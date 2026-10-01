---
name: record-decision
description: Record a decision a person made (behavior, contract, schema, layer, convention) in .github/context/decisions.md with the next free id. Use when the user decides something, says "let's go with", answers an open question, or when wrap-up finds an unrecorded decision.
argument-hint: the decision in one sentence
---
# Record a decision

1. Confirm it is a person's decision. If the choice came from you and the user hasn't agreed, ask
   first. Get the username with `git config user.name` (or the name the user gives).
2. Find the next free id in `.github/context/STATE.md` ("Next free decision id"). Check
   `git log --all --oneline | Select-String "D<n>"` to make sure it wasn't spent on another branch.
3. Read the section of `decisions.md` for the area. Is there a rule this changes?
   - **New rule**: add a bullet in the right section, citing `(D<n>)`.
   - **Changed rule**: edit the bullet in place, cite the new id; add a line to
     `archive/decisions-archive.md` for the superseded wording if it had its own id.
4. Append to the Log at the bottom of `decisions.md`:

   ```
   ### D<n> — <one-line rule>
   Date: YYYY-MM-DD · Decided by: <username> · Area: <section>
   Why: <one or two sentences>
   Changes: <rule added or edited, or "new">
   ```

5. Bump the next free id in `STATE.md`.
6. If it answers something in `open-questions.md`, delete that question.
7. Tell the user the id in one line. The id goes in the commit message that implements it, never
   in docstrings or code comments.

Keep the rule text short enough to read in one breath; put detail in the spec that implements it.
