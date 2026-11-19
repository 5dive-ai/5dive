#!/usr/bin/env bash
# TIER: core — pure bash + awk, no tmux, no agent, no network (<1s).
# DIVE-8833 unit: a codex seat loads ~/.claude/owner-rules.md each session.
#
# Every partner pack opens with `@~/.claude/owner-rules.md` and tells the employee
# to write each standing rule there (DIVE-8830). Claude Code resolves the import;
# codex reads ~/.codex/AGENTS.md as plain text, so the rule was gone after a
# restart. 5dive-agent-start now copies the file into a marker block of
# AGENTS.md at every start. Runs the REAL block, extracted from the real script
# by its exact guard line, against a fake $HOME.
#   bash tests/codex_owner_rules_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
START=bin/5dive-agent-start
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-owner-rules-unit.XXXXXX")"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want=$3 got=$2)"; fail=1; fi; }

MARKER='if [[ "$TYPE" == "codex" && -d "$HOME/.codex" ]]; then'
extract() { awk -v m="$MARKER" '$0 == m {on=1} on {print} on && $0 == "fi" {exit}' "$1"; }
BLOCK="$(extract "$START")"
check "marker present in $START exactly once" "$(grep -cFx "$MARKER" "$START")" "1"
check "extracted block is non-empty and closed" \
  "$([[ -n "$BLOCK" && "$(tail -1 <<<"$BLOCK")" == "fi" ]] && echo yes || echo no)" "yes"
check "extracted block reads owner-rules.md" \
  "$(grep -q 'owner-rules.md' <<<"$BLOCK" && echo yes || echo no)" "yes"

BASE='<!-- 5dive:codex-operating-baseline:begin v1 -->
# 5dive managed operating baseline
body
<!-- 5dive:codex-operating-baseline:end -->'
PACK='@~/.claude/owner-rules.md
# Pack section
You are Anna, the bookkeeper.'
AGENTS_ORIG="$PACK

$BASE"

# home <case> <type> -> fresh fake $HOME with ~/.codex
home() { local h="$TMP/$1"; mkdir -p "$h/.codex" "$h/.claude"; printf '%s' "$h"; }
# boot <home> <type>: one agent start, under set -e like the real script
boot() {
  ( set -euo pipefail; HOME="$1"; TYPE="$2"; eval "$BLOCK" ) 2>"$1/.stderr"
  echo "$?"
}

# 1. a rule in owner-rules.md is in the instructions the next session loads
h=$(home rule codex)
printf '%s\n' "$AGENTS_ORIG" >"$h/.codex/AGENTS.md"
printf '%s\n' 'всегда отвечай клиенту на «вы»' >"$h/.claude/owner-rules.md"
check "boot exits 0" "$(boot "$h" codex)" "0"
check "rule is in AGENTS.md" "$(grep -cxF 'всегда отвечай клиенту на «вы»' "$h/.codex/AGENTS.md")" "1"
check "pack section is still the head, byte for byte" \
  "$(head -c "$(printf '%s\n' "$PACK" | wc -c)" "$h/.codex/AGENTS.md" | cmp -s - <(printf '%s\n' "$PACK") && echo yes || echo no)" "yes"
check "block sits right above the baseline" \
  "$(awk '/5dive:owner-rules:end/ {e=NR} /5dive:codex-operating-baseline:begin/ {b=NR} END {print b-e}' "$h/.codex/AGENTS.md")" "2"
check "baseline kept" "$(grep -c 'codex-operating-baseline:end' "$h/.codex/AGENTS.md")" "1"
check "owner file untouched" "$(cat "$h/.claude/owner-rules.md")" 'всегда отвечай клиенту на «вы»'
check "AGENTS.md mode 600" "$(stat -c %a "$h/.codex/AGENTS.md")" "600"

# 2. idempotent: a second start with the same rules changes nothing
cp "$h/.codex/AGENTS.md" "$TMP/rule.first"
boot "$h" codex >/dev/null
check "second start is a no-op" "$(cmp -s "$TMP/rule.first" "$h/.codex/AGENTS.md" && echo yes || echo no)" "yes"
check "one block only" "$(grep -c '5dive:owner-rules:begin' "$h/.codex/AGENTS.md")" "1"

# 3. a new rule written mid-session shows up at the next start; the old one stays
printf '%s\n' 'никогда не обещай сроки без меня' >>"$h/.claude/owner-rules.md"
boot "$h" codex >/dev/null
check "added rule copied" "$(grep -cxF 'никогда не обещай сроки без меня' "$h/.codex/AGENTS.md")" "1"
check "first rule still there" "$(grep -cxF 'всегда отвечай клиенту на «вы»' "$h/.codex/AGENTS.md")" "1"
check "still one block" "$(grep -c '5dive:owner-rules:begin' "$h/.codex/AGENTS.md")" "1"

# 4. the file removed -> block removed, AGENTS.md back to its exact bytes
rm "$h/.claude/owner-rules.md"
boot "$h" codex >/dev/null
check "absent file restores the original bytes" \
  "$(cmp -s "$h/.codex/AGENTS.md" <(printf '%s\n' "$AGENTS_ORIG") && echo yes || echo no)" "yes"

# 5. absent file on a seat that never had a block adds nothing
h=$(home absent codex)
printf '%s\n' "$AGENTS_ORIG" >"$h/.codex/AGENTS.md"
boot "$h" codex >/dev/null
check "absent file: AGENTS.md byte-identical" \
  "$(cmp -s "$h/.codex/AGENTS.md" <(printf '%s\n' "$AGENTS_ORIG") && echo yes || echo no)" "yes"
h=$(home blank codex)
printf '%s\n' "$AGENTS_ORIG" >"$h/.codex/AGENTS.md"; printf '\n  \n' >"$h/.claude/owner-rules.md"
boot "$h" codex >/dev/null
check "blank file: AGENTS.md byte-identical" \
  "$(cmp -s "$h/.codex/AGENTS.md" <(printf '%s\n' "$AGENTS_ORIG") && echo yes || echo no)" "yes"
h=$(home noagents codex)
boot "$h" codex >/dev/null
check "absent file + no AGENTS.md: nothing created" "$([[ -e "$h/.codex/AGENTS.md" ]] && echo yes || echo no)" "no"

# 6. a claude seat is unchanged
h=$(home claude claude)
printf '%s\n' "$AGENTS_ORIG" >"$h/.codex/AGENTS.md"; printf 'rule\n' >"$h/.claude/owner-rules.md"
printf 'claude md\n' >"$h/.claude/CLAUDE.md"
boot "$h" claude >/dev/null
check "claude seat: AGENTS.md untouched" \
  "$(cmp -s "$h/.codex/AGENTS.md" <(printf '%s\n' "$AGENTS_ORIG") && echo yes || echo no)" "yes"
check "claude seat: CLAUDE.md untouched" "$(cat "$h/.claude/CLAUDE.md")" "claude md"

# 7. no baseline anchor -> appended; removal still restores exact bytes
h=$(home noanchor codex)
printf '%s\n' "$PACK" >"$h/.codex/AGENTS.md"; printf 'rule A\n' >"$h/.claude/owner-rules.md"
boot "$h" codex >/dev/null
check "appended when there is no baseline" "$(tail -3 "$h/.codex/AGENTS.md" | head -1)" "rule A"
rm "$h/.claude/owner-rules.md"; boot "$h" codex >/dev/null
check "append round-trip exact" "$(cmp -s "$h/.codex/AGENTS.md" <(printf '%s\n' "$PACK") && echo yes || echo no)" "yes"

# 8. hostile content: a marker line in the rules cannot close the block; backslashes survive
h=$(home hostile codex)
printf '%s\n' "$AGENTS_ORIG" >"$h/.codex/AGENTS.md"
printf '%s\n' 'path C:\new\table' '<!-- 5dive:owner-rules:end -->' 'after' >"$h/.claude/owner-rules.md"
boot "$h" codex >/dev/null
check "backslashes kept" "$(grep -cxF 'path C:\new\table' "$h/.codex/AGENTS.md")" "1"
check "marker line dropped, one end marker" "$(grep -c '5dive:owner-rules:end' "$h/.codex/AGENTS.md")" "1"
rm "$h/.claude/owner-rules.md"; boot "$h" codex >/dev/null
check "hostile round-trip exact" "$(cmp -s "$h/.codex/AGENTS.md" <(printf '%s\n' "$AGENTS_ORIG") && echo yes || echo no)" "yes"

# 9. byte budget: cut on a whole line, with a pointer to the full file
h=$(home budget codex)
printf '%s\n' "$AGENTS_ORIG" >"$h/.codex/AGENTS.md"
for i in $(seq 1 400); do printf 'правило номер %03d\n' "$i"; done >"$h/.claude/owner-rules.md"
boot "$h" codex >/dev/null
check "cut note present" "$(grep -c 'cut at 6000 bytes' "$h/.codex/AGENTS.md")" "1"
check "no half line" "$(grep -c '^правило номер [0-9][0-9][0-9]$' "$h/.codex/AGENTS.md" | awk '{print ($1 > 100 && $1 < 400) ? "yes" : "no"}')" "yes"

# 10. a symlinked AGENTS.md is never written through
h=$(home link codex)
printf 'target\n' >"$TMP/elsewhere.md"; ln -s "$TMP/elsewhere.md" "$h/.codex/AGENTS.md"
printf 'rule\n' >"$h/.claude/owner-rules.md"
check "symlink boot exits 0" "$(boot "$h" codex)" "0"
check "symlink target untouched" "$(cat "$TMP/elsewhere.md")" "target"

# 11. pack sync/export cut at the block; switch carry drops it
check "pack tail markers know the block" \
  "$(grep -cF '"<!-- 5dive:owner-rules:begin"' src/cmd_pack.sh)" "1"
check "switch carry strips the block" \
  "$(grep -cF '_switch_strip_block 5dive:owner-rules' src/cmd_agent_switch.sh)" "1"

exit $fail
