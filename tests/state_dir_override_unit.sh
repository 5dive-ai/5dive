#!/usr/bin/env bash
# DIVE-1361 — built-binary state isolation for mutating smoke tests.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/5dive"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0

ok_t() { echo "  ok  $1"; PASS=$((PASS+1)); }
bad_t() { echo "  FAIL $1${2:+ — $2}"; FAIL=$((FAIL+1)); }

echo "== state-dir override gate =="

# The production invariant stays explicit and true at runtime: an inherited
# value is overwritten, not used as a fallback.
resolved=$(STATE_DIR="$TMP/poison" bash -c 'source "$1"; printf "%s" "$STATE_DIR"' \
  _ "$ROOT/src/header.sh")
if [[ "$resolved" == "/var/lib/5dive" ]] \
   && grep -q '^STATE_DIR="/var/lib/5dive"$' "$ROOT/src/header.sh" \
   && ! grep -Eq 'STATE_DIR="\$\{STATE_DIR[:-]' "$ROOT/src/header.sh"; then
  ok_t "bare STATE_DIR remains ignored"
else
  bad_t "bare STATE_DIR remains ignored"
fi

denied="$TMP/denied"
set +e
out=$("$BIN" --json --state-dir="$denied" task add "must not land" --no-verify 2>/dev/null)
rc=$?
set -e
if [[ $rc -eq 2 ]] && [[ ! -e "$denied" ]] \
   && jq -e '.ok == false and .error.code == 2' <<<"$out" >/dev/null 2>&1; then
  ok_t "override without sentinel fails before mutation"
else
  bad_t "override without sentinel fails before mutation" "rc=$rc out=$out"
fi

set +e
out=$(FIVE_ALLOW_STATE_OVERRIDE=1 "$BIN" --state-dir=relative task ls --json 2>/dev/null)
rc=$?
set -e
if [[ $rc -eq 2 ]] && jq -e '.error.code == 2' <<<"$out" >/dev/null 2>&1; then
  ok_t "relative override is rejected"
else
  bad_t "relative override is rejected" "rc=$rc out=$out"
fi

set +e
out=$(FIVE_ALLOW_STATE_OVERRIDE=1 "$BIN" --state-dir=/var/lib/5dive/../5dive task ls --json 2>/dev/null)
rc=$?
set -e
if [[ $rc -eq 2 ]] && jq -e '.error.code == 2' <<<"$out" >/dev/null 2>&1; then
  ok_t "production path aliases are rejected"
else
  bad_t "production path aliases are rejected" "rc=$rc out=$out"
fi

ln -s /var/lib/5dive "$TMP/prod-link"
set +e
out=$(FIVE_ALLOW_STATE_OVERRIDE=1 "$BIN" --state-dir="$TMP/prod-link" task ls --json 2>/dev/null)
rc=$?
set -e
if [[ $rc -eq 2 ]] && jq -e '.error.code == 2' <<<"$out" >/dev/null 2>&1; then
  ok_t "symlink aliases of the production store are rejected"
else
  bad_t "symlink aliases of the production store are rejected" "rc=$rc out=$out"
fi

escape_store="$TMP/escape-store"
mkdir -p "$escape_store"
ln -s /var/lib/5dive/tasks "$escape_store/tasks"
set +e
out=$(FIVE_ALLOW_STATE_OVERRIDE=1 "$BIN" --state-dir="$escape_store" task ls --json 2>/dev/null)
rc=$?
set -e
if [[ $rc -eq 3 ]] && jq -e '.error.code == 3' <<<"$out" >/dev/null 2>&1; then
  ok_t "tasks symlink escape is rejected at use"
else
  bad_t "tasks symlink escape is rejected at use" "rc=$rc out=$out"
fi

store="$TMP/store"
out=$(FIVE_ALLOW_STATE_OVERRIDE=1 "$BIN" task add "isolated built-binary smoke" \
  --state-dir="$store" --no-verify --json 2>/dev/null)
if jq -e '.ok == true and (.data.ident | startswith("DIVE-"))' <<<"$out" >/dev/null 2>&1 \
   && [[ -f "$store/tasks/tasks.db" ]]; then
  ok_t "built binary mutates a fresh non-root isolated store"
else
  bad_t "built binary mutates a fresh non-root isolated store" "out=$out"
fi

out=$(FIVE_ALLOW_STATE_OVERRIDE=1 "$BIN" --state-dir="$store" task ls --all --json 2>/dev/null)
if jq -e '.ok == true and ([.data.tasks[].title] | index("isolated built-binary smoke") != null)' \
     <<<"$out" >/dev/null 2>&1; then
  ok_t "isolated row is readable on the next invocation"
else
  bad_t "isolated row is readable on the next invocation" "out=$out"
fi

if [[ ! -e "$store/agents.json" ]] && [[ ! -e "$store/agent-audit.log" ]]; then
  ok_t "task smoke creates no unrelated registry or audit files"
else
  bad_t "task smoke creates no unrelated registry or audit files"
fi

printf 'state-dir override: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
