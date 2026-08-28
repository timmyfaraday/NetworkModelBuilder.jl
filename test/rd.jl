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
