#!/usr/bin/env bash
# DIVE-1888 isolated unit harness for proof.json PERSISTENCE.
#
# The bug this locks down: every write to ${STATE_DIR}/proof.json failed for two
# weeks and every command still returned 0. Two independent silent failures —
# the lastPublished stamp sat behind a `[ -w ]` guard that skipped the write
# with NO output, and the other sites let the redirection error escape to a log
# and then `|| true`'d the exit code back to success. Root cause was a
# permission (state dir root-owned, no group write, publisher running non-root).
#
# Asserts:
#   - a writable dir persists via atomic tmp+rename, leaving no .tmp residue,
#   - an UNWRITABLE dir with a writable FILE still persists (truncate in place) —
#     the fallback that lets a locked-down state dir keep working,
#   - neither writable => NON-ZERO exit AND a loud stderr message (never silent),
#   - an existing file's mode survives a rewrite (a root-run write must not strip
#     the group-write bit the non-root publisher depends on),
#   - `proof status` says the state is unwritable instead of implying "never
#     published", and --json exposes stateWritable,
#   - source-level guard: no proof.json write site is `|| true`'d back to success
#     and the `[ -w ]` skip-guard is gone,
#   - the payload builder stamps publishedBy {host,user} into zero-human.json AND
#     the append-only history row, and omits it when unset (harness back-compat).
#
# Run: bash tests/proof_state_persist_unit.sh   (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/proof-state.XXXXXX)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
skip_t() { SKIP=$((SKIP+1)); printf 'skip - %s (%s)\n' "$1" "${2:-}"; }

# Perms are meaningless to root: it can write a 0500 dir, so the two
# unwritable-path cases cannot be exercised. Everything else still runs.
ROOTISH=0; [ "$(id -u)" = 0 ] && ROOTISH=1

# --- stub the deps cmd_proof.sh reaches for, then source it ------------------
E_USAGE=2; E_GENERIC=1
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
_PROOF_CRON="$TMP/cron"
JSON_MODE=0
require_root() { :; }
fail() { echo "fail($1): $2" >&2; exit "$1"; }
db() { echo ""; }                       # no tasks db: the ledger reads 0 shipped
sqlq() { printf "'%s'" "$1"; }
# shellcheck disable=SC1091
source src/cmd_proof.sh

PREF="$STATE_DIR/proof.json"

# --- Case 1: writable dir -> atomic rename, no residue -----------------------
printf '{"enabled":true,"branch":"status"}\n' > "$PREF"
if _proof_pref_write --arg d "2026-07-25" '.lastPublished=$d' 2>"$TMP/e1"; then
  got="$(jq -r '.lastPublished' "$PREF" 2>/dev/null)"
  [ "$got" = "2026-07-25" ] && ok_t "writable dir persists lastPublished" \
    || bad_t "writable dir persists lastPublished" "got '$got'"
else
  bad_t "writable dir persists lastPublished" "_proof_pref_write returned non-zero: $(cat "$TMP/e1")"
fi
residue="$(find "$STATE_DIR" -name 'proof.json.tmp*' 2>/dev/null | wc -l)"
[ "$residue" = 0 ] && ok_t "no .tmp residue left behind" || bad_t "no .tmp residue left behind" "$residue file(s)"
[ "$(_proof_state_writable)" = "dir" ] && ok_t "_proof_state_writable reports 'dir'" \
  || bad_t "_proof_state_writable reports 'dir'" "got '$(_proof_state_writable)'"

# --- Case 2: existing mode survives a rewrite --------------------------------
# The regression this blocks: a root-run write that recreates the file at 0600
# silently locks the non-root publisher back out — the original bug, restored.
chmod 0664 "$PREF"
_proof_pref_write '.enabled=true' >/dev/null 2>&1
mode="$(stat -c '%a' "$PREF" 2>/dev/null)"
[ "$mode" = "664" ] && ok_t "file mode survives a rewrite (group-write preserved)" \
  || bad_t "file mode survives a rewrite (group-write preserved)" "mode is now $mode, expected 664"

# --- Case 3: dir NOT writable, file IS -> truncate-in-place still persists ---
if [ "$ROOTISH" = 1 ]; then
  skip_t "unwritable dir + writable file still persists" "running as root; perms do not apply"
  skip_t "_proof_state_writable reports 'file'" "running as root"
else
  chmod 0500 "$STATE_DIR"
  [ "$(_proof_state_writable)" = "file" ] && ok_t "_proof_state_writable reports 'file'" \
    || bad_t "_proof_state_writable reports 'file'" "got '$(_proof_state_writable)'"
  if _proof_pref_write --arg d "2026-07-26" '.lastPublished=$d' 2>"$TMP/e3"; then
    got="$(jq -r '.lastPublished' "$PREF" 2>/dev/null)"
    [ "$got" = "2026-07-26" ] && ok_t "unwritable dir + writable file still persists" \
      || bad_t "unwritable dir + writable file still persists" "got '$got'"
  else
    bad_t "unwritable dir + writable file still persists" "returned non-zero: $(cat "$TMP/e3")"
  fi
  chmod 0700 "$STATE_DIR"
fi

# --- Case 4: nothing writable -> LOUD failure, never a silent success --------
if [ "$ROOTISH" = 1 ]; then
  skip_t "unwritable state fails loudly" "running as root; perms do not apply"
else
  chmod 0400 "$PREF"; chmod 0500 "$STATE_DIR"
  [ -z "$(_proof_state_writable)" ] && ok_t "_proof_state_writable reports '' when locked" \
    || bad_t "_proof_state_writable reports '' when locked" "got '$(_proof_state_writable)'"
  rc=0; _proof_pref_write '.enabled=false' 2>"$TMP/e4" || rc=$?
  [ "$rc" -ne 0 ] && ok_t "locked state write returns NON-ZERO" \
    || bad_t "locked state write returns NON-ZERO" "returned 0 — this is the original bug"
  if grep -q "CANNOT PERSIST STATE" "$TMP/e4" && grep -q "chmod g+w" "$TMP/e4"; then
    ok_t "locked state write explains itself and prints the fix"
  else
    bad_t "locked state write explains itself and prints the fix" "stderr was: $(cat "$TMP/e4")"
  fi
  # `proof status` must not let "last published: never" stand unqualified.
  out="$( _proof_onoff status 2>&1 )"
  grep -q "NOT writable" <<<"$out" && ok_t "proof status flags the unwritable state" \
    || bad_t "proof status flags the unwritable state" "status said: $out"
  jout="$( JSON_MODE=1 _proof_onoff status 2>/dev/null )"
  [ "$(jq -r '.stateWritable' <<<"$jout" 2>/dev/null)" = "false" ] \
    && ok_t "proof status --json exposes stateWritable=false" \
    || bad_t "proof status --json exposes stateWritable=false" "json was: $jout"
  chmod 0700 "$STATE_DIR"; chmod 0644 "$PREF"
fi

# --- Case 5: source-level guards ---------------------------------------------
# The `[ -w … ] || [ -w … ]` guard around the lastPublished stamp is what made
# the failure invisible; it must not come back.
if grep -q '\[ -w "\$(dirname "\$f")" \]' src/cmd_proof.sh; then
  bad_t "the silent [ -w ] skip-guard is gone" "src/cmd_proof.sh still guards the stamp"
else
  ok_t "the silent [ -w ] skip-guard is gone"
fi
# No proof.json write may end in `|| true` (success regardless of outcome).
# Comment lines are excluded — the fix's own commentary quotes the old pattern.
_tmp_writes() { grep -nE 'f\.tmp' src/cmd_proof.sh | grep -vE '^[0-9]+:[[:space:]]*#'; }
if _tmp_writes | grep -q '|| true'; then
  bad_t "no proof.json write is '|| true'd back to success" "$(_tmp_writes | grep '|| true')"
else
  ok_t "no proof.json write is '|| true'd back to success"
fi
# The cron driver must not swallow stderr, or every loud message dies there.
# Comment lines excluded — the fix's own commentary quotes the old body.
if grep -n '_proof_publish >/dev/null 2>&1' src/cmd_proof.sh | grep -vqE '^[0-9]+:[[:space:]]*#'; then
  bad_t "proof tick lets stderr reach the log" "tick still redirects 2>&1 to /dev/null"
else
  ok_t "proof tick lets stderr reach the log"
fi

# --- Case 5b: the tick's EXIT CODE is loud too ------------------------------
# Freeing stderr is not enough on its own: the tick's log target may be
# unreadable or absent (on this box /var/log/5dive-proof.log is root:root and
# the tick has no live caller at all), so the exit code has to carry the signal.
printf '{"enabled":true}\n' > "$PREF"
_proof_publish() { return 7; }              # stub: publish failed
rc=0; _proof_tick >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 7 ] && ok_t "proof tick propagates a publish failure in its exit code" \
  || bad_t "proof tick propagates a publish failure in its exit code" "got rc=$rc, expected 7"
_proof_publish() { return 3; }              # stub: already published today
rc=0; _proof_tick >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok_t "proof tick maps 'already published today' (3) to success" \
  || bad_t "proof tick maps 'already published today' (3) to success" "got rc=$rc"
printf '{"enabled":false}\n' > "$PREF"
_proof_publish() { return 7; }
rc=0; _proof_tick >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok_t "proof tick is a no-op (0) when publishing is disabled" \
  || bad_t "proof tick is a no-op (0) when publishing is disabled" "got rc=$rc"
unset -f _proof_publish

# --- Case 5c: the cron's log target is PROVEN, not assumed -------------------
# The cron line redirects as ${user}, and the shell opens that file BEFORE
# /usr/local/bin/5dive runs — an unwritable target kills the command before the
# publisher ever starts. Same shape as the DIVE-1896 monitor failure.
if [ -d /etc/cron.d ]; then
  _PROOF_LOG="$TMP/proof-cron.log"; _PROOF_CRON="$TMP/cron"
  rm -f "$_PROOF_LOG" "$_PROOF_CRON"
  _proof_install_cron 9 "$(id -un)" 2>/dev/null
  [ -f "$_PROOF_LOG" ] && ok_t "cron install creates its log target instead of assuming it" \
    || bad_t "cron install creates its log target instead of assuming it" "$_PROOF_LOG absent"
  grep -q "$_PROOF_LOG" "$_PROOF_CRON" 2>/dev/null \
    && ok_t "the installed cron line redirects to that same proven path" \
    || bad_t "the installed cron line redirects to that same proven path" "$(cat "$_PROOF_CRON" 2>/dev/null)"
  # An unwritable destination must WARN, not install silently.
  _PROOF_LOG="/proc/definitely-not-writable/proof.log"
  err="$(_proof_install_cron 9 "$(id -un)" 2>&1 >/dev/null)"
  grep -q "cannot create" <<<"$err" && ok_t "an unwritable cron log warns loudly" \
    || bad_t "an unwritable cron log warns loudly" "stderr was: $err"
else
  skip_t "cron log target is proven, not assumed" "/etc/cron.d absent"
  skip_t "installed cron line redirects to the proven path" "/etc/cron.d absent"
  skip_t "an unwritable cron log warns loudly" "/etc/cron.d absent"
fi

# --- Case 6: the payload carries a publisher IDENTITY ------------------------
# cliVersion DATES the artifact; it does not identify the machine that wrote it.
awk "/python3 <<'PROOFPY'/{f=1;next} f&&/^PROOFPY\$/{f=0} f" src/cmd_proof.sh > "$TMP/proof.py"
[ -s "$TMP/proof.py" ] || bad_t "extract payload builder" "empty"
WD="$TMP/wd"; mkdir -p "$WD"
run_build() { # <extra env assignments via caller env> ; runs in $WD
  ( cd "$WD" && \
    DAY_JSON='{"zeroHuman":{"shipped":5,"humanTouches":1}}' \
    WEEK_JSON='{"zeroHuman":{"shipped":5,"humanTouches":1}}' \
    TODAY="$1" TODAY_LABEL="Jul 25" NOW_ISO="${1}T00:00:00Z" \
    CLI_VERSION="0.14.9" METHODOLOGY_URL="https://example.test/zero-human.md" \
    python3 "$TMP/proof.py" >/dev/null 2>&1 )
}
PUB_HOST="box-42" PUB_USER="claude" run_build "2026-07-25"
host="$(jq -r '.publishedBy.host // empty' "$WD/zero-human.json" 2>/dev/null)"
user="$(jq -r '.publishedBy.user // empty' "$WD/zero-human.json" 2>/dev/null)"
{ [ "$host" = "box-42" ] && [ "$user" = "claude" ]; } \
  && ok_t "zero-human.json stamps publishedBy {host,user}" \
  || bad_t "zero-human.json stamps publishedBy {host,user}" "got host='$host' user='$user'"
hhost="$(jq -r 'select(.date=="2026-07-25") | .publishedBy.host // empty' "$WD/history.jsonl" 2>/dev/null)"
[ "$hhost" = "box-42" ] && ok_t "history.jsonl row stamps publishedBy (attributable audit trail)" \
  || bad_t "history.jsonl row stamps publishedBy (attributable audit trail)" "got '$hhost'"
# Unset => omitted entirely, so the existing unit harness and older readers are
# unaffected (the zero-human.json contract is additive-only).
run_build "2026-07-26"
if jq -e 'has("publishedBy")' "$WD/zero-human.json" >/dev/null 2>&1; then
  bad_t "publishedBy omitted when host/user unknown" "key present with no source"
else
  ok_t "publishedBy omitted when host/user unknown"
fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
