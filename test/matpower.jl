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

@testset "matpower" begin

    @testset "case14" begin
        data = quiet(() -> parse_file(case("case14")))
        net  = network(data)

        @test data.name == "case14"
        @test baseMVA(data) == 100.0
        @test dim_length(data) == 1

        @test length(ids(net, Node))      == 14
        @test length(ids(net, Branch))    == 20
        @test length(ids(net, Generator)) == 5
        @test length(ids(net, Load))      == 11   # buses with a non-zero Pd or Qd
        @test length(ids(net, Shunt))     == 1    # bus 9 carries Bs = 19 MVAr
        @test length(ids(net, AbstractUnit)) == 17

        # unit identifiers run in one sequence over generators, loads and shunts
        @test ids(net, Generator) == 1:5
        @test ids(net, Shunt)     == [17]

        @test node(net, 1).type == REF
        @test node(net, 2).type == PV
        @test node(net, 4).type == PQ
        @test node(net, 1).vm   == 1.06

        # everything is per unit on baseMVA, every angle in radians
        @test unit(net, 1).pmax ≈ 3.324
        @test unit(net, 1).pg   ≈ 2.324
        @test unit(net, 17).bs  ≈ 0.19
        @test edge(net, 8).tm   ≈ 0.978
        @test edge(net, 8).ta   ≈ 0.0
        @test edge(net, 1).b_fr ≈ 0.0528 / 2
        @test edge(net, 1).rate_a == Inf          # a zero rating means unlimited
        @test edge(net, 1).angmax ≈ deg2rad(360)

        # the cost polynomial is stored ascending and rescaled to per unit
        @test unit(net, 1).cost ≈ [0.0, 20 * 100, 0.0430292599 * 100^2, 0.0, 0.0]
        @test generation_cost(unit(net, 1), 1.0) ≈ 0.0 + 2000.0 + 430.292599
    end

    @testset "bus type correction" begin
        # bus 8 of case14 is declared PQ but carries an in-service generator
        @test_logs (:warn, r"bus 8 is declared PQ") match_mode = :any parse_file(case("case14"))
        data = quiet(() -> parse_file(case("case14")))
        @test node(network(data), 8).type == PV

        # bus 3 of case5 carries the invalid bus type 0
        @test_logs (:warn, r"bus 3 has the unknown bus type 0") match_mode = :any parse_file(case("case5"))

        # case3 declares no reference bus at all
        @test_logs (:warn, r"declares no reference bus") match_mode = :any parse_file(case("case3"))
        data = quiet(() -> parse_file(case("case3")))
        @test node(network(data), 1).type == REF
    end

    @testset "non-contiguous identifiers" begin
        data = quiet(() -> parse_file(case("case5")))
        net  = network(data)

        @test ids(net, Node) == [1, 2, 3, 4, 10]
        @test node(net, 10).type == PV
        @test edge(net, 5).tm ≈ 1.05
        @test edge(net, 5).ta ≈ deg2rad(1.0)
        @test edge(net, 6).ta ≈ deg2rad(-1.0)
    end

    @testset "errors" begin
        @test_throws ArgumentError parse_file("nowhere.json")
        @test_throws ArgumentError parse_matpower(joinpath(@__DIR__, "data", "nothing.m"))
    end
end
