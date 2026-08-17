#!/usr/bin/env bash
# DIVE-3551 unit harness for `agent buzz pair` — the NIP-AB session verb.
#
# What this grades WITHOUT a relay, a phone, or root — and deliberately only
# that (whether a relay accepts the session is the fresh-VM smoke's job):
#
#   1. the file is CONCATENATED into the bundle (the buzz_channel_wiring
#      failure mode: present but never bundled = "command not found")
#   2. `agent buzz pair` is dispatched and in the usage text
#   3. _buzz_relay_to_ws — scheme swap ONLY, everything else verbatim. This is
#      the qr.rs trap: its DECODER accepts wss/ws only while our configs store
#      https://, and encode validates nothing, so an untranslated URL is a QR
#      that renders everywhere and fails on the handset (wiki: the-pairing-
#      rendezvous-is-the-customers-own-relay-and-its-scheme-is-the-trap.md)
#   4. the same translation against the REAL decoder when a buzz-pair binary is
#      present: translated URL DECODES, raw https is REJECTED (control arm)
#   5. the BUZZ-PAIR-* marker contract against a stub buzz-pair, full verb
#      path: QR + SAS markers appear, RESULT: ok on success, RESULT: fail on a
#      SAS mismatch, rc 0/3 respectively, and the timeout arm marks fail
#   6. THE KEY IS NEVER AN ARGV ELEMENT (the DIVE-3509 push-gate rule): the
#      stub logs its argv; the nsec must not be in it, `--nsec -` must be
#   7. the stdin-support probe: a cli-v0.1.0-shaped --help (no stdin form)
#      must be REFUSED, a cli-v0.1.1-shaped one accepted — with the real
#      0.1.0 help text as the control, so the probe cannot rot into always-yes
#
# Run: bash tests/buzz_pair_unit.sh   (no root, no network, no relay.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_buzz.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent_buzz_join.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent_buzz_pair.sh"
set +e  # header.sh enables set -e; the arms below deliberately probe non-zero rc

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- 1. the file is in the bundle -------------------------------------------
grep -q '^  src/cmd_agent_buzz_pair\.sh \\$' build.sh \
  && ok_t "build.sh concatenates cmd_agent_buzz_pair.sh" \
  || bad_t "build.sh concatenates cmd_agent_buzz_pair.sh" \
           "present but never concatenated — \`agent buzz pair\` would be 'command not found' in the built bundle"

# --- 2. dispatched + in usage ------------------------------------------------
grep -qE '^\s+pair\)\s+shift; _buzz_pair' "$SRC/cmd_agent_buzz.sh" \
  && ok_t "cmd_agent_buzz dispatches 'pair'" \
  || bad_t "cmd_agent_buzz dispatches 'pair'" "the verb is unreachable"
grep -q 'buzz pair <name>' "$SRC/cmd_agent_buzz.sh" \
  && ok_t "usage text names 'buzz pair'" \
  || bad_t "usage text names 'buzz pair'" "undiscoverable"

# --- 3. _buzz_relay_to_ws ----------------------------------------------------
t3() { # <desc> <in> <want>
  local got
  got=$(_buzz_relay_to_ws "$2")
  [[ "$got" == "$3" ]] && ok_t "relay_to_ws: $1" \
    || bad_t "relay_to_ws: $1" "in='$2' want='$3' got='$got'"
}
t3 "https host"        "https://relay.example.com"       "wss://relay.example.com"
t3 "https host:port"   "https://relay.example.com:7443"  "wss://relay.example.com:7443"
t3 "path kept"         "https://r.example.com/nostr"     "wss://r.example.com/nostr"
t3 "http -> ws"        "http://192.0.2.7:8080"           "ws://192.0.2.7:8080"
t3 "wss passthrough"   "wss://already.example.com"       "wss://already.example.com"
if _buzz_relay_to_ws "ftp://192.0.2.7" >/dev/null 2>&1; then
  bad_t "relay_to_ws refuses a non-http(s)/ws(s) scheme" "ftp:// accepted"
else
  ok_t "relay_to_ws refuses a non-http(s)/ws(s) scheme"
fi

# --- 4. against the REAL decoder, when one is around -------------------------
# nostrpair:// URI minted by hand per qr.rs's format; 127.0.0.1:1 makes decode
# success distinguishable (a fast connect-refused, never InvalidQr).
REAL_PAIR=""
for c in /usr/local/bin/buzz-pair /opt/buzz/bin/buzz-pair; do
  [[ -x "$c" ]] && REAL_PAIR="$c" && break
done
if [[ -n "$REAL_PAIR" ]]; then
  PUB=$(printf 'a%.0s' {1..64}); SEC=$(printf 'b%.0s' {1..64})
  enc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
  out=$(printf 'nostrpair://%s?secret=%s&relay=%s&v=1' "$PUB" "$SEC" "$(enc "$(_buzz_relay_to_ws https://127.0.0.1:1)")" \
        | timeout 10 "$REAL_PAIR" target 2>&1)
  if grep -q 'relay URL must use wss:// or ws:// scheme' <<<"$out"; then
    bad_t "real decoder accepts the TRANSLATED url" "still rejected: $out"
  else
    ok_t "real decoder accepts the TRANSLATED url ($REAL_PAIR)"
  fi
  out=$(printf 'nostrpair://%s?secret=%s&relay=%s&v=1' "$PUB" "$SEC" "$(enc https://127.0.0.1:1)" \
        | timeout 10 "$REAL_PAIR" target 2>&1)
  if grep -q 'relay URL must use wss:// or ws:// scheme' <<<"$out"; then
    ok_t "real decoder REJECTS the raw https url (control)"
  else
    bad_t "real decoder REJECTS the raw https url (control)" \
          "decoded — the decoder loosened; the translation layer may be retirable, but deliberately: $out"
  fi
else
  printf 'note - no buzz-pair binary on this box; decoder round-trip arms ran only in the fresh-VM smoke\n'
fi

# --- 5 + 6. the verb end to end against a stub buzz-pair ---------------------
WORK=$(mktemp -d)
STUBDIR="$WORK/bin"; mkdir -p "$STUBDIR"
ARGS_LOG="$WORK/argv.log"; export ARGS_LOG

cat >"$STUBDIR/buzz-pair" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "source" && "${2:-}" == "--help" ]]; then
  echo "      --nsec <NSEC>  nsec of the key to transfer; use '-' to read the nsec from stdin"
  exit 0
fi
printf '%s\n' "$@" >> "$ARGS_LOG"
IFS= read -r _nsec_line   # --nsec -: first stdin line is the key
if [[ "${STUB_MODE:-ok}" == "hang" ]]; then sleep 30; exit 1; fi
echo "QR URI (contains session secret — do not share beyond the target device):"
echo "nostrpair://cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc?secret=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd&relay=wss%3A%2F%2Fr.example.com&v=1"
echo "Waiting for target to scan QR code..."
echo "SAS code: 4217"
printf 'Does your other device show 4217? [y/n]: '
IFS= read -r ans
if [[ "$ans" != "y" ]]; then echo "error: SAS mismatch — session aborted"; exit 1; fi
echo "Sending identity..."
echo "Transfer complete! ✓"
EOF
chmod +x "$STUBDIR/buzz-pair"
PATH="$STUBDIR:$PATH"

# Seams: a one-agent registry, a canned envelope (the real _buzz_owner needs
# owner.json + sudo), and binary resolution pinned at the stub. The nsec is a
# RESERVED FAKE, never a real key.
FAKE_NSEC="nsec1testonlytestonlytestonlytestonlytestonlytestonlyq7clt5"
ensure_state() { :; }
registry_read() { printf '{"agents":{"tagent":{"type":"claude"}}}'; }
# the documented harness convention: run as ourselves, every sudo hop collapses
# (the DIVE-3096 isolation layer refuses sudo inside harnesses by design)
_buzz_pair_user() { id -un; }
_buzz_owner() { printf '{"relayUrl": "https://r.example.com", "pubkey": "%s", "nsec": "%s"}' \
                  "$(printf 'e%.0s' {1..64})" "$FAKE_NSEC"; }
_buzz_resolve_pair_binary() { printf '%s\n' "$STUBDIR/buzz-pair"; }

out=$(printf 'y\n' | _buzz_pair tagent 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok_t "pair: rc 0 on success" || bad_t "pair: rc 0 on success" "rc=$rc; out: $out"
grep -q '^BUZZ-PAIR-QR: nostrpair://' <<<"$out" \
  && ok_t "pair: BUZZ-PAIR-QR marker" || bad_t "pair: BUZZ-PAIR-QR marker" "$out"
grep -q '^BUZZ-PAIR-SAS: 4217$' <<<"$out" \
  && ok_t "pair: BUZZ-PAIR-SAS marker carries the code" || bad_t "pair: BUZZ-PAIR-SAS marker carries the code" "$out"
grep -q '^BUZZ-PAIR-RESULT: ok$' <<<"$out" \
  && ok_t "pair: BUZZ-PAIR-RESULT ok" || bad_t "pair: BUZZ-PAIR-RESULT ok" "$out"

# the key rule: on stdin, never argv — and the stub must have been told so.
if grep -q "$FAKE_NSEC" "$ARGS_LOG" 2>/dev/null; then
  bad_t "pair: nsec is NOT an argv element" "found the key in the stub's argv: $(cat "$ARGS_LOG")"
else
  ok_t "pair: nsec is NOT an argv element"
fi
grep -qx -- '-' "$ARGS_LOG" 2>/dev/null && grep -qx -- '--nsec' "$ARGS_LOG" \
  && ok_t "pair: '--nsec -' requested (key expected on stdin)" \
  || bad_t "pair: '--nsec -' requested (key expected on stdin)" "argv: $(tr '\n' ' ' <"$ARGS_LOG" 2>/dev/null)"
grep -qx -- '--envelope-relay' "$ARGS_LOG" && grep -qx -- 'https://r.example.com' "$ARGS_LOG" \
  && ok_t "pair: envelope relay stays https, VERBATIM" \
  || bad_t "pair: envelope relay stays https, VERBATIM" "argv: $(tr '\n' ' ' <"$ARGS_LOG" 2>/dev/null)"
grep -qx -- 'wss://r.example.com' "$ARGS_LOG" \
  && ok_t "pair: rendezvous relay is the TRANSLATED wss url" \
  || bad_t "pair: rendezvous relay is the TRANSLATED wss url" "argv: $(tr '\n' ' ' <"$ARGS_LOG" 2>/dev/null)"

out=$(printf 'n\n' | _buzz_pair tagent 2>&1); rc=$?
[[ $rc -eq 3 ]] && ok_t "pair: rc 3 on SAS mismatch" || bad_t "pair: rc 3 on SAS mismatch" "rc=$rc"
grep -q '^BUZZ-PAIR-RESULT: fail' <<<"$out" \
  && ok_t "pair: BUZZ-PAIR-RESULT fail on mismatch" || bad_t "pair: BUZZ-PAIR-RESULT fail on mismatch" "$out"

export STUB_MODE=hang
out=$(printf '' | _buzz_pair tagent --timeout=1 2>&1); rc=$?
unset STUB_MODE
grep -q '^BUZZ-PAIR-RESULT: fail timeout after 1s' <<<"$out" \
  && ok_t "pair: timeout marks RESULT fail timeout" || bad_t "pair: timeout marks RESULT fail timeout" "rc=$rc out: $out"

# --- 7. the stdin-support probe, with the 0.1.0 text as CONTROL ---------------
cat >"$STUBDIR/pair-v010" <<'EOF'
#!/usr/bin/env bash
# the REAL cli-v0.1.0 --nsec help line, verbatim — must NOT read as stdin-capable
echo "      --nsec <NSEC>  nsec (bech32) of the key to transfer. If omitted, generates a test key."
EOF
chmod +x "$STUBDIR/pair-v010"
if _buzz_pair_supports_stdin_nsec "$(id -un)" "$STUBDIR/pair-v010"; then
  bad_t "probe: cli-v0.1.0 help is refused (control)" "read the argv-only build as stdin-capable — the refusal arm is dead"
else
  ok_t "probe: cli-v0.1.0 help is refused (control)"
fi
_buzz_pair_supports_stdin_nsec "$(id -un)" "$STUBDIR/buzz-pair" \
  && ok_t "probe: stdin-capable help is accepted" \
  || bad_t "probe: stdin-capable help is accepted" "would refuse the fixed build too"

rm -rf "$WORK"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
