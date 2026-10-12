################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
# v0.12.0 - one Transformer; its controls are flags, not types                 #
# v0.13.0 - one Branch, so no branch type is compared with another             #
# v0.13.0 - a branch holds one entry per terminal of a field                   #
# v0.14.0 - variable and solution keys follow the nomenclature                 #
# v0.14.0 - the fields follow the nomenclature                                 #
# v0.15.0 - constraint keys follow the nomenclature                            #
# v0.15.1 - e_min, c_chg and c_dch replace c_thru                              #
# v0.15.2 - a storage unit's converter rating                                  #
# v0.15.3 - exact keeps charging and discharging at once out                   #
# v0.15.4 - the end of a storage unit's horizon is a list of conditions        #
# v0.15.5 - an outage of a storage unit is its status                          #
# v0.15.6 - the cycle limit is a sliding 24 h window on both sides of the store#
################################################################################

"case5 with edge 5, which has a turns ratio, rebuilt as a transformer carrying `extra`"
function as_transformer(; extra...)
    data = quiet(() -> parse_file(case("case5")))
    net  = network(data)
    tf   = edge(net, 5)::Transformer
    E    = Dict{Int,AbstractEdge}(net.edge)

    E[5] = Transformer(; id = tf.id, name = tf.name, terminals = tf.terminals, r = tf.r, x = tf.x,
                       g_shnt = tf.g_shnt, b_shnt = tf.b_shnt, t_magn = tf.t_magn, t_angl = tf.t_angl, s_max = tf.s_max,
                       v_angl_min = tf.v_angl_min, v_angl_max = tf.v_angl_max, status = tf.status, extra...)

    return NetworkData(Network(net.node, E, net.unit);
                       name = "case5 with a controlled transformer", s_base_mva = s_base_mva(data))
end

@testset "component hierarchy" begin

    @testset "the type tree" begin
        @test Branch <: AbstractBranch <: AbstractEdge <: AbstractComponent
        @test Transformer <: AbstractTransformer <: AbstractEdge

        @test Generator <: AbstractGenerator <: AbstractUnit
        @test FixedLoad <: AbstractLoad <: AbstractUnit
        @test FlexibleLoad <: AbstractLoad
        @test Storage <: AbstractStorage <: AbstractUnit
        @test Shunt <: AbstractShunt <: AbstractUnit

        # a branch transports and so has no turns ratio; a transformer does
        @test :t_magn ∉ fieldnames(Branch)
        @test :t_magn ∈ fieldnames(Transformer)

        for T in (Branch, DCLink, Switch, Transformer)
            @test T in edge_types()
        end

        # a cable and an overhead line are a Branch with another length, not types
        @test !isdefined(_NMB, :Cable) && !isdefined(_NMB, :OverheadLine)
        @test !any(T -> nameof(T) in (:Cable, :OverheadLine), edge_types())

        # a rating that follows the weather is a profile in the `s_max` of any branch
        br = Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.1, s_max = 1.5)
        @test dynamic_rating(br) == [1.5, 1.5]
        for T in (Generator, FixedLoad, FlexibleLoad, Storage, Shunt)
            @test T in unit_types()
        end
    end

    @testset "a controllable tap is fixed in a load flow" begin
        # a load flow has no freedom, so a transformer whose angle or magnitude can
        # move must behave exactly as the one it was built from
        reference = quiet(() -> solve_lf(case("case5"), IVRFormulation, OPTIMIZER))

        for data in (as_transformer(; pst = true, t_angl_min = -0.3, t_angl_max = 0.3),
                     as_transformer(; oltc = true, t_magn_min = 0.9, t_magn_max = 1.1))
            result = quiet(() -> solve_lf(data, IVRFormulation, OPTIMIZER))

            @test result["termination_status"] == JuMP.LOCALLY_SOLVED
            for i in keys(nw_solution(reference)["node"])
                @test nw_solution(result)["node"][i]["v_magn"] ≈
                      nw_solution(reference)["node"][i]["v_magn"] atol = 1e-7
            end
        end
    end

    @testset "a controllable tap is a decision in a dispatch problem" begin
        fixed = quiet(() -> solve_opf(case("case5"), IVRFormulation, OPTIMIZER))

        @testset "$name" for (name, extra) in (
                ("angle", (pst  = true, t_angl_min = -0.2, t_angl_max = 0.2)),
                ("magnitude", (oltc = true, t_magn_min = 0.9, t_magn_max = 1.1)))
            data   = as_transformer(; extra...)
            nm     = instantiate_model(data, OptimalPowerFlowProblem, IVRFormulation)
            result = quiet(() -> optimize_model!(nm, OPTIMIZER))

            @test result["termination_status"] == JuMP.LOCALLY_SOLVED

            # a free tap enlarges the feasible set, so the optimum cannot be worse
            @test result["objective"] <= fixed["objective"] + 1e-6

            # and the tap it chose sits inside its limits
            tap = nw_solution(result)["edge"]["5"]["terminal"]["1"]["tap"]
            if name == "angle"
                @test tap["t_magn"] ≈ edge(nm, 5).t_magn[1] atol = 1e-6     # magnitude preserved
                @test -0.2 - 1e-6 <= tap["t_angl"] <= 0.2 + 1e-6
            else
                @test 0.9 - 1e-6 <= tap["t_magn"] <= 1.1 + 1e-6
                @test tap["t_angl"] ≈ edge(nm, 5).t_angl[1] atol = 1e-6     # angle preserved
            end
        end
    end

    @testset "a transformer with three windings hides its star point" begin
        r, x = [0.010, 0.020, 0.030], [0.100, 0.200, 0.300]

        star = NetworkData(Network(
            Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, v_magn_set = 1.02),
                                   2 => Node(; id = 2), 3 => Node(; id = 3)),
            Dict{Int,AbstractEdge}(1 => Transformer(; id = 1,
                                                    terminals = [1, 2, 3],
                                                    r = r, x = x)),
            Dict{Int,AbstractUnit}(1 => Generator(; id = 1, node = 1),
                                   2 => FixedLoad(; id = 2, node = 2, p_set = 0.40, q_set = 0.15),
                                   3 => FixedLoad(; id = 3, node = 3, p_set = 0.25, q_set = 0.10)));
            name = "star")

        split = NetworkData(Network(
            Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, v_magn_set = 1.02),
                                   2 => Node(; id = 2), 3 => Node(; id = 3),
                                   4 => Node(; id = 4)),
            Dict{Int,AbstractEdge}(k => Branch(; id = k, terminals = [k, 4],
                                               r = r[k], x = x[k]) for k in 1:3),
            Dict{Int,AbstractUnit}(1 => Generator(; id = 1, node = 1),
                                   2 => FixedLoad(; id = 2, node = 2, p_set = 0.40, q_set = 0.15),
                                   3 => FixedLoad(; id = 3, node = 3, p_set = 0.25, q_set = 0.10)));
            name = "split")

        # the star point is not a node: three nodes, one edge, three arcs
        @test length(ids(network(star), Node)) == 3
        @test length(arcs(network(star))) == 3
        @test nterminals(edge(network(star), 1)) == 3

        a = quiet(() -> solve_lf(star,  IVRFormulation, OPTIMIZER))
        b = quiet(() -> solve_lf(split, IVRFormulation, OPTIMIZER))

        for i in 1:3
            @test nw_solution(a)["node"]["$i"]["v_magn"] ≈ nw_solution(b)["node"]["$i"]["v_magn"] atol = 1e-8
            @test nw_solution(a)["node"]["$i"]["v_angl"] ≈ nw_solution(b)["node"]["$i"]["v_angl"] atol = 1e-8
        end
        @test nw_solution(a)["unit"]["1"]["p_unit"] ≈ nw_solution(b)["unit"]["1"]["p_unit"] atol = 1e-8

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
function price_network(prices; dim::Dimension = Dimension(:time => length(prices)),
                       extra::Dict{Int,AbstractUnit} = Dict{Int,AbstractUnit}())

    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, v_magn_set = 1.0),
                               2 => Node(; id = 2))
    E = Dict{Int,AbstractEdge}(1 => Branch(; id = 1, terminals = [1, 2],
                                           r = 0.001, x = 0.01))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, p_max = 5.0, q_min = -5.0, q_max = 5.0,
                       c = nw_vector(dim, [[0.0, p] for p in prices])),
        2 => FixedLoad(; id = 2, node = 2, p_set = 0.20, q_set = 0.05))
    merge!(U, extra)

    return NetworkData(Network(I, E, U; dim); name = "prices", s_base_mva = 100.0)
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
    p_set                   ::NetworkQuantity{Float64} = 0.0
    q_set                   ::NetworkQuantity{Float64} = 0.0
    e_max      ::NetworkQuantity{Float64} = 0.0
    e_min      ::NetworkQuantity{Float64} = 0.0
    e_init       ::Float64                  = 0.0
    e_fin         ::Float64                  = NaN
    terminal      ::Vector{AbstractTerminal} = AbstractTerminal[]
    p_chg_max        ::NetworkQuantity{Float64} = 0.0
    p_dch_max     ::NetworkQuantity{Float64} = 0.0
    η_chg    ::Float64                  = 1.0
    η_dch ::Float64                  = 1.0
    exact       ::Exclusion                = RELAXED
    k_cycl_max::Float64                  = Inf
    e_cycl_init::Vector{Tuple{Float64,Float64}} = Tuple{Float64,Float64}[]
    c_chg      ::NetworkQuantity{Float64} = 0.0
    c_dch      ::NetworkQuantity{Float64} = 0.0
    c_cycl           ::Float64                  = 0.0
    net_inflow           ::NetworkQuantity{Float64} = 0.0
    q_min                 ::NetworkQuantity{Float64} = 0.0
    q_max                 ::NetworkQuantity{Float64} = 0.0
    s_max                 ::NetworkQuantity{Float64} = Inf
    c_up              ::NetworkQuantity{Float64} = 0.0
    c_dn              ::NetworkQuantity{Float64} = 0.0
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
    ([nw_solution(result, n)["unit"]["3"]["p_chg"] for n in steps],
     [nw_solution(result, n)["unit"]["3"]["p_dch"] for n in steps],
     [nw_solution(result, n)["unit"]["3"]["e_stor"]  for n in steps])

"""
Three steps of a must-run surplus at a node that charges 500 to spill it. A full
battery with losses is paid to burn energy there, by charging and discharging in
the same step, unless something keeps it from.
"""
function surplus_network(battery; steps = 3)
    dim = Dimension(:time => steps)

    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, v_magn_set = 1.0),
                               2 => Node(; id = 2))
    E = Dict{Int,AbstractEdge}(1 => Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.01))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, p_min = 0.5, p_max = 0.5, q_min = -5.0, q_max = 5.0,
                       c = [0.0, 0.0]),
        2 => FixedLoad(; id = 2, node = 2, p_set = 0.2, q_set = 0.05),
        3 => battery,
        4 => Spill(; id = 4, node = 2))

    return NetworkData(Network(I, E, U; dim); name = "surplus", s_base_mva = 100.0)
end

"a full battery with losses of ten per cent each way, for `surplus_network`"
surplus_battery(; kw...) = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.5,
                                   p_chg_max = 0.2, p_dch_max = 0.2, η_chg = 0.9, η_dch = 0.9, kw...)

"""
A two node network whose cheap generator carries an energy limit, with an
expensive one behind the load to pick up whatever the limit will not let it
produce. The linearized formulation is lossless, so every number below is exact.
"""
function allocation_network(prices, limit; period::Union{Nothing,Int} = nothing)
    dim = Dimension(:time => length(prices))
    period === nothing || (dim_meta(dim, :time)[:period_length] = period)

    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, v_magn_set = 1.0),
                               2 => Node(; id = 2))
    E = Dict{Int,AbstractEdge}(1 => Branch(; id = 1, terminals = [1, 2],
                                           r = 0.0, x = 0.01))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, p_max = 5.0, q_min = -5.0, q_max = 5.0,
                       e_per_max = limit,
                       c = nw_vector(dim, [[0.0, p] for p in prices])),
        2 => Generator(; id = 2, node = 2, p_max = 5.0, q_min = -5.0, q_max = 5.0,
                       c = [0.0, 200.0]),
        3 => FixedLoad(; id = 3, node = 2, p_set = 0.20, q_set = 0.05))

    return NetworkData(Network(I, E, U; dim); name = "allocation", s_base_mva = 100.0)
end

const PRICES = [10.0, 100.0, 50.0]

@testset "units that couple network indices" begin

    @testset "a flexible load moves demand to the cheap step" begin
        flat = FlexibleLoad(; id = 3, node = 2, p_nom = 0.10, q_nom = 0.02,
                            p_min = 0.0, p_max = 0.15)
        data = price_network(PRICES; extra = Dict{Int,AbstractUnit}(3 => flat))

        result = quiet(() -> solve_model(data, OptimalPowerFlowProblem,
                                         IVRFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED

        pd = [nw_solution(result, n)["unit"]["3"]["p_set"] for n in 1:3]

        # it fills the cheapest step to the brim, then prefers the next cheapest
        @test pd[1] ≈ 0.15 atol = 1e-5
        @test pd[3] > pd[2]
        @test pd[2] < 1e-5

        # and it takes exactly the energy the nominal profile would have taken
        @test sum(pd) ≈ 3 * 0.10 atol = 1e-6

        # reactive demand follows at the nominal power factor
        for n in 1:3
            @test nw_solution(result, n)["unit"]["3"]["q_set"] ≈
                  0.2 * nw_solution(result, n)["unit"]["3"]["p_set"] atol = 1e-8
        end
    end

    @testset "a flexible load balances its energy per period" begin
        # six steps, cheap-dear-cheap in each half, grouped into two days: the
        # load may shift within a day but may not borrow energy from the other
        prices = [10.0, 100.0, 50.0, 10.0, 100.0, 50.0]
        flat   = FlexibleLoad(; id = 3, node = 2, p_nom = 0.10, q_nom = 0.02,
                              p_min = 0.0, p_max = 0.15)
        data   = price_network(prices; extra = Dict{Int,AbstractUnit}(3 => flat))
        dim_meta(dimension(data), :time)[:period_length] = 3

        result = quiet(() -> solve_model(data, OptimalPowerFlowProblem,
                                         LPFFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        pd = [nw_solution(result, n)["unit"]["3"]["p_set"] for n in 1:6]

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
        @test sum(nw_solution(loose, n)["unit"]["3"]["p_set"] for n in 1:6) ≈ 6 * 0.10 atol = 1e-6
        @test loose["objective"] <= result["objective"] + 1e-8
    end

    @testset "a flexible load is fixed in a load flow" begin
        flat = FlexibleLoad(; id = 3, node = 2, p_nom = 0.10, q_nom = 0.02,
                            p_min = 0.0, p_max = 0.15)
        data = price_network(PRICES; extra = Dict{Int,AbstractUnit}(3 => flat))

        result = quiet(() -> solve_model(data, LoadFlowProblem, IVRFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        for n in 1:3
            @test nw_solution(result, n)["unit"]["3"]["p_set"] ≈ 0.10 atol = 1e-8
        end
    end

    @testset "a storage unit arbitrages the price" begin
        battery = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                          p_chg_max = 0.2, p_dch_max = 0.2,
                          η_chg = 0.95, η_dch = 0.95)
        data = price_network(PRICES; extra = Dict{Int,AbstractUnit}(3 => battery))

        result = quiet(() -> solve_model(data, OptimalPowerFlowProblem,
                                         IVRFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED

        psc = [nw_solution(result, n)["unit"]["3"]["p_chg"] for n in 1:3]
        psd = [nw_solution(result, n)["unit"]["3"]["p_dch"] for n in 1:3]
        es  = [nw_solution(result, n)["unit"]["3"]["e_stor"]  for n in 1:3]

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
        plain = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                        p_chg_max = 0.2, p_dch_max = 0.2)
        free  = quiet(() -> solve_model(arbitrage_network(plain), OptimalPowerFlowProblem,
                                        LPFFormulation, OPTIMIZER))
        psc, psd, _ = storage_path(free, 1:2)
        @test psc[1] ≈ 0.2 atol = 1e-6
        @test psd[2] ≈ 0.2 atol = 1e-6
        @test free["objective"] ≈ 4.0 atol = 1e-4

        # a throughput price below 90 per pu leaves the arbitrage worth doing and
        # simply charges for it
        cheap = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                        p_chg_max = 0.2, p_dch_max = 0.2, c_dch = 50.0)
        result = quiet(() -> solve_model(arbitrage_network(cheap), OptimalPowerFlowProblem,
                                         LPFFormulation, OPTIMIZER))
        @test storage_path(result, 1:2)[2][2] ≈ 0.2 atol = 1e-6
        @test result["objective"] ≈ 4.0 + 50.0 * 0.2 atol = 1e-4

        # above it the battery is better off doing nothing at all
        dear = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                       p_chg_max = 0.2, p_dch_max = 0.2, c_dch = 100.0)
        idle = quiet(() -> solve_model(arbitrage_network(dear), OptimalPowerFlowProblem,
                                       LPFFormulation, OPTIMIZER))
        @test storage_path(idle, 1:2)[2][2] < 1e-6
        @test idle["objective"] ≈ 22.0 atol = 1e-4
    end

    # The same 90 per pu against a price on each side. The battery buys 0.2 and
    # sells 0.2, so a price on one side costs it 0.2 times that price and a price
    # on both of them twice that.
    @testset "a battery pays on the way in as well as on the way out" begin
        priced(; kw...) = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                                  p_chg_max = 0.2, p_dch_max = 0.2, kw...)
        solved(st) = quiet(() -> solve_model(arbitrage_network(st), OptimalPowerFlowProblem,
                                             LPFFormulation, OPTIMIZER))

        @test solved(priced(c_chg = 40.0))["objective"] ≈ 4.0 + 40.0 * 0.2 atol = 1e-4
        @test solved(priced(c_chg = 40.0, c_dch = 40.0))["objective"] ≈ 4.0 + 80.0 * 0.2 atol = 1e-4

        # 50 and 50 are worth 100 per pu, more than the 90 the arbitrage is
        idle = solved(priced(c_chg = 50.0, c_dch = 50.0))
        @test storage_path(idle, 1:2)[1][1] < 1e-6
        @test idle["objective"] ≈ 22.0 atol = 1e-4
    end

    # The 0.2 pu arbitrage again, behind a converter that carries 0.1: half of the
    # 18 it is worth, so 22 - 9 = 13.
    @testset "a converter rating limits what a battery injects" begin
        behind(; kw...) = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                                  p_chg_max = 0.2, p_dch_max = 0.2, kw...)
        solved(st, F) = quiet(() -> solve_model(arbitrage_network(st), OptimalPowerFlowProblem,
                                                F, OPTIMIZER))

        # what the converter carries is the net injection: with efficiencies of one the
        # unit may charge and discharge at once, so the sides are free to be larger
        net_injection(result) = (path = storage_path(result, 1:2); path[2] .- path[1])

        # a limit on the active power in the linearized formulation, which has no reactive power
        limited = solved(behind(s_max = 0.1), LPFFormulation)
        @test net_injection(limited) ≈ [-0.1, 0.1] atol = 1e-6
        @test limited["objective"] ≈ 13.0 atol = 1e-4

        # the circle in the current based one, where reactive power is fixed at zero unless it is given
        circle = solved(behind(s_max = 0.1), IVRFormulation)
        @test circle["termination_status"] == JuMP.LOCALLY_SOLVED
        @test maximum(abs, net_injection(circle)) <= 0.1 + 1e-6
        @test net_injection(circle)[2] > 0.09   # and it is the rating that stops it
        @test net_injection(solved(behind(), IVRFormulation))[2] > 0.15

        # no rating is no row, and a rating is a row at every index, two of them in the linearized formulation
        for (F, rows) in ((LPFFormulation, 4), (IVRFormulation, 2))
            rated(m) = count(k -> k[2] === :cstr_stor_rating, keys(_NMB.registered_constraints(m)))
            @test rated(instantiate_model(arbitrage_network(behind()), OptimalPowerFlowProblem, F)) == 0
            @test rated(instantiate_model(arbitrage_network(behind(s_max = 0.1)),
                                          OptimalPowerFlowProblem, F)) == rows
        end

        # with reactive power free the net injection and q share the circle: maximise both
        wide = behind(e_init = 0.25, q_min = -0.2, q_max = 0.2, s_max = 0.15)
        nm   = instantiate_model(arbitrage_network(wide), OptimalPowerFlowProblem, IVRFormulation)
        JuMP.@objective(nm.model, Max, _NMB.var(nm, :p_dch, 3; nw = 1) - _NMB.var(nm, :p_chg, 3; nw = 1) +
                                       _NMB.var(nm, :q_stor, 3; nw = 1))
        JuMP.set_optimizer(nm.model, OPTIMIZER)
        JuMP.optimize!(nm.model)
        p = JuMP.value(_NMB.var(nm, :p_dch, 3; nw = 1)) - JuMP.value(_NMB.var(nm, :p_chg, 3; nw = 1))
        q = JuMP.value(_NMB.var(nm, :q_stor, 3; nw = 1))
        @test p^2 + q^2 ≈ 0.15^2 atol = 1e-6
        @test p ≈ q atol = 1e-4
    end

    @testset "a battery pays per cycle, which is not per unit of energy" begin
        # 0.2 pu out of a capacity of 0.5 is 0.4 of a cycle, so a price of 20 per
        # cycle is 40 per pu — below the 90 the arbitrage is worth
        cheap  = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                         p_chg_max = 0.2, p_dch_max = 0.2, c_cycl = 20.0)
        result = quiet(() -> solve_model(arbitrage_network(cheap), OptimalPowerFlowProblem,
                                         LPFFormulation, OPTIMIZER))
        @test storage_path(result, 1:2)[2][2] ≈ 0.2 atol = 1e-6
        @test result["objective"] ≈ 4.0 + 20.0 * 0.4 atol = 1e-4

        # and 100 per cycle is 200 per pu, which is not
        dear = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                       p_chg_max = 0.2, p_dch_max = 0.2, c_cycl = 100.0)
        idle = quiet(() -> solve_model(arbitrage_network(dear), OptimalPowerFlowProblem,
                                       LPFFormulation, OPTIMIZER))
        @test storage_path(idle, 1:2)[2][2] < 1e-6
        @test idle["objective"] ≈ 22.0 atol = 1e-4

        # the cycles are counted at every network index, on both sides of the store, so the
        # price reaches the objective where the energy moves: half of what goes in and half of
        # what comes out, over the capacity, at 20 per cycle
        nm = instantiate_model(arbitrage_network(cheap), OptimalPowerFlowProblem,
                               LPFFormulation)
        for key in (:p_chg, :p_dch)
            @test JuMP.coefficient(network_cost(nm, 2), _NMB.var(nm, key, 3; nw = 2)) ≈ 20.0 / (2 * 0.5)
            @test JuMP.coefficient(horizon_cost(nm), _NMB.var(nm, key, 3; nw = 2)) ≈ 0.0
        end
        @test period_cost(nm, Storage, 3; nw = 1) == 0.0
        @test period_cost(nm, FixedLoad, 2; nw = 1) == 0.0
    end

    @testset "a price per cycle counts the length of a step once" begin
        # a step of a quarter of an hour moves a quarter of the energy, whether the objective
        # weighs the index by its duration or not, and each side by what it puts into the store
        # or draws from it
        for weight in (nothing, 0.25)
            prop = weight === nothing ? Dict{Symbol,Any}(:duration => 0.25) :
                                        Dict{Symbol,Any}(:duration => 0.25, :weight => weight)
            dim  = Dimension(:time => [copy(prop) for _ in 1:2])
            lossy = Storage(; id = 3, node = 2, e_max = 0.5, p_chg_max = 0.2, p_dch_max = 0.2,
                            η_chg = 0.9, η_dch = 0.8, c_cycl = 20.0)
            nm = instantiate_model(price_network([10.0, 100.0]; dim, extra = Dict{Int,AbstractUnit}(3 => lossy)),
                                   OptimalPowerFlowProblem, LPFFormulation)

            paid(key) = network_weight(nm, 2) *
                        JuMP.coefficient(network_cost(nm, 2), _NMB.var(nm, key, 3; nw = 2))
            @test paid(:p_chg) ≈ 20.0 * 0.25 * 0.9 / (2 * 0.5)
            @test paid(:p_dch) ≈ 20.0 * 0.25 / (0.8 * 2 * 0.5)
        end
    end

    @testset "a cycle limit holds over any 24 hours, with a row per network index" begin
        # a limit of 0.2 cycles on a capacity of 0.5 is 0.1 pu·h counted over 24 hours, and a lossless
        # unit that charges and discharges the same amount counts that amount once
        limited = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                          p_chg_max = 0.2, p_dch_max = 0.2,
                          k_cycl_max = 0.2)
        result  = quiet(() -> solve_model(arbitrage_network(limited),
                                          OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        @test sum(storage_path(result, 1:2)[2]) ≈ 0.1 atol = 1e-6

        # with no limit the same battery moves twice as much
        plain = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                        p_chg_max = 0.2, p_dch_max = 0.2)
        free  = quiet(() -> solve_model(arbitrage_network(plain), OptimalPowerFlowProblem,
                                        LPFFormulation, OPTIMIZER))
        @test sum(storage_path(free, 1:2)[2]) ≈ 0.2 atol = 1e-6

        # an infinite limit is the absence of a row, not a row with an infinite right hand
        # side, and a finite one has a row at every network index
        loose = instantiate_model(arbitrage_network(plain), OptimalPowerFlowProblem,
                                  LPFFormulation)
        @test !any(k -> k[2] === :cstr_stor_cycle, keys(_NMB.registered_constraints(loose)))
        tight = instantiate_model(arbitrage_network(limited), OptimalPowerFlowProblem,
                                  LPFFormulation)
        @test haskey(_NMB.registered_constraints(tight), (1, :cstr_stor_cycle, 3))
        @test haskey(_NMB.registered_constraints(tight), (2, :cstr_stor_cycle, 3))

        # a row reads the steps up to its own that fit in 24 hours: eight steps of six hours
        dim  = Dimension(:time => [Dict{Symbol,Any}(:duration => 6.0) for _ in 1:8])
        nm   = instantiate_model(price_network(fill(10.0, 8); dim,
                                               extra = Dict{Int,AbstractUnit}(3 => limited)),
                                 OptimalPowerFlowProblem, LPFFormulation)
        terms(n) = length(last(_NMB.registered_constraints(nm)[(n, :cstr_stor_cycle, 3)]).func.terms)
        @test [terms(n) for n in 1:8] == [2, 4, 6, 8, 8, 8, 8, 8]
    end

    @testset "the 24 hours are not the periods" begin
        # four steps of twelve hours, dear-cheap-dear-cheap: the unit charges in the second and
        # sells in the third, which are 24 hours but not a day. It may count 0.4 pu·h in them, which is
        # 6 p_chg + 6 p_dch, whereas a limit per block of two steps would not have seen them together
        dim     = Dimension(:time => [Dict{Symbol,Any}(:duration => 12.0) for _ in 1:4])
        battery(; kw...) = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                                   p_chg_max = 0.05, p_dch_max = 0.05, kw...)
        solved(st; days = nothing) = begin
            data = price_network([100.0, 10.0, 100.0, 10.0]; dim = deepcopy(dim),
                                 extra = Dict{Int,AbstractUnit}(3 => st))
            days === nothing || (dim_meta(dimension(data), :time)[:period_length] = days)
            quiet(() -> solve_model(data, OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        end
        # what it holds at the most, which charging and discharging at once, free at no loss, cannot move
        energy(result) = maximum(storage_path(result, 1:4)[3])

        @test energy(solved(battery())) ≈ 0.5 atol = 1e-6
        @test energy(solved(battery(k_cycl_max = 0.8))) ≈ 0.4 atol = 1e-6

        # and grouping the steps into days changes nothing: it is a window of hours, not a calendar
        @test energy(solved(battery(k_cycl_max = 0.8); days = 2)) ≈ 0.4 atol = 1e-6
    end

    @testset "a cycle counts the energy into the store and the energy out of it" begin
        # 0.9 of what is charged is stored and 0.9 of what is stored is delivered, so a charge of c
        # is a delivery of 0.81 c, and the count of the pair is (0.9 c + 0.81 c / 0.9) / 2 = 0.9 c
        lossy = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                        p_chg_max = 0.2, p_dch_max = 0.2, η_chg = 0.9, η_dch = 0.9,
                        k_cycl_max = 0.2)
        result = quiet(() -> solve_model(arbitrage_network(lossy), OptimalPowerFlowProblem,
                                         LPFFormulation, OPTIMIZER))
        chg, dch, _ = storage_path(result, 1:2)
        @test sum(chg) ≈ 0.1 / 0.9 atol = 1e-6
        @test sum(dch) ≈ 0.81 * 0.1 / 0.9 atol = 1e-6
    end

    @testset "the cycles a unit has already turned count against its limit" begin
        # a unit that starts full sells at 100 in the one step, as much as 0.1 pu·h of count lets it:
        # 0.2 of discharge, which counts half of it
        battery(; kw...) = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.5,
                                   p_chg_max = 0.4, p_dch_max = 0.4, k_cycl_max = 0.2, kw...)
        sold(st) = only(storage_path(quiet(() -> solve_model(
            price_network([100.0]; extra = Dict{Int,AbstractUnit}(3 => st)),
            OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER)), 1:1)[2])

        @test sold(battery()) ≈ 0.2 atol = 1e-6

        # 0.06 turned in the hour before leaves 0.04, which is 0.08 of discharge
        @test sold(battery(e_cycl_init = [(1.0, 0.06)])) ≈ 0.08 atol = 1e-6

        # and what is turned more than 24 hours ago does not count, with the step in the 24 hours
        @test sold(battery(e_cycl_init = [(23.0, 0.06)])) ≈ 0.08 atol = 1e-6
        @test sold(battery(e_cycl_init = [(23.5, 0.06)])) ≈ 0.2 atol = 1e-6
        @test sold(battery(e_cycl_init = [(30.0, 0.06)])) ≈ 0.2 atol = 1e-6
        @test sold(battery(e_cycl_init = [(22.0, 0.06), (1.0, 0.03)])) ≈ 0.02 atol = 1e-6
        @test sold(battery(e_cycl_init = [(23.0, 0.06), (1.0, 0.03)])) ≈ 0.14 atol = 1e-6
    end

    @testset "a storage unit says when the relaxation may let it charge and discharge at once" begin
        lossy(; kw...) = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0,
                                 p_chg_max = 0.2, p_dch_max = 0.2, η_chg = 0.9, η_dch = 0.9, kw...)
        built(st, prices) = instantiate_model(
            price_network(prices; extra = Dict{Int,AbstractUnit}(3 => st)),
            OptimalPowerFlowProblem, LPFFormulation)

        # nothing is priced below zero, so nothing is said
        @test_logs min_level = Logging.Warn built(lossy(), [10.0, 100.0])

        # without losses a cycle at once moves no energy away, so there is nothing to say
        plain = Storage(; id = 3, node = 2, e_max = 0.5, p_chg_max = 0.2, p_dch_max = 0.2)
        @test_logs min_level = Logging.Warn built(plain, [-10.0, 100.0])

        # a generator that pays to run, and a lossy battery that pays nothing to cycle
        @test_logs (:warn, r"storage 3") match_mode = :any built(lossy(), [-10.0, 100.0])

        # at any step: a price below zero that comes after the first is just as paid
        @test_logs (:warn, r"storage 3") match_mode = :any built(lossy(), [10.0, 100.0, -10.0])

        # what settles it is the price on the unit itself: with losses of ten per cent a price
        # of 0.9 c_dch + c_chg / 0.9 must reach 0.2111 times the 10 the node pays to take a unit
        for priced in (lossy(c_dch = 3.0), lossy(c_chg = 3.0), lossy(exact = EXACT), lossy(exact = FROZEN))
            @test_logs min_level = Logging.Warn built(priced, [-10.0, 100.0])
        end

        # a price below that, a cycle price, or a cycle limit does not
        for unsettled in (lossy(c_dch = 2.0), lossy(c_cycl = 1.0), lossy(k_cycl_max = 1.0))
            @test_logs (:warn, r"storage 3") match_mode = :any built(unsettled, [-10.0, 100.0])
        end
        @test_logs (:warn, r"cycle limit") match_mode = :any built(lossy(k_cycl_max = 1.0), [-10.0, 100.0])

        # the price is a Spill's too: 500 to spill it puts the line at 0.2111 times 500 = 105.6
        function warns(st)
            logs, _ = Test.collect_test_logs() do
                instantiate_model(surplus_network(st), OptimalPowerFlowProblem, LPFFormulation)
            end
            return any(l -> l.level == Logging.Warn, logs)
        end
        @test warns(surplus_battery(c_dch = 100.0))
        @test !warns(surplus_battery(c_dch = 120.0))
        @test !warns(surplus_battery(c_dch = 100.0, exact = EXACT))
    end

    @testset "a storage unit can be kept from charging and discharging at once" begin
        highs = JuMP.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)
        solved(st) = quiet(() -> solve_model(surplus_network(st), OptimalPowerFlowProblem,
                                             LPFFormulation, highs))
        overlap(result) = (path = storage_path(result, 1:3); maximum(path[1] .* path[2]) / 0.2^2)
        binaries(nm) = JuMP.num_constraints(nm.model, JuMP.VariableRef, JuMP.MOI.ZeroOne)
        rows(nm) = count(k -> k[2] === :cstr_stor_exclusion, keys(_NMB.registered_constraints(nm)))

        # relaxed, the full battery is paid to burn what it holds: 393.00 where 426.54 is the most it can earn
        relaxed = solved(surplus_battery())
        @test relaxed["objective"] ≈ 393.00 atol = 5e-3
        @test overlap(relaxed) > 1e-5
        @test !haskey(relaxed, "relaxation_gap")

        exact = solved(surplus_battery(exact = EXACT))
        @test exact["objective"] ≈ 426.54 atol = 5e-3
        @test overlap(exact) < 1e-5
        @test exact["relaxation_gap"] ≈ exact["objective"] - relaxed["objective"] atol = 1e-6
        @test exact["dual_status"] == JuMP.NO_SOLUTION                  # it is mixed-integer now
        @test solved(surplus_battery(exact = true))["objective"] ≈ exact["objective"] atol = 1e-9

        # the binaries only where the relaxation violated are the binaries everywhere
        every = instantiate_model(surplus_network(surplus_battery()), OptimalPowerFlowProblem, LPFFormulation)
        for n in nw_ids(every)
            z = JuMP.@variable(every.model, binary = true)
            JuMP.@constraint(every.model, _NMB.var(every, :p_chg, 3; nw = n) <= 0.2 * z)
            JuMP.@constraint(every.model, _NMB.var(every, :p_dch, 3; nw = n) <= 0.2 * (1 - z))
        end
        quiet(() -> optimize_model!(every, highs))
        @test JuMP.objective_value(every.model) ≈ exact["objective"] atol = 1e-6

        # and it adds binaries only where it must, two rows each
        nm = instantiate_model(surplus_network(surplus_battery(exact = EXACT)),
                               OptimalPowerFlowProblem, LPFFormulation)
        quiet(() -> optimize_model!(nm, highs))
        @test 1 <= binaries(nm) <= 3
        @test rows(nm) == 2 * binaries(nm)
        @test !JuMP.has_duals(nm.model)

        # the line is the unit's own price: 100 leaves the gap, 130 closes it
        for (c_dch, free, tight) in ((100.0, 441.60, 446.54), (130.0, 450.0, 450.0))
            @test solved(surplus_battery(; c_dch))["objective"] ≈ free atol = 5e-3
            @test solved(surplus_battery(; c_dch, exact = EXACT))["objective"] ≈ tight atol = 5e-3
        end

        # where the relaxation is exact the model stays a linear program
        settled = instantiate_model(surplus_network(surplus_battery(c_dch = 130.0, exact = EXACT)),
                                    OptimalPowerFlowProblem, LPFFormulation)
        quiet(() -> optimize_model!(settled, highs))
        @test binaries(settled) == 0 && rows(settled) == 0
        @test JuMP.has_duals(settled.model)
        @test !haskey(settled.sol, "relaxation_gap")

        # the third value fixes the direction of each violating step: feasible, not optimal, still linear
        frozen = solved(surplus_battery(exact = FROZEN))
        @test overlap(frozen) < 1e-5
        @test exact["objective"] - 1e-6 <= frozen["objective"] <= 450.0 + 1e-6
        @test frozen["dual_status"] == JuMP.FEASIBLE_POINT
        @test frozen["relaxation_gap"] >= exact["relaxation_gap"] - 1e-6
    end

    @testset "an exact storage unit is exact in current too" begin
        juniper = JuMP.optimizer_with_attributes(
            Juniper.Optimizer, "log_levels" => Symbol[],
            "nl_solver" => JuMP.optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0,
                                                           "sb" => "yes"))
        overlap(result) = (path = storage_path(result, 1:3); maximum(path[1] .* path[2]) / 0.2^2)

        result = quiet(() -> solve_model(surplus_network(surplus_battery(exact = EXACT)),
                                         OptimalPowerFlowProblem, IVRFormulation, juniper))
        @test result["termination_status"] in (JuMP.OPTIMAL, JuMP.LOCALLY_SOLVED)
        @test overlap(result) < 1e-5
        @test result["objective"] ≈ 426.54 atol = 0.05

        # the gap is in the summary of a result that has one
        @test occursin("relaxation gap", sprint(print_summary, result))
        unrefined = quiet(() -> solve_model(surplus_network(surplus_battery()),
                                            OptimalPowerFlowProblem, IVRFormulation, OPTIMIZER))
        @test !occursin("relaxation gap", sprint(print_summary, unrefined))
    end

    @testset "a roll builds a window again when the one before it refined" begin
        highs = JuMP.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)
        roll(st) = quiet(() -> solve_rolling_horizon(surplus_network(st; steps = 4), OptimalPowerFlowProblem,
                                                     LPFFormulation, highs; horizon = 2, step = 1,
                                                     reuse = true))

        # a model that refined holds binaries and rows its successor would not have written
        relaxed = roll(surplus_battery())
        refined = roll(surplus_battery(exact = EXACT))
        @test refined["horizon"]["built"] > relaxed["horizon"]["built"]
        @test any(haskey(w, "relaxation_gap") for w in refined["horizon"]["window"])
        @test !any(haskey(w, "relaxation_gap") for w in relaxed["horizon"]["window"])
    end

    @testset "an outage of a storage unit is its status, and it holds its energy across the gap" begin
        prices = [10.0, 10.0, 100.0, 10.0, 100.0]
        dim    = Dimension(:time => 5)
        highs  = JuMP.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)

        function network(dim, prices; kw...)
            I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, v_magn_set = 1.0), 2 => Node(; id = 2))
            E = Dict{Int,AbstractEdge}(1 => Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.01))
            U = Dict{Int,AbstractUnit}(
                1 => Generator(; id = 1, node = 1, p_max = 5.0, q_min = -5.0, q_max = 5.0,
                               c = nw_vector(dim, [[0.0, p] for p in prices])),
                2 => FixedLoad(; id = 2, node = 2, p_set = 0.2, q_set = 0.0),
                3 => Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.0, p_chg_max = 0.2,
                             p_dch_max = 0.2, η_chg = 0.95, η_dch = 0.95, kw...))
            return NetworkData(Network(I, E, U; dim); name = "outage", s_base_mva = 100.0)
        end
        solved(data) = quiet(() -> solve_model(data, OptimalPowerFlowProblem, LPFFormulation, highs))
        energy(result, steps) = [nw_solution(result, n)["unit"]["3"]["e_stor"] for n in steps]

        gone = nw_vector(dim, [true, false, false, true, true])
        none = nw_vector(dim, [0.2, 0.0, 0.0, 0.2, 0.2])

        # an outage is a status, and what it does is what ratings of zero do: hold the energy
        served = solved(network(dim, prices))
        out    = solved(network(dim, prices; status = gone))
        held   = solved(network(dim, prices; p_chg_max = none, p_dch_max = none))
        @test served["objective"] ≈ 10.432 atol = 5e-3
        @test out["objective"] ≈ 28.216 atol = 5e-3
        @test out["objective"] ≈ held["objective"] atol = 1e-6
        @test energy(out, [1, 4, 5]) ≈ energy(held, [1, 4, 5]) atol = 1e-6
        @test energy(held, 1:3) ≈ fill(energy(held, 1:1)[1], 3) atol = 1e-6

        # a step out of service has no row in the solution
        @test !haskey(nw_solution(out, 2)["unit"], "3") && !haskey(nw_solution(out, 3)["unit"], "3")
        @test haskey(nw_solution(out, 4)["unit"], "3")

        # the energy is read through the gap: what it started with before the first step it is in
        # service at, what it left after
        dim4 = Dimension(:time => 4)
        nm   = instantiate_model(network(dim4, [10.0, 100.0, 10.0, 100.0]; e_init = 0.3,
                                         status = nw_vector(dim4, [false, true, false, false])),
                                 OptimalPowerFlowProblem, LPFFormulation)
        @test energy_at(nm, 3, 1) == 0.3
        @test energy_at(nm, 3, 2) === _NMB.var(nm, :e_stor, 3; nw = 2)
        @test energy_at(nm, 3, 3) === energy_at(nm, 3, 2) && energy_at(nm, 3, 4) === energy_at(nm, 3, 2)

        # a roll whose boundary falls inside the gap carries the energy it held, not the one it started with
        roll(data) = quiet(() -> solve_rolling_horizon(data, OptimalPowerFlowProblem, LPFFormulation, highs;
                                                       horizon = 3, step = 1))
        rolled = roll(network(dim, prices; status = gone))
        stalled = roll(network(dim, prices; p_chg_max = none, p_dch_max = none))
        @test rolled["objective"] ≈ stalled["objective"] atol = 1e-6
        @test energy(rolled, [1, 4, 5]) ≈ energy(stalled, [1, 4, 5]) atol = 1e-6

        # the cycle limit holds over the steps it is in service for, also when it is out at the first
        capped = network(dim4, [10.0, 100.0, 10.0, 100.0]; k_cycl_max = 0.2,
                         status = nw_vector(dim4, [false, true, true, true]))
        nm = instantiate_model(capped, OptimalPowerFlowProblem, LPFFormulation)
        @test !haskey(_NMB.registered_constraints(nm), (1, :cstr_stor_cycle, 3))
        @test haskey(_NMB.registered_constraints(nm), (2, :cstr_stor_cycle, 3))
        limited = solved(capped)
        @test sum(nw_solution(limited, n)["unit"]["3"]["p_dch"] for n in 2:4) <= 0.2 * 0.5 + 1e-6

        # a unit that asks for exactness is kept from charging and discharging at once across a gap too
        surplus = surplus_network(surplus_battery(exact = EXACT, status = nw_vector(Dimension(:time => 3), [true, false, true])))
        @test quiet(() -> solve_model(surplus, OptimalPowerFlowProblem, LPFFormulation, highs))["termination_status"] == JuMP.OPTIMAL
    end

    @testset "the end of a horizon is read through a gap" begin
        three   = Dimension(:time => 3)
        battery(; kw...) = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.2, p_chg_max = 0.2, p_dch_max = 0.2,
                                   status = nw_vector(three, [true, true, false]), kw...)
        solved(st) = quiet(() -> solve_model(price_network(PRICES; extra = Dict{Int,AbstractUnit}(3 => st)),
                                             OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))

        # out at the last step the unit holds what the step before left, and the generator serves
        # that step at 50: 2.0 for the first, the 0.2 it starts with sold at 100, 10.0 for the last
        free = solved(battery())
        @test free["objective"] ≈ 12.0 atol = 1e-4
        @test nw_solution(free, 2)["unit"]["3"]["e_stor"] ≈ 0.0 atol = 1e-6
        @test !haskey(nw_solution(free, 3)["unit"], "3")

        # a pin is on what it holds: 0.4 is charged at 10 and not sold at 100, 4.0 and 20.0 and the last 10.0
        pinned = solved(battery(terminal = Pin(0.4)))
        @test pinned["objective"] ≈ 34.0 atol = 1e-3
        @test nw_solution(pinned, 2)["unit"]["3"]["e_stor"] ≈ 0.4 atol = 1e-6
        @test solved(battery(terminal = Floor(0.2)))["objective"] ≈ 14.0 atol = 1e-4

        # a price on the energy it holds: 150 is worth more than the 100 for selling it, and more
        # than charging at 100 costs, so it holds the 0.5 it can: 44 for the energy, 75 back
        valued = solved(battery(terminal = Value(150.0)))
        @test valued["objective"] ≈ -31.0 atol = 1e-3
        @test nw_solution(valued, 2)["unit"]["3"]["e_stor"] ≈ 0.5 atol = 1e-6
        @test solved(battery(terminal = Soft(0.4; c_dn = 1000.0)))["objective"] ≈ 34.0 atol = 1e-3

        # a unit that is out all the time has nothing to end on, and is asked nothing
        absent = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.2, p_chg_max = 0.2, p_dch_max = 0.2,
                         status = false, terminal = [Pin(0.4)])
        result = solved(absent)
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test result["objective"] ≈ 0.2 * (10.0 + 100.0 + 50.0) atol = 1e-4
    end

    @testset "energy may arrive from outside the model" begin
        # a plain battery has no inflow, and the hook says so
        nm = instantiate_model(arbitrage_network(
                 Storage(; id = 3, node = 2, e_max = 0.5,
                         p_chg_max = 0.2, p_dch_max = 0.2)),
             OptimalPowerFlowProblem, LPFFormulation)
        @test inflow(unit(nm, 3; nw = 1), nm, 1) == 0.0

        # a subtype that overrides one line gets the whole balance for free:
        # 0.05 pu·h arrives every step, is held through the cheap one and given
        # back in the dear one
        river = InflowStorage(; id = 3, node = 2, e_max = 0.5,
                              e_init = 0.0, p_chg_max = 0.0,
                              p_dch_max = 0.2, net_inflow = 0.05)
        data   = price_network(PRICES; extra = Dict{Int,AbstractUnit}(3 => river))
        result = quiet(() -> solve_model(data, OptimalPowerFlowProblem, LPFFormulation,
                                         OPTIMIZER))

        _, psd, es = storage_path(result, 1:3)
        @test psd ≈ [0.0, 0.10, 0.05] atol = 1e-6
        @test es  ≈ [0.05, 0.0, 0.0]  atol = 1e-6

        # nothing of the inflow is lost or invented over the horizon
        @test sum(psd) ≈ 3 * 0.05 atol = 1e-6
    end


    @testset "a battery keeps a floor of energy" begin
        # without a floor the unit sells down to empty in the last step, with 0.1
        # held back that step is 0.1 short and the generator makes it at 50
        reserve = Storage(; id = 3, node = 2, e_max = 0.5, e_min = 0.1, e_init = 0.2,
                          p_chg_max = 0.2, p_dch_max = 0.2)
        data    = price_network(PRICES; extra = Dict{Int,AbstractUnit}(3 => reserve))
        held    = quiet(() -> solve_model(data, OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))

        @test storage_path(held, 1:3)[3] ≈ [0.4, 0.2, 0.1] atol = 1e-6
        @test held["objective"] ≈ 4.0 + 0.1 * 50.0 atol = 1e-4

        nm = instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation)
        @test JuMP.lower_bound(_NMB.var(nm, :e_stor, 3; nw = 1)) == 0.1
    end

    @testset "a horizon can be asked to end where it started" begin
        # the battery starts on 0.2 and may end wherever it likes: it charges in
        # the cheap step, sells in the dear one and sells the rest in the last
        loose = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.2,
                        p_chg_max = 0.2, p_dch_max = 0.2)
        free   = quiet(() -> solve_model(price_network(PRICES;
                                             extra = Dict{Int,AbstractUnit}(3 => loose)),
                                         OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        @test storage_path(free, 1:3)[3] ≈ [0.4, 0.2, 0.0] atol = 1e-6
        @test free["objective"] ≈ 4.0 atol = 1e-4

        # asked to hand back 0.2, it stops one step short and pays for the step
        # it can no longer cover
        pinned = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.2,
                         e_fin = 0.2, p_chg_max = 0.2, p_dch_max = 0.2)
        held   = quiet(() -> solve_model(price_network(PRICES;
                                             extra = Dict{Int,AbstractUnit}(3 => pinned)),
                                         OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        @test storage_path(held, 1:3)[3] ≈ [0.4, 0.2, 0.2] atol = 1e-6
        @test held["objective"] ≈ 14.0 atol = 1e-4

        # no target is the absence of a row, not a row against `NaN`
        open  = instantiate_model(price_network(PRICES;
                                      extra = Dict{Int,AbstractUnit}(3 => loose)),
                                  OptimalPowerFlowProblem, LPFFormulation)
        @test !haskey(_NMB.registered_constraints(open), (3, :cstr_stor_final_energy, 3))
        shut  = instantiate_model(price_network(PRICES;
                                      extra = Dict{Int,AbstractUnit}(3 => pinned)),
                                  OptimalPowerFlowProblem, LPFFormulation)
        @test haskey(_NMB.registered_constraints(shut), (3, :cstr_stor_final_energy, 3))
    end

    @testset "the end of a horizon is a list of conditions" begin
        battery(; kw...) = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.2,
                                   p_chg_max = 0.2, p_dch_max = 0.2, kw...)
        network(st) = price_network(PRICES; extra = Dict{Int,AbstractUnit}(3 => st))
        solved(st)  = quiet(() -> solve_model(network(st), OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        final_keys(st) = Set(k[2] for k in keys(_NMB.registered_constraints(
            instantiate_model(network(st), OptimalPowerFlowProblem, LPFFormulation)))
                             if startswith(String(k[2]), "cstr_stor_final"))

        # the free unit ends on 0, and a pin, a cyclic end or a floor of 0.2 hold it to 0.2: 14.0
        for held in (battery(terminal = Pin(0.2)), battery(terminal = Cyclic()),
                     battery(terminal = Floor(0.2)), battery(terminal = [Floor(0.1), Pin(0.2)]))
            result = solved(held)
            @test storage_path(result, 1:3)[3] ≈ [0.4, 0.2, 0.2] atol = 1e-6
            @test result["objective"] ≈ 14.0 atol = 1e-4
        end

        # a floor is not a pin: below what the unit would hold it costs nothing, above it the unit holds it
        floored = solved(battery(terminal = Floor(0.1)))
        @test storage_path(floored, 1:3)[3] ≈ [0.4, 0.2, 0.1] atol = 1e-6
        @test floored["objective"] ≈ 9.0 atol = 1e-4
        @test solved(battery(terminal = Floor(0.0)))["objective"] ≈ 4.0 atol = 1e-4

        # a value on the energy left: the last step sells at 50, so below it the unit sells
        # what it has and above it holds that and charges more
        sells = solved(battery(terminal = Value(40.0)))
        @test storage_path(sells, 1:3)[3] ≈ [0.4, 0.2, 0.0] atol = 1e-6
        @test sells["objective"] ≈ 4.0 atol = 1e-4
        keeps = solved(battery(terminal = Value(60.0)))
        @test storage_path(keeps, 1:3)[3] ≈ [0.4, 0.2, 0.4] atol = 1e-6
        @test keeps["objective"] ≈ 0.0 atol = 1e-4

        # a price on missing the target: 30 a pu·h short is cheaper than 50 for the energy, 80 is not
        cheap = solved(battery(terminal = Soft(0.2; c_dn = 30.0)))
        @test storage_path(cheap, 1:3)[3] ≈ [0.4, 0.2, 0.0] atol = 1e-6
        @test cheap["objective"] ≈ 10.0 atol = 1e-4
        for dear in (Soft(0.2; c_dn = 80.0), Soft(0.2; c_up = 1.0, c_dn = 80.0))
            result = solved(battery(terminal = dear))
            @test storage_path(result, 1:3)[3] ≈ [0.4, 0.2, 0.2] atol = 1e-6
            @test result["objective"] ≈ 14.0 atol = 1e-4
        end

        # a quadratic price on the miss: 50 x + 200 x^2 is least at x = -0.125, so the unit ends on 0.075
        bent = solved(battery(terminal = Quad(0.2; weight = 200.0)))
        @test storage_path(bent, 1:3)[3][end] ≈ 0.075 atol = 1e-4
        @test bent["objective"] ≈ 10.875 atol = 1e-3

        # only what a condition needs is written: a price on the energy needs no row, a floor one of its own
        @test isempty(final_keys(battery()))
        @test final_keys(battery(terminal = Pin(0.2))) == Set([:cstr_stor_final_energy])
        @test final_keys(battery(e_fin = 0.2)) == Set([:cstr_stor_final_energy])
        @test final_keys(battery(terminal = Floor(0.2))) == Set([:cstr_stor_final_limit])
        @test final_keys(battery(terminal = Soft(0.2; c_dn = 1.0))) == Set([:cstr_stor_final_balance])
        @test isempty(final_keys(battery(terminal = Value(60.0))))
        @test isempty(final_keys(battery(terminal = Quad(0.2; weight = 1.0))))
    end

    @testset "a target the ratings cannot reach has no answer" begin
        # 0.5 asked of a unit that starts empty and may charge 0.2 a step, over
        # two steps: a pin is a pin, and the honest answer is that there is none
        unreachable = Storage(; id = 3, node = 2, e_max = 0.5,
                              e_init = 0.0, e_fin = 0.5,
                              p_chg_max = 0.2, p_dch_max = 0.2)
        result = quiet(() -> solve_model(arbitrage_network(unreachable),
                                         OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        @test result["termination_status"] != JuMP.LOCALLY_SOLVED

        @test_throws ArgumentError Storage(; id = 3, node = 2, e_fin = -1.0)
        @test isnan(Storage(; id = 3, node = 2).e_fin)
    end

    @testset "only the window that closes a horizon carries its target" begin
        pinned = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.2,
                         e_fin = 0.2, p_chg_max = 0.2, p_dch_max = 0.2)

        # the target is released, and nothing else about the unit is touched
        released = interior_state(pinned)
        @test isnan(released.e_fin)
        @test released.e_init == pinned.e_init
        @test released.e_max == pinned.e_max
        @test released.p_chg_max == pinned.p_chg_max

        # a unit with no target, and anything that is not a storage unit, is
        # returned as it is
        loose = Storage(; id = 3, node = 2, e_max = 0.5)
        @test interior_state(loose) === loose
        @test interior_state(Node(; id = 1)) isa Node

        # a pin, a cyclic end and a floor belong to the end of the problem; a price on the end
        # belongs to the end of every window, which is what it is for
        kept = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.2, p_chg_max = 0.2, p_dch_max = 0.2,
                       terminal = [Floor(0.1), Value(90.0)])
        @test only(interior_state(kept).terminal) isa Value
        @test isempty(interior_state(Storage(; id = 3, node = 2, e_max = 0.5, terminal = Cyclic())).terminal)
        @test isempty(interior_state(Storage(; id = 3, node = 2, e_max = 0.5, terminal = [Pin(0.2), Floor(0.1)])).terminal)
        for priced in (Soft(0.2; c_dn = 1.0), Quad(0.2; weight = 1.0))
            st = Storage(; id = 3, node = 2, e_max = 0.5, terminal = priced)
            @test only(interior_state(st).terminal) isa typeof(priced)
        end
        @test interior_state(kept) !== kept
    end

    @testset "a price on the end of every window stops a roll from draining the unit" begin
        prices = [10.0, 10.0, 10.0, 10.0, 10.0, 100.0, 100.0, 100.0]
        drain(terminal) = price_network(prices; extra = Dict{Int,AbstractUnit}(3 => Storage(;
            id = 3, node = 2, e_max = 0.5, e_init = 0.0, p_chg_max = 0.2, p_dch_max = 0.2,
            η_chg = 0.95, η_dch = 0.95, terminal)))
        # a simplex solver, which picks a vertex among equal costs where an interior point picks the middle
        highs   = JuMP.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)
        perfect = quiet(() -> solve_model(drain(AbstractTerminal[]), OptimalPowerFlowProblem,
                                          LPFFormulation, highs))["objective"]
        extra(h, terminal = AbstractTerminal[]) = quiet(() -> solve_rolling_horizon(
            drain(terminal), OptimalPowerFlowProblem, LPFFormulation, highs;
            horizon = h, step = 1))["objective"] - perfect

        # with no price on the end a roll spends the energy before a peak it cannot see
        @test perfect ≈ 27.763 atol = 5e-3
        @test [extra(h) for h in 2:5] ≈ [26.2, 10.1, 8.4, 0.0] atol = 0.1

        # priced below what the peak pays after the losses, 100 x 0.95 = 95, it does not
        @test all(abs(extra(h, Value(90.0))) < 1e-6 for h in 2:5)

        # priced above it the unit keeps its energy to the end and the roll pays for the steps it
        # did not sell, 47.5 for 0.5 pu·h at 95; the value it keeps is not in what a roll reports
        @test extra(3, Value(500.0)) ≈ 47.5 atol = 1e-3
    end


    # Four steps of 0.2 pu, cheap-dear-cheap-dear at 10 and 100, with a generator
    # at 200 behind the load to make up whatever the limit will not allow.
    #
    #   no limit        : 10(.2) + 100(.2) + 10(.2) + 100(.2)            = 44
    #   0.3 per horizon : the 0.3 goes to the two cheap steps, 200 pays for
    #                     0.2 + 0.1 + 0.2 of the rest                     = 103
    #   0.3 per day     : 0.3 in each half, 200 pays for 0.1 in each      = 64
    @testset "a generator can be given an energy limit per period" begin
        prices = [10.0, 100.0, 10.0, 100.0]
        cheap(result) = [nw_solution(result, n)["unit"]["1"]["p_gen"] for n in 1:4]

        free = quiet(() -> solve_model(allocation_network(prices, Inf),
                                       OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        @test cheap(free) ≈ [0.2, 0.2, 0.2, 0.2] atol = 1e-6
        @test free["objective"] ≈ 44.0 atol = 1e-4

        # one period spanning the horizon: the allowance goes to the cheap steps
        loose = quiet(() -> solve_model(allocation_network(prices, 0.3),
                                        OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        pg = cheap(loose)
        @test sum(pg) ≈ 0.3 atol = 1e-6
        @test pg[2] < 1e-6
        @test pg[4] < 1e-6
        @test loose["objective"] ≈ 103.0 atol = 1e-4

        # grouped into two days, it gets the same allowance in each of them
        grouped = quiet(() -> solve_model(allocation_network(prices, 0.3; period = 2),
                                          OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        pg = cheap(grouped)
        @test sum(pg[1:2]) ≈ 0.3 atol = 1e-6
        @test sum(pg[3:4]) ≈ 0.3 atol = 1e-6
        @test grouped["objective"] ≈ 64.0 atol = 1e-4

        # one row per limited generator per period, and none for the others
        nm = instantiate_model(allocation_network(prices, 0.3; period = 2),
                               OptimalPowerFlowProblem, LPFFormulation)
        @test haskey(_NMB.registered_constraints(nm), (1, :cstr_gen_energy, 1))
        @test haskey(_NMB.registered_constraints(nm), (3, :cstr_gen_energy, 1))
        @test !haskey(_NMB.registered_constraints(nm), (2, :cstr_gen_energy, 1))
        @test !haskey(_NMB.registered_constraints(nm), (1, :cstr_gen_energy, 2))

        # an infinite limit is the absence of a row, not a row against infinity
        open = instantiate_model(allocation_network(prices, Inf), OptimalPowerFlowProblem,
                                 LPFFormulation)
        @test !haskey(_NMB.registered_constraints(open), (1, :cstr_gen_energy, 1))

        @test_throws ArgumentError Generator(; id = 1, node = 1,
                                             e_per_max = -1.0)
        @test Generator(; id = 1, node = 1).e_per_max == Inf
    end

    @testset "a time coupled unit says so when there is no time" begin
        for cmp in (FlexibleLoad(; id = 3, node = 2, p_nom = 0.1, p_max = 0.2),
                    Storage(; id = 3, node = 2, e_max = 0.5,
                            p_chg_max = 0.2, p_dch_max = 0.2),
                    Generator(; id = 3, node = 2, p_max = 1.0,
                              e_per_max = 0.5))
            I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF), 2 => Node(; id = 2))
            E = Dict{Int,AbstractEdge}(1 => Branch(; id = 1, terminals = [1, 2],
                                                   r = 0.001, x = 0.01))
            U = Dict{Int,AbstractUnit}(1 => Generator(; id = 1, node = 1, p_max = 5.0),
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
