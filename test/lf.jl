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

# The reference values below are the AC power flow solution of PowerModels.jl
# v0.21 in its ACP formulation. A load flow has one physical answer, so an IVR
# model that is written correctly has to reproduce it whatever the formulation
# the reference was computed in.

const CASE14_LF_VM = Dict(
     1 => 1.06,        2 => 1.045,       3 => 1.01,        4 => 1.01767085,
     5 => 1.01951386,  6 => 1.07,        7 => 1.06151953,  8 => 1.09,
     9 => 1.05593172, 10 => 1.05098462, 11 => 1.05690652, 12 => 1.05518856,
    13 => 1.05038171, 14 => 1.03552995)

const CASE14_LF_VA = Dict(   # degrees
     1 =>   0.0,       2 =>  -4.982589,  3 => -12.7251,    4 => -10.312901,
     5 =>  -8.773854,  6 => -14.220946,  7 => -13.359627,  8 => -13.359627,
     9 => -14.938521, 10 => -15.097288, 11 => -14.790622, 12 => -15.075585,
    13 => -15.156276, 14 => -16.033645)

const CASE14_LF_PG = Dict(1 => 2.32393272, 2 => 0.4, 3 => 0.0, 4 => 0.0, 5 => 0.0)
const CASE14_LF_QG = Dict(1 => -0.16549301, 2 => 0.435571, 3 => 0.25075348,
                          4 => 0.12730944, 5 => 0.17623451)

const CASE5_LF_VM = Dict(1 => 1.0, 2 => 0.98940185, 3 => 1.0, 4 => 1.0, 10 => 1.0)
const CASE5_LF_VA = Dict(1 => 3.585141, 2 => 0.031853, 3 => 0.482437,
                         4 => -0.0, 10 => 4.38111)

@testset "load flow" begin

    @testset "case14 reproduces the reference solution" begin
        result = quiet(() -> solve_lf(case("case14"), IVRFormulation, OPTIMIZER))
        sol    = nw_solution(result)

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test result["objective"] ≈ 0.0 atol = 1e-8

        for (i, vm) in CASE14_LF_VM
            @test sol["node"]["$i"]["vm"] ≈ vm atol = 1e-6
        end
        for (i, va) in CASE14_LF_VA
            @test rad2deg(sol["node"]["$i"]["va"]) ≈ va atol = 1e-5
        end
        for (u, pg) in CASE14_LF_PG
            @test sol["unit"]["$u"]["pg"] ≈ pg atol = 1e-6
            @test sol["unit"]["$u"]["qg"] ≈ CASE14_LF_QG[u] atol = 1e-6
        end
    end

    @testset "case14 setpoints are honoured" begin
        data   = quiet(() -> parse_file(case("case14")))
        net    = network(data)
        result = quiet(() -> solve_lf(data, IVRFormulation, OPTIMIZER))
        sol    = nw_solution(result)

        for i in ids(net, Node)
            nd = node(net, i)
            nd.type == PQ && continue
            # the reference and the PV nodes hold their voltage magnitude setpoint
            @test sol["node"]["$i"]["vm"] ≈ nd.vm atol = 1e-8
        end
        @test rad2deg(sol["node"]["1"]["va"]) ≈ 0.0 atol = 1e-8

        for u in ids(net, Generator)
            g = unit(net, u)
            node(net, g.node).type == REF && continue
            # every generator away from the reference holds its active setpoint
            @test sol["unit"]["$u"]["pg"] ≈ g.pg atol = 1e-8
        end

        for u in ids(net, Load)
            ld = unit(net, u)
            @test sol["unit"]["$u"]["p"] ≈ -ld.pd atol = 1e-8
            @test sol["unit"]["$u"]["q"] ≈ -ld.qd atol = 1e-8
        end
    end

    @testset "case14 the solution satisfies the node balance" begin
        data   = quiet(() -> parse_file(case("case14")))
        net    = network(data)
        result = quiet(() -> solve_lf(data, IVRFormulation, OPTIMIZER))
        sol    = nw_solution(result)

        for i in ids(net, Node)
            into_edges = sum(sol["edge"]["$(a.edge)"]["terminal"]["$(a.terminal)"]["p"]
                             for a in node_arcs(net, i); init = 0.0)
            from_units = sum(sol["unit"]["$u"]["p"] for u in node_units(net, i); init = 0.0)
            @test into_edges ≈ from_units atol = 1e-7

            into_edges = sum(sol["edge"]["$(a.edge)"]["terminal"]["$(a.terminal)"]["q"]
                             for a in node_arcs(net, i); init = 0.0)
            from_units = sum(sol["unit"]["$u"]["q"] for u in node_units(net, i); init = 0.0)
            @test into_edges ≈ from_units atol = 1e-7
        end
    end

    @testset "case5 has phase shifting transformers and non-contiguous nodes" begin
        result = quiet(() -> solve_lf(case("case5"), IVRFormulation, OPTIMIZER))
        sol    = nw_solution(result)

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        for (i, vm) in CASE5_LF_VM
            @test sol["node"]["$i"]["vm"] ≈ vm atol = 1e-6
        end
        for (i, va) in CASE5_LF_VA
            @test rad2deg(sol["node"]["$i"]["va"]) ≈ va atol = 1e-5
        end
    end

    @testset "the reporting helpers" begin
        result = quiet(() -> solve_lf(case("case5"), IVRFormulation, OPTIMIZER))

        @test result["problem_type"] === LoadFlowProblem
        @test result["formulation_type"] === IVRFormulation
        @test result["baseMVA"] == 100.0
        @test result["solve_time"] > 0.0
        @test_throws KeyError nw_solution(result, 2)

        io = IOBuffer()
        print_summary(io, result)
        text = String(take!(io))
        @test occursin("case5", text)
        @test occursin("LoadFlowProblem", text)
        @test occursin("Generator", text)
    end
end
