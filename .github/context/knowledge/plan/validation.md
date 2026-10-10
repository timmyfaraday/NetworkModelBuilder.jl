# Constructors refuse input a model cannot use (B23)

Status: implemented on `b23-validation` (v0.12.8), measured, not merged · Author: Tom Van Acker (requested) · Date: 2026-10-10
Decisions: D48 recorded 2026-10-10 (next free after: D49); no open question
Priority: P2 · Effort: Medium. Branch `b23-validation`, cut from `main` at `9e33c53` (v0.12.7);
becomes v0.12.8. Fourth move of the review `julia-guide-review.md`, item 3.

## Handoff instructions

- Implement on `b23-validation`, one commit per family (node; generator, load and shunt; branch family), the test
  first and red, no AI attribution.
- Per-file changelog header (80 columns) on every `src/` and `test/` file touched, `Project.toml` 0.12.8,
  `CHANGELOG.md` under Changed: it refuses input that used to build.
- The style is `_check_branch` and `_check_switch`: a `_check_<type>` called from the inner constructor, `all_nw` for
  every field that may be a `NetworkVector`, `ArgumentError("generator $id has pmin above pmax")`. One sentence
  in the struct's docstring says what it refuses. No decision id in a comment.

## Evidence

- **19 of 19 invalid inputs are accepted today** (`scratch/b23_probe.jl`, current `main`): `Generator` with `pmin 2 >
  pmax 1`, `qmin 1 > qmax -1`, `pmax`, `pg` or a cost coefficient NaN; `Node` with `vmin 1.1 > vmax 0.9`, `vmin -1`,
  `base_kv -380`, `vm` NaN; `FixedLoad` with `pd` NaN or `qd` Inf; `Shunt` with `bs` NaN; `Branch` with `r` NaN,
  `r = x = 0`, `rate_a` -1 or NaN, `b_fr` NaN; `Cable` with `length_km -5`, `OverheadLine` with NaN. A generator
  with `pmin 3 > pmax 1` in case5 gives an OPF `INFEASIBLE` with nothing pointing at it (review item 3).
- Seven inputs that must stay accepted are: `Node(base_kv = 0)`, `vmin = 0`, `Generator(qmin = -Inf, pmax = Inf)`,
  `cost_up = NaN` (its default, the marginal cost), `Branch(rate_a = Inf)`, a pure resistor `r = 0.01, x = 0`, and a
  series capacitor `x = -0.05`.
- **The rules against real data** (`scratch/b23_audit.jl`): case3, case5 and `switch_loop` break none. case14 breaks
  `base_kv > 0` on 14 of 14 nodes (`baseKV` is 0 in `case14.m`). The Zorba data, 8,760 hours, 234 nodes, 93
  generators, 234 loads, 399 branches, breaks none of 23 candidate rules, `pmin <= pg <= pmax` and the signs of `r`
  and `x` included.
- `susceptance(r, x) = -x / (r^2 + x^2)` (`src/comp/edge/pi_model.jl:219`) is 0/0 at `r = x = 0`; `r != 0, x = 0`
  gives 0, a pure resistor. D13: a coupler is a `Switch`, not a branch of near-zero impedance.
- Today's validators: `_check_branch` (`branch.jl:85`, terminals and angles), `_check_switch`, `_check_transformer`,
  `Storage`, `DCLink`, the slack units, `FlexibleLoad` (`pd_min <= pd_max`), `Generator` (the energy limit only).
  `Node`, `FixedLoad`, `Shunt` have none.
- **A constructor runs on every rebuild.** A window rebuilds the components that carry network data: 1,437 of
  2,050 on step 3. Cutting a real window takes 7.7 ms (80 network indices; step 2: 5.8 ms, 112 indices) against
  seconds a window (`scratch/b23_cost.jl`), so a few more `all_nw` scans are not a cost, but they are measured.

## Root cause

`Node`, `Generator`, `FixedLoad`, `Shunt` and the branch family validate terminals, angles or one energy limit and
nothing else, so an impossible value travels to the solver, which answers `INFEASIBLE`, or to a `NaN` in a row.

## Fix

1. **Node:** `_check_node`: `0 <= vmin <= vmax`, `base_kv >= 0` (0 is unknown, case14), `vm` and `va` finite.
2. **Generator:** `_check_generator`: `pmin <= pmax`, `qmin <= qmax` (`all_nw`, `-Inf` and `Inf` allowed), no NaN in
   `pmin`, `pmax`, `qmin`, `qmax`, `pg`, `qg` and `vg` finite, every `cost` coefficient finite, the energy limit
   as today. `cost_up` and `cost_dn` are not checked, NaN is their default.
3. **FixedLoad and Shunt:** `pd`, `qd`, `gs`, `bs` finite.
4. **The branch family:** `_check_branch` takes `r`, `x`, the four shunt admittances and `rate_a` too: `r` and `x`
   finite, `r^2 + x^2 > 0` with a message that says to use a `Switch` for a coupler, admittances finite,
   `rate_a >= 0` (`Inf` is unlimited, NaN is refused). `Cable` and `OverheadLine` also check `length_km` finite
   and `>= 0`.
5. Not checked, on purpose: the signs of `r` and `x`, `pg` against its limits, `status`, anything of a type the
   package does not own.

## Decisions

- **D48, recorded 2026-10-10 (Tom Van Acker):** the set above over a smaller one (ordered limits and NaN only) and
  a larger one (signs of `r` and `x`, `pg` inside its limits); every component is validated, in service or not;
  v0.12.8, a patch, not v0.13.0.

## Verification

- `test/validation.jl`, new: one `@test_throws ArgumentError` per refusal, the 19 inputs of the probe, and for
  each family one with the bad value at a single network index of a `NetworkVector`; the seven inputs that must stay
  accepted, with `case14`'s `base_kv = 0` through `parse_file`. Red against today's sources (19 not thrown), green after.
- The full suite with `$env:JULIA_NUM_THREADS = '4'`, the docs build.
- The pipeline: a 24 h chunk (`NMB_HOURS = 1:24`) on the branch against `runs/_b25_proc/chunks/h00001-00024`:
  every file byte-identical, the objectives equal. The data pass through `restrict_to_belgium!`,
  `add_load_shedding!`, `freeze_dispatch` and `with_contingencies`, which rebuild components, so this is what shows
  a rule refusing something the pipeline makes.
- The cost: `scratch/b23_cost.jl` before and after; `window()` on a real step-3 window stays under 16 ms (7.7 ms today).

## Commit order

1. `test/validation.jl` with the node rules, red; `_check_node`, green.
2. The generator, load and shunt rules, the same way.
3. The branch family and `length_km`, the same way.
4. `Project.toml` 0.12.8, `CHANGELOG.md`, headers, the docstring sentences; after the runs STATE and B23.

## Stop rule

If a bundled case, a test fixture, a documentation example or the Zorba chunk is refused by a rule, the rule is wrong
and not the data: stop and report, it is a decision. If `window()` goes over 16 ms, look at `all_nw` first (it
builds a generator per element) before dropping a rule.

## What this deliberately does not decide

- A `validate(data)` for whole-network consistency (a node nobody connects to, a unit on a missing node): another
  question, `Network` already refuses an edge to a node it does not have.
- The messages of `parse_tables` and the Matpower reader, which will now show these errors from inside a
  constructor with the component id; a reader that names the row is a later change.
- Types the package does not own: `docs/src/manual/extending.md` could show a `_check_` of its own.

## Result (2026-10-10)

- Commits `f2b4d54` (node), `59a68df` (generator, load, shunt), `1ed12c7` (branch family), `5413359` (0.12.8); suite 3295
  with 4 threads, docs build clean.
- `test/validation.jl`, 72 checks: 12 of the node checks, 25 of the generator, load and shunt ones and 20 of the branch
  ones failed or errored on the sources before; all pass. The seven inputs that must stay valid are tested.
- The Zorba year loads through the new constructors in 36 s and breaks none of the 23 rules, as before.
- Cost: `window()` on a real step-3 window 7.5 ms (7.7 before, stop rule 16), step 2 5.8 ms (5.8). `window` rebuilds
  through the positional constructor, so the checks run there; they are cheap because `_slice` collapses a vector of
  equal values to a scalar.
- Pipeline: a 24 h chunk (`runs/_b23_check`) against `runs/_b25_proc/chunks/h00001-00024`: all seven files
  byte-identical, objectives 317,686,796.800330 and 308,105,792.250268 equal.
