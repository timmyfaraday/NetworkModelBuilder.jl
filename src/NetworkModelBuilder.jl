################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
# v0.2.0 - network dependent data stored per component                         #
# v0.3.0 - component hierarchy                                                 #
# v0.4.0 - the linearized formulation                                          #
# v0.5.0 - the redispatch problem                                              #
################################################################################

module NetworkModelBuilder

    # import pkgs
    import JuMP
    import MathOptInterface as MOI
    import Printf

    # pkg constants
    const _NMB = NetworkModelBuilder

    # paths
    const BASE_DIR = dirname(@__DIR__)

    # include — core
    include("core/types.jl")
    include("core/dimension.jl")
    include("core/network.jl")
    include("core/model.jl")
    include("core/rebuild.jl")
    include("core/redispatch.jl")
    include("core/window.jl")

    # include — components, following the (I, E, U) hierarchy
    include("comp/node/node.jl")

    include("comp/edge/edge.jl")
    include("comp/edge/pi_model.jl")
    include("comp/edge/branch/branch.jl")
    include("comp/edge/branch/cable.jl")
    include("comp/edge/branch/overhead_line.jl")
    include("comp/edge/transformer/transformer.jl")
    include("comp/edge/transformer/phase_shifter.jl")
    include("comp/edge/transformer/tap_changer.jl")
    include("comp/edge/transformer/multi_winding.jl")

    include("comp/unit/unit.jl")
    include("comp/unit/generator/generator.jl")
    include("comp/unit/load/load.jl")
    include("comp/unit/load/fixed_load.jl")
    include("comp/unit/load/flexible_load.jl")
    include("comp/unit/storage/storage.jl")
    include("comp/unit/shunt/shunt.jl")

    # include — core, depending on the components
    include("core/objective.jl")
    include("core/solution.jl")

    # include — problems
    include("prob/lf.jl")
    include("prob/opf.jl")
    include("prob/rd.jl")

    # include — input and output
    include("io/common.jl")
    include("io/matpower.jl")

    # export — paths
    export BASE_DIR

    # export — problem types
    export AbstractProblemType, AbstractPowerFlowProblem, AbstractDispatchProblem
    export LoadFlowProblem, OptimalPowerFlowProblem, RedispatchProblem

    # export — formulation types
    export AbstractFormulationType, AbstractACFormulation, AbstractLinearizedFormulation
    export AbstractCurrentFormulation, AbstractPowerFormulation
    export IVRFormulation, ACPFormulation, ACRFormulation, LPFFormulation

    # export — network index
    export Dimension, add_dimension
    export dim_names, has_dim, dim_length, dim_position, dim_prop, dim_meta, coordinates
    export nw_ids, similar_id, similar_ids, first_id, last_id, is_first_id, is_last_id
    export prev_id, next_id, prev_ids, next_ids
    export period_id, period_ids, is_first_period_id, is_last_period_id, period_count

    # export — network dependent data
    export NetworkVector, NetworkQuantity
    export nw_value, nw_values, nw_vector, nw_component
    export is_nw_varying, has_nw_data, all_nw

    # export — extended graph
    export AbstractComponent, AbstractNode, AbstractEdge, AbstractUnit
    export Arc, Topology, Network, NetworkData
    export set_dimension, replicate
    export network, dimension, baseMVA, topology, topologies, switchable, nw_id_default
    export nodes, edges, units, arcs, node, edge, unit
    export node_arcs, node_units, edge_arcs, ids
    export component_id, status, is_active, terminals, nterminals
    export edge_id, terminal_id, node_id

    # export — components, node
    export Node, NodeType, PQ, PV, REF, ISOLATED, reference_nodes

    # export — components, edge
    export AbstractBranch, Branch, Cable, OverheadLine
    export AbstractTransformer, AbstractTwoWindingTransformer
    export Transformer, PhaseShifter, TapChanger, MultiWindingTransformer
    export impedance, shunt_admittance, tap_ratio, dynamic_rating

    # export — components, unit
    export AbstractGenerator, Generator, generation_cost, marginal_cost
    export AbstractLoad, FixedLoad, FlexibleLoad, demand, power_factor_ratio
    export AbstractStorage, Storage
    export AbstractShunt, Shunt

    # export — component registries
    export register_edge_type!, register_unit_type!, edge_types, unit_types

    # export — model
    export constrain!, variable!, variables!, variable_container!, bound!
    export registered_constraints
    export NetworkModel, problem_type, formulation_type
    export instantiate_model, build_model!, update_model!, optimize_model!, solve_model
    export register_model!, implemented_models

    # export — variables, constraints and objective
    export variable_node_voltage
    export variable_edge, variable_edge_terminal_flow
    export variable_edge_terminal_current, variable_edge_terminal_power
    export variable_unit, variable_unit_injection
    export variable_unit_injection_current, variable_unit_injection_power
    export constraint_node_balance, constraint_node_voltage_reference
    export constraint_node_voltage_setpoint, constraint_node_voltage_limits
    export constraint_edge, constraint_edge_limits, constraint_edge_coupling
    export constraint_unit, constraint_unit_coupling
    export constraint_pi_section!, constraint_edge_rating!
    export constraint_edge_angle_difference!, constraint_unit_power!
    export constraint_linear_flow!, constraint_linear_limits!
    export variable_edge_overload!
    export constraint_unit_injection!, susceptance, phase_shift
    export variable_storage_active!, variable_storage_reactive!
    export variable_edge_series_current, variable_two_winding!
    export constraint_two_winding_limits!
    export time_step, require_time_dimension
    export objective, objective_generation_cost, network_weight, default_weight
    export network_cost, minimize_network_cost
    export objective_redispatch_cost

    # export — solution
    export build_solution, nw_solution, print_summary, solution
    export solution_node, solution_edge, solution_unit
    export solution_edge!, solution_unit!, solution_tap

    # export — the redispatch problem
    export Redispatch, OverloadPrice, redispatch_setup
    export is_monitored, monitored_edges, overload_price, overload_cost
    export control_mode, is_preventive, is_corrective
    export redispatch_controls, redispatch_cost, redispatch_price
    export constraint_redispatch_control

    # export — the rolling horizon
    export window, window_indices, initial_state, solve_rolling_horizon
    export same_topology, same_structure, structure_gates, structure_varies

    # export — problems
    export solve_lf, solve_opf, solve_rd

    # export — input and output
    export parse_file, parse_matpower

end
