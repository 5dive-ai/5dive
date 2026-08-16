# -------- 5dive task — crud --------
#
# Split out of src/cmd_task.sh (DIVE-3278): the CRUD verbs: add, ls, show, gate-history, assign, verifier.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
# src/cmd_task.sh when the split tree is used (tests source src/cmd_task.sh).
# Function definitions only — never execute this file directly.
cmd_task_add() {
  # DIVE-3077: a run that has declared itself a test may not write to the PROD
  # board. Refuse BEFORE tasks_db_init so a refused call touches nothing.
  _task_board_write_allowed || fail "$E_PERMISSION" \
    "refusing to write to the production task board from a test run (FIVEDIVE_HARNESS/FIVEDIVE_TEST/FIVEDIVE_E2E/COUNCIL_MOCK/FIVEDIVE_NO_HUMAN_SEND is set and TASKS_DB resolves to $(_task_real_prod_tasks_db)). Point TASKS_DB/STATE_DIR at a throwaway store."
  tasks_db_init
  local body="" priority="medium" assignee="" parent="" from="" recurring="" fresh="" project="dive"
  local on_overlap="" overlap_bound=""   # DIVE-2272: per-template overlap policy
  local accept="" verify_cmd="" max_iters="" verifier="" task_budget="" no_verify="" branch=""
  local customer_facing="" already_blocked="" materialized=""
  # DIVE-2627: which flag supplied each prose value (see _read_prose_file).
  local body_src="" accept_src=""
  local -a words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --body=*)      _prose_flag_dupe --body "$body_src"; body="${1#*=}"; body_src="--body" ;;
      # DIVE-2627: the body read VERBATIM from a file. A task body is the
      # permanent spec a verifier grades against, so a backtick the caller's
      # shell ate is a silently wrong record nobody can detect afterwards.
      --body-file=*) _prose_flag_dupe --body-file "$body_src"
                     _read_prose_file --body-file "${1#*=}"
                     body="$_PROSE_FILE_VALUE"; body_src="--body-file" ;;
      --priority=*)  priority="${1#*=}" ;;
      --assignee=*)  assignee="${1#*=}" ;;
      --parent=*)    parent="${1#*=}" ;;
      --project=*)   project="${1#*=}" ;;
      --from=*)      from="${1#*=}" ;;
      --recurring=*) recurring="${1#*=}" ;;
      --schedule=*)  recurring="${1#*=}" ;;
      # DIVE-2272 (decision DIVE-2270): the per-template overlap policy.
      --on-overlap=*)    on_overlap="${1#*=}" ;;
      --overlap-bound=*) overlap_bound="${1#*=}" ;;
      --fresh)       fresh="1" ;;
      --no-fresh)    fresh="0" ;;
      # DIVE-476: loop-spec — declarative verify loop persisted on the row so the
      # (c) verify-runner reads its inputs off the task instead of re-passing them.
      --accept=*)    _prose_flag_dupe --accept "$accept_src"; accept="${1#*=}"; accept_src="--accept" ;;
      # DIVE-2627: acceptance criteria read VERBATIM from a file. This is the
      # single highest-value member of the class after --ask: it is literally the
      # text the VERIFIER grades the work against.
      --accept-file=*) _prose_flag_dupe --accept-file "$accept_src"
                       _read_prose_file --accept-file "${1#*=}"
                       accept="$_PROSE_FILE_VALUE"; accept_src="--accept-file" ;;
      --verify=*)    verify_cmd="${1#*=}" ;;
      --max-iters=*) max_iters="${1#*=}" ;;
      --verifier=*)  verifier="${1#*=}" ;;
      # DIVE-969: explicit opt-out of the verifier-by-default posture. A plain
      # `task done` closes the resulting task directly (no maker→grader handoff).
      --no-verify)   no_verify="1" ;;
      # DIVE-2681 (the filing cap): the two declared escapes from the internal
      # classifier. --customer says the scan was WRONG (this is a customer
      # surface); --already-blocked=<what> says the scan was RIGHT and this is
      # the stated exception — it already blocked shipped work. The reason is
      # mandatory on the exception and is written into the body, because an
      # exception nobody can audit later is not an exception, it is an opt-out.
      --customer)          customer_facing="1" ;;
      # DIVE-2794 arm two: set by the internal writers that turn one approved
      # decision into N rows. Exempts the WIP cap only — never the DIVE-2681
      # filing cap, which is about what a title IS, not how many there are.
      --materialized)      materialized="1" ;;
      --already-blocked=*) already_blocked="${1#*=}" ;;
      # DIVE-824: per-run spend cap carried on the row (sibling to verify --timeout).
      # Value is either a bare token count or a "$cost" dollar figure.
      --task-budget=*) task_budget="${1#*=}" ;;
      # DIVE-1697: seed a 'Branch: <name>' line in the body so a delegated-push
      # maker task declares its DIVE-1462 branch binding at creation.
      --branch=*)    branch="${1#*=}" ;;
      --)            shift; words+=("$@"); break ;;
      -*)            fail "$E_USAGE" "unknown flag: $1" ;;
      *)             words+=("$1") ;;
    esac
    shift
  done
  local title="${words[*]:-}"
  [[ -n "$title" ]] || fail "$E_USAGE" "usage: 5dive task add <title...> [flags: 5dive task --help]"
  # DIVE-3107: a flag written AFTER the `--` end-of-flags separator is not a flag
  # at all — it is positional title text, and the parser above accepts it in
  # silence. DIVE-3100 was filed with a 628-char title whose text began
  # `--body=MEASURED 2026-08-09...` and an EMPTY body; nobody saw it until the
  # grader read the row days later, by which point delivered title/body are
  # frozen and the row could not be repaired in place. Add-time is the only
  # moment the filer can still act on it, so refuse here rather than store it.
  # Two independent tells, either sufficient:
  #   1. a `--<word>=` token in the title — a flag name that leaked across `--`
  #   2. a title over 200 chars — no legitimate title is that long
  # Skipped for --materialized (the internal writers in cmd_goal/cmd_loop/
  # cmd_objective/cmd_proof/cmd_loop_pack): they build the argv programmatically
  # with every flag already on the correct side of `--`, so the swallow this
  # guards cannot occur there, while their titles are user prose ("Goal: <outcome>")
  # that may legitimately run long — and a refusal mid-batch aborts a whole
  # materialization. Unlike the DIVE-2681 filing cap, which is about what a title
  # MEANS, this one is about how the command line was TYPED.
  if [[ -z "$materialized" ]]; then
    local _w _leaked=""
    for _w in "${words[@]}"; do
      if [[ "$_w" =~ ^--[A-Za-z][A-Za-z0-9-]*= ]]; then _leaked="${_w%%=*}"; break; fi
    done
    if [[ -n "$_leaked" ]]; then
      fail "$E_USAGE" "refusing: the title contains the flag token '${_leaked}=' — it was written AFTER the '--' end-of-flags separator, so it parsed as TITLE TEXT and '${_leaked}' was never applied (this is how DIVE-3100 got a 628-char title and an empty body). Move every flag BEFORE the '--': 5dive task add ${_leaked}=\"...\" -- \"<title>\". Title as parsed (${#title} chars): ${title:0:120}$([[ ${#title} -gt 120 ]] && printf '...')"
    fi
    if (( ${#title} > 200 )); then
      fail "$E_USAGE" "refusing: the title is ${#title} chars (limit 200) — a title that long is almost always body text swallowed past the '--' end-of-flags separator, where flags parse as positional title words instead. Put the prose in --body=/--body-file= BEFORE the '--' and keep the title to one line. Title as parsed: ${title:0:120}..."
    fi
  fi
  valid_task_priority "$priority" || fail "$E_VALIDATION" "bad priority '$priority' (low|medium|high|urgent)"
  # DIVE-476: --max-iters is the maker→verifier loop cap; must be a positive int.
  [[ -z "$max_iters" || "$max_iters" =~ ^[1-9][0-9]*$ ]] \
    || fail "$E_VALIDATION" "--max-iters must be a positive integer"
  # DIVE-824: --task-budget is EITHER a bare token count ("50000") OR a dollar
  # cost ("$1.50" / "$2"). Reject anything else so a malformed cap can't silently
  # store as a no-op. Stored verbatim; the loop runner interprets the form.
  # DIVE-2794 adds a fourth accepted value: the literal `none`, which is the
  # ONLY exemption from the now-enforced 5M default. It is spelled rather than
  # implied on purpose — see _hb_task_budget_sweep's header for why --customer
  # and priority were both rejected as implicit carve-outs.
  [[ -z "$task_budget" || "$task_budget" =~ ^[1-9][0-9]*$ || "$task_budget" =~ ^\$[0-9]+(\.[0-9]+)?$ || "$task_budget" == "none" ]] \
    || fail "$E_VALIDATION" "--task-budget must be a token count (e.g. 50000), a dollar cost (e.g. \$1.50), or 'none'. NOTE: advisory only since DIVE-3343 — nothing enforces it"
  # DIVE-1697: --branch seeds the delegated-push 'Branch: <name>' binding into the
  # body up front (same line set-branch writes/upserts later).
  if [[ -n "$branch" ]]; then
    [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
      || fail "$E_VALIDATION" "invalid --branch '$branch' (letters/digits/._/- only, no whitespace)"
    body=$(_task_upsert_branch_line "$body" "$branch")
  fi
  # --recurring=<cron> makes this a TEMPLATE (kind='recurring'), not a worked
  # task — the step-2 materializer clones it into a standard todo on schedule.
  # A template + an explicit --parent is nonsensical (instances are top-level),
  # so reject the combo rather than store a confusing row.
  local kind="standard" schedule_sql="NULL"
  if [[ -n "$recurring" ]]; then
    valid_cron_expr "$recurring" || fail "$E_VALIDATION" "bad --recurring '$recurring' (need a 5-field cron expr, e.g. \"0 2 * * *\")"
    [[ -z "$parent" ]] || fail "$E_VALIDATION" "--recurring can't be combined with --parent (a template has no parent)"
    kind="recurring"; schedule_sql=$(sqlq "$recurring")
  fi
  # DIVE-2272: the overlap policy is a property of a TEMPLATE. Refuse it on a
  # standard row rather than storing a column nothing will ever read — a flag
  # that is silently inert is the same defect class as a guard that swallows its
  # own failure, one layer up.
  local on_overlap_sql="NULL" overlap_bound_sql="NULL"
  if [[ -n "$on_overlap" || -n "$overlap_bound" ]]; then
    [[ "$kind" == "recurring" ]] \
      || fail "$E_VALIDATION" "--on-overlap/--overlap-bound only apply to a recurring TEMPLATE (add --recurring=<cron>); on a one-off task there is no next slot to skip or spawn"
  fi
  if [[ -n "$on_overlap" ]]; then
    [[ "$on_overlap" == "skip" || "$on_overlap" == "spawn" ]] \
      || fail "$E_VALIDATION" "bad --on-overlap '$on_overlap' (skip|spawn). skip = an open instance suppresses the next slot (the default, today's behaviour); spawn = fire anyway up to --overlap-bound open instances, then skip and record the suppression"
    on_overlap_sql=$(sqlq "$on_overlap")
  fi
  if [[ -n "$overlap_bound" ]]; then
    [[ "$overlap_bound" =~ ^[1-9][0-9]*$ ]] \
      || fail "$E_VALIDATION" "bad --overlap-bound '$overlap_bound' (positive integer)"
    [[ "$on_overlap" == "spawn" ]] \
      || fail "$E_VALIDATION" "--overlap-bound only means anything with --on-overlap=spawn (under skip the first open instance already suppresses, so there is no bound to reach)"
    overlap_bound_sql="$overlap_bound"
  fi
  # DIVE-484: resolve the target project (default 'dive'). Accept the key
  # case-insensitively; the row must exist (create one with `5dive project add`).
  project="${project,,}"
  local proj_lead
  proj_lead=$(db "SELECT COALESCE(lead_agent,'') FROM projects WHERE key=$(sqlq "$project") AND status='active';")
  if [[ -z "$proj_lead" ]]; then
    db "SELECT 1 FROM projects WHERE key=$(sqlq "$project") AND status='active';" | grep -q 1 \
      || fail "$E_NOT_FOUND" "no active project '$project' (see: 5dive project ls; create: 5dive project add)"
  fi
  local parent_sql="NULL"
  if [[ -n "$parent" ]]; then
    # DIVE-3275: the SAME guard `task set-parent` carries, on the surface that
    # actually misfired. `--parent=2895` filed DIVE-3273 under DIVE-2708 with no
    # error at all — a valid global row id naming a row from another month —
    # because the id and ident number spaces have diverged and this line took the
    # number on faith. The remedy shipped at the time was a written rule ("always
    # --parent=DIVE-####"); a rule is not a guard, and the wrong-row edge is
    # invisible by construction, since it renders on a row nobody is looking at.
    # See _task_resolve_ref_strict (src/lib/tasks_db.sh) for the measurement.
    _task_resolve_ref_strict "$parent" "--parent"; parent_sql="$RESOLVED_TASK_ID"
  fi
  # DIVE-2449: an explicit --parent is the graph edge, so it suppresses this
  # advisory regardless of prose. Without one, measure the narrow numbered
  # follow-up title before inserting the row; the warning itself is emitted only
  # after the new ident exists, and JSON carries the same receipt.
  local followup_warn_ident="" followup_warn_kind="" followup_warn_number="" followup_warn_matches=""
  if [[ "$kind" == "standard" && -z "$parent" ]]; then
    _task_unparented_followup_advisory "$title"
    followup_warn_ident="$_TASK_FOLLOWUP_WARN_IDENT"
    followup_warn_kind="$_TASK_FOLLOWUP_WARN_KIND"
    followup_warn_number="$_TASK_FOLLOWUP_WARN_NUMBER"
    followup_warn_matches="$_TASK_FOLLOWUP_WARN_MATCHES"
  fi
  # DIVE-980: an explicit --assignee may be a literal agent name OR an org-chart
  # TOKEN (role:<r> / charter:<kw> / @name). Route tokens through the org chart;
  # a literal name is trusted verbatim (explicit --assignee always wins). A token
  # with no UNIQUE holder is a hard, EXPLAINABLE error — never a silent misroute.
  local role_pick_note=""
  if [[ -n "$assignee" ]]; then
    case "$assignee" in
      role:*|charter:*|@*)
        local _resolved _token="$assignee"; _resolved=$(_org_resolve_assignee "$assignee")
        # DIVE-3366: a role with TWO holders is not an unanswerable question — it
        # is the one the board most needs answered, and answering it with a
        # refusal is what sends every row to the seat the filer remembers. Runs
        # ONLY on the empty (previously fatal) path, so a token that already
        # resolved is untouched. The verifier seat is excluded from the
        # candidates, which is how a loop row gets a build lane that is not its
        # own grader instead of the refusal below.
        if [[ -z "$_resolved" && "$_token" == role:* ]] \
           && _task_role_least_loaded "${_token#role:}" "$verifier"; then
          _resolved="$_TASK_ROLE_PICK"
          # Recorded on the row, not only warned at the prompt: the counts that
          # made this choice have moved by the time anyone audits it.
          role_pick_note="ROUTED BY LOAD (DIVE-3366): --assignee=${_token} -> ${_resolved}${verifier:+ (verifier '${verifier}' excluded from the candidates)}. Open-row counts at filing: ${_TASK_ROLE_PICK_BASIS}."
          warn "$role_pick_note"
        fi
        [[ -n "$_resolved" ]] || fail "$E_NOT_FOUND" "--assignee='$assignee' has no unique holder in the org chart — name an agent, or fix the role: 5dive org set"
        assignee="$_resolved"
        ;;
    esac
  fi
  # DIVE-3344: and now that the token is resolved, the name has to NAME SOMETHING.
  # "a literal name is trusted verbatim" above was the whole defect: the picker
  # dispatches on this column, so a typo'd lane is a row that is never picked and
  # never says why. Checked on the EXPLICIT input only — the DIVE-333 default
  # below is derived from the project lead / org coordinator, and refusing an add
  # because the CHART is stale would punish the filer for someone else's data.
  # `task orphans` is what surfaces that case. See _task_require_lane (routing.sh)
  # for why `cli` is refused here and accepted two lines down.
  _task_require_lane "$assignee" "--assignee"
  _task_require_lane "$verifier" "--verifier"
  _task_require_principal "$from" "--from"
  # fresh: per-task clean-session pref (DIVE-138). Recurring templates default to
  # fresh=1 (clean each run — Mark's decision for the community/marketing jobs)
  # and carry it onto every materialized instance; an explicit --fresh/--no-fresh
  # overrides. Standard tasks leave it NULL (fall back to the agent-level
  # heartbeat fresh setting at wake).
  local fresh_sql="NULL"
  if [[ -n "$fresh" ]]; then fresh_sql="$fresh"
  elif [[ "$kind" == "recurring" ]]; then fresh_sql="1"; fi
  # DIVE-333: an unassigned STANDARD task stalls — the heartbeat only wakes an
  # assignee. Default it to the org's coordinator so it always has an owner.
  # Recurring TEMPLATES stay unassigned (they're inert until materialized; the
  # instance gets coordinated when it's cloned as a standard task).
  # DIVE-333 + DIVE-484: default an unassigned standard task to a coordinator so
  # the heartbeat can wake an owner. Prefer the PROJECT's own lead_agent; fall
  # back to the org-wide coordinator when the project has none.
  local auto_coordinated=0
  if [[ -z "$assignee" && "$kind" == "standard" ]]; then
    assignee="$proj_lead"
    [[ -z "$assignee" ]] && assignee=$(_task_resolve_coordinator)
    [[ -n "$assignee" ]] && auto_coordinated=1
  fi
  # DIVE-3097: an explicit --verifier naming this row's own (now-fully-resolved)
  # assignee reaches the IDENTICAL end state `task verifier` already refuses —
  # "'X' is <ident>'s own assignee — a maker can't grade itself" — but `task add`
  # had zero guard on this attach point, so the same state was one flag combo
  # away with no refusal at all (DIVE-2899: assignee=dev3, verifier=dev3,
  # delivered_at NULL — a maker booked as its own grader, never handed off).
  # Checked AFTER both --assignee resolution steps above (the org-chart token
  # lookup and the DIVE-333 auto-coordinate default), so a --verifier that only
  # collides with an IMPLIED assignee (nothing passed on the command line) is
  # caught too, not just a literal --assignee=X --verifier=X pair. Never fires on
  # the verify-BY-DEFAULT picker below — that path only runs when $verifier is
  # still empty here, and _task_default_verifier already excludes the assignee by
  # construction (see the "distinct from the maker" chain above).
  if [[ -n "$verifier" && -n "$assignee" && "$verifier" == "$assignee" ]]; then
    fail "$E_VALIDATION" "'$verifier' is this task's own assignee ('$assignee') — a maker can't grade itself (pick a different --verifier, or drop --assignee and let it default so the two can't collide)"
  fi
  # DIVE-2681: the filing cap, enforced at the keystroke. Classify FIRST, because
  # the classification feeds two separate controls below (the refusal here, and
  # the verifier-rail skip further down). --customer declares the classifier
  # wrong and turns both off; --already-blocked declares the stated exception and
  # turns off only the refusal, recording its reason in the body.
  local internal_reason=""
  if [[ "$kind" == "standard" && -z "$customer_facing" ]]; then
    internal_reason=$(_task_internal_subject_reason "$title")
  fi
  # THE CAP GOVERNS THE SHARED BOARD, SO IT ONLY APPLIES TO THE SHARED BOARD.
  # Found 2026-08-09 by widening the classifier above: 24 harnesses seed rows with
  # titles like "w review gate" and "smoke previous work", and once enough of them
  # land in one fixture store the cap starts refusing a TEST's setup — which is
  # not a filing decision at all, it is a rig building a fixture. The narrow scan
  # hid this by never matching those titles; it was always the wrong scope.
  # Store identity is the same primitive _task_human_send_allowed (DIVE-1506) uses
  # one control over, for the same "a fixture must not act on prod" reason.
  # HIGH AND URGENT ARE NEVER CAPPED (lodar, 2026-08-09: "maybe refuse only low
  # and med priority tasks"). The cap exists to stop the fleet filing routine
  # observations about itself, and a quota that can block a SERIOUS finding is a
  # quota that will eventually eat one — the cost of the two failure directions
  # is not symmetric. An agent that has judged something high or urgent has said
  # more about it than any title scan can, so that judgement wins. This also
  # narrows what the escapes are for: --already-blocked is now about the stated
  # exception at medium, not a way to force a serious row through.
  local _cap_exempt_priority=""
  [[ "$priority" == "high" || "$priority" == "urgent" ]] && _cap_exempt_priority=1
  if _task_filing_cap_store_is_prod && [[ -z "$_cap_exempt_priority" && -n "$internal_reason" && -z "$already_blocked" && "${FIVE_FILING_CAP:-1}" != "0" ]]; then
    # `|| true` on the read as well as the newline at the producer: two
    # independent guards, because a filing rule must never be able to take
    # `task add` down. If the read ever comes back empty the cap declines to
    # enforce rather than dying — a control that fails OPEN is the right
    # posture for a quota, and the wrong one for a security check.
    local _hits=0 _win=0; read -r _hits _win < <(_task_internal_recent_ratio 20) || true
    [[ "$_hits" =~ ^[0-9]+$ ]] || _hits=0
    [[ "$_win"  =~ ^[0-9]+$ ]] || _win=0
    # Only enforce once the window is big enough to mean anything — on a fresh
    # board a 1-in-4 rule computed over three rows is noise, not a signal.
    if (( _win >= 8 )) && (( (_hits + 1) * 4 > (_win + 1) )); then
      # A REFUSAL MUST LEAVE THE FINDING SOMEWHERE (lodar, 2026-08-09: "if task
      # is refused where will it be logged if something serious found?"). Until
      # now: nowhere. `fail` printed to the caller's terminal and returned, so a
      # refused row left no record of its own title — the cap could eat a real
      # finding and neither the filer's next session nor anyone auditing the cap
      # could recover what was lost. policy_refuse writes the TITLE into
      # policy_refusals.detail and emits a policy.refused lifecycle event, so
      # `5dive task refusals` and the ledger both hold it. It fails with the same
      # code afterwards, so the refusal itself is unchanged.
      #
      # The ident slot takes the would-be title rather than an ident, because at
      # this point in `task add` the row does not exist and never will — the
      # whole event is "this title was not allowed to become a row". Recording a
      # synthetic ident would be worse than none: it would look like a lookup key.
      policy_refuse "$E_VALIDATION" filing-cap-internal-machinery DIVE-2681 "(unfiled) ${title}" \
        "filing cap: ${_hits} of the last ${_win} rows are already internal machinery — this one would make it $((_hits + 1))/$((_win + 1)), over the 1-in-4 cap.
REFUSED TITLE (recorded in policy_refusals, not lost): ${title}
An internal-machinery finding gets its own ident ONLY if it has ALREADY blocked shipped work. Otherwise it belongs in the body of the row it was found on, or in the team wiki.
  · it is serious                  →  --priority=high (high and urgent are never capped)
  · it already blocked something   →  --already-blocked='<what it blocked>'
  · the scan is wrong, this is a customer surface  →  --customer
  · fleet-wide override (emergencies)  →  FIVE_FILING_CAP=0"
    fi
  fi
  # DIVE-3245 — THE PER-FILER VOLUME CAP, beside the ratio cap above rather than
  # replacing it, because they bind different things and both are needed.
  # DIVE-2681 caps the PROPORTION of internal-machinery titles fleet-wide; this
  # caps the VOLUME one filer can add per rolling 24h whatever the titles say.
  # Measured: main filed 404 low/medium rows in 30 days and almost none of them
  # classify as machinery, so the ratio cap never saw them.
  #
  # THERE IS NO BYPASS FLAG, deliberately (DIVE-3245): "the population this exists
  # to slow down is exactly the population that would reach for one." The escape is
  # --priority=high|urgent, which is BETTER than a flag precisely because it is not
  # a bypass — it is a claim about severity, recorded on the row, visible to
  # everyone, and falsifiable later. An env kill-switch would be invisible in the
  # record, which is the property that makes it worth refusing.
  #
  # IT STILL FAILS OPEN, which is not a bypass and is the same posture the ratio
  # cap takes: if the count cannot be read the cap declines to enforce rather than
  # taking `task add` down. A quota that can break filing is worse than a quota
  # that occasionally misses.
  if [[ "$kind" == "standard" && -z "$materialized" && -z "$_cap_exempt_priority" ]] \
     && _task_filing_cap_store_is_prod; then
    local _vfiler; _vfiler=$(task_actor "$from") || _vfiler=""
    # `cli` is the unmeasurable-actor sentinel, not a person with a filing habit.
    if [[ -n "$_vfiler" && "$_vfiler" != "cli" ]]; then
      local _v24; _v24=$(_task_filer_low_med_24h "$_vfiler") || _v24=""
      if [[ "$_v24" =~ ^[0-9]+$ ]] && (( _v24 >= _TASK_FILING_DAILY_CAP )); then
        # Counted for the same reason the WIP cap counts its trips: whether this
        # binds constantly is a fact about INFLOW, and it decides whether 15 was
        # the right number — measured later, rather than re-argued.
        db "INSERT INTO task_prefs (key,value) VALUES ('filing_volume_cap_trips','1')
            ON CONFLICT(key) DO UPDATE SET value=CAST(CAST(value AS INT)+1 AS TEXT), updated_at=datetime('now');" 2>/dev/null || true
        # DISTINCT SLUG from the ratio cap's, so `task refusals` and the ledger can
        # separate "you file too much" from "the board is too full of machinery" —
        # they have different remedies and one slug would merge the two populations
        # in exactly the data that decides whether either number is right.
        # The message NAMES THE ALTERNATIVE rather than only the limit, and points
        # at the row the finding came from — which is where DIVE-3245 phase 2 will
        # put findings, so the instruction does not change under people later.
        policy_refuse "$E_VALIDATION" filing-cap-daily-volume DIVE-3245 "(unfiled) ${title}" \
          "filing cap: ${_vfiler} has filed ${_v24} low/medium rows in the last 24h (cap ${_TASK_FILING_DAILY_CAP}, rolling).
REFUSED TITLE (recorded in policy_refusals, not lost): ${title}
This is a budget on NEW ROWS, not on noticing things. Put it where it already has context:
  · a finding on work you are doing  →  append it to the BODY of the row you found it on
  · durable, reusable knowledge      →  community/wiki/ (see the compile-knowledge skill)
  · someone must ACT and it is serious →  --priority=high (high and urgent are never capped)
There is no bypass flag. If it is serious enough to need one, it is serious enough to be high."
      fi
    fi
  fi

  # DIVE-2794 arm two: the WIP cap, checked here so it shares the DIVE-2681
  # store-identity and refusal machinery rather than adding a second, disagreeing
  # refusal to the same verb.
  #
  # EXEMPT: MATERIALIZATION, NOT FILING. Six internal writers reach this function
  # (cmd_goal x2, cmd_loop, cmd_loop_pack, cmd_objective, cmd_proof). They turn
  # ONE already-approved decision into N rows, so a cap firing halfway through
  # leaves a HALF-MATERIALIZED plan — some children exist, some do not, and a
  # loop driver is already waiting on a child list that is short. That is a
  # silent, undesigned state, and strictly worse than an uncapped lane. They pass
  # --materialized and are exempt; the rows they create still COUNT toward the
  # lane, so the next HUMAN filing is the one that gets refused.
  #
  # PRIORITY. lodar ruled 2026-08-09 that only low and med get the hard refusal —
  # "a quota that can block a SERIOUS finding will eventually eat one". That rule
  # stands here verbatim. What it does not say, because nobody asked, is that a
  # high/urgent row must be filed to the lane first named: so on a full lane those
  # are REDIRECTED, never refused. The message names the lanes with headroom and
  # `--assignee=<other>` succeeds immediately, so nothing is ever lost. And if
  # EVERY lane is at cap the row lands anyway, uncapped, and trips the counter
  # loudly — at that point the fleet is genuinely saturated and refusing a serious
  # finding is the worse of the two failures. That branch existing is precisely
  # what lets the rest of the rule be strict.
  if [[ "$kind" == "standard" && -z "$materialized" && "$task_budget" != "none" \
        && "${FIVE_WIP_CAP:-1}" != "0" && -n "$assignee" ]] && _task_filing_cap_store_is_prod; then
    local _wcap _wact
    _wcap=$(_task_wip_cap "$assignee") || _wcap=""
    _wact=$(_task_lane_actionable "$assignee")
    if [[ "$_wcap" =~ ^[0-9]+$ && "$_wact" =~ ^[0-9]+$ ]] && (( _wact >= _wcap )); then
      # Counted on every trip, including the redirect and the saturated-fleet
      # landing. If lanes hit the cap constantly that is a signal about INFLOW,
      # and it is the number that says whether the frozen cap wants a scheduled
      # decay after all — measured, rather than argued.
      db "INSERT INTO task_prefs (key,value) VALUES ('wip_cap_trips','1')
          ON CONFLICT(key) DO UPDATE SET value=CAST(CAST(value AS INT)+1 AS TEXT), updated_at=datetime('now');" 2>/dev/null || true
      local _oldest; _oldest=$(_task_lane_oldest "$assignee" 3)
      if [[ "$priority" == "high" || "$priority" == "urgent" ]]; then
        local _free; _free=$(_task_lanes_with_headroom "$assignee")
        if [[ -n "$_free" ]]; then
          # DISTINCT SLUG from the hard refusal below, and not a cosmetic choice:
          # the slug is the key `task refusals` and the ledger group by, so one
          # slug over both branches would make a REDIRECT (nothing lost, re-file
          # elsewhere) indistinguishable from a REFUSAL (close something first)
          # in exactly the data main needs to separate them in. Caught by
          # tests/policy_refusals_unit.sh's duplicate-slug arm.
          policy_refuse "$E_VALIDATION" wip-cap-lane-redirect DIVE-2794 "(unfiled) ${title}" \
            "lane '${assignee}' is at its WIP cap (${_wact}/${_wcap} actionable). A ${priority} row is never refused — it is REDIRECTED, so re-file it to a lane with room:
${_oldest}
  lanes with headroom:  ${_free}
  →  5dive task add \"${title}\" --priority=${priority} --assignee=<one of the above>
Nothing is lost: this title is recorded in policy_refusals, and the re-file succeeds immediately."
        else
          # Saturated fleet: land it. Loudly.
          warn "every lane is at its WIP cap — filing '${title}' to '${assignee}' anyway because a ${priority} row is never refused. The fleet is saturated (lane ${_wact}/${_wcap}); this is recorded in wip_cap_trips."
        fi
      else
        policy_refuse "$E_VALIDATION" wip-cap-lane-full DIVE-2794 "(unfiled) ${title}" \
          "lane '${assignee}' is at its WIP cap (${_wact}/${_wcap} actionable). Close something before adding to it — the cap is frozen, so closing a row is what makes room:
${_oldest}
  · file it elsewhere            →  --assignee=<other lane>
  · it is serious                →  --priority=high (high/urgent are redirected, never refused)
  · exempt this row deliberately →  --task-budget=none
  · fleet-wide override          →  FIVE_WIP_CAP=0
REFUSED TITLE (recorded in policy_refusals, not lost): ${title}"
      fi
    fi
  fi
  # The exception is recorded ON THE ROW, not just consumed at the prompt. A cap
  # you can step over leaves no trace is a cap nobody can audit afterwards.
  if [[ -n "$already_blocked" ]]; then
    body="${body:+$body

}FILING-CAP EXCEPTION (already blocked shipped work): ${already_blocked}"
  fi
  # DIVE-3366 acceptance 1: "its choice is recorded so it can be audited". Same
  # reason as the cap exception directly above — a router whose choice leaves no
  # trace cannot be audited, and this one is worse than the cap: the INPUT that
  # decided it (each seat's open-row count) is a moving number, so by the time
  # anyone asks why this lane got the row, the counts that answer no longer exist
  # anywhere. Recorded on the row, not only in the warn line at the prompt, which
  # the filer's terminal is the only witness to.
  if [[ -n "$role_pick_note" ]]; then
    body="${body:+$body

}${role_pick_note}"
  fi
  # DIVE-969: verifier-by-default posture. For a NON-TRIVIAL standard task where
  # the creator neither wired the loop themselves (--accept/--verify/--verifier)
  # nor opted out (--no-verify), engage grading by default: derive acceptance
  # criteria from the title and assign a grader distinct from the maker. Trivial
  # chores, recurring templates, low priority, and explicit opt-outs are left
  # untouched so the common cheap case stays frictionless. If no distinct grader
  # exists (e.g. a solo org, or the only coordinator IS the assignee) the default
  # silently no-ops rather than blocking the add. Env kill-switch for the fleet:
  # FIVE_VERIFY_DEFAULT=0.
  # DIVE-1880: the auto-skip used to be SILENT — `task add --priority=low` printed
  # nothing to say the rail had been declined, so the filer could not tell a
  # railed task from an unrailed one without inspecting the row afterwards. We now
  # capture WHY it was skipped and announce it below. Note an explicit
  # --verifier=<agent> still forces the rail ON at any priority (it short-circuits
  # this whole block and is stored verbatim) — the auto-skip is a DEFAULT, not a
  # ceiling. --no-verify is an explicit, already-visible opt-out, so it stays quiet.
  local verify_defaulted=0 verify_unavailable=0 verify_skipped=""
  if [[ "$kind" == "standard" && -z "$no_verify" && "${FIVE_VERIFY_DEFAULT:-1}" != "0" \
        && -z "$accept" && -z "$verify_cmd" && -z "$verifier" ]]; then
   verify_skipped=$(_task_verify_skip_reason "$title" "$body" "$priority")
   # DIVE-2681, the half that actually moves tokens: an internal-machinery row
   # does not book a grading pass by default. Filing one used to cost a row PLUS
   # a full verifier round-trip against it, which is how a self-auditing fleet
   # multiplies its own spend. Announced through the existing DIVE-1880 path —
   # never silent — and an explicit --verifier=<agent> still forces the rail ON,
   # exactly as it does for the low-priority skip. This is a DEFAULT, not a
   # ceiling; `task verifier <id> <agent>` attaches grading afterwards.
   [[ -z "$verify_skipped" && -n "$internal_reason" ]] && verify_skipped="$internal_reason"
  fi
  if [[ "$kind" == "standard" && -z "$no_verify" && "${FIVE_VERIFY_DEFAULT:-1}" != "0" \
        && -z "$accept" && -z "$verify_cmd" && -z "$verifier" && -z "$verify_skipped" ]]; then
    local _grader; _grader=$(_task_default_verifier "$assignee" "$proj_lead")
    if [[ -n "$_grader" ]]; then
      verifier="$_grader"
      accept="Deliverable meets the intent of: ${title}. Maker records in the done result WHAT was built and HOW it was checked; ${_grader} confirms against this before the task closes (refine these criteria as the work firms up)."
      verify_defaulted=1
    else
      # INST-2: the verifier-by-default posture WOULD engage here but no distinct
      # grader exists (solo org, or the only candidate IS the maker). Rather than
      # let the default silently no-op — leaving the "verifier-graded by default"
      # claim quietly false — record it so `task show` + the dashboard can label
      # the task "Unverified: no independent verifier available".
      verify_unavailable=1
    fi
  fi
  # DIVE-2518: `task_actor_claim`, not `task_actor` — this site WRITES the row, so
  # it needs the claim GRADE and not just the name, and a `$( )` would lose it. The
  # stamped `created_by` is the derived actor; a `--from` that did not corroborate
  # is preserved beside it in `claimed_by` rather than replacing it. Recording both
  # is what keeps the row falsifiable later: `created_by` alone cannot distinguish
  # a measured identity from an asserted one.
  # BARE call, not `$( )` — the grade must survive into this shell. See the
  # contract note on task_actor_claim; a command substitution here silently
  # NULLs claimed_by for every divergent claim.
  task_actor_claim "$from"
  local creator="${from:-$ACTOR_BOARD}"
  # RECORD BOTH, with the columns the right way round. `created_by` keeps its
  # meaning — who this row is attributed to, which for a uid-less relay principal
  # (`council`, `telegram`) can only ever be the claim. `derived_actor` carries the
  # uid that actually ran it.
  #
  # ALWAYS POPULATED, never only-on-divergence (olivia, DIVE-2518 review). A
  # conditionally written column makes NULL mean three different things at read
  # time — the claim agreed, the row predates the column, or the row came through a
  # path that does not populate it — which is the exact absent-vs-not-measured
  # collapse lib/actor.sh's own header says this epoch exists to end. It costs one
  # column write, and AGREEMENT IS EVIDENCE TOO: a row where the two match is a
  # positive record that the uid was measured and corroborated the claim, which is
  # not something a NULL can ever say.
  local derived_actor="$ACTOR_BOARD"
  local id
  id=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, derived_actor, parent_id, project_key, kind, schedule, fresh,
                              acceptance_criteria, verify_command, max_iterations, verifier, task_budget, verify_unavailable,
                              verify_optout, on_overlap, overlap_bound)
           VALUES ($(sqlq "$title"), $(sqlq_or_null "$body"), $(sqlq "$priority"),
                   $(sqlq_or_null "$assignee"), $(sqlq "$creator"), $(sqlq_or_null "$derived_actor"), ${parent_sql}, $(sqlq "$project"),
                   $(sqlq "$kind"), ${schedule_sql}, ${fresh_sql},
                   $(sqlq_or_null "$accept"), $(sqlq_or_null "$verify_cmd"), ${max_iters:-NULL}, $(sqlq_or_null "$verifier"), $(sqlq_or_null "$task_budget"), $([[ $verify_unavailable == 1 ]] && echo 1 || echo NULL),
                   $([[ -n "$no_verify" ]] && echo 1 || echo NULL), ${on_overlap_sql}, ${overlap_bound_sql});
           SELECT last_insert_rowid();")
  # Ident is stamped by the AFTER INSERT trigger from the project's counter, so
  # read it back rather than assuming the DIVE- prefix (DIVE-484).
  local ident; ident=$(db "SELECT ident FROM tasks WHERE id=${id};")
  # INST-4: first row of this task's lifecycle. The title is hashed as the input
  # payload rather than stored twice — tasks.title is already the authority on
  # what was asked, and the digest is what lets a reader prove the title was not
  # edited after the fact.
  ledger_emit task.created ident="$ident" task_id="$id" \
    parent="$(db "SELECT COALESCE(p.ident,'') FROM tasks t LEFT JOIN tasks p ON p.id=t.parent_id WHERE t.id=${id};" 2>/dev/null)" \
    actor="$creator" claimed_by="$derived_actor" in="$title" \
    detail="${priority} → ${assignee:-unassigned}${verifier:+ (verifier ${verifier})}"
  if [[ "$kind" == "recurring" ]]; then
    ok "created recurring ${ident} (${recurring}, fresh=$([[ "$fresh_sql" == "1" ]] && echo on || echo off)) — $title" \
       '{id:($i|tonumber), ident:$id, project:$pr, title:$t, priority:$p, assignee:$a, created_by:$c, kind:"recurring", schedule:$s, fresh:($f=="1")}' \
       --arg i "$id" --arg id "$ident" --arg pr "$project" --arg t "$title" --arg p "$priority" --arg a "${assignee:-}" --arg c "$creator" --arg s "$recurring" --arg f "$fresh_sql"
  else
    if [[ -n "$followup_warn_ident" ]]; then
      local _followup_match_note=""
      if [[ -n "$followup_warn_matches" ]]; then
        _followup_match_note=" Open title match(es) for the same token: ${followup_warn_matches}."
      fi
      warn "$ident: title cites existing ${followup_warn_ident} ${followup_warn_kind} #${followup_warn_number} without --parent, so no child link was created.${_followup_match_note} If this is a child, file it with --parent=${followup_warn_ident}."
    fi
    local coord_note=""
    (( auto_coordinated )) && coord_note=" → coordinator: $assignee"
    local verify_note=""
    (( verify_defaulted )) && verify_note=" · verifier-graded by default → $verifier ('task done' hands off to grade; refine with --accept/--verify, or opt out with --no-verify)"
    # INST-2 (DIVE-1673): a quiet, lowercase tag — honest but not a nag for solo
    # users; the full explanation lives in `task show` detail, not this line.
    (( verify_unavailable )) && verify_note=" · unverified"
    # DIVE-1880: mirror the positive notice when the rail was auto-DECLINED, and
    # name the remedy — otherwise the filer reads a bare "created DIVE-N" and
    # reasonably assumes the by-default grading they were told about applied.
    [[ -n "$verify_skipped" ]] \
      && verify_note=" · NOT verifier-graded ($verify_skipped) — 'task done' will close it outright; attach a grader with: 5dive task verifier $ident <agent>"
    ok "created ${ident} — $title${coord_note}${verify_note}" \
       '{id:($i|tonumber), ident:$id, project:$pr, title:$t, priority:$p, assignee:$a, created_by:$c, kind:"standard", autoCoordinated:($ac=="1"), verifyDefaulted:($vd=="1"), verifyUnavailable:($vu=="1"), verifySkipped:($vs!=""), verifySkipReason:$vs, verifier:$v, parentLinkWarning:($wi!=""), citedParent:$wi, citedSeries:(if $wi=="" then "" else ($wk+" #"+$wn) end), openTitleMatches:($wm|split(",")|map(select(length>0)))}' \
       --arg i "$id" --arg id "$ident" --arg pr "$project" --arg t "$title" --arg p "$priority" --arg a "${assignee:-}" --arg c "$creator" --arg ac "$auto_coordinated" --arg vd "$verify_defaulted" --arg vu "$verify_unavailable" --arg vs "$verify_skipped" --arg v "${verifier:-}" \
       --arg wi "$followup_warn_ident" --arg wk "$followup_warn_kind" --arg wn "$followup_warn_number" --arg wm "$followup_warn_matches"
  fi
}

cmd_task_ls() {
  tasks_db_init
  local status="" assignee="" mine=0 all=0 from="" recurring=0 project="" no_body=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status=*)   status="${1#*=}" ;;
      --assignee=*) assignee="${1#*=}" ;;
      --project=*)  project="${1#*=}" ;;
      --mine)       mine=1 ;;
      --all)        all=1 ;;
      --recurring)  recurring=1 ;;
      --from=*)     from="${1#*=}" ;;
      # DIVE-3388: the JSON contract is read by agents, not humans, and `ls`
      # SELECTs every row's full body+result — a single `task ls --json` on a
      # 179-task board dumps hundreds of KB into the caller's context before any
      # filtering is possible. Bodies are opt-in-cost here: `--no-body` strips
      # body+result from every emitted row. The strip is a jq post-pass (not SQL
      # column surgery) so the SELECT and its MAX_ARG_STRLEN stdin-feed stay
      # untouched, and the only behaviour change is what reaches the caller.
      --no-body)    no_body=1 ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ $mine -eq 1 ]] && assignee=$(task_actor "$from")
  # --recurring lists the TEMPLATES (kind='recurring') with their schedule;
  # otherwise we list real work and always exclude templates (they're never
  # worked directly, so they'd be noise in the board).
  local where="1=1" order
  if (( recurring )); then
    where+=" AND kind='recurring'"
    # DIVE-2055: default to the EXACT predicate the heartbeat materializer
    # fires on (schedule IS NOT NULL AND status='todo') so this listing can't
    # tell a different story than the scheduler — a cancelled/blocked/parked
    # template used to still appear here with a blank schedule and a stale
    # last_fired timestamp, reading as a live driver that fired recently.
    # --all lifts the filter for an audit view of every template regardless
    # of whether the scheduler still sees it.
    (( all )) || where+=" AND schedule IS NOT NULL AND status='todo'"
    order="ORDER BY id"
  else
    where+=" AND kind='standard'"
    if [[ -n "$status" ]]; then
      valid_task_status "$status" || fail "$E_VALIDATION" "bad status '$status' (todo|in_progress|blocked|done|cancelled)"
      where+=" AND status=$(sqlq "$status")"
    elif [[ $all -ne 1 ]]; then
      where+=" AND status NOT IN ('done','cancelled')"
    fi
    order="ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, created_at"
  fi
  [[ -n "$assignee" ]] && where+=" AND assignee=$(sqlq "$assignee")"
  # DIVE-484: scope to one project by key (case-insensitive).
  [[ -n "$project" ]] && where+=" AND project_key=$(sqlq "${project,,}")"
  if (( JSON_MODE )); then
    local rows
    # DIVE-3267: `needs_human` is the CLI's own verdict — "this gate is waiting on a
    # HUMAN" — exported as a computed boolean so a consumer partitions on the answer
    # instead of rebuilding the rule. Both predicates come from the single-source
    # helpers above `cmd_task_inbox`; see the contract there before touching either.
    # NOT a second call to `task inbox --json`: two calls are two snapshots with a
    # window between them, and a gate answered in that window lands a row in neither
    # section or in both. One query, one evaluation, one truth.
    local _gate_open _gate_human
    _gate_open=$(_task_gate_open_pred); _gate_human=$(_task_human_gate_pred)
    # DIVE-583: emit project_key natively so the dashboard keys off a real field
    # (join name/prefix/lead from `project ls`) instead of deriving project from
    # the ident prefix client-side (fragile; couples to naming + the id≠ident bug).
    # DIVE-1347: emit gate_live — the canonical "still-answerable human gate"
    # flag, IDENTICAL to the `task inbox` predicate (need_type set, not yet
    # answered, task still open). Consumers/dashboards MUST count/filter on this,
    # never raw `need_type != null` (which retains a STALE type after a gate is
    # consumed or the task is re-blocked on a dependency, over-reporting the inbox).
    # INST-2: emit verify_unavailable — the canonical "no independent verifier
    # available" flag (verifier-by-default no-opped in a solo org). True only while
    # the mark stands AND no verifier has since been assigned; the dashboard renders
    # it as an "Unverified" badge.
    # DIVE-2777: emit handoff_delivered_at and handoff_rejected_at. They were
    # ABSENT from this projection, not nulled — a distinction with no difference to
    # a consumer (`r.get('handoff_delivered_at')` is None either way) and all the
    # difference to the fix: include the fields, do not repair a write. `task show
    # --json` already returned them correctly and matched sqlite the whole time, so
    # the two surfaces disagreed and the list one was the one people reached for
    # first. It cost a real wrong answer: DIVE-2207 was read off this list as never
    # re-delivered when the DB had it delivered at 2026-08-04 17:40:13.
    #
    # TWO fields, not three. `handoff_ack_at` is already here and works; it merely
    # reads absent on rows whose value is NULL, because this projection drops
    # null-valued keys generally. That is also why the trap took three hands: you
    # cannot tell "omitted by the serializer" from "null in the DB" by looking at a
    # row whose value is null, and every row anyone reached for first was null
    # here. Only a row with a NON-NULL clock discriminates — which is what the
    # regression test asserts against (tests/task_reject_trace_unit.sh, arm C).
    # NB: no inline SQL `--` comments in this string —
    # dbfmt flattens newlines, so a `--` would comment out the rest of the query.
    rows=$(dbfmt -json "SELECT id, ident, title, status, priority, assignee, created_by, parent_id, created_at, done_at, body, result, delivery_ref, need_type, ask, need_options, recommend, precedent_ref, precedent_kind, need_answer, need_answered_at, need_answered_by, need_answered_relay, need_answered_tap_uid, tier, gate_mode, kind, schedule, last_fired_at, last_skipped_at, on_overlap, overlap_bound, parked_at, park_reason, wake_at, project_key, maker_agent, verifier,
             CASE WHEN maker_agent IS NOT NULL AND assignee=verifier AND status NOT IN ('done','cancelled')
                  THEN CASE WHEN handoff_ack_at IS NOT NULL THEN 'reviewing' ELSE 'delivered' END
                  ELSE NULL END AS handoff_state,
             handoff_ack_at, handoff_delivered_at, handoff_rejected_at,
             CASE WHEN ${_gate_open} THEN 1 ELSE 0 END AS gate_live,
             CASE WHEN ${_gate_open} AND ( ${_gate_human} ) THEN 1 ELSE 0 END AS needs_human,
             CASE WHEN verify_unavailable = 1 AND verifier IS NULL AND status NOT IN ('done','cancelled') THEN 1 ELSE 0 END AS verify_unavailable,
             CASE WHEN kind='recurring' THEN CASE WHEN COALESCE(on_overlap,'skip')='spawn' THEN (SELECT CASE WHEN COUNT(*) >= COALESCE(tasks.overlap_bound, ${TASKS_OVERLAP_BOUND_DEFAULT:-3}) THEN 'bound '||COUNT(*)||'/'||COALESCE(tasks.overlap_bound, ${TASKS_OVERLAP_BOUND_DEFAULT:-3}) ELSE NULL END FROM tasks i WHERE i.from_template_id=tasks.id AND i.status NOT IN ('done','cancelled')) ELSE (SELECT i.ident FROM tasks i WHERE i.from_template_id=tasks.id AND i.status NOT IN ('done','cancelled') ORDER BY i.id LIMIT 1) END ELSE NULL END AS blocked_by
           FROM tasks WHERE ${where} ${order};")
    [[ -n "$rows" ]] || rows="[]"
    # Feed rows via stdin, not --argjson: a big board (179+ tasks w/ bodies)
    # blows past MAX_ARG_STRLEN (128K per argv string) -> execve E2BIG
    # ("Argument list too long"). stdin has no such cap. (DIVE-222)
    if (( no_body )); then
      printf '%s' "$rows" | jq -c '{ok:true, data:{tasks:(map(del(.body, .result)))}}'
    else
      printf '%s' "$rows" | jq -c '{ok:true, data:{tasks:.}}'
    fi
  elif (( recurring )); then
    # DIVE-2237: last_fired alone cannot distinguish SUPPRESSED from BROKEN.
    # last_skipped names the last tick the materializer found this template due
    # and declined (skip-if-open); blocked_by names the open instance doing the
    # blocking, so the fix is one `task done` away and the reader does not have
    # to go find it. blocked_by is derived live from the same predicate the
    # materializer dedups on, so this listing cannot tell a different story than
    # the scheduler (the DIVE-2055 rule for this table).
    #
    # DIVE-2272: that rule is why blocked_by is now POLICY-AWARE rather than "is
    # there any open instance". On an on_overlap='spawn' template an open instance
    # does NOT block — the next slot fires anyway — so printing its ident under a
    # column named blocked_by would send a reader to close a row that is
    # suppressing nothing, the same wasted trip DIVE-2273's forged last_skipped_at
    # sends them on. A spawn template reads '-' until it is AT its bound, and then
    # reads 'bound N/B', because that is the point at which the scheduler really
    # does start skipping. The expression reproduces the materializer's own branch,
    # including the same default bound (TASKS_OVERLAP_BOUND_DEFAULT), so the two
    # cannot drift.
    dbfmt -box "SELECT ident, status, COALESCE(schedule,'-') AS schedule, COALESCE(assignee,'-') AS assignee, COALESCE(last_fired_at,'never') AS last_fired, COALESCE(last_skipped_at,'-') AS last_skipped, COALESCE(CASE WHEN kind='recurring' THEN CASE WHEN COALESCE(on_overlap,'skip')='spawn' THEN (SELECT CASE WHEN COUNT(*) >= COALESCE(tasks.overlap_bound, ${TASKS_OVERLAP_BOUND_DEFAULT:-3}) THEN 'bound '||COUNT(*)||'/'||COALESCE(tasks.overlap_bound, ${TASKS_OVERLAP_BOUND_DEFAULT:-3}) ELSE NULL END FROM tasks i WHERE i.from_template_id=tasks.id AND i.status NOT IN ('done','cancelled')) ELSE (SELECT i.ident FROM tasks i WHERE i.from_template_id=tasks.id AND i.status NOT IN ('done','cancelled') ORDER BY i.id LIMIT 1) END ELSE NULL END,'-') AS blocked_by, COALESCE(on_overlap,'skip') AS on_overlap, title FROM tasks WHERE ${where} ${order};"
  else
    # DIVE-2316: the binding audit is a list question — "which closed rows have
    # no pointer?"  Show the column whenever closed rows were requested, and
    # render the missing value explicitly instead of turning it into another
    # invisible blank.  The default open queue stays compact.
    if [[ "$status" == "done" || $all -eq 1 ]]; then
      # DIVE-3098: the audit view renders graded-and-waiting the same way as the
      # compact one. Two branches, one predicate — if only the default view knew,
      # `--all` would still paint the row `todo` and the reader who went looking for
      # detail would get the LESS accurate answer.
      dbfmt -box "SELECT ident,
             CASE WHEN ${_TASKS_TFV_SQL}
                  THEN 'graded->merge:'||COALESCE(NULLIF(maker_agent,''), COALESCE(assignee,'?'))
                  ELSE status END AS status,
             priority, COALESCE(assignee,'-') AS assignee, COALESCE(NULLIF(delivery_ref,''),'absent') AS delivery_ref, title FROM tasks WHERE ${where} ${order};"
    else
      # DIVE-3098: a graded-and-waiting row must not read as todo/blocked/in_progress
      # to the eye, and the render must name who owes the MERGE - the maker or ship
      # approver, never the verifier, who has already finished. Folded into the status
      # cell rather than a new column so the compact board stays compact.
      dbfmt -box "SELECT ident,
             CASE WHEN ${_TASKS_TFV_SQL}
                  THEN 'graded->merge:'||COALESCE(NULLIF(maker_agent,''), COALESCE(assignee,'?'))
                  ELSE status END AS status,
             priority, COALESCE(assignee,'-') AS assignee, title FROM tasks WHERE ${where} ${order};"
    fi
    # DIVE-3366 acceptance 3: the skew belongs ON THE BOARD, under the queue,
    # because that is where the routing decision is actually made — a number in a
    # digest nobody reads at filing time is why lodar had to raise this by hand
    # three times in one day. Suppressed under --assignee/--mine: a single-lane
    # view is not a routing view, and a note about two other seats there is noise.
    # Human path only; the --json branch returns above and its consumers must not
    # find a new advisory in their payload.
    [[ -n "$assignee" ]] || _task_role_skew_note
  fi
}

cmd_task_show() {
  tasks_db_init
  # DIVE-3388: --no-body strips the (often multi-KB) body+result from both the
  # JSON and text renderings, for callers that want the row's state/gates without
  # pulling the full text into context. Same opt-in-cost rule as `task ls`.
  local no_body=0
  local -a pos=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-body) no_body=1 ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         pos+=("$1") ;;
    esac
    shift
  done
  [[ ${#pos[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task show <id|DIVE-N> [--no-body]"
  resolve_task_id "${pos[0]}"; local id="$RESOLVED_TASK_ID"
  if (( JSON_MODE )); then
    local task subs deps previous_gates
    # DIVE-3340 iter2 (main2): export the VERDICTS here too. `SELECT *` returns
    # only stored columns, so `gate_live`/`needs_human` — which `task ls --json`
    # has computed since DIVE-1347/DIVE-3267 — read NULL on this surface. A
    # consumer that reaches for `show` (the telegram plugin's task-detail view
    # does) therefore has no verdict available and rebuilds the rule from the
    # raw inputs, which is precisely the DIVE-3224/DIVE-3267 conflation those
    # fields exist to end. Same two single-source predicates, evaluated in the
    # same query as the row, so the two surfaces cannot disagree.
    local _gate_open _gate_human
    _gate_open=$(_task_gate_open_pred); _gate_human=$(_task_human_gate_pred)
    task=$(dbfmt -json "SELECT *,
             CASE WHEN ${_gate_open} THEN 1 ELSE 0 END AS gate_live,
             CASE WHEN ${_gate_open} AND ( ${_gate_human} ) THEN 1 ELSE 0 END AS needs_human
           FROM tasks WHERE id=${id};")
    subs=$(dbfmt -json "SELECT id,ident,title,status FROM tasks WHERE parent_id=${id} ORDER BY id;")
    deps=$(dbfmt -json "SELECT t.id,t.ident,t.title,t.status FROM task_deps d JOIN tasks t ON t.id=d.blocked_by WHERE d.task_id=${id} ORDER BY t.id;")
    previous_gates=$(_gate_history_summary_json "$id")
    [[ -n "$subs" ]] || subs="[]"
    [[ -n "$deps" ]] || deps="[]"
    if (( no_body )); then
      jq -cn --argjson t "$task" --argjson s "$subs" --argjson b "$deps" \
        --argjson g "$previous_gates" \
        '{ok:true, data:{task:($t[0] | del(.body, .result)), subtasks:$s, blocked_by:$b, previous_gates:$g}}'
    else
      jq -cn --argjson t "$task" --argjson s "$subs" --argjson b "$deps" \
        --argjson g "$previous_gates" \
        '{ok:true, data:{task:($t[0]), subtasks:$s, blocked_by:$b, previous_gates:$g}}'
    fi
  else
    # DIVE-2316: delivery_ref is an enforcement input, so omission here made a
    # missing binding indistinguishable from a presenter that never read it.
    # Keep the field present in both states; "absent" is the observable value.
    # DIVE-3251: first_started_at sits next to started_at because the whole point
    # of the split is that a reader can tell "reclaimed after real work" from
    # "never started" FROM THE BOARD ALONE. A fix that records the first start but
    # does not surface it here does not satisfy that.
    if (( no_body )); then
      dbfmt -line "SELECT ident, title, status, priority, assignee, created_by, parent_id, created_at, first_started_at, started_at, done_at, COALESCE(NULLIF(delivery_ref,''),'absent') AS delivery_ref FROM tasks WHERE id=${id};"
    else
      dbfmt -line "SELECT ident, title, status, priority, assignee, created_by, parent_id, created_at, first_started_at, started_at, done_at, COALESCE(NULLIF(delivery_ref,''),'absent') AS delivery_ref, body, result FROM tasks WHERE id=${id};"
    fi
    # DIVE-1064: surface the creator's isolation tier (read-time from the
    # registry, no schema change) so a reader/agent can down-trust a task filed
    # by a lower-privilege peer.
    #
    # DIVE-2213: this used to print the line ONLY when the lookup came back
    # non-empty, over a lookup whose stderr went to /dev/null — so an unreadable
    # registry, a jq failure and a creator who genuinely has no tier all rendered
    # as the line simply not being there, and a reader could not tell "no tier"
    # from "not measured". Third instance of the DIVE-2210 shape (display-only;
    # the decision-site instance is cmd_heartbeat.sh's DIVE-1065 guard).
    #
    # The line is now ALWAYS printed, in three distinguishable states. That
    # changes `task show`'s human output shape for every task; checked first —
    # origin/main across 5dive-cli / api / app / plugins / mcp has no consumer of
    # this line other than the site emitting it, and the machine path is the
    # --json branch above, which never carried it.
    local _cb _ctier=""
    _cb=$(db "SELECT COALESCE(created_by,'') FROM tasks WHERE id=${id};")
    _ctier="$(agent_tier "$_cb")"
    case "$_ctier" in
      unknown:no-caller)    printf 'created_by_tier = none (no creator recorded)
' ;;
      unknown:unregistered) printf 'created_by_tier = none (creator is not a registered agent)
' ;;
      unknown:*)            printf 'created_by_tier = %s (NOT measured)
' "$_ctier" ;;
      *)                    printf 'created_by_tier = %s
' "$_ctier" ;;
    esac
    _gate_history_show_summary "$id"
    # Human gate (only when set) — mirrors the conditional subtasks/blockers
    # blocks below so an ordinary task's `show` stays clean.
    local gate
    gate=$(db "SELECT 'type: '||need_type||
                      -- DIVE-2354: the ORDER, on the type line, because it changes
                      -- what the type MEANS. A gate whose mode is absent says so —
                      -- NULL is 'filed before the column existed', not 'before the
                      -- action', and printing a default here would invent the claim.
                      CASE WHEN gate_mode='confirm-after-send'
                           THEN '  mode: confirm-after-send (the action ALREADY HAPPENED — this asks for RATIFICATION, not prior approval)'
                           WHEN gate_mode IS NOT NULL THEN '  mode: '||gate_mode
                           ELSE '' END||
                      CASE WHEN tier IS NOT NULL THEN '  (tier '||tier||')' ELSE '' END||
                      CASE WHEN need_options IS NOT NULL THEN '  options: '||need_options ELSE '' END||
                      CASE WHEN recommend IS NOT NULL THEN x'0a'||'recommend: '||recommend ELSE '' END||
                      -- DIVE-2848: the audited exception to the keystroke cap, shown
                      -- next to the recommendation it overrode, because the pair is
                      -- the whole claim (I advised X and still needed a person).
                      CASE WHEN gate_rubber_stamp IS NOT NULL THEN x'0a'||'rubber-stamp-ok: '||gate_rubber_stamp ELSE '' END||
                      CASE WHEN precedent_ref IS NOT NULL
                           THEN x'0a'||'precedent: '||COALESCE((SELECT ident FROM tasks p WHERE p.id=tasks.precedent_ref),'#'||precedent_ref) ELSE '' END||
                      -- DIVE-2615: why this gate has this tier. Absent on rows filed
                      -- before this shipped, which is a real distinction and not a
                      -- rendering gap — see the NULL-vs-axis=none note in cmd_task_need.
                      CASE WHEN floor_provenance IS NOT NULL AND floor_provenance <> ''
                           THEN x'0a'||'tier set by: '||floor_provenance ELSE '' END||x'0a'||
                      'ask:  '||COALESCE(ask,'')||
                      CASE WHEN need_answered_at IS NOT NULL
                           -- DIVE-2354: an answer on a confirm-after-send gate is a
                           -- RATIFICATION and must not read as a prior approval. The
                           -- stored value is unchanged (approved/denied); what the
                           -- record gains is the order the tap came in.
                           THEN x'0a'||'answer: '||CASE WHEN need_type='secret' THEN '(provided — loaded out-of-band)' ELSE COALESCE(need_answer,'') END||'  ('||need_answered_at||')'||
                                CASE WHEN gate_mode='confirm-after-send'
                                     THEN x'0a'||'        ↩︎ RATIFIED AFTER THE FACT — the action had already been taken when this was answered'
                                     ELSE '' END
                           ELSE x'0a'||'answer: — pending'||
                                CASE WHEN gate_mode='confirm-after-send'
                                     THEN ' (awaiting RATIFICATION of an action already taken)' ELSE '' END END
               FROM tasks WHERE id=${id} AND need_type IS NOT NULL;")
    [[ -n "$gate" ]] && { echo; echo "human gate:"; printf '%s\n' "$gate" | indent2; }
    # DIVE-476: loop spec (only when any field is set) — the declarative verify
    # loop the (c) runner executes. Mirrors the conditional human-gate block.
    local loopspec
    loopspec=$(db "SELECT
        CASE WHEN acceptance_criteria IS NOT NULL THEN 'acceptance_criteria: '||acceptance_criteria||x'0a' ELSE '' END||
        CASE WHEN verify_command      IS NOT NULL THEN 'verify_command: '||verify_command||x'0a' ELSE '' END||
        CASE WHEN max_iterations      IS NOT NULL THEN 'max_iterations: '||max_iterations||x'0a' ELSE '' END||
        CASE WHEN task_budget         IS NOT NULL THEN 'task_budget: '||task_budget||x'0a' ELSE '' END||
        CASE WHEN verifier            IS NOT NULL THEN 'verifier: '||verifier||x'0a' ELSE '' END||
        CASE WHEN maker_agent         IS NOT NULL THEN 'maker: '||maker_agent||x'0a' ELSE '' END||
        CASE WHEN maker_agent IS NOT NULL AND assignee=verifier AND status NOT IN ('done','cancelled')
             THEN 'handoff: '||CASE WHEN handoff_ack_at IS NOT NULL
                                    THEN 'reviewing (ACK '||handoff_ack_at||')'
                                    ELSE 'delivered (awaiting verifier ACK)' END||x'0a'
             ELSE '' END||
        CASE WHEN iteration           IS NOT NULL THEN 'iteration: '||iteration||x'0a' ELSE '' END||
        CASE WHEN verify_unavailable = 1 AND verifier IS NULL AND status NOT IN ('done','cancelled')
             THEN 'unverified: no independent verifier available (solo org, no distinct grader)' ELSE '' END
      FROM tasks WHERE id=${id}
        AND (acceptance_criteria IS NOT NULL OR verify_command IS NOT NULL
             OR max_iterations IS NOT NULL OR verifier IS NOT NULL OR task_budget IS NOT NULL
             OR maker_agent IS NOT NULL OR iteration IS NOT NULL OR handoff_ack_at IS NOT NULL
             OR (verify_unavailable = 1 AND verifier IS NULL AND status NOT IN ('done','cancelled')));")
    [[ -n "$loopspec" ]] && { echo; echo "loop spec:"; printf '%s\n' "$loopspec" | sed -e 's/[[:space:]]*$//' | indent2; }
    local subs
    subs=$(db "SELECT ident||'  ['||status||']  '||title FROM tasks WHERE parent_id=${id} ORDER BY id;")
    [[ -n "$subs" ]] && { echo; echo "subtasks:"; printf '%s\n' "$subs" | indent2; }
    local deps
    deps=$(db "SELECT t.ident||'  ['||t.status||']  '||t.title FROM task_deps d JOIN tasks t ON t.id=d.blocked_by WHERE d.task_id=${id} ORDER BY t.id;")
    [[ -n "$deps" ]] && { echo; echo "blocked by:"; printf '%s\n' "$deps" | indent2; }
  fi
  # DIVE-2751: the `blocked by` block above is a CONDITIONAL RENDER whose test is
  # the last command in this function, so on a row with no dependency edge the
  # false test became `task show`'s exit status and `set -euo pipefail` killed the
  # script — after the row had already printed in full. That is the majority of the
  # board, and `5dive task show <id>` is the canonical verification command a /goal
  # stop-hook is pointed at, so a correctly-rendered row read as a failed command
  # whose effect the trap then declared UNKNOWN. Terminate the function on its own
  # status: a render that reached the end SUCCEEDED, whatever the last block chose
  # not to print. Covers the --json branch too (jq's status is not a render verdict).
  return 0
}

# DIVE-2133 — gate_history was an append-only WRITE path with no reader. Keep
# the summary logic shared by `task show` and the detailed verb so the compact
# count can never claim stronger archive coverage than the listing beneath it.
#
# gate_history_coverage is a conservative evidence boundary, not a release/
# version guess. Its single value is prefixed fresh: or inferred: so the boundary
# and its proof basis commit atomically. Fresh stores stamp before their first
# task. Existing stores stamp the earliest row they can prove was archived, or
# migration time when the archive is empty. A task older than that boundary may
# have displaced gates from the blind era, so zero means "zero recorded", never
# "none existed". Equality is complete only for a fresh store: SQLite timestamps
# are second-granular, so an upgraded task stamped in the boundary second may
# still predate the migration.
_gate_history_facts() {
  local id="$1" count raw coverage="" basis="unknown" created state="unknown"
  count=$(db "SELECT COUNT(*) FROM gate_history WHERE task_id=${id};")
  raw=$(_task_pref_get gate_history_coverage)
  case "$raw" in
    fresh:*)    basis="fresh"; coverage="${raw#*:}" ;;
    inferred:*) basis="inferred"; coverage="${raw#*:}" ;;
  esac
  created=$(db "SELECT created_at FROM tasks WHERE id=${id};")
  if [[ -n "$coverage" ]]; then
    state="partial"
    if [[ "$created" > "$coverage" || ( "$basis" == "fresh" && "$created" == "$coverage" ) ]]; then
      state="complete"
    fi
  fi
  printf '%s|%s|%s|%s\n' "$count" "$coverage" "$state" "$basis"
}

_gate_history_summary_json() {
  local id="$1" count coverage state basis complete="null"
  IFS='|' read -r count coverage state basis < <(_gate_history_facts "$id")
  case "$state" in
    complete) complete="true" ;;
    partial)  complete="false" ;;
  esac
  jq -cn --argjson n "${count:-0}" --arg started "$coverage" --arg state "$state" --arg basis "$basis" \
    --argjson complete "$complete" \
    '{recorded:$n, coverage_state:$state, coverage_basis:$basis, coverage_complete_for_task:$complete,
      coverage_started_at:(if $started=="" then null else $started end),
      history_before_coverage:(if $state=="complete" then "none" else "unknown" end)}'
}

_gate_history_show_summary() {
  local id="$1" count coverage state basis
  IFS='|' read -r count coverage state basis < <(_gate_history_facts "$id")
  case "$state" in
    complete) printf 'previous gates = %s\n' "$count" ;;
    partial)  printf 'previous gates = %s recorded (earlier history unknown; coverage begins %s)\n' "$count" "$coverage" ;;
    *)        printf 'previous gates = %s recorded (archive coverage NOT measured)\n' "$count" ;;
  esac
}

cmd_task_gate_history() {
  tasks_db_init
  [[ $# -eq 1 ]] || fail "$E_USAGE" "usage: 5dive task gate-history <id|DIVE-N>"
  resolve_task_id "$1"
  local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local summary rows count coverage state basis
  summary=$(_gate_history_summary_json "$id")
  if (( JSON_MODE )); then
    # Deliberately omit need_answer_sig and human_nonce_hash: they prove the
    # archive internally but are not reader payload. Secret answers are always
    # redacted on both output paths, matching the live gate in `task show`.
    rows=$(dbfmt -json "SELECT id, ident, need_type, ask, need_options, recommend, tier,
          need_asked_at, gate_mode,
          CASE WHEN need_type='secret' AND need_answer IS NOT NULL
               THEN '(provided - redacted)' ELSE need_answer END AS need_answer,
          need_answered_at, need_answered_by, need_answered_uid,
          CASE WHEN need_answer_sig IS NOT NULL THEN 1 ELSE 0 END AS answer_attested,
          retired_by, retired_at
        FROM gate_history WHERE task_id=${id} ORDER BY id;")
    [[ -n "$rows" ]] || rows="[]"
    jq -cn --arg id "$ident" --argjson s "$summary" --argjson rows "$rows" \
      '{ok:true, data:{ident:$id, summary:$s, gates:$rows}}'
    return
  fi

  IFS='|' read -r count coverage state basis < <(_gate_history_facts "$id")
  case "$state" in
    complete) printf '%s previous gates: %s\n' "$ident" "$count" ;;
    partial)  printf '%s previous gates: %s recorded — history before %s is unknown\n' "$ident" "$count" "$coverage" ;;
    *)        printf '%s previous gates: %s recorded — archive coverage is NOT measured\n' "$ident" "$count" ;;
  esac
  (( count > 0 )) || return 0
  dbfmt -box "SELECT id AS seq, need_type AS type, COALESCE(gate_mode,'-') AS mode, COALESCE(tier,'-') AS tier,
      COALESCE(need_asked_at,'-') AS asked_at, COALESCE(ask,'-') AS ask,
      COALESCE(need_options,'-') AS options, COALESCE(recommend,'-') AS recommend,
      CASE WHEN need_type='secret' AND need_answer IS NOT NULL
           THEN '(provided - redacted)' ELSE COALESCE(need_answer,'-') END AS answer,
      COALESCE(need_answered_at,'-') AS answered_at,
      COALESCE(need_answered_by,'-') AS answered_by,
      retired_by, retired_at
    FROM gate_history WHERE task_id=${id} ORDER BY id;"
}

cmd_task_assign() {
  tasks_db_init
  [[ $# -ge 2 ]] || fail "$E_USAGE" "usage: 5dive task assign <id|DIVE-N> <agent>"
  resolve_task_id "$1"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local who="$2"
  # DIVE-3344: the raw reassignment verb, and the one that can move a live row
  # onto a lane that does not exist. Refused BEFORE the write — an orphaned row is
  # not recoverable by the machine, because nothing ever looks at it again.
  _task_require_lane "$who" "<agent>"
  # DIVE-3097: refuse landing the ASSIGNEE onto this row's own VERIFIER — the
  # identical end state `task verifier` already refuses from the other
  # direction (DIVE-474: "'X' is <ident>'s own assignee — a maker can't grade
  # itself"), reachable here because that guard only checks at ATTACH time and
  # the assignee can move afterward. `task assign` is a raw reassignment with no
  # such check, and the automatic maker→verifier handoff never calls this verb
  # (it writes assignee=verifier itself, via _task_route_to_verifier, as PART of
  # delivering) — so the only way `who` legitimately equals the current verifier
  # here is a row ALREADY in that delivered shape (assignee is already the
  # verifier), which this leaves alone as a no-op rather than refuse. What it
  # refuses is manufacturing the shape FRESH: a not-yet-delivered row
  # (assignee != verifier today) reassigned straight onto its own verifier,
  # which would make that agent both the worker and the grader with no handoff
  # ever recorded (DIVE-2899: assignee=verifier, delivered_at NULL).
  local _asg_cur_vfier _asg_cur_assignee
  _asg_cur_vfier=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${id};")
  _asg_cur_assignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")
  if [[ -n "$_asg_cur_vfier" && "$who" == "$_asg_cur_vfier" && "$_asg_cur_assignee" != "$_asg_cur_vfier" ]]; then
    fail "$E_VALIDATION" "'$who' is $ident's own verifier — a maker can't grade itself (pick a different assignee, or re-point the verifier first with '5dive task verifier $ident <agent>')"
  fi
  # Handing a task to a NEW owner resets its in_progress clock: SQLite evaluates
  # SET column refs against the pre-update row, so `assignee IS NOT <who>` is the
  # OLD assignee. Without this, an inherited in_progress task keeps the prior
  # owner's started_at, and the heartbeat stale-reaper (_hb_reap_stale) can
  # cancel it on the new owner's very first tick before they touch it.
  # DIVE-2853, and the SAME hazard the paragraph above fixes for the stale-reaper,
  # one layer over: the recurring-stall ladder escalates on how long ago the row was
  # FLAGGED, so a row flagged two days ago that someone deliberately reassigns by
  # hand is eligible for rung 2 on the new owner's very first tick — the machine
  # would yank a routing decision seconds after a person or agent made it, having
  # measured nothing about the new hands. Clearing both stamps when the assignee
  # actually CHANGES restarts the ladder at detection: the new owner gets a full
  # rung-1 window, and is re-flagged on their own clock if they also sit on it.
  # Only an explicit `task assign` resets it — the ladder writes assignee directly
  # and keeps its own latch, so the machine's own move still cannot repeat.
  db "UPDATE tasks SET
        handoff_ack_at=CASE WHEN assignee IS NOT $(sqlq "$who") THEN NULL ELSE handoff_ack_at END,
        recurring_stall_pinged_at=CASE WHEN assignee IS NOT $(sqlq "$who")
                                       THEN NULL ELSE recurring_stall_pinged_at END,
        recurring_stall_escalated_at=CASE WHEN assignee IS NOT $(sqlq "$who")
                                          THEN NULL ELSE recurring_stall_escalated_at END,
        assignee=$(sqlq "$who"),
        started_at=CASE WHEN status='in_progress' AND assignee IS NOT $(sqlq "$who")
                        THEN datetime('now') ELSE started_at END
      WHERE id=${id};"
  ok "$ident assigned to $who" '{id:($i|tonumber), ident:$id, assignee:$a}' --arg i "$id" --arg id "$ident" --arg a "$who"
}

# DIVE-1880: attach the maker→verifier rail to an ALREADY-FILED task. `--verifier`
# only ever existed on `task add`, so a task filed WITHOUT the rail — explicitly
# (--no-verify) or silently (the DIVE-969 auto-skip for low priority / chore
# titles) — could never be graded afterwards: `task done` closed it outright and
# the only remedy was cancel-and-re-file, which loses the thread. This makes the
# auto-skip a reversible DEFAULT rather than a one-way ceiling.
#
# Deliberately ONE-WAY: there is no --none/--clear to DETACH a grader. Adding a
# control after the fact is safe; quietly removing one is exactly the failure this
# task is about. Opting out stays an add-time decision (--no-verify).
cmd_task_verifier() {
  tasks_db_init
  local task="" who="" accept="" max_iters=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --accept=*)    accept="${1#*=}" ;;
      --max-iters=*) max_iters="${1#*=}" ;;
      --from=*)      : ;;   # accepted for symmetry with the other verbs; unused
      -*)            fail "$E_USAGE" "unknown flag: $1" ;;
      *)             if [[ -z "$task" ]]; then task="$1"
                     elif [[ -z "$who" ]]; then who="$1"
                     else fail "$E_USAGE" "unexpected arg: $1"; fi ;;
    esac
    shift
  done
  [[ -n "$task" && -n "$who" ]] \
    || fail "$E_USAGE" "usage: 5dive task verifier <id|DIVE-N> <agent> [--accept=<criteria>] [--max-iters=<n>]"
  [[ -z "$max_iters" || "$max_iters" =~ ^[1-9][0-9]*$ ]] \
    || fail "$E_VALIDATION" "--max-iters must be a positive integer"
  # DIVE-3344: a verifier is a DISPATCH TARGET too — delivering writes
  # assignee=<verifier> — so a typo'd grader orphans the row at handoff, one step
  # further from anyone noticing than a typo'd assignee does.
  _task_require_lane "$who" "<agent>"
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local st kind title asignee cur_accept cur_vfier maker delivered
  st=$(db "SELECT status FROM tasks WHERE id=${id};")
  kind=$(db "SELECT COALESCE(kind,'standard') FROM tasks WHERE id=${id};")
  title=$(db "SELECT title FROM tasks WHERE id=${id};")
  asignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")
  cur_accept=$(db "SELECT COALESCE(acceptance_criteria,'') FROM tasks WHERE id=${id};")
  cur_vfier=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${id};")
  maker=$(db "SELECT COALESCE(maker_agent,'') FROM tasks WHERE id=${id};")
  delivered=$(db "SELECT COALESCE(handoff_delivered_at,'') FROM tasks WHERE id=${id};")
  # A CLOSED task can't be retro-graded — `done` already happened, so a verifier
  # here would be a grade that never ran. `task reject` is the real remedy: it
  # bounces a closed task back to its maker.
  [[ "$st" != "done" && "$st" != "cancelled" ]] \
    || fail "$E_VALIDATION" "$ident is already $st — a verifier can't grade a closed task; bounce it back: 5dive task reject $ident"
  [[ "$kind" == "standard" ]] \
    || fail "$E_VALIDATION" "$ident is a $kind template, not a worked task — set the rail on its instances (task add … --verifier=)"
  # The DELIVERED / awaiting-verifier middle state (DIVE-477 + DIVE-1416): a
  # maker's `task done` re-queues the row as status='todo' with assignee=<the
  # verifier>, maker_agent=<the maker> and handoff_delivered_at stamped. So mid
  # review the ASSIGNEE is the outgoing GRADER, not the maker — re-pointing the
  # grader here must move the queue too, or the row would claim a grader who
  # doesn't hold the task while the old one still has it on their board.
  local mid_handoff=0
  [[ -n "$cur_vfier" && -n "$delivered" && "$asignee" == "$cur_vfier" ]] && mid_handoff=1
  # writer != grader (DIVE-474): a maker grading itself is not a review. Compare
  # against whoever the MAKER actually is in this state.
  local _maker="$asignee"
  (( mid_handoff )) && _maker="${maker:-$asignee}"
  [[ "$who" != "$_maker" ]] \
    || fail "$E_VALIDATION" "'$who' is $ident's own $( (( mid_handoff )) && echo maker || echo assignee) — a maker can't grade itself; reassign first"
  local new_accept="$cur_accept"
  [[ -n "$accept" ]] && new_accept="$accept"
  [[ -z "$new_accept" ]] \
    && new_accept="Deliverable meets the intent of: ${title}. Maker records in the done result WHAT was built and HOW it was checked; ${who} confirms against this before the task closes (refine these criteria as the work firms up)."
  # Re-pointing the grader MID-REVIEW hands the open review to the new one: move
  # the queue with it and re-stamp the delivery clock (the new grader has not
  # ACKed and the stall sweep should time THEIR review, not the old one's). The
  # maker_agent and iteration count are untouched — the maker and the loop's
  # history do not change just because the grader did. Pointing at the grader who
  # already holds it is an idempotent no-op on the handoff (criteria still
  # refine), NOT an error.
  local move_sql="" new_owner="$asignee" repoint=0
  if (( mid_handoff )) && [[ "$who" != "$cur_vfier" ]]; then
    repoint=1; new_owner="$who"
    move_sql=", assignee=$(sqlq "$who"), started_at=NULL, handoff_ack_at=NULL,
               handoff_delivered_at=datetime('now'), handoff_stale_pinged_at=NULL"
  fi
  db "UPDATE tasks SET verifier=$(sqlq "$who"),
        acceptance_criteria=$(sqlq "$new_accept"),
        max_iterations=$([[ -n "$max_iters" ]] && echo "$max_iters" || echo "max_iterations"),
        verify_unavailable=NULL,
        verify_optout=NULL${move_sql}
      WHERE id=${id};"
  # DIVE-2812 — RECORD THE EDIT TO THE BAR THE ROW IS GRADED AGAINST.
  #
  # `--accept=` on this verb is the ONLY writer of `acceptance_criteria` on an
  # existing row, and it REPLACED the prior text with no trace: measured zero
  # `"cmd":"task verifier"` rows fleet-wide, against 1672 for its audited sibling
  # `task set-body` (DIVE-1920, which audits actor/mode/prior_len for exactly this
  # reason). So a maker could rewrite the criterion they are graded against and
  # nobody downstream could see that it moved, or what it used to say.
  #
  # This is why the field READ as immutable for months (DIVE-2812's original
  # premise, retracted): a mutable value whose mutation leaves no trace is
  # indistinguishable from an immutable one to every observer except the person
  # who typed the command. The control is a RECORD of the edit, not a lock on the
  # field — a legitimate re-scope must stay possible, it just must not be silent.
  #
  # Fires only when the text actually MOVES. Re-pointing a grader with no
  # --accept, or passing back the identical criterion, is not an edit to the bar,
  # and a row for it would be the noise that hides the real ones. `prior` carries
  # the FULL previous text (truncated with a marker past 2000 chars, with a
  # sha256 of the untruncated original alongside) so the criterion a row was
  # originally filed under stays recoverable from the log, which is the auditable
  # half this ticket was filed to get.
  if [[ "$new_accept" != "$cur_accept" ]]; then
    local _acc_prior="$cur_accept" _acc_sha=""
    _acc_sha=$(printf '%s' "$cur_accept" | sha256sum 2>/dev/null | cut -c1-16) || _acc_sha=""
    (( ${#_acc_prior} > 2000 )) && _acc_prior="${_acc_prior:0:2000}…[truncated, ${#cur_accept} chars total]"
    _task_store_audit_log "task verifier set-accept" "ok" 0 -- \
      "task=$ident" "actor=$(task_actor)" "verifier=$who" \
      "prior_len=${#cur_accept}" "new_len=${#new_accept}" \
      "prior_sha256=${_acc_sha:-unavailable}" "prior=${_acc_prior:-<none>}" || true
  fi
  local msg="$ident is now verifier-graded → $who ('task done' hands off to grade instead of closing)"
  (( repoint )) && msg="$ident review re-pointed → $who (was with '$cur_vfier'; delivery re-stamped, maker '${maker:-?}' and iteration unchanged)"
  (( mid_handoff )) && (( ! repoint )) && msg="$ident is already with verifier $who for review — criteria updated, handoff untouched"
  # DIVE-2812: say ON THE COMMAND that the bar moved, and echo what it used to
  # say. The audit row is for the reader of the log later; this is for the one
  # person who can still notice a wrong overwrite while it is undoable.
  if [[ "$new_accept" != "$cur_accept" ]]; then
    msg+=" — acceptance criteria CHANGED (${#cur_accept} chars -> ${#new_accept}; prior text recorded in the audit log)"
  fi
  ok "$msg" \
     '{id:($i|tonumber), ident:$id, verifier:$v, assignee:$a, acceptanceCriteria:$ac, priorAcceptanceCriteria:$pac, acceptanceChanged:($ch=="1"), midReview:($m=="1"), repointed:($r=="1")}' \
     --arg i "$id" --arg id "$ident" --arg v "$who" --arg a "$new_owner" --arg ac "$new_accept" \
     --arg pac "$cur_accept" --arg ch "$([[ "$new_accept" != "$cur_accept" ]] && echo 1 || echo 0)" \
     --arg m "$mid_handoff" --arg r "$repoint"
}

