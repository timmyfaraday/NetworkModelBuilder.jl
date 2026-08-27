# Generator

A generator is a unit ``(u, i)`` whose injection is a decision bounded by its
capability. That, rather than the sign of the power, is what separates it from a
[Load](@ref): a generator says how much it *could* deliver and the model chooses
within that.

```@docs
AbstractGenerator
Generator
```

## Parameters

| symbol | field | description | unit |
|:-------|:------|:------------|:-----|
| | `id`, `name` | identifier and label | |
| ``i`` | `node` | the node it is connected to | |
| ``p^{\text{g,set}}_{u}`` | `pg` | active power setpoint | pu |
| ``q^{\text{g,set}}_{u}`` | `qg` | reactive power setpoint | pu |
| ``p^{\text{min}}_{u}``, ``p^{\text{max}}_{u}`` | `pmin`, `pmax` | active power limits | pu |
| ``q^{\text{min}}_{u}``, ``q^{\text{max}}_{u}`` | `qmin`, `qmax` | reactive power limits | pu |
| | `vg` | voltage setpoint carried from the input data | pu |
| ``c_{u,k}`` | `cost` | cost polynomial, ascending, per unit | currency/h |
| | `status` | in service | |

`cost` is ascending in the power: `cost[k]` multiplies ``(p^{\text{g}}_{u})^{k-1}``.
A network dependent cost is a `NetworkVector{Vector{Float64}}` — the plain
`Vector{Float64}` is the polynomial, not a profile.

## Variables

### In the `IVRFormulation`

| symbol | key | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``c^{\text{r}}_{u}`` | `:cru` | unit | real injected current | pu |
| ``c^{\text{i}}_{u}`` | `:ciu` | unit | imaginary injected current | pu |
| ``p^{\text{g}}_{u}`` | `:pg` | unit | active power | pu |
| ``q^{\text{g}}_{u}`` | `:qg` | unit | reactive power | pu |

The injection currents are shared by every unit type. `pg` and `qg` are free in
a power flow, where [`constraint_unit`](@ref) fixes them at their setpoint
instead, and bounded by the operating limits in a dispatch problem.

## Constraints

The power a generator injects, against the current it injects:

```math
p^{\text{g}}_{u} = v^{\text{r}}_{i} c^{\text{r}}_{u} + v^{\text{i}}_{i} c^{\text{i}}_{u},
\qquad
q^{\text{g}}_{u} = v^{\text{i}}_{i} c^{\text{r}}_{u} - v^{\text{r}}_{i} c^{\text{i}}_{u} .
```

In a **power flow** the setpoint follows the role of the node:

| node type | ``p^{\text{g}}_{u}`` | ``q^{\text{g}}_{u}`` |
|:----------|:---------------------|:---------------------|
| `REF` | free | free |
| `PV` | fixed at `pg` | free, follows the voltage setpoint |
| `PQ` | fixed at `pg` | fixed at `qg` |

Where several generators share a `PV` or `REF` node, their split of the free
quantity is not determined by the model; the solver returns one admissible split.

In a **dispatch problem** nothing is fixed, and the bounds on the variables do
the work.

## Objective

An [`OptimalPowerFlowProblem`](@ref) minimizes

```math
\min \quad \sum_{n} w_{n} \sum_{u} \sum_{k} c_{u,k} \, (p^{\text{g}}_{u,n})^{k-1}
```

with ``w_n`` the weight of the network index, see [`network_weight`](@ref).

```@docs
generation_cost
```
