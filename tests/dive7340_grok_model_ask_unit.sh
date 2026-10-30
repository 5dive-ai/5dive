#!/usr/bin/env bash
# DIVE-7340 — a Grok agent: `config set model=` must move the model Grok runs,
# and `agent ask` must read Grok's reply and refuse Grok's sign-in screen.
#
# Found by the 2026-10-30 init QA (cell G, grok 1.0.70): `set model=` wrote a
# top-level `model =` that Grok ignores and said OK; `ask` timed out twice while
# Grok had answered in ~3 s, because Grok never paints the answer in its pane
# and the reply only exists in ~/.grok/sessions/<cwd>/<id>/updates.jsonl; and on
# a signed-out seat `ask` typed the question into Grok's sign-in screen.
#
# Offline: sudo is stubbed (the real python reader runs as the test user); the
# config writer runs on a fixture home under AGENT_HOME_ROOT.
#
#   M1  `[models] default` written into a boot-shaped config (telegram MCP
#       table, stale top-level model): table kept, stale line gone, read back.
#   M2  an existing `[models] default` is replaced, its neighbours kept.
#   M3  an empty config gets a `[models]` table.
#   R1  the reply streamed as several agent_message_chunk records comes back.
#   R2  no fabrication: only the question (markers adjacent, a user chunk) → rc 1.
#   R3  another ask's fence is never this ask's reply → rc 1.
#   C1  Grok's sign-in screen is a credential pane; its chat screen is not.
#   C2  the refusal says the agent is not signed in.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
WORK=""
trap 'rc=$?; [[ -n "$WORK" ]] && rm -rf "$WORK"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_agent.sh cmd_agent_runtime.sh; do
  # shellcheck disable=SC1090
  source "src/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

WORK=$(mktemp -d)
export AGENT_HOME_ROOT="$WORK/home"
chown() { :; }
sudo() {
  case " $* " in
    *" python3 -c "*) shift 3; "$@"; return ;;   # -n -u agent-<x> python3 … → run the real reader
  esac
  return 1
}

# --- config set model= -------------------------------------------------------
CFG="$AGENT_HOME_ROOT/agent-gk/.grok/config.toml"
# What Grok itself reads: models.default, parsed as TOML (not our own reader,
# which would agree with whatever key our writer used).
tdef() { python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb")).get("models",{}).get("default",""))' "$CFG" 2>&1; }
mkdir -p "$(dirname "$CFG")"

printf '%s\n' 'model = "grok-4.7-build-fast"' '' '[mcp_servers.telegram]' 'command = "bun"' \
  'args = ["/usr/local/lib/5dive/telegram-grok/server.ts"]' > "$CFG"
( write_runtime_model grok gk grok-4.5 ) 2>/dev/null
eq_t "M1 Grok reads the new model" "grok-4.5" "$(tdef)"
eq_t "M1 agent info reads it too" "grok-4.5" "$(resolve_agent_model grok gk)"
grep -q '^\[mcp_servers\.telegram\]' "$CFG" && grep -q 'telegram-grok/server.ts' "$CFG" \
  && ok_t "M1 telegram MCP table kept" || bad_t "M1 telegram MCP table kept" "$(cat "$CFG")"
grep -q '^model[[:space:]]*=' "$CFG" && bad_t "M1 stale top-level model dropped" "$(cat "$CFG")" \
  || ok_t "M1 stale top-level model dropped"

printf '%s\n' '[cli]' 'installer = "internal"' '' '[models]' 'default = "grok-4.7"' \
  'default_reasoning_effort = "low"' '' '[ui]' 'vim_mode = false' > "$CFG"
( write_runtime_model grok gk grok-4.6 ) 2>/dev/null
eq_t "M2 existing default replaced" "grok-4.6" "$(tdef)"
eq_t "M2 one default line" "1" "$(grep -c '^default[[:space:]]*=' "$CFG")"
grep -q 'default_reasoning_effort = "low"' "$CFG" && grep -q '^vim_mode = false' "$CFG" \
  && ok_t "M2 neighbouring keys kept" || bad_t "M2 neighbouring keys kept" "$(cat "$CFG")"

: > "$CFG"
( write_runtime_model grok gk grok-4.7 ) 2>/dev/null
eq_t "M3 empty config gets [models]" "grok-4.7" "$(tdef)"

# --- agent ask reads Grok's session file ---------------------------------------
export FIVE_ASK_TRANSCRIPT_ROOT="$WORK/claude-projects" FIVE_ASK_GROK_SESSIONS_ROOT="$WORK/grok-sessions"
mkdir -p "$FIVE_ASK_TRANSCRIPT_ROOT"
SDIR="$FIVE_ASK_GROK_SESSIONS_ROOT/%2Fhome%2Fagent-gk/0b8f6e1c-1111-4222-8333-944445555666"
UPD="$SDIR/updates.jsonl"
MID="a1b2c3d4"
upd() { jq -cn --arg k "$1" --arg t "$2" '{sessionId:"0b8f6e1c", update:{sessionUpdate:$k, content:{type:"text", text:$t}}}'; }
q_rec() { upd user_message_chunk "[5dive-msg from=owner id=${MID}] what model are you? [reply-format] Put your answer between these two marker lines: <5dive-r:${MID}></5dive-r:${MID}>"; }
mkdir -p "$SDIR"

{ q_rec
  upd agent_thought_chunk "The user asks which model."
  upd agent_message_chunk "<5dive-r:${MID}>"$'\n'"I am Grok 4.5, "
  upd agent_message_chunk "built by xAI."$'\n'"</5dive-r:${MID}>"
} > "$UPD"
eq_t "R1 chunked reply read from updates.jsonl" "I am Grok 4.5, built by xAI." "$(_ask_transcript_reply gk "$MID")"

q_rec > "$UPD"
out=$(_ask_transcript_reply gk "$MID"); rc=$?
[[ $rc -ne 0 && -z "$out" ]] && ok_t "R2 the question alone is no reply" || bad_t "R2 the question alone is no reply" "rc=$rc out=[$out]"

{ q_rec; upd agent_message_chunk "<5dive-r:ffff0000>"$'\n'"another ask"$'\n'"</5dive-r:ffff0000>"; } > "$UPD"
out=$(_ask_transcript_reply gk "$MID"); rc=$?
[[ $rc -ne 0 && -z "$out" ]] && ok_t "R3 another ask's fence is not this reply" || bad_t "R3 another ask's fence is not this reply" "rc=$rc out=[$out]"

# --- Grok's sign-in screen -------------------------------------------------------
SIGNIN=$'  Sign in to Grok\n\n  A browser window will open for authentication.\n  Approve in your browser to finish signing in.\n\n  Code: H4AS-0000\n  Waiting for approval...\n  Make sure your browser shows this code.'
CHAT=$'  what model are you?\n\n  Worked for 2.3s\n\n  Help improve Grok [Opt out] [Opt in]\n ❯ \n  Grok 4.5 (low)'
_agent_pane_credential_prompt "$SIGNIN" && ok_t "C1 sign-in screen refused" || bad_t "C1 sign-in screen refused"
_agent_pane_credential_prompt "$CHAT" && bad_t "C1 chat screen not refused" || ok_t "C1 chat screen not refused"
_agent_cred_seed_failure() { :; }
msg=$(_AGENT_PANE_REFUSAL_REASON=credential _agent_credential_refusal_msg gk)
grep -q "agent 'gk' is not signed in" <<<"$msg" && ok_t "C2 refusal says not signed in" || bad_t "C2 refusal says not signed in" "$msg"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
