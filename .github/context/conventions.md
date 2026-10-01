# Conventions

Rules the team chose. Change one only through a decision (`record-decision`), since people rely on
them.

## Ownership

- Owner of NMB and of this agent setup: **Tom Van Acker**. Setup changes need Tom's OK.
- Anyone may update `context/` files as part of their work. Every entry that records a choice names
  who made it: a username or initials, never an agent.

## Git

- **No AI attribution** in commits or PRs: no `Co-authored-by` for a tool, no "Generated with". A
  PreToolUse hook blocks commits that carry one.
- One gap/decision or one fix per commit, test first when it fixes a defect. The message names the
  decision id when there is one (`D<n>: …`).
- Only the files that implement the change are committed — never an unrelated pre-existing
  unstaged edit or an untracked scratch file that happens to be sitting in the tree.
- Tag and push are the user's call — ask before `git push` or `git tag`; approval on one release
  doesn't imply standing consent for the next.

## Code

- Julia ≥1.10, JuMP + MathOptInterface for the model layer.
- Every `src/`/`test/` file: 80-column box header ending in a Changelog section (see
  `instructions/julia.instructions.md`).
- Docstrings: what and why. No decision ids or phase names in comments.
- No `src/form/` directory: a formulation is methods spread across component files.

## Tests and gates

- Gates: `julia --project=. -e "using Pkg; Pkg.test()"` (full suite), `julia --project=docs
  docs/make.jl` (doc build). No linter gate today (no mypy/ruff equivalent adopted).
- **A test earns its place if it exercises a path the real data/API doesn't, or reproduces a
  defect that actually happened.** No test per module, no coverage target.
- A concurrency fix is proven red/green against a real crash (revert the fix, reproduce, restore,
  confirm clean) before trusting the regression test alone.

## Specs and run prompts

- Specs (gap write-ups, integration handoffs) go in `context/knowledge/plan/`; shape in
  `context/knowledge/plan/README.md` and the `new-spec` skill.
- Agent-run prompts and reports go in `context/agent-runs/`, not `context/knowledge/plan/` and not
  the top-level `runs/` (which holds NMB's own simulation output, unrelated).
- Decision ids are global and sequential; the next free one is in `STATE.md`.

## Docs

- Every "complete example" (a fenced block with `using NetworkModelBuilder`) is a Documenter
  `@example <name>` block, swept a second time by `test/docs.jl`.
