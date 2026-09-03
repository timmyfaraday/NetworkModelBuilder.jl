################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
################################################################################

"case14 with every plain branch rebuilt as `T`, which must change nothing"
function as_branch_type(::Type{T}) where {T<:AbstractBranch}
    data = quiet(() -> parse_file(case("case14")))
    net  = network(data)
    E    = Dict{Int,AbstractEdge}(net.edge)

    for e in ids(net, Branch)
        br   = edge(net, e)::Branch
        E[e] = T(; id = br.id, name = br.name, terminals = br.terminals,
                 r = br.r, x = br.x, b_fr = br.b_fr, b_to = br.b_to,
                 rate_a = br.rate_a, angmin = br.angmin, angmax = br.angmax,
                 status = br.status)
    end

    return NetworkData(Network(net.node, E, net.unit);
                       name = "case14 as $T", baseMVA = baseMVA(data))
end

"case5 with edge 5, which has a turns ratio, rebuilt as `T` carrying `extra`"
function as_transformer_type(::Type{T}; extra...) where {T<:AbstractTwoWindingTransformer}
    data = quiet(() -> parse_file(case("case5")))
    net  = network(data)
    tf   = edge(net, 5)::Transformer
    E    = Dict{Int,AbstractEdge}(net.edge)

    E[5] = T(; id = tf.id, name = tf.name, terminals = tf.terminals, r = tf.r, x = tf.x,
             b_fr = tf.b_fr, b_to = tf.b_to, tm = tf.tm, ta = tf.ta, rate_a = tf.rate_a,
             angmin = tf.angmin, angmax = tf.angmax, status = tf.status, extra...)

    return NetworkData(Network(net.node, E, net.unit);
                       name = "case5 with a $T", baseMVA = baseMVA(data))
end

@testset "component hierarchy" begin

    @testset "the type tree" begin
        @test Branch <: AbstractBranch <: AbstractEdge <: AbstractComponent
        @test Cable <: AbstractBranch
        @test OverheadLine <: AbstractBranch
        @test Transformer <: AbstractTwoWindingTransformer <: AbstractTransformer <: AbstractEdge
        @test PhaseShifter <: AbstractTwoWindingTransformer
        @test TapChanger <: AbstractTwoWindingTransformer
        @test MultiWindingTransformer <: AbstractTransformer
        @test !(MultiWindingTransformer <: AbstractTwoWindingTransformer)

        @test Generator <: AbstractGenerator <: AbstractUnit
        @test FixedLoad <: AbstractLoad <: AbstractUnit
        @test FlexibleLoad <: AbstractLoad
        @test Storage <: AbstractStorage <: AbstractUnit
        @test Shunt <: AbstractShunt <: AbstractUnit

        # a branch transports and so has no turns ratio; a transformer does
        @test :tm ∉ fieldnames(Branch)
        @test :tm ∈ fieldnames(Transformer)

        for T in (Branch, Cable, OverheadLine, Transformer, PhaseShifter, TapChanger,
                  MultiWindingTransformer)
            @test T in edge_types()
        end
        for T in (Generator, FixedLoad, FlexibleLoad, Storage, Shunt)
            @test T in unit_types()
        end
    end

    @testset "every branch type is the same π-equivalent" begin
        reference = quiet(() -> solve_lf(case("case14"), IVRFormulation, OPTIMIZER))

        for T in (Cable, OverheadLine)
            result = quiet(() -> solve_lf(as_branch_type(T), IVRFormulation, OPTIMIZER))

            @test result["termination_status"] == JuMP.LOCALLY_SOLVED
            for i in keys(nw_solution(reference)["node"])
                @test nw_solution(result)["node"][i]["vm"] ≈
                      nw_solution(reference)["node"][i]["vm"] atol = 1e-8
                @test nw_solution(result)["node"][i]["va"] ≈
                      nw_solution(reference)["node"][i]["va"] atol = 1e-8
            end
        end
    end

    @testset "a controllable tap is fixed in a load flow" begin
        # a load flow has no freedom, so a phase shifter and a tap changer must
        # behave exactly as the transformer they were built from
        reference = quiet(() -> solve_lf(case("case5"), IVRFormulation, OPTIMIZER))

        for data in (as_transformer_type(PhaseShifter; ta_min = -0.3, ta_max = 0.3),
                     as_transformer_type(TapChanger; tm_min = 0.9, tm_max = 1.1))
            result = quiet(() -> solve_lf(data, IVRFormulation, OPTIMIZER))

            @test result["termination_status"] == JuMP.LOCALLY_SOLVED
            for i in keys(nw_solution(reference)["node"])
                @test nw_solution(result)["node"][i]["vm"] ≈
                      nw_solution(reference)["node"][i]["vm"] atol = 1e-7
            end
        end
    end

    @testset "a controllable tap is a decision in a dispatch problem" begin
        fixed = quiet(() -> solve_opf(case("case5"), IVRFormulation, OPTIMIZER))

        @testset "$T" for (T, extra) in ((PhaseShifter, (ta_min = -0.2, ta_max = 0.2)),
                                         (TapChanger,   (tm_min = 0.9, tm_max = 1.1)))
            data   = as_transformer_type(T; extra...)
            nm     = instantiate_model(data, OptimalPowerFlowProblem, IVRFormulation)
            result = quiet(() -> optimize_model!(nm, OPTIMIZER))

            @test result["termination_status"] == JuMP.LOCALLY_SOLVED

            # a free tap enlarges the feasible set, so the optimum cannot be worse
            @test result["objective"] <= fixed["objective"] + 1e-6

            # and the tap it chose sits inside its limits
            tap = solution_tap(nm, edge(nm, 5), 5, 1)
            if T === PhaseShifter
                @test tap["tm"] ≈ edge(nm, 5).tm atol = 1e-6     # magnitude preserved
                @test -0.2 - 1e-6 <= tap["ta"] <= 0.2 + 1e-6
            else
                @test 0.9 - 1e-6 <= tap["tm"] <= 1.1 + 1e-6
                @test tap["ta"] ≈ edge(nm, 5).ta atol = 1e-6     # angle preserved
            end
        end
    end

    @testset "a multi-winding transformer hides its star point" begin
        r, x = [0.010, 0.020, 0.030], [0.100, 0.200, 0.300]

        star = NetworkData(Network(
            Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.02),
                                   2 => Node(; id = 2), 3 => Node(; id = 3)),
            Dict{Int,AbstractEdge}(1 => MultiWindingTransformer(; id = 1,
                                                                terminals = [1, 2, 3],
                                                                r = r, x = x)),
            Dict{Int,AbstractUnit}(1 => Generator(; id = 1, node = 1),
                                   2 => FixedLoad(; id = 2, node = 2, pd = 0.40, qd = 0.15),
                                   3 => FixedLoad(; id = 3, node = 3, pd = 0.25, qd = 0.10)));
            name = "star")

        split = NetworkData(Network(
            Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.02),
                                   2 => Node(; id = 2), 3 => Node(; id = 3),
                                   4 => Node(; id = 4)),
            Dict{Int,AbstractEdge}(k => Branch(; id = k, terminals = [k, 4],
                                               r = r[k], x = x[k]) for k in 1:3),
            Dict{Int,AbstractUnit}(1 => Generator(; id = 1, node = 1),
                                   2 => FixedLoad(; id = 2, node = 2, pd = 0.40, qd = 0.15),
                                   3 => FixedLoad(; id = 3, node = 3, pd = 0.25, qd = 0.10)));
            name = "split")

        # the star point is not a node: three nodes, one edge, three arcs
        @test length(ids(network(star), Node)) == 3
        @test length(arcs(network(star))) == 3
        @test nterminals(edge(network(star), 1)) == 3

        a = quiet(() -> solve_lf(star,  IVRFormulation, OPTIMIZER))
        b = quiet(() -> solve_lf(split, IVRFormulation, OPTIMIZER))

        for i in 1:3
            @test nw_solution(a)["node"]["$i"]["vm"] ≈ nw_solution(b)["node"]["$i"]["vm"] atol = 1e-8
            @test nw_solution(a)["node"]["$i"]["va"] ≈ nw_solution(b)["node"]["$i"]["va"] atol = 1e-8
        end
        @test nw_solution(a)["unit"]["1"]["p"] ≈ nw_solution(b)["unit"]["1"]["p"] atol = 1e-8

        # the star point appears in the edge, and nowhere among the nodes
        @test !haskey(nw_solution(a)["node"], "4")
        @test length(nw_solution(a)["edge"]["1"]["terminal"]) == 3
    end
end

################################################################################
# Units that couple network indices                                            #
################################################################################

"""
A two-node network over a `:time` dimension whose generation cost changes from
one step to the next, which is what gives a flexible unit something to respond
to.
"""
function price_network(prices; extra::Dict{Int,AbstractUnit} = Dict{Int,AbstractUnit}())
    dim = Dimension(:time => length(prices))

    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.0),
                               2 => Node(; id = 2))
    E = Dict{Int,AbstractEdge}(1 => Branch(; id = 1, terminals = [1, 2],
                                           r = 0.001, x = 0.01))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       cost = nw_vector(dim, [[0.0, p] for p in prices])),
        2 => FixedLoad(; id = 2, node = 2, pd = 0.20, qd = 0.05))
    merge!(U, extra)

    return NetworkData(Network(I, E, U; dim); name = "prices", baseMVA = 100.0)
end

"""
A storage unit whose energy comes partly from outside the model, registered from
here the way an extension package would register it — which is the whole point
of the [`inflow`](@ref) hook: a reservoir overrides one line rather than the
state of charge balance.
"""
Base.@kwdef struct InflowStorage <: AbstractStorage
    id                   ::Int
    name                 ::String                   = ""
    node                 ::Int
    ps                   ::NetworkQuantity{Float64} = 0.0
    qs                   ::NetworkQuantity{Float64} = 0.0
    energy_capacity      ::NetworkQuantity{Float64} = 0.0
    energy_initial       ::Float64                  = 0.0
    energy_final         ::Float64                  = NaN
    charge_rating        ::NetworkQuantity{Float64} = 0.0
    discharge_rating     ::NetworkQuantity{Float64} = 0.0
    charge_efficiency    ::Float64                  = 1.0
    discharge_efficiency ::Float64                  = 1.0
    max_cycles_per_period::Float64                  = Inf
    cost_throughput      ::NetworkQuantity{Float64} = 0.0
    cost_cycle           ::Float64                  = 0.0
    net_inflow           ::NetworkQuantity{Float64} = 0.0
    qmin                 ::NetworkQuantity{Float64} = 0.0
    qmax                 ::NetworkQuantity{Float64} = 0.0
    cost_up              ::NetworkQuantity{Float64} = 0.0
    cost_dn              ::NetworkQuantity{Float64} = 0.0
    status               ::NetworkQuantity{Bool}    = true
    ext                  ::Dict{Symbol,Any}         = Dict{Symbol,Any}()
end

register_unit_type!(InflowStorage)

NetworkModelBuilder.inflow(st::InflowStorage, nm::NetworkModel, n::Int) =
    nw_value(nm, st.net_inflow, n)

"a two step network, cheap then dear, and nothing between the two but a battery"
function arbitrage_network(battery)
    return price_network([10.0, 100.0]; extra = Dict{Int,AbstractUnit}(3 => battery))
end

"the charge, discharge and state of charge of unit 3 over `steps` of a result"
storage_path(result, steps) =
    ([nw_solution(result, n)["unit"]["3"]["psc"] for n in steps],
     [nw_solution(result, n)["unit"]["3"]["psd"] for n in steps],
     [nw_solution(result, n)["unit"]["3"]["es"]  for n in steps])

const PRICES = [10.0, 100.0, 50.0]

@testset "units that couple network indices" begin

    @testset "a flexible load moves demand to the cheap step" begin
        flat = FlexibleLoad(; id = 3, node = 2, pd_nominal = 0.10, qd_nominal = 0.02,
                            pd_min = 0.0, pd_max = 0.15)
        data = price_network(PRICES; extra = Dict{Int,AbstractUnit}(3 => flat))

        result = quiet(() -> solve_model(data, OptimalPowerFlowProblem,
                                         IVRFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED

        pd = [nw_solution(result, n)["unit"]["3"]["pd"] for n in 1:3]

        # it fills the cheapest step to the brim, then prefers the next cheapest
        @test pd[1] ≈ 0.15 atol = 1e-5
        @test pd[3] > pd[2]
        @test pd[2] < 1e-5

        # and it takes exactly the energy the nominal profile would have taken
        @test sum(pd) ≈ 3 * 0.10 atol = 1e-6

        # reactive demand follows at the nominal power factor
        for n in 1:3
            @test nw_solution(result, n)["unit"]["3"]["qd"] ≈
                  0.2 * nw_solution(result, n)["unit"]["3"]["pd"] atol = 1e-8
        end
    end

    @testset "a flexible load balances its energy per period" begin
        # six steps, cheap-dear-cheap in each half, grouped into two days: the
        # load may shift within a day but may not borrow energy from the other
        prices = [10.0, 100.0, 50.0, 10.0, 100.0, 50.0]
        flat   = FlexibleLoad(; id = 3, node = 2, pd_nominal = 0.10, qd_nominal = 0.02,
                              pd_min = 0.0, pd_max = 0.15)
        data   = price_network(prices; extra = Dict{Int,AbstractUnit}(3 => flat))
        dim_meta(dimension(data), :time)[:period_length] = 3

        result = quiet(() -> solve_model(data, OptimalPowerFlowProblem,
                                         LPFFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        pd = [nw_solution(result, n)["unit"]["3"]["pd"] for n in 1:6]

        # each day balances on its own, rather than the horizon balancing as one
        @test sum(pd[1:3]) ≈ 3 * 0.10 atol = 1e-6
        @test sum(pd[4:6]) ≈ 3 * 0.10 atol = 1e-6

        # and within a day it still runs to the cheap step
        @test pd[1] ≈ 0.15 atol = 1e-5
        @test pd[4] ≈ 0.15 atol = 1e-5

        # ungrouped, the same data is one period and the halves may trade
        loose = quiet(() -> solve_model(price_network(prices;
                                            extra = Dict{Int,AbstractUnit}(3 => flat)),
                                        OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        @test sum(nw_solution(loose, n)["unit"]["3"]["pd"] for n in 1:6) ≈ 6 * 0.10 atol = 1e-6
        @test loose["objective"] <= result["objective"] + 1e-8
    end

    @testset "a flexible load is fixed in a load flow" begin
        flat = FlexibleLoad(; id = 3, node = 2, pd_nominal = 0.10, qd_nominal = 0.02,
                            pd_min = 0.0, pd_max = 0.15)
        data = price_network(PRICES; extra = Dict{Int,AbstractUnit}(3 => flat))

        result = quiet(() -> solve_model(data, LoadFlowProblem, IVRFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        for n in 1:3
            @test nw_solution(result, n)["unit"]["3"]["pd"] ≈ 0.10 atol = 1e-8
        end
    end

    @testset "a storage unit arbitrages the price" begin
        battery = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.0,
                          charge_rating = 0.2, discharge_rating = 0.2,
                          charge_efficiency = 0.95, discharge_efficiency = 0.95)
        data = price_network(PRICES; extra = Dict{Int,AbstractUnit}(3 => battery))

        result = quiet(() -> solve_model(data, OptimalPowerFlowProblem,
                                         IVRFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED

        psc = [nw_solution(result, n)["unit"]["3"]["psc"] for n in 1:3]
        psd = [nw_solution(result, n)["unit"]["3"]["psd"] for n in 1:3]
        es  = [nw_solution(result, n)["unit"]["3"]["es"]  for n in 1:3]

        # it charges when power is cheap and discharges when it is dear
        @test psc[1] > 0.01
        @test psd[2] > 0.01
        @test psd[1] < 1e-5

        # the state of charge follows the flows, from an empty start
        @test es[1] ≈ 0.0 + 0.95 * psc[1] - psd[1] / 0.95 atol = 1e-7
        for n in 2:3
            @test es[n] ≈ es[n-1] + 0.95 * psc[n] - psd[n] / 0.95 atol = 1e-7
        end
        @test all(0 - 1e-7 .<= es .<= 0.5 + 1e-7)

        # and having it is never worse than not having it
        without = quiet(() -> solve_model(price_network(PRICES), OptimalPowerFlowProblem,
                                          IVRFormulation, OPTIMIZER))
        @test result["objective"] <= without["objective"] + 1e-6
    end


    # The two step network costs 10(0.2) + 100(0.2) = 22 with no battery. One that
    # charges 0.2 in the cheap step and gives it back in the dear one leaves the
    # generator 0.4 and 0.0 to make, which is 4 — a gain of 18 for 0.2 pu moved,
    # or 90 per pu. Every number below is that 90 against a price.
    @testset "a battery pays for what it moves" begin
        plain = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.0,
                        charge_rating = 0.2, discharge_rating = 0.2)
        free  = quiet(() -> solve_model(arbitrage_network(plain), OptimalPowerFlowProblem,
                                        LPFFormulation, OPTIMIZER))
        psc, psd, _ = storage_path(free, 1:2)
        @test psc[1] ≈ 0.2 atol = 1e-6
        @test psd[2] ≈ 0.2 atol = 1e-6
        @test free["objective"] ≈ 4.0 atol = 1e-4

        # a throughput price below 90 per pu leaves the arbitrage worth doing and
        # simply charges for it
        cheap = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.0,
                        charge_rating = 0.2, discharge_rating = 0.2, cost_throughput = 50.0)
        result = quiet(() -> solve_model(arbitrage_network(cheap), OptimalPowerFlowProblem,
                                         LPFFormulation, OPTIMIZER))
        @test storage_path(result, 1:2)[2][2] ≈ 0.2 atol = 1e-6
        @test result["objective"] ≈ 4.0 + 50.0 * 0.2 atol = 1e-4

        # above it the battery is better off doing nothing at all
        dear = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.0,
                       charge_rating = 0.2, discharge_rating = 0.2, cost_throughput = 100.0)
        idle = quiet(() -> solve_model(arbitrage_network(dear), OptimalPowerFlowProblem,
                                       LPFFormulation, OPTIMIZER))
        @test storage_path(idle, 1:2)[2][2] < 1e-6
        @test idle["objective"] ≈ 22.0 atol = 1e-4
    end

    @testset "a battery pays per cycle, which is not per unit of energy" begin
        # 0.2 pu out of a capacity of 0.5 is 0.4 of a cycle, so a price of 20 per
        # cycle is 40 per pu — below the 90 the arbitrage is worth
        cheap  = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.0,
                         charge_rating = 0.2, discharge_rating = 0.2, cost_cycle = 20.0)
        result = quiet(() -> solve_model(arbitrage_network(cheap), OptimalPowerFlowProblem,
                                         LPFFormulation, OPTIMIZER))
        @test storage_path(result, 1:2)[2][2] ≈ 0.2 atol = 1e-6
        @test result["objective"] ≈ 4.0 + 20.0 * 0.4 atol = 1e-4

        # and 100 per cycle is 200 per pu, which is not
        dear = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.0,
                       charge_rating = 0.2, discharge_rating = 0.2, cost_cycle = 100.0)
        idle = quiet(() -> solve_model(arbitrage_network(dear), OptimalPowerFlowProblem,
                                       LPFFormulation, OPTIMIZER))
        @test storage_path(idle, 1:2)[2][2] < 1e-6
        @test idle["objective"] ≈ 22.0 atol = 1e-4

        # the charge is a period cost, so it reaches the objective through the
        # horizon term rather than through any one network index
        nm = instantiate_model(arbitrage_network(cheap), OptimalPowerFlowProblem,
                               LPFFormulation)
        @test JuMP.coefficient(horizon_cost(nm), _NMB.var(nm, :psd, 3; nw = 2)) ≈ 20.0 / 0.5
        @test JuMP.coefficient(network_cost(nm, 2), _NMB.var(nm, :psd, 3; nw = 2)) ≈ 0.0
        @test period_cost(nm, Storage, 3; nw = 1) isa JuMP.AbstractJuMPScalar
        @test period_cost(nm, FixedLoad, 2; nw = 1) == 0.0
    end

    @testset "a cycle limit is written once per period" begin
        # a limit of 0.2 cycles on a capacity of 0.5 is 0.1 pu·h of discharge
        limited = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.0,
                          charge_rating = 0.2, discharge_rating = 0.2,
                          max_cycles_per_period = 0.2)
        result  = quiet(() -> solve_model(arbitrage_network(limited),
                                          OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        @test sum(storage_path(result, 1:2)[2]) ≈ 0.1 atol = 1e-6

        # with no limit the same battery moves twice as much
        plain = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.0,
                        charge_rating = 0.2, discharge_rating = 0.2)
        free  = quiet(() -> solve_model(arbitrage_network(plain), OptimalPowerFlowProblem,
                                        LPFFormulation, OPTIMIZER))
        @test sum(storage_path(free, 1:2)[2]) ≈ 0.2 atol = 1e-6

        # an infinite limit is the absence of a row, not a row with an infinite
        # right hand side
        loose = instantiate_model(arbitrage_network(plain), OptimalPowerFlowProblem,
                                  LPFFormulation)
        @test !haskey(_NMB.registered_constraints(loose), (1, :storage_cycles, 3))
        tight = instantiate_model(arbitrage_network(limited), OptimalPowerFlowProblem,
                                  LPFFormulation)
        @test haskey(_NMB.registered_constraints(tight), (1, :storage_cycles, 3))
    end

    @testset "the periods are what a cycle limit is per" begin
        # four steps, cheap-dear in each half, grouped into two days: the battery
        # gets its 0.1 pu·h of discharge in each of them rather than once
        limited = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.0,
                          charge_rating = 0.2, discharge_rating = 0.2,
                          max_cycles_per_period = 0.2)
        data = price_network([10.0, 100.0, 10.0, 100.0];
                             extra = Dict{Int,AbstractUnit}(3 => limited))
        dim_meta(dimension(data), :time)[:period_length] = 2

        result = quiet(() -> solve_model(data, OptimalPowerFlowProblem, LPFFormulation,
                                         OPTIMIZER))
        psd = storage_path(result, 1:4)[2]
        @test sum(psd[1:2]) ≈ 0.1 atol = 1e-6
        @test sum(psd[3:4]) ≈ 0.1 atol = 1e-6

        # ungrouped, the same data is one period and the halves share one limit
        loose = quiet(() -> solve_model(
            price_network([10.0, 100.0, 10.0, 100.0];
                          extra = Dict{Int,AbstractUnit}(3 => limited)),
            OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        @test sum(storage_path(loose, 1:4)[2]) ≈ 0.1 atol = 1e-6
    end

    @testset "a storage unit says when it is free to cycle against negative prices" begin
        plain = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.0,
                        charge_rating = 0.2, discharge_rating = 0.2)

        # nothing is priced below zero, so nothing is said
        @test_logs min_level = Logging.Warn instantiate_model(
            arbitrage_network(plain), OptimalPowerFlowProblem, LPFFormulation)

        # a generator that pays to run, and a battery that pays nothing to cycle
        paid = price_network([-10.0, 100.0]; extra = Dict{Int,AbstractUnit}(3 => plain))
        @test_logs (:warn,) match_mode = :any instantiate_model(
            paid, OptimalPowerFlowProblem, LPFFormulation)

        # a cycle limit, a throughput price or a cycle price each settle it
        for priced in (Storage(; id = 3, node = 2, energy_capacity = 0.5,
                               charge_rating = 0.2, discharge_rating = 0.2,
                               max_cycles_per_period = 1.0),
                       Storage(; id = 3, node = 2, energy_capacity = 0.5,
                               charge_rating = 0.2, discharge_rating = 0.2,
                               cost_throughput = 1.0),
                       Storage(; id = 3, node = 2, energy_capacity = 0.5,
                               charge_rating = 0.2, discharge_rating = 0.2,
                               cost_cycle = 1.0))
            @test_logs min_level = Logging.Warn instantiate_model(
                price_network([-10.0, 100.0]; extra = Dict{Int,AbstractUnit}(3 => priced)),
                OptimalPowerFlowProblem, LPFFormulation)
        end
    end

    @testset "energy may arrive from outside the model" begin
        # a plain battery has no inflow, and the hook says so
        nm = instantiate_model(arbitrage_network(
                 Storage(; id = 3, node = 2, energy_capacity = 0.5,
                         charge_rating = 0.2, discharge_rating = 0.2)),
             OptimalPowerFlowProblem, LPFFormulation)
        @test inflow(unit(nm, 3; nw = 1), nm, 1) == 0.0

        # a subtype that overrides one line gets the whole balance for free:
        # 0.05 pu·h arrives every step, is held through the cheap one and given
        # back in the dear one
        river = InflowStorage(; id = 3, node = 2, energy_capacity = 0.5,
                              energy_initial = 0.0, charge_rating = 0.0,
                              discharge_rating = 0.2, net_inflow = 0.05)
        data   = price_network(PRICES; extra = Dict{Int,AbstractUnit}(3 => river))
        result = quiet(() -> solve_model(data, OptimalPowerFlowProblem, LPFFormulation,
                                         OPTIMIZER))

        _, psd, es = storage_path(result, 1:3)
        @test psd ≈ [0.0, 0.10, 0.05] atol = 1e-6
        @test es  ≈ [0.05, 0.0, 0.0]  atol = 1e-6

        # nothing of the inflow is lost or invented over the horizon
        @test sum(psd) ≈ 3 * 0.05 atol = 1e-6
    end


    @testset "a horizon can be asked to end where it started" begin
        # the battery starts on 0.2 and may end wherever it likes: it charges in
        # the cheap step, sells in the dear one and sells the rest in the last
        loose = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.2,
                        charge_rating = 0.2, discharge_rating = 0.2)
        free   = quiet(() -> solve_model(price_network(PRICES;
                                             extra = Dict{Int,AbstractUnit}(3 => loose)),
                                         OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        @test storage_path(free, 1:3)[3] ≈ [0.4, 0.2, 0.0] atol = 1e-6
        @test free["objective"] ≈ 4.0 atol = 1e-4

        # asked to hand back 0.2, it stops one step short and pays for the step
        # it can no longer cover
        pinned = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.2,
                         energy_final = 0.2, charge_rating = 0.2, discharge_rating = 0.2)
        held   = quiet(() -> solve_model(price_network(PRICES;
                                             extra = Dict{Int,AbstractUnit}(3 => pinned)),
                                         OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        @test storage_path(held, 1:3)[3] ≈ [0.4, 0.2, 0.2] atol = 1e-6
        @test held["objective"] ≈ 14.0 atol = 1e-4

        # no target is the absence of a row, not a row against `NaN`
        open  = instantiate_model(price_network(PRICES;
                                      extra = Dict{Int,AbstractUnit}(3 => loose)),
                                  OptimalPowerFlowProblem, LPFFormulation)
        @test !haskey(_NMB.registered_constraints(open), (3, :storage_final, 3))
        shut  = instantiate_model(price_network(PRICES;
                                      extra = Dict{Int,AbstractUnit}(3 => pinned)),
                                  OptimalPowerFlowProblem, LPFFormulation)
        @test haskey(_NMB.registered_constraints(shut), (3, :storage_final, 3))
    end

    @testset "a target the ratings cannot reach has no answer" begin
        # 0.5 asked of a unit that starts empty and may charge 0.2 a step, over
        # two steps: a pin is a pin, and the honest answer is that there is none
        unreachable = Storage(; id = 3, node = 2, energy_capacity = 0.5,
                              energy_initial = 0.0, energy_final = 0.5,
                              charge_rating = 0.2, discharge_rating = 0.2)
        result = quiet(() -> solve_model(arbitrage_network(unreachable),
                                         OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        @test result["termination_status"] != JuMP.LOCALLY_SOLVED

        @test_throws ArgumentError Storage(; id = 3, node = 2, energy_final = -1.0)
        @test isnan(Storage(; id = 3, node = 2).energy_final)
    end

    @testset "only the window that closes a horizon carries its target" begin
        pinned = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.2,
                         energy_final = 0.2, charge_rating = 0.2, discharge_rating = 0.2)

        # the target is released, and nothing else about the unit is touched
        released = interior_state(pinned)
        @test isnan(released.energy_final)
        @test released.energy_initial == pinned.energy_initial
        @test released.energy_capacity == pinned.energy_capacity
        @test released.charge_rating == pinned.charge_rating

        # a unit with no target, and anything that is not a storage unit, is
        # returned as it is
        loose = Storage(; id = 3, node = 2, energy_capacity = 0.5)
        @test interior_state(loose) === loose
        @test interior_state(Node(; id = 1)) isa Node
    end

    @testset "a time coupled unit says so when there is no time" begin
        for cmp in (FlexibleLoad(; id = 3, node = 2, pd_nominal = 0.1, pd_max = 0.2),
                    Storage(; id = 3, node = 2, energy_capacity = 0.5,
                            charge_rating = 0.2, discharge_rating = 0.2))
            I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF), 2 => Node(; id = 2))
            E = Dict{Int,AbstractEdge}(1 => Branch(; id = 1, terminals = [1, 2],
                                                   r = 0.001, x = 0.01))
            U = Dict{Int,AbstractUnit}(1 => Generator(; id = 1, node = 1, pmax = 5.0),
                                       3 => cmp)
            data = NetworkData(Network(I, E, U); name = "no time")

            err = try
                instantiate_model(data, OptimalPowerFlowProblem, IVRFormulation)
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("couples network indices along `:time`", err.msg)
        end
    end
end
