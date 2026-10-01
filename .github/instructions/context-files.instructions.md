---
name: Writing project memory
description: How to write in .github/context (STATE, decisions, backlog, lessons, environment, knowledge). Use whenever you update project memory.
applyTo: ".github/context/**"
---
# Writing project memory

- Write for the next agent and the next colleague: short statements, the reason in one sentence,
  no story of how we got there (git and the archive keep history).
- Every entry that records a choice or a finding names who: `Decided by` / `Owner` / `found by`,
  as a username or initials. Never an agent.
- Update in place rather than append duplicates; delete what is no longer true. `STATE.md` is
  overwritten, not appended.
- Budgets: `STATE.md` ≤ 80 lines; any knowledge file ≤ 150 lines. Over budget: condense or split.
- Numbers, not adjectives. Dates as YYYY-MM-DD.
- Ids: decisions `D<n>`, backlog `B<n>`, questions `Q<n>`, feedback `F<n>`, setup changes `SC<n>`.
  The next free id is stated in each file's header; bump it when you use one.
- New file in `context/`? Add a line to `INDEX.md` saying when to open it.
- No confidential data in these files; counts and ids are fine. (NMB's own data — Matpower cases —
  is public, but treat any future proprietary input the same way regardless.)
