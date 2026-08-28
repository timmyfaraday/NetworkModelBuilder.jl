################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.5.0 - the redispatch problem                                              #
################################################################################

# The network below is the radial one of `rd.jl` over a horizon, with a battery
# behind the constraint and a price that jumps in the last step. Every step needs
# 0.5 from behind the constraint, generator 1 comes down by 0.5 to give it, and
# the battery holds 0.4 it can spend in whichever step it likes.
#
#   with full information : 20 + 10(0.5) + 10(0.5) + 10(0.5) + 200(0.5 - 0.4) = 55
#   seeing one step ahead : 20 + 10(0.5 - 0.4) + 10(0.5) + 10(0.5) + 200(0.5) = 131
#
# the second being what it costs to spend a battery in the cheapest hour of the
# day because the expensive one is not yet visible.

const ROLLING_PRICES = [10.0, 10.0, 10.0, 200.0]

"a radial network over `length(prices)` steps whose expensive generator is priced per step"
function rolling_network(prices = ROLLING_PRICES; energy = 0.4, extra_dims = ())
    dim = Dimension(:time => length(prices), extra_dims...)

    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.0),
                               2 => Node(; id = 2))
    E = Dict{Int,AbstractEdge}(
        1 => Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.1, rate_a = 0.5))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       pg = 1.0, cost = [0.0, 10.0]),
        2 => Generator(; id = 2, node = 2, pmax = 5.0, qmin = -5.0, qmax = 5.0, pg = 0.0,
                       cost = nw_vector(dim, :time, [[0.0, c] for c in prices])),
        3 => FixedLoad(; id = 3, node = 2, pd = 1.0, qd = 0.0),
        4 => Storage(; id = 4, node = 2, energy_capacity = energy, energy_initial = energy,
                     charge_rating = 0.0, discharge_rating = 0.5,
                     charge_efficiency = 1.0, discharge_efficiency = 1.0))

    return NetworkData(Network(I, E, U; dim); name = "rolling", baseMVA = 100.0)
end

"the discharge of the battery at every time step of a result"
discharge(result, steps) = [nw_solution(result, n)["unit"]["4"]["psd"] for n in steps]

@testset "rolling horizon" begin

    @testset "a window is an ordinary data set over fewer coordinates" begin
        data = rolling_network()
        w    = window(data, :time, 2:3)

        @test w isa NetworkData
        @test dim_names(w) == (:time,)
        @test dim_length(w) == 2
        @test nw_ids(w) == [1, 2]                     # indexed from one, not from two
        @test baseMVA(w) == baseMVA(data)

        # the profile of the source is sliced, not recomputed
        for (k, n) in enumerate(2:3)
            @test unit(network(w), 2; nw = k).cost == unit(network(data), 2; nw = n).cost
        end

        # and what does not vary is left as a plain value
        @test !has_nw_data(units(network(w))[1])
        @test units(network(w))[3].pd == 1.0
    end

    @testset "a window keeps every other dimension whole" begin
        data = rolling_network(; extra_dims = (:contingency => 3,))
        w    = window(data, :time, 3:4)

        @test dim_names(w) == (:time, :contingency)
        @test dim_length(w, :time) == 2
        @test dim_length(w, :contingency) == 3
        @test dim_length(w) == 6

        # window index k sits at the source index with the same contingency
        idx = window_indices(data, :time, 3:4)
        @test length(idx) == 6
        for m in nw_ids(w)
            @test coordinates(w, m).contingency == coordinates(data, idx[m]).contingency
            @test coordinates(data, idx[m]).time == (3:4)[coordinates(w, m).time]
        end
        @test window_indices(data, :time, 1:4) == nw_ids(data)
    end

    @testset "a window carries the properties of the coordinates it keeps" begin
        dim = Dimension(:time => [Dict{Symbol,Any}(:duration => d) for d in (0.25, 0.5, 1.0, 2.0)])
        I   = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF))
        E   = Dict{Int,AbstractEdge}(1 => Branch(; id = 1, terminals = [1, 1], r = 0.0, x = 0.1))
        U   = Dict{Int,AbstractUnit}(1 => Generator(; id = 1, node = 1))
        data = NetworkData(Network(I, E, U; dim))

        w = window(data, :time, 2:4)
        @test [dim_prop(w, :time, k, :duration) for k in 1:3] == [0.5, 1.0, 2.0]
    end

    @testset "a window re-derives its topology from the statuses it kept" begin
        dim  = Dimension(:time => 4)
        out  = nw_vector(dim, (n, c) -> n != 2)          # edge 2 is out at step 2 only
        I    = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF), 2 => Node(; id = 2))
        E    = Dict{Int,AbstractEdge}(
            1 => Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.1),
            2 => Branch(; id = 2, terminals = [1, 2], r = 0.0, x = 0.2, status = out))
        U    = Dict{Int,AbstractUnit}(1 => Generator(; id = 1, node = 1),
                                      2 => FixedLoad(; id = 2, node = 2, pd = 0.1))
        data = NetworkData(Network(I, E, U; dim))

        # a window that spans the outage still switches
        early = window(data, :time, 1:2)
        @test switchable(network(early)) == [(:edge, 2)]
        @test 2 ∈ ids(network(early), Branch; nw = 1)
        @test 2 ∉ ids(network(early), Branch; nw = 2)

        # one that steps over it has nothing switchable left at all
        late = window(data, :time, 3:4)
        @test isempty(switchable(network(late)))
        @test all(2 ∈ ids(network(late), Branch; nw = n) for n in nw_ids(late))
    end

    @testset "a window says what it cannot cut" begin
        data = rolling_network()

        @test_throws ArgumentError window(data, :scenario, 1:2)
        @test_throws ArgumentError window(data, :time, Int[])
        @test_throws ArgumentError window(data, :time, 3:5)
        @test_throws ArgumentError window(data, :time, 0:2)
    end

    @testset "one window is the whole problem" begin
        data = rolling_network()

        full = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER))
        one  = quiet(() -> solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                                 OPTIMIZER; horizon = 4, step = 4))

        @test length(one["horizon"]["window"]) == 1
        @test one["objective"] ≈ full["objective"] atol = 1e-6
        @test one["objective"] ≈ 55.0 atol = 1e-4          # worked out in this file
        for n in 1:4
            @test nw_solution(one, n)["unit"]["4"]["psd"] ≈
                  nw_solution(full, n)["unit"]["4"]["psd"] atol = 1e-5
        end
    end

    @testset "every time step is committed, whatever the window" begin
        data = rolling_network()

        for (horizon, step) in ((1, 1), (2, 1), (3, 1), (4, 1), (2, 2), (3, 2), (4, 4))
            result = quiet(() -> solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                                       OPTIMIZER; horizon, step))
            @test result["termination_status"] == JuMP.LOCALLY_SOLVED
            @test sort(parse.(Int, collect(keys(result["solution"]["nw"])))) == [1, 2, 3, 4]

            # the committed steps of the windows partition the horizon exactly once
            committed = reduce(vcat, w["committed"] for w in result["horizon"]["window"])
            @test sort(committed) == [1, 2, 3, 4]
        end
    end

    @testset "the lookahead is what stops a window from being myopic" begin
        data = rolling_network()
        objectives = map(1:4) do horizon
            quiet(() -> solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                              OPTIMIZER; horizon, step = 1))["objective"]
        end

        # seeing one step ahead spends the battery in the cheapest hour of the day
        @test objectives[1] ≈ 131.0 atol = 1e-3
        # seeing all four is the full information optimum
        @test objectives[4] ≈ 55.0 atol = 1e-3
        # and no window ever beats it, because none of them knows more
        @test issorted(objectives; rev = true)
        @test all(o >= objectives[4] - 1e-6 for o in objectives)

        myopic = quiet(() -> solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                                   OPTIMIZER; horizon = 1, step = 1))
        aware  = quiet(() -> solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                                   OPTIMIZER; horizon = 4, step = 1))
        @test discharge(myopic, 1:4) ≈ [0.4, 0.0, 0.0, 0.0] atol = 1e-5
        @test discharge(aware,  1:4) ≈ [0.0, 0.0, 0.0, 0.4] atol = 1e-5
    end

    @testset "the state of charge is carried across the windows" begin
        data   = rolling_network()
        result = quiet(() -> solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                                   OPTIMIZER; horizon = 2, step = 1))

        # each window started from the energy the previous one left behind, so the
        # trajectory is continuous across a boundary it never saw
        energy = 0.4
        for n in 1:4
            battery = nw_solution(result, n)["unit"]["4"]
            energy -= battery["psd"]
            @test battery["es"] ≈ energy atol = 1e-5
            @test energy >= -1e-6
        end

        # and the battery never gave more than it held
        @test sum(discharge(result, 1:4)) ≤ 0.4 + 1e-6
    end

    @testset "initial_state is what a component carries, and only that" begin
        data = rolling_network()
        nm   = instantiate_model(window(data, :time, 1:2), RedispatchProblem, LPFFormulation)
        quiet(() -> optimize_model!(nm, OPTIMIZER))

        battery = units(network(data))[4]::Storage
        carried = initial_state(battery, nm, 1)

        @test carried isa Storage
        @test carried.energy_initial ≈ JuMP.value(_NMB.var(nm, :es, 4; nw = 1))
        @test carried.energy_initial != battery.energy_initial
        # everything that is not state is left exactly as it was
        @test carried.node == battery.node
        @test carried.discharge_rating == battery.discharge_rating
        @test carried.energy_capacity == battery.energy_capacity

        # nothing else in the package carries anything
        @test initial_state(units(network(data))[1], nm, 1) === units(network(data))[1]
        @test initial_state(units(network(data))[3], nm, 1) === units(network(data))[3]
        @test initial_state(edges(network(data))[1], nm, 1) === edges(network(data))[1]
    end

    @testset "the roll leaves the data set it was given alone" begin
        data   = rolling_network()
        before = units(network(data))[4]::Storage

        quiet(() -> solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                          OPTIMIZER; horizon = 2, step = 1))

        @test units(network(data))[4] === before
        @test units(network(data))[4].energy_initial == 0.4
    end

    @testset "it rolls any problem, not only a redispatch" begin
        data   = rolling_network()
        result = quiet(() -> solve_rolling_horizon(data, OptimalPowerFlowProblem,
                                                   LPFFormulation, OPTIMIZER;
                                                   horizon = 2, step = 1))

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test result["problem_type"] === OptimalPowerFlowProblem
        @test sort(parse.(Int, collect(keys(result["solution"]["nw"])))) == [1, 2, 3, 4]

        # the objective is the generation cost of the committed steps, not the
        # price of a redispatch
        @test result["objective"] > 0.0
    end

    @testset "the per-index cost is the objective, one index at a time" begin
        data = rolling_network()

        # the objective is nothing more than the weighted sum of these
        for P in (OptimalPowerFlowProblem, RedispatchProblem)
            nm = instantiate_model(data, P, LPFFormulation)
            @test sum(network_weight(nm, n) * network_cost(nm, n) for n in nw_ids(nm)) ==
                  JuMP.objective_function(nm.model)
        end

        # a power flow is a feasibility problem, so every index of it is free
        lf = instantiate_model(data, LoadFlowProblem, LPFFormulation)
        @test network_cost(lf, 1) == 0.0

        # and a problem type with no method says so rather than costing nothing
        bare = instantiate_model(data, AbstractDispatchProblem, LPFFormulation; build = false)
        err  = try
            network_cost(bare, 1)
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("no per-index cost", err.msg)
    end

    @testset "the roll says what it cannot do" begin
        data = rolling_network()
        flat = NetworkData(Network(deepcopy(nodes(network(data))), deepcopy(edges(network(data))),
                                   Dict{Int,AbstractUnit}(1 => Generator(; id = 1, node = 1),
                                                          3 => FixedLoad(; id = 3, node = 2, pd = 0.1))))

        # a rolling horizon runs along `:time`, and says so where there is none
        err = try
            solve_rolling_horizon(flat, RedispatchProblem, LPFFormulation, OPTIMIZER; horizon = 2)
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(":time", err.msg)

        @test_throws ArgumentError solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                                         OPTIMIZER; horizon = 0)
        @test_throws ArgumentError solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                                         OPTIMIZER; horizon = 2, step = 0)
        @test_throws ArgumentError solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                                         OPTIMIZER; horizon = 2, step = 3)
        @test_throws ArgumentError solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                                         OPTIMIZER; horizon = 9)
    end

    @testset "solve_rd rolls when it is given a horizon" begin
        data = rolling_network()

        direct  = quiet(() -> solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                                    OPTIMIZER; horizon = 2, step = 1))
        through = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2, step = 1))
        @test through["objective"] ≈ direct["objective"] atol = 1e-6
        @test haskey(through, "horizon")

        # without one it is the single problem it has always been
        single = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER))
        @test !haskey(single, "horizon")
        @test single["objective"] ≈ 55.0 atol = 1e-4

        # and the setup reaches the windows: watching no edge leaves the market
        # dispatch alone in every one of them
        none = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2,
                                    redispatch = Redispatch(; monitored = Int[])))
        @test none["objective"] ≈ 0.0 atol = 1e-5
        for n in 1:4
            @test nw_solution(none, n)["unit"]["1"]["pg"] ≈ 1.0 atol = 1e-5
        end
    end

    @testset "the result reports what each window covered" begin
        data   = rolling_network()
        result = quiet(() -> solve_rolling_horizon(data, RedispatchProblem, LPFFormulation,
                                                   OPTIMIZER; horizon = 3, step = 1))
        windows = result["horizon"]["window"]

        @test result["horizon"]["horizon"] == 3
        @test result["horizon"]["step"] == 1
        @test length(windows) == 4

        @test [w["first"] for w in windows] == [1, 2, 3, 4]
        @test [w["last"]  for w in windows] == [3, 4, 4, 4]   # the tail sees less ahead
        @test [w["committed"] for w in windows] == [[1], [2], [3], [4]]

        # a window's own objective prices its lookahead too, so it is not the
        # committed cost and the two are reported apart
        @test all(haskey(w, "objective") for w in windows)
        @test result["solve_time"] ≈ sum(w["solve_time"] for w in windows)
    end
end
