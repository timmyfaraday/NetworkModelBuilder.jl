################################################################################
# PipelineReports.jl                                                          #
# What the LongTermSteeringPlan pipeline writes about a solve: a summary, the   #
# edges whose solved flow went past their rating, and what a redispatch moved.#
# Every report names the hour of the year, not the position along `:time`, see#
# `hour_ids`.                                                                 #
################################################################################

module PipelineReports

using CSV
using DataFrames
using Dates
using NetworkModelBuilder
using ..SteeringPlanData: hour_ids
using ..ContingencyData: ContingencyEvent

export is_solved, congestion_report, solve_summary, write_csv, redispatch_volumes,
       overload_report, load_shedding_report, spillage_report, pipeline_report

"""
    pipeline_report(data, monitored)

The `report` of a solve of `data`, see `build_solution`, that holds what the
pipeline reads of it and no more: no node; the `monitored` edges, whose overload
[`overload_report`](@ref) reads, and the transformers with a phase shifter, whose
tap `freeze_dispatch` reads; every generator and storage unit, which
[`redispatch_volumes`](@ref), the shedding and spillage reports and
`freeze_dispatch` read.

Take it from the `data` the solve is run on, after the units it adds, so that those
are named too. Hold nothing less: a reader that tests with `haskey` takes what is
not held for what is not there, and says nothing.
"""
function pipeline_report(data::NetworkData, monitored::AbstractVector{Int})
    net     = network(data)
    shifter = [e for (e, c) in edges(net) if c isa Transformer && any(!=(FIXED), c.pst)]
    held    = [u for (u, c) in units(net) if c isa Union{AbstractGenerator,AbstractStorage}]

    return (; node = false, edge = sort!(union(monitored, shifter)), unit = sort!(held))
end

"""
    is_solved(result, n)

Whether `result` carries a solved network index `n` — false for one a rolling
horizon never reached because an earlier window came back infeasible and
stopped the roll (see `solve_rolling_horizon`'s `stopping the roll` warning),
which `haskey(result, "solution")` alone does not catch since that key is
present as soon as *any* window committed.
"""
is_solved(result::Dict{String,Any}, n::Int) =
    haskey(result, "solution") && haskey(result["solution"]["nw"], "$n")

"""
    congestion_report(data, result)

One row per (edge, hour) where the solved terminal flow exceeds `rate_a` (the
tighter winding's, for a transformer); `LoadFlowProblem` does not enforce it.

Empty, with the same columns, when `result` carries no solved values (e.g. an
infeasible solve) — there is nothing to report, not an error.
"""
function congestion_report(data::NetworkData, result::Dict{String,Any})
    rows = NamedTuple{(:edge, :hour, :flow_pu, :rate_a_pu, :overload_pu),
                      Tuple{Int,Int,Float64,Float64,Float64}}[]
    haskey(result, "solution") || return DataFrame(rows)

    net   = network(data)
    hours = hour_ids(data)
    for e in ids(net, AbstractEdge)
        rate = minimum(edges(net)[e].rate_a)
        isfinite(rate) || continue
        for n in nw_ids(data)
            is_solved(result, n) || continue
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

"write `df` to `path`, creating parent directories as needed"
function write_csv(path::AbstractString, df::DataFrame)
    mkpath(dirname(path))
    CSV.write(path, df)

    return nothing
end

"""
    redispatch_volumes(data, result)

Redispatch volumes of every generator and storage unit, one row per (unit,
hour), at the base case only.

Every measure here is preventive, so its volumes are identical across every
contingency (`constraint_redispatch_control`); the base case is the whole story
and reporting only it keeps this from being one row per (unit, hour,
contingency) — except a load-shedding generator, which is corrective: its row
here is only its base-case volume, see [`load_shedding_report`](@ref) for what
it sheds per contingency.

Empty, with the same columns, when `result` carries no solved values.
"""
function redispatch_volumes(data::NetworkData, result::Dict{String,Any})
    rows = NamedTuple{(:unit, :type, :hour, :up, :down),
                      Tuple{Int,String,Int,Float64,Float64}}[]
    haskey(result, "solution") || return DataFrame(rows)

    hours = hour_ids(data)
    for n in nw_ids(data; contingency = 1)
        is_solved(result, n) || continue
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

One row per (edge, hour, contingency) where a monitored edge's rating was priced
rather than enforced and the solved overload is non-zero: how far past its
rating the edge ran, and — where the network index sits at a contingency rather
than the base case — which member of `events` was on outage when it happened
(contingency `k + 1` is `events[k]` out).

Empty, with the same columns, when `result` carries no solved values.
"""
function overload_report(data::NetworkData, result::Dict{String,Any}, events::Vector{ContingencyEvent})
    rows = NamedTuple{(:edge, :name, :hour, :contingency, :outaged_event, :outaged_category, :overload_pu),
                      Tuple{Int,String,Int,Int,Union{Missing,String},Union{Missing,Symbol},Float64}}[]
    haskey(result, "solution") || return DataFrame(rows)

    dim   = dimension(data)
    net   = network(data)
    hours = hour_ids(data)
    for n in nw_ids(data)
        is_solved(result, n) || continue
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

One row per (node, hour, contingency) where a synthetic load-shedding generator
(`shed_ids`) shed a non-zero amount of demand — a **corrective** measure, so this
is what the operator would have done after that specific contingency
(`events[contingency - 1]`, `missing` at the base case).

Empty, with the same columns, when `result` carries no solved values.
"""
function load_shedding_report(data::NetworkData, result::Dict{String,Any},
                              shed_ids::Vector{Int}, events::Vector{ContingencyEvent})
    return _corrective_report(data, result, shed_ids, events, "pgup", :shed_pu)
end

"""
    spillage_report(data, result, spill_ids, events)

One row per (node, hour, contingency) where a synthetic spillage generator
(`spill_ids`) withdrew a non-zero amount of surplus generation — the mirror image
of [`load_shedding_report`](@ref), reading `pgdn` (the withdrawal) instead of
`pgup`. Also a **corrective** measure.

Empty, with the same columns, when `result` carries no solved values.
"""
function spillage_report(data::NetworkData, result::Dict{String,Any},
                         spill_ids::Vector{Int}, events::Vector{ContingencyEvent})
    return _corrective_report(data, result, spill_ids, events, "pgdn", :spilled_pu)
end

"the rows of a corrective relief valve: where `key` of one of `unit_ids` is non-zero, per node, hour and contingency"
function _corrective_report(data::NetworkData, result::Dict{String,Any}, unit_ids::Vector{Int},
                            events::Vector{ContingencyEvent}, key::String, column::Symbol)
    rows = NamedTuple{(:node, :hour, :contingency, :outaged_event, :outaged_category, column),
                      Tuple{Int,Int,Int,Union{Missing,String},Union{Missing,Symbol},Float64}}[]
    haskey(result, "solution") || return DataFrame(rows)

    hours = hour_ids(data)
    dim   = dimension(data)
    net   = network(data)
    for n in nw_ids(data)
        is_solved(result, n) || continue
        c   = coordinates(dim, n)
        sol = nw_solution(result, n)["unit"]
        for u in unit_ids
            haskey(sol, "$u") || continue
            volume = sol["$u"][key]
            volume > 1e-6 || continue
            ev = c.contingency == 1 ? missing : events[c.contingency - 1]
            push!(rows, merge((node = units(net)[u].node, hour = hours[c.time], contingency = c.contingency,
                               outaged_event = ismissing(ev) ? missing : ev.label,
                               outaged_category = ismissing(ev) ? missing : ev.category),
                              NamedTuple{(column,)}((volume,))))
        end
    end

    sort!(rows, by = r -> (r.node, r.hour, r.contingency))

    return DataFrame(rows)
end

end # module
