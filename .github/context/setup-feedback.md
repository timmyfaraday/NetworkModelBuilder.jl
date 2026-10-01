# Setup feedback

How the agent setup improves itself. The setup = `.github/copilot-instructions.md`,
`.github/instructions/`, `.github/skills/`, `.github/hooks/`, `.vscode/settings.json`.
Owner: **Tom Van Acker**.

## The loop

1. **Capture (low bar).** At every wrap-up, ask: did a rule get ignored or contradict another? Was
   information missing, stale or wrong in `context/`? Did a skill misfire or not trigger? Were
   turns wasted on the machine, on searching, on output that was too long? Log each finding below.
2. **Propose (higher bar).** When the same issue appears **twice**, or **once at real cost** (a
   wrong result, a rejected change, 5+ wasted turns), propose a change to Tom at the end of the
   session: the diff, the evidence (entry ids below), and what it removes or shortens.
3. **Apply (only with Tom's OK in the conversation).** Make the change, add a line to
   `setup-changelog.md`, mark the entries `→ applied SC<n>` or `→ declined`.

## Rules that keep the setup small

- **Escalate when prose fails**: a written rule broken twice becomes a hook or a check, not more
  prose.
- **Every addition names a cut**: a proposal says what it removes or shortens.
- **Budgets** (checked by the Stop hook): `copilot-instructions.md` ≤ 80 lines, `STATE.md` ≤ 80
  lines, each file in `instructions/` ≤ 60 lines, each `SKILL.md` ≤ 120 lines.
- **Promote and demote**: a lesson that keeps proving true moves into the instructions; a rule that
  hasn't mattered in a month moves out to a knowledge file or goes.
- **Review**: run the `setup-review` skill every so often, or once `setup-feedback.md` has 10+
  open entries.

## Log

Format: `- F<n> · YYYY-MM-DD · <user> · <what happened> · cost: <turns/result> · status: open`
Next id: **F3**.

- F1 · 2026-09-30 · Tom Van Acker · `probe-environment` found the SessionStart/PreToolUse/Stop
  hooks have never fired: no `.git/agent-session/` dir, no `.git/agent-hooks.log`, and this
  session got no SessionStart-injected `STATE.md` context. `agent-hooks.json`'s schema matches
  Claude Code's hook config, not a known VS Code Copilot Chat feature · cost: all 3 hooks silently
  inert since the setup was created — `STATE.md` auto-injection, the AI-attribution/setup-file
  guard and the wrap-up nag all rely on the prose fallback in `copilot-instructions.md` only ·
  status: open
- F2 · 2026-10-01 · Tom Van Acker · `STATE.md`'s `## Branches` section claimed `main` was "one
  commit ahead of `origin/main`... not yet pushed" for the D12 commit, but `git log` showed
  `main`/`origin/main`/`origin/HEAD` already identical — D12 had been pushed outside a recorded
  session and `STATE.md` was never updated to match · cost: one extra `git log` cross-check before
  trusting STATE's push-status claim; likely the same root cause as F1 (no Stop-hook nag to keep
  it fresh) · status: open
