################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.5.0 - initial implementation, including the rolling horizon               #
# v0.6.0 - the objective pays for the congestion it left                       #
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
[`constraint_redispatch_control`](@ref) and [`constraint_overload_peak`](@ref).

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
    constraint_overload_peak(nm)

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
# Redispatch — the peak of a period                                            #
################################################################################

"""
    constraint_overload_peak(nm)

Bound the peak overload of every monitored edge over every period from below by
the overload it carries at each network index of that period,

```math
o_{e,m} \\le \\hat{o}_{e,n} \\quad \\forall m \\in \\mathcal{P}(n) ,
```

with the period `𝒫` running over the `:time` coordinates grouped with `n`, see
[`period_ids`](@ref), and every other coordinate held fixed — so a problem posed
over contingencies as well gets one peak per period *per contingency*, which is
what makes each contingency a self-contained day.

The peak variable belongs to the first network index of its period, which is
where a quantity that spans indices has to be registered to survive a rebuild;
nothing else about it is per index. It is bounded from below and priced from
above, so the objective pulls it down onto the largest overload of the period
and no binary is needed to make the maximum tight.

A no-op unless the setup carries an [`OverloadPrice`](@ref) with a non-zero
`per_peak`, since a peak nothing pays for is a free variable and a row per index
for nothing.
"""
function constraint_overload_peak(nm::NetworkModel)
    price = overload_price(nm)
    price === nothing && return nothing
    iszero(price.per_peak) && return nothing
    has_dim(nm, :time) ||
        throw(ArgumentError("a `per_peak` overload price charges the worst overload of a " *
                            "period, but this problem has no `:time` dimension for periods " *
                            "to group; give it one with " *
                            "`set_dimension(data, Dimension(:time => n))`"))

    peak = Dict{Tuple{Int,Int},Any}()

    for n in nw_ids(nm)
        is_first_period_id(nm, n, :time) || continue
        window = period_ids(nm, n, :time)
        monitored = _overloaded_edges(nm, window)
        isempty(monitored) && continue

        variable_container!(nm, :olp; nw = n)
        for e in monitored
            olp = variable!(nm, :olp, e; nw = n, base_name = "$(n)_olp[$e]",
                            start = 0.0, lower = 0.0)
            for m in window
                haskey(var(nm; nw = m), :ol) || continue
                ol = var(nm, :ol; nw = m)
                haskey(ol, e) || continue

                peak[(e, m)] = constrain!(nm, :overload_peak, (e, m),
                                          JuMP.@build_constraint(ol[e] <= olp); nw = n)
            end
        end
    end

    nm.ext[:overload_peak] = peak

    return nothing
end

"the edges carrying an overload variable at any network index of `window`, sorted"
function _overloaded_edges(nm::NetworkModel, window)
    found = Int[]
    for m in window
        haskey(var(nm; nw = m), :ol) || continue
        union!(found, keys(var(nm, :ol; nw = m)))
    end

    return sort!(found)
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
registered edge and unit type through [`redispatch_cost`](@ref), plus what the
congestion left unrelieved costs, see [`overload_cost`](@ref).

The two are separate sums because they price different things. A measure is
something a component was asked to do, so it is charged to that component; an
overload is the rating of an edge going unmet, which is charged to no component
at all — it is what the problem pays for not solving the thing it was posed.
"""
function network_cost(nm::NetworkModel{P,F}, n::Int) where {P<:RedispatchProblem,F}
    total = JuMP.AffExpr(0.0)

    for (T, id) in ((T, id) for T in edge_types() for id in ids(nm, T; nw = n))
        JuMP.add_to_expression!(total, redispatch_cost(nm, T, id; nw = n))
    end
    for (T, id) in ((T, id) for T in unit_types() for id in ids(nm, T; nw = n))
        JuMP.add_to_expression!(total, redispatch_cost(nm, T, id; nw = n))
    end
    JuMP.add_to_expression!(total, overload_cost(nm; nw = n))

    return total
end

"""
    overload_cost(nm; nw)

What the rating violations at network index `nw` cost, as a JuMP expression or
`0.0`.

Zero unless the setup carries an [`OverloadPrice`](@ref), and zero as well where
it does but no monitored edge has a finite rating, since then nothing was ever
relaxed. This is a per-index cost like any other, so
[`minimize_network_cost`](@ref) weights it by the weight of its index — with a
`:weight` of the step duration, a price per per-unit becomes a price per
per-unit-hour without this having to know it.
"""
function overload_cost(nm::NetworkModel; nw::Int = nw_id_default(nm))
    price = overload_price(nm)
    price === nothing && return 0.0
    haskey(var(nm; nw), :ol) || return 0.0

    ol = var(nm, :ol; nw)

    return JuMP.@expression(nm.model,
                            price.per_energy *
                            sum(ol[e] for e in sort!(collect(keys(ol))); init = 0.0))
end

"""
    horizon_cost(nm)
    horizon_cost(nm, ids)

What a redispatch pays over a period: whatever its components charge per period
through [`period_cost`](@ref), plus what the peak overloads cost.

```math
c^{\\text{peak}} \\sum_{n} w^{\\text{p}}_{n} \\sum_{e} \\hat{o}_{e,n}
```

is the second of the two, summed over the first network index of every period and
every monitored edge, with ``w^{\\text{p}}`` the [`period_weight`](@ref). It is
charged to no component at all, for the same reason [`overload_cost`](@ref) is:
an overload is the rating of an edge going unmet, and that is what the problem
pays for not solving the thing it was posed. The duration of a step is
deliberately absent — a peak is a power, not an energy, and multiplying it by an
hour would make a day of quarter-hours cost a quarter of a day of hours for the
same worst flow. The probability of a contingency is deliberately present, for
the same reason [`network_cost`](@ref) carries it: a peak reached only in a
contingency is expected to cost what it costs times how likely that contingency
is.

`ids` restricts the sum to the periods lying **entirely** within it, which is
what [`solve_rolling_horizon`](@ref) charges a committed step.
"""
function horizon_cost(nm::NetworkModel{P,F}) where {P<:RedispatchProblem,F}
    total = JuMP.AffExpr(0.0)
    JuMP.add_to_expression!(total, component_period_cost(nm, nothing))
    JuMP.add_to_expression!(total, _overload_peak_cost(nm, nothing))

    return total
end

function horizon_cost(nm::NetworkModel{P,F}, settled::AbstractVector{Int}
                     ) where {P<:RedispatchProblem,F}
    total = JuMP.AffExpr(0.0)
    JuMP.add_to_expression!(total, component_period_cost(nm, settled))
    JuMP.add_to_expression!(total, _overload_peak_cost(nm, settled))

    return total
end

function _overload_peak_cost(nm::NetworkModel, ids)
    price = overload_price(nm)
    price === nothing && return 0.0
    iszero(price.per_peak) && return 0.0

    total = JuMP.AffExpr(0.0)

    for n in nw_ids(nm)
        haskey(var(nm; nw = n), :olp) || continue
        ids === nothing || all(in(ids), period_ids(nm, n, :time)) || continue

        olp = var(nm, :olp; nw = n)
        c   = price.per_peak * period_weight(nm, n, :time)
        for e in sort!(collect(keys(olp)))
            JuMP.add_to_expression!(total, c, olp[e])
        end
    end

    return total
end

"""
    solution_overload_peak(nm)

The peak overload of every monitored edge in every period of a solved model,
keyed by `(edge, first network index of the period)`.
"""
function solution_overload_peak(nm::NetworkModel)
    peaks = Dict{Tuple{Int,Int},Float64}()

    for n in nw_ids(nm)
        haskey(var(nm; nw = n), :olp) || continue
        for (e, v) in var(nm, :olp; nw = n)
            peaks[(e, n)] = JuMP.value(v)
        end
    end

    return peaks
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
`step`, `reuse`, `warm_start` and `new_model` along with it — and the result is shaped the same either
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
                  reuse::Bool = false, warm_start::Bool = false, kwargs...
                 ) where {F<:AbstractFormulationType}
    ext = merge(ext, Dict{Symbol,Any}(:redispatch => redispatch))

    horizon === nothing &&
        return solve_model(data, RedispatchProblem, F, optimizer; ext, kwargs...)

    return solve_rolling_horizon(data, RedispatchProblem, F, optimizer;
                                 horizon, step, reuse, warm_start, ext, kwargs...)
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
    solve_rolling_horizon(data, P, F, optimizer; horizon, step = 1, reuse = false, warm_start = false, new_model = () -> JuMP.Model(), kwargs...)

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
- `reuse`: keep one model across the windows, updating it in place instead of
  building it again, wherever the two windows have the same shape. Off by
  default. See the note below.
- `warm_start`: hand each window the previous one's answer as a starting point.
  Off by default, and see the warning below for why. With `reuse` the hand-over
  is a shift within the one model, and without it a carry between two; the first
  is much the cheaper, so the two keywords are better together than either is
  alone.
- `new_model`: called once per window for the `JuMP.Model` that window is built
  in. A roll needs a *fresh* model each time, so it takes the constructor rather
  than the model — passing `jump_model` here would give every window the same
  one, and is refused.

Remaining keyword arguments reach [`instantiate_model`](@ref) and
[`optimize_model!`](@ref), as they do for [`solve_model`](@ref).

!!! tip "`reuse` is where the time is"
    A window's model is very nearly the one the next window needs, and building
    it again is most of what a roll does. With `reuse` it is built once and
    updated after that — [`update_model!`](@ref) — which took the building of a
    year from 5.7 s to 3.8 s.

    It saves the *building* and not the solving: on the year measured, solver
    time was 1.72 s rebuilt and 1.65 s reused. A solver does not carry a basis
    across rows that have been rewritten, so an updated problem is re-solved
    much as a fresh one is. `warm_start` is what addresses the solving, and
    where it pays it pays on top of this rather than instead of it.

    Reuse is only sound between windows of the same *shape*, so each window is
    checked against the last with [`same_structure`](@ref) and built afresh
    where the answer is no — an outage that starts or ends inside the horizon,
    a rating that goes from finite to unlimited, the short windows at the end.
    The check costs a fraction of a millisecond for a whole year; where nothing
    varies but the numbers it never fails.

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

!!! tip "`warm_start` pays on a nonlinear solve and not on a linear one"
    Handing the overlap over reliably takes 15–25% off the *solve*, whichever
    formulation is being built. Whether that is worth the bookkeeping depends on
    how much of the run the solve is:

    | formulation | solver | `reuse` | `warm_start` | wall |
    |:---|:---|:---|:---|---:|
    | LPF | HiGHS | yes | no | **5.8 s** |
    | LPF | HiGHS | yes | yes | 6.0 s |
    | IVR | Ipopt | yes | no | 3.6 s |
    | IVR | Ipopt | yes | yes | **2.9 s** |

    Under a [`LPFFormulation`](@ref) the model is a linear program, an LP solver
    disposes of it in well under a second per thousand windows, and gathering
    the overlap costs more than it saves. Under an [`IVRFormulation`](@ref) the
    solve is most of the run, and the same hand-over is worth about a fifth of
    the whole.

    On the network measured, `reuse` and `warm_start` together also reached the
    same solution a cold roll did, where `warm_start` alone had settled on a
    slightly worse local one — but that is one network, and the warning below
    stands.

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
                               horizon::Int, step::Int = 1, reuse::Bool = false,
                               warm_start::Bool = false, new_model = () -> JuMP.Model(),
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
    held     = nothing
    before   = Int[]
    rebuilt  = 0
    closes   = 0

    for first in 1:step:steps
        last      = min(first + horizon - 1, steps)
        committed = first:min(first + step - 1, steps)
        kept      = window_indices(state, :time, first:last)
        w         = window(state, :time, first:last)
        last < steps && _open_window_end!(w)

        nm = reuse && held !== nothing && _same_shape(state, before, kept) ?
             update_model!(held, w) :
             (rebuilt += 1;
              instantiate_model(w, P, F; jump_model = new_model(), kwargs...))
        held, before = nm, kept
        warm_start && !reuse && _warm_start!(nm, previous, kept)
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
        settled = Int[]
        for m in nw_ids(nm)
            coordinates(nm, m).time in 1:length(committed) || continue
            solution["$(kept[m])"] = nm.sol["solution"]["nw"]["$m"]
            cost += network_weight(nm, m) * _value(network_cost(nm, m))
            push!(settled, m)
        end

        # and pay for the periods this window both saw whole and committed whole
        closed = _closed_period_ids(nm, state, kept, settled)
        isempty(closed) || (cost += _value(horizon_cost(nm, closed)); closes += 1)

        first + step <= steps || break

        # everything that reads this window's answer has to come before anything
        # that writes to its model: a model that has been written to has no
        # solution any more, and `_shift_starts!` writes
        _carry_state!(state, nm, length(committed))
        warm_start && (reuse ? _shift_starts!(nm, step) :
                               (previous = _overlap_values(nm, kept, step)))
    end

    _warn_unpriced_periods(held, closes)

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
                                                 "built"   => rebuilt, "closed" => closes,
                                                 "window"  => windows))

    isempty(solution) || (result["solution"] = Dict{String,Any}("nw" => solution))

    return result
end

solve_rolling_horizon(file::AbstractString, P::Type, F::Type, optimizer; kwargs...) =
    solve_rolling_horizon(parse_file(file), P, F, optimizer; kwargs...)

"""
    _open_window_end!(w)

Release every end-of-horizon target in the window `w`, whose last time step is
not the last time step of the problem, see [`interior_state`](@ref).

The alternative — leaving the target in every window — is the workaround this
package exists without: it asks each batch to arrive at a level someone guessed,
because the batches have no other way to agree. They do have one here, and it is
the state `initial_state` carries, so the target belongs to the window that
actually closes the horizon and to no other.
"""
function _open_window_end!(w::NetworkData)
    net = network(w)
    for (i, c) in collect(nodes(net)); net.node[i] = interior_state(c) end
    for (e, c) in collect(edges(net)); net.edge[e] = interior_state(c) end
    for (u, c) in collect(units(net)); net.unit[u] = interior_state(c) end

    return nothing
end

"""
    _closed_period_ids(nm, state, kept, settled)

The network indices of the window `nm` whose period it both **holds whole** and
committed in full, sorted.

Two things have to be true before a period-spanning cost may be charged to a
committed step, and only one of them can be seen from inside the window. That
the period was committed in full is `settled`. That the window ever saw the
whole period is not: a window renumbers what it cut, so its own last coordinate
of a period is its last coordinate of *the part it holds*, which is why the
length is compared against the period of the original problem. A window that saw
three hours of a day and committed all three has not closed that day.
"""
function _closed_period_ids(nm::NetworkModel, state::NetworkData, kept::Vector{Int},
                            settled::Vector{Int})
    has_dim(nm, :time) || return Int[]

    closed = Int[]
    for m in settled
        is_last_period_id(nm, m, :time) || continue
        here = period_ids(nm, m, :time)
        length(here) == length(period_ids(state, kept[m], :time)) || continue
        all(in(settled), here) || continue
        append!(closed, here)
    end

    return sort!(unique!(closed))
end

"warn where a roll carries a period-spanning cost that no window ever closed"
function _warn_unpriced_periods(nm, closes::Int)
    (nm === nothing || closes > 0) && return nothing
    price = overload_price(nm)
    (price === nothing || iszero(price.per_peak)) && return nothing

    @warn "no window both saw a whole period and committed it, so the peak overload " *
          "charge is in the objective of every window and in none of the cost this roll " *
          "reports; a `horizon` of at least one period and a `step` that closes one is " *
          "what makes a peak chargeable across a roll"

    return nothing
end

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

"""
    _shift_starts!(nm, step)

Move the answer `nm` just gave back by `step` time steps, and leave it there as
the starting point for the next window.

This is [`_warm_start!`](@ref) for a model that is being **reused**, and it is
the same idea arrived at for nothing. Where two windows are two models the
overlap has to be carried between them, keyed by something both can agree on;
where they are one model the overlap is already in it — the variable the next
window will call step `j` is the variable this window called step `j + step`, and
handing over means reading a value and writing a start on the same model.

The last `step` steps have no counterpart to take one from, being the part of the
horizon the next window sees for the first time, and are left at whatever start
they had.

Every value is read before any start is written, and the two passes are not an
accident of style. Writing a start counts as modifying the model, and a model
that is modified has no solution any more — so a loop that read and wrote by
turns would find the answer it was reading gone after the first write. It fails
that way on a cached model and, quietly, not on a direct one.
"""
function _shift_starts!(nm::NetworkModel, step::Int)
    horizon = dim_length(nm, :time)
    starts  = Pair{JuMP.VariableRef,Float64}[]

    for n in nw_ids(nm)
        later = coordinates(nm, n).time + step
        later <= horizon || continue
        m = similar_id(nm, n; time = later)

        for (key, container) in var(nm; nw = n)
            source = get(var(nm; nw = m), key, nothing)
            source === nothing && continue

            for (idx, v) in _variable_pairs(container)
                v isa JuMP.VariableRef || continue
                push!(starts, v => JuMP.value(_variable_at(source, idx)))
            end
        end
    end

    for (v, x) in starts
        JuMP.set_start_value(v, x)
    end

    return nothing
end

"the variable at `idx` of a container, whichever kind it is"
_variable_at(container::AbstractDict, idx) = container[idx]
_variable_at(container, idx) = container[idx]

"the `index => variable` pairs of a variable container, whichever kind it is"
_variable_pairs(container::AbstractDict) = pairs(container)
_variable_pairs(container) = ((idx, container[idx]) for idx in keys(container))

"""
    _same_shape(state, before, kept)

Whether the window whose source indices are `kept` gives a model of the same
shape as the one whose were `before`, so that the second can be the first
updated rather than a new one.

The two are compared **position by position**: the shape of a window is the
shape of its first index, then its second, and so on, and the windows of a roll
are offset from one another, so what has to hold is not that the structure is
constant but that it survives the shift. A short window at the end of a problem
has fewer indices than the one before it and is never the same shape.
"""
_same_shape(state::NetworkData, before::Vector{Int}, kept::Vector{Int}) =
    length(before) == length(kept) &&
    all(same_structure(state, a, b) for (a, b) in zip(before, kept))

"the status of a roll: the first window that did not solve, or the status they agree on"
function _rolling_status(windows::Vector{Dict{String,Any}})
    isempty(windows) && return JuMP.OPTIMIZE_NOT_CALLED

    solved = (JuMP.OPTIMAL, JuMP.LOCALLY_SOLVED)
    bad    = findfirst(w -> w["termination_status"] ∉ solved, windows)

    return bad === nothing ? first(windows)["termination_status"] :
                             windows[bad]["termination_status"]
end
