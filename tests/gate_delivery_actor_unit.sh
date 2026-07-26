#!/usr/bin/env bash
# DIVE-2073 isolated unit harness — a gate-delivery row NAMES WHO DELIVERED IT.
#
# WHY THIS EXISTS. This row, verbatim from the fleet audit log on 2026-07-26:
#   {"user":"unknown","cmd":"gate delivery","result":"ok",
#    "args":["tasks=DIVE-2050","chat=1234567890","message_id=691",
#            "detail=confirmed Bot API send"]}
# asserts a confirmed send while naming nobody. DIVE-1968's whole thesis is that
# a gate is not delivered until a row PROVES it was; "something sent it" is not
# that proof. On the ordinary path the gap is cosmetic. On the PRIVILEGED paths
# it is load-bearing, because the only question those paths exist to answer is
# "did the escalation reach a human through a DIFFERENT channel than the
# filer's" — and that cannot be answered by a row that will not say which
# channel.
#
# Two distinct defects sat behind that one row, and both are pinned here:
#
#   1. `unknown` MEANT TWO THINGS. audit_log fell back to it for BOTH "this
#      process genuinely has no invoking user" and "actor resolution failed".
#      Measured: every unknown-actor gate-delivery row on this box lands at
#      :NN:02 on a five-minute boundary — i.e. the root heartbeat re-nag, which
#      has neither SUDO_USER nor USER. That is an identity BY DESIGN, and it
#      must not share a value with a resolution failure. Same absent-vs-forbidden
#      conflation as DIVE-1927's paired probe and DIVE-1989's dropped rows.
#
#   2. THE ROW NEVER NAMED THE CHANNEL. Each bot holds its own conversation with
#      the same human, so message ids live in per-bot id spaces: the 2026-07-26
#      rows sit at 26235-26309 while message_id 691 sits in another space
#      entirely. Which bot carried a send was simply not recorded anywhere, so
#      DIVE-1927's residual 2 (a human tap arriving through the MANAGER's bot
#      rather than the filer's) could not be discharged from the evidence base
#      even though it had probably already happened.
#
# What is pinned:
#   1. no invoking user + root  => user=root      (identity by design)
#   2. no invoking user, non-root => user=unknown (a genuine resolution failure)
#   3. SUDO_USER / FIVEDIVE_AUDIT_USER still win, unchanged
#   4. _task_agent_channel publishes TASK_CH_AGENT on success — on the by-NAME
#      path too, which is the one every privileged send uses
#   5. ...and CLEARS it on failure, so an error row can never borrow a stale
#      owner from an earlier send in the same process
#   6. the delivery row carries via=<agent> and path=<rail> on all three rails:
#      file-time, renag, privileged-resend
# Run: bash tests/gate_delivery_actor_unit.sh   (no root, no network)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-actor-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_push.sh cmd_agent_pairing.sh cmd_task.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e                       # AFTER sourcing: header.sh turns `set -e` back on.
tasks_db_init

PASS=0; FAIL=0
ok_t()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

# ---- 1. the actor fallback stops conflating two answers ----------------------
# audit_log writes into an isolated log; AUDIT_LOG's parent must exist or it
# returns early (the DIVE-1268 guard).
AUDIT_LOG="$TMP/audit/agent-audit.log"; mkdir -p "$TMP/audit"
# Keep the append inside the harness: _emit_audit_line falls back to `sudo 5dive
# _audit_append` when it cannot write, which would leave the row in the REAL
# fleet log. We can write our own file, so the direct branch is taken; stub the
# fallback anyway so a harness bug can never leak a fixture row into production.
_audit_note_drop() { :; }

# The root branch cannot be reached by assigning $EUID (it is readonly), hence
# the _audit_is_root seam — stubbing it is the ONLY way this case is testable.
# Each case runs in a SUBSHELL with the three actor sources unset, so the
# harness's own environment cannot mask a regression.
run_case() { # <expect> <label> <setup-fn>
  local expect="$1" label="$2" setup="$3"
  : >"$AUDIT_LOG"
  (
    unset USER SUDO_USER FIVEDIVE_AUDIT_USER
    "$setup"
    audit_log "gate delivery" "ok" 0 -- "tasks=DIVE-0000"
  )
  local got; got=$(jq -r '.user' <"$AUDIT_LOG" 2>/dev/null | tail -1)
  [[ "$got" == "$expect" ]] && ok_t "$label" || bad_t "$label" "user='$got' expected '$expect'"
}

as_root()     { _audit_is_root() { return 0; }; }
as_non_root() { _audit_is_root() { return 1; }; }
as_sudo()     { _audit_is_root() { return 0; }; SUDO_USER=agent-marketing; }
as_override() { _audit_is_root() { return 0; }; FIVEDIVE_AUDIT_USER=agent-olivia; }

run_case root    "root with no invoking user records user=root (identity by design)" as_root
run_case unknown "non-root with no resolvable user still records unknown (a real failure)" as_non_root
run_case agent-marketing "SUDO_USER still wins over the root fallback" as_sudo
run_case agent-olivia    "FIVEDIVE_AUDIT_USER still wins over everything" as_override

# ---- 2. the channel resolver publishes WHOSE channel it resolved -------------
# _tg_access_state_dir hardcodes /home/<user>/..., so point it at the fixture.
CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"
_tg_access_state_dir() { printf '%s/%s-%s' "$TMP/channels" "$1" "$2"; }
mk_channel() { # <agent>
  printf 'TELEGRAM_BOT_TOKEN=tok-%s\n' "$1" >"$CONNECTORS_DIR/telegram-$1.env"
  mkdir -p "$TMP/channels/agent-$1-claude"
  printf '%s\n' '{"allowFrom":["1234567890"]}' >"$TMP/channels/agent-$1-claude/access.json"
}
mk_channel olivia

TASK_CH_AGENT=""
if _task_agent_channel olivia && [[ "$TASK_CH_AGENT" == "olivia" ]]; then
  ok_t "_task_agent_channel names the resolved owner (the by-NAME privileged path)"
else
  bad_t "_task_agent_channel names the resolved owner" "TASK_CH_AGENT='$TASK_CH_AGENT'"
fi

# A failed resolve must CLEAR it. Otherwise the next delivery row inherits the
# previous send's owner and quietly attributes a message to the wrong bot —
# strictly worse than the `unknown` this ticket is removing.
_task_agent_channel nosuchagent
if [[ -z "$TASK_CH_AGENT" ]]; then
  ok_t "a failed resolve CLEARS the owner instead of leaving a stale one"
else
  bad_t "failed resolve clears the owner" "TASK_CH_AGENT='$TASK_CH_AGENT' survived a miss"
fi

# ---- 3. the delivery row carries via= and path= on every rail ----------------
# Capture the audit args rather than the file: this asserts what the ROW says.
AUDIT_CALLS="$TMP/audit-calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
# On the prod store the row is written; the fence (DIVE-1968/2010) is asserted by
# its own suite, so force the allow here rather than re-testing it.
_task_human_send_allowed() { return 0; }
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"

row_says() { # <label> <needle...>
  local label="$1"; shift
  local last; last=$(tail -1 "$AUDIT_CALLS")
  local n missing=""
  for n in "$@"; do [[ "$last" == *"$n"* ]] || missing+="$n "; done
  [[ -z "$missing" ]] && ok_t "$label" || bad_t "$label" "missing: $missing | row: $last"
}

_task_agent_channel olivia          # resolves TASK_CH_AGENT=olivia
TASK_GATE_ESCALATING="" TASK_GATE_RENAG=""
_task_gate_delivery_log ok DIVE-2050 1234567890 691 "confirmed Bot API send"
row_says "file-time delivery names the channel owner and its rail" "via=olivia" "path=file-time"

TASK_GATE_RENAG=1
_task_gate_delivery_log ok DIVE-2050 1234567890 692 "confirmed Bot API send"
row_says "the root re-nag is distinguishable from a file-time send" "via=olivia" "path=renag"
TASK_GATE_RENAG=""

TASK_GATE_ESCALATING=1
_task_gate_delivery_log ok DIVE-2050 1234567890 693 "confirmed Bot API send"
row_says "the PRIVILEGED RE-SEND says so on the row itself" "via=olivia" "path=privileged-resend"
TASK_GATE_ESCALATING=""

# The no-channel error rows are the ones that must not borrow an owner: this is
# the shape that produced 194 rows of "no paired channel for filer X".
_task_agent_channel nosuchagent
_task_gate_delivery_log error DIVE-2050 "" "" "no paired channel for filer dev3 or anyone above it"
row_says "an unresolved send records via=none, never a stale owner" "via=none" "path=file-time"

# The human-readable notify log must carry the same two facts — it is the file
# people actually grep, and a fact that lives in only one of the two records is
# a fact the next investigation will miss.
if grep -q 'via=olivia path=renag' "$FIVEDIVE_GATE_NOTIFY_LOG" 2>/dev/null; then
  ok_t "the notify log carries via= and path= too, not just the audit row"
else
  bad_t "notify log carries via/path" "$(tail -2 "$FIVEDIVE_GATE_NOTIFY_LOG" 2>/dev/null)"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
