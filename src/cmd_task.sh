
# -------- 5dive task — host-shared task queue --------

_task_usage() {
  cat <<USAGE
5dive task — shared task queue (sqlite at ${STATE_DIR}/tasks/tasks.db)

  5dive task init                                    # one-time root bootstrap of the store
  5dive task add <title...> [--body=<text>] [--priority=low|medium|high|urgent]
                            [--assignee=<agent|role:<r>|charter:<kw>>] [--parent=<id|DIVE-N>] [--from=<who>]
                                                     # --assignee token routes via the org chart (DIVE-980); omit = org lead/coordinator
                            [--recurring="<cron>"]  # recurring=template (5-field cron, e.g. "0 2 * * *")
                            [--accept=<criteria>] [--verify=<cmd>] [--max-iters=<n>] [--verifier=<agent>] [--no-verify]
                                                     # DIVE-969: non-trivial tasks are verifier-graded BY DEFAULT (a grader
                                                     # !=maker + derived acceptance criteria). --no-verify opts out (plain
                                                     # 'task done' closes). Trivial/low-priority chores skip it automatically
                                                     # — the skip is ANNOUNCED on the add line (DIVE-1880), and an explicit
                                                     # --verifier=<agent> forces the rail ON at ANY priority.
                            [--task-budget=<tokens|\$cost>]  # per-run spend cap for the on-host loop (DIVE-824)
                                                     # loop spec: declarative verify loop (DIVE-476). --verify is
                                                     # the default cmd for 'task verify'; --verifier grades (writer!=grader)
  5dive task ls [--status=<s>] [--assignee=<agent>] [--mine] [--all] [--recurring]
                                                     # default: open tasks, priority-ordered; --recurring: templates
                                                     # the scheduler is actually still driving (schedule set, status=todo);
                                                     # --recurring --all: every template regardless, incl. stopped ones
  5dive task show <id|DIVE-N>                        # full detail + subtasks + blockers
  5dive task assign <id|DIVE-N> <agent>
  5dive task verifier <id|DIVE-N> <agent> [--accept=<criteria>] [--max-iters=<n>]
                                                     # DIVE-1880: attach the maker→verifier rail to an ALREADY-FILED open
                                                     # task (grader must differ from the maker). The remedy when the
                                                     # DIVE-969 auto-skip declined the rail at filing time. On a task
                                                     # already DELIVERED to a verifier it re-points the review and moves
                                                     # the task to the new grader. No detach: opting out is add-time only.
  5dive task set-branch <id|DIVE-N> <branch>         # bind the task to a git branch for delegated push (DIVE-1462/1697);
                                                     # writes/updates a 'Branch: <name>' line in the body. Also: task add --branch=<name>
  5dive task set-body <id|DIVE-N> <text...> [--append]
                                                     # DIVE-1920: edit a task's body after creation (--body was add-time only).
                                                     # Default OVERWRITES the whole body; --append tacks text on instead (the
                                                     # common case — a finding/addendum after filing). Works on recurring
                                                     # templates too. Refused on a closed (done/cancelled) task.
  5dive task start  <id|DIVE-N>                      # -> in_progress
  5dive task done   <id|DIVE-N> [--result=<text>]    # -> done; --result captures the agent's response
  5dive task deliver <id|DIVE-N> --pr=<url> [--result=<text>]
                                                     # maker: record the delivery PR + hand to verifier; 'task done' stays
                                                     # BLOCKED until the work is MERGED to main (opt-in merge-gate, DIVE-1830).
                                                     # The gate honors EITHER binding: a delivery_ref (this PR url) OR an
                                                     # existing 'Branch: <name>' body line (delegated-push binding, DIVE-1462).
                                                     # DIVE-1935: a PR number the maker merely TYPES into --result/--body is a
                                                     # binding too, and merged-but-RED is refused as well as unmerged.
                                                     # DIVE-1955: every binding carries its REPO. --pr= url is preferred (it
                                                     # already does); for a 'Branch:' or a bare 'PR #N' add 'Repo: owner/repo'
                                                     # to the body. A bare #N with no declared repo binds only when exactly one
                                                     # known repo has a #N naming the ident — else it reports 'ambiguous'
                                                     # rather than guess, because #N means a different PR in each repo.
  5dive task merge-audit [--limit=N] [--json]         # DIVE-1935: retrospective sweep — DONE tasks whose own record names a PR
                                                     # that never merged (or merged red). Read-only; reports, never reopens.
                                                     # DIVE-1955: sweeps every repo in FIVE_GATE_REPOS (default: the CLI,
                                                     # 5dive-api and 5dive-frontend), not just the CLI one.
  5dive task verify <id|DIVE-N> [--cmd="<command>"] [--no-done] [--timeout=<s>]
                                                     # run a check; exit 0 => proven-done (flips to done,
                                                     # captures output tail). Verb exits 0/1 = the verdict.
                                                     # --cmd optional: falls back to the task's stored --verify command.
  5dive task reject <id|DIVE-N> [--feedback="<what to fix>"]
                                                     # verifier's FAIL verdict (DIVE-477): bounce back to the maker
                                                     # for another pass, or escalate to a human at max_iterations.
  5dive task loops [--stuck] [--all] [--escalate-stuck] [--runs] [--watch[=secs]] [--kill <loopId>]
                                                     # observability (DIVE-478/597): maker→verifier board + LOOP-7
                                                     # loop_runs control window (topology/stage/iter/tokens-ceiling/
                                                     # status/⚠stuck). --runs=only loop_runs; --watch repaints;
                                                     # --kill flips kill_requested (deferred-safe). Cost: 'usage loops'.
                                                     # Tokens/cost per loop: see '5dive usage' (same task ids).
  5dive task cancel <id|DIVE-N> [--result=<text>]    # -> cancelled; --result captures why
  5dive task done|cancel ... [--keep-worktree]       # DIVE-1967: a close RECLAIMS node_modules from that task's worktrees (gitignored,
                                                     # 'npm ci'-regenerable -> structurally data-loss-free). --keep-worktree opts out.
                                                     # The worktree DIRECTORY is never deleted — it may hold unpushed commits.
  5dive task reclaim <id|DIVE-N>|--all [--dry-run]   # reclaim node_modules from closed tasks' worktrees. --all sweeps every worktree whose
                                                     # task is done/cancelled/absent and SKIPS in_progress/blocked. Also REPORTS which
                                                     # worktree dirs look prunable (nothing unpushed) — pruning itself stays a human call.
  5dive task block   <id|DIVE-N> --by=<id|DIVE-N>    # add a blocks edge, mark blocked
                                                     # Attempt first — blocking is the exception you must justify. Every block MUST carry a revisit anchor:
                                                     #   --by=<id> (dependency, auto-clears on the blocker's done), OR route a timed hold via 'task park --reason --wake', OR a human 'task need'.
                                                     # A bare reasonless/dateless block is refused (DIVE-1357).
  5dive task unblock <id|DIVE-N> [--by=<id|DIVE-N>]  # drop edge(s); back to todo if clear
  5dive task rm <id|DIVE-N>                          # delete (cascades subtasks + edges)
  5dive task escalate <id|DIVE-N> [--from=<who>]     # flag for attention: bump priority a tier (cap urgent) + ping owning agent & paired human

  # Human Task Inbox — park a task on a human and clear it
  5dive task need <id|DIVE-N> --type=decision|secret|approval|manual|access --ask="..." [--options=A|B] [--recommend="A"] [--tier=0|1|2]
                                                     # --type=access: manager-clearable "grant me X" gate — routes to the org lead first (any tier), lead-clearable; add --probe='test -w /path' to self-check the block
  5dive task need <id|DIVE-N> --withdraw            # DIVE-1401: cancel a still-pending gate the team filed but that's now moot — filer or org lead, no human tap. NOT a grant (never records a secret/approval); genuine clears stay human-only.
    --ask: ONE crisp question + ~1 line essential context, recommendation up front. Heavy detail goes in the task BODY, not the ask.
    --discusses="<why>" (DIVE-2089, --type=decision ONLY): appeal a T2 floor that fired on SUBJECT MATTER. A design question that merely NAMES secrets/publishing/deletion performs none of them; declare that and the gate goes to your lead at tier 1 instead of the human. The declaration is recorded on the gate, shown to the reviewer, and audited — unlike rewording the ask, which reaches the same audience with no record of how. Refused, loudly, for money / customer comms / irreversible infra, for a pinned --tier=2, and when no lead sits above you.
    --needs=<capability> (DIVE-2241): DECLARE what this ask consumes. human_tap (a person's call: brand, strategy, irreversible), spend_authority (billing, paid accounts), secret_provision (a new token/credential) resolve to the paired human as CONSTANTS — the gate skips lead- AND verifier-routing and cannot be agent-cleared. Fixes: a gate on a verifier-loop task otherwise routes to whoever is GRADING the ticket, whatever it asks. Declared, never guessed from your wording; any other value is undeclared-equivalent and changes nothing (it never refuses).
    --recommend: your advised choice (strongly encouraged for decision/approval). Leads the alert as '✅ Recommended: <X>' and ⭐-marks its button. For a decision it must match one of --options.
    --tier (DIVE-891 risk tiers): 0 = auto-clear (rec applies NOW, no ping, digest line; requires --recommend)
             1 = agent-clearable; unanswered 48h -> the heartbeat applies the rec   2 = hard human gate (default for approval/secret/manual)
             Money, public comms, secrets and destructive asks are FLOORED to tier 2 no matter what you pass; secret is always tier 2.
                                                     # -> blocked, awaiting a human (decision/secret/approval/manual)
  5dive task park <id|DIVE-N> --reason="..." --wake=<YYYY-MM-DD[ HH:MM]|+Nd|+Nh>
                                                     # QUIET timed wait (no ping, not in the inbox); the heartbeat auto-unparks at --wake.
                                                     # --reason AND --wake are REQUIRED (DIVE-1357): a park with no revisit date is the block graveyard. Unknown date? pick a re-check (+7d). Waiting on a person? use 'task need'.
                                                     # back to todo when the time passes (heartbeat sweep, DIVE-891)
  5dive task unpark <id|DIVE-N>                      # clear a park early -> todo (unless task-deps still block it)
  5dive task inbox                                   # list ONLY human-gated tasks, priority-ordered
  5dive task inbox --send [--channel-proof=<chat>]   # DM the owner ONE tap-button digest of those gates (root-side; nonce never printed)
  5dive task coordinator [--json]                     # print the resolved org coordinator (DIVE-333/1568) — the one agent that fronts the pinned needs-you banner
  5dive task answer <id|DIVE-N> --value="..."        # record the human's answer, unblock, ping the owning agent
  5dive task clear-recs --channel-proof=<chat_id> [--only=<id|DIVE-N>]
                                                     # DIVE-1305: paired-human bulk-clear — apply each pending gate's --recommend as a HUMAN clear,
                                                     # driven by the human's own verified DM ("go with recs"). Clears only tier<2 (agent-clearable) gates;
                                                     # tier-2 hard gates (money/destructive/secret) are SKIPPED and keep their per-gate button tap.
                                                     # --only limits it to one named gate. Invoked by the telegram plugin, which supplies the verified chat_id.
                                                     # approval/secret gates are human-only: blocked for agent-* callers,
                                                     # and (DIVE-519) require --proof=<token from '5dive gate-proof'> once
                                                     # '5dive gate-proof enforce on' is set. Trusted paths attach it automatically.

  status: todo | in_progress | blocked | done | cancelled

  Maker→verifier loop (DIVE-477): give a task a --verifier (≠ its assignee) and the
  maker's 'task done' does NOT close it — it hands off to the verifier (re-queued as
  their todo; the heartbeat wakes them). The verifier grades against acceptance_criteria
  / runs 'task verify', then closes it ('task done', which closes for real since
  verifier==assignee) on PASS or 'task reject --feedback=' on FAIL (bounce back to the
  maker, or escalate to a human at max_iterations). Writer never grades itself:
  once delivered, a 'task done' from anyone but the verifier is REFUSED (DIVE-2007) —
  to amend a delivered result, send the correction to the verifier, don't re-run done.

  Any agent (group claude) can run these without sudo. Add --json for machine output.
USAGE
}

# -------- DIVE-1967: worktree reclaim on close --------
#
# Worktree-per-task with a full `npm install` per worktree and NO teardown at
# close filled this host to 100% of 75G (DIVE-1966). Teardown belongs at the
# close because that is the moment the artifact provably stops being needed.
#
# Only the SAFE half is automated: node_modules inside a worktree is gitignored,
# `npm ci`-regenerable output — no commit or branch can live there, so removing
# it is structurally data-loss-free. The worktree DIRECTORY may hold unpushed
# commits; `task reclaim` only ever REPORTS those, and never deletes one.

# _wt_num_of <path> — the task number a worktree basename encodes.
_wt_num_of() {
  local base="${1##*/}"
  [[ "$base" =~ (^|[-_])(wt|dive)[-_]?(dive)?([0-9]+) ]] && printf '%s' "${BASH_REMATCH[4]}"
  return 0
}

# _task_reclaim_on_close <ident> <keep:0|1>
_task_reclaim_on_close() {
  local ident="$1" keep="${2:-0}"
  (( keep )) && return 0
  [[ "${FIVEDIVE_NO_WT_RECLAIM:-0}" == "1" ]] && return 0
  local num; num=$(wt_task_num "$ident")
  [[ -n "$num" ]] || return 0
  local wt r a b c kb=0 removed=0 failed=0 seen=0
  while IFS= read -r wt; do
    [[ -n "$wt" ]] || continue
    seen=$((seen + 1))
    r=$(wt_reclaim_node_modules "$wt") || continue
    read -r a b c <<<"$r"
    kb=$((kb + ${a:-0})); removed=$((removed + ${b:-0})); failed=$((failed + ${c:-0}))
  done < <(wt_candidates "$num" 2>/dev/null)
  (( seen )) || return 0
  (( removed )) && step "reclaimed $(disk_gb "$kb")G of node_modules ($removed tree(s)) from $seen worktree(s) for $ident"
  # A worktree owned by a DIFFERENT agent (mode 0755) fails the rm. Say so — a
  # silent skip would read as "there was nothing to reclaim", which is the
  # empty-output-is-not-an-empty-answer defect (DIVE-1869), just in a disk sweep.
  (( failed )) && step "warn: $failed node_modules tree(s) for $ident not removable as $(id -un) — run: sudo 5dive task reclaim $ident"
  # DIVE-2054: task-store state (a reclaim stat for THIS task's worktrees) — fenced.
  _task_store_audit_log "task reclaim" ok 0 -- "$ident" "worktrees=$seen" "kb=$kb" "removed=$removed" "failed=$failed"
  return 0
}

cmd_task_reclaim() {
  tasks_db_init
  local dry=0 all=0 target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)     all=1 ;;
      --dry-run) dry=1 ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         target="$1" ;;
    esac
    shift
  done
  [[ -n "$target" || $all -eq 1 ]] || \
    fail "$E_USAGE" "usage: 5dive task reclaim <id|DIVE-N>|--all [--dry-run]"

  local -a wts=()
  local w
  if (( all )); then
    while IFS= read -r w; do [[ -n "$w" ]] && wts+=("$w"); done < <(wt_all)
  else
    resolve_task_id "$target"
    local num; num=$(wt_task_num "$RESOLVED_TASK_IDENT")
    while IFS= read -r w; do [[ -n "$w" ]] && wts+=("$w"); done < <(wt_candidates "$num")
  fi

  local rows='[]' total_kb=0 total_rm=0 total_fail=0 skipped=0
  local wt num st r a b c why
  for wt in ${wts[@]+"${wts[@]}"}; do
    num=$(_wt_num_of "$wt")
    # A worktree name carries a NUMBER, not an ident, and the ident counter is
    # per-project (DIVE-500, FROG-500 both exist as far as this name is
    # concerned). So match every project's task with that suffix and let ANY
    # live one veto the reclaim — an ambiguous name must resolve toward keeping.
    st=""
    [[ -n "$num" ]] && st=$(db "SELECT COALESCE(GROUP_CONCAT(status,','),'') FROM tasks WHERE ident LIKE '%-${num}';" 2>/dev/null || echo "")
    # NEVER touch a worktree whose task is still live. An in-flight agent losing
    # its node_modules mid-build is a real outage bought for a disk win we do
    # not need — the dead ones are more than enough.
    if [[ "$st" == *"in_progress"* || "$st" == *"blocked"* ]]; then
      skipped=$((skipped + 1))
      # NAME every skip, on the acting path and not only in --dry-run. A reclaim
      # that silently declines to act is indistinguishable from one that found
      # nothing to do, and the operator only learns the difference when the disk
      # fills again (Marcus, DIVE-1967 review).
      step "skip $wt — task DIVE-${num} is ${st} (live)"
      rows=$(jq -c --arg w "$wt" --arg s "$st" \
        '. + [{worktree:$w, task_status:$s, action:"skipped", reason:"task is live"}]' <<<"$rows")
      continue
    fi
    if (( dry )); then r=$(wt_reclaim_node_modules "$wt" dry); else r=$(wt_reclaim_node_modules "$wt"); fi
    read -r a b c <<<"$r"
    total_kb=$((total_kb + ${a:-0})); total_rm=$((total_rm + ${b:-0})); total_fail=$((total_fail + ${c:-0}))
    (( ${c:-0} )) && step "skip ${c} tree(s) in $wt — not writable as $(id -un)"
    # The DIRECTORY verdict is REPORTED, never acted on. wt_unpushed fails
    # closed: anything it cannot PROVE is pushed comes back with a reason.
    why=$(wt_unpushed "$wt")
    rows=$(jq -c --arg w "$wt" --arg s "${st:-absent}" --argjson kb "${a:-0}" \
      --argjson n "${b:-0}" --argjson f "${c:-0}" --arg why "$why" \
      '. + [{worktree:$w, task_status:$s, action:(if $n>0 then "reclaimed" else "nothing" end),
             kb:$kb, trees:$n, failed:$f,
             prunable:($why==""), prune_blocker:(if $why=="" then null else $why end)}]' <<<"$rows")
  done

  local verb="reclaimed"; (( dry )) && verb="would reclaim"
  ok "$verb $(disk_gb "$total_kb")G of node_modules ($total_rm tree(s)) across ${#wts[@]} worktree(s); $skipped skipped as live, $total_fail not writable" \
     '{dry_run:($d=="1"), worktrees:($w|tonumber), reclaimed_kb:($kb|tonumber), trees:($n|tonumber), skipped_live:($s|tonumber), not_writable:($f|tonumber), detail:$rows}' \
     --arg d "$dry" --arg w "${#wts[@]}" --arg kb "$total_kb" --arg n "$total_rm" \
     --arg s "$skipped" --arg f "$total_fail" --argjson rows "$rows"
}

cmd_task() {
  [[ $# -gt 0 ]] || { _task_usage; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    init)            cmd_task_init "$@" ;;
    add|new)         cmd_task_add "$@" ;;
    ls|list)         cmd_task_ls "$@" ;;
    show|view)       cmd_task_show "$@" ;;
    assign)          cmd_task_assign "$@" ;;
    set-branch)      cmd_task_set_branch "$@" ;;
    set-body)        cmd_task_set_body "$@" ;;
    start)           cmd_task_start "$@" ;;
    done|close)      cmd_task_done "$@" ;;
    deliver)         cmd_task_deliver "$@" ;;
    merge-audit)     cmd_task_merge_audit "$@" ;;   # DIVE-1935 retrospective sweep
    verify)          cmd_task_verify "$@" ;;
    verifier)        cmd_task_verifier "$@" ;;
    reject)          cmd_task_reject "$@" ;;
    loop)            cmd_task_loop "$@" ;;
    loops)           cmd_task_loops "$@" ;;
    cancel)          cmd_task_cancel "$@" ;;
    block)           cmd_task_block "$@" ;;
    unblock)         cmd_task_unblock "$@" ;;
    park)            cmd_task_park "$@" ;;
    unpark)          cmd_task_unpark "$@" ;;
    escalate)        cmd_task_escalate "$@" ;;
    need)            cmd_task_need "$@" ;;
    gate-escalate)   cmd_task_gate_escalate "$@" ;;   # DIVE-1927 internal, root-only
    inbox)           cmd_task_inbox "$@" ;;
    coordinator)     cmd_task_coordinator "$@" ;;
    answer)          cmd_task_answer "$@" ;;
    clear-recs)      cmd_task_clear_recs "$@" ;;
    precedent)       cmd_task_precedent "$@" ;;
    routing)         cmd_task_routing "$@" ;;
    reclaim)         cmd_task_reclaim "$@" ;;   # DIVE-1967 worktree node_modules reclaim
    rm|delete)       cmd_task_rm "$@" ;;
    -h|--help|help)  _task_usage ;;
    *) fail "$E_USAGE" "unknown task command: $sub (try: 5dive task --help)" ;;
  esac
}

# DIVE-1697: delegated push (5dive push, DIVE-1462) refuses unless the task body
# carries a 'Branch: <name>' line binding the cleared gate to a specific branch —
# but a body is only writable at `task add`, so a maker task filed WITHOUT one hit
# a wall (scoped-sudo makers can't sqlite the body). `set-branch` (and the sibling
# `task add --branch`) writes that line without an admin DB edit.

# _task_upsert_branch_line <body> <branch> — echo BODY with any existing
# 'Branch: <x>' line replaced by 'Branch: <branch>' (appended if none). Matches
# the case-insensitive, leading-whitespace-tolerant '^\s*branch:\s*\S+' parser in
# cmd_push.sh (_push_branch_from_body), so what we write is exactly what push reads.
_task_upsert_branch_line() {
  local body="$1" branch="$2" stripped
  # Drop any pre-existing Branch: line(s); `|| true` so a no-match grep can't trip
  # `set -e` inside this command substitution.
  stripped=$(printf '%s' "$body" | grep -ivP '^\s*branch:\s' || true)
  if [[ -n "$stripped" ]]; then
    printf '%s\nBranch: %s' "$stripped" "$branch"
  else
    printf 'Branch: %s' "$branch"
  fi
}

# `5dive task set-branch <id|DIVE-N> <branch>` — bind a task to the branch its
# cleared delegated-push gate authorizes. Idempotent: re-running replaces the line.
cmd_task_set_branch() {
  tasks_db_init
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) shift; positional+=("$@"); break ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -ge 2 ]] || fail "$E_USAGE" "usage: 5dive task set-branch <id|DIVE-N> <branch>"
  local branch="${positional[1]}"
  # No whitespace: push parses the branch as a single '\S+' token, so a space would
  # silently truncate the binding. Keep it to plausible git ref-name characters.
  [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
    || fail "$E_VALIDATION" "invalid branch name '$branch' (letters/digits/._/- only, no whitespace — push parses it as one token)"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local body newbody
  body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
  newbody=$(_task_upsert_branch_line "$body" "$branch")
  db "UPDATE tasks SET body=$(sqlq "$newbody") WHERE id=${id};"
  ok "$ident bound to branch '$branch' — delegated push (5dive push $ident) will accept this branch" \
     '{ident:$id, branch:$b}' --arg id "$ident" --arg b "$branch"
}

# `5dive task set-body <id|DIVE-N> <text...> [--append]` — DIVE-1920: the only
# route to edit a body after `task add` was a direct sqlite UPDATE, which
# scoped-sudo makers can't do and admins correctly decline to do unilaterally
# (a finding/addendum belongs in the ticket, not relayed over chat — that's the
# appending-is-not-compiling failure this exists to close). Default overwrites
# the whole body; --append tacks the text on with a blank-line separator so an
# addendum can't clobber someone else's existing context. Also works on
# recurring TEMPLATES (kind='recurring'), the DIVE-176 case. Refuses on a
# closed task — same "can't retro-edit a closed task" guard as `task verifier`.
# DIVE-1920 review (main): a body carries the spec/findings/reasoning a task is
# graded against, so a silently rewritable body is the same last-write-wins gap
# just flagged on need_asked_at — audit it like `task reject` does, naming the
# actor, overwrite-vs-append, and the PRIOR length so a destructive overwrite is
# distinguishable from an append after the fact. Not a permission check — the
# fleet is a trust domain and collaborative body edits are legitimate.
cmd_task_set_body() {
  tasks_db_init
  local append=0 task=""
  local -a words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --append)      append=1 ;;
      --)            shift; words+=("$@"); break ;;
      -*)            fail "$E_USAGE" "unknown flag: $1" ;;
      *)             if [[ -z "$task" ]]; then task="$1"; else words+=("$1"); fi ;;
    esac
    shift
  done
  local text="${words[*]:-}"
  [[ -n "$task" && -n "$text" ]] \
    || fail "$E_USAGE" "usage: 5dive task set-body <id|DIVE-N> <text...> [--append]"
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local st
  st=$(db "SELECT status FROM tasks WHERE id=${id};")
  [[ "$st" != "done" && "$st" != "cancelled" ]] \
    || fail "$E_VALIDATION" "$ident is already $st — its body is frozen (closed tasks don't get retro-edited; bounce it back first with: 5dive task reject $ident --feedback=\"…\")"
  local body; body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
  local prior_len=${#body}
  local newbody
  if (( append )); then
    if [[ -n "$body" ]]; then
      newbody="${body}"$'\n\n'"${text}"
    else
      newbody="$text"
    fi
  else
    newbody="$text"
  fi
  db "UPDATE tasks SET body=$(sqlq "$newbody") WHERE id=${id};"
  local mode="replaced"; (( append )) && mode="appended"
  _task_store_audit_log "task set-body" "ok" 0 -- \
    "task=$ident" "actor=$(task_actor)" "mode=$mode" "prior_len=$prior_len" || true
  ok "$ident body $mode" '{ident:$id, mode:$m}' --arg id "$ident" --arg m "$mode"
}

cmd_task_init() {
  require_root "task init"
  tasks_db_init
  ok "tasks store ready at $TASKS_DB" '{path:$p}' --arg p "$TASKS_DB"
}

# Resolve the task-queue coordinator (DIVE-333): the agent who owns unassigned
# tasks so they don't stall (the heartbeat only wakes an assignee). Org-agnostic,
# resolved live from the org chart — never a hardcoded agent:
#   1. an agent explicitly tagged `--role=coordinator` (reuses the existing org
#      role field; the disambiguator a multi-root org sets), when exactly one holds it
#   2. else the lone org root (the single-CEO case — zero config)
#   3. else empty — ambiguous (multi-root, none tagged) or empty org chart; we
#      leave the task unassigned exactly as before rather than guess wrong.
# Prints the coordinator name (or nothing). Safe on an empty/missing org table.
_task_resolve_coordinator() {
  if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE role='coordinator';")" == "1" ]]; then
    db "SELECT name FROM agents_org WHERE role='coordinator' LIMIT 1;"
    return
  fi
  if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org);")" == "1" ]]; then
    db "SELECT name FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org) LIMIT 1;"
  fi
}

# DIVE-969: verifier-by-default posture (Karpathy autonomy slider). Non-trivial
# work should get graded by someone other than the maker (writer!=grader,
# DIVE-474/477) UNLESS the creator explicitly opts out. These two helpers decide
# WHEN the default engages and WHO grades — deliberately conservative so trivial
# tasks stay frictionless and we never block an add.

# Is this task trivial enough to skip the verifier default? Trivial = low-signal
# work where a grading round-trip is pure overhead: low priority, OR a bodyless
# task whose title reads as a mechanical chore (typo/bump/rename/docs/lint/…).
# Anything with a real body or medium+ priority is treated as non-trivial.
#
# DIVE-1880: prints the REASON the rail is being skipped (empty = not trivial =
# the default engages). The reason exists so the skip can be ANNOUNCED at add
# time — a control that looks applied and is not is the defect this fixes.
_task_verify_skip_reason() {
  local _title="$1" _body="$2" _priority="$3"
  [[ "$_priority" == "low" ]] && { printf 'low priority'; return 0; }
  if [[ -z "$_body" ]]; then
    local t="${_title,,}"
    [[ "$t" =~ (^|[^a-z])(typo|typos|bump|rename|tweak|nit|nits|lint|format|reformat|comment|comments|whitespace|changelog|readme|docs|doc|wording|copy[[:space:]]fix|version[[:space:]]bump)([^a-z]|$) ]] \
      && { printf 'bodyless chore title'; return 0; }
  fi
  return 0
}

# Boolean form, kept for readability at the call site.
_task_is_trivial() {
  [[ -n "$(_task_verify_skip_reason "$1" "$2" "$3")" ]]
}

# Resolve the lone org root (the single top of the chart — reports_to NULL or a
# dangling manager). Prints the name, or nothing when the org is empty or has
# more than one root (ambiguous — never guess). Mirrors the coordinator's
# lone-root fallback but is exposed on its own so the grader chain can try it
# even in an org that DOES tag a distinct role='coordinator'.
_task_resolve_org_root() {
  [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org);")" == "1" ]] || return
  db "SELECT name FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org) LIMIT 1;"
}

# Resolve the org's designated technical deputy — the lone agent whose role or
# title marks them as a CTO / chief-technology / deputy — excluding $1 (the
# maker). This is the grader of last resort for the root/CEO's OWN work: when a
# task auto-coordinates to the lone-root coordinator, the maker IS the top of
# the chart with no manager above, so the chain would otherwise give up. The
# match is a leading-space-anchored keyword scan (so "CTO" matches but "factory"
# does not) and must be UNIQUE — >1 candidate is ambiguous and yields nothing.
_task_resolve_deputy() {
  local _skip="$1"
  local _pred="( lower(' '||COALESCE(role,'')||' '||COALESCE(title,'')) LIKE '% cto%'
                 OR lower(' '||COALESCE(role,'')||' '||COALESCE(title,'')) LIKE '% chief technolog%'
                 OR lower(' '||COALESCE(role,'')||' '||COALESCE(title,'')) LIKE '% deputy%' )
               AND name <> $(sqlq "$_skip")"
  [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE ${_pred};")" == "1" ]] || return
  db "SELECT name FROM agents_org WHERE ${_pred} LIMIT 1;"
}

# Pick a grader distinct from the maker (assignee) — a maker can't grade itself
# (DIVE-474). DIVE-969 established the verifier-by-default posture; DIVE-989
# widens WHO can grade so the default no longer silently no-ops when a task
# auto-coordinates TO the coordinator (maker==coordinator — the common
# default-project case where the lone-root CEO owns all unassigned work). We
# walk an ordered chain of DISTINCT candidates and take the FIRST that exists
# and differs from the maker:
#   1. project lead   — the task's own project owner
#   2. coordinator    — the queue owner (role=coordinator, else the lone root)
#   3. maker's manager — reports_to: the maker's natural up-reviewer
#   4. org root        — the lone top of the chart
#   5. technical deputy — the org's designated CTO/deputy, so the root/CEO's own
#                         work still gets a distinct grader
# The silent no-op survives ONLY when none of these yields a distinct agent (a
# genuinely solo org, or nobody but the maker anywhere). Prints the grader name.
_task_default_verifier() {
  local _assignee="$1" _proj_lead="$2" c=""
  local -a cands=(
    "$_proj_lead"
    "$(_task_resolve_coordinator)"
    "$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$_assignee") LIMIT 1;")"
    "$(_task_resolve_org_root)"
    "$(_task_resolve_deputy "$_assignee")"
  )
  for c in "${cands[@]}"; do
    if [[ -n "$c" && "$c" != "$_assignee" ]]; then
      printf '%s' "$c"; return
    fi
  done
}

# DIVE-1145: ship-gating routing. Resolve WHO a builder's gate should route to
# for lead review before it ever pings the human. Enforces the org policy
# "builder decision gates go through the org lead (main), not straight to the
# human" using the org-chart primitives already present — never a hardcoded
# agent. Prints the reviewer name, or NOTHING when the filer IS a lead (or the
# org can't name a distinct one), in which case the gate falls through to the
# human path unchanged. Ordered, DISTINCT-from-filer candidate chain:
#   1. the filer's manager      — reports_to: their natural up-reviewer
#   2. the org coordinator/root — role=coordinator, else the lone chart root
# Excluding the filer is what makes re-escalation free: when the LEAD files (or
# re-files) the same gate, they resolve to no distinct reviewer, so it goes to
# the human — exactly "only escalate to the human when the lead re-escalates".
_gate_route_reviewer() {
  local _filer="$1" c=""
  [[ -n "$_filer" ]] || return
  local -a cands=(
    "$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$_filer") LIMIT 1;")"
    "$(_task_resolve_coordinator)"
  )
  for c in "${cands[@]}"; do
    if [[ -n "$c" && "$c" != "$_filer" ]]; then
      printf '%s' "$c"; return
    fi
  done
}

# DIVE-1401 (olivia review, iter 2): the TRUSTED caller identity for gate-withdraw
# AUTHORIZATION. This is deliberately NOT task_actor: --from is caller-asserted and
# SUDO_USER/SUDO_UID are plain env vars a NON-root process can forge with no real
# sudo (`SUDO_USER=agent-<filer> 5dive task need <id> --withdraw`). Trust rule:
#   - EUID==0 (real sudo / root): sudo set SUDO_* truthfully AND reaching EUID 0
#     required actually sudo-ing, so a non-root agent cannot forge in. Read the
#     agent id from SUDO_USER (auto_sender_from_sudo) and the human signal from a
#     non-agent SUDO_UID (_gate_sudo_uid_nonagent), mirroring cmd_task_answer.
#   - non-root: SUDO_* are UNTRUSTED (forgeable) — ignore them entirely and judge
#     by the real `id -un` unix login, which a process cannot spoof.
# Prints one of: "agent <name>" | "human" | "none". Never reads --from ($from stays
# ATTRIBUTION-only) nor $USER (also env-spoofable). The determined root-sudo residual
# (an agent that truly sudo's then forges) is shared with the whole gate system and
# out of scope here — same boundary cmd_task_answer draws. _gate_is_root is a seam so
# the unit harness can exercise BOTH branches with the REAL resolver (not stubbed).
_gate_is_root() { [[ $EUID -eq 0 ]]; }
_gate_withdraw_actor() {
  if _gate_is_root; then
    local a; a=$(auto_sender_from_sudo)
    [[ -n "$a" ]] && { printf 'agent %s' "$a"; return; }
    _gate_sudo_uid_nonagent && { printf 'human'; return; }
    printf 'none'; return
  fi
  local idun; idun=$(id -un 2>/dev/null || echo "")
  if [[ "$idun" == agent-* ]]; then printf 'agent %s' "${idun#agent-}"
  elif [[ -n "$idun" ]]; then printf 'human'
  else printf 'none'; fi
}

# DIVE-980: shared org-chart assignee resolution. Resolve an assignee TOKEN to a
# concrete agent via the org chart (agents_org). Prints the resolved name, or
# NOTHING when a role/charter token has no UNIQUE holder — callers decide whether
# that empty is a hard error (task add) or a fall-through (goal validate).
# Deterministic + explainable: a role/charter routes ONLY on an unambiguous
# single match; >1 holder or unknown -> empty (never guess which one).
#   @name / bare name  -> taken as-is (explicit override; never re-routed)
#   role:<r>           -> the lone agents_org holder whose role == <r> (ci)
#   charter:<kw>       -> the lone holder whose title (charter) contains <kw> (ci)
# Safe on an empty/missing org table (COUNT != 1 -> empty).
_org_resolve_assignee() {
  local v="${1#@}"
  case "$v" in
    role:*)
      local r="${v#role:}"
      [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE role IS NOT NULL AND lower(role)=lower($(sqlq "$r"));" 2>/dev/null)" == "1" ]] || { printf ''; return; }
      db "SELECT name FROM agents_org WHERE role IS NOT NULL AND lower(role)=lower($(sqlq "$r")) LIMIT 1;"
      ;;
    charter:*)
      local kw="${v#charter:}"
      [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE title IS NOT NULL AND lower(title) LIKE '%'||lower($(sqlq "$kw"))||'%';" 2>/dev/null)" == "1" ]] || { printf ''; return; }
      db "SELECT name FROM agents_org WHERE title IS NOT NULL AND lower(title) LIKE '%'||lower($(sqlq "$kw"))||'%' LIMIT 1;"
      ;;
    *)
      printf '%s' "$v"
      ;;
  esac
}

cmd_task_add() {
  tasks_db_init
  local body="" priority="medium" assignee="" parent="" from="" recurring="" fresh="" project="dive"
  local accept="" verify_cmd="" max_iters="" verifier="" task_budget="" no_verify="" branch=""
  local -a words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --body=*)      body="${1#*=}" ;;
      --priority=*)  priority="${1#*=}" ;;
      --assignee=*)  assignee="${1#*=}" ;;
      --parent=*)    parent="${1#*=}" ;;
      --project=*)   project="${1#*=}" ;;
      --from=*)      from="${1#*=}" ;;
      --recurring=*) recurring="${1#*=}" ;;
      --schedule=*)  recurring="${1#*=}" ;;
      --fresh)       fresh="1" ;;
      --no-fresh)    fresh="0" ;;
      # DIVE-476: loop-spec — declarative verify loop persisted on the row so the
      # (c) verify-runner reads its inputs off the task instead of re-passing them.
      --accept=*)    accept="${1#*=}" ;;
      --verify=*)    verify_cmd="${1#*=}" ;;
      --max-iters=*) max_iters="${1#*=}" ;;
      --verifier=*)  verifier="${1#*=}" ;;
      # DIVE-969: explicit opt-out of the verifier-by-default posture. A plain
      # `task done` closes the resulting task directly (no maker→grader handoff).
      --no-verify)   no_verify="1" ;;
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
  [[ -n "$title" ]] || fail "$E_USAGE" "usage: 5dive task add <title...> [--body=] [--priority=] [--assignee=] [--parent=] [--project=<key>] [--recurring=\"<cron>\"] [--task-budget=<tokens|\$cost>]"
  valid_task_priority "$priority" || fail "$E_VALIDATION" "bad priority '$priority' (low|medium|high|urgent)"
  # DIVE-476: --max-iters is the maker→verifier loop cap; must be a positive int.
  [[ -z "$max_iters" || "$max_iters" =~ ^[1-9][0-9]*$ ]] \
    || fail "$E_VALIDATION" "--max-iters must be a positive integer"
  # DIVE-824: --task-budget is EITHER a bare token count ("50000") OR a dollar
  # cost ("$1.50" / "$2"). Reject anything else so a malformed cap can't silently
  # store as a no-op. Stored verbatim; the loop runner interprets the form.
  [[ -z "$task_budget" || "$task_budget" =~ ^[1-9][0-9]*$ || "$task_budget" =~ ^\$[0-9]+(\.[0-9]+)?$ ]] \
    || fail "$E_VALIDATION" "--task-budget must be a token count (e.g. 50000) or a dollar cost (e.g. \$1.50)"
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
    resolve_task_id "$parent"; parent_sql="$RESOLVED_TASK_ID"
  fi
  # DIVE-980: an explicit --assignee may be a literal agent name OR an org-chart
  # TOKEN (role:<r> / charter:<kw> / @name). Route tokens through the org chart;
  # a literal name is trusted verbatim (explicit --assignee always wins). A token
  # with no UNIQUE holder is a hard, EXPLAINABLE error — never a silent misroute.
  if [[ -n "$assignee" ]]; then
    case "$assignee" in
      role:*|charter:*|@*)
        local _resolved; _resolved=$(_org_resolve_assignee "$assignee")
        [[ -n "$_resolved" ]] || fail "$E_NOT_FOUND" "--assignee='$assignee' has no unique holder in the org chart (see: 5dive org ls) — assign by explicit agent name, or place/disambiguate the role with 5dive org set"
        assignee="$_resolved"
        ;;
    esac
  fi
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
  local creator; creator=$(task_actor "$from")
  local id
  id=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, parent_id, project_key, kind, schedule, fresh,
                              acceptance_criteria, verify_command, max_iterations, verifier, task_budget, verify_unavailable)
           VALUES ($(sqlq "$title"), $(sqlq_or_null "$body"), $(sqlq "$priority"),
                   $(sqlq_or_null "$assignee"), $(sqlq "$creator"), ${parent_sql}, $(sqlq "$project"),
                   $(sqlq "$kind"), ${schedule_sql}, ${fresh_sql},
                   $(sqlq_or_null "$accept"), $(sqlq_or_null "$verify_cmd"), ${max_iters:-NULL}, $(sqlq_or_null "$verifier"), $(sqlq_or_null "$task_budget"), $([[ $verify_unavailable == 1 ]] && echo 1 || echo NULL));
           SELECT last_insert_rowid();")
  # Ident is stamped by the AFTER INSERT trigger from the project's counter, so
  # read it back rather than assuming the DIVE- prefix (DIVE-484).
  local ident; ident=$(db "SELECT ident FROM tasks WHERE id=${id};")
  if [[ "$kind" == "recurring" ]]; then
    ok "created recurring ${ident} (${recurring}, fresh=$([[ "$fresh_sql" == "1" ]] && echo on || echo off)) — $title" \
       '{id:($i|tonumber), ident:$id, project:$pr, title:$t, priority:$p, assignee:$a, created_by:$c, kind:"recurring", schedule:$s, fresh:($f=="1")}' \
       --arg i "$id" --arg id "$ident" --arg pr "$project" --arg t "$title" --arg p "$priority" --arg a "${assignee:-}" --arg c "$creator" --arg s "$recurring" --arg f "$fresh_sql"
  else
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
       '{id:($i|tonumber), ident:$id, project:$pr, title:$t, priority:$p, assignee:$a, created_by:$c, kind:"standard", autoCoordinated:($ac=="1"), verifyDefaulted:($vd=="1"), verifyUnavailable:($vu=="1"), verifySkipped:($vs!=""), verifySkipReason:$vs, verifier:$v}' \
       --arg i "$id" --arg id "$ident" --arg pr "$project" --arg t "$title" --arg p "$priority" --arg a "${assignee:-}" --arg c "$creator" --arg ac "$auto_coordinated" --arg vd "$verify_defaulted" --arg vu "$verify_unavailable" --arg vs "$verify_skipped" --arg v "${verifier:-}"
  fi
}

cmd_task_ls() {
  tasks_db_init
  local status="" assignee="" mine=0 all=0 from="" recurring=0 project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status=*)   status="${1#*=}" ;;
      --assignee=*) assignee="${1#*=}" ;;
      --project=*)  project="${1#*=}" ;;
      --mine)       mine=1 ;;
      --all)        all=1 ;;
      --recurring)  recurring=1 ;;
      --from=*)     from="${1#*=}" ;;
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
    # it as an "Unverified" badge. NB: no inline SQL `--` comments in this string —
    # dbfmt flattens newlines, so a `--` would comment out the rest of the query.
    rows=$(dbfmt -json "SELECT id, ident, title, status, priority, assignee, created_by, parent_id, created_at, done_at, body, result, need_type, ask, need_options, recommend, precedent_ref, precedent_kind, need_answer, need_answered_at, need_answered_by, tier, kind, schedule, last_fired_at, last_skipped_at, parked_at, park_reason, wake_at, project_key,
             CASE WHEN maker_agent IS NOT NULL AND assignee=verifier AND status NOT IN ('done','cancelled')
                  THEN CASE WHEN handoff_ack_at IS NOT NULL THEN 'reviewing' ELSE 'delivered' END
                  ELSE NULL END AS handoff_state,
             handoff_ack_at,
             CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL AND status NOT IN ('done','cancelled') THEN 1 ELSE 0 END AS gate_live,
             CASE WHEN verify_unavailable = 1 AND verifier IS NULL AND status NOT IN ('done','cancelled') THEN 1 ELSE 0 END AS verify_unavailable,
             CASE WHEN kind='recurring' THEN (SELECT i.ident FROM tasks i WHERE i.from_template_id=tasks.id AND i.status NOT IN ('done','cancelled') ORDER BY i.id LIMIT 1) ELSE NULL END AS blocked_by
           FROM tasks WHERE ${where} ${order};")
    [[ -n "$rows" ]] || rows="[]"
    # Feed rows via stdin, not --argjson: a big board (179+ tasks w/ bodies)
    # blows past MAX_ARG_STRLEN (128K per argv string) -> execve E2BIG
    # ("Argument list too long"). stdin has no such cap. (DIVE-222)
    printf '%s' "$rows" | jq -c '{ok:true, data:{tasks:.}}'
  elif (( recurring )); then
    # DIVE-2237: last_fired alone cannot distinguish SUPPRESSED from BROKEN.
    # last_skipped names the last tick the materializer found this template due
    # and declined (skip-if-open); blocked_by names the open instance doing the
    # blocking, so the fix is one `task done` away and the reader does not have
    # to go find it. blocked_by is derived live from the same predicate the
    # materializer dedups on, so this listing cannot tell a different story than
    # the scheduler (the DIVE-2055 rule for this table).
    dbfmt -box "SELECT ident, status, COALESCE(schedule,'-') AS schedule, COALESCE(assignee,'-') AS assignee, COALESCE(last_fired_at,'never') AS last_fired, COALESCE(last_skipped_at,'-') AS last_skipped, COALESCE((SELECT i.ident FROM tasks i WHERE i.from_template_id=tasks.id AND i.status NOT IN ('done','cancelled') ORDER BY i.id LIMIT 1),'-') AS blocked_by, title FROM tasks WHERE ${where} ${order};"
  else
    dbfmt -box "SELECT ident, status, priority, COALESCE(assignee,'-') AS assignee, title FROM tasks WHERE ${where} ${order};"
  fi
}

cmd_task_show() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task show <id|DIVE-N>"
  resolve_task_id "$1"; local id="$RESOLVED_TASK_ID"
  if (( JSON_MODE )); then
    local task subs deps
    task=$(dbfmt -json "SELECT * FROM tasks WHERE id=${id};")
    subs=$(dbfmt -json "SELECT id,ident,title,status FROM tasks WHERE parent_id=${id} ORDER BY id;")
    deps=$(dbfmt -json "SELECT t.id,t.ident,t.title,t.status FROM task_deps d JOIN tasks t ON t.id=d.blocked_by WHERE d.task_id=${id} ORDER BY t.id;")
    [[ -n "$subs" ]] || subs="[]"
    [[ -n "$deps" ]] || deps="[]"
    jq -cn --argjson t "$task" --argjson s "$subs" --argjson b "$deps" \
      '{ok:true, data:{task:($t[0]), subtasks:$s, blocked_by:$b}}'
  else
    dbfmt -line "SELECT ident, title, status, priority, assignee, created_by, parent_id, created_at, started_at, done_at, body, result FROM tasks WHERE id=${id};"
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
    # Human gate (only when set) — mirrors the conditional subtasks/blockers
    # blocks below so an ordinary task's `show` stays clean.
    local gate
    gate=$(db "SELECT 'type: '||need_type||
                      CASE WHEN tier IS NOT NULL THEN '  (tier '||tier||')' ELSE '' END||
                      CASE WHEN need_options IS NOT NULL THEN '  options: '||need_options ELSE '' END||
                      CASE WHEN recommend IS NOT NULL THEN x'0a'||'recommend: '||recommend ELSE '' END||
                      CASE WHEN precedent_ref IS NOT NULL
                           THEN x'0a'||'precedent: '||COALESCE((SELECT ident FROM tasks p WHERE p.id=tasks.precedent_ref),'#'||precedent_ref) ELSE '' END||x'0a'||
                      'ask:  '||COALESCE(ask,'')||
                      CASE WHEN need_answered_at IS NOT NULL
                           THEN x'0a'||'answer: '||CASE WHEN need_type='secret' THEN '(provided — loaded out-of-band)' ELSE COALESCE(need_answer,'') END||'  ('||need_answered_at||')'
                           ELSE x'0a'||'answer: — pending' END
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
}

cmd_task_assign() {
  tasks_db_init
  [[ $# -ge 2 ]] || fail "$E_USAGE" "usage: 5dive task assign <id|DIVE-N> <agent>"
  resolve_task_id "$1"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local who="$2"
  # Handing a task to a NEW owner resets its in_progress clock: SQLite evaluates
  # SET column refs against the pre-update row, so `assignee IS NOT <who>` is the
  # OLD assignee. Without this, an inherited in_progress task keeps the prior
  # owner's started_at, and the heartbeat stale-reaper (_hb_reap_stale) can
  # cancel it on the new owner's very first tick before they touch it.
  db "UPDATE tasks SET
        handoff_ack_at=CASE WHEN assignee IS NOT $(sqlq "$who") THEN NULL ELSE handoff_ack_at END,
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
    || fail "$E_VALIDATION" "$ident is already $st — a verifier can't retro-grade a closed task (bounce it back with: 5dive task reject $ident --feedback=\"…\")"
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
    || fail "$E_VALIDATION" "'$who' is $ident's own $( (( mid_handoff )) && echo maker || echo assignee) — a maker can't grade itself (reassign first, or pick a different grader)"
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
        verify_unavailable=NULL${move_sql}
      WHERE id=${id};"
  local msg="$ident is now verifier-graded → $who ('task done' hands off to grade instead of closing)"
  (( repoint )) && msg="$ident review re-pointed → $who (was with '$cur_vfier'; delivery re-stamped, maker '${maker:-?}' and iteration unchanged)"
  (( mid_handoff )) && (( ! repoint )) && msg="$ident is already with verifier $who for review — criteria updated, handoff untouched"
  ok "$msg" \
     '{id:($i|tonumber), ident:$id, verifier:$v, assignee:$a, acceptanceCriteria:$ac, midReview:($m=="1"), repointed:($r=="1")}' \
     --arg i "$id" --arg id "$ident" --arg v "$who" --arg a "$new_owner" --arg ac "$new_accept" --arg m "$mid_handoff" --arg r "$repoint"
}

# _gate_gh_token — resolve a usable gh auth token for the DIVE-1830 merge-gate's
# read-only PR-state queries. `task done` normally runs under sudo (EUID 0), which
# has no gh login of its own, and the acting agent may itself be non-gh-authed
# (e.g. agent-*); running gh in that caller env returns state=unknown and the gate
# false-BLOCKS a legitimately-merged close (DIVE-1834). Resolution order:
#   1. an explicit token already in the env (manual passthrough / CI),
#   2. the REAL sudo invoker's gh login (SUDO_USER, when not root itself),
#   3. our OWN gh login, when we happen to be running as an authed user directly,
#   4. the host's known gh-authed user `claude` (the same identity delegated push
#      runs its git transport as) — reachable password-free from root, and from any
#      caller holding passwordless sudo (DIVE-1935).
# Order 3-before-4 is deliberate and was swapped there by DIVE-1935: a caller's OWN
# credential must win over borrowing another account's. Keep the order here in sync
# with the code below — this comment is what the next person reads before touching
# gate auth.
# Fail-safe: empty output => the gate treats state as unknown => false-BLOCK on the
# DECLARED path, never a false-CLOSE; on the auto-detect path it is a named,
# audited UNVERIFIED close (DIVE-1935), never a silent one. The token is passed to
# gh as a GH_TOKEN environment prefix and never appears in argv.
# Only ever used for read-only `gh pr view`/`gh pr list`.
_gate_gh_token() {
  local t u
  t="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  [[ -n "$t" ]] && { printf '%s' "$t"; return 0; }
  u="${SUDO_USER:-}"
  if [[ -n "$u" && "$u" != "root" ]] && command -v sudo >/dev/null 2>&1; then
    t=$(sudo -n -u "$u" gh auth token 2>/dev/null || true)
    [[ -n "$t" ]] && { printf '%s' "$t"; return 0; }
  fi
  # Our own gh login, when we happen to be running as an authed user directly.
  # DIVE-1935: this MUST stay ahead of the `claude` fallback below — a caller's own
  # credential always wins over borrowing another account's.
  t=$(gh auth token 2>/dev/null || true)
  [[ -n "$t" ]] && { printf '%s' "$t"; return 0; }
  # DIVE-1935: the `claude` fallback was gated on `id -un == root`, so it only ran
  # for root/sudo callers. Every agent-* account closes tasks as ITSELF (plain
  # `5dive task done`, no sudo) and none of them are gh-authed — so resolution
  # returned EMPTY for the entire fleet, and the fail-OPEN auto-detect gate below
  # was inert on every close it was written to police. Agents hold passwordless
  # sudo on this host, so try `claude` for non-root callers too; `sudo -n` keeps it
  # a silent no-op (never a password prompt) where that isn't true.
  if command -v sudo >/dev/null 2>&1 && [[ "$(id -un 2>/dev/null)" != "claude" ]]; then
    t=$(sudo -n -u claude gh auth token 2>/dev/null || true)
    [[ -n "$t" ]] && { printf '%s' "$t"; return 0; }
  fi
  printf ''
}

# DIVE-1935: extract every PR REFERENCE a piece of prose names, one number per
# line (deduped, first-seen order). DIVE-1922 closed with an empty delivery_ref
# and no Branch: line, but its own done result said "PR #156" in prose — the
# detectable signal was sitting in the text the maker typed. Two forms only:
#   * a github pull URL   https://github.com/<owner>/<repo>/pull/<n>
#   * a bare hash ref     #<n>   (1-6 digits, not glued to alnum on either side)
#   * a hash ref WITH PR CONTEXT   "PR #156", "PRs 156", "pull request #156"
# A bare '#<n>' is deliberately NOT enough. The first cut of this took any
# '#<n>' and the retrospective sweep immediately showed why that is wrong: it read
# "arms-length payer #4" and a column number "#25" as PR references. Harmless for
# the gate as long as those resolve non-OPEN, but a bare-'#' match against a
# low-numbered OPEN PR would false-block an unrelated close, and it made the sweep
# mostly noise. Requiring the word PR (or a pull url) keeps the DIVE-1922 shape —
# its result said "Merged as PR #156" — and drops the prose collisions.
# A '#' with no digits (markdown heading) and a 7+ digit id both correctly miss.
# A CLOSED-but-unmerged PR named here is deliberately IGNORED, not refused — see
# the gate below; that is documented behaviour, not an oversight.
#
# POSIX ERE only, deliberately. The first cut used `grep -oP` for both patterns,
# which made the whole text-binding gate depend on a PCRE-enabled grep: with -P
# unavailable both greps fail, `|| true` swallows it, refs come back empty and the
# gate silently does nothing — the EXACT silent-empty shape this ticket exists to
# delete, left sitting in the parser after being fixed in the token resolver and
# in _gate_pr_state. Not live-broken on our hosts, which is precisely why it would
# have sat there. ERE has no lookahead, so the trailing boundary is enforced by
# CAPTURING any glued alnum run (`[0-9]+[A-Za-z0-9]*`) and then rejecting the
# candidate unless it is digits-only and at most 6 long. That is strictly TIGHTER
# than the PCRE version it replaces: `(?![0-9])` excluded only a following DIGIT, so
# "PR 12ab" resolved as PR 12 under PCRE and under the first ERE cut too. Marcus
# asked for glued-to-alnum as a pinned negative and it caught that on the first run.
# The named fixtures in tests/task_merge_gate_result_pr_unit.sh are the equivalence
# proof; the canary below only proves the parser RAN.
#
# DIVE-1955: refs are now emitted QUALIFIED, as `<slug>|<number>`, where <slug> is
# the owner/repo the reference itself carries (pull URL) and EMPTY for a bare
# "PR #N". A number alone does not identify a pull request — our product spans at
# least three repos and their numbering collides — so the repo has to travel with
# the ref instead of being supplied later by a constant. When the same number
# appears both as a URL and bare in one text, the qualified form wins and the bare
# duplicate is dropped: strictly more information about the same reference.
_gate_pr_refs_qualified_from_text() {
  local text="$1"
  {
    printf '%s' "$text" | grep -oE  'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+[A-Za-z0-9]*'   || true
    printf '%s' "$text" | grep -oiE '(^|[^A-Za-z0-9])(PRs?|pull request)[[:space:]]*#?[[:space:]]*[0-9]+[A-Za-z0-9]*' || true
  } | awk '
      {
        n = $0; sub(/^.*[^0-9]/, "", n)                       # trailing digit-run
        if (n !~ /^[0-9]{1,6}$/) next                          # glued alnum / 7+ digits
        if ($0 ~ /^https:\/\/github\.com\//) {
          split($0, p, "/"); slug = p[4] "/" p[5]
        } else slug = ""
        if (slug != "") { if (qseen[slug "|" n]++) next; qual[n] = 1 }
        else            { if (bseen[n]++) next }
        order[++c] = slug "|" n
      }
      END { for (i = 1; i <= c; i++) { split(order[i], f, "|");
              if (f[1] == "" && qual[f[2]]) continue          # URL form already emitted
              print order[i] } }'
}

# Back-compat shape: the bare NUMBERS only, first-seen order. Kept because the
# engine canary and the DIVE-1935 equivalence fixtures are written against it, and
# because the audit's grouping only ever needed the number.
_gate_pr_refs_from_text() {
  _gate_pr_refs_qualified_from_text "$1" | awk -F'|' '!seen[$2]++ { print $2 }'
}

# _gate_delivery_refs_from_text <text> — of the refs this prose names, which ones
# does it claim THIS TASK DELIVERED? Emits the qualified `<slug>|<n>` subset.
#
# DIVE-1965. The gate's subject used to be "a PR mentioned in the result/body", and
# that predicate cannot tell "I shipped this" from "I am writing about this". Review,
# triage, audit, hygiene and coordination closes cite other tasks' pull requests as a
# matter of course. While off-repo bare refs silently failed to resolve the confusion
# was COSMETIC — a cited PR produced a wrong marker sentence and nothing worse. Once a
# bare `#N` resolves in the repo it actually lives in (DIVE-1963), a cited OPEN PR
# lands on the REFUSAL path (`done-with-open-pr-in-result`), and every close that so
# much as mentions another task's open PR becomes unclosable without
# `--force-merge-gate`. That is a fleet-wide close blocker on exactly the task class
# that does the most cross-referencing, so this has to land FIRST.
#
# This is the THIRD state, after DIVE-1955's pair:
#   "I LOOKED AND COULD NOT TELL"  — a non-verdict about this task's delivery.
#   "THERE WAS NOTHING TO LOOK AT" — the close named no PR at all.
#   "I AM TALKING ABOUT SOMETHING I DID NOT SHIP" — a ref was named, and it is not
#                                    this task's to answer for. Not a non-verdict:
#                                    there is no question here, so no disclosure.
#
# Marcus's design steer, and the reason this is not just a looser mention-predicate:
# **delivery must come from a STRUCTURED, INTENTIONAL signal, never from "a number
# appeared in the text".** The strongest two live elsewhere and already win — a
# `delivery_ref` and a `Branch:` line both route to the DECLARED gate above and never
# reach this code. What is left for prose is a deliberate claim, so the DEFAULT here
# is CITED and delivery has to be asserted:
#
#   1. a `Delivered:` / `Delivery:` line — the structured escape, sibling of the
#      DIVE-1462 `Branch:` and DIVE-1955 `Repo:` lines. Everything it names is a
#      delivery, no phrasing heuristic involved.
#   2. a shipping verb ADJACENT to the reference: "merged as PR #6", "landed in
#      #13", "shipped as https://.../pull/99", "PR #6 was merged". Anchored with `$`
#      against the text immediately before the ref (and a narrow `is|was <verb>`
#      after it) so it is adjacency, not "the word merged occurs somewhere".
#
# The failure modes are deliberately asymmetric. Mis-reading a citation as a delivery
# re-creates the fleet-wide blocker this exists to prevent; mis-reading a delivery as
# a citation costs coverage on ONE narrow shape — a close with no `delivery_ref`, no
# `Branch:`, no open PR naming the ident (the mandatory auto-detect scan is
# untouched and still fires), whose prose names its own merged PR with no shipping
# verb anywhere near it. That slip is ANNOUNCED at the call site, with both escapes
# named, rather than being silent.
#
# Negations are rejected explicitly ("not merged yet — PR #6", "unmerged"), and the
# verb needs a left word boundary so "unmerged" does not read as "merged".
# Line-scoped: a cue on the previous line does not carry, which keeps the window
# rule stateable in one sentence. `tolower` for matching only — it preserves length,
# so offsets still index the ORIGINAL line and a URL's owner/repo keeps its case.
_gate_delivery_refs_from_text() {
  printf '%s' "$1" | awk '
    BEGIN {
      RE   = "(https://github\\.com/[a-z0-9._-]+/[a-z0-9._-]+/pull/[0-9]+[a-z0-9]*)|((^|[^a-z0-9])(prs?|pull request)[[:space:]]*#?[[:space:]]*[0-9]+[a-z0-9]*)"
      VERB = "(merged|shipped|landed|delivered|delivery|released|rolled)"
      PRE  = "(^|[^a-z0-9])" VERB "([[:space:]]+(as|in|via|by|to|into|is|was))?[^[:alnum:]]*$"
      NEG  = "(^|[^a-z0-9])(not|never|no|un)[- ]?" VERB "([[:space:]]+(as|in|via|by|to|into|is|was))?[^[:alnum:]]*$"
      OWN  = "(^|[^a-z0-9])(my|our)[[:space:]]*$"
      POST = "^[[:space:]]*(is|was|were|are)[[:space:]]+" VERB
    }
    # same normalisation as the extractor: trailing digit-run, glued alnum and
    # 7+ digit ids rejected, a URL carries its own owner/repo, a bare ref none.
    function refkey(m,   n, k, p) {
      n = m; sub(/^.*[^0-9]/, "", n)
      if (n !~ /^[0-9]{1,6}$/) return ""
      if (tolower(m) ~ /https:\/\/github\.com\//) {
        k = m; sub(/^.*https:\/\/github\.com\//, "", k)
        split(k, p, "/"); return p[1] "/" p[2] "|" n
      }
      return "|" n
    }
    {
      line = $0; low = tolower(line)
      dline = (low ~ /^[[:space:]]*(delivered|delivery|delivers|ships?|shipped)[[:space:]]*:/)
      pos = 1
      while (match(substr(low, pos), RE)) {
        st = pos + RSTART - 1; ln = RLENGTH
        key = refkey(substr(line, st, ln))
        if (key != "") {
          pre = tolower(substr(line, 1, st - 1)); post = tolower(substr(line, st + ln))
          if (dline || (pre ~ PRE && pre !~ NEG) || pre ~ OWN || post ~ POST)
            if (!seen[key]++) print key
        }
        pos = st + ln
      }
    }'
}

# _gate_text_names_a_ref <text> — did this close mention a pull request AT ALL?
#
# DIVE-1955 (review, Marcus): this is the difference between the two states the gate
# can be in when it does not produce a verdict, and they are NOT the same thing:
#
#   "I LOOKED AND COULD NOT TELL"   — a ref was named and could not be confirmed
#                                     (ambiguous, unresolvable, no token, a partial
#                                     scan, unreadable checks). This is a real
#                                     non-verdict and the record must say so.
#   "THERE WAS NOTHING TO LOOK AT"  — the close named no PR, no branch, no delivery.
#                                     Research, comms, decisions, recaps. `unverified`
#                                     is simply the wrong word: nothing was pending
#                                     verification.
#
# Stamping the second case puts a scary merge-gate warning on the majority of closes
# in the fleet within a day, and a marker on every row is a marker nobody reads —
# destroying the exact property the marker was added to buy. Same failure as the
# merged-red one: a signal that cries wolf is worth less than no signal.
# Kept as an explicit named branch rather than implied by a missing condition,
# because the next reader will otherwise collapse the two back together.
#
# Deliberately NOT built on `_gate_pr_refs_from_text`: one caller is the case where
# that parser cannot run at all, so this uses bash's own `[[ =~ ]]` and a substring
# test — no grep, no subprocess — and stays a genuinely independent mechanism.
# Broader than the extractor on purpose: it answers "was a PR mentioned", not "which
# PR", so an over-match here only risks an honest UNVERIFIED note, never a verdict.
_gate_text_names_a_ref() {
  local t="$1"
  [[ "$t" == *"/pull/"* ]] && return 0
  [[ "$t" =~ (^|[^A-Za-z0-9])([Pp][Rr][Ss]?|[Pp][Uu][Ll][Ll][[:space:]]+[Rr][Ee][Qq][Uu][Ee][Ss][Tt])[[:space:]]*#?[[:space:]]*[0-9] ]] && return 0
  return 1
}

# DIVE-1955: the repos the merge-gate knows about, one slug per line, CLI first.
# `_PUSH_DEFAULT_REPO` used to be the whole world: every bare `#N` resolved against
# 5dive-ai/5dive, so lodar/5dive-api (== prod) and lodar/5dive-frontend had ZERO
# coverage AND — worse — an api task naming "PR #6" got a CONFIDENT verdict about an
# unrelated CLI pull request. Overridable so a new repo is config, not a patch, and
# so the tests can point the whole gate at fixtures.
_gate_repo_slugs() {
  local raw="${FIVE_GATE_REPOS:-}"
  if [[ -z "$raw" ]]; then
    raw="$(_push_repo_slug "$_PUSH_DEFAULT_REPO") lodar/5dive-api lodar/5dive-frontend"
  fi
  printf '%s' "$raw" | tr ',' ' ' | tr -s '[:space:]' '\n' | awk 'NF && !seen[$0]++'
}

# _gate_slug_from_url <text> — OWNER/REPO out of the first github URL in <text>, or
# empty. Accepts a pull URL, a repo URL and an ssh remote.
_gate_slug_from_url() {
  printf '%s' "$1" \
    | grep -oE '(https://github\.com/|git@github\.com:)[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' \
    | head -1 | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' || true
}

# _gate_task_repo_slug <delivery_ref> <body> — the repo THIS TASK DECLARED, or empty.
# Precedence: the delivery_ref URL (a delivered PR carries its own repo, which is why
# ask 1 says prefer it) > an explicit `Repo: owner/repo` body line, the sibling of the
# DIVE-1462 `Branch:` line. Empty means unknown, and unknown must stay unknown — it is
# never quietly filled in with a default.
#
# DIVE-1963: there was a THIRD fallback — any github URL sitting anywhere in the body —
# and it read a URL that happened to be MENTIONED as a declaration of where this task's
# work lives. DIVE-1955's own close is the specimen: its body QUOTES the constant it is
# about (`_PUSH_DEFAULT_REPO="https://github.com/5dive-ai/5dive.git"`), so the gate
# bound every bare `#N` to the CLI repo and never looked in api or frontend at all. The
# ticket describing an implicit repo standing in for a missing one triggered a narrower
# version of itself, sourced from prose instead of from a constant.
#
# Deleting it CANNOT lose coverage, which is why this is a deletion and not a widening:
# with no declared repo a bare `#N` goes through the DIVE-1955 existence-count sweep,
# which searches EVERY known repo — strictly a superset of the single repo the
# inference picked. What it does delete is the sharper half. "The inferred repo misses"
# is only one of the two cases; when the inferred repo HAS a `#N`, the old path handed
# back a confident verdict about a pull request nobody claimed, which is the
# "wrong, not blind" failure DIVE-1955 exists to remove. So the fix is NOT "sweep when
# the inference misses" — that leaves the dangerous half untouched. Same rule DIVE-1965
# settled one layer up: a binding comes from a STRUCTURED, INTENTIONAL signal, never
# from "a URL appeared in the text". Prose is evidence of discussion, not declaration.
#
# The superset is over the CONFIGURED repo set, not over all of GitHub (Marcus, review):
# `_gate_repo_slugs` is the world, and it is `FIVE_GATE_REPOS` when that is exported.
# Unset — the default on every box — it is the three real repos, which is what makes the
# claim hold in practice, and tests/task_merge_gate_inferred_repo_unit.sh pins that
# default with the env cleared rather than leaving it asserted in prose. A box that
# exports a NARROWER list narrows the sweep too, and there the deleted inference could
# have named a repo outside the configured world — but a binding that reaches outside
# the set the operator configured is its own defect, not coverage worth keeping.
_gate_task_repo_slug() {
  local dref="$1" body="$2" s=""
  if [[ -n "$dref" ]]; then
    s=$(_gate_slug_from_url "$dref"); [[ -n "$s" ]] && { printf '%s' "$s"; return 0; }
  fi
  local line
  line=$(printf '%s\n' "$body" | grep -ioE '^[[:space:]]*repo:[[:space:]]*\S+' | head -1 || true)
  if [[ -n "$line" ]]; then
    line="${line#*:}"; line="${line#"${line%%[![:space:]]*}"}"
    s=$(_gate_slug_from_url "$line")
    [[ -z "$s" && "$line" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && s="${line%.git}"
    [[ -n "$s" ]] && { printf '%s' "$s"; return 0; }
  fi
  return 0
}

# _gate_bind_slug <qualified-ref> <task_slug> — the ONE repo a ref binds to, or EMPTY
# for "nothing binds it, sweep every known repo". Precedence: the repo the ref carries
# itself (a pull URL) > the repo the TASK declared > unbound.
#
# DIVE-1963 (Marcus, review): the resolver and the message reporting its scope used to
# derive this INDEPENDENTLY, and the original comment claimed they "cannot drift". They
# agreed, but that is parallel derivation — two copies that happen to match today, which
# buys "does not currently drift". Cannot-drift is what a shared definition buys, so
# here it is: one function, two callers, and the sentence the reader gets is computed
# from the same answer the lookup used. Same shape as the DIVE-1932 lesson — a rule that
# holds because of the shape of the code, rather than because something declares it, is
# preserved by nothing.
_gate_bind_slug() {
  local rslug="${1%%|*}"
  [[ -z "$rslug" && -n "$2" ]] && rslug="$2"
  printf '%s' "$rslug"
}

# _gate_search_scope <qualified-ref> <task_slug> — the repo(s) a ref is ACTUALLY looked
# up in, comma-joined. DIVE-1963: the unresolvable warning said "in any known repo"
# after searching exactly ONE, so the message asserted a sweep that never happened, and
# a warning that misstates its own scope is the defect class this arc exists to delete.
_gate_search_scope() {
  local rslug; rslug=$(_gate_bind_slug "$1" "$2")
  if [[ -n "$rslug" ]]; then printf '%s' "$rslug"
  else _gate_repo_slugs | paste -sd, -; fi
}

# _gate_pr_probe <n> <tok> <slug> <ident> — one bounded read-only lookup of PR #n in
# <slug>, as `STATE|mergedAt|CHECKS|IDENTMATCH`, empty when the PR does not exist
# there. IDENTMATCH is 1 when the PR's title or head branch names <ident> at word
# boundaries — the EVIDENCE that this number, in this repo, belongs to this task.
# That evidence is what lets a bare "#N" bind at all without guessing a repo.
_gate_pr_probe() {
  local n="$1" tok="$2" slug="$3" ident="$4"
  GH_TOKEN="$tok" timeout 10s gh pr view "$n" --repo "$slug" \
      --json state,mergedAt,statusCheckRollup,title,headRefName \
      -q "[ .state,
            (.mergedAt // \"null\"),
            $_GATE_ROLLUP_JQ,
            ( if ((.title // \"\") | test(\"(^|[^A-Za-z0-9])${ident}([^A-Za-z0-9]|\$)\";\"i\"))
                 or ((.headRefName // \"\") | test(\"(^|[^A-Za-z0-9])${ident}([^A-Za-z0-9]|\$)\";\"i\"))
              then \"1\" else \"0\" end ) ] | join(\"|\")" \
      2>/dev/null || true
}

# _gate_resolve_qualified <slug|number> <tok> <ident> <task_slug> — resolve ONE
# qualified ref to `<slug>|STATE|mergedAt|CHECKS`, or `AMBIGUOUS|<slug,slug,…>`, or
# EMPTY for "exists nowhere we know / could not resolve".
#
# THIS IS THE ANTI-FABRICATION RULE (DIVE-1955 ask 2). Three cases:
#   * the ref carries its own repo (pull URL)  -> resolve there, done.
#   * the ref is bare and the TASK declared a repo -> resolve there, done.
#   * the ref is bare and the task's repo is UNKNOWN -> do NOT pick a default. Probe
#     every known repo and count the ones that actually HAVE a #N:
#       0 -> unresolvable (empty), same loud note as before.
#       1 -> that repo. There is nothing to disambiguate: the number identifies
#            exactly one pull request in the world we know about. This is the common
#            case and it is why the DIVE-1935 coverage does not regress.
#       2+ -> a REAL collision. Break it only on evidence: if exactly one of them
#            NAMES the ident in its title or head branch, that one binds. Otherwise
#            AMBIGUOUS — any single verdict would be invented.
# Ambiguous is a LOUD non-answer, never a block and never a pass — a fabricated
# verdict can refuse a legitimate close or bless a bad one, which is strictly worse
# than admitting we do not know which pull request the maker meant.
_gate_resolve_qualified() {
  local qref="$1" tok="$2" ident="$3" task_slug="$4"
  local n="${qref#*|}" rslug
  # DIVE-1963: shared with `_gate_search_scope`, so the repo we look in and the repo the
  # warning NAMES are one answer, not two derivations that agree.
  rslug=$(_gate_bind_slug "$qref" "$task_slug")
  if [[ -n "$rslug" ]]; then
    local st; st=$(_gate_pr_state "$n" "$tok" "$rslug")
    [[ -n "$st" ]] && printf '%s|%s' "$rslug" "$st"
    return 0
  fi
  local s p exists="" exists_n=0 only="" only_st="" named="" named_st="" named_n=0
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    p=$(_gate_pr_probe "$n" "$tok" "$s" "$ident")
    [[ -n "$p" ]] || continue
    exists="${exists:+$exists,}$s"; exists_n=$((exists_n+1)); only="$s"; only_st="${p%|*}"
    if [[ "${p##*|}" == "1" ]]; then named_n=$((named_n+1)); named="$s"; named_st="${p%|*}"; fi
  done < <(_gate_repo_slugs)
  [[ $exists_n -eq 0 ]] && return 0
  [[ $exists_n -eq 1 ]] && { printf '%s|%s' "$only" "$only_st"; return 0; }
  [[ $named_n -eq 1 ]] && { printf '%s|%s' "$named" "$named_st"; return 0; }
  printf 'AMBIGUOUS|%s' "$exists"
  return 0
}

# _gate_pr_refs_engine_ok — positive control for the extractor above. "No refs
# found" must be provably different from "the parser cannot run": a canary with a
# known answer is checked before an empty result is trusted. Cheap (no subprocess
# beyond the extractor itself) and it converts an unrunnable grep from a silent
# fail-open into a named, audited unverified close.
_gate_pr_refs_engine_ok() {
  [[ "$(_gate_pr_refs_from_text 'ship PR #4242 via https://github.com/o/r/pull/99')" == "99
4242" ]]
}

# DIVE-1955 (review, Marcus): the check verdict is the LATEST RUN PER CHECK NAME, not
# "any FAILURE anywhere in the rollup". `statusCheckRollup` carries every run on the
# head commit, so a check that failed and was then re-run green still contributes its
# old FAILURE — and the gate called the PR red. Proven on lodar/5dive-api#13: smoke-gate
# FAILED 11:49:41, SUCCEEDED 12:41:15, merged 12:42:06. It went green and then merged;
# reporting it as a merged-red escape is a FALSE POSITIVE. A merged-red table that cries
# wolf gets ignored, at which point it is worth less than no table at all.
# Group by name (CheckRun) or context (StatusContext), sort each group by its own
# timestamp, keep the last, and judge only those. Runs with no timestamp sort first, so
# a timestamp-less duplicate can never outrank a real completion.
readonly _GATE_ROLLUP_JQ='
  ( [ (.statusCheckRollup // [])[]?
      | { n: (.name // .context // ""),
          c: (.conclusion // .state // ""),
          t: (.completedAt // .startedAt // .createdAt // "") } ]
    | group_by(.n) | map(sort_by(.t) | last | .c)
    | if   any(. == "FAILURE" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED" or . == "ERROR")
      then "FAILURE" elif length == 0 then "NONE" else "OK" end )'

# DIVE-1935: resolve ONE pr ref (number or url) to `STATE|mergedAt|CHECKS` where
# CHECKS is FAILURE (at least one failed/cancelled/timed-out/action-required run),
# NONE (no checks reported) or OK. Empty output means COULD NOT RESOLVE — no
# token, no network, gh absent, or the ref isn't a PR at all. Callers MUST treat
# empty as "unverified" and say so out loud rather than as "fine": a resolver that
# silently yields nothing is the exact failure this ticket exists to delete.
# Read-only (`gh pr view`), bounded by `timeout`.
_gate_pr_state() {
  local ref="$1" tok="$2" slug="$3"
  local -a repo_arg=()
  [[ "$ref" =~ ^[0-9]+$ ]] && repo_arg=(--repo "$slug")
  GH_TOKEN="$tok" timeout 10s gh pr view "$ref" "${repo_arg[@]}" \
      --json state,mergedAt,statusCheckRollup \
      -q "[ .state, (.mergedAt // \"null\"), $_GATE_ROLLUP_JQ ] | join(\"|\")" \
      2>/dev/null || true
}

# DIVE-2101: _gate_branch_ancestry <slug> <branch> <tok> — is <branch>'s tip an
# ANCESTOR of that repo's main? Prints "1" (yes: every commit on the branch is
# already on main), "0" (demonstrably not) or EMPTY when the question could not be
# REACHED — no token, no network, gh absent, repo/branch gone, unparseable answer.
#
# Empty is not "no", and the caller must never read it as one: it falls through to
# the merged-PR path exactly as if this check did not exist, so an outage can only
# ever cost the NEW acceptance, never manufacture a refusal that DIVE-1830 did not
# already make.
#
# Asked over the API rather than a local `git merge-base --is-ancestor` on purpose:
# `task done` runs from any cwd (and from root/cron), so there is no checkout to
# trust — the same reason the merged-PR probe next to it passes --repo explicitly
# (DIVE-1834). `compare/main...branch` answers the ancestry question directly:
# ahead_by is the count of commits the branch has that main does not, so ahead_by==0
# (status `identical` or `behind`) IS "the tip is an ancestor". Both are required
# together so a shape-changed payload reads as unresolved, not as a pass.
# Read-only, bounded by `timeout`, token passed via env and never in argv.
_gate_branch_ancestry() {
  local slug="$1" branch="$2" tok="$3" out st ahead
  out=$(GH_TOKEN="$tok" timeout 10s gh api \
        "repos/${slug}/compare/${FIVE_GATE_MAIN_BRANCH:-main}...${branch}" \
        -q '[(.status // ""), ((.ahead_by // "") | tostring)] | join("|")' 2>/dev/null || true)
  out="${out%%$'\n'*}"
  st="${out%%|*}"; ahead="${out##*|}"
  if [[ -z "$st" || "$out" != *"|"* ]]; then printf ''; return 0; fi
  if [[ "$ahead" == "0" && ( "$st" == "identical" || "$st" == "behind" ) ]]; then
    printf '1'; return 0
  fi
  printf '0'
}

# DIVE-2101 (main's vacuity arm, before merge): ancestry ALONE is trivially true
# for a branch with ZERO commits — its tip IS a commit on main — so a task bound to
# a branch nobody ever committed to would satisfy done=merged-to-main having
# delivered NOTHING. That is the mirror of the unmerged case: "commits that did not
# land" and "no commits at all" are different shapes, and only the first is covered
# by refusing a branch that is ahead of main. Ancestry answers "is this tip on
# main", never "did this task put anything there", and no amount of ancestry
# arithmetic separates them (merge-base(tip,main)==tip in BOTH).
#
# So ATTRIBUTION is asked separately: does any commit reachable from the branch tip
# name <ident> at word boundaries? Same evidence idiom `_gate_pr_probe` already uses
# to bind a bare #N (title/head-branch naming the ident) — here against commit
# messages, which is this repo's standing convention. Because the tip is already
# established as an ancestor of main, every commit it reaches IS on main, so a hit
# means "work for this task is on main" measured on the commits themselves.
# Deliberately NOT solved by recording a base SHA at `set-branch` time: that reads
# only for bindings made after it ships, and the live casualties (DIVE-2051, and
# this ticket's own binding) are already bound — an anti-vacuity arm that cannot
# see the vacuum it was written for is theatre.
#
# Prints "1" (attributable), "0" (nothing on the branch names the ident) or EMPTY
# when unreachable. Empty and "0" both DECLINE the ancestry acceptance and fall
# through to the merged-PR search — this arm can only ever subtract an acceptance,
# never add a refusal that DIVE-1830 did not already make. Read-only, bounded.
_gate_branch_ident_on_main() {
  # DIVE-2120: search MAIN, never the branch ref.
  #
  # The DIVE-2101 arms both queried the GitHub API BY BRANCH NAME
  # (compare/main...<branch>, commits?sha=<branch>). Measured: against a ref absent
  # from the remote both 404, so a MERGED-AND-DELETED branch returns byte-identical
  # results to one that NEVER EXISTED — and deleting the branch on merge is routine
  # hygiene we perform by default (four branches deleted the night DIVE-2101 shipped).
  # The task then became permanently un-closeable on this path, and the refusal told
  # the reader to "land the branch", which is wrong advice for work already on main.
  #
  # Searching main directly removes the dependency instead of repairing it, and it
  # makes the VACUITY case structurally impossible rather than separately guarded: an
  # empty branch contributes no commit naming the ident TO MAIN, so there is nothing
  # to mistake for delivery. It also works retroactively on every existing binding.
  #
  # Returns: 1 = a commit on main names the ident
  #          0 = genuine miss (main's history was EXHAUSTED within the bound)
  # bound:<walked> = not found, and the scan STOPPED AT ITS BOUND after walking
  #                  <walked> commits — inconclusive, not a miss. The number is the
  #                  count actually WALKED, never the configured one: reporting the
  #                  request as if it were the measurement is the whole bug below.
  #         "" = unreachable (no token, API down, timeout)
  local slug="$1" tok="$3" ident="$4" main_br n per page walked out hits count
  main_br="${FIVE_GATE_MAIN_BRANCH:-main}"
  n="${FIVE_GATE_ANCESTRY_SCAN:-50}"
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || n=50
  # SUBJECT LINE ONLY, not the whole message. Searching main widened the attribution
  # set: every commit reachable from a branch tip is on main, but not every commit on
  # main is reachable from that tip — so a whole-message match accepts INCIDENTAL
  # mentions. Measured while building this: DIVE-2112 matched inside a 2-commit bound
  # because the 0.16.20 RELEASE commit's body happens to name it. That commit delivered
  # nothing for DIVE-2112. Our delivery commits put the ident in the SUBJECT
  # ("task: ... (DIVE-2112)"); prose references live in the body. Matching the subject
  # keeps the branch-deletion immunity without paying for it in a looser bar.
  #
  # PAGINATED, and that is not an optimisation — it is the correctness fix.
  # The first cut asked for per_page=$n in ONE call and inferred "history EXHAUSTED"
  # from a short page. GitHub CLAMPS per_page at 100 (measured by olivia against the
  # live API: 50->50 rows, 100->100, 200->100, 500->100), so at any n>100 the page
  # came back short for a reason that has nothing to do with history running out: the
  # scan saw 100 of main's 1000+ commits and returned "genuine miss". That fell
  # through to the generic refusal telling the reader to LAND THE BRANCH — the exact
  # wrong advice this ticket exists to kill — and the bound refusal's only documented
  # remedy ("raise FIVE_GATE_ANCESTRY_SCAN") was the single input that triggered it.
  # The remedy was worse than the disease.
  #
  # So: never request more than the clamp, and walk pages until the ident is found,
  # history genuinely runs out, or n commits have actually been walked. The clamp was
  # the only known cause of a short page that is not exhaustion, and asking for at
  # most 100 removes it — a short page now means what the code says it means. This is
  # also what makes the refusal's advice TRUE: raising the bound past 100 now walks
  # further instead of silently converting an honest INCONCLUSIVE into a false miss.
  walked=0; page=1
  while (( walked < n )); do
    per=$(( n - walked )); (( per > 100 )) && per=100
    out=$(GH_TOKEN="$tok" timeout 10s gh api \
          "repos/${slug}/commits?sha=${main_br}&per_page=${per}&page=${page}" \
          -q "[ .[] | ((.commit.message // \"\") | split(\"\\n\")[0]) ] | [length, ([ .[]
               | select(test(\"(^|[^A-Za-z0-9])${ident}([^A-Za-z0-9]|\$)\";\"i\")) ] | length)] | @tsv" \
          2>/dev/null || true)
    out="${out%%$'\n'*}"
    count="${out%%$'\t'*}"; hits="${out##*$'\t'}"
    [[ "$count" =~ ^[0-9]+$ && "$hits" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
    [[ "$hits" -gt 0 ]] && { printf '1'; return 0; }
    walked=$(( walked + count ))
    # A page SHORTER than the one asked for is the only honest evidence that main's
    # history ran out inside the window, and it is honest evidence only because we
    # never asked for more than the API will give.
    (( count < per )) && { printf '0'; return 0; }
    page=$(( page + 1 ))
  done
  # Stopped counting; did not run out. Report what was WALKED, not what was asked for.
  printf 'bound:%s' "$walked"
}

_task_status_cmd() {
  local newstatus="$1" extra="$2" verb="$3"; shift 3
  tasks_db_init
  local result="" want_result=0 notify=0 no_preflight=0 force_merge_gate=0 keep_wt=0
  # DIVE-1955 (review, Marcus): every reason the merge-gate could NOT reach an answer,
  # accumulated so the close can be stamped UNVERIFIED in the DURABLE RECORD. A stderr
  # warn and an audit row are necessary and not sufficient: the task row is what a
  # reader sees months later, and a clean-looking row is a verdict the gate never made.
  # Same rule we shipped in DIVE-1869 — a check that could not reach its answer must
  # not render as one. Blocking nothing is fine; blessing by silence is not.
  local _mg_unverified=""
  # ...and whether the gate had ANY subject to verify in the first place. See
  # _gate_text_names_a_ref: an unverified reason only earns a mark on the record when
  # something was actually pending verification.
  local _mg_had_subject=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result=*)     result="${1#*=}"; want_result=1 ;;
      --notify)       notify=1 ;;
      --no-preflight) no_preflight=1 ;;
      --force-merge-gate) force_merge_gate=1 ;;  # DIVE-1835: audited escape from the mandatory auto-detect gate
      # DIVE-1967: opt OUT of the node_modules reclaim a close performs (you are
      # about to reuse the worktree and do not want to pay for another npm ci).
      --keep-worktree) keep_wt=1 ;;
      --)         shift; positional+=("$@"); break ;;
      -*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)          positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task $verb <id|DIVE-N> [--result=<text>] [--notify]"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
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
      policy_refuse "$E_CONFLICT" start-on-recurring-template DIVE-2059 "$ident" "$ident is a recurring TEMPLATE (kind='recurring'), not a worked task — 'task start' has no meaning here and would silently stop it firing (the materializer only fires status='todo' templates, DIVE-2055/DIVE-2059). To stop the template use 'task cancel $ident', 'task block $ident --by=<id>', or 'task park $ident --reason=<why> --wake=<when>'. To work an instance it already fired, start that materialized child task instead."
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
      policy_refuse "$E_CONFLICT" start-on-closed-task DIVE-2113 "$ident" "$ident is CLOSED (status='${_cs}', closed ${_cd}) — 'task start' would silently reopen it to in_progress while LEAVING done_at set, so the row contradicts itself and any recorded grade would describe a task the board shows as open. If it genuinely must be reopened, that is a deliberate decision and belongs on the record; no alternative verb is named here on purpose, because a refusal that lists exits publishes a route around itself (DIVE-2067)."
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
  # DIVE-477: maker→verifier routing. A `task done` on a task that carries a
  # `verifier` distinct from its current assignee is NOT a close — it's a handoff.
  # The maker is claiming the work is ready; the verifier must grade it before the
  # task can close (writer != grader). Route it to the verifier and let the
  # heartbeat wake them on the next tick; the verifier closes it for real (its own
  # `task done`, where verifier==assignee, falls through to a normal close) or
  # rejects it (`task reject` → bounce back to the maker). Opt-in: ordinary tasks
  # (verifier NULL) and the verifier's own close are untouched.
  if [[ "$verb" == "done" ]]; then
    local _vfier _asignee
    _vfier=$(db "SELECT COALESCE(verifier,'')  FROM tasks WHERE id=${id};")
    _asignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_vfier" && "$_vfier" != "$_asignee" ]]; then
      _task_route_to_verifier "$id" "$_vfier" "$_asignee" "$result" "$want_result"
      return
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
          "$ident is DELIVERED to verifier '${_vfier}' (iteration ${_iter}, maker '${_maker}') and has NOT been graded — a 'task done' from '${_actor}' would close it ungraded, which is the maker grading its own work (writer != grader, DIVE-477). Only '${_vfier}' can close it. To CORRECT the result text do NOT re-run done: send the correction to '${_vfier}' (5dive agent send ${_vfier} \"...\") and let them fold it in. Real exits: '5dive task reject $ident --feedback=...' (verifier bounces it back), '5dive task verify $ident --cmd=\"<acceptance test>\"' (evidence-backed close), or '5dive task cancel $ident --result=...' (abandon)."
      fi
    fi
  fi
  # DIVE-555 gate enforcement (DIVE-393/394 class): a `task done` must NOT close
  # a task that still has an UNANSWERED human gate — that's how DIVE-535's
  # public-publish approval got bypassed (the task was marked done while its
  # approval gate sat 'pending', so the public ship happened with no recorded
  # sign-off). Block the close: the gate must be answered (`task answer`) or the
  # task abandoned (`task cancel`, which legitimately closes a gated task).
  # Verifier routing already returned above; only a real `done` reaches here.
  if [[ "$verb" == "done" ]]; then
    local _gt _ga
    _gt=$(db "SELECT COALESCE(need_type,'')        FROM tasks WHERE id=${id};")
    _ga=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_gt" && -z "$_ga" ]]; then
      policy_refuse "$E_CONFLICT" done-over-open-gate DIVE-555 "$ident" "$ident has a pending '${_gt}' gate awaiting a human — answer it (5dive task answer $ident ...) or abandon the task (5dive task cancel $ident) instead of marking done. A gated/public ship must not close ahead of its gate (DIVE-555)."
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
    if [[ -n "$_dref" || -n "$_branch" ]]; then
      _mg_had_subject=1     # a declared delivery IS something to verify
      if ! command -v gh >/dev/null 2>&1; then
        fail "$E_GENERIC" "$ident declared delivered work (${_dref:-branch $_branch}) but \`gh\` is unavailable to confirm it merged — install gh or close via the verifier on-box."
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
      if [[ -z "$_ghtok" ]]; then
        policy_refuse "$E_CONFLICT" done-merge-gate-no-credential DIVE-2318 "$ident" "$ident cannot close: the merge gate COULD NOT CHECK whether ${_dref:-branch '$_branch'} landed — no gh credential resolved in this caller's environment, so no query ran at all. This says NOTHING about the merge; do not read it as 'not merged'. Resolution order is GH_TOKEN/GITHUB_TOKEN in env, then \`gh auth token\` for the sudo invoker, then your own, then \`sudo -n -u claude gh auth token\` — the last needs sudoers scope most agents do not have. Either re-run with a token (\`GH_TOKEN=\$(sudo -u claude gh auth token) 5dive task done $ident ...\`) or hand the close to an agent that holds one (agent-main); a maker who cannot query GitHub cannot satisfy done=merged-to-main (DIVE-1830) and this gate defers to a token-holding closer by design. Verify with \`5dive task merge-audit --limit=1\`, which reports the same missing credential."
      fi
      if [[ -n "$_dref" ]]; then
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
            policy_refuse "$E_CONFLICT" done-with-ambiguous-delivery-ref DIVE-1955 "$ident" "$ident cannot close: its delivery_ref \"$_dref\" is a bare PR number with no repo, and this product spans ${_qd#AMBIGUOUS|}${_qd:+ — }multiple repos whose numbering collides. A number alone does not identify a pull request. Re-bind it with the full URL (\`task deliver $ident --pr=https://github.com/<owner>/<repo>/pull/N\`), or add a \`Repo: <owner>/<repo>\` line to the body, then \`task done\`."
          fi
          _dref="https://github.com/${_qd%%|*}/pull/${_dref#\#}"
          warn "$ident: bare delivery_ref resolved to $_dref by ident evidence (DIVE-1955) — bind the full URL next time."
        fi
        local _state _merged
        _state=$(GH_TOKEN="$_ghtok" gh pr view "$_dref" --json state,mergedAt -q '.state' 2>/dev/null || echo "")
        _merged=$(GH_TOKEN="$_ghtok" gh pr view "$_dref" --json state,mergedAt -q '.mergedAt' 2>/dev/null || echo "")
        # DIVE-2318: an EMPTY state is "the question was not answered", not "the answer
        # was no". A token is present by here (guarded above), so an empty state means
        # the query itself failed — network, timeout, a PR/repo this token cannot see,
        # a deleted PR, an unparseable payload. The old single branch collapsed that
        # into "not merged to main yet ... state=unknown", which asserts a merge verdict
        # nobody measured. Own slug, because a refusal record that cannot answer WHICH
        # of the two happened is the same defect one level down.
        if [[ -z "$_state" ]]; then
          policy_refuse "$E_CONFLICT" done-pr-state-unresolved DIVE-2318 "$ident" "$ident cannot close: the merge gate COULD NOT READ the state of $_dref — a gh credential resolved, but the query returned nothing. This is NOT a finding that the PR is unmerged; it was never answered. Likely: the PR/repo is not visible to this token, the ref is wrong or deleted, or gh/the network failed. Check by hand (\`gh pr view $_dref --json state,mergedAt\`); if it IS merged, re-run \`task done\` from an environment whose token can see it. Use \`task cancel\` to abandon."
        fi
        if [[ "$_state" != "MERGED" || -z "$_merged" || "$_merged" == "null" ]]; then
          policy_refuse "$E_CONFLICT" done-before-pr-merged DIVE-1830 "$ident" "$ident cannot close: its delivery PR is not merged to main yet ($_dref, state=$_state — MEASURED, not assumed). done=merged-to-main (DIVE-1830) — merge the PR, then run task done. Use \`task cancel\` to abandon."
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
              policy_refuse "$E_CONFLICT" done-after-red-merge DIVE-1935 "$ident" "$ident cannot close: its delivery PR $_dref is merged but its checks are RED. done=merged-AND-green (DIVE-1935) — fix main (or re-run the failed check), then task done, or \`task done $ident --force-merge-gate\` to override (audited)."
            fi
            ;;
          '') warn "$ident: could not verify the check status of $_dref (no gh token / network / gh) — merged-state confirmed, checks UNVERIFIED."
              _mg_unverified="${_mg_unverified:+$_mg_unverified; }checks of $_dref unresolved (merged-state confirmed)" ;;
        esac
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
        local _slug _bmerged="" _searched="" _attr_slug="" _anc="" _attr="" _anc_novac="" _attr_bound="" _attr_walked="" _attr_unreach=""
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
          # bound:<walked> — carry the MEASURED count into the refusal. The number in
          # that message is the one thing a reader acts on, so it must be what the scan
          # actually walked and not what it was configured to want.
          [[ "$_attr" == bound:* ]] && { _attr_bound="$_slug"; _attr_walked="${_attr#bound:}"; }
          # Ancestry is kept ONLY to name the vacuous shape in the refusal; it can no longer
          # accept anything by itself (that was the DIVE-2101 bug).
          _anc=$(_gate_branch_ancestry "$_slug" "$_branch" "$_ghtok")
          [[ "$_anc" == "1" && "$_attr" == "0" ]] && _anc_novac="$_slug"
          # DIVE-2318: attribution returning EMPTY is "unreachable", documented as such
          # on _gate_branch_ident_on_main and then discarded here — every non-"1" answer
          # fell through to the same generic "branch is NOT on main" refusal, so an API
          # failure and an exhaustive miss printed the identical sentence. Only one of
          # them is a finding. Carry it so the refusal below can tell them apart.
          [[ -z "$_attr" ]] && _attr_unreach="$_slug"
          _bmerged=$(GH_TOKEN="$_ghtok" gh pr list --repo "$_slug" --head "$_branch" --state merged --json number,mergedAt -q '.[0].mergedAt' 2>/dev/null || echo "")
          [[ -n "$_bmerged" && "$_bmerged" != "null" ]] && break
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
          warn "$ident: a commit on ${FIVE_GATE_MAIN_BRANCH:-main} in $_attr_slug names $ident in its SUBJECT — the work is on main (attribution, DIVE-2120). This does NOT establish HOW it landed: a delegated push and a squash-merged PR are indistinguishable to a subject scan, because a squash rewrites the sha. done=merged-to-main satisfied."
        elif [[ -n "$_attr_bound" && -z "$_bmerged" ]]; then
          # DIVE-2120: the scan stopped AT THE BOUND without finding the ident. That is NOT
          # a miss and must not read as one — a bounded search whose negative looks like an
          # exhaustive one asserts something it never measured. Own slug, so the durable
          # record says which of the two actually happened.
          policy_refuse "$E_CONFLICT" done-ident-not-found-within-scan-bound DIVE-2120 "$ident" "$ident cannot close: NOT FOUND IN THE $_attr_walked COMMITS WALKED on ${FIVE_GATE_MAIN_BRANCH:-main} in $_attr_bound — the scan stopped at its bound with main's history NOT exhausted, so this is INCONCLUSIVE, not a finding that the work is absent. TWO explanations survive and this scan cannot separate them: (a) the delivery landed more than $_attr_walked commits ago, or (b) nothing on main ever named $ident in a commit SUBJECT — which is what an EMPTY branch looks like, and a delivery whose subject omits the ident looks the same. For (a) raise the bound and retry (FIVE_GATE_ANCESTRY_SCAN=<n>, paginated since DIVE-2120, so n>100 really does walk n). For (b) land a commit whose SUBJECT names $ident (`5dive push $ident`) or bind the branch that carries it. A merged PR for '$_branch' also satisfies the gate."
        elif [[ -n "$_anc_novac" && -z "$_bmerged" ]]; then
          # The vacuous shape, named as itself: an ancestor tip carrying nothing
          # attributable is exactly what an EMPTY branch looks like, and a generic
          # "not merged" here would send the reader off to merge something that is
          # already in.
          policy_refuse "$E_CONFLICT" done-on-vacuous-branch-ancestry DIVE-2101 "$ident" "$ident cannot close: branch '$_branch' points at a commit that IS on ${FIVE_GATE_MAIN_BRANCH:-main} in $_anc_novac, but NO commit reachable from it names $ident — which is what an EMPTY branch (created, never committed to) looks like, and is indistinguishable from one here. done=merged-to-main (DIVE-1830/2101) needs work ON main, not a tip on main: commit the work naming $ident and land it (\`5dive push $ident\`), or bind the branch that actually carries it (\`task set-branch $ident <branch>\`). A merged PR for the branch also satisfies the gate. Use \`task cancel\` to abandon."
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
          policy_refuse "$E_CONFLICT" done-attribution-unresolved DIVE-2318 "$ident" "$ident cannot close: the merge gate COULD NOT SCAN ${FIVE_GATE_MAIN_BRANCH:-main} in $_attr_unreach for a commit naming $ident — that query returned nothing, so the question was never answered there. The search covered $_searched, so this is PARTIAL COVERAGE, not a finding that '$_branch' is absent. Likely gh/network/timeout, or a repo this token cannot read. Re-run when the API is reachable, hand the close to an agent whose token can see $_attr_unreach, or narrow the search with a \`Repo: <owner>/<repo>\` line in the body. Use \`task cancel\` to abandon."
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
          policy_refuse "$E_CONFLICT" done-before-branch-merged DIVE-1830 "$ident" "$ident cannot close: nothing on ${FIVE_GATE_MAIN_BRANCH:-main} in $_searched shows branch '$_branch' landed. MEASURED, both ways that can accept: (a) no commit SUBJECT on main names $ident (attribution, DIVE-2120 — the only test that accepts here), and (b) no MERGED PR has '$_branch' as its head. Ancestry is NOT one of the ways: a squash rewrites the sha, so a branch tip is never an ancestor of a squash-merged main — do not go looking for the branch. done=merged-to-main (DIVE-1830) — land it (delegated push: \`5dive push $ident\`, or open and merge a PR) with the ident in the commit SUBJECT, then run task done. If it lives in a repo not listed there, add a \`Repo: <owner>/<repo>\` line to the body. Use \`task cancel\` to abandon."
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
    if [[ -n "$_ghtok2" ]]; then
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
        _hit=$(GH_TOKEN="$_ghtok2" timeout 5s gh pr list --repo "$_slug2" \
                    --state open --limit 200 --json number,headRefName,title \
                    -q "[.[] | select((.title // \"\" | test(\"(^|[^A-Za-z0-9])${ident}([^A-Za-z0-9]|\$)\";\"i\")) or (.headRefName // \"\" | test(\"(^|[^A-Za-z0-9])${ident}([^A-Za-z0-9]|\$)\";\"i\"))) | .number] | .[0] // empty" \
                    2>/dev/null) && _sc_ok=$((_sc_ok+1)) || _hit=""
        if [[ -n "$_hit" ]]; then _auto_hit="$_hit"; _sc_hit_slug="$_slug2"; break; fi
      done < <(if [[ -n "$_task_slug" ]]; then printf '%s\n' "$_task_slug"; else _gate_repo_slugs; fi)
      [[ $_sc_ok -eq $_sc_total && $_sc_total -gt 0 ]] && _scan_ran=1
      [[ -n "$_auto_hit" ]] && _scan_ran=1
    fi
    # DIVE-1935: SAY SO when the scan could not run. A fail-open gate that returns
    # "no hit" for a gh outage and "no hit" for a clean repo is indistinguishable
    # from a working one — the same succeeding-in-appearance shape DIVE-1922 was
    # itself about. Fail-open stays (a gh outage must never stall the fleet), but
    # it is no longer silent, and the audit row makes the unverified close findable.
    if [[ $_scan_ran -eq 0 ]]; then
      local _scan_why="query-failed"
      command -v gh >/dev/null 2>&1 || _scan_why="gh-absent"
      [[ -n "$_ghtok2" ]] || _scan_why="no-gh-token"
      # DIVE-1955: "3 repos, 2 listed" is partial coverage, and partial coverage
      # announced as a clean scan is the defect this ticket is about, one level up.
      [[ -n "$_ghtok2" && $_sc_total -gt 0 && $_sc_ok -lt $_sc_total ]] && _scan_why="partial-repo-scan-${_sc_ok}-of-${_sc_total}"
      warn "$ident: merge-gate could not query GitHub ($_scan_why) — this close is UNVERIFIED, not verified-clean (DIVE-1935)."
      _task_store_audit_log "task.merge-gate-unverified" ok 0 -- "$ident" "reason=$_scan_why"
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
        warn "$ident: merge-gate treated PR reference(s) #${_txt_cited//,/, #} as CITED, not delivered — nothing binds them to this task, so their merge state was NOT checked (DIVE-1965). If one of them IS this task's delivery, bind it (\`task deliver $ident --pr=<url>\`) or say so (\"merged as PR #N\", or a \`Delivered: <url>\` line)."
        # DIVE-2054 (judgment call): same merge-gate family as -ambiguous above — fenced.
        _task_store_audit_log "task.merge-gate-reported-on" ok 0 -- "$ident" "refs=$_txt_cited"
      fi
    fi
    if [[ -n "$_txt_open" && $force_merge_gate -eq 0 ]]; then
      policy_refuse "$E_CONFLICT" done-with-open-pr-in-result DIVE-1935 "$ident" "$ident cannot close: its result/body names PR #$_txt_open, which is OPEN in $_txt_open_slug and not merged to main. done=merged-to-main (DIVE-1935) — merge it then \`task done\`, bind it with \`task deliver --pr=\` if it is the delivery, \`task cancel\` to abandon, or \`task done $ident --force-merge-gate\` to override (audited)."
    fi
    if [[ -n "$_txt_red" && $force_merge_gate -eq 0 ]]; then
      policy_refuse "$E_CONFLICT" done-after-named-red-merge DIVE-1935 "$ident" "$ident cannot close: PR ${_txt_red//,/, } named in its result/body is merged but its checks are RED. done=merged-AND-green (DIVE-1935) — fix main (or re-run the failed check), then task done, or \`task done $ident --force-merge-gate\` to override (audited)."
    fi
    if [[ $force_merge_gate -eq 1 ]]; then
      # Never a silent bypass: record the forced close (with the overridden PR #
      # if any) to the tamper-evident audit log. The unmerged PR/branch it leaves
      # behind is independently flagged by the weekly hygiene digest (#139).
      # DIVE-2054 (judgment call): same reasoning as the other force-merge-gate
      # site above — task-store override record, fenced for consistency.
      _task_store_audit_log "task.force-merge-gate" ok 0 -- "$ident" "override_pr=${_auto_hit:-none}"
    elif [[ -n "$_auto_hit" ]]; then
      policy_refuse "$E_CONFLICT" done-before-named-pr-merged DIVE-1835 "$ident" "$ident cannot close: open PR ${_sc_hit_slug}#$_auto_hit names it in its title/branch but is not merged to main. done=merged-to-main (DIVE-1835 mandatory gate) — merge it then \`task done\`, \`task cancel\` to abandon, or \`task done $ident --force-merge-gate\` to override (audited + surfaced in the weekly hygiene digest)."
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
  if (( notify )) && [[ "$verb" == "done" || "$verb" == "cancel" ]]; then
    local from_tmpl
    from_tmpl=$(db "SELECT COALESCE(from_template_id,'') FROM tasks WHERE id=${id};" 2>/dev/null || echo "")
    if [[ -z "$from_tmpl" ]]; then
      _task_close_notify "$ident" "$verb" "$result" || true
    fi
  fi
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

cmd_task_start()  { _task_status_cmd in_progress ", started_at=COALESCE(started_at, datetime('now'))" start "$@"; }
cmd_task_done()   { _task_status_cmd done ", done_at=datetime('now')" done "$@"; }
cmd_task_cancel() { _task_status_cmd cancelled ", done_at=datetime('now')" cancel "$@"; }

# DIVE-1830: `task deliver` — the maker records the PR that delivers this task,
# then hands off to the verifier for review. This is the OPT-IN half of the
# merge-gate: once a task carries a delivery_ref, its `task done` will not close
# until that PR is MERGED to main (see the gate in _task_status_cmd). Delivery
# reuses the DIVE-477 in-review handoff — it does NOT invent a new status. When
# there is no distinct verifier, the delivery is still recorded but the task
# stays in_progress: a verifier must close it after the merge (done ≠ delivered).
cmd_task_deliver() {
  tasks_db_init
  local task="" pr="" result="" want_result=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr=*)      pr="${1#*=}" ;;
      --result=*)  result="${1#*=}"; want_result=1 ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task deliver <id|DIVE-N> --pr=<url> [--result=<text>]"
  [[ -n "$pr" ]]   || fail "$E_USAGE" "task deliver requires --pr=<url> (the PR that delivers this task; done stays blocked until it is MERGED — DIVE-1830)"
  # Basic sanity: a delivery ref must look like a PR URL, not a bare word.
  if [[ "$pr" != http*://* && "$pr" != *github.com* ]]; then
    fail "$E_VALIDATION" "--pr must be a URL (e.g. https://github.com/<org>/<repo>/pull/<n>) — got '$pr'"
  fi
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # Record the delivery ref + timestamp before the handoff, so the merge-gate can
  # see it regardless of where the task lands next.
  db "UPDATE tasks SET delivery_ref=$(sqlq "$pr"), delivered_at=datetime('now') WHERE id=${id};"
  local _vfier _asignee
  _vfier=$(db "SELECT COALESCE(verifier,'')  FROM tasks WHERE id=${id};")
  _asignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")
  if [[ -n "$_vfier" && "$_vfier" != "$_asignee" ]]; then
    # Hand off to the verifier exactly like a maker's `task done` (DIVE-477).
    _task_route_to_verifier "$id" "$_vfier" "$_asignee" "$result" "$want_result"
    return
  fi
  # No distinct verifier: record the delivery but do NOT close — a verifier must
  # confirm the merge and close it. Leave the task in_progress.
  (( want_result )) && db "UPDATE tasks SET result=$(sqlq_or_null "$result") WHERE id=${id};"
  ok "$ident delivered ($pr) — recorded; it has no distinct verifier, so have a verifier close it via 'task done' AFTER the PR is merged (done stays blocked until then — DIVE-1830)" \
     '{id:($i|tonumber), ident:$id, deliveryRef:$p, delivered:true, routedTo:null, status:"in_progress"}' \
     --arg i "$id" --arg id "$ident" --arg p "$pr"
}

# `5dive task merge-audit [--limit=N] [--json]` — DIVE-1935 retrospective sweep.
# The gates above only police closes from now on; this answers the question the
# ticket actually asked: is DIVE-1922 the ONLY task that closed while the PR its
# own record names was never merged? Read-only — it reports, it never reopens.
# Scans DONE tasks newest-first, pulls every PR reference out of delivery_ref +
# result + body, resolves each, and prints the ones that are NOT merged. An
# unresolvable ref is reported as `unverified`, never counted as clean, so the
# sweep can't answer "all good" out of a broken token (the DIVE-1935 defect).
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
  [[ -n "$tok" ]] || fail "$E_GENERIC" "task merge-audit could not resolve a gh token — every PR would report 'unverified', which is not an audit. Authenticate gh (or export GH_TOKEN) and re-run."
  _gate_pr_refs_engine_ok || fail "$E_GENERIC" "task merge-audit cannot parse PR references on this host (grep -oE unusable) — it would report a clean sweep by finding nothing at all. Fix grep and re-run."
  local rows findings=0 unver=0 amb=0 json_rows=""
  rows=$(db "SELECT ident || '|' || COALESCE(delivery_ref,'') || '|' || REPLACE(REPLACE(COALESCE(delivery_ref,'') || ' ' || COALESCE(result,'') || ' ' || COALESCE(body,''), char(10), ' '), '|', ' ')
               FROM tasks WHERE status='done' ORDER BY COALESCE(done_at, created_at) DESC LIMIT ${limit};")
  local line tident tdref ttext qref st state rslug tslug
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
      json_rows+=$(jq -nc --arg t "$tident" --arg p "${qref#*|}" --arg r "$rslug" --arg s "$state" \
                     '{ident:$t,pr:("#"+$p),repo:$r,state:$s}')$'\n'
      [[ "${JSON_MODE:-0}" == "1" ]] || printf '%-12s %-22s PR #%-6s %s\n' "$tident" "$rslug" "${qref#*|}" "$state"
    done < <(_gate_pr_refs_qualified_from_text "$ttext")
  done <<<"$rows"
  local payload; payload=$(printf '%s' "$json_rows" | jq -sc '.')
  if [[ "${JSON_MODE:-0}" != "1" ]] && (( unver + amb > 0 )); then
    printf 'note: `unverified` = the number resolves to no PR in the repo(s) searched FOR THAT\n      TASK — the one its own record DECLARES (a delivery_ref URL or a `Repo:` line) when it\n      declares one, else all of %s (DIVE-1963).\n      `ambiguous` = a bare "PR #N" that exists in more than one of them and the task\n      declares no repo, so no single verdict is defensible. NEITHER is evidence of an\n      unmerged PR, and neither is evidence of a clean one. Cite the full pull URL, or\n      add a `Repo: <owner>/<repo>` line to the task body, to have them resolved.\n' "$slugs"
  fi
  ok "merge-audit: scanned the newest $limit done task(s) across $slugs — $findings PR reference(s) not merged-and-green ($unver unverified, $amb ambiguous)" \
     '{scanned:($n|tonumber), repos:($rp|split(",")), findings:($f|tonumber), unverified:($u|tonumber), ambiguous:($a|tonumber), rows:($r|fromjson)}' \
     --arg n "$limit" --arg rp "$slugs" --arg f "$findings" --arg u "$unver" --arg a "$amb" --arg r "$payload"
}

# DIVE-477: hand a maker-completed task to its verifier instead of closing it.
# Stash the original maker (first writer wins, so it survives re-routes) so a
# verify FAIL can bounce straight back, bump the iteration counter, keep the
# maker's result, and re-queue the task to the verifier as a fresh todo — the
# heartbeat picks it up on the verifier's next tick exactly like any other todo
# in their queue (no heartbeat change needed). No status='done' is written: the
# work is not closed until the verifier signs off.
_task_route_to_verifier() {
  local id="$1" vfier="$2" maker="$3" result="$4" want_result="$5"
  local set_result=""
  (( want_result )) && set_result=", result=$(sqlq_or_null "$result")"
  # DIVE-1416 (gap#2): stamp handoff_delivered_at fresh on EVERY delivery (incl.
  # a re-delivery after a reject/bounce-back) — the dedicated clock the stall
  # sweep uses to detect a delivery sitting unacknowledged too long. Clear any
  # prior stale-ping flag so a redelivered task gets a clean shot at surfacing
  # again if it goes stale a second time.
  db "UPDATE tasks
        SET status='todo', assignee=$(sqlq "$vfier"),
            maker_agent=COALESCE(maker_agent, $(sqlq_or_null "$maker")),
            iteration=COALESCE(iteration,0)+1,
            started_at=NULL, handoff_ack_at=NULL,
            handoff_delivered_at=datetime('now'), handoff_stale_pinged_at=NULL${set_result}
      WHERE id=${id};"
  local iter; iter=$(db "SELECT iteration FROM tasks WHERE id=${id};")
  local ident; ident=$(ident_of "$id")
  ok "$ident ready for review — delivered to verifier '$vfier' (iteration $iter; awaiting ACK)" \
     '{id:($i|tonumber), ident:$id, status:"todo", routedTo:$v, role:"verifier", handoff:"delivered", acknowledged:false, iteration:($n|tonumber)}' \
     --arg i "$id" --arg id "$ident" --arg v "$vfier" --arg n "$iter"
}

# DIVE-477: the verifier's FAIL verdict. The maker's work missed the bar, so
# bounce the task back to the maker with feedback for another pass — UNLESS we've
# reached max_iterations, where the loop is stuck and we park it on a human
# (`task need`) rather than ping-pong forever. Only meaningful mid-loop
# (maker_agent set); a plain task has no maker to bounce to.
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
  _rj_prev=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${id};")
  # (3) attribute to the REAL actor, never to the recorded verifier by assumption.
  local fb_txt="❌ ${_rj_actor} rejected (iteration ${iter}): ${feedback:-no feedback given}"
  # (4) never silently discard a landed record.
  if [[ "$_rj_st" == 'done' && -n "$_rj_prev" ]]; then
    # ONE marker, deliberately shared with the verify path (olivia, DIVE-2112: "extend,
    # do not fork the marker") so a single grep finds every superseded record. The
    # ticket in the string names the CONVENTION's origin, not this call site.
    fb_txt="${fb_txt}"$'\n'"--- superseded result (DIVE-2067, preserved) ---"$'\n'"${_rj_prev}"
  fi
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
  fi
  # max_iterations reached -> stop bouncing, park it on a human to decide.
  if (( maxi > 0 && iter >= maxi )); then
    db "UPDATE tasks SET result=$(sqlq "$fb_txt") WHERE id=${id};"
    warn "$ident hit max_iterations ($maxi) — escalating to human review"
    cmd_task_need "$id" --type=manual --from="${vfier:-verifier}" \
      --ask="Maker→verifier loop stuck: $ident failed verification ${iter}× (max ${maxi}). Last feedback: ${feedback:-none}. Review + decide."
    return
  fi
  # Otherwise bounce back to the maker for another pass.
  db "UPDATE tasks SET status='todo', assignee=$(sqlq "$maker"), started_at=NULL, handoff_ack_at=NULL,
        result=$(sqlq "$fb_txt") WHERE id=${id};"
  ok "$ident rejected — bounced back to maker '$maker' (iteration $iter${maxi:+/$maxi})" \
     '{id:($i|tonumber), ident:$id, status:"todo", bouncedTo:$m, role:"maker", iteration:($n|tonumber)}' \
     --arg i "$id" --arg id "$ident" --arg m "$maker" --arg n "$iter"
}

# DIVE-478: loop observability. The org-wide board of maker→verifier loops (any
# task with a verifier), grouped by task id, showing where each loop sits — the
# maker/verifier pair, who currently holds it, iteration vs its cap, and a ⚠ STUCK
# flag when a loop has burned its whole max_iterations budget but still isn't
# closed (it should have escalated via `task reject` at the cap; this surfaces any
# that slipped through, e.g. a maker that kept re-routing without a clean reject).
# Pairs with `5dive usage`, which attributes tokens/turns/cost to the same task
# ids — so loops here + usage there give iterations AND cost per loop.
#   --stuck            only the stuck loops
#   --all              include closed loops (default: open only)
#   --escalate-stuck   run `task escalate` on every stuck open loop (reuses the
#                      standard escalate path: bump priority + ping agent & human)
cmd_task_loops() {
  tasks_db_init
  local only_stuck=0 show_all=0 escalate=0 kill_id="" watch=0 watch_secs=3 runs_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stuck)          only_stuck=1 ;;
      --all)            show_all=1 ;;
      --escalate-stuck) escalate=1; only_stuck=1 ;;
      --runs)           runs_only=1 ;;
      --kill=*)         kill_id="${1#--kill=}" ;;
      --kill)           shift; kill_id="${1:-}" ;;
      --watch)          watch=1 ;;
      --watch=*)        watch=1; watch_secs="${1#--watch=}" ;;
      -*)               fail "$E_USAGE" "unknown flag: $1" ;;
      *)                fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done

  # --kill <loopId>: deferred-safe stop for a LOOP-7 run. Flips kill_requested;
  # the running verb checks it between stages and halts + escalates-with-proof.
  # The control window never authors work — this only sets a flag (design §2/§4).
  if [[ -n "$kill_id" ]]; then
    local exists; exists=$(db "SELECT 1 FROM loop_runs WHERE loop_id=$(sqlq "$kill_id") LIMIT 1;")
    [[ "$exists" == "1" ]] || fail "$E_NOT_FOUND" "no loop run with id '$kill_id'"
    db "UPDATE loop_runs SET kill_requested=1, updated_at=$(date +%s) WHERE loop_id=$(sqlq "$kill_id");"
    ok "kill requested for loop ${kill_id} (deferred — halts at its next stage check)" \
       '{loopId:$l, killRequested:true}' --arg l "$kill_id"
    return
  fi

  [[ "$watch_secs" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--watch=<seconds> must be a positive integer"
  # A loop is "stuck" once it has a cap, has reached it, and still isn't closed.
  local stuck_pred="(verifier IS NOT NULL AND max_iterations IS NOT NULL
                     AND COALESCE(iteration,0) >= max_iterations
                     AND status NOT IN ('done','cancelled'))"
  local where="verifier IS NOT NULL"
  (( show_all )) || where+=" AND status NOT IN ('done','cancelled')"
  (( only_stuck )) && where+=" AND ${stuck_pred}"

  # --escalate-stuck: reuse the standard escalate path on every stuck open loop.
  if (( escalate )); then
    local ids; ids=$(db "SELECT id FROM tasks WHERE ${stuck_pred} ORDER BY id;")
    if [[ -z "$ids" ]]; then
      ok "no stuck loops to escalate" '{escalated:[]}'
      return
    fi
    local eid
    for eid in $ids; do cmd_task_escalate "$eid" --from=loop-watch || true; done
    return
  fi

  # loop_runs (LOOP-7) control-window predicate: open = status 'running'.
  local runs_where="status='running'"; (( show_all )) && runs_where="1=1"

  # One repaint of the board(s). JSON mode emits {loops, runs}; text prints the
  # maker→verifier board (DIVE-478) then the LOOP-7 loop_runs board below it.
  # --runs shows only the loop_runs board. Read-only — never authors work.
  _task_loops_paint() {
    if (( JSON_MODE )); then
      local tloops="[]" runs="[]"
      (( runs_only )) || tloops=$(dbfmt -json "SELECT ident, status,
               COALESCE(maker_agent, assignee) AS maker, verifier,
               COALESCE(iteration,0) AS iteration, max_iterations,
               COALESCE(assignee,'') AS holder,
               CASE WHEN maker_agent IS NOT NULL AND assignee=verifier AND status NOT IN ('done','cancelled')
                    THEN CASE WHEN handoff_ack_at IS NOT NULL THEN 'reviewing' ELSE 'delivered' END
                    ELSE NULL END AS handoff_state,
               handoff_ack_at,
               CASE WHEN ${stuck_pred} THEN 1 ELSE 0 END AS stuck, title
             FROM tasks WHERE ${where}
             ORDER BY (CASE WHEN ${stuck_pred} THEN 1 ELSE 0 END) DESC, COALESCE(iteration,0) DESC, id;")
      [[ -n "$tloops" ]] || tloops="[]"
      runs=$(dbfmt -json "SELECT loop_id, topology, COALESCE(stage,'') AS stage,
               COALESCE(iteration,0) AS iteration, COALESCE(tokens_spent,0) AS tokens_spent,
               ceiling, status, COALESCE(spawned_by_agent,'') AS by,
               kill_requested, stuck, COALESCE(scorecard_json,'') AS scorecard
             FROM loop_runs WHERE ${runs_where}
             ORDER BY (status='running') DESC, started_at DESC;")
      [[ -n "$runs" ]] || runs="[]"
      jq -cn --argjson l "$tloops" --argjson r "$runs" '{ok:true, data:{loops:$l, runs:$r}}'
    else
      if (( ! runs_only )); then
        dbfmt -box "SELECT ident, status,
                 CASE WHEN maker_agent IS NOT NULL AND assignee=verifier AND status NOT IN ('done','cancelled')
                      THEN CASE WHEN handoff_ack_at IS NOT NULL THEN 'reviewing' ELSE 'delivered' END
                      ELSE '-' END AS handoff,
                 COALESCE(maker_agent, COALESCE(assignee,'-')) AS maker,
                 COALESCE(verifier,'-') AS verifier,
                 COALESCE(iteration,0)||'/'||COALESCE(CAST(max_iterations AS TEXT),'∞') AS iter,
                 CASE WHEN ${stuck_pred} THEN '⚠' ELSE '' END AS stuck,
                 title
               FROM tasks WHERE ${where}
               ORDER BY (CASE WHEN ${stuck_pred} THEN 1 ELSE 0 END) DESC, COALESCE(iteration,0) DESC, ident;"
        printf '\nLOOP-7 runs:\n'
      fi
      dbfmt -box "SELECT loop_id, topology, COALESCE(NULLIF(stage,''),'-') AS stage,
               COALESCE(iteration,0) AS iter,
               COALESCE(tokens_spent,0)||'/'||COALESCE(CAST(ceiling AS TEXT),'∞') AS tokens,
               status,
               CASE WHEN scorecard_json IS NOT NULL AND json_valid(scorecard_json)
                    THEN COALESCE(CAST(json_extract(scorecard_json,'\$.overall') AS TEXT),'-')||'/100'
                    ELSE '-' END AS score,
               CASE WHEN kill_requested=1 THEN '✗kill' ELSE '' END AS kill,
               CASE WHEN stuck=1 THEN '⚠' ELSE '' END AS stuck,
               COALESCE(spawned_by_agent,'-') AS by
             FROM loop_runs WHERE ${runs_where}
             ORDER BY (status='running') DESC, started_at DESC;"
    fi
  }

  # --watch: repaint on an interval (text only; JSON callers poll themselves).
  if (( watch )) && (( ! JSON_MODE )); then
    while :; do
      printf '\033[2J\033[H'   # clear + home
      printf '5dive loop control — refresh %ss (Ctrl-C to exit)\n\n' "$watch_secs"
      _task_loops_paint
      sleep "$watch_secs"
    done
    return
  fi
  _task_loops_paint
}

# ───────────────────────── DIVE-552 loop engine ─────────────────────────
# A "loop" is an N-step agent relay — the general case of the maker→verifier
# 2-step chain (DIVE-477). It is composed ENTIRELY from existing primitives, so
# NO schema migration: a loop RUN is a parent task; each STEP is a subtask
# (assignee = the step's agent), ordered by block edges (step N+1 blocked_by
# step N). When a step's `task done` fires, the close path advances the loop:
# drop the edge to the next step, which the existing unblock-flip turns into a
# todo the heartbeat wakes. A HUMAN-GATE step is the existing `task need`
# decision gate (Approve →/Do better ↩), fired the moment the loop reaches it.
#
# Loop membership is marked in the task body with an ASCII sentinel (no new
# column): the run carries `[[5dive-loop:run]]`, a step carries
# `[[5dive-loop:work]]` or `[[5dive-loop:gate:approval]]` / `:gate:manual`.
_LOOP_MARK="[[5dive-loop"

# Echo a task's loop-step kind from its body marker: work | gate:approval |
# gate:manual | run, or "" when the task is not part of a loop.
_loop_kind() {
  local id="$1" body
  body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
  case "$body" in
    *"${_LOOP_MARK}:"*) ;;
    *) return ;;
  esac
  printf '%s' "$body" | sed -n 's/.*\[\[5dive-loop:\([^]]*\)\]\].*/\1/p' | head -1
}

# DIVE-1355 — the task-engine self-dispatch fix. When a task CLOSES (done or
# cancelled), free any dependent this close finished off: drop the now-satisfied
# blocking edge, and if the dependent has NO blocking edges left, flip it
# blocked->todo and ping its assignee so it dispatches now instead of rotting.
# This is the same unblock-flip `task unblock`, the relay advance, and the
# park-wake sweep all use (a task with no task_deps edge is, by convention,
# unblocked). It is what makes a finished blocker actually release its dependents
# — the OSS-26 -> OSS-27 rot that idled the whole builder queue overnight
# (dependents stayed status=blocked forever because NOTHING cleared their edge).
#
# GUARDRAIL (lodar/main): ONLY dependency edges auto-clear. A dependent is left
# blocked (not flipped) when it has another live hold — an unanswered human
# need-gate (need_type set, need_answered_at NULL) or a park (parked_at set: a
# deliberate hold / future wake the park-wake sweep owns). The satisfied edge is
# still dropped (the blocker really is done), so once the gate is answered / the
# park wakes, the existing NOT-EXISTS-edge flip releases it correctly.
#
# Best-effort + isolated by the caller (|| true): a cascade hiccup must never
# fail the close that already committed. Runs on done AND cancel — a cancelled
# blocker is as "cleared" as a done one for its dependents.
_task_cascade_unblock() {
  local closed_id="$1" dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    # This blocker is now done/cancelled — drop its (satisfied) edge.
    db "DELETE FROM task_deps WHERE task_id=${dep} AND blocked_by=${closed_id};"
    # Still blocked by another unfinished edge? leave it.
    [[ "$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=${dep};")" == "0" ]] || continue
    # Flip blocked->todo ONLY when no non-dependency hold remains (guardrail).
    db "UPDATE tasks SET status='todo'
        WHERE id=${dep} AND status='blocked'
          AND parked_at IS NULL
          AND (need_type IS NULL OR need_answered_at IS NOT NULL);"
    [[ "$(db "SELECT status FROM tasks WHERE id=${dep};")" == "todo" ]] || continue
    # Ping the freed dependent's assignee (best-effort; subshell contains cmd_send's
    # fail-closed exit + scoped-send exec exactly like _task_loop_advance).
    local who dident dtitle
    who=$(db    "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${dep};")
    dident=$(db "SELECT ident FROM tasks WHERE id=${dep};")
    dtitle=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${dep};")
    [[ -n "$who" ]] && ( cmd_send "$who" --from="task-engine" \
        --message="▶️ Unblocked: ${dident} — all its blockers are done. It's on your queue now: ${dtitle}" ) >/dev/null 2>&1 || true
  done < <(db "SELECT task_id FROM task_deps WHERE blocked_by=${closed_id};")
  return 0
}

# Advance a loop past a just-finished step `sid`. Drop each edge where a sibling
# was blocked_by sid; a freed AGENT step becomes a todo (the unblock-flip the
# existing `task block`/answer paths use) and we best-effort ping its assignee;
# a freed GATE step fires its human tap right when it's reached. When sid has no
# downstream step, the relay is over — close the parent run.
_task_loop_advance() {
  local sid="$1"
  local run; run=$(db "SELECT COALESCE(parent_id,'') FROM tasks WHERE id=${sid};")
  local nexts; nexts=$(db "SELECT task_id FROM task_deps WHERE blocked_by=${sid};")
  if [[ -z "$nexts" ]]; then
    # last step done — close the run (if it's still open) and tell its owner.
    if [[ -n "$run" ]]; then
      local rstatus; rstatus=$(db "SELECT status FROM tasks WHERE id=${run};")
      if [[ "$rstatus" != "done" && "$rstatus" != "cancelled" ]]; then
        db "UPDATE tasks SET status='done', done_at=datetime('now') WHERE id=${run};"
        # DIVE-1415: a closed loop RUN can itself be a blocker of other tasks —
        # release its dependents on this terminal close too.
        _task_cascade_unblock "$run" || true
        local owner; owner=$(db "SELECT COALESCE(assignee,created_by) FROM tasks WHERE id=${run};")
        local rident; rident=$(db "SELECT ident FROM tasks WHERE id=${run};")
        [[ -n "$owner" ]] && ( cmd_send "$owner" --from="loop" \
            --message="✅ Loop complete: ${rident} — all steps done." ) >/dev/null 2>&1 || true
      fi
    fi
    return
  fi
  local nid
  while IFS= read -r nid; do
    [[ -n "$nid" ]] || continue
    db "DELETE FROM task_deps WHERE task_id=${nid} AND blocked_by=${sid};"
    # still blocked by another step? leave it.
    [[ "$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=${nid};")" == "0" ]] || continue
    local kind; kind=$(_loop_kind "$nid")
    case "$kind" in
      gate:*)
        local gtype="${kind#gate:}" gask
        gask=$(db "SELECT COALESCE(NULLIF(title,''),'Approve this step?') FROM tasks WHERE id=${nid};")
        if [[ "$gtype" == "manual" ]]; then
          cmd_task_need "$nid" --type=manual --from="loop" --ask="$gask"
        else
          # DIVE-560: a loop approval gate fires as --type=approval, which is
          # HUMAN-enforced (agent-uid block + gate-proof). It used to fire as
          # --type=decision purely for the Approve/Do-better buttons, but a
          # decision gate is agent-clearable — silently undercutting the public
          # "you get the final say at the gate" claim. The standard approval
          # Approve/Deny buttons cover it with no plugin change: a "denied" tap
          # drives the loop's bounce-back-and-redo (see the answer path below).
          cmd_task_need "$nid" --type=approval --from="loop" \
            --ask="$gask" --recommend="approved"
        fi
        ;;
      *)
        # agent step: the unblock-flip turns it todo; wake its owner.
        db "UPDATE tasks SET status='todo'
            WHERE id=${nid} AND status='blocked'
              AND (need_type IS NULL OR need_answered_at IS NOT NULL);"
        local who lbl rident
        who=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${nid};")
        lbl=$(db "SELECT title FROM tasks WHERE id=${nid};")
        rident=$(db "SELECT COALESCE((SELECT ident FROM tasks WHERE id=${run}),'') FROM tasks LIMIT 1;")
        [[ -n "$who" ]] && ( cmd_send "$who" --from="loop" \
            --message="🔁 Your turn in loop ${rident}: ${lbl}" ) >/dev/null 2>&1 || true
        ;;
    esac
  done <<< "$nexts"
}

# `5dive task loop start --title=<name> --steps=<json> [--project=] [--owner=] [--from=]`
# steps JSON = ordered array; each item is either an agent step
#   {"agent":"marcus","label":"Draft it","handoff":"submits for review"}
# or a human gate
#   {"gate":"approval"|"manual","label":"You approve before publish"}
# Materializes the run + chained step subtasks and starts step 1.
cmd_task_loop_start() {
  tasks_db_init
  local title="" steps="" project="dive" owner="" from=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title=*)   title="${1#*=}" ;;
      --steps=*)   steps="${1#*=}" ;;
      --project=*) project="${1#*=}" ;;
      --owner=*)   owner="${1#*=}" ;;
      --from=*)    from="${1#*=}" ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$title" ]] || fail "$E_USAGE" "usage: 5dive task loop start --title=<name> --steps=<json>"
  [[ -n "$steps" ]] || fail "$E_USAGE" "--steps=<json array> is required"
  printf '%s' "$steps" | jq -e 'type=="array" and length>0' >/dev/null 2>&1 \
    || fail "$E_VALIDATION" "--steps must be a non-empty JSON array"
  local creator; creator=$(task_actor "$from")
  [[ -n "$owner" ]] || owner=$(_task_resolve_coordinator)

  # Run parent — marked, assigned to the owner so it always has a home.
  local run_body="Loop run.
${_LOOP_MARK}:run]]"
  local run
  run=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, project_key, kind)
            VALUES ($(sqlq "$title"), $(sqlq "$run_body"), 'medium',
                    $(sqlq_or_null "$owner"), $(sqlq "$creator"), $(sqlq "${project,,}"), 'standard');
            SELECT last_insert_rowid();")
  local run_ident; run_ident=$(db "SELECT ident FROM tasks WHERE id=${run};")

  # Walk the steps, creating one subtask each and chaining N+1 blocked_by N.
  local n; n=$(printf '%s' "$steps" | jq 'length')
  local prev="" i=0 first=""
  while (( i < n )); do
    local item; item=$(printf '%s' "$steps" | jq -c ".[$i]")
    local gate; gate=$(printf '%s' "$item" | jq -r '.gate // empty')
    local label; label=$(printf '%s' "$item" | jq -r '.label // "Step"')
    local kind sassignee
    if [[ -n "$gate" ]]; then
      [[ "$gate" == "approval" || "$gate" == "manual" ]] || gate="approval"
      kind="gate:$gate"; sassignee="$owner"   # human answers; owner-agent holds it
    else
      sassignee=$(printf '%s' "$item" | jq -r '.agent // empty')
      [[ -n "$sassignee" ]] || fail "$E_VALIDATION" "step $i needs an \"agent\" or a \"gate\""
      kind="work"
    fi
    local sbody="${_LOOP_MARK}:${kind}]]"
    local sid
    sid=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, parent_id, project_key, kind)
              VALUES ($(sqlq "$label"), $(sqlq "$sbody"), 'medium',
                      $(sqlq_or_null "$sassignee"), $(sqlq "$creator"), ${run}, $(sqlq "${project,,}"), 'standard');
              SELECT last_insert_rowid();")
    if [[ -n "$prev" ]]; then
      db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES (${sid}, ${prev});
          UPDATE tasks SET status='blocked' WHERE id=${sid};"
    else
      first="$sid"
    fi
    prev="$sid"
    i=$((i+1))
  done

  # Kick off step 1 — ping its agent (heartbeat would wake it anyway).
  local who1; who1=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${first};")
  local lbl1; lbl1=$(db "SELECT title FROM tasks WHERE id=${first};")
  [[ -n "$who1" ]] && ( cmd_send "$who1" --from="loop" \
      --message="🔁 Loop ${run_ident} started — your step: ${lbl1}" ) >/dev/null 2>&1 || true

  ok "loop ${run_ident} started — ${n} steps, first: ${who1:-?}" \
     '{run:$r, ident:$id, steps:($n|tonumber), first_assignee:$w}' \
     --arg r "$run" --arg id "$run_ident" --arg n "$n" --arg w "${who1:-}"
}

# `5dive task loop ls` — the board of loop runs (parent tasks marked :run]]),
# with how many of their steps are done.
cmd_task_loop_ls() {
  tasks_db_init
  local show_all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) show_all=1 ;;
      -*)    fail "$E_USAGE" "unknown flag: $1" ;;
      *)     fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  local run_pred="body LIKE '%${_LOOP_MARK}:run]]%'"
  local status_pred="status NOT IN ('done','cancelled')"
  (( show_all )) && status_pred="1=1"
  # DIVE-860: latest grade scorecard for each run, joined by the graded task's
  # ident (loop grade stamps scorecard_json.target with it). Emitted as the raw
  # JSON string ('' when ungraded) — same shape `task loops` uses for its runs
  # board, so dashboard consumers parse one contract.
  local score_sub="COALESCE((SELECT lr.scorecard_json FROM loop_runs lr
             WHERE lr.scorecard_json IS NOT NULL AND json_valid(lr.scorecard_json)
               AND json_extract(lr.scorecard_json,'\$.target')=tasks.ident
             ORDER BY lr.updated_at DESC LIMIT 1),'')"
  if (( JSON_MODE )); then
    local rows
    rows=$(dbfmt -json "SELECT id, ident, title, status, assignee,
             (SELECT COUNT(*) FROM tasks s WHERE s.parent_id=tasks.id) AS steps,
             (SELECT COUNT(*) FROM tasks s WHERE s.parent_id=tasks.id AND s.status='done') AS done_steps,
             ${score_sub} AS scorecard_json
           FROM tasks WHERE ${run_pred} AND ${status_pred} ORDER BY id DESC;")
    [[ -n "$rows" ]] || rows="[]"
    printf '%s' "$rows" | jq -c '{ok:true, data:{loops:.}}'
  else
    dbfmt -box "SELECT ident, status, COALESCE(assignee,'-') AS owner,
             (SELECT COUNT(*) FROM tasks s WHERE s.parent_id=tasks.id AND s.status='done')||'/'||
             (SELECT COUNT(*) FROM tasks s WHERE s.parent_id=tasks.id) AS progress,
             CASE WHEN ${score_sub} <> ''
                  THEN COALESCE(CAST(json_extract(${score_sub},'\$.overall') AS TEXT),'-')||'/100'
                  ELSE '-' END AS score,
             title
           FROM tasks WHERE ${run_pred} AND ${status_pred} ORDER BY id DESC;"
  fi
}

cmd_task_loop() {
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task loop <start|ls> ..."
  local sub="$1"; shift
  case "$sub" in
    start)          cmd_task_loop_start "$@" ;;
    ls|list)        cmd_task_loop_ls "$@" ;;
    -h|--help|help) echo "5dive task loop start --title=<name> --steps=<json>   |   loop ls [--all]" ;;
    *) fail "$E_USAGE" "unknown loop command: $sub (try: start|ls)" ;;
  esac
}

# DIVE-475: deterministic verify-runner — proven-done, not claimed-done. Run a
# command; its EXIT CODE is the real stop condition. On pass (exit 0) flip the
# task to done with the command + output tail captured in result; on fail leave
# status untouched (just record the failing attempt). The verb itself exits 0 on
# pass / 1 on fail so it can BE a stop condition (heartbeat /goal, scripts) — the
# maker no longer grades itself by asserting status=done (writer != verifier).
# --no-done (alias --check) runs the check and records it WITHOUT flipping.
cmd_task_verify() {
  tasks_db_init
  local task="" cmd="" no_done=0 timeout_s=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cmd=*)      cmd="${1#*=}" ;;
      --no-done|--check) no_done=1 ;;
      --timeout=*)  timeout_s="${1#*=}" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] \
    || fail "$E_USAGE" "usage: 5dive task verify <id|DIVE-N> [--cmd=\"<command>\"] [--no-done] [--timeout=<seconds>]"
  [[ -z "$timeout_s" || "$timeout_s" =~ ^[1-9][0-9]*$ ]] \
    || fail "$E_VALIDATION" "--timeout must be a positive integer (seconds)"
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # DIVE-476: --cmd is now optional — when omitted, fall back to the task's stored
  # verify_command (the declarative loop spec). Persisted input, no re-passing.
  if [[ -z "$cmd" ]]; then
    cmd=$(db "SELECT COALESCE(verify_command,'') FROM tasks WHERE id=${id};")
    [[ -n "$cmd" ]] \
      || fail "$E_USAGE" "no --cmd given and task has no stored verify_command (set one: 5dive task add … --verify=\"<cmd>\")"
  fi

  # Run it. Combined stdout+stderr. The `if` wrapper captures the exit code
  # WITHOUT tripping `set -e` (a failing $() in a bare assignment would abort).
  local out rc
  if [[ -n "$timeout_s" ]]; then
    if out=$(timeout "${timeout_s}" bash -c "$cmd" 2>&1); then rc=0; else rc=$?; fi
    (( rc == 124 )) && out="${out}"$'\n'"[timed out after ${timeout_s}s]"
  else
    if out=$(bash -c "$cmd" 2>&1); then rc=0; else rc=$?; fi
  fi
  # Tail the output so a chatty command can't bloat the result row.
  local tail_out; tail_out=$(printf '%s\n' "$out" | tail -n 25)

  local verdict result_txt
  if (( rc == 0 )); then
    verdict="pass"
    result_txt="✅ verify PASS (exit 0): ${cmd}"$'\n'"--- output tail ---"$'\n'"${tail_out}"
  else
    verdict="fail"
    result_txt="❌ verify FAIL (exit ${rc}): ${cmd}"$'\n'"--- output tail ---"$'\n'"${tail_out}"
  fi

  local flipped=0 self_verified_close=0
  local self_verify_maker="" self_verify_verifier="" self_verify_iteration=""
  if (( rc == 0 )) && (( ! no_done )); then
    # DIVE-2196: this auto-close is a TERMINAL CLOSE reached by raw UPDATE, so it
    # never saw DIVE-555's pending-gate refusal — `task verify --cmd=true` closed a
    # task out from under an unanswered human gate, and the question then vanished
    # from every open-gate view (they all require an open status). That is the same
    # bypass DIVE-2067 recorded on the ACK axis: the refusal on `task done` NAMES
    # `task verify` as an alternative, and the named alternative carried no
    # equivalent check. Refusing here is what makes the `done`/`reject` rails real
    # rather than advisory. The verify RESULT is still recorded first — the evidence
    # is worth keeping and is not what the gate is protecting; only the close waits.
    local _vg_t _vg_a
    _vg_t=$(db "SELECT COALESCE(need_type,'')        FROM tasks WHERE id=${id};")
    _vg_a=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_vg_t" && -z "$_vg_a" ]]; then
      db "UPDATE tasks SET result=$(sqlq "$result_txt") WHERE id=${id};"
      policy_refuse "$E_CONFLICT" verify-close-over-open-gate DIVE-2196 "$ident" \
        "$ident has a pending '${_vg_t}' gate awaiting a human — the verify verdict is RECORDED, but the auto-close is refused: closing here would drop the human's question out of every open-gate view without anyone answering it, which is DIVE-555's bypass reached by a different verb. Exits: let them answer it ('5dive task answer $ident --value=...'), withdraw it if your result makes it moot ('5dive task need $ident --withdraw'), or re-run with --no-done to record evidence without closing."
    fi
    # DIVE-2015: a maker is deliberately ALLOWED to rescue a stalled delivered
    # loop with `task verify --cmd=...`; refusing it would remove the only
    # zero-human exit when the assigned verifier never runs. Permitted must not
    # mean invisible, though. When the REAL caller is the recorded maker and the
    # still-live row is held by its verifier, stamp the durable task result,
    # emit a separately classifiable audit event, and warn on stderr. The mark
    # names every fact a later reader needs to weigh the close: maker, verifier
    # who never recorded a grade, and loop iteration.
    #
    # This belongs in audit_log, not policy_refusals: nothing was refused. Route
    # through the task-store fence so fixture DBs cannot write real-looking task
    # telemetry into the fleet audit log (DIVE-2010).
    local _svc_actor _svc_row _svc_assignee _svc_status
    _svc_actor=$(task_actor)
    _svc_row=$(db "SELECT COALESCE(maker_agent,'')||x'1f'||
                        COALESCE(verifier,'')||x'1f'||
                        COALESCE(assignee,'')||x'1f'||
                        COALESCE(iteration,0)||x'1f'||status
                   FROM tasks WHERE id=${id};")
    IFS=$'\x1f' read -r self_verify_maker self_verify_verifier \
      _svc_assignee self_verify_iteration _svc_status <<<"$_svc_row"
    if [[ -n "$self_verify_maker" && -n "$self_verify_verifier" \
          && "$_svc_actor" == "$self_verify_maker" \
          && "$_svc_assignee" == "$self_verify_verifier" \
          && "$_svc_status" != "done" && "$_svc_status" != "cancelled" ]]; then
      self_verified_close=1
      result_txt="⚠ self-verified-close: maker=${self_verify_maker}; verifier=${self_verify_verifier} never graded; iteration=${self_verify_iteration}"$'\n'"${result_txt}"
    fi
    db "UPDATE tasks SET status='done', done_at=datetime('now'), result=$(sqlq "$result_txt") WHERE id=${id};"
    flipped=1
    if (( self_verified_close )); then
      _task_store_audit_log "task.verify-self-close" "self-verified-close" 0 -- \
        "task=$ident" "maker=$self_verify_maker" "verifier=$self_verify_verifier" \
        "iteration=$self_verify_iteration"
      warn "$ident self-verified-close: maker '$self_verify_maker' selected the passing verify command; verifier '$self_verify_verifier' never graded iteration $self_verify_iteration. Close allowed and visibly recorded."
    fi
    # DIVE-1415: `task verify` auto-done is a terminal close like `task done`, so
    # it must release this task's dependents too. DIVE-1355 wired the cascade
    # only into `_task_status_cmd` (the done/cancel verbs); a task closed via
    # verify (or the gate paths below) left its dependents stuck 'blocked' with
    # a satisfied edge — the exact stall that froze OSS-32/33 behind OSS-27
    # overnight (OSS-27 closed via `task verify`, cascade never ran).
    _task_cascade_unblock "$id" || true
  else
    db "UPDATE tasks SET result=$(sqlq "$result_txt") WHERE id=${id};"
  fi

  if (( JSON_MODE )); then
    printf '%s' "$result_txt" | jq -R -s \
      --arg i "$id" --arg id "$ident" --arg v "$verdict" --argjson rc "$rc" \
      --argjson flipped "$([[ $flipped -eq 1 ]] && echo true || echo false)" \
      '{ok:true, data:{id:($i|tonumber), ident:$id, verdict:$v, exit:$rc, flippedToDone:$flipped, output:.}}'
  else
    printf '%s\n' "$result_txt" >&2
    if (( rc == 0 )); then
      (( flipped )) && ok "$ident verify PASS — marked done" \
                    || ok "$ident verify PASS (status unchanged, --no-done)"
    else
      warn "$ident verify FAIL (exit $rc) — status unchanged"
    fi
  fi
  return $(( rc == 0 ? 0 : 1 ))
}

# DIVE-1357: a 'blocked' task is only legitimate if it carries a REVISIT anchor —
# a dependency edge (revisits via the DIVE-1355 cascade), a human need-gate
# (revisits on answer), or a park with a wake_at (revisits when the heartbeat
# passes it). This predicate is the single source of truth the block-producing
# verbs (block/need/park) all satisfy; it is what keeps the DIVE-1355 'blocked
# with no live reason' surface set permanently empty. 0 if $1 has >=1 anchor.
_task_has_block_anchor() {
  local id="$1"
  [[ "$(db "SELECT CASE WHEN
       EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id})
         OR need_type IS NOT NULL
         OR (parked_at IS NOT NULL AND wake_at IS NOT NULL)
     THEN 1 ELSE 0 END FROM tasks WHERE id=${id};")" == "1" ]]
}

cmd_task_block() {
  tasks_db_init
  local task="" by="" reason="" wake=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by=*)     by="${1#*=}" ;;
      --reason=*) reason="${1#*=}" ;;
      --wake=*)   wake="${1#*=}" ;;
      -*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)          [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task block <id|DIVE-N> --by=<id|DIVE-N>   (or --reason=<why> --wake=<when> to hold it as a timed park)"
  # DIVE-1357: with --by this is a dependency edge (the normal, self-revisiting
  # block). WITHOUT --by, the only honest hold is a timed park — so route a
  # reason+wake block through `task park`, and REFUSE a bare reasonless/dateless
  # block outright: that unreachable state is what filled the block graveyard.
  # Norm: attempt first — blocking is the exception you must justify with an anchor.
  if [[ -z "$by" ]]; then
    if [[ -n "$reason" && -n "$wake" ]]; then
      cmd_task_park "$task" --reason="$reason" --wake="$wake"
      return
    fi
    policy_refuse "$E_USAGE" bare-block-forbidden DIVE-1357 "$task" "a bare 'task block $task' with no reason or revisit date is forbidden (DIVE-1357) — pick a revisit anchor: 'task block $task --by=<id>' (a dependency), 'task park $task --reason=<why> --wake=<when>' (a timed hold), or 'task need $task --type=… --ask=…' (a human gate)"
  fi
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID" tident="$RESOLVED_TASK_IDENT"
  resolve_task_id "$by";   local bid="$RESOLVED_TASK_ID" bident="$RESOLVED_TASK_IDENT"
  [[ "$tid" != "$bid" ]] || fail "$E_VALIDATION" "a task can't block itself"
  db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES (${tid}, ${bid});
      UPDATE tasks SET status='blocked' WHERE id=${tid} AND status NOT IN ('done','cancelled');"
  ok "$tident blocked by $bident" '{task:($t|tonumber), task_ident:$ti, blocked_by:($b|tonumber), blocked_by_ident:$bi}' --arg t "$tid" --arg ti "$tident" --arg b "$bid" --arg bi "$bident"
}

cmd_task_unblock() {
  tasks_db_init
  local task="" by=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by=*) by="${1#*=}" ;;
      -*)     fail "$E_USAGE" "unknown flag: $1" ;;
      *)      [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task unblock <id|DIVE-N> [--by=<id|DIVE-N>]"
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID" tident="$RESOLVED_TASK_IDENT"
  if [[ -n "$by" ]]; then
    resolve_task_id "$by"; local bid="$RESOLVED_TASK_ID"
    db "DELETE FROM task_deps WHERE task_id=${tid} AND blocked_by=${bid};"
  else
    db "DELETE FROM task_deps WHERE task_id=${tid};"
  fi
  # Don't flip a still-pending human gate back to todo (DIVE-109): a task parked
  # on a human has need_type set and need_answered_at NULL. Only edge-blocks clear here.
  db "UPDATE tasks SET status='todo'
      WHERE id=${tid} AND status='blocked'
        AND (need_type IS NULL OR need_answered_at IS NOT NULL)
        AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${tid});"
  ok "$tident unblocked" '{task:($t|tonumber), task_ident:$ti}' --arg t "$tid" --arg ti "$tident"
}

# DIVE-356: `park` is the QUIET counterpart to `need`. A parked task is waiting
# on an external/time event the human need not act on — so it must NOT fire a
# CTA ping the way `need` does, and must NOT show in the human inbox. We set
# status=blocked + parked_at + park_reason and CLEAR any pending gate fields so
# the state is unambiguously "parked, no action" (inbox is need_type IS NOT
# NULL, so clearing need_type also drops it from the inbox). No notify.
# Dashboard reads: status='blocked' AND parked_at IS NOT NULL.
cmd_task_park() {
  tasks_db_init
  local task="" reason="" wake=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason=*) reason="${1#*=}" ;;
      --wake=*)   wake="${1#*=}" ;;
      -*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)          [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task park <id|DIVE-N> --reason=<why / what unblocks it> --wake=<YYYY-MM-DD[ HH:MM]|+Nd|+Nh>"
  # DIVE-1357: a park is anchor #3 for a 'blocked' task, and an anchor MUST carry
  # a revisit or it silently becomes the block graveyard DIVE-1355 has to sweep.
  # Require BOTH a --reason (why it's held / what unblocks it) and a --wake (when
  # to revisit). No known date? Pick a re-check date (--wake=+7d). Waiting on a
  # person is a human gate (`task need`), not a park.
  [[ -n "$reason" ]] || fail "$E_USAGE" "park needs --reason=<why / what unblocks it> — a reasonless hold is exactly the block graveyard DIVE-1357 forbids"
  [[ -n "$wake" ]]   || fail "$E_USAGE" "park needs --wake=<when to revisit> (e.g. --wake=+7d, +12h, or 'YYYY-MM-DD') so it can't rot; if the date is unknown pick a re-check date, or use 'task need' if you're waiting on a person"
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID" tident="$RESOLVED_TASK_IDENT"
  # DIVE-1453: park and a human gate share `status='blocked'` plus overlapping
  # need_* columns, so the UPDATE below would NULL an OPEN, UNANSWERED gate's
  # fields — silently destroying it (no answer, no audit row; the heartbeat wake
  # then unparks it to todo as if a human had cleared it). REFUSE to park over a
  # live gate: the task is already `blocked` on the human, so answer it first.
  # Predicate matches the gate_live flag used by inbox/show: need_type set, not
  # yet answered, task still open.
  local _live_gate; _live_gate=$(db "SELECT CASE WHEN need_type IS NOT NULL
        AND need_answered_at IS NULL AND status NOT IN ('done','cancelled')
      THEN 1 ELSE 0 END FROM tasks WHERE id=${tid};")
  if [[ "$_live_gate" == "1" ]]; then
    local _gt; _gt=$(db "SELECT COALESCE(need_type,'gate') FROM tasks WHERE id=${tid};")
    policy_refuse "$E_USAGE" park-over-open-gate DIVE-1453 "$tident" "$tident has an open ${_gt} gate awaiting a human — parking would silently destroy it (DIVE-1453). It is already blocked on the human, so no park is needed; resolve the gate first ('5dive task answer $tident …') if it's moot, then park."
  fi
  # DIVE-891: --wake gives a park a wake-up time — the heartbeat's TTL pass
  # auto-unparks (back to todo) once it passes, so "revisit in a week" stops
  # masquerading as a pending human gate. Accepts an absolute UTC timestamp or
  # a +Nd/+Nh relative form. Stored as the same ISO text every other timestamp
  # column uses, so plain string comparison against datetime('now') works.
  local wake_sql="NULL"
  if [[ -n "$wake" ]]; then
    local wake_ts=""
    case "$wake" in
      +*d) local _n="${wake#+}"; _n="${_n%d}"
           [[ "$_n" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "bad --wake '$wake' (use +Nd, +Nh, or 'YYYY-MM-DD[ HH:MM]')"
           wake_ts=$(db "SELECT datetime('now', '+${_n} days');") ;;
      +*h) local _n="${wake#+}"; _n="${_n%h}"
           [[ "$_n" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "bad --wake '$wake' (use +Nd, +Nh, or 'YYYY-MM-DD[ HH:MM]')"
           wake_ts=$(db "SELECT datetime('now', '+${_n} hours');") ;;
      *)   wake_ts=$(db "SELECT datetime($(sqlq "$wake"));")
           [[ -n "$wake_ts" ]] || fail "$E_VALIDATION" "bad --wake '$wake' (use +Nd, +Nh, or 'YYYY-MM-DD[ HH:MM]')" ;;
    esac
    wake_sql=$(sqlq "$wake_ts")
  fi
  # DIVE-2119: park retires a gate too (an ANSWERED one — a live gate is refused
  # above), so it goes through the same archive-then-clear as file/withdraw
  # rather than nulling half the columns itself. One transaction: the archive
  # must not survive without the reset, or the reset without the archive.
  db "BEGIN IMMEDIATE;
      $(_gate_archive_and_clear_sql park "id=${tid} AND status NOT IN ('done','cancelled')")
      UPDATE tasks
        SET status='blocked', parked_at=datetime('now'), park_reason=$(sqlq "$reason"),
            wake_at=${wake_sql},
            need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL
      WHERE id=${tid} AND status NOT IN ('done','cancelled');
      COMMIT;"
  local wake_note=""; [[ "$wake_sql" != "NULL" ]] && wake_note=" — wakes $(db "SELECT wake_at FROM tasks WHERE id=${tid};") UTC"
  ok "$tident parked (no action needed)${reason:+ — $reason}${wake_note}" \
     '{task:($t|tonumber), task_ident:$ti, parked:true, reason:$r, wake_at:(($w|select(length>0)) // null)}' \
     --arg t "$tid" --arg ti "$tident" --arg r "$reason" --arg w "$([[ "$wake_sql" != "NULL" ]] && db "SELECT wake_at FROM tasks WHERE id=${tid};" || echo "")"
}

# Clear a park -> back to todo (unless real dependency edges still block it).
cmd_task_unpark() {
  tasks_db_init
  local task="${1:-}"
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task unpark <id|DIVE-N>"
  resolve_task_id "$task"; local tid="$RESOLVED_TASK_ID" tident="$RESOLVED_TASK_IDENT"
  db "UPDATE tasks SET parked_at=NULL, park_reason=NULL, wake_at=NULL,
        status=CASE WHEN status='blocked'
                     AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${tid})
                    THEN 'todo' ELSE status END
      WHERE id=${tid} AND status NOT IN ('done','cancelled');"
  ok "$tident unparked" '{task:($t|tonumber), task_ident:$ti}' --arg t "$tid" --arg ti "$tident"
}

# --- Human Task Inbox (DIVE-103; parent feature DIVE-102) ----------------
# `need` parks a task on a human; `inbox` lists what's waiting; `answer`
# records the human's reply, unblocks, and pings the agent that hit the gate.

# OSS-21: precedent auto-clear policy switch. `5dive task precedent [on|off]`
# (bare / `status` reports state). When ON, a resolved tier-1 gate that matches
# proven human precedent clears itself at file-time (see cmd_task_need). Default
# is OFF fleet-wide until the OSS-16 policy owner (lodar) flips it. Read-only
# `status` needs no privilege; on/off is a policy write.
cmd_task_precedent() {
  tasks_db_init
  local sub="${1:-status}"
  case "$sub" in
    status|"")
      local v; v=$(_task_pref_get precedent_autoclear); v="${v:-off}"
      ok "precedent auto-clear: ${v}" \
         '{pref:"precedent_autoclear", value:$v}' --arg v "$v"
      ;;
    on|enable)
      _task_pref_set precedent_autoclear on
      # DIVE-2054: a fleet-wide pref toggle keyed off the active store — fenced.
      _task_store_audit_log "task precedent" "on" 0 -- "pref=precedent_autoclear" || true
      ok "precedent auto-clear: ON — resolved tier-1 gates with proven human precedent now clear at file-time" \
         '{pref:"precedent_autoclear", value:"on"}'
      ;;
    off|disable)
      _task_pref_set precedent_autoclear off
      # DIVE-2054: same as the "on" branch above — fenced.
      _task_store_audit_log "task precedent" "off" 0 -- "pref=precedent_autoclear" || true
      ok "precedent auto-clear: OFF — tier-1 gates always surface to a human" \
         '{pref:"precedent_autoclear", value:"off"}'
      ;;
    *)
      fail "$E_USAGE" "usage: 5dive task precedent [on|off|status]"
      ;;
  esac
}

# DIVE-1145: ship-gating routing policy switch. `5dive task routing [on|off]`
# (bare / `status` reports state). When ON, a NON-lead agent's decision gate
# (tier < 2) routes to the org lead first (see cmd_task_need) instead of pinging
# the human. Default is OFF fleet-wide until the org lead (main) flips it after
# reviewing the diff. True-human categories (tier-2-floored decisions, and every
# approval/manual/secret gate) are never routed. Read-only `status` needs no
# privilege; on/off is a policy write. Mirrors `task precedent` (OSS-21).
cmd_task_routing() {
  tasks_db_init
  local sub="${1:-status}"
  case "$sub" in
    status|"")
      local v; v=$(_task_pref_get gate_builder_routing); v="${v:-off}"
      ok "builder-gate routing: ${v}" \
         '{pref:"gate_builder_routing", value:$v}' --arg v "$v"
      ;;
    on|enable)
      _task_pref_set gate_builder_routing on
      # DIVE-2054: same reasoning as "task precedent" above — fenced.
      _task_store_audit_log "task routing" "on" 0 -- "pref=gate_builder_routing" || true
      ok "builder-gate routing: ON — a non-lead agent's tier<2 decision gate now routes to the org lead before pinging the human" \
         '{pref:"gate_builder_routing", value:"on"}'
      ;;
    off|disable)
      _task_pref_set gate_builder_routing off
      # DIVE-2054: same reasoning as "task routing on" above — fenced.
      _task_store_audit_log "task routing" "off" 0 -- "pref=gate_builder_routing" || true
      ok "builder-gate routing: OFF — decision gates ping the human directly" \
         '{pref:"gate_builder_routing", value:"off"}'
      ;;
    *)
      fail "$E_USAGE" "usage: 5dive task routing [on|off|status]"
      ;;
  esac
}

# DIVE-891/CNCL-14: the T2 category floor. The shipped defaults make money,
# public/customer comms, secrets, and destructive/irreversible actions a hard
# human gate; a valid company constitution replaces those classes as data.
# A matched class is ALWAYS a hard human gate, regardless of the tier the
# filing agent asked for — the floor is enforced here, not trusted from the
# filer. Matched case-insensitively over ask + title. The bias is deliberately
# toward false positives: a wrongly-ELEVATED gate costs the human one tap; a
# wrongly-lowered one would let a spend/publish call auto-apply. Bar-raise,
# same posture as gate-proof (a determined agent can still word around it —
# but only by loudly not-naming what it's asking for, which the ask text then
# fails to justify).
# DIVE-2241: the HUMAN-CLASS capability constants. A gate may DECLARE the
# capability its ask consumes with `--needs=<capability>`; exactly three names
# resolve to the paired human, and they resolve as CONSTANTS, not as a lookup.
#
# Why a constant and not the DIVE-2102 capability registry this was originally
# sequenced behind: that registry is a SUDOERS MIRROR — its vocabulary is five
# command grants and its holder key is `holder_agent`. lodar has no agent account
# and no sudoers entry, so these three are not "undeclared, pending declaration",
# they are INEXPRESSIBLE in that schema and always will be. A registry derived
# from a permission system answers "who may RUN this", never "who may DECIDE
# this". See community/wiki/an-oracle-that-mirrors-sudoers-answers-permission-\
# not-authority.md.
#
# Why a shipped shell constant is the DIVE-2099 anchor and a routing table is not:
# agents here hold NOPASSWD:ALL, so any table an agent can `sudo 5dive ... set` is
# an authority the beneficiary can grant itself — naming itself the holder of
# human_tap is one command. This list is a name sealed into the release artifact:
# changing it means changing the code that ships and passes review, and the
# installed binary's sha256 (5dive.sha256) no longer matches. There is deliberately
# NO write path — not root-guarded, ABSENT — because `require_root` answers "can
# this principal write here", which on this host is always yes (DIVE-2131).
#
#   human_tap        — a person's call: brand, strategy, an irreversible choice.
#   spend_authority  — billing / paid accounts. NOT smoke runs: lodar pre-approved
#                      those 2026-07-27, so a smoke gate declares nothing here.
#   secret_provision — a new token / credential must come FROM a human.
#
# Anything else — including a typo, and including a real agent capability like
# delegated_push — is UNRECOGNISED and falls through to today's routing untouched
# (see _gate_needs_human below). Absence means UNDECLARED, never non-holding.
_GATE_HUMAN_CAPABILITIES='human_tap spend_authority secret_provision'
# True iff $1 is one of the human-class constants. Whitespace-fenced substring
# match so no capability can hit by prefix (`human_tap_delegate` must NOT match).
#
# NORMALISE FIRST (Marcus, pre-merge read on #288). Exact matching makes a TYPO
# SILENTLY WEAKER: `--needs=human-tap` / `HUMAN_TAP` fell through to a tier-1,
# agent-clearable, TTL-auto-appliable gate while the filer believed they had just
# secured a human. The fall-through is loud — but the warn goes to whoever ran the
# command, and the common caller is an agent filing programmatically in a headless
# session: the reader least likely to see it and most likely to believe the
# declaration held.
#
# Why NORMALISE and not REFUSE-on-unknown, which was the other way to close it: an
# unknown name must keep falling through, because gh_push / root / delegated_push
# are deliberately unroutable here pending DIVE-2156, and hard-failing them would
# break a newer capability on an older CLI. Normalising kills the whole near-miss
# class (case + separator, the only two ways to write these names wrong) while
# leaving forward-compat intact. Deliberately NOT edit distance: a resolver that
# guesses what you meant is a new thing to be wrong about, and this one decides
# whether a human is required.
_gate_needs_human() {
  local c="${1:-}"
  [[ -n "$c" ]] || return 1
  c=$(printf '%s' "$c" | tr '[:upper:]-' '[:lower:]_')
  [[ " $_GATE_HUMAN_CAPABILITIES " == *" $c "* ]]
}

_GATE_T2_FLOOR_RX='spend|billing|invoice|charge|payment|refund|subscription|price|pricing|\$[0-9]|€[0-9]|publish|public post|announce|launch post|press|customer email|email customers|newsletter|blast|secret|credential|api key|token|password|delete|destroy|teardown|wipe|purge|drop[^.]{0,20}table|truncate|irreversible|revoke|dns|domain transfer'
_gate_tier2_floor_hit() {
  local text floor_rx="$_GATE_T2_FLOOR_RX" loaded_rx="" constitution_path="" ere_rc=0
  text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  # CNCL-14: production bundles include the council loader later in the file;
  # isolated task tests that source cmd_task alone retain the byte-identical
  # legacy regex. The overwhelmingly common no-file path must stay in-process:
  # do not start Node or materialize the embedded council runtime merely to
  # rediscover the same default. A present-but-malformed file still goes through
  # the loader and atomically resolves to the legacy regex.
  if declare -F _council_hard_gate_rx >/dev/null 2>&1 \
     && declare -F _council_constitution_path >/dev/null 2>&1; then
    constitution_path="$(_council_constitution_path 2>/dev/null || true)"
    if [[ -n "$constitution_path" && -f "$constitution_path" ]]; then
      # DIVE-1695: the on-disk constitution is trusted for the human-gate floor
      # ONLY when it matches the digest SEALED into the council lineage. The
      # sealed chain is the authority, not the forgeable file. A drifted/tampered
      # constitution.yaml — e.g. an unsanctioned edit that DELETES a hard class to
      # weaken the floor — must never be enforced: fail closed to the shipped
      # defaults, the exact verdict `council verify`/`convene` reach on drift.
      # No seal in the lineage yet (pre-constitution org) leaves CNCL-14 behavior
      # unchanged: the present file is loaded as before.
      if declare -F _council_constitution_drifted >/dev/null 2>&1 \
         && _council_constitution_drifted; then
        warn "constitution.yaml drifted from the sealed digest; enforcing the shipped tier-2 floor, not the on-disk file (amend via a constitutional-class council motion) (${constitution_path})"
      else
        loaded_rx="$(_council_hard_gate_rx 2>/dev/null || true)"
        if [[ -n "$loaded_rx" ]]; then
          floor_rx="$loaded_rx"
          # CNCL-28: engine.mjs can reject known JS-only syntax, but Bash is the
          # consumer and therefore the authority on POSIX ERE validity. Bash =~
          # returns 2 for an invalid expression; treat that as a whole-policy
          # failure so one bad class can never silently disable the T2 floor.
          [[ x =~ $floor_rx ]] || ere_rc=$?
          if (( ere_rc == 2 )); then
            warn "constitution hard_gates regex is invalid POSIX ERE; falling back to the shipped tier-2 floor (${constitution_path})"
            floor_rx="$_GATE_T2_FLOOR_RX"
          fi
        fi
      fi
    fi
  fi
  # DIVE-2301: the floor terms are a bare alternation with no boundary, so every
  # one of them is a SUBSTRING matcher: 'press' fires on suppression/expression/
  # compressed/depression, 'charge' on recharge/supercharge. Both live on the
  # NON-APPEALABLE list, so an ask that legitimately says "stop forging a
  # suppression" floored to tier 2 with no appeal path, on a word that has nothing
  # to do with press or money.
  #
  # The boundary is applied HERE, at the match site, and not by writing \b onto
  # each term in $_GATE_T2_FLOOR_RX. Two reasons, both measured:
  #
  #   1. $floor_rx is POLICY DATA and may have been replaced wholesale by a sealed
  #      constitution.yaml a few lines up. Anchoring the shipped default would
  #      leave the defect live in exactly the path where the policy is
  #      authoritative, and an org's own terms would still be substring matchers.
  #   2. \b CANNOT anchor the money terms. \b asserts a word/non-word transition,
  #      and '$' is not a word character, so `\b\$[0-9]` never matches: with a
  #      per-term \b, "approve $500 for ads" and "wire €900 to the vendor" stop
  #      flooring ALTOGETHER. That trades a false positive for a false NEGATIVE on
  #      the one class with no escape path. `(^|[^[:alnum:]_])` is a leading
  #      boundary that a non-word term can also sit behind, and it keeps both.
  #
  # LEADING only, deliberately: the terms are unanchored at the tail so inflections
  # keep matching (revoked, truncated, charges, pressing). Containment inside an
  # unrelated STEM is the defect; containment at the start of a longer word
  # (pressure, deleterious) still fires and is the accepted cost of that choice.
  [[ "$text" =~ (^|[^[:alnum:]_])($floor_rx) ]]
}

# DIVE-2224: NEVER concatenate two SUBJECTS into one classifier input. The ASK is
# what is being asked for, written at gate-filing time; the TITLE is what the
# ticket is about, written at ticket-creation time. They are different statements,
# and joining them with a space lets any BOUNDED-DISTANCE pattern match ACROSS the
# seam and fabricate a classification present in NEITHER field.
#
# Measured on origin/main with the shipped floor: ask "confirm we can drop" MISSES,
# title "table stakes: the onboarding rewrite" MISSES, the join HITS -- on
# `drop[^.]{0,20}table`, a database-deletion guard, between two texts about neither.
# Second instance of the shape after DIVE-1481's 20-char co-reference window, so it
# is a property of the JOIN and not of one regex; every classifier that reads both
# fields has it.
#
# Evaluating each field SEPARATELY preserves "either field can trip it" -- the
# DIVE-1957 title axis, which is load-bearing in both directions -- and removes only
# the phantoms. It cannot suppress a real single-field match, so it is strictly
# safer than the join for an UPGRADE classifier (the floor) and for a DOWNGRADE one
# (eng-ship / curation / internal-ops), where a fabricated hit is the dangerous
# direction because it REMOVES a human.
_gate_hit_either() {   # <predicate-fn> <ask> <title>
  local _fn="$1"; "$_fn" "${2-}" || "$_fn" "${3-}"
}

# DIVE-2224 PART 2 — lodar answered A on 2026-07-28. The floor's SUBJECT is the ASK.
#
# WHY. A title cannot be a REQUEST. It is written at ticket-creation time to describe
# a DEFECT; the ask is written at gate-filing time to describe what is being asked
# for. Flooring on the title treats a description as a request, and the filer cannot
# reword their way out of it -- DIVE-2216 could not file a push gate AT ALL, because
# 'deleted' sits in its own title. Measured over the 177 filed gates carrying an ask:
# 40 match on the ask (unchanged), 15 match TITLE-ONLY (move to the lead), 122 match
# neither -- so this moves ~27% of human gates to the lead, and understates it,
# because gates that could never be filed never entered the count.
#
# THE FALLBACK IS LOAD-BEARING, NOT A FOOTNOTE (olivia's condition, adopted). A
# works only while the ask is a TRUTHFUL statement of the request. The failure case
# is a lazy filing -- ask "approve this", title "delete all customer data" -- where
# the title genuinely IS the only statement of the request. An ask that names nothing
# is a badly-filed gate, and the floor FAILS CLOSED on it rather than trusting the
# filer. Bias is deliberately toward NOT-substantive: a wrongly-floored gate costs
# one tap, a wrongly-unfloored one lets a destructive ask reach an agent.
_GATE_ASK_FILLER_RX='approve|approved|approval|please|confirm|confirmation|ok|okay|yes|no|this|that|these|those|it|its|the|a|an|and|or|to|for|of|on|in|is|are|be|go|ahead|proceed|sign|off|signoff|thanks|thank|you|we|i|can|could|would|should|do|does|did|need|needs|needed|want|review|now|asap|me|my|our|us|us|pls|plz'
_gate_ask_substantive() {   # <ask> -> 0 when the ask states something of its own
  local t n
  t=$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g')
  t=$(printf '%s' "$t" | sed -E "s/\b(${_GATE_ASK_FILLER_RX})\b//g")
  n=$(printf '%s' "$t" | wc -w)
  (( n >= 3 ))
}
# _gate_floor_axis <ask> <title> -> echoes WHICH field decided, so every consumer
# (the filing floor and the approval/manual routing arm) makes the SAME call from
# the same inputs instead of each re-deriving it:
#   ask            floor fires -- hard human, unchanged from before DIVE-2224
#   title-fallback floor fires -- title matched and the ask states nothing (olivia's
#                  fail-closed condition)
#   title          floor does NOT fire -- lead-routed, stamped floored_by=title
#   none           floor does not fire
_gate_floor_axis() {
  local a="${1-}" t="${2-}"
  if _gate_tier2_floor_hit "$a"; then printf 'ask'; return 0; fi
  if _gate_tier2_floor_hit "$t"; then
    if _gate_ask_substantive "$a"; then printf 'title'; else printf 'title-fallback'; fi
    return 0
  fi
  printf 'none'
}

# DIVE-1359: the ENG-SHIP gate class. An eng ship / merge / diff / deploy
# approval is NOT a human call — it is the org lead's (Marcus) to clear. But a
# builder can file one as a hard-human gate (default, or explicit --tier=2),
# which (a) pings the paired human and (b) is UNCLEARABLE by the lead, since
# tier-2 is human-only by system rule. Observed twice: dev (DIVE-1349/1314) +
# codex (DIVE-907) escalated eng ship approvals to the human. We classify these
# by kind and force them DOWN to a lead-routed tier-1 — the mirror of the T2
# floor (which forces true-human categories UP to tier-2). The true-human floor
# ALWAYS wins and is checked FIRST: an eng gate that also names money / secrets /
# destructive stays tier-2 (a "ship the pricing change" gate is still a
# human call). Bias, like the floor, is deliberate: a wrongly-classified eng gate
# costs the lead one clear; the floor guards the only genuinely-human direction.
# DIVE-1555: a delegated push-for-review (5dive push / DIVE-1376) is an eng-ship
# action — it pushes a FEATURE branch for PR review (no merge, no prod touch), so
# it must file as a lead-routed tier-1, not a tier-2 human-only approval that
# lands in the human's DM. `push to (main|prod|...)` deliberately does NOT match a
# feature-branch push-for-review, so name it explicitly here.
# DIVE-1698: a VERIFIED builder ship — "push the tested commit to GitHub + roll to
# the fleet" (DIVE-1674 telegram undefined-guard) — is the same eng-ship kind, yet
# it missed the classifier: `push to (main|prod|origin)` excludes "to GitHub", and
# `roll ?out` excludes "roll/rolling to the fleet". Both stayed at the approval
# tier-2 default → the human's DM. Add `push … github` and `roll … fleet` /
# `fleet roll` so a tested-code push+fleet-roll files as a lead-routed tier-1. The
# true-human floor still runs FIRST and wins (a "push the pricing change" gate
# stays human), so these can only ever cost the lead one clear.
# _gate_authenticated_actor — DIVE-2004. The agent identity the KERNEL enforced for
# this invocation, or EMPTY when it cannot be established. This is deliberately NOT
# `task_actor`: that resolves `--from=<who>` verbatim, so it answers "who does the
# caller SAY they are" (provenance, right for the audit record) and must never be
# asked "who is the caller" (authentication). Two trustworthy sources:
#   1. the real process user — `agent-X` can only be reached by actually being X.
#   2. `$SUDO_UID`, but ONLY at EUID 0 (DIVE-1413): sudo sets it, and a non-root
#      process forging it cannot also become root. Below EUID 0 it is a plain env
#      var, which is why DIVE-950 dropped the agent-forgeable `--proof` form.
# FAILS CLOSED by design: neither source resolving means "unidentified", never
# "trusted". The cost of a false empty is re-filing a gate; the cost of a false
# identity is a self-authorized delegated push.
# The dashboard path is unaffected and needs no marker: shelld runs as `claude`
# (a NON-agent user) and sends `--human`, so those answers are `human:*` — already
# authorized everywhere `lead:*` is, and never in want of a lead stamp.
_gate_authenticated_actor() {
  local u; u=$(id -un 2>/dev/null || echo '')
  if [[ "$u" == agent-* ]]; then printf '%s' "${u#agent-}"; return; fi
  if [[ "$(id -u 2>/dev/null || echo 1)" == "0" && -n "${SUDO_UID:-}" ]]; then
    local su; su=$(getent passwd "$SUDO_UID" 2>/dev/null | cut -d: -f1)
    [[ "$su" == agent-* ]] && { printf '%s' "${su#agent-}"; return; }
  fi
  printf ''
}

# _gate_agent_for_uid <uid> — the agent name owning a numeric uid, or EMPTY. Used
# to re-check a STORED `need_answered_uid` (DIVE-756 stamps the real pre-sudo
# invoker) against a claimed `need_answered_by`, so a `--from` spoof is visible
# after the fact and not only at answer time.
_gate_agent_for_uid() {
  local uid="${1:-}"; [[ "$uid" =~ ^[0-9]+$ ]] || { printf ''; return; }
  local u; u=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
  [[ "$u" == agent-* ]] && printf '%s' "${u#agent-}" || printf ''
}

_GATE_ENG_SHIP_RX='\bmerg(e|es|ed|ing)\b|pull request|\bpr\b|\bdiff\b|ship it|ship the|ship this|\bship(ping|ped)\b|deploy|redeploy|roll ?out|\broll(ing|ed)? out\b|land the|land it|land this|\bland(ing|ed)\b|rebase|hotfix|cut a branch|cut the release|push(es|ed|ing)? to (main|prod|production|origin)|push[^.]*github|delegated push|push[- ]for[- ]review|push .*(branch|for review|for a? ?pr|for code review)|5dive push|roll[^.]*fleet|fleet[- ]?roll|code review|approve the (merge|diff|change|pr|build|deploy|ship|commit)|build\.sh|smoke test|ci\b'
_gate_eng_ship_hit() {
  local text; text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$text" =~ $_GATE_ENG_SHIP_RX ]]
}

# DIVE-2099: the org lead's STANDING authority to clear an ENGINEERING approval
# gate. lodar granted it 2026-07-26 ("agreed") in response to main asking for it
# directly; main filed the ticket rather than implementing it because the
# requester is the beneficiary. The boundary is therefore deliberately narrow and
# the mechanism is deliberately visible in the record.
#
# WHAT IT ADDS: DIVE-1182/1243 already let the lead clear a gate that was ROUTED
# to them at filing time (routed_reviewer == the authenticated caller). That is
# the only lead-clear path today, so an engineering approval that reached the
# human WITHOUT routing — pref off, filer-is-lead, a re-route that NULLed the
# reviewer, or a gate filed before routing existed — is human-only forever, even
# though its entire content is a judgement the lead can make. Three of the 14
# gates in lodar's inbox on 2026-07-26 were exactly that. This predicate is the
# standing authority: no routing required, but every other guard stays.
#
# WHY IT IS NOT "another keyword match" (design note 1 on the ticket, and the
# DIVE-2089 trap): a keyword match here would be a false-NEGATIVE machine — the
# dangerous polarity, where the lead self-clears something that should have gone
# to the human. So vocabulary is never sufficient on its own. Eligibility is a
# CONJUNCTION of an unforgeable identity check, a structural type/tier check, a
# positive engineering classification, AND two independent exclusion tests. Text
# can only ever REMOVE authority here; the guards that GRANT it are structural.
#
# FAIL CLOSED (design note 2): every unknown answers "no". An empty ask, an empty
# or legacy-NULL tier, an unresolvable org lead, an unauthenticated caller, or a
# text that does not positively classify as engineering all deny. An
# unclassifiable gate is a human gate.
_GATE_LEAD_STANDING_DENY_RX='customer.{0,20}(box|vm|host|server|instance|machine|account|repo|data|db)|client.{0,20}(box|vm|host|server|instance|machine)|(on|to|their) (a )?customer.s|marketing site|landing page|5dive\.com|public repo|docs site|blog post|\bbrand\b|rebrand|positioning|pricing page|go.to.market|\bstrategic\b|public relations|\bpr (agency|firm|retainer)\b|agent (create|creation|rm|remove|delete|fire|hire|repurpose|provision)|(create|remove|delete|fire|hire|repurpose|provision)( an?| the)? agent|sudoers|sudo (grant|access|rule|rules|policy)|grant.{0,20}sudo|root access|fleet privilege|privilege (grant|change|escalat)'
_gate_lead_standing_denied() {
  local text; text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$text" =~ $_GATE_LEAD_STANDING_DENY_RX ]]
}
# _gate_lead_standing_eligible <need_type> <tier> <text>  -> 0 when the standing
# authority reaches this gate. <text> is the ask AND the title, because the gate
# classifiers on both sides of this file read both (DIVE-1957) and a scope word
# that appears only in the title must still be able to REMOVE authority.
_gate_lead_standing_eligible() {
  # DIVE-2224: <ask> and <title> are SEPARATE arguments. They used to arrive
  # pre-joined (`ask||' '||title` in SQL), which let a bounded-distance pattern
  # straddle the seam -- and here a phantom `_gate_eng_ship_hit` GRANTS standing
  # authority on a gate neither field classifies as engineering. The 4th argument
  # is optional so a 3-argument caller keeps its exact single-text behaviour.
  local nt="${1:-}" tier="${2:-}" text="${3:-}" text2="${4-}"
  # Type: `approval` ONLY. `secret` is never lead-clearable at any tier;
  # `manual` is by definition a step only a person can perform; `access` already
  # has its own DIVE-1243 route; `decision` is lead-clearable by type already and
  # needs no new authority. Narrowing to one type keeps the blast radius of a
  # misclassification to the one class lodar actually granted.
  [[ "$nt" == "approval" ]] || return 1
  # Tier: exactly 1. Tier 2 is the hard human floor and this authority does NOT
  # pierce it — an engineering gate that got floored to 2 (DIVE-2089's subject-
  # matter misread) stays human-only until 2089 fixes the floor itself. Empty /
  # legacy-NULL / 0 deny: an unknown tier is not a tier-1 gate.
  [[ "$tier" == "1" ]] || return 1
  # A gate with nothing to classify cannot be classified as engineering.
  [[ -n "${text//[[:space:]]/}" || -n "${text2//[[:space:]]/}" ]] || return 1
  # Positive engineering evidence. Absence of this is a DENY, not a default —
  # this is the fail-closed direction: "not recognised as engineering" routes to
  # the human exactly as it does today.
  _gate_hit_either _gate_eng_ship_hit "$text" "$text2" || return 1
  # Exclusion 1 — the shared true-human floor (money, secrets/credentials,
  # destructive, publish/press/customer-comms, dns). Belt-and-braces: a tier-1
  # gate should already have failed this floor at filing, but a row filed before
  # the floor existed, or one whose floor terms live in a title added later, must
  # not inherit authority from a stale tier column.
  ! _gate_hit_either _gate_tier2_floor_hit "$text" "$text2" || return 1
  # Exclusion 2 — the ticket's EXPLICITLY OUT OF SCOPE list that the T2 floor does
  # NOT already cover: a customer's box, our customer-facing/public surfaces, a
  # brand or strategic call, and fleet privilege changes.
  ! _gate_hit_either _gate_lead_standing_denied "$text" "$text2" || return 1
  return 0
}

# DIVE-2099 iteration 2 — WHO holds the standing authority, anchored to a NAMED
# agent. lodar answered the tier-2 decision gate 2026-07-27 with
# `anchor-to-named-agent`, over `keep-chart-derived`.
#
# WHY THE ORG CHART CANNOT BE THE SOURCE (what iteration 1 got wrong): iteration 1
# resolved the holder live at clear time with `_gate_route_reviewer(filer)`, which
# reads `agents_org.reports_to`. DIVE-2124 put `require_root` on `org set`/`org rm`,
# but every agent on this host holds (ALL) NOPASSWD:ALL, so `sudo 5dive org set` is
# still reachable by any of them, and the column recording who wrote the row
# (`by_claimed`) is caller-supplied and explicitly labelled non-evidence
# (residual: DIVE-2131). Deriving the authority from a table the beneficiary can
# rewrite is a self-grant path on the very authority being granted: rewrite the
# chart to make yourself somebody's lead, then clear their gate as your own lead.
#
# THE ANCHOR: the agent NAMED in the constitution, trusted only when the on-disk
# constitution still matches the digest SEALED into the council lineage. This is
# the DIVE-1695 precedent, already load-bearing for the tier-2 hard-gate floor a
# few hundred lines up: the file is forgeable, the chain is not. An agent CAN
# `sudo` a new name into constitution.yaml — and the moment it does, the live
# sha256 stops matching the sealed one, `_council_constitution_drifted` says
# DRIFTED, and this function denies EVERYONE, including the name that was there
# before. Re-sealing is a constitutional-class council motion (2/3 + full quorum +
# founder veto), which no agent can convene against itself. So the write is not
# prevented, it is made self-defeating and tamper-evident — which is the property
# `require_root` alone does not have on a NOPASSWD:ALL host.
#
# FAIL CLOSED at every unknown: no council loader in scope, no sealed digest in
# the lineage (a bare constitution.yaml is then just a file anyone can write), a
# drifted file, a missing file, no `authority.eng_approval_lead` key, an empty
# value, or a value that is not a plain agent name -> no standing authority for
# anyone. Absence of a name is NOT "everyone" and is NOT "fall back to the chart".
#
# The org chart is still read for ROUTING (`_gate_route_reviewer`, unchanged) and
# the resolved filer is still recorded in the audit row — but neither is consulted
# for AUTHORITY any more. That separation is what the required test pins: mutate
# the chart after filing and the clear must still be refused.
_GATE_STANDING_LEAD_NAME_RX='^[a-z0-9][a-z0-9_-]{0,31}$'
# Node-free reader for the one constitution field this authority needs, mirroring
# `_council_constitution_drifted`'s reason for existing: the gate path must not
# spin up the Node runtime (and must stay testable when cmd_task.sh is sourced
# alone). Deliberately a STRICT subset of YAML — a top-level `authority:` block
# and a scalar `eng_approval_lead:` inside it. Anything it cannot parse reads as
# absent, which denies.
_gate_constitution_standing_lead() {
  local path="${1:-}" line val in_block=0
  [[ -n "$path" && -f "$path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # A non-indented line starts a new top-level key: we are inside `authority:`
    # only while that key is the current one. Nested keys elsewhere in the file
    # named `eng_approval_lead` therefore cannot grant anything.
    if [[ "$line" =~ ^[^[:space:]] ]]; then
      if [[ "$line" =~ ^authority:[[:space:]]*(#.*)?$ ]]; then in_block=1; else in_block=0; fi
      continue
    fi
    (( in_block )) || continue
    [[ "$line" =~ ^[[:space:]]+eng_approval_lead:[[:space:]]*(.*)$ ]] || continue
    val="${BASH_REMATCH[1]}"
    val="${val%%#*}"                       # strip a trailing comment
    val="${val#"${val%%[![:space:]]*}"}"   # ltrim
    val="${val%"${val##*[![:space:]]}"}"   # rtrim
    val="${val%\"}"; val="${val#\"}"       # unquote "…"
    val="${val%\'}"; val="${val#\'}"       # unquote '…'
    [[ -n "$val" ]] || return 1
    printf '%s' "$val"
    return 0
  done < "$path"
  return 1
}
# _gate_standing_lead -> prints the named holder on stdout, or nothing + rc 1.
_gate_standing_lead() {
  declare -F _council_constitution_path >/dev/null 2>&1 || return 1
  declare -F _council_sealed_constitution_digest >/dev/null 2>&1 || return 1
  declare -F _council_constitution_drifted >/dev/null 2>&1 || return 1
  # A constitution that was never sealed carries no authority: without a lineage
  # record to drift FROM, the file is exactly as writable as the org chart, and
  # anchoring to it would reproduce the self-grant path in a different file.
  local sealed; sealed="$(_council_sealed_constitution_digest 2>/dev/null || true)"
  [[ -n "$sealed" ]] || return 1
  # Sealed but the live bytes differ (or the file is gone) -> deny everyone.
  ! _council_constitution_drifted || return 1
  local path; path="$(_council_constitution_path 2>/dev/null || true)"
  local name; name="$(_gate_constitution_standing_lead "$path" 2>/dev/null || true)"
  # A plain agent name only. Rejecting `human:main`, `*`, `all`, a path or a shell
  # metacharacter keeps this a name comparison and nothing more.
  [[ "$name" =~ $_GATE_STANDING_LEAD_NAME_RX ]] || return 1
  printf '%s' "$name"
}

# DIVE-2233 — the SECOND authority that was still derived from the org chart, and the
# one DIVE-2099 explicitly left alone ("the org chart is still read for ROUTING,
# unchanged"). Routing turned out not to be only routing:
#
#   _gate_route_reviewer(filer)  reads agents_org.reports_to           (agent-writable)
#     -> UPDATE tasks SET routed_reviewer=<that name>                  (persisted at FILE time)
#       -> cmd_task_answer: nt in approval|manual|access AND actor == routed_reviewer
#          -> _lead_clear=1 -> that agent CLEARS A HUMAN-ONLY GATE
#
# So `sudo 5dive org set <victim> --manager=<me>` is a one-command self-grant: re-parent
# a builder, wait for (or provoke) their next ship gate, and clear it as their lead. The
# `require_root` on `org set` (DIVE-2124) does not help on a NOPASSWD:ALL host, and the
# `by_claimed` record of who wrote the row is caller-supplied and explicitly non-evidence.
#
# THE SPLIT THAT FIXES IT: routing and authorization are two different questions and only
# one of them has to be trustworthy.
#   - WHO IS PINGED stays chart-derived. That is a notification: routing a gate to the
#     wrong agent wastes their attention, it does not clear anything. Left unchanged so
#     re-parenting an org keeps working the way an org expects.
#   - WHO MAY CLEAR comes from these sealed bytes and nowhere else. An agent that writes
#     itself into somebody's `reports_to` still gets the ping and still cannot clear; the
#     gate falls through to the human exactly as if no lead had been named.
# Deriving BOTH from the chart is what made the write an authority grant. Deriving only
# the ping from it makes the same write inert.
#
# The seal is what carries the property, same as DIVE-2099: an agent CAN sudo a new name
# into constitution.yaml, and the moment it does the live sha256 stops matching the digest
# sealed in the council lineage, `_council_constitution_drifted` says DRIFTED, and this
# returns EMPTY — denying every lead including the legitimate ones. Re-sealing is a
# constitutional-class motion (2/3 + full quorum + founder veto) no agent convenes against
# itself. The write is not prevented, it is made self-defeating.
#
# FAIL CLOSED at every unknown (no council loader, no sealed digest, drift, missing file,
# no key, empty list, a malformed entry) -> NO name may lead-clear. Absence is not
# "everyone" and is NOT "fall back to the chart" — falling back would restore the exact
# path this closes. Note the operational consequence and that it is intended: on a box
# whose constitution does not name `gate_clear_leads`, routed lead-clear is INERT and
# every routed approval/manual/access gate waits for a human. That is a real posture
# change, so the refusal is logged with a REASON (see `_gate_clear_lead_denied_reason`)
# rather than being a silent nothing — an authority that quietly stopped working is the
# failure mode DIVE-1935 cost us a day on.
_GATE_CLEAR_LEAD_NAME_RX="$_GATE_STANDING_LEAD_NAME_RX"
# Node-free reader for `authority.gate_clear_leads`, a STRICT subset of YAML: a top-level
# `authority:` block containing a `gate_clear_leads:` key whose value is a BLOCK SEQUENCE
# of plain scalars. Prints one name per line. A flow sequence (`[a, b]`), a nested map, or
# anything else it cannot parse reads as ABSENT, which denies — a reader that guessed at a
# shape it does not really support would be granting authority from bytes nobody verified.
_gate_constitution_clear_leads() {
  local path="${1:-}" line val in_block=0 in_list=0 n=0
  [[ -n "$path" && -f "$path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # A non-indented line starts a new top-level key. `gate_clear_leads` nested under any
    # other top-level key therefore grants nothing.
    if [[ "$line" =~ ^[^[:space:]] ]]; then
      if [[ "$line" =~ ^authority:[[:space:]]*(#.*)?$ ]]; then in_block=1; else in_block=0; fi
      in_list=0
      continue
    fi
    (( in_block )) || continue
    # An indented NON-list key ends the sequence — `gate_clear_leads:` followed by
    # `eng_approval_lead:` must not swallow the latter as an entry.
    if [[ ! "$line" =~ ^[[:space:]]+- ]]; then
      if [[ "$line" =~ ^[[:space:]]+gate_clear_leads:[[:space:]]*(.*)$ ]]; then
        val="${BASH_REMATCH[1]}"; val="${val%%#*}"
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        # Only an EMPTY value opens a block sequence. An inline value here is a scalar or a
        # flow sequence — neither is the supported shape, so refuse the whole key rather
        # than parse half of `[a, b]` into a name.
        [[ -n "$val" ]] && return 1
        in_list=1
      else
        in_list=0
      fi
      continue
    fi
    (( in_list )) || continue
    [[ "$line" =~ ^[[:space:]]+-[[:space:]]*(.*)$ ]] || continue
    val="${BASH_REMATCH[1]}"
    val="${val%%#*}"                       # strip a trailing comment
    val="${val#"${val%%[![:space:]]*}"}"   # ltrim
    val="${val%"${val##*[![:space:]]}"}"   # rtrim
    val="${val%\"}"; val="${val#\"}"       # unquote "…"
    val="${val%\'}"; val="${val#\'}"       # unquote '…'
    [[ -n "$val" ]] || continue
    printf '%s\n' "$val"
    n=$((n+1))
  done < "$path"
  (( n > 0 ))
}
# _gate_clear_leads -> prints the sealed allowlist, one name per line, or nothing + rc 1.
# Same fail-closed chain as _gate_standing_lead, for the same reasons.
_gate_clear_leads() {
  declare -F _council_constitution_path >/dev/null 2>&1 || return 1
  declare -F _council_sealed_constitution_digest >/dev/null 2>&1 || return 1
  declare -F _council_constitution_drifted >/dev/null 2>&1 || return 1
  # Never sealed = the file is exactly as writable as the org chart, so anchoring to it
  # would reproduce the self-grant in a different file.
  local sealed; sealed="$(_council_sealed_constitution_digest 2>/dev/null || true)"
  [[ -n "$sealed" ]] || return 1
  ! _council_constitution_drifted || return 1
  local path; path="$(_council_constitution_path 2>/dev/null || true)"
  local names; names="$(_gate_constitution_clear_leads "$path" 2>/dev/null || true)"
  [[ -n "$names" ]] || return 1
  # Validate EVERY entry and refuse the whole list if any one is malformed. Dropping the
  # bad entry and keeping the rest would let a hostile edit that fails validation still
  # shift the effective allowlist, which is a partial grant from bytes we just rejected.
  local nm
  while IFS= read -r nm; do
    [[ "$nm" =~ $_GATE_CLEAR_LEAD_NAME_RX ]] || return 1
  done <<< "$names"
  printf '%s\n' "$names"
}
# Is $1 named in the sealed allowlist? rc 0 = yes. Everything else = no.
_gate_clear_lead_allowed() {
  local who="${1:-}" nm; [[ -n "$who" ]] || return 1
  local names; names="$(_gate_clear_leads 2>/dev/null || true)"
  [[ -n "$names" ]] || return 1
  while IFS= read -r nm; do [[ "$nm" == "$who" ]] && return 0; done <<< "$names"
  return 1
}
# Why was a routed lead-clear refused? Emitted into the audit row so "the seal is not set
# up on this box" is distinguishable from "this agent is not a lead" — the two demand
# completely different responses (convene a motion vs. investigate a self-grant attempt)
# and are indistinguishable from the gate's behaviour alone.
_gate_clear_lead_denied_reason() {
  declare -F _council_sealed_constitution_digest >/dev/null 2>&1 || { printf 'no-council-loader'; return; }
  local sealed; sealed="$(_council_sealed_constitution_digest 2>/dev/null || true)"
  [[ -n "$sealed" ]] || { printf 'constitution-unsealed'; return; }
  if _council_constitution_drifted 2>/dev/null; then printf 'constitution-drifted'; return; fi
  local names; names="$(_gate_clear_leads 2>/dev/null || true)"
  [[ -n "$names" ]] || { printf 'no-gate-clear-leads-key'; return; }
  printf 'not-a-sealed-lead'
}

# DIVE-1381: the CONTENT-CURATION gate class — the third downgrade kind, mirror
# of the eng-ship class (DIVE-1359) for our early-stage content surfaces
# (OpenAgent / character-packs / the daily persona drip). Surfaced by DIVE-1366:
# a persona/pack QUEUE-READINESS approval is not a human call — per ship-gating,
# OpenAgent/character-packs is an early-stage surface, safe to push, no approval
# gate to the paired human; it is the org lead's (Marcus) to clear. But the T2
# floor matches 'publish' in the ask/title and forces the gate hard-human
# (tier-2 = unclearable by the lead), the exact wall DIVE-1366 hit. This class
# marks curation/queue-readiness asks so the caller below can downgrade them to
# a lead-routed tier-1 — BUT ONLY when the *sole* reason the floor fired was a
# content-publish-LATER term (see _GATE_CONTENT_PUBLISH_RX): the real publish
# happens downstream via the drip, not now. The true-human floor still wins for
# a genuine publish-NOW / press / customer-comms / money / secret /
# destructive ask — the caller re-tests the floor with the publish-later terms
# stripped and only downgrades if nothing else trips it. secret/manual are never
# curation; filer-is-lead ⇒ no reviewer ⇒ not downgraded.
# NB word-anchored where a bare substring would over-match: \bpersonas?\b (not
# 'personal'/'personalize'), \bcurat (curate/curation/curator, not 'accurate').
_GATE_CONTENT_CURATION_RX='\bpersonas?\b|character.?pack|char.?pack|openagent|promote.?queue|drip queue|drip schedule|queue.?readiness|ready for the (queue|drip)|ready to (queue|drip)|\bcurat|skill.?set|gallery (card|pack|entry)'
_gate_content_curation_hit() {
  local text; text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$text" =~ $_GATE_CONTENT_CURATION_RX ]]
}
# The content-publish-LATER terms — the subset of the T2 floor whose match is
# safe to carve out for a curation-shaped ask, because for our drip the actual
# publish is a downstream, automated step, not the thing being approved now.
# Deliberately NARROW: 'press', 'customer email', 'newsletter', and 'blast'
# and every money/secret/destructive term stay in the floor (they are genuine
# human calls even in a curation context). Used to compute the residual-floor
# test in cmd_task_need.
_GATE_CONTENT_PUBLISH_RX='publish|public post|announce|launch post'

# DIVE-1480: the INTERNAL-OPS / RECOVERY decision class — the fourth downgrade
# kind, mirror of eng-ship (DIVE-1359) and content-curation (DIVE-1381). Surfaced
# by the 2026-07-19 board wipe: dev's STEER-1 "keep vs discard my work / rebuild
# the board" decision gate (filed FOR the lead) got FORCED to hard-human tier-2
# purely because its ask NARRATED the wipe — 'destroyed', 'wiped', 'purge' — so
# the T2 destructive floor tripped and it landed on lodar instead of Marcus, whose
# call it actually was. A decision about our OWN control-plane state (the task
# board / an agent's uncommitted work / a wipe recovery) is the org lead's to
# clear, not the paired human's. This class marks such asks so the caller
# downgrades them to a lead-routed tier-1, BUT ONLY when the SOLE reason the floor
# fired was an INTERNAL-destructive term (see _GATE_INTERNAL_DESTRUCTIVE_RX): a
# genuine prod/customer/infra destructive ask (drop a prod table, teardown infra,
# revoke a key, a dns/domain change) keeps those terms in the residual floor and
# stays hard-human. The class regex is deliberately NARROW — task-board / dev-
# workspace / recovery vocabulary that essentially never appears in an external
# destructive gate — so it is the real safety gate, not the term carve-out.
# secret/manual are never internal-ops; filer-is-lead ⇒ no reviewer ⇒ not
# downgraded (a lead may legitimately pin a human gate).
_GATE_INTERNAL_OPS_RX='task ?board|tasks?\.db|\btask db\b|the backlog|board (wipe|wiped|reset|reconstruct|rebuild|recovery)|(wipe|wiped|reset|lost|rebuild|reconstruct|restore).{0,20}(board|backlog)|my (uncommitted|wip|in.?flight|local|unmerged) (work|changes|edits|branch)|discard (my|the|dev.s) (work|changes|edits|wip)|keep (vs|or) discard|steer-[0-9]|the audit (trail|log)|heartbeat log'
_gate_internal_ops_hit() {
  local text; text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$text" =~ $_GATE_INTERNAL_OPS_RX ]]
}
# The internal-destructive terms — the subset of the T2 floor whose match is safe
# to carve out for an internal-ops ask, because they NARRATE/act-on our own
# recoverable dev state, not production. Deliberately NARROW: 'teardown', 'drop
# table', 'revoke', 'dns', 'domain transfer' STAY in the floor (real infra / prod
# / access, human calls even in a recovery context), as does every money / secret
# / publish term. Used to compute the residual-floor test below.
_GATE_INTERNAL_DESTRUCTIVE_RX='destroy|wipe|purge|delete|irreversible'

# DIVE-1481: the internal-ops OBJECT vocabulary — the control-plane nouns a
# carved-out destructive term is allowed to act on (task board / tasks.db /
# backlog / an agent's own wip). The residual test below strips a destructive
# term ONLY when it is CO-REFERENT (adjacent) to one of these, never merely
# co-present in the same ask. That closes the residual gap DIVE-1480 left open:
# 'delete the production database as part of board recovery' matches the
# internal-ops CLASS ('board recovery') and has its 'delete' stripped by a blanket
# carve-out, silently downgrading a PROD-destructive action to lead review — but
# 'delete' governs 'production database', not the board, so it must stay
# hard-human. `\bboard\b` (not bare 'board') so 'dashboard'/'keyboard' don't match.
_GATE_INTERNAL_OBJECT_RX='task ?board|tasks?\.db|\btask db\b|backlog|\bboard\b|\bwip\b|uncommitted|in.?flight|unmerged|audit (trail|log)|heartbeat log'
# _gate_internal_residual <text>: lower-cases <text>, then removes each internal-
# destructive term ONLY where an internal-ops object sits within ~20 chars on
# either side (active 'wipe the board' OR passive 'the board was wiped'). A verb
# whose object is external (a prod table, a customer record) is left intact so the
# residual still trips the T2 floor and the gate stays hard-human. Iterates to a
# fixpoint so several verbs sharing one object all clear; non-/g single pass per
# step keeps the object available for the next verb.
# DIVE-1487: external destructive TARGETS — a prod/customer/infra object. When one
# appears anywhere in the ask, a destructive verb may govern IT rather than (or in
# addition to) the internal object — in a compound ("delete the board and the
# production database"), across a coordination span, or over a passive window the
# 20-char heuristic mis-reads ("wipe the board then delete the prod customer
# records"). The nearest-object active/passive strip can't tell these from a purely
# internal ask, so we REFUSE to strip any destructive verb once an external target
# is present: the verb survives into the residual, trips the T2 floor, and the gate
# stays hard-human. Biased to over-elevate (the safe direction); the carve-out then
# only fires for asks whose destructive framing is PURELY internal. Narrowly
# external (prod/customer/live/user-data) so a plain internal ask ("discard my
# uncommitted work", "rebuild the board from the audit log") is untouched.
_GATE_EXTERNAL_TARGET_RX='\bprod\b|production|customers?\b|user data|\bpii\b|live (data|site|db|database)|user records?|customer records?'
_gate_internal_residual() {
  local text prev; text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  # An external prod/customer target is present → a destructive verb may govern it;
  # do not strip, so the residual keeps the verb and the T2 floor still fires.
  [[ "$text" =~ $_GATE_EXTERNAL_TARGET_RX ]] && { printf '%s' "$text"; return; }
  local i=0
  while [[ $i -lt 8 ]]; do
    prev="$text"
    # active: destructive verb governs a following internal object
    text=$(printf '%s' "$text" | sed -E "s/(${_GATE_INTERNAL_DESTRUCTIVE_RX})([^.]{0,20}(${_GATE_INTERNAL_OBJECT_RX}))/ \2/")
    # passive: internal object precedes the destructive verb
    text=$(printf '%s' "$text" | sed -E "s/((${_GATE_INTERNAL_OBJECT_RX})[^.]{0,20})(${_GATE_INTERNAL_DESTRUCTIVE_RX})/\1 /")
    [[ "$text" == "$prev" ]] && break
    i=$((i+1))
  done
  printf '%s' "$text"
}

# DIVE-2089: the DECLARED-DISCUSSION appeal — the fifth (and last text-driven)
# treatment of the T2 floor, and the only one that does NOT try to infer intent
# from vocabulary.
#
# THE DEFECT IT ANSWERS. The floor reads SUBJECT MATTER and picks the audience
# from it. dev3 filed a tier-1 SIZING gate on DIVE-2078 — "how should we model
# capability vs clearance" — and it was floored hard-human because the ask
# contains the words "credentials" and "privileged". The gate DISCUSSES
# credential handling as a design question and performs NO credential operation.
# Talking about credentials is not handling credentials.
#
# WHY NOT ANOTHER CLASS REGEX. eng-ship / curation / internal-ops all guess the
# KIND from more vocabulary, and DIVE-2099's design note 1 is explicit that
# adding a sixth guesser reproduces this bug with the polarity reversed — a
# false NEGATIVE there routes a real secret gate to an agent. There is no
# phrasing that reliably separates "discussing X" from "doing X": that is a fact
# about the filer's intent, not about the text. So we stop inferring and make
# the filer DECLARE it, on the record, with `--discusses="<why>"`.
#
# WHY A DECLARATION BEATS THE WORKAROUND IT REPLACES. dev3's actual remedy was
# to re-file with neutral wording, which is the worst outcome available: it
# works, it teaches the fleet to launder vocabulary to reach the right audience,
# and it is INVISIBLE — a laundered ask is byte-indistinguishable from an ask
# that never had the words. A declaration is the opposite on every axis: it is
# attributable to its filer, it is written into the gate the LEAD then reads, and
# it is audited. An agent that lies in a `--discusses` string is caught by the
# reviewer looking at the claim; an agent that launders is caught by nobody.
#
# THE SAFETY MODEL, and it is deliberately four-deep — the declaration is NOT
# trusted on its own:
#   1. `--type=decision` ONLY. approval / manual / secret / access DECLARE AN
#      ACTION by construction ("approve me doing X", "hand me the key"), so no
#      appeal exists for them. decision is the one type whose content is a
#      question. This is the ticket's own suggested shape: key off the declared
#      action, not the substrings.
#   2. Fires ONLY when the floor ACTUALLY over-fired (tier_floored==1), like
#      DIVE-1480 — a non-floored decision's routing is untouched.
#   3. NON-APPEALABLE CORE. Money, irreversible infra and real-comms terms can
#      never be appealed, no matter what is declared: we re-test the floor with
#      only the APPEALABLE terms stripped and refuse the appeal if anything
#      still trips it. A "should we refund these customers, A or B" decision is
#      a human call whether or not it is framed as design.
#   4. It downgrades to a LEAD-ROUTED tier-1, never to tier-0 and never to the
#      filer. A human is replaced by a reviewer, not by nobody; filer-is-lead ⇒
#      no reviewer ⇒ no appeal (a lead cannot self-appeal to themselves).
# Plus: an explicit --tier=2 vetoes it (DIVE-1957), and the appeal is refused
# LOUDLY rather than silently ignored, so a filer never believes an appeal
# applied when it did not.
#
# WHAT THIS DOES NOT REMOVE — the DIVE-2146 pre-condition, discharged by
# construction rather than by enumeration. olivia's precondition on this ticket
# is that the floor is currently the SOLE ENFORCER of at least one directive
# (the self-restart confirm at projects/CLAUDE.md:13) and that a control which
# stops firing emits NO signal. This design cannot regress any such gate,
# because NOTHING here changes a gate's tier unless the filer PASSES A NEW FLAG.
# An agent that files the self-restart approval exactly as before gets the exact
# tier it got before — and `--discusses` is unavailable to it anyway, since that
# gate is --type=approval (rule 1). The directive still needs encoding as its own
# artifact; DIVE-2146 owns that arm and gates it on its own precondition.
#
# APPEALABLE: the vocabulary that routinely appears in DESIGN discussion of a
# category without any action being requested — secrets/credentials handling
# (2089's reported case), the content-publish-later terms DIVE-1381 already
# treats as over-firing, and the recoverable-destructive verbs DIVE-1480 does.
_GATE_FLOOR_APPEALABLE_RX='secret|credential|api key|token|password|publish|public post|announce|launch post|delete|destroy|wipe|purge'
# NON-APPEALABLE (everything else in the floor, stated positively so a future
# edit to the floor regex cannot silently widen what an appeal reaches): money,
# real outbound comms, and irreversible infra/access. Never carved out.
#
# DIVE-2301: this constant is DOCUMENTATION OF RECORD, not a matcher — nothing
# matches against it (grep the tree: one definition, zero uses). The non-appealable
# decision is reached by SUBTRACTION: strip the appealable terms and re-test the
# FULL floor, so the boundary fix at _gate_tier2_floor_hit is what actually stops
# 'suppression' from being read as the non-appealable 'press' in an appeal refusal.
# If this list is ever promoted to a live matcher it must go through the same
# leading-boundary wrapper and NOT per-term \b, which cannot anchor \$[0-9]/€[0-9]
# and would silently drop the money class out of the un-appealable half.
#
# The appeal path depends on an invariant this pair must keep: no APPEALABLE term
# may be a substring of a NON-APPEALABLE one, or stripping the former would erase
# the latter and hand an appeal to a class that has none. Asserted in
# tests/gate_floor_word_boundary_unit.sh rather than left to review.
_GATE_FLOOR_NONAPPEALABLE_RX='spend|billing|invoice|charge|payment|refund|subscription|price|pricing|\$[0-9]|€[0-9]|press|customer email|email customers|newsletter|blast|teardown|drop[^.]{0,20}table|truncate|irreversible|revoke|dns|domain transfer'
# _gate_floor_appeal_residual <text>: lower-case <text> and remove ONLY the
# appealable terms. The caller re-tests the full floor against the result; if it
# still fires, a non-appealable class is present and the appeal is refused.
_gate_floor_appeal_residual() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E "s/(${_GATE_FLOOR_APPEALABLE_RX})//g"
}
# _gate_tier2_floor_term <text>: the SUBSTRING that tripped the floor, or empty.
# DIVE-2089 defect 2 — the floor was SILENT. dev3 only discovered the escalation
# by re-reading their own filed gate; an agent that files and moves on leaves a
# design question in the founder's inbox indefinitely. "[tier forced to 2 — T2
# category floor]" does not say WHICH word did it, and a filer cannot appeal or
# even understand an escalation whose cause is unnamed. Reuses the same resolved
# policy regex as the floor itself (constitution-aware, drift-fail-closed) so the
# term reported is always the term that actually matched.
_gate_tier2_floor_term() {
  local text rx="$_GATE_T2_FLOOR_RX" loaded=""
  text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if declare -F _council_hard_gate_rx >/dev/null 2>&1 \
     && declare -F _council_constitution_path >/dev/null 2>&1; then
    local cp; cp="$(_council_constitution_path 2>/dev/null || true)"
    if [[ -n "$cp" && -f "$cp" ]] \
       && ! { declare -F _council_constitution_drifted >/dev/null 2>&1 && _council_constitution_drifted; }; then
      loaded="$(_council_hard_gate_rx 2>/dev/null || true)"
      # Same ERE-validity guard as the floor (CNCL-28): Bash returns 2 for an
      # invalid expression, and this helper must never report a term the floor
      # itself did not use.
      if [[ -n "$loaded" ]]; then
        local ere_rc=0; [[ x =~ $loaded ]] || ere_rc=$?
        (( ere_rc == 2 )) || rx="$loaded"
      fi
    fi
  fi
  # DIVE-2301: same leading-boundary wrapper as the floor itself — this helper must
  # never report a term the floor did not use, and that includes never reporting a
  # term the floor no longer matches. BASH_REMATCH[0] now carries the boundary
  # character too (" press"), so the TERM is group 2; reporting [0] would print a
  # leading space into the warn line and into the gate record.
  [[ "$text" =~ (^|[^[:alnum:]_])($rx) ]] && printf '%s' "${BASH_REMATCH[2]}"
}

# OSS-11 (DIVE-976) — _gate_ask_shape <ask>: normalize an ask into its "shape
# key" so two gates that ask structurally the same question but about different
# targets collapse to one key. Precedent matching uses EXACT shape-key equality
# (no fuzzy/embedding match) to bound false positives. Volatile tokens become
# typed placeholders; the ORDER below matters — each rule must run before any
# later rule that could re-consume its output (dates/hosts before the bare-number
# rule; quoted names first so their contents aren't mangled). Placeholders carry
# no digits, hyphenated-digit runs, or dots, so no rule ever re-fires on them.
_gate_ask_shape() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E \
        -e 's/"[^"]*"/<name>/g' \
        -e "s/'[^']*'/<name>/g" \
        -e 's#https?://[^[:space:]]+#<host>#g' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}/<date>/g' \
        -e 's/\b(today|tomorrow|yesterday)\b/<date>/g' \
        -e 's/([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}/<host>/g' \
        -e 's/\$[0-9][0-9,]*(\.[0-9]+)?[kmb]?/<amount>/g' \
        -e 's/\b[a-z]+-[0-9]+\b/<ident>/g' \
        -e 's/[0-9]+(\.[0-9]+)?/<num>/g' \
        -e 's/[[:space:]]+/ /g' \
        -e 's/^ +//; s/ +$//'
}

# OSS-20 — _gate_shape_jaccard <shapeA> <shapeB>: token-set Jaccard similarity of
# two ask_shapes, printed as an integer 0..100 (percent). Tokens are the
# whitespace-split words of each shape (order- and duplicate-insensitive; the set
# is what matters). Jaccard = |A∩B| / |A∪B|. Empty-vs-empty and any empty side is
# 0 (the caller only fuzzy-matches non-empty shapes anyway). Used by the fuzzy
# precedent fallback: two shapes at >=80 are "same question, paraphrased".
_gate_shape_jaccard() {
  awk -v a="$1" -v b="$2" '
    BEGIN {
      na = split(a, ta, /[ ]+/); for (i = 1; i <= na; i++) if (ta[i] != "") A[ta[i]] = 1
      nb = split(b, tb, /[ ]+/); for (i = 1; i <= nb; i++) if (tb[i] != "") B[tb[i]] = 1
      inter = 0; for (k in A) if (k in B) inter++
      uni = 0; for (k in A) uni++; for (k in B) if (!(k in A)) uni++
      if (uni == 0) { print 0; exit }
      printf "%d", (inter * 100) / uni
    }'
}

cmd_task_need() {
  tasks_db_init
  local type="" ask="" options="" recommend="" from="" tier="" secret_key="" connector="" probe="" withdraw="" discusses="" needs=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type=*)      type="${1#*=}" ;;
      --ask=*)       ask="${1#*=}" ;;
      --options=*)   options="${1#*=}" ;;
      --recommend=*) recommend="${1#*=}" ;;
      --tier=*)      tier="${1#*=}" ;;
      --from=*)      from="${1#*=}" ;;
      # DIVE-1401: withdraw a still-pending gate the team ITSELF filed but that is
      # now moot (e.g. a secret gate for fixtures never needed). This is NOT a
      # grant — it never records a secret/approval as provided — so it is safe for
      # the gate's filer or an org lead to run without a human tap. See branch below.
      --withdraw)    withdraw=1 ;;
      # DIVE-931 secure credential drop: name WHERE a secret gate's value lands.
      # Both together enable the burnable drop link in the gate message.
      --secret-key=*) secret_key="${1#*=}" ;;
      --connector=*)  connector="${1#*=}" ;;
      # DIVE-1243: opt-in self-check for --type=access. The command MUST FAIL
      # (non-zero) for the gate to file; if it SUCCEEDS the block isn't real.
      --probe=*)     probe="${1#*=}" ;;
      # DIVE-2089: declare that this DECISION gate DISCUSSES a floored category
      # rather than performing it, with the reason. See the class comment above
      # _GATE_FLOOR_APPEALABLE_RX — decision-type only, floor-over-fire only,
      # non-appealable core excepted, lead-routed, audited.
      --discusses=*) discusses="${1#*=}" ;;
      # DIVE-2241: DECLARE the capability this ask consumes. Declared, never
      # inferred — inferring it from --type or from the ask text would be the
      # DIVE-2089 mistake one layer up (reading subject matter to guess intent).
      --needs=*)     needs="${1#*=}" ;;
      --)          shift; positional+=("$@"); break ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task need <id|DIVE-N> --type=decision|secret|approval|manual --ask=\"...\" [--options=A|B] [--recommend=\"A\"] [--needs=human_tap|spend_authority|secret_provision] [--discusses=\"why this decision only DISCUSSES a floored category\"]  (or --withdraw to cancel a moot pending gate)"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"

  # DIVE-1401: --withdraw path. Secret/approval/manual gates are human-only to
  # CLEAR by deliberate security scope (an agent can't fake a secret grant). But
  # WITHDRAWING a still-pending request the team itself filed is not a grant — it
  # cancels a moot gate and unblocks the task WITHOUT ever writing need_answer /
  # need_answered_at, so no secret is recorded as provided. Allowed for the gate's
  # FILER (assignee of record, set at file time), the filer's routed lead /
  # coordinator, or a human caller (non-agent unix id). Genuine GRANT-clears stay
  # human-only via cmd_task_answer — this branch never touches that path.
  if [[ -n "$withdraw" ]]; then
    [[ -z "$type$ask$options$recommend$tier$secret_key$connector$probe$discusses$needs" ]] \
      || fail "$E_USAGE" "--withdraw takes no other gate flags (it cancels the existing gate, not re-files one)"
    local w_type w_ans w_status
    w_type=$(db "SELECT COALESCE(need_type,'')        FROM tasks WHERE id=${id};")
    w_ans=$(db  "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")
    w_status=$(db "SELECT status FROM tasks WHERE id=${id};")
    [[ "$w_status" == "done" || "$w_status" == "cancelled" ]] \
      && fail "$E_CONFLICT" "$ident is $w_status — nothing to withdraw"
    [[ -n "$w_type" ]] || fail "$E_CONFLICT" "$ident has no gate to withdraw"
    [[ -z "$w_ans" ]]  || fail "$E_CONFLICT" "$ident's gate is already answered — --withdraw only applies to a still-pending gate (need_answered_at IS NULL)"
    # Authorize on the TRUSTED caller identity from _gate_withdraw_actor (EUID-gated
    # SUDO_* or the real id -un — see its comment), NEVER on --from. The gate's filer
    # is its assignee of record; the filer's routed lead / org coordinator may also
    # withdraw, as may a genuine human. An agent that is none of these is refused.
    local w_filer w_id w_kind w_name="" w_lead w_coord w_ok=0
    w_filer=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")
    w_id=$(_gate_withdraw_actor)                          # "agent <name>" | "human" | "none"
    w_kind="${w_id%% *}"
    [[ "$w_kind" == "agent" ]] && w_name="${w_id#agent }"
    w_lead=$(_gate_route_reviewer "$w_filer")
    w_coord=$(_task_resolve_coordinator)
    [[ "$w_kind" == "human" ]] && w_ok=1                                    # a genuine human caller
    [[ -n "$w_name" && "$w_name" == "$w_filer" ]] && w_ok=1                # the filer
    [[ -n "$w_name" && -n "$w_lead"  && "$w_name" == "$w_lead"  ]] && w_ok=1  # filer's lead
    [[ -n "$w_name" && -n "$w_coord" && "$w_name" == "$w_coord" ]] && w_ok=1  # org coordinator
    (( w_ok )) || policy_refuse "$E_AUTH_REQUIRED" gate-withdraw-not-authorized DIVE-1401 "$ident" "only the gate's filer (${w_filer:-?}), their lead, or a human can withdraw $ident's gate"
    # Clear every gate field and unblock back to todo when no dependency edge
    # still holds it. The withdrawn gate is archived to gate_history first, in
    # the same transaction (DIVE-2119).
    #
    # DIVE-2119: this comment used to read "Clear every gate field (NEVER
    # need_answer/need_answered_at — this is not a grant)" while the UPDATE it
    # sits on cleared 12 fields and left need_answered_by / need_answered_uid /
    # need_answer_sig standing — so a withdrawn gate left orphaned answer
    # provenance behind (13 of the 21 rows DIVE-2094 measured were this path and
    # `task park`). Two things were wrong with the old wording: it claimed a
    # completeness it did not have, and its parenthetical is backwards — the
    # answer columns ARE nulled here (a withdrawal records no grant, which is the
    # property it was reaching for). Both are now true: _gate_archive_and_clear_sql
    # resets all six provenance columns, so no answer or answerer survives a
    # withdrawal, and the outgoing gate is preserved in gate_history instead.
    db "BEGIN IMMEDIATE;
        $(_gate_archive_and_clear_sql withdraw "id=${id}")
        UPDATE tasks
          SET need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL,
              secret_key=NULL, connector=NULL, ask_shape=NULL,
              precedent_ref=NULL, precedent_kind=NULL, routed_reviewer=NULL,
              needs_capability=NULL,
              need_asked_at=NULL, gate_pinged_at=NULL, gate_filed_by=NULL
        WHERE id=${id};
        UPDATE tasks SET status='todo'
          WHERE id=${id} AND status='blocked'
            AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id});
        COMMIT;"
    # DIVE-2054: DELIBERATELY UNFENCED. Carries asserted_from=, the identity-assertion
    # audit trail red-teamed on DIVE-1401 — a fixture store must never be able to
    # suppress it (fencing here would trade a contamination bug for an
    # evidence-suppression bug, the DIVE-1968 fail-open family). See DIVE-2054 wiki.
    audit_log "task need withdraw" "ok" 0 -- "task=$ident" "type=$w_type" "by=${w_name:-$w_kind}" "asserted_from=${from:-}" || true
    local w_new; w_new=$(db "SELECT status FROM tasks WHERE id=${id};")
    ok "$ident gate withdrawn (${w_type}) — moot request cleared, no secret/grant recorded; task now ${w_new}" \
       '{ident:$id, withdrawn:true, was_type:$wt, status:$st}' \
       --arg id "$ident" --arg wt "$w_type" --arg st "$w_new"
    return
  fi

  valid_need_type "$type" || fail "$E_VALIDATION" "bad --type '$type' (decision|secret|approval|manual|access)"
  [[ -n "$ask" ]] || fail "$E_USAGE" "--ask is required (what does the human need to provide?)"

  # DIVE-2089: --discusses is a DECISION-only appeal. approval / manual / secret /
  # access declare an ACTION by construction, so "I'm only discussing it" is not a
  # coherent claim on them — refuse rather than accept-and-ignore, so a filer can
  # never believe an appeal applied when it did not. Rule 1 of the four-deep safety
  # model above; it is also what keeps this change unable to regress the
  # DIVE-2146 self-restart APPROVAL gate.
  if [[ -n "$discusses" ]]; then
    [[ "$type" == "decision" ]] \
      || fail "$E_VALIDATION" "--discusses only applies to --type=decision — a $type gate requests an ACTION, so it cannot be 'only discussing' the category. If this really is a design question, file it as --type=decision."
    [[ ${#discusses} -ge 12 ]] \
      || fail "$E_VALIDATION" "--discusses must state WHY this gate discusses rather than performs (it is recorded on the gate and read by the reviewer who clears it)"
  fi

  # DIVE-1243: self-check for the manager-clearable `access` class. An access gate
  # claims "I'm blocked on a grant a teammate can give" — but a FALSE block (codex
  # DIVE-1234 filed 'grant me wiki write access' when it ALREADY had it) wastes a
  # lead ping. --probe=<cmd> is an opt-in real self-check run AS the filing agent:
  # it MUST FAIL (non-zero) for the gate to file; if it SUCCEEDS the access already
  # works, so we refuse. With no --probe we still NUDGE (never hard-block — the
  # probe can't be expressed for every kind of block).
  if [[ -n "$probe" ]]; then
    [[ "$type" == "access" ]] || fail "$E_VALIDATION" "--probe only applies to --type=access"
    if bash -c "$probe" >/dev/null 2>&1; then
      fail "$E_CONFLICT" "self-check passed (\`$probe\` succeeded) — you already have this access; not filing. Re-check the real blocker (see DIVE-1234)."
    fi
  elif [[ "$type" == "access" ]]; then
    warn "--type=access filed without --probe — confirm you actually tested the block (e.g. --probe='test -w /path'). False blocks (DIVE-1234) waste a lead ping."
  fi
  # Options are the choice list for a decision; reject them on the other types
  # so the gate shape stays honest for the dashboard. (An approval gate is
  # deliberately approved/denied only — the plugin tap handler resolves no
  # option index for it; see DIVE-560 note in _task_loop_advance.)
  if [[ -n "$options" && "$type" != "decision" ]]; then
    fail "$E_VALIDATION" "--options only applies to --type=decision"
  fi
  # DIVE-2074: a decision gate on a branch-bound (delegated-push) task is a trap —
  # `5dive push` only accepts a decision answer from the gate's OWN routed reviewer
  # (matching invoker uid) or a human/lead stamp; a lead who answers on someone
  # else's behalf (e.g. the org lead clearing a decision routed to a named
  # reviewer) stamps as a bare agent name, which push refuses. That refusal lands
  # on the PUSHER, one step after the lead believed they'd unblocked the work (see
  # DIVE-2073/DIVE-2004). Surface the trap at FILE time, while --type can still be
  # changed, instead of after an unusable answer is already recorded.
  if [[ "$type" == "decision" ]]; then
    local _need_body _need_branch
    _need_body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
    _need_branch=$(_push_branch_from_body "$_need_body")
    if [[ -n "$_need_branch" ]]; then
      warn "$ident is branch-bound (Branch: ${_need_branch}) — a --type=decision gate only authorizes 'push' when answered by ITS OWN routed reviewer; a lead clearing it on someone else's behalf will NOT satisfy push (DIVE-2073). If this gate is meant to unblock a delegated push, file --type=approval instead."
    fi
  fi
  # DIVE-931: --secret-key / --connector name the drop target and only make sense
  # on a secret gate. Require them together (a key with no connector has nowhere
  # to land, and vice versa) and validate against the same charsets the box-side
  # `secret write` + the api /drop/mint enforce, so a bad value fails here rather
  # than at mint time. Both omitted = legacy secret gate (out-of-band delivery).
  if [[ -n "$secret_key" || -n "$connector" ]]; then
    [[ "$type" == "secret" ]] || fail "$E_VALIDATION" "--secret-key/--connector only apply to --type=secret"
    [[ -n "$secret_key" && -n "$connector" ]] \
      || fail "$E_VALIDATION" "--secret-key and --connector must be given together (both name the drop target)"
    [[ "$secret_key" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] \
      || fail "$E_VALIDATION" "invalid --secret-key '$secret_key' (env-var name: ^[A-Z][A-Z0-9_]{0,63}\$)"
    [[ "$connector" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] \
      || fail "$E_VALIDATION" "invalid --connector '$connector' (^[a-z0-9][a-z0-9-]{0,63}\$)"
  fi
  # DIVE-148: --recommend surfaces the agent's advised choice first in the human
  # alert (and ⭐-marks its button). Only meaningful for the two finite-choice
  # gate types; reject it elsewhere so the gate shape stays honest. For a
  # decision it MUST be one of --options (same split rule as the buttons:
  # split '|', trim, drop empties) or a tapped/displayed recommend wouldn't
  # match any real option. For approval it's free text (e.g. approved/denied).
  if [[ -n "$recommend" ]]; then
    case "$type" in
      decision)
        [[ -n "$options" ]] || fail "$E_VALIDATION" "--recommend on a decision needs --options to match against"
        local _match
        _match=$(printf '%s' "$options" | jq -Rr --arg r "$recommend" '
          [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ]
          | (($r | gsub("^\\s+|\\s+$"; "")) as $rr | any(.[]; . == $rr)) | tostring' 2>/dev/null) || _match="false"
        [[ "$_match" == "true" ]] || fail "$E_VALIDATION" "--recommend \"$recommend\" must match one of --options ($options)"
        ;;
      approval) : ;;
      *) fail "$E_VALIDATION" "--recommend only applies to --type=decision or --type=approval" ;;
    esac
  fi
  local cur; cur=$(db "SELECT status FROM tasks WHERE id=${id};")
  [[ "$cur" == "done" || "$cur" == "cancelled" ]] \
    && fail "$E_CONFLICT" "$ident is $cur — reopen it before gating on a human"

  # DIVE-891: resolve the gate's risk tier (adopted DIVE-861 design).
  #   0 = auto-clear: the recommendation applies immediately, no ping, digest line
  #   1 = agent-clearable; 48h unanswered -> the heartbeat TTL sweep applies the rec
  #   2 = hard human gate: never auto-applies, TTL only batches reminder pings
  # Defaults by type when --tier is omitted: decision/approval -> 1 (agents
  # legitimately resolve these; "approve this ship/close/commit" is the most
  # common builder gate and the human blanket-cleared them in practice), manual/
  # secret -> 2. Explicit --tier can lower an approval/decision/manual gate,
  # EXCEPT: a secret gate is always tier 2, and the T2 category floor below
  # overrides everything (money/public-comms/secrets/destructive still
  # route to a human regardless of this default — see _gate_tier2_floor_hit).
  # DIVE-1284: default 'approval' to tier 1 too — the old default sent the bulk
  # of delegatable ship/close/commit approvals straight to the paired human.
  # DIVE-1182: remember whether --tier was EXPLICIT (a caller's hard-human
  # contract) vs. only the type default. manual/secret default to tier 2, so the
  # effective tier alone can't tell "builder ship-gate" from "caller pinned
  # hard-human"; the routing predicate below needs the explicit signal.
  local tier_arg="$tier"
  if [[ -n "$tier" ]]; then
    [[ "$tier" == "0" || "$tier" == "1" || "$tier" == "2" ]] \
      || fail "$E_VALIDATION" "bad --tier '$tier' (0=auto-clear | 1=48h-TTL-applies-rec | 2=hard human gate)"
  else
    case "$type" in decision|approval) tier=1 ;; *) tier=2 ;; esac  # DIVE-1284
  fi
  local tier_floored=0
  local _floored_by_title=0 _floor_axis=none _ft_title=""   # DIVE-2224
  if [[ "$tier" != "2" ]]; then
    if [[ "$type" == "secret" ]]; then
      tier=2; tier_floored=1
    else
      local ttl_title; ttl_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
      # DIVE-2224: per-field, never the join; and the ASK is the subject (answer A).
      _floor_axis=$(_gate_floor_axis "$ask" "$ttl_title")
      case "$_floor_axis" in
        ask) tier=2; tier_floored=1 ;;
        title-fallback)
          tier=2; tier_floored=1
          warn "gate floored on the TITLE because the ask states nothing of its own ('${ask}'). A self-contained ask is the standing rule; the floor fails closed rather than trust a filing whose only statement of the request is the ticket title."
          ;;
        title)
          # Not floored. The reviewer is told WHY in one line so 'this ticket is
          # about deletion' is a fact they hold, and escalating is one step.
          _floored_by_title=1; _ft_title="$ttl_title"
          warn "gate NOT floored: the tier-2 category term is in the TASK TITLE, not in the ask (DIVE-2224 answer A). Routed to the lead, stamped floored_by=title — escalate it if the ask really is asking for that."
          ;;
      esac
    fi
  fi

  # DIVE-2241: the DECLARED human-class capability. This is the sibling of the
  # keyword floor directly above — same destination, opposite epistemics. The
  # floor READS the ask and guesses ("this says 'billing', so it is probably
  # money"); `--needs` is the filer STATING what the ask consumes. A declaration
  # is the stronger signal, so it is applied AFTER the floor and simply overrides:
  # a human-class capability is tier-2 by definition (never auto-applies, always
  # reaches the person), and marking it tier_floored=1 puts it in the same bucket
  # every downstream reader already treats as true-human.
  #
  # THE DEFECT THIS CLOSES: a gate on a verifier-loop task routes to the VERIFIER
  # regardless of what is being ASKED — so "may I spend $X" landed on whichever
  # agent happened to be grading the ticket. Three instances in 36h across three
  # agents (dev3/DIVE-2084, main/DIVE-2146, olivia immediately after). The routing
  # veto is at the _routable backstop below, next to the DIVE-1957 tier-2 one, so
  # it holds against every KIND-based override by construction rather than
  # per-branch.
  #
  # FALL THROUGH, NEVER REFUSE (scope item 4): an unrecognised capability warns
  # and resolves to today's routing. A router that hard-fails on an unknown name
  # turns a mis-declared gate into a STUCK one, and the whole point of the class
  # is that a mis-declaration should cost a re-file, not a block. `--needs=`
  # (empty) is the same as absent: undeclared, never non-holding.
  local _needs_human=0
  if [[ -n "$needs" ]]; then
    if _gate_needs_human "$needs"; then
      _needs_human=1
      tier=2; tier_floored=1
    else
      warn "--needs='${needs}' is not a human-class capability, so it changes nothing about where this gate goes (routing is unchanged). The three that resolve to the paired human are: ${_GATE_HUMAN_CAPABILITIES// /, }. Agent capabilities (delegated_push, root, gh_push) are NOT routable this way yet — see DIVE-2156."
    fi
  fi

  # DIVE-1381: content-curation carve-out. Mirror of the eng-ship class (DIVE-1359)
  # for our early-stage content surfaces (OpenAgent / character-packs / the persona
  # drip). A persona/pack QUEUE-READINESS approval is lead-clearable, not a human
  # call — but the T2 floor matches 'publish' in the ask/title and forces it
  # hard-human (tier-2, unclearable by the lead), the exact wall DIVE-1366 hit.
  # Like eng-ship the routing is intrinsic to the KIND, so this fires whether or
  # not the floor tripped: a curation-shaped decision/approval from a NON-lead is
  # forced to a lead-routed tier-1 — downgrading tier-2 when the floor fired. The
  # true-human floor still WINS for a genuine publish-NOW / press /
  # customer-comms / money / secret / destructive ask: we re-test the floor with
  # only the content-publish-LATER terms stripped (_GATE_CONTENT_PUBLISH_RX — the
  # real publish happens downstream via the drip, not now) and refuse to downgrade
  # if anything else still trips it. Clearing tier_floored lets the routing
  # predicate treat it as a tier-1 gate; _curation (like _eng_ship) forces
  # lead-routing regardless of the gate_builder_routing pref. secret/manual are
  # never curation; filer-is-lead ⇒ no reviewer ⇒ not downgraded.
  # DIVE-1957: an EXPLICIT --tier=2 vetoes this downgrade (tier_arg==2). Note the
  # tier==2 short-circuit above means an explicitly-pinned gate never sets
  # tier_floored, so without this guard curation downgraded a pinned brand/money
  # ask that the floor would otherwise have caught.
  local _curation=0
  if [[ "$tier_arg" != "2" && ( "$type" == "decision" || "$type" == "approval" ) ]]; then
    local _cc_title; _cc_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
    # DIVE-2224: classify and strip PER FIELD. Building one residual from the join
    # let the publish-strip and the re-tested floor both straddle the seam.
    local _cc_res_ask _cc_res_title
    _cc_res_ask=$(printf '%s' "$ask" \
      | tr '[:upper:]' '[:lower:]' | sed -E "s/(${_GATE_CONTENT_PUBLISH_RX})//g")
    _cc_res_title=$(printf '%s' "$_cc_title" \
      | tr '[:upper:]' '[:lower:]' | sed -E "s/(${_GATE_CONTENT_PUBLISH_RX})//g")
    if _gate_hit_either _gate_content_curation_hit "$ask" "$_cc_title" \
       && ! _gate_hit_either _gate_tier2_floor_hit "$_cc_res_ask" "$_cc_res_title"; then
      local _cc_reviewer; _cc_reviewer=$(_gate_route_reviewer "$(task_actor "$from")")
      if [[ -n "$_cc_reviewer" ]]; then
        tier=1; tier_floored=0; _curation=1
      fi
    fi
  fi

  # DIVE-1480: internal-ops / recovery carve-out. Same shape as content-curation
  # above: an internal control-plane decision (task board / an agent's own work /
  # a wipe recovery) is lead-clearable, but the T2 destructive floor over-fires on
  # the ask NARRATING a wipe ('destroyed'/'wiped'/'purge') and forces it hard-human
  # — the exact wall the STEER-1 keep-vs-discard gate hit (landed on lodar, not
  # Marcus). UNLIKE eng-ship/curation this fires ONLY when the floor ACTUALLY
  # over-fired (tier_floored==1): a precise fix for the over-escalation, leaving a
  # non-floored internal decision's normal tier-1 routing untouched. We re-test the
  # floor with only the INTERNAL-destructive terms stripped
  # (_GATE_INTERNAL_DESTRUCTIVE_RX); only if the ask matches the narrow internal-ops
  # class AND nothing else in the residual still trips the floor (a real prod/infra
  # destructive term — teardown / drop table / revoke / dns — or any money / secret
  # / publish term wins and stays hard-human) do we downgrade to a
  # lead-routed tier-1 so it reaches the lead, not lodar. Guarded to decision/
  # approval with a reviewer (filer-is-lead ⇒ no downgrade); runs after curation so
  # a curation-shaped ask keeps its own class.
  # DIVE-1957: explicit --tier=2 vetoes this downgrade too. (Belt-and-braces: the
  # tier==2 short-circuit above already leaves tier_floored=0 for a pinned gate,
  # so this arm was unreachable with a pin — the guard is stated so the invariant
  # survives any future change to where the floor is evaluated.)
  local _internal_ops=0
  if [[ "$tier_arg" != "2" && "$tier_floored" == "1" && "$_curation" == "0" \
        && ( "$type" == "decision" || "$type" == "approval" ) ]]; then
    local _io_title; _io_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
    # DIVE-1481: strip a destructive term only where it is CO-REFERENT to an
    # internal-ops object, not everywhere it appears — a prod-object verb survives
    # into the residual and keeps the gate hard-human.
    # DIVE-2224: run that strip PER FIELD. DIVE-1481's window is 20 characters, and
    # on the joined string it reached across the seam and manufactured a
    # co-reference present in neither text -- which STRIPS a destructive term the
    # floor should have kept, i.e. it removes a human. This is the dangerous
    # direction of the seam bug, not the annoying one.
    local _io_res_ask _io_res_title
    _io_res_ask=$(_gate_internal_residual "$ask")
    _io_res_title=$(_gate_internal_residual "$_io_title")
    if _gate_hit_either _gate_internal_ops_hit "$ask" "$_io_title" \
       && ! _gate_hit_either _gate_tier2_floor_hit "$_io_res_ask" "$_io_res_title"; then
      local _io_reviewer; _io_reviewer=$(_gate_route_reviewer "$(task_actor "$from")")
      if [[ -n "$_io_reviewer" ]]; then
        tier=1; tier_floored=0; _internal_ops=1
      fi
    fi
  fi

  # DIVE-2089: the DECLARED-DISCUSSION appeal. Runs after the three inferring
  # classes so an ask that already qualifies as curation / internal-ops keeps its
  # own class (and needs no declaration). Structure is DIVE-1480's — fires only on
  # an ACTUAL over-fire, re-tests the floor on a residual, requires a reviewer,
  # downgrades to a LEAD-routed tier-1 — with one deliberate difference: the class
  # membership is DECLARED by the filer, not guessed from vocabulary. See the
  # comment block on _GATE_FLOOR_APPEALABLE_RX for why that inversion is the whole
  # point of the ticket.
  # Every refusal path below is LOUD. A silently-ignored appeal would reproduce
  # defect 2 (the escalation nobody sees) one layer up.
  local _discusses_applied=0
  if [[ -n "$discusses" ]]; then
    if [[ "$tier_arg" == "2" ]]; then
      # DIVE-1957: an explicit pin is the caller's hard-human contract and vetoes
      # every downgrade class. Nothing to appeal — the floor never even ran.
      warn "--discusses ignored: you pinned --tier=2, which is a hard-human contract and outranks the appeal. Drop the pin to appeal the floor."
    elif [[ "$tier_floored" != "1" ]]; then
      warn "--discusses ignored: the T2 category floor did not fire on this gate (tier $tier), so there is nothing to appeal."
    elif [[ "$_curation" == "1" || "$_internal_ops" == "1" ]]; then
      : # already downgraded by its own class; the declaration is recorded below
    else
      local _dd_title; _dd_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
      # DIVE-2224: appeal residual is computed PER FIELD too — a phantom seam match
      # here would REFUSE a legitimate appeal, naming a term neither text contains.
      local _dd_res_ask _dd_res_title
      _dd_res_ask=$(_gate_floor_appeal_residual "$ask")
      _dd_res_title=$(_gate_floor_appeal_residual "$_dd_title")
      if _gate_hit_either _gate_tier2_floor_hit "$_dd_res_ask" "$_dd_res_title"; then
        # Rule 3: a non-appealable class (money / real comms / irreversible infra)
        # is present. Name the surviving term so the refusal is actionable rather
        # than mysterious — the filer can see it is not the word they meant.
        local _dd_term; _dd_term=$(_gate_tier2_floor_term "$_dd_residual")
        warn "--discusses REFUSED: this gate names a non-appealable category (matched '${_dd_term}'). Money, outbound customer comms and irreversible infra/access stay hard-human however they are framed. Staying at tier 2."
      else
        local _dd_reviewer; _dd_reviewer=$(_gate_route_reviewer "$(task_actor "$from")")
        if [[ -z "$_dd_reviewer" ]]; then
          # Rule 4: the appeal replaces a human with a REVIEWER, never with nobody.
          warn "--discusses REFUSED: no lead sits above you in the org chart, so there is nobody to route the appeal to (a lead cannot self-appeal). Staying at tier 2."
        else
          tier=1; tier_floored=0; _discusses_applied=1
        fi
      fi
    fi
    # Audited whether or not it applied — the DECLARATION is the artifact that
    # replaces the invisible rewording, so it has to survive a refusal too.
    _task_store_audit_log "task need floor-appeal" \
      "$( ((_discusses_applied)) && echo applied || echo refused )" 0 -- \
      "task=$ident" "filer=$(task_actor "$from")" "declared=$discusses" || true
  fi

  # DIVE-1359: eng-ship downgrade. A builder cannot file a hard-human (tier-2)
  # gate for an eng ship/merge/diff/deploy decision — that class is lead-clearable,
  # not a human call. When a NON-lead filer's decision/approval gate hits the
  # eng-ship kind AND did NOT trip the true-human floor above (which already ran
  # and wins — money/secrets/destructive stay tier-2), force it to a
  # lead-routed tier-1, OVERRIDING an explicit --tier=2. `_eng_ship=1` also makes
  # the routing predicate below send it to the lead regardless of the
  # gate_builder_routing pref, exactly like the DIVE-1243 `access` class — the
  # routing is intrinsic to the kind, not part of the pref's staged rollout.
  # secret/manual are never eng-ship. Filer-is-lead ⇒ _gate_route_reviewer empty
  # ⇒ not downgraded (a lead may legitimately pin a human gate). `actor` is not
  # yet set here (defined further down), so resolve the filer inline.
  local _eng_ship=0
  if [[ "$tier_floored" == "0" && ( "$type" == "decision" || "$type" == "approval" || "$type" == "manual" ) ]]; then
    local _es_title; _es_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
    if _gate_hit_either _gate_eng_ship_hit "$ask" "$_es_title"; then   # DIVE-2224: per-field
      local _es_reviewer; _es_reviewer=$(_gate_route_reviewer "$(task_actor "$from")")
      # DIVE-1738: builder ship-handoff nudge. approval/manual gates are
      # HUMAN-ONLY (cmd_task_answer's provenance floor) UNLESS routed — they
      # lean on routed_reviewer + the designated-reviewer exception, and manual
      # is not even eng-ship-downgraded below, so pref-OFF a manual ship gate
      # still pings the human. `decision` is lead-clearable by TYPE (tier-1, no
      # human_nonce, no routing dependency), which is what a builder->lead ship/
      # deploy handoff wants. Steer the filer to --type=decision. Fires only when
      # a lead sits above the filer (_es_reviewer non-empty ⇒ a builder, not the
      # lead re-escalating). Non-fatal + stderr-only: JSON stdout stays clean and
      # routing/tiering are unchanged (the DIVE-1359 downgrade below is intact).
      if [[ -n "$_es_reviewer" && ( "$type" == "approval" || "$type" == "manual" ) ]]; then
        warn "this looks like an engineering ship/deploy handoff filed as --type=$type. Prefer --type=decision for a builder ship gate — it's lead-clearable by design, so $_es_reviewer can resolve it without a human ping (approval/manual are human-only unless routed to the lead)."
      fi
      # DIVE-1359 downgrade stays scoped to decision/approval (manual is never
      # downgraded — the nudge above is its only treatment).
      # DIVE-1957: an EXPLICIT --tier=2 vetoes the downgrade. Overriding the TYPE
      # DEFAULT for a builder ship-gate is the point of this class and stays;
      # overriding the caller's hard-human contract was the bug — a brand/money
      # decision filed --tier=2 on a task merely TITLED "land/merge/ship X" was
      # silently re-tiered to 1 and routed to an agent, and the filer could not
      # fix it from the ask (the classifier reads ask + title). Warn instead of
      # silently obeying, so a builder who pinned by habit sees why their ship
      # gate went to the human rather than to their lead.
      if [[ -n "$_es_reviewer" && "$tier_arg" == "2" \
            && ( "$type" == "decision" || "$type" == "approval" ) ]]; then
        warn "explicit --tier=2 kept this eng-ship-shaped gate hard-human, so it pings the paired human instead of $_es_reviewer. Drop --tier=2 if a lead can clear it (ship/merge/deploy calls are lead-clearable by design); keep it only for a genuine brand/money/destructive call."
        # The warn corrects the NEXT filer; this row lets us MEASURE whether the
        # habit is real. The standing remedy for this very bug was "pin
        # --tier=2", so every agent carrying that advice may now escalate routine
        # ship gates past their lead to the paired human. Audit the branch that
        # declines to act, not just the one that acts — otherwise the only signal
        # is the human complaining about gate spam.
        # DIVE-2054: task-store measurement of a filer/lead pattern — fenced.
        _task_store_audit_log "task.gate-tier2-pin-escalated" ok 0 -- "$ident" "filer=$(task_actor "$from")" "lead=$_es_reviewer" "type=$type"
      elif [[ -n "$_es_reviewer" && ( "$type" == "decision" || "$type" == "approval" ) ]]; then
        tier=1; _eng_ship=1
      fi
    fi
  fi
  [[ "$tier" == "0" && -z "$recommend" ]] \
    && fail "$E_USAGE" "--tier=0 auto-applies the recommendation, so --recommend is required"

  # OSS-11 (DIVE-976) decision-memory precedent prefill. This runs AFTER the tier
  # + T2 category floor are settled and the tier-0-requires-recommend check above,
  # so precedent can NEVER satisfy that requirement or change the resolved tier —
  # it only sources the VALUE of an advisory recommend. The DIVE-916 invariant
  # holds by construction: no tier mutation, no touch of the clear path
  # (cmd_task_answer / TTL / nonce), and a blank rec is filled ONLY when the tier
  # would have surfaced/applied a rec anyway.
  local ask_shape precedent_ref="" precedent_cite="" precedent_kind=""
  ask_shape=$(_gate_ask_shape "$ask")
  # DIVE-2089: an APPLIED appeal is written into the ask the reviewer reads, so
  # the claim it rests on is graded by the person it moved the gate to. This is
  # the property the vocabulary workaround it replaces does not have — a
  # laundered ask carries no trace of having been laundered. Appended AFTER
  # ask_shape so the precedent key still matches the question, not the appeal.
  if [[ "$_discusses_applied" == "1" ]]; then
    ask="${ask}"$'\n\n'"[DIVE-2089 floor appeal — filer declared this DISCUSSES a tier-2 category rather than performing it: ${discusses}. Routed to you instead of the human on that claim; if it is wrong, this belongs with the human.]"
  fi
  # Best prior ANSWERED gate: same need_type, EXACT ask_shape, from an equally- or
  # more-scrutinized tier (COALESCE(tier,2) so legacy NULL counts as T2 — a
  # rubber-stamped T0 can never prefill a T2 gate), answered within 90 days; most
  # recent wins. Exclude self (id<>).
  local _prow
  _prow=$(db "SELECT id||x'1f'||ident||x'1f'||COALESCE(need_answer,'')||x'1f'||
                     COALESCE(need_answered_at,'')||x'1f'||COALESCE(need_answered_by,'')
              FROM tasks
              WHERE need_answer IS NOT NULL AND id<>${id}
                AND need_type=$(sqlq "$type")
                AND ask_shape IS NOT NULL AND ask_shape=$(sqlq "$ask_shape")
                AND COALESCE(tier,2) >= ${tier}
                AND need_answered_at >= datetime('now','-90 day')
              ORDER BY need_answered_at DESC LIMIT 1;")
  [[ -n "$_prow" ]] && precedent_kind="exact"

  # OSS-20 fuzzy fallback. Hand-written asks almost never collide EXACTLY, so the
  # exact path prefilled ~0 gates in practice. When it misses, scan the SAME
  # candidate set (same need_type, tier>=this, answered in 90d, non-empty shape,
  # not self) newest-first and take the most-recent whose ask_shape is token-set
  # Jaccard >= 0.8 to this one — "the same question, paraphrased". This is
  # advisory-ONLY and stays strictly inside the DIVE-916 invariant: it may prefill
  # a blank recommend + cite (recorded precedent_kind='fuzzy'), but it NEVER
  # mutates the tier and is NEVER eligible for auto-clear — OSS-21's auto-clear
  # keys on precedent_kind='exact', so a fuzzy match can only ever advise a human.
  if [[ -z "$_prow" && -n "$ask_shape" ]]; then
    local _cands
    _cands=$(db "SELECT id||x'1f'||ident||x'1f'||COALESCE(need_answer,'')||x'1f'||
                        COALESCE(need_answered_at,'')||x'1f'||COALESCE(need_answered_by,'')||x'1f'||
                        COALESCE(ask_shape,'')
                 FROM tasks
                 WHERE need_answer IS NOT NULL AND id<>${id}
                   AND need_type=$(sqlq "$type")
                   AND ask_shape IS NOT NULL AND ask_shape<>''
                   AND COALESCE(tier,2) >= ${tier}
                   AND need_answered_at >= datetime('now','-90 day')
                 ORDER BY need_answered_at DESC;")
    if [[ -n "$_cands" ]]; then
      local _cid _cident _cans _cat _cby _cshape _j
      while IFS=$'\x1f' read -r _cid _cident _cans _cat _cby _cshape; do
        [[ -n "$_cshape" ]] || continue
        _j=$(_gate_shape_jaccard "$ask_shape" "$_cshape")
        if [[ "$_j" -ge 80 ]]; then
          _prow="${_cid}"$'\x1f'"${_cident}"$'\x1f'"${_cans}"$'\x1f'"${_cat}"$'\x1f'"${_cby}"
          precedent_kind="fuzzy"
          break
        fi
      done <<<"$_cands"
    fi
  fi

  if [[ -n "$_prow" ]]; then
    local _pid _pident _pans _pat _pby
    IFS=$'\x1f' read -r _pid _pident _pans _pat _pby <<<"$_prow"
    precedent_ref="$_pid"
    local _pwho="${_pby#human:}"; _pwho="${_pwho#auto:}"
    # A fuzzy hit is a paraphrase, not an identical gate — flag it in the citation
    # so the human reads the prefill as advisory-by-similarity, not a rubber stamp.
    local _sim=""; [[ "$precedent_kind" == "fuzzy" ]] && _sim=" [similar gate]"
    precedent_cite="Precedent: you answered '${_pans}' on ${_pident} (${_pat%% *}${_pwho:+, $_pwho})${_sim}"
    # Prefill ONLY a blank recommend — never override an explicit filer rec. For a
    # decision the precedent answer must ALSO be one of THIS gate's options (shapes
    # match but option sets can differ); if it isn't, keep the citation but skip
    # the prefill so a tapped/displayed rec always maps to a real option.
    if [[ -z "$recommend" && -n "$_pans" ]]; then
      local _pok=1
      if [[ "$type" == "decision" ]]; then
        _pok=$(printf '%s' "$options" | jq -Rr --arg r "$_pans" '
          [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ]
          | (($r | gsub("^\\s+|\\s+$"; "")) as $rr | any(.[]; . == $rr)) | if . then "1" else "0" end' 2>/dev/null) || _pok=0
      fi
      [[ "$_pok" == "1" ]] && recommend="$_pans"
    fi
  fi

  # DIVE-2235 class-over-tier, applied BEFORE the write below so the stored tier
  # is the floored one (a record showing tier=0 on a gate that was pinged would
  # be its own small lie). Tier 0 IS an auto-answer: it applies `recommend` at
  # file time and never pings. A human-class gate must not be auto-answered at
  # any tier, so tier 0 on one of those is floored to 1 — the gate is filed,
  # a nonce is minted, and a person is asked. Cost of a mis-classification is
  # now one ping instead of a silent self-clear that nothing in the record
  # distinguishes from a considered call. Deliberately NOT floored to 2: this
  # change corrects the class violation only, it does not re-tier the fleet.
  if [[ "$tier" == "0" ]] && _gate_human_class "$type"; then
    tier=1
    _task_store_audit_log "task need class-floor" "ok" 0 -- \
      "task=$ident" "type=$type" "from_tier=0" "to_tier=1" "reason=human_class" || true
  fi

  # assignee=actor: the agent hitting the gate becomes the owner-of-record, so
  # `task answer` knows who to ping to resume. The inbox is defined by the gate
  # (need_type set), not by assignee, so it still surfaces to the human.
  local actor; actor=$(task_actor "$from")
  # DIVE-2196: filing a gate on a task DELIVERED to you IS an act of review — the
  # verifier demonstrably opened it and escalated. Stamp the handoff ACK in the same
  # transaction, so "reviewed it and escalated to a human" stops being byte-identical
  # to "never looked at it": handoff_ack_at NULL is what the stall sweep, `task show`
  # and the loop board all read as UNACKNOWLEDGED, and on DIVE-2146 that made the
  # sweep nag a verifier who had already graded and escalated. Same receiver rule as
  # DIVE-1378's `task start` ACK — the REAL actor only (never --from, which would let
  # a third party forge the verifier's receipt), only while they are the assigned
  # verifier of a delivered row, COALESCE so a set ACK never moves.
  local _ack_actor; _ack_actor=$(task_actor)
  # DIVE-2119: a re-file DESTROYS the previous gate — archive it to gate_history
  # and reset all six provenance columns in the same transaction, before the
  # SET below overwrites need_type/ask/tier. Without the archive the previous
  # gate leaves nothing but a stale answerer; without the reset the incoming
  # gate wears that answerer's identity, uid and signature (DIVE-2094).
  db "BEGIN IMMEDIATE;
      $(_gate_archive_and_clear_sql file "id=${id}")
      UPDATE tasks
        SET status='blocked', assignee=$(sqlq "$actor"),
            handoff_ack_at=CASE
              WHEN maker_agent IS NOT NULL AND verifier IS NOT NULL
                   AND assignee=verifier AND verifier=$(sqlq "$_ack_actor")
                   AND handoff_delivered_at IS NOT NULL
              THEN COALESCE(handoff_ack_at, datetime('now'))
              ELSE handoff_ack_at END,
            need_type=$(sqlq "$type"), ask=$(sqlq "$ask"),
            need_options=$(sqlq_or_null "$options"),
            recommend=$(sqlq_or_null "$recommend"),
            secret_key=$(sqlq_or_null "$secret_key"),
            connector=$(sqlq_or_null "$connector"),
            ask_shape=$(sqlq_or_null "$ask_shape"),
            precedent_ref=${precedent_ref:-NULL},
            precedent_kind=$(sqlq_or_null "$precedent_kind"),
            -- DIVE-2241: the capability the filer DECLARED, recorded verbatim —
            -- including one that resolved to nothing. What was claimed is the
            -- provenance; whether it resolved is recomputable from the sealed
            -- list, and a mis-declaration you cannot see is one you cannot correct.
            needs_capability=$(sqlq_or_null "$needs"),
            tier=${tier}, need_asked_at=datetime('now'), gate_pinged_at=NULL,
            gate_filed_by=$(sqlq "$actor")
      WHERE id=${id};
      COMMIT;"

  # DIVE-891 tier 0: apply the recommendation right now — the gate exists only
  # as a signed-off record in the log/digest, never as a ping. Provenance is
  # 'auto:t0' (never human:*, so a loop approval gate can NOT be advanced this
  # way — _task_loop_advance requires human:*). No task_need_notify. The direct
  # answer write here intentionally skips cmd_task_answer's human-only checks:
  # tier 0 was validated above as outside every T2 category, which is exactly
  # the delegation the adopted design grants.
  if [[ "$tier" == "0" ]]; then
    local _ts0; _ts0=$(date -u '+%Y-%m-%d %H:%M:%S')
    db "UPDATE tasks SET need_answer=$(sqlq "$recommend"), need_answered_at=$(sqlq "$_ts0"),
          need_answered_by='auto:t0' WHERE id=${id};
        UPDATE tasks SET status='todo'
          WHERE id=${id} AND status='blocked'
            AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id});"
    # DIVE-2054: auto-clear applied from task-store data — fenced.
    _task_store_audit_log "task need t0-auto" "ok" 0 -- "task=$ident" "type=$type" "applied=$recommend" || true
    ok "$ident tier-0 gate auto-cleared — applied: $recommend" \
       '{id:($i|tonumber), ident:$id, tier:0, auto_applied:$rc, need_type:$ty}' \
       --arg i "$id" --arg id "$ident" --arg rc "$recommend" --arg ty "$type"
    return
  fi

  # OSS-21: tier-1 precedent auto-clear (behind pref precedent_autoclear, default
  # OFF). Runs AFTER tier resolution + the T2 floor (both unchanged) and AFTER the
  # main gate write above, so it can only ever act on a gate that has ALREADY
  # resolved to tier 1 — T0 returned above, and T2/HUMAN-CLASS are excluded by the
  # guard. Qualify precedent = EXACT ask_shape + same need_type, >=2 DISTINCT prior
  # gates answered by a VERIFIED human (see below) that were NOT themselves fuzzy-
  # prefilled (precedent_kind<>'fuzzy' — OSS-20's advisory fuzzy match can never
  # leak into the auto-clear seed set; exact human precedent only), IDENTICAL
  # need_answer, within
  # 90d, precedent tier >= 1, and ZERO contradicting human answers on that shape in
  # 90d (i.e. exactly ONE distinct human answer). On qualification we clear via the
  # SAME immediate direct-write path as tier-0/auto:ttl (never cmd_task_answer, so
  # NO human nonce is ever minted), provenance 'auto:precedent', precedent_ref = the
  # most-recent qualifying gate. The digest surfaces it through the auto:* Auto-
  # cleared section with the precedent citation (DIVE-891 path). Secret gates and
  # T2 provably never reach here; pref OFF is exact pre-OSS-21 behaviour.
  #
  # DIVE-2235 changes the SEED TEST, and this is the subtle half of the ticket.
  # The old filter was `need_answered_by LIKE 'human:%'`, with a comment saying
  # it excludes every auto:* seed — true, and it does stop the auto writers
  # compounding. But `human:<name>` is a SELF-DECLARATION written from the
  # caller's own username: on DIVE-2224 two agent self-clears were stamped
  # `human:olivia` and would have QUALIFIED AS HUMAN PRECEDENT. The guard built
  # to stop laundering was checking the one field that cannot be trusted. So the
  # seed now additionally requires a per-gate human nonce to have been minted and
  # survived to the answer (human_nonce_hash non-empty — _gate_archive_and_clear
  # nulls it on a re-file, so it can only be the nonce this answer was given).
  #
  # HONEST CONSEQUENCE, stated rather than discovered later: combined with the
  # class guard, the only class that still reaches here is 'decision', and
  # decision gates do not mint a nonce (_gate_human_class's list is the mint
  # list). So precedent auto-clear is INERT until decision gates mint — that is
  # the v0.18 "proof of who" work. Inert is the correct direction for a pref
  # that ships OFF and whose failure mode is "ask the human instead", but inert
  # AND SILENT is the DIVE-1935 shape, so the decline is logged loudly below.
  if [[ "$tier" == "1" && -n "$ask_shape" ]] && ! _gate_human_class "$type"; then
    local _ac; _ac=$(_task_pref_get precedent_autoclear); _ac="${_ac:-off}"
    if [[ "$_ac" == "on" ]]; then
      # One atomic read of the human-precedent set on this exact shape: newest
      # qualifying gate (id + its answer), the count of DISTINCT human answers
      # (>1 ⇒ contradiction ⇒ disqualified), and the total human-gate count.
      local _qrow
      _qrow=$(db "SELECT t1.id||x'1f'||COALESCE(t1.need_answer,'')||x'1f'||
          (SELECT COUNT(DISTINCT need_answer) FROM tasks
             WHERE need_answer IS NOT NULL AND id<>${id}
               AND need_type=$(sqlq "$type")
               AND ask_shape IS NOT NULL AND ask_shape=$(sqlq "$ask_shape")
               AND need_answered_by LIKE 'human:%'
               AND human_nonce_hash IS NOT NULL AND human_nonce_hash <> ''
               AND COALESCE(precedent_kind,'') <> 'fuzzy'
               AND COALESCE(tier,2) >= 1
               AND need_answered_at >= datetime('now','-90 day'))
          ||x'1f'||
          (SELECT COUNT(*) FROM tasks
             WHERE need_answer IS NOT NULL AND id<>${id}
               AND need_type=$(sqlq "$type")
               AND ask_shape IS NOT NULL AND ask_shape=$(sqlq "$ask_shape")
               AND need_answered_by LIKE 'human:%'
               AND human_nonce_hash IS NOT NULL AND human_nonce_hash <> ''
               AND COALESCE(precedent_kind,'') <> 'fuzzy'
               AND COALESCE(tier,2) >= 1
               AND need_answered_at >= datetime('now','-90 day'))
        FROM tasks t1
        WHERE t1.need_answer IS NOT NULL AND t1.id<>${id}
          AND t1.need_type=$(sqlq "$type")
          AND t1.ask_shape IS NOT NULL AND t1.ask_shape=$(sqlq "$ask_shape")
          AND t1.need_answered_by LIKE 'human:%'
          AND t1.human_nonce_hash IS NOT NULL AND t1.human_nonce_hash <> ''
          AND COALESCE(t1.precedent_kind,'') <> 'fuzzy'
          AND COALESCE(t1.tier,2) >= 1
          AND t1.need_answered_at >= datetime('now','-90 day')
        ORDER BY t1.need_answered_at DESC LIMIT 1;")
      # DIVE-2235: make the DECLINE observable. If no nonce-verified seed
      # qualified, count the seeds the OLD self-declaration filter would have
      # accepted. A non-zero count is exactly the laundering this change stops,
      # and it is the number that says "the nonce path is not live for this
      # class yet" — without this row the feature would simply never fire and
      # nothing would say why (DIVE-1935: inert while reporting itself working).
      if [[ -z "$_qrow" ]]; then
        local _unverified
        _unverified=$(db "SELECT COUNT(*) FROM tasks
             WHERE need_answer IS NOT NULL AND id<>${id}
               AND need_type=$(sqlq "$type")
               AND ask_shape IS NOT NULL AND ask_shape=$(sqlq "$ask_shape")
               AND need_answered_by LIKE 'human:%'
               AND COALESCE(precedent_kind,'') <> 'fuzzy'
               AND COALESCE(tier,2) >= 1
               AND need_answered_at >= datetime('now','-90 day');" 2>/dev/null || echo 0)
        [[ "$_unverified" =~ ^[0-9]+$ ]] || _unverified=0
        if (( _unverified > 0 )); then
          _task_store_audit_log "task need precedent-declined" "ok" 0 -- \
            "task=$ident" "type=$type" "unverified_seeds=$_unverified" \
            "reason=no_nonce_verified_precedent" || true
        fi
      fi
      if [[ -n "$_qrow" ]]; then
        local _qid _qans _qdistinct _qtotal
        IFS=$'\x1f' read -r _qid _qans _qdistinct _qtotal <<<"$_qrow"
        # Qualified: exactly one distinct human answer, backed by >=2 gates.
        if [[ "$_qdistinct" == "1" && "$_qtotal" -ge 2 && -n "$_qans" ]]; then
          # For a decision the consensus answer must ALSO be a current option
          # (shapes match but option sets can drift); if it isn't, fall through
          # to the normal human ping rather than apply an off-menu answer.
          local _dok=1
          if [[ "$type" == "decision" ]]; then
            _dok=$(printf '%s' "$options" | jq -Rr --arg r "$_qans" '
              [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ]
              | (($r | gsub("^\\s+|\\s+$"; "")) as $rr | any(.[]; . == $rr)) | if . then "1" else "0" end' 2>/dev/null) || _dok=0
          fi
          if [[ "$_dok" == "1" ]]; then
            local _tsp; _tsp=$(date -u '+%Y-%m-%d %H:%M:%S')
            db "UPDATE tasks SET need_answer=$(sqlq "$_qans"), need_answered_at=$(sqlq "$_tsp"),
                  need_answered_by='auto:precedent', precedent_ref=${_qid}, precedent_kind='exact'
                WHERE id=${id};
                UPDATE tasks SET status='todo'
                  WHERE id=${id} AND status='blocked'
                    AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id});"
            # DIVE-2054: same reasoning as "task need t0-auto" above — fenced.
            _task_store_audit_log "task need precedent-auto" "ok" 0 -- "task=$ident" "type=$type" "applied=$_qans" "precedent=$_qid" || true
            ok "$ident tier-1 gate auto-cleared from human precedent — applied: $_qans (precedent #$_qid)" \
               '{id:($i|tonumber), ident:$id, tier:1, need_type:$ty, auto_applied:$rc, need_answered_by:"auto:precedent", precedent_ref:($pr|tonumber)}' \
               --arg i "$id" --arg id "$ident" --arg ty "$type" --arg rc "$_qans" --arg pr "$_qid"
            return
          fi
        fi
      fi
    fi
  fi

  # DIVE-1145: ship-gating routing. Root-cause fix for builders over-filing
  # gates straight to the human (DIVE-1127/1142). Before the human ping, route a
  # NON-true-human builder gate to the org lead first, as an agent handoff. Gated
  # on pref `gate_builder_routing` (default OFF — same ship-safe posture as
  # OSS-21 precedent_autoclear; the lead flips it on after reviewing this diff).
  # Scope is deliberately DECISION-only in v1: decision gates are agent-clearable
  # (tier 1, no human_nonce) so the lead can actually resolve them, whereas
  # approval/manual/secret are enforced human-only by `task answer` (DIVE-1117
  # provenance floor) — routing those to an agent-reviewer needs the floor to
  # trust a designated reviewer, a deeper change deferred to a follow-up. We
  # never route a tier-2 gate — whether floored (true-human category: money/
  # destructive/secret, per _gate_tier2_floor_hit) OR filed with an
  # explicit --tier=2 (the caller's hard-human contract; 2 = never auto-applies,
  # always pings the human). Guarding on the EFFECTIVE tier (tier != 2) subsumes
  # the floor, since a floored gate always sets tier=2, and closes the hole where
  # `--type=decision --tier=2` with no floor keyword left tier_floored=0 and
  # silently routed past the human. We also never route one filed BY a lead
  # (_gate_route_reviewer returns empty → falls through to the human, which is
  # also how the lead re-escalates). Reviewer notify is best-effort + detached so
  # the 45s tmux-inject wait never blocks or fails the already-committed gate.
  # DIVE-1182 closes the DIVE-1145 gap: a builder's ship-gate is filed as
  # `approval` (or `manual`), NOT `decision`, so v1 left it human-only — it pinged
  # lodar instead of being clearable by the org lead (Marcus). We now route
  # approval/manual too, so a NON-true-human builder gate reaches the lead first.
  # `secret` is deliberately EXCLUDED (a secret must be delivered by a human,
  # never an agent), and tier-2 gates are never routed (guarded by tier != 2,
  # which subsumes the true-human category floor: money/destructive/secret).
  # Unlike decision (agent-clearable by type), approval/manual are human-only in
  # cmd_task_answer; routing them therefore PERSISTS routed_reviewer, the single
  # basis for the designated-reviewer floor exception there — so the exception is
  # scoped to exactly this routed gate + this reviewer, and every un-routed
  # approval/manual gate stays hard-human (DIVE-391/515/516 boundary intact).
  # Routability differs by type because of the tier-2 defaults:
  #   decision — defaults to tier 1, so `tier != 2` cleanly means "not pinned/
  #     floored hard-human" (subsumes explicit --tier=2 AND the category floor,
  #     which already ran above for tier<2).
  #   approval/manual — default to tier 2, so the effective tier can't discriminate.
  #     Route them UNLESS the caller EXPLICITLY pinned --tier=2 (hard-human
  #     contract) OR the ask/title hits the true-human category floor (money/
  #     destructive/secret) — the same floor decision that gates a decision,
  #     re-run here because the tier==2 short-circuit above skipped it for these.
  #   secret — never routable (must be delivered by a human).
  #
  # DIVE-1495: verifier-route. When the task carries a maker→verifier loop whose
  # VERIFIER is a distinct fleet agent, a decision/approval gate the maker files
  # is really a question FOR that verifier — not the paired human (CNCL-9: dev, as
  # maker, filed `task need --type=decision` to ask main the verifier and it
  # pinged lodar). Route it to the verifier's agent-send rail: they clear it via
  # `task answer` (already allowed for a decision; for approval the routed_reviewer
  # persisted below authorizes them, DIVE-1182). Intrinsic to the KIND, so it
  # bypasses the gate_builder_routing pref like eng-ship/curation. Never fires when
  # the filer IS the verifier (self-route — e.g. the max_iters escalation files
  # its manual gate --from the verifier) or on secret/manual/access. We still guard
  # tier!=2 so a money/brand/destructive decision stays human even inside a loop.
  # DIVE-2241: re-assert the declared human class AFTER every downgrade kind has
  # had its turn. eng-ship / curation / internal-ops / --discusses each force a
  # floored gate back down to a lead-routed tier-1, and they classify on the ask's
  # SHAPE ("this looks like a ship") — which a declared capability outranks, because
  # it states what the ask CONSUMES. One re-assert here rather than a veto bolted
  # onto each of the four guards: the DIVE-1957 lesson is that a promise held
  # per-branch is a promise that breaks when branch five is added.
  if [[ "$_needs_human" == "1" && "$tier" != "2" ]]; then
    warn "--needs=${needs} restored this gate to tier 2: a downgrade kind (eng-ship / curation / internal-ops / floor appeal) classified it as lead-clearable off the ask's shape, but you declared it consumes a human-held capability, and the declaration wins."
    tier=2; tier_floored=1
  fi

  local _verifier_route=0 _route_target=""
  if [[ ( "$type" == "decision" || "$type" == "approval" ) && "$tier" != "2" ]]; then
    local _vf; _vf=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_vf" && "$_vf" != "$actor" ]]; then
      # Confirm the verifier is a real fleet agent (a live maker→verifier loop by
      # construction, or present in the org chart) so we never misroute to a
      # non-agent token.
      local _vf_is_agent; _vf_is_agent=$(db "SELECT CASE WHEN
            (SELECT COALESCE(maker_agent,'') FROM tasks WHERE id=${id}) <> ''
            OR EXISTS(SELECT 1 FROM agents_org WHERE name=$(sqlq "$_vf"))
          THEN 1 ELSE 0 END;")
      [[ "$_vf_is_agent" == "1" ]] && { _verifier_route=1; _route_target="$_vf"; }
    fi
  fi
  local _routable=0
  case "$type" in
    decision) [[ "$tier" != "2" ]] && _routable=1 ;;
    approval|manual)
      if [[ "$tier_arg" != "2" ]]; then
        local _rt_title; _rt_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
        # DIVE-2224: identical axis call as the filing floor -- an approval/manual
        # gate must not be routable by one rule and floored by another.
        case "$(_gate_floor_axis "$ask" "$_rt_title")" in ask|title-fallback) ;; *) _routable=1 ;; esac
      fi ;;
    # DIVE-1243: the manager-clearable class routes to the lead FIRST regardless
    # of tier — that is the whole point of the type. The ONLY fall-through to the
    # human is the T2 category floor (money/destructive/secrets), which sets
    # tier_floored=1 above. An access gate is therefore routable unless floored.
    access) (( tier_floored )) || _routable=1 ;;
  esac
  # DIVE-1359: an eng-ship gate is lead-routed by kind (set above), so it is
  # always routable regardless of type default / explicit --tier.
  [[ "$_eng_ship" == "1" ]] && _routable=1
  # DIVE-1381: a content-curation gate is likewise lead-routed by kind.
  [[ "$_curation" == "1" ]] && _routable=1
  # DIVE-1480: an internal-ops/recovery gate the destructive floor over-fired on is
  # lead-routed by kind (set above), so the lead clears it instead of lodar.
  [[ "$_internal_ops" == "1" ]] && _routable=1
  # DIVE-2224 (answer A): a gate the floor declined to fire on BECAUSE the term was
  # in the title is lead-routed BY KIND. Being un-floored is not the same as being
  # routed -- with gate_builder_routing at its default (off) an ordinary tier-1 gate
  # still pings the paired human, so without this line answer A would move the tier
  # and change nothing about who gets woken, which is the entire point of the ticket.
  [[ "$_floored_by_title" == "1" ]] && _routable=1
  # DIVE-2089: a DECLARED-DISCUSSION appeal that survived every guard is
  # lead-routed by kind — the appeal's entire effect is "a reviewer instead of the
  # human", so it must not fall back to the human via the pref (rule 4).
  [[ "$_discusses_applied" == "1" ]] && _routable=1
  # DIVE-1495: a verifier-route gate is routable by kind (to the verifier agent).
  [[ "$_verifier_route" == "1" ]] && _routable=1
  # DIVE-1957: backstop — an EXPLICIT --tier=2 is the caller's hard-human contract
  # and no KIND-based override may cross it, so the DIVE-1145 promise ("we never
  # route a tier-2 gate, floored OR filed with an explicit --tier=2") holds by
  # construction instead of per-branch. eng-ship/curation/internal-ops are already
  # vetoed at the downgrade sites above; `access` is routable regardless of tier by
  # DIVE-1243 and was the last path a pinned gate could still reach an agent through.
  [[ "$tier_arg" == "2" ]] && _routable=0
  # DIVE-2241: THE constant resolution. A declared human-class capability resolves
  # to lodar — and "lodar" is not a name this router looks up, it is the human path
  # itself: refuse to hand the gate to ANY agent and let it fall through to
  # task_need_notify's human ping. That is what makes it a constant rather than a
  # row. It sits at the backstop with the DIVE-1957 tier-2 veto so no KIND-based
  # override above (eng-ship / curation / internal-ops / access / verifier-route)
  # can cross it — the verifier-route being the one this ticket exists to stop.
  [[ "$_needs_human" == "1" ]] && _routable=0
  # Record the declaration and what it did, at the moment it did it. DIVE-2093 will
  # PRINT the routing decision at file time; until it lands this row is the only
  # place a mis-declared gate is visible without diffing where it ended up.
  # DIVE-2054: task-store state for $ident, no channel proof — fenced.
  if [[ -n "$needs" ]]; then
    _task_store_audit_log "task need declared-capability" \
      "$( ((_needs_human)) && echo human-class || echo unrecognised )" 0 -- \
      "task=$ident" "type=$type" "declared=$needs" "filer=$actor" \
      "resolved=$( ((_needs_human)) && echo human || echo unchanged )" || true
  fi
  if [[ "$_routable" == "1" ]]; then
    # DIVE-1243: `access` routing is intrinsic to the TYPE, so it does NOT wait on
    # the gate_builder_routing pref (which ship-gates the decision/approval/manual
    # routing rollout). The other types still honour the pref.
    # DIVE-1359: eng-ship routing is likewise intrinsic to the KIND — it bypasses
    # the pref too, so the fix is live under the default (pref OFF) posture.
    local _route; _route=$(_task_pref_get gate_builder_routing); _route="${_route:-off}"
    # DIVE-2224: a title-only floor is intrinsic to the KIND too, and must bypass the
    # pref for the same reason eng-ship does. Routable-but-pref-gated would have left
    # answer A moving the TIER while the human still got the ping -- two layers, and
    # only the second one decides who is woken.
    if [[ "$_route" == "on" || "$type" == "access" || "$_eng_ship" == "1" || "$_curation" == "1" || "$_internal_ops" == "1" || "$_discusses_applied" == "1" || "$_verifier_route" == "1" || "$_floored_by_title" == "1" ]]; then
      # DIVE-1495: a verifier-route targets the task's verifier directly; every
      # other kind resolves the filer's lead via the org chart.
      local _reviewer
      if [[ "$_verifier_route" == "1" ]]; then _reviewer="$_route_target"; else _reviewer=$(_gate_route_reviewer "$actor"); fi
      if [[ -n "$_reviewer" ]]; then
        # Persist the designated reviewer on the row. For approval/manual this is
        # what authorizes agent-<_reviewer> to clear the gate later; for decision
        # it is provenance only (decision is already agent-clearable by type).
        db "UPDATE tasks SET routed_reviewer=$(sqlq "$_reviewer") WHERE id=${id};"
        local _rrole="lead review"; [[ "$_verifier_route" == "1" ]] && _rrole="verifier review"
        # DIVE-2011: the handoff goes through the SAME delivery assertion as the
        # human ping (task_need_notify dispatches on TASK_GATE_ROUTE_TO), so a
        # routed gate can no longer exit without a delivery verdict or leave the
        # one dataset DIVE-1968 reads with no row for it. TASK_GATE_FILER pins the
        # send's `--from` to the gate's own filer for the same reason the human
        # path sets it: under `sudo -u agent-X` the ambient identity is the
        # invoker, not the filer.
        local _nrc=0
        TASK_GATE_FILER="$actor" TASK_GATE_ROUTE_TO="$_reviewer" TASK_GATE_ROUTE_ROLE="$_rrole" \
        TASK_GATE_FLOORED_BY="$([[ "$_floored_by_title" == "1" ]] && printf 'title' || printf '')" \
          task_need_notify "$ident" "$type" "$ask" "$options" "$recommend" || _nrc=$?
        # Never print a bare "routed to X" on an unobserved send again. The claim
        # is exactly what the delivery state supports: pinged, not-yet, or NOT.
        local _rstate="${TASK_GATE_ROUTE_STATE:-inflight}" _rnote=""
        # DIVE-2011 (olivia's second finding on DIVE-1968, read off the installed
        # binary): this audit row's result was a HARDCODED "ok", so the routed rail
        # did not merely emit nothing to the telemetry — it emitted a GREEN row for a
        # send whose exit status had been discarded. An absent row is a gap; a false
        # green is worse, because it is the shape a reader trusts. The row now
        # carries the delivery verdict, and is only `ok` when the send was confirmed.
        local _rres="ok" _rrc=0
        [[ "$_rstate" == "failed" ]] && { _rres="error"; _rrc=1; }
        # DIVE-2054: internal lead-routing telemetry keyed off task-store data —
        # unlike the escalate-to-human/clear-recs exemptions this carries no
        # channel/chat proof, so fenced (not exempted).
        _task_store_audit_log "task need lead-route" "$_rres" "$_rrc" -- "task=$ident" "type=$type" \
          "reviewer=$_reviewer" "filer=$actor" "delivery=$_rstate" || true
        case "$_rstate" in
          delivered) ;;
          inflight)  _rnote=" [handoff dispatched — delivery not yet confirmed; the gate-delivery row lands when the send completes]" ;;
          *)         _rnote=" [HANDOFF NOT DELIVERED — ${_reviewer} was NOT pinged${TASK_NOTIFY_FAIL_REASON:+ (${TASK_NOTIFY_FAIL_REASON})}; the gate stands, the re-nag escalates it (<=15 min), and it is answerable now with: 5dive task answer ${ident}]" ;;
        esac
        # DIVE-2224: when the floor declined to fire only because the term was in the
        # TITLE, say so HERE. A stderr warn is not the durable surface -- the routed
        # reviewer reads this line, and "escalate if the ask really is asking for
        # that" is only actionable if they are told which term and from where.
        local _fbt=""
        [[ "$_floored_by_title" == "1" ]] && _fbt=" [floored_by=title: the T2 category floor matched '$(_gate_tier2_floor_term "$_ft_title")' in the TASK TITLE, not in the ask — escalate to the human if the ask really is asking for that]"
        ok "$ident routed to $_reviewer for ${_rrole} ($type, tier $tier)${_rnote}${_fbt} — $ask" \
           '{id:($i|tonumber), ident:$id, status:"blocked", need_type:$ty, tier:($tr|tonumber), routed_to:$rv, delivery:$ds, notified:($ds=="delivered"), ask:$ak, recommend:(($rc|select(length>0)) // null)}' \
           --arg i "$id" --arg id "$ident" --arg ty "$type" --arg tr "$tier" --arg rv "$_reviewer" --arg ds "$_rstate" --arg ak "$ask" --arg rc "$recommend"
        # No separate undelivered row: the lead-route row above already carries
        # delivery=<state>, and a second row for the same event is how one send
        # becomes two data points (the re-inflation DIVE-1968 spent a round undoing).
        return
      fi
    fi
  fi

  # DIVE-2004: LOUD AT FILE TIME. Reaching here means the gate was NOT lead-routed,
  # so it has no routed_reviewer. A `decision` in that state can be answered by any
  # agent, which is exactly why delegated push will not accept it — and the filer
  # only finds out later, from a refusal that reads as if the answerer was at
  # fault. If the ask is push-for-review shaped, say so now, while the filer is
  # still standing here and re-filing costs nothing. Deliberately narrow: the ask
  # must LOOK like a push gate, the type must be the one push cannot attribute, and
  # the gate must be unrouted — a warning that fires on ordinary decisions would be
  # wallpaper (DIVE-1955).
  if [[ "$type" == "decision" ]] && _gate_eng_ship_hit "$ask"; then
    warn "$ident is a push-for-review ask filed as --type=decision with no routed reviewer, so '5dive push' will REFUSE it: an unrouted decision can be answered by any agent, and push only accepts a human, a lead-clear, or a decision answered by this gate's own routed reviewer. Re-file with --type=approval (it routes to the org lead as a tier-1 they can clear), or keep the decision and route it to a reviewer."
  fi

  # DIVE-105: DM the paired human right now so the gate doesn't sit unseen.
  # `|| true` + the helper's own self-gating make this fully best-effort — a
  # failed DM must never fail the gate write that just committed above.
  # DIVE-891: tier 1 gates still notify (they're answerable early); the 48h TTL
  # is a backstop, not a silencer. Only tier 0 skips the ping.
  # DIVE-916: mint the per-gate HUMAN nonce for hard human gates (approval/
  # secret/manual — the types `task answer` enforces as human-only). Store ONLY
  # its hash; the raw nonce is handed to task_need_notify to embed in the tap
  # callback_data. It is never printed to stdout, so the agent that filed the
  # gate never sees it. decision gates are agent-clearable → no nonce.
  # DIVE-1243: `access` mints a nonce too. It only reaches this human-ping path
  # when it FELL THROUGH to a human — either the T2 category floor fired (genuine
  # human-territory) or the org named no distinct lead (the filer IS the lead, who
  # is re-escalating). Both are legitimate human clears, so it needs the same
  # tap-safe nonce as approval/secret/manual for the Telegram tap.
  #
  # DIVE-2356 (from the DIVE-2355 measurement): the mint was gated on gate TYPE
  # ALONE, and the "decision gates are agent-clearable → no nonce" line above is
  # true only at tier 0/1. A `decision` FLOORED to tier 2 is by definition NOT
  # agent-clearable — the DIVE-1117 floor refuses a non-human answer on it — yet
  # it minted nothing, so it carried no per-gate human evidence at all. Measured
  # across every answered gate on the live board: approval/manual/secret tier-2
  # were 40/40 nonce-SET, decision tier-2 was 4/47 (and those 4 came from the
  # escalate-to-human path below, the one unconditional mint). So the mint
  # condition is now "hard-human TYPE **or** tier>=2", which is what the DIVE-916
  # comment always meant by "the types `task answer` enforces as human-only".
  #
  # ORDERING, DELIBERATE — this ships ALONE. The companion rule (refuse a tier-2
  # answer whose human_nonce_hash IS NULL) must NOT land until tier-2 decision
  # gates have accumulated nonces in the wild: shipped together, it would refuse
  # the overwhelming majority of tier-2 decision answers, i.e. the dominant
  # working path. Safe to land alone on the ANSWER side, which is the side that
  # could break: the tier-2 floor in cmd_task_answer is provenance-only
  # (`(( ! human ))`), and the DIVE-916 evidence block never fires for `decision`.
  #
  # BUT THE HASH IS NOT INERT, AND AN EARLIER DRAFT OF THIS COMMENT SAID IT WAS.
  # `_proof_ledger` (cmd_proof.sh) counts a done row as an ASK when
  # `human_nonce_hash IS NOT NULL`, as an OR-arm beside the human-answered test,
  # and the published zero-human badge is `1 - asks/shipped`. Measured on the live
  # board when this landed: 704 shipped, 101 asks, of which 20 came from the nonce
  # arm ALONE — rows with no human answer at all, counted only because a nonce
  # existed. So widening the mint moves a PUBLISHED METRIC DOWNWARD, and every
  # future tier-2 decision joins that arm.
  #
  # That is intended, not incidental. A tier-2 decision IS a human ask; counting
  # it is more truthful than not, and the ledger's own header says the arm is
  # deliberately conservative so the badge understates autonomy rather than
  # flattering it. Named here because the comment above that query warns against
  # moving this metric as a SIDE EFFECT — which is a rule about surprise, not
  # about direction, and so applies to lowering it too.
  #
  # If you are here to add a nonce mint somewhere new: check what it does to the
  # ledger before you assume it is a no-op. This one was assumed to be.
  #
  # NOT DONE HERE, on purpose: the minted nonce is not yet reachable by a decision
  # TAP. `_task_gate_reply_markup` appends `:${nonce}` to callback_data for
  # approval/secret/manual but not for the decision option buttons, and
  # telegram-pi's parser is `^tna:(\d+):(.+)$` (greedy) — appending there would
  # swallow the nonce into the option token and break decision taps on pi
  # runtimes. That is a plugin-side fix (all four TNA_RE variants) and its own
  # ticket; until it lands the hash is at-rest evidence only, which is exactly
  # and only what the refuse-on-NULL rule needs.
  local human_nonce="" _mint_nonce=0
  case "$type" in approval|secret|manual|access) _mint_nonce=1 ;; esac
  [[ "${tier:-}" =~ ^[0-9]+$ ]] && (( tier >= 2 )) && _mint_nonce=1
  if (( _mint_nonce )); then
    human_nonce=$(_human_nonce_mint)
    [[ -n "$human_nonce" ]] \
      && db "UPDATE tasks SET human_nonce_hash=$(sqlq "$(_human_nonce_sha "$human_nonce")") WHERE id=${id};"
  fi
  # DIVE-1927: rc 3 = filed and answerable, but NOBODY was pinged. The gate always
  # stands — the dashboard "Needs you" card, `task inbox` and `task answer` need no
  # channel, and a headless/solo/CI box answers gates exactly that way. What must
  # never happen is an unnotified gate reading identically to a notified one, which
  # is the indistinguishability this whole ticket started from, so the miss is
  # marked on the result, logged as a delivery error, left with gate_pinged_at NULL
  # and re-driven by the 15-minute re-nag until it lands.
  # TASK_GATE_FILER pins the escalation chain to the gate's OWN filer. Without it
  # the chain starts from the ambient identity (auto_sender_from_sudo), which under
  # a `sudo -u agent-X` invocation is the INVOKER, not the filer — so the walk
  # would climb the wrong branch of the org chart.
  local _nrc=0
  TASK_GATE_FILER="$actor" \
    task_need_notify "$ident" "$type" "$ask" "$options" "$recommend" "$secret_key" "$connector" "$human_nonce" "$precedent_cite" || _nrc=$?
  # DIVE-2010: this used to also require $EUID to be root before auditing — the
  # exact anti-pattern audit.sh's own audit_log doc says never to use (it
  # predates _emit_audit_line's non-root privileged fallback, DIVE-1989) AND
  # carried no store-identity fence, so a fixture-TASKS_DB suite run as root
  # wrote real-looking rows with fixture idents into the real audit log. Fixed
  # by dropping the root condition (audit_log/_task_store_audit_log handle the
  # non-root case) and routing through the store fence instead.
  [[ "$_nrc" == "3" ]] \
    && _task_store_audit_log "task need unnotified" "error" 1 -- "task=$ident" "type=$type" "filer=$actor" || true
  # DIVE-2089 defect 2 — the floor was SILENT about WHY. "[tier forced to 2 — T2
  # category floor]" says an escalation happened but not what caused it, so the
  # filer cannot tell a correct escalation from a subject-matter false positive,
  # and cannot act on either. dev3 discovered their sizing gate had been floored
  # only by re-reading it; an agent that files and moves on leaves a design
  # question in the founder's inbox indefinitely. Name the matched term on the
  # result AND warn on stderr, and — for a decision gate, the one type where an
  # appeal exists — say what the sanctioned appeal is. Stating the appeal here is
  # the anti-laundering lever: the filer who would otherwise re-file with neutral
  # wording is shown an attributable, audited path to the same audience.
  local floor_note="" floor_term=""
  # DIVE-2241: a DECLARED human-class gate is also tier_floored, but it did not get
  # there by the keyword floor — so it must not wear the floor's explanation. Saying
  # "the T2 category floor fired" over a declaration is wrong twice: it credits a
  # match that may not exist (floor_term comes back empty and the note degrades to a
  # bare claim), and it hands the filer the --discusses appeal for a category call
  # they made THEMSELVES. Nobody should be invited to appeal their own declaration.
  if [[ "$_needs_human" == "1" ]]; then
    floor_note=" [tier 2 — DECLARED --needs=${needs}, a human-held capability; routed to the paired human, not to a lead or verifier]"
    warn "this gate is hard-human because you DECLARED --needs=${needs}. It bypasses lead- and verifier-routing by constant, and only the paired human can answer it. If the ask does not actually consume that capability, withdraw and re-file without --needs — do not appeal it, the declaration is yours."
  elif (( tier_floored )); then
    floor_term=$(_gate_tier2_floor_term "${ask} $(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")")
    floor_note=" [tier forced to 2 — T2 category floor${floor_term:+: matched '$floor_term'}]"
    local _fw="this gate was FORCED to tier 2 (hard human) by the T2 category floor"
    [[ -n "$floor_term" ]] && _fw="$_fw because the ask or the task title contains '${floor_term}'"
    if [[ "$type" == "decision" && -z "$discusses" ]]; then
      _fw="$_fw. The floor matches SUBJECT MATTER, not the action you asked for. If this decision only DISCUSSES that category and performs nothing, re-file with --discusses=\"<why>\" — it is recorded on the gate and routed to your lead. Do NOT reword the ask to dodge the floor: that reaches the same audience with no record of how."
    else
      _fw="$_fw. It is answerable only by the paired human."
    fi
    warn "$_fw"
  fi
  local prec_note=""; [[ -n "$precedent_cite" ]] && prec_note=" [${precedent_cite}]"
  # rc 3 = filed, answerable, but nobody was PINGED. Say so on the record instead
  # of letting an unnotified gate read exactly like a notified one — that
  # indistinguishability is the whole defect this ticket started from.
  local notified=1 unnotified_note=""
  if [[ "$_nrc" == "3" ]]; then
    notified=0
    unnotified_note=" [UNNOTIFIED — nobody was pinged; answer on the dashboard or: 5dive task answer ${ident}]"
  fi
  ok "$ident needs a human ($type, tier $tier)${floor_note}${prec_note}${unnotified_note} — $ask" \
     '{id:($i|tonumber), ident:$id, status:"blocked", need_type:$ty, tier:($tr|tonumber), tier_floored:($fl=="1"), floor_term:(($ft|select(length>0)) // null), needs_capability:(($nc|select(length>0)) // null), needs_human:($nh=="1"), notified:($nf=="1"), ask:$ak, need_options:(($op|select(length>0)) // null), recommend:(($rc|select(length>0)) // null), precedent_ref:(($pr|select(length>0)|tonumber?) // null), assignee:$ac}' \
     --arg i "$id" --arg id "$ident" --arg ty "$type" --arg tr "$tier" --arg fl "$tier_floored" --arg ft "$floor_term" --arg nc "$needs" --arg nh "$_needs_human" --arg nf "$notified" --arg ak "$ask" --arg op "$options" --arg rc "$recommend" --arg pr "$precedent_ref" --arg ac "$actor"
}

# _task_owner_channel — resolve the filing agent's bot token + the per-type
# access.json that holds the paired human's DM/group targets. Sets globals
# TASK_CH_TOKEN / TASK_CH_ACCESS / TASK_CH_TYPE and returns 0 on success, 1 if
# anything is missing (so callers `_task_owner_channel || return 0` to stay
# best-effort — a missing channel must never fail a committed DB write). Works
# whether run directly as agent-<name> (common — task verbs need no sudo) or via
# sudo (resolved like task_actor; token from the group-claude-readable connector
# file or an inherited env var). Shared by task_need_notify + _task_close_notify.
TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE=""
# DIVE-1927: set by task_need_notify when the alert was escalated off an unpaired
# filer, so the message can name whose ask the recipient is looking at.
TASK_NOTIFY_ESCALATED_FROM=""
# DIVE-1927: why the alert could not be delivered, so the caller's hard failure
# states what we actually know rather than the worst-sounding of the two causes.
TASK_NOTIFY_FAIL_REASON=""
# DIVE-1968: the privileged re-send's stderr, kept so the parent can name WHY it
# failed instead of only THAT it did. Empty when it succeeded or was never run.
TASK_GATE_ESCALATE_ERR=""
# DIVE-891: the by-NAME half of the resolution, split out so the heartbeat's
# gate-TTL sweep (which runs as root from cron — no sudo chain, no agent-* USER)
# can resolve a FILING AGENT's channel per gate row instead of from the caller.
_task_agent_channel() {
  # DIVE-2073: TASK_CH_AGENT is set HERE, not only in _task_chain_channel. This
  # is the one resolver every send path funnels through (own channel, by-name
  # privileged, chain walk), so it is the only place that can name WHOSE bot
  # carried a message on all of them. Without it the delivery row could say a
  # message_id but never which bot's id space it lives in — and since each bot
  # holds its OWN conversation with the same human, ids from different bots are
  # not comparable. That is exactly why DIVE-1927's residual 2 could not be
  # discharged from the log alone.
  TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE="" TASK_CH_AGENT=""
  local name="$1"
  [[ -n "$name" ]] || return 1
  local token="" token_file="${CONNECTORS_DIR}/telegram-${name}.env"
  [[ -r "$token_file" ]] && token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$token_file" | head -1)
  [[ -z "$token" ]] && token="${TELEGRAM_BOT_TOKEN:-}"
  [[ -n "$token" ]] || return 1
  local t d
  for t in claude codex grok antigravity; do
    d=$(_tg_access_state_dir "agent-${name}" "$t") || continue
    if [[ -r "${d}/access.json" ]]; then
      TASK_CH_TOKEN="$token" TASK_CH_ACCESS="${d}/access.json" TASK_CH_TYPE="$t" TASK_CH_AGENT="$name"
      return 0
    fi
  done
  return 1
}

_task_owner_channel() {
  local name="" s
  s=$(auto_sender_from_sudo)
  if [[ -n "$s" ]]; then
    name="$s"
  else
    local u="${USER:-$(id -un 2>/dev/null)}"
    [[ "$u" == agent-* ]] && name="${u#agent-}"
  fi
  _task_agent_channel "$name"
}

# DIVE-1927: is <name> PAIRED AT ALL — independent of whether THIS uid may read
# its access.json? Every agent's channel dir is 0700 and its access.json 0600, so
# a sibling agent can NEVER read a peer's pairing state; the parent .../channels
# dir is 0755 root:root, so a bare -d probe still answers. Pairing = a resolvable
# bot token (connector files are group-claude readable) AND an existing per-type
# channel dir. This is the only honest way to tell "nobody is reachable" (the gate
# must then fail LOUDLY) apart from "reachable, but I lack the privilege to read
# the target" (re-run the send as root). Getting that distinction wrong is exactly
# how DIVE-1243's lead fallback degraded into a silent no-op: it probed
# readability, read Permission-denied as "unpaired", and returned OK.
# Three-valued ON PURPOSE: 0 = paired, 1 = PROVABLY not paired, 2 = undetermined
# (we are blind, because something we needed to look at exists but is forbidden,
# or sits behind a directory we may not search). Only a PROVABLE 1 may be treated
# as "this ask can reach nobody" — an undetermined 2 must be handled like paired,
# i.e. escalated to a privileged sender who can actually see.
#
# The three-valued return is the whole point. A boolean here would reintroduce the
# absent-vs-forbidden conflation ONE LAYER OVER: the connector env is currently
# 0640 root:claude and every agent is in group claude, so a plain `-r` works today
# — but the day a connector file is tightened to 0600, or an agent lands outside
# group claude, an unreadable token would read as "unpaired". Before this fix that
# would have cost a delayed gate. WITH the fail-closed `task need` it would REFUSE
# a gate on a chain that is perfectly fine. Absence and denial must never share an
# answer in a probe whose false-negative refuses work. (Found by main reviewing
# PR #160 — the second instance of the exact mechanism the fix exists to remove,
# inside the fix. Third instance the same night: DIVE-1929, where
# os.path.exists() answers False under a mode-700 home.)
_task_agent_paired() {
  local name="${1:-}"; [[ -n "$name" ]] || return 1
  local blind=0 token="" token_file="${CONNECTORS_DIR}/telegram-${name}.env"
  if [[ -r "$token_file" ]]; then
    # Readable and genuinely tokenless is the one case that PROVES unpaired.
    token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$token_file" | head -1)
    [[ -n "$token" ]] || return 1
  elif [[ -e "$token_file" ]]; then
    blind=1                                   # exists, forbidden -> not evidence
  elif [[ ! -d "$CONNECTORS_DIR" || ! -x "$CONNECTORS_DIR" ]]; then
    blind=1                                   # can't even search the dir -> ditto
  else
    return 1                                  # dir searchable, file really absent
  fi

  local t d
  for t in claude codex grok antigravity; do
    d=$(_tg_access_state_dir "agent-${name}" "$t") || continue
    [[ -d "$d" ]] || continue
    (( blind )) && return 2
    return 0
  done
  # No channel dir found. Same question again: absence, or blindness? A home we
  # may not traverse cannot tell us anything about what is inside it.
  local home="/home/agent-${name}"
  [[ -d "$home" && -x "$home" ]] || return 2
  (( blind )) && return 2
  return 1
}

# DIVE-1968: WHY is this filer's chain empty? Three unrelated causes produced one
# indistinguishable message, and that is why 28 real rows sat unreadable underneath
# ~840 fixture ones. Naming the shape in the detail is what makes the acceptance
# criterion ("zero error rows on production-store idents") checkable at all: a row
# that cannot say what happened cannot be triaged, only counted.
#   absent-from-org  the filer has NO agents_org row at all. It can file gates while
#                    being outside the structure the rail walks, and nothing
#                    reconciles the two. Largest real shape measured: 13 of 28.
#   top-of-org       the filer IS in the chart and has no manager. Real, and 1 of 28.
#   no-chain         in the chart, has a manager, chain still came back empty — the
#                    shape neither the ticket nor the diagnosis named. 13 of 28, and
#                    it is the reason this labelling landed BEFORE any rail fix.
_task_filer_chain_shape() {
  local filer="${1:-}" n rt
  [[ -n "$filer" ]] || { printf 'no-filer'; return 0; }
  n=$(db "SELECT COUNT(*) FROM agents_org WHERE name=$(sqlq "$filer");" 2>/dev/null) || n=""
  [[ -n "$n" ]] || { printf 'org-unreadable'; return 0; }   # a failed read is NOT an empty org
  [[ "$n" == "0" ]] && { printf 'absent-from-org'; return 0; }
  rt=$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$filer") LIMIT 1;" 2>/dev/null) || rt=""
  [[ -z "$rt" ]] && { printf 'top-of-org'; return 0; }
  printf 'no-chain'
}

# DIVE-1927: emit the escalation chain for <filer> — every candidate recipient
# ABOVE it, nearest manager first, ending with the coordinator. Cycle-guarded and
# depth-capped so a reports_to loop can never spin. The filer itself is never
# emitted. This is the multi-hop generalisation of _gate_route_reviewer (which
# stops at ONE hop + coordinator): if dev3 -> main -> olivia and main is unpaired,
# the ask still has to reach olivia rather than dying at the first miss.
_task_escalation_chain() {
  local filer="${1:-}" seen=$'\n' hops=0 nxt cur
  cur="$filer"
  [[ -n "$filer" ]] || return 0
  while (( hops < 8 )); do
    nxt=$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$cur") LIMIT 1;" 2>/dev/null) || nxt=""
    [[ -n "$nxt" && "$nxt" != "$filer" ]] || break
    [[ "$seen" == *$'\n'"$nxt"$'\n'* ]] && break
    seen+="${nxt}"$'\n'
    printf '%s\n' "$nxt"
    cur="$nxt"; hops=$((hops+1))
  done
  local coord; coord=$(_task_resolve_coordinator)
  [[ -n "$coord" && "$coord" != "$filer" && "$seen" != *$'\n'"$coord"$'\n'* ]] && printf '%s\n' "$coord"
  return 0
}

# DIVE-1927 (review round 2): does this DEPLOYMENT deliver gates by channel at
# all? A box with no channel anywhere — solo OSS, fresh install, CI, any headless
# environment — answers gates on the dashboard "Needs you" card or with
# `5dive task answer`, and there an unnotified gate is the NORMAL mode rather
# than a failure. This is the discriminator for the hard refusal: only where
# notification IS the delivery mechanism does "reached nobody" mean a human will
# never see the ask.
# Deliberately fails PERMISSIVE: an unreadable/absent connector dir answers
# "no channels", i.e. never refuse. That is the same absent-vs-forbidden
# ambiguity as everywhere else on this page, pointed at the safe side on purpose
# — a probe whose false negative REFUSES work must never guess in that direction.
_task_deployment_has_channels() {
  local f
  for f in "${CONNECTORS_DIR}"/telegram-*.env; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

# DIVE-1927: resolve the nearest channel up the chain that THIS uid can actually
# read. Sets TASK_CH_* (the send target) and TASK_CH_AGENT (whose it is); returns
# 1 if none is readable from here. It must NEVER be called in a command
# substitution — that runs it in a subshell and the TASK_CH_* it resolved die
# with it, leaving the caller to "successfully" send with an empty token to an
# empty access file. Hence the name comes back in a GLOBAL, not on stdout.
TASK_CH_AGENT=""
_task_chain_channel() {
  local filer="$1" c
  local -a chain=()
  TASK_CH_AGENT=""
  mapfile -t chain < <(_task_escalation_chain "$filer")
  for c in "${chain[@]}"; do
    [[ -n "$c" ]] || continue
    if _task_agent_channel "$c"; then TASK_CH_AGENT="$c"; return 0; fi
  done
  return 1
}

# DIVE-1927: is anyone up the chain PAIRED (i.e. deliverable by a privileged
# run, even though this uid can't read their access.json)? Echoes the first such
# agent. Empty + rc 1 means the ask is genuinely undeliverable to any human.
_task_chain_paired() {
  local filer="$1" c rc
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    _task_agent_paired "$c"; rc=$?
    # 0 paired, 2 undetermined — both mean "a privileged sender may well reach
    # this agent", and only an all-1 chain licenses refusing the gate.
    [[ "$rc" == "0" || "$rc" == "2" ]] && { printf '%s' "$c"; return 0; }
  done < <(_task_escalation_chain "$filer")
  return 1
}

# DIVE-1927: re-run this gate's alert as root, which can read every agent's
# access.json. Agents carry NOPASSWD sudo for the 5dive binary, so this is the
# one privilege step that turns a reachable-but-unreadable manager channel into a
# real delivery. The raw human nonce goes over STDIN (the DIVE-880 `-` sentinel),
# never argv, so it can't leak through ps/audit. Returns the child's status:
# 0 delivered, non-zero not delivered (the caller then fails loudly).
_task_gate_escalate_via_sudo() {
  local ident="$1" nonce="${2:-}"
  command -v sudo >/dev/null 2>&1 || return 1
  # MUST be the installed path: agents' sudoers grants NOPASSWD for exactly
  # `/usr/local/bin/5dive` (and `/usr/local/bin/5dive *`). A `command -v` result
  # pointing at a worktree/dev build would be REFUSED by sudo, so the escalation
  # would fail for a reason that has nothing to do with the channel.
  local cli=/usr/local/bin/5dive
  [[ -x "$cli" ]] || cli=$(command -v 5dive 2>/dev/null) || return 1
  [[ -n "$cli" ]] || return 1
  # DIVE-1968: KEEP THE CHILD'S REASON. This used to be `>/dev/null 2>&1`, so the
  # parent could only ever report "privileged re-send FAILED" with no cause, and a
  # whole diagnosis round went into deciding whether sudo had refused the
  # invocation or gate-escalate had returned non-zero for its own reason — a
  # distinction the child prints and we were throwing away. Stdout stays discarded
  # (it is the ok/JSON envelope); stderr is captured into a global the caller names
  # in its warn and its audit row. Truncated because it rides a log line.
  TASK_GATE_ESCALATE_ERR=""
  local _err _rc=0
  _err=$(printf '%s' "$nonce" | sudo -n "$cli" task gate-escalate "$ident" --nonce=- 2>&1 >/dev/null) || _rc=$?
  TASK_GATE_ESCALATE_ERR="${_err//$'\n'/ }"
  TASK_GATE_ESCALATE_ERR="${TASK_GATE_ESCALATE_ERR:0:300}"
  return $_rc
}

# DIVE-1927: `5dive task gate-escalate <ident> [--nonce=-]` — internal, root-only.
# Re-send an ALREADY-FILED, still-pending gate's alert from a privileged context
# so the escalation chain can be read. It mints nothing and decides nothing: the
# recipient, text, options and tier all come from the stored row, so the only
# thing this verb can do is deliver an ask that is already on the board to the
# human it was always meant for. Refuses anything that is not a live gate.
# Undocumented in `task --help` (not an operator verb) but usable by hand for
# recovery. Exit 0 = delivered, non-zero = not delivered.
cmd_task_gate_escalate() {
  tasks_db_init
  local ident_arg="" nonce=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --nonce=-) IFS= read -r nonce || true ;;
      --nonce=*) fail "$E_USAGE" "--nonce accepts only '-' (read from stdin)" ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         [[ -z "$ident_arg" ]] && ident_arg="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$ident_arg" ]] || fail "$E_USAGE" "usage: 5dive task gate-escalate <ident>"
  # DIVE-1968: through the `_gate_is_root` seam (already the convention in this file,
  # see the DIVE-1401 withdraw path) rather than reading $EUID inline. $EUID is
  # READONLY in bash, so an inline test makes this verb unreachable from a unit
  # harness — and an unreachable verb is how the hardcoded audit code below survived
  # since DIVE-1927. Same lesson as the rest of this ticket: a check nobody can
  # exercise is a check nobody can trust.
  _gate_is_root || fail "$E_PERMISSION" "task gate-escalate must run as root (it reads other agents' channel state)"

  resolve_task_id "$ident_arg"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # DIVE-1945: the filer is the gate's FILER-OF-RECORD (gate_filed_by, stamped by
  # cmd_task_need from the acting agent), NOT the task's created_by. They differ
  # whenever one agent files a gate on another agent's task — and then this walked
  # the CREATOR's branch of the org chart and the alert read "filed by <creator>
  # (no channel of its own)", wrong attribution about an agent that may well have
  # one. Same bug DIVE-1927 fixed on the `task need` path via TASK_GATE_FILER,
  # surviving here because this process cannot see that env var: it is a separate
  # privileged run driven by the re-nag, so the filer has to come off the ROW.
  # created_by remains the fallback for gates filed before the column existed.
  local grow
  grow=$(db "SELECT COALESCE(need_type,'')||x'1f'||COALESCE(ask,'')||x'1f'||COALESCE(need_options,'')||x'1f'||
                    COALESCE(recommend,'')||x'1f'||COALESCE(secret_key,'')||x'1f'||COALESCE(connector,'')||x'1f'||
                    COALESCE(NULLIF(gate_filed_by,''),NULLIF(created_by,''),assignee,'')
             FROM tasks
             WHERE id=${id} AND need_type IS NOT NULL AND need_answered_at IS NULL
               AND status NOT IN ('done','cancelled');")
  [[ -n "$grow" ]] || fail "$E_CONFLICT" "$ident is not a pending gate — nothing to escalate"
  local nt ask opts rec skey conn filer
  IFS=$'\x1f' read -r nt ask opts rec skey conn filer <<<"$grow"

  # TASK_GATE_ESCALATING stops the recursion: this IS the privileged run, so a
  # miss here must fall through to the loud failure, never re-sudo itself.
  local rc=0
  TASK_SEND_DELIVERED=0
  TASK_GATE_ESCALATING=1 TASK_GATE_FILER="$filer" \
    task_need_notify "$ident" "$nt" "$ask" "$opts" "$rec" "$skey" "$conn" "$nonce" "" || rc=$?
  # A resolved channel is NOT a delivery. task_need_notify is best-effort about
  # the actual Bot API call, so this verb — whose entire contract is "the ask
  # reached a human" — asserts the CONFIRMED receipt, not the attempt. Reporting
  # ok on an unconfirmed send would rebuild the exact bug this fixes one layer up.
  [[ "$rc" == "0" && "${TASK_SEND_DELIVERED:-0}" != "1" ]] && rc=2
  if [[ "$rc" == "0" ]]; then
    # DIVE-2054: task-store re-send outcome — fenced.
    _task_store_audit_log "task gate-escalate" "ok" 0 -- "task=$ident" "type=$nt" "filer=${filer:-unknown}" || true
    ok "$ident gate alert re-sent from a privileged context (filer ${filer:-unknown} is unpaired)" \
       '{ident:$id, escalated:true, filer:$f}' --arg id "$ident" --arg f "$filer"
    return 0
  fi
  # DIVE-1968: the code was a hardcoded `1`, so the ONE durable record of this verb
  # could not distinguish rc=2 (a channel resolved, the Bot API send was simply not
  # confirmed) from a genuine no-recipient failure — and the message below asserts
  # the second reading whichever happened. Record the real rc, and say which of the
  # two it was, because "zero error rows after ship" is only checkable if the rows
  # can say what happened.
  # DIVE-2054: same reasoning as the "ok" branch above — fenced.
  _task_store_audit_log "task gate-escalate" "error" "$rc" -- "task=$ident" "type=$nt" "filer=${filer:-unknown}" "rc=$rc" || true
  if [[ "$rc" == "2" ]]; then
    fail "$E_AUTH_REQUIRED" "$ident: a channel WAS resolved in the chain above ${filer:-the filer}, but the Bot API send was not confirmed — delivery is UNVERIFIED, not refused (DIVE-1968)."
  fi
  fail "$E_AUTH_REQUIRED" "$ident could not be delivered — no paired channel for ${filer:-the filer} or anyone above it"
}

# DIVE-1305: verify a chat_id is the paired human's OWN verified DM — i.e. it is
# listed in the bot's access.json `allowFrom` (the users who /started the bot and
# were approved). This is the trust anchor for the "go with recs from your own
# channel" clear: the plugin only ever passes a chat_id it already matched against
# access.json, and we RE-verify here so the CLI never trusts the flag blindly.
# DMs only (allowFrom) — groups (.groups, negative ids) are multi-member and a
# weaker identity, so a group message is NOT accepted as one human's proof. The
# caller's own bot channel is resolved via _task_owner_channel (SUDO_UID -> agent
# -> that agent's access.json), so an agent can only ever assert ITS OWN paired
# human, never another bot's. Returns 0 when the chat verifies. Scope guard: this
# proof clears only tier<2 gates (enforced at the call site, cmd_task_answer).
_gate_channel_proof_ok() {
  local chat="$1"
  [[ -n "$chat" ]] || return 1
  # Numeric chat id only (a DM id is a positive integer) — rejects junk / any
  # attempt to smuggle a jq filter or a negative group id through the flag.
  [[ "$chat" =~ ^[0-9]+$ ]] || return 1
  _task_owner_channel || return 1
  [[ -n "$TASK_CH_ACCESS" && -r "$TASK_CH_ACCESS" ]] || return 1
  jq -e --arg c "$chat" '(.allowFrom // []) | index($c) != null' "$TASK_CH_ACCESS" >/dev/null 2>&1
}

# DIVE-1490: append a queryable delivery event for a gate alert. The purpose-
# built notify log is group-writable for agent-filed gates (DIVE-1345), while
# audit_log provides the tamper-evident event stream. Failures are ALSO loud on
# stderr; an unanswered gate must never look delivered merely because curl ran.
_task_gate_delivery_log() { # <ok|error> <task_ids> <chat> <message_id> <detail> [next_step]
  local result="$1" task_ids="$2" chat="$3" message_id="$4" detail="$5"
  # DIVE-2011: the failure warn's tail used to state "trying a visible group
  # fallback" unconditionally, which is true only of the Bot API path. On the
  # lead-route rail there is no group fallback, so the caller says what actually
  # happens next. A wrong sentence in a shipped warn outlives the analysis that
  # produced it (see the "28 rows on 2 tasks" correction below) — so it is a
  # parameter, not a comment.
  local next_step="${6:-trying a visible group fallback}"
  # DIVE-1968 criterion 3: count the ATTEMPT, not the write. The delivery
  # assertion in task_need_notify needs to know whether this gate reached a
  # terminal verdict at all, and it must reach the same answer on a fenced
  # fixture store as on prod — otherwise every unit harness would trip it.
  TASK_GATE_DELIVERY_ROWS=$(( ${TASK_GATE_DELIVERY_ROWS:-0} + 1 ))
  local idents="$task_ids"
  if [[ "$task_ids" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    idents=$(db "SELECT group_concat(ident, ',') FROM tasks WHERE id IN (${task_ids});" 2>/dev/null) || idents="$task_ids"
  fi
  [[ -n "$idents" ]] || idents="unknown"
  detail=${detail//$'\n'/ }
  # DIVE-2073: NAME THE ACTOR AND THE CHANNEL ON EVERY PATH. The audit row's
  # `user` answers only "which uid ran the process", and on both privileged
  # paths that is root — which names nobody. A row reading "confirmed Bot API
  # send" while its actor is unnameable proves that SOMETHING sent it, not who,
  # and on the privileged re-send the whole question the path exists to answer
  # is "did the escalation reach a human through a DIFFERENT channel than the
  # filer's". Two facts have to live on the row itself:
  #   via=   whose bot/channel carried it (TASK_CH_AGENT — every resolver sets it)
  #   path=  which rail the send is on
  # Measured cost of not having them (2026-07-26, DIVE-1927 residual 2): a
  # delivery to lodar at 10:25:02 carried message_id 691 while the same day's
  # other rows sat at 26235-26309 — two id spaces, because each bot keeps its
  # own conversation with the same human, so ids from different bots are not
  # comparable. The row was circumstantially olivia's and could not be PROVEN
  # so, and a residual stayed open on evidence we should have been writing.
  # `via=none` is honest and DISTINCT from a resolved owner: an error row that
  # never resolved a channel has no owner. It must never borrow a stale one from
  # an earlier send in the same process, which is why _task_agent_channel clears
  # TASK_CH_AGENT on entry rather than only setting it on success.
  local _via="${TASK_CH_AGENT:-none}" _path="file-time"
  if [[ "${TASK_GATE_ESCALATING:-}" == "1" ]]; then _path="privileged-resend"
  elif [[ "${TASK_GATE_RENAG:-}" == "1" ]]; then _path="renag"
  fi
  local line
  line=$(printf 'gate-delivery result=%s tasks=%s chat=%s message_id=%s via=%s path=%s detail=%q' \
    "$result" "$idents" "${chat:-none}" "${message_id:-none}" "$_via" "$_path" "${detail:-none}")
  # DIVE-1968: FENCE THE TELEMETRY ON STORE IDENTITY. This log and the audit rows
  # are the ONLY dataset anyone reads to judge whether the gate rail works, and
  # until now every run wrote into them from a HARDCODED prod path regardless of
  # which task store it was driving. A unit harness points TASKS_DB at a throwaway
  # store whose `agents_org` is EMPTY — and an empty org table gives an EMPTY
  # escalation chain for every filer, so each fixture gate emitted a real-looking
  # "no paired channel for filer X or anyone above it" row into production
  # telemetry. Measured on this box: of 36 distinct idents in the error rows, 17
  # existed ONLY in fixture stores; the true post-DIVE-1927 production population
  # is far smaller than the 194 rows on 13 tasks the ticket was filed on.
  #
  # CORRECTION to this comment's first cut (and to PR #170's body), because the
  # number it quoted was derived the wrong way and is now cited knowledge: it said
  # "28 rows on 2 tasks", from an IDENT-EXISTS-IN-PROD-STORE filter. That filter is
  # insufficient — fixtures REUSE real idents. The sound discriminator is the
  # PENDING-GATE WINDOW: a row is a real delivery attempt only if
  # need_asked_at <= ts < need_answered_at, because the notify path will not
  # re-fire an answered gate and cmd_task_gate_escalate refuses anything not
  # pending. The fence is right; only PR #170's numbers and taxonomy were wrong.
  #
  # POSITIVE RESULT (DIVE-1988, re-derived on the full 1330-row union across all
  # seven days, method cited beside every number because this dataset has now
  # misled us four separate ways — see the wiki page linked below): the window
  # filter gives 112 in-window rows on 85 tasks — 11 error, 101 ok. The 11 are one
  # per task at filing time, and 9 of the 11 also carry a later `ok`. absent-from-org
  # is ZERO instances, not "the largest real shape, 13 of 28" as PR #170 had it. The
  # real shape is ORG-UNREADABLE: 10 of the 11 read "filing agent and org lead have
  # no paired channel", 1 reads "no allowlisted DM or deliverable group topic", and
  # every agent's access.json is 0600 — root can read it, a peer cannot.
  #
  # That shape has TWO causes and they take DIFFERENT fixes — do not collapse them:
  #   (a) the filer itself has NO channel of its own at all (quinn, dev2, dev3 — 1
  #       genuinely top-of-org, 2 with no access.json regardless): fix is SEED A
  #       CHANNEL.
  #   (b) the filer's OWN channel exists but its chain holds one nobody in that
  #       context may read — main -> olivia, whose access.json is 600 under a 750
  #       dir a peer can't even traverse, though root reads it fine: fix is PASS
  #       THE FILER NAME into a root-privileged probe so it resolves the chain
  #       with root's reach instead of the caller's.
  # Only 1 of the 11 (quinn) is genuine top-of-org-with-no-channel; main alone is
  # 8 of the 11, so the mass of the population is (b). Full derivation:
  # community/wiki/gate-delivery-telemetry-decontamination-dive1968.md (DIVE-1988).
  #
  # That contamination is worse than noise, and in BOTH directions: it inflated the
  # apparent blast radius AND it hid the real residual inside it. It also
  # manufactured the control that made the diagnosis look decisive — "13 tasks hold
  # 194 errors and not ONE ever recorded an ok, while the ok rows belong to 6
  # disjoint tasks" reads as proof of a broken rail, but a fixture ident can never
  # record an ok because it was never a real gate. Zero overlap was evidence of two
  # POPULATIONS IN ONE FILE, not of a failure.
  #
  # Fenced on STORE IDENTITY (_task_human_send_allowed, the DIVE-1506 positive
  # allowlist) rather than on an opt-out env var every harness must remember: the
  # failure mode of a forgotten override is SILENT contamination of prod telemetry,
  # which is precisely what we are standing in. An explicit FIVEDIVE_GATE_NOTIFY_LOG
  # is still honoured — a harness redirecting to its OWN file is the safe case and
  # the one we want to encourage — but it can never redirect INTO the prod default.
  # Withholding is announced once per process, because a fence that silently drops
  # rows is the same defect class one layer over.
  # PRIMARY is store identity and it needs NO env at all, so a harness that sets
  # nothing is fenced BY CONSTRUCTION — including harnesses nobody has written yet,
  # which no opt-in can manage. SECONDARY honours DIVE-1500's existing
  # FIVEDIVE_NOTIFY_DRYRUN quarantine so we reuse that vocabulary instead of
  # minting a rival one. The order matters: an opt-in fence is a fence you have to
  # REMEMBER, and "four harnesses set it, the rest do not" is the exact defect being
  # removed here. Do not fix an opt-out failure with a different opt-in.
  local logf="${FIVEDIVE_GATE_NOTIFY_LOG:-}" _prod_telemetry=0
  if _task_human_send_allowed \
     && [[ -z "${FIVEDIVE_NOTIFY_DRYRUN:-}" || "${FIVEDIVE_NOTIFY_DRYRUN}" == "0" ]]; then
    _prod_telemetry=1
  fi
  [[ -n "$logf" ]] || { (( _prod_telemetry )) && logf=/var/log/5dive/notify/gate-notify.log; }
  if [[ -n "$logf" ]] && ( umask 0002; : >>"$logf" ) 2>/dev/null; then
    chmod g+w "$logf" 2>/dev/null || true
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')" "$line" >>"$logf" 2>/dev/null || true
  fi
  if (( _prod_telemetry )); then
    audit_log "gate delivery" "$result" "$([[ "$result" == "ok" ]] && echo 0 || echo 1)" -- \
      "tasks=$idents" "chat=${chat:-none}" "message_id=${message_id:-none}" \
      "via=$_via" "path=$_path" "detail=${detail:-none}" || true
  elif [[ -z "${_TASK_GATE_TELEMETRY_FENCED:-}" ]]; then
    _TASK_GATE_TELEMETRY_FENCED=1
    warn "gate-delivery telemetry withheld: TASKS_DB is not the production store, so these rows are NOT written to the fleet log or audit (DIVE-1968). Set FIVEDIVE_GATE_NOTIFY_LOG to capture them locally."
  fi
  [[ "$result" == "ok" ]] || warn "$idents: gate alert delivery FAILED for chat ${chat:-none} (${detail:-unknown}); ${next_step}"
}

# DIVE-1506 — fail-closed guard: a gate alert (task_need_notify) or an /inbox digest
# (_task_inbox_send) may reach the PAIRED HUMAN only from the canonical PROD task DB. This is a
# POSITIVE ALLOWLIST, not a fixture blocklist — a rotted blocklist is exactly how DIVE-1500's guard
# missed the gate-notify + /inbox legs and let an isolated e2e's `task need` DM real fixture gates
# (dive1-4) to lodar. Every human-facing send now refuses unless the active TASKS_DB resolves to the
# prod path (operator-overridable via FIVEDIVE_PROD_TASKS_DB); an explicit test/e2e opt-out also
# refuses (belt-and-suspenders for a harness that forgets to repoint TASKS_DB). Returns 0=allow,1=refuse.
_task_prod_tasks_db() { printf '%s' "${FIVEDIVE_PROD_TASKS_DB:-/var/lib/5dive/tasks/tasks.db}"; }
_task_human_send_allowed() {
  # Explicit test/e2e markers force refuse regardless of path (covers COUNCIL_MOCK e2es etc.).
  [[ -n "${FIVEDIVE_NO_HUMAN_SEND:-}" || -n "${COUNCIL_MOCK:-}" || -n "${FIVEDIVE_E2E:-}" || -n "${FIVEDIVE_TEST:-}" ]] && return 1
  local active prod ra rp
  active="${TASKS_DB:-${STATE_DIR:-/var/lib/5dive}/tasks/tasks.db}"
  prod="$(_task_prod_tasks_db)"
  ra="$(readlink -f "$active" 2>/dev/null || printf '%s' "$active")"
  rp="$(readlink -f "$prod" 2>/dev/null || printf '%s' "$prod")"
  [[ -n "$ra" && "$ra" == "$rp" ]]
}

# DIVE-2010: fence a task-store-driven audit_log call on STORE IDENTITY, reusing
# the exact primitive _task_gate_delivery_log (DIVE-1968) already trusts for the
# same risk shape — a row built from live TASKS_DB state (a task ident, a filer,
# a gate type) written by a fixture store is a real-looking row with a fixture
# ident landing in the real fleet audit log. Measured on this box: a 41-suite
# run wrote 6 such rows via "task need unnotified" alone (fixture idents
# DIVE-1..4, filer=dev); re-sweeping tests/task_*unit.sh + tests/gate_*unit.sh
# after fixing that site found 2 MORE live call sites doing the same thing
# ("task set-body", "task.merge-gate-unverified") before they were routed
# through this wrapper too. Other unconditional task-store call sites remain
# (tracked in DIVE-2045) — untested is not the same claim as leak-free.
# Withholding is announced ONCE per process — a silent fence is the same
# fail-open shape as no fence (DIVE-1968 assertion 2).
_TASK_STORE_AUDIT_FENCED=""
_task_store_audit_log() { # <cmd> <result> <code> -- <args...>
  if _task_human_send_allowed; then
    audit_log "$@"
  elif [[ -z "${_TASK_STORE_AUDIT_FENCED:-}" ]]; then
    _TASK_STORE_AUDIT_FENCED=1
    warn "task audit telemetry withheld: TASKS_DB is not the production store, so this row is NOT written to the fleet audit log (DIVE-2010)."
  fi
  return 0
}

TASK_SEND_DELIVERED=0
TASK_SEND_MESSAGE_IDS=""
TASK_SEND_FAILED=0

_task_post_owner_target() { # <token> <chat> <thread> <text> <access> <markup> <task_ids>
  local token="$1" chat="$2" thread="$3" text="$4" access_file="$5" reply_markup="$6" task_ids="$7"
  _mirror_post "$token" "$chat" "$thread" "$text" "$access_file" "$reply_markup"
  if [[ "${MIRROR_POST_DELIVERED:-0}" == "1" ]]; then
    TASK_SEND_DELIVERED=1
    [[ -n "${MIRROR_POST_MESSAGE_ID:-}" ]] \
      && TASK_SEND_MESSAGE_IDS+="${TASK_SEND_MESSAGE_IDS:+,}${MIRROR_POST_MESSAGE_ID}"
    if [[ -n "$task_ids" ]]; then
      _task_gate_delivery_log ok "$task_ids" "${MIRROR_POST_CHAT:-$chat}" "${MIRROR_POST_MESSAGE_ID:-}" "confirmed Bot API send"
    fi
  else
    TASK_SEND_FAILED=1
    if [[ -n "$task_ids" ]]; then
      _task_gate_delivery_log error "$task_ids" "${MIRROR_POST_CHAT:-$chat}" "" "${MIRROR_POST_ERROR:-unconfirmed Bot API send}"
    fi
  fi
}

_task_send_owner_groups() { # <token> <access> <text> <markup> <task_ids> [exclude_chat]
  local token="$1" access_file="$2" text="$3" reply_markup="$4" task_ids="$5" exclude_chat="${6:-}"
  local groups n i g_chat g_thread
  groups=$(jq -c '(.groups // {}) | to_entries' "$access_file" 2>/dev/null) || groups="[]"
  n=$(jq 'length' <<<"$groups" 2>/dev/null) || n=0
  n=${n:-0}
  for (( i=0; i<n; i++ )); do
    g_chat=$(jq -r ".[$i].key" <<<"$groups" 2>/dev/null) || continue
    g_thread=$(jq -r ".[$i].value.message_thread_id // \"\"" <<<"$groups" 2>/dev/null) || g_thread=""
    [[ -n "$g_chat" && "$g_chat" != "$exclude_chat" ]] || continue
    _task_post_owner_target "$token" "$g_chat" "$g_thread" "$text" "$access_file" "$reply_markup" "$task_ids"
  done
}

_task_stamp_confirmed_delivery() { # <comma-separated numeric task ids>
  local task_ids="$1"
  [[ "${TASK_SEND_DELIVERED:-0}" == "1" && "$task_ids" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 0
  db "UPDATE tasks SET gate_pinged_at=datetime('now')
      WHERE id IN (${task_ids}) AND need_type IS NOT NULL AND need_answered_at IS NULL;" 2>/dev/null || true
}

# _task_send_owner — send ONE message ($1, optional reply_markup $2, optional
# comma-separated task row ids $3) to the
# paired human, using the channel resolved by _task_owner_channel. Routing
# (DIVE-259, Mark): follow the conversation — if the telegram plugin recorded
# where the human last talked to this agent (last-human-chat.json beside
# access.json), the alert and its tap buttons go THERE, but only when that
# chat is still allowlisted in access.json (a stale or hand-edited pointer
# must never widen the audience). No pointer (plugin predates the feature) =
# legacy flow: human DMs first (allowFrom — exactly the users who /started
# the bot), then the agent's bound forum topic(s) so nothing is silently
# lost. A Bot API {ok:true} is required before task ids are stamped delivered;
# failures are logged loudly and retry against an allowed group topic. Always
# returns 0 (best-effort); TASK_SEND_DELIVERED exposes the receipt to callers.
_task_send_owner() {
  local text="$1" reply_markup="${2:-}" task_ids="${3:-}"
  local token="$TASK_CH_TOKEN" access_file="$TASK_CH_ACCESS"
  TASK_SEND_DELIVERED=0 TASK_SEND_MESSAGE_IDS="" TASK_SEND_FAILED=0
  # DIVE-1506: fail-closed chokepoint. EVERY real human-facing task send (gate-notify + /inbox
  # digest) funnels here. Refuse unless the active task DB is the prod DB — an isolated e2e/fixture
  # DB (council_gate_e2e's `task need`, a replayed fixture digest) must never reach a paired human.
  # Leaves DELIVERED=0/FAILED=1 so callers' existing not-delivered fail-closed handling takes over.
  # Stub-based unit tests override _task_send_owner, so this never fires under a mocked send.
  if ! _task_human_send_allowed; then
    TASK_SEND_FAILED=1
    warn "DIVE-1506: refused a human task-send — active task DB (${TASKS_DB:-${STATE_DIR:-/var/lib/5dive}/tasks/tasks.db}) is not the prod DB (fail-closed; set FIVEDIVE_PROD_TASKS_DB if this IS prod)"
    return 0
  fi

  local ptr_file="${access_file%/*}/last-human-chat.json"
  if [[ -r "$ptr_file" ]]; then
    local p_chat p_thread
    p_chat=$(jq -r '.chatId // empty' "$ptr_file" 2>/dev/null) || p_chat=""
    p_thread=$(jq -r '.messageThreadId // empty' "$ptr_file" 2>/dev/null) || p_thread=""
    if [[ -n "$p_chat" ]]; then
      if jq -e --arg c "$p_chat" '(.allowFrom // []) | index($c) != null' "$access_file" >/dev/null 2>&1; then
        _task_post_owner_target "$token" "$p_chat" "" "$text" "$access_file" "$reply_markup" "$task_ids"
        [[ "$TASK_SEND_DELIVERED" == "1" ]] || _task_send_owner_groups "$token" "$access_file" "$text" "$reply_markup" "$task_ids"
        _task_stamp_confirmed_delivery "$task_ids"
        return 0
      fi
      if jq -e --arg c "$p_chat" '(.groups // {}) | has($c)' "$access_file" >/dev/null 2>&1; then
        _task_post_owner_target "$token" "$p_chat" "$p_thread" "$text" "$access_file" "$reply_markup" "$task_ids"
        [[ "$TASK_SEND_DELIVERED" == "1" ]] || _task_send_owner_groups "$token" "$access_file" "$text" "$reply_markup" "$task_ids" "$p_chat"
        _task_stamp_confirmed_delivery "$task_ids"
        return 0
      fi
      # Pointer references a chat that is no longer allowed — ignore it.
    fi
  fi

  local dms attempted=0 chat
  dms=$(jq -r '(.allowFrom // [])[]' "$access_file" 2>/dev/null) || dms=""
  if [[ -n "$dms" ]]; then
    while IFS= read -r chat; do
      [[ -n "$chat" ]] || continue
      _task_post_owner_target "$token" "$chat" "" "$text" "$access_file" "$reply_markup" "$task_ids"
      attempted=1
    done <<<"$dms"
  fi
  # No DM target, or at least one DM rejected: post once per configured group so
  # the alert lands somewhere visible. A partial DM failure still falls back —
  # every allowlisted owner should have a recovery surface.
  if (( ! attempted )) || [[ "$TASK_SEND_FAILED" == "1" ]]; then
    _task_send_owner_groups "$token" "$access_file" "$text" "$reply_markup" "$task_ids"
  fi
  if (( ! attempted )) && [[ "$TASK_SEND_DELIVERED" != "1" && -n "$task_ids" ]]; then
    TASK_SEND_FAILED=1
    _task_gate_delivery_log error "$task_ids" "" "" "no allowlisted DM or deliverable group topic"
  fi
  _task_stamp_confirmed_delivery "$task_ids"
  return 0
}

# _task_close_notify — DM the paired human a one-line ✅/⚠️ summary when a task
# is closed with --notify (used by the heartbeat nudge so autonomous queue work
# surfaces a finish line without full progress streaming). Best-effort: every
# miss returns 0 so it can't fail the status write the caller just committed.
_task_close_notify() {
  local ident="$1" verb="$2" result="$3"
  _task_owner_channel || return 0
  local text
  if [[ "$verb" == "cancel" ]]; then
    text="⚠️ [${ident}] cancelled"
  else
    text="✅ [${ident}] done"
  fi
  # Ping shows only the result's FIRST line — done-results lead with a one-line
  # summary; a full paragraph is too noisy on the owner's phone. The complete
  # result stays on the record (`task show` renders all of it).
  [[ -n "$result" ]] && text+=": ${result%%$'\n'*}"
  _task_send_owner "$text" ""
  return 0
}

# task_need_notify — DIVE-105: the instant a human gate is filed, DM the paired
# human ONE alert so it doesn't sit unseen until someone opens the dashboard.
# Best-effort + self-gating in the shape of mirror_interagent_outbound, and
# reusing its _mirror_post send path (migration self-heal included). EVERY exit
# path returns 0: a missing token / access.json / dead Telegram call must NEVER
# block or fail the gate write (the DB UPDATE already committed before we run).
# The caller also invokes us as `... || true`, so set -e can't trip on anything
# inside either.
#
# Works whether `task need` is run directly as agent-<name> (the common path —
# task verbs need no sudo) OR via sudo: the agent is resolved the same way
# task_actor does; the token comes from the group-claude-readable connector
# file (or an inherited env var); and access.json is found by probing the
# per-type channel dirs (own file when direct, root-readable when sudo).
# _task_mint_drop_link — DIVE-931. Mint a one-time secure credential drop link
# for a secret gate (api POST /drop/mint, box-authed with the box's connectord
# token). Echoes exactly one of:
#   <url>|<ttlMinutes>   a live burnable link (api pushes the value to the box)
#   ONBOX                 api holds no usable token for this box -> on-box path
#   (empty)               mint unavailable (self-hosted / api down) -> legacy text
# Best-effort: never fails the caller and never touches the secret VALUE (only the
# destination coordinates). The value crosses solely via the drop page -> stdin.
_task_mint_drop_link() {
  local ident="$1" secret_key="$2" connector="$3"
  local token="" env_file="/etc/5dive/connectord.env"
  [[ -n "${CONNECTORD_TOKEN:-}" ]] && token="$CONNECTORD_TOKEN"
  [[ -z "$token" && -r "$env_file" ]] && token=$(sed -n 's/^CONNECTORD_TOKEN=//p' "$env_file" | head -1)
  [[ -n "$token" ]] || return 0   # no box identity (self-hosted OSS) -> legacy text
  local api="${FIVE_API_BASE:-https://api.5dive.com}" body resp
  body=$(jq -nc --arg t "$ident" --arg k "$secret_key" --arg c "$connector" \
           '{taskIdent:$t, secretKey:$k, connector:$c, ttlMinutes:30}') || return 0
  resp=$(curl -fsS --max-time 10 -X POST "${api%/}/drop/mint" \
           -H "authorization: Bearer ${token}" -H "content-type: application/json" \
           -d "$body" 2>/dev/null) || return 0
  if [[ "$(printf '%s' "$resp" | jq -r '.useOnBoxPath // false' 2>/dev/null)" == "true" ]]; then
    echo "ONBOX"; return 0
  fi
  local url ttl
  url=$(printf '%s' "$resp" | jq -r '.url // empty' 2>/dev/null)
  ttl=$(printf '%s' "$resp" | jq -r '.ttlMinutes // empty' 2>/dev/null)
  [[ -n "$url" ]] || return 0
  echo "${url}|${ttl:-15}"
}

# Render the canonical tap keyboard for one gate. Kept separate from the alert
# prose so heartbeat re-nags can combine N gates into one message without
# drifting from the callback contract used by the initial task-need alert.
_task_gate_reply_markup() { # <row_id> <type> <options> <recommend> <nonce> <channel_type> [label]
  local numid="$1" need_type="$2" options="$3" recommend="$4" human_nonce="$5" channel_type="$6" label="${7:-}"
  [[ -n "$label" ]] && label="[${label}] "
  local np=""; [[ -n "$human_nonce" ]] && np=":${human_nonce}"
  local reply_markup=""
  if [[ "$channel_type" =~ ^(claude|codex|grok|antigravity)$ ]]; then
    if [[ "$need_type" == "decision" && -n "$options" ]]; then
      reply_markup=$(printf '%s' "$options" | jq -Rc --arg id "$numid" --arg r "$recommend" --arg p "$label" '
        ($r | gsub("^\\s+|\\s+$"; "")) as $rr
        | [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ] as $o
        | ($o | to_entries
           | sort_by(.value == $rr and ($rr|length)>0 | not)
           | reduce .[] as $e ({rows: [], cur: [], w: 0};
               (($e.value | length) + (if $e.value == $rr and ($rr|length)>0 then 2 else 0 end)) as $len
               | {text: ($p + (if $e.value == $rr and ($rr|length)>0 then "⭐ " + $e.value else $e.value end)), callback_data: ("tna:" + $id + ":" + ($e.key | tostring))} as $btn
               | if (.cur | length) > 0 and ((.cur | length) >= 3 or (.w + $len + 2) > 24)
                 then {rows: (.rows + [.cur]), cur: [$btn], w: $len}
                 else {rows: .rows, cur: (.cur + [$btn]), w: (.w + $len + 2)}
                 end)
           | .rows + (if (.cur | length) > 0 then [.cur] else [] end)) as $kb
        | if ($kb | length) > 0 then {inline_keyboard: $kb} else empty end' 2>/dev/null) || reply_markup=""
    elif [[ "$need_type" == "approval" ]]; then
      local rl; rl=$(printf '%s' "$recommend" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
      local appr='{"text":"'"${label}"'✅ Approve","callback_data":"tna:'"${numid}"':approved'"${np}"'"}'
      local deny='{"text":"'"${label}"'🚫 Deny","callback_data":"tna:'"${numid}"':denied'"${np}"'"}'
      case "$rl" in
        approve|approved) appr='{"text":"'"${label}"'⭐ ✅ Approve","callback_data":"tna:'"${numid}"':approved'"${np}"'"}'
                          reply_markup='{"inline_keyboard":[['"$appr"','"$deny"']]}' ;;
        deny|denied)      deny='{"text":"'"${label}"'⭐ 🚫 Deny","callback_data":"tna:'"${numid}"':denied'"${np}"'"}'
                          reply_markup='{"inline_keyboard":[['"$deny"','"$appr"']]}' ;;
        *)                reply_markup='{"inline_keyboard":[['"$appr"','"$deny"']]}' ;;
      esac
    elif [[ "$need_type" == "secret" ]]; then
      reply_markup='{"inline_keyboard":[[{"text":"'"${label}"'✅ Provided","callback_data":"tna:'"${numid}"':provided'"${np}"'"}]]}'
    elif [[ "$need_type" == "manual" ]]; then
      reply_markup='{"inline_keyboard":[[{"text":"'"${label}"'✅ Done","callback_data":"tna:'"${numid}"':done'"${np}"'"}]]}'
    fi
  fi
  printf '%s' "$reply_markup"
}

# DIVE-1968 criterion 3 — THE DELIVERY ASSERTION.
#
# Every branch below records a verdict: an `ok` row, an `error` row, or a
# privileged re-send whose child records one. The bug is what happens when NONE of
# them runs. Measured on this box while reading the residual: of 9 real post-fix
# gates, 5 recorded NEITHER an ok nor an error row — they were filed, they returned
# 0, and they left no trace in the only dataset anyone consults to judge whether
# the gate rail works. That is strictly worse than a logged failure. A logged
# failure is a bug report; silence is indistinguishable from success, and it is
# what let this whole class survive a live end-to-end verification of DIVE-1927.
#
# So the delivery verdict is now MANDATORY rather than emergent. If the inner path
# returns without any delivery row, we synthesise the missing verdict (error, with
# a detail that names the hole rather than guessing a cause), warn loudly at the
# filer, and downgrade a bare `return 0` to rc 3 — FILED, NOT NOTIFIED. rc 3 is an
# existing, handled contract: the gate row stands and is answerable on the
# dashboard, gate_pinged_at stays NULL, and the re-nag sweep escalates it. That
# matters more than the log line: an unrecorded delivery used to also claim the
# ping, which suppressed the one mechanism that would have rescued it.
#
# Deliberately a wrapper around the unchanged body: the invariant is "no exit from
# this function without a verdict", and a wrapper enforces it for the four exits
# that exist today AND for whichever ones get added later — which is the actual
# failure mode, since none of today's exits was written intending to be silent.
# The verdict FOLLOWS THE DELIVERY STATE — it is not assumed from the silence. Two
# different holes hide behind "no row", and collapsing them would have traded a
# missing row for a WRONG one:
#   * delivered, unrecorded  -> the send was confirmed (TASK_SEND_DELIVERED=1) and
#     only the bookkeeping is missing. Backfill the `ok` row. This is the larger
#     half of the measured 5, and calling it a failure would have manufactured
#     error rows for gates that reached their human — re-contaminating the dataset
#     with the opposite bias, on the very ticket about a mis-measured one.
#   * neither delivered nor recorded -> nobody can show a human was reached.
#     Synthesise the error row and downgrade rc 0 to 3.
# Found by two pre-existing tests (gate_channelless_escalation, gate_filer_own_channel)
# going red against the first cut, which asserted on the row alone. They were right
# and the assertion was wrong: both drive a stubbed send that reports DELIVERED,
# which is exactly the delivered-but-unrecorded shape. Both pass UNCHANGED here —
# that they were not edited to accommodate this diff is the point.
#
# DIVE-2011: the assertion now fences the LEAD-ROUTE rail too, by dispatch rather
# than by a second copy. A routed gate never reached this wrapper at all — it sent
# its handoff inline and `return`ed before the notify path was called — so
# "no exit without a delivery verdict" was true of the human ping ONLY, on the
# rail that now carries most builder gates. Measured: DIVE-1989's approval gate was
# filed and lead-cleared inside the post-assertion window and gate-notify.log holds
# nothing for it. One wrapper, two deliverers: a parallel assertion would be a
# second thing to go inert, which is the failure mode of the thing being fixed.
task_need_notify() {
  TASK_GATE_DELIVERY_ROWS=0
  TASK_SEND_DELIVERED=0
  local _rc=0
  if [[ -n "${TASK_GATE_ROUTE_TO:-}" ]]; then
    _task_need_route_deliver "$@" || _rc=$?
  else
    _task_need_notify_deliver "$@" || _rc=$?
  fi
  if (( ${TASK_GATE_DELIVERY_ROWS:-0} == 0 )); then
    if [[ "${TASK_SEND_DELIVERED:-0}" == "1" ]]; then
      _task_gate_delivery_log ok "$1" "${TASK_CH_CHAT:-}" "${TASK_SEND_MESSAGE_IDS%%,*}" \
        "confirmed send, backfilled by the delivery assertion (the notify path recorded no row of its own)"
    else
      _task_gate_delivery_log error "$1" "" "" \
        "no delivery verdict recorded by the notify path (rc=${_rc}) and no confirmed send; delivery is UNVERIFIABLE, treating as unnotified"
      warn "$1: gate delivery is UNVERIFIABLE — the notify path exited (rc=${_rc}) with neither a confirmed send nor a recorded verdict, so nobody can show a human was reached. Treated as FILED UNNOTIFIED: the re-nag will escalate it. Answer on the dashboard or: 5dive task answer $1"
      (( _rc == 0 )) && _rc=3
    fi
  fi
  return $_rc
}

# DIVE-2011 — the LEAD-ROUTE rail's deliverer, the routed twin of
# _task_need_notify_deliver. Same wrapper, same telemetry, same rc contract.
#
# What it replaces, verbatim from the branch it was lifted out of:
#
#   ( 5dive agent send "$_reviewer" "$_hmsg" --from="$actor" >/dev/null 2>&1 & ) || true
#   ok "$ident routed to $_reviewer ..."
#
# Three defects in two lines, and the third is the one that hides the other two:
# the send is backgrounded, both streams go to /dev/null, and `|| true` sits
# outside the subshell — so its exit status is not merely ignored, it is
# STRUCTURALLY UNOBSERVABLE. "routed to X" printed whether or not X existed, was
# running, or had a live tmux pane to inject into.
#
# The fix has to survive one hard constraint: `5dive agent send` waits up to 45s
# for the receiver's input prompt (wait_agent_input_ready) and a BUSY-but-healthy
# peer burns that whole budget. So neither of the two obvious fixes works —
# a synchronous send stalls the filer for the better part of a minute on the
# COMMON case, and a `timeout`-truncated one kills the child DURING the readiness
# wait, i.e. before the inject, converting a delivered handoff into a lost one.
# Making the send observable must not make it worse.
#
# So: observe the FAST FAILURES synchronously and let the slow tail run detached.
# Every shape we actually care about — unknown agent (require_agent), dead tmux
# session (E_NOT_RUNNING), sudo denied (the DIVE-1337 scoped-a2a gap), CLI absent
# — is decided in well under a second, BEFORE the readiness wait. A short poll on
# the child's own rc therefore catches all of them at the filer, while a peer that
# is merely mid-turn is left to finish in the background.
#
# THE CHILD WRITES THE ROW, not the parent, and writes its rc file only AFTER the
# row lands — so "parent observed an rc" implies "the row is already on disk", and
# there is exactly one writer per gate with no double-count. The parent credits
# TASK_GATE_DELIVERY_ROWS for the same reason the privileged re-send does: the row
# exists, it was just written one process over, and re-logging here would
# re-inflate the very telemetry DIVE-1968 spent a round decontaminating.
#
# The in-flight case is reported as in-flight, NOT as delivered and NOT as failed.
# Calling it a failure would manufacture error rows for healthy busy peers — the
# opposite-direction bias, on the ticket about a mis-measured dataset — and calling
# it delivered is the lie being removed. TASK_GATE_ROUTE_STATE carries the three
# states out to the caller's ok line, so the printed claim never exceeds what was
# observed. rc stays on the existing 0/3 contract (3 = filed, NOT notified) rather
# than minting a new code the human path's callers would not recognise.
TASK_GATE_ROUTE_TO=""
TASK_GATE_ROUTE_ROLE=""
TASK_GATE_ROUTE_STATE=""
_task_need_route_deliver() {
  local ident="$1" need_type="$2" ask="$3" options="${4:-}" recommend="${5:-}"
  local reviewer="${TASK_GATE_ROUTE_TO:-}" filer="${TASK_GATE_FILER:-}"
  local role="${TASK_GATE_ROUTE_ROLE:-review}"
  TASK_GATE_ROUTE_STATE="failed"
  [[ -n "$reviewer" ]] || return 3
  # The ident, not the row id: _task_gate_delivery_log resolves numeric ids with a
  # DB read, and the detached child must not touch the store the parent is writing.
  local msg="🧭 [${ident}] routed to you for ${role} (${need_type} gate). ${ask}"
  [[ -n "$options" ]]   && msg+=" Options: ${options}."
  [[ -n "$recommend" ]] && msg+=" ${filer} recommends: ${recommend}."
  msg+=" Resolve: 5dive task answer ${ident} --value=\"<choice>\" — or re-file to escalate to the human."
  if ! command -v 5dive >/dev/null 2>&1; then
    TASK_NOTIFY_FAIL_REASON="the 5dive CLI is not on PATH here, so the handoff to ${reviewer} could never be sent"
    _task_gate_delivery_log error "$ident" "agent:${reviewer}" "" \
      "lead-route handoff to ${reviewer} not attempted: no 5dive CLI on PATH" \
      "the gate stands and the re-nag escalates it"
    return 3
  fi
  local _d; _d=$(mktemp -d "${TMPDIR:-/tmp}/5dive-gate-route.XXXXXX" 2>/dev/null) || _d=""
  if [[ -z "$_d" ]]; then
    # No scratch dir means no rc channel, so the send would be unobservable again.
    # Send it anyway (delivery beats measurement) but record the blind spot as what
    # it is rather than claiming a verdict we cannot have.
    ( 5dive agent send "$reviewer" "$msg" --from="$filer" >/dev/null 2>&1 & ) || true
    TASK_GATE_ROUTE_STATE="inflight"
    _task_gate_delivery_log error "$ident" "agent:${reviewer}" "" \
      "lead-route handoff to ${reviewer} dispatched UNOBSERVED: no writable scratch dir for the send's exit status" \
      "the gate stands and the re-nag escalates it"
    return 0
  fi
  # Detached so it outlives this command, but no longer mute: the child logs the
  # terminal verdict itself, then publishes its rc, then cleans up its own dir (so
  # cleanup has a single owner and cannot race the parent's poll).
  ( {
      local _crc=0 _cout=""
      _cout=$(5dive agent send "$reviewer" "$msg" --from="$filer" 2>&1) || _crc=$?
      if (( _crc == 0 )); then
        _task_gate_delivery_log ok "$ident" "agent:${reviewer}" "" \
          "lead-route handoff delivered to ${reviewer} (${role}) via 5dive agent send"
      else
        _task_gate_delivery_log error "$ident" "agent:${reviewer}" "" \
          "5dive agent send to ${reviewer} failed rc=${_crc}: ${_cout//$'\n'/ }" \
          "the gate stands and the re-nag escalates it"
      fi >/dev/null 2>&1
      printf '%s' "$_crc" >"${_d}/rc" 2>/dev/null || true
      sleep 5; rm -rf "$_d" 2>/dev/null || true
    } & ) || true
  # Bounded observation window. 3s is comfortably past every fast-failure shape
  # above and far short of the 45s readiness wait, so it separates "cannot deliver"
  # from "not delivered YET" without paying for the latter.
  local _w=0 _rc=""
  while (( _w < 30 )); do
    if [[ -s "${_d}/rc" ]]; then _rc=$(cat "${_d}/rc" 2>/dev/null) || _rc=""; break; fi
    sleep 0.1; _w=$((_w+1))
  done
  # The child owns the row in every branch below; credit it so the wrapper's
  # assertion does not synthesise a duplicate (see the privileged re-send).
  TASK_GATE_DELIVERY_ROWS=$(( ${TASK_GATE_DELIVERY_ROWS:-0} + 1 ))
  if [[ -z "$_rc" ]]; then
    TASK_GATE_ROUTE_STATE="inflight"
    return 0
  fi
  if [[ "$_rc" == "0" ]]; then
    TASK_SEND_DELIVERED=1
    TASK_GATE_ROUTE_STATE="delivered"
    return 0
  fi
  TASK_GATE_ROUTE_STATE="failed"
  TASK_NOTIFY_FAIL_REASON="the handoff send to ${reviewer} failed (rc=${_rc})"
  warn "${ident}: the lead-route handoff to ${reviewer} FAILED (5dive agent send rc=${_rc}) — the gate is filed and routed on the record but ${reviewer} was NOT pinged. The re-nag escalates it (<=15 min); answerable now with: 5dive task answer ${ident}"
  return 3
}

_task_need_notify_deliver() {
  local ident="$1" need_type="$2" ask="$3" options="$4" recommend="${5:-}"
  local secret_key="${6:-}" connector="${7:-}" human_nonce="${8:-}"
  local precedent_cite="${9:-}"  # OSS-11: prior-answer citation, empty if none
  # The delivery helper accepts numeric task row ids so it can stamp exactly the
  # alert(s) confirmed by Telegram. Resolve before channel routing so even a
  # total no-channel failure can be recorded against the gate.
  local numid; numid=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$ident");")
  # Resolve bot token + the human's DM/group targets (TASK_CH_* globals). The
  # matched access type (TASK_CH_TYPE) gates the tap-to-answer buttons below.
  # DIVE-1243: never DROP a gate alert silently. The filing agent being unpaired
  # (no access.json — the codex-gate-invisible bug: its gate was filed but no one
  # was ever pinged) used to `return 0` here and the gate sat unseen. Warn, then
  # fall back to the org lead's channel so the alert still surfaces; if even that
  # is missing, warn again — the gate still shows on the dashboard "Needs you"
  # card, but we never fail silently.
  # DIVE-1927: DIVE-1243's lead fallback existed but never fired in practice — it
  # probed the lead's channel by READABILITY (`-r access.json`), and a sibling
  # agent can never read a peer's 0600 access.json, so every escalation collapsed
  # to "no lead channel either" and `return 0` (a plain OK from `task need`). That
  # is the succeeding-in-appearance class aimed at the escalation rail itself:
  # dev3's DIVE-1926 manual gate was filed, reported OK, and reached NOBODY.
  # Three ordered attempts now, and NO silent success:
  #   1. nearest READABLE channel walking UP reports_to (multi-hop, not one).
  #   2. reachable-but-unreadable: re-run the send as root over sudo, which can
  #      read every access.json.
  #   3. nobody up the chain is paired at all -> return 2, and the caller UNDOES
  #      the gate and fails loudly. A gate nobody can answer is worse than a
  #      refused one: the refusal is visible, the silence is not.
  TASK_NOTIFY_ESCALATED_FROM=""; TASK_NOTIFY_FAIL_REASON=""
  # In a root sweep (heartbeat cron: no SUDO_UID, USER=root) the caller is not
  # the filer, so everything below must key off the gate row's own filer.
  local _self; _self="${TASK_GATE_FILER:-}"; [[ -n "$_self" ]] || _self=$(task_actor "")
  # DIVE-1968: try the FILER'S OWN channel BY NAME before anything else.
  # `_task_owner_channel` resolves the CALLER (auto_sender_from_sudo -> $SUDO_USER,
  # else $USER, and only when either is agent-*), never the gate's filer. So it is
  # a structural no-op in precisely the two contexts that matter — the root re-nag
  # sweep and the privileged re-send, where the name resolves EMPTY and
  # `_task_agent_channel ""` returns 1 immediately — and when a PEER agent drives
  # the send it resolves that peer's channel, i.e. alerts the wrong human. The
  # chain then walks strictly UP from the filer, so a top-of-org filer (olivia,
  # quinn: reports_to='') comes back empty and we report "no paired channel for
  # filer X or anyone above it" while X has a working channel sitting right there.
  # Root CAN read a peer's 0600 access.json, which is the whole reason the
  # privileged path exists — so by-name resolution is exactly what it was missing.
  # This is the answer to "why did _task_owner_channel not fire for olivia": it
  # never could. Prepending the filer is not papering over a second bug; the
  # second bug WAS that the own-channel probe is caller-scoped.
  if [[ -n "$_self" ]] && _task_agent_channel "$_self"; then
    : # the filer's own channel — the alert belongs to THEIR paired human
  elif ! _task_owner_channel; then
    warn "$ident: filing agent (${_self:-?}) has no paired channel — escalating up the org chart for the gate alert"
    local _fb=""
    _task_chain_channel "$_self" && _fb="$TASK_CH_AGENT"
    if [[ -n "$_fb" ]]; then
      TASK_NOTIFY_ESCALATED_FROM="$_self"
      warn "$ident: gate alert escalated to ${_fb} (nearest paired agent above the unpaired filer ${_self:-?})"
    else
      local _paired; _paired=$(_task_chain_paired "$_self") || _paired=""
      if [[ -n "$_paired" && $EUID -ne 0 && -z "${TASK_GATE_ESCALATING:-}" ]]; then
        if _task_gate_escalate_via_sudo "$ident" "$human_nonce"; then
          warn "$ident: gate alert delivered to ${_paired} via a privileged re-send (its channel is not readable as this agent)"
          # The row for this delivery was written by the CHILD process (it runs the
          # same notify path as root against the same prod store), so nothing is
          # missing from the log — but the counter lives in THIS shell, so credit it
          # here or the delivery assertion below would read a confirmed delivery as
          # an unrecorded one. Counted, not logged: logging here would double-count
          # one send as two rows and re-inflate exactly the telemetry this ticket
          # spent a whole round decontaminating.
          TASK_GATE_DELIVERY_ROWS=$(( ${TASK_GATE_DELIVERY_ROWS:-0} + 1 ))
          return 0
        fi
        warn "$ident: privileged re-send to ${_paired} FAILED${TASK_GATE_ESCALATE_ERR:+ — ${TASK_GATE_ESCALATE_ERR}}"
      fi
      # DIVE-1927 review round 2 (main, off RED CI on PR #160). The first cut
      # refused the gate here, and that equated "no paired TELEGRAM channel" with
      # "no human can answer" — which is false. The dashboard "Needs you" card and
      # `5dive task answer` are real answering surfaces that need no channel at
      # all. Refusing on this branch made a paired bot a hard dependency of the
      # entire gate rail: CI (nothing is ever paired) went red, and with it any
      # solo OSS user who never wired Telegram, any fresh install, any headless
      # box — including `5dive goal`, which could no longer file its plan gate.
      # So the hard refusal is now scoped to the one case where the gate really
      # can reach nobody, and everything else is filed DELIVERABLE-BUT-UNNOTIFIED
      # (rc 3): the row stands, it is answerable, gate_pinged_at stays NULL, and
      # the 15-minute re-nag escalates it. Losing a gate is worse than delaying it.
      if [[ -n "$_paired" ]]; then
        # Someone up the chain IS reachable; we merely could not reach them from
        # HERE. The root re-nag walks the same chain with strictly more privilege
        # and will deliver. Refusing would turn a delayed gate into a lost one —
        # literally the DIVE-1926 case, which the 07:10 re-nag rescued.
        TASK_NOTIFY_FAIL_REASON="the privileged re-send to ${_paired} failed, so delivery is unconfirmed"
        warn "$ident: could not hand this gate to ${_paired} from here — FILED UNNOTIFIED; the heartbeat re-nag escalates it (<=15 min). Answerable now on the dashboard or: 5dive task answer ${ident}"
        _task_gate_delivery_log error "$numid" "" "" "privileged re-send to ${_paired} failed${TASK_GATE_ESCALATE_ERR:+ (${TASK_GATE_ESCALATE_ERR})}; gate filed unnotified, re-nag will escalate"
        return 3
      fi
      # Nobody up the chain is paired. This is still NOT grounds to refuse: the
      # dashboard "Needs you" card, `task inbox` and `task answer` are answering
      # surfaces that need no channel, and tests/gate_parity_smoke.sh asserts
      # exactly that contract ("gate filed CLI-only with no Telegram present").
      # An earlier cut refused here and then tried to scope the refusal to
      # deployments that have channels configured — which still broke the parity
      # smoke, because whether some OTHER agent on the box is paired says nothing
      # about whether THIS gate can be answered. Every attempt to define
      # "nowhere to land" kept mis-firing in an environment I did not control,
      # which is the signal that the condition does not exist. So: always file,
      # and make the non-notification loud, recorded and persistent instead.
      # Only the WORDING forks, because an unnotified gate is routine on a box
      # with no channels and an anomaly on one that notifies.
      if _task_deployment_has_channels; then
        local _shape; _shape=$(_task_filer_chain_shape "${_self:-}")
        TASK_NOTIFY_FAIL_REASON="${_self:-the filer} has no paired channel and neither does anyone above it in the org chart (${_shape})"
        warn "$ident: NO paired channel for ${_self:-?} or anyone above it in the org chart [${_shape}] — gate FILED UNNOTIFIED on a deployment that notifies. Nobody was pinged; answer on the dashboard or: 5dive task answer ${ident}"
        _task_gate_delivery_log error "$numid" "" "" "no paired channel for filer ${_self:-?} or anyone above it; shape=${_shape}; gate filed unnotified on a channel-having deployment"
      else
        TASK_NOTIFY_FAIL_REASON=""
        warn "$ident: no channels configured on this deployment — gate filed UNNOTIFIED. Answer it on the dashboard, or: 5dive task answer ${ident}"
        _task_gate_delivery_log error "$numid" "" "" "no channel configured on this deployment; gate filed unnotified (dashboard-answerable)"
      fi
      return 3
    fi
  fi

  # The /task_<n> deep link and tna:<n>:… callback both carry a BARE NUMBER that
  # the plugin re-resolves via `5dive task show/answer <n>` — and a bare number
  # resolves by the GLOBAL ROW ID, not the per-project issue number. Derive it
  # from the row id, never from the ident: `${ident#DIVE-}` yields the issue
  # number, which diverges from the row id once a non-default project consumes
  # global ids (DIVE-484/DIVE-561), and for a non-DIVE prefix wouldn't strip at
  # all — either way the tap would resolve the WRONG row (DIVE-561).
  # One message. Blank lines separate the header / ask / options so a long ask
  # doesn't render as an unreadable wall on mobile. No footer: tap buttons cover
  # decision/approval, and button-less gates (secret/manual) still surface on
  # the dashboard "Needs you" card — a redirect line is just noise in chat.
  # Options are listed one per line (numbered to match the tap buttons) so long
  # labels stay readable even when Telegram crops the button text.
  # DIVE-148: lead with the agent's recommendation (✅ Recommended: <X>) before
  # the ask, so the human sees the advised choice first instead of hunting for
  # it. Applies to decision + approval gates; NULL/empty recommend = no line.
  local text="🙋 [${ident}] needs you"
  # DIVE-1927: when the ask was escalated off an unpaired filer, NAME the filer.
  # The recipient's bot is not the asker's bot, so without this the alert reads as
  # the manager's own gate and there is no way to tell whose ask it is.
  [[ -n "${TASK_NOTIFY_ESCALATED_FROM:-}" ]] \
    && text+=$'\n'"↑ filed by ${TASK_NOTIFY_ESCALATED_FROM} (no channel of its own) — escalated to you"
  [[ -n "$recommend" ]] && text+=$'\n\n'"✅ Recommended: ${recommend}"
  # OSS-11 (DIVE-976): cite the precedent that sourced the recommendation so the
  # human sees WHY this choice is advised and can catch a wrong recall.
  [[ -n "$precedent_cite" ]] && text+=$'\n'"↩︎ ${precedent_cite}"
  # DIVE-390: append a bare, tappable /task_<id> link inline at the end of the
  # description sentence, before the options (Mark 2026-06-15). Telegram
  # auto-linkifies bare /commands, so tapping it fires the plugin's
  # ^/task_(\d+)$ handler -> `5dive task show <id>` (the full detail card). No
  # "details" label, numeric id only. A plain-text host shows an inert link.
  text+=$'\n\n'"${ask} /task_${numid}"
  if [[ "$need_type" == "decision" && -n "$options" ]]; then
    local opts_list
    # ⭐-mark the recommended option in the numbered list (numbering stays the
    # original option order so it still maps to need_options on the dashboard).
    opts_list=$(printf '%s' "$options" | jq -Rr --arg r "$recommend" '
      ($r | gsub("^\\s+|\\s+$"; "")) as $rr
      | [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ]
      | to_entries | map("  \(.key + 1). \(.value)\(if .value == $rr and ($rr|length)>0 then " ⭐" else "" end)") | join("\n")' 2>/dev/null) || opts_list=""
    [[ -n "$opts_list" ]] && text+=$'\n\n'"Options:"$'\n'"${opts_list}"
  fi

  # DIVE-356: secret/manual gates used to carry NO instruction on how to clear
  # them — the core of Mark's "a needs-you that needs no obvious action is
  # confusing" complaint. Add a type-specific CTA telling the human exactly what
  # to do + tap (the matching ✅ button is emitted below for plugin types).
  # DIVE-894: every CTA also carries the on-box CLI line. Boxes with no
  # dashboard (CLI-only self-hosted — lodar hit this live on DIVE-790) had no
  # recovery path when a tap fails; the answer command works on EVERY box, run
  # as a human login (claude/root — the human path clears approval/secret gates).
  case "$need_type" in
    secret)
      # DIVE-931: when the gate names a drop target (secret_key + connector), mint
      # a burnable single-use link so the human drops the credential straight onto
      # the box — the VALUE never transits chat, only the link does. Falls back to
      # the on-box `secret write` (tokenless boxes) or the legacy out-of-band text
      # (self-hosted / api unreachable). The box-side write auto-clears this gate.
      local _drop=""
      if [[ -n "$secret_key" && -n "$connector" ]]; then
        _drop=$(_task_mint_drop_link "$ident" "$secret_key" "$connector")
      fi
      if [[ "$_drop" == "ONBOX" ]]; then
        text+=$'\n\n'"🔑 [${ident}] needs the ${secret_key} credential. On the box, drop it straight in (never paste it here):"$'\n'"  echo -n \"\$SECRET\" | sudo 5dive secret write ${secret_key} --connector=${connector} --task=${ident}"$'\n'"That writes it and clears this gate. Or tap ✅ Provided once it is done."
      elif [[ -n "$_drop" ]]; then
        local _url="${_drop%%|*}" _ttl="${_drop##*|}"
        text+=$'\n\n'"🔑 [${ident}] needs the ${secret_key} credential. Drop it securely (single-use, expires in ${_ttl}m):"$'\n'"${_url}"$'\n'"The value goes straight onto your box and is never shown in chat. Prefer the box? echo -n \"\$SECRET\" | sudo 5dive secret write ${secret_key} --connector=${connector} --task=${ident}"
      else
        text+=$'\n\n'"🔑 Put the key where I expect it (my .env / our channel), then tap ✅ Provided below. Don't paste the key here. Tap not working? On the box: sudo 5dive task answer ${ident}"
      fi
      ;;
    manual) text+=$'\n\n'"✋ Tap ✅ Done below once it is handled, which closes this out. Or on the box: sudo 5dive task answer ${ident} --value=done" ;;
    # DIVE-1243: an `access` gate normally clears via the org lead; it only reaches
    # a human when it's genuinely human-territory (money/secrets/destructive) or no
    # lead was available. No tap button (the plugin `tna:` handler has no access
    # resolution — see the DIVE-118 no-dead-taps allowlist below); give the on-box
    # CLI line instead.
    access) text+=$'\n\n'"🔓 This is a grant request that reached you directly (human-territory, or no lead available). Clear it on the box: sudo 5dive task answer ${ident} --value=\"granted\" (or denied)" ;;
  esac

  # DIVE-117/118 tap-to-answer buttons. GATED to the plugin types whose `tna:`
  # callback_query handler exists AND splits options byte-identically to this
  # emit: claude, codex, grok, antigravity (DIVE-118 — parity verified against
  # the actual handlers). opencode has no `tna:` handler yet, so it stays
  # excluded to avoid dead taps; add it here when its handler lands. Explicit
  # allowlist (not != "") so a future new plugin type never auto-emits dead
  # taps. Only finite-option gates get
  # buttons: decision-with-options (index into need_options) and approval
  # (approved/denied). callback_data is `tna:<numericId>:<idx|approved|denied>`
  # — numeric id + index keeps it under Telegram's 64-byte cap; the value is
  # re-resolved from the DB on tap, never trusted from the payload.
  # The option-split rule here MUST be byte-identical to the plugin's `tna:`
  # handler (split '|', trim, drop empties) or a tapped index resolves the wrong
  # option. Filtering empties also avoids an empty-text button (Telegram rejects
  # it, which would 400 the whole message — see the text-fallback in
  # _mirror_post). If nothing survives the filter, emit no keyboard (plain text).
  # DIVE-1490: the initial alert and every re-nag share this exact renderer, so
  # option indexing, recommendation ordering, nonce handling, and the plugin
  # allowlist cannot drift between first delivery and subsequent reminders.
  local reply_markup
  reply_markup=$(_task_gate_reply_markup "$numid" "$need_type" "$options" "$recommend" "$human_nonce" "$TASK_CH_TYPE")

  # DIVE-894: no tap buttons landed (non-tna channel type, or no valid options)
  # — a decision/approval gate would otherwise render with no way to act on a
  # dashboard-less box. Append the copy-pasteable on-box answer line.
  if [[ -z "$reply_markup" ]]; then
    case "$need_type" in
      decision) text+=$'\n\n'"Answer on the box: sudo 5dive task answer ${ident} --value=\"<option>\"" ;;
      approval) text+=$'\n\n'"Answer on the box: sudo 5dive task answer ${ident} --value=approved (or denied)" ;;
    esac
  fi

  _task_send_owner "$text" "$reply_markup" "$numid"
  return 0
}

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
  local where="need_type IS NOT NULL AND need_answered_at IS NULL AND status NOT IN ('done','cancelled')"
  local order="ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, created_at"
  if (( send )); then
    _task_inbox_send "$channel_proof" "$where" "$order"
    return
  fi
  [[ -z "$channel_proof" ]] || fail "$E_USAGE" "--channel-proof only applies with --send"
  if (( JSON_MODE )); then
    local rows
    rows=$(dbfmt -json "SELECT id, ident, title, status, priority, assignee, created_by, parent_id, created_at, need_type, ask, need_options, recommend, precedent_ref, need_answer, need_answered_at FROM tasks WHERE ${where} ${order};")
    [[ -n "$rows" ]] || rows="[]"
    # stdin, not --argjson — same ARG_MAX guard as `task ls`. (DIVE-222)
    printf '%s' "$rows" | jq -c '{ok:true, data:{inbox:.}}'
  else
    local cnt; cnt=$(db "SELECT COUNT(*) FROM tasks WHERE ${where};")
    if [[ "$cnt" == "0" ]]; then
      echo "inbox empty — nothing waiting on a human."
    else
      dbfmt -box "SELECT ident, priority, need_type, COALESCE(assignee,'-') AS owner, COALESCE(recommend,'-') AS recommend, COALESCE((SELECT ident FROM tasks p WHERE p.id=tasks.precedent_ref),'-') AS precedent, ask FROM tasks WHERE ${where} ${order};"
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
    || fail "$E_VALIDATION" "refused: /inbox --send blocked — the active task DB is not the prod DB (DIVE-1506 fail-closed fixture guard). Set FIVEDIVE_PROD_TASKS_DB if this IS prod."
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
  local shown=$(( total < cap ? total : cap ))

  local text="🗂 Gate inbox — waiting on you now:"
  local kbrows='[]' row id ident prio ntype options recommend gtier ask nonce="" markup="" idlist="" _mint_n=0
  local -a nonce_ids=() nonce_hashes=()
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS=$'\x1f' read -r id ident prio ntype options recommend gtier ask <<<"$row"
    [[ -n "$id" && -n "$ident" ]] || continue
    idlist+="${idlist:+,}${id}"
    text+=$'\n\n'"• [${ident}] ${ntype}, ${prio} — ${ask} /task_${id}"
    [[ -n "$recommend" ]] && text+=$'\n'"  ✅ Recommended: ${recommend}"
    [[ -n "$options" ]] && text+=$'\n'"  Options: ${options}"
    # DIVE-2356: same widened condition as the cmd_task_need mint — hard-human
    # TYPE **or** tier>=2. Without the tier arm a tier-2 `decision` filed before
    # that change stays nonce-less forever, since this rotation is the only other
    # write to human_nonce_hash on the non-escalation path. `tier` is now selected
    # below, spliced in AHEAD of `ask` so `ask` stays the greedy tail of the read.
    nonce=""; _mint_n=0
    case "$ntype" in approval|secret|manual) _mint_n=1 ;; esac
    [[ "${gtier:-}" =~ ^[0-9]+$ ]] && (( gtier >= 2 )) && _mint_n=1
    if (( _mint_n )); then
      nonce=$(_human_nonce_mint)
      if [[ -n "$nonce" ]]; then
        nonce_ids+=("$id")
        nonce_hashes+=("$(_human_nonce_sha "$nonce")")
      fi
    fi
    markup=$(_task_gate_reply_markup "$id" "$ntype" "$options" "$recommend" "$nonce" "$TASK_CH_TYPE" "$ident")
    if [[ -n "$markup" ]]; then
      kbrows=$(jq -cn --argjson a "$kbrows" --argjson b "$markup" '$a + ($b.inline_keyboard // [])' 2>/dev/null) || kbrows='[]'
    fi
  done < <(db "SELECT id||x'1f'||ident||x'1f'||priority||x'1f'||need_type||x'1f'||COALESCE(need_options,'')||x'1f'||COALESCE(recommend,'')||x'1f'||COALESCE(tier,'')||x'1f'||substr(replace(COALESCE(ask,''),x'0a',' '),1,240)
               FROM tasks WHERE ${where} ${order} LIMIT ${cap};")
  if (( total > cap )); then
    text+=$'\n\n'"…and $(( total - cap )) more — 5dive task inbox on the box or the dashboard."
  fi
  text+=$'\n\n'"Tap a button, open a /task link, or answer from the dashboard."

  local reply_markup=""
  [[ "$kbrows" != "[]" ]] && reply_markup=$(jq -cn --argjson rows "$kbrows" '{inline_keyboard:$rows}' 2>/dev/null) || true

  _task_send_owner "$text" "$reply_markup" "$idlist"
  if [[ "${TASK_SEND_DELIVERED:-0}" == "1" ]]; then
    # Rotate hashes only after a confirmed receipt (same ordering as the
    # heartbeat re-nag): an earlier alert's button dies only once a live
    # replacement is in the human's chat.
    local i
    for (( i=0; i<${#nonce_ids[@]}; i++ )); do
      db "UPDATE tasks SET human_nonce_hash=$(sqlq "${nonce_hashes[$i]}")
          WHERE id=${nonce_ids[$i]} AND need_answered_at IS NULL;" 2>/dev/null || true
    done
    # DIVE-2054: DELIBERATELY UNFENCED, same shape as "task clear-recs" (5389) —
    # carries chat_proof=$channel_proof, proof a real channel was (or wasn't) hit
    # for this digest send. A fixture store must never be able to suppress that.
    audit_log "task inbox send" "ok" 0 -- \
      "gates=${shown}/${total}" "chat_proof=${channel_proof:-none}" "message_id=${TASK_SEND_MESSAGE_IDS:-none}"
    ok "inbox digest sent (${shown}/${total} gates)" \
      '{sent:true, gates:($g|tonumber), total:($t|tonumber), message_ids:$m}' \
      --arg g "$shown" --arg t "$total" --arg m "${TASK_SEND_MESSAGE_IDS:-}"
  else
    # DIVE-2054: DELIBERATELY UNFENCED, same exemption as the "ok" branch above.
    audit_log "task inbox send" "error" 1 -- \
      "gates=${shown}/${total}" "chat_proof=${channel_proof:-none}"
    fail "$E_GENERIC" "inbox digest delivery unconfirmed — nonce hashes left unrotated, earlier alert buttons remain valid"
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
    [[ -n "$_nt" && -n "$_nat" ]] || fail "$E_CONFLICT" "$vident has no answered gate to verify"
    local _vfs=""; [[ "$_nt" != "secret" ]] && _vfs="$_na"
    local _signed=absent _valid=false
    if [[ -n "$_nsig" ]]; then
      _signed=present
      _gate_closure_verify "$vid" "$_nt" "$_vfs" "$_nb" "$_nat" "$_nuid" "$_nsig" && _valid=true
    fi
    # DIVE-2054: the nonce/signature being verified is itself TASKS_DB state for
    # $vident (not an independent real-world channel/identity fact) — fenced.
    _task_store_audit_log "gate-proof verify" "$([[ "$_valid" == true ]] && echo ok || echo error)" 0 -- \
      "task=$vident" "type=$_nt" "signed=$_signed" "valid=$_valid" "uid=${_nuid:-}" "by=${_nb:-}"
    if (( JSON_MODE )); then
      ok "gate-proof verify $vident: signed=$_signed valid=$_valid" \
        '{ident:$i, signed:$s, valid:($v=="true"), uid:$u, by:$b}' \
        --arg i "$vident" --arg s "$_signed" --arg v "$_valid" --arg u "${_nuid:-}" --arg b "${_nb:-}"
    else
      echo "ident:  $vident"; echo "signed: $_signed"; echo "valid:  $_valid"
      echo "uid:    ${_nuid:-—}"; echo "by:     ${_nb:-—}"
    fi
    return
  fi

  if [[ "${1:-}" == "enforce" ]]; then
    require_root "gate-proof enforce"
    local _ef; _ef=$(_gate_proof_enforce_file)
    case "${2:-status}" in
      on)  : > "$_ef"; chmod 0644 "$_ef" 2>/dev/null || true
           ok "gate-proof enforcement ON: approval/secret/manual answers now require human evidence (a valid --human-proof nonce or a non-agent SUDO_UID)" ;;
      off) rm -f "$_ef"
           ok "gate-proof enforcement OFF: audit-only; approval/secret/manual answers allowed without human evidence" ;;
      status)
           local _e _k
           _gate_proof_enforced && _e=on || _e=off
           [[ -s "$(_gate_proof_key_file)" ]] && _k=present || _k=absent
           if (( JSON_MODE )); then
             ok "gate-proof: enforce=$_e key=$_k" '{enforce:$e, key:$k}' --arg e "$_e" --arg k "$_k"
           else
             echo "enforce: $_e"; echo "key: $_k"
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
  fail "$E_USAGE" "gate-proof mint is removed (DIVE-950): the --proof evidence form was agent-forgeable. Gates clear via a human tap (per-gate nonce) or a non-agent SUDO_UID. Valid subcommands: gate-proof enforce on|off|status | verify <id> | sign."
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
    || fail "$E_AUTH_REQUIRED" "channel-proof did not verify — the chat id is not in this bot's access.json allowFrom (paired-human DMs). A bulk clear must come from the human's own verified channel."

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

cmd_task_answer() {
  tasks_db_init
  local value="" value_set=0 from="" human=0 human_proof="" channel_proof=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --value=*) value="${1#*=}"; value_set=1 ;;
      --from=*)  from="${1#*=}" ;;
      # DIVE-394: trusted human paths (the Telegram tap handler, the dashboard/API
      # exec) pass --human to mark the answer as human-sourced. Recorded as
      # provenance in need_answered_by; the enforced boundary for hard-line gates
      # is still root (below), so an agent passing --human gains nothing.
      --human)   human=1 ;;
      # DIVE-950: evidence-form (b), the DIVE-519 --proof token, is DROPPED — it
      # was agent-forgeable (`5dive gate-proof` mint is require_root only, so any
      # agent could `sudo`-mint a valid token: the easy one-sudo forge). The flag
      # is still PARSED but IGNORED — a rollout-safe no-op — so an in-flight caller
      # that still sends --proof=AUTO/<token> (an old dashboard/shelld mid-deploy)
      # does not hit "unknown flag"; it falls through to the surviving evidence
      # forms: (a) --human-proof nonce, or (c) a non-agent SUDO_UID.
      --proof=*) : ;;
      # DIVE-916: per-gate HUMAN nonce (from the Telegram tap callback_data /
      # dashboard payload) — the evidence form for the plugin-tap path, whose
      # SUDO_UID is the spawning agent. Verified against human_nonce_hash below.
      --human-proof=*) human_proof="${1#*=}" ;;
      # DIVE-1305: paired-human channel proof — a chat_id the trusted plugin
      # verified as the paired human's OWN verified DM (∈ access.json allowFrom).
      # Honored as human evidence ONLY for tier<2 gates (see below); a tier-2
      # hard gate (money/destructive/secret) NEVER accepts it and keeps its
      # per-gate button tap. This is the "go with recs from your own channel"
      # clear (lodar's chosen scope, DIVE-1305 decision 2026-07-16).
      --channel-proof=*) channel_proof="${1#*=}" ;;
      --)        shift; positional+=("$@"); break ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task answer <id|DIVE-N> --value=\"...\"  (omit --value for a secret gate)"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # Must have a pending (unanswered) gate to answer.
  local nt
  nt=$(db "SELECT CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL THEN need_type ELSE '' END FROM tasks WHERE id=${id};")
  [[ -n "$nt" ]] || fail "$E_CONFLICT" "$ident has no pending human gate (nothing to answer)"

  # DIVE-1117: resolve the gate's stored risk tier now — the human-only + evidence
  # blocks below key on need_type (approval/secret/manual), but tier 2 is the true
  # hard-human floor. A `decision` gate can be FLOORED to tier 2 by the T2 category
  # heuristic (cmd_task_need), yet decision is agent-clearable BY TYPE, so those
  # blocks let it through. The tier-2 provenance floor further down uses this.
  local gtier; gtier=$(db "SELECT COALESCE(tier,'') FROM tasks WHERE id=${id};")

  # DIVE-2228: refuse a STATUS-MOVING answer on an already-CLOSED row, before any
  # write. cmd_task_answer's only precondition is the one above — "this row has an
  # unanswered gate" — and nothing in it is about status, while a closed task
  # carrying a dangling gate is an ordinary state (file a gate, then close or
  # cancel without answering it). Two writers below then ran with no status
  # predicate at all: the DIVE-909 close-as-done branch (WHERE id=${id}) and the
  # DIVE-552 loop-gate advance/bounce. MEASURED on an isolated fixture as a third
  # party who is neither maker nor verifier: on a `done` row, rc=0 and done_at
  # RE-STAMPED to now (the verifier's close time destroyed); on a `cancelled` row,
  # rc=0 and cancelled -> done, with _task_cascade_unblock then releasing its
  # dependents — something `task cancel` itself never does.
  #
  # `result` survived both, because DIVE-2067's CASE WHEN result='' guard was
  # already applied. THAT is why this was missed for so long: the field everyone
  # learned to watch was protected, so the row looked defended while status and
  # done_at were not. When auditing a status writer, check every field the close
  # sets, not just the one the verb names.
  #
  # REACHABILITY, stated precisely: every gate LIST query carries
  # status NOT IN ('done','cancelled'), so a freshly rendered inbox never offers
  # the button on a closed task. The exposure is the message ALREADY SENT —
  # callback_data tna:<id>:done -> teambot -> `task answer --value=done`. Telegram
  # inline buttons on delivered messages DO NOT EXPIRE, so a manual gate pinged
  # while the task was open keeps a live ✅ Done button in chat history
  # indefinitely, and a tap months later lands the write. The live surface is
  # filtered; the historical surface is not, and it outlives the state it was
  # rendered against.
  #
  # SCOPE is DIVE-2067's, not symmetry. Only the paths that MOVE the row are
  # refused. Answering a decision/approval/secret gate on a closed row is
  # measured clean (its else-branch is fenced on status='blocked') and stays
  # working — including the DIVE-931 secret-drop write, which may legitimately
  # land after the task closed. The refusal fires here rather than at the write
  # so the command is all-or-nothing: past this point the answer is already
  # recorded, and refusing there would leave a gate answered under a non-zero rc.
  local _lk; _lk=$(_loop_kind "$id")
  local _close_done=0
  if [[ "$nt" == "manual" && "$_lk" != gate:* ]]; then
    local _dv; _dv=$(printf '%s' "${value:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    [[ "$_dv" == "done" ]] && _close_done=1
  fi
  local _row_status; _row_status=$(db "SELECT status FROM tasks WHERE id=${id};")
  local _row_closed=0
  case "$_row_status" in done|cancelled) _row_closed=1 ;; esac
  if (( _row_closed )) && { (( _close_done )) || [[ "$_lk" == gate:* ]]; }; then
    policy_refuse "$E_CONFLICT" "task_answer_closed_row" "DIVE-2228" "$ident" \
      "$ident is already ${_row_status} — answering this gate would move a closed task's status, so it is refused. The close record (status, done_at, result) stands."
  fi

  # DIVE-1305: the paired-human channel proof is a valid human-evidence form, but
  # STRICTLY for tier<2 gates. tier 2 is the hard-human floor (money/destructive/
  # secret are floored there) and lodar's chosen scope keeps those a
  # deliberate per-gate button tap — a plain chat line must NOT clear them. So we
  # honor --channel-proof only when the gate is tier<2 AND the chat_id verifies
  # against the bot's own access.json allowFrom (the paired human's verified DM).
  # When valid it marks the answer human-sourced (human=1 -> need_answered_by
  # human:*), so provenance is honest. For a tier-2 gate _cp_ok stays 0, human is
  # untouched, and the tier-2 provenance floor below rejects it exactly as before.
  local _cp_ok=0
  if [[ -n "$channel_proof" && "$gtier" != "2" ]]; then
    _gate_channel_proof_ok "$channel_proof" && _cp_ok=1
  fi
  (( _cp_ok )) && human=1

  # DIVE-394: approval/secret are HUMAN-ONLY gates. Reject answers that come from
  # an agent acting as itself — that's the DIVE-391 incident, where an Olivia
  # endorsement (running as agent-<name>) silently cleared a human approval gate.
  # The boundary is the CALLER's unix identity, because the legitimate human
  # paths run as privileged, non-agent users while an agent runs as `agent-<name>`:
  #   - Telegram tap  -> plugin shells `sudo -n 5dive task answer` -> root
  #   - dashboard     -> API exec tunnel -> shelld runs as `claude` (non-root)
  #   - human on box  -> their own (non-agent) login
  #   - agent itself  -> `agent-<name>`  <- the only case we block
  # So: block when the caller is an `agent-*` user. This closes the reported
  # incident WITHOUT breaking either live path (root tap OR claude dashboard),
  # and needs no coordinated plugin/API deploy. decision/manual stay open: agents
  # legitimately resolve those. Residual: an agent that runs `sudo 5dive task
  # answer` becomes root and passes — closing that (require a --human secret the
  # trusted paths inject) is the documented fast-follow; the --human flag is
  # already parsed + recorded as provenance to stage it.
  # DIVE-916: `manual` joins approval/secret as a hard human gate here — it's a
  # step only a person can do, so an agent must not self-answer it either.
  # DIVE-1182: a builder ship-gate (approval/manual) that DIVE-1145 routing sent
  # to the org lead carries routed_reviewer. The designated lead — and ONLY that
  # agent, on ONLY this routed gate — may clear it, closing the gap where such a
  # gate was human-only and pinged lodar instead of Marcus. Resolve it up front so
  # both the uid block and the evidence block below honour the exception. `secret`
  # is never routed (routed_reviewer stays NULL), so it can never take this path.
  # DIVE-1243: `access` joins approval/manual as lead-clearable — the designated
  # routed_reviewer (and only that agent, on only this routed gate) may clear it.
  # DIVE-2004: the caller identity here must be the one the KERNEL enforced, not
  # the one the CLI was told. `need_answered_by` is provenance — `task_actor`
  # returns `--from=<anything>` verbatim — so authorizing on it would let any agent
  # mint `lead:<the reviewer>` for itself. `_gate_authenticated_actor` is the
  # unforgeable half, and it FAILS CLOSED (empty -> no lead-clear).
  local _routed_rev; _routed_rev=$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE id=${id};")
  local _lead_clear=0 _rc_sealed=0 _rc_deny=""
  if [[ ( "$nt" == "approval" || "$nt" == "manual" || "$nt" == "access" ) && -n "$_routed_rev" ]]; then
    local _auth; _auth=$(_gate_authenticated_actor)
    if [[ -n "$_auth" && "$_auth" == "$_routed_rev" ]]; then
      # DIVE-2233 PHASE 1 — READER ONLY, DECIDES NOTHING. Routing still carries the
      # clearance exactly as it does today; `_lead_clear=1` is unconditional here and
      # this release changes no gate's outcome. What the seal WOULD have decided is
      # resolved and recorded on the audit row below (`sealed=`), and phase 3 flips
      # this one branch to make it binding.
      #
      # Reader-before-enforcer, and the ordering is forced rather than cautious: the
      # constitution normalizer REJECTS unknown top-level authority keys and
      # loadConstitution fails closed to shipped defaults, so a council motion sealing
      # `gate_clear_leads` BEFORE this release ships would not merely fail to help —
      # it would invalidate the whole document on every box still running the current
      # CLI and silently collapse it to defaults. The key has to be READABLE before it
      # can safely be SEALED, and sealed before it can be ENFORCED.
      #
      # Deliberately NOT a feature flag: a flag on an agent-writable surface reopens
      # the exact self-grant this ticket closes. The gate between phases is a release,
      # which agents cannot cut for themselves.
      #
      # Recording it now is not bookkeeping. `sealed=0` rows are the fleet-wide
      # measurement of which lead-clears phase 3 will start refusing — collected for a
      # whole release, from production traffic, before anything breaks. Running the
      # reader on every lead-clear also keeps it from rotting unexercised between the
      # two cuts.
      _lead_clear=1
      if _gate_clear_lead_allowed "$_routed_rev"; then
        _rc_sealed=1
      else
        _rc_deny="$(_gate_clear_lead_denied_reason)"
      fi
    fi
  fi
  # DIVE-2099: the org lead's STANDING authority over ENGINEERING approvals — the
  # same clearance as the routed lead-clear above, but WITHOUT requiring that this
  # gate was routed to them at filing time. Identity is the unforgeable half and
  # is checked FIRST: `_gate_authenticated_actor` reads the kernel-enforced unix
  # caller (never --from, which `task_actor` returns verbatim — DIVE-2004), and
  # `_gate_standing_lead` resolves the holder and itself fails closed to EMPTY.
  # Both empty-checks are load-bearing: without them "" == "" would hand the
  # authority to every caller on a box with no constitution.
  #
  # WHO the lead is comes from the agent NAMED in the SEALED constitution, never
  # from the org chart (iteration 2; lodar answered `anchor-to-named-agent`
  # 2026-07-27). See `_gate_standing_lead` for why the chart is a self-grant path
  # on a NOPASSWD:ALL host and why the seal is what makes the anchor hold.
  #
  # `_ls_filer` is read for the AUDIT ROW ONLY and grants nothing. It stays the
  # stored assignee (the agent that hit the gate — `task need` stamps it) falling
  # back to created_by, the same COALESCE `owner` uses below, so the log still
  # answers "whose gate was this" without the answer feeding the decision.
  local _lead_standing=0
  if [[ "$_lead_clear" != "1" && "$nt" == "approval" ]]; then
    local _ls_auth _ls_lead _ls_filer
    _ls_auth=$(_gate_authenticated_actor)
    _ls_filer=$(db "SELECT COALESCE(NULLIF(assignee,''), NULLIF(created_by,''), '') FROM tasks WHERE id=${id};")
    _ls_lead=$(_gate_standing_lead 2>/dev/null || true)
    if [[ -n "$_ls_auth" && -n "$_ls_lead" && "$_ls_auth" == "$_ls_lead" ]]; then
      # DIVE-2224: read the two fields SEPARATELY rather than ||' '|| in SQL.
      local _ls_ask _ls_title
      _ls_ask=$(db "SELECT COALESCE(ask,'') FROM tasks WHERE id=${id};")
      _ls_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
      if _gate_lead_standing_eligible "$nt" "$gtier" "$_ls_ask" "$_ls_title"; then
        _lead_standing=1
        _lead_clear=1
      fi
    fi
  fi
  # DIVE-1243: `access` is NOT open-agent-clearable (unlike decision) — a random
  # agent must not self-grant. It is gated here like the human-only types, so only
  # the routed lead (_lead_clear above) OR a human may clear it. When access fell
  # through to a human (T2 floor / no distinct lead), routed_reviewer is NULL, so
  # _lead_clear=0 and a human is required — exactly the intended fall-through.
  if [[ "$nt" == "approval" || "$nt" == "secret" || "$nt" == "manual" || "$nt" == "access" ]]; then
    local _caller; _caller=$(id -un 2>/dev/null || echo '?')
    if [[ "$_caller" == agent-* && "$_lead_clear" != "1" ]]; then
      # No audit_log here: the blocked caller is an agent user that can't write
      # the root-owned audit log anyway (it would only leak a perms error to
      # stderr). The fail + non-zero exit is the record.
      fail "$E_AUTH_REQUIRED" "$ident is a '$nt' gate — only a human can clear it. Answer it from Telegram (tap the button) or the dashboard; an agent can't self-answer an approval/secret/manual gate."
    fi
    # DIVE-2054: routed_reviewer is task-store state for $ident — fenced.
    # DIVE-2099: `standing=` distinguishes the two clearances that reach here.
    # This row records the DECISION TO ALLOW, which is not the same event as the
    # answer landing in the DB — the authoritative post-write row is emitted
    # after the UPDATE below (DIVE-2090: a pre-check row is not an audit of the
    # write; the two diverge in both directions).
    # DIVE-2233 phase 1: `sealed=` records what the SEAL would have decided about this
    # clear, and `denied=` why not. Nothing here changes the outcome — the row is the
    # instrument. Counting `sealed=0` rows fleet-wide over this release is how we size
    # phase 3's blast radius from real traffic instead of predicting it.
    [[ "$_lead_clear" == "1" ]] && _task_store_audit_log "task answer lead-clear" "ok" 0 -- "task=$ident" "type=$nt" "reviewer=${_routed_rev:-<none>}" "standing=$_lead_standing" "sealed=$_rc_sealed" "would_deny=${_rc_deny:-<none>}" 2>/dev/null || true
  fi

  # DIVE-916/950: hard human gates (approval/secret/manual) need HUMAN evidence
  # beyond the agent-* uid block above — that block sees `sudo`->root as non-agent,
  # so it cannot catch the agent->sudo->root path. The trusted human paths supply
  # ONE of two evidence forms (see below): the per-gate --human-proof nonce (the
  # plugin tap, whose SUDO_UID is the spawning agent) or a non-agent SUDO_UID (the
  # dashboard exec as claude, the DIVE-931 drop write, a human-on-box login). We
  # ALWAYS audit the attempt; we only REJECT when NEITHER form is present, and only
  # once enforcement is flipped on (`gate-proof enforce on`). Ships DORMANT until
  # the nonce-carrying plugin is confirmed live FLEET-WIDE (else a live tap that
  # can't supply the nonce yet would fail closed). DIVE-950 dropped the old DIVE-519
  # --proof form: it was agent-forgeable via the require_root `gate-proof` mint.
  #
  # DIVE-525 (UX): a HUMAN's tap must NEVER be rejected — "you tapped but it's not
  # enough" is the exact confusion lodar hit dogfooding. Under enforcement we reject
  # ONLY when no evidence form is present (the forge: an agent's bare
  # `sudo task answer --human`, SUDO_UID=agent, no nonce). Every trusted path
  # supplies at least one form, so a real human is never blocked. The agent-* uid
  # block above + this rule stop the DIVE-515/516 incident (an agent silently
  # self-clearing). Bar-raise scope: closes the one-liner + the easy sudo-mint
  # forge, NOT a determined root-sudo agent (separate sudo-reduction track).
  if [[ "$nt" == "approval" || "$nt" == "secret" || "$nt" == "manual" || "$nt" == "access" ]]; then
    # DIVE-916/950: TWO EQUIVALENT human-evidence forms — accept EITHER one, never
    # require both (double-gating a real tap violates DIVE-525):
    #   (a) --human-proof=<nonce> matching this gate's stored hash — the plugin
    #       tap / dashboard payload, the one path whose SUDO_UID is the agent,
    #   (c) a non-agent SUDO_UID — a claude/root interactive login, the dashboard
    #       exec (shelld runs as SUDO_UID=claude), AND the DIVE-931 secret-drop
    #       write (SUDO_UID=claude survives the nested non-sudo task-answer exec;
    #       verified empirically).
    # DIVE-950 dropped the former form (b), a DIVE-519 --proof token: it was
    # agent-forgeable (`sudo 5dive gate-proof` mint is require_root only), so it
    # raised the bar no higher than the sudo it already required. This still
    # supersedes the DIVE-519 "proof OR bare --human" rule: a bare --human is NOT
    # sufficient — that was the sudo→--human forge (DIVE-916 threat).
    local _hp=0 _su=0
    [[ -n "$human_proof" ]] && _human_nonce_verify "$id" "$human_proof" && _hp=1
    _gate_sudo_uid_nonagent && _su=1
    # DIVE-1305: a verified paired-human channel proof is the fourth evidence
    # form — but _cp_ok is already gated to tier<2 above, so it can satisfy the
    # evidence rule only for a tier-1 approval/access gate (never a tier-2 hard
    # gate, whose _cp_ok is 0). A tier-2 approval still requires the nonce/SUDO_UID
    # forms + is caught by the tier-2 floor below.
    # DIVE-1182: a routed builder gate cleared by its designated lead reviewer is a
    # sanctioned agent path — count the lead-clear as evidence so enforcement (the
    # "no human evidence ⇒ reject" rule) does not block the very exception granted
    # by the uid block above. Scoped to approval/manual with a matching
    # routed_reviewer (never secret), so no un-routed human gate is affected.
    local _evid=$(( _hp || _su || _lead_clear || _cp_ok ))
    local _caller2; _caller2=$(id -un 2>/dev/null || echo '?')
    # DIVE-2054: the human-proof/nonce evidence being scored here is stored
    # against $ident in TASKS_DB (not an independent channel/delivery fact like
    # the 3 named exemptions) — fenced.
    _task_store_audit_log "task answer gate" "$([[ $_evid -eq 1 ]] && echo ok || echo error)" 0 -- \
      "task=$ident" "type=$nt" "channel_proof=$([[ -n "$channel_proof" ]] && echo present || echo absent)" "cp_ok=$_cp_ok" \
      "human_proof=$([[ -n "$human_proof" ]] && echo present || echo absent)" "nonce_valid=$_hp" \
      "sudo_nonagent=$_su" "human=$human" "caller=$_caller2" "sudo_uid=${SUDO_UID:-}" \
      "enforce=$(_gate_proof_enforced && echo on || echo off)"
    # DIVE-525: a real human tap is NEVER rejected — every trusted path supplies
    # at least one evidence form (plugin→nonce, dashboard→proof/SUDO_UID=claude,
    # human-on-box→non-agent SUDO_UID, drop→SUDO_UID=claude). Under enforcement,
    # reject only when NONE is present (the forge: an agent's bare
    # `sudo task answer --human`). Ships DORMANT (audit-only) until the plugin
    # --human-proof injection is confirmed live fleet-wide; root then flips
    # `gate-proof enforce on` (Marcus ship-gates the flip).
    if _gate_proof_enforced && (( ! _evid )); then
      fail "$E_AUTH_REQUIRED" "$ident ($nt) needs a human to clear it — tap the button in Telegram or use the dashboard. (An agent can't self-clear an approval/secret/manual gate.)"
    fi
  fi

  # DIVE-1117 (companion to DIVE-1115, CLI side / defense in depth): tier 2 is the
  # HARD human floor and NEVER auto-applies, so `task answer` must refuse a
  # NON-HUMAN answer on a tier-2 gate regardless of need_type. The blocks above
  # only fire for the approval/secret/manual types; a `decision` gate floored to
  # tier 2 by the T2 category heuristic (OSS-16, keyword-floored by "secrets")
  # slipped past and accepted a bare-agent answer (need_answered_by=main) with
  # `gate-proof enforce` ON. The floor is provenance: an answer is human-sourced
  # only when a trusted path passed --human (recorded human:* below). Every real
  # human path — the Telegram tap, the dashboard/API exec — passes --human, so a
  # genuine human answer is NEVER rejected here (DIVE-525). We gate this on
  # `gate-proof enforce` for the SAME rollout envelope as the evidence block
  # above; enforce is ON fleet-wide (DIVE-950). We deliberately do NOT require the
  # evidence forms here: a tier-2 `decision` gate's tap runs as SUDO_UID=agent and
  # its option buttons carry NO nonce in their callback_data, so demanding evidence
  # would reject a real human decision tap — provenance is the correct, tap-safe
  # floor. Residual (an agent sudo->--human-forging human:* on a tier-2 *decision*)
  # is the forged-human threat DIVE-916/DIVE-1115 own; tracked as follow-up.
  #
  # DIVE-2356 UPDATED THE FIRST HALF OF THAT REASONING, AND READ THIS BEFORE
  # TIGHTENING THIS BLOCK. A tier-2 decision now DOES mint a per-gate nonce at
  # filing — so "it has no nonce" is no longer why evidence is not required here.
  # The reason is now narrower and entirely about the TAP: the decision option
  # buttons still do not carry the nonce (telegram-pi's TNA_RE is greedy and would
  # swallow it), so a real human tap arrives with no proof to offer and an evidence
  # requirement would reject it — the DIVE-525 trap.
  #
  # The sanctioned next step is NOT an evidence requirement. It is the far weaker
  # "refuse a tier>=2 answer whose human_nonce_hash IS NULL", and it must not land
  # until tier-2 decision gates filed BEFORE DIVE-2356 have aged out or been
  # rescued by the digest/re-nag mints: at the time of writing that rule would
  # refuse 43 of the last 47 tier-2 decision answers. Check the live NULL count
  # first; do not infer that it has drained. NO downgrade path from the answer side by design: an over-fired T2
  # (the heuristic can over-match) waits for a human — the conservative correct
  # default for a hard floor; re-file at a lower --tier if the floor misfired.
  if [[ "$gtier" == "2" ]] && (( ! human )) && _gate_proof_enforced; then
    local _caller3; _caller3=$(id -un 2>/dev/null || echo '?')
    # DIVE-1437: a tier-2 gate that was LEAD-ROUTED (routed_reviewer set) but is an
    # approval/manual builder gate is the DIVE-1429 stall — the DIVE-1145/1182
    # routing sent it to the org lead, but the T2 hard-human floor here refuses the
    # lead's non-human answer, AND cmd_task_need RETURNED before task_need_notify
    # so the human never got a tap button. The lead then hand-asks the human in
    # plain chat with no button to tap. Instead of dead-ending here, ESCALATE to
    # the human via the normal ping path so task_need_notify fires WITH the tap
    # keyboard, and take the lead out of the loop (clear routed_reviewer). We mint
    # a FRESH per-gate human nonce (approval/manual are hard human gates), so
    # anti-forge is preserved: only a real human tap/nonce or non-agent SUDO_UID
    # can clear the escalated gate — the escalation itself grants no clearance.
    # Scoped to approval/manual routed gates (the DIVE-1429 case): `access` is
    # DELIBERATELY lead-clearable by DIVE-1243, `secret` is never routed, and a
    # non-routed tier-2 gate already got its human button at filing — those keep
    # the original refuse. eng_ship/curation are forced tier-1 at filing, so they
    # never reach this block. Ties to DIVE-1330/1243 handoff patterns.
    if [[ -n "$_routed_rev" ]] && [[ "$nt" == "approval" || "$nt" == "manual" ]]; then
      local _esc_ask _esc_opts _esc_rec _esc_sk _esc_conn
      _esc_ask=$(db "SELECT COALESCE(ask,'') FROM tasks WHERE id=${id};")
      _esc_opts=$(db "SELECT COALESCE(need_options,'') FROM tasks WHERE id=${id};")
      _esc_rec=$(db "SELECT COALESCE(recommend,'') FROM tasks WHERE id=${id};")
      _esc_sk=$(db "SELECT COALESCE(secret_key,'') FROM tasks WHERE id=${id};")
      _esc_conn=$(db "SELECT COALESCE(connector,'') FROM tasks WHERE id=${id};")
      # Mint a fresh human nonce so the escalated tap can clear it (mirrors the
      # cmd_task_need mint for approval/manual). Take the lead out (routed_reviewer
      # NULL) and re-arm the ping (gate_pinged_at NULL) so task_need_notify fires
      # fresh with the tap keyboard.
      local _esc_nonce=""; _esc_nonce=$(_human_nonce_mint)
      db "UPDATE tasks SET routed_reviewer=NULL, gate_pinged_at=NULL$([[ -n "$_esc_nonce" ]] && echo ", human_nonce_hash=$(sqlq "$(_human_nonce_sha "$_esc_nonce")")") WHERE id=${id};"
      # DIVE-2054: DELIBERATELY UNFENCED (ticket-named exemption) — records an
      # escalation actually leaving the fleet.
      audit_log "task answer escalate-to-human" ok 0 -- \
        "task=$ident" "type=$nt" "tier=$gtier" "reason=T2-floor refused routed gate — escalated to human with buttons" \
        "was_routed_to=$_routed_rev" "caller=$_caller3" "sudo_uid=${SUDO_UID:-}" 2>/dev/null || true
      task_need_notify "$ident" "$nt" "$_esc_ask" "$_esc_opts" "$_esc_rec" "$_esc_sk" "$_esc_conn" "$_esc_nonce" "" || true
      ok "$ident is a tier-2 human gate ($nt) — the org lead can't clear it, so it was ESCALATED to the human with a tap button. Awaiting their answer." \
         '{id:($i|tonumber), ident:$id, status:"blocked", need_type:$ty, tier:2, escalated_to_human:true, was_routed_to:$rv, ask:$ak}' \
         --arg i "$id" --arg id "$ident" --arg ty "$nt" --arg rv "$_routed_rev" --arg ak "$_esc_ask"
      return 0
    fi
    # DIVE-2054: same reasoning as the "task answer gate" site above — fenced.
    _task_store_audit_log "task answer gate" error 0 -- \
      "task=$ident" "type=$nt" "tier=$gtier" "reason=non-human answer on tier-2 floor" \
      "human=$human" "caller=$_caller3" "sudo_uid=${SUDO_UID:-}"
    fail "$E_AUTH_REQUIRED" "$ident is a tier-2 human gate ($nt) — only a human can clear it, so an agent answer is refused. Tap the button in Telegram or use the dashboard. (If the tier-2 floor over-fired on this gate, re-file it at a lower --tier.)"
  fi

  # Who resumes: the agent that hit the gate (assignee), else the creator.
  local owner; owner=$(db "SELECT COALESCE(NULLIF(assignee,''), NULLIF(created_by,''), '') FROM tasks WHERE id=${id};")
  # DIVE-394 provenance: record WHO answered. `human:` prefix when a trusted path
  # passed --human; otherwise the resolved actor label.
  local answered_by; answered_by=$(task_actor "$from")
  (( human )) && answered_by="human:${answered_by}"
  # DIVE-1182: a routed builder gate cleared by its designated lead is recorded as
  # lead-sourced provenance (NOT human:*) — honest that an agent lead, not a human,
  # cleared it. Never overrides a genuine human:* answer.
  [[ "$_lead_clear" == "1" ]] && (( ! human )) && answered_by="lead:${answered_by}"
  # DIVE-2099 (design note 3): a STANDING-authority clear must stay distinguishable
  # from a human tap AND from a routed lead-clear, forever — not merely in a log
  # line that can rotate or diverge from the row (DIVE-2090). So the distinction
  # is carried by the persisted provenance itself: `lead:standing:<actor>`. The
  # `lead:` prefix is preserved deliberately, so every existing `lead:*` consumer
  # (cmd_push's delegated-push predicate, the digest's human-touch count, the
  # proof ledger) keeps treating it as agent-sourced-not-human with no change;
  # the `standing:` infix is the new, additive fact. `need_answered_by` is inside
  # the DIVE-756 signed closure, so this marker is tamper-evident: a raw DB edit
  # that downgrades `lead:standing:main` to `lead:main` fails `gate-proof verify`.
  [[ "$_lead_standing" == "1" ]] && (( ! human )) && answered_by="lead:standing:$(task_actor "$from")"

  # DIVE-756: stamp the REAL invoker uid ($SUDO_UID survives `sudo -u agent-X`,
  # unlike need_answered_by) and a tamper-evidence signature over the closure
  # facts. We compute the timestamp in shell (not datetime('now')) so the exact
  # same string is signed AND stored, letting `gate-proof verify` recompute it.
  # Signing needs the root-only key: in a root context we sign in-process; from
  # the non-root trusted path (dashboard exec as claude) we re-exec the root-only
  # `gate-proof sign` over sudo. Best-effort — a box that can't sign just stores
  # an empty sig (verify reports "unsigned"); the answer NEVER fails on this.
  local _uid="${SUDO_UID:-$(id -u 2>/dev/null || echo "")}"
  local _ts; _ts=$(date -u '+%Y-%m-%d %H:%M:%S')
  local _vfs=""; [[ "$nt" != "secret" ]] && _vfs="$value"
  local _sig=""
  if [[ -n "$_uid" ]]; then
    if [[ $EUID -eq 0 ]]; then
      _gate_proof_ensure_key 2>/dev/null || true
      _sig=$(_gate_closure_sign "$id" "$nt" "$_vfs" "$answered_by" "$_ts" "$_uid" 2>/dev/null || echo "")
    else
      _sig=$(_gate_closure_payload "$id" "$nt" "$_vfs" "$answered_by" "$_ts" "$_uid" \
               | sudo -n 5dive gate-proof sign 2>/dev/null || echo "")
    fi
  fi
  local _uidsql="NULL"; [[ -n "$_uid" ]] && _uidsql="$_uid"

  # Record the answer. A `secret` gate NEVER stores its value — writing a raw
  # key into this group-claude-readable db is a plaintext-secret-at-rest leak.
  # We only stamp need_answered_at (the "provided" signal); the agent loads the
  # key out-of-band. decision/approval/manual store the value in need_answer.
  if [[ "$nt" == "secret" ]]; then
    (( value_set )) && fail "$E_USAGE" "$ident is a secret gate — do not pass --value; the key must not be stored in the shared db. Run: 5dive task answer $ident  (records it as provided + pings the agent to load it from where you placed it)"
    db "UPDATE tasks SET need_answered_at=$(sqlq "$_ts"), need_answered_by=$(sqlq "$answered_by"), need_answered_uid=${_uidsql}, need_answer_sig=$(sqlq "$_sig") WHERE id=${id};"
  else
    (( value_set )) || fail "$E_USAGE" "--value is required (the human's answer)"
    db "UPDATE tasks SET need_answer=$(sqlq "$value"), need_answered_at=$(sqlq "$_ts"), need_answered_by=$(sqlq "$answered_by"), need_answered_uid=${_uidsql}, need_answer_sig=$(sqlq "$_sig") WHERE id=${id};"
  fi

  # DIVE-2099: the authoritative record of a STANDING-authority clear. Emitted
  # AFTER the write and reading `need_answered_by` BACK OUT of the row, so it
  # audits the state that actually landed rather than the intent to write it
  # (DIVE-2090: gate-answer state was reaching the DB off the audited path, and a
  # pre-check row greens identically whether or not the write happened). This is
  # a privilege being exercised by the party that asked for it, so it names the
  # authenticated caller, the real invoker uid, the tier and type it was allowed
  # under, and the persisted provenance — enough to re-derive the eligibility
  # decision from the log alone. Never fails the answer.
  #
  # `standing_lead=` is the NAME the sealed constitution carried at clear time and
  # `authority_source=` says where it came from, so a reader can tell an anchored
  # clear from the iteration-1 chart-derived one without diffing the binary.
  # `filer=`/`routed_reviewer=` are recorded as context and are NOT inputs to the
  # decision — the audit must not imply an authority the code does not consult.
  if [[ "$_lead_standing" == "1" ]]; then
    local _ls_persisted; _ls_persisted=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${id};")
    _task_store_audit_log "task answer lead-standing-clear" \
      "$([[ "$_ls_persisted" == lead:standing:* ]] && echo ok || echo error)" 0 -- \
      "task=$ident" "type=$nt" "tier=$gtier" "authority=DIVE-2099 org-lead standing (engineering approval)" \
      "authority_source=sealed-constitution:authority.eng_approval_lead" \
      "authenticated_caller=${_ls_auth:-}" "standing_lead=${_ls_lead:-}" "filer=${_ls_filer:-}" "routed_reviewer=${_routed_rev:-<none>}" \
      "persisted_provenance=${_ls_persisted:-<none>}" "invoker_uid=${_uid:-}" "human=$human" 2>/dev/null || true
  fi

  # DIVE-2090: audit the answer AT THE WRITE, for EVERY need_type. Until now the
  # only `task answer gate` rows came from the PRE-CHECKS above — the
  # approval/secret/manual/access evidence block and the tier-2 floor refusal —
  # so a `decision` gate, and any gate that is neither one of those four types
  # nor tier-2-refused, stored need_answer/at/by/uid/sig with NO audit event
  # behind it at all. That is the reported defect (three instances on DIVE-2051 /
  # DIVE-2084): a stored, signed, nonce-bearing gate answer that the audit log
  # cannot account for, which is exactly the property DIVE-756 exists to provide.
  # Scale when this landed: AT LEAST 78 answered `decision` gates on the live
  # board, none of them auditable (2026-07-26 17:16 UTC; need_type='decision' AND
  # need_answered_at IS NOT NULL AND need_answered_by NOT LIKE 'auto:%'; 127
  # across all types). A lower bound at a moment, not a fixed fact — it climbs
  # with every gate the fleet answers.
  #
  # The divergence ran BOTH ways, so this is not just a missing row. The
  # pre-check rows are emitted BEFORE the write and report a CHECK outcome: an
  # approval that passes the evidence block and then trips the tier-2 floor, or
  # hits the `--value is required` / secret `--value` usage `fail` just above,
  # leaves an `ok` row behind with no answer stored. This row is emitted AFTER
  # the UPDATE and reports the provenance AS STORED, so `task answer gate` at
  # last means "an answer was written" rather than "a check passed". The two are
  # distinguishable by the `answered_by=` field, which only this site carries.
  #
  # Fenced like its sibling call sites (DIVE-2054): a row built from live
  # TASKS_DB state must not be written into the fleet audit log by a fixture
  # store. `|| true` because the write has ALREADY landed — an audit log that
  # cannot be written must never fail an answer that is already durable (a
  # missing row is the defect we are fixing, but losing the answer would be
  # worse, and the caller has no way to retry a half-applied answer). NEVER logs
  # $value: a secret gate stores nothing, and a decision answer is the human's
  # prose, neither of which belongs in the fleet log.
  local _caller4; _caller4=$(id -un 2>/dev/null || echo '?')
  _task_store_audit_log "task answer gate" ok 0 -- \
    "task=$ident" "type=$nt" "tier=${gtier:-}" "answered_by=$answered_by" \
    "uid=${_uid:-}" "sig=$([[ -n "$_sig" ]] && echo present || echo absent)" \
    "human=$human" "lead_clear=$_lead_clear" "cp_ok=$_cp_ok" \
    "caller=$_caller4" "sudo_uid=${SUDO_UID:-}" || true

  # DIVE-909: a standalone MANUAL gate answered "done" is the human saying "this
  # is handled / complete" — close the task as DONE, not back to todo. Without
  # this a park-marker holding COMPLETED work had no honest close: the agent
  # can't `task done` (blocked by its own pending gate, DIVE-555) and the only
  # agent-allowed escape was `task cancel`, which mislabels finished work as
  # cancelled (DIVE-524). The already-shipped ✅ Done tap (tna:<id>:done ->
  # `task answer --value=done`, DIVE-356) now lands here and closes cleanly — no
  # plugin/fork change needed. Loop GATE steps are EXEMPT (_lk=gate:*): a manual
  # answer there drives the relay advance below, which owns that status move.
  # DIVE-2228: _lk and _close_done are resolved ABOVE, before any write, because
  # the closed-row refusal keys on them. Do not recompute them here.
  if (( _close_done )); then
    # Close as done + stamp a result IF empty (never clobber real work notes) so
    # the dashboard/creator sees why it closed rather than a blank card.
    # DIVE-2228: the status predicate is defence in depth — the refusal above is
    # the real fence. It is kept so this UPDATE cannot re-stamp a graded row even
    # if a future caller reaches it by another route.
    db "UPDATE tasks SET status='done', done_at=datetime('now'),
           result=CASE WHEN COALESCE(result,'')='' THEN 'Closed via manual-gate tap — marked done by '||$(sqlq "$answered_by") ELSE result END
        WHERE id=${id} AND status NOT IN ('done','cancelled');"
    # DIVE-1415: a manual-gate answer that closes the task DONE is terminal — its
    # dependents must release just as they would on `task done`.
    _task_cascade_unblock "$id" || true
  else
    # Clearing the gate ≠ unblocking. `status='blocked'` is overloaded (human
    # gate AND task-task `block` edges), so RECOMPUTE rather than hardcode todo:
    # flip to todo only if no block edges remain — same edge-check `unblock` does
    # — else stay blocked (still waiting on another task). Answered-ness lives in
    # need_answered_at, so the task already left the inbox regardless of status.
    db "UPDATE tasks SET status='todo'
        WHERE id=${id} AND status='blocked'
          AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id});"
  fi
  local newstatus; newstatus=$(db "SELECT status FROM tasks WHERE id=${id};")

  # DIVE-552: a loop GATE step was just answered → advance the relay. Approve
  # (decision "Approve →", or any manual answer) closes the gate step and frees
  # the next step; "Do better ↩" bounces to the previous step to redo (re-blocks
  # the gate by it; when that step re-completes the gate re-fires fresh). Reuses
  # _task_loop_advance + the block edges. Best-effort; never fails the answer.
  # (_lk was resolved above for the DIVE-909 close-as-done check — reuse it.)
  # DIVE-560: a loop APPROVAL gate only advances on a HUMAN-cleared answer
  # (need_answered_by=human:*). The answer path above already blocks an agent
  # self-answering an approval gate; this makes the loop's "the final say is
  # yours" guarantee explicit and regression-proof — if a non-human path ever
  # clears it (e.g. a future regression, or the audited sudo-bypass), the relay
  # simply doesn't advance. manual gates stay agent-answerable (agents
  # legitimately resolve those), so they're exempt. Falling through here without
  # advancing still records the answer + emits the success output below.
  local _gate_may_advance=1
  if [[ "$_lk" == "gate:approval" ]]; then
    local _ab; _ab=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${id};")
    case "$_ab" in human:*) : ;; *) _gate_may_advance=0 ;; esac
  fi
  case "$_lk" in
    gate:*)
      if (( _gate_may_advance )); then
      # Bounce (redo the previous step) vs advance. Match the reject vocabulary
      # of BOTH gate styles: the old decision options ("Do better ↩") and the
      # approval buttons ("denied" — DIVE-560). NB "denied" does NOT contain the
      # substring "deny", so it must be matched explicitly; missing it would let a
      # human's DENY silently ADVANCE the loop. Anything else (approve/approved)
      # advances.
      local _lv; _lv=$(printf '%s' "${value:-}" | tr '[:upper:]' '[:lower:]')
      if [[ "$_lv" == *"better"* || "$_lv" == *"reject"* || "$_lv" == *"deny"* || "$_lv" == *"denied"* || "$_lv" == *"declin"* ]]; then
        local _run _prev
        _run=$(db "SELECT COALESCE(parent_id,'') FROM tasks WHERE id=${id};")
        _prev=$(db "SELECT id FROM tasks WHERE parent_id=${_run:-0} AND id<${id} AND body LIKE '%${_LOOP_MARK}:%' ORDER BY id DESC LIMIT 1;")
        if [[ -n "$_prev" ]]; then
          # DIVE-2228: the fence goes IN THE WHERE, matching the idiom the
          # else-branch above has always used, so a future write here either
          # copies its neighbours or looks visibly different from all of them.
          # THE ${_prev} WRITE IS DELIBERATELY NOT FENCED — it targets a
          # DIFFERENT row, and reopening it is the whole point of a bounce: the
          # previous step is ALWAYS done at that moment, so a status fence there
          # would not harden the bounce, it would delete it. (A bounce onto a
          # CANCELLED _prev would be wrong for a different reason; that is
          # DIVE-552's semantics, unmeasured, and deliberately not changed here.)
          # tests/task_answer_closed_row_unit.sh enumerates these writes and
          # asserts the rule per target, so the exemption is graded, not assumed.
          db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES (${id}, ${_prev});
              UPDATE tasks SET status='blocked' WHERE id=${id} AND status NOT IN ('done','cancelled');
              UPDATE tasks SET status='todo', started_at=NULL WHERE id=${_prev};"
          local _pw _pl; _pw=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${_prev};"); _pl=$(db "SELECT title FROM tasks WHERE id=${_prev};")
          [[ -n "$_pw" ]] && ( cmd_send "$_pw" --from="loop" --message="↩ Loop bounced back — redo: ${_pl}" ) >/dev/null 2>&1 || true
        fi
      else
        # DIVE-2228: defence in depth, same as the close-as-done branch — a
        # gate STEP that is already closed is refused above, before any write.
        db "UPDATE tasks SET status='done', done_at=datetime('now') WHERE id=${id} AND status NOT IN ('done','cancelled');"
        _task_loop_advance "$id" || true
        # DIVE-1415: _task_loop_advance only frees this gate's loop-STEP siblings;
        # a non-loop task blocked_by this gate step is a cross-DAG dependent it
        # never touches. Cascade so those release on the gate's terminal close.
        _task_cascade_unblock "$id" || true
      fi
      fi
      ;;
  esac

  # Best-effort resume ping over the existing agent-send path. We deliberately
  # do NOT embed the answer value: cmd_send mirrors the outbound into the group
  # chat, so a `secret` answer would leak. The agent reads need_answer itself
  # via `task show` (its own pane only). A stopped or non-agent owner just
  # yields pinged:false — it never fails the answer.
  local pinged=0
  # DIVE-909: a close-as-done manual gate needs no "resume the task" ping — the
  # task is finished, not waiting to resume. Skip it (the `now done` output is
  # the signal); pinging the owner to resume a closed task is just confusing.
  if [[ -n "$owner" ]] && (( ! _close_done )); then
    local pingmsg
    if [[ "$nt" == "secret" ]]; then
      pingmsg="${ident} secret gate marked provided — resume the task and load the key from where it was placed (its .env / your own channel), NOT from the task."
    else
      pingmsg="${ident} gate cleared — your '${nt}' ask was answered. Resume the task; run \`5dive task show ${ident}\` for the value."
    fi
    local actor; actor=$(task_actor "$from")
    if valid_sender_label "$actor"; then
      ( cmd_send "$owner" --from="$actor" --message="$pingmsg" ) >/dev/null 2>&1 && pinged=1 || true
    else
      ( cmd_send "$owner" --message="$pingmsg" ) >/dev/null 2>&1 && pinged=1 || true
    fi
  fi

  local note=""
  [[ $pinged -eq 1 ]] && note=" + pinged $owner"
  ok "$ident answered ($nt) — now ${newstatus}${note}" \
     '{id:($i|tonumber), status:$st, need_type:$nt, provided:true, need_answer:(if $nt=="secret" then null else $v end), owner:(($o|select(length>0)) // null), pinged:($p=="1")}' \
     --arg i "$id" --arg st "$newstatus" --arg nt "$nt" --arg v "$value" --arg o "$owner" --arg p "$pinged"
}

# cmd_task_escalate — DIVE-449: the /task_<id> Telegram "Escalate" button (and a
# plain CLI verb). Semantics A (Mark's call 2026-06-17): "flag for attention" —
# bump the task's priority up ONE tier (capped at urgent) AND ping both the
# owning agent ("get eyes on it / I'm stuck") and the paired human, so a stuck
# task can't sit unseen at its old priority. Does NOT file a human gate (that's
# `task need`) or reassign (that's `task assign`). The bump + escalated_at/by
# audit stamp persist; the two pings are best-effort and never fail the verb.
cmd_task_escalate() {
  tasks_db_init
  local from=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from=*) from="${1#*=}" ;;
      --)       shift; positional+=("$@"); break ;;
      -*)       fail "$E_USAGE" "unknown flag: $1" ;;
      *)        positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task escalate <id|DIVE-N>"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"

  # Don't escalate a finished task — there's nothing to get eyes on.
  local status; status=$(db "SELECT status FROM tasks WHERE id=${id};")
  [[ "$status" == "done" || "$status" == "cancelled" ]] && \
    fail "$E_CONFLICT" "$ident is $status — nothing to escalate."

  local old_pri title assignee created_by
  old_pri=$(db "SELECT COALESCE(priority,'medium') FROM tasks WHERE id=${id};")
  title=$(db "SELECT title FROM tasks WHERE id=${id};")
  # Who to get eyes on it: the assignee, else the creator.
  local owner; owner=$(db "SELECT COALESCE(NULLIF(assignee,''), NULLIF(created_by,''), '') FROM tasks WHERE id=${id};")

  # Bump up one tier, capped at urgent. low/medium -> high keeps the common
  # "this is stuck" tap meaningful; a second tap on a high task reaches urgent.
  local new_pri
  case "$old_pri" in
    low|medium) new_pri="high" ;;
    high)       new_pri="urgent" ;;
    urgent)     new_pri="urgent" ;;
    *)          new_pri="high" ;;
  esac

  local actor; actor=$(task_actor "$from")
  db "UPDATE tasks SET priority=$(sqlq "$new_pri"), escalated_at=datetime('now'), escalated_by=$(sqlq "$actor") WHERE id=${id};"

  local pri_note="$old_pri → $new_pri"
  [[ "$old_pri" == "$new_pri" ]] && pri_note="$new_pri (already top tier)"

  # Ping the owning agent over the existing agent-send path — but never ping the
  # actor about its own task (an agent escalating its own work already knows).
  local pinged=0
  if [[ -n "$owner" && "$owner" != "$actor" ]]; then
    local pingmsg="🔺 ${ident} escalated by ${actor} — flagged as needing attention (priority ${pri_note}). Get eyes on it; run \`5dive task show ${ident}\`."
    if valid_sender_label "$actor"; then
      ( cmd_send "$owner" --from="$actor" --message="$pingmsg" ) >/dev/null 2>&1 && pinged=1 || true
    else
      ( cmd_send "$owner" --message="$pingmsg" ) >/dev/null 2>&1 && pinged=1 || true
    fi
  fi

  # Ping the paired human so an escalation surfaces on their phone (best-effort,
  # mirrors task_need_notify's owner-channel resolution + send path).
  local notified_human=0
  if _task_owner_channel; then
    local htext="🔺 [${ident}] escalated by ${actor} — needs attention"$'\n\n'"${title}"$'\n\n'"priority ${pri_note}"
    _task_send_owner "$htext" "" && notified_human=1 || true
  fi

  local note=""
  [[ $pinged -eq 1 ]] && note=" + pinged $owner"
  ok "$ident escalated — priority ${pri_note}${note}" \
     '{id:($i|tonumber), priority:$np, was:$op, owner:(($o|select(length>0)) // null), pinged:($p=="1"), human_notified:($h=="1")}' \
     --arg i "$id" --arg np "$new_pri" --arg op "$old_pri" --arg o "$owner" --arg p "$pinged" --arg h "$notified_human"
}

cmd_task_rm() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task rm <id|DIVE-N>"
  resolve_task_id "$1"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  db "DELETE FROM tasks WHERE id=${id};"
  ok "$ident deleted" '{id:($i|tonumber), deleted:true}' --arg i "$id"
}
