# Problems and formulations

A model is a [`NetworkModel{P,F}`](@ref). The pair `(P, F)` is what selects the
variables, the constraints and the objective.

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
```

Every tag in both hierarchies is an **abstract type** used purely for dispatch,
so an extension package specialises one by subtyping it.

```@docs
AbstractProblemType
AbstractPowerFlowProblem
AbstractDispatchProblem
AbstractFormulationType
AbstractACFormulation
AbstractCurrentFormulation
AbstractPowerFormulation
AbstractLinearizedFormulation
IVRFormulation
ACPFormulation
ACRFormulation
LPFFormulation
```

## What each axis decides

The problem type decides *which question is asked*. The clearest case is the
reference node: a load flow pins its complex voltage, a dispatch problem pins
only its angle. Same call site, different method:

```julia
fnct_node_voltage_reference(nm::NetworkModel{<:AbstractPowerFlowProblem,<:IVRFormulation}; nw)
fnct_node_voltage_reference(nm::NetworkModel{<:AbstractDispatchProblem,<:IVRFormulation}; nw)
```

The same axis decides whether a generator holds a setpoint or moves within its
limits, whether the ratio of a [`Transformer`](@ref) winding is a control or a
constant, and whether a
[`FlexibleLoad`](@ref) is flexible at all.

The formulation type decides *in which variables the physics are written*. The
two problem builders are shared between the formulations, because every call
inside them is itself a dispatch point:

```julia
build_model!(nm::NetworkModel{P,F}) where {P<:LoadFlowProblem,F<:IVRFormulation} = _build_load_flow!(nm)
build_model!(nm::NetworkModel{P,F}) where {P<:LoadFlowProblem,F<:LPFFormulation} = _build_load_flow!(nm)
```

## What is implemented

|                           | `IVRFormulation` | `LPFFormulation` | `ACPFormulation` | `ACRFormulation` |
|:--------------------------|:-----------------|:-----------------|:-----------------|:-----------------|
| `LoadFlowProblem`         | yes              | yes              | —                | —                |
| `OptimalPowerFlowProblem` | yes              | yes              | —                | —                |
| `RedispatchProblem`       | yes              | yes              | —                | —                |

See [The linearized formulation](@ref) for what `LPFFormulation` approximates
and what that costs.

Asking for a combination that has no builder reports what is available rather
than building a wrong model.

## Debug mode

In `debug_mode` every variable and every constraint is built with a name made of
the network index, its key and its id, which is what a solver log or an LP file
shows. A name costs a string per row and a call into the solver to store it: on a
real step-3 window of a rolling redispatch, 249,118 variables and 274,523
constraints, that is 29 % of the time [`instantiate_model`](@ref) takes and 44 % of
what it allocates. The default is `debug_mode = false`, which builds none, and every
solve takes it. A `jump_model` that is handed in is set to match: unnamed unless
`debug_mode` is `true`.

## The pipeline

```@docs
NetworkModel
instantiate_model
build_model!
update_model!
optimize_model!
refine!
solve_model
problem_type
formulation_type
register_model!
implemented_models
objective
objective_generation_cost
network_cost
minimize_network_cost
dispatch_cost
horizon_cost
terminal_cost
period_cost
component_period_cost
network_weight
period_weight
default_weight
```

## The solution

```@docs
build_solution
nw_solution
solution_tables
print_summary
solution
```

## Input

```@docs
parse_file
parse_matpower
```

A network held as tables rather than as a Matpower case is read by
[`parse_tables`](@ref), and one written as Arrow files by
[`parse_arrow`](@ref) — see [Tabular input](@ref).
