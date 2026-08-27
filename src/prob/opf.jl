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
# Optimal power flow                                                           #
################################################################################

"""
    build_model!(nm::NetworkModel{<:OptimalPowerFlowProblem,<:IVRFormulation})

Build an optimal power flow in the current-voltage rectangular formulation.

Compare this builder with the one in `src/prob/lf.jl`: the calls are almost the
same, and the difference between a load flow and a dispatch problem lives in the
methods those calls resolve to. The voltage variables become bounded, the
reference node fixes an angle instead of a complex voltage, the `PV` magnitude
setpoint disappears in favour of magnitude limits, the generator setpoints
disappear in favour of operating limits, the edge limits appear, and the
objective stops being zero.

| stage      | what is added                                                     |
|:-----------|:------------------------------------------------------------------|
| variables  | as in a load flow, but the node voltages and the generator power are bounded |
| constraints| the angle anchor at the reference nodes, the voltage magnitude limits, Kirchhoff's current law, the physics and the limits of every edge, the behaviour of every unit |
| objective  | the total generation cost                                         |
"""
function build_model!(nm::NetworkModel{P,F}) where {P<:OptimalPowerFlowProblem,F<:IVRFormulation}
    for n in nw_ids(nm)
        variable_node_voltage(nm; nw = n)
        variable_edge(nm; nw = n)
        variable_unit(nm; nw = n)

        constraint_node_voltage_reference(nm; nw = n)
        constraint_node_voltage_limits(nm; nw = n)
        constraint_node_balance(nm; nw = n)
        constraint_edge(nm; nw = n)
        constraint_edge_limits(nm; nw = n)
        constraint_unit(nm; nw = n)
    end

    constraint_edge_coupling(nm)
    constraint_unit_coupling(nm)

    objective(nm)

    return nm
end

register_model!(OptimalPowerFlowProblem, IVRFormulation)

"""
    solve_opf(data, F, optimizer; kwargs...)

Solve an [`OptimalPowerFlowProblem`](@ref) in formulation `F`.
"""
solve_opf(data, ::Type{F}, optimizer; kwargs...) where {F<:AbstractFormulationType} =
    solve_model(data, OptimalPowerFlowProblem, F, optimizer; kwargs...)
