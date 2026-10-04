################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.11.0 - the islands test                                                   #
################################################################################

# Which nodes can exchange power, what a model does about an island that cannot
# be supplied, and how an island that can be supplied gets an angle to be
# measured against.

@testset "islands" begin

    br(id, i, j; kw...)   = Branch(; id, terminals = [i, j], r = 0.01, x = 0.1, kw...)
    sw(id, i, j; kw...)   = Switch(; id, terminals = [i, j], kw...)
    gen(id, i; kw...)     = Generator(; id, node = i, pmax = 5.0, kw...)
    load(id, i; pd = 1.0) = FixedLoad(; id, node = i, pd)

    "a network of `n` nodes whose reference node is `reference`, none when it is 0"
    function toy(; n = 4, edges, units = AbstractUnit[], reference = 1, dim = nothing)
        I = Dict{Int,AbstractNode}(i => Node(; id = i, type = i == reference ? REF : PQ)
                                   for i in 1:n)
        E = Dict{Int,AbstractEdge}(e.id => e for e in edges)
        U = Dict{Int,AbstractUnit}(u.id => u for u in units)

        return NetworkData(dim === nothing ? Network(I, E, U) : Network(I, E, U; dim))
    end

    "the same edge, out of service"
    function out_of_service(c::AbstractEdge)
        kw = Dict{Symbol,Any}(f => getfield(c, f) for f in fieldnames(typeof(c)))
        kw[:status] = false

        return typeof(c)(; kw...)
    end

    message(f) = try f(); nothing catch e e isa ArgumentError ? e.msg : rethrow() end

    @testset "an island is what a path of connecting edges reaches" begin
        data = toy(n = 5, edges = [br(1, 1, 2), br(2, 2, 3), br(3, 4, 5)])

        @test islands(data) == [[1, 2, 3], [4, 5]]
        @test islands(network(data)) == islands(data)
        @test islands(data; nw = 1) == islands(data)
        @test islands(data; without = [2]) == [[1, 2], [3], [4, 5]]
        @test islands(data; without = [1, 2, 3]) == [[i] for i in 1:5]
        @test islands(instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation;
                                        build = false)) == islands(data)

        # an edge out of service is not there to join anything
        data = toy(n = 5, edges = [br(1, 1, 2), br(2, 2, 3; status = false), br(3, 4, 5)])
        @test islands(data) == [[1, 2], [3], [4, 5]]

        # and neither is a node, nor an edge that was to reach it
        I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF), 2 => Node(; id = 2),
                                   3 => Node(; id = 3, status = false))
        E = Dict{Int,AbstractEdge}(1 => br(1, 1, 2))
        @test islands(NetworkData(Network(I, E, Dict{Int,AbstractUnit}()))) == [[1, 2]]
    end

    @testset "a switch connects unless it is locked open" begin
        dim  = dimension(toy(edges = [br(1, 1, 2)]))
        link(; kw...) = islands(toy(n = 3, edges = [br(1, 1, 2), sw(2, 2, 3; kw...)]))

        @test link() == [[1, 2, 3]]                              # locked, closed
        @test link(position = 0) == [[1, 2], [3]]                # locked, open
        @test link(lock = FREE, position = 0) == [[1, 2, 3]]     # free: the problem may close it
        @test link(lock = FREE, position = 1) == [[1, 2, 3]]
        @test link(status = false) == [[1, 2], [3]]              # out of service

        @test connects(dim, br(1, 1, 2), 1) && !can_open(dim, br(1, 1, 2), 1)
        @test connects(dim, sw(1, 1, 2), 1) && !can_open(dim, sw(1, 1, 2), 1)
        @test !connects(dim, sw(1, 1, 2; position = 0), 1)
        @test connects(dim, sw(1, 1, 2; lock = FREE, position = 0), 1)
        @test can_open(dim, sw(1, 1, 2; lock = FREE), 1)
    end

    @testset "which islands there are depends on the network index" begin
        dim  = Dimension(:time => 3)
        data = toy(n = 3, dim = dim, edges = [br(1, 1, 2),
                                              sw(2, 2, 3; position = nw_vector(dim, [1, 0, 1]))])

        @test islands(data; nw = 1) == [[1, 2, 3]]
        @test islands(data; nw = 2) == [[1, 2], [3]]
        @test islands(data; nw = 3) == [[1, 2, 3]]
    end

    @testset "an island with load and nothing to supply it is refused" begin
        data = toy(edges = [br(1, 1, 2), br(2, 3, 4)],
                   units = [gen(1, 1), load(2, 2), load(3, 4)])

        msg = message(() -> check_islands(data))
        @test msg !== nothing
        @test occursin("[3, 4]", msg) && occursin("network index 1", msg)
        @test occursin("no reference node and no source", msg)

        # the model refuses it before it builds, in every formulation and problem
        for (P, F) in ((LoadFlowProblem, IVRFormulation), (LoadFlowProblem, LPFFormulation),
                       (OptimalPowerFlowProblem, IVRFormulation),
                       (OptimalPowerFlowProblem, LPFFormulation))
            @test_throws ArgumentError instantiate_model(data, P, F)
        end
        @test_throws ArgumentError solve_opf(data, LPFFormulation, OPTIMIZER)

        # `islanding = :allow` is about switches, not about this
        @test_throws ArgumentError check_islands(data; islanding = :allow)

        # unless nobody asked for it to be built
        @test instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation;
                                build = false) isa NetworkModel

        # a source is enough, a reference node is enough, and units are not needed
        @test check_islands(toy(edges = [br(1, 1, 2), br(2, 3, 4)],
                                units = [gen(1, 1), load(2, 2), gen(3, 3), load(4, 4)])) === nothing
        @test check_islands(toy(edges = [br(1, 1, 2), br(2, 3, 4)],
                                units = [gen(1, 1), load(2, 2)])) === nothing   # empty island
        @test check_islands(toy(edges = [br(1, 1, 2), br(2, 3, 4)], reference = 3,
                                units = [gen(1, 1), load(2, 2), load(3, 4)])) === nothing

        @test_throws ArgumentError check_islands(data; islanding = :sometimes)
    end

    @testset "it is a network that went wrong that gets refused: case14 with node 14 cut off" begin
        data = quiet(() -> parse_file(case("case14")))
        net  = network(data)
        cut  = [e for (e, c) in edges(net) if sort(terminals(c)) in ([9, 14], [13, 14])]
        E    = Dict{Int,AbstractEdge}(net.edge)
        for e in cut
            E[e] = out_of_service(E[e])
        end
        island = NetworkData(Network(net.node, E, net.unit); name = "case14, node 14 cut off",
                             baseMVA = baseMVA(data))

        @test length(cut) == 2
        @test islands(island) == [collect(1:13), [14]]

        for solve in (() -> solve_lf(island, IVRFormulation, OPTIMIZER),
                      () -> solve_lf(island, LPFFormulation, OPTIMIZER),
                      () -> solve_opf(island, IVRFormulation, OPTIMIZER),
                      () -> solve_opf(island, LPFFormulation, OPTIMIZER))
            msg = message(() -> quiet(solve))
            @test msg !== nothing && occursin("[14]", msg)
        end

        # the network it was cut from is still fine
        @test solve_lf(data, LPFFormulation, OPTIMIZER)["termination_status"] ==
              JuMP.LOCALLY_SOLVED
    end

    @testset "an island with a source and no reference node is anchored" begin
        data = toy(edges = [br(1, 1, 2), br(2, 3, 4)],
                   units = [gen(1, 1), load(2, 2), gen(3, 3), load(4, 4)])

        for F in (IVRFormulation, LPFFormulation)
            nm = instantiate_model(data, OptimalPowerFlowProblem, F)

            @test collect(keys(_NMB.con(nm)[:node_voltage_reference])) == [1]
            @test collect(keys(_NMB.con(nm)[:node_voltage_anchor])) == [3]       # the lowest node

            result = quiet(() -> solve_opf(data, F, OPTIMIZER))
            sol    = nw_solution(result)["node"]
            @test result["termination_status"] == JuMP.LOCALLY_SOLVED
            @test sol["1"]["va"] ≈ 0 atol = 1e-6
            @test sol["3"]["va"] ≈ 0 atol = 1e-6
            @test sol["4"]["va"] < sol["3"]["va"]                           # the load pulls it
        end

        # a network that has its reference node needs none
        whole = toy(edges = [br(1, 1, 2), br(2, 2, 3), br(3, 3, 4)],
                    units = [gen(1, 1), load(2, 2), load(3, 4)])
        nm    = instantiate_model(whole, OptimalPowerFlowProblem, LPFFormulation)
        @test isempty(_NMB.con(nm)[:node_voltage_anchor])

        # and a load flow anchors the same way
        lf = toy(edges = [br(1, 1, 2), br(2, 3, 4)],
                 units = [gen(1, 1), load(2, 2), gen(3, 3; pg = 1.0), load(4, 4)])
        pf = quiet(() -> solve_lf(lf, LPFFormulation, OPTIMIZER))
        @test pf["termination_status"] == JuMP.LOCALLY_SOLVED
        @test nw_solution(pf)["node"]["3"]["va"] ≈ 0 atol = 1e-6
    end

    @testset "a model that may open a switch may not leave a section on its own" begin
        # 1 -- 2 == 3, a branch and then a free switch, with the load behind the switch
        data = toy(n = 3, edges = [br(1, 1, 2), sw(2, 2, 3; lock = FREE, rate_a = 5.0)],
                   units = [gen(1, 1), load(2, 3)])

        msg = message(() -> check_islands(data))
        @test msg !== nothing
        @test occursin("free edges [2]", msg) && occursin("[1, 2, 3]", msg)
        @test occursin("[1, 2], [3]", msg)
        @test occursin("islanding = :allow", msg)
        @test message(() -> instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation)) == msg

        @test check_islands(data; islanding = :allow) === nothing

        # a second path round it, and it may open
        around = toy(n = 3, units = [gen(1, 1), load(2, 3)],
                     edges = [br(1, 1, 2), sw(2, 2, 3; lock = FREE, rate_a = 5.0), br(3, 1, 3)])
        @test check_islands(around) === nothing

        # a locked switch is data, not a decision
        locked = toy(n = 3, units = [gen(1, 1), load(2, 3)],
                     edges = [br(1, 1, 2), sw(2, 2, 3)])
        @test check_islands(locked) === nothing

        # a free switch that is out of service is not there to open
        gone = toy(n = 3, units = [gen(1, 1), load(2, 3)],
                   edges = [br(1, 1, 2), sw(2, 2, 3; lock = FREE, rate_a = 5.0, status = false)])
        @test occursin("no reference node and no source", message(() -> check_islands(gone)))
    end

    @testset "every network index is checked, once for each shape" begin
        dim  = Dimension(:time => 3)
        data = toy(n = 3, dim = dim, units = [gen(1, 1), load(2, 3)],
                   edges = [br(1, 1, 2), sw(2, 2, 3; position = nw_vector(dim, [1, 1, 0]))])

        msg = message(() -> check_islands(data))
        @test msg !== nothing && occursin("network index 3", msg)

        fine = toy(n = 3, dim = dim, units = [gen(1, 1), load(2, 3)],
                   edges = [br(1, 1, 2), sw(2, 2, 3; position = nw_vector(dim, [1, 1, 1]))])
        @test check_islands(fine) === nothing
    end

    @testset "a power flow holds a free switch where the data has it" begin
        data = toy(n = 3, edges = [br(1, 1, 2), sw(2, 2, 3; lock = FREE, position = 0, rate_a = 5.0)],
                   units = [gen(1, 1), gen(2, 3; pg = 1.0), load(3, 3)])

        @test islands(data) == [[1, 2, 3]]                        # a dispatch problem may close it
        @test islands(data; decide = false) == [[1, 2], [3]]      # a power flow may not
        @test check_islands(data; decide = false) === nothing

        # so the load flow has an island with a source and no reference node, and anchors it
        nm = instantiate_model(data, LoadFlowProblem, LPFFormulation)
        @test collect(keys(_NMB.con(nm)[:node_voltage_anchor])) == [3]
        r = quiet(() -> solve_lf(data, LPFFormulation, OPTIMIZER))
        @test r["termination_status"] == JuMP.LOCALLY_SOLVED
        @test nw_solution(r)["node"]["3"]["va"] ≈ 0 atol = 1e-6

        # while a dispatch problem is refused, since opening the switch would leave it there
        @test_throws ArgumentError instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation)
    end

end
