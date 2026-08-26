################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
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

    _NMB.var(nm; nw)[:vsr] = JuMP.@variable(nm.model, [e in E], base_name = "$(nw)_vsr", start = 1.0)
    _NMB.var(nm; nw)[:vsi] = JuMP.@variable(nm.model, [e in E], base_name = "$(nw)_vsi", start = 0.0)

    return nothing
end

"the voltage drop from every terminal to the star point, and the balance at the star point"
function _NMB.constraint_edge(nm::NetworkModel{P,F}, ::Type{StarEdge};
                              nw::Int = nw_id_default(nm)
                             ) where {P<:AbstractProblemType,F<:IVRFormulation}
    vr,  vi  = _NMB.var(nm, :vr;  nw), _NMB.var(nm, :vi;  nw)
    cr,  ci  = _NMB.var(nm, :cr;  nw), _NMB.var(nm, :ci;  nw)
    vsr, vsi = _NMB.var(nm, :vsr; nw), _NMB.var(nm, :vsi; nw)

    for e in ids(nm, StarEdge; nw)
        se = edge(nm, e; nw)::StarEdge
        A  = edge_arcs(nm, e; nw)

        for (k, a) in enumerate(A)
            i = a.node
            JuMP.@constraint(nm.model, vr[i] - vsr[e] == se.r[k] * cr[a] - se.x[k] * ci[a])
            JuMP.@constraint(nm.model, vi[i] - vsi[e] == se.r[k] * ci[a] + se.x[k] * cr[a])
        end

        JuMP.@constraint(nm.model, sum(cr[a] for a in A) == 0.0)
        JuMP.@constraint(nm.model, sum(ci[a] for a in A) == 0.0)
    end

    return nothing
end

const STAR_R = [0.010, 0.020, 0.030]
const STAR_X = [0.100, 0.200, 0.300]

"a three-terminal network: one reference node feeding two loads through a star edge"
function star_network()
    I = Dict{Int,AbstractNode}(
        1 => Node(; id = 1, type = REF, vm = 1.02, va = 0.0),
        2 => Node(; id = 2, type = PQ),
        3 => Node(; id = 3, type = PQ))
    E = Dict{Int,AbstractEdge}(
        1 => StarEdge(; id = 1, terminals = [1, 2, 3], r = STAR_R, x = STAR_X))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1),
        2 => Load(; id = 2, node = 2, pd = 0.40, qd = 0.15),
        3 => Load(; id = 3, node = 3, pd = 0.25, qd = 0.10))

    return NetworkData(Network(I, E, U); name = "star")
end

"the same network with the star point written out as a fourth node and three branches"
function split_network()
    I = Dict{Int,AbstractNode}(
        1 => Node(; id = 1, type = REF, vm = 1.02, va = 0.0),
        2 => Node(; id = 2, type = PQ),
        3 => Node(; id = 3, type = PQ),
        4 => Node(; id = 4, type = PQ))
    E = Dict{Int,AbstractEdge}(
        k => Branch(; id = k, terminals = [k, 4], r = STAR_R[k], x = STAR_X[k]) for k in 1:3)
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1),
        2 => Load(; id = 2, node = 2, pd = 0.40, qd = 0.15),
        3 => Load(; id = 3, node = 3, pd = 0.25, qd = 0.10))

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
            @test nw_solution(star)["node"]["$i"]["vm"] ≈
                  nw_solution(split)["node"]["$i"]["vm"] atol = 1e-8
            @test nw_solution(star)["node"]["$i"]["va"] ≈
                  nw_solution(split)["node"]["$i"]["va"] atol = 1e-8
        end

        # the generator at the reference node covers the load plus the losses
        @test nw_solution(star)["unit"]["1"]["p"] ≈
              nw_solution(split)["unit"]["1"]["p"] atol = 1e-8
        @test nw_solution(star)["unit"]["1"]["p"] > 0.65
    end

    @testset "the currents balance at the star point" begin
        result = quiet(() -> solve_lf(star_network(), IVRFormulation, OPTIMIZER))
        sol    = nw_solution(result)["edge"]["1"]["terminal"]

        @test sum(sol["$t"]["cr"] for t in 1:3) ≈ 0.0 atol = 1e-8
        @test sum(sol["$t"]["ci"] for t in 1:3) ≈ 0.0 atol = 1e-8
    end
end
