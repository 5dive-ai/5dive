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

## Server mode: the browser lives on the box, you reach it through a one-time link

On a managed 5dive VM there is no display and there never will be one. `auth` used to refuse
there, and the only route past that refusal was `ssh -X` + `apt install chromium` + a hand-written
JSON file — which is not a product a customer can use.

So the browser runs **on the box**, on a persistent Xvfb display owned by the seat, and a person
reaches it through a viewer that is handed out as a **one-time, expiring, session-bound** ticket:

```
5dive browser serve <site>                                   # persistent Chrome on its own Xvfb
5dive browser serve <site> --stop                            # stop the browser; the profile survives
5dive browser viewer <site> --bind=<session> [--ttl=600]     # mint a one-time link
5dive browser viewer-redeem <site> --nonce=- --session=<id>  # the relay's gate; consumes the link
5dive browser viewer-revoke <site>                           # kill the view, keep the login
```

A successful `viewer-redeem` prints the two things the relay needs, and prints them exactly once:

```
target=127.0.0.1:6080
password=<the VNC credential x11vnc was started with>
```

The password is emitted **here and nowhere else**. `x11vnc` runs with `-passwdfile` inside the
seat's `0700` profile directory — the one place the relay is deliberately unable to read — so a
target without the password is a port that prompts for a secret nobody has. It rides the redemption
because the redemption already has exactly the right lifetime: one use, one bound session, consumed
in the same breath. The `-timeout` `x11vnc` is started with **is the ticket's TTL**, not a constant:
a VNC server that gives up before its own link expires hands the customer a spent link and a dead
port.

`auth` on a display-less box starts server mode instead of dead-ending. A box that does not have
the server-mode packages still refuses — and names which ones it lacks, rather than half-starting.

### What protects the session while the viewer is open

A viewer onto a logged-in profile is not a screenshot; it is the credential with a keyboard
attached. Five properties, each of which fails closed:

1. **Nothing listens off-box.** `Xvfb -nolisten tcp`, `x11vnc -localhost -once`, the bridge on
   `127.0.0.1`. Redemption returns a loopback target; the customer arrives through the box's
   already-authenticated relay, never through a port we opened.
2. **The ticket is a nonce we do not keep.** 32 bytes of urandom, stored only as its SHA-256 — the
   same rule the human-gate nonces use, for the same reason. The raw value exists once, in the line
   printed to whoever asked.
3. **It is single-use.** A TTL cannot close a replay inside its own window; consuming the ticket
   can. The spent-state check runs *before* the nonce compare, so a used ticket is not an oracle.
4. **It is bound to the session that asked.** `--bind` is mandatory; there is no implicit unbound
   ticket, because an unbound one is a bearer credential for a live logged-in account.
   `--bind=local` is the named escape for a hand-run on the box. A refused redemption from the
   wrong session does not spend the ticket for the right one.
5. **The nonce never enters argv.** `/proc/<pid>/cmdline` is readable by other seats, so
   `viewer-redeem` takes the nonce on **stdin** and refuses `--nonce=<value>` outright.

**Killing the viewer does not kill the browser.** The profile is the durable half; the view onto it
is the ephemeral half. `viewer-revoke` ends the view and the session stays logged in.

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

- **The customer-facing FLOW.** Server mode and the viewer above are built, but they ship **dark**:
  reachable by hand on a box that has the packages, wired to no button. The dashboard tile and the
  relay that gates on `viewer-redeem` are DIVE-4239; the provisioning that installs
  chromium/xvfb/x11vnc/websockify is DIVE-4238; and no human has yet logged into a real site
  through a real viewer on a managed box. Until that end-to-end arm runs, the flow is not shipped —
  a tile that promises a login nobody has driven is the failure DIVE-3590 named.
- **RELAY mode** — an outbound relay to Chrome on the user's own laptop. It must target a
  **dedicated profile on that desktop, never the user's default**; reaching the default discards
  the entire reason profile-per-site is the design, turning an adapter bug into their bank and
  their email. Do not ship it unscoped.
