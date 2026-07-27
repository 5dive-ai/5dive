#!/usr/bin/env bash
# DIVE-2044 isolated unit harness for the tick's logging rail.
#
# The incident: /etc/cron.d/5dive-proof ended `>> /var/log/5dive-proof.log 2>&1`.
# The log was re-chowned to a user the cron could not write as, so the SHELL died
# on the redirect and `5dive proof tick` never executed — 26h of no publishes,
# with cron logging the CMD line every night so journalctl showed a healthy job.
# The log's only content in that window was a SKIP line, because a successful
# tick printed nothing at all.
#
# Asserts, against stubbed publishes (no network, no root, no cron.d writes):
#   1. the installed cron line has NO `>>` redirect and passes --log=,
#   2. a successful tick writes a PUBLISHED record carrying the stamp,
#   3. a no-op (rc 3) is recorded AS a no-op and still exits 0,
#   4. a failure (rc 4, no identity) is recorded as FAILED and stays non-zero,
#   5. THE ONE THAT MATTERS: with an unwritable --log target the publish STILL
#      RUNS (proven by a sentinel the stub writes) and the tick's exit code is
#      unchanged — the log is downstream of the publish, never upstream,
#   6. a legacy `>>` cron is detected and rewritten by _proof_cron_legacy_check.
# Run: bash tests/proof_tick_log_unit.sh   (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/proof-tick-log.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

E_USAGE=2
E_GENERIC=1
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
_PROOF_CRON="$TMP/cron"
_PROOF_LOG="$TMP/proof.log"
JSON_MODE=0
require_root() { :; }
fail() { echo "fail($1): $2" >&2; exit "$1"; }
[ -d /etc/cron.d ] || { echo "SKIP - /etc/cron.d absent on this host"; exit 0; }

# shellcheck disable=SC1091
source src/cmd_proof.sh

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

echo '{"enabled":true,"repo":"https://github.com/x/y.git","branch":"status","hour":2,"lastPublished":"2026-07-26"}' > "$STATE_DIR/proof.json"

# The publish stub every case drives. It records that it RAN (the sentinel is the
# whole point of case 5 — an assertion on the log alone cannot tell a publish that
# was skipped from one whose record went missing).
SENTINEL="$TMP/publish-ran"
_proof_publish() {
  printf 'ran\n' >> "$SENTINEL"
  [ -n "${STUB_OUT:-}" ] && echo "$STUB_OUT"
  return "${STUB_RC:-0}"
}

# --- 1. the cron line ---------------------------------------------------------
_proof_install_cron 2 root >/dev/null 2>&1
cronline="$(grep -E '^[0-9]' "$_PROOF_CRON" 2>/dev/null)"
case "$cronline" in
  *'>>'*) bad_t "cron line carries no >> redirect" "still redirects: $cronline" ;;
  *"--log=$_PROOF_LOG"*) ok_t "cron line carries no >> redirect and passes --log=" ;;
  *) bad_t "cron line carries no >> redirect and passes --log=" "unexpected: $cronline" ;;
esac

# --- 2. success is RECORDED ---------------------------------------------------
: > "$_PROOF_LOG"; : > "$SENTINEL"
STUB_RC=0 STUB_OUT="published 468 shipped / 61 asks" _proof_tick --log="$_PROOF_LOG" >/dev/null 2>&1
rc=$?
body="$(cat "$_PROOF_LOG")"
if [ "$rc" -eq 0 ] && printf '%s' "$body" | grep -q 'proof tick: PUBLISHED' \
   && printf '%s' "$body" | grep -q 'lastPublished=2026-07-26' \
   && printf '%s' "$body" | grep -q '468 shipped'; then
  ok_t "a successful tick writes a PUBLISHED record with the stamp and the publisher's summary"
else
  bad_t "a successful tick writes a PUBLISHED record" "rc=$rc log=<<$body>>"
fi

# --- 3. no-op (3) is a no-op, not a success and not a failure -----------------
: > "$_PROOF_LOG"
STUB_RC=3 STUB_OUT="proof: already published today for status" _proof_tick --log="$_PROOF_LOG" >/dev/null 2>&1
rc=$?
body="$(cat "$_PROOF_LOG")"
if [ "$rc" -eq 0 ] && printf '%s' "$body" | grep -q 'proof tick: no-op'; then
  ok_t "rc 3 is recorded as a no-op and still exits 0"
else
  bad_t "rc 3 is recorded as a no-op and still exits 0" "rc=$rc log=<<$body>>"
fi

# --- 4. the identity refusal stays loud and non-zero (DIVE-2051 boundary) -----
: > "$_PROOF_LOG"
STUB_RC=4 STUB_OUT="" _proof_tick --log="$_PROOF_LOG" >/dev/null 2>&1
rc=$?
body="$(cat "$_PROOF_LOG")"
if [ "$rc" -eq 4 ] && printf '%s' "$body" | grep -q 'FAILED rc=4 — no publishing identity'; then
  ok_t "rc 4 is recorded as FAILED and the tick stays non-zero"
else
  bad_t "rc 4 is recorded as FAILED and the tick stays non-zero" "rc=$rc log=<<$body>>"
fi

# --- 4b. a box that never enabled the publisher is SKIPPED, never PUBLISHED ---
# The first cut of this fix returned plain 0 from the not-configured path, so the
# record read "PUBLISHED (lastPublished=unrecorded)" on a box that published
# nothing — this ticket's own defect, rebuilt inside its fix. Caught by running
# the real binary, not by the harness. It is asserted here now.
: > "$_PROOF_LOG"; : > "$SENTINEL"
( STATE_DIR="$TMP/empty-state"; mkdir -p "$STATE_DIR"
  _proof_tick --log="$_PROOF_LOG" >/dev/null 2>&1 )
rc=$?
body="$(cat "$_PROOF_LOG")"
if [ "$rc" -eq 0 ] && printf '%s' "$body" | grep -q 'proof tick: SKIPPED' \
   && ! printf '%s' "$body" | grep -q 'PUBLISHED' && [ ! -s "$SENTINEL" ]; then
  ok_t "an unconfigured box records SKIPPED (never PUBLISHED) and exits 0"
else
  bad_t "an unconfigured box records SKIPPED, never PUBLISHED" "rc=$rc log=<<$body>>"
fi
: > "$_PROOF_LOG"
echo '{"enabled":false}' > "$TMP/off-state-proof.json"
( STATE_DIR="$TMP/off-state"; mkdir -p "$STATE_DIR"
  cp "$TMP/off-state-proof.json" "$STATE_DIR/proof.json"
  _proof_tick --log="$_PROOF_LOG" >/dev/null 2>&1 )
body="$(cat "$_PROOF_LOG")"
printf '%s' "$body" | grep -q 'proof tick: SKIPPED' \
  && ok_t "a disabled publisher records SKIPPED, not PUBLISHED" \
  || bad_t "a disabled publisher records SKIPPED, not PUBLISHED" "log=<<$body>>"

# --- 4c. A FAILING TICK NAMES ITS REASON ON STDERR, EVEN WITH A WRITABLE LOG --
# Regression arm. Capturing the publisher's output for the record (defect 2's fix)
# also took it OFF stderr, so on any box with a working `logger` the reason went
# to journald and cron's stderr — the operator's actual channel for a scheduled
# run — got nothing. That is this ticket's defect one layer up: a failure that
# writes nothing where somebody is looking. tests/proof_identity_guard_unit.sh
# caught it end-to-end with NO --log; this arm pins the axis that one cannot see,
# where the log rail SUCCEEDS and could therefore be mistaken for sufficient.
: > "$_PROOF_LOG"; : > "$SENTINEL"
STUB_RC=4 STUB_OUT="NO GIT IDENTITY CONFIGURED for the publisher" \
  _proof_tick --log="$_PROOF_LOG" >"$TMP/out" 2>"$TMP/err"
rc=$?
body="$(cat "$_PROOF_LOG")"
if [ "$rc" -ne 0 ] && grep -q 'NO GIT IDENTITY CONFIGURED' "$TMP/err"; then
  ok_t "a FAILING tick names its reason on stderr even when --log took the record"
else
  bad_t "a FAILING tick names its reason on stderr" "rc=$rc stderr=<<$(cat "$TMP/err")>>"
fi
# The record still reaches the log too — stderr is an ADDITION, not a diversion.
printf '%s' "$body" | grep -q 'FAILED' \
  && ok_t "…and the log still carries the FAILED record (stderr added, not diverted)" \
  || bad_t "the log still carries the FAILED record" "log=<<$body>>"
# Non-vacuity: a SUCCESSFUL tick must stay quiet on stderr, or the arm above
# passes for any tick at all and asserts nothing about failure.
: > "$_PROOF_LOG"; : > "$SENTINEL"
STUB_RC=0 STUB_OUT="published 468 shipped / 61 asks" \
  _proof_tick --log="$_PROOF_LOG" >"$TMP/out" 2>"$TMP/err"
[ ! -s "$TMP/err" ] \
  && ok_t "non-vacuity: a SUCCESSFUL tick writes nothing to stderr" \
  || bad_t "a successful tick writes nothing to stderr" "stderr=<<$(cat "$TMP/err")>>"

# --- 5. AN UNWRITABLE LOG DOES NOT STOP THE PUBLISH ---------------------------
# /proc/<nothing>/… cannot be created by anyone, root included, so this case is
# not quietly skipped when the harness happens to run as root.
: > "$SENTINEL"
DEAD_LOG="/proc/5dive-2044-nonexistent/proof.log"
STUB_RC=0 STUB_OUT="published 468 shipped / 61 asks" _proof_tick --log="$DEAD_LOG" >"$TMP/out" 2>"$TMP/err"
rc=$?
if [ "$rc" -eq 0 ] && [ -s "$SENTINEL" ]; then
  ok_t "an unwritable --log does not stop the publish (it ran; rc unchanged)"
else
  bad_t "an unwritable --log does not stop the publish" "rc=$rc sentinel=$(wc -c <"$SENTINEL" 2>/dev/null)"
fi
# ...and bash's own redirect diagnostic is not what escapes. `>> "$f" 2>/dev/null`
# applies the append FIRST, so the shell's "No such file or directory" (naming a
# bundle line number) reaches the real stderr and gets cron-mailed every night.
if grep -qi 'no such file or directory' "$TMP/err"; then
  bad_t "no raw bash redirect diagnostic escapes to stderr" "stderr=<<$(cat "$TMP/err")>>"
else
  ok_t "no raw bash redirect diagnostic escapes to stderr"
fi
# ...and the record went SOMEWHERE. Asserting only "the publish ran" would leave the
# outage's other half — a run nobody can read afterwards — untested, so both fallback
# rails are exercised for real. journald is not readable from a unit test, so `logger`
# is stubbed on PATH and its stdin captured: that is the message journald would get.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/logger" <<'STUB'
#!/usr/bin/env bash
cat >> "$LOGGER_CAPTURE"
STUB
chmod +x "$TMP/bin/logger"
LOGGER_CAPTURE="$TMP/journald" : > "$TMP/journald"
LOGGER_CAPTURE="$TMP/journald" PATH="$TMP/bin:$PATH" \
  STUB_RC=0 STUB_OUT="published 468 shipped / 61 asks" _proof_tick --log="$DEAD_LOG" >/dev/null 2>"$TMP/err"
jr="$(cat "$TMP/journald")"
if printf '%s' "$jr" | grep -q 'proof tick: PUBLISHED' && printf '%s' "$jr" | grep -q 'could NOT append'; then
  ok_t "the record falls back to journald, carrying BOTH the run and why the file rail was skipped"
else
  bad_t "the record falls back to journald" "captured=<<$jr>>"
fi
# Last rail: journald refuses too (no syslog socket in a container, say) — stderr,
# so cron mail still carries it. Stubbed as a FAILING logger, not a missing one:
# `command -v` succeeding while the write fails is the harder of the two paths.
mkdir -p "$TMP/badbin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/badbin/logger"; chmod +x "$TMP/badbin/logger"
PATH="$TMP/badbin:$PATH" STUB_RC=0 STUB_OUT="published 468 shipped / 61 asks" \
  _proof_tick --log="$DEAD_LOG" >/dev/null 2>"$TMP/err2"
if grep -q 'proof tick: PUBLISHED' "$TMP/err2"; then
  ok_t "with neither a writable file nor journald, the record still reaches stderr"
else
  bad_t "with neither a writable file nor journald, the record reaches stderr" "stderr=<<$(cat "$TMP/err2")>>"
fi

# --- 6. a legacy cron is detected and rewritten -------------------------------
cat > "$_PROOF_CRON" <<'LEGACY'
# 5dive zero-human proof publisher (OSS-17)
0 2 * * * claude /usr/local/bin/5dive proof tick >> /var/log/5dive-proof.log 2>&1
LEGACY
warn="$(_proof_cron_legacy_check 2>&1)"
after="$(grep -E '^[0-9]' "$_PROOF_CRON")"
if printf '%s' "$warn" | grep -q 'legacy' && ! printf '%s' "$after" | grep -q '>>' \
   && printf '%s' "$after" | grep -q -- '--log=' && printf '%s' "$after" | grep -q ' claude '; then
  ok_t "a legacy >> cron is detected, warned about, and rewritten (user preserved)"
else
  bad_t "a legacy >> cron is detected and rewritten" "warn=<<$warn>> after=<<$after>>"
fi
# ...and a fixed cron is not re-warned about (no permanent nag on a healthy box).
warn2="$(_proof_cron_legacy_check 2>&1)"
[ -z "$warn2" ] && ok_t "an already-fixed cron produces no warning" \
                || bad_t "an already-fixed cron produces no warning" "warn=<<$warn2>>"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
