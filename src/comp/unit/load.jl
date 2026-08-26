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
# Load — data                                                                  #
################################################################################

"""
    Load <: AbstractUnit

A unit `(u, i)` that withdraws a constant active and reactive power from its
node.

# Fields
- `id`: the identifier of the load.
- `name`: a human readable label.
- `node`: the node the load is connected to.
- `pd`, `qd`: the active and reactive power withdrawn [pu].
- `status`: whether the load is in service.
- `ext`: free-form storage.
- `pd`, `qd` and `status` may be given as a [`NetworkVector`](@ref) to make them
  vary over the network index, which is how a demand profile is expressed.
"""
Base.@kwdef struct Load <: AbstractUnit
    id    ::Int
    name  ::String                    = ""
    node  ::Int
    pd    ::NetworkQuantity{Float64}  = 0.0
    qd    ::NetworkQuantity{Float64}  = 0.0
    status::NetworkQuantity{Bool}     = true
    ext   ::Dict{Symbol,Any}          = Dict{Symbol,Any}()
end

register_unit_type!(Load)

################################################################################
# Load — constraints                                                           #
################################################################################

"""
    constraint_unit(nm, Load; nw)

Fix the power a load injects into its node at minus its withdrawal,

```math
v^{\\text{r}}_{i} c^{\\text{r}}_{u} + v^{\\text{i}}_{i} c^{\\text{i}}_{u} = -p^{\\text{d}}_{u},
\\qquad
v^{\\text{i}}_{i} c^{\\text{r}}_{u} - v^{\\text{r}}_{i} c^{\\text{i}}_{u} = -q^{\\text{d}}_{u}.
```

Written this way the load draws a constant power at any voltage, which is the
usual assumption; a voltage dependent load is a different unit type.
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{Load}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:IVRFormulation}
    vr,  vi  = var(nm, :vr;  nw), var(nm, :vi;  nw)
    cru, ciu = var(nm, :cru; nw), var(nm, :ciu; nw)

    con(nm; nw)[:load_power] = Dict{Int,Any}()
    for u in ids(nm, Load; nw)
        ld = unit(nm, u; nw)::Load
        i  = ld.node
        con(nm; nw)[:load_power][u] = (
            JuMP.@constraint(nm.model, vr[i] * cru[u] + vi[i] * ciu[u] == -ld.pd),
            JuMP.@constraint(nm.model, vi[i] * cru[u] - vr[i] * ciu[u] == -ld.qd))
    end

    return nothing
end

################################################################################
# Load — solution                                                              #
################################################################################

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel, ::Type{Load}, u::Int, nw::Int)
    ld = unit(nm, u; nw)::Load
    sol["pd"] = ld.pd
    sol["qd"] = ld.qd

    return nothing
end
