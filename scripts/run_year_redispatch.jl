################################################################################
# run_year_redispatch.jl                                                      #
# The LongTermSteeringPlan redispatch pipeline over any range of hours of the #
# year, solved in chunks of hours on Julia threads: no hour depends on        #
# another here (storage is excluded, nothing ramps), so a chunk solves exactly#
# as it would inside the whole.                                               #
#                                                                              #
# Run with several threads, e.g. `julia --project=scripts -t 16              #
# scripts/run_year_redispatch.jl`. Settings are read from the environment:    #
#   NMB_HOURS ("1:168"), NMB_RUN_ID, NMB_CHUNK_HOURS (24), NMB_NTASKS         #
#   (threads), NMB_XPRESS_THREADS (1, threads Xpress uses within one solve).  #
#                                                                              #
# So far: 1. load flow at market-cleared dispatch.                            #
################################################################################

haskey(ENV, "XPRESSDIR") || (ENV["XPRESSDIR"] = raw"C:\xpressmp")

using NetworkModelBuilder
using Xpress
using DataFrames

const MOI = NetworkModelBuilder.MOI

include(joinpath(@__DIR__, "SteeringPlanData.jl"))
using .SteeringPlanData

include(joinpath(@__DIR__, "PipelineReports.jl"))
using .PipelineReports

include(joinpath(@__DIR__, "ParallelRun.jl"))
using .ParallelRun

################################################################################
# Configuration                                                              #
################################################################################

const DATA_DIR = raw"D:\TVA\LongTermSteeringPlan\Data\Clean"

const HOURS = let (a, b) = parse.(Int, split(get(ENV, "NMB_HOURS", "1:168"), ':'))
    a:b
end
const RUN_ID         = get(ENV, "NMB_RUN_ID", "_year_scratch")
const OUT_DIR        = joinpath(@__DIR__, "..", "runs", RUN_ID)
const CHUNK_HOURS    = parse(Int, get(ENV, "NMB_CHUNK_HOURS", "24"))
const NTASKS         = parse(Int, get(ENV, "NMB_NTASKS", string(Threads.nthreads())))
const XPRESS_THREADS = parse(Int, get(ENV, "NMB_XPRESS_THREADS", "1"))

Threads.nthreads() == 1 &&
    @warn "running on one thread: start Julia with `-t N` for the chunks to solve in parallel"

################################################################################
# Step 1 — load flow at market-cleared dispatch                              #
################################################################################

"the load flow of `hours`, with its summary and the edges past their rating"
function step1_chunk(data::NetworkData, hours::Vector{Int}, optimizer)
    d      = select_hours(data, hours)
    result = solve_lf(d, LPFFormulation, optimizer)

    return (hours = extrema(hours), summary = solve_summary(result),
            congestion = congestion_report(d, result))
end

println("[1/3] loading network data for hours $HOURS ...")
data = load_network(DATA_DIR; hours = HOURS, baseMVA = 100.0)

chunks    = chunk_hours(collect(HOURS), CHUNK_HOURS)
optimizer = xpress_optimizer(threads = XPRESS_THREADS)

println("[1/3] solving the load flow over $(length(chunks)) chunk(s) of up to $CHUNK_HOURS ",
        "hour(s) on $NTASKS task(s) ...")
elapsed = @elapsed results = parallel_map(h -> step1_chunk(data, h, optimizer), chunks;
                                          ntasks = NTASKS)

chunk_summary = DataFrame(first_hour = Int[], last_hour = Int[], termination_status = String[],
                          objective = Float64[], solve_time = Float64[], n_overloads = Int[],
                          error = String[])
for (c, r) in zip(chunks, results)
    if r isa Failed
        push!(chunk_summary, (first(c), last(c), "ERROR", NaN, NaN, 0, first(r.message, 300)))
    else
        s = r.summary
        push!(chunk_summary, (r.hours..., s.termination_status[1], s.objective[1],
                              s.solve_time[1], nrow(r.congestion), ""))
    end
end

solved     = [r.congestion for r in results if !(r isa Failed)]
congestion = isempty(solved) ? DataFrame() : vcat(solved...)
nrow(congestion) > 0 && sort!(congestion, [:edge, :hour])

dir1 = joinpath(OUT_DIR, "01_market_lf")
write_csv(joinpath(dir1, "chunks.csv"), chunk_summary)
write_csv(joinpath(dir1, "congestion.csv"), congestion)

bad = chunk_summary[chunk_summary.termination_status .!= string(MOI.OPTIMAL), :]
println("[1/3] ", nrow(chunk_summary) - nrow(bad), " of ", nrow(chunk_summary),
        " chunk(s) OPTIMAL in ", round(elapsed, digits = 1), " s; ", nrow(congestion),
        " (edge, hour) overload(s) over ",
        nrow(congestion) > 0 ? length(unique(congestion.hour)) : 0, " hour(s)")
isempty(bad) ||
    error("[1/3] $(nrow(bad)) chunk(s) did not solve to OPTIMAL, see $(joinpath(dir1, "chunks.csv"))")

println("done — outputs written under ", OUT_DIR)
