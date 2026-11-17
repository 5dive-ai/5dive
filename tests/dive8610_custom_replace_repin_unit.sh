#!/usr/bin/env bash
# DIVE-8610 unit: `account add <n> --provider=custom ... --replace` moves the
# claude seats on the account to the new model.
#
# The defect: a claude seat pins its model in its own settings.json (create
# starts it on the account's id), and Claude Code asks the server for that pin.
# --replace rewrote the account and restarted the seats, but every seat kept
# asking for the OLD model: the server 404'd and the office chat sat on
# "Working…" with no message (DIVE-8608 e2e, snag S1).
#
# WHAT IS ASSERTED (against the shipped cmd_account_custom.sh, sourced):
#   R1  a seat pinned to the old model moves to the new one (settings.json)
#   R2  a seat pinned to one of the old TIER ids (haiku slot) moves too
#   R2b a seat on an Anthropic claude-* id moves too (the e2e seat's pin)
#   R3  a bare alias (sonnet) is left alone: the account's map carries it
#   R4  a deliberate pin to some other id is left alone
#   R5  a seat on ANOTHER account is never touched
#   R6  a codex seat on the account is not written (its start script renders it)
#   R7  a parked seat is moved too (not restarted), so it starts right
#   R8  the registry's own `model` field follows the move
#   R9  a first save (no --replace, account new) moves nothing
#   R10 a seat that cannot be written is named with the one command that fixes it
#   M1  mutation: with the re-pin call removed, R1 goes red
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1 (expected '$2', got '$3')"; fi; }

load() {
  local f
  for f in src/header.sh src/lib/error_codes.sh src/lib/output.sh src/lib/validation.sh src/lib/local_only.sh "$1"; do
    # shellcheck source=/dev/null
    source "$f"
  done
  set +e
  export FIVE_REPORTED_FLAG="$TMP/reported" FIVE_LOCAL_ONLY_FILE="$TMP/local-only"
  JSON_MODE=1
  require_root() { :; }
  step() { :; }
  ensure_profile_dir() { :; }
  profile_set_var() { cat >/dev/null; }
  _apply_byo_claude() { :; }
  systemctl() { echo "$*" >> "$TMP/sysctl"; }
  # The old account: model A on the custom server, haiku slot A-small.
  profile_env_value() {
    case "$2" in
      FIVEDIVE_CUSTOM_BASE_URL) echo "http://10.0.0.1:11434" ;;
      FIVEDIVE_CUSTOM_MODEL|ANTHROPIC_DEFAULT_OPUS_MODEL|ANTHROPIC_DEFAULT_SONNET_MODEL) echo "qwen-a:7b" ;;
      ANTHROPIC_DEFAULT_HAIKU_MODEL) echo "qwen-a:1b" ;;
      *) echo "" ;;
    esac
  }
  REGISTRY="$TMP/registry.json"
  registry_read() { cat "$REGISTRY"; }
  registry_write() { cat > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"; }
  resolve_agent_model() { cat "$TMP/home/$2.model" 2>/dev/null || true; }
  write_runtime_model() {
    [[ "$2" == broken ]] && { echo "no claude runtime config" >&2; return 1; }
    printf '%s' "$3" > "$TMP/home/$2.model"; echo "$2" >> "$TMP/writes"
  }
  model_latest() { case "$1" in opus|sonnet|haiku) echo "claude-$1-x" ;; *) return 1 ;; esac; }
  mkdir -p "$TMP/profiles/office"; AUTH_PROFILES_DIR="$TMP/profiles"
}

seed() {
  rm -rf "$TMP/home"; mkdir -p "$TMP/home"; : > "$TMP/sysctl"; : > "$TMP/writes"
  printf 'qwen-a:7b' > "$TMP/home/ann.model"     # on the old model
  printf 'qwen-a:1b' > "$TMP/home/bob.model"     # on the old haiku tier id
  printf 'sonnet'    > "$TMP/home/cat.model"     # bare alias
  printf 'mistral:7b' > "$TMP/home/dan.model"    # deliberate pin
  printf 'qwen-a:7b' > "$TMP/home/eve.model"     # other account, same id
  printf 'qwen-a:7b' > "$TMP/home/fay.model"     # parked, on the old model
  printf 'qwen-a:7b' > "$TMP/home/broken.model"  # cannot be written
  printf 'claude-haiku-4-5' > "$TMP/home/hal.model"  # an Anthropic id (the e2e seat)
  cat > "$REGISTRY" <<'JSON'
{"agents":{
 "ann":{"type":"claude","authProfile":"office","model":"qwen-a:7b"},
 "bob":{"type":"claude","authProfile":"office"},
 "cat":{"type":"claude","authProfile":"office"},
 "dan":{"type":"claude","authProfile":"office"},
 "eve":{"type":"claude","authProfile":"other"},
 "fay":{"type":"claude","authProfile":"office","desiredState":"stopped"},
 "gus":{"type":"codex","authProfile":"office"},
 "broken":{"type":"claude","authProfile":"office"},
 "hal":{"type":"claude","authProfile":"office"}}}
JSON
}

load src/cmd_account_custom.sh
seed
out=$( (cmd_account_add_custom office --provider=custom --base-url=http://10.0.0.2:11434 --model=qwen-b:14b --harness=claude --replace </dev/null) 2>&1); rc=$?
eq_t "R0 --replace saves (rc 0)" "0" "$rc"
eq_t "R1 a seat on the old model moves to the new one" "qwen-b:14b" "$(cat "$TMP/home/ann.model")"
eq_t "R2 a seat on an old tier id (haiku slot) moves too" "qwen-b:14b" "$(cat "$TMP/home/bob.model")"
eq_t "R2b a seat on an Anthropic claude-* id moves too (the DIVE-8608 e2e seat)" "qwen-b:14b" "$(cat "$TMP/home/hal.model")"
eq_t "R3 a bare alias is left alone (the account map carries it)" "sonnet" "$(cat "$TMP/home/cat.model")"
eq_t "R4 a deliberate pin to another id is left alone" "mistral:7b" "$(cat "$TMP/home/dan.model")"
eq_t "R5 a seat on another account is never touched" "qwen-a:7b" "$(cat "$TMP/home/eve.model")"
grep -qx gus "$TMP/writes" && bad_t "R6 the codex seat was written" || ok_t "R6 a codex seat on the account is not written (its start script renders the model)"
eq_t "R7a a parked seat is moved too" "qwen-b:14b" "$(cat "$TMP/home/fay.model")"
grep -q fay "$TMP/sysctl" && bad_t "R7b the parked seat was restarted" || ok_t "R7b the parked seat is still not restarted"
eq_t "R8 the registry model field follows the move" "qwen-b:14b" "$(jq -r '.agents.ann.model' "$REGISTRY")"
eq_t "R8b no model field is invented where there was none" "false" "$(jq -r '.agents.bob | has("model")' "$REGISTRY")"
[[ "$out" == *"sudo 5dive agent config broken set model=qwen-b:14b"* ]] \
  && ok_t "R10 a seat that cannot be written is named with its fix" || bad_t "R10 no fix named: $out"
eq_t "R0b the move restarts the running seats, as before" \
  "restart 5dive-agent@ann.service|restart 5dive-agent@bob.service|restart 5dive-agent@broken.service|restart 5dive-agent@cat.service|restart 5dive-agent@dan.service|restart 5dive-agent@gus.service|restart 5dive-agent@hal.service" \
  "$(sort "$TMP/sysctl" | paste -sd'|')"

# R9: a first save (the account had no server yet) moves nothing.
seed
rm -rf "$TMP/profiles/office"
out=$( (cmd_account_add_custom office --provider=custom --base-url=http://10.0.0.2:11434 --model=qwen-b:14b --harness=claude </dev/null) 2>&1); rc=$?
[[ $rc -eq 0 && ! -s "$TMP/writes" ]] && ok_t "R9 a first save moves no seat" || bad_t "R9 rc=$rc writes=$(cat "$TMP/writes")"
mkdir -p "$TMP/profiles/office"

# M1: the same run on a copy with the re-pin call removed must go red on R1.
sed '/^  _custom_ai_repin_claude_seats "\$name"/d' src/cmd_account_custom.sh > "$TMP/mutant.sh"
if grep -q '_custom_ai_repin_claude_seats "\$name"' "$TMP/mutant.sh"; then bad_t "M1 the mutation did not apply"; else
  ( source "$TMP/mutant.sh"; seed
    cmd_account_add_custom office --provider=custom --base-url=http://10.0.0.2:11434 --model=qwen-b:14b --harness=claude --replace </dev/null >/dev/null 2>&1
    [[ "$(cat "$TMP/home/ann.model")" == "qwen-a:7b" ]] ) \
    && ok_t "M1 mutation: without the re-pin the seat stays on the old model (R1 would be red)" \
    || bad_t "M1 the mutant still moved the seat — R1 does not test the fix"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
