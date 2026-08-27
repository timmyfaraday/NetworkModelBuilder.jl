# Extending the package

## A new component

Write one file holding the struct, its variables and its constraints, put it
under `src/comp/` where the hierarchy says it belongs, and register it:

```julia
Base.@kwdef struct WindGenerator <: AbstractGenerator
    id  ::Int
    node::Int
    # ...
end

register_unit_type!(WindGenerator)
```

Because the dispatchers walk the registries, no problem definition changes. If
the new type shares an implementation with its siblings — as [`Cable`](@ref)
does with [`Branch`](@ref) — it inherits the methods written on the abstract
parent and needs none of its own.

```@docs
register_edge_type!
register_unit_type!
edge_types
unit_types
```

### If it couples network indices

Constraints that span network indices cannot be written from inside the loop
over them. Put them in a [`constraint_unit_coupling`](@ref) or
[`constraint_edge_coupling`](@ref) method, which every problem builder calls once
after that loop, and guard them with [`require_time_dimension`](@ref).

### If it has more than two terminals

Give it as many `terminals` as it needs and let the internal points be *edge
variables*, as [`MultiWindingTransformer`](@ref) does with its star point. Do
not invent nodes: an implicit internal point keeps ``I`` a set of real busbars,
needs no synthetic identifier, and does not grow the topology.

## A new formulation

Add the tag to `src/core/types.jl` and write one method per component file
dispatching on it. Nothing outside the component files moves.

```julia
abstract type ACPFormulation <: AbstractPowerFormulation end

function variable_node_voltage(nm::NetworkModel{P,F}; nw = nw_id_default(nm)
                              ) where {P<:AbstractProblemType,F<:ACPFormulation}
    # vm, va instead of vr, vi
end
```

## A new problem

Add the tag, a [`build_model!`](@ref) method in `src/prob/`, an
[`objective`](@ref) method, and a [`register_model!`](@ref) call. Where the new
problem changes how a component behaves — different bounds, an extra variable —
add a method in that component's own file dispatching on the new problem type.

`src/prob/rd.jl` sketches this for a redispatch problem.

## Shared model fragments

Physics that several components share lives in a fragment rather than being
written twice:

- [`constraint_pi_section!`](@ref) — the π-equivalent, used by every branch and
  every two-winding transformer;
- [`constraint_unit_power!`](@ref) — the injection of a unit against its current,
  used by every generator, load and storage unit;
- [`constraint_edge_rating!`](@ref) and
  [`constraint_edge_angle_difference!`](@ref) — the operating limits of an edge.

```@docs
constraint_unit_power!
```

## Dispatchers

```@docs
variable_edge
constraint_edge
constraint_edge_limits
constraint_edge_coupling
variable_unit
constraint_unit
variable_edge_terminal_current
variable_unit_injection_current
solution_node
solution_edge
solution_unit
solution_edge!
solution_unit!
```
