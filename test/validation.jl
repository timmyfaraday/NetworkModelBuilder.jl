################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.12.8 - the constructors refuse input a model cannot use                   #
# v0.13.0 - the length of a branch may be NaN, and is by default               #
# v0.13.0 - a branch has one entry per terminal, and two or more terminals     #
# v0.14.0 - the fields follow the nomenclature                                 #
# v0.15.1 - a storage unit is refused what it cannot use, and checked          #
# v0.15.2 - a storage unit's converter rating                                  #
# v0.15.3 - a storage unit's s_max is positive, never zero                     #
# v0.15.3 - exact keeps charging and discharging at once out                   #
################################################################################

# An impossible value used to travel on to the solver, which answered
# `INFEASIBLE`, or put a `NaN` in a row, with nothing pointing at the component.
# Each constructor now refuses it and says which component and what.

"the `ArgumentError` that `f` raises, or `nothing` where it raises none"
function refusal(f)
    try
        f()
    catch e
        e isa ArgumentError && return e
        rethrow()
    end

    return nothing
end

"""
A two node network over `dim` with a generator at the reference node, a load, and
`storage` at the load node as unit 3: the smallest data a storage check runs over.
"""
function bounded_network(dim::Dimension, storage::AbstractStorage)
    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, v_magn_set = 1.0),
                               2 => Node(; id = 2))
    E = Dict{Int,AbstractEdge}(1 => Branch(; id = 1, terminals = [1, 2], r = 0.0, x = 0.01))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, p_max = 5.0, q_min = -5.0, q_max = 5.0,
                       c = [0.0, 10.0]),
        2 => FixedLoad(; id = 2, node = 2, p_set = 0.2, q_set = 0.0),
        3 => storage)

    return NetworkData(Network(I, E, U; dim); name = "bounded", s_base_mva = 100.0)
end

@testset "validation" begin

    @testset "a node" begin
        @test_throws ArgumentError Node(; id = 1, v_magn_min = 1.1, v_magn_max = 0.9)
        @test_throws ArgumentError Node(; id = 1, v_magn_min = -1.0)
        @test_throws ArgumentError Node(; id = 1, v_magn_min = NaN)
        @test_throws ArgumentError Node(; id = 1, v_magn_max = NaN)
        @test_throws ArgumentError Node(; id = 1, v_base_kv = -380.0)
        @test_throws ArgumentError Node(; id = 1, v_base_kv = NaN)
        @test_throws ArgumentError Node(; id = 1, v_magn_set = NaN)
        @test_throws ArgumentError Node(; id = 1, v_angl_set = Inf)

        # a profile is refused at the one network index that breaks it
        dim = Dimension(:time => 3)
        @test_throws ArgumentError Node(; id = 1, v_magn_set = nw_vector(dim, [1.0, NaN, 1.0]))
        @test_throws ArgumentError Node(; id = 1, v_magn_min = nw_vector(dim, [0.9, 1.2, 0.9]), v_magn_max = 1.1)

        # and it says which node and what
        err = refusal(() -> Node(; id = 4, v_magn_min = 1.1, v_magn_max = 0.9))
        @test err isa ArgumentError
        @test occursin("node 4", err.msg) && occursin("v_magn_min", err.msg)

        # what real data carries is not refused: Matpower's case14 gives every bus a v_base_kv of 0
        @test Node(; id = 1, v_base_kv = 0.0).v_base_kv == 0.0
        @test Node(; id = 1, v_magn_min = 0.0).v_magn_min == 0.0
        data = quiet(() -> parse_file(case("case14")))
        @test all(n -> n.v_base_kv == 0.0, values(nodes(network(data))))
    end

    @testset "a generator" begin
        @test_throws ArgumentError Generator(; id = 1, node = 1, p_min = 2.0, p_max = 1.0)
        @test_throws ArgumentError Generator(; id = 1, node = 1, q_min = 1.0, q_max = -1.0)
        @test_throws ArgumentError Generator(; id = 1, node = 1, p_max = NaN)
        @test_throws ArgumentError Generator(; id = 1, node = 1, p_min = NaN)
        @test_throws ArgumentError Generator(; id = 1, node = 1, q_max = NaN)
        @test_throws ArgumentError Generator(; id = 1, node = 1, p_set = NaN)
        @test_throws ArgumentError Generator(; id = 1, node = 1, q_set = Inf)
        @test_throws ArgumentError Generator(; id = 1, node = 1, v_magn_set = NaN)
        @test_throws ArgumentError Generator(; id = 1, node = 1, c = [NaN])
        @test_throws ArgumentError Generator(; id = 1, node = 1, c = [0.0, Inf])
        @test_throws ArgumentError Generator(; id = 1, node = 1, e_per_max = -1.0)

        # a profile is refused at the one network index that breaks it
        dim = Dimension(:time => 3)
        @test_throws ArgumentError Generator(; id = 1, node = 1, p_set = nw_vector(dim, [0.5, NaN, 0.5]))
        @test_throws ArgumentError Generator(; id = 1, node = 1, p_min = nw_vector(dim, [0.0, 2.0, 0.0]), p_max = 1.0)
        @test_throws ArgumentError Generator(; id = 1, node = 1,
                                             c = nw_vector(dim, [[0.0, 1.0], [0.0, NaN], [0.0, 1.0]]))

        err = refusal(() -> Generator(; id = 7, node = 1, p_min = 2.0, p_max = 1.0))
        @test err isa ArgumentError
        @test occursin("generator 7", err.msg) && occursin("p_min", err.msg)

        # an unbounded limit, a pinned one and the default price are not refused
        @test Generator(; id = 1, node = 1).p_max == Inf
        @test Generator(; id = 1, node = 1).q_min == -Inf
        @test Generator(; id = 1, node = 1, p_min = 0.4, p_max = 0.4).p_min == 0.4
        @test isnan(Generator(; id = 1, node = 1).c_up)
    end

    @testset "a load and a shunt" begin
        @test_throws ArgumentError FixedLoad(; id = 1, node = 1, p_set = NaN)
        @test_throws ArgumentError FixedLoad(; id = 1, node = 1, q_set = Inf)
        @test_throws ArgumentError Shunt(; id = 1, node = 1, g = NaN)
        @test_throws ArgumentError Shunt(; id = 1, node = 1, b = Inf)

        dim = Dimension(:time => 3)
        @test_throws ArgumentError FixedLoad(; id = 1, node = 1, p_set = nw_vector(dim, [0.5, NaN, 0.5]))
        @test_throws ArgumentError Shunt(; id = 1, node = 1, b = nw_vector(dim, [0.1, 0.1, Inf]))

        err = refusal(() -> FixedLoad(; id = 5, node = 1, p_set = NaN))
        @test err isa ArgumentError
        @test occursin("load 5", err.msg)
        err = refusal(() -> Shunt(; id = 6, node = 1, b = NaN))
        @test err isa ArgumentError
        @test occursin("shunt 6", err.msg)

        # a negative demand is a load that injects, a negative susceptance an inductor: neither is refused
        @test FixedLoad(; id = 1, node = 1, p_set = -0.3).p_set == -0.3
        @test Shunt(; id = 1, node = 1, b = -0.19).b == -0.19
    end

    @testset "a storage unit" begin
        @test_throws ArgumentError Storage(; id = 1, node = 1, p_chg_max = -0.1)
        @test_throws ArgumentError Storage(; id = 1, node = 1, p_dch_max = -0.1)
        @test_throws ArgumentError Storage(; id = 1, node = 1, p_chg_max = NaN)
        @test_throws ArgumentError Storage(; id = 1, node = 1, s_max = -0.1)
        @test_throws ArgumentError Storage(; id = 1, node = 1, s_max = 0.0)
        @test_throws ArgumentError Storage(; id = 1, node = 1, s_max = NaN)
        @test_throws ArgumentError Storage(; id = 1, node = 1, e_max = -0.5)
        @test_throws ArgumentError Storage(; id = 1, node = 1, e_min = -0.1, e_max = 0.5)
        @test_throws ArgumentError Storage(; id = 1, node = 1, e_min = 0.6, e_max = 0.5)
        @test_throws ArgumentError Storage(; id = 1, node = 1, e_init = NaN)
        @test_throws ArgumentError Storage(; id = 1, node = 1, η_chg = 0.0)
        @test_throws ArgumentError Storage(; id = 1, node = 1, η_dch = 1.1)
        @test_throws ArgumentError Storage(; id = 1, node = 1, c_chg = -1.0)
        @test_throws ArgumentError Storage(; id = 1, node = 1, c_dch = -1.0)
        @test_throws ArgumentError Storage(; id = 1, node = 1, c_chg = NaN)
        @test_throws ArgumentError Storage(; id = 1, node = 1, c_dch = Inf)
        @test_throws ArgumentError Storage(; id = 1, node = 1, c_cycl = Inf)
        @test_throws ArgumentError Storage(; id = 1, node = 1, c_up = NaN)
        @test_throws ArgumentError Storage(; id = 1, node = 1, c_dn = Inf)

        # the pair is what is refused: a sum below zero pays the solver to move the unit
        @test_throws ArgumentError Storage(; id = 1, node = 1, c_up = 10.0, c_dn = -30.0)

        # a profile is refused at the one network index that breaks it
        dim = Dimension(:time => 3)
        @test_throws ArgumentError Storage(; id = 1, node = 1, e_max = nw_vector(dim, [0.5, 0.5, -0.1]))
        @test_throws ArgumentError Storage(; id = 1, node = 1, s_max = nw_vector(dim, [0.2, -0.2, 0.2]))
        @test_throws ArgumentError Storage(; id = 1, node = 1, s_max = nw_vector(dim, [0.2, 0.0, 0.2]))
        @test_throws ArgumentError Storage(; id = 1, node = 1, exact = EXACT,
                                           p_dch_max = nw_vector(dim, [0.2, Inf, 0.2]))
        @test_throws ArgumentError Storage(; id = 1, node = 1, e_min = nw_vector(dim, [0.0, 0.6, 0.0]), e_max = 0.5)
        @test_throws ArgumentError Storage(; id = 1, node = 1, p_dch_max = nw_vector(dim, [0.2, -0.2, 0.2]))
        @test_throws ArgumentError Storage(; id = 1, node = 1, c_dch = nw_vector(dim, [1.0, -1.0, 1.0]))
        @test_throws ArgumentError Storage(; id = 1, node = 1, c_up = 10.0,
                                           c_dn = nw_vector(dim, [10.0, -30.0, 10.0]))

        # a unit that cannot inject is out of service, and `status` says so
        err = refusal(() -> Storage(; id = 7, node = 1, s_max = 0.0))
        @test err isa ArgumentError
        @test occursin("storage 7", err.msg) && occursin("status", err.msg)

        err = refusal(() -> Storage(; id = 7, node = 1, c_up = 10.0, c_dn = -30.0))
        @test err isa ArgumentError
        @test occursin("storage 7", err.msg) && occursin("c_up", err.msg)

        # a payback on one side is a price, and an energy held above the capacity is
        # for `check_storage` to see, at the index it is held
        @test Storage(; id = 1, node = 1, c_up = 10.0, c_dn = -5.0).c_dn == -5.0
        @test Storage(; id = 1, node = 1, c_up = -3.0, c_dn = 3.0).c_up == -3.0
        @test Storage(; id = 1, node = 1, e_max = 0.5, e_init = 0.6).e_init == 0.6
        @test Storage(; id = 1, node = 1, e_init = -1e-12).e_init == -1e-12    # what a solver hands the next window
        @test Storage(; id = 1, node = 1).e_min == 0.0
        @test Storage(; id = 1, node = 1).s_max == Inf          # no converter limit unless given
        @test Storage(; id = 1, node = 1, s_max = 0.2).s_max == 0.2

        # `exact` says how charging and discharging at once is kept out, and takes a Bool as `pst` does
        @test Storage(; id = 1, node = 1).exact === RELAXED
        @test Storage(; id = 1, node = 1, exact = true).exact === EXACT
        @test Storage(; id = 1, node = 1, exact = false).exact === RELAXED
        @test Storage(; id = 1, node = 1, exact = FROZEN).exact === FROZEN

        # what is excluded is measured against the ratings, and a binary row is big-M over them
        @test Storage(; id = 1, node = 1, p_chg_max = Inf, p_dch_max = 0.2).exact === RELAXED
        @test_throws ArgumentError Storage(; id = 1, node = 1, p_chg_max = Inf, p_dch_max = 0.2, exact = EXACT)
        @test_throws ArgumentError Storage(; id = 1, node = 1, p_chg_max = 0.2, p_dch_max = Inf, exact = FROZEN)
        err = refusal(() -> Storage(; id = 7, node = 1, p_dch_max = Inf, exact = EXACT))
        @test err isa ArgumentError && occursin("storage 7", err.msg) && occursin("exact", err.msg)

        # a price on each side replaces the one price on the discharge, and the old
        # name is gone
        @test Storage(; id = 1, node = 1, c_chg = 2.0, c_dch = 3.0).c_chg == 2.0
        @test_throws MethodError Storage(; id = 1, node = 1, c_thru = 1.0)
    end

    @testset "a storage unit is checked against its bounds before the build" begin
        dim = Dimension(:time => 3)
        data(st) = bounded_network(dim, st)
        battery(; kw...) = Storage(; id = 3, node = 2, e_max = 0.5, e_init = 0.2,
                                   p_chg_max = 0.2, p_dch_max = 0.2, kw...)

        @test check_storage(data(battery(e_fin = 0.3))) === nothing
        @test check_storage(data(battery())) === nothing

        # held or asked for above the capacity, or below the floor
        for bad in (battery(e_init = 0.6), battery(e_init = -0.1), battery(e_fin = 0.6),
                    battery(e_min = 0.1, e_init = 0.05), battery(e_min = 0.1, e_fin = 0.05))
            @test_throws ArgumentError check_storage(data(bad))
            @test_throws ArgumentError instantiate_model(data(bad), OptimalPowerFlowProblem, LPFFormulation)
            @test_throws ArgumentError instantiate_model(data(bad), RedispatchProblem, LPFFormulation)
        end

        # a load flow holds the setpoint and has no state of charge to bound
        @test instantiate_model(data(battery(e_init = 0.6)), LoadFlowProblem, LPFFormulation) isa NetworkModel

        # it says which unit, which quantity and where
        err = refusal(() -> check_storage(data(battery(e_fin = 0.6))))
        @test err isa ArgumentError
        @test occursin("storage 3", err.msg) && occursin("e_fin", err.msg) && occursin("network index 3", err.msg)

        # the bound is the one at the index the energy is read at: the start is read
        # at the first, the target at the last
        @test check_storage(data(battery(e_max = nw_vector(dim, [0.5, 0.3, 0.5]), e_fin = 0.4))) === nothing
        @test_throws ArgumentError check_storage(data(battery(e_max = nw_vector(dim, [0.5, 0.5, 0.3]), e_fin = 0.4)))
        @test check_storage(data(battery(e_max = nw_vector(dim, [0.3, 0.5, 0.5])))) === nothing
        @test_throws ArgumentError check_storage(data(battery(e_max = nw_vector(dim, [0.1, 0.5, 0.5]))))

        # what a solver hands back is not refused for the digits it carries
        @test check_storage(data(battery(e_init = 0.5 + 1e-9))) === nothing
        @test check_storage(data(battery(e_init = -1e-9))) === nothing

        # without a `:time` dimension nothing couples, and there is nothing to check
        @test check_storage(bounded_network(Dimension(), battery(e_init = 0.6))) === nothing
    end

    @testset "a market schedule is checked against the energy and the cycle budget" begin
        dim = Dimension(:time => 3)
        scheduled(p; dim = dim, kw...) = bounded_network(dim, Storage(;
            id = 3, node = 2, e_max = 0.5, e_init = 0.5, p_chg_max = 0.5, p_dch_max = 0.5,
            η_chg = 1.0, η_dch = 1.0, p_set = p, kw...))

        # 0.3 discharged for three steps from a full 0.5 runs out in the second
        over = scheduled(0.3)
        @test scheduled_energy(over, 3) isa NetworkVector
        @test scheduled_energy(over, 3).data ≈ [0.2, -0.1, -0.4]
        @test scheduled_energy(scheduled(0.1), 3).data ≈ [0.4, 0.3, 0.2]

        @test check_storage(scheduled(0.1)) === nothing
        err = refusal(() -> check_storage(over))
        @test err isa ArgumentError
        @test occursin("storage 3", err.msg) && occursin("network index 2", err.msg)
        @test check_storage(over; schedule = false) === nothing

        # only a redispatch reads `p_set` as a schedule: an optimal power flow
        # chooses the dispatch and a load flow holds it
        @test_throws ArgumentError instantiate_model(over, RedispatchProblem, LPFFormulation)
        @test instantiate_model(over, RedispatchProblem, LPFFormulation; schedule = false) isa NetworkModel
        @test instantiate_model(over, OptimalPowerFlowProblem, LPFFormulation) isa NetworkModel
        @test instantiate_model(over, LoadFlowProblem, LPFFormulation) isa NetworkModel

        # the losses are in the energy: 0.1 out of the unit costs 0.2 of the store
        lossy = scheduled(0.1; η_dch = 0.5)
        @test scheduled_energy(lossy, 3).data ≈ [0.3, 0.1, -0.1]
        @test_throws ArgumentError check_storage(lossy)
        charging = scheduled(-0.1; η_chg = 0.5, e_init = 0.0)
        @test scheduled_energy(charging, 3).data ≈ [0.05, 0.10, 0.15]

        # a step of a quarter of an hour moves a quarter of the energy
        quarter = Dimension(:time => [Dict{Symbol,Any}(:duration => 0.25) for _ in 1:4])
        @test scheduled_energy(scheduled(0.4; dim = quarter), 3).data ≈ [0.4, 0.3, 0.2, 0.1]

        # a unit out of service holds what it has
        away = scheduled(0.1; status = nw_vector(dim, [true, false, true]))
        @test scheduled_energy(away, 3).data ≈ [0.4, 0.4, 0.3]

        # what it can be asked of is a unit that exists and stores
        @test_throws ArgumentError scheduled_energy(over, 1)
        @test_throws ArgumentError scheduled_energy(over, 99)
        @test_throws ArgumentError scheduled_energy(scheduled(0.1; dim = Dimension()), 3)

        # the cycle budget: a cycle counts half of what goes in and what comes out of
        # the store, and the budget holds over any 24 hours, not only a calendar day
        hourly = Dimension(:time => 48)
        swing(k, active) = bounded_network(hourly, Storage(;
            id = 3, node = 2, e_max = 0.5, e_init = 0.2, p_chg_max = 0.5, p_dch_max = 0.5,
            η_chg = 1.0, η_dch = 1.0, k_cycl_max = k,
            p_set = nw_vector(hourly, [n in active ? (isodd(n) ? 0.2 : -0.2) : 0.0 for n in 1:48])))

        # 24 hours of swinging 0.2 up and down count 24 * 0.1 = 2.4 pu·h
        @test check_storage(swing(5.0, 1:48)) === nothing            # budget 5 * 0.5 = 2.5
        @test_throws ArgumentError check_storage(swing(4.0, 1:48))   # budget 2.0
        @test check_storage(swing(Inf, 1:48)) === nothing

        # eight steps across midnight count 0.8, 0.4 on each side of it
        @test_throws ArgumentError check_storage(swing(1.0, 21:28))  # budget 0.5
        @test check_storage(swing(1.6, 21:28)) === nothing           # budget 0.8
        err = refusal(() -> check_storage(swing(1.0, 21:28)))
        @test occursin("storage 3", err.msg) && occursin("k_cycl_max", err.msg)
    end

    @testset "a branch" begin
        branch(; kwargs...) = Branch(; id = 3, terminals = [1, 2], r = 0.01, x = 0.1, kwargs...)

        @test_throws ArgumentError branch(r = NaN)
        @test_throws ArgumentError branch(r = Inf)
        @test_throws ArgumentError branch(x = NaN)
        @test_throws ArgumentError branch(r = 0.0, x = 0.0)
        @test_throws ArgumentError branch(g_shnt = NaN)
        @test_throws ArgumentError branch(b_shnt = NaN)
        @test_throws ArgumentError branch(g_shnt = Inf)
        @test_throws ArgumentError branch(b_shnt = [NaN, 0.0])
        @test_throws ArgumentError branch(s_max = -1.0)
        @test_throws ArgumentError branch(s_max = NaN)

        # a length is NaN where it is not known, and is neither negative nor infinite
        @test_throws ArgumentError branch(l_km = -5.0)
        @test_throws ArgumentError branch(l_km = Inf)
        @test isnan(branch(l_km = NaN).l_km)

        # a profile is refused at the one network index that breaks it
        dim = Dimension(:time => 3)
        @test_throws ArgumentError branch(r = nw_vector(dim, [0.01, NaN, 0.01]))
        @test_throws ArgumentError branch(s_max = nw_vector(dim, [1.0, 1.0, -1.0]))
        @test_throws ArgumentError branch(r = nw_vector(dim, [0.01, 0.0, 0.01]), x = 0.0)

        # and it says which branch, and what to do about a coupler
        err = refusal(() -> branch(r = 0.0, x = 0.0))
        @test err isa ArgumentError
        @test occursin("branch 3", err.msg) && occursin("Switch", err.msg)

        # what is not refused: no rating, a rating of zero, a pure resistor, a series capacitor, a length not given
        @test branch(s_max = Inf).s_max == [Inf, Inf]
        @test branch(s_max = 0.0).s_max == [0.0, 0.0]
        @test branch(r = 0.01, x = 0.0).x == [0.0, 0.0]
        @test branch(r = 0.0, x = -0.05).x == [-0.05, 0.0]
        @test isnan(branch().l_km)
        @test branch(l_km = 0.0).l_km == 0.0
        @test branch(l_km = 12.5).l_km == 12.5
    end

    @testset "a branch has an entry per terminal" begin
        branch(; kwargs...) = Branch(; id = 3, terminals = [1, 2], r = 0.01, x = 0.1, kwargs...)
        three(; kwargs...)  = Branch(; id = 4, terminals = [1, 2, 3], r = [0.01, 0.02, 0.03],
                                     x = [0.1, 0.2, 0.3], kwargs...)

        # two terminals are one π-section: a scalar is its entry, the second terminal carries nothing
        @test branch(b_shnt = 0.02).b_shnt == [0.02, 0.0]
        @test branch(s_max = 1.5).s_max == [1.5, 1.5]
        @test_throws ArgumentError branch(r = [0.01, 0.02])
        @test_throws ArgumentError branch(x = [0.1, 0.1])
        @test_throws ArgumentError branch(g_shnt = [0.0, 0.1])
        @test_throws ArgumentError branch(b_shnt = [0.0, 0.1])
        @test_throws ArgumentError branch(x = [0.1, 0.0, 0.0])

        # more than two are as many sections: a vector, a rating that is one number for every terminal
        @test three().g_shnt == [0.0, 0.0, 0.0]
        @test three(s_max = 1.5).s_max == [1.5, 1.5, 1.5]
        @test three(b_shnt = [0.01, 0.02, 0.03]).b_shnt == [0.01, 0.02, 0.03]
        @test_throws ArgumentError Branch(; id = 1, terminals = [1], r = 0.01, x = 0.1)
        @test_throws ArgumentError three(r = 0.01)
        @test_throws ArgumentError three(x = [0.1, 0.2])
        @test_throws ArgumentError three(b_shnt = 0.02)
        @test_throws ArgumentError three(s_max = [1.0, -1.0, 1.0])
        @test_throws ArgumentError three(g_shnt = [0.0, NaN, 0.0])

        # every section has an impedance, and the message says which branch
        err = refusal(() -> three(r = [0.01, 0.0, 0.03], x = [0.1, 0.0, 0.3]))
        @test err isa ArgumentError
        @test occursin("branch 4", err.msg)

        # a profile is refused at the one network index that breaks it
        dim = Dimension(:time => 3)
        @test_throws ArgumentError three(r = nw_vector(dim, [[0.01, 0.02, 0.03], [0.01, NaN, 0.03], [0.01, 0.02, 0.03]]))

        # and profiles that do not cover the same network indices are refused
        @test_throws ArgumentError branch(r = nw_vector(dim, [0.01, 0.01, 0.01]),
                                          x = nw_vector(Dimension(:time => 2), [0.1, 0.1]))
    end

end
