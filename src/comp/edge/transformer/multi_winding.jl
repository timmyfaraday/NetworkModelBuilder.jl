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
# MultiWindingTransformer — data                                               #
################################################################################

"""
    MultiWindingTransformer <: AbstractTransformer

A transformer with three or more windings, modelled as a star of series
impedances meeting at a common point.

This is the component that answers the question a multi-terminal edge raises:
where does the star point live? It does **not** become a node. It has no
identifier in `I`, no balance of its own among the node constraints, and it never
appears in `ids(net, Node)` or in the node part of a solution. It is a pair of
variables, `vsr[e]` and `vsi[e]`, belonging to the edge, and the current balance
at it is one of the edge's own constraints.

Making it implicit costs one thing: nothing can be hung off the star point from
outside, because it is not a node a unit can name. The magnetising branch, which
is what one usually wants there, is therefore part of this component — `g_m` and
`b_m` below. In exchange the node set stays a set of real busbars, no synthetic
identifier has to be invented and kept from colliding, and the topology does not
grow.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `terminals`: the nodes the windings connect to, three or more.
- `r`, `x`: the series resistance and reactance of each winding [pu], one entry
  per terminal, referred to the star point.
- `tm`, `ta`: the magnitude [pu] and angle [rad] of the turns ratio of each
  winding, one entry per terminal.
- `g_m`, `b_m`: the magnetising admittance at the star point [pu].
- `rate_a`: the apparent power rating of each terminal [pu], one entry per
  terminal, `Inf` where unlimited.
- `status`: whether the transformer is in service.
- `ext`: free-form storage.

The per-winding vectors are indexed by terminal position, not by network index;
to make one of them vary over the network index, wrap it in a
[`NetworkVector`](@ref) of vectors.
"""
Base.@kwdef struct MultiWindingTransformer <: AbstractTransformer
    id       ::Int
    name     ::String                           = ""
    terminals::Vector{Int}
    r        ::NetworkQuantity{Vector{Float64}}
    x        ::NetworkQuantity{Vector{Float64}}
    tm       ::NetworkQuantity{Vector{Float64}} = Float64[]
    ta       ::NetworkQuantity{Vector{Float64}} = Float64[]
    g_m      ::NetworkQuantity{Float64}         = 0.0
    b_m      ::NetworkQuantity{Float64}         = 0.0
    rate_a   ::NetworkQuantity{Vector{Float64}} = Float64[]
    status   ::NetworkQuantity{Bool}            = true
    ext      ::Dict{Symbol,Any}                 = Dict{Symbol,Any}()

    function MultiWindingTransformer(id, name, terminals, r, x, tm, ta, g_m, b_m,
                                     rate_a, status, ext)
        n = length(terminals)
        n >= 3 ||
            throw(ArgumentError("multi-winding transformer $id has $n terminals, use a Transformer for two"))
        tm = _fill_winding(tm, n, 1.0)
        ta = _fill_winding(ta, n, 0.0)
        rate_a = _fill_winding(rate_a, n, Inf)
        for (field, v) in ((:r, r), (:x, x), (:tm, tm), (:ta, ta), (:rate_a, rate_a))
            all_nw(w -> length(w) == n, v) ||
                throw(ArgumentError("multi-winding transformer $id has $n terminals but `$field` has a different number of entries"))
        end
        all_nw(w -> all(>(0), w), tm) ||
            throw(ArgumentError("multi-winding transformer $id has a non-positive tap magnitude"))
        return new(id, name, terminals, r, x, tm, ta, g_m, b_m, rate_a, status, ext)
    end
end

"default a per-winding vector that was left empty"
_fill_winding(v::Vector{Float64}, n::Int, default::Float64) = isempty(v) ? fill(default, n) : v
_fill_winding(v::NetworkVector, ::Int, ::Float64) = v

register_edge_type!(MultiWindingTransformer)

################################################################################
# MultiWindingTransformer — variables                                          #
################################################################################

"""
    variable_edge(nm, MultiWindingTransformer; nw)

The complex voltage of the star point of every in-service multi-winding
transformer, `vsr` and `vsi`.

These are the only variables the component needs: the current of each winding is
the current of its own terminal, referred through that winding's ratio, so there
is no separate series current to carry.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{MultiWindingTransformer};
                       nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractProblemType,F<:IVRFormulation}
    vsr = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :vsr)
    vsi = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :vsi)

    for e in ids(nm, MultiWindingTransformer; nw)
        vsr[e] = JuMP.@variable(nm.model, base_name = "$(nw)_vsr[$e]", start = 1.0)
        vsi[e] = JuMP.@variable(nm.model, base_name = "$(nw)_vsi[$e]", start = 0.0)
    end

    return nothing
end

################################################################################
# MultiWindingTransformer — constraints                                        #
################################################################################

"""
    constraint_edge(nm, MultiWindingTransformer; nw)

The physics of every in-service multi-winding transformer: the drop from each
winding to the star point, and the current balance at the star point.

For winding `k` at node `i_k`, with ratio `T_k` and impedance `z_k`, write the
voltage and current referred through the ratio as

```math
v^{\\text{t}}_{k} = v_{i_k} / T_{k}, \\qquad c^{\\text{t}}_{k} = \\overline{T_{k}} \\, c_{a_k},
```

after which the star is simply

```math
v^{\\text{t}}_{k} - v^{\\text{s}}_{e} = z_{k} \\, c^{\\text{t}}_{k}
\\quad \\text{for every } k,
\\qquad
\\sum_{k} c^{\\text{t}}_{k} = y^{\\text{m}}_{e} \\, v^{\\text{s}}_{e}.
```

With unit ratios and no magnetising branch this is a plain star of impedances,
and gives the same node voltages as the same star written with a real node in
the middle and one branch per winding.
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{MultiWindingTransformer};
                         nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:IVRFormulation}
    vr,  vi  = var(nm, :vr;  nw), var(nm, :vi;  nw)
    cr,  ci  = var(nm, :cr;  nw), var(nm, :ci;  nw)
    vsr, vsi = var(nm, :vsr; nw), var(nm, :vsi; nw)

    winding = get!(() -> Dict{Int,Any}(), con(nm; nw), :winding)
    star    = get!(() -> Dict{Int,Any}(), con(nm; nw), :star_balance)

    for e in ids(nm, MultiWindingTransformer; nw)
        tf  = edge(nm, e; nw)::MultiWindingTransformer
        A   = edge_arcs(nm, e; nw)
        ctr = Any[]
        cti = Any[]

        winding[e] = map(enumerate(A)) do (k, a)
            i        = a.node
            trk, tik = tf.tm[k] * cos(tf.ta[k]), tf.tm[k] * sin(tf.ta[k])
            tmk2     = tf.tm[k]^2

            # the voltage and the current of terminal k referred through its ratio
            vtr = JuMP.@expression(nm.model, (trk * vr[i] + tik * vi[i]) / tmk2)
            vti = JuMP.@expression(nm.model, (trk * vi[i] - tik * vr[i]) / tmk2)
            push!(ctr, JuMP.@expression(nm.model, trk * cr[a] + tik * ci[a]))
            push!(cti, JuMP.@expression(nm.model, trk * ci[a] - tik * cr[a]))

            (JuMP.@constraint(nm.model,
                 vtr - vsr[e] == tf.r[k] * ctr[k] - tf.x[k] * cti[k]),
             JuMP.@constraint(nm.model,
                 vti - vsi[e] == tf.r[k] * cti[k] + tf.x[k] * ctr[k]))
        end

        star[e] = (
            JuMP.@constraint(nm.model,
                sum(ctr) == tf.g_m * vsr[e] - tf.b_m * vsi[e]),
            JuMP.@constraint(nm.model,
                sum(cti) == tf.g_m * vsi[e] + tf.b_m * vsr[e]))
    end

    return nothing
end

"""
    constraint_edge_limits(nm, MultiWindingTransformer; nw)

The apparent power rating of every winding, applied per terminal, and only where
the problem watches the transformer for congestion, see [`is_monitored`](@ref).
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{MultiWindingTransformer};
                                nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:IVRFormulation}
    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)
    rating = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_rating)

    for e in ids(nm, MultiWindingTransformer; nw)
        is_monitored(nm, e) || continue
        tf = edge(nm, e; nw)::MultiWindingTransformer
        rating[e] = [JuMP.@constraint(nm.model,
                         (vr[a.node]^2 + vi[a.node]^2) * (cr[a]^2 + ci[a]^2) <= tf.rate_a[k]^2)
                     for (k, a) in enumerate(edge_arcs(nm, e; nw)) if isfinite(tf.rate_a[k])]
    end

    return nothing
end

################################################################################
# MultiWindingTransformer — the linearized formulation                         #
################################################################################

"""
    variable_edge(nm, MultiWindingTransformer; nw)

The angle of the star point of every in-service multi-winding transformer.

The star point stays implicit here exactly as it does in the current based
formulation: one variable belonging to the edge, and no node.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{MultiWindingTransformer};
                       nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractProblemType,F<:LPFFormulation}
    vas = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), :vas)

    for e in ids(nm, MultiWindingTransformer; nw)
        vas[e] = JuMP.@variable(nm.model, base_name = "$(nw)_vas[$e]", start = 0.0)
    end

    return nothing
end

"""
    constraint_edge(nm, MultiWindingTransformer; nw)

The linearized flow of every winding into the star point, and the balance there,

```math
p_{a_k} = -b_{e,k} \\left(v^{\\text{a}}_{i_k} - ta_{e,k} - v^{\\text{as}}_{e}\\right)
\\quad \\text{for every } k,
\\qquad
\\sum_{k} p_{a_k} = 0 .
```

The magnetising branch plays no part, for the same reason a branch's shunt does
not.
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{MultiWindingTransformer};
                         nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:LPFFormulation}
    va, p, vas = var(nm, :va; nw), var(nm, :p; nw), var(nm, :vas; nw)

    winding = get!(() -> Dict{Int,Any}(), con(nm; nw), :winding)
    star    = get!(() -> Dict{Int,Any}(), con(nm; nw), :star_balance)

    for e in ids(nm, MultiWindingTransformer; nw)
        tf = edge(nm, e; nw)::MultiWindingTransformer
        A  = edge_arcs(nm, e; nw)

        winding[e] = map(enumerate(A)) do (k, a)
            JuMP.@constraint(nm.model, p[a] ==
                -susceptance(tf.r[k], tf.x[k]) * (va[a.node] - tf.ta[k] - vas[e]))
        end
        star[e] = JuMP.@constraint(nm.model, sum(p[a] for a in A) == 0.0)
    end

    return nothing
end

"""
    constraint_edge_limits(nm, MultiWindingTransformer; nw)

The rating of every winding, applied per terminal, and only where the problem
watches the transformer for congestion, see [`is_monitored`](@ref).
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{MultiWindingTransformer};
                                nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:LPFFormulation}
    p      = var(nm, :p; nw)
    limits = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_limits)

    for e in ids(nm, MultiWindingTransformer; nw)
        is_monitored(nm, e) || continue
        tf = edge(nm, e; nw)::MultiWindingTransformer
        limits[e] = [JuMP.@constraint(nm.model, -tf.rate_a[k] <= p[a] <= tf.rate_a[k])
                     for (k, a) in enumerate(edge_arcs(nm, e; nw)) if isfinite(tf.rate_a[k])]
    end

    return nothing
end
