################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
# v0.10.2 - a tidy solution_tables view, alongside nw_solution                 #
################################################################################

################################################################################
# Solution                                                                     #
################################################################################

"""
    build_solution(nm; nws = nw_ids(nm))

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

`nws` says which network indices the entry holds, all of them by default. Building
a solution is most of what asking for one costs, so a caller that keeps a few of
the indices, as a rolling horizon does, asks for those. An index the model does
not have is an error.
"""
function build_solution(nm::NetworkModel{P,F}; nws::AbstractVector{Int} = nm.nws) where {P,F}
    missing_nws = [n for n in nws if !insorted(n, nm.nws)]
    isempty(missing_nws) ||
        throw(ArgumentError("a solution was asked for network indices $missing_nws, which this model does not have"))

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
        for n in nws))

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
    solution_tables(data, result)

A tidy view of `result`, one table per family of the extended graph.

Returns `(; node, edge, unit)`, each a `NamedTuple` of columns, one row per
network index and component — an edge's row is per **terminal**, since an edge
may have any number of them, not always two. Every dimension `data` is posed
over becomes its own column (`time`, `contingency`, ...), named the way
[`coordinates`](@ref) names it, so the result is a flat table to filter or group
by rather than a tree to walk by hand. A quantity only some components or some
network indices report — a nodal price without duals, a tap only a transformer
has — is `missing` where it wasn't; a column no row ever has at all is dropped
rather than kept `missing` throughout.

| table  | one row per                    | columns                                                  |
|:-------|:--------------------------------|:-----------------------------------------------------------|
| `node` | network index, node              | `id`, `name`, `type` (`PQ`/`PV`/`REF`/`ISOLATED`), `vm`, `va`, ... |
| `edge` | network index, edge, terminal     | `id`, `name`, `type`, `terminal`, `node`, `p`, `q`, ...      |
| `unit` | network index, unit               | `id`, `name`, `type`, `node`, `p`, `q`, ...                  |

This is an addition alongside [`nw_solution`](@ref), not a replacement — the
nested dictionary stays exactly as it is, the direct read of `result`.
`solution_tables` is for a caller who wants to slice, filter or plot the same
numbers instead: every column is a plain `Vector`, so `DataFrame(tables.node)`
(with DataFrames.jl, not a dependency of this package) is an ordinary table —
the same shape [`zorba_tables`](@ref) and [`security_tables`](@ref) already
return.

# Examples
```julia
tables = solution_tables(data, result)
tables.node.vm                              # every node's voltage, every index
tables.edge.p[tables.edge.terminal .== 1]   # the flow into every edge's terminal 1
```
"""
function solution_tables(data::NetworkData, result::Dict{String,Any})
    dim = dimension(data)
    net = network(data)
    ns  = nw_ids(dim)

    return (; node = _node_table(net, dim, result, ns),
            edge = _edge_table(net, dim, result, ns),
            unit = _unit_table(net, dim, result, ns))
end

"the coordinates of network index `n`, as a `Dict{String,Any}` row seed"
_coord_row(dim::Dimension, n::Int) =
    Dict{String,Any}(string(k) => v for (k, v) in pairs(coordinates(dim, n)))

"flatten `value` into `row` under `key`, a nested `Dict` becoming `key_subkey` columns"
function _flatten!(row::Dict{String,Any}, key::String, value)
    if value isa AbstractDict
        for (k, v) in value
            _flatten!(row, "$(key)_$(k)", v)
        end
    else
        row[key] = value
    end

    return row
end

"the sorted numeric keys of `dict`, e.g. `\"1\", \"2\", \"10\"` rather than lexicographic order"
_sorted_ids(dict::Dict{String,Any}) = sort!(collect(keys(dict)); by = x -> parse(Int, x))

"the tidy node table `solution_tables` returns"
function _node_table(net::Network, dim::Dimension, result::Dict{String,Any}, ns::Vector{Int})
    rows = Dict{String,Any}[]
    for n in ns
        sol = nw_solution(result, n)["node"]
        for i_str in _sorted_ids(sol)
            entry = sol[i_str]
            i     = parse(Int, i_str)
            row   = _coord_row(dim, n)
            row["id"]   = i
            row["name"] = node(net, i; nw = n).name
            row["type"] = string(node(net, i; nw = n).type)
            for (k, v) in entry
                _flatten!(row, k, v)
            end
            push!(rows, row)
        end
    end

    return _tidy(rows, ["id", "name", "type"])
end

"the tidy unit table `solution_tables` returns"
function _unit_table(net::Network, dim::Dimension, result::Dict{String,Any}, ns::Vector{Int})
    rows = Dict{String,Any}[]
    for n in ns
        sol = nw_solution(result, n)["unit"]
        for u_str in _sorted_ids(sol)
            entry = sol[u_str]
            u     = parse(Int, u_str)
            row   = _coord_row(dim, n)
            row["id"]   = u
            row["name"] = unit(net, u; nw = n).name
            for (k, v) in entry
                _flatten!(row, k, v)
            end
            push!(rows, row)
        end
    end

    return _tidy(rows, ["id", "name", "type", "node"])
end

"the tidy edge table `solution_tables` returns, one row per edge terminal"
function _edge_table(net::Network, dim::Dimension, result::Dict{String,Any}, ns::Vector{Int})
    rows = Dict{String,Any}[]
    for n in ns
        sol = nw_solution(result, n)["edge"]
        for e_str in _sorted_ids(sol)
            entry = sol[e_str]
            e     = parse(Int, e_str)
            shell = _coord_row(dim, n)
            shell["id"]   = e
            shell["name"] = edge(net, e; nw = n).name
            shell["type"] = string(nameof(typeof(edge(net, e; nw = n))))
            for (k, v) in entry
                k == "terminal" && continue
                _flatten!(shell, k, v)
            end
            for t_str in _sorted_ids(entry["terminal"])
                row = copy(shell)
                row["terminal"] = parse(Int, t_str)
                for (k, v) in entry["terminal"][t_str]
                    _flatten!(row, k, v)
                end
                push!(rows, row)
            end
        end
    end

    return _tidy(rows, ["id", "name", "type", "terminal", "node"])
end

"row dicts into one `NamedTuple` of columns: `first` in that order, the rest sorted, any column no row has at all dropped"
function _tidy(rows::Vector{Dict{String,Any}}, first::Vector{String})
    present = reduce(union!, (Set(keys(row)) for row in rows); init = Set{String}())
    cols    = [c for c in first if c in present]
    append!(cols, sort!(collect(setdiff(present, first))))

    return NamedTuple{Tuple(Symbol.(cols))}(
        Tuple([get(row, c, missing) for row in rows] for c in cols))
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
