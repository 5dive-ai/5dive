#!/usr/bin/env bash
# DIVE-4297 — a secret passed as a `key=value` ARGUMENT was written to
# /var/log/5dive/agent-audit.log in cleartext.
#
# WHAT LEAKED. `audit_log` redacted a fixed list of `--flag=value` forms
# (--api-key=, --telegram-token=, --discord-token=, --code=, --token=) and
# nothing else. `5dive agent config <seat> set telegram.token=<token>` passes
# the credential as a POSITIONAL `key=value` pair, so it matched none of them
# and was recorded verbatim. The log is 640 root:claude and group `claude`
# contains every agent seat on the box, so two live bot tokens sat readable by
# every seat, indefinitely (measured 2026-09-11 in a 105,949-line log).
#
# The defect is the VERBATIM `args` capture, not the one subcommand — so what
# is pinned here is the key-name rule, not a list of verbs:
#   1. a positional `telegram.token=` is redacted, KEY KEPT (the audit row must
#      still say what was set);
#   2. the old --flag= list still redacts (no regression from the rewrite);
#   3. the key-name rule is case-insensitive and matches anywhere in the key,
#      so TELEGRAM.TOKEN=, api_key=, --auth-secret=, db_password= are covered;
#   4. an ordinary `key=value` argument carrying no sensitive word is NOT
#      touched — over-redaction that ate `channels=telegram` would make the
#      audit log useless and the fix would be reverted;
#   5. a bare word that merely CONTAINS a sensitive name but has no `=` is left
#      alone (`token`, `set`) — there is no value to hide;
#   6. cmd_bug.sh's _bug_redact_argv mirrors the same rule, because that string
#      is bound for a PUBLIC GitHub issue.
# Run: bash tests/audit_key_value_secret_redaction_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/audit-kv-redaction.XXXXXX)"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/audit.sh; do
  source "$SRC/$f"
done
set +e   # AFTER sourcing: header.sh turns `set -e` back on.

# Suite guard (same shape as audit_nonroot_unit.sh): prove this run never
# appended to the fleet's real audit log, which is the file this row is about.
REALLOG=/var/log/5dive/agent-audit.log
REALLOG_OFFSET=0
[[ -r "$REALLOG" ]] && REALLOG_OFFSET=$(wc -c <"$REALLOG" 2>/dev/null || echo 0)

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

AUDIT_LOG="$TMP/agent-audit.log"; : > "$AUDIT_LOG"
mkdir -p "$TMP/notify"

# A reserved FAKE in the Telegram bot-token SHAPE (<digits>:<35 chars>), never a
# real credential: 1234567890 is the reserved test id, and the secret half is
# filler. The shape matters because case 1 also re-greps for it the way the row
# says to verify on the live log.
FAKE='1234567890:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'

# args_of <n> — the args[] array of the n-th (1-based) row, one element per line.
args_of() { sed -n "${1}p" "$AUDIT_LOG" | jq -r '.args[]' 2>/dev/null; }

# --- case 1: the leak itself — positional telegram.token= ----------------------
audit_log "agent config" ok 0 -- draft-codex set "telegram.token=$FAKE" channels=telegram
got=$(args_of 1)
if [[ "$got" != *"$FAKE"* ]] \
   && grep -qx 'telegram.token=<redacted>' <<<"$got" \
   && grep -qx 'channels=telegram' <<<"$got"; then
  ok_t "case 1: positional telegram.token= redacted, key kept, neighbours intact"
else
  bad_t "case 1: positional telegram.token= redacted, key kept, neighbours intact" "$got"
fi

# The row-body verification, run against the harness log instead of the live one:
# nothing token-SHAPED survives anywhere in the line.
if ! grep -qE '[0-9]{8,10}:[A-Za-z0-9_-]{30,}' "$AUDIT_LOG"; then
  ok_t "case 1b: no token-shaped value survives anywhere in the written row"
else
  bad_t "case 1b: no token-shaped value survives anywhere in the written row" "$(cat "$AUDIT_LOG")"
fi

# --- case 2: the pre-existing --flag= list still redacts (no regression) -------
: > "$AUDIT_LOG"
audit_log "agent create" ok 0 -- bot --api-key="$FAKE" --telegram-token="$FAKE" \
  --discord-token="$FAKE" --code="$FAKE" --token="$FAKE"
got=$(args_of 1)
if [[ "$got" != *"$FAKE"* ]] \
   && [[ $(grep -c '=<redacted>$' <<<"$got") -eq 5 ]]; then
  ok_t "case 2: all five legacy --flag= forms still redacted"
else
  bad_t "case 2: all five legacy --flag= forms still redacted" "$got"
fi

# --- case 3: key-name rule is case-insensitive and substring-wide --------------
: > "$AUDIT_LOG"
audit_log "probe" ok 0 -- "TELEGRAM.TOKEN=$FAKE" "api_key=$FAKE" "--auth-secret=$FAKE" \
  "db_password=$FAKE" "aws.credential=$FAKE" "--sort-key=name"
got=$(args_of 1)
missing=""
for want in 'TELEGRAM.TOKEN=<redacted>' 'api_key=<redacted>' '--auth-secret=<redacted>' \
            'db_password=<redacted>' 'aws.credential=<redacted>' '--sort-key=<redacted>'; do
  grep -qx -- "$want" <<<"$got" || missing="$missing $want"
done
if [[ "$got" != *"$FAKE"* ]] && [[ -z "$missing" ]]; then
  ok_t "case 3: key-name rule is case-insensitive, substring-wide, value-only"
else
  bad_t "case 3: key-name rule is case-insensitive, substring-wide, value-only" \
        "missing:$missing | got: $got"
fi

# --- case 4: ordinary key=value arguments are NOT redacted --------------------
# The failure mode that would get this fix reverted: an audit log that records
# `<redacted>` for every argument records nothing.
: > "$AUDIT_LOG"
audit_log "task add" ok 0 -- --title=fix --priority=high status=todo assignee=ops DIVE-4297
got=$(args_of 1)
if [[ "$got" != *'<redacted>'* ]] \
   && grep -qx -- '--priority=high' <<<"$got" \
   && grep -qx 'assignee=ops' <<<"$got"; then
  ok_t "case 4: ordinary key=value args are left verbatim"
else
  bad_t "case 4: ordinary key=value args are left verbatim" "$got"
fi

# --- case 5: a sensitive WORD with no `=` is untouched -------------------------
: > "$AUDIT_LOG"
audit_log "agent config" ok 0 -- draft-codex set token secret-santa --keyring
got=$(args_of 1)
if [[ "$got" != *'<redacted>'* ]] && grep -qx 'token' <<<"$got" \
   && grep -qx 'secret-santa' <<<"$got" && grep -qx -- '--keyring' <<<"$got"; then
  ok_t "case 5: bare words carrying a sensitive name but no value are untouched"
else
  bad_t "case 5: bare words carrying a sensitive name but no value are untouched" "$got"
fi

# --- case 6: cmd_bug.sh's mirror covers the same shape ------------------------
# That string goes to a PUBLIC issue, so the bar is the same or higher. Sourced
# in a subshell: cmd_bug.sh pulls in more of the tree than this harness wants.
mirror=$(
  # shellcheck disable=SC1090
  source "$SRC/cmd_bug.sh" >/dev/null 2>&1
  _bug_redact_argv "5dive agent config draft-codex set telegram.token=$FAKE channels=telegram"
)
if [[ -n "$mirror" && "$mirror" != *"$FAKE"* ]] \
   && [[ "$mirror" == *'telegram.token=<redacted>'* ]] \
   && [[ "$mirror" == *'channels=telegram'* ]]; then
  ok_t "case 6: _bug_redact_argv mirrors the positional key=value rule"
else
  bad_t "case 6: _bug_redact_argv mirrors the positional key=value rule" "$mirror"
fi

# --- suite guard: the real fleet log was never written -------------------------
now=0
[[ -r "$REALLOG" ]] && now=$(wc -c <"$REALLOG" 2>/dev/null || echo 0)
if [[ "$now" == "$REALLOG_OFFSET" ]]; then
  ok_t "guard: the live /var/log/5dive/agent-audit.log was not appended to"
else
  bad_t "guard: the live /var/log/5dive/agent-audit.log was not appended to" \
        "grew ${REALLOG_OFFSET} -> ${now}"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
