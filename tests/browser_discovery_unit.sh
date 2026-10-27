#!/usr/bin/env bash
# DIVE-7117 — a self-hoster, or their head agent, can FIND 5dive-browser.
#
# Live QA 2026-10-27: Olivia, an admin head agent on a fresh self-hosted box, was
# asked for a screenshot and went looking for a browser on purpose. Every place
# she looked said nothing useful:
#
#   A  `5dive browser --help` -> "unknown command: browser", no install hint.
#   B  `5dive --help` never names the plugin.
#   C  `5dive market --kind=plugin` lists browser from the registry mirror, whose
#      description opens "DEPRECATED — browser now lives in its own repository".
#   E  `5dive market show browser` -> "no agent 'browser' in the market".
#
# She hand-built Playwright + Chrome from nine apt libraries instead. Each arm
# below is red on origin/main (A, B, C, E measured; D is the fence that keeps the
# fix off the app's --json catalogue, which still installs browser@5dive-plugins).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
WORK=$(mktemp -d)

PASS=0; FAIL=0
t()  { if [[ "$3" == "$2" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   want: %s\n   got:  %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   want to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   must not contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

INSTALL="sudo 5dive plugin add 5dive-ai/5dive-browser && sudo 5dive browser setup"

# ---- A, B: the built binary on a box with no plugins at all ----------------
BIN="$WORK/5dive"
if ! BUILD_OUT="$BIN" bash build.sh >"$WORK/build.log" 2>&1; then
  echo "FAIL - the bundle builds"; tail -5 "$WORK/build.log"; exit 1
fi
mkdir -p "$WORK/empty-state"
out=$(STATE_DIR="$WORK/empty-state" GH_ORG=5dive-ai "$BIN" browser --help 2>&1); rc=$?
t  "A1 \`5dive browser\` without the plugin exits E_USAGE" "2" "$rc"
tc "A2 ...and names the exact install, setup included" "$INSTALL" "$out"
t  "A3 ...in one line" "1" "$(printf '%s\n' "$out" | grep -c .)"
tn "A4 ...instead of the bare unknown-command line" "unknown command" "$out"
out=$(STATE_DIR="$WORK/empty-state" GH_ORG=5dive-ai "$BIN" no-such-verb-7117 2>&1)
tc "A5 control: any other unknown verb still reads unknown command" "unknown command: no-such-verb-7117" "$out"
tn "A6 control: ...with no browser hint on it" "5dive-browser" "$out"

out=$(STATE_DIR="$WORK/empty-state" GH_ORG=5dive-ai "$BIN" --help 2>&1)
tc "B1 \`5dive --help\` lists the browser plugin's install line" "sudo 5dive plugin add 5dive-ai/5dive-browser" "$out"
tc "B2 ...and points at market show browser" "5dive market show browser" "$out"

# ---- C, D, E: the catalogue, driven through the shipping functions ---------
# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/header.sh
# shellcheck source=/dev/null
source src/cmd_plugin.sh
# shellcheck source=/dev/null
source src/cmd_pack.sh
set +e
export STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
export GH_ORG=5dive-ai; _GH_ORG_RESOLVED=""

DEPRECATED='DEPRECATED — browser now lives in its own repository. Install it with `5dive plugin add 5dive-ai/5dive-browser`.'
LIVE='Persistent human-authenticated browser sessions: you log into a site once by hand.'
BROWSER_REPO_UP=1
curl() {
  case "${*: -1}" in
    */5dive-plugins/main/.claude-plugin/marketplace.json)
      jq -cn --arg d "$DEPRECATED" '{name:"5dive-plugins",plugins:[{name:"telegram",category:"productivity"},{name:"browser",category:"channel",description:$d}]}' ;;
    */5dive-browser/main/.claude-plugin/marketplace.json)
      (( BROWSER_REPO_UP )) || return 22
      jq -cn --arg d "$LIVE" '{name:"5dive-browser",plugins:[{name:"browser",category:"channel",description:$d}]}' ;;
    *) return 22 ;;
  esac
}
_marketplace_index() { printf '%s\n' '{"packs":[{"slug":"olivia","name":"Olivia","path":"packs/olivia"}]}'; }

JSON_MODE=0
out=$(cmd_market_plugins --kind=plugin 2>&1)
t  "C1 the plugin table lists browser once, from its own repo" "1" "$(grep -cE '^\s+browser\s+5dive-browser\s' <<<"$out")"
tn "C2 ...and no longer shows the DEPRECATED stub" "DEPRECATED" "$out"
tc "C3 ...and gives the whole install, setup included" "browser, the whole install:  $INSTALL" "$out"

JSON_MODE=1
out=$(cmd_market_plugins --kind=plugin 2>/dev/null)
JSON_MODE=0
t  "D1 fence: the --json feed (the app's catalogue) keeps the registry row" \
   "1|5dive-plugins|browser@5dive-plugins" \
   "$(jq -r '[.data.plugins[] | select(.name=="browser")] | "\(length)|\(.[0].marketplace)|\(.[0].install)"' <<<"$out")"

out=$(cmd_market_show browser 2>&1); rc=$?
t  "E1 \`market show browser\` answers" "0" "$rc"
tc "E2 ...with the live description" "$LIVE" "$(tr '\n' ' ' <<<"$out" | tr -s ' ')"
tc "E3 ...and the exact install line" "install:  $INSTALL" "$out"
tn "E4 ...and not the DEPRECATED stub" "DEPRECATED" "$out"
JSON_MODE=1
out=$(cmd_market_show browser 2>/dev/null)
JSON_MODE=0
t  "E5 --json carries the install line and the repo row" "$INSTALL|5dive-browser" \
   "$(jq -r '"\(.data.install)|\(.data.plugin.marketplace)"' <<<"$out")"
out=$(cmd_market_show olivia 2>&1); rc=$?
t  "E6 control: an agent slug still shows the agent" "0" "$rc"
tn "E7 control: ...not a plugin" "PLUGIN" "$out"
out=$( (cmd_market_show telegram) 2>&1)
tc "E8 a registry plugin shows its qualified install line" "install:  sudo 5dive plugin add telegram@5dive-plugins" "$out"
tc "E9 ...and says a channel attaches to one agent" "--channels=telegram" "$out"
out=$( (cmd_market_show no-such-7117) 2>&1); rc=$?
t  "E10 a name that is neither is E_NOT_FOUND" "$E_NOT_FOUND" "$rc"
tc "E11 ...and the refusal names both catalogues" "no agent or plugin 'no-such-7117'" "$out"
_marketplace_index() { return 1; }
out=$( (cmd_market_show browser) 2>&1); rc=$?
t  "E12 an unreachable agent index no longer hides a plugin" "0" "$rc"
out=$( (cmd_market_show no-such-7117) 2>&1); rc=$?
tc "E13 ...but an unknown name with no agent index says the market is unreachable" "could not reach the agent market" "$out"

# NEGATIVE CONTROL: the swap is a replacement, never a fabrication. With the
# browser repo unreachable the registry row is the floor and stays listed.
BROWSER_REPO_UP=0
out=$(cmd_market_plugins --kind=plugin 2>&1)
t  "F1 control: browser's repo unreachable -> the registry row still lists" "1" "$(grep -cE '^\s+browser\s+5dive-plugins\s' <<<"$out")"
tn "F2 control: ...and the whole-install line is not claimed for it" "browser, the whole install" "$out"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
