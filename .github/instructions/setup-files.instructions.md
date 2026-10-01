---
name: Changing the agent setup
description: Protocol for changing the agent setup itself (copilot-instructions, instructions, skills, hooks, .vscode settings). Use before proposing or making any such change.
applyTo: ".github/copilot-instructions.md,.github/instructions/**,.github/skills/**,.github/hooks/**,.vscode/**"
---
# Changing the agent setup

The setup is owned by **Tom Van Acker**. A PreToolUse hook asks for approval on every edit to
these files.

1. Don't edit before Tom says yes in this conversation. Propose first: the diff, the evidence
   (`F<n>` entries in `.github/context/setup-feedback.md`), and what it removes or shortens.
2. Prefer, in order: deleting a rule; tightening one; turning a repeatedly broken rule into a hook
   or check; adding a rule. Additions name what they cut.
3. Keep within budgets: `copilot-instructions.md` ≤ 80 lines, each instruction file ≤ 60, each
   `SKILL.md` ≤ 120. Project facts belong in `context/`, not here.
4. Keep the generic layer generic: skills and hooks don't mention NMB specifics, so another repo
   can reuse them. NMB specifics go in `copilot-instructions.md`, `instructions/` or `context/`.
5. After applying: add `SC<n>` to `setup-changelog.md` (what, why, approved by) and mark the
   feedback entries as applied.
