---
description: Analyze this repo and generate a tailored .github/copilot-instructions.md for it.
agent: agent
tools: ['search', 'edit']
---
# Generate this repo's Copilot instructions

Analyze the current workspace and write a `.github/copilot-instructions.md` tailored to it. This file is applied automatically to every Copilot response in this repo, so it carries the codebase-specific knowledge the shared agents don't have.

First, investigate. Don't assume. Read the repo and determine:
- Languages and versions (expect mostly Python, but confirm and note anything else).
- Frameworks, key libraries, and the package/dependency manager in use (pip, poetry, uv, conda).
- Project layout: where source, tests, config, and scripts live.
- Testing setup: framework (pytest, unittest), how tests are run, any coverage expectations.
- Linting/formatting/type-checking already configured (ruff, black, flake8, mypy, pyright) and their settings.
- Any conventions visible in the existing code: naming, docstring style, type-hint usage, error handling.

Then write `.github/copilot-instructions.md` with these sections, filled from what you found (not generic boilerplate):
- **Project overview**: one paragraph on what this codebase does.
- **Stack and tooling**: languages, key libs, package manager, and the exact commands to install, test, lint, and format.
- **Code style**: the conventions this repo actually follows. Include type hints and docstring style if the code uses them.
- **Testing**: what's expected when code changes, and how to run the suite.
- **Team conventions** (include these regardless):
  - Explain non-obvious code, because coding levels on this team vary.
  - Challenge questionable requests and propose simpler alternatives rather than complying by default.
  - Match existing patterns before introducing new ones.

Keep it concise and specific to this repo. When you're unsure about a convention, ask rather than inventing one. After writing the file, show me a short summary of what you put in it and what you couldn't determine.
