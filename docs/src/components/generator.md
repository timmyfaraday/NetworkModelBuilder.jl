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

| symbol | code name | description | unit |
|:-------|:------|:------------|:-----|
| | `id`, `name` | identifier and label | |
| ``i`` | `node` | the node it is connected to | |
| ``p^{\text{g,set}}_{u}`` | `p_set` | active power setpoint | pu |
| ``q^{\text{g,set}}_{u}`` | `q_set` | reactive power setpoint | pu |
| ``p^{\text{min}}_{u}``, ``p^{\text{max}}_{u}`` | `p_min`, `p_max` | active power limits | pu |
| ``q^{\text{min}}_{u}``, ``q^{\text{max}}_{u}`` | `q_min`, `q_max` | reactive power limits | pu |
| | `v_magn_set` | voltage setpoint carried from the input data | pu |
| ``E^{\text{max}}_{u}`` | `e_per_max` | most energy produced in one period | pu·h |
| ``c_{u,k}`` | `c` | cost polynomial, ascending, per unit | currency/h |
| ``c^{\uparrow}_{u}``, ``c^{\downarrow}_{u}`` | `c_up`, `c_dn` | price of moving one per unit up and down from the market schedule in a redispatch; `NaN` is the marginal cost at the market dispatch | currency/pu/h |
| | `status` | in service | |
| | `ext` | free-form storage, carried along and never read | |

`c` is ascending in the power: `c[k]` multiplies ``(p^{\text{g}}_{u})^{k-1}``.
A network dependent cost is a `NetworkVector{Vector{Float64}}` — the plain
`Vector{Float64}` is the polynomial, not a profile.

## Variables

### In the `IVRFormulation`

| symbol | code name | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``i^{\text{r}}_{u}`` | `:i_unit_real` | unit | real injected current | pu |
| ``i^{\text{i}}_{u}`` | `:i_unit_imag` | unit | imaginary injected current | pu |
| ``p^{\text{g}}_{u}`` | `:p_gen` | unit | active power | pu |
| ``q^{\text{g}}_{u}`` | `:q_gen` | unit | reactive power | pu |
| ``p^{\uparrow}_{u}``, ``p^{\downarrow}_{u}`` | `:p_gen_up`, `:p_gen_dn` | unit | moved up and down from the market schedule, redispatch only | pu |

The injection currents are shared by every unit type. `:p_gen` and `:q_gen` are free in
a power flow, where [`constraint_unit`](@ref) fixes them at their setpoint
instead, and bounded by the operating limits in a dispatch problem.

### In the `LPFFormulation`

| symbol | code name | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``p_{u}`` | `:p_unit` | unit | active power injected into the node | pu |
| ``p^{\text{g}}_{u}`` | `:p_gen` | unit | active power | pu |
| ``p^{\uparrow}_{u}``, ``p^{\downarrow}_{u}`` | `:p_gen_up`, `:p_gen_dn` | unit | moved up and down from the market schedule, redispatch only | pu |

There is no reactive power, so `:q_gen` is not created and the reactive limits play
no part. In a load flow the `PV` and `PQ` distinction disappears with it: every
generator away from the reference node holds its active setpoint and nothing
else.

## Constraints

The power a generator injects, against the current it injects:

```math
p^{\text{g}}_{u} = v^{\text{r}}_{i} i^{\text{r}}_{u} + v^{\text{i}}_{i} i^{\text{i}}_{u},
\qquad
q^{\text{g}}_{u} = v^{\text{i}}_{i} i^{\text{r}}_{u} - v^{\text{r}}_{i} i^{\text{i}}_{u} .
```

In a **power flow** the setpoint follows the role of the node:

| node type | ``p^{\text{g}}_{u}`` | ``q^{\text{g}}_{u}`` |
|:----------|:---------------------|:---------------------|
| `REF` | free | free |
| `PV` | fixed at `p_set` | free, follows the voltage setpoint |
| `PQ` | fixed at `p_set` | fixed at `q_set` |

Where several generators share a `PV` or `REF` node, their split of the free
quantity is not determined by the model; the solver returns one admissible split.

In a **dispatch problem** nothing is fixed, and the bounds on the variables do
the work.

### Across network indices

A generator that carries a finite `e_per_max` gets one row per
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
nothing about how the generator spends it within one. `p_max` cannot express it —
a plant that may run flat out for four hours of a day and not at all for the
other twenty has the same `p_max` as one that may run all day, and only the
second of them is what `p_max` alone describes.

The sum is over the net output, so a generator with a negative `p_min` has what it
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
