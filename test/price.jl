################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.7.0 - nodal prices from the duals of the node balance                     #
################################################################################

# Two nodes, a cheap generator on one and a dear one on the other, and a branch
# between them that may or may not be able to carry the difference. The
# linearized formulation is lossless, so every price below is one of the two
# generation costs and nothing in between.

"a two node network whose branch carries `rate`, or as much as it likes"
function priced_network(; rate = Inf, pd = 1.0, dim::Dimension = Dimension())
    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.0),
                               2 => Node(; id = 2))
    E = Dict{Int,AbstractEdge}(
        1 => Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.1, rate_a = rate))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       cost = [0.0, 10.0]),
        2 => Generator(; id = 2, node = 2, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       cost = [0.0, 100.0]),
        3 => FixedLoad(; id = 3, node = 2, pd = pd, qd = 0.0))

    return NetworkData(Network(I, E, U; dim); name = "priced", baseMVA = 100.0)
end

"the nodal price of every node of a result at network index `n`"
prices(result, n = 1) = [nw_solution(result, n)["node"]["$i"]["lambda"] for i in 1:2]

@testset "nodal prices" begin

    @testset "an uncongested network prices every node the same" begin
        result = quiet(() -> solve_opf(priced_network(), LPFFormulation, OPTIMIZER))

        @test result["dual_status"] == JuMP.FEASIBLE_POINT
        @test result["objective"] ≈ 10.0 atol = 1e-4

        # the cheap generator is marginal everywhere, so it sets both prices
        @test prices(result) ≈ [10.0, 10.0] atol = 1e-4
    end

    @testset "a congested corridor splits the price" begin
        # the branch carries 0.4 of the 1.0 the load needs, so the dear
        # generator makes the rest: 10(0.4) + 100(0.6) = 64
        result = quiet(() -> solve_opf(priced_network(; rate = 0.4), LPFFormulation,
                                       OPTIMIZER))
        @test result["objective"] ≈ 64.0 atol = 1e-4

        λ = prices(result)
        @test λ ≈ [10.0, 100.0] atol = 1e-4

        # and the two sides of the constraint account for each other exactly: the
        # load pays its node's price, the generators are paid theirs, and what is
        # left over is the congestion rent of the branch
        paid_by_load  = λ[2] * 1.0
        paid_to_gens  = λ[1] * 0.4 + λ[2] * 0.6
        @test paid_by_load - paid_to_gens ≈ (λ[2] - λ[1]) * 0.4 atol = 1e-4
        @test paid_to_gens ≈ result["objective"] atol = 1e-4
    end

    @testset "a price is the cost of one more per unit withdrawn" begin
        # the sign is the whole of this: solve the same problem with a fraction
        # more demand and the objective rises by the price of the node it is at
        base  = quiet(() -> solve_opf(priced_network(; rate = 0.4), LPFFormulation,
                                      OPTIMIZER))
        more  = quiet(() -> solve_opf(priced_network(; rate = 0.4, pd = 1.01),
                                      LPFFormulation, OPTIMIZER))

        @test more["objective"] - base["objective"] ≈ 0.01 * prices(base)[2] atol = 1e-3
        @test all(>(0), prices(base))
    end

    @testset "every network index is priced on its own" begin
        # a horizon whose load is congested in the second step only
        dim  = Dimension(:time => 2)
        data = priced_network(; rate = 0.4, pd = NetworkVector([0.2, 1.0]), dim)

        result = quiet(() -> solve_opf(data, LPFFormulation, OPTIMIZER))
        @test prices(result, 1) ≈ [10.0, 10.0]  atol = 1e-4
        @test prices(result, 2) ≈ [10.0, 100.0] atol = 1e-4
    end

    @testset "the accessor and the solution agree" begin
        nm = instantiate_model(priced_network(; rate = 0.4), OptimalPowerFlowProblem,
                               LPFFormulation)

        # a model that has not been solved has no duals to report
        @test nodal_price(nm, 1) === nothing

        quiet(() -> optimize_model!(nm, OPTIMIZER))
        @test nodal_price(nm, 1) ≈ 10.0  atol = 1e-4
        @test nodal_price(nm, 2) ≈ 100.0 atol = 1e-4
        @test nodal_price(nm, 2; nw = 1) ≈ nw_solution(nm.sol)["node"]["2"]["lambda"]

        # and a node the model does not hold has no price rather than an error
        @test nodal_price(nm, 99) === nothing
    end

    @testset "a redispatch prices the measures it would have to take" begin
        # nothing is congested, so relieving one more per unit of withdrawal at
        # either node costs what moving the generators costs — and never zero,
        # since both directions of a redispatch are priced
        result = quiet(() -> solve_rd(priced_network(; rate = 0.4), LPFFormulation,
                                      OPTIMIZER))
        @test result["dual_status"] == JuMP.FEASIBLE_POINT
        @test haskey(nw_solution(result)["node"]["1"], "lambda")
    end

    @testset "a roll reports the prices of the steps it committed" begin
        dim  = Dimension(:time => 4)
        data = priced_network(; rate = 0.4, pd = NetworkVector([0.2, 1.0, 0.2, 1.0]), dim)

        result = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER;
                                      horizon = 2, step = 1))

        # every window was priced, so the roll says so rather than claiming it
        # has no duals while carrying a price at every node it committed
        @test result["dual_status"] == JuMP.FEASIBLE_POINT
        for n in 1:4, i in ("1", "2")
            @test haskey(nw_solution(result, n)["node"][i], "lambda")
        end
    end

    @testset "a feasibility problem prices nothing" begin
        # a load flow minimizes zero, so every price in one is zero; that is
        # correct and says only that nothing was being minimized
        result = quiet(() -> solve_lf(priced_network(), LPFFormulation, OPTIMIZER))

        @test result["dual_status"] == JuMP.FEASIBLE_POINT
        @test prices(result) ≈ [0.0, 0.0] atol = 1e-6
    end

    @testset "the current based balance is priced in current, and says so" begin
        result = quiet(() -> solve_opf(priced_network(), IVRFormulation, OPTIMIZER))

        # both rows of the balance are reported, and neither is called a price
        for i in ("1", "2")
            @test haskey(result["solution"]["nw"]["1"]["node"][i], "lambda_real")
            @test haskey(result["solution"]["nw"]["1"]["node"][i], "lambda_imag")
            @test !haskey(result["solution"]["nw"]["1"]["node"][i], "lambda")
        end

        nm = instantiate_model(priced_network(), OptimalPowerFlowProblem, IVRFormulation)
        quiet(() -> optimize_model!(nm, OPTIMIZER))

        err = try
            nodal_price(nm, 1)
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("balance is in current", err.msg)
    end
end
