################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
################################################################################

################################################################################
# Unit — registry                                                              #
################################################################################

const _UNIT_TYPES = DataType[]

"""
    register_unit_type!(T)

Record the concrete unit type `T` so that [`variable_unit`](@ref),
[`constraint_unit`](@ref) and [`solution_unit`](@ref) visit it. See
[`register_edge_type!`](@ref) for the rationale.
"""
function register_unit_type!(::Type{T}) where {T<:AbstractUnit}
    T in _UNIT_TYPES || push!(_UNIT_TYPES, T)
    return nothing
end

"the registered concrete unit types"
unit_types() = copy(_UNIT_TYPES)

################################################################################
# Unit — variables                                                             #
################################################################################

"""
    variable_unit_injection_current(nm; nw)

The current a unit injects into its node, one variable pair per in-service unit,
shared by every unit type.

A generator injects, a load and a shunt withdraw; the sign lives in the
constraints of the individual unit type, not in the node balance. That is what
lets [`constraint_node_balance`](@ref) sum over `U(i)` without knowing what kind
of unit each `u` is.
"""
function variable_unit_injection_current(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                                        ) where {P<:AbstractProblemType,F<:IVRFormulation}
    U = ids(nm, AbstractUnit; nw)

    var(nm; nw)[:cru] = JuMP.@variable(nm.model, [u in U], base_name = "$(nw)_cru", start = 0.0)
    var(nm; nw)[:ciu] = JuMP.@variable(nm.model, [u in U], base_name = "$(nw)_ciu", start = 0.0)

    return nothing
end

"""
    variable_unit(nm; nw)
    variable_unit(nm, T; nw)

The unit variables at network index `nw`: the shared injection currents,
followed by the internal variables of each registered unit type.
"""
function variable_unit(nm::NetworkModel; nw::Int = nw_id_default(nm))
    variable_unit_injection_current(nm; nw)
    for T in _UNIT_TYPES
        variable_unit(nm, T; nw)
    end

    return nothing
end

variable_unit(nm::NetworkModel, ::Type{T}; nw::Int = nw_id_default(nm)) where {T<:AbstractUnit} =
    nothing

################################################################################
# Unit — constraints                                                           #
################################################################################

"""
    constraint_unit(nm; nw)
    constraint_unit(nm, T; nw)

The behaviour of every registered unit type at network index `nw`.
"""
function constraint_unit(nm::NetworkModel; nw::Int = nw_id_default(nm))
    for T in _UNIT_TYPES
        constraint_unit(nm, T; nw)
    end

    return nothing
end

function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P,F,T<:AbstractUnit}
    isempty(ids(nm, T; nw)) && return nothing
    error("no constraints are defined for unit type `$T` under problem `$P` with formulation `$F`")
end

"""
    constraint_unit_power!(nm, u, p, q; nw)

Link the power a unit exchanges with its node to the current it injects,

```math
p = v^{\\text{r}}_{i} c^{\\text{r}}_{u} + v^{\\text{i}}_{i} c^{\\text{i}}_{u},
\\qquad
q = v^{\\text{i}}_{i} c^{\\text{r}}_{u} - v^{\\text{r}}_{i} c^{\\text{i}}_{u}.
```

`p` and `q` are injections, so a load hands in the negative of what it
withdraws. They may be numbers, variables or expressions, which is what lets one
implementation serve a generator whose power is a decision, a fixed load whose
power is data, and a flexible load whose power is a decision within an envelope.
"""
function constraint_unit_power!(nm::NetworkModel, u::Int, p, q; nw::Int)
    i        = node(unit(nm, u; nw))
    vr,  vi  = var(nm, :vr;  nw), var(nm, :vi;  nw)
    cru, ciu = var(nm, :cru; nw), var(nm, :ciu; nw)

    return (
        JuMP.@constraint(nm.model, p == vr[i] * cru[u] + vi[i] * ciu[u]),
        JuMP.@constraint(nm.model, q == vi[i] * cru[u] - vr[i] * ciu[u]))
end

################################################################################
# Unit — constraints across network indices                                    #
################################################################################

"""
    constraint_unit_coupling(nm)
    constraint_unit_coupling(nm, T)

The constraints of every registered unit type that tie network indices to one
another, rather than holding within one.

A problem builder calls this once, outside its loop over network indices,
because a constraint that spans indices cannot be written from inside it. The
energy balance of a [`Storage`](@ref) and the energy envelope of a
[`FlexibleLoad`](@ref) live here; a unit without such a constraint needs no
method.
"""
function constraint_unit_coupling(nm::NetworkModel)
    for T in _UNIT_TYPES
        constraint_unit_coupling(nm, T)
    end

    return nothing
end

constraint_unit_coupling(::NetworkModel, ::Type{T}) where {T<:AbstractUnit} = nothing

"""
    time_step(nm, n)

The duration of the time step at network index `n`, taken from the `:duration`
property of its coordinate along `:time` and defaulting to one hour.

```julia
Dimension(:time => [Dict{Symbol,Any}(:duration => 0.25) for _ in 1:96])
```
"""
time_step(nm::NetworkModel, n::Int) =
    has_dim(nm, :time) ? dim_prop(nm, n, :time, :duration, 1.0) : 1.0

"""
    require_time_dimension(nm, T)

Raise an informative error when a component type that couples network indices
along `:time` is used in a problem that has no such dimension.
"""
function require_time_dimension(nm::NetworkModel, ::Type{T}) where {T<:AbstractComponent}
    has_dim(nm, :time) && return nothing

    throw(ArgumentError("`$T` couples network indices along `:time`, but this problem has " *
                        "no such dimension; give it one with " *
                        "`set_dimension(data, Dimension(:time => n))`"))
end

################################################################################
# Unit — solution                                                              #
################################################################################

"""
    solution_unit(nm, nw)

The unit part of the solution at network index `nw`: for every unit the injected
current and the active and reactive power it injects into its node. Unit types
add their own entries through [`solution_unit`](@ref) methods.
"""
function solution_unit(nm::NetworkModel{P,F}, nw::Int) where {P,F<:IVRFormulation}
    sol = Dict{String,Any}()
    for T in _UNIT_TYPES, u in ids(nm, T; nw)
        i   = node(unit(nm, u; nw))
        vr  = JuMP.value(var(nm, :vr,  i; nw))
        vi  = JuMP.value(var(nm, :vi,  i; nw))
        cru = JuMP.value(var(nm, :cru, u; nw))
        ciu = JuMP.value(var(nm, :ciu, u; nw))
        sol["$u"] = Dict{String,Any}("type" => string(nameof(T)), "node" => i,
                                     "cru" => cru, "ciu" => ciu,
                                     "p" => vr * cru + vi * ciu,
                                     "q" => vi * cru - vr * ciu)
        solution_unit!(sol["$u"], nm, T, u, nw)
    end

    return sol
end

"add the type specific entries of unit `u` to its solution dictionary"
solution_unit!(::Dict{String,Any}, ::NetworkModel, ::Type{T}, ::Int, ::Int) where {T<:AbstractUnit} =
    nothing
