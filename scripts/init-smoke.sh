#!/bin/bash
# init-smoke.sh (DIVE-7337) — take ONE agent type from a fresh box through
# install.sh, `5dive init` (answered on a real terminal) and the agent's first
# reply. harness-smoke (DIVE-7115) stops before sign-in and makes no AI call,
# so it was green on all three things the 2026-10-30 init QA found: a Hermes
# agent dead on arrival (DIVE-7330), Codex/Grok signed out (DIVE-7335) and
# `agent list` broken on 22.04 (DIVE-7331).
#
#   init-smoke.sh list-cells                 print every cell this smoke runs
#   init-smoke.sh run <cell> <os-label>      run the arm (inside the smoke container)
#
# `run` expects docker/harness-smoke.Dockerfile, booted, with the tree staged at
# /opt/5dive-bundle and the driver at /usr/local/sbin/init-smoke-drive. The key
# comes in $INIT_SMOKE_KEY. It writes /init-smoke-result.json; result is pass,
# fail, or skip (no test key: install and init still ran, on a placeholder key,
# and the reply was not asked). A red names the cell, the OS and the step:
#
#   install-5dive  install.sh from the tree under test did not finish
#   init           `5dive init` stopped, asked something unexpected, or failed
#   pin            the seat could not be put on the cheapest model
#   reply          the agent's own answer never arrived, or was wrong
#   webchat        (hermes, openclaw) a 5dive app chat message got no answer, or a wrong one
#
# The reply is graded on the agent's TEXT: it is asked a sum and must answer
# it. The self-check and `agent list` both said ready on the dead Hermes seat.
set -uo pipefail

STEP="" CELL="" OS="" DETAIL=""
RESULT=/init-smoke-result.json
NAME=my-agent
PLACEHOLDER=0

# cell -> type, provider key, init answers. Sign-in-only paths (ChatGPT, Grok)
# stay manual: they need a person at a browser.
CELLS=(claude openclaw hermes-sandboxed hermes-standard codex)

list_cells() { printf '%s\n' "${CELLS[@]}"; }

cell_type() { printf '%s' "${1%%-*}"; }

# The key family each cell's provider bills: the workflow passes the matching
# repo secret.
cell_key() { case "$1" in codex) printf openai ;; *) printf anthropic ;; esac; }

json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

finish() {
  local result="$1"
  printf '{"cell":%s,"os":%s,"step":%s,"result":%s,"detail":%s}\n' \
    "$(json_str "$CELL")" "$(json_str "$OS")" "$(json_str "$STEP")" \
    "$(json_str "$result")" "$(json_str "$DETAIL")" > "$RESULT"
  echo "INIT-SMOKE ${result^^} cell=$CELL os=$OS${STEP:+ step=$STEP}${DETAIL:+: $DETAIL}" >&2
  [[ "$result" == fail ]] && exit 1
  exit 0
}

step() { STEP="$1"; echo; echo "=== [$CELL / $OS] $STEP"; }

# init's answers, as a person picks them: by the label on the menu line.
steps_json() {
  local cell="$1" type label auth="" provider="" channel=1 iso=""
  type=$(cell_type "$cell")
  case "$type" in
    claude)   label="Claude Code"; auth="Anthropic API key" ;;
    codex)    label="Codex"; auth="OpenAI API key"; channel=0 ;;
    openclaw) label="OpenClaw"; provider="Anthropic" ;;
    hermes)   label="Hermes"; provider="Anthropic" ;;
  esac
  case "$cell" in
    hermes-sandboxed) iso="Sandboxed" ;;
    hermes-standard)  iso="Standard" ;;
  esac
  python3 - "$label" "$auth" "$provider" "$channel" "$iso" <<'PY'
import json, sys
label, auth, provider, channel, iso = sys.argv[1:6]
menu = r'[\s\S]*?Choose \[\d+\]: '
s = [{'wait': 'Pick an agent type:' + menu, 'pick': label}]
# The agent tool installs between the type pick and the next prompt.
if auth:
    s.append({'wait': 'How should ' + label + ' authenticate\\?' + menu, 'pick': auth, 'secs': 1500})
    s.append({'wait': auth + ': ', 'secret': True})
else:
    s.append({'wait': 'Choose a provider for ' + label + ':' + menu, 'pick': provider, 'secs': 1500})
    s.append({'wait': provider.lower() + ' API key: ', 'secret': True})
s.append({'wait': r'Agent name \[my-agent\]: ', 'send': '\n', 'secs': 600})
if channel == '1':
    s.append({'wait': r'Where do you want to talk to [a-z0-9-]+\?' + menu, 'pick': 'Terminal only'})
if iso:
    s.append({'wait': 'Pick isolation:' + menu, 'pick': iso})
else:
    s.append({'wait': 'Pick isolation:' + menu, 'send': '\n'})
s.append({'wait': r'Ready to create [a-z0-9-]+\?' + menu, 'pick': 'Create agent'})
print(json.dumps(s, indent=1))
PY
}

seat_up() {
  local unit="5dive-agent@${NAME}.service" _
  for _ in $(seq 1 60); do
    systemctl is-active --quiet "$unit" \
      && sudo -u "agent-${NAME}" tmux has-session -t "agent-${NAME}" 2>/dev/null && return 0
    sleep 3
  done
  return 1
}

show_seat() {
  echo "--- pane (agent-$NAME) ---"
  sudo -u "agent-${NAME}" tmux capture-pane -p -t "agent-${NAME}" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -30 || true
  echo "--- journal (5dive-agent@$NAME) ---"
  journalctl -u "5dive-agent@${NAME}" --no-pager -n 40 2>/dev/null || true
  echo "--- agent list ---"
  5dive agent list 2>&1 | tail -5 || true
}

# The cheapest model, set before the first message: a night costs cents.
pin_model() {
  local type="$1" haiku out rc=0
  haiku=$(sed -n '/^model_latest()/,/^}/p' "$(command -v 5dive)" \
    | sed -n 's/^[[:space:]]*haiku)[[:space:]]*printf .%s. "\([^"]*\)".*/\1/p' | head -1)
  [[ -n "$haiku" ]] || { DETAIL="could not read the haiku model id from the installed CLI"; return 1; }
  case "$type" in
    claude)
      out=$(5dive agent config "$NAME" set model=haiku 2>&1) || rc=$? ;;
    codex)
      out=$(5dive agent config "$NAME" set "model=${INIT_SMOKE_CODEX_MODEL:-gpt-5-mini}" 2>&1) || rc=$? ;;
    openclaw)
      # `agent config set model=` refuses openclaw (init QA defect 6), so
      # openclaw's own CLI, as the seat user, as a person would.
      out=$(sudo -u "agent-${NAME}" -H env "PATH=/home/claude/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        openclaw models set "anthropic/$haiku" 2>&1) || rc=$?
      (( rc == 0 )) && { systemctl restart "5dive-agent@${NAME}" || rc=$?; } ;;
    hermes)
      # The shared config.yaml is authoritative: the seat's start seeds its own
      # copy from it on every boot (bin/5dive-agent-start, seed_one content).
      # Edited as text, so a hermes that cannot run still gets its pin and the
      # reply step, not this one, names what is wrong.
      out=$(python3 - "/home/claude/.hermes/config.yaml" "$haiku" <<'PY' 2>&1
import re, sys
p, m = sys.argv[1:3]
lines = open(p).read().split('\n')
inm, done = False, False
for i, l in enumerate(lines):
    if re.match(r'^model:\s*$', l):
        inm = True; continue
    if inm and re.match(r'^\S', l):
        break
    if inm and re.match(r'^\s+default:', l):
        lines[i] = re.sub(r'default:.*', 'default: ' + m, l); done = True
if not done:
    sys.exit('no model.default in ' + p)
open(p, 'w').write('\n'.join(lines))
print('model.default = ' + m)
PY
) || rc=$?
      (( rc == 0 )) && { systemctl restart "5dive-agent@${NAME}" || rc=$?; } ;;
  esac
  printf '%s\n' "$out" | tail -5
  (( rc == 0 )) || { DETAIL="$type model pin exited $rc: $(printf '%s' "$out" | tail -1)"; return 1; }
  echo "pinned $type to the cheapest model ($haiku for Anthropic)"
}

# DIVE-7349: the 5dive app chat on hermes and openclaw seats. A message is left
# where the control plane leaves one (the seat's dashboard inbox) and graded on
# what the seat's dashboard bridge posts back. The control plane itself is not
# in the container, so a stand-in on loopback answers the bridge's calls and
# records the reply: everything from the inbox to the outbound POST is real,
# the seat's gateway and model included.
cell_has_webchat() { case "$(cell_type "$1")" in hermes|openclaw) return 0 ;; *) return 1 ;; esac; }

FAKE_API_PORT=18999
start_fake_api() {
  python3 - "$FAKE_API_PORT" /tmp/webchat-replies.jsonl >/tmp/fake-api.log 2>&1 <<'PY' &
import http.server, json, sys, time, urllib.parse
port, log = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def _ok(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def _route(self):
        u = urllib.parse.urlparse(self.path)
        n = int(self.headers.get('content-length') or 0)
        body = self.rfile.read(n) if n else b''
        if u.path == '/server/messages/pending':
            # A long poll waits like the real one, so the bridge does not spin.
            wait = int(urllib.parse.parse_qs(u.query).get('wait', ['0'])[0] or 0)
            time.sleep(min(wait, 20)); return self._ok({'pending': []})
        if u.path == '/server/messages/pending/ack': return self._ok({'ok': True, 'acked': 0})
        if u.path == '/server/messages/event':
            with open(log, 'a') as f: f.write(body.decode() + '\n')
            return self._ok({'id': 1})
        return self._ok({})
    do_GET = do_POST = _route
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PY
}

webchat_arm() {
  local home inbox a b want out _
  home=$(getent passwd "agent-${NAME}" | cut -d: -f6)
  start_fake_api
  : > /tmp/webchat-replies.jsonl
  # The bridge's own override file (plugins/dashboard/server.ts reads it at boot).
  install -d -o "agent-${NAME}" -m 700 "$home/.claude" "$home/.claude/channels" "$home/.claude/channels/dashboard"
  printf 'DASHBOARD_API_BASE=http://127.0.0.1:%s\nCONNECTORD_TOKEN=init-smoke-not-a-token\n' "$FAKE_API_PORT" \
    > "$home/.claude/channels/dashboard/.env"
  chown "agent-${NAME}" "$home/.claude/channels/dashboard/.env"
  out=$(5dive agent config "$NAME" set channels=dashboard 2>&1) || {
    DETAIL="agent config set channels=dashboard failed: $(printf '%s' "$out" | tail -1)"; return 1; }
  printf '%s\n' "$out" | tail -5
  seat_up || { DETAIL="the seat did not come back up with the web chat on"; return 1; }
  sleep 20
  a=$((RANDOM % 400 + 100)) b=$((RANDOM % 400 + 500)) want=$((a + b))
  inbox="$home/.claude/channels/dashboard/agent-inbox"
  # The shelld drop contract: a temp name, then a rename to *.json.
  jq -cn --arg t "What is $a + $b? Reply with only the number." '{text: $t, chat_id: "dashboard"}' \
    | sudo -u "agent-${NAME}" bash -c 'mkdir -p "$1" && cat > "$1/.m.tmp" && mv "$1/.m.tmp" "$1/m.json"' _ "$inbox"
  for _ in $(seq 1 100); do
    grep -q . /tmp/webchat-replies.jsonl 2>/dev/null && break
    sleep 3
  done
  echo "--- web chat replies ---"; cat /tmp/webchat-replies.jsonl
  if ! grep -q . /tmp/webchat-replies.jsonl; then
    DETAIL="a web chat message got no reply in 300s"; return 1
  fi
  if ! jq -r '.body // empty' /tmp/webchat-replies.jsonl | grep -qw -- "$want"; then
    DETAIL="web chat: asked $a + $b, the reply did not say $want: $(jq -r '.body // empty' /tmp/webchat-replies.jsonl | tail -1 | cut -c1-300)"
    return 1
  fi
  echo "the web chat answered $want"
}

run_arm() {
  CELL="$1" OS="$2"
  local type rc=0 a b want out
  type=$(cell_type "$CELL")
  printf '%s\n' "${CELLS[@]}" | grep -qx "$CELL" || { DETAIL="unknown cell '$CELL'"; finish fail; }
  if [[ -z "${INIT_SMOKE_KEY:-}" ]]; then
    # No test key in the repo's secrets: init still runs end to end on a key
    # nobody will accept (no init step checks it), and the reply is not asked.
    PLACEHOLDER=1
    INIT_SMOKE_KEY="sk-init-smoke-placeholder-$(cell_key "$CELL")-not-a-key"
  fi
  export INIT_SMOKE_KEY

  step install-5dive
  timeout 1200 env REPO=file:///opt/5dive-bundle bash /opt/5dive-bundle/install.sh >/tmp/install.log 2>&1 || rc=$?
  tail -5 /tmp/install.log
  (( rc == 0 )) || { DETAIL="install.sh exited $rc: $(tail -1 /tmp/install.log)"; finish fail; }
  command -v 5dive >/dev/null || { DETAIL="install.sh finished but 5dive is not on PATH"; finish fail; }
  echo "5dive $(5dive --version 2>&1 | head -1)"

  step init
  steps_json "$CELL" > /tmp/init-steps.json
  rc=0
  timeout 3000 python3 /usr/local/sbin/init-smoke-drive /tmp/init-steps.json /tmp/init.log /tmp/init-drive.json || rc=$?
  tail -40 /tmp/init.log
  DETAIL=$(jq -r '.detail // empty' /tmp/init-drive.json 2>/dev/null) || DETAIL=""
  [[ -n "$DETAIL" ]] || DETAIL="the init driver exited $rc without a result"
  (( rc == 0 )) || { show_seat; finish fail; }
  echo "init: $DETAIL in $(jq -r .secs /tmp/init-drive.json)s"
  DETAIL=""
  seat_up || { DETAIL="init said ready, but the seat's unit or tmux session is not up"; show_seat; finish fail; }

  step pin
  pin_model "$type" || { show_seat; finish fail; }
  seat_up || { DETAIL="the seat did not come back up after the model pin"; show_seat; finish fail; }

  step reply
  if (( PLACEHOLDER )); then
    DETAIL="no $(cell_key "$CELL") test key in the repo secrets: install, init and pin ran on a placeholder key; the reply was not asked"
    show_seat
    finish skip
  fi
  # A sum, so the answer is in no text the CLI or the question printed: only
  # the agent can have written it.
  a=$((RANDOM % 400 + 100)) b=$((RANDOM % 400 + 500)) want=$((a + b))
  sleep 15
  rc=0
  out=$(timeout 400 5dive agent ask "$NAME" "What is $a + $b? Reply with only the number." --timeout=300 2>&1) || rc=$?
  printf '%s\n' "$out" | tail -15
  if grep -qw -- "$want" <<<"$out"; then
    echo "the agent answered $want"
    if cell_has_webchat "$CELL"; then
      step webchat
      webchat_arm || { show_seat; finish fail; }
    fi
    STEP="" DETAIL=""
    finish pass
  fi
  DETAIL="asked $a + $b, the reply did not say $want (ask exited $rc): $(printf '%s' "$out" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-300)"
  show_seat
  finish fail
}

case "${1:-}" in
  list-cells) list_cells ;;
  steps) shift; steps_json "$1" ;;
  run) shift; [[ $# -eq 2 ]] || { echo "usage: $0 run <cell> <os-label>" >&2; exit 2; }; run_arm "$@" ;;
  *) echo "usage: $0 list-cells | steps <cell> | run <cell> <os-label>" >&2; exit 2 ;;
esac
