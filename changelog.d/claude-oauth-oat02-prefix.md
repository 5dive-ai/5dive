## Unreleased — fix(auth): accept and mask Claude sign-in tokens that start with sk-ant-oat02-

Claude Code 2.1.332 says its sign-in token can now start with `sk-ant-oat02-` as well as `sk-ant-oat01-`. 5dive only knew the `oat01` shape, so the first `oat02` token would have broken three things on every box: the Claude sign-in finished but stored nothing, the token showed up unmasked on screen during sign-in, and `5dive agent auth set claude --api-key=` filed it as an API key that Claude cannot sign in with.

All three now accept any two-digit version (`oat01`, `oat02`, and later ones). The on-screen mask shows the real prefix it hid.
