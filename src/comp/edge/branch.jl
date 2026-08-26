################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
# v0.2.0 - network dependent data stored per component                         #
################################################################################

################################################################################
# Branch — data                                                                #
################################################################################

"""
    Branch <: AbstractEdge

A two-terminal edge `(e, i, j)` modelled as a π-equivalent in series with an
ideal transformer on the from side.

# Fields
- `id`: the identifier of the branch.
- `name`: a human readable label.
- `terminals`: `[i, j]`, the from and to node.
- `r`, `x`: the series resistance and reactance [pu].
- `g_fr`, `b_fr`, `g_to`, `b_to`: the shunt admittance at the from and to
  terminal [pu]. A line with total charging susceptance `b` has
  `b_fr = b_to = b/2`.
- `tm`, `ta`: the magnitude [pu] and angle [rad] of the tap ratio
  `T = tm · exp(j·ta)` of the ideal transformer on the from side.
- `rate_a`: the apparent power rating [pu], `Inf` when unlimited.
- `angmin`, `angmax`: the limits on the voltage angle difference [rad].
- `status`: whether the branch is in service.
- `ext`: free-form storage.
- every field but `id`, `name`, `terminals` and `ext` may be given as a
  [`NetworkVector`](@ref) to make it vary over the network index; an outage in a
  contingency is a `status` that does.
"""
Base.@kwdef struct Branch <: AbstractEdge
    id       ::Int
    name     ::String                  = ""
    terminals::Vector{Int}
    r        ::NetworkQuantity{Float64}
    x        ::NetworkQuantity{Float64}
    g_fr     ::NetworkQuantity{Float64} = 0.0
    b_fr     ::NetworkQuantity{Float64} = 0.0
    g_to     ::NetworkQuantity{Float64} = 0.0
    b_to     ::NetworkQuantity{Float64} = 0.0
    tm       ::NetworkQuantity{Float64} = 1.0
    ta       ::NetworkQuantity{Float64} = 0.0
    rate_a   ::NetworkQuantity{Float64} = Inf
    angmin   ::NetworkQuantity{Float64} = -pi / 3
    angmax   ::NetworkQuantity{Float64} =  pi / 3
    status   ::NetworkQuantity{Bool}    = true
    ext      ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function Branch(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to, tm, ta,
                    rate_a, angmin, angmax, status, ext)
        length(terminals) == 2 ||
            throw(ArgumentError("branch $id has $(length(terminals)) terminals, a Branch has exactly two"))
        all_nw(>(0), tm) ||
            throw(ArgumentError("branch $id has a non-positive tap magnitude"))
        all_nw(<=, angmin, angmax) ||
            throw(ArgumentError("branch $id has angmin above angmax"))
        return new(id, name, terminals, r, x, g_fr, b_fr, g_to, b_to, tm, ta,
                   rate_a, angmin, angmax, status, ext)
    end
end

"the real and imaginary part of the tap ratio `T = tm · exp(j·ta)` of a branch resolved at one network index"
tap(b::Branch) = (b.tm * cos(b.ta), b.tm * sin(b.ta))

register_edge_type!(Branch)

################################################################################
# Branch — variables                                                           #
################################################################################

"""
    variable_edge(nm, Branch; nw)

The series current of every in-service branch, `csr` and `csi`, defined on the
from side of the π-equivalent. Together with the shared terminal currents these
close the branch model.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{Branch}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractProblemType,F<:IVRFormulation}
    E = ids(nm, Branch; nw)

    var(nm; nw)[:csr] = JuMP.@variable(nm.model, [e in E], base_name = "$(nw)_csr", start = 0.0)
    var(nm; nw)[:csi] = JuMP.@variable(nm.model, [e in E], base_name = "$(nw)_csi", start = 0.0)

    return nothing
end

################################################################################
# Branch — constraints                                                         #
################################################################################

"""
    constraint_edge(nm, Branch; nw)

The physics of every in-service branch: how the terminal currents split over the
series and shunt admittances of the π-equivalent, and the voltage drop that
links the two terminals.

With `T = tr + j·ti` the tap ratio, `tm = |T|`, `c^s` the series current and
`y^{\\text{sh}}` the terminal shunt admittances, the from terminal `a^{\\text{f}}`
and to terminal `a^{\\text{t}}` of branch `e` satisfy

```math
\\begin{aligned}
c_{a^{\\text{f}}} &= \\left(T \\, c^{\\text{s}}_{e} + y^{\\text{sh}}_{\\text{fr}} v_{i}\\right) / tm^2, \\\\
c_{a^{\\text{t}}} &= -c^{\\text{s}}_{e} + y^{\\text{sh}}_{\\text{to}} v_{j}, \\\\
v_{j} &= \\overline{T} v_{i} / tm^2 - (r + j x) \\, c^{\\text{s}}_{e}.
\\end{aligned}
```
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{Branch}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:IVRFormulation}
    vr,  vi  = var(nm, :vr;  nw), var(nm, :vi;  nw)
    cr,  ci  = var(nm, :cr;  nw), var(nm, :ci;  nw)
    csr, csi = var(nm, :csr; nw), var(nm, :csi; nw)

    con(nm; nw)[:branch_terminal_current] = Dict{Int,Any}()
    con(nm; nw)[:branch_voltage_drop]     = Dict{Int,Any}()

    for e in ids(nm, Branch; nw)
        br = edge(nm, e; nw)::Branch
        a_fr, a_to = edge_arcs(nm, e; nw)
        i, j = a_fr.node, a_to.node
        tr, ti = tap(br)
        tm2 = br.tm^2

        con(nm; nw)[:branch_terminal_current][e] = (
            JuMP.@constraint(nm.model, cr[a_fr] ==
                (tr * csr[e] - ti * csi[e] + br.g_fr * vr[i] - br.b_fr * vi[i]) / tm2),
            JuMP.@constraint(nm.model, ci[a_fr] ==
                (tr * csi[e] + ti * csr[e] + br.g_fr * vi[i] + br.b_fr * vr[i]) / tm2),
            JuMP.@constraint(nm.model, cr[a_to] ==
                -csr[e] + br.g_to * vr[j] - br.b_to * vi[j]),
            JuMP.@constraint(nm.model, ci[a_to] ==
                -csi[e] + br.g_to * vi[j] + br.b_to * vr[j]))

        con(nm; nw)[:branch_voltage_drop][e] = (
            JuMP.@constraint(nm.model, vr[j] ==
                (tr * vr[i] + ti * vi[i]) / tm2 - br.r * csr[e] + br.x * csi[e]),
            JuMP.@constraint(nm.model, vi[j] ==
                (tr * vi[i] - ti * vr[i]) / tm2 - br.r * csi[e] - br.x * csr[e]))
    end

    return nothing
end

"""
    constraint_edge_limits(nm, Branch; nw)

The apparent power rating at every terminal,
`(v^{\\text{r}}_i{}^2 + v^{\\text{i}}_i{}^2)(c^{\\text{r}}_a{}^2 + c^{\\text{i}}_a{}^2) \\le
(s^{\\text{max}}_e)^2`, and the limits on the voltage angle difference across the
branch. Both are skipped where the data leaves them unbounded.
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{Branch}; nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:IVRFormulation}
    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)

    con(nm; nw)[:branch_rating]           = Dict{Int,Any}()
    con(nm; nw)[:branch_angle_difference] = Dict{Int,Any}()

    for e in ids(nm, Branch; nw)
        br = edge(nm, e; nw)::Branch

        if isfinite(br.rate_a)
            con(nm; nw)[:branch_rating][e] = [
                JuMP.@constraint(nm.model,
                    (vr[a.node]^2 + vi[a.node]^2) * (cr[a]^2 + ci[a]^2) <= br.rate_a^2)
                for a in edge_arcs(nm, e; nw)]
        end

        a_fr, a_to = edge_arcs(nm, e; nw)
        i, j = a_fr.node, a_to.node
        if br.angmin > -pi / 2 || br.angmax < pi / 2
            con(nm; nw)[:branch_angle_difference][e] = (
                JuMP.@constraint(nm.model, vi[i] * vr[j] - vr[i] * vi[j] <=
                    tan(br.angmax) * (vr[i] * vr[j] + vi[i] * vi[j])),
                JuMP.@constraint(nm.model, vi[i] * vr[j] - vr[i] * vi[j] >=
                    tan(br.angmin) * (vr[i] * vr[j] + vi[i] * vi[j])))
        end
    end

    return nothing
end
