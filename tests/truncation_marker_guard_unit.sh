#!/usr/bin/env bash
# DIVE-2610 — grade the ABORT/ABORTED truncation markers themselves.
#
# community/wiki/a-refusal-that-exits-truncates-its-caller.md prescribes an EXIT trap
# that names a truncated run. Written the obvious way — `printf ... >&2` — that marker
# is SILENT in exactly the case it exists for: the refusing call in these harnesses is
# invoked as `cmd_x ... >/dev/null 2>&1`, and `exit` terminates the shell WHILE that
# redirection is still in effect, so the trap prints into /dev/null. The remedy is to
# dup the real stderr once (`exec 8>&2`) and write the marker to `>&8`; per-command
# redirects only ever touch fd 1 and 2.
#
# A marker cannot be graded by reading it. This injects a probe that exits the way a
# refusal does and requires the literal marker to come back — once through a redirect
# (the case that bites) and once bare (the POSITIVE CONTROL). If the control does not
# print, the injection never ran and the row is INVALID, not clean: an inert injection
# and a working marker leave identical evidence. See
# community/wiki/an-exit-trap-abort-marker-is-swallowed-by-the-callers-own-redirect.md
# Run: bash tests/truncation_marker_guard_unit.sh (no root, no network).
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/truncation-marker-guard.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

SELF="$(basename "$0")"

# Subjects: harnesses whose EXIT trap prints a truncation marker. Discovered, not
# listed, so a harness that grows one is graded without editing this file.
mapfile -t SUBJECTS < <(grep -lE "^[[:space:]]*trap .*ABORT" tests/*.sh 2>/dev/null \
                        | grep -v "/$SELF\$" | sort)

if (( ${#SUBJECTS[@]} == 0 )); then
  bad_t "discovery: at least one harness carries an EXIT-trap truncation marker" \
        "found none — the grep moved, or every marker was removed"
  printf 'truncation_marker_guard_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# Inject the probe on the line AFTER the trap is installed: the trap and its flag
# variable are live by then, and nothing the harness does later can skip it.
probe_run() { # $1=subject $2=redirected|bare -> prints captured stderr
  local f="$1" mode="$2" tln inj out
  tln=$(grep -nE "^[[:space:]]*trap .*ABORT" "$f" | head -1 | cut -d: -f1)
  if [[ "$mode" == redirected ]]; then
    inj='_tmg_probe() { exit 7; }; _tmg_probe >/dev/null 2>&1'
  else
    inj='_tmg_probe() { exit 7; }; _tmg_probe'
  fi
  out="$TMP/$(basename "$f").$mode.sh"
  awk -v n="$tln" -v inj="$inj" 'NR==n{print; print inj; next} {print}' "$f" > "$out"
  cp "$out" "tests/.tmg-$(basename "$f")"     # must live in tests/ — subjects cd by $0
  bash "tests/.tmg-$(basename "$f")" >/dev/null 2>"$TMP/err.$mode"
  echo $? > "$TMP/rc.$mode"
  rm -f "tests/.tmg-$(basename "$f")"
  cat "$TMP/err.$mode"
}

for f in "${SUBJECTS[@]}"; do
  b="$(basename "$f")"

  # CONTROL first. A bare exiting probe must produce the marker. If it does not, the
  # injection never executed (or the marker is broken outright) and the treatment arm
  # below can prove nothing — so this INVALIDATES the subject rather than clearing it.
  ctl="$(probe_run "$f" bare)"; ctl_rc="$(cat "$TMP/rc.bare")"
  if [[ "$ctl_rc" != 7 ]] || ! grep -q 'ABORT' <<<"$ctl"; then
    bad_t "$b CONTROL: a bare exiting probe reaches the marker" \
          "rc=$ctl_rc (want 7), marker $(grep -q 'ABORT' <<<"$ctl" && echo seen || echo ABSENT) — injection inert or marker broken; the redirect arm below grades NOTHING for this file"
    continue
  fi
  ok_t "$b control: bare exit prints the truncation marker (injection is live)"

  # TREATMENT: the shape that actually occurs. Same probe, invoked the way every
  # guarded call in these harnesses is invoked.
  tr="$(probe_run "$f" redirected)"; tr_rc="$(cat "$TMP/rc.redirected")"
  [[ "$tr_rc" == 7 ]] && grep -q 'ABORT' <<<"$tr" \
    && ok_t "$b marker survives a caller-side '>/dev/null 2>&1' (written to a dup'd fd)" \
    || bad_t "$b marker SWALLOWED by the caller's own redirect" \
             "rc=$tr_rc, stderr had no ABORT — the trap fired into /dev/null. Add 'exec 8>&2' before the trap and write the marker to '>&8'."
done

echo "-----"
printf 'truncation_marker_guard_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
