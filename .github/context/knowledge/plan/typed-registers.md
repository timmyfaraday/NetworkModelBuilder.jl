# The package's registers are fields, and a key is not reused (B24)

Status: done on its branch (v0.12.9, D49), not merged · Author: Tom Van Acker (requested) · Date: 2026-10-10
Decisions: D49 recorded 2026-10-10 (next free after: D50); no open question
Priority: P2 · Effort: Medium. Branch `b24-typed-registers`, cut from `main` at `bd0d1a4` (v0.12.8);
becomes v0.12.9. Fifth move of the review `julia-guide-review.md`, item 4.

## Handoff instructions

- Implement on `b24-typed-registers`, one commit per part, the test first and red, no AI attribution.
- Per-file changelog header (80 columns) on every `src/` and `test/` file touched, `Project.toml` 0.12.9, `CHANGELOG.md`
  under Changed and Removed. `registered_constraints(nm)` stays exported and returns what it returned.
- Targeted tests per commit, the full suite once with `$env:JULIA_NUM_THREADS = '4'`, the docs build.
- Measure with `scratch/b24_registers.jl` (local, gitignored) beside a same-day control of `main`.

## Evidence

- **Nine keys of `nm.ext`, seven written and never read** (`grep` over `src/`, `docs/`, `scripts/`, `test/`): `:redispatch_control`
  (`rd.jl:148`), `:overload_peak` (`rd.jl:237`), `:storage_balance`, `:storage_final`, `:storage_cycles` (`storage.jl:313`, `:354`,
  `:443`), `:generator_energy` (`generator.jl:307`), `:flexible_load_energy` (`flexible_load.jl:159`). Each holds the
  `constrain!` references its builder just made, and every one is also in `registered_constraints(nm)` as `(nw, key, id)`.
  Only 7 test lines read one, `:redispatch_control` (`arc_controls.jl:116,133`, `rd.jl:327,426,437`, `transformer.jl:314,502`).
  The other two are used: `:registered` (`rebuild.jl:106`) and `:redispatch`, the documented input of `solve_rd` and
  `instantiate_model(...; ext)` (`redispatch.jl:176`).
- **What one real step-3 window holds** (80 network indices, `scratch/b24_registers.jl`): `:registered` 274,523 entries,
  179 MB; `:redispatch_control` 66,431 entries, 7.3 MB of its own, a duplicate (first read as 56.5 MB: `Base.summarysize` of
  it followed the references into the 49.2 MB JuMP model, see Result); `:redispatch` the setup.
- **A typed field is not a speed item:** `registered_constraints(nm)` is 14 ns a call, 3.8 ms of a 1,231 ms
  `update_model!` (0.3 %). The cost in `constrain!` is hashing its `Tuple{Int,Symbol,Any}` key, 125 ns a lookup, 34 ms an
  update (2.8 %): B20's remainder, not here.
- **A key asked for again with another index set** (`scratch/b24_probe.jl`, today): `variables!(:x, 1:3)` then `(:x, 1:5)`
  returns the 3-element container; `variables!(:z, 1:3)` then `variable!(:z, 1)` returns a variable of the array and
  `bound!` may move it; `variable!(:w, 1)` then `variables!(:w, 1:3)` returns the dictionary; `variable_container!(:v, Int)`
  then `(:v, idtype = Arc)` is accepted; only `variable!(:y, 1)` then `(:y, Arc(1,1,1))` fails, a `MethodError` that an `Arc`
  cannot convert to an `Int`. A constraint id given twice overwrites silently, as the `constrain!` docstring says. The
  `:vsr` incident in `lessons.md` (an extension's array in the key a `Transformer` then used) was this.
- `NetworkModel{P,F}(...)` is called once, in `instantiate_model` (`model.jl:227`).

## Root cause

`ext` is the caller's storage and the package wrote its own state into it; `var` and `con` are keyed by `Symbol`, shared with
every extension, and the functions that make a container check nothing about one that is already there.

## Fix

1. **`registered` is a field** of `NetworkModel`, typed as `registered_constraints` asserts today, made empty in
   `instantiate_model`; `registered_constraints(nm) = nm.registered`. The `NetworkModel` docstring lists it, and says `ext`
   is the caller's.
2. **The seven registers go.** Their `nm.ext[...] = ...` lines go, and the local dictionaries that only filled them become
   plain `constrain!` calls. The 7 test lines read `registered_constraints(nm)` through one helper, keyed
   `(nw, :redispatch_control, (family, sub, key))`. `ext` keeps `:redispatch`.
3. **A variable key is not reused with another index set.** `variable!` and `variable_container!` raise an `ArgumentError`
   naming the key and the network index where the container held is not a `Dict` of the id type asked for; `variables!`
   where it holds a dictionary, or an array over other indices. Asking again with the same index set returns the
   container untouched, as it does.
4. **A constraint id written twice in the first build of a model raises.** `NetworkModel` has a flag, `building`, that
   `instantiate_model` sets around its build; `constrain!` raises where the key is already registered while it is set:
   "`(nw, key, id)` is written twice in one build, give each constraint of a component its own id". It costs nothing in an
   update, the flag is read only where an entry exists, and a manual `constrain!` after the build still replaces in place.
   A builder is the same code in every pass, so a collision shows in the first. It does not see one that first appears in a
   later pass.
5. **`extending.md`** says an extension prefixes its keys with its own name (`:star_vr`, not `:vsr`) and that the errors
   above are what a reused key gets; the `constrain!` and `variables!` docstrings say what they refuse.

## Decisions

- **D49, recorded 2026-10-10 (Tom Van Acker):** a typed `registered` field and the seven write-only registers deleted, over
  the field alone and over documenting the keys as reserved; an error for a variable key reused and for a constraint id
  written twice in a build, over docs only; v0.12.9, not v0.13.0. The second is checked in the first build only: a pass
  counter and a third element in the register would cost a rewrite of every entry in an update (34 ms of 1,231).

## Verification

- `test/registers.jl`, new: the five reuses of the probe raise, naming the key; the same index set twice returns the same
  container; a constraint id twice in `instantiate_model` raises and a `constrain!` after the build replaces; `update_model!`
  does not raise; `nm.ext` after a redispatch build holds `:redispatch` and nothing the package added;
  `@inferred registered_constraints(nm)`. Red against today's sources, green after.
- The suite and the docs build; every build in them and in a 24 h chunk passes the duplicate check: that is the audit of
  part 4.
- The cost: `update_model!` of a real step-3 window within 2 % of a same-day control (1,231 ms measured today), the
  `benchmark/window.jl` stages the same, and the whole held model smaller by what the seven registers held of their own.
- The pipeline: a 24 h chunk against `runs/_b25_proc/chunks/h00001-00024`: all seven files byte-identical.

## Commit order

1. `test/registers.jl` with the variable-key cases, red; the checks in `variable!`, `variables!`, `variable_container!`.
2. The `building` flag and the `constrain!` check, its test; the suite and a chunk as the audit.
3. The `registered` field, the seven registers deleted, the 7 test lines moved.
4. `extending.md`, docstrings, `Project.toml` 0.12.9, `CHANGELOG.md`, headers; after the runs STATE and B24.

## Stop rule

If a package builder writes one `(nw, key, id)` twice in a first build, stop and report: it is a bug the check found, or a repeat
the rule has to allow, and that is Tom's call. If `update_model!` is more than 2 % slower, look at the index-set comparison in
`variables!` first.

## What this deliberately does not decide

- The `Tuple{Int,Symbol,Any}` key of the register and what it costs (B20's remainder); typed `var` and `con` containers.
- A duplicate that first appears in a later pass; an extension that calls `build_model!` itself twice rather than
  `update_model!`.
- Q7, the export surface: `registered_constraints` stays exported.

## Result

Commits on `b24-typed-registers` (cut at `bd0d1a4`): `6d7f09c` plan and D49, `11e88db` variable keys, `052e7b6` constraint ids,
`95dec60` the field and the deleted registers, `20b3975` docs, docstrings, 0.12.9.

- **Tests:** `test/registers.jl`, 27 checks. Red against the sources before each part (the variable-key part 3 failures and 2
  errors, the constraint-id part 1 and 2, the field part 2 and 4), green after; suite 3295 to 3322 with 4 threads, docs
  build clean.
- **Audit (stop rule not fired):** no builder in the suite, and none in two real 24 h pipeline chunks, writes an id twice
  in a first build or reuses a variable key.
- **Pipeline:** both 24 h chunks (`runs/_b24_check`, `_b24_check2`) byte-identical to `runs/_b25_proc/chunks/h00001-00024`,
  all seven files, objectives 317686796.800330 and 308105792.250268 equal.
- **Cost**, held step-3 model (80 indices, 274,523 rows), `scratch/b24_cost.jl` beside a same-day control worktree of v0.12.8,
  two pairs: `update_model!` 1,171 and 1,185 ms against 1,309 and 1,266 (min of 7), so not slower; `instantiate_model` 2,868
  and 2,435 against 2,757 and 2,497 (noise). `benchmark/window.jl` case14: update 25.9 against 26.4 ms, 303,921 against 306,925
  allocations; instantiate 55.7 against 55.8 ms.
- **The size claim was wrong.** `Base.summarysize(nm)` 243.6 MB before, 236.3 after: **7.3 MB** (3.0 %), not 56 MB. The 56.5 MB of
  `:redispatch_control` was `summarysize` following each reference into `nm.model` (49.2 MB); the 179 MB of `:registered`
  the same. D49 stands on ownership and on the checks, not on memory. Measure a held structure by the whole holder before and after.
- **Not compared:** `variables!` does not compare a sparse container with `indices` (nothing in the package builds one).
  The source of part 3 was edited before the test was red; red was shown by stashing `src/` and running the new cases.
