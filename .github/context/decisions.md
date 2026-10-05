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
  bumps the patch digit only (`version = "0.9.x"` in `Project.toml`), except an item that adds a
  component type, which bumps the minor digit (D20); no git tag per bump. Tag and
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

## Component model

- **A bus coupler, or any other device that only connects or disconnects, is a `Switch`: a subtype of
  the edge with its own children, such as a busbar switch and a circuit breaker — not a branch with
  a near-zero impedance** (D13). Built in v0.11.0. The Zorba pipeline loads its 21 couplers as
  locked, closed switches and floors no reactance (`scripts/SteeringPlanData.jl`, on
  `test-zorba-run`).
- **A switch carries `lock` (free or locked) and `position`, an `Int` (0 open, 1 closed); `status`
  stays the in-service flag every component has** (D15). A load flow treats every switch as locked.
  A switch is supported in both the linearised and the current-based formulation.
- **A free switch makes a dispatch problem a mixed-integer program, the first in the package**
  (D16). Such a model has no duals, so nodal prices are `nothing`; tests that solve one use HiGHS.
- **A closed switch is an equality of the voltage at its two nodes with a free flow, an open one a
  zero flow; nodes are not merged** (D17). A locked switch writes exact rows chosen by its
  position. A free one writes big-M rows, needs a finite `rate_a`, which is an equipment limit in
  every dispatch problem whether or not the edge is monitored, and takes `angmin`/`angmax` as the
  angle difference allowed across it when open. To be revisited with network reduction (B7).
- **A free switch can be a preventive or a corrective measure, and is non-costly** (D18).
- **`BusbarSwitch` and `CircuitBreaker` are added later than `AbstractSwitch` and `Switch`** (D19).
- **Closed locked switches in a loop keep the voltage equalities of a spanning tree only; every other
  one gets a unit-weight loop equation, so parallel switches split the flow evenly** (D21). A free
  switch writes no equality of its own; every loop that free switches can close gets a loop row that
  holds when they are closed (D26).
- **An island must hold a reference node or a source, else building the model is an error; an island
  with a source and no reference node has one node anchored; opening every free switch may not
  create an island, unless the caller allows it** (D22).
- **A free switch is supported in the current-based formulation too, as a nonconvex mixed-integer
  program; Juniper is a test dependency for the tests that solve one** (D23).
- **A switch has exactly two terminals for now; `position` stays an `Int` for a later multi-terminal
  form** (D24).
- **`lock` is the enum `SwitchLock`, `FREE` or `LOCKED`, as `NodeType` is** (D25).

## Zorba pipeline (`scripts/`)

- **The last-resort prices are 10x the thermal ceiling for a monitored-line overload (477,000
  $/pu), 5x that overload price for spillage and 10x for load shedding** (D14), not the 3x/2x/4x
  rescaling tried while the false `INFEASIBLE` was being chased. The rescaling was never the fix;
  the reactance floor was (D13).

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
- **The documentation cites literature through DocumenterCitations, author-year, from
  `docs/src/refs.bib`** (D27): a page cites with `[Key](@citet)` or `[Key](@citep)`, lists its own
  references in a non-canonical `@bibliography` block, and `docs/src/references.md` is the one
  canonical list. An entry is written as in the published paper, with a `doi` where it is known,
  and carries only the pages and details that were read in a source, never ones made up.

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

### D13 — A bus coupler is a `Switch`, a subtype of the edge, not a near-zero-impedance branch
Date: 2026-10-02 · Decided by: Tom Van Acker · Area: Component model
Why: the Zorba data models 21 busbar couplers as branches with reactance 1e-7 (susceptance 1e7
against ~60 for a line), and that coefficient range made Xpress return false `INFEASIBLE` and false
`OPTIMAL` solutions that violated node balance by up to 32 pu. A switch has no impedance to get
wrong and can be open or closed. Its children would include a busbar switch and a circuit breaker.
Changes: new. Not implemented; the pipeline floors reactance at 1e-5 meanwhile.

### D14 — The Zorba pipeline's last-resort prices go back to 10x / 5x / 10x of the thermal ceiling
Date: 2026-10-03 · Decided by: Tom Van Acker · Area: Zorba pipeline
Why: the price rescale to 3x/2x/4x was a wrong fix for the false `INFEASIBLE`; with the reactance
floor the original prices solve week 1 with 7 of 7 chunks `OPTIMAL`, no violation and no fallback,
in the same time as the rescaled ones. Higher prices tolerate less overload (week 1: 127,368 step-3
overload rows against 129,486).
Changes: new. The year run made with the rescaled prices has to be re-run.

### D15 — A switch has `lock` and `position`; `status` stays the in-service flag
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Component model
Why: the core reads `status` as the in-service flag (topology, contingencies), so a free/locked
meaning would need special cases there, and a coupler outage works unchanged as `status = false`.
`position` is an `Int` so that more than two terminals can extend it later. Both formulations.
Changes: new.

### D16 — A free switch makes the first mixed-integer model in the package
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Component model
Why: a free switch has to choose between two physics, which a continuous variable cannot. The
package avoided integers so far (a tap changer is continuous for that reason); the cost is no
duals, hence no nodal prices, and HiGHS in the tests.
Changes: new.

### D17 — A closed switch is an equality, not a merged node; the rows follow the lock
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Component model
Why: keeps every node and its result, and states the voltage-equal, power-flows / decoupled,
no-flow behaviour exactly. Merging closed switches is a network reduction, to be taken up later
(B7), where this is revisited. The big-M rows of a free switch need a finite rating to be written.
Changes: new.

### D18 — A free switch is preventive or corrective, and non-costly
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Component model
Why: the choice is the `Redispatch` setup's, as for every other measure; no cost is charged for a
move, as for a phase shifter at its default.
Changes: new.

### D19 — `BusbarSwitch` and `CircuitBreaker` come after `Switch`
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Component model
Why: they would change nothing in the model at first, as `Cable` and `OverheadLine` do not; D13
names them as children and they are added once something tells them apart.
Changes: D13 (children deferred).

### D20 — B5 is v0.11.0, a minor bump
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Versioning and releases
Why: it adds a component type and the first integer model, more than a gap closed.
Changes: D1 (minor digit for an item that adds a component type).

### D21 — Closed switches in a loop share the flow equally
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Component model
Why: with every closed switch an equality, a loop of them leaves the split to the solver (a toy
run: HiGHS 1.0/0.0, Ipopt 0.5/0.5); unit-weight loop equations make it unique, well scaled and the
same in every solver.
Changes: new.

### D22 — Islands are checked for, not left to the solver
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Component model
Why: an islanded load gives INFEASIBLE with no explanation, and a false LOCALLY_SOLVED at 1.39e6 pu
in the current-based load flow (case14, bus 14); the literature keeps the switchable set from
islanding (Goldis, Fattahi, Pineda).
Changes: new.

### D23 — A free switch is supported in the current-based formulation; Juniper is a test dependency
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Component model
Why: one switch model in both formulations. The rating makes the free case nonconvex and
mixed-integer; the package builds it and the caller supplies the solver. Juniper 0.9.5 with Ipopt
and HiGHS solved a small such problem and resolves with the other test dependencies.
Changes: new (`Project.toml`: Juniper in `[extras]` and `[targets]`).

### D24 — A switch has two terminals for now
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Component model
Why: a one-of-n device and a group of two-terminal switches give the same mixed-integer program,
so the form is left until a double-busbar selector turns up; `position` being an `Int` keeps it open.
Changes: new.

### D25 — `lock` is an enum, `SwitchLock`
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Component model
Why: `NodeType` is one, and the table reader parses enums already.
Changes: D15 (names the type of `lock`).

### D26 — A loop that free switches can close gets a loop row that holds when they are closed
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Component model
Why: with no equation on it, a loop of free switches lets the problem split its flow as it likes and
undercut every setting of the locked model (toy: 5.4 against 12.6). One big-M row per simple cycle
of the switches that can be closed is exact; it is exponential in the worst case, so building errors
above a cycle count, and it needs a finite rating on every switch of the loop.
Changes: D21 (a free switch's loop).

### D27 — The documentation cites literature through DocumenterCitations
Date: 2026-10-04 · Decided by: Tom Van Acker · Area: Documentation
Why: the switch page cites ten papers and other pages will cite more; one `refs.bib` and generated
author-year links keep the references consistent, instead of a hand-written list on each page.
Changes: new (`docs/Project.toml`: DocumenterCitations; `docs/make.jl`: the plugin;
`docs/src/refs.bib` and `docs/src/references.md`).
