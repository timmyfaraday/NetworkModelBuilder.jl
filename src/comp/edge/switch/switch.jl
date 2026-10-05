################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.11.0 - initial implementation                                             #
################################################################################

export AbstractSwitch, Switch, SwitchLock, FREE, LOCKED

################################################################################
# Switch — data                                                                #
################################################################################

"""
    SwitchLock

Whether a problem may operate a switch: `FREE` makes its position a decision in a
dispatch problem, `LOCKED` holds it at the position the data gives. A power flow
chooses nothing, so it holds every switch, whatever its lock says.
"""
@enum SwitchLock FREE = 1 LOCKED = 2

"""
    AbstractSwitch <: AbstractEdge

An edge that connects or disconnects its two nodes and has no impedance of its
own: a busbar coupler, a circuit breaker.

Closed, it holds the voltage at its two nodes equal and lets any flow through;
open, it lets none through and leaves the two voltages independent. That is all
of its physics, and it is why a switch is a type of its own rather than a
[`Branch`](@ref) with a very small impedance. A switch has no reactance and no
susceptance. A coupler loaded as a branch needs a reactance close to zero, and
so a susceptance close to infinity: with a reactance of `1e-7` the matrix holds
`1e7` among entries around `60`, which a solver cannot be asked to weigh. A
switch has no impedance to choose, so there is nothing to round.

A concrete switch carries `id`, `name`, `terminals` (exactly two), `lock`,
`position`, `rate_a`, `angmin`, `angmax`, `status` and `ext`. Every field but
`id`, `name`, `terminals`, `lock` and `ext` may be a [`NetworkVector`](@ref).
"""
abstract type AbstractSwitch <: AbstractEdge end

"""
    Switch <: AbstractSwitch

A two-terminal edge `(e, i, j)` that is either closed or open.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `terminals`: `[i, j]`, the two nodes it connects.
- `lock`: the [`SwitchLock`](@ref), `LOCKED` by default. It describes what the
  equipment is allowed to do, so it does not vary over the network index.
- `position`: `0` for open and `1` for closed, `1` by default. Where the switch is
  locked this is the position; where it is free it is the position the problem
  starts from. An integer rather than a flag so that a switch with more terminals
  can take it further than two values.
- `rate_a`: the rating [pu], `Inf` when unlimited. An equipment limit, so a
  dispatch problem enforces it whether or not the switch is monitored for
  congestion. A free switch needs a finite one.
- `angmin`, `angmax`: the angle difference allowed across the switch while it is
  open [rad]. A closed switch has none by construction, so `angmin ≤ 0 ≤ angmax`.
- `status`: whether the switch is in service. Out of service it is absent from
  the network like any edge, which leaves its two nodes apart.
- `ext`: free-form storage.

Every field but `id`, `name`, `terminals`, `lock` and `ext` may be given as a
[`NetworkVector`](@ref).

# Examples
```julia
julia> Switch(; id = 1, terminals = [2, 7])                    # a closed coupler

julia> Switch(; id = 2, terminals = [3, 4], lock = FREE, position = 0, rate_a = 2.0)
```
"""
Base.@kwdef struct Switch <: AbstractSwitch
    id       ::Int
    name     ::String                   = ""
    terminals::Vector{Int}
    lock     ::SwitchLock               = LOCKED
    position ::NetworkQuantity{Int}     = 1
    rate_a   ::NetworkQuantity{Float64} = Inf
    angmin   ::NetworkQuantity{Float64} = -Float64(pi)
    angmax   ::NetworkQuantity{Float64} =  Float64(pi)
    status   ::NetworkQuantity{Bool}    = true
    ext      ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function Switch(id, name, terminals, lock, position, rate_a, angmin, angmax,
                    status, ext)
        _check_switch(id, terminals, position, rate_a, angmin, angmax)
        return new(id, name, terminals, lock, position, rate_a, angmin, angmax,
                   status, ext)
    end
end

function _check_switch(id, terminals, position, rate_a, angmin, angmax)
    length(terminals) == 2 ||
        throw(ArgumentError("switch $id has $(length(terminals)) terminals, a switch has exactly two"))
    all_nw(p -> p == 0 || p == 1, position) ||
        throw(ArgumentError("switch $id has a position other than 0 (open) or 1 (closed)"))
    all_nw(>=(0), rate_a) ||
        throw(ArgumentError("switch $id has a negative rating"))
    all_nw(<=(0), angmin) && all_nw(>=(0), angmax) ||
        throw(ArgumentError("switch $id has an open angle range that leaves out zero, " *
                            "which is what a closed switch has: angmin must be at most 0 " *
                            "and angmax at least 0"))

    return nothing
end

register_edge_type!(Switch)

"""
    connects(dim, sw, n; decide = true)
    can_open(dim, sw, n)

A switch connects its terminals where it is closed. A free switch also connects
while the problem decides, because the problem may close it, and is the only kind
the problem may open. See [`islands`](@ref).
"""
connects(dim::Dimension, sw::AbstractSwitch, n::Int; decide::Bool = true) =
    (decide && sw.lock === FREE) || nw_value(dim, sw.position, n) == 1

can_open(::Dimension, sw::AbstractSwitch, ::Int) = sw.lock === FREE

"""
    structure_gates(sw)

A switch writes a rating only where `rate_a` is finite, and writes different rows
for an open position than for a closed one, so those two decide the shape of its
model rather than a number in it. See [`structure_gates`](@ref).
"""
structure_gates(::AbstractSwitch) = (:rate_a, :position)

################################################################################
# Switch — what the problem makes of it                                        #
################################################################################

"the formulations a switch has rows for"
const _SwitchFormulation = Union{IVRFormulation,LPFFormulation}

"""
    _held(nm, sw)

Whether the problem holds switch `sw` where the data puts it: a locked switch
always, a free one wherever the problem does not choose, as in a power flow.
"""
_held(::NetworkModel{P}, sw::AbstractSwitch) where {P<:AbstractProblemType} =
    sw.lock === LOCKED || !_decides(P)

"""
    variable_edge(nm, T; nw)

A switch held where the data puts it needs no variables of its own: its flow is
the terminal power or current every edge already has.
"""
variable_edge(::NetworkModel{P,F}, ::Type{T}; nw::Int = 0
             ) where {P<:AbstractProblemType,F<:_SwitchFormulation,T<:AbstractSwitch} = nothing

"""
    variable_edge(nm, T; nw)

The position `zsw` of every free switch in a dispatch problem, a binary variable
that is 1 where the switch is closed and starts at the position the data gives.

It is the first integer variable of the package, and it makes the model a
mixed-integer program: one that has no duals, and so no nodal prices, see
[`active_nodal_price`](@ref). A switch the problem holds has none.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractDispatchProblem,F<:_SwitchFormulation,T<:AbstractSwitch}
    variable_container!(nm, :zsw; nw)

    for e in ids(nm, T; nw)
        sw = edge(nm, e; nw)::T
        sw.lock === FREE || continue

        variable!(nm, :zsw, e; nw, base_name = "$(nw)_zsw[$e]",
                  start = float(sw.position), binary = true)
    end

    return nothing
end

"""
    constraint_edge(nm, T; nw)

The physics of every in-service switch. What leaves one terminal arrives at the
other, `p_{a^t} = -p_{a^f}` in the linearized formulation and the same on both
currents in the current-based one, and then, for a switch the problem holds at
its position,

| position | linearized | current-based |
|:---------|:-----------|:--------------|
| open     | `p_{a^f} = 0` | `c^r_{a^f} = c^i_{a^f} = 0` |
| closed   | `v^a_i = v^a_j` | `v^r_i = v^r_j`, `v^i_i = v^i_j` |

For a free switch in a dispatch problem, whose closed position `z` is a decision,
the linearized formulation has

```math
\\theta^{\\text{min}}_{e} (1 - z_{e}) \\le v^{\\text{a}}_{i} - v^{\\text{a}}_{j}
\\le \\theta^{\\text{max}}_{e} (1 - z_{e}),
\\qquad
-s^{\\text{max}}_{e} z_{e} \\le p_{a^{\\text{f}}} \\le s^{\\text{max}}_{e} z_{e} ,
```

and the current-based formulation has, for the real and the imaginary part of the
voltage across it and of the current through it,

```math
\\left| v_{i} - v_{j} \\right| \\le M_{e} (1 - z_{e}),
\\qquad
\\left| c_{a^{\\text{f}}} \\right| \\le C_{e} z_{e},
```

with `M_e = 2 max(v^max_i, v^max_j)` and `C_e = s^max_e / min(v^min_i, v^min_j)`.

Closed, the first of each pair is the equality of the angles or of the voltages;
open, it lets them part. The second of each pair forces the flow to zero when open,
and is the rating when closed. Both are big-M rows written with `s^max`, so a free
switch must have a finite rating.

A closed switch has no impedance, so its flow is whatever the node balances ask
of it, and a loop of closed switches leaves the split between them undetermined.
The equality of angles or voltages is therefore written only for the switches of a
spanning tree of each group of held closed switches, taken by ascending
identifier. Each other held closed switch closes a loop with the tree instead, and
gets the equation of that loop in place of its equality, on the power or on each
current,

```math
\\sum_{s \\in \\text{loop}} \\sigma_s \\, p_{a^{\\text{f}}_s} = 0 ,
```

with `σ_s = ±1` by the direction the loop runs through `s`. That is Kirchhoff's
voltage law with every switch given the same impedance, so parallel switches share
a flow equally, whichever solver is asked.

A free switch is not part of such a loop, since whether it closes one is the
problem's to decide, so it writes its big-M rows and no equation of its own. A loop
that it can close, that is, a simple cycle of switches that are held closed or free
with at least one free, gets a row that holds when its free switches are closed,

```math
\\left| \\sum_{s \\in \\text{loop}} \\sigma_s \\, p_{a^{\\text{f}}_s} \\right|
\\le M \\sum_{s \\in \\text{loop, free}} (1 - z_{s}) ,
\\qquad
M = \\sum_{s \\in \\text{loop}} s^{\\text{max}}_{s} ,
```

so that a loop of free switches the problem closes splits its flow as a locked one
does, and one it leaves open is not asked to. That is one row for each simple cycle,
which is exponential in the worst case: building refuses a network that has more than
`1000` loops of this kind, and one in which a switch of such a loop has no finite
rating, which `M` is written with.
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:_SwitchFormulation,T<:AbstractSwitch}
    switch = get!(() -> Dict{Int,Any}(), con(nm; nw), :switch)
    cycles = _switch_cycles(nm; nw)

    for e in ids(nm, T; nw)
        sw         = edge(nm, e; nw)::T
        a_fr, a_to = edge_arcs(nm, e; nw)

        flow = _switch_flow!(nm, e, a_fr, a_to; nw)

        position = if !_held(nm, sw)
            _free_switch_rows!(nm, e, sw, a_fr, a_to; nw)
        elseif sw.position != 1
            _switch_open!(nm, e, a_fr; nw)
        elseif haskey(cycles, e)
            _switch_loop!(nm, e, cycles[e]; nw)
        else
            _switch_equal!(nm, e, a_fr, a_to; nw)
        end

        switch[e] = (flow, position)
    end

    # a loop is written by the type of its lowest switch, so that no type writes it twice
    loops = get!(() -> Dict{Any,Any}(), con(nm; nw), :switch_loop_free)
    for cycle in _free_switch_cycles(nm; nw)
        edge(nm, minimum(first, cycle); nw) isa T || continue
        loops[Tuple(sort!([e for (e, _) in cycle]))] = _switch_cycle_rows!(nm, cycle; nw)
    end

    return nothing
end

"the error a free switch without a finite rating is refused with"
_require_rating(e::Int, sw::AbstractSwitch) =
    isfinite(sw.rate_a) ||
        throw(ArgumentError("switch $e is free and has no finite rating, which the rows " *
                            "that let a dispatch problem open it are written with; give " *
                            "it a `rate_a`, or lock it"))

################################################################################
# Switch — the linearized formulation                                          #
################################################################################

function _switch_flow!(nm::NetworkModel{P,F}, e::Int, a_fr::Arc, a_to::Arc; nw::Int
                      ) where {P<:AbstractProblemType,F<:LPFFormulation}
    p = var(nm, :p; nw)

    return constrain!(nm, :switch_flow, e, JuMP.@build_constraint(p[a_to] == -p[a_fr]); nw)
end

function _switch_open!(nm::NetworkModel{P,F}, e::Int, a_fr::Arc; nw::Int
                      ) where {P<:AbstractProblemType,F<:LPFFormulation}
    p = var(nm, :p; nw)

    return constrain!(nm, :switch_open, e, JuMP.@build_constraint(p[a_fr] == 0.0); nw)
end

function _switch_equal!(nm::NetworkModel{P,F}, e::Int, a_fr::Arc, a_to::Arc; nw::Int
                       ) where {P<:AbstractProblemType,F<:LPFFormulation}
    va   = var(nm, :va; nw)
    i, j = a_fr.node, a_to.node

    return constrain!(nm, :switch_angle, e, JuMP.@build_constraint(va[i] == va[j]); nw)
end

function _switch_loop!(nm::NetworkModel{P,F}, e::Int, loop; nw::Int
                      ) where {P<:AbstractProblemType,F<:LPFFormulation}
    p = var(nm, :p; nw)

    return constrain!(nm, :switch_loop, e, JuMP.@build_constraint(
        sum(σ * p[first(edge_arcs(nm, f; nw))] for (f, σ) in loop; init = 0.0) == 0.0); nw)
end

function _free_switch_rows!(nm::NetworkModel{P,F}, e::Int, sw::AbstractSwitch,
                            a_fr::Arc, a_to::Arc; nw::Int
                           ) where {P<:AbstractProblemType,F<:LPFFormulation}
    _require_rating(e, sw)

    va, p, z = var(nm, :va; nw), var(nm, :p; nw), var(nm, :zsw, e; nw)
    i, j     = a_fr.node, a_to.node

    return (
        constrain!(nm, :switch_angle_range, (e, :max), JuMP.@build_constraint(
            va[i] - va[j] <= sw.angmax * (1 - z)); nw),
        constrain!(nm, :switch_angle_range, (e, :min), JuMP.@build_constraint(
            va[i] - va[j] >= sw.angmin * (1 - z)); nw),
        constrain!(nm, :switch_flow_range, (e, :max), JuMP.@build_constraint(
            p[a_fr] <= sw.rate_a * z); nw),
        constrain!(nm, :switch_flow_range, (e, :min), JuMP.@build_constraint(
            p[a_fr] >= -sw.rate_a * z); nw),
    )
end

_loop_bound(::NetworkModel{P,F}, ::Int, sw::AbstractSwitch; nw::Int = 0
           ) where {P<:AbstractProblemType,F<:LPFFormulation} = sw.rate_a

function _switch_cycle_rows!(nm::NetworkModel{P,F}, cycle; nw::Int
                            ) where {P<:AbstractProblemType,F<:LPFFormulation}
    p      = var(nm, :p; nw)
    key    = Tuple(sort!([e for (e, _) in cycle]))
    M      = _loop_bound_sum(nm, cycle; nw)
    slack  = _loop_slack(nm, cycle; nw)
    around = sum(σ * p[first(edge_arcs(nm, e; nw))] for (e, σ) in cycle)

    return (
        constrain!(nm, :switch_cycle, (key, :max),
                   JuMP.@build_constraint(around <= M * slack); nw),
        constrain!(nm, :switch_cycle, (key, :min),
                   JuMP.@build_constraint(around >= -M * slack); nw),
    )
end

"""
    constraint_edge_limits(nm, T; nw)

The rating of every in-service switch that is closed, `-s^max_e ≤ p_{a^f} ≤
s^max_e`, where it is finite. It is an equipment limit, so it holds whether or not
the switch is monitored for congestion, and it is never priced: an open switch has
no flow to limit.
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,T<:AbstractSwitch}
    p      = var(nm, :p; nw)
    limits = get!(() -> Dict{Int,Any}(), con(nm; nw), :switch_limits)

    for e in ids(nm, T; nw)
        sw = edge(nm, e; nw)::T
        (_held(nm, sw) && sw.position == 1 && isfinite(sw.rate_a)) || continue

        a_fr = first(edge_arcs(nm, e; nw))
        limits[e] = constrain!(nm, :switch_rating, e,
                               JuMP.@build_constraint(-sw.rate_a <= p[a_fr] <= sw.rate_a); nw)
    end

    return nothing
end

################################################################################
# Switch — the current-based formulation                                       #
################################################################################

function _switch_flow!(nm::NetworkModel{P,F}, e::Int, a_fr::Arc, a_to::Arc; nw::Int
                      ) where {P<:AbstractProblemType,F<:IVRFormulation}
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)

    return (
        constrain!(nm, :switch_flow, (e, :real),
                   JuMP.@build_constraint(cr[a_to] == -cr[a_fr]); nw),
        constrain!(nm, :switch_flow, (e, :imag),
                   JuMP.@build_constraint(ci[a_to] == -ci[a_fr]); nw),
    )
end

function _switch_open!(nm::NetworkModel{P,F}, e::Int, a_fr::Arc; nw::Int
                      ) where {P<:AbstractProblemType,F<:IVRFormulation}
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)

    return (
        constrain!(nm, :switch_open, (e, :real), JuMP.@build_constraint(cr[a_fr] == 0.0); nw),
        constrain!(nm, :switch_open, (e, :imag), JuMP.@build_constraint(ci[a_fr] == 0.0); nw),
    )
end

function _switch_equal!(nm::NetworkModel{P,F}, e::Int, a_fr::Arc, a_to::Arc; nw::Int
                       ) where {P<:AbstractProblemType,F<:IVRFormulation}
    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)
    i, j   = a_fr.node, a_to.node

    return (
        constrain!(nm, :switch_voltage, (e, :real), JuMP.@build_constraint(vr[i] == vr[j]); nw),
        constrain!(nm, :switch_voltage, (e, :imag), JuMP.@build_constraint(vi[i] == vi[j]); nw),
    )
end

function _switch_loop!(nm::NetworkModel{P,F}, e::Int, loop; nw::Int
                      ) where {P<:AbstractProblemType,F<:IVRFormulation}
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)

    return (
        constrain!(nm, :switch_loop, (e, :real), JuMP.@build_constraint(
            sum(σ * cr[first(edge_arcs(nm, f; nw))] for (f, σ) in loop; init = 0.0) == 0.0); nw),
        constrain!(nm, :switch_loop, (e, :imag), JuMP.@build_constraint(
            sum(σ * ci[first(edge_arcs(nm, f; nw))] for (f, σ) in loop; init = 0.0) == 0.0); nw),
    )
end

function _free_switch_rows!(nm::NetworkModel{P,F}, e::Int, sw::AbstractSwitch,
                            a_fr::Arc, a_to::Arc; nw::Int
                           ) where {P<:AbstractProblemType,F<:IVRFormulation}
    _require_rating(e, sw)

    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)
    z      = var(nm, :zsw, e; nw)
    i, j   = a_fr.node, a_to.node
    ni, nj = node(nm, i; nw), node(nm, j; nw)

    M = 2 * max(ni.vmax, nj.vmax)
    C = _current_bound(nm, e, sw, a_fr, a_to; nw)

    return (
        constrain!(nm, :switch_voltage_range, (e, :real, :max), JuMP.@build_constraint(
            vr[i] - vr[j] <= M * (1 - z)); nw),
        constrain!(nm, :switch_voltage_range, (e, :real, :min), JuMP.@build_constraint(
            vr[i] - vr[j] >= -M * (1 - z)); nw),
        constrain!(nm, :switch_voltage_range, (e, :imag, :max), JuMP.@build_constraint(
            vi[i] - vi[j] <= M * (1 - z)); nw),
        constrain!(nm, :switch_voltage_range, (e, :imag, :min), JuMP.@build_constraint(
            vi[i] - vi[j] >= -M * (1 - z)); nw),
        constrain!(nm, :switch_current_range, (e, :real, :max), JuMP.@build_constraint(
            cr[a_fr] <= C * z); nw),
        constrain!(nm, :switch_current_range, (e, :real, :min), JuMP.@build_constraint(
            cr[a_fr] >= -C * z); nw),
        constrain!(nm, :switch_current_range, (e, :imag, :max), JuMP.@build_constraint(
            ci[a_fr] <= C * z); nw),
        constrain!(nm, :switch_current_range, (e, :imag, :min), JuMP.@build_constraint(
            ci[a_fr] >= -C * z); nw),
    )
end

"""
the largest current a switch can carry, its rating over the lowest voltage there may
be at either end, which is what a bound on a current is written with
"""
function _current_bound(nm::NetworkModel, e::Int, sw::AbstractSwitch,
                        a_fr::Arc, a_to::Arc; nw::Int)
    vmin = min(node(nm, a_fr.node; nw).vmin, node(nm, a_to.node; nw).vmin)
    vmin > 0 ||
        throw(ArgumentError("switch $e joins a node with a lower voltage limit of $vmin, " *
                            "and the bound on its current is the rating over that limit; " *
                            "give the nodes a positive `vmin`, or lock it"))

    return sw.rate_a / vmin
end

_loop_bound(nm::NetworkModel{P,F}, e::Int, sw::AbstractSwitch; nw::Int
           ) where {P<:AbstractProblemType,F<:IVRFormulation} =
    _current_bound(nm, e, sw, edge_arcs(nm, e; nw)...; nw)

function _switch_cycle_rows!(nm::NetworkModel{P,F}, cycle; nw::Int
                            ) where {P<:AbstractProblemType,F<:IVRFormulation}
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)
    key    = Tuple(sort!([e for (e, _) in cycle]))
    M      = _loop_bound_sum(nm, cycle; nw)
    slack  = _loop_slack(nm, cycle; nw)
    real   = sum(σ * cr[first(edge_arcs(nm, e; nw))] for (e, σ) in cycle)
    imag   = sum(σ * ci[first(edge_arcs(nm, e; nw))] for (e, σ) in cycle)

    return (
        constrain!(nm, :switch_cycle, (key, :real, :max),
                   JuMP.@build_constraint(real <= M * slack); nw),
        constrain!(nm, :switch_cycle, (key, :real, :min),
                   JuMP.@build_constraint(real >= -M * slack); nw),
        constrain!(nm, :switch_cycle, (key, :imag, :max),
                   JuMP.@build_constraint(imag <= M * slack); nw),
        constrain!(nm, :switch_cycle, (key, :imag, :min),
                   JuMP.@build_constraint(imag >= -M * slack); nw),
    )
end

"""
    constraint_edge_limits(nm, T; nw)

The rating of every in-service switch that is closed or free, where it is finite,

```math
\\left( (v^{\\text{r}}_{i})^2 + (v^{\\text{i}}_{i})^2 \\right)
\\left( (c^{\\text{r}}_{a^{\\text{f}}})^2 + (c^{\\text{i}}_{a^{\\text{f}}})^2 \\right)
\\le (s^{\\text{max}}_{e})^2 .
```

One row on the first terminal is the whole rating: closed, the voltage is the same at
both, and open, the current is zero. A free switch has it as well as the bounds that
make `s^max` a big-M, so a model with one is nonconvex as well as mixed-integer.

It is an equipment limit, so it holds whether or not the switch is monitored for
congestion, and it is never priced.
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:IVRFormulation,T<:AbstractSwitch}
    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)
    limits = get!(() -> Dict{Int,Any}(), con(nm; nw), :switch_limits)

    for e in ids(nm, T; nw)
        sw = edge(nm, e; nw)::T
        (isfinite(sw.rate_a) && (!_held(nm, sw) || sw.position == 1)) || continue

        a = first(edge_arcs(nm, e; nw))
        limits[e] = constrain!(nm, :switch_rating, e, JuMP.@build_constraint(
            (vr[a.node]^2 + vi[a.node]^2) * (cr[a]^2 + ci[a]^2) <= sw.rate_a^2); nw)
    end

    return nothing
end

################################################################################
# Switch — the redispatch problem and the solution                             #
################################################################################

"""
    redispatch_controls(nm, T)

The position `zsw` of a free switch, which a preventive switch holds equal across
the contingencies and a corrective one does not. A locked switch has no such
variable, so there is nothing of it to hold.

A switch is a **non-costly** measure: it has no [`redispatch_cost`](@ref) method,
so it moves for free.
"""
redispatch_controls(::NetworkModel{P,F}, ::Type{T}
                   ) where {P<:AbstractProblemType,F<:_SwitchFormulation,T<:AbstractSwitch} = (:zsw,)

"""
    solution_edge!(entry, nm, T, e, nw)

The `"lock"` of a switch, as a string, and its `"position"`, 1 for closed and 0 for
open: the one in the data where the problem holds it, and the one the problem chose
where it was free.
"""
function solution_edge!(entry::Dict{String,Any}, nm::NetworkModel, ::Type{T}, e::Int, nw::Int
                       ) where {T<:AbstractSwitch}
    sw = edge(nm, e; nw)::T

    entry["lock"]     = string(sw.lock)
    entry["position"] = _held(nm, sw) ? sw.position :
                        round(Int, JuMP.value(var(nm, :zsw, e; nw)))

    return nothing
end

################################################################################
# Switch — the loops of closed switches                                        #
################################################################################

"""
    _switch_cycles(nm; nw)

For every closed switch that is not in the spanning tree of its group, the loop it
closes with the tree, as the `(edge, σ)` pairs that go round it, `σ` being `+1`
where the loop runs through the edge from its first terminal to its second.
"""
function _switch_cycles(nm::NetworkModel; nw::Int)
    adjacent = Dict{Int,Vector{Tuple{Int,Int,Int}}}()
    cycles   = Dict{Int,Vector{Tuple{Int,Int}}}()

    for e in ids(nm, AbstractSwitch; nw)
        sw = edge(nm, e; nw)
        (_held(nm, sw) && sw.position == 1) || continue

        i, j = terminals(sw)
        path = _tree_path(adjacent, j, i)
        if path === nothing
            push!(get!(() -> Tuple{Int,Int,Int}[], adjacent, i), (j, e, +1))
            push!(get!(() -> Tuple{Int,Int,Int}[], adjacent, j), (i, e, -1))
        else
            cycles[e] = vcat([(e, +1)], path)
        end
    end

    return cycles
end

"the `(edge, σ)` pairs along the one path through the tree from node `from` to node `to`, or `nothing`"
function _tree_path(adjacent, from::Int, to::Int)
    from == to && return Tuple{Int,Int}[]

    reached = Dict{Int,Tuple{Int,Int,Int}}(from => (from, 0, 0))
    stack   = [from]
    while !isempty(stack)
        u = pop!(stack)
        for (w, f, σ) in get(adjacent, u, ())
            haskey(reached, w) && continue
            reached[w] = (u, f, σ)
            if w == to
                path = Tuple{Int,Int}[]
                while w != from
                    u, f, σ = reached[w]
                    pushfirst!(path, (f, σ))
                    w = u
                end

                return path
            end
            push!(stack, w)
        end
    end

    return nothing
end

"the most loops of switches that a free one can close that a model is written with"
const _MAX_SWITCH_LOOPS = 1000

"""
    _free_switch_cycles(nm; nw)

Every simple cycle at network index `nw` of the switches that are closed or that
the problem may close, with at least one of the latter, as a list of `(edge, σ)`
pairs that go round it, `σ` being `+1` where the cycle runs through the edge from
its first terminal to its second. Each is found once.

A cycle of switches that are all held closed is the business of
[`_switch_cycles`](@ref), and a switch that is held open is on no cycle. Only the
groups of switches that have a free one in them are searched.
"""
function _free_switch_cycles(nm::NetworkModel; nw::Int)
    free  = Set{Int}()
    found = Tuple{Int,Int,Int}[]                   # (edge, first node, second node)
    for e in ids(nm, AbstractSwitch; nw)
        sw   = edge(nm, e; nw)
        held = _held(nm, sw)
        (held && sw.position != 1) && continue

        held || push!(free, e)
        i, j = terminals(sw)
        push!(found, (e, i, j))
    end
    cycles = Vector{Tuple{Int,Int}}[]
    isempty(free) && return cycles

    parent = Dict{Int,Int}()
    function root(u::Int)
        while get!(parent, u, u) != u
            parent[u] = parent[parent[u]]
            u = parent[u]
        end

        return u
    end
    for (_, i, j) in found
        a, b = root(i), root(j)
        a == b || (parent[max(a, b)] = min(a, b))
    end
    alive = Set(root(i) for (e, i, _) in found if e in free)

    adjacent = Dict{Int,Vector{Tuple{Int,Int,Int}}}()
    for (e, i, j) in found
        root(i) in alive || continue
        if i == j
            e in free && push!(cycles, [(e, +1)])
        else
            push!(get!(() -> Tuple{Int,Int,Int}[], adjacent, i), (j, e, +1))
            push!(get!(() -> Tuple{Int,Int,Int}[], adjacent, j), (i, e, -1))
        end
    end

    path, seen, met = Tuple{Int,Int}[], Set{Int}(), Ref(0)
    function extend(start::Int, u::Int)
        for (w, e, σ) in adjacent[u]
            if w == start
                # each cycle is met in both directions, and kept in the one that starts
                # on the lower edge
                (!isempty(path) && first(first(path)) < e) || continue
                met[] += 1
                met[] > _MAX_SWITCH_LOOPS &&
                    throw(ArgumentError("at network index $nw the switches that are closed " *
                        "or that a free switch could close form more than $_MAX_SWITCH_LOOPS " *
                        "loops around the nodes $(_list(sort!(collect(keys(adjacent))))), and " *
                        "a loop row is written for each; lock some of the free switches"))
                cycle = vcat(path, [(e, σ)])
                any(in(free), first.(cycle)) && push!(cycles, cycle)
            elseif w > start && w ∉ seen
                push!(path, (e, σ)); push!(seen, w)
                extend(start, w)
                pop!(path); delete!(seen, w)
            end
        end
    end
    for start in sort!(collect(keys(adjacent)))
        extend(start, start)
    end

    return cycles
end

"the sum of the largest flows the switches of a cycle can carry, which its loop row is written with"
function _loop_bound_sum(nm::NetworkModel, cycle; nw::Int)
    total = 0.0
    for (e, _) in cycle
        sw = edge(nm, e; nw)
        isfinite(sw.rate_a) ||
            throw(ArgumentError("switch $e is in a loop that a free switch can close, and " *
                                "the row of that loop is written with the rating of every " *
                                "switch in it; give it a finite `rate_a`"))
        total += _loop_bound(nm, e, sw; nw)
    end

    return total
end

"how far the free switches of a cycle are from all being closed"
_loop_slack(nm::NetworkModel, cycle; nw::Int) =
    sum(1 - var(nm, :zsw, e; nw) for (e, _) in cycle
        if !_held(nm, edge(nm, e; nw)); init = 0.0)
