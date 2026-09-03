################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.7.0 - energy not served and spill                                         #
################################################################################

# Every network below is a single node, so nothing the network does can hide
# what the slack units do: whatever the generator cannot cover is unserved, and
# whatever it cannot avoid producing is spilled.

"""
A one node system with a generator of capability `[pmin, pmax]` at a linear
`price`, a load of `pd`, and whichever slack units `extra` adds.
"""
function slack_network(; dim::Dimension = Dimension(), pmin = 0.0, pmax = 5.0,
                         price = 10.0, pd = 1.0,
                         extra::Dict{Int,AbstractUnit} = Dict{Int,AbstractUnit}())
    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.0))
    E = Dict{Int,AbstractEdge}()
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, pmin = pmin, pmax = pmax,
                       qmin = -5.0, qmax = 5.0, cost = [0.0, price]),
        2 => FixedLoad(; id = 2, node = 1, pd = pd, qd = 0.0))
    merge!(U, extra)

    return NetworkData(Network(I, E, U; dim); name = "slack", baseMVA = 100.0)
end

@testset "energy not served and spill" begin

    @testset "both types are registered units" begin
        @test AbstractSlackUnit <: AbstractUnit
        @test EnergyNotServed   <: AbstractSlackUnit
        @test Spill             <: AbstractSlackUnit

        @test EnergyNotServed in unit_types()
        @test Spill in unit_types()

        # and are readable from a table the moment they exist, see `component_types`
        @test component_types()["EnergyNotServed"] === EnergyNotServed
        @test component_types()["Spill"] === Spill
    end

    @testset "the price of a slack unit is the price of an injection" begin
        @test slack_sign(EnergyNotServed(; id = 1, node = 1)) == 1.0
        @test slack_sign(Spill(; id = 1, node = 1)) == -1.0

        # the defaults carry the invariant: an unserved per unit is never cheaper
        # than a spilled one, whatever node either of them sits on
        @test EnergyNotServed(; id = 1, node = 1).cost >= Spill(; id = 2, node = 1).cost

        @test_throws ArgumentError EnergyNotServed(; id = 1, node = 1, cost = -1.0)
        @test_throws ArgumentError Spill(; id = 1, node = 1, cost = 1.0)
        @test_throws ArgumentError EnergyNotServed(; id = 1, node = 1, pmax = -1.0)
        @test_throws ArgumentError Spill(; id = 1, node = 1, pmax = -1.0)

        # zero is admissible on both sides, and is the pair meeting
        @test EnergyNotServed(; id = 1, node = 1, cost = 0.0) isa EnergyNotServed
        @test Spill(; id = 1, node = 1, cost = 0.0) isa Spill
    end

    @testset "a power flow leaves them idle" begin
        extra = Dict{Int,AbstractUnit}(3 => EnergyNotServed(; id = 3, node = 1))
        for F in (IVRFormulation, LPFFormulation)
            nm = instantiate_model(slack_network(; extra), LoadFlowProblem, F)

            # nothing to relax in a problem that decides nothing
            @test !haskey(_NMB.var(nm), :psl)
        end
    end

    @testset "what the generation cannot cover is unserved" begin
        extra  = Dict{Int,AbstractUnit}(
            3 => EnergyNotServed(; id = 3, node = 1, cost = 5000.0))
        result = solve_opf(slack_network(; pmax = 0.4, price = 10.0, pd = 1.0, extra),
                           LPFFormulation, OPTIMIZER)

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED ||
              result["termination_status"] == JuMP.OPTIMAL

        sol = nw_solution(result, 1)["unit"]
        @test sol["1"]["pg"] ≈ 0.4  atol = 1e-6      # the generator runs flat out
        @test sol["3"]["psl"] ≈ 0.6 atol = 1e-6      # and 0.6 pu goes unserved
        @test sol["3"]["p"] ≈ 0.6   atol = 1e-6      # a slack unit that injects

        # 10 · 0.4 of generation plus 5000 · 0.6 of lost load
        @test result["objective"] ≈ 3004.0 atol = 1e-4
    end

    @testset "what the generation cannot avoid is spilled" begin
        extra  = Dict{Int,AbstractUnit}(3 => Spill(; id = 3, node = 1, cost = -500.0))
        result = solve_opf(slack_network(; pmin = 1.0, pmax = 1.0, price = 10.0,
                                           pd = 0.4, extra),
                           LPFFormulation, OPTIMIZER)

        sol = nw_solution(result, 1)["unit"]
        @test sol["1"]["pg"] ≈ 1.0   atol = 1e-6     # the must-run cannot back off
        @test sol["3"]["psl"] ≈ 0.6  atol = 1e-6     # so 0.6 pu is spilled
        @test sol["3"]["p"] ≈ -0.6   atol = 1e-6     # a slack unit that withdraws

        # 10 · 1.0 of generation plus 500 · 0.6 of spill, both a cost
        @test result["objective"] ≈ 310.0 atol = 1e-4
    end

    @testset "a slack unit is used only where it is worth it" begin
        # the same system with enough capability leaves the slack unit at zero
        extra  = Dict{Int,AbstractUnit}(
            3 => EnergyNotServed(; id = 3, node = 1, cost = 5000.0),
            4 => Spill(; id = 4, node = 1, cost = -500.0))
        result = solve_opf(slack_network(; pmax = 5.0, pd = 1.0, extra),
                           LPFFormulation, OPTIMIZER)

        sol = nw_solution(result, 1)["unit"]
        @test sol["1"]["pg"] ≈ 1.0   atol = 1e-6
        @test sol["3"]["psl"] ≈ 0.0  atol = 1e-6
        @test sol["4"]["psl"] ≈ 0.0  atol = 1e-6
        @test result["objective"] ≈ 10.0 atol = 1e-4
    end

    @testset "pmax bounds the relaxation" begin
        extra = Dict{Int,AbstractUnit}(
            3 => EnergyNotServed(; id = 3, node = 1, pmax = 0.2))
        nm    = instantiate_model(slack_network(; pmax = 0.4, extra),
                                  OptimalPowerFlowProblem, LPFFormulation)

        @test JuMP.lower_bound(_NMB.var(nm, :psl, 3)) == 0.0
        @test JuMP.upper_bound(_NMB.var(nm, :psl, 3)) == 0.2

        # an unbounded one is left free rather than bounded by infinity
        free = instantiate_model(
            slack_network(; extra = Dict{Int,AbstractUnit}(
                3 => EnergyNotServed(; id = 3, node = 1))),
            OptimalPowerFlowProblem, LPFFormulation)
        @test !JuMP.has_upper_bound(_NMB.var(free, :psl, 3))

        # and `pmax` is what decides the shape of the model, so a rating that
        # comes and goes across a rolling horizon rebuilds rather than updates
        @test structure_gates(EnergyNotServed(; id = 3, node = 1)) == (:pmax,)
    end

    @testset "a slack unit exchanges no reactive power" begin
        extra = Dict{Int,AbstractUnit}(3 => EnergyNotServed(; id = 3, node = 1))
        nm    = instantiate_model(slack_network(; extra), OptimalPowerFlowProblem,
                                  IVRFormulation)

        # it has a volume like any other, and no reactive counterpart
        @test haskey(_NMB.var(nm, :psl), 3)
        @test !haskey(_NMB.var(nm), :qsl)
    end

    @testset "the objective reaches every unit, not only the generators" begin
        # the hook is what makes a priced unit possible without editing the
        # objective; a unit that says nothing costs nothing
        nm = instantiate_model(slack_network(), OptimalPowerFlowProblem, LPFFormulation)
        @test dispatch_cost(nm, FixedLoad, 2; nw = 1) == 0.0
        @test dispatch_cost(nm, Generator, 1; nw = 1) isa JuMP.AbstractJuMPScalar

        extra = Dict{Int,AbstractUnit}(
            3 => EnergyNotServed(; id = 3, node = 1, cost = 5000.0))
        sl    = instantiate_model(slack_network(; extra), OptimalPowerFlowProblem,
                                  LPFFormulation)
        @test JuMP.coefficient(dispatch_cost(sl, EnergyNotServed, 3; nw = 1),
                               _NMB.var(sl, :psl, 3)) ≈ 5000.0

        # a spill is priced on its injection, which makes its volume a charge
        extra = Dict{Int,AbstractUnit}(3 => Spill(; id = 3, node = 1, cost = -500.0))
        sp    = instantiate_model(slack_network(; extra), OptimalPowerFlowProblem,
                                  LPFFormulation)
        @test JuMP.coefficient(dispatch_cost(sp, Spill, 3; nw = 1),
                               _NMB.var(sp, :psl, 3)) ≈ 500.0
    end

    @testset "a linear cost keeps the objective linear" begin
        extra = Dict{Int,AbstractUnit}(
            3 => EnergyNotServed(; id = 3, node = 1),
            4 => Spill(; id = 4, node = 1))
        nm = instantiate_model(slack_network(; extra), OptimalPowerFlowProblem,
                               LPFFormulation)

        @test JuMP.objective_function_type(nm.model) == JuMP.AffExpr
    end

    @testset "a redispatch pays for what it leaves unserved" begin
        # the branch cannot carry the load and there is nothing behind it, so the
        # only measure left is not serving it
        I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.0),
                                   2 => Node(; id = 2))
        E = Dict{Int,AbstractEdge}(
            1 => Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.1, rate_a = 0.5))
        U = Dict{Int,AbstractUnit}(
            1 => Generator(; id = 1, node = 1, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                           pg = 1.0, cost = [0.0, 10.0]),
            2 => FixedLoad(; id = 2, node = 2, pd = 1.0, qd = 0.0),
            3 => EnergyNotServed(; id = 3, node = 2, cost = 1000.0))
        data = NetworkData(Network(I, E, U; dim = Dimension()); baseMVA = 100.0)

        result = solve_rd(data, LPFFormulation, OPTIMIZER;
                          redispatch = Redispatch(; monitored = [1]))

        sol = nw_solution(result, 1)["unit"]
        @test sol["3"]["psl"] ≈ 0.5 atol = 1e-6      # half the load goes unserved
        @test sol["1"]["pgdn"] ≈ 0.5 atol = 1e-6     # and the generator backs off

        # 1000 · 0.5 of lost load plus 10 · 0.5 of the generator moving down
        @test result["objective"] ≈ 505.0 atol = 1e-4
    end
end
