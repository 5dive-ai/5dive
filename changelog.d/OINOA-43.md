## Unreleased — fix(telegram): a Russian owner's first greeting carries the bot's Russian tagline and name (OINOA-43)

The greeting a box sends the moment Telegram is connected read the bot's short description with no language, so a Russian owner got the English default line under a Russian «Здравствуйте». It now asks for the line set under `language_code=ru` (falling back to the default when the bot has none), as the plugin's own `/start` greeting already did.

A bot whose own name is Cyrillic (a partner's Russian client now confirms «Джейн», not «Jane», when creating it) greets a Russian owner under that name, even over the persona's Latin name. The English greeting and a Latin bot name are unchanged.
