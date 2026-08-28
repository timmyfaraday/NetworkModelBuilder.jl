################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
# v0.5.0 - the redispatch problem                                              #
################################################################################

################################################################################
# Generator — data                                                             #
################################################################################

"""
    AbstractGenerator <: AbstractUnit

A unit whose injection is a decision bounded by its capability.

That, rather than the sign of the power, is what separates a generator from a
load: a generator says how much it *could* deliver and the model chooses within
that, whereas a [`FixedLoad`](@ref) states what it takes. Both exchange reactive
power, and either may take a negative value of it.
"""
abstract type AbstractGenerator <: AbstractUnit end

"""
    Generator <: AbstractGenerator

A unit `(u, i)` that injects active and reactive power into its node.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `node`: the node the generator is connected to.
- `pg`, `qg`: the active and reactive power setpoint [pu], used by a load flow,
  and the **market dispatch** a [`RedispatchProblem`](@ref) moves away from.
- `pmin`, `pmax`, `qmin`, `qmax`: the operating limits [pu], used by a dispatch
  problem.
- `vg`: the voltage magnitude setpoint [pu] carried through from the input data;
  the setpoint that is actually enforced is the one on the node.
- `cost`: the coefficients of the generation cost polynomial in **ascending**
  order and in per unit, so that the cost is
  `sum(cost[k] * pg^(k-1) for k in eachindex(cost))` [currency/h].
- `cost_up`, `cost_dn`: the price of moving one per unit up and down in a
  [`RedispatchProblem`](@ref) [currency/pu/h]. `NaN`, the default, means the
  marginal generation cost at the market dispatch, see
  [`redispatch_price`](@ref).
- `status`: whether the generator is in service.
- `ext`: free-form storage.

Every field but `id`, `name`, `node` and `ext` may be given as a
[`NetworkVector`](@ref). Note that a network dependent `cost` is a
`NetworkVector{Vector{Float64}}`: the plain `Vector{Float64}` is the polynomial,
not a profile.
"""
Base.@kwdef struct Generator <: AbstractGenerator
    id     ::Int
    name   ::String                          = ""
    node   ::Int
    pg     ::NetworkQuantity{Float64}        = 0.0
    qg     ::NetworkQuantity{Float64}        = 0.0
    pmin   ::NetworkQuantity{Float64}        = 0.0
    pmax   ::NetworkQuantity{Float64}        = Inf
    qmin   ::NetworkQuantity{Float64}        = -Inf
    qmax   ::NetworkQuantity{Float64}        = Inf
    vg     ::NetworkQuantity{Float64}        = 1.0
    cost   ::NetworkQuantity{Vector{Float64}} = [0.0]
    cost_up::NetworkQuantity{Float64}        = NaN
    cost_dn::NetworkQuantity{Float64}        = NaN
    status ::NetworkQuantity{Bool}           = true
    ext    ::Dict{Symbol,Any}                = Dict{Symbol,Any}()
end

register_unit_type!(Generator)

"""
    generation_cost(g, pg)

The generation cost of `g` at an active power `pg`, as a JuMP expression or a
number.

Coefficients that are zero are skipped, and the linear and quadratic terms are
written as products rather than powers. Both matter: a cost vector padded with
zeros — which is what Matpower writes for a quadratic cost declared with `ncost`
above three — would otherwise put `pg^3` and `pg^4` into the objective and make
the whole model nonlinear, when it is in fact quadratic. A
[`LPFFormulation`](@ref) is a linear program or a quadratic one, and stays that
way only if nothing needlessly raises its objective's degree.
"""
function generation_cost(g::AbstractGenerator, pg)
    c = g.cost
    isempty(c) && return 0.0

    total = c[1]
    for k in 2:length(c)
        iszero(c[k]) && continue
        total += k == 2 ? c[k] * pg :
                 k == 3 ? c[k] * pg * pg :
                          c[k] * pg^(k - 1)
    end

    return total
end

################################################################################
# Generator — variables                                                        #
################################################################################

"""
    variable_unit(nm, T; nw)

The active and reactive power of every in-service generator.

Whether they are bounded is decided by the problem type: a load flow fixes them
at their setpoint in [`constraint_unit`](@ref) and leaves them free where the
network has to determine them, whereas a dispatch problem bounds them by the
operating limits of the generator.
"""
function variable_unit end

variable_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
             ) where {P<:AbstractPowerFlowProblem,F<:IVRFormulation,T<:AbstractGenerator} =
    _variable_generator_power(nm, T, nw, false)

variable_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
             ) where {P<:AbstractDispatchProblem,F<:IVRFormulation,T<:AbstractGenerator} =
    _variable_generator_power(nm, T, nw, true)

function _variable_generator_power(nm::NetworkModel, ::Type{T}, nw::Int, bounded::Bool
                                  ) where {T<:AbstractGenerator}
    pg = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :pg)
    qg = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :qg)

    for u in ids(nm, T; nw)
        g     = unit(nm, u; nw)::T
        pg[u] = JuMP.@variable(nm.model, base_name = "$(nw)_pg[$u]", start = g.pg)
        qg[u] = JuMP.@variable(nm.model, base_name = "$(nw)_qg[$u]", start = g.qg)

        bounded || continue
        isfinite(g.pmin) && JuMP.set_lower_bound(pg[u], g.pmin)
        isfinite(g.pmax) && JuMP.set_upper_bound(pg[u], g.pmax)
        isfinite(g.qmin) && JuMP.set_lower_bound(qg[u], g.qmin)
        isfinite(g.qmax) && JuMP.set_upper_bound(qg[u], g.qmax)
    end

    return nothing
end

################################################################################
# Generator — constraints                                                      #
################################################################################

"""
    constraint_unit(nm, T; nw)

Link the power of every in-service generator to the current it injects, and, for
a load flow only, fix that power at its setpoint.

The setpoint follows the role of the node the generator sits on. At a `REF` node
both are free: the reference generator closes the system balance. At a `PV` node
the active power is fixed and the reactive power follows from the voltage
magnitude setpoint. At a `PQ` node both are fixed. Where several generators
share a `PV` or `REF` node their split of the free quantity is not determined by
the model; the solver returns one of the admissible splits.
"""
function constraint_unit end

function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractPowerFlowProblem,F<:IVRFormulation,T<:AbstractGenerator}
    _constraint_generator_power(nm, T, nw)

    pg, qg = var(nm, :pg; nw), var(nm, :qg; nw)
    for u in ids(nm, T; nw)
        g  = unit(nm, u; nw)::T
        nd = node(nm, g.node; nw)
        nd.type == REF && continue
        JuMP.fix(pg[u], g.pg; force = true)
        nd.type == PQ && JuMP.fix(qg[u], g.qg; force = true)
    end

    return nothing
end

constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
               ) where {P<:AbstractDispatchProblem,F<:IVRFormulation,T<:AbstractGenerator} =
    _constraint_generator_power(nm, T, nw)

function _constraint_generator_power(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractGenerator}
    pg, qg = var(nm, :pg; nw), var(nm, :qg; nw)
    power  = get!(() -> Dict{Int,Any}(), con(nm; nw), :generator_power)

    for u in ids(nm, T; nw)
        power[u] = constraint_unit_power!(nm, u, pg[u], qg[u]; nw)
    end

    return nothing
end

################################################################################
# Generator — solution                                                         #
################################################################################

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel{P,F}, ::Type{T},
                        u::Int, nw::Int) where {P<:AbstractProblemType,F<:AbstractACFormulation,T<:AbstractGenerator}
    sol["pg"] = JuMP.value(var(nm, :pg, u; nw))
    sol["qg"] = JuMP.value(var(nm, :qg, u; nw))
    _solution_generator_redispatch!(sol, nm, u, nw)

    return nothing
end

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel{P,F}, ::Type{T},
                        u::Int, nw::Int) where {P<:AbstractProblemType,F<:LPFFormulation,T<:AbstractGenerator}
    sol["pg"] = JuMP.value(var(nm, :pg, u; nw))
    _solution_generator_redispatch!(sol, nm, u, nw)

    return nothing
end

################################################################################
# Generator — the linearized formulation                                       #
################################################################################

"""
    variable_unit(nm, T; nw)

The active power of every in-service generator. There is no reactive power in a
linearized formulation, so `qg` is not created and the generator's reactive
limits play no part.
"""
variable_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
             ) where {P<:AbstractPowerFlowProblem,F<:LPFFormulation,T<:AbstractGenerator} =
    _variable_generator_active(nm, T, nw, false)

variable_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
             ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,T<:AbstractGenerator} =
    _variable_generator_active(nm, T, nw, true)

function _variable_generator_active(nm::NetworkModel, ::Type{T}, nw::Int, bounded::Bool
                                   ) where {T<:AbstractGenerator}
    pg = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :pg)

    for u in ids(nm, T; nw)
        g     = unit(nm, u; nw)::T
        pg[u] = JuMP.@variable(nm.model, base_name = "$(nw)_pg[$u]", start = g.pg)

        bounded || continue
        isfinite(g.pmin) && JuMP.set_lower_bound(pg[u], g.pmin)
        isfinite(g.pmax) && JuMP.set_upper_bound(pg[u], g.pmax)
    end

    return nothing
end

"""
    constraint_unit(nm, T; nw)

Link the active power of every in-service generator to what it injects, and, for
a load flow, fix it at its setpoint everywhere but the reference node.

The `PV` and `PQ` distinction disappears here: with no reactive power and no
voltage magnitude, both hold their active setpoint and nothing else.
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractPowerFlowProblem,F<:LPFFormulation,T<:AbstractGenerator}
    _constraint_generator_active(nm, T, nw)

    pg = var(nm, :pg; nw)
    for u in ids(nm, T; nw)
        g = unit(nm, u; nw)::T
        node(nm, g.node; nw).type == REF && continue
        JuMP.fix(pg[u], g.pg; force = true)
    end

    return nothing
end

constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
               ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,T<:AbstractGenerator} =
    _constraint_generator_active(nm, T, nw)

function _constraint_generator_active(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractGenerator}
    pg    = var(nm, :pg; nw)
    power = get!(() -> Dict{Int,Any}(), con(nm; nw), :generator_power)

    for u in ids(nm, T; nw)
        power[u] = constraint_unit_injection!(nm, u, pg[u]; nw)
    end

    return nothing
end

################################################################################
# Generator — the redispatch problem                                           #
################################################################################

"""
    marginal_cost(g, pg)

The derivative of the generation cost of `g` with respect to its active power,
`sum(k * cost[k+1] * pg^(k-1) for k)`, as a JuMP expression or a number.

Zero coefficients are skipped for the same reason they are in
[`generation_cost`](@ref): a Matpower cost vector padded with zeros would
otherwise raise the degree of whatever this enters.
"""
function marginal_cost(g::AbstractGenerator, pg)
    c = g.cost
    length(c) < 2 && return 0.0

    total = c[2]
    for k in 3:length(c)
        iszero(c[k]) && continue
        total += k == 3 ? (k - 1) * c[k] * pg : (k - 1) * c[k] * pg^(k - 2)
    end

    return total
end

"""
    redispatch_price(g)

The price of moving `g` one per unit up and one per unit down, as a pair
`(c↑, c↓)` [currency/pu/h].

Where `cost_up` or `cost_dn` is `NaN` — the default — the marginal generation
cost at the market dispatch stands in for it. That default prices a redispatch
by the volume it moves weighted by what the generator's own cost curve says a
unit of its output is worth, which is the usual proxy when no bid prices are
available; both directions cost, since both are an intervention. Give the fields
explicitly to price a real balancing bid, and note that a *downward* price is
what it costs the system to have the generator back off, not the fuel it saves.
"""
function redispatch_price(g::AbstractGenerator)
    mc = marginal_cost(g, g.pg)

    return (isnan(g.cost_up) ? mc : g.cost_up,
            isnan(g.cost_dn) ? mc : g.cost_dn)
end

"""
    variable_unit(nm, T; nw)

The power of every in-service generator, bounded by its capability, plus the
volumes it moved away from the market dispatch.

The volumes are bounded by the headroom that is left in each direction,
`p^{\\uparrow}_{u} \\le p^{\\text{max}}_{u} - p^{\\text{g}}_{u}` and
`p^{\\downarrow}_{u} \\le p^{\\text{g}}_{u} - p^{\\text{min}}_{u}`, clipped at
zero so that a market dispatch outside the capability can still be brought back
into it rather than making the problem infeasible.
"""
function variable_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:RedispatchProblem,F<:IVRFormulation,T<:AbstractGenerator}
    _variable_generator_power(nm, T, nw, true)
    _variable_generator_redispatch(nm, T, nw)

    return nothing
end

function variable_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:RedispatchProblem,F<:LPFFormulation,T<:AbstractGenerator}
    _variable_generator_active(nm, T, nw, true)
    _variable_generator_redispatch(nm, T, nw)

    return nothing
end

function _variable_generator_redispatch(nm::NetworkModel, ::Type{T}, nw::Int
                                       ) where {T<:AbstractGenerator}
    pgup = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :pgup)
    pgdn = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :pgdn)

    for u in ids(nm, T; nw)
        g = unit(nm, u; nw)::T

        pgup[u] = JuMP.@variable(nm.model, base_name = "$(nw)_pgup[$u]",
                                 lower_bound = 0.0, start = 0.0)
        pgdn[u] = JuMP.@variable(nm.model, base_name = "$(nw)_pgdn[$u]",
                                 lower_bound = 0.0, start = 0.0)

        isfinite(g.pmax) && JuMP.set_upper_bound(pgup[u], max(g.pmax - g.pg, 0.0))
        isfinite(g.pmin) && JuMP.set_upper_bound(pgdn[u], max(g.pg - g.pmin, 0.0))
    end

    return nothing
end

"""
    constraint_unit(nm, T; nw)

Link the power of every in-service generator to what it injects, and split that
power into the market dispatch and the volumes moved away from it,

```math
p^{\\text{g}}_{u} = p^{\\text{g,mkt}}_{u} + p^{\\uparrow}_{u} - p^{\\downarrow}_{u} .
```

The market dispatch is the setpoint `pg` the generator already carries — the
same field a load flow holds it at. A redispatch over a horizon therefore takes
its market schedule from a `pg` that varies over `:time`, see
[`NetworkVector`](@ref).

The two volumes are separate non-negative variables because they are priced
separately. Nothing forbids both from being non-zero at once, and with positive
prices on both it is never worth doing.
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:RedispatchProblem,F<:IVRFormulation,T<:AbstractGenerator}
    _constraint_generator_power(nm, T, nw)
    _constraint_generator_redispatch(nm, T, nw)

    return nothing
end

function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:RedispatchProblem,F<:LPFFormulation,T<:AbstractGenerator}
    _constraint_generator_active(nm, T, nw)
    _constraint_generator_redispatch(nm, T, nw)

    return nothing
end

function _constraint_generator_redispatch(nm::NetworkModel, ::Type{T}, nw::Int
                                         ) where {T<:AbstractGenerator}
    pg   = var(nm, :pg;   nw)
    pgup = var(nm, :pgup; nw)
    pgdn = var(nm, :pgdn; nw)
    split = get!(() -> Dict{Int,Any}(), con(nm; nw), :generator_redispatch)

    for u in ids(nm, T; nw)
        g = unit(nm, u; nw)::T
        split[u] = JuMP.@constraint(nm.model, pg[u] == g.pg + pgup[u] - pgdn[u])
    end

    return nothing
end

"""
    redispatch_cost(nm, T, u; nw)

What generator `u` costs at network index `nw`,
`c^{\\uparrow}_{u} p^{\\uparrow}_{u} + c^{\\downarrow}_{u} p^{\\downarrow}_{u}`,
with the prices [`redispatch_price`](@ref) gives.
"""
function redispatch_cost(nm::NetworkModel, ::Type{T}, u::Int; nw::Int) where {T<:AbstractGenerator}
    cup, cdn = redispatch_price(unit(nm, u; nw)::T)

    return JuMP.@expression(nm.model,
        cup * var(nm, :pgup, u; nw) + cdn * var(nm, :pgdn, u; nw))
end

"a preventive generator holds one redispatch volume across every contingency"
redispatch_controls(::NetworkModel, ::Type{T}) where {T<:AbstractGenerator} = (:pgup, :pgdn)

"add the redispatch volumes of generator `u` to its solution, where the problem has them"
function _solution_generator_redispatch!(sol::Dict{String,Any}, nm::NetworkModel,
                                         u::Int, nw::Int)
    haskey(var(nm; nw), :pgup) || return nothing

    sol["pg_market"] = unit(nm, u; nw).pg
    sol["pgup"]      = JuMP.value(var(nm, :pgup, u; nw))
    sol["pgdn"]      = JuMP.value(var(nm, :pgdn, u; nw))

    return nothing
end
