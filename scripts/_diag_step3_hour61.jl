################################################################################
# Throwaway diagnosis script: the full-week run (_week1_freeze_fix) committed #
# hours 1-60 of step 3 then came back INFEASIBLE at hour 61, stopping the     #
# roll. Mirrors run_three_step_redispatch.jl exactly through the construction #
# of data3, using the *full* HOURS = 1:168 (unlike the hour-1 diagnosis,      #
# hour 61's step-2 reference depends on step 2's 8th window, hours 57-64, so  #
# a truncated HOURS range would not reproduce it faithfully). Reconstructs    #
# hour 61's window manually (instead of going through solve_rd's rolling      #
# horizon, which throws the live model away) so the solved, infeasible       #
# JuMP/Xpress model is available for JuMP.compute_conflict!. Delete when the  #
# diagnosis is done.                                                          #
################################################################################

haskey(ENV, "XPRESSDIR") || (ENV["XPRESSDIR"] = raw"C:\xpressmp")

using NetworkModelBuilder
using Xpress
using Dates

const MOI  = NetworkModelBuilder.MOI
const JuMP = NetworkModelBuilder.JuMP

include(joinpath(@__DIR__, "SteeringPlanData.jl"))
using .SteeringPlanData

include(joinpath(@__DIR__, "ContingencyData.jl"))
using .ContingencyData

################################################################################
# Configuration — copied from run_three_step_redispatch.jl                   #
################################################################################

const DATA_DIR         = raw"D:\TVA\LongTermSteeringPlan\Data\Clean"
const CONTINGENCY_XLSX = raw"O:\ESM\IPL\SMA\C_Studies\52_ZORBA\02_Input\LT_steering_data\LTSteering_Structuur_SMA_v3_EME.xlsx"
const HOURS      = 1:168
const HORIZON_CB = 8
const STEP_CB    = 8
const OPTIMIZER  = Xpress.Optimizer

const OVERLOAD_PRICE      = OverloadPrice(; per_energy = 477_000.0)
const LOAD_SHEDDING_PRICE = 10 * OVERLOAD_PRICE.per_energy
const SPILLAGE_PRICE      = 5 * OVERLOAD_PRICE.per_energy

################################################################################
# Helpers — copied verbatim from run_three_step_redispatch.jl for fidelity    #
################################################################################

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

function _spread_over(c::T, new_dim::Dimension) where {T}
    kwargs = Dict{Symbol,Any}()
    for f in fieldnames(T)
        v = getfield(c, f)
        kwargs[f] = v isa NetworkVector ? nw_vector(new_dim, :time, v.data) : v
    end

    return T(; kwargs...)
end

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

function bridge_events(net::Network, events::Vector{ContingencyEvent})
    all_edges = ids(net, AbstractEdge)
    base      = _n_components(net, all_edges)

    return [ev for ev in events if !isempty(ev.edges) &&
                                    _n_components(net, setdiff(all_edges, ev.edges)) > base]
end

function contingency_events(net::Network, candidates::Vector{ContingencyEvent})
    bridges       = bridge_events(net, candidates)
    bridge_labels = Set(ev.label for ev in bridges)
    kept          = [ev for ev in candidates if !(ev.label in bridge_labels)]

    return kept, bridges
end

touches(pred, data::NetworkData, ev::ContingencyEvent) = any(e -> pred(data, e), ev.edges)

################################################################################
# Load data, resolve events (hour-independent)                                #
################################################################################

println("[setup] loading network data for hours $HOURS ...")
data1 = load_network(DATA_DIR; hours = HOURS, baseMVA = 100.0)

println("[setup] loading Elia's N-1 study contingency events ...")
raw_events    = load_contingency_events(CONTINGENCY_XLSX)
events, _rep  = resolve_contingency_events(data1, raw_events)

cb_events = filter(ev -> touches(cross_border, data1, ev), events)
be_events = filter(ev -> !touches(cross_border, data1, ev), events)

cb_monitored = sort!(unique(reduce(vcat, (ev.edges for ev in cb_events); init = Int[])))
be_monitored = sort!(unique(reduce(vcat, (ev.edges for ev in be_events); init = Int[])))
cb_contingency, cb_excluded = contingency_events(network(data1), cb_events)
be_contingency, be_excluded = contingency_events(network(data1), be_events)

println("[setup] cb_contingency=", length(cb_contingency), " be_contingency=", length(be_contingency),
        " (excluded as bridges: cb=", length(cb_excluded), " be=", length(be_excluded), ")")

################################################################################
# Step 2 — via the real solve_rd, full 1:168, so hour 61's reference is exact #
################################################################################

println("[step2] solving the cross-border redispatch over $(length(cb_contingency)) event(s), full week ...")
data2 = exclude_all_storage!(data1)
data2 = with_contingencies(data2, cb_contingency)
rd2   = Redispatch(; monitored = cb_monitored, control = :preventive, overload = OVERLOAD_PRICE)
result2 = solve_rd(data2, LPFFormulation, OPTIMIZER; redispatch = rd2,
                   horizon = HORIZON_CB, step = STEP_CB, reuse = true, warm_start = false)
println("[step2] termination status: ", result2["termination_status"])
result2["termination_status"] == MOI.OPTIMAL ||
    error("[step2] did not solve to OPTIMAL, cannot proceed to step 3")

################################################################################
# Step 3 — build the pre-contingency base (frozen, restricted, shed + spill)  #
################################################################################

println("[step3] freezing dispatch at step 2's solution, restricting to Belgium ...")
data3_base = freeze_dispatch(data1, result2)
data3_base = restrict_to_belgium!(data3_base)
data3_base = add_load_shedding!(data3_base; price = LOAD_SHEDDING_PRICE)
shed_ids3  = load_shedding_ids(data3_base)
data3_base = add_spillage!(data3_base; price = SPILLAGE_PRICE)
spill_ids3 = spillage_ids(data3_base)

corrective_ids = vcat(shed_ids3, spill_ids3)
rd_exception   = Dict{Tuple{Symbol,Int},Symbol}((:unit, id) => :corrective for id in corrective_ids)
monitored_all  = sort!(unique(vcat(cb_monitored, be_monitored)))

println("[step3] shed_ids3=", length(shed_ids3), " spill_ids3=", length(spill_ids3),
        " monitored_all=", length(monitored_all))

"""
    solve_hourN(n, events_subset; silent = true)

Hour `n` of step 3, wired in with only `events_subset`'s contingencies (or, if
`nothing`, no `:contingency` dimension at all — the base case alone), built and
solved exactly as `solve_rolling_horizon`'s window `n:n` would (freshly built,
`reuse` notwithstanding), so the live `NetworkModel` survives the call for
conflict analysis — `solve_rd` itself throws it away.

Returns the solved `NetworkModel`.
"""
function solve_hourN(n::Int, events_subset; silent::Bool = true)
    d3    = events_subset === nothing ? data3_base : with_contingencies(data3_base, events_subset)
    steps = dim_length(d3, :time)
    w     = window(d3, :time, n:n)
    n < steps && NetworkModelBuilder._open_window_end!(w)

    rd3 = Redispatch(; monitored = monitored_all, control = :preventive,
                     exception = rd_exception, overload = OVERLOAD_PRICE)
    nm = instantiate_model(w, RedispatchProblem, LPFFormulation;
                           jump_model = JuMP.direct_model(Xpress.Optimizer()),
                           ext = Dict{Symbol,Any}(:redispatch => rd3))
    silent && JuMP.set_silent(nm.model)
    optimize_model!(nm, OPTIMIZER)

    return nm
end

println("[ready] data3_base, be_contingency ($(length(be_contingency)) events), and solve_hourN(...) are set up.")

################################################################################
# Reproduce hour 61 in isolation                                              #
################################################################################

println("[check] solving hour 61 in isolation (full 79-event be_contingency set) ...")
nm61 = solve_hourN(61, be_contingency; silent = false)
println("[check] status=", nm61.sol["termination_status"],
        " objective=", get(nm61.sol, "objective", NaN),
        " solve_time=", nm61.sol["solve_time"])
