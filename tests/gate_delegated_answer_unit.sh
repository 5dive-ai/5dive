#!/usr/bin/env bash
# DIVE-3160 unit harness: the delegated SIGNED gate clear (`5dive _task_answer`).
#
# The defect it pins: a cli-scoped lead can CLEAR a gate it cannot SIGN, so its
# closure stores unsigned and a delegated push is refused later, on the maker's
# round-trip, as tampering. The repair is a root executor that signs at ANSWER
# time from facts it establishes itself — and the reason it may not instead SEAL A
# STORED ROW is that tasks.db is group-claude writable, i.e. the payload would be
# caller-authored. That last fact is what makes the guards below load-bearing
# rather than decorative: every one of them is the difference between "act as me,
# signed" and "sign whatever I wrote".
#
# WHAT THIS HARNESS CAN AND CANNOT REACH, said plainly. `$EUID` is a bash builtin
# and cannot be assigned, so an unprivileged harness CANNOT enter
# cmd_task_answer_delegated past its root guard. It therefore grades:
#   1. the root guard itself (the arm an unprivileged caller does reach);
#   2. `_task_answer_forbidden_flag`, the human-evidence predicate the executor
#      loops over, plus a SOURCE TRIPWIRE that the loop still calls it;
#   3. `_task_answer_try_delegated`'s gating table, driven through a `sudo` shim —
#      the half that decides whether a seat delegates at all;
#   4. the sudoers grant (pure renderer, no root, no box).
# The standing/self-clear re-derivations run only at EUID 0 and are NOT graded
# here; they are covered by inspection and by DIVE-2159 as the live acceptance
# row. A harness that claimed them would be claiming an arm it never entered.
#
# Run: bash tests/gate_delegated_answer_unit.sh   (no root, no network, no box)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-delegated-answer.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

export STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
export TASKS_DIR="$TMP/tasks";  mkdir -p "$TASKS_DIR"
export TASKS_DB="$TASKS_DIR/tasks.db"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"

set +e   # header.sh enabled `set -e`; this harness asserts on values, not exits

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}" >&2; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

# ---------------------------------------------------------------------------
# 1. The root guard. An unprivileged caller is refused, and the refusal names
#    the primitive rather than failing somewhere deeper with a confusing error.
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  printf 'SKIP arm 1: harness is running as root, which is the arm this cannot grade\n'
else
  out=$(printf '%s\0' "DIVE-1" "--value=approve" | cmd_task_answer_delegated 2>&1); rc=$?
  [[ $rc -ne 0 ]] && ok "arm1: off-root call refuses (rc=$rc)" \
                  || bad "arm1: off-root call refuses" "rc=0"
  case "$out" in
    *"privileged internal primitive"*) ok "arm1: refusal names the primitive" ;;
    *) bad "arm1: refusal names the primitive" "got: $out" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 2. The human-evidence predicate, and the tripwire that the executor uses it.
#    Positive controls AND negative controls: a predicate that returns 0 for
#    everything would pass a forbidden-only list, so the ordinary arguments are
#    asserted to survive.
# ---------------------------------------------------------------------------
for flag in --human --human-proof=abc --channel-proof=123 --channel-msg=7 \
            --tap-uid=1234567890 --tap-username=someone --tap-msg=9 \
            --relay-agent=main --from=main; do
  _task_answer_forbidden_flag "$flag" \
    && ok "arm2: refuses $flag" \
    || bad "arm2: refuses $flag" "predicate returned 1"
done
for flag in --value=approve DIVE-2159 --value="lead:main" ""; do
  _task_answer_forbidden_flag "$flag" \
    && bad "arm2: permits [$flag]" "predicate returned 0 (would refuse a legitimate clear)" \
    || ok "arm2: permits [$flag]"
done
# SOURCE TRIPWIRE. Extracting the check moved it out of the loop's body; this is
# the assertion that the loop did not quietly stop calling it (the standard
# failure of an extracted guard).
if grep -q '_task_answer_forbidden_flag "\$a"' "$SRC/cmd_task.sh"; then
  ok "arm2: the executor's arg loop still calls the predicate"
else
  bad "arm2: the executor's arg loop still calls the predicate" \
      "cmd_task_answer_delegated no longer calls _task_answer_forbidden_flag"
fi
# The structural backstop must sit where every raise-site has already run.
b=$(grep -n 'TASK_ANSWER_DELEGATED:-}" ]] || human=0' "$SRC/cmd_task.sh" | head -1 | cut -d: -f1)
e=$(grep -n 'local _human_evid=' "$SRC/cmd_task.sh" | head -1 | cut -d: -f1)
if [[ -n "$b" && -n "$e" && "$b" -lt "$e" ]]; then
  ok "arm2: human=0 backstop precedes the provenance decision"
else
  bad "arm2: human=0 backstop precedes the provenance decision" "backstop=$b evid=$e"
fi

# ---------------------------------------------------------------------------
# 3. The gating table of `_task_answer_try_delegated`, driven through a `sudo`
#    shim. The shim RECORDS what it was asked, so "did not delegate" is measured
#    as an absent invocation rather than inferred from a return code.
# ---------------------------------------------------------------------------
CALLS="$TMP/sudo.calls"
mkdir -p "$TMP/bin"
cat >"$TMP/bin/sudo" <<'SHIM'
#!/usr/bin/env bash
# Record PROBE and INVOKE distinctly. `sudo -n -l /usr/local/bin/5dive
# _task_answer` and `sudo -n /usr/local/bin/5dive _task_answer` differ by two
# characters, so a recording that stores the raw argv makes "it only asked
# whether it COULD" indistinguishable from "it DID" — and the assertion then
# passes on the wrong event. The first draft of this harness did exactly that and
# the arm below caught it.
if [[ "${1:-}" == "-n" && "${2:-}" == "-l" ]]; then
  printf 'PROBE %s\n' "$*" >>"$CALLS"
  probe="${*: -1}"
  [[ " ${SUDO_SHIM_CAN:-} " == *" $probe "* ]] && exit 0
  exit 1
fi
# otherwise: the delegated call itself
printf 'INVOKE %s\n' "$*" >>"$CALLS"
cat >/dev/null
[[ "${SUDO_SHIM_DELEGATE_RC:-0}" == "0" ]] && { printf 'OK — DIVE-9999 gate cleared\n'; exit 0; }
printf '_task_answer: refused\n' >&2
exit "${SUDO_SHIM_DELEGATE_RC}"
SHIM
chmod +x "$TMP/bin/sudo"
export CALLS
PATH="$TMP/bin:$PATH"

: >"$CALLS"; export SUDO_SHIM_CAN="sign"          # seat CAN sign directly
_task_answer_try_delegated DIVE-1 --value=approve >/dev/null 2>&1
check "arm3: a seat that can sign directly does not delegate" \
      "$(grep -c '^INVOKE' "$CALLS")" "0"

: >"$CALLS"; export SUDO_SHIM_CAN=""              # neither grant
_task_answer_try_delegated DIVE-1 --value=approve >/dev/null 2>&1
check "arm3: a seat with neither grant does not delegate" \
      "$(grep -c '^INVOKE' "$CALLS")" "0"

: >"$CALLS"; export SUDO_SHIM_CAN="_task_answer"  # cannot sign, CAN delegate
export SUDO_SHIM_DELEGATE_RC=0
out=$(_task_answer_try_delegated DIVE-1 --value=approve 2>&1); rc=$?
check "arm3: the cli-scoped seat delegates" "$rc" "0"
case "$out" in *"gate cleared"*) ok "arm3: the delegated output reaches the caller" ;;
               *) bad "arm3: the delegated output reaches the caller" "got: $out" ;; esac
if grep -q '^INVOKE .*bin/5dive _task_answer' "$CALLS"; then
  ok "arm3: the exact-path primitive was the thing invoked"
else
  bad "arm3: the exact-path primitive was the thing invoked" "$(cat "$CALLS")"
fi

: >"$CALLS"                                        # recursion guard
TASK_ANSWER_DELEGATED=1 _task_answer_try_delegated DIVE-1 --value=approve >/dev/null 2>&1
check "arm3: the executor's own re-entry does not recurse" \
      "$(grep -c '^INVOKE' "$CALLS")" "0"
unset TASK_ANSWER_DELEGATED

: >"$CALLS"; export SUDO_SHIM_DELEGATE_RC=1        # delegated call REFUSES
out=$(_task_answer_try_delegated DIVE-1 --value=approve 2>&1); rc=$?
check "arm3: a refusal falls through to the existing path" "$rc" "1"
case "$out" in *"will store UNSIGNED"*) ok "arm3: the fall-through says what it costs" ;;
               *) bad "arm3: the fall-through says what it costs" "got: $out" ;; esac
unset SUDO_SHIM_DELEGATE_RC

# ---------------------------------------------------------------------------
# 4. The grant. Exact command path, no wildcard, and present for a seat with NO
#    push and NO deploy capability — the cli-scoped lead this ticket is about.
# ---------------------------------------------------------------------------
s=$(render_standard_sudoers agent-main2 0 0)
case "$s" in
  *"NOPASSWD: /usr/local/bin/5dive _task_answer"*)
    ok "arm4: the cli-scoped grant carries _task_answer" ;;
  *) bad "arm4: the cli-scoped grant carries _task_answer" "$s" ;;
esac
line=$(printf '%s\n' "$s" | grep '_task_answer')
case "$line" in
  *"_task_answer *"|*"_task_answer  "*) bad "arm4: no argument wildcard" "$line" ;;
  *) ok "arm4: no argument wildcard (params travel over stdin)" ;;
esac
# The unquoted heredoc executes backticks and $ in COMMENTS (the note in
# render_standard_sudoers). Assert the block it renders is free of both, or the
# next editor's comment lands in a sudoers file visudo then rejects.
case "$s" in
  *'`'*) bad "arm4: rendered policy is backtick-free" "a backtick survived into the sudoers text" ;;
  *) ok "arm4: rendered policy is backtick-free" ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
