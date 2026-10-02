################################################################################
# ParallelRun.jl                                                              #
# Cutting a list of hours into chunks, solving the chunks on Julia threads,   #
# keeping one chunk's failure from taking the others with it, and not taking a#
# solver's word for a solution it has not checked.                            #
################################################################################

module ParallelRun

using HiGHS
using NetworkModelBuilder
using Xpress

const MOI  = NetworkModelBuilder.MOI
const JuMP = NetworkModelBuilder.JuMP

export chunk_hours, parallel_map, Failed, xpress_optimizer, xpress_model, highs_model,
       worst_violation, solve_checked

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

"""
    xpress_model(; threads = 1)
    highs_model()

A constructor of silent direct models, for `solve_rd`'s `new_model`: one is
built per window that cannot reuse the last. A direct model skips the copy JuMP
keeps before handing the problem over, which a roll would make once per window.
"""
xpress_model(; threads::Int = 1) = () -> begin
    m = JuMP.direct_model(Xpress.Optimizer())
    JuMP.set_silent(m)
    JuMP.set_attribute(m, "THREADS", threads)
    m
end

highs_model() = () -> begin
    m = JuMP.direct_model(HiGHS.Optimizer())
    JuMP.set_silent(m)
    m
end

"""
    worst_violation(nm; atol = 1e-3)

The largest amount by which the solution of the solved window `nm` breaks one of
its own constraints, or `0` if none by more than `atol`.

A solver's status says what it believes, not what it returned: Xpress has
reported `OPTIMAL` for a vector that breaks node balance by 30 per unit. `atol` is
0.1 MW on a 100 MVA base, far above what tolerance noise produces.
"""
function worst_violation(nm; atol::Float64 = 1e-3)
    report = JuMP.primal_feasibility_report(nm.model; atol)

    return isempty(report) ? 0.0 : maximum(values(report))
end

"""
    solve_checked(data, redispatch; horizon, step, primary, fallback, tol = 1e-3)

`solve_rd` of `data` rolled `step` hours at a time over `horizon`, with every
window's model checked against its own constraints once it is solved, see
[`worst_violation`](@ref).

If the roll is not `OPTIMAL`, or any window breaks a constraint by more than
`tol`, it is solved again with `fallback`. `primary` and `fallback` are model
constructors, see [`xpress_model`](@ref).

Returns a `NamedTuple`: the `result`, the `solver` that produced it
(`"primary"` or `"fallback"`), whether it was `retried`, the `status` of the
result returned, its `worst_violation`, and what the first attempt had said
(`first_status`, `first_violation`).
"""
function solve_checked(data, redispatch; horizon::Int, step::Int, primary, fallback, tol::Float64 = 1e-3)
    function attempt(model, optimizer)
        worst = Ref(0.0)
        check = (nm, sol) -> haskey(sol, "solution") && (worst[] = max(worst[], worst_violation(nm)))
        result = solve_rd(data, LPFFormulation, optimizer; redispatch, horizon, step,
                          reuse = true, warm_start = false, new_model = model,
                          solution_processors = [check])

        return result, worst[]
    end
    sound(result, worst) = result["termination_status"] == MOI.OPTIMAL && worst <= tol

    result, worst = attempt(primary, Xpress.Optimizer)
    sound(result, worst) &&
        return (result = result, solver = "primary", retried = false,
                status = string(result["termination_status"]), worst_violation = worst,
                first_status = string(result["termination_status"]), first_violation = worst)

    first_status, first_violation = string(result["termination_status"]), worst
    result, worst = attempt(fallback, HiGHS.Optimizer)

    return (result = result, solver = "fallback", retried = true,
            status = string(result["termination_status"]), worst_violation = worst,
            first_status = first_status, first_violation = first_violation)
end

end # module
