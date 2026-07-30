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

_gh_usage() {
  cat >&2 <<'EOF'
5dive gh — run `gh` as the right identity (DIVE-2448)

  5dive gh <gh args...>              Route by operation: writes go out as the
                                     machine account, admin + read stay on your
                                     own credential. The decision is printed.
  5dive gh --as=bot <gh args...>     Force the machine account (admin-class
                                     operations are still refused: admin=false).
  5dive gh --as=caller <gh args...>  Force your own credential (the pre-2448
                                     behaviour), explicitly and on the record.
  5dive gh --explain <gh args...>    Print the routing decision and run nothing.
  5dive gh whoami                    Resolve BOTH identities (caller and bot).

Why: an agent `gh` write authenticates as the human account, so the audit trail
cannot tell an agent action from a human one (DIVE-2232). Routing writes here
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

  case "$as" in auto|bot|caller) ;; *)
    fail "$E_VALIDATION" "--as must be auto, bot or caller — got '${as}'." ;;
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
        fail "$E_CONFLICT" "refusing --as=bot for an admin-class operation: 5dive-bot is admin=false on every repo (measured DIVE-2444), so this cannot succeed as the bot. Re-run without --as=bot to use your own credential."
      fi
      actor="bot"; reason="you asked for --as=bot" ;;
    auto)
      if [[ "$class" == "write" ]]; then actor="bot"; else actor="caller"; fi ;;
  esac

  if [[ "$actor" == "bot" ]]; then
    echo "[5dive gh] actor=5dive-bot (class=${class}: ${reason})" >&2
  else
    echo "[5dive gh] actor=your own gh credential (class=${class}: ${reason})" >&2
  fi
  [[ $explain -eq 1 ]] && return 0

  if [[ "$actor" == "caller" ]]; then
    gh "$@"
    return $?
  fi

  # Hand off to the root-only helper. Args travel NUL-separated over stdin, never
  # argv, so the NOPASSWD grant stays an exact command path (sudo-rs safe, no arg
  # wildcard) and no argument of a credential-bearing call lands in the process
  # table. The helper re-derives the class and reads the token itself.
  local rc=0
  printf '%s\0' "$@" | sudo -n /usr/local/bin/5dive _gh_do || rc=$?
  if [[ $rc -eq 127 ]]; then
    fail "$E_GENERIC" "routing to 5dive-bot needs the NOPASSWD grant for '/usr/local/bin/5dive _gh_do', which this account does not have. A builder agent gets it with 'agent create --can-push'; meanwhile re-run with --as=caller (the write will be recorded as the human account)."
  fi
  return $rc
}

# cmd_gh_whoami — resolve BOTH identities and print them. The point of the verb
# is that "which account did that write go out as" stops being something you
# infer from a config file and becomes something you can measure in one call.
cmd_gh_whoami() {
  local caller bot
  caller=$(gh api user --jq .login 2>/dev/null || true)
  printf 'caller : %s\n' "${caller:-UNRESOLVED (no gh credential in this environment)}"
  bot=$(printf '%s\0' api user --jq .login | sudo -n /usr/local/bin/5dive _gh_do 2>/dev/null || true)
  printf 'bot    : %s\n' "${bot:-UNRESOLVED (no _gh_do grant here, or the github-bot connector is not provisioned)}"
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

  # Re-derive rather than accept: the caller told us nothing we are willing to
  # trust about what it is asking the bot to do (the _push_do posture).
  local class
  class=$(_gh_route_class "${args[@]}")
  [[ "$class" == "admin" ]] && fail "$E_CONFLICT" "_gh_do refuses an admin-class operation: 5dive-bot is admin=false on every repo, so this cannot succeed as the bot."

  [[ -r "$_GH_BOT_ENV" ]] \
    || fail "$E_GENERIC" "machine-account credential is not provisioned: $_GH_BOT_ENV is missing or unreadable. Provision it with '5dive secret write ${_GH_BOT_KEY} --connector=github-bot'."
  local tok
  # shellcheck disable=SC1090
  tok=$(set -a; . "$_GH_BOT_ENV"; set +a; printf '%s' "${GH_BOT_TOKEN:-}")
  [[ -n "$tok" ]] || fail "$E_GENERIC" "$_GH_BOT_ENV exists but carries no ${_GH_BOT_KEY}."

  # GITHUB_TOKEN is cleared so a stale one in root's environment cannot win over
  # the token we just resolved — gh prefers GH_TOKEN, but a reader six months out
  # should not have to know that to believe this line.
  GH_TOKEN="$tok" GITHUB_TOKEN="" gh "${args[@]}"
}
