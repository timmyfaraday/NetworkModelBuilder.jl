# The hierarchy

Every component of a power system is a node, an edge or a unit. Within those
three families the types form a hierarchy, and where a type sits in it is a
statement about the *model*, not a label: a type earns its place by changing
which variables exist, which constraints are written, or which data the
component carries.

```
AbstractComponent
│
├── AbstractNode
│   └── Node                          an AC busbar
│
├── AbstractEdge
│   ├── AbstractBranch                transports power, no transformation
│   │   ├── Branch                    of unspecified construction
│   │   ├── Cable
│   │   └── OverheadLine
│   ├── AbstractTransformer           transforms power between its terminals
│   │   ├── AbstractTwoWindingTransformer
│   │   │   ├── Transformer           fixed turns ratio
│   │   │   ├── PhaseShifter          the ratio angle is a control
│   │   │   └── TapChanger            the ratio magnitude is a control
│   │   └── MultiWindingTransformer   three or more terminals, star equivalent
│   └── AbstractDCLink                the flow is chosen, not determined
│       └── DCLink                    two terminals, lossy, decoupling
│
└── AbstractUnit
    ├── AbstractGenerator
    │   └── Generator                 injection bounded by a capability
    ├── AbstractLoad
    │   ├── FixedLoad                 the demand is data
    │   └── FlexibleLoad              the demand is a decision in an envelope
    ├── AbstractStorage
    │   └── Storage                   what it does now depends on what it did
    └── AbstractShunt
        └── Shunt                     constant impedance
```

## What each level is for

**The three families** are structural. A node has a voltage, an edge connects an
ordered list of nodes and carries a flow at each terminal, a unit hangs off one
node and injects into it. Nothing else in the package needs to know more than
that: [`constraint_node_balance`](@ref) sums the arcs incident to a node against
the units connected to it without knowing what kinds of either exist.

**The abstract middle** is where an implementation lives. Every
[`AbstractBranch`](@ref) shares one π-equivalent, written once and dispatched on
the abstract type; every [`AbstractTwoWindingTransformer`](@ref) shares one ideal
ratio plus π-equivalent. A concrete type inherits that implementation and
overrides only what genuinely differs.

**The concrete leaves** are what a network is built from, and what
[`ids`](@ref) addresses.

## Where a type earns its place

Not every distinction an engineer draws is a distinction a model draws. The
package is explicit about which is which.

| distinction | changes the model? | why the type exists |
|:------------|:-------------------|:--------------------|
| [`Cable`](@ref) vs [`OverheadLine`](@ref) | **no** — the same π-equivalent | to address one kind, and to carry the data that does differ |
| [`Branch`](@ref) vs [`Transformer`](@ref) | **yes** — the turns ratio and the voltage behind it | a branch transports, a transformer transforms |
| [`Transformer`](@ref) vs [`TapChanger`](@ref) | **yes** — the ratio becomes a variable in a dispatch problem | a tap that the optimizer sets is a different model from one it does not |
| [`FixedLoad`](@ref) vs [`FlexibleLoad`](@ref) | **yes** — the demand becomes a variable, and constraints span network indices | who chooses the demand |
| [`FixedLoad`](@ref) vs [`Shunt`](@ref) | **yes** — constant power against constant impedance | one is bilinear in the voltage, the other linear |
| [`Branch`](@ref) vs [`DCLink`](@ref) | **yes** — the flow stops being a function of the angles and becomes a decision | one transports what the physics send it, the other what it is told |

Cable and overhead line are the honest case: in a steady-state model they are the
same equations, and the documentation says so rather than implying a difference
that is not there. They pay for themselves as soon as a rating follows the
weather or a planning problem costs a route.

## How a component reaches a model

A concrete type registers itself once, at the bottom of its own file:

```julia
register_edge_type!(Cable)
register_unit_type!(Storage)
```

A problem builder never names a component type. It calls the dispatchers —
[`variable_edge`](@ref), [`constraint_edge`](@ref), [`constraint_unit`](@ref),
[`constraint_unit_coupling`](@ref) — and those walk the registries. Adding a
component therefore touches one file and no problem definition.

Where a component type is present in the data but no method exists for the
problem and formulation asked for, the model is not built: the error names the
type and the pair, rather than quietly leaving the component out.

## One file per component

The code of a component — its data structure, its variables and its constraints
— lives in a single file, and the files follow the hierarchy:

```
src/comp/
├── node/node.jl
├── edge/
│   ├── edge.jl                     the registry, terminal currents, dispatchers
│   ├── pi_model.jl                 the π-equivalent, shared by branch and transformer
│   ├── branch/{branch,cable,overhead_line}.jl
│   └── transformer/{transformer,phase_shifter,tap_changer,multi_winding}.jl
└── unit/
    ├── unit.jl                     the registry, injection currents, dispatchers
    ├── generator/generator.jl
    ├── load/{load,fixed_load,flexible_load}.jl
    ├── storage/storage.jl
    └── shunt/shunt.jl
```

There is deliberately no `form/` directory. A formulation is a set of methods
spread over these files, not a place of its own: keeping everything about a
transformer together is worth more than keeping everything about IVR together.
