################################################################################
# run_three_step_redispatch.jl                                                #
# Orchestrates the three-step LongTermSteeringPlan redispatch pipeline:       #
#   1. load flow at market-cleared dispatch                                   #
#   2. cross-border N-1 redispatch, reference = raw market data               #
#   3. internal-BE N-1 redispatch, reference = step 2's solved dispatch       #
#                                                                              #
# Defaults to a one-week validation window (`HOURS = 1:168`). Scaling to the  #
# full year is a parameter change — `HOURS = 1:8760` and a rolling            #
# `HORIZON`/`STEP` smaller than 8760 — not a rewrite of anything below.       #
################################################################################

# Xpress.jl needs `XPRESSDIR` to find the local install; set it defensively
# rather than assuming it is already configured on every machine this runs on.
haskey(ENV, "XPRESSDIR") || (ENV["XPRESSDIR"] = raw"C:\xpressmp")

using NetworkModelBuilder
using Xpress
using CSV
using DataFrames
using Dates

const MOI  = NetworkModelBuilder.MOI
const JuMP = NetworkModelBuilder.JuMP

include(joinpath(@__DIR__, "SteeringPlanData.jl"))
using .SteeringPlanData

include(joinpath(@__DIR__, "ContingencyData.jl"))
using .ContingencyData

################################################################################
# Configuration                                                              #
################################################################################

const DATA_DIR         = raw"D:\TVA\LongTermSteeringPlan\Data\Clean"
const CONTINGENCY_XLSX = raw"O:\ESM\IPL\SMA\C_Studies\52_ZORBA\02_Input\LT_steering_data\LTSteering_Structuur_SMA_v3_EME.xlsx"
const HOURS            = 1:168

# Contingencies come from Elia's own N-1 study (`CONTINGENCY_XLSX`, sheet
# "N-1"), not from an N-1 sweep of every cross-border/internal-BE edge
# individually: see `ContingencyData.jl` for how its three mini-tables
# (simple N-1, multi-section, busbar outages) are parsed and resolved into
# `ContingencyEvent`s, each outaging one or more edges — and, in principle, a
# generator, see `with_contingencies` below — at a single contingency
# coordinate instead of assuming one coordinate is always one edge. Of the 94
# in-scope events, 13 touch a cross-border edge (11 of Elia's "simple" N-1
# events plus 2 busbar groups whose elements include one) and go to step 2;
# the other 81 (39 simple, 6 multi-section, 36 busbar) go to step 3 — well
# below the roughly 266 single-edge contingencies the old "every internal-BE
# edge individually" sweep produced.
#
# CORRECTION of an earlier note here: the 24h/11-contingency step 2 INFEASIBLE
# was re-verified directly against Xpress's own log (converted from the
# PowerShell UTF-16 transcript, not eyeballed) and it is real, not a
# presolve/scaling artifact. Xpress's own "Verifying unscaled infeasibility"
# step — the exact check that would catch a false positive like this — comes
# back with a large *nonzero* unscaled infeasibility every single time: 224,768
# for the full 11-contingency/24h case; 21,076 and 19,885 respectively for
# lines 240 and 285 tested as isolated single contingencies (~1/7 the rows,
# same coefficient range, so problem size was never the explanation); and
# Xpress's final verdict in every case is an unqualified "Problem is
# infeasible", never a scaled-vs-unscaled discrepancy. This *confirms*, rather
# than contradicts, the earlier IIS finding of two genuinely non-securable N-1
# contingencies — Elia's own simple N-1 events "DI 380 27 MAASBVANYK TI" (edge
# 240) and "DI 380 80 AVELIAVLGM TI" (edge 285), both still part of the
# official 13-event cross-border set. `OVERLOAD_PRICE` below is what actually
# resolves that — by pricing the violation instead of forbidding it — not the
# horizon length: an 8h-windowed hard-rating rerun (no price) is still
# INFEASIBLE too, just on a different window.
#
# Step 2 and step 3 still use different horizons, but for a tractability
# reason now, not a correctness one:
# - Step 2 (13 contingency events, was 11 single edges): a single 24h window
#   is ~1.9M rows and solves in seconds without the price, but *with* the
#   price it becomes numerically much harder (hundreds of thousands of
#   simplex iterations, still not converged after 100+ seconds when last
#   tried) — apparently the 477,000 coefficient is far more taxing at this
#   scale. 8h rolling windows are already proven fast (all 3 windows OPTIMAL
#   in ~1-2 minutes) with the price applied, so they stay.
# - Step 3 (81 contingency events, restricted to Belgium, was ~266 single
#   edges): well below the scale that forced 1h windows here in the first
#   place — at ~266 contingencies, even with `OVERLOAD_PRICE` in the
#   objective, Xpress was still grinding past 2.5M simplex iterations without
#   resolving *one* 8h window after 13+ hours, and even at a 1h horizon an
#   isolated hour 14 came back a clean, confirmed INFEASIBLE (nonzero
#   unscaled infeasibility, ~90s) before the roll as a whole was made to work
#   — i.e. `OVERLOAD_PRICE` does not make step 3 unconditionally solvable,
#   because it only prices *monitored line* overloads, not the power balance
#   that Belgium-only pinning of every non-BE unit (`restrict_to_belgium!`)
#   can leave with nothing left able to close it. With roughly a third of the
#   old contingency count, and no event outaging more than a handful of edges
#   at once (a busbar group lists at most 5), 1h windows are kept rather than
#   re-risking a wider one that has never been tried, at any scale, with the
#   price applied — revisit if a future revision of Elia's N-1 study
#   meaningfully grows the event count.
const HORIZON_CB = 8   # step 2 — cross-border, 13 contingency events
const STEP_CB    = 8
const HORIZON_BE = 1   # step 3 — internal BE, 81 contingency events
const STEP_BE    = 1
const RUN_ID    = "_week1_price_rescale"
const OUT_DIR   = joinpath(@__DIR__, "..", "runs", RUN_ID)
const OPTIMIZER = Xpress.Optimizer

# The costliest redispatch already flowing through this data is the thermal
# ceiling: `rd_cost_up`/`rd_cost_down` top out at 477 $/MWh in
# thermal_generators.csv (mean ~240 $/MWh), i.e. 47,700 $/pu once scaled by
# `baseMVA = 100` the same way `Generator.cost_up` is (see
# `SteeringPlanData._load_thermal_generators!`). Storage is cheaper over these
# 24 hours (<=137.5 $/MWh, <=13,753 $/pu). A last-resort overload price has to
# clear that ceiling by enough that every cheaper redispatch measure is used up
# first. This used to be a 10x multiple (477,000 $/pu) — Xpress's default
# SCALING/PRESOLVE combination gave a false INFEASIBLE on at least one hour of
# step 3 with that value in the LP alongside PST angles of O(0.1) (confirmed
# against HiGHS and against re-solving with SCALING=0; see lessons.md). 3x is
# still a comfortable, unambiguous margin over every real redispatch cost at a
# much smaller absolute scale; revisit if the underlying cost data changes
# materially or this margin turns out not to be enough on other data.
const OVERLOAD_PRICE = OverloadPrice(; per_energy = 3 * 47_700.0)

# Shedding real demand is a more severe measure than a monitored line running hot
# (`OVERLOAD_PRICE`), so it has to clear that price by a wide margin, not sit below
# or at it — 4x `OVERLOAD_PRICE` so the solver exhausts redispatch and priced
# overload alike before shedding a single per-unit of load.
const LOAD_SHEDDING_PRICE = 4 * OVERLOAD_PRICE.per_energy

# Dumping surplus generation (`add_spillage!`) is real TSO practice — curtailment — and,
# unlike load shedding, interrupts no customer, so it stays strictly cheaper than
# `LOAD_SHEDDING_PRICE`: shedding real demand remains the true last resort. But it still has to
# clear `OVERLOAD_PRICE` by enough that thermal redispatch and priced line overloads are
# exhausted first, so it sits at the midpoint of the two: 2 * OVERLOAD_PRICE, half of
# `LOAD_SHEDDING_PRICE`.
const SPILLAGE_PRICE = 2 * OVERLOAD_PRICE.per_energy

################################################################################
# Helpers                                                                    #
################################################################################

"""
    with_contingencies(data, events)

`data` rebuilt over `Dimension(:time => T, :contingency => length(events) + 1)`:
contingency `1` is the base case and contingency `k + 1` takes out every edge
and unit `events[k]` lists, together — following `test/rd.jl`'s N-1 pattern,
generalized from one contingency coordinate per outaged edge to one per
[`ContingencyData.ContingencyEvent`](@ref), which may bundle several edges (a
multi-section line, a busbar's connected elements) that trip as one.

A unit is overridden the exact same way an edge is, since a [`Generator`](@ref)
carries the same `status` field an edge does — see
[`ContingencyData.resolve_contingency_events`](@ref) for why a generator is the
only unit type an `events` entry ever names.

Every component's existing `:time` profile is spread unchanged over every
contingency, since `set_dimension` does not do this on its own: a `NetworkVector`
built against the smaller `:time`-only dimension has to be re-wrapped over the
larger one, exactly as the `nw_vector(dim, name, values)` docstring describes
for "a daily profile in a problem that also has contingencies".
"""
function with_contingencies(data::NetworkData, events::Vector{ContingencyEvent})
    new_dim = add_dimension(dimension(data), :contingency, length(events) + 1)

    return set_dimension(data, new_dim; apply! = function (net, dim)
        for (id, c) in net.node
            net.node[id] = _spread_over(c, dim)
        end
        for (id, c) in net.edge
            spread = _spread_over(c, dim)
            k = findfirst(ev -> id in ev.edges, events)
            net.edge[id] = k === nothing ? spread :
                typeof(spread)(; SteeringPlanData._fields(spread)...,
                               status = nw_vector(dim, (n, coord) -> coord.contingency != k + 1))
        end
        for (id, c) in net.unit
            spread = _spread_over(c, dim)
            k = findfirst(ev -> id in ev.units, events)
            net.unit[id] = k === nothing ? spread :
                typeof(spread)(; SteeringPlanData._fields(spread)...,
                               status = nw_vector(dim, (n, coord) -> coord.contingency != k + 1))
        end
    end)
end

"every `NetworkVector` field of `c`, re-spread from its old `:time`-only dimension onto `new_dim`"
function _spread_over(c::T, new_dim::Dimension) where {T}
    kwargs = Dict{Symbol,Any}()
    for f in fieldnames(T)
        v = getfield(c, f)
        kwargs[f] = v isa NetworkVector ? nw_vector(new_dim, :time, v.data) : v
    end

    return T(; kwargs...)
end

"the number of connected components of `net`'s nodes when only `active_edges` carry a connection"
function _n_components(net::Network, active_edges)
    node_ids = ids(net, AbstractNode)
    index    = Dict(i => k for (k, i) in enumerate(node_ids))
    n        = length(node_ids)

    parent = collect(1:n)
    find(x) = (while parent[x] != x
                   parent[x] = parent[parent[x]]
                   x = parent[x]
               end; x)
    for e in active_edges
        i, j   = terminals(edges(net)[e])
        ri, rj = find(index[i]), find(index[j])
        ri == rj || (parent[ri] = rj)
    end

    return length(Set(find(k) for k in 1:n))
end

"""
    bridge_events(net, events)

The `events` whose edges, removed *together*, disconnect the graph — the
group generalization of a bridge (cut-edge) to a
[`ContingencyData.ContingencyEvent`](@ref) that may outage several edges at
once. Found by brute force — remove each event's edges in turn and count
connected components with a union-find — which is fine at this network's size
(a few hundred edges, under a hundred events), and specializes to the
single-edge bridge test for an event that outages only one.

This matters because an N-1 outage of a bridge — or of a set of edges that
together act as one — islands whatever sits on the far side of it with no path
back to the rest of the network. If that island's net position is not exactly
zero — the general case — no redispatch can rebalance it: there is no
alternate route for power to take. That is a structurally non-securable
contingency, not a shortfall of generation headroom, and no [`Redispatch`](@ref)
measure can fix it; see the `bridge_events` exclusion in this file's `main`
section — two of Elia's own simple N-1 events (`DI 380 27 MAASBVANYK TI`,
`DI 380 80 AVELIAVLGM TI`) were confirmed structurally infeasible this way even
in isolation before `OVERLOAD_PRICE` was introduced, see the notes above
`HORIZON_CB`.

An event with no resolved edges at all (a busbar group that only resolved to a
generator, say) cannot disconnect anything by this test and is never excluded
by it.
"""
function bridge_events(net::Network, events::Vector{ContingencyEvent})
    all_edges = ids(net, AbstractEdge)
    base      = _n_components(net, all_edges)

    return [ev for ev in events if !isempty(ev.edges) &&
                                    _n_components(net, setdiff(all_edges, ev.edges)) > base]
end

"""
    contingency_events(net, candidates)

`candidates` with its [`bridge_events`](@ref) removed, and the excluded ones —
in that order — since an event whose combined outage disconnects the graph is
excluded from getting its own N-1 contingency coordinate but its edges are
still worth monitoring for congestion, see the `monitored` argument at each
step's call site below.
"""
function contingency_events(net::Network, candidates::Vector{ContingencyEvent})
    bridges       = bridge_events(net, candidates)
    bridge_labels = Set(ev.label for ev in bridges)
    kept          = [ev for ev in candidates if !(ev.label in bridge_labels)]

    return kept, bridges
end

"whether any resolved edge of contingency event `ev` satisfies `pred(data, e)` — e.g. `touches(cross_border, data, ev)`"
touches(pred, data::NetworkData, ev::ContingencyEvent) = any(e -> pred(data, e), ev.edges)

"whether `result` carries a solved network index `n` — false for one a rolling
horizon never reached because an earlier window came back infeasible and
stopped the roll (see `solve_rolling_horizon`'s `stopping the roll` warning),
which `haskey(result, \"solution\")` alone does not catch since that key is
present as soon as *any* window committed."
_solved(result::Dict{String,Any}, n::Int) =
    haskey(result, "solution") && haskey(result["solution"]["nw"], "$n")

"one row per (edge, hour) where the solved terminal flow exceeds `rate_a`; `LoadFlowProblem` does not enforce it

Empty, with the same columns, when `result` carries no solved values (e.g. an
infeasible redispatch) — there is nothing to report, not an error."
function congestion_report(data::NetworkData, result::Dict{String,Any})
    rows = NamedTuple{(:edge, :hour, :flow_pu, :rate_a_pu, :overload_pu),
                      Tuple{Int,Int,Float64,Float64,Float64}}[]
    haskey(result, "solution") || return DataFrame(rows)

    net   = network(data)
    hours = hour_ids(data)
    for e in ids(net, AbstractEdge)
        rate = edges(net)[e].rate_a
        isfinite(rate) || continue
        for n in nw_ids(data)
            _solved(result, n) || continue
            term = nw_solution(result, n)["edge"]["$e"]["terminal"]
            flow = maximum(abs(t["p"]) for t in values(term))
            flow > rate + 1e-6 &&
                push!(rows, (edge = e, hour = hours[n], flow_pu = flow, rate_a_pu = rate,
                             overload_pu = flow - rate))
        end
    end

    return DataFrame(rows)
end

"a one-row summary of a solve"
solve_summary(result::Dict{String,Any}) = DataFrame(
    timestamp = string(Dates.now()),
    termination_status = string(result["termination_status"]),
    objective = get(result, "objective", NaN),
    solve_time = result["solve_time"])

"redispatch volumes of every generator and storage unit, one row per (unit, hour), at the base case only

Every measure here is preventive, so its volumes are identical across every
contingency (`constraint_redispatch_control`); the base case is the whole
story and reporting only it keeps this from being one row per (unit, hour,
contingency) — except a load-shedding generator
([`SteeringPlanData.add_load_shedding!`](@ref)), which is corrective: its row
here is only its base-case volume, see [`load_shedding_report`](@ref) for what
it sheds per contingency.

Empty, with the same columns, when `result` carries no solved values (e.g. an
infeasible redispatch) — there is nothing to report, not an error."
function redispatch_volumes(data::NetworkData, result::Dict{String,Any})
    rows = NamedTuple{(:unit, :type, :hour, :up, :down),
                      Tuple{Int,String,Int,Float64,Float64}}[]
    haskey(result, "solution") || return DataFrame(rows)

    hours = hour_ids(data)
    for n in nw_ids(data; contingency = 1)
        _solved(result, n) || continue
        sol = nw_solution(result, n)
        for (u, entry) in sol["unit"]
            if haskey(entry, "pgup")
                push!(rows, (unit = parse(Int, u), type = entry["type"], hour = hours[n],
                             up = entry["pgup"], down = entry["pgdn"]))
            elseif haskey(entry, "psup")
                push!(rows, (unit = parse(Int, u), type = entry["type"], hour = hours[n],
                             up = entry["psup"], down = entry["psdn"]))
            end
        end
    end

    return DataFrame(rows)
end

"""
    overload_report(data, result, events)

One row per (edge, hour, contingency) where a monitored edge's rating was
priced rather than enforced (`OVERLOAD_PRICE`) and the solved overload is
non-zero: how far past its rating the edge ran, and — where the network index
sits at a contingency rather than the base case — which member of `events`
was on outage when it happened, following the same `with_contingencies`
convention `redispatch_volumes` relies on (contingency `k + 1` <=> `events[k]`
out).

Empty, with the same columns, when `result` carries no solved values (e.g. an
infeasible redispatch) — there is nothing to report, not an error.
"""
function overload_report(data::NetworkData, result::Dict{String,Any}, events::Vector{ContingencyEvent})
    rows = NamedTuple{(:edge, :name, :hour, :contingency, :outaged_event, :outaged_category, :overload_pu),
                      Tuple{Int,String,Int,Int,Union{Missing,String},Union{Missing,Symbol},Float64}}[]
    haskey(result, "solution") || return DataFrame(rows)

    dim   = dimension(data)
    net   = network(data)
    hours = hour_ids(data)
    for n in nw_ids(data)
        _solved(result, n) || continue
        c   = coordinates(dim, n)
        sol = nw_solution(result, n)["edge"]
        for (e_str, entry) in sol
            haskey(entry, "overload") || continue
            ov = entry["overload"]
            ov > 1e-6 || continue
            e  = parse(Int, e_str)
            ev = c.contingency == 1 ? missing : events[c.contingency - 1]
            push!(rows, (edge = e, name = edges(net)[e].name, hour = hours[c.time],
                         contingency = c.contingency,
                         outaged_event = ismissing(ev) ? missing : ev.label,
                         outaged_category = ismissing(ev) ? missing : ev.category,
                         overload_pu = ov))
        end
    end

    sort!(rows, by = r -> (r.edge, r.hour, r.contingency))

    return DataFrame(rows)
end

"""
    load_shedding_report(data, result, shed_ids, events)

One row per (node, hour, contingency) where a synthetic load-shedding
generator (`shed_ids`, see [`SteeringPlanData.add_load_shedding!`](@ref)) shed
a non-zero amount of demand — a **corrective** measure, so this is what the
operator would have done after that specific contingency (`events[contingency
- 1]`, `missing` at the base case), not a value pre-committed to cover every
contingency at once.

Empty, with the same columns, when `result` carries no solved values (e.g. an
infeasible redispatch) — there is nothing to report, not an error.
"""
function load_shedding_report(data::NetworkData, result::Dict{String,Any},
                              shed_ids::Vector{Int}, events::Vector{ContingencyEvent})
    rows = NamedTuple{(:node, :hour, :contingency, :outaged_event, :outaged_category, :shed_pu),
                      Tuple{Int,Int,Int,Union{Missing,String},Union{Missing,Symbol},Float64}}[]
    haskey(result, "solution") || return DataFrame(rows)

    hours = hour_ids(data)
    dim = dimension(data)
    net = network(data)
    for n in nw_ids(data)
        _solved(result, n) || continue
        c   = coordinates(dim, n)
        sol = nw_solution(result, n)["unit"]
        for u in shed_ids
            haskey(sol, "$u") || continue
            shed = sol["$u"]["pgup"]
            shed > 1e-6 || continue
            ev = c.contingency == 1 ? missing : events[c.contingency - 1]
            push!(rows, (node = units(net)[u].node, hour = hours[c.time], contingency = c.contingency,
                         outaged_event = ismissing(ev) ? missing : ev.label,
                         outaged_category = ismissing(ev) ? missing : ev.category,
                         shed_pu = shed))
        end
    end

    sort!(rows, by = r -> (r.node, r.hour, r.contingency))

    return DataFrame(rows)
end

"""
    spillage_report(data, result, spill_ids, events)

One row per (node, hour, contingency) where a synthetic spillage generator
(`spill_ids`, see [`SteeringPlanData.add_spillage!`](@ref)) withdrew a
non-zero amount of surplus generation — the mirror image of
[`load_shedding_report`](@ref), reading `pgdn` (the withdrawal volume) instead
of `pgup`, for the same reason `add_spillage!` reads as the mirror image of
`add_load_shedding!`. Also a **corrective** measure: what the operator would
have done after that specific contingency, not a value pre-committed to cover
every contingency at once.

Empty, with the same columns, when `result` carries no solved values (e.g. an
infeasible redispatch) — there is nothing to report, not an error.
"""
function spillage_report(data::NetworkData, result::Dict{String,Any},
                         spill_ids::Vector{Int}, events::Vector{ContingencyEvent})
    rows = NamedTuple{(:node, :hour, :contingency, :outaged_event, :outaged_category, :spilled_pu),
                      Tuple{Int,Int,Int,Union{Missing,String},Union{Missing,Symbol},Float64}}[]
    haskey(result, "solution") || return DataFrame(rows)

    hours = hour_ids(data)
    dim = dimension(data)
    net = network(data)
    for n in nw_ids(data)
        _solved(result, n) || continue
        c   = coordinates(dim, n)
        sol = nw_solution(result, n)["unit"]
        for u in spill_ids
            haskey(sol, "$u") || continue
            spilled = sol["$u"]["pgdn"]
            spilled > 1e-6 || continue
            ev = c.contingency == 1 ? missing : events[c.contingency - 1]
            push!(rows, (node = units(net)[u].node, hour = hours[c.time], contingency = c.contingency,
                         outaged_event = ismissing(ev) ? missing : ev.label,
                         outaged_category = ismissing(ev) ? missing : ev.category,
                         spilled_pu = spilled))
        end
    end

    sort!(rows, by = r -> (r.node, r.hour, r.contingency))

    return DataFrame(rows)
end

"write `df` to `path`, creating parent directories as needed"
function write_csv(path::AbstractString, df::DataFrame)
    mkpath(dirname(path))
    CSV.write(path, df)

    return nothing
end

"""
    ensure_optimal(result, label)

Stop the pipeline with a clear message if `result` did not solve to
`MOI.OPTIMAL`, rather than letting the next step crash trying to read a
solution that does not exist — [`freeze_dispatch`](@ref) reads `result2`'s
solution hour by hour and has no reasonable fallback if there is none.

This step's own report files are written before this is called, so an
infeasible result still leaves a summary and an empty (not missing) report
behind — see [`congestion_report`](@ref) and [`redispatch_volumes`](@ref) —
and only the *next* step is refused.
"""
function ensure_optimal(result::Dict{String,Any}, label::AbstractString)
    status = result["termination_status"]
    status == MOI.OPTIMAL ||
        error("$label finished with termination status $status, not OPTIMAL. " *
              "Stopping here rather than reading a solution that does not exist; " *
              "see the report files already written under $OUT_DIR for what was found.")

    return nothing
end

################################################################################
# Step 0 — load the market data                                              #
################################################################################

println("[1/3] loading network data for hours $HOURS ...")
data1 = load_network(DATA_DIR; hours = HOURS, baseMVA = 100.0)

################################################################################
# Step 1 — load flow at market-cleared dispatch                              #
################################################################################

println("[1/3] solving the load flow ...")
result1 = solve_lf(data1, LPFFormulation, OPTIMIZER)
println("[1/3] termination status: ", result1["termination_status"])

dir1 = joinpath(OUT_DIR, "01_market_lf")
write_csv(joinpath(dir1, "summary.csv"), solve_summary(result1))
write_csv(joinpath(dir1, "congestion.csv"), congestion_report(data1, result1))
ensure_optimal(result1, "[1/3] load flow")

################################################################################
# Contingency events — Elia's own N-1 study                                  #
################################################################################

println("[2/3] loading Elia's N-1 study contingency events ...")
raw_events           = load_contingency_events(CONTINGENCY_XLSX)
events, event_report = resolve_contingency_events(data1, raw_events)

dir_events = joinpath(OUT_DIR, "00_contingencies")
write_csv(joinpath(dir_events, "events.csv"), event_report)

println("[2/3] ", length(raw_events), " event(s) read from Elia's N-1 study, ",
        length(events), " resolved and wired in:")
for row in eachrow(combine(groupby(event_report, [:category, :status]), nrow => :n))
    println("[2/3]   ", row.category, " ", row.status, ": ", row.n)
end
for row in eachrow(event_report[event_report.status .!= :ok, :])
    println("[2/3]   ", row.status, ": ", row.label, " (", row.category,
            ") — unresolved: ", row.unresolved)
end

cb_events = filter(ev -> touches(cross_border, data1, ev), events)
be_events = filter(ev -> !touches(cross_border, data1, ev), events)
println("[2/3] ", length(cb_events), " cross-border-touching event(s) (-> step 2), ",
        length(be_events), " internal event(s) (-> step 3)")

simple_events     = filter(ev -> ev.category == :simple, events)
simple_mismatches = filter(ev -> !ismissing(ev.xb_flag) &&
                           ev.xb_flag != touches(cross_border, data1, ev), simple_events)
if isempty(simple_mismatches)
    println("[2/3] the sheet's own XB? flag agrees with the derived classification for ",
            "all ", length(simple_events), " simple N-1 events")
else
    println("[2/3] ", length(simple_mismatches), " simple N-1 event(s) disagree with the ",
            "sheet's own XB? flag: ", join(getproperty.(simple_mismatches, :label), ", "))
end

################################################################################
# Step 2 — cross-border N-1 redispatch, reference = raw market data          #
################################################################################

println("[2/3] building the cross-border contingency set ...")
cb_monitored = sort!(unique(reduce(vcat, (ev.edges for ev in cb_events); init = Int[])))
cb_contingency, cb_excluded = contingency_events(network(data1), cb_events)
isempty(cb_excluded) ||
    println("[2/3] excluding ", length(cb_excluded), " event(s) whose combined outage ",
            "disconnects the graph (no redispatch can rebalance an island with no ",
            "alternate path): ", join(getproperty.(cb_excluded, :label), ", "))
println("[2/3] excluding storage from the redispatch (see `exclude_all_storage!`) ...")
data2 = exclude_all_storage!(data1)
data2 = with_contingencies(data2, cb_contingency)
rd2   = Redispatch(; monitored = cb_monitored, control = :preventive, overload = OVERLOAD_PRICE)

println("[2/3] solving the cross-border redispatch over $(length(cb_events)) contingency event(s) ...")
result2 = solve_rd(data2, LPFFormulation, OPTIMIZER; redispatch = rd2,
                   horizon = HORIZON_CB, step = STEP_CB, reuse = true, warm_start = false)
println("[2/3] termination status: ", result2["termination_status"])

dir2 = joinpath(OUT_DIR, "02_cross_border_redispatch")
write_csv(joinpath(dir2, "summary.csv"), solve_summary(result2))
write_csv(joinpath(dir2, "redispatch_volumes.csv"), redispatch_volumes(data2, result2))
write_csv(joinpath(dir2, "overload.csv"), overload_report(data2, result2, cb_contingency))
write_csv(joinpath(dir2, "excluded_bridge_edges.csv"),
         DataFrame(label = getproperty.(cb_excluded, :label),
                   category = getproperty.(cb_excluded, :category),
                   edges = [join(ev.edges, ";") for ev in cb_excluded]))
ensure_optimal(result2, "[2/3] cross-border redispatch")

################################################################################
# Step 3 — internal-BE N-1 redispatch, reference = step 2's solved dispatch  #
################################################################################

println("[3/3] freezing the dispatch at step 2's solution and restricting to Belgium ...")
be_monitored = sort!(unique(reduce(vcat, (ev.edges for ev in be_events); init = Int[])))
be_contingency, be_excluded = contingency_events(network(data1), be_events)
isempty(be_excluded) ||
    println("[3/3] excluding ", length(be_excluded), " event(s) whose combined outage ",
            "disconnects the graph (no redispatch can rebalance an island with no ",
            "alternate path): ", join(getproperty.(be_excluded, :label), ", "))
data3          = freeze_dispatch(data1, result2)
data3          = restrict_to_belgium!(data3)
println("[3/3] adding a corrective load-shedding relief valve at every Belgian node ...")
# without storage, step 3's power balance can come up short at some hours once every
# non-BE unit is pinned (`restrict_to_belgium!`) and storage is gone
# (`exclude_all_storage!`); this is that shortfall's relief valve, not a substitute
# for either exclusion
data3          = add_load_shedding!(data3; price = LOAD_SHEDDING_PRICE)
shed_ids3      = load_shedding_ids(data3)
println("[3/3] adding a corrective spillage relief valve at every Belgian node ...")
# load shedding alone only relieves a deficit (its synthetic generator has pg = pmin = 0,
# so it can only inject); this is the surplus-side mirror for an hour with too much
# generation and nowhere for it to go, which load shedding structurally cannot touch
data3          = add_spillage!(data3; price = SPILLAGE_PRICE)
spill_ids3     = spillage_ids(data3)
data3          = with_contingencies(data3, be_contingency)
corrective_ids = vcat(shed_ids3, spill_ids3)
rd_exception   = Dict{Tuple{Symbol,Int},Symbol}((:unit, id) => :corrective for id in corrective_ids)
rd3            = Redispatch(; monitored = sort!(unique(vcat(cb_monitored, be_monitored))),
                            control = :preventive, exception = rd_exception,
                            overload = OVERLOAD_PRICE)

println("[3/3] solving the internal-BE redispatch over $(length(be_events)) contingency event(s) ...")
# a direct model skips the copy JuMP otherwise keeps before handing the problem to Xpress;
# measured on this data (hour 14, full 266-contingency scale) that cut the first window's
# solve from ~42 s to ~28 s with the same objective (5.9073e6 either way, `reuse` means only
# the first window pays this cost) — see the diagnosis for the rest of what was measured.
result3 = solve_rd(data3, LPFFormulation, OPTIMIZER; redispatch = rd3,
                   horizon = HORIZON_BE, step = STEP_BE, reuse = true, warm_start = false,
                   new_model = () -> JuMP.direct_model(Xpress.Optimizer()))
println("[3/3] termination status: ", result3["termination_status"])

dir3 = joinpath(OUT_DIR, "03_internal_redispatch")
write_csv(joinpath(dir3, "summary.csv"), solve_summary(result3))
write_csv(joinpath(dir3, "redispatch_volumes.csv"), redispatch_volumes(data3, result3))
write_csv(joinpath(dir3, "overload.csv"), overload_report(data3, result3, be_contingency))
write_csv(joinpath(dir3, "load_shedding.csv"), load_shedding_report(data3, result3, shed_ids3, be_contingency))
write_csv(joinpath(dir3, "spillage.csv"), spillage_report(data3, result3, spill_ids3, be_contingency))
write_csv(joinpath(dir3, "excluded_bridge_edges.csv"),
         DataFrame(label = getproperty.(be_excluded, :label),
                   category = getproperty.(be_excluded, :category),
                   edges = [join(ev.edges, ";") for ev in be_excluded]))

println("done — outputs written under ", OUT_DIR)
