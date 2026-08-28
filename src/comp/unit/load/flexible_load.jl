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
# FlexibleLoad — data                                                          #
################################################################################

"""
    FlexibleLoad <: AbstractLoad

A unit `(u, i)` whose demand the model may shift in time, as long as it receives
the same energy over the horizon.

In a dispatch problem the withdrawal at each network index is a decision held
between `pd_min` and `pd_max`, and one constraint per horizon ties the whole
profile together: the energy it takes must equal `energy`. In a power flow it
has no freedom and behaves as a [`FixedLoad`](@ref) at `pd_nominal`.

This is the first component in the package whose constraints span network
indices, so it needs the problem to have a `:time` dimension and says so if it
does not. The duration of a step comes from the `:duration` property of that
dimension, see [`time_step`](@ref).

Reactive demand follows the active demand at the power factor of the nominal
point, so that shifting a load does not silently change what it does to voltages.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `node`: the node the load is connected to.
- `pd_nominal`, `qd_nominal`: the demand it would take without flexibility [pu].
- `pd_min`, `pd_max`: the limits within which the demand may be shifted [pu].
- `energy`: the energy it must receive over the horizon [pu·h]. `NaN`, the
  default, means the energy the nominal profile would have taken.
- `status`: whether the load is in service.
- `ext`: free-form storage.
"""
Base.@kwdef struct FlexibleLoad <: AbstractLoad
    id        ::Int
    name      ::String                    = ""
    node      ::Int
    pd_nominal::NetworkQuantity{Float64}  = 0.0
    qd_nominal::NetworkQuantity{Float64}  = 0.0
    pd_min    ::NetworkQuantity{Float64}  = 0.0
    pd_max    ::NetworkQuantity{Float64}  = Inf
    energy    ::Float64                   = NaN
    status    ::NetworkQuantity{Bool}     = true
    ext       ::Dict{Symbol,Any}          = Dict{Symbol,Any}()

    function FlexibleLoad(id, name, node, pd_nominal, qd_nominal, pd_min, pd_max,
                          energy, status, ext)
        all_nw(<=, pd_min, pd_max) ||
            throw(ArgumentError("flexible load $id has pd_min above pd_max"))
        return new(id, name, node, pd_nominal, qd_nominal, pd_min, pd_max,
                   energy, status, ext)
    end
end

register_unit_type!(FlexibleLoad)

"a flexible load is given an upper bound only where `pd_max` is finite"
structure_gates(::FlexibleLoad) = (:pd_max,)

"the ratio of reactive to active demand at the nominal point"
power_factor_ratio(ld::FlexibleLoad) = iszero(ld.pd_nominal) ? 0.0 : ld.qd_nominal / ld.pd_nominal

################################################################################
# FlexibleLoad — variables                                                     #
################################################################################

"""
    variable_unit(nm, FlexibleLoad; nw)

The active demand of every in-service flexible load, held between `pd_min` and
`pd_max`. A power flow creates nothing: there the demand is its nominal value.
"""
function variable_unit(nm::NetworkModel{P,F}, ::Type{FlexibleLoad}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractDispatchProblem,F<:AbstractFormulationType}
    isempty(ids(nm, FlexibleLoad; nw)) && return nothing
    require_time_dimension(nm, FlexibleLoad)

    variable_container!(nm, :pdf; nw)

    for u in ids(nm, FlexibleLoad; nw)
        ld = unit(nm, u; nw)::FlexibleLoad
        variable!(nm, :pdf, u; nw, base_name = "$(nw)_pdf[$u]", start = ld.pd_nominal,
                  lower = ld.pd_min, upper = ld.pd_max)
    end

    return nothing
end

demand(::NetworkModel, ld::FlexibleLoad, ::Int; nw::Int) = (ld.pd_nominal, ld.qd_nominal)

function demand(nm::NetworkModel{P,F}, ld::FlexibleLoad, u::Int; nw::Int
               ) where {P<:AbstractDispatchProblem,F<:AbstractFormulationType}
    pd = var(nm, :pdf, u; nw)

    return (pd, JuMP.@expression(nm.model, power_factor_ratio(ld) * pd))
end

################################################################################
# FlexibleLoad — constraints across network indices                            #
################################################################################

"""
    constraint_unit_coupling(nm, FlexibleLoad; nw)

One energy balance per flexible load per horizon,

```math
\\sum_{n \\in \\mathcal{T}} \\Delta t_{n} \\, p^{\\text{d}}_{u,n} = E_{u},
```

where the horizon `𝒯` runs over the `:time` coordinates while every other
coordinate of the network index is held fixed. A problem with a contingency
dimension therefore gets one balance per contingency, which is what makes each
contingency a self-contained day rather than a shared one.
"""
function constraint_unit_coupling(nm::NetworkModel{P,F}, ::Type{FlexibleLoad}
                                 ) where {P<:AbstractDispatchProblem,F<:AbstractFormulationType}
    isempty(ids(nm, FlexibleLoad; nw = nw_id_default(nm))) && return nothing
    require_time_dimension(nm, FlexibleLoad)

    horizon = 1:dim_length(nm, :time)
    energy  = Dict{Tuple{Int,Int},Any}()

    for n in nw_ids(nm)
        is_first_id(nm, n, :time) || continue
        window = similar_ids(nm, n; time = horizon)

        for u in ids(nm, FlexibleLoad; nw = n)
            ld     = unit(nm, u; nw = n)::FlexibleLoad
            target = isnan(ld.energy) ?
                sum(time_step(nm, m) * unit(nm, u; nw = m).pd_nominal for m in window) :
                ld.energy

            energy[(u, n)] = constrain!(nm, :flexible_energy, u, JuMP.@build_constraint(
                sum(time_step(nm, m) * var(nm, :pdf, u; nw = m) for m in window) == target); nw = n)
        end
    end

    nm.ext[:flexible_load_energy] = energy

    return nothing
end
