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

@testset "network" begin

    @testset "arcs" begin
        data = quiet(() -> parse_file(case("case14")))
        net  = network(data)

        # every in-service two-terminal edge contributes two arcs
        @test length(arcs(net)) == 2 * length(ids(net, Branch))
        @test issorted(arcs(net))

        # branch 8 runs from node 4 to node 7
        @test edge_arcs(net, 8) == [Arc(8, 1, 4), Arc(8, 2, 7)]
        @test edge_id(Arc(8, 1, 4)) == 8
        @test terminal_id(Arc(8, 1, 4)) == 1
        @test node_id(Arc(8, 1, 4)) == 4

        # node 9 sits on branches 9, 15, 16 and 17 and carries a load and a shunt
        @test node_arcs(net, 9) == [Arc(9, 2, 9), Arc(15, 2, 9), Arc(16, 1, 9), Arc(17, 1, 9)]
        @test node_units(net, 9) == [11, 17]

        # every arc appears exactly once in the incidence of its node
        @test sum(length(node_arcs(net, i)) for i in ids(net, Node)) == length(arcs(net))
        @test arcs(net, Branch) == arcs(net)
    end

    @testset "out of service components" begin
        data = quiet(() -> parse_file(case("case14")))
        net  = network(data)

        br = edge(net, 8)::Branch
        E  = Dict{Int,AbstractEdge}(net.edge)
        E[8] = Branch(; id = br.id, name = br.name, terminals = br.terminals, r = br.r,
                      x = br.x, b_fr = br.b_fr, b_to = br.b_to, tm = br.tm, ta = br.ta,
                      status = false)
        out = Network(net.node, E, net.unit)

        @test !is_active(edge(out, 8))
        @test 8 ∉ ids(out, Branch)
        @test length(arcs(out)) == length(arcs(net)) - 2
        @test Arc(8, 1, 4) ∉ node_arcs(out, 4)
        @test haskey(edges(out), 8)          # kept in the data, absent from the topology
        @test !haskey(out.edge_arc, 8)
    end

    @testset "construction errors" begin
        I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF), 2 => Node(; id = 2))
        U = Dict{Int,AbstractUnit}()

        E = Dict{Int,AbstractEdge}(1 => Branch(; id = 1, terminals = [1, 9], r = 0.1, x = 1.0))
        @test_throws ArgumentError Network(I, E, U)

        E = Dict{Int,AbstractEdge}()
        U = Dict{Int,AbstractUnit}(1 => Load(; id = 1, node = 9, pd = 0.1))
        @test_throws ArgumentError Network(I, E, U)

        @test_throws ArgumentError Branch(; id = 1, terminals = [1, 2, 3], r = 0.1, x = 1.0)
        @test_throws ArgumentError Branch(; id = 1, terminals = [1, 2], r = 0.1, x = 1.0, tm = 0.0)
    end

    @testset "component interface" begin
        br = Branch(; id = 3, terminals = [7, 9], r = 0.1, x = 1.0, tm = 1.02, ta = 0.1)

        @test component_id(br) == 3
        @test is_active(br)
        @test terminals(br) == [7, 9]
        @test nterminals(br) == 2
        @test all(tap(br) .≈ (1.02 * cos(0.1), 1.02 * sin(0.1)))

        g = Generator(; id = 4, node = 7, pg = 1.0)
        @test node(g) == 7
        @test component_id(g) == 4
    end
end
