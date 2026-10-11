################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.14.0 - initial implementation                                             #
# v0.15.0 - debug_mode names variables and constraints, off by default         #
################################################################################

# A variable and a constraint are named from their key and their id, and only
# when the solve asks for `debug_mode`. Nothing reads a name back, but a solver
# log, `print(model)` and an LP file do, and building them is a large part of
# what a cold build of a large model spends its time on.

"two nodes, a cheap generator behind a rated branch, a dear one at the load, over `dim`"
function named_network(; dim::Dimension = Dimension())
    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, v_magn_set = 1.0), 2 => Node(; id = 2))
    E = Dict{Int,AbstractEdge}(
        1 => Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.1, s_max = 0.5))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, p_max = 5.0, q_min = -5.0, q_max = 5.0,
                       p_set = 1.0, c = [0.0, 10.0]),
        2 => Generator(; id = 2, node = 2, p_max = 5.0, q_min = -5.0, q_max = 5.0,
                       p_set = 0.0, c = [0.0, 100.0]),
        3 => FixedLoad(; id = 3, node = 2, p_set = 1.0, q_set = 0.0))

    return NetworkData(Network(I, E, U; dim); name = "named", s_base_mva = 100.0)
end

"whether no variable and no constraint of the model has a name"
unnamed(nm) = all(v -> isempty(JuMP.name(v)), JuMP.all_variables(nm.model)) &&
              all(r -> isempty(JuMP.name(first(r))), values(registered_constraints(nm)))

"whether every variable and every constraint of the model has a name"
named(nm) = all(v -> !isempty(JuMP.name(v)), JuMP.all_variables(nm.model)) &&
            all(r -> !isempty(JuMP.name(first(r))), values(registered_constraints(nm)))

@testset "debug mode" begin

    @testset "a variable is named from its key and its id" begin
        nm = instantiate_model(named_network(; dim = Dimension(:time => 2)),
                               OptimalPowerFlowProblem, IVRFormulation; debug_mode = true)

        @test JuMP.name(_NMB.var(nm, :p_gen, 1; nw = 1)) == "1_p_gen[1]"
        @test JuMP.name(_NMB.var(nm, :p_gen, 2; nw = 2)) == "2_p_gen[2]"
        @test JuMP.name(_NMB.var(nm, :i_ser_real, 1; nw = 1)) == "1_i_ser_real[1]"
        @test JuMP.name(_NMB.var(nm, :v_real; nw = 1)[2]) == "1_v_real[2]"
        @test startswith(JuMP.name(_NMB.var(nm, :i_term_real; nw = 1)[Arc(1, 1, 1)]), "1_i_term_real[")
        @test all(v -> !isempty(JuMP.name(v)), JuMP.all_variables(nm.model))

        # a variable that belongs to one terminal of an edge, or to one position of it
        @test _NMB._variable_name(2, :t_real, Arc(3, 2, 5)) == "2_t_real[3,2]"
        @test _NMB._variable_name(1, :z_step, (Arc(3, 2, 5), 4)) == "1_z_step[3,2,4]"
        @test _NMB._variable_name(1, :p_gen, 7) == "1_p_gen[7]"
    end

    @testset "a constraint is named from its key and its id" begin
        for F in (IVRFormulation, LPFFormulation)
            nm   = instantiate_model(named_network(; dim = Dimension(:time => 2)),
                                     OptimalPowerFlowProblem, F; debug_mode = true)
            rows = registered_constraints(nm)

            @test length(rows) > 10
            @test all(p -> JuMP.name(first(p.second)) == _NMB._constraint_name(p.first...), rows)
            @test length(unique(JuMP.name(first(v)) for v in values(rows))) == length(rows)
            @test named(nm)
        end

        # the id of a component, of a part of it, of a terminal, of a loop and of a control
        @test _NMB._constraint_name(2, :k, 7) == "2_k[7]"
        @test _NMB._constraint_name(1, :k, (4, :real)) == "1_k[4,real]"
        @test _NMB._constraint_name(1, :k, (Arc(3, 2, 5), :imag)) == "1_k[3,2,imag]"
        @test _NMB._constraint_name(3, :k, ((1, 2, 3), :max)) == "3_k[1,2,3,max]"
        @test _NMB._constraint_name(1, :k, (:unit, 7, :p_gen_up)) == "1_k[unit,7,p_gen_up]"
    end

    @testset "by default nothing is named, and the model is the same" begin
        data  = named_network()
        plain = instantiate_model(data, OptimalPowerFlowProblem, IVRFormulation)
        debug = instantiate_model(data, OptimalPowerFlowProblem, IVRFormulation; debug_mode = true)

        @test unnamed(plain) && named(debug)
        @test JuMP.num_variables(plain.model) == JuMP.num_variables(debug.model)
        @test JuMP.num_constraints(plain.model; count_variable_in_set_constraints = true) ==
              JuMP.num_constraints(debug.model; count_variable_in_set_constraints = true)

        for F in (IVRFormulation, LPFFormulation)
            off = quiet(() -> solve_opf(data, F, OPTIMIZER))
            on  = quiet(() -> solve_opf(data, F, OPTIMIZER; debug_mode = true))

            @test on["termination_status"] == off["termination_status"]
            @test on["objective"] ≈ off["objective"] atol = 1e-9
        end
    end

    @testset "a model handed in is set either way" begin
        data = named_network()

        on = JuMP.Model()
        @test JuMP.set_string_names_on_creation(on)
        instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation; jump_model = on)
        @test !JuMP.set_string_names_on_creation(on)

        off = JuMP.Model()
        JuMP.set_string_names_on_creation(off, false)
        nm = instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation; jump_model = off,
                               debug_mode = true)
        @test JuMP.set_string_names_on_creation(off)
        @test named(nm)
    end

    @testset "a rolling horizon names every window it builds, or none" begin
        data = named_network(; dim = Dimension(:time => 3))

        for reuse in (false, true), debug_mode in (false, true)
            flags = Bool[]
            quiet(() -> solve_rolling_horizon(data, RedispatchProblem, LPFFormulation, OPTIMIZER;
                                              horizon = 2, step = 1, reuse, debug_mode,
                                              solution_processors = [(nm, _) -> push!(flags, debug_mode ? named(nm) : unnamed(nm))]))

            @test length(flags) == 3
            @test all(flags)
        end
    end

    @testset "set_string_name is not asked for any more, nor a name by hand" begin
        data = named_network()
        nm   = instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation; build = false)

        @test_throws MethodError instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation;
                                                   set_string_name = true)
        @test_throws MethodError variable!(nm, :probe, 1; nw = 1, base_name = "probe")
        @test_throws MethodError variables!(nm, :probe, 1:2; nw = 1, base_name = "probe")
    end
end
