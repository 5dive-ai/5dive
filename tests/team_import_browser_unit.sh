#!/usr/bin/env bash
# DIVE-7075 — a team that declares the browser comes up able to browse.
#
# The Dropshipping trial (DIVE-6902, OSS CLI 0.102.0): all three team imports
# finished, and Clicker, whose whole job is the browser, had none. The import
# printed "capability preflight: publishing=api-only" and nothing else; the
# owner then needed `plugin add browser`, `browser setup` and a per-seat
# FIVEDIVE_BROWSER_SEAT line nobody would guess.
#
#   1. the REAL `up` (cmd_compose_up), with every `5dive …` it runs answered by a
#      recorder: a team with `browser: optional` adds the plugin (official only)
#      BEFORE its first seat, and ends on the one line a person runs;
#   2. the plugin already on: nothing added, no extra line;
#   3. the add fails: the team still comes up, the warning names both commands;
#   4. a team with no browser: nothing about a browser at all;
#   5. --json carries the word;
#   6. NEGATIVE CONTROL: origin/main's cmd_compose.sh adds nothing (arm 1 red).
#
# COVERAGE LIMIT: no seat is really made and no plugin is really fetched. The
# store at create is tests/agent_create_browser_store_unit.sh; the back-fill and
# the box stack are 5dive-browser's tests/browser_setup_{backfill,stack}_unit.sh.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
STATE_DIR="$(mktemp -d)"   # never the live /var/lib/5dive
# shellcheck disable=SC1091
source src/cmd_compose.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }
has_t() { grep -qF -- "$2" <<<"$3" && ok_t "$1" || bad_t "$1" "missing [$2] in: $(tail -20 <<<"$3")"; }
not_t() { grep -qF -- "$2" <<<"$3" && bad_t "$1" "found [$2]: $(grep -F -- "$2" <<<"$3")" || ok_t "$1"; }

TMP=$(mktemp -d); rm -rf "$STATE_DIR"; STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"

# The Dropshipping template's shape (marketplace teams/dropshipping.5dive.yaml).
cat > "$TMP/shop.5dive.yaml" <<'YAML'
version: "2"
team:
  capabilities:
    browser: optional
defaults:
  type: claude
  defer_auth: true
agents:
  clip:    {pack: clip,    role: "Shop lead"}
  dude:    {pack: dude,    role: "Product scout", reports_to: clip}
  clicker: {pack: clicker, role: "Browser hands", reports_to: clip}
YAML
sed '/^team:/,/browser: optional/d' "$TMP/shop.5dive.yaml" > "$TMP/plain.5dive.yaml"

# Every `5dive …` up runs. `browser --help` answers from a marker that `plugin
# add browser` drops; each agent call records whether the plugin was on by then.
cat > "$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$RECORD/calls"
case "${1:-} ${2:-}" in
  "browser --help") [[ -e "$RECORD/browser_on" ]]; exit ;;
  "plugin add")
    [[ -n "${FAKE_ADD_FAIL:-}" ]] && { echo "error: no route to github.com" >&2; exit 69; }
    : > "$RECORD/browser_on"; echo "added browser"; exit 0 ;;
  "agent import"|"agent create")
    verb=$2; shift 2
    name=""; for a in "$@"; do case "$a" in --as=*) name="${a#--as=}" ;; esac; done
    [[ -n "$name" ]] || name="$1"
    [[ -e "$RECORD/browser_on" ]] && echo on > "$RECORD/$verb.$name" || echo off > "$RECORD/$verb.$name"
    exit 0 ;;
esac
exit 0
SH
chmod +x "$TMP/fake5dive"
export RECORD="$TMP/rec"
stubs() {
  _compose_self() { printf '%s' "$TMP/fake5dive"; }
  ensure_state() { :; }
  require_root() { :; }
  registry_read() { printf '%s\n' '{"agents":{}}'; }
  _compose_wire_role() { :; }
  step() { printf 'STEP: %s\n' "$*" >&2; }
  warn() { printf 'WARN: %s\n' "$*" >&2; }
}
stubs
# up <spec> [browser-already-on] — the real cmd_compose_up; output in $OUT.
up() {
  rm -rf "$RECORD"; mkdir -p "$RECORD"; : > "$RECORD/calls"
  [[ "${2:-}" == on ]] && : > "$RECORD/browser_on"
  OUT=$( ( cmd_compose_up -f "$1" ) 2>&1 ); RC=$?
}
seats() { local n; for n in clip dude clicker; do printf '%s=%s ' "$n" "$(cat "$RECORD"/*."$n" 2>/dev/null || echo '(not created)')"; done; }
adds() { grep -c '^plugin add' "$RECORD/calls"; }

echo '== 1. no browser on the box: the import adds it before any seat =='
arm1() {  # arm1 <label> — the arms a revert of DIVE-7075's import half turns red
  eq_t "$1 up exits 0" 0 "$RC"
  eq_t "$1 the plugin is added once" 1 "$(adds)"
  eq_t "$1 ...from our own org only, with no prompt" 'plugin add browser --yes --official-only' "$(grep '^plugin add' "$RECORD/calls")"
  eq_t "$1 ...before the first seat: every seat is created with it on" 'clip=on dude=on clicker=on ' "$(seats)"
  has_t "$1 the run ends naming the one step left" '── one step left for the browser: run once, as root:' "$OUT"
  has_t "$1 ...and the command" '     sudo 5dive browser setup' "$OUT"
  not_t "$1 it no longer just says api-only" 'api-only' "$OUT"
  not_t "$1 it never hands out a per-seat line" 'FIVEDIVE_BROWSER_SEAT' "$OUT"
}
up "$TMP/shop.5dive.yaml"; arm1 T1
[[ $RC -eq 0 ]] || printf '%s\n' "$(tail -15 <<<"$OUT")" >&2
has_t 'T1 it says why, before the seats' 'browser: this team uses one, so the browser plugin goes on first' "$OUT"

echo '== 2. the plugin is already on =='
up "$TMP/shop.5dive.yaml" on
eq_t 'T2 nothing is added' 0 "$(adds)"
eq_t 'T2 ...every seat still made with it on' 'clip=on dude=on clicker=on ' "$(seats)"
has_t 'T2 ...says so once' 'browser: the plugin is on, so each agent of this team gets its browser at create' "$OUT"
not_t 'T2 ...and no extra closing line' 'one step left for the browser' "$OUT"

echo '== 3. the add fails =='
FAKE_ADD_FAIL=1 up "$TMP/shop.5dive.yaml"
eq_t 'T3 up still exits 0' 0 "$RC"
eq_t 'T3 ...every seat still made' 'clip=off dude=off clicker=off ' "$(seats)"
has_t 'T3 ...the warning names the exit and the reason' 'could not add the browser plugin (exit 69: error: no route to github.com)' "$OUT"
has_t 'T3 ...and both commands that finish the job' 'sudo 5dive plugin add browser && sudo 5dive browser setup' "$OUT"
not_t 'T3 ...no "one step left" over a plugin that is not there' 'one step left for the browser' "$OUT"

echo '== 4. a team that declares no browser =='
up "$TMP/plain.5dive.yaml"
eq_t 'T4 nothing is added' 0 "$(adds)"
not_t 'T4 ...nothing is probed' 'browser --help' "$(cat "$RECORD/calls")"
not_t 'T4 ...and nothing said' 'browser' "$OUT"

echo '== 5. --json =='
rm -rf "$RECORD"; mkdir -p "$RECORD"; : > "$RECORD/calls"
J=$( ( JSON_MODE=1; cmd_compose_up -f "$TMP/shop.5dive.yaml" ) 2>/dev/null | tail -n 1 )
eq_t 'T5 the result carries browser: added' added "$(jq -r '.data.browser // .browser // empty' <<<"$J" 2>/dev/null)"
rm -rf "$RECORD"; mkdir -p "$RECORD"; : > "$RECORD/calls"
J=$( ( JSON_MODE=1; cmd_compose_up -f "$TMP/plain.5dive.yaml" ) 2>/dev/null | tail -n 1 )
eq_t 'T5b ...and no browser key for a team without one' none "$(jq -r 'if (.data // .) | has("browser") then "has" else "none" end' <<<"$J" 2>/dev/null)"

echo '== 6. NEGATIVE CONTROL: origin/main =='
if git cat-file -e origin/main:src/cmd_compose.sh 2>/dev/null \
   && ! git show origin/main:src/cmd_compose.sh | grep -q '_compose_ensure_browser'; then
  git show origin/main:src/cmd_compose.sh > "$TMP/old_compose.sh"
  P0=$PASS F0=$FAIL
  ( source "$TMP/old_compose.sh"; stubs; up "$TMP/shop.5dive.yaml"; arm1 T6m; echo "RED=$((FAIL-F0))" ) > "$TMP/old.log" 2>&1
  RED=$(sed -n 's/^RED=//p' "$TMP/old.log")
  eq_t 'T6 origin/main: the T1 arms go red (>= 4)' yes "$( (( ${RED:-0} >= 4 )) && echo yes || echo "no (red=${RED:-?})")"
  has_t 'T6 ...it only says api-only' 'publishing=api-only' "$(cat "$TMP/old.log")"
else
  echo 'T6 skipped: origin/main already carries the import half (or is not fetched)'
fi

echo
printf 'DIVE-7075 a team with a browser comes up able to browse: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
