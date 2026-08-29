#!/usr/bin/env bash
# DIVE-3811 — a clean install must not hand the customer a red doctor line, and
# must not print PATH advice aimed at an account that is not theirs.
#
# Two install-time gaps, both on the documented first-run path
# (`curl … | sudo bash` then `5dive init`):
#
#   * /var/log/5dive/notify was built lazily by audit_init, which only runs
#     behind ensure_state — so the doctor at the end of `5dive init` could be the
#     first thing to look at the tree and correctly reported it missing. Every
#     new self-hosted box ended its first screen on
#     `[error] host/audit-drop-dir`.
#   * upstream's Claude Code installer prints a "add ~/.local/bin to PATH in
#     ~/.bashrc" advisory when it cannot see that dir on PATH. It runs as the
#     `claude` service account, so the ~/.bashrc it names is not the operator's.
#
# The arms below are about the two things a grep for the new lines would NOT
# catch: that the installer's modes are the ones the DOCTOR accepts (the two
# drifting apart is the defect, not the absence of a mkdir), and that both
# blocks are ordered after/before the thing that makes them work.
#
# Run: bash tests/install_first_run_clean_unit.sh (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/install-first-run.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- the installer's mode for notify/, read out of install.sh ------------------
NOTIFY_MODE=$(grep -oP '^chmod \K[0-7]+(?= /var/log/5dive/notify$)' install.sh | head -1)
PARENT_MODE=$(grep -oP '^chmod \K[0-7]+(?= /var/log/5dive$)' install.sh | head -1)
if [[ -n "$NOTIFY_MODE" && -n "$PARENT_MODE" ]]; then
  ok_t "install.sh sets an explicit mode on /var/log/5dive and notify/ (parent=$PARENT_MODE notify=$NOTIFY_MODE)"
else
  bad_t "install.sh sets an explicit mode on /var/log/5dive and notify/" \
        "parent='$PARENT_MODE' notify='$NOTIFY_MODE'"
fi

# --- that mode is the one the DOCTOR accepts ----------------------------------
# Not a string comparison against a number written twice: build a real directory
# with the mode the INSTALLER chose and put it through the real check. If the
# installer's mode and the doctor's expectation ever drift, this reds — which is
# the whole failure the customer saw.
# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/cmd_doctor.sh
set +e

if [[ -n "$NOTIFY_MODE" ]]; then
  DROP="$TMP/log5dive/notify"
  mkdir -p "$DROP"
  chmod "$NOTIFY_MODE" "$DROP"
  DOCTOR_CHECKS='[]'
  doctor_check_audit_drop_dir "$DROP" "$(id -gn)"
  sev=$(jq -r '.[0].severity' <<<"$DOCTOR_CHECKS")
  if [[ "$sev" == "ok" ]]; then
    ok_t "a dir created with install.sh's mode passes doctor_check_audit_drop_dir"
  else
    bad_t "a dir created with install.sh's mode passes doctor_check_audit_drop_dir" \
          "severity=$sev row=$(jq -c '.[0]' <<<"$DOCTOR_CHECKS")"
  fi
  # Negative control: the check is capable of failing on this fixture, so the
  # green above is the mode's doing and not a check that always says ok.
  chmod 0755 "$DROP"
  DOCTOR_CHECKS='[]'
  doctor_check_audit_drop_dir "$DROP" "$(id -gn)"
  sev=$(jq -r '.[0].severity' <<<"$DOCTOR_CHECKS")
  if [[ "$sev" == "error" ]]; then
    ok_t "negative control — the same check errors on a 0755 dir"
  else
    bad_t "negative control — the same check errors on a 0755 dir" "severity=$sev"
  fi
fi

# --- ordering: the chown needs the `claude` group to already exist -------------
grp_line=$(grep -n '^  groupadd --system claude$' install.sh | head -1 | cut -d: -f1)
own_line=$(grep -n '^chown root:claude /var/log/5dive /var/log/5dive/notify$' install.sh | head -1 | cut -d: -f1)
if [[ -n "$grp_line" && -n "$own_line" && "$own_line" -gt "$grp_line" ]]; then
  ok_t "the audit-tree chown (line $own_line) runs after groupadd claude (line $grp_line)"
else
  bad_t "the audit-tree chown runs after groupadd claude" "groupadd=$grp_line chown=$own_line"
fi

# --- the PATH block, and the ordering that makes it do anything ---------------
if grep -q 'export PATH="\$HOME/.local/bin:\$PATH"' install.sh; then
  ok_t "install.sh puts ~/.local/bin on the claude account's login PATH"
else
  bad_t "install.sh puts ~/.local/bin on the claude account's login PATH" "block absent"
fi

# cmd_install covers boxes installed before install.sh grew that block. It only
# helps if it lands BEFORE the recipe runs — the recipe is what reads PATH.
path_line=$(grep -n "5dive: agent runtimes .* install into ~/.local/bin" src/cmd_auth.sh | head -1 | cut -d: -f1)
recipe_line=$(grep -n 'sudo -u claude -i bash -lc "\${prelude}\${recipe}"' src/cmd_auth.sh | head -1 | cut -d: -f1)
if [[ -n "$path_line" && -n "$recipe_line" && "$path_line" -lt "$recipe_line" ]]; then
  ok_t "cmd_install writes the PATH block (line $path_line) before running the recipe (line $recipe_line)"
else
  bad_t "cmd_install writes the PATH block before running the recipe" \
        "path=$path_line recipe=$recipe_line"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
