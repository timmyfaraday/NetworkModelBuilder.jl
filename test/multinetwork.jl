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

"a copy of load `ld` whose demand follows `profile` over dimension `:time`"
profiled(ld::Load, dim, profile) =
    Load(; id = ld.id, name = ld.name, node = ld.node,
         pd = nw_vector(dim, :time, ld.pd .* profile),
         qd = nw_vector(dim, :time, ld.qd .* profile),
         status = ld.status, ext = ld.ext)

"a copy of branch `br` that is out of service at the network indices in `out`"
outaged(br::Branch, dim, out) =
    Branch(; id = br.id, name = br.name, terminals = br.terminals, r = br.r, x = br.x,
           b_fr = br.b_fr, b_to = br.b_to, g_fr = br.g_fr, g_to = br.g_to,
           tm = br.tm, ta = br.ta, rate_a = br.rate_a,
           angmin = br.angmin, angmax = br.angmax,
           status = nw_vector(dim, (n, c) -> n ∉ out), ext = br.ext)

"apply a `:time` profile to every load"
scale_loads(profile) = (net, dim) -> for (u, cmp) in net.unit
    cmp isa Load || continue
    net.unit[u] = profiled(cmp, dim, profile)
end

const PROFILE = [0.9, 1.0, 1.1]

@testset "multinetwork" begin

    @testset "set_dimension keeps one extended graph" begin
        data = quiet(() -> parse_file(case("case5")))
        mn   = set_dimension(data, Dimension(:time => 3))

        @test dim_length(mn) == 3
        @test nw_ids(mn) == [1, 2, 3]
        @test dim_names(mn) == (:time,)
        @test baseMVA(mn) == baseMVA(data)

        # one graph, not one per network index
        @test network(mn) isa Network
        @test length(nodes(network(mn))) == length(nodes(network(data)))
        @test length(units(network(mn))) == length(units(network(data)))

        # nothing varies, so every network index shares a single topology object
        @test topology(network(mn); nw = 1) === topology(network(mn); nw = 3)
        for n in nw_ids(mn)
            @test ids(network(mn), Node; nw = n) == ids(network(data), Node)
        end
    end

    @testset "constant data stays a plain value" begin
        data = quiet(() -> parse_file(case("case5")))
        mn   = set_dimension(data, Dimension(:time => 3); apply! = scale_loads(PROFILE))
        net  = network(mn)

        ld = units(net)[6]::Load
        @test is_nw_varying(ld.pd)               # the demand was made to vary
        @test !is_nw_varying(ld.node)            # the node it hangs off did not
        @test !is_nw_varying(ld.status)
        @test has_nw_data(ld)

        br = edges(net)[1]::Branch
        @test !has_nw_data(br)                   # no branch datum was touched
        @test br.r isa Float64

        gen = units(net)[1]::Generator
        @test !has_nw_data(gen)
        @test gen.cost isa Vector{Float64}       # a polynomial, not a profile
    end

    @testset "nw_value resolves both cases" begin
        data = quiet(() -> parse_file(case("case5")))
        mn   = set_dimension(data, Dimension(:time => 3); apply! = scale_loads(PROFILE))
        net  = network(mn)
        ld   = units(net)[6]::Load

        for n in nw_ids(mn)
            @test nw_value(mn, ld.pd, n) ≈ ld.pd.data[n]
            @test nw_value(mn, ld.node, n) == ld.node          # a constant passes through
            @test unit(net, 6; nw = n).pd ≈ ld.pd.data[n]      # resolved component
            @test unit(net, 6; nw = n).node == ld.node
        end
        @test nw_values(mn, ld.pd) == ld.pd.data
        @test nw_values(mn, ld.node) == fill(ld.node, 3)
        @test_throws ArgumentError nw_value(mn, ld.pd, 9)
    end

    @testset "nw_vector in its three forms" begin
        dim = Dimension(:time => 3, :contingency => 2)

        @test length(nw_vector(dim, collect(1:6))) == 6
        @test nw_vector(dim, (n, c) -> c.time).data == [1, 2, 3, 1, 2, 3]
        @test nw_vector(dim, :time, [10, 20, 30]).data == [10, 20, 30, 10, 20, 30]
        @test nw_vector(dim, :contingency, [7, 8]).data == [7, 7, 7, 8, 8, 8]

        @test_throws ArgumentError nw_vector(dim, [1, 2, 3])
        @test_throws ArgumentError nw_vector(dim, :time, [1, 2])
        @test_throws ArgumentError nw_vector(dim, :harmonic, [1, 2, 3])
    end

    @testset "a profile reaches the loads" begin
        data = quiet(() -> parse_file(case("case5")))
        mn   = set_dimension(data, Dimension(:time => 3); apply! = scale_loads(PROFILE))

        base = sum(unit(network(data), u).pd for u in ids(network(data), Load))
        for n in nw_ids(mn)
            total = sum(unit(network(mn), u; nw = n).pd for u in ids(network(mn), Load; nw = n))
            @test total ≈ base * PROFILE[n]
        end
    end

    @testset "an optimal power flow over three time steps" begin
        data = quiet(() -> parse_file(case("case5")))
        mn   = set_dimension(data, Dimension(:time => 3); apply! = scale_loads(PROFILE))

        result = quiet(() -> solve_model(mn, OptimalPowerFlowProblem, IVRFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test length(result["solution"]["nw"]) == 3

        # without coupling constraints the total is the sum of the three separate problems
        separate = sum(PROFILE) do s
            single = set_dimension(data, Dimension(:time => 1); apply! = scale_loads([s]))
            quiet(() -> solve_model(single, OptimalPowerFlowProblem,
                                    IVRFormulation, OPTIMIZER))["objective"]
        end
        @test result["objective"] ≈ separate rtol = 1e-6

        # a heavier load is served at a higher cost and a lower voltage
        costs = [sum(generation_cost(unit(network(mn), u; nw = n),
                                     nw_solution(result, n)["unit"]["$u"]["pg"])
                     for u in ids(network(mn), Generator; nw = n)) for n in 1:3]
        @test issorted(costs)
        @test nw_solution(result, 1)["node"]["2"]["vm"] > nw_solution(result, 3)["node"]["2"]["vm"]
    end

    @testset "network_weight scales the objective" begin
        data = quiet(() -> parse_file(case("case5")))
        dim  = Dimension(:time => [Dict{Symbol,Any}(:weight => w) for w in (1.0, 2.0)])
        mn   = set_dimension(data, dim)
        nm   = instantiate_model(mn, OptimalPowerFlowProblem, IVRFormulation)

        @test network_weight(nm, 1) == 1.0
        @test network_weight(nm, 2) == 2.0

        result = quiet(() -> optimize_model!(nm, OPTIMIZER))
        single = quiet(() -> solve_opf(data, IVRFormulation, OPTIMIZER))["objective"]
        @test result["objective"] ≈ 3 * single rtol = 1e-6
    end

    @testset "a network dependent status is a contingency" begin
        data = quiet(() -> parse_file(case("case5")))
        dim  = Dimension(:contingency => 2)
        mn   = set_dimension(data, dim; apply! = (net, d) ->
                   net.edge[1] = outaged(net.edge[1]::Branch, d, (2,)))
        net  = network(mn)

        @test is_nw_varying(edges(net)[1].status)
        @test is_active(dim, edges(net)[1], 1)
        @test !is_active(dim, edges(net)[1], 2)
        @test_throws ArgumentError is_active(edges(net)[1])

        # the topology follows the status, and the two indices no longer share one
        @test topology(net; nw = 1) !== topology(net; nw = 2)
        @test 1 ∈ ids(net, Branch; nw = 1)
        @test 1 ∉ ids(net, Branch; nw = 2)
        @test length(arcs(net; nw = 2)) == length(arcs(net; nw = 1)) - 2
        @test Arc(1, 1, 1) ∈ node_arcs(net, 1; nw = 1)
        @test Arc(1, 1, 1) ∉ node_arcs(net, 1; nw = 2)

        # and the model built from it prices the outage
        result = quiet(() -> solve_model(mn, OptimalPowerFlowProblem, IVRFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test haskey(nw_solution(result, 1)["edge"], "1")
        @test !haskey(nw_solution(result, 2)["edge"], "1")
    end

    @testset "the dimension is visible from the model" begin
        data = quiet(() -> parse_file(case("case5")))
        mn   = set_dimension(data, Dimension(:time => 2, :contingency => 3))
        nm   = instantiate_model(mn, LoadFlowProblem, IVRFormulation; build = false)

        @test nw_ids(nm) == collect(1:6)
        @test nw_ids(nm; contingency = 2) == [3, 4]
        @test coordinates(nm, 4) == (time = 2, contingency = 2)
        @test next_id(nm, 3, :contingency) == 5
        @test dimension(nm) === dimension(mn)
    end

    @testset "the graph does not grow with the number of network indices" begin
        data    = quiet(() -> parse_file(case("case14")))
        stored  = length(nodes(network(data))) + length(edges(network(data))) +
                  length(units(network(data)))
        profile = [1 + 0.2sin(2pi * h / 24) for h in 1:1000]
        dim     = Dimension(:time => 1000)

        mn  = set_dimension(data, dim; apply! = scale_loads(profile))
        net = network(mn)

        # one copy of every component, whatever the number of network indices
        @test length(nodes(net)) + length(edges(net)) + length(units(net)) == stored
        @test dim_length(mn) == 1000

        # nothing changed which components are in service, so there is one topology
        @test length(unique(objectid(topology(net; nw = n)) for n in nw_ids(mn))) == 1

        # and the data that does vary is there, indexed by the network index
        ld = units(net)[6]::Load
        @test length(ld.pd) == 1000
        @test unit(net, 6; nw = 500).pd ≈ nw_value(mn, ld.pd, 500)
    end

    @testset "replicate is deprecated but still folds correctly" begin
        data = quiet(() -> parse_file(case("case5")))

        old_apply! = function (net, n, c)
            for (u, cmp) in net.unit
                cmp isa Load || continue
                net.unit[u] = Load(; id = cmp.id, name = cmp.name, node = cmp.node,
                                   pd = cmp.pd * PROFILE[n], qd = cmp.qd * PROFILE[n],
                                   status = cmp.status, ext = cmp.ext)
            end
        end

        mn = quiet(() -> replicate(data, Dimension(:time => 3); apply! = old_apply!))

        # the per-index copies were folded back into one graph
        @test network(mn) isa Network
        @test dim_length(mn) == 3
        @test is_nw_varying(units(network(mn))[6].pd)     # the demand differed
        @test !is_nw_varying(units(network(mn))[6].node)  # the node did not
        @test !has_nw_data(edges(network(mn))[1])         # no branch was touched

        # and it agrees with what set_dimension builds directly
        direct = set_dimension(data, Dimension(:time => 3); apply! = scale_loads(PROFILE))
        for n in nw_ids(mn), u in ids(network(mn), Load; nw = n)
            @test unit(network(mn), u; nw = n).pd ≈ unit(network(direct), u; nw = n).pd
        end
    end
end
