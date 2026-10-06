# Setup changelog

Every change to the setup (instructions, skills, hooks, settings), newest at the bottom.
Format: `- SC<n> · YYYY-MM-DD · approved by <user> · <what changed> · why: <feedback ids or reason>`.
Next id: **SC6**.

- SC1 · 2026-09-30 · approved by Tom Van Acker · Initial setup, ported from a colleague's
  FlowBasedDomains (fbd) repo and adapted for Julia/GitHub/solo maintainer: `copilot-instructions`,
  5 instruction files, 8 skills, 3 hooks, `.github/context/` seeded from `plans/GAP_CLOSURE_PLAN.md`
  and prior session history, `.vscode/settings.json` search excludes and a terminal auto-approve
  allow-list · why: move NMB's project memory into a shared, git-tracked place instead of only an
  agent's private memory.
- SC2 · 2026-09-30 · approved by Tom Van Acker · `domain-invariants.instructions.md`: added a bullet
  documenting that a `src/comp/` subdirectory's file named like the directory itself loads first ·
  why: closing gap #8 (`plans/GAP_CLOSURE_PLAN.md`) makes `src/comp/` auto-discovered by directory
  walk, turning this existing naming habit into a load-bearing rule that needed writing down.
- SC3 · 2026-10-01 · approved by Tom Van Acker · `copilot-instructions.md` and `new-spec/SKILL.md`:
  updated their `plans/` path references to `context/knowledge/plan/` · why: D12 moved specs/plans
  from a top-level `plans/` to `context/knowledge/plan/`; these two setup files are the only ones
  under the setup-files protocol that named the old path.
- SC4 · 2026-10-04 · approved by Tom Van Acker · `copilot-instructions.md` rule 2 and
  `julia.instructions.md`: a version bump is the patch digit, or the minor digit for an item that
  adds a component type; `templates/spec.md` says the same · why: F3, D20 (B5 is v0.11.0).
- SC5 · 2026-10-11 · approved by Tom Van Acker · `domain-invariants.instructions.md`: the
  load-order bullet no longer names `transformer/transformer.jl` as an example · why: B11, D28 —
  `transformer/` holds the one file and has no siblings left to load after it.