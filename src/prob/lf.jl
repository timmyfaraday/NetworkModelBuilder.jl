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
# Load flow                                                                    #
################################################################################

"""
    build_model!(nm::NetworkModel{<:LoadFlowProblem,<:IVRFormulation})

Build a load flow in the current-voltage rectangular formulation.

The builder names no component type. It calls the node functions, the edge
dispatcher and the unit dispatcher, and those walk the registries of edge and
unit types, so an extension package that registers a three-winding transformer
or a voltage dependent load gets it into this problem without touching this
file.

| stage      | what is added                                                     |
|:-----------|:------------------------------------------------------------------|
| variables  | node voltages `vr, vi`; terminal currents `cr, ci` and the internal variables of each edge type; injection currents `cru, ciu` and the internal variables of each unit type |
| constraints| the voltage anchor at the reference nodes, the magnitude setpoint at the `PV` nodes, Kirchhoff's current law at every node, the physics of every edge, the behaviour of every unit |
| objective  | zero, the problem is a feasibility problem                        |
"""
build_model!(nm::NetworkModel{P,F}) where {P<:LoadFlowProblem,F<:IVRFormulation} = _build_load_flow!(nm)
build_model!(nm::NetworkModel{P,F}) where {P<:LoadFlowProblem,F<:LPFFormulation} = _build_load_flow!(nm)

"""
    _build_load_flow!(nm)

The body both formulations share. Every call in it is a dispatch point, so the
definition of the problem says nothing about the formulation it is being built
in; swapping `IVRFormulation` for `LPFFormulation` changes which methods these
names resolve to and nothing else.
"""
function _build_load_flow!(nm::NetworkModel)
    for n in nw_ids(nm)
        variable_node_voltage(nm; nw = n)
        variable_edge(nm; nw = n)
        variable_unit(nm; nw = n)

        constraint_node_voltage_reference(nm; nw = n)
        constraint_node_voltage_setpoint(nm; nw = n)
        constraint_node_balance(nm; nw = n)
        constraint_edge(nm; nw = n)
        constraint_unit(nm; nw = n)
    end

    constraint_edge_coupling(nm)
    constraint_unit_coupling(nm)

    objective(nm)

    return nm
end

register_model!(LoadFlowProblem, IVRFormulation)
register_model!(LoadFlowProblem, LPFFormulation)

"""
    solve_lf(data, F, optimizer; kwargs...)

Solve a [`LoadFlowProblem`](@ref) in formulation `F`.
"""
solve_lf(data, ::Type{F}, optimizer; kwargs...) where {F<:AbstractFormulationType} =
    solve_model(data, LoadFlowProblem, F, optimizer; kwargs...)
