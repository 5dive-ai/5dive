#!/usr/bin/env bash
# DIVE-4698 — the pairing that makes a PERSON, and the threshold it must not
# cross in silence.
#
# WHAT THIS IS ABOUT. `5dive human` (DIVE-3342) can name the person a gate
# belongs to, but nothing ever WROTE a row: no INSERT existed outside
# src/cmd_human.sh, so the table was empty on this box and on every box. Pairing
# already learned the person — it put their numeric id in the bot's allowFrom and
# in the box-wide operator allowlist — and then discarded the identity. This
# harness grades the write that closes that, and the one hazard it introduces.
#
# THE HAZARD, and it is why half these arms exist: `_human_registry_active` is
# `COUNT(*) > 0`, so the FIRST row switches every gate send off the pre-DIVE-3342
# pointer/fan-out path and onto registry routing, where an unresolved recipient is
# HELD on the agent rail rather than broadcast. That is safe at exactly one row —
# `_human_gate_recipient`'s last arm resolves a one-person registry to that person
# unconditionally — and stops being safe at two. So the write must always LINK,
# and the second person must arrive with a warning.
#
#   A1  the first pairing writes one human row, with the telegram id, AND links it;
#   A2  the id is the @username lowercased when the profile read gives one;
#   A3  ... and `tg-<id>` when it does not — a complete record, not a failure;
#   A4  the same person paired to a second agent gains an AGENT, not a second row;
#   A5  a slug already held by a DIFFERENT telegram id falls back instead of
#       overwriting that person's identity;
#   A6  the 1 -> 2 write WARNS, naming the consequence (gates held, not sent);
#   A7  the link REPLACES — one agent, one human owner (`human link`'s rule);
#   A8  an unusable store is a no-op, not a failed pairing (best-effort, like
#       _operator_record beside it);
#   A9  a malformed sender id writes nothing;
#   A10 a person pre-added BY NAME with no telegram id yet is ADOPTED when they
#       pair — one row, slug kept, hand-written name intact (the only path that
#       reaches the display-name COALESCE, and the reason it is there);
#   A11 ... and once fully on record, a later pairing touches only the agent list;
#   B1  `_create_human_telegram_id` reads a known person and is empty otherwise;
#   B2  `_create_human_link` links, replaces, and reports failure for an unknown
#       person by exit status instead of killing the process;
#   B3  STRUCTURAL — `--human=` is parsed, its allowFrom seed is ADDITIVE (a
#       union, never an assignment: naming a colleague must not evict the
#       operator), and an unknown person is REFUSED before anything is created;
#   B4  STRUCTURAL — the link is attempted only AFTER the agent exists, so a
#       failed create leaves no dangling ownership row;
#   C1  THE SAFETY ARM — with exactly one human on record and NO links anywhere,
#       a gate still resolves to that person: a first pairing cannot make gate
#       delivery go dark;
#   C2  ... and with two, it does not. That is the threshold A6 announces;
#   C3  CONTROL — zero rows: the registry reads inactive and the pre-DIVE-3342
#       path stands, byte for byte (DIVE-3342's zero-rows contract).
#
# Isolation: source src/ directly, throwaway TASKS_DB, stubbed curl/audit, no
# tmux, no network, no root, no agent provisioning.
# Run: bash tests/human_at_pairing_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-human-at-pairing.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh task/routing.sh task/notify.sh \
         cmd_human.sh cmd_agent_pairing.sh cmd_agent_create.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f" 2>/dev/null
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init >/dev/null 2>&1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

reset_humans() { db "DELETE FROM human_agents; DELETE FROM humans;" >/dev/null 2>&1; }
hrows()  { db "SELECT COUNT(*) FROM humans;"; }
hid_of() { db "SELECT COALESCE(id,'') FROM humans WHERE telegram_id=$(sqlq "$1") LIMIT 1;"; }
links()  { db "SELECT COALESCE(group_concat(human_id||':'||agent, ','),'') FROM (SELECT human_id, agent FROM human_agents ORDER BY agent, human_id);"; }
dname()  { db "SELECT COALESCE(display_name,'(null)') FROM humans WHERE id=$(sqlq "$1");"; }

audit_log() { :; }          # the audit sink is not what this grades
# The profile read is ONE getChat through the agent's own bot token. Stubbed so
# the arms are deterministic and offline; $CURL_JSON is the canned body and an
# empty one stands for "the lookup failed", which is arm A3.
CURL_JSON=''
curl() { [[ -n "$CURL_JSON" ]] && printf '%s' "$CURL_JSON"; return 0; }

# =============================================================================
# A) the write at pairing approval
# =============================================================================
reset_humans
CURL_JSON='{"ok":true,"result":{"id":1234567890,"username":"Lodar","first_name":"Mark","last_name":"U"}}'
_pair_record_human dev 1234567890 1234567890 tok:en >"$TMP/a1.out" 2>&1
A1H=$(hrows); A1ID=$(hid_of 1234567890); A1L=$(links)
[[ "$A1H" == "1" && "$A1ID" == "lodar" && "$A1L" == "lodar:dev" ]] \
  && ok_t "A1 the first pairing writes one human row with the telegram id AND links the agent" \
  || bad_t "A1 the first pairing did not record a linked person" "rows=$A1H id='$A1ID' links='$A1L'"
[[ "$(dname lodar)" == "Mark U" ]] \
  && ok_t "A2 the id is the @username lowercased and the display name comes from the profile" \
  || bad_t "A2 profile fields were not recorded" "id='$A1ID' name='$(dname lodar)'"

reset_humans
CURL_JSON=''
_pair_record_human dev 1234567890 1234567890 tok:en >/dev/null 2>&1
A3ID=$(hid_of 1234567890)
[[ "$A3ID" == "tg-1234567890" && "$(hrows)" == "1" && "$(links)" == "tg-1234567890:dev" ]] \
  && ok_t "A3 a failed profile read still yields a complete, linked record (tg-<id>)" \
  || bad_t "A3 no record without a profile read" "id='$A3ID' rows=$(hrows) links='$(links)'"

reset_humans
CURL_JSON='{"ok":true,"result":{"id":1234567890,"username":"lodar","first_name":"Mark"}}'
_pair_record_human dev  1234567890 1234567890 tok:en >/dev/null 2>&1
_pair_record_human ops  1234567890 1234567890 tok:en >/dev/null 2>&1
[[ "$(hrows)" == "1" && "$(links)" == "lodar:dev,lodar:ops" ]] \
  && ok_t "A4 the same person on a second agent gains an AGENT, not a second identity" \
  || bad_t "A4 a second pairing minted a duplicate person" "rows=$(hrows) links='$(links)'"

# A5 the slug is already somebody else's. Never overwrite an identity: fall back
# to the id that cannot collide.
reset_humans
db "INSERT INTO humans (id, telegram_id, display_name) VALUES ('lodar','1111111111','The First Lodar');" >/dev/null 2>&1
CURL_JSON='{"ok":true,"result":{"id":2222222222,"username":"lodar","first_name":"Other"}}'
_pair_record_human dev 2222222222 2222222222 tok:en >/dev/null 2>&1
A5ID=$(hid_of 2222222222)
[[ "$A5ID" == "tg-2222222222" && "$(dname lodar)" == "The First Lodar" \
   && "$(db "SELECT telegram_id FROM humans WHERE id='lodar';")" == "1111111111" ]] \
  && ok_t "A5 a taken slug falls back instead of overwriting another person's identity" \
  || bad_t "A5 the second person overwrote the first" "id='$A5ID' first='$(dname lodar)'/$(db "SELECT telegram_id FROM humans WHERE id='lodar';")"

# A6 THE THRESHOLD. One -> two is the only write that changes gate delivery's
# shape, and it must say so.
reset_humans
CURL_JSON=''
_pair_record_human dev 1234567890 1234567890 tok:en >/dev/null 2>&1
_pair_record_human ops 1234567891 1234567891 tok:en >"$TMP/a6.out" 2>&1
A6=$(cat "$TMP/a6.out")
[[ "$(hrows)" == "2" ]] && [[ "$A6" == *TWO* || "$A6" == *"two people"* ]] && [[ "$A6" == *HELD* || "$A6" == *held* ]] \
  && ok_t "A6 the second person arrives with a warning that names the consequence" \
  || bad_t "A6 the 1->2 threshold was crossed in silence" "rows=$(hrows) out='$A6'"

# A7 one agent, one owner.
reset_humans
CURL_JSON=''
_pair_record_human dev 1234567890 1234567890 tok:en >/dev/null 2>&1
_pair_record_human dev 1234567891 1234567891 tok:en >/dev/null 2>&1
[[ "$(links)" == "tg-1234567891:dev" ]] \
  && ok_t "A7 re-pairing an agent to a new person REPLACES the ownership link" \
  || bad_t "A7 two owners accumulated on one agent" "links='$(links)'"

# A8 best-effort. An unusable store must not turn a completed pairing into a
# failure — the same posture _operator_record takes beside it.
reset_humans
( TASKS_DB=/proc/self/definitely-not-writable/tasks.db TASKS_DIR=/proc/self/nope \
  _pair_record_human dev 1234567890 1234567890 tok:en >/dev/null 2>&1 )
A8=$?
(( A8 == 0 )) \
  && ok_t "A8 an unusable task store is a no-op, not a failed pairing" \
  || bad_t "A8 the bookkeeping write failed the pairing" "rc=$A8"

reset_humans
_pair_record_human dev "not-an-id" "not-an-id" tok:en >/dev/null 2>&1
[[ "$(hrows)" == "0" ]] \
  && ok_t "A9 a malformed sender id writes nothing" \
  || bad_t "A9 a malformed sender was recorded" "rows=$(hrows)"

# A10 THE ADOPTION CASE, and the only path that reaches the display-name
# COALESCE. An operator pre-registers a colleague by name — `human add luca
# --name="Luca R"` — with no telegram id yet, because they do not have one until
# that person pairs. When they do pair, the existing row is ADOPTED (its
# telegram id filled in, its slug kept) rather than a second `tg-<id>` identity
# being minted for the same person, and the hand-written name outlives the
# profile read. Written the other way round (a bare SET) the pairing would
# overwrite 'Luca R' with whatever Telegram returns.
reset_humans
db "INSERT INTO humans (id, display_name) VALUES ('luca','Luca R');" >/dev/null 2>&1
CURL_JSON='{"ok":true,"result":{"id":1234567891,"username":"luca","first_name":"whatever","last_name":"Telegram says"}}'
_pair_record_human dev 1234567891 1234567891 tok:en >/dev/null 2>&1
A10N=$(dname luca); A10T=$(db "SELECT COALESCE(telegram_id,'') FROM humans WHERE id='luca';")
[[ "$(hrows)" == "1" && "$A10T" == "1234567891" && "$A10N" == "Luca R" && "$(links)" == "luca:dev" ]] \
  && ok_t "A10 a person pre-added by name is ADOPTED at pairing and their hand-written name survives" \
  || bad_t "A10 the pre-added person was not adopted cleanly" "rows=$(hrows) tg='$A10T' name='$A10N' links='$(links)'"

# A11 and the converse: once someone is fully on record, a later pairing touches
# only their agent list, never their identity.
reset_humans
CURL_JSON='{"ok":true,"result":{"id":1234567890,"username":"lodar","first_name":"Wrong","last_name":"Name"}}'
_pair_record_human dev 1234567890 1234567890 tok:en >/dev/null 2>&1
db "UPDATE humans SET display_name='Mark (corrected)' WHERE id='lodar';" >/dev/null 2>&1
_pair_record_human ops 1234567890 1234567890 tok:en >/dev/null 2>&1
[[ "$(dname lodar)" == "Mark (corrected)" && "$(links)" == "lodar:dev,lodar:ops" ]] \
  && ok_t "A11 a re-pair adds the agent and leaves a corrected display name alone" \
  || bad_t "A11 the re-pair rewrote the identity" "name='$(dname lodar)' links='$(links)'"

# =============================================================================
# B) agent create --human=<id>
# =============================================================================
reset_humans
db "INSERT INTO humans (id, telegram_id, display_name) VALUES ('lodar','1234567890','Mark');" >/dev/null 2>&1
[[ "$(_create_human_telegram_id lodar)" == "1234567890" && -z "$(_create_human_telegram_id nobody)" ]] \
  && ok_t "B1 the create-side read resolves a known person and is empty for an unknown one" \
  || bad_t "B1 the create-side read is wrong" "known='$(_create_human_telegram_id lodar)' unknown='$(_create_human_telegram_id nobody)'"

_create_human_link lodar dev >/dev/null 2>&1; B2A=$?
db "INSERT INTO humans (id, telegram_id) VALUES ('luca','1234567891');" >/dev/null 2>&1
_create_human_link luca dev >/dev/null 2>&1
_create_human_link nobody dev >/dev/null 2>&1; B2C=$?
(( B2A == 0 )) && [[ "$(links)" == "luca:dev" ]] && (( B2C != 0 )) \
  && ok_t "B2 the create-side link replaces, and reports an unknown person by exit status" \
  || bad_t "B2 the create-side link is wrong" "ok=$B2A links='$(links)' unknown_rc=$B2C"

B3F=$(grep -c -- '--human=\*)' "$SRC/cmd_agent_create.sh")
B3U=$(grep -c 'telegram_allowed_users="${telegram_allowed_users:+${telegram_allowed_users},}${_hu_tg}"' "$SRC/cmd_agent_create.sh")
B3R=$(grep -c 'no person .\$human_id. with a telegram id on this box' "$SRC/cmd_agent_create.sh")
(( B3F == 1 && B3U == 1 && B3R == 1 )) \
  && ok_t "B3 the flag is parsed, its allowFrom seed is a UNION, and an unknown person is refused" \
  || bad_t "B3 create wiring is wrong" "flag=$B3F union=$B3U refusal=$B3R"

B4L=$(grep -n '_create_human_link "\$human_id" "\$name"' "$SRC/cmd_agent_create.sh" | head -1 | cut -d: -f1)
B4O=$(grep -n "ok \"agent '\\\$name' (type=\\\$type" "$SRC/cmd_agent_create.sh" | head -1 | cut -d: -f1)
B4S=$(grep -n 'agent_home_conflict_check "\$name"' "$SRC/cmd_agent_create.sh" | head -1 | cut -d: -f1)
[[ -n "$B4L" && -n "$B4O" && -n "$B4S" ]] && (( B4L > B4S && B4L < B4O )) \
  && ok_t "B4 the ownership link is attempted after the agent exists, before the success line" \
  || bad_t "B4 the link is not ordered after creation" "link=$B4L conflict_check=$B4S ok=$B4O"

# =============================================================================
# C) the registry threshold this row walks up to
# =============================================================================
# A gate row with NO human links anywhere: the state every box is in the moment
# the first pairing writes a row.
mk_gate_row() {
  db "DELETE FROM tasks;
      INSERT INTO tasks (id, ident, title, status, assignee, created_by, gate_filed_by, routed_reviewer)
      VALUES (900, 'DIVE-900', 'a gate', 'todo', 'dev', 'dev', 'dev', 'ops');" >/dev/null 2>&1
}
reset_humans; mk_gate_row
db "INSERT INTO humans (id, telegram_id) VALUES ('lodar','1234567890');" >/dev/null 2>&1
_human_gate_recipient 900 >/dev/null
[[ "$HUMAN_RECIPIENT_ID" == "lodar" && "$HUMAN_RECIPIENT_BASIS" == *"sole human"* ]] \
  && ok_t "C1 one human on record, nothing linked — a gate still resolves to them (the first pairing cannot go dark)" \
  || bad_t "C1 a one-person registry left a gate unresolved" "id='$HUMAN_RECIPIENT_ID' basis='$HUMAN_RECIPIENT_BASIS'"

db "INSERT INTO humans (id, telegram_id) VALUES ('luca','1234567891');" >/dev/null 2>&1
_human_gate_recipient 900 >/dev/null
[[ -z "$HUMAN_RECIPIENT_ID" ]] \
  && ok_t "C2 two on record and nothing linked — unresolved, which is exactly what A6 announces" \
  || bad_t "C2 a two-person registry guessed a recipient" "id='$HUMAN_RECIPIENT_ID' basis='$HUMAN_RECIPIENT_BASIS'"

reset_humans
_human_registry_active
(( $? != 0 )) \
  && ok_t "C3 [control] zero rows — the registry reads inactive and pre-DIVE-3342 delivery stands" \
  || bad_t "C3 an empty registry read as active" "rc=$?"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
(( FAIL == 0 ))
