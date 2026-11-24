## Unreleased — fix(pack): an exported agent or team no longer carries your sign-in name

`5dive agent export` and `5dive team export` wrote each seat's sign-in name into the file. Whoever imported it got a seat bound to that name: an empty sign-in from someone else's box, so the seat came up signed out.

Exports now leave the sign-in out, and imports ignore one in older files. The importing box picks the account itself, as it does for any hire; `--auth-profile=` still chooses one explicitly.
