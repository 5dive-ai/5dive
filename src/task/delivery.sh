# -------- 5dive task — delivery --------
#
# Split out of src/cmd_task.sh (DIVE-3278): maker->verifier delivery: deliver, reject, the routing hop, and the merge audit.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
# src/cmd_task.sh when the split tree is used (tests source src/cmd_task.sh).
# Function definitions only — never execute this file directly.

# DIVE-3496 (iteration 2) — THE DELIVERY-TIME TRIPWIRE. main2's original ask.
#
# WHAT IT BUYS. The merge gate reads the bound PR with the CLOSING seat's rail
# selection, one verb later, in someone else's session, after the maker has moved
# on. When that read comes back blind the gate cannot tell "cannot see" from "not
# merged" — that ambiguity is correct and deliberate, it is what makes the gate
# fail closed — but it means the VERIFIER pays the whole discovery cost, cold.
# Measured: on DIVE-2192 main2 spent two failed closes, an
# `/installation/repositories` enumeration, a `gh auth status` check and a wiki
# compile to reach "I am permanently unable to close this row", then still needed
# a round-trip to learn the designed exit existed
# (community/wiki/a-grader-that-cannot-read-the-repo-cannot-close-the-row.md).
# `task deliver --pr=` is the moment where that costs one read-only query instead.
#
# WHAT #673 CHANGED ABOUT ITS VALUE: less, but not zero. Now that `_gate_gh`
# escalates to the credential-free rails, the population that trips this shrinks
# to refs NO rail can see — a genuinely private third-party repo, a deleted PR, a
# typo'd URL. Those still exist and still land on the verifier.
#
# IT ASSERTS READ REACH, NOT OWNERSHIP, and that is the easy thing to get wrong.
# `_gate_our_owners`/`_gate_repo_slugs` is keyed on WHO OWNS the repo; `lodar/*`
# is in that list and was unreadable from every verifier seat for months. The two
# sets are unrelated and only the first predicts nothing about whether the close
# will succeed. So the probe runs the gate's OWN resolution — `_gate_gh_token`,
# then `_gate_gh` — against the ref that was just bound, and believes only that.
#
# WARN-ONLY, DELIBERATELY. A delivery must not be refused because GitHub was
# briefly unreachable. That is the same fail-open/fail-closed question the gate
# answers one verb later, and the gate is the right place to answer it: refusing
# here would turn a transient network fault into a blocked handoff, on the one
# verb whose entire job is to get finished work off the maker's desk. Every exit
# from this function is 0.
_task_deliver_reach_probe() {
  local ident="$1" pr="$2"
  # Escape hatch for harnesses and offline runs. Not a policy knob: the gate still
  # does its own read at close, so silencing this cannot let anything through.
  [[ "${FIVE_DELIVER_NO_REACH_PROBE:-0}" == "1" ]] && return 0
  # The gate lives in gate_evidence.sh; in a tree where it was not sourced there
  # is nothing to predict with, and guessing would be worse than staying quiet.
  declare -F _gate_gh       >/dev/null 2>&1 || return 0
  declare -F _gate_gh_token >/dev/null 2>&1 || return 0
  local _tok=""
  command -v gh >/dev/null 2>&1 && _tok=$(_gate_gh_token 2>/dev/null || printf '')
  # THE SAME TRAP THIS ITERATION IS FIXING ONE LEVEL DOWN, so it is spelled out
  # rather than avoided by luck: `_state=$(_gate_gh ...)` would run the gate in a
  # SUBSHELL and the `_GATE_GH_LAST_ERR` it sets there would die with it, leaving
  # the warning below with no reason attached. Capture through a file instead —
  # the same technique the gate harnesses use, for the same reason.
  local _state="" _probef
  _probef="${TMPDIR:-/tmp}/.5dive-deliver-reach.$$"
  _gate_gh "$_tok" 15 pr view "$pr" --json state -q '.state' >"$_probef" 2>/dev/null || true
  _state="$(cat "$_probef" 2>/dev/null || printf '')"
  rm -f "$_probef" 2>/dev/null || true
  # A state — ANY state, including OPEN — means the credential can SEE the ref.
  # This probe is not asking whether the PR merged; that is the gate's question at
  # close and it would be wrong to answer it here, since a delivery is normally
  # bound BEFORE the merge.
  [[ -n "$_state" ]] && return 0
  warn "$ident: the merge gate's own credential cannot READ the delivery ref you just bound (${pr}). The delivery stands — this is a warning, not a refusal — but at 'task done' this reads as an unresolved merge state, which is indistinguishable from 'not merged', and your verifier meets it cold.${_GATE_GH_LAST_ERR:+ Rail says: ${_GATE_GH_LAST_ERR}.} If it is still unreadable then, the designed exit is a proof that needs no GitHub: 5dive task verify ${ident} --cmd='git -C <repo> merge-base --is-ancestor <merge-sha> origin/main' (DIVE-3496)."
  return 0
}

cmd_task_deliver() {
  tasks_db_init
  local task="" pr="" result="" want_result=0 result_src=""
  local append_result=0 force_result=0   # DIVE-2476: the two sanctioned answers to the
                                         # already-closed-row refusal, spelled exactly
                                         # as `task done|cancel` spells them.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr=*)          pr="${1#*=}" ;;
      # DIVE-3018: --result-file mirrors `task done`'s (DIVE-2627). The argv form
      # only fails once the text is long enough to hit a shell-quoting mistake —
      # i.e. it fails invisibly in exactly the cases nobody tests with, and what
      # lands is a permanently wrong record rather than an error.
      --result=*)      _prose_flag_dupe --result "$result_src"
                       result="${1#*=}"; want_result=1; result_src="--result" ;;
      --result-file=*) _prose_flag_dupe --result-file "$result_src"
                       _read_prose_file --result-file "${1#*=}"
                       result="$_PROSE_FILE_VALUE"; want_result=1; result_src="--result-file" ;;
      --append-result) append_result=1 ;;
      --force-result)  force_result=1 ;;
      -*)              fail "$E_USAGE" "unknown flag: $1" ;;
      *)               [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task deliver <id|DIVE-N> --pr=<url> [--result=<text>|--result-file=<path>] [--append-result|--force-result]"
  [[ -n "$pr" ]]   || fail "$E_USAGE" "task deliver requires --pr=<url> (the PR that delivers this task; done stays blocked until it is MERGED — DIVE-1830)"
  # Basic sanity: a delivery ref must look like a PR URL, not a bare word.
  if [[ "$pr" != http*://* && "$pr" != *github.com* ]]; then
    fail "$E_VALIDATION" "--pr must be a URL (e.g. https://github.com/<org>/<repo>/pull/<n>) — got '$pr'"
  fi
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # DIVE-2317 follow-through: the ticket asked whether deliver has the same
  # hole as start. It does on the distinct-verifier arm: delivery routes the row
  # to status=todo while preserving its live blocked_by edge. Refuse before the
  # delivery_ref/timestamp write so a failed delivery is wholly non-mutating.
  local _deliver_st; _deliver_st=$(db "SELECT status FROM tasks WHERE id=${id};")
  if [[ "$_deliver_st" == "blocked" ]]; then
    local _deliver_ob _deliver_obi _deliver_obs
    _deliver_ob=$(_task_live_blocker "$id")
    if [[ -n "$_deliver_ob" ]]; then
      _deliver_obi="${_deliver_ob%%|*}"; _deliver_obs="${_deliver_ob#*|}"
      policy_refuse "$E_CONFLICT" deliver-on-open-blocker DIVE-2317 "$ident" "$ident is BLOCKED by open task ${_deliver_obi} (status='${_deliver_obs}') — 'task deliver' would stamp a delivery and may route this row to status=todo while its live blocked_by edge remains, so the status and dependency graph would contradict each other. Deliver after every blocker is done or cancelled (DIVE-2317)."
    fi
  fi
  # DIVE-2476: consult the shared already-closed-row guard BEFORE anything is
  # written. The ordering IS the fix and not a detail — the delivery stamp on the
  # next line lands on a closed row too, so a refusal that fired after it would
  # leave delivery_ref/delivered_at rewritten on the very row it just declined to
  # touch. It sits above the routed/not-routed fork, so both deliver rails reach it.
  if (( want_result )); then
    _task_guard_result_over_closed "$id" "$ident" deliver "$result" \
      "$append_result" "$force_result" deliver-over-closed-result
    result="$_TASK_GUARDED_RESULT"
  fi
  # Record the delivery ref + timestamp before the handoff, so the merge-gate can
  # see it regardless of where the task lands next.
  # DIVE-2682 (dev's reject, iteration 1): stamp the binding's iteration HERE, beside
  # the delivery_ref write, so BOTH deliver arms record it. The routing arm below
  # overwrites this with iteration+1 inside the same UPDATE that bumps the counter.
  # The non-routing arm (verifier == assignee) previously stamped NOTHING — and that
  # is exactly the arm a maker lands in when it follows the refusal's own printed
  # remedy, because the gate fires on a VERIFIER's close, when assignee IS the
  # verifier. So `task deliver --pr=<new>` re-pointed the binding for real while the
  # stamp stayed behind, and the next close refused again naming the CORRECT new PR
  # as recorded at the old iteration: a false refuse on a correctly-bound row, which
  # is the hazard class this row exists to prevent.
  # CURRENT iteration, never a bump: re-pointing is the legitimate act the gate
  # demands, so recording it cannot weaken the gate — the stamp still only ever
  # equals an iteration at which a PR was actually named.
  db "UPDATE tasks SET delivery_ref=$(sqlq "$pr"), delivered_at=datetime('now'), delivery_ref_iteration=COALESCE(iteration,0) WHERE id=${id};"
  # DIVE-3496 (iteration 2): the ref is now bound — assert the gate's credential
  # can SEE it, here, rather than leaving the verifier to discover it at close.
  # Runs AFTER the write on purpose: the delivery is not conditional on it.
  _task_deliver_reach_probe "$ident" "$pr"
  local _vfier _asignee
  _vfier=$(db "SELECT COALESCE(verifier,'')  FROM tasks WHERE id=${id};")
  _asignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")
  if [[ -n "$_vfier" && "$_vfier" != "$_asignee" ]]; then
    # Hand off to the verifier exactly like a maker's `task done` (DIVE-477).
    # DIVE-2682: the trailing 1 stamps delivery_ref_iteration alongside the bump —
    # this verb, and only this verb, just wrote delivery_ref above.
    _task_route_to_verifier "$id" "$_vfier" "$_asignee" "$result" "$want_result" 1
    return
  fi
  # No distinct verifier: record the delivery but do NOT close — a verifier must
  # confirm the merge and close it. Leave the task in_progress.
  (( want_result )) && db "UPDATE tasks SET result=$(sqlq_or_null "$result") WHERE id=${id};"
  # DIVE-2204: the two rows that land here are NOT the same claim. verifier=='' has
  # no verifier at all; verifier==assignee HAS one, just not distinct from the
  # assignee. Saying "no distinct verifier" for the latter reads as "unverified" to
  # an agent deciding whether it's safe to self-close — say what's actually true.
  if [[ -n "$_vfier" ]]; then
    ok "$ident delivered ($pr) — recorded; verifier is the current assignee, so nothing to hand off (a verifier still must close it via 'task done' AFTER the PR is merged — DIVE-1830)" \
       '{id:($i|tonumber), ident:$id, deliveryRef:$p, delivered:true, routedTo:null, status:"in_progress"}' \
       --arg i "$id" --arg id "$ident" --arg p "$pr"
  else
    ok "$ident delivered ($pr) — recorded; no verifier is set, so have a verifier close it via 'task done' AFTER the PR is merged (done stays blocked until then — DIVE-1830)" \
       '{id:($i|tonumber), ident:$id, deliveryRef:$p, delivered:true, routedTo:null, status:"in_progress"}' \
       --arg i "$id" --arg id "$ident" --arg p "$pr"
  fi
}

# `5dive task merge-audit [--limit=N] [--json]` — DIVE-1935 retrospective sweep.
# The gates above only police closes from now on; this answers the question the
# ticket actually asked: is DIVE-1922 the ONLY task that closed while the PR its
# own record names was never merged? Read-only — it reports, it never reopens.
# Scans DONE tasks newest-first, pulls every PR reference out of delivery_ref +
# result + body, resolves each, and prints the ones that are NOT merged. An
# unresolvable ref is reported as `unverified`, never counted as clean, so the
# sweep can't answer "all good" out of a broken token (the DIVE-1935 defect).
# DIVE-1975: every finding also carries `delivered` or `cited` — the DIVE-1965
# split, as a LABEL. See the long note at the classification site for why this
# consumer labels where the gate skips.
# `5dive task merge-gate-selftest [--pr=<url>] [--json]` — DIVE-1935 (iteration 2).
#
# THE GATE ASSERTS ITS OWN INSTRUMENT, on the seat where the assertion matters.
#
# WHY THIS VERB EXISTS AND A FOURTH FALLBACK DOES NOT. Iteration 1 shipped an arm
# (`sudo -n -u claude gh auth token`) premised on "agents hold passwordless sudo on
# this host". That premise is a per-SEAT grant written as a host property, it is false
# for the cli-scoped seats, and — this is the part that matters — it was UNFALSIFIABLE
# FROM THE CODE. No amount of re-reading the resolver tells you whether it resolves
# where you are, because the failure is silent by construction (`sudo -n` cannot
# prompt, `|| true` swallows the refusal, and an empty token is a legitimate state).
# Any NEXT fallback inherits exactly that blind spot. So the fix is an instrument
# check, not another arm: run the real resolution, print WHICH arm stopped it, and
# then GRADE the result against a PR whose answer is already known.
#
# THE POSITIVE CONTROL IS THE POINT. "A token resolved" is not the property the gate
# needs — the property is "this seat can get a true answer out of GitHub about whether
# a PR merged". So the check spends one read-only query on a PR that IS merged and
# requires the word MERGED to come back. A seat that resolves a credential which
# cannot see the repo fails here, and should: from the gate's vantage that seat is as
# blind as one holding nothing, and the two were indistinguishable before this.
# Exit status is the verdict, so a census over the fleet is
# `for a in $(...); do sudo -u "$a" 5dive task merge-gate-selftest --json; done`
# rather than a one-off measurement by whoever happened to hold root.
_GATE_SELFTEST_PR_DEFAULT="https://github.com/5dive-ai/5dive/pull/163"

cmd_task_merge_gate_selftest() {
  local pr="$_GATE_SELFTEST_PR_DEFAULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr=*)    pr="${1#*=}"
                 [[ "$pr" =~ ^https?://[^[:space:]]+/pull/[0-9]+$ ]] \
                   || fail "$E_VALIDATION" "--pr must be a full pull-request URL (…/pull/<n>)" ;;
      --json)    JSON_MODE=1 ;;
      -h|--help) printf 'usage: 5dive task merge-gate-selftest [--pr=<merged pull url>] [--json]\n'; return 0 ;;
      *)         fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done

  local seat tok trace bot anon state rc=0 verdict detail
  seat="$(_gate_seat)"
  if command -v gh >/dev/null 2>&1; then
    tok=$(_gate_gh_token)
  else
    tok=""; _gate_tok_note "[0 gh binary] ABSENT — no arm can run"
  fi
  trace=$(awk '{printf "%s%s", (NR>1?"; ":""), $0}' "$_GATE_TOK_TRACEF" 2>/dev/null || printf '')
  _gate_gh_bot_ok && bot="available" || bot="not permitted on this seat"
  _gate_anon_ok   && anon="usable"   || anon="unusable (no curl/jq, or FIVE_GATE_NO_ANON=1)"

  # The graded probe. `_gate_gh` picks whichever rail this seat actually has, which is
  # deliberately the SAME selection the gate makes — a self-test that hand-picks a rail
  # tests the rail, not the gate.
  if _gate_gh_reachable "$tok"; then
    state=$(_gate_gh "$tok" 20 pr view "$pr" --json state -q '.state' 2>/dev/null || printf '')
  else
    state=""
  fi

  case "$state" in
    MERGED) verdict="ok"
            detail="this seat CAN query GitHub: the control PR $pr reads MERGED" ;;
    "")     rc=1; verdict="blind"
            detail="this seat CANNOT query GitHub — the merge-gate is INERT here and will close on a named, audited UNVERIFIED result instead of checking${_GATE_GH_LAST_ERR:+ ($_GATE_GH_LAST_ERR)}" ;;
    *)      rc=1; verdict="wrong"
            detail="the control PR $pr came back '$state', not MERGED — the rail answers but its answer is not trustworthy for this repo" ;;
  esac

  if [[ "$verdict" == "ok" ]]; then
    ok "merge-gate selftest: $detail — $seat; token arms: ${trace:-none run}; machine-account rail: $bot; anonymous rail: $anon" \
       '{verdict:$v, seat:$s, controlPr:$p, state:$st, tokenResolved:($tk=="1"), tokenTrace:$tr, botRail:$b, anonRail:$a}' \
       --arg v "$verdict" --arg s "$seat" --arg p "$pr" --arg st "$state" \
       --arg tk "$([[ -n "$tok" ]] && printf 1 || printf 0)" --arg tr "$trace" --arg b "$bot" --arg a "$anon"
    return 0
  fi
  # A failing self-test is a FINDING, not a crash: it is the only surface on which an
  # inert gate announces itself, so it prints the same fields and exits non-zero.
  if (( JSON_MODE )); then
    ok "merge-gate selftest: $detail" \
       '{verdict:$v, seat:$s, controlPr:$p, state:$st, tokenResolved:($tk=="1"), tokenTrace:$tr, botRail:$b, anonRail:$a}' \
       --arg v "$verdict" --arg s "$seat" --arg p "$pr" --arg st "$state" \
       --arg tk "$([[ -n "$tok" ]] && printf 1 || printf 0)" --arg tr "$trace" --arg b "$bot" --arg a "$anon"
    return "$rc"
  fi
  warn "merge-gate selftest FAILED on $seat: $detail"
  warn "  token arms: ${trace:-none run}"
  warn "  machine-account rail: $bot · anonymous rail: $anon"
  warn "  a close from this seat is not verified-clean; grade it with \`task merge-audit --limit=1\` or hand the close to a seat that passes."
  return "$rc"
}

cmd_task_merge_audit() {
  tasks_db_init
  local limit=200
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit=*) limit="${1#*=}"
                 [[ "$limit" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--limit must be a positive integer" ;;
      --json)    JSON_MODE=1 ;;
      -h|--help) printf 'usage: 5dive task merge-audit [--limit=N] [--json]\n'; return 0 ;;
      *)         fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  command -v gh >/dev/null 2>&1 || fail "$E_GENERIC" "task merge-audit needs \`gh\` to resolve PR state — install gh."
  local tok slugs; tok=$(_gate_gh_token); slugs=$(_gate_repo_slugs | paste -sd, -)
  _gate_gh_reachable "$tok" || fail "$E_GENERIC" "task merge-audit cannot reach GitHub — $(_gate_tok_why); machine-account rail not permitted on this seat. Check \`5dive gh whoami\` and \`5dive task merge-gate-selftest\`, then authenticate gh (or export GH_TOKEN) and re-run"
  _gate_pr_refs_engine_ok || fail "$E_GENERIC" "task merge-audit cannot parse PR references on this host (grep -oE unusable) — fix grep and re-run"
  local rows findings=0 unver=0 amb=0 deliv_n=0 cited_n=0 json_rows=""
  rows=$(db "SELECT ident || '|' || COALESCE(delivery_ref,'') || '|' || REPLACE(REPLACE(COALESCE(delivery_ref,'') || ' ' || COALESCE(result,'') || ' ' || COALESCE(body,''), char(10), ' '), '|', ' ')
               FROM tasks WHERE status='done' ORDER BY COALESCE(done_at, created_at) DESC LIMIT ${limit};")
  local line tident tdref ttext qref st state rslug tslug tdeliv origin
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    tident="${line%%|*}"; line="${line#*|}"
    tdref="${line%%|*}"; ttext="${line#*|}"
    # DIVE-1955: same repo resolution the gate uses, so the sweep and the gate can
    # never disagree about which pull request a task means. The audit's OWN previous
    # answer ("0 OPEN, 0 merged-red") was true only for the CLI repo, and reported
    # DIVE-1874/1875 as CLOSED on a `#25` that is a 5dive-api number colliding with
    # an old CLI one — a resolved-looking verdict about the wrong PR, which the
    # footnote excused only for `unverified`.
    tslug=$(_gate_task_repo_slug "$tdref" "$ttext")
    # DIVE-1975: LABEL each finding delivered-vs-cited. NEVER filter on it.
    #
    # DIVE-1965 split "a PR this task DELIVERED" from "a PR this task WRITES ABOUT"
    # and taught the gate to skip the second. This sweep is the SAME predicate over
    # the SAME data feeding a DIFFERENT consumer, and the two want OPPOSITE safe
    # defaults:
    #   * the GATE blocks a close. Over-judging stalls the fleet — the exact
    #     fleet-wide blocker DIVE-1965 exists to prevent — so its default is CITED
    #     and delivery must be asserted.
    #   * this SWEEP blocks nothing; a human reads it. Over-reporting costs one line
    #     to dismiss. Under-reporting HIDES REAL UNMERGED WORK, which is the whole
    #     job. So it reports every ref and annotates the ones it cannot bind.
    # Filtering to `delivered` here would rebuild the DIVE-1955 blindness one layer
    # down and HARDER TO SEE: the sweep would come back clean while the work it was
    # built to find sat unmerged behind a maker's phrasing. DIVE-1965's own known
    # coverage seam (an own delivery phrased outside the shipping-verb vocabulary)
    # lands precisely there. Same shape as DIVE-1955's `ambiguous` branch: report
    # the non-answer, do not manufacture one and do not swallow it. A label lets the
    # reader triage; a filter decides for them with the gate's risk model.
    #
    # Two deliberate differences from the gate's classification, both widening
    # `delivered`, which is the harmless direction when nothing is dropped:
    #   1. the `delivery_ref` COLUMN is folded in. It never reaches the gate's prose
    #      classifier (a declared ref routes to the declared gate) but it IS part of
    #      this row's text, and a bound delivery_ref is the strongest delivery
    #      assertion we have — classifying it as a citation would be plainly wrong.
    #   2. the row arrives with newlines collapsed to spaces (the reader loop is
    #      line-based), so the classifier's line-scoping degrades to text-scoping and
    #      a shipping verb can reach across an original line break. Cosmetic here:
    #      it can only move a row from `cited` to `delivered` in a report where both
    #      are printed.
    tdeliv=$( _gate_pr_refs_qualified_from_text "$tdref"
              _gate_delivery_refs_from_text "$ttext" )
    while IFS= read -r qref; do
      [[ -n "$qref" ]] || continue
      st=$(_gate_resolve_qualified "$qref" "$tok" "$tident" "$tslug")
      rslug="${st%%|*}"; st="${st#*|}"; state="${st%%|*}"
      if [[ "$rslug" == "AMBIGUOUS" ]]; then
        state="ambiguous"; rslug="${st//,/, }"; amb=$((amb+1))
      elif [[ -z "$rslug" ]]; then
        state="unverified"; rslug="-"; unver=$((unver+1))
      else
        case "$state" in
          MERGED) [[ "${st##*|}" == "FAILURE" ]] || continue
                  state="MERGED-RED" ;;
        esac
      fi
      findings=$((findings+1))
      # The gate's membership rule, verbatim (DIVE-1965): an exact qualified match,
      # OR the same number asserted BARE — the extractor may have upgraded a bare
      # "PR #N" to `slug|N` off a URL elsewhere in the same text, so a number-only
      # match on the cited side would be too loose and an exact-only match too tight.
      if printf '%s\n' "$tdeliv" | grep -qxF -e "$qref" -e "|${qref#*|}"; then
        origin="delivered"; deliv_n=$((deliv_n+1))
      else
        origin="cited"; cited_n=$((cited_n+1))
      fi
      json_rows+=$(jq -nc --arg t "$tident" --arg p "${qref#*|}" --arg r "$rslug" --arg s "$state" --arg o "$origin" \
                     '{ident:$t,pr:("#"+$p),repo:$r,state:$s,origin:$o}')$'\n'
      [[ "${JSON_MODE:-0}" == "1" ]] || printf '%-12s %-22s PR #%-6s %-11s %s\n' "$tident" "$rslug" "${qref#*|}" "$state" "$origin"
    done < <(_gate_pr_refs_qualified_from_text "$ttext")
  done <<<"$rows"
  local payload; payload=$(printf '%s' "$json_rows" | jq -sc '.')
  if [[ "${JSON_MODE:-0}" != "1" ]] && (( unver + amb > 0 )); then
    printf 'note: `unverified` = the number resolves to no PR in the repo(s) searched FOR THAT\n      TASK — the one its own record DECLARES (a delivery_ref URL or a `Repo:` line) when it\n      declares one, else all of %s (DIVE-1963).\n      `ambiguous` = a bare "PR #N" that exists in more than one of them and the task\n      declares no repo, so no single verdict is defensible. NEITHER is evidence of an\n      unmerged PR, and neither is evidence of a clean one. Cite the full pull URL, or\n      add a `Repo: <owner>/<repo>` line to the task body, to have them resolved.\n' "$slugs"
  fi
  # DIVE-1975: the label is only useful if the reader knows it is a LABEL and not a
  # filter — otherwise `cited` reads as "already dismissed" and the rows it marks get
  # skipped, which is the filter we refused to write, executed by the human instead.
  if [[ "${JSON_MODE:-0}" != "1" ]] && (( findings > 0 )); then
    printf 'note: `delivered` = the task ASSERTS this PR as its own delivery (a bound delivery_ref,\n      a `Delivered:` line, or a shipping verb next to the ref — DIVE-1965).\n      `cited` = the task names the PR but claims no delivery. It is a LABEL, not a\n      filter: every reference found is listed either way, because a maker who shipped\n      without the phrasing would otherwise vanish from this sweep entirely (DIVE-1975).\n      Triage `delivered` first; `cited` rows are usually another task'"'"'s to answer for.\n'
  fi
  ok "merge-audit: scanned the newest $limit done task(s) across $slugs — $findings PR reference(s) not merged-and-green ($deliv_n delivered by the task, $cited_n only cited; $unver unverified, $amb ambiguous)" \
     '{scanned:($n|tonumber), repos:($rp|split(",")), findings:($f|tonumber), delivered:($d|tonumber), cited:($c|tonumber), unverified:($u|tonumber), ambiguous:($a|tonumber), rows:($r|fromjson)}' \
     --arg n "$limit" --arg rp "$slugs" --arg f "$findings" --arg d "$deliv_n" --arg c "$cited_n" --arg u "$unver" --arg a "$amb" --arg r "$payload"
}

# `5dive task merge-unverified [--limit=N] [--since=<Nd|Nh>] [--json]` — DIVE-3526.
#
# THE STAMP HAD NO CONSUMER. DIVE-1935 taught the mandatory auto-detect gate to say
# so when its repo scan could not complete: it warns, it writes a
# `task.merge-gate-unverified` row to the audit log, and it lets the close proceed
# (fail-open stays — DIVE-1830 refused fail-CLOSED for blast radius and that is
# still the right refusal). All of that works and is firing: 196 stamped rows in
# `agent-audit.log` on 2026-08-17, every recent one `reason=partial-repo-scan-7-of-11`.
# The gap is one layer later — NOTHING EVER READ THEM BACK. DIVE-3300 closed
# 2026-08-12 with exactly that stamp and nobody re-derived it for five days.
# A record that is written and never read is a receipt, not a control.
#
# WHY `merge-audit` DOES NOT ALREADY COVER THIS, and it is not a limit you can raise.
# That sweep is TEXT-DRIVEN: it pulls PR references out of a done row's own
# delivery_ref/result/body and resolves them. The stamped population is precisely the
# closes where the gate's own scan came up empty, and the auto-detect gate runs ONLY
# when the row declared no binding at all — so the typical stamped row NAMES NO PR
# ANYWHERE IN ITS TEXT and yields `merge-audit` exactly zero references to resolve.
# DIVE-3300 is that shape: its result names a patch file and no pull request.
# So this sweep is driven by the OTHER key — the ident the gate stamped — and
# re-derives with the OTHER predicate: the gate's own open-PR-by-ident scan, run now.
#
# THE SCAN IS INVERTED ON PURPOSE. The gate asks one ident against every repo. Doing
# that per stamped ident is repos x idents API calls (11 x 196 = 2156 here) and the
# sweep would be unrunnable. Every ident asks the same question of the same repo, so
# each repo's OPEN pull requests are listed ONCE and every ident is matched against
# the result in memory: 11 calls, whatever the backlog. The MATCH is the gate's,
# character for character — ident at word boundaries, case-insensitive, against
# title and headRefName only, never the body (a "follow-up to DIVE-N" mention must
# not raise a finding, DIVE-1835).
#
# AND IT REFUSES TO LAUNDER ITS OWN PARTIAL COVERAGE, which is the whole lesson of the
# ticket it consumes. A repo whose listing fails is not a repo with no hits, and a
# `--limit 200` page that comes back FULL may have more behind it. Either one makes a
# quiet row `unconfirmed`, never `clean`, and the summary reports scanned-k-of-n. An
# unreadable audit log is a hard failure, not "0 stamps found" — that inference is the
# DIVE-1935 defect itself, rebuilt in the consumer.
#
# Read-only. It reports; it never reopens a row and never touches the gate.
cmd_task_merge_unverified() {
  tasks_db_init
  local limit=500 since="" cutoff=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit=*) limit="${1#*=}"
                 [[ "$limit" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--limit must be a positive integer" ;;
      --since=*) since="${1#*=}"
                 [[ "$since" =~ ^[1-9][0-9]*[dh]$ ]] || fail "$E_VALIDATION" "--since must look like 7d or 48h" ;;
      --json)    JSON_MODE=1 ;;
      -h|--help) printf 'usage: 5dive task merge-unverified [--limit=N] [--since=<Nd|Nh>] [--json]\n'; return 0 ;;
      *)         fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  command -v jq >/dev/null 2>&1 || fail "$E_GENERIC" "task merge-unverified needs \`jq\` to read the audit log — install jq."
  command -v gh >/dev/null 2>&1 || fail "$E_GENERIC" "task merge-unverified needs \`gh\` to re-derive PR state — install gh."

  # The stamps live in the audit log, which is 640 root:claude. A caller who cannot
  # READ it must not be told the backlog is empty: an unreadable log and a clean
  # fleet are the same silence, and telling them apart is this verb's job.
  local logf="${AUDIT_LOG:-/var/log/5dive/agent-audit.log}"
  [[ -e "$logf" ]] || fail "$E_GENERIC" "task merge-unverified cannot find the audit log ($logf) — the stamps it consumes are written there; nothing was scanned. This is NOT an empty backlog."
  [[ -r "$logf" ]] || fail "$E_GENERIC" "task merge-unverified cannot READ the audit log ($logf: $(stat -c '%A %U:%G' "$logf" 2>/dev/null || printf 'permissions unknown')) — it is 640 root:claude, so run this from a seat in group \`claude\`. An unreadable log reads exactly like a clean fleet; refusing rather than reporting 0 is the point."

  if [[ -n "$since" ]]; then
    local _n="${since%[dh]}" _u="${since: -1}"
    cutoff=$(date -u -d "-${_n} ${_u/d/days}" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || cutoff=""
    [[ "$_u" == "h" ]] && cutoff=$(date -u -d "-${_n} hours" +%Y-%m-%dT%H:%M:%S 2>/dev/null)
    [[ -n "$cutoff" ]] || fail "$E_GENERIC" "task merge-unverified could not compute a cutoff from --since=$since (\`date -u -d\` unusable on this host) — re-run without --since rather than reading an unfiltered sweep as a filtered one."
  fi

  # ident<TAB>ts<TAB>reason<TAB>seat, newest LAST so the dedupe below keeps the newest
  # stamp per ident (a row re-closed after a reopen stamps twice).
  local stamps
  stamps=$(jq -rs --arg cut "$cutoff" '
      .[] | select(.cmd == "task.merge-gate-unverified")
      | select($cut == "" or (.ts >= $cut))
      | [ (.args[0] // ""),
          (.ts // ""),
          ((.args[] | select(startswith("reason="))) // "reason=unrecorded"),
          (.user // "") ] | @tsv
    ' "$logf" 2>/dev/null | awk -F'\t' '$1 ~ /^DIVE-[0-9]+$/ { r[$1]=$0 } END { for (k in r) print r[k] }' | sort -t$'\t' -k2,2r | head -n "$limit")

  local total_stamps=0
  [[ -n "$stamps" ]] && total_stamps=$(printf '%s\n' "$stamps" | grep -c .)

  local tok slugs; tok=$(_gate_gh_token); slugs=$(_gate_repo_slugs | paste -sd, -)
  _gate_gh_reachable "$tok" || fail "$E_GENERIC" "task merge-unverified cannot reach GitHub — $(_gate_tok_why); machine-account rail not permitted on this seat. It would report every stamped close as quiet by asking nothing. Check \`5dive gh whoami\` and \`5dive task merge-gate-selftest\`, then re-run"

  # ── one listing per repo, reused by every ident ──────────────────────────
  local prs_f; prs_f=$(mktemp "${TMPDIR:-/tmp}/.5dive-mu-prs.XXXXXX")
  local slug hits repos_total=0 repos_ok=0 unscanned="" capped=""
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    repos_total=$((repos_total+1))
    if hits=$(_gate_gh "$tok" 20 pr list --repo "$slug" --state open --limit 200 \
                --json number,headRefName,title \
                -q '.[] | [(.number|tostring), (.title // ""), (.headRefName // "")] | @tsv' 2>/dev/null); then
      repos_ok=$((repos_ok+1))
      # A FULL page is not a complete answer. Say so rather than sweeping 201.
      [[ $(printf '%s\n' "$hits" | grep -c .) -ge 200 ]] && capped="${capped:+$capped, }$slug"
      while IFS= read -r line; do [[ -n "$line" ]] && printf '%s\t%s\n' "$slug" "$line" >>"$prs_f"; done <<<"$hits"
    else
      unscanned="${unscanned:+$unscanned, }$slug"
    fi
  done < <(_gate_repo_slugs)
  local full_coverage=0
  [[ $repos_ok -eq $repos_total && $repos_total -gt 0 && -z "$capped" ]] && full_coverage=1

  local line tident tts treason tseat st verdict detail
  local findings=0 clean=0 unconf=0 reopened=0 missing=0 json_rows=""
  while IFS=$'\t' read -r tident tts treason tseat; do
    [[ -n "$tident" ]] || continue
    st=$(db "SELECT status FROM tasks WHERE ident='${tident}' LIMIT 1;")
    detail=""
    if [[ -z "$st" ]]; then
      verdict="row-missing"; missing=$((missing+1))
      detail="no such row in the task store"
    elif [[ "$st" != "done" ]]; then
      # The stamp recorded an unverified CLOSE. If the row is not closed now, that
      # close was undone and there is nothing silent left to surface here.
      verdict="reopened"; reopened=$((reopened+1)); detail="row is now '$st', not done"
    else
      # Neither the slug nor the PR number can contain "DIVE-<n>", so a whole-line
      # match is the gate's title/headRefName predicate with no extra field surgery.
      local hit h_slug h_num h_title
      hit=$(grep -iE "(^|[^A-Za-z0-9])${tident}([^A-Za-z0-9]|$)" "$prs_f" 2>/dev/null | head -1 || true)
      if [[ -n "$hit" ]]; then
        IFS=$'\t' read -r h_slug h_num h_title _ <<<"$hit"
        verdict="OPEN-PR"; findings=$((findings+1))
        detail="$h_slug #$h_num still OPEN — \"$h_title\""
      elif (( full_coverage )); then
        verdict="clean"; clean=$((clean+1)); detail="no open PR names it in $repos_ok/$repos_total repos"
      else
        verdict="unconfirmed"; unconf=$((unconf+1))
        detail="no open PR found, but only $repos_ok/$repos_total repos answered${capped:+ (page full in $capped)} — NOT clean"
      fi
    fi
    json_rows+=$(jq -nc --arg t "$tident" --arg s "$tts" --arg r "${treason#reason=}" --arg u "$tseat" --arg v "$verdict" --arg d "$detail" \
                   '{ident:$t,stampedAt:$s,reason:$r,seat:$u,verdict:$v,detail:$d}')$'\n'
    [[ "${JSON_MODE:-0}" == "1" ]] || printf '%-12s %-20s %-11s %s\n' "$tident" "${tts%%+*}" "$verdict" "$detail"
  done <<<"$stamps"
  rm -f "$prs_f"

  local payload; payload=$(printf '%s' "$json_rows" | jq -sc '.')
  if [[ "${JSON_MODE:-0}" != "1" ]]; then
    (( findings > 0 )) && printf 'note: `OPEN-PR` = this row CLOSED while the merge-gate could not check it, and an open\n      pull request naming the ident exists RIGHT NOW. Triage these: either land the PR,\n      close it as abandoned, or record on the row why the close was correct anyway.\n'
    (( unconf > 0 )) && printf 'note: `unconfirmed` is NOT a clean row. %s of %s repos answered%s, so "no open PR" is a\n      statement about the repos that answered, never about the ones that did not\n      (DIVE-1935/1955). Re-run from a seat whose token reads them all.\n' "$repos_ok" "$repos_total" "${capped:+, and the 200-PR page was full in $capped}"
    [[ -n "$unscanned" ]] && warn "repos that did NOT answer: $unscanned"
  fi
  ok "merge-unverified: $total_stamps stamped close(s) re-derived across $repos_ok/$repos_total repos — $findings still carry an OPEN PR ($clean clean, $unconf unconfirmed, $reopened reopened, $missing row-missing)" \
     '{stamps:($n|tonumber), repos:($rp|split(",")), reposScanned:($ro|tonumber), reposTotal:($rt|tonumber), fullCoverage:($fc=="1"), unscanned:($us|split(", ")|map(select(.!=""))), pageCapped:($cp|split(", ")|map(select(.!=""))), findings:($f|tonumber), clean:($c|tonumber), unconfirmed:($u|tonumber), reopened:($re|tonumber), rowMissing:($m|tonumber), rows:($r|fromjson)}' \
     --arg n "$total_stamps" --arg rp "$slugs" --arg ro "$repos_ok" --arg rt "$repos_total" --arg fc "$full_coverage" \
     --arg us "$unscanned" --arg cp "$capped" --arg f "$findings" --arg c "$clean" --arg u "$unconf" \
     --arg re "$reopened" --arg m "$missing" --arg r "$payload"
  # Exit status is the consumable signal — a stamp with no consumer is what this verb
  # exists to fix, so `merge-unverified && echo ok` must mean something to cron.
  (( findings > 0 )) && return 1
  return 0
}

# DIVE-477: hand a maker-completed task to its verifier instead of closing it.
# Stash the original maker (first writer wins, so it survives re-routes) so a
# verify FAIL can bounce straight back, bump the iteration counter, keep the
# maker's result, and re-queue the task to the verifier as a fresh todo — the
# heartbeat picks it up on the verifier's next tick exactly like any other todo
# in their queue (no heartbeat change needed). No status='done' is written: the
# work is not closed until the verifier signs off.
_task_route_to_verifier() {
  local id="$1" vfier="$2" maker="$3" result="$4" want_result="$5" stamp_binding="${6:-0}"
  local set_result=""
  (( want_result )) && set_result=", result=$(sqlq_or_null "$result")"
  # DIVE-2682: stamp the binding's iteration in the SAME UPDATE that bumps the
  # counter, never in a second statement. Both right-hand sides evaluate against
  # the PRE-update row, so delivery_ref_iteration and iteration land on the same
  # number — which is the whole point. Reading the counter at two different
  # moments is what would false-REFUSE the well-behaved maker who re-points the
  # binding and delivers in one breath.
  #
  # Only cmd_task_deliver passes 1: it is the only caller of THIS helper that
  # just (re)pointed the binding. DIVE-2316's merge-gate discovery write is a
  # separate writer on the non-loop close path and never calls this helper.
  # A plain `task done`
  # re-delivery passes 0 and deliberately leaves the stamp behind at its old
  # iteration — that gap IS the signal the gate reads.
  local set_binding_iter=""
  # DIVE-2682 + DIVE-2624 interaction, found by rebasing onto 8051cb1: the counter's
  # bump became CONDITIONAL ("re-delivery of the same pass, not rework" — it only
  # increments on a first delivery or after a reject). An unconditional +1 here then
  # stamped the binding at iteration+1 while `iteration` itself stayed put, leaving
  # bind > iter on every same-pass re-delivery — a state the guard's own predicate
  # (bind < iter) can never flag, so it fails SILENTLY rather than loudly. The stamp
  # must mirror the counter's CASE exactly, or the two answers are read from
  # different moments again, which is the hazard this row's body opens with.
  (( stamp_binding )) && set_binding_iter=", delivery_ref_iteration=CASE
              WHEN handoff_delivered_at IS NULL OR handoff_rejected_at IS NOT NULL
              THEN COALESCE(iteration,0)+1
              ELSE COALESCE(iteration,0) END"
  # DIVE-1416 (gap#2): stamp handoff_delivered_at fresh on EVERY delivery (incl.
  # a re-delivery after a reject/bounce-back) — the dedicated clock the stall
  # sweep uses to detect a delivery sitting unacknowledged too long. Clear any
  # prior stale-ping flag so a redelivered task gets a clean shot at surfacing
  # again if it goes stale a second time.
  # DIVE-2624 (b): THE COUNTER MEANS "how many times has the verifier sent this
  # back", because that is what every reader assumes it means — a high iteration
  # is read as a maker who keeps missing the bar, and `task loops` flags a loop as
  # STUCK off it. It used to bump on EVERY `task done`, so a delivery that merely
  # RESTORED a handoff the gate path had just destroyed (DIVE-2624 (a)) inflated it:
  # DIVE-2594 read iteration 3 for two real passes plus one accounting ghost, and
  # the maker had to write "that bump was a restore" into the result by hand.
  #
  # A pass counts when the verifier REJECTED it, and that is the only signal that
  # can distinguish the two — handoff_delivered_at IS NOT NULL alone cannot, because
  # it is equally true of a genuine second pass after a bounce-back. cmd_task_reject
  # stamps handoff_rejected_at on the bounce, and THIS delivery spends it.
  #
  # A TOKEN, NOT A CLOCK COMPARISON, and the first cut got that wrong. Comparing
  # handoff_rejected_at against handoff_delivered_at looks equivalent and is not:
  # both are datetime('now') at ONE-SECOND resolution, so a reject and the delivery
  # that answers it routinely land in the SAME second. Any comparison then has to
  # pick a side of the tie and is wrong on the other — `>=` leaves the reject looking
  # permanently outstanding, so every later re-delivery re-bumps; `>` drops a reject
  # answered inside a second. My local box was slow enough to separate them and
  # passed; CI was not, and T9 came back iteration=3. Consuming the token has no tie
  # to break: the reject is spent exactly once, whatever the clock says.
  local prev_iter; prev_iter=$(db "SELECT COALESCE(iteration,0) FROM tasks WHERE id=${id};")
  db "UPDATE tasks
        SET status='todo', assignee=$(sqlq "$vfier"),
            maker_agent=COALESCE(maker_agent, $(sqlq_or_null "$maker")),
            iteration=CASE
              WHEN handoff_delivered_at IS NULL OR handoff_rejected_at IS NOT NULL
              THEN COALESCE(iteration,0)+1
              ELSE COALESCE(iteration,0) END,
            handoff_rejected_at=NULL,
            started_at=NULL, handoff_ack_at=NULL,
            handoff_delivered_at=datetime('now'), handoff_stale_pinged_at=NULL${set_result}${set_binding_iter}
      WHERE id=${id};"
  # DIVE-3349: close the session segment. This is the ONE status transition that
  # returns BEFORE `_task_status_cmd`'s funnel, so the hook there cannot see it —
  # and a delivered row is not being worked (it is sitting in the verifier's
  # queue), so a segment left open here would keep charging this row for every
  # later turn of a session that has moved on. `task deliver` with NO distinct
  # verifier deliberately does NOT reach this line: it leaves the row in_progress
  # and the maker is still working, so its segment stays open.
  _task_session_close "$id"
  local iter; iter=$(db "SELECT iteration FROM tasks WHERE id=${id};")
  local iter_note=""
  [[ "$iter" == "$prev_iter" ]] && iter_note=" — re-delivery of the same pass, not rework"
  local ident; ident=$(ident_of "$id")
  # INST-4: the maker→verifier DELIVERY.
  #
  # Emitted here and not from _task_status_cmd, because a `task done` that
  # delivers never reaches _task_status_cmd — it forks earlier, into this
  # handoff write. The first cut of this change assumed one funnel and shipped a
  # ledger with no delivered event at all; the e2e caught it because the row was
  # simply absent, which is the one shape a ledger cannot self-report.
  #
  # The distinction is load-bearing, not cosmetic: a delivery is NOT a close. A
  # ledger that recorded it as `task.done` would attest that work was finished
  # while it is still waiting to be graded — the precise overstatement the
  # verifier rail exists to prevent, asserted by our own evidence base.
  ledger_emit task.delivered ident="$ident" task_id="$id" actor="$(task_actor "")" \
    out="${result:-}" detail="delivered to verifier ${vfier} (iteration ${iter}${iter_note}; awaiting ACK)"
  # DIVE-3503 — `task deliver` is a terminal boundary for the MAKER even though
  # the row stays open, so it reaps like done/cancel. Same predicate, same
  # protections; see src/lib/reap.sh.
  declare -F _reap_at_task_boundary >/dev/null 2>&1 && _reap_at_task_boundary "deliver" "$ident" || true

  ok "$ident ready for review — delivered to verifier '$vfier' (iteration ${iter}${iter_note}; awaiting ACK)" \
     '{id:($i|tonumber), ident:$id, status:"todo", routedTo:$v, role:"verifier", handoff:"delivered", acknowledged:false, iteration:($n|tonumber)}' \
     --arg i "$id" --arg id "$ident" --arg v "$vfier" --arg n "$iter"
}

# DIVE-477: the verifier's FAIL verdict. The maker's work missed the bar, so
# bounce the task back to the maker with feedback for another pass — UNLESS we've
# reached max_iterations, where the loop is stuck and we park it on a human
# (`task need`) rather than ping-pong forever. Only meaningful mid-loop
# (maker_agent set); a plain task has no maker to bounce to.
# DIVE-2777: the ONE emitter for a bounce, shared by both of `reject`'s write
# sites — the ordinary bounce-back and the max_iterations escalation. It is a
# function rather than two call-sites-worth of inline `ledger_emit` for the exact
# reason this ticket exists: DIVE-2483 fixed a class in three places and left a
# fourth hand-rolled copy, which then survived the fix meant to kill it. The next
# path added to `reject` should inherit this rather than re-derive it.
#
# `out` is the SUPERSEDED text, deliberately, not the rejection line. output_hash
# is then sha256 of what was on the row when the bounce landed, so it EQUALS the
# `task.delivered` output_hash for the same ident and a reader can say WHICH
# delivery this bounce displaced. The rejection text itself is on the row and
# needs no hash.
_task_reject_emit_event() {
  local ident="$1" id="$2" actor="$3" prev="$4" iter="$5" maxi="$6" disposition="$7"
  local prior
  if (( ${#prev} )); then
    prior="superseded (${#prev} bytes, preserved on the row)"
  else
    prior="none"
  fi
  ledger_emit task.rejected ident="$ident" task_id="$id" actor="$actor" \
    out="$prev" \
    detail="rejected by ${actor} at iteration ${iter}${maxi:+/$maxi}, ${disposition}; prior_result=${prior}"
}

cmd_task_reject() {
  tasks_db_init
  local task="" feedback=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --feedback=*) feedback="${1#*=}" ;;
      --reason=*)   feedback="${1#*=}" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task reject <id|DIVE-N> [--feedback=\"<what to fix>\"]"
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local maker iter maxi vfier
  maker=$(db "SELECT COALESCE(maker_agent,'')    FROM tasks WHERE id=${id};")
  iter=$(db  "SELECT COALESCE(iteration,0)       FROM tasks WHERE id=${id};")
  maxi=$(db  "SELECT COALESCE(max_iterations,0)  FROM tasks WHERE id=${id};")
  vfier=$(db "SELECT COALESCE(verifier,'')       FROM tasks WHERE id=${id};")
  [[ -n "$maker" ]] || fail "$E_VALIDATION" \
    "$ident is not in a maker→verifier loop (no maker to bounce to) — use 'task need'/'task block' for a plain rejection"
  # DIVE-2112: found by olivia verifying DIVE-2067 — whose refusal text pointed makers HERE.
  # Measured on a fixture: a MAKER reject of an already-done task returned rc=0, reopened it,
  # replaced the verifier ACK, and — because the string hard-coded the RECORDED verifier —
  # recorded the write under a verifier who never made it. dev2 pressed the button, the board
  # said olivia did. Destroying a record is bad; MANUFACTURING a false one is worse.
  #
  # Scoped like DIVE-2067 rather than symmetrically: a lead bouncing an OPEN task is
  # legitimate and stays working. Only the two cases with nothing to escape from are refused.
  _rj_actor=$(task_actor "")
  _rj_st=$(db "SELECT COALESCE(status,'') FROM tasks WHERE id=${id};")
  # (1) the writer may not grade its own work (DIVE-477) — and a maker reject would otherwise
  # be filed under the verifier's name, which is the false-record half.
  if [[ -n "$maker" && "$_rj_actor" == "$maker" ]]; then
    policy_refuse "$E_CONFLICT" reject-by-maker DIVE-2112 "$ident" \
      "$ident lists you ('${_rj_actor}') as its MAKER. A reject is the verifier's grade, so this would be the writer grading its own delivery (DIVE-477) and would be recorded under '${vfier:-the verifier}''s name. Ask '${vfier:-the verifier}' to bounce it back, or send them what you found and let them decide."
  fi
  # (2) a CLOSED, graded task is not reopened by someone other than its grader. Deliberately
  # names no alternative verb: this fix exists because DIVE-2067's refusal enumerated one.
  if [[ "$_rj_st" == 'done' && -n "$vfier" && "$_rj_actor" != "$vfier" ]]; then
    policy_refuse "$E_CONFLICT" reject-over-closed DIVE-2112 "$ident" \
      "$ident is already done and was graded by '${vfier}', not by you ('${_rj_actor}'). Reopening it here would discard that grade and file the reopen under '${vfier}''s name. '${vfier}' can reopen their own grade; anyone else should raise a NEW task citing $ident."
  fi
  # (3) attribute to the REAL actor, never to the recorded verifier by assumption.
  local fb_txt="❌ ${_rj_actor} rejected (iteration ${iter}): ${feedback:-no feedback given}"
  # (4) never silently discard a landed record — VIA THE SHARED GUARD, not a
  # private copy of it.
  #
  # DIVE-2773. `reject` cannot write a BLANK (a missing --feedback substitutes
  # "no feedback given" above), so it is not in the first-close-needs-a-reason
  # population at all. Its defect was the other one, and it is DIVE-2762 EXACTLY,
  # one verb over: the hand-rolled preservation this replaces read
  #
  #     if [[ "$_rj_st" == 'done' && -n "$_rj_prev" ]]; then ... fi
  #
  # so the preservation FIRED ONLY ON A `done` ROW. A row delivered to a verifier
  # is `todo` BY DESIGN — that is the rail's own contract, a correct `task done`
  # delivers it, status stays todo, assignee moves to the verifier. So on the
  # ORDINARY reject path, the one the loop manufactures on every bounce, `_rj_st`
  # is 'todo', the branch did not fire, and the bare UPDATE below replaced the
  # MAKER'S RESULT with the rejection text. No warning, no marker, no audit of
  # the overwritten value.
  #
  # That is DIVE-2762's finding verbatim: the guard keyed on CLOSED-NESS while
  # the population is CARRIES-A-RESULT. DIVE-2483 repaired exactly that for
  # done/deliver/verify by routing all three through
  # `_task_guard_result_over_closed`. `cmd_task_reject` was never one of its call
  # sites; it kept a private copy of the OLD, WRONG predicate and so survived the
  # fix meant to kill the class — while wearing a DIVE-2067 marker that made it
  # look handled. Fixing a class in three places and leaving a fourth hand-rolled
  # copy is how this got here, which is why the remedy is one predicate and not a
  # fourth condition: the next verb added inherits the guard instead of a habit.
  #
  # append_result=1 rather than 0, and that is load-bearing: on a CLOSED row the
  # guard's default is to REFUSE, which would break the one legitimate reopen
  # DIVE-2112 allows (the recorded verifier withdrawing their own grade) — the
  # very case the old private branch existed to serve. Asking for the append is
  # what makes this a strict widening. Note the seam puts the PRIOR text first
  # now, where the old marker put it last; that is the shared convention's order
  # and a single grep still finds every superseded record.
  #
  # DIVE-2777. Read the prior text BEFORE the guard runs, for the lifecycle event
  # below — after it, `$fb_txt` is the merged string and the question "was there a
  # record here to supersede" is no longer answerable from the row.
  local _rj_prev; _rj_prev=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${id};")
  _task_guard_result_over_closed "$id" "$ident" reject "$fb_txt" 1 0 reject-result-over-open
  fb_txt="$_TASK_GUARDED_RESULT"
  # DIVE-1495: a reject supersedes any still-open need-gate on this task. Leaving
  # it 'pending' (need_answered_at NULL) let the DIVE-1490 re-nag ladder keep
  # firing a question the reject already mooted (CNCL-9: lodar was re-nagged AFTER
  # the task was rejected). Resolve it as auto:reject so the open-gate predicate
  # (need_type set AND need_answered_at NULL) stops matching, while preserving the
  # gate row for audit. The max_iterations branch below then files its OWN fresh
  # manual gate to a human on purpose.
  local _open_gate; _open_gate=$(db "SELECT CASE WHEN need_type IS NOT NULL
        AND need_answered_at IS NULL THEN 1 ELSE 0 END FROM tasks WHERE id=${id};")
  # DIVE-2196: ...but NOT a tier-2 one. The supersede below writes
  # need_answered_by='auto:reject' with raw SQL, which is a NON-HUMAN provenance on
  # a gate the tier-2 floor exists to keep human-only — cmd_task_answer refuses
  # exactly that write, and this path reaches around it. `task done` over a live
  # gate is already refused (DIVE-555); reject was the remaining verb by which an
  # agent could clear a human's pending question as a side effect of its own move.
  # Scoped to an AGENT actor: a genuine human caller is the very party the gate is
  # waiting on, and an unattributable one ('none': CI, root cron) is the different
  # question DIVE-2007 got wrong by answering it here. Tier<=1 keeps DIVE-1495's
  # supersede untouched — a fleet-actionable gate is one an agent could have
  # cleared anyway, and leaving it pending is the CNCL-9 re-nag defect.
  if [[ "$_open_gate" == "1" ]]; then
    # EXPLICIT tier only. Every gate filed through `task need` writes a tier, so a
    # NULL one is a legacy or hand-inserted row that predates tiers — inferring a
    # human-only floor from a missing value would retro-fit this refusal onto rows
    # nobody ever tiered and silently break DIVE-1495's supersede where it has
    # always applied (caught by tests/gate_verifier_route_unit.sh, whose DIVE-505
    # fixture is exactly that shape). Fail-closed on an absent tier belongs where a
    # gate is being ANSWERED — a grant; here the question is whether a rail that has
    # worked since DIVE-1495 keeps working.
    local _og_tier _og_type _og_actor _og_kind
    _og_tier=$(db "SELECT COALESCE(tier,'')            FROM tasks WHERE id=${id};")
    _og_type=$(db "SELECT COALESCE(need_type,'gate')   FROM tasks WHERE id=${id};")
    _og_actor=$(_gate_withdraw_actor)          # "agent <name>" | "human" | "none"
    _og_kind="${_og_actor%% *}"
    if [[ -n "$_og_tier" && "$_og_tier" -ge 2 && "$_og_kind" == "agent" ]]; then
      # MIRROR QUESTION (main, pre-merge): what does this guard make unreachable?
      # A verifier who grades the work a FAIL while a tier-2 gate stands. If the
      # only answer were "wait for the human", the rail would convert a
      # wrong-but-moving state into a correct-but-stuck one and the next agent
      # would route around it. So the refusal PRINTS the exit, and which exit
      # depends on who the caller is:
      #   - you filed the gate  -> you can retire it yourself: `need --withdraw`
      #     then reject. Two explicit steps, one of them recorded in gate_history
      #     as a withdrawal, which is the whole difference from a forged answer.
      #   - someone else filed it -> you cannot retire their ask and must not
      #     answer it for them, but your GRADE does not have to wait on it:
      #     `task set-body --append` records the verdict now, the reject lands
      #     when the gate clears. Nothing is lost, only the loop transition waits.
      local _og_filer _og_me _og_exit
      _og_filer=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''), assignee, '') FROM tasks WHERE id=${id};")
      _og_me="${_og_actor#agent }"
      if [[ -n "$_og_filer" && "$_og_filer" == "$_og_me" ]]; then
        _og_exit="You filed this gate, so you can retire it yourself: '5dive task need $ident --withdraw' (a withdrawal, archived to gate_history — not an answer put in a human's mouth), then reject. Do that only if your grade makes the question genuinely moot."
      else
        _og_exit="'${_og_filer:-its filer}' or their lead can withdraw it ('5dive task need $ident --withdraw') if your grade makes the question moot — ask them, do not answer it for them. Your grade does not have to wait on that: record it now with '5dive task set-body $ident \"VERDICT: ...\" --append' and send it to the maker, then reject once the gate clears."
      fi
      policy_refuse "$E_CONFLICT" reject-over-tier2-gate DIVE-2196 "$ident" \
        "$ident has an OPEN tier-2 ${_og_type} gate awaiting a human — rejecting it would mark that gate '(superseded)' with provenance 'auto:reject', i.e. an agent clearing a human-only gate as a side effect of its own move (DIVE-1117 floor, DIVE-2196). The wait is on the human, not on you. ${_og_exit} A human answering it ('5dive task answer $ident --value=...') also clears the way."
    fi
    local _sup_ts; _sup_ts=$(date -u '+%Y-%m-%d %H:%M:%S')
    db "UPDATE tasks SET need_answer='(superseded — task rejected, bounced to maker)',
          need_answered_at=$(sqlq "$_sup_ts"), need_answered_by='auto:reject', gate_pinged_at=NULL
        WHERE id=${id} AND need_answered_at IS NULL;"
    # DIVE-2054: task-store state — fenced.
    _task_store_audit_log "task reject gate-supersede" "ok" 0 -- "task=$ident" || true
    # DIVE-2410: superseded is settled. This one is the worst stale button of the
    # set — the gate now reads '(superseded ...)' with provenance auto:reject, so
    # a human tapping it would believe they authorized something an agent already
    # closed on their behalf.
    _task_gate_retire_buttons "$ident" "superseded by auto:reject" || true
  fi
  # max_iterations reached -> stop bouncing, park it on a human to decide.
  # DIVE-2477 considered clearing done_at here too, by symmetry with the
  # bounce-back below, and MEASURED that it would be wrong: this branch does not
  # reopen the row, it files a gate — and on a row that was CLOSED, `task need`
  # refuses (rc=5, "is done — reopen it before gating on a human"), so the status
  # stays 'done'. Clearing done_at would leave a done row with no close clock: a
  # NEW contradiction, not a fix. That refusal also means a reject at
  # max_iterations over a closed row cannot escalate at all (it writes the
  # feedback, then fails) — a separate pre-existing defect, deliberately not
  # ridden along here; graded as a documented control in
  # tests/task_close_preserves_done_at_unit.sh (arm G).
  if (( maxi > 0 && iter >= maxi )); then
    db "UPDATE tasks SET result=$(sqlq "$fb_txt") WHERE id=${id};"
    # DIVE-2777: THE SECOND WRITE SITE GETS THE EVENT TOO, and this branch is the
    # one that most needs it — it is the terminal reject, the bounce that ends the
    # loop and parks it on a human, and it `return`s before the emit below.
    #
    # Emitting only from the ordinary path would have rebuilt this row's own
    # defect in the fix for it: DIVE-2483 routed three verbs through the shared
    # guard and left `reject`'s fourth site hand-rolled, which is the entire reason
    # this ticket exists. A trace that covers the routine bounce and goes silent on
    # the escalation is the same shape — the population is EVERY reject, not every
    # reject that happens to fall through.
    _task_reject_emit_event "$ident" "$id" "$_rj_actor" "$_rj_prev" "$iter" "$maxi" \
      "escalated to human review at the iteration cap (loop stuck, not bounced back)"
    warn "$ident hit max_iterations ($maxi) — escalating to human review"
    cmd_task_need "$id" --type=manual --from="${vfier:-verifier}" \
      --ask="Maker→verifier loop stuck: $ident failed verification ${iter}× (max ${maxi}). Last feedback: ${feedback:-none}. Review + decide."
    return
  fi
  # Otherwise bounce back to the maker for another pass.
  # DIVE-2477: clear done_at. `task reject` is the one verb that REOPENS a closed
  # row (DIVE-2112 allows it for the recorded verifier withdrawing their own
  # grade, and refuses everyone else), and it left the close timestamp in place —
  # status='todo' on a row carrying a done_at, the same self-contradiction
  # DIVE-2113 refuses `task start` for. Latent before; load-bearing now that the
  # close verbs COALESCE, because a stale done_at would be PRESERVED as the real
  # close time on the next pass instead of stamped fresh.
  # DIVE-2624 (b): stamp the bounce. This is the ONLY event that makes the next
  # delivery a genuine second pass rather than a re-delivery of this one, and until
  # now it left no trace a later `task done` could read — which is why the iteration
  # counter had to bump on every delivery and so counted restores as rework. It is a
  # dedicated clock for the same reason handoff_delivered_at is one: updated_at moves
  # on any row touch and cannot answer "was there a reject since the last delivery".
  db "UPDATE tasks SET status='todo', assignee=$(sqlq "$maker"), started_at=NULL, handoff_ack_at=NULL,
        handoff_rejected_at=datetime('now'),
        done_at=NULL, result=$(sqlq "$fb_txt") WHERE id=${id};"
  # DIVE-2777: THE BOUNCE IS A LIFECYCLE EVENT. Until now `reject` emitted nothing
  # — the distinct kinds in the table were gate.answered, gate.filed,
  # policy.refused, ship, task.cancelled, task.created, task.delivered, task.done,
  # task.review, task.started, and no `task.rejected` among them. So a reject's
  # only trace was `handoff_rejected_at`, and :4426 NULLs that on the very next
  # delivery because it is an iteration-increment signal, not a log. A row that
  # goes rejected -> re-delivered -> closed therefore left NO machine-readable
  # trace that a bounce ever happened, which is why the historical count of
  # DIVE-2762-class destruction is a floor (3 known) rather than a number.
  #
  # It goes to lifecycle_events specifically because that table is APPEND-ONLY and
  # nothing on the re-delivery path touches it — the same property that makes
  # task.delivered's output_hash survive. A marker in `result` would not do: the
  # next delivery overwrites the column and takes the marker with it, which is the
  # design constraint olivia raised and then withdrew once main2 reproduced that
  # the surviving store already ships. So: emit the event, do NOT invent a new
  # durable column, and do NOT touch how handoff_rejected_at is spent.
  #
  # `out` carries the SUPERSEDED text, not the rejection line. output_hash is then
  # sha256 of what was on the row when the bounce landed, which is exactly the
  # value a later reader wants to compare against the task.delivered hash for the
  # same ident: same hash -> this bounce is the one that displaced that delivery.
  # The rejection text itself is on the row and needs no hash.
  #
  # This buys FORWARD countability only. It cannot backfill: an ordinary verifier
  # close also replaces `result`, so a destructive reject and a legitimate close
  # are indistinguishable by hash across the 278 existing task.delivered events
  # (270 mismatch — essentially the whole population). The census starts here.
  _task_reject_emit_event "$ident" "$id" "$_rj_actor" "$_rj_prev" "$iter" "$maxi" \
    "bounced back to maker ${maker}"
  ok "$ident rejected — bounced back to maker '$maker' (iteration $iter${maxi:+/$maxi})" \
     '{id:($i|tonumber), ident:$id, status:"todo", bouncedTo:$m, role:"maker", iteration:($n|tonumber)}' \
     --arg i "$id" --arg id "$ident" --arg m "$maker" --arg n "$iter"
  # DIVE-3499: the sender-visible receipt. A verifier who has just bounced a row
  # cannot otherwise tell "the maker will pick this up" from "this vanished", and
  # closes the gap by pinging them — which costs the maker a full reload of a PR
  # they had closed out. Cannot fail; see src/lib/routing_receipt.sh.
  # The `|| true` and the stderr drop are the additive-only contract AT THE CALL
  # SITE, not belt-and-braces: a tree that sources a SUBSET of src/ — which is
  # what most harnesses do — has no routing_receipt, and bash turns that into
  # rc=127 on a verb that had already succeeded. Measured on
  # tests/task_reject_trace_unit.sh before this line existed. The wrapper's own
  # containment cannot cover the case where the wrapper is what is missing.
  routing_receipt "$ident" "$maker" "now owns it (bounced back)" 2>/dev/null || true
}


# ── DIVE-3474 arm 1 — `task merge`: a verifier merges what IT graded ──────────
#
# THE DEFECT, measured on this board 2026-08-16: quinn graded DIVE-3457 and
# DIVE-3450 PASS — re-derived the maker's counts, drove her own mutants, confirmed
# every required check green at the graded head — and then filed, twice, "my token
# is read-only so I cannot do it. Please merge #658". agent-main pressed a button.
#
# NO JUDGEMENT IS ADDED BY THE SECOND SEAT. Nothing about the merge decision is
# re-derived there; the second seat holds a credential, not an opinion. It is a
# token-permission artifact wearing the shape of an approval, and every one of
# those asks wakes a NON-FRESH window (main), which is the most expensive event
# this fleet has. Removing an ILLEGITIMATE ask is autonomy, not unsupervised
# action — lodar's 2026-08-03 test on the strict reading.
#
# WHAT THIS IS NOT: a merge grant. The standing is the row, not the seat. It is
# keyed on `graded_by = <this seat>` over the SAME predicate the board already
# uses to paint "graded->merge" (`_TASKS_TFV_SQL`), so a verifier can merge
# exactly the pull request it has itself passed and NOTHING else — not a peer's
# row, not a row it merely assigned, not one whose grade a later reject retired.
#
# WHY `_TASKS_TFV_SQL` AND NOT A FRESH PREDICATE. That constant is the single
# source for the graded-awaiting-merge rule and carries four conjuncts this rail
# would otherwise have to re-type: writer!=grader (DIVE-477), a live reject
# retires a grade (DIVE-3428), a grade is not a pass (DIVE-3430), and a verdict
# with no delivery_ref has nothing to merge. Re-typing it is how the board and
# the rail drift, and a drift HERE is a merge nobody authorised. Same rule the
# constant's own comment states: written once, interpolated, never retyped.
#
# THE SUDO POSTURE IS `_task_answer`'s (DIVE-3160), deliberately, because the
# shape is identical: the grant confers NO authority of its own — it refuses
# unless the row already names this seat as the grader — so gating it behind a
# capability flag would recreate the exact split between standing and capability
# that both tickets exist to close. Hence UNCONDITIONAL in render_standard_sudoers,
# alongside `_task_answer` and not alongside `_push_do`.
#
#   1. EUID 0 or refuse — reachable only through the exact-path NOPASSWD grant.
#   2. WHO comes from SUDO_UID under sudo's env_reset, never argv, never --from.
#   3. STANDING re-derived AS ROOT FROM THE ROW. The caller passes an ident and
#      nothing else; the PR URL comes from `delivery_ref` in the store, never from
#      the caller, so a caller cannot name a pull request the row does not.
#   4. The merge goes out as the machine account (`_GH_BOT_ENV`), the same
#      credential and the same attribution rule as every other agent write
#      (DIVE-2232/2448).
#
# _task_merge_standing_sql <actor> — the WHERE that decides this rail, as one
# string, so the verb and the root executor grade the identical rule. PURE: no
# I/O, no root, unit-testable without a box.
_task_merge_standing_sql() {
  printf '%s' "${_TASKS_TFV_SQL} AND graded_by = $(sqlq "${1:-}")"
}

# cmd_task_merge — the caller half. Resolves nothing security-relevant itself:
# every check below is re-run authoritatively inside the root executor, and these
# exist only so a refusal arrives with its reason instead of as a sudo exit code.
cmd_task_merge() {
  local ident="" json=0 a
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      -h|--help)
        printf 'usage: 5dive task merge <ident> [--json]\n\n  Merge the pull request bound to a row THIS SEAT graded PASS.\n  Refused on any row this seat did not itself grade (DIVE-3474).\n'
        return 0 ;;
      --*) fail "$E_VALIDATION" "task merge: unknown flag '$a' — usage: 5dive task merge <ident> [--json]" ;;
      *) [[ -z "$ident" ]] && ident="$a" ;;
    esac
  done
  [[ -n "$ident" ]] || fail "$E_VALIDATION" "task merge needs a task ident — usage: 5dive task merge <ident>"
  (( json )) && JSON_MODE=1
  tasks_db_init

  local actor; task_actor_claim ""; actor="$ACTOR_BOARD"
  _task_merge_preflight "$ident" "$actor"   # names the refusal; never authorises

  local rc=0 out=""
  out=$(printf '%s\0' "$ident" | sudo -n /usr/local/bin/5dive _merge_do 2>&1) || rc=$?
  if (( rc != 0 )) && ! sudo -n -l /usr/local/bin/5dive _merge_do >/dev/null 2>&1; then
    fail "$E_PERMISSION" "$ident: this seat holds no _merge_do grant, so NOTHING RAN — the merge was not attempted and was not refused on standing. A seat provisioned before DIVE-3474 does not carry the grant until it is re-provisioned (5dive agent provision <seat>). Until then the merge stays with a seat that holds one."
  fi
  [[ -n "$out" ]] && printf '%s\n' "$out" >&2
  (( rc == 0 )) || { mark_reported; return "$rc"; }
  ok "$ident merged — the pull request this seat graded PASS is on the target branch; no second seat was asked" \
     '{ident:$id, merged:true, actor:$ac}' --arg id "$ident" --arg ac "$actor"
}

# _task_merge_preflight <ident> <actor> — the caller-side refusal texts. Split out
# so the harness can grade each refusal by NAME rather than by exit code, and so
# the negative case (a row this seat did NOT grade) has a message a reader can act
# on instead of a bare permission error.
_task_merge_preflight() {
  local ident="$1" actor="$2" row
  row=$(db "SELECT COALESCE(graded_by,'')||x'1f'||COALESCE(graded_verdict,'')||x'1f'||COALESCE(delivery_ref,'')||x'1f'||COALESCE(handoff_rejected_at,'')||x'1f'||COALESCE(graded_at,'')||x'1f'||status
            FROM tasks WHERE ident=$(sqlq "$ident") LIMIT 1;" 2>/dev/null || printf '')
  [[ -n "$row" ]] || fail "$E_VALIDATION" "no task ${ident}."
  local gb gv dr hr ga st rest
  gb="${row%%$'\x1f'*}";   rest="${row#*$'\x1f'}"
  gv="${rest%%$'\x1f'*}";  rest="${rest#*$'\x1f'}"
  dr="${rest%%$'\x1f'*}";  rest="${rest#*$'\x1f'}"
  hr="${rest%%$'\x1f'*}";  rest="${rest#*$'\x1f'}"
  ga="${rest%%$'\x1f'*}";  st="${rest#*$'\x1f'}"

  [[ -n "$ga" ]] \
    || fail "$E_CONFLICT" "${ident} carries NO grade (graded_at is NULL), so there is nothing for this rail to act on. This verb merges what a verifier has already passed; it is not a way to merge something first and grade it after. Grade it: 5dive task verify ${ident} --cmd=<acceptance test>"
  # THE NEGATIVE, asserted by name. Without this arm the grant is unbounded in the
  # one direction nobody would notice: a verifier merging a row someone ELSE graded
  # is indistinguishable, at the GitHub end, from a legitimate merge.
  [[ "$gb" == "$actor" ]] \
    || fail "$E_AUTH_REQUIRED" "${ident} was graded by '${gb:-<nobody>}', not by '${actor}' — REFUSED. This rail removes one ask only: the verifier asking a second seat to press the button on a pull request IT ITSELF passed. It is not a merge capability, so it does not extend to a row this seat did not grade. If '${gb:-the grader}' should merge it, that seat runs this verb; otherwise it stays a normal merge."
  [[ -n "$dr" ]] \
    || fail "$E_CONFLICT" "${ident} is graded but carries no delivery_ref, so no pull request is bound to it and there is nothing to merge. Bind it: 5dive task deliver ${ident} --pr=<url>."
  [[ -z "$gv" || "$gv" == "pass" ]] \
    || fail "$E_CONFLICT" "${ident}'s recorded verdict is '${gv}', not a pass (DIVE-3430) — a grade is not a pass, and this rail merges only what was passed."
  [[ -z "$hr" || ( -n "$ga" && ! "$hr" > "$ga" ) ]] \
    || fail "$E_CONFLICT" "${ident} was REJECTED at ${hr}, after the grade at ${ga} (DIVE-3428: a grade is not a latch) — the maker has not answered that bounce, so the graded head is not the head to merge."
  case "$st" in
    done|cancelled) fail "$E_CONFLICT" "${ident} is ${st} — a terminal row is not a merge queue." ;;
  esac
}

# cmd_task_merge_do — ROOT-ONLY (`_merge_do`). Re-derives everything: the caller
# from SUDO_UID, the standing from the row, and the pull request from the row's
# own delivery_ref. Accepts an IDENT and nothing else, so there is no argument
# through which a caller can name a different pull request or a different grader.
cmd_task_merge_do() {
  [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "_merge_do is a privileged internal primitive (reachable only through the exact-path NOPASSWD grant)."
  local -a args=(); local a
  while IFS= read -r -d '' a; do args+=("$a"); done
  (( ${#args[@]} == 1 )) || fail "$E_VALIDATION" "_merge_do takes exactly one task ident on stdin and no flags — got ${#args[@]} argument(s). The pull request is read from the row, never from the caller."
  local ident="${args[0]}"
  [[ "$ident" == --* ]] && fail "$E_VALIDATION" "_merge_do takes a task ident, not a flag ('${ident}')."

  local _ruid="${SUDO_UID:-}"
  [[ "$_ruid" =~ ^[0-9]+$ ]] \
    || fail "$E_AUTH_REQUIRED" "_merge_do: no SUDO_UID — reach this primitive through sudo from an agent seat, never as root directly (a root caller has no grading seat to attribute the merge to)."
  [[ "$_ruid" != "0" ]] \
    || fail "$E_AUTH_REQUIRED" "_merge_do: SUDO_UID is root, which is not an agent seat."
  local actor; actor=$(_gate_uid_to_agent "$_ruid")
  [[ -n "$actor" ]] \
    || fail "$E_AUTH_REQUIRED" "_merge_do: uid ${_ruid} owns no agent-* passwd row, so this merge has no attributable grader."

  tasks_db_init
  # STANDING + SUBJECT in ONE query over the shared predicate: a row that does not
  # match is refused, and the delivery_ref of a row that does match is the only
  # pull request this call can reach.
  local pr
  pr=$(db "SELECT delivery_ref FROM tasks WHERE ident=$(sqlq "$ident") AND $(_task_merge_standing_sql "$actor") LIMIT 1;" 2>/dev/null || printf '')
  [[ -n "$pr" ]] \
    || fail "$E_AUTH_REQUIRED" "_merge_do: ${actor} holds no merge standing on ${ident} — the row must be graded PASS BY ${actor}, still carry the delivery_ref that grade was recorded against, and not have been rejected since. Re-derived here as root from the row; the caller's view of it is not consulted. \`5dive task show ${ident}\` prints the fields this predicate reads."

  [[ -r "$_GH_BOT_ENV" ]] \
    || fail "$E_GENERIC" "machine-account credential missing ($_GH_BOT_ENV) — 5dive secret write ${_GH_BOT_KEY} --connector=github-bot"
  local tok
  # shellcheck disable=SC1090
  tok=$(set -a; . "$_GH_BOT_ENV"; set +a; printf '%s' "${GH_BOT_TOKEN:-}")
  [[ -n "$tok" ]] || fail "$E_GENERIC" "$_GH_BOT_ENV exists but carries no ${_GH_BOT_KEY}."

  local rc=0
  GH_TOKEN="$tok" GITHUB_TOKEN="" gh pr merge "$pr" --squash || rc=$?
  if (( rc != 0 )); then
    mark_reported
    printf '_merge_do: `gh pr merge %s --squash` exited %s as the machine account. That is GitHub'"'"'s answer, not a standing refusal — %s DOES hold merge standing on %s here. A required check that is red or still running, a protected branch the machine account cannot merge, and a conflict all land on this line; read gh'"'"'s message above.\n' \
      "$pr" "$rc" "$actor" "$ident" >&2
    return "$rc"
  fi
  # Audited as the GRADER's act, not root's: the whole point of the rail is that
  # the seat that graded is the seat that merged.
  _task_store_audit_log "task merge" "ok" 0 -- "task=$ident" "pr=$pr" "grader=$actor" "actor=$actor" 2>/dev/null || true
  printf '%s merged by %s (the seat that graded it) as the machine account.\n' "$pr" "$actor" >&2
  return 0
}
