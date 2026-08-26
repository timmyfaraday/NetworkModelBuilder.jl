################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
# v0.2.0 - network dependent data stored per component                         #
################################################################################

################################################################################
# Generator — data                                                             #
################################################################################

"""
    Generator <: AbstractUnit

A unit `(u, i)` that injects active and reactive power into its node.

# Fields
- `id`: the identifier of the generator.
- `name`: a human readable label.
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
- every field but `id`, `name`, `node` and `ext` may be given as a
  [`NetworkVector`](@ref) to make it vary over the network index. Note that a
  network dependent `cost` is a `NetworkVector{Vector{Float64}}`: the plain
  `Vector{Float64}` is the polynomial, not a profile.
"""
Base.@kwdef struct Generator <: AbstractUnit
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
generation_cost(g::Generator, pg) = sum(c * pg^(k - 1) for (k, c) in enumerate(g.cost); init = 0.0)

################################################################################
# Generator — variables                                                        #
################################################################################

"""
    variable_unit(nm, Generator; nw)

The active and reactive power of every in-service generator.

Whether they are bounded is decided by the problem type: a load flow fixes them
at their setpoint in [`constraint_unit`](@ref) and leaves them free where the
network has to determine them, whereas a dispatch problem bounds them by the
operating limits of the generator.
"""
function variable_unit end

function variable_unit(nm::NetworkModel{P,F}, ::Type{Generator}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractPowerFlowProblem,F<:IVRFormulation}
    U = ids(nm, Generator; nw)

    var(nm; nw)[:pg] = JuMP.@variable(nm.model, [u in U], base_name = "$(nw)_pg",
                                      start = unit(nm, u; nw).pg)
    var(nm; nw)[:qg] = JuMP.@variable(nm.model, [u in U], base_name = "$(nw)_qg",
                                      start = unit(nm, u; nw).qg)

    return nothing
end

function variable_unit(nm::NetworkModel{P,F}, ::Type{Generator}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractDispatchProblem,F<:IVRFormulation}
    U = ids(nm, Generator; nw)

    pg = JuMP.@variable(nm.model, [u in U], base_name = "$(nw)_pg", start = unit(nm, u; nw).pg)
    qg = JuMP.@variable(nm.model, [u in U], base_name = "$(nw)_qg", start = unit(nm, u; nw).qg)

    for u in U
        g = unit(nm, u; nw)::Generator
        isfinite(g.pmin) && JuMP.set_lower_bound(pg[u], g.pmin)
        isfinite(g.pmax) && JuMP.set_upper_bound(pg[u], g.pmax)
        isfinite(g.qmin) && JuMP.set_lower_bound(qg[u], g.qmin)
        isfinite(g.qmax) && JuMP.set_upper_bound(qg[u], g.qmax)
    end

    var(nm; nw)[:pg] = pg
    var(nm; nw)[:qg] = qg

    return nothing
end

################################################################################
# Generator — constraints                                                      #
################################################################################

"""
    constraint_unit(nm, Generator; nw)

Link the power of every in-service generator to the current it injects,

```math
p_{u} = v^{\\text{r}}_{i} c^{\\text{r}}_{u} + v^{\\text{i}}_{i} c^{\\text{i}}_{u},
\\qquad
q_{u} = v^{\\text{i}}_{i} c^{\\text{r}}_{u} - v^{\\text{r}}_{i} c^{\\text{i}}_{u},
```

and, for a load flow only, fix that power at its setpoint.

The setpoint follows the role of the node the generator sits on. At a `REF` node
both are free: the reference generator closes the system balance. At a `PV` node
the active power is fixed and the reactive power follows from the voltage
magnitude setpoint. At a `PQ` node both are fixed. Where several generators
share a `PV` or `REF` node their split of the free quantity is not determined by
the model; the solver returns one of the admissible splits.
"""
function constraint_unit end

function constraint_unit(nm::NetworkModel{P,F}, ::Type{Generator}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractPowerFlowProblem,F<:IVRFormulation}
    _constraint_generator_power(nm, nw)

    pg, qg = var(nm, :pg; nw), var(nm, :qg; nw)
    for u in ids(nm, Generator; nw)
        g  = unit(nm, u; nw)::Generator
        nd = node(nm, g.node; nw)
        nd.type == REF && continue
        JuMP.fix(pg[u], g.pg; force = true)
        nd.type == PQ && JuMP.fix(qg[u], g.qg; force = true)
    end

    return nothing
end

constraint_unit(nm::NetworkModel{P,F}, ::Type{Generator}; nw::Int = nw_id_default(nm)
               ) where {P<:AbstractDispatchProblem,F<:IVRFormulation} =
    _constraint_generator_power(nm, nw)

function _constraint_generator_power(nm::NetworkModel, nw::Int)
    vr,  vi  = var(nm, :vr;  nw), var(nm, :vi;  nw)
    cru, ciu = var(nm, :cru; nw), var(nm, :ciu; nw)
    pg,  qg  = var(nm, :pg;  nw), var(nm, :qg;  nw)

    con(nm; nw)[:generator_power] = Dict{Int,Any}()
    for u in ids(nm, Generator; nw)
        i = node(unit(nm, u; nw))
        con(nm; nw)[:generator_power][u] = (
            JuMP.@constraint(nm.model, pg[u] == vr[i] * cru[u] + vi[i] * ciu[u]),
            JuMP.@constraint(nm.model, qg[u] == vi[i] * cru[u] - vr[i] * ciu[u]))
    end

    return nothing
end

################################################################################
# Generator — solution                                                         #
################################################################################

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel, ::Type{Generator}, u::Int, nw::Int)
    sol["pg"] = JuMP.value(var(nm, :pg, u; nw))
    sol["qg"] = JuMP.value(var(nm, :qg, u; nw))

    return nothing
end
