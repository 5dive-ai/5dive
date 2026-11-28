## Unreleased — fix(security): a seat no longer needs to read other seats' Telegram bot tokens

A box can now take away every seat's read of the other seats' Telegram bot tokens without losing a notice. Before, a few messages went out through whichever bot the running seat could read. Taking that read away would have quietly stopped some of them, and one path could have sent through the seat's own bot into another seat's chat.

Now those paths use the seat's own bot or hand the job to root. The low-disk notice says when it is waiting for the hourly root run. The human-recipient check says "only root can read" instead of "no bot". `telegram-info`, `telegram-discover --agent` and `cos set-avatar`/`rotate` re-run under sudo, or say who can run them. Nothing changes on a box until its file permissions are tightened.
