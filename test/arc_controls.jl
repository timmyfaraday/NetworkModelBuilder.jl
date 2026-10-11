################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.12.0 - initial implementation                                             #
# v0.12.9 - the held controls are read through held_controls                   #
# v0.14.0 - a variable is named by the model, not by its caller                #
# v0.14.0 - variable and solution keys follow the nomenclature                 #
# v0.14.0 - the fields follow the nomenclature                                 #
# v0.15.0 - functions that write rows, duals and letters follow the map        #
################################################################################

# A control that belongs to one terminal of an edge rather than to the edge, such
# as the angle of one winding of a transformer. This file adds an edge with one
# angle per terminal from outside the package, as an extension would, and checks
# that a variable can be keyed by an arc and that a preventive redispatch holds
# each of them.

"""
A two-terminal edge whose terminals each shift the angle by a variable of their
own, `shift[a]`, held between `-limit` and `limit`. The flow is that of a
lossless line across the difference of the two shifts.
"""
Base.@kwdef struct ArcShifter <: AbstractEdge
    id       ::Int
    name     ::String           = ""
    terminals::Vector{Int}
    x        ::Float64
    limit    ::Float64          = 0.15
    status   ::Bool             = true
    ext      ::Dict{Symbol,Any} = Dict{Symbol,Any}()
end

register_edge_type!(ArcShifter)

function _NMB.variable_edge(nm::NetworkModel{P,F}, ::Type{ArcShifter};
                            nw::Int = nw_id_default(nm)
                           ) where {P<:AbstractProblemType,F<:LPFFormulation}
    variable_container!(nm, :shift; nw, idtype = Arc)

    for e in ids(nm, ArcShifter; nw), a in edge_arcs(nm, e; nw)
        sh = edge(nm, e; nw)::ArcShifter
        variable!(nm, :shift, a; nw,
                  start = 0.0, lower = -sh.limit, upper = sh.limit)
    end

    return nothing
end

function _NMB.fnct_edge(nm::NetworkModel{P,F}, ::Type{ArcShifter};
                              nw::Int = nw_id_default(nm)
                             ) where {P<:AbstractProblemType,F<:LPFFormulation}
    shift = _NMB.var(nm, :shift; nw)

    for e in ids(nm, ArcShifter; nw)
        sh         = edge(nm, e; nw)::ArcShifter
        a_fr, a_to = edge_arcs(nm, e; nw)

        fnct_edge_flow_linear!(nm, e, a_fr, a_to, susceptance(0.0, sh.x),
                                shift[a_fr] - shift[a_to]; nw)
    end

    return nothing
end

_NMB.redispatch_controls(::NetworkModel{P,F}, ::Type{ArcShifter}
                        ) where {P<:AbstractProblemType,F<:LPFFormulation} = (:shift,)

"""
A tight corridor `1–3` in parallel with a path `1–2–3` through an `ArcShifter`.
Edge 3 is out of service at the network indices in `out`.
"""
function arc_network(; dim::Dimension = Dimension(), out = ())
    status = isempty(out) ? true : nw_vector(dim, (n, c) -> n ∉ out)

    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF, v_magn_set = 1.0),
                               2 => Node(; id = 2), 3 => Node(; id = 3))
    E = Dict{Int,AbstractEdge}(
        1 => Branch(; id = 1, terminals = [1, 3], r = 0.0, x = 0.1, s_max = 0.5),
        2 => ArcShifter(; id = 2, terminals = [1, 2], x = 0.1),
        3 => Branch(; id = 3, terminals = [2, 3], r = 0.0, x = 0.1, status = status))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, p_max = 5.0, q_min = -5.0, q_max = 5.0,
                       p_set = 1.0, c = [0.0, 10.0]),
        2 => Generator(; id = 2, node = 3, p_max = 5.0, q_min = -5.0, q_max = 5.0,
                       p_set = 0.0, c = [0.0, 100.0]),
        3 => FixedLoad(; id = 3, node = 3, p_set = 1.0, q_set = 0.0))

    return NetworkData(Network(I, E, U; dim); name = "arcs", s_base_mva = 100.0)
end

@testset "controls that belong to a terminal" begin

    @testset "a variable can be keyed by an arc" begin
        nm = instantiate_model(arc_network(), OptimalPowerFlowProblem, LPFFormulation)
        a  = Arc(2, 1, 1)

        # the containers a component declares keep the type of their identifiers
        @test keytype(_NMB.var(nm, :shift; nw = 1)) === Arc
        @test keytype(_NMB.var(nm, :p_gen; nw = 1)) === Int
        @test isempty(variable_container!(nm, :nothing_here; nw = 1, idtype = Arc))
        @test keytype(variable_container!(nm, :nothing_here; nw = 1, idtype = Arc)) === Arc

        # created on first sight, returned and brought up to date on second
        v = variable!(nm, :probe, a; nw = 1, lower = 0.0, upper = 1.0)
        @test keytype(_NMB.var(nm, :probe; nw = 1)) === Arc
        @test variable!(nm, :probe, a; nw = 1, lower = 0.0, upper = 2.0) === v
        @test JuMP.upper_bound(v) == 2.0
        @test variable!(nm, :probe, Arc(2, 2, 2); nw = 1) !== v
    end

    @testset "a preventive redispatch holds each terminal's control" begin
        dim  = Dimension(:contingency => 2)
        data = arc_network(; dim, out = (2,))

        nm   = instantiate_model(data, RedispatchProblem, LPFFormulation)
        tied = held_controls(nm)

        @test (:edge, Arc(2, 1, 1), :shift, 2) in tied
        @test (:edge, Arc(2, 2, 2), :shift, 2) in tied
        @test (:edge, Arc(2, 1, 1), :shift, 1) ∉ tied             # the base case is the reference

        result = quiet(() -> optimize_model!(nm, OPTIMIZER))
        @test result["termination_status"] == JuMP.LOCALLY_SOLVED
        for a in (Arc(2, 1, 1), Arc(2, 2, 2))
            @test JuMP.value(_NMB.var(nm, :shift, a; nw = 1)) ≈
                  JuMP.value(_NMB.var(nm, :shift, a; nw = 2)) atol = 1e-6
        end

        # corrective, nothing is held
        free = instantiate_model(data, RedispatchProblem, LPFFormulation;
                                 ext = Dict{Symbol,Any}(:redispatch =>
                                     Redispatch(; control = :corrective)))
        @test isempty(held_controls(free))
    end
end
