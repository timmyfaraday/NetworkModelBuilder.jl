################################################################################
# run_year_redispatch.jl                                                      #
# The LongTermSteeringPlan three-step redispatch pipeline over any range of   #
# hours of the year:                                                          #
#   1. load flow at market-cleared dispatch                                   #
#   2. cross-border N-1 redispatch, reference = raw market data               #
#   3. internal-BE N-1 redispatch, reference = step 2's solved dispatch       #
#                                                                             #
# It is solved in chunks of hours on Julia threads. No hour depends on        #
# another here (storage is excluded, nothing ramps), so a chunk solves exactly#
# as it would inside the whole, and a chunk runs all three steps for its hours#
# before the next one starts. Each chunk writes its own files and a DONE      #
# marker, so an interrupted run resumes where it stopped.                     #
#                                                                             #
# Run with several threads, e.g. `julia --project=scripts -t 48               #
# scripts/run_year_redispatch.jl`. Settings are read from the environment:    #
#   NMB_HOURS ("1:168"), NMB_RUN_ID, NMB_CHUNK_HOURS (24), NMB_NTASKS         #
#   (threads), NMB_XPRESS_THREADS (2, threads Xpress uses within one solve),  #
#   NMB_RESUME ("0"; "1" skips the chunks already done), NMB_MERGE ("1";      #
#   "0" writes the chunks only, no merged files).                             #
#   NMB_HORIZON_CB (8), NMB_STEP_CB (8), NMB_HORIZON_BE (1), NMB_STEP_BE (1): #
#   hours a window of step 2 / step 3 sees and how many it commits; a chunk   #
#   shorter than the horizon caps it, so set NMB_CHUNK_HOURS to at least it.  #
#                                                                             #
# More threads in one process stop paying off at a handful of tasks: the      #
# garbage collector and the allocator are shared. To use the whole machine    #
# run many one-thread processes, each on its own range of hours with a shared #
# NMB_RUN_ID and NMB_MERGE=0, then one last run over the full range with      #
# NMB_RESUME=1, which finds every chunk done and only merges them.            #
################################################################################

haskey(ENV, "XPRESSDIR") || (ENV["XPRESSDIR"] = raw"C:\xpressmp")

using CSV
using DataFrames
using NetworkModelBuilder
using Xpress

const MOI = NetworkModelBuilder.MOI

include(joinpath(@__DIR__, "SteeringPlanData.jl"))
using .SteeringPlanData

include(joinpath(@__DIR__, "ContingencyData.jl"))
using .ContingencyData

include(joinpath(@__DIR__, "Contingencies.jl"))
using .Contingencies

include(joinpath(@__DIR__, "PipelineReports.jl"))
using .PipelineReports

include(joinpath(@__DIR__, "ParallelRun.jl"))
using .ParallelRun

################################################################################
# Configuration                                                              #
################################################################################

const DATA_DIR         = raw"D:\TVA\LongTermSteeringPlan\Data\Clean"
const CONTINGENCY_XLSX = raw"O:\ESM\IPL\SMA\C_Studies\52_ZORBA\02_Input\LT_steering_data\LTSteering_Structuur_SMA_v3_EME.xlsx"

const HOURS = let (a, b) = parse.(Int, split(get(ENV, "NMB_HOURS", "1:168"), ':'))
    a:b
end
const RUN_ID         = get(ENV, "NMB_RUN_ID", "_year_scratch")
const OUT_DIR        = joinpath(@__DIR__, "..", "runs", RUN_ID)
const CHUNK_HOURS    = parse(Int, get(ENV, "NMB_CHUNK_HOURS", "24"))
const NTASKS         = parse(Int, get(ENV, "NMB_NTASKS", string(Threads.nthreads())))
const XPRESS_THREADS = parse(Int, get(ENV, "NMB_XPRESS_THREADS", "2"))
const RESUME         = get(ENV, "NMB_RESUME", "0") == "1"
const MERGE          = get(ENV, "NMB_MERGE", "1") == "1"

# a window looks `HORIZON` hours ahead and commits `STEP` of them; with no coupling between
# hours that changes only how big a model is and how often one is built
const HORIZON_CB = parse(Int, get(ENV, "NMB_HORIZON_CB", "8"))
const STEP_CB    = parse(Int, get(ENV, "NMB_STEP_CB", "8"))
const HORIZON_BE = parse(Int, get(ENV, "NMB_HORIZON_BE", "1"))
const STEP_BE    = parse(Int, get(ENV, "NMB_STEP_BE", "1"))

# a solution that breaks one of its own constraints by more than this is not trusted
const VIOLATION_TOL = 1e-3

# The costliest redispatch in the data is the thermal ceiling, 477 $/MWh = 47,700 $/pu
# at `baseMVA = 100`. Each last-resort price clears the one below it: overloading a
# monitored line costs 10x that ceiling, dumping surplus generation 5x the overload price,
# and shedding real demand 10x the overload price, so demand is the very last thing to go.
const OVERLOAD_PRICE      = OverloadPrice(; per_energy = 10 * 47_700.0)
const LOAD_SHEDDING_PRICE = 10 * OVERLOAD_PRICE.per_energy
const SPILLAGE_PRICE      = 5 * OVERLOAD_PRICE.per_energy

Threads.nthreads() == 1 &&
    @warn "running on one thread: start Julia with `-t N` for the chunks to solve in parallel"

################################################################################
# Setup shared by every chunk                                                #
################################################################################

println("[setup] loading network data for hours $HOURS ...")
data = load_network(DATA_DIR; hours = HOURS, baseMVA = 100.0)

println("[setup] loading Elia's N-1 study contingency events ...")
raw_events           = load_contingency_events(CONTINGENCY_XLSX)
events, event_report = resolve_contingency_events(data, raw_events)

cb_events = filter(ev -> touches(cross_border, data, ev), events)
be_events = filter(ev -> !touches(cross_border, data, ev), events)

cb_monitored = sort!(unique(reduce(vcat, (ev.edges for ev in cb_events); init = Int[])))
be_monitored = sort!(unique(reduce(vcat, (ev.edges for ev in be_events); init = Int[])))
monitored_all = sort!(unique(vcat(cb_monitored, be_monitored)))

# an event whose combined outage disconnects the graph cannot be redispatched around
# and gets no contingency of its own, but its edges are still monitored
cb_contingency, cb_excluded = contingency_events(network(data), cb_events)
be_contingency, be_excluded = contingency_events(network(data), be_events)

println("[setup] ", length(events), " event(s) resolved: ", length(cb_contingency), " cross-border and ",
        length(be_contingency), " internal contingencies (", length(cb_excluded) + length(be_excluded),
        " excluded as bridges)")

excluded_table(excluded) = DataFrame(label = getproperty.(excluded, :label),
                                     category = getproperty.(excluded, :category),
                                     edges = [join(ev.edges, ";") for ev in excluded])
if MERGE
    write_csv(joinpath(OUT_DIR, "00_contingencies", "events.csv"), event_report)
    write_csv(joinpath(OUT_DIR, "02_cross_border_redispatch", "excluded_bridge_edges.csv"), excluded_table(cb_excluded))
    write_csv(joinpath(OUT_DIR, "03_internal_redispatch", "excluded_bridge_edges.csv"), excluded_table(be_excluded))
end

const ROW_FIELDS = (:first_hour, :last_hour,
                    :step1_status, :step1_s,
                    :step2_status, :step2_solver, :step2_first_status, :step2_first_violation,
                    :step2_violation, :step2_s, :step2_solve_s, :step2_windows, :step2_built,
                    :step3_status, :step3_solver, :step3_first_status, :step3_first_violation,
                    :step3_violation, :step3_s, :step3_solve_s, :step3_windows, :step3_built,
                    :sound, :seconds, :maxrss_gb, :error)

chunk_dir(hours) = joinpath(OUT_DIR, "chunks",
                            "h$(lpad(first(hours), 5, '0'))-$(lpad(last(hours), 5, '0'))")

"whether a checked solve is `OPTIMAL` and breaks none of its own constraints"
is_sound(run) = run.status == string(MOI.OPTIMAL) && run.worst_violation <= VIOLATION_TOL

"`summary` of a solve with the hours it covered in front"
summary_of(hours, result) =
    hcat(DataFrame(first_hour = first(hours), last_hour = last(hours)), solve_summary(result))

################################################################################
# One chunk: all three steps for its hours                                   #
################################################################################

"""
    run_chunk(data, hours) -> Dict

Run the three steps for `hours` and write what they found under `chunk_dir(hours)`.
The chunk is redone whole if it is run again, never patched. A step that does not
come back sound stops the chunk there, since the next step reads its answer.
"""
function run_chunk(data::NetworkData, hours::Vector{Int})
    started = time()
    dir     = chunk_dir(hours)
    isdir(dir) && rm(dir; recursive = true)
    mkpath(dir)

    T   = length(hours)
    row = Dict{Symbol,Any}(:first_hour => first(hours), :last_hour => last(hours), :sound => false)

    try
        d1 = select_hours(data, hours)

        # step 1 — load flow at market-cleared dispatch
        t = time()
        result1 = solve_lf(d1, LPFFormulation, xpress_optimizer(threads = XPRESS_THREADS))
        write_csv(joinpath(dir, "01_congestion.csv"), congestion_report(d1, result1))
        row[:step1_status] = string(result1["termination_status"])
        row[:step1_s]      = round(time() - t, digits = 1)
        result1["termination_status"] == MOI.OPTIMAL ||
            error("step 1 finished with status $(row[:step1_status])")

        # step 2 — cross-border N-1 redispatch, storage excluded
        t   = time()
        d2  = with_contingencies(exclude_all_storage!(d1), cb_contingency)
        rd2 = Redispatch(; monitored = cb_monitored, control = :preventive, overload = OVERLOAD_PRICE)
        run2 = solve_checked(d2, rd2; horizon = min(HORIZON_CB, T), step = min(STEP_CB, T),
                             primary = xpress_model(threads = XPRESS_THREADS), fallback = highs_model(),
                             tol = VIOLATION_TOL, report = pipeline_report(d2, cb_monitored))
        result2 = run2.result
        write_csv(joinpath(dir, "02_summary.csv"), summary_of(hours, result2))
        write_csv(joinpath(dir, "02_redispatch_volumes.csv"), redispatch_volumes(d2, result2))
        write_csv(joinpath(dir, "02_overload.csv"), overload_report(d2, result2, cb_contingency))
        row[:step2_status]          = run2.status
        row[:step2_solver]          = run2.solver
        row[:step2_first_status]    = run2.first_status
        row[:step2_first_violation] = run2.first_violation
        row[:step2_violation]       = run2.worst_violation
        row[:step2_s]               = round(time() - t, digits = 1)
        row[:step2_solve_s]         = round(result2["solve_time"], digits = 1)
        row[:step2_windows]         = length(result2["horizon"]["window"])
        row[:step2_built]           = result2["horizon"]["built"]
        is_sound(run2) ||
            error("step 2 finished with status $(run2.status) and violation $(run2.worst_violation)")

        # step 3 — internal-BE N-1 redispatch, reference = step 2's dispatch
        t  = time()
        d3 = freeze_dispatch(d1, result2)
        d3 = restrict_to_belgium!(d3)
        # with every non-BE unit pinned and storage gone the balance can come up short
        # or long at some hour; these are the relief valves, last resort and corrective
        d3 = add_load_shedding!(d3; price = LOAD_SHEDDING_PRICE)
        shed_ids = load_shedding_ids(d3)
        d3 = add_spillage!(d3; price = SPILLAGE_PRICE)
        spill_ids = spillage_ids(d3)
        d3 = with_contingencies(d3, be_contingency)
        exception = Dict{Tuple{Symbol,Int},Symbol}((:unit, id) => :corrective
                                                   for id in vcat(shed_ids, spill_ids))
        rd3  = Redispatch(; monitored = monitored_all, control = :preventive, exception,
                          overload = OVERLOAD_PRICE)
        run3 = solve_checked(d3, rd3; horizon = min(HORIZON_BE, T), step = min(STEP_BE, T),
                             primary = xpress_model(threads = XPRESS_THREADS), fallback = highs_model(),
                             tol = VIOLATION_TOL, report = pipeline_report(d3, monitored_all))
        result3 = run3.result
        write_csv(joinpath(dir, "03_summary.csv"), summary_of(hours, result3))
        write_csv(joinpath(dir, "03_redispatch_volumes.csv"), redispatch_volumes(d3, result3))
        write_csv(joinpath(dir, "03_overload.csv"), overload_report(d3, result3, be_contingency))
        write_csv(joinpath(dir, "03_load_shedding.csv"),
                  load_shedding_report(d3, result3, shed_ids, be_contingency))
        write_csv(joinpath(dir, "03_spillage.csv"), spillage_report(d3, result3, spill_ids, be_contingency))
        row[:step3_status]          = run3.status
        row[:step3_solver]          = run3.solver
        row[:step3_first_status]    = run3.first_status
        row[:step3_first_violation] = run3.first_violation
        row[:step3_violation]       = run3.worst_violation
        row[:step3_s]               = round(time() - t, digits = 1)
        row[:step3_solve_s]         = round(result3["solve_time"], digits = 1)
        row[:step3_windows]         = length(result3["horizon"]["window"])
        row[:step3_built]           = result3["horizon"]["built"]
        is_sound(run3) ||
            error("step 3 finished with status $(run3.status) and violation $(run3.worst_violation)")

        row[:sound] = true
    catch e
        row[:error] = first(sprint(showerror, e), 300)
    end

    row[:seconds]   = round(time() - started, digits = 1)
    row[:maxrss_gb] = round(Sys.maxrss() / 2^30, digits = 1)
    write_chunk_row(dir, row)
    row[:sound] && write(joinpath(dir, "DONE"), "")

    println("[chunk $(first(hours))-$(last(hours))] ", row[:sound] ? "sound" : "NOT SOUND",
            " in $(row[:seconds]) s",
            haskey(row, :step2_solver) && row[:step2_solver] == "fallback" ? ", step 2 on the fallback solver" : "",
            haskey(row, :step3_solver) && row[:step3_solver] == "fallback" ? ", step 3 on the fallback solver" : "",
            haskey(row, :error) ? ": $(row[:error])" : "")

    return row
end

"write the one-row `chunk.csv` of a chunk with every field present, empty where a step never ran"
function write_chunk_row(dir::AbstractString, row::Dict{Symbol,Any})
    write_csv(joinpath(dir, "chunk.csv"),
              DataFrame([k => [get(row, k, missing)] for k in ROW_FIELDS]))

    return nothing
end

"the files `name` of every chunk of `chunks`, concatenated into `out` under one header"
function merge_csv(chunks, name::AbstractString, out::AbstractString)
    mkpath(dirname(out))
    open(out, "w") do io
        wrote_header = false
        for c in chunks
            file = joinpath(chunk_dir(c), name)
            isfile(file) || continue
            for (k, line) in enumerate(eachline(file))
                k == 1 && wrote_header && continue
                println(io, line)
            end
            wrote_header = true
        end
    end

    return nothing
end

################################################################################
# Run                                                                        #
################################################################################

chunks = chunk_hours(collect(HOURS), CHUNK_HOURS)
todo   = RESUME ? [c for c in chunks if !isfile(joinpath(chunk_dir(c), "DONE"))] : chunks

println("[run] ", length(todo), " of ", length(chunks), " chunk(s) of up to $CHUNK_HOURS hour(s) to solve on ",
        "$NTASKS task(s), $XPRESS_THREADS Xpress thread(s) each")
elapsed = @elapsed results = parallel_map(h -> run_chunk(data, h), todo; ntasks = NTASKS)

# a chunk whose task died without writing its own row still gets one
for (c, r) in zip(todo, results)
    r isa Failed || continue
    dir = chunk_dir(c)
    mkpath(dir)
    write_chunk_row(dir, Dict{Symbol,Any}(:first_hour => first(c), :last_hour => last(c),
                                          :sound => false, :error => first(r.message, 300)))
end

# one process of many sharing a run id leaves the merging to a last run over the full range
if !MERGE
    not_done = [c for c in todo if !isfile(joinpath(chunk_dir(c), "DONE"))]
    println("[run] ", length(todo) - length(not_done), " of ", length(todo), " chunk(s) sound; ",
            round(elapsed, digits = 1), " s, of which ",
            round(Base.gc_num().total_time / 1e9, digits = 1), " s of garbage-collection pauses")
    isempty(not_done) || error("[run] $(length(not_done)) chunk(s) are not sound, see $(joinpath(OUT_DIR, "chunks"))")
    println("done — chunks written under ", joinpath(OUT_DIR, "chunks"))
    exit(0)
end

merge_csv(chunks, "01_congestion.csv", joinpath(OUT_DIR, "01_market_lf", "congestion.csv"))
for (step_dir, prefix, names) in (("02_cross_border_redispatch", "02_",
                                   ("summary", "redispatch_volumes", "overload")),
                                  ("03_internal_redispatch", "03_",
                                   ("summary", "redispatch_volumes", "overload", "load_shedding", "spillage")))
    for name in names
        merge_csv(chunks, "$prefix$name.csv", joinpath(OUT_DIR, step_dir, "$name.csv"))
    end
end
merge_csv(chunks, "chunk.csv", joinpath(OUT_DIR, "chunks.csv"))

chunk_table = CSV.read(joinpath(OUT_DIR, "chunks.csv"), DataFrame)
unsound = chunk_table[.!coalesce.(chunk_table.sound, false), :]
retried = count(s -> !ismissing(s) && s == "fallback", chunk_table.step2_solver) +
          count(s -> !ismissing(s) && s == "fallback", chunk_table.step3_solver)
println("[run] ", nrow(chunk_table) - nrow(unsound), " of ", nrow(chunk_table), " chunk(s) sound; ",
        retried, " step(s) needed the fallback solver; ", round(elapsed, digits = 1), " s, of which ",
        round(Base.gc_num().total_time / 1e9, digits = 1), " s of garbage-collection pauses")
isempty(unsound) ||
    error("[run] $(nrow(unsound)) chunk(s) are not sound, see $(joinpath(OUT_DIR, "chunks.csv"))")

println("done — outputs written under ", OUT_DIR)
