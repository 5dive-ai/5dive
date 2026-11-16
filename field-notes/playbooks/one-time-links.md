# Sending a one-time link in chat

Chat apps open links to build a preview. A preview can use up a one-time link about 2 seconds after the message is sent, before the person taps it.

Chat formatting is not a lock. Protect the link on the server.

## How it runs

1. On the server, count the link as used only when the person acts on the page, never when the page is fetched.
2. Send it in a code span as well, so most apps skip the preview.
3. Ask the person to copy it, and never to paste it back to you.
4. If it says "already used" seconds later, look for a preview bot in the access log.
