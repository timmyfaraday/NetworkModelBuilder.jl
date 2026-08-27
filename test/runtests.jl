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

using Test
using Logging

using Ipopt
using JuMP

using NetworkModelBuilder

const _NMB = NetworkModelBuilder

const OPTIMIZER = JuMP.optimizer_with_attributes(Ipopt.Optimizer,
                                                 "print_level" => 0,
                                                 "tol"         => 1e-9,
                                                 "sb"          => "yes")

"the path of a Matpower case in the test data"
case(name::String) = joinpath(@__DIR__, "data", "matpower", "$name.m")

"run `f` with warnings suppressed, the bus type corrections are expected here"
quiet(f) = Logging.with_logger(f, Logging.NullLogger())

@testset "NetworkModelBuilder" begin
    include("dimension.jl")
    include("matpower.jl")
    include("network.jl")
    include("hierarchy.jl")
    include("dispatch.jl")
    include("lf.jl")
    include("opf.jl")
    include("lpf.jl")
    include("multinetwork.jl")
    include("multiterminal.jl")
end
