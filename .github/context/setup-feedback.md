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
Next id: **F8**.

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
- F3 · 2026-10-04 · Tom Van Acker · `copilot-instructions.md` rule 2 and `julia.instructions.md` say
  version bumps are the patch digit only; Tom decided B5 (a new component type and the first integer
  model) is v0.11.0 (D20), so the rule is wrong for that case · cost: none yet, but the next agent
  will read "patch only" and push back · status: applied SC4
- F4 · 2026-10-07 · Tom Van Acker · Five plugin skills do not fit a Julia/GitHub repo: `pr-description`
  is Azure DevOps (4,000 characters, mypy/ruff), `probe-environment` probes Python/venv/data paths,
  `new-spec` writes to `specs/`, `new-run-prompt` and `review-run-report` to `runs/` and name "the
  legacy" · cost: the five stay in `.github/skills/` as copies that get no plugin fixes · status:
  open (B15, D37)
- F5 · 2026-10-07 · Tom Van Acker · `launch.py` adds "no .venv found, tell the user to create it" to
  every session start of a repo without a Python of its own · cost: an empty `.venv` kept only to
  silence it · status: applied SC6 (D39); plugin key in B16
- F6 · 2026-10-07 · Tom Van Acker · `environment.md` already says a `Get-Content -Raw` round trip
  without `-Encoding UTF8` turns `≈` into mojibake, and a scratch script was rewritten that way
  anyway · cost: one broken script, 3 calls. `INDEX.md` sends the agent to `environment.md` only after
  something fails, and nothing points to it before rewriting a file through the shell · status: open
- F7 · 2026-10-07 · Tom Van Acker · A sync `run_in_terminal` call came back with only the tail of the
  echoed prompt (`lder.jl> ^C`) five times in one session, the command having run; a second call
  returned the output · cost: 5 extra calls; cause not found, seen while a background terminal
  existed · status: open
