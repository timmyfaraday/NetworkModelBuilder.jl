################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.11.0 - the switch test                                                    #
################################################################################

# What a switch is, before any model is built from one: the data it takes and
# refuses, how it sits in a network, and how a table says it.

@testset "switch" begin

    @testset "a switch is closed, locked and between two nodes unless told otherwise" begin
        sw = Switch(; id = 1, terminals = [2, 7])

        @test sw isa AbstractSwitch
        @test sw isa AbstractEdge
        @test sw.lock === LOCKED
        @test sw.position == 1
        @test isinf(sw.rate_a)
        @test sw.angmin == -Float64(pi) && sw.angmax == Float64(pi)
        @test is_active(sw)
        @test Switch in edge_types()

        free = Switch(; id = 2, terminals = [3, 4], lock = FREE, position = 0, rate_a = 2.0)
        @test free.lock === FREE && free.position == 0 && free.rate_a == 2.0
    end

    @testset "it says what it refuses" begin
        two = [1, 2]

        @test_throws ArgumentError Switch(; id = 1, terminals = [1])
        @test_throws ArgumentError Switch(; id = 1, terminals = [1, 2, 3])
        @test_throws ArgumentError Switch(; id = 1, terminals = two, position = 2)
        @test_throws ArgumentError Switch(; id = 1, terminals = two, position = -1)
        @test_throws ArgumentError Switch(; id = 1, terminals = two, rate_a = -1.0)
        @test_throws ArgumentError Switch(; id = 1, terminals = two, angmin = 0.1)
        @test_throws ArgumentError Switch(; id = 1, terminals = two, angmax = -0.1)

        err = try Switch(; id = 7, terminals = [1, 2, 3]) catch e e end
        @test occursin("switch 7", err.msg) && occursin("exactly two", err.msg)

        # at every network index, not only the first
        dim = Dimension(:time => 3)
        @test_throws ArgumentError Switch(; id = 1, terminals = two,
                                          position = nw_vector(dim, [1, 0, 2]))
        @test Switch(; id = 1, terminals = two,
                     position = nw_vector(dim, [1, 0, 1])).position isa NetworkVector
    end

    @testset "it is an edge like any other, so an outage takes it out" begin
        dim = Dimension(:time => 3)
        I   = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.0), 2 => Node(; id = 2))
        E   = Dict{Int,AbstractEdge}(
            1 => Switch(; id = 1, terminals = [1, 2], status = nw_vector(dim, [true, false, true])))
        net = Network(I, E, Dict{Int,AbstractUnit}(); dim)

        @test ids(net, Switch; nw = 1) == [1]
        @test ids(net, AbstractSwitch; nw = 1) == [1]
        @test isempty(ids(net, Branch; nw = 1))
        @test isempty(ids(net, Switch; nw = 2))             # out of service, no arcs
        @test edge_arcs(net, 1; nw = 1) == [_NMB.Arc(1, 1, 1), _NMB.Arc(1, 2, 2)]
        @test only(switchable(net)) == (:edge, 1)           # a status that varies, as for a branch
    end

    @testset "a position that changes is a change of shape, a rating that stops binding too" begin
        dim = Dimension(:time => 4)
        I   = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.0), 2 => Node(; id = 2))
        E   = Dict{Int,AbstractEdge}(
            1 => Switch(; id = 1, terminals = [1, 2], position = nw_vector(dim, [1, 0, 1, 1]),
                        rate_a = nw_vector(dim, [1.0, 1.0, 1.0, Inf])))
        data = NetworkData(Network(I, E, Dict{Int,AbstractUnit}(); dim))

        @test structure_gates(edges(network(data))[1]) == (:rate_a, :position)
        @test isempty(switchable(network(data)))            # nothing went out of service
        @test same_structure(data, 1, 3)
        @test !same_structure(data, 1, 2)                   # open against closed
        @test !same_structure(data, 3, 4)                   # a rating against none
    end

    @testset "a table reads it, lock and all" begin
        base = (node = (id = [1, 2], type = ["REF", "PQ"]),
                unit = (id = [1, 2], component = ["Generator", "FixedLoad"], node = [1, 2],
                        pmax = [5.0, missing], pd = [missing, 1.0]))
        edge = (id = [1, 2], component = ["Switch", "Switch"], terminals = [[1, 2], [1, 2]],
                lock = ["FREE", missing], position = [0, missing], rate_a = [2.0, missing])

        data = parse_tables(; base..., edge)
        sw   = edges(network(data))

        @test sw[1] isa Switch
        @test sw[1].lock === FREE && sw[1].position == 0 && sw[1].rate_a == 2.0
        @test sw[2].lock === LOCKED && sw[2].position == 1          # blank is the default
        @test haskey(component_types(), "Switch")

        # and says what it takes where it cannot
        err = try
            parse_tables(; base..., edge = (id = [1], component = ["Switch"],
                                            terminals = [[1, 2]], lock = ["STUCK"]))
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("FREE", err.msg) && occursin("LOCKED", err.msg)
        @test_throws ArgumentError parse_tables(; base..., edge = (id = [1], component = ["Switch"],
                                                                    terminals = [[1, 2, 3]]))

        # a position that varies arrives as a profile
        dim  = Dimension(:time => 3)
        prof = (family = fill("edge", 3), id = fill(1, 3), field = fill("position", 3),
                nw = 1:3, value = [1, 0, 1])
        data = parse_tables(; base..., dim, profile = prof,
                            edge = (id = [1], component = ["Switch"], terminals = [[1, 2]]))
        @test edges(network(data))[1].position isa NetworkVector
        @test !same_structure(data, 1, 2)
    end

end
