################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.6.0 - initial implementation                                              #
################################################################################

# Two nodes with no alternating current path between them, joined only by a dc
# link. Every per unit the load takes therefore crosses the link, which is what
# makes the transfer and the loss readable straight off the answer. Both nodes
# are references, which a branch could never allow: that they may be is the
# decoupling the link exists for.
"""
Two islands joined by one dc link. `cheap` names the node holding the cheap
generator, and the load sits on the other one, so `cheap = 1` sends power from
the from terminal and `cheap = 2` sends it back the other way.
"""
function island_network(; cheap::Int = 1, flip::Bool = false, rate::Float64 = Inf,
                          loss_fixed::Float64 = 0.0, loss_prop::Float64 = 0.0,
                          reverse::Bool = true, pdc::Float64 = 0.0, cost::Float64 = 0.0,
                          load::Int = 0, dim::Dimension = Dimension())
    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.0),
                               2 => Node(; id = 2, type = REF, vm = 1.0))
    E = Dict{Int,AbstractEdge}(
        1 => DCLink(; id = 1, terminals = flip ? [2, 1] : [1, 2], rate_a = rate,
                      loss_fixed, loss_prop, reverse, pdc, cost))
    c1, c2 = cheap == 1 ? (10.0, 100.0) : (100.0, 10.0)
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       cost = [0.0, c1]),
        2 => Generator(; id = 2, node = 2, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       cost = [0.0, c2]),
        3 => FixedLoad(; id = 3, node = load == 0 ? (cheap == 1 ? 2 : 1) : load,
                       pd = 1.0, qd = 0.0))

    return NetworkData(Network(I, E, U; dim); name = "islands", baseMVA = 100.0)
end

"the dc link entry of a solution at network index `n`"
link(result, n = 1) = nw_solution(result, n)["edge"]["1"]

@testset "dc link" begin

    @testset "it is an edge type like any other" begin
        @test DCLink <: AbstractDCLink <: AbstractEdge
        @test DCLink in edge_types()

        dl = DCLink(; id = 1, terminals = [1, 2], rate_a = 2.0)
        @test terminals(dl) == [1, 2]
        @test nterminals(dl) == 2
        @test structure_gates(dl) == (:rate_a, :loss_prop)
        @test transfer_limits(dl) == (-2.0, 2.0)
        @test transfer_limits(DCLink(; id = 1, terminals = [1, 2], rate_a = 2.0,
                                       reverse = false)) == (0.0, 2.0)
    end

    @testset "it validates what it is given" begin
        ok(; kw...) = DCLink(; id = 1, terminals = [1, 2], kw...)

        @test_throws ArgumentError DCLink(; id = 1, terminals = [1, 2, 3])
        @test_throws ArgumentError ok(; rate_a = -1.0)
        @test_throws ArgumentError ok(; loss_fixed = -0.1)
        @test_throws ArgumentError ok(; loss_prop = -0.1)
        @test_throws ArgumentError ok(; loss_prop = 1.0)      # a link that eats everything
        @test_throws ArgumentError ok(; cost = -1.0)
        @test_throws ArgumentError ok(; rate_a = 1.0, pdc = 2.0)
        @test_throws ArgumentError ok(; reverse = false, pdc = -1.0)

        @test ok(; loss_prop = 0.99) isa DCLink
        @test ok(; rate_a = 1.0, pdc = -1.0) isa DCLink        # at the rating, backwards
    end

    @testset "a lossless link delivers what it takes" begin
        result = quiet(() -> solve_opf(island_network(), LPFFormulation, OPTIMIZER))

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test link(result)["pdc"]  ≈ 1.0 atol = 1e-6
        @test link(result)["loss"] ≈ 0.0 atol = 1e-8
        @test result["objective"]  ≈ 10.0 atol = 1e-5

        # what leaves one terminal arrives at the other, and nothing else joins them
        @test link(result)["terminal"]["1"]["p"] ≈ -link(result)["terminal"]["2"]["p"] atol = 1e-8
    end

    @testset "a lossy link is charged on what is sent" begin
        result = quiet(() -> solve_opf(island_network(; loss_prop = 0.05),
                                       LPFFormulation, OPTIMIZER))

        # to land 1.0 the link must be sent t with t - 0.05t = 1.0
        @test link(result)["pdc"]  ≈ 1 / 0.95    atol = 1e-6
        @test link(result)["loss"] ≈ 0.05 / 0.95 atol = 1e-6
        @test result["objective"]  ≈ 10.0 / 0.95 atol = 1e-4

        # the transfer settled on what was sent rather than anywhere above it,
        # which is the whole question about the relaxation
        nm = instantiate_model(island_network(; loss_prop = 0.05),
                               OptimalPowerFlowProblem, LPFFormulation)
        quiet(() -> optimize_model!(nm, OPTIMIZER))
        @test JuMP.value(_NMB.var(nm, :pdct, 1)) ≈ 1 / 0.95 atol = 1e-6
    end

    @testset "a fixed loss is taken whether it carries anything or not" begin
        # the cheap generator and the load are both on node 1, so the link has
        # nothing to carry — and still takes its no-load loss, which somebody
        # has to generate
        idle = island_network(; loss_fixed = 0.02, load = 1)

        result = quiet(() -> solve_opf(idle, LPFFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test link(result)["loss"] ≈ 0.02 atol = 1e-6
        @test link(result)["pdc"]  ≈ 0.02 atol = 1e-6   # what it draws is the loss itself

        # with the loss gone the link is genuinely idle, which is the contrast
        none = quiet(() -> solve_opf(island_network(; load = 1), LPFFormulation, OPTIMIZER))
        @test link(none)["pdc"]  ≈ 0.0 atol = 1e-7
        @test link(none)["loss"] ≈ 0.0 atol = 1e-8
    end

    @testset "it runs the same way whichever way it runs" begin
        # a converter station is symmetric equipment. Neither the direction of
        # the flow nor the order the two nodes were listed in may change what it
        # does, and the order is a data-entry choice with no physics in it.
        forward = quiet(() -> solve_opf(island_network(; cheap = 1, loss_prop = 0.05),
                                        LPFFormulation, OPTIMIZER))
        reverse = quiet(() -> solve_opf(island_network(; cheap = 2, loss_prop = 0.05),
                                        LPFFormulation, OPTIMIZER))
        listed  = quiet(() -> solve_opf(island_network(; cheap = 2, flip = true,
                                                         loss_prop = 0.05),
                                        LPFFormulation, OPTIMIZER))

        @test link(forward)["pdc"] > 0 && link(reverse)["pdc"] < 0
        @test link(forward)["loss"] ≈ link(reverse)["loss"] atol = 1e-8
        @test forward["objective"]  ≈ reverse["objective"]  atol = 1e-6
        @test reverse["objective"]  ≈ listed["objective"]   atol = 1e-6

        # and it never delivers more than it took, which a loss charged to a
        # signed flow would do in exactly this direction
        @test link(reverse)["loss"] > 0
    end

    @testset "a one-way link stays shut rather than running against itself" begin
        # the cheap generator is on the far side, so the link would have to run
        # backwards to help; it may not, and the dear local generator serves
        one = quiet(() -> solve_opf(island_network(; cheap = 2, reverse = false),
                                    LPFFormulation, OPTIMIZER))
        @test link(one)["pdc"] ≈ 0.0 atol = 1e-7
        @test one["objective"] ≈ 100.0 atol = 1e-4

        both = quiet(() -> solve_opf(island_network(; cheap = 2), LPFFormulation, OPTIMIZER))
        @test both["objective"] ≈ 10.0 atol = 1e-4
    end

    @testset "the rating caps what an end may send, at either end" begin
        for cheap in (1, 2)
            result = quiet(() -> solve_opf(island_network(; cheap, rate = 0.4),
                                           LPFFormulation, OPTIMIZER))
            @test abs(link(result)["pdc"]) ≈ 0.4 atol = 1e-6
            # 0.4 comes across and the dear generator makes up the other 0.6
            @test result["objective"] ≈ 0.4 * 10.0 + 0.6 * 100.0 atol = 1e-4
        end

        # an unlimited two-way link writes no limit row at all
        loose = instantiate_model(island_network(), OptimalPowerFlowProblem, LPFFormulation)
        @test isempty(_NMB.con(loose, :dc_link_limits)[1])

        # a one-way link writes one even when it is unlimited: the cap that says
        # it may not send is a rating of zero, not a missing rating
        oneway = instantiate_model(island_network(; reverse = false),
                                   OptimalPowerFlowProblem, LPFFormulation)
        @test length(_NMB.con(oneway, :dc_link_limits)[1]) == 1
    end

    @testset "it decouples the nodes it joins" begin
        # both ends are reference nodes, which no branch could join: there is no
        # angle difference across a dc link to be limited, and no synchronism
        nm = instantiate_model(island_network(), OptimalPowerFlowProblem, LPFFormulation)

        @test length(reference_nodes(nm)) == 2
        @test !haskey(_NMB.con(nm), :linear_angle)
        @test !any(k -> k[2] === :linear_angle, keys(_NMB.registered_constraints(nm)))

        result = quiet(() -> solve_opf(island_network(), LPFFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
    end

    @testset "a load flow holds it at its schedule" begin
        data   = island_network(; pdc = 0.3, loss_prop = 0.05)
        result = quiet(() -> solve_model(data, LoadFlowProblem, LPFFormulation, OPTIMIZER))

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test link(result)["pdc"]  ≈ 0.3 atol = 1e-8
        @test link(result)["loss"] ≈ 0.05 * 0.3 atol = 1e-8
    end

    @testset "it has no model in an alternating current formulation" begin
        # a dc link couples to an ac network through a converter station, which
        # is a component in its own right; saying so is better than answering
        # with a link that has no reactive power
        err = try
            instantiate_model(island_network(), OptimalPowerFlowProblem, IVRFormulation)
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("DCLink", err.msg)
        @test occursin("converter station", err.msg)
        @test occursin("LPFFormulation", err.msg)
    end
end

################################################################################
# The dc link as a redispatch measure                                          #
################################################################################

"the dc link entry of a solution, which is edge 2 where a branch is edge 1"
dcl(result, n = 1) = nw_solution(result, n)["edge"]["2"]

"""
The radial network of `test/rd.jl` with a dc link in parallel with its branch:
the market ran generator 1 up to 1.0 behind a branch that carries 0.5, and the
link is a second way to get the rest of it across. `out` names the network
indices at which the branch is out of service.

Everything the topology depends on is given to the `Network` constructor rather
than written into it afterwards — a status changed after the fact leaves the
topology that was derived from it behind, and the outage silently does not
happen.
"""
function linked_network(; rate::Float64 = 1.0, cost::Float64 = 0.0, pdc::Float64 = 0.0,
                          loss_prop::Float64 = 0.0, dim::Dimension = Dimension(),
                          out = ())
    status = isempty(out) ? true : nw_vector(dim, (n, c) -> n ∉ out)

    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.0),
                               2 => Node(; id = 2))
    E = Dict{Int,AbstractEdge}(
        1 => Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.1, rate_a = 0.5,
                      status = status),
        2 => DCLink(; id = 2, terminals = [1, 2], rate_a = rate, cost, pdc, loss_prop))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       pg = 1.0, cost = [0.0, 10.0]),
        2 => Generator(; id = 2, node = 2, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       pg = 0.0, cost = [0.0, 100.0]),
        3 => FixedLoad(; id = 3, node = 2, pd = 1.0, qd = 0.0))

    return NetworkData(Network(I, E, U; dim); name = "linked", baseMVA = 100.0)
end

@testset "dc link as a redispatch measure" begin

    @testset "a free link relieves congestion for nothing" begin
        # the load needs 1.0, the branch may carry 0.5 of it and the link takes
        # the rest, so no generator has to move at all. How much *more* than the
        # rest the link takes is not pinned down: a free measure costs the same
        # whatever it does, so every split that keeps the branch inside its
        # rating is optimal, and only the parts that are asked of it are asserted
        result = quiet(() -> solve_rd(linked_network(), LPFFormulation, OPTIMIZER))

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test result["objective"] ≈ 0.0 atol = 1e-5
        @test nw_solution(result)["unit"]["1"]["pg"] ≈ 1.0 atol = 1e-6
        @test dcl(result, 1)["pdc"] ≥ 0.5 - 1e-6
        @test abs(nw_solution(result)["edge"]["1"]["terminal"]["1"]["p"]) ≤ 0.5 + 1e-6

        # it is a non-costly measure, so it carries no price at all
        nm = instantiate_model(linked_network(), RedispatchProblem, LPFFormulation)
        @test redispatch_cost(nm, DCLink, 2; nw = 1) == 0.0
    end

    @testset "a priced link is used only while it is worth it" begin
        # moving the link costs 40 a per unit; redispatching costs 110 a per
        # unit, so the link is still the cheaper way to move all 0.5
        priced = quiet(() -> solve_rd(linked_network(; cost = 40.0),
                                      LPFFormulation, OPTIMIZER))
        @test dcl(priced, 1)["pdc"] ≈ 0.5 atol = 1e-6
        @test priced["objective"] ≈ 0.5 * 40.0 atol = 1e-5

        # at 200 a per unit it is dearer than redispatching, so it stays put
        dear = quiet(() -> solve_rd(linked_network(; cost = 200.0),
                                    LPFFormulation, OPTIMIZER))
        @test dcl(dear, 1)["pdc"] ≈ 0.0 atol = 1e-6
        @test dear["objective"] ≈ 0.5 * 100.0 + 0.5 * 10.0 atol = 1e-5
    end

    @testset "what is priced is the move, not the transfer" begin
        # the link is already scheduled at 0.5, which is exactly what relieving
        # the congestion needs, so a costly link costs nothing here
        scheduled = quiet(() -> solve_rd(linked_network(; cost = 200.0, pdc = 0.5),
                                         LPFFormulation, OPTIMIZER))

        @test scheduled["objective"] ≈ 0.0 atol = 1e-5
        @test dcl(scheduled, 1)["pdc"]        ≈ 0.5 atol = 1e-6
        @test dcl(scheduled, 1)["pdc_market"] ≈ 0.5
        @test dcl(scheduled, 1)["pdcup"] ≈ 0.0 atol = 1e-6
        @test dcl(scheduled, 1)["pdcdn"] ≈ 0.0 atol = 1e-6
    end

    @testset "its rating is not congestion and cannot be priced away" begin
        # the link can only take 0.2, so 0.3 still has to be redispatched, and
        # an overload price that relaxes the branch does not reach the link
        rd     = Redispatch(; overload = 500.0)
        result = quiet(() -> solve_rd(linked_network(; rate = 0.2), LPFFormulation,
                                      OPTIMIZER; redispatch = rd))

        @test dcl(result, 1)["pdc"] ≈ 0.2 atol = 1e-6
        @test !haskey(dcl(result, 1), "overload")
        @test nw_solution(result)["edge"]["1"]["overload"] ≈ 0.0 atol = 1e-6
        @test result["objective"] ≈ 0.3 * 100.0 + 0.3 * 10.0 atol = 1e-5
    end

    @testset "a preventive link holds one transfer across the contingencies" begin
        nm = instantiate_model(linked_network(), RedispatchProblem, LPFFormulation)
        @test redispatch_controls(nm, DCLink) == (:pdcup, :pdcdn)

        # The branch is the contingency, so the link has to carry the whole load
        # in the second state. Price the link, or there is no reason to prefer
        # one setting to another and the two control modes are indistinguishable:
        # at 40 a per unit it is cheaper than the 110 redispatching costs, so a
        # corrective link takes 0.5 in the healthy state and 1.0 in the outaged
        # one, while a preventive link has to take 1.0 in both.
        dim  = Dimension(:contingency => 2)
        data = linked_network(; dim, cost = 40.0, out = (2,))

        preventive = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER))
        @test preventive["termination_status"] == JuMP.LOCALLY_SOLVED
        @test dcl(preventive, 1)["pdc"] ≈ dcl(preventive, 2)["pdc"] atol = 1e-6
        @test dcl(preventive, 1)["pdc"] ≈ 1.0 atol = 1e-5

        corrective = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER;
                                          redispatch = Redispatch(; control = :corrective)))
        @test dcl(corrective, 1)["pdc"] ≈ 0.5 atol = 1e-5
        @test dcl(corrective, 2)["pdc"] ≈ 1.0 atol = 1e-5

        # holding one setting for a contingency that may not happen is what a
        # preventive measure pays for
        @test corrective["objective"] < preventive["objective"] - 1e-6
    end

    @testset "it survives a roll on one model" begin
        dim  = Dimension(:time => 4)
        data = linked_network(; dim, cost = 40.0, loss_prop = 0.02)

        built = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER;
                                     horizon = 2, step = 1))
        @test built["termination_status"] == JuMP.LOCALLY_SOLVED

        reused = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2,
                                      step = 1, reuse = true, warm_start = true))
        @test reused["objective"] ≈ built["objective"] rtol = 1e-6
        for n in 1:4
            @test dcl(reused, n)["pdc"] ≈ dcl(built, n)["pdc"] atol = 1e-5
        end
        @test reused["horizon"]["built"] < built["horizon"]["built"]
    end
end
