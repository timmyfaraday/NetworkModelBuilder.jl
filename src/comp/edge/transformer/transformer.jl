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
# v0.12.0 - one transformer, with windings, a tap changer and a phase shifter  #
# v0.12.0 - a winding can be a tap changer and a phase shifter at once         #
# v0.12.0 - a transformer held at the base case writes no tap rows again       #
# v0.12.0 - a winding can step through the positions of a range                #
################################################################################

export AbstractTransformer, Transformer, TapMode, FIXED, CONTINUOUS, STEPPED
export tap_ratio, phase_shift

################################################################################
# Transformer — data                                                           #
################################################################################

"""
    AbstractTransformer <: AbstractEdge

An edge that transforms electrical power between its nodes, i.e., an edge with a
turns ratio at each terminal. [`Transformer`](@ref) is the one concrete type; the
abstract type is where an extension that adds a transformer of its own hangs.
"""
abstract type AbstractTransformer <: AbstractEdge end

"""
    TapMode

Whether the ratio of a winding can be moved, and how: `FIXED` holds it at the
setpoint the data gives, `CONTINUOUS` lets a dispatch problem choose it between
two limits, and `STEPPED` lets it choose one of a list of positions.

A `Bool` is accepted where a `TapMode` is: `false` is `FIXED` and `true` is
`CONTINUOUS`.
"""
@enum TapMode FIXED CONTINUOUS STEPPED

"""
    Transformer <: AbstractTransformer

A transformer with two or more windings, as a T-model: every winding has an ideal
ratio at its terminal and a series impedance, and the windings meet at a star
point that carries the magnetising branch.

The star point is not a node. It has no identifier in `I`, no balance among the
node constraints, and appears in neither `ids(net, Node)` nor the node part of a
solution; it is a pair of variables belonging to the edge. The magnetising branch
is therefore part of this component, since nothing outside it could be hung from
the star point.

A π-equivalent, which is what a Matpower branch with a ratio is, is the same
model with no magnetising branch, the impedance on the first winding and a shunt
on each: the star point then lies on the series path, and where the impedance is
split between the windings does not matter.

The ratio of a winding is `T = tm · exp(j·ta)`. Whether it is data or a decision
is a property of the winding: `oltc` says whether the magnitude `tm` can be moved,
as an on-load tap changer does, and `pst` whether the angle `ta` can, as a phase
shifter does. A dispatch problem chooses a ratio that can move, between its
limits; a power flow, which chooses nothing, holds it at the setpoint.

# Fields
Every field with an entry per winding is indexed by terminal position.
- `id`, `name`: the identifier and a human readable label.
- `terminals`: the nodes the windings connect to, two or more.
- `r`, `x`: the series resistance and reactance of each winding [pu], referred to
  the star point.
- `g_sh`, `b_sh`: the shunt admittance behind each ratio [pu], zero by default.
- `g_m`, `b_m`: the magnetising admittance at the star point [pu].
- `tm`, `ta`: the magnitude [pu] and the angle [rad] of the ratio of each
  winding, or the setpoint of it where it can move.
- `oltc`, `pst`: per winding, a [`TapMode`](@ref) or a `Bool`, `FIXED` by default.
- `tm_min`, `tm_max`: the limits of the magnitude where `oltc` is `CONTINUOUS`,
  `0.9` and `1.1` by default.
- `ta_min`, `ta_max`: the limits of the angle where `pst` is `CONTINUOUS`, `±π/12`
  by default.
- `tm_step`, `ta_step`: the distance between the positions of a winding that is
  `STEPPED`, which run from `tm_min` to `tm_max` and from `ta_min` to `ta_max`;
  `0.0125` and one degree by default.
- `rate_a`: the apparent power rating at each terminal [pu], `Inf` when unlimited.
- `angmin`, `angmax`: the limits on the voltage angle difference between the two
  terminals of a two-winding transformer [rad]. A transformer with more windings
  has none.
- `status`: whether the transformer is in service.
- `ext`: free-form storage.

A transformer with two windings accepts a scalar where a field takes an entry per
winding: it stands for the first winding, and the second is neutral — a ratio of
one, no shift, no impedance, no shunt — except for `rate_a`, which applies to
both terminals. With more windings every such field is a vector.

A winding that is both `oltc` and `pst` moves its magnitude and its angle at once,
which in the current based formulation puts the ratio in a ring between `tm_min`
and `tm_max`, cut to the angles between `ta_min` and `ta_max`.

A `STEPPED` winding takes one of the positions of its range, a binary variable for
each, which makes a dispatch problem mixed-integer: there are no duals, and in the
current based formulation it is nonconvex as well, so it needs a solver for that.
The setpoint has to be one of the positions, and the limits and the step of a
stepped winding cannot vary over the network index. In the current based
formulation a winding steps its magnitude, its angle or both, over every pair, the
other part of the ratio being its setpoint; in the linearized one only the angle
exists, so only `pst` steps and `oltc` is inert as it is when continuous. A winding
that steps one of the two and moves the other continuously is not built.

# Examples
```julia
julia> Transformer(; id = 1, terminals = [2, 7], r = 0.001, x = 0.1, tm = 1.05)

julia> Transformer(; id = 2, terminals = [3, 4], r = 0.0, x = 0.1, pst = true,
                     ta_min = -0.3, ta_max = 0.3)

julia> Transformer(; id = 3, terminals = [1, 5, 6], r = [0.01, 0.02, 0.03],
                     x = [0.1, 0.2, 0.3], g_m = 0.001, b_m = -0.01)
```
"""
Base.@kwdef struct Transformer <: AbstractTransformer
    id       ::Int
    name     ::String                              = ""
    terminals::Vector{Int}
    r        ::NetworkQuantity{Vector{Float64}}
    x        ::NetworkQuantity{Vector{Float64}}
    g_sh     ::NetworkQuantity{Vector{Float64}}    = 0.0
    b_sh     ::NetworkQuantity{Vector{Float64}}    = 0.0
    g_m      ::NetworkQuantity{Float64}            = 0.0
    b_m      ::NetworkQuantity{Float64}            = 0.0
    tm       ::NetworkQuantity{Vector{Float64}}    = 1.0
    ta       ::NetworkQuantity{Vector{Float64}}    = 0.0
    oltc     ::Vector{TapMode}                     = FIXED
    pst      ::Vector{TapMode}                     = FIXED
    tm_min   ::NetworkQuantity{Vector{Float64}}    = 0.9
    tm_max   ::NetworkQuantity{Vector{Float64}}    = 1.1
    ta_min   ::NetworkQuantity{Vector{Float64}}    = -pi / 12
    ta_max   ::NetworkQuantity{Vector{Float64}}    =  pi / 12
    tm_step  ::NetworkQuantity{Vector{Float64}}    = 0.0125
    ta_step  ::NetworkQuantity{Vector{Float64}}    = pi / 180
    rate_a   ::NetworkQuantity{Vector{Float64}}    = Inf
    angmin   ::NetworkQuantity{Float64}            = -pi / 3
    angmax   ::NetworkQuantity{Float64}            =  pi / 3
    status   ::NetworkQuantity{Bool}               = true
    ext      ::Dict{Symbol,Any}                    = Dict{Symbol,Any}()

    function Transformer(id, name, terminals, r, x, g_sh, b_sh, g_m, b_m, tm, ta, oltc, pst,
                         tm_min, tm_max, ta_min, ta_max, tm_step, ta_step, rate_a, angmin,
                         angmax, status, ext)
        n = length(terminals)
        n >= 2 ||
            throw(ArgumentError("transformer $id has $n terminals, a transformer has at least two"))

        r      = _per_winding(r,      n, 0.0,      id, :r)
        x      = _per_winding(x,      n, 0.0,      id, :x)
        g_sh   = _per_winding(g_sh,   n, 0.0,      id, :g_sh)
        b_sh   = _per_winding(b_sh,   n, 0.0,      id, :b_sh)
        tm     = _per_winding(tm,     n, 1.0,      id, :tm)
        ta     = _per_winding(ta,     n, 0.0,      id, :ta)
        tm_min = _per_winding(tm_min, n, 0.9,      id, :tm_min)
        tm_max = _per_winding(tm_max, n, 1.1,      id, :tm_max)
        ta_min = _per_winding(ta_min, n, -pi / 12, id, :ta_min)
        ta_max = _per_winding(ta_max, n,  pi / 12, id, :ta_max)
        tm_step = _per_winding(tm_step, n, 0.0125,   id, :tm_step)
        ta_step = _per_winding(ta_step, n, pi / 180, id, :ta_step)
        rate_a = _per_winding(rate_a, n, Inf,      id, :rate_a; every = true)
        oltc   = _tap_modes(oltc, n, id, :oltc)
        pst    = _tap_modes(pst,  n, id, :pst)

        _check_transformer(id, tm, ta, tm_min, tm_max, ta_min, ta_max, tm_step, ta_step,
                           oltc, pst, angmin, angmax)

        return new(id, name, terminals, r, x, g_sh, b_sh, g_m, b_m, tm, ta, oltc, pst,
                   tm_min, tm_max, ta_min, ta_max, tm_step, ta_step, rate_a, angmin, angmax,
                   status, ext)
    end
end

"""
    _per_winding(x, n, neutral, id, field; every = false)

`x` as one entry per winding of a transformer with `n` of them. A vector is taken
as it is; a scalar stands for the first winding of a two-winding transformer, the
second being `neutral`, or for every winding where `every` is set, which is what a
rating is. A transformer with more windings gives a vector, or the neutral scalar.
"""
function _per_winding(x, n::Int, neutral, id, field::Symbol; every::Bool = false)
    x isa NetworkVector &&
        return NetworkVector([_per_winding(v, n, neutral, id, field; every) for v in x.data])

    if x isa AbstractVector
        length(x) == n ||
            throw(ArgumentError("transformer $id has $n terminals but `$field` has $(length(x)) entries"))
        return Float64.(x)
    end

    every && return fill(Float64(x), n)
    n == 2 && return [Float64(x), Float64(neutral)]
    x == neutral && return fill(Float64(neutral), n)

    throw(ArgumentError("transformer $id has $n terminals, so `$field` takes one entry per " *
                        "terminal; a scalar stands for the first winding of a two-winding " *
                        "transformer only"))
end

"a `Bool` or a `TapMode` as a `TapMode`"
_tap_mode(m::TapMode) = m
_tap_mode(b::Bool) = b ? CONTINUOUS : FIXED

"`x` as one `TapMode` per winding, a scalar standing for the first winding of two"
function _tap_modes(x, n::Int, id, field::Symbol)
    if x isa AbstractVector
        length(x) == n ||
            throw(ArgumentError("transformer $id has $n terminals but `$field` has $(length(x)) entries"))
        return TapMode[_tap_mode(m) for m in x]
    end

    m = _tap_mode(x)
    n == 2 && return TapMode[m, FIXED]
    m === FIXED && return fill(FIXED, n)

    throw(ArgumentError("transformer $id has $n terminals, so `$field` takes one entry per " *
                        "terminal; a scalar stands for the first winding of a two-winding " *
                        "transformer only"))
end

function _check_transformer(id, tm, ta, tm_min, tm_max, ta_min, ta_max, tm_step, ta_step,
                            oltc, pst, angmin, angmax)
    all_nw(w -> all(>(0), w), tm) ||
        throw(ArgumentError("transformer $id has a non-positive tap magnitude"))
    all_nw(w -> all(>(0), w), tm_min) ||
        throw(ArgumentError("transformer $id has a non-positive tm_min"))
    all_nw((lo, hi) -> all(lo .<= hi), tm_min, tm_max) ||
        throw(ArgumentError("transformer $id has tm_min above tm_max"))
    all_nw((lo, hi) -> all(lo .<= hi), ta_min, ta_max) ||
        throw(ArgumentError("transformer $id has ta_min above ta_max"))
    all_nw(w -> all(a -> -pi / 2 < a < pi / 2, w), ta_min) &&
        all_nw(w -> all(a -> -pi / 2 < a < pi / 2, w), ta_max) ||
        throw(ArgumentError("transformer $id has a ratio angle limit outside (-π/2, π/2)"))
    all_nw(w -> all(>(0), w), tm_step) && all_nw(w -> all(>(0), w), ta_step) ||
        throw(ArgumentError("transformer $id has a step that is not positive"))
    all_nw(<=, angmin, angmax) ||
        throw(ArgumentError("transformer $id has angmin above angmax"))

    for k in eachindex(oltc)
        steps_magnitude, steps_angle = oltc[k] === STEPPED, pst[k] === STEPPED
        mixed = (steps_magnitude && pst[k] === CONTINUOUS) ||
                (steps_angle && oltc[k] === CONTINUOUS)

        mixed &&
            throw(ArgumentError("winding $k of transformer $id steps one part of its ratio and " *
                                "moves the other continuously, which is not built"))

        steps_magnitude && _check_steps(id, k, "magnitude", tm, tm_min, tm_max, tm_step)
        steps_angle     && _check_steps(id, k, "angle", ta, ta_min, ta_max, ta_step)
    end

    return nothing
end

"the positions of a stepped range, from `lo` to `hi` and `step` apart"
_positions(lo, hi, step) = [lo + i * step for i in 0:round(Int, (hi - lo) / step)]

"the index of `x` among the positions of a range, or `nothing` where it is none of them"
function _position(x, lo, hi, step)
    i = round(Int, (x - lo) / step)

    return 0 <= i <= round(Int, (hi - lo) / step) && abs(x - (lo + i * step)) < 1e-8 ? i + 1 : nothing
end

"what a winding that steps its `what` has to satisfy: a range of whole steps, a setpoint on one"
function _check_steps(id, k, what, setpoint, lo, hi, step)
    any(is_nw_varying, (lo, hi, step)) &&
        throw(ArgumentError("winding $k of transformer $id steps its $what, so the limits and the " *
                            "step of it cannot vary over the network index"))

    n = (hi[k] - lo[k]) / step[k]
    abs(n - round(n)) < 1e-6 ||
        throw(ArgumentError("the limits of the $what of winding $k of transformer $id are not " *
                            "a whole number of steps apart"))

    all_nw(x -> _position(x[k], lo[k], hi[k], step[k]) !== nothing, setpoint) ||
        throw(ArgumentError("the setpoint of the $what of winding $k of transformer $id is " *
                            "not one of its positions"))

    return nothing
end

register_edge_type!(Transformer)

"a transformer writes a rating where a terminal's `rate_a` is finite, and angle limits where they bind"
structure_gates(::Transformer) = (:rate_a, :angmin, :angmax)

"whether the problem chooses the ratio magnitude of winding `k`"
_moves_magnitude(::NetworkModel{P}, tf::Transformer, k::Int) where {P<:AbstractProblemType} =
    _decides(P) && tf.oltc[k] === CONTINUOUS

"whether the problem chooses the ratio angle of winding `k`"
_moves_angle(::NetworkModel{P}, tf::Transformer, k::Int) where {P<:AbstractProblemType} =
    _decides(P) && tf.pst[k] === CONTINUOUS

"whether the problem chooses the ratio of winding `k` at all"
_moves(nm::NetworkModel, tf::Transformer, k::Int) =
    _moves_magnitude(nm, tf, k) || _moves_angle(nm, tf, k) || _stepped(nm, tf, k)

"""
    _stepped(nm, tf, k)

Whether the problem chooses the ratio of winding `k` from the positions of a
range. In the linearized formulation that is only an angle, since a magnitude does
nothing there.
"""
function _stepped end

_stepped(::NetworkModel{P,F}, tf::Transformer, k::Int) where {P<:AbstractProblemType,F<:IVRFormulation} =
    _decides(P) && (tf.oltc[k] === STEPPED || tf.pst[k] === STEPPED)

_stepped(::NetworkModel{P,F}, tf::Transformer, k::Int) where {P<:AbstractProblemType,F<:LPFFormulation} =
    _decides(P) && tf.pst[k] === STEPPED

"""
    _variable_steps!(nm, tf, a, k; nw)

One binary `zt` for each position winding `k` can take, keyed by `(a, s)` with `a`
its [`Arc`](@ref), and starting at 1 for the position of the setpoint.

A winding that is held, see [`is_held`](@ref), takes the position of the base case,
so it does not have binaries of its own: it reuses the ones of the base case, where
ties between copies would only give a mixed-integer solver more to branch on.
"""
function _variable_steps!(nm::NetworkModel, tf::Transformer, a::Arc, k::Int; nw::Int)
    start = _step_start(nm, tf, k)
    base  = is_held(nm, :edge, a.edge; nw) ? first_id(nm, nw, :contingency) : nothing

    zt = variable_container!(nm, :zt; nw, idtype = Tuple{Arc,Int})
    for s in eachindex(_step_values(nm, tf, k))
        if base === nothing
            variable!(nm, :zt, (a, s); nw, base_name = "$(nw)_zt[$(a.edge),$k,$s]",
                      start = s == start ? 1.0 : 0.0, binary = true)
        else
            zt[(a, s)] = var(nm, :zt, (a, s); nw = base)
        end
    end

    return nothing
end

"""
    _constraint_steps!(nm, tf, e, A; nw)

One position for every stepped winding of transformer `e`, `Σₛ zt = 1`, written
where the transformer is not held, see [`is_held`](@ref).
"""
function _constraint_steps!(nm::NetworkModel, tf::Transformer, e::Int, A::Vector{Arc}; nw::Int)
    step = get!(() -> Dict{Arc,Any}(), con(nm; nw), :tap_step)
    is_held(nm, :edge, e; nw) && return nothing

    for (k, a) in enumerate(A)
        _stepped(nm, tf, k) || continue

        zt = var(nm, :zt; nw)
        step[a] = constrain!(nm, :tap_step, a, JuMP.@build_constraint(
            sum(zt[(a, s)] for s in eachindex(_step_values(nm, tf, k))) == 1); nw)
    end

    return nothing
end

"the position winding `k` takes, among the ones it can, in a solved model"
_chosen_step(nm::NetworkModel, tf::Transformer, a::Arc, k::Int; nw::Int) =
    argmax(s -> JuMP.value(var(nm, :zt, (a, s); nw)), eachindex(_step_values(nm, tf, k)))

"""
    tap_ratio(nm, tf, e, k; nw)

The real and imaginary part of the ratio `T = tm · exp(j·ta)` of winding `k` of
transformer `e`.

Two numbers where the winding holds its ratio, which is the case for a `FIXED`
one and for any winding in a power flow. A winding the problem chooses the ratio
of returns what that ratio is made of: variables for the angle, an expression in
the magnitude variable, or an expression in the binaries of its positions.
"""
function tap_ratio end

tap_ratio(::NetworkModel, tf::Transformer, ::Int, k::Int; nw::Int) =
    (tf.tm[k] * cos(tf.ta[k]), tf.tm[k] * sin(tf.ta[k]))

"""
    phase_shift(nm, tf, e, k; nw)

The angle winding `k` of transformer `e` shifts, `ta`.

The counterpart of [`tap_ratio`](@ref) for the linearized formulation, where only
the angle survives: a number where the winding holds it, the variable the problem
chooses where `pst` is `CONTINUOUS`, and an expression in the binaries of its
positions where `pst` is `STEPPED`.
"""
function phase_shift end

phase_shift(::NetworkModel, tf::Transformer, ::Int, k::Int; nw::Int) = tf.ta[k]

################################################################################
# Transformer — variables                                                      #
################################################################################

"""
    variable_edge(nm, Transformer; nw)

The complex voltage of the star point of every in-service transformer, `vsr` and
`vsi`, and for every winding whose ratio the problem chooses, the voltage behind
it, and the ratio itself: `tm` where only the magnitude moves, `tr` and `ti` where
the angle does, with or without the magnitude. A variable of a winding is keyed by
its [`Arc`](@ref).

Only the angle is kept as a real and an imaginary part, so that the equations stay
polynomial: it enters through `tr² + ti² = tm²`, or a ring between `tm_min²` and
`tm_max²` where the magnitude moves too, and a pair of bounds on `ti/tr`, in
place of a sine and a cosine of a variable. The start of a voltage behind a ratio
is the node's own, referred through it.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{Transformer}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractProblemType,F<:IVRFormulation}
    variable_container!(nm, :vsr, :vsi; nw)

    for e in ids(nm, Transformer; nw)
        tf = edge(nm, e; nw)::Transformer

        vs0 = _referred_start(tf, 1)
        variable!(nm, :vsr, e; nw, base_name = "$(nw)_vsr[$e]", start = vs0[1])
        variable!(nm, :vsi, e; nw, base_name = "$(nw)_vsi[$e]", start = vs0[2])

        for (k, a) in enumerate(edge_arcs(nm, e; nw))
            _moves(nm, tf, k) || continue
            _variable_winding!(nm, tf, a, k; nw)
        end
    end

    return nothing
end

"the voltage of a node at one per unit and no angle, as seen behind the ratio of winding `k`"
function _referred_start(tf::Transformer, k::Int)
    tr, ti = tf.tm[k] * cos(tf.ta[k]), tf.tm[k] * sin(tf.ta[k])

    return tr / (tr^2 + ti^2), -ti / (tr^2 + ti^2)
end

"the variables of winding `k`, whose ratio the problem chooses"
function _variable_winding!(nm::NetworkModel, tf::Transformer, a::Arc, k::Int; nw::Int)
    name(key) = "$(nw)_$(key)[$(a.edge),$k]"
    tm, ta    = tf.tm[k], tf.ta[k]

    vtr0, vti0 = _referred_start(tf, k)
    variable!(nm, :vtr, a; nw, base_name = name(:vtr), start = vtr0)
    variable!(nm, :vti, a; nw, base_name = name(:vti), start = vti0)

    if _stepped(nm, tf, k)
        _variable_steps!(nm, tf, a, k; nw)
    elseif _moves_angle(nm, tf, k)
        lo, hi   = tf.ta_min[k], tf.ta_max[k]
        mlo, mhi = _moves_magnitude(nm, tf, k) ? (tf.tm_min[k], tf.tm_max[k]) : (tm, tm)
        ms       = clamp(tm, mlo, mhi)

        variable!(nm, :tr, a; nw, base_name = name(:tr), start = ms * cos(ta),
                  lower = mlo * cos(max(abs(lo), abs(hi))), upper = mhi)
        variable!(nm, :ti, a; nw, base_name = name(:ti), start = ms * sin(ta),
                  lower = min(mlo * sin(lo), mhi * sin(lo)),
                  upper = max(mlo * sin(hi), mhi * sin(hi)))
    else
        variable!(nm, :tm, a; nw, base_name = name(:tm),
                  start = clamp(tm, tf.tm_min[k], tf.tm_max[k]),
                  lower = tf.tm_min[k], upper = tf.tm_max[k])
    end

    return nothing
end

function tap_ratio(nm::NetworkModel{P,F}, tf::Transformer, e::Int, k::Int; nw::Int
                  ) where {P<:AbstractProblemType,F<:IVRFormulation}
    _moves(nm, tf, k) || return (tf.tm[k] * cos(tf.ta[k]), tf.tm[k] * sin(tf.ta[k]))

    a = edge_arcs(nm, e; nw)[k]
    if _stepped(nm, tf, k)
        zt, S = var(nm, :zt; nw), _step_values(nm, tf, k)

        return (JuMP.@expression(nm.model, sum(S[s][1] * zt[(a, s)] for s in eachindex(S))),
                JuMP.@expression(nm.model, sum(S[s][2] * zt[(a, s)] for s in eachindex(S))))
    end
    _moves_angle(nm, tf, k) && return (var(nm, :tr, a; nw), var(nm, :ti, a; nw))

    tm = var(nm, :tm, a; nw)

    return (JuMP.@expression(nm.model, cos(tf.ta[k]) * tm),
            JuMP.@expression(nm.model, sin(tf.ta[k]) * tm))
end

"""
    _step_values(nm, tf, k)

The ratios `(tr, ti)` winding `k` can take where it steps, one binary for each: the
magnitudes in turn for every angle, where it steps both. The part of the ratio it
does not step is its setpoint.
"""
function _step_values(::NetworkModel{P,F}, tf::Transformer, k::Int
                     ) where {P<:AbstractProblemType,F<:IVRFormulation}
    ms = tf.oltc[k] === STEPPED ? _positions(tf.tm_min[k], tf.tm_max[k], tf.tm_step[k]) : [tf.tm[k]]
    as = tf.pst[k]  === STEPPED ? _positions(tf.ta_min[k], tf.ta_max[k], tf.ta_step[k]) : [tf.ta[k]]

    return [(m * cos(a), m * sin(a)) for m in ms for a in as]
end

"the index, among [`_step_values`](@ref), of the setpoint of winding `k`"
function _step_start(::NetworkModel{P,F}, tf::Transformer, k::Int
                    ) where {P<:AbstractProblemType,F<:IVRFormulation}
    i = tf.oltc[k] === STEPPED ? _position(tf.tm[k], tf.tm_min[k], tf.tm_max[k], tf.tm_step[k]) : 1
    j = tf.pst[k]  === STEPPED ? _position(tf.ta[k], tf.ta_min[k], tf.ta_max[k], tf.ta_step[k]) : 1
    na = tf.pst[k] === STEPPED ? length(_positions(tf.ta_min[k], tf.ta_max[k], tf.ta_step[k])) : 1

    return (i - 1) * na + j
end

################################################################################
# Transformer — constraints                                                    #
################################################################################

"""
    constraint_edge(nm, Transformer; nw)

The physics of every in-service transformer: the ideal ratio of each winding, the
drop from each winding to the star point, and the current balance there.

For winding `k` at node `i_k`, with ratio `T_k`, write the voltage behind the
ratio and the current referred through it as

```math
v_{i_k} = T_{k} \\, v^{\\text{t}}_{k}, \\qquad c^{\\text{t}}_{k} = \\overline{T_{k}} \\, c_{a_k},
```

which conserves complex power across the ideal part. Where the ratio is held this
is substituted away and `v^{\\text{t}}_{k}` is an expression in the node voltage,
or the node voltage itself where the ratio is one; where the problem chooses it,
`v^{\\text{t}}_{k}` is a variable of the winding. What is left is the star, with
`z_k` the impedance and `y^{\\text{sh}}_{k}` the shunt of winding `k`,

```math
v^{\\text{t}}_{k} - v^{\\text{s}}_{e} = z_{k} \\left( c^{\\text{t}}_{k} -
y^{\\text{sh}}_{k} v^{\\text{t}}_{k} \\right),
\\qquad
\\sum_{k} \\left( c^{\\text{t}}_{k} - y^{\\text{sh}}_{k} v^{\\text{t}}_{k} \\right)
= y^{\\text{m}}_{e} \\, v^{\\text{s}}_{e}.
```
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{Transformer}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:IVRFormulation}
    vsr, vsi = var(nm, :vsr; nw), var(nm, :vsi; nw)

    winding = get!(() -> Dict{Int,Any}(), con(nm; nw), :winding)
    star    = get!(() -> Dict{Int,Any}(), con(nm; nw), :star_balance)

    for e in ids(nm, Transformer; nw)
        tf  = edge(nm, e; nw)::Transformer
        csr = Any[]
        csi = Any[]

        winding[e] = map(enumerate(edge_arcs(nm, e; nw))) do (k, a)
            vtr, vti, ctr, cti = _behind_ratio!(nm, tf, e, k, a; nw)

            # what leaves the winding's own shunt reaches the star point
            gsh, bsh = tf.g_sh[k], tf.b_sh[k]
            if iszero(gsh) && iszero(bsh)
                push!(csr, ctr)
                push!(csi, cti)
            else
                push!(csr, JuMP.@expression(nm.model, ctr - (gsh * vtr - bsh * vti)))
                push!(csi, JuMP.@expression(nm.model, cti - (gsh * vti + bsh * vtr)))
            end

            zr, zx = tf.r[k], tf.x[k]
            (constrain!(nm, :winding, (a, :real), JuMP.@build_constraint(
                 vtr - vsr[e] == zr * csr[k] - zx * csi[k]); nw),
             constrain!(nm, :winding, (a, :imag), JuMP.@build_constraint(
                 vti - vsi[e] == zr * csi[k] + zx * csr[k]); nw))
        end

        star[e] = (
            constrain!(nm, :star_balance, (e, :real), JuMP.@build_constraint(
                sum(csr) == tf.g_m * vsr[e] - tf.b_m * vsi[e]); nw),
            constrain!(nm, :star_balance, (e, :imag), JuMP.@build_constraint(
                sum(csi) == tf.g_m * vsi[e] + tf.b_m * vsr[e]); nw))
    end

    return nothing
end

"""
    _behind_ratio!(nm, tf, e, k, a; nw)

The voltage and the current of arc `a`, winding `k`, behind its ratio, as
`(vtr, vti, ctr, cti)`, writing the rows of the ideal ratio where the problem
chooses it.
"""
function _behind_ratio!(nm::NetworkModel, tf::Transformer, e::Int, k::Int, a::Arc; nw::Int)
    vr, vi = var(nm, :vr; nw), var(nm, :vi; nw)
    cr, ci = var(nm, :cr; nw), var(nm, :ci; nw)
    i      = a.node

    if _moves(nm, tf, k)
        tr, ti   = tap_ratio(nm, tf, e, k; nw)
        vtr, vti = var(nm, :vtr, a; nw), var(nm, :vti, a; nw)

        constrain!(nm, :transformer_ratio, (a, :real),
                   JuMP.@build_constraint(vr[i] == tr * vtr - ti * vti); nw)
        constrain!(nm, :transformer_ratio, (a, :imag),
                   JuMP.@build_constraint(vi[i] == tr * vti + ti * vtr); nw)

        return (vtr, vti,
                JuMP.@expression(nm.model, tr * cr[a] + ti * ci[a]),
                JuMP.@expression(nm.model, tr * ci[a] - ti * cr[a]))
    end

    tm, ta = tf.tm[k], tf.ta[k]
    tm == 1 && ta == 0 && return (vr[i], vi[i], cr[a], ci[a])

    tr, ti = tm * cos(ta), tm * sin(ta)

    return (JuMP.@expression(nm.model, (tr * vr[i] + ti * vi[i]) / tm^2),
            JuMP.@expression(nm.model, (tr * vi[i] - ti * vr[i]) / tm^2),
            JuMP.@expression(nm.model, tr * cr[a] + ti * ci[a]),
            JuMP.@expression(nm.model, tr * ci[a] - ti * cr[a]))
end

"""
    constraint_edge_limits(nm, Transformer; nw)

The limits of every in-service transformer: the apparent power rating at each
terminal, where the problem watches the transformer for congestion, see
[`is_monitored`](@ref); the limits on the voltage angle difference across a
two-winding one; and, for a winding whose angle the problem chooses, that the
ratio keeps its magnitude, `tr² + ti² = tm²`, and its angle stays between
`ta_min` and `ta_max`. Where the magnitude is chosen too, the ratio stays in the
ring `tm_min² ≤ tr² + ti² ≤ tm_max²` instead. A winding that steps takes exactly one
of its positions, `Σₛ zt = 1`.

In a redispatch the ratio of a preventive winding is tied to the base case, whose
rows already restrict it, so the other network indices do not write them again,
see [`is_held`](@ref).
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{Transformer}; nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:IVRFormulation}
    rating = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_rating)
    angle  = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_angle_difference)
    tap    = get!(() -> Dict{Arc,Any}(), con(nm; nw), :tap_setting)

    for e in ids(nm, Transformer; nw)
        tf = edge(nm, e; nw)::Transformer
        A  = edge_arcs(nm, e; nw)

        rating[e] = constraint_edge_rating!(nm, e, tf.rate_a; nw)
        length(A) == 2 &&
            (angle[e] = constraint_edge_angle_difference!(nm, A[1], A[2], tf.angmin, tf.angmax; nw))

        _constraint_steps!(nm, tf, e, A; nw)
        is_held(nm, :edge, e; nw) && continue

        for (k, a) in enumerate(A)
            _moves_angle(nm, tf, k) || continue
            tr, ti = var(nm, :tr, a; nw), var(nm, :ti, a; nw)

            magnitude = if _moves_magnitude(nm, tf, k)
                (constrain!(nm, :tap_setting, (a, :magnitude_max),
                            JuMP.@build_constraint(tr^2 + ti^2 <= tf.tm_max[k]^2); nw),
                 constrain!(nm, :tap_setting, (a, :magnitude_min),
                            JuMP.@build_constraint(tr^2 + ti^2 >= tf.tm_min[k]^2); nw))
            else
                (constrain!(nm, :tap_setting, (a, :magnitude),
                            JuMP.@build_constraint(tr^2 + ti^2 == tf.tm[k]^2); nw),)
            end

            tap[a] = (magnitude...,
                constrain!(nm, :tap_setting, (a, :max),
                           JuMP.@build_constraint(ti <= tan(tf.ta_max[k]) * tr); nw),
                constrain!(nm, :tap_setting, (a, :min),
                           JuMP.@build_constraint(ti >= tan(tf.ta_min[k]) * tr); nw))
        end
    end

    return nothing
end

################################################################################
# Transformer — the linearized formulation                                     #
################################################################################

"""
    variable_edge(nm, Transformer; nw)

The angle of the star point of every in-service transformer with three or more
windings, `vas`, and the angle of every winding whose `pst` is `CONTINUOUS` where
the problem chooses, held between `ta_min` and `ta_max`. A winding whose `pst` is
`STEPPED` has a binary `zt` for each of its positions instead.

A transformer with two windings has no star point here: its windings are in series
and only the sum of their impedances matters, so nothing is left to be a variable.

!!! note "The tap magnitude does nothing here"
    With every voltage magnitude equal to one there is nothing for a ratio
    magnitude to change, so `tm` does not appear in the linearized equations at
    all. A winding that is `oltc` is therefore **inert** in this formulation: it is
    built and solved as an ordinary winding at its setpoint, and the control it
    offers an alternating current model is simply absent. If it is also `pst`, its
    angle still moves. Use an [`IVRFormulation`](@ref) where the magnitude is the
    point.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{Transformer}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractProblemType,F<:LPFFormulation}
    variable_container!(nm, :vas; nw)

    for e in ids(nm, Transformer; nw)
        tf = edge(nm, e; nw)::Transformer
        A  = edge_arcs(nm, e; nw)

        length(A) > 2 && variable!(nm, :vas, e; nw, base_name = "$(nw)_vas[$e]", start = 0.0)

        for (k, a) in enumerate(A)
            if _stepped(nm, tf, k)
                _variable_steps!(nm, tf, a, k; nw)
                continue
            end

            _moves_angle(nm, tf, k) || continue
            variable!(nm, :ta, a; nw, base_name = "$(nw)_ta[$e,$k]",
                      start = clamp(tf.ta[k], tf.ta_min[k], tf.ta_max[k]),
                      lower = tf.ta_min[k], upper = tf.ta_max[k])
        end
    end

    return nothing
end

function phase_shift(nm::NetworkModel{P,F}, tf::Transformer, e::Int, k::Int; nw::Int
                    ) where {P<:AbstractProblemType,F<:LPFFormulation}
    a = edge_arcs(nm, e; nw)[k]
    if _stepped(nm, tf, k)
        zt, S = var(nm, :zt; nw), _step_values(nm, tf, k)

        return JuMP.@expression(nm.model, sum(S[s] * zt[(a, s)] for s in eachindex(S)))
    end

    return _moves_angle(nm, tf, k) ? var(nm, :ta, a; nw) : tf.ta[k]
end

"the angles winding `k` can take where it steps, one binary for each"
_step_values(::NetworkModel{P,F}, tf::Transformer, k::Int
            ) where {P<:AbstractProblemType,F<:LPFFormulation} =
    _positions(tf.ta_min[k], tf.ta_max[k], tf.ta_step[k])

"the index, among [`_step_values`](@ref), of the setpoint of winding `k`"
_step_start(::NetworkModel{P,F}, tf::Transformer, k::Int
           ) where {P<:AbstractProblemType,F<:LPFFormulation} =
    _position(tf.ta[k], tf.ta_min[k], tf.ta_max[k], tf.ta_step[k])

"""
    constraint_edge(nm, Transformer; nw)

The linearized flow of every in-service transformer. With `va^t_k = va_{i_k} -
ta_k` the angle behind the ratio of winding `k`, a transformer with two windings
is a line across the sum of their impedances,

```math
p_{a_1} = -b_{e} \\left( v^{\\text{at}}_{1} - v^{\\text{at}}_{2} \\right),
\\qquad
p_{a_2} = -p_{a_1},
```

and one with more windings is a star, each winding flowing into the star point
and the flows balancing there,

```math
p_{a_k} = -b_{e,k} \\left( v^{\\text{at}}_{k} - v^{\\text{as}}_{e} \\right),
\\qquad
\\sum_{k} p_{a_k} = 0 .
```

The phase shift survives the approximations and the ratio magnitude does not,
which is what makes a winding that is `pst` a real control in this formulation
and one that is `oltc` an inert one. The magnetising branch and the shunts play no
part, for the same reason a branch's shunt does not.
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{Transformer}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractProblemType,F<:LPFFormulation}
    va, p = var(nm, :va; nw), var(nm, :p; nw)

    branch  = get!(() -> Dict{Int,Any}(), con(nm; nw), :branch)
    winding = get!(() -> Dict{Int,Any}(), con(nm; nw), :winding)
    star    = get!(() -> Dict{Int,Any}(), con(nm; nw), :star_balance)

    for e in ids(nm, Transformer; nw)
        tf = edge(nm, e; nw)::Transformer
        A  = edge_arcs(nm, e; nw)

        if length(A) == 2
            shift = phase_shift(nm, tf, e, 1; nw) - phase_shift(nm, tf, e, 2; nw)
            b     = susceptance(sum(tf.r), sum(tf.x))

            branch[e] = constraint_linear_flow!(nm, e, A[1], A[2], b, shift; nw)
            continue
        end

        vas = var(nm, :vas; nw)
        winding[e] = map(enumerate(A)) do (k, a)
            tf.r[k]^2 + tf.x[k]^2 > 0 ||
                throw(ArgumentError("winding $k of transformer $e has no impedance, which a " *
                                    "transformer with $(length(A)) windings cannot have in a " *
                                    "linearized formulation: its susceptance would be infinite"))

            constrain!(nm, :winding, a, JuMP.@build_constraint(p[a] ==
                -susceptance(tf.r[k], tf.x[k]) *
                (va[a.node] - phase_shift(nm, tf, e, k; nw) - vas[e])); nw)
        end
        star[e] = constrain!(nm, :star_balance, e,
                             JuMP.@build_constraint(sum(p[a] for a in A) == 0.0); nw)
    end

    return nothing
end

"""
    constraint_edge_limits(nm, Transformer; nw)

The rating and the angle difference limits of every in-service transformer. With
no losses, what leaves one terminal of a two-winding transformer arrives at the
other, so the tighter of the two ratings is the one that binds; a transformer with
more windings is rated at each terminal. The rating is skipped where the problem
does not watch the transformer for congestion, see [`is_monitored`](@ref). A winding
that steps takes exactly one of its positions, `Σₛ zt = 1`.
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{Transformer}; nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:LPFFormulation}
    limits = get!(() -> Dict{Int,Any}(), con(nm; nw), :edge_limits)

    for e in ids(nm, Transformer; nw)
        tf = edge(nm, e; nw)::Transformer
        A  = edge_arcs(nm, e; nw)

        limits[e] = length(A) == 2 ?
            constraint_linear_limits!(nm, e, A[1], A[2], minimum(tf.rate_a),
                                      tf.angmin, tf.angmax; nw) :
            constraint_linear_ratings!(nm, e, A, tf.rate_a; nw)

        _constraint_steps!(nm, tf, e, A; nw)
    end

    return nothing
end

################################################################################
# Transformer — the redispatch problem                                         #
################################################################################

"""
    redispatch_controls(nm, Transformer)

The ratio of a preventive winding, held equal across the contingencies: `tm`, `tr`
and `ti` in the current based formulation, the angle `ta` in the linearized one,
each of them keyed by the [`Arc`](@ref) of the winding it belongs to. The binaries
of a winding that steps are not tied: a preventive winding reuses the ones of the
base case, see [`is_held`](@ref).

A winding that is `oltc` or `pst` is a **non-costly** measure: there is no
[`redispatch_cost`](@ref) method for a transformer, so moving it is free. In the
linearized formulation a magnitude is inert and has no variable, so it holds
nothing there.
"""
redispatch_controls(::NetworkModel{P,F}, ::Type{Transformer}
                   ) where {P<:AbstractProblemType,F<:IVRFormulation} = (:tm, :tr, :ti)

redispatch_controls(::NetworkModel{P,F}, ::Type{Transformer}
                   ) where {P<:AbstractProblemType,F<:LPFFormulation} = (:ta,)

################################################################################
# Transformer — solution                                                       #
################################################################################

"""
    solution_edge!(entry, nm, Transformer, e, nw)

Add the tap setting of every winding to the entry of its terminal, under `tap`: the
magnitude `tm` and the angle `ta` of the ratio, and `tr` and `ti` in the current
based formulation. For a winding that holds its ratio this reports back what was
given; for one the problem chose it is what the optimizer chose.

In a redispatch the setpoint is reported too, as `tm_market` and `ta_market`: the
ratio the market schedule left the winding at, so that what the redispatch moved is
the difference. A winding that steps reports the index of its position as `step`,
counted as the positions of [`Transformer`](@ref) run: for a winding that steps
both in the current based formulation, the magnitudes in turn for every angle.
"""
function solution_edge!(entry::Dict{String,Any}, nm::NetworkModel{P,F}, ::Type{Transformer},
                        e::Int, nw::Int) where {P<:AbstractProblemType,F<:IVRFormulation}
    tf = edge(nm, e; nw)::Transformer

    for (k, a) in enumerate(edge_arcs(nm, e; nw))
        tr, ti = map(_value, tap_ratio(nm, tf, e, k; nw))
        tap    = Dict{String,Any}("tr" => tr, "ti" => ti, "tm" => hypot(tr, ti), "ta" => atan(ti, tr))
        _stepped(nm, tf, k) && (tap["step"] = _chosen_step(nm, tf, a, k; nw))
        _market!(tap, nm, tf, k)

        entry["terminal"]["$(a.terminal)"]["tap"] = tap
    end

    return nothing
end

function solution_edge!(entry::Dict{String,Any}, nm::NetworkModel{P,F}, ::Type{Transformer},
                        e::Int, nw::Int) where {P<:AbstractProblemType,F<:LPFFormulation}
    tf = edge(nm, e; nw)::Transformer

    for (k, a) in enumerate(edge_arcs(nm, e; nw))
        tap = Dict{String,Any}("tm" => tf.tm[k], "ta" => _value(phase_shift(nm, tf, e, k; nw)))
        _stepped(nm, tf, k) && (tap["step"] = _chosen_step(nm, tf, a, k; nw))
        _market!(tap, nm, tf, k)

        entry["terminal"]["$(a.terminal)"]["tap"] = tap
    end

    return nothing
end

"add the setpoint of winding `k` to `tap` where the problem is a redispatch"
_market!(tap::Dict{String,Any}, ::NetworkModel{P}, tf::Transformer, k::Int) where {P<:AbstractProblemType} =
    P <: RedispatchProblem ? (tap["tm_market"] = tf.tm[k]; tap["ta_market"] = tf.ta[k]; nothing) : nothing
