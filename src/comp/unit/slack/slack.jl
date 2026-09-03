################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.7.0 - energy not served and spill                                         #
# v0.8.0 - a slack unit takes a side in the preventive-corrective split        #
################################################################################

################################################################################
# Slack unit — data                                                            #
################################################################################

"""
    AbstractSlackUnit <: AbstractUnit

A unit that relaxes the balance of its node at a price.

Where a generator says what it can deliver and a load says what it takes, a
slack unit says what it costs to leave the two unmatched. It is what turns an
infeasible dispatch into an expensive one: the model always has an answer, and
the answer reports how much of the problem it failed to solve and where.

A slack unit is an ordinary unit and is instantiated like any other. It is
deliberately **not** created implicitly at every node: a unit that appears
without anything asking for it is hidden state, and the solution has to be able
to report what was not served separately from what was.

Two of them are shipped, [`EnergyNotServed`](@ref) and [`Spill`](@ref), and they
differ only in which way they move the balance, see [`slack_sign`](@ref).
Together they also subsume a bounded, priced slack of any other name: a
"wiggle room" on the node balance is what these already are.
"""
abstract type AbstractSlackUnit <: AbstractUnit end

"""
    EnergyNotServed <: AbstractSlackUnit

A unit `(u, i)` that injects unserved energy into its node at a price.

What it injects is demand the network could not meet, so its volume is the
energy not served at that node and its cost is the value of lost load.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `node`: the node whose balance is relaxed.
- `pmax`: the most that may go unserved [pu]. `Inf`, the default, leaves the
  volume unbounded, which is what makes a dispatch problem always feasible.
- `cost`: the price of one per unit **injected** [currency/pu/h], which must be
  non-negative — see [`Spill`](@ref) for why the sign is checked rather than the
  pair.
- `status`: whether the unit is in service.
- `ext`: free-form storage.
"""
Base.@kwdef struct EnergyNotServed <: AbstractSlackUnit
    id    ::Int
    name  ::String                   = ""
    node  ::Int
    pmax  ::NetworkQuantity{Float64} = Inf
    cost  ::NetworkQuantity{Float64} = 5000.0
    status::NetworkQuantity{Bool}    = true
    ext   ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function EnergyNotServed(id, name, node, pmax, cost, status, ext)
        all_nw(>=(0), pmax) ||
            throw(ArgumentError("energy not served $id has a negative pmax"))
        all_nw(>=(0), cost) ||
            throw(ArgumentError("energy not served $id has a negative cost, which pays " *
                                "the problem to leave demand unserved"))
        return new(id, name, node, pmax, cost, status, ext)
    end
end

register_unit_type!(EnergyNotServed)

"""
    Spill <: AbstractSlackUnit

A unit `(u, i)` that withdraws surplus energy from its node at a price.

What it withdraws is generation the network could not place — a run-of-river
inflow that had nowhere to go, a must-run plant against a trough — so its volume
is the energy spilled at that node.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `node`: the node whose balance is relaxed.
- `pmax`: the most that may be spilled [pu].
- `cost`: the price of one per unit **injected** [currency/pu/h], which must be
  non-positive. A spill withdraws, so a `cost` of `-500.0` — the default — is a
  charge of `500` per per unit spilled.
- `status`: whether the unit is in service.
- `ext`: free-form storage.

# The sign of the price

Both slack units price the same thing, the *injection*, which is what makes the
two comparable at all: running an [`EnergyNotServed`](@ref) and a `Spill` at the
same node by the same amount leaves the balance where it was and costs
`c^{\\text{ens}} - c^{\\text{sp}}` per per unit. Where that difference is
negative the pair is a money pump and the dispatch is unbounded, which is the
invariant a model carrying both has to respect.

That invariant is `c^{\\text{ens}} \\ge c^{\\text{sp}}` and it cannot be checked
in either constructor, since neither unit knows about the other. Factoring it
through zero costs nothing and puts the check where the package puts this kind
of check: an unserved per unit costs at least nothing, a spilled one costs at
least nothing, and the pair is then arbitrage free at every node without a
single node ever being looked at.
"""
Base.@kwdef struct Spill <: AbstractSlackUnit
    id    ::Int
    name  ::String                   = ""
    node  ::Int
    pmax  ::NetworkQuantity{Float64} = Inf
    cost  ::NetworkQuantity{Float64} = -500.0
    status::NetworkQuantity{Bool}    = true
    ext   ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function Spill(id, name, node, pmax, cost, status, ext)
        all_nw(>=(0), pmax) ||
            throw(ArgumentError("spill $id has a negative pmax"))
        all_nw(<=(0), cost) ||
            throw(ArgumentError("spill $id has a positive cost, which pays the problem " *
                                "to spill; the price is the price of an injection, and a " *
                                "spill withdraws"))
        return new(id, name, node, pmax, cost, status, ext)
    end
end

register_unit_type!(Spill)

"""
    slack_sign(su)

Which way slack unit `su` moves the balance of its node: `+1` for one that
injects, `-1` for one that withdraws.

This is the whole difference between [`EnergyNotServed`](@ref) and
[`Spill`](@ref) — everything else about them is shared — and it is what an
extension defines to add a third.
"""
function slack_sign end

slack_sign(::EnergyNotServed) = 1.0
slack_sign(::Spill)           = -1.0

"""
    structure_gates(su)

A slack unit is given an upper bound only where `pmax` is finite, so that field
decides the shape of its model. See [`structure_gates`](@ref).
"""
structure_gates(::AbstractSlackUnit) = (:pmax,)

################################################################################
# Slack unit — variables                                                       #
################################################################################

"""
    variable_unit(nm, T; nw)

The volume of every in-service slack unit, non-negative and bounded by `pmax`.

One variable serves both types: what separates them is the sign it enters the
node balance with, see [`slack_sign`](@ref), so the volume itself is always the
amount of the relaxation and never a signed injection. A power flow creates
nothing — there is nothing to relax in a problem that decides nothing — and the
unit sits idle at zero.
"""
variable_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
             ) where {P<:AbstractDispatchProblem,F<:AbstractFormulationType,T<:AbstractSlackUnit} =
    variable_slack_volume!(nm, T; nw)

"the volume of every slack unit of type `T`, in any formulation"
function variable_slack_volume!(nm::NetworkModel, ::Type{T}; nw::Int) where {T<:AbstractSlackUnit}
    isempty(ids(nm, T; nw)) && return nothing

    variable_container!(nm, :psl; nw)

    for u in ids(nm, T; nw)
        su = unit(nm, u; nw)::T
        variable!(nm, :psl, u; nw, base_name = "$(nw)_psl[$u]", start = 0.0,
                  lower = 0.0, upper = su.pmax)
    end

    return nothing
end

################################################################################
# Slack unit — constraints                                                     #
################################################################################

"""
    constraint_unit(nm, T; nw)

Link the injection of every in-service slack unit to the current it injects.

A slack unit relaxes the **active** balance of its node and exchanges no
reactive power, in either formulation: what it stands for is energy that was not
served or not placed, and neither has a reactive counterpart. Its injection is
`\\sigma_{u} p^{\\text{sl}}_{u}`, with `\\sigma` the sign of the unit; in a power
flow it is zero.
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractPowerFlowProblem,F<:IVRFormulation,T<:AbstractSlackUnit}
    power = get!(() -> Dict{Int,Any}(), con(nm; nw), :slack_power)

    for u in ids(nm, T; nw)
        power[u] = constraint_unit_power!(nm, u, 0.0, 0.0; nw)
    end

    return nothing
end

constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
               ) where {P<:AbstractDispatchProblem,F<:IVRFormulation,T<:AbstractSlackUnit} =
    _constraint_slack_power(nm, T, nw)

"link the volume of every slack unit to the current it injects"
function _constraint_slack_power(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractSlackUnit}
    isempty(ids(nm, T; nw)) && return nothing

    psl   = var(nm, :psl; nw)
    power = get!(() -> Dict{Int,Any}(), con(nm; nw), :slack_power)

    for u in ids(nm, T; nw)
        su = unit(nm, u; nw)::T
        p  = JuMP.@expression(nm.model, slack_sign(su) * psl[u])
        power[u] = constraint_unit_power!(nm, u, p, 0.0; nw)
    end

    return nothing
end

################################################################################
# Slack unit — cost                                                            #
################################################################################

"""
    slack_cost(nm, T, u; nw)

What slack unit `u` costs at network index `nw`,
`c_{u} \\sigma_{u} p^{\\text{sl}}_{u}`, as a JuMP expression or `0.0`.

The price is a price on the injection and the sign is the unit's, so the product
of the two is a charge per unit of volume for both kinds: `+5000` per per unit
injected and `-500` per per unit injected are a cost of `5000` per per unit
unserved and of `500` per per unit spilled. This is what an
[`EnergyNotServed`](@ref) contributes to a dispatch and to a redispatch alike —
a slack unit has no market schedule to move away from, so every per unit it
takes is the intervention itself.
"""
function slack_cost(nm::NetworkModel, ::Type{T}, u::Int; nw::Int) where {T<:AbstractSlackUnit}
    haskey(var(nm; nw), :psl) || return 0.0
    su = unit(nm, u; nw)::T

    return JuMP.@expression(nm.model, su.cost * slack_sign(su) * var(nm, :psl, u; nw))
end

dispatch_cost(nm::NetworkModel, ::Type{T}, u::Int; nw::Int) where {T<:AbstractSlackUnit} =
    slack_cost(nm, T, u; nw)

redispatch_cost(nm::NetworkModel, ::Type{T}, u::Int; nw::Int) where {T<:AbstractSlackUnit} =
    slack_cost(nm, T, u; nw)

"""
    redispatch_controls(nm, T)

The volume of a **preventive** slack unit, held equal across the contingencies.

A slack unit is a measure like any other and takes a side in the preventive and
corrective split, see [`Redispatch`](@ref): load shed ahead of an outage that may
not come is not the same decision as load shed after one that did, and the second
is worth more precisely because it is never paid for a state that did not occur.
Which one a problem means is a statement about how it is posed, so it is set on
the setup rather than on the unit.
"""
redispatch_controls(::NetworkModel, ::Type{T}) where {T<:AbstractSlackUnit} = (:psl,)

################################################################################
# Slack unit — solution                                                        #
################################################################################

"the volume of slack unit `u`, where the problem gave it one"
function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel, ::Type{T}, u::Int, nw::Int
                       ) where {T<:AbstractSlackUnit}
    haskey(var(nm; nw), :psl) && haskey(var(nm, :psl; nw), u) || return nothing
    sol["psl"] = JuMP.value(var(nm, :psl, u; nw))

    return nothing
end

################################################################################
# Slack unit — the linearized formulation                                      #
################################################################################

"""
    constraint_unit(nm, T; nw)

Link the injection of every in-service slack unit to its volume. Reactive power
plays no part in a linearized formulation, and a slack unit had none to begin
with.
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractPowerFlowProblem,F<:LPFFormulation,T<:AbstractSlackUnit}
    power = get!(() -> Dict{Int,Any}(), con(nm; nw), :slack_power)

    for u in ids(nm, T; nw)
        power[u] = constraint_unit_injection!(nm, u, 0.0; nw)
    end

    return nothing
end

constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
               ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,T<:AbstractSlackUnit} =
    _constraint_slack_injection(nm, T, nw)

"link the volume of every slack unit to the active power it injects"
function _constraint_slack_injection(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractSlackUnit}
    isempty(ids(nm, T; nw)) && return nothing

    psl   = var(nm, :psl; nw)
    power = get!(() -> Dict{Int,Any}(), con(nm; nw), :slack_power)

    for u in ids(nm, T; nw)
        su = unit(nm, u; nw)::T
        power[u] = constraint_unit_injection!(nm, u,
                       JuMP.@expression(nm.model, slack_sign(su) * psl[u]); nw)
    end

    return nothing
end
