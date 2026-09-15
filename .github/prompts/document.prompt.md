---
description: Generate or refresh documentation for the current file, selection, or module.
agent: agent
tools: ['edit', 'search']
---
# Document

Generate or update documentation for the code in context: the open file, the current selection, or a module the user names.

- Follow this repo's docstring and documentation conventions from its `copilot-instructions`. Match the style already used in neighboring code; don't introduce a new one.
- Document what the code actually does, checked by reading it, not what its name suggests or what it's supposed to do.
- Explain intent and non-obvious decisions. Skip anything that just restates the code.
- Cover the public surface: modules, classes, and functions, with their parameters, return values, and the exceptions they raise. Note important side effects.
- Do not change behavior. Only touch docstrings, comments, and Markdown. If you spot a bug while documenting, flag it separately instead of fixing it here.
- For a README or module-level doc, keep it short and current: what it's for, how to use it, and anything a newcomer would trip on.

If the code is unclear enough that you'd be guessing at intent, ask rather than writing documentation that might be wrong.
