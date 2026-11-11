## Unreleased — fix(telegram): the first greeting to an owner whose Telegram is in Russian carries the bot's Russian tagline and name

The greeting a box sends the moment Telegram is connected read the bot's short description with no language, so an owner whose Telegram is in Russian got the English default line under a Russian «Здравствуйте». It now asks for the line set under `language_code=ru` (falling back to the default when the bot has none), as the plugin's own `/start` greeting already did.

A bot whose own name is Cyrillic (a partner's client now confirms «Джейн», not «Jane», when creating it) greets an owner whose Telegram is in Russian under that name, even over the persona's Latin name. The English greeting and a Latin bot name are unchanged.
