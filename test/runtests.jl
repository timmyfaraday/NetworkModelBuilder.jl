################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
# v0.9.4 - the thread-safety regression tests                                  #
# v0.9.7 - the PowerModels.jl live cross-check                                 #
# v0.10.0 - the security tables test                                           #
# v0.10.2 - the solution tables test                                           #
# v0.11.0 - the switch test                                                    #
# v0.11.0 - the islands test                                                   #
# v0.11.0 - imports HiGHS, for the linear programs a switch makes              #
# v0.11.0 - imports Juniper, for a free switch in current                      #
# v0.12.0 - the transformers, as they behave                                   #
# v0.12.0 - the per-terminal control test                                      #
################################################################################

using Test
using Logging
using Markdown

using Arrow
using Ipopt
using JuMP
using Parquet2
import HiGHS         # `using` would export names of its own into every test file
import Juniper       # the same, and the solver of a nonconvex mixed-integer program
import PowerModels   # `using` would export `parse_file`, `ids`, ... over this package's own

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
    include("tables.jl")
    include("network.jl")
    include("hierarchy.jl")
    include("dispatch.jl")
    include("lf.jl")
    include("opf.jl")
    include("lpf.jl")
    include("powermodels.jl")
    include("rd.jl")
    include("transformer.jl")
    include("arc_controls.jl")
    include("dc_link.jl")
    include("switch.jl")
    include("islands.jl")
    include("slack.jl")
    include("zorba.jl")
    include("dashboard.jl")
    include("price.jl")
    include("multinetwork.jl")
    include("multiterminal.jl")
    include("solution_tables.jl")
    include("thread_safety.jl")
    include("docs.jl")
end
