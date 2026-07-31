#!/usr/bin/env bash
# DIVE-2411 isolated unit harness — a `secret` gate must NAME A DELIVERY PATH, at
# filing time AND at answer time.
#
# WHY THIS EXISTS (measured, DIVE-2232, 2026-07-30):
#   * FILING. `task need --type=secret` with neither --secret-key nor --connector
#     was the DEFAULTED "legacy out-of-band" shape. The gate pinged correctly, the
#     ask read as complete, and NO PATH existed for the value to reach the box —
#     the only remaining answer was pasting a live credential into a persistent
#     chat log. main nearly received one. A human staring at the ask cannot see
#     that the drop is missing; nothing in the message is about the drop. Only the
#     filer can, and only at filing time.
#   * ANSWERING, which is worse. That gate WAS answered: need_answered_by=
#     human:main, uid 1004, need_answer_sig VALID, human_nonce_hash SET — a real
#     human holding the raw nonce tapped ✅ Provided — and need_answer EMPTY, no
#     connector file written, no drop ever minted, no value anywhere. The record
#     reads "credential provided, human-attested, signed, nonced" over nothing.
#     Provenance and payload are independent and only provenance was ever checked.
#   * THE AFFORDANCE. ✅ Provided is legitimate for "I already ran `5dive secret
#     write` myself" — true on a gate with a drop target, meaningless on a gate
#     that never named one. It was offered anyway, on a BATCHED six-gate message
#     whose batcher cannot know what any of the six drops targeted, which is why
#     the fix is at the affordance/mint layer (_task_gate_reply_markup reads the
#     ROW) and not in the batcher's copy.
#
# WHAT IS PINNED HERE. Both halves are ABSENCE assertions ("must not accept"),
# which pass on empty output, so every negative arm asserts a NONZERO rc AND that
# the row did not move — never rc alone (feedback: a refusal graded by rc alone
# passes the wrong refusal, so each also matches the refusal REASON). The positive
# arms exist because the cheap version of this fix bricks out-of-band delivery and
# the legitimate box-side write:
#   N1  filing with no delivery path is refused, and NO gate is written
#   N2  --out-of-band on a non-secret type is refused
#   N3  --out-of-band together with a drop target is refused (one path per gate)
#   N4  a bare/short --out-of-band is refused (it must NAME the channel)
#   N5  a re-file with nothing to inherit is refused
#   N6  answering a no-path secret gate is refused and the row does NOT transition
#   N7  no ✅ Provided affordance on a no-path secret gate
#   P1  drop target files and is stored
#   P2  explicit --out-of-band files and is stored
#   P3  a re-file inherits the drop target (the council-escalation shape)
#   P4  a drop-target gate still ANSWERS (the legitimate `secret write` case)
#   P5  an out-of-band gate still ANSWERS
#   P6  drop-target gate still gets its ✅ Provided button
#   P7  out-of-band gate still gets its ✅ Provided button
#   T8  the no-path gate's alert text names the missing path and offers no tap
# Isolation matches the sibling harnesses: source src/ libs, throwaway STATE_DIR —
# the live shared tasks.db is NEVER touched.
# Run: bash tests/secret_gate_delivery_path_unit.sh   (no root, no network)
#
# MUTATION GRADING lives in tests/secret_gate_delivery_path_mutation.sh, which
# re-runs this suite once per safety condition with that condition deleted (in a
# COPY of src/) and demands the named arm go red. An absence-assertion suite that
# nobody mutation-grades is exactly the shape this ticket is about, and a mutation
# mode that only runs when a human passes a flag is graded by nobody in CI.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` — see the sibling harnesses: redirecting the
# source's stderr also swallows the helper's own line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC="${SGDP_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/sgdp-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# Notify is a no-op in isolation (no channel resolves), but it is also how the raw
# per-gate human nonce reaches us: cmd_task_need hands it to notify as $8, and the
# answer path needs it as --human-proof (this harness runs as an agent account, so
# the nonce is its only human-evidence form).
NONCE=""
task_need_notify() { NONCE="${8:-}"; return 0; }

# The human-only block in cmd_task_answer refuses when the CALLER is an agent
# account, and this suite runs as one, so P4/P5 would grade that refusal instead
# of the delivery-path decision. Pin the DIVE-2330 seams to a non-agent uid — the
# seam exists precisely so a harness can model a non-agent caller (its own comment
# says so, after the EUID bypass made suite outcomes a function of whose uid ran
# them). Every NEGATIVE arm below is unaffected: the delivery-path refusal lands
# BEFORE this block, and N6 asserts its reason text, not just a nonzero rc.
_PIN_UID=987654
_gate_caller_uid() { printf '%s' "$_PIN_UID"; }
_gate_passwd_stream() {
  printf '%s:x:%s:%s::/nonexistent:/bin/false\n' "human-fixture" "$_PIN_UID" "$_PIN_UID"
  printf '%s\n' "$(</etc/passwd)"
}

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }

# ============================ FILING ==========================================

# --- N1: no delivery path -> refused, and NOTHING is written ------------------
# Command substitution runs cmd_task_need in a subshell so its `fail` exit cannot
# kill this harness (a fail-fast harness cannot grade per assertion).
seed_task DIVE-2401
out=$(cmd_task_need DIVE-2401 --type=secret --ask="drop the GH_BOT_TOKEN" 2>&1); rc=$?
if [[ $rc -ne 0 ]] \
   && [[ "$out" == *"must name a delivery path"* ]] \
   && [[ "$out" == *"--secret-key"* && "$out" == *"--connector"* && "$out" == *"--out-of-band"* ]]; then
  ok_t "N1 filing with no delivery path is refused, naming both flags and the opt-in"
else
  bad_t "N1 filing with no delivery path is refused, naming both flags and the opt-in" "rc=$rc out=$out"
fi
# The row must not have moved AT ALL — a refusal that leaves a half-filed gate is
# the DIVE-2233 shape (refused the caller, created the state anyway).
got="$(field DIVE-2401 need_type)|$(field DIVE-2401 ask)|$(field DIVE-2401 need_asked_at)|$(field DIVE-2401 human_nonce_hash)|$(field DIVE-2401 status)"
[[ "$got" == "∅|∅|∅|∅|todo" ]] \
  && ok_t "N1b the refused filing wrote no gate (type/ask/asked_at/nonce all NULL, status untouched)" \
  || bad_t "N1b the refused filing wrote no gate (type/ask/asked_at/nonce all NULL, status untouched)" "got: $got"

# --- N2: --out-of-band is secret-only ----------------------------------------
seed_task DIVE-2402
out=$(cmd_task_need DIVE-2402 --type=approval --ask="approve the deploy" --out-of-band="in my .env on this box" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"only applies to --type=secret"* && "$(field DIVE-2402 need_type)" == "∅" ]] \
  && ok_t "N2 --out-of-band on a non-secret gate is refused (no row written)" \
  || bad_t "N2 --out-of-band on a non-secret gate is refused (no row written)" "rc=$rc need_type=$(field DIVE-2402 need_type) out=$out"

# --- N3: one delivery path per gate ------------------------------------------
seed_task DIVE-2403
out=$(cmd_task_need DIVE-2403 --type=secret --ask="drop it" --secret-key=GH_BOT_TOKEN --connector=github-bot --out-of-band="in my .env on this box" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"mutually exclusive"* && "$(field DIVE-2403 need_type)" == "∅" ]] \
  && ok_t "N3 --out-of-band + drop target is refused (no row written)" \
  || bad_t "N3 --out-of-band + drop target is refused (no row written)" "rc=$rc need_type=$(field DIVE-2403 need_type) out=$out"

# --- N4: the opt-in must NAME the channel ------------------------------------
# A bare "yes" opt-in would restore the defect with a flag in front of it.
seed_task DIVE-2404
out=$(cmd_task_need DIVE-2404 --type=secret --ask="drop it" --out-of-band="yes" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"must NAME where the value will land"* && "$(field DIVE-2404 need_type)" == "∅" ]] \
  && ok_t "N4 a bare --out-of-band=yes is refused (must name the channel)" \
  || bad_t "N4 a bare --out-of-band=yes is refused (must name the channel)" "rc=$rc need_type=$(field DIVE-2404 need_type) out=$out"

# --- P1: drop target files and is stored -------------------------------------
seed_task DIVE-2405
cmd_task_need DIVE-2405 --type=secret --ask="drop the GH_BOT_TOKEN" --secret-key=GH_BOT_TOKEN --connector=github-bot >/dev/null 2>&1
got="$(field DIVE-2405 need_type)|$(field DIVE-2405 secret_key)|$(field DIVE-2405 connector)|$(field DIVE-2405 secret_oob)"
[[ "$got" == "secret|GH_BOT_TOKEN|github-bot|∅" ]] \
  && ok_t "P1 drop-target secret gate files and stores the target" \
  || bad_t "P1 drop-target secret gate files and stores the target" "got: $got"

# --- P2: the out-of-band shape stays reachable when CHOSEN --------------------
seed_task DIVE-2406
cmd_task_need DIVE-2406 --type=secret --ask="drop it" --out-of-band="already in my .env on this box" >/dev/null 2>&1
got="$(field DIVE-2406 need_type)|$(field DIVE-2406 secret_key)|$(field DIVE-2406 secret_oob)"
[[ "$got" == "secret|∅|already in my .env on this box" ]] \
  && ok_t "P2 explicit --out-of-band files and records the declared channel" \
  || bad_t "P2 explicit --out-of-band files and records the declared channel" "got: $got"

# --- P3: a re-file INHERITS the delivery path (the council-escalation shape) --
# src/council/engine.mjs re-files an escalated gate as
# `task need <ident> --type=secret --tier=2 --ask=...` — type preserved, nothing
# else. Without inheritance that re-file converts a properly-targeted gate into
# the DIVE-2232 shape, i.e. the defect would have a generator.
out=$(cmd_task_need DIVE-2405 --type=secret --tier=2 --ask="[council escalation] still needs the human" 2>&1); rc=$?
got="$(field DIVE-2405 secret_key)|$(field DIVE-2405 connector)"
[[ $rc -eq 0 && "$got" == "GH_BOT_TOKEN|github-bot" ]] \
  && ok_t "P3 a re-file with no flags inherits the existing drop target" \
  || bad_t "P3 a re-file with no flags inherits the existing drop target" "rc=$rc got=$got out=$out"
out=$(cmd_task_need DIVE-2406 --type=secret --tier=2 --ask="[council escalation] still needs the human" 2>&1); rc=$?
[[ $rc -eq 0 && "$(field DIVE-2406 secret_oob)" == "already in my .env on this box" ]] \
  && ok_t "P3b a re-file with no flags inherits the declared out-of-band channel" \
  || bad_t "P3b a re-file with no flags inherits the declared out-of-band channel" "rc=$rc oob=$(field DIVE-2406 secret_oob) out=$out"

# --- N5: a re-file with NOTHING to inherit is still refused -------------------
# Inheritance must not become a back door: a row whose gate columns are empty
# (never targeted, or withdrawn — withdraw NULLs them) has nothing to carry.
seed_task DIVE-2407
db "UPDATE tasks SET need_type='decision', ask='pick one', status='blocked' WHERE ident='DIVE-2407';"
out=$(cmd_task_need DIVE-2407 --type=secret --ask="drop it" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"must name a delivery path"* && "$(field DIVE-2407 need_type)" == "decision" ]] \
  && ok_t "N5 a re-file with no path to inherit is refused (prior gate untouched)" \
  || bad_t "N5 a re-file with no path to inherit is refused (prior gate untouched)" "rc=$rc need_type=$(field DIVE-2407 need_type) out=$out"

# ============================ ANSWERING =======================================

# --- N6: the DIVE-2232 shape cannot be STAMPED -------------------------------
# Built by direct SQL, deliberately: this row can no longer be produced by
# `task need` (N1), and the exposure is exactly the rows that ALREADY exist —
# plus every ✅ Provided button already sitting in someone's chat history, which
# Telegram never expires. Fields mirror the measured DIVE-2232 row.
seed_task DIVE-2408
db "UPDATE tasks SET need_type='secret', ask='drop the GH_BOT_TOKEN', tier=2, status='blocked',
      need_asked_at=datetime('now'), human_nonce_hash='$(printf 'a%.0s' {1..64})',
      secret_key=NULL, connector=NULL, secret_oob=NULL WHERE ident='DIVE-2408';"
out=$(cmd_task_answer DIVE-2408 --from=main --human 2>&1); rc=$?
if [[ $rc -ne 0 ]] && [[ "$out" == *"names NO delivery path"* ]]; then
  ok_t "N6 answering a no-path secret gate is refused, and the reason names the missing path"
else
  bad_t "N6 answering a no-path secret gate is refused, and the reason names the missing path" "rc=$rc out=$out"
fi
got="$(field DIVE-2408 need_answered_at)|$(field DIVE-2408 need_answered_by)|$(field DIVE-2408 need_answer_sig)|$(field DIVE-2408 status)"
[[ "$got" == "∅|∅|∅|blocked" ]] \
  && ok_t "N6b the refused answer left no provenance (answered_at/by/sig NULL, still blocked)" \
  || bad_t "N6b the refused answer left no provenance (answered_at/by/sig NULL, still blocked)" "got: $got"

# --- P4: a drop-target gate still ANSWERS (do not brick `secret write`) ------
# This is the legitimate case the affordance exists for: "I already ran
# `5dive secret write` on the box myself" — true on a gate that named a target.
seed_task DIVE-2409
NONCE=""
cmd_task_need DIVE-2409 --type=secret --ask="drop the GH_BOT_TOKEN" --secret-key=GH_BOT_TOKEN --connector=github-bot >/dev/null 2>&1
out=$(cmd_task_answer DIVE-2409 --from=main --human --human-proof="$NONCE" 2>&1); rc=$?
[[ $rc -eq 0 && "$(field DIVE-2409 need_answered_at)" != "∅" ]] \
  && ok_t "P4 a drop-target secret gate still accepts a human 'provided' answer" \
  || bad_t "P4 a drop-target secret gate still accepts a human 'provided' answer" "rc=$rc answered_at=$(field DIVE-2409 need_answered_at) out=$out"

# --- P5: an explicitly out-of-band gate still ANSWERS ------------------------
# Its ask NAMED where the value goes, so "I put it there" is a coherent claim.
seed_task DIVE-2410
NONCE=""
cmd_task_need DIVE-2410 --type=secret --ask="drop it" --out-of-band="already in my .env on this box" >/dev/null 2>&1
out=$(cmd_task_answer DIVE-2410 --from=main --human --human-proof="$NONCE" 2>&1); rc=$?
[[ $rc -eq 0 && "$(field DIVE-2410 need_answered_at)" != "∅" ]] \
  && ok_t "P5 an out-of-band secret gate still accepts a human 'provided' answer" \
  || bad_t "P5 an out-of-band secret gate still accepts a human 'provided' answer" "rc=$rc answered_at=$(field DIVE-2410 need_answered_at) out=$out"

# ============================ THE AFFORDANCE ==================================
# _task_gate_reply_markup reads the ROW (not a parameter), so the single-gate
# notify and the batch re-send are both covered by the same decision.
kb() { _task_gate_reply_markup "$(db "SELECT id FROM tasks WHERE ident='$1';")" secret "" "" "" claude 2>/dev/null; }

# --- N7: no ✅ Provided button on a gate that named no path ------------------
got=$(kb DIVE-2408)
[[ "$got" != *"provided"* ]] \
  && ok_t "N7 no ✅ Provided affordance is offered on a no-path secret gate" \
  || bad_t "N7 no ✅ Provided affordance is offered on a no-path secret gate" "markup: $got"

# --- P6/P7: the button survives where it MEANS something ---------------------
got=$(kb DIVE-2405)
[[ "$got" == *'"tna:'*':provided'* ]] \
  && ok_t "P6 a drop-target secret gate still gets its ✅ Provided button" \
  || bad_t "P6 a drop-target secret gate still gets its ✅ Provided button" "markup: $got"
got=$(kb DIVE-2406)
[[ "$got" == *'"tna:'*':provided'* ]] \
  && ok_t "P7 an out-of-band secret gate still gets its ✅ Provided button" \
  || bad_t "P7 an out-of-band secret gate still gets its ✅ Provided button" "markup: $got"

# ============================ THE ALERT TEXT ==================================
# The prose half ships with zero coverage unless it is graded too: a fix whose
# remedy text tells the human to do the impossible is still a live defect. The
# instruction on a no-path gate must NOT invite a tap or a paste — the tap is
# withheld (N7) and `task answer` refuses (N6), so the only honest line is
# "this gate names no delivery path and has to be re-filed".
txt=$(_task_secret_gate_cta DIVE-2408 "$(db "SELECT id FROM tasks WHERE ident='DIVE-2408';")" "" "" "")
if [[ "$txt" == *"NO delivery path"* && "$txt" == *"re-filed"* ]] \
   && [[ "$txt" != *"tap ✅ Provided"* ]] && [[ "$txt" != *"task answer"* ]]; then
  ok_t "T8 the no-path alert names the missing path and offers neither a tap nor a paste"
else
  bad_t "T8 the no-path alert names the missing path and offers neither a tap nor a paste" "text: $txt"
fi
txt=$(_task_secret_gate_cta DIVE-2406 "$(db "SELECT id FROM tasks WHERE ident='DIVE-2406';")" "" "" "")
[[ "$txt" == *"already in my .env on this box"* && "$txt" == *"tap ✅ Provided"* ]] \
  && ok_t "T8b the out-of-band alert names the declared channel and keeps the tap" \
  || bad_t "T8b the out-of-band alert names the declared channel and keeps the tap" "text: $txt"

printf '\nsecret-gate delivery-path unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
