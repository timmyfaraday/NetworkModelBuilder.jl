################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.9.7 - a live PowerModels.jl solve is checked, not just a snapshot         #
# v0.11.0 - the switch problems of PowerModels.jl                              #
# v0.12.0 - case5, whose transformers shift the phase                          #
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

    # case14 has ratios and no shift; case5 has both, on the windings of a
    # transformer that is a T here and a π there. PowerModels.jl's own current
    # based model has no row for a shifted branch, so the reference is its ACP.
    @testset "a transformer that shifts the phase matches a live ACP solve" begin
        nmb = quiet(() -> solve_opf(case("case5"), IVRFormulation, OPTIMIZER))
        pm  = PowerModels.solve_opf(case("case5"), PowerModels.ACPPowerModel, OPTIMIZER)

        @test nmb["objective"] ≈ pm["objective"] rtol = 1e-6

        nmb = quiet(() -> solve_lf(case("case5"), IVRFormulation, OPTIMIZER))
        pm  = PowerModels.solve_ac_pf(case("case5"), OPTIMIZER)

        for (i, bus) in pm["solution"]["bus"]
            @test nw_solution(nmb)["node"][i]["vm"] ≈ bus["vm"] atol = 1e-6
            @test nw_solution(nmb)["node"][i]["va"] ≈ bus["va"] atol = 1e-5
        end
    end

    # PowerModels.jl keeps its switch problems behind an underscore, so they are
    # looked for rather than assumed. The loop is `switch_loop.m` with three switches
    # across it that a Matpower file cannot hold; PowerModels.jl closes one by
    # `va_fr == va_to` and opens one by `psw == 0`, which is what a locked switch is
    # here, and it leaves a free one a binary `z_switch` with big-M rows.
    @testset "switches match the PowerModels.jl problems that have them" begin
        if !(isdefined(PowerModels, :_solve_opf_sw) && isdefined(PowerModels, :_solve_oswpf))
            @test_skip false              # PowerModels.jl no longer has them, see its prob/test.jl
        else
            ends    = ((1, 3), (1, 2), (2, 3))
            ratings = (0.6, 0.8, 5.0)
            exact   = JuMP.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false,
                                                     "mip_rel_gap" => 0.0)

            function pm_data(state)
                data = PowerModels.parse_file(case("switch_loop"))
                data["switch"] = Dict{String,Any}("$k" => Dict{String,Any}(
                    "index" => k, "f_bus" => ends[k][1], "t_bus" => ends[k][2], "status" => 1,
                    "state" => state[k], "thermal_rating" => ratings[k],
                    "source_id" => ["switch", k]) for k in 1:3)

                return data
            end

            function nmb_data(lock, state)
                data = quiet(() -> parse_file(case("switch_loop")))
                net  = network(data)
                E    = Dict{Int,AbstractEdge}(net.edge)
                for k in 1:3
                    E[2 + k] = Switch(; id = 2 + k, terminals = collect(ends[k]), lock,
                                      position = state[k], rate_a = ratings[k])
                end

                return NetworkData(Network(net.node, E, net.unit); baseMVA = baseMVA(data))
            end

            @testset "fixed switches, in power" begin
                for state in Iterators.product((0, 1), (0, 1), (0, 1))
                    pm  = PowerModels._solve_opf_sw(pm_data(state), PowerModels.DCPPowerModel, exact)
                    nmb = quiet(() -> solve_opf(nmb_data(LOCKED, state), LPFFormulation, exact))

                    if pm["termination_status"] != JuMP.OPTIMAL
                        @test nmb["termination_status"] == JuMP.INFEASIBLE
                    elseif all(==(1), state)
                        # three closed switches round a loop: PowerModels.jl leaves the
                        # flow round it free, and this package gives every switch of a
                        # loop the same impedance (D21), so it can only cost more
                        @test nmb["objective"] > pm["objective"] + 1.0
                    else
                        @test nmb["termination_status"] == JuMP.OPTIMAL
                        @test nmb["objective"] ≈ pm["objective"] rtol = 1e-6
                    end
                end
            end

            @testset "fixed switches, in current against voltage" begin
                for state in Iterators.product((0, 1), (0, 1), (0, 1))
                    (all(==(1), state) || state == (1, 1, 0)) && continue   # a loop, and no way to feed

                    pm  = PowerModels._solve_opf_sw(pm_data(state), PowerModels.ACPPowerModel, OPTIMIZER)
                    nmb = quiet(() -> solve_opf(nmb_data(LOCKED, state), IVRFormulation, OPTIMIZER))

                    @test pm["termination_status"] == JuMP.LOCALLY_SOLVED
                    @test nmb["termination_status"] == JuMP.LOCALLY_SOLVED
                    @test nmb["objective"] ≈ pm["objective"] rtol = 1e-6
                end
            end

            @testset "controllable switches choose the same setting at the same cost" begin
                pm  = PowerModels._solve_oswpf(pm_data((1, 1, 1)), PowerModels.DCPPowerModel, exact)
                nmb = quiet(() -> solve_opf(nmb_data(FREE, (1, 1, 1)), LPFFormulation, exact))

                @test pm["termination_status"] == JuMP.OPTIMAL
                @test nmb["termination_status"] == JuMP.OPTIMAL
                @test nmb["objective"] ≈ pm["objective"] rtol = 1e-6

                # the one across closed, the other two open
                @test [round(Int, pm["solution"]["switch"]["$k"]["status"]) for k in 1:3] == [1, 0, 0]
                @test [nw_solution(nmb)["edge"]["$(2 + k)"]["position"] for k in 1:3] == [1, 0, 0]
            end
        end
    end
end
