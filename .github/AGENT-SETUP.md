# Working with the agent on NetworkModelBuilder.jl

For people, not for the agent. How the VS Code agent setup in this repo works and how to use it
well. Owner: Tom Van Acker.

## What's here

| Path | What it is | Who edits it |
| --- | --- | --- |
| `copilot-instructions.md` | Always-loaded rules (~50 lines) | Tom approves changes |
| `instructions/*.instructions.md` | Rules that load when the agent touches matching files | Tom approves |
| `skills/*/SKILL.md` | NMB's five override skills (below); every other skill comes from the plugin | Tom approves |
| `hooks/` | `launch.py`, `agent-hooks.json`, `hook_config.json`; the scripts run from the plugin | Tom approves |
| `context/` | The project's memory: state, decisions, backlog, lessons | Anyone, via their work |

The agent keeps `context/` up to date as part of each task.

## The plugin

The skills `wrap-up`, `record-decision`, `setup-review`, `init-second-brain` and the hook scripts
(session start, guard, stop check) come from the `sma-coding-second-brain` plugin; `launch.py`
finds and runs them. A fix to one of them is a PR against the plugin, not an edit here.

Five skills stay here and shadow the plugin's, because the plugin's version names Python, Azure
DevOps or a `specs/` folder: `new-spec`, `new-run-prompt`, `review-run-report`,
`probe-environment`, `pr-description`. Backlog B15 makes them generic so these can go.

## Daily use

- **One chat per task.** Old history costs tokens and dilutes context. The next chat picks up from
  `STATE.md`, which a hook injects automatically.
- **Finish with `/wrap-up`.** If you forget, the Stop hook asks the agent once to do it.
- **Decisions**: when you decide something, say so plainly ("let's go with X"); the agent records
  it with `/record-decision` and cites the id in the commit.
- **Useful skills**: `/new-spec` (writes into `context/knowledge/plan/`), `/pr-description`,
  `/setup-review`,
  `/probe-environment`, `/new-run-prompt` and `/review-run-report` (for a task handed to an
  unattended/overnight agent run).
- **Before asking the agent to re-explain something**, check `context/INDEX.md`; point it at the
  right file instead.

## Keeping costs down

- `.vscode/settings.json` keeps `docs/build/`, `runs/`, `scratch/` and the Manifests out of search
  results.
- Big test-run output goes to `scratch/` (gitignored), not into the chat.

## How the setup improves

The agent logs friction (`context/setup-feedback.md`) at every wrap-up. When an issue repeats, it
proposes a change with evidence; nothing in the setup changes without Tom's OK (a hook enforces
the prompt). Approved changes are logged in `context/setup-changelog.md`. Run `/setup-review`
occasionally, or once `setup-feedback.md` has 10+ open entries.

## First time on a machine

1. Julia ≥1.10 on PATH (`juliaup`), then `julia --project=. -e "using Pkg; Pkg.instantiate()"`.
2. Python 3.9+ reachable as `py -3` (Windows) or `python3`: the hooks are stdlib-only Python. Create
   the empty, gitignored venv that keeps the launcher quiet: `py -3 -m venv .venv`.
3. Install the `sma-coding-second-brain` plugin (steps in its README), then restart the chat. Without
   it the hooks do nothing and say so at session start.
4. From the repo root run `echo {} | py -3 .github\hooks\launch.py session_start`: the JSON must
   contain `STATE.md`. Then start an agent chat and check that the first answer knows the project
   state.
5. Run `/probe-environment`.

## Reusing this in another repo

Run `/init-second-brain` there; see `TRANSFER-SETUP.md`.
