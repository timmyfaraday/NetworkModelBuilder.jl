# Transformer

A transformer is an edge with a turns ratio ``T_{e} = tm_{e} \exp(j \, ta_{e})``:
its magnitude scales the voltage and its angle shifts it.

```@docs
AbstractTransformer
AbstractTwoWindingTransformer
Transformer
PhaseShifter
TapChanger
MultiWindingTransformer
```

## The voltage behind the ratio

Rather than substitute the ratio into the π-equations, the package carries the
voltage on the transformer side of the ratio as an **edge variable**,
``v^{\text{t}}_{e}``. Two things follow.

The ideal transformer and the impedance are then written separately, each in its
own form, so one implementation serves a fixed ratio and a ratio the optimizer
chooses. And the equations stay polynomial when the ratio is a variable, where
substituting would have divided by it.

The internal point is **not a node**. It never enters ``I``, gets no identifier,
carries no balance among the node constraints, and does not appear in
`ids(net, Node)`. It is a variable belonging to the edge. The same idea, with
more terminals, is what [`MultiWindingTransformer`](@ref) is built on.

## Parameters

As [`Branch`](@ref), plus:

| symbol | field | description | unit | type |
|:-------|:------|:------------|:-----|:-----|
| ``tm_{e}`` | `tm` | turns ratio magnitude, or its setpoint | pu | all |
| ``ta_{e}`` | `ta` | turns ratio angle, or its setpoint | rad | all |
| ``ta^{\text{min}}_{e}`` | `ta_min` | lower ratio angle limit | rad | [`PhaseShifter`](@ref) |
| ``ta^{\text{max}}_{e}`` | `ta_max` | upper ratio angle limit | rad | [`PhaseShifter`](@ref) |
| ``tm^{\text{min}}_{e}`` | `tm_min` | lower ratio magnitude limit | pu | [`TapChanger`](@ref) |
| ``tm^{\text{max}}_{e}`` | `tm_max` | upper ratio magnitude limit | pu | [`TapChanger`](@ref) |

For [`MultiWindingTransformer`](@ref), `r`, `x`, `tm`, `ta` and `rate_a` are
vectors with one entry per terminal, and `g_m`, `b_m` are the magnetising
admittance at the star point.

## Variables

### In the `IVRFormulation`

| symbol | key | index | description | unit | when |
|:-------|:----|:------|:------------|:-----|:-----|
| ``c^{\text{r}}_{a}``, ``c^{\text{i}}_{a}`` | `:cr`, `:ci` | arc | terminal current | pu | all |
| ``c^{\text{sr}}_{e}``, ``c^{\text{si}}_{e}`` | `:csr`, `:csi` | edge | series current | pu | two-winding |
| ``v^{\text{tr}}_{e}``, ``v^{\text{ti}}_{e}`` | `:vtr`, `:vti` | edge | voltage behind the ratio | pu | two-winding |
| ``t^{\text{r}}_{e}``, ``t^{\text{i}}_{e}`` | `:tr`, `:ti` | edge | the ratio itself | pu | [`PhaseShifter`](@ref), dispatch |
| ``tm_{e}`` | `:tm` | edge | the ratio magnitude | pu | [`TapChanger`](@ref), dispatch |
| ``v^{\text{sr}}_{e}``, ``v^{\text{si}}_{e}`` | `:vsr`, `:vsi` | edge | star point voltage | pu | [`MultiWindingTransformer`](@ref) |

A [`PhaseShifter`](@ref) carries its ratio as a real and an imaginary part rather
than as an angle, so that the angle enters only through ``t^2 + t^2 = tm^2`` and
a pair of bounds, in place of a sine and a cosine of a variable. A
[`TapChanger`](@ref) needs one variable rather than two, because only the
magnitude moves.

### In the `LPFFormulation`

| symbol | key | index | description | unit | when |
|:-------|:----|:------|:------------|:-----|:-----|
| ``p_{a}`` | `:p` | arc | terminal active power | pu | all |
| ``ta_{e}`` | `:ta` | edge | the ratio angle | rad | [`PhaseShifter`](@ref), dispatch |
| ``v^{\text{as}}_{e}`` | `:vas` | edge | star point angle | rad | [`MultiWindingTransformer`](@ref) |

The ratio magnitude appears nowhere: with every voltage magnitude equal to one
there is nothing for it to change. A [`TapChanger`](@ref) is therefore **inert**
here and a [`PhaseShifter`](@ref) is a linear control. See
[The linearized formulation](@ref).

## Constraints

### Two-winding

The ideal ratio, and the π-equivalent behind it:

```math
v_{i} = T_{e} \, v^{\text{t}}_{e},
\qquad
c^{\text{t}}_{e} = \overline{T_{e}} \, c_{a^{\text{f}}} ,
```

which conserves complex power across the ideal part, followed by

```math
\begin{aligned}
c^{\text{t}}_{e} &= y^{\text{sh}}_{e,\text{fr}} \, v^{\text{t}}_{e} + c^{\text{s}}_{e}, \\
c_{a^{\text{t}}} &= -c^{\text{s}}_{e} + y^{\text{sh}}_{e,\text{to}} \, v_{j}, \\
v^{\text{t}}_{e} - v_{j} &= z_{e} \, c^{\text{s}}_{e},
\end{aligned}
```

the same three equations a [Branch](@ref) writes, with ``v^{\text{t}}_{e}`` and
``c^{\text{t}}_{e}`` in place of the from node's own voltage and current.

A [`PhaseShifter`](@ref) in a dispatch problem adds

```math
(t^{\text{r}}_{e})^2 + (t^{\text{i}}_{e})^2 = tm_{e}^2,
\qquad
\tan(ta^{\text{min}}_{e}) \, t^{\text{r}}_{e} \le t^{\text{i}}_{e} \le \tan(ta^{\text{max}}_{e}) \, t^{\text{r}}_{e} ,
```

so the ratio keeps its magnitude and moves only in angle. A
[`TapChanger`](@ref) instead bounds ``tm_{e}`` between ``tm^{\text{min}}_{e}``
and ``tm^{\text{max}}_{e}`` and holds the angle at `ta`.

!!! note "The tap is continuous"
    A real on-load tap changer moves in discrete steps. Modelling that
    faithfully would make the problem an integer one, which is a different class
    of model and needs a different solver; the tap here is continuous within its
    range.

### Multi-winding

For winding ``k`` at node ``i_k``, with ratio ``T_{e,k}`` and impedance
``z_{e,k}``, write the voltage and the current referred through the ratio as

```math
v^{\text{t}}_{e,k} = v_{i_k} / T_{e,k},
\qquad
c^{\text{t}}_{e,k} = \overline{T_{e,k}} \, c_{a_k} ,
```

after which the star is

```math
v^{\text{t}}_{e,k} - v^{\text{s}}_{e} = z_{e,k} \, c^{\text{t}}_{e,k}
\quad \text{for every } k,
\qquad
\sum_{k} c^{\text{t}}_{e,k} = y^{\text{m}}_{e} \, v^{\text{s}}_{e} .
```

With unit ratios and no magnetising branch this is a plain star of impedances,
and gives the same node voltages as the same star written with a real node in the
middle and one branch per winding — which is what the test suite checks.

!!! note "Why the magnetising branch lives here"
    Making the star point implicit costs one thing: nothing can be hung off it
    from outside, because it is not a node a unit can name. The magnetising
    branch, which is what one usually wants there, is therefore part of the
    component. In exchange the node set stays a set of real busbars, no synthetic
    identifier has to be invented and kept from colliding, and the topology does
    not grow.

### In the `LPFFormulation`

```math
p_{a^{\text{f}}} = -b_{e} \left(v^{\text{a}}_{i} - v^{\text{a}}_{j} - ta_{e}\right),
\qquad
p_{a^{\text{t}}} = -p_{a^{\text{f}}} ,
```

and, for a multi-winding transformer,

```math
p_{a_k} = -b_{e,k} \left(v^{\text{a}}_{i_k} - ta_{e,k} - v^{\text{as}}_{e}\right)
\quad \text{for every } k,
\qquad
\sum_{k} p_{a_k} = 0 .
```

```@docs
phase_shift
```

```@docs
tap_ratio
solution_tap
variable_two_winding!
constraint_two_winding_limits!
```
