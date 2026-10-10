################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.12.8 - the constructors refuse input a model cannot use                   #
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
        @test_throws ArgumentError Node(; id = 1, vmin = 1.1, vmax = 0.9)
        @test_throws ArgumentError Node(; id = 1, vmin = -1.0)
        @test_throws ArgumentError Node(; id = 1, vmin = NaN)
        @test_throws ArgumentError Node(; id = 1, vmax = NaN)
        @test_throws ArgumentError Node(; id = 1, base_kv = -380.0)
        @test_throws ArgumentError Node(; id = 1, base_kv = NaN)
        @test_throws ArgumentError Node(; id = 1, vm = NaN)
        @test_throws ArgumentError Node(; id = 1, va = Inf)

        # a profile is refused at the one network index that breaks it
        dim = Dimension(:time => 3)
        @test_throws ArgumentError Node(; id = 1, vm = nw_vector(dim, [1.0, NaN, 1.0]))
        @test_throws ArgumentError Node(; id = 1, vmin = nw_vector(dim, [0.9, 1.2, 0.9]), vmax = 1.1)

        # and it says which node and what
        err = refusal(() -> Node(; id = 4, vmin = 1.1, vmax = 0.9))
        @test err isa ArgumentError
        @test occursin("node 4", err.msg) && occursin("vmin", err.msg)

        # what real data carries is not refused: Matpower's case14 gives every bus a base_kv of 0
        @test Node(; id = 1, base_kv = 0.0).base_kv == 0.0
        @test Node(; id = 1, vmin = 0.0).vmin == 0.0
        data = quiet(() -> parse_file(case("case14")))
        @test all(n -> n.base_kv == 0.0, values(nodes(network(data))))
    end

    @testset "a generator" begin
        @test_throws ArgumentError Generator(; id = 1, node = 1, pmin = 2.0, pmax = 1.0)
        @test_throws ArgumentError Generator(; id = 1, node = 1, qmin = 1.0, qmax = -1.0)
        @test_throws ArgumentError Generator(; id = 1, node = 1, pmax = NaN)
        @test_throws ArgumentError Generator(; id = 1, node = 1, pmin = NaN)
        @test_throws ArgumentError Generator(; id = 1, node = 1, qmax = NaN)
        @test_throws ArgumentError Generator(; id = 1, node = 1, pg = NaN)
        @test_throws ArgumentError Generator(; id = 1, node = 1, qg = Inf)
        @test_throws ArgumentError Generator(; id = 1, node = 1, vg = NaN)
        @test_throws ArgumentError Generator(; id = 1, node = 1, cost = [NaN])
        @test_throws ArgumentError Generator(; id = 1, node = 1, cost = [0.0, Inf])
        @test_throws ArgumentError Generator(; id = 1, node = 1, max_energy_per_period = -1.0)

        # a profile is refused at the one network index that breaks it
        dim = Dimension(:time => 3)
        @test_throws ArgumentError Generator(; id = 1, node = 1, pg = nw_vector(dim, [0.5, NaN, 0.5]))
        @test_throws ArgumentError Generator(; id = 1, node = 1, pmin = nw_vector(dim, [0.0, 2.0, 0.0]), pmax = 1.0)
        @test_throws ArgumentError Generator(; id = 1, node = 1,
                                             cost = nw_vector(dim, [[0.0, 1.0], [0.0, NaN], [0.0, 1.0]]))

        err = refusal(() -> Generator(; id = 7, node = 1, pmin = 2.0, pmax = 1.0))
        @test err isa ArgumentError
        @test occursin("generator 7", err.msg) && occursin("pmin", err.msg)

        # an unbounded limit, a pinned one and the default price are not refused
        @test Generator(; id = 1, node = 1).pmax == Inf
        @test Generator(; id = 1, node = 1).qmin == -Inf
        @test Generator(; id = 1, node = 1, pmin = 0.4, pmax = 0.4).pmin == 0.4
        @test isnan(Generator(; id = 1, node = 1).cost_up)
    end

    @testset "a load and a shunt" begin
        @test_throws ArgumentError FixedLoad(; id = 1, node = 1, pd = NaN)
        @test_throws ArgumentError FixedLoad(; id = 1, node = 1, qd = Inf)
        @test_throws ArgumentError Shunt(; id = 1, node = 1, gs = NaN)
        @test_throws ArgumentError Shunt(; id = 1, node = 1, bs = Inf)

        dim = Dimension(:time => 3)
        @test_throws ArgumentError FixedLoad(; id = 1, node = 1, pd = nw_vector(dim, [0.5, NaN, 0.5]))
        @test_throws ArgumentError Shunt(; id = 1, node = 1, bs = nw_vector(dim, [0.1, 0.1, Inf]))

        err = refusal(() -> FixedLoad(; id = 5, node = 1, pd = NaN))
        @test err isa ArgumentError
        @test occursin("load 5", err.msg)
        err = refusal(() -> Shunt(; id = 6, node = 1, bs = NaN))
        @test err isa ArgumentError
        @test occursin("shunt 6", err.msg)

        # a negative demand is a load that injects, a negative susceptance an inductor: neither is refused
        @test FixedLoad(; id = 1, node = 1, pd = -0.3).pd == -0.3
        @test Shunt(; id = 1, node = 1, bs = -0.19).bs == -0.19
    end

end
