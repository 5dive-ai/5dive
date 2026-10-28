#!/usr/bin/env bash
# DIVE-7184 — a key with several parts, and a second secret ask on one row.
# On a fresh self-hosted box (0.106.0, 2026-10-28) the owner asked olivia for an
# X API key, which is four values. She ran `task need --type=secret` four times
# on ONE row, one per value, and sent four links. Each filing replaced the gate
# before it and said nothing, so links 1-3 were dead (410). Opening link 1 then
# burned every link on the task, link 4 included (404 thirty seconds later).
#
#   K1-K4  --secret-key=A,B,C,D is one gate; bad lists are refused at filing;
#   R1-R5  a second secret gate for another key on the row is refused, the row
#          unchanged; the same key (the council's re-file) is accepted; any other
#          replacement says what it ended;
#   P1-P6  one link, one labelled box per key, one POST lands all four in
#          tools.sh and closes the gate through the real `task answer` with
#          gate-proof enforcement on; a bad box saves nothing and keeps the link;
#   S1-S2  opening a superseded link burns that link only (the link-4 death);
#   W1-W3  `secret write A,B` (the terminal line the alert prints), one line per
#          key, all checked first; the self-host match finds a gate by one key.
# Isolation: src/ libs, throwaway STATE_DIR; the live tasks.db is never touched.
# Run: bash tests/secret_multi_key_gate_unit.sh   (no root, no network beyond 127.0.0.1)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"
TMP="$(mktemp -d /tmp/secret-multi-key.XXXXXX)"

LIBS="header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh lib/self.sh cmd_task.sh cmd_tool.sh cmd_secret.sh cmd_secret_drop.sh"
for f in $LIBS; do
  # shellcheck source=/dev/null
  source "src/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable)\n' >&2

export STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
export CONNECTORS_DIR="$TMP/connectors"
SECRET_DROP_DIR="$STATE_DIR/secret-drop"
SECRET_DROP_CONF="$TMP/secret-drop.env"
SECRET_DROP_PROVISIONING="$TMP/provisioning.env"
SECRET_DROP_CADDYFILE="$TMP/Caddyfile"
SECRET_DROP_LOCK="$TMP/drop.lock"
SECRET_WRITE_LOCK="$TMP/write.lock"
SECRET_DROP_PROC_NET="$TMP/procnet"; mkdir -p "$SECRET_DROP_PROC_NET"
printf '  sl  local_address rem_address   st\n' > "$SECRET_DROP_PROC_NET/tcp"; cp "$SECRET_DROP_PROC_NET/tcp" "$SECRET_DROP_PROC_NET/tcp6"
TOOLS_ENV_FILE="$CONNECTORS_DIR/tools.sh"; TOOLS_WRITE_LOCK="$TMP/tools.lock"
export SECRET_PROJECTS_DIR="$TMP/projects"; mkdir -p "$SECRET_PROJECTS_DIR"
printf 'FIVE_DOMAIN=teal-fox.example.com\n' > "$SECRET_DROP_PROVISIONING"
require_root() { :; }
# The page and `sudo secret write` run as root, where a seat's own-key path
# never applies; a CI or seat user may hold that grant, so say what the box says.
_seat_secret_eligible() { return 1; }
_secret_link_agent_caller() { :; }
JSON_MODE=1
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { local name="$1"; shift; if "$@"; then ok_t "$name"; else bad_t "$name" "${DETAIL:-}"; fi; }

tasks_db_init
task_need_notify() { :; }
X4="X_API_KEY,X_API_SECRET,X_ACCESS_TOKEN,X_ACCESS_TOKEN_SECRET"
row() { db "INSERT INTO tasks (ident, title, status, created_by, assignee) VALUES ('$1','t','todo','main','olivia');"; }
need() { ( cmd_task_need "$@" ) 2>&1; }
col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident='$1';"; }
prev_gates() { db "SELECT COUNT(*) FROM gate_history WHERE task_id=(SELECT id FROM tasks WHERE ident='$1');" 2>/dev/null || echo 0; }
mint() { ( _secret_link "$@" --no-start ) 2>&1; }
tok_of() { printf '%s' "$1" | jq -r '.data.url // empty' | sed 's#.*/##'; }
hash_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
ASK="An X API key for posting: four values from developer.x.com"

# --- K: one gate for a key with several parts ---------------------------------
row DIVE-1
out=$(need DIVE-1 --type=secret --ask="$ASK" --secret-key="$X4" --connector=tools); rc=$?
DETAIL="rc=$rc key=$(col DIVE-1 secret_key) out=$out"
check "K1 --secret-key=A,B,C,D files ONE secret gate naming all four" \
  test "$rc" -eq 0 -a "$(col DIVE-1 need_type)" == secret -a "$(col DIVE-1 secret_key)" == "$X4"
row DIVE-2
o1=$(need DIVE-2 --type=secret --ask="$ASK" --secret-key="X_API_KEY,X_API_KEY" --connector=tools); r1=$?
o2=$(need DIVE-2 --type=secret --ask="$ASK" --secret-key="X_API_KEY,,X_API_SECRET" --connector=tools); r2=$?
o3=$(need DIVE-2 --type=secret --ask="$ASK" --secret-key="A1_KEY,A2_KEY,A3_KEY,A4_KEY,A5_KEY,A6_KEY,A7_KEY,A8_KEY,A9_KEY" --connector=tools); r3=$?
DETAIL="r1=$r1 r2=$r2 r3=$r3 type=$(col DIVE-2 need_type)"
check "K2 a key named twice, an empty part, or more than 8 is refused, nothing filed" \
  test "$r1" -ne 0 -a "$r2" -ne 0 -a "$r3" -ne 0 -a -z "$(col DIVE-2 need_type)" -a "${o1}" != "${o1/twice/}"
o4=$(need DIVE-2 --type=secret --ask="$ASK" --secret-key="X_API_KEY,ANTHROPIC_API_KEY" --connector=tools); r4=$?
DETAIL="r4=$r4 out=$o4"
check "K3 every part passes the tools reserved-name rule (a seat's own key is refused)" \
  bash -c '[[ "$1" != 0 && "$2" == *"--secret-key=ANTHROPIC_API_KEY is not allowed"* ]]' _ "$r4" "$o4"
_valid_env_keys "$X4" && ! _valid_env_keys "A,a" && ! _valid_env_keys ",A" && ! _valid_env_keys "A," && _valid_env_keys "ONE"
check "K4 _valid_env_keys: a list of names, one name, never a lower-case or empty part" test $? -eq 0

# --- R: a second secret ask on the same row ------------------------------------
row DIVE-3
need DIVE-3 --type=secret --ask="$ASK" --secret-key=X_API_KEY --connector=tools >/dev/null
pg=$(prev_gates DIVE-3)
out=$(need DIVE-3 --type=secret --ask="$ASK" --secret-key=X_API_SECRET --connector=tools); rc=$?
DETAIL="rc=$rc key=$(col DIVE-3 secret_key) out=$out"
check "R1 a second secret gate for another key is REFUSED (exit $E_CONFLICT), the first gate kept" \
  test "$rc" -eq "$E_CONFLICT" -a "$(col DIVE-3 secret_key)" == X_API_KEY -a "$(prev_gates DIVE-3)" == "$pg"
check "R2 ...and the refusal says what to do: one gate for all keys, or its own row" \
  bash -c '[[ "$1" == *"DIVE-3 already waits for X_API_KEY"* && "$1" == *"--secret-key=X_API_KEY,X_API_SECRET"* && "$1" == *"its own row"* ]]' _ "$out"
out=$(need DIVE-3 --type=secret --tier=2 --ask="$ASK again"); rc=$?
DETAIL="rc=$rc key=$(col DIVE-3 secret_key) out=$out"
check "R3 a re-file of the SAME key (the council's escalation: no key flags) is accepted" \
  test "$rc" -eq 0 -a "$(col DIVE-3 secret_key)" == X_API_KEY
out=$(need DIVE-3 --type=decision --ask="Post on X, or skip X this week?" --options="post on X|skip X" --recommend="post on X" --tier=1); rc=$?
DETAIL="rc=$rc out=$out"
check "R4 a non-secret gate replacing a secret one says the sent link no longer works" \
  bash -c '[[ "$1" == *"any link sent for it no longer works"* ]]' _ "$out"
out=$(need DIVE-3 --type=decision --ask="Post on X today, or tomorrow?" --options="today|tomorrow" --recommend="today" --tier=1); rc=$?
DETAIL="rc=$rc out=$out"
check "R5 any other replacement of a pending gate says the old one's buttons stop working" \
  bash -c '[[ "$1" == *"replaces its pending decision gate"* ]]' _ "$out"

# --- the page, as the box runs it ----------------------------------------------
MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKBIN/logger"; chmod +x "$MOCKBIN/logger"
REALBIN="$TMP/realbin"; mkdir -p "$REALBIN"; : > "$TMP/enforce"; cp "$MOCKBIN/logger" "$REALBIN/logger"
# The REAL `task answer`, root with no SUDO_UID in the page's unit cgroup and
# gate-proof enforcement on: only the redeemed link can be the evidence.
cat > "$REALBIN/5dive" <<EOF
#!/usr/bin/env bash
cd "$REPO"; for f in $LIBS; do source "src/\$f"; done
STATE_DIR="$STATE_DIR"; TASKS_DIR="$TASKS_DIR"; TASKS_DB="$TASKS_DB"; CONNECTORS_DIR="$CONNECTORS_DIR"
SECRET_DROP_DIR="$SECRET_DROP_DIR"; AUDIT_LOG="$TMP/audit.log"
TOOLS_ENV_FILE="$TOOLS_ENV_FILE"; TOOLS_WRITE_LOCK="$TOOLS_WRITE_LOCK"; SECRET_PROJECTS_DIR="$SECRET_PROJECTS_DIR"
[[ "\${1:-}" == agent ]] && { printf '%s\n' "\$*" >> "$TMP/agent-sends.log"; exit 0; }
export GATE_PROOF_ENFORCE="$TMP/enforce"; unset SUDO_UID
_gate_is_root() { return 0; }; _gate_caller_uid() { printf '0'; }
_gate_sudo_uid_nonagent() { return 0; }
_gate_caller_cgroup() { printf '%s' '/system.slice/5dive-secret-drop.service'; }
task_need_notify() { :; }; _task_send_owner() { :; }
_task_answer_ping_unit_ok() { return 1; }
cmd_send() { printf '%s\n' "\$*" >> "$TMP/sends.log"; }
_task_store_audit_log() { :; }
[[ "\${1:-}" == task ]] && shift
cmd_task "\$@"
EOF
chmod +x "$REALBIN/5dive"
WRAP="$TMP/5dive-bundle"
cat > "$WRAP" <<EOF
#!/usr/bin/env bash
cd "$REPO"
for f in $LIBS; do source "src/\$f"; done
STATE_DIR="$STATE_DIR"; TASKS_DIR="$TASKS_DIR"; TASKS_DB="$TASKS_DB"; CONNECTORS_DIR="$CONNECTORS_DIR"
SECRET_DROP_DIR="$SECRET_DROP_DIR"; SECRET_DROP_LOCK="$SECRET_DROP_LOCK"; SECRET_WRITE_LOCK="$SECRET_WRITE_LOCK"
TOOLS_ENV_FILE="$TOOLS_ENV_FILE"; TOOLS_WRITE_LOCK="$TOOLS_WRITE_LOCK"; SECRET_PROJECTS_DIR="$SECRET_PROJECTS_DIR"
PATH="$REALBIN:\$PATH"
require_root() { :; }; _seat_secret_eligible() { return 1; }; _gate_is_root() { return 0; }
five_self_bundle() { printf '%s' "$REALBIN/5dive"; }
shift
args=(); for a in "\$@"; do [[ "\$a" == --json ]] && JSON_MODE=1 || args+=("\$a"); done
cmd_secret "\${args[@]}"
EOF
chmod +x "$WRAP"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
_secret_drop_server_py > "$TMP/server.py"
python3 "$TMP/server.py" 127.0.0.1 "$PORT" "$WRAP" "$SECRET_DROP_DIR" 0 2> "$TMP/server.log" & SRV_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
B="http://127.0.0.1:$PORT"

# --- P: one link, one box per key, one save ------------------------------------
out=$(mint DIVE-1); tok=$(tok_of "$out")
DETAIL="out=$out store=$(ls "$SECRET_DROP_DIR" 2>/dev/null | wc -l)"
check "P1 ONE link for the four-part gate, bound to all four keys" \
  test -n "$tok" -a "$(ls "$SECRET_DROP_DIR" | wc -l)" -eq 1 -a "$(grep -c "^key=$X4\$" "$SECRET_DROP_DIR/$(hash_of "$tok")")" -eq 1
code=$(curl -s -o "$TMP/page.html" -w '%{http_code}' "$B/$tok")
boxes=$(grep -o '<textarea [^>]*name=k[0-9]' "$TMP/page.html" | wc -l)
DETAIL="code=$code boxes=$boxes"
check "P2 the page shows one labelled box per key (4), each named for its key" \
  bash -c '[[ "$1" == 200 && "$2" == 4 ]] && for k in X_API_KEY X_API_SECRET X_ACCESS_TOKEN X_ACCESS_TOKEN_SECRET; do grep -q "<label for=f-[0-9]>$k</label>" "$3" || exit 1; done' _ "$code" "$boxes" "$TMP/page.html"
code=$(curl -s -o "$TMP/bad.html" -w '%{http_code}' --data-urlencode "k0=ak-1" --data-urlencode "k1=has space" \
  --data-urlencode "k2=at-3" --data-urlencode "k3=ats-4" "$B/$tok")
DETAIL="code=$code tools=$(cat "$TOOLS_ENV_FILE" 2>/dev/null | grep -c X_) link=$(ls "$SECRET_DROP_DIR" | wc -l)"
check "P3 one bad box saves NOTHING (no key lands) and the link still works" \
  test "$code" == 400 -a "$(grep -c '^export X_' "$TOOLS_ENV_FILE" 2>/dev/null || echo 0)" == 0 -a "$(ls "$SECRET_DROP_DIR" | wc -l)" -eq 1 -a -z "$(col DIVE-1 need_answered_at)"
code=$(curl -s -o /dev/null -w '%{http_code}' --data-urlencode "k0=ak-1" --data-urlencode "k1=" \
  --data-urlencode "k2=at-3" --data-urlencode "k3=ats-4" "$B/$tok")
DETAIL="code=$code"
check "P4 an empty box is refused before the box is asked, link kept" test "$code" == 400 -a "$(ls "$SECRET_DROP_DIR" | wc -l)" -eq 1
code=$(curl -s -o "$TMP/ok.html" -w '%{http_code}' --data-urlencode "k0=ak-1" --data-urlencode "k1=aks-2" \
  --data-urlencode "k2=at-3" --data-urlencode "k3=ats-4" "$B/$tok")
DETAIL="code=$code at=$(col DIVE-1 need_answered_at) by=$(col DIVE-1 need_answered_by) tools=$(grep '^export X_' "$TOOLS_ENV_FILE" 2>/dev/null | cut -d= -f1 | tr '\n' ' ') page=$(sed 's/<[^>]*>/ /g' "$TMP/ok.html" | tr -s ' ' | tail -c 200)"
check "P5 ACCEPTANCE: one save lands all four in tools.sh and closes the gate (human:drop, enforce on)" \
  bash -c '[[ "$1" == 200 && -n "$2" && "$3" == human:drop ]] && grep -qxF "export X_API_KEY='"'"'ak-1'"'"'" "$4" && grep -qxF "export X_API_SECRET='"'"'aks-2'"'"'" "$4" && grep -qxF "export X_ACCESS_TOKEN='"'"'at-3'"'"'" "$4" && grep -qxF "export X_ACCESS_TOKEN_SECRET='"'"'ats-4'"'"'" "$4"' \
  _ "$code" "$(col DIVE-1 need_answered_at)" "$(col DIVE-1 need_answered_by)" "$TOOLS_ENV_FILE"
DETAIL="links=$(ls "$SECRET_DROP_DIR" | wc -l) page=$(grep -o 'Saved[^<]*' "$TMP/ok.html" | head -1)"
check "P6 ...the link is burned and the page never echoes a value" \
  bash -c '[[ "$(ls "$1" | wc -l)" == 0 ]] && ! grep -qE "ak-1|aks-2|at-3|ats-4" "$2"' _ "$SECRET_DROP_DIR" "$TMP/ok.html"

# --- S: a superseded link burns itself only -----------------------------------
row DIVE-4
need DIVE-4 --type=secret --ask="$ASK" --secret-key=X_API_KEY --connector=tools >/dev/null
o1=$(mint DIVE-4); t1=$(tok_of "$o1")
( cmd_task_need DIVE-4 --withdraw ) >/dev/null 2>&1
need DIVE-4 --type=secret --ask="$ASK" --secret-key=X_API_SECRET --connector=tools >/dev/null
o4=$(mint DIVE-4); t4=$(tok_of "$o4")
c1=$(curl -s -o /dev/null -w '%{http_code}' "$B/$t1")
c4=$(curl -s -o /dev/null -w '%{http_code}' "$B/$t4")
DETAIL="link1=$c1 link4=$c4 store=$(ls "$SECRET_DROP_DIR" | wc -l)"
check "S1 opening the superseded link says closed (410) and burns THAT link" \
  test "$c1" == 410 -a ! -f "$SECRET_DROP_DIR/$(hash_of "$t1")"
check "S2 ...and the live link for the gate that replaced it still opens (the link-4 death)" \
  test "$c4" == 200 -a -f "$SECRET_DROP_DIR/$(hash_of "$t4")"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- W: the terminal path the alert prints -------------------------------------
: > "$TOOLS_ENV_FILE"
out=$(printf 'w1\nw two\n' | ( _secret_write W_ONE_KEY,W_TWO_KEY --connector=tools ) 2>&1); rc=$?
DETAIL="rc=$rc out=$out"
check "W1 secret write A,B: a bad second value saves neither" \
  test "$rc" -ne 0 -a "$(grep -c '^export W_' "$TOOLS_ENV_FILE")" == 0
out=$(printf 'w1\r\nw2\n' | ( _secret_write W_ONE_KEY,W_TWO_KEY --connector=tools ) 2>&1); rc=$?
DETAIL="rc=$rc out=$out tools=$(cat "$TOOLS_ENV_FILE")"
check "W2 secret write A,B: one line per key on stdin lands both" \
  bash -c '[[ "$1" == 0 ]] && grep -qxF "export W_ONE_KEY='"'"'w1'"'"'" "$2" && grep -qxF "export W_TWO_KEY='"'"'w2'"'"'" "$2"' _ "$rc" "$TOOLS_ENV_FILE"
row DIVE-5
need DIVE-5 --type=secret --ask="$ASK" --secret-key="Y_ONE_KEY,Y_TWO_KEY" --connector=tools >/dev/null
g=$(_secret_open_gate_for Y_TWO_KEY tools); n=$(_secret_open_gate_for Y_TWO tools)
DETAIL="by-key=$g by-prefix=$n"
check "W3 the self-host match finds a several-key gate by one of its keys, never by a prefix" \
  test "$g" == DIVE-5 -a -z "$n"

printf '\nsecret multi-key gate unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
