#!/usr/bin/env bash
# DIVE-6843 — an agent never builds an agent on the box's free demo AI. On a fresh
# box a lead made a Grok trend agent on it (--auth-profile=demo-ai, the demo key
# piped to --api-key=-) and one run used the whole allowance. Graded here:
#   1. the caller rule (_create_caller_is_agent) over the cgroups that matter,
#      through the REAL _gate_cgroup_human_capable;
#   2. the demo-AI rule (_create_uses_demo_ai): by account name and by copied key;
#   3. the import default (_import_demo_ai_default) never binds demo-ai for an agent;
#   5. the built binary refuses the account, and still passes a normal one on.
#      DIVE-7084: a codex hire there uses the box's codex login when the box has
#      one, and with none the refusal points at that one box login.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && { sudo -n rm -rf "$TMP" 2>/dev/null || rm -rf "$TMP"; }; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

CREATE=src/cmd_agent_create.sh
# fn <file> <name> — extract one top-level function from the shipped source.
fn() { awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" { on = 1 } on { print } on && $0 == "}" { exit }' "$1"; }
for f in _create_caller_is_agent _create_demo_ai_key _create_uses_demo_ai; do
  eval "$(fn "$CREATE" "$f")"
  declare -F "$f" >/dev/null || { bad_t "extract $f from $CREATE" "not found"; echo "pass=$PASS fail=$FAIL"; exit 1; }
done
eval "$(grep -m1 '^CREATE_DEMO_AI_ACCOUNT=' "$CREATE")"
for f in _gate_cgroup_pick_line _gate_cgroup_human_capable; do eval "$(fn src/lib/tasks_db.sh "$f")"; done

TMP=$(mktemp -d)
# The systemd template unit of agent olivia. The @ is built, not typed, so a
# fixture scanner does not read the unit name as an address.
AT='@'; AGENT_UNIT="/system.slice/system-5dive\\x2dagent.slice/5dive-agent${AT}olivia.service"

echo '== 1. who is an agent =='
CG=""
_gate_caller_cgroup() { printf '%s' "$CG"; }
_gate_is_root() { return 0; }   # the arms model a real `sudo 5dive` (euid 0)
who() { CG="$2"; if [[ -n "$1" ]]; then SUDO_UID="$1" _create_caller_is_agent; else (unset SUDO_UID; _create_caller_is_agent); fi && echo agent || echo owner; }
eq_t 'an agent unit through sudo is an agent' agent "$(who 1001 "$AGENT_UNIT")"
eq_t 'the primary claude session through sudo is an agent' agent "$(who 1000 /system.slice/claude-session.service)"
eq_t "an agent's cron job through sudo is an agent" agent "$(who 1000 /system.slice/cron.service)"
eq_t 'the Mini App / dashboard (shelld) is the owner' owner "$(who 1000 /system.slice/shelld.service)"
eq_t "a person's login session is the owner" owner "$(who 1000 /user.slice/user-1000.slice/session-3.scope)"
eq_t 'root with no sudo (provisioning) is not an agent' owner "$(who '' /system.slice/cloud-final.service)"

echo '== 2. what is the demo AI =='
AUTH_PROFILES_DIR="$TMP/auth-profiles"
mkdir -p "$AUTH_PROFILES_DIR/demo-ai"
printf 'ANTHROPIC_AUTH_TOKEN=sk-or-v1-fixturedemo\nANTHROPIC_BASE_URL=https://openrouter.ai/api\n' > "$AUTH_PROFILES_DIR/demo-ai/combined.env"
uses() { _create_uses_demo_ai "$1" "$2" && echo demo || echo own; }
eq_t 'naming the demo-ai account' demo "$(uses demo-ai '')"
eq_t 'the demo key copied under a new account name' demo "$(uses trends sk-or-v1-fixturedemo)"
eq_t "the owner's own key" own "$(uses trends sk-or-v1-ownersown)"
eq_t 'no key, another account' own "$(uses trends '')"
mkdir -p "$AUTH_PROFILES_DIR/saved"
printf 'ANTHROPIC_AUTH_TOKEN=sk-or-v1-fixturedemo\n' > "$AUTH_PROFILES_DIR/saved/combined.env"
eq_t 'an account the demo key was saved into first' demo "$(uses saved '')"
printf 'ANTHROPIC_AUTH_TOKEN=sk-or-v1-ownersown\n' > "$AUTH_PROFILES_DIR/saved/combined.env"
eq_t "an account holding the owner's own key" own "$(uses saved '')"
rm -rf "$AUTH_PROFILES_DIR/saved"
rm -rf "$AUTH_PROFILES_DIR/demo-ai"
eq_t 'no demo-ai on the box: a key is never the demo key' own "$(uses trends sk-or-v1-fixturedemo)"

echo '== 3. an agent-run import never defaults to demo-ai =='
# shellcheck source=/dev/null
source src/lib/error_codes.sh; source src/lib/output.sh; source src/lib/validation.sh
# shellcheck source=/dev/null
STATE_DIR="$TMP/state"; source src/cmd_auth.sh
set +e
eval "$(fn src/cmd_pack.sh _import_demo_ai_default)"
eval "$(grep -m1 '^IMPORT_DEMO_AI_ACCOUNT=' src/cmd_pack.sh)"
AUTH_PROFILES_DIR="$TMP/auth-profiles"; CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR" "$AUTH_PROFILES_DIR/demo-ai"
declare -A TYPE_AUTH=([claude]="$CONNECTORS_DIR/anthropic.env:CLAUDE_CODE_OAUTH_TOKEN")
declare -A TYPE_API_FILE=([claude]="anthropic.env")
printf 'ANTHROPIC_AUTH_TOKEN=sk-or-v1-fixturedemo\n' > "$AUTH_PROFILES_DIR/demo-ai/combined.env"
imp() { CG="$1"; SUDO_UID=1000 _import_demo_ai_default claude && echo bind || echo keep; }
eq_t 'the dashboard hire still binds demo-ai' bind "$(imp /system.slice/shelld.service)"
eq_t "a lead's import keeps the per-agent sign-in" keep "$(imp "$AGENT_UNIT")"

echo '== 4. wiring =='
g=$(grep -n '_create_uses_demo_ai "$profile" "$byo_api_key" && _create_caller_is_agent' "$CREATE" | head -1 | cut -d: -f1)
k=$(grep -n 'byo_api_key=$(cat)' "$CREATE" | head -1 | cut -d: -f1)
u=$(grep -n 'create_agent_user "$name" "$isolation"' "$CREATE" | head -1 | cut -d: -f1)
if [[ -n "$g" && -n "$k" && -n "$u" && $k -lt $g && $g -lt $u ]]; then
  ok_t "guard reads the piped key and runs before the agent user exists ($k < $g < $u)"
else
  bad_t 'guard order' "stdin=${k:-?} guard=${g:-?} create_agent_user=${u:-?}"
fi

echo '== 5. built binary =='
SUDO=""; [[ $EUID -eq 0 ]] || { sudo -n true 2>/dev/null && SUDO="sudo -n"; }
CG=$(_gate_cgroup_pick_line </proc/self/cgroup 2>/dev/null || true)
# ensure_state's `chown root:claude` aborts under `set -e` before the guard runs
# on a pristine runner, which has no claude group. Replicate the install
# invariant (same as grok_freeze_guard_unit.sh); on CI a missing group is a red,
# never a skip, or the binary arm runs nowhere.
if [[ -x ./5dive && -n "$SUDO$([[ $EUID -eq 0 ]] && echo root)" ]]; then
  getent group claude >/dev/null 2>&1 || $SUDO groupadd claude 2>/dev/null || true
fi
if [[ -n "${GITHUB_ACTIONS:-}" ]] && ! getent group claude >/dev/null 2>&1; then
  bad_t 'binary: fixture could not create the claude group' "$(id)"
fi
if [[ -x ./5dive && -n "$SUDO" ]] && ! _gate_cgroup_human_capable; then
  # This harness runs as a sudo caller outside shelld and a login session, so it
  # IS an agent to the guard. A bad codex --model is the barrier right after it:
  # reaching that error means the guard let the create through.
  # FIVEDIVE_CONNECTOR_DIR keeps a host's shared API key out of the fixture.
  S="$TMP/bin-state"; mkdir -p "$S/auth-profiles/demo-ai" "$S/connectors"
  printf 'ANTHROPIC_AUTH_TOKEN=sk-or-v1-fixturedemo\n' > "$S/auth-profiles/demo-ai/combined.env"
  mk() { $SUDO env STATE_DIR="$S" FIVEDIVE_CONNECTOR_DIR="$S/connectors" ./5dive agent create trends "$@" --model='bad model' 2>&1; }
  # No codex login on the box: still refused. The next step is the box's one
  # codex sign-in, not an account per hire (DIVE-7084).
  if $SUDO test -s /home/claude/.codex/auth.json 2>/dev/null; then
    echo '  skip no-login arms (this host has a shared codex login)'
  else
    out=$(mk --type=codex --auth-profile=demo-ai)
    grep -qF "free demo AI is the owner's trial" <<<"$out" \
      && ok_t 'binary: an agent creating on demo-ai is refused' || bad_t 'binary: demo-ai not refused' "$out"
    grep -qF 'sudo 5dive agent auth start codex (later codex hires use that same sign-in)' <<<"$out" \
      && ok_t 'binary: the refusal names the box sign-in verb' || bad_t 'binary: no box sign-in next step' "$out"
    grep -qF -- '--auth-profile=trends' <<<"$out" \
      && bad_t 'binary: the refusal still asks for an account per hire' "$out" || ok_t 'binary: no account per hire'
  fi
  # One codex account on the box: the demo-ai hire uses it, past the guard.
  # The create above ran ensure_state, which made $S root:claude 2750, so the
  # runner can no longer write here: add the account as the binary's user.
  $SUDO mkdir -p "$S/auth-profiles/mine"
  printf 'OPENAI_API_KEY=sk-fixture\n' | $SUDO tee "$S/auth-profiles/mine/combined.env" >/dev/null
  out=$(mk --type=codex --auth-profile=demo-ai)
  grep -qF "using this box's codex login" <<<"$out" && grep -qF "invalid --model" <<<"$out" \
    && ok_t "binary: a codex hire on demo-ai uses the box's codex login" || bad_t 'binary: demo-ai hire did not use the box login' "$out"
  grep -qF "free demo AI is the owner's trial" <<<"$out" \
    && bad_t 'binary: refused although the box has a codex login' "$out" || ok_t 'binary: not refused when the box has a codex login'
  out=$(mk --type=codex --auth-profile=mine)
  grep -qF "invalid --model" <<<"$out" \
    && ok_t "binary: the owner's own account passes the guard" || bad_t 'binary: own account wrongly refused' "$out"
else
  echo '  skip binary (need built ./5dive, sudo -n, and a non-owner cgroup)'
fi

echo
echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
