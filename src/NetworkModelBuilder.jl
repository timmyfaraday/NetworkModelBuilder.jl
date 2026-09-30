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
# v0.6.0 - priced congestion, periods, the dc link and tabular input           #
# v0.7.0 - the asset model                                                     #
# v0.8.0 - the zorba adapter                                                   #
# v0.10.0 - the security screening output, towards the zorba dashboard         #
# v0.10.1 - src/comp/ is auto-included; its exports moved into it              #
# v0.10.2 - exports solution_tables                                            #
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

    "`include` every `.jl` file under `src/<dir>`, the file named like its own directory first"
    function _include_dir(dir::AbstractString)
        root = joinpath(@__DIR__, dir)
        for (path, subdirs, files) in walkdir(root)
            sort!(subdirs)
            jl      = sort!(filter(f -> endswith(f, ".jl"), files))
            self    = basename(path) * ".jl"
            ordered = self in jl ? [self; filter(!=(self), jl)] : jl
            for f in ordered
                include(joinpath(path, f))
            end
        end
        return nothing
    end

    # include — components, following the (I, E, U) hierarchy; each directory
    # is walked rather than listed, so a new component type needs no edit here
    _include_dir("comp/node")
    _include_dir("comp/edge")
    _include_dir("comp/unit")

    # include — core, depending on the components
    include("core/objective.jl")
    include("core/solution.jl")

    # include — problems
    include("prob/lf.jl")
    include("prob/opf.jl")
    include("prob/rd.jl")

    # include — input and output
    include("io/common.jl")
    include("io/tables.jl")
    include("io/matpower.jl")
    include("io/zorba.jl")
    include("io/dashboard.jl")

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

    # export — model
    export constrain!, variable!, variables!, variable_container!, bound!
    export registered_constraints
    export NetworkModel, problem_type, formulation_type
    export instantiate_model, build_model!, update_model!, optimize_model!, solve_model
    export register_model!, implemented_models

    # export — objective
    export objective, objective_generation_cost, network_weight, default_weight
    export network_cost, minimize_network_cost, dispatch_cost
    export horizon_cost, period_cost, component_period_cost, period_weight
    export objective_redispatch_cost

    # export — solution
    export build_solution, nw_solution, print_summary, solution, solution_tables

    # export — the redispatch problem
    export Redispatch, OverloadPrice, redispatch_setup
    export is_monitored, monitored_edges, overload_price, overload_cost
    export control_mode, is_preventive, is_corrective
    export redispatch_controls, redispatch_cost
    export constraint_redispatch_control, constraint_overload_peak
    export solution_overload_peak

    # export — the rolling horizon
    export window, window_indices, initial_state, interior_state
    export solve_rolling_horizon
    export same_topology, same_structure, structure_gates, structure_varies

    # export — problems
    export solve_lf, solve_opf, solve_rd

    # export — input and output
    export parse_file, parse_matpower, parse_tables, parse_arrow, component_types

    # export — the zorba adapter
    export ZorbaLink, ZorbaStudy
    export parse_zorba, zorba_study, solve_zorba, zorba_tables, write_zorba

    # export — security screening output, e.g. towards a dashboard
    export security_tables, write_security_tables

end
