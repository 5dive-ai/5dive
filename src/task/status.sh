# -------- 5dive task — status --------
#
# Split out of src/cmd_task.sh (DIVE-3278): the status machine: the result-over-closed guard and _task_status_cmd, which
# start / done / cancel all funnel through.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
# src/cmd_task.sh when the split tree is used (tests source src/cmd_task.sh).
# Function definitions only — never execute this file directly.
# DIVE-2464 / DIVE-2476: the one guard standing between a `--result=` write and an
# ALREADY-CLOSED row's recorded result. Extracted from `_task_status_cmd` so the
# refusal text, the --append-result ordering and the --force-result audit row are
# LITERALLY the same across every verb that writes the column, rather than a second
# variant that drifts apart from it. DIVE-2476 is why it is a function: the rule
# belongs to the COLUMN — whose ledger copy is a sha256, so a silent replace is
# unrecoverable — and not to the verb, and `task deliver --result=` was destroying
# the same value through the door next to the guarded one. Measured on origin/main
# e935d82 AND on #357's tip, so pre-existing rather than a #357 regression.
#
# Callers decide WHEN to consult it (which verbs, and only when a result was
# actually passed); it decides what happens. It is NOT safe to call inside a command
# substitution: the refusal path ends in `fail`, which exits, and a subshell would
# turn the refusal into a shrug the caller then writes straight past. So the
# (possibly appended) text it wants written comes back in a global, not on stdout.
#
# args: <id> <ident> <verb> <result> [append_result] [force_result] [policy-slug]
# out:  _TASK_GUARDED_RESULT — the text the caller must write from here on.
_task_guard_result_over_closed() {
  local id="$1" ident="$2" verb="$3" result="$4"
  local append_result="${5:-0}" force_result="${6:-0}" policy="${7:-done-over-closed-result}"
  _TASK_GUARDED_RESULT="$result"
  local _cl_st _cl_prev
  _cl_st=$(db "SELECT COALESCE(status,'') FROM tasks WHERE id=${id};")
  _cl_prev=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${id};")
  # DIVE-2483: THE KEY IS THE COLUMN, NOT THE ROW STATE. Both reads now happen
  # unconditionally, and the gate below is "bytes are about to be lost" — the
  # thing this guard is actually for. Keyed on closed-ness it missed the cell the
  # maker→verifier rail MANUFACTURES on every loop: a delivered row is OPEN and
  # already carries the maker's record, so the guard protected the rare cell and
  # skipped the routine one. Three verbs hit that cell (done, deliver, verify) and
  # each was found separately, which is what a status key buys you.
  #
  # Nothing recorded, or nothing changing -> no bytes at risk, and in particular a
  # bare repeat close (no --result at all) never reaches here because the callers
  # only consult the guard when a result was actually passed.
  if [[ -z "$_cl_prev" || "$_cl_prev" == "$result" ]]; then
    _TASK_GUARDED_RESULT="$result"; return 0
  fi

  # DIVE-2483, and this one is unconditional on purpose: an EMPTY --result= over a
  # non-empty column is refused at EVERY status and under EVERY flag, --force-result
  # included. There is no legitimate reason to blank a result, and the value arrives
  # from ordinary shell accidents rather than from a decision — an unset variable, a
  # killed heredoc, a truncated arg. It is also the least visible loss available: a
  # zero-length result renders as a blank field, indistinguishable from "nobody ever
  # wrote one", so unlike a replacement with real text it leaves nothing for a reader
  # to notice. That is why it does not get the escape hatch the lossy path gets.
  if [[ -z "$result" ]]; then
    policy_refuse "$E_CONFLICT" result-blanked DIVE-2483 "$ident" \
      "$ident carries a result and '5dive task ${verb} --result=' was given an EMPTY value — that would blank the record, and the ledger keeps only a sha256 of it, so it could not be restored (DIVE-2483). This is refused at every status and under every flag (including --force-result): a zero-length result is indistinguishable from one that was never written, so nobody would ever notice the loss. Almost always this is a shell accident rather than an intent — an unset variable, a killed heredoc, a truncated argument. Check the value you passed. If you genuinely mean to REPLACE the text, pass the replacement; if you mean to ADD to it, that is the default on an open row and '--append-result' on a closed one."
  fi

  if [[ "$_cl_st" == "done" || "$_cl_st" == "cancelled" ]]; then
      if (( append_result )); then
        # Prior text FIRST and untouched: the existing record is the one that
        # must survive verbatim, and the addition is what is new.
        result="${_cl_prev}"$'\n\n'"--- appended by a later close (DIVE-2464) ---"$'\n'"${result}"
      elif (( force_result )); then
        # The only lossy path, so it is the only one that leaves a row behind.
        # The overwritten text goes in the audit args, not just its hash — the
        # whole point of this ticket is that a hash is not a backup.
        _task_store_audit_log "task.force-result-over-closed" ok 0 -- \
          "$ident" "closed_status=$_cl_st" "overwritten_result=$_cl_prev"
        warn "$ident: --force-result REPLACED the result recorded at close. The overwritten text is in the audit log (task.force-result-over-closed); the board copy is gone (DIVE-2464)."
      else
        local _cl_at _cl_asg _cl_vf _cl_mk
        _cl_at=$(db  "SELECT COALESCE(done_at,'unknown')     FROM tasks WHERE id=${id};")
        _cl_asg=$(db "SELECT COALESCE(assignee,'unassigned') FROM tasks WHERE id=${id};")
        _cl_vf=$(db  "SELECT COALESCE(verifier,'')           FROM tasks WHERE id=${id};")
        _cl_mk=$(db  "SELECT COALESCE(maker_agent,'')        FROM tasks WHERE id=${id};")
        policy_refuse "$E_CONFLICT" "$policy" DIVE-2464 "$ident" \
          "$ident is ALREADY ${_cl_st} (closed ${_cl_at}; assignee '${_cl_asg}'${_cl_vf:+, verifier '${_cl_vf}'}${_cl_mk:+, maker '${_cl_mk}'}) and carries a result — a bare '5dive task ${verb} --result=' here would REPLACE that record with no warning, and the ledger keeps only a sha256 of it, so it could not be restored (DIVE-2464). Run '5dive trace $ident' to see who wrote it. If you are ADDING your half of the work, say so: '5dive task ${verb} $ident --append-result --result=<your text>' (keeps theirs verbatim, adds yours under it). Only if the recorded text is genuinely WRONG: '--force-result' (replaces it, audited with the overwritten text)."
      fi
  else
    # DIVE-2483: OPEN row already carrying someone's result. AUTO-APPEND — the
    # decision on the row (olivia, 2026-08-04), and it is not the same answer as
    # the closed cell above on purpose.
    #
    # Refusing here instead would have been the "uniform" choice and it WEDGES the
    # rail: `task reject` writes the VERIFIER'S feedback into `result` (see the
    # UPDATE in _task_reject_cmd), so after any rejection the row is open and
    # carries someone else's non-empty text — and the maker's next
    # `task done --result=` at iteration 2 is exactly this cell. Uniform refusal
    # would turn the second iteration of every graded task into a refusal, which
    # trains people to reach for --force-result. Appending cannot wedge anything.
    #
    # It also removes the DIVE-2717 class rather than patching it: --append-result
    # was PARSED, accepted and silently INERT here, because the remedy lived inside
    # the closed-row branch. A flag that no-ops in the situation its help text
    # describes is worse than an absent one — an operator reaches for it precisely
    # when they perceive the risk, and a clean OK is affirmative evidence that the
    # protection ran. Making preservation the DEFAULT means the protection no
    # longer depends on remembering a flag whose habit only forms where it works.
    # (--append-result is therefore a no-op here, not an error: it asks for what
    # already happens.)
    if (( force_result )); then
      # Same lossy escape as the closed cell, same audit obligation: the
      # overwritten TEXT, not just its hash.
      _task_store_audit_log "task.force-result-over-open" ok 0 -- \
        "$ident" "open_status=$_cl_st" "overwritten_result=$_cl_prev"
      warn "$ident: --force-result REPLACED a result this OPEN row already carried. The overwritten text is in the audit log (task.force-result-over-open); the board copy is gone (DIVE-2483)."
    else
      # DIVE-2483 iteration 2 (olivia's reject). The gate answer named FOUR
      # conditions; the two expressible as DB-column state shipped, and the two
      # about what the OPERATOR SEES were dropped. Both are here now.
      #
      # CONDITION 2 — DATE THE SEAM. There is no result_by column (that was this
      # row's first blocker), so the seam marker IS the provenance: it is the only
      # thing on the board that says a second writer arrived and when. An undated
      # marker tells a reader that two texts were joined and nothing about the
      # order of events, which is most of what provenance is for.
      local _seam_at; _seam_at=$(date -u '+%Y-%m-%d %H:%M:%SZ')
      result="${_cl_prev}"$'\n\n'"--- appended ${_seam_at} by a later write (DIVE-2483); the text above was already on the row ---"$'\n'"${result}"
      # CONDITION 1 — SAY IT HAPPENED. This is the one the gate answer flagged as
      # "most likely to be dropped as cosmetic", and it was dropped. Without it a
      # bare open-row close prints exactly `ok - <ident> done` — BYTE-IDENTICAL to
      # the output that accompanied the DIVE-2712 wipe. The bytes were rescued and
      # the silence that made their loss undetectable was shipped intact, so an
      # operator cannot tell the fixed behaviour from the defect at the terminal.
      # The byte count is not decoration: it is the cheapest thing that makes the
      # claim falsifiable at a glance — a reader who expected 2.6KB and sees 40
      # knows to look, and one who sees nothing at all never does.
      warn "$ident: this row already carried a result and it was PRESERVED, not replaced — ${#_cl_prev} bytes kept above your text, under a dated seam (DIVE-2483). Run '5dive task show $ident' to read both, or '5dive trace $ident' for who wrote the earlier one."
    fi
  fi
  _TASK_GUARDED_RESULT="$result"
}

_task_status_cmd() {
  local newstatus="$1" extra="$2" verb="$3"; shift 3
  tasks_db_init
  local result="" want_result=0 notify=0 no_preflight=0 force_merge_gate=0 keep_wt=0 no_graded_sha=0
  local no_pr=0                          # DIVE-2096: "this close REPORTS ON a PR, it delivers none"
  local append_result=0 force_result=0   # DIVE-2464
  # DIVE-1955 (review, Marcus): every reason the merge-gate could NOT reach an answer,
  # accumulated so the close can be stamped UNVERIFIED in the DURABLE RECORD. A stderr
  # warn and an audit row are necessary and not sufficient: the task row is what a
  # reader sees months later, and a clean-looking row is a verdict the gate never made.
  # Same rule we shipped in DIVE-1869 — a check that could not reach its answer must
  # not render as one. Blocking nothing is fine; blessing by silence is not.
  local _mg_unverified=""
  # DIVE-3458: the foreign-delivery record. Separate from _mg_unverified on
  # purpose — UNVERIFIED means "we could not check"; this means "we checked, and
  # the merge is not ours to make". Collapsing them would put a scare-mark on a
  # close that is exactly as complete as it will ever be.
  local _mg_foreign=""
  # ...and whether the gate had ANY subject to verify in the first place. See
  # _gate_text_names_a_ref: an unverified reason only earns a mark on the record when
  # something was actually pending verification.
  local _mg_had_subject=0
  # DIVE-2627: which flag supplied the result (see _read_prose_file).
  local result_src=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result=*)     _prose_flag_dupe --result "$result_src"; result="${1#*=}"; want_result=1; result_src="--result" ;;
      # DIVE-2627: the result read VERBATIM from a file. `--result` is the widest
      # site in the class (32 call sites on origin/main @ 2e0e876) and it is the
      # permanent close record the dashboard and the task's creator read.
      --result-file=*) _prose_flag_dupe --result-file "$result_src"
                       _read_prose_file --result-file "${1#*=}"
                       result="$_PROSE_FILE_VALUE"; want_result=1; result_src="--result-file" ;;
      --notify)       notify=1 ;;
      --no-preflight) no_preflight=1 ;;
      --force-merge-gate) force_merge_gate=1 ;;  # DIVE-1835: audited escape from the mandatory auto-detect gate
      # DIVE-2096: the NAMED opt-out for DIVE-1965's reports-on category. Distinct
      # from --force-merge-gate on purpose: that one overrides a gate that RAN and
      # disagreed; this one ASSERTS a fact about the close ("no PR is mine to bind"),
      # which is a claim the operator can be held to and the audit row records.
      --no-pr)        no_pr=1 ;;
      # DIVE-2940: the declared escape from the graded-sha PRE-CLOSE refusal below.
      # Deliberately NOT folded into --force-merge-gate: that flag escapes a gate
      # that RAN and disagreed (a sha mismatch, a red merge), and this one escapes
      # a gate that could not run at all for want of an operand. Same distinction
      # DIVE-2318 draws between "answered no" and "never asked", and a shared flag
      # would make the audit row unable to say which of the two a closer overrode.
      --no-graded-sha) no_graded_sha=1 ;;
      # DIVE-1967: opt OUT of the node_modules reclaim a close performs (you are
      # about to reuse the worktree and do not want to pay for another npm ci).
      --keep-worktree) keep_wt=1 ;;
      # DIVE-2464: the two sanctioned answers to the already-closed-row refusal
      # below. --append-result is the COMMON legitimate case (a second closer
      # adds their half); --force-result is the rare "the prior text was wrong"
      # replace, and it is audited because it is the only lossy one.
      --append-result) append_result=1 ;;
      --force-result)  force_result=1 ;;
      --)         shift; positional+=("$@"); break ;;
      -*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)          positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task $verb <id|DIVE-N> [--result=<text>] [--notify]"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # DIVE-2179: `task done` on a live, unacknowledged handoff must stamp the SAME
  # ack the DIVE-1378 `start` block stamps below — even when this `done` is about
  # to be REFUSED further down (DIVE-2464/DIVE-477/DIVE-2007/DIVE-555, or the
  # DIVE-1830/DIVE-1835 merge gate). The ack means "the verifier attempted to
  # grade this", not "the close succeeded". `start`'s ack can defer its write into
  # `extra` because nothing after it in the `start` path refuses; `done` has no
  # such guarantee — every refusal below goes through policy_refuse -> fail,
  # which exits immediately, so anything only staged in `extra` never reaches the
  # final UPDATE. A verifier who runs `done` straight (skipping `start`) against
  # an unmerged PR/branch binding gets structurally refused by the merge gate,
  # and without this, handoff_ack_at stays NULL forever — the heartbeat stall
  # sweep (_hb_stall_sweep, src/cmd_heartbeat.sh) then nags them forever with two
  # dead-end remedies: `done` is the very thing just refused, and `reject` would
  # write a false FAIL over work the verifier meant to grade PASS. So this write
  # is immediate and separately committed, not deferred, and placed as early in
  # the `done` path as the resolved id allows. Same predicate as the `start` ack
  # below, plus excluding an already-closed row (a `done`/`cancel` can land here
  # on a closed task where there is nothing live left to ack). COALESCE keeps
  # repeat attempts idempotent.
  if [[ "$verb" == "done" ]]; then
    local _done_ack_actor; _done_ack_actor=$(task_actor)
    db "UPDATE tasks SET handoff_ack_at=COALESCE(handoff_ack_at, datetime('now'))
        WHERE id=${id}
          AND maker_agent IS NOT NULL
          AND assignee=verifier
          AND assignee=$(sqlq "$_done_ack_actor")
          AND handoff_ack_at IS NULL
          AND status NOT IN ('done','cancelled');"
  fi
  # DIVE-2059: 'task start' on a recurring TEMPLATE was never meaningful — it
  # sets status='in_progress', and post-DIVE-2055 the materializer's fire
  # predicate requires status='todo', so this silently retired the template's
  # schedule (no error, no output) and dropped it from the default
  # `task ls --recurring` listing too (same live predicate). cancel/block/park
  # on a template ARE the real, intentional stop levers (that's the DIVE-2055
  # fix) and must keep working — this refuses ONLY the meaningless 'start' verb.
  if [[ "$verb" == "start" ]]; then
    local _tpl_kind; _tpl_kind=$(db "SELECT kind FROM tasks WHERE id=${id};")
    if [[ "$_tpl_kind" == "recurring" ]]; then
      policy_refuse "$E_CONFLICT" start-on-recurring-template DIVE-2059 "$ident" "$ident is a recurring TEMPLATE, not a worked task — start the instance it fired, or 'task cancel $ident' to stop it"
    fi
    # DIVE-2113: `task start` silently REOPENED a closed, graded task for ANY
    # actor — neither maker nor verifier. Measured on an isolated fixture:
    # status done -> in_progress, rc=0, and the ONLY output was an advisory warn
    # about the assignee. The result survived (milder than the DIVE-2112 reject
    # bug, which destroyed it), but the grade then described a task the board
    # showed as OPEN.
    #
    # Worse than first recorded, and measured here rather than assumed: done_at
    # is NOT cleared, so the row lands in_progress WHILE STILL CARRYING a
    # done_at — internally contradictory, and any reader or query keying off
    # done_at disagrees with the one keying off status.
    #
    # Same family as DIVE-2112: a writer landing on a closed task with no status
    # check. Measured CLEAN in the same sweep, recorded so nobody re-audits:
    # block (rc=2), unblock (rc=0), unpark (rc=0), deliver (rc=2) — none mutated
    # status or result on a closed task.
    #
    # NO ALTERNATIVE VERB IS NAMED IN THE REFUSAL, DELIBERATELY. A refusal that
    # enumerates exits publishes a route around itself, and each named verb
    # inherits an obligation it was never audited for — that is exactly how
    # DIVE-2067 happened, where `task done`'s refusal pointed at an unguarded
    # `task verify --cmd` and a landed verifier ACK was replaced 39 seconds
    # later. See community/wiki/a-guard-advertises-its-own-bypass.md. A reopen
    # path exists in the code, but it is not audited as an entry point to a
    # CLOSED row, so this refusal will not advertise it.
    local _cs _cd
    _cs=$(db "SELECT status FROM tasks WHERE id=${id};")
    if [[ "$_cs" == "done" || "$_cs" == "cancelled" ]]; then
      _cd=$(db "SELECT COALESCE(done_at,'unknown') FROM tasks WHERE id=${id};")
      policy_refuse "$E_CONFLICT" start-on-closed-task DIVE-2113 "$ident" "$ident is CLOSED (${_cs}, closed ${_cd}) — reopening it here would leave done_at set and contradict the board"
    fi
    # DIVE-2317: status='blocked' is only a reason to refuse while the edge is
    # still live. The cascade normally flips a dependent back to todo when its
    # last blocker closes, but stale blocked statuses can exist; refusing those
    # would strand otherwise-actionable work. Conversely, starting a row with an
    # OPEN blocker leaves the edge in place while changing only the status, so
    # the board and dependency graph immediately disagree. Name one deterministic
    # live blocker so the refusal is evidence, not a generic state assertion.
    if [[ "$_cs" == "blocked" ]]; then
      local _start_ob _start_obi _start_obs
      _start_ob=$(_task_live_blocker "$id")
      if [[ -n "$_start_ob" ]]; then
        _start_obi="${_start_ob%%|*}"; _start_obs="${_start_ob#*|}"
        policy_refuse "$E_CONFLICT" start-on-open-blocker DIVE-2317 "$ident" "$ident is BLOCKED by open task ${_start_obi} (status='${_start_obs}') — 'task start' would silently set this row to in_progress while its live blocked_by edge remains, so the status and dependency graph would contradict each other. It becomes startable when every blocker is done or cancelled; a stale status='blocked' with no open blocker is deliberately allowed (DIVE-2317)."
      fi
    fi
    # DIVE-2510: `task start` was the LAST status writer with no delivered-loop
    # guard. `task done` refuses a non-verifier over a live delivery (DIVE-2007),
    # `task reject` refuses the maker (DIVE-2112), `task start` refuses a closed
    # row (DIVE-2113) — but a delivered row could still be re-claimed by its own
    # maker, and the /goal prompt instructs exactly that ("claim it with
    # `task start`"). So the documented workflow walks a maker into it: any
    # delivered row a goal is re-issued over gets silently taken back out of the
    # delivered shape by an agent following instructions correctly.
    #
    # THE HARM IS A MISREPRESENTED STATE. Measured on an isolated fixture, not
    # inferred, and scoped narrowly on purpose because the exact scope is what
    # the reader needs:
    #   * status flips todo -> in_progress, and started_at (which the handoff set
    #     to NULL) is re-stamped with the re-claim time. That is the whole write.
    #   * `task show` keeps printing `handoff: delivered (awaiting verifier ACK)`
    #     throughout — the render keys on `assignee=verifier AND status NOT IN
    #     ('done','cancelled')`, and in_progress passes that. `task reject` is
    #     what moves assignee back to the maker and (correctly) drops the line.
    # So the board shows in_progress on a row nobody is working — it is sitting
    # in the verifier's queue — and `status='todo' AND assignee=verifier`, the
    # predicate the delivered state is documented as, stops matching. A false
    # record either way, which is reason enough to refuse.
    #
    # DO NOT go looking for cleared delivery columns; there are none, and a
    # reading of this rail that expects them is wrong at the schema level.
    # A maker→verifier handoff returns before the merge-gate, so on a loop
    # delivered by `task done` these columns are NULL and always were. The two
    # writers — explicit `task deliver --pr=` and DIVE-2316's later merge-gate
    # discovery write — are both unreachable on this early-return path.
    # `handoff_ack_at` is set to NULL by
    # _task_route_to_verifier as PART of delivering. All three are therefore NULL
    # *while the row is legitimately delivered*, which is why observing them NULL
    # after a stray `task start` says nothing about that start. T6 of the harness
    # measures the columns a loop delivery actually populates
    # (handoff_delivered_at, maker_agent, iteration, result) and pins that they
    # are untouched, rather than restating survival of columns that were never
    # set — a "survives" claim over a NULL column is vacuously true and misleads.
    #
    # Keyed on the ACTOR, exactly like DIVE-2007, not on who the row is assigned
    # to: delivery flips assignee TO the verifier, so an assignee test would read
    # the maker's re-claim as a stranger's. The verifier's own start is the
    # DIVE-1378 ACK further down and is excluded HERE by the actor comparison —
    # the SQL only yields a verifier name when that verifier is not the caller.
    # `cli` is task_actor's "could not attribute this invocation" sentinel
    # (non-agent user, root cron, CI) and is EXEMPT for the same reason DIVE-2007
    # exempts it — the threat model is a resolvable agent re-claiming its own
    # delivery, and CI is where an over-broad version of that guard breaks
    # unrelated harnesses.
    #
    # NOT an iteration fix, and it was proposed as one — measured instead of
    # assumed, see T7. A maker's re-claim cannot inflate `iteration`: the only
    # writer is _task_route_to_verifier, reached only by a `task done` that was
    # NOT refused, and DIVE-2007 refuses the maker's done whatever status a stray
    # start left behind. A climbing iteration on a delivered row means real
    # reject/re-deliver cycles (or the exempt `cli`/verifier actor), not this bug.
    #
    # Placed BEFORE _task_start_preflight, alongside the DIVE-2059 and DIVE-2113
    # refusals, so a start that is going to be refused does not first print three
    # advisory heads-up warnings about work it will not be allowed to do.
    local _sd_actor; _sd_actor=$(task_actor)
    local _sd_vfier _sd_maker _sd_iter
    IFS='|' read -r _sd_vfier _sd_maker _sd_iter <<<"$(db "SELECT
            CASE WHEN maker_agent IS NOT NULL AND verifier IS NOT NULL
                      AND assignee=verifier AND verifier IS NOT $(sqlq "$_sd_actor")
                      AND handoff_ack_at IS NULL
                      AND status NOT IN ('done','cancelled')
                 THEN verifier ELSE '' END
            ||'|'||COALESCE(maker_agent,'')||'|'||COALESCE(iteration,0)
          FROM tasks WHERE id=${id};")"
    if [[ -n "$_sd_vfier" && "$_sd_actor" != "cli" ]]; then
        policy_refuse "$E_CONFLICT" start-over-delivered-loop DIVE-2510 "$ident" \
          "$ident is DELIVERED to verifier '${_sd_vfier}' (iteration ${_sd_iter}, maker '${_sd_maker}') and has NOT been graded — a 'task start' from '${_sd_actor}' would flip it to in_progress, so the board would show someone working a row that is actually sitting in '${_sd_vfier}''s review queue, and the delivered predicate (status='todo' AND assignee=verifier) would stop matching it. Nothing is yours to claim here until it comes back: '${_sd_vfier}' either closes it or bounces it with '5dive task reject $ident --feedback=...' — that bounce reassigns it to you and 'task start' works again. If you have a CORRECTION to the delivery, send it to '${_sd_vfier}' (5dive agent send ${_sd_vfier} \"...\") rather than taking the row back."
    fi
  fi
  # DIVE-1375: fail-loud preflight — surface identity/auth/repo gaps at `start`
  # BEFORE the agent burns a turn discovering them mid-task. Advisory only
  # (never blocks the start); runs from the caller's cwd.
  if [[ "$verb" == "start" && $no_preflight -eq 0 ]]; then
    _task_start_preflight "$id" "$ident" "$(task_actor)" || true
  fi
  # DIVE-1378: `task start` is the receiver-emitted ACK for a verifier handoff.
  # Record it only when the ACTOR is the currently assigned verifier. Delivery
  # alone, or a third party forcing status=in_progress, must never claim that
  # review is running. COALESCE makes repeat starts idempotent.
  local handoff_ack="" handoff_ack_at=""
  if [[ "$verb" == "start" ]]; then
    local _start_actor; _start_actor=$(task_actor)
    if [[ "$(db "SELECT CASE WHEN maker_agent IS NOT NULL
                                  AND assignee=verifier
                                  AND assignee=$(sqlq "$_start_actor")
                                  AND handoff_ack_at IS NULL
                               THEN 1 ELSE 0 END
                         FROM tasks WHERE id=${id};")" == "1" ]]; then
      handoff_ack="reviewing"
      extra+=", handoff_ack_at=COALESCE(handoff_ack_at, datetime('now'))"
    fi
  fi
  # DIVE-2464: a close landing on an ALREADY-CLOSED row silently REPLACED its
  # result. Hit live 2026-07-30 21:11 on DIVE-2451 — main2 closed at 21:08:59,
  # main ran `task done --result=...` at 21:11:43, and the verb accepted it,
  # overwrote the result column, printed nothing, exited 0. The prior record was
  # gone from the board.
  #
  # WHY THE LEDGER DOES NOT COVER THIS: `5dive trace` shows both task.done events
  # with an authority envelope and an `out:` field — but that field is a sha256 OF
  # the result, not the text. It proves the record changed and cannot restore it.
  # An integrity hash is not a backup. What actually recovered DIVE-2451 was a
  # /var/lib/5dive/tasks-backups/ snapshot that happened to fall between the two
  # writes (5-minute cadence, 3-minute window) — luck about a cron, not a path.
  #
  # WHY THE CHECK HAS TO LIVE IN THE VERB: "read the status first" does not work.
  # The overwriting invocation PRINTED the row's status in the same call as the
  # write, so the read could not gate anything. A check that cannot stop the
  # action is decoration.
  #
  # This is DIVE-2067 rec 1, ported to the verb that was left unguarded. DIVE-2067
  # fixed the same clobber in `task verify` (verify-over-closed refusal + the
  # preserve-by-appending fallback further down that function); `task done` kept
  # the destructive behaviour, and the DIVE-2007 guard above explicitly falls
  # THROUGH for closed rows ("a repeat done stays idempotent") — true of the
  # status write, false of the result write.
  #
  # SCOPE, deliberately narrow so nothing idempotent regresses:
  #   * only a close verb (done/cancel) landing on status done|cancelled;
  #   * only when --result= was actually PASSED (a bare re-close writes no result);
  #   * only when the stored result is NON-EMPTY (nothing to destroy otherwise);
  #   * only when the new text DIFFERS (a replay with identical text is a no-op).
  # Everything else keeps working exactly as before.
  #
  # PLACEMENT IS PART OF THE FIX, and the first version of this change got it
  # wrong in a way worth recording. This block originally sat BELOW the DIVE-477
  # verifier-routing branch, which `return`s early — so on any row where
  # `verifier` is set and differs from `assignee` the guard was never reached,
  # `_task_route_to_verifier` performed its own unconditional
  # `(( want_result )) && set_result=`, and the clobber survived untouched on that
  # shape. The scope list above then read as sufficient while an unstated fourth
  # condition ("...and the row does not route to a distinct verifier") was doing
  # real work. Caught in review by main, measured on a clean detached worktree
  # rather than argued.
  #
  # TWO CHANGES ANSWER IT, and their division of labour was MEASURED by mutating
  # each independently rather than inferred — the result is not what either of us
  # expected:
  #   * this block moved ABOVE the routing branch;
  #   * a closed row additionally stopped from routing at all (note there).
  # Mutation A (exclusion removed, placement kept): the routed-shape arms stay
  # GREEN, the resurrection arms RED. Mutation B (placement reverted, exclusion
  # kept): EVERYTHING stays green. So the exclusion SUBSUMES the ordering for the
  # result clobber and the ordering is redundant given it — no test arm pins this
  # block's position, and a future refactor could move it back down with no red.
  # Kept anyway as defence-in-depth: it is the only thing left standing if the
  # exclusion is relaxed, and a closed row not routing is right on its own merits.
  # Written down rather than sold as belt-and-braces coverage, because the first
  # version of this change asserted coverage it had not measured and that is the
  # entire reason it came back.
  #
  # The resurrection is a genuinely SEPARATE harm, not a second symptom of this
  # one: it fires on a BARE re-close where there is no result to protect and this
  # block correctly stays silent. Ordering alone does not reach it.
  #
  # NOT FIXED HERE, named so none of it is mistaken for covered:
  #   * (CLOSED by DIVE-2476: `task deliver --result=` clobbered a closed row the
  #     same way — main's probe P4. It now consults the SAME guard, extracted above,
  #     and consults it BEFORE it stamps delivery_ref. Still open on that verb, and
  #     measured: a BARE `task deliver` with no --result= re-stamps delivery_ref and
  #     delivered_at on a closed row, and on a closed row carrying a distinct
  #     verifier it still ROUTES — resurrecting it to 'todo' — the shape DIVE-2464
  #     iter 2 excluded on the `task done` rail only. Both live in the no-result
  #     population this guard is blind to by construction, so neither is covered.)
  #   * `_task_route_to_verifier` still writes unconditionally over an OPEN row's
  #     existing result — a different population than this ticket measured;
  #   * a BARE re-close still REFRESHES done_at (both close verbs pass
  #     `done_at=datetime('now')` unconditionally), measured: 2026-07-30 21:08:59
  #     -> now. Pre-existing on the non-routed shape and unchanged by this ticket;
  #     NEW on the routed shape only because the exclusion above now lets it fall
  #     through here instead of resurrecting the row, which is strictly the better
  #     of the two. It matters slightly more than it looks, because the refusal
  #     message quotes done_at as evidence of who closed when — so the honest fix
  #     is `COALESCE(done_at, datetime('now'))` at the two call sites, which is a
  #     change to EVERY close and therefore its own row (DIVE-2477), not a rider
  #     on this one.
  #
  # The general lesson, since it is this ticket's own defect wearing a different
  # hat: a guard's scope is bounded by every early `return` above it, and "the
  # other rail handles that shape" is a claim about a GUARD when the thing above
  # you may be a different WRITE PATH. Enumerate the writers, do not reason from
  # the neighbouring comment.
  #
  # The refusal names the row's recorded holders and the close timestamp, not the
  # invoking actor of the earlier write — the tasks row does not store that. The
  # actor lives in the audit trail, so the message sends the reader to `5dive
  # trace` for it rather than implying the row knows.
  if [[ "$verb" == "done" || "$verb" == "cancel" ]] && (( want_result )); then
    _task_guard_result_over_closed "$id" "$ident" "$verb" "$result" "$append_result" "$force_result"
    result="$_TASK_GUARDED_RESULT"
  fi
  # DIVE-2835: a result that NAMES a version is making a claim about a DEPLOYED
  # artifact — compare it to the one this host runs. Placed BEFORE the DIVE-477
  # routing below on purpose: a maker's `task done` that delivers rather than
  # closes carries exactly the same claim, and the moment to check it is the
  # moment it is written, not the moment someone later re-reads it.
  [[ "$verb" == "done" ]] && _gate_version_vs_installed "$ident" done "$result"
  # DIVE-477: maker→verifier routing. A `task done` on a task that carries a
  # `verifier` distinct from its current assignee is NOT a close — it's a handoff.
  # The maker is claiming the work is ready; the verifier must grade it before the
  # task can close (writer != grader). Route it to the verifier and let the
  # heartbeat wake them on the next tick; the verifier closes it for real (its own
  # `task done`, where verifier==assignee, falls through to a normal close) or
  # rejects it (`task reject` → bounce back to the maker). Opt-in: ordinary tasks
  # (verifier NULL) and the verifier's own close are untouched.
  if [[ "$verb" == "done" ]]; then
    local _vfier _asignee _route_st
    _vfier=$(db "SELECT COALESCE(verifier,'')  FROM tasks WHERE id=${id};")
    _asignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")
    # DIVE-2464 (review, main): a row that is ALREADY CLOSED must not route. The
    # routing predicate is purely positional (`verifier != assignee`) and never
    # read status, so a second `task done` on a closed handoff row was routed
    # again — and `_task_route_to_verifier` sets status='todo', so the close was
    # RESURRECTED and re-delivered. Measured on a closed row with verifier='main',
    # assignee='olivia': status done -> todo, rc=0, and (before the guard above
    # moved ahead of this branch) the result destroyed on the way through.
    #
    # This is the SECOND harm on the path and it is not the result clobber: it
    # fires on a BARE re-close too, where there is no result to protect and the
    # DIVE-2464 guard above correctly stays silent. So ordering alone does not
    # cover it and this condition is doing separate work — stated because the
    # first version of this change asserted coverage it did not have, which is
    # what the review caught.
    #
    # Falling through (rather than refusing) is deliberate: the normal close path
    # below is idempotent on an already-closed row, so a bare repeat `task done`
    # keeps its long-standing rc=0 no-op behaviour instead of newly erroring.
    _route_st=$(db "SELECT COALESCE(status,'') FROM tasks WHERE id=${id};")
    # DIVE-2719: the depth `task add` GUESSED from the title, re-measured here
    # from the paths this delivery actually touched (see _task_delivery_depth).
    # Empty = unknown = every branch below behaves exactly as it did before.
    local _depth=""
    if [[ "$_route_st" != "done" && "$_route_st" != "cancelled" ]]; then
      _depth=$(_task_delivery_paths "$id" | _task_delivery_depth)
    fi
    if [[ -n "$_vfier" && "$_vfier" != "$_asignee" \
          && "$_route_st" != "done" && "$_route_st" != "cancelled" ]]; then
      if [[ "$_depth" == "shallow" ]]; then
        # DOWNGRADE. The rail was earned by the title; the diff says tests/docs
        # only. Fall through to the ordinary close — which still has to satisfy
        # the DIVE-1830 merge gate below, so "no verifier round" never becomes
        # "no gate at all". The verifier column is left in place: it records who
        # WOULD have graded, and `5dive trace` can still answer why nobody did.
        warn "$ident: verifier round skipped (DIVE-2719) — the delivered diff touches only tests/docs/changelog, where CI is the gate and a grading round-trip adds latency and no signal. Grader on the row was '$_vfier'; force the review with '5dive task verifier $ident $_vfier' after re-opening if you disagree."
      else
        _task_route_to_verifier "$id" "$_vfier" "$_asignee" "$result" "$want_result"
        return
      fi
    elif [[ -z "$_vfier" && "$_depth" == "deep" && -n "$_asignee" \
            && "$_route_st" != "done" && "$_route_st" != "cancelled" \
            && "${FIVE_VERIFY_DEFAULT:-1}" != "0" ]]; then
      # UPGRADE. `task add` read this row as trivial (bodyless chore title, or
      # low priority) and gave it no grader — but the diff reached the scheduler,
      # the task store, credentials or deploy. This is a ROUND TRIP, not a block:
      # the grader's own `task done` (verifier==assignee) closes it normally.
      #
      # DIVE-2730: AN EXPLICIT `--no-verify` DOES NOT SUPPRESS THIS UPGRADE, and
      # the temptation to make it do so is the whole reason to write this down.
      # `--no-verify` is declared at FILE time; the blast radius is MEASURED at
      # DELIVERY time. Letting the declaration win inverts which evidence decides
      # — it lets a sentence typed before the diff existed pre-authorise closing a
      # credentials or scheduler change ungraded, which is the exact control
      # DIVE-2719 exists to impose and a waiver in DIVE-969's banned direction.
      # What the filer opted out of was ROUTINE grading, not grading of a diff
      # they had not written yet. (main, reviewing this change on DIVE-2730.)
      #
      # So the column is not a predicate here — it is what makes the override
      # SAYABLE. The defect this row was filed for is that an explicit human
      # instruction was overridden SILENTLY: before the column, `task done` could
      # not tell a refusal from a default absence, so it could not name what it
      # was overriding even if it wanted to. Now it can, and does.
      local _optout; _optout=$(db "SELECT COALESCE(verify_optout,0) FROM tasks WHERE id=${id};")
      local _up; _up=$(_task_default_verifier "$_asignee" "")
      if [[ -n "$_up" ]]; then
        db "UPDATE tasks SET verifier=$(sqlq "$_up") WHERE id=${id};"
        if [[ "$_optout" == "1" ]]; then
          warn "$ident: graded despite '--no-verify' (DIVE-2730) — the opt-out was declared at filing, before this diff existed, and the delivered diff touches the blast radius (scheduler/task store/credentials/deploy), where the delivery-time measurement wins over the file-time declaration. Routes to '$_up'."
        else
          warn "$ident: graded after all (DIVE-2719) — filed without a verifier, but the delivered diff touches the blast radius (scheduler/task store/credentials/deploy), so it routes to '$_up' instead of closing outright."
        fi
        _task_route_to_verifier "$id" "$_up" "$_asignee" "$result" "$want_result"
        return
      fi
    fi
    # DIVE-2007: the DELIVERED state must be durable against its own MAKER. The
    # routing test above is positional (`verifier != assignee`), and delivery
    # flips assignee TO the verifier — so a SECOND `task done` by the same maker
    # read as "the verifier's own close" and fell straight through to a real
    # close. DIVE-1988 closed that way: status=done, iteration 1 still open, the
    # verifier never graded. Hit from the other side on DIVE-2002. Key the guard
    # on the ACTOR, not on who the row is assigned to: while a loop is delivered
    # (maker recorded, verifier holding it), only the verifier may close it.
    # Refuse rather than re-deliver at iteration+1 — a silent re-delivery burns
    # the max_iterations budget and would let a wrong `done` escalate the loop.
    # Same shape as DIVE-1330's handoff guard (block + name the real verbs).
    if [[ -n "$_vfier" && "$_vfier" == "$_asignee" ]]; then
      local _maker _actor _st _iter
      _maker=$(db "SELECT COALESCE(maker_agent,'') FROM tasks WHERE id=${id};")
      _st=$(db  "SELECT COALESCE(status,'')        FROM tasks WHERE id=${id};")
      _iter=$(db "SELECT COALESCE(iteration,0)     FROM tasks WHERE id=${id};")
      _actor=$(task_actor)
      # Already-closed tasks pass through (a repeat `done` stays idempotent);
      # only a LIVE delivered loop is protected.
      #
      # `cli` is `task_actor`'s "could not attribute this invocation" sentinel —
      # a non-agent user, root cron, CI. It is deliberately EXEMPT, and CI is what
      # found this: with $USER unresolvable this guard fired ahead of the DIVE-1830
      # merge-gate on tests/task_deliver_merge_gate_unit.sh Tb/Tc, so a close whose
      # real problem was an unmerged delivery PR got refused citing DIVE-2007 (Tb
      # asserts the message names DIVE-1830) and a MERGED one was refused outright
      # (Tc). Two costs, both bad: the reader is sent after the wrong rule, and a
      # legitimate non-agent close is blocked by a rail aimed at something else.
      # The threat model here is a MAKER — a resolvable agent — closing its own
      # work; DIVE-1988's maker resolved to `dev` and is still caught. An
      # unattributable caller is a DIFFERENT question and not this ticket's to
      # answer. It stayed green on every dev box because $USER there resolves to
      # an agent, which is exactly why local green is not CI green.
      if [[ -n "$_maker" && "$_actor" != "$_vfier" && "$_actor" != "cli" \
            && "$_st" != "done" && "$_st" != "cancelled" ]]; then
        policy_refuse "$E_CONFLICT" done-over-delivered-loop DIVE-2007 "$ident" \
          "$ident is DELIVERED to verifier '${_vfier}' (iteration ${_iter}, maker '${_maker}') and has NOT been graded — a 'task done' from '${_actor}' would close it ungraded, which is the maker grading its own work (writer != grader, DIVE-477). Only '${_vfier}' can grade it. To CORRECT the result text do NOT re-run done: send the correction to '${_vfier}' (5dive agent send ${_vfier} \"...\") and let them fold it in. Real exits: '5dive task reject $ident --feedback=...' (verifier bounces it back), '5dive task verify $ident --no-done --cmd=\"<acceptance test>\"' (record machine evidence and hold at graded->merge), or '5dive task cancel $ident --result=...' (abandon)."
      fi
    fi
  fi
  # DIVE-555 gate enforcement (DIVE-393/394 class): a `task done` must NOT close
  # a task that still has an UNANSWERED human gate — that's how DIVE-535's
  # public-publish approval got bypassed (the task was marked done while its
  # approval gate sat 'pending', so the public ship happened with no recorded
  # sign-off). Block the close: the gate must be answered (`task answer`) or
  # WITHDRAWN (`task need --withdraw`).
  # Verifier routing already returned above; only a real `done` reaches here.
  #
  # DIVE-2773: this refusal used to name `task cancel` as the legitimate way out,
  # and that is now false — cancel is refused over a live gate too, immediately
  # below. It was never as safe as it read: a cancel does not ANSWER the gate, it
  # deletes the question, and it silently retires the human's buttons on the way
  # (_task_gate_retire_buttons, further down this same function). Naming it here
  # published the route that DIVE-2758 took.
  if [[ "$verb" == "done" || "$verb" == "cancel" ]]; then
    local _gt _ga
    _gt=$(db "SELECT COALESCE(need_type,'')        FROM tasks WHERE id=${id};")
    _ga=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_gt" && -z "$_ga" ]]; then
      if [[ "$verb" == "done" ]]; then
        policy_refuse "$E_CONFLICT" done-over-open-gate DIVE-555 "$ident" "$ident has a pending '${_gt}' gate awaiting a human — answer it (5dive task answer $ident ...), or withdraw it if it is moot (5dive task need $ident --withdraw)."
      fi
      # DIVE-2773: THE CANCEL HALF, and it is a STRONGER condition than the
      # reason requirement below rather than a case of it — it fires with a
      # perfectly good reason attached.
      #
      # MEASURED (main, 2026-08-05): the 06:18:33 empty cancel of DIVE-2758 also
      # destroyed a LIVE tier-2 human gate — `agent-olivia gate button retire
      # [ok]` twice at that timestamp, ~8 minutes after the gate reached
      # marketing, on lodar's own surface decision, and the row still reads
      # `answer: — pending`. So the loss was not merely the record of a decision:
      # it was the AFFORDANCE BY WHICH A HUMAN COULD STILL MAKE ONE. A reason
      # field cannot repair that, which is why this is not folded into the check
      # below.
      #
      # WHY IT REFUSES RATHER THAN WARNS: the retire is already silent-by-design
      # (best-effort, `|| true`, no stderr), and the operator population here is
      # exactly callers clearing a board at speed. A warning is read after the
      # write; the buttons are gone by then.
      #
      # THE EXITS ARE NAMED ON PURPOSE, against the DIVE-2067 rule that a refusal
      # should not publish a route around itself — because here the alternative is
      # WORSE than a published route. Refusing `done` (DIVE-555) and `cancel`
      # (this) with no exit leaves a gated row with NO close verb at all, so the
      # next agent invents one: a raw UPDATE, a --force flag request, or an
      # `answer` typed on the human's behalf, which is the forgery DIVE-1117's
      # tier floor exists to prevent. `--withdraw` is the honest exit and it is
      # recorded as a withdrawal in gate_history, never as an answer. See
      # community/wiki/a-default-action-that-terminates-on-a-human-held-surface-is-a-queue.md.
      #
      # DIVE-3340: NAME BOTH EXITS, AND THE HUMAN ONE FIRST. The paragraph above
      # argues that naming an exit beats naming none — and then named only the one
      # exit the reader of this message most often CANNOT TAKE. `--withdraw`
      # authorizes on `human | filer | filer's lead | coordinator`, and a person
      # typing into the Telegram bot is none of those (the command executes on an
      # agent seat; see _gate_answer_route's header for why that must not change).
      # Measured on a customer box 2026-08-12: cancel → "withdraw it first" →
      # withdraw → "not authorized", a closed loop out of two correct refusals.
      # Answering is the exit that needs no authorization, so it goes first, and the
      # withdraw route now carries its authorized set inline rather than reading as
      # unconditionally available. Same class as DIVE-2382: grade a refusal by the
      # conclusion its reader reaches, not by whether it is technically true.
      local _cg_filer; _cg_filer=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''), assignee, '') FROM tasks WHERE id=${id};")
      local _cg_lead _cg_coord
      # DIVE-3340 iter2 (main2): `|| x=""` is LOAD-BEARING, not defensive noise.
      # `_gate_route_reviewer` opens `[[ -n "$_filer" ]] || return`, and a bare
      # `return` inherits the FAILED test's rc — so an EMPTY filer returns 1 while
      # an unresolvable NON-empty filer returns 0 (the trailing `if` inside the
      # `for` sets the rc, and a false `if` with no `else` is 0). The bundle is
      # `set -euo pipefail` and an assignment's rc is its command substitution's,
      # so without this the refusal below never printed at all: rc=1, "exited
      # without reporting a reason", on the one path this ticket is about. The
      # `${_cg_filer:-unknown}` two lines down proves the empty-filer state was
      # anticipated by the text and not by the control flow. Same shape as the
      # DIVE-2751 note at need.sh's push-for-review route. Arm: EMPTY-FILER below.
      _cg_lead=$(_gate_route_reviewer "$_cg_filer") || _cg_lead=""
      _cg_coord=$(_task_resolve_coordinator) || _cg_coord=""
      policy_refuse "$E_CONFLICT" cancel-over-open-gate DIVE-2773 "$ident" \
        "$ident has a PENDING '${_gt}' gate (filed by '${_cg_filer:-unknown}') and a cancel deletes the question, silently retiring the human's buttons. TWO EXITS: (1) $(_gate_answer_route "$ident" "$_gt") — no authorization needed, and it is what the buttons in the human's chat are for; or (2) withdraw it as moot: 5dive task need $ident --withdraw — but ONLY '${_cg_filer:-unknown}', their lead (${_cg_lead:-none}), the org coordinator (${_cg_coord:-none}) or a genuine human unix caller may do that, so a chat-bot seat cannot."
    fi
  fi
  # DIVE-2773: A FIRST CLOSE REQUIRES A NON-EMPTY REASON, ON BOTH VERBS.
  #
  # This is NOT the DIVE-2483/DIVE-2464 guard ported to `cancel`, and the
  # difference is the whole ticket. That guard is DESTROY-protection: its own
  # first lines return early when the row carries no result yet
  # (`if [[ -z "$_cl_prev" ... ]]`), because with nothing recorded there are no
  # bytes at risk. Correct for what it does — and it means a FIRST close with a
  # blank reason was accepted by BOTH verbs all along (demonstrated by olivia on
  # scratch row DIVE-2774: open row, `task done --result=""`, rc=0, empty result
  # stored). Shipping "give cancel the check done already has" would have
  # delivered destroy-protection that misses every blank first close and leaves
  # `done`, the commoner verb, exactly as open. So this is a new predicate keyed
  # on the other thing entirely: THIS ROW IS BEING CLOSED AND NOTHING HAS EVER
  # BEEN WRITTEN ABOUT WHY.
  #
  # MEASURED POPULATION (main, from lifecycle_events, actor column read not
  # inferred): seven empty-result cancels in three days, five by main and two by
  # olivia, EVERY ONE of them a daily recurring row, arriving in bursts — three
  # inside 186 seconds on 08-05, two inside 23 seconds on 08-04. The record they
  # left is unreadable: DIVE-2472 was the same act by the same actor on the same
  # template WITH a reason ("a stale dated instance, not work declined") and is
  # still explicable six days on; DIVE-2683 and DIVE-2737 are not. Identical
  # verb, identical author, opposite legibility, and the only difference is
  # whether the field was filled.
  #
  # NO FLAG BYPASSES THIS, deliberately. The population is precisely callers
  # clearing a board at speed, and a flag is what they reach for; an escape hatch
  # would be taken by exactly the people this exists to slow down. The cost of
  # being wrong is one sentence.
  #
  # SCOPE, kept narrow so no false refusal is possible:
  #   * only a REAL close — a maker→verifier delivery routes and returns above,
  #     so a bare `task done` handoff is untouched;
  #   * only a FIRST close — an already done/cancelled row keeps its long-standing
  #     idempotent bare re-close (rc=0 no-op). "First" is meant literally;
  #   * only when the column is empty AND nothing is being written. A row that
  #     already carries text is the other guard's population, and a close that
  #     supplies text is what this asks for.
  if [[ "$verb" == "done" || "$verb" == "cancel" ]]; then
    local _fc_st _fc_prev
    _fc_st=$(db   "SELECT COALESCE(status,'') FROM tasks WHERE id=${id};")
    _fc_prev=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${id};")
    if [[ "$_fc_st" != "done" && "$_fc_st" != "cancelled" && -z "$_fc_prev" && -z "$result" ]]; then
      # NAME THE SHAPE OF A GOOD REASON, not just the flag. The useful cancel
      # reasons say what was NOT concluded — main's own DIVE-2472 text is the
      # model — and a caller under load writes "n/a" unless told otherwise, which
      # satisfies a non-empty check while recording nothing. A refusal that only
      # says "pass --result" buys the string and not the sentence.
      local _fc_shape _fc_past="closed"
      [[ "$verb" == "cancel" ]] && _fc_past="cancelled"
      if [[ "$verb" == "cancel" ]]; then
        _fc_shape="Say what was NOT concluded, not just that you stopped — 'n/a' records nothing."
      else
        _fc_shape="Say what shipped or was concluded and where to look — the dashboard and this row's creator read this field and nothing else."
      fi
      policy_refuse "$E_VALIDATION" close-without-reason DIVE-2773 "$ident" \
        "$ident would be ${_fc_past} with a permanently blank result — pass --result=<why> (or --result-file=<path>). ${_fc_shape} No flag bypasses this."
    fi
  fi
  # DIVE-1830 merge-gate (opt-in): a task that declared DELIVERED WORK cannot
  # close until that work is MERGED to main — done means merged-to-main, not "PR
  # opened". Only a REAL close reaches here (verifier routing + the DIVE-555
  # pending-gate check both returned/failed above). Two bindings count as a
  # declaration; the gate fires when EITHER is present, else it's untouched (a
  # plain close with no binding is unchanged — zero regression, opt-in):
  #   1. delivery_ref — the PR URL recorded by `task deliver --pr=`.
  #   2. a `Branch: <name>` line in the task body — the EXISTING delegated-push
  #      binding (DIVE-1462; resolved the same way cmd_push does). delivery_ref
  #      wins when both are present.
  if [[ "$verb" == "done" ]]; then
    local _dref _branch="" _body _task_slug
    _dref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=${id};")
    _body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
    # DIVE-1955: the task's OWN repo, resolved once, from the bindings it actually
    # carries (delivery_ref url > `Repo:` body line > a github url in the body).
    # Empty = unknown, and unknown is a real answer here: it is what stops a bare
    # `#N` from being resolved against a default slug further down.
    _task_slug=$(_gate_task_repo_slug "$_dref" "$_body")
    if [[ -z "$_dref" ]]; then
      _branch=$(_push_branch_from_body "$_body")
    fi
    # -----------------------------------------------------------------------
    # DIVE-2096 — THE ORDERING PRE-CHECK: cited-not-delivered, BEFORE the close.
    #
    # Two agents hit the identical wall from opposite sides inside ~2h on
    # 2026-07-26 (olivia on DIVE-2064, main on DIVE-2080). That is a tool defect,
    # not two operator slips. The DIVE-2414 disclosure below already MEASURES a
    # cited PR's state and says so — but it says so in the same breath as the
    # close, and `done` freezes the body. The diagnosis and the point of no
    # return arrive together, so the only remedy the warning can name (bounce it
    # back to the maker to fix the verifier's own metadata) is wildly
    # disproportionate to the error. Nothing anywhere hints at the correct
    # sequence — merge -> `task deliver --pr` -> `done` — until it is too late to
    # act on it. This is that hint, moved to the moment it is still actionable.
    #
    # THE SHAPE IS ORDERING, NOT INFERENCE, and that boundary is load-bearing:
    #   * DIVE-1965 (done) deliberately separates a PR the task DELIVERED from one
    #     it merely REPORTS ON. Kept intact — this refuses, it does not reclassify.
    #   * DIVE-1962 (CANCELLED) proposed INFERRING the binding from a PR number in
    #     prose. It was cancelled because that OVERCLAIMS: an incidental number
    #     stamps an unrelated close UNVERIFIED. So prose is the TRIGGER for the
    #     prompt and NEVER the SOURCE of the binding. Nothing below reads the
    #     number into `delivery_ref`; the operator does that, with `task deliver`,
    #     and only they can say which of the named refs is theirs.
    #
    # FIRES ONLY WITH NO DECLARED BINDING AT ALL — neither `delivery_ref` nor a
    # `Branch:` line. Both are structured, intentional declarations, and either
    # one sends this close down the DIVE-1830 declared path where the delivery IS
    # verified (PR state, or ancestry+attribution for a branch). Refusing there
    # would add friction to the fleet's dominant delegated-push flow and buy no
    # safety, so "the field is bound" leaves behaviour byte-identical.
    #
    # The trigger is `_gate_text_names_a_ref`, deliberately the BROAD predicate
    # (bash-only, no grep, no subprocess): it answers "was a PR mentioned", not
    # "which one". An over-match here costs one refusal that `--no-pr` answers in
    # a keystroke; an under-match costs the whole ticket. The sharp extractor is
    # used only to NAME numbers in the message, and it is allowed to come back
    # empty — a refusal must never depend on a parser that may be unusable.
    if [[ -z "$_dref" && -z "$_branch" ]] && _gate_text_names_a_ref "$result
$_body"; then
      local _cnd_refs=""
      if _gate_pr_refs_engine_ok; then
        _cnd_refs=$(_gate_pr_refs_qualified_from_text "$result
$_body" 2>/dev/null | sed 's/^.*|/#/' | head -3 | paste -sd, - || true)
      fi
      local _cnd_named="${_cnd_refs:+ (${_cnd_refs//,/, })}"
      if [[ $no_pr -eq 1 ]]; then
        # The assertion is recorded, not just honoured. `--no-pr` is a CLAIM about
        # this close ("no pull request here is mine"), and an unrecorded claim is
        # indistinguishable from a bypass when someone reads the row back.
        warn "$ident: closing with --no-pr — the PR reference(s)${_cnd_named:- named in the result/body} are asserted to be REPORTED ON, not delivered by this task (DIVE-2096, audited)."
        _task_store_audit_log "task.done-no-pr" ok 0 -- "$ident" "refs=${_cnd_refs:-unparsed}"
      elif [[ $force_merge_gate -eq 0 ]]; then
        policy_refuse "$E_CONFLICT" done-cited-not-delivered DIVE-2096 "$ident" "$ident cannot close YET: its result/body names a pull request${_cnd_named} but NOTHING BINDS one to this task — \`delivery_ref\` is empty and the body declares no \`Branch:\` line. A citation in prose is not a binding: only the field is (DIVE-1962 was CANCELLED for trying to infer one from prose). Closing now would leave the named PR's merge state UNCHECKED, and \`done\` freezes the body, so you would learn that only after it was unfixable (DIVE-2096). CORRECT ORDER: merge it, then \`5dive task deliver $ident --pr=<url>\`, then \`5dive task done $ident\`. If this close only REPORTS ON that PR and delivers no code of its own — a review, triage, audit or coordination close, DIVE-1965's category — say so and it proceeds: \`5dive task done $ident --no-pr\` (audited). \`--force-merge-gate\` also overrides."
      fi
    fi
    # DIVE-2682 (implements the DIVE-2671 design call): a binding can OUTLIVE the
    # iteration it was made for. The gate below asks "did the bound PR land"; it
    # never asks "did the sha the verifier graded land", and a maker→verifier loop
    # separates those two by design. DIVE-2057 is the clean instance: bound to #45
    # at first delivery, #45 was REJECTED, the fix landed in a new PR #51, and the
    # row still pointed at #45 — a credential-holding close would have greened off
    # a PR that does not contain the passed work.
    #
    # Keyed on ITERATION, not on the graded sha and not on timestamps. The sha
    # variant is refuted: we squash-merge, so a graded head is NEVER an ancestor
    # of main and every squash-merged PR would false-RED. The timestamp variant is
    # refuted too — DIVE-2057's binding legitimately predates its latest ACK.
    #
    # This check is PURELY LOCAL. No token, no API, no rail — so unlike every
    # GitHub-query arm below it, it cannot vary by caller, which is the exact
    # failure mode that made a missing credential do the work of a control.
    #
    # NULL is not stale: rows bound before this column existed cannot be judged,
    # and a gate that refuses on "I do not know" is a false red.
    if [[ -n "$_dref" ]]; then
      local _bind_iter _cur_iter
      _bind_iter=$(db "SELECT COALESCE(CAST(delivery_ref_iteration AS TEXT),'') FROM tasks WHERE id=${id};")
      _cur_iter=$(db "SELECT COALESCE(iteration,0) FROM tasks WHERE id=${id};")
      if [[ -n "$_bind_iter" ]] && (( _bind_iter < _cur_iter )); then
        policy_refuse "$E_CONFLICT" done-with-stale-delivery-binding DIVE-2682 "$ident" \
          "$ident cannot close: its delivery binding ${_dref} was recorded at loop iteration ${_bind_iter}, and the loop is now at ${_cur_iter}. The work bounced back to the maker and was re-delivered after that PR was bound, so closing here would grade a PR that does not contain the re-delivered work (DIVE-2057 is the clean instance of that). Re-point the binding to the PR carrying the CURRENT iteration — \`task deliver $ident --pr=https://github.com/<owner>/<repo>/pull/N\` — then \`task done\`."
      fi
    fi
    # DIVE-3823: THE RECORDED-EVIDENCE RAIL, read BEFORE the gate interrogates
    # GitHub — because on the seat this rescues there is no GitHub to interrogate.
    #
    # DIVE-477 lets only the verifier close a live delivered loop; this gate wants
    # the closer to READ the delivery PR. On a verifier seat over a PRIVATE repo
    # neither is negotiable and neither is wrong, so the row was closable by NO
    # seat (DIVE-3808: fix merged at 2033057e, stuck). See _gate_merge_proof_ok for
    # the full argument and the limits of what a proof claims.
    #
    # SCOPED TO THE CALLER THAT CANNOT GET AN ANSWER — not to the caller that holds
    # no credential. A recorded proof must never substitute for an answer the gate
    # could have gotten, or every close silently starts trusting an attestation
    # instead of a measurement. Iteration 1 spelled that as `! _gate_gh_credentialed`
    # and quinn measured the gap: the ANONYMOUS rail holds no credential either, so
    # on a PUBLIC repo an uncredentialed caller can still be answered, and the proof
    # pre-empted a query that would have refused an OPEN PR (curl called zero times).
    # The predicate is now `_gate_pr_state_answerable` — it ASKS, and the proof is
    # read only when nothing could answer about this ref. See that function for why
    # `_gate_gh_reachable` is wrong in the other direction (true wherever curl merely
    # exists, i.e. everywhere, which would make this rail dead code).
    #
    # ORDER IS DELIBERATE AND CHEAP-FIRST: the db read, then the free credential test,
    # then the one request. A credentialed caller and an unproved row both stop before
    # any query, so no close that passes today spends anything extra.
    local _mg_proof_at="" _mg_proof_ref="" _mg_proof_by="" _mg_proof_cmd="" _mg_proof_ok=0
    if [[ -n "$_dref" ]]; then
      IFS=$'\x1f' read -r _mg_proof_at _mg_proof_ref _mg_proof_by _mg_proof_cmd <<<"$(
        db "SELECT COALESCE(merge_proof_at,'')||x'1f'||COALESCE(merge_proof_ref,'')||x'1f'||
                   COALESCE(merge_proof_by,'')||x'1f'||COALESCE(merge_proof_cmd,'')
            FROM tasks WHERE ident=$(sqlq "$ident") LIMIT 1;" 2>/dev/null || printf '')"
      # DIVE-3888: THE `! _gate_gh_credentialed` CLAUSE IS GONE, and it was the bug.
      #
      # It asked what the caller HOLDS. A verifier seat here holds a GitHub App
      # INSTALLATION token (`ghs_`) minted against the single pinned installation
      # (the 5dive-ai org), so for a PERSONAL-account repo — lodar/5dive-api — the
      # token is live and blind: measured 2026-09-02 from agent-quinn's own uid,
      # `gh api rate_limit` answers 5100 while `gh api repos/lodar/5dive-api` is a
      # 404. `_gate_gh_credentialed` is therefore TRUE, this rail was skipped, and
      # the close fell through to the DIVE-2318 `done-pr-state-unresolved` refusal
      # whose printed remedy ("check by hand and re-run") can never succeed on that
      # seat because the blindness is permanent, not transient.
      #
      # The consequence is the inversion DIVE-3888 was filed on: a seat holding a
      # WRONG-SCOPE token was strictly worse off than a seat holding NO token, which
      # reaches this rail and closes on recorded evidence. Holding a credential
      # disabled the fallback for not holding one.
      #
      # DIVE-3496's escalation does not rescue it either. That fix is real and it is
      # installed (0.25.3) — `_gate_gh` retries the bot rail and then the anonymous
      # rail when the caller's own stderr says it cannot see the repository — but on
      # quinn BOTH escalation rails are gone: `5dive task merge-gate-selftest` run as
      # agent-quinn prints "machine-account rail: not permitted on this seat" (its
      # sudoers is a five-command allowlist with no `_gh_do`, which is correct —
      # `_gh_do` refuses only admin-class ops, so it permits `pr merge` and is a
      # can-push grant a grader must not hold), and the anonymous rail cannot read a
      # private repo. So no rail can answer, which is exactly the state this rail
      # exists for.
      #
      # `_gate_pr_state_answerable` is now the WHOLE credential predicate, and it is
      # the honest one: it ASKS, with the caller's own token, so the proof is read
      # only when nothing could answer. A caller whose token works still queries,
      # gets a state, and never reaches the proof — no close that passes today
      # changes path, and none of them can be turned into a merge by a stamp.
      #
      # COST, since the cheap-first ordering is what the clause also bought: the db
      # read and `_gate_merge_proof_ok` still run FIRST, so this asks only on rows
      # that ALREADY carry a proof stamped against the current binding. On those
      # rows the same query runs a few lines below anyway; on every other row —
      # which is nearly all of them — nothing extra is spent.
      if _gate_merge_proof_ok "$_mg_proof_at" "$_mg_proof_ref" "$_dref" \
         && ! _gate_pr_state_answerable "$_dref" "$(_gate_gh_token)"; then
        _mg_proof_ok=1
      fi
    fi
    if [[ -n "$_dref" ]] && (( _mg_proof_ok )); then
      # A declared delivery is still something that was verified — just not by a
      # query. Setting this keeps the DIVE-1830 accounting honest either way.
      _mg_had_subject=1
      _task_store_audit_log "task.merge-proof-close" ok 0 -- \
        "$ident" "ref=$_mg_proof_ref" "proved_by=$_mg_proof_by" "at=$_mg_proof_at" "cmd=$_mg_proof_cmd"
      # Say WHY no rail could answer, MEASURED rather than assumed: the predicate
      # above ASKED, and `_gate_anon_why` names what came back (404/private, a rate
      # limit, a network failure, or no transport at all). Iteration 1 asserted "the
      # anonymous rail cannot see a private repo" without asking, and quinn measured
      # it saying that about a PUBLIC repo it had never queried — a false sentence in
      # the one message whose whole job is to say what is known and how.
      local _mg_why; _mg_why="$(_gate_anon_why)"
      [[ -n "$_mg_why" ]] || _mg_why="No credential-free rail was available to ask with on this host either."
      # DIVE-3888: the sentence used to assert "this seat holds no gh credential of
      # its own". That is now false on the seat this rail most often rescues — a
      # blind-but-live installation token — and a message whose whole job is to say
      # what is known must not assert something it did not measure. So it names what
      # WAS measured: every rail this caller can reach was asked and none answered.
      warn "$ident: the merge gate could not GET AN ANSWER about $_dref — every rail this seat can reach (its own gh credential if it holds one, the machine-account rail, and the credential-free rail) WAS asked about this pull request and none of them answered. ${_mg_why} So it is closing on RECORDED MACHINE EVIDENCE instead (DIVE-3823, audited): '$_mg_proof_by' ran \`$_mg_proof_cmd\` against $_mg_proof_ref at $_mg_proof_at and it exited 0. That is an attestation by a named seat, not an API answer — if the two ever disagree, the API is right."
    elif [[ -n "$_dref" || -n "$_branch" ]]; then
      _mg_had_subject=1     # a declared delivery IS something to verify
      if ! command -v gh >/dev/null 2>&1; then
        fail "$E_GENERIC" "$ident declared delivered work (${_dref:-branch $_branch}) but gh is unavailable to confirm the merge — install gh"
      fi
      # DIVE-1834: run the read-only PR-state queries with an explicitly resolved
      # token and repo so a plain `sudo task done` works without a manual
      # GH_TOKEN. Without this, sudo/root (no gh login) and non-authed agents
      # both got state=unknown and false-blocked. Repo is passed explicitly so
      # the branch-path query is CWD-independent (was `gh pr list` with no --repo,
      # which errors outside a repo checkout).
      local _ghtok; _ghtok=$(_gate_gh_token)
      # DIVE-2318: NO CREDENTIAL IS NOT A NEGATIVE VERDICT, and until now this gate
      # rendered it as one. Every probe below this line — `gh pr view`, `gh pr list`,
      # the attribution scan, the ancestry probe — is a GitHub API call. With an empty
      # token every one of them returns empty, and the refusals downstream read those
      # empties as "not merged" and blamed the PR or the branch. Measured on DIVE-2286:
      # the gate printed "its delivery PR is not merged to main yet (pull/295,
      # state=unknown)" about a PR that had merged 90 minutes earlier. That sentence is
      # FALSE about the world, and two agents burned a night misdiagnosing from it —
      # dev2 went hunting a deleted branch, then main filed a confident wrong mechanism
      # (squash/ancestry) on top of dev2's reading.
      #
      # `task merge-audit` already gets this right on the SAME missing credential: it
      # names the credential, refuses, and tells you to authenticate. Two verbs, one
      # fault, opposite diagnostics. This copies the one that is correct.
      #
      # THIS CHANGES NO ACCEPTANCE, only attribution. With an empty token both paths
      # already refused 100% of the time (all probes empty => _state empty on the
      # declared path, _bmerged/_attr empty on the branch path). No close that passes
      # today starts failing; a refusal that named the wrong cause now names the right
      # one. That is the whole change on this line.
      #
      # WHY A CALLER HAS NO TOKEN, since the refusal has to say something actionable:
      # _gate_gh_token's last resort is `sudo -n -u claude gh auth token`, and whether
      # that resolves is a property of the CALLER'S OWN SUDOERS, not of being a builder.
      # Measured 2026-07-29: agent-dev (`ALL=(ALL) NOPASSWD: ALL`) resolves a token;
      # agent-dev2/dev3 (`ALL=(root) NOPASSWD: /usr/local/bin/5dive *`) cannot run
      # anything as `claude`, so they resolve EMPTY. "Builders hold no gh token" is the
      # right conclusion for the wrong reason — it is scoped sudo, and it is per-agent.
      # DIVE-2605: ask whether GitHub is REACHABLE, not whether a token was resolved.
      # Those were the same question until the bot rail existed; the refusal below now
      # fires only when BOTH rails are gone, which for a builder means the `_gh_do`
      # grant is missing — a provisioning fault with a name, not a standing condition.
      if ! _gate_gh_reachable "$_ghtok"; then
        _gate_refuse_no_rail "$ident" "${_dref:-branch '$_branch'}"
      fi
      # DIVE-3458: THE DELIVERY IS A SUBMISSION INTO A REPO WE DO NOT OWN.
      #
      # The gate below asks "did it merge to main", and for a repo whose merge
      # button belongs to a stranger that question can never be answered by any
      # work we do. `--force-merge-gate` discharges it per row and is the wrong
      # instrument at this frequency: reaching for an override six times in a
      # fortnight for a legitimate, intended, REPEATING shape says the gate is
      # missing a case, and it records as "someone bypassed a safety check",
      # which is the wrong audit trail for the normal path of an approved
      # campaign.
      #
      # WHAT IS NOT DROPPED — and this is the half that matters. The gate's value
      # here was never the refusal, it is the RECORD. Losing the sentence is how
      # "we submitted it" quietly becomes "we're listed there" in a later report.
      # So this arm still MEASURES the PR's state and writes it into the result:
      # what was submitted, where, whether it is merged, and whose decision that
      # is. A close on this arm asserts the SUBMISSION, never the acceptance.
      #
      # Deliberately NOT exempted from the gh-reachability guard above: recording
      # "not merged" without reading it would be the assertion this arm exists to
      # avoid making.
      if [[ -n "$_dref" ]] && _gate_foreign_delivery "$_dref"; then
        local _fslug _fowner _fstate _fwhat
        _fslug=$(_gate_slug_from_url "$_dref")
        _fowner="${_fslug%%/*}"
        _fstate=$(_gate_gh "$_ghtok" 0 pr view "$_dref" --json state -q '.state' 2>/dev/null || echo "")
        # Same DIVE-2720 normalisation as the owned path: gh renders a missing
        # .state as the four-character string 'null', and a successful query that
        # answered nothing is the same epistemic state as one that never ran.
        [[ "$_fstate" == "null" ]] && _fstate=""
        case "$_fstate" in
          MERGED) _fwhat="MERGED — ${_fowner} accepted it" ;;
          OPEN)   _fwhat="OPEN (not merged) — awaiting ${_fowner}, who alone can merge it" ;;
          CLOSED) _fwhat="CLOSED WITHOUT MERGE by ${_fowner} — the submission was declined or superseded" ;;
          *)      _fwhat="state NOT READ (the query did not answer) — this is 'not checked', not 'not merged'" ;;
        esac
        _task_store_audit_log "task.foreign-delivery" ok 0 -- "$ident" "foreign_repo=$_fslug ref=$_dref state=${_fstate:-unread}"
        warn "$ident: delivery $_dref is a submission into $_fslug, a repository we do not own — the merged-to-main gate does not apply (DIVE-3458). MEASURED: $_fwhat. This close asserts the SUBMISSION was made; it does NOT assert that $_fowner accepted it."
        _mg_foreign="[delivery: $_dref submitted to $_fslug, a repository outside our control. MEASURED at close: ${_fwhat}. Merging is ${_fowner}'s decision, not ours — this close records the SUBMISSION and asserts nothing about its acceptance. (DIVE-3458)]"
      elif [[ -n "$_dref" ]]; then
        # DIVE-1955: a delivery_ref that is a full pull URL carries its own repo and
        # `gh pr view <url>` needs no --repo. A BARE delivery_ref (`#6`, `6`) does
        # not identify a pull request at all, and this is the fail-CLOSED declared
        # path — so rather than resolve it against the CLI constant and hand back a
        # confident verdict about some other repo's #6, refuse and ask for the URL.
        # No live task carries a bare delivery_ref (all 7 are URLs, checked
        # 2026-07-25); this exists so the shape can never be introduced silently.
        if ! [[ "$_dref" =~ ^https?:// ]]; then
          local _qd; _qd=$(_gate_resolve_qualified "|${_dref#\#}" "$_ghtok" "$ident" "$_task_slug")
          if [[ -z "$_qd" || "$_qd" == AMBIGUOUS\|* ]]; then
            policy_refuse "$E_CONFLICT" done-with-ambiguous-delivery-ref DIVE-1955 "$ident" "$ident cannot close: delivery_ref \"$_dref\" is a bare PR number and repos collide — re-bind with the full PR url"
          fi
          _dref="https://github.com/${_qd%%|*}/pull/${_dref#\#}"
          warn "$ident: bare delivery_ref resolved to $_dref by ident evidence (DIVE-1955) — bind the full URL next time."
        fi
        local _state _merged
        # DIVE-2770 considered joining these two reads into one (they ask for the
        # SAME PR, and the credential-free rail draws on a 60-request hourly budget
        # shared by the whole host). It is REVERTED on purpose: five sibling
        # harnesses stub `gh` by dispatching on the exact `-q` filter string, so
        # changing the filter silently returns nothing and reads as a merge-gate
        # failure in files that have nothing to do with this rail. Saving two
        # requests is not worth editing five fixtures, each edit being a chance to
        # weaken a guard. The cost is instead made VISIBLE and asserted —
        # tests/task_merge_gate_anon_rail_unit.sh T9 pins how many requests one
        # graded close spends, so a future change that multiplies it is caught.
        _state=$(_gate_gh "$_ghtok" 0 pr view "$_dref" --json state,mergedAt -q '.state' 2>/dev/null || echo "")
        _merged=$(_gate_gh "$_ghtok" 0 pr view "$_dref" --json state,mergedAt -q '.mergedAt' 2>/dev/null || echo "")
        # DIVE-2720: NORMALISE the literal 'null' to empty, at CAPTURE, so every
        # reader below inherits it. `gh -q .state` renders a MISSING .state as the
        # four-character string 'null' — not empty — so a SUCCESSFUL query with an
        # unusable payload slipped the `-z "$_state"` guard below and landed on the
        # DIVE-1830 refusal, which printed "not merged to main yet (..., state=null
        # — MEASURED, not assumed)". Same defect class as DIVE-2318/2705 by a third
        # route: the earlier two reached it through a FAILED call, this one through a
        # call that succeeded and answered nothing. jq's null and a query that never
        # returned are the same epistemic state — unresolved — so they get the same
        # representation here rather than a second parallel branch that can drift
        # from the first. Line ~3265 already special-cased 'null' for _merged and
        # nothing did for _state; that asymmetry was the hole.
        if [[ "$_state" == "null" ]]; then _state=""; fi
        # DIVE-2318: an EMPTY state is "the question was not answered", not "the answer
        # was no". A token is present by here (guarded above), so an empty state means
        # the query itself failed — network, timeout, a PR/repo this token cannot see,
        # a deleted PR, an unparseable payload. The old single branch collapsed that
        # into "not merged to main yet ... state=unknown", which asserts a merge verdict
        # nobody measured. Own slug, because a refusal record that cannot answer WHICH
        # of the two happened is the same defect one level down.
        if [[ -z "$_state" ]]; then
          # DIVE-2770: WHICH unresolved is this? A caller that holds a rail got an
          # empty answer from it; a caller that holds nothing never had one to get an
          # empty answer from — the anonymous rail simply cannot see a private repo.
          # Printing "a gh credential resolved" at a seat that has never held one is
          # DIVE-2318's own defect one refusal further down, so route by what the
          # caller actually holds rather than by what it could reach.
          if ! _gate_gh_credentialed "$_ghtok"; then
            _gate_refuse_no_rail "$ident" "$_dref"
          fi
          policy_refuse "$E_CONFLICT" done-pr-state-unresolved DIVE-2318 "$ident" "$ident cannot close: gh could not read $_dref, so the merge is UNKNOWN, not absent — check by hand (gh pr view $_dref --json state,mergedAt) and re-run, or task cancel to abandon."
        fi
        if [[ "$_state" != "MERGED" || -z "$_merged" || "$_merged" == "null" ]]; then
          # DIVE-3458 ARM 2: THE PR IS NOT MERGED AND THE WORK IS ON MAIN ANYWAY.
          #
          # Measured on DIVE-3292: delivery_ref pull/629 CLOSED, merged=null, while
          # fd945c2 ("docs(changelog): … (DIVE-3292)") is an ancestor of origin/main.
          # The change LANDED — as a direct commit, with the PR closed rather than
          # merged. This gate read only the PR's merge flag, so it could not tell
          # "delivered by another route" from "never delivered", and the remedy it
          # printed was IMPOSSIBLE TO PERFORM: you cannot merge a closed PR whose
          # content is already in main. `--force-merge-gate` does not reach here
          # either (main2's source read: the flag escapes gates that RAN AND
          # DISAGREED, never this binding check), so the row was unclosable from any
          # seat by any means.
          #
          # The predicate is the one this gate already trusts everywhere else — is
          # the work on main — asked with the machinery DIVE-2101/2120 built:
          # ATTRIBUTION, a commit ON MAIN whose SUBJECT names the ident.
          #
          # DIVE-3534: THIS ARM USED TO REQUIRE THE PR HEAD'S ANCESTRY TOO, AND THAT
          # REFUSED ITS OWN CANONICAL ROW. Measured by olivia on the bundle that
          # carries this arm (0.19.39): DIVE-3292's PR 629 head is e2bad22, which is
          # NOT an ancestor of main; what landed is fd945c2, a DIFFERENT commit. That
          # is not an accident of one row — "landed by another route" MEANS the work
          # came in as a different commit, so the abandoned PR tip is precisely the
          # sha that is not on main. Requiring ancestry-of-the-PR-head AND attribution
          # made the two operands mutually exclusive on the exact shape this arm was
          # written for, and it left DIVE-3292 unclosable from any seat by any means —
          # the precise condition DIVE-3458 was filed to remove.
          #
          # So attribution is the ONLY acceptor here, exactly as DIVE-2120/2184 already
          # made it on the `Branch:` path below (see the long note at the _attr_slug
          # search — "if you are changing acceptance, change attribution"). This arm had
          # replicated the pre-DIVE-2120 shape that ticket exists to correct.
          #
          # THE DIVE-2101 VACUITY CONCERN IS ANSWERED BY THE SAME MOVE, not dropped:
          # vacuity was a hazard of ANCESTRY (an EMPTY branch's tip IS main's tip, so
          # ancestry is trivially true of it). Attribution is measured against main's
          # commit SUBJECTS, and an empty branch contributes no commit naming the ident
          # to main — so there is nothing to mistake for delivery. Vacuity is
          # structurally impossible here rather than separately guarded.
          #
          # Ancestry survives as DIAGNOSTIC context in the messages only. It cannot
          # accept anything on its own, and it can no longer BLOCK an acceptance —
          # which also makes a deleted branch (routine on a closed PR, DIVE-2120) stop
          # being fatal here: an unreadable head costs a diagnostic, not the close.
          #
          # Fail-safe direction is unchanged: attribution returning EMPTY (no token,
          # API down) or `bound:<n>` (the scan hit its walk bound without exhausting
          # main) DECLINES the acceptance and falls through to the refusal below
          # exactly as if this arm did not exist. It can only ever ADD an acceptance on
          # measured evidence, never manufacture a refusal.
          local _cu_slug _cu_shas _cu_head="" _cu_anc="" _cu_attr="" _cu_diag=""
          _cu_slug=$(_gate_slug_from_url "$_dref")
          if [[ -n "$_cu_slug" ]]; then
            _cu_attr=$(_gate_branch_ident_on_main "$_cu_slug" "" "$_ghtok" "$ident")
            # Diagnostic only, and read AFTER the acceptor: a closed PR's branch is
            # routinely deleted, so this is the probe most likely to answer nothing.
            _cu_shas=$(_gate_pr_shas "$_dref" "$_ghtok" "$_cu_slug")
            _cu_head="${_cu_shas%%|*}"
            [[ -n "$_cu_head" ]] && _cu_anc=$(_gate_branch_ancestry "$_cu_slug" "$_cu_head" "$_ghtok")
          fi
          # Rendered once, into a variable: a nested ${x:+ … ${y} … } inside the
          # sentences below is a parse error, not a formatting preference.
          [[ -n "$_cu_head" ]] \
            && _cu_diag=" PR head ${_cu_head:0:12} ancestry=${_cu_anc:-unread} — DIAGNOSTIC ONLY, it neither accepts nor blocks (DIVE-3534)."
          if [[ "$_cu_attr" == "1" ]]; then
            _task_store_audit_log "task.landed-without-merge" ok 0 -- "$ident" "ref=$_dref state=$_state head=${_cu_head:-unread} ancestry=${_cu_anc:-unread} slug=$_cu_slug"
            # Say what was MEASURED and claim no more. A subject scan cannot tell a
            # direct commit from a squash that landed in some other PR, and — the
            # DIVE-3534 case — the PR's own head is typically NOT on main here.
            # Claiming ancestry in this sentence described a shape that cannot occur.
            warn "$ident: $_dref is NOT merged (state=$_state, measured) but a commit on ${FIVE_GATE_MAIN_BRANCH:-main} in $_cu_slug names $ident in its SUBJECT — the work LANDED BY ANOTHER ROUTE (DIVE-3458/3534). done=merged-to-main satisfied on ATTRIBUTION, not on the PR's merge flag.$_cu_diag$(_gate_merged_not_deployed "$_cu_slug")"
            _mg_foreign="[delivery: $_dref is CLOSED/UNMERGED (state=$_state), and the work is nonetheless ON ${FIVE_GATE_MAIN_BRANCH:-main} in $_cu_slug — a commit subject on main names $ident. Closed on ATTRIBUTION, NOT on the pull request's merge flag and NOT on the PR head's ancestry.$_cu_diag (DIVE-3458/3534)]"
          else
            # Name what was MEASURED and why, so the refusal cannot print advice the
            # reader is unable to follow. A CLOSED PR gets the remedy that exists.
            # Keyed on ATTRIBUTION, because that is the operand that accepts; ancestry
            # is appended as context and is never the stated reason.
            local _cu_why="" _cu_fix="merge it, then task done"
            case "$_cu_attr" in
              0) _cu_why=" NO commit subject on main names $ident, so the work has not landed by another route either." ;;
              bound:*) _cu_why=" No commit subject on main names $ident within the scan bound (${_cu_attr#bound:} COMMITS WALKED in $_cu_slug) — main's history was NOT exhausted, so this is unresolved, not ruled out; re-run, or raise FIVE_GATE_ANCESTRY_SCAN." ;;
              *) _cu_why=" Whether any commit subject on main names $ident COULD NOT BE READ, so 'landed by another route' is unresolved here, not ruled out." ;;
            esac
            [[ "$_cu_anc" == "1" ]] \
              && _cu_why="$_cu_why Its head ${_cu_head:0:12} IS on main, which on its own is what an EMPTY branch looks like — ancestry alone would accept a row that delivered nothing (DIVE-2101), so it cannot close this."
            [[ "$_state" == "CLOSED" ]] \
              && _cu_fix="it is CLOSED, so it cannot be merged — if the work landed another way, land or cite a commit on main whose SUBJECT names $ident and re-run; if it landed in a different PR, re-point the binding (\`task deliver $ident --pr=<url>\`); if it never landed, this row is not done"
            policy_refuse "$E_CONFLICT" done-before-pr-merged DIVE-1830 "$ident" "$ident cannot close: $_dref is not merged to main (state=$_state, measured).$_cu_why — $_cu_fix"
          fi
        fi
        # DIVE-2656: MERGED is not the same as MERGED-WHAT-THE-VERIFIER-GRADED.
        #
        # ORIGIN, measured: PR #425 (DIVE-2654) carried the commit main2 had
        # REJECTED while GitHub read CLEAN / MERGEABLE / 14 checks green. The
        # graded fix existed only on dev2's local branch and was never pushed.
        # Every predicate above this line was satisfied and every one of them was
        # answering a question about the PR, not about the VERDICT. A merge was
        # one command from landing rejected code and it was caught by hand.
        #
        # The check is an EQUALITY between two shas: the one the verifier NAMED
        # in its result (`graded-sha: <hex>`) and the one the PR actually carried
        # (head, or the merge commit — see _gate_pr_shas for why both). It is
        # explicitly NOT ancestry: a squash rewrites the sha, so ancestry against
        # a stated sha false-REDs every squash-merged PR
        # (community/wiki/a-stored-graded-sha-cannot-survive-a-squash-merge.md).
        #
        # WHY IT IS WORTH MORE THAN THE ROWS IT CATCHES, and this is main's
        # argument rather than mine: A CHECK THAT FORCES A PATH TO RUN FINDS MORE
        # THAN A CHECK THAT INSPECTS IT. On the night this was filed two fail-opens
        # sat on one path and suppressed each other — agent-main2 could not sign a
        # gate proof (three gates answered with an EMPTY signature, never failing),
        # and the graded fix was never pushed. Each defect's SYMPTOM was the other
        # defect's ABSENCE, so inspecting either in isolation surfaced nothing.
        # Comparing the stated sha to the merged one EXERCISES the delivery step on
        # every close, which is what makes a pair like that observable at all.
        #
        # OPT-IN BY CONSTRUCTION, and that is deliberate: it fires only when the
        # result MAKES the claim. A verifier that says nothing gets a nudge, never
        # a refusal — the enabling half costs nothing, so it must not be able to
        # block a close on a row whose verifier has not adopted the form yet.
        local _graded; _graded=$(_gate_graded_sha "$result")
        if [[ -n "$_graded" ]]; then
          local _prshas _headsha _mcsha
          _prshas=$(_gate_pr_shas "$_dref" "$_ghtok" "$(_gate_slug_from_url "$_dref")")
          _headsha="${_prshas%%|*}"; _mcsha="${_prshas##*|}"
          _headsha="${_headsha,,}"; _mcsha="${_mcsha,,}"
          if [[ -z "$_headsha" && -z "$_mcsha" ]]; then
            # DIVE-2318's rule, one level down: a query that did not run is not a
            # mismatch. Say NOT CHECKED out loud rather than accepting silently —
            # the close proceeds, but nobody may later read it as "the shas matched".
            warn "$ident: the result states graded-sha $_graded, but $_dref's head/merge sha COULD NOT BE READ — the comparison did NOT run (DIVE-2656). This is 'not checked', not 'matched'; verify by hand with \`gh pr view $_dref --json headRefOid,mergeCommit\`."
          elif [[ ( -n "$_headsha" && "$_headsha" == "$_graded"* ) || ( -n "$_mcsha" && "$_mcsha" == "$_graded"* ) ]]; then
            step "$ident: graded-sha $_graded matches $_dref (head ${_headsha:0:12}${_mcsha:+, merge ${_mcsha:0:12}}) — the merged work IS the graded work (DIVE-2656)."
          elif [[ $force_merge_gate -eq 1 ]]; then
            _task_store_audit_log "task.force-merge-gate" ok 0 -- "$ident" "override_graded_sha_mismatch=$_dref graded=$_graded head=$_headsha merge=$_mcsha"
            warn "$ident: graded-sha $_graded matches NEITHER $_dref's head ($_headsha) nor its merge commit ($_mcsha) — closing anyway (--force-merge-gate, audited)."
          else
            policy_refuse "$E_CONFLICT" done-graded-sha-not-the-merged-sha DIVE-2656 "$ident" "$ident cannot close: its result states it graded $_graded, but $_dref merged ${_headsha:+head $_headsha}${_headsha:+${_mcsha:+ / }}${_mcsha:+merge commit $_mcsha} — the sha that was GRADED is not the sha that LANDED (DIVE-2656; MEASURED, both operands read from GitHub). A merged PR is not evidence the verdict was cleared: on a maker->verifier loop the maker can push after the verdict, or fix in a NEW PR and leave this row bound to the old one, and every other check on this gate would still pass. Resolve it, do not route around it: if the graded work is in a different PR, re-point the binding (\`task deliver $ident --pr=<url>\`) and close against that; if this PR is right and the sha statement is stale, re-grade the head that actually merged and state THAT sha. \`task done $ident --force-merge-gate\` overrides (audited) — use it only when you have confirmed by hand that the merged content is the graded content."
          fi
        elif [[ "$(db "SELECT CASE WHEN maker_agent IS NOT NULL AND verifier IS NOT NULL AND verifier<>'' THEN 1 ELSE 0 END FROM tasks WHERE id=${id};")" == "1" ]]; then
          # PART 2, the enabling half — a NUDGE until DIVE-2940, a REFUSAL after it.
          #
          # WHY IT CHANGED, measured by olivia over three closes by one seat:
          # DIVE-2862 (08-07), DIVE-2891 (08-08), DIVE-2867 (08-09). The warn below
          # is correct about the world and useless to the person reading it, because
          # of WHEN it prints: the result row is already written by the time it
          # appears. Its printed remedy ("state the sha you graded") is advice for
          # the NEXT row, not an action available on this one — the
          # community/wiki/a-gates-printed-remedy-must-be-reachable-from-the-state-
          # it-fires-in shape. Prose remedy issued three times, missed three times,
          # because the omission happens while DRAFTING and nothing checked at the
          # keystroke.
          #
          # A pre-close refusal costs a retry and returns the one thing the warn
          # cannot: the draft, still editable, before anything is committed.
          #
          # WHAT THE ORIGINAL OPT-IN-BY-CONSTRUCTION NOTE ABOVE GOT RIGHT, and why
          # this does not contradict it: that note argues the ENABLING half must not
          # block "a row whose verifier has not adopted the form yet". True while the
          # form was new. The scope here is far narrower than "has a verifier" — it
          # is the intersection of (maker AND verifier set) AND (a delivery PR bound)
          # AND (that PR MEASURED as merged). Every predicate above this line has
          # already passed. On that population the sha is not a convention, it is the
          # missing operand of a guard the row is otherwise fully wired for.
          #
          # NOT a repair-vs-loss argument, and this is worth stating because the
          # filing said the field was frozen and it is NOT: `task done <id>
          # --append-result --result=...` writes a closed row and re-runs this gate
          # (DIVE-2464/2476; measured by olivia on DIVE-2760, where an appended sha
          # produced the confirmation the first close could not). So the warn was
          # never unrepairable data loss. It was an ERRAND — undiscoverable from the
          # warn's own text, which names no such path — and the refusal exists to
          # convert an errand nobody runs into a retry nobody can skip.
          if [[ $no_graded_sha -eq 1 ]]; then
            _task_store_audit_log "task.no-graded-sha" ok 0 -- "$ident" "closed_without_graded_sha=$_dref"
            warn "$ident: closed on a maker->verifier loop with no \`graded-sha: <sha>\` in the result (--no-graded-sha, audited), so the DIVE-2656 head-vs-graded comparison did NOT run — $_dref merged unverified against any stated verdict."
          else
            policy_refuse "$E_CONFLICT" done-without-graded-sha DIVE-2940 "$ident" "$ident cannot close: it is a maker->verifier loop row whose delivery PR $_dref is MEASURED as merged, but the result states no \`graded-sha: <7-40 hex>\`, so the DIVE-2656 head-vs-graded comparison has no second operand and CANNOT RUN (DIVE-2940). This is 'not checked', not 'matched' — nothing here has established that what merged is what was graded. NOTHING IS WRITTEN YET and your draft is still editable, which is the whole reason this fires before the close rather than after it: re-run with the sha you actually graded on the first line of the result (\`graded-sha: <sha>\`), and the gate will compare it to $_dref's head and merge commit and tell you which. Read the sha you graded from the PR itself, do NOT copy it from this message or from a handoff — \`gh pr view $_dref --json headRefOid,mergeCommit\`, or credential-free \`git ls-remote <repo-url> refs/pull/<N>/head\`. If you genuinely graded nothing sha-shaped (a docs row, a decision, work you did not grade yourself), that is a real case and it has a declared, audited escape: \`task done $ident --no-graded-sha\`. Use the escape rather than inventing a sha — a wrong sha here does not fail loudly, it MATCHES nothing and converts this refusal into the DIVE-2656 mismatch refusal one branch up."
          fi
        fi
        # DIVE-1935: MERGED is not the same as GREEN.
        # Slug pairing: this DECLARED-binding site is `done-after-red-merge`; the
        # prose/result site below is `done-after-named-red-merge`, mirroring the
        # existing done-before-pr-merged / done-before-named-pr-merged pair. They
        # must NOT share a slug: policy_refusals is the series DIVE-1922 was about,
        # and one name for two causes cannot answer WHICH binding caught a red merge
        # — a record that preserves that something happened but not what is a smaller
        # version of the defect this whole ticket is against. tests/policy_refusals_unit.sh
        # asserts slug uniqueness structurally and is what caught the collision. #156 was red on its own new
        # unit test, and a red PR can still be merged (admin/bypass merge), which
        # lands work whose own test says it doesn't do what the result claims.
        # Refuse only on a POSITIVE failure signal — pending/absent checks are a
        # loud note, not a block, so a slow or check-less repo never stalls.
        # `--force-merge-gate` is the audited escape (a flaky post-merge run must
        # not make a landed task permanently unclosable).
        # DIVE-1955: the ref is a URL by here, so it carries its own repo — pass that
        # slug, not the CLI constant, so nothing on this path depends on the default.
        local _rollup; _rollup=$(_gate_pr_state "$_dref" "$_ghtok" "$(_gate_slug_from_url "$_dref")")
        case "${_rollup##*|}" in
          FAILURE)
            if [[ $force_merge_gate -eq 1 ]]; then
              # DIVE-2054 (judgment call, not a mechanical sweep): a pure task-store
              # override record (ident + which PR was forced) — no delivery/identity
              # component like the 5389/5638/3264 exemptions carry, and its sibling
              # "task.merge-gate-unverified" a few lines below was already fenced by
              # DIVE-2010. Fenced for consistency within the same merge-gate family.
              _task_store_audit_log "task.force-merge-gate" ok 0 -- "$ident" "override_red_merge=$_dref"
              warn "$ident: delivery PR $_dref merged with FAILING checks — closing anyway (--force-merge-gate, audited)."
            else
              policy_refuse "$E_CONFLICT" done-after-red-merge DIVE-1935 "$ident" "$ident cannot close: $_dref is merged but its checks are RED — fix main, then task done"
            fi
            ;;
          '') warn "$ident: could not verify the check status of $_dref (no gh token / network / gh) — merged-state confirmed, checks UNVERIFIED."
              _mg_unverified="${_mg_unverified:+$_mg_unverified; }checks of $_dref unresolved (merged-state confirmed)" ;;
        esac
        # DIVE-2641: THE FOURTH ACCEPTING PATH, and until now the SILENT one. The row
        # bound a delivery_ref, the PR is MERGED (every refusal above returned), and
        # this path printed nothing at all — so the most common close route in the
        # product was the one arm that could not carry the deployed-vs-merged note, and
        # patching only the three arms that already spoke would have re-created the
        # defect for exactly the rows that bind a PR. Same reasoning DIVE-2217 applied
        # to the merged-PR arm below: an accept that says nothing is indistinguishable
        # from every other accept in the durable operator record.
        warn "$ident: delivery PR $_dref is MERGED (at $_merged) — GitHub's merged-PR record on the DECLARED delivery is the accepting evidence. done=merged-to-main satisfied.$(_gate_merged_not_deployed "$(_gate_slug_from_url "$_dref")")"
      else
        # DIVE-1955: a `Branch:` line names no repo, so this used to look for the
        # merged PR in the CLI repo ONLY — an api/frontend branch could never satisfy
        # its own fail-CLOSED gate. Search the task's declared repo when it has one,
        # else every known repo, and pass if the branch landed in ANY of them.
        #
        # DIVE-2101: TWO independent ways to satisfy done=merged-to-main here, tried
        # per repo in this order:
        #   1. ANCESTRY — the branch tip is an ancestor of that repo's main.
        #   2. a MERGED PR for the branch (the DIVE-1955 search, unchanged).
        # Ancestry is not a relaxation, it is the SAME requirement measured directly:
        # "a PR was merged" is a proxy artifact for "the code is in main", and the
        # DELEGATED-PUSH path (DIVE-1496 — how an agent without gh auth lands a branch
        # at all) produces the fact without ever producing the artifact. Measured on
        # DIVE-2051: work provably 0 commits ahead of main, no PR possible (its diff
        # would be EMPTY), and the gate refused forever. That is unsatisfiable, not
        # strict, and it is the standing shape of every delegated push.
        #   DIVE-2184 — THIS PARAGRAPH USED TO DESCRIBE PRE-DIVE-2120 SEMANTICS AND WAS
        # FALSE. It said "Ancestry PASSING is sufficient" and "Acceptance needs BOTH
        # halves ... Neither half alone closes anything". Both are wrong now, and the
        # wrong version is what the close message was written against, which is how it
        # came to claim ancestry for a squash-merged PR. Corrected against MEASUREMENT,
        # not reading (olivia, DIVE-2184 iteration 1):
        #   * stub _gate_branch_ident_on_main to 0, leave ancestry passing -> the
        #     ancestor case REFUSES. Attribution is NECESSARY.
        #   * stub _gate_branch_ancestry to 0, leave attribution passing -> the same
        #     case still CLOSES. Ancestry is neither necessary nor sufficient.
        #   SO: SINCE DIVE-2120, ATTRIBUTION IS THE ONLY THING THAT ACCEPTS on this
        # path — some commit reachable from main names this ident in its subject
        # (_gate_branch_ident_on_main). _gate_branch_ancestry survives as diagnostic
        # context in the refusal text; it cannot close anything on its own. If you are
        # changing acceptance, change attribution — ancestry is not a lever any more.
        #   The empty-branch hazard the old text worried about is still covered, by
        # attribution alone rather than by a second half: a branch with ZERO commits
        # has a tip that IS on main, so ancestry is trivially true of it, but no commit
        # names the ident, so it is refused. That is why vacuity is structurally
        # impossible here instead of separately guarded.
        #   Squash-merges still close, and this is the case that produced the ticket:
        # a squash rewrites the sha, so the branch tip is NOT an ancestor of main even
        # though the content is in. Attribution finds it anyway, because the squash
        # commit subject carries the ident.
        local _slug _bmerged="" _merged_slug="" _searched="" _attr_slug="" _anc="" _attr="" _anc_novac="" _attr_bound="" _attr_unreach="" _attr_scope="" _attr_unreach_note=""
        while IFS= read -r _slug; do
          [[ -n "$_slug" ]] || continue
          _searched="${_searched:+$_searched, }$_slug"
          # DIVE-2120: attribution is measured against MAIN now, so it no longer depends on
          # the branch ref existing — a merged-and-DELETED branch was byte-identical to one
          # that never existed. Acceptance is the attribution alone: a commit ON MAIN whose
          # SUBJECT names the ident IS work on main, which is the property ancestry existed
          # to establish. Vacuity becomes structurally impossible rather than separately
          # guarded — an empty branch contributes no such commit.
          _attr=$(_gate_branch_ident_on_main "$_slug" "$_branch" "$_ghtok" "$ident")
          if [[ "$_attr" == "1" ]]; then _attr_slug="$_slug"; break; fi
          # bound:<walked> — carry every bound-hit repo and ITS OWN measured count into
          # the refusal. DIVE-2266: overwriting this on each pass named only the last
          # member of a set search, and a detached count cannot describe multiple repos.
          [[ "$_attr" == bound:* ]] \
            && _attr_bound="${_attr_bound:+$_attr_bound, }$_slug:${_attr#bound:} COMMITS WALKED"
          # Ancestry is kept ONLY to name the vacuous shape in the refusal; it can no longer
          # accept anything by itself (that was the DIVE-2101 bug).
          _anc=$(_gate_branch_ancestry "$_slug" "$_branch" "$_ghtok")
          [[ "$_anc" == "1" && "$_attr" == "0" ]] && _anc_novac="$_slug"
          # DIVE-2318: attribution returning EMPTY is "unreachable", documented as such
          # on _gate_branch_ident_on_main and then discarded here — every non-"1" answer
          # fell through to the same generic "branch is NOT on main" refusal, so an API
          # failure and an exhaustive miss printed the identical sentence. Only one of
          # them is a finding. Carry it so the refusal below can tell them apart.
          # DIVE-2324: accumulate, don't overwrite — a plain assignment named only the
          # LAST unreachable repo of a set search, under-reporting the coverage gap the
          # variable exists to describe. Same fix as DIVE-2266 made for _attr_bound above.
          [[ -z "$_attr" ]] && _attr_unreach="${_attr_unreach:+$_attr_unreach, }$_slug"
          _bmerged=$(_gate_gh "$_ghtok" 0 pr list --repo "$_slug" --head "$_branch" --state merged --json number,mergedAt -q '.[0].mergedAt' 2>/dev/null || echo "")
          if [[ -n "$_bmerged" && "$_bmerged" != "null" ]]; then
            _merged_slug="$_slug"
            break
          fi
          _bmerged=""
        done < <(if [[ -n "$_task_slug" ]]; then printf '%s\n' "$_task_slug"; else _gate_repo_slugs; fi)
        if [[ -n "$_attr_slug" ]]; then
          # Say WHICH evidence closed it. A close that passed on ancestry and one that
          # passed on a merged PR are different records, and the reader of the record
          # months later cannot tell them apart from a clean exit (DIVE-1869 rule).
          # DIVE-2184: this branch accepts on ATTRIBUTION, not ancestry. The variable
          # feeding it is set by _gate_branch_ident_on_main; _gate_branch_ancestry was
          # demoted by DIVE-2120 and can no longer accept anything. The message claimed
          # ancestry anyway, and asserted "no PR needed; delegated push" — both false for
          # DIVE-2102, which closed via SQUASH-MERGED PR #248 whose tip is not an ancestor
          # of main at all. The comment directly above already demanded this say WHICH
          # evidence closed it; it named the wrong one.
          #
          # Attribution CANNOT distinguish a delegated push from a squash-merged PR — a
          # squash rewrites the sha, so both look identical to a subject scan. So this
          # states what was measured and claims neither route.
          # DIVE-2431: name the SCOPE on the accept, not only on the refusals. The
          # refusals already said which repos they searched; this line did not, and it
          # is the half that fails silently — an accept sourced from a repo that is not
          # where the delivery went reads as a clean close and nothing invites a second
          # look. Measured on DIVE-2303: accepted on a commit in 5dive-ai/5dive while
          # the delivery sat in character-packs, which was not in the searched set at
          # all. Only stated when the task DECLARED no repo, because a declared repo
          # narrows the scan to itself and there is no unsearched remainder to warn about.
          _attr_scope=""
          if [[ -z "$_task_slug" ]]; then
            _attr_scope=" SCOPE: this task declares no repo, so the gate searched $_searched and stopped at the first hit — repos outside that set were NOT looked at. If the delivery landed somewhere else, this accept is about a DIFFERENT repo's commit; declare it with a \`Repo: <owner>/<repo>\` line or bind the delivery_ref, and re-check."
          fi
          warn "$ident: a commit on ${FIVE_GATE_MAIN_BRANCH:-main} in $_attr_slug names $ident in its SUBJECT — the work is on main (attribution, DIVE-2120). This does NOT establish HOW it landed: a delegated push and a squash-merged PR are indistinguishable to a subject scan, because a squash rewrites the sha. done=merged-to-main satisfied.$_attr_scope$(_gate_merged_not_deployed "$_attr_slug")"
        elif [[ -n "$_attr_bound" && -z "$_bmerged" ]]; then
          # DIVE-2120: the scan stopped AT THE BOUND without finding the ident. That is NOT
          # a miss and must not read as one — a bounded search whose negative looks like an
          # exhaustive one asserts something it never measured. Own slug, so the durable
          # record names the whole set that hit a bound, with each repo's own count.
          # DIVE-2266: a repo outside the searched set is a third live explanation; a
          # larger bound cannot find it, so give the binding remedies that can terminate.
          # DIVE-2324: this arm is MEASURED and wins ahead of the unreachable-sibling
          # arm below, deliberately (see that arm's ordering comment) — but winning
          # silently dropped the fact that the scan was ALSO incomplete elsewhere. Name
          # it here too, so the record does not read as "only the bound was inconclusive".
          _attr_unreach_note=""
          [[ -n "$_attr_unreach" ]] && _attr_unreach_note=" Additionally, $_attr_unreach never answered at all (unreachable, not merely bounded) — the scan is incomplete there too."
          policy_refuse "$E_CONFLICT" done-ident-not-found-within-scan-bound DIVE-2120 "$ident" "$ident cannot close: the commit scan hit its bound in $_attr_bound (repo:commits-walked) — INCONCLUSIVE, not absence.$_attr_unreach_note Three explanations survive: (a) the delivery predates the scanned window — raise FIVE_GATE_ANCESTRY_SCAN=<n> and retry; (b) no commit SUBJECT on main ever named $ident, which is what an EMPTY branch looks like — land one (\`5dive push $ident\`); (c) the branch lives in a repo that was NEVER SCANNED — add a 'Repo: <owner/repo>' line to the body, or bind it (\`task deliver $ident --pr=https://github.com/<owner>/<repo>/pull/N\`)."
        elif [[ -n "$_anc_novac" && -z "$_bmerged" ]]; then
          # The vacuous shape, named as itself: an ancestor tip carrying nothing
          # attributable is exactly what an EMPTY branch looks like, and a generic
          # "not merged" here would send the reader off to merge something that is
          # already in.
          policy_refuse "$E_CONFLICT" done-on-vacuous-branch-ancestry DIVE-2101 "$ident" "$ident cannot close: branch '$_branch' points at a commit on main but NO commit reachable from it names $ident — that is what an EMPTY branch looks like. Land work naming it (\`5dive push $ident\`), or bind the branch that carries it (\`task set-branch $ident <branch>\`)."
        elif [[ -n "$_attr_unreach" && -z "$_bmerged" ]]; then
          # DIVE-2318: at least one repo in the search set never ANSWERED, so the
          # negative below it is not exhaustive over the set it claims to cover. A
          # refusal here must describe the SCAN, not the branch — nothing about the
          # branch was measured in $_attr_unreach.
          #
          # ORDERED LAST AMONG THE INCONCLUSIVE ARMS, deliberately. `bound:` and the
          # vacuous-ancestry shape above are both MEASURED, concrete and actionable in
          # a NAMED repo; an unreachable sibling repo must not shout over either of
          # them. It sits directly ahead of the pure negative because that is the one
          # arm that would otherwise launder partial coverage into a clean absence.
          policy_refuse "$E_CONFLICT" done-attribution-unresolved DIVE-2318 "$ident" "$ident cannot close: main in $_attr_unreach could not be scanned — PARTIAL COVERAGE, not absence; re-run when reachable"
        elif [[ -z "$_bmerged" ]]; then
          # DIVE-2318: this message used to say the branch "is neither an ancestor of
          # [main] nor the head of a MERGED PR". Both halves were wrong to state as
          # acceptance criteria:
          #   * ANCESTRY has not accepted anything since DIVE-2120/2184 — attribution is
          #     the sole acceptance on this path, measured by olivia's stub arms. Naming
          #     ancestry told the reader to satisfy a condition that closes nothing.
          #   * Worse, it is UNSATISFIABLE by construction under our default merge
          #     strategy. Measured on PR #300 (DIVE-2301): `merge-base --is-ancestor
          #     8068061 origin/main` FALSE while `git diff 8068061 origin/main` over the
          #     changed paths was EMPTY. A squash rewrites the sha, so the branch tip is
          #     never an ancestor of main, for any squash-merged PR, ever.
          # An error naming a condition that cannot be satisfied sends people looking for
          # a missing branch. It did exactly that to dev2 on DIVE-2286 and to dev3 on
          # DIVE-2301. So: state what was actually measured (no commit subject on main
          # names the ident, no merged PR for the branch) and give the remedy that works.
          # DIVE-2296: "not landed" is TRUE here and it is not ENOUGH. It is the same
          # sentence whether no PR exists for this branch or one is open and mid-CI,
          # and those want opposite responses (open one / wait). Look the open PR up
          # and say which state this is — the lookup is here, on the refusing path,
          # so nothing that closes pays for it.
          local _open_slug="" _open_pr="" _open_probe="" _open_unread=""
          while IFS= read -r _slug; do
            [[ -n "$_slug" ]] || continue
            _open_probe=$(_gate_branch_open_pr "$_slug" "$_branch" "$_ghtok")
            # An UNREADABLE repo is carried, not discarded: a negative that skipped
            # over a repo it could not ask is not a negative about that repo.
            if [[ "$_open_probe" == "UNREADABLE" ]]; then
              _open_unread="${_open_unread:+$_open_unread, }$_slug"; continue
            fi
            if [[ -n "$_open_probe" ]]; then _open_slug="$_slug"; _open_pr="$_open_probe"; break; fi
          done < <(if [[ -n "$_task_slug" ]]; then printf '%s\n' "$_task_slug"; else _gate_repo_slugs; fi)
          local _open_note=" No OPEN PR was found for '$_branch' in $_searched either, so the next step is to land it: \`5dive push $ident\`."
          # Say UNKNOWN out loud. A blank where a PR would be reads as "checked, none"
          # and sends the maker to open a duplicate of a PR that may well exist.
          [[ -n "$_open_unread" ]] \
            && _open_note=" Whether an OPEN PR exists for '$_branch' is UNKNOWN — the lookup could not be answered in $_open_unread (no rail, an invalid credential, or a timeout). That is NOT 'there is no PR': before opening one, check by hand (\`5dive gh pr list --head $_branch --repo <owner>/<repo>\`), and if there is genuinely none, land it with \`5dive push $ident\`."
          if [[ -n "$_open_pr" ]]; then
            local _open_num="${_open_pr%%|*}" _open_checks="${_open_pr##*|}" _checks_note=""
            case "$_open_checks" in
              OK)      _checks_note="its checks are GREEN, so it is waiting on a MERGE, not on you" ;;
              FAILURE) _checks_note="its checks are RED — fix the PR; merging it is not the next step" ;;
              NONE)    _checks_note="it reports NO checks yet — they may not have started" ;;
              *)       _checks_note="its check status could not be read" ;;
            esac
            _open_note=" AN OPEN PR ALREADY EXISTS for this branch: ${_open_slug}#${_open_num}, and ${_checks_note}. DO NOT open a second one, and do not ask anyone to — this refusal means 'not merged yet', which is exactly what an open PR looks like. Watch it with \`5dive gh pr view ${_open_num} --repo ${_open_slug}\` (that read routes to the bot when you hold no credential of your own, DIVE-2296)."
          fi
          policy_refuse "$E_CONFLICT" done-before-branch-merged DIVE-1830 "$ident" "$ident cannot close: nothing on ${FIVE_GATE_MAIN_BRANCH:-main} in $_searched shows branch '$_branch' landed — no commit SUBJECT there names $ident (attribution) and no MERGED PR has that head. Ancestry is NOT one of the ways in: a squash rewrites the sha, so a branch tip is never an ancestor of a squash-merged main.$_open_note"
        else
          # DIVE-2217: this is the OTHER accepting arm. Keep its repo in a variable
          # named for the evidence that assigned it, just as _attr_slug is owned by
          # _gate_branch_ident_on_main above. A silent success here made a merged-PR
          # close indistinguishable from attribution in the durable operator record.
          warn "$ident: branch '$_branch' is the head of a MERGED PR in $_merged_slug (merged at $_bmerged) — GitHub's merged-PR record is the accepting evidence. done=merged-to-main satisfied.$(_gate_merged_not_deployed "$_merged_slug")"
        fi
      fi
    fi
  fi
  # DIVE-1835 MANDATORY auto-detect merge-gate. The DIVE-1830 gate above fires
  # only when the maker DECLARED a binding (delivery_ref / Branch: line); 8
  # code-tasks closed with NEITHER and slipped straight through. This second
  # gate closes that hole: it runs ONLY when no binding was declared, and
  # detects code bound to the ident WITHOUT the maker self-declaring — an OPEN,
  # unmerged PR whose TITLE or HEAD-BRANCH names the ident (never the PR body: a
  # "follow-up to DIVE-N" mention would false-block; OPEN only: an abandoned /
  # closed-unmerged PR must never make the task unclosable).
  #   Auto-detect is FAIL-OPEN by design — the opposite of the declared path's
  # fail-closed. It runs on EVERY no-binding close (incl. research/docs/heartbeat,
  # which simply won't match), so a gh outage/timeout/absence must NEVER block
  # the whole fleet from closing anything (the fleet-stall design-flaw class,
  # DIVE-1830). Fail-open slips are the acceptable trade: the weekly
  # branch-hygiene digest (#139, DIVE-1833) catches any unmerged PR/branch left
  # behind. `--force-merge-gate` is the audited manual escape (a mandatory gate
  # with no escape is a footgun) — logged, and its leftover PR is digest-flagged.
  if [[ "$verb" == "done" && -z "$_dref" && -z "$_branch" ]]; then
    local _auto_hit="" _scan_ran=0
    # DIVE-1955: declared out here, not inside the token branch — they are read by
    # the refusal messages below, and `set -u` turns an unset one into a crash on
    # the very path (no gh token) this gate is supposed to survive.
    local _ghtok2="" _slug2="" _sc_hit_slug="" _sc_total=0 _sc_ok=0
    command -v gh >/dev/null 2>&1 && _ghtok2=$(_gate_gh_token)
    # DIVE-1935: NO TOKEN means the answer is unverified whatever gh prints — do
    # not run the query and then read its empty result as "repo is clean". That
    # inference is precisely how this gate reported a clean close for every unauthed
    # agent on the box. An empty token short-circuits to the unverified branch below.
    # DIVE-2605: "no token" is no longer the same as "cannot ask" — a builder with no
    # token reaches the same API through the bot rail. Unreachable still short-circuits
    # to unverified exactly as before; this only stops calling a reachable host unauthed.
    if _gate_gh_reachable "$_ghtok2"; then
      # One bounded, read-only listing PER KNOWN REPO; filter title/headRefName
      # client-side so a body-only mention can't match. `timeout 5s` + `|| echo ""`
      # => any slow/failed/absent gh yields no hit and the close proceeds (fail-open).
      # The ident is matched at WORD BOUNDARIES (non-alnum on both sides), not as
      # a bare substring — else DIVE-202 would be false-blocked by an open PR
      # naming DIVE-2021/DIVE-2029. Case-insensitive so a lowercase branch
      # (`dive-202-fix`) matches the uppercase ident too.
      # DIVE-1955: this scan was single-repo, so an open api/frontend PR naming the
      # ident never blocked anything — the mandatory gate simply did not exist for
      # two of three repos. First hit wins and the refusal names WHICH repo. A repo
      # whose listing fails does not count as scanned: partial coverage reported as
      # full is the same succeeding-in-appearance shape DIVE-1935 was about.
      while IFS= read -r _slug2; do
        [[ -n "$_slug2" ]] || continue
        _sc_total=$((_sc_total+1))
        local _hit
        _hit=$(_gate_gh "$_ghtok2" 5 pr list --repo "$_slug2" \
                    --state open --limit 200 --json number,headRefName,title \
                    -q "[.[] | select((.title // \"\" | test(\"(^|[^A-Za-z0-9])${ident}([^A-Za-z0-9]|\$)\";\"i\")) or (.headRefName // \"\" | test(\"(^|[^A-Za-z0-9])${ident}([^A-Za-z0-9]|\$)\";\"i\"))) | .number] | .[0] // empty" \
                    2>/dev/null) && _sc_ok=$((_sc_ok+1)) || _hit=""
        if [[ -n "$_hit" ]]; then _auto_hit="$_hit"; _sc_hit_slug="$_slug2"; break; fi
      done < <(if [[ -n "$_task_slug" ]]; then printf '%s\n' "$_task_slug"; else _gate_repo_slugs; fi)
      [[ $_sc_ok -eq $_sc_total && $_sc_total -gt 0 ]] && _scan_ran=1
      [[ -n "$_auto_hit" ]] && _scan_ran=1
    fi
    # DIVE-2316: the mandatory gate already resolved a concrete PR in a concrete
    # repo. Persist that identity before refusing the premature close, so the
    # next invocation takes the declared, fail-closed path instead of throwing
    # the discovery away and starting from an unbound row again. This is also
    # provenance: the compliant "PR open -> refused -> merge -> close" sequence
    # must not leave a weaker record than a post-hoc `task deliver --pr=` repair.
    #
    # Never overwrite a concurrently supplied binding. The initial read above
    # was empty, but a `task deliver` can race this network scan; the WHERE keeps
    # its explicit pointer authoritative. Stamp the current loop iteration for
    # the DIVE-2682 stale-binding guard, even though ordinary non-loop rows use 0.
    if [[ -n "$_auto_hit" && -n "$_sc_hit_slug" ]]; then
      local _auto_ref _stored_ref
      _auto_ref="https://github.com/${_sc_hit_slug}/pull/${_auto_hit}"
      db "UPDATE tasks
            SET delivery_ref=$(sqlq "$_auto_ref"),
                delivered_at=datetime('now'),
                delivery_ref_iteration=COALESCE(iteration,0)
          WHERE id=${id} AND COALESCE(delivery_ref,'')='';"
      _stored_ref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=${id};")
      if [[ "$_stored_ref" == "$_auto_ref" ]]; then
        warn "$ident: auto-detected delivery PR $_auto_ref from its title/head branch and persisted the binding (DIVE-2316)."
      else
        warn "$ident: auto-detected delivery PR $_auto_ref, but preserved the concurrently recorded binding $_stored_ref (DIVE-2316)."
      fi
    fi
    # DIVE-1935: SAY SO when the scan could not run. A fail-open gate that returns
    # "no hit" for a gh outage and "no hit" for a clean repo is indistinguishable
    # from a working one — the same succeeding-in-appearance shape DIVE-1922 was
    # itself about. Fail-open stays (a gh outage must never stall the fleet), but
    # it is no longer silent, and the audit row makes the unverified close findable.
    if [[ $_scan_ran -eq 0 ]]; then
      local _scan_why="query-failed"
      command -v gh >/dev/null 2>&1 || _scan_why="gh-absent"
      # DIVE-2705: "no token" is a statement about ONE rail, and it is only the
      # right label when NO rail answered — i.e. the loop was never entered, so
      # _sc_total is still 0. Gating it on the token alone predates the bot rail
      # and mislabels a bot-rail scan that ran and partly failed.
      [[ $_sc_total -eq 0 && -z "$_ghtok2" ]] && _scan_why="no-gh-token"
      # DIVE-1955: "3 repos, 2 listed" is partial coverage, and partial coverage
      # announced as a clean scan is the defect this ticket is about, one level up.
      # DIVE-2705: partial coverage is a fact about how many repos ANSWERED, never
      # about WHICH RAIL asked — the `-n "$_ghtok2"` that used to guard this was
      # the same token-as-proxy-for-reachability that DIVE-2605 replaced with
      # _gate_gh_reachable one level up, left behind here. With the bot rail now
      # reporting real failures, that proxy made a partial bot-rail scan announce
      # itself as "no-gh-token": wrong, and the more reassuring of the two.
      [[ $_sc_total -gt 0 && $_sc_ok -lt $_sc_total ]] && _scan_why="partial-repo-scan-${_sc_ok}-of-${_sc_total}"
      # DIVE-2770: the anonymous rail makes _gate_gh_reachable true for a caller
      # who holds nothing, so this loop is now ENTERED where it used to be skipped
      # — and every repo declines, because the anon rail deliberately does not
      # serve the open-PR listing (see _gate_anon_gh). "partial-repo-scan-0-of-3"
      # would then name a coverage problem where there is a credential one: zero
      # answers with no token and no bot is not partial coverage, it is no rail for
      # THIS query.
      #
      # NOTE THE `_sc_total -gt 0`, which is the whole care in this line. Without it
      # this also relabels the case where the loop was never ENTERED at all — the
      # pre-2770 no-rail state, which three sibling harnesses assert as
      # `no-gh-token` and which this ticket did not change. A new label belongs only
      # on the new situation; widening it to an old one is churn wearing a fix's
      # clothes.
      if [[ $_sc_total -gt 0 && $_sc_ok -eq 0 && -z "$_ghtok2" ]] && ! _gate_gh_bot_ok; then
        _scan_why="no-gh-rail-for-listing"
      fi
      # DIVE-1935 iteration 2: the audited-unverified close is the ONLY surface on
      # which an inert gate announces itself, so it has to say where the instrument
      # stopped. Without the seat, every reader generalises from their own.
      local _uv_why; _uv_why="$(_gate_tok_why)"
      warn "$ident: merge-gate could not query GitHub ($_scan_why) — this close is UNVERIFIED, not verified-clean (DIVE-1935). Instrument: ${_uv_why}. Grade it with \`5dive task merge-gate-selftest\`."
      _task_store_audit_log "task.merge-gate-unverified" ok 0 -- "$ident" "reason=$_scan_why" "seat=$(id -un 2>/dev/null || printf '?')"
      _mg_unverified="${_mg_unverified:+$_mg_unverified; }repo scan did not complete ($_scan_why)"
    fi
    # DIVE-1935: the PR reference the maker TYPED is a declaration too. DIVE-1922
    # closed with no delivery_ref and no Branch: line, so both bindings were empty
    # and the repo-wide scan was inert (unresolvable token, above) — yet its own
    # result said "PR #156" in prose. Parse the result AND the body, and refuse the
    # close while a PR they named is still OPEN. Deliberately narrow so prose stays
    # safe: OPEN only (a "superseded by #150" mention of an abandoned PR must never
    # make a task unclosable, per DIVE-1835), and an unresolvable ref is a loud note
    # rather than a block, so a non-PR "#12" and an offline box both stay closable.
    local _txt_open="" _txt_open_slug="" _txt_red="" _txt_unres="" _txt_amb="" _txt_cited=""
    # DIVE-2414: the cited set kept QUALIFIED as well as by number. `_txt_cited`
    # is the number-only list the warning and the audit row have always printed;
    # the subject-state reader needs the slug that travelled with the ref, or a
    # bare "#6" gets read against whichever repo answers first (DIVE-1955).
    local _txt_cited_q=""
    # DIVE-1955 (review, Marcus): decide "was a PR mentioned at all" UNCONDITIONALLY,
    # before the token/parser checks below, because those are exactly the paths that
    # cannot answer it later. Without this, a no-token close cannot distinguish a
    # research task (nothing to verify) from a task whose result names a PR nobody
    # could confirm — and it is the second one the record has to disclose.
    local _mg_txt="$result
$_body"
    _gate_text_names_a_ref "$_mg_txt" && _mg_had_subject=1
    # An empty ref list is only trustworthy if the parser can actually run. Without
    # this, a grep that cannot execute makes the text-binding gate a no-op that
    # looks exactly like a clean close (the ticket's own defect, one layer down).
    if [[ $force_merge_gate -eq 0 ]] && ! _gate_pr_refs_engine_ok; then
      warn "$ident: PR-reference parsing is BROKEN on this host (grep -oE unusable) — the result/body merge-gate did NOT run; this close is UNVERIFIED (DIVE-1935)."
      _task_store_audit_log "task.merge-gate-unverified" ok 0 -- "$ident" "reason=ref-parser-broken"
      _mg_unverified="${_mg_unverified:+$_mg_unverified; }PR-reference parser unusable on this host"
    elif [[ -z "$_auto_hit" && $force_merge_gate -eq 0 && -n "$_ghtok2" ]]; then
      local _txt _qref _n=0 _st _rslug
      _txt="$_mg_txt"
      # DIVE-1965: which of these refs does the close claim to have DELIVERED? Only
      # those are this task's to answer for. A bare `|N` entry means the delivery was
      # asserted on a bare "PR #N", which the extractor may have upgraded to a
      # qualified `slug|N` via a URL elsewhere in the same text — so membership is
      # "exact match OR same number asserted bare", never a number-only match on the
      # cited side. Computed ONCE, outside the loop: it is a pure text pass.
      local _deliv; _deliv=$(_gate_delivery_refs_from_text "$_txt")
      # DIVE-1955: refs are resolved QUALIFIED. A pull URL is checked in its own
      # repo; a bare `#N` is checked in the task's declared repo, or — when that is
      # unknown — bound only by ident evidence across the known repos and otherwise
      # reported AMBIGUOUS. It is never resolved against a default slug: that path
      # produced confident verdicts about the wrong pull request (an api "#6" judged
      # against the CLI repo's unrelated #6), which can refuse a legitimate close or
      # bless a bad one. Ambiguous blocks nothing and blesses nothing.
      while IFS= read -r _qref; do
        [[ -n "$_qref" ]] || continue
        # DIVE-1965: a ref this close only REPORTS ON is not judged at all — not
        # resolved (no API call), not refused, and not stamped. There is no question
        # about it for the gate to answer or decline: it is another task's delivery.
        # Skipped BEFORE the cap so five cited PRs cannot crowd out the real one.
        if ! printf '%s\n' "$_deliv" | grep -qxF -e "$_qref" -e "|${_qref#*|}"; then
          _txt_cited="${_txt_cited:+$_txt_cited,}${_qref#*|}"
          _txt_cited_q="${_txt_cited_q:+$_txt_cited_q$'\n'}${_qref}"
          continue
        fi
        # Bounded: 5 refs max per close, and the drop is announced — a silent cap
        # would read as "all references checked" when it wasn't.
        if (( _n >= 5 )); then warn "$ident: merge-gate checked the first 5 PR references named in the result/body; later ones were NOT checked."; break; fi
        _n=$((_n+1))
        _st=$(_gate_resolve_qualified "$_qref" "$_ghtok2" "$ident" "$_task_slug")
        _rslug="${_st%%|*}"; _st="${_st#*|}"
        case "$_rslug|$_st" in
          AMBIGUOUS\|*)          _txt_amb="${_txt_amb:+$_txt_amb; }#${_qref#*|} in ${_st//,/, }" ;;
          *\|OPEN\|*)            _txt_open="${_qref#*|}"; _txt_open_slug="$_rslug"; break ;;
          *\|MERGED\|*\|FAILURE) _txt_red="${_txt_red:+$_txt_red,}${_rslug}#${_qref#*|}" ;;
          \|)                    _txt_unres="${_txt_unres:+$_txt_unres; }#${_qref#*|} in $(_gate_search_scope "$_qref" "$_task_slug")" ;;
        esac
      done < <(_gate_pr_refs_qualified_from_text "$_txt")
      if [[ -n "$_txt_unres" ]]; then
        # DIVE-1963: name the repo(s) ACTUALLY searched, per ref. A ref carrying its own
        # pull URL is looked up there and nowhere else; a bare #N in a task that declares
        # a repo is looked up there and nowhere else; only a bare #N with no declaration
        # gets the full sweep. One sentence covered all three and was false for two.
        warn "$ident: could not resolve PR reference(s) named in the result/body — $_txt_unres — merge state UNVERIFIED for those. Cite the full pull URL, or add a \`Repo: <owner>/<repo>\` line, to have them checked."
        _mg_unverified="${_mg_unverified:+$_mg_unverified; }PR reference(s) resolve to no PR in the repo(s) searched — $_txt_unres"
      fi
      if [[ -n "$_txt_amb" ]]; then
        warn "$ident: AMBIGUOUS PR reference(s) — $_txt_amb. A bare number does not identify a pull request across our repos and this task declares none, so the merge state is UNVERIFIED rather than guessed (DIVE-1955). Cite the full pull URL or add a \`Repo: <owner>/<repo>\` line to the body."
        # DIVE-2054 (judgment call): pure task-store text-match record, same
        # family as the already-fenced "task.merge-gate-unverified" — fenced.
        _task_store_audit_log "task.merge-gate-ambiguous" ok 0 -- "$ident" "refs=$_txt_amb"
        _mg_unverified="${_mg_unverified:+$_mg_unverified; }AMBIGUOUS PR reference(s) — $_txt_amb"
      fi
      # DIVE-1965: say which refs were set aside and WHY, with both escapes named.
      # Deliberately a warn + audit row and NOT an UNVERIFIED stamp: the record only
      # discloses non-verdicts about THIS task's delivery, and a cited PR was never
      # that. Stamping here would put the marker back on every audit/triage/review
      # close — the wallpaper failure DIVE-1955 spent a review pass deleting. It is
      # also the guard on this ticket's one coverage cost: if the maker's own
      # delivery landed in here, this line is where they see it.
      if [[ -n "$_txt_cited" ]]; then
        # DIVE-2414: SET ASIDE IS NOT THE SAME ACT AS NOT LOOKED AT. These refs
        # still do not gate this close — restoring that would re-create the
        # fleet-wide blocker DIVE-1965 deleted — but their state is now READ and
        # DISCLOSED through the same subject-state reader the gate sweep uses.
        # DIVE-2382 closed while citing its own PR #337 as OPEN and nothing said
        # so; that open PR then outlived the only row pointing at it.
        local _cited_note; _cited_note=$(_gate_cited_state_note "$_txt_cited_q" "$_ghtok2" "$ident" "$_task_slug")
        warn "$ident: merge-gate treated PR reference(s) #${_txt_cited//,/, #} as CITED, not delivered — nothing binds them to this task, so they do NOT gate this close (DIVE-1965). Their state, MEASURED anyway and reported only (DIVE-2414): ${_cited_note}. If one of them IS this task's delivery, bind it (\`task deliver $ident --pr=<url>\`) or say so (\"merged as PR #N\", or a \`Delivered: <url>\` line)."
        # DIVE-2054 (judgment call): same merge-gate family as -ambiguous above — fenced.
        _task_store_audit_log "task.merge-gate-reported-on" ok 0 -- "$ident" "refs=$_txt_cited" "states=$_cited_note"
      fi
    fi
    if [[ -n "$_txt_open" && $force_merge_gate -eq 0 ]]; then
      policy_refuse "$E_CONFLICT" done-with-open-pr-in-result DIVE-1935 "$ident" "$ident cannot close: PR #$_txt_open in $_txt_open_slug is OPEN, not merged — merge it, then task done"
    fi
    if [[ -n "$_txt_red" && $force_merge_gate -eq 0 ]]; then
      policy_refuse "$E_CONFLICT" done-after-named-red-merge DIVE-1935 "$ident" "$ident cannot close: PR ${_txt_red//,/, } is merged but its checks are RED — fix main, then task done"
    fi
    # DIVE-2577: the DIVE-2556 shape — a result/body that names a BRANCH, never a
    # PR. Run only when nothing above already found (or is about to refuse on) a
    # PR, and only when a token resolved (fail-open on missing credential, same
    # design as the rest of this mandatory gate — a gh outage must never stall the
    # fleet). `_gate_branch_refs_from_text` is the anchor: it can only return a hit
    # when the text carries this task's OWN ident as a branch-slug prefix, so a
    # close that names no branch at all (the overwhelming majority) never enters
    # this block.
    if [[ -z "$_auto_hit" && $force_merge_gate -eq 0 && -n "$_ghtok2" ]]; then
      # DIVE-2603: the extractor is a PROBE that legitimately finds nothing — most
      # results name no branch at all. Its pipeline ends in `grep`, which exits 1 on
      # no-match; `pipefail` promotes that through `sed | tr | sort`, and a bare
      # `var=$(...)` under `set -euo pipefail` (src/header.sh) kills the whole close.
      # Shipped in v0.18.3 and it broke `task done` for every caller holding a gh
      # token whose result text named no `<ident>-slug` branch — exit 1, empty stdout
      # AND empty stderr, because the die happens before anything is printed.
      # `|| _br_cands=""` rather than `|| true`: it states the post-condition the
      # `[[ -z ]]` test below actually reads. Same defect and same fix as DIVE-2566
      # one file over — an unguarded substitution around a probe allowed to fail.
      local _br_cands; _br_cands=$(_gate_branch_refs_from_text "$_mg_txt" "$ident") || _br_cands=""
      if [[ -n "$_br_cands" ]]; then
        _mg_had_subject=1
        local _cand _slug3 _attr3 _bm3 _bl_hit="" _bl_hit_slug="" _bl_hit_how="" _bl_searched2="" _bl_any_unreach=0
        while IFS= read -r _cand; do
          [[ -n "$_cand" ]] || continue
          while IFS= read -r _slug3; do
            [[ -n "$_slug3" ]] || continue
            [[ ",$_bl_searched2," == *",$_slug3,"* ]] || _bl_searched2="${_bl_searched2:+$_bl_searched2,}$_slug3"
            _attr3=$(_gate_branch_ident_on_main "$_slug3" "$_cand" "$_ghtok2" "$ident")
            if [[ "$_attr3" == "1" ]]; then _bl_hit="$_cand"; _bl_hit_slug="$_slug3"; _bl_hit_how="attribution"; break 2; fi
            [[ -z "$_attr3" ]] && _bl_any_unreach=1
            _bm3=$(_gate_gh "$_ghtok2" 0 pr list --repo "$_slug3" --head "$_cand" --state merged --json mergedAt -q '.[0].mergedAt' 2>/dev/null || echo "")
            if [[ -n "$_bm3" && "$_bm3" != "null" ]]; then _bl_hit="$_cand"; _bl_hit_slug="$_slug3"; _bl_hit_how="a merged PR"; break 2; fi
          done < <(if [[ -n "$_task_slug" ]]; then printf '%s\n' "$_task_slug"; else _gate_repo_slugs; fi)
        done < <(printf '%s\n' "$_br_cands")
        if [[ -n "$_bl_hit" ]]; then
          warn "$ident: branch '$_bl_hit', named in the result/body, is on ${FIVE_GATE_MAIN_BRANCH:-main} in $_bl_hit_slug via $_bl_hit_how. done=merged-to-main satisfied (DIVE-2577).$(_gate_merged_not_deployed "$_bl_hit_slug")"
        elif [[ $_bl_any_unreach -eq 1 ]]; then
          warn "$ident: result/body names branch(es) ${_br_cands//$'\n'/, } but the merge-gate could not fully scan ${_bl_searched2//,/, } for them (API/timeout on at least one repo) — this close is UNVERIFIED for the branch, not verified-clean (DIVE-2318 pattern)."
          _mg_unverified="${_mg_unverified:+$_mg_unverified; }branch named in result/body (${_br_cands//$'\n'/, }) could not be fully scanned"
        else
          policy_refuse "$E_CONFLICT" done-with-unlanded-branch-in-result DIVE-2577 "$ident" "$ident cannot close: nothing on main shows branch(es) ${_br_cands//$'\n'/, } landed — land them, then task done"
        fi
      fi
    fi
    if [[ $force_merge_gate -eq 1 ]]; then
      # Never a silent bypass: record the forced close (with the overridden PR #
      # if any) to the tamper-evident audit log. The unmerged PR/branch it leaves
      # behind is independently flagged by the weekly hygiene digest (#139).
      # DIVE-2054 (judgment call): same reasoning as the other force-merge-gate
      # site above — task-store override record, fenced for consistency.
      _task_store_audit_log "task.force-merge-gate" ok 0 -- "$ident" "override_pr=${_auto_hit:-none}"
    elif [[ -n "$_auto_hit" ]]; then
      policy_refuse "$E_CONFLICT" done-before-named-pr-merged DIVE-1835 "$ident" "$ident cannot close: open PR ${_sc_hit_slug}#$_auto_hit names it but is not merged — merge it, then task done"
    fi
  fi
  # DIVE-1955 (review, Marcus): STAMP THE RECORD. Every path above that could not
  # reach an answer — an ambiguous bare `#N`, a repo whose listing failed, a dead ref
  # parser, an unresolvable reference, unreadable checks on a confirmed merge — is a
  # non-verdict, and until now it existed only as stderr (gone the moment the terminal
  # scrolls) and an audit row (a different artifact than the one anyone reads). The
  # task row said `done` with no finding, which is exactly the clean verdict the gate
  # declined to make. The marker rides the result so the record itself carries it.
  # Deliberately NOT a block and NOT a refusal: `ambiguous` means we do not know, and
  # a close is still the right outcome. It just may not LOOK verified.
  # And it is gated on `_mg_had_subject`: a close that named no PR, no branch and no
  # delivery had NOTHING pending verification, so `unverified` is the wrong word for
  # it — see _gate_text_names_a_ref for why that distinction is load-bearing. Those
  # closes still get the warn and the audit row; what they do not get is a permanent
  # scare-mark on a record that was never in doubt. The no-PR-at-all escape (the
  # DIVE-1690 shape: work on a branch, result cites a commit, no PR ever opened) is
  # real, but it belongs in the `merge-audit` sweep where someone is deliberately
  # looking — not solved by making this marker louder.
  # Appended, never substituted, so the maker's own text is untouched; and only on a
  # real `done` (a cancel was never gated, so it has nothing to disclaim).
  # DIVE-3458: ride the foreign-delivery record on the result, for the same reason
  # the UNVERIFIED marker rides it — stderr scrolls away and the audit row is a
  # different artifact than the one anyone reads. Appended, never substituted, and
  # only on a real `done`. It goes FIRST so the two markers cannot interleave into
  # one sentence if a close somehow earns both.
  if [[ -n "$_mg_foreign" && "$verb" == "done" ]]; then
    local _fg_base="$result"
    (( want_result )) || _fg_base=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${id};")
    result="${_fg_base}${_fg_base:+

}${_mg_foreign}"
    want_result=1
  fi
  if [[ -n "$_mg_unverified" && $_mg_had_subject -eq 1 && "$verb" == "done" ]]; then
    local _mg_base="$result"
    (( want_result )) || _mg_base=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${id};")
    result="${_mg_base}${_mg_base:+

}[merge-gate: UNVERIFIED — ${_mg_unverified}. This close was NOT confirmed merged-and-green against GitHub; absence of a finding here is not evidence of one. (DIVE-1955)]"
    want_result=1
  fi
  local set_result=""
  if (( want_result )); then
    set_result=", result=$(sqlq_or_null "$result")"
  fi
  db "UPDATE tasks SET status=$(sqlq "$newstatus")${extra}${set_result} WHERE id=${id};"
  # DIVE-3349: the SESSION SEGMENT, written from the one funnel every status verb
  # crosses and immediately after the status write it describes — the same reason
  # the audit row and the ledger row below sit here rather than in each verb: a
  # fourth status verb added later cannot ship without its segment. Design, and
  # why an absent session id is NULL rather than a fallback: src/lib/tasks_db.sh.
  # Best-effort by construction; a bookkeeping insert must not fail a close that
  # has already committed on the line above.
  case "$newstatus" in
    in_progress)             _task_session_open  "$id" ;;
    done|cancelled|blocked)  _task_session_close "$id" ;;
  esac
  # DIVE-3932: the RUN boundary, written from the same funnel and for the same
  # reason as the segment above — a fourth status verb added later cannot ship
  # without opening/closing its attempt. Every writer is best-effort and returns
  # 0 (src/lib/runs.sh), so the status write that already committed on the line
  # above can never be undone by a bookkeeping fault.
  #
  # `blocked` closes the run PARKED, not failed: a row that blocked on a human
  # gate has not failed, and scoring it as a failure would make the reliability
  # metrics read worse exactly when the fleet did the correct thing. `cancelled`
  # closes ABANDONED for the mirror-image reason — the attempt genuinely did not
  # reach its boundary, and calling that "completed" would inflate success rate.
  case "$newstatus" in
    in_progress) run_open "$id" "$ident" "${FIVEDIVE_WAKE_REASON:-task claimed}" >/dev/null 2>&1 || true ;;
    done)        _run_close_for_task "$id" completed "$([[ -n "$handoff_ack" ]] && printf verifier_review || printf task_done)" || true ;;
    cancelled)   _run_close_for_task "$id" abandoned task_cancelled || true ;;
    blocked)     _run_close_for_task "$id" parked    task_blocked   || true ;;
  esac
  [[ -n "$handoff_ack" ]] && handoff_ack_at=$(db "SELECT handoff_ack_at FROM tasks WHERE id=${id};")
  # DIVE-552: if this close finished a LOOP STEP, advance the relay — free the
  # next step (a freed agent step the heartbeat wakes; a freed gate fires its
  # human tap) and close the run when the last step lands. Only on a real `done`
  # of a work step; gate steps advance via their answer, not here. Best-effort:
  # an advance hiccup never fails the close that already committed above.
  if [[ "$verb" == "done" ]]; then
    case "$(_loop_kind "$id")" in
      work) _task_loop_advance "$id" || true ;;
    esac
  fi
  # DIVE-1966/1967: a close reclaims the closed task's worktree node_modules —
  # gitignored, `npm ci`-regenerable, so structurally data-loss-free. The
  # worktree DIRECTORY is never touched (it may hold unpushed commits). Best
  # effort: a reclaim hiccup never fails the status write that already committed.
  if [[ "$verb" == "done" || "$verb" == "cancel" ]]; then
    _task_reclaim_on_close "$ident" "$keep_wt" || true
  fi
  # DIVE-1355: on any close (done/cancel), cascade-unblock dependents whose last
  # blocking edge this close satisfies. Additive to and idempotent with the loop
  # advance above (that path already dropped a loop step's edges, so this finds
  # none left for those). Best-effort — never fails the committed close.
  if [[ "$verb" == "done" || "$verb" == "cancel" ]]; then
    _task_cascade_unblock "$id" || true
  fi
  # --notify (done/cancel only): DM the paired human a one-line ✅/⚠️ summary so
  # autonomous queue work surfaces a finish line. Best-effort; never fails the
  # status write above.
  #
  # Suppress the DM for auto-materialized recurring tasks (from_template_id set):
  # those are agent housekeeping the user never asked for per-occurrence — the
  # daily recap, nightly sweeps, weekly cleanups — and pinging on every fire is
  # the noise Mark flagged. Their result still lands on the record + the daily
  # recap; only the redundant live ping is dropped. Manual/delegated closes
  # (no template parent) still notify. Cheap single-column read, fail-open to
  # "notify" so a DB hiccup never silently swallows a real finish line.
  # DIVE-2410: closing a task MOOTS any gate still open on it — the question can
  # never be answered now, so its button must stop looking answerable. Conditional
  # on the gate being UNANSWERED on purpose: an answered gate had its buttons
  # retired at answer time, and re-editing would only add a "not modified" row.
  # Independent of --notify (that flag governs the human's ✅/⚠️ ping, a different
  # question from whether a dead control is still on their screen).
  #
  # DIVE-2773: THIS IS NOW UNREACHABLE BY CONSTRUCTION and is kept anyway, which is
  # a claim that needs its reasons stated rather than left for the next reader to
  # rediscover. Both close verbs are refused above while a gate is unanswered, so
  # no `done`/`cancel` can arrive here with `need_answered_at IS NULL`; the retire
  # WIRING is still exercised by `task answer`, `task need --withdraw`, a re-filed
  # gate and `task park`, which are the paths that legitimately moot a question.
  # It stays because it is idempotent and free on the reachable path (the SELECT
  # returns nothing), and because it is the backstop if either refusal above is
  # ever scoped narrower — a close that lands on a live gate must not leave a
  # button that looks answerable. Its old test arm was inverted rather than
  # deleted (tests/gate_button_retire_unit.sh): over a live gate the cancel is
  # refused and the button must SURVIVE, because the question is still open.
  if [[ "$verb" == "done" || "$verb" == "cancel" ]]; then
    local _open_gate
    _open_gate=$(db "SELECT 1 FROM tasks WHERE id=${id} AND need_type IS NOT NULL AND need_answered_at IS NULL;" 2>/dev/null || echo "")
    [[ -n "$_open_gate" ]] && { _task_gate_card_apply "$ident" die "task ${verb} with the gate still open" || true; }
  fi
  if (( notify )) && [[ "$verb" == "done" || "$verb" == "cancel" ]]; then
    local from_tmpl
    from_tmpl=$(db "SELECT COALESCE(from_template_id,'') FROM tasks WHERE id=${id};" 2>/dev/null || echo "")
    if [[ -z "$from_tmpl" ]]; then
      _task_close_notify "$ident" "$verb" "$result" || true
    fi
  fi
  # INST-4: the state transition, on the unified timeline.
  #
  # Emitted from the ONE place all three verbs funnel through, not from the three
  # cmd_task_{start,done,cancel} wrappers, so a fourth verb added later cannot
  # ship without its ledger row. The `result` is hashed, not stored: it can carry
  # anything a maker typed, and the ledger must stay safe to read at a lower
  # privilege than the board it describes.
  #
  # A `done` that DELIVERS never gets here — it forks earlier into the handoff
  # write, which emits task.delivered itself. What CAN arrive here carrying a
  # handoff_ack is the verifier picking the review up, and that is `task.review`,
  # a third state distinct from both delivered and done. Conflating it with
  # either would put a claim in the ledger that the rail was built to refuse.
  # DIVE-3251 (FINDING 2) — A STATUS VERB THAT LEAVES NO TRAIL CANNOT BE DEBUGGED
  # AFTER THE FACT. `task start` wrote ZERO audit rows fleet-wide while demonstrably
  # working, so when 58 rows turned up with an empty started_at there was no way from
  # agent-audit.log to tell "the start never wrote, and the OK was a lie" from "it
  # wrote and something cleared it later" — two hypotheses with very different
  # severity. Settling it needed a second, independent store (lifecycle_events) and
  # the luck that it happened to carry a task.started kind.
  #
  # Emitted from the ONE place all three verbs funnel through, for the same reason
  # the ledger row below is: a fourth status verb added later cannot ship without
  # its trail. New cmd names (`task start` / `task done` / `task cancel`), so no
  # existing audit reader loses a row it was matching on.
  #
  # NO `seat=` ARG, AND THE REASON IS BOTH CORRECTNESS AND COST. audit_log already
  # derives the actor itself into three fields — `user` (_actor_identity), `derived`
  # (the uid measurement) and `claimed` (populated ONLY when those two disagree,
  # DIVE-2518). A `seat=$(id -un)` payload arg would be a FOURTH, WEAKER copy of the
  # same fact: it records what this process says, cannot record a disagreement, and
  # sits in the args array where nothing grades it. Provenance the row derives beats
  # provenance the caller supplies. It was also the only forking expression on a path
  # every status verb crosses, and a command substitution in an argument is expanded
  # BEFORE the callee runs — so every test-store call paid a fork for a row the
  # DIVE-2010 fence then withheld. MEASURED, and scoped to what was measured:
  # removing it took tests/task_deliver_merge_gate_unit.sh from +918ms against
  # pristine main to parity (13.2s both, two rounds). It did NOT account for the
  # whole-corpus delta this branch carries (~+45s on 289 harnesses, unchanged by
  # this edit) — that is still unattributed, and is written up in the PR body rather
  # than guessed at here. Copying the idiom from the merge-gate site above is what
  # put it here; that site is a rare path and this one is not.
  _task_store_audit_log "task ${verb}" ok 0 -- "$ident" "status=$newstatus"
  local _lk="task.${newstatus}"
  [[ "$newstatus" == "in_progress" ]] && _lk="task.started"
  [[ -n "$handoff_ack" ]] && _lk="task.review"
  #
  # actor= is the BOARD identity (task_actor), not the OS user the default
  # resolver would supply. The smoke run that caught this had task.created say
  # `dev` and task.started say `agent-dev` for the same person on the same task —
  # two rows in one timeline disagreeing about who acted, which is precisely the
  # failure the shared _actor_identity resolver was meant to prevent. A default
  # is only shared if every site actually takes it.
  ledger_emit "$_lk" ident="$ident" task_id="$id" actor="$(task_actor)" out="$result" \
    detail="$verb${handoff_ack:+ → verifier ${handoff_ack}}"

  # DIVE-3503 — the task boundary is the natural lifetime bound for anything the
  # agent launched for this task, and until now NOTHING happened here: four seats
  # were wedged in one day by shells that outlived the row, and a human unstuck
  # them by hand three separate times. Reaps only agent-written `bash -c` shells
  # older than the grace age, never the caller's own ancestors and never the
  # seat's machinery — see src/lib/reap.sh for the measured predicate. Runs AFTER
  # every write above, so a reaper fault can never cost the status transition.
  case "$verb" in
    done|cancel) declare -F _reap_at_task_boundary >/dev/null 2>&1 && _reap_at_task_boundary "$verb" "$ident" || true ;;
  esac

  local ok_msg="$ident $verb"
  [[ -n "$handoff_ack" ]] && ok_msg+=" — verifier ACK: reviewing"
  ok "$ok_msg" \
     '{id:($i|tonumber), ident:$id, status:$s,
       handoff:(if $h=="" then null else $h end),
       handoffAckAt:(if $ha=="" then null else $ha end)}' \
     --arg i "$id" --arg id "$ident" --arg s "$newstatus" \
     --arg h "$handoff_ack" --arg ha "$handoff_ack_at"
}

# DIVE-1375: fail-loud preflight at `task start` (Bobby gripe #3). Surface the
# identity/auth/repo gaps that otherwise get discovered mid-task — Marcus hit
# the git dubious-ownership wall on DIVE-1356. Every check is best-effort and
# ADVISORY: it prints heads-up warnings to stderr and NEVER blocks the start
# (fail-open). Repo checks run against the caller's cwd, so run `task start`
# from inside the repo you'll work in to get them. Suppress with --no-preflight.
_task_start_preflight() {
  local id="$1" ident="$2" actor="$3"
  local n=0
  _pf() { warn "preflight: $*"; n=$((n+1)); }

  # --- task-level: is the DONE path even reachable by THIS actor? ---
  # Assignee mismatch: the heartbeat only wakes the assignee, so a start by
  # someone else is legit but easy to do by accident — flag the mis-claim now.
  local asignee; asignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};" 2>/dev/null || echo "")
  if [[ -n "$asignee" && -n "$actor" && "$actor" != "cli" && "$asignee" != "$actor" ]]; then
    _pf "assigned to '${asignee}', but you are '${actor}' — confirm you mean to take this over (the heartbeat wakes '${asignee}', not you)."
  fi
  # Pending human gate: this task cannot close via `task done` until the gate is
  # answered (DIVE-555). Cheaper to learn that before doing the work than after.
  local gt ga
  gt=$(db "SELECT COALESCE(need_type,'')        FROM tasks WHERE id=${id};" 2>/dev/null || echo "")
  ga=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};" 2>/dev/null || echo "")
  if [[ -n "$gt" && -z "$ga" ]]; then
    _pf "an unanswered '${gt}' gate is open on this task — 'task done' will be REFUSED until a human answers it (5dive task answer ${ident} ...)."
  fi

  # --- repo-level: only meaningful when cwd is (or should be) a git repo ---
  local gerr
  gerr=$(git -C . rev-parse --is-inside-work-tree 2>&1 >/dev/null)
  if [[ -n "$gerr" ]]; then
    # git refused to even look. The classic case is dubious ownership — EXACTLY
    # the wall Marcus hit on DIVE-1356 — so hand over the one-line fix.
    if printf '%s' "$gerr" | grep -qi 'dubious ownership'; then
      _pf "git refuses this repo (dubious ownership). Fix: git config --global --add safe.directory \"\$(pwd)\" — then retry your git commands."
    fi
    # Otherwise cwd just isn't a git repo → no repo checks apply; stay quiet.
  else
    # Real work tree — run the hygiene/auth checks.
    # Dirty worktree: pre-existing uncommitted changes get swept into your
    # commit on a shared checkout — a repeat gotcha across this fleet.
    local dirty; dirty=$(git -C . status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${dirty:-0}" -gt 0 ]]; then
      _pf "worktree is DIRTY (${dirty} uncommitted path(s)) — a commit here may sweep sibling WIP; branch from origin/main or use a fresh worktree."
    fi
    # Git identity: an unset committer silently uses a default author that trips
    # remote author checks (e.g. the Vercel team gate on this project).
    local gemail; gemail=$(git -C . config user.email 2>/dev/null || echo "")
    [[ -z "$gemail" ]] && _pf "git user.email is unset here — commits will use a default identity that may be rejected by the remote's author check."
    # Push reachability: if there's an origin, sanity-check that SOME push
    # credential is on hand. Offline heuristic — no network probe.
    local remote; remote=$(git -C . remote get-url origin 2>/dev/null || echo "")
    if [[ -n "$remote" ]]; then
      case "$remote" in
        git@*|ssh://*)
          if ! ls "$HOME"/.ssh/id_* >/dev/null 2>&1 && [[ ! -e /home/claude/.ssh/id_ed25519 ]]; then
            _pf "origin is an SSH remote but no SSH key found under ~/.ssh — a push will fail; stage the key before you plan to push."
          fi ;;
        https://*)
          if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
            _pf "origin is an HTTPS remote but 'gh auth' isn't logged in — a push will prompt/fail; authenticate before you plan to push."
          fi ;;
      esac
    fi
  fi

  unset -f _pf
  _TASK_PREFLIGHT_WARNINGS="$n"
  (( n > 0 )) && step "task ${ident}: ${n} preflight heads-up above — resolve before the work needs them (advisory; start proceeded)."
  return 0
}

# DIVE-3251: two clocks, written by the same COALESCE and cleared by different
# things. `started_at` is the CURRENT claim's clock, which the heartbeat reclaim
# ladder is allowed to NULL so the age and the per-task nudge counter restart.
# `first_started_at` is the durable record that work ever started, and NOTHING in
# the nudge path may touch it. Seeded from started_at as well as now(), so a row
# already in flight when this ships records its real start rather than the moment
# of its next re-claim. See src/lib/tasks_db.sh for the full rationale.
cmd_task_start()  { _task_status_cmd in_progress ", started_at=COALESCE(started_at, datetime('now')), first_started_at=COALESCE(first_started_at, started_at, datetime('now'))" start "$@"; }
# DIVE-2477: COALESCE, not a bare stamp — FIRST close wins. These wrote
# done_at=datetime('now') unconditionally, so any second close silently moved the
# original close timestamp forward: measured on a fixture, a row closed at T then
# a BARE `task done` (no --result, the one shape DIVE-2464's result guard
# correctly stays silent on) had done_at rewritten to 'now'. That matters because
# DIVE-2464's own refusal quotes done_at as the evidence of who closed when
# ("is ALREADY done (closed <done_at>; ...)") — a bare re-close in between made
# the refusal cite a time that was not the close it was protecting.
# `task start` next to them has always COALESCEd started_at; this is that rule
# applied to the close clock. Correct only because the one verb that REOPENS a
# closed row (`task reject`) now clears done_at — otherwise this would preserve a
# stale value as the real close time. tests/task_close_preserves_done_at_unit.sh
# grades both directions.
cmd_task_done()   { _task_status_cmd done ", done_at=COALESCE(done_at, datetime('now'))" done "$@"; }
cmd_task_cancel() { _task_status_cmd cancelled ", done_at=COALESCE(done_at, datetime('now'))" cancel "$@"; }

# Print one deterministic nonterminal blocker as IDENT|STATUS, or nothing.
# Shared by status-changing entry points that must preserve the blocked-edge
# invariant. Terminal blockers deliberately do not count: a stale blocked row
# whose dependencies are all done/cancelled must remain actionable (DIVE-2317).
_task_live_blocker() {
  local id="$1"
  db "SELECT b.ident || '|' || b.status
      FROM task_deps d
      JOIN tasks b ON b.id=d.blocked_by
      WHERE d.task_id=${id}
        AND b.status NOT IN ('done','cancelled')
      ORDER BY b.id
      LIMIT 1;"
}

# DIVE-1830: `task deliver` — the maker records the PR that delivers this task,
# then hands off to the verifier for review. This is the OPT-IN half of the
# merge-gate: once a task carries a delivery_ref, its `task done` will not close
# until that PR is MERGED to main (see the gate in _task_status_cmd). Delivery
# reuses the DIVE-477 in-review handoff — it does NOT invent a new status. When
# there is no distinct verifier, the delivery is still recorded but the task
# stays in_progress: a verifier must close it after the merge (done ≠ delivered).
# _task_terminal_for_verifier <id> — DIVE-3098. TRUE (exit 0) when the row is
# TERMINAL FOR THE VERIFIER and still NON-TERMINAL FOR THE ROW:
#
#   a verifier grade recorded by `task verify --no-done` (graded_at stamped,
#   graded_by != maker_agent)  AND  delivery_ref bound.
#
# Such a row SATISFIES the goal Stop hook and is EXEMPT from the rot-nudger — the
# verifier has discharged their role and the remaining work is a MERGE, owed by the
# maker or the ship approver. `status` stays open; the row closes only on merge, so
# `done` keeps meaning merged-to-main (DIVE-1835) and nobody gains a terminal-looking
# verb short of it. That anti-goal is why this is a PREDICATE and not a status value.
#
# Both halves are load-bearing and the negative arms prove it: a grade with no
# delivery_ref is a verdict nobody can check, and a delivery_ref with no grade is the
# ungraded case the nudger exists for. Neither alone qualifies.
_task_terminal_for_verifier() {
  local id="$1"
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  local hit
  hit=$(db "SELECT 1 FROM tasks WHERE id=${id} AND ${_TASKS_TFV_SQL};" 2>/dev/null) || return 1
  [[ "$hit" == "1" ]]
}

# _task_merge_owner <id> — who owes the merge on a graded-and-waiting row. The maker
# built it and the verifier has finished; naming the verifier here would point at the
# one person with nothing left to do. Falls back to the assignee.
_task_merge_owner() {
  local id="$1" who
  who=$(db "SELECT COALESCE(NULLIF(maker_agent,''), COALESCE(assignee,'?')) FROM tasks WHERE id=${id};" 2>/dev/null)
  printf '%s' "${who:-?}"
}
