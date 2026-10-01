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
- **Cross-check an unexpected `INFEASIBLE` with a second, independent solver before trusting it —
  especially when the model mixes very different coefficient magnitudes.** The Zorba three-step
  redispatch pipeline (`test-zorba-run` branch) had Xpress report hour 61 of the internal-BE
  redispatch step genuinely `INFEASIBLE` (its own unscaled-infeasibility check agreed, ~20 min to
  prove) with a phase shifter's angle held preventive. Pinning that angle at one specific, in-range
  value — a strict subset of the "free" case — solved `OPTIMAL`: a feasible point inside a
  supposedly-infeasible region is a contradiction. HiGHS then solved the identical, unchanged model
  `OPTIMAL` in under a minute. Root cause: this model's last-resort prices (overload/shedding/
  spillage, 477,000–4,770,000 $/pu) sat next to phase-shifter angle bounds of O(0.1–0.5) in the same
  LP — FICO's own docs name this exact symptom ("problem instability generally manifests in either
  long run times or spurious infeasibilities") and recommend coefficients not exceed a 1e6 ratio.
  `JuMP.compute_conflict!` did not help — it returned `NO_CONFLICT_EXISTS` on a confirmed-infeasible
  model, twice. **First "fix" tried, and retracted**: `PRESOLVE=0` or `SCALING=0` as an Xpress
  attribute both independently resolved hour 61 (matching HiGHS) with no regression found at the
  time — but re-running the *real* full week surfaced a second, different false `INFEASIBLE` at a
  completely different window (step 2, hours 17–24) that only appeared with `reuse=true`'s carried-
  over solver state, not in an isolated re-solve of that window. `PRESOLVE=0` fixed that too but at
  ~30x the solve time (not viable at scale); a lighter `SCALING=16` (Curtis-Reid) fixed it at ~6x the
  time — still a real cost, and never confirmed against hour 61 itself under step 3's own real
  reuse path. Toggling Xpress attributes was fixing one window while risking another, because the
  bug tracks solver-internal state, not each window's own data. **Actual fix**: rescale the model's
  own last-resort prices down instead of fighting the solver — same strict ordering (redispatch <
  overload < spillage < shedding) at smaller multiples (3x/2x/4x the thermal ceiling instead of
  10x/5x/10x, i.e. 143,100/286,200/572,400 $/pu instead of 477,000/2,385,000/4,770,000), plain
  `Xpress.Optimizer` with no attribute overrides. Confirmed on the real full week, not just a
  single window: all three steps `OPTIMAL` across all 168 hours, and ~2.4x *faster* overall
  (every window got easier to solve, not just the one that used to fail). **Lesson: prefer fixing
  the model's own numerics over tuning solver attributes to tolerate bad ones — a solver-attribute
  fix validated on the one window that was known to fail is not validated against the rest of the
  model, because the fix can change behavior through carried-over solver state that single-window
  testing never exercises.** Confirmed Tom Van Acker.

