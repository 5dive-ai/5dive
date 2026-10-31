#!/usr/bin/env bash
# DIVE-7370: init-smoke's README arm (scripts/init-smoke-readme.py) runs every
# `5dive` command README.md shows. Graded on a stub `5dive` that logs its argv:
# the real README parses into real commands, the table's bare verbs continue
# their noun, a planted unknown command and a usage error each go red, and a
# skip is printed with its reason, never counted as a run.
# Run: bash tests/dive7370_init_smoke_readme_unit.sh (no root, no network, ~2s)
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad_t() { FAIL=$((FAIL+1)); echo "FAIL $1${2:+ — $2}"; }

R=scripts/init-smoke-readme.py
mkdir -p "$TMP/bin"
cat >"$TMP/bin/5dive" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$1 $2" in
  "task add")  echo "added DIVE-41" ;;
  "agent lst") echo "error: unknown command 'lst'" >&2; exit 2 ;;
  "agent bad") echo "usage: 5dive agent bad <name>" ;;
  *) echo "ok" ;;
esac
STUB
chmod +x "$TMP/bin/5dive"
run() { STUB_LOG="$TMP/$1.log" PATH="$TMP/bin:$PATH" python3 "$R" run "$2" "$TMP/$1.json" "${@:3}" >"$TMP/$1.out" 2>&1; }

# --- 1. the real README, every command a clean run on the stub ------------------
run good README.md --no-model; rc=$?
(( rc == 0 )) && ok_t "the README runs clean on a stub CLI" || bad_t "rc=$rc" "$(tail -3 "$TMP/good.out")"
n=$(jq .total "$TMP/good.json")
(( n >= 30 )) && ok_t "found $n README commands" || bad_t "found only $n README commands"
for want in "agent list" "agent logs my-agent --lines=20" "account add work" "doctor" \
            "agent send my-agent The launch moved to Friday" "task loop auto DIVE-41 on" "trace DIVE-41"; do
  grep -qxF -- "$want" "$TMP/good.log" && ok_t "ran: 5dive $want" || bad_t "never ran: 5dive $want"
done
grep -q -- '--help' "$TMP/good.log" && bad_t "a --help counted as a run" || ok_t "no command ran as --help"
grep -qE '^(agent create|self-update|watch|wall|account login)' "$TMP/good.log" \
  && bad_t "a skip-listed command ran" || ok_t "skip-listed commands did not run"
line=$(jq -r .line "$TMP/good.json")
[[ "$line" =~ ^README:\ [0-9]+\ of\ [0-9]+\ commands\ ran,\ [0-9]+\ skipped\ \(.*agent\ create.*\)$ ]] \
  && ok_t "summary line: $line" || bad_t "summary line shape" "$line"
jq -e '[.commands[] | select(.status == "skip")] | length > 0 and all(.why | length > 0)' "$TMP/good.json" >/dev/null \
  && ok_t "every skip carries a reason" || bad_t "a skip without a reason"
grep -qx 'agent ask my-agent Which post goes out today?' "$TMP/good.log" \
  && bad_t "--no-model still asked the agent" || ok_t "--no-model skips agent ask"
run model README.md
grep -qx 'agent ask my-agent Which post goes out today?' "$TMP/model.log" \
  && ok_t "with a key, agent ask runs on this box's agent" || bad_t "agent ask did not run with a key"

# --- 2. negative controls: a planted broken command goes red ---------------------
printf '# t\n\n```bash\n5dive agent lst\n5dive doctor\n```\n' >"$TMP/bad.md"
run bad "$TMP/bad.md"; rc=$?
(( rc == 1 )) && ok_t "an unknown README command turns the arm red" || bad_t "unknown command rc=$rc"
jq -r .line "$TMP/bad.json" | grep -q '1 of 2 commands ran, 1 failed' \
  && ok_t "the line counts the failure" || bad_t "line" "$(jq -r .line "$TMP/bad.json")"
printf '| Command | Does |\n|---|---|\n| `5dive agent bad` · `list` | x |\n' >"$TMP/usage.md"
run usage "$TMP/usage.md"; rc=$?
(( rc == 1 )) && ok_t "a usage error on exit 0 is red" || bad_t "usage error rc=$rc"
grep -qx 'agent list' "$TMP/usage.log" && ok_t "a bare table verb continues its noun" || bad_t "table continuation" "$(cat "$TMP/usage.log")"
printf '```\n5dive goal add "<nothing-maps-this>"\n```\n' >"$TMP/ph.md"
run ph "$TMP/ph.md"; rc=$?
(( rc == 1 )) && [[ ! -s "$TMP/ph.log" ]] && ok_t "an unmapped placeholder is red, not run" || bad_t "placeholder rc=$rc"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
