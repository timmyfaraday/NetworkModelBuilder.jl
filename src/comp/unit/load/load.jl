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
    constraint_unit(nm, T; nw)

Fix the power a load injects into its node at minus its withdrawal,

```math
v^{\\text{r}}_{i} c^{\\text{r}}_{u} + v^{\\text{i}}_{i} c^{\\text{i}}_{u} = -p^{\\text{d}}_{u},
\\qquad
v^{\\text{i}}_{i} c^{\\text{r}}_{u} - v^{\\text{r}}_{i} c^{\\text{i}}_{u} = -q^{\\text{d}}_{u}.
```

Written this way the load draws a constant power at any voltage, which is the
usual assumption; a voltage dependent load is a different unit type.
"""
function constraint_unit(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:IVRFormulation,T<:AbstractLoad}
    power = get!(() -> Dict{Int,Any}(), con(nm; nw), :load_power)

    for u in ids(nm, T; nw)
        ld     = unit(nm, u; nw)::T
        pd, qd = demand(nm, ld, u; nw)
        power[u] = constraint_unit_power!(nm, u, -pd, -qd; nw)
    end

    return nothing
end

################################################################################
# Load — solution                                                              #
################################################################################

function solution_unit!(sol::Dict{String,Any}, nm::NetworkModel, ::Type{T}, u::Int, nw::Int
                       ) where {T<:AbstractLoad}
    pd, qd = demand(nm, unit(nm, u; nw)::T, u; nw)
    sol["pd"] = _value(pd)
    sol["qd"] = _value(qd)

    return nothing
end
