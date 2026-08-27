# Shunt

A shunt is a unit ``(u, i)`` that draws a current proportional to the voltage of
its node — a constant impedance.

```@docs
AbstractShunt
Shunt
```

!!! note "A shunt is not 'reactive power'"
    Constant impedance, not the kind of power exchanged, is what distinguishes a
    shunt. Its admittance ``y^{\text{s}}_{u} = g^{\text{s}}_{u} + j
    b^{\text{s}}_{u}`` has a conductance as well as a susceptance, and that
    conductance draws **active** power in proportion to the square of the voltage
    magnitude. In the language of the ZIP model a shunt is the Z and a
    [`FixedLoad`](@ref) is the P.

## Parameters

| symbol | field | description | unit |
|:-------|:------|:------------|:-----|
| | `id`, `name`, `node` | identifier, label, node | |
| ``g^{\text{s}}_{u}`` | `gs` | shunt conductance | pu |
| ``b^{\text{s}}_{u}`` | `bs` | shunt susceptance | pu |
| | `status` | in service | |

A switched capacitor bank is a `bs` given as a [`NetworkVector`](@ref).

## Variables

### In the `IVRFormulation`

| symbol | key | index | description | unit |
|:-------|:----|:------|:------------|:-----|
| ``c^{\text{r}}_{u}`` | `:cru` | unit | real injected current | pu |
| ``c^{\text{i}}_{u}`` | `:ciu` | unit | imaginary injected current | pu |

## Constraints

The injected current is minus the current the admittance draws,
``c_{u} = -y^{\text{s}}_{u} v_{i}``:

```math
c^{\text{r}}_{u} = -\left(g^{\text{s}}_{u} v^{\text{r}}_{i} - b^{\text{s}}_{u} v^{\text{i}}_{i}\right),
\qquad
c^{\text{i}}_{u} = -\left(g^{\text{s}}_{u} v^{\text{i}}_{i} + b^{\text{s}}_{u} v^{\text{r}}_{i}\right).
```

This is **linear**, where the constant power of a [`FixedLoad`](@ref) is
bilinear in the voltage and the current. Cheap shunts are one of the reasons to
prefer a current based formulation.
