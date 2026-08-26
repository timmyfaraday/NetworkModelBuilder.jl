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
################################################################################

module NetworkModelBuilder

    # import pkgs
    import JuMP
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

    # include — components, following the (I, E, U) hierarchy
    include("comp/node/node.jl")

    include("comp/edge/edge.jl")
    include("comp/edge/branch.jl")

    include("comp/unit/unit.jl")
    include("comp/unit/generator.jl")
    include("comp/unit/load.jl")
    include("comp/unit/shunt.jl")

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
    export AbstractFormulationType, AbstractACFormulation, AbstractDCFormulation
    export AbstractCurrentFormulation, AbstractPowerFormulation
    export IVRFormulation, ACPFormulation, ACRFormulation, DCPFormulation

    # export — network index
    export Dimension, add_dimension
    export dim_names, has_dim, dim_length, dim_position, dim_prop, dim_meta, coordinates
    export nw_ids, similar_id, similar_ids, first_id, last_id, is_first_id, is_last_id
    export prev_id, next_id, prev_ids, next_ids

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

    # export — components
    export Node, NodeType, PQ, PV, REF, ISOLATED, reference_nodes
    export Branch, tap
    export Generator, Load, Shunt, generation_cost
    export register_edge_type!, register_unit_type!, edge_types, unit_types

    # export — model
    export NetworkModel, problem_type, formulation_type
    export instantiate_model, build_model!, optimize_model!, solve_model
    export register_model!, implemented_models

    # export — variables, constraints and objective
    export variable_node_voltage
    export variable_edge, variable_edge_terminal_current
    export variable_unit, variable_unit_injection_current
    export constraint_node_balance, constraint_node_voltage_reference
    export constraint_node_voltage_setpoint, constraint_node_voltage_limits
    export constraint_edge, constraint_edge_limits, constraint_unit
    export objective, objective_generation_cost, network_weight

    # export — solution
    export build_solution, nw_solution, print_summary, solution
    export solution_node, solution_edge, solution_unit, solution_unit!

    # export — problems
    export solve_lf, solve_opf

    # export — input and output
    export parse_file, parse_matpower

end
