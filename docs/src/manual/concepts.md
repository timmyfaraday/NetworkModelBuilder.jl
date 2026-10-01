# Concepts for newcomers

A [`NetworkModel{P,F}`](@ref) is parameterized by two independent choices, and
most of the conceptual on-ramp is telling them apart:

- `P`, the **problem type**, decides *which question is asked* of the
  network — which degrees of freedom are free, which are fixed by a setpoint,
  what is minimized.
- `F`, the **formulation type**, decides *in which variables the physics are
  written* — rectangular voltage and current, or a linearized approximation.

The two never interact: swapping `F` never changes what question is being
asked, and swapping `P` never changes how a `Branch` or a `Generator` is
written down. This page works one small network through both axes, then shows
the two ways to read an answer back.

## `P` decides the question

The network below is the smallest one that makes a question interesting: a
branch rated below what the cheap generator alone would carry, so something
has to give.

```@example concepts-question
using NetworkModelBuilder, Ipopt, JuMP

data = parse_tables(
    node = (id        = [1, 2],
            type      = ["REF", "PQ"]),
    edge = (id        = [1],
            component = ["Branch"],
            terminals = [[1, 2]],
            r         = [0.0],
            x         = [0.1],
            rate_a    = [0.5]),
    unit = (id        = [1, 2, 3],
            component = ["Generator", "Generator", "FixedLoad"],
            node      = [1, 2, 2],
            pg        = [1.0, 0.0, missing],
            cost      = [[0.0, 10.0], [0.0, 100.0], missing],
            pd        = [missing, missing, 1.0]))

optimizer = optimizer_with_attributes(Ipopt.Optimizer, "print_level" => 0)
nothing # hide
```

A [`LoadFlowProblem`](@ref) asks *what flows, given the dispatch as it
stands*. `pg` is not a decision here — the branch is left to carry whatever a
fixed 1.0 and 0.0 imply, rating or not:

```@example concepts-question
lf = solve_lf(data, IVRFormulation, optimizer)
print_summary(lf)
```

An [`OptimalPowerFlowProblem`](@ref) asks a different question — *what
dispatch is cheapest, given the network's limits* — so `pg` becomes a decision
bounded by `pmin`/`pmax`, and the branch's `rate_a` is now enforced rather than
merely reported on:

```@example concepts-question
opf = solve_opf(data, IVRFormulation, optimizer)
print_summary(opf)
```

The optimizer moves generation away from the cheap unit only as far as the
branch forces it to — the same physics, the same network, a different
question.

A [`RedispatchProblem`](@ref) asks a third question — *given a dispatch
already decided (by a market, by the file's own `pg`), what is the cheapest
way to adjust it so the network can carry it* — with the answer expressed as
volumes moved rather than an absolute dispatch. [Redispatch](@ref) works this
same network through in full, including its `RedispatchProblem` under
[`LPFFormulation`](@ref).

## `F` decides the mathematics

Every problem type is implemented in both `IVRFormulation` (current and
voltage, in rectangular coordinates) and `LPFFormulation` (a linearized
approximation — see [The linearized formulation](@ref) for what that costs).
Posing the same question in the other formulation changes nothing about *what*
is being asked:

```@example concepts-question
opf_lpf = solve_opf(data, LPFFormulation, optimizer)
(ivr = opf["objective"], lpf = opf_lpf["objective"])
```

Close, not identical — `LPFFormulation` drops losses, so it under-counts the
generation a lossy network actually needs. Which formulation to reach for is a
question of what the study needs to capture, never of what question is being
asked; see [What is implemented](@ref) for the full `(P, F)` grid.

## Reading the answer back

Every `result` carries the same nested dictionary regardless of `(P, F)`:
[`nw_solution`](@ref) reaches into it without spelling out the path by hand.
It is a reasonable, PowerModels.jl-familiar default, and it is *all* a
`result` carried before [`solution_tables`](@ref) — for a caller who wants
every node or edge at once, as a plain column rather than a dictionary walked
by hand, `solution_tables` is a tidy `NamedTuple` view over the same numbers:

```@example concepts-question
tables = solution_tables(data, opf)

(dict = nw_solution(opf)["node"]["2"]["vm"], column = tables.node.vm)
```

Both read the same solve. `nw_solution` is the one-value-at-a-time reach;
`solution_tables` is the whole table at once — `DataFrame(tables.node)` is an
ordinary table for a caller who has DataFrames.jl, with no new dependency of
this package's own.

## Coming from SmaLoadFlow

Two API shapes that ask the same kind of questions, described honestly rather
than mapped feature-for-feature — the packages are not equivalent, and nothing
below claims they are:

| | this package | SmaLoadFlow |
|:---|:---|:---|
| the network + what to compute | `NetworkModel{P,F}`, two orthogonal type parameters selected by multiple dispatch | `PowerSystem` + `SolveOptions`, two separate objects |
| the answer | a nested `Dict{String,Any}` (`nw_solution`), now also a tidy `NamedTuple` (`solution_tables`) | `RunResultXr`, xarray-based — labeled, sliceable, plotted with the shipped matplotlib helpers |
| on-ramp | multiple dispatch and two type parameters need understanding before anything makes sense | one object to construct, one to configure |

Neither the `Dict` nor the type parameters are a defect to fix away — the
`Dict` is what every solver library callers already know looks like, and the
type parameters are what let an extension package add a problem or a
formulation without a single line of this package changing. `solution_tables`
and this page exist because the on-ramp itself was real, not because the
underlying design was wrong.
