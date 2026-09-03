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
| ``E^{\text{max}}_{u}`` | `max_energy_per_period` | most energy produced in one period | pu·h |
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

### In the `LPFFormulation`

| symbol | key | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``p_{u}`` | `:pu` | unit | active power injected into the node | pu |
| ``p^{\text{g}}_{u}`` | `:pg` | unit | active power | pu |

There is no reactive power, so `qg` is not created and the reactive limits play
no part. In a load flow the `PV` and `PQ` distinction disappears with it: every
generator away from the reference node holds its active setpoint and nothing
else.

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

### Across network indices

A generator that carries a finite `max_energy_per_period` gets one row per
period:

```math
\sum_{n \in \mathcal{P}} \Delta t_{n} \, p^{\text{g}}_{u,n} \le E^{\text{max}}_{u}
```

with the period ``\mathcal{P}`` running over the `:time` coordinates grouped
with the index, see [`period_ids`](@ref), and every other coordinate held fixed.
A `:time` dimension with no grouping gives one period spanning the horizon, and
the limit is then a limit over the whole problem.

This is what a fuel allocation, a water licence or an emissions allowance looks
like once it reaches the model: a bound on the **energy** of a period that says
nothing about how the generator spends it within one. `pmax` cannot express it —
a plant that may run flat out for four hours of a day and not at all for the
other twenty has the same `pmax` as one that may run all day, and only the
second of them is what `pmax` alone describes.

The sum is over the net output, so a generator with a negative `pmin` has what it
absorbs counted against what it produced. An infinite limit — the default — is
the **absence** of a row rather than a row with an infinite right hand side, and
a generator that carries a finite one turns its problem into one that couples
network indices, so it says so where there is no `:time` dimension to couple
along.

## Objective

An [`OptimalPowerFlowProblem`](@ref) minimizes

```math
\min \quad \sum_{n} w_{n} \sum_{u} \sum_{k} c_{u,k} \, (p^{\text{g}}_{u,n})^{k-1}
```

with ``w_n`` the weight of the network index, see [`network_weight`](@ref).

```@docs
generation_cost
```
