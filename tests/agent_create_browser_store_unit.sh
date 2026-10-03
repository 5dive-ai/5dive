#!/usr/bin/env bash
# DIVE-5478 — `agent create` makes the new seat's browser store when the box's
# browser plugin is enabled, so a hired seat can browse with no root step.
#
# B1-B7 run the REAL helper through the REAL plugin dispatch (cmd_plugin.sh's
# _plugin_verb_claims + _plugin_dispatch_verb) against a throwaway STATE_DIR whose
# enabled `browser` verb is a recorder. That observes what setup is handed: the
# argv, the seat, the group, the JSON mode. What it cannot observe is the plugin's
# own setup making a directory as root; that half is the plugin's, and the live
# check on a box is what covers it.
#
#   B1  enabled plugin, standard seat: setup runs once, for agent-<name>, with the
#       shared group pinned (not the seat's private primary group, which would
#       re-point the box-wide on-demand-serve sudoers grant at the newest hire).
#   B2  the group follows AGENT_SHARED_GROUP, the one source create_agent_user uses.
#   B3  no plugin record at all: nothing runs, status `absent`, silent.
#   B4  the plugin is installed but DISABLED: same as B3.
#   B5  sandboxed seat: nothing runs, status `sandboxed`, and the warning names
#       the hand command.
#   B6  setup fails: status `failed`, the helper still returns 0 (the create must
#       not die after the agent is provisioned), and the warning names the retry.
#   B7  a --json create: the verb is handed FIVEDIVE_JSON_MODE=0 and the helper's
#       stdout is the bare status word, so nothing leaks into the envelope.
#   S1  the call site sits AFTER the registry write (setup refuses an agent-*
#       account missing from the registry) and BEFORE the unit's first boot.
#   S2  the self-check reports `failed` as an issue and `made` as ok.
# Run: bash tests/agent_create_browser_store_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src/cmd_agent_create.sh

source src/lib/error_codes.sh
source src/lib/output.sh
source src/header.sh
source src/cmd_plugin.sh
set +e

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

fn=$(sed -n '/^seed_browser_store_for_seat() {/,/^}/p' "$SRC")
t "the helper exists in $SRC" "yes" "$([[ -n "$fn" ]] && echo yes || echo no)"
eval "$fn"

TMP="$(mktemp -d)"
export STATE_DIR="$TMP/state" SENTINEL="$TMP/RAN"
KEY="browser@fixture"
mkdir -p "$STATE_DIR/plugins/enabled/$KEY/bin"
cat > "$STATE_DIR/plugins/enabled/$KEY/bin/browser" <<'ENTRY'
#!/usr/bin/env bash
{ printf 'ARGS=%s\n' "$*"
  printf 'SEAT=%s\n' "${FIVEDIVE_BROWSER_SEAT:-}"
  printf 'GROUP=%s\n' "${FIVEDIVE_BROWSER_AGENT_GROUP:-}"
  printf 'JSON=%s\n' "${FIVEDIVE_JSON_MODE:-}"
} >> "$SENTINEL"
echo "profile store ready"
if [[ -n "${FIXTURE_SETUP_FAIL:-}" ]]; then echo "setup: cannot create the store" >&2; exit 3; fi
exit 0
ENTRY
chmod +x "$STATE_DIR/plugins/enabled/$KEY/bin/browser"

record() {  # record <enabled true|false>
  jq -n --arg k "$KEY" --argjson e "$1" \
    '{($k): {enabled:$e, capabilities:["verb"], verbs:[{name:"browser"}]}}' \
    > "$STATE_DIR/plugins/installed.json"
}
OUT=""; ERR=""; RC=0
run() {
  rm -f "$SENTINEL"
  OUT=$( ( "$@" ) 2>"$TMP/.e" ); RC=$?
  ERR=$(cat "$TMP/.e")
}
ran() { [[ -f "$SENTINEL" ]] && cat "$SENTINEL" || echo "<not run>"; }

# B1
record true; JSON_MODE=0
run seed_browser_store_for_seat luna standard
t  "B1 status is made" "made" "$OUT"
t  "B1 helper rc" "0" "$RC"
tc "B1 setup verb ran" "ARGS=setup" "$(ran)"
tc "B1 for the new seat" "SEAT=agent-luna" "$(ran)"
tc "B1 shared group pinned, not the seat's private group" "GROUP=claude" "$(ran)"
t  "B1 ran exactly once" "1" "$(grep -c '^ARGS=' "$SENTINEL" 2>/dev/null || echo 0)"
tc "B1 says it on stderr" "browser store ready for agent-luna" "$ERR"

# B2
AGENT_SHARED_GROUP=team run seed_browser_store_for_seat luna standard
tc "B2 group follows AGENT_SHARED_GROUP" "GROUP=team" "$(ran)"

# B3
rm -f "$STATE_DIR/plugins/installed.json"
run seed_browser_store_for_seat luna standard
t "B3 no plugin record: absent" "absent" "$OUT"
t "B3 no plugin record: nothing ran" "<not run>" "$(ran)"
t "B3 no plugin record: silent" "" "$ERR"

# B4
record false
run seed_browser_store_for_seat luna standard
t "B4 disabled plugin: absent" "absent" "$OUT"
t "B4 disabled plugin: nothing ran" "<not run>" "$(ran)"

# B5
record true
run seed_browser_store_for_seat luna sandboxed
t  "B5 sandboxed: status" "sandboxed" "$OUT"
t  "B5 sandboxed: nothing ran" "<not run>" "$(ran)"
tc "B5 sandboxed: the warning names the hand command" "FIVEDIVE_BROWSER_SEAT=agent-luna FIVEDIVE_BROWSER_AGENT_GROUP=claude 5dive browser setup" "$ERR"

# B6
FIXTURE_SETUP_FAIL=1 run seed_browser_store_for_seat luna standard
t  "B6 failure: status" "failed" "$OUT"
t  "B6 failure: the helper still returns 0" "0" "$RC"
tc "B6 failure: names the exit and the last line" "exit 3: setup: cannot create the store" "$ERR"
tc "B6 failure: names the retry" "Retry: sudo env FIVEDIVE_BROWSER_SEAT=agent-luna" "$ERR"

# B7
JSON_MODE=1
run seed_browser_store_for_seat luna standard
t  "B7 --json create: stdout is the bare status word" "made" "$OUT"
tc "B7 --json create: verb handed JSON mode 0" "JSON=0" "$(ran)"
JSON_MODE=0

# S1 — order inside cmd_create
body=$(sed -n '/^cmd_create() {/,/^}/p' "$SRC")
reg=$(grep -n "registry_write" <<<"$body" | tail -1 | cut -d: -f1)
call=$(grep -n 'browser_store=$(seed_browser_store_for_seat "$name" "$isolation")' <<<"$body" | cut -d: -f1)
boot=$(grep -n 'systemctl enable --now "5dive-agent@${name}.service"' <<<"$body" | cut -d: -f1)
t "S1 call site after the registry write and before first boot" "yes" \
  "$([[ -n "$reg" && -n "$call" && -n "$boot" ]] && (( reg < call && call < boot )) && echo yes || echo "no (registry=$reg call=$call boot=$boot)")"

# S2 — self-check
tc "S2 failed is an issue" '_hc_issues+=("no browser store (agent CANNOT BROWSE)' "$body"
tc "S2 made is ok" '_hc_ok+=("browser store ready")' "$body"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
