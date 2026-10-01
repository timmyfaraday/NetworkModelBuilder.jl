# NetworkModelBuilder.jl — Gap Closure Plan

**Source**: a multi-axis comparative review of this package against `SmaLoadFlow`
(Elia's Python dispatch tool), conducted 2026-09-15 → 2026-09-28. Findings below
are limited to axes where the review found NetworkModelBuilder.jl (NMB) behind,
weaker, or carrying a confirmed defect. Every item was checked empirically
(actually run, not just read) unless stated otherwise. Axes where NMB already
leads (extendability, dependency/CVE exposure, solver-failure UX, Matpower
input robustness) are intentionally out of scope here — see "Non-gaps" at the
end so this plan doesn't accidentally motivate regressing them.

**Audience**: whoever picks up maintenance work on this package next.

## How to read this

- **Priority** — `P0` quick/low-risk fixes, `P1` process infrastructure,
  `P2` structural, `P3` organizational/longer-horizon.
- **Effort** — `Small` (one function, no API change), `Medium` (touches a
  public surface or adds a new process), `Large` (no single PR closes it).
- File/line references are relative to the repo root and were correct as of
  the review date; re-check before editing if time has passed.

## Summary table

| # | Gap | Priority | Effort |
|---|-----|----------|--------|
| 1 | Doc quick-start examples fail outside one undocumented directory | P0 | Small |
| 2 | `parse_tables` raises a raw `BoundsError` on column-length mismatch | P0 | Small |
| 3 | `parse_tables` silently no-ops on an empty table set | P0 | Small |
| 4 | Concurrent type registration crashes (`ConcurrencyViolationError`) | P0 | Small |
| 5 | No `CHANGELOG.md` / no release process at v0.9.0 | P1 | Medium |
| 6 | Doc code examples are never executed in CI | P1 | Medium |
| 7 | "Validated against PowerModels.jl" is a frozen snapshot, not a live check | P1 | Medium |
| 8 | Central include/export file is a growing manual-edit tax | P2 | Medium |
| 9 | API ergonomics / onboarding curve vs. SmaLoadFlow | P2 | Large |
| 10 | No parallel-throughput option for long-horizon solves | P2 | Large |
| 11 | Bus factor — solo maintainer, ~3 weeks of project history | P3 | Large |

---

## P0 — Quick, low-risk fixes

### 1. Doc quick-start examples fail outside one undocumented directory

**Evidence**: the three pages that present a complete, standalone, runnable
example — [docs/src/index.md](docs/src/index.md#L19-L23),
[docs/src/problems/optimal_power_flow/lpf.md](docs/src/problems/optimal_power_flow/lpf.md),
and [docs/src/problems/redispatch/ivr.md](docs/src/problems/redispatch/ivr.md)
— all call `solve_lf("case14.m", ...)` / `solve_opf("case5.m", ...)` with a
bare filename. That file only physically exists at
`test/data/matpower/case14.m` (and `case5.m`); there is no copy under `docs/`.
Ran all three twice in a real Julia environment: from
`test/data/matpower/`, all three pass; from the repo root — where a normal
`]dev`'d user's REPL actually starts — **all three fail** with
`SystemError: opening file "case14.m"` (or equivalent). That's a 100% failure
rate on the only examples the docs claim are runnable, and it has been silently
true since these pages were written, because none of the code blocks use
Documenter's `@example`/`@repl` (see #6) — nothing has ever executed them.

**Root cause**: [src/io/matpower.jl:57](src/io/matpower.jl#L57) —
`isfile(path) || throw(ArgumentError("`$path` is not a file"))` — has no
fallback search path. The test suite already solves this exact problem for
itself via `case(name) = joinpath(@__DIR__, "data", "matpower", "$name.m")`
in [test/runtests.jl:28](test/runtests.jl#L28), but that helper is
test-only and never exposed to a real user session.

**Fix**: in `_read_matpower` ([src/io/matpower.jl:56](src/io/matpower.jl#L56)),
before the `isfile` check, fall back to the package's own bundled case files
when a bare filename isn't found relative to the working directory:

```julia
function _read_matpower(path::AbstractString)
    if !isfile(path) && !isabspath(path)
        bundled = joinpath(pkgdir(NetworkModelBuilder), "test", "data", "matpower", path)
        isfile(bundled) && (path = bundled)
    end
    isfile(path) || throw(ArgumentError("`$path` is not a file"))
    ...
```

This makes every doc example work unconditionally, regardless of the
caller's working directory, without changing behavior for any path that
already resolves. The tabular reader (`parse_file`/`parse_arrow` in
[src/io/common.jl](src/io/common.jl)) doesn't need the same fix — it has no
doc example that references a bundled test fixture by bare name.

**Verification**: re-run `sweep.py` / the per-file scripts in the scratch
harness described under "Reusable verification assets" below, invoked from
the repo root. Expect 3/3 passes instead of 0/3.

### 2. `parse_tables` raises a raw `BoundsError` on column-length mismatch

**Evidence**: fed 7 deliberately malformed tabular inputs through
`parse_tables` ([src/io/tables.jl:128](src/io/tables.jl#L128)). 6/7 produced
clean, specific `ArgumentError`s (missing `id` column, unregistered
component type, dangling node reference, duplicate IDs). The 7th — a table
whose columns have mismatched lengths — instead raised a raw
`BoundsError: attempt to access 2-element Vector{String} at index [3]`, with
no indication of which table or which columns disagree. The Matpower reader
already has the equivalent check for its own "rows of unequal length" case
([src/io/matpower.jl](src/io/matpower.jl), confirmed via the same test pass)
and produces a clear `ArgumentError` — this reader is the outlier.

**Root cause**: `_nrows(tbl)` ([src/io/tables.jl:36](src/io/tables.jl#L36))
derives the row count from a single arbitrary column
(`length(_column(tbl, first(cols)))`); `_parse_components`
([src/io/tables.jl:~150](src/io/tables.jl#L150)) then indexes every other
column by the same range with no length check first.

**Fix**: in `_parse_components`, validate that every column in `cols` (and
every profile column pulled from `fields`) has length equal to `_nrows(tbl)`
before the `for r in 1:_nrows(tbl)` loop, and throw an `ArgumentError` naming
the offending column and its actual length — mirroring the Matpower reader's
message shape.

**Verification**: re-run `malformed_tables_test.jl` from the scratch harness
(see below). Expect 7/7 clean `ArgumentError`s.

### 3. `parse_tables` silently no-ops on an empty table set

**Evidence**: same malformed-tabular test pass — an entirely empty
node/edge/unit table set raised no error at all. Not incorrect, but
unhelpful: a caller who accidentally passes empty tables gets an empty
`NetworkData` with no signal that something upstream (a filter, a join) ate
all their rows.

**Fix**: in `parse_tables`, after building `I`/`E`/`U`, warn or throw if all
three are empty — a one-line `isempty(I) && isempty(E) && isempty(U) &&
@warn "parse_tables built an empty network — check the input tables"` is
enough; doesn't need to be a hard error since an intentionally-empty network
may be a valid (if unusual) input.

**Verification**: extend `malformed_tables_test.jl` with an
all-empty-tables case; expect a warning/error instead of silent success.

### 4. Concurrent type registration crashes

**Evidence**: `_EDGE_TYPES` ([src/comp/edge/edge.jl:17](src/comp/edge/edge.jl#L17)),
`_UNIT_TYPES` ([src/comp/unit/unit.jl:16](src/comp/unit/unit.jl#L16)), and
`_MODELS` ([src/core/model.jl:64](src/core/model.jl#L64)) are plain
`Vector`s; `register_edge_type!`, `register_unit_type!`, and
`register_model!` each do an unsynchronized check-then-`push!`. Launched
Julia with 56 threads, pre-defined 300 dummy edge types, registered them
concurrently via `Threads.@threads`: **the first attempt crashed**, with
Julia 1.12's own runtime race detector:
`ConcurrencyViolationError("Vector can not be resized concurrently")`.

Blast radius is narrow — a separate test confirmed **concurrent reads are
safe** (56 threads × 200,000 reads each, ~89.6M total, 0 errors), because the
realistic usage pattern (register once at module load, then solve many
`NetworkModel`s in parallel, which only reads via `edge_types()`/
`unit_types()`, both already `copy()`-on-return) never hits the unsafe path.
The bug only bites dynamic/parallel *registration* — e.g. a parallel test
harness or plugin-style loader that defines and registers new types from
multiple threads at runtime.

**Fix**: wrap the three `register_*!` functions' check-then-push in a
`ReentrantLock` (one lock per registry, or one shared lock — registration is
rare enough that contention is irrelevant). Negligible cost on the hot path
since it never touches the read functions.

```julia
const _EDGE_TYPES_LOCK = ReentrantLock()
function register_edge_type!(::Type{T}) where {T<:AbstractEdge}
    lock(_EDGE_TYPES_LOCK) do
        T in _EDGE_TYPES || push!(_EDGE_TYPES, T)
    end
end
```

**Verification**: re-run `thread_safety_test.jl` from the scratch harness
(see below) after the fix. Expect 0 crashes across repeated runs; keep
`thread_safety_readonly_test.jl` passing as a non-regression check.

---

## P1 — Process & maintainability infrastructure

### 5. No `CHANGELOG.md` / no release process at v0.9.0

**Evidence**: `Project.toml` reports `version = "0.9.0"`
([Project.toml:3](Project.toml#L3)); no `CHANGELOG.md` exists at the repo
root (confirmed directly). By contrast, SmaLoadFlow runs
`python-semantic-release` against conventional commits to auto-generate its
changelog and publish in one step — a future maintainer inherits a working,
low-friction way to see what changed between any two versions.

**Fix**: at minimum, start hand-maintaining a `CHANGELOG.md` from this point
forward (a `## [Unreleased]` section, filled in per PR or per release, is
enough to start). If commit messages are made to follow a light convention
(`fix:`, `feat:`, `breaking:`), a generator (e.g.
`github_changelog_generator`, or a small script against `git log`) can
backfill 0.1.0 → 0.9.0 from existing history — the repo already has enough
commit granularity (55 commits) for this to be worth doing once, not
continuously by hand.

**Verification**: n/a (process change) — track as done once `CHANGELOG.md`
exists and at least one subsequent release updates it.

### 6. Doc code examples are never executed in CI

**Evidence**: zero uses of Documenter's `@example`/`@repl`/`@setup` across
`docs/src/` (confirmed via search) — every code block is a plain ` ```julia `
fence, so the docs build never executes any of them. This is *why* gap #1
went undetected. There is already a precedent in this exact repo for
CI-gating a doc-quality problem: [test/docs.jl](test/docs.jl) — included in
[test/runtests.jl](test/runtests.jl#L47) — checks that every markdown table
in `docs/src/` actually renders as a table (a narrower, earlier-caught doc
bug). It does not execute any code blocks.

**Fix**: two complementary options, not mutually exclusive:
- Convert the three complete examples (#1) to Documenter `@example` blocks,
  so `docs/make.jl`'s own build fails if they ever break again.
- Extend `test/docs.jl` with a check that walks `docs/src/**/*.md`,
  extracts fenced ` ```julia ` blocks that look like complete examples
  (contain `using NetworkModelBuilder`), and `include()`s each one in a
  scratch `Module`, asserting no exception — this is a generalized,
  permanent version of the ad-hoc `sweep.py` harness used for this review
  (see below), wired into the existing `@testset "docs"`.

**Verification**: CI fails if `case14.m`-style breakage (#1) is ever
reintroduced, without needing another manual doctest sweep.

### 7. "Validated against PowerModels.jl" is a frozen snapshot, not a live check

**Evidence**: the claim (referenced in `docs/` and test comments) is backed
by static numeric constants embedded in tests, not a live cross-check that
actually runs PowerModels.jl in CI. If NMB's own numerics drift, or if this
were ever revisited, nothing would catch a real divergence from
PowerModels.jl's current behavior — only against a value frozen at whatever
commit those constants were written.

**Fix**: either (a) add PowerModels.jl as a test-only dependency and run a
small live cross-check for at least one case file in CI, accepting the
extra CI weight, or (b) if that's judged not worth the dependency, change
the docs/comment wording from "validated against" to "matches a
PowerModels.jl reference snapshot captured on `<date>`" so the claim's
actual strength is accurately represented.

**Verification**: n/a for (b) — a docs/wording change. For (a), a CI run
that would fail if PowerModels.jl and NMB disagree beyond tolerance.

---

## P2 — Structural / architecture-adjacent

### 8. Central include/export file is a growing manual-edit tax

**Evidence**: [src/NetworkModelBuilder.jl](src/NetworkModelBuilder.jl) (196
lines) is the single most-churned file in the repo — 25 of 55 commits
(~45%) touch it, because every new component/problem/formulation type still
needs a manual one-line `include`/`export` edit there, even though the
registries themselves (`_EDGE_TYPES` etc.) are otherwise open and
self-registering. Not a bug — nothing here is incorrect — but a structural,
quantified maintenance cost that scales linearly with the package's growth
and is the one place every contributor's change collides with every other's.

**Fix** (pick one, both are reasonable trade-offs, don't do this
speculatively — only worth it if growth continues at this rate):
- Auto-discover component files via a directory scan (`include` every
  `.jl` file under `src/comp/edge/`, `src/comp/unit/`, etc.) instead of
  naming each one — trades one explicit list for "drop a file in the right
  folder and it's picked up," consistent with the registries' own
  philosophy.
- Leave includes manual (explicit is often preferable for load-order
  clarity in Julia) but split the single file into one include-list per
  subsystem (`src/comp/_includes.jl`, `src/prob/_includes.jl`, ...) so
  concurrent additions in different subsystems stop colliding in the same
  file/lines.

**Verification**: after the change, re-check commit churn concentration
over the next several months of activity — this is a trend to monitor, not
a one-time test.

### 9. API ergonomics / onboarding curve vs. SmaLoadFlow

**Evidence**: NMB requires understanding multiple dispatch and two
orthogonal type parameters (`NetworkModel{ProblemType,FormulationType}`)
before anything makes sense — a real conceptual on-ramp for anyone not
already comfortable with Julia or PowerModels.jl-style modeling.
Result access is a stringly-typed nested `Dict{String,Any}`
(`nw_solution(result)["node"]["4"]["vm"]`) — no autocomplete, no type
safety, no built-in plotting. SmaLoadFlow's `RunResultXr` is xarray-based —
labeled, sliceable, directly plottable — and ships matplotlib helpers aimed
at "make this easy to look at."

**Fix** (longer-horizon, no single PR closes this):
- Add a typed, structured results accessor as an *addition* alongside
  `nw_solution` (not a replacement — the dict is a reasonable
  PowerModels.jl-familiar default) for callers who want IDE
  autocomplete/type safety, e.g. a small `NamedTuple`/struct view over a
  solved network's per-node/per-edge/per-unit quantities.
- Add a "concepts for newcomers" doc page that maps the two-axis dispatch
  model to concrete, worked examples side by side (what SmaLoadFlow calls a
  `PowerSystem` + `SolveOptions`, NMB calls a `NetworkModel{P,F}` — a
  translation table like this would meaningfully shorten the on-ramp for
  anyone coming from a more application-shaped tool).

**Verification**: qualitative — track via onboarding feedback from the next
new contributor or user, not an automated test.

### 10. No parallel-throughput option for long-horizon solves

**Evidence**: from the computational-standpoint review — SmaLoadFlow scales
long horizons via fixed-size batching plus OS-level **multiprocessing**:
independent LPs solved in parallel processes
([executors/process.py](D:/TVA/PythonProjects/SmaLoadFlow/sma_load_flow/engine/executors/process.py)),
giving strong wall-clock throughput on many-core hardware (confirmed on a
112-core machine) at the cost of only approximate temporal coupling across
batch boundaries, and every process rebuilding its model from scratch. NMB's
`solve_rolling_horizon` ([src/prob/rd.jl:620](src/prob/rd.jl#L620),
[src/core/rebuild.jl](src/core/rebuild.jl),
[src/core/window.jl](src/core/window.jl)) is a first-class mechanism with
model reuse/warm-start and **exact** state carry-over (`initial_state`)
between windows — but each window depends on the previous window's solved
state, so the solve is inherently sequential. It cannot exploit multi-core
hardware the way SmaLoadFlow's independent-batch multiprocessing can. This is
an architectural trade-off (exact coupling vs. parallelizability), not a
defect, and it's the one place the computational-standpoint review gave
SmaLoadFlow a clear, durable edge.

**Fix** (needs a design decision, not a bug fix — options, not a
prescription):
- Option A — add an opt-in **chunked-parallel mode** alongside (not
  replacing) the existing sequential rolling horizon: partition a long
  horizon into independent chunks, solve chunks concurrently
  (`Threads.@threads`, safe per the concurrent-read confirmation in gap #4),
  and stitch chunk boundaries with an approximate boundary condition (e.g. a
  forecast or previous-solve terminal state rather than the exact solved
  one) — the same trade-off SmaLoadFlow already makes, offered as a choice
  rather than forced on every caller.
- Option B — document and wrap the *embarrassingly-parallel* case NMB
  already supports today with zero code changes: solving many independent
  `NetworkModel`s concurrently (different scenarios/contingencies/Monte
  Carlo draws, not windows of one horizon) via `Threads.@threads`. This is
  **not** the SmaLoadFlow-equivalent — that's Option A. SmaLoadFlow's
  multiprocessing executor manufactures independence (cuts one continuous
  horizon into batches, approximates the coupling at the cuts) and then
  parallelizes the result; Option B only parallelizes work that's already
  independent, with nothing to approximate, because no continuous horizon is
  being cut. It doesn't touch the sequential rolling-horizon algorithm at
  all, and gives **zero speedup for a single long horizon** — it only helps
  when the actual workload is multiple separate horizons/scenarios run side
  by side.
- Either way, benchmark first: measure actual wall-clock throughput of the
  current sequential rolling horizon on a realistic long horizon on
  multi-core hardware before committing to Option A's added complexity — if
  model-reuse/warm-start already closes most of the gap raw parallelism
  would buy, the honest fix may be "document the trade-off," not "add
  parallelism."

**When A actually differs from B**: the distinction is entirely contingent
on real inter-window dependence existing. If a given horizon's windows carry
no genuine state coupling (no storage state-of-charge, ramping, or
commitment continuity linking one window to the next), Option A degenerates
exactly into Option B: chunk size shrinks to one window, the boundary
approximation becomes vacuous (there's nothing left to approximate), and
"solve chunks concurrently" is identical to "solve independent
`NetworkModel`s concurrently." At that point there'd be no reason to call
`solve_rolling_horizon` at all — it would just be $N$ independent
single-period solves, Option B's use case by definition. One wrinkle
survives even then: rolling horizon typically also warm-starts window
$i{+}1$ from window $i$'s solution for solver speed, not correctness — going
fully parallel forfeits that head start, a secondary cost distinct from the
coupling question. Practical implication: confirm genuine inter-window
coupling exists in the workloads that matter (already established for NMB's
current `initial_state` mechanism) before investing in Option A — a weakly
coupled horizon makes Option A wasted effort when Option B is already free.

**Verification**: a benchmark script solving a representative long horizon
(e.g. a year of hourly windows) sequentially vs. (if Option A is built)
chunked-parallel, on the same multi-core hardware used for the
thread-safety tests, reporting wall-clock time and confirming any
chunked/approximate result stays within an explicitly stated tolerance of
the exact sequential solve.

---

## P3 — Organizational / longer-horizon

### 11. Bus factor — solo maintainer, ~3 weeks of project history

**Evidence**: 55 commits, all but a Documenter.jl bot authored by Tom Van
Acker, spanning 2026-08-26 → 2026-09-15 (~3 weeks) at the time of review.
SmaLoadFlow, by comparison, has 211 commits across 14 months from 2 real
contributors. This isn't a code defect — it's the root cause underlying
several items above (no changelog process, no second reviewer on the
include-file churn, less real-world mileage to have surfaced latent bugs
the way SmaLoadFlow's usage has for itself).

**Fix**: not something a PR closes. Concretely: get a second person
reviewing/co-committing (even lightly), and keep leaning on the existing
`.github/copilot-instructions.md` + custom agent modes (`plan`/`implement`/
`review`/`debug`/`document`) as a substitute for tribal knowledge — that
investment is already unusually good here and is worth explicitly
maintaining as the package grows, precisely because there's only one person
who currently holds the rest of the context.

**Verification**: n/a — track via contributor count / commit distribution
over time.

---

## Reusable verification assets

This review built and ran real regression checks rather than relying on
reading the source alone. They currently live outside the repo, in a
scratch Julia environment at
`C:\Users\SM5256\AppData\Local\Temp\nmb_doctest\` (machine-local, not
guaranteed to persist):

- `malformed_test.jl` — 8 deliberately broken Matpower files, asserts each
  produces a clean, specific error.
- `malformed_tables_test.jl` — 7 deliberately broken tabular inputs; this is
  the harness that caught gaps #2 and #3.
- `thread_safety_test.jl` — 56-thread concurrent registration stress test;
  this is the harness that caught gap #4.
- `thread_safety_readonly_test.jl` — 56-thread, ~90M-read concurrent-read
  safety check (confirms the *safe* case stays safe after any registry fix).
- `sweep.py` + `scratch/*.jl` — extracts and executes every code block from
  every `docs/src/**/*.md` page and the README; this is the harness that
  caught gap #1.

**Recommendation**: promote these into `test/` as permanent regression
tests (e.g. `test/malformed_input.jl`, `test/thread_safety.jl`, folded into
the `test/docs.jl` extension described in gap #6) rather than leaving them
as one-off scratch scripts — the package currently has no test coverage for
any of the four P0 gaps, meaning nothing stops them from being
reintroduced.

## Suggested sequencing

1. **P0 items (1–4)** — small, isolated, no design decisions; each can be
   its own short PR with the corresponding scratch script promoted into
   `test/` as its regression test in the same PR.
2. **P1 items (5–7)** — process/infrastructure; #6 should land alongside or
   immediately after #1, since it's what prevents #1-shaped bugs from
   recurring silently again.
3. **P2 items (8–10)** — structural; worth scoping properly rather than
   rushing, since all three involve a real design decision rather than a bug
   fix. Benchmark before starting #10 — it may turn out documentation is
   the right fix, not new code.
4. **P3 (11)** — ongoing, not a PR; revisit periodically as the project
   matures.

## Non-gaps — don't regress these

For balance: the same review found NMB clearly ahead of SmaLoadFlow on
several axes, none of which this plan touches. Worth stating explicitly so
remediation work doesn't accidentally erode them:

- **Extendability** — open, self-registering component types
  (`register_edge_type!` etc.), proven by `test/multiterminal.jl` and
  `test/hierarchy.jl` defining new types entirely outside `src/`.
- **Dependency exposure** — ~19 real third-party dependencies, 0 security
  advisories on the two with any track record (JuMP, MathOptInterface),
  versus SmaLoadFlow's 115 dependencies and ~50+ advisories across 7
  packages (including confirmed RCE paths in a pinned GitPython version).
- **Solver-failure / infeasibility UX** — `nw_solution` raises a specific
  `ArgumentError` naming the actual JuMP termination status, and the
  package ships a tested, structural pattern (soft/priced constraints) for
  turning hard infeasibilities into solvable ones. SmaLoadFlow has no
  visible handling of this at all.
- **Matpower input robustness** — 8/8 malformed-file cases produced clean,
  specific errors, including a dangling branch-to-nonexistent-bus reference
  that a naive reading of the source suggested would slip through
  uncaught, and didn't.
