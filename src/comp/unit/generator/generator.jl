################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
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
- `pg`, `qg`: the active and reactive power setpoint [pu], used by a load flow.
- `pmin`, `pmax`, `qmin`, `qmax`: the operating limits [pu], used by a dispatch
  problem.
- `vg`: the voltage magnitude setpoint [pu] carried through from the input data;
  the setpoint that is actually enforced is the one on the node.
- `cost`: the coefficients of the generation cost polynomial in **ascending**
  order and in per unit, so that the cost is
  `sum(cost[k] * pg^(k-1) for k in eachindex(cost))` [currency/h].
- `status`: whether the generator is in service.
- `ext`: free-form storage.

Every field but `id`, `name`, `node` and `ext` may be given as a
[`NetworkVector`](@ref). Note that a network dependent `cost` is a
`NetworkVector{Vector{Float64}}`: the plain `Vector{Float64}` is the polynomial,
not a profile.
"""
Base.@kwdef struct Generator <: AbstractGenerator
    id    ::Int
    name  ::String                          = ""
    node  ::Int
    pg    ::NetworkQuantity{Float64}         = 0.0
    qg    ::NetworkQuantity{Float64}         = 0.0
    pmin  ::NetworkQuantity{Float64}         = 0.0
    pmax  ::NetworkQuantity{Float64}         = Inf
    qmin  ::NetworkQuantity{Float64}         = -Inf
    qmax  ::NetworkQuantity{Float64}         = Inf
    vg    ::NetworkQuantity{Float64}         = 1.0
    cost  ::NetworkQuantity{Vector{Float64}} = [0.0]
    status::NetworkQuantity{Bool}            = true
    ext   ::Dict{Symbol,Any}                 = Dict{Symbol,Any}()
end

register_unit_type!(Generator)

"the generation cost of `g` at an active power `pg`, as a JuMP expression or a number"
generation_cost(g::AbstractGenerator, pg) =
    sum(c * pg^(k - 1) for (k, c) in enumerate(g.cost); init = 0.0)

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

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel, ::Type{T}, u::Int, nw::Int
                       ) where {T<:AbstractGenerator}
    sol["pg"] = JuMP.value(var(nm, :pg, u; nw))
    sol["qg"] = JuMP.value(var(nm, :qg, u; nw))

    return nothing
end
