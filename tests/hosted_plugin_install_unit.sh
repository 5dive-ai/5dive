#!/usr/bin/env bash
# DIVE-9324 — `5dive partner hire` left core for hosted@5dive-plugins, so install.sh
# must put that plugin on every box 5dive built in the SAME run that removed the
# built-in, and never on a self-hosted box.
#
# The block is extracted VERBATIM from install.sh (its >>> / <<< markers) and run
# against a stub `5dive` that records its argv:
#   I1  5dive-built (provisioning.env + box token), no `partner` yet -> plugin add hosted@5dive-plugins --yes
#   I2  self-hosted (no provisioning.env)                            -> nothing
#   I3  built but no box token                                       -> nothing
#   I4  `partner` already answers                                    -> no add (retried only while missing)
#   I5  offline update                                               -> nothing
#   I6  a failed add warns and still returns 0 (never blocks an upgrade)
#   W1  the upgrade branch and the fresh install each call it once
#   W2  `partner` is no longer a core verb: no case arm, not in FIVEDIVE_BUILTIN_VERBS,
#       and _moved_verb_repo points it at the plugin
# Run: bash tests/hosted_plugin_install_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hosted-plugin-install.XXXXXX")"

pass=0; fail=0
ok_t()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { fail=$((fail+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

BLOCK="$TMP/block.sh"
sed -n '/^# >>> DIVE-9324 hosted plugin/,/^# <<< DIVE-9324 hosted plugin/p' install.sh >"$BLOCK"
[[ -s "$BLOCK" ]] && grep -q '^_hosted_plugin_ensure()' "$BLOCK" \
  && ok_t "the block is in install.sh between its markers" \
  || { bad_t "the block is in install.sh between its markers" "extracted nothing"; echo "TESTS pass=$pass fail=$fail"; exit 1; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/5dive" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls"
case "$1" in
  partner) exit "${STUB_PARTNER_RC:-1}" ;;
  plugin)  [[ "${STUB_ADD_RC:-0}" == 0 ]] || { echo "add failed"; exit "$STUB_ADD_RC"; }; echo "installed" ;;
esac
STUB
chmod +x "$TMP/bin/5dive"
export STUB_DIR="$TMP"

# case <prov 0|1> <token 0|1> — run the block once; sets CALLS, OUT, ERR, RC.
case_run() {
  rm -f "$TMP/calls" "$TMP/prov" "$TMP/conn"; : >"$TMP/calls"
  [[ "$1" == 1 ]] && : >"$TMP/prov"
  [[ "$2" == 1 ]] && printf 'CONNECTORD_TOKEN=tok-abc\n' >"$TMP/conn" || printf 'CONNECTORD_TOKEN=\n' >"$TMP/conn"
  ( BIN_DIR="$TMP/bin"
    offline_update() { [[ "${FIVEDIVE_OFFLINE_UPDATE:-0}" == 1 ]]; }
    say() { echo "→ $*"; }
    FIVEDIVE_PROVISIONING_ENV="$TMP/prov" FIVEDIVE_CONNECTORD_ENV="$TMP/conn"
    # shellcheck source=/dev/null
    source "$BLOCK"; _hosted_plugin_ensure ) >"$TMP/out" 2>"$TMP/err"; RC=$?
  CALLS=$(cat "$TMP/calls"); OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err")
}
added() { grep -qx 'plugin add hosted@5dive-plugins --yes' "$TMP/calls"; }

case_run 1 1
added && [[ $RC -eq 0 && "$OUT" == *"Installing the hosted plugin"* ]] \
  && ok_t "I1 a 5dive-built box without 'partner' gets: plugin add hosted@5dive-plugins --yes" \
  || bad_t "I1 built box gets the plugin" "rc=$RC calls=$CALLS"
case_run 0 1
[[ -z "$CALLS" && $RC -eq 0 ]] && ok_t "I2 a self-hosted box (no provisioning.env) is never touched" || bad_t "I2 self-hosted untouched" "calls=$CALLS"
case_run 1 0
[[ -z "$CALLS" && $RC -eq 0 ]] && ok_t "I3 a built box with no box token is not touched" || bad_t "I3 no token" "calls=$CALLS"
STUB_PARTNER_RC=0 case_run 1 1
! added && [[ $RC -eq 0 ]] && ok_t "I4 'partner' already answers -> no add" || bad_t "I4 already installed" "calls=$CALLS"
FIVEDIVE_OFFLINE_UPDATE=1 case_run 1 1
[[ -z "$CALLS" && $RC -eq 0 ]] && ok_t "I5 an offline update is not touched" || bad_t "I5 offline" "calls=$CALLS"
STUB_ADD_RC=1 case_run 1 1
added && [[ $RC -eq 0 && "$ERR" == *"hosted plugin not installed"* ]] \
  && ok_t "I6 a failed add warns and returns 0" || bad_t "I6 failed add" "rc=$RC err=$ERR"

# W1 — wiring: one call in the --upgrade branch (after the partner migration), one on a fresh install.
up=$(awk '/^if \[\[ "\$\{1:-\}" == "--upgrade" \]\]; then$/{on=1} on && /^fi$/{exit} on' install.sh | grep -c '^  _hosted_plugin_ensure')
fresh=$(awk '/^if \[\[ "\$\{1:-\}" == "--upgrade" \]\]; then$/{skip=1} skip && /^fi$/{skip=0; next} !skip' install.sh | grep -c '^_hosted_plugin_ensure$')
[[ "$up" == 1 && "$fresh" == 1 ]] && ok_t "W1 called once on --upgrade and once on a fresh install" \
  || bad_t "W1 wiring" "upgrade=$up fresh=$fresh"

# W2 — `partner` left core, so the plugin's verb claim can resolve.
arm=$(grep -c '^    partner)$' src/main.sh)
inlist=$(grep -m1 'readonly FIVEDIVE_BUILTIN_VERBS=' src/cmd_plugin.sh | grep -cw partner)
repo=$(grep -E "^    partner\) printf 'hosted@5dive-plugins" src/main.sh | wc -l)
[[ "$arm" == 0 && "$inlist" == 0 && "$repo" == 1 && ! -e src/cmd_partner.sh ]] \
  && ok_t "W2 partner is not a core verb and _moved_verb_repo names hosted@5dive-plugins" \
  || bad_t "W2 partner left core" "arm=$arm inlist=$inlist repo=$repo"

echo
echo "TESTS pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
