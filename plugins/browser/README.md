# browser — operate a site as yourself

`5dive browser` is a **general capability, not a distribution product.** We do not curate a
platform list and we do not choose per-site API-vs-browser paths; the user does. Adapters are
therefore a **public surface**, and "how does a user add a site" is a core design question rather
than a detail.

```
5dive browser setup                 # once, as root: create the profile store
5dive browser auth <site>           # a browser opens; you log in yourself
5dive browser auth --status         # is the session still alive? run this on a SCHEDULE
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

- `5dive browser auth --status` is a cheap liveness probe **on a schedule, not at publish time**.
  One page load a day is worth more than any adapter.
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
(the Browser Hand shape: extension / local bridge). The reason is not better automation — it is
that a real profile is not fingerprinted the way an automation-controlled browser is. Playwright is
the right tool for *building and testing* an adapter and the wrong tool for *running* it against a
site that detects automation. `run` refuses rather than silently falling back to one.
