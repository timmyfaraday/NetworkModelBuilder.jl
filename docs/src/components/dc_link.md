# DC link

A DC link is an edge ``(e, i, j)`` whose flow the problem **chooses**, rather
than one whose flow falls out of the voltages at its ends.

That is the whole of the distinction, and it is what makes it a type rather than
a [Branch](@ref) carrying a flag. Write the angles either side of a branch and
its flow is decided; a DC link stands between two converter stations, and what
they exchange is a setpoint. See [Where a type earns its place](@ref).

```@docs
AbstractDCLink
DCLink
```

Two things follow, and both are why such a link gets built in the first place:

- it **decouples** the nodes it joins. There is no angle difference across it to
  be limited, and the two networks need not be synchronous — each may carry its
  own reference node, which no branch could allow.
- it is **lossy** where a linearized branch is not. The linearization drops the
  losses of a branch because they are second order in the angle difference; a
  converter station's losses are first order in what it transfers and do not
  vanish, so they are modelled here even though the rest of the linearized model
  is lossless.

!!! note "One link, not two stations"
    A real scheme has a converter at each end, each with its own losses and, in
    a voltage source converter, its own reactive capability. This type collapses
    the pair into one edge. That is enough to decide a transfer in a market or
    redispatch model and deliberately less than a converter model — which is
    also why it has no model in the [`IVRFormulation`](@ref), see
    [In an alternating current formulation](@ref).

## Parameters

| symbol | field | description | unit |
|:-------|:------|:------------|:-----|
| | `id`, `name` | identifier and label | |
| ``(i, j)`` | `terminals` | the from and to node, flow positive from ``i`` to ``j`` | |
| ``s^{\text{max}}_{e}`` | `rate_a` | transfer rating | pu |
| ``\ell^{0}_{e}`` | `loss_fixed` | no-load loss of the stations | pu |
| ``\ell^{1}_{e}`` | `loss_prop` | loss per unit transferred, below one | |
| | `reverse` | whether it may carry from ``j`` to ``i`` | |
| ``p^{\text{dc,mkt}}_{e}`` | `pdc` | the market schedule | pu |
| ``c_{e}`` | `cost` | price of moving one per unit away from `pdc` | currency/pu/h |
| | `status` | in service | |

Every field but `id`, `name`, `terminals`, `reverse` and `ext` may be a
[`NetworkVector`](@ref). `reverse` describes what the equipment is able to do
and so does not vary over the network index; take a link out through `status`.

## Variables

### In the `LPFFormulation`

| symbol | key | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``p_{a}`` | `:p` | arc | terminal active power, node into edge | pu |
| ``t_{e}`` | `:pdct` | edge | power sent into the link | pu |
| ``p^{\uparrow}_{e}`` | `:pdcup` | edge | moved up from the schedule, redispatch only | pu |
| ``p^{\downarrow}_{e}`` | `:pdcdn` | edge | moved down from the schedule, redispatch only | pu |

``t_{e}`` exists only where `loss_prop` is non-zero, and only in a dispatch
problem — see [The transfer, and why it is a variable](@ref).

### In the `IVRFormulation`

None. A DC link has no model there at all.

## Constraints

| name | problem |
|:-----|:--------|
| [`constraint_edge`](@ref) | all |
| [`constraint_edge_limits`](@ref) | dispatch |

### The transfer, and why it is a variable

What leaves one end arrives at the other, less the loss of the pair of stations:

```math
p_{a^{\text{f}}} + p_{a^{\text{t}}} = \ell^{0}_{e} + \ell^{1}_{e} t_{e} ,
\qquad t_{e} \ge p_{a^{\text{f}}} , \qquad t_{e} \ge p_{a^{\text{t}}} .
```

Compare a branch, where the same statement is ``p_{a^{\text{t}}} =
-p_{a^{\text{f}}}``.

The transfer ``t_{e}`` is bounded below by what **each** end puts in, not by the
flow at one nominated end. Exactly one end is sending at a time and the other is
receiving, so the binding bound is always the sending one and the loss is
charged on the power sent. That is what keeps the link symmetric: which of its
two nodes was listed first in `terminals` is a data-entry choice, and it must
not change what the equipment does.

The bounds are inequalities because the magnitude of a variable is not something
a linear program can be told. Together they are the convex hull of the two
directions, and the loss equality is what closes it: a larger ``t_{e}`` is a
larger loss, a larger loss needs more generation, and generation is what the
objective pays for.

| the problem | is ``t_{e}`` settled on what is sent? |
|:-----------------------------------|:------------------------------------------|
| dispatch, generation priced        | yes — the objective pushes it down        |
| dispatch, `loss_prop` zero         | vacuously — there is no ``t_{e}``         |
| power flow                         | vacuously — the transfer is `pdc`, data   |
| dispatch, nobody paid to generate  | **no** — nothing pushes it down           |

The last row is a degenerate way to pose the question rather than a case the
model guards: give every generator that could serve the loss a redispatch price
of zero and ``t_{e}`` is free again. It is worth knowing about.

!!! warning "Do not charge the loss to a signed flow"
    Writing the loss as ``p_{a^{\text{t}}} = -\eta \, p_{a^{\text{f}}}`` is
    right in one direction and **creates energy** in the other: with ``\eta <
    1`` a reversed flow delivers more than it took, and a cost-minimizing solver
    will find that and use it. The inequality pair above is what a bidirectional
    lossy link needs instead, and it costs one extra row.

### The rating

A cap on what each end may put in,

```math
p_{a} \le s^{\text{max}}_{e} \quad \forall a \in A(e) ,
```

which bounds the power *sent* whichever end is sending, and needs no bound on
the receiving end because what arrives is less than what left. A link that
carries one way is the same statement with a cap of zero on the end that may not
send, so a direction and a rating are one row each rather than a special case. A
cap that is infinite is not written.

!!! note "A converter rating is not congestion"
    Unlike the rating of a branch this does not follow the monitored set, and an
    [`OverloadPrice`](@ref) does not reach it. An operator may run a line past
    its rating and pay for the risk; a converter asked for more than it was
    built for does not deliver it.

### In a power flow

A power flow chooses nothing. The link is held at its schedule, and because the
transfer is then data so is the loss:

```math
p_{a^{\text{f}}} = p^{\text{dc,mkt}}_{e} , \qquad
p_{a^{\text{f}}} + p_{a^{\text{t}}} = \ell^{0}_{e} + \ell^{1}_{e} \left| p^{\text{dc,mkt}}_{e} \right| .
```

No ``t_{e}`` is created. A power flow is a feasibility problem with no objective
at all, and a transfer variable carried into one would be settled by nothing —
the loss reported would be wherever the solver happened to stop.

### In a redispatch

The transfer splits into the market schedule and the volumes moved away from it,
the same statement a generator makes about its dispatch:

```math
p_{a^{\text{f}}} = p^{\text{dc,mkt}}_{e} + p^{\uparrow}_{e} - p^{\downarrow}_{e} ,
```

priced at ``c_{e} \left( p^{\uparrow}_{e} + p^{\downarrow}_{e} \right)``. One
price for both directions: a link is symmetric equipment and moving it either
way is the same intervention. What is priced is the **move**, not the transfer —
a link left at its schedule costs nothing however much it carries.

A `cost` of zero, the default, makes it a **non-costly** measure, taken before
anything that is priced, which is usually the right model of a link the operator
already controls. It is then the DC counterpart of a [`PhaseShifter`](@ref), and
[a redispatch](@ref Redispatch) will use it to relieve congestion for free.

```@docs
transfer_loss
transfer_limits
```

### In an alternating current formulation

There is no model, and asking for one raises an error rather than returning a
worse answer quietly.

The reason is not that it would be hard to write but that it would be a
different component. What couples a DC link to an AC network is a converter
station, and a converter is more than a lossy transfer: it sets its reactive
exchange within a capability curve, which is most of why a voltage source
converter is worth building and all of what an AC formulation would be asked
about. Writing this type against the [`IVRFormulation`](@ref) would answer that
question with a link that has no reactive power at all.

Pose the problem in the [`LPFFormulation`](@ref), or leave the link out of the
network handed to an AC one.
