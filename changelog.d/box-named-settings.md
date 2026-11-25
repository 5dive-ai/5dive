## Unreleased — chore(core): 5dive's own seat names, GitHub orgs and paths become box settings (DIVE-9315)

The core no longer names 5dive's own team. Four things that were written into it are now box settings, empty by default:

- `wake-protected`: agents that never go cold (was: main and marketing, on every box).
- `own-orgs`: the GitHub orgs that are this box's own, for the rule that an agent may not ask a person to merge or push there (was: 5dive-ai and lodar).
- `principals`: names that may file tasks without being an agent (was: lodar).
- `projects-root`: where checkouts and `community/wiki` live (was: /home/claude/projects/5dive). `$FIVE_PROJECTS_ROOT` still wins; the default is /home/claude/projects.

Set them with `sudo 5dive config wake-protected=… own-orgs=… principals=… projects-root=…`; `none` is an explicit empty and `default` clears one. A box with the devteam plugin 0.4.7 takes that plugin's values for any it leaves unset, which is how 5dive's own boxes keep today's behaviour with no config step. The dead fallbacks to a 5dive-plugins checkout in the agent launcher and the plugin-dir resolvers are gone: every box has the installed copies.
