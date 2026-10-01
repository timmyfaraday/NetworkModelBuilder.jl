# Transferring this agent setup to a new repo

For a colleague who wants to reuse this VS Code agent setup (instructions, skills, hooks,
`context/` conventions) in a different codebase. Expands on the "Reusing this in another repo"
section of [AGENT-SETUP.md](AGENT-SETUP.md).

This setup was itself ported into NMB from a colleague's FlowBasedDomains (fbd) repo, adapted from
Python/Azure-DevOps/team to Julia/GitHub/solo-maintainer — proof that the generic layer travels,
and a worked example if the diff between the two adaptations is useful.

## What's generic vs. NMB-specific

**Copy as-is (generic, no NMB mentions):**
- `.github/skills/**` (all skills — `new-run-prompt`/`review-run-report` talk about "a reference
  implementation" generically, not PowerModels.jl by name)
- `.github/hooks/**` (`agent-hooks.json` + `scripts/`)
- `.github/instructions/setup-files.instructions.md`
- `.github/instructions/context-files.instructions.md`
- The *empty shapes* of `context/`: `INDEX.md`'s table structure, `templates/`, and
  empty/skeleton versions of `decisions.md`, `backlog.md`, `lessons.md`, `open-questions.md`,
  `conventions.md`, `environment.md`, `setup-feedback.md`, `setup-changelog.md` (headers only, no
  NMB content)
- `.vscode/settings.json`'s `search.exclude` and `chat.tools.terminal.autoApprove` blocks

**Must rewrite for the new repo:**
- `.github/copilot-instructions.md` — NMB's domain summary and hard rules; write new ones for the
  new codebase
- `.github/instructions/julia.instructions.md`, `domain-invariants.instructions.md`,
  `tests.instructions.md` — NMB-specific; drop or replace with the new repo's own rules (if the
  new repo isn't Julia, replace `julia.instructions.md` with that language's equivalent)
- `context/decisions.md`, `backlog.md`, `lessons.md`, `environment.md`, `conventions.md` *content*
  — NMB's own history, don't carry over
- `context/STATE.md` — start fresh (empty / "nothing done yet")
- `context/knowledge/plan/` (NMB's spec location, referenced from `context/INDEX.md`) — don't
  carry over the content; check whether the new repo already has its own equivalent before
  creating `context/specs/` from scratch

**Config that needs one edit each:**
- `.github/hooks/scripts/hook_config.json` — change `setup_owner` to the new repo's owner; adjust
  `ignored_prefixes` to the new repo's own scratch/output directories
- `.github/hooks/agent-hooks.json`'s Windows command — point at wherever that repo's Python lives
  (a `.venv\Scripts\python.exe` if it's a Python project with one, plain `python` on PATH
  otherwise, as here)

## Steps

1. Copy `.github/skills/`, `.github/hooks/`, `.github/instructions/setup-files.instructions.md`,
   `.github/instructions/context-files.instructions.md`, and `.github/AGENT-SETUP.md` wholesale
   into the new repo.
2. Copy `.github/context/` structure but strip NMB content: keep `INDEX.md` (rewrite the table
   rows to point at whatever the new repo will actually have), `templates/`, and create empty
   `STATE.md`, `decisions.md`, `backlog.md`, etc. with just headers.
3. Edit `hook_config.json`: set `setup_owner` to the new owner, confirm `state_file` /
   `memory_prefixes` / `ignored_prefixes` paths still make sense.
4. Confirm a Python 3.9+ interpreter is reachable the way `agent-hooks.json`'s Windows command
   expects (edit the command if not).
5. Write a fresh `copilot-instructions.md` for the new repo (own hard rules, own domain summary,
   own owner name) — keep it ≤80 lines per the setup's own budget rule.
6. Merge the `.vscode/settings.json` excludes/`autoApprove` block into the new repo's settings (or
   create one if none exists).
7. Open the new repo in VS Code, start a chat, confirm the SessionStart hook injects `STATE.md`
   and the PreToolUse guard fires on an edit to a setup file (sanity check the hooks actually run).

## If this becomes a third repo

Package the generic layer (`skills/` + `hooks/` + the two generic instructions files) as a proper
agent plugin instead of copy-pasting again.
