################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
################################################################################

using Documenter
using NetworkModelBuilder

makedocs(
    sitename = "NetworkModelBuilder.jl",
    authors  = "Tom Van Acker",
    modules  = [NetworkModelBuilder],
    format   = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical  = "https://timmyfaraday.github.io/NetworkModelBuilder.jl",
    ),
    pages = [
        "Home" => "index.md",
        "Manual" => [
            "The extended graph"        => "manual/extended_graph.md",
            "The network index"         => "manual/network_index.md",
            "Problems and formulations" => "manual/problems_formulations.md",
            "The linearized formulation" => "manual/linearized.md",
            "Tabular input"             => "manual/tabular_input.md",
            "Extending the package"     => "manual/extending.md",
        ],
        "Problems" => [
            "Overview"           => "problems/overview.md",
            "Load flow" => [
                "The problem"      => "problems/load_flow/index.md",
                "IVR formulation"  => "problems/load_flow/ivr.md",
                "LPF formulation"  => "problems/load_flow/lpf.md",
            ],
            "Optimal power flow" => [
                "The problem"      => "problems/optimal_power_flow/index.md",
                "IVR formulation"  => "problems/optimal_power_flow/ivr.md",
                "LPF formulation"  => "problems/optimal_power_flow/lpf.md",
            ],
            "Redispatch" => [
                "The problem"      => "problems/redispatch/index.md",
                "IVR formulation"  => "problems/redispatch/ivr.md",
                "LPF formulation"  => "problems/redispatch/lpf.md",
            ],
        ],
        "Components" => [
            "The hierarchy" => "components/hierarchy.md",
            "Node"          => "components/node.md",
            "Branch"        => "components/branch.md",
            "Transformer"   => "components/transformer.md",
            "DC link"       => "components/dc_link.md",
            "Generator"     => "components/generator.md",
            "Load"          => "components/load.md",
            "Storage"       => "components/storage.md",
            "Shunt"         => "components/shunt.md",
        ],
        "API reference" => "api.md",
    ],
    checkdocs = :exports,
    warnonly  = [:missing_docs],
)

deploydocs(
    repo      = "github.com/timmyfaraday/NetworkModelBuilder.jl.git",
    devbranch = "main",
)
