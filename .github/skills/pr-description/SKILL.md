---
name: pr-description
description: Draft a GitHub pull request description from the branch's commits and project memory. Use when the user asks for a PR description or is about to open a PR.
argument-hint: branch name (defaults to the current branch) and target branch
---
# PR description

1. Find the range: `git log --oneline <target>..<branch>` and `git diff --stat <target>...<branch>`.
   Confirm the target with the user — usually `main`.
2. Read the decisions and STATE entries these commits implement.
3. Write, in this order:
   - **Title**: what the branch delivers, in plain words.
   - **What this branch does**: one bullet per area, each with the result as a number (test
     counts, gap ids closed, timings). No adjectives in place of numbers.
   - **Not in this PR**: deliberate exclusions, with backlog ids.
   - **Gates**: the `Pkg.test()` pass count and the docs build result, from an actual run. If not
     run yet, write `_to fill in_` and say so.
4. No AI attribution, no internal ids the reviewer can't resolve (decision ids are fine, as they
   resolve in `.github/context/decisions.md`).
5. Keep it scannable: short bullets, no wall of prose. GitHub has no hard length limit, but say
   the line count if it runs long.
6. Save to `scratch/pr-<branch>.md` and show it. A person opens the PR.
