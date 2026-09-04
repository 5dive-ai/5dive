#!/usr/bin/env bash
# DIVE-3958 unit harness for doctor_seat_claude_pid.
#
# The bug it locks down: `5dive doctor`'s plugin-version check used to find "the
# seat's claude session" with a per-UID `pgrep -f claude`, which on this box
# (install root /home/claude/) matches ANY long-lived process a seat owns whose
# path passes through that dir. On agent-marketing it picked a 46-day-old discord
# welcome_bot.py -> false "stale plugin" WARN -> `--repair` restarted a healthy
# seat forever (the decoy lived in a different systemd unit the restart could not
# reach). The fix scopes to the seat's unit cgroup AND matches the EXECUTABLE
# (comm=claude), not the argv.
#
# No systemd, no cgroup, no real processes: we mock `systemctl` + `ps` and point
# the cgroup base at a temp dir via DOCTOR_CGROUP_BASE.
#
# Run: bash tests/doctor_seat_claude_pid_unit.sh
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: single EXIT trap folds tempdir cleanup into the rc echo so the two EXIT traps do not clobber each other (corpus contract: tests/harness_rc_corpus_contract_unit.sh)
# DIVE-2211/DIVE-3074: name the tree this harness grades. No 2>/dev/null — the
# helper's stderr line IS the payload (see tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

# Pull just the helper out of cmd_doctor.sh (self-contained; avoids the heavy
# deps a full source would drag in).
eval "$(awk '/^doctor_seat_claude_pid\(\) \{/,/^\}/' "$SRC/cmd_doctor.sh")"

TMP=$(mktemp -d)
PASS=0; FAIL=0
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "PASS: $1";
  else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}

export DOCTOR_CGROUP_BASE="$TMP/cg"

# Fixture unit cgroup: a real claude (younger) alongside a 46-day decoy whose
# argv passes through /home/claude/ — the exact agent-marketing shape.
CG="/system.slice/system-5dive\\x2dagent.slice/5dive-agent@marketing.service"
mkdir -p "$TMP/cg$CG"
cat > "$TMP/cg$CG/cgroup.procs" <<'EOF'
100
200
300
EOF

# Mocks. systemctl echoes the unit's ControlGroup; ps answers comm=/etimes= per
# pid. pid 200 is the claude runtime; 100/300 are decoys (older, non-claude).
systemctl() { [[ "$*" == *ControlGroup* ]] && printf '%s\n' "$CG"; }
ps() {
  local pid="${@: -1}"
  case "$1" in
    -o) case "$2" in
          comm=)   case "$pid" in 100) echo python;; 200) echo claude;; 300) echo bash;; *) echo "";; esac ;;
          etimes=) case "$pid" in 100) echo 4038541;; 200) echo 1560;; 300) echo 9000000;; *) echo "";; esac ;;
        esac ;;
  esac
}
export -f systemctl ps

got=$(doctor_seat_claude_pid marketing agent-marketing)
check "picks the claude executable, not the older decoy" "200" "$got"

# MUTATION ARM: if the predicate matched argv (comm test relaxed to always-true),
# the OLDEST proc (300, etimes 9000000) would win — proving the comm match bites.
doctor_seat_claude_pid_MUT() {
  local name="$1" user="$2" cg procs base="${DOCTOR_CGROUP_BASE:-/sys/fs/cgroup}"
  cg=$(systemctl show -p ControlGroup --value "5dive-agent@${name}.service" 2>/dev/null || true)
  [[ -n "$cg" && -r "${base}${cg}/cgroup.procs" ]] || return 0
  procs=$(while read -r p; do
            true || continue   # mutated: drop the comm=claude guard
            printf '%s %s\n' "$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ')" "$p"
          done < "${base}${cg}/cgroup.procs" | sort -rn | awk 'NR==1{print $2}' || true)
  printf '%s' "$procs"
}
mut=$(doctor_seat_claude_pid_MUT marketing agent-marketing)
check "MUTATION: without the comm=claude guard the decoy wins (arm bites)" "300" "$mut"

# Unit-scope: a seat with no claude in its unit (codex-shape) returns nothing, so
# the caller's `[[ -n "$cpid" ]]` guard skips the check instead of false-warning.
cat > "$TMP/cg$CG/cgroup.procs" <<'EOF'
100
300
EOF
got2=$(doctor_seat_claude_pid marketing agent-marketing)
check "no claude runtime in the unit -> empty (check is skipped)" "" "$got2"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
