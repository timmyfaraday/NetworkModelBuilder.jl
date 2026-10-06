# Switch

A switch is an edge ``(e, i, j)`` that is either **closed** or **open**, and has no
impedance. Closed, it holds the voltage at its two nodes equal and lets any flow
through; open, it lets none through and leaves the two voltages independent. That
is all of its physics.

It is a type of its own rather than a [Branch](@ref) with a very small impedance,
and the reason is numerical. The flow of a branch is its susceptance times an angle
difference, so a coupler written as a branch needs a reactance close to zero and
with it a susceptance close to infinity: a reactance of `1e-7` puts `1e7` in a
matrix whose other entries are around `60`, which a solver cannot be asked to weigh.
Flooring the reactance repairs the conditioning and moves the flows it was never
meant to touch. A switch has no reactance and no susceptance, so there is nothing to
round. See [Where a type earns its place](@ref).

The literature has both. [Babaeinejadsarookolaee2021](@citet) keep
a breaker a branch and regularise it, with a susceptance of `1e5` closed and `1e-2`
open; [Goldis2017](@citet) model it exactly, as an element of zero
impedance with a flow of its own.

!!! note "A switch is modelled exactly, not regularised"
    NetworkModelBuilder.jl models a switch **exactly**, as an element of zero
    impedance with a flow of its own, and does **not** regularise it as a branch with
    a large closed and a small open susceptance.

```@docs
AbstractSwitch
Switch
SwitchLock
```

## Parameters

| symbol | field | description | unit |
|:-------|:------|:------------|:-----|
| | `id`, `name` | identifier and label | |
| ``(i, j)`` | `terminals` | the two nodes it connects, exactly two | |
| | `lock` | [`LOCKED`](@ref SwitchLock) or [`FREE`](@ref SwitchLock) | |
| ``z^{0}_{e}`` | `position` | `0` for open, `1` for closed | |
| ``s^{\text{max}}_{e}`` | `rate_a` | the rating, `Inf` when unlimited; a free switch needs a finite one | pu |
| ``\theta^{\text{min}}_{e}``, ``\theta^{\text{max}}_{e}`` | `angmin`, `angmax` | the angle difference allowed across it while open | rad |
| | `status` | in service | |

Every field but `id`, `name`, `terminals`, `lock` and `ext` may be a
[`NetworkVector`](@ref). `lock` describes what the equipment is allowed to do and so
does not vary over the network index; take a switch out of the network, which leaves
its two nodes apart, through `status`, as for any edge.

### Lock and position

A **locked** switch is data: it is closed or open as its `position` says, in every
problem. A **free** switch is a decision in a dispatch problem, and its `position`
is only the position the decision starts from. A power flow chooses nothing, so it
holds every switch where its `position` puts it, whatever its `lock` says.

That a free switch may be opened by the problem, where a locked one may not, is the
whole difference between the two, and it is what makes the model of a free switch a
different kind of model: see [A free switch](@ref).

## Variables

### In the `LPFFormulation`

| symbol | key | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``p_{a}`` | `:p` | arc | terminal active power, node into edge | pu |
| ``z_{e}`` | `:zsw` | edge | closed position, a binary variable, free switches in a dispatch problem only | |

### In the `IVRFormulation`

| symbol | key | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``c^{\text{r}}_{a}``, ``c^{\text{i}}_{a}`` | `:cr`, `:ci` | arc | terminal current, node into edge | pu |
| ``z_{e}`` | `:zsw` | edge | closed position, a binary variable, free switches in a dispatch problem only | |

A switch has no variables of its own beyond that. ``z_{e}`` starts at the position
in the data.

## Constraints

| name | problem |
|:-----|:--------|
| [`constraint_edge`](@ref) | all |
| [`constraint_edge_limits`](@ref) | dispatch |

What leaves one terminal arrives at the other, ``p_{a^{\text{t}}} =
-p_{a^{\text{f}}}``, and in the `IVRFormulation` the same on the real and the
imaginary current. Then, for a switch the problem holds where it is,

| position | `LPFFormulation` | `IVRFormulation` |
|:---------|:-----------------|:-----------------|
| open     | ``p_{a^{\text{f}}} = 0`` | ``c^{\text{r}}_{a^{\text{f}}} = c^{\text{i}}_{a^{\text{f}}} = 0`` |
| closed   | ``v^{\text{a}}_{i} = v^{\text{a}}_{j}`` | ``v^{\text{r}}_{i} = v^{\text{r}}_{j}``, ``v^{\text{i}}_{i} = v^{\text{i}}_{j}`` |

A closed switch is an **equality, not a merged node**: both of its nodes stay in
the model with their own results, and the flow through it is whatever the node
balances ask of it. Merging closed switches is a network reduction, a separate
question from what a switch is.

### The rating

A finite `rate_a` bounds a closed switch in a dispatch problem,

```math
-s^{\text{max}}_{e} \le p_{a^{\text{f}}} \le s^{\text{max}}_{e}
```

in the `LPFFormulation`, and in the `IVRFormulation`

```math
\left( (v^{\text{r}}_{i})^2 + (v^{\text{i}}_{i})^2 \right)
\left( (c^{\text{r}}_{a^{\text{f}}})^2 + (c^{\text{i}}_{a^{\text{f}}})^2 \right)
\le (s^{\text{max}}_{e})^2 .
```

It is an equipment limit, so it holds whether or not the switch is monitored for
congestion, and an [`OverloadPrice`](@ref) does not reach it. An open switch has no
flow to limit.

### Loops of closed switches

A closed switch has no impedance, so a loop of them leaves the split of the flow
between them undetermined, and a solver is free to choose: on two switches in
parallel HiGHS's simplex returns `1.0` and `0.0` where Ipopt returns `0.5` and
`0.5`. The model fixes the split so that every solver gives the same one.

Among the switches held closed at a network index, the equality of angles or of
voltages is written only for a spanning tree of each group, taken by ascending
identifier. Every other closed switch closes a loop with the tree and gets the
equation of that loop in its place,

```math
\sum_{s \in \text{loop}} \sigma_{s} \, p_{a^{\text{f}}_{s}} = 0 ,
```

with ``\sigma_{s} = \pm 1`` by the direction the loop runs through ``s``, and in the
`IVRFormulation` the same on each current. This is Kirchhoff's voltage law with
every switch given the same impedance, so parallel switches **share the flow
equally**, and a triangle of three splits it by the length of each way: two thirds
over the switch across and one third over the two beside it.

[Goldis2017](@citet) need no such equation because their breaker
model excludes the case: it exists only where there are no parallel breakers and no
closed loops of breakers.

### A free switch

In a dispatch problem a free switch is a binary variable ``z_{e}``, and the model
that follows is **mixed-integer**. Choosing which elements to open together with the
dispatch is optimal transmission switching, which [Fisher2008](@citet)
formulated as a mixed-integer program with a binary for each line, and which
[Kocuk2016](@citet) show to be NP-complete even on series-parallel
networks. In the `LPFFormulation`, closed when ``z_{e} = 1``,

```math
\theta^{\text{min}}_{e} (1 - z_{e}) \le v^{\text{a}}_{i} - v^{\text{a}}_{j}
\le \theta^{\text{max}}_{e} (1 - z_{e}) ,
\qquad
-s^{\text{max}}_{e} z_{e} \le p_{a^{\text{f}}} \le s^{\text{max}}_{e} z_{e} .
```

Closed, the first pair is the equality of the angles and the second is the rating.
Open, the first lets the angles part within the range the data allows and the second
forces the flow to zero. The flow rows are those of [Fisher2008](@citet),
the flow between its bounds times the binary; the angle rows are what their big-M rows
on Ohm's law become for an element that has no susceptance. The `IVRFormulation` has
the same pair on the real and the imaginary part of the voltage across the switch and
of the current through it, with

```math
\left| v_{i} - v_{j} \right| \le M_{e} (1 - z_{e}) ,
\qquad
\left| c_{a^{\text{f}}} \right| \le C_{e} z_{e} ,
\qquad
M_{e} = 2 \max(v^{\text{max}}_{i}, v^{\text{max}}_{j}) ,
\quad
C_{e} = \frac{s^{\text{max}}_{e}}{\min(v^{\text{min}}_{i}, v^{\text{min}}_{j})} ,
```

and the rating of a closed switch on top, which makes that model **nonconvex** as
well as mixed-integer. It is the AC optimal transmission switching problem, a
nonconvex mixed-integer nonlinear program [Coffrin2014, Kocuk2017](@citep), and it
is there because a topology the linearized model chooses may have no feasible AC
dispatch at all, as [Coffrin2014](@citet) find.

Three things follow, and none of them is optional:

- **A free switch needs a finite `rate_a`**, since the rating is what the big-M rows
  are written with; the model is not built without one. In the `IVRFormulation` the
  nodes it joins need a positive `vmin` for the same reason.
- **There are no prices.** A mixed-integer program has no duals, so a model with a
  free switch reports [`active_nodal_price`](@ref) as `nothing` and the `dual_status`
  of its result as `NO_SOLUTION`. A model whose switches are all locked keeps them.
  [Hedman2009](@citet) price a switching solution by fixing the
  integer variables at their best-found values and taking the duals of the linear
  program that remains. Here that is a lock: read each position from the solution,
  lock the switches there and solve again, as the example does.
- **It needs a solver that takes integers**, and in the `IVRFormulation` one that
  takes a nonconvex nonlinear constraint as well. The test suite uses HiGHS for the
  first and Juniper for the second.

!!! note "A free switch is as good as every way of locking it"
    The optimum of a model with free switches is the best of the optima of the
    models with every one of them locked at each of its two positions, and the test
    suite checks it so, on a loop of three. Fixing every ``z_{e}`` at a position
    gives the model of the same switches locked there.

### The big-M values

The constants are the data: the rating ``s^{\text{max}}_{e}``, the range of the angle
difference, and in current the voltage limits. Constants derived from the network are
smaller and give a better relaxation. [Fattahi2019](@citet) show
that the best ones are NP-hard to find, and give a shortest-path bound where a
connected set of lines is fixed; [Pineda2024](@citet) tighten them
by relaxing the binaries and capping the cost; [Pineda2026](@citet)
do so where every line is switchable. None of that is done here, so a rating that is
loose is a big-M that is loose.

### Loops that a free switch can close

A loop of switches that the problem closes by choosing them has to split its flow
as a loop of locked switches does, or the problem would route the flow round it as
it liked and undercut every way of locking the switches. Every simple cycle of the
switches that are held closed or free, with at least one free, therefore gets a row
that holds when its free switches are closed,

```math
\left| \sum_{s \in \text{loop}} \sigma_{s} \, p_{a^{\text{f}}_{s}} \right|
\le M \sum_{s \in \text{loop, free}} (1 - z_{s}) ,
\qquad
M = \sum_{s \in \text{loop}} s^{\text{max}}_{s} ,
```

and in the `IVRFormulation` the same on each current, with ``s^{\text{max}}_{s}``
over the lowest voltage there may be at the ends of ``s``. A loop one of whose free
switches is open is not a loop and is not asked to be. It is the cycle row of
[Kocuk2016](@citet), Kirchhoff's voltage law round a cycle with a
big-M on the number of its lines that are open, here with every switch given the same
impedance and only the free ones counted.

That is one row for each simple cycle, which is exponential in the worst case. The
model is not built when there are more than `1000` such loops at a network index,
nor where a switch of one has no finite `rate_a`, since the sum is written with it;
lock some of the free switches, or rate the others.

### Opening a switch can split the network

Opening a switch can leave a part of the network on its own, and an island is
checked for when the model is instantiated: see [Islands](@ref). A locked-open
switch leaves its nodes apart in every problem. A free one is allowed to, and
`instantiate_model` refuses to build when opening every free switch would split an
island, unless it is told `islanding = :allow`; a power flow, which opens nothing,
is not asked. An island that has a source but no reference node is anchored at its
lowest node, see [An island without a reference node](@ref).

Keeping the switchable set from islanding is the usual practice. [Goldis2017](@citet)
restrict the switchable breakers to a set that does not island the system, 39 of them in
their case, and [Fattahi2019](@citet) note that operators keep a
connected set of lines fixed for the same reason. [Hedman2009](@citet)
allow an island that is itself N-1 secure, which is what `islanding = :allow` leaves to
the caller.

## In a redispatch

A free switch is a **measure**, like the phase shifter of a [`Transformer`](@ref) or a
[`DCLink`](@ref): a
preventive one takes one position that has to serve every contingency, a corrective
one is free to take a different position in each. Which is which is the
[`Redispatch`](@ref) setup's to say, as it is for every other measure. The preventive
switch is the model of [Hedman2009](@citet), whose switching
decisions are shared across the contingency states. A switch is
**non-costly**: it has no [`redispatch_cost`](@ref), so a move is free. A locked
switch has no position to choose and so nothing to tie across contingencies.

## In the solution

The entry of a switch in the solution carries its `"position"`, `0` or `1`, and its
`"lock"`, as `"FREE"` or `"LOCKED"`. The position is the one in the data where the
problem held the switch, and the one the problem chose where it was free; the
columns reach [`solution_tables`](@ref) for the switches, and are `missing` for
every other edge.

## An example

Three nodes round a loop: a cheap generator at node 1, a dear one at node 3, the
load at node 2, and two rated branches. Three switches across it decide how much of
the cheap generator can reach the load. Locked, they are all closed. Free, the
problem chooses.

```@example switch
using NetworkModelBuilder, HiGHS, JuMP

branch(id, i, j; rate) = Branch(; id, terminals = [i, j], r = 0.0, x = 0.1, rate_a = rate)
switch(id, i, j; rate, lock, position = 1) =
    Switch(; id, terminals = [i, j], rate_a = rate, lock = lock, position = position)

function ring(lock, positions = (1, 1, 1))
    I = Dict{Int,AbstractNode}(1 => Node(; id = 1, type = REF),
                               2 => Node(; id = 2), 3 => Node(; id = 3))
    E = Dict{Int,AbstractEdge}(
        1 => branch(1, 1, 2; rate = 1.0),
        2 => branch(2, 3, 2; rate = 1.5),
        3 => switch(3, 1, 3; rate = 0.6, lock, position = positions[1]),
        4 => switch(4, 1, 2; rate = 0.8, lock, position = positions[2]),
        5 => switch(5, 2, 3; rate = 5.0, lock, position = positions[3]))
    U = Dict{Int,AbstractUnit}(
        1 => Generator(; id = 1, node = 1, pmax = 5.0, cost = [0.0, 1.0]),
        2 => Generator(; id = 2, node = 3, pmax = 5.0, cost = [0.0, 10.0]),
        3 => FixedLoad(; id = 3, node = 2, pd = 1.8))

    return NetworkData(Network(I, E, U))
end

optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)

locked = solve_opf(ring(LOCKED), LPFFormulation, optimizer)
free   = solve_opf(ring(FREE),   LPFFormulation, optimizer)

# a free switch has no prices: lock the switches where the problem put them, and solve again
positions = [nw_solution(free)["edge"]["$e"]["position"] for e in 3:5]
priced    = solve_opf(ring(LOCKED, positions), LPFFormulation, optimizer)

(locked       = locked["objective"],
 free         = free["objective"],
 positions    = positions,
 price_free   = get(nw_solution(free)["node"]["2"], "lambda", nothing),
 price_locked = nw_solution(priced)["node"]["2"]["lambda"],
 same_cost    = priced["objective"] ≈ free["objective"])
```

The free switches reach `4.5` where the locked ones, all closed, cost `12.6`, by
closing the switch across the loop and opening the other two. The model that chose
them has no price at node 2, and the same network locked at the positions it chose
has one, `5.5`, at the same cost. The same network in the `IVRFormulation` is the same
model with the nonconvex version of every row, and needs a solver such as Juniper for
the free switches.

## References

```@bibliography
Pages = [@__FILE__]
Canonical = false
```
