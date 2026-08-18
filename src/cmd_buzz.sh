#!/usr/bin/env bash
# DIVE-3592 — `5dive buzz pair`: ONE QR per SERVER.
#
# lodar hit the dashboard's "Which agent should your phone pair with?" and
# rejected the shape: "isnt qr one per server?" — yes, and it is also the
# recorded design (DIVE-3510). The phone pairs once, at box level, as the
# OWNER's identity. Whether a given agent talks in team chat is a different
# question with its own verb (`agent buzz enable <name>`), and it is not asked
# at pairing time.
#
# The per-agent picker existed because the owner key was minted per agent.
# `_buzz_owner_key` (DIVE-3592, src/cmd_agent_buzz_join.sh) makes that key
# server-level, so `agent buzz pair <name>` and this verb now hand the handset
# the SAME identity — the interim per-agent path keeps working and stops being
# a choice that means anything.
#
# WHAT THIS VERB OWNS THAT THE PER-AGENT ONE CANNOT: membership. A handset that
# is not a member of a channel cannot see it at all (DIVE-3331), so pairing at
# box level has to wire the owner key into EVERY buzz agent's channels first —
# and it must do that itself. DIVE-3510's lesson was a hand-added key, and the
# row that files this one recorded the same failure again: a `join` that has to
# be run by hand at a sudo prompt is not a product. So the wire-up runs here,
# and if it leaves the owner in ZERO channels this verb REFUSES to pair rather
# than hand the customer an identity that opens an empty app.
#
# THE MARKER CONTRACT IS THE PANEL'S ONLY SIGNAL (cmd_agent_buzz_pair.sh) and
# it now covers refusals too: a refusal prints `BUZZ-PAIR-RESULT: fail …`
# before it exits non-zero. The panel drives this over a PTY, where the exit
# status it can observe is the SHELL's, not the verb's — so "no markers, no
# error" was indistinguishable from success (measured on lodar's first pairing
# attempts, 2026-08-18: sessions ended in under a second and read as ordinary
# closures). A refusal now says so on the stream.

# cmd: 5dive buzz pair [--timeout=<secs>] [--agent=<name>] [--no-wire]
_buzz_server_pair() {
  local timeout_s="600" host="" wire="true"
  while (($#)); do
    case "$1" in
      --timeout=*) timeout_s="${1#*=}" ;;
      --agent=*)   host="${1#*=}" ;;
      --no-wire)   wire="false" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "unexpected argument: $1 — pairing is per SERVER; there is no agent to name. (Use --agent=<name> only to pin which seat hosts the session.)" ;;
    esac
    shift
  done
  [[ "$timeout_s" =~ ^[0-9]+$ && "$timeout_s" -gt 0 ]] \
    || fail "$E_USAGE" "--timeout wants a positive integer (seconds), got '$timeout_s'"

  ensure_state
  local agents=() a
  while IFS= read -r a; do [[ -n "$a" ]] && agents+=("$a"); done < <(_buzz_enabled_agents)
  ((${#agents[@]} > 0)) || _buzz_pair_refuse "$E_NOT_FOUND" \
    "no agent on this box has buzz enabled, so there is no relay and no room to pair into — run: sudo 5dive agent buzz enable <name> --relay=<https://…>"
  if [[ -n "$host" ]]; then
    local found="no"
    for a in "${agents[@]}"; do [[ "$a" == "$host" ]] && found="yes"; done
    [[ "$found" == "yes" ]] || _buzz_pair_refuse "$E_NOT_FOUND" \
      "--agent='$host' does not have buzz enabled (enabled here: ${agents[*]})"
  fi

  # --- the owner key into every agent's channels ----------------------------
  # `join` is idempotent by construction and it is what adds the owner pubkey as
  # a MEMBER, so running it per agent is both the wire-up and the assertion that
  # the wire-up took. It refuses with `fail`, which exits — hence the subshell.
  local wired=0 unwired=""
  if [[ "$wire" == "true" ]]; then
    step "Wiring the owner identity into every buzz agent's channels (${#agents[@]} agent(s)) — a handset that is not a MEMBER sees an empty app, not a quiet one"
    for a in "${agents[@]}"; do
      if ( with_registry_lock _buzz_join "$a" ) >&2; then
        wired=$((wired + 1))
        [[ -z "$host" ]] && host="$a"
      else
        unwired="${unwired:+$unwired, }$a"
      fi
    done
    ((wired > 0)) || _buzz_pair_refuse "$E_GENERIC" \
      "the owner key is a member of NO channel on this box — pairing now would hand the phone an identity that opens an empty app. The wire-up output above says why (relay, binary, or a write the relay did not read back). Fix it, then re-run."
    if [[ -n "$unwired" ]]; then
      warn "these agents did not wire and the handset will NOT see their channels: $unwired — repair with: sudo 5dive agent buzz join <name>"
    fi
  fi
  [[ -n "$host" ]] || host="${agents[0]}"

  step "One QR, one identity: this pairs the PHONE as the owner of this box, not as an agent. Which agents talk in team chat is 'sudo 5dive agent buzz enable <name>' and is not asked here."
  local rc=0
  _buzz_pair "$host" --timeout="$timeout_s" || rc=$?
  return "$rc"
}

# cmd: 5dive buzz owner [--envelope]
# The box's handset identity. Public half by default; --envelope prints the
# DIVE-3300 payload and is therefore a PRIVATE key on stdout, same rule as the
# per-agent verb it delegates to.
_buzz_server_owner() {
  local envelope=""
  while (($#)); do
    case "$1" in
      --envelope) envelope="--envelope" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "unexpected argument: $1 — the owner identity is per SERVER" ;;
    esac
    shift
  done
  ensure_state
  local a first=""
  while IFS= read -r a; do [[ -n "$a" && -z "$first" ]] && first="$a"; done < <(_buzz_enabled_agents)
  [[ -n "$first" ]] || fail "$E_NOT_FOUND" \
    "no agent on this box has buzz enabled — the envelope's relay comes from an agent's config. Run: sudo 5dive agent buzz enable <name> --relay=<https://…>"
  # The key is server-level; the RELAY still comes from a config, and every
  # buzz agent on a box shares one relay by construction (`enable --relay`).
  if [[ -n "$envelope" ]]; then _buzz_owner "$first" --envelope; else _buzz_owner "$first"; fi
}

# cmd: 5dive buzz <pair|owner>
cmd_buzz() {
  local verb="${1:-}"
  case "$verb" in
    pair)  shift; _buzz_server_pair "$@" ;;
    owner) shift; _buzz_server_owner "$@" ;;
    ""|-h|--help)
      fail "$E_USAGE" "usage: 5dive buzz pair [--timeout=<secs>] [--agent=<name>] [--no-wire]
       5dive buzz owner [--envelope]

Pairing is per SERVER: one QR pairs the phone as the OWNER of this box. Use
'5dive agent buzz enable <name>' to choose which agents talk in team chat." ;;
    *) fail "$E_USAGE" "unknown buzz verb '$verb' (pair|owner)" ;;
  esac
}
