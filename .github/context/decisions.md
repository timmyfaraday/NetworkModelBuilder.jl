# Decisions

The rules that still constrain NMB. Read the section for the area you are touching before
changing it.

How to use this file:
- A new decision gets the next free id (**D89**), goes in the Log at the bottom, and is written by
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

## Agent setup

- **The hook engine and the generic skills come from the `sma-coding-second-brain` plugin; the repo
  keeps `launch.py`, `agent-hooks.json`, `hook_config.json` and five override skills** (D37):
  `new-spec`, `new-run-prompt`, `review-run-report`, `probe-environment` and `pr-description` stay in
  `.github/skills/` and shadow the plugin's, until the plugin's versions are project-neutral (B15).
- **No `.github/copilot/settings.json` while NMB is public** (D38): the plugin's template names its
  internal repository URL and recommends a plugin an outside contributor cannot install. Add the
  file from the template when the package moves internal (B17).
- **An empty, gitignored `.venv` at the repo root** (D39): `launch.py` adds a "no .venv" note to
  every session start, and the engine is stdlib-only, so the venv holds nothing. It goes when the
  plugin can turn the note off (B16).
- **The Stop hook asks once per session for a docs update when `src/` changed and `docs/` did not**
  (D40): `docs_watch_prefixes` in `hook_config.json`, since `README.md` and the docs examples are
  load-bearing.
- **"A question, observation or open idea is not a go-ahead to edit" is hard rule 8 of
  `copilot-instructions.md`** (D41), taken from the plugin's template.

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
- **The measure step has guard rails that reproduce defects that happened** (D47): a test that a
  lookup a model build calls in loops allocates nothing, red on the code before v0.12.2; a
  `benchmark/` environment of its own with BenchmarkTools, never a dependency of the package, run by
  hand beside a same-day control and not in CI; and `chunk.csv` carries the GC time and the bytes
  allocated of the chunk and of steps 2 and 3. `@inferred` is not added where it would have passed on
  the defect it is meant to catch.
- **A constructor refuses input a model cannot use, in service or not** (D48): `Node`, `Generator`,
  `FixedLoad`, `Shunt` and the branch family check ordered limits, finite setpoints and impedances,
  `r² + x² > 0`, `s_max >= 0` and an `l_km` that is NaN (unknown) or `>= 0` (D50), with `all_nw` so that a `NetworkVector` is checked at
  every index, and raise an `ArgumentError` naming the component. `v_base_kv` may be 0, which means
  unknown. The signs of `r` and `x`, and `pg` against its limits, are not checked.
- **The package's own state is fields, not keys of `nm.ext`, and a key is not reused** (D49):
  `registered` is a field of `NetworkModel`; the registers that only repeated what
  `registered_constraints` holds are gone; `ext` holds what the caller put there. `variable!`, `variables!`
  and `variable_container!` raise an `ArgumentError` where a key is asked for again with another id type,
  container kind or index set, and `constrain!` where one `(nw, key, id)` is written twice in the first build
  of a model. An extension prefixes its keys.
- **What several types of a family share lives in the family file, and what one type alone uses lives in that
  type's file** (D51): `edge/edge.jl` and `unit/unit.jl`, not a file of fragments of their own.
- **A rating and an angle limit are separate constraints, and `fnct_edge_rating_linear!` is the one linear rating, for
  two terminals as for more** (D52); `constraint_linear_limits!` is removed.
- **A quantity is named `symbol_primary_secondary[_unit]`** (D55): lowercase snake_case, singular, a descriptor of at most
  4 letters from the closed lists of `knowledge/nomenclature.md`, empty slots dropped, the lists disjoint and used in a fixed
  order (what, part, qualifier, unit), a key with at least one descriptor; what is not a quantity is a plain word. The symbols are `v i p q s r x g b e t c l z k η`: current is `i` and cost
  is `c`, in the docs mathematics too, and `η` is the one non-ASCII symbol (D56). In v0.14.0, spec `knowledge/plan/naming.md`.
- **A variable key names the owner, a field does not, and a local equals its key** (D57): `:p_gen` and `Generator.p_max`; a role
  only one owner has takes the owner's place (`:p_chg`). Inside the package `rate_a` is `s_max`, `angmin` and `angmax` are `v_angl_min`
  and `v_angl_max`, `base_kv` is `v_base_kv`, `baseMVA` is `s_base_mva`, `length_km` is `l_km`; Matpower, PowerModels and Zorba names
  live in their readers (D58).
- **A rename is a hard removal: no alias, no hint, every layer tested** (D59): the old name fails, and a test finds none left in
  `src`, `test`, `docs/src`, `scripts` and `benchmark`.
- **A solve takes `debug_mode::Bool = false`** (D69, from D61 and D67): true names every variable and constraint and calls
  `JuMP.set_string_names_on_creation(model, true)`; false builds no name and calls it with `false`, on a `jump_model` given by the caller too.
- **A key of `ext` the package reads for a quantity follows the grammar** (D62): a node's `:v_real_init`, `:v_imag_init` and
  `:v_angl_init` start the voltage (`init` is the qualifier of an initial value, as in `e_init`); an `ext` key that is not a quantity,
  such as `:source_id`, `:country` or `:zorba`, stays a plain word.

- **A constraint key is `cstr_<owner>_<role>`: the owner, then what the row states** (D63, D68): words from the closed lists of
  `knowledge/nomenclature.md`, singular, lowercase snake_case, with no formulation in it (as `:p_term` has none); the owner is the
  type, the family where several types write the row (D51), or the problem; a bound, a phasor part or a side goes in the id, never in
  the key.
- **`con` takes the same keys, the register's where an entry holds the rows of one key, and its ids stay component ids; its value is a row, or a tuple of rows in the order of the register's id parts** (D64, D70).
- **A constraint id is the component's id, or `(id, part...)`** (D65, D70): parts spelled as the nomenclature spells them, no old variable
  key, one shape per key within a formulation.
- **`constrain!` names the row `"$(nw)_$(key)[$id]"`, and `debug_mode` covers constraints as it covers variables** (D66, D69).
- **A constraint, the function that writes it and the dual it gives share one stem and take one prefix each: `cstr_`, `fnct_`,
  `dual_`** (D68): `cstr_node_balance`, `fnct_node_balance`, `dual_node_balance_real`; the `constraint_*` functions and the `"lambda*"`
  solution keys are renamed by a hard removal (D59). In v0.15.0, spec `knowledge/plan/naming-constraints.md`.
- **A limit is written in the most complete form that keeps the problem class of its formulation** (D73). A converter rating `s_max` is the circle on the net injection, `p^2 + q^2 <= s_max^2`, in `IVRFormulation`, which is already a nonconvex quadratic program; a limit on the active power alone in `LPFFormulation`, which has no reactive power; the box, a limit on `p` and one on `q`, in a linear formulation that has reactive power (none yet), since the circle would make it a second-order cone program. A new formulation says which of the three it takes.

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
- **A solution holds what was asked for: a rolling horizon builds the solution of the network indices
  it commits, and `report`, a `NamedTuple` whose `node`, `edge` and `unit` are each `true`, `false` or
  a vector of identifiers, says which families and components a solution holds** (D46). The default
  is everything, as before. A roll's `solution_processors` see the committed indices only. A typed core
  under the nested `Dict` stays open as Q9, behind the stop rule of its plan.

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
  position. A free one writes big-M rows, needs a finite `s_max`, which is an equipment limit in
  every dispatch problem whether or not the edge is monitored, and takes `v_angl_min`/`v_angl_max` as the
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
- **A transformer is one component, `Transformer`, with any number of windings; `TapChanger`,
  `PhaseShifter`, `MultiWindingTransformer` and `AbstractTwoWindingTransformer` are removed, with no
  shims for the old names** (D28). Planned as v0.12.0, tagged `v0.12.0`; spec
  `knowledge/plan/unified-transformer.md`.
- **A transformer's data are vectors with one entry per winding, for two windings as for more; a
  scalar is accepted for two windings** (D29).
- **A table may give a number for a field with an entry per terminal of a `Branch` or a
  `Transformer`, as their constructors accept one; a field such as a generator's `cost` takes a list
  and nothing else** (D54).
- **A transformer is a T-model for every number of windings: a ratio and a series impedance per
  winding, meeting at a star point that carries the magnetising branch and is an edge variable, not a
  node; a π-equivalent is `y_m = 0` and `z_2 = 0`** (D30).
- **Whether a winding's ratio magnitude and angle can move is `oltc` and `pst`, each a `TapMode`
  (`FIXED`, `CONTINUOUS`, `STEPPED`) per winding, static over the network index; a `Bool` is accepted,
  `false` is `FIXED` and `true` is `CONTINUOUS`** (D31).
- **A stepped winding makes a dispatch problem mixed-integer, a second source after the free switch;
  continuous is the default and `STEPPED` is asked for, built after the continuous controls** (D32).
- **A transformer reports its tap per terminal, not per edge** (D33).
- **`oltc` and `pst` are non-costly measures, for now: moving a tap or an angle has no price, and a
  transformer has no `cost`** (D34). The price a phase shifter carried is removed; to be revisited.
- **A preventive measure tied to the base case builds no rows of its own at the network indices it
  is tied to; the rows that only restrict it are written once, at the base case** (D35).
- **A preventive winding that steps has no binaries of its own at the network indices it is held at:
  it reuses the base case's, and nothing is tied; its continuous ratio stays tied. A corrective one
  keeps a set per contingency** (D36).
- **A structure gate asks what the model's own guard asks of that field** (D43): `isfinite` of a limit,
  the ±π/2 test of an angle limit, `iszero` of a `DCLink`'s `p_loss_prop`. A generator limit that crosses
  1.571 pu is not a change of the shape of the model, and was read as one, so a rolling horizon with
  `reuse = true` rebuilt almost every window.
- **A repeated `topology` lookup is answered from the last answer, held in one atomic slot on the
  `Network`: a cache of a derivation, one entry however many network indices, not a table** (D45).
  Two entries if, after B21, `topology` is still above 3 % of the pipeline profile.
- **A cable and an overhead line are a `Branch` with another `l_km`, not types: `Cable` and `OverheadLine`
  are removed with no shim, `Branch` carries `l_km`, NaN meaning unknown and being the default** (D50). `AbstractBranch`
  stays as the extension hook. Planned as v0.13.0; spec `knowledge/plan/one-branch.md`.
- **A `Branch` has two or more terminals: `n` π-sections coupled at one point with the shunts there aggregated, two
  terminals being the single π as before; its fields are vectors with one entry per terminal, as a transformer's, and the
  shunt of a section, `g_shnt` and `b_shnt`, is split equally between its two ends** (D53).
  Spec `knowledge/plan/one-branch-terminals.md`.
- **`Storage` has a keyword `exact` that says how charging and discharging at once is kept out: `RELAXED` (the default, no integers, exact where the nodal price is not negative or the unit's own prices cover it), `EXACT` (optimal, binaries only where the relaxed solution violates, so mixed-integer with no duals) and `FROZEN` (the direction of each violating unit-step is fixed and the model solved again: feasible, not optimal); a `Bool` is accepted, `true` is `EXACT`, as `pst` accepts one** (D71, D78). `exact` is a plain word of `test/nomenclature.jl`. Spec `knowledge/plan/storage-review.md`.
- **The end of a storage unit's horizon is `terminal`, a list of typed conditions: `Pin`, `Cyclic`, `Floor`, `Value`, `Soft`, `Quad`; `e_fin` stays as `Pin`** (D72). `Pin`, `Cyclic` and `Floor` belong to the last window of a roll, the others to the end of every window; a target may be a profile over `:time`.
- **A storage unit prices what it charges and what it discharges apart, `c_chg` and `c_dch`, both at least 0; `c_thru` is removed with no shim** (D74), a hard removal (D59).
- **A storage unit has a lower energy bound `e_min`, 0 by default** (D75).
- **A storage unit out of service for part of the time holds its energy across the gap: no variables while out, the next step starts from the last in-service state, and `initial_state` reads that state** (D76). A `status` outage must give what zero ratings give today.
- **Detailed battery physics is not modelled: a power-dependent loss curve, rate capacity, a convexified degradation map (Fortenbacher et al.) and self-discharge** (D77). Noted in `docs/src/components/storage.md` and B39.
- **A storage cycle counts both sides, the energy into the store and the energy drawn from it, `Δt·(η_chg·p_chg + p_dch/η_dch)/2`, over `e_max` (a lossless full cycle counts 1); charging and discharging are priced apart, as Barrera et al. do** (D79, D81).
- **`k_cycl_max` holds over any sliding 24 h window, a row per step, and a roll carries the used allowance through `initial_state`; a market schedule over the budget is refused before the build** (D80).
- **`c_cycl` is charged per index on the same count, with no period, and `Generator.e_per_max` carries its calendar-period allowance across the windows of a roll through `initial_state`** (D82).
- **The `c_up` and `c_dn` of a storage unit are each finite and sum to at least 0 at every index; `check_storage(data)` refuses a market schedule whose own energy, `e_n = e_{n-1} + Δt(η_chg max(-p_set, 0) - max(p_set, 0)/η_dch)` from `e_init`, leaves `[e_min, e_max]`; the exported `scheduled_energy(data, u)` returns that trajectory and may be the target of `Pin`, `Soft` and `Quad`** (D83, D84, D85).
- **A corrective storage unit may carry a curative holding time `h_cur` [h], 0 by default: its net power over the contingency coordinates, the base case included, spans at most `e_max/h_cur` at every step; a preventive unit gets no row** (D86).
- **The `Storage` constructor does not compare `e_init` or `e_fin` with the bounds; `check_storage(data)` does, at the first and the last index, within 1e-5** (D87).
- **A rolling horizon checks the market schedule of its storage once, over the whole problem; its windows do not, `schedule = false`** (D88).

## Zorba pipeline (`scripts/`)

- **The last-resort prices are 10x the thermal ceiling for a monitored-line overload (477,000
  $/pu), 5x that overload price for spillage and 10x for load shedding** (D14), not the 3x/2x/4x
  rescaling tried while the false `INFEASIBLE` was being chased. The rescaling was never the fix;
  the reactance floor was (D13).
- **The pipeline has no N-1 screen; every hour is solved** (D42): a closed-form screen flagged 96.5 %
  (step 2) and 97.7 % (step 3) of the year's hours, so it skipped about 3 %. It never ran in the
  driver and refuses a `Switch`. `scripts/NMinusOneScreen.jl` is deleted; git has it at `e100616`.
- **The per-window feasibility check stays, made cheaper, and is to be re-evaluated** (D44): it costs
  2.4 s of 9.6 s a step-3 window. Once the pipeline has proven stable, whether to sample or drop it is
  Tom's call (B19).

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
- **Every concrete component type has its own parameters table and its own variables table, with the symbol, the code name, a
  description and a unit** (D60), and a test compares a type's table with its `fieldnames`.

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

### D28 — One `Transformer` replaces the four transformer types, with no shims
Date: 2026-10-05 · Decided by: Tom Van Acker · Area: Component model
Why: one device was four types, so a winding with both controls, or a control on a three-winding
transformer, could not be built; the old names change meaning (their fields become vectors), so keeping
them as shims would hide that.
Changes: new. Released as v0.12.0 and tagged `v0.12.0`, as v0.9.1-v0.9.7 were (D1 leaves tagging to Tom).

### D29 — A transformer's data are per-winding vectors, with a scalar shorthand for two windings
Date: 2026-10-05 · Decided by: Tom Van Acker · Area: Component model
Why: one shape for every number of windings beats a scalar field for two and a vector for more; the
shorthand keeps the two-winding call sites, such as a Matpower branch, readable.
Changes: new.

### D30 — A transformer is a T-model for every number of windings
Date: 2026-10-05 · Decided by: Tom Van Acker · Area: Component model
Why: the T is the usual transformer model and the package's three-winding star already was one; a
Matpower π is its `y_m = 0`, `z_2 = 0` case with a shunt per winding, so imports stay exact, and for two
windings the star voltage replaces the series current, six rows either way. One set of rows serves every
number of windings.
Changes: new.

### D31 — `oltc` and `pst` per winding, as the enum `TapMode`
Date: 2026-10-05 · Decided by: Tom Van Acker · Area: Component model
Why: whether the magnitude can move and whether the angle can are two independent facts; fixed, tap
changer, phase shifter and both are the four combinations. Static over the network index, so a model is
still updated in place. An enum rather than two Bools, since D32 needs a third value; a `Bool` still works.
Changes: new.

### D32 — A stepped winding makes a dispatch problem mixed-integer; continuous is the default
Date: 2026-10-05 · Decided by: Tom Van Acker · Area: Component model
Why: a real tap changer and a mechanical phase shifter step, but an integer variable costs the duals
(D16) and needs a nonconvex mixed-integer solver in the current-based formulation (D23), so it is
asked for with `STEPPED` and built after the continuous controls.
Changes: D16 (a second source of integers).

### D33 — A transformer reports its tap per terminal
Date: 2026-10-05 · Decided by: Tom Van Acker · Area: Component model
Why: with a ratio per winding an edge-level value cannot say which winding it belongs to, and
`solution_tables` already has a row per terminal.
Changes: new.

### D34 — A tap and an angle are non-costly measures, for now
Date: 2026-10-05 · Decided by: Tom Van Acker · Area: Component model
Why: the steering-plan pipeline never prices a phase shifter, a price per radian is a charge the
current-based formulation cannot carry, and a free switch is non-costly already (D18). May change.
Changes: new. Removes the priced phase shifter: `cost`, and `pst_cost` of `parse_zorba`.

### D35 — A held measure builds no rows of its own
Date: 2026-10-06 · Decided by: Tom Van Acker · Area: Component model
Why: the tie of a preventive phase shifter and the magnitude row each state wrote made the
current-based rows dependent at every feasible point, and Ipopt stopped at its first iteration on a
three-winding shifter set at zero (B14); without the repeated rows it solves, to the two-winding optimum.
Changes: new. Reuse of the base case's variables instead of a tie was left open, and is settled in D36.

### D36 — A held stepped winding reuses the base case's binaries
Date: 2026-10-06 · Decided by: Tom Van Acker · Area: Component model
Why: measured on a preventive stepped shifter with N contingencies and P positions, a tie leaves P×N
binaries and the same optimum as reuse, which leaves P: HiGHS takes 0.01-0.02 s either way, Juniper
0.07-23 s tied against 0.05-0.2 s reused. A corrective winding is the same under both, 100 and 200
binaries and about two minutes of Juniper at N = 4 and 8 with P = 25.
Changes: D35, its open question. Only the binaries; `tr`, `ti` and `ta` stay tied.

### D37 — The hook engine and the generic skills come from the second-brain plugin
Date: 2026-10-07 · Decided by: Tom Van Acker · Area: Agent setup
Why: the setup was ported into NMB and then extracted as a plugin shared by several repos; keeping a
vendored copy means fixes land twice. Five skills carry NMB content the plugin's versions lack: the
spec and run folders (`knowledge/plan/`, `agent-runs/`), the PowerModels.jl cross-check rules, the
Julia probe steps, and a GitHub pull request (the plugin's is Azure DevOps, with mypy and ruff gates).
Changes: new. Removes `.github/hooks/scripts/` and the `wrap-up`, `record-decision` and `setup-review`
copies. For the plugin: make those five skills project-neutral (B15).

### D38 — No `.github/copilot/settings.json` while NMB is public
Date: 2026-10-07 · Decided by: Tom Van Acker · Area: Agent setup
Why: the plugin's template file publishes the plugin's internal repository URL and recommends a plugin
that an outside contributor cannot install. The package is to move internal, and then the file is wanted.
Changes: new. Revert at the move: add the file from the plugin's `templates/copilot/settings.json` (B17).

### D39 — An empty, gitignored `.venv` for the hook launcher
Date: 2026-10-07 · Decided by: Tom Van Acker · Area: Agent setup
Why: `launch.py` appends "no .venv found, tell the user to create it" to every session start of a repo
without one, and NMB is Julia with no Python of its own. The engine is stdlib-only, so an empty venv
silences the note at no cost. For the plugin: a `hook_config.json` key to turn the note off (B16).
Changes: new.

### D40 — The Stop hook watches `src/` for a docs update
Date: 2026-10-07 · Decided by: Tom Van Acker · Area: Agent setup
Why: `README.md` claims are load-bearing and the docs examples run in `test/docs.jl` (hard rule 3), but
nothing asked for a docs page when `src/` changed. `docs_watch_prefixes` is `["src/"]`, `docs_prefix`
is `docs/`; the hook asks once per session, and the wrap-up may say why the docs do not change.
Changes: new.

### D41 — A question or observation is not a go-ahead to edit
Date: 2026-10-07 · Decided by: Tom Van Acker · Area: Agent setup
Why: the plugin's template carries this rule, and Tom asks for a plan first before most changes.
It is hard rule 8 of `copilot-instructions.md`.
Changes: new.

### D42 — The pipeline has no N-1 screen; `scripts/NMinusOneScreen.jl` is deleted
Date: 2026-10-07 · Decided by: Tom Van Acker · Area: Zorba pipeline
Why: over the year it flags 8,453 of 8,760 hours for step 2 and 8,555 for step 3, so a screen skips
about 3 % and the driver never used it. It cannot run on today's data (it refuses the 21 coupler
`Switch`es) and it broke when v0.12.0 removed `PhaseShifter`. Its independent check of the redispatch
flows goes with it; B12 used a same-day control run instead.
Changes: new rule in the Zorba pipeline section. Removes the file, closes B18.

### D43 — A structure gate asks what the model's own guard asks of that field
Date: 2026-10-07 · Decided by: Tom Van Acker · Area: Component model
Why: measured on the Zorba year, `same_structure` called two windows different whenever a generator's
`pmin` or `pmax` crossed ±π/2 = 1.571 pu, so the year built 1095 of 1095 step-2 and 8353 of 8760 step-3
windows from scratch with `reuse = true`. With the angle test off those fields, 5 of 6 step-3 windows
reused the model, 17 % less wall time, and a step-2 objective equal to 2.9e-14. The rows do not change.
The audit of the guards found the opposite hole too: a `DCLink`'s transfer variable exists only where
`loss_prop` is non-zero, which no gate told apart, so an update kept a dead transfer variable and loss
row (32 variables against 31 fresh); the objective was equal in the three cases checked.
Changes: new rule in the Component model section; edits `_gate` in `src/core/window.jl`.

### D44 — The per-window feasibility check stays, cheaper, and is re-evaluated later
Date: 2026-10-07 · Decided by: Tom Van Acker · Area: Zorba pipeline
Why: the check guards against a solver returning OPTIMAL for a point that breaks node balance, found
with the 1e-7 couplers; those are switches now and 365 of 365 chunks of the year run had zero first
violation, but one run is not proof, and the check costs 25 % of a step-3 window. It is made cheaper
without dropping any of what it checks; whether to sample or drop it comes back once the pipeline has
proven stable (B19).
Changes: new rule in the Zorba pipeline section.

### D45 — A repeated topology lookup is answered from the last answer, held in one atomic slot on the `Network`
Date: 2026-10-09 · Decided by: Tom Van Acker · Area: Component model
Why: `topology` derived its answer on every call, 80-142 times per network index in a model build, and was 13 % of a rolling horizon's wall time; one remembered answer took `update_model!` of a redispatch on case14 from 6.6-7.1 ms to 4.8-5.3 ms, and it keeps "derived, never tabulated" true, being one entry however many indices there are. Hoisting the lookup meant over 130 call sites in 16 files; one entry, not two, since two gave 4.76 against 4.86 ms.
Changes: new rule in the Component model section. Revise to two entries if, after B21, `topology` is still above 3 % of the pipeline profile (the redispatch hit rate goes 0.913 to 0.967); edit this rule in place then.

### D46 — A solution holds what was asked for: a roll builds the committed indices, and `report` names the rest
Date: 2026-10-09 · Decided by: Tom Van Acker · Area: Results access
Why: `build_solution` was 16 % of a rolling horizon's wall time and a step-3 window of the pipeline holds 91 MB of it, until the chunk ends, yet a roll keeps only the committed indices and the pipeline reads no node and 113 of 439 edges. Building only what is kept and what is asked for (estimated -66 % of the entries on step 3) needs no change to what a default solve returns; a typed core under the nested `Dict` (Q9) is left until that is measured.
Changes: new rule in the Results access section; D11 stands, the nested `Dict` is still the default result. A roll's `solution_processors` see the committed indices only; its one user reads the model.

### D47 — The measure step has guard rails: a hot-path allocation test, a `benchmark/` environment, and GC columns in `chunk.csv`
Date: 2026-10-09 · Decided by: Tom Van Acker · Area: Code conventions
Why: B6's boxed field loop cost 12 % of a roll and no correctness test saw it, and `@inferred` would not have either: on the sources before v0.12.2 it passes for `has_nw_data` and `nw_component`, while `has_nw_data` allocates 1,248-2,176 B a call there and 0 now. The profiles behind B6 sit in the gitignored `scratch/`, and `lessons.md` still says the cause of the threads not scaling (a shared garbage collector) is not proven.
Changes: new rule in Code conventions. Tom chose the allocation checks only, BenchmarkTools in its own `benchmark/` environment, six GC columns in `chunk.csv` (chunk, step 2, step 3) and one same-day pair of 7 threads against 7 processes after they land. The `chunk.csv` columns are a change to a file format.

### D48 — A constructor refuses input a model cannot use, in service or not
Date: 2026-10-10 · Decided by: Tom Van Acker · Area: Code conventions
Why: 19 of 19 invalid inputs built without complaint (`Generator(pmin = 2, pmax = 1)`, `Node(vmin = 1.1, vmax = 0.9)`, `Branch(r = 0, x = 0)`, NaN in a setpoint, a negative rating or length), and one reached the solver as an `INFEASIBLE` with nothing pointing at it. The rules were run over the four bundled Matpower cases and the Zorba year (8,760 hours, 234 nodes, 93 generators, 234 loads, 399 branches): only `base_kv > 0` failed, on case14, whose buses carry 0, so `base_kv` may be 0 for unknown.
Changes: new rule in Code conventions. Tom chose the proposed set over a smaller one (ordered limits and NaN only) and a larger one (the signs of `r` and `x`, `pg` inside its limits, which would refuse series capacitors and a market dispatch the redispatch is there to fix), validation of components out of service too, and v0.12.8 over v0.13.0.

### D49 — The package's own state is fields, not keys of `nm.ext`, and a key is not reused
Date: 2026-10-10 · Decided by: Tom Van Acker · Area: Code conventions
Why: `ext` is the caller's free-form storage, yet the package kept nine registers in it, and seven of them (`:redispatch_control`, `:overload_peak`, `:storage_balance`, `:storage_final`, `:storage_cycles`, `:generator_energy`, `:flexible_load_energy`) are written and never read in `src/`, `docs/` or `scripts/`: the references they hold are all in `registered_constraints`, and `:redispatch_control` alone is 66,431 entries and 7.3 MB of its own in one held step-3 model (the 56.5 MB that `Base.summarysize` gives for it counts the JuMP model its references reach). A typed field is not a speed item, the accessor is 0.3 % of an update. A key asked for again with another index set was accepted four ways out of five (`variables!(:x, 1:3)` then `(:x, 1:5)` returns the first container), the fifth a `MethodError` far from the cause; the `:vsr` incident in `lessons.md` was this.
Changes: new rule in Code conventions. Tom chose a typed `registered` field and deleting the seven registers (`:redispatch` stays, it is the documented input of `solve_rd`), an error for a variable key reused and one for a constraint id written twice in a build, and v0.12.9 over v0.13.0. The second is checked in the first build of a model only, which costs nothing in an update and is where a structural collision shows.

### D50 — A cable and an overhead line are a `Branch` with another `length_km`, not types
Date: 2026-10-10 · Decided by: Tom Van Acker · Area: Component model
Why: `Cable` and `OverheadLine` are `Branch` plus a `length_km` nothing reads, and the same as each other; no method in `src/` dispatches on either, no reader builds them, and `dynamic_rating`, the only method written for them, has no caller. Three registered types cost about 0.2 ms of a 1,171 ms step-3 update, so this is not a speed item.
Changes: new rule in Component model; the `length_km` clause of the D48 rule edited, NaN is valid and means unknown. Tom chose one `Branch` with `length_km` over a `construction` flag and over merging the files only, a hard removal over one release of shims, `dynamic_rating` kept for every `AbstractBranch`, and v0.13.0 over v0.12.10; `length_km` is NaN by default.

### D51 — What several types of a family share lives in the family file
Date: 2026-10-10 · Decided by: Tom Van Acker · Area: Code conventions
Why: `pi_model.jl` held the π-section only a branch writes, the rating, angle and linear-flow fragments a branch and a transformer share, and the one rating function only a transformer calls; the unit side keeps `constraint_unit_power!` in `unit/unit.jl` already. Proposed by Tom.
Changes: new rule in Code conventions. Branch-only code goes to `branch.jl`, shared code to `edge.jl`, transformer-only code to `transformer.jl`, and `pi_model.jl` is deleted.

### D52 — A rating and an angle limit are separate constraints
Date: 2026-10-10 · Decided by: Tom Van Acker · Area: Code conventions
Why: `constraint_linear_limits!` wrote a rating and the angle limit together for two arcs and one scalar rating, and the transformer chose it for two windings with `minimum(tf.rate_a)` and `constraint_linear_ratings!` for more; in IVR the two were already apart (`constraint_edge_rating!`, `constraint_edge_angle_difference!`). A lossless two-terminal edge has `p_2 = -p_1`, so a rating at each terminal is the same feasible set.
Changes: new rule in Code conventions. `constraint_linear_limits!` is removed, the angle row becomes `constraint_linear_angle_difference!`, and `constraint_linear_ratings!`, which the branch now calls too, goes to `edge.jl` with the other shared fragments (D51's Why called it the transformer's).

### D53 — A branch has two or more terminals, as `n` π-sections coupled at one point
Date: 2026-10-10 · Decided by: Tom Van Acker · Area: Component model
Why: the graph carries edges of any number of terminals and the transformer already has windings, but a branch had exactly two. Tom's model is `n` π-sections, section `k` from terminal `k` to one point, the shunts at the point aggregated: the equations of the transformer's star with neutral ratios, so the two can be checked against each other.
Changes: new rule in Component model. Tom chose per-terminal vectors like the transformer's (D29) and one item with two stages over two items; the shunt fields are `g_sh` and `b_sh`, the total of a section split equally between its two ends, and `g_fr`, `b_fr`, `g_to`, `b_to` are removed with no shim, so an asymmetric shunt is no longer expressible (nothing in the repository uses one).

### D54 — A table may give a number for a field with an entry per terminal
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Component model
Why: `r`, `x`, `g_sh`, `b_sh` and `rate_a` of a `Branch` became vectors (D53), and the table reader asked for a list wherever a field is a vector, so every table of two-terminal branches failed (8 testsets of `test/tables.jl`). The constructors take a number for two terminals (D29, D53), and a flat table holds Matpower-like rows.
Changes: new rule in Component model. Tom confirmed the reader's change: a type opts in through `_per_terminal_data`, which `Branch` and `Transformer` do, so a `Transformer` row may now give a number too; `cost` of a generator stays a list.

### D55 — A quantity is named `symbol_primary_secondary[_unit]`
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: names were Matpower's, or one letter and a suffix chosen where it was written (`:pg`, `:psc`, `:csi`, `:vpr`), so one letter carried several meanings (`s` six, `p`, `t` and `c` three each), a bound was glued (`pmax`), underscored (`tm_min`), a prefix (`max_energy_per_period`) or a word (`charge_rating`), and one quantity had two spellings (`gs` and `g_sh`). Surveyed: 72 field names, 42 variable keys, about 60 keywords.
Changes: new rule in Code conventions. Tom proposed the form and confirmed the grammar; the lists of descriptors (parts, locations, owners, roles; bounds, references, directions; units), the disjoint classes and the symbols are in `knowledge/nomenclature.md`. Constraints and function names are a later step.

### D56 — Current is `i`, cost is `c`, efficiency is `η`
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: `c` was current and also cost, charge and cycle, and an index is never a quantity, so `i_term_real` and `for i in I` do not meet. `η` is a valid identifier, stable under NFC, and works as a field, a keyword and an Arrow or Parquet column that `pyarrow` reads back; the docs already write `η`.
Changes: the symbols in the D55 rule. In the docs mathematics current becomes `i` and cost keeps `c`, by meaning.

### D57 — A key names the owner, a field does not, a local equals its key
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: the variables of every type share one dictionary per network index, so a key needs the owner (`:p_gen`, `:p_stor_up`, `:p_term`); a field is reached through its type (`Generator.p_max`). A local that equals its key makes the code, the docs and the solution use one name.
Changes: new rule in Code conventions. Tom chose this over the owner in both, over a registry namespaced by type, and over a shorthand for the locals of an equation.

### D58 — The Matpower-derived names are renamed inside the package
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: `rate_a`, `angmin`, `angmax`, `base_kv`, `baseMVA` and `length_km` carry no symbol, or a unit that the grammar puts in a slot. `s_max` also stands for a `DCLink` and the linearized model, where apparent power is active power; `v_angl_min` is the angle difference across an edge, which the docs index says.
Changes: `rate_a` `s_max`, `angmin` `v_angl_min`, `angmax` `v_angl_max`, `base_kv` `v_base_kv`, `baseMVA` `s_base_mva`, `length_km` `l_km`. The readers keep the names of their sources.

### D59 — A rename is a hard removal, fully tested, in v0.14.0
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: asked whether the table reader's refusal of an old column should also name the new field, Tom answered no, hard removal everywhere, and asked that it be fully tested. As with D28 and D50.
Changes: new rule in Code conventions. No alias and no hint map; tests that the vocabulary is respected, that no old name is left, and that every type's table round-trips through Arrow and Parquet; v0.14.0.

### D60 — Every component has its own parameters table and variables table in the docs
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Documentation
Why: `load.md` and `slack.md` hold two types in one variables table. The tables are where a symbol, its code name and its unit meet, so each concrete type has its own.
Changes: new rule in Documentation, applied with the rename; a test compares a type's table with its `fieldnames`.

### D61 — A solve takes `set_string_name`, default true
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: names are built at 45 call sites and read by nothing. On the real step-3 window `instantiate_model` took 1,958 and 1,977 ms with JuMP's names off against 2,437 and 2,697 ms (19 to 27 %), about 0.5 s of a 125 s chunk since the pipeline then updates the model.
Changes: new rule in Code conventions. A `jump_model` given by the caller is left as it is when the option is true. This step names variables only; constraints are named in the next.

### D62 — A key of `ext` the package reads for a quantity follows the grammar
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: `:vr_start`, `:vi_start` and `:va_start` of a node's `ext` set the start of the voltage and are read by the package, so they are quantities that D55 left unnamed. Tom asked for them to follow the nomenclature; `init` is the qualifier of an initial value.
Changes: new rule in Code conventions. `:vr_start` `:v_real_init`, `:vi_start` `:v_imag_init`, `:va_start` `:v_angl_init`, a hard removal (D59), checked by `test/nomenclature.jl`.

### D63 — A constraint key names the owner, then the role
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: constraint keys were chosen where each row was written: some begin with an owner (`:node_balance`, `:storage_final`), others name a role or a part alone (`:winding`, `:pi_section`, `:star_balance`), and one rating has two keys by formulation (`:linear_rating`, `:edge_rating`). Ids are per kind (node 1, edge 1 and unit 1 coexist), so a role alone cannot be unique; `:redispatch_control` already carries its family in its id.
Changes: new rule in Code conventions, as D57 is for variables. Tom answered B32's open question: the owner, then the role, over the role alone and over a key that names the formulation, which a variable key does not either (`:p_term`).

### D64 — `con` takes the same keys as the register
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: the node rows are `:node_voltage_reference` in `con` and `:node_reference` in the register, and `src/` reads `con` only for the node balance.
Changes: new rule in Code conventions. An entry that bundles the rows of several keys (`:edge_limits`, `:switch`) takes an owner and a role; its ids stay component ids. Whether `con` earns its keep is its own item.

### D65 — A constraint id is the component's id or `(id, part...)`
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: the ids of `:pi_section` still read `:cr_fr`, `:ci_fr`, `:cr_to`, `:ci_to`, variable keys from before D55, and `:tap_setting` has `:magnitude_max` next to a bare `:max` that is the angle bound.
Changes: new rule in Code conventions. Parts use the nomenclature's words (`real imag magn angl min max up dn`), one id shape per key.

### D66 — `constrain!` names the row
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: every row passes through `constrain!` and none is named; a name built there needs no string at the 100 call sites, and the second sight of a row, an update, never builds it.
Changes: new rule in Code conventions. A row is named `"$(nw)_$(key)[$id]"` as a variable is, an `Arc` and a nested tuple flattened, the names unique over a model.

### D67 — `set_string_name` covers constraints
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: D61 named variables only and said constraints were next; one switch for the names JuMP shows is simpler than two.
Changes: D61's rule edited in place. The default stays true, subject to the measurement of stage 0 of `knowledge/plan/naming-constraints.md`.

### D68 — A constraint, its function and its dual take the prefixes `cstr_`, `fnct_` and `dual_`
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: D55 left function names and duals out. Tom asked that they follow and that a name say what it is, a constraint, a function or a dual.
Changes: new rule in Code conventions. `cstr_` prefixes a constraint key, `fnct_` the function that writes it, `dual_` the dual it gives (`constraint_node_balance` `fnct_node_balance`, `"lambda_real"` `dual_node_balance_real`), a hard removal (D59) that includes the two exported `constraint_*` names. The reading of one stem for the three, the entry points and the dual suffixes is confirmed with the map at stage 1.

### D69 — A solve takes `debug_mode`, default false, for the names of every variable and constraint
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: nothing reads a name back, so a name is a debugging aid, and D61 made it a default that costs 19 to 27 % of a cold build; Tom asked for one switch, off unless asked, across variables, constraints and whatever else JuMP names.
Changes: `set_string_name` (D61, D67) is replaced by `debug_mode::Bool = false`, a hard removal (D59). True names every variable and constraint and sets `JuMP.set_string_names_on_creation(model, true)`; false builds no name and sets it to `false`. A `jump_model` handed in is set either way, which D61 left as it came with true.

### D70 — An id has one shape per key within a formulation, and a `con` value is a row or a tuple of rows
Date: 2026-10-11 · Decided by: Tom Van Acker · Area: Code conventions
Why: 11 of 46 register keys have two id shapes, the LPF id and the IVR `(id, :real|:imag)` (`switch_cycle` puts the part before the bound), and D63 merges `linear_*` into `edge_*`: `cstr_edge_overload` is `(e, t)` in IVR and `(e, t, :pos|:neg)` in LPF, `cstr_edge_angle_difference` `(e, :max|:min)` against `e`. Splitting the LPF rows to match would change the model's rows. The IVR node balance is two `con` containers, `node_balance_real` and `node_balance_imag`, while D63 keeps a part out of a key.
Changes: D65 edited in place: one shape per key within a formulation, and the fixed magnitude of a tap is `(a, :magn, :set)`, so that `cstr_tf_tap_setting` has 3-tuples only. D64 extended: a `con` value is a row, or a tuple of rows in the order of the register's id parts, `(real, imag)` for the IVR node balance; its ids stay component ids. A check of one id arity per key in a built IVR and LPF model comes with stage 3.

### D71 — `Storage` takes `exact`: relaxed by default, exact, and a third value that fixes the direction
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: the relaxation, with no integers, lets a full battery absorb more than it can where a node price is negative: 393.00 against 426.54 in a three-step run, and the warning for it missed that run. The cheapest exact way measured is the relaxed solve first and binaries only where it violates (`knowledge/plan/storage-review.md`).
Changes: new rule in Component model; `exact` goes into the word list of `test/nomenclature.jl`; the third value is named in D78.

### D72 — `Storage` takes `terminal`, a list of typed end-of-horizon conditions
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: a pin alone made a roll spend the energy before a peak it could not see (extra cost 26.2, 10.1, 8.4 over perfect foresight at horizons 2, 3, 4, none at 5); the literature has a pin, a cyclic condition, a floor, a value and a penalty, and Zorba's plan asks for a soft target. Tom wants all of them selectable.
Changes: new rule in Component model; `e_fin` stays as `Pin`.

### D73 — A limit takes the most complete form that keeps its formulation's problem class
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Code conventions
Why: the converter limit is the circle, or separate cones, in IVR, which is already a nonconvex quadratic program; a limit on the active power in LPF; the box in a future linear formulation with reactive power, where the circle would make it a second-order cone program.
Changes: new rule in Code conventions; `s_max` on `Storage`, `Inf` by default.

### D74 — `Storage` prices charging and discharging apart: `c_chg` and `c_dch`
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: only the discharged energy could be priced; the literature prices both sides (Barrera-Singana et al., Wang et al. 2023) and the exactness conditions read both prices (Liang et al.).
Changes: `c_thru` is replaced by `c_dch` and `c_chg` is added, a hard removal as D59; the map in `knowledge/nomenclature.md` follows when it is built.

### D75 — `Storage` has a minimum energy `e_min`
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: five sources bound the energy below by more than zero (Jha et al. 0.30 of the capacity, Barrera-Singana et al., Garifi et al., Wang et al. 2023, Liang et al.), and a curative use needs energy held back (Lindner et al.).
Changes: new field, 0 by default.

### D76 — A storage unit out of service for part of the time holds its energy across the gap
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: a `status` over `:time` is a raw `KeyError` today; zero ratings already hold the energy (e_stor 0.0205 across two steps, objective 28.216), and an outage is to be supported as the status it is, not as a rating of zero.
Changes: new rule in Component model; the acceptance test is that equality, also across a window boundary.

### D77 — Detailed battery physics, self-discharge included, is deferred
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: a loss curve, rate capacity and a convexified degradation map (Fortenbacher et al.) and self-discharge (Li et al., Wang et al. 2023, Zafar et al.) are detail the questions asked of NMB do not need yet.
Changes: new rule in Component model; a note in the docs citing Fortenbacher et al.; B39.

### D78 — The third value of `exact` is `FROZEN`
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: `FIXED` is a `TapMode` value and exported, so a second `FIXED` is an invalid redefinition.
Changes: D71 edited in place: `exact` takes `RELAXED`, `EXACT` and `FROZEN`; Q10 deleted.

### D79 — A storage cycle is the energy drawn from the store over `e_max`, and charging and discharging are priced apart
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: delivered energy lets a unit draw `k·e_max/η_dch` from its store, 5 % more at η 0.95; Barrera et al. price both sides, which D74 does. Tom confirmed that `c_thru` is retired.
Changes: `storage_cycles` counts `Δt·p_dch/η_dch` over `e_max`; D74 stands as written. The count is widened to both sides in D81.

### D80 — The cycle limit holds over any sliding 24 h window, and a roll carries the used allowance
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: a calendar block lets a unit turn twice its limit in 24 h across midnight, and a roll gave every window a fresh allowance (0.2 against 0.1 pu·h a period at horizon 2 step 2, a generator 1.2 against 0.6). Tom chose a row per step over the 24 h up to it, the allowance carried through `initial_state`, and a market schedule over the budget refused before the build.
Changes: new rule in Component model; the carry for `Generator.e_per_max` on its calendar period and `c_cycl` charged per index are decided in D82. Q11 now holds only what Zorba's cap counts.

### D81 — The cycle count covers both sides of the store
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: Tom chose that the count itself covers both sides, not only the energy drawn. Both sides then spend the allowance, so charging and discharging in the same step, which the relaxation allows, spends it twice. The form, half the sum of the two store-side energies so that a lossless full cycle still counts 1, is the form Tom confirmed.
Changes: D79's rule edited in place; `storage_cycles` counts `Δt·(η_chg·p_chg + p_dch/η_dch)/2` over `e_max`; the check of a market schedule counts a negative `p_set` as charge.

### D82 — `c_cycl` is charged per index and the generator's allowance is carried in a roll
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: `c_cycl` is linear in the same count, so it needs no period; `Generator.e_per_max` has the defect measured for storage (1.2 against 0.6 in total at horizon 2 step 2). Tom agreed both proposals of plan item 6.
Changes: new rule in Component model; `storage_cycles` and the storage `period_cost` go and the horizon-term test of `test/hierarchy.jl` changes; `e_per_max` keeps its calendar period, not the sliding window.

### D83 — The redispatch prices of a storage unit may not sum below zero
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: a pair `c_up`, `c_dn` that sums below zero pays the solver to raise both volumes by the same amount: -20.0 with no congestion at `c_up` 10 and `c_dn` -30. Either price alone may be negative, a payback; the thesis of Scarponi keeps binaries on its up and down bids for the same reason.
Changes: new rule in Component model; `_check_storage` refuses `c_up + c_dn < 0` at any index.

### D84 — A market schedule whose own energy leaves the bounds is refused
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: a schedule that discharges 0.3 for three steps from a full 0.5 is repaired silently by a redispatch at its prices, 24.0 with no congestion, so a data error is booked as redispatch cost.
Changes: new rule in Component model; `check_storage(data)` and the exported helper `scheduled_energy(data, u)`.

### D85 — The scheduled energy is a target of `Pin`, `Soft` and `Quad`
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: a redispatch should leave a unit where the market plan leaves it (Dratsas et al. restore the scheduled state of charge by rule); ending on 0.25 instead of free costs 110.0 against 85.0 on the radial test network.
Changes: same rule as D84; no new terminal type, D72's list stands.

### D86 — A corrective storage unit may carry a curative holding time
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: Lindner et al. keep a booster's curative set points over the contingencies in one band of width `e_max` over the holding time, so that one pre-positioned state serves whichever contingency occurs; a corrective unit here has a trajectory per contingency, which is more freedom (objective 6.0 against 7.0 at a range of 0.25). Tom asked for it; the name `h_cur`, and the symbol `h` and the word `cur` it needs in the vocabulary, are proposed with it and stand unless Tom objects at the plan review.
Changes: new rule in Component model; B40.

### D87 — A start and a target are checked against the bounds by `check_storage`, not by the constructor
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: a constructor runs again at every network index with that index's values, and a window starts from what a solver returned, a digit outside its bounds. The first version refused an `e_init` below zero and four rolling-horizon tests failed. D75 and D84 stand; the check of a start and a target moves.
Changes: new rule in Component model; the `e_min <= e_init` and `e_fin` rows of plan item 1 are in `check_storage`, within 1e-5.

### D88 — A roll checks the market schedule of its storage once, over the whole problem
Date: 2026-10-12 · Decided by: Tom Van Acker · Area: Component model
Why: from the second window a unit starts from the energy the roll left it, and a schedule written for the start of the problem was refused there (-0.1 at network index 1). A redispatch is entitled to move a unit away from its schedule and to pay for what is left of it.
Changes: new rule in Component model; `instantiate_model` takes `schedule = true` and a window is built with `schedule = false`; D84 stands for a problem built whole.
