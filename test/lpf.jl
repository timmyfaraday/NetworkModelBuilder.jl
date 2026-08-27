################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.4.0 - the linearized formulation                                          #
################################################################################

# The reference values below are those of PowerModels.jl v0.21 in its
# DCPPowerModel. That model drops the phase shift of a transformer where this one
# keeps it, so the two agree exactly on case14 and case3, which have no phase
# shift, and are expected to differ on case5, which does. See the note at the end
# of this file.

const CASE14_DC_OPF_VA = [    # degrees
     0.0,       -5.552765, -14.116668, -11.547783,  -9.882645, -15.945279,
   -15.028123, -15.028123, -16.858996, -17.199942, -16.831421, -17.258219,
   -17.557871, -18.759242]

const CASE14_DC_PF_VA = [
     0.0,       -5.491197, -14.061764, -11.499165,  -9.838325, -15.899609,
   -14.980216, -14.980216, -16.811464, -17.152726, -16.78495,  -17.212433,
   -17.511921, -18.712395]

const CASE3_DC_OPF_VA = [0.0, 5.348570, -16.161221]
const CASE3_DC_PF_VA  = [0.0, 2.118113, -17.631043]

"the angles of a solution, in degrees, ordered by node identifier"
degrees(result, nw = 1) =
    [rad2deg(nw_solution(result, nw)["node"]["$i"]["va"])
     for i in sort(parse.(Int, collect(keys(nw_solution(result, nw)["node"]))))]

@testset "linearized formulation" begin

    @testset "the model is a linear or quadratic program" begin
        for P in (LoadFlowProblem, OptimalPowerFlowProblem)
            nm = quiet(() -> instantiate_model(case("case14"), P, LPFFormulation))

            # every constraint is affine; nothing quadratic survives the approximations
            @test all(T <: Union{JuMP.AffExpr,JuMP.VariableRef}
                      for (T, S) in JuMP.list_of_constraint_types(nm.model))
        end

        # the objective is quadratic only because the cost polynomial is
        opf = quiet(() -> instantiate_model(case("case14"), OptimalPowerFlowProblem, LPFFormulation))
        @test JuMP.objective_function_type(opf.model) == JuMP.QuadExpr

        lf = quiet(() -> instantiate_model(case("case14"), LoadFlowProblem, LPFFormulation))
        @test JuMP.objective_function_type(lf.model) == JuMP.AffExpr

        # for contrast, the current based formulation keeps quadratic constraints
        ivr = quiet(() -> instantiate_model(case("case14"), OptimalPowerFlowProblem, IVRFormulation))
        @test any(T == JuMP.QuadExpr for (T, S) in JuMP.list_of_constraint_types(ivr.model))
    end

    @testset "the variables are the linearized ones" begin
        nm = quiet(() -> instantiate_model(case("case14"), OptimalPowerFlowProblem, LPFFormulation))

        for key in (:va, :p, :pu, :pg)
            @test haskey(_NMB.var(nm), key)
        end
        # no magnitude, no current, no reactive power
        for key in (:vr, :vi, :cr, :ci, :cru, :ciu, :csr, :csi, :qg)
            @test !haskey(_NMB.var(nm), key)
        end
    end

    @testset "case14 reproduces the reference solution" begin
        opf = quiet(() -> solve_opf(case("case14"), LPFFormulation, OPTIMIZER))
        @test opf["termination_status"] == JuMP.LOCALLY_SOLVED
        @test opf["objective"] ≈ 7642.591774 rtol = 1e-7
        @test degrees(opf) ≈ CASE14_DC_OPF_VA atol = 1e-5

        pf = quiet(() -> solve_lf(case("case14"), LPFFormulation, OPTIMIZER))
        @test pf["termination_status"] == JuMP.LOCALLY_SOLVED
        @test degrees(pf) ≈ CASE14_DC_PF_VA atol = 1e-5
        @test nw_solution(pf)["unit"]["1"]["pg"] ≈ 2.19 atol = 1e-6   # the slack closes
        @test nw_solution(pf)["unit"]["2"]["pg"] ≈ 0.40 atol = 1e-8   # the rest hold
    end

    @testset "case3 reproduces the reference solution" begin
        opf = quiet(() -> solve_opf(case("case3"), LPFFormulation, OPTIMIZER))
        @test opf["objective"] ≈ 5695.895884 rtol = 1e-7
        @test degrees(opf) ≈ CASE3_DC_OPF_VA atol = 1e-5

        pf = quiet(() -> solve_lf(case("case3"), LPFFormulation, OPTIMIZER))
        @test degrees(pf) ≈ CASE3_DC_PF_VA atol = 1e-5
    end

    @testset "every voltage magnitude is one, and there is no reactive power" begin
        result = quiet(() -> solve_opf(case("case14"), LPFFormulation, OPTIMIZER))
        sol    = nw_solution(result)

        @test all(sol["node"]["$i"]["vm"] == 1.0 for i in keys(sol["node"]))
        @test !any(haskey(sol["unit"][u], "qg") for u in keys(sol["unit"]))
        @test !any(haskey(sol["edge"][e]["terminal"]["1"], "q") for e in keys(sol["edge"]))
    end

    @testset "the model is lossless" begin
        data   = quiet(() -> parse_file(case("case14")))
        net    = network(data)
        result = quiet(() -> solve_opf(data, LPFFormulation, OPTIMIZER))
        sol    = nw_solution(result)

        # whatever leaves one terminal of an edge arrives at the others
        for e in ids(net, AbstractEdge)
            @test sum(t["p"] for t in values(sol["edge"]["$e"]["terminal"])) ≈ 0.0 atol = 1e-8
        end

        # so generation equals demand exactly, with the shunt conductance included
        generated = sum(sol["unit"]["$u"]["pg"] for u in ids(net, Generator))
        withdrawn = sum(unit(net, u).pd for u in ids(net, FixedLoad)) +
                    sum(unit(net, u).gs for u in ids(net, Shunt))
        @test generated ≈ withdrawn atol = 1e-7

        # and the node balance holds at every node
        for i in ids(net, Node)
            into = sum(sol["edge"]["$(a.edge)"]["terminal"]["$(a.terminal)"]["p"]
                       for a in node_arcs(net, i); init = 0.0)
            from = sum(sol["unit"]["$u"]["p"] for u in node_units(net, i); init = 0.0)
            @test into ≈ from atol = 1e-7
        end
    end

    @testset "the operating limits are respected" begin
        data   = quiet(() -> parse_file(case("case5")))
        net    = network(data)
        result = quiet(() -> solve_opf(data, LPFFormulation, OPTIMIZER))
        sol    = nw_solution(result)

        for e in ids(net, AbstractEdge)
            br = edge(net, e)
            isfinite(br.rate_a) || continue
            for t in values(sol["edge"]["$e"]["terminal"])
                @test abs(t["p"]) <= br.rate_a + 1e-6
            end
        end
        for u in ids(net, Generator)
            g = unit(net, u)
            @test g.pmin - 1e-6 <= sol["unit"]["$u"]["pg"] <= g.pmax + 1e-6
        end
    end
end

@testset "linearized formulation — the components" begin

    @testset "every branch type behaves the same" begin
        reference = quiet(() -> solve_opf(case("case14"), LPFFormulation, OPTIMIZER))

        for T in (Cable, OverheadLine)
            result = quiet(() -> solve_opf(as_branch_type(T), LPFFormulation, OPTIMIZER))
            @test result["objective"] ≈ reference["objective"] rtol = 1e-8
            @test degrees(result) ≈ degrees(reference) atol = 1e-8
        end
    end

    @testset "a tap changer is inert, a phase shifter is a control" begin
        plain = quiet(() -> solve_opf(as_transformer_type(Transformer),
                                      LPFFormulation, OPTIMIZER))

        # the ratio magnitude has nothing to act on once every magnitude is one,
        # so a tap changer gives exactly the transformer it was built from
        tap = quiet(() -> solve_opf(as_transformer_type(TapChanger; tm_min = 0.8, tm_max = 1.2),
                                    LPFFormulation, OPTIMIZER))
        @test tap["objective"] ≈ plain["objective"] rtol = 1e-9
        @test degrees(tap) ≈ degrees(plain) atol = 1e-9

        # the ratio angle does survive, so a phase shifter enlarges the feasible set
        data = as_transformer_type(PhaseShifter; ta_min = -0.2, ta_max = 0.2)
        nm   = instantiate_model(data, OptimalPowerFlowProblem, LPFFormulation)
        pst  = quiet(() -> optimize_model!(nm, OPTIMIZER))

        @test pst["objective"] <= plain["objective"] + 1e-6
        @test pst["objective"] < plain["objective"]          # it is worth using here
        @test -0.2 - 1e-6 <= nw_solution(pst)["edge"]["5"]["tap"]["ta"] <= 0.2 + 1e-6

        # and it stays a linear program while doing it
        @test all(T <: Union{JuMP.AffExpr,JuMP.VariableRef}
                  for (T, S) in JuMP.list_of_constraint_types(nm.model))

        # in a load flow it has no freedom and holds its setpoint
        lf = instantiate_model(data, LoadFlowProblem, LPFFormulation)
        @test !haskey(_NMB.var(lf), :ta)
    end

    @testset "a shunt keeps its conductance and loses its susceptance" begin
        I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF), 2 => Node(; id = 2))
        E = Dict{Int,AbstractEdge}(1 => Branch(; id = 1, terminals = [1, 2], r = 0.01, x = 0.1))
        U = Dict{Int,AbstractUnit}(1 => Generator(; id = 1, node = 1, pmax = 5.0),
                                   2 => Shunt(; id = 2, node = 2, gs = 0.03, bs = 0.40))
        data = NetworkData(Network(I, E, U); name = "shunt")

        result = quiet(() -> solve_lf(data, LPFFormulation, OPTIMIZER))
        sol    = nw_solution(result)

        @test sol["unit"]["2"]["p"] ≈ -0.03 atol = 1e-9     # gs, and not bs
        @test sol["unit"]["1"]["pg"] ≈ 0.03 atol = 1e-9     # which the generator covers
    end

    @testset "a multi-winding transformer hides its star point here too" begin
        r, x = [0.010, 0.020, 0.030], [0.100, 0.200, 0.300]
        units() = Dict{Int,AbstractUnit}(1 => Generator(; id = 1, node = 1, pmax = 5.0),
                                         2 => FixedLoad(; id = 2, node = 2, pd = 0.40),
                                         3 => FixedLoad(; id = 3, node = 3, pd = 0.25))

        star = NetworkData(Network(
            Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF),
                                   2 => Node(; id = 2), 3 => Node(; id = 3)),
            Dict{Int,AbstractEdge}(1 => MultiWindingTransformer(; id = 1,
                                                                terminals = [1, 2, 3],
                                                                r = r, x = x)),
            units()); name = "star")

        split = NetworkData(Network(
            Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF), 2 => Node(; id = 2),
                                   3 => Node(; id = 3), 4 => Node(; id = 4)),
            Dict{Int,AbstractEdge}(k => Branch(; id = k, terminals = [k, 4],
                                               r = r[k], x = x[k]) for k in 1:3),
            units()); name = "split")

        a = quiet(() -> solve_lf(star,  LPFFormulation, OPTIMIZER))
        b = quiet(() -> solve_lf(split, LPFFormulation, OPTIMIZER))

        for i in 1:3
            @test nw_solution(a)["node"]["$i"]["va"] ≈
                  nw_solution(b)["node"]["$i"]["va"] atol = 1e-9
        end
        @test !haskey(nw_solution(a)["node"], "4")
    end

    @testset "two identical impedances carry equal and opposite flows" begin
        # case5 connects nodes 3 and 4 twice with the same impedance, oriented
        # oppositely. Once the phase shift is taken out they are the same element
        # seen from either end, and the model has to say so.
        data = quiet(() -> parse_file(case("case5")))
        net  = network(data)
        E    = Dict{Int,AbstractEdge}(net.edge)
        for e in ids(net, Transformer)
            tf   = edge(net, e)::Transformer
            E[e] = Transformer(; id = tf.id, name = tf.name, terminals = tf.terminals,
                               r = tf.r, x = tf.x, b_fr = tf.b_fr, b_to = tf.b_to,
                               tm = tf.tm, ta = 0.0, rate_a = tf.rate_a,
                               angmin = tf.angmin, angmax = tf.angmax, status = tf.status)
        end
        flat = NetworkData(Network(net.node, E, net.unit); name = "flat", baseMVA = 100.0)

        sol = nw_solution(quiet(() -> solve_opf(flat, LPFFormulation, OPTIMIZER)))
        @test sol["edge"]["5"]["terminal"]["1"]["p"] ≈
              -sol["edge"]["6"]["terminal"]["1"]["p"] atol = 1e-8
    end

    @testset "the time coupled units work here too" begin
        battery = Storage(; id = 3, node = 2, energy_capacity = 0.5, energy_initial = 0.0,
                          charge_rating = 0.2, discharge_rating = 0.2,
                          charge_efficiency = 0.95, discharge_efficiency = 0.95)
        data = price_network(PRICES; extra = Dict{Int,AbstractUnit}(3 => battery))

        result = quiet(() -> solve_model(data, OptimalPowerFlowProblem,
                                         LPFFormulation, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        @test nw_solution(result, 1)["unit"]["3"]["psc"] > 0.01   # charges when cheap
        @test nw_solution(result, 2)["unit"]["3"]["psd"] > 0.01   # discharges when dear

        flat = FlexibleLoad(; id = 3, node = 2, pd_nominal = 0.10, qd_nominal = 0.02,
                            pd_min = 0.0, pd_max = 0.15)
        shifted = quiet(() -> solve_model(price_network(PRICES;
                                              extra = Dict{Int,AbstractUnit}(3 => flat)),
                                          OptimalPowerFlowProblem, LPFFormulation, OPTIMIZER))
        pd = [nw_solution(shifted, n)["unit"]["3"]["pd"] for n in 1:3]
        @test pd[1] ≈ 0.15 atol = 1e-5
        @test sum(pd) ≈ 3 * 0.10 atol = 1e-6
    end

    @testset "the linearization is a reasonable approximation" begin
        # not a physical law, but a model that lands nowhere near the AC answer
        # would be wrong in a way worth catching
        for name in ("case14", "case3")
            ac = quiet(() -> solve_opf(case(name), IVRFormulation, OPTIMIZER))
            dc = quiet(() -> solve_opf(case(name), LPFFormulation, OPTIMIZER))
            @test dc["objective"] < ac["objective"]            # losses are not paid for
            @test dc["objective"] > 0.9 * ac["objective"]      # but the answer is close
        end
    end
end
