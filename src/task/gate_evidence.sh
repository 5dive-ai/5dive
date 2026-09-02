# -------- 5dive task — gate evidence --------
#
# Split out of src/cmd_task.sh (DIVE-3278): gate EVIDENCE. GitHub token discovery, the anonymous probe rail, and every
# PR / branch / sha / version reference pulled out of a task's text and graded
# against its real state.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
# src/cmd_task.sh when the split tree is used (tests source src/cmd_task.sh).
# Function definitions only — never execute this file directly.
# DIVE-1935 (iteration 2): THE GATE ASSERTS ITS OWN INSTRUMENT.
#
# Iteration 1 was rejected for a reason that is about EVIDENCE, not about the arm it
# added: `_gate_gh_token`'s last arm was justified by "agents hold passwordless sudo
# on this host", which is a per-SEAT grant written as a HOST property. Census from
# `5dive agent list --json` at the time: root-all 7, cli-root 4, cli-scoped 5 — and a
# `cli-scoped` sudoers (`NOPASSWD: /usr/local/bin/5dive *`) cannot run `gh` as
# `claude` at all, so `sudo -n` is refused, `-n` makes that silent, `|| true` swallows
# it, and resolution returns EMPTY on 9 of 16 seats.
#
# THE DEFECT WAS UNFALSIFIABLE FROM THE CODE, which is why a fourth fallback would
# have inherited it: nothing the resolver does tells you WHICH arm declined, so an
# inert gate looks identical from the seat where it works and from the seat where it
# does not. Every arm below therefore leaves a CRUMB naming its own outcome, and the
# refusals/warnings downstream print the crumbs plus the seat they were taken on.
# `5dive task merge-gate-selftest` runs the same resolution deliberately and grades it
# against a known-merged PR, so the census above is reproducible by anyone on their own
# seat instead of being a one-off measurement by whoever happened to hold root.
#
# SUBSHELL, SO A FILE (the `_GATE_ANON_STATEF` idiom next door, same reason): every
# caller reads the resolver through `$(...)`, so a variable set inside it dies with the
# child. `$$` is the top-level pid even inside a command substitution, which is exactly
# the property needed to hand the crumbs back to the parent.
_GATE_TOK_TRACEF="${TMPDIR:-/tmp}/.5dive-gate-tok-trace.$$"

_gate_tok_note() { printf '%s\n' "$1" >>"$_GATE_TOK_TRACEF" 2>/dev/null || true; }

# _gate_seat — WHICH seat this ran on. The answer to "is the gate inert here?" is a
# property of the account, not of the host, and every diagnostic that omits it invites
# the same host-wide generalisation that produced this ticket.
_gate_seat() {
  printf '%s@%s uid=%s' "$(id -un 2>/dev/null || printf '?')" \
                        "$(hostname -s 2>/dev/null || printf '?')" \
                        "$(id -u 2>/dev/null || printf '?')"
}

# _gate_tok_why — the per-arm trace of the LAST resolution in this process, one line.
# Non-destructive (unlike `_gate_anon_why`): several sites may print it, and a second
# reader getting silence would reproduce this ticket's own failure shape.
_gate_tok_why() {
  local _t
  # awk, not `paste -sd'; '`: paste treats a multi-char -d as a CYCLE of single
  # delimiters, so it joins with ';' then ' ' alternately and the trace comes out
  # mis-punctuated. Caught by reading the live output, not by the syntax check.
  _t=$(awk '{printf "%s%s", (NR>1?"; ":""), $0}' "$_GATE_TOK_TRACEF" 2>/dev/null || printf '')
  [[ -n "$_t" ]] || { printf 'no token resolution ran in this process'; return 0; }
  printf 'seat %s: %s' "$(_gate_seat)" "$_t"
}

# _gate_gh_token — resolve a usable gh auth token for the DIVE-1830 merge-gate's
# read-only PR-state queries. `task done` normally runs under sudo (EUID 0), which
# has no gh login of its own, and the acting agent may itself be non-gh-authed
# (e.g. agent-*); running gh in that caller env returns state=unknown and the gate
# false-BLOCKS a legitimately-merged close (DIVE-1834). Resolution order:
#   1. an explicit token already in the env (manual passthrough / CI),
#   2. the REAL sudo invoker's gh login (SUDO_USER, when not root itself),
#   3. our OWN gh login, when we happen to be running as an authed user directly,
#   4. the host's known gh-authed user `claude` (the same identity delegated push
#      runs its git transport as) — reachable password-free from root, and from any
#      caller holding passwordless sudo (DIVE-1935).
# Order 3-before-4 is deliberate and was swapped there by DIVE-1935: a caller's OWN
# credential must win over borrowing another account's. Keep the order here in sync
# with the code below — this comment is what the next person reads before touching
# gate auth.
# Fail-safe: empty output => the gate treats state as unknown => false-BLOCK on the
# DECLARED path, never a false-CLOSE; on the auto-detect path it is a named,
# audited UNVERIFIED close (DIVE-1935), never a silent one. The token is passed to
# gh as a GH_TOKEN environment prefix and never appears in argv.
# Only ever used for read-only `gh pr view`/`gh pr list`.
_gate_gh_token() {
  local t u
  : >"$_GATE_TOK_TRACEF" 2>/dev/null || true
  t="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$t" ]]; then
    _gate_tok_note "[1 env GH_TOKEN/GITHUB_TOKEN] RESOLVED"; printf '%s' "$t"; return 0
  fi
  _gate_tok_note "[1 env GH_TOKEN/GITHUB_TOKEN] absent"
  u="${SUDO_USER:-}"
  if [[ -n "$u" && "$u" != "root" ]] && command -v sudo >/dev/null 2>&1; then
    t=$(sudo -n -u "$u" gh auth token 2>/dev/null || true)
    if [[ -n "$t" ]]; then
      _gate_tok_note "[2 sudo -u $u gh auth token] RESOLVED"; printf '%s' "$t"; return 0
    fi
    _gate_tok_note "[2 sudo -u $u gh auth token] empty (invoker not gh-authed, or sudo refused)"
  else
    _gate_tok_note "[2 sudo -u \$SUDO_USER] skipped (no non-root SUDO_USER)"
  fi
  # Our own gh login, when we happen to be running as an authed user directly.
  # DIVE-1935: this MUST stay ahead of the `claude` fallback below — a caller's own
  # credential always wins over borrowing another account's.
  t=$(gh auth token 2>/dev/null || true)
  if [[ -n "$t" ]]; then
    _gate_tok_note "[3 own gh auth token] RESOLVED"; printf '%s' "$t"; return 0
  fi
  _gate_tok_note "[3 own gh auth token] empty (this account has no gh login)"
  # DIVE-1935: the `claude` fallback was gated on `id -un == root`, so it only ran
  # for root/sudo callers. Every agent-* account closes tasks as ITSELF (plain
  # `5dive task done`, no sudo) and none of them are gh-authed — so resolution
  # returned EMPTY for the entire fleet, and the fail-OPEN auto-detect gate below
  # was inert on every close it was written to police. Agents hold passwordless
  # sudo on this host, so try `claude` for non-root callers too; `sudo -n` keeps it
  # a silent no-op (never a password prompt) where that isn't true.
  # DIVE-1935 iteration 2: `sudo -n` is REFUSED (not merely empty) on a cli-scoped
  # seat, and the two outcomes have different remedies — "claude has no gh login"
  # is a host fault, "you may not run sudo as claude" is this seat's sudoers. `-n`
  # made both silent, so they were indistinguishable; separate them here.
  # DIVE-2538 item 5 (axis corrected by olivia: weaken-a-gate, NOT misattribution).
  # This predicate does not decide "whether to re-exec under sudo" — it gates arm 4,
  # the LAST token-resolution arm. When it is skipped the resolver falls through to
  # `printf ''` and returns EMPTY, and the auto-detect merge gate below is fail-OPEN
  # on an empty token. So a PATH shim echoing `claude` made a caller skip its own
  # fallback, resolve no token, and take the open path — a gate weakened by a shim,
  # from a seat whose real uid was never `claude`. $EUID via actor_caller_unix_name
  # is not shimmable.
  #
  # (The fail-OPEN downstream is carried from the parent ticket's body and was NOT
  # re-measured on this branch; it decides this item's severity, not its fix shape.)
  if command -v sudo >/dev/null 2>&1 && [[ "$(actor_caller_unix_name)" != "claude" ]]; then
    # The classification reads sudo's OWN stderr rather than asking a second time
    # (`sudo -n -u claude true`). Deliberate: an extra probe changes the call
    # sequence three sibling harnesses assert on, and a diagnostic that alters the
    # thing it is diagnosing is worth less than the sentence it prints.
    local _e4; _e4="${TMPDIR:-/tmp}/.5dive-gate-sudo-err.$$"
    t=$(sudo -n -u claude gh auth token 2>"$_e4" || true)
    if [[ -n "$t" ]]; then
      rm -f "$_e4" 2>/dev/null || true
      _gate_tok_note "[4 sudo -u claude gh auth token] RESOLVED"; printf '%s' "$t"; return 0
    fi
    if grep -qiE 'password is required|not allowed to execute|may not run|no tty' "$_e4" 2>/dev/null; then
      _gate_tok_note "[4 sudo -u claude gh auth token] REFUSED by sudoers on this seat (scoped grant: no general sudo)"
    else
      _gate_tok_note "[4 sudo -u claude gh auth token] empty (sudo permitted; claude holds no gh login)"
    fi
    rm -f "$_e4" 2>/dev/null || true
  else
    _gate_tok_note "[4 sudo -u claude] skipped (no sudo, or already running as claude)"
  fi
  printf ''
}

# DIVE-2605: THE BOT RAIL — a second way to ASK GitHub, for callers who can never
# HOLD a token.
#
# Everything above resolves a token the caller may then use. For a standard-isolation
# builder that resolution is empty by construction, and DIVE-2318 already wrote down
# why: their sudoers is `ALL=(root) NOPASSWD: /usr/local/bin/5dive *`, which permits
# exactly one binary as root and nothing as `claude`, so the last-resort arm above
# ("sudo -n -u claude gh auth token") exits "a password is required". Measured again
# 2026-08-04 from agent-dev2's own uid, which is the only uid the answer is true of.
#
# DIVE-2318 made that refusal HONEST — it stopped rendering "no credential" as "not
# merged". This makes it RARE. The same builder that cannot borrow a token CAN run
# `sudo -n /usr/local/bin/5dive _gh_do`: it is that one permitted binary, and DIVE-2448
# already built it to read the machine account's PAT root-side and exec gh with it.
# Measured from agent-dev2: `_gh_do` returns `5dive-bot` for `api user` and answers
# `pr view 430 --repo 5dive-ai/5dive --json state,mergedAt` with real state. The rail
# the gate needs was already shipped; nothing routed the gate onto it.
#
# WHY THIS DOES NOT WEAKEN THE GATE. The rail is READ-ONLY here (`pr view`, `pr list`,
# `api` GETs) and `_gh_do` re-derives its own routing class as root, so a caller cannot
# talk it into a write. It is tried ONLY after every caller-credential arm comes back
# empty, so no close that resolves a token today changes path at all.
#
# WHY THE BOT AND NOT THE CALLER, when `5dive gh` routes reads the other way: that
# preference exists because the bot's visibility is NARROWER, so routing a read there
# could turn a working query into a 404. That trade needs a working caller credential
# to be a trade. Here there is none — the choice is the bot or no query — and a repo
# the bot cannot see still yields empty, which is the SAME unverified verdict the
# caller gets today. This arm can only ever add answers, never subtract one.
readonly _GATE_GH_DO=/usr/local/bin/5dive

# _gate_gh_bot_ok — 0 when THIS caller may route through the root-only `_gh_do`.
# Asks sudo, not the sudoers text: `sudo -n -l <cmd>` is 0 exactly when this account
# may run it, which is the property that matters and the one an admin's blanket
# `NOPASSWD: ALL` also satisfies. No network, no token, no side effect.
_gate_gh_bot_ok() {
  command -v sudo >/dev/null 2>&1 || return 1
  [[ -x "$_GATE_GH_DO" ]] || return 1
  sudo -n -l "$_GATE_GH_DO" _gh_do >/dev/null 2>&1
}

# _gate_gh_reachable <tok> — 0 when SOME way to ask GitHub exists. This is the
# predicate the refusals want; `[[ -z "$tok" ]]` was only ever a proxy for it, and
# it stopped being a correct one the moment a second rail existed.
_gate_gh_reachable() {
  [[ -n "${1:-}" ]] && return 0
  _gate_gh_bot_ok && return 0
  # DIVE-2770: a third way to ASK — see the anonymous rail below.
  _gate_anon_ok
}

# _gate_gh_credentialed <tok> — 0 when the caller HOLDS a rail of its OWN (a token,
# or the `_gh_do` grant), as opposed to only the anonymous one.
#
# DIVE-2770: `_gate_gh_reachable` is now true for a caller holding nothing, because
# the anon rail can answer for a PUBLIC repo. That is the fix — and it makes the two
# states downstream diverge. "A credential resolved and the query came back empty"
# and "there was never a credential, and the credential-free rail could not see this
# repo either" have DIFFERENT remedies, and a refusal that prints the first sentence
# for the second case is the exact DIVE-2318 defect this ticket inherited, one
# refusal further down: measured here on a private-repo close, which landed on
# `done-pr-state-unresolved` saying "a gh credential resolved" to a seat that has
# never held one. Reachability decides whether to ASK; this decides what an empty
# answer MEANS.
_gate_gh_credentialed() {
  [[ -n "${1:-}" ]] && return 0
  _gate_gh_bot_ok
}

# DIVE-2770: ONE refusal string, TWO sites. The EARLY site fires when no rail of any
# kind exists (no token, no bot grant, and no curl/jq to read anonymously with). The
# LATE site fires when the anonymous rail was the only one and it could not see this
# repo — a private repo, which is the ordinary case. Same epistemic state and the same
# remedy, so the same words, emitted from one place: two copies of a refusal this long
# drift, and then they disagree about which remedies a verifier seat can reach, which
# is the failure this ticket is about.
# DIVE-1935 (found by quinn, 2026-08-11): CLAUSE 1 OF THE DOCUMENTED EXIT WAS A
# TIP-EQUALITY TEST WEARING A MERGE TEST'S COSTUME, and it shipped in v0.19.20.
#
#     git ls-remote <repo-url> refs/heads/main | grep -q <merge-sha>
#
# `ls-remote <url> refs/heads/main` resolves ONE ref to its CURRENT VALUE, so that
# matches only while the merge sha IS STILL THE TIP of main. Main moves 20+ commits a
# day here, so the window in which the gate's own authorised exit works is about one
# commit wide — and outside it the script exits non-zero and reports NOT MERGED for a
# PR that merged. Failing CLOSED, on precisely the rows the exit exists to rescue, and
# handed to the caller as the thing to run. quinn measured it against the live ref and
# refused to run it.
#
# `git merge-base --is-ancestor <sha> origin/main` asks the question that was meant:
# is the merge REACHABLE from main, whenever it landed. CLAUSE 3 (`git grep` over
# origin/main for a symbol the PR added) is KEPT deliberately — it is the squash-proof
# half, and it still answers when the sha exists nowhere on main because the PR was
# squashed. The rewrite also drops a pipe that was never needed: `cmd | grep -q` under
# `set -o pipefail` returns 141 when grep exits early on a match, i.e. it can fail
# EXACTLY when it succeeds (community/wiki/grep-q-under-pipefail-turns-a-match-into-a
# -failed-check.md). Latent for a one-line producer like this, per quinn, and not the
# bug being fixed — but there is no reason to re-introduce the shape while rewriting
# the line.
# DIVE-3823 — THE RECORDED-EVIDENCE RAIL. Three rails above ask GitHub; this one
# reads a proof that was already RUN, and it exists because a verifier seat on a
# private repo holds none of the three by design.
#
# THE DEADLOCK, measured on DIVE-3808 (fix merged at 2033057e, row unclosable):
# DIVE-477 permits only the verifier of record to close a live delivered loop, and
# the merge gate requires the closer to be able to READ the delivery PR. On
# `agent-vesper` — no GH_TOKEN, no non-root SUDO_USER, no `_gh_do` grant (that is
# the can-push grant a grader must not hold), anonymous rail 404 on a private repo —
# both rails are correct and they enclose each other. The one seat allowed to close
# is the one seat unable to. `--force-merge-gate` does NOT reach it: that flag
# escapes a gate that RAN and disagreed, never one that asked nothing.
#
# WHAT THIS ACCEPTS, and why it is not a hole:
#   * The refusal below ALREADY tells that seat to run `task verify --no-done
#     --cmd=<ancestry/grep script>` "whose EXIT STATUS proves the merge". This is
#     the gate finally reading its own recommended exit instead of printing it.
#   * Only `--merge-proof` stamps these columns, and only when a command actually
#     RAN and EXITED 0. It is structural, never keyed on result TEXT — the maker's
#     `task deliver --result=` writes that column, so a text predicate would be
#     satisfiable by typing the right words (DIVE-3098's rule, one column over).
#   * It is consulted ONLY where no rail could ask at all. A caller holding a token
#     or the bot grant takes the API path exactly as today; this can never
#     substitute for an answer the gate could have gotten.
#   * The proof binds to the delivery_ref it was run against. A re-pointed binding
#     makes it inert rather than carrying it silently onto a different PR.
#
# WHAT IT DOES NOT CLAIM. The caller chose the command, so this is an ATTESTATION
# by a named seat with the command text on the row and an audit line — strictly
# stronger than the assertion `--force-merge-gate` records elsewhere, and weaker
# than an API query. That is the honest ordering, and it is why the close warns
# loudly and says whose proof it is rather than passing silently.
#
# Pure string logic on values the caller reads: no db, no network, so it is
# testable on its own and cannot fail open through an unavailable query.
# 0 when <proof_at> is set AND <proof_ref> is exactly the row's CURRENT <dref>.
_gate_merge_proof_ok() { # <proof_at> <proof_ref> <dref>
  local proof_at="${1:-}" proof_ref="${2:-}" dref="${3:-}"
  [[ -n "$proof_at" && -n "$proof_ref" && -n "$dref" ]] || return 1
  [[ "$proof_ref" == "$dref" ]]
}

# _gate_pr_state_answerable <dref> [tok] — 0 when SOME rail available to this caller
# can actually answer "what state is this PR in", asked about THIS pull request.
#
# DIVE-3823 iteration 2, and this is the whole correction. Iteration 1 scoped the
# recorded-evidence rail on `! _gate_gh_credentialed` — what the caller HOLDS — and
# quinn measured the hole that opens: the ANONYMOUS rail needs no credential, so on a
# PUBLIC repo an uncredentialed caller IS answerable, and a recorded proof pre-empted
# a query that would have refused. Measured on an OPEN public PR: `task done` returned
# 0 with curl called ZERO times. That is the inverse of this rail's own invariant.
#
# `_gate_gh_reachable` is not the predicate either, in the other direction: it is true
# whenever curl and jq merely EXIST, which is every seat, so scoping on it would make
# this rail dead code on the exact private-repo row it was written for. Neither "holds
# a credential" nor "has a transport" is the question. The question is whether an
# ANSWER is obtainable for this ref, and the only honest way to know is to ask.
#
# So it asks, with the same call the gate makes downstream, and it costs a request
# only on the narrow path that reaches it (uncredentialed AND a proof already stamped
# against the current binding). A 404 on a private repo — the DIVE-3808 shape — is
# rc 1 here and cheap. An answer of any kind is rc 0 and the proof is never consulted.
#
# DIVE-3888: IT NOW TAKES THE CALLER'S TOKEN, because the caller may hold one and
# still be blind. Iteration 2 passed an empty token on the reasoning quoted below —
# "this is only ever called when _gate_gh_credentialed is false, so there is no
# token to pass". That premise died with the `! _gate_gh_credentialed` clause at the
# call site (see src/task/status.sh, DIVE-3888): the rail is now reached by a caller
# that DOES hold a token, and asking with an empty one would skip the caller's own
# credential and the DIVE-3496 escalation behind it — i.e. it would under-answer and
# consult a recorded proof while a live rail could have said MERGED. Passing the
# token restores the invariant this predicate exists to hold: the proof is read only
# when NOTHING could answer. Empty `tok` behaves exactly as before.
_gate_pr_state_answerable() { # <dref> [tok]
  local dref="${1:-}" tok="${2:-}" st=""
  [[ "$dref" =~ ^https?:// ]] || return 1
  # `_gate_gh` with a token runs the caller's credential first and, on a stderr that
  # says "cannot see this repository", escalates to the bot rail and then the
  # credential-free rail (DIVE-3496). With an empty token it routes straight to those
  # two. Either way this asks with everything the caller can reach, which is the
  # question. `null` is a successful query that answered nothing (DIVE-2720).
  st=$(_gate_gh "$tok" 0 pr view "$dref" --json state,mergedAt -q '.state' 2>/dev/null || printf '')
  [[ -n "$st" && "$st" != "null" ]]
}

_gate_refuse_no_rail() {
  local ident="$1" subject="$2"
  # DIVE-2770: name WHICH way the credential-free rail failed. Rate-limited clears
  # by itself; a private repo never will. One sentence, and it decides whether the
  # reader waits or reaches for `task verify`.
  local _why; _why="$(_gate_anon_why)"
  # DIVE-1935 iteration 2: name WHICH seat and WHICH arm, not just "no credential".
  # The generic sentence reads the same on a seat that is momentarily unauthed and on
  # one that structurally can never resolve, and that ambiguity is what let an inert
  # gate stay invisible for a fleet-wide census.
  local _tokwhy; _tokwhy="$(_gate_tok_why)"
  policy_refuse "$E_CONFLICT" done-merge-gate-no-credential DIVE-2318 "$ident" "$ident cannot close: the merge gate COULD NOT CHECK whether ${subject} landed — no gh credential resolved in this caller's environment, the machine-account rail is unreachable, AND the credential-free rail could not answer either (DIVE-2770: an unauthenticated read of a public repo). No query ran at all. ${_why} This says NOTHING about the merge; do not read it as 'not merged'. WHICH OF TWO CAUSES THIS IS decides what you should do, and the gate cannot tell them apart from here. (a) BY FAULT: a builder that should hold the \`_gh_do\` grant is missing it — a provisioning problem with a name. Check it with \`5dive gh whoami\`; if the bot line is UNRESOLVED and you are a builder, that is the thing to fix (\`agent create --can-push\`), or re-run with a token (\`GH_TOKEN=\$(sudo -u claude gh auth token) 5dive task done $ident ...\`). (b) BY DESIGN: on a VERIFIER seat an UNRESOLVED bot line is the CORRECT state — \`_gh_do\` is the can-push grant a grader must not hold, so no credential is coming. Record machine evidence without claiming the merge by running \`5dive task verify $ident --no-done --cmd=<script>\` — e.g. \`git fetch -q origin main && git merge-base --is-ancestor <merge-sha> origin/main && git grep -q <a-symbol-the-PR-added> origin/main -- <path>\`, whose EXIT STATUS proves the merge rather than asserting it, and which is squash-proof where a sha comparison is not. That is terminal for the verifier and leaves the row visibly at graded->merge; the merge owner must later close through \`task done\`, whose gate answers this question. DIVE-3823: add \`--merge-proof\` to that same command and the exit status is RECORDED against this row's delivery binding — a later \`task done\` from this seat then closes on the recorded proof instead of a query it can never run, warning loudly and naming who proved it. It stops counting the moment the binding is re-pointed. \`--force-merge-gate\` does NOT reach this refusal: it escapes a gate that RAN and disagreed, never one that asked nothing. \`task merge-audit --limit=1\` reports the same missing credential. WHERE IT ACTUALLY STOPPED (DIVE-1935) — ${_tokwhy}; machine-account rail: $(_gate_gh_bot_ok && printf 'available' || printf 'not permitted on this seat'). Re-run that resolution on its own, graded against a known-merged PR, with \`5dive task merge-gate-selftest\`."
}

# DIVE-2770: THE ANONYMOUS RAIL — the gate's own question has a credential-free
# answer, and demanding a credential for it deadlocked a MERGED row.
#
# ORIGIN, measured (DIVE-2449 / PR #483, squash 0396d920). The DIVE-477 rail
# requires a close come from the VERIFIER OF RECORD. That seat holds no gh
# credential BY DESIGN — `_gh_do` is the can-push grant a grader must not hold —
# so `_gate_gh_reachable` was false and the close refused. The one agent permitted
# to close could not see the evidence; the one who could see it was barred from
# closing. Neither was misconfigured. The two rails enclosed each other, and the
# refusal printed two remedies (`5dive gh whoami`, "hand it to agent-main") that
# the caller the rail requires cannot reach.
#
# THE DEFECT IS THE PREMISE, NOT THE PLUMBING. "Did pull/483 land?" is answerable
# ANONYMOUSLY on a public repo: `GET /repos/O/R/pulls/N` needs no token, and
# `git ls-remote` reads refs without one. The gate was asking a public question
# through a private door. This rail asks it through the public one, and it is
# tried LAST — after the caller's token and after the bot rail — so no close that
# resolves a credential today changes path at all. The rail can only ever ADD an
# answer where there was none.
#
# WHY THIS IS NOT A WIDENING, which is the objection to answer first. It grants
# nobody anything: an unauthenticated read of a public repo is available to the
# whole internet, and it is READ-ONLY by construction (a curl GET with no
# credential to escalate with). On a PRIVATE repo it 404s and the close lands on
# exactly the refusal it lands on today. This is the fix DIVE-2770 asked for in
# preference to granting verifier seats `_gh_do`, which would trade a bookkeeping
# problem for a security regression.
#
# SQUASH IS THE SECOND BUG WEARING THE FIRST ONE'S CLOTHES, and it lives in the
# reshape below rather than in a separate branch. REST reports a squash-merged PR
# as `state: "closed"`; gh's `--json state` reports `"MERGED"`. Copying `.state`
# across would render every merged PR as CLOSED and false-refuse
# `done-before-pr-merged` on precisely the population this rail exists to unblock.
# So gh's state is DERIVED from `.merged`, never copied — and `merged` is a fact a
# squash does not disturb, which is why this rail answers "did it land" for a
# squash merge where no sha comparison can.
_GATE_ANON_API="${FIVE_GATE_ANON_API:-https://api.github.com}"

# _gate_anon_ok — 0 when an unauthenticated GitHub read is even possible here.
# FIVE_GATE_NO_ANON=1 turns the rail off: harnesses that grade the no-rail
# refusal need the pre-DIVE-2770 world back, and so does any operator who wants
# it. It is an opt-OUT, not an opt-in — a fix nobody enables is not a fix.
_gate_anon_ok() {
  [[ "${FIVE_GATE_NO_ANON:-0}" == "1" ]] && return 1
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

# DIVE-2770: THE ANONYMOUS RAIL HAS A BUDGET, AND IT IS SHARED. Unauthenticated
# api.github.com is 60 requests/hour PER IP — not per agent, per IP — so the whole
# fleet on one box draws from one bucket, and the bucket is small enough to empty by
# hand (measured: exhausted during this ticket's own end-to-end run, with
# `x-ratelimit-remaining: 0`, and the rail correctly declined rather than guessing).
# Two consequences are designed for here rather than discovered later:
#
#   1. EXHAUSTION MUST NOT WEAR THE PRIVATE-REPO COSTUME. A 403-with-remaining-0 and
#      a 404 are both "the rail could not answer", and stopping there prints "this
#      repo is private" for a condition that clears by itself inside an hour. That is
#      the same defect this whole ticket is about — an unreached question rendered as
#      an answered one — so the code that cannot tell them apart is the code that has
#      to. `_gate_anon_why` is where the difference is spent.
#   2. SPEND LESS. The declared path asks for the SAME PR twice (once for `.state`,
#      once for `.mergedAt`) and `_gate_pr_shas` asks a third time. Memoising the
#      response for the life of the process turns three requests into one, which is
#      the difference between ~10 closes an hour and ~30 for the whole fleet.
# SUBSHELL, AND WHY THIS IS A FILE. Every gate call site reads `_gate_gh` through a
# command substitution — `_state=$(_gate_gh ... || echo "")` — so the rail runs in a
# CHILD shell and any variable it sets dies with that child. Measured here: a shell
# variable carrying the outcome read back EMPTY at the refusal, and an in-memory
# response cache never hit once because each call had its own copy. So the outcome
# crosses the boundary in a file, keyed by the top-level pid (`$$` is the parent's
# even inside `$( )`, which is exactly the property needed). The sibling
# `.5dive-gate-gh-err.$$` file next door is the same idiom for the same reason.
#
# An in-memory cache is deliberately NOT reinstated on top of this: it would be
# inert for the same reason, and an optimisation that a test asserts but that never
# fires is worse than no optimisation. The duplicate reads were removed at the CALL
# SITE instead (one `pr view` for state AND mergedAt), which spends less on every
# rail rather than only on this one.
_GATE_ANON_STATEF="${TMPDIR:-/tmp}/.5dive-anon-outcome.$$"

# _gate_anon_get <secs> <api-path> — ONE bounded, unauthenticated GET.
# stdout is the body; a NON-ZERO rc means the read did not happen. The outcome is
# recorded for `_gate_anon_why`: an absent answer is unresolved, never "no"
# (DIVE-2318, one rail further down), and the three ways it can be absent have three
# different remedies.
_gate_anon_get() {
  local secs="${1:-10}" path="${2#/}" code="" out="" reset="" _b _h
  [[ "$secs" == "0" ]] && secs=10
  _b="${TMPDIR:-/tmp}/.5dive-anon.$$.$BASHPID"; _h="${_b}.h"
  code=$(timeout "${secs}s" curl -sSL -o "$_b" -D "$_h" -w '%{http_code}' \
          -H 'Accept: application/vnd.github+json' \
          -H 'X-GitHub-Api-Version: 2022-11-28' \
          "${_GATE_ANON_API}/${path}" 2>/dev/null) || code=""
  out=$(cat "$_b" 2>/dev/null || printf '')
  if [[ "$code" == "403" || "$code" == "429" ]] \
     && grep -qi '^x-ratelimit-remaining:[[:space:]]*0' "$_h" 2>/dev/null; then
    reset=$(grep -i '^x-ratelimit-reset:' "$_h" 2>/dev/null | tr -dc '0-9' || printf '')
    printf 'ratelimit|%s' "$reset" >"$_GATE_ANON_STATEF" 2>/dev/null || true
  else
    printf '%s|' "${code:-network}" >"$_GATE_ANON_STATEF" 2>/dev/null || true
  fi
  rm -f "$_b" "$_h" 2>/dev/null || true
  [[ "$code" == 2* ]] || return 1
  printf '%s' "$out"
}

# _gate_anon_why — ONE clause naming why the anonymous rail could not answer, for a
# refusal to paste. Empty when the rail answered or was never tried: a refusal that
# explains a rail nobody used is noise, and noise is how a reader learns to skip the
# sentence that matters.
_gate_anon_why() {
  local _st="" _code="" _reset=""
  _st=$(cat "$_GATE_ANON_STATEF" 2>/dev/null || printf '')
  # Read once, then unlink: this is a per-invocation crumb in TMPDIR, and the only
  # reader is the refusal it was written for. A close that never refuses leaves one
  # ~12-byte file behind, which is the same shape as the `.5dive-gate-gh-err.$$`
  # sibling and is bounded at ONE per CLI invocation (fixed name, last write wins)
  # rather than one per request.
  rm -f "$_GATE_ANON_STATEF" 2>/dev/null || true
  _code="${_st%%|*}"; _reset="${_st#*|}"
  case "$_code" in
    ""|2*)     printf '' ;;
    ratelimit) local _w=""
               [[ -n "$_reset" ]] \
                 && _w=" (it refills at $(date -u -d "@${_reset}" '+%H:%M UTC' 2>/dev/null || printf 'the top of the hour'))"
               printf 'AND NOTE WHICH FAILURE THIS WAS: the credential-free rail is RATE-LIMITED, not blind — unauthenticated api.github.com allows 60 requests per hour PER IP, and this host shares one IP across every agent on it%s. That is TRANSIENT: re-run `task done` after it refills and the gate should answer without any credential.' "$_w" ;;
    404)       printf 'AND NOTE WHICH FAILURE THIS WAS: the credential-free rail got a 404, which for an unauthenticated read means the repo is PRIVATE (or the ref is gone). There is no anonymous read of it at all, so waiting will not clear this one.' ;;
    network)   printf 'AND NOTE WHICH FAILURE THIS WAS: the credential-free rail could not reach github.com at all — network or timeout, so retry is worth one attempt.' ;;
    *)         printf 'AND NOTE WHICH FAILURE THIS WAS: the credential-free rail was refused with HTTP %s.' "$_code" ;;
  esac
}

# The REST->gh reshape. Only the fields the gate actually asks for, so a shape it
# has never requested cannot be silently invented. `statusCheckRollup` is injected
# by the caller as $roll because it is a SECOND request — leaving the key absent
# would let the rollup filter render NONE ("no checks reported") for a question
# nobody asked, which is the succeeding-in-appearance shape DIVE-1935 is about.
readonly _GATE_ANON_PR_SHAPE='{
  state: (if (.merged // false) then "MERGED"
          elif ((.state // "") == "open") then "OPEN"
          else "CLOSED" end),
  mergedAt: .merged_at,
  title: (.title // ""),
  headRefName: (.head.ref // ""),
  headRefOid: (.head.sha // ""),
  mergeCommit: (if ((.merge_commit_sha // "") == "") then null
                else {oid: .merge_commit_sha} end),
  number: (.number // 0),
  url: (.html_url // "")
}'

# _gate_anon_rollup <secs> <slug> <sha> — the check state of one commit, as a
# gh-shaped statusCheckRollup array. Two GETs because GitHub keeps check-runs
# (Actions) and commit statuses (legacy/external) in different places and gh
# merges them; asking only one would report OK for a repo whose reds live in the
# other. Conclusions are upcased because the rollup filter matches "FAILURE",
# and REST spells it "failure".
_gate_anon_rollup() {
  local secs="${1:-10}" slug="$2" sha="$3" cr="" st=""
  [[ -n "$sha" ]] || { printf '[]'; return 1; }
  cr=$(_gate_anon_get "$secs" "repos/${slug}/commits/${sha}/check-runs" \
        | jq -c '[ (.check_runs // [])[]
                   | {name: (.name // ""),
                      conclusion: ((.conclusion // "") | ascii_upcase),
                      completedAt: (.completed_at // .started_at // "")} ]' 2>/dev/null) || cr=""
  st=$(_gate_anon_get "$secs" "repos/${slug}/commits/${sha}/status" \
        | jq -c '[ (.statuses // [])[]
                   | {context: (.context // ""),
                      state: ((.state // "") | ascii_upcase),
                      createdAt: (.created_at // "")} ]' 2>/dev/null) || st=""
  # Both unreachable is UNRESOLVED, not "no checks" — say so with the rc.
  if [[ -z "$cr" && -z "$st" ]]; then printf '[]'; return 1; fi
  jq -cn --argjson a "${cr:-[]}" --argjson b "${st:-[]}" '$a + $b' 2>/dev/null || { printf '[]'; return 1; }
}

# _gate_anon_gh <secs> <gh args...> — serve a READ-ONLY gh call over the anon rail.
#
# rc 0 with output = ANSWERED. rc 1 = this rail could not answer, for any reason:
# an unsupported query shape, a private repo, a network failure, OR a listing that
# matched nothing. That last one is deliberate and is the whole discipline of this
# function: the anon rail cannot see a fork-headed PR and does not paginate a long
# closed-PR list, so an empty listing here is a question that was not REACHED, and
# rendering it as "not merged" would reintroduce DIVE-2318 on a new rail. Only a
# POSITIVE finding is allowed to travel.
#
# Shapes served, and the omission is deliberate: `pr view` and `pr list --head
# --state merged` are the two ways the fail-CLOSED gate asks "did this land", and
# `api` passes through because those call sites are written against REST already.
# `pr list --state open` — the fail-OPEN auto-detect scan — is NOT served: it is a
# 200-row listing whose emptiness the scan reads as coverage, and an anon rail
# that pages differently would convert "I did not see it" into "there is none".
# That scan keeps reporting UNVERIFIED for a credential-less caller, exactly as
# it does today.
_gate_anon_gh() {
  local secs="${1:-10}"; shift
  _gate_anon_ok || return 1
  local -a a=("$@") pos=()
  local expr='.' repo="" json="" head="" pstate="" i=0
  while [[ $i -lt ${#a[@]} ]]; do
    case "${a[$i]}" in
      -q|--jq)  expr="${a[$((i+1))]:-.}";  i=$((i+2)) ;;
      -q*)      expr="${a[$i]#-q}";        i=$((i+1)) ;;
      --repo)   repo="${a[$((i+1))]:-}";   i=$((i+2)) ;;
      --json)   json="${a[$((i+1))]:-}";   i=$((i+2)) ;;
      --head)   head="${a[$((i+1))]:-}";   i=$((i+2)) ;;
      --state)  pstate="${a[$((i+1))]:-}"; i=$((i+2)) ;;
      --limit)  i=$((i+2)) ;;
      -*)       i=$((i+1)) ;;
      *)        pos+=("${a[$i]}");         i=$((i+1)) ;;
    esac
  done
  local _body="" _out="" _slug="" _num="" _roll="null" _sha=""
  case "${pos[0]:-}" in
    api)
      # REST in, REST out — these call sites already speak this schema.
      [[ -n "${pos[1]:-}" ]] || return 1
      _body=$(_gate_anon_get "$secs" "${pos[1]}") || return 1
      ;;
    pr)
      case "${pos[1]:-}" in
        view)
          local _ref="${pos[2]:-}"
          if [[ "$_ref" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
            _slug="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"; _num="${BASH_REMATCH[3]}"
          elif [[ "$_ref" =~ ^[0-9]+$ && -n "$repo" ]]; then
            _slug="$repo"; _num="$_ref"
          else
            return 1
          fi
          _body=$(_gate_anon_get "$secs" "repos/${_slug}/pulls/${_num}") || return 1
          ;;
        list)
          # Only the fail-CLOSED "did this branch land" listing. See the header.
          [[ -n "$repo" && -n "$head" && "$pstate" == "merged" ]] || return 1
          _slug="$repo"
          _body=$(_gate_anon_get "$secs" \
                    "repos/${_slug}/pulls?state=closed&per_page=100&head=${_slug%%/*}:${head}") || return 1
          _body=$(printf '%s' "$_body" | jq -c '[ .[] | select((.merged_at // null) != null) ]' 2>/dev/null) || return 1
          # Nothing matched is NOT REACHED, never "not merged" (see the header).
          [[ -n "$_body" && "$_body" != "[]" ]] || return 1
          ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  [[ -n "$_body" ]] || return 1
  if [[ "${pos[0]:-}" == "api" ]]; then
    _out=$(printf '%s' "$_body" | jq -r "($expr)" 2>/dev/null) || return 1
    [[ -n "$_out" ]] || return 1
    printf '%s' "$_out"
    return 0
  fi
  # A rollup is fetched only when the caller ASKED for one, and a rollup that
  # could not be read declines the whole call rather than answering "no checks".
  if [[ ",${json}," == *,statusCheckRollup,* ]]; then
    _sha=$(printf '%s' "$_body" | jq -r 'if type == "array" then (.[0].head.sha // "") else (.head.sha // "") end' 2>/dev/null) || _sha=""
    _roll=$(_gate_anon_rollup "$secs" "$_slug" "$_sha") || return 1
  fi
  if [[ "${pos[1]:-}" == "list" ]]; then
    _out=$(printf '%s' "$_body" \
            | jq -r --argjson roll "$_roll" \
                "[ .[] | ${_GATE_ANON_PR_SHAPE} + {statusCheckRollup: \$roll} ] | ($expr)" 2>/dev/null) || return 1
  else
    _out=$(printf '%s' "$_body" \
            | jq -r --argjson roll "$_roll" \
                "${_GATE_ANON_PR_SHAPE} + {statusCheckRollup: \$roll} | ($expr)" 2>/dev/null) || return 1
  fi
  [[ -n "$_out" ]] || return 1
  printf '%s' "$_out"
}

# _gate_gh <tok> <secs> <gh args...> — run ONE read-only gh call by whichever rail
# is available, printing gh's stdout and nothing else. Empty output keeps its
# existing meaning at every call site: COULD NOT RESOLVE, never "fine".
#
# <secs> is the call site's OWN wall-clock bound, carried in rather than fixed here:
# the sites do not agree (10s on the declared-ref probes, 5s on the fail-open
# autodetect scan, none at all on four others) and each number is load-bearing where
# it sits — the 5s one is what keeps a slow gh from stalling a close that is allowed
# to proceed. `0` means the site had no bound and keeps none on the token rail.
# The BOT rail is always bounded (10s when the site names nothing) because it spends
# a sudo round-trip on top of the network, and an unbounded new rail is a new way to
# hang a close.
#
# Args reach `_gh_do` NUL-separated over STDIN (never argv), the same posture
# `cmd_gh` uses: the jq filters below carry newlines and quotes, and the NOPASSWD
# grant stays an exact command path with no argument wildcard.
# DIVE-2705: the stderr of the most recent _gate_gh call, or empty. Read it to
# tell a DEAD call apart from a successful empty one — see the contract below.
_GATE_GH_LAST_ERR=""

# DIVE-3496 (iteration 2) — THE SUBSHELL SINK, and why a second variable is the
# fix rather than more care.
#
# `_GATE_GH_LAST_ERR` is a plain global, so it only travels back to a caller that
# runs the callee IN ITS OWN SHELL. The escalation below does not: it CAPTURES the
# credential-free rails' stdout, `_esc_out=$(_gate_gh_nocred ...)`, which runs them
# in a subshell, and every assignment they make dies with it. `_gate_gh` then
# resets `_GATE_GH_LAST_ERR` to "" at entry, so the double-blind diagnostic
# interpolated the EMPTY STRING and the reader got "...could not answer: " with the
# half that says WHY the fallback failed silently dropped. Found by main in review
# of #673, confirmed empirically by quinn by instrumenting the harness — and the
# harness stayed 25/0 through it, because both of T4's arms match literals that
# live in the assignment itself and survive any value of the interpolation.
#
# So the error travels back through a FILE the caller names. A caller that captures
# stdout sets `_GATE_GH_NOCRED_ERRF` to a path and reads it back after; a caller
# that does not (the no-token path, which runs `_gate_gh_nocred` in this shell)
# leaves it empty and keeps using the variable exactly as before. Empty means "no
# sink", never "no error" — the variable is still authoritative in-shell.
_GATE_GH_NOCRED_ERRF=""

# Publish the current `_GATE_GH_LAST_ERR` to a caller-named sink, if there is one.
# Never fails: a diagnostic that can break the call it is describing is worse than
# a missing diagnostic.
_gate_gh_nocred_publish() {
  local _sink="${1:-}"
  [[ -n "$_sink" ]] || return 0
  printf '%s' "$_GATE_GH_LAST_ERR" >"$_sink" 2>/dev/null || true
  return 0
}

# DIVE-2705 — THE CONTRACT, and why it needed both halves.
#
# This used to end `|| true; return 0` on BOTH rails, and swallow stderr on both.
# That left a failed call and a successful-but-empty one indistinguishable on
# EVERY channel at once: same empty stdout, same empty stderr, same exit 0. Most
# call sites are output-driven and were unharmed (DIVE-2318 reads `-z "$_state"`
# / `-z "$_attr"` and refuses as UNRESOLVED, which is why those paths were already
# honest). But the autodetect scan counts a repo as SCANNED on the exit status:
#   _hit=$(_gate_gh ...) && _sc_ok=$((_sc_ok+1)) || _hit=""
# so an unlistable repo incremented _sc_ok, _sc_ok==_sc_total set _scan_ran=1, and
# the whole DIVE-1935/1955 partial-repo-scan block — warn, audit row, UNVERIFIED
# stamp — never fired. Partial coverage was announced as a clean scan, which is
# the exact defect DIVE-1955 exists to delete, surviving one level down inside its
# own remedy.
#
# So: the status is now REAL, and stderr is CAPTURED rather than discarded. Empty
# stdout keeps its documented meaning (COULD NOT RESOLVE, never "fine"); the
# status says whether the call itself ran; _GATE_GH_LAST_ERR says why it did not.
# Stderr is captured rather than passed through on purpose — a repo this token
# cannot see is an ordinary, expected condition on a multi-repo close, and
# spraying gh's error text on every gate would be noise that trains readers to
# ignore it (the alarm-fatigue shape DIVE-2711 names).
# DIVE-3496: the CREDENTIAL-FREE rails, lifted out of _gate_gh so both the
# no-token path and the blind-token escalation below reach them by the same code.
# Behaviour on the no-token path is unchanged — this is an extraction, not a
# rewrite; the escalation is the only new caller.
_gate_gh_nocred() {
  local secs="${1:-0}"; shift
  local _rc=0 _errf
  # DIVE-3496 it.2: read the sink ONCE, at entry, so a caller that captures our
  # stdout still gets the diagnostic back across the subshell boundary.
  local _sink="${_GATE_GH_NOCRED_ERRF:-}"
  _errf="${TMPDIR:-/tmp}/.5dive-gate-gh-nocred-err.$$"
  # No rail at all is NOT "the query ran and found nothing" — there was nothing
  # to run it with. Returning 0 here made an unusable bot rail count as a
  # completed scan, which is the same laundering as a failed listing.
  if ! _gate_gh_bot_ok; then
    # DIVE-2770: LAST rail, and only reached when the caller holds nothing.
    # An unauthenticated read of a public repo answers "did this land" without
    # any grant at all; on a private repo it declines and we fall through to
    # the same no-rail state as before.
    local _anon_out=""
    if _anon_out=$(_gate_anon_gh "$secs" "$@"); then
      _GATE_GH_LAST_ERR=""
      _gate_gh_nocred_publish "$_sink"
      rm -f "$_errf" 2>/dev/null || true
      printf '%s' "$_anon_out"
      return 0
    fi
    _GATE_GH_LAST_ERR="no gh rail: no token, the gate bot is not usable here, and the anonymous rail could not answer (private repo, or a query it does not serve)"
    _gate_gh_nocred_publish "$_sink"
    rm -f "$_errf" 2>/dev/null || true
    printf ''
    return 1
  fi
  [[ "$secs" == "0" ]] && secs=10
  printf '%s\0' "$@" | timeout "${secs}s" sudo -n "$_GATE_GH_DO" _gh_do 2>"$_errf" || _rc=$?
  [[ -s "$_errf" ]] && _GATE_GH_LAST_ERR="$(cat "$_errf" 2>/dev/null || printf '')"
  _gate_gh_nocred_publish "$_sink"
  rm -f "$_errf" 2>/dev/null || true
  return "$_rc"
}

# DIVE-3496: does this stderr say THE CREDENTIAL CANNOT SEE THE REPOSITORY, as
# opposed to any other failure? Kept deliberately narrow. GitHub does not
# distinguish "private and invisible to you" from "does not exist" — both are the
# same 404 / GraphQL resolution failure — and that is fine here, because the only
# thing this predicate authorises is ASKING A SECOND RAIL. A repo that truly does
# not exist fails on the second rail too and lands in the same unresolved state.
#
# "Could not resolve to a PullRequest" is deliberately NOT matched: that is a
# credential which CAN see the repo answering about a PR number, and re-asking a
# narrower rail cannot improve it.
_gate_gh_blind_err() {
  local f="${1:-}"
  [[ -s "$f" ]] || return 1
  grep -qiE 'could not resolve to a repository|not found \(http 404\)|http 404|resource not accessible by integration' "$f" 2>/dev/null
}

_gate_gh() {
  local tok="${1:-}" secs="${2:-0}"; shift 2
  local -a bound=()
  local _rc=0 _errf
  _GATE_GH_LAST_ERR=""
  _GATE_GH_NOCRED_ERRF=""   # DIVE-3496 it.2: only the escalation below sets a sink
  _errf="${TMPDIR:-/tmp}/.5dive-gate-gh-err.$$"
  if [[ -n "$tok" ]]; then
    [[ "$secs" != "0" ]] && bound=(timeout "${secs}s")
    GH_TOKEN="$tok" "${bound[@]}" gh "$@" 2>"$_errf" || _rc=$?
    # DIVE-3496: A RESOLVED TOKEN IS NOT A RAIL THAT CAN SEE THE REPO, and until
    # now the first was silently read as the second.
    #
    # _gate_gh_token returns the FIRST credential it can resolve and every rail
    # below that point is then unreachable — the bot rail and the anonymous rail
    # are in the `else` arm, i.e. they are tried only when the caller holds
    # NOTHING. A caller holding a token that is blind to the target repo
    # therefore forecloses two rails that would have answered, and the gate
    # renders the result as an unresolved merge state.
    #
    # Measured 2026-08-16 on this host, which is what makes this concrete rather
    # than defensive. Verifier seats are provisioned with `gh` authenticated as a
    # GitHub App INSTALLATION token (`ghs_`) minted against the single pinned
    # installation — the 5dive-ai org, 21 repos. Arm 3 of _gate_gh_token ("our
    # own gh login") resolves it and it wins:
    #   agent-main2's token -> lodar/5dive-api : GraphQL: Could not resolve to a
    #                                            Repository (the merge gate's UNKNOWN)
    #   agent-main2's token -> 5dive-ai/5dive  : answers normally
    #   the BOT rail (_gh_do, the 5dive-bot PAT) -> lodar/5dive-api : answers,
    #                                            "mergedAt" and all
    # So the answer was one rail away the whole time and nothing could reach it.
    # DIVE-2192 was merged, deployed and green, and could not be closed from
    # either seat (community/wiki/a-grader-that-cannot-read-the-repo-cannot-close-the-row.md).
    #
    # WHY THIS CANNOT WEAKEN THE GATE, on the DIVE-2605 argument:
    #  * it fires ONLY on a non-zero exit whose stderr says "cannot see this
    #    repository" — never on a call that ran and answered, so no close that
    #    passes or refuses today changes path, and no green close spends an extra
    #    request (tests/task_merge_gate_anon_rail_unit.sh T9 pins that count);
    #  * the escalation rails are read-only by construction — `_gh_do` re-derives
    #    its routing class as root and refuses a write, and the anonymous rail has
    #    no credential to write with;
    #  * if the escalation also fails we return the ORIGINAL non-zero status and
    #    empty stdout, which is byte-for-byte the state the caller sees today. The
    #    gate's fail-closed reading of an empty answer is untouched.
    # It can only ever convert an UNANSWERED query into an answered one.
    #
    # Streaming (not capturing) the primary call is deliberate: it keeps every
    # existing path identical. `gh ... --json` emits its payload only after a
    # successful request, so a failed primary call has printed nothing and the
    # escalation's output cannot be appended to a partial one.
    if (( _rc != 0 )) && _gate_gh_blind_err "$_errf"; then
      local _blind; _blind="$(head -n1 "$_errf" 2>/dev/null || printf '')"
      local _esc_out="" _esc_rc=0 _esc_err="" _escerrf
      # DIVE-3496 it.2: the capture below runs the callee in a SUBSHELL, so its
      # `_GATE_GH_LAST_ERR` cannot travel back — name a sink file and read that.
      _escerrf="${TMPDIR:-/tmp}/.5dive-gate-gh-esc-err.$$"
      : >"$_escerrf" 2>/dev/null || true
      _GATE_GH_NOCRED_ERRF="$_escerrf"
      _esc_out=$(_gate_gh_nocred "$secs" "$@") || _esc_rc=$?
      _GATE_GH_NOCRED_ERRF=""
      [[ -s "$_escerrf" ]] && _esc_err="$(cat "$_escerrf" 2>/dev/null || printf '')"
      rm -f "$_escerrf" 2>/dev/null || true
      if (( _esc_rc == 0 )); then
        _GATE_GH_LAST_ERR=""
        rm -f "$_errf" 2>/dev/null || true
        printf '%s' "$_esc_out"
        return 0
      fi
      _GATE_GH_LAST_ERR="the caller's own credential cannot see this repository (${_blind}); the credential-free rails were tried too and could not answer: ${_esc_err}"
      rm -f "$_errf" 2>/dev/null || true
      printf ''
      return "$_rc"
    fi
  else
    _gate_gh_nocred "$secs" "$@" || _rc=$?
    rm -f "$_errf" 2>/dev/null || true
    return "$_rc"
  fi
  [[ -s "$_errf" ]] && _GATE_GH_LAST_ERR="$(cat "$_errf" 2>/dev/null || printf '')"
  rm -f "$_errf" 2>/dev/null || true
  return "$_rc"
}

# DIVE-1935: extract every PR REFERENCE a piece of prose names, one number per
# line (deduped, first-seen order). DIVE-1922 closed with an empty delivery_ref
# and no Branch: line, but its own done result said "PR #156" in prose — the
# detectable signal was sitting in the text the maker typed. Two forms only:
#   * a github pull URL   https://github.com/<owner>/<repo>/pull/<n>
#   * a bare hash ref     #<n>   (1-6 digits, not glued to alnum on either side)
#   * a hash ref WITH PR CONTEXT   "PR #156", "PRs 156", "pull request #156"
# A bare '#<n>' is deliberately NOT enough. The first cut of this took any
# '#<n>' and the retrospective sweep immediately showed why that is wrong: it read
# "arms-length payer #4" and a column number "#25" as PR references. Harmless for
# the gate as long as those resolve non-OPEN, but a bare-'#' match against a
# low-numbered OPEN PR would false-block an unrelated close, and it made the sweep
# mostly noise. Requiring the word PR (or a pull url) keeps the DIVE-1922 shape —
# its result said "Merged as PR #156" — and drops the prose collisions.
# A '#' with no digits (markdown heading) and a 7+ digit id both correctly miss.
# A CLOSED-but-unmerged PR named here is deliberately IGNORED, not refused — see
# the gate below; that is documented behaviour, not an oversight.
#
# POSIX ERE only, deliberately. The first cut used `grep -oP` for both patterns,
# which made the whole text-binding gate depend on a PCRE-enabled grep: with -P
# unavailable both greps fail, `|| true` swallows it, refs come back empty and the
# gate silently does nothing — the EXACT silent-empty shape this ticket exists to
# delete, left sitting in the parser after being fixed in the token resolver and
# in _gate_pr_state. Not live-broken on our hosts, which is precisely why it would
# have sat there. ERE has no lookahead, so the trailing boundary is enforced by
# CAPTURING any glued alnum run (`[0-9]+[A-Za-z0-9]*`) and then rejecting the
# candidate unless it is digits-only and at most 6 long. That is strictly TIGHTER
# than the PCRE version it replaces: `(?![0-9])` excluded only a following DIGIT, so
# "PR 12ab" resolved as PR 12 under PCRE and under the first ERE cut too. Marcus
# asked for glued-to-alnum as a pinned negative and it caught that on the first run.
# The named fixtures in tests/task_merge_gate_result_pr_unit.sh are the equivalence
# proof; the canary below only proves the parser RAN.
#
# DIVE-1955: refs are now emitted QUALIFIED, as `<slug>|<number>`, where <slug> is
# the owner/repo the reference itself carries (pull URL) and EMPTY for a bare
# "PR #N". A number alone does not identify a pull request — our product spans at
# least three repos and their numbering collides — so the repo has to travel with
# the ref instead of being supplied later by a constant. When the same number
# appears both as a URL and bare in one text, the qualified form wins and the bare
# duplicate is dropped: strictly more information about the same reference.
_gate_pr_refs_qualified_from_text() {
  local text="$1"
  {
    printf '%s' "$text" | grep -oE  'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+[A-Za-z0-9]*'   || true
    printf '%s' "$text" | grep -oiE '(^|[^A-Za-z0-9])(PRs?|pull request)[[:space:]]*#?[[:space:]]*[0-9]+[A-Za-z0-9]*' || true
  } | awk '
      {
        n = $0; sub(/^.*[^0-9]/, "", n)                       # trailing digit-run
        if (n !~ /^[0-9]{1,6}$/) next                          # glued alnum / 7+ digits
        if ($0 ~ /^https:\/\/github\.com\//) {
          split($0, p, "/"); slug = p[4] "/" p[5]
        } else slug = ""
        if (slug != "") { if (qseen[slug "|" n]++) next; qual[n] = 1 }
        else            { if (bseen[n]++) next }
        order[++c] = slug "|" n
      }
      END { for (i = 1; i <= c; i++) { split(order[i], f, "|");
              if (f[1] == "" && qual[f[2]]) continue          # URL form already emitted
              print order[i] } }'
}

# Back-compat shape: the bare NUMBERS only, first-seen order. Kept because the
# engine canary and the DIVE-1935 equivalence fixtures are written against it, and
# because the audit's grouping only ever needed the number.
_gate_pr_refs_from_text() {
  _gate_pr_refs_qualified_from_text "$1" | awk -F'|' '!seen[$2]++ { print $2 }'
}

# _gate_delivery_refs_from_text <text> — of the refs this prose names, which ones
# does it claim THIS TASK DELIVERED? Emits the qualified `<slug>|<n>` subset.
#
# DIVE-1965. The gate's subject used to be "a PR mentioned in the result/body", and
# that predicate cannot tell "I shipped this" from "I am writing about this". Review,
# triage, audit, hygiene and coordination closes cite other tasks' pull requests as a
# matter of course. While off-repo bare refs silently failed to resolve the confusion
# was COSMETIC — a cited PR produced a wrong marker sentence and nothing worse. Once a
# bare `#N` resolves in the repo it actually lives in (DIVE-1963), a cited OPEN PR
# lands on the REFUSAL path (`done-with-open-pr-in-result`), and every close that so
# much as mentions another task's open PR becomes unclosable without
# `--force-merge-gate`. That is a fleet-wide close blocker on exactly the task class
# that does the most cross-referencing, so this has to land FIRST.
#
# This is the THIRD state, after DIVE-1955's pair:
#   "I LOOKED AND COULD NOT TELL"  — a non-verdict about this task's delivery.
#   "THERE WAS NOTHING TO LOOK AT" — the close named no PR at all.
#   "I AM TALKING ABOUT SOMETHING I DID NOT SHIP" — a ref was named, and it is not
#                                    this task's to answer for. Not a non-verdict:
#                                    there is no question here, so no disclosure.
#
# Marcus's design steer, and the reason this is not just a looser mention-predicate:
# **delivery must come from a STRUCTURED, INTENTIONAL signal, never from "a number
# appeared in the text".** The strongest two live elsewhere and already win — a
# `delivery_ref` and a `Branch:` line both route to the DECLARED gate above and never
# reach this code. What is left for prose is a deliberate claim, so the DEFAULT here
# is CITED and delivery has to be asserted:
#
#   1. a `Delivered:` / `Delivery:` line — the structured escape, sibling of the
#      DIVE-1462 `Branch:` and DIVE-1955 `Repo:` lines. Everything it names is a
#      delivery, no phrasing heuristic involved.
#   2. a shipping verb ADJACENT to the reference: "merged as PR #6", "landed in
#      #13", "shipped as https://.../pull/99", "PR #6 was merged". Anchored with `$`
#      against the text immediately before the ref (and a narrow `is|was <verb>`
#      after it) so it is adjacency, not "the word merged occurs somewhere".
#
# The failure modes are deliberately asymmetric. Mis-reading a citation as a delivery
# re-creates the fleet-wide blocker this exists to prevent; mis-reading a delivery as
# a citation costs coverage on ONE narrow shape — a close with no `delivery_ref`, no
# `Branch:`, no open PR naming the ident (the mandatory auto-detect scan is
# untouched and still fires), whose prose names its own merged PR with no shipping
# verb anywhere near it. That slip is ANNOUNCED at the call site, with both escapes
# named, rather than being silent.
#
# Negations are rejected explicitly ("not merged yet — PR #6", "unmerged"), and the
# verb needs a left word boundary so "unmerged" does not read as "merged".
# Line-scoped: a cue on the previous line does not carry, which keeps the window
# rule stateable in one sentence. `tolower` for matching only — it preserves length,
# so offsets still index the ORIGINAL line and a URL's owner/repo keeps its case.
_gate_delivery_refs_from_text() {
  printf '%s' "$1" | awk '
    BEGIN {
      RE   = "(https://github\\.com/[a-z0-9._-]+/[a-z0-9._-]+/pull/[0-9]+[a-z0-9]*)|((^|[^a-z0-9])(prs?|pull request)[[:space:]]*#?[[:space:]]*[0-9]+[a-z0-9]*)"
      VERB = "(merged|shipped|landed|delivered|delivery|released|rolled)"
      PRE  = "(^|[^a-z0-9])" VERB "([[:space:]]+(as|in|via|by|to|into|is|was))?[^[:alnum:]]*$"
      NEG  = "(^|[^a-z0-9])(not|never|no|un)[- ]?" VERB "([[:space:]]+(as|in|via|by|to|into|is|was))?[^[:alnum:]]*$"
      OWN  = "(^|[^a-z0-9])(my|our)[[:space:]]*$"
      POST = "^[[:space:]]*(is|was|were|are)[[:space:]]+" VERB
    }
    # same normalisation as the extractor: trailing digit-run, glued alnum and
    # 7+ digit ids rejected, a URL carries its own owner/repo, a bare ref none.
    function refkey(m,   n, k, p) {
      n = m; sub(/^.*[^0-9]/, "", n)
      if (n !~ /^[0-9]{1,6}$/) return ""
      if (tolower(m) ~ /https:\/\/github\.com\//) {
        k = m; sub(/^.*https:\/\/github\.com\//, "", k)
        split(k, p, "/"); return p[1] "/" p[2] "|" n
      }
      return "|" n
    }
    {
      line = $0; low = tolower(line)
      dline = (low ~ /^[[:space:]]*(delivered|delivery|delivers|ships?|shipped)[[:space:]]*:/)
      pos = 1
      while (match(substr(low, pos), RE)) {
        st = pos + RSTART - 1; ln = RLENGTH
        key = refkey(substr(line, st, ln))
        if (key != "") {
          pre = tolower(substr(line, 1, st - 1)); post = tolower(substr(line, st + ln))
          if (dline || (pre ~ PRE && pre !~ NEG) || pre ~ OWN || post ~ POST)
            if (!seen[key]++) print key
        }
        pos = st + ln
      }
    }'
}

# _gate_text_names_a_ref <text> — did this close mention a pull request AT ALL?
#
# DIVE-1955 (review, Marcus): this is the difference between the two states the gate
# can be in when it does not produce a verdict, and they are NOT the same thing:
#
#   "I LOOKED AND COULD NOT TELL"   — a ref was named and could not be confirmed
#                                     (ambiguous, unresolvable, no token, a partial
#                                     scan, unreadable checks). This is a real
#                                     non-verdict and the record must say so.
#   "THERE WAS NOTHING TO LOOK AT"  — the close named no PR, no branch, no delivery.
#                                     Research, comms, decisions, recaps. `unverified`
#                                     is simply the wrong word: nothing was pending
#                                     verification.
#
# Stamping the second case puts a scary merge-gate warning on the majority of closes
# in the fleet within a day, and a marker on every row is a marker nobody reads —
# destroying the exact property the marker was added to buy. Same failure as the
# merged-red one: a signal that cries wolf is worth less than no signal.
# Kept as an explicit named branch rather than implied by a missing condition,
# because the next reader will otherwise collapse the two back together.
#
# Deliberately NOT built on `_gate_pr_refs_from_text`: one caller is the case where
# that parser cannot run at all, so this uses bash's own `[[ =~ ]]` and a substring
# test — no grep, no subprocess — and stays a genuinely independent mechanism.
# Broader than the extractor on purpose: it answers "was a PR mentioned", not "which
# PR", so an over-match here only risks an honest UNVERIFIED note, never a verdict.
_gate_text_names_a_ref() {
  local t="$1"
  [[ "$t" == *"/pull/"* ]] && return 0
  [[ "$t" =~ (^|[^A-Za-z0-9])([Pp][Rr][Ss]?|[Pp][Uu][Ll][Ll][[:space:]]+[Rr][Ee][Qq][Uu][Ee][Ss][Tt])[[:space:]]*#?[[:space:]]*[0-9] ]] && return 0
  return 1
}

# DIVE-2577: every parser above this line only ever recognizes a PR — '#N', a pull
# URL, the word "PR". DIVE-2556 closed done with its OWN result stating "commit
# dc336f7 on branch dive-2556-maker-credit is UNPUSHED (dev3 has no push route)" —
# real, checkable evidence of unlanded work, and nothing upstream of this function
# could see it, because a branch was never a PR. The declared-binding gate (DIVE-1830,
# above in this file) already runs the ancestry+attribution scan for a `Branch:` line
# the maker BOUND; this teaches the mandatory auto-detect gate to run that same scan
# for a branch the maker's own TEXT names but never bound, so describing the branch
# in prose instead of `task set-branch`-ing it is not an escape from the gate.
#
# Anchored to the task's own ident (case-insensitive), followed by our house
# kebab-case branch convention — a candidate MUST carry "<ident>-" as a prefix, the
# same word-boundary discipline the PR-title/head-branch scan already applies. This
# is deliberately narrow: ordinary prose that happens to contain the word "branch"
# ("three branches of this problem") can never match, so closes with no code at all
# (research, decisions, coordination) are untouched — this is the DIVE-1690 shape
# named as itself, not a blanket PR-or-branch requirement.
#
# DIVE-3265 — A FILE IS NOT A BRANCH, AND THE ANCHOR ABOVE CANNOT TELL THEM APART.
# "<ident>-<kebab>" is also how we name the ARTIFACT a non-repo row delivers.
# DIVE-3264's deliverable is a design doc, `community/designs/dive-3264-svc-5dive-
# api-account-split.md`; that basename matched, and the gate then demanded a branch
# of that name land on main. No branch could exist: the deliverable is a file in a
# directory tree that is not a git repo at all. The row became UNCLOSEABLE BY
# CONSTRUCTION, and every obvious escape is shut — results are PRESERVED (DIVE-2483)
# so the offending text cannot be edited out of a later close, and `task set-branch
# <id> ''` is rejected ("invalid branch name") so a binding that was never set cannot
# be cleared. Scoped by CLASS, not by the instance (olivia, DIVE-3264): this fires
# for EVERY non-repo deliverable — design docs, wiki-only rows, anything landing
# under `community/` — so fixing the one filename would leave the next such row
# blocked identically.
#
# THE DISCRIMINATOR IS THE EXTENSION, and the DIRECTION OF THE BIAS is the whole
# argument for choosing it. The two errors are not symmetric:
#   a MISS      — a maker describes an unlanded branch and we do not catch it. Costs
#                 one unlanded branch, which the weekly hygiene digest (#139) still
#                 flags, and the DIVE-1830 declared-`Branch:` gate still catches the
#                 bound case. Recoverable.
#   a FALSE HIT — the row can never close, by construction, with no escape short of
#                 an audited `--force-merge-gate` on a row that has nothing to force.
# So this filter drops rather than guesses. It is a suffix test on the candidate,
# NOT a path test: a branch legitimately appears after a `/` in a forge URL
# (`.../tree/<branch>`), so rejecting path-shaped tokens would cost that shape for
# nothing the extension rule does not already buy.
#
# WHAT STAYS UNCOVERED, named so the next reader does not have to rediscover it: an
# extension-LESS artifact path (a delivered directory, `community/designs/dive-N-x/`)
# still reads as a branch. Unmeasured — every artifact in the measured population
# carries an extension — and a one-line follow-up if it ever bites.
_gate_branch_refs_from_text() {
  local text="$1" ident="$2"
  printf '%s\n' "$text" \
    | grep -ioE "(^|[^A-Za-z0-9])${ident}-[A-Za-z0-9][A-Za-z0-9_.-]*" 2>/dev/null \
    | sed -E 's/^[^A-Za-z0-9]//' \
    | grep -ivE '\.(md|mdx|markdown|txt|rst|patch|diff|json|ya?ml|toml|sh|bash|[jt]sx?|mjs|cjs|py|rb|go|rs|sql|log|csv|tsv|html?|pdf|png|jpe?g|gif|svg|webp|zip|gz|tgz|tar|lock|env|ini|conf|cfg)$' \
    | tr 'A-Z' 'a-z' | sort -u
}

# DIVE-1955: the repos the merge-gate knows about, one slug per line, CLI first.
# `_PUSH_DEFAULT_REPO` used to be the whole world: every bare `#N` resolved against
# 5dive-ai/5dive, so lodar/5dive-api (== prod) and lodar/5dive-frontend had ZERO
# coverage AND — worse — an api task naming "PR #6" got a CONFIDENT verdict about an
# unrelated CLI pull request. Overridable so a new repo is config, not a patch, and
# so the tests can point the whole gate at fixtures.
# DIVE-2431: the default was exactly those three, and a delivery to any OTHER repo we
# ship from was graded by a set that never contained it. Both directions were live and
# both were measured on DIVE-2303, whose delivery landed in 5dive-ai/character-packs:
#   FALSE ACCEPT  — the gate found the ident in 5dive-ai/5dive (step 1 of the same
#                   ticket, days earlier) and closed clean having never looked at
#                   character-packs. Correct by luck.
#   FALSE REFUSE  — strip that coincidence and genuinely-landed work is refused with
#                   "nothing on main in <3 slugs> shows branch ... landed", whose remedy
#                   is an audited `--force-merge-gate` override for a gate that was
#                   simply looking in the wrong place.
#
# WHY A LIST AND NOT A DERIVATION. Deriving the set from the git remotes on the box, or
# from the org's repo list, removes the drift but buys a worse property: the gate's
# verdict would then depend on host filesystem state or on network reachability at close
# time. A gate that answers differently on two boxes, or refuses when offline, is not a
# gate. The list is deterministic and auditable; drift is the price.
#
# WHAT PAYS FOR THE DRIFT: every verdict names the set it searched — the refusals always
# did, and DIVE-2431 added it to the ACCEPT, which was the silent half. A stale list now
# announces itself at the exact moment it matters, to the person it is failing. That is
# the property to preserve if this list is ever edited; adding a repo without it just
# moves the blind spot.
# ---------------------------------------------------------------------------
# DIVE-2414 — THE SUBJECT-STATE READER. ONE reader, pointed TWO directions.
#
# THE DEFECT IT REPLACES. "A gate whose task looks shipped retires with it" reads
# the ROW's own commit stream (`git log --grep=<ident>`, _hb_repo_grep_ident) and
# calls that evidence about the GATE. It is not. A row carrying a six-item program
# gets one commit for item #5 and reads as complete: DIVE-2382 was flagged
# "likely shipped, verify+close" while its live human gate asked about a
# completely different item. On a ticket that lands in pieces that nudge points
# the right way for the wrong reason and arrives with the authority of an
# automatic check. So the rule this file now enforces:
#
#   THE READER RESOLVES WHAT THE GATE IS ABOUT — the pull request it NAMES — and
#   NEVER inherits the row's commit stream as evidence. A gate that names NO
#   subject does not auto-retire; it stays open and SAYS so.
#
# TWO DIRECTIONS, ONE READER (olivia's scope, and it is a correctness argument,
# not just anti-duplication — built as two rows it repeats DIVE-2382's own defect):
#   (a) retire/flag a gate when the PR its ASK names has merged   — _gate_subject_verdict
#   (b) the DIVE-1830 merge-gate's cited-not-delivered gap, where a PR named in
#       prose is never read for its state AT ALL                 — _gate_cited_state_note
# Same blindness, opposite directions: one asks "is my subject resolved?", the
# other "what state is the thing you are citing actually in?".
#
# _gate_subject_refs_from_text <text> — of the refs this text names, which ones is
# it ASKING ABOUT? Emits the qualified `<slug>|<n>` subset, same shape as
# _gate_delivery_refs_from_text (DIVE-1965), and for the same reason: the subject
# must come from a STRUCTURED, INTENTIONAL signal, never from "a number appeared in
# the text". DIVE-2382's own ask is the pinned negative — it says "fix #5 is
# already in review as PR #335", a PR it is NOT about, and a mention-predicate
# would have retired a live approval on the strength of it.
#   Accepted: a `Subject:` / `Gate-subject:` / `Blocked-on:` line, or an
# ACTION-REQUEST verb adjacent to the ref (approve / merge / land / sign off) —
# the ask wants something DONE to that PR. Report verbs (review, shipped, cited)
# are deliberately NOT in the set: "in review as PR #335" is the exact shape that
# must miss, and "shipped as PR #N" describes a PR rather than asking about it.
# The asymmetry is deliberate and is the whole safety argument: reading a citation
# as the subject retires a live human question, reading the subject as a citation
# costs ONE nudge. Line-scoped, negations rejected, `tolower` for matching only so
# offsets still index the original line (a URL keeps its owner/repo case).
#
# THE VERB LIST IS A CLOSED VOCABULARY, AND THAT IS THE DESIGN, not an oversight
# left for the next person to finish (Marcus, verifying DIVE-2414). An ask phrased
# outside it — "can you OK PR #123" — yields NO subject, and a gate with no subject
# withholds the flag. That is the fail-closed direction and it costs a nudge.
# Widening the vocabulary is how the pinned negatives come back: E3 (DIVE-2382's
# "already in review as PR #335"), E4 (a bare mention) and E8 ("shipped as PR #N")
# in tests/gate_subject_state_unit.sh each pass only because some phrasing is
# OUTSIDE the set. If you add a verb, add it with the arm that proves the
# citations still miss — and note that the two halves are pinned by mutations the
# other survives: subject:=any-mention reds E3/E4/E5/E8, subject:=nothing reds
# E1/E2/E6/E7, a clean 4/4 partition with no overlap. Keep that property.
_gate_subject_refs_from_text() {
  printf '%s' "$1" | awk '
    BEGIN {
      RE   = "(https://github\\.com/[a-z0-9._-]+/[a-z0-9._-]+/pull/[0-9]+[a-z0-9]*)|((^|[^a-z0-9])(prs?|pull request)[[:space:]]*#?[[:space:]]*[0-9]+[a-z0-9]*)"
      VERB = "(approve|approves|approved|approval|merge|merges|merging|land|lands|landing|sign[- ]?off|signs[- ]?off|signed[- ]?off)"
      CONN = "([[:space:]]+(as|in|on|of|to|into|via|by|the|this|that|is|was|it))*"
      PRE  = "(^|[^a-z0-9])" VERB CONN "[^[:alnum:]]*$"
      NEG  = "(^|[^a-z0-9])(not|never|no|un|cannot|can[[:space:]]not|dont|do[[:space:]]not)[- ]?" VERB CONN "[^[:alnum:]]*$"
      POST = "^[[:space:]]*(is|was|needs|need)[[:space:]]+(your[[:space:]]+|a[[:space:]]+)?(approval|approving|sign[- ]?off|merging|merged|landing)"
    }
    function refkey(m,   n, k, p) {
      n = m; sub(/^.*[^0-9]/, "", n)
      if (n !~ /^[0-9]{1,6}$/) return ""
      if (tolower(m) ~ /https:\/\/github\.com\//) {
        k = m; sub(/^.*https:\/\/github\.com\//, "", k)
        split(k, p, "/"); return p[1] "/" p[2] "|" n
      }
      return "|" n
    }
    {
      line = $0; low = tolower(line)
      sline = (low ~ /^[[:space:]]*(subject|gate-subject|gate subject|blocked-on|blocked on)[[:space:]]*:/)
      pos = 1
      while (match(substr(low, pos), RE)) {
        st = pos + RSTART - 1; ln = RLENGTH
        key = refkey(substr(line, st, ln))
        if (key != "") {
          pre = tolower(substr(line, 1, st - 1)); post = tolower(substr(line, st + ln))
          if (sline || (pre ~ PRE && pre !~ NEG) || post ~ POST)
            if (!seen[key]++) print key
        }
        pos = st + ln
      }
    }'
}

# _gate_ref_states <tok> <ident> <task_slug> — THE READER. Qualified refs on
# STDIN, one MEASURED state line per ref on stdout:
#
#   <number>|<STATE>|<where>     STATE ∈ MERGED | MERGED-RED | OPEN | CLOSED
#                                        | AMBIGUOUS | UNRESOLVED
#
# Every state comes from `gh pr view` on the ref ITSELF, through the DIVE-1955
# qualified resolver (a bare `#N` is looked up in the declared repo, or bound by
# ident evidence, or reported AMBIGUOUS — never guessed against a default slug).
# There is deliberately NO git call anywhere in this path: the moment this reader
# can reach the row's commit stream, the defect it exists to delete is back.
# MERGED-RED is kept DISTINCT from MERGED because "merged" is not the same claim
# as "landed and green" (DIVE-1935), and a caller retiring a human ask must not
# collapse them.
_gate_ref_states() {
  local tok="$1" ident="$2" task_slug="$3" qref st rslug
  while IFS= read -r qref; do
    [[ -n "$qref" ]] || continue
    st=$(_gate_resolve_qualified "$qref" "$tok" "$ident" "$task_slug")
    rslug="${st%%|*}"; st="${st#*|}"
    case "$rslug|$st" in
      AMBIGUOUS\|*)          printf '%s|AMBIGUOUS|%s\n' "${qref#*|}" "$st" ;;
      \|)                    printf '%s|UNRESOLVED|%s\n' "${qref#*|}" "$(_gate_search_scope "$qref" "$task_slug")" ;;
      *\|MERGED\|*\|FAILURE) printf '%s|MERGED-RED|%s\n' "${qref#*|}" "$rslug" ;;
      *\|MERGED\|*)          printf '%s|MERGED|%s\n' "${qref#*|}" "$rslug" ;;
      *\|OPEN\|*)            printf '%s|OPEN|%s\n' "${qref#*|}" "$rslug" ;;
      *)                     printf '%s|%s|%s\n' "${qref#*|}" "${st%%|*}" "$rslug" ;;
    esac
  done
}
_GATE_SUBJECT_CAP=5

# _gate_subject_verdict <ask-text> <tok> <ident> <task_slug> — DIRECTION (a).
# One line: `NO-SUBJECT` | `UNKNOWN|<why>` | `OPEN|<detail>` | `MERGED|<detail>`.
#
# Feed it the gate's own ASK and nothing else. NOT the row body: the body carries
# the whole program and every PR it cites, which is exactly how a row-level signal
# gets read as a gate-level one — the DIVE-2382 misread, one input earlier.
#
# Precedence, strictest first, because these are answers to "may this ask be
# retired without a human":
#   OPEN     — a subject is still open. Nothing else matters; the ask is live.
#   UNKNOWN  — a subject exists and its state could not be READ (no gh, no token,
#              dead parser, unresolvable, ambiguous, merged-but-red). A non-verdict
#              is not a negative (DIVE-2318) and must never read as "resolved".
#   MERGED   — every subject named resolved, and all of them merged green.
#   NO-SUBJECT — the ask names no pull request AT ALL. Not a failure: most gates
#              ask for a decision, not for a merge. Nothing can retire them
#              automatically and the caller has to say that out loud.
_gate_subject_verdict() {
  local text="$1" tok="$2" ident="$3" task_slug="$4"
  local refs n
  refs=$(_gate_subject_refs_from_text "$text")
  refs=$(printf '%s\n' "$refs" | grep . || true)
  [[ -n "$refs" ]] || { printf 'NO-SUBJECT'; return 0; }
  # A ref was named, so from here on silence is never an accept. An unrunnable
  # parser or a missing credential is UNKNOWN — the same distinction DIVE-1955
  # drew between "I looked and could not tell" and "there was nothing to look at".
  _gate_pr_refs_engine_ok || { printf 'UNKNOWN|ref-parser-broken'; return 0; }
  command -v gh >/dev/null 2>&1 || { printf 'UNKNOWN|gh-absent'; return 0; }
  [[ -n "$tok" ]] || { printf 'UNKNOWN|no-gh-token'; return 0; }
  n=$(printf '%s\n' "$refs" | grep -c .) || n=0
  local states open="" merged="" unk=""
  states=$(printf '%s\n' "$refs" | head -n "$_GATE_SUBJECT_CAP" | _gate_ref_states "$tok" "$ident" "$task_slug")
  local num st where
  while IFS='|' read -r num st where; do
    [[ -n "$num" ]] || continue
    case "$st" in
      OPEN)   open="${open:+$open, }#${num} in ${where}" ;;
      MERGED) merged="${merged:+$merged, }#${num} in ${where}" ;;
      *)      unk="${unk:+$unk; }#${num} ${st} (${where})" ;;
    esac
  done <<<"$states"
  (( n > _GATE_SUBJECT_CAP )) && unk="${unk:+$unk; }only the first ${_GATE_SUBJECT_CAP} of ${n} named refs were checked"
  [[ -n "$open" ]] && { printf 'OPEN|%s' "$open"; return 0; }
  [[ -n "$unk"  ]] && { printf 'UNKNOWN|%s' "$unk"; return 0; }
  [[ -n "$merged" ]] && { printf 'MERGED|%s' "$merged"; return 0; }
  printf 'UNKNOWN|no state read for any named subject'
}

# _gate_cited_state_note <qualified-refs> <tok> <ident> <task_slug> — DIRECTION (b).
# The DIVE-1830 merge-gate sets CITED refs aside and, until now, did not read them
# at all: "nothing binds them to this task, so their merge state was NOT checked".
# The set-aside is right — a cited PR is another task's delivery and must never
# gate this close (DIVE-1965 deleted that fleet-wide blocker on purpose). Reading
# it is a different act from judging it. DIVE-2382's own close cited PR #337 while
# it was OPEN and nothing said so; the same open PR then outlived the row that was
# its only tracker. This returns the MEASURED state as a note. It never refuses,
# never stamps UNVERIFIED, and never changes a verdict — it is disclosure only.
# Bounded to 3 (a close that cites ten PRs must not pay ten round-trips) and the
# cap is named in the note, because a silent cap reads as "all of them checked".
_gate_cited_state_note() {
  local qrefs="$1" tok="$2" ident="$3" task_slug="$4"
  local refs n out="" num st where
  refs=$(printf '%s\n' "$qrefs" | grep . || true)
  [[ -n "$refs" ]] || { printf 'no cited reference resolved to read'; return 0; }
  [[ -n "$tok" ]] || { printf 'state NOT read (no gh credential resolved)'; return 0; }
  n=$(printf '%s\n' "$refs" | grep -c .) || n=0
  while IFS='|' read -r num st where; do
    [[ -n "$num" ]] || continue
    out="${out:+$out; }#${num} ${st} in ${where}"
  done < <(printf '%s\n' "$refs" | head -n 3 | _gate_ref_states "$tok" "$ident" "$task_slug")
  [[ -n "$out" ]] || out="state NOT read"
  (( n > 3 )) && out="$out (first 3 of $n cited refs read)"
  printf '%s' "$out"
}

_gate_repo_slugs() {
  local raw="${FIVE_GATE_REPOS:-}"
  if [[ -z "$raw" ]]; then
    # The repos task deliveries actually land in. Kept to ACTIVE product repos rather
    # than every repo we own — an inactive repo costs a lookup on every close and has
    # never received a delivery.
    raw="$(_push_repo_slug "$_PUSH_DEFAULT_REPO") lodar/5dive-api lodar/5dive-frontend"
    raw="$raw 5dive-ai/character-packs 5dive-ai/skills 5dive-ai/5dive-plugins"
    raw="$raw 5dive-ai/5dive-mcp 5dive-ai/openagent 5dive-ai/ops"
    raw="$raw lodar/5dive-blog lodar/5dive-mobile"
  fi
  printf '%s' "$raw" | tr ',' ' ' | tr -s '[:space:]' '\n' | awk 'NF && !seen[$0]++'
}

# ── DIVE-3458: a delivery into a repo we do not own ────────────────────────
# The merge gate refuses `task done` until the bound PR is merged. That is right
# for our own repos, where merging is OUR action and "delivered but not landed"
# is the failure it exists to catch (DIVE-2096, DIVE-2656). It is WRONG for a
# submission into someone else's repository: merging is a third party's decision
# on their timeline, and NO WORK WE DO can satisfy the gate. Six rows were in that
# class on 2026-08-16 (awesome-list submissions), two already blocked on it.
#
# Holding those rows open is not the conservative option, it is the corrosive one:
# an open row is supposed to mean WE OWE WORK, and a population of rows open
# because a stranger has not clicked anything destroys that meaning for every
# other row on the board. The rows themselves already say so — DIVE-3439's
# acceptance is verbatim "DONE = the PR/submission URL on this row."
#
# THE TEST IS THE HOST AND OWNER OF THE BOUND REF, never the title or a keyword.
# A title-keyword test is what bound PR #649 to DIVE-3419 and cost two refused
# closes. Owners come from _gate_repo_slugs, so the FIVE_GATE_REPOS seam keeps
# working and there is no second list to drift.
#
# FAIL CLOSED on anything unparseable: a ref that yields no owner/repo, or is not
# a github.com ref at all, is NOT foreign and keeps the full gate. The expensive
# mistake here is exempting one of our own deliveries, not gating a foreign one.
_gate_our_owners() {
  _gate_repo_slugs | awk -F/ 'NF==2 && $1 != "" { print tolower($1) }' | awk '!seen[$0]++'
}

# _gate_foreign_delivery <delivery-ref> — rc 0 when the ref names a repository
# whose OWNER is not one of ours. rc 1 otherwise (including "cannot tell").
_gate_foreign_delivery() {
  local ref="$1" slug owner o
  [[ "$ref" =~ ^https?://github\.com/ || "$ref" =~ ^git@github\.com: ]] || return 1
  slug=$(_gate_slug_from_url "$ref") || slug=""
  [[ -n "$slug" && "$slug" == */* ]] || return 1
  owner="${slug%%/*}"; owner="${owner,,}"
  [[ -n "$owner" ]] || return 1
  while read -r o; do
    [[ -n "$o" ]] || continue
    [[ "$o" == "$owner" ]] && return 1
  done < <(_gate_our_owners)
  return 0
}

# _gate_slug_from_url <text> — OWNER/REPO out of the first github URL in <text>, or
# empty. Accepts a pull URL, a repo URL and an ssh remote.
_gate_slug_from_url() {
  printf '%s' "$1" \
    | grep -oE '(https://github\.com/|git@github\.com:)[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' \
    | head -1 | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' || true
}

# _gate_merged_not_deployed <accepting-repo-slug> — DIVE-2641 (split from DIVE-2621,
# item b+c). The sentence EVERY accepting arm of the merge gate appends to its own
# receipt.
#
# WHY HERE. Each accepting arm prints `done=merged-to-main satisfied`, which is TRUE,
# at the exact moment the reader assumes the STRONGER claim nobody checked: that the
# change is RUNNING. Four agents made that substitution independently on 2026-08-03
# (olivia DIVE-2587, dev DIVE-2571, dev3 on marketplace clones, main across the
# v0.18.3-v0.18.6 cuts). They were not careless — the system told them they were done.
# So the close gate is the cheapest place to interrupt it: same breath as the grade.
#
# THIS CHANGES NO ACCEPTANCE. It appends text to warns that already fire on paths that
# already passed; no arm refuses, no new failure mode exists, and every refusal is
# untouched. Merged-to-main is necessary and correctly verified — this only stops the
# SENTENCE AFTER the grade travelling further than the evidence.
# community/wiki/merged-to-main-is-a-claim-about-the-authors-artifact-not-the-readers.md
#
# ONE SHORT SENTENCE, deliberately. A paragraph gets skipped, and the entire value is
# that it is read at the instant of the inference.
#
# The DEPLOYED-ARTIFACT prompt (item c) is keyed off the repo the ACCEPTING EVIDENCE
# was found in — never off the task text, which is the maker's prose and describes what
# they meant rather than where it landed. Only repos whose artifact a reader EXECUTES
# get a prompt, and each names the surface that actually measures THAT artifact: the
# host CLI check cannot see a marketplace clone and vice versa, so naming one for the
# other would be a check that cannot answer the question it was cited for.
#
# WHICH IS WHY THE GENERIC HALF NAMES BARE `5dive doctor` AND NO CATEGORY. It said
# `--category=host` in the first cut, and that is only right for the host binary: on a
# marketplace row the FIRST surface the reader was handed was the one that reads
# /usr/local/bin/5dive and can say nothing about a clone in an agent's own $HOME. Bare
# `5dive doctor` runs every category (cmd_doctor.sh: an empty filter sets run_host=1 AND
# run_plugins=1), so it is true for every repo and the keyed half below narrows it.
# Caught by RENDERING the three shapes and reading them, not by any assertion — the two
# arms that now grade it (D5/D6) were written after the fact, which is the honest ordering.
_gate_merged_not_deployed() {
  local _slug="${1:-}"
  printf '%s' ' NOT ESTABLISHED by this: that the change is DEPLOYED — merged is a property of the repo, not of the artifact anyone is RUNNING, so check the installed side (`5dive doctor`) before you report this live (DIVE-2621/2641).'
  case "${_slug##*/}" in
    5dive|5dive-cli)
      printf ' DEPLOYED-ARTIFACT ROW: %s ships /usr/local/bin/5dive, which cron and every agent execute — a host still on the previous release runs the OLD code whatever main says; `5dive doctor --category=host` reports installed vs published (DIVE-2640).' "$_slug" ;;
    5dive-plugins)
      printf ' DEPLOYED-ARTIFACT ROW: %s ships the marketplace clone each agent runs out of its OWN $HOME, so freshness is per-agent and one refresh does not fix the fleet — `5dive doctor --category=plugins` reports it per clone (DIVE-2642).' "$_slug" ;;
  esac
}

# _gate_task_repo_slug <delivery_ref> <body> — the repo THIS TASK DECLARED, or empty.
# Precedence: the delivery_ref URL (a delivered PR carries its own repo, which is why
# ask 1 says prefer it) > an explicit `Repo: owner/repo` body line, the sibling of the
# DIVE-1462 `Branch:` line. Empty means unknown, and unknown must stay unknown — it is
# never quietly filled in with a default.
#
# DIVE-1963: there was a THIRD fallback — any github URL sitting anywhere in the body —
# and it read a URL that happened to be MENTIONED as a declaration of where this task's
# work lives. DIVE-1955's own close is the specimen: its body QUOTES the constant it is
# about (`_PUSH_DEFAULT_REPO="https://github.com/5dive-ai/5dive.git"`), so the gate
# bound every bare `#N` to the CLI repo and never looked in api or frontend at all. The
# ticket describing an implicit repo standing in for a missing one triggered a narrower
# version of itself, sourced from prose instead of from a constant.
#
# Deleting it CANNOT lose coverage, which is why this is a deletion and not a widening:
# with no declared repo a bare `#N` goes through the DIVE-1955 existence-count sweep,
# which searches EVERY known repo — strictly a superset of the single repo the
# inference picked. What it does delete is the sharper half. "The inferred repo misses"
# is only one of the two cases; when the inferred repo HAS a `#N`, the old path handed
# back a confident verdict about a pull request nobody claimed, which is the
# "wrong, not blind" failure DIVE-1955 exists to remove. So the fix is NOT "sweep when
# the inference misses" — that leaves the dangerous half untouched. Same rule DIVE-1965
# settled one layer up: a binding comes from a STRUCTURED, INTENTIONAL signal, never
# from "a URL appeared in the text". Prose is evidence of discussion, not declaration.
#
# The superset is over the CONFIGURED repo set, not over all of GitHub (Marcus, review):
# `_gate_repo_slugs` is the world, and it is `FIVE_GATE_REPOS` when that is exported.
# Unset — the default on every box — it is the three real repos, which is what makes the
# claim hold in practice, and tests/task_merge_gate_inferred_repo_unit.sh pins that
# default with the env cleared rather than leaving it asserted in prose. A box that
# exports a NARROWER list narrows the sweep too, and there the deleted inference could
# have named a repo outside the configured world — but a binding that reaches outside
# the set the operator configured is its own defect, not coverage worth keeping.
_gate_task_repo_slug() {
  local dref="$1" body="$2" s=""
  if [[ -n "$dref" ]]; then
    s=$(_gate_slug_from_url "$dref"); [[ -n "$s" ]] && { printf '%s' "$s"; return 0; }
  fi
  local line
  line=$(printf '%s\n' "$body" | grep -ioE '^[[:space:]]*repo:[[:space:]]*\S+' | head -1 || true)
  if [[ -n "$line" ]]; then
    line="${line#*:}"; line="${line#"${line%%[![:space:]]*}"}"
    s=$(_gate_slug_from_url "$line")
    [[ -z "$s" && "$line" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && s="${line%.git}"
    [[ -n "$s" ]] && { printf '%s' "$s"; return 0; }
  fi
  return 0
}

# _gate_bind_slug <qualified-ref> <task_slug> — the ONE repo a ref binds to, or EMPTY
# for "nothing binds it, sweep every known repo". Precedence: the repo the ref carries
# itself (a pull URL) > the repo the TASK declared > unbound.
#
# DIVE-1963 (Marcus, review): the resolver and the message reporting its scope used to
# derive this INDEPENDENTLY, and the original comment claimed they "cannot drift". They
# agreed, but that is parallel derivation — two copies that happen to match today, which
# buys "does not currently drift". Cannot-drift is what a shared definition buys, so
# here it is: one function, two callers, and the sentence the reader gets is computed
# from the same answer the lookup used. Same shape as the DIVE-1932 lesson — a rule that
# holds because of the shape of the code, rather than because something declares it, is
# preserved by nothing.
_gate_bind_slug() {
  local rslug="${1%%|*}"
  [[ -z "$rslug" && -n "$2" ]] && rslug="$2"
  printf '%s' "$rslug"
}

# _gate_search_scope <qualified-ref> <task_slug> — the repo(s) a ref is ACTUALLY looked
# up in, comma-joined. DIVE-1963: the unresolvable warning said "in any known repo"
# after searching exactly ONE, so the message asserted a sweep that never happened, and
# a warning that misstates its own scope is the defect class this arc exists to delete.
_gate_search_scope() {
  local rslug; rslug=$(_gate_bind_slug "$1" "$2")
  if [[ -n "$rslug" ]]; then printf '%s' "$rslug"
  else _gate_repo_slugs | paste -sd, -; fi
}

# _gate_pr_probe <n> <tok> <slug> <ident> — one bounded read-only lookup of PR #n in
# <slug>, as `STATE|mergedAt|CHECKS|IDENTMATCH`, empty when the PR does not exist
# there. IDENTMATCH is 1 when the PR's title or head branch names <ident> at word
# boundaries — the EVIDENCE that this number, in this repo, belongs to this task.
# That evidence is what lets a bare "#N" bind at all without guessing a repo.
_gate_pr_probe() {
  local n="$1" tok="$2" slug="$3" ident="$4"
  _gate_gh "$tok" 10 pr view "$n" --repo "$slug" \
      --json state,mergedAt,statusCheckRollup,title,headRefName \
      -q "[ .state,
            (.mergedAt // \"null\"),
            $_GATE_ROLLUP_JQ,
            ( if ((.title // \"\") | test(\"(^|[^A-Za-z0-9])${ident}([^A-Za-z0-9]|\$)\";\"i\"))
                 or ((.headRefName // \"\") | test(\"(^|[^A-Za-z0-9])${ident}([^A-Za-z0-9]|\$)\";\"i\"))
              then \"1\" else \"0\" end ) ] | join(\"|\")" \
      2>/dev/null || true
}

# _gate_resolve_qualified <slug|number> <tok> <ident> <task_slug> — resolve ONE
# qualified ref to `<slug>|STATE|mergedAt|CHECKS`, or `AMBIGUOUS|<slug,slug,…>`, or
# EMPTY for "exists nowhere we know / could not resolve".
#
# THIS IS THE ANTI-FABRICATION RULE (DIVE-1955 ask 2). Three cases:
#   * the ref carries its own repo (pull URL)  -> resolve there, done.
#   * the ref is bare and the TASK declared a repo -> resolve there, done.
#   * the ref is bare and the task's repo is UNKNOWN -> do NOT pick a default. Probe
#     every known repo and count the ones that actually HAVE a #N:
#       0 -> unresolvable (empty), same loud note as before.
#       1 -> that repo. There is nothing to disambiguate: the number identifies
#            exactly one pull request in the world we know about. This is the common
#            case and it is why the DIVE-1935 coverage does not regress.
#       2+ -> a REAL collision. Break it only on evidence: if exactly one of them
#            NAMES the ident in its title or head branch, that one binds. Otherwise
#            AMBIGUOUS — any single verdict would be invented.
# Ambiguous is a LOUD non-answer, never a block and never a pass — a fabricated
# verdict can refuse a legitimate close or bless a bad one, which is strictly worse
# than admitting we do not know which pull request the maker meant.
_gate_resolve_qualified() {
  local qref="$1" tok="$2" ident="$3" task_slug="$4"
  local n="${qref#*|}" rslug
  # DIVE-1963: shared with `_gate_search_scope`, so the repo we look in and the repo the
  # warning NAMES are one answer, not two derivations that agree.
  rslug=$(_gate_bind_slug "$qref" "$task_slug")
  if [[ -n "$rslug" ]]; then
    local st; st=$(_gate_pr_state "$n" "$tok" "$rslug")
    [[ -n "$st" ]] && printf '%s|%s' "$rslug" "$st"
    return 0
  fi
  local s p exists="" exists_n=0 only="" only_st="" named="" named_st="" named_n=0
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    p=$(_gate_pr_probe "$n" "$tok" "$s" "$ident")
    [[ -n "$p" ]] || continue
    exists="${exists:+$exists,}$s"; exists_n=$((exists_n+1)); only="$s"; only_st="${p%|*}"
    if [[ "${p##*|}" == "1" ]]; then named_n=$((named_n+1)); named="$s"; named_st="${p%|*}"; fi
  done < <(_gate_repo_slugs)
  [[ $exists_n -eq 0 ]] && return 0
  [[ $exists_n -eq 1 ]] && { printf '%s|%s' "$only" "$only_st"; return 0; }
  [[ $named_n -eq 1 ]] && { printf '%s|%s' "$named" "$named_st"; return 0; }
  printf 'AMBIGUOUS|%s' "$exists"
  return 0
}

# _gate_pr_refs_engine_ok — positive control for the extractor above. "No refs
# found" must be provably different from "the parser cannot run": a canary with a
# known answer is checked before an empty result is trusted. Cheap (no subprocess
# beyond the extractor itself) and it converts an unrunnable grep from a silent
# fail-open into a named, audited unverified close.
_gate_pr_refs_engine_ok() {
  [[ "$(_gate_pr_refs_from_text 'ship PR #4242 via https://github.com/o/r/pull/99')" == "99
4242" ]]
}

# DIVE-1955 (review, Marcus): the check verdict is the LATEST RUN PER CHECK NAME, not
# "any FAILURE anywhere in the rollup". `statusCheckRollup` carries every run on the
# head commit, so a check that failed and was then re-run green still contributes its
# old FAILURE — and the gate called the PR red. Proven on lodar/5dive-api#13: smoke-gate
# FAILED 11:49:41, SUCCEEDED 12:41:15, merged 12:42:06. It went green and then merged;
# reporting it as a merged-red escape is a FALSE POSITIVE. A merged-red table that cries
# wolf gets ignored, at which point it is worth less than no table at all.
# Group by name (CheckRun) or context (StatusContext), sort each group by its own
# timestamp, keep the last, and judge only those. Runs with no timestamp sort first, so
# a timestamp-less duplicate can never outrank a real completion.
readonly _GATE_ROLLUP_JQ='
  ( [ (.statusCheckRollup // [])[]?
      | { n: (.name // .context // ""),
          c: (.conclusion // .state // ""),
          t: (.completedAt // .startedAt // .createdAt // "") } ]
    | group_by(.n) | map(sort_by(.t) | last | .c)
    | if   any(. == "FAILURE" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED" or . == "ERROR")
      then "FAILURE" elif length == 0 then "NONE" else "OK" end )'

# DIVE-1935: resolve ONE pr ref (number or url) to `STATE|mergedAt|CHECKS` where
# CHECKS is FAILURE (at least one failed/cancelled/timed-out/action-required run),
# NONE (no checks reported) or OK. Empty output means COULD NOT RESOLVE — no
# token, no network, gh absent, or the ref isn't a PR at all. Callers MUST treat
# empty as "unverified" and say so out loud rather than as "fine": a resolver that
# silently yields nothing is the exact failure this ticket exists to delete.
# Read-only (`gh pr view`), bounded by `timeout`.
_gate_pr_state() {
  local ref="$1" tok="$2" slug="$3"
  local -a repo_arg=()
  [[ "$ref" =~ ^[0-9]+$ ]] && repo_arg=(--repo "$slug")
  _gate_gh "$tok" 10 pr view "$ref" "${repo_arg[@]}" \
      --json state,mergedAt,statusCheckRollup \
      -q "[ .state, (.mergedAt // \"null\"), $_GATE_ROLLUP_JQ ] | join(\"|\")" \
      2>/dev/null || true
}

# DIVE-2296: _gate_branch_open_pr <slug> <branch> <tok> — is there an OPEN PR for
# this head, and where are its checks? Prints `N|CHECKS` (CHECKS as in
# _gate_pr_state: FAILURE / NONE / OK) or EMPTY for "no open PR found, or the
# query could not run".
#
# WHY THIS EXISTS AT ALL. The branch-path refusal below reports the SAME sentence
# for two states that demand opposite responses: no PR exists for this branch (go
# open one), and a PR exists and is sitting in an 18-minute CI run (wait). For a
# maker holding no gh credential that refusal is the ONLY window onto their own
# work, so the collapse does not merely under-inform, it manufactures round trips:
# measured on DIVE-2286, dev2 filed a gate asking main to open a PR that dev2 had
# opened fifteen minutes earlier, then two more asking for a merge that was
# waiting on checks. Three asks, all of them answerable by one read.
#
# This is DIAGNOSTIC ONLY and deliberately so: an OPEN PR accepts NOTHING here and
# must not — done=merged-to-main is the whole point of the DIVE-1830 gate, and a
# refusal that explains itself better is not a refusal that yields. It is called
# from the refusal arm only, never on an accepting path, so a close that passes
# pays nothing for it.
_gate_branch_open_pr() {
  local slug="$1" branch="$2" tok="$3" out rc=0
  out=$(_gate_gh "$tok" 10 pr list --repo "$slug" --head "$branch" --state open \
      --json number,statusCheckRollup \
      -q "[ (.[0].number // empty | tostring), ( .[0] // {} | $_GATE_ROLLUP_JQ ) ] | join(\"|\")" \
      2>/dev/null) || rc=$?
  # THREE ANSWERS, NOT TWO. A query that could not RUN — no rail, an invalid token,
  # a timeout, gh absent — must never render as "there is no open PR". That is the
  # DIVE-2318 defect exactly, and it is the one this ticket is downstream of: an
  # unreached question printed as a measured no. It has already bitten the sibling
  # surface (an invalid credential made `task done` refuse on a row whose merge WAS
  # on main, because the gate asked gh and not git), so it is guarded here at birth.
  #   Two independent signals, because either alone is incomplete: a non-zero rc,
  # and EMPTY output. The second matters because the no-PR case is not empty — jq
  # renders it as a bare rollup ("NONE"), so nothing at all means the payload was
  # never valid JSON, whatever the exit status said.
  if (( rc != 0 )) || [[ -z "$out" ]]; then printf 'UNREADABLE'; return 0; fi
  # A number is required before believing there is a PR: an absence that still
  # LOOKS like a value is the collapse this function exists to undo.
  [[ "$out" =~ ^[0-9]+\| ]] || out=""
  printf '%s' "$out"
}

# DIVE-2656 PART 2: _gate_graded_sha <text> — the sha a verifier STATES it graded.
#
# This is a FENCE, not a scrape. It matches only a labelled declaration —
# `graded-sha: <7-40 hex>` (also `graded sha`, `graded_sha`, `=` for `:`,
# any case) — and deliberately NOT a bare 40-hex string sitting in prose. A
# result routinely names shas it did not grade (the base it rebased onto, a
# squash sha it is citing, a sha in a quoted error), so "there is a hex blob in
# here" is a different claim from "this is what I graded" and only the second
# one may drive a refusal. Prose that forks the map is how this surface breaks;
# an explicit label is the whole reason the comparison downstream is safe.
#
# LAST occurrence wins: `--append-result` prepends the earlier close's text, so
# the most recent statement is the later one.
# Prints lowercase hex, or EMPTY when the result makes no such claim. Empty is
# "the verifier said nothing", never "it matched" — the caller must not read it
# as a pass.
_gate_graded_sha() {
  local txt="${1:-}" line sha=""
  while IFS= read -r line; do
    if [[ "$line" =~ [Gg][Rr][Aa][Dd][Ee][Dd][-_\ ][Ss][Hh][Aa][[:space:]]*[:=][[:space:]]*([0-9a-fA-F]{7,40}) ]]; then
      sha="${BASH_REMATCH[1]}"
    fi
  done <<<"$txt"
  printf '%s' "${sha,,}"
}

# DIVE-2835: _gate_version_claim <text> — the version a close STATES it verified on.
#
# Sibling of `_gate_graded_sha` above, and deliberately a LOOSER fence, for one
# reason worth stating because it looks like an inconsistency: THE TIGHTNESS OF A
# FENCE BELONGS TO THE CONSEQUENCE IT DRIVES. `graded-sha` drives a REFUSAL, so a
# false positive blocks a close and the fence must be a labelled declaration only.
# This one can never do more than WARN, so its false positive costs one line of
# output while its false NEGATIVE costs what DIVE-2762 cost: a result reading
# "VERIFIED ON v0.19.2" while this host ran 0.19.1, the board reading fixed for a
# full day, and the live defect eating maker text twice with a verifier signature
# on the row. A label-only fence (`verified-on:`) would be tidy and would have
# matched NOTHING in the incident that motivates this, because the claim was
# ordinary prose. A guard that cannot fire on its own founding case is decoration.
#
# So: a verification VERB and a full x.y.z version on the SAME line, verb first.
# Requiring all three parts is what keeps it from matching the versions a result
# routinely names without claiming to have verified against them — "fixed in
# v0.19.2, rollout tracked in DIVE-2816", a version in a quoted log line, a
# changelog citation. LAST occurrence wins, same as graded-sha: `--append-result`
# prepends the earlier close's text, so the later statement is the current one.
#
# Prints the bare version (no leading v), or EMPTY when the result makes no such
# claim. Empty is "nothing was claimed", never "it matched".
_gate_version_claim() {
  local txt="${1:-}" line ver=""
  # One regex, and the ORDER inside it is the fence: the verb, then a gap, then the
  # version. The gap class `[^0-9;,]*` is doing the real work and it is worth being
  # precise about why, because the obvious `[^0-9]*` is NOT enough: "verified the
  # retirement; separately, the box runs 0.19.1" has no digits between the verb and
  # the version, so a digit-only gap matches it and attributes a claim to a sentence
  # that never made one. Excluding `;` and `,` means the gap cannot cross into the
  # next clause, which is where an unrelated version lives. Measured both ways.
  # The pattern lives in a VARIABLE, not inline: an unquoted `;` inside `[[ =~ ]]`
  # terminates the command and bash reports a syntax error at parse time, so the
  # class that makes this fence work cannot be written inline at all.
  local _re='(VERIFIED|Verified|verified|TESTED|Tested|tested|CONFIRMED|Confirmed|confirmed|VALIDATED|Validated|validated|SMOKED|Smoked|smoked|REPRODUCED|Reproduced|reproduced)[^0-9;,]*[vV]?([0-9]+\.[0-9]+\.[0-9]+)'
  while IFS= read -r line; do
    [[ "$line" =~ $_re ]] && ver="${BASH_REMATCH[2]}"
  done <<<"$txt"
  printf '%s' "$ver"
}

# DIVE-2835: _gate_installed_cli — the DEPLOYED artifact, as `<path>|<version>`.
#
# The point of the whole check is that a version STRING is not evidence (DIVE-2819),
# so this resolves a FILE and asks that file what it reports, rather than trusting
# `$FIVE_VERSION` of whatever bundle happens to be executing — which on a maker's
# worktree is not what the control plane runs. `/usr/local/bin/5dive` first because
# that is the path cron and every agent execute (the same path
# `_gate_merged_not_deployed` names); `command -v` only as a fallback for a box that
# installed elsewhere. Empty means the artifact could not be read, which the caller
# must report as NOT CHECKED rather than as agreement.
_gate_installed_cli() {
  local p v
  for p in /usr/local/bin/5dive "$(command -v 5dive 2>/dev/null)"; do
    [[ -n "$p" && -f "$p" && -x "$p" ]] || continue
    v=$("$p" --version 2>/dev/null | head -1 | awk '{print $2}')
    [[ -n "$v" ]] || continue
    printf '%s|%s' "$p" "$v"; return 0
  done
  return 1
}

# DIVE-2835: _gate_version_vs_installed <ident> <verb> <result-text>
#
# Converts a discipline into machinery. DIVE-2762 closed "verified on v0.19.2" onto a
# host running 0.19.1; DIVE-2819's pass then turned on a human REMEMBERING to grep the
# installed artifact. This runs that comparison at the only moment the closer can act
# on it, and it always points at the FILE.
#
# WARN, never refuse, and that is not timidity: the guard cannot know WHICH artifact a
# version names. "verified on v2.1.0" may be a plugin, the api, or a dependency, and a
# refusal would be a confident claim about something this code did not identify. So it
# reports the comparison and names its own scope, which is the honest shape for a check
# whose subject is inferred rather than declared.
#
# Direction matters and is reported separately. Installed OLDER than claimed is the
# DIVE-2762 shape — the artifact carrying the fix is not the artifact running here, and
# the board is about to read fixed. Installed NEWER is ordinarily fine (it shipped, and
# more shipped after), so it gets a note rather than the loud line.
_gate_version_vs_installed() {
  local ident="${1:-}" verb="${2:-}" txt="${3:-}"
  local claimed; claimed=$(_gate_version_claim "$txt")
  [[ -n "$claimed" ]] || return 0
  local inst ipath iver
  if ! inst=$(_gate_installed_cli); then
    warn "$ident: this $verb states it verified on v$claimed, but the INSTALLED 5dive artifact could not be read (tried /usr/local/bin/5dive and \$PATH) — the deployed-vs-claimed comparison did NOT run (DIVE-2835). That is 'not checked', not 'agreed'."
    return 0
  fi
  ipath="${inst%%|*}"; iver="${inst##*|}"
  if [[ "$iver" == 0.0.0* || "$iver" == *-dev* ]]; then
    warn "$ident: this $verb states it verified on v$claimed; $ipath reports '$iver', a dev build whose ordering against a release is meaningless, so no comparison was made (DIVE-2835). Grep the artifact for the change itself — the version string was never the evidence."
    return 0
  fi
  if [[ "$iver" == "$claimed" ]]; then
    step "$ident: verified-on v$claimed matches the installed artifact ($ipath reports $iver) — the claim describes what this host actually runs (DIVE-2835)."
    return 0
  fi
  local older; older=$(printf '%s\n%s\n' "$claimed" "$iver" | sort -V | head -1)
  if [[ "$older" == "$iver" ]]; then
    warn "$ident: DEPLOYED-VS-CLAIMED MISMATCH — this $verb states it verified on v$claimed, but $ipath reports $iver, which is OLDER (DIVE-2835). The board is about to read this as fixed while the artifact every agent and cron actually executes does not carry it: that is exactly DIVE-2762, which stayed live for a day under a verifier's signature. Confirm against the FILE, not the version string — grep $ipath for the change — and if the rollout has not happened, this row is a rollout row, not a done one."
  else
    warn "$ident: this $verb states it verified on v$claimed; $ipath reports $iver, which is NEWER (DIVE-2835). Usually fine — it shipped and more shipped after — but the claim describes an artifact nobody is running now, so grep $ipath if the behaviour still matters."
  fi
}

# DIVE-2656 PART 1: _gate_pr_shas <ref> <tok> — the two shas a merged PR can be
# legitimately said to carry, as `<headRefOid>|<mergeCommit.oid>`.
#
# BOTH, on purpose. A verifier who graded the BRANCH states its head; one who
# graded the LANDED result states the merge commit. Accepting only the first
# would false-REFUSE the second, and a false refuse blocks every close while a
# false green closes one row wrongly (community/wiki/a-stored-graded-sha-cannot-
# survive-a-squash-merge.md). Note what is NOT asked here: ancestry. Under
# squash the branch head is never an ancestor of main, so ancestry against a
# stored sha false-REDs 100% of rows — this is an EQUALITY test between the sha
# the verifier named and the sha the PR actually carried, which squash does not
# touch. GitHub keeps headRefOid on a merged PR even after the branch is deleted.
#
# Prints EMPTY (or `|`) when the query could not be reached; the caller renders
# that as NOT CHECKED, never as a mismatch.
_gate_pr_shas() {
  local ref="$1" tok="$2" slug="${3:-}"
  local -a repo_arg=()
  [[ "$ref" =~ ^[0-9]+$ ]] && repo_arg=(--repo "$slug")
  _gate_gh "$tok" 10 pr view "$ref" "${repo_arg[@]}" \
      --json headRefOid,mergeCommit \
      -q '[(.headRefOid // ""), (.mergeCommit.oid // "")] | join("|")' \
      2>/dev/null || true
}

# DIVE-2101: _gate_branch_ancestry <slug> <branch> <tok> — is <branch>'s tip an
# ANCESTOR of that repo's main? Prints "1" (yes: every commit on the branch is
# already on main), "0" (demonstrably not) or EMPTY when the question could not be
# REACHED — no token, no network, gh absent, repo/branch gone, unparseable answer.
#
# Empty is not "no", and the caller must never read it as one: it falls through to
# the merged-PR path exactly as if this check did not exist, so an outage can only
# ever cost the NEW acceptance, never manufacture a refusal that DIVE-1830 did not
# already make.
#
# Asked over the API rather than a local `git merge-base --is-ancestor` on purpose:
# `task done` runs from any cwd (and from root/cron), so there is no checkout to
# trust — the same reason the merged-PR probe next to it passes --repo explicitly
# (DIVE-1834). `compare/main...branch` answers the ancestry question directly:
# ahead_by is the count of commits the branch has that main does not, so ahead_by==0
# (status `identical` or `behind`) IS "the tip is an ancestor". Both are required
# together so a shape-changed payload reads as unresolved, not as a pass.
# Read-only, bounded by `timeout`, token passed via env and never in argv.
_gate_branch_ancestry() {
  local slug="$1" branch="$2" tok="$3" out st ahead
  out=$(_gate_gh "$tok" 10 api \
        "repos/${slug}/compare/${FIVE_GATE_MAIN_BRANCH:-main}...${branch}" \
        -q '[(.status // ""), ((.ahead_by // "") | tostring)] | join("|")' 2>/dev/null || true)
  out="${out%%$'\n'*}"
  st="${out%%|*}"; ahead="${out##*|}"
  if [[ -z "$st" || "$out" != *"|"* ]]; then printf ''; return 0; fi
  if [[ "$ahead" == "0" && ( "$st" == "identical" || "$st" == "behind" ) ]]; then
    printf '1'; return 0
  fi
  printf '0'
}

# DIVE-2101 (main's vacuity arm, before merge): ancestry ALONE is trivially true
# for a branch with ZERO commits — its tip IS a commit on main — so a task bound to
# a branch nobody ever committed to would satisfy done=merged-to-main having
# delivered NOTHING. That is the mirror of the unmerged case: "commits that did not
# land" and "no commits at all" are different shapes, and only the first is covered
# by refusing a branch that is ahead of main. Ancestry answers "is this tip on
# main", never "did this task put anything there", and no amount of ancestry
# arithmetic separates them (merge-base(tip,main)==tip in BOTH).
#
# So ATTRIBUTION is asked separately: does any commit reachable from the branch tip
# name <ident> at word boundaries? Same evidence idiom `_gate_pr_probe` already uses
# to bind a bare #N (title/head-branch naming the ident) — here against commit
# messages, which is this repo's standing convention. Because the tip is already
# established as an ancestor of main, every commit it reaches IS on main, so a hit
# means "work for this task is on main" measured on the commits themselves.
# Deliberately NOT solved by recording a base SHA at `set-branch` time: that reads
# only for bindings made after it ships, and the live casualties (DIVE-2051, and
# this ticket's own binding) are already bound — an anti-vacuity arm that cannot
# see the vacuum it was written for is theatre.
#
# Prints "1" (attributable), "0" (nothing on the branch names the ident) or EMPTY
# when unreachable. Empty and "0" both DECLINE the ancestry acceptance and fall
# through to the merged-PR search — this arm can only ever subtract an acceptance,
# never add a refusal that DIVE-1830 did not already make. Read-only, bounded.
_gate_branch_ident_on_main() {
  # DIVE-2120: search MAIN, never the branch ref.
  #
  # The DIVE-2101 arms both queried the GitHub API BY BRANCH NAME
  # (compare/main...<branch>, commits?sha=<branch>). Measured: against a ref absent
  # from the remote both 404, so a MERGED-AND-DELETED branch returns byte-identical
  # results to one that NEVER EXISTED — and deleting the branch on merge is routine
  # hygiene we perform by default (four branches deleted the night DIVE-2101 shipped).
  # The task then became permanently un-closeable on this path, and the refusal told
  # the reader to "land the branch", which is wrong advice for work already on main.
  #
  # Searching main directly removes the dependency instead of repairing it, and it
  # makes the VACUITY case structurally impossible rather than separately guarded: an
  # empty branch contributes no commit naming the ident TO MAIN, so there is nothing
  # to mistake for delivery. It also works retroactively on every existing binding.
  #
  # Returns: 1 = a commit on main names the ident
  #          0 = genuine miss (main's history was EXHAUSTED within the bound)
  # bound:<walked> = not found, and the scan STOPPED AT ITS BOUND after walking
  #                  <walked> commits — inconclusive, not a miss. The number is the
  #                  count actually WALKED, never the configured one: reporting the
  #                  request as if it were the measurement is the whole bug below.
  #         "" = unreachable (no token, API down, timeout)
  local slug="$1" tok="$3" ident="$4" main_br n per page walked out hits count
  main_br="${FIVE_GATE_MAIN_BRANCH:-main}"
  # DIVE-1935, 2026-08-11: default raised 50 -> 250 ON FRICTION GROUNDS ONLY, and the
  # distinction is the whole reason this comment exists. THERE ARE ZERO STUCK ROWS:
  # of 37 rows refused in 24h, 30 closed and 5 were cancelled. Nobody should read this
  # as unblocking a backlog and go looking for movement in a number that was never
  # moving.
  #
  # What it buys is RETRIES. The refusal is inconclusive-by-construction — it walks the
  # bound per repo across 8 repos and gives up — so a caller below the bound pays for it
  # in attempts, not in a permanent block: DIVE-2093 burned 2, and quinn's DIVE-3184,
  # DIVE-3229 and DIVE-3230 burned 3 each. On a day where main takes 20+ commits, 50 is
  # simply too short to answer the question the scan was asked.
  #
  # `FIVE_GATE_ANCESTRY_SCAN` stays as the override, and stays deliberately: the bound
  # exists so the walk terminates, and a raised default is not a reason to remove the
  # knob that makes it tunable in either direction.
  n="${FIVE_GATE_ANCESTRY_SCAN:-250}"
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || n=250
  # SUBJECT LINE ONLY, not the whole message. Searching main widened the attribution
  # set: every commit reachable from a branch tip is on main, but not every commit on
  # main is reachable from that tip — so a whole-message match accepts INCIDENTAL
  # mentions. Measured while building this: DIVE-2112 matched inside a 2-commit bound
  # because the 0.16.20 RELEASE commit's body happens to name it. That commit delivered
  # nothing for DIVE-2112. Our delivery commits put the ident in the SUBJECT
  # ("task: ... (DIVE-2112)"); prose references live in the body. Matching the subject
  # keeps the branch-deletion immunity without paying for it in a looser bar.
  #
  # PAGINATED, and that is not an optimisation — it is the correctness fix.
  # The first cut asked for per_page=$n in ONE call and inferred "history EXHAUSTED"
  # from a short page. GitHub CLAMPS per_page at 100 (measured by olivia against the
  # live API: 50->50 rows, 100->100, 200->100, 500->100), so at any n>100 the page
  # came back short for a reason that has nothing to do with history running out: the
  # scan saw 100 of main's 1000+ commits and returned "genuine miss". That fell
  # through to the generic refusal telling the reader to LAND THE BRANCH — the exact
  # wrong advice this ticket exists to kill — and the bound refusal's only documented
  # remedy ("raise FIVE_GATE_ANCESTRY_SCAN") was the single input that triggered it.
  # The remedy was worse than the disease.
  #
  # So: never request more than the clamp, and walk pages until the ident is found,
  # history genuinely runs out, or n commits have actually been walked. The clamp was
  # the only known cause of a short page that is not exhaustion, and asking for at
  # most 100 removes it — a short page now means what the code says it means. This is
  # also what makes the refusal's advice TRUE: raising the bound past 100 now walks
  # further instead of silently converting an honest INCONCLUSIVE into a false miss.
  walked=0; page=1
  while (( walked < n )); do
    per=$(( n - walked )); (( per > 100 )) && per=100
    out=$(_gate_gh "$tok" 10 api \
          "repos/${slug}/commits?sha=${main_br}&per_page=${per}&page=${page}" \
          -q "[ .[] | ((.commit.message // \"\") | split(\"\\n\")[0]) ] | [length, ([ .[]
               | select(test(\"(^|[^A-Za-z0-9])${ident}([^A-Za-z0-9]|\$)\";\"i\")) ] | length)] | @tsv" \
          2>/dev/null || true)
    out="${out%%$'\n'*}"
    count="${out%%$'\t'*}"; hits="${out##*$'\t'}"
    [[ "$count" =~ ^[0-9]+$ && "$hits" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
    [[ "$hits" -gt 0 ]] && { printf '1'; return 0; }
    walked=$(( walked + count ))
    # A page SHORTER than the one asked for is the only honest evidence that main's
    # history ran out inside the window, and it is honest evidence only because we
    # never asked for more than the API will give.
    (( count < per )) && { printf '0'; return 0; }
    page=$(( page + 1 ))
  done
  # Stopped counting; did not run out. Report what was WALKED, not what was asked for.
  printf 'bound:%s' "$walked"
}
