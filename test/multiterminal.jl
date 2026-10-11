################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
# v0.12.0 - the star point keys differ from the ones a Transformer registers   #
# v0.13.0 - a three-terminal Branch against a Transformer and the split point  #
# v0.14.0 - variable and solution keys follow the nomenclature                 #
# v0.14.0 - the fields follow the nomenclature                                 #
# v0.15.0 - functions that write rows, duals and letters follow the map        #
################################################################################

# An edge with more than two terminals is the reason the extended graph carries
# arcs `(e, t, i)` rather than pairs. This file adds one — the star equivalent of
# a three-winding transformer — from outside the package, in exactly the way an
# extension package would, and checks it against the two-terminal model of the
# same thing: three branches meeting at an explicit internal node.

"""
A three or more terminal edge modelled as a star of series impedances meeting at
an internal star point. Terminal `k` sees the impedance `r[k] + j·x[k]`.
"""
Base.@kwdef struct StarEdge <: AbstractEdge
    id       ::Int
    name     ::String           = ""
    terminals::Vector{Int}
    r        ::Vector{Float64}
    x        ::Vector{Float64}
    status   ::Bool             = true
    ext      ::Dict{Symbol,Any} = Dict{Symbol,Any}()
end

register_edge_type!(StarEdge)

"the complex voltage of the star point of every in-service star edge"
function _NMB.variable_edge(nm::NetworkModel{P,F}, ::Type{StarEdge};
                            nw::Int = nw_id_default(nm)
                           ) where {P<:AbstractProblemType,F<:IVRFormulation}
    E = ids(nm, StarEdge; nw)

    _NMB.var(nm; nw)[:star_vr] = JuMP.@variable(nm.model, [e in E], base_name = "$(nw)_star_vr", start = 1.0)
    _NMB.var(nm; nw)[:star_vi] = JuMP.@variable(nm.model, [e in E], base_name = "$(nw)_star_vi", start = 0.0)

    return nothing
end

"the voltage drop from every terminal to the star point, and the balance at the star point"
function _NMB.fnct_edge(nm::NetworkModel{P,F}, ::Type{StarEdge};
                              nw::Int = nw_id_default(nm)
                             ) where {P<:AbstractProblemType,F<:IVRFormulation}
    v_real, v_imag           = _NMB.var(nm, :v_real;      nw), _NMB.var(nm, :v_imag;      nw)
    i_term_real, i_term_imag = _NMB.var(nm, :i_term_real; nw), _NMB.var(nm, :i_term_imag; nw)
    vsr, vsi                 = _NMB.var(nm, :star_vr;     nw), _NMB.var(nm, :star_vi;     nw)

    for e in ids(nm, StarEdge; nw)
        se = edge(nm, e; nw)::StarEdge
        A  = edge_arcs(nm, e; nw)

        for (k, a) in enumerate(A)
            i = a.node
            JuMP.@constraint(nm.model, v_real[i] - vsr[e] == se.r[k] * i_term_real[a] - se.x[k] * i_term_imag[a])
            JuMP.@constraint(nm.model, v_imag[i] - vsi[e] == se.r[k] * i_term_imag[a] + se.x[k] * i_term_real[a])
        end

        JuMP.@constraint(nm.model, sum(i_term_real[a] for a in A) == 0.0)
        JuMP.@constraint(nm.model, sum(i_term_imag[a] for a in A) == 0.0)
    end

    return nothing
end

const STAR_R = [0.010, 0.020, 0.030]
const STAR_X = [0.100, 0.200, 0.300]

"a three-terminal network: one reference node feeding two loads through a star edge"
function star_network()
    I = Dict{Int,AbstractNode}(
        1 => Node(; id = 1, type = REF, v_magn_set = 1.02, v_angl_set = 0.0),
        2 => Node(; id = 2, type = PQ),
        3 => Node(; id = 3, type = PQ))
    E = Dict{Int,AbstractEdge}(
        1 => StarEdge(; id = 1, terminals = [1, 2, 3], r = STAR_R, x = STAR_X))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1),
        2 => FixedLoad(; id = 2, node = 2, p_set = 0.40, q_set = 0.15),
        3 => FixedLoad(; id = 3, node = 3, p_set = 0.25, q_set = 0.10))

    return NetworkData(Network(I, E, U); name = "star")
end

"the same network with the star point written out as a fourth node and three branches"
function split_network()
    I = Dict{Int,AbstractNode}(
        1 => Node(; id = 1, type = REF, v_magn_set = 1.02, v_angl_set = 0.0),
        2 => Node(; id = 2, type = PQ),
        3 => Node(; id = 3, type = PQ),
        4 => Node(; id = 4, type = PQ))
    E = Dict{Int,AbstractEdge}(
        k => Branch(; id = k, terminals = [k, 4], r = STAR_R[k], x = STAR_X[k]) for k in 1:3)
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1),
        2 => FixedLoad(; id = 2, node = 2, p_set = 0.40, q_set = 0.15),
        3 => FixedLoad(; id = 3, node = 3, p_set = 0.25, q_set = 0.10))

    return NetworkData(Network(I, E, U); name = "split")
end

@testset "multi-terminal edges" begin

    @testset "the topology carries three arcs for one edge" begin
        net = network(star_network())

        @test nterminals(edge(net, 1)) == 3
        @test length(arcs(net)) == 3
        @test edge_arcs(net, 1) == [Arc(1, 1, 1), Arc(1, 2, 2), Arc(1, 3, 3)]
        @test node_arcs(net, 2) == [Arc(1, 2, 2)]
        @test StarEdge in edge_types()
    end

    @testset "a star edge and its two-terminal equivalent agree" begin
        star  = quiet(() -> solve_lf(star_network(),  IVRFormulation, OPTIMIZER))
        split = quiet(() -> solve_lf(split_network(), IVRFormulation, OPTIMIZER))

        @test star["termination_status"]  == JuMP.LOCALLY_SOLVED
        @test split["termination_status"] == JuMP.LOCALLY_SOLVED

        for i in 1:3
            @test nw_solution(star)["node"]["$i"]["v_magn"] ≈
                  nw_solution(split)["node"]["$i"]["v_magn"] atol = 1e-8
            @test nw_solution(star)["node"]["$i"]["v_angl"] ≈
                  nw_solution(split)["node"]["$i"]["v_angl"] atol = 1e-8
        end

        # the generator at the reference node covers the load plus the losses
        @test nw_solution(star)["unit"]["1"]["p_unit"] ≈
              nw_solution(split)["unit"]["1"]["p_unit"] atol = 1e-8
        @test nw_solution(star)["unit"]["1"]["p_unit"] > 0.65
    end

    @testset "the currents balance at the star point" begin
        result = quiet(() -> solve_lf(star_network(), IVRFormulation, OPTIMIZER))
        sol    = nw_solution(result)["edge"]["1"]["terminal"]

        @test sum(sol["$t"]["i_term_real"] for t in 1:3) ≈ 0.0 atol = 1e-8
        @test sum(sol["$t"]["i_term_imag"] for t in 1:3) ≈ 0.0 atol = 1e-8
    end
end

# A `Branch` with more than two terminals is n π-sections from its terminals to one
# point. It is checked against two things that say the same in other words: the
# `Transformer` without ratios, whose model is written independently in
# `transformer.jl`, and the point written out as a node with one two-terminal
# `Branch` to each terminal. Everything is within solver tolerance of them, or the
# model of the section is wrong.

"the series impedance and the total shunt of each section of the edge"
const SECTION = (r    = [0.010, 0.020, 0.030],
                 x      = [0.100, 0.200, 0.300],
                 g_shnt = [0.001, 0.000, 0.002],
                 b_shnt = [0.020, 0.040, 0.030])

"a `Branch` with three terminals, `kw` giving what else it has"
section_branch(; kw...) = Branch(; id = 1, terminals = [1, 2, 3], SECTION..., kw...)

"""
The same edge as a `Transformer` of ratio one: half the shunt of a section sits at its
terminal, which is where a winding has its own, and the other halves meet at the star
point as the magnetising branch.
"""
section_tee(; kw...) = Transformer(; id = 1, terminals = [1, 2, 3], r = SECTION.r,
                                   x = SECTION.x, g_shnt = SECTION.g_shnt ./ 2,
                                   b_shnt = SECTION.b_shnt ./ 2, g_mgnt = sum(SECTION.g_shnt) / 2,
                                   b_mgnt = sum(SECTION.b_shnt) / 2, kw...)

"the point written out as a node, with a two-terminal branch to each terminal"
section_split(; kw...) = Dict{Int,AbstractEdge}(
    k => Branch(; id = k, terminals = [k, 4], r = SECTION.r[k], x = SECTION.x[k],
                g_shnt = SECTION.g_shnt[k], b_shnt = SECTION.b_shnt[k], kw...) for k in 1:3)

"""
One reference node feeding two loads through the edge `E`, a dearer unit at the first
load for what the edge cannot carry. `dear` leaves that unit out, for a load flow.
"""
function section_network(E::Dict{Int,<:AbstractEdge}; dear::Bool = true, market = 0.65)
    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, v_magn_set = 1.02, v_angl_set = 0.0),
                               2 => Node(; id = 2), 3 => Node(; id = 3))
    haskey(E, 3) && (I[4] = Node(; id = 4))

    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, p_max = 5.0, q_min = -5.0, q_max = 5.0,
                       p_set = market, c = [0.0, 10.0]),
        3 => FixedLoad(; id = 3, node = 2, p_set = 0.40, q_set = 0.15),
        4 => FixedLoad(; id = 4, node = 3, p_set = 0.25, q_set = 0.10))
    dear && (U[2] = Generator(; id = 2, node = 2, p_max = 5.0, q_min = -5.0, q_max = 5.0,
                              p_set = 0.0, c = [0.0, 100.0]))

    return NetworkData(Network(I, E, U); name = "sections")
end

section_network(e::AbstractEdge; kw...) =
    section_network(Dict{Int,AbstractEdge}(1 => e); kw...)

"the apparent power into terminal `k` of edge 1 in a solution"
apparent(result, k) = hypot(nw_solution(result)["edge"]["1"]["terminal"]["$k"]["p_term"],
                            nw_solution(result)["edge"]["1"]["terminal"]["$k"]["q_term"])

@testset "a branch with three terminals" begin

    @testset "a load flow agrees with a transformer without ratios and with the split point" begin
        tee    = quiet(() -> solve_lf(section_network(section_tee(); dear = false),
                                      IVRFormulation, OPTIMIZER))
        branch = quiet(() -> solve_lf(section_network(section_branch(); dear = false),
                                      IVRFormulation, OPTIMIZER))
        split  = quiet(() -> solve_lf(section_network(section_split(); dear = false),
                                      IVRFormulation, OPTIMIZER))

        for result in (tee, branch, split)
            @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        end

        for i in 1:3, other in (tee, split)
            @test nw_solution(branch)["node"]["$i"]["v_magn"] ≈
                  nw_solution(other)["node"]["$i"]["v_magn"] atol = 1e-8
            @test nw_solution(branch)["node"]["$i"]["v_angl"] ≈
                  nw_solution(other)["node"]["$i"]["v_angl"] atol = 1e-8
        end

        # the shunts are in the model: without them the generator gives something else
        bare = quiet(() -> solve_lf(section_network(Branch(; id = 1, terminals = [1, 2, 3],
                                                           r = SECTION.r, x = SECTION.x);
                                                    dear = false),
                                    IVRFormulation, OPTIMIZER))
        @test abs(nw_solution(bare)["unit"]["1"]["q_unit"] -
                  nw_solution(branch)["unit"]["1"]["q_unit"]) > 1e-3
    end

    @testset "an optimal power flow agrees, with the rating of one terminal binding" begin
        free = quiet(() -> solve_opf(section_network(section_branch()),
                                     IVRFormulation, OPTIMIZER))

        rate = [0.5, Inf, Inf]
        tee    = quiet(() -> solve_opf(section_network(section_tee(; s_max = rate)),
                                       IVRFormulation, OPTIMIZER))
        branch = quiet(() -> solve_opf(section_network(section_branch(; s_max = rate)),
                                       IVRFormulation, OPTIMIZER))

        for result in (free, tee, branch)
            @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        end

        # the cheap unit would carry more than 0.5 into the edge, so the dear one is used
        @test apparent(free, 1) > 0.5 + 1e-3
        @test apparent(branch, 1) ≤ 0.5 + 1e-5
        @test branch["objective"] > free["objective"] + 1e-4

        @test branch["objective"] ≈ tee["objective"] atol = 1e-5
        for i in 1:3
            @test nw_solution(branch)["node"]["$i"]["v_magn"] ≈
                  nw_solution(tee)["node"]["$i"]["v_magn"] atol = 1e-5
        end
    end

    @testset "the linearized model agrees too, and so does the point written out" begin
        free = quiet(() -> solve_opf(section_network(section_branch()),
                                     LPFFormulation, OPTIMIZER))

        rate   = [0.5, Inf, Inf]
        tee    = quiet(() -> solve_opf(section_network(section_tee(; s_max = rate)),
                                       LPFFormulation, OPTIMIZER))
        branch = quiet(() -> solve_opf(section_network(section_branch(; s_max = rate)),
                                       LPFFormulation, OPTIMIZER))
        split  = quiet(() -> solve_opf(section_network(section_split()),
                                       LPFFormulation, OPTIMIZER))

        for result in (free, tee, branch, split)
            @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        end

        # losses are not in this model, so the edge carries the whole load and the
        # rating relieves it of what is over 0.5
        @test abs(nw_solution(free)["edge"]["1"]["terminal"]["1"]["p_term"]) ≈ 0.65 atol = 1e-6
        @test abs(nw_solution(branch)["edge"]["1"]["terminal"]["1"]["p_term"]) ≈ 0.5 atol = 1e-6
        @test branch["objective"] ≈ free["objective"] + 0.15 * (100.0 - 10.0) atol = 1e-5

        @test branch["objective"] ≈ tee["objective"] atol = 1e-6
        @test free["objective"]   ≈ split["objective"] atol = 1e-6
        for i in 1:3
            @test nw_solution(branch)["node"]["$i"]["v_angl"] ≈
                  nw_solution(tee)["node"]["$i"]["v_angl"] atol = 1e-6
            @test nw_solution(free)["node"]["$i"]["v_angl"] ≈
                  nw_solution(split)["node"]["$i"]["v_angl"] atol = 1e-6
        end
    end

    # 0.15 over the rating is relieved at 100 + 10 per pu, so a price above 110 buys
    # the relief and one below it buys the overload instead
    @testset "a rating on one terminal can be priced instead of enforced" begin
        data = section_network(section_branch(; s_max = [0.5, Inf, Inf]))

        dear = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER;
                                    redispatch = Redispatch(; overload = 500.0)))
        @test dear["termination_status"] == JuMP.LOCALLY_SOLVED
        @test dear["objective"] ≈ 0.15 * 110.0 atol = 1e-5
        @test nw_solution(dear)["edge"]["1"]["s_ovl"] ≈ 0.0 atol = 1e-6

        cheap = quiet(() -> solve_rd(data, LPFFormulation, OPTIMIZER;
                                     redispatch = Redispatch(; overload = 20.0)))
        @test cheap["termination_status"] == JuMP.LOCALLY_SOLVED
        @test cheap["objective"] ≈ 0.15 * 20.0 atol = 1e-5
        @test nw_solution(cheap)["edge"]["1"]["s_ovl"] ≈ 0.15 atol = 1e-6
    end
end
