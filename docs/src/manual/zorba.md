# The Zorba adapter

Zorba poses a security constrained redispatch as five tables and four numbers,
and reads the answer back as two more. This is the translation of the one into
the other — the whole of it, in one file, so that nothing else in the package
knows Zorba exists.

```@docs
parse_zorba
solve_zorba
zorba_tables
```

## Why the translation is on this side

The alternative is a translator in Python that hands this package its own
tables. Putting it here instead buys three things: the caller stays thin, the
package becomes independently exercisable on real Zorba grids without a Python
process anywhere near it, and the unit conversion happens in exactly one place —
Zorba is in MW and degrees, this package is per unit on `baseMVA` and radians.

The hand-off is Arrow either way, which is the same boundary [Tabular
input](@ref) already uses.

## A study is a network, not a problem

What arrives over the boundary is a grid, a schedule and a set of outages. Which
question to ask of it is a separate choice, and [`solve_zorba`](@ref) takes the
problem and the formulation:

```julia
result = solve_zorba(data, HiGHS.Optimizer)                         # as Zorba poses it
opf    = solve_zorba(data, OptimalPowerFlowProblem, LPFFormulation, opt)
ac     = solve_zorba(data, RedispatchProblem, IVRFormulation, opt)
```

[`zorba_tables`](@ref) writes the answer to any of them. What it reports — a
terminal power, an overload where one was priced, a tap angle — is what every
formulation with a model writes, so the tables come out the same shape whatever
was asked; a problem that enforced its ratings rather than pricing them simply
reports an overload of zero throughout, and one that held the phase shifters at
their setpoints reports those.

The [`Redispatch`](@ref) the settings amount to rides along in `data.ext[:zorba]`
and is placed in the model whatever the problem is. Only a
[`RedispatchProblem`](@ref) consults it, so it is inert elsewhere rather than
something to strip out.

!!! note "Posable is not the same as well posed"
    The mechanism is general; whether a given question has an answer is a
    property of the data, and Zorba's data is a DC abstraction.

    A study has a **fixed injection at every node and no slack machine**, so a
    [`LoadFlowProblem`](@ref) on one is a square system with a reference angle
    on top of it and a solver will say it has too few degrees of freedom. The
    reactances are in per unit on a 100 MVA base and are large — the reference
    study runs at `x = 1` — so an [`IVRFormulation`](@ref) will usually find the
    voltage limits it never had in the DC model. Neither is the adapter refusing;
    both are the study saying what it is.

    Two things the package refuses outright, and says so: a [`DCLink`](@ref) has
    no model in an alternating current formulation, so a study with an `hvdc`
    table cannot be posed in one, and a phase shifter priced per radian is
    linearized-only — `pst_cost = 0.0` is what asks the current based question
    about a study that has one.

## What becomes what

| Zorba                                | here                                                          |
|:-------------------------------------|:--------------------------------------------------------------|
| a node of `net_position`             | a [`Node`](@ref), the first of them the reference              |
| its `value_mw`                       | a [`FixedLoad`](@ref) withdrawing the negation of it           |
| a row of `grid` with `pst_deg == 0`  | a [`Branch`](@ref)                                             |
| a row with a phase shift range       | a [`PhaseShifter`](@ref) priced at `pst_cost` per radian       |
| its `capacity`                       | `rate_a`, in per unit; blank is unlimited                      |
| an `Hvdc`                            | a [`DCLink`](@ref) scheduled at zero and priced per per-unit   |
| an outage                            | a `:contingency` coordinate, carried on the `status` of the links it takes out |
| `overload_penalty`                   | an [`OverloadPrice`](@ref), or a hard rating for `:force`      |
| `wiggle_room`                        | an [`EnergyNotServed`](@ref) and a [`Spill`](@ref) at every node, free and bounded |
| a time step                          | a `:time` coordinate                                           |

Two of those are worth dwelling on, because they are where the two models differ
rather than where they agree.

### An outage is a topology, not a nulled susceptance

Zorba multiplies the susceptance of an outaged link by zero, which forces its
flow to zero while leaving the link in every array. Here the link is simply
**out of service** at that coordinate, and the topology of that network index is
derived from the statuses — see [The network index](@ref). The models are the
same; what changes is that a substation trip is a `status` that is false on
several links rather than a mask that has to be built by hand, and that the
package never carries a table indexed by network index to hold it.

The answer still reports an outaged link, at rest, because that is what Zorba
writes for it and what a downstream join expects.

### A preventive measure is a measure that takes one value

Zorba's phase shifts, HVDC flows and wiggle room carry no outage coordinate:
they are decided once and serve every state of the world. That is precisely what
this package calls a **preventive** measure, see [`Redispatch`](@ref), and the
adapter poses the study that way — so the distinction Zorba makes implicitly, by
which arrays it gives an outage dimension to, is the one the model states
explicitly.

Nothing else has to change to ask the other question. A corrective study is
`solve_rd` with `Redispatch(; control = :corrective)`, and it is a question
Zorba's model cannot pose at all.

## The objective

Zorba minimizes

```math
\sum_{t} c^{\text{pst}} |s_{t}| + \sum_{t} c^{\text{dc}} |p_{t}| +
\sum_{t} \sum_{o} c^{\text{ol}} o_{t,o} ,
```

its measures charged **once** and its congestion **once per state of the
world**. Here every cost is weighted by the weight of its network index, and a
`:contingency` coordinate carries a probability — see [`default_weight`](@ref) —
so `N` copies of a preventive measure are each worth `1/N` and are charged once
between them, while the congestion comes out an *expectation* rather than a sum.

Multiplying the congestion price by `N` turns that average back into Zorba's
sum, and nothing else has to move: the two objectives are then the same
function, not two similar ones. That is what `parse_zorba` does by default, and
giving it real `contingency_weight` probabilities asks the expected-cost
question instead, which drops the factor.

## The sign of a phase shift

This package writes the linearized flow as

```math
p = -b \left(\theta_{i} - \theta_{j} - ta\right)
```

and Zorba as ``P = (\theta_{i} - \theta_{j} + s) B``, so `ta` is the **negation**
of Zorba's phase shift. The negation is applied in [`zorba_tables`](@ref) and
nowhere else: a study that compared the two column by column would otherwise
find every phase shifter mirrored and every flow right, which is the hardest
kind of difference to explain.

## The files

```@docs
write_zorba
```

```
study/
├── grid.arrow
├── net_position.arrow
├── hvdc.arrow           # optional
├── outage.arrow         # optional
└── out/
    ├── grid_flows.arrow
    └── pst_dispatch.arrow
```

The settings are keywords rather than files: they are the arguments of a *run*,
not the description of a grid, which is how Zorba passes them too.

```julia
using Arrow, HiGHS, NetworkModelBuilder

data   = parse_zorba("study"; overload_penalty = 1e3, pst_cost = 1.0)
result = solve_zorba(data, HiGHS.Optimizer)
write_zorba("study/out", zorba_tables(data, result))
```

From the Python side, with `juliacall`:

```python
from juliacall import Main as jl

jl.seval("using Arrow, HiGHS, NetworkModelBuilder")
data   = jl.parse_zorba("study", overload_penalty=1e3)
result = jl.solve_zorba(data, jl.HiGHS.Optimizer)
jl.write_zorba("study/out", jl.zorba_tables(data, result))

flows = GfOverloadSchema.validate(pl.read_ipc("study/out/grid_flows.arrow"))
```

The columns and their types are what `GfOverloadSchema` and `PstDispatchSchema`
declare, so the frames need no casting on arrival — a `time_id` is a `UInt16`, a
flow is a `Float32`, and the `outage` of the base case is null rather than the
string `"NONE"`.

## What is not carried

| Zorba                          | why not                                                        |
|:-------------------------------|:---------------------------------------------------------------|
| `Outage.node_adjustment`       | `RedispatchSolver.run` cannot express it either — it takes a list of link names |
| `could_trip`, `trip_with`      | what an outage is, is the `outage` table's business rather than a flag on a line |
| `pst_tap`, `pst_tap_min/max`   | the linearized model steers on the angle, not on the tap position |
| `DEG_TO_RAD`                   | it is `3.14 / 180`; the conversion here is exact, and that is a difference to expect in a comparison rather than to reproduce |
| the batching granularity       | `horizon` and `step` roll a study, see [`solve_rolling_horizon`](@ref) |
| `RdsSolution.wiggle_mw`        | the two frames Zorba validates do not carry it; the volumes are in the solution, under the slack units of each node |

## Reading it back

```@docs
zorba_study
ZorbaStudy
ZorbaLink
```
