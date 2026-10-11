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
