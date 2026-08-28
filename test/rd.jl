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

# Every network below is built so that the answer can be worked out by hand. The
# linearized formulation is lossless, so what leaves a generator arrives at the
# load and the redispatch volumes are exact rather than approximate.

"a two-node radial network whose single branch cannot carry the market dispatch"
function radial_network(; dim::Dimension = Dimension(), rate::Float64 = 0.5,
                          pd = 1.0, pg_market = 1.0,
                          extra::Dict{Int,AbstractUnit} = Dict{Int,AbstractUnit}())
    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.0),
                               2 => Node(; id = 2))
    E = Dict{Int,AbstractEdge}(
        1 => Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.1, rate_a = rate))
    U = Dict{Int,AbstractUnit}(
        # the cheap generator the market ran up, far from the load
        1 => Generator(; id = 1, node = 1, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       pg = pg_market, cost = [0.0, 10.0]),
        # the expensive one behind the constraint
        2 => Generator(; id = 2, node = 2, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       pg = 0.0, cost = [0.0, 100.0]),
        3 => FixedLoad(; id = 3, node = 2, pd = pd, qd = 0.0))
    merge!(U, extra)

    return NetworkData(Network(I, E, U; dim); name = "radial", baseMVA = 100.0)
end

"""
A three-node meshed network: a tight direct corridor `1–3` in parallel with a
path `1–2–3` carrying a phase shifter, which can steer flow off the corridor at
no cost. Edge 3 is what a contingency takes out.
"""
function meshed_network(; dim::Dimension = Dimension(), rate::Float64 = 0.5,
                          shift::Bool = true, out = ())
    ps_limit = shift ? 0.3 : 0.0
    status   = isempty(out) ? true : nw_vector(dim, (n, c) -> n ∉ out)

    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.0),
                               2 => Node(; id = 2), 3 => Node(; id = 3))
    E = Dict{Int,AbstractEdge}(
        1 => Branch(; id = 1, terminals = [1, 3], r = 0.0, x = 0.1, rate_a = rate),
        2 => PhaseShifter(; id = 2, terminals = [1, 2], r = 0.0, x = 0.1,
                          ta_min = -ps_limit, ta_max = ps_limit),
        3 => Branch(; id = 3, terminals = [2, 3], r = 0.0, x = 0.1, status = status))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       pg = 1.0, cost = [0.0, 10.0]),
        2 => Generator(; id = 2, node = 3, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       pg = 0.0, cost = [0.0, 100.0]),
        3 => FixedLoad(; id = 3, node = 3, pd = 1.0, qd = 0.0))

    return NetworkData(Network(I, E, U; dim); name = "meshed", baseMVA = 100.0)
end

"the redispatch volumes of every generator of a solution at network index `n`"
volumes(result, n = 1) = Dict(u => (nw_solution(result, n)["unit"]["$u"]["pgup"],
                                    nw_solution(result, n)["unit"]["$u"]["pgdn"])
                              for u in ("1", "2"))

@testset "redispatch" begin

    @testset "the problem is registered in both formulations" begin
        @test (RedispatchProblem, IVRFormulation) in implemented_models()
        @test (RedispatchProblem, LPFFormulation) in implemented_models()

        # and only in those two
        err = try
            instantiate_model(radial_network(), RedispatchProblem, ACPFormulation)
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("RedispatchProblem with IVRFormulation", err.msg)
    end

    @testset "the market dispatch is the setpoint the component carries" begin
        nm = instantiate_model(radial_network(), RedispatchProblem, LPFFormulation)

        # pg splits into the setpoint plus what was moved, and nothing else
        @test haskey(_NMB.var(nm), :pgup)
        @test haskey(_NMB.var(nm), :pgdn)
        @test haskey(_NMB.con(nm), :generator_redispatch)
        @test JuMP.lower_bound(_NMB.var(nm, :pgup, 1)) == 0.0
        @test JuMP.lower_bound(_NMB.var(nm, :pgdn, 1)) == 0.0

        # the headroom left in each direction bounds the volumes
        @test JuMP.upper_bound(_NMB.var(nm, :pgup, 1)) ≈ 5.0 - 1.0   # pmax - pg
        @test JuMP.upper_bound(_NMB.var(nm, :pgdn, 1)) ≈ 1.0 - 0.0   # pg - pmin
    end

    @testset "a feasible market dispatch is not redispatched" begin
        # the branch carries the dispatch, so there is nothing to relieve
        data   = radial_network(; rate = 2.0)
        result = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER))

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test result["objective"] ≈ 0.0 atol = 1e-5
        @test nw_solution(result)["unit"]["1"]["pg"] ≈ 1.0 atol = 1e-5
        @test nw_solution(result)["unit"]["1"]["pg_market"] ≈ 1.0
    end

    @testset "congestion is relieved at the price of the volumes moved" begin
        data   = radial_network(; rate = 0.5)
        result = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER))

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED

        # 0.5 has to come from behind the constraint instead of in front of it
        up, dn = volumes(result)["2"], volumes(result)["1"]
        @test up[1] ≈ 0.5 atol = 1e-6                 # generator 2 up by 0.5
        @test dn[2] ≈ 0.5 atol = 1e-6                 # generator 1 down by 0.5

        # priced at each generator's own marginal cost, the default
        @test result["objective"] ≈ 0.5 * 100.0 + 0.5 * 10.0 atol = 1e-5

        # and the branch is at its rating rather than beyond it
        @test abs(nw_solution(result)["edge"]["1"]["terminal"]["1"]["p"]) ≤ 0.5 + 1e-6

        # the volumes net out: the load did not change and the model is lossless
        @test sum(nw_solution(result)["unit"]["$u"]["pgup"] -
                  nw_solution(result)["unit"]["$u"]["pgdn"] for u in 1:2) ≈ 0.0 atol = 1e-6
    end

    @testset "an explicit price is used where it is given" begin
        # generator 2 bids 40 upward instead of the 100 its cost curve implies
        data = radial_network()
        net  = network(data)
        g    = units(net)[2]::Generator
        units(net)[2] = Generator(; id = g.id, node = g.node, pg = g.pg, pmax = g.pmax,
                                  qmin = g.qmin, qmax = g.qmax, cost = g.cost,
                                  cost_up = 40.0, cost_dn = 5.0)

        @test redispatch_price(units(net)[2]) == (40.0, 5.0)
        @test redispatch_price(units(net)[1]) == (10.0, 10.0)   # the cost curve stands in
        @test marginal_cost(units(net)[1], 0.0) ≈ 10.0

        result = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER))
        @test result["objective"] ≈ 0.5 * 40.0 + 0.5 * 10.0 atol = 1e-5
    end

    @testset "only the monitored edges are watched" begin
        data = radial_network(; rate = 0.5)

        # watching nothing leaves the market dispatch alone
        none = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER;
                                    redispatch = Redispatch(; monitored = Int[])))
        @test none["objective"] ≈ 0.0 atol = 1e-5
        @test nw_solution(none)["unit"]["1"]["pg"] ≈ 1.0 atol = 1e-5

        # watching the one edge that is congested is the same as watching them all
        one = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER;
                                   redispatch = Redispatch(; monitored = [1])))
        all = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER))
        @test one["objective"] ≈ all["objective"] atol = 1e-6

        nm = instantiate_model(data, RedispatchProblem, LPFFormulation;
                               ext = Dict{Symbol,Any}(:redispatch => Redispatch(; monitored = Int[])))
        @test !is_monitored(nm, 1)
        @test isempty(monitored_edges(nm))
        rating, angle = _NMB.con(nm, :edge_limits)[1]
        @test rating === nothing          # the congestion limit is gone
        @test angle !== nothing           # the angle difference limit is not

        # an optimal power flow watches everything, whatever the setup says
        opf = instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation;
                                ext = Dict{Symbol,Any}(:redispatch => Redispatch(; monitored = Int[])))
        @test is_monitored(opf, 1)
        @test monitored_edges(opf) == [1]
    end

    @testset "a phase shifter relieves congestion for free" begin
        # the flow splits two thirds over the direct corridor, which is rated 0.5
        with = quiet(() -> solve_rd(meshed_network(; shift = true),
                                    LPFFormulation, OPTIMIZER))
        @test with["termination_status"] == JuMP.LOCALLY_SOLVED
        @test with["objective"] ≈ 0.0 atol = 1e-5
        @test abs(nw_solution(with)["edge"]["1"]["terminal"]["1"]["p"]) ≤ 0.5 + 1e-6

        # the shifter moved, and it steered flow onto the parallel path. Which
        # angle it settled on is not determined: every setting that brings the
        # corridor under 0.5 costs the same nothing, so the solver returns one of
        # them, and `-0.05` — the setting that just clears the rating — is only
        # the mildest of those.
        @test nw_solution(with)["edge"]["2"]["tap"]["ta"] < -1e-3
        @test abs(nw_solution(with)["edge"]["3"]["terminal"]["1"]["p"]) > 0.5 - 1e-6

        # take the control away and the same congestion has to be paid for
        without = quiet(() -> solve_rd(meshed_network(; shift = false),
                                       LPFFormulation, OPTIMIZER))
        @test without["objective"] > 1.0
    end

    @testset "a storage unit is a measure over the time window" begin
        dim     = Dimension(:time => 2)
        battery = Storage(; id = 4, node = 2, energy_capacity = 0.5, energy_initial = 0.25,
                          charge_rating = 0.5, discharge_rating = 0.5,
                          charge_efficiency = 1.0, discharge_efficiency = 1.0)
        data = radial_network(; dim, extra = Dict{Int,AbstractUnit}(4 => battery))

        result = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED

        # the corridor caps generator 1 at 0.5 in both steps, so it comes down by
        # 1.0 over the window. Behind the constraint the battery gives the 0.25
        # it holds for free and the expensive generator supplies the other 0.75.
        #
        # Only the *net* volume of the battery is determined: both its prices are
        # zero, so nothing stops the solver from adding the same amount to the
        # upward and the downward volume, and it does.
        moved = sum(nw_solution(result, n)["unit"]["4"]["psup"] -
                    nw_solution(result, n)["unit"]["4"]["psdn"] for n in 1:2)
        @test moved ≈ 0.25 atol = 1e-5
        @test sum(nw_solution(result, n)["unit"]["2"]["pgup"] for n in 1:2) ≈ 0.75 atol = 1e-5
        @test sum(nw_solution(result, n)["unit"]["1"]["pgdn"] for n in 1:2) ≈ 1.0 atol = 1e-5
        @test result["objective"] ≈ 0.75 * 100.0 + 1.0 * 10.0 atol = 1e-4

        # the market schedule of a storage unit is its setpoint too
        @test nw_solution(result)["unit"]["4"]["ps_market"] == 0.0

        # price the battery above the generator and it stays where the market put it
        dear = Storage(; id = 4, node = 2, energy_capacity = 0.5, energy_initial = 0.25,
                       charge_rating = 0.5, discharge_rating = 0.5,
                       charge_efficiency = 1.0, discharge_efficiency = 1.0,
                       cost_up = 500.0, cost_dn = 500.0)
        idle = quiet(() -> solve_rd(radial_network(; dim, extra = Dict{Int,AbstractUnit}(4 => dear)),
                                    LPFFormulation, OPTIMIZER))
        @test sum(nw_solution(idle, n)["unit"]["4"]["psup"] for n in 1:2) ≈ 0.0 atol = 1e-5
        @test idle["objective"] ≈ 1.0 * 100.0 + 1.0 * 10.0 atol = 1e-3
    end

    @testset "a preventive measure serves every contingency" begin
        # contingency 2 takes the parallel path out, and everything has to go
        # over the corridor the phase shifter can no longer relieve
        dim  = Dimension(:contingency => 2)
        data = meshed_network(; dim, out = (2,))

        preventive = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER))
        corrective = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER;
                                          redispatch = Redispatch(; control = :corrective)))

        @test preventive["termination_status"] == JuMP.LOCALLY_SOLVED
        @test corrective["termination_status"] == JuMP.LOCALLY_SOLVED

        # a corrective measure is only ever applied in the state it belongs to,
        # so it never costs more than one that has to serve both
        @test corrective["objective"] < preventive["objective"] - 1e-6

        # under a preventive setup the volumes are the same in both states
        for u in ("1", "2"), key in ("pgup", "pgdn")
            @test nw_solution(preventive, 1)["unit"][u][key] ≈
                  nw_solution(preventive, 2)["unit"][u][key] atol = 1e-6
        end

        # and under a corrective one the base case is left alone
        @test nw_solution(corrective, 1)["unit"]["2"]["pgup"] ≈ 0.0 atol = 1e-6
        @test nw_solution(corrective, 2)["unit"]["2"]["pgup"] > 1e-3
    end

    @testset "the control mode is per component" begin
        dim  = Dimension(:contingency => 2)
        data = meshed_network(; dim, out = (2,))
        rd   = Redispatch(; control = :corrective,
                            exception = Dict((:unit, 1) => :preventive))

        nm = instantiate_model(data, RedispatchProblem, LPFFormulation;
                               ext = Dict{Symbol,Any}(:redispatch => rd))

        @test control_mode(nm, :unit, 1) === :preventive
        @test control_mode(nm, :unit, 2) === :corrective
        @test is_preventive(nm, :unit, 1)
        @test is_corrective(nm, :unit, 2)

        # generator 1 is tied across the states, generator 2 is not
        tied = nm.ext[:redispatch_control]
        @test haskey(tied, (:unit, 1, :pgup, 2))
        @test !haskey(tied, (:unit, 2, :pgup, 2))

        result = quiet(() -> optimize_model!(nm, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test nw_solution(result, 1)["unit"]["1"]["pgdn"] ≈
              nw_solution(result, 2)["unit"]["1"]["pgdn"] atol = 1e-6
    end

    @testset "the objective is an expectation over the contingencies" begin
        rd   = Redispatch(; control = :corrective)
        one  = meshed_network(; out = ())                       # no contingencies at all
        data = meshed_network(; dim = Dimension(:contingency => 4), out = (2, 3, 4))

        # a contingency coordinate weighs 1/N unless the data says otherwise, so
        # the states are equally likely and their weights add up to one
        nm = instantiate_model(data, RedispatchProblem, LPFFormulation)
        @test default_weight(dimension(nm), :contingency) ≈ 0.25
        @test all(network_weight(nm, n) ≈ 0.25 for n in nw_ids(nm))
        @test sum(network_weight(nm, n) for n in nw_ids(nm)) ≈ 1.0

        # three of the four states are the outaged one, so a corrective measure
        # costs three quarters of what it costs in a single outaged network
        outaged = quiet(() -> solve_rd(meshed_network(; dim = Dimension(:contingency => 2),
                                                        out = (1, 2)),
                                       LPFFormulation, OPTIMIZER; redispatch = rd))
        spread  = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; redispatch = rd))
        @test spread["objective"] ≈ 0.75 * outaged["objective"] atol = 1e-4

        # and a `:time` dimension is untouched by any of this
        hours = instantiate_model(meshed_network(; dim = Dimension(:time => 3)),
                                  RedispatchProblem, LPFFormulation)
        @test default_weight(dimension(hours), :time) == 1.0
        @test all(network_weight(hours, n) == 1.0 for n in nw_ids(hours))
    end

    @testset "an explicit weight overrides the default" begin
        dim  = Dimension(:contingency => [Dict{Symbol,Any}(:weight => w) for w in (0.9, 0.1)])
        data = meshed_network(; dim, out = (2,))
        rd   = Redispatch(; control = :corrective)

        weighted = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; redispatch = rd))
        flat     = quiet(() -> solve_rd(meshed_network(; dim = Dimension(:contingency => 2),
                                                         out = (2,)),
                                        LPFFormulation, OPTIMIZER; redispatch = rd))

        # only the outaged state is redispatched: 0.1 against the 0.5 it defaults to
        @test weighted["objective"] ≈ (0.1 / 0.5) * flat["objective"] atol = 1e-5
    end

    @testset "the controls a preventive measure holds" begin
        ivr = instantiate_model(meshed_network(), RedispatchProblem, IVRFormulation)
        lpf = instantiate_model(meshed_network(), RedispatchProblem, LPFFormulation)

        @test redispatch_controls(ivr, Generator) == (:pgup, :pgdn)
        @test redispatch_controls(lpf, Generator) == (:pgup, :pgdn)
        @test redispatch_controls(ivr, Storage) == (:psc, :psd, :psup, :psdn)

        # the ratio is carried differently in the two formulations
        @test redispatch_controls(ivr, PhaseShifter) == (:tr, :ti)
        @test redispatch_controls(lpf, PhaseShifter) == (:ta,)

        # a tap changer is a control in the current based formulation and inert
        # in the linearized one, so it holds nothing there
        @test redispatch_controls(ivr, TapChanger) == (:tm,)
        @test redispatch_controls(lpf, TapChanger) == ()

        # a load is no measure at all
        @test redispatch_controls(lpf, FixedLoad) == ()
        @test redispatch_cost(lpf, FixedLoad, 3; nw = 1) == 0.0
    end

    @testset "the linearized redispatch is a linear program" begin
        nm = instantiate_model(radial_network(), RedispatchProblem, LPFFormulation)

        # the cost polynomial has left the objective, so nothing raises its degree
        @test all(T <: Union{JuMP.AffExpr,JuMP.VariableRef}
                  for (T, S) in JuMP.list_of_constraint_types(nm.model))
        @test JuMP.objective_function_type(nm.model) == JuMP.AffExpr

        # the cost polynomial is what makes the optimal power flow on case14 a
        # quadratic program; a redispatch on the same case stays linear, since
        # that polynomial only ever reaches its objective as a price
        opf = quiet(() -> instantiate_model(case("case14"), OptimalPowerFlowProblem, LPFFormulation))
        rd  = quiet(() -> instantiate_model(case("case14"), RedispatchProblem, LPFFormulation))
        @test JuMP.objective_function_type(opf.model) == JuMP.QuadExpr
        @test JuMP.objective_function_type(rd.model) == JuMP.AffExpr
    end

    @testset "a preventive phase shifter holds one setting" begin
        dim  = Dimension(:contingency => 2)
        data = meshed_network(; dim, out = (2,))

        nm = instantiate_model(data, RedispatchProblem, LPFFormulation)
        @test haskey(nm.ext[:redispatch_control], (:edge, 2, :ta, 2))

        result = quiet(() -> optimize_model!(nm, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test nw_solution(result, 1)["edge"]["2"]["tap"]["ta"] ≈
              nw_solution(result, 2)["edge"]["2"]["tap"]["ta"] atol = 1e-6

        # left corrective it may steer differently in each state
        free = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER;
                                    redispatch = Redispatch(; control = :corrective)))
        @test isempty(instantiate_model(data, RedispatchProblem, LPFFormulation;
                          ext = Dict{Symbol,Any}(:redispatch =>
                              Redispatch(; control = :corrective))).ext[:redispatch_control])
        @test free["objective"] ≤ result["objective"] + 1e-6
    end

    @testset "the current based formulation asks the same question" begin
        data   = radial_network(; rate = 0.5)
        result = quiet(() -> solve_rd(data, IVRFormulation, OPTIMIZER))

        @test result["termination_status"] == JuMP.LOCALLY_SOLVED

        # the same measure, up to the losses the linearized model discards
        @test nw_solution(result)["unit"]["2"]["pgup"] > 0.4
        @test nw_solution(result)["unit"]["1"]["pgdn"] > 0.4
        @test result["objective"] > 0.0

        # the rating is a limit on apparent power here, so it binds too
        s = hypot(nw_solution(result)["edge"]["1"]["terminal"]["1"]["p"],
                  nw_solution(result)["edge"]["1"]["terminal"]["1"]["q"])
        @test s ≤ 0.5 + 1e-5
    end

    @testset "a redispatch on case5 relieves what an unlimited market ignored" begin
        data = quiet(() -> parse_file(case("case5")))

        # watching no edge asks only for a dispatch that balances: the setpoints
        # of a Matpower case do not add up to its load on their own
        market = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER;
                                      redispatch = Redispatch(; monitored = Int[])))
        @test market["termination_status"] == JuMP.LOCALLY_SOLVED
        @test market["objective"] > 0.0

        # and it leaves the network congested, which is the point of the exercise
        @test any(abs(nw_solution(market)["edge"]["$e"]["terminal"]["1"]["p"]) >
                  edge(network(data), e).rate_a + 1e-5
                  for e in ids(network(data), AbstractEdge))

        # watching them all costs more, and every rating holds afterwards
        result = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test result["objective"] > market["objective"] + 1e-6
        for e in ids(network(data), AbstractEdge)
            rate = edge(network(data), e).rate_a
            for t in keys(nw_solution(result)["edge"]["$e"]["terminal"])
                @test abs(nw_solution(result)["edge"]["$e"]["terminal"][t]["p"]) ≤ rate + 1e-5
            end
        end
    end

    @testset "the setup validates what it is given" begin
        @test_throws ArgumentError Redispatch(; control = :curative)
        @test_throws ArgumentError Redispatch(; exception = Dict((:unit, 1) => :curative))
        @test_throws ArgumentError Redispatch(; exception = Dict((:widget, 1) => :preventive))

        rd = Redispatch(; monitored = [7, 3, 3])
        @test rd.monitored == [3, 7]                    # sorted and deduplicated
        @test rd.control === :preventive
        @test occursin("2 edge(s) monitored", sprint(show, rd))
        @test occursin("every edge monitored", sprint(show, Redispatch()))
    end
end

################################################################################
# The rolling horizon                                                          #
################################################################################

# The network below is the radial one above over a horizon, with a battery
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

    @testset "when two network indices give the same model" begin
        data = rolling_network()
        net  = network(data)

        # nothing switches and no gate varies, so one shape serves the year
        @test !structure_varies(data)
        @test all(same_structure(data, 1, n) for n in 2:4)
        @test all(same_topology(data, 1, n) for n in 2:4)

        # and `topology` proves it by handing back the very same object
        @test topology(net; nw = 1) === topology(net; nw = 4)
        @test length(topologies(net)) == 1

        # the gates are the fields the model asks a question of before writing
        @test structure_gates(edges(net)[1]) == (:rate_a, :angmin, :angmax)
        @test structure_gates(units(net)[1]) == (:pmin, :pmax, :qmin, :qmax)
        @test structure_gates(units(net)[3]) == ()          # a fixed load has none
        @test structure_gates(units(net)[4]) == ()          # nor a storage unit
    end

    @testset "an outage is a change of topology" begin
        dim  = Dimension(:time => 4)
        data = rolling_network()
        net  = network(data)
        net.edge[1] = Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.1, rate_a = 0.5,
                             status = nw_vector(dim, (n, c) -> n != 3))
        data = NetworkData(Network(net.node, net.edge, net.unit; dim))

        @test structure_varies(data)
        @test same_structure(data, 1, 2)
        @test !same_topology(data, 2, 3)
        @test !same_structure(data, 2, 3)
        @test same_structure(data, 2, 4)                    # in service at both
    end

    @testset "a gate changes the model without touching the topology" begin
        # the branch is in service throughout — only its rating moves, and only
        # across the boundary between finite and unlimited
        dim  = Dimension(:time => 3)
        net  = network(rolling_network())
        net.edge[1] = Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.1,
                             rate_a = nw_vector(dim, [0.5, 0.9, Inf]))
        data = NetworkData(Network(net.node, net.edge, net.unit; dim))

        # the topology cannot tell the difference: nothing went out of service
        @test isempty(switchable(network(data)))
        @test all(same_topology(data, 1, n) for n in 2:3)

        # but the model does, and `same_structure` is what catches it
        @test structure_varies(data)
        @test same_structure(data, 1, 2)                    # 0.5 and 0.9 both bound
        @test !same_structure(data, 1, 3)                   # Inf writes no rating

        # and that is not a theory about the code, it is what gets built
        counts = map(1:3) do n
            nm = instantiate_model(window(data, :time, n:n), RedispatchProblem, LPFFormulation)
            sum(JuMP.num_constraints(nm.model, F, S) for (F, S) in
                JuMP.list_of_constraint_types(nm.model))
        end
        @test counts[1] == counts[2]
        @test counts[3] < counts[1]
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

    @testset "a warm start hands the overlap to the next window" begin
        data = rolling_network()

        # what a window keeps for its successor is the overlap and nothing else:
        # its first `step` time coordinates were committed and will not be asked
        # about again
        nm = instantiate_model(window(data, :time, 1:3), RedispatchProblem, LPFFormulation)
        quiet(() -> optimize_model!(nm, OPTIMIZER))
        kept = window_indices(data, :time, 1:3)

        values = _NMB._overlap_values(nm, kept, 1)
        @test all(n in (2, 3) for (n, _, _) in keys(values))     # source indices, not local
        @test (2, :pg, 1) in keys(values)
        @test values[(2, :pg, 1)] ≈ JuMP.value(_NMB.var(nm, :pg, 1; nw = 2))

        # the next window starts from them where the two overlap, and is left
        # alone where it is seeing a step for the first time
        next = instantiate_model(window(data, :time, 2:4), RedispatchProblem, LPFFormulation)
        _NMB._warm_start!(next, values, window_indices(data, :time, 2:4))

        @test JuMP.start_value(_NMB.var(next, :pg, 1; nw = 1)) ≈ values[(2, :pg, 1)]
        @test JuMP.start_value(_NMB.var(next, :pg, 1; nw = 2)) ≈ values[(3, :pg, 1)]
        @test JuMP.start_value(_NMB.var(next, :pg, 1; nw = 3)) ==
              unit(network(data), 1; nw = 4).pg          # step 4 is new, so it keeps its own
    end

    @testset "a warm start changes the path, not the answer" begin
        # a price that differs at every step gives every window a single optimum,
        # and then where the solver starts cannot change where any of them ends
        data = rolling_network([10.0, 40.0, 90.0, 200.0])

        cold = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2, step = 1))
        warm = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2, step = 1,
                                    warm_start = true))

        @test warm["objective"] ≈ cold["objective"] rtol = 1e-6
        for n in 1:4, key in ("psd", "es")
            @test nw_solution(warm, n)["unit"]["4"][key] ≈
                  nw_solution(cold, n)["unit"]["4"][key] atol = 1e-5
        end

        # and it is off unless asked for
        plain = instantiate_model(window(data, :time, 1:2), RedispatchProblem, LPFFormulation)
        @test _NMB._warm_start!(plain, nothing, [1, 2]) === nothing
    end

    @testset "a tied window carries its tie-break into the roll" begin
        # `ROLLING_PRICES` is flat over the first three steps, so the early
        # windows have several answers that cost the same. Which one comes back
        # is committed, its state is carried on, and the rest of the roll follows
        # from it — so two rolls that differ only in where the solver started can
        # end up in different places, both of them correct.
        data = rolling_network()

        cold = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2, step = 1))
        warm = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2, step = 1,
                                    warm_start = true))

        @test cold["termination_status"] == JuMP.LOCALLY_SOLVED
        @test warm["termination_status"] == JuMP.LOCALLY_SOLVED

        # both are feasible rolls: every step committed, the battery never
        # overdrawn, and neither beating what full information can do
        best = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER))["objective"]
        for result in (cold, warm)
            @test sort(parse.(Int, collect(keys(result["solution"]["nw"])))) == [1, 2, 3, 4]
            @test sum(discharge(result, 1:4)) ≤ 0.4 + 1e-6
            @test result["objective"] >= best - 1e-6
        end

        # this is a property of rolling a tied problem, not of the warm start:
        # the same data solved in one piece has one answer
        @test best ≈ 55.0 atol = 1e-3
    end

    @testset "a warm start survives a contingency dimension" begin
        # distinct prices again, so each window has one answer and the two rolls
        # are comparable, see the tied case above
        data = rolling_network([10.0, 40.0, 90.0, 200.0]; extra_dims = (:contingency => 2,))

        cold = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2, step = 1))
        warm = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2, step = 1,
                                    warm_start = true))
        @test warm["objective"] ≈ cold["objective"] rtol = 1e-6

        # the hand-over is keyed by the source network index, so it lands on the
        # right contingency of the right hour rather than on the right local index
        nm = instantiate_model(window(data, :time, 1:2), RedispatchProblem, LPFFormulation)
        quiet(() -> optimize_model!(nm, OPTIMIZER))
        kept   = window_indices(data, :time, 1:2)
        values = _NMB._overlap_values(nm, kept, 1)

        for (n, key, idx) in keys(values)
            @test coordinates(data, n).time == 2       # only the overlapping hour
        end
        @test length(unique(coordinates(data, n).contingency for (n, _, _) in keys(values))) == 2
    end

    @testset "each window is built in a model of its own" begin
        # distinct prices, so the windows are not tied and two rolls that took
        # different paths are comparable, see the tied case above
        data = rolling_network([10.0, 40.0, 90.0, 200.0])
        plain = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2, step = 1))

        # `new_model` is a constructor, called once per window
        built  = Ref(0)
        result = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2, step = 1,
                                      new_model = () -> (built[] += 1; JuMP.Model())))
        @test built[] == length(result["horizon"]["window"]) == 4
        @test result["objective"] ≈ plain["objective"] rtol = 1e-6

        # handing it a model rather than a constructor would give every window the
        # same one, so it is refused rather than silently shared
        err = try
            solve_rolling_horizon(data, RedispatchProblem, LPFFormulation, OPTIMIZER;
                                  horizon = 2, jump_model = JuMP.Model())
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("new_model", err.msg)

        # a direct model carries its own optimizer and reaches the same answer
        direct = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2, step = 1,
                                      new_model = () -> begin
                                          m = JuMP.direct_model(Ipopt.Optimizer())
                                          JuMP.set_silent(m)
                                          m
                                      end))
        @test direct["termination_status"] == JuMP.LOCALLY_SOLVED
        @test direct["objective"] ≈ result["objective"] rtol = 1e-6
    end

    @testset "reuse and warm_start do not change the answer, in any combination" begin
        # distinct prices, so every window has one answer and the rolls are
        # comparable, see the tied case above
        data = rolling_network([10.0, 40.0, 90.0, 200.0])

        for F in (LPFFormulation, IVRFormulation)
            built = quiet(() -> solve_rd(data, F, OPTIMIZER; horizon = 2, step = 1))

            # `reuse` speaks to the building and `warm_start` to the solving, so
            # they compose — and each of the four has to reach the same place.
            # The hand-over takes a different route under `reuse`, within one
            # model rather than between two, which is why all four are checked
            for reuse in (false, true), warm_start in (false, true)
                (reuse || warm_start) || continue
                result = quiet(() -> solve_rd(data, F, OPTIMIZER; horizon = 2, step = 1,
                                              reuse, warm_start))

                @test result["termination_status"] == built["termination_status"]
                @test result["objective"] ≈ built["objective"] rtol = 1e-6
                for n in 1:4, key in ("pg", "pgup", "pgdn")
                    @test nw_solution(result, n)["unit"]["2"][key] ≈
                          nw_solution(built, n)["unit"]["2"][key] atol = 1e-5
                end
                # the battery carried its state across the windows either way
                @test nw_solution(result, 4)["unit"]["4"]["es"] ≈
                      nw_solution(built, 4)["unit"]["4"]["es"] atol = 1e-5
            end

            # one model served the windows that had the same shape; the short one
            # at the end has fewer indices and cannot
            reused = quiet(() -> solve_rd(data, F, OPTIMIZER; horizon = 2, step = 1,
                                          reuse = true))
            @test reused["horizon"]["built"] < built["horizon"]["built"]
        end
    end

    @testset "a model is rebuilt where the shape changes" begin
        # the branch is unlimited at the third step, which writes no rating there
        # and so gives that window a different shape, see `same_structure`
        dim  = Dimension(:time => 6)
        net  = network(rolling_network([10.0, 40.0, 90.0, 200.0, 30.0, 60.0]))
        net.edge[1] = Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.1,
                             rate_a = nw_vector(dim, [0.5, 0.5, Inf, 0.5, 0.5, 0.5]))
        data = NetworkData(Network(net.node, net.edge, net.unit; dim))

        built  = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2, step = 1))
        reused = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER; horizon = 2, step = 1,
                                      reuse = true))

        @test reused["objective"] ≈ built["objective"] rtol = 1e-6
        # it did reuse, but not blindly: the windows spanning the unlimited step
        # forced a rebuild rather than being updated into the wrong shape
        @test 1 < reused["horizon"]["built"] < built["horizon"]["built"]
    end

    @testset "update_model! refuses data of another shape" begin
        data = rolling_network()
        nm   = instantiate_model(window(data, :time, 1:2), RedispatchProblem, LPFFormulation)

        err = try
            update_model!(nm, window(data, :time, 1:3))
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("same shape", err.msg)

        # and accepts one of the same shape, leaving the model the size it was
        before = JuMP.num_variables(nm.model)
        update_model!(nm, window(data, :time, 3:4))
        @test JuMP.num_variables(nm.model) == before
        @test length(registered_constraints(nm)) > 0
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
