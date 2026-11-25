## Unreleased — chore: two of 5dive's own tools leave the CLI

The CLI no longer carries the code that seats 5dive's tool-call guard on new Claude agents (`5dive config mod-seat`), or the push-time privacy guard 5dive runs on its own servers. Both were for 5dive's own team and were switched off on every other server. Nothing changes on your server: `mod-seat` still reads off, and `install.sh` no longer downloads or installs the privacy guard. 5dive's own servers get both from the devteam plugin and the private ops repo.
