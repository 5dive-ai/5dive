#!/usr/bin/env bash
# DIVE-7427 unit: the hooks.json that `5dive-agent-start` writes for an
# antigravity+telegram agent must be in agy's own schema.
#
# The defect: the block wrote Claude Code's nested shape
# ({"hooks":{"Stop":[{"hooks":[{type,command}]}]}}). agy (1.4.12 seen live)
# reads each top-level key as a NAMED hook, so "hooks" loads as one hook whose
# Stop entries lack `command`; agy logs "invalid hook "hooks": command hook must
# specify 'command'" and skips the whole file. No turn-complete ping and no
# error relay ever fired. It also never healed: the file was rewritten only when
# `notify-stop.ts` was missing from it, and the broken file contained it.
#
# The schema asserted below is agy 1.4.12's own hooks doc (embedded in its
# binary): {"<name>": {"enabled"?, <Event>: [...]}}; PreToolUse/PostToolUse are
# groups of {matcher, hooks:[handler]}; SessionStart/PreInvocation/
# PostInvocation/Stop are flat lists of handlers; a handler needs `command`.
# There is no Notification event.
#
# Runs the real block, extracted from the real script, against a fake plugin dir
# and a temp HOME. Pure, no root, no network:
#   bash tests/agent_start_agy_hooks_unit.sh
# START=<other copy of 5dive-agent-start> grades that copy instead (the pre-fix
# writer is red). AGY_BIN=<agy binary> also runs `agy plugin validate` on every
# written file.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.." || exit 1
START="${START:-bin/5dive-agent-start}"
TMP="$(mktemp -d /tmp/agent-start-agy-hooks.XXXXXX)"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not installed (precondition)"; exit 1; }

fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want=$3 got=$2)"; fi; }

BLOCK="$TMP/block.sh"
awk 'index($0, "if [[ \"$TYPE\" == \"antigravity\" ]] && [[ \"$CHANNELS\" == \"telegram\" ]]; then") == 1 { on=1 }
     on { print }
     on && $0 == "fi" { exit }' "$START" > "$BLOCK"
grep -q 'hooks.json' "$BLOCK" || { echo "FAIL: antigravity+telegram block not found in $START"; exit 1; }

PLUGIN="$TMP/telegram-agy"
mkdir -p "$PLUGIN/hooks"
touch "$PLUGIN/server.ts" "$PLUGIN/hooks/notify-stop.ts" "$PLUGIN/hooks/silence-watchdog.ts"
echo '// relay that predates DIVE-7427' > "$PLUGIN/hooks/notification-relay.ts"

run_block() { # <home>
  # shellcheck disable=SC2034 # read by the sourced block
  ( HOME="$1" TYPE=antigravity CHANNELS=telegram NAME=t TELEGRAM_AGY_PLUGIN_DIR="$PLUGIN"
    # shellcheck disable=SC1090
    . "$BLOCK" ) 2>"$TMP/stderr"
}

# agy's schema as a jq predicate: true only for a file agy loads.
SCHEMA='
  def handler: type == "object" and (.command | type == "string" and length > 0) and (has("hooks") | not)
    and ((.type // "command") == "command");
  def flat: type == "array" and all(.[]; handler);
  def grouped: type == "array" and all(.[]; type == "object" and (.matcher | type == "string")
    and (.hooks | type == "array" and length > 0 and all(.[]; handler)));
  type == "object" and length > 0 and all(to_entries[]; .value | type == "object" and all(to_entries[];
    if .key == "enabled" then (.value | type == "boolean")
    elif (.key == "PreToolUse" or .key == "PostToolUse") then (.value | grouped)
    elif (.key == "SessionStart" or .key == "PreInvocation" or .key == "PostInvocation" or .key == "Stop") then (.value | flat)
    else false end))'
schema_ok() { jq -e "$SCHEMA" "$1" >/dev/null 2>&1; }

agy_validate() { # <hooks.json> <label>
  [[ -n "${AGY_BIN:-}" ]] || return 0
  local p="$TMP/vp" out
  rm -rf "$p"; mkdir -p "$p"
  echo '{"name":"t","version":"0.0.1","description":"t"}' > "$p/plugin.json"
  cp "$1" "$p/hooks.json"
  out=$(HOME="$TMP/agyhome" "$AGY_BIN" plugin validate "$p" 2>&1)
  if grep -q 'Validation passed' <<<"$out"; then ok "$2: agy plugin validate passes"
  else bad "$2: agy plugin validate: $(grep -m1 '✗' <<<"$out")"; fi
}

# 0. The instrument: the shape the pre-fix writer produced must fail SCHEMA.
cat > "$TMP/legacy.json" <<'J'
{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bun /p/hooks/silence-watchdog.ts","timeout":5}]}],"Stop":[{"hooks":[{"type":"command","command":"bun /p/hooks/notify-stop.ts","timeout":10}]}],"Notification":[{"hooks":[{"type":"command","command":"bun /p/hooks/notification-relay.ts","timeout":10}]}]}}
J
if schema_ok "$TMP/legacy.json"; then bad "schema check rejects the Claude Code shape"; else ok "schema check rejects the Claude Code shape"; fi

# 1. Fresh agent: the written file is in agy's schema.
H1="$TMP/h1"; mkdir -p "$H1"
run_block "$H1"
F1="$H1/.gemini/config/hooks.json"
if schema_ok "$F1"; then ok "fresh: hooks.json is in agy's schema"; else bad "fresh: hooks.json is not in agy's schema: $(cat "$F1" 2>/dev/null)"; fi
check "fresh: Stop pings via notify-stop.ts" \
  "$(jq -r '[.[] | .Stop // [] | .[].command] | map(select(endswith("/hooks/notify-stop.ts"))) | length' "$F1" 2>/dev/null)" 1
check "fresh: no relay on Stop while the staged relay predates the Stop payload" \
  "$(jq -r '[.[] | .Stop // [] | .[].command] | map(select(endswith("/hooks/notification-relay.ts"))) | length' "$F1" 2>/dev/null)" 0
check "fresh: file mode 600" "$(stat -c %a "$F1" 2>/dev/null)" 600
agy_validate "$F1" fresh

# 2. Idempotent: a second boot leaves the file alone (same inode, same bytes).
before="$(stat -c %i "$F1" 2>/dev/null) $(md5sum < "$F1" 2>/dev/null)"
run_block "$H1"
check "rerun: file untouched" "$(stat -c %i "$F1" 2>/dev/null) $(md5sum < "$F1" 2>/dev/null)" "$before"

# 3. Heal: a box carrying the old file (notify-stop.ts inside it) plus a hook of
#    the owner's own is fixed on the next boot, keeping the owner's hook.
H3="$TMP/h3"; mkdir -p "$H3/.gemini/config"
jq '. + {"mine": {"PreInvocation": [{"command": "echo {}"}]}}' "$TMP/legacy.json" > "$H3/.gemini/config/hooks.json"
run_block "$H3"
F3="$H3/.gemini/config/hooks.json"
if schema_ok "$F3"; then ok "heal: an old Claude-shape file is rewritten into agy's schema"; else bad "heal: still not agy's schema: $(cat "$F3")"; fi
check "heal: the owner's own named hook survives" "$(jq -c '.mine' "$F3" 2>/dev/null)" '{"PreInvocation":[{"command":"echo {}"}]}'
agy_validate "$F3" heal

# 4. Relay: once the staged relay reads agy's Stop payload, the next boot adds it.
echo 'if (typeof payload.terminationReason === "string") {}' > "$PLUGIN/hooks/notification-relay.ts"
run_block "$H1"
check "relay: Stop gains notification-relay.ts once the plugin supports it" \
  "$(jq -r '[.[] | .Stop // [] | .[].command] | map(select(endswith("/hooks/notification-relay.ts"))) | length' "$F1" 2>/dev/null)" 1
if schema_ok "$F1"; then ok "relay: still in agy's schema"; else bad "relay: not in agy's schema"; fi
agy_validate "$F1" relay

# 5. An unparseable file starts fresh rather than staying broken.
H5="$TMP/h5"; mkdir -p "$H5/.gemini/config"
echo '{not json' > "$H5/.gemini/config/hooks.json"
run_block "$H5"
if schema_ok "$H5/.gemini/config/hooks.json"; then ok "garbage: rewritten into agy's schema"; else bad "garbage: still broken"; fi

[[ -s "$TMP/stderr" ]] && { echo "--- block stderr:"; cat "$TMP/stderr"; }
if (( fail )); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
