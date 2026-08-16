# -------- 5dive task — inbox --------
#
# Split out of src/cmd_task.sh (DIVE-3278): the human inbox + gate-proof history: coordinator, inbox, inbox send, gate
# proof, clear-recs.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
# src/cmd_task.sh when the split tree is used (tests source src/cmd_task.sh).
# Function definitions only — never execute this file directly.
# DIVE-1568: expose the resolved org coordinator as a thin read-only verb so
# surfaces that must act on exactly ONE agent (the DIVE-1503 pinned needs-you
# banner) can gate themselves instead of every paired agent pinning the same
# reminder into the founder's DM. Pure wrapper over _task_resolve_coordinator
# (DIVE-333): the sole role='coordinator', else the lone org root, else empty
# (ambiguous multi-root / no org) — callers MUST treat empty as "nobody pins".
cmd_task_coordinator() {
  tasks_db_init
  [[ $# -eq 0 ]] || fail "$E_USAGE" "coordinator takes no positional args"
  local who; who=$(_task_resolve_coordinator)
  if (( JSON_MODE )); then
    ok "" '{coordinator: $c}' --arg c "$who"
  else
    [[ -n "$who" ]] && echo "$who" || echo "(no coordinator resolved)"
  fi
}

# --- DIVE-3267: the human-gate predicate, in ONE place, for TWO call sites ------
#
# `cmd_task_inbox` owns the answer to "is this gate waiting on a HUMAN?". It is the
# only place that predicate is evaluated, and these two functions exist so that
# staying true stays cheap: `task ls --json` needs the SAME answer (to partition its
# "Needs you" section) and must not restate the rule to get it.
#
# THIS IS THE FIX FOR THE BUG THAT KEEPS RECURRING, SO READ THE SHAPE BEFORE
# EDITING. DIVE-3224: the telegram plugin's /inbox filtered on `need_type` alone —
# "has an unanswered gate", not "needs a human" — and showed the founder 12 gates of
# which 3 were his, each with a tap-to-apply button on a question routed to an agent
# seat. DIVE-3267: the SAME wrong predicate was live one command over, in /task's
# "Needs you" section, in all SIX plugin forks, with a comment above it asserting the
# premise as justification. Both copies existed because this predicate was reachable
# only by re-deriving it.
#
# So the contract is: **export the VERDICT, never the INPUTS.** `needs_human` on
# `task ls --json` is the RESULT of the one evaluation below. Exporting
# `routed_reviewer` / `needs_capability` so a consumer can rebuild the rule is the
# forbidden move — that is the second copy, and it drifts: the access clause
# (DIVE-3228) landed the morning after DIVE-3224 was written, so a plugin-side copy
# authored the day before was already wrong by the time it shipped.
#
# And the way to get THIS wrong is to paste the string into the `ls` query instead of
# calling this. Then there are two copies inside the fix for two copies. Both call
# sites go through here; `tests/task_needs_human_parity_unit.sh` asserts the two views
# return the identical ident set, and asserts at source level that the disjunction
# appears exactly once in this file.
_task_gate_open_pred() {
  printf '%s' "need_type IS NOT NULL AND need_answered_at IS NULL AND status NOT IN ('done','cancelled')"
}
_task_human_gate_pred() {
  printf '%s' "( COALESCE(routed_reviewer,'') = ''
          OR CAST(COALESCE(NULLIF(tier,''),'2') AS INTEGER) >= 2
          OR COALESCE(needs_capability,'') != '' )
    AND NOT ( COALESCE(need_type,'') = 'access'
              AND COALESCE(routed_reviewer,'') != ''
              AND COALESCE(floor_provenance,'') = 'axis=type-default'
              AND COALESCE(needs_capability,'') = '' )"
}

# ── DIVE-3474 arm 2 — the ROUTED-GATE QUEUE ──────────────────────────────────
#
# The counterpart of the human `inbox`, and it exists because arm 2 stops the
# file-time a2a ping: a gate the reviewer is never pinged about has to be
# FINDABLE, or the change trades an interrupt for a lost decision. This is the
# surface a routed reviewer reads on its next natural wake.
#
# ONE PREDICATE, called — never pasted (the rule the human predicate above states
# and `tests/task_needs_human_parity_unit.sh` enforces). And it is the VERDICT
# surface: a consumer asks "what may I clear" and gets rows, rather than being
# handed `routed_reviewer` and left to rebuild the rule — the second copy that
# drifted the morning DIVE-3228 landed.
#
# The rows carry every field the decision needs — ask, options, recommend, filer,
# age, urgency and the exact answer command — for the same reason: a view that
# withholds one field makes its consumer go and re-derive the whole thing, and
# whatever it re-derives is the copy that goes stale.
_task_agent_gate_pred() { # <agent>
  printf '%s' "$(_task_gate_open_pred)
    AND COALESCE(routed_reviewer,'') = $(sqlq "${1:-}")
    AND CAST(COALESCE(NULLIF(tier,''),'2') AS INTEGER) < 2"
}

cmd_task_queue() {
  tasks_db_init
  local who="" json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --for=*) who="${1#*=}" ;;
      --json)  json=1; JSON_MODE=1 ;;
      -h|--help)
        printf 'usage: 5dive task queue [--for=<agent>] [--json]\n\n  Gates ROUTED TO YOU and still unanswered — filed without waking your\n  window (DIVE-3474). Answer one with: 5dive task answer <ident> --value="<choice>"\n'
        return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "unexpected arg: $1 (task queue takes no positional args)" ;;
    esac
    shift
  done
  if [[ -z "$who" ]]; then task_actor_claim ""; who="$ACTOR_BOARD"; fi
  local pred; pred=$(_task_agent_gate_pred "$who")

  if (( json )); then
    local rows
    rows=$(db "SELECT ident||x'1f'||COALESCE(need_type,'')||x'1f'||COALESCE(tier,'')||x'1f'||COALESCE(gate_filed_by,created_by,'')||x'1f'||COALESCE(gate_urgent,0)||x'1f'||CAST((julianday('now')-julianday(COALESCE(need_asked_at,updated_at,created_at)))*24 AS INT)||x'1f'||COALESCE(need_options,'')||x'1f'||COALESCE(recommend,'')||x'1f'||replace(COALESCE(ask,''),x'0a',' ')
               FROM tasks WHERE ${pred} ORDER BY COALESCE(gate_urgent,0) DESC, COALESCE(need_asked_at,updated_at,created_at);" 2>/dev/null || printf '')
    local out="[]" line
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      local id ty ti fb ur ag op rc ak rest
      id="${line%%$'\x1f'*}"; rest="${line#*$'\x1f'}"
      ty="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
      ti="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
      fb="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
      ur="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
      ag="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
      op="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
      rc="${rest%%$'\x1f'*}"; ak="${rest#*$'\x1f'}"
      out=$(jq -cn --argjson a "$out" --arg id "$id" --arg ty "$ty" --arg ti "$ti" --arg fb "$fb" \
        --arg ur "$ur" --arg ag "$ag" --arg op "$op" --arg rc "$rc" --arg ak "$ak" \
        '$a + [{ident:$id, need_type:$ty, tier:(($ti|select(length>0)|tonumber?) // null), filed_by:$fb,
                urgent:($ur=="1"), age_hours:(($ag|tonumber?) // 0),
                options:(($op|select(length>0)) // null), recommend:(($rc|select(length>0)) // null),
                ask:$ak, answer_cmd:("5dive task answer "+$id+" --value=<choice>")}]' 2>/dev/null) || out="$out"
    done <<<"$rows"
    printf '%s\n' "$(jq -cn --argjson q "$out" --arg w "$who" '{ok:true, data:{reviewer:$w, count:($q|length), gates:$q}}' 2>/dev/null)"
    return 0
  fi

  local n; n=$(db "SELECT COUNT(*) FROM tasks WHERE ${pred};" 2>/dev/null || printf '0')
  if [[ "${n:-0}" == "0" ]]; then
    printf '%s: no gates routed to you are waiting.\n' "$who"
    return 0
  fi
  printf '%s gate(s) routed to %s and unanswered — filed WITHOUT waking your window (DIVE-3474):\n\n' "$n" "$who"
  db "SELECT '  ['||ident||'] '||need_type||CASE WHEN COALESCE(gate_urgent,0)=1 THEN ' URGENT' ELSE '' END
             ||'  (from '||COALESCE(gate_filed_by,created_by,'?')||', '
             ||CAST((julianday('now')-julianday(COALESCE(need_asked_at,updated_at,created_at)))*24 AS INT)||'h ago)'||x'0a'
             ||'    ask:       '||replace(COALESCE(ask,''),x'0a',' ')||x'0a'
             ||CASE WHEN COALESCE(need_options,'')!='' THEN '    options:   '||need_options||x'0a' ELSE '' END
             ||CASE WHEN COALESCE(recommend,'')!='' THEN '    recommends: '||recommend||x'0a' ELSE '' END
             ||'    answer:    5dive task answer '||ident||' --value=\"<choice>\"'||x'0a'
        FROM tasks WHERE ${pred} ORDER BY COALESCE(gate_urgent,0) DESC, COALESCE(need_asked_at,updated_at,created_at);" 2>/dev/null || true
  return 0
}

cmd_task_inbox() {
  tasks_db_init
  local send=0 channel_proof=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --send)            send=1 ;;
      --channel-proof=*) channel_proof="${1#*=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "unexpected arg: $1 (inbox takes no positional args)" ;;
    esac
    shift
  done
  # A pending gate, decoupled from the overloaded `status` (a task can be both
  # human-gated and blocked-by another task): need set, not yet answered. We
  # still exclude TERMINAL statuses (done/cancelled) — a closed task waits on
  # no one, so a lingering unanswered gate must not leak into the human inbox.
  local open_where; open_where=$(_task_gate_open_pred)
  # DIVE-3117 part 2: this view is "what is waiting on a HUMAN", and until now it
  # listed every open gate. A gate with `routed_reviewer` set is waiting on an
  # AGENT seat — the org lead, or a designated reviewer — and `task answer`'s
  # designated-reviewer exception is what clears it. Listing it here put a question
  # already addressed to someone else on lodar's plate, and it is exactly why the
  # ROUTING fix (part 1) took not one gate off that plate: routing decides which
  # agent is NAMED on a gate, this clause decides who is SHOWN it. Two independent
  # defects, one symptom.
  #
  # THREE ESCAPES, each a class a human genuinely still owns:
  #   * routed_reviewer empty — nothing was routed. The human's gate by default,
  #     and also where an UNROUTABLE gate lands (no lead resolves, `--needs` a
  #     human capability, a tier-2 filing that never routes at all).
  #   * tier >= 2 — a hard gate: money, irreversible, a secret, a human tap. Note
  #     DIVE-1437 clears routed_reviewer when a lead cannot answer one, so a
  #     stalled hard gate comes BACK to this list rather than vanishing from it;
  #     that escalation is the return path this filter relies on existing.
  #   * needs_capability set — a declared human capability (DIVE-2241). Today that
  #     already implies BOTH tier 2 and _routable=0, so this disjunct is redundant
  #     by consequence. It is stated anyway because the floor making it true lives
  #     ~2400 lines away in cmd_task_need, and if that floor ever moved the failure
  #     mode would be a human losing sight of a human-capability gate, silently.
  # An UNKNOWN tier reads as 2 and stays VISIBLE — the fail-safe direction here,
  # since showing a human one gate too many is recoverable and hiding one is the
  # defect being fixed. `NULLIF(tier,'')` and not `clear-recs`'s bare COALESCE:
  # `tier` is INTEGER-affinity but nullable, and SQLite stores an empty string as
  # TEXT '' rather than converting it, so COALESCE alone passes '' straight to
  # CAST, which yields 0. Measured — the arm for this went red before the NULLIF.
  # (clear-recs has the same gap with the opposite sign: there '' reads as tier 0
  # and becomes ELIGIBLE for a blanket clear. Out of scope here, noted on the row.)
  # DIVE-3228: the `tier >= 2` escape used to capture a ROUTED `access` gate that a
  # lead can now actually clear — so lodar was shown a question already addressed to
  # somebody else, which is the complaint this row exists for. Same defect as
  # DIVE-3117 part 2 above, one type further along.
  #
  # STRICTER THAN THE ANSWER-SIDE PREDICATE, ON PURPOSE, AND THAT IS THE WHOLE
  # DESIGN NOTE. `_gate_access_lead_clearable` is bash and cannot run inside this
  # SELECT, and restating it in SQL would be the two-copies-that-can-disagree
  # problem DIVE-3171 names. So this clause is deliberately a SUBSET of it: it
  # additionally requires `needs_capability` to be EMPTY, where the bash predicate
  # tolerates an UNRECOGNISED capability. The two can therefore disagree in exactly
  # one direction — a gate the lead may clear can still be SHOWN here — and never
  # in the other. Showing a human one gate too many is recoverable; hiding one that
  # no agent will clear is the defect this whole view exists to prevent, and it is
  # the same fail-safe direction the UNKNOWN-tier note below relies on.
  # DIVE-3228: ONE predicate, used by both the view and the withheld-count below.
  # It used to be written out twice — once here and once, negated by hand, in
  # `routed_n` — and adding the access clause to only the first would have made the
  # count under-report exactly the gates this change withholds. A fix that records
  # only its successes leaves the next regression with nothing to count, and a
  # hand-maintained inverse is the form that rots silently, since both halves still
  # run and neither errors.
  local human_pred; human_pred=$(_task_human_gate_pred)
  local human_where="${open_where} AND ${human_pred}"
  local where="$human_where"
  local order="ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, created_at"
  if (( send )); then
    _task_inbox_send "$channel_proof" "$where" "$order"
    return
  fi
  [[ -z "$channel_proof" ]] || fail "$E_USAGE" "--channel-proof only applies with --send"
  # What the filter WITHHELD, counted rather than merely not-shown. Without this a
  # newly-quiet inbox is indistinguishable from a fleet with no open gates — the
  # same "an unnotified gate reads exactly like a notified one" shape this rail has
  # been burned by before. It is a count and a pointer, never the asks themselves.
  local routed_n; routed_n=$(db "SELECT COUNT(*) FROM tasks WHERE ${open_where} AND NOT ( ${human_pred} );")
  routed_n="${routed_n:-0}"
  if (( JSON_MODE )); then
    local rows
    # DIVE-3224: `tier` is exported so a CONSUMER never has to re-derive the
    # human/agent split to decide which gate gets a tap button. The telegram
    # plugin's /inbox sourced `task ls --json` purely because this view withheld
    # `tier` (its own comment says so), and rebuilding the "needs a human" filter
    # plugin-side re-derived it wrong: it filtered on `need_type` alone, so the
    # founder was shown all 12 open gates — 9 of them routed to agent seats, each
    # with a ✅ apply-the-rec button on a question addressed to somebody else.
    # Exporting the one missing field is what lets the predicate above stay the
    # SINGLE copy. Do NOT answer the next such request by exporting
    # `routed_reviewer`/`needs_capability` here — that invites a second copy of
    # the rule, which is the DIVE-3171 two-copies-that-disagree shape and is the
    # exact defect this line closes.
    rows=$(dbfmt -json "SELECT id, ident, title, status, priority, assignee, created_by, parent_id, created_at, need_type, ask, need_options, recommend, tier, precedent_ref, need_answer, need_answered_at FROM tasks WHERE ${where} ${order};")
    [[ -n "$rows" ]] || rows="[]"
    # stdin, not --argjson — same ARG_MAX guard as `task ls`. (DIVE-222)
    # `routed_elsewhere` is additive under data{}; every existing consumer reads
    # data.inbox and is unaffected.
    printf '%s' "$rows" | jq -c --argjson r "$routed_n" '{ok:true, data:{inbox:., routed_elsewhere:$r}}'
  else
    local cnt; cnt=$(db "SELECT COUNT(*) FROM tasks WHERE ${where};")
    if [[ "$cnt" == "0" ]]; then
      echo "inbox empty — nothing waiting on a human."
    else
      dbfmt -box "SELECT ident, priority, need_type, COALESCE(assignee,'-') AS owner, COALESCE(recommend,'-') AS recommend, COALESCE((SELECT ident FROM tasks p WHERE p.id=tasks.precedent_ref),'-') AS precedent, ask FROM tasks WHERE ${where} ${order};"
    fi
    if (( routed_n > 0 )); then
      echo "(${routed_n} more open gate(s) routed to an agent seat — not yours to answer: 5dive task ls --status=blocked)"
    fi
  fi
}

# DIVE-1499: on-demand owner digest of the pending-gate inbox as ONE message
# with WORKING tap buttons for every gate type — including approval/secret/
# manual. The per-gate DIVE-916 human nonce is deliberately NOT exposed in
# `inbox --json`: that output is agent-readable, and a readable nonce is an
# agent-forgeable human-proof — the exact hole DIVE-950 closed. Instead this
# root-side path mints a FRESH nonce per hard gate, embeds it ONLY in Telegram
# callback_data, and rotates the stored hash after a confirmed send — the same
# contract as `task need` and the heartbeat re-nag batch. Stdout carries counts
# and message ids, never a nonce. The telegram plugin's /inbox flow shells this
# verb (passing the requesting chat as --channel-proof) instead of composing
# tier-2 buttons itself.
_task_inbox_send() {
  local channel_proof="$1" where="$2" order="$3"
  require_root "task inbox --send"
  # DIVE-1506: fail closed — an /inbox digest may reach the paired human ONLY from the prod DB.
  # A fixture/e2e DB (isolated TASKS_DB) must never DM real gates; refuse loudly, don't send.
  # (The send itself is also guarded in _task_send_owner; this gives the command a clear message.)
  _task_human_send_allowed \
    || fail "$E_VALIDATION" "refused: inbox --send — the active task DB is not the prod DB; set FIVEDIVE_PROD_TASKS_DB if this IS prod"
  # When the plugin relays a human /inbox request it passes the requester's
  # chat_id; verify it against access.json allowFrom before sending. Absent
  # proof = an operator/root invocation on the box.
  if [[ -n "$channel_proof" ]]; then
    _gate_channel_proof_ok "$channel_proof" \
      || fail "$E_AUTH_REQUIRED" "channel-proof did not verify — the chat id is not in this bot's access.json allowFrom (paired-human DMs)"
  fi
  _task_owner_channel || fail "$E_AUTH_REQUIRED" "no paired owner channel (connector token / access.json missing)"

  local cap=10 total
  total=$(db "SELECT COUNT(*) FROM tasks WHERE ${where};")
  if [[ "${total:-0}" == "0" ]]; then
    ok "inbox empty — nothing to send" '{sent:false, gates:0}'
    return
  fi

  # DIVE-2712 (lodar, 2026-08-04): ONE MESSAGE PER GATE, not one digest.
  #
  # It used to accumulate every gate into one message with one merged keyboard.
  # Two complaints, one root: answering ANY gate called _task_gate_retire_buttons,
  # which edits the message that delivered it — and with every gate sharing one
  # message, Telegram's keyboard-removal took ALL of them, so picking a second gate
  # meant running /inbox again. The digest was also unreadable once several gates
  # were open.
  #
  # Sending one message per gate fixes both AND DELETES THE HARD PART. The
  # alternative — keep the digest and subtract only the answered gate's rows —
  # needs the ORIGINAL button nonces to survive the edit, and only their SHA is
  # persisted (human_nonce_hash), so the surviving rows would have to be re-minted
  # and their hashes rotated, which silently kills those same gates' buttons on
  # every OTHER message that delivered them. One gate per message makes the
  # existing retire path correct BY CONSTRUCTION: the message carries exactly one
  # gate, so removing its keyboard can affect nothing else.
  #
  # THE COST IS THE PUSH COUNT, and it is paid rather than ignored: N gates would
  # be N buzzes. The first message pings, every one after it is SILENT
  # (FIVEDIVE_NOTIFY_SILENT -> disable_notification), so the human gets one ping
  # and a readable stack.
  local id ident prio ntype options recommend gtier ask nonce="" markup=""
  local gate_text sent=0 failed=0 first_sent=0 all_ids="" all_mids="" _mint_n=0
  local _prev_silent="${FIVEDIVE_NOTIFY_SILENT:-}"
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS=$'\x1f' read -r id ident prio ntype options recommend gtier ask <<<"$row"
    [[ -n "$id" && -n "$ident" ]] || continue
    gate_text="🗂 Gate waiting on you:"$'\n\n'"[${ident}] ${ntype}, ${prio} — ${ask} /task_${id}"
    [[ -n "$recommend" ]] && gate_text+=$'\n'"✅ Recommended: ${recommend}"
    [[ -n "$options" ]]   && gate_text+=$'\n'"Options: ${options}"
    gate_text+=$'\n\n'"Tap a button, open the /task link, or answer from the dashboard."
    # DIVE-2356: hard-human TYPE **or** tier>=2. Unchanged by the split.
    nonce=""; _mint_n=0
    case "$ntype" in approval|secret|manual) _mint_n=1 ;; esac
    [[ "${gtier:-}" =~ ^[0-9]+$ ]] && (( gtier >= 2 )) && _mint_n=1
    (( _mint_n )) && nonce=$(_human_nonce_mint)
    markup=$(_task_gate_reply_markup "$id" "$ntype" "$options" "$recommend" "$nonce" "$TASK_CH_TYPE" "$ident")
    # DIVE-2818: the high-stakes reply-to-clear prompt reaches the BATCH re-send
    # too. DIVE-1490's rule applies unchanged — the initial alert and every re-nag
    # share one renderer so the affordance cannot drift between first delivery and
    # the reminders — and a re-nag is exactly when a gate has sat long enough for
    # the button to have gone stale, which is the case the recovery path is for.
    #
    # Reads `markup`, hence the mint/markup lines now sitting above it (DIVE-2824
    # iteration 3): since the tap-primary re-scope the copy speaks about the
    # button and is withheld where there is none. Same reorder as the single-gate
    # site, and for the same reason — independent statements, one renderer.
    if [[ "$TASK_CH_TYPE" == "claude" ]] && _task_gate_high_stakes "$id"; then
      local _batch_cta; _batch_cta=$(_task_gate_reply_cta "$ident" "$ntype" "$options" "$recommend" "$markup")
      [[ -n "$_batch_cta" ]] && gate_text+=$'\n\n'"$_batch_cta"
    fi
    # First message pings; the rest arrive silently.
    if (( first_sent )); then export FIVEDIVE_NOTIFY_SILENT=1; fi
    # DIVE-3342: per-gate, so each gate reaches ITS owner (or nobody) — the
    # per-gate loop this site already had is what makes that free.
    _task_send_gate_owner "$gate_text" "$markup" "$id"
    if [[ "${TASK_SEND_DELIVERED:-0}" == "1" ]]; then
      sent=$(( sent + 1 )); first_sent=1
      all_ids+="${all_ids:+,}${id}"
      [[ -n "${TASK_SEND_MESSAGE_IDS:-}" ]] && all_mids+="${all_mids:+,}${TASK_SEND_MESSAGE_IDS}"
      # Rotate this gate's hash ONLY after ITS OWN confirmed receipt. Per-gate now,
      # which is strictly better than the old batch rotation: a partial delivery no
      # longer rotates hashes for gates whose message never landed.
      if [[ -n "$nonce" ]]; then
        db "UPDATE tasks SET human_nonce_hash=$(sqlq "$(_human_nonce_sha "$nonce")")
            WHERE id=${id} AND need_answered_at IS NULL;" 2>/dev/null || true
      fi
    else
      failed=$(( failed + 1 ))
    fi
  done < <(db "SELECT id||x'1f'||ident||x'1f'||priority||x'1f'||need_type||x'1f'||COALESCE(need_options,'')||x'1f'||COALESCE(recommend,'')||x'1f'||COALESCE(tier,'')||x'1f'||substr(replace(COALESCE(ask,''),x'0a',' '),1,240)
               FROM tasks WHERE ${where} ${order} LIMIT ${cap};")
  if (( total > cap )) && (( sent > 0 )); then
    export FIVEDIVE_NOTIFY_SILENT=1
    # DIVE-3342: the tail carries no rows, so it has nobody to resolve from —
    # address it to whoever just received the batch rather than to the allowlist.
    _task_send_gate_owner "…and $(( total - cap )) more gate(s) — 5dive task inbox on the box, or the dashboard." "" "" "${TASK_GATE_LAST_OWNER:-}"
  fi
  if [[ -n "$_prev_silent" ]]; then export FIVEDIVE_NOTIFY_SILENT="$_prev_silent"; else unset FIVEDIVE_NOTIFY_SILENT; fi
  TASK_SEND_MESSAGE_IDS="$all_mids"
  if (( sent > 0 )); then
    # DIVE-2054: DELIBERATELY UNFENCED, same shape as "task clear-recs".
    audit_log "task inbox send" "ok" 0 -- \
      "gates=${sent}/${total}" "delivery=per-gate" "failed=${failed}" \
      "chat_proof=${channel_proof:-none}" "message_id=${all_mids:-none}"
    ok "inbox sent (${sent}/${total} gates, one message each)" \
      '{sent:true, gates:($g|tonumber), total:($t|tonumber), failed:($f|tonumber), message_ids:$m}' \
      --arg g "$sent" --arg t "$total" --arg f "$failed" --arg m "${all_mids:-}"
  else
    # DIVE-2054: DELIBERATELY UNFENCED, same exemption as the "ok" branch above —
    # chat_proof is the proof a real channel was (or was not) hit for this send, and
    # a fixture store must not be able to suppress that record.
    audit_log "task inbox send" "error" 1 -- \
      "gates=0/${total}" "delivery=per-gate" "failed=${failed}" "chat_proof=${channel_proof:-none}"
    fail "$E_GENERIC" "inbox delivery unconfirmed — no gate message landed, so nonce hashes are left unrotated and earlier alert buttons remain valid (DIVE-2712: per-gate send)"
  fi
}

# DIVE-3191: THE CURRENT GATE IS NOT THE WHOLE RECORD.
#
# `gate-proof verify` read `tasks` only, and `tasks` holds exactly ONE gate per row.
# The standard unblock for an unsigned lead clear is to RE-FILE the gate and have a
# signer clear it — which retires the unsigned closure into `gate_history`. So the
# workaround that unblocks the push also ERASES it from the tool you would audit
# with: the row reads an unqualified green forever, with nothing saying a prior
# clear existed. Measured on DIVE-3170/3136/3113/2808 (DIVE-3176), which is how a
# proposed sweep would have reported the store healthy.
#
# No new store is needed. `gate_history` (lib/tasks_db.sh) already carries
# need_answered_at / need_answered_by / need_answered_uid / need_answer_sig, and
# `_gate_closure_verify` is keyed on the task id plus the closure FACTS — so an
# archived signature re-verifies against the archived facts. A displaced closure
# that WAS signed therefore reports `valid`, not merely `present`.
#
# Two boundaries this must respect, or it reintroduces the defect one level down:
#   1. A zero count is only CLEAN where the archive covers the row's whole life.
#      `gate_history_coverage` (DIVE-2133) is an evidence boundary, not a count —
#      out of coverage, zero means UNKNOWN and the green stays qualified.
#   2. A gate retired with NO answer (withdrawn / parked / loop-ceiling) is not a
#      closure. Counting those would over-accuse, which is the mirror of the
#      under-count this fixes:
#      community/wiki/a-current-gate-only-read-undercounts-the-census-and-over-accuses-the-ships.md
#
# Sets for the caller: _GPH_VERDICT _GPH_ARCHIVED _GPH_CLOSED _GPH_UNSIGNED
# _GPH_INVALID _GPH_VALID _GPH_STATE _GPH_BASIS _GPH_COVERAGE _GPH_TEXT _GPH_TRAILER
_gate_proof_history_scan() {
  local vid="$1"
  IFS='|' read -r _GPH_ARCHIVED _GPH_COVERAGE _GPH_STATE _GPH_BASIS < <(_gate_history_facts "$vid")
  _GPH_CLOSED=0; _GPH_UNSIGNED=0; _GPH_INVALID=0; _GPH_VALID=0; _GPH_TEXT=""; _GPH_TRAILER=""
  local _row _seq _t _a _by _at _uid _sig _ret _retat _vfs _stat _lines=""
  while IFS= read -r _row; do
    [[ -n "$_row" ]] || continue
    IFS=$'\x1f' read -r _seq _t _a _by _at _uid _sig _ret _retat <<<"$_row"
    # Boundary 2: no answer => it was displaced, never closed. Not a closure.
    [[ -n "$_at" ]] || continue
    _GPH_CLOSED=$(( _GPH_CLOSED + 1 ))
    # Mirror the live path exactly: a secret's answer is NOT in the signed payload.
    _vfs=""; [[ "$_t" != "secret" ]] && _vfs="$_a"
    if [[ -z "$_sig" ]]; then
      _GPH_UNSIGNED=$(( _GPH_UNSIGNED + 1 )); _stat=UNSIGNED
    elif _gate_closure_verify "$vid" "$_t" "$_vfs" "$_by" "$_at" "$_uid" "$_sig"; then
      _GPH_VALID=$(( _GPH_VALID + 1 )); _stat=valid
    else
      _GPH_INVALID=$(( _GPH_INVALID + 1 )); _stat=INVALID
    fi
    _lines+="  #${_seq} ${_t} ${_stat} — answered ${_at} by ${_by:-—}, retired ${_retat} (${_ret})"$'\n'
  done < <(db "SELECT id||x'1f'||COALESCE(need_type,'')||x'1f'||COALESCE(need_answer,'')||x'1f'||
      COALESCE(need_answered_by,'')||x'1f'||COALESCE(need_answered_at,'')||x'1f'||
      COALESCE(CAST(need_answered_uid AS TEXT),'')||x'1f'||COALESCE(need_answer_sig,'')||x'1f'||
      COALESCE(retired_by,'')||x'1f'||COALESCE(retired_at,'')
    FROM gate_history WHERE task_id=${vid} ORDER BY id;")
  if   (( _GPH_UNSIGNED > 0 )); then _GPH_VERDICT="SUPERSEDED-UNSIGNED"
  elif (( _GPH_INVALID  > 0 )); then _GPH_VERDICT="SUPERSEDED-INVALID"
  elif [[ "$_GPH_STATE" == complete ]]; then _GPH_VERDICT="clean"
  else _GPH_VERDICT="UNKNOWN"
  fi
  local _cov
  case "$_GPH_STATE" in
    complete) _cov="archive covers this row's whole life" ;;
    partial)  _cov="archive coverage begins ${_GPH_COVERAGE} (${_GPH_BASIS}), so a zero here cannot mean clean" ;;
    *)        _cov="archive coverage is NOT measured, so a zero here cannot mean clean" ;;
  esac
  case "$_GPH_VERDICT" in
    clean)
      _GPH_TEXT="history: clean — 0 superseded closures of ${_GPH_ARCHIVED} archived gate(s); ${_cov}"$'\n' ;;
    UNKNOWN)
      _GPH_TEXT="history: UNKNOWN — ${_GPH_CLOSED} superseded closure(s) of ${_GPH_ARCHIVED} archived gate(s), all signed and valid; ${_cov}"$'\n'"$_lines" ;;
    *)
      _GPH_TEXT="history: ${_GPH_VERDICT} — ${_GPH_CLOSED} superseded closure(s) of ${_GPH_ARCHIVED} archived gate(s): ${_GPH_UNSIGNED} UNSIGNED, ${_GPH_INVALID} INVALID, ${_GPH_VALID} valid; ${_cov}"$'\n'"$_lines" ;;
  esac
  if (( _GPH_UNSIGNED > 0 || _GPH_INVALID > 0 )); then
    _GPH_TRAILER=" — but its ARCHIVE holds ${_GPH_CLOSED} superseded closure(s), ${_GPH_UNSIGNED} unsigned and ${_GPH_INVALID} invalid; read them with '5dive task gate-history'"
  fi
}

# DIVE-519: `5dive gate-proof <id|DIVE-N> <approval|secret>` — root-only. Mints a
# human-origin proof token (RAW on stdout, never a --json envelope) that the
# trusted answer paths attach as --proof to clear an approval/secret gate: the
# Telegram plugin tap (mintGateProof shells here), the dashboard/shelld injector,
# and a human on the box (`task answer DIVE-N --proof=$(sudo 5dive gate-proof N approval)`).
# Subcommand `enforce on|off|status` toggles whether a missing/invalid proof is
# REJECTED (default off = audit-only) — see _gate_proof_enforced.
cmd_gate_proof() {
  # DIVE-756: root-only signer for the non-root answer path. Reads the canonical
  # closure payload on STDIN (so the human answer never enters argv) and prints
  # the HMAC raw. cmd_task_answer re-execs this over `sudo -n` when it isn't root.
  if [[ "${1:-}" == "sign" ]]; then
    require_root "gate-proof sign"
    tasks_db_init
    _gate_proof_ensure_key || fail "$E_GENERIC" "cannot provision gate-proof key (need root)"
    local _payload; _payload=$(cat)
    local _mac; _mac=$(_gate_proof_hmac "$_payload") || fail "$E_GENERIC" "failed to sign"
    printf '%s\n' "$_mac"
    return
  fi

  # DIVE-756: verify a stored closure signature. Root-only (needs the key). Recom-
  # putes the HMAC over the row's durable facts and reports signed/valid — a raw-
  # sqlite write that bypassed cmd_task_answer shows signed=absent or valid=false.
  # The detective half of the fix (enforcement of valid-or-reject is a later flip).
  if [[ "${1:-}" == "verify" ]]; then
    require_root "gate-proof verify"
    tasks_db_init
    local vref="${2:-}"
    [[ -n "$vref" ]] || fail "$E_USAGE" "usage: 5dive gate-proof verify <id|DIVE-N>"
    resolve_task_id "$vref"; local vid="$RESOLVED_TASK_ID" vident="$RESOLVED_TASK_IDENT"
    local _row; _row=$(db "SELECT
        COALESCE(need_type,'')||x'1f'||
        COALESCE(need_answer,'')||x'1f'||
        COALESCE(need_answered_by,'')||x'1f'||
        COALESCE(need_answered_at,'')||x'1f'||
        COALESCE(CAST(need_answered_uid AS TEXT),'')||x'1f'||
        COALESCE(need_answer_sig,'')
      FROM tasks WHERE id=${vid};")
    local _nt _na _nb _nat _nuid _nsig
    IFS=$'\x1f' read -r _nt _na _nb _nat _nuid _nsig <<<"$_row"
    # DIVE-3191: read the ARCHIVE before the early exit, because the row with no
    # current answered gate is the same defect one level down — "nothing to verify"
    # is not "nothing ever happened here".
    _gate_proof_history_scan "$vid"
    [[ -n "$_nt" && -n "$_nat" ]] || fail "$E_CONFLICT" "$vident has no answered gate to verify${_GPH_TRAILER}"
    local _vfs=""; [[ "$_nt" != "secret" ]] && _vfs="$_na"
    local _signed=absent _valid=false
    if [[ -n "$_nsig" ]]; then
      _signed=present
      _gate_closure_verify "$vid" "$_nt" "$_vfs" "$_nb" "$_nat" "$_nuid" "$_nsig" && _valid=true
    fi
    # DIVE-2054: the nonce/signature being verified is itself TASKS_DB state for
    # $vident (not an independent real-world channel/identity fact) — fenced.
    # DIVE-3191: the audit row carries the history verdict too, or the audit trail
    # inherits exactly the blind spot this change exists to close.
    _task_store_audit_log "gate-proof verify" "$([[ "$_valid" == true && "$_GPH_VERDICT" == clean ]] && echo ok || echo error)" 0 -- \
      "task=$vident" "type=$_nt" "signed=$_signed" "valid=$_valid" "uid=${_nuid:-}" "by=${_nb:-}" \
      "history=$_GPH_VERDICT" "superseded=$_GPH_CLOSED" "superseded_unsigned=$_GPH_UNSIGNED" \
      "superseded_invalid=$_GPH_INVALID" "coverage=$_GPH_STATE"
    if (( JSON_MODE )); then
      ok "gate-proof verify $vident: signed=$_signed valid=$_valid history=$_GPH_VERDICT" \
        '{ident:$i, signed:$s, valid:($v=="true"), uid:$u, by:$b,
          history:{verdict:$hv, superseded_closures:($hc|tonumber), unsigned:($hu|tonumber),
                   invalid:($hi|tonumber), valid:($hg|tonumber), coverage_state:$hst,
                   coverage_basis:$hbs,
                   coverage_started_at:(if $hcv=="" then null else $hcv end)}}' \
        --arg i "$vident" --arg s "$_signed" --arg v "$_valid" --arg u "${_nuid:-}" --arg b "${_nb:-}" \
        --arg hv "$_GPH_VERDICT" --arg hc "$_GPH_CLOSED" --arg hu "$_GPH_UNSIGNED" \
        --arg hi "$_GPH_INVALID" --arg hg "$_GPH_VALID" --arg hst "$_GPH_STATE" \
        --arg hbs "$_GPH_BASIS" --arg hcv "$_GPH_COVERAGE"
    else
      echo "ident:  $vident"; echo "signed: $_signed"; echo "valid:  $_valid"
      echo "uid:    ${_nuid:-—}"; echo "by:     ${_nb:-—}"
      printf '%s' "$_GPH_TEXT"
    fi
    return
  fi

  if [[ "${1:-}" == "enforce" ]]; then
    require_root "gate-proof enforce"
    local _ef; _ef=$(_gate_proof_enforce_file)
    case "${2:-status}" in
      on)  : > "$_ef"; chmod 0644 "$_ef" 2>/dev/null || true
           ok "gate-proof enforcement ON: approval/secret/manual answers now require human evidence (a valid --human-proof nonce or a non-agent SUDO_UID)" ;;
      off) # DIVE-2588: enforcement is now armed by EITHER sentinel, so removing only
           # the override path would print OFF while the default kept it ON — a status
           # line that disagrees with the predicate is how the flag got trusted in the
           # first place. Root asked for off; take both. (Still root-only: this widens
           # nothing an unprivileged caller can reach.)
           rm -f "$_ef" "${STATE_DIR}/gate-proof.enforce"
           ok "gate-proof enforcement OFF: audit-only; approval/secret/manual answers allowed without human evidence. NOTE the tier-2 human floor is NOT affected — since DIVE-2588 it is unconditional and no flag can lower it." ;;
      status)
           local _e _k _src
           _gate_proof_enforced && _e=on || _e=off
           [[ -s "$(_gate_proof_key_file)" ]] && _k=present || _k=absent
           # DIVE-2588: name WHICH sentinel armed it. "on" alone cannot tell an
           # operator that an env override is in play on this invocation.
           _src=none
           [[ -f "${STATE_DIR}/gate-proof.enforce" ]] && _src=default
           if [[ -n "${GATE_PROOF_ENFORCE:-}" && -f "$GATE_PROOF_ENFORCE" ]]; then
             [[ "$_src" == default ]] && _src=both || _src=env-override
           fi
           if (( JSON_MODE )); then
             ok "gate-proof: enforce=$_e key=$_k armed_by=$_src" \
               '{enforce:$e, key:$k, armedBy:$s, t2FloorUnconditional:true}' \
               --arg e "$_e" --arg k "$_k" --arg s "$_src"
           else
             echo "enforce: $_e"; echo "key: $_k"; echo "armed by: $_src"
             echo "tier-2 human floor: unconditional (DIVE-2588 — not switchable by this flag)"
           fi ;;
      *) fail "$E_USAGE" "usage: 5dive gate-proof enforce on|off|status" ;;
    esac
    return
  fi
  # DIVE-950: the `gate-proof <id> <type>` MINT path is REMOVED. The --proof token
  # it produced (evidence-form b) was agent-forgeable — `gate-proof` is require_root
  # only, so any agent could `sudo`-mint a valid token and self-clear a gate, no
  # higher a bar than the sudo it already had. Human evidence is now (a) the
  # per-gate --human-proof nonce (plugin tap / dashboard payload) or (c) a non-agent
  # SUDO_UID. `sign`/`verify`/`enforce` above remain (closure tamper-evidence +
  # the enforcement toggle). A stray mint caller gets a loud, AUDITED failure here
  # rather than a silent forge.
  require_root "gate-proof"
  # DIVE-2054: DELIBERATELY UNFENCED — store-identity fencing doesn't apply here at
  # all. This row carries no TASKS_DB-derived data (a constant + raw CLI args); it
  # is a bare record that a removed, forgeable command path was invoked at all.
  audit_log "gate-proof mint" "error" 1 -- "removed=DIVE-950" "args=${1:-} ${2:-}"
  fail "$E_USAGE" "gate-proof mint is removed — valid: gate-proof enforce on|off|status | verify <id> | sign"
}

# DIVE-1305: paired-human bulk-clear. When the paired human sends "go with recs"
# (or "approve DIVE-X") in their OWN verified DM, the telegram plugin — which has
# already matched the sender chat_id against access.json — shells this with the
# verified chat_id. We apply each eligible pending gate's --recommend as a HUMAN
# clear (reusing cmd_task_answer's provenance + closure-signature + loop-advance
# path via --channel-proof), so it is byte-identical to a per-gate human tap
# except one command clears many.
#
# Scope (lodar's DIVE-1305 decision, 2026-07-16): ONLY tier<2, agent-clearable
# gates. tier-2 hard gates (money/destructive/secret are floored there) are
# SKIPPED — they keep a deliberate per-gate button tap. We also skip lead-routed
# gates (routed_reviewer set): those clear via their designated lead, not the
# human's blanket channel. A gate with no --recommend is skipped (nothing to
# apply). The tier<2 + channel-proof enforcement lives in cmd_task_answer, so
# even a hand-crafted --only=<hard gate> can never be cleared here.
cmd_task_clear_recs() {
  tasks_db_init
  local channel_proof="" only="" from=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --channel-proof=*) channel_proof="${1#*=}" ;;
      --only=*)          only="${1#*=}" ;;
      --from=*)          from="${1#*=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "usage: 5dive task clear-recs --channel-proof=<chat_id> [--only=<id|DIVE-N>]" ;;
    esac
    shift
  done
  [[ -n "$channel_proof" ]] || fail "$E_USAGE" "--channel-proof=<chat_id> is required (the paired human's verified DM chat id)"
  # Verify the channel up front so a bad/forged chat id fails once, loudly, before
  # we touch any gate. Same allowFrom check cmd_task_answer re-runs per gate.
  _gate_channel_proof_ok "$channel_proof" \
    || fail "$E_AUTH_REQUIRED" "channel-proof did not verify — that chat id is not in this bot's access.json allowFrom"

  # Eligible pending gates: unanswered, blocked, tier<2, has a recommend, not
  # lead-routed. --only narrows to one row (still subject to every filter, so a
  # hard/ineligible target simply clears nothing and is reported).
  local only_sql=""
  if [[ -n "$only" ]]; then
    resolve_task_id "$only"; only_sql=" AND id=${RESOLVED_TASK_ID}"
  fi
  local rows
  rows=$(db "SELECT id FROM tasks
             WHERE need_type IS NOT NULL AND need_answered_at IS NULL
               AND status='blocked'
               AND CAST(COALESCE(tier,'2') AS INTEGER) < 2
               AND COALESCE(recommend,'') != ''
               AND COALESCE(routed_reviewer,'') = ''${only_sql}
             ORDER BY id;")

  local -a cleared=() cleared_recs=()
  local gid gident grec
  while IFS= read -r gid; do
    [[ -n "$gid" ]] || continue
    grec=$(db "SELECT COALESCE(recommend,'') FROM tasks WHERE id=${gid};")
    gident=$(db "SELECT ident FROM tasks WHERE id=${gid};")
    # Reuse the single-gate answer path (provenance/signature/advance identical to
    # a human tap). Suppress its per-gate ok line; a subshell isolates its fail/exit
    # so one bad gate can't abort the batch.
    if ( cmd_task_answer "$gid" --value="$grec" --channel-proof="$channel_proof" --from="${from:-telegram}" ) >/dev/null 2>&1; then
      cleared+=("$gident"); cleared_recs+=("$grec")
    fi
  done <<<"$rows"

  local n=${#cleared[@]}
  # DIVE-2054: DELIBERATELY UNFENCED (ticket-named exemption) — carries
  # chat=$channel_proof, the proof a real channel was hit.
  audit_log "task clear-recs" "ok" 0 -- "cleared=$n" "only=${only:-all}" "chat=$channel_proof" "list=${cleared[*]:-none}"
  if (( n == 0 )); then
    ok "no eligible gates to clear (agent-clearable, tier<2, with a recommendation)$([[ -n "$only" ]] && echo " for $only")" \
       '{cleared:0, gates:[]}'
    return 0
  fi
  # Build a JSON array of cleared idents for the plugin/dashboard.
  local gates_json; gates_json=$(printf '%s\n' "${cleared[@]}" | jq -R . | jq -sc .)
  ok "applied recommendations to $n gate(s): ${cleared[*]}" \
     '{cleared:($n|tonumber), gates:$g}' --arg n "$n" --argjson g "$gates_json"
}

