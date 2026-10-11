################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.1.0 - initial implementation                                              #
# v0.6.0 - the overload of an edge is reported                                 #
# v0.9.4 - registering an edge type is safe from concurrent threads            #
# v0.10.1 - exports its own public names                                       #
# v0.12.6 - the solution builders are cheaper and hold what is asked           #
# v0.13.0 - the fragments a branch and a transformer share are here            #
# v0.13.0 - the linearized rating and angle limit are two constraints          #
# v0.13.0 - the per-terminal data of an edge is normalised here                #
# v0.13.0 - an edge type says whether a table may give a scalar for it         #
# v0.13.0 - a Float64 vector is kept, so a window rebuilds a branch cheaply    #
################################################################################

export register_edge_type!, edge_types
export variable_edge, variable_edge_terminal_current
export variable_edge_terminal_flow, variable_edge_terminal_power
export constraint_edge, constraint_edge_limits, constraint_edge_coupling
export solution_edge, solution_edge!
export susceptance
export constraint_edge_rating!, constraint_edge_angle_difference!
export constraint_linear_flow!, constraint_linear_ratings!, constraint_linear_angle_difference!
export variable_edge_overload!

################################################################################
# Edge — registry                                                              #
################################################################################

const _EDGE_TYPES = DataType[]
const _EDGE_TYPES_LOCK = ReentrantLock()

"""
    register_edge_type!(T)

Record the concrete edge type `T` so that [`variable_edge`](@ref),
[`constraint_edge`](@ref) and [`solution_edge`](@ref) visit it.

A problem definition never names the edge types it supports: it calls the
dispatchers, which walk the registry. An extension package that adds an edge
type — a three-winding transformer, a multi-terminal HVDC converter station —
registers it once and every problem picks it up.
"""
function register_edge_type!(::Type{T}) where {T<:AbstractEdge}
    lock(_EDGE_TYPES_LOCK) do
        T in _EDGE_TYPES || push!(_EDGE_TYPES, T)
    end
    return nothing
end

"the registered concrete edge types"
edge_types() = copy(_EDGE_TYPES)

################################################################################
# Edge — per-terminal data                                                     #
################################################################################

"""
    _per_terminal(x, n, neutral, owner, part, id, field; every = false)

`x` as one entry per terminal of an edge with `n` of them. `owner` and `part` only
name the edge type and what an entry belongs to in a message, `"transformer"` and
`"winding"` or `"branch"` and `"terminal"`.

A vector is taken as it is. A scalar stands for the first entry of an edge with two
terminals, the second being `neutral`, or for every entry where `every` is set,
which is what a rating is. An edge with more terminals gives a vector, or the
neutral scalar.
"""
function _per_terminal(x, n::Int, neutral, owner::String, part::String, id, field::Symbol;
                       every::Bool = false)
    x isa NetworkVector &&
        return NetworkVector([_per_terminal(v, n, neutral, owner, part, id, field; every)
                              for v in x.data])

    if x isa AbstractVector
        length(x) == n ||
            throw(ArgumentError("$owner $id has $n terminals but `$field` has $(length(x)) entries"))
        return x isa Vector{Float64} ? x : Float64.(x)
    end

    every && return fill(Float64(x), n)
    n == 2 && return [Float64(x), Float64(neutral)]
    x == neutral && return fill(Float64(neutral), n)

    throw(ArgumentError("$owner $id has $n terminals, so `$field` takes one entry per " *
                        "terminal; a scalar stands for the first $part of a two-$part " *
                        "$owner only"))
end

"""
    _per_terminal_data(T)

Whether the constructor of the type `T` takes a scalar for a field with an entry per
terminal, through [`_per_terminal`](@ref). A table may then give a scalar cell
where it would otherwise have to give a list.
"""
_per_terminal_data(::Type) = false

################################################################################
# Edge — variables                                                             #
################################################################################

"""
    variable_edge_terminal_current(nm; nw)

The current flowing from a node into an edge terminal, one variable pair per
arc, shared by every edge type.

These are the only edge variables the node balance sees, which is what lets an
edge have any number of terminals: an edge with terminals `(e, i, j, k)` simply
contributes three arcs.
"""
function variable_edge_terminal_current(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                                       ) where {P<:AbstractProblemType,F<:IVRFormulation}
    A = arcs(nm; nw)

    variables!(nm, :cr, A; nw, base_name = "$(nw)_cr")
    variables!(nm, :ci, A; nw, base_name = "$(nw)_ci")

    return nothing
end

"""
    variable_edge_terminal_flow(nm; nw)

The flow variables every edge terminal has, whichever formulation is being
built: currents under a [`IVRFormulation`](@ref), active power under a
[`LPFFormulation`](@ref). A problem builder calls [`variable_edge`](@ref),
which calls this, and so never has to ask which.
"""
function variable_edge_terminal_flow end

variable_edge_terminal_flow(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                           ) where {P<:AbstractProblemType,F<:IVRFormulation} =
    variable_edge_terminal_current(nm; nw)

variable_edge_terminal_flow(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                           ) where {P<:AbstractProblemType,F<:LPFFormulation} =
    variable_edge_terminal_power(nm; nw)

"""
    variable_edge_terminal_power(nm; nw)

The active power flowing from a node into an edge terminal, one variable per
arc, shared by every edge type. The linearized counterpart of
[`variable_edge_terminal_current`](@ref).
"""
function variable_edge_terminal_power(nm::NetworkModel{P,F}; nw::Int = nw_id_default(nm)
                                     ) where {P<:AbstractProblemType,F<:LPFFormulation}
    A = arcs(nm; nw)

    variables!(nm, :p, A; nw, base_name = "$(nw)_p")

    return nothing
end

"""
    variable_edge(nm; nw)
    variable_edge(nm, T; nw)

The edge variables at network index `nw`: the shared terminal currents, followed
by the internal variables of each registered edge type.
"""
function variable_edge(nm::NetworkModel; nw::Int = nw_id_default(nm))
    variable_edge_terminal_flow(nm; nw)
    for T in _EDGE_TYPES
        variable_edge(nm, T; nw)
    end

    return nothing
end

function variable_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P,F,T<:AbstractEdge}
    isempty(ids(nm, T; nw)) && return nothing
    error("no variables are defined for edge type `$T` under formulation `$F`")
end

################################################################################
# Edge — constraints                                                           #
################################################################################

"""
    constraint_edge(nm; nw)
    constraint_edge(nm, T; nw)

The physics of every registered edge type at network index `nw`.
"""
function constraint_edge(nm::NetworkModel; nw::Int = nw_id_default(nm))
    for T in _EDGE_TYPES
        constraint_edge(nm, T; nw)
    end

    return nothing
end

function constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P,F,T<:AbstractEdge}
    isempty(ids(nm, T; nw)) && return nothing
    error("no constraints are defined for edge type `$T` under problem `$P` with formulation `$F`")
end

"""
    constraint_edge_limits(nm; nw)
    constraint_edge_limits(nm, T; nw)

The operating limits of every registered edge type, i.e., the limits that only a
dispatch problem imposes. Defaults to a no-op so that an edge type without
limits needs no method.
"""
function constraint_edge_limits(nm::NetworkModel; nw::Int = nw_id_default(nm))
    for T in _EDGE_TYPES
        constraint_edge_limits(nm, T; nw)
    end

    return nothing
end

constraint_edge_limits(nm::NetworkModel, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {T<:AbstractEdge} = nothing

"""
    constraint_edge_coupling(nm)
    constraint_edge_coupling(nm, T)

The constraints of every registered edge type that tie network indices to one
another. The counterpart of [`constraint_unit_coupling`](@ref); no edge type in
the package needs one yet, and the hook is here so that one can be added without
touching a problem builder.
"""
function constraint_edge_coupling(nm::NetworkModel)
    for T in _EDGE_TYPES
        constraint_edge_coupling(nm, T)
    end

    return nothing
end

constraint_edge_coupling(::NetworkModel, ::Type{T}) where {T<:AbstractEdge} = nothing

################################################################################
# Edge — operating limits                                                      #
################################################################################

"""
    constraint_edge_rating!(nm, e, rate_a; nw)

Bound the apparent power at every terminal of edge `e` by `rate_a`,
`(v^{\\text{r}}_i{}^2 + v^{\\text{i}}_i{}^2)(c^{\\text{r}}_a{}^2 + c^{\\text{i}}_a{}^2) \\le
(s^{\\text{max}}_e)^2`. Written per terminal, it applies to an edge with any
number of them. `rate_a` is one number for every terminal or one per terminal, and
a terminal whose rating is not finite is not bounded.

Skipped where the data leaves every rating unbounded, and where the problem does
not watch the edge for congestion, see [`is_monitored`](@ref).

Where the problem prices congestion rather than forbidding it, see
[`overload_price`](@ref), the bound is relaxed by the overload of the edge,

```math
(v^{\\text{r}}_i{}^2 + v^{\\text{i}}_i{}^2)(c^{\\text{r}}_a{}^2 + c^{\\text{i}}_a{}^2)
\\le (s^{\\text{max}}_e + o_e)^2 ,
```

with one `o_e ≥ 0` shared by every terminal, so the overload is the excess of the
worst of them rather than a separate allowance for each. The constraint stays the
same degree it already was and is written under its own key, since a row whose
set is `≤ (s^{max})^2` cannot be updated in place into one holding a variable.
"""
function constraint_edge_rating!(nm::NetworkModel, e::Int, rate_a::Union{Real,AbstractVector};
                                 nw::Int)
    _any_finite(rate_a) && is_monitored(nm, e) || return nothing

    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)
    price  = overload_price(nm)

    price === nothing &&
        return [constrain!(nm, :edge_rating, (e, t),
                    JuMP.@build_constraint(
                        (vr[a.node]^2 + vi[a.node]^2) * (cr[a]^2 + ci[a]^2) <=
                        _rating_at(rate_a, t)^2); nw)
                for (t, a) in enumerate(edge_arcs(nm, e; nw)) if isfinite(_rating_at(rate_a, t))]

    ol = variable_edge_overload!(nm, e; nw)

    return [constrain!(nm, :edge_overload, (e, t),
                JuMP.@build_constraint(
                    (vr[a.node]^2 + vi[a.node]^2) * (cr[a]^2 + ci[a]^2) <=
                    (_rating_at(rate_a, t) + ol)^2); nw)
            for (t, a) in enumerate(edge_arcs(nm, e; nw)) if isfinite(_rating_at(rate_a, t))]
end

"the rating of terminal `t`, where a rating is one number for every terminal or one per terminal"
_rating_at(rate_a::Real, ::Int) = rate_a
_rating_at(rate_a::AbstractVector, t::Int) = rate_a[t]

"whether any terminal has a rating that bounds anything"
_any_finite(rate_a::Real) = isfinite(rate_a)
_any_finite(rate_a::AbstractVector) = any(isfinite, rate_a)

"""
    variable_edge_overload!(nm, e; nw)

The overload of edge `e` at network index `nw`: how far past its rating the
problem is willing to pay to run it, in per-unit and non-negative.

One variable per monitored edge, in the `:ol` container shared by every edge
type and both formulations. It is apparent power where the formulation has
reactive power and active power where it does not, which is the same thing the
rating means in each.
"""
function variable_edge_overload!(nm::NetworkModel, e::Int; nw::Int)
    variable_container!(nm, :ol; nw)

    return variable!(nm, :ol, e; nw, base_name = "$(nw)_ol[$e]", start = 0.0, lower = 0.0)
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
# Edge — the linearized two-terminal flow                                      #
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

`shift` may be a number or a variable, which is what lets a winding of a
[`Transformer`](@ref) that is a `pst` be a control here.
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
    constraint_linear_ratings!(nm, e, arcs, rate_a; nw)

The rating at each terminal of an edge with any number of them in a linearized
formulation: a bound on the terminal power, since with no reactive power in the
model apparent power is active power. `rate_a` is one number for every terminal
or one per terminal, and a terminal whose rating is not finite has no row.
Skipped where no terminal has a finite rating, and where the problem does not
watch the edge for congestion, see [`is_monitored`](@ref).

```math
-s^{\\text{max}}_{a} \\le p_{a} \\le s^{\\text{max}}_{a} .
```

Where the problem prices congestion rather than forbidding it, see
[`overload_price`](@ref), the rating is relaxed by the overload of the edge and
written as a pair of one-sided rows per terminal,

```math
p_{a} - o_{e} \\le s^{\\text{max}}_{a}, \\qquad -p_{a} - o_{e} \\le s^{\\text{max}}_{a},
```

rather than as one two-sided bound: the bounds of a range constraint are
constants, and `o_e` is not. The pair is what a bound on `|p_a|` becomes once
the allowance is a variable, and it is exact without a binary because the
objective pays for `o_e` and so never lifts it further than one of the two rows
requires.
"""
function constraint_linear_ratings!(nm::NetworkModel, e::Int, arcs,
                                    rate_a::Union{Real,AbstractVector}; nw::Int)
    _any_finite(rate_a) && is_monitored(nm, e) || return nothing

    p     = var(nm, :p; nw)
    price = overload_price(nm)

    price === nothing &&
        return [constrain!(nm, :linear_rating, (e, t),
                           JuMP.@build_constraint(-_rating_at(rate_a, t) <= p[a] <= _rating_at(rate_a, t)); nw)
                for (t, a) in enumerate(arcs) if isfinite(_rating_at(rate_a, t))]

    ol = variable_edge_overload!(nm, e; nw)

    return [(constrain!(nm, :linear_overload, (e, t, :pos),
                        JuMP.@build_constraint(p[a] - ol <= _rating_at(rate_a, t)); nw),
             constrain!(nm, :linear_overload, (e, t, :neg),
                        JuMP.@build_constraint(-p[a] - ol <= _rating_at(rate_a, t)); nw))
            for (t, a) in enumerate(arcs) if isfinite(_rating_at(rate_a, t))]
end

"""
    constraint_linear_angle_difference!(nm, a_fr, a_to, angmin, angmax; nw)

Bound the voltage angle difference across a two-terminal edge in a linearized
formulation, where the limit is already linear,

```math
\\theta^{\\text{min}}_{e} \\le v^{\\text{a}}_{i} - v^{\\text{a}}_{j} \\le \\theta^{\\text{max}}_{e} .
```

Skipped where the data leaves it unbounded. The angle limit is not congestion, so
it holds whether or not the problem watches the edge, see [`is_monitored`](@ref).
"""
function constraint_linear_angle_difference!(nm::NetworkModel, a_fr::Arc, a_to::Arc,
                                             angmin::Real, angmax::Real; nw::Int)
    angmin > -pi / 2 || angmax < pi / 2 || return nothing

    va   = var(nm, :va; nw)
    i, j = a_fr.node, a_to.node

    return constrain!(nm, :linear_angle, a_fr.edge,
                      JuMP.@build_constraint(angmin <= va[i] - va[j] <= angmax); nw)
end

################################################################################
# Edge — solution                                                              #
################################################################################

"""
    solution_edge(nm, nw; only = true)

The edge part of the solution at network index `nw`: for every arc the terminal
current and the active and reactive power flowing from the node into that
terminal.

`only` is `true` for every edge, `false` for none, or the `Set` of the identifiers
of the edges to hold.
"""
function solution_edge(nm::NetworkModel{P,F}, nw::Int; only::Union{Bool,Set{Int}} = true
                      ) where {P<:AbstractProblemType,F<:IVRFormulation}
    sol = Dict{String,Any}()
    only === false && return sol
    sizehint!(sol, _room(length(topology(nm; nw).edge), only))
    for T in _EDGE_TYPES
        es = _asked(ids(nm, T; nw), only)
        isempty(es) && continue

        vrs, vis = var(nm, :vr; nw), var(nm, :vi; nw)
        crs, cis = var(nm, :cr; nw), var(nm, :ci; nw)
        for e in es
            terminals = Dict{String,Any}()
            for a in edge_arcs(nm, e; nw)
                vr = JuMP.value(vrs[a.node])
                vi = JuMP.value(vis[a.node])
                cr = JuMP.value(crs[a])
                ci = JuMP.value(cis[a])

                terminal        = Dict{String,Any}()
                terminal["node"] = a.node
                terminal["cr"]   = cr
                terminal["ci"]   = ci
                terminal["p"]    = vr * cr + vi * ci
                terminal["q"]    = vi * cr - vr * ci
                terminals[string(a.terminal)] = terminal
            end
            entry = Dict{String,Any}("terminal" => terminals)
            _solution_edge_overload!(entry, nm, e, nw)
            solution_edge!(entry, nm, T, e, nw)
            sol[string(e)] = entry
        end
    end

    return sol
end

"""
    _solution_edge_overload!(entry, nm, e, nw)

Record how far past its rating edge `e` was run, where the problem priced that
rather than forbidding it.

Reported for every monitored edge that has a rating, including the ones the
answer left at zero: the overload volume is an output of the problem, and an
edge missing from the result reads as *not asked*, not as *asked and clear*.
"""
function _solution_edge_overload!(entry::Dict{String,Any}, nm::NetworkModel, e::Int, nw::Int)
    haskey(var(nm; nw), :ol) || return nothing
    ol = var(nm, :ol; nw)
    haskey(ol, e) || return nothing

    entry["overload"] = JuMP.value(ol[e])

    return nothing
end

"add the type specific entries of edge `e` to its solution dictionary"
solution_edge!(::Dict{String,Any}, ::NetworkModel, ::Type{T}, ::Int, ::Int) where {T<:AbstractEdge} =
    nothing

"the edge part of the solution under a linearized formulation"
function solution_edge(nm::NetworkModel{P,F}, nw::Int; only::Union{Bool,Set{Int}} = true
                      ) where {P<:AbstractProblemType,F<:LPFFormulation}
    sol = Dict{String,Any}()
    only === false && return sol
    sizehint!(sol, _room(length(topology(nm; nw).edge), only))
    for T in _EDGE_TYPES
        es = _asked(ids(nm, T; nw), only)
        isempty(es) && continue

        ps = var(nm, :p; nw)
        for e in es
            terminals = Dict{String,Any}()
            for a in edge_arcs(nm, e; nw)
                terminal         = Dict{String,Any}()
                terminal["node"] = a.node
                terminal["p"]    = JuMP.value(ps[a])
                terminals[string(a.terminal)] = terminal
            end
            entry = Dict{String,Any}("terminal" => terminals)
            _solution_edge_overload!(entry, nm, e, nw)
            solution_edge!(entry, nm, T, e, nw)
            sol[string(e)] = entry
        end
    end

    return sol
end
