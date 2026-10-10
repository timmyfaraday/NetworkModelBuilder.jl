################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.12.0 - initial implementation                                             #
# v0.12.0 - the helpers build the one Transformer; a held ratio is folded      #
# v0.12.0 - both controls on one winding, and on any winding of three          #
# v0.12.0 - a winding that steps through the positions of a range              #
# v0.12.9 - the held controls are read through held_controls                   #
################################################################################

# What a transformer does, written so that it does not depend on how one is
# built. The helpers below are the only place in this file that names a type; the
# assertions say what the device does, with numbers taken from the code as it
# stood when this file was written. A change to how a transformer is built
# changes a helper and nothing else.
#
# Objectives, taps and angles are as they were before the three transformer types
# became one. The current-based sizes are 2 variables and 2 constraints smaller per
# transformer whose ratio is held, because a ratio that is data is folded into the
# winding and not given variables (case5 has two transformers); a phase shifter in
# a redispatch has no price and so no `taup`, `tadn` and their two constraints.

"a transformer whose ratio is data"
fixed(; kw...) = Transformer(; kw...)

"a transformer whose angle is a decision between `ta_min` and `ta_max`"
pst(; ta_min, ta_max, kw...) = Transformer(; pst = true, ta_min, ta_max, kw...)

"a transformer whose magnitude is a decision between `tm_min` and `tm_max`"
oltc(; tm_min, tm_max, kw...) = Transformer(; oltc = true, tm_min, tm_max, kw...)

"a transformer whose magnitude and angle are both decisions"
both(; kw...) = Transformer(; oltc = true, pst = true, kw...)

"a transformer whose magnitude, angle or both take one of the positions of a range, as `kw` say"
stepper(; kw...) = Transformer(; kw...)

"a transformer with three or more windings, `r`, `x`, ... holding one entry per terminal"
star(; kw...) = Transformer(; kw...)

"the tap of edge `e` in a result at network index `n`"
tap_of(result, e, n = 1) = nw_solution(result, n)["edge"]["$e"]["terminal"]["1"]["tap"]

"the taps of the windings of edge `e` in a result at network index `n`, in terminal order"
taps_of(result, e, n = 1) =
    [t["tap"] for (_, t) in sort!(collect(nw_solution(result, n)["edge"]["$e"]["terminal"]);
                                  by = kv -> parse(Int, first(kv)))]

"the number of variables and of constraints that are not variable bounds"
size_of(nm) = (JuMP.num_variables(nm.model),
               JuMP.num_constraints(nm.model; count_variable_in_set_constraints = false))

"the model of problem `P` in formulation `F` over `data`, and its solution"
function solved(data, ::Type{P}, ::Type{F}) where {P,F}
    nm = instantiate_model(data, P, F)

    return nm, quiet(() -> optimize_model!(nm, OPTIMIZER))
end

"case5 with branch 5, the one with a turns ratio, rebuilt by `make`"
function case5_with(make; extra...)
    data = quiet(() -> parse_file(case("case5")))
    net  = network(data)
    tf   = edge(net, 5)
    E    = Dict{Int,AbstractEdge}(net.edge)

    E[5] = make(; id = tf.id, name = tf.name, terminals = tf.terminals, r = tf.r, x = tf.x,
                g_sh = tf.g_sh, b_sh = tf.b_sh, tm = tf.tm, ta = tf.ta, rate_a = tf.rate_a,
                angmin = tf.angmin, angmax = tf.angmax, status = tf.status, extra...)

    return NetworkData(Network(net.node, E, net.unit); name = "case5", baseMVA = baseMVA(data))
end

"one reference node feeding two loads through a transformer with three windings, the loads' voltage capped at `vmax`"
function winding_network(; vmax = 1.1, kw...)
    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.02),
                               2 => Node(; id = 2, vmax), 3 => Node(; id = 3, vmax))
    E = Dict{Int,AbstractEdge}(
        1 => star(; id = 1, terminals = [1, 2, 3], r = [0.010, 0.020, 0.030],
                  x = [0.100, 0.200, 0.300], kw...))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       cost = [0.0, 10.0]),
        2 => FixedLoad(; id = 2, node = 2, pd = 0.40, qd = 0.15),
        3 => FixedLoad(; id = 3, node = 3, pd = 0.25, qd = 0.10))

    return NetworkData(Network(I, E, U); name = "windings")
end

"""
A tight corridor `1–3` in parallel with a path `1–2–3` that carries a transformer
whose angle can move, which is what relieves the corridor.
"""
function shifter_network()
    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, vm = 1.0),
                               2 => Node(; id = 2), 3 => Node(; id = 3))
    E = Dict{Int,AbstractEdge}(
        1 => Branch(; id = 1, terminals = [1, 3], r = 0.0, x = 0.1, rate_a = 0.5),
        2 => pst(; id = 2, terminals = [1, 2], r = 0.0, x = 0.1, ta_min = -0.3, ta_max = 0.3),
        3 => Branch(; id = 3, terminals = [2, 3], r = 0.0, x = 0.1))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       pg = 1.0, cost = [0.0, 10.0]),
        2 => Generator(; id = 2, node = 3, pmax = 5.0, qmin = -5.0, qmax = 5.0,
                       pg = 0.0, cost = [0.0, 100.0]),
        3 => FixedLoad(; id = 3, node = 3, pd = 1.0, qd = 0.0))

    return NetworkData(Network(I, E, U); name = "shifter", baseMVA = 100.0)
end

"the optimal power flow of case5 with branch 5 as `make`, against what it gave"
function check_case5(make, F; extra = (;), objective, tm, ta, sz)
    nm, result = solved(case5_with(make; extra...), OptimalPowerFlowProblem, F)
    tap        = tap_of(result, 5)

    @test result["termination_status"] == JuMP.LOCALLY_SOLVED
    @test result["objective"] ≈ objective rtol = 1e-7
    @test tap["tm"] ≈ tm atol = 1e-6
    @test tap["ta"] ≈ ta atol = 1e-6
    @test size_of(nm) == sz

    return nothing
end

"""
The load flow and the optimal power flow of the three-winding network against
what they gave. `vm` and `q` are only there where the formulation has them.
"""
function check_windings(F, extra; va, p, objective, lf_size, opf_size, vm = nothing, q = nothing)
    data = winding_network(; extra...)

    lf, result = solved(data, LoadFlowProblem, F)
    sol        = nw_solution(result)
    @test result["termination_status"] == JuMP.LOCALLY_SOLVED
    @test sol["node"]["2"]["va"] ≈ va[1] atol = 1e-6
    @test sol["node"]["3"]["va"] ≈ va[2] atol = 1e-6
    @test sol["unit"]["1"]["p"] ≈ p atol = 1e-6
    if vm !== nothing
        @test sol["node"]["2"]["vm"] ≈ vm[1] atol = 1e-6
        @test sol["node"]["3"]["vm"] ≈ vm[2] atol = 1e-6
        @test sol["unit"]["1"]["q"] ≈ q atol = 1e-6
    end
    @test size_of(lf) == lf_size

    opf, result = solved(data, OptimalPowerFlowProblem, F)
    @test result["termination_status"] == JuMP.LOCALLY_SOLVED
    @test result["objective"] ≈ objective rtol = 1e-7
    @test size_of(opf) == opf_size

    return nothing
end

@testset "transformers" begin

    @testset "case5, optimal power flow: what a control buys" begin
        pst_range  = (ta_min = -0.2, ta_max = 0.2)
        oltc_range = (tm_min = 0.9, tm_max = 1.1)

        @testset "fixed, current-based" begin
            check_case5(fixed, IVRFormulation; objective = 18269.10277920319,
                        tm = 1.05, ta = deg2rad(1.0), sz = (78, 108))
        end
        @testset "fixed, linearized" begin
            check_case5(fixed, LPFFormulation; objective = 18230.87327365834,
                        tm = 1.05, ta = deg2rad(1.0), sz = (32, 49))
        end
        @testset "phase shifter, current-based" begin
            check_case5(pst, IVRFormulation; extra = pst_range, objective = 15361.63977117874,
                        tm = 1.05, ta = -0.1437787322995556, sz = (82, 113))
        end
        @testset "phase shifter, linearized" begin
            check_case5(pst, LPFFormulation; extra = pst_range, objective = 14979.73668132809,
                        tm = 1.05, ta = -0.16926719116051048, sz = (33, 49))
        end
        @testset "tap changer, current-based" begin
            check_case5(oltc, IVRFormulation; extra = oltc_range, objective = 18175.84597840520,
                        tm = 0.9195861572681617, ta = deg2rad(1.0), sz = (81, 110))
        end
        @testset "tap changer, linearized: no use for a magnitude" begin
            check_case5(oltc, LPFFormulation; extra = oltc_range, objective = 18230.87327365833,
                        tm = 1.05, ta = deg2rad(1.0), sz = (32, 49))
        end
    end

    @testset "case5, both controls on one winding" begin
        range = (tm_min = 0.9, tm_max = 1.1, ta_min = -0.2, ta_max = 0.2)

        # together they do better than either alone, 15361.6 and 18175.8
        @testset "current-based: a ring of ratios" begin
            check_case5(both, IVRFormulation; extra = range, objective = 15344.22651230504,
                        tm = 1.0219854701926994, ta = -0.138662043125777, sz = (82, 114))
        end
        @testset "linearized: the angle alone" begin
            check_case5(both, LPFFormulation; extra = range, objective = 14979.73668132809,
                        tm = 1.05, ta = -0.16926719116051048, sz = (33, 49))
        end
        @testset "held at what it chose, the winding gives the same optimum" begin
            check_case5(fixed, IVRFormulation;
                        extra = (tm = [1.0219854701926994, 1.0], ta = [-0.138662043125777, 0.0]),
                        objective = 15344.22651230504,
                        tm = 1.0219854701926994, ta = -0.138662043125777, sz = (78, 108))
        end
    end

    @testset "three windings, load flow and optimal power flow" begin
        # the second network gives every winding a ratio and a rating, and the
        # star point a magnetising branch
        ratios = (tm = [1.0, 0.95, 1.05], ta = [0.0, 0.02, -0.01], g_m = 0.002, b_m = -0.01,
                  rate_a = [3.0, 1.0, 1.0])

        @testset "plain, current-based" begin
            check_windings(IVRFormulation, (;); va = (-0.1468713374927703, -0.14130337788297284),
                           vm = (0.9348310737873904, 0.9358532410998236),
                           p = 0.6622053866092757, q = 0.3720538660927581,
                           lf_size = (22, 22), objective = 6.601790739872742, opf_size = (22, 28))
        end
        @testset "plain, linearized" begin
            check_windings(LPFFormulation, (;); va = (-0.14645, -0.1414), p = 0.65,
                           lf_size = (11, 11), objective = 6.5, opf_size = (11, 11))
        end
        @testset "ratios and magnetising, current-based" begin
            check_windings(IVRFormulation, ratios; va = (-0.12723016145875204, -0.1516489913608215),
                           vm = (0.8870174021272711, 0.9814634990542811),
                           p = 0.6642380022581644, q = 0.3828174463537286,
                           lf_size = (22, 22), objective = 6.625487508859268, opf_size = (22, 31))
        end
        @testset "ratios and magnetising, linearized" begin
            check_windings(LPFFormulation, ratios; va = (-0.12645, -0.1514), p = 0.65,
                           lf_size = (11, 11), objective = 6.5, opf_size = (11, 14))
        end
    end

    @testset "controls on the windings of a transformer with three" begin
        # the loads' voltage is capped, so what a ratio buys is a source that can
        # stay high; it takes both windings to do it, as both loads are at the cap
        opf(; kw...) = solved(winding_network(; vmax = 1.02, kw...),
                              OptimalPowerFlowProblem, IVRFormulation)
        angle = (ta_min = [0.0, -0.2, -0.2], ta_max = [0.0, 0.2, 0.2])

        _, plain = opf()
        @test plain["objective"] ≈ 6.602714947516425 rtol = 1e-7

        @testset "magnitudes" begin
            nm, result = opf(; oltc = [false, true, true])
            taps = taps_of(result, 1)

            @test result["objective"] ≈ 6.601790739817746 rtol = 1e-7
            @test size_of(nm) == (28, 32)
            @test taps[1]["tm"] == 1.0
            @test all(0.9 - 1e-6 <= t["tm"] < 1.0 for t in taps[2:3])

            # a ratio on one winding does not relieve the cap at the other
            _, one = opf(; oltc = [false, true, false])
            @test one["objective"] ≈ plain["objective"] rtol = 1e-9

            # held at the ratios it chose, the transformer gives the same optimum
            _, held = opf(; tm = [t["tm"] for t in taps])
            @test held["objective"] ≈ result["objective"] rtol = 1e-7
        end

        @testset "angles" begin
            # in a radial network an angle has nothing to relieve
            nm, result = opf(; pst = [false, true, true], angle...)
            @test result["objective"] ≈ plain["objective"] rtol = 1e-9
            @test size_of(nm) == (30, 38)
        end

        @testset "magnitudes and angles" begin
            nm, result = opf(; oltc = [false, true, true], pst = [false, true, true], angle...)
            taps = taps_of(result, 1)

            @test result["objective"] ≈ 6.601790739817746 rtol = 1e-7
            @test size_of(nm) == (30, 40)
            @test all(0.9 - 1e-6 <= t["tm"] <= 1.1 + 1e-6 for t in taps)
            @test all(-0.2 - 1e-6 <= t["ta"] <= 0.2 + 1e-6 for t in taps)

            _, held = opf(; tm = [t["tm"] for t in taps], ta = [t["ta"] for t in taps])
            @test held["objective"] ≈ result["objective"] rtol = 1e-7
        end
    end

    @testset "a phase shifter that is one winding of three" begin
        # the same device as the two-winding one, with a third winding that ends on a
        # node of its own and so carries nothing
        for (F, sz) in ((LPFFormulation, (18, 20)), (IVRFormulation, (42, 55)))
            _, two      = solved(meshed_network(), OptimalPowerFlowProblem, F)
            nm, three   = solved(meshed_network(; star = true), OptimalPowerFlowProblem, F)
            _, stranded = solved(meshed_network(; shift = false, star = true),
                                 OptimalPowerFlowProblem, F)
            taps = taps_of(three, 2)

            @test three["objective"] ≈ two["objective"] rtol = 1e-6
            @test stranded["objective"] > three["objective"] + 1.0
            @test size_of(nm) == sz

            # any angle that brings the corridor under its rating costs the same, so
            # it is the rating and the direction that are determined
            corridor = nw_solution(three)["edge"]["1"]["terminal"]["1"]
            @test hypot(corridor["p"], get(corridor, "q", 0.0)) <= 0.5 + 1e-6
            @test -0.3 - 1e-6 <= taps[1]["ta"] < -1e-3
            @test taps[2]["ta"] == 0.0 && taps[3]["ta"] == 0.0
        end
    end

    @testset "a winding of three held across the contingencies" begin
        dim  = Dimension(:contingency => 2)
        data = meshed_network(; dim, out = (2,), star = true)

        for (F, keys) in ((LPFFormulation, (:ta,)), (IVRFormulation, (:tr, :ti)))
            tied = held_controls(instantiate_model(data, RedispatchProblem, F))

            @test all((:edge, Arc(2, 1, 1), k, 2) in tied for k in keys)
            @test !any((:edge, a, k, 2) in tied
                       for a in (Arc(2, 2, 2), Arc(2, 3, 4)), k in (:ta, :tr, :ti, :tm))
        end

        # the optimum is the two-winding one, held or not; the setpoint angle is zero,
        # where dependent rows would stop the current-based solver
        two = meshed_network(; dim, out = (2,))
        for F in (LPFFormulation, IVRFormulation), control in (:preventive, :corrective)
            rd    = Redispatch(; control)
            three = quiet(() -> solve_rd(data, F, OPTIMIZER; redispatch = rd))
            @test three["termination_status"] == JuMP.LOCALLY_SOLVED
            @test three["objective"] ≈
                  quiet(() -> solve_rd(two, F, OPTIMIZER; redispatch = rd))["objective"] rtol = 1e-6

            control === :preventive && @test taps_of(three, 2, 1)[1]["ta"] ≈
                                             taps_of(three, 2, 2)[1]["ta"] atol = 1e-6
        end

        # a held winding has no tap rows of its own, the base case's imply them
        for (control, held) in ((:preventive, true), (:corrective, false))
            nm = instantiate_model(data, RedispatchProblem, IVRFormulation;
                                   ext = Dict{Symbol,Any}(:redispatch => Redispatch(; control)))

            @test haskey(_NMB.con(nm; nw = 1)[:tap_setting], Arc(2, 1, 1))
            @test haskey(_NMB.con(nm; nw = 2)[:tap_setting], Arc(2, 1, 1)) == !held
        end
    end

    @testset "redispatch with a phase shifter" begin
        # any angle that clears the rating of the corridor costs nothing, so only
        # the objective and the limits are determined
        nm, result = solved(shifter_network(), RedispatchProblem, LPFFormulation)
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test result["objective"] ≈ 0.0 atol = 1e-5
        @test tap_of(result, 2)["tm"] == 1.0
        @test -0.3 - 1e-6 <= tap_of(result, 2)["ta"] <= 0.3 + 1e-6
        @test tap_of(result, 2)["ta_market"] == 0.0
        @test size_of(nm) == (19, 20)

        nm, result = solved(shifter_network(), RedispatchProblem, IVRFormulation)
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test result["objective"] ≈ 0.0 atol = 1e-5
        @test size_of(nm) == (42, 53)
    end

    @testset "stepped windings" begin
        exact   = JuMP.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false,
                                                 "mip_rel_gap" => 0.0, "mip_abs_gap" => 0.0)
        juniper = JuMP.optimizer_with_attributes(
            Juniper.Optimizer, "log_levels" => Symbol[],
            "nl_solver" => JuMP.optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0,
                                                           "sb" => "yes"))

        # the meshed network with its shifter at each of `positions`, or stepping
        positions = -0.3:0.1:0.3
        stepping  = (pst = STEPPED, ta_step = 0.1)
        held_at(a; star = false, kw...) =
            meshed_network(; kw..., star, tap = (pst = FIXED, ta = star ? [a, 0.0, 0.0] : [a, 0.0]))

        @testset "linearized: the optimum is the best of every position" begin
            runs = [quiet(() -> solve_opf(held_at(a), LPFFormulation, exact))["objective"]
                    for a in positions]

            nm     = instantiate_model(meshed_network(; tap = stepping), OptimalPowerFlowProblem,
                                       LPFFormulation)
            result = quiet(() -> optimize_model!(nm, exact))
            tap    = taps_of(result, 2)[1]

            @test result["termination_status"] == JuMP.OPTIMAL
            @test result["objective"] ≈ minimum(runs) atol = 1e-6
            @test maximum(runs) - minimum(runs) > 100.0        # and it was a choice

            # the position it took is the angle it reports, and one that clears the corridor
            @test tap["ta"] ≈ positions[tap["step"]] atol = 1e-9
            @test tap["ta"] <= -0.1 + 1e-9
            @test sum(JuMP.value, values(_NMB.var(nm)[:zt])) ≈ 1.0 atol = 1e-9

            # held at that position, the same winding gives the same optimum
            @test quiet(() -> solve_opf(held_at(tap["ta"]), LPFFormulation, exact))["objective"] ≈
                  result["objective"] atol = 1e-6
        end

        @testset "one binary for each position, and no prices" begin
            nm = instantiate_model(meshed_network(; tap = stepping), OptimalPowerFlowProblem,
                                   LPFFormulation)
            zt = _NMB.var(nm)[:zt]

            @test length(zt) == 7 && all(JuMP.is_binary, values(zt))
            @test [JuMP.start_value(zt[(Arc(2, 1, 1), s)]) for s in 1:7] == [0, 0, 0, 1, 0, 0, 0]
            @test !haskey(_NMB.var(nm), :ta)
            @test count(==(:tap_step), first.([(key, id) for (_, key, id) in
                                               keys(registered_constraints(nm))])) == 1

            quiet(() -> optimize_model!(nm, exact))
            @test !JuMP.has_duals(nm.model)
            @test all(active_nodal_price(nm, i) === nothing for i in 1:3)
        end

        @testset "a power flow holds the setpoint, and a magnitude is inert when linearized" begin
            range = (pst = STEPPED, ta_min = deg2rad(-9), ta_max = deg2rad(11), ta_step = deg2rad(5))
            lf    = instantiate_model(case5_with(stepper; range...), LoadFlowProblem, LPFFormulation)
            @test !any(JuMP.is_binary, JuMP.all_variables(lf.model))

            # a stepped magnitude has nothing to act on in the linearized formulation
            nm, result = solved(case5_with(stepper; oltc = STEPPED, tm_min = 0.9, tm_max = 1.1,
                                           tm_step = 0.05), OptimalPowerFlowProblem, LPFFormulation)
            @test !any(JuMP.is_binary, JuMP.all_variables(nm.model))
            @test result["objective"] ≈ 18230.87327365834 rtol = 1e-7
            @test size_of(nm) == (32, 49)
        end

        @testset "current-based, $name: the optimum is the best of every position" for
                (name, extra, ms, as, sz) in (
                    ("magnitude", (oltc = STEPPED, tm_min = 0.9, tm_max = 1.1, tm_step = 0.05),
                     0.9:0.05:1.1, [deg2rad(1.0)], (85, 111)),
                    ("angle", (pst = STEPPED, ta_min = deg2rad(-9), ta_max = deg2rad(11),
                               ta_step = deg2rad(5)),
                     [1.05], deg2rad.(-9:5:11), (85, 111)),
                    ("magnitude and angle", (oltc = STEPPED, pst = STEPPED, tm_min = 0.95,
                                             tm_max = 1.05, tm_step = 0.05, ta_min = deg2rad(-9),
                                             ta_max = deg2rad(1), ta_step = deg2rad(5)),
                     0.95:0.05:1.05, deg2rad.(-9:5:1), (89, 111)))

            # in turn for each angle, the order in which the winding numbers its positions
            runs = [solved(case5_with(fixed; tm = [m, 1.0], ta = [a, 0.0]),
                           OptimalPowerFlowProblem, IVRFormulation)[2]["objective"]
                    for m in ms for a in as]
            best = argmin(runs)

            nm     = instantiate_model(case5_with(stepper; extra...), OptimalPowerFlowProblem,
                                       IVRFormulation)
            result = quiet(() -> optimize_model!(nm, juniper))
            tap    = taps_of(result, 5)[1]

            @test result["termination_status"] in (JuMP.OPTIMAL, JuMP.LOCALLY_SOLVED)
            @test result["objective"] ≈ runs[best] rtol = 1e-6
            @test maximum(runs) - minimum(runs) > 100.0
            @test tap["step"] == best
            @test size_of(nm) == sz
            @test !JuMP.has_duals(nm.model)
        end

        @testset "a winding of three steps as one of two" begin
            tap  = (pst = [STEPPED, FIXED, FIXED], ta_step = [0.1, 0.1, 0.1])
            two  = quiet(() -> solve_opf(meshed_network(; tap = stepping), LPFFormulation, exact))
            nm   = instantiate_model(meshed_network(; star = true, tap), OptimalPowerFlowProblem,
                                     LPFFormulation)
            three = quiet(() -> optimize_model!(nm, exact))

            @test three["objective"] ≈ two["objective"] atol = 1e-6
            @test length(_NMB.var(nm)[:zt]) == 7              # the windings that hold have none
            @test taps_of(three, 2)[1]["ta"] <= -0.1 + 1e-9
            @test taps_of(three, 2)[2]["ta"] == 0.0 && !haskey(taps_of(three, 2)[2], "step")
        end

        @testset "preventive: one position over the contingencies" begin
            dim = Dimension(:contingency => 2)
            for star in (false, true)
                t    = star ? (pst = [STEPPED, FIXED, FIXED], ta_step = [0.1, 0.1, 0.1]) : stepping
                data = meshed_network(; dim, out = (2,), star, tap = t)

                # one angle for both states, so the best of the enumerated fixed ones
                runs = [quiet(() -> solve_rd(held_at(a; dim, out = (2,), star), LPFFormulation,
                                             exact))["objective"] for a in positions]
                preventive = quiet(() -> solve_rd(data, LPFFormulation, exact))
                corrective = quiet(() -> solve_rd(data, LPFFormulation, exact;
                                          redispatch = Redispatch(; control = :corrective)))

                @test preventive["objective"] ≈ minimum(runs) atol = 1e-6
                @test corrective["objective"] < preventive["objective"] - 1.0
                @test taps_of(preventive, 2, 1)[1]["step"] == taps_of(preventive, 2, 2)[1]["step"]
            end

            # a held winding has no binaries and no row of its own: it takes the base
            # case's, so nothing is tied and the corrective one keeps a set per state
            data = meshed_network(; dim, out = (2,), tap = stepping)
            arc  = Arc(2, 1, 1)
            for F in (LPFFormulation, IVRFormulation), control in (:preventive, :corrective)
                nm = instantiate_model(data, RedispatchProblem, F;
                                       ext = Dict{Symbol,Any}(:redispatch => Redispatch(; control)))
                held = control === :preventive

                @test count(JuMP.is_binary, JuMP.all_variables(nm.model)) == (held ? 7 : 14)
                @test all((_NMB.var(nm, :zt, (arc, s); nw = 2) === _NMB.var(nm, :zt, (arc, s); nw = 1))
                          == held for s in 1:7)
                @test !any(key[3] === :zt for key in held_controls(nm))
                @test haskey(_NMB.con(nm; nw = 1)[:tap_step], arc)
                @test haskey(_NMB.con(nm; nw = 2)[:tap_step], arc) == !held
            end
        end
    end

    @testset "what it refuses" begin
        two = (id = 1, terminals = [1, 2], r = 0.0, x = 0.1)

        @test_throws ArgumentError Transformer(; id = 1, terminals = [1], r = 0.0, x = 0.1)
        @test_throws ArgumentError Transformer(; two..., tm = 0.0)
        @test_throws ArgumentError Transformer(; two..., oltc = true, tm_min = 1.1, tm_max = 0.9)
        @test_throws ArgumentError Transformer(; two..., pst = true, ta_min = 0.2, ta_max = -0.2)
        @test_throws ArgumentError Transformer(; two..., pst = true, ta_min = -2.0, ta_max = 2.0)
        @test_throws ArgumentError Transformer(; two..., angmin = 1.0, angmax = -1.0)

        # a vector has to say something about every winding, and a scalar only
        # stands for the first winding of two
        @test_throws ArgumentError Transformer(; two..., tm = [1.0, 1.0, 1.0])
        @test_throws ArgumentError Transformer(; id = 1, terminals = [1, 2, 3],
                                                 r = [0.01, 0.02, 0.03], x = 0.1)

        # what is not built yet says so rather than being modelled as something else
        @test_throws ArgumentError Transformer(; two..., oltc = STEPPED, pst = true)
        @test_throws ArgumentError Transformer(; two..., oltc = true, pst = STEPPED)

        # a stepped winding needs a range of whole steps with its setpoint on one, and
        # a range that is the same at every network index
        @test Transformer(; two..., oltc = STEPPED).oltc == [STEPPED, FIXED]
        @test Transformer(; two..., pst = STEPPED).pst == [STEPPED, FIXED]
        @test_throws ArgumentError Transformer(; two..., oltc = STEPPED, tm = 1.004)
        @test_throws ArgumentError Transformer(; two..., pst = STEPPED, ta = 0.003)
        @test_throws ArgumentError Transformer(; two..., oltc = STEPPED, tm_max = 1.11)
        @test_throws ArgumentError Transformer(; two..., pst = STEPPED, ta_step = 0.0)
        @test_throws ArgumentError Transformer(; two..., oltc = STEPPED,
            tm_max = nw_vector(Dimension(:time => 2), [1.1, 1.0]))

        # a winding with no impedance has no angle of its own in the linearized
        # formulation, where the star point is one
        data = winding_network(; r = [0.0, 0.02, 0.03], x = [0.0, 0.2, 0.3])
        err  = try
            instantiate_model(data, LoadFlowProblem, LPFFormulation)
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("winding", err.msg)
    end
end
