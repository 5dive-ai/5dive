## Unreleased — fix(agent create): only sandboxed claude seats start on the lite Telegram bot; standard seats keep the stock bot (DIVE-5306)

v0.66.0 put every new `--isolation=standard` claude seat on the lite Telegram bot profile. Standard
is the default tier for every seat after a box's first, so that moved most new seats onto the
client-facing bot. Now only `--isolation=sandboxed` gets `TELEGRAM_PROFILE=lite` at create. Standard
and admin seats get no profile line, as before v0.66.0.

`--telegram-profile=lite` still puts a standard or admin seat on lite, and `--telegram-profile=default`
keeps a sandboxed seat on the stock bot. Seats created on v0.66.0 are not changed:
`agent config <name> set telegram.profile=default` moves one back.
