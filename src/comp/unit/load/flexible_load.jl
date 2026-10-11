################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
# v0.6.0 - the energy balance runs per period                                  #
# v0.10.1 - exports its own public names                                       #
# v0.12.9 - the energy rows are registered by constrain! alone                 #
# v0.14.0 - a variable is named by the model, not at the call site             #
# v0.14.0 - variable and solution keys follow the nomenclature                 #
# v0.14.0 - the fields follow the nomenclature                                 #
################################################################################

export FlexibleLoad, power_factor_ratio

################################################################################
# FlexibleLoad — data                                                          #
################################################################################

"""
    FlexibleLoad <: AbstractLoad

A unit `(u, i)` whose demand the model may shift in time, as long as it receives
the same energy over each period.

In a dispatch problem the withdrawal at each network index is a decision held
between `p_min` and `p_max`, and one constraint per period ties the profile
together: the energy it takes must equal `e_set`. A `:time` dimension with no
grouping declared is one period, so unless the problem says otherwise this is
the whole horizon. In a power flow it has no freedom and behaves as a
[`FixedLoad`](@ref) at `p_nom`.

This is the first component in the package whose constraints span network
indices, so it needs the problem to have a `:time` dimension and says so if it
does not. The duration of a step comes from the `:duration` property of that
dimension, see [`time_step`](@ref).

Reactive demand follows the active demand at the power factor of the nominal
point, so that shifting a load does not silently change what it does to voltages.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `node`: the node the load is connected to.
- `p_nom`, `q_nom`: the demand it would take without flexibility [pu].
- `p_min`, `p_max`: the limits within which the demand may be shifted [pu].
- `e_set`: the energy it must receive over each period [pu·h]. `NaN`, the
  default, means the energy the nominal profile would have taken over that
  period, which is the one that stays right whatever the grouping.
- `status`: whether the load is in service.
- `ext`: free-form storage.
"""
Base.@kwdef struct FlexibleLoad <: AbstractLoad
    id    ::Int
    name  ::String                   = ""
    node  ::Int
    p_nom ::NetworkQuantity{Float64} = 0.0
    q_nom ::NetworkQuantity{Float64} = 0.0
    p_min ::NetworkQuantity{Float64} = 0.0
    p_max ::NetworkQuantity{Float64} = Inf
    e_set ::Float64                  = NaN
    status::NetworkQuantity{Bool}    = true
    ext   ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function FlexibleLoad(id, name, node, p_nom, q_nom, p_min, p_max,
                          e_set, status, ext)
        all_nw(<=, p_min, p_max) ||
            throw(ArgumentError("flexible load $id has p_min above p_max"))
        return new(id, name, node, p_nom, q_nom, p_min, p_max,
                   e_set, status, ext)
    end
end

register_unit_type!(FlexibleLoad)

"a flexible load is given an upper bound only where `p_max` is finite"
structure_gates(::FlexibleLoad) = (:p_max,)

"the ratio of reactive to active demand at the nominal point"
power_factor_ratio(ld::FlexibleLoad) = iszero(ld.p_nom) ? 0.0 : ld.q_nom / ld.p_nom

################################################################################
# FlexibleLoad — variables                                                     #
################################################################################

"""
    variable_unit(nm, FlexibleLoad; nw)

The active demand of every in-service flexible load, held between `p_min` and
`p_max`. A power flow creates nothing: there the demand is its nominal value.
"""
function variable_unit(nm::NetworkModel{P,F}, ::Type{FlexibleLoad}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractDispatchProblem,F<:AbstractFormulationType}
    isempty(ids(nm, FlexibleLoad; nw)) && return nothing
    require_time_dimension(nm, FlexibleLoad)

    variable_container!(nm, :p_flex; nw)

    for u in ids(nm, FlexibleLoad; nw)
        ld = unit(nm, u; nw)::FlexibleLoad
        variable!(nm, :p_flex, u; nw, start = ld.p_nom,
                  lower = ld.p_min, upper = ld.p_max)
    end

    return nothing
end

demand(::NetworkModel, ld::FlexibleLoad, ::Int; nw::Int) = (ld.p_nom, ld.q_nom)

function demand(nm::NetworkModel{P,F}, ld::FlexibleLoad, u::Int; nw::Int
               ) where {P<:AbstractDispatchProblem,F<:AbstractFormulationType}
    p_flex = var(nm, :p_flex, u; nw)

    return (p_flex, JuMP.@expression(nm.model, power_factor_ratio(ld) * p_flex))
end

################################################################################
# FlexibleLoad — constraints across network indices                            #
################################################################################

"""
    constraint_unit_coupling(nm, FlexibleLoad; nw)

One energy balance per flexible load per period,

```math
\\sum_{n \\in \\mathcal{P}} \\Delta t_{n} \\, p^{\\text{d}}_{u,n} = E_{u},
```

where the period `𝒫` runs over the `:time` coordinates grouped with `n`, see
[`period_ids`](@ref), while every other coordinate of the network index is held
fixed. A problem with a contingency dimension therefore gets one balance per
contingency, which is what makes each contingency a self-contained day rather
than a shared one; a `:time` dimension with no grouping gives one period
spanning the whole horizon, which is the behaviour this had before periods
existed.
"""
function constraint_unit_coupling(nm::NetworkModel{P,F}, ::Type{FlexibleLoad}
                                 ) where {P<:AbstractDispatchProblem,F<:AbstractFormulationType}
    isempty(ids(nm, FlexibleLoad; nw = nw_id_default(nm))) && return nothing
    require_time_dimension(nm, FlexibleLoad)

    for n in nw_ids(nm)
        is_first_period_id(nm, n, :time) || continue
        window = period_ids(nm, n, :time)

        for u in ids(nm, FlexibleLoad; nw = n)
            ld     = unit(nm, u; nw = n)::FlexibleLoad
            target = isnan(ld.e_set) ?
                sum(time_step(nm, m) * unit(nm, u; nw = m).p_nom for m in window) :
                ld.e_set

            constrain!(nm, :flexible_energy, u, JuMP.@build_constraint(
                sum(time_step(nm, m) * var(nm, :p_flex, u; nw = m) for m in window) == target); nw = n)
        end
    end

    return nothing
end
