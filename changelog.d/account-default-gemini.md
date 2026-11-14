## Unreleased — fix(account): a Gemini login can be the one new agents use

`5dive account default <account>:antigravity` was refused, and `5dive account default <account>` on an account holding only a Gemini login answered that it held no login, so a client who signed in to Gemini and tapped "use for new employees" got "try again later". Gemini now counts like Claude, ChatGPT and Grok: it can be pinned, Undone, and a Gemini login added later becomes the default for new hires. With no type named, an account's Claude, ChatGPT and Grok logins still come first.

A hire that cannot run on Gemini (a pack with no Gemini persona, a plain team seat) skips a Gemini default and hires exactly as before. A Gemini login a box already had when it updates is not a new default: an update changes no hire.
