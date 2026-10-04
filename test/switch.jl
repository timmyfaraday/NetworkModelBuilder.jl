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

# What a switch held at its position does to a model: the same as the nodes it
# joins being one node, or as the edge not being there, and no more than that to a
# loop of them. In both formulations.

@testset "switch, held" begin

    br(id, i, j; kw...)   = Branch(; id, terminals = [i, j], r = 0.0, x = 0.1, kw...)
    sw(id, i, j; kw...)   = Switch(; id, terminals = [i, j], kw...)
    gen(id, i; kw...)     = Generator(; id, node = i, pmax = 5.0, kw...)
    load(id, i; pd = 1.0) = FixedLoad(; id, node = i, pd)

    "a network of `n` nodes, the first of which is the reference"
    function toy(edges, units; n = 3)
        I = Dict{Int,AbstractNode}(i => Node(; id = i, type = i == 1 ? REF : PQ) for i in 1:n)
        E = Dict{Int,AbstractEdge}(e.id => e for e in edges)
        U = Dict{Int,AbstractUnit}(u.id => u for u in units)

        return NetworkData(Network(I, E, U))
    end

    "the active power into the first terminal of edge `e`"
    flow(result, e) = nw_solution(result)["edge"]["$e"]["terminal"]["1"]["p"]

    "the same component with some of its fields replaced"
    function rebuilt(c; kw...)
        fields = Dict{Symbol,Any}(f => getfield(c, f) for f in fieldnames(typeof(c)))
        merge!(fields, Dict{Symbol,Any}(kw))

        return typeof(c)(; fields...)
    end

    highs(solver) = JuMP.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false,
                                                   "solver" => solver)
    solvers = (simplex = highs("simplex"), ipm = highs("ipm"), ipopt = OPTIMIZER)

    @testset "a closed switch is its two nodes as one, an open one is no edge" begin
        data = quiet(() -> parse_file(case("case14")))
        net  = network(data)
        e14  = only(e for (e, c) in edges(net) if sort(terminals(c)) == [13, 14])
        keep = filter(!=(e14), collect(keys(net.edge)))
        make(E, I = net.node, U = net.unit) =
            NetworkData(Network(I, Dict{Int,AbstractEdge}(E), U); baseMVA = baseMVA(data))

        closed  = make(merge(net.edge, Dict(e14 => sw(e14, 13, 14))))
        opened  = make(merge(net.edge, Dict(e14 => sw(e14, 13, 14; position = 0))))
        removed = make(Dict(e => net.edge[e] for e in keep))
        merged  = make(
            Dict(e => rebuilt(net.edge[e]; terminals = [t == 14 ? 13 : t for t in terminals(net.edge[e])])
                 for e in keep),
            Dict(i => nd for (i, nd) in net.node if i != 14),
            Dict(u => (c.node == 14 ? rebuilt(c; node = 13) : c) for (u, c) in net.unit))

        for F in (LPFFormulation, IVRFormulation),
            solve in (d -> solve_opf(d, F, OPTIMIZER), d -> solve_lf(d, F, OPTIMIZER))

            ref = quiet(() -> solve(merged))
            r   = quiet(() -> solve(closed))
            @test r["termination_status"] == JuMP.LOCALLY_SOLVED
            @test r["objective"] ≈ ref["objective"] rtol = 1e-6
            @test all(isapprox(flow(r, e), flow(ref, e); atol = 1e-5) for e in keep)

            ref = quiet(() -> solve(removed))
            r   = quiet(() -> solve(opened))
            @test r["objective"] ≈ ref["objective"] rtol = 1e-6
            @test all(isapprox(flow(r, e), flow(ref, e); atol = 1e-5) for e in keep)
            @test abs(flow(r, e14)) < 1e-7
        end
    end

    @testset "two switches in parallel share the flow, in every solver" begin
        data = toy([br(1, 1, 2), sw(2, 2, 3), sw(3, 2, 3)], [gen(1, 1), load(2, 3)])

        for (name, solver) in pairs(solvers)
            r = solve_opf(data, LPFFormulation, solver)
            @test r["termination_status"] in (JuMP.OPTIMAL, JuMP.LOCALLY_SOLVED)
            @test flow(r, 1) ≈ 1.0 atol = 1e-6
            @test flow(r, 2) ≈ 0.5 atol = 1e-6
            @test flow(r, 3) ≈ 0.5 atol = 1e-6
        end

        # and in the current-based formulation, where the loop row is on each current
        r = quiet(() -> solve_opf(data, IVRFormulation, OPTIMIZER))
        @test r["termination_status"] == JuMP.LOCALLY_SOLVED
        @test flow(r, 2) ≈ 0.5 atol = 1e-5
        @test flow(r, 3) ≈ 0.5 atol = 1e-5
        current(e, part) = nw_solution(r)["edge"]["$e"]["terminal"]["1"][part]
        @test current(2, "cr") ≈ current(3, "cr") atol = 1e-6
        @test current(2, "ci") ≈ current(3, "ci") atol = 1e-6

        # one angle equality for the pair, and a loop row for the other switch
        nm   = instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation)
        rows = Set((key, id) for (_, key, id) in keys(registered_constraints(nm))
                   if key in (:switch_angle, :switch_loop, :switch_open))
        @test rows == Set([(:switch_angle, 2), (:switch_loop, 3)])

        # the same in current, a real row and an imaginary one for each
        nm   = instantiate_model(data, OptimalPowerFlowProblem, IVRFormulation)
        rows = Set((key, id) for (_, key, id) in keys(registered_constraints(nm))
                   if key in (:switch_voltage, :switch_loop, :switch_open))
        @test rows == Set([(:switch_voltage, (2, :real)), (:switch_voltage, (2, :imag)),
                           (:switch_loop, (3, :real)), (:switch_loop, (3, :imag))])
    end

    @testset "three switches in a triangle split the flow by the length of the way" begin
        data = toy([sw(1, 1, 2), sw(2, 2, 3), sw(3, 1, 3)], [gen(1, 1), load(2, 3)])

        for (name, solver) in pairs(solvers)
            r = solve_opf(data, LPFFormulation, solver)
            @test flow(r, 3) ≈ 2 / 3 atol = 1e-6            # the way that is one switch long
            @test flow(r, 1) ≈ 1 / 3 atol = 1e-6            # the way that is two long
            @test flow(r, 2) ≈ 1 / 3 atol = 1e-6
        end

        # a switch that runs from its second terminal to its first is the same loop
        data = toy([sw(1, 1, 2), sw(2, 3, 2), sw(3, 1, 3)], [gen(1, 1), load(2, 3)])
        for F in (LPFFormulation, IVRFormulation)
            r = quiet(() -> solve_opf(data, F, OPTIMIZER))
            @test flow(r, 3) ≈ 2 / 3 atol = 1e-5
            @test flow(r, 1) ≈ 1 / 3 atol = 1e-5
            @test flow(r, 2) ≈ -1 / 3 atol = 1e-5
        end
    end

    @testset "an open switch writes no angle row, and a closed one no flow row" begin
        data = toy([br(1, 1, 2), sw(2, 2, 3; position = 0)], [gen(1, 1), load(2, 2)])

        for (F, equal) in ((LPFFormulation, :switch_angle), (IVRFormulation, :switch_voltage))
            nm    = instantiate_model(data, OptimalPowerFlowProblem, F)
            keys_ = Set(key for (_, key, _) in keys(registered_constraints(nm)))

            @test :switch_open in keys_ && :switch_flow in keys_
            @test equal ∉ keys_ && :switch_loop ∉ keys_
        end
    end

    @testset "the rating of a closed switch holds in a dispatch problem, not in a power flow" begin
        cheap, dear = [0.0, 1.0], [0.0, 100.0]
        units = [gen(1, 1; cost = cheap), gen(2, 2; cost = dear, pg = 1.0), load(3, 2; pd = 2.0)]
        net(rate; position = 1) = toy([sw(1, 1, 2; rate_a = rate, position)], units; n = 2)

        for F in (LPFFormulation, IVRFormulation)
            free  = quiet(() -> solve_opf(net(Inf), F, OPTIMIZER))
            tight = quiet(() -> solve_opf(net(0.5), F, OPTIMIZER))
            @test flow(free, 1) ≈ 2.0 atol = 1e-5
            @test flow(tight, 1) ≈ 0.5 atol = 1e-5              # the dear one makes up the rest
            @test nw_solution(tight)["unit"]["2"]["pg"] ≈ 1.5 atol = 1e-5

            # a power flow chooses nothing and has no rating, as for a branch
            pf = quiet(() -> solve_lf(net(0.5), F, OPTIMIZER))
            @test flow(pf, 1) ≈ 1.0 atol = 1e-5

            # open, there is nothing to limit
            r = quiet(() -> solve_opf(net(0.5; position = 0), F, OPTIMIZER))
            @test abs(flow(r, 1)) < 1e-7
            @test nw_solution(r)["unit"]["2"]["pg"] ≈ 2.0 atol = 1e-5
        end
    end

    @testset "a rolling horizon over a position that changes is every hour on its own" begin
        dim = Dimension(:time => 6)
        I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF), 2 => Node(; id = 2))
        E = Dict{Int,AbstractEdge}(
            1 => sw(1, 1, 2; position = nw_vector(dim, [1, 1, 1, 0, 0, 0])))
        U = Dict{Int,AbstractUnit}(1 => gen(1, 1; cost = [0.0, 10.0]),
                                   2 => gen(2, 2; cost = [0.0, 50.0]),
                                   3 => load(3, 2))
        data = NetworkData(Network(I, E, U; dim))

        @test same_structure(data, 1, 2) && same_structure(data, 5, 6)
        @test !same_structure(data, 3, 4)

        roll(F; reuse) = quiet(() -> solve_rolling_horizon(data, OptimalPowerFlowProblem,
                                                           F, OPTIMIZER;
                                                           horizon = 2, step = 1, reuse))

        for F in (LPFFormulation, IVRFormulation)
            whole  = quiet(() -> solve_opf(data, F, OPTIMIZER))
            built  = roll(F; reuse = false)
            reused = roll(F; reuse = true)

            for result in (built, reused)
                @test result["termination_status"] == JuMP.LOCALLY_SOLVED
                @test result["objective"] ≈ whole["objective"] rtol = 1e-6
                @test [nw_solution(result, n)["unit"]["2"]["pg"] for n in 1:6] ≈
                      [0.0, 0.0, 0.0, 1.0, 1.0, 1.0] atol = 1e-5
            end

            # one model served the windows that had the same shape, and no more
            @test 1 < reused["horizon"]["built"] < built["horizon"]["built"]
        end
    end

    @testset "a power flow holds a free switch where the data has it" begin
        data = toy([br(1, 1, 2), sw(2, 2, 3; lock = FREE, rate_a = 5.0), br(3, 1, 3)],
                   [gen(1, 1), load(2, 3)])

        for F in (LPFFormulation, IVRFormulation)
            r = quiet(() -> solve_lf(data, F, OPTIMIZER))
            @test r["termination_status"] == JuMP.LOCALLY_SOLVED

            nm = instantiate_model(data, LoadFlowProblem, F)
            @test isempty(get(_NMB.var(nm), :zsw, Dict()))          # no decision to make
        end
    end

end

# What a free switch does to a dispatch problem: the position is a decision, and
# the model that decides it is the first mixed-integer one in the package.

@testset "switch, free" begin

    br(id, i, j; kw...)   = Branch(; id, terminals = [i, j], r = 0.0, x = 0.1, kw...)
    sw(id, i, j; kw...)   = Switch(; id, terminals = [i, j], kw...)
    gen(id, i; kw...)     = Generator(; id, node = i, pmax = 5.0, kw...)
    load(id, i; pd = 1.0) = FixedLoad(; id, node = i, pd)

    "the active power into the first terminal of edge `e`"
    flow(result, e) = nw_solution(result)["edge"]["$e"]["terminal"]["1"]["p"]

    exact = JuMP.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false,
                                           "mip_rel_gap" => 0.0, "mip_abs_gap" => 0.0)

    # A loop 1 - 2 - 3 - 1 with the cheap generator at 1, the dear one at 3 and the
    # load at 2, an edge of each kind in it, and three switches. How much the cheap
    # generator can send depends on which of them are closed, and the best setting
    # is not the one with all of them closed.
    "the loop, its three switches locked or free at `positions`, over `dim` if given"
    function loop(locks, positions; dim = nothing, pd = 1.8)
        I = Dict{Int,AbstractNode}(i => Node(; id = i, type = i == 1 ? REF : PQ) for i in 1:3)
        E = Dict{Int,AbstractEdge}(
            1 => br(1, 1, 2; rate_a = 1.0),
            2 => br(2, 3, 2; rate_a = 1.5),
            3 => sw(3, 1, 3; lock = locks[1], position = positions[1], rate_a = 0.6),
            4 => sw(4, 1, 2; lock = locks[2], position = positions[2], rate_a = 0.8),
            5 => sw(5, 2, 3; lock = locks[3], position = positions[3], rate_a = 5.0))
        U = Dict{Int,AbstractUnit}(1 => gen(1, 1; cost = [0.0, 1.0]),
                                   2 => gen(2, 3; cost = [0.0, 10.0]),
                                   3 => load(3, 2; pd))

        return NetworkData(dim === nothing ? Network(I, E, U) : Network(I, E, U; dim))
    end

    locked(positions) = loop((LOCKED, LOCKED, LOCKED), positions)
    free(positions = (1, 1, 1); kw...) = loop((FREE, FREE, FREE), positions; kw...)

    @testset "the optimum is the best of every way of setting the switches" begin
        tries = [(positions, quiet(() -> solve_opf(locked(positions), LPFFormulation, exact)))
                 for positions in Iterators.product((0, 1), (0, 1), (0, 1))]
        solved = [(p, r["objective"]) for (p, r) in tries
                  if r["termination_status"] == JuMP.OPTIMAL]

        # the choice matters, and one setting is not feasible at all
        @test length(solved) == 7
        @test maximum(last, solved) - minimum(last, solved) > 5.0
        best = minimum(last, solved)

        nm = instantiate_model(free(), OptimalPowerFlowProblem, LPFFormulation)
        optimize_model!(nm, exact)
        @test JuMP.termination_status(nm.model) == JuMP.OPTIMAL
        @test JuMP.objective_value(nm.model) ≈ best atol = 1e-6

        # it closes the one across and opens the other two
        z = [round(Int, JuMP.value(_NMB.var(nm, :zsw, e))) for e in 3:5]
        @test z == [1, 0, 0]
        @test only(p for (p, o) in solved if o ≈ best) == (1, 0, 0)

        # whatever the position it starts from
        for start in ((0, 0, 0), (1, 1, 1), (0, 1, 0))
            r = quiet(() -> solve_opf(free(start), LPFFormulation, exact))
            @test r["objective"] ≈ best atol = 1e-6
        end
    end

    @testset "a free switch is a binary variable that starts where the data has it" begin
        nm = instantiate_model(free((1, 0, 1)), OptimalPowerFlowProblem, LPFFormulation)
        zs = [_NMB.var(nm, :zsw, e) for e in 3:5]

        @test all(JuMP.is_binary, zs)
        @test JuMP.start_value.(zs) == [1.0, 0.0, 1.0]

        # for each switch the flow row, the angle range twice and the flow range twice
        keys_ = [(key, id) for (_, key, id) in keys(registered_constraints(nm))]
        @test count(==(:switch_flow), first.(keys_)) == 3
        @test count(==(:switch_angle_range), first.(keys_)) == 6
        @test count(==(:switch_flow_range), first.(keys_)) == 6

        # a locked one has none of it
        nm = instantiate_model(locked((1, 1, 1)), OptimalPowerFlowProblem, LPFFormulation)
        @test isempty(_NMB.var(nm)[:zsw])
        @test !any(JuMP.is_binary, JuMP.all_variables(nm.model))
    end

    @testset "a model with a free switch has no prices, one without has" begin
        mixed = instantiate_model(free(), OptimalPowerFlowProblem, LPFFormulation)
        optimize_model!(mixed, exact)
        @test !JuMP.has_duals(mixed.model)
        @test all(active_nodal_price(mixed, i) === nothing for i in 1:3)
        @test build_solution(mixed)["dual_status"] == JuMP.NO_SOLUTION

        held = instantiate_model(locked((1, 0, 0)), OptimalPowerFlowProblem, LPFFormulation)
        optimize_model!(held, exact)
        @test JuMP.has_duals(held.model)
        @test all(active_nodal_price(held, i) isa Float64 for i in 1:3)
    end

    @testset "a free switch needs a rating, and in current a positive lower voltage limit" begin
        data(; vmin = 0.9, rate = Inf) = NetworkData(Network(
            Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vmin), 2 => Node(; id = 2, vmin)),
            Dict{Int,AbstractEdge}(1 => br(1, 1, 2), 2 => sw(2, 1, 2; lock = FREE, rate_a = rate)),
            Dict{Int,AbstractUnit}(1 => gen(1, 1), 2 => load(2, 2))))

        for F in (LPFFormulation, IVRFormulation)
            err = try instantiate_model(data(), OptimalPowerFlowProblem, F) catch e e end
            @test err isa ArgumentError
            @test occursin("switch 2", err.msg) && occursin("rate_a", err.msg)

            # a power flow opens nothing, so it asks for none
            @test instantiate_model(data(), LoadFlowProblem, F) isa NetworkModel
        end

        # the bound on a current is the rating over the lowest voltage there may be
        err = try
            instantiate_model(data(; rate = 2.0, vmin = 0.0), OptimalPowerFlowProblem, IVRFormulation)
        catch e
            e
        end
        @test err isa ArgumentError && occursin("vmin", err.msg)
        @test instantiate_model(data(; rate = 2.0, vmin = 0.0), OptimalPowerFlowProblem,
                                LPFFormulation) isa NetworkModel
    end

    @testset "a rolling horizon on one model keeps the position binary" begin
        dim  = Dimension(:time => 4)
        data = free((1, 1, 1); dim, pd = nw_vector(dim, [1.8, 0.5, 1.8, 1.5]))

        roll(; reuse) = quiet(() -> solve_rolling_horizon(data, OptimalPowerFlowProblem,
                                                          LPFFormulation, exact;
                                                          horizon = 2, step = 1, reuse))
        whole  = quiet(() -> solve_opf(data, LPFFormulation, exact))
        built  = roll(reuse = false)
        reused = roll(reuse = true)

        for result in (built, reused)
            @test result["termination_status"] == JuMP.OPTIMAL
            @test result["objective"] ≈ whole["objective"] atol = 1e-4      # the integrality tolerance
        end
        @test reused["horizon"]["built"] < built["horizon"]["built"]
    end

    @testset "in current a free switch is nine rows and a nonconvex one" begin
        nm    = instantiate_model(free((1, 0, 1)), OptimalPowerFlowProblem, IVRFormulation)
        keys_ = first.([(key, id) for (_, key, id) in keys(registered_constraints(nm))])
        zs    = [_NMB.var(nm, :zsw, e) for e in 3:5]

        @test all(JuMP.is_binary, zs)
        @test JuMP.start_value.(zs) == [1.0, 0.0, 1.0]

        # for each switch two flow rows, four on the voltage, four on the current, one rating
        @test count(==(:switch_flow), keys_) == 6
        @test count(==(:switch_voltage_range), keys_) == 12
        @test count(==(:switch_current_range), keys_) == 12
        @test count(==(:switch_rating), keys_) == 3

        nm = instantiate_model(locked((1, 1, 1)), OptimalPowerFlowProblem, IVRFormulation)
        @test isempty(_NMB.var(nm)[:zsw])
        @test !any(JuMP.is_binary, JuMP.all_variables(nm.model))
    end

    @testset "a free switch fixed at a position is the same model as a locked one" begin
        for F in (LPFFormulation, IVRFormulation),
            positions in Iterators.product((0, 1), (0, 1), (0, 1))

            nm = instantiate_model(free(), OptimalPowerFlowProblem, F)
            JuMP.relax_integrality(nm.model)
            for (e, z) in zip(3:5, positions)
                JuMP.fix(_NMB.var(nm, :zsw, e), z; force = true)
            end
            relaxed = quiet(() -> optimize_model!(nm, OPTIMIZER))
            held    = quiet(() -> solve_opf(locked(positions), F, OPTIMIZER))

            if held["termination_status"] != JuMP.LOCALLY_SOLVED
                # the one setting that cannot be fed
                @test relaxed["termination_status"] != JuMP.LOCALLY_SOLVED
            elseif all(==(1), positions)
                # three closed switches round a loop: a locked model gives the loop an
                # equation, and a free one does not, so it may send the flow round as it likes
                @test relaxed["termination_status"] == JuMP.LOCALLY_SOLVED
                @test relaxed["objective"] < held["objective"] - 1.0
            else
                @test relaxed["termination_status"] == JuMP.LOCALLY_SOLVED
                @test relaxed["objective"] ≈ held["objective"] rtol = 1e-6
                @test all(isapprox(flow(relaxed, e), flow(held, e); atol = 1e-5) for e in 1:5)
            end
        end
    end

    @testset "a nonconvex mixed-integer solver chooses the position in current" begin
        juniper = JuMP.optimizer_with_attributes(
            Juniper.Optimizer, "log_levels" => Symbol[],
            "nl_solver" => JuMP.optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0,
                                                           "sb" => "yes"))

        # one switch free, the other two held open
        data = loop((FREE, LOCKED, LOCKED), (1, 0, 0))
        nm   = instantiate_model(data, OptimalPowerFlowProblem, IVRFormulation)
        quiet(() -> optimize_model!(nm, juniper))

        held = [quiet(() -> solve_opf(loop((LOCKED, LOCKED, LOCKED), (z, 0, 0)),
                                      IVRFormulation, OPTIMIZER)) for z in (0, 1)]
        best = minimum(r["objective"] for r in held
                       if r["termination_status"] == JuMP.LOCALLY_SOLVED)

        @test JuMP.termination_status(nm.model) in (JuMP.OPTIMAL, JuMP.LOCALLY_SOLVED)
        @test JuMP.objective_value(nm.model) ≈ best rtol = 1e-5
        @test round(Int, JuMP.value(_NMB.var(nm, :zsw, 3))) == 1
        @test maximum(r["objective"] for r in held) > best + 1.0       # and it was a choice

        # a mixed-integer program has no prices in this formulation either
        @test !JuMP.has_duals(nm.model)
        @test all(active_nodal_price(nm, i) === nothing for i in 1:3)
    end

end
