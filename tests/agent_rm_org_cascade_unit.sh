#!/usr/bin/env bash
# DIVE-1609 isolated unit for `5dive agent rm` org-chart cascade. No root, no
# systemd, no network — stubs the heavyweight teardown (user deletion, channel
# secrets, systemctl) and drives cmd_rm against a temp registry + temp tasks db.
# Asserts that removing an agent:
#   - drops it from the registry (agents.json)
#   - drops its agents_org row (the DIVE-1609 cascade — used to leak)
#   - reparents its direct reports via ON DELETE SET NULL (no orphan pointer)
#   - clears the failed templated unit (systemctl reset-failed <unit>)
# Run: bash tests/agent_rm_org_cascade_unit.sh
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agent-rm-cascade-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/registry.sh lib/tasks_db.sh cmd_org.sh \
         cmd_agent_lifecycle.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
ENV_DIR="$TMP/env"
REGISTRY="$TMP/registry.json"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$ENV_DIR" "$TASKS_DIR"
set +e

# --- test seams: neuter root-only / host-only teardown -----------------------
ensure_state() { :; }                              # no require_root / chown
registry_write() { cat > "$REGISTRY"; }            # plain file, no chown
remove_channel_secret() { :; }
delete_agent_user() { :; }
paperclip_unseed_for_profile() { :; }
# record systemctl invocations so we can assert reset-failed ran
SYSCTL_LOG="$TMP/systemctl.log"
: > "$SYSCTL_LOG"
systemctl() { printf '%s\n' "$*" >> "$SYSCTL_LOG"; return 0; }

tasks_db_init

# Seed registry with two agents (agy reports up to creative).
cat > "$REGISTRY" <<'JSON'
{"schemaVersion":2,"agents":{"agy":{"type":"claude"},"creative":{"type":"claude"},"kidreports":{"type":"claude"}}}
JSON
# Seed org chart: creative at top, agy + kidreports report to agy.
db "INSERT OR IGNORE INTO agents_org (name) VALUES ('creative'),('agy'),('kidreports');"
db "UPDATE agents_org SET reports_to='creative' WHERE name='agy';"
db "UPDATE agents_org SET reports_to='agy' WHERE name='kidreports';"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# DIVE-4562: the memory-consolidation scheduler's per-seat files. The
# not-transacting counter is cleared ONLY by a pass that gets through, and only
# an enrolled seat ever gets a pass — so a seat removed while its distiller was
# being refused used to leave behind a counter nothing could clear, and
# `5dive doctor --category=memory` would name a seat nobody can restore, forever.
# `creative` is the control: it is not the seat being removed and its files must
# survive, or the cleanup is a wipe rather than a cleanup.
mkdir -p "$STATE_DIR/memory-consolidate"
printf '63\n' > "$STATE_DIR/memory-consolidate/agy.notx"
printf '1\n'  > "$STATE_DIR/memory-consolidate/agy.stamp"
printf '63\n' > "$STATE_DIR/memory-consolidate/creative.notx"

# --- exercise ----------------------------------------------------------------
cmd_rm agy >"$TMP/out" 2>"$TMP/err"

# 1. gone from registry
gone_reg=$(jq -r '.agents.agy // "ABSENT"' "$REGISTRY")
[[ "$gone_reg" == "ABSENT" ]] \
  && ok_t "agent rm drops the registry entry" \
  || bad_t "registry entry survived" "got: $gone_reg :: $(cat "$TMP/err")"

# 2. gone from agents_org (the DIVE-1609 cascade)
gone_org=$(db "SELECT COUNT(*) FROM agents_org WHERE name='agy';")
[[ "$gone_org" == "0" ]] \
  && ok_t "agent rm cascades the agents_org row" \
  || bad_t "agents_org row orphaned" "count=$gone_org"

# 3. direct report reparented (reports_to -> NULL), not left dangling at 'agy'
child_mgr=$(db "SELECT COALESCE(reports_to,'(top)') FROM agents_org WHERE name='kidreports';")
[[ "$child_mgr" == "(top)" ]] \
  && ok_t "ON DELETE SET NULL reparents the removed agent's reports" \
  || bad_t "child still points at removed manager" "reports_to=$child_mgr"

# 4. failed unit cleared
grep -q "reset-failed 5dive-agent@agy.service" "$SYSCTL_LOG" \
  && ok_t "agent rm reset-failed the templated unit" \
  || bad_t "reset-failed not issued" "$(cat "$SYSCTL_LOG")"

# 5. DIVE-2138: the JSON receipt must actually PARSE. `ok()` runs jq and returns
#    0 whatever jq says, so a filter that fails to compile prints nothing to
#    stdout, writes a compile error to stderr nobody reads, and every other
#    assertion here still passes. Caught exactly that (an unparenthesised `+` in
#    an object value) — so assert on stdout, not on the exit status.
if jq -e . "$TMP/out" >/dev/null 2>&1; then
  ok_t "agent rm emits a receipt that is valid JSON"
  disp=$(jq -r '.data.home.disposition // "MISSING"' "$TMP/out")
  [[ "$disp" != "MISSING" ]] \
    && ok_t "the receipt reports the home disposition (DIVE-2138)" \
    || bad_t "receipt has no home disposition" "$(cat "$TMP/out")"
else
  bad_t "agent rm receipt is not valid JSON" \
        "stdout=[$(cat "$TMP/out")] stderr=[$(tail -2 "$TMP/err")]"
fi

# 6. DIVE-4562: the removed seat's consolidation counter and cadence stamp go
#    with it. Without this, the alarm added for DIVE-4562 wedges permanently on
#    a name nobody can restore — and that is likeliest during a fleet-wide auth
#    lapse, when several seats are refusing at once and one gets removed.
[[ -e "$STATE_DIR/memory-consolidate/agy.notx" ]] \
  && bad_t "agent rm left the not-transacting counter behind (DIVE-4562)" \
  || ok_t "agent rm removes the seat's not-transacting counter (DIVE-4562)"
[[ -e "$STATE_DIR/memory-consolidate/agy.stamp" ]] \
  && bad_t "agent rm left the consolidation cadence stamp behind" \
  || ok_t "and its consolidation cadence stamp"
# CONTROL — it removes THIS seat's files and nobody else's. A cleanup that wiped
# the directory would pass both arms above while deleting the fleet's signal.
[[ -e "$STATE_DIR/memory-consolidate/creative.notx" ]] \
  && ok_t "CONTROL: another seat's counter is untouched" \
  || bad_t "CONTROL: agent rm wiped a seat it was not removing"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
