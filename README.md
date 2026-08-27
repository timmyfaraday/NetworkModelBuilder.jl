<a href="https://github.com/timmyfaraday/NetworkModelBuilder.jl/actions?query=workflow%3ACI"><img src="https://github.com/timmyfaraday/NetworkModelBuilder.jl/workflows/CI/badge.svg"></img></a>
<a href="https://timmyfaraday.github.io/NetworkModelBuilder.jl/"><img src="https://github.com/timmyfaraday/NetworkModelBuilder.jl/workflows/Documentation/badge.svg"></img></a>

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
                                     └── AbstractLinearizedFormulation
                                         └── LPFFormulation

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

### 3. Every dimension under one network index, and varying data on the component

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

There is **one extended graph**, not one per network index. A field whose value
the network index changes is stored on its component as a `NetworkVector` with
one entry per index; a field that does not change is stored as a plain value.
The impedance of a line is written once whether the problem spans one hour or
eight thousand.

```julia
Load(; id = 4, node = 2,
     pd = nw_vector(dim, :time, profile),   # varies: a NetworkVector
     qd = 0.05)                             # constant: a Float64
```

Both cases are read through one getter, so no calling code has to ask which it
is holding:

```julia
nw_value(dim, x, n)          # a constant as it is, a NetworkVector indexed at n
nw_component(dim, comp, n)   # the whole component, every field resolved at n
```

`nw_component` is why the component files read plain fields — `br.r`, `ld.pd` —
and never mention profiles: `edge(nm, e; nw = n)` hands them a `Branch` already
resolved at `n`.

The wrapper earns its keep by removing an ambiguity. A bare `Vector` is not
enough to say what its entries mean: `terminals` and the cost polynomial of a
generator are vectors too, and nothing in their type says whether entry two is
the second terminal or the second hour. Only the network dependent case is
wrapped.

Because only `status` can change which components exist, which `Topology` a
network index has is *derived* from the statuses of the components whose status
varies — never looked up in a table indexed by `n`. A problem without
contingencies has one topology and reaches it without doing any work, however
many indices it spans; a contingency is nothing more than a `status` that
varies:

```julia
Branch(; id = 1, terminals = [1, 2], r = 0.01, x = 0.1,
       status = nw_vector(dim, (n, c) -> c.contingency != 2))
```

The result is that **nothing anywhere is stored per network index**. On case14
with an hourly demand profile:

| indices | build | `Dimension` | whole graph | topologies |
|--------:|------:|------------:|------------:|-----------:|
| 1       | —     | 928 B       | 44 kB       | 1          |
| 24      | 0.1 ms| 928 B       | 48 kB       | 1          |
| 168     | 0.3 ms| 928 B       | 74 kB       | 1          |
| 8760    | 12 ms | 928 B       | 1.59 MB     | 1          |

The 1.59 MB at 8760 hours is 1.54 MB of profile — 11 loads × 2 fields × 8760
× 8 B — plus the 44 kB the same network costs over a single index. The graph is
the data you asked for plus a constant, and the `Dimension` is flat: its index
is arithmetic rather than tabulated, and a dimension given as a plain size
stores that size rather than a dictionary per coordinate.

## The component hierarchy

Within the three families the types form a hierarchy, and a type earns its place
by changing the *model*, not by carrying a label.

```
AbstractEdge                          AbstractUnit
├── AbstractBranch                    ├── AbstractGenerator
│   ├── Branch                        │   └── Generator
│   ├── Cable                         ├── AbstractLoad
│   └── OverheadLine                  │   ├── FixedLoad
└── AbstractTransformer               │   └── FlexibleLoad
    ├── AbstractTwoWindingTransformer ├── AbstractStorage
    │   ├── Transformer               │   └── Storage
    │   ├── PhaseShifter              └── AbstractShunt
    │   └── TapChanger                    └── Shunt
    └── MultiWindingTransformer
```

Every `AbstractBranch` shares one π-equivalent; `Cable` and `OverheadLine` are
*electrically identical* to `Branch` and exist to be addressed and to carry the
data that does differ. A `PhaseShifter` and a `TapChanger` are not labels: their
ratio is a decision variable in a dispatch problem and a constant in a power
flow. A `MultiWindingTransformer` keeps its star point as an edge variable
rather than inventing a node for it.

See [the documentation](https://timmyfaraday.github.io/NetworkModelBuilder.jl/)
for the parameters, variables and constraints of each.

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
data    = parse_file("case5.m")
dim     = Dimension(:time => 3)
profile = [0.9, 1.0, 1.1]

data = set_dimension(data, dim; apply! = function (net, dim)
    for (u, ld) in net.unit
        ld isa Load || continue
        net.unit[u] = Load(; id = ld.id, name = ld.name, node = ld.node,
                           pd = nw_vector(dim, :time, ld.pd .* profile),
                           qd = nw_vector(dim, :time, ld.qd .* profile))
    end
end)

result = solve_model(data, OptimalPowerFlowProblem, IVRFormulation, Ipopt.Optimizer)
nw_solution(result, 3)["node"]["2"]["vm"]     # the third hour
```

Everything `apply!` leaves alone stays a plain value, and is therefore constant
over the network index.

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
│   ├── node/node.jl            I
│   ├── edge/
│   │   ├── edge.jl             E — the registry, terminal currents, dispatchers
│   │   ├── pi_model.jl         E — the π-equivalent, shared by branch and transformer
│   │   ├── branch/             E — branch.jl, cable.jl, overhead_line.jl
│   │   └── transformer/        E — transformer.jl, phase_shifter.jl,
│   │                           #    tap_changer.jl, multi_winding.jl
│   └── unit/
│       ├── unit.jl             U — the registry, injection currents, dispatchers
│       ├── generator/          U — generator.jl
│       ├── load/               U — load.jl, fixed_load.jl, flexible_load.jl
│       ├── storage/            U — storage.jl
│       └── shunt/              U — shunt.jl
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

|                              | `IVRFormulation` | `LPFFormulation` | `ACPFormulation` | `ACRFormulation` |
|:-----------------------------|:-----------------|:-----------------|:-----------------|:-----------------|
| `LoadFlowProblem`            | yes              | yes              | —                | —                |
| `OptimalPowerFlowProblem`    | yes              | yes              | —                | —                |
| `RedispatchProblem`          | sketched         | sketched         | —                | —                |

`LPFFormulation` is the linearized power flow — what the literature calls the DC
power flow, a name avoided here because nothing about it involves direct
current. Every voltage magnitude is one, reactive power is omitted, and angle
differences are small, which leaves a linear program. Both problem builders are
*shared* between the two formulations, because every call inside them is itself
a dispatch point:

```julia
build_model!(nm::NetworkModel{P,F}) where {P<:LoadFlowProblem,F<:IVRFormulation} = _build_load_flow!(nm)
build_model!(nm::NetworkModel{P,F}) where {P<:LoadFlowProblem,F<:LPFFormulation} = _build_load_flow!(nm)
```

One consequence is worth knowing: a `PhaseShifter` stays a control in the
linearized model and a `TapChanger` becomes inert, because the ratio angle
survives the approximations and the ratio magnitude has nothing left to act on.

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

Components: `Node`; `Branch`, `Cable`, `OverheadLine`, `Transformer`,
`PhaseShifter`, `TapChanger`, `MultiWindingTransformer`; `Generator`,
`FixedLoad`, `FlexibleLoad`, `Storage`, `Shunt`. Readers: Matpower.

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
| multinetwork | the whole data dictionary replicated per `nw` | one graph; only the data that varies is a `NetworkVector` on its component |
| dimensions | `nw` ids, flat | `Dimension` over named axes, with index arithmetic |

## Acknowledgements

The design owes its structure to
[PowerModels.jl](https://github.com/lanl-ansi/PowerModels.jl), by Carleton
Coffrin and contributors, and its handling of problem dimensions to
[FlexPlan.jl](https://github.com/Electa-Git/FlexPlan.jl).

## License

This code is provided under a BSD 3-Clause License.
