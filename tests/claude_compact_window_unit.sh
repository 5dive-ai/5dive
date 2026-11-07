#!/usr/bin/env bash
# DIVE-7892 — a claude seat compacts at 400k context, not at Claude Code's own
# ~95% of a 1M window, unless the seat's owner set a window of their own.
#
# THE BUG (report 769, teal-fox): nothing capped a claude seat's context before
# it compacted. Opus 4.8 looped one word to the 64k output cap four times at
# 632k-831k context — the seat was silent ~35 minutes — until the native
# auto-compact fired at 950k.
#
#   T1   a seat with no value of its own launches with the 400000 ceiling.
#   T2   a value already in the unit's env wins (the :- keeps it).
#   T3-T7 a window the owner set in ANY settings file Claude Code reads wins:
#        no export at all, because the env var beats the setting.
#   T8   NEGATIVE: unrelated settings (and a modelSettings entry with no window)
#        still get the ceiling.
#   T9   a settings file Claude Code cannot parse does not block the ceiling.
#   T10  other harness types never get the claude knob.
#   T11  the launch line applies STAGE_GUARD.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
set +e

TMP="$(mktemp -d /tmp/compact-window.XXXXXX)"
PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

START=bin/5dive-agent-start
# The helper and the type case, read off the start script as they ship. The
# managed-settings path is pointed into the sandbox so the runner's own /etc
# cannot colour the result.
helper=$(awk '/^_claude_owner_compact_window\(\)/{f=1} f{print} f&&/^}$/{exit}' "$START")
cases=$(awk '/^STAGE_GUARD=""$/{f=1} f{print} f&&/^esac$/{exit}' "$START")
cases=${cases//\/etc\/claude-code\/managed-settings.json/$TMP\/managed-settings.json}

seen() { # <type> [unit env value] -> CLAUDE_CODE_AUTO_COMPACT_WINDOW as the seat sees it
  ( TYPE="$1"; HOME="$TMP/home"; WORKDIR="$TMP/wd"
    eval "$helper"; eval "$cases"
    inner="${STAGE_GUARD}"'printf %s "${CLAUDE_CODE_AUTO_COMPACT_WINDOW-UNSET}"'
    if [[ -n "${2:-}" ]]; then CLAUDE_CODE_AUTO_COMPACT_WINDOW="$2" bash -c "bash -c $(printf %q "$inner")"
    else env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW bash -c "bash -c $(printf %q "$inner")"; fi )
}
reset() { rm -rf "$TMP/home" "$TMP/wd" "$TMP/managed-settings.json"; mkdir -p "$TMP/home/.claude" "$TMP/wd/.claude"; }
put() { printf '%s\n' "$2" >"$1"; }

reset
eq_t "T1 no owner value: the seat gets the 400000 ceiling" 400000 "$(seen claude)"
eq_t "T2 a value in the unit's env wins"                    600000 "$(seen claude 600000)"

reset; put "$TMP/home/.claude/settings.json" '{"autoCompactWindow": 800000}'
eq_t "T3 user settings autoCompactWindow wins (no export)" UNSET "$(seen claude)"
reset; put "$TMP/home/.claude/settings.json" '{"autoCompactWindow": "auto"}'
eq_t "T3b an explicit \"auto\" is the owner's choice too"   UNSET "$(seen claude)"
reset; put "$TMP/home/.claude/settings.json" '{"modelSettings": {"claude-opus-4-8": {"autoCompactWindow": 700000}}}'
eq_t "T4 a per-model window (where /autocompact saves) wins" UNSET "$(seen claude)"
reset; put "$TMP/home/.claude/settings.json" '{"env": {"CLAUDE_CODE_AUTO_COMPACT_WINDOW": "900000"}}'
eq_t "T5 settings env value wins"                           UNSET "$(seen claude)"
reset; put "$TMP/wd/.claude/settings.local.json" '{"autoCompactWindow": 300000}'
eq_t "T6 a project-local window wins"                       UNSET "$(seen claude)"
reset; put "$TMP/wd/.claude/settings.json" '{"autoCompactWindow": 300000}'
eq_t "T6b a project window wins"                            UNSET "$(seen claude)"
reset; put "$TMP/managed-settings.json" '{"autoCompactWindow": 500000}'
eq_t "T7 a managed window wins"                             UNSET "$(seen claude)"

reset; put "$TMP/home/.claude/settings.json" '{"permissions":{"defaultMode":"bypassPermissions"},"env":{"FOO":"1"},"modelSettings":{"claude-opus-4-8":{"effortLevel":"high"},"x":"str"}}'
eq_t "T8 unrelated settings still get the ceiling"          400000 "$(seen claude)"
reset; put "$TMP/home/.claude/settings.json" '{"autoCompactWindow": 8'
eq_t "T9 an unparseable settings file does not block it"    400000 "$(seen claude)"

reset
for t in codex opencode hermes grok devin; do
  eq_t "T10 a $t seat never gets the claude knob"           UNSET "$(seen "$t")"
done

if grep -q 'INNER="unset CLAUDE_CONFIG_DIR ${UNSET_CREDS}; ${STAGE_GUARD}' "$START"; then
  ok_t "T11 the launch line applies STAGE_GUARD"
else
  bad_t "T11 the launch line applies STAGE_GUARD" "INNER no longer carries STAGE_GUARD"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
