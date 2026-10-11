# One nomenclature for variables and parameters (B31)

Status: decided (D55-D61), the map awaits Tom's review of its `?` spellings · Author: Tom Van Acker (requested) · Date: 2026-10-11
Decisions: D55-D61 recorded 2026-10-11 (next free after: D62)
Priority: P2 · Effort: Large, in six stages. Branch `b31-nomenclature`, cut from `main` at `c493901` (v0.13.0); becomes v0.14.0.
The names themselves are in `../nomenclature.md`; this file is how to get there.

## Handoff instructions

- Implement on `b31-nomenclature`, one commit per stage (a layer may take several), tests first and red where a test can be, no AI
  attribution, commit messages name the decision (`D57: ...`).
- Per-file changelog header (80 columns) on every `src/`, `test/` and `scripts/` file touched, `Project.toml` 0.14.0, `CHANGELOG.md`
  with a migration table that lists every renamed name. Compute the padded header lines, then re-read the file (`lessons.md`).
- **Rename with a Julia script, never PowerShell:** `Get-Content`/`Set-Content` in 5.1 reads UTF-8 as ANSI and writes a BOM
  (`lessons.md`), and `η` is in the new names. The script reads and writes bytes as UTF-8, keeps each file's line endings, takes a
  token map from `nomenclature.md` and prints a dry-run diff per file before it writes. Review the dry run, then run it.
- Hard removal, no alias, no hint map (D59): an old name must fail, loudly.
- Targeted tests per commit, the full suite once per layer with `$env:JULIA_NUM_THREADS = '4'`, the docs build.

## Evidence

- **What there is** (survey, `scratch/naming_survey*.txt`): 72 distinct component field names over 12 types, 42 variable keys,
  46 constraint keys, about 60 distinct keywords, 230 positional parameters, 424 local names. Three layers with three habits: fields
  are mostly Matpower's (`pg`, `vmax`, `rate_a`, `baseMVA`), keys are one letter plus an ad hoc suffix (`:pg`, `:psc`, `:csi`, `:vpr`),
  locals are one or two letters (`i` 67, `e` 58, `u` 50, `n` 43).
- **Why it is hard to read:** one letter carries several meanings (`s`: storage, series, star, shunt, slack, apparent power; `p`:
  power, point, peak; `t`: terminal, tap, throughput; `c`: current, charge, cycle). One quantity has two spellings (`gs`/`bs` on `Shunt`,
  `g_sh`/`b_sh` on `Branch`; the network index is the keyword `nw` in 198 methods and `n` in 57 positions). A bound is glued
  (`pmax`), underscored (`tm_min`), a prefix (`max_energy_per_period`) or a word (`charge_rating`).
- **Size** of a rename, counted in `src`, `test`, `docs/src`, `scripts`, `benchmark`: 52 field names occur 2,650 times, 42 variable keys
  830 times (359 in `src`, 297 in `test`, 157 in `docs/src`, 13 in `scripts`). A field or a key that is missed **fails loudly** (a
  `MethodError` on a keyword, a `KeyError` on a key, the table reader's "is not a field of"); a local or a docs symbol does not.
- **Names are built at 45 call sites** (`base_name = "$(nw)_pg[$u]"`, `grep base_name src/`) and nothing reads a name back (no
  `JuMP.name`, `variable_by_name` in `src/` or `test/`). JuMP is 1.31.2, which has `set_string_names_on_creation`.
- **What names cost, measured** (`scratch/b30_names.jl`, the real step-3 window, 249,118 variables, `instantiate_model` min of 3,
  names switched off on the model handed in, the call-site strings still built): 2,437 and 2,697 ms with names, 1,958 and 1,977 ms
  without, 19 to 27 % less. The pipeline builds that model once per step and then updates it (`update_model!` 1.15 s, unaffected), so
  a chunk gains about 0.5 s of 125 s; the option is for cold builds and one-off solves.
- **`η`** (`scratch/naming_eta.jl`): `η_chg` is an identifier, stable under NFC, works as field, keyword and `Symbol`, and as an Arrow
  and a Parquet column that `pyarrow` reads back with the same name and values. `src/` has Greek locals already (`λ`, `σ`). The
  Windows PowerShell console prints it as `╬À` unless `[Console]::OutputEncoding` is UTF-8.
- **Docs** (`docs/src/components/`): 10 pages, each with a Parameters and a Variables section, but `load.md` and `slack.md` hold two
  types in one variables table, and the math writes current as `c` (about 140 occurrences in 18 files, 12 in 7 docstrings) next to
  cost as `c_{u}`, `c^{tp}`; `docs/src/index.md` has a Notation table and `problems/overview.md` an additional one.
- **Fixed from outside:** dashboard names (D9), Zorba table columns, Matpower matrix columns, PowerModels names in tests.

## Root cause

The names grew with each component. Each took Matpower's or PowerModels' name where there was one, and where there was none a letter
for the quantity and a locally chosen suffix for the owner, the part or the direction, so nothing says which suffix means what.

## Fix

1. **Red.** `test/nomenclature.jl` holds the vocabulary of `nomenclature.md` as constants and checks, for every registered component
   type, that each field name is a word or parses under D55, that each variable key of a model built over every type does, and that
   each solution key does; a second testset reads `src/`, `test/`, `docs/src/`, `scripts/` and `benchmark/` for the old names of the
   map and finds none (comments and the historical `CHANGELOG.md` sections excepted). Both fail on `main`: write down how many.
2. **`set_string_name` (D61).** `variable!` and `variables!` build the name from `(nw, key, id)` themselves, `"$(nw)_$(key)[$id]"`,
   and the 45 `base_name` strings go. `NetworkModel` gets a typed field `string_names::Bool`; `instantiate_model` takes
   `set_string_name::Bool = true` and the `solve_*` functions, `solve_rolling_horizon` and `solve_zorba` pass it on. False calls
   `JuMP.set_string_names_on_creation(model, false)` once and builds no string; true leaves a `jump_model` given by the caller as it
   is. Constraints stay unnamed (next step). Do this first: the key rename then has no third place to keep in step.
3. **Keys layer.** Variable keys and solution keys by the map, and every local that holds a key's variables takes the key's name (D57).
   A failure shows as a `KeyError`; `scripts/PipelineReports.jl`, `src/io/dashboard.jl` and `test/dashboard.jl` read solution keys.
4. **Fields layer.** The struct fields, their constructors and `_check_*`, the readers (`matpower.jl` and `zorba.jl` map their own
   names to the new ones), `tables.jl` (columns are fields), the tests and fixtures, `scripts/` (3 files, 159 occurrences),
   `benchmark/window.jl`; `baseMVA` becomes `s_base_mva` as field, accessor and keyword. `_per_terminal_data`, `Redispatch` and
   `OverloadPrice` follow the map.
5. **Docs.** Each concrete type gets its own Parameters table and its own Variables table (D60), columns symbol, code name, description,
   unit (and index for variables), so `load.md` and `slack.md` are split; the math pass writes current as `i` and keeps `c` for cost,
   by meaning and not by search; a page `docs/src/manual/nomenclature.md` from `nomenclature.md`, linked from the Notation table of
   `index.md`, with the index that says `v_angl_min` is a difference; `README.md`; `CHANGELOG.md`; `Project.toml` 0.14.0.
6. **Memory.** `decisions.md` live sections that name a renamed field are edited in place (the Log stays as it was), `STATE.md`,
   the backlog. With Tom's OK (setup files): one line in `julia.instructions.md` and the vocabulary in `domain-invariants`.

## Decisions

- **D55** the grammar `symbol_primary_secondary[_unit]`; **D56** the symbols, current `i`, cost `c`, efficiency `η`, in code and in
  the docs math; **D57** a key names the owner and a field does not, a local equals its key; **D58** the renames inside the package
  (`rate_a` `s_max`, `angmin` `v_angl_min`, `base_kv` `v_base_kv`, `baseMVA` `s_base_mva`, `length_km` `l_km`), Matpower names at the
  reader boundary; **D59** hard removal everywhere, tested, v0.14.0; **D60** a table of parameters and a table of variables for every
  component; **D61** `set_string_name`. All Tom Van Acker, 2026-10-11; see `decisions.md`.

## Verification

- Red then green: `test/nomenclature.jl` (stage 1) fails on `main` and passes after stage 4.
- Nothing numerical moves: the full suite, `test/powermodels.jl` and the frozen values unchanged; a 24 h chunk
  (`NMB_RUN_ID=_b31_check`, `scratch/b23_chunk_compare.jl`) byte-identical to `runs/_b25_proc/chunks/h00001-00024`, all seven files.
- `set_string_name = false` gives the identical objective, `JuMP.name(v)` is empty for every variable, and a rolling horizon that
  rebuilds its model keeps the flag. `instantiate_model` beside a same-day control worktree of `c493901`: names on within 2 %, names off
  faster (`scratch/b30_names.jl`).
- Tables: one test builds, for every registered component type, a table from its `fieldnames`, writes it as Arrow and as Parquet, reads
  it back with `parse_tables`, and compares the component; the old name of each renamed field raises `ArgumentError` from the reader.
- Docs: the build is clean, every `@docs` resolves, and a test compares each type's Parameters table with `fieldnames`, and its
  Variables table with the keys a solve registers.
- Every file touched is UTF-8 without a BOM with its own line endings (`git diff --stat`, and a check of the first bytes).

## Stop rule

Stop and report if a 24 h chunk differs by one byte, if `instantiate_model` with names on is more than 2 % slower than the control, if
a name the code needs cannot be spelled by D55, or if a file comes out with a BOM or mixed line endings.

## What this deliberately does not decide

- The names of constraints, their ids and their keys, and naming them in JuMP: the next step (D61 names variables only).
- Function names (`variable_edge_series_current`, `constraint_*`), the duals `lambda*` and a Greek `λ`, the plain words.
- `scripts/NMinusOneScreen.jl` (untracked, Tom's) reads fields by their old names and has to follow.
- Q7, the export surface: moving a name changes exports, not who can see them.
