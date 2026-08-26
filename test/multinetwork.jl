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

"scale every load of `net` by the `:scale` property of its coordinate along `:time`"
function scale_loads!(dim)
    return function (net, n, coordinates)
        s = dim_prop(dim, n, :time, :scale)
        for (u, cmp) in net.unit
            cmp isa Load || continue
            net.unit[u] = Load(; id = cmp.id, name = cmp.name, node = cmp.node,
                               pd = cmp.pd * s, qd = cmp.qd * s,
                               status = cmp.status, ext = cmp.ext)
        end
    end
end

@testset "multinetwork" begin

    @testset "replicate" begin
        data = quiet(() -> parse_file(case("case5")))
        dim  = Dimension(:time => 3)
        mn   = replicate(data, dim)

        @test dim_length(mn) == 3
        @test nw_ids(mn) == [1, 2, 3]
        @test dim_names(mn) == (:time,)
        @test baseMVA(mn) == baseMVA(data)

        # every network index gets its own copy of the extended graph
        for n in nw_ids(mn)
            @test ids(network(mn, n), Node) == ids(network(data), Node)
            @test length(arcs(network(mn, n))) == length(arcs(network(data)))
        end
        @test network(mn, 1) !== network(mn, 2)

        @test_throws ArgumentError replicate(mn, Dimension(:time => 2))
    end

    @testset "apply! writes the index dependent data" begin
        data  = quiet(() -> parse_file(case("case5")))
        scale = [0.9, 1.0, 1.1]
        dim   = Dimension(:time => [Dict{Symbol,Any}(:scale => s) for s in scale])
        mn    = replicate(data, dim; apply! = scale_loads!(dim))

        base = sum(unit(network(data), u).pd for u in ids(network(data), Load))
        for n in nw_ids(mn)
            total = sum(unit(network(mn, n), u).pd for u in ids(network(mn, n), Load))
            @test total ≈ base * scale[n]
        end
    end

    @testset "an optimal power flow over three time steps" begin
        data  = quiet(() -> parse_file(case("case5")))
        scale = [0.9, 1.0, 1.1]
        dim   = Dimension(:time => [Dict{Symbol,Any}(:scale => s) for s in scale])
        mn    = replicate(data, dim; apply! = scale_loads!(dim))

        result = quiet(() -> solve_model(mn, OptimalPowerFlowProblem, IVRFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test length(result["solution"]["nw"]) == 3

        # without coupling constraints the total is the sum of the three separate problems
        separate = 0.0
        for s in scale
            single = replicate(data, Dimension(:time => [Dict{Symbol,Any}(:scale => s)]);
                               apply! = scale_loads!(Dimension(:time => [Dict{Symbol,Any}(:scale => s)])))
            separate += quiet(() -> solve_model(single, OptimalPowerFlowProblem,
                                                IVRFormulation, OPTIMIZER))["objective"]
        end
        @test result["objective"] ≈ separate rtol = 1e-6

        # a heavier load is served at a higher cost and a lower voltage
        costs = [sum(generation_cost(unit(network(mn, n), u),
                                     nw_solution(result, n)["unit"]["$u"]["pg"])
                     for u in ids(network(mn, n), Generator)) for n in 1:3]
        @test issorted(costs)
        @test nw_solution(result, 1)["node"]["2"]["vm"] > nw_solution(result, 3)["node"]["2"]["vm"]
    end

    @testset "network_weight scales the objective" begin
        data = quiet(() -> parse_file(case("case5")))
        dim  = Dimension(:time => [Dict{Symbol,Any}(:scale => 1.0, :weight => w) for w in (1.0, 2.0)])
        mn   = replicate(data, dim; apply! = scale_loads!(dim))
        nm   = instantiate_model(mn, OptimalPowerFlowProblem, IVRFormulation)

        @test network_weight(nm, 1) == 1.0
        @test network_weight(nm, 2) == 2.0

        result = quiet(() -> optimize_model!(nm, OPTIMIZER))
        single = quiet(() -> solve_opf(data, IVRFormulation, OPTIMIZER))["objective"]
        @test result["objective"] ≈ 3 * single rtol = 1e-6
    end

    @testset "the dimension is visible from the model" begin
        data = quiet(() -> parse_file(case("case5")))
        mn   = replicate(data, Dimension(:time => 2, :contingency => 3))
        nm   = instantiate_model(mn, LoadFlowProblem, IVRFormulation; build = false)

        @test nw_ids(nm) == collect(1:6)
        @test nw_ids(nm; contingency = 2) == [3, 4]
        @test coordinates(nm, 4) == (time = 2, contingency = 2)
        @test next_id(nm, 3, :contingency) == 5
    end
end
