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
# Shunt — data                                                                 #
################################################################################

"""
    Shunt <: AbstractUnit

A unit `(u, i)` that draws a current proportional to the voltage of its node.

# Fields
- `id`: the identifier of the shunt.
- `name`: a human readable label.
- `node`: the node the shunt is connected to.
- `gs`, `bs`: the conductance and susceptance of the shunt admittance
  `y^{\\text{s}}_u = g^{\\text{s}}_u + j b^{\\text{s}}_u` [pu].
- `status`: whether the shunt is in service.
- `ext`: free-form storage.
- `gs`, `bs` and `status` may be given as a [`NetworkVector`](@ref) to make them
  vary over the network index, which is how a switched capacitor bank is
  expressed.
"""
Base.@kwdef struct Shunt <: AbstractUnit
    id    ::Int
    name  ::String                    = ""
    node  ::Int
    gs    ::NetworkQuantity{Float64}  = 0.0
    bs    ::NetworkQuantity{Float64}  = 0.0
    status::NetworkQuantity{Bool}     = true
    ext   ::Dict{Symbol,Any}          = Dict{Symbol,Any}()
end

register_unit_type!(Shunt)

################################################################################
# Shunt — constraints                                                          #
################################################################################

"""
    constraint_unit(nm, Shunt; nw)

Fix the current a shunt injects into its node at `c_u = -y^{\\text{s}}_u v_i`,
i.e.,

```math
c^{\\text{r}}_{u} = -\\left(g^{\\text{s}}_{u} v^{\\text{r}}_{i} - b^{\\text{s}}_{u} v^{\\text{i}}_{i}\\right),
\\qquad
c^{\\text{i}}_{u} = -\\left(g^{\\text{s}}_{u} v^{\\text{i}}_{i} + b^{\\text{s}}_{u} v^{\\text{r}}_{i}\\right).
```

Unlike a generator or a load this is a linear relation, which is the reason a
current based formulation keeps a shunt cheap.
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{Shunt}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:IVRFormulation}
    vr,  vi  = var(nm, :vr;  nw), var(nm, :vi;  nw)
    cru, ciu = var(nm, :cru; nw), var(nm, :ciu; nw)

    con(nm; nw)[:shunt_current] = Dict{Int,Any}()
    for u in ids(nm, Shunt; nw)
        sh = unit(nm, u; nw)::Shunt
        i  = sh.node
        con(nm; nw)[:shunt_current][u] = (
            JuMP.@constraint(nm.model, cru[u] == -(sh.gs * vr[i] - sh.bs * vi[i])),
            JuMP.@constraint(nm.model, ciu[u] == -(sh.gs * vi[i] + sh.bs * vr[i])))
    end

    return nothing
end

################################################################################
# Shunt — solution                                                             #
################################################################################

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel, ::Type{Shunt}, u::Int, nw::Int)
    sh = unit(nm, u; nw)::Shunt
    sol["gs"] = sh.gs
    sol["bs"] = sh.bs

    return nothing
end
