# The extended graph

A power system is represented by an extended graph ``(I, E, U)``:

- ``I``, the **nodes** — electrical busbars, the only components with a voltage
  and the only ones at which a balance is written;
- ``E``, the **edges** — each connected to an *ordered list* of nodes
  ``(e, i, j, \ldots)``, so nothing assumes there are two of them;
- ``U``, the **units** — each connected to a single node ``(u, i)``.

```@docs
AbstractComponent
AbstractNode
AbstractEdge
AbstractUnit
Network
NetworkData
```

## Arcs

An edge flow variable is indexed by an [`Arc`](@ref), not by a pair ``(e, i)``:

```@docs
Arc
```

```@docs
edge_id
terminal_id
node_id
```

The terminal position is part of the identity for two reasons. Terminals are not
interchangeable — the windings of a transformer differ — and two terminals of one
edge may land on the same node.

## One balance, whatever the network contains

Every unit — generator, load, storage, shunt — injects through the same variable
pair, so Kirchhoff's current law at a node is

```math
\sum_{a \in A(i)} c_{a} = \sum_{u \in U(i)} c_{u}
```

and in code

```julia
sum(cr[a] for a in node_arcs(nm, i; nw)) == sum(cru[u] for u in node_units(nm, i; nw))
```

The sign lives in the constraints of the individual unit type, not in the
balance. Adding a unit type therefore never touches this constraint.

## Topology

The incidence of the graph at one network index is a [`Topology`](@ref):

```@docs
Topology
topology
topologies
switchable
```

Only the `status` of a component can change which components are in service, so
which topology a network index has is **derived** from the statuses of the
components whose status varies, never looked up in a table indexed by ``n``. A
problem without contingencies has one topology however many indices it spans.

## Accessors

```@docs
nodes
edges
units
node
ids
arcs
node_arcs
node_units
edge_arcs
terminals
nterminals
is_active
status
component_id
network
dimension
baseMVA
```
