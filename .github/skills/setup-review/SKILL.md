---
name: setup-review
description: Periodic review of the agent setup (instructions, skills, hooks, context files) - finds contradictions, stale entries, unused rules and repeat failures, and proposes changes to the owner. Use every ~2 weeks, when setup-feedback has 10+ open entries, or when the user asks to review the setup.
---
# Setup review

Read-only until the owner (named in `.github/context/conventions.md`) approves. Output is a list of
proposals, not edits.

## Collect

1. `.github/context/setup-feedback.md`: open entries, grouped by cause.
2. `setup-changelog.md`: recent changes (did one cause new friction?).
3. `.git/agent-hooks.log` if present: hook errors and how often each hook blocked.
4. Line counts of `copilot-instructions.md`, `instructions/*`, `skills/*/SKILL.md`, `STATE.md`,
   `knowledge/*` against the budgets in `setup-feedback.md`.
5. `git log --since="3 weeks ago" --stat -- .github/context`: which context files are kept up to
   date and which are never touched.

## Look for

- **Repeat offenders**: a rule broken twice → propose a hook or check instead of more prose.
- **Contradictions** between instructions, skills and context files.
- **Stale content**: STATE facts older than the last commits; decisions contradicted by the code
  (spot-check two); backlog items with no movement for a month; environment lines still
  `(unverified)`.
- **Dead weight**: rules or skills that no feedback, commit or session touched in a month → demote
  to a knowledge file or delete.
- **Promotions**: confirmed lessons that keep recurring → a line in the instructions.
- **Budgets** exceeded → what to condense.
- **Portability**: NMB specifics leaking into skills or hooks.

## Propose

At most seven proposals, most valuable first. Each: the change as a diff, the evidence (F-ids,
counts), what it removes, the risk. Ask the owner to approve each one. For approved ones, apply,
log `SC<n>` in `setup-changelog.md`, and mark the F-entries.
