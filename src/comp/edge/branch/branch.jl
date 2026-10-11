################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.3.0 - component hierarchy                                                 #
# v0.10.1 - exports its own public names                                       #
# v0.12.8 - a branch refuses an impedance or a rating no model can use         #
# v0.13.0 - one Branch: a cable and an overhead line are its length_km         #
# v0.13.0 - the pi-section and the series current of a branch are here         #
# v0.13.0 - a branch is limited by its ratings and its angle limit, apart      #
# v0.13.0 - a branch has one entry per terminal, and two or more terminals     #
# v0.13.0 - checking plain data allocates nothing                              #
# v0.14.0 - a variable is named by the model, not at the call site             #
################################################################################

export AbstractBranch, Branch, impedance, shunt_admittance, dynamic_rating
export constraint_pi_section!, variable_edge_series_current

################################################################################
# Branch — data                                                                #
################################################################################

"""
    AbstractBranch <: AbstractEdge

An edge that transports electrical power between its terminals without
transforming it: a π-equivalent between two of them, and one π-section from each
terminal to a common point where there are more.

Every branch type shares the same equations. A cable and an overhead line are not
types of their own: in a steady-state model both are a series impedance between
two shunt admittances, so each is a [`Branch`](@ref) with its own data.

A concrete branch carries `id`, `name`, `terminals` (two or more), `r`, `x`,
`g_sh`, `b_sh`, `rate_a`, `angmin`, `angmax`, `length_km`, `status` and `ext`.
Every field but `id`, `name`, `terminals`, `length_km` and `ext` may be a
[`NetworkVector`](@ref).
"""
abstract type AbstractBranch <: AbstractEdge end

"""
    Branch <: AbstractBranch

An edge of two or more terminals, modelled as π-sections.

With two terminals it is the π-equivalent `(e, i, j)`: a series impedance between
two shunt admittances. With more it is one π-section from each terminal to a
common point, the shunts at the point aggregated, as a line with a tee is. The
point is not a node: it has no identifier and appears in neither `ids(net, Node)`
nor the node part of a solution, it is a pair of variables belonging to the edge.

This is what a Matpower branch without a turns ratio becomes, and what a cable or
an overhead line is: they differ in `length_km` and in a rating that may follow
the weather, not in the equations. Where the edge has a turns ratio it is a
[`Transformer`](@ref), not a branch.

# Fields
Every field with an entry per terminal is indexed by terminal position, and entry
`k` belongs to the section that starts at terminal `k`.
- `id`, `name`: the identifier and a human readable label.
- `terminals`: the nodes the sections start at, two or more.
- `r`, `x`: the series resistance and reactance of each section [pu].
- `g_sh`, `b_sh`: the shunt admittance of each section [pu], half of it at each
  end of the section. A line with total charging susceptance `b` has `b_sh = b`.
  On a [`Transformer`](@ref) the same names are the shunt at the terminal side of
  a winding.
- `rate_a`: the apparent power rating at each terminal [pu], `Inf` when unlimited.
- `angmin`, `angmax`: the limits on the voltage angle difference between the two
  terminals of a branch with two [rad]. A branch with more has none.
- `length_km`: the route length [km], `NaN` where it is not known.
- `status`: whether the branch is in service.
- `ext`: free-form storage.

Two terminals are one section: a scalar stands for the first entry of `r`, `x`,
`g_sh` and `b_sh`, whose second entry is 0 and has to be, and a scalar `rate_a`
for every terminal. With more terminals each of them is a vector, but `rate_a`,
which may still be one number.

A branch is refused when an entry of `r`, `x`, `g_sh` or `b_sh` is not finite,
when a section has no impedance, `r` and `x` both 0, when `rate_a` is negative or
NaN, when its angle limits are out of order, or when its `length_km` is negative
or infinite. A bus coupler has no impedance to give: it is a [`Switch`](@ref).
"""
Base.@kwdef struct Branch <: AbstractBranch
    id       ::Int
    name     ::String                             = ""
    terminals::Vector{Int}
    r        ::NetworkQuantity{Vector{Float64}}
    x        ::NetworkQuantity{Vector{Float64}}
    g_sh     ::NetworkQuantity{Vector{Float64}}   = 0.0
    b_sh     ::NetworkQuantity{Vector{Float64}}   = 0.0
    rate_a   ::NetworkQuantity{Vector{Float64}}   = Inf
    angmin   ::NetworkQuantity{Float64}           = -pi / 3
    angmax   ::NetworkQuantity{Float64}           =  pi / 3
    length_km::Float64                            = NaN
    status   ::NetworkQuantity{Bool}              = true
    ext      ::Dict{Symbol,Any}                   = Dict{Symbol,Any}()

    function Branch(id, name, terminals, r, x, g_sh, b_sh, rate_a, angmin, angmax,
                    length_km, status, ext)
        n = length(terminals)
        n >= 2 ||
            throw(ArgumentError("branch $id has $n terminals, a branch has at least two"))

        r      = _per_terminal(r,      n, 0.0, "branch", "terminal", id, :r)
        x      = _per_terminal(x,      n, 0.0, "branch", "terminal", id, :x)
        g_sh   = _per_terminal(g_sh,   n, 0.0, "branch", "terminal", id, :g_sh)
        b_sh   = _per_terminal(b_sh,   n, 0.0, "branch", "terminal", id, :b_sh)
        rate_a = _per_terminal(rate_a, n, Inf, "branch", "terminal", id, :rate_a; every = true)

        _check_branch(id, n, r, x, g_sh, b_sh, rate_a, angmin, angmax)
        _check_length(id, length_km)
        return new(id, name, terminals, r, x, g_sh, b_sh, rate_a, angmin, angmax,
                   length_km, status, ext)
    end
end

_per_terminal_data(::Type{Branch}) = true

function _check_branch(id, n, r::Vector{Float64}, x::Vector{Float64}, g_sh::Vector{Float64},
                       b_sh::Vector{Float64}, rate_a::Vector{Float64}, angmin::Real,
                       angmax::Real)
    # two terminals are one section, and a second one is what a third terminal is for
    n > 2 || (iszero(r[2]) && iszero(x[2]) && iszero(g_sh[2]) && iszero(b_sh[2])) ||
        throw(ArgumentError("branch $id has two terminals, which are one section: the second " *
                            "entry of `r`, `x`, `g_sh` and `b_sh` is 0, and a branch whose " *
                            "second section carries something has three terminals"))
    all(isfinite, r) && all(isfinite, x) ||
        throw(ArgumentError("branch $id has an impedance that is not finite"))
    all(k -> r[k]^2 + x[k]^2 > 0, 1:(n == 2 ? 1 : n)) ||
        throw(ArgumentError("branch $id has a section with no impedance, r and x are both 0: " *
                            "a bus coupler is a Switch"))
    all(isfinite, g_sh) && all(isfinite, b_sh) ||
        throw(ArgumentError("branch $id has a shunt admittance that is not finite"))
    all(>=(0), rate_a) ||
        throw(ArgumentError("branch $id has a rating that is negative or NaN"))
    angmin <= angmax ||
        throw(ArgumentError("branch $id has angmin above angmax"))

    return nothing
end

"the checks of a branch some of whose data varies, made at every network index"
function _check_branch(id, n, data...)
    all_nw((a...) -> true, data...)

    for k in 1:maximum(length(d.data) for d in data if d isa NetworkVector)
        _check_branch(id, n, map(d -> d isa NetworkVector ? d.data[k] : d, data)...)
    end

    return nothing
end

"refuse a route length that is negative or infinite; NaN says it is not known"
function _check_length(id, length_km)
    isnan(length_km) || (isfinite(length_km) && length_km >= 0) ||
        throw(ArgumentError("branch $id has a length that is negative or infinite"))

    return nothing
end

register_edge_type!(Branch)

"""
    structure_gates(br)

A branch writes its rating only where `rate_a` is finite and its angle limits
only where they fall inside `(-π/2, π/2)`, so those three decide the shape of
its model rather than a number in it. See [`structure_gates`](@ref).
"""
structure_gates(::AbstractBranch) = (:rate_a, :angmin, :angmax)

"the series impedance of every section of a branch, resolved at one network index"
impedance(br::AbstractBranch) = (br.r, br.x)

"the shunt admittance of every section of a branch, resolved at one network index"
shunt_admittance(br::AbstractBranch) = (br.g_sh, br.b_sh)

"""
    dynamic_rating(br)

The rating of a branch at one network index. Give `rate_a` a
[`NetworkVector`](@ref) over the `:time` dimension and the thermal limit of the
branch becomes a profile, a rating that follows the ambient conditions, without
any change to the constraint that enforces it.
"""
dynamic_rating(br::AbstractBranch) = br.rate_a

"whether branch `e` has two terminals, which is one π-section between them"
_is_pi(nm::NetworkModel, e::Int) = nterminals(edges(network(nm))[e]) == 2

################################################################################
# Branch — variables                                                           #
################################################################################

"""
    variable_edge_series_current(nm, E; nw)
    variable_edge_series_current(nm, T; nw)

The series current of every edge in `E`, or of every in-service edge of type `T`,
added to the `:csr` and `:csi` containers shared by every edge type that has one.

The container is a `Dict` rather than a JuMP array because several edge types
contribute to it: the dispatcher visits one concrete type at a time, and each
adds its own edges to the same two containers.
"""
function variable_edge_series_current(nm::NetworkModel, E; nw::Int)
    variable_container!(nm, :csr, :csi; nw)

    for e in E
        variable!(nm, :csr, e; nw, start = 0.0)
        variable!(nm, :csi, e; nw, start = 0.0)
    end

    return nothing
end

variable_edge_series_current(nm::NetworkModel, ::Type{T}; nw::Int) where {T<:AbstractEdge} =
    variable_edge_series_current(nm, ids(nm, T; nw); nw)

"""
    variable_edge(nm, T; nw)

The series current of every in-service branch with two terminals, `csr` and `csi`,
and the voltage of the point of every one with more, `vpr` and `vpi`. Together
with the terminal currents shared by every edge type these close the branch model.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractProblemType,F<:IVRFormulation,T<:AbstractBranch}
    E = ids(nm, T; nw)
    variable_edge_series_current(nm, filter(e -> _is_pi(nm, e), E); nw)

    for e in E
        _is_pi(nm, e) && continue
        variable!(nm, :vpr, e; nw, start = 1.0)
        variable!(nm, :vpi, e; nw, start = 0.0)
    end

    return nothing
end

################################################################################
# Branch — constraints                                                         #
################################################################################

# A branch is a π-equivalent: a series impedance `z = r + jx` between two shunt
# admittances `y = g + jb`. `csr, csi` is the series current, defined positive
# from the from side to the to side.

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
    constraint_edge(nm, T; nw)

The physics of every in-service branch: how the terminal currents split over the
series and shunt admittances of the π-equivalent, and the voltage drop that
links the two terminals.

```math
\\begin{aligned}
c_{a^{\\text{f}}} &= y^{\\text{sh}}_{\\text{fr}} v_{i} + c^{\\text{s}}_{e}, \\\\
c_{a^{\\text{t}}} &= -c^{\\text{s}}_{e} + y^{\\text{sh}}_{\\text{to}} v_{j}, \\\\
v_{i} - v_{j} &= (r + j x) \\, c^{\\text{s}}_{e}.
\\end{aligned}
```

A branch with more terminals has the same three equations for every section `k`,
with the voltage `v^{\\text{p}}_{e}` of its point where the section above has its
to node, and the series currents balance there against the aggregated shunt,

```math
\\sum_{k} c^{\\text{s}}_{k} = \\tfrac{1}{2} \\Big( \\sum_{k} y^{\\text{sh}}_{k} \\Big) v^{\\text{p}}_{e},
\\qquad
c^{\\text{s}}_{k} = c_{a_k} - \\tfrac{1}{2} y^{\\text{sh}}_{k} v_{i_k}.
```
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:IVRFormulation,T<:AbstractBranch}
    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)

    branch = get!(() -> Dict{Int,Any}(), con(nm; nw), :branch)

    for e in ids(nm, T; nw)
        br = edge(nm, e; nw)::T
        A  = edge_arcs(nm, e; nw)

        if length(A) > 2
            branch[e] = _constraint_sections!(nm, br, e, A; nw)
            continue
        end

        a_fr, a_to = A
        i          = a_fr.node
        y          = (br.g_sh[1] / 2, br.b_sh[1] / 2)

        branch[e] = constraint_pi_section!(nm, cr[a_fr], ci[a_fr], vr[i], vi[i],
                                           a_to, e, (br.r[1], br.x[1]), y, y; nw)
    end

    return nothing
end

"""
    _constraint_sections!(nm, br, e, A; nw)

The rows of a branch with more than two terminals in the current based
formulation: for each section the drop from its terminal to the point, with the
current through the section read off the terminal current less the half of the
section's shunt at the terminal, and the balance of the sections at the point.
"""
function _constraint_sections!(nm::NetworkModel, br::AbstractBranch, e::Int, A; nw::Int)
    vr, vi   = var(nm, :vr; nw), var(nm, :vi; nw)
    cr, ci   = var(nm, :cr; nw), var(nm, :ci; nw)
    vpr, vpi = var(nm, :vpr, e; nw), var(nm, :vpi, e; nw)

    csr = Any[]
    csi = Any[]

    sections = map(enumerate(A)) do (k, a)
        i    = a.node
        g, b = br.g_sh[k] / 2, br.b_sh[k] / 2

        if iszero(g) && iszero(b)
            push!(csr, cr[a])
            push!(csi, ci[a])
        else
            push!(csr, JuMP.@expression(nm.model, cr[a] - (g * vr[i] - b * vi[i])))
            push!(csi, JuMP.@expression(nm.model, ci[a] - (g * vi[i] + b * vr[i])))
        end

        (constrain!(nm, :branch_section, (a, :real), JuMP.@build_constraint(
             vr[i] - vpr == br.r[k] * csr[k] - br.x[k] * csi[k]); nw),
         constrain!(nm, :branch_section, (a, :imag), JuMP.@build_constraint(
             vi[i] - vpi == br.r[k] * csi[k] + br.x[k] * csr[k]); nw))
    end

    g, b  = sum(br.g_sh) / 2, sum(br.b_sh) / 2
    point = (constrain!(nm, :branch_point, (e, :real), JuMP.@build_constraint(
                 sum(csr) == g * vpr - b * vpi); nw),
             constrain!(nm, :branch_point, (e, :imag), JuMP.@build_constraint(
                 sum(csi) == g * vpi + b * vpr); nw))

    return (sections, point)
end

"""
    constraint_edge_limits(nm, T; nw)

The apparent power rating at every terminal of a branch and the limits on the
voltage angle difference across it. Only a dispatch problem imposes them.
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:IVRFormulation,T<:AbstractBranch}
    rating = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_rating)
    angle  = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_angle_difference)

    for e in ids(nm, T; nw)
        br = edge(nm, e; nw)::T
        A  = edge_arcs(nm, e; nw)

        rating[e] = constraint_edge_rating!(nm, e, br.rate_a; nw)
        length(A) == 2 &&
            (angle[e] = constraint_edge_angle_difference!(nm, A[1], A[2], br.angmin, br.angmax; nw))
    end

    return nothing
end

################################################################################
# Branch — the linearized formulation                                          #
################################################################################

"""
    variable_edge(nm, T; nw)

A branch with two terminals needs no variables of its own under a
[`LPFFormulation`](@ref): its flow is the terminal power every edge already has,
and there is no series current left to carry once the model is lossless. One with
more has the angle of its point, `vap`.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractProblemType,F<:LPFFormulation,T<:AbstractBranch}
    for e in ids(nm, T; nw)
        _is_pi(nm, e) && continue
        variable!(nm, :vap, e; nw, start = 0.0)
    end

    return nothing
end

"""
    constraint_edge(nm, T; nw)

The linearized flow of every in-service branch,

```math
p_{a^{\\text{f}}} = -b_{e} \\left(v^{\\text{a}}_{i} - v^{\\text{a}}_{j}\\right),
\\qquad
p_{a^{\\text{t}}} = -p_{a^{\\text{f}}} ,
```

with `b_e` the series susceptance, see [`susceptance`](@ref). The shunt
admittance of the branch plays no part: its susceptance is reactive, and its
conductance would draw a constant power that the same three approximations
discard along with the rest of the loss.

A branch with more terminals is one section for each, `k` flowing into the point
with its own susceptance `b_k` and the flows balancing there,

```math
p_{a_k} = -b_{k} \\left(v^{\\text{a}}_{i_k} - v^{\\text{a}}_{e}\\right),
\\qquad
\\sum_{k} p_{a_k} = 0 ,
```

with `v^a_e` the angle of the point.
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:LPFFormulation,T<:AbstractBranch}
    branch = get!(() -> Dict{Int,Any}(), con(nm; nw), :branch)

    for e in ids(nm, T; nw)
        br = edge(nm, e; nw)::T
        A  = edge_arcs(nm, e; nw)

        if length(A) > 2
            va, p, vap = var(nm, :va; nw), var(nm, :p; nw), var(nm, :vap, e; nw)

            sections = map(enumerate(A)) do (k, a)
                constrain!(nm, :branch_section, a, JuMP.@build_constraint(p[a] ==
                    -susceptance(br.r[k], br.x[k]) * (va[a.node] - vap)); nw)
            end
            point = constrain!(nm, :branch_point, e,
                               JuMP.@build_constraint(sum(p[a] for a in A) == 0.0); nw)

            branch[e] = (sections, point)
            continue
        end

        branch[e] = constraint_linear_flow!(nm, e, A[1], A[2],
                                            susceptance(sum(br.r), sum(br.x)), 0.0; nw)
    end

    return nothing
end

"""
    constraint_edge_limits(nm, T; nw)

The rating at every terminal and the angle difference limit of every in-service
branch, see [`constraint_linear_ratings!`](@ref) and
[`constraint_linear_angle_difference!`](@ref).
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,T<:AbstractBranch}
    limits = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_limits)

    for e in ids(nm, T; nw)
        br = edge(nm, e; nw)::T
        A  = edge_arcs(nm, e; nw)

        limits[e] = length(A) == 2 ?
            (constraint_linear_ratings!(nm, e, A, br.rate_a; nw),
             constraint_linear_angle_difference!(nm, A[1], A[2], br.angmin, br.angmax; nw)) :
            constraint_linear_ratings!(nm, e, A, br.rate_a; nw)
    end

    return nothing
end
