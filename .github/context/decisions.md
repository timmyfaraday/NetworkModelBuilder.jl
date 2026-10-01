# Decisions

The rules that still constrain NMB. Read the section for the area you are touching before
changing it.

How to use this file:
- A new decision gets the next free id (**D11**), goes in the Log at the bottom, and is written by
  the `record-decision` skill. `Decided by` is a person's username, never an agent.
- A decision that changes a rule below edits the rule in place and cites the new id. The old
  wording goes to the archive line of the id it came from.
- Ids exist for commits, PRs and this file. They do not go in docstrings or code comments.

---

## Versioning and releases

- **Gap-closure items are tackled one at a time: plan → user review → implement** (D1). Each item
  bumps the patch digit only (`version = "0.9.x"` in `Project.toml`); no git tag per bump. Tag and
  push are the user's call, asked for every time, not assumed from a prior approval.
- **`CHANGELOG.md` follows Keep a Changelog, backfilled from per-file changelog headers, not raw
  commit timing** (D3): the per-file `# vX.Y.Z - <what changed>` header comments are the author's
  own retrospective record of which version a change belongs to, and outrank `git log` dates when
  the two disagree (`Project.toml` often didn't move for 20+ commits at a time).

## Project memory layout

- **Specs/plans live in `context/knowledge/plan/`, not a top-level `plans/`** (D12): all of
  project memory now lives under one root, `.github/context/`; `knowledge/` holds longer-form
  reference material, a category `context-files.instructions.md` already named before this gave it
  a real directory. Content is unchanged, only location — every cross-reference to `plans/...` was
  updated to `context/knowledge/plan/...`; historical mentions (`CHANGELOG.md`, this file's own
  Log, `setup-changelog.md`, a tag's own pinned reference commit) were left as the accurate record
  of what was true at the time.

## Code conventions

- **`src/comp/{node,edge,unit}/` is included by walking the directory tree, not by naming every
  file in `src/NetworkModelBuilder.jl`** (D10): the file named like its own directory loads first
  in each one (see `domain-invariants.instructions.md`). Each component file exports its own
  public names next to their definition instead of a central list. A new component type needs no
  edit to the central file — only its own, in the right folder.
- **Every `src/`/`test/` file carries an 80-column box header ending in a Changelog section**
  (D2). A new version line is added, not a rewrite of existing ones.
- **A generic-purpose test dependency is `import`ed, never `using`d, in `test/runtests.jl`** (D5):
  `using` exports the dependency's own names into the shared test namespace, and a name collision
  with NMB's own exports breaks unrelated test files with a confusing `UndefVarError`. Solver
  packages (Ipopt, HiGHS) are low-risk and stay `using`d — they only export their own `Optimizer`
  type.

## Concurrency

- **Each mutable registry (`_EDGE_TYPES`, `_UNIT_TYPES`, `_MODELS`) gets its own `ReentrantLock`,
  wrapping only the check-then-push in its `register_*!` function** (D4). Read functions
  (`edge_types()`, `unit_types()`) stay lock-free — already `copy()`-safe, and reads/writes don't
  realistically overlap. CI sets `JULIA_NUM_THREADS=4` specifically so the regression test can't
  silently pass without real concurrency.

## Dashboard output

- **`security_tables` is built generically against `Network`/`Dimension`/`nw_solution`, not as
  part of the Zorba adapter** (D9): an N-1 security screening is a question about any grid this
  package can solve, not something only a `parse_zorba` study can ask — "coordinate 1 of
  `:contingency` is the base case" is already a package-wide convention (`src/prob/rd.jl`), not a
  Zorba-only one. A Zorba-built study needs no special case; it already carries the right names.
- **`security_tables`/`write_security_tables` use a specific dashboard's own file and column
  names directly** (`frank_safe_borders`/`nm1_max_flows`/`nm1_min_flows`), **rather than NMB's own,
  more neutral ones** (D9): chosen for zero-friction interop with that one consumer, at the cost of
  baking another team's naming into NMB's public API. See
  `context/knowledge/plan/dashboard-output-mapping.md` for the full correspondence and the options
  for revisiting this later.
- **Parquet2 is a new weak dependency, gated the same way Arrow is** (D9): Arrow.jl implements only
  the Arrow IPC format, not Parquet — there is no way to write a literal `.parquet` file without a
  Parquet-capable package, so this was not a choice between Arrow and Parquet2, only whether to add
  Parquet2 at all.

## Results access

- **`solution_tables` is a `NamedTuple`-of-columns addition alongside `nw_solution`, not a
  replacement for it** (D11): the nested `Dict` stays the PowerModels.jl-familiar default. An
  edge's row is per **terminal**, not per edge, since an edge may have any number of them; every
  dimension `data` is posed over becomes its own column; a column no component or network index
  reports at all is dropped rather than kept `missing` throughout. No new dependency —
  `DataFrame(tables.node)` works for a caller who already has DataFrames.jl.

## Validation against a reference implementation

- **PowerModels.jl is a live cross-check (`test/powermodels.jl`), run alongside the existing
  frozen-value tests, not instead of them** (D6): frozen tests catch NMB's own regressions, the
  live one catches divergence from PowerModels' current behavior. PowerModels is a test-only
  dependency (`[extras]`/`[targets]`, like Ipopt and HiGHS).

## Documentation

- **A "complete example" (a fenced block with `using NetworkModelBuilder`) is executed twice**
  (D7): as a Documenter `@example <name>` block (so a broken one fails `docs/make.jl`) and swept a
  second time by `test/docs.jl` (so it fails the test suite too, independent of a docs build).
- **A bare Matpower filename (e.g. `"case14.m"`) resolves against the package's own bundled
  `test/data/matpower/` when it isn't found relative to the working directory** (D8), in
  `_read_matpower`. This makes doc quick-starts work from any cwd without changing behavior for
  any path that already resolves.

---

## Log

New decisions, newest at the bottom.

### D1 — Gap-closure items are tackled one at a time, patch-digit bump, no per-bump tag
Date: 2026-09-29 · Decided by: Tom Van Acker · Area: Versioning and releases
Why: keeps each change small and reviewable; tagging isn't needed until a real release is cut.
Changes: new.

### D2 — Every src/test file carries an 80-column box header with a Changelog section
Date: 2026-09-29 · Decided by: Tom Van Acker · Area: Code conventions
Why: pre-existing convention across the whole codebase; kept explicit so new files match it.
Changes: new (documents existing practice).

### D3 — CHANGELOG.md backfilled from per-file changelog headers, not commit timing
Date: 2026-09-29 · Decided by: Tom Van Acker · Area: Versioning and releases
Why: `Project.toml`'s version field jumped 0.6.0 → 0.9.0 in one commit; per-file headers are the
more reliable record of which version a change belongs to.
Changes: new.

### D4 — One ReentrantLock per mutable registry, colocated, guarding only check-then-push
Date: 2026-09-29 · Decided by: Tom Van Acker · Area: Concurrency
Why: fixed a real `ConcurrencyViolationError` reproduced under 56-thread concurrent registration;
read functions were already safe and don't need locking.
Changes: new.

### D5 — Generic-purpose test dependencies are imported, not used, in test/runtests.jl
Date: 2026-09-29 · Decided by: Tom Van Acker · Area: Code conventions
Why: `using PowerModels` broke two unrelated test files via a name collision on `parse_file`/
`ids`/`solve_opf`; `import` + qualified calls avoids the shared-namespace risk entirely.
Changes: new.

### D6 — PowerModels.jl live cross-check runs alongside frozen-value tests, not instead of them
Date: 2026-09-29 · Decided by: Tom Van Acker · Area: Validation against a reference implementation
Why: frozen tests catch NMB's own regressions; a live check catches divergence from PowerModels'
current behavior — the two catch different things.
Changes: new.

### D7 — Complete doc examples run twice: Documenter @example and the test/docs.jl sweep
Date: 2026-09-29 · Decided by: Tom Van Acker · Area: Documentation
Why: a redispatch LPF example had referenced an undefined variable for months, undetected, because
nothing had ever executed it; two independent execution paths make that harder to happen again.
Changes: new.

### D8 — Bare Matpower filenames fall back to the package's own bundled test fixtures
Date: 2026-09-29 · Decided by: Tom Van Acker · Area: Documentation
Why: every "complete, runnable" quick-start example failed from the repo root (a normal user's
starting point); the fallback fixes all of them without changing behavior for paths that resolve.
Changes: new.

### D9 — `security_tables` is general and dashboard-shaped: Parquet2, and GRIP's own names
Date: 2026-09-30 · Decided by: Tom Van Acker · Area: Dashboard output
Why: an N-1 screening isn't Zorba-specific, and matching a real dashboard's own file/column names
and format (Parquet, which Arrow.jl cannot write) lets its output be plugged in directly, at the
cost of one new dependency and one team's naming baked into NMB's public API.
Changes: new.

### D10 — `src/comp/` is auto-included by directory walk; each component exports its own names
Date: 2026-09-30 · Decided by: Tom Van Acker · Area: Code conventions
Why: closes gap #8 of `plans/GAP_CLOSURE_PLAN.md` — `src/NetworkModelBuilder.jl` was the most
churned file in the repo (~39% of commits) purely from listing every new component type's include
and export lines by hand; verified the public API is unchanged (`names(NetworkModelBuilder)`
identical before and after) and every existing subtype-ordering dependency already followed the
"file named like its directory loads first" pattern, so no behavior changed, only where the
include/export statements live.
Changes: new.

### D11 — `solution_tables` is a tidy NamedTuple view alongside `nw_solution`, edge rows per terminal
Date: 2026-09-30 · Decided by: Tom Van Acker · Area: Results access
Why: closes gap #9 of `plans/GAP_CLOSURE_PLAN.md` — result access was a stringly-typed nested
`Dict` with no autocomplete, type safety or easy whole-table access; adding a tidy view alongside
it (not replacing it) gives that without a new dependency or changing what a `result` carries.
Changes: new.

### D12 — Specs/plans move from a top-level `plans/` to `context/knowledge/plan/`
Date: 2026-10-01 · Decided by: Tom Van Acker · Area: Project memory layout
Why: keeps all project memory under one root (`.github/context/`) instead of split across that and
a separate top-level `plans/`; `knowledge/` was already named as a context category in
`context-files.instructions.md` before this gave it a real directory.
Changes: new.
