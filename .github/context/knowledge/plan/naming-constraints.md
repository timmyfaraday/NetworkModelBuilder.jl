# One nomenclature for constraints, functions and duals (B32)

Status: decided (D63-D70), stages 0 to 3 done, the map confirmed by Tom; the map is confirmed by Tom at stage 1 · Author: Tom Van Acker (requested) · Date: 2026-10-11
Decisions: D63-D70 recorded 2026-10-11 (next free after: D71)
Priority: P2 · Effort: Large, in six stages. Branch `b32-constraint-names`, cut from `main` at v0.14.0; becomes v0.15.0 (a hard removal that renames exports and extension points is a minor bump, as D59 made v0.14.0).
Follows `naming.md` (D55-D62). The names themselves are drafted in stage 1 into `../nomenclature.md`; this file is how to get there.

## Handoff instructions

- Implement on `b32-constraint-names`, one commit per stage, tests first and red where a test can be, no AI attribution, commit messages
  name the decision (`D63: ...`).
- Per-file changelog header (80 columns) on every `src/`, `test/` and `scripts/` file touched, `Project.toml` 0.15.0, `CHANGELOG.md` with
  a migration table that lists every renamed key, function and dual. Compute the padded lines, then re-read the file (`lessons.md`).
- **Rename with a Julia script, never PowerShell** (as `naming.md`): bytes read and written as UTF-8 without a BOM, each file's line
  endings kept, a token map from `nomenclature.md`, a dry-run diff per file before it writes. A multi-line edit of a CRLF file goes
  through the same kind of script, matching its anchor exactly once (F8, F9).
- Hard removal, no alias, no hint map (D59): an old name must fail loudly.
- Targeted tests per commit, the full suite once per stage with `$env:JULIA_NUM_THREADS = '4'`, the docs build.

## Evidence

- **Constraint keys** (survey of `src/`, 2026-10-11): 46 register keys at about 100 `constrain!` sites, 28 `con` keys, about 30 distinct
  id words in five shapes: `e`, `(e, part)`, `(arc, part)`, `((e1, e2, ...), :max)` and `(family, sub, key)`.
- **Two spellings for one row.** The node rows are `:node_voltage_reference`, `_setpoint`, `_limits`, `_anchor` in `con` and
  `:node_reference`, `_setpoint`, `_limits`, `_anchor` in the register; `:edge_angle_difference` against `:edge_angle`; `:generator_power`,
  `:load_power`, `:slack_power`, `:storage_power` in `con` against `:unit_power` in the register. `:linear_rating` and `:edge_rating` are
  one rating in two formulations; `:winding`, `:pi_section` and `:star_balance` name no owner; `:storage_cycles`, `:edge_limits` and
  `:node_voltage_limits` are plural.
- **`con` is nearly write-only.** `src/` reads it only for the node balance (`nodal_prices`, `active_nodal_price`, the solution
  builder); the rest is read by tests. Its entries bundle rows: `:edge_limits` holds a rating and an angle row, `:switch` a flow and a
  position row.
- **Ids are per kind.** Node 1, edge 1 and unit 1 coexist, so `:redispatch_control` carries its family in its id, and a key of a role
  alone, `:balance`, would collide.
- **Ids carry old names.** `:pi_section` has `(e, :cr_fr)`, `:ci_fr`, `:cr_to`, `:ci_to`, variable keys from before D55, next to
  `(e, :v_real)`; `:tap_setting` has `:magnitude_max` and a bare `:max`, which is the angle bound; `:angle` and `:magnitude` are
  `angl` and `magn` in the nomenclature.
- **No row is named.** `constrain!` calls `JuMP.add_constraint(nm.model, c)` with no name, and every row passes through it, so a name
  costs no call-site string, unlike the 45 of `variable!`. Its second sight (an update) never needs the name.
- **A name is a debugging aid.** Nothing in `src/`, `test/` or `scripts/` reads one back; a solver log, `print(model)` and an LP file do.
  v0.14.0 builds them by default (`set_string_name = true`, D61), 19 to 27 % of a cold `instantiate_model` on the step-3 window; the
  pipeline never passes the keyword.
- **Functions.** 22 `constraint_*` names, 63 definitions (one a one-liner), 233 lines in 20 files of `src/`, 59 lines in 13 pages of `docs/src/`, 3 lines in 2
  test files, 1 in `scripts/`, 3 in `README.md`. Two are exported (`constraint_redispatch_control`, `constraint_overload_peak`);
  `constraint_edge`, `constraint_unit`, `constraint_edge_limits` and the two `*_coupling` are the extension points of
  `docs/src/manual/extending.md`, extended by `test/arc_controls.jl` and `test/multiterminal.jl`.
- **Duals.** Four solution keys of a node, `"lambda"`, `"lambda_q"`, `"lambda_real"`, `"lambda_imag"` (`src/comp/node/node.jl`), read by
  `test/price.jl`, named in `test/nomenclature.jl` and used on three docs pages. The top-level `"dual_status"` is JuMP's own term.
- **B31 left old letters** that its sweep (`.old`, `:old`, `"old"`, backticks in the docs) cannot see: `constraint_pi_section!(nm, ctr, cti,
  vtr, vti, ...)` and its docstring, the locals `csr`, `csi` (`branch.jl`, `transformer.jl`), `vtr vti ctr cti` of the transformer, `cru`,
  `ciu` (`unit.jl`), the example in `core/rebuild.jl`, the table in `prob/lf.jl`, a snippet in `docs/src/manual/extended_graph.md`, and
  the docstrings of `variable!`, `_variable_name` and `instantiate_model`, which show `1_pg[3]`, `2_tr[4,1]`, `1_zt[4,1,2]` for what are
  now `1_p_gen[3]`, `2_t_real[4,1]`, `1_z_step[4,1,2]`.

## Root cause

D55 named quantities and left what talks about constraints out of it. A key was chosen where its row was written, `con` and the register
by two different hands, and a function and a dual took their name from the key they served, so nothing says which of the three a name is.

## Fix

0. **Measure (read-only).** `scratch/b32_names.jl`, from `b30_names.jl`, on the real step-3 window with constraint names built too:
   `instantiate_model` with names off (the new default), with variable names only (v0.14.0) and with both (`debug_mode = true`), min
   of 3, beside the row count. It says what debug mode costs and what the default gains.
1. **Map and red.** Draft a "Constraints, functions and duals" section in `../nomenclature.md`: the closed owner, role and part lists, the
   46 register keys, the 28 `con` keys, the id shapes, the 22 function names, the four duals, the old-letter parameters and locals; Tom
   confirms it as he confirmed B31's map. Then red in `test/nomenclature.jl`: every key a `constrain!` or a `con` literal writes is
   `cstr_<owner>_<role>` from the lists; `con` and the register agree; every id part is a word of the lists; no `constraint_*` is defined;
   every `dual_*` key a solution builder writes is in the map and no `lambda*` is left; and the old-name sweep reads bare identifiers
   (`ctr cti vtr vti csr csi cru ciu`), docstring examples (`1_pg[3]`) and the code blocks of the docs, which it did not.
2. **Debug mode and names first.** `set_string_name` becomes `debug_mode::Bool = false` in `instantiate_model` and in every solve
   (`solve_model`, `solve_lf`, `solve_opf`, `solve_rd`, `solve_rolling_horizon`, `solve_zorba`), and the `NetworkModel` field
   `string_names` becomes `debug_mode`. `variable!`, `variables!`, `variable_container!` and `constrain!` name a row only when it is
   true, `constrain!` as `"$(nw)_$(key)[$id]"` through a `_constraint_name` that flattens an `Arc` and a nested tuple. True sets
   `JuMP.set_string_names_on_creation(model, true)`, false sets it to `false`, on a `jump_model` handed in too; `set_string_name` fails
   with a `MethodError` (D59). Tests, in `test/string_names.jl`: with `debug_mode = true` every variable and every registered ref has
   its name and the names are unique over a model (distinct names equal the register's size); by default none has one; the objective is
   identical either way; a rolling horizon keeps the flag in every window it builds and an updated window keeps its names; every
   test that reads a name passes `debug_mode = true`. Do this first: the key rename then has no third place to keep in step.
3. **Keys, ids and `con`.** The register keys, the `con` keys and the ids by the map, in `src/` and in the tests that read them (about 45
   lines in 10 files); a miss is a `KeyError` or a failing `haskey`. `con[:cstr_node_balance][i]` is `(real, imag)` in IVR, which `nodal_prices` and
   the solution builder destructure. A check that a built IVR and a built LPF model, on the fixtures, hold one id arity per key (D70).
4. **Functions, duals and old letters.** `constraint_*` to `fnct_*` (methods, calls, exports, `docs/src`, `README.md`, the two test files
   that extend `constraint_edge`); `lambda*` to `dual_*` in the node solution builders, `test/price.jl` and three docs pages; `ctr cti vtr
   vti` and the other old letters to their key names (D57); the stale docstrings and docs snippets.
5. **Docs and memory.** The code-name column of each type's tables (D60) and `docs/src/manual/nomenclature.md`, whose "What is not
   covered" shrinks to `variable_*`, `solution_*`, `objective_*`; `docs/src/manual/extending.md` (an extension prefixes its keys with its
   own name); `README.md`; `CHANGELOG.md` with the migration table; `Project.toml` 0.15.0; the live sections of `decisions.md` that name a
   renamed key, function or dual are edited in place (the Log stays); `STATE.md`, the backlog. With Tom's OK (setup files): one line in
   `julia.instructions.md`.

## Results (2026-10-11)

**Stage 0** (`scratch/b32_names.jl`): the real step-3 window, 249,118 variables and 274,523 rows, min of 3 over four rounds. Off 1,706 ms, 764 MB; variable names only
(v0.14.0) 1,948 ms, 1,003 MB; both 2,420 ms, 1,352 MB. The default off against v0.14.0: -12 % time, -24 % memory; debug mode against off: +42 % time, +77 % memory.

**Stage 1:** the map is in `../nomenclature.md` and as data in `test/nomenclature.jl`; of 99 checks 89 pass and 10 were red on v0.14.0: 46 of 46 register keys, 28 of 28
`con` keys, 14 id words, 22 `constraint_*` functions and 2 exports, 4 `lambda*` duals, 680 old names written.

**Stage 2** (`scratch/b32_stage2_names.jl`): `debug_mode = false` 1,707 ms, 764 MB, as stage 0's off; `true` 2,401 ms, 1,372 MB, all 274,523 row names distinct. An MPS
file carries the names; the LP writer rewrites `1_node_balance[1]` to `_1_node_balance_1_`; an IVR model cannot be written to either format, named or not. Found, not
changed: a `variables!` container names its elements `1_p_term[Arc(1, 1, 1)]`, where `variable!` flattens an `Arc` to `[1,1]`.

**Stage 3:** suite 3,685 passed, 6 failed, the six checks of stage 4 (22 functions and 2 exports, 4 duals, 451 old names: 312 functions, 80 letters, 49 duals, 10 containers);
no old key is written anywhere, and 26 built models, IVR and LPF, hold one id arity per key. The 10 failures of stage 1 are 6 now.

## Decisions

- **D63** a key is `<owner>_<role>`: the owner, then what the row states, words from closed lists, singular, no formulation in it; the owner is the type, the family
  where several types write the row (D51), or the problem; a bound, a phasor part or a side goes in the id. **D64** `con` takes the same keys, the register's where an
  entry holds the rows of one key; its ids stay component ids. **D65** an id is the component's id or `(id, part...)`, parts spelled as the nomenclature spells them, no
  old variable key. **D66** `constrain!` names the row `"$(nw)_$(key)[$id]"`. **D67** `set_string_name` covers constraints; **D69** replaces it: `debug_mode`, default false,
  for the names of every variable and constraint. **D68** the prefixes `cstr_`, `fnct_` and `dual_` for a constraint, the function that writes it and its dual; with D63 a key
  is `cstr_<owner>_<role>`. **D70** amends D64 and D65: an id has one shape per key within a formulation, and a `con` value is a row or a tuple of rows in the order of the
  register's id parts. All Tom Van Acker, 2026-10-11; see `decisions.md`.

## Confirmed 2026-10-11

One stem and three prefixes; `fnct_` for the `constraint_*` writers only (`variable_*`, `solution_*`, `objective_*` keep their names); the dual suffixes
`p q real imag`; the π-section parameters `i_wind_*` and `v_wind_*`; v0.15.0 as D59 made v0.14.0; owners as the descriptors of the quantities. The map is in `../nomenclature.md`.

## Verification

- Red then green: the new testsets of `test/nomenclature.jl` (stage 1) fail on v0.14.0 and pass after stage 4.
- Nothing numerical moves: the full suite, `test/powermodels.jl` and the frozen values unchanged; a 24 h chunk (`NMB_RUN_ID=_b32_check`,
  `scratch/b23_chunk_compare.jl`) byte-identical to `runs/_b25_proc/chunks/h00001-00024`, all seven files.
- Debug mode: `true` and `false` give the identical objective and row count (`same_structure`); an updated window keeps its names;
  `instantiate_model` beside a same-day control worktree of v0.14.0: `false` no slower than its names off, `true` what stage 0
  measured.
- Duals: a priced model (`test/price.jl`) gives the same numbers under the new keys, the old keys raise `KeyError`, `"dual_status"` is
  unchanged.
- An LP file written from a model with `debug_mode = true` carries them (`JuMP.write_to_file`); if the format refuses a name, report which, as a
  finding and not a fix.
- Docs: the build is clean, `test/docs.jl` runs every example, every `@docs` resolves (the function names changed), and a test compares
  each type's tables with what a solve registers.
- Every file touched is UTF-8 without a BOM with its own line endings (`git diff --stat`, and a check of the first bytes).

## Stop rule

Stop and report if a 24 h chunk differs by one byte; if `debug_mode = false` builds a model that differs from v0.14.0's in a row, a bound or a
number; if a name the code needs cannot be spelled by the lists; if a rename leaves a docs example that no
longer runs; or if a file comes out with a BOM or mixed line endings.

## What this deliberately does not decide

- `variable_*`, `solution_*` and `objective_*` names; `active_nodal_price`, `reactive_nodal_price` and `nodal_prices` (functions about
  prices, not duals); `"dual_status"` (JuMP's term); the Greek `λ` locals and the `\lambda` of the docs mathematics (symbols).
- Whether `con` earns its keep: 28 keys, only the node balance read by `src/`. Retiring entries is its own item.
- Q7, the export surface: renaming `constraint_redispatch_control` and `constraint_overload_peak` changes exports, not who can see them.
