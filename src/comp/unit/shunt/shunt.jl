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
# Shunt — data                                                                 #
################################################################################

"""
    AbstractShunt <: AbstractUnit

A unit that draws a current proportional to the voltage of its node, i.e., a
constant impedance.

Constant impedance, not "reactive power", is what distinguishes a shunt. Its
admittance `y = g + jb` has a conductance as well as a susceptance, and that
conductance draws *active* power in proportion to the square of the voltage
magnitude. What makes a shunt cheap in a current based formulation is that
`c = -y v` is linear, where the constant power of a [`FixedLoad`](@ref) is not.
"""
abstract type AbstractShunt <: AbstractUnit end

"""
    Shunt <: AbstractShunt

A unit `(u, i)` of constant admittance.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `node`: the node the shunt is connected to.
- `gs`, `bs`: the conductance and susceptance of the shunt admittance
  `y^{\\text{s}}_u = g^{\\text{s}}_u + j b^{\\text{s}}_u` [pu].
- `status`: whether the shunt is in service.
- `ext`: free-form storage.

`gs`, `bs` and `status` may be given as a [`NetworkVector`](@ref); a switched
capacitor bank is a `bs` that varies over the network index.
"""
Base.@kwdef struct Shunt <: AbstractShunt
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
    constraint_unit(nm, T; nw)

Fix the current a shunt injects into its node at `c_u = -y^{\\text{s}}_u v_i`,
i.e.,

```math
c^{\\text{r}}_{u} = -\\left(g^{\\text{s}}_{u} v^{\\text{r}}_{i} - b^{\\text{s}}_{u} v^{\\text{i}}_{i}\\right),
\\qquad
c^{\\text{i}}_{u} = -\\left(g^{\\text{s}}_{u} v^{\\text{i}}_{i} + b^{\\text{s}}_{u} v^{\\text{r}}_{i}\\right).
```
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:IVRFormulation,T<:AbstractShunt}
    vr,  vi  = var(nm, :vr;  nw), var(nm, :vi;  nw)
    cru, ciu = var(nm, :cru; nw), var(nm, :ciu; nw)
    current  = get!(() -> Dict{Int,Any}(), con(nm; nw), :shunt_current)

    for u in ids(nm, T; nw)
        sh = unit(nm, u; nw)::T
        i  = sh.node
        current[u] = (
            JuMP.@constraint(nm.model, cru[u] == -(sh.gs * vr[i] - sh.bs * vi[i])),
            JuMP.@constraint(nm.model, ciu[u] == -(sh.gs * vi[i] + sh.bs * vr[i])))
    end

    return nothing
end

################################################################################
# Shunt — solution                                                             #
################################################################################

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel, ::Type{T}, u::Int, nw::Int
                       ) where {T<:AbstractShunt}
    sh = unit(nm, u; nw)::T
    sol["gs"] = sh.gs
    sol["bs"] = sh.bs

    return nothing
end
