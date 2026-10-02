################################################################################
# PipelineReports.jl                                                          #
# What the LongTermSteeringPlan pipeline writes about a solve: a summary and  #
# the edges whose solved flow went past their rating. Every report names the  #
# hour of the year, not the position along `:time`, see `hour_ids`.           #
################################################################################

module PipelineReports

using CSV
using DataFrames
using Dates
using NetworkModelBuilder
using ..SteeringPlanData: hour_ids

export is_solved, congestion_report, solve_summary, write_csv

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

One row per (edge, hour) where the solved terminal flow exceeds `rate_a`;
`LoadFlowProblem` does not enforce it.

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
        rate = edges(net)[e].rate_a
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

end # module
