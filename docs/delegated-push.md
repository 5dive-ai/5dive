# Delegated git push — bring your own GitHub App

`5dive push` lets an agent push code without ever holding a Git credential. Your
team stands up **one scoped push identity** — a GitHub App you own — whose key
lives root-side on the control plane. The CLI lends it for a single, gated,
one-branch push and never hands the agent a token.

This guide walks an operator through standing it up on their own host and org.
The design rationale is in `../DIVE-1376-delegated-push-design.md`; the security
model is summarized at the end here.

## What you get

```sh
5dive push <task> --branch=<feature-branch>
```

A push that runs **only** when all of these hold:

- the task carries a ship **gate** a human has answered and not rejected;
- the target is a **feature branch** (never `main`/`master`);
- every commit being pushed is authored by your configured **commit author**
  (so provider team-checks like Vercel stay green).

The privileged work — gate re-verify, author scan, token mint, push, discard —
happens atomically in a root-only helper. The agent process never sees a token,
and the minted token is scoped to just the one repo.

## Prerequisites

- A GitHub org (or user) that owns the repos you ship.
- Admin on the box running 5dive (the setup writes under `/etc/5dive/connectors`
  and, for fleet agents, `/etc/sudoers.d`).
- `openssl`, `curl`, `jq`, `git` (already required by 5dive).

## 1. Create the GitHub App

GitHub → **Settings → Developer settings → GitHub Apps → New GitHub App**.

- **Name / Homepage URL** — anything (e.g. `acme-5dive-push`).
- **Repository permissions → Contents: Read and write.** Nothing else is needed.
- Leave **Webhook** unchecked (uncheck "Active").
- **Where can this GitHub App be installed?** — Only on this account.

Create it, then:

- note the **App ID** (top of the App's settings page);
- **Generate a private key** — this downloads a `.pem`. Keep it; you place it in
  step 3.

## 2. Install the App on your ship repos

On the App page → **Install App** → pick your org → choose **Only select
repositories** and select exactly the repos you ship (not "All repositories" —
that widens blast radius unnecessarily).

After installing, the browser URL is
`https://github.com/settings/installations/<INSTALLATION_ID>` (or
`…/organizations/<org>/settings/installations/<INSTALLATION_ID>`). Note the
**Installation ID**.

## 3. Drop the credential (root-side)

Run the helper — it creates the connector dir, scaffolds the env template, and
tells you exactly what's still missing:

```sh
sudo 5dive push setup
```

Then place the two files it expects (both root-owned, mode 600):

- `/etc/5dive/connectors/github-app.pem` — the private key you downloaded.
  ```sh
  sudo install -m 600 -o root -g root ~/downloads/your-app.private-key.pem \
       /etc/5dive/connectors/github-app.pem
  ```
- `/etc/5dive/connectors/github-app.env` — fill the scaffolded template:
  ```sh
  GITHUB_APP_ID=<your App ID>
  GITHUB_APP_INSTALLATION_ID=<your Installation ID>
  GITHUB_APP_PRIVATE_KEY_FILE=/etc/5dive/connectors/github-app.pem
  # Optional — enforce a commit author on every pushed commit. Set it if your git
  # host enforces a committer identity (e.g. a Vercel author gate); leave blank
  # for no restriction. Format: 'Name <email>'.
  GITHUB_APP_COMMIT_AUTHOR=
  ```
  `sudo 5dive push setup` also prompts for this committer (or pass
  `--author='Name <email>'`) and writes it here for you.

Re-run `sudo 5dive push setup` — it should now report **Ready**. No secret is
ever passed on the command line; you paste the `.pem` and edit the `.env` by
hand, so nothing lands in shell history.

## 4. Wire the sudoers grant

`5dive push` calls a root-only helper (`_push_do`) over `sudo`. Admin agents that
already run `NOPASSWD: ALL` need nothing. **Standard (least-privilege) agents**
get the exact-path grant automatically when you create them (`5dive agent
create`) — the template writes:

```
<user> ALL=(root) NOPASSWD: /usr/local/bin/5dive _push_do
```

It's an **exact command path with no argument wildcard**, so it behaves
identically under classic `sudo` and under `sudo-rs`. Existing agents created
before this shipped can be re-provisioned, or you can add that one line to their
`/etc/sudoers.d/<user>` file by hand (validate with `visudo -cf`).

## 5. First push

From inside the repo's work tree, on the branch you want to ship:

```sh
# dry run — checks gate + author, mints nothing, pushes nothing:
5dive push DIVE-123 --branch=my-feature --dry-run

# real push (after the task's ship gate has been answered):
5dive push DIVE-123 --branch=my-feature
```

The branch can also come from a `Branch: my-feature` line in the task body
instead of `--branch`. Point at a different repo with `--repo=https://github.com/<org>/<repo>`
(defaults to the repo configured for your deployment).

## Security model

- **Credential locality.** The App key never leaves `/etc/5dive/connectors`
  (root-600). Agents cannot read it.
- **No token in the agent.** Minting, pushing, and discarding the installation
  token all happen inside the root-only `_push_do` helper. The agent process
  never holds a token to exfiltrate.
- **Repo-scoped, short-lived token.** The installation token is minted scoped to
  just the target repo (`repositories:[<repo>]` + `contents:write`) and lives
  ~9 minutes. A captured token can't reach other repos in your org.
- **Gate is authoritative root-side.** The cleared-gate predicate is re-read
  fresh from the task DB inside `_push_do`, not trusted from the caller — so a
  direct `sudo 5dive _push_do` can't bypass the human gate.
- **Input hardening.** Branch, URL, and repo-path are validated against flag,
  refspec, and traversal injection before reaching `git`; parameters travel over
  stdin (never argv), which keeps the sudoers grant an exact command path.
- **Audited.** Every `push` is written to the audit log (the token never appears
  in argv or the log).

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `no gate on <task>` | File and clear a ship gate first: `5dive task need <task> --type=approval --ask=...`, then a human answers it. |
| `gate … is OPEN` | The gate hasn't been answered yet. |
| `gate … was REJECTED` | The human answered no. Push stays refused. |
| `author check FAILED` | A commit isn't authored by the configured `GITHUB_APP_COMMIT_AUTHOR`. Re-author with `git rebase --exec 'git commit --amend --author="Name <email>" --no-edit'`, or clear the setting to drop the restriction. |
| `missing GitHub App credential` | `github-app.env`/`.pem` absent or unreadable. Re-run `sudo 5dive push setup`. |
| `NOPASSWD grant for '_push_do' is missing` | Standard agent lacks the sudoers line (step 4). |
| `refusing to push to protected branch` | Target a feature branch, not `main`/`master`. |

> The author check is config-only: it enforces `GITHUB_APP_COMMIT_AUTHOR` from
> `github-app.env` and is skipped entirely when that is unset. No committer
> identity is baked into the source — set it to your own committer if your git
> host runs an author gate, otherwise leave it blank.
