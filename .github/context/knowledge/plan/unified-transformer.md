# One `Transformer` for every transformer: windings, tap changers, phase shifters

Status: implemented on `b11-unified-transformer`, awaiting merge (D28-D36 accepted and recorded 2026-10-05/06) · Author: Tom Van Acker · Date: 2026-10-05
Decisions: D28-D36 (next free after: D37) · Priority: P2 · Effort: Large · Backlog: B11 (follow-ups B12, B13)

## Handoff instructions

- Implement on `b11-unified-transformer`, cut from `main` (`01122bd`), one commit per row of the table
  under *Fix*, messages naming the decision (`D31: …`), **no AI attribution**. The Zorba scripts live on
  `test-zorba-run` and are not part of this branch (B12).
- Update the 80-column changelog header of every file touched (`# v0.12.0 - …`). The last commit sets
  `version = "0.12.0"` and writes the `CHANGELOG.md` entry with a migration table. After the merge into
  `main`, create the annotated tag `v0.12.0`, as for v0.9.1-v0.9.7 (D28); ask before pushing it.
- Targeted tests per commit; the full suite once at the end (`JULIA_NUM_THREADS=4`), then the docs build.
- Check `TapMode`, `FIXED`, `CONTINUOUS`, `STEPPED` for name collisions before exporting (as for `Switch`).

## What the literature fixes (`D:\KnowledgeBase\Power System Optimization\Transformer Models in OPF\1-wiki\`)

- **A branch with a tap** is an ideal transformer of complex ratio `T` at the sending end of a π-section:
  `I_tot = (I_s + I_sh)/conj(T)`, series voltage `U_i/T` [Geth & Liu 2022, Eq. (8)-(11), p.2; Coffrin
  et al. 2015, Eq. (34c)-(34d), p.10]. NMB's `vt` variables are this form.
- **One law for magnitude and phase** over an integer position `ψ`: `n_t = n_nom [1 + Δn (ψ - ψ_N)]
  exp(j[φ_N + Δφ (ψ - ψ_N)])` [Gebhardt & Engel 2026, Eq. (2), p.2-3]. A PST is the angle of that ratio as a
  bounded variable [Garcia-Guzman et al. 2013, Eq. (5)-(9), (18), p.2-3]; linearized a shift term, about
  5 % off at 30° [Van Hertem et al., Eq. (10)-(12), p.4]. A discrete tap makes the OPF a MINLP, the hardest
  case to solve [Nickel et al. 2025, §IV, p.5-6].
- **n windings = ideal two-winding transformers + series impedances + shunts**, matching OpenDSS to 3.9e-7
  on IEEE13 [Claeys et al. 2020, §2-3, p.3-6]; without phases a vector group is a fixed `ta`. Core losses
  change the optimum [Hamilton et al. 2023, §V-B, p.8].

## Evidence

**1. Four types, 1,162 lines, for one device; combinations that cannot be built** (run 2026-10-05):

```
PhaseShifter(...; tm_min = 0.9)             MethodError, no keyword tm_min
TapChanger(...; ta_min = -0.1)              MethodError, no keyword ta_min
MultiWindingTransformer(...; tm_min = ...)  MethodError, no keyword tm_min / ta_min
Transformer(...; terminals = [1, 2, 3])     ArgumentError: a two-winding transformer has exactly two
TapChanger(...; tap_pos = 3)                MethodError, no discrete tap anywhere
```

**2. A star with a zero-impedance winding fails in the linearized formulation** (`multi_winding.jl:274`):
`r = 0`, `x = [0.1, 0.0, 0.3]` gives `invalid term NaN * 1_va[2]`; `x = [0.1, 0.2, 0.3]` solves.

**3. Model sizes**, variables/constraints of `OptimalPowerFlowProblem` on case5 with branch 5 rebuilt as
each type. IVR: `Transformer` 82/112, `PhaseShifter` 84/115, `TapChanger` 83/112. LPF: 32/49, 33/49, 32/49.

**4. Who names the types.** `matpower.jl:223` builds `Transformer`; `zorba.jl:397` builds `PhaseShifter`
and `:713` reads `tap["ta"]`; on `test-zorba-run` `SteeringPlanData.jl` (`:140`, `:538`, `:632`) and
`NMinusOneScreen.jl` (`:90`, `:100`) use `PhaseShifter`, `.ta`, `_fields(c)`.

**5. T or π (D30).** The exact T-model has a series arm per winding and the magnetising branch between
them (ElectricalFlux, a general reference). MATPOWER, PowerModels and the QC/SOC papers use the π (one `z`,
`b/2` at each end); Hamilton et al. 2023 use the T (Fig. 4, p.6); `MultiWindingTransformer` already is a T.
A T with a shunt per winding contains the π (`z_2 = 0`, `y_m = 0`, `b_sh = [b/2, b/2]`), so imports stay
exact, and by count costs the same for two windings: `vsr, vsi` replace `csr, csi`, six rows.

## Root cause

The controls are split by type, so a device with two of them cannot exist; the star form has no controls.

## Fix

**Data** (`src/comp/edge/transformer/transformer.jl`, the only file left there; `AbstractTransformer`
stays as the extension point). Sketch, `n = length(terminals) ≥ 2`:

```julia
@enum TapMode FIXED CONTINUOUS STEPPED          # D31, D32; a Bool is accepted: false = FIXED, true = CONTINUOUS
Base.@kwdef struct Transformer <: AbstractTransformer
    id::Int; name::String = ""; terminals::Vector{Int}
    r, x         ::NetworkQuantity{Vector{Float64}}           # series impedance per winding [pu] (D29)
    g_sh, b_sh   ::NetworkQuantity{Vector{Float64}}           # shunt behind each ratio [pu]
    g_m, b_m     ::NetworkQuantity{Float64} = 0.0             # magnetising branch at the star point
    tm, ta       ::NetworkQuantity{Vector{Float64}}           # ratio setpoint per winding
    oltc, pst    ::Vector{TapMode}                            # per winding, static, default FIXED: may the magnitude / the angle move
    tm_min, tm_max, ta_min, ta_max   # per winding; default 0.9..1.1 and ±π/12 as the old types had
    tm_step, ta_step                 # STEPPED: the values are min, min + step, ..., max
    rate_a       ::NetworkQuantity{Vector{Float64}} = Inf     # per terminal
    angmin, angmax, status, ext                               # angle limits: two windings only
end
```

Two windings accept scalars (winding 1, winding 2 neutral, `rate_a` on both). The Matpower reader gives
the from side `tm`/`ta`, `z_2 = 0`, `b_sh = [b/2, b/2]`; the Zorba reader sets `pst` for a row with a phase
shift range. `structure_gates`: `(:rate_a, :angmin, :angmax)`.

**Current-based rows.** Winding `k`, ratio `T_k = tr + j·ti`, `v^t_k` the voltage behind it, `c^t_k = conj(T_k) c_{a_k}`.
- A held ratio is folded into the rows (`v^t_k = conj(T_k) v_i / |T_k|²`; no variable, no row; a unit
  ratio is an alias). A moving one gets edge variables `vtr, vti` and `v_i = T_k v^t_k`.
- `oltc` only: variable `tm ∈ [tm_min, tm_max]`, `T = tm (cos ta, sin ta)`. `pst` only: variables `tr, ti`,
  `tr² + ti² = tm²`, `tan(ta_min) tr ≤ ti ≤ tan(ta_max) tr`, as `PhaseShifter` has today. Both: the same
  with `tm_min² ≤ tr² + ti² ≤ tm_max²` in place of the equality.
- The T-model, for every `n`: `v^t_k - v^s = z_k (c^t_k - y_sh,k v^t_k)` and `Σ_k (c^t_k - y_sh,k v^t_k) =
  y_m v^s`, the star voltage `vsr, vsi` an edge variable, not a node. Start `v^t` through the ratio.

**Linearized rows.** `va^t_k = va_{i_k} - ta_k`; the magnitude does nothing. Two windings eliminate the star
point: `p_{a_1} = -b (va^t_1 - va^t_2)` with `b = susceptance(z_1 + z_2)`, `p_{a_2} = -p_{a_1}`, so a zero
`z_2` is fine. Three or more: `p_{a_k} = -b_k (va^t_k - vas)`, `Σ p_{a_k} = 0`, and `z_k = 0` is an
`ArgumentError` naming the winding (evidence 2).

**Redispatch.** `redispatch_controls` returns the keys a preventive winding holds across contingencies
(`:tm`, `:tr`, `:ti`, `:ta`, `:zt`); one without the variable is skipped, as now. Linearized, the angle keeps
`ta = ta_set + taup - tadn` as today and has no price (D34): `parse_zorba` loses `pst_cost`.

**Stepped windings** (D32). `true` is continuous; `STEPPED` is asked for. `oltc = STEPPED` takes the
magnitudes `tm_min, tm_min + tm_step, …, tm_max`, `pst = STEPPED` the angles likewise; the setpoint must be
one of them. Binaries `zt[a, s]`, `Σ_s zt = 1`, `T = Σ_s zt_s T_s`; both stepped is one set over the pairs;
one stepped and one continuous is an `ArgumentError`. Linearized a MILP; current-based a nonconvex MINLP
(bilinear ratio row, as a free switch, D23). No duals, so prices are `nothing` (D16).

**Solution** (D33). Each terminal entry gets `tap` (`tm`, `ta`; `ta_market`, `taup`, `tadn`; the step index
when stepped): `solution_tables` has `tap_tm`, `tap_ta` per terminal, `zorba.jl:713` reads terminal 1.
**Removed:** the three types, `AbstractTwoWindingTransformer`, `variable_two_winding!`,
`constraint_two_winding_*!`, `solution_tap`. **Changed:** `tap_ratio`, `phase_shift` take a winding.

| # | Commit | Verification |
|---|---|---|
| 1 | Characterization: helpers `fixed`, `pst`, `oltc`, `star` in `test/transformer.jl`; objectives, taps, sizes frozen | green on today's code; a perturbed helper goes red |
| 2 | `variable!` takes any hashable id (an `Arc`); `constraint_redispatch_control` ties each arc's variable | suite green; a toy `Arc`-keyed tie |
| 3 | `Transformer`, the T-model for every `n`, `oltc`/`pst` `FIXED` or `CONTINUOUS` (not both on one winding); both formulations; redispatch; solution; Matpower, Zorba, table readers; four files become one; helpers swapped | step 1 numbers unchanged; IVR 78/108, 82/113, 81/110 (a held ratio is folded, and case5 has two transformers), LPF 32/49, 33/49, 32/49, redispatch LPF 19/20 (no `taup`/`tadn`); three windings equal their decomposition; PowerModels' ACP equals on case5 (a shift), PowerModels' IVR has no row for a shifted branch |
| 4 | `oltc` and `pst` on one winding; controls on any winding of `n ≥ 3` | objective ≤ the best single-control run; preventive tie over a three-winding winding |
| 5 | `STEPPED` | optimum equals the best of all enumerated fixed runs (HiGHS linearized, Juniper current-based, small); no duals; a held winding reuses the base case's binaries (D36) |
| 6 | Docs (`transformer.md`, hierarchy, 13 other pages, README, `refs.bib`), `CHANGELOG.md`, 0.12.0 | `docs/make.jl`, `test/docs.jl`, full suite |

## Verification

- Commit 3 is parity: the helpers change, never the assertions; sizes move only where stated (82/112 to 80/110).
- Decomposition oracle (Claeys): three windings with ratios equal three two-winding transformers meeting
  at a real fourth node (the magnetising branch a `Shunt`), in current-based load flow and linearized OPF, to 1e-8.

## What this deliberately does not decide

- B12: moving `test-zorba-run` to `Transformer`. B13: a datasheet constructor (winding resistances, pairwise
  short-circuit reactances, no-load power) and a mesh for four or more windings (Claeys' Algorithm 1).
- Non-uniform PST tap tables; tap-dependent impedance; a price on moving a tap or an angle (D34); a PST flow target
  (`P_ij = P_esp`); sequential rounding for `STEPPED`; phases, delta windings, convex relaxations.

## Decisions (recorded in `decisions.md`)

| Id | Decision | Status |
|---|---|---|
| D28 | One `Transformer` replaces the four types; no shims for the old names; 0.12.0, tagged `v0.12.0` | accepted, Tom |
| D29 | Per-winding vectors for `n ≥ 2`; scalar shorthand for two windings | accepted, Tom |
| D30 | Every transformer is a T: windings with ratio and impedance meeting at a star point with the magnetising branch; the π is `y_m = 0`, `z_2 = 0` (evidence 5) | accepted, Tom (was a π for two windings) |
| D31 | `oltc` and `pst` per winding, static, for magnitude and angle; the enum `TapMode`, a `Bool` accepted: `false` is `FIXED`, `true` is `CONTINUOUS` | accepted, Tom |
| D32 | Stepped windings in this branch, last; the default is continuous; `STEPPED` is asked for | accepted, Tom |
| D33 | `tap` reported per terminal | accepted, Tom |
| D34 | `oltc` and `pst` are non-costly measures for now: no `cost`, no `pst_cost`; may change | accepted, Tom |
