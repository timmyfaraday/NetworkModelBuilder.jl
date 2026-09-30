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
