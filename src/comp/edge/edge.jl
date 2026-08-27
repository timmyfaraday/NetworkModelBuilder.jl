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
# Edge — registry                                                              #
################################################################################

const _EDGE_TYPES = DataType[]

"""
    register_edge_type!(T)

Record the concrete edge type `T` so that [`variable_edge`](@ref),
[`constraint_edge`](@ref) and [`solution_edge`](@ref) visit it.

A problem definition never names the edge types it supports: it calls the
dispatchers, which walk the registry. An extension package that adds an edge
type — a three-winding transformer, a multi-terminal HVDC converter station —
registers it once and every problem picks it up.
"""
function register_edge_type!(::Type{T}) where {T<:AbstractEdge}
    T in _EDGE_TYPES || push!(_EDGE_TYPES, T)
    return nothing
end

"the registered concrete edge types"
edge_types() = copy(_EDGE_TYPES)

################################################################################
# Edge — variables                                                             #
################################################################################

"""
    variable_edge_terminal_current(nm; nw)

The current flowing from a node into an edge terminal, one variable pair per
arc, shared by every edge type.

These are the only edge variables the node balance sees, which is what lets an
edge have any number of terminals: an edge with terminals `(e, i, j, k)` simply
contributes three arcs.
"""
function variable_edge_terminal_current(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                                       ) where {P<:AbstractProblemType,F<:IVRFormulation}
    A = arcs(nm; nw)

    var(nm; nw)[:cr] = JuMP.@variable(nm.model, [a in A], base_name = "$(nw)_cr", start = 0.0)
    var(nm; nw)[:ci] = JuMP.@variable(nm.model, [a in A], base_name = "$(nw)_ci", start = 0.0)

    return nothing
end

"""
    variable_edge_terminal_flow(nm; nw)

The flow variables every edge terminal has, whichever formulation is being
built: currents under a [`IVRFormulation`](@ref), active power under a
[`LPFFormulation`](@ref). A problem builder calls [`variable_edge`](@ref),
which calls this, and so never has to ask which.
"""
function variable_edge_terminal_flow end

variable_edge_terminal_flow(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                           ) where {P<:AbstractProblemType,F<:IVRFormulation} =
    variable_edge_terminal_current(nm; nw)

variable_edge_terminal_flow(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                           ) where {P<:AbstractProblemType,F<:LPFFormulation} =
    variable_edge_terminal_power(nm; nw)

"""
    variable_edge_terminal_power(nm; nw)

The active power flowing from a node into an edge terminal, one variable per
arc, shared by every edge type. The linearized counterpart of
[`variable_edge_terminal_current`](@ref).
"""
function variable_edge_terminal_power(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                                     ) where {P<:AbstractProblemType,F<:LPFFormulation}
    A = arcs(nm; nw)

    var(nm; nw)[:p] = JuMP.@variable(nm.model, [a in A], base_name = "$(nw)_p", start = 0.0)

    return nothing
end

"""
    variable_edge(nm; nw)
    variable_edge(nm, T; nw)

The edge variables at network index `nw`: the shared terminal currents, followed
by the internal variables of each registered edge type.
"""
function variable_edge(nm::NetworkModel; nw::Int = nw_id_default(nm))
    variable_edge_terminal_flow(nm; nw)
    for T in _EDGE_TYPES
        variable_edge(nm, T; nw)
    end

    return nothing
end

function variable_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P,F,T<:AbstractEdge}
    isempty(ids(nm, T; nw)) && return nothing
    error("no variables are defined for edge type `$T` under formulation `$F`")
end

################################################################################
# Edge — constraints                                                           #
################################################################################

"""
    constraint_edge(nm; nw)
    constraint_edge(nm, T; nw)

The physics of every registered edge type at network index `nw`.
"""
function constraint_edge(nm::NetworkModel; nw::Int = nw_id_default(nm))
    for T in _EDGE_TYPES
        constraint_edge(nm, T; nw)
    end

    return nothing
end

function constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P,F,T<:AbstractEdge}
    isempty(ids(nm, T; nw)) && return nothing
    error("no constraints are defined for edge type `$T` under problem `$P` with formulation `$F`")
end

"""
    constraint_edge_limits(nm; nw)
    constraint_edge_limits(nm, T; nw)

The operating limits of every registered edge type, i.e., the limits that only a
dispatch problem imposes. Defaults to a no-op so that an edge type without
limits needs no method.
"""
function constraint_edge_limits(nm::NetworkModel; nw::Int = nw_id_default(nm))
    for T in _EDGE_TYPES
        constraint_edge_limits(nm, T; nw)
    end

    return nothing
end

constraint_edge_limits(nm::NetworkModel, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {T<:AbstractEdge} = nothing

"""
    constraint_edge_coupling(nm)
    constraint_edge_coupling(nm, T)

The constraints of every registered edge type that tie network indices to one
another. The counterpart of [`constraint_unit_coupling`](@ref); no edge type in
the package needs one yet, and the hook is here so that one can be added without
touching a problem builder.
"""
function constraint_edge_coupling(nm::NetworkModel)
    for T in _EDGE_TYPES
        constraint_edge_coupling(nm, T)
    end

    return nothing
end

constraint_edge_coupling(::NetworkModel, ::Type{T}) where {T<:AbstractEdge} = nothing

################################################################################
# Edge — solution                                                              #
################################################################################

"""
    solution_edge(nm, nw)

The edge part of the solution at network index `nw`: for every arc the terminal
current and the active and reactive power flowing from the node into that
terminal.
"""
function solution_edge(nm::NetworkModel{P,F}, nw::Int) where {P<:AbstractProblemType,F<:IVRFormulation}
    sol = Dict{String,Any}()
    for T in _EDGE_TYPES, e in ids(nm, T; nw)
        entry = Dict{String,Any}("terminal" => Dict{String,Any}())
        for a in edge_arcs(nm, e; nw)
            vr = JuMP.value(var(nm, :vr, a.node; nw))
            vi = JuMP.value(var(nm, :vi, a.node; nw))
            cr = JuMP.value(var(nm, :cr, a;      nw))
            ci = JuMP.value(var(nm, :ci, a;      nw))
            entry["terminal"]["$(a.terminal)"] = Dict{String,Any}(
                "node" => a.node, "cr" => cr, "ci" => ci,
                "p" => vr * cr + vi * ci, "q" => vi * cr - vr * ci)
        end
        solution_edge!(entry, nm, T, e, nw)
        sol["$e"] = entry
    end

    return sol
end

"add the type specific entries of edge `e` to its solution dictionary"
solution_edge!(::Dict{String,Any}, ::NetworkModel, ::Type{T}, ::Int, ::Int) where {T<:AbstractEdge} =
    nothing

"the edge part of the solution under a linearized formulation"
function solution_edge(nm::NetworkModel{P,F}, nw::Int) where {P<:AbstractProblemType,F<:LPFFormulation}
    sol = Dict{String,Any}()
    for T in _EDGE_TYPES, e in ids(nm, T; nw)
        entry = Dict{String,Any}("terminal" => Dict{String,Any}())
        for a in edge_arcs(nm, e; nw)
            entry["terminal"]["$(a.terminal)"] = Dict{String,Any}(
                "node" => a.node, "p" => JuMP.value(var(nm, :p, a; nw)))
        end
        solution_edge!(entry, nm, T, e, nw)
        sol["$e"] = entry
    end

    return sol
end
