# A branch with more than two terminals (B30, stage 2)

Status: decided (D53), not started · Author: Tom Van Acker (requested) · Date: 2026-10-10
Decisions: D53 recorded 2026-10-10 (next free after: D54); one point to confirm, the field names
Priority: P3 · Effort: Large. Second stage of B30, on `b30-one-branch` after parts 1 to 3 of `one-branch.md`; v0.13.0.

## Handoff instructions

- Start only when parts 1 to 3 of `one-branch.md` are green and the 24 h chunk is byte-identical: the stage changes the fields of
  every `Branch`, and that chunk is what proves a two-terminal branch did not move.
- One commit per part, tests first and red, no AI attribution; headers, `CHANGELOG.md` and the docs follow `one-branch.md`.
- If a stop rule below fires, stop and report: the stage can be split off as its own item without touching stages 1 to 3.

## Evidence

- **A branch has exactly two terminals today** (`_check_branch`, `branch.jl:92`), every field is a scalar (`branch.jl:67-81`),
  `constraint_pi_section!` writes one π (`pi_model.jl:53-79`) and `constraint_linear_flow!` one flow between two arcs.
- **The graph already carries more.** `edge_arcs` returns one `Arc(e, t, i)` per terminal; the `Transformer` has two or more
  windings; `test/multiterminal.jl` adds a three-terminal `StarEdge` from outside the package and checks it against its
  two-terminal equivalent. What is missing is a branch that has them.
- **The model (Tom Van Acker):** `n` π-sections coupled at one point, section `k` from terminal `k` to the point, the shunts at
  the point aggregated. Its equations, with `y_fr,k` the terminal-side and `y_to,k` the point-side shunt of section `k`:

  ```math
  c_k = y_{\text{fr},k} v_k + c^{\text{s}}_k, \quad v_k - v^{\text{p}} = z_k c^{\text{s}}_k, \quad
  \sum_k c^{\text{s}}_k = \Big( \sum_k y_{\text{to},k} \Big) v^{\text{p}} .
  ```

  These are the equations of the transformer's star with neutral ratios, `y_sh,k = y_fr,k` and `y_m = Σ y_to,k`
  (`transformer.jl:557-595`), so a three-terminal branch and that transformer must agree: a live reference for the new code.
- **Cost, measured today** (`scratch/b30_construct.jl`): building a `Branch` is 46 ns and 160 B, a `Transformer`, which has vector
  fields, 584 ns and 1,664 B. Six vector fields on a `Branch` cost a few hundred ns a build: an estimate of at most 0.5 ms on a
  7.5 ms step-3 window cut, not a run. The Zorba model has 399 branches and none with more than two terminals.
- **The conventions to follow** are D29 and `_per_winding` (`transformer.jl:190`): a vector with one entry per terminal, a scalar
  standing for the first of two, a rating applying to every terminal.

## Fix

1. **Fields.** `terminals` has two or more entries. `r`, `x`, `g_fr`, `b_fr`, `g_to`, `b_to` and `rate_a` are
   `NetworkQuantity{Vector{Float64}}` with one entry per terminal, entry `k` belonging to section `k`; the names are kept, so
   `matpower.jl:213`, `zorba.jl:400`, `scripts/` and `benchmark/window.jl:68` build as before. For two terminals a scalar stands for
   the first entry and the second is 0, a scalar `rate_a` for every terminal. `angmin`, `angmax`, `length_km` and `status` stay
   scalars; the angle limit applies to a two-terminal branch only, as it does to a transformer. `_per_winding` becomes
   `_per_terminal(x, n, neutral, kind, id, field; every)` in `edge.jl`, the transformer's messages unchanged.
2. **Checks** (`all_nw`, as D48). Every entry finite; `rate_a >= 0`; `r_k² + x_k² > 0` for every section that exists, which is the
   first for two terminals and all for more; a two-terminal branch has one section, so its second entries must be 0 (a branch
   whose second section carries something has three terminals); `angmin <= angmax`.
3. **Two terminals are the π as today.** `constraint_pi_section!` takes the to-side voltage and current as it takes the from side,
   so one function writes every section; the two-terminal call passes `vr[j]` and `cr[a_to]` and writes the same six rows. In the
   linearized formulation `susceptance(sum(r), sum(x))`, exactly `r` and `x` where the second entry is 0.
4. **More than two terminals.** IVR: a point voltage per branch, `vpr[e]` and `vpi[e]`; a series current per section, `scr[a]`
   and `sci[a]`, keyed by its `Arc`; the six rows of a section against the point; the balance `Σ c^s_k = (Σ y_to,k) v^p`.
   LPF: a point angle `vap[e]`, `p_k = -b_k (va_k - vap)`, `Σ p_k = 0`, the shunts playing no part. The keys are new: D49 refuses
   `:csr`, `:csi` (keyed by edge) for variables keyed by an `Arc`, and `:vsr`, `:vsi`, `:vas` are the transformer's. Limits: the
   ratings of `constraint_linear_ratings!` and `constraint_edge_rating!`, the angle limit for two terminals only.
5. **Docs.** `branch.md` (per-terminal parameters, a section on more than two terminals with the equations and the variable
   tables), `AbstractBranch` and `Branch` docstrings, `README.md` (its Matpower table says a branch has two terminals),
   `hierarchy.md`.

## Decisions

- **D53 (Tom Van Acker, recorded 2026-10-10):** a `Branch` has two or more terminals, as `n` π-sections coupled at one point with
  the shunts there aggregated, two terminals being the single π as today; its fields are vectors with one entry per terminal as a
  transformer's are (D29), over keeping two terminals only and over a star of the transformer's; one item with two stages, over
  two items. To confirm: that the names `r`, `x`, `g_fr`, `b_fr`, `g_to`, `b_to` stay (the plan offered `g_sh`, `b_sh`).

## Verification

- Red on the sources of stage 1: a three-terminal `Branch` raises today (`exactly two`); `Branch(; r = [..], x = [..])` of two
  entries with a nonzero second one is refused; a scalar `rate_a` reads as one entry per terminal.
- **The reference:** a three-terminal `Branch` against the `Transformer` with neutral ratios, `g_sh = g_fr`, `b_sh = b_fr`,
  `g_m = sum(g_to)`, `b_m = sum(b_to)`: node voltages in a load flow and an OPF in `IVRFormulation`, angles and objective in
  `LPFFormulation`, flows at every terminal, within 1e-8; one case with an overload price. Added to `test/multiterminal.jl`.
- Nothing moves for two terminals: the suite and `test/powermodels.jl` unchanged, `test/hot_path.jl` still allocation free for a
  branch, and the 24 h chunk byte-identical again after this stage.
- Cost: `scratch/b23_cost.jl` window cut at most 8.0 ms; `benchmark/window.jl` update within 2 % of a same-day control.

## Stop rule

If the window cut is above 8.0 ms, or the chunk is not byte-identical, look first at `_per_terminal`: it allocates a vector per
field each time a `Branch` is built. If a `NetworkVector` holding vectors cannot be read through `nw_component` or
`structure_gates` for a branch the way it is for a transformer, stop and report.

## What this deliberately does not decide

- A branch whose sections carry different `length_km`: the length stays one number for the whole line.
- The `Transformer` is not rewritten onto the branch; both are checked against each other and stay two models.
- A zero-impedance section (a terminal at the point itself): refused by D48's rule for now.
- Q7, the export surface: `impedance` and `shunt_admittance` keep their names and return one entry per terminal.
