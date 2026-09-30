# STATE

Overwrite, don't append. Keep under 80 lines. Last updated: 2026-09-30 by Tom Van Acker (adding
the security-tables / dashboard-output feature towards v0.10.0).

## Where NMB stands

- v0.10.0, committed and pushed (`efc271c`): `security_tables` / `write_security_tables`
  (new `src/io/dashboard.jl`), a new Parquet2 weak dependency
  (`ext/NetworkModelBuilderParquetExt.jl`), `test/dashboard.jl`, a new manual page
  (`docs/src/manual/dashboard.md`) and a reference mapping
  (`plans/dashboard-output-mapping.md`). Full suite green: 2465 tests (2436 + 29 new),
  `docs/make.jl` builds clean.
- All P0/P1 gap-closure items (#1-7) from `plans/GAP_CLOSURE_PLAN.md` stay closed; P2/P3
  (#8-11) untouched — see `backlog.md`.
- Only tag in git history is `v0.6.0`; later versions are real untagged `Project.toml` states
  (see `decisions.md`).

## Branches

- `main`, `efc271c` (D9) is the tip, matching `origin/main`. No other branches in flight.
- Next free decision id: **D10**.

## In progress

- Nothing in progress. D9 (`security_tables`/`write_security_tables`, GRIP naming, Parquet2) is
  confirmed by Tom, implemented, tested, documented and committed.

## Next

1. Pick up `plans/GAP_CLOSURE_PLAN.md` gap #8 (central include/export file tax) when ready — see
   `backlog.md` B1.

## Blocked / waiting

- Gap #10 (parallel rolling-horizon throughput) needs a design decision before implementation
  (chunked-parallel vs. document-the-trade-off) — see `open-questions.md` Q1.

