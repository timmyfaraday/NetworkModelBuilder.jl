# Transferring this agent setup to a new repo

The generic layer (hooks, the shared skills, the two generic instruction files and the empty shapes
of `context/`) is the `sma-coding-second-brain` plugin. In the other repo:

1. Install the plugin (steps in its README) and run `/init-second-brain`. It never overwrites an
   existing file.
2. Write that repo's own `copilot-instructions.md`, project instructions and `context/` content;
   nothing of NMB's carries over.
3. Check the hooks from the repo root: `echo {} | py -3 .github\hooks\launch.py session_start`.

NMB keeps five skills that shadow the plugin's (see `AGENT-SETUP.md`); another repo that needs the
same changes should wait for backlog B15 rather than copy them.

History: this setup was ported into NMB from a colleague's FlowBasedDomains repo and adapted from
Python/Azure DevOps/team to Julia/GitHub/solo maintainer; `context/setup-changelog.md` has the record.
