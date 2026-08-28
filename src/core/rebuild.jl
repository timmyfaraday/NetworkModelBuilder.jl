################################################################################
# NetworkModelBuilder.jl                                                       #
# A Julia package to build optimization models for power system problems.      #
# See http://github.com/timmyfaraday/NetworkModelBuilder.jl                    #
################################################################################
# Authors: Tom Van Acker                                                       #
################################################################################
# Changelog:                                                                   #
# v0.5.0 - building a model a second time updates it in place                  #
################################################################################

# A model built for one window of a rolling horizon is very nearly the model the
# next window needs: the same variables, the same constraints between them, and
# different numbers in them. Throwing it away and building it again is most of
# what a roll spends its time on, and it throws away the solver's basis with it.
#
# Rather than carry a second set of methods that write those numbers into an
# existing model — one per component per formulation, to be kept in step with
# the ones that built it — the builders themselves do both. Every constraint and
# every variable goes in through one of the two functions below, which add on
# first sight and update on second. Running `build_model!` again against new
# data is then the update, and there is no second description of the model to
# drift away from the first.

################################################################################
# Constraints                                                                  #
################################################################################

"""
    constrain!(nm, key, id, constraint; nw)

Add `constraint` under `(key, id)` at network index `nw`, or, where one is
already registered there, replace its function and its set in place.

`constraint` is what `JuMP.@build_constraint` returns — the same expression a
`JuMP.@constraint` would have written, held rather than added — so a call site
reads as it did before:

```julia
constrain!(nm, :node_balance, (i, :real),
           JuMP.@build_constraint(sum(cr[a] for a in A) == sum(cru[u] for u in U)); nw)
```

Replacing rather than deleting and re-adding is the whole point. The row keeps
its place in the solver's problem, so a simplex basis stays valid across the
change and the next solve starts from the last one instead of from scratch.

`id` is anything hashable, and a component that writes several constraints
should distinguish them — `(e, :from)` and `(e, :to)` rather than `e` twice.
Giving two different constraints the same `id` will silently overwrite one with
the other.

The register this keeps is its own, in `nm.ext`, and is not `con`.
`con` is what a component chooses to publish about itself and is keyed however
that component finds useful; this has to be keyed by what makes a constraint
*the same constraint* between one build and the next, which is a different
question with a different answer. Keeping them apart also means nothing that
already reads `con` sees any of this.
"""
function constrain!(nm::NetworkModel, key::Symbol, id, c::JuMP.ScalarConstraint; nw::Int)
    store = registered_constraints(nm)
    entry = get(store, (nw, key, id), nothing)

    if entry === nothing
        ref = JuMP.add_constraint(nm.model, c)
        store[(nw, key, id)] = (ref, c)
        return ref
    end

    ref, last = entry
    backend   = JuMP.backend(nm.model)
    index     = JuMP.index(ref)
    changed   = false

    # most of what a window is asked is what the last one was asked. Writing a
    # row the solver already holds costs more than adding one, so the ones that
    # did not move are left alone — which is the difference between this being
    # worth doing and not
    if last.func != c.func
        MOI.set(backend, MOI.ConstraintFunction(), index, JuMP.moi_function(c.func))
        changed = true
    end
    if last.set != c.set
        MOI.set(backend, MOI.ConstraintSet(), index, c.set)
        changed = true
    end
    changed && (store[(nw, key, id)] = (ref, c))

    return ref
end

"""
    registered_constraints(nm)

What [`constrain!`](@ref) has registered, keyed by `(nw, key, id)`, as the
constraint reference paired with the last function and set written into it.

The second half of the pair is what makes an update cheap: it says what the
solver is already holding, so a constraint that has not moved between one build
and the next is recognised and skipped.
"""
registered_constraints(nm::NetworkModel) =
    get!(() -> Dict{Tuple{Int,Symbol,Any},Tuple{JuMP.ConstraintRef,JuMP.ScalarConstraint}}(),
         nm.ext, :registered)::Dict{Tuple{Int,Symbol,Any},Tuple{JuMP.ConstraintRef,JuMP.ScalarConstraint}}

################################################################################
# Variables                                                                    #
################################################################################

"""
    variable!(nm, key, id; nw, base_name, start, lower, upper, fix)

The variable registered under `(key, id)` at network index `nw`, created on
first sight and returned as it is on second — with its bounds brought to what
the arguments say either way.

Only the bounds are updated, because only the bounds are data. Which variables
exist is structure, and a model is updated rather than rebuilt exactly when the
structure has not changed, see [`same_structure`](@ref).

`lower` and `upper` are dropped where they are `nothing` or not finite, so a
limit that was `1.0` in one window and `Inf` in the next leaves the variable
free rather than bounded by infinity. `fix` pins the variable outright, as a
load flow does to a generator setpoint, and releases it where it is `nothing`.
"""
function variable!(nm::NetworkModel, key::Symbol, id; nw::Int, base_name::String = "",
                   start = nothing, lower = nothing, upper = nothing, fix = nothing)
    store = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), key)
    v     = get(store, id, nothing)

    if v === nothing
        v = JuMP.@variable(nm.model, base_name = base_name)
        start === nothing || JuMP.set_start_value(v, start)
        store[id] = v
    end

    return bound!(v; lower, upper, fix)
end

"""
    variable_container!(nm, keys...; nw)

Make sure the container registered under each of `keys` at network index `nw`
exists, and return the last of them.

[`variable!`](@ref) creates a container as it puts the first variable in it,
which leaves the container missing where a type has no components at this
network index. Code that reaches for the whole container before looping — the
limits of a phase shifter, say — would then find nothing rather than nothing to
do, so a caller that does declares its containers up front.
"""
function variable_container!(nm::NetworkModel, keys::Symbol...; nw::Int)
    container = nothing
    for key in keys
        container = get!(() -> Dict{Int,JuMP.VariableRef}(), var(nm; nw), key)
    end

    return container
end

"""
    variables!(nm, key, indices; nw, base_name, start)

The container of variables registered under `key` at network index `nw`, one per
entry of `indices`, created on first sight and returned untouched on second.

The counterpart of [`variable!`](@ref) for the containers a whole index set
shares — the node voltages, the terminal flows, the unit injections. None of
them carries a bound that the data can move, so there is nothing to bring up to
date; where a caller does bound them, as a dispatch problem bounds a voltage by
the magnitude limit of its node, it does so through [`bound!`](@ref).
"""
function variables!(nm::NetworkModel, key::Symbol, indices; nw::Int,
                    base_name::String = "", start = _ -> 0.0)
    existing = get(var(nm; nw), key, nothing)
    existing === nothing || return existing

    v = JuMP.@variable(nm.model, [i in indices], base_name = base_name)
    for i in indices
        JuMP.set_start_value(v[i], start(i))
    end

    return var(nm; nw)[key] = v
end

"""
    bound!(v; lower, upper, fix)

Bring the bounds of variable `v` to what the arguments say, adding, moving and
removing them as needed, and return `v`.

A bound that is `nothing` or not finite is removed rather than set to infinity,
which is what lets a limit come and go between two windows of a rolling horizon
without the variable being left pinned by the one it had before.
"""
function bound!(v::JuMP.VariableRef; lower = nothing, upper = nothing, fix = nothing)
    if fix !== nothing
        JuMP.fix(v, fix; force = true)
        return v
    end
    JuMP.is_fixed(v) && JuMP.unfix(v)

    _bound!(v, lower, JuMP.has_lower_bound, JuMP.set_lower_bound, JuMP.delete_lower_bound)
    _bound!(v, upper, JuMP.has_upper_bound, JuMP.set_upper_bound, JuMP.delete_upper_bound)

    return v
end

function _bound!(v, value, has, set, delete)
    if value === nothing || !isfinite(value)
        has(v) && delete(v)
    else
        set(v, value)
    end

    return nothing
end

################################################################################
# Building a model again                                                       #
################################################################################

"""
    update_model!(nm, data)

Point `nm` at `data` and build it again, which updates it rather than adding to
it, and return `nm`.

Every variable and constraint goes in through [`variable!`](@ref) or
[`constrain!`](@ref), which find what is already registered and bring it up to
date instead of making a second one. So this is [`build_model!`](@ref), run a
second time, against different numbers.

`data` must give a model of the same **shape** — the same variables, the same
constraints between them — which is [`same_structure`](@ref) asked of every
network index. Nothing here checks that, because the caller is in a position to
know it cheaply and this is not: handing in data of a different shape leaves the
model holding constraints belonging to the data it had before, silently. A
rolling horizon asks the question once per window and rebuilds where the answer
is no, see [`solve_rolling_horizon`](@ref).
"""
function update_model!(nm::NetworkModel, data::NetworkData)
    nw_ids(data) == nm.nws ||
        throw(ArgumentError("this model is posed over network indices $(nm.nws) and the " *
                            "data given is over $(nw_ids(data)); a model is updated in " *
                            "place only by data of the same shape"))

    nm.data = data
    build_model!(nm)

    return nm
end
