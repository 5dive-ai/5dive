#!/usr/bin/env bash
# DIVE-7077 — on a box with no Telegram and no app link, a gate that needs the
# owner reaches them in the box's shell, and the tier-2 floor does not move.
#
# THE GAP (Dropshipping trial, DIVE-6902, OSS CLI 0.102.0, no channel, unlinked):
# a tier-2 manual gate sat 4 hours and nothing told anyone, and when the owner ran
# `task answer` from the box the refusal said "tap the button in Telegram".
#
# Arms:
#   L1-L3  `task inbox --login` (what /etc/profile.d/5dive-asks.sh runs) prints the
#          waiting ask and the command that answers it; silent with a channel or
#          an app link, or with nothing waiting.
#   R1-R5  refusals on a channel-less box name that command and never "Telegram";
#          with a channel they keep the Telegram wording.
#   C1-C3  that command, from root's login shell (logind session scope), clears
#          the gate, the row goes back to the filer and the filer is pinged.
#   N1-N2  the SAME command from an agent seat, and from root in a non-login
#          service context, is refused and the gate stays open (the floor holds).
#   S1     a secret gate's hint is the hidden-prompt `secret write --task=` path.
#   Q1-Q2  agent-written text cannot run as root or reach the owner's terminal raw:
#          an option with $(...), backticks and both quotes prints as one quoted
#          word that a real shell hands to 5dive literally, running nothing; an
#          ask carrying ESC/BEL comes out of --login with no control bytes.
# L1 and R1 are red on the pre-fix tree (no --login; "tap the button in Telegram").
#
# Seams only what cannot be reassigned in-process, as the sibling gate harnesses
# do: EUID (`_gate_is_root`), the caller's cgroup reader, the caller uid, and the
# outbound ping. The accept/deny logic is the shipped bytes.
# Run: bash tests/gate_shell_owner_reach_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
exec 8>&2
SUMMARY_PRINTED=0
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "${SUMMARY_PRINTED:-0}" == 1 ]] || printf "ABORTED - gate_shell_owner_reach_unit exited early (rc=%s) before its summary\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-shell-owner.XXXXXX)"

STATE_DIR="$TMP"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh constitution_kernel.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable)\n' >&2
TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"
export FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env"   # absent = not linked to the app
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"; touch "$GATE_PROOF_ENFORCE"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
audit_log() { :; }
task_need_notify() { return 0; }
_task_human_send_allowed() { return 0; }
PING_FILE="$TMP/pings"; : > "$PING_FILE"
_task_answer_ping_detached() { printf '%s\n' "$1" >> "$PING_FILE"; return 0; }
cmd_send() { printf '%s\n' "$1" >> "$PING_FILE"; return 0; }

# The caller: an agent seat by default (uid pinned to a fixture agent-* name).
AGENT_UID=987654
AGENT_CG='/system.slice/system-5dive.slice/agent-fixture.service'
_gate_passwd_stream() {
  printf 'agent-fixture:x:%s:%s::/nonexistent:/bin/false\n' "$AGENT_UID" "$AGENT_UID"
  printf '%s\n' "$(</etc/passwd)"
}
getent() {
  if [[ "${1:-}" == passwd && "${2:-}" == "$AGENT_UID" ]]; then
    printf 'agent-fixture:x:%s:%s::/home/agent-fixture:/bin/bash\n' "$AGENT_UID" "$AGENT_UID"; return 0
  fi
  command getent "$@"
}
_gate_is_root() { return 0; }
as_agent() {
  export SUDO_UID="$AGENT_UID"; _gate_caller_uid() { printf '%s' "$AGENT_UID"; }
  _gate_caller_cgroup() { printf '%s' "$AGENT_CG"; }
}
as_root_login() {
  export SUDO_UID=0; _gate_caller_uid() { printf '0'; }
  _gate_caller_cgroup() { printf '%s' '/user.slice/user-0.slice/session-3.scope'; }
}
as_root_service() {
  export SUDO_UID=0; _gate_caller_uid() { printf '0'; }
  _gate_caller_cgroup() { printf '%s' '/system.slice/cron.service'; }
}

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by, assignee) VALUES ('$1','t','in_progress','fixture','fixture');"; }
answered()  { db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }
statusof()  { db "SELECT status FROM tasks WHERE ident='$1';"; }

as_agent
seed_task DIVE-1
cmd_task_need DIVE-1 --type=manual --ask="Solve the Shopify robot check in the box browser" --from=fixture >/dev/null 2>&1
[[ "$(db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='DIVE-1';")" == "2" && "$(answered DIVE-1)" == "open" ]] \
  && ok_t "precond: an agent filed a tier-2 manual gate" \
  || bad_t "precond: tier-2 manual gate" "tier=$(db "SELECT tier FROM tasks WHERE ident='DIVE-1';") state=$(answered DIVE-1)"
CMD='sudo 5dive task answer DIVE-1 --value=handled --human'

# ── L: the login notice ─────────────────────────────────────────────────────
out=$(cmd_task_inbox --login 2>&1)
[[ "$out" == *"1 ask is waiting for you"* && "$out" == *"DIVE-1"* && "$out" == *"Shopify robot check"* && "$out" == *"answer: $CMD"* ]] \
  && ok_t "L1 no channel, no app link: the login notice shows the ask and the command that answers it" \
  || bad_t "L1 login notice" "out=$out"

touch "$CONNECTORS_DIR/telegram-main.env"
out=$(cmd_task_inbox --login 2>&1)
[[ -z "$out" ]] && ok_t "L2 a box with Telegram prints nothing at login" || bad_t "L2 telegram box" "out=$out"
rm -f "$CONNECTORS_DIR/telegram-main.env"
touch "$FIVEDIVE_CONNECTORD_ENV"
out=$(cmd_task_inbox --login 2>&1)
[[ -z "$out" ]] && ok_t "L2b a box linked to the app prints nothing at login" || bad_t "L2b linked box" "out=$out"
rm -f "$FIVEDIVE_CONNECTORD_ENV"

# ── R: refusals on a channel-less box ───────────────────────────────────────
out=$( (cmd_task_answer DIVE-1 --value=handled --from=fixture) 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"login shell on this box: $CMD"* ]] \
  && ok_t "R1 the tier-2 refusal names the command that works on this box" \
  || bad_t "R1 refusal names the shell command" "rc=$rc out=$out"
[[ "$out" != *Telegram* ]] && ok_t "R2 no refusal text says Telegram on a box without it" || bad_t "R2 Telegram in refusal" "out=$out"

touch "$FIVEDIVE_CONNECTORD_ENV"
out=$( (cmd_task_answer DIVE-1 --value=handled --from=fixture) 2>&1)
[[ "$out" == *"dashboard"* && "$out" == *"$CMD"* && "$out" != *Telegram* ]] \
  && ok_t "R3 a linked box without Telegram names the dashboard and the command" \
  || bad_t "R3 linked refusal" "out=$out"
rm -f "$FIVEDIVE_CONNECTORD_ENV"

touch "$CONNECTORS_DIR/telegram-main.env"
out=$( (cmd_task_answer DIVE-1 --value=handled --from=fixture) 2>&1)
[[ "$out" == *Telegram* && "$out" != *"login shell"* ]] \
  && ok_t "R4 a box with Telegram keeps the Telegram wording" || bad_t "R4 telegram wording" "out=$out"
rm -f "$CONNECTORS_DIR/telegram-main.env"

# The trial's own case: the owner, in root's login shell, answers without --human.
# That is the tier-2 floor refusal itself, and it must hand them the working form.
as_root_login
out=$( (cmd_task_answer DIVE-1 --value=handled) 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-1)" == "open" && "$out" == *"tier-2 human gate"* && "$out" == *"$CMD"* && "$out" != *Telegram* ]] \
  && ok_t "R5 the owner without --human is told the exact command, not Telegram" \
  || bad_t "R5 owner without --human" "rc=$rc state=$(answered DIVE-1) out=$out"
as_agent

# ── N: the floor holds for the same command ─────────────────────────────────
out=$( (cmd_task_answer DIVE-1 --value=handled --human --from=fixture) 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-1)" == "open" ]] \
  && ok_t "N1 the same command from an agent seat is refused; the gate stays open" \
  || bad_t "N1 agent seat floor" "rc=$rc state=$(answered DIVE-1) out=$out"
[[ "$out" != *Telegram* ]] && ok_t "N1b that refusal does not say Telegram either" || bad_t "N1b Telegram" "out=$out"

as_root_service
out=$( (cmd_task_answer DIVE-1 --value=handled --human --from=fixture) 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-1)" == "open" ]] \
  && ok_t "N2 root in a non-login service context is refused; the gate stays open" \
  || bad_t "N2 service context floor" "rc=$rc state=$(answered DIVE-1) out=$out"

# ── C: the owner's login shell clears it and the filer resumes ──────────────
as_root_login
: > "$PING_FILE"
out=$( (cmd_task_answer DIVE-1 --value=handled --human) 2>&1); rc=$?
[[ $rc -eq 0 && "$(answered DIVE-1)" == "closed" ]] \
  && ok_t "C1 the command from root's login shell clears the gate" \
  || bad_t "C1 owner clears" "rc=$rc state=$(answered DIVE-1) out=$out"
[[ "$(statusof DIVE-1)" == "in_progress" ]] \
  && ok_t "C2 the row goes back to its maker (in_progress), not closed" \
  || bad_t "C2 row status" "status=$(statusof DIVE-1)"
grep -qx fixture "$PING_FILE" \
  && ok_t "C3 the filer is pinged to pick the row back up" || bad_t "C3 filer ping" "pings=$(cat "$PING_FILE")"
as_agent
out=$(cmd_task_inbox --login 2>&1)
[[ -z "$out" ]] && ok_t "L3 nothing waiting: the login notice is silent" || bad_t "L3 empty" "out=$out"

# ── S: a secret gate's command ──────────────────────────────────────────────
seed_task DIVE-2
cmd_task_need DIVE-2 --type=secret --secret-key=SHOPIFY_TOKEN --connector=tools --ask="Shopify admin token" --from=fixture >/dev/null 2>&1
out=$(cmd_task_inbox --login 2>&1)
[[ "$out" == *"answer: sudo 5dive secret write SHOPIFY_TOKEN --connector=tools --task=DIVE-2"* ]] \
  && ok_t "S1 a secret gate's login line is the hidden-prompt secret write" \
  || bad_t "S1 secret hint" "out=$out"

# ── Q: agent-written text stays text ────────────────────────────────────────
# A real shell runs the printed command with sudo and 5dive stubbed on PATH:
# 5dive writes each argument it got, one per NUL, so the check is byte-exact.
STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$STUB/sudo"
printf '#!/usr/bin/env bash\nprintf "%%s\\0" "$@" > "%s/args"\n' "$TMP" > "$STUB/5dive"
chmod +x "$STUB/sudo" "$STUB/5dive"
# Bare file names (the ask lint refuses a path in --options); the command runs in RUN.
RUN="$TMP/run"; mkdir -p "$RUN"
HOSTILE="go \$(touch q-sub) \`touch q-tick\` \"dq\" 'sq'"
seed_task DIVE-3
cmd_task_need DIVE-3 --type=decision --tier=2 --needs=human_tap --ask="Pick one" \
  --options="$HOSTILE|stop" --from=fixture >"$TMP/need3" 2>&1
out=$(cmd_task_inbox --login 2>&1)
line=$(printf '%s\n' "$out" | grep -A1 '  DIVE-3  ' | sed -n 's/^  answer: //p')
rm -f "$TMP/args"
if [[ -n "$line" ]] && bash -n <<<"$line" 2>/dev/null; then
  (cd "$RUN" && PATH="$STUB:$PATH" bash -c "$line") >/dev/null 2>&1
  got=(); mapfile -d '' got < "$TMP/args" 2>/dev/null
  exact=0; for a in "${got[@]}"; do [[ "$a" == "--value=$HOSTILE" ]] && exact=1; done
  [[ $exact == 1 && ! -e "$RUN/q-sub" && ! -e "$RUN/q-tick" ]] \
    && ok_t "Q1 a hostile option prints as one quoted word: 5dive gets it literally, nothing runs" \
    || bad_t "Q1 hostile option" "line=$line got=${got[*]-} sub=$([[ -e $RUN/q-sub ]] && echo RAN) tick=$([[ -e $RUN/q-tick ]] && echo RAN)"
else
  bad_t "Q1 hostile option" "no parseable answer line for DIVE-3: out=$out need=$(cat "$TMP/need3")"
fi

seed_task DIVE-4
cmd_task_need DIVE-4 --type=manual --ask=$'Robot check \e]0;owned\a\e[2J done' --from=fixture >/dev/null 2>&1
out=$(cmd_task_inbox --login 2>&1)
[[ "$out" == *"DIVE-4"* && "$out" == *"Robot check"* ]] \
  && ! LC_ALL=C grep -q $'[\x01-\x08\x0b-\x1f\x7f]' <<<"$out" \
  && ok_t "Q2 an ask carrying ESC/BEL reaches the login notice with no control bytes" \
  || bad_t "Q2 control bytes" "out=$(printf '%s' "$out" | cat -v)"

SUMMARY_PRINTED=1
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
