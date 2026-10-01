################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.9.7 - a live PowerModels.jl solve is checked, not just a snapshot         #
################################################################################

# lf.jl, lpf.jl and opf.jl check against PowerModels.jl v0.21 values frozen at
# the commit they were written; nothing there would catch this package's own
# numerics drifting away from PowerModels.jl's actual, current behaviour. This
# file re-solves case14 with PowerModels.jl itself, live, alongside those —
# not instead of them, since a fast, dependency-free regression check and a
# live cross-check against another implementation answer different questions.

@testset "PowerModels.jl cross-check" begin
    PowerModels.silence()

    @testset "load flow (IVR) matches a live ACP power flow" begin
        nmb = quiet(() -> solve_lf(case("case14"), IVRFormulation, OPTIMIZER))
        pm  = PowerModels.solve_ac_pf(case("case14"), OPTIMIZER)
        sol = nw_solution(nmb)

        for (i, bus) in pm["solution"]["bus"]
            @test sol["node"][i]["vm"] ≈ bus["vm"] atol = 1e-6
            @test sol["node"][i]["va"] ≈ bus["va"] atol = 1e-5
        end
    end

    @testset "optimal power flow (IVR) matches a live IVR solve" begin
        nmb = quiet(() -> solve_opf(case("case14"), IVRFormulation, OPTIMIZER))
        pm  = PowerModels.solve_opf(case("case14"), PowerModels.IVRPowerModel, OPTIMIZER)

        @test nmb["objective"] ≈ pm["objective"] rtol = 1e-6
    end

    @testset "optimal power flow (LPF) matches a live DC solve" begin
        nmb = quiet(() -> solve_opf(case("case14"), LPFFormulation, OPTIMIZER))
        pm  = PowerModels.solve_dc_opf(case("case14"), OPTIMIZER)

        @test nmb["objective"] ≈ pm["objective"] rtol = 1e-6
    end
end
