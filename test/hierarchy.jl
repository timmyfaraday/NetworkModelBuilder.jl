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
