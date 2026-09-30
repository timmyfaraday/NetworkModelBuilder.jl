# Setup changelog

Every change to the setup (instructions, skills, hooks, settings), newest at the bottom.
Format: `- SC<n> · YYYY-MM-DD · approved by <user> · <what changed> · why: <feedback ids or reason>`.
Next id: **SC3**.

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
