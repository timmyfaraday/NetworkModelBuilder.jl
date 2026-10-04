# A `Switch` edge type: couplers and breakers without an impedance

Status: draft · Author: Tom Van Acker · Date: 2026-10-04 · Decisions: D13, D15-D25 (next free after: D26)
Priority: P2 · Effort: Large · Backlog: B5 (follow-ups B7)

## Handoff instructions

- Implement on `b5-switch-edge`, cut from `main`, one commit per item of the table under *Fix*. The
  Zorba scripts live on `test-zorba-run` and are not part of this branch; do not copy them here.
- Commit messages name the decision (`D17: …`) where there is one, and carry **no AI attribution**.
- Update the 80-column per-file changelog header of every file touched. The last commit sets
  `version = "0.11.0"` in `Project.toml` (D20, a minor bump) and adds the `CHANGELOG.md` entry.
- Targeted tests per commit; the full suite once at the end with `JULIA_NUM_THREADS=4`.
- Juniper is already in `Project.toml` (`[extras]` and `[targets]`); `import Juniper` in the test
  files and call `Juniper.Optimizer`, as PowerModels is (D5).
- Do not define functions named `lock` or `position`: both are `Base` functions. The fields are fine.
  `Switch`, `AbstractSwitch`, `SwitchLock`, `FREE`, `LOCKED` and `islands` collide with nothing in
  JuMP, HiGHS, Ipopt, Juniper, PowerModels or `Base` (checked 2026-10-04).

## Evidence

**1. A coupler is a branch with x = 1e-7 today.** The Zorba export has 21 busbar couplers, loaded as
`Branch` with reactance 1e-7. [`susceptance`](src/comp/edge/pi_model.jl#L206) is `-x/(r²+x²)`, so
1e7 against about 60 for an ordinary line. `lessons.md`: Xpress returned a false `INFEASIBLE` at
hour 61 of step 3 and `OPTIMAL` vectors that broke node balance by up to 32 pu; flooring the
reactance at 1e-5 removed every violation, at the price of moving monitored flows (99th percentile
0.22 % of rating, maximum 2.2 %). Babaeinejadsarookolaee et al. 2021 regularise a breaker the same
way (closed susceptance 1e5, open 1e-2); Goldis et al. 2017 model it exactly (angle equality and a
free flow variable). Neither paper discusses solver conditioning.

**2. A loop of closed switches leaves the flow to the solver.** Throwaway run (nodes 1 gen/ref, 2,
3 with a load of 1 pu; line 1-2; two parallel closed zero-impedance switches 2-3; both angle
equalities written):

```
HiGHS simplex / primal simplex / ipm       p_s1 = 1.0   p_s2 = 0.0
Ipopt                                      p_s1 = 0.5   p_s2 = 0.5
one equality + loop row p_s1 - p_s2 = 0    0.5 / 0.5 in HiGHS simplex, HiGHS ipm and Ipopt
```

Ipopt took 5 iterations with the redundant rows and 1 with the loop row; the redundant rows broke
no solver on this toy. Larger IVR models are untested.

**3. An island with a load and no source is not diagnosed.** case14 with branches 9-14 and 13-14
out of service (bus 14: 14.9 MW load, no generator), run on the current code:

```
OPF  LPF HiGHS    INFEASIBLE          LF  LPF HiGHS    INFEASIBLE
OPF  IVR Ipopt    LOCALLY_INFEASIBLE  LF  IVR Ipopt    LOCALLY_SOLVED, vm at bus 14 = 1.39e6 pu
```

The last line is a false solution: the voltage is pushed to infinity so that the constant-power load
draws no current. It needs no switch, any contingency or open edge can cause it.

**4. What the code gives and lacks.**
- `status` is the in-service flag: [network.jl](src/core/network.jl#L56), `is_active`
  ([L70](src/core/network.jl#L70)), the varying-status list ([L256](src/core/network.jl#L256)), and
  `ids` drops an out-of-service edge with its arcs.
- No integer variable exists. `variable!` ([rebuild.jl](src/core/rebuild.jl#L126)) has no binary
  option; [tap_changer.jl](src/comp/edge/transformer/tap_changer.jl#L28) avoids integers on purpose;
  duals are already guarded by `JuMP.has_duals` ([node.jl](src/comp/node/node.jl#L371)).
- Model reuse compares `structure_gates` fields through `_gate` ([window.jl](src/core/window.jl#L349)),
  `(isfinite(x), -π/2 < x < π/2)`: it says 0 and 1 are the same shape. A `position` that changes the
  rows would leave a stale model after `update_model!`.
- Builders run per network index: `variable_edge`, `constraint_edge`, `constraint_edge_limits`
  ([opf.jl](src/prob/opf.jl#L46)); `instantiate_model` ([model.jl](src/core/model.jl#L207)) is the one
  place every problem and every rolling window passes through.
- Precedent for a control that is data in a power flow and a variable in a dispatch problem:
  [phase_shifter.jl](src/comp/edge/transformer/phase_shifter.jl#L158) and
  [dc_link.jl](src/comp/edge/dc_link/dc_link.jl#L207). `redispatch_controls`
  ([phase_shifter.jl](src/comp/edge/transformer/phase_shifter.jl#L194)) ties a preventive measure
  across contingencies, and `_control_variable` ([rd.jl](src/prob/rd.jl#L145)) skips a component that has
  no such variable.
- Tabular input already parses enums (`_enum`, [tables.jl](src/io/tables.jl#L270)), as for `NodeType`.
- PowerModels 0.21.6 has the same physics: closed `va_fr == va_to` (`form/dcp.jl:150`), open
  `psw == 0` (`core/constraint.jl:162`), controllable `psw ≤ psw_ub·z` with a binary `z_switch`
  (`core/constraint.jl:177`) and `0 ≤ Δva + vad_max(1−z)` (`form/dcp.jl:157`). Its problems
  `_solve_opf_sw` and `_solve_oswpf` are underscore-prefixed (`prob/test.jl:48`, `:93`).

## Root cause

Every edge is either a π-equivalent ([branch.jl](src/comp/edge/branch/branch.jl)) or something
else with its own physics, and none can say "the two ends have the same voltage and any flow passes"
or "nothing passes and the ends are independent". A coupler can only be a branch with a very small
impedance, which is the badly scaled matrix of evidence 1.

## Fix

**Data** (`src/comp/edge/switch/switch.jl`, which loads first, then registered with
`register_edge_type!`).

```julia
@enum SwitchLock FREE = 1 LOCKED = 2                         # D25
abstract type AbstractSwitch <: AbstractEdge end
Base.@kwdef struct Switch <: AbstractSwitch
    id::Int;  name::String = "";  terminals::Vector{Int}      # exactly two (D24)
    lock    ::SwitchLock               = LOCKED               # D15, not network dependent
    position::NetworkQuantity{Int}     = 1                    # 0 open, 1 closed
    rate_a  ::NetworkQuantity{Float64} = Inf                  # equipment limit, D17
    angmin  ::NetworkQuantity{Float64} = -pi                  # angle difference allowed when open
    angmax  ::NetworkQuantity{Float64} =  pi
    status  ::NetworkQuantity{Bool}    = true                 # in service, as every component
    ext     ::Dict{Symbol,Any}         = Dict{Symbol,Any}()
end
structure_gates(::AbstractSwitch) = (:rate_a, :position)
```

The constructor checks two terminals, `position ∈ {0, 1}` at every index, `angmin ≤ 0 ≤ angmax`
and `rate_a ≥ 0`. `_gate(x::Integer) = x` is added to `window.jl` so that two positions are two
shapes. A `FREE` switch in a dispatch problem with an infinite `rate_a` is an error at build time.

**Rows, linearised formulation** (`i`, `j` the nodes, `a_f`, `a_t` the arcs, `z` the position).
Always `p[a_t] == -p[a_f]`.

| switch | rows |
|---|---|
| locked, closed | `va[i] == va[j]`; if `rate_a` is finite and the problem is a dispatch one, `-rate_a ≤ p[a_f] ≤ rate_a` |
| locked, open | `p[a_f] == 0` |
| free (dispatch only) | binary `zsw[e]`; `angmin(1-z) ≤ va[i]-va[j] ≤ angmax(1-z)`; `-rate_a·z ≤ p[a_f] ≤ rate_a·z` |

A load flow never creates `zsw`: every switch is locked there, and has no rating, as for a branch.
Locked switches keep a dispatch problem a linear program, so prices survive (D16).

**Rows, current-based formulation.** Always `cr[a_t] == -cr[a_f]` and `ci[a_t] == -ci[a_f]`.
Locked closed: `vr[i] == vr[j]`, `vi[i] == vi[j]`, and the rating `(vr²+vi²)(cr²+ci²) ≤ rate_a²` per
terminal, written whether or not the edge is monitored. Locked open: `cr[a_f] == ci[a_f] == 0`.
Free: `|vr[i]-vr[j]| ≤ M(1-z)`, `|vi[i]-vi[j]| ≤ M(1-z)` with `M = 2·max(vmax_i, vmax_j)`, and
`|cr[a_f]|, |ci[a_f]| ≤ C·z` with `C = rate_a / min(vmin_i, vmin_j)`. The rating makes it a
nonconvex mixed-integer program: building it is supported, solving needs such a solver (D23).

**Loops** (D21). For each connected group of locked-closed switches at an index, take a spanning
tree by ascending id (union-find). Tree switches keep their equalities. Each other switch loses its
equality and gets one row `Σ σ_s p[a_f(s)] == 0` around its fundamental cycle, `σ_s = ±1` by the
direction the cycle crosses `s` (in the current-based formulation the same on `cr` and on `ci`).
Parallel switches then split evenly. A free switch writes no equality and needs none; the flows it
reports in a closed loop may differ between solvers, and normalising them afterwards is not done.

**Islands** (D22). `islands(data; nw, without = ())` returns the connected node sets at an index; an
edge counts as joining its terminals when `connects(dim, edge, n)` says so (every edge, except a
switch locked open), an out-of-service edge counts as absent and a free switch as present
(`can_open(dim, edge, n)`, true only for a free switch, names what the problem may open). In
`instantiate_model` (`check_islands`), once per distinct topology and set of locked-open edges: an
island with units but no `REF` node and no in-service generator, storage or unserved-energy unit
(a `Spill` only absorbs, so it is not a source) is an `ArgumentError` naming its nodes; an island
with a source but no `REF` node has its lowest node anchored by `constraint_node_voltage_anchor`
(`va == 0`; `vi == 0` and `vr >= 0` in the current-based formulation), called from
`constraint_node_voltage_reference`; and if opening every free switch splits an island, it is an
`ArgumentError` naming the switches and the pieces, unless `instantiate_model(...; islanding =
:allow)`. `islanding = :allow` leaves the first check in force.

**Hooks.** `redispatch_controls(nm, ::Type{<:AbstractSwitch}) = (:zsw,)`: a preventive free switch
is held equal across contingencies, a corrective one (by `Redispatch`'s `exception`) is not, and a
locked one has no variable to tie. No `redispatch_cost` method, so a move is free (D18).
`solution_edge!` adds `"position"` (the data, or the rounded `zsw`) and `"lock"`.
`variable!` gets `binary::Bool = false`; a free switch's `zsw` starts at its data `position`.

| # | Commit | Verification |
|---|---|---|
| 1 | `variable!` binary option; `_gate(::Integer)` | binary variable survives `update_model!`; two positions are two shapes |
| 2 | `AbstractSwitch`, `Switch`, constructor, registration | constructor errors; `ids`; tables round trip with `lock` |
| 3 | `islands`, the checks in `instantiate_model` | evidence 3 now errors; the anchor; the free-switch check and its opt-out |
| 4 | locked switch, linearised, with loops | closed equals merged, open equals removed; evidence 2 gives 0.5/0.5 on HiGHS and Ipopt |
| 5 | free switch, linearised | optimum equals the best of all `2^k` locked runs; prices are `nothing` |
| 6 | current-based formulation | locked equals merged/removed; free: row counts, relax-and-fix equals locked under Ipopt, small Juniper solve |
| 7 | `redispatch_controls`, `solution_edge!` | a preventive free switch has one position over all contingencies |
| 8 | PowerModels cross-check | `_solve_opf_sw` and `_solve_oswpf` objectives equal, behind an `isdefined` guard |
| 9 | docs page, hierarchy and README trees, `CHANGELOG.md`, 0.11.0 | `docs/make.jl` and `test/docs.jl` run the `@example` |

## Verification

- `test/switch.jl`, included from `runtests.jl`. Closed equals merged and open equals removed use
  case14 with one branch replaced by a switch, in both formulations: same objective, same flows on
  the other edges, to 1e-6.
- Free switches: three free switches on case14, eight locked runs, the minimum equals the mixed
  integer objective (HiGHS). A locked-only dispatch problem has `JuMP.has_duals`; a free one does not.
- A rolling horizon over a locked switch whose position changes at hour 5 equals independent
  solves, and `same_structure` is false across the change.
- Island cases from evidence 3 as tests; the IVR load flow must error rather than return 1.39e6 pu.
- Loop cases: two parallel switches, and a triangle of three.
- After merging into `main`, on `test-zorba-run`: load the 21 couplers as locked-closed switches
  and drop `min_reactance`. Week 1 must solve with no violation at exact zero impedance, with
  results within the 2.2 % the floor moved flows.

## What this deliberately does not decide

- Closed switches as merged nodes: B7.
- `BusbarSwitch`, `CircuitBreaker` (D19) and a multi-terminal switch (D24).
- A switching cost, and normalising the flows a free loop reports.
- Tight big-M values from the network (the shortest-path bound of Pineda et al.); `angmin`/`angmax`
  and `rate_a` are the data until then.
- An exact connectivity constraint for free switches, instead of the conservative check.
- The Zorba loader change, which belongs on `test-zorba-run`.
