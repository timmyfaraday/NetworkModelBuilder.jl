# Branch

A branch is an edge that transports power between its terminals without
transforming it. With two terminals it is the π-equivalent ``(e, i, j)`` with no
turns ratio; with more it is one π-section from each terminal to a common point.
Where an edge does have a ratio it is a [Transformer](@ref), not a branch.

```@docs
AbstractBranch
Branch
```

There is one branch type. A cable and an overhead line are a `Branch` with another
`l_km` and another rating, not types of their own: what separates them in a
steady-state model is the data they carry, not the physics — see
[Where a type earns its place](@ref).

## Parameters

Every field with an entry per terminal is a vector indexed by terminal position,
and entry ``k`` belongs to the section that starts at terminal ``k``.

| symbol | code name | description | unit |
|:-------|:------|:------------|:-----|
| | `id`, `name` | identifier and label | |
| ``(i_1, \dots, i_n)`` | `terminals` | the nodes the sections start at, two or more | |
| ``r_{e,k}`` | `r` | series resistance of section ``k`` | pu |
| ``x_{e,k}`` | `x` | series reactance of section ``k`` | pu |
| ``g^{\text{sh}}_{e,k}`` | `g_shnt` | shunt conductance of section ``k``, half at each end | pu |
| ``b^{\text{sh}}_{e,k}`` | `b_shnt` | shunt susceptance of section ``k``, half at each end | pu |
| ``s^{\text{max}}_{e,k}`` | `s_max` | apparent power rating at terminal ``k`` | pu |
| ``\theta^{\text{min}}_{e}`` | `v_angl_min` | lower angle difference limit, two terminals only | rad |
| ``\theta^{\text{max}}_{e}`` | `v_angl_max` | upper angle difference limit, two terminals only | rad |
| | `l_km` | route length, `NaN` where it is not known | km |
| | `status` | in service | |
| | `ext` | free-form storage, carried along and never read | |

Two terminals are one section. A scalar stands for the first entry of `r`, `x`,
`g_shnt` and `b_shnt`, and the second entry is 0 — and has to be: a branch whose
second section carries something has three terminals. A scalar `s_max` is the
rating of every terminal. With more terminals each of them is a vector, but
`s_max`, which may still be one number.

A line whose total charging susceptance is ``b`` has ``b^{\text{sh}} = b``, which
is how a Matpower branch is read; half of it sits at each end. Every field but
`id`, `name`, `terminals`, `l_km` and `ext` may be a
[`NetworkVector`](@ref); an outage in a contingency is a `status` that varies,
and a rating that follows the weather is a `s_max` that does.

On a [Transformer](@ref) the names `g_shnt` and `b_shnt` are the shunt at the terminal
side of a winding, once; on a branch they are the whole shunt of a section, half
at each end.

A branch is refused when it cannot be modelled: an entry of `r`, `x`, `g_shnt` or
`b_shnt` that is not finite, a section with `r` and `x` both 0 (a bus coupler is a
[`Switch`](@ref)), a rating that is negative or NaN, `v_angl_min` above `v_angl_max`, or a
`l_km` that is negative or infinite.

## Variables

### In the `IVRFormulation`

| symbol | code name | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``i^{\text{r}}_{a}`` | `:i_term_real` | arc | real terminal current, node into edge | pu |
| ``i^{\text{i}}_{a}`` | `:i_term_imag` | arc | imaginary terminal current | pu |
| ``i^{\text{sr}}_{e}`` | `:i_ser_real` | edge | real series current, from → to; two terminals | pu |
| ``i^{\text{si}}_{e}`` | `:i_ser_imag` | edge | imaginary series current; two terminals | pu |
| ``v^{\text{pr}}_{e}`` | `:v_pnt_real` | edge | real voltage of the point; more than two terminals | pu |
| ``v^{\text{pi}}_{e}`` | `:v_pnt_imag` | edge | imaginary voltage of the point; more than two terminals | pu |

The terminal currents are shared by every edge type and are created once, over
all arcs; the series current is created by each edge type that has one, into a
shared container. The point of a branch with more than two terminals is not a
node: it belongs to the edge, as the star point of a [Transformer](@ref) does, and
the current of a section is an expression of the terminal current, not a
variable.

### In the `LPFFormulation`

| symbol | code name | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``p_{a}`` | `:p_term` | arc | terminal active power, node into edge | pu |
| ``v^{\text{ap}}_{e}`` | `:v_pnt_angl` | edge | angle of the point; more than two terminals | rad |

A branch with two terminals needs no variables of its own: there is no series
current left to carry once the model is lossless.

## Constraints

| name | problem |
|:-----|:--------|
| [`fnct_edge`](@ref) | all |
| [`fnct_edge_limit`](@ref) | dispatch |

### The π-equivalent

A branch with two terminals has one section. With ``y^{\text{sh}}_{e} = g^{\text{sh}}_{e,1} +
j b^{\text{sh}}_{e,1}`` its shunt admittance, half of it at each end,
``z_e = r_{e,1} + j x_{e,1}`` the series impedance, ``a^{\text{f}}`` and
``a^{\text{t}}`` the two arcs of the edge and ``i^{\text{s}}_{e}`` the series
current:

```math
\begin{aligned}
i_{a^{\text{f}}} &= \tfrac{1}{2} y^{\text{sh}}_{e} \, v_{i} + i^{\text{s}}_{e}, \\
i_{a^{\text{t}}} &= -i^{\text{s}}_{e} + \tfrac{1}{2} y^{\text{sh}}_{e} \, v_{j}, \\
v_{i} - v_{j} &= z_{e} \, i^{\text{s}}_{e}.
\end{aligned}
```

The first two split the terminal current over the shunt and the series branch;
the third is the drop across the series impedance. A [Transformer](@ref) without a
magnetising branch writes the same three equations with the from side behind an
ideal ratio.

### More than two terminals

A branch with ``n`` terminals is ``n`` of these sections, section ``k`` running
from terminal ``k`` to a point ``p`` the sections share. The half of the shunt of a
section that is at its far end is at the point, where the shunts of all of them
add up. With ``i^{\text{s}}_{k}`` the current in section ``k``, that is the
terminal current less the half of the shunt at the terminal:

```math
\begin{aligned}
i^{\text{s}}_{k} &= i_{a_k} - \tfrac{1}{2} y^{\text{sh}}_{e,k} \, v_{i_k}, \\
v_{i_k} - v^{\text{p}}_{e} &= z_{e,k} \, i^{\text{s}}_{k}, \\
\sum_{k} i^{\text{s}}_{k} &= \tfrac{1}{2} \Big( \sum_{k} y^{\text{sh}}_{e,k} \Big) v^{\text{p}}_{e}.
\end{aligned}
```

The point is a pair of variables of the edge, not a node: it has no identifier and
appears in neither `ids(net, Node)` nor the node part of a solution. With two
terminals there is no point: the one section runs from the first terminal to the
second, which is the π-equivalent above.

This is the model of a [Transformer](@ref) with every ratio one, with
``y^{\text{sh}}_{e,k}/2`` as the shunt behind each winding and
``\sum_k y^{\text{sh}}_{e,k}/2`` as its magnetising branch; the two are written
independently and `test/multiterminal.jl` checks each against the other.

### Rating and angle difference

A dispatch problem adds, per terminal,

```math
\left((v^{\text{r}}_{i})^2 + (v^{\text{i}}_{i})^2\right)
\left((i^{\text{r}}_{a})^2 + (i^{\text{i}}_{a})^2\right) \le (s^{\text{max}}_{e,k})^2 ,
```

which is the apparent power at that terminal against the rating, and for a branch
with two terminals

```math
\tan(\theta^{\text{min}}_{e}) \left(v^{\text{r}}_{i} v^{\text{r}}_{j} + v^{\text{i}}_{i} v^{\text{i}}_{j}\right)
\le v^{\text{i}}_{i} v^{\text{r}}_{j} - v^{\text{r}}_{i} v^{\text{i}}_{j}
\le \tan(\theta^{\text{max}}_{e}) \left(v^{\text{r}}_{i} v^{\text{r}}_{j} + v^{\text{i}}_{i} v^{\text{i}}_{j}\right) ,
```

which bounds the angle difference across the edge. A branch with more terminals has
no angle limit, as a transformer with more windings has none. Both are skipped where
the data leaves them unbounded.

### In the `LPFFormulation`

With two terminals,

```math
p_{a^{\text{f}}} = -b_{e} \left(v^{\text{a}}_{i} - v^{\text{a}}_{j}\right),
\qquad
p_{a^{\text{t}}} = -p_{a^{\text{f}}} ,
```

with ``b_{e}`` the series susceptance, see [`susceptance`](@ref). With more, each
section is a flow to the angle ``v^{\text{ap}}_{e}`` of the point, and the flows
balance there:

```math
p_{a_k} = -b_{e,k} \left(v^{\text{a}}_{i_k} - v^{\text{ap}}_{e}\right),
\qquad
\sum_{k} p_{a_k} = 0 .
```

The shunt admittance plays no part. The rating of every terminal becomes a bound,
``-s^{\text{max}}_{e,k} \le p_{a_k} \le s^{\text{max}}_{e,k}``, written by
[`fnct_edge_rating_linear!`](@ref), and the angle difference limit of a branch
with two terminals, written by [`fnct_edge_angle_difference_linear!`](@ref), is
linear already. The two are separate rows: a rating and an angle limit are not
one constraint.

```@docs
susceptance
fnct_edge_flow_linear!
fnct_edge_rating_linear!
fnct_edge_angle_difference_linear!
```

```@docs
impedance
shunt_admittance
fnct_br_pi_section!
fnct_edge_rating!
fnct_edge_angle_difference!
variable_edge_series_current
dynamic_rating
```
