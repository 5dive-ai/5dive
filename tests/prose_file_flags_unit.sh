#!/usr/bin/env bash
# TIER: nightly — 17.2s measured by scripts/run-harnesses.sh on the 5dive control-plane
# VM (standalone runs: 16.5s, 17.8s; the slower is claimed on purpose, since a low claim
# is what the DIVE-2555 grader reds). Demoted, and the reason is NOT "it is slow": the
# core tier is ALREADY 397s against its 300s cap on this box in the same sweep, and main
# measured 306s on test-installed-host on a branch that does not contain this file. So
# core is over before this harness exists, and CLAUDE.md's rule at that point is that a
# new guard REPLACES or MERGES an existing one. There is nothing here to merge with — no
# existing harness covers prose-flag file input, because the flags are new in this diff —
# and nothing to retire, so nightly is the honest third door rather than adding 17.2s to
# a tier that is already 97s past its ratchet. Coverage on THIS PR is unaffected: the
# changed-harnesses job runs every harness the diff touches whatever its tier.
#
# THE BILL FOR THAT, stated so the next reader does not have to rediscover it
# (main, reviewing #449): nightly is what let DIVE-2588 red main invisibly. A
# src/ change that breaks this file reds it AFTER the PR responsible has merged,
# so its author never sees the red. changed-harnesses covers the PR that touches
# THIS file; it does not cover a future PR that breaks it from somewhere else.
# That cost is knowingly paid here, not overlooked — and it is the argument for
# promoting this back to core the moment the tier has room.
# DIVE-2627 unit harness for the *-file prose flags.
#
# WHAT IT GRADES. Every prose flag in this CLI used to be argv-only, so the
# CALLER'S SHELL assembled the value before the CLI ever ran: a backtick inside a
# double-quoted value is executed as command substitution, the words are silently
# replaced, and the command still exits 0 (see
# community/wiki/the-payload-is-corrupted-before-the-cli-is-invoked.md). DIVE-2627
# adds a file path alongside each one. The property under test is therefore ONE
# property, asserted per flag: the bytes in the file are the bytes in the record.
#
# THE PAYLOAD carries all four hostile classes at once — backtick, dollar sign,
# apostrophe, newline — because the two obvious "fixes" each defeat exactly one of
# them (double quotes stop apostrophes and run backticks; single quotes stop
# backticks and end at the apostrophe). A payload with three of the four would pass
# against a half-fix.
#
# Same isolation contract as task_set_body_unit.sh: source src/ directly, point
# STATE_DIR at a throwaway temp dir so the live shared tasks.db is NEVER touched.
# Run: bash tests/prose_file_flags_unit.sh   (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/prose-file-flags-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_agent_runtime.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run()   { local verb="$1"; shift; ( "cmd_task_$verb" "$@" ) 2>"$TMP"/err; }
jf()    { jq -r "$1" 2>/dev/null; }

# BYTE comparison, not string comparison. `got=$(db "SELECT body …")` would strip
# the trailing newline on the way OUT of the store and hand every arm below a
# comparison that cannot see the one byte the naive reader eats — a harness that
# reproduces the defect it is grading. hex() on the SQL side and od on the file
# side both yield a trailing-whitespace-free token, so $(...) is safe on them.
hexof() { od -An -tx1 -v < "$1" | tr -d ' \n' | tr 'a-f' 'A-F'; }
dbhex() { db "SELECT hex(COALESCE($1,'')) FROM tasks WHERE id=$2;"; }

tasks_db_init

# ---------------------------------------------------------------------------
# The payload, and the NON-VACUITY ANCHOR that proves it is hostile.
# ---------------------------------------------------------------------------
# Composed with a QUOTED-delimiter heredoc — the one form that is safe in both
# directions — so this harness's own authoring does not mangle the thing it is
# grading. Written to disk with a trailing newline, exactly as any editor or
# `cat > file` would leave it, because a trailing newline is the byte the naive
# `$(cat file)` implementation eats.
PAYLOAD=$(cat <<'PAYLOAD_EOF'
run `5dive task need DIVE-1 --ask="x"` first, then `5dive push`
budget is $500 and ${STATE_DIR} must not expand; 100% of it
don't drop the maker's words — an apostrophe ends a single-quoted string
PAYLOAD_EOF
)
PAYLOAD="$PAYLOAD"$'\n'   # trailing newline, on purpose (see above)
PF="$TMP/payload.txt"
printf '%s' "$PAYLOAD" > "$PF"
PAYLOAD_HEX=$(hexof "$PF")

# A test that passes on empty output proves nothing. Anchor every class first: if
# any of these four goes missing (an edit to the heredoc, a shell that mangled it
# on the way in) the whole file's round-trip arms become weaker without saying so.
anchor_ok=1
[[ "$PAYLOAD" == *'`'* ]]   || { anchor_ok=0; bad_t "ANCHOR: payload carries a backtick" "payload=$PAYLOAD"; }
[[ "$PAYLOAD" == *'$'* ]]   || { anchor_ok=0; bad_t "ANCHOR: payload carries a dollar sign" "payload=$PAYLOAD"; }
[[ "$PAYLOAD" == *"'"* ]]   || { anchor_ok=0; bad_t "ANCHOR: payload carries an apostrophe" "payload=$PAYLOAD"; }
[[ "$PAYLOAD" == *$'\n'* ]] || { anchor_ok=0; bad_t "ANCHOR: payload carries a newline" "payload=$PAYLOAD"; }
[[ "$PAYLOAD" == *$'\n' ]]  || { anchor_ok=0; bad_t "ANCHOR: payload ends with a newline" "payload=$PAYLOAD"; }
(( anchor_ok )) && ok_t "ANCHOR: payload carries all four hostile classes + a trailing newline"

# The file on disk must equal the variable, or every arm below grades the wrong
# object. cmp against a second write rather than re-reading with $(...), which is
# the very stripping this harness exists to catch.
printf '%s' "$PAYLOAD" | cmp -s - "$PF" \
  && ok_t "ANCHOR: the payload file holds the payload bytes" \
  || bad_t "ANCHOR: the payload file holds the payload bytes" "cmp differs"

# ---------------------------------------------------------------------------
# T1 — task add --body-file
# ---------------------------------------------------------------------------
id1=$(run add --assignee=alice --no-verify --body-file="$PF" -- "prose file body" | jf '.data.id')
[[ "$(dbhex body "$id1")" == "$PAYLOAD_HEX" ]] \
  && ok_t "task add --body-file records the body byte-identically" \
  || bad_t "task add --body-file byte-identical" "got hex: $(dbhex body "$id1")"

# ---------------------------------------------------------------------------
# T2 — THE MUTATION ARM. Replace _read_prose_file with the naive implementation
# ($(cat), the obvious way to write it) and assert the SAME assertion goes RED.
# Without this, T1 could be passing because the comparison itself is toothless.
# ---------------------------------------------------------------------------
_real_read_prose_file=$(declare -f _read_prose_file)
_read_prose_file() { _PROSE_FILE_VALUE="$(cat "$2")"; }   # the naive version
id_mut=$(run add --assignee=alice --no-verify --body-file="$PF" -- "mutated reader" | jf '.data.id')
got_mut=$(dbhex body "$id_mut")
[[ "$got_mut" != "$PAYLOAD_HEX" ]] \
  && ok_t "MUTATION: the naive \$(cat) reader FAILS the same assertion (it is not vacuous)" \
  || bad_t "MUTATION: naive reader should have failed the round-trip" \
           "the assertion cannot distinguish the two implementations — it grades nothing"
eval "$_real_read_prose_file"   # restore the real reader
# ...and confirm the restore landed, or every arm after this one grades the stub.
declare -f _read_prose_file | grep -q 'read -r -d' \
  && ok_t "MUTATION: the real reader is restored before the remaining arms" \
  || bad_t "MUTATION: reader not restored" "$(declare -f _read_prose_file)"

# ---------------------------------------------------------------------------
# T3 — task add --accept-file (what a VERIFIER grades against)
# ---------------------------------------------------------------------------
id3=$(run add --assignee=alice --verifier=bob --accept-file="$PF" -- "prose file accept" | jf '.data.id')
[[ "$(dbhex acceptance_criteria "$id3")" == "$PAYLOAD_HEX" ]] \
  && ok_t "task add --accept-file records the acceptance criteria byte-identically" \
  || bad_t "task add --accept-file byte-identical" "got hex: $(dbhex acceptance_criteria "$id3")"

# ---------------------------------------------------------------------------
# T4 — task done --result-file (the permanent close record)
# ---------------------------------------------------------------------------
id4=$(run add --assignee=alice --no-verify -- "prose file result" | jf '.data.id')
run done "$id4" --result-file="$PF" >/dev/null
[[ "$(dbhex result "$id4")" == "$PAYLOAD_HEX" ]] \
  && ok_t "task done --result-file records the result byte-identically" \
  || bad_t "task done --result-file byte-identical" "got hex: $(dbhex result "$id4"); err: $(cat "$TMP"/err)"

# ---------------------------------------------------------------------------
# T5 — task set-body --file, and the newline the positional form cannot carry
# ---------------------------------------------------------------------------
id5=$(run add --assignee=alice --no-verify -- "prose file set-body" | jf '.data.id')
run set_body "$id5" --file="$PF" >/dev/null
[[ "$(dbhex body "$id5")" == "$PAYLOAD_HEX" ]] \
  && ok_t "task set-body --file records the body byte-identically" \
  || bad_t "task set-body --file byte-identical" "got hex: $(dbhex body "$id5")"

# The positional form re-joins words with single spaces. This is not a regression
# and not a bug being fixed here — it is the reason --file is the only faithful
# route, stated as a measurement rather than a claim.
id5b=$(run add --assignee=alice --no-verify -- "positional flattening control" | jf '.data.id')
run set_body "$id5b" $'alpha\nbeta' >/dev/null
[[ "$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id5b};")" == *$'\n'* ]] \
  && ok_t "CONTROL: positional set-body preserved a newline (single argument)" \
  || bad_t "CONTROL: positional set-body preserved a newline" "flattened"

# ---------------------------------------------------------------------------
# T6 — task need --ask-file and --recommend-file (the human-facing gate record)
# ---------------------------------------------------------------------------
id6=$(run add --assignee=alice --no-verify -- "prose file gate" | jf '.data.id')
# --type=approval, not decision, on purpose: a DECISION gate validates --recommend
# against --options and the payload is prose rather than an option label, while
# --recommend applies only to decision/approval. The thing under test is the
# READER, which is the same reader for every gate type — so grading it on the type
# that lets prose through is the honest arm, not a weaker one.
run need "$id6" --type=approval --ask-file="$PF" --recommend-file="$PF" >/dev/null
[[ "$(dbhex ask "$id6")" == "$PAYLOAD_HEX" ]] \
  && ok_t "task need --ask-file records the ask byte-identically" \
  || bad_t "task need --ask-file byte-identical" "got hex: $(dbhex ask "$id6"); err: $(cat "$TMP"/err)"
[[ "$(dbhex recommend "$id6")" == "$PAYLOAD_HEX" ]] \
  && ok_t "task need --recommend-file records the recommendation byte-identically" \
  || bad_t "task need --recommend-file byte-identical" "got hex: $(dbhex recommend "$id6")"

# ---------------------------------------------------------------------------
# T7 — agent send --message-file. cmd_send's next call after parsing is
# a2a_needs_scoped, and bash locals are dynamically scoped, so a stub there sees
# the body the parser actually built and hands downstream. That is the real
# measurement; asserting the flag appears in the case block would not be.
# ---------------------------------------------------------------------------
a2a_needs_scoped() { printf '%s' "$message" > "$TMP/captured"; return 1; }
require_agent()    { fail "$E_NOT_FOUND" "stub-stop (parse graded, delivery not attempted)"; }
rm -f "$TMP/captured"
( cmd_send peer --message-file="$PF" ) >/dev/null 2>"$TMP"/err
if [[ -f "$TMP/captured" ]]; then
  cap=$(cat "$TMP/captured")   # $(...) strips the trailing newline; cmp does not
  printf '%s' "$PAYLOAD" | cmp -s - "$TMP/captured" \
    && ok_t "agent send --message-file hands the body downstream byte-identically" \
    || bad_t "agent send --message-file byte-identical" "got: $(printf '%q' "$cap")"
else
  bad_t "agent send --message-file reached delivery" "no capture; err: $(cat "$TMP"/err)"
fi

# --message-file + positional text is refused rather than silently dropping one
rm -f "$TMP/captured"
( cmd_send peer extra words --message-file="$PF" ) >/dev/null 2>"$TMP"/err
[[ ! -f "$TMP/captured" ]] && grep -q -- '--message-file conflicts with the positional text' "$TMP"/err \
  && ok_t "agent send refuses --message-file together with positional text" \
  || bad_t "agent send --message-file + positional refusal" "err: $(cat "$TMP"/err)"

# ---------------------------------------------------------------------------
# T8 — the refusals. Each names the flag, so a caller reads which of the two
# they passed twice rather than a generic usage dump.
# ---------------------------------------------------------------------------
id8=$(run add --assignee=alice --no-verify -- "refusal arms" | jf '.data.id')

run need "$id8" --type=decision --ask="inline" --ask-file="$PF" >/dev/null
rc=$?
[[ $rc -eq $E_USAGE ]] && grep -q -- '--ask-file conflicts with --ask' "$TMP"/err \
  && ok_t "--ask and --ask-file together are refused (E_USAGE), naming both" \
  || bad_t "--ask + --ask-file refusal" "rc=$rc err: $(cat "$TMP"/err)"

run need "$id8" --type=decision --ask-file="$TMP/nope.txt" >/dev/null
rc=$?
[[ $rc -eq $E_USAGE ]] && grep -q "no such file" "$TMP"/err \
  && ok_t "a missing --ask-file path is refused (E_USAGE)" \
  || bad_t "missing file refusal" "rc=$rc err: $(cat "$TMP"/err)"

: > "$TMP/empty.txt"
run need "$id8" --type=decision --ask-file="$TMP/empty.txt" >/dev/null
rc=$?
[[ $rc -eq $E_VALIDATION ]] && grep -q "is empty" "$TMP"/err \
  && ok_t "an EMPTY --ask-file is refused (E_VALIDATION), not recorded as empty prose" \
  || bad_t "empty file refusal" "rc=$rc err: $(cat "$TMP"/err)"

# The refusals must not have written a gate on the row — a refusal that half-lands
# is the same undetectable-wrong-record this ticket is about.
[[ "$(db "SELECT COALESCE(ask,'') FROM tasks WHERE id=${id8};")" == "" ]] \
  && ok_t "no refused --ask-file left a partial gate record behind" \
  || bad_t "refused --ask-file wrote a record" "$(db "SELECT ask FROM tasks WHERE id=${id8};")"

# ---------------------------------------------------------------------------
# T9 — the argv forms are NOT removed (the ticket says add alongside, and the
# whole fleet still calls them).
# ---------------------------------------------------------------------------
id9=$(run add --assignee=alice --no-verify --body="plain inline body" -- "argv still works" | jf '.data.id')
[[ "$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id9};")" == "plain inline body" ]] \
  && ok_t "the inline --body argv form still works unchanged" \
  || bad_t "inline --body regression" "$(db "SELECT body FROM tasks WHERE id=${id9};")"
run done "$id9" --result="plain inline result" >/dev/null
[[ "$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${id9};")" == "plain inline result" ]] \
  && ok_t "the inline --result argv form still works unchanged" \
  || bad_t "inline --result regression" "$(db "SELECT result FROM tasks WHERE id=${id9};")"

# A REPEATED argv flag keeps its old last-wins behaviour. This arm exists because
# the natural way to write _prose_flag_dupe refuses it too — which would ship a
# silent behaviour change to every existing caller inside an additive change.
id10=$(run add --assignee=alice --no-verify --body="first" --body="second" -- "repeat argv" | jf '.data.id')
[[ "$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id10};")" == "second" ]] \
  && ok_t "a REPEATED --body keeps last-wins (the argv forms are unchanged)" \
  || bad_t "repeated --body last-wins" "got: $(db "SELECT body FROM tasks WHERE id=${id10};"); err: $(cat "$TMP"/err)"

# ...and the same repeat on the FILE form is likewise not the ambiguity being refused.
id11=$(run add --assignee=alice --no-verify --body-file="$PF" --body-file="$PF" -- "repeat file" | jf '.data.id')
[[ "$(dbhex body "$id11")" == "$PAYLOAD_HEX" ]] \
  && ok_t "a REPEATED --body-file is accepted (same flag, same answer)" \
  || bad_t "repeated --body-file" "err: $(cat "$TMP"/err)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
