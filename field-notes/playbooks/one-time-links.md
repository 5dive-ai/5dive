# Sending a one-time link in chat

Chat apps open links to build a preview. A one-time link can be used up before the person taps it.

Ours was used by Telegram's preview bot about 2 seconds after the message left.

## How it runs

1. Send the link in a code span, so the app doesn't preview it.
2. Ask the person to copy it, and never to paste it back to you.
3. If it says "already used" seconds later, look for a preview bot in the access log.
4. On the server, turn preview bots away before the link counts as used.
