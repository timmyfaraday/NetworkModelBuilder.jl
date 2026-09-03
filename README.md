<a href="https://github.com/timmyfaraday/NetworkModelBuilder.jl/actions?query=workflow%3ACI"><img src="https://github.com/timmyfaraday/NetworkModelBuilder.jl/workflows/CI/badge.svg"></img></a>
<a href="https://timmyfaraday.github.io/NetworkModelBuilder.jl/dev/"><img src="https://github.com/timmyfaraday/NetworkModelBuilder.jl/workflows/Documentation/badge.svg"></img></a>

# NetworkModelBuilder.jl

## Three ideas

**1. A problem type and a formulation type, dispatched on together.** The
problem type answers *which question is asked of the network* — which degrees of
freedom are free, which are fixed, what is minimized. The formulation type
answers *in which variables the physics are written* — rectangular or polar,
current or power, exact or relaxed. The two are orthogonal, so they get an axis
each, and every variable, constraint and objective is a method on the pair:

```julia
NetworkModel{LoadFlowProblem, IVRFormulation}

# a load flow pins the complex voltage at the reference node,
# a dispatch problem pins the angle only and lets the magnitude float
constraint_node_voltage_reference(nm::NetworkModel{<:AbstractPowerFlowProblem,<:IVRFormulation}; nw)
constraint_node_voltage_reference(nm::NetworkModel{<:AbstractDispatchProblem,<:IVRFormulation}; nw)
```

Every tag in both hierarchies is abstract, so an extension specialises one by
subtyping it.

**2. An extended graph `(I, E, U)`, with multi-terminal edges.** An **edge**
`(e, i, j, ...)` connects an *ordered list* of nodes — nothing assumes there are
two, so a three-winding transformer or a multi-terminal HVDC link is an ordinary
edge. A **unit** `(u, i)` connects to one node; generators, loads, storage and
shunts all inject through the same variable pair, so the node balance knows
nothing about what kinds of unit exist. Edge variables are indexed by an
`Arc(edge, terminal, node)`, because terminals are not interchangeable and two
terminals of one edge may land on the same node.

**3. Every dimension under one network index, and varying data on the
component.** Time, contingencies, harmonics and scenarios are axes of the same
problem. A `Dimension` gives the bijection between a coordinate tuple and the
scalar index `n`, and its arithmetic — `similar_id`, `prev_ids`, `next_ids` — is
what a coupling constraint needs.

```julia
dim = Dimension(:time => 24, :contingency => 3)
nw_ids(dim; contingency = 2)   # every hour of the second contingency
prev_id(dim, 26, :time)        # 25, the hour before, same contingency
```

There is **one** extended graph, not one per index. A field the index changes is
stored on its component as a `NetworkVector` (`pd = nw_vector(dim, :time,
profile)`); a field that does not is a plain value (`qd = 0.05`). Both are read
through one getter, so nothing anywhere is stored per network index — on case14
with an hourly profile, 8760 indices cost 12 ms to build and 1.59 MB of graph,
of which 1.54 MB is the profile itself. Which `Topology` an index has is
*derived* from the statuses that vary, never tabulated, so a contingency is
nothing more than a `status` that varies.

## Components

Within the three families a type earns its place by changing the *model*, not by
carrying a label. `Cable` and `OverheadLine` are electrically identical to
`Branch` and exist to be addressed; a `PhaseShifter` and a `TapChanger` have a
ratio that is a decision variable in a dispatch problem and a constant in a
power flow; a `MultiWindingTransformer` keeps its star point as an edge variable
rather than inventing a node for it.

```
AbstractEdge                          AbstractUnit
├── AbstractBranch                    ├── AbstractGenerator → Generator
│   ├── Branch                        ├── AbstractLoad
│   ├── Cable                         │   ├── FixedLoad
│   └── OverheadLine                  │   └── FlexibleLoad
├── AbstractTransformer               ├── AbstractStorage → Storage
│   ├── AbstractTwoWindingTransformer ├── AbstractSlackUnit
│   │   ├── Transformer               │   ├── EnergyNotServed
│   │   ├── PhaseShifter              │   └── Spill
│   │   └── TapChanger                └── AbstractShunt → Shunt
│   └── MultiWindingTransformer
└── AbstractDCLink → DCLink
```

The code of a component lives in one file, holding its struct, its variables and
its constraints together. There is deliberately no `src/form/` directory: a
formulation is a set of methods spread over the component files, not a place.

## Installation

Requires `Julia 1.10` or newer.

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

`set_dimension` lifts parsed data onto a `Dimension` and takes an `apply!` hook
that turns the fields which vary into `NetworkVector`s; everything it leaves
alone stays constant over the network index. See
[the manual](https://timmyfaraday.github.io/NetworkModelBuilder.jl/) for that
and for the multi-period, redispatch and rolling-horizon problems.

## What is implemented

The implemented pairs are the full cross product of the two hierarchies below:
every problem marked ✓ builds with every formulation marked ✓. A — is a declared
tag that carries no methods.

```
AbstractProblemType                 AbstractFormulationType
├── AbstractPowerFlowProblem        ├── AbstractACFormulation
│   └── LoadFlowProblem          ✓  │   ├── AbstractCurrentFormulation
└── AbstractDispatchProblem         │   │   └── IVRFormulation          ✓
    ├── OptimalPowerFlowProblem  ✓  │   └── AbstractPowerFormulation
    └── RedispatchProblem        ✓  │       ├── ACPFormulation          —
                                    │       └── ACRFormulation          —
                                    └── AbstractLinearizedFormulation
                                        └── LPFFormulation              ✓
```

`LPFFormulation` is the linearized power flow — what the literature calls the DC
power flow, a name avoided here because nothing about it involves direct
current. The problem builders are *shared* between the two formulations, because
every call inside them is itself a dispatch point. The formulation types that
carry no methods are declared so the hierarchy is complete; asking for one
reports what is available instead of building a wrong model.

Readers: Matpower, tabular (Arrow), and a [Zorba
adapter](https://timmyfaraday.github.io/NetworkModelBuilder.jl/) that translates
a study into a network and back. The two implemented models are checked against
PowerModels.jl v0.21 in `test/`, to `1e-6` on `case14`, `case5` and `case3`.

## Extending

A **new edge or unit type** is one file — the struct, its `variable_*` and
`constraint_*` methods, and a `register_edge_type!`/`register_unit_type!` call;
the problem builders walk those registries, so `src/prob/` never changes
(`test/multiterminal.jl` is a worked example). A **new formulation** is a tag in
`src/core/types.jl` plus a method per component file, and nothing outside those
files moves. A **new problem** is a tag, a `build_model!`, an `objective`, a
`register_model!`, and a method in the file of each component whose behaviour
changes — `src/prob/rd.jl` is the worked example.

## Differences from PowerModels.jl

| | PowerModels.jl | NetworkModelBuilder.jl |
|:-|:-|:-|
| problem | a `build_*` function | a type, dispatched on |
| formulation | `AbstractPowerModel` subtype | a type, dispatched on |
| data | `Dict{String,Any}` | typed structs |
| branch | two-terminal, `f_bus`/`t_bus` | an edge with any number of terminals |
| flow index | `(l, i, j)` arc | `Arc(edge, terminal, node)` |
| gen/load/shunt | three separate balance terms | one set `U`, one injection pair |
| code layout | by kind — `variable.jl`, `constraint.jl` | by component — one file each |
| multinetwork | the data dictionary replicated per `nw` | one graph; only what varies is a `NetworkVector` |
| dimensions | `nw` ids, flat | `Dimension` over named axes, with index arithmetic |

## Acknowledgements

The design owes its structure to
[PowerModels.jl](https://github.com/lanl-ansi/PowerModels.jl), by Carleton
Coffrin and contributors, and its handling of problem dimensions to
[FlexPlan.jl](https://github.com/Electa-Git/FlexPlan.jl).

## License

This code is provided under a BSD 3-Clause License.
