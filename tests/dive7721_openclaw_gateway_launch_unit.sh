#!/usr/bin/env bash
# DIVE-7721: openclaw 2026.10.10 refuses `config set` while the seat runs, so
# `agent channel add dashboard` could no longer bind the gateway to loopback and
# the web chat answered "OpenClaw could not answer just now" in every container.
# 5dive-agent-start now fills in a missing gateway.mode/bind before the seat
# starts. This runs that block from the real script against a fake openclaw.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad_t() { FAIL=$((FAIL+1)); echo "FAIL $1${2:+ :: $2}"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

block=$(awk '/DIVE-7721: a seat with a channel runs/{on=1} on{print} on&&/^  esac$/{exit}' bin/5dive-agent-start)
[[ "$block" == *'config patch --stdin'* && "$block" == *'esac' ]] \
  && ok_t "the launch block is in bin/5dive-agent-start" || { bad_t "launch block not found"; echo "--- $PASS pass, $FAIL fail"; exit 1; }
# the real path to openclaw is fixed in the script; point it at the fake
block="${block//\/home\/claude\/.local\/bin\/openclaw/$TMP/openclaw}"
cat >"$TMP/openclaw" <<'SH'
#!/bin/bash
echo "$*" >>"$OC_LOG"; cat >>"$OC_LOG"; echo >>"$OC_LOG"
[[ "${OC_FAIL:-0}" == 1 ]] && exit 1 || exit 0
SH
chmod +x "$TMP/openclaw"

run() { # $1=channels $2=config json ; prints what openclaw got
  : >"$TMP/log"; printf '%s' "$2" >"$TMP/cfg.json"
  CHANNELS="$1" LOCAL_OPENCLAW_CFG="$TMP/cfg.json" OC_LOG="$TMP/log" OC_FAIL="${OC_FAIL:-0}" \
    bash -c "$block" 2>"$TMP/err"; cat "$TMP/log"
}

out=$(run dashboard '{"agents":{}}')
[[ "$out" == *'config patch --stdin'* && "$out" == *'"mode":"local"'* && "$out" == *'"bind":"loopback"'* ]] \
  && ok_t "web chat seat with no gateway keys gets mode=local + bind=loopback" || bad_t "unset keys" "$out"
out=$(run dashboard '{"gateway":{"mode":"local"}}')
[[ "$out" == *'"bind":"loopback"'* && "$out" != *'"mode"'* ]] \
  && ok_t "only the missing bind is filled in (the failed-run shape)" || bad_t "bind only" "$out"
out=$(run telegram,dashboard '{"gateway":{"mode":"local","bind":"loopback"}}')
[[ -z "$out" ]] && ok_t "already set: openclaw is not called" || bad_t "already set" "$out"
out=$(run dashboard '{"gateway":{"mode":"remote","bind":"lan"}}')
[[ -z "$out" ]] && ok_t "a deliberate bind=lan is left alone" || bad_t "deliberate bind" "$out"
out=$(run none '{}')
[[ -z "$out" ]] && ok_t "a seat with no channel (runs chat, not the gateway) is untouched" || bad_t "no channel" "$out"
out=$(run "" '{}')
[[ -z "$out" ]] && ok_t "empty channels is untouched" || bad_t "empty channels" "$out"
out=$(run dashboard 'not json')
[[ -z "$out" ]] && ok_t "an unreadable config is not patched blind" || bad_t "bad json" "$out"
OC_FAIL=1 run dashboard '{}' >/dev/null
[[ "$(cat "$TMP/err")" == *'warn: openclaw gateway mode/bind'* ]] \
  && ok_t "a failed patch warns and the launch goes on" || bad_t "failed patch" "$(cat "$TMP/err")"

echo "--- $PASS pass, $FAIL fail"
(( FAIL == 0 ))
