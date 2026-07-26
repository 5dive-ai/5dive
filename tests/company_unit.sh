#!/usr/bin/env bash
# OSS-34 isolated unit harness for `5dive company` — the onboarding-wizard sugar.
#
# The wizard is a thin macro over `project add` + `objective add` (+ `goal add`).
# This harness drives the non-interactive `--yes` path (the interactive prompts
# are just _init_* UI over the same variables) against a throwaway STATE_DIR, so
# it never touches the live shared tasks.db. Asserts: --yes stands up BOTH the
# project and the objective in one call, key/prefix are derived from the name,
# explicit flags override the derivation, essentials are required, a bad prefix
# is rejected, and re-running against an existing project reuses it.
# Run: bash tests/company_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/company-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_objective.sh \
         cmd_init.sh cmd_company.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests deliberately expect non-zero exits

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run()   { ( "$@" ) 2>/dev/null; }

# ---- (1) --yes happy path: one call stands up project + objective ----
out=$(run cmd_company --yes --name="Acme Robotics" \
        --objective="grow signups" --metric-cmd="echo 42" --target=100 --direction=up); rc=$?
[[ $rc -eq 0 ]] \
  && printf '%s' "$out" | jq -e '.data.project=="acme-robotics" and .data.prefix=="ACME" and .data.objective=="grow signups"' >/dev/null \
  && ok_t "company --yes creates project + objective, key/prefix derived from name" \
  || bad_t "company --yes happy path" "$out"

# the project actually exists in the store
[[ "$(db "SELECT 1 FROM projects WHERE key='acme-robotics';")" == "1" ]] \
  && ok_t "project row persisted" || bad_t "project row persisted"
# the objective actually exists and is bound to the metric + project
[[ "$(db "SELECT project_key FROM objectives WHERE name='grow signups';")" == "acme-robotics" ]] \
  && ok_t "objective persisted under the project" || bad_t "objective persisted under the project"

# ---- (2) explicit --key/--prefix override the name-derived slug ----
out=$(run cmd_company --yes --name="Widget Co" --key=widgets --prefix=WGT \
        --objective="cut churn" --metric-cmd="echo 5" --target=2 --direction=down --unit=%); rc=$?
[[ $rc -eq 0 ]] \
  && printf '%s' "$out" | jq -e '.data.project=="widgets" and .data.prefix=="WGT"' >/dev/null \
  && ok_t "explicit --key/--prefix override the derived slug" || bad_t "explicit override" "$out"
[[ "$(db "SELECT direction FROM objectives WHERE name='cut churn';")" == "down" ]] \
  && ok_t "direction=down stored" || bad_t "direction=down stored"

# ---- (3) --yes requires the essentials ----
run cmd_company --yes --name="No Metric Inc" --objective="x" >/dev/null 2>&1
[[ $? -ne 0 ]] && ok_t "missing --metric-cmd is rejected" || bad_t "missing --metric-cmd is rejected"
run cmd_company --yes --metric-cmd="echo 1" --objective="x" >/dev/null 2>&1
[[ $? -ne 0 ]] && ok_t "missing --name is rejected" || bad_t "missing --name is rejected"

# ---- (4) a bad prefix is rejected (not silently coerced) ----
run cmd_company --yes --name="Bad" --prefix="bad1" \
    --objective="x" --metric-cmd="echo 1" --target=1 >/dev/null 2>&1
[[ $? -ne 0 ]] && ok_t "lowercase/numeric prefix rejected" || bad_t "bad prefix rejected"

# ---- (5) bare --yes with no TTY and no flags fails clearly (no silent noop) ----
run cmd_company --yes </dev/null >/dev/null 2>&1
[[ $? -ne 0 ]] && ok_t "--yes with no flags fails (essentials required)" || bad_t "--yes no flags fails"

# ---- (6) re-running against an existing project reuses it (no dup-project error) ----
out=$(run cmd_company --yes --name="Acme Robotics" --key=acme-robotics --prefix=ACME \
        --objective="second objective" --metric-cmd="echo 7" --target=9 --direction=up); rc=$?
[[ $rc -eq 0 ]] \
  && [[ "$(db "SELECT COUNT(*) FROM objectives WHERE project_key='acme-robotics';")" == "2" ]] \
  && ok_t "re-run reuses existing project, adds a second objective" || bad_t "re-run reuses project" "$out"

echo
printf 'company_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
