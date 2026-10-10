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

end
