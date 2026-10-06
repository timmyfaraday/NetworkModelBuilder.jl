# Transformer

A transformer is an edge with two or more **windings**. Winding ``k`` has an ideal
ratio ``T_{e,k} = tm_{e,k} \exp(j \, ta_{e,k})`` at its terminal, a series impedance
``z_{e,k}`` and a shunt ``y^{\text{sh}}_{e,k}``, and the windings meet at a **star
point** that carries the magnetising branch ``y^{\text{m}}_{e}``. That is the T-model,
for two windings as for more: a transformer is a set of ideal two-winding
transformers, series impedances and shunts [Claeys2020](@citet), and a core that
loses power changes the optimum [Hamilton2023](@citep).

One type covers what a fixed transformer, a tap changer, a phase shifter and a
transformer with three windings used to be. Whether the ratio of a winding is data,
a decision or one of a list of positions is a property of the winding, a
[`TapMode`](@ref) on its `oltc` for the magnitude and on its `pst` for the angle, so
a device that is both is not a fifth type.

```@docs
AbstractTransformer
Transformer
TapMode
```

## The star point and the voltage behind the ratio

For winding ``k`` at node ``i_k``, write the voltage behind the ratio and the current
referred through it as

```math
v_{i_k} = T_{e,k} \, v^{\text{t}}_{e,k},
\qquad
c^{\text{t}}_{e,k} = \overline{T_{e,k}} \, c_{a_k} ,
```

which conserves complex power across the ideal part. What is left is the star,

```math
v^{\text{t}}_{e,k} - v^{\text{s}}_{e} = z_{e,k} \left( c^{\text{t}}_{e,k} -
y^{\text{sh}}_{e,k} \, v^{\text{t}}_{e,k} \right),
\qquad
\sum_{k} \left( c^{\text{t}}_{e,k} - y^{\text{sh}}_{e,k} \, v^{\text{t}}_{e,k} \right)
= y^{\text{m}}_{e} \, v^{\text{s}}_{e} .
```

The star point is **not a node**. It never enters ``I``, gets no identifier, carries no
balance among the node constraints, and does not appear in `ids(net, Node)` or in the
node part of a solution. It is a pair of variables belonging to the edge. The
magnetising branch is therefore part of the component, since nothing outside it could
be hung from the star point; in exchange the node set stays a set of real busbars and
the topology does not grow.

Where a winding holds its ratio, ``v^{\text{t}}_{e,k}`` is substituted away: it is an
expression in the node voltage, or the node voltage itself where the ratio is one.
Where the problem chooses the ratio, ``v^{\text{t}}_{e,k}`` is a variable of the winding
and the ratio enters as ``v_{i_k} = T_{e,k} \, v^{\text{t}}_{e,k}``, so that the
equations stay polynomial where substituting would have divided by a variable.

### The π-equivalent is a special case

A Matpower branch with a ratio is an ideal transformer at the sending end of a
π-section [Geth2022, Coffrin2015](@citep). It is the T-model with ``y^{\text{m}}_{e} = 0``,
the whole impedance on the first winding, none on the second, and half the charging
on each winding, which is how [`parse_matpower`](@ref) builds it. The star point then
lies on the series path, so where the impedance is split between the windings makes no
difference, and what is imported is exact.

## Parameters

Every field with an entry per winding is indexed by terminal position. A transformer
with two windings accepts a scalar for the first winding, the second being neutral: a
ratio of one, no shift, no impedance, no shunt.

| symbol | field | description | unit | default |
|:-------|:------|:------------|:-----|:--------|
| ``z_{e,k}`` | `r`, `x` | series resistance and reactance, referred to the star point | pu | |
| ``y^{\text{sh}}_{e,k}`` | `g_sh`, `b_sh` | shunt admittance behind the ratio | pu | `0` |
| ``y^{\text{m}}_{e}`` | `g_m`, `b_m` | magnetising admittance at the star point | pu | `0` |
| ``tm_{e,k}`` | `tm` | ratio magnitude, or its setpoint | pu | `1` |
| ``ta_{e,k}`` | `ta` | ratio angle, or its setpoint | rad | `0` |
| | `oltc`, `pst` | whether the magnitude, the angle, can move: a [`TapMode`](@ref) | | `FIXED` |
| ``tm^{\text{min}}_{e,k}``, ``tm^{\text{max}}_{e,k}`` | `tm_min`, `tm_max` | limits of the magnitude | pu | `0.9`, `1.1` |
| ``ta^{\text{min}}_{e,k}``, ``ta^{\text{max}}_{e,k}`` | `ta_min`, `ta_max` | limits of the angle | rad | `±π/12` |
| | `tm_step`, `ta_step` | distance between the positions of a `STEPPED` winding | pu, rad | `0.0125`, `1°` |
| ``s^{\text{max}}_{e,a}`` | `rate_a` | apparent power rating at each terminal | pu | `Inf` |
| | `angmin`, `angmax` | limits of the angle difference, two windings only | rad | `±π/3` |

## Variables

### In the `IVRFormulation`

| symbol | key | index | description | unit | when |
|:-------|:----|:------|:------------|:-----|:-----|
| ``c^{\text{r}}_{a}``, ``c^{\text{i}}_{a}`` | `:cr`, `:ci` | arc | terminal current | pu | all |
| ``v^{\text{sr}}_{e}``, ``v^{\text{si}}_{e}`` | `:vsr`, `:vsi` | edge | star point voltage | pu | all |
| ``v^{\text{tr}}_{a}``, ``v^{\text{ti}}_{a}`` | `:vtr`, `:vti` | arc | voltage behind the ratio | pu | a winding that moves or steps, in a dispatch problem |
| ``tm_{a}`` | `:tm` | arc | the ratio magnitude | pu | `oltc` is `CONTINUOUS` and `pst` is not |
| ``t^{\text{r}}_{a}``, ``t^{\text{i}}_{a}`` | `:tr`, `:ti` | arc | the ratio itself | pu | `pst` is `CONTINUOUS` |
| ``z^{\text{t}}_{a,s}`` | `:zt` | arc, position | the position taken, a binary | | a winding that is `STEPPED` |

The ratio of a winding that moves its angle is kept as a real and an imaginary part
rather than as an angle, so that the angle enters through a circle and a pair of
bounds in place of a sine and a cosine of a variable.

### In the `LPFFormulation`

| symbol | key | index | description | unit | when |
|:-------|:----|:------|:------------|:-----|:-----|
| ``p_{a}`` | `:p` | arc | terminal active power | pu | all |
| ``v^{\text{as}}_{e}`` | `:vas` | edge | star point angle | rad | three or more windings |
| ``ta_{a}`` | `:ta` | arc | the ratio angle | rad | `pst` is `CONTINUOUS`, in a dispatch problem |
| ``z^{\text{t}}_{a,s}`` | `:zt` | arc, position | the position taken, a binary | | `pst` is `STEPPED` |

The ratio magnitude appears nowhere: with every voltage magnitude equal to one there
is nothing for it to change. A winding that is `oltc` is therefore **inert** here,
built and solved as an ordinary winding at its setpoint. See
[The linearized formulation](@ref).

## What a winding can be

A power flow chooses nothing, so every winding holds its setpoint there. A dispatch
problem chooses the ratio of a winding that can move. A phase shifter is the angle of
the ratio as a bounded variable [GarciaGuzman2013](@citep), and the magnitude and the
angle of a tap changer follow one law over its position [Gebhardt2026](@citep):

| `oltc` / `pst` | in the `IVRFormulation` | in the `LPFFormulation` |
|:---------------|:------------------------|:------------------------|
| `FIXED` | the ratio is folded into the rows | the angle is data; the magnitude does nothing |
| `oltc = CONTINUOUS` | ``tm_{a}`` between ``tm^{\text{min}}`` and ``tm^{\text{max}}``, at the setpoint angle | inert |
| `pst = CONTINUOUS` | ``t^{\text{r}}_{a}, t^{\text{i}}_{a}`` on the circle ``(t^{\text{r}})^2 + (t^{\text{i}})^2 = tm^2``, between the angle limits | ``ta_{a}`` between ``ta^{\text{min}}`` and ``ta^{\text{max}}`` |
| both `CONTINUOUS` | the same, on the ring ``(tm^{\text{min}})^2 \le (t^{\text{r}})^2 + (t^{\text{i}})^2 \le (tm^{\text{max}})^2`` | as the angle alone |
| `STEPPED` | one binary per magnitude, per angle, or per pair | one binary per angle; `oltc` is inert |

The angle limits of a continuous winding are ``\tan(ta^{\text{min}}) \, t^{\text{r}} \le
t^{\text{i}} \le \tan(ta^{\text{max}}) \, t^{\text{r}}``.

### A winding that steps

A real tap changer and a mechanical phase shifter move in steps. A `STEPPED` winding
takes one of the positions of its range, ``lo, lo + \text{step}, \dots, hi``, with a
binary for each and exactly one of them taken,

```math
\sum_{s} z^{\text{t}}_{a,s} = 1,
\qquad
T_{a} = \sum_{s} z^{\text{t}}_{a,s} \, T_{s} ,
```

where ``T_{s}`` is the ratio of position ``s``. A winding that steps both its
magnitude and its angle has a position for every pair, the magnitudes in turn for each
angle. The setpoint has to be one of the positions, and the limits and the step of a
stepped winding cannot vary over the network index. Stepping one part of the ratio
while moving the other continuously is not built.

That makes a dispatch problem **mixed-integer**. In the `LPFFormulation` it is a
mixed-integer linear program, which a solver such as HiGHS takes. In the
`IVRFormulation` the ratio multiplies the voltage behind it, so it is a nonconvex
mixed-integer nonlinear program, which needs a solver such as Juniper. Either way
there are no duals, and so no nodal prices: [`active_nodal_price`](@ref) is `nothing`,
as it is for a free [Switch](@ref). A discrete tap makes the optimal power flow a
mixed-integer nonlinear program, the hardest case to solve [Nickel2025](@citep), which
is why a position is asked for rather than assumed.

## Constraints

### In the `IVRFormulation`

For every winding, the ideal ratio, the star equations above, and the balance at the
star point. A transformer with two windings adds the limits on the angle difference
across it, and every transformer a rating at each terminal where the problem watches
it for congestion, see [`is_monitored`](@ref). A winding that moves adds the circle,
the ring or the bounds of the table; a winding that steps adds ``\sum_{s}
z^{\text{t}}_{a,s} = 1``.

### In the `LPFFormulation`

With ``v^{\text{at}}_{k} = v^{\text{a}}_{i_k} - ta_{e,k}`` the angle behind the ratio of
winding ``k``, a transformer with two windings is a line across the sum of its
impedances,

```math
p_{a_1} = -b_{e} \left( v^{\text{at}}_{1} - v^{\text{at}}_{2} \right),
\qquad
p_{a_2} = -p_{a_1},
```

and one with more windings is a star, each winding flowing into the star point and the
flows balancing there,

```math
p_{a_k} = -b_{e,k} \left( v^{\text{at}}_{k} - v^{\text{as}}_{e} \right),
\qquad
\sum_{k} p_{a_k} = 0 .
```

The phase shift survives the approximations and the magnitude does not, which is what
makes a winding that is `pst` a real control here and one that is `oltc` an inert one.
The magnetising branch and the shunts play no part, for the same reason a branch's
shunt does not. A winding of a transformer with three or more windings needs an
impedance, since its susceptance would otherwise be infinite; the model says which
winding has none rather than returning a `NaN`. With no losses, what leaves one
terminal of a two-winding transformer arrives at the other, so the tighter of its two
ratings is the one that binds.

```@docs
tap_ratio
phase_shift
```

### In a redispatch

A winding that is `oltc` or `pst` is a **measure**, and a **non-costly** one: it has no
[`redispatch_cost`](@ref), so moving it is free. A preventive one takes one setting
that serves every contingency, a corrective one a setting per contingency, and which is
which is the [`Redispatch`](@ref) setup's to say, as it is for every other measure.
Every winding is reported next to the setpoint it was left at, so that what the
redispatch moved is the difference.

Because a free angle is free, its final value is one of however many settings relieve
the congestion equally, and which one a solver returns is not determined.

What a preventive winding holds across the contingencies is its ratio: ``tm``,
``t^{\text{r}}`` and ``t^{\text{i}}`` in the `IVRFormulation`, ``ta`` in the
`LPFFormulation`, each tied to the winding's own value in the base case. A transformer
that is held, see [`is_held`](@ref), does not write again at the other network indices
the rows that only restrict the ratio, since those of the base case imply them; written
twice, they would be dependent. A winding that steps goes further: it has no binaries
of its own and uses those of the base case. A copy tied to them would be the same
decision, and one more variable for a mixed-integer solver to branch on. A corrective
winding is independent in every contingency and keeps a set of binaries for each.

## In the solution

The entry of every terminal carries the tap of its winding, under `"tap"`:

| key | description | when |
|:----|:------------|:-----|
| `"tm"`, `"ta"` | the magnitude and the angle of the ratio | always |
| `"tr"`, `"ti"` | the ratio as a real and an imaginary part | `IVRFormulation` |
| `"step"` | the index of the position taken | a winding that steps |
| `"tm_market"`, `"ta_market"` | the setpoint the market left the winding at | a redispatch |

For a winding that holds its ratio this reports back what was given, for one the
problem chose it is what the optimizer chose. A position is numbered as its range runs;
for a winding that steps both magnitude and angle in the `IVRFormulation`, the
magnitudes in turn for each angle. [`solution_tables`](@ref) has the taps as `tap_tm`,
`tap_ta` and so on, one row per terminal, and `missing` for every edge that is not a
transformer.

## An example

A cheap generator at node 1 reaches the load at node 3 by two paths: a direct corridor
with a rating of `0.5`, and a path through node 2 with a transformer in it. Held at its
setpoint of no shift the transformer leaves the corridor at its rating and the dear
generator at node 3 has to cover the rest. With its angle free, or stepped, it steers
the flow onto the path.

```@example transformer
using NetworkModelBuilder, HiGHS, JuMP

function corridor(; kw...)
    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF),
                               2 => Node(; id = 2), 3 => Node(; id = 3))
    E = Dict{Int,AbstractEdge}(
        1 => Branch(; id = 1, terminals = [1, 3], r = 0.0, x = 0.1, rate_a = 0.5),
        2 => Transformer(; id = 2, terminals = [1, 2], r = 0.0, x = 0.1, kw...),
        3 => Branch(; id = 3, terminals = [2, 3], r = 0.0, x = 0.1))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, pmax = 5.0, cost = [0.0, 10.0]),
        2 => Generator(; id = 2, node = 3, pmax = 5.0, cost = [0.0, 100.0]),
        3 => FixedLoad(; id = 3, node = 3, pd = 1.0))

    return NetworkData(Network(I, E, U); baseMVA = 100.0)
end

optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)

held    = solve_opf(corridor(), LPFFormulation, optimizer)
free    = solve_opf(corridor(; pst = CONTINUOUS, ta_min = -0.3, ta_max = 0.3),
                    LPFFormulation, optimizer)
stepped = solve_opf(corridor(; pst = STEPPED, ta_min = -0.3, ta_max = 0.3, ta_step = 0.1),
                    LPFFormulation, optimizer)

corridor_flow(result) = nw_solution(result)["edge"]["1"]["terminal"]["1"]["p"]

(held    = held["objective"],
 free    = free["objective"],
 stepped = stepped["objective"],
 within_rating = all(abs(corridor_flow(r)) <= 0.5 + 1e-9 for r in (free, stepped)),
 prices  = (free = get(nw_solution(free)["node"]["3"], "lambda", nothing),
            stepped = get(nw_solution(stepped)["node"]["3"], "lambda", nothing)))
```

Held, the transformer costs `32.5`; free or stepped it brings the cost down to `10.0`,
the cheap generator alone. The positions are `-0.3, -0.2, \dots, 0.3`, and any of the
first three clears the corridor, so which one the solver takes is not determined. The
stepped model is mixed-integer and has no prices; the free one is linear and has one at
every node. The same network in the `IVRFormulation` is the same model with the
nonconvex version of every row, and needs a solver such as Juniper for the stepped
winding.

## Migrating from the four types

`PhaseShifter`, `TapChanger`, `MultiWindingTransformer` and
`AbstractTwoWindingTransformer` are gone, with no shims.

| before | now |
|:-------|:----|
| `PhaseShifter(; ta_min, ta_max, cost)` | `Transformer(; pst = true, ta_min, ta_max)`; a phase shifter has no price |
| `TapChanger(; tm_min, tm_max)` | `Transformer(; oltc = true, tm_min, tm_max)` |
| `MultiWindingTransformer(; terminals, r, x, tm, ta, g_m, b_m)` | `Transformer(; terminals, r, x, tm, ta, g_m, b_m)` |
| `b_fr`, `b_to` of a transformer | `b_sh = [b_fr, b_to]` |
| `tm`, `ta`, `r`, `x`, `rate_a` as scalars | the same for two windings; a vector with an entry per winding for more |
| `solution["edge"][e]["tap"]` | `solution["edge"][e]["terminal"][k]["tap"]` |
| `tap["taup"]`, `tap["tadn"]` | gone with the price |
| `pst_cost` of [`parse_zorba`](@ref) | deprecated, with a warning, and without effect |
| `solution_tap`, `variable_two_winding!` and the other helpers of the old types | [`tap_ratio`](@ref) and [`phase_shift`](@ref) take a winding |

## References

```@bibliography
Pages = [@__FILE__]
Canonical = false
```
