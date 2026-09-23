#!/usr/bin/env bash
# DIVE-4863 — reasoning effort must land in the key Claude Code actually reads.
#
# Claude Code >= 2.1.280 applies a user-settings top-level `effortLevel` only to
# the models it calls legacy; claude-opus-5-5 ignores it and runs at medium.
# The honoured key is `modelSettings.<canonical model>.effortLevel`. Every seat
# on every box ran at medium because the CLI wrote only the top-level key.
#
# Arms EXECUTE the shipped code (models.sh sourced; the cmd_agent.sh functions
# extracted by name and run against fixture homes). The create path is graded in
# tests/byo_model_create_unit.sh (it already drives the real preseed).
set -uo pipefail

# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT=$PWD
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
is()  { [[ "$2" == "$3" ]] && ok "$1" || no "$1 (got '$2', want '$3')"; }

# shellcheck disable=SC1091
source "$ROOT/src/lib/models.sh"
OPUS=$(model_latest opus); SONNET=$(model_latest sonnet)
A=$(models_json)

echo "== 1. canonical ids =="
is "alias resolves"            "$(model_canonical opus)"            "$OPUS"
is "[1m] suffix dropped"       "$(model_canonical 'opus[1m]')"      "$OPUS"
is "full id [1m] dropped"      "$(model_canonical 'claude-opus-5[1m]')" "claude-opus-5"
is "BYO slug passes through"   "$(model_canonical google/gemini-2.5-pro)" "google/gemini-2.5-pro"
ids=$(model_effort_ids_json opus)
is "every family's id is written" "$(jq -c --arg o "$OPUS" --arg s "$SONNET" '[index($o) != null, index($s) != null, length]' <<<"$ids")" "[true,true,$(model_families | wc -l)]"
is "a pinned older claude id is added" "$(model_effort_ids_json claude-opus-5 | jq 'index("claude-opus-5") != null')" "true"
is "a BYO slug is not a key"   "$(model_effort_ids_json google/gemini-2.5-pro | jq 'map(select(startswith("google"))) | length')" "0"

j() { jq -c --argjson ids "$ids" --argjson a "$A" "$MODEL_EFFORT_JQ$1"; }

echo "== 2. apply_effort (explicit set: both keys, overwrites) =="
out=$(j 'apply_effort("high"; $ids)' <<<'{"model":"opus","effortLevel":"medium","x":1,"modelSettings":{"'"$OPUS"'":{"effortLevel":"low","maxEffortLevel":"max"}}}')
is "top-level set"             "$(jq -r .effortLevel <<<"$out")" "high"
is "per-model set (overwrites)" "$(jq -r --arg o "$OPUS" '.modelSettings[$o].effortLevel' <<<"$out")" "high"
is "sibling per-model key kept" "$(jq -r --arg o "$OPUS" '.modelSettings[$o].maxEffortLevel' <<<"$out")" "max"
is "unrelated key kept"        "$(jq -r .x <<<"$out")" "1"
out=$(j 'apply_effort("max"; $ids)' <<<'{"model":"opus"}')
is "max stays max top-level"   "$(jq -r .effortLevel <<<"$out")" "max"
is "max persists per-model as xhigh (schema has no max)" "$(jq -r --arg o "$OPUS" '.modelSettings[$o].effortLevel' <<<"$out")" "xhigh"

echo "== 3. heal_effort (fill missing only) =="
out=$(j 'heal_effort($ids)' <<<'{"model":"opus","effortLevel":"high"}')
is "missing per-model filled"  "$(jq -r --arg o "$OPUS" '.modelSettings[$o].effortLevel' <<<"$out")" "high"
out=$(j 'heal_effort($ids)' <<<'{"model":"opus","effortLevel":"high","modelSettings":{"'"$OPUS"'":{"effortLevel":"xhigh"}}}')
is "an /effort choice is never overwritten" "$(jq -r --arg o "$OPUS" '.modelSettings[$o].effortLevel' <<<"$out")" "xhigh"
is "...while its siblings are filled" "$(jq -r --arg s "$SONNET" '.modelSettings[$s].effortLevel' <<<"$out")" "high"
is "no top-level -> untouched" "$(j 'heal_effort($ids)' <<<'{"model":"opus"}')" '{"model":"opus"}'
is "bogus top-level -> untouched" "$(j 'heal_effort($ids)' <<<'{"effortLevel":"ultra"}')" '{"effortLevel":"ultra"}'
is "non-object modelSettings -> untouched" "$(j 'heal_effort($ids)' <<<'{"effortLevel":"high","modelSettings":[]}')" '{"effortLevel":"high","modelSettings":[]}'
once=$(j 'heal_effort($ids)' <<<'{"model":"opus","effortLevel":"low"}')
is "idempotent"                "$(j 'heal_effort($ids)' <<<"$once")" "$once"

echo "== 4. effective_effort (jq readers) =="
is "per-model wins"            "$(jq -r --argjson a "$A" "$MODEL_EFFORT_JQ"'effective_effort($a)' <<<'{"model":"opus[1m]","effortLevel":"high","modelSettings":{"'"$OPUS"'":{"effortLevel":"xhigh"}}}')" "xhigh"
is "falls back to top-level"   "$(jq -r --argjson a "$A" "$MODEL_EFFORT_JQ"'effective_effort($a)' <<<'{"model":"opus","effortLevel":"low"}')" "low"
is "another model's key ignored" "$(jq -r --argjson a "$A" "$MODEL_EFFORT_JQ"'effective_effort($a)' <<<'{"model":"opus","effortLevel":"low","modelSettings":{"'"$SONNET"'":{"effortLevel":"xhigh"}}}')" "low"
is "nothing set -> empty"      "$(jq -r --argjson a "$A" "$MODEL_EFFORT_JQ"'effective_effort($a)' <<<'{}')" ""

echo "== 5. agent-list shaper (python, env-less helper) =="
awk '/^def _model_version_key/,/^def model_and_effort/' "$ROOT/src/cmd_agent.sh" | sed '$d' >"$TMP/shaper.py"
if grep -q '^def claude_effective_effort' "$TMP/shaper.py"; then ok "shaper function extracted"; else no "shaper function extracted — arms below test nothing"; fi
py() { python3 -c "import json, re, sys
exec(open('$TMP/shaper.py').read())
print(claude_effective_effort(json.loads(sys.argv[1])))" "$1"; }
is "bare alias -> highest-versioned key" "$(py '{"model":"opus","effortLevel":"high","modelSettings":{"claude-opus-5":{"effortLevel":"low"},"claude-opus-5-5":{"effortLevel":"xhigh"}}}')" "xhigh"
is "exact full id wins"        "$(py '{"model":"claude-opus-5[1m]","effortLevel":"high","modelSettings":{"claude-opus-5":{"effortLevel":"low"},"claude-opus-5-5":{"effortLevel":"xhigh"}}}')" "low"
is "falls back to top-level"   "$(py '{"model":"opus","effortLevel":"high"}')" "high"
is "malformed modelSettings -> top-level" "$(py '{"model":"opus","effortLevel":"high","modelSettings":"x"}')" "high"
is "nothing set -> None"       "$(py '{}')" "None"

echo "== 6. write_runtime_effort (agent config set effort=) =="
fail() { printf 'FAIL(%s) %s\n' "$1" "$2" >&2; exit "${1:-1}"; }
E_NOT_FOUND=4; E_GENERIC=1
sed -n '/^write_runtime_effort()/,/^}/p;/^settings_effective_effort()/,/^}/p;/^cmd_agent_heal_effort()/,/^}/p' \
  "$ROOT/src/cmd_agent.sh" >"$TMP/fns.sh"
is "three functions extracted" "$(grep -cE '^(write_runtime_effort|settings_effective_effort|cmd_agent_heal_effort)\(\)' "$TMP/fns.sh")" "3"
# shellcheck disable=SC1091
source "$TMP/fns.sh"
export AGENT_HOME_ROOT="$TMP/home"
mkdir -p "$AGENT_HOME_ROOT/agent-a/.claude"
f="$AGENT_HOME_ROOT/agent-a/.claude/settings.json"
printf '{"model":"opus","effortLevel":"medium","permissions":{"defaultMode":"bypassPermissions"}}\n' >"$f"
( write_runtime_effort claude a high )
is "top-level written"         "$(jq -r .effortLevel "$f")" "high"
is "per-model written for the seat's model" "$(jq -r --arg o "$OPUS" '.modelSettings[$o].effortLevel' "$f")" "high"
is "other keys preserved"      "$(jq -r .permissions.defaultMode "$f")" "bypassPermissions"
is "mode 600"                  "$(stat -c %a "$f")" "600"
is "reader reports the effective level" "$(settings_effective_effort <"$f")" "high"
# resolve_agent_effort (agent info / list-json reader) runs through priv_read;
# stub it to a direct read so the jq program itself is what is graded.
sed -n '/^resolve_agent_effort()/,/^}/p' "$ROOT/src/cmd_agent.sh" >"$TMP/rae.sh"
# shellcheck disable=SC1091
source "$TMP/rae.sh"
priv_read() { shift; "$@" 2>/dev/null || true; }
printf '{"model":"opus","effortLevel":"high","modelSettings":{"%s":{"effortLevel":"xhigh"}}}\n' "$OPUS" >"$f"
is "resolve_agent_effort prefers the per-model key" "$(resolve_agent_effort claude a)" "xhigh"
printf '{"model":"opus","effortLevel":"low"}\n' >"$f"
is "resolve_agent_effort falls back to top-level" "$(resolve_agent_effort claude a)" "low"
printf '[1,2]\n' >"$f"
( write_runtime_effort claude a high ) 2>/dev/null; rc=$?
is "non-object settings refused (rc!=0)" "$([[ $rc -ne 0 ]] && echo refused || echo written)" "refused"
is "...and left byte-identical" "$(cat "$f")" "[1,2]"

echo "== 7. cmd_agent_heal_effort (installer migration) =="
require_root() { :; }
ok_msg=""; ok() { ok_msg="$*"; }   # the CLI's ok(); re-bound below
warn() { :; }
registry_read() { jq -n '{agents:{a:{type:"claude"},b:{type:"claude"},c:{type:"codex"},d:{type:"claude"}}}'; }
mkdir -p "$AGENT_HOME_ROOT"/agent-{b,c,d}/.claude
printf '{"model":"opus","effortLevel":"high"}\n' >"$AGENT_HOME_ROOT/agent-a/.claude/settings.json"
printf '{"model":"opus","effortLevel":"high","modelSettings":{"%s":{"effortLevel":"xhigh"}},"z":1}' "$OPUS" \
  >"$AGENT_HOME_ROOT/agent-b/.claude/settings.json"
printf '{"effortLevel":"high"}\n' >"$AGENT_HOME_ROOT/agent-c/.claude/settings.json"
printf '{"model":"opus"}\n' >"$AGENT_HOME_ROOT/agent-d/.claude/settings.json"
cp "$AGENT_HOME_ROOT/agent-c/.claude/settings.json" "$TMP/c.before"
cp "$AGENT_HOME_ROOT/agent-d/.claude/settings.json" "$TMP/d.before"
cmd_agent_heal_effort; hrc=$?
heal_msg=$ok_msg
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
is "heal exits 0"              "$hrc" "0"
is "top-level-only seat healed" "$(jq -r --arg o "$OPUS" '.modelSettings[$o].effortLevel' "$AGENT_HOME_ROOT/agent-a/.claude/settings.json")" "high"
is "a per-model choice is kept" "$(jq -r --arg o "$OPUS" '.modelSettings[$o].effortLevel' "$AGENT_HOME_ROOT/agent-b/.claude/settings.json")" "xhigh"
is "codex seat untouched"      "$(cmp -s "$TMP/c.before" "$AGENT_HOME_ROOT/agent-c/.claude/settings.json" && echo same)" "same"
is "seat with no effort untouched (no rewrite)" "$(cmp -s "$TMP/d.before" "$AGENT_HOME_ROOT/agent-d/.claude/settings.json" && echo same)" "same"
is "count reported"            "$heal_msg" "per-model effort healed on 2 agent(s)"
cp "$AGENT_HOME_ROOT/agent-a/.claude/settings.json" "$TMP/a.after"
ok() { ok_msg="$*"; }
cmd_agent_heal_effort
second=$ok_msg
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
is "second pass heals nothing" "$second" "per-model effort healed on 0 agent(s)"
is "second pass does not rewrite (fingerprint stable)" "$(cmp -s "$TMP/a.after" "$AGENT_HOME_ROOT/agent-a/.claude/settings.json" && echo same)" "same"

echo "== 8. wiring =="
grep -q '_heal_effort)' "$ROOT/src/main.sh" && grep -q 'cmd_agent_heal_effort "\$@"' "$ROOT/src/main.sh" \
  && ok "agent _heal_effort dispatches" || no "agent _heal_effort not dispatched in main.sh"
grep -q '"\$BIN_DIR/5dive" agent _heal_effort' "$ROOT/install.sh" \
  && ok "installer runs the heal on upgrade" || no "installer does not run the heal"
grep -q "grep -q 'cmd_agent_heal_effort' \"\$BIN_DIR/5dive\"" "$ROOT/install.sh" \
  && ok "installer skips a bundle that predates the verb" || no "installer would warn on every pre-0.49.1 bundle"
grep -q 'effort=$(settings_effective_effort <"$f")' "$ROOT/src/cmd_agent_pairing.sh" \
  && ok "pairing greeting reads the effective level" || no "pairing greeting still reads the legacy key"
grep -q 'effort=$(settings_effective_effort <"$cdir/settings.json"' "$ROOT/src/cmd_pack.sh" \
  && ok "pack export carries the effective level" || no "pack export still reads the legacy key"
# No writer may set the top-level key alone again.
lone=$(grep -nE 'effortLevel[:"]? *(=|:) *\$?effort|data\["effortLevel"\]' "$ROOT"/src/*.sh "$ROOT"/src/lib/*.sh | grep -v 'models.sh' || true)
is "no top-level-only effort writer left" "$lone" ""

echo "-----"
echo "per_model_effort_unit: $pass passed, $fail failed"
(( fail == 0 ))
