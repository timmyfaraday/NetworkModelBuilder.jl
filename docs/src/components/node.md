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

### In the `LPFFormulation`

| symbol | key | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``v^{\text{a}}_{i}`` | `:va` | node | voltage angle | rad |

There is no magnitude variable: it is one by assumption. The angle is unbounded
whatever the problem, since the differences that matter are bounded on the edges
that span them.

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

### In the `LPFFormulation`

The balance is the same statement in active power alone,

```math
\sum_{a \in A(i)} p_{a} = \sum_{u \in U(i)} p_{u} ,
```

and the reference node fixes its angle, ``v^{\text{a}}_{i} =
v^{\text{a,set}}_{i}``, in every problem rather than only in a dispatch one.
The magnitude setpoint and the magnitude limits have nothing to act on and are
no-ops.

```@docs
constraint_node_balance
constraint_node_voltage_reference
constraint_node_voltage_setpoint
constraint_node_voltage_limits
variable_node_voltage
reference_nodes
```

## The price of a node

The balance is the row a nodal price is the dual of, so a solved model already
holds one per node and per network index. It is a price per per-unit-hour and
reaches the solution as `lambda`:

```julia
result = solve_opf(data, LPFFormulation, HiGHS.Optimizer)
result["solution"]["nw"]["1"]["node"]["2"]["lambda"]
active_nodal_price(nm, 2)                       # the same number, from the model
```

```@docs
active_nodal_price
reactive_nodal_price
```

### What it is the price of

The marginal cost of one more per unit **withdrawn** at the node. In an
[`OptimalPowerFlowProblem`](@ref) that is the locational marginal price; in a
[`RedispatchProblem`](@ref) it is what relieving one more per unit of withdrawal
costs in the measures that problem is allowed to take. Both are the same
question asked of a different objective, which is why nothing in the
implementation knows which problem it is pricing.

The sign is the one thing worth reading twice. The balance is written as *what
leaves the node equals what its units inject into it*, so raising the right hand
side of that row by one is one more per unit **injected** — which *lowers* the
cost by the price of the node. The dual a solver reports is therefore the
negative of the price an operator means, and the package negates it rather than
leaving the caller to.

### When there is none

The `lambda` entry is **absent**, and `active_nodal_price` returns `nothing`, wherever
the solve gave the model no duals: an unsolved model, a failed solve, or a
mixed integer program, which has no duals at all. `result["dual_status"]` says
which case a result is in, and an absent price reads as *not available* rather
than as zero.

A [`LoadFlowProblem`](@ref) is the one case where a price is present and
uninformative: it minimizes zero, so every price in one is zero.

The current based prices need the solved **voltage** as well as the duals, since
the rotation is by that voltage, so they are absent wherever either is missing —
and at a node whose voltage solved to zero, where there is nothing to rotate
about.

### Where the balance is in current

Under an [`IVRFormulation`](@ref) the balance is Kirchhoff's current law, so its
two duals price a per unit of **current** rather than of energy. They are one
rotation by the voltage away from the power prices, and the rotation is invertible,
so `active_nodal_price` means the same thing in both formulations — and the reactive
price falls out of the same inversion, which the linearized formulation cannot
produce at all.

```@docs
nodal_prices
```

The node solution therefore carries four numbers under an `IVRFormulation`:

| key | what it is | unit |
|:----|:-----------|:-----|
| `lambda_real` | the dual of the real current row | currency/pu of current |
| `lambda_imag` | the dual of the imaginary current row | currency/pu of current |
| `lambda` | the active power price behind them | currency/pu/h |
| `lambda_q` | the reactive power price behind them | currency/pu/h |

!!! warning "`lambda_real` is not the nodal price"
    It is the price scaled by the real part of the voltage with a bleed of the
    reactive price, so at a magnitude near one it lands *near* the right answer
    without being it — which is what makes reading it as the price a plausible
    mistake rather than an obvious one. On the two node case in `test/price.jl`
    the congested node prices at 100 and its `lambda_real` reads 109.94. Take
    `lambda`, or [`nodal_prices`](@ref) for both halves at once.
