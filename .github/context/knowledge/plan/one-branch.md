# One `Branch`, and the fragments in the file that owns them (B30)

Status: decided (D50, D51), not started · Author: Tom Van Acker (requested) · Date: 2026-10-10
Decisions: D50, D51 recorded 2026-10-10 (next free after: D52); one open point, the default of `length_km`
Priority: P3 · Effort: Medium. Branch `b30-one-branch`, cut from `main` at `b577b4a` (v0.12.9);
becomes v0.13.0.

## Handoff instructions

- Implement on `b30-one-branch`, one commit per part, tests first and red where a test can be, no AI attribution.
  The first commit carries the bookkeeping the B24 merge left (STATE, backlog, plan index say `b577b4a`, `v0.12.9`).
- Per-file changelog header (80 columns) on every `src/` and `test/` file touched, `Project.toml` 0.13.0, `CHANGELOG.md`
  under Changed and Removed. Compute the padded header lines, then re-read the file (`lessons.md`).
- Move code with the edit tools, never by rewriting a file through PowerShell (`lessons.md`: encoding).
- Targeted tests per commit, the full suite once with `$env:JULIA_NUM_THREADS = '4'`, the docs build.

## Evidence

- **`Cable` and `OverheadLine` are `Branch` plus one field, and the same as each other.** Run today
  (`scratch/b30_probe.jl`): `fieldnames(Branch)` is `id name terminals r x g_fr b_fr g_to b_to rate_a angmin angmax status ext`;
  `setdiff(fieldnames(Cable), fieldnames(Branch))` and the same for `OverheadLine` are both `[:length_km]`.
  `cable.jl` (66 lines) and `overhead_line.jl` (73) repeat the 15-field struct and its constructor of `branch.jl`.
- **Nothing in `src/` uses the difference.** No method dispatches on `Cable` or `OverheadLine`; the only method written for
  either is `dynamic_rating(ohl::OverheadLine) = ohl.rate_a` (`overhead_line.jl:73`), an identity accessor with no caller in
  `src/`, `test/`, `scripts/`, `benchmark/`, `ext/` or `docs/`. `length_km` is read by `_check_length` and by nothing else, and `_check_length` refuses NaN today.
  No reader builds either: Matpower (`matpower.jl:232`) and Zorba (`zorba.jl:400`) build `Branch`, as do `scripts/` and
  `benchmark/window.jl:68`. Only tests do: `hierarchy.jl:50-51,64,72-86`, `lpf.jl:152-160`, `validation.jl:125-129,147`.
- **It costs nothing measurable.** `ids(nm, Cable; nw = 1)` on case14 is 268 ns, and the edge dispatchers (variables,
  constraints, limits, solution) visit it and `OverheadLine` once per network index each: about 0.2 ms of a 1,171 ms step-3
  update (an estimate, 80 indices x 4 x 2 x 268 ns, not a run). Not a speed item.
- **The invariant already says so.** `domain-invariants.instructions.md:26-28`: "A type earns its place by changing the
  model ... `Cable` and `OverheadLine` are electrically identical to `Branch`; don't add a type that changes no variable or
  constraint relative to its parent." `hierarchy.md:72-75` says they "pay for themselves as soon as a rating follows the
  weather or a planning problem costs a route": neither exists, and `rate_a` may be a `NetworkVector` on any branch today.
- **`pi_model.jl` (332 lines) is three things.** Its comment (`:21-31`) says a transformer calls `constraint_pi_section!`; it
  does not, `transformer.jl:566-591` writes its own. Who calls what (grep over `src/`, `test/`, `docs/`, `scripts/`):

  | in `pi_model.jl` | called by |
  |:--|:--|
  | `constraint_pi_section!`, `variable_edge_series_current` | `branch.jl` only |
  | `constraint_edge_rating!` (`_rating_at`, `_any_finite`), `variable_edge_overload!`, `constraint_edge_angle_difference!`, `susceptance`, `constraint_linear_flow!`, `constraint_linear_limits!` (`_linear_rating!`) | `branch.jl` and `transformer.jl` (`:662,664,807-821,850`); `susceptance` also `test/arc_controls.jl:59` |
  | `constraint_linear_ratings!` | `transformer.jl:852` only |

- **The family file is where the shared function lives on the unit side.** `constraint_unit_power!` (`unit.jl:165`), used by
  every generator, load and storage unit, is in `unit/unit.jl`, not in a component's file.
- **Lines today:** `edge.jl` 294, `pi_model.jl` 332, `branch.jl` 274, `transformer.jl` 935.

## Root cause

A type was added to carry a label (construction, and a rating that follows the weather) before anything needed it, and the
branch physics was put in a file of its own because a transformer was going to call it; the transformer ended up calling part
of it and writing the rest itself.

## Fix

1. **One `Branch`.** `branch.jl` keeps `AbstractBranch` (the extension hook; methods stay on `T<:AbstractBranch`) and `Branch`,
   which gains `length_km::Float64 = 0.0` between `angmax` and `status`, checked by `_check_length` in its constructor: a
   length is NaN, which means unknown, or `>= 0`; a negative one and `Inf` are refused. `Cable` refused NaN too, so this
   changes D48. `cable.jl` and `overhead_line.jl` are deleted, `Cable` and `OverheadLine` are no longer registered or
   exported; `edge_types()` is `Branch`, `DCLink`, `Switch`, `Transformer`. `dynamic_rating(br::AbstractBranch) = br.rate_a`
   stays, exported, with its own docstring. The `Branch` docstring says a cable and an overhead line are a `Branch`, and
   that a `NetworkVector` over `:time` in `rate_a` is a rating that follows the weather.
2. **Shared fragments go to `edge.jl`.** A new section there holds `constraint_edge_rating!`, `_rating_at`, `_any_finite`,
   `variable_edge_overload!`, `constraint_edge_angle_difference!`, `susceptance`, `constraint_linear_flow!`,
   `constraint_linear_limits!` and `_linear_rating!`, verbatim, with their exports. Branch-only code moves to `branch.jl`:
   `constraint_pi_section!` and `variable_edge_series_current`, with the comment that only a branch writes its π-section.
   Transformer-only code moves to `transformer.jl`: `constraint_linear_ratings!`. `pi_model.jl` is deleted. No body changes.
3. **Docs.** `branch.md`: `Cable` and `OverheadLine` leave `@docs`, the `length_km` row reads "route length [km], NaN where unknown", the paragraph on cable against line becomes one sentence; `constraint_linear_ratings!` moves to the `@docs` of
   `transformer.md`. `hierarchy.md`: tree, the Cable/OverheadLine row of the table, the paragraph under it, the
   `register_edge_type!(Cable)` example (use `Branch`), the file tree (no `pi_model.jl`, `branch/branch.jl`, and `edge.jl` as
   "the registry, terminal currents, dispatchers and what branch and transformer share"). `README.md:60-61,72-75`.
   `extending.md:19` ("as `Cable` does with `Branch`") reworded around `AbstractBranch`. `CHANGELOG.md` 0.13.0: Removed `Cable`,
   `OverheadLine`, with the migration (`Branch(; ..., length_km)`, a table row `component = "Cable"` becomes `"Branch"`);
   Changed `Branch` carries `length_km`, `dynamic_rating` takes any `AbstractBranch`; the file moves.
4. **Tests.** `hierarchy.jl`: the type tree and `edge_types` checks lose the two types, the testset "every branch type is the
   same π-equivalent" and `as_branch_type` go (they compared `Branch` with itself); `lpf.jl:152-160` goes. `validation.jl`:
   the length cases become `Branch(...; length_km = -5.0 / Inf)` refused, `NaN` and the default accepted.

## Decisions

- **D50 (Tom Van Acker, recorded 2026-10-10):** one `Branch` with `length_km`, `Cable` and `OverheadLine` removed, over a
  `construction` flag and over merging the files only; `AbstractBranch` stays; a hard removal, no shim; `dynamic_rating` kept for
  every `AbstractBranch`; `length_km` may be NaN, which means unknown (a change to D48); v0.13.0, as public names go.
- **D51 (Tom Van Acker, recorded 2026-10-10):** what several types of a family share lives in the family file
  (`edge/edge.jl`, as `unit/unit.jl` has `constraint_unit_power!`); what one type alone uses lives in that type's file;
  `src/comp/edge/pi_model.jl` goes. Proposed by Tom; the plan adds only that `constraint_linear_ratings!` is the transformer's.

## Verification

- `test/validation.jl`, red on v0.12.9: `Branch(...; length_km = -5.0)` raises `ArgumentError` and `length_km = NaN` is accepted
  (today a `MethodError` for both, no such field); `hierarchy.jl`: `Set(edge_types()) == Set([Branch, DCLink, Switch, Transformer])`
  (today six types); `dynamic_rating(Branch(...))` returns `rate_a` (today a `MethodError`). All green after part 1.
- Part 2 is code motion: every definition of the old `pi_model.jl` appears once, character for character, in its destination
  (`git diff --color-moved` and a check of each stripped line against `git show main:src/comp/edge/pi_model.jl`), the header
  and the stale comment aside; the exports of the module are the same set minus `Cable`, `OverheadLine`.
- Suite with 4 threads passes, with the removed checks listed in the commit; `test/powermodels.jl` and the frozen values of
  `lf.jl`, `opf.jl`, `lpf.jl` unchanged; `test/hot_path.jl` passes (`Branch` grows a field and must still allocate nothing).
- Docs build clean: every `@docs` resolves once, `grep -rE "Cable|OverheadLine" src docs/src test scripts benchmark README.md`
  finds nothing.
- A 24 h chunk (`NMB_RUN_ID=_b30_check`, `scratch/b23_chunk_compare.jl`) against `runs/_b25_proc/chunks/h00001-00024`: all seven
  files byte-identical. The pipeline builds `Branch` only, so this is the proof the move changed no number.
- Cost: `scratch/b23_cost.jl`, a step-3 window cut at most 8.0 ms (7.5 ms on v0.12.8, the field adds a check per `Branch`
  built); `benchmark/window.jl` update 25.9 ms within 2 % beside a same-day control worktree.

## Commit order

1. Bookkeeping of the B24 merge; this plan, D50 and D51 recorded. The setup change below is its own commit (SC7).
2. Tests red, then one `Branch`: the field, the check, `Cable` and `OverheadLine` deleted, `dynamic_rating`, the two test files.
3. The move: `edge.jl`, `branch.jl`, `transformer.jl`; `pi_model.jl` deleted; the `@docs` of `constraint_linear_ratings!`.
4. Docs, README, `CHANGELOG.md`, `Project.toml` 0.13.0, headers; after the runs STATE and B30.

## Setup file (Tom's OK 2026-10-10, applied as SC7)

`.github/instructions/domain-invariants.instructions.md` named both types twice, and its load-order example was `branch/`:
- `:26-28` becomes "**A type earns its place by changing the model, not by carrying a label.** A cable and an overhead line are
  a `Branch` with another `length_km`; don't add a type that changes no variable or constraint relative to its parent."
- `:31-32` takes `load/load.jl` before `fixed_load.jl`/`flexible_load.jl` as its example, `branch/branch.jl` being alone.
- One bullet after "One file per component": "What several types of a family share lives in the family file (`edge/edge.jl`,
  `unit/unit.jl`); what one type alone uses lives in its own file."

## Stop rule

If a table, script or `runs/` configuration outside the repo's tracked files names `Cable` or `OverheadLine` (none in `scripts/`,
`benchmark/`, `ext/` or `docs/`; outside users unknown), say so before the removal. If a window cut or an update is slower than
the limits above, look first at the `length_km` check in the `Branch` constructor.

## What this deliberately does not decide

- A `construction` flag, if a rating model or a planning cost ever needs the kind: its own decision, a field, not a type.
- Whether `variable_edge_series_current`, generic over `AbstractEdge`, is promoted to `edge.jl` when a second edge type needs it.
- The default of `length_km`: 0.0 as `Cable` had it, or NaN, since NaN is now the way to say unknown. Open for Tom; the
  plan writes 0.0 until he says. Nothing reads it, so it is a line in `Branch`, the docstring and a test.
- Whether `constraint_linear_limits!` (two arcs, one rating, the angle limit) and `constraint_linear_ratings!` (any number of
  arcs, a rating each, no angle limit) become one function; the transformer picks one by `length(A)` and never calls both.
- Q7, the export surface: 267 names, two fewer here; moving an `export` between files changes nothing for a user.
- B20, B13 (a transformer from datasheet values) and the `Switch` and `DCLink` rating code, which repeats none of this.
