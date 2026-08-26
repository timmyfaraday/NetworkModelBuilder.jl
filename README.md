<a href="https://github.com/timmyfaraday/NetworkModelBuilder.jl/actions?query=workflow%3ACI"><img src="https://github.com/timmyfaraday/NetworkModelBuilder.jl/workflows/CI/badge.svg"></img></a>

# NetworkModelBuilder.jl

NetworkModelBuilder.jl builds optimization models for power system problems. It
takes the ideas of [PowerModels.jl](https://github.com/lanl-ansi/PowerModels.jl)
and [FlexPlan.jl](https://github.com/Electa-Git/FlexPlan.jl) and changes three
things about them.

## Three ideas

### 1. A problem type and a formulation type, dispatched on together

PowerModels.jl uses one type hierarchy, `AbstractPowerModel`, for the
formulation, and an ordinary function, `build_opf`, for the problem. Here both
are types, and every variable, constraint and objective is a method that
dispatches on the pair.

```
AbstractProblemType                  AbstractFormulationType
├── AbstractPowerFlowProblem         ├── AbstractACFormulation
│   └── LoadFlowProblem              │   ├── AbstractCurrentFormulation
└── AbstractDispatchProblem          │   │   └── IVRFormulation
    ├── OptimalPowerFlowProblem      │   └── AbstractPowerFormulation
    └── RedispatchProblem            │       ├── ACPFormulation
                                     │       └── ACRFormulation
                                     └── AbstractDCFormulation
                                         └── DCPFormulation

                    NetworkModel{LoadFlowProblem, IVRFormulation}
```

The problem type answers *which question is asked of the network*: which degrees
of freedom are free, which are fixed by a setpoint, what is minimized. The
formulation type answers *in which variables the physics are written*:
rectangular or polar voltage, current or power flow, exact or relaxed. The two
are orthogonal, so they get an axis each.

The payoff is visible in `src/comp/node/node.jl`, where the same call resolves
to a different constraint depending on the problem:

```julia
# a load flow pins the complex voltage at the reference node
constraint_node_voltage_reference(nm::NetworkModel{<:AbstractPowerFlowProblem,<:IVRFormulation}; nw)

# a dispatch problem pins the angle only and lets the magnitude float
constraint_node_voltage_reference(nm::NetworkModel{<:AbstractDispatchProblem,<:IVRFormulation}; nw)
```

Every tag in both hierarchies is an abstract type, so an extension package
specialises one by subtyping it, e.g., `abstract type HarmonicIVRFormulation <:
IVRFormulation end`.

### 2. An extended graph `(I, E, U)`, with multi-terminal edges

A power system is an extended graph of nodes `I`, edges `E` and units `U`.

- An **edge** `(e, i, j, ...)` connects an *ordered list* of nodes. Nothing in
  the package assumes there are two of them, so a three-winding transformer or a
  multi-terminal HVDC link is an edge like any other.
- A **unit** `(u, i)` connects to a single node. Generators, loads and shunts are
  all units, and they all inject through the same variable pair, so the node
  balance is

  ```julia
  sum(cr[a] for a in node_arcs(nm, i; nw)) == sum(cru[u] for u in node_units(nm, i; nw))
  ```

  and knows nothing about what kinds of unit exist.

Edge variables are indexed by an `Arc(edge, terminal, node)`, not by a pair
`(e, i)`. The terminal position is part of the identity because terminals are
not interchangeable — the windings of a transformer differ — and because two
terminals of one edge may land on the same node.

`test/multiterminal.jl` adds a three-terminal star edge from outside the
package, in the way an extension package would, and checks it against the same
network written with three ordinary branches and an explicit star node.

### 3. Every dimension aggregated under one network index

Time, contingencies, harmonics and scenarios are all axes of the same problem.
A `Dimension` holds their names and sizes and gives the bijection between a
coordinate tuple and the scalar network index `n` that labels the variables.

```julia
julia> dim = Dimension(:time => 24, :contingency => 3);

julia> nw_ids(dim; contingency = 2)     # every hour of the second contingency
julia> coordinates(dim, 26)             # (time = 2, contingency = 2)
julia> prev_id(dim, 26, :time)          # 25, the hour before, same contingency
```

The index arithmetic — `similar_id`, `first_id`, `prev_ids`, `next_ids` — is
what a coupling constraint needs: a storage balance links `n` to
`prev_id(dim, n, :time)`, a non-anticipativity constraint links the scenarios
returned by `similar_ids(dim, n; scenario = 1:dim_length(dim, :scenario))`.

## Installation

The package requires `Julia 1.10` or newer.

```julia
] add https://github.com/timmyfaraday/NetworkModelBuilder.jl
```

## Quick start

```julia
using NetworkModelBuilder, Ipopt

result = solve_lf("case14.m", IVRFormulation, Ipopt.Optimizer)
print_summary(result)

nw_solution(result)["node"]["4"]["vm"]        # 1.01767
nw_solution(result)["unit"]["1"]["pg"]        # 2.32393
```

An optimal power flow over three hours with a load profile:

```julia
data  = parse_file("case5.m")
dim   = Dimension(:time => [Dict{Symbol,Any}(:scale => s, :weight => 1.0) for s in (0.9, 1.0, 1.1)])
multi = replicate(data, dim; apply! = function (net, n, coordinates)
    s = dim_prop(dim, n, :time, :scale)
    for (u, cmp) in net.unit
        cmp isa Load || continue
        net.unit[u] = Load(; id = cmp.id, node = cmp.node, pd = cmp.pd * s, qd = cmp.qd * s)
    end
end)

result = solve_model(multi, OptimalPowerFlowProblem, IVRFormulation, Ipopt.Optimizer)
```

## Package layout

The code of a component lives in one file, which holds its data structure, its
variables and its constraints together, and those files follow the `(I, E, U)`
hierarchy:

```
src/
├── core/
│   ├── types.jl        the two type hierarchies
│   ├── dimension.jl    the network index
│   ├── network.jl      the extended graph (I, E, U) and its topology
│   ├── model.jl        NetworkModel, the accessors and the build pipeline
│   ├── objective.jl
│   └── solution.jl
├── comp/
│   ├── node/node.jl            I — data, variables, constraints
│   ├── edge/edge.jl            E — the shared terminal currents and the registry
│   ├── edge/branch.jl          E — a two-terminal π-equivalent
│   ├── unit/unit.jl            U — the shared injection currents and the registry
│   ├── unit/generator.jl       U
│   ├── unit/load.jl            U
│   └── unit/shunt.jl           U
├── prob/
│   ├── lf.jl           LoadFlowProblem
│   ├── opf.jl          OptimalPowerFlowProblem
│   └── rd.jl           RedispatchProblem — a sketch, not implemented
└── io/
    ├── common.jl
    └── matpower.jl
```

There is deliberately no `src/form/` directory. A formulation is a set of
methods spread over the component files, not a place; keeping the whole of a
branch in one file is worth more than keeping the whole of IVR in one file.

## What is implemented

|                              | `IVRFormulation` | `ACPFormulation` | `ACRFormulation` | `DCPFormulation` |
|:-----------------------------|:-----------------|:-----------------|:-----------------|:-----------------|
| `LoadFlowProblem`            | yes              | —                | —                | —                |
| `OptimalPowerFlowProblem`    | yes              | —                | —                | —                |
| `RedispatchProblem`          | sketched         | —                | —                | —                |

The formulation types that carry no methods are declared so that the hierarchy
is complete; asking for one reports what is available instead of building a
wrong model:

```
ERROR: NetworkModelBuilder has no model builder for
    problem type     : LoadFlowProblem
    formulation type : ACPFormulation
Implemented combinations are:
    LoadFlowProblem with IVRFormulation
    OptimalPowerFlowProblem with IVRFormulation
```

Components: `Node`, `Branch`, `Generator`, `Load`, `Shunt`. Readers: Matpower.

The two implemented models are checked against PowerModels.jl v0.21 in
`test/`: the load flow reproduces its AC power flow solution on `case14` and
`case5` to `1e-6`, and the optimal power flow reproduces its objective on
`case14`, `case5` and `case3` to a relative `1e-6`.

## Extending

**A new edge or unit type.** Write one file with the struct, its
`variable_edge`/`variable_unit` and `constraint_edge`/`constraint_unit` methods,
and call `register_edge_type!` or `register_unit_type!`. The problem builders
walk those registries, so nothing in `src/prob/` has to change.
`test/multiterminal.jl` is a worked example.

**A new formulation.** Add the tag to `src/core/types.jl` and a method per
component file, dispatching on it. Nothing outside the component files moves.

**A new problem.** Add the tag to `src/core/types.jl`, a `build_model!` method
in `src/prob/`, an `objective` method, and a `register_model!` call. Where the
new problem changes how a component behaves — different bounds, an extra
variable — add a method in that component's file dispatching on the new problem
type. `src/prob/rd.jl` sketches this for a redispatch problem.

## Differences from PowerModels.jl

| | PowerModels.jl | NetworkModelBuilder.jl |
|:-|:-|:-|
| problem | a `build_*` function | a type, dispatched on |
| formulation | `AbstractPowerModel` subtype | a type, dispatched on |
| data | `Dict{String,Any}` | typed structs |
| branch | two-terminal, `f_bus`/`t_bus` | an edge with any number of terminals |
| flow index | `(l, i, j)` arc | `Arc(edge, terminal, node)` |
| gen/load/shunt | three separate balance terms | one set `U` with one injection variable pair |
| code layout | by kind — `variable.jl`, `constraint.jl` | by component — one file per component |
| multinetwork | replicated `nw` dictionaries | `Dimension` over named axes, network index arithmetic |

## Acknowledgements

The design owes its structure to
[PowerModels.jl](https://github.com/lanl-ansi/PowerModels.jl), by Carleton
Coffrin and contributors, and its handling of problem dimensions to
[FlexPlan.jl](https://github.com/Electa-Git/FlexPlan.jl).

## License

This code is provided under a BSD 3-Clause License.
