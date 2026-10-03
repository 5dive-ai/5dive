#!/usr/bin/env bash
# DIVE-5447 — the pinned needs-you banner is OFF unless a seat opts in with
# TELEGRAM_NEEDS_BANNER=1 (lodar, 2026-10-03: "too noisy"). With it off, nobody
# pins by design, so `doctor --category=channels` must not grade a missing
# coordinator as the DIVE-2041 outage on every box. With a seat opted in, the
# DIVE-2041 grading must come back exactly as before.
#
# Every arm drives doctor_check_needs_banner itself against a temp connectors
# dir, a temp agents.d and a stubbed coordinator/db; the off arms are only
# meaningful because the on arms prove the same fixture still reaches the error.
#
# Run: bash tests/doctor_needs_banner_optin_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/doctor-needs-banner.XXXXXX)"
export STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/cmd_doctor.sh
set +e

CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"
ENV_DIR="$TMP/agents.d"; mkdir -p "$ENV_DIR"
TASKS_DB="$TMP/tasks.db"; : > "$TASKS_DB"
step() { :; }

# The DIVE-2041 outage fixture: no coordinator, two org roots, three pending gates.
COORD=''
_task_resolve_coordinator() { printf '%s' "$COORD"; }
db() { case "$1" in *agents_org*) echo 2 ;; *tasks*) echo 3 ;; esac; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
verdict() {
  DOCTOR_CHECKS='[]'
  doctor_check_needs_banner
  jq -r '[.[] | select(.name=="needs-banner-coordinator")] | if length==1 then .[0].severity + "|" + .[0].message else "count=\(length)" end' <<<"$DOCTOR_CHECKS"
}
expect() { # <label> <severity> <message-substring>
  local got; got=$(verdict)
  if [[ "${got%%|*}" == "$2" && "$got" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "got: $got"; fi
}
reset_env() { rm -f "$CONNECTORS_DIR"/* "$ENV_DIR"/*; }

# --- off (the new default) -------------------------------------------------
reset_env
printf 'TELEGRAM_BOT_TOKEN=x\n' > "$CONNECTORS_DIR/telegram-dev.env"
expect 'A1 no seat opted in: the outage fixture reads ok, not error' ok 'is off on this box (DIVE-5447)'
printf 'TELEGRAM_NEEDS_BANNER=0\n' > "$CONNECTORS_DIR/telegram-main.env"
expect 'A2 an explicit =0 is still off' ok 'is off on this box'
printf '# TELEGRAM_NEEDS_BANNER=1\nXTELEGRAM_NEEDS_BANNER=1\n' > "$CONNECTORS_DIR/telegram-ops.env"
expect 'A3 a commented or prefixed line does not opt in' ok 'is off on this box'
printf 'TELEGRAM_NEEDS_BANNER=1\n' > "$CONNECTORS_DIR/discord-dev.env"
expect 'A4 a non-telegram connector env does not opt in' ok 'is off on this box'

# --- on (a seat opted back in) ---------------------------------------------
reset_env
printf 'TELEGRAM_BOT_TOKEN=x\nTELEGRAM_NEEDS_BANNER=1\n' > "$CONNECTORS_DIR/telegram-dev.env"
expect 'B1 opted in via the telegram connector env: the DIVE-2041 error is back' error 'human gate(s) are pending'
reset_env
printf 'TELEGRAM_NEEDS_BANNER="1"\n' > "$ENV_DIR/main.env"
expect 'B2 opted in via agents.d (quoted, as systemd allows): error' error 'human gate(s) are pending'
COORD='main'
expect 'B3 opted in with a coordinator: ok, and it names the owner' ok "resolves to 'main'"
COORD=''

# --- no tasks db: the check stays silent, as before ------------------------
TASKS_DB="$TMP/missing.db"
got=$(DOCTOR_CHECKS='[]'; doctor_check_needs_banner; jq 'length' <<<"$DOCTOR_CHECKS")
[[ "$got" == 0 ]] && ok_t 'C1 no tasks db: no line at all' || bad_t 'C1 no tasks db: no line at all' "got $got"

# --- wiring: the channels category runs the function ----------------------
if grep -qE '^    doctor_check_needs_banner$' src/cmd_doctor.sh; then ok_t 'D1 the channels category calls doctor_check_needs_banner'
else bad_t 'D1 the channels category calls doctor_check_needs_banner'; fi

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
