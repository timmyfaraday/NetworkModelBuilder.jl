################################################################################
# ParallelRun.jl                                                              #
# Cutting a list of hours into chunks, solving the chunks on Julia threads,   #
# and keeping one chunk's failure from taking the others with it.             #
################################################################################

module ParallelRun

using NetworkModelBuilder
using Xpress

const MOI  = NetworkModelBuilder.MOI
const JuMP = NetworkModelBuilder.JuMP

export chunk_hours, parallel_map, Failed, xpress_optimizer

"""
    chunk_hours(hours, size) -> Vector{Vector{Int}}

`hours` cut into consecutive pieces of at most `size` hours each.
"""
chunk_hours(hours::AbstractVector{Int}, size::Int) =
    [collect(c) for c in Iterators.partition(hours, size)]

"""
    Failed(message)

What [`parallel_map`](@ref) returns in place of a result when `f` threw: the
error and its backtrace, kept as text.
"""
struct Failed
    message::String
end

"""
    parallel_map(f, items; ntasks = Threads.nthreads()) -> Vector

`f` applied to every item of `items` on up to `ntasks` threads, results in the
order of `items`. An item for which `f` throws gives a [`Failed`](@ref) rather
than stopping the others.

The items are handed out one at a time as a task frees up, so chunks of uneven
cost do not leave a thread idle behind a fixed share.
"""
function parallel_map(f, items; ntasks::Int = Threads.nthreads())
    out  = Vector{Any}(undef, length(items))
    next = Threads.Atomic{Int}(1)

    @sync for _ in 1:min(ntasks, length(items))
        Threads.@spawn while true
            k = Threads.atomic_add!(next, 1)
            k > length(items) && break
            out[k] = try
                f(items[k])
            catch e
                Failed(sprint(showerror, e, catch_backtrace()))
            end
        end
    end

    return out
end

"""
    xpress_optimizer(; threads = 1)

Xpress, silent, using `threads` threads of its own for one solve.

Left alone Xpress takes every core for each solve, so several solves running at
once would fight over them; the share per solve is set here instead.
"""
xpress_optimizer(; threads::Int = 1) =
    JuMP.optimizer_with_attributes(Xpress.Optimizer, MOI.Silent() => true, "THREADS" => threads)

end # module
