################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.5.0 - initial implementation, including the rolling horizon               #
################################################################################

################################################################################
# Redispatch                                                                   #
################################################################################

"""
    build_model!(nm::NetworkModel{<:RedispatchProblem,<:IVRFormulation})
    build_model!(nm::NetworkModel{<:RedispatchProblem,<:LPFFormulation})

Build a redispatch in either formulation.

Compare this builder with the one in `src/prob/opf.jl`: it is the same list of
calls with one line added. The physics, the operating limits and the ratings of
an optimal power flow are exactly what a redispatch needs — a redispatch *is* a
dispatch problem, and the network does not care why the dispatch is being
chosen. What differs lives in the methods those calls resolve to and in the two
lines that are new:

| stage       | what is added                                                    |
|:------------|:-----------------------------------------------------------------|
| variables   | as in an optimal power flow, plus the volumes each generator and storage unit moved away from its market schedule |
| constraints | as in an optimal power flow, with the rating enforced on the monitored edges only, plus the split of each dispatch into its market schedule and those volumes |
| coupling    | one setting per preventive measure, shared by every contingency  |
| objective   | the price of the volumes moved, not the cost of the dispatch     |
"""
build_model!(nm::NetworkModel{P,F}) where {P<:RedispatchProblem,F<:IVRFormulation} = _build_redispatch!(nm)
build_model!(nm::NetworkModel{P,F}) where {P<:RedispatchProblem,F<:LPFFormulation} = _build_redispatch!(nm)

"""
    _build_redispatch!(nm)

The body both formulations share, the optimal power flow builder plus
[`constraint_redispatch_control`](@ref).

Every call in it is a dispatch point, so the definition of the problem says
nothing about the formulation it is being built in, and nothing about which
component types exist: an extension package that registers a controllable edge
or a costly unit is picked up here without this file changing.
"""
function _build_redispatch!(nm::NetworkModel)
    for n in nw_ids(nm)
        variable_node_voltage(nm; nw = n)
        variable_edge(nm; nw = n)
        variable_unit(nm; nw = n)

        constraint_node_voltage_reference(nm; nw = n)
        constraint_node_voltage_limits(nm; nw = n)
        constraint_node_balance(nm; nw = n)
        constraint_edge(nm; nw = n)
        constraint_edge_limits(nm; nw = n)
        constraint_unit(nm; nw = n)
    end

    constraint_edge_coupling(nm)
    constraint_unit_coupling(nm)
    constraint_redispatch_control(nm)

    objective(nm)

    return nm
end

register_model!(RedispatchProblem, IVRFormulation)
register_model!(RedispatchProblem, LPFFormulation)

################################################################################
# Redispatch — preventive and corrective measures                              #
################################################################################

"""
    constraint_redispatch_control(nm)

Hold every **preventive** measure equal across the contingencies,

```math
x_{c,n} = x_{c,n^{0}} \\quad
\\forall n \\in \\mathcal{N}, \\; \\forall x \\in X^{\\text{prev}}_{c} ,
```

where ``n^{0}`` is the network index that shares every coordinate of ``n`` but
sits at the first `:contingency` coordinate — the base case — and
``X^{\\text{prev}}_{c}`` is what [`redispatch_controls`](@ref) says component
``c`` controls.

That single family of equalities is the whole difference between a preventive
and a corrective measure. A preventive one is decided before anything happens
and has to serve every state, so it pays for outages that never occur; a
corrective one is what the operator does *after* a given outage, and is free per
contingency because it is only ever applied in the state it was chosen for. See
[`Redispatch`](@ref) for how to say which is which.

A no-op in a problem without a `:contingency` dimension, or with one that has a
single coordinate: there is then only one state, and nothing to be preventive
about. A measure at a network index where the component is out of service is
skipped, so a generator that is itself the contingency constrains nothing.
"""
function constraint_redispatch_control(nm::NetworkModel)
    has_dim(nm, :contingency) || return nothing
    dim_length(nm, :contingency) > 1 || return nothing

    tie = Dict{Tuple{Symbol,Int,Symbol,Int},Any}()

    for n in nw_ids(nm)
        is_first_id(nm, n, :contingency) && continue
        base = first_id(nm, n, :contingency)

        for (family, types) in ((:edge, edge_types()), (:unit, unit_types())), T in types
            controls = redispatch_controls(nm, T)
            isempty(controls) && continue

            at_base = ids(nm, T; nw = base)
            for id in ids(nm, T; nw = n)
                insorted(id, at_base) || continue
                is_preventive(nm, family, id) || continue

                for key in controls
                    x = _control_variable(nm, key, id, n)
                    y = _control_variable(nm, key, id, base)
                    (x === nothing || y === nothing) && continue
                    tie[(family, id, key, n)] = constrain!(nm, :redispatch_control,
                        (family, id, key), JuMP.@build_constraint(x == y); nw = n)
                end
            end
        end
    end

    nm.ext[:redispatch_control] = tie

    return nothing
end

"the variable registered under `key` for component `id` at network index `n`, or `nothing`"
function _control_variable(nm::NetworkModel, key::Symbol, id::Int, n::Int)
    container = var(nm; nw = n)
    haskey(container, key) || return nothing
    entry = container[key]

    return haskey(entry, id) ? entry[id] : nothing
end

################################################################################
# Redispatch — the objective                                                   #
################################################################################

"a redispatch minimizes the price of the measures it takes"
objective(nm::NetworkModel{P,F}) where {P<:RedispatchProblem,F} = objective_redispatch_cost(nm)

"""
    objective_redispatch_cost(nm)

Minimize the price of the volumes moved away from the market schedule,

```math
\\min \\quad \\sum_{n \\in \\mathcal{N}} w_{n} \\sum_{c}
    \\left( c^{\\uparrow}_{c} p^{\\uparrow}_{c,n}
          + c^{\\downarrow}_{c} p^{\\downarrow}_{c,n} \\right) ,
```

with ``w_{n}`` the weight of network index ``n``, see [`network_weight`](@ref),
and the sum running over every registered edge and unit type through
[`redispatch_cost`](@ref). A component with no method there — a
[`PhaseShifter`](@ref), a [`TapChanger`](@ref) — contributes nothing, which is
exactly what makes it a non-costly measure.

Every network index enters this sum, contingencies included, which is what makes
it an **expected** cost: a `:contingency` coordinate carries a weight of `1/N`
unless the data gives it one, see [`default_weight`](@ref). Under uniform
probabilities a preventive measure — one setting serving all `N` states — is
therefore paid for exactly once, and a corrective one only in the state it
belongs to.

Give the coordinates an explicit `:weight` wherever the contingencies are not
equally likely:

```julia
Dimension(:time => 24,
          :contingency => [Dict{Symbol,Any}(:weight => p) for p in (0.97, 0.02, 0.01)])
```
"""
objective_redispatch_cost(nm::NetworkModel) = minimize_network_cost(nm)

"""
    network_cost(nm, n)

The price of every measure taken at network index `n`, summed over every
registered edge and unit type through [`redispatch_cost`](@ref).
"""
function network_cost(nm::NetworkModel{P,F}, n::Int) where {P<:RedispatchProblem,F}
    total = JuMP.AffExpr(0.0)

    for (T, id) in ((T, id) for T in edge_types() for id in ids(nm, T; nw = n))
        JuMP.add_to_expression!(total, redispatch_cost(nm, T, id; nw = n))
    end
    for (T, id) in ((T, id) for T in unit_types() for id in ids(nm, T; nw = n))
        JuMP.add_to_expression!(total, redispatch_cost(nm, T, id; nw = n))
    end

    return total
end

################################################################################
# Redispatch — the pipeline                                                    #
################################################################################

"""
    solve_rd(data, F, optimizer; redispatch = Redispatch(), horizon = nothing, step = 1, warm_start = false, new_model, kwargs...)

Solve a [`RedispatchProblem`](@ref) in formulation `F`.

`redispatch` is the [`Redispatch`](@ref) setup, i.e., the monitored edges and
the split between preventive and corrective measures. It is placed in the `ext`
of the model, so `instantiate_model(data, RedispatchProblem, F;
ext = Dict{Symbol,Any}(:redispatch => rd))` is the equivalent that stops before
the solve.

Give it a `horizon` and it becomes a **rolling** redispatch: a sequence of
windows along `:time`, each looking `horizon` steps ahead and committing the
first `step` of them, rather than one problem decided over the whole horizon at
once. That is [`solve_rolling_horizon`](@ref), which is what this forwards to —
`step`, `warm_start` and `new_model` along with it — and the result is shaped the same either
way.

# Examples
```julia
julia> using HiGHS

julia> dim = Dimension(:time => 24, :contingency => 3);

julia> mn = set_dimension(data, dim; apply! = schedule!);

julia> result = solve_rd(mn, LPFFormulation, HiGHS.Optimizer;
                         redispatch = Redispatch(; monitored = [3, 7],
                                                   control   = :preventive));

julia> rolling = solve_rd(mn, LPFFormulation, HiGHS.Optimizer; horizon = 6);
```
"""
function solve_rd(data, ::Type{F}, optimizer; redispatch::Redispatch = Redispatch(),
                  ext::Dict{Symbol,Any} = Dict{Symbol,Any}(),
                                horizon::Union{Nothing,Int} = nothing, step::Int = 1,
                  warm_start::Bool = false, kwargs...
                 ) where {F<:AbstractFormulationType}
    ext = merge(ext, Dict{Symbol,Any}(:redispatch => redispatch))

    horizon === nothing &&
        return solve_model(data, RedispatchProblem, F, optimizer; ext, kwargs...)

    return solve_rolling_horizon(data, RedispatchProblem, F, optimizer;
                                 horizon, step, warm_start, ext, kwargs...)
end

################################################################################
# The rolling horizon                                                          #
################################################################################

# The roll below is *not* redispatch-specific: it takes the problem type as an
# argument and rolls an optimal power flow as readily. All it needs from a
# problem is `network_cost`, which is how it prices a committed step without
# knowing what it is rolling, and all it needs from a component is
# `initial_state`. It lives here because a redispatch is what it is for — an
# operator decides the day step by step against a forecast that reaches only so
# far — and because `solve_rd` is the entry point that forwards to it.

"""
    solve_rolling_horizon(data, P, F, optimizer; horizon, step = 1, warm_start = false, new_model = () -> JuMP.Model(), kwargs...)

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
- `warm_start`: hand each window the previous one's answer as a starting point.
  Off by default, and see the warning below for why.
- `new_model`: called once per window for the `JuMP.Model` that window is built
  in. A roll needs a *fresh* model each time, so it takes the constructor rather
  than the model — passing `jump_model` here would give every window the same
  one, and is refused.

Remaining keyword arguments reach [`instantiate_model`](@ref) and
[`optimize_model!`](@ref), as they do for [`solve_model`](@ref).

!!! tip "A direct model is worth having here"
    `JuMP.direct_model` skips the layer that caches a copy of the problem before
    handing it to the solver. For a roll that is the right trade: the copy is
    made once per window and thrown away with it, and on a year at
    `horizon = 24, step = 4` skipping it took the solver side from 3.0 s to
    1.7 s.

    ```julia
    solve_rolling_horizon(mn, RedispatchProblem, LPFFormulation, HiGHS.Optimizer;
                          horizon = 24, step = 4,
                          new_model = () -> (m = JuMP.direct_model(HiGHS.Optimizer());
                                             JuMP.set_silent(m); m))
    ```

    A direct model carries its own optimizer, so the `optimizer` argument is then
    only a fallback and is left unused. Not every solver supports direct mode.

!!! tip "Choose the solver before reaching for `warm_start`"
    Across a year at `horizon = 24, step = 4` — 2190 windows — solving is about
    two thirds of the work, building the models a quarter, and cutting the
    windows out under a twentieth. Which solver does that two thirds matters
    more than anything else here: a [`LPFFormulation`](@ref) redispatch is a
    linear program, and giving it to an LP solver rather than to an interior
    point method roughly halves the whole run and returns `OPTIMAL` rather than
    a status that says it nearly converged.

    `warm_start` is worth having where that choice is not available — a
    nonconvex [`IVRFormulation`](@ref) has no LP solver to be given to — and is
    not worth having once it is: on an LP solver the overlap it hands over saves
    less solver time than it costs to hand over.

!!! warning "A warm start can change the roll, even where every window is convex"
    Consecutive windows overlap in `horizon - step` of their steps, so most of
    what a window is asked is what the last one just answered. Handing that over
    as a starting point does not change what any one window's optimum *is* — but
    where a window has **several** optima it decides which of them comes back,
    and a roll is not one solve: the optimum that comes back is committed, its
    state is carried to the next window, and the whole trajectory downstream
    follows from it. Two rolls that differ only in their starting points can
    therefore end the year in different places, both of them correct.

    Whether that happens is a property of the data, not of the warm start: it
    needs a window whose answer is tied. A price that is flat across a window
    ties it, a price that differs at every step does not. Under an
    [`IVRFormulation`](@ref) there is the further ordinary caveat that a
    different starting point may converge to a different local solution, and on
    the network measured above it converged to a slightly worse one.

    Keep it off for a run that has to reproduce an earlier one.

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
                               horizon::Int, step::Int = 1, warm_start::Bool = false,
                               new_model = () -> JuMP.Model(),
                               solution_processors = [], kwargs...
                              ) where {P<:AbstractProblemType,F<:AbstractFormulationType}
    haskey(kwargs, :jump_model) &&
        throw(ArgumentError("a rolling horizon builds one model per window, so it takes a " *
                            "constructor rather than a model; pass `new_model = () -> ...` " *
                            "instead of `jump_model`"))
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
    previous = nothing

    for first in 1:step:steps
        last      = min(first + horizon - 1, steps)
        committed = first:min(first + step - 1, steps)
        kept      = window_indices(state, :time, first:last)

        nm = instantiate_model(window(state, :time, first:last), P, F;
                               jump_model = new_model(), kwargs...)
        warm_start && _warm_start!(nm, previous, kept)
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
        for m in nw_ids(nm)
            coordinates(nm, m).time in 1:length(committed) || continue
            solution["$(kept[m])"] = nm.sol["solution"]["nw"]["$m"]
            cost += network_weight(nm, m) * _value(network_cost(nm, m))
        end

        first + step <= steps || break
        warm_start && (previous = _overlap_values(nm, kept, step))
        _carry_state!(state, nm, length(committed))
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

"""
    _overlap_values(nm, kept, step)

The value of every variable of the solved window `nm` that the **next** window
will ask about again, keyed by the network index of the original problem it
belongs to, the name it is registered under, and its index within that.

Only the overlap is kept: a window index whose `:time` coordinate is at most
`step` has been committed and will not appear again, and storing it would grow
this with the whole window rather than with the part that is reused.

Keying by the *source* network index rather than by anything local is what makes
the hand-over exact under any combination of dimensions — the next window looks
up the same source index, whatever local index it gives it.
"""
function _overlap_values(nm::NetworkModel, kept::Vector{Int}, step::Int)
    values = Dict{Tuple{Int,Symbol,Any},Float64}()

    for m in nw_ids(nm)
        coordinates(nm, m).time > step || continue
        for (key, container) in var(nm; nw = m), (idx, v) in _variable_pairs(container)
            v isa JuMP.VariableRef || continue
            values[(kept[m], key, idx)] = JuMP.value(v)
        end
    end

    return values
end

"""
    _warm_start!(nm, previous, kept)

Start `nm` from the answer the previous window gave, wherever the two overlap.

Consecutive windows share `horizon - step` of their steps, so most of what a
window is asked is what the last one just answered — shifted, but about the same
hours of the same network. Handing that over as a starting point does not change
what is being solved, only where the solver begins looking, and it is the
cheapest thing a roll can do for itself.

A variable with no counterpart is left at whatever start the component gave it,
which covers the steps the window sees for the first time and anything the
previous window did not have at all.

This is what the `warm_start` keyword of [`solve_rolling_horizon`](@ref) does,
and the warning there — that it can change which of several equally good rolls
comes back — is the reason that keyword is opt-in.
"""
function _warm_start!(nm::NetworkModel, previous, kept::Vector{Int})
    previous === nothing && return nothing

    for m in nw_ids(nm)
        for (key, container) in var(nm; nw = m), (idx, v) in _variable_pairs(container)
            v isa JuMP.VariableRef || continue
            value = get(previous, (kept[m], key, idx), nothing)
            value === nothing || JuMP.set_start_value(v, value)
        end
    end

    return nothing
end

"the `index => variable` pairs of a variable container, whichever kind it is"
_variable_pairs(container::AbstractDict) = pairs(container)
_variable_pairs(container) = ((idx, container[idx]) for idx in keys(container))

"the status of a roll: the first window that did not solve, or the status they agree on"
function _rolling_status(windows::Vector{Dict{String,Any}})
    isempty(windows) && return JuMP.OPTIMIZE_NOT_CALLED

    solved = (JuMP.OPTIMAL, JuMP.LOCALLY_SOLVED)
    bad    = findfirst(w -> w["termination_status"] ∉ solved, windows)

    return bad === nothing ? first(windows)["termination_status"] :
                             windows[bad]["termination_status"]
end
