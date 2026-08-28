################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.5.0 - initial implementation                                              #
################################################################################

################################################################################
# Rolling horizon                                                              #
################################################################################

"""
    solve_rolling_horizon(data, P, F, optimizer; horizon, step = 1, kwargs...)

Solve `data` as a sequence of overlapping problems along `:time` rather than as
one problem over the whole of it, and return a single solution covering every
time step.

Each window looks `horizon` steps ahead, **commits** the first `step` of them,
and hands whatever its components carry — the state of charge of a
[`Storage`](@ref) unit, and nothing else in this package, see
[`initial_state`](@ref) — to the next window, which starts `step` steps later.
The windows at the end of the problem see less than `horizon` ahead, because
there is less future left for them to see. With
`horizon = step = dim_length(data, :time)` there is a single window and the
result is that of [`solve_model`](@ref).

This is how an operator actually runs a redispatch: the day is not decided at
once from a schedule known in full, it is decided step by step against a
forecast that reaches only so far. The lookahead is what stops each step from
being myopic — a battery that cannot see the evening peak empties itself into
the afternoon — and committing only `step` of it is what admits that the
forecast beyond the next step will have changed by the time it arrives.

# What is solved, and what is reported

Every window is a complete problem `P` in formulation `F` over its own slice,
cut by [`window`](@ref): the same physics, the same limits, the same objective.
What differs is only that its answer is kept for the committed steps and thrown
away for the rest, which is what the lookahead is for.

The result is shaped like any other, keyed by the network indices of `data`, so
[`nw_solution`](@ref) reaches a step by the index it has in the original
problem. Its `"objective"` is the cost of the **committed** steps only, summed
through [`network_cost`](@ref); a window's own objective, which prices its
lookahead too, is under `"horizon"`, along with what each window covered and
committed.

# Arguments
- `horizon`: how many time steps a window sees. Must be at least `step`.
- `step`: how many of them it commits, one by default.

Remaining keyword arguments reach [`instantiate_model`](@ref) and
[`optimize_model!`](@ref), as they do for [`solve_model`](@ref).

!!! note "A flexible load keeps its energy per window"
    The energy balance of a [`FlexibleLoad`](@ref) holds over the horizon it is
    posed on, so in a rolling solve it holds over each **window** rather than
    over the whole problem. With the default `energy = NaN` that is what should
    happen — the target is the nominal energy of the window itself — but an
    `energy` given explicitly is read as a per-window target, not a per-day one.

# Examples
```julia
julia> result = solve_rolling_horizon(mn, RedispatchProblem, LPFFormulation, HiGHS.Optimizer;
                                      horizon = 6, step = 1);

julia> result["objective"]              # the committed cost over the whole day

julia> nw_solution(result, 17)["unit"]["3"]["pgup"]
```
"""
function solve_rolling_horizon(data::NetworkData, ::Type{P}, ::Type{F}, optimizer;
                               horizon::Int, step::Int = 1,
                               solution_processors = [], kwargs...
                              ) where {P<:AbstractProblemType,F<:AbstractFormulationType}
    has_dim(data, :time) ||
        throw(ArgumentError("a rolling horizon runs along `:time`, but this problem has no " *
                            "such dimension; give it one with " *
                            "`set_dimension(data, Dimension(:time => n))`"))

    steps = dim_length(data, :time)
    horizon >= 1 || throw(ArgumentError("`horizon` must be at least one, got $horizon"))
    step    >= 1 || throw(ArgumentError("`step` must be at least one, got $step"))
    step <= horizon ||
        throw(ArgumentError("a window commits `step = $step` of the `horizon = $horizon` it sees, which is more than it has"))
    horizon <= steps ||
        throw(ArgumentError("`horizon = $horizon` reaches past the $steps time step(s) of this problem"))

    state    = _rolling_state(data)
    solution = Dict{String,Any}()
    windows  = Vector{Dict{String,Any}}()
    cost     = 0.0
    elapsed  = 0.0

    for first in 1:step:steps
        last      = min(first + horizon - 1, steps)
        committed = first:min(first + step - 1, steps)

        nm = instantiate_model(window(state, :time, first:last), P, F; kwargs...)
        optimize_model!(nm, optimizer; solution_processors)

        record = Dict{String,Any}(
            "first"              => first,
            "last"               => last,
            "committed"          => collect(committed),
            "termination_status" => nm.sol["termination_status"],
            "solve_time"         => nm.sol["solve_time"])
        elapsed += nm.sol["solve_time"]

        if !haskey(nm.sol, "solution")
            push!(windows, record)
            @warn "the window over time steps $first to $last returned no solution, " *
                  "stopping the roll at time step $(first - 1)"
            break
        end

        record["objective"] = nm.sol["objective"]
        push!(windows, record)

        # keep what the window committed, under the network indices it came from
        kept = window_indices(state, :time, first:last)
        for m in nw_ids(nm)
            coordinates(nm, m).time in 1:length(committed) || continue
            solution["$(kept[m])"] = nm.sol["solution"]["nw"]["$m"]
            cost += network_weight(nm, m) * _value(network_cost(nm, m))
        end

        first + step <= steps && _carry_state!(state, nm, length(committed))
    end

    result = Dict{String,Any}(
        "name"               => data.name,
        "baseMVA"            => baseMVA(data),
        "problem_type"       => P,
        "formulation_type"   => F,
        "termination_status" => _rolling_status(windows),
        "primal_status"      => JuMP.FEASIBLE_POINT,
        "dual_status"        => JuMP.NO_SOLUTION,
        "solve_time"         => elapsed,
        "objective"          => cost,
        "horizon"            => Dict{String,Any}("horizon" => horizon, "step" => step,
                                                 "window"  => windows))

    isempty(solution) || (result["solution"] = Dict{String,Any}("nw" => solution))

    return result
end

solve_rolling_horizon(file::AbstractString, P::Type, F::Type, optimizer; kwargs...) =
    solve_rolling_horizon(parse_file(file), P, F, optimizer; kwargs...)

"""
    _rolling_state(data)

A copy of `data` for the roll to write the carried state into, so that the data
set the caller handed in is left as it was.
"""
_rolling_state(data::NetworkData) =
    NetworkData(Network(deepcopy(nodes(network(data))), deepcopy(edges(network(data))),
                        deepcopy(units(network(data)));
                        dim = dimension(data), ext = deepcopy(network(data).ext));
                name = data.name, baseMVA = baseMVA(data), ext = deepcopy(data.ext))

"""
    _carry_state!(state, nm, committed)

Write what every component of `state` carries out of the window `nm` into
`state`, ready for the next window.

The state is read at the **last committed** time step of the base case, i.e., at
the first coordinate of every dimension other than `:time`. That is a modelling
choice, and the only one available: the windows form a single trajectory through
time, and only one of the contingencies is the world that actually happened. A
preventive measure leaves the same state behind in every state of the world in
any case; a corrective one does not, and the base case is the one that is real.
"""
function _carry_state!(state::NetworkData, nm::NetworkModel, committed::Int)
    net = network(state)
    n   = similar_id(nm, nw_id_default(nm); time = committed)

    for (i, c) in nodes(net); net.node[i] = initial_state(c, nm, n) end
    for (e, c) in edges(net); net.edge[e] = initial_state(c, nm, n) end
    for (u, c) in units(net); net.unit[u] = initial_state(c, nm, n) end

    return nothing
end

"the status of a roll: the first window that did not solve, or the status they agree on"
function _rolling_status(windows::Vector{Dict{String,Any}})
    isempty(windows) && return JuMP.OPTIMIZE_NOT_CALLED

    solved = (JuMP.OPTIMAL, JuMP.LOCALLY_SOLVED)
    bad    = findfirst(w -> w["termination_status"] ∉ solved, windows)

    return bad === nothing ? first(windows)["termination_status"] :
                             windows[bad]["termination_status"]
end
