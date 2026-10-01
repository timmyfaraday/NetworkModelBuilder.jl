---
name: new-spec
description: Write an implementation spec for a gap or feature from decisions agreed with the user, in the house shape. Use when the user asks for a spec, a handoff, or to "spec out" a change.
argument-hint: what it should achieve
---
# Write a spec

Read `.github/context/knowledge/plan/README.md` (the shape) and `.github/context/lessons.md`
first.

## Before writing

1. Gather the material: the code involved (read it, cite file:line), the decisions section it
   touches (`.github/context/decisions.md`), relevant backlog and open-question items.
2. List the decisions the spec needs. Anything not yet decided by the user: ask, in one message,
   with options and a recommendation. Don't write a spec on undecided points.
3. Take the next free decision id from `STATE.md`; check the branch tip to cut from
   (`git log --oneline --graph -15`).

## Writing rules (the shape `GAP_CLOSURE_PLAN.md` already uses)

- Per item: **Evidence** (what happens today, file:line, an actual run's output — not just a
  reading of the source), **Root cause** (the specific line/function), **Fix** (what to build,
  a code sketch if it helps), **Verification** (the command or test that proves it).
- Quote evidence into the spec; the implementer may not have the conversation.
- Tests: only paths real data doesn't exercise, or defects that happened.
- "What this deliberately does not decide": link backlog/question ids.

## After writing

1. A new item in the active plan (e.g. `.github/context/knowledge/plan/GAP_CLOSURE_PLAN.md`): add
   a numbered section following its existing shape. A standalone effort:
   `.github/context/knowledge/plan/<slug>.md`, added to the index table in
   `.github/context/knowledge/plan/README.md`.
2. Show the user a summary: decisions, commit order, open points.
3. When the user accepts: run `record-decision` for each decision, update `STATE.md` (next free
   id, In progress).
