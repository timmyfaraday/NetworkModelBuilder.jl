################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
################################################################################

################################################################################
# The π-equivalent                                                             #
################################################################################

# Every two-terminal edge in the package is a π-equivalent: a series impedance
# `z = r + jx` between two shunt admittances `y = g + jb`. A branch applies it
# directly between its two nodes; a transformer applies it between the secondary
# of its ideal ratio and its to-node. Rather than write the physics twice, both
# call the fragment below, a branch with the voltage and current of its from
# node and a transformer with the voltage and current on the transformer side of
# its ratio.
#
# `csr, csi` is the series current, defined positive from the from side to the
# to side.

"""
    constraint_pi_section!(nm, ctr, cti, vtr, vti, a_to, e, z, y_fr, y_to; nw)

Add the equations of a π-equivalent whose from side sees the current
`ctr + j·cti` at the voltage `vtr + j·vti`, and whose to side is the arc `a_to`.

`ctr`, `cti`, `vtr` and `vti` may be variables or expressions, which is what lets
a transformer hand in the quantities behind its ideal ratio.

```math
\\begin{aligned}
c^{\\text{t}} &= y^{\\text{sh}}_{\\text{fr}} v^{\\text{t}} + c^{\\text{s}}, \\\\
c_{a^{\\text{t}}} &= -c^{\\text{s}} + y^{\\text{sh}}_{\\text{to}} v_{j}, \\\\
v^{\\text{t}} - v_{j} &= z \\, c^{\\text{s}}.
\\end{aligned}
```
"""
function constraint_pi_section!(nm::NetworkModel, ctr, cti, vtr, vti, a_to::Arc, e::Int,
                                z::Tuple{<:Real,<:Real},
                                y_fr::Tuple{<:Real,<:Real},
                                y_to::Tuple{<:Real,<:Real}; nw::Int)
    r, x         = z
    g_fr, b_fr   = y_fr
    g_to, b_to   = y_to
    j            = a_to.node

    vr, vi   = var(nm, :vr;  nw), var(nm, :vi;  nw)
    cr, ci   = var(nm, :cr;  nw), var(nm, :ci;  nw)
    csr, csi = var(nm, :csr; nw), var(nm, :csi; nw)

    return (
        constrain!(nm, :pi_section, (e, :cr_fr),
                   JuMP.@build_constraint(ctr == g_fr * vtr - b_fr * vti + csr[e]); nw),
        constrain!(nm, :pi_section, (e, :ci_fr),
                   JuMP.@build_constraint(cti == g_fr * vti + b_fr * vtr + csi[e]); nw),
        constrain!(nm, :pi_section, (e, :cr_to),
                   JuMP.@build_constraint(cr[a_to] == -csr[e] + g_to * vr[j] - b_to * vi[j]); nw),
        constrain!(nm, :pi_section, (e, :ci_to),
                   JuMP.@build_constraint(ci[a_to] == -csi[e] + g_to * vi[j] + b_to * vr[j]); nw),
        constrain!(nm, :pi_section, (e, :vr),
                   JuMP.@build_constraint(vtr - vr[j] == r * csr[e] - x * csi[e]); nw),
        constrain!(nm, :pi_section, (e, :vi),
                   JuMP.@build_constraint(vti - vi[j] == r * csi[e] + x * csr[e]); nw),
    )
end

"""
    variable_edge_series_current(nm, T; nw)

The series current of every in-service edge of type `T`, added to the `:csr` and
`:csi` containers shared by every edge type that has one.

The container is a `Dict` rather than a JuMP array because several edge types
contribute to it: the dispatcher visits one concrete type at a time, and each
adds its own edges to the same two containers.
"""
function variable_edge_series_current(nm::NetworkModel, ::Type{T}; nw::Int) where {T<:AbstractEdge}
    variable_container!(nm, :csr, :csi; nw)

    for e in ids(nm, T; nw)
        variable!(nm, :csr, e; nw, base_name = "$(nw)_csr[$e]", start = 0.0)
        variable!(nm, :csi, e; nw, base_name = "$(nw)_csi[$e]", start = 0.0)
    end

    return nothing
end

"""
    constraint_edge_rating!(nm, e, rate_a; nw)

Bound the apparent power at every terminal of edge `e` by `rate_a`,
`(v^{\\text{r}}_i{}^2 + v^{\\text{i}}_i{}^2)(c^{\\text{r}}_a{}^2 + c^{\\text{i}}_a{}^2) \\le
(s^{\\text{max}}_e)^2`. Written per terminal, it applies to an edge with any
number of them.

Skipped where the data leaves the rating unbounded, and where the problem does
not watch the edge for congestion, see [`is_monitored`](@ref).
"""
function constraint_edge_rating!(nm::NetworkModel, e::Int, rate_a::Real; nw::Int)
    isfinite(rate_a) && is_monitored(nm, e) || return nothing

    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)

    return [constrain!(nm, :edge_rating, (e, t),
                JuMP.@build_constraint(
                    (vr[a.node]^2 + vi[a.node]^2) * (cr[a]^2 + ci[a]^2) <= rate_a^2); nw)
            for (t, a) in enumerate(edge_arcs(nm, e; nw))]
end

"""
    constraint_edge_angle_difference!(nm, a_fr, a_to, angmin, angmax; nw)

Bound the voltage angle difference across a two-terminal edge. Skipped where the
data leaves it unbounded.
"""
function constraint_edge_angle_difference!(nm::NetworkModel, a_fr::Arc, a_to::Arc,
                                           angmin::Real, angmax::Real; nw::Int)
    angmin > -pi / 2 || angmax < pi / 2 || return nothing

    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)
    i, j   = a_fr.node, a_to.node

    return (
        constrain!(nm, :edge_angle, (a_fr.edge, :max),
            JuMP.@build_constraint(vi[i] * vr[j] - vr[i] * vi[j] <=
                tan(angmax) * (vr[i] * vr[j] + vi[i] * vi[j])); nw),
        constrain!(nm, :edge_angle, (a_fr.edge, :min),
            JuMP.@build_constraint(vi[i] * vr[j] - vr[i] * vi[j] >=
                tan(angmin) * (vr[i] * vr[j] + vi[i] * vi[j])); nw),
    )
end

################################################################################
# The linearized two-terminal flow                                             #
################################################################################

"""
    susceptance(r, x)

The series susceptance of an impedance `z = r + jx`, i.e., the imaginary part of
`1/z`:

```math
b = \\frac{-x}{r^2 + x^2} .
```

The resistance is kept. Dropping it as well, `b = -1/x`, is the other common
convention and gives Matpower's DC model; the three approximations this package
makes — unit voltage magnitude, no reactive power, small angles — do not require
it.
"""
susceptance(r::Real, x::Real) = -x / (r^2 + x^2)

"""
    constraint_linear_flow!(nm, e, a_fr, a_to, b, shift; nw)

Add the linearized flow of a two-terminal edge,

```math
p_{a^{\\text{f}}} = -b_{e} \\left(v^{\\text{a}}_{i} - v^{\\text{a}}_{j} - ta_{e}\\right),
\\qquad
p_{a^{\\text{t}}} = -p_{a^{\\text{f}}} ,
```

where `shift` is the phase shift the edge applies, zero for a branch. The second
equation is what makes the model lossless: whatever leaves one terminal arrives
at the other.

`shift` may be a number or a variable, which is what lets a
[`PhaseShifter`](@ref) be a control here.
"""
function constraint_linear_flow!(nm::NetworkModel, e::Int, a_fr::Arc, a_to::Arc,
                                 b::Real, shift; nw::Int)
    va = var(nm, :va; nw)
    p  = var(nm, :p;  nw)
    i, j = a_fr.node, a_to.node

    return (
        constrain!(nm, :linear_flow, (e, :from),
                   JuMP.@build_constraint(p[a_fr] == -b * (va[i] - va[j] - shift)); nw),
        constrain!(nm, :linear_flow, (e, :to),
                   JuMP.@build_constraint(p[a_to] == -p[a_fr]); nw),
    )
end

"""
    constraint_linear_limits!(nm, e, a_fr, a_to, rate_a, angmin, angmax; nw)

The operating limits of a two-terminal edge in a linearized formulation: the
rating becomes a bound on the terminal power, and the angle difference limit is
already linear. The rating is skipped where the problem does not watch the edge
for congestion, see [`is_monitored`](@ref); the angle limit is not congestion and
always holds.

```math
-s^{\\text{max}}_{e} \\le p_{a} \\le s^{\\text{max}}_{e},
\\qquad
\\theta^{\\text{min}}_{e} \\le v^{\\text{a}}_{i} - v^{\\text{a}}_{j} \\le \\theta^{\\text{max}}_{e} .
```

With no reactive power in the model, apparent power is active power, so the
rating applies to it directly.
"""
function constraint_linear_limits!(nm::NetworkModel, e::Int, a_fr::Arc, a_to::Arc,
                                   rate_a::Real, angmin::Real, angmax::Real; nw::Int)
    va = var(nm, :va; nw)
    p  = var(nm, :p;  nw)
    i, j = a_fr.node, a_to.node

    rating = isfinite(rate_a) && is_monitored(nm, e) ?
        [constrain!(nm, :linear_rating, (e, t),
                    JuMP.@build_constraint(-rate_a <= p[a] <= rate_a); nw)
         for (t, a) in enumerate((a_fr, a_to))] : nothing
    angle = (angmin > -pi / 2 || angmax < pi / 2) ?
        constrain!(nm, :linear_angle, e,
                   JuMP.@build_constraint(angmin <= va[i] - va[j] <= angmax); nw) : nothing

    return (rating, angle)
end
