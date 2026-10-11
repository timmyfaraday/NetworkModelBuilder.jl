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
# v0.14.0 - variable and solution keys follow the nomenclature                 #
# v0.14.0 - the fields follow the nomenclature                                 #
# v0.14.0 - the docstrings follow the nomenclature                             #
# v0.15.0 - constraint keys and ids follow the nomenclature                    #
# v0.15.0 - functions that write rows, duals and letters follow the map        #
################################################################################

export AbstractLoad, demand

################################################################################
# Load — data                                                                  #
################################################################################

"""
    AbstractLoad <: AbstractUnit

A unit that withdraws power from its node.

What separates a load from an [`AbstractGenerator`](@ref) is not the sign of the
power — a load may well have a negative reactive demand — but where the number
comes from. A [`FixedLoad`](@ref) states what it takes and the model has no say;
a [`FlexibleLoad`](@ref) lets the model choose within an envelope, subject to
getting the same energy over the horizon.

Both are constant *power*, not constant impedance: at any voltage they take the
same `p` and `q`. The constant impedance case is an [`AbstractShunt`](@ref).

Every load type shares one implementation of its constraint, and differs only in
what [`demand`](@ref) returns.
"""
abstract type AbstractLoad <: AbstractUnit end

"""
    demand(nm, ld, u; nw)

The active and reactive power load `u` withdraws at network index `nw`, as a
pair.

This is the single point at which load types differ. A [`FixedLoad`](@ref)
returns two numbers. A [`FlexibleLoad`](@ref) returns two numbers in a power
flow, where it has no freedom, and the variable it is free to choose in a
dispatch problem.
"""
function demand end

################################################################################
# Load — constraints                                                           #
################################################################################

"""
    fnct_unit(nm, T; nw)

Fix the power a load injects into its node at minus its withdrawal,

```math
v^{\\text{r}}_{i} i^{\\text{r}}_{u} + v^{\\text{i}}_{i} i^{\\text{i}}_{u} = -p^{\\text{d}}_{u},
\\qquad
v^{\\text{i}}_{i} i^{\\text{r}}_{u} - v^{\\text{r}}_{i} i^{\\text{i}}_{u} = -q^{\\text{d}}_{u}.
```

Written this way the load draws a constant power at any voltage, which is the
usual assumption; a voltage dependent load is a different unit type.
"""
function fnct_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:IVRFormulation,T<:AbstractLoad}
    power = get!(() -> Dict{Int,Any}(), con(nm; nw), :cstr_unit_power)

    for u in ids(nm, T; nw)
        ld           = unit(nm, u; nw)::T
        p_set, q_set = demand(nm, ld, u; nw)
        power[u] = fnct_unit_power!(nm, u, -p_set, -q_set; nw)
    end

    return nothing
end

################################################################################
# Load — solution                                                              #
################################################################################

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel{P,F}, ::Type{T},
                        u::Int, nw::Int) where {P<:AbstractProblemType,F<:AbstractACFormulation,T<:AbstractLoad}
    p_set, q_set = demand(nm, unit(nm, u; nw)::T, u; nw)
    sol["p_set"] = _value(p_set)
    sol["q_set"] = _value(q_set)

    return nothing
end

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel{P,F}, ::Type{T},
                        u::Int, nw::Int) where {P<:AbstractProblemType,F<:LPFFormulation,T<:AbstractLoad}
    sol["p_set"] = _value(first(demand(nm, unit(nm, u; nw)::T, u; nw)))

    return nothing
end

################################################################################
# Load — the linearized formulation                                            #
################################################################################

"""
    fnct_unit(nm, T; nw)

Fix the active power a load injects at minus its withdrawal,
`p_{u} = -p^{\\text{d}}_{u}`. The reactive demand plays no part in a linearized
formulation.
"""
function fnct_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:LPFFormulation,T<:AbstractLoad}
    power = get!(() -> Dict{Int,Any}(), con(nm; nw), :cstr_unit_injection)

    for u in ids(nm, T; nw)
        p_set = first(demand(nm, unit(nm, u; nw)::T, u; nw))
        power[u] = fnct_unit_injection!(nm, u, -p_set; nw)
    end

    return nothing
end
