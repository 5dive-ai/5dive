#!/usr/bin/env bash
# DIVE-8308 — a claude seat on a BYO provider launches with its model's real
# context window (CLAUDE_CODE_MAX_CONTEXT_TOKENS), unless the owner set one.
#
# THE BUG (customer report 2026-11-12, CLI 0.128.0): Claude Code does not know
# a BYO model's window and assumes 200k, and the 400k ceiling (DIVE-7892) hides
# its own notice saying so. The box had to set the window by hand: 983,616 for
# qwen4-max-preview on a Qwen Token Plan, 1,000,000 for deepseek-v4.1-flash
# through OpenRouter.
#
#   T1-T2   a qwen seat and an OpenRouter seat get the window; the ceiling stays.
#   T3      the SMALLEST window among the seat's models is the one exported.
#   T4      OpenRouter: the routed provider's own smaller figure wins; a ":x"
#           variant falls back to its base slug.
#   T5-T8   the owner's value wins: unit env, user / project / managed settings.
#   T9-T12  nothing is exported (never guess high): an unknown model (with a
#           warning), an endpoint of the owner's own, an Anthropic seat, a
#           settings model nothing knows.
#   T13     claude-* ids and family aliases are not counted.
#   T14-T17 OpenRouter's list: a fresh cache is not re-fetched, a stale one is,
#           a failed fetch falls back to the stale copy, local-only never fetches.
#   T18     other harness types never get the knob.
#   T19     the case runs under set -u with no WORKDIR.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
set +e

TMP="$(mktemp -d /tmp/byo-window.XXXXXX)"
PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

START="${START_SCRIPT:-bin/5dive-agent-start}"
# Every helper between the ceiling's and STAGE_GUARD, and the type case, read
# off the start script as they ship. The managed-settings path is pointed into
# the sandbox so the runner's own /etc cannot colour the result.
helpers=$(awk '/^_claude_owner_compact_window\(\)/{f=1} /^# STAGE_GUARD: env exports/{exit} f{print}' "$START")
cases=$(awk '/^STAGE_GUARD=""$/{f=1} f{print} f&&/^esac$/{exit}' "$START")
cases=${cases//\/etc\/claude-code\/managed-settings.json/$TMP\/managed-settings.json}

# A stand-in curl: logs each call, serves the fixture list, or fails on demand.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CURL_LOG"
[[ -n "${CURL_FAIL:-}" ]] && exit 22
out=""; while (($#)); do [[ "$1" == -o ]] && { out="$2"; shift; }; shift; done
cp "$CURL_FIXTURE" "$out"
STUB
chmod +x "$TMP/bin/curl"
cat >"$TMP/fixture.json" <<'JSON'
{"data":[
 {"id":"deepseek/deepseek-v4.1-flash","context_length":1048576,"top_provider":{"context_length":1048576}},
 {"id":"deepseek/deepseek-v4-pro","context_length":1048576,"top_provider":{"context_length":1024000}},
 {"id":"z-ai/glm-4.5-air","context_length":131072,"top_provider":{"context_length":131072}},
 {"id":"qwen/qwen3.8-max","context_length":1000000,"top_provider":{"context_length":null}}
]}
JSON
export CURL_LOG="$TMP/curl.log" CURL_FIXTURE="$TMP/fixture.json"
CACHE="$TMP/home/.cache/5dive/openrouter-models.json"

QWEN=https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic
OR=https://openrouter.ai/api

# seen <type> [VAR=value ...] -> CLAUDE_CODE_MAX_CONTEXT_TOKENS as the launched
# seat sees it (UNSET when none). The seat's stderr goes to $TMP/err.
seen() {
  local type="$1"; shift
  ( TYPE="$type"; HOME="$TMP/home"; WORKDIR="$TMP/wd"; NAME=t
    export FIVE_LOCAL_ONLY_FILE="$TMP/local-only" PATH="$TMP/bin:$PATH"
    unset XDG_CACHE_HOME ANTHROPIC_BASE_URL ANTHROPIC_MODEL CLAUDE_CODE_MAX_CONTEXT_TOKENS \
          ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
          CLAUDE_CODE_AUTO_COMPACT_WINDOW
    for kv in "$@"; do export "$kv"; done
    eval "$helpers"; eval "$cases"
    inner="${STAGE_GUARD}"'printf %s "${CLAUDE_CODE_MAX_CONTEXT_TOKENS-UNSET}"'
    bash -c "bash -c $(printf %q "$inner")" ) 2>"$TMP/err"
}
ceiling() { # same seat, the ceiling it launches with
  ( TYPE=claude; HOME="$TMP/home"; WORKDIR="$TMP/wd"; NAME=t
    export FIVE_LOCAL_ONLY_FILE="$TMP/local-only" PATH="$TMP/bin:$PATH"
    unset CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_MAX_CONTEXT_TOKENS
    for kv in "$@"; do export "$kv"; done
    eval "$helpers"; eval "$cases"
    inner="${STAGE_GUARD}"'printf %s "${CLAUDE_CODE_AUTO_COMPACT_WINDOW-UNSET}"'
    bash -c "bash -c $(printf %q "$inner")" ) 2>/dev/null
}
reset() { rm -rf "$TMP/home" "$TMP/wd" "$TMP/managed-settings.json" "$TMP/local-only" "$CURL_LOG"
          mkdir -p "$TMP/home/.claude" "$TMP/wd/.claude"; : >"$CURL_LOG"; }
put() { mkdir -p "${1%/*}"; printf '%s\n' "$2" >"$1"; }
seed_cache() { put "$CACHE" "$(cat "$TMP/fixture.json")"; }

QWEN_SEAT=(ANTHROPIC_BASE_URL=$QWEN ANTHROPIC_DEFAULT_OPUS_MODEL=qwen4-max-preview
           ANTHROPIC_DEFAULT_SONNET_MODEL=qwen4-max-preview ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3.6-flash)
OR_SEAT=(ANTHROPIC_BASE_URL=$OR ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek/deepseek-v4.1-flash
         ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek/deepseek-v4.1-flash ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek/deepseek-v4.1-flash)

reset
eq_t "T1 a qwen seat launches with its window"               983616  "$(seen claude "${QWEN_SEAT[@]}")"
eq_t "T1b ... and keeps the 400k ceiling"                    400000  "$(ceiling "${QWEN_SEAT[@]}")"
reset
eq_t "T2 an OpenRouter seat launches with its window"        1048576 "$(seen claude "${OR_SEAT[@]}")"
eq_t "T2b ... read from OpenRouter's list (one fetch)"       1       "$(wc -l <"$CURL_LOG" | tr -d ' ')"
grep -q -- "--proto =https https://openrouter.ai/api/v1/models" "$CURL_LOG" \
  && ok_t "T2c ... over https from openrouter.ai, no key" || bad_t "T2c fetch line" "$(cat "$CURL_LOG")"

reset; seed_cache
eq_t "T3 the smallest window among the seat's models wins"   131072 \
  "$(seen claude "${OR_SEAT[@]}" ANTHROPIC_DEFAULT_HAIKU_MODEL=z-ai/glm-4.5-air)"
reset; seed_cache
eq_t "T3b a direct provider: smallest of its tiers"          202752 \
  "$(seen claude ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2 ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5-turbo ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5-turbo)"
reset; seed_cache
eq_t "T4 the routed provider's smaller figure wins"          1024000 \
  "$(seen claude ANTHROPIC_BASE_URL=$OR ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek/deepseek-v4-pro)"
reset; seed_cache
eq_t "T4b a ':nitro' variant reads its base slug"            1048576 \
  "$(seen claude ANTHROPIC_BASE_URL=$OR ANTHROPIC_MODEL=deepseek/deepseek-v4.1-flash:nitro)"
reset; seed_cache
eq_t "T4c a null routed figure falls back to context_length" 1000000 \
  "$(seen claude ANTHROPIC_BASE_URL=$OR ANTHROPIC_MODEL=qwen/qwen3.8-max)"

reset
eq_t "T5 a value in the unit's env wins"                     500000 \
  "$(seen claude "${QWEN_SEAT[@]}" CLAUDE_CODE_MAX_CONTEXT_TOKENS=500000)"
reset; put "$TMP/home/.claude/settings.json" '{"env": {"CLAUDE_CODE_MAX_CONTEXT_TOKENS": "900000"}}'
eq_t "T6 the owner's user settings env wins (no export)"     UNSET "$(seen claude "${QWEN_SEAT[@]}")"
reset; put "$TMP/wd/.claude/settings.local.json" '{"env": {"CLAUDE_CODE_MAX_CONTEXT_TOKENS": "900000"}}'
eq_t "T7 a project-local value wins"                         UNSET "$(seen claude "${QWEN_SEAT[@]}")"
reset; put "$TMP/managed-settings.json" '{"env": {"CLAUDE_CODE_MAX_CONTEXT_TOKENS": "900000"}}'
eq_t "T8 a managed value wins"                               UNSET "$(seen claude "${QWEN_SEAT[@]}")"
reset; put "$TMP/home/.claude/settings.json" '{"env": {"FOO": "1"}, "autoCompactWindow": 300000}'
eq_t "T8b unrelated settings still get the window"           983616 "$(seen claude "${QWEN_SEAT[@]}")"

reset
eq_t "T9 an unknown model: nothing exported"                 UNSET \
  "$(seen claude "${QWEN_SEAT[@]}" ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen9-mystery)"
grep -q "calls 'qwen9-mystery' on qwen, whose context window is unknown" "$TMP/err" \
  && ok_t "T9b ... and the journal says why" || bad_t "T9b warning" "$(cat "$TMP/err")"
reset; seed_cache
eq_t "T9c an unknown OpenRouter slug: nothing exported"      UNSET \
  "$(seen claude ANTHROPIC_BASE_URL=$OR ANTHROPIC_MODEL=acme/nothing-here)"
reset
eq_t "T10 an endpoint of the owner's own: nothing exported"  UNSET \
  "$(seen claude ANTHROPIC_BASE_URL=http://192.0.2.10:11434 ANTHROPIC_DEFAULT_OPUS_MODEL=glm-4.5-air)"
reset
eq_t "T11 an Anthropic seat: nothing exported"               UNSET "$(seen claude)"
reset; put "$TMP/home/.claude/settings.json" '{"model": "qwen-unlisted"}'
eq_t "T12 the seat's own settings model counts (unknown)"    UNSET "$(seen claude "${QWEN_SEAT[@]}")"
reset; put "$TMP/home/.claude/settings.json" '{"model": "opus[1m]"}'
eq_t "T13 a family alias is not counted"                     983616 \
  "$(seen claude "${QWEN_SEAT[@]}" ANTHROPIC_MODEL=sonnet)"
reset
eq_t "T13b a claude-* id is not counted"                     983616 \
  "$(seen claude "${QWEN_SEAT[@]}" ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-5-5)"

reset; seed_cache
seen claude "${OR_SEAT[@]}" >/dev/null
eq_t "T14 a fresh cache is not fetched again"                0 "$(wc -l <"$CURL_LOG" | tr -d ' ')"
reset; seed_cache; touch -d '2 days ago' "$CACHE"
seen claude "${OR_SEAT[@]}" >/dev/null
eq_t "T15 a day-old cache is fetched again"                  1 "$(wc -l <"$CURL_LOG" | tr -d ' ')"
reset; seed_cache; touch -d '2 days ago' "$CACHE"
eq_t "T16 a failed fetch falls back to the old copy"         1048576 "$(CURL_FAIL=1 seen claude "${OR_SEAT[@]}")"
reset
eq_t "T16b a failed fetch and no copy: nothing exported"     UNSET "$(CURL_FAIL=1 seen claude "${OR_SEAT[@]}")"
reset; : >"$TMP/local-only"
eq_t "T17 local-only: nothing exported"                      UNSET "$(seen claude "${OR_SEAT[@]}")"
eq_t "T17b ... and nothing fetched"                          0 "$(wc -l <"$CURL_LOG" | tr -d ' ')"

reset
for t in codex opencode hermes grok devin; do
  eq_t "T18 a $t seat never gets the knob"                   UNSET "$(seen "$t" "${QWEN_SEAT[@]}")"
done

reset
out=$( ( set -u; TYPE=claude; HOME="$TMP/home"; unset WORKDIR; NAME=t
         export ANTHROPIC_BASE_URL=$QWEN ANTHROPIC_DEFAULT_OPUS_MODEL=qwen3.8-max
         unset ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_MODEL CLAUDE_CODE_MAX_CONTEXT_TOKENS
         eval "$helpers"; eval "$cases"; printf '%s' "$STAGE_GUARD" ) 2>&1 )
[[ "$out" == *"export CLAUDE_CODE_MAX_CONTEXT_TOKENS=983616; "* ]] \
  && ok_t "T19 the case runs under set -u with no WORKDIR" || bad_t "T19 set -u" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
