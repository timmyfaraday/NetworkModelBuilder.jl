################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
# v0.10.1 - exports its own public names                                       #
# v0.12.8 - a load refuses a demand that is not finite                         #
# v0.14.0 - the fields follow the nomenclature                                 #
################################################################################

export FixedLoad

################################################################################
# FixedLoad — data                                                             #
################################################################################

"""
    FixedLoad <: AbstractLoad

A unit `(u, i)` that withdraws a given active and reactive power from its node.

The demand is data: no problem type gives the model any say in it. A demand that
follows a profile is still a fixed load — give `p_set` and `q_set` a
[`NetworkVector`](@ref) and each network index gets its own number. What makes a
load *flexible* is that the model chooses the number, see
[`FlexibleLoad`](@ref).

# Fields
- `id`, `name`: the identifier and a human readable label.
- `node`: the node the load is connected to.
- `p_set`, `q_set`: the active and reactive power withdrawn [pu].
- `status`: whether the load is in service.
- `ext`: free-form storage.

A demand that is not finite is refused. A negative one is not: it is a load that
injects, which is what a net position is.
"""
Base.@kwdef struct FixedLoad <: AbstractLoad
    id    ::Int
    name  ::String                   = ""
    node  ::Int
    p_set ::NetworkQuantity{Float64} = 0.0
    q_set ::NetworkQuantity{Float64} = 0.0
    status::NetworkQuantity{Bool}    = true
    ext   ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function FixedLoad(id, name, node, p_set, q_set, status, ext)
        all_nw(isfinite, p_set) && all_nw(isfinite, q_set) ||
            throw(ArgumentError("load $id has a demand that is not finite"))
        return new(id, name, node, p_set, q_set, status, ext)
    end
end

register_unit_type!(FixedLoad)

demand(::NetworkModel, ld::FixedLoad, ::Int; nw::Int) = (ld.p_set, ld.q_set)
