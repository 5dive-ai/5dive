#!/usr/bin/env bash
# DIVE-3551 — the NIP-AB pairing session, as a CLI verb.
#
# The dashboard's Connect Buzz panel needs to run a pairing session: show a
# nostrpair:// QR, let the human compare the SAS on both ends, and report
# whether the handset imported the identity. That session is a live socket with
# an interactive step, and it must be THE SAME code path an OSS self-hoster
# runs in a terminal, or the two drift (the DIVE-3509 rule: CLI first, panel on
# top). So the panel drives THIS verb over the existing PTY shell session and
# parses the BUZZ-PAIR-* marker lines below; a human in a terminal reads the
# same lines as prose.
#
# THE MARKER LINES ARE A CONTRACT (the panel regexes them from a PTY stream):
#   BUZZ-PAIR-QR: nostrpair://…      render this as a QR for the handset camera
#   BUZZ-PAIR-SAS: <code>            show it; ask "does the phone show this?"
#   BUZZ-PAIR-RESULT: ok             the handset imported the identity
#   BUZZ-PAIR-RESULT: fail <why>     it did not (mismatch/timeout/relay/…)
# One marker per line, always at line start. Grep-stable: tests/buzz_pair_unit.sh
# grades every one of them against a stub buzz-pair.
#
# TWO RELAY URLS, TWO SCHEMES, BY DESIGN (do not "fix" one into the other):
#   --relay          the pairing rendezvous. qr.rs's DECODER accepts wss/ws
#                    ONLY, while our config stores https:// — and encode_qr
#                    percent-encodes whatever it is handed, so an untranslated
#                    URL mints a QR that renders fine everywhere we can see and
#                    is refused by the handset when it decodes. Translated here,
#                    scheme swap only (community/wiki/the-pairing-rendezvous-is-
#                    the-customers-own-relay-and-its-scheme-is-the-trap.md).
#   --envelope-relay the Buzz app's join URL inside the transferred envelope.
#                    Release builds of the app REFUSE non-https here. VERBATIM.
# The customer's own relay is the rendezvous — buzz IS a nostr relay and the
# pairing session authenticates with its own ephemeral keys, so no extra
# infrastructure and no third party sees the (already NIP-44-encrypted) leg.
#
# THE KEY TRAVELS ON STDIN, NEVER ON ARGV — same rule as _buzz_write_config and
# _buzz_cli, same measured reason (/proc/<pid>/cmdline is world-readable, no
# hidepid on our boxes). The shipped buzz-pair at cli-v0.1.0 only takes the
# nsec as an argv element, so this verb REFUSES to run against it and names the
# fix, rather than leaking the customer's handset key for the width of a
# pairing session. cli-v0.1.1's `--nsec -` reads it from the first stdin line.

# The user the session runs as. In production this is the agent user; a
# harness overrides it to its own name so every sudo hop collapses (the same
# convention _buzz_write_config documents — the DIVE-3096 isolation layer
# refuses sudo inside harnesses, so a seam is the only honest way to grade the
# full verb path).
_buzz_pair_user() { printf 'agent-%s\n' "$1"; }

# Where the `buzz-pair` binary is, or empty. Same search discipline as
# _buzz_resolve_binary: the agent's own PATH view first, then the two control
# plane locations. Never invented.
_buzz_resolve_pair_binary() {
  local user="$1" p
  p=$(sudo -u "$user" -H bash -lc 'command -v buzz-pair' 2>/dev/null) || p=""
  [[ -n "$p" ]] && { printf '%s\n' "$p"; return 0; }
  for p in /usr/local/bin/buzz-pair /opt/buzz/bin/buzz-pair; do
    [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# https->wss / http->ws, host:port/path/query verbatim. The offline arm grades
# this against qr.rs's OWN decoder (round-trip + an https control that must be
# rejected), so the rule lives where the test can hold it.
_buzz_relay_to_ws() {
  case "$1" in
    https://*) printf 'wss://%s' "${1#https://}" ;;
    http://*)  printf 'ws://%s'  "${1#http://}" ;;
    wss://*|ws://*) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

# Does this buzz-pair read the nsec from stdin (`--nsec -`)? cli-v0.1.0 does
# not; its --help describes --nsec with no stdin form. Probed from the help
# text because probing by RUNNING it would either leak (argv) or consume a key.
_buzz_pair_supports_stdin_nsec() { # <runas> <bin>
  local runas="$1" bin="$2" help
  local -a pre=()
  [[ "$runas" != "$(id -un)" ]] && pre=(sudo -u "$runas")
  help=$("${pre[@]}" "$bin" source --help 2>&1) || return 1
  grep -Eq -- "--nsec.*(stdin|'-'|\"-\")" <<<"$help" || grep -Eqi 'reads? the (key|nsec) from stdin' <<<"$help"
}

# A refusal is a RESULT, on the same stream the panel already parses.
#
# The panel drives this verb over a PTY, so the exit status it can see is the
# shell's, not the verb's: a refusal that only printed `error: …` and exited was
# indistinguishable from a session that ended normally — which is exactly what
# lodar's first pairing attempts looked like (2026-08-18, sessions ending in
# under a second with no markers at all). Every state refusal below prints the
# terminal marker FIRST and then fails with its code, so the stream carries the
# verdict and the exit status stays honest for a terminal caller.
_buzz_pair_refuse() { # <code> <message>
  printf 'BUZZ-PAIR-RESULT: fail %s\n' "$2"
  fail "$1" "$2"
}

# cmd: 5dive agent buzz pair <name> [--timeout=<secs>]
#
# Requires `join` to have run (owner.json + the customer pubkey already a
# member): pairing hands the handset an identity, and an identity with no room
# membership lands the customer in an empty lobby — the panel must never mint
# that state. Refusals are loud and name the next command, per the DIVE-3509
# rule that a surface must not report success while connected to nothing.
_buzz_pair() {
  local name="" timeout_s="600"
  while (($#)); do
    case "$1" in
      --timeout=*) timeout_s="${1#*=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "unexpected argument: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent buzz pair <name> [--timeout=<secs>]"
  [[ "$timeout_s" =~ ^[0-9]+$ && "$timeout_s" -gt 0 ]] \
    || fail "$E_USAGE" "--timeout wants a positive integer (seconds), got '$timeout_s'"

  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || _buzz_pair_refuse "$E_NOT_FOUND" "no agent named '$name'"
  local user
  user=$(_buzz_pair_user "$name")

  # The envelope: {relayUrl,pubkey,nsec}. _buzz_owner already builds it (and
  # already refuses, naming `join`, when owner.json is absent) — reuse it
  # rather than grow a second bech32 implementation.
  local envelope relay nsec
  # `_buzz_owner` refuses (naming the repair) when the owner identity is absent;
  # it exits, so the marker has to be printed by whoever sees the non-zero rc.
  local owner_rc=0
  envelope=$(_buzz_owner "$name" --envelope) || owner_rc=$?
  if ((owner_rc != 0)); then
    printf 'BUZZ-PAIR-RESULT: fail no owner identity for %s (rc=%s; the error above says the repair)\n' "$name" "$owner_rc"
    exit "$owner_rc"
  fi
  relay=$(_buzz_pick "d.get('relayUrl')" <<<"$envelope")
  nsec=$(_buzz_pick "d.get('nsec')" <<<"$envelope")
  [[ -n "$relay" && -n "$nsec" ]] \
    || _buzz_pair_refuse "$E_GENERIC" "could not assemble the pairing envelope for '$name'"

  local ws_relay
  ws_relay=$(_buzz_relay_to_ws "$relay") \
    || _buzz_pair_refuse "$E_VALIDATION" "relay_url '$relay' has no ws form — expected an https://, http://, wss:// or ws:// URL"

  local pair_bin
  pair_bin=$(_buzz_resolve_pair_binary "$user") || _buzz_pair_refuse "$E_NOT_INSTALLED" \
    "no \`buzz-pair\` binary for '$name' (the agent's PATH, /usr/local/bin/buzz-pair, /opt/buzz/bin/buzz-pair). It ships beside \`buzz\` in 5dive-ai/buzz release cli-v0.1.0+ — install it, then re-run."

  _buzz_pair_supports_stdin_nsec "$user" "$pair_bin" || _buzz_pair_refuse "$E_NOT_INSTALLED" \
    "this \`buzz-pair\` ($pair_bin) only accepts the key as a command-line argument, which is world-readable in /proc for the whole session — refusing to leak the customer's handset key. Install buzz-pair cli-v0.1.1+ (supports \`--nsec -\`, key on stdin)."

  step "Pairing session for '$name': rendezvous $ws_relay, envelope relay $relay (timeout ${timeout_s}s)"

  # First stdin line to the child is the nsec; everything after is forwarded
  # verbatim (the y/n SAS answer, from a terminal or from the panel's PTY).
  # printf is a builtin: the key is never an argv element on either side of the
  # sudo hop. The transform is line-based and flushed per line, because the
  # panel parses a live PTY stream; buzz-pair's own [y/n] prompt has no newline
  # and would sit in the pipe, so the SAS marker line carries the instruction.
  # The feeder is a process substitution, not a pipeline element, so the verb
  # does not wait on `cat` still holding the terminal after the child exits;
  # it is killed explicitly below instead of being left to eat a stray line.
  local rc=0 feeder_pid
  local -a pre=()
  [[ "$user" != "$(id -un)" ]] && pre=(sudo -u "$user")
  exec 3< <({ printf '%s\n' "$nsec"; cat; })
  feeder_pid=$!
  timeout "$timeout_s" \
    "${pre[@]}" "$pair_bin" source --relay "$ws_relay" --envelope-relay "$relay" --nsec - <&3 2>&1 \
    | awk '
      { print; fflush() }
      /^nostrpair:\/\// { print "BUZZ-PAIR-QR: " $0; fflush() }
      /^SAS code: /     { sas=$0; sub(/^SAS code: /, "", sas)
                          print "BUZZ-PAIR-SAS: " sas
                          print "confirm: if the phone shows the same code, type y then enter (n aborts)"
                          fflush() }
    '
  rc=${PIPESTATUS[0]}
  exec 3<&-
  kill "$feeder_pid" 2>/dev/null || true
  # timeout(1) reports 124; the child reports 1 on any pairing failure and its
  # last stderr line (already on the stream above) says why.
  if ((rc == 0)); then
    printf 'BUZZ-PAIR-RESULT: ok\n'
    ok "handset paired for '$name' — it holds the customer identity and lands in the joined channel(s)."
    return 0
  fi
  if ((rc == 124)); then
    printf 'BUZZ-PAIR-RESULT: fail timeout after %ss\n' "$timeout_s"
  else
    printf 'BUZZ-PAIR-RESULT: fail rc=%s (the line above this marker says why)\n' "$rc"
  fi
  mark_reported  # DIVE-3558: by-design rc=3, and the BUZZ-PAIR-RESULT marker is the report
  return 3
}
