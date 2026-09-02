################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.6.0 - initial implementation                                              #
################################################################################

################################################################################
# DC link — data                                                               #
################################################################################

"""
    AbstractDCLink <: AbstractEdge

An edge whose flow is *chosen* rather than determined by the voltages at its
ends.

This is what separates it from every other edge in the package, and it is why it
is a type rather than a [`Branch`](@ref) carrying a flag. The flow of a branch
falls out of the angle difference across it: write the angles and the flow is
decided. A DC link stands between two converter stations, and what they exchange
is a setpoint — the link carries what it is told to carry, up to its rating, and
the angles either side of it are left free.

Two consequences follow, and both are the reason such a link is built:

- it **decouples** its two nodes, so no angle difference limit applies and the
  networks it joins need not be synchronous;
- it is **lossy** in a way a linearized branch is not. The linearization drops
  the losses of a branch because they are second order in the angle difference.
  A converter station's losses are first order in what it transfers and do not
  vanish at all, so they are modelled here even though the rest of the
  linearized model is lossless.

A concrete DC link carries `id`, `name`, `terminals` (exactly two), `rate_a`,
`loss_fixed`, `loss_prop`, `reverse`, `pdc`, `cost`, `status` and `ext`.
"""
abstract type AbstractDCLink <: AbstractEdge end

"""
    DCLink <: AbstractDCLink

A two-terminal edge `(e, i, j)` transferring active power from `i` to `j`, or
back, at a flow the problem chooses.

# Fields
- `id`, `name`: the identifier and a human readable label.
- `terminals`: `[i, j]`, the from and to node. The flow is positive from `i` to
  `j`.
- `rate_a`: the transfer rating [pu], `Inf` when unlimited. Unlike the rating of
  a branch this is an equipment limit rather than a congestion limit — a
  converter cannot transfer more than it is built for — so it is enforced
  whatever the problem watches, and it is not something an
  [`OverloadPrice`](@ref) can relax.
- `loss_fixed`, `loss_prop`: the loss the link takes as `loss_fixed +
  loss_prop · t`, with `t` the power **sent** into it [pu], from whichever end
  is sending. `loss_fixed` is the no-load loss of the stations, which an
  energized link takes whether it carries anything or not; `loss_prop` is the
  part proportional to the transfer, and must be below one.
- `reverse`: whether the link may carry power from `j` to `i` as well.
- `pdc`: the market schedule, i.e., the transfer the link is set to before the
  problem is asked [pu]. A load flow holds it here; a redispatch prices the
  moves away from it.
- `cost`: the price of moving one per unit away from `pdc`, in either direction
  [currency/pu/h]. Zero — the default — makes the link a **non-costly** measure,
  free to move, like a [`PhaseShifter`](@ref).
- `status`: whether the link is in service.
- `ext`: free-form storage.

Every field but `id`, `name`, `terminals`, `reverse` and `ext` may be given as a
[`NetworkVector`](@ref). `reverse` describes what the equipment is able to do
and so does not vary over the network index; take a link out of service through
`status` instead.

# Examples
```julia
julia> DCLink(; id = 1, terminals = [2, 7], rate_a = 10.0)

julia> DCLink(; id = 1, terminals = [2, 7], rate_a = 10.0,
                loss_fixed = 0.01, loss_prop = 0.02, reverse = false)
```

!!! note "One link, not two stations"
    A real scheme has a converter at each end, each with its own losses and, in
    a VSC, its own reactive capability. This type collapses both into one edge:
    the losses are those of the pair, and there is no reactive power because the
    linearized formulation has none. That is enough for a transfer decision in a
    market or redispatch model, and it is deliberately less than a converter
    model — see the manual for what is given up.
"""
Base.@kwdef struct DCLink <: AbstractDCLink
    id        ::Int
    name      ::String                   = ""
    terminals ::Vector{Int}
    rate_a    ::NetworkQuantity{Float64} = Inf
    loss_fixed::NetworkQuantity{Float64} = 0.0
    loss_prop ::NetworkQuantity{Float64} = 0.0
    reverse   ::Bool                     = true
    pdc       ::NetworkQuantity{Float64} = 0.0
    cost      ::NetworkQuantity{Float64} = 0.0
    status    ::NetworkQuantity{Bool}    = true
    ext       ::Dict{Symbol,Any}         = Dict{Symbol,Any}()

    function DCLink(id, name, terminals, rate_a, loss_fixed, loss_prop, reverse,
                    pdc, cost, status, ext)
        length(terminals) == 2 ||
            throw(ArgumentError("dc link $id has $(length(terminals)) terminals, a dc link has exactly two"))
        all_nw(>=(0), rate_a) ||
            throw(ArgumentError("dc link $id has a negative rating"))
        all_nw(>=(0), loss_fixed) ||
            throw(ArgumentError("dc link $id has a negative fixed loss"))
        all_nw(x -> 0 <= x < 1, loss_prop) ||
            throw(ArgumentError("dc link $id has a proportional loss outside [0, 1)"))
        all_nw(>=(0), cost) ||
            throw(ArgumentError("dc link $id has a negative cost, which pays the problem to move it"))
        all_nw((p, r) -> abs(p) <= r, pdc, rate_a) ||
            throw(ArgumentError("dc link $id has a market schedule beyond its rating"))
        reverse || all_nw(>=(0), pdc) ||
            throw(ArgumentError("dc link $id carries one way but has a market schedule against it"))

        return new(id, name, terminals, rate_a, loss_fixed, loss_prop, reverse,
                   pdc, cost, status, ext)
    end
end

register_edge_type!(DCLink)

"""
    structure_gates(dl)

A DC link writes its transfer limit only where that limit says something, and
writes the transfer variable its proportional loss is charged on only where
there is such a loss. Both therefore decide the shape of its model rather than a
number in it, see [`structure_gates`](@ref).
"""
structure_gates(::AbstractDCLink) = (:rate_a, :loss_prop)

"the loss a dc link takes when `t` is sent into it, resolved at one network index"
transfer_loss(dl::AbstractDCLink, t) = dl.loss_fixed + dl.loss_prop * t

"""
    transfer_limits(dl)

The range the flow at the from terminal of a dc link may take, resolved at one
network index.

Not quite the rating, which caps what each end *sends*, see
[`constraint_edge_limits`](@ref): a receiving end takes in less than the sending
end put out, so this is a range the flow certainly lies in rather than the
tightest one. That is all the redispatch volumes need it for.
"""
transfer_limits(dl::AbstractDCLink) = (dl.reverse ? -dl.rate_a : 0.0, dl.rate_a)

"whether the loss of a dc link depends on what it transfers"
_has_transfer_loss(dl::AbstractDCLink) = !iszero(dl.loss_prop)

################################################################################
# DC link — variables                                                          #
################################################################################

"""
    variable_edge(nm, T; nw)

The transfer of every in-service DC link whose loss depends on it.

The flow of a link is the terminal power it already has as an edge, so no
variable is needed to hold it. What is needed, and only where `loss_prop` is
non-zero, is the **transfer** `t`: the magnitude of that flow, which the loss is
charged on. It is bounded below by the flow in each direction, so it is at least
the magnitude, and the loss equality then pushes it down onto it — see
[`constraint_edge`](@ref).

A link with no proportional loss gets no such variable: its loss is a constant,
and a variable nothing pushes on would be free to take any value its bounds
allow.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,T<:AbstractDCLink}
    isempty(ids(nm, T; nw)) && return nothing

    _variable_dc_link!(nm, T, nw)

    return nothing
end

"""
    variable_edge(nm, T; nw)

Nothing: a power flow gives a DC link no variables at all.

The transfer of a link in a power flow is its schedule, which is data, so the
loss it takes is data too and there is nothing to solve for. That is not merely
an economy. A power flow has no objective — it is a feasibility problem — and
the transfer variable a dispatch problem carries is settled on the magnitude of
the flow by the objective and by nothing else. Carried into a power flow it
would be free to take any value its bounds allow, and the loss reported would be
whichever one the solver happened to stop at.
"""
variable_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
             ) where {P<:AbstractPowerFlowProblem,F<:LPFFormulation,T<:AbstractDCLink} =
    nothing

"the transfer of every in-service dc link whose loss is charged on it"
function _variable_dc_link!(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractDCLink}
    variable_container!(nm, :pdct; nw)

    for e in ids(nm, T; nw)
        dl = edge(nm, e; nw)::T
        _has_transfer_loss(dl) || continue

        variable!(nm, :pdct, e; nw, base_name = "$(nw)_pdct[$e]", start = abs(dl.pdc),
                  lower = 0.0, upper = dl.rate_a)
    end

    return nothing
end

"""
    variable_edge(nm, T; nw)

The transfer of every in-service DC link, plus the volumes it moved away from
its market schedule.

The volumes are bounded by the room left in each direction, clipped at zero the
way a generator's are, so a schedule outside the rating can still be brought
back inside it rather than making the problem infeasible.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:RedispatchProblem,F<:LPFFormulation,T<:AbstractDCLink}
    isempty(ids(nm, T; nw)) && return nothing

    _variable_dc_link!(nm, T, nw)

    variable_container!(nm, :pdcup, :pdcdn; nw)

    for e in ids(nm, T; nw)
        dl         = edge(nm, e; nw)::T
        down, up   = transfer_limits(dl)

        variable!(nm, :pdcup, e; nw, base_name = "$(nw)_pdcup[$e]", start = 0.0,
                  lower = 0.0, upper = isfinite(up) ? max(up - dl.pdc, 0.0) : nothing)
        variable!(nm, :pdcdn, e; nw, base_name = "$(nw)_pdcdn[$e]", start = 0.0,
                  lower = 0.0, upper = isfinite(down) ? max(dl.pdc - down, 0.0) : nothing)
    end

    return nothing
end

"""
    variable_edge(nm, T; nw)

A DC link has no model in an alternating current formulation, and says so.

The reason is not that it is hard to write but that it would be a different
component. What couples a DC link to an AC network is a converter station, and a
converter is more than a lossy transfer: it sets its reactive exchange within a
capability curve, which is most of why a voltage source converter is worth
building and all of what an AC formulation would be asked about. Writing this
type against [`IVRFormulation`](@ref) would answer that question with a link
that has no reactive power at all, which is worse than not answering it.
"""
function variable_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                      ) where {P<:AbstractProblemType,F<:AbstractACFormulation,T<:AbstractDCLink}
    isempty(ids(nm, T; nw)) && return nothing

    error("`$T` has no model under formulation `$F`: a dc link couples to an " *
          "alternating current network through a converter station, which is a " *
          "component in its own right and not this one. Pose the problem in a " *
          "`LPFFormulation`, or leave the link out of the network you hand to `$F`.")
end

################################################################################
# DC link — constraints                                                        #
################################################################################

"""
    constraint_edge(nm, T; nw)

The physics of every in-service DC link: what leaves one end arrives at the
other, less the loss of the pair of stations,

```math
p_{a^{\\text{f}}} + p_{a^{\\text{t}}} = \\ell^{0}_{e} + \\ell^{1}_{e} t_{e} ,
\\qquad t_{e} \\ge p_{a^{\\text{f}}}, \\qquad t_{e} \\ge p_{a^{\\text{t}}} .
```

Compare [`constraint_linear_flow!`](@ref), where the same statement is
`p_{a^{t}} = -p_{a^{f}}`: a branch is lossless in this formulation and a DC link
is not, and there is no angle difference here at all.

The transfer `t_e` is bounded below by what **each** end puts into the link, not
by the flow at one nominated end. Exactly one end is sending at a time and the
other is receiving, so the binding bound is always the sending one, and the loss
is charged on the power sent. That is what makes the link symmetric: which of
its two nodes was listed first in `terminals` is a data-entry choice, and it
must not change what the equipment does.

The bounds are inequalities rather than an equality because the magnitude of a
variable is not something a linear program can be told; together they are the
convex hull of the two directions, and the loss equality is what closes it. A
larger `t_e` is a larger loss, a larger loss needs more generation, and
generation is what the objective pays for, so the relaxation is tight wherever
dissipating power costs something. Where `loss_prop` is zero there is no `t_e`
and no relaxation to be tight, and a power flow, which has no objective at all,
takes neither — see [`variable_edge`](@ref).

What is left is a dispatch problem in which nobody is paid to generate: give
every generator that could serve the loss a redispatch price of zero and `t_e`
is free again. That is a degenerate way to pose the question rather than a case
this should handle, and it is worth knowing about rather than guarding.

Writing it this way is also what keeps a **bidirectional** link honest. Charging
the loss to a signed flow — `p_{a^{t}} = -\\eta \\, p_{a^{f}}` — is right in one
direction and creates energy in the other, since with `η < 1` a reversed flow
would deliver more than it took.
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,T<:AbstractDCLink}
    isempty(ids(nm, T; nw)) && return nothing

    _constraint_dc_link!(nm, T, nw)

    return nothing
end

"""
    constraint_edge(nm, T; nw)

The physics of every in-service DC link, and its flow held at the market
schedule it carries.

A power flow chooses nothing: a DC link is a setpoint there, the way a generator
is held at its `pg`, and the transfer is `pdc` whatever the rest of the network
does. Both the flow and the loss are therefore read off the data, with no
transfer variable and no relaxation between them.
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:AbstractPowerFlowProblem,F<:LPFFormulation,T<:AbstractDCLink}
    isempty(ids(nm, T; nw)) && return nothing

    p    = var(nm, :p; nw)
    link = get!(() -> Dict{Int,Any}(), con(nm; nw), :dc_link)

    for e in ids(nm, T; nw)
        dl         = edge(nm, e; nw)::T
        a_fr, a_to = edge_arcs(nm, e; nw)

        # the transfer is `pdc` and the loss follows from it, both data
        link[e] = (constrain!(nm, :dc_link, (e, :setpoint),
                              JuMP.@build_constraint(p[a_fr] == dl.pdc); nw),
                   constrain!(nm, :dc_link, (e, :loss), JuMP.@build_constraint(
                       p[a_fr] + p[a_to] == transfer_loss(dl, abs(dl.pdc))); nw))
    end

    return nothing
end

"the transfer and the loss of every in-service dc link"
function _constraint_dc_link!(nm::NetworkModel, ::Type{T}, nw::Int) where {T<:AbstractDCLink}
    p    = var(nm, :p; nw)
    link = get!(() -> Dict{Int,Any}(), con(nm; nw), :dc_link)

    for e in ids(nm, T; nw)
        dl         = edge(nm, e; nw)::T
        a_fr, a_to = edge_arcs(nm, e; nw)

        if !_has_transfer_loss(dl)
            link[e] = (constrain!(nm, :dc_link, (e, :loss), JuMP.@build_constraint(
                           p[a_fr] + p[a_to] == dl.loss_fixed); nw),)
            continue
        end

        t = var(nm, :pdct, e; nw)

        # the transfer is at least what each end puts in, so it is at least what
        # the *sending* end puts in whichever end that turns out to be; the loss
        # equality is what settles it there rather than above it
        forward = constrain!(nm, :dc_link, (e, :forward),
                             JuMP.@build_constraint(t >= p[a_fr]); nw)
        reverse = constrain!(nm, :dc_link, (e, :reverse),
                             JuMP.@build_constraint(t >= p[a_to]); nw)
        loss = constrain!(nm, :dc_link, (e, :loss), JuMP.@build_constraint(
                   p[a_fr] + p[a_to] == transfer_loss(dl, t)); nw)

        link[e] = (forward, reverse, loss)
    end

    return nothing
end

"""
    constraint_edge_limits(nm, T; nw)

The transfer limit of every in-service DC link: a cap on what each of its ends
may put in,

```math
p_{a} \\le s^{\\text{max}}_{e} \\quad \\forall a \\in A(e) ,
```

which bounds the power *sent* whichever end is sending, and needs no bound on
the receiving end because what arrives is less than what left. A link that
carries one way is the same statement with a cap of zero on the end that may not
send, so a direction and a rating are one row each rather than a special case.

A cap that is infinite is not written, which for a bidirectional unlimited link
means no rows at all. Unlike the rating of a branch this is not
congestion and so does not follow the monitored set, and an
[`OverloadPrice`](@ref) does not reach it: an operator may run a line past its
rating and pay for the risk, but a converter that is asked for more than it was
built for does not deliver it.
"""
function constraint_edge_limits(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                               ) where {P<:AbstractDispatchProblem,F<:LPFFormulation,
                                        T<:AbstractDCLink}
    isempty(ids(nm, T; nw)) && return nothing

    p      = var(nm, :p; nw)
    limits = get!(() -> Dict{Int,Any}(), con(nm; nw), :dc_link_limits)

    for e in ids(nm, T; nw)
        dl         = edge(nm, e; nw)::T
        a_fr, a_to = edge_arcs(nm, e; nw)
        caps       = (a_fr => dl.rate_a, a_to => dl.reverse ? dl.rate_a : 0.0)

        limits[e] = Tuple(constrain!(nm, :dc_link_limits, (e, a.terminal),
                                     JuMP.@build_constraint(p[a] <= cap); nw)
                          for (a, cap) in caps if isfinite(cap))
    end

    return nothing
end

"""
    constraint_edge(nm, T; nw)

The physics of every in-service DC link, and its transfer split into the market
schedule and the volumes moved away from it,

```math
p_{a^{\\text{f}}} = p^{\\text{dc,mkt}}_{e} + p^{\\uparrow}_{e} - p^{\\downarrow}_{e} .
```

The same statement a generator makes about its dispatch, and for the same
reason: what a redispatch prices is the move, not the transfer. A link left at
its schedule costs nothing however much it carries.
"""
function constraint_edge(nm::NetworkModel{P,F}, ::Type{T}; nw::Int = nw_id_default(nm)
                        ) where {P<:RedispatchProblem,F<:LPFFormulation,T<:AbstractDCLink}
    isempty(ids(nm, T; nw)) && return nothing

    _constraint_dc_link!(nm, T, nw)

    p     = var(nm, :p;     nw)
    pdcup = var(nm, :pdcup; nw)
    pdcdn = var(nm, :pdcdn; nw)
    split = get!(() -> Dict{Int,Any}(), con(nm; nw), :dc_link_redispatch)

    for e in ids(nm, T; nw)
        dl      = edge(nm, e; nw)::T
        a_fr, _ = edge_arcs(nm, e; nw)

        split[e] = constrain!(nm, :dc_link_redispatch, e, JuMP.@build_constraint(
                       p[a_fr] == dl.pdc + pdcup[e] - pdcdn[e]); nw)
    end

    return nothing
end

################################################################################
# DC link — redispatch                                                         #
################################################################################

"""
    redispatch_cost(nm, T, e; nw)

What moving DC link `e` away from its market schedule costs at network index
`nw`, `c_{e} (p^{\\uparrow}_{e} + p^{\\downarrow}_{e})`.

One price for both directions: a link is symmetric equipment, and moving it
either way is the same intervention. A link whose `cost` is zero has no cost
here and is a **non-costly** measure, taken before anything that is priced —
which is usually the right model of a link the operator already controls.
"""
function redispatch_cost(nm::NetworkModel, ::Type{T}, e::Int; nw::Int) where {T<:AbstractDCLink}
    dl = edge(nm, e; nw)::T

    return JuMP.@expression(nm.model,
        dl.cost * (var(nm, :pdcup, e; nw) + var(nm, :pdcdn, e; nw)))
end

"a preventive dc link holds one transfer across every contingency"
redispatch_controls(::NetworkModel{P,F}, ::Type{T}
                   ) where {P<:AbstractProblemType,F<:LPFFormulation,T<:AbstractDCLink} =
    (:pdcup, :pdcdn)

################################################################################
# DC link — solution                                                           #
################################################################################

"the transfer, the loss and the redispatch volumes of a dc link"
function solution_edge!(entry::Dict{String,Any}, nm::NetworkModel{P,F}, ::Type{T},
                        e::Int, nw::Int) where {P<:AbstractProblemType,F<:LPFFormulation,
                                                T<:AbstractDCLink}
    a_fr, a_to = edge_arcs(nm, e; nw)
    p_fr       = JuMP.value(var(nm, :p, a_fr; nw))
    p_to       = JuMP.value(var(nm, :p, a_to; nw))

    entry["pdc"]  = p_fr
    entry["loss"] = p_fr + p_to

    if haskey(var(nm; nw), :pdcup) && haskey(var(nm, :pdcup; nw), e)
        entry["pdc_market"] = edge(nm, e; nw).pdc
        entry["pdcup"]      = JuMP.value(var(nm, :pdcup, e; nw))
        entry["pdcdn"]      = JuMP.value(var(nm, :pdcdn, e; nw))
    end

    return nothing
end
