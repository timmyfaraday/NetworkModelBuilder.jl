# Lessons

Mistakes that became rules. Each lesson: the rule, the incident it came from, who confirmed it.
A lesson an agent inferred on its own is marked `unconfirmed` until a person agrees. Lessons that
keep proving true get promoted into the instructions by `setup-review`; ones that never come up
again get retired.

## Verification

- **Prove a regression test would actually have caught the bug, not just that it passes now.**
  For the registry-locking fix (gap #4): reverted just the lock, reproduced the exact
  `ConcurrencyViolationError` under 56 threads, restored the fix, confirmed clean. For the doc-CI
  wiring (gap #6): deliberately broke a filename in a `@example` block, confirmed `docs/make.jl`
  fails with the exact error, reverted, confirmed clean again. Cheaper than a full test-suite round
  trip when only one or two functions are in question, and far more convincing than reading the
  diff. Confirmed Tom Van Acker.
- **A generic-purpose package added via `using` to a shared test file can silently break unrelated
  files through name collision.** `using PowerModels` in `test/runtests.jl` broke two files that
  never mention PowerModels, because it exports `parse_file`/`ids`/`solve_opf` over NMB's own
  identically-named exports. `import` + qualified calls (`PowerModels.parse_file`) costs nothing
  when the new code only ever needed qualified access anyway. Check `using` vs `import` before
  adding any new general-purpose (non-solver) test dependency to a shared namespace. Confirmed Tom
  Van Acker.
- **Read the plan's own evidence, not just its summary.** Gap #2's fix was named for one parser
  (`_parse_components`) in the plan's summary table, but reading `_nrows`'s call sites directly
  found the identical unchecked-length pattern in two more (`_parse_profiles`, `_parse_dimension`)
  — all three got the fix once the scope was actually read, not just the count. Confirmed Tom Van
  Acker.
- **Grep the actual pattern across the whole codebase before trusting a plan's stated count.** Gap
  #6's plan named 3 "complete, runnable" doc examples; `grep "using NetworkModelBuilder"` across
  `docs/src/**/*.md` found 5. Confirmed Tom Van Acker.
- **After mechanically computing a padded string (e.g. the 80-column header lines), re-verify the
  length in the file after writing it, not just at computation time.** Building v0.10.0's
  `security_tables`, a PowerShell one-liner correctly computed three changelog header lines at 80
  characters each, but retyping them into `create_file`/`replace_string_in_file` calls silently
  dropped one trailing space in three separate files — caught only by grepping every touched file
  for `^#.*#$` and checking `.Line.Length -eq 80` after the fact. Trust the write, not the
  computation. (unconfirmed)
- **A hand-built solver-result `Dict` for testing a solution-reading function must use the same
  units the real solution uses (per-unit on `baseMVA`), not the display units the function
  outputs.** `security_tables`'s test fixture set `"p"` entries directly to the intended MW values
  (10.0, -5.0, …); the function correctly multiplies by `baseMVA` to convert per-unit to MW, so
  every assertion was off by exactly 100×. Caught by running the tests, not by reading the code —
  the fixture "looked" right. (unconfirmed)
- **A solver status is a claim, not a result: cross-check an unexpected `INFEASIBLE` with a second
  solver, and check an `OPTIMAL` primal vector against the model's own constraints.** The Zorba
  three-step redispatch pipeline (`test-zorba-run`) had Xpress report hour 61 of step 3 `INFEASIBLE`
  (~20 min to "prove"); pinning a phase shifter inside its range — a strict subset of the free case —
  solved `OPTIMAL`, and HiGHS solved the unchanged model `OPTIMAL` in under a minute. The same model
  also returned `OPTIMAL` vectors that violate node balance by up to 32 pu — visible only through
  `JuMP.primal_feasibility_report(model; atol = 1e-5)`; the status and objective looked normal. On
  week 1 step 2, 8 of 21 windows were affected. `JuMP.compute_conflict!` returned `NO_CONFLICT_EXISTS`
  on a confirmed-infeasible model, so it is no help here. (unconfirmed)
- **The root cause was 21 busbar-coupler edges with reactance 1e-7, not the prices or Xpress's
  settings.** A coupler has susceptance 1e7 against ~60 for an ordinary line, so the matrix spans
  [1, 1e7]; FICO's docs name this symptom ("long run times or spurious infeasibilities"). Flooring the
  reactance at 1e-5 removed every violation (0 of 21 windows) and solved hour 61 in 6.3 s *with the
  original prices*, default settings and no other change. It moves monitored flows little (week 1, 79
  outage cases: 99th percentile 0.22 % of rating, maximum 2.2 %, none above 10 %); a floor of 1e-4
  moves them up to 17 % and is too coarse. Two earlier "fixes" were wrong and are retracted: Xpress
  `SCALING=0`/`PRESOLVE=0` fixed hour 61 but broke a different window under `reuse=true` (the bug
  tracks solver state, so a fix checked only on the known-bad window proves nothing about the rest),
  and rescaling the last-resort prices only reduced how often the trouble showed. Look for the
  extreme coefficient in the *constraint matrix* (`Coefficient range` in the solver log) before
  touching prices or solver attributes. Confirmed 2026-10-03: with the floor and the original prices
  week 1 solves 7 of 7 chunks `OPTIMAL`, violation-free, no fallback, in the same time as with the
  rescaled prices. Confirmed again 2026-10-05 with the couplers as locked-closed `Switch`es and no
  floor: 7 of 7 sound, 0 violation, flows on the 2,853 congested step 1 rows within 0.14 % of rating
  of the floored run, objective +0.009 % (step 2) and +0.018 % (step 3). (unconfirmed)
- **A per-edge lookup of "which event contains this edge" silently drops every event after the
  first.** The pipeline's `with_contingencies` used `findfirst(ev -> id in ev.edges, events)`, so an
  edge listed by several events (a line that is both a simple N-1 and part of a busbar group) went out
  only in the first one. 34 of 79 internal events and 2 of 13 cross-border events were affected, and 10
  busbar events lost *every* edge, i.e. modelled no outage at all. It showed up only because an
  independent closed-form flow calculation matched NMB's load flow to 1e-9 pu for 12 events and was
  off by 46 pu for the two with a shared edge. Validate a second implementation against the first on
  the real data, not a toy case. Every redispatch result produced before the fix understates the N-1
  severity of those events. (unconfirmed)
- **A file added to a directory that is walked at load time is invisible to a package that loads
  from its compiled cache.** Adding `src/comp/edge/switch/switch.jl` left `Switch` undefined and
  unregistered: the cache tracks the files it included, a new one changes none of them, touching
  `src/NetworkModelBuilder.jl` did not help (Julia compares content, not the time stamp) and
  deleting `~/.julia/compiled/v1.12/NetworkModelBuilder` did. `include_dependency(path)` on every
  walked directory fixes it: a file added to, then removed from, `src/comp/edge/switch/` was
  noticed each time. Checked on Julia 1.12.5 only. When a new component "does nothing", look at
  `names(NetworkModelBuilder)` and `edge_types()` before the code. (unconfirmed)
- **After an edit that ends a Julia block (`end`, `return nothing`), read the edited lines back;
  `get_errors` does not see a broken Julia file.** Five edits to `src/comp/node/node.jl` in one call
  left one method without the `end` of its `for` loop, another with an extra `end`, and a call
  inside a loop instead of after it. Two of the three still parsed, so the first symptom was a
  misleading `UndefVarError` in a test, not a syntax error. Reading the result with `read_file`,
  or `git diff` on the file, found all three at once. (unconfirmed)
- **Edits to one file go one call at a time, never side by side in one block.** Three
  `replace_string_in_file` calls on `src/core/network.jl` issued together each matched against the
  same starting text and interleaved: a docstring lost its closing quotes and a call was left half
  written, which showed up only as a `LoadError` at precompile. A `read_file` or `grep_search` issued
  next to an edit also returns the text from before it. (unconfirmed)
- **A restriction written in every state, plus a tie of the state to the base case, makes rows
  dependent, and Ipopt can stop on it at the first iteration.** B14: a preventive three-winding phase
  shifter set at exactly zero gave `OTHER_ERROR` (restoration failed) under every Ipopt setting tried,
  while a setpoint of 1e-3 rad solved. The rank of the equality Jacobian at the start (finite
  differences, 80 rows, rank 78) pointed at the repeated magnitude row; leaving it out of the tied
  states solved the case to the two-winding optimum (D35). Confirmed Tom Van Acker.
- **A test that matches an enumeration can pass with the row it is about removed.** `STEPPED`: with
  `Σ zt = 1` deleted, every "optimum equals the best of the enumerated positions" test still passed,
  because the objective is flat past the angle that clears the corridor and a combination of
  positions cost no less than the best single one; only the row-count and size assertions failed.
  Delete the row once to see which tests notice, and keep a structural assertion beside the oracle.
  (unconfirmed)
- **A test extension that writes a variable key the package also uses replaces the package's
  container.** `StarEdge` in `test/multiterminal.jl` wrote `:vsr`/`:vsi`; once the package's own
  `Transformer` used the same keys, any model with both a `Transformer` and the registered
  `StarEdge` type (registration is process-wide) got an empty array in `:vsr` and a `KeyError` far
  from the cause. Extensions pick their own keys (`:star_vr`). Found by running `zorba.jl` after
  `multiterminal.jl`; each alone passed. (unconfirmed)
- **Removing a price can leave the optimum non-unique, and a test that froze one vertex then
  fails.** Zorba's `[12, 12, 18]` flows came from the phase shifter price (1 per radian) choosing
  the least movement among equal-overload solutions; free, the solver returns another split with the
  same 11 MW overload (D34). Assert what is determined (total overload, conservation, ratings) and
  say so in the test. (unconfirmed)

## Performance

- **Time a change against a control run made the same day, not against an older run.** Week 1 with
  the couplers as switches took 376 s a chunk against 358 s three days earlier (+5 %, every chunk
  slower, all of it outside the solver). The floor loader, unchanged, re-run beside it took 377 s;
  two uncontended processes, three 8 h chunks each, gave 341 s with switches against 352 s with the
  floor, and a build-only benchmark of one window was within 4 %. The gap was the machine (25-29 %
  CPU busy before the launch, GC pauses 69 s then 73-78 s). The two sequential 7-process runs also
  differed by ~20 s of non-solver time in step 3 (switches slower) with ~18 s less solver time, same
  total; that did not survive a paired run: 8 processes at once, floor and switches on the same four
  days, gave step 3 non-solver 213-219 s with switches against 217-222 s with the floor, solver 67-101 s
  against 85-139 s, chunk 330-370 s against 354-410 s. Run the variants side by side on the same
  hours, not one after the other. B12 (v0.12.0 against v0.11.0, two pairs of 7 chunks, launch order
  swapped between them): new slower in 11 of 14 chunks, +1.4 % then +0.7 %, pooled +1.0 % (3.6 s a
  chunk); non-solver time slower in step 2 in 14 of 14 (+0.8 s) and in step 3 in 13 of 14 (+4.2 s), the
  solver not. A small cost in NMB's own work, not the launch order; cause not measured. (unconfirmed)
- **Threads inside one Julia process stop paying at a handful of tasks for NMB's per-window work;
  separate one-thread processes keep scaling.** Zorba week 1, same 7 daily chunks: 7 threads in one
  process 860 s per chunk; 7 processes 330-400 s. One 720-hour month on 30 threads had the same
  throughput as the week on 7 (0.17 vs 0.19 h/s). The year as 73 processes took 63 min (chunks
  327-911 s, mean 632 s, so some contention remains at 73). The Xpress solve is only ~15-20% of a
  chunk (step 3: 137 s of 3,680 s on 30 threads); the rest is `update_model!` (~3 s/window),
  `build_solution` (~1 s) and the agent's per-window feasibility check (~1.9 s), plus GC (13-20%
  of wall). The cause (shared GC or allocator, a GC held up by threads inside a long Xpress call) is
  not proven. Before building parallelism into a long run, time a one-chunk run alone, then at the
  intended concurrency, as threads and as processes. (unconfirmed)
- **A longer window buys nothing in the Zorba pipeline and costs in proportion to the hours it
  solves.** Hours do not depend on each other there (storage excluded, nothing ramps), so a window
  only adds model size and overlap. Hours 1-48, original prices, one process: 48 h windows committing
  8 h in both steps gave the same answer as 8/8 (step 2) and 1/1 (step 3) — objectives equal to
  1.7e-11 and 4.6e-11 relative, overload rows 1,576 and 20,054 in both, largest unit-hour volume
  difference 5.8e-6 pu — but the chunk took 4,944 s against ~670 s for two 24 h chunks (7 processes
  at once; ~1,230 s under the 73-process load), at 27 GB and 978 s of GC. Step 2: 579 s (solver
  290 s) against ~83 s (20 s); step 3: 4,344 s (solver 1,926 s) against ~570 s (147 s). Step 3 alone
  on hours 1-24: 1/1 276 s, 8/8 379 s, 24/24 395 s, 24/8 745 s (solver 62, 136, 122, 247 s). The time
  outside the solver (214, 243, 273, 497 s) follows the hour-states processed, overlap included, not
  the number of windows, so fewer windows saves nothing. Keep 8/8 and 1/1 unless a component couples
  the hours again (storage back in). (unconfirmed)

