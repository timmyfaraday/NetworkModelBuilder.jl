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

@testset "network" begin

    @testset "arcs" begin
        data = quiet(() -> parse_file(case("case14")))
        net  = network(data)

        # every in-service two-terminal edge contributes two arcs
        @test length(arcs(net)) == 2 * length(ids(net, AbstractEdge))
        @test length(ids(net, Branch)) == 17          # case14 has 17 plain branches
        @test length(ids(net, Transformer)) == 3      # and three with a turns ratio
        @test issorted(arcs(net))

        # edge 8 runs from node 4 to node 7
        @test edge_arcs(net, 8) == [Arc(8, 1, 4), Arc(8, 2, 7)]
        @test edge_id(Arc(8, 1, 4)) == 8
        @test terminal_id(Arc(8, 1, 4)) == 1
        @test node_id(Arc(8, 1, 4)) == 4

        # node 9 sits on branches 9, 15, 16 and 17 and carries a load and a shunt
        @test node_arcs(net, 9) == [Arc(9, 2, 9), Arc(15, 2, 9), Arc(16, 1, 9), Arc(17, 1, 9)]
        @test node_units(net, 9) == [11, 17]

        # every arc appears exactly once in the incidence of its node
        @test sum(length(node_arcs(net, i)) for i in ids(net, Node)) == length(arcs(net))
        @test arcs(net, AbstractEdge) == arcs(net)
    end

    @testset "out of service components" begin
        data = quiet(() -> parse_file(case("case14")))
        net  = network(data)

        tf = edge(net, 8)::Transformer      # branch 8 of case14 has a turns ratio
        E  = Dict{Int,AbstractEdge}(net.edge)
        E[8] = Transformer(; id = tf.id, name = tf.name, terminals = tf.terminals,
                           r = tf.r, x = tf.x, b_fr = tf.b_fr, b_to = tf.b_to,
                           tm = tf.tm, ta = tf.ta, status = false)
        out = Network(net.node, E, net.unit)

        @test !is_active(edge(out, 8))
        @test 8 ∉ ids(out, AbstractEdge)
        @test length(arcs(out)) == length(arcs(net)) - 2
        @test Arc(8, 1, 4) ∉ node_arcs(out, 4)
        @test haskey(edges(out), 8)          # kept in the data, absent from the topology
        @test !haskey(topology(out).edge_arc, 8)
    end

    @testset "construction errors" begin
        I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF), 2 => Node(; id = 2))
        U = Dict{Int,AbstractUnit}()

        E = Dict{Int,AbstractEdge}(1 => Branch(; id = 1, terminals = [1, 9], r = 0.1, x = 1.0))
        @test_throws ArgumentError Network(I, E, U)

        E = Dict{Int,AbstractEdge}()
        U = Dict{Int,AbstractUnit}(1 => FixedLoad(; id = 1, node = 9, pd = 0.1))
        @test_throws ArgumentError Network(I, E, U)

        @test_throws ArgumentError Branch(; id = 1, terminals = [1, 2, 3], r = 0.1, x = 1.0)
        @test_throws ArgumentError Transformer(; id = 1, terminals = [1, 2], r = 0.1, x = 1.0, tm = 0.0)
    end

    @testset "component interface" begin
        br = Branch(; id = 3, terminals = [7, 9], r = 0.1, x = 1.0)

        @test component_id(br) == 3
        @test is_active(br)
        @test terminals(br) == [7, 9]
        @test nterminals(br) == 2
        @test impedance(br) == (0.1, 1.0)
        @test shunt_admittance(br) == ((0.0, 0.0), (0.0, 0.0))

        g = Generator(; id = 4, node = 7, pg = 1.0)
        @test node(g) == 7
        @test component_id(g) == 4
    end
end
