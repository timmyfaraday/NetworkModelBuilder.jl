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
# v0.12.5 - a topology lookup has one type and answers repeats                 #
# v0.12.6 - a solution holds the indices and components asked for              #
################################################################################

"a copy of load `ld` whose demand follows `profile` over dimension `:time`"
profiled(ld::FixedLoad, dim, profile) =
    FixedLoad(; id = ld.id, name = ld.name, node = ld.node,
         pd = nw_vector(dim, :time, ld.pd .* profile),
         qd = nw_vector(dim, :time, ld.qd .* profile),
         status = ld.status, ext = ld.ext)

"a copy of branch `br` that is out of service at the network indices in `out`"
outaged(br::Branch, dim, out) =
    Branch(; id = br.id, name = br.name, terminals = br.terminals, r = br.r, x = br.x,
           b_fr = br.b_fr, b_to = br.b_to, g_fr = br.g_fr, g_to = br.g_to,
           rate_a = br.rate_a, angmin = br.angmin, angmax = br.angmax,
           status = nw_vector(dim, (n, c) -> n ∉ out), ext = br.ext)

"apply a `:time` profile to every load"
scale_loads(profile) = (net, dim) -> for (u, cmp) in net.unit
    cmp isa FixedLoad || continue
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
        @test isempty(switchable(network(mn)))
        @test length(topologies(network(mn))) == 1
        for n in nw_ids(mn)
            @test ids(network(mn), Node; nw = n) == ids(network(data), Node)
        end
    end

    @testset "constant data stays a plain value" begin
        data = quiet(() -> parse_file(case("case5")))
        mn   = set_dimension(data, Dimension(:time => 3); apply! = scale_loads(PROFILE))
        net  = network(mn)

        ld = units(net)[6]::FixedLoad
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
        ld   = units(net)[6]::FixedLoad

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

        base = sum(unit(network(data), u).pd for u in ids(network(data), FixedLoad))
        for n in nw_ids(mn)
            total = sum(unit(network(mn), u; nw = n).pd for u in ids(network(mn), FixedLoad; nw = n))
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
        @test switchable(net) == [(:edge, 1)]
        @test topology(net; nw = 1) !== topology(net; nw = 2)
        @test length(topologies(net)) == 2
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

    @testset "a topology lookup has one type, whether or not a status varies" begin
        data = quiet(() -> parse_file(case("case5")))
        out  = network(set_dimension(data, Dimension(:contingency => 2); apply! = (net, d) ->
                   net.edge[1] = outaged(net.edge[1]::Branch, d, (2,))))
        same = network(set_dimension(data, Dimension(:time => 2)))

        @test @inferred(topology(out; nw = 1)) isa Topology
        @test @inferred(topology(same; nw = 1)) isa Topology
    end

    @testset "a repeated lookup is answered from the last one" begin
        data = quiet(() -> parse_file(case("case5")))
        net  = network(set_dimension(data, Dimension(:contingency => 3); apply! = (net, d) ->
                   net.edge[1] = outaged(net.edge[1]::Branch, d, (2,))))
        tops = [topology(net; nw = n) for n in 1:3]

        @test tops[1] === tops[3]
        @test tops[1] !== tops[2]

        # whatever the order of the questions, each index gets its own topology
        for n in (1, 1, 2, 3, 2, 2, 1, 3)
            @test topology(net; nw = n) === tops[n]
        end

        # and the index just asked is not derived again
        asked(net, n) = (topology(net; nw = n); @allocated topology(net; nw = n))
        @test asked(net, 2) == 0
    end

    @testset "a solution holds the network indices asked for" begin
        data = quiet(() -> parse_file(case("case5")))
        mn   = set_dimension(data, Dimension(:time => 3); apply! = scale_loads(PROFILE))
        nm   = instantiate_model(mn, OptimalPowerFlowProblem, IVRFormulation)
        full = quiet(() -> optimize_model!(nm, OPTIMIZER))
        part = build_solution(nm; nws = [2])

        @test collect(keys(part["solution"]["nw"])) == ["2"]
        @test isequal(part["solution"]["nw"]["2"], full["solution"]["nw"]["2"])
        @test part["objective"] == full["objective"]
        @test_throws ArgumentError build_solution(nm; nws = [4])

        # optimize_model! builds those and no others
        nm2   = instantiate_model(mn, OptimalPowerFlowProblem, IVRFormulation)
        asked = quiet(() -> optimize_model!(nm2, OPTIMIZER; solution_indices = [1, 3]))
        @test sort(collect(keys(asked["solution"]["nw"]))) == ["1", "3"]
        @test nw_solution(asked, 3)["node"]["1"]["vm"] ≈ nw_solution(full, 3)["node"]["1"]["vm"] atol = 1e-6
    end

    @testset "a report names what a solution holds" begin
        data = quiet(() -> parse_file(case("case5")))
        mn   = set_dimension(data, Dimension(:time => 3); apply! = scale_loads(PROFILE))
        nm   = instantiate_model(mn, OptimalPowerFlowProblem, IVRFormulation)
        full = quiet(() -> optimize_model!(nm, OPTIMIZER))
        held(result, n, family) = result["solution"]["nw"]["$n"][family]
        eds  = ids(network(mn), AbstractEdge)[[1, 3]]
        gen  = ids(network(mn), Generator)[1]

        # nothing said, or everything said, is the whole solution
        @test isequal(build_solution(nm)["solution"], full["solution"])
        @test isequal(build_solution(nm; report = (; node = true, edge = true, unit = true))["solution"],
                      full["solution"])

        # a family left out stays in the result, empty, and the others are as they were
        nodeless = build_solution(nm; report = (; node = false))
        for n in 1:3
            @test isempty(held(nodeless, n, "node"))
            @test isequal(held(nodeless, n, "edge"), held(full, n, "edge"))
            @test isequal(held(nodeless, n, "unit"), held(full, n, "unit"))
        end

        # identifiers keep those components and no others
        some = build_solution(nm; report = (; edge = eds, unit = [gen]))
        for n in 1:3
            @test sort(parse.(Int, collect(keys(held(some, n, "edge"))))) == sort(eds)
            @test collect(keys(held(some, n, "unit"))) == ["$gen"]
            @test isequal(held(some, n, "edge")["$(eds[2])"], held(full, n, "edge")["$(eds[2])"])
            @test isequal(held(some, n, "unit")["$gen"], held(full, n, "unit")["$gen"])
            @test isequal(held(some, n, "node"), held(full, n, "node"))
        end

        # a family that does not exist, an identifier that does not exist, and a
        # value that says neither yes nor no nor which are all refused
        @test_throws ArgumentError build_solution(nm; report = (; bus = true))
        @test_throws ArgumentError build_solution(nm; report = (; edge = [999]))
        @test_throws ArgumentError build_solution(nm; report = (; node = 1))

        # the solve asks for it the same way
        nm2   = instantiate_model(mn, OptimalPowerFlowProblem, IVRFormulation)
        asked = quiet(() -> optimize_model!(nm2, OPTIMIZER; report = (; node = false)))
        @test isempty(held(asked, 1, "node")) && !isempty(held(asked, 1, "edge"))

        solved = quiet(() -> solve_model(mn, OptimalPowerFlowProblem, IVRFormulation, OPTIMIZER;
                                         report = (; edge = false, unit = false)))
        @test isempty(held(solved, 2, "edge")) && isempty(held(solved, 2, "unit"))
        @test !isempty(held(solved, 2, "node"))

        # and the tables hold what the result holds
        tables = solution_tables(mn, some)
        @test sort(unique(tables.edge.id)) == sort(eds)
        @test unique(tables.unit.id) == [gen]
        @test length(tables.node.id) == length(solution_tables(mn, full).node.id)
        @test isempty(solution_tables(mn, nodeless).node)
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

        # nothing changed which components are in service, so there is one topology,
        # derived from the statuses rather than tabulated per network index
        @test length(unique(objectid(topology(net; nw = n)) for n in nw_ids(mn))) == 1
        @test isempty(switchable(net))
        @test length(topologies(net)) == 1

        # the dimension holds nothing per network index either
        @test Base.summarysize(dimension(mn)) < 5_000

        # the whole graph is the profile data plus a constant: take the profiles
        # away and what is left is what a single network index costs
        single   = set_dimension(data, Dimension(:time => 1); apply! = scale_loads([1.0]))
        profiles = 2 * sum(length(units(net)[u].pd) * sizeof(Float64) for u in ids(net, FixedLoad))
        @test Base.summarysize(net) - profiles <
              Base.summarysize(network(single)) + 4_000

        # and the data that does vary is there, indexed by the network index
        ld = units(net)[6]::FixedLoad
        @test length(ld.pd) == 1000
        @test unit(net, 6; nw = 500).pd ≈ nw_value(mn, ld.pd, 500)
    end

    @testset "replicate is deprecated but still folds correctly" begin
        data = quiet(() -> parse_file(case("case5")))

        old_apply! = function (net, n, c)
            for (u, cmp) in net.unit
                cmp isa FixedLoad || continue
                net.unit[u] = FixedLoad(; id = cmp.id, name = cmp.name, node = cmp.node,
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
        for n in nw_ids(mn), u in ids(network(mn), FixedLoad; nw = n)
            @test unit(network(mn), u; nw = n).pd ≈ unit(network(direct), u; nw = n).pd
        end
    end
end
