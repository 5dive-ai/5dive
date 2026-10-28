#!/usr/bin/env bash
# DIVE-7102 — a secret gate on a self-hosted box points the owner at a page they
# can open. On 2026-10-27 a self-hosted lead filed `task need --type=secret` and
# told the owner to paste the token "into the secret request on your dashboard";
# a self-hosted owner has no dashboard and no Tasks tab, so the token went into
# plain chat. Graded:
#   L1-L4  on a box linked to 5dive.app chat, the gate's result line and JSON
#          carry https://my.5dive.ai/tg/secret?key=<KEY>&agent=<filer>, first in
#          the line; an unlinked box prints no such link;
#   W1-W4  the box reporter's `secret write <KEY> --connector=<c>` (value on stdin,
#          no --task) closes the ONE open gate asking for that key, so its agent
#          hears; two such gates, or an unlinked box, are left alone.
#   W5-W13 DIVE-7186: the REAL `task answer`, enforcement on — the reporter's
#          own unit closes it as a human answer and wakes the filer; an agent's
#          unit, a sudo caller, a value not yet on the box, an unlinked box do not.
# Isolation: src/ libs, throwaway STATE_DIR; the live tasks.db is never touched.
# Run: bash tests/selfhost_secret_link_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/selfhost-secret-link.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_secret.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"
SECRET_WRITE_LOCK="$TMP/secret-write.lock"
export FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }
# The filer is the lead, an agent on this box.
# (each gate is filed --from=olivia)
registry_read() { printf '%s\n' '{"agents":{"olivia":{"type":"claude"}}}'; }
seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','olivia');"; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }
URL='https://my.5dive.ai/tg/secret?key=THEO_BOT_TOKEN&agent=olivia'

echo '== the gate names the self-host page =='
: > "$FIVEDIVE_CHAT_ONLY_MARK"
seed_task DIVE-1
out=$(cmd_task_need DIVE-1 --from=olivia --type=secret --ask="Theo needs his bot token" --secret-key=THEO_BOT_TOKEN --connector=tools 2>"$TMP/err"); rc=$?
okline=$(grep -m1 '^OK — ' <<<"$out")
[[ $rc -eq 0 && "$okline" == *"$URL"* ]] \
  && ok_t "L1 the result line carries the self-host link" || bad_t "L1 no self-host link" "rc=$rc out=$out err=$(cat "$TMP/err")"
[[ "$okline" == "OK — DIVE-1 needs a human (secret, tier "[0-9]") [self-hosted box: send the owner this link"* ]] \
  && ok_t "L2 it is the first note, so it is what the lead relays" || bad_t "L2 not first" "$okline"
grep -qF "dashboard" <<<"$okline" \
  && bad_t "L3 a self-hosted result line must not send the owner to a dashboard" "$okline" \
  || ok_t "L3 no dashboard in the line"
grep -qF "$URL" "$TMP/err" && ok_t "L3b and a separate step line says it" || bad_t "L3b no step line" "$(cat "$TMP/err")"
seed_task DIVE-2
js=$(JSON_MODE=1 cmd_task_need DIVE-2 --from=olivia --type=secret --ask="a key for the CRM" --secret-key=CRM_API_KEY --connector=tools 2>/dev/null)
[[ "$(jq -r '.data.selfhost_secret_url' <<<"$js" 2>/dev/null)" == 'https://my.5dive.ai/tg/secret?key=CRM_API_KEY&agent=olivia' ]] \
  && ok_t "L4 JSON carries selfhost_secret_url" || bad_t "L4 JSON" "$js"
rm -f "$FIVEDIVE_CHAT_ONLY_MARK"
seed_task DIVE-3
out=$(cmd_task_need DIVE-3 --from=olivia --type=secret --ask="a key for the CRM" --secret-key=CRM2_API_KEY --connector=tools 2>&1)
grep -qF 'my.5dive.ai/tg/secret' <<<"$out" \
  && bad_t "L5 a box not linked to 5dive.app chat prints no self-host link" "$out" \
  || ok_t "L5 a box not linked to 5dive.app chat prints no self-host link"

echo '== the reporter'"'"'s write closes the gate =='
require_root() { :; }
MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
printf '#!/usr/bin/env bash\necho "$*" >> "$MOCK5DIVE_LOG"\n' > "$MOCKBIN/5dive"; chmod +x "$MOCKBIN/5dive"
export MOCK5DIVE_LOG="$TMP/5dive-calls.log"; : > "$MOCK5DIVE_LOG"
PATH="$MOCKBIN:$PATH"
: > "$FIVEDIVE_CHAT_ONLY_MARK"
seed_task DIVE-4
cmd_task_need DIVE-4 --from=olivia --type=secret --ask="the Notion key" --secret-key=NOTION_KEY --connector=notion >/dev/null 2>&1
printf 'secret-notion-value' | _secret_write NOTION_KEY --connector=notion >/dev/null 2>&1
grep -qx 'NOTION_KEY=secret-notion-value' "$CONNECTORS_DIR/notion.env" 2>/dev/null \
  && ok_t "W1 the value is written from stdin" || bad_t "W1 value not written" "$(cat "$CONNECTORS_DIR/notion.env" 2>/dev/null)"
grep -qF 'task answer DIVE-4 --human --from=drop' "$MOCK5DIVE_LOG" \
  && ok_t "W2 the one open gate asking for that key is closed" || bad_t "W2 gate not closed" "$(cat "$MOCK5DIVE_LOG")"
: > "$MOCK5DIVE_LOG"
seed_task DIVE-5; seed_task DIVE-6
cmd_task_need DIVE-5 --from=olivia --type=secret --ask="key A" --secret-key=TWICE_KEY --connector=notion >/dev/null 2>&1
cmd_task_need DIVE-6 --from=olivia --type=secret --ask="key B" --secret-key=TWICE_KEY --connector=notion >/dev/null 2>&1
printf 'v' | _secret_write TWICE_KEY --connector=notion >/dev/null 2>&1
grep -q 'task answer' "$MOCK5DIVE_LOG" \
  && bad_t "W3 two gates for one key: neither may be guessed" "$(cat "$MOCK5DIVE_LOG")" \
  || ok_t "W3 two gates for one key: neither is guessed"
rm -f "$FIVEDIVE_CHAT_ONLY_MARK"; : > "$MOCK5DIVE_LOG"
seed_task DIVE-7
cmd_task_need DIVE-7 --from=olivia --type=secret --ask="key C" --secret-key=ONPREM_KEY --connector=notion >/dev/null 2>&1
printf 'v' | _secret_write ONPREM_KEY --connector=notion >/dev/null 2>&1
grep -q 'task answer' "$MOCK5DIVE_LOG" \
  && bad_t "W4 an unlinked box keeps today's rule (only --task closes a gate)" "$(cat "$MOCK5DIVE_LOG")" \
  || ok_t "W4 an unlinked box keeps today's rule (only --task closes a gate)"

echo '== DIVE-7186: the REAL answer, under enforcement, from the reporter'"'"'s unit =='
# W2 above reads a mock. On DIVE-7185's box the real `task answer --human
# --from=drop` was refused (evidence=none, enforce=on): the reporter runs as root
# in its own system unit, with no SUDO_UID. Here the real verb runs as a separate
# process, enforcement on, in the cgroup each arm names.
LIBS="header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_tool.sh cmd_secret.sh"
REALBIN="$TMP/realbin"; mkdir -p "$REALBIN"; : > "$TMP/enforce"
export AUDIT_LOG_T="$TMP/audit.log" SENDS="$TMP/sends.log"; : > "$AUDIT_LOG_T"; : > "$SENDS"
cat > "$REALBIN/5dive" <<EOF2
#!/usr/bin/env bash
cd "$PWD"; for f in $LIBS; do source "src/\$f"; done
STATE_DIR="$STATE_DIR"; TASKS_DIR="$TASKS_DIR"; TASKS_DB="$TASKS_DB"; CONNECTORS_DIR="$CONNECTORS_DIR"; AUDIT_LOG="$AUDIT_LOG_T"; TOOLS_ENV_FILE="$CONNECTORS_DIR/tools.sh"; TOOLS_WRITE_LOCK="$TMP/tools.lock"
export GATE_PROOF_ENFORCE="$TMP/enforce"
_gate_is_root() { return 0; }; _gate_caller_uid() { printf '0'; }
_gate_caller_cgroup() { printf '%s' "\$CG"; }
registry_read() { printf '%s\n' '{"agents":{"olivia":{"type":"claude"}}}'; }
task_need_notify() { :; }; _task_send_owner() { :; }
_task_answer_ping_unit_ok() { return 1; }
cmd_send() { printf '%s\n' "\$*" >> "$SENDS"; }
_task_store_audit_log() { audit_log "\$@"; }
[[ "\${1:-}" == task ]] && shift
cmd_task "\$@"
EOF2
chmod +x "$REALBIN/5dive"
REPORTER=/system.slice/5dive-chat-report.service
ans_at() { db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident='$1';"; }
owed() { # <ident> <KEY> <cgroup> [SUDO_UID] — the reporter's owed pull: secret write, no --task
  seed_task "$1"
  cmd_task_need "$1" --from=olivia --type=secret --ask="Theo's key" --secret-key="$2" --connector=tools >/dev/null 2>&1
  printf 'sk-ant-api03-owed-0123456789' | PATH="$REALBIN:$PATH" CG="$3" SUDO_UID="${4:-}" _secret_write "$2" --connector=tools 2>&1
}
wait_sends() { local i; for i in $(seq 1 50); do grep -qF -- "$1" "$SENDS" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
: > "$FIVEDIVE_CHAT_ONLY_MARK"
source src/cmd_tool.sh; TOOLS_ENV_FILE="$CONNECTORS_DIR/tools.sh"; TOOLS_WRITE_LOCK="$TMP/tools.lock"

out=$(owed DIVE-10 THEO_ANTHROPIC_KEY "$REPORTER")
ev=$(db "SELECT COALESCE(human_evidence,'') FROM tasks WHERE ident='DIVE-10';")
by=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='DIVE-10';")
[[ -n "$(ans_at DIVE-10)" && "$ev" == owner-pull && "$by" == human:* ]] \
  && ok_t "W5 the reporter's write closes the gate as a human answer (evidence=owner-pull)" \
  || bad_t "W5 gate not closed by the owner pull" "at=$(ans_at DIVE-10) ev=$ev by=$by out=$out audit=$(grep DIVE-10 "$AUDIT_LOG_T" | tail -2)"
grep -q 'task=DIVE-10.*owner_pull=1.*evidence=owner-pull' "$AUDIT_LOG_T" && grep -q 'task=DIVE-10.*enforce=on' "$AUDIT_LOG_T" \
  && ok_t "W6 the audit names evidence=owner-pull, under enforce=on" || bad_t "W6 audit" "$(grep DIVE-10 "$AUDIT_LOG_T" | tail -2)"
wait_sends "DIVE-10 secret gate provided" \
  && grep -qF -- "olivia --wake" "$SENDS" \
  && ok_t "W7 the filer is woken" || bad_t "W7 filer not woken" "$(cat "$SENDS")"
grep -qF 'sk-ant-api03-owed' "$AUDIT_LOG_T" "$SENDS" && bad_t "W8 the value leaked into the audit or the ping" "" || ok_t "W8 the value is in neither the audit nor the ping"

out=$(owed DIVE-11 CRM_ONE_KEY /system.slice/5dive-agent@olivia.service)
[[ -z "$(ans_at DIVE-11)" && "$out" == *"was not marked provided"* ]] \
  && ok_t "W9 control: the same write from an agent's unit leaves the gate open and says so" \
  || bad_t "W9 an agent's unit closed the gate" "at=$(ans_at DIVE-11) out=$out"
out=$(owed DIVE-12 CRM_TWO_KEY "$REPORTER" 1001)
[[ -z "$(ans_at DIVE-12)" ]] && ok_t "W10 ...and from sudo (a SUDO_UID), even in the reporter's unit" || bad_t "W10 a sudo caller closed the gate" "out=$out"

seed_task DIVE-13
cmd_task_need DIVE-13 --from=olivia --type=secret --ask="not yet sent" --secret-key=NOT_SENT_KEY --connector=tools >/dev/null 2>&1
out=$(PATH="$REALBIN:$PATH" CG="$REPORTER" 5dive task answer DIVE-13 --human --from=drop 2>&1)
[[ -z "$(ans_at DIVE-13)" ]] && ok_t "W11 the reporter's unit with no value on the box cannot close a gate" || bad_t "W11 closed with no value" "$out"
_tool_put_var NOT_SENT_KEY v; rm -f "$FIVEDIVE_CHAT_ONLY_MARK"
out=$(PATH="$REALBIN:$PATH" CG="$REPORTER" 5dive task answer DIVE-13 --human --from=drop 2>&1)
[[ -z "$(ans_at DIVE-13)" ]] && ok_t "W12 nor on a box not linked to 5dive.app chat" || bad_t "W12 closed on an unlinked box" "$out"
: > "$FIVEDIVE_CHAT_ONLY_MARK"
out=$(PATH="$REALBIN:$PATH" CG="$REPORTER" 5dive task answer DIVE-13 --human --from=drop 2>&1)
[[ -n "$(ans_at DIVE-13)" ]] && ok_t "W13 linked, value on the box: it closes (the arms above differ by one fact each)" || bad_t "W13 positive control" "$out"

echo
printf 'DIVE-7102 self-host secret link: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
