################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
# v0.12.0 - a transformer has an entry per winding                             #
# v0.13.0 - a branch holds one entry per terminal of a field                   #
# v0.14.0 - variable and solution keys follow the nomenclature                 #
# v0.14.0 - the fields follow the nomenclature                                 #
################################################################################

# The reference objectives below are those of PowerModels.jl v0.21, computed in
# the ACP formulation for case5 and case3 and in both the ACP and the IVR
# formulation for case14.

@testset "optimal power flow" begin

    @testset "the objective matches the reference" begin
        for (name, objective) in ("case14" => 8081.524739,
                                  "case5"  => 18269.102723,
                                  "case3"  => 5812.642935)
            result = quiet(() -> solve_opf(case(name), IVRFormulation, OPTIMIZER))

            @test result["termination_status"] == JuMP.LOCALLY_SOLVED
            @test result["objective"] ≈ objective rtol = 1e-6
        end
    end

    @testset "case5 respects the operating limits" begin
        data   = quiet(() -> parse_file(case("case5")))
        net    = network(data)
        result = quiet(() -> solve_opf(data, IVRFormulation, OPTIMIZER))
        sol    = nw_solution(result)

        for i in ids(net, Node)
            nd = node(net, i)
            @test nd.v_magn_min - 1e-6 <= sol["node"]["$i"]["v_magn"] <= nd.v_magn_max + 1e-6
        end

        for u in ids(net, Generator)
            g = unit(net, u)
            @test g.p_min - 1e-6 <= sol["unit"]["$u"]["p_gen"] <= g.p_max + 1e-6
            @test g.q_min - 1e-6 <= sol["unit"]["$u"]["q_gen"] <= g.q_max + 1e-6
        end

        for e in ids(net, AbstractEdge)
            br = edge(net, e)
            for a in edge_arcs(net, e)
                rate = rating_at(br, a.terminal)
                isfinite(rate) || continue
                t = sol["edge"]["$e"]["terminal"]["$(a.terminal)"]
                @test hypot(t["p_term"], t["q_term"]) <= rate + 1e-6
            end
        end
    end

    @testset "the objective is the generation cost of the solution" begin
        data   = quiet(() -> parse_file(case("case5")))
        net    = network(data)
        result = quiet(() -> solve_opf(data, IVRFormulation, OPTIMIZER))
        sol    = nw_solution(result)

        cost = sum(generation_cost(unit(net, u), sol["unit"]["$u"]["p_gen"])
                   for u in ids(net, Generator))
        @test cost ≈ result["objective"] rtol = 1e-8
    end

    @testset "relaxing the edge limits cannot raise the optimum" begin
        # dropping the thermal ratings enlarges the feasible set, so the optimal
        # cost can only fall; this is what pins down the edge limit constraints
        data = quiet(() -> parse_file(case("case5")))
        net  = network(data)

        E = Dict{Int,AbstractEdge}(net.edge)
        for e in ids(net, Branch)
            br = edge(net, e)::Branch
            E[e] = Branch(; id = br.id, name = br.name, terminals = br.terminals,
                          r = br.r, x = br.x, b_shnt = br.b_shnt,
                          s_max  = Inf, v_angl_min = br.v_angl_min, v_angl_max = br.v_angl_max,
                          status = br.status)
        end
        for e in ids(net, Transformer)
            tf = edge(net, e)::Transformer
            E[e] = Transformer(; id = tf.id, name = tf.name, terminals = tf.terminals,
                               r = tf.r, x = tf.x, g_shnt = tf.g_shnt, b_shnt = tf.b_shnt,
                               t_magn = tf.t_magn, t_angl = tf.t_angl, s_max = Inf,
                               v_angl_min = tf.v_angl_min, v_angl_max = tf.v_angl_max, status = tf.status)
        end
        relaxed = NetworkData(Network(net.node, E, net.unit);
                              name = "case5 unlimited", s_base_mva = s_base_mva(data))

        limited = quiet(() -> solve_opf(data, IVRFormulation, OPTIMIZER))
        opened  = quiet(() -> solve_opf(relaxed, IVRFormulation, OPTIMIZER))

        @test opened["termination_status"] == JuMP.LOCALLY_SOLVED
        @test opened["objective"] <= limited["objective"] + 1e-6
        @test opened["objective"] < limited["objective"]   # branch 7 binds in case5
    end
end
