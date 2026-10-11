# One `Branch`, and the fragments in the file that owns them (B30)

Status: implemented on `b30-one-branch` (D50-D53), not merged · Author: Tom Van Acker (requested) · Date: 2026-10-11
Decisions: D50-D53 recorded 2026-10-10 (next free after: D54); no open point
Priority: P3 · Effort: Large, in two stages. Branch `b30-one-branch`, cut from `main` at `b577b4a` (v0.12.9);
becomes v0.13.0. Stage 1 is this file (parts 1 to 3), stage 2, more than two terminals, is `one-branch-terminals.md`.

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
  `src/`, `test/`, `scripts/`, `benchmark/`, `ext/` or `docs/`. `length_km` is read by `_check_length` and nothing else, which
  refuses NaN today.
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
  | `constraint_linear_ratings!` | `transformer.jl:852` only, until part 3 |

- **`constraint_linear_limits!` writes two things at once**: a rating (`_linear_rating!`) and the angle limit (`:linear_angle`,
  `pi_model.jl:285-298`). The transformer picks it for two windings, with `minimum(tf.rate_a)`, and `constraint_linear_ratings!`
  (the rating alone, any number of arcs, a rating each) for more (`transformer.jl:849-852`). In IVR the two are already apart:
  `constraint_edge_rating!` and `constraint_edge_angle_difference!`.
- **The unit side already does it:** `constraint_unit_power!` (`unit.jl:165`), shared by every generator, load and storage
  unit, lives in `unit/unit.jl`, not in a component's file.

## Root cause

A type was added to carry a label before anything needed it, and the branch physics got a file of its own because a
transformer was going to call it; the transformer called part of it and wrote the rest itself.

## Fix

1. **One `Branch`.** `branch.jl` keeps `AbstractBranch` (the extension hook; methods stay on `T<:AbstractBranch`) and `Branch`,
   which gains `length_km::Float64 = NaN` between `angmax` and `status`, checked by `_check_length` in its constructor: a
   length is NaN, which means unknown and is the default, or `>= 0`; a negative one and `Inf` are refused. `Cable` refused NaN too, so this
   changes D48. `cable.jl` and `overhead_line.jl` are deleted, `Cable` and `OverheadLine` are no longer registered or
   exported; `edge_types()` is `Branch`, `DCLink`, `Switch`, `Transformer`. `dynamic_rating(br::AbstractBranch) = br.rate_a`
   stays, exported, with its own docstring. The `Branch` docstring says a cable and an overhead line are a `Branch`, and
   that a `NetworkVector` over `:time` in `rate_a` is a rating that follows the weather.
2. **Shared fragments go to `edge.jl`.** A new section there holds `constraint_edge_rating!`, `_rating_at`, `_any_finite`,
   `variable_edge_overload!`, `constraint_edge_angle_difference!`, `susceptance`, `constraint_linear_flow!`,
   `constraint_linear_limits!`, `_linear_rating!` and `constraint_linear_ratings!`, verbatim, with their exports (the last
   because part 3 makes the branch call it). Branch-only code moves to `branch.jl`: `constraint_pi_section!` and
   `variable_edge_series_current`, with the comment that only a branch writes its π-section. Nothing is the transformer's
   alone. `pi_model.jl` is deleted. No body changes.
3. **A rating and an angle limit are two constraints** (D52), in a part of their own after the move. `constraint_linear_limits!`
   goes. The angle row becomes `constraint_linear_angle_difference!(nm, a_fr, a_to, angmin, angmax; nw)`, the counterpart of
   IVR's `constraint_edge_angle_difference!`, under the same key `(e, :linear_angle)`. `constraint_linear_ratings!` is the one
   linear rating, for two terminals as for more, and absorbs `_linear_rating!`, its only caller left. A branch and a two-winding
   transformer then write the ratings of every terminal and the angle limit; a transformer with more windings the ratings
   only. The transformer's `minimum(tf.rate_a)` goes: a lossless two-terminal edge has `p_2 = -p_1`, so a rating each is the same
   feasible set. Rows are identical where the ratings are, and differ in a bound only where a transformer's two windings are
   rated unequally (a search of the tests for one is part of the part). `window.jl:258` names `constraint_linear_limits!` in
   a docstring and is reworded.
4. **Docs.** `branch.md`: `Cable` and `OverheadLine` leave `@docs`, the `length_km` row reads "route length [km], NaN where
   unknown", the paragraph on cable against line becomes one sentence; `constraint_linear_limits!` leaves `@docs` and
   `constraint_linear_angle_difference!` joins it. `hierarchy.md`: tree, the Cable/OverheadLine row of the table, the paragraph
   under it, the
   `register_edge_type!(Cable)` example (use `Branch`), the file tree (no `pi_model.jl`, `branch/branch.jl`, and `edge.jl` as
   "the registry, terminal currents, dispatchers and what branch and transformer share"). `README.md:60-61,72-75`.
   `extending.md:19` ("as `Cable` does with `Branch`") reworded around `AbstractBranch`. `CHANGELOG.md` 0.13.0: Removed `Cable`,
   `OverheadLine`, with the migration (`Branch(; ..., length_km)`, a table row `component = "Cable"` becomes `"Branch"`);
   Changed `Branch` carries `length_km`, `dynamic_rating` takes any `AbstractBranch`; the file moves.
5. **Tests.** `hierarchy.jl`: the type tree and `edge_types` checks lose the two types, the testset "every branch type is the
   same π-equivalent" and `as_branch_type` go (they compared `Branch` with itself); `lpf.jl:152-160` goes. `validation.jl`:
   the length cases become `Branch(...; length_km = -5.0 / Inf)` refused, `NaN` and the default accepted.

## Decisions

- **D50 (Tom Van Acker, recorded 2026-10-10):** one `Branch` with `length_km`, `Cable` and `OverheadLine` removed, over a
  `construction` flag and over merging the files only; `AbstractBranch` stays; a hard removal, no shim; `dynamic_rating` kept for
  every `AbstractBranch`; `length_km` may be NaN, which means unknown, and is NaN by default (a change to D48); v0.13.0, as
  public names go.
- **D51 (Tom Van Acker, recorded 2026-10-10):** what several types of a family share lives in the family file
  (`edge/edge.jl`, as `unit/unit.jl` has `constraint_unit_power!`); what one type alone uses lives in that type's file;
  `src/comp/edge/pi_model.jl` goes. Proposed by Tom.
- **D52 (Tom Van Acker, recorded 2026-10-10):** a rating and an angle limit are separate constraints; `constraint_linear_ratings!`
  is the one linear rating for any number of terminals, and `constraint_linear_limits!` is removed.
- **D53**, a branch with more than two terminals, is in `one-branch-terminals.md`.

## Verification

- `test/validation.jl`, red on v0.12.9: `Branch(...; length_km = -5.0)` raises `ArgumentError`, `Branch(...).length_km` is NaN and
  `length_km = NaN` is accepted (today a `MethodError`, no such field); `hierarchy.jl`: `Set(edge_types()) == Set([Branch, DCLink,
  Switch, Transformer])` (today six types); `dynamic_rating(Branch(...))` returns `rate_a` (today a `MethodError`). Green after part 1.
- Part 2 is code motion: every definition of the old `pi_model.jl` appears once, character for character, in its destination
  (`git diff --color-moved` and a check of each stripped line against `git show main:src/comp/edge/pi_model.jl`), the header
  and the stale comment aside; the exports of the module are the same set minus `Cable`, `OverheadLine`.
- Part 3 changes no key: `test/rd.jl:547-559` and `test/dc_link.jl:184` hold as they are (`(e, t)`, `(e, :linear_angle)`). For a
  two-winding transformer rated unequally on its windings, an LPF OPF with an overload price gives the same objective before
  and after, to 1e-9; if no test has one, one is built for the check.
- Suite with 4 threads passes, with the removed checks listed in the commit; `test/powermodels.jl` and the frozen values of
  `lf.jl`, `opf.jl`, `lpf.jl` unchanged; `test/hot_path.jl` passes (`Branch` grows a field and must still allocate nothing).
- Docs build clean: every `@docs` resolves once, `grep -rE "Cable|OverheadLine" src docs/src test scripts benchmark README.md`
  finds nothing.
- A 24 h chunk (`NMB_RUN_ID=_b30_check`, `scratch/b23_chunk_compare.jl`) against `runs/_b25_proc/chunks/h00001-00024`: all seven
  files byte-identical. The pipeline builds `Branch` only, so this is the proof the move and the split changed no number.
- Cost: `scratch/b23_cost.jl`, a step-3 window cut at most 8.0 ms (7.5 ms on v0.12.8, the field adds a check per `Branch`
  built); `benchmark/window.jl` update 25.9 ms within 2 % beside a same-day control worktree.

## Commit order

1. Bookkeeping of the B24 merge; this plan, D50 to D53 recorded. Done, with the setup change (SC7, Tom's OK: `domain-invariants`
   no longer names `Cable` and `OverheadLine` and says shared fragments live in the family file) as its own commit.
2. Tests red, then one `Branch`: the field, the check, `Cable` and `OverheadLine` deleted, `dynamic_rating`, the two test files.
3. The move: `edge.jl`, `branch.jl`; `pi_model.jl` deleted.
4. The split: `constraint_linear_angle_difference!`, `constraint_linear_limits!` removed, the two call sites. The 24 h chunk here.
5. Stage 2, `one-branch-terminals.md`, in its own commits, with the chunk again after it.
6. Docs, README, `CHANGELOG.md`, `Project.toml` 0.13.0, headers; after the runs STATE and B30. Done 2026-10-11. Stage 1 is
   `edf3657`, `af00183`, `967d06d` (24 h chunk byte-identical after it, suite 3265); the rest is in `one-branch-terminals.md`.

## Stop rule

If a table, script or `runs/` configuration outside the repo's tracked files names `Cable` or `OverheadLine` (none in `scripts/`,
`benchmark/`, `ext/` or `docs/`; outside users unknown), say so before the removal. If a window cut or an update is slower than
the limits above, look first at the `length_km` check in the `Branch` constructor.

## What this deliberately does not decide

- A `construction` flag, if a rating model or a planning cost ever needs the kind: its own decision, a field, not a type.
- Whether `variable_edge_series_current`, generic over `AbstractEdge`, is promoted to `edge.jl` when a second edge type needs it.
- Q7, the export surface: 267 names, two fewer here; moving an `export` between files changes nothing for a user.
- B20, B13 (a transformer from datasheet values) and the `Switch` and `DCLink` rating code, which repeats none of this.
