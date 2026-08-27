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
# FixedLoad — data                                                             #
################################################################################

"""
    FixedLoad <: AbstractLoad

A unit `(u, i)` that withdraws a given active and reactive power from its node.

The demand is data: no problem type gives the model any say in it. A demand that
follows a profile is still a fixed load — give `pd` and `qd` a
[`NetworkVector`](@ref) and each network index gets its own number. What makes a
load *flexible* is that the model chooses the number, see
[`FlexibleLoad`](@ref).

# Fields
- `id`, `name`: the identifier and a human readable label.
- `node`: the node the load is connected to.
- `pd`, `qd`: the active and reactive power withdrawn [pu].
- `status`: whether the load is in service.
- `ext`: free-form storage.
"""
Base.@kwdef struct FixedLoad <: AbstractLoad
    id    ::Int
    name  ::String                    = ""
    node  ::Int
    pd    ::NetworkQuantity{Float64}  = 0.0
    qd    ::NetworkQuantity{Float64}  = 0.0
    status::NetworkQuantity{Bool}     = true
    ext   ::Dict{Symbol,Any}          = Dict{Symbol,Any}()
end

register_unit_type!(FixedLoad)

demand(::NetworkModel, ld::FixedLoad, ::Int; nw::Int) = (ld.pd, ld.qd)
