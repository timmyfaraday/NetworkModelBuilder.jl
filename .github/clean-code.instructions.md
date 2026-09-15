---
name: Clean Code
description: Clean Code principles (Robert C. Martin) applied when writing and reviewing code.
applyTo: '**'
---
# Clean Code principles

Apply these when writing and reviewing code. Treat them as strong defaults, not laws. If a principle makes the code clearly worse in a specific case (common in data pipelines and numeric code), choose the clearer option and say why. In review, flag a violation with the reasoning behind the rule, not just the rule name.

## Functions
- Keep them small and doing one thing, at a single level of abstraction.
- Few parameters, ideally three or fewer. Prefer a small dataclass or object over a long argument list.
- No boolean flag arguments. Split into two clearly named functions instead.
- Don't mutate arguments to return results. Return values instead.

## Names
- Reveal intent: a name should say what something is and why it exists.
- Make them unambiguous and searchable. Use longer names for wider scopes; short names only in tight local scope.
- Describe side effects in the name so callers aren't surprised.

## Comments
- Explain *why*, not *what*. If a comment just restates the code, delete it and make the code clearer.
- Remove obsolete, redundant, and commented-out code. Version control already remembers it.

## Error handling
- Prefer exceptions over error codes. Don't return null and don't pass null around.
- Fail with context: the error should say what was being attempted when it broke.

## Design
- Duplication is the worst smell. Extract it.
- Prefer polymorphism or a lookup/dispatch table over long if/elif or switch chains.
- Keep data and the behavior that acts on it together. Respect the Law of Demeter: don't reach through one object to get at another.
- Replace magic numbers and strings with named constants.
- Don't mix high-level policy with low-level detail in the same function.

## Tests
- Follow FIRST: Fast, Independent, Repeatable, Self-validating, Timely.
- Test boundaries and edge cases, not just the happy path.
- Keep each test focused so a failure points straight at what broke.
