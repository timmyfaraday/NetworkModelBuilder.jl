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
            "Extending the package"     => "manual/extending.md",
        ],
        "Components" => [
            "The hierarchy" => "components/hierarchy.md",
            "Node"          => "components/node.md",
            "Branch"        => "components/branch.md",
            "Transformer"   => "components/transformer.md",
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
