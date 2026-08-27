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
            @test nd.vmin - 1e-6 <= sol["node"]["$i"]["vm"] <= nd.vmax + 1e-6
        end

        for u in ids(net, Generator)
            g = unit(net, u)
            @test g.pmin - 1e-6 <= sol["unit"]["$u"]["pg"] <= g.pmax + 1e-6
            @test g.qmin - 1e-6 <= sol["unit"]["$u"]["qg"] <= g.qmax + 1e-6
        end

        for e in ids(net, AbstractEdge)
            br = edge(net, e)
            isfinite(br.rate_a) || continue
            for a in edge_arcs(net, e)
                t = sol["edge"]["$e"]["terminal"]["$(a.terminal)"]
                @test hypot(t["p"], t["q"]) <= br.rate_a + 1e-6
            end
        end
    end

    @testset "the objective is the generation cost of the solution" begin
        data   = quiet(() -> parse_file(case("case5")))
        net    = network(data)
        result = quiet(() -> solve_opf(data, IVRFormulation, OPTIMIZER))
        sol    = nw_solution(result)

        cost = sum(generation_cost(unit(net, u), sol["unit"]["$u"]["pg"])
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
                          r = br.r, x = br.x, b_fr = br.b_fr, b_to = br.b_to,
                          rate_a = Inf, angmin = br.angmin, angmax = br.angmax,
                          status = br.status)
        end
        for e in ids(net, Transformer)
            tf = edge(net, e)::Transformer
            E[e] = Transformer(; id = tf.id, name = tf.name, terminals = tf.terminals,
                               r = tf.r, x = tf.x, b_fr = tf.b_fr, b_to = tf.b_to,
                               tm = tf.tm, ta = tf.ta, rate_a = Inf,
                               angmin = tf.angmin, angmax = tf.angmax, status = tf.status)
        end
        relaxed = NetworkData(Network(net.node, E, net.unit);
                              name = "case5 unlimited", baseMVA = baseMVA(data))

        limited = quiet(() -> solve_opf(data, IVRFormulation, OPTIMIZER))
        opened  = quiet(() -> solve_opf(relaxed, IVRFormulation, OPTIMIZER))

        @test opened["termination_status"] == JuMP.LOCALLY_SOLVED
        @test opened["objective"] <= limited["objective"] + 1e-6
        @test opened["objective"] < limited["objective"]   # branch 7 binds in case5
    end
end
