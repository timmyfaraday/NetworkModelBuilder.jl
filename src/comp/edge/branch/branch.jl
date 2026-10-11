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
# v0.13.0 - one Branch: a cable and an overhead line are its l_km         #
# v0.13.0 - the pi-section and the series current of a branch are here         #
# v0.13.0 - a branch is limited by its ratings and its angle limit, apart      #
# v0.13.0 - a branch has one entry per terminal, and two or more terminals     #
# v0.13.0 - checking plain data allocates nothing                              #
# v0.14.0 - a variable is named by the model, not at the call site             #
# v0.14.0 - variable and solution keys follow the nomenclature                 #
# v0.14.0 - the fields follow the nomenclature                                 #
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
`g_shnt`, `b_shnt`, `s_max`, `v_angl_min`, `v_angl_max`, `l_km`, `status` and `ext`.
Every field but `id`, `name`, `terminals`, `l_km` and `ext` may be a
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
an overhead line is: they differ in `l_km` and in a rating that may follow
the weather, not in the equations. Where the edge has a turns ratio it is a
[`Transformer`](@ref), not a branch.

# Fields
Every field with an entry per terminal is indexed by terminal position, and entry
`k` belongs to the section that starts at terminal `k`.
- `id`, `name`: the identifier and a human readable label.
- `terminals`: the nodes the sections start at, two or more.
- `r`, `x`: the series resistance and reactance of each section [pu].
- `g_shnt`, `b_shnt`: the shunt admittance of each section [pu], half of it at each
  end of the section. A line with total charging susceptance `b` has `b_shnt = b`.
  On a [`Transformer`](@ref) the same names are the shunt at the terminal side of
  a winding.
- `s_max`: the apparent power rating at each terminal [pu], `Inf` when unlimited.
- `v_angl_min`, `v_angl_max`: the limits on the voltage angle difference between the two
  terminals of a branch with two [rad]. A branch with more has none.
- `l_km`: the route length [km], `NaN` where it is not known.
- `status`: whether the branch is in service.
- `ext`: free-form storage.

Two terminals are one section: a scalar stands for the first entry of `r`, `x`,
`g_shnt` and `b_shnt`, whose second entry is 0 and has to be, and a scalar `s_max`
for every terminal. With more terminals each of them is a vector, but `s_max`,
which may still be one number.

A branch is refused when an entry of `r`, `x`, `g_shnt` or `b_shnt` is not finite,
when a section has no impedance, `r` and `x` both 0, when `s_max` is negative or
NaN, when its angle limits are out of order, or when its `l_km` is negative
or infinite. A bus coupler has no impedance to give: it is a [`Switch`](@ref).
"""
Base.@kwdef struct Branch <: AbstractBranch
    id        ::Int
    name      ::String                           = ""
    terminals ::Vector{Int}
    r         ::NetworkQuantity{Vector{Float64}}
    x         ::NetworkQuantity{Vector{Float64}}
    g_shnt    ::NetworkQuantity{Vector{Float64}} = 0.0
    b_shnt    ::NetworkQuantity{Vector{Float64}} = 0.0
    s_max     ::NetworkQuantity{Vector{Float64}} = Inf
    v_angl_min::NetworkQuantity{Float64}         = -pi / 3
    v_angl_max::NetworkQuantity{Float64}         =  pi / 3
    l_km      ::Float64                          = NaN
    status    ::NetworkQuantity{Bool}            = true
    ext       ::Dict{Symbol,Any}                 = Dict{Symbol,Any}()

    function Branch(id, name, terminals, r, x, g_shnt, b_shnt, s_max, v_angl_min, v_angl_max,
                    l_km, status, ext)
        n = length(terminals)
        n >= 2 ||
            throw(ArgumentError("branch $id has $n terminals, a branch has at least two"))

        r      = _per_terminal(r,      n, 0.0, "branch", "terminal", id, :r)
        x      = _per_terminal(x,      n, 0.0, "branch", "terminal", id, :x)
        g_shnt = _per_terminal(g_shnt, n, 0.0, "branch", "terminal", id, :g_shnt)
        b_shnt = _per_terminal(b_shnt, n, 0.0, "branch", "terminal", id, :b_shnt)
        s_max  = _per_terminal(s_max,  n, Inf, "branch", "terminal", id, :s_max; every = true)

        _check_branch(id, n, r, x, g_shnt, b_shnt, s_max, v_angl_min, v_angl_max)
        _check_length(id, l_km)
        return new(id, name, terminals, r, x, g_shnt, b_shnt, s_max, v_angl_min, v_angl_max,
                   l_km, status, ext)
    end
end

_per_terminal_data(::Type{Branch}) = true

function _check_branch(id, n, r::Vector{Float64}, x::Vector{Float64}, g_shnt::Vector{Float64},
                       b_shnt::Vector{Float64}, s_max::Vector{Float64}, v_angl_min::Real,
                       v_angl_max::Real)
    # two terminals are one section, and a second one is what a third terminal is for
    n > 2 || (iszero(r[2]) && iszero(x[2]) && iszero(g_shnt[2]) && iszero(b_shnt[2])) ||
        throw(ArgumentError("branch $id has two terminals, which are one section: the second " *
                            "entry of `r`, `x`, `g_shnt` and `b_shnt` is 0, and a branch whose " *
                            "second section carries something has three terminals"))
    all(isfinite, r) && all(isfinite, x) ||
        throw(ArgumentError("branch $id has an impedance that is not finite"))
    all(k -> r[k]^2 + x[k]^2 > 0, 1:(n == 2 ? 1 : n)) ||
        throw(ArgumentError("branch $id has a section with no impedance, r and x are both 0: " *
                            "a bus coupler is a Switch"))
    all(isfinite, g_shnt) && all(isfinite, b_shnt) ||
        throw(ArgumentError("branch $id has a shunt admittance that is not finite"))
    all(>=(0), s_max) ||
        throw(ArgumentError("branch $id has a rating that is negative or NaN"))
    v_angl_min <= v_angl_max ||
        throw(ArgumentError("branch $id has v_angl_min above v_angl_max"))

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
function _check_length(id, l_km)
    isnan(l_km) || (isfinite(l_km) && l_km >= 0) ||
        throw(ArgumentError("branch $id has a length that is negative or infinite"))

    return nothing
end

register_edge_type!(Branch)

"""
    structure_gates(br)

A branch writes its rating only where `s_max` is finite and its angle limits
only where they fall inside `(-π/2, π/2)`, so those three decide the shape of
its model rather than a number in it. See [`structure_gates`](@ref).
"""
structure_gates(::AbstractBranch) = (:s_max, :v_angl_min, :v_angl_max)

"the series impedance of every section of a branch, resolved at one network index"
impedance(br::AbstractBranch) = (br.r, br.x)

"the shunt admittance of every section of a branch, resolved at one network index"
shunt_admittance(br::AbstractBranch) = (br.g_shnt, br.b_shnt)

"""
    dynamic_rating(br)

The rating of a branch at one network index. Give `s_max` a
[`NetworkVector`](@ref) over the `:time` dimension and the thermal limit of the
branch becomes a profile, a rating that follows the ambient conditions, without
any change to the constraint that enforces it.
"""
dynamic_rating(br::AbstractBranch) = br.s_max

"whether branch `e` has two terminals, which is one π-section between them"
_is_pi(nm::NetworkModel, e::Int) = nterminals(edges(network(nm))[e]) == 2

################################################################################
# Branch — variables                                                           #
################################################################################

"""
    variable_edge_series_current(nm, E; nw)
    variable_edge_series_current(nm, T; nw)

The series current of every edge in `E`, or of every in-service edge of type `T`,
added to the `:i_ser_real` and `:i_ser_imag` containers shared by every edge type that has one.

The container is a `Dict` rather than a JuMP array because several edge types
contribute to it: the dispatcher visits one concrete type at a time, and each
adds its own edges to the same two containers.
"""
function variable_edge_series_current(nm::NetworkModel, E; nw::Int)
    variable_container!(nm, :i_ser_real, :i_ser_imag; nw)

    for e in E
        variable!(nm, :i_ser_real, e; nw, start = 0.0)
        variable!(nm, :i_ser_imag, e; nw, start = 0.0)
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
        variable!(nm, :v_pnt_real, e; nw, start = 1.0)
        variable!(nm, :v_pnt_imag, e; nw, start = 0.0)
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

    v_real, v_imag           = var(nm, :v_real;      nw), var(nm, :v_imag;      nw)
    i_term_real, i_term_imag = var(nm, :i_term_real; nw), var(nm, :i_term_imag; nw)
    i_ser_real, i_ser_imag   = var(nm, :i_ser_real;  nw), var(nm, :i_ser_imag;  nw)

    return (
        constrain!(nm, :pi_section, (e, :cr_fr),
                   JuMP.@build_constraint(ctr == g_fr * vtr - b_fr * vti + i_ser_real[e]); nw),
        constrain!(nm, :pi_section, (e, :ci_fr),
                   JuMP.@build_constraint(cti == g_fr * vti + b_fr * vtr + i_ser_imag[e]); nw),
        constrain!(nm, :pi_section, (e, :cr_to),
                   JuMP.@build_constraint(i_term_real[a_to] == -i_ser_real[e] + g_to * v_real[j] - b_to * v_imag[j]); nw),
        constrain!(nm, :pi_section, (e, :ci_to),
                   JuMP.@build_constraint(i_term_imag[a_to] == -i_ser_imag[e] + g_to * v_imag[j] + b_to * v_real[j]); nw),
        constrain!(nm, :pi_section, (e, :v_real),
                   JuMP.@build_constraint(vtr - v_real[j] == r * i_ser_real[e] - x * i_ser_imag[e]); nw),
        constrain!(nm, :pi_section, (e, :v_imag),
                   JuMP.@build_constraint(vti - v_imag[j] == r * i_ser_imag[e] + x * i_ser_real[e]); nw),
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
    v_real, v_imag           = var(nm, :v_real;      nw), var(nm, :v_imag;      nw)
    i_term_real, i_term_imag = var(nm, :i_term_real; nw), var(nm, :i_term_imag; nw)

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
        y          = (br.g_shnt[1] / 2, br.b_shnt[1] / 2)

        branch[e] = constraint_pi_section!(nm, i_term_real[a_fr], i_term_imag[a_fr], v_real[i], v_imag[i],
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
    v_real, v_imag           = var(nm, :v_real;        nw), var(nm, :v_imag;        nw)
    i_term_real, i_term_imag = var(nm, :i_term_real;   nw), var(nm, :i_term_imag;   nw)
    v_pnt_real, v_pnt_imag   = var(nm, :v_pnt_real, e; nw), var(nm, :v_pnt_imag, e; nw)

    csr = Any[]
    csi = Any[]

    sections = map(enumerate(A)) do (k, a)
        i    = a.node
        g, b = br.g_shnt[k] / 2, br.b_shnt[k] / 2

        if iszero(g) && iszero(b)
            push!(csr, i_term_real[a])
            push!(csi, i_term_imag[a])
        else
            push!(csr, JuMP.@expression(nm.model, i_term_real[a] - (g * v_real[i] - b * v_imag[i])))
            push!(csi, JuMP.@expression(nm.model, i_term_imag[a] - (g * v_imag[i] + b * v_real[i])))
        end

        (constrain!(nm, :branch_section, (a, :real), JuMP.@build_constraint(
             v_real[i] - v_pnt_real == br.r[k] * csr[k] - br.x[k] * csi[k]); nw),
         constrain!(nm, :branch_section, (a, :imag), JuMP.@build_constraint(
             v_imag[i] - v_pnt_imag == br.r[k] * csi[k] + br.x[k] * csr[k]); nw))
    end

    g, b  = sum(br.g_shnt) / 2, sum(br.b_shnt) / 2
    point = (constrain!(nm, :branch_point, (e, :real), JuMP.@build_constraint(
                 sum(csr) == g * v_pnt_real - b * v_pnt_imag); nw),
             constrain!(nm, :branch_point, (e, :imag), JuMP.@build_constraint(
                 sum(csi) == g * v_pnt_imag + b * v_pnt_real); nw))

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

        rating[e] = constraint_edge_rating!(nm, e, br.s_max; nw)
        length(A) == 2 &&
            (angle[e] = constraint_edge_angle_difference!(nm, A[1], A[2], br.v_angl_min, br.v_angl_max; nw))
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
        variable!(nm, :v_pnt_angl, e; nw, start = 0.0)
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
            v_angl, p_term, v_pnt_angl = var(nm, :v_angl; nw), var(nm, :p_term; nw), var(nm, :v_pnt_angl, e; nw)

            sections = map(enumerate(A)) do (k, a)
                constrain!(nm, :branch_section, a, JuMP.@build_constraint(p_term[a] ==
                    -susceptance(br.r[k], br.x[k]) * (v_angl[a.node] - v_pnt_angl)); nw)
            end
            point = constrain!(nm, :branch_point, e,
                               JuMP.@build_constraint(sum(p_term[a] for a in A) == 0.0); nw)

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
            (constraint_linear_ratings!(nm, e, A, br.s_max; nw),
             constraint_linear_angle_difference!(nm, A[1], A[2], br.v_angl_min, br.v_angl_max; nw)) :
            constraint_linear_ratings!(nm, e, A, br.s_max; nw)
    end

    return nothing
end
