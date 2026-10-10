# Plans

A plan/spec turns decisions into an implementation handoff for one gap or effort. Write one with
the `new-spec` skill; the house shape is `../templates/spec.md` (Evidence → Root cause → Fix →
Verification per item — the shape `GAP_CLOSURE_PLAN.md` already uses).

- An ongoing series of small, related gaps: one file, one numbered section per gap (see
  `GAP_CLOSURE_PLAN.md`).
- A standalone, larger effort (e.g. a third-party integration): its own `<slug>.md` (see
  `zorba-integration.md`).
- A plan's lasting rules go to `../decisions.md` when accepted, not only when drafted. Unlike
  fbd's `context/specs/` (removed once merged, since that project keeps a separate historical
  archive elsewhere), a plan file stays here after the work is done — it's the evidence trail, and
  NMB has nowhere else to keep it.

## Index

| Plan | Status | Decisions |
| --- | --- | --- |
| `GAP_CLOSURE_PLAN.md` | in progress (9/11 gaps closed) | D1, D2, D4-D8, D10, D11 |
| `zorba-integration.md` | Julia side complete; Python side tracked in Zorba's own repo | — |
| `dashboard-output-mapping.md` | reference, not a plan to close; revisit when GRIP unifies its naming | D9 |
| `switch-edge.md` | draft, awaiting review; B5 on `b5-switch-edge`, v0.11.0 | D13, D15-D25 |
| `unified-transformer.md` | implemented and merged into `main` (6 commits); tagged v0.12.0 | D28-D36 |
| `julia-guide-review.md` | proposed, awaiting Tom's order (B21-B28, Q7-Q9); nothing implemented | — |
| `topology-lookup.md` | implemented, merged and tagged `v0.12.5`; week 1 -10.7 % a chunk | D45 |
| `build-solution.md` | implemented, merged and tagged `v0.12.6`; week 1 -12.3 % a chunk, peak 5.0 to 2.9 GB | D46 |
| `guard-rails.md` | implemented, merged and tagged `v0.12.7`; threads 1.79x slower than processes, GC 14 % in both | D47 |
| `validation.md` | implemented on `b23-validation` (v0.12.8), not merged; Zorba year breaks no rule, chunk byte-identical | D48 |
