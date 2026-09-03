################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.8.0 - the zorba adapter                                                   #
################################################################################

# The network below is the one Zorba's own `BaseTestCase.get_ref_minimal_study`
# builds, and the numbers asserted against are the ones its
# `test_redispatch_solver.py` asserts. That is the point of them: the adapter is
# not tested against what this package thinks the answer is, it is tested against
# what the implementation it replaces returns for the same study.
#
#            a ──── "a - b", 8 MW, x = 1, ±30° ──── b
#            │                                      │
#     "a - c", 11 MW, x = 2                  "b - c", 12 MW, x = 1
#            │                                      │
#            └──────────────── c ───────────────────┘

"the grid of Zorba's reference study"
ref_grid() = (id           = ["a - b", "b - c", "a - c"],
              from_node    = ["a", "b", "a"],
              to_node      = ["b", "c", "c"],
              capacity     = [8.0, 12.0, 11.0],
              reactance_pu = [1.0, 1.0, 2.0],
              pst_deg      = [30.0, 0.0, 0.0],
              could_trip   = [false, true, true])

"""
Its net positions over two hours, `scale` times over.

Zorba's tests triple them to force an overload; at their face value the study
fits inside every rating and is what a hard rating can be asked of.
"""
ref_net_position(; scale = 3.0) =
    (node     = ["a", "a", "b", "b", "c", "c"],
     time_id  = UInt16[0, 1, 0, 1, 0, 1],
     value_mw = scale .* [10.0, 10.0, 0.0, -10.0, -10.0, 0.0])

"the reference HVDC link, `a → c` at 10 €/MWh"
ref_hvdc() = (from_node = ["a"], to_node = ["c"], cost = [10.0])

"the flow of every link at `time_id` in state `outage`, in the order the grid gave them"
function flows(tbl, time_id, outage = missing)
    rows = [i for i in eachindex(tbl.Name)
            if tbl.time_id[i] == time_id && isequal(tbl.outage[i], outage)]

    return Float64.(tbl.flow_mw[rows])
end

"the overload of every link at `time_id` in state `outage`"
function overloads(tbl, time_id, outage = missing)
    rows = [i for i in eachindex(tbl.Name)
            if tbl.time_id[i] == time_id && isequal(tbl.outage[i], outage)]

    return Float64.(tbl.overload_mw[rows])
end

@testset "the zorba adapter" begin

    @testset "the study becomes the network it describes" begin
        data = parse_zorba(; grid = ref_grid(), net_position = ref_net_position())
        net  = network(data)

        # the nodes are numbered as `MinimalStudy.node_list` orders them, and the
        # first of them anchors the angle the way Zorba's slack does
        @test [node(net, i; nw = 1).name for i in 1:3] == ["a", "b", "c"]
        @test node(net, 1; nw = 1).type == REF
        @test node(net, 2; nw = 1).type == PQ

        # a link with a phase shift range is a control, one without is a branch
        @test edge(net, 1; nw = 1) isa PhaseShifter
        @test edge(net, 2; nw = 1) isa Branch
        @test edge(net, 3; nw = 1) isa Branch

        ps = edge(net, 1; nw = 1)::PhaseShifter
        @test ps.terminals == [1, 2]
        @test ps.x == 1.0
        @test ps.rate_a ≈ 8.0 / 100.0            # MW against a 100 MVA base
        @test ps.ta_min ≈ -deg2rad(30)
        @test ps.ta_max ≈  deg2rad(30)
        @test ps.cost == 1.0                     # `RdsSettings.pst_cost`

        # Zorba writes no angle difference limits, and ±π/2 is how this package
        # says there are none
        @test edge(net, 2; nw = 1).angmin == -pi / 2
        @test edge(net, 2; nw = 1).angmax ==  pi / 2

        # a node exports `value_mw`, and a load withdraws, so the sign turns over
        @test unit(net, 1; nw = 1) isa FixedLoad
        @test nw_value(dimension(data), unit(net, 1; nw = 1).pd, 1) ≈ -30.0 / 100.0
        @test nw_value(dimension(data), unit(net, 3; nw = 1).pd, 1) ≈  30.0 / 100.0

        # two hours and the base case, which is a state of the world like any other
        @test dim_length(data, :time) == 2
        @test dim_length(data, :contingency) == 1
        @test zorba_study(data).time_id == UInt16[0, 1]
        @test isequal(zorba_study(data).outage, [missing])
    end

    @testset "a phase shifter steers flow off the corridor" begin
        # `test_pst_flex`: with the net positions tripled the study cannot be
        # served without an overload, and the phase shifter picks which one
        data   = parse_zorba(; grid = ref_grid(), net_position = ref_net_position())
        result = quiet(() -> solve_zorba(data, OPTIMIZER))
        tables = zorba_tables(data, result)

        @test flows(tables.grid_flows, 0) ≈ [12.0, 12.0, 18.0] atol = 1e-4
        @test overloads(tables.grid_flows, 0) ≈ [4.0, 0.0, 7.0] atol = 1e-4

        # and it is worth having: without the range the split is 15 / 15
        flat = parse_zorba(; grid = merge(ref_grid(), (pst_deg = [0.0, 0.0, 0.0],)),
                             net_position = ref_net_position())
        none = zorba_tables(flat, quiet(() -> solve_zorba(flat, OPTIMIZER)))

        @test flows(none.grid_flows, 0) ≈ [15.0, 15.0, 15.0] atol = 1e-4
        @test sum(overloads(tables.grid_flows, 0)) < sum(overloads(none.grid_flows, 0))
    end

    @testset "an hvdc link is a scheduled injection, priced per MWh" begin
        # `test_with_hvdc`, whose answer is exactly on every rating
        data   = parse_zorba(; grid = ref_grid(), net_position = ref_net_position(),
                               hvdc = ref_hvdc(), overload_penalty = 1e3)
        net    = network(data)
        tables = zorba_tables(data, quiet(() -> solve_zorba(data, OPTIMIZER)))

        @test flows(tables.grid_flows, 0) ≈ [8.0, 8.0, 11.0, 11.0] atol = 1e-4
        @test all(overloads(tables.grid_flows, 0) .≈ 0.0)

        # the link is the fourth row, and it is reported under the name the
        # caller gave it rather than under the name of the branch beside it
        @test tables.grid_flows.Name[4] == "a - c"
        @test edge(net, 4; nw = 1) isa DCLink
        @test edge(net, 4; nw = 1).cost == 10.0 * 100.0
    end

    @testset "an outage is a change of topology" begin
        # `test_with_outages`
        outage = (name = ["a - c", "b - c"], link = ["a - c", "b - c"])
        data   = parse_zorba(; grid = ref_grid(), net_position = ref_net_position(),
                               hvdc = ref_hvdc(), outage, overload_penalty = 1e3)
        net    = network(data)
        tables = zorba_tables(data, quiet(() -> solve_zorba(data, OPTIMIZER)))

        @test flows(tables.grid_flows, 0)          ≈ [4.0, 4.0, 4.0, 22.0]  atol = 1e-4
        @test flows(tables.grid_flows, 0, "a - c") ≈ [8.0, 8.0, 0.0, 22.0]  atol = 1e-4
        @test flows(tables.grid_flows, 0, "b - c") ≈ [0.0, 0.0, 8.0, 22.0]  atol = 1e-4

        # the link an outage takes out is out of service, not merely at rest
        @test is_active(dimension(data), edge(net, 3; nw = 1), 1)
        @test !is_active(dimension(data), edge(net, 3; nw = 3), 3)
        @test 3 ∉ topology(net; nw = 3).edge

        # and it is still reported, at rest, which is what Zorba writes for it
        @test count(isequal("a - c"), tables.grid_flows.outage) == 8
    end

    @testset "the congestion is summed over the states and the measures charged once" begin
        outage = (name = ["a - c", "b - c"], link = ["a - c", "b - c"])
        data   = parse_zorba(; grid = ref_grid(), net_position = ref_net_position(),
                               hvdc = ref_hvdc(), outage, overload_penalty = 1e3,
                               pst_cost = 1.0)
        result = quiet(() -> solve_zorba(data, OPTIMIZER))
        tables = zorba_tables(data, result)
        gf, ps = tables.grid_flows, tables.pst_dispatch

        # Zorba's objective, written out: every overload of every state, every
        # radian of phase shift once, and every MWh the link moved once
        congestion = 1e3 * sum(gf.overload_mw)
        shift      = 1.0 * sum(deg2rad(abs(x)) for x in skipmissing(ps.pst_deg))
        transfer   = 10.0 * sum(abs(nw_solution(result, n)["edge"]["4"]["pdc"]) * 100.0
                                for n in nw_ids(data; contingency = 1))

        @test result["objective"] ≈ congestion + shift + transfer rtol = 1e-5

        # which is what the gross-up buys: three states, so an average of the
        # congestion priced at three times over is the sum of it priced at one
        @test zorba_study(data).redispatch.overload.per_energy ≈ 1e3 * 100.0 * 3

        # a caller who gives probabilities is asking the other question
        expected = parse_zorba(; grid = ref_grid(), net_position = ref_net_position(),
                                 outage, contingency_weight = [0.98, 0.01, 0.01])
        @test zorba_study(expected).redispatch.overload.per_energy ≈ 1e3 * 100.0
        @test dim_prop(dimension(expected), :contingency, 1, :weight) == 0.98
    end

    @testset "the wiggle room is a pair of slack units" begin
        data = parse_zorba(; grid = ref_grid(), net_position = ref_net_position(),
                             wiggle_room = 50.0)
        net  = network(data)

        ens   = [u for u in ids(net, EnergyNotServed; nw = 1)]
        spill = [u for u in ids(net, Spill; nw = 1)]
        @test length(ens) == 3 && length(spill) == 3

        # bounded, and free: Zorba charges nothing for missing the balance
        @test unit(net, first(ens); nw = 1).pmax ≈ 50.0 / 100.0
        @test unit(net, first(ens); nw = 1).cost == 0.0
        @test unit(net, first(spill); nw = 1).cost == 0.0

        # and it is used, since 50 MW of free relaxation is cheaper than the
        # congestion the study would otherwise pay for
        room = zorba_tables(data, quiet(() -> solve_zorba(data, OPTIMIZER)))
        bare = parse_zorba(; grid = ref_grid(), net_position = ref_net_position())
        none = zorba_tables(bare, quiet(() -> solve_zorba(bare, OPTIMIZER)))

        @test sum(room.grid_flows.overload_mw) < sum(none.grid_flows.overload_mw)
    end

    @testset "`force` is a hard rating rather than a price" begin
        # at their face value the net positions fit, so the ratings can be held
        data = parse_zorba(; grid = ref_grid(), net_position = ref_net_position(; scale = 1.0),
                             overload_penalty = :force)

        @test zorba_study(data).redispatch.overload === nothing

        tables = zorba_tables(data, quiet(() -> solve_zorba(data, OPTIMIZER)))
        @test all(abs.(tables.grid_flows.flow_mw) .<= [8.0, 12.0, 11.0, 8.0, 12.0, 11.0] .+ 1e-4)

        # nothing was relaxed, so nothing is reported as relaxed
        @test all(tables.grid_flows.overload_mw .== 0.0f0)
    end

    @testset "a blank capacity is an unlimited one" begin
        grid = merge(ref_grid(), (capacity = [8.0, missing, 11.0],))
        data = parse_zorba(; grid, net_position = ref_net_position())

        @test edge(network(data), 2; nw = 1).rate_a == Inf

        # an edge with no rating has no overload to report, and reports zero
        # rather than dropping the row
        tables = zorba_tables(data, quiet(() -> solve_zorba(data, OPTIMIZER)))
        @test overloads(tables.grid_flows, 0)[2] == 0.0f0
    end

    @testset "the phase shift is reported in Zorba's sign" begin
        data   = parse_zorba(; grid = ref_grid(), net_position = ref_net_position())
        nm     = instantiate_model(data, RedispatchProblem, LPFFormulation;
                                   ext = Dict{Symbol,Any}(
                                       :redispatch => zorba_study(data).redispatch))
        result = quiet(() -> optimize_model!(nm, OPTIMIZER))
        tables = zorba_tables(data, result)

        # this package writes `p = -b(θi - θj - ta)` and Zorba `P = (θi - θj + s)B`,
        # so the two differ by a sign and the adapter is where it is applied
        ta = nw_solution(result, 1)["edge"]["1"]["tap"]["ta"]
        @test tables.pst_dispatch.pst_deg[1] ≈ -rad2deg(ta)
        @test !iszero(ta)

        # a link without a phase shifter has no setting rather than a zero one
        @test ismissing(tables.pst_dispatch.pst_deg[2])
        @test ismissing(tables.pst_dispatch.pst_deg[3])

        # and there is no outage column: a phase shifter is preventive
        @test !haskey(tables.pst_dispatch, :outage)
        @test length(tables.pst_dispatch.Name) == 6
    end

    @testset "the tables carry the types the schemas declare" begin
        outage = (name = ["a - c"], link = ["a - c"])
        data   = parse_zorba(; grid = ref_grid(), net_position = ref_net_position(),
                               hvdc = ref_hvdc(), outage)
        tables = zorba_tables(data, quiet(() -> solve_zorba(data, OPTIMIZER)))
        gf, ps = tables.grid_flows, tables.pst_dispatch

        @test keys(gf) == (:outage, :Name, :from_node, :to_node, :time_id,
                           :flow_mw, :overload_mw)
        @test eltype(gf.outage)      == Union{Missing,String}
        @test eltype(gf.Name)        == String
        @test eltype(gf.time_id)     == UInt16
        @test eltype(gf.flow_mw)     == Float32
        @test eltype(gf.overload_mw) == Float32
        @test all(gf.overload_mw .>= 0.0f0)

        @test keys(ps) == (:Name, :from_node, :to_node, :time_id, :pst_deg)
        @test eltype(ps.pst_deg) == Union{Missing,Float32}
        @test all(-180 .<= skipmissing(ps.pst_deg) .<= 180)

        # one row per link, step and state of the world, the hvdc included
        @test length(gf.Name) == 4 * 2 * 2
        @test all(gf.from_node .!= gf.to_node)
    end

    @testset "what it refuses" begin
        grid, nps = ref_grid(), ref_net_position()

        # a link hanging off a node the net positions do not have
        @test_throws ArgumentError parse_zorba(;
            grid = merge(grid, (to_node = ["b", "c", "d"],)), net_position = nps)

        # a node missing a step, which is a filter far more often than a statement
        short = (node = ["a", "a", "b", "c", "c"], time_id = UInt16[0, 1, 0, 0, 1],
                 value_mw = [10.0, 10.0, 0.0, -10.0, -10.0])
        @test_throws ArgumentError parse_zorba(; grid, net_position = short)

        # or given one twice
        twice = (node = ["a", "a", "b", "b", "c", "c"], time_id = UInt16[0, 0, 0, 1, 0, 1],
                 value_mw = [10.0, 1.0, 0.0, -10.0, -10.0, 0.0])
        @test_throws ArgumentError parse_zorba(; grid, net_position = twice)

        # an outage of a link the grid does not have
        @test_throws ArgumentError parse_zorba(; grid, net_position = nps,
                                                 outage = (name = ["x"], link = ["x"]))

        # a phase shift range no ratio angle can hold
        @test_throws ArgumentError parse_zorba(;
            grid = merge(grid, (pst_deg = [95.0, 0.0, 0.0],)), net_position = nps)

        # a price that is neither a number nor a hard rating
        @test_throws ArgumentError parse_zorba(; grid, net_position = nps,
                                                 overload_penalty = :hard)

        # weights that do not cover the states of the world
        @test_throws ArgumentError parse_zorba(; grid, net_position = nps,
                                                 contingency_weight = [0.5, 0.5])

        # a table that is missing a column altogether
        @test_throws ArgumentError parse_zorba(; grid = (id = ["a - b"],),
                                                 net_position = nps)
        @test_throws ArgumentError parse_zorba(; grid, net_position = (node = ["a"],))

        # and a network nobody built from a Zorba study has nothing to write back
        @test_throws ArgumentError zorba_study(parse_file(case("case5")))
    end

    @testset "a study is read from and written back to arrow" begin
        dir = mktempdir()
        Arrow.write(joinpath(dir, "grid.arrow"), ref_grid())
        Arrow.write(joinpath(dir, "net_position.arrow"), ref_net_position())
        Arrow.write(joinpath(dir, "hvdc.arrow"), ref_hvdc())
        Arrow.write(joinpath(dir, "outage.arrow"), (name = ["a - c"], link = ["a - c"]))

        data = parse_zorba(dir; overload_penalty = 1e3)
        @test data.name == basename(dir)
        @test length(zorba_study(data).link) == 4
        @test dim_length(data, :contingency) == 2

        # the files describe the same study the keywords do, and answer it the same
        memory = parse_zorba(; grid = ref_grid(), net_position = ref_net_position(),
                               hvdc = ref_hvdc(),
                               outage = (name = ["a - c"], link = ["a - c"]),
                               overload_penalty = 1e3)
        tables = zorba_tables(data, quiet(() -> solve_zorba(data, OPTIMIZER)))
        same   = zorba_tables(memory, quiet(() -> solve_zorba(memory, OPTIMIZER)))
        @test tables.grid_flows.flow_mw ≈ same.grid_flows.flow_mw atol = 1e-4
        @test isequal(tables.grid_flows.outage, same.grid_flows.outage)

        out = write_zorba(joinpath(dir, "out"), tables)
        @test length(out) == 2
        @test isfile(joinpath(dir, "out", "grid_flows.arrow"))
        @test isfile(joinpath(dir, "out", "pst_dispatch.arrow"))

        back = Arrow.Table(joinpath(dir, "out", "grid_flows.arrow"))
        @test collect(propertynames(back)) == [:outage, :Name, :from_node, :to_node,
                                               :time_id, :flow_mw, :overload_mw]
        @test eltype(back.time_id) == UInt16
        @test eltype(back.flow_mw) == Float32
        @test collect(back.flow_mw) == tables.grid_flows.flow_mw
        @test ismissing(back.outage[1])

        # a directory that is not one, and one that is missing a table
        @test_throws ArgumentError parse_zorba(joinpath(dir, "grid.arrow"))
        @test_throws ArgumentError parse_zorba(mktempdir())
    end

    @testset "a study is a network, and any problem can be asked of it" begin
        # at face value, so the ratings hold without being priced
        data = parse_zorba(; grid = ref_grid(),
                             net_position = ref_net_position(; scale = 1.0))

        opf = quiet(() -> solve_zorba(data, OptimalPowerFlowProblem, LPFFormulation,
                                      OPTIMIZER))
        @test opf["problem_type"] == OptimalPowerFlowProblem
        @test opf["termination_status"] == JuMP.LOCALLY_SOLVED

        # the same tables, from a problem that is not the one Zorba poses
        tables = zorba_tables(data, opf)
        @test length(tables.grid_flows.Name) == 3 * 2
        @test all(abs.(flows(tables.grid_flows, 0)) .<= [8.0, 12.0, 11.0] .+ 1e-4)

        # nothing priced the congestion here, so nothing reports one — which is
        # the true answer to a question that never allowed an overload
        @test all(tables.grid_flows.overload_mw .== 0.0f0)
        @test !ismissing(tables.pst_dispatch.pst_deg[1])

        # the redispatch setup rides along whatever the problem is, and is inert
        # in every problem but the one that reads it
        nm = instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation;
                               ext = Dict{Symbol,Any}(
                                   :redispatch => zorba_study(data).redispatch))
        @test overload_price(nm) === nothing
        @test is_monitored(nm, 1)

        # the current based formulation asks the same grid a different question,
        # and the two things it cannot be asked say so rather than answering
        priced = try
            solve_zorba(data, RedispatchProblem, IVRFormulation, OPTIMIZER)
        catch e
            e
        end
        @test priced isa ErrorException
        @test occursin("priced phase shifter", priced.msg)

        link = parse_zorba(; grid = ref_grid(), pst_cost = 0.0, hvdc = ref_hvdc(),
                             net_position = ref_net_position(; scale = 1.0))
        dc = try
            solve_zorba(link, RedispatchProblem, IVRFormulation, OPTIMIZER)
        catch e
            e
        end
        @test dc isa ErrorException
        @test occursin("DCLink", dc.msg)

        # and one that can be: unpriced, without a link, the model is built
        ac = parse_zorba(; grid = ref_grid(), pst_cost = 0.0,
                           net_position = ref_net_position(; scale = 1.0))
        @test instantiate_model(ac, RedispatchProblem, IVRFormulation;
                                ext = Dict{Symbol,Any}(
                                    :redispatch => zorba_study(ac).redispatch)) isa
              NetworkModel
    end

    @testset "a study rolls the way Zorba batches one" begin
        data = parse_zorba(; grid = ref_grid(), net_position = ref_net_position())

        one  = zorba_tables(data, quiet(() -> solve_zorba(data, OPTIMIZER)))
        roll = zorba_tables(data, quiet(() -> solve_zorba(data, OPTIMIZER;
                                                          horizon = 1, step = 1,
                                                          reuse = true)))

        # the study is two independent hours, so a window of one sees everything
        # a window of two does
        @test roll.grid_flows.flow_mw ≈ one.grid_flows.flow_mw atol = 1e-3
    end

end
