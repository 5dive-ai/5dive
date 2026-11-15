## Unreleased — fix(heartbeat): the pacing floor no longer lets a row through at 99% of the week when a fresh usage read forgets the account

An account the floor had just seen at 99% of its week (from its seats' own reading) could fall back to "no reading" when the next usage read came back without it, usually right after the nightly update while seats were restarting. With no reading the floor opened by default, and a high row ran. The floor now remembers each account's last weekly seat reading until that week resets, and holds on it the same way it holds on a remembered account reading: it can only tighten, never open.

When the floor does let a row through with no reading at all, the wake line now says so, for example `waking (fresh=false, pace=open: … blind meter …)`. A measured open admit is unchanged.
