#!/usr/bin/env bash
# DIVE-4973 — `agent install <type> --detach` / `--status`.
#
# The wizard ran a cold install as ONE blocking exec that the api and shelld kill
# at 300s, and hermes' cold install went to 272-321s. `--detach` hands the same
# install to its own transient unit and returns at once; `--status` is what the
# wizard polls. The arms pin the three things that make that safe:
#   - the install runs ONLY through systemd-run (a setsid'd child would stay in
#     shelld's cgroup and die on its next restart — DIVE-4886), with a hard
#     RuntimeMaxSec so a hung installer ends as `failed`;
#   - a retry while a job is running joins it, never starts a second installer;
#   - --status tells running / installed / failed / interrupted / idle apart, and
#     a failed job carries its log tail.
# systemd-run and systemctl are PATH stubs; the "unit" is a background process
# whose liveness is a marker file. The job re-invokes the CLI through
# FIVE_INSTALL_SELF, pointed at a fixture that plays the install.
#
# Run: bash tests/install_detach_job_unit.sh (no root, no network, ~5s)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# shellcheck disable=SC2154  # rc is assigned inside the trap string
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"

PASS=0; FAIL=0
check() { # check <label> <condition-rc> [detail]
  if [[ "$2" -eq 0 ]]; then PASS=$((PASS+1)); echo "ok   $1"
  else FAIL=$((FAIL+1)); echo "FAIL $1${3:+ — $3}" >&2; fi
}

mkdir -p "$TMP/stubs"
# systemctl: is-active reads the marker the fake unit holds; reset-failed is a no-op.
cat >"$TMP/stubs/systemctl" <<STUB
#!/usr/bin/env bash
case "\$1" in
  is-active) for u in "\$@"; do :; done; [[ -f "$TMP/active-\$u" ]] ;;
  *) exit 0 ;;
esac
STUB
# systemd-run: record argv, then run everything after `--` in the background as
# the "unit", holding the marker while it runs. SDRUN_MODE=refuse fails the call;
# SDRUN_MODE=inert records and starts nothing.
cat >"$TMP/stubs/systemd-run" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$TMP/sdrun-argv"
echo call >>"$TMP/sdrun-calls"
[[ "\${SDRUN_MODE:-}" == refuse ]] && { echo "Unit already exists" >&2; exit 1; }
[[ "\${SDRUN_MODE:-}" == inert ]] && exit 0
unit=""
while [[ \$# -gt 0 && "\$1" != -- ]]; do [[ "\$1" == --unit=* ]] && unit="\${1#--unit=}"; shift; done
shift
touch "$TMP/active-\$unit"
( "\$@"; rm -f "$TMP/active-\$unit" ) </dev/null >/dev/null 2>&1 &
exit 0
STUB
# The CLI the job re-invokes: FAKE_MODE ok|fail, FAKE_SLEEP seconds.
cat >"$TMP/fake-5dive" <<STUB
#!/usr/bin/env bash
echo "\$*" >"$TMP/job-argv"
sleep "\${FAKE_SLEEP:-0}"
if [[ "\${FAKE_MODE:-ok}" == fail ]]; then echo "npm ERR! boom while building the TUI"; exit 1; fi
mkdir -p "$TMP/bin" && printf '#!/bin/sh\n' >"$TMP/bin/hermes" && chmod +x "$TMP/bin/hermes"
echo '{"ok":true,"data":{"type":"hermes","installed":true}}'
STUB
# sudo: record argv; the recipe hop (bash -lc) "installs" the binary. Only the
# blocking path reaches sudo — the detached path hands off before it.
cat >"$TMP/stubs/sudo" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/sudo-argv"
for a in "\$@"; do
  [[ "\$a" == -lc ]] && { mkdir -p "$TMP/bin"; printf '#!/bin/sh\n' >"$TMP/bin/hermes"; chmod +x "$TMP/bin/hermes"; exit 0; }
done
exit 0
STUB
chmod +x "$TMP/stubs/"* "$TMP/fake-5dive"

# install <args...> — run cmd_install in a subshell (fail exits); sets OUT RC MS.
install() {
  local t0; t0=$(date +%s%3N)
  OUT=$(
    export PATH="$TMP/stubs:$PATH"
    # shellcheck disable=SC1091
    source "$ROOT/src/header.sh"
    # shellcheck disable=SC1091
    source "$ROOT/src/lib/error_codes.sh"
    # shellcheck disable=SC1091
    source "$ROOT/src/lib/output.sh"
    # shellcheck disable=SC1091
    source "$ROOT/src/lib/validation.sh"
    # shellcheck disable=SC1091
    source "$ROOT/src/cmd_auth.sh"
    # env_isolation's sudo guard refuses REAL sudo (PAM re-reads FIVE_* knobs).
    # Here sudo resolves to the recording stub, which never reaches PAM, so the
    # guard is lifted only once that is proven.
    [[ "$(type -P sudo)" == "$TMP/stubs/sudo" ]] && unset -f sudo
    set +e
    # shellcheck disable=SC2034,SC2154  # all read by the sourced cmd_install
    JSON_MODE=1 INSTALL_JOB_DIR="$TMP/jobs" FIVE_INSTALL_SELF="$TMP/fake-5dive" TYPE_BIN[hermes]="$TMP/bin/hermes"
    cmd_install "$@" 2>/dev/null
  ) && RC=0 || RC=$?
  MS=$(( $(date +%s%3N) - t0 ))
  OUT=$(printf '%s\n' "$OUT" | grep '^{' | tail -1)
}
j() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
wait_idle() { local w=0; while ls "$TMP"/active-* >/dev/null 2>&1 && (( w < 60 )); do sleep 0.1; w=$((w+1)); done; }
reset() { wait_idle; rm -rf "${TMP:?}/jobs" "${TMP:?}/bin" "$TMP"/sdrun-* "$TMP/sudo-argv" "$TMP/job-argv" "$TMP"/active-*; }

# --- 1. a fresh detach returns while the install is still running -----------
reset
export FAKE_SLEEP=2 FAKE_MODE=ok
install hermes --detach
check "detach: exits 0 with started:true, state running" \
  "$([[ $RC -eq 0 && "$(j .data.started)" == true && "$(j .data.state)" == running && "$(j .data.detached)" == true ]]; echo $?)" "rc=$RC out=$OUT"
check "detach: returns before the 2s install finishes (${MS}ms)" "$( (( MS < 1500 )); echo $?)"
argv=$(cat "$TMP/sdrun-argv" 2>/dev/null)
check "detach: the job runs in its own unit 5dive-install-hermes, collected" \
  "$(grep -qx -- '--unit=5dive-install-hermes' <<<"$argv" && grep -qx -- '--collect' <<<"$argv"; echo $?)" "$argv"
check "detach: the unit carries the hard bound RuntimeMaxSec=900" \
  "$(grep -qx -- '--property=RuntimeMaxSec=900' <<<"$argv"; echo $?)"
check "detach: the unit tells the job it is inside the unit (FIVE_INSTALL_IN_UNIT=1)" \
  "$(grep -qx -- '--setenv=FIVE_INSTALL_IN_UNIT=1' <<<"$argv"; echo $?)" "$argv"

# --- 2. status while running, and a retry joins the running job --------------
install hermes --status
check "status: running while the unit is active" "$([[ "$(j .data.state)" == running && "$(j .data.installed)" == false ]]; echo $?)" "$OUT"
install hermes --detach
check "retry: joins the running job (started:false)" "$([[ $RC -eq 0 && "$(j .data.started)" == false && "$(j .data.state)" == running ]]; echo $?)" "$OUT"
check "retry: systemd-run was not called a second time" "$([[ $(wc -l <"$TMP/sdrun-calls") -eq 1 ]]; echo $?)"

# --- 3. the job finishes: installed ------------------------------------------
wait_idle
check "job: re-invoked the CLI as 'agent install hermes --json'" "$([[ "$(cat "$TMP/job-argv" 2>/dev/null)" == "agent install hermes --json" ]]; echo $?)" "$(cat "$TMP/job-argv" 2>/dev/null)"
install hermes --status
check "status: installed after a clean exit (exitCode 0)" \
  "$([[ "$(j .data.state)" == installed && "$(j .data.installed)" == true && "$(j .data.exitCode)" == 0 && "$(j .data.finishedAt)" != null ]]; echo $?)" "$OUT"

# --- 4. a failed job carries its exit code and log tail ----------------------
reset
export FAKE_SLEEP=0 FAKE_MODE=fail
install hermes --detach
wait_idle
install hermes --status
check "status: failed after a non-zero exit (exitCode 1)" "$([[ "$(j .data.state)" == failed && "$(j .data.exitCode)" == 1 ]]; echo $?)" "$OUT"
check "status: the failure carries the install's log tail" "$(grep -q 'boom while building' <<<"$(j .data.logTail)"; echo $?)"

# --- 5. a job that died before its exit line reads as interrupted ------------
reset
mkdir -p "$TMP/jobs"
echo '{"type":"hermes","state":"running","exitCode":null}' >"$TMP/jobs/hermes.status"
install hermes --status
check "status: 'running' with no live unit reads as failed/interrupted" \
  "$([[ "$(j .data.state)" == failed ]] && grep -q interrupted <<<"$(j .data.message)"; echo $?)" "$OUT"

# --- 6. nothing ran: idle; already installed: short-circuit ------------------
reset
install hermes --status
check "status: idle when no job ran and nothing is installed" "$([[ $RC -eq 0 && "$(j .data.state)" == idle ]]; echo $?)" "$OUT"
mkdir -p "$TMP/bin" && printf '#!/bin/sh\n' >"$TMP/bin/hermes" && chmod +x "$TMP/bin/hermes"
install hermes --detach
check "detach: an installed type answers alreadyInstalled and starts no job" \
  "$([[ "$(j .data.alreadyInstalled)" == true && ! -f "$TMP/sdrun-calls" ]]; echo $?)" "$OUT"

# --- 7. refusals -------------------------------------------------------------
reset
install hermes --detach --status
check "--detach with --status is a usage error" "$([[ $RC -eq 2 && "$(j .error.class)" == usage ]]; echo $?)" "rc=$RC $OUT"
SDRUN_MODE=refuse install hermes --detach
check "systemd-run refusing fails the call and leaves no running record" \
  "$([[ $RC -ne 0 && ! -f "$TMP/jobs/hermes.status" ]]; echo $?)" "rc=$RC"

# --- 8. the install is started by systemd-run and by nothing else ------------
# With a systemd-run that records and starts nothing, no install may run: a
# recipe that also forked the job itself (setsid/nohup) would still leave shelld's
# cgroup untouched and die with it.
reset
export FAKE_SLEEP=0 FAKE_MODE=ok
SDRUN_MODE=inert install hermes --detach
sleep 0.5
check "only systemd-run starts the job (inert systemd-run -> no install ran)" "$([[ ! -f "$TMP/job-argv" ]]; echo $?)"

# --- 9. inside the unit the installer must stay in the unit's cgroup ---------
# sudo -i opens a PAM login session (sudo-i -> common-session -> pam_systemd),
# which moves the installer into a logind scope outside the unit: a stop or
# RuntimeMaxSec then leaves it running (measured on a box, DIVE-4973). The job's
# own run of the recipe must hop WITHOUT -i; the plain blocking path keeps it.
recipe_hop() { grep -F 'hermes-agent.nousresearch.com/install.sh' "$TMP/sudo-argv" 2>/dev/null | head -1; }
reset
FIVE_INSTALL_IN_UNIT=1 install hermes
hop=$(recipe_hop)
check "in unit: the recipe runs as claude with -H and no -i (no login session)" \
  "$([[ $RC -eq 0 && "$hop" == "-u claude -H bash -lc "* && " $hop " != *" -i "* ]]; echo $?)" "rc=$RC hop=$hop"
check "in unit: the recipe still starts from claude's home" "$([[ "$hop" == *"-lc cd ~ && "* ]]; echo $?)" "$hop"
reset
install hermes
hop=$(recipe_hop)
check "blocking path: the recipe hop keeps sudo -i (unchanged outside the unit)" \
  "$([[ $RC -eq 0 && "$hop" == "-u claude -i bash -lc "* ]]; echo $?)" "rc=$RC hop=$hop"

reset
TOTAL=$((PASS+FAIL))
if (( FAIL )); then echo "FAIL: $FAIL of $TOTAL detached-install arms failed"
else echo "PASS: $PASS of $TOTAL detached-install arms"; fi
(( FAIL == 0 && TOTAL > 0 ))
