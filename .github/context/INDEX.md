# INDEX: what is in `.github/context/`, and when to open it

| File | Open it when |
| --- | --- |
| `STATE.md` | Always (injected at session start). Where the work stands, what's next. |
| `decisions.md` | Before changing behavior, a public API, a file format or a layering convention. |
| `backlog.md` | Picking the next task, or when you find work that won't fit in the current one. |
| `open-questions.md` | Before asking Tom something; it may already be answered or parked. |
| `conventions.md` | Writing commits, PR descriptions, specs, run prompts, tests or docs. |
| `environment.md` | Anything fails because of the machine: Julia, PowerShell, git, CI. Also before installing anything. |
| `lessons.md` | Planning a cross-check against a reference implementation, a large refactor, or a concurrency fix. |
| `setup-feedback.md` | At wrap-up, to log friction with the setup; and when proposing a setup change. |
| `setup-changelog.md` | When a setup file behaves unexpectedly: was it changed recently, and why? |
| `agent-runs/` | Writing or reviewing an agent-run prompt/report (unattended/overnight tasks). `agent-runs/README.md` has the rules. |
| `templates/` | Shapes for specs and run prompts (used by the `new-spec` and `new-run-prompt` skills). |
| `archive/` | Only to resolve an old decision id. |

Detailed specs (gap write-ups, integration handoffs) live in `plans/` at the repo root, not under
`context/` — see `plans/README.md`. NMB's own simulation output lives in the top-level `runs/`,
unrelated to `context/agent-runs/`.
