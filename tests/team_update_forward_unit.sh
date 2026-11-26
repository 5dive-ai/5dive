#!/usr/bin/env bash
# DIVE-9330 — `team update <team>` (a premium team to its newest version, from
# 5dive's API as the box) left core for hosted@5dive-plugins as the verb
# `premium-team update` (its harness went with it: 5dive-plugins
# tests/hosted_premium_team_unit.sh). The verify side and `team import` of a
# premium file stay here (tests/premium_team_unit.sh, premium_team_update_unit.sh).
# What core keeps, pinned here:
#
#   F1  `team update <argv>` -> the plugin's `premium-team update <argv>`, unchanged
#   F2  a non-official plugin claiming premium-team is never run (it runs as root
#       and applies what it downloads)
#   F3  no plugin -> E_NOT_INSTALLED, one line naming the plugin and the offline way
#   F4  the API's partner probe (`team update --json`, 5dive-api
#       src/routes/partner-premium-teams.ts) never reads "missing" without the
#       plugin: a JSON envelope, not E_USAGE + "unknown team subcommand"
#   W1  the team arm calls the forward; the old fetch and the producer are gone
#   NC1 NEGATIVE CONTROL: a forward without the official-plugin check is CAUGHT by F2
# Run: bash tests/team_update_forward_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/team-update-forward.XXXXXX")"

for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/validation.sh \
         src/cmd_compose.sh src/cmd_team_pack.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e
STATE_DIR="$TMP"; JSON_MODE=0
FWD=src/cmd_team_pack.sh

pass=0; fail=0
ok_t()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { fail=$((fail+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# tu <claimed-by> <argv…> — `team update` with the plugin seam stubbed. Sets RC.
tu() {
  local claims="$1"; shift; rm -f "$TMP/dispatch"
  ( _plugin_verb_claims() { [[ "$1" == premium-team ]] && printf '%s' "$claims"; }
    _plugin_dispatch_verb() { printf '%s\n' "$@" >"$TMP/dispatch"; exit 0; }
    cmd_team update "$@" ) >"$TMP/out" 2>"$TMP/err"; RC=$?
}
f2_arm() { tu someone-else@fork research; [[ $RC -eq $E_NOT_INSTALLED && ! -e "$TMP/dispatch" ]]; }

tu hosted@5dive-plugins research --allow-downgrade
[[ $RC -eq 0 && "$(tr '\n' ' ' <"$TMP/dispatch" 2>/dev/null)" == "premium-team update research --allow-downgrade " ]] \
  && ok_t "F1 'team update <argv>' -> the plugin's 'premium-team update <argv>', unchanged" \
  || bad_t "F1 forward" "rc=$RC $(cat "$TMP/dispatch" 2>/dev/null)"
f2_arm && ok_t "F2 a non-official plugin claiming premium-team is never run" \
  || bad_t "F2 official only" "rc=$RC dispatched=$(cat "$TMP/dispatch" 2>/dev/null)"
tu "" research
[[ $RC -eq $E_NOT_INSTALLED && "$(wc -l <"$TMP/err")" == 1 ]] \
  && grep -q 'hosted@5dive-plugins' "$TMP/err" && grep -q 'team import <newer file>' "$TMP/err" \
  && ok_t "F3 no plugin: E_NOT_INSTALLED, one line naming the plugin and the offline import" \
  || bad_t "F3 missing" "rc=$RC err=$(cat "$TMP/err")"
JSON_MODE=1 tu ""
code=$(jq -r '.error.code' <"$TMP/out" 2>/dev/null); msg=$(jq -r '.error.message' <"$TMP/out" 2>/dev/null)
[[ "$code" == "$E_NOT_INSTALLED" && -n "$msg" && ! "$msg" =~ ^unknown\ team\ subcommand ]] \
  && ok_t "F4 the API's probe 'team update --json' without the plugin reads installed-elsewhere, never 'unknown team subcommand'" \
  || bad_t "F4 probe" "code=$code msg=$msg out=$(cat "$TMP/out")"

grep -qE '^    update\)  _team_update_forward "\$@"' src/cmd_compose.sh \
  && ! git grep -q '_team_premium_update_online\|premium-teams/\$team/latest' -- src \
  && [[ ! -e packaging/premium-team/build.sh ]] \
  && ok_t "W1 the team arm forwards; the API fetch and the producer are gone from core" || bad_t "W1 wiring" ""

# ── NC1: F2 can go red ───────────────────────────────────────────────────────
sed 's/if \[\[ "$(_plugin_verb_claims premium-team 2>\/dev\/null)" == "hosted@5dive-plugins" \]\]; then/if [[ -n "$(_plugin_verb_claims premium-team 2>\/dev\/null)" ]]; then/' "$FWD" >"$TMP/fwd.mut"
if cmp -s "$FWD" "$TMP/fwd.mut"; then bad_t "NC1 mutation did not apply" ""
else
  # shellcheck source=/dev/null
  source "$TMP/fwd.mut"
  f2_arm && bad_t "NC1 a forward without the official check passes F2 — the check cannot go red" "" \
         || ok_t "NC1 a forward without the official-plugin check is CAUGHT by F2"
fi

printf '\nTESTS pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
