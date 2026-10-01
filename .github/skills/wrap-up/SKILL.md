---
name: wrap-up
description: Update project memory at the end of a task or session - STATE, backlog, decisions, environment, lessons, and setup friction. Use before stopping after any change to code or data, when the user says "wrap up", or when the Stop hook asks for it.
argument-hint: optional one-line summary of what was done
---
# Wrap-up

Project memory lives in `.github/context/`. The goal is that the next session (another person,
another agent) can continue from `STATE.md` alone. Do these steps in order and keep each short.

## 1. What changed

Run `git status --short` and `git log --oneline -10`. List for yourself: code changed, decisions
taken (by the user in this conversation), things learned about the machine, mistakes made.
Identify the current user: `git config user.name`.

## 2. STATE.md (always)

Overwrite the relevant lines; stay under 80 lines. Update "Last updated: <date> by <user>", the
branch facts, "In progress", "Next", "Blocked". If the task is unfinished, say exactly where it
stopped and what the next command is.

## 3. Backlog

Tick finished items and move them to Done; add new work found but not done (`B<n>`, owner, date);
bump the next id.

## 4. Decisions

If the user decided something that changes behavior, a contract, a schema, a layer or a
convention, and it isn't recorded yet, run the `record-decision` skill. An agent's own design
choice inside a task is not a decision unless the user confirmed it.

## 5. Environment and lessons

- Something failed because of the machine (blocked script, path, proxy, missing tool, slow step)?
  Add or fix a line in `environment.md`: fact, what works instead, found by, date.
- A mistake that a rule would have prevented? Add it to `lessons.md` as `unconfirmed` unless the
  user confirmed it in this conversation.

## 6. Setup friction

Add one `F<n>` line to `setup-feedback.md` for each: a rule ignored or contradictory; context
missing, stale or wrong; a skill that misfired or didn't trigger; turns wasted on search, output
volume or the environment; a hook that fired wrongly. Include the cost. If nothing, skip.

If an issue now meets the proposal bar (seen twice, or once at real cost), end your message with
a **Setup proposal**: the diff, the `F<n>` evidence, what it removes. Don't apply it.
If `setup-feedback.md` has 10+ open entries, suggest running `setup-review`.

## 7. Commit

Stage the memory files with the code they describe. If the user commits themselves, tell them
which memory files changed.

## 8. Report

End with at most five lines: what was updated, anything the user must decide, the proposal if any.
