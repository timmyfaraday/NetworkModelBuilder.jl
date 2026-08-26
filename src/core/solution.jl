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

################################################################################
# Solution                                                                     #
################################################################################

"""
    build_solution(nm)

Assemble the solution of `nm` into a dictionary.

The returned dictionary always carries the solver status and the metadata of the
run. It carries a `"solution"` entry only when the solver returned primal
values; that entry mirrors the extended graph, with a `"node"`, `"edge"` and
`"unit"` dictionary per network index:

```
result["solution"]["nw"]["1"]["node"]["4"]["vm"]
```

Use [`nw_solution`](@ref) to reach one network index without spelling out the
path. All quantities are in per unit on `result["baseMVA"]`, all angles in
radians.
"""
function build_solution(nm::NetworkModel{P,F}) where {P,F}
    result = Dict{String,Any}(
        "name"               => nm.data.name,
        "baseMVA"            => nm.data.baseMVA,
        "problem_type"       => P,
        "formulation_type"   => F,
        "termination_status" => JuMP.termination_status(nm.model),
        "primal_status"      => JuMP.primal_status(nm.model),
        "dual_status"        => JuMP.dual_status(nm.model),
        "solve_time"         => NaN,
    )

    if !JuMP.has_values(nm.model)
        @warn "the solver returned no primal solution, termination status is $(result["termination_status"])"
        return result
    end

    result["objective"] = JuMP.objective_value(nm.model)
    result["solution"]  = Dict{String,Any}("nw" => Dict{String,Any}(
        "$n" => Dict{String,Any}("node" => solution_node(nm, n),
                                 "edge" => solution_edge(nm, n),
                                 "unit" => solution_unit(nm, n))
        for n in nw_ids(nm)))

    return result
end

"""
    nw_solution(result, n = 1)

The part of `result` that belongs to network index `n`.
"""
function nw_solution(result::Dict{String,Any}, n::Int = 1)
    haskey(result, "solution") ||
        throw(ArgumentError("this result carries no solution, termination status is $(result["termination_status"])"))

    return result["solution"]["nw"]["$n"]
end

"""
    print_summary([io,] result; nw = 1)

Print a compact table of the node voltages and the unit injections of one
network index.
"""
print_summary(result::Dict{String,Any}; nw::Int = 1) = print_summary(stdout, result; nw)

function print_summary(io::IO, result::Dict{String,Any}; nw::Int = 1)
    sol = nw_solution(result, nw)

    Printf.@printf(io, "%s — %s with %s\n", result["name"],
                   result["problem_type"], result["formulation_type"])
    Printf.@printf(io, "status %s", result["termination_status"])
    haskey(result, "objective") && Printf.@printf(io, ", objective %.6f", result["objective"])
    Printf.@printf(io, "\n\nnode        vm [pu]     va [deg]\n")
    for i in sort(collect(keys(sol["node"])), by = x -> parse(Int, x))
        Printf.@printf(io, "%-8s %10.5f %12.5f\n", i, sol["node"][i]["vm"],
                       rad2deg(sol["node"][i]["va"]))
    end

    Printf.@printf(io, "\nunit     type        node      p [pu]      q [pu]\n")
    for u in sort(collect(keys(sol["unit"])), by = x -> parse(Int, x))
        e = sol["unit"][u]
        Printf.@printf(io, "%-8s %-11s %5d %11.5f %11.5f\n", u, e["type"], e["node"],
                       e["p"], e["q"])
    end

    return nothing
end
