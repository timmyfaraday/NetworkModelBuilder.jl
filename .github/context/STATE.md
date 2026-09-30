# STATE

Overwrite, don't append. Keep under 80 lines. Last updated: 2026-09-30 by Tom Van Acker (closing
gap #8 of `plans/GAP_CLOSURE_PLAN.md`, v0.10.1).

## Where NMB stands

- v0.10.1, committed and pushed (`7801238`): `src/comp/{node,edge,unit}/` is now
  auto-included by a `_include_dir` directory walk instead of ~19 explicit lines in
  `src/NetworkModelBuilder.jl`, and each component file exports its own public names next to their
  definition. Public API verified unchanged (`names(NetworkModelBuilder)` identical before/after,
  258 names). Full suite green: 2465 tests, `docs/make.jl` builds clean.
- v0.10.0 (`security_tables`/`write_security_tables`) committed and pushed at `efc271c`/`4adad89`.
- All P0/P1 gap-closure items (#1-7) from `plans/GAP_CLOSURE_PLAN.md` stay closed; #8 now closed
  too (D10); #9-11 untouched — see `backlog.md`.
- Only tag in git history is `v0.6.0`; later versions are real untagged `Project.toml` states
  (see `decisions.md`).

## Branches

- `main`, `7801238` on `origin/main`. No other branches in flight.
- Next free decision id: **D11**.

## In progress

- Nothing in progress. D10 (gap #8) is confirmed by Tom, implemented, tested and pushed.

## Next

1. Pick up gap #9 (API ergonomics vs. SmaLoadFlow, P2/Large) when ready — see `backlog.md` B2.

## Blocked / waiting

- Gap #10 (parallel rolling-horizon throughput) needs a design decision before implementation
  (chunked-parallel vs. document-the-trade-off) — see `open-questions.md` Q1.

