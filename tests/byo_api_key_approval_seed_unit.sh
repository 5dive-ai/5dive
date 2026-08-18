#!/usr/bin/env bash
# DIVE-1591 unit: the custom-API-key approval seed in `5dive-agent-start`.
#
# The defect: any auth profile carrying a non-empty ANTHROPIC_API_KEY (every BYO
# provider, plus any profile set up by pasting a key) makes Claude Code raise a
# first-boot "Detected a custom API key in your environment" prompt that a
# normally-OAuth'd agent never sees. Nothing answered it, so the session parked
# on that pane forever — the agent was born asleep — and the channel plugin
# connect that raced the stall was cached as needs-auth and never retried. It
# was reported as "--channels ignored on openrouter agents"; the flag was fine.
#
# This runs the REAL block, extracted from the real script by its exact guard
# line, against a fake $HOME. Pure, no root, no network, no claude binary:
#   bash tests/byo_api_key_approval_seed_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
START=5dive-agent-start
TMP="$(mktemp -d /tmp/byo-apikey-seed-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want=$3 got=$2)"; fail=1; fi; }

MARKER='if [[ "$TYPE" == "claude" && -n "${ANTHROPIC_API_KEY:-}" ]]; then'

# --- non-vacuity, first ------------------------------------------------------
# Every assertion below runs an EXTRACTED block. If the marker ever drifts, awk
# emits nothing, every fixture is "unchanged", and a suite that only asserts
# outcomes goes green while grading an empty string. So prove the extraction
# found real code before trusting a single result.
BLOCK="$(awk -v m="$MARKER" '$0 == m {on=1} on {print} on && $0 == "fi" {exit}' "$START")"
check "marker present in $START exactly once" \
  "$(grep -cFx "$MARKER" "$START")" "1"
check "extracted block is non-empty and closed" \
  "$([[ -n "$BLOCK" && "$(tail -1 <<<"$BLOCK")" == "fi" ]] && echo yes || echo no)" "yes"
check "extracted block really seeds customApiKeyResponses" \
  "$(grep -q 'customApiKeyResponses' <<<"$BLOCK" && echo yes || echo no)" "yes"

# The preseed every claude agent gets from preseed_claude_agent(). If the seed
# clobbers this instead of merging, the agent re-arms the theme picker and the
# trust dialog — a strictly worse stall than the one we are fixing.
PRESEED='{"theme":"dark","hasCompletedOnboarding":true,"projects":{"/home/claude/projects":{"hasTrustDialogAccepted":true,"hasCompletedProjectOnboarding":true}}}'

# run <case> <TYPE> <key> [initial-json]  -> writes $TMP/<case>/.claude.json
run() {
  local case="$1" type="$2" key="$3" initial="${4:-$PRESEED}"
  local home="$TMP/$case"
  mkdir -p "$home"
  [[ "$initial" == "__none__" ]] || printf '%s\n' "$initial" > "$home/.claude.json"
  (
    set -uo pipefail
    HOME="$home"; NAME="probe"; TYPE="$type"
    if [[ "$key" == "__unset__" ]]; then unset ANTHROPIC_API_KEY; else ANTHROPIC_API_KEY="$key"; fi
    eval "$BLOCK"
  ) 2>"$home/.stderr"
  printf '%s' "$home"
}

# Independent oracle for Claude Code's `Jne(e){return e.trim().slice(-20)}`.
# Computed with bash string ops, NOT by re-running the block's jq — otherwise
# the assertion grades the implementation against itself.
tail20() { local t="$1"; t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"; printf '%s' "${t: -20}"; }

jqf() { jq -r "$2" "$1/.claude.json" 2>/dev/null; }

# --- 1. the reported case: BYO key, fresh preseeded config -------------------
KEY='sk-or-v1-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd'
H=$(run byo claude "$KEY")
check "byo: approved holds the last-20 tail" \
  "$(jqf "$H" '.customApiKeyResponses.approved | join(",")')" "$(tail20 "$KEY")"
check "byo: rejected is empty" "$(jqf "$H" '.customApiKeyResponses.rejected | length')" "0"
check "byo: onboarding preseed survives"    "$(jqf "$H" '.hasCompletedOnboarding')" "true"
check "byo: trust-dialog preseed survives" \
  "$(jqf "$H" '.projects["/home/claude/projects"].hasTrustDialogAccepted')" "true"
check "byo: theme preseed survives"         "$(jqf "$H" '.theme')" "dark"
check "byo: config stays mode 600"          "$(stat -c '%a' "$H/.claude.json")" "600"
check "byo: no WARN on the happy path"      "$(grep -c 'WARN' "$H/.stderr")" "0"
# The happy path must SAY it seeded. A silent success and a block that never ran
# produce the same journal, and on 2026-08-05 that ambiguity cost a full smoke
# cycle: the gate came back armed on a box we could not ssh into, and nothing
# recorded which of the two had happened. Assert the line AND that it carries the
# key's last 6 chars, since a line with no correlator cannot be matched to the key
# in the prompt. Assert the FULL key never appears — this line is a journal entry.
check "byo: happy path announces the seed" \
  "$(grep -c 'seeded claude custom-API-key approval' "$H/.stderr")" "1"
check "byo: seed line carries the last-6 correlator" \
  "$(grep -c "…${KEY: -6}" "$H/.stderr")" "1"
check "byo: seed line does not leak the key" \
  "$(grep -c -- "$KEY" "$H/.stderr")" "0"

# --- 2. the stray-Enter case -------------------------------------------------
# The prompt's DEFAULT is "2. No (recommended)", so one blind Enter into that
# pane records a permanent rejection. Re-approval must WIN, not coexist: the
# first live probe ended up with the same key in both lists.
T=$(tail20 "$KEY")
H=$(run rejected claude "$KEY" "{\"customApiKeyResponses\":{\"approved\":[],\"rejected\":[\"$T\"]}}")
check "rejected: tail removed from rejected" \
  "$(jqf "$H" '.customApiKeyResponses.rejected | length')" "0"
check "rejected: tail present in approved" \
  "$(jqf "$H" '.customApiKeyResponses.approved | join(",")')" "$T"

# --- 3. key rotation ---------------------------------------------------------
OLD='sk-or-v1-oldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldoldold9999'
H=$(run rotate claude "$KEY" "{\"customApiKeyResponses\":{\"approved\":[\"$(tail20 "$OLD")\"],\"rejected\":[]}}")
check "rotate: new tail approved" \
  "$(jqf "$H" '.customApiKeyResponses.approved | index("'"$T"'") != null')" "true"
check "rotate: no duplicate entries" \
  "$(jqf "$H" '.customApiKeyResponses.approved | (length == (unique | length))')" "true"

# --- 4. idempotence ----------------------------------------------------------
H=$(run idem claude "$KEY" "{\"customApiKeyResponses\":{\"approved\":[\"$T\"],\"rejected\":[]}}")
check "idempotent: approved is exactly the one tail" \
  "$(jqf "$H" '.customApiKeyResponses.approved | join(",")')" "$T"

# --- 5. the guard: no key, and non-claude types ------------------------------
# Negative assertions need the positive control above to mean anything; case 1
# is that control — the same block DOES write when the guard passes.
H=$(run nokey claude "__unset__")
check "no key: config untouched" "$(jqf "$H" 'has("customApiKeyResponses")')" "false"
# A claude agent that skips must SAY it skipped, and only a claude agent may.
# Without this line, "no key in the launcher env" and "the fix is not installed"
# read identically in a journal — which is exactly the state DIVE-1591 got stuck
# in. If the prompt then appears anyway, this line localises the bug to systemd
# handing claude a key the launcher never saw.
check "no key: claude announces the skip" \
  "$(grep -c 'no ANTHROPIC_API_KEY in the launcher env' "$H/.stderr")" "1"
H=$(run empty claude "")
check "empty key: config untouched" "$(jqf "$H" 'has("customApiKeyResponses")')" "false"
check "empty key: claude announces the skip" \
  "$(grep -c 'no ANTHROPIC_API_KEY in the launcher env' "$H/.stderr")" "1"
H=$(run hermes hermes "$KEY")
check "non-claude: stays silent (the skip line is claude-only)" \
  "$(grep -c 'no ANTHROPIC_API_KEY in the launcher env' "$H/.stderr")" "0"
check "non-claude type: config untouched" "$(jqf "$H" 'has("customApiKeyResponses")')" "false"

# --- 6. shapes the trim/slice must get right --------------------------------
SHORT='sk-tiny'
H=$(run short claude "$SHORT")
check "short key: whole key approved (slice(-20) semantics)" \
  "$(jqf "$H" '.customApiKeyResponses.approved | join(",")')" "$SHORT"
H=$(run ws claude "  $KEY  ")
check "whitespace-wrapped key: trimmed before slicing" \
  "$(jqf "$H" '.customApiKeyResponses.approved | join(",")')" "$T"

# --- 7. degraded configs must not block the launch --------------------------
H=$(run missing claude "$KEY" "__none__")
check "absent config: seeded from scratch" \
  "$(jqf "$H" '.customApiKeyResponses.approved | join(",")')" "$T"
H=$(run malformed claude "$KEY" 'not json at all {')
check "malformed config: replaced with a valid object" \
  "$(jqf "$H" '.customApiKeyResponses.approved | join(",")')" "$T"
check "malformed config: warns rather than failing silently" \
  "$(grep -c 'unreadable or not a JSON object' "$H/.stderr")" "1"
H=$(run array claude "$KEY" '[1,2,3]')
check "non-object config: replaced with a valid object" \
  "$(jqf "$H" '.customApiKeyResponses.approved | join(",")')" "$T"

# The block runs under `set -e` in the real script. An unwritable home must warn
# and fall through, never abort the launch.
H="$TMP/ro"; mkdir -p "$H"; printf '%s\n' "$PRESEED" > "$H/.claude.json"; chmod 500 "$H"
rc=0
( set -euo pipefail
  HOME="$H"; NAME="probe"; TYPE=claude; ANTHROPIC_API_KEY="$KEY"
  eval "$BLOCK"
  echo REACHED_END
) >"$H.out" 2>"$H.err" || rc=$?
chmod 700 "$H"
check "unwritable home: block does not abort the launch (set -e)" "$rc" "0"
check "unwritable home: execution continues past the block" \
  "$(grep -c REACHED_END "$H.out")" "1"
check "unwritable home: warns" \
  "$(grep -c 'custom-API-key prompt may stall' "$H.err")" "1"

# --- 7b. the block writes the file Claude Code will actually OPEN -----------
# Re-derived from the 2.1.234 bundle's own resolver:
#   hAy(): $HOME/.claude/.config.json if it exists, else
#          ${CLAUDE_CONFIG_DIR || $HOME}/.claude${dat()}.json
# Every miss here is a SILENT no-op — the seed logs success, the gate stays
# armed, and nothing in the journal separates "wrote the wrong file" from
# "never ran". These arms are the only thing that can see the difference.

# 7b.1 an existing .config.json wins outright over the dotfile.
H="$TMP/cfgjson"; mkdir -p "$H/.claude"
printf '%s\n' "$PRESEED" > "$H/.claude/.config.json"
printf '%s\n' "$PRESEED" > "$H/.claude.json"
( set -uo pipefail; HOME="$H"; NAME=probe; TYPE=claude; ANTHROPIC_API_KEY="$KEY"; eval "$BLOCK" ) 2>/dev/null
check "config.json precedence: .config.json carries the tail" \
  "$(jq -r '.customApiKeyResponses.approved | join(",")' "$H/.claude/.config.json" 2>/dev/null)" "$T"
check "config.json precedence: the dotfile is left untouched" \
  "$(jq -r '.customApiKeyResponses // "absent"' "$H/.claude.json" 2>/dev/null)" "absent"

# 7b.2 a non-prod OAuth environment suffixes the filename. Asserted per variant
# rather than in a loop so a single broken branch names itself.
for pair in "CLAUDE_CODE_CUSTOM_OAUTH_URL=https://oauth.example.com|-custom-oauth" \
            "USE_LOCAL_OAUTH=1|-local-oauth" \
            "USE_STAGING_OAUTH=1|-staging-oauth"; do
  envset="${pair%%|*}"; sfx="${pair#*|}"
  H="$TMP/oauth${sfx}"; mkdir -p "$H"
  ( set -uo pipefail; HOME="$H"; NAME=probe; TYPE=claude; ANTHROPIC_API_KEY="$KEY"
    export "${envset?}"; eval "$BLOCK" ) 2>/dev/null
  check "oauth env ${envset%%=*}: seeds .claude${sfx}.json" \
    "$(jq -r '.customApiKeyResponses.approved | join(",")' "$H/.claude${sfx}.json" 2>/dev/null)" "$T"
  check "oauth env ${envset%%=*}: leaves the prod dotfile absent" \
    "$([[ -e "$H/.claude.json" ]] && echo present || echo absent)" "absent"
done

# 7b.3 CLAUDE_CONFIG_DIR must NOT be honoured. profile.d exports it into every
# login shell, but the launch string unsets it before exec'ing claude, so the
# reader resolves against $HOME. A block that honoured it would write the one
# file claude is guaranteed not to open — and would do it on EVERY 5dive box,
# not an edge case. This arm is the tripwire on that unset.
H="$TMP/ccd"; mkdir -p "$H" "$TMP/ccd-elsewhere"
( set -uo pipefail; HOME="$H"; NAME=probe; TYPE=claude; ANTHROPIC_API_KEY="$KEY"
  export CLAUDE_CONFIG_DIR="$TMP/ccd-elsewhere"; eval "$BLOCK" ) 2>/dev/null
check "CLAUDE_CONFIG_DIR is ignored: \$HOME dotfile carries the tail" \
  "$(jq -r '.customApiKeyResponses.approved | join(",")' "$H/.claude.json" 2>/dev/null)" "$T"
check "CLAUDE_CONFIG_DIR is ignored: nothing written under it" \
  "$(find "$TMP/ccd-elsewhere" -type f | wc -l)" "0"

# --- 8. no temp-file litter --------------------------------------------------
check "no .claude.json.XXXXXX temp files left behind" \
  "$(find "$TMP" -name '.claude.json.*' -o -name '.config.json.*' | wc -l)" "0"

if (( fail )); then echo "byo_api_key_approval_seed_unit: FAIL"; exit 1; fi
echo "byo_api_key_approval_seed_unit: PASS"
