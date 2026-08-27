# Node

A node ``i \in I`` is an electrical busbar. It is the only component that has a
voltage, and the only one at which a balance is written.

```@docs
Node
NodeType
```

## Parameters

| symbol | field | description | unit |
|:-------|:------|:------------|:-----|
| | `id` | identifier | |
| | `name` | label | |
| | `type` | [`PQ`](@ref NodeType), [`PV`](@ref NodeType), [`REF`](@ref NodeType) or [`ISOLATED`](@ref NodeType) | |
| ``v^{\text{m}}_{i}`` | `vm` | voltage magnitude setpoint | pu |
| ``v^{\text{a}}_{i}`` | `va` | voltage angle setpoint | rad |
| ``v^{\text{min}}_{i}`` | `vmin` | lower voltage magnitude limit | pu |
| ``v^{\text{max}}_{i}`` | `vmax` | upper voltage magnitude limit | pu |
| | `base_kv` | voltage base | kV |
| | `area`, `zone` | bookkeeping identifiers | |
| | `status` | in service | |

Every field but `id`, `name`, `base_kv`, `area`, `zone` and `ext` may be a
[`NetworkVector`](@ref).

## Variables

### In the `IVRFormulation`

| symbol | key | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``v^{\text{r}}_{i}`` | `:vr` | node | real part of the voltage | pu |
| ``v^{\text{i}}_{i}`` | `:vi` | node | imaginary part of the voltage | pu |

Whether they are bounded depends on the problem. A power flow leaves them free,
so that the solver is not steered away from the one physical answer. A dispatch
problem bounds each by ``v^{\text{max}}_{i}`` and adds the magnitude limits
below.

## Constraints

| name | applies to | problem |
|:-----|:-----------|:--------|
| [`constraint_node_balance`](@ref) | every node | all |
| [`constraint_node_voltage_reference`](@ref) | `REF` nodes | all |
| [`constraint_node_voltage_setpoint`](@ref) | `PV` nodes | power flow |
| [`constraint_node_voltage_limits`](@ref) | every node | dispatch |

### Current balance

Kirchhoff's current law, at every node, in the `IVRFormulation`:

```math
\sum_{a \in A(i)} c_{a} = \sum_{u \in U(i)} c_{u}
```

with ``c_a`` the current flowing from the node into an edge terminal and ``c_u``
the current a unit injects. Every kind of unit contributes to the same sum
through the shared `:cru` and `:ciu` variables, which is what keeps this
constraint independent of what a network contains.

### Voltage reference

A power flow pins the complex voltage, because the reference generator absorbs
whatever mismatch remains:

```math
v^{\text{r}}_{i} = v^{\text{m}}_{i} \cos v^{\text{a}}_{i}, \qquad
v^{\text{i}}_{i} = v^{\text{m}}_{i} \sin v^{\text{a}}_{i}.
```

A dispatch problem pins the angle only, leaving the magnitude to the optimizer:

```math
\sin(v^{\text{a}}_{i}) \, v^{\text{r}}_{i} - \cos(v^{\text{a}}_{i}) \, v^{\text{i}}_{i} = 0,
\qquad
\cos(v^{\text{a}}_{i}) \, v^{\text{r}}_{i} + \sin(v^{\text{a}}_{i}) \, v^{\text{i}}_{i} \ge 0.
```

### Voltage magnitude setpoint, and limits

At a `PV` node in a power flow the magnitude is given:

```math
(v^{\text{r}}_{i})^2 + (v^{\text{i}}_{i})^2 = (v^{\text{m}}_{i})^2 .
```

In a dispatch problem no node has a setpoint, and every node has limits:

```math
(v^{\text{min}}_{i})^2 \le (v^{\text{r}}_{i})^2 + (v^{\text{i}}_{i})^2 \le (v^{\text{max}}_{i})^2 .
```

```@docs
constraint_node_balance
constraint_node_voltage_reference
constraint_node_voltage_setpoint
constraint_node_voltage_limits
variable_node_voltage
reference_nodes
```
