# Branch

A branch is an edge ``(e, i, j)`` that transports power between two nodes
without transforming it: a π-equivalent with no turns ratio. Where an edge does
have a ratio it is a [Transformer](@ref), not a branch.

```@docs
AbstractBranch
Branch
Cable
OverheadLine
```

Every branch type shares the same equations. What separates a cable from an
overhead line in a steady-state model is the data it carries, not the physics —
see [Where a type earns its place](@ref).

## Parameters

| symbol | field | description | unit |
|:-------|:------|:------------|:-----|
| | `id`, `name` | identifier and label | |
| ``(i, j)`` | `terminals` | the from and to node | |
| ``r_{e}`` | `r` | series resistance | pu |
| ``x_{e}`` | `x` | series reactance | pu |
| ``g^{\text{sh}}_{e,\text{fr}}`` | `g_fr` | shunt conductance, from side | pu |
| ``b^{\text{sh}}_{e,\text{fr}}`` | `b_fr` | shunt susceptance, from side | pu |
| ``g^{\text{sh}}_{e,\text{to}}`` | `g_to` | shunt conductance, to side | pu |
| ``b^{\text{sh}}_{e,\text{to}}`` | `b_to` | shunt susceptance, to side | pu |
| ``s^{\text{max}}_{e}`` | `rate_a` | apparent power rating | pu |
| ``\theta^{\text{min}}_{e}`` | `angmin` | lower angle difference limit | rad |
| ``\theta^{\text{max}}_{e}`` | `angmax` | upper angle difference limit | rad |
| | `length_km` | route length, [`Cable`](@ref) and [`OverheadLine`](@ref) only | km |
| | `status` | in service | |

A line whose total charging susceptance is ``b`` has
``b^{\text{sh}}_{\text{fr}} = b^{\text{sh}}_{\text{to}} = b/2``. Every field but
`id`, `name`, `terminals`, `length_km` and `ext` may be a
[`NetworkVector`](@ref); an outage in a contingency is a `status` that varies,
and a rating that follows the weather is a `rate_a` that does.

## Variables

### In the `IVRFormulation`

| symbol | key | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``c^{\text{r}}_{a}`` | `:cr` | arc | real terminal current, node into edge | pu |
| ``c^{\text{i}}_{a}`` | `:ci` | arc | imaginary terminal current | pu |
| ``c^{\text{sr}}_{e}`` | `:csr` | edge | real series current, from → to | pu |
| ``c^{\text{si}}_{e}`` | `:csi` | edge | imaginary series current | pu |

The terminal currents are shared by every edge type and are created once, over
all arcs; the series current is created by each edge type that has one, into a
shared container.

### In the `LPFFormulation`

| symbol | key | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``p_{a}`` | `:p` | arc | terminal active power, node into edge | pu |

A branch needs no variables of its own: there is no series current left to carry
once the model is lossless.

## Constraints

| name | problem |
|:-----|:--------|
| [`constraint_edge`](@ref) | all |
| [`constraint_edge_limits`](@ref) | dispatch |

### The π-equivalent

With ``y^{\text{sh}}`` the terminal shunt admittances, ``z_e = r_e + j x_e`` the
series impedance, ``a^{\text{f}}`` and ``a^{\text{t}}`` the two arcs of the edge
and ``c^{\text{s}}_{e}`` the series current:

```math
\begin{aligned}
c_{a^{\text{f}}} &= y^{\text{sh}}_{e,\text{fr}} \, v_{i} + c^{\text{s}}_{e}, \\
c_{a^{\text{t}}} &= -c^{\text{s}}_{e} + y^{\text{sh}}_{e,\text{to}} \, v_{j}, \\
v_{i} - v_{j} &= z_{e} \, c^{\text{s}}_{e}.
\end{aligned}
```

The first two split the terminal current over the shunt and the series branch;
the third is the drop across the series impedance. The same three equations,
with the from-side quantities taken behind an ideal ratio, are what a
[Transformer](@ref) uses.

### Rating and angle difference

A dispatch problem adds, per terminal,

```math
\left((v^{\text{r}}_{i})^2 + (v^{\text{i}}_{i})^2\right)
\left((c^{\text{r}}_{a})^2 + (c^{\text{i}}_{a})^2\right) \le (s^{\text{max}}_{e})^2 ,
```

which is the apparent power at that terminal against the rating, and

```math
\tan(\theta^{\text{min}}_{e}) \left(v^{\text{r}}_{i} v^{\text{r}}_{j} + v^{\text{i}}_{i} v^{\text{i}}_{j}\right)
\le v^{\text{i}}_{i} v^{\text{r}}_{j} - v^{\text{r}}_{i} v^{\text{i}}_{j}
\le \tan(\theta^{\text{max}}_{e}) \left(v^{\text{r}}_{i} v^{\text{r}}_{j} + v^{\text{i}}_{i} v^{\text{i}}_{j}\right) ,
```

which bounds the angle difference across the edge. Both are skipped where the
data leaves them unbounded.

### In the `LPFFormulation`

```math
p_{a^{\text{f}}} = -b_{e} \left(v^{\text{a}}_{i} - v^{\text{a}}_{j}\right),
\qquad
p_{a^{\text{t}}} = -p_{a^{\text{f}}} ,
```

with ``b_{e}`` the series susceptance, see [`susceptance`](@ref). The shunt
admittance plays no part. The rating becomes a bound, ``-s^{\text{max}}_{e} \le
p_{a} \le s^{\text{max}}_{e}``, and the angle difference limit is already
linear.

```@docs
susceptance
constraint_linear_flow!
constraint_linear_limits!
```

```@docs
impedance
shunt_admittance
constraint_pi_section!
constraint_edge_rating!
constraint_edge_angle_difference!
variable_edge_series_current
dynamic_rating
```
