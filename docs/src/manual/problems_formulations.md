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
constraint_node_voltage_reference(nm::NetworkModel{<:AbstractPowerFlowProblem,<:IVRFormulation}; nw)
constraint_node_voltage_reference(nm::NetworkModel{<:AbstractDispatchProblem,<:IVRFormulation}; nw)
```

The same axis decides whether a generator holds a setpoint or moves within its
limits, whether a [`TapChanger`](@ref) is a control or a constant, and whether a
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

## The pipeline

```@docs
NetworkModel
instantiate_model
build_model!
update_model!
optimize_model!
solve_model
problem_type
formulation_type
register_model!
implemented_models
objective
objective_generation_cost
network_cost
minimize_network_cost
network_weight
default_weight
```

## The solution

```@docs
build_solution
nw_solution
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
