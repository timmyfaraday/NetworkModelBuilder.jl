################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.14.0 - initial implementation                                             #
################################################################################

# A variable is named from its key and its id, and a solve can leave the names
# out. Nothing reads a name back, but a solver log or `print(model)` does, which
# is why they are on by default, and building them is what a cold build of a
# large model spends a fifth of its time on.

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

"whether no variable of the model has a name"
unnamed(nm) = all(v -> isempty(JuMP.name(v)), JuMP.all_variables(nm.model))

@testset "variable names" begin

    @testset "a variable is named from its key and its id" begin
        nm = instantiate_model(named_network(; dim = Dimension(:time => 2)),
                               OptimalPowerFlowProblem, IVRFormulation)

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

    @testset "a solve can leave the variables unnamed, and the model is the same" begin
        data   = named_network()
        named  = instantiate_model(data, OptimalPowerFlowProblem, IVRFormulation)
        silent = instantiate_model(data, OptimalPowerFlowProblem, IVRFormulation;
                                   set_string_name = false)

        @test !unnamed(named) && unnamed(silent)
        @test JuMP.num_variables(silent.model) == JuMP.num_variables(named.model)
        @test JuMP.num_constraints(silent.model; count_variable_in_set_constraints = true) ==
              JuMP.num_constraints(named.model; count_variable_in_set_constraints = true)

        for F in (IVRFormulation, LPFFormulation)
            on  = quiet(() -> solve_opf(data, F, OPTIMIZER))
            off = quiet(() -> solve_opf(data, F, OPTIMIZER; set_string_name = false))

            @test off["termination_status"] == on["termination_status"]
            @test off["objective"] ≈ on["objective"] atol = 1e-9
        end
    end

    @testset "a model handed in keeps its own choice" begin
        data = named_network()

        off = JuMP.Model()
        JuMP.set_string_names_on_creation(off, false)
        @test unnamed(instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation;
                                        jump_model = off))
        @test !JuMP.set_string_names_on_creation(off)

        on = JuMP.Model()
        instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation; jump_model = on,
                          set_string_name = false)
        @test !JuMP.set_string_names_on_creation(on)
    end

    @testset "a rolling horizon leaves them out in every window it builds" begin
        data = named_network(; dim = Dimension(:time => 3))

        for reuse in (false, true), (set_string_name, expected) in ((false, true), (true, false))
            flags = Bool[]
            quiet(() -> solve_rolling_horizon(data, RedispatchProblem, LPFFormulation, OPTIMIZER;
                                              horizon = 2, step = 1, reuse, set_string_name,
                                              solution_processors = [(nm, _) -> push!(flags, unnamed(nm))]))

            @test length(flags) == 3
            @test all(==(expected), flags)
        end
    end

    @testset "a name is not asked for by hand any more" begin
        nm = instantiate_model(named_network(), OptimalPowerFlowProblem, LPFFormulation; build = false)

        @test_throws MethodError variable!(nm, :probe, 1; nw = 1, base_name = "probe")
        @test_throws MethodError variables!(nm, :probe, 1:2; nw = 1, base_name = "probe")
    end
end
