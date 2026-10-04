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
[`Branch`](@ref) with a very small impedance. The flow of a branch is the
susceptance times an angle difference, and as the reactance goes to zero the
susceptance goes to infinity: a coupler of reactance `1e-7` puts `1e7` in a
matrix whose lines are around `60`, which a solver cannot be asked to weigh.

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
    structure_gates(sw)

A switch writes a rating only where `rate_a` is finite, and writes different rows
for an open position than for a closed one, so those two decide the shape of its
model rather than a number in it. See [`structure_gates`](@ref).
"""
structure_gates(::AbstractSwitch) = (:rate_a, :position)
