################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.12.9 - a variable key is not reused, nor a constraint id in a build       #
################################################################################

# `var` and `con` are keyed by `Symbol`, shared by the package and every
# extension. A key asked for again with another index set used to be accepted,
# and the container already there handed back in its place, or a `MethodError`
# raised far from the cause. A key names one set of variables, and says so.

"the `ArgumentError` that `f` raises, or `nothing` where it raises none"
function error_of(f)
    try
        f()
    catch e
        e isa ArgumentError && return e
        rethrow()
    end

    return nothing
end

@testset "registers" begin

    data  = quiet(() -> parse_file(case("case5")))
    mn    = set_dimension(data, Dimension(:time => 2))
    fresh = () -> instantiate_model(mn, LoadFlowProblem, LPFFormulation; build = false)

    @testset "a variable key names one set of variables" begin
        # an array asked for again over other indices
        nm  = fresh()
        x   = variables!(nm, :x, 1:3; nw = 1)
        err = error_of(() -> variables!(nm, :x, 1:5; nw = 1))
        @test err isa ArgumentError
        @test occursin(":x", err.msg) && occursin("network index 1", err.msg)

        # an array asked for as a dictionary, and the other way round
        nm = fresh(); variables!(nm, :z, 1:3; nw = 1)
        @test_throws ArgumentError variable!(nm, :z, 1; nw = 1)
        nm = fresh(); variable!(nm, :w, 1; nw = 1)
        @test_throws ArgumentError variables!(nm, :w, 1:3; nw = 1)

        # a dictionary asked for again with ids of another type
        nm = fresh(); variable!(nm, :y, 1; nw = 1)
        err = error_of(() -> variable!(nm, :y, Arc(1, 1, 1); nw = 1))
        @test err isa ArgumentError && occursin(":y", err.msg)
        nm = fresh(); variable_container!(nm, :v; nw = 1, idtype = Int)
        @test_throws ArgumentError variable_container!(nm, :v; nw = 1, idtype = Arc)

        # asked for again as it was, it is the same container, and another network index is its own
        nm = fresh()
        x  = variables!(nm, :x, 1:3; nw = 1)
        @test variables!(nm, :x, 1:3; nw = 1) === x
        @test variables!(nm, :x, [1, 2, 3]; nw = 1) === x
        @test length(variables!(nm, :x, 1:5; nw = 2)) == 5
        v = variable!(nm, :y, 7; nw = 1)
        @test variable!(nm, :y, 7; nw = 1) === v
        @test variable!(nm, :y, 8; nw = 1) !== v
        c = variable_container!(nm, :v; nw = 1, idtype = Arc)
        @test variable_container!(nm, :v; nw = 1, idtype = Arc) === c
    end

end
