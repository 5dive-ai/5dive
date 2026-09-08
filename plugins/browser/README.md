# browser — persistent human-authenticated browser sessions

**What this is, in the words the decision landed on (lodar, 2026-09-07): persistent
human-authenticated browser sessions.** It is *not* anti-bot bypassing. A CAPTCHA, a 2FA prompt or
an "unusual activity" interstitial is a **hard stop that asks for a person** — the executor never
attempts to solve one. That is a decision, not a limitation, and the second framing invites legal
and reputational exposure the actual design avoids. Use the first one in docs, marketing and the
plugin description.

`5dive browser` is a **general capability, not a distribution product.** We do not curate a
platform list and we do not choose per-site API-vs-browser paths; the user does. Adapters are
therefore a **public surface**, and "how does a user add a site" is a core design question rather
than a detail.

```
5dive browser setup                 # once, as root: create the profile store
5dive browser auth <site>           # a browser opens; you log in yourself
5dive browser status                # per-site auth state; run this on a SCHEDULE
5dive browser ls                    # profiles, and when each was last seen alive
5dive browser run <site> <action> [--key=value ...]
```

## The auth model

`5dive browser auth <site>` opens a browser profile dedicated to that site and you log in
**manually, once**. No cookie export, no password handed to an agent. The agent is granted
permission to **operate the session**, not the credentials. Three reasons that is strictly better
than a cookie export:

1. **Blast radius is one site.** A cookie jar is your whole logged-in life; a profile is one account.
2. **It survives.** Cookies expire and the export is dead; a live profile re-auths in place.
3. **No password ever enters our process** — the difference between "we had a breach" and "we had a
   breach and it did not matter."

## A profile directory IS a credential

Anything that can read the directory can replay the session, regardless of the permission model
layered above it in our own code. On a box with ~18 seats that needs OS-level isolation, so the
store is:

```
/var/lib/5dive/browser-profiles/          root, 0711   traverse, do not list
                              /<seat>/    that seat,  0700
                                     /<site>/         0700
```

`0711` on the parent means a seat reaches its own subtree and can enumerate nobody else's. It also
means a seat cannot create its own directory there, which is why `setup` is a root act — the
alternative is a world-writable parent, and on one of those a hostile seat pre-creates another
seat's directory name, owns it, and every profile that seat later authenticates lands somewhere it
can read. Every command re-audits owner and mode and **fails closed**; it never repairs them.

## Sessions die, and that is the steady state

Sites invalidate sessions on their own schedule, throw device checks, re-prompt 2FA and
interstitial on "unusual activity". A profile that worked Monday is logged out Thursday, and
without a scheduled probe the agent finds out **mid-publish**. So:

- `5dive browser status` is a cheap liveness probe **on a schedule, not at publish time**. One
  page load a day is worth more than any adapter. It reports `authenticated`, `session expired —
  human action required`, `CHALLENGE — human action required`, or `UNKNOWN` when the probe could
  not read the page at all (no browser on the box, a load that failed).
- **`UNKNOWN` is deliberately asymmetric, and both halves are load-bearing.** `status` stays
  QUIET on it and exits 0 — a network blip must not page a person, or the signal becomes noise.
  `run` **refuses** on it, because the action is the irreversible half and an unverified session
  is as likely to be a challenge page as a healthy one. `run` proceeds only on `authenticated`:
  a positive list, so a state the classifier has no name for cannot fall through to the driver.
- A **challenge is classified before a logged-out state**, because a challenge page usually still
  carries the login form's markup. Get that order wrong and you send someone to re-authenticate a
  session that is fine, which teaches them the signal is noise.
- A cold profile **pings a human**, naming the site, with a one-command fix. Only a person at a
  browser can clear it.
- Adapters **fail closed** on an unexpected logged-out state: never retry, never improvise a login,
  never fall through to a generic "click the blue button".

## Adapters are data, and the vocabulary is fixed

An adapter is a JSON file at `adapters/<site>.json`. Its steps come from a closed vocabulary —
`goto fill click wait_for select upload press` — and a step outside it is a **load-time refusal**.
There is no `eval`, no `script` and no free-text instruction step, because any of those would make
the adapter a program the executor merely hosts. The LLM decides *what* to distribute, where, and
whether it is worth doing; the **adapter** decides where to click, what to fill, how to publish.
Freeform browser reasoning on a publish action is how a half-written draft reaches a real account.

## Verification is out-of-band or it is not verification

Every action must declare `verify.url` and `verify.expect`, and `run` checks that **before it
executes a single step**. After the driver finishes, `run` re-reads the artifact **from a different
path** — the permalink, fetched outside the browser session — and its exit status is that read, not
the driver's. A DOM assertion on the page you just acted on catches neither failure that matters:

- posted the wrong thing (draft, truncated, wrong account) and reported success;
- published fine but reported failure — so the retry double-posts.

## The executor

The backend is named by `FIVEDIVE_BROWSER_DRIVER` and must drive a **real Chrome profile**
(the Browser Hand shape: extension + local relay). Playwright is the right tool for *building and
testing* an adapter and the wrong tool for *running* it, so `run` refuses rather than silently
falling back to one. One executor, not six: each candidate runtime carries its own site adapters on
someone else's maintenance schedule, so six dependencies is six adapter surfaces that rot.

## Not shipped yet, and named so nobody assumes it

- **SERVER mode** — a persistent Chrome on a virtual display (Xvfb) with the 5dive extension and a
  local relay. `auth` currently needs a display and refuses without one instead of pretending.
- **The re-auth viewer** — exposing the session through a temporary noVNC/KasmVNC URL so a person
  can log in or clear a challenge from a phone. That URL is **credential-grade while it is open**:
  short TTL, single use, and never written to a log, a task body or a chat message. Decide that
  with the flow, not after.
- **RELAY mode** — an outbound relay to Chrome on the user's own laptop. It must target a
  **dedicated profile on that desktop, never the user's default**; reaching the default discards
  the entire reason profile-per-site is the design, turning an adapter bug into their bank and
  their email. Do not ship it unscoped.
