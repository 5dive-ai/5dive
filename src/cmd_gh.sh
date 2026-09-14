# cmd_gh — actor-routed `gh` (DIVE-2448, the last mile of DIVE-2232).
#
# THE PROBLEM THIS EXISTS FOR. Every agent `gh` call on this fleet authenticates
# as the HUMAN account (`gh auth status` -> "Logged in to github.com account
# lodar"), so every merge, comment and review an agent performs is
# indistinguishable from one the human performed. DIVE-2232 measured that across
# three surfaces (PR actor field, org audit log, merge commit) and found no
# surface that discriminates. A machine account (`5dive-bot`) now exists and
# holds push on every shipping repo (DIVE-2444) — but nothing ROUTES to it, so
# acting as the bot means an agent remembering to write `GH_TOKEN=...` by hand.
#
# That is agent DISCIPLINE, which is the exact self-declared shape DIVE-2232
# rejected for attribution markers: an agent that forgets is indistinguishable
# from one that never tried. This verb makes it CONFIGURATION — the routing
# decision is made by the tool, printed on every call, and re-derived
# authoritatively as root.
#
# THE ROUTING RULE, and why it is per-operation rather than per-account:
#   write  -> the BOT.    Attribution is the whole point, and writes are the only
#                         operations that leave an actor field behind.
#   admin  -> the CALLER. Measured 2026-07-30: 5dive-bot is `admin=false` on all
#                         six repos. Branch protection, repo settings, secrets
#                         and collaborator changes (DIVE-2141/2319) would 403 as
#                         the bot, so routing them there breaks a live path.
#   read   -> the CALLER. A read leaves no actor field, so there is nothing to
#                         attribute; and the bot's visibility is NARROWER than
#                         the caller's, so routing reads there would turn a
#                         working query into a 404 for zero benefit.
#
# WHY A WHOLESALE `gh auth switch` IS NOT THE FIX (and cannot be): the PAT is
# unstorable — `gh auth login --with-token` REFUSES it for "missing required
# scope 'read:org'" — so there is no account to switch to. Even with the scope,
# a global flip would trade five broken write paths for a broken ADMIN path,
# because the bot is admin=false everywhere. Per-operation routing is the only
# shape that fixes attribution without breaking a capability.
#
# CREDENTIAL POSTURE — same invariant as delegated push (DIVE-1460): the agent
# process NEVER holds the token. `/etc/5dive/connectors/` is root-only, the
# token is read inside the root-only `_gh_do` helper, passed to gh as an
# environment prefix (never argv, so it cannot leak via ps or the audit log),
# and discarded with the process. `_gh_do` re-derives the routing class itself
# and refuses admin-class calls, so a caller cannot talk the bot into an
# operation this file says it must not perform.
#
# FAIL-SAFE DIRECTION: an operation this file does not RECOGNISE routes to the
# caller — i.e. today's behaviour, unchanged — and SAYS SO on stderr. An
# unrecognised write is then a visible attribution gap someone can close by name,
# not a silent one. The opposite default (route the unknown to the bot) would
# turn every new gh subcommand into a 403 on a path that used to work.

# Connector that holds the machine account's PAT. Not env-overridable: a caller
# must not be able to redirect which credential "the bot" means.
readonly _GH_BOT_ENV="/etc/5dive/connectors/github-bot.env"
readonly _GH_BOT_KEY="GH_BOT_TOKEN"

# DIVE-4334. The ATTESTER credential, and it is deliberately not the bot's.
# `.github/CODEOWNERS` requires a review on /install.sh and /src/cmd_selfupdate.sh
# from a GitHub USER (CODEOWNERS resolves users and teams only — never an App
# identity, which is why 5dive-bot can never be named there), and that user must
# not be the PR author (GitHub 422s a self-approval and 5dive-bot authors every
# installer PR). So the attester is a third login, `5dive-reviewer`, holding write
# and nothing else, and this rail is the ONLY thing on the box that can speak as
# it. Same posture as the bot: root-side, never held by an agent, passed to gh in
# the environment and discarded with the process.
readonly _GH_REVIEWER_ENV="/etc/5dive/connectors/github-reviewer.env"
readonly _GH_REVIEWER_KEY="GH_REVIEWER_TOKEN"

_gh_usage() {
  cat >&2 <<'EOF'
5dive gh — run `gh` as the right identity

  5dive gh <gh args...>              Route by operation: writes go out as the
                                     machine account, admin + read stay on your
                                     own credential. The decision is printed.
  5dive gh --as=bot <gh args...>     Force the machine account (admin-class
                                     operations are still refused: admin=false).
  5dive gh --as=caller <gh args...>  Force your own credential (the pre-2448
                                     behaviour), explicitly and on the record.
  5dive gh --as=reviewer pr review <n> --approve --body "<why>"
                                     Submit the CODEOWNERS attestation as
                                     5dive-reviewer. `pr review` only — this
                                     credential signs, it does not work.
  5dive gh --explain <gh args...>    Print the routing decision and run nothing.
  5dive gh whoami                    Resolve BOTH identities (caller and bot).

Why: an agent `gh` write authenticates as the human account, so the audit trail
cannot tell an agent action from a human one. Routing writes here
makes the actor field mean something again.
EOF
}

# _gh_route_class <gh args...> — the routing class of a gh invocation: one of
# `admin`, `write`, `read`. PURE (no I/O, no root, no network) so it is
# unit-testable without a box and so `_gh_do` can re-derive it authoritatively.
#
# The write map is an ALLOWLIST of verbs whose effect lands in a GitHub actor
# field. It is deliberately explicit rather than "anything not obviously a read":
# a wrong guess in the permissive direction sends an admin operation to a
# credential that cannot perform it, which fails a live path. A wrong guess in
# the restrictive direction only leaves attribution where it already was, and
# the caller is TOLD, which is the recoverable side of the trade.
_gh_route_class() {
  local sub="${1:-}" verb="${2:-}" a
  case "$sub" in
    # Identity state. Never routed: `gh auth` mutates which account the caller's
    # own gh is logged into, and doing that under a borrowed token is how you end
    # up with a shell whose identity nobody can name.
    auth|config) printf 'admin'; return 0 ;;
    # Org/repo administration. The bot is admin=false on every repo (measured
    # 2026-07-30, DIVE-2444), so these must stay on the caller's credential.
    secret|variable|ruleset|ssh-key|gpg-key) printf 'admin'; return 0 ;;
    repo)
      case "$verb" in
        edit|delete|create|archive|rename|deploy-key|set-default) printf 'admin'; return 0 ;;
        sync|fork) printf 'write'; return 0 ;;
        *) printf 'read'; return 0 ;;
      esac ;;
    api)
      # An `api` call is a write only when it names a mutating method; GET is the
      # gh default. The admin PATHS are checked first because an admin path is
      # admin whichever method reaches it.
      for a in "$@"; do
        case "$a" in
          */branches/*/protection|*/branches/*/protection/*|orgs/*|/orgs/*|\
          */collaborators|*/collaborators/*|*/actions/permissions|*/actions/permissions/*|\
          */rulesets|*/rulesets/*|*/hooks|*/hooks/*|*/keys|*/keys/*|*/teams|*/teams/*)
            printf 'admin'; return 0 ;;
        esac
      done
      local prev=""
      for a in "$@"; do
        case "$a" in
          -X|--method) prev="method" ; continue ;;
          -f|-F|--field|--raw-field|--input) printf 'write'; return 0 ;;
          -XPOST|-XPUT|-XPATCH|-XDELETE|--method=POST|--method=PUT|--method=PATCH|--method=DELETE)
            printf 'write'; return 0 ;;
        esac
        if [[ "$prev" == "method" ]]; then
          case "$a" in POST|PUT|PATCH|DELETE|post|put|patch|delete) printf 'write'; return 0 ;; esac
          prev=""
        fi
      done
      printf 'read'; return 0 ;;
    pr)
      case "$verb" in
        create|merge|close|reopen|comment|edit|review|ready|lock|unlock) printf 'write'; return 0 ;;
        *) printf 'read'; return 0 ;;
      esac ;;
    issue)
      case "$verb" in
        create|close|reopen|comment|edit|delete|lock|unlock|pin|unpin|transfer|develop) printf 'write'; return 0 ;;
        *) printf 'read'; return 0 ;;
      esac ;;
    release)
      case "$verb" in
        create|edit|delete|upload|delete-asset) printf 'write'; return 0 ;;
        *) printf 'read'; return 0 ;;
      esac ;;
    workflow)
      case "$verb" in
        run|enable|disable) printf 'write'; return 0 ;;
        *) printf 'read'; return 0 ;;
      esac ;;
    run)
      case "$verb" in
        rerun|cancel|delete) printf 'write'; return 0 ;;
        *) printf 'read'; return 0 ;;
      esac ;;
    label|gist|cache)
      case "$verb" in
        create|edit|delete|clone) printf 'write'; return 0 ;;
        *) printf 'read'; return 0 ;;
      esac ;;
    *) printf 'read'; return 0 ;;
  esac
}

# _gh_route_reason <class> — the one-line WHY that accompanies every decision.
# The reason is part of the output on purpose: a routing tool that only prints
# WHAT it did teaches nobody where the remaining gaps are.
_gh_route_reason() {
  case "$1" in
    write)  printf 'a write leaves an actor field, and that field is the thing DIVE-2232 is about' ;;
    admin)  printf 'admin-class operation and 5dive-bot is admin=false on every repo — as the bot this 403s' ;;
    read)   printf 'a read leaves no actor field to attribute, and the bot sees fewer repos than you do' ;;
    *)      printf 'unclassified' ;;
  esac
}

# _gh_bot_available — 0 when the machine-account connector is present and holds
# the key. Runs as root (the connectors dir is root-only), so the non-root path
# answers "unknown" rather than "absent": a failed read is not an absence.
_gh_bot_available() {
  [[ -r "$_GH_BOT_ENV" ]] || return 1
  grep -q "^${_GH_BOT_KEY}=" "$_GH_BOT_ENV" 2>/dev/null
}

# _gh_reviewer_allowed <gh args...> — 0 for the ONE operation the attester
# credential exists to perform, `gh pr review`. PURE, like `_gh_route_class`, so
# the root helper can re-derive it instead of trusting the parent (the `_gh_do`
# posture) and so it is unit-testable without a box.
#
# WHY AN ALLOWLIST AND NOT A ROUTING CLASS: the attester holds write on the repo,
# so a general passthrough would make it a second machine account and undo the
# attribution DIVE-2448 bought. It is not a credential for doing work; it is a
# credential for signing one. Everything else routes to bot or caller as before.
_gh_reviewer_allowed() {
  [[ "${1:-}" == "pr" && "${2:-}" == "review" ]] && return 0
  # `api user` is the identity read `whoami` needs. It is the authenticated
  # account's OWN record and nothing else, so it grants no reach; without it
  # "which login attests our installer path" would be a config read rather than
  # a measurement, which is the failure class DIVE-3135 is about.
  #
  # AND IT IS ADMITTED AS A READ ONLY. Iteration 1 of this row matched on the
  # sub-command alone, so `api user -X PATCH` and `api user -f name=...` were
  # admitted: a path-but-not-method allowlist does not enforce "an attester
  # signs, it does not work" — `PATCH /user` edits the attester's own account.
  # The read flags are ALLOWLISTED rather than the mutating ones denied,
  # because `gh` grows flags and a deny-list silently admits every one it has
  # not yet heard of (the DIVE-2144 never-requests-anybody shape, one layer
  # down). The only call this rail makes is `api user --jq .login`.
  [[ "${1:-}" == "api" && "${2:-}" == "user" ]] || return 1
  shift 2
  while (($#)); do
    case "$1" in
      --jq|-q|--template|-t) (($# >= 2)) || return 1; shift 2 ;;
      --jq=*|--template=*|-q=*|-t=*)                   shift   ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# _gh_caller_credential — 0 when THIS seat actually holds a gh credential.
# OFFLINE: `gh auth token` resolves GH_TOKEN/GITHUB_TOKEN and the hosts config
# and makes no network call, so asking before we name an identity costs nothing.
# DIVE-3135: the banner used to assert `actor=your own gh credential` on a seat
# that has none — the same defect class as DIVE-3128's `human:<relaying agent>`,
# an identity named before it was resolved.
# DIVE-4341: under a config dir this uid cannot read, gh exits non-zero on the
# config read and this predicate renders it as "you hold no credential".
_gh_caller_credential() { GH_CONFIG_DIR="$(gh_config_dir)" gh auth token >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# DIVE-4494 — THE READ RAIL IS OWNER-AWARE ON ONE SIDE OF THE HOUSE ONLY.
#
# `gh` holds ONE token per host, and on this fleet `hosts.yml` carries the
# 5dive-ai installation's. Against a PERSONAL-account repo (`lodar/5dive-api`,
# `lodar/5dive-frontend` — most of what we ship) that token is LIVE AND BLIND:
# it authenticates, and answers `GraphQL: Could not resolve to a Repository`.
#
# The answer is already on the seat. `/usr/local/sbin/verifier-gh-read-token.sh`
# mints one read-only App installation token PER INSTALLATION into
# `~/.config/5dive/gh-read-tokens.env` as `GH_READ_TOKEN_<OWNER>`, and DIVE-3888
# taught the MERGE GATE to open that file (`_gate_gh`'s escalation). `cmd_gh`
# never learned: two rails, one blind. Measured 2026-09-14 in
# /var/log/5dive-grader.log — the DIVE-4417 parallel grader lane probes a seat
# with `5dive gh pr view <ref> --json state`, so every lodar/* delivery queued as
# "has headroom but cannot read the delivery ref" while a 5dive-ai/* delivery on
# the same tick spawned. The lane worked; the READ did not.
#
# So this reuses DIVE-3888's helpers verbatim (`_gate_owner_from_args`,
# `_gate_owner_read_token`, `_gate_gh_blind_err`) rather than growing a second
# token lookup — one file, one transform, one place to be wrong.
#
# THE CONTRACT, and it is DIVE-3888's, because the safety argument is the same:
#  * READ CLASS ONLY. The token is scoped `contents:read metadata:read
#    pull_requests:read` (DIVE-3888 recorded the 403-on-PATCH positive control),
#    so it cannot carry a write or an admin call, and offering it one would only
#    convert a clear refusal into a 403.
#  * ONLY AFTER A CALL THAT FAILED BLIND. No query that answers today changes
#    path, and no successful call spends an extra request.
#  * CHOSEN BY OWNER, from the repo the query itself names. It can never be
#    pointed at a repo it was not minted for, and an argv that names no owner
#    yields nothing and the old behaviour stands.
#  * FAILS CLOSED. If the file, the variable or the retry is missing, the
#    caller gets the ORIGINAL status and the ORIGINAL stderr, byte for byte.
# It can only convert an unanswered read into an answered one.
# ---------------------------------------------------------------------------

# _gh_owner_read_token <class> <gh args...> — 0 when this seat holds a read-only
# token for the owner this call names, publishing it in `_GH_OWNER_READ_TOK`.
#
# IT RETURNS THE TOKEN IN A VARIABLE, NOT ON STDOUT, and that is deliberate: the
# credential posture in this file is that a token is never printed and never
# reaches argv (DIVE-1460/2448), and `tests/gh_actor_routing_unit.sh` pins it by
# grepping this source for a print of a token. A helper that answered on stdout
# would have made that guard report a leak on a line that was fine — and widening
# a guard to admit your own change is how the next real leak gets through.
_GH_OWNER_READ_TOK=""
_gh_owner_read_token() {
  local class="${1:-}"; shift
  _GH_OWNER_READ_TOK=""
  [[ "$class" == "read" ]] || return 1
  local own cur
  own="$(_gate_owner_from_args "$@" 2>/dev/null || printf '')"
  [[ -n "$own" ]] || return 1
  _GH_OWNER_READ_TOK="$(_gate_owner_read_token "$own" 2>/dev/null)" || { _GH_OWNER_READ_TOK=""; return 1; }
  [[ -n "$_GH_OWNER_READ_TOK" ]] || return 1
  # Retrying with the credential that just said "cannot see" buys nothing and
  # would make the retry note a lie about which rail answered.
  cur="$(GH_CONFIG_DIR="$(gh_config_dir)" gh auth token 2>/dev/null || printf '')"
  if [[ -n "$cur" && "$_GH_OWNER_READ_TOK" == "$cur" ]]; then _GH_OWNER_READ_TOK=""; return 1; fi
  return 0
}

# _gh_run_as_caller <class> <gh args...> — run gh on the caller's own credential,
# with the DIVE-4494 owner-scoped read retry behind it. Returns gh's status.
#
# STDERR IS CAPTURED ONLY ON THE CANDIDATE PATH. Deciding "is this stderr the
# blind one" means reading it, and reading it means not streaming it — which
# would reorder the output of every ordinary `5dive gh` call for a retry that
# almost never applies. So the token is resolved first, and a call with nothing
# to retry with runs exactly as it always has: streamed, untouched.
_gh_run_as_caller() {
  local class="${1:-}"; shift
  local rc=0
  if ! _gh_owner_read_token "$class" "$@"; then
    gh "$@" || rc=$?
    return "$rc"
  fi

  local errf; errf="${TMPDIR:-/tmp}/.5dive-gh-caller-err.$$"
  : >"$errf" 2>/dev/null || true
  gh "$@" 2>"$errf" || rc=$?
  if (( rc != 0 )) && _gate_gh_blind_err "$errf"; then
    local own; own="$(_gate_owner_from_args "$@" 2>/dev/null || printf '')"
    # The SAME transform the minting script uses (`5dive-ai` -> 5DIVE_AI), so the
    # variable this message names is the variable that was actually read.
    local ovar; ovar="GH_READ_TOKEN_$(printf '%s' "$own" | tr 'a-z-' 'A-Z_')"
    local blind; blind="$(head -n1 "$errf" 2>/dev/null || printf '')"
    local rrc=0
    # The primary call failed, so it printed nothing on stdout (gh emits a --json
    # payload only after a successful request) and the retry's output cannot be
    # appended to a partial one — the same reason _gate_gh streams its primary.
    GH_TOKEN="$_GH_OWNER_READ_TOK" GH_CONFIG_DIR="$(gh_config_dir)" gh "$@" || rrc=$?
    if (( rrc == 0 )); then
      echo "[5dive gh] your own credential cannot see this repository (${blind}) — answered instead with this seat's read-only token for '${own}' (${ovar}, minted by root, read-only: DIVE-3888/DIVE-4494)." >&2
      rm -f "$errf" 2>/dev/null || true
      return 0
    fi
    echo "[5dive gh] your own credential cannot see this repository, and this seat's read-only token for '${own}' could not answer either (gh exit ${rrc})." >&2
  fi
  cat "$errf" >&2 2>/dev/null || true
  rm -f "$errf" 2>/dev/null || true
  return "$rc"
}

# _gh_child_exit <rc> — a non-zero from the WRAPPED gh is gh's failure, not ours.
#
# DIVE-3135: without this the silent-exit backstop (lib/output.sh) fires and
# overwrites gh's own message with "5dive gh exited N without reporting a reason.
# This is a bug in the CLI, not a refusal". For a routed passthrough that text is
# false in both halves — gh DID report a reason, and the reason is often a refusal
# (rc 4 = "please run gh auth login"). It is what made issues #526 (rc 1) and #553
# (rc 4) read as unrelated: the sentence a reader needed was printed and then
# talked over. So we claim the report and re-state the status as gh's.
#
# The DIVE-2792 distinction is PRESERVED and in fact sharpened: an internal CLI
# failure still reaches the backstop as class="generic" with the bug text, while a
# wrapped child's non-zero now carries class="passthrough" and says whose status
# it is. A reader can tell them apart on the class alone.
_gh_child_exit() {
  local rc="${1:-0}"
  shift || true
  (( rc == 0 )) && return 0
  mark_reported
  if (( rc == 8 )) && [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
    echo "[5dive gh] checks are still pending (gh exit 8). This is a CI state, not a 5dive failure; poll again or use gh's --watch mode." >&2
    if (( ${JSON_MODE:-0} )); then
      jq -cn \
        --arg m "Checks are still pending (gh exit 8). This is a CI state, not a 5dive failure." \
        '{ok:false, error:{code:8, class:"pending", message:$m}}' 2>/dev/null || true
    fi
    return "$rc"
  fi
  echo "[5dive gh] gh exited ${rc} — that is gh's OWN exit status, not a 5dive failure. Its message is above; 5dive routed the call and ran it to completion." >&2
  if (( ${JSON_MODE:-0} )); then
    jq -cn --argjson c "$rc" \
      --arg m "gh exited ${rc}. This is the wrapped gh's own exit status, passed through verbatim — 5dive routed the call and did not itself fail. Read gh's stderr for the reason." \
      '{ok:false, error:{code:$c, class:"passthrough", message:$m}}' 2>/dev/null || true
  fi
  return 0
}

# cmd_gh — the user-facing verb.
cmd_gh() {
  local as="auto" explain=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as=*)    as="${1#--as=}"; shift ;;
      --explain) explain=1; shift ;;
      -h|--help) _gh_usage; return 0 ;;
      whoami)    shift; cmd_gh_whoami "$@"; return $? ;;
      *) break ;;
    esac
  done

  case "$as" in auto|bot|caller|reviewer) ;; *)
    fail "$E_VALIDATION" "--as must be auto, bot, caller or reviewer — got '${as}'." ;;
  esac
  [[ $# -gt 0 ]] || { _gh_usage; return 2; }
  command -v gh >/dev/null 2>&1 \
    || fail "$E_GENERIC" "gh is not installed on this box — 5dive gh only routes credentials, it does not replace the tool."

  local class actor reason
  class=$(_gh_route_class "$@")
  reason=$(_gh_route_reason "$class")

  case "$as" in
    caller) actor="caller"; reason="you asked for --as=caller" ;;
    bot)
      # An explicit --as=bot cannot buy an admin operation: the bot genuinely
      # cannot perform one, so honouring the flag here would trade a clear
      # refusal for a 403 the caller has to decode.
      if [[ "$class" == "admin" ]]; then
        fail "$E_CONFLICT" "refusing --as=bot for an admin-class operation: 5dive-bot is admin=false — re-run without --as=bot"
      fi
      actor="bot"; reason="you asked for --as=bot" ;;
    reviewer)
      # Never auto-routed: nothing INFERS that a call should be signed by the
      # attester. It is asked for, by name, or it does not happen.
      _gh_reviewer_allowed "$@" \
        || fail "$E_CONFLICT" "--as=reviewer carries the CODEOWNERS attester credential and serves 'pr review' (and 'api user') only — got '${1:-}${2:+ $2}'. Use --as=bot for writes and --as=caller for admin-class work."
      actor="reviewer"; reason="you asked for --as=reviewer: the CODEOWNERS attestation on the installer paths (DIVE-4334)" ;;
    auto)
      if [[ "$class" == "write" ]]; then
        actor="bot"
      elif [[ "$class" != "admin" ]] && ! _gh_caller_credential; then
        # DIVE-2296: a maker with NO credential is the case `read -> caller` was
        # never written for. The preference behind that arm ("the bot sees fewer
        # repos than you do") is a PREFERENCE, not a safety property, and it is
        # strictly worse than nothing when the caller holds nothing: routing to a
        # credential that does not exist produces a gh auth refusal, and the maker
        # reads that as "reads are closed to me" and falls back to asking another
        # agent — the five-round-trip shape this ticket measured.
        #
        # This grants NO new authority. class=admin is excluded above (the bot is
        # admin=false and an explicit --as=bot is refused for it two arms up), the
        # very same token is already reachable by typing --as=bot by hand, and the
        # bot's read visibility is a SUBSET of an authed caller's. The only thing
        # that changes is that a seat with nothing to route to gets an answer
        # instead of an error.
        actor="bot"; reason="this class normally routes to you, but you hold NO gh credential on this seat, so it routes to the bot rather than refusing a read you are allowed to make (DIVE-2296)"
      else
        actor="caller"
      fi ;;
  esac

  if [[ "$actor" == "reviewer" ]]; then
    echo "[5dive gh] actor=5dive-reviewer (class=${class}: ${reason})" >&2
  elif [[ "$actor" == "bot" ]]; then
    echo "[5dive gh] actor=5dive-bot (class=${class}: ${reason})" >&2
  elif _gh_caller_credential; then
    echo "[5dive gh] actor=your own gh credential (class=${class}: ${reason})" >&2
  else
    # Resolve FIRST, then name what was resolved. Saying "your own gh credential"
    # on a seat that holds none sends the reader looking for a routing bug when
    # the answer is that there is nothing to route to (DIVE-3135).
    # DIVE-2296: the old text qualified the escape hatch as "--as=bot if this is a
    # WRITE", which steered a credential-less maker AWAY from the one path that
    # answers a read. --as=bot serves reads too; only admin-class work genuinely
    # cannot go that way. With the auto-route above, reaching this line at all now
    # means class=admin or an explicit --as=caller.
    echo "[5dive gh] actor=your own gh credential — but NONE IS RESOLVED on this seat, so gh will refuse to authenticate (class=${class}: ${reason}). Provision one, or use --as=bot — that works for READS as well as writes, and is refused only for admin-class operations, which 5dive-bot genuinely cannot perform." >&2
  fi
  [[ $explain -eq 1 ]] && return 0

  local rc=0
  if [[ "$actor" == "caller" ]]; then
    _gh_run_as_caller "$class" "$@" || rc=$?
    _gh_child_exit "$rc" "$@"
    return "$rc"
  fi

  # Hand off to the root-only helper. Args travel NUL-separated over stdin, never
  # argv, so the NOPASSWD grant stays an exact command path (sudo-rs safe, no arg
  # wildcard) and no argument of a credential-bearing call lands in the process
  # table. The helper re-derives the class and reads the token itself.
  # The identity travels as a leading NUL-separated sentinel rather than as a new
  # verb, because the NOPASSWD grant names `/usr/local/bin/5dive _gh_do` exactly —
  # a second root entry point would need a sudoers change on every box, which is a
  # fleet privilege change and not something a CLI release can carry.
  if [[ "$actor" == "reviewer" ]]; then
    { printf '%s\0' --identity=reviewer; printf '%s\0' "$@"; } | sudo -n /usr/local/bin/5dive _gh_do || rc=$?
  else
    printf '%s\0' "$@" | sudo -n /usr/local/bin/5dive _gh_do || rc=$?
  fi
  # Distinguish "you may not route" from "the routed call failed". sudo exits 1
  # for a missing grant, which is indistinguishable from gh's own 1 by rc alone —
  # so ask sudo directly, and only after a failure (the probe costs nothing on the
  # happy path). `sudo -n -l <cmd>` is 0 exactly when this account may run it.
  if [[ $rc -ne 0 ]] && ! sudo -n -l /usr/local/bin/5dive _gh_do >/dev/null 2>&1; then
    fail "$E_GENERIC" "routing to 5dive-bot needs a NOPASSWD grant this account lacks, so nothing ran — re-run with --as=caller"
  fi
  # Past the grant probe, a non-zero came from the routed gh (or from _gh_do's own
  # refusal, which printed its reason in that process) — either way it is reported.
  _gh_child_exit "$rc" "$@"
  return "$rc"
}

# cmd_gh_whoami — resolve BOTH identities and print them. The point of the verb
# is that "which account did that write go out as" stops being something you
# infer from a config file and becomes something you can measure in one call.
cmd_gh_whoami() {
  local caller bot
  caller=$(GH_CONFIG_DIR="$(gh_config_dir)" gh api user --jq .login 2>/dev/null || true)
  printf 'caller : %s\n' "${caller:-UNRESOLVED (no gh credential in this environment)}"
  bot=$(printf '%s\0' api user --jq .login | sudo -n /usr/local/bin/5dive _gh_do 2>/dev/null || true)
  # Three causes, and naming only the first two would send a reader hunting a
  # grant that is fine: `_gh_do` is reached through the INSTALLED /usr/local/bin/5dive,
  # so a box that has not rolled this version yet resolves UNRESOLVED with
  # everything else correct.
  printf 'bot    : %s\n' "${bot:-UNRESOLVED (the installed 5dive predates this verb, this account has no _gh_do grant, or the github-bot connector is not provisioned)}"
  # The attester is resolved through the SAME allowlisted rail, so this line is a
  # live check that the credential exists and authenticates as a USER — not a
  # config read. A CODEOWNERS entry is satisfiable only by a user identity, so an
  # App token here would resolve empty and say so rather than look fine.
  local reviewer
  reviewer=$({ printf '%s\0' --identity=reviewer; printf '%s\0' api user --jq .login; } \
    | sudo -n /usr/local/bin/5dive _gh_do 2>/dev/null || true)
  printf 'reviewer: %s\n' "${reviewer:-UNRESOLVED (the installed 5dive predates this verb, this account has no _gh_do grant, or the github-reviewer connector is not provisioned)}"
  if [[ -n "$reviewer" && -n "$bot" && "$reviewer" == "$bot" ]]; then
    warn "reviewer and bot resolve to the SAME login (${reviewer}) — the attester would be the PR author, and GitHub refuses a self-approval, so the CODEOWNERS gate on the installer paths is unclearable on this box."
  fi
  if [[ -n "$caller" && -n "$bot" && "$caller" == "$bot" ]]; then
    warn "caller and bot resolve to the SAME login (${caller}) — routing would change nothing, so attribution is not fixed on this box."
  fi
}

# cmd_gh_do — ROOT-ONLY. Reads the gh argv NUL-separated on STDIN, re-derives the
# routing class AUTHORITATIVELY (never trusts the caller), reads the machine
# account's PAT from the root-only connector, and execs gh with the token as an
# environment prefix. Prints only gh's own output — never the token. Not
# advertised; the parent `gh` verb is what gets audited.
cmd_gh_do() {
  [[ "$(id -u)" == "0" ]] || fail "$E_GENERIC" "_gh_do is root-only."
  local -a args=()
  local a
  while IFS= read -r -d '' a; do args+=("$a"); done
  [[ ${#args[@]} -gt 0 ]] || fail "$E_VALIDATION" "_gh_do got no arguments on stdin."

  # DIVE-4334: an optional LEADING sentinel selects the attester credential. It is
  # honoured in first position only and stripped before anything else looks at the
  # argv, so it can never reach gh. A caller who types it by hand buys nothing the
  # flag does not already give them: the allowlist below is re-derived here, so the
  # widest thing this sentinel can unlock is `gh pr review` as 5dive-reviewer,
  # which is the whole purpose of the credential.
  local identity="bot"
  if [[ "${args[0]}" == "--identity=reviewer" ]]; then
    identity="reviewer"
    args=("${args[@]:1}")
    [[ ${#args[@]} -gt 0 ]] || fail "$E_VALIDATION" "_gh_do got an identity and no arguments."
  fi

  local env_file key tok
  if [[ "$identity" == "reviewer" ]]; then
    # Re-derive rather than accept, exactly as the bot arm does below.
    _gh_reviewer_allowed "${args[@]}" \
      || fail "$E_CONFLICT" "_gh_do refuses '${args[0]}' as 5dive-reviewer: the attester credential serves 'pr review' (and 'api user') only."
    env_file="$_GH_REVIEWER_ENV"; key="$_GH_REVIEWER_KEY"
    [[ -r "$env_file" ]] \
      || fail "$E_GENERIC" "attester credential missing ($env_file) — 5dive secret write ${key} --connector=github-reviewer"
    # shellcheck disable=SC1090
    tok=$(set -a; . "$env_file"; set +a; printf '%s' "${GH_REVIEWER_TOKEN:-}")
  else
    # Re-derive rather than accept: the caller told us nothing we are willing to
    # trust about what it is asking the bot to do (the _push_do posture).
    local class
    class=$(_gh_route_class "${args[@]}")
    [[ "$class" == "admin" ]] && fail "$E_CONFLICT" "_gh_do refuses an admin-class operation: 5dive-bot is admin=false on every repo, so this cannot succeed as the bot."

    env_file="$_GH_BOT_ENV"; key="$_GH_BOT_KEY"
    [[ -r "$env_file" ]] \
      || fail "$E_GENERIC" "machine-account credential missing ($env_file) — 5dive secret write ${key} --connector=github-bot"
    # shellcheck disable=SC1090
    tok=$(set -a; . "$env_file"; set +a; printf '%s' "${GH_BOT_TOKEN:-}")
  fi
  [[ -n "$tok" ]] || fail "$E_GENERIC" "$env_file exists but carries no ${key}."

  # GITHUB_TOKEN is cleared so a stale one in root's environment cannot win over
  # the token we just resolved — gh prefers GH_TOKEN, but a reader six months out
  # should not have to know that to believe this line.
  # Capture the wrapped child's status HERE, before this helper's own EXIT trap
  # can misclassify it as an unexplained 5dive death. The user-facing parent
  # preserves the status and explains pending vs failure; this marker only says
  # the root helper did run gh and therefore must not emit the silent-exit bug
  # report on top of gh's own output.
  local rc=0
  GH_TOKEN="$tok" GITHUB_TOKEN="" GH_CONFIG_DIR="$(gh_config_dir)" gh "${args[@]}" || rc=$?
  (( rc != 0 )) && mark_reported
  return "$rc"
}
