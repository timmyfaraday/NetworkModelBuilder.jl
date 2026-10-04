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
# Switch — the linearized formulation                                          #
################################################################################

"""
    _held(nm, sw)

Whether the problem holds switch `sw` where the data puts it: a locked switch
always, a free one wherever the problem does not choose, as in a power flow.
"""
_held(::NetworkModel{P}, sw::AbstractSwitch) where {P<:AbstractProblemType} =
    sw.lock === LOCKED || !_decides(P)

"""
    variable_edge(nm, T; nw)

A switch held where the data puts it needs no variables of its own under a
[`LPFFormulation`](@ref): its flow is the terminal power every edge already has.
"""
variable_edge(::NetworkModel{P,F}, ::Type{T}; nw::Int = 0
             ) where {P<:AbstractProblemType,F<:LPFFormulation,T<:AbstractSwitch} = nothing

"""
    variable_edge(nm, T; nw)

The position `zsw` of every free switch in a dispatch problem, a binary variable
that is 1 where the switch is closed and starts at the position the data gives.

It is the first integer variable of the package, and it makes the model a
mixed-integer program: one that has no duals, and so no nodal prices, see
[`active_nodal_price`](@ref). A switch the problem holds has none.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,T<:AbstractSwitch}
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

The physics of every in-service switch, in the linearized formulation. What leaves
one terminal arrives at the other, `p_{a^t} = -p_{a^f}`, and then, for a switch
the problem holds at its position,

| position | rows |
|:---------|:-----|
| open     | `p_{a^f} = 0` |
| closed   | `v^a_i = v^a_j` |

and for a free switch in a dispatch problem, whose closed position `z` is a
decision,

```math
\\theta^{\\text{min}}_{e} (1 - z_{e}) \\le v^{\\text{a}}_{i} - v^{\\text{a}}_{j}
\\le \\theta^{\\text{max}}_{e} (1 - z_{e}),
\\qquad
-s^{\\text{max}}_{e} z_{e} \\le p_{a^{\\text{f}}} \\le s^{\\text{max}}_{e} z_{e} .
```

Closed, the first pair is the angle equality and the second the rating; open, the
first lets the angles part within the range the data allows and the second forces
the flow to zero. The bound on the flow is what makes `s^max` a big-M, so a free
switch must have a finite rating.

A closed switch has no impedance, so its flow is whatever the node balances ask
of it, and a loop of closed switches leaves the split between them undetermined.
The angle equality is therefore written only for the switches of a spanning tree
of each group of held closed switches, taken by ascending identifier. Each other
held closed switch closes a loop with the tree instead, and gets the equation of
that loop in place of its angle equality,

```math
\\sum_{s \\in \\text{loop}} \\sigma_s \\, p_{a^{\\text{f}}_s} = 0 ,
```

with `σ_s = ±1` by the direction the loop runs through `s`. That is Kirchhoff's
voltage law with every switch given the same impedance, so parallel switches share
a flow equally, whichever solver is asked.
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:LPFFormulation,T<:AbstractSwitch}
    va, p  = var(nm, :va; nw), var(nm, :p; nw)
    switch = get!(() -> Dict{Int,Any}(), con(nm; nw), :switch)
    cycles = _switch_cycles(nm; nw)

    for e in ids(nm, T; nw)
        sw         = edge(nm, e; nw)::T
        a_fr, a_to = edge_arcs(nm, e; nw)
        i, j       = a_fr.node, a_to.node

        flow = constrain!(nm, :switch_flow, e,
                          JuMP.@build_constraint(p[a_to] == -p[a_fr]); nw)

        position = if !_held(nm, sw)
            _free_switch_rows!(nm, e, sw, a_fr, a_to; nw)
        elseif sw.position != 1
            constrain!(nm, :switch_open, e, JuMP.@build_constraint(p[a_fr] == 0.0); nw)
        elseif haskey(cycles, e)
            loop = cycles[e]
            constrain!(nm, :switch_loop, e, JuMP.@build_constraint(
                sum(σ * p[first(edge_arcs(nm, f; nw))] for (f, σ) in loop; init = 0.0) == 0.0); nw)
        else
            constrain!(nm, :switch_angle, e, JuMP.@build_constraint(va[i] == va[j]); nw)
        end

        switch[e] = (flow, position)
    end

    return nothing
end

"the angle and flow rows of free switch `e`, see [`constraint_edge`](@ref)"
function _free_switch_rows!(nm::NetworkModel, e::Int, sw::AbstractSwitch,
                            a_fr::Arc, a_to::Arc; nw::Int)
    isfinite(sw.rate_a) ||
        throw(ArgumentError("switch $e is free and has no finite rating, which the rows " *
                            "that let a dispatch problem open it are written with; give " *
                            "it a `rate_a`, or lock it"))

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
