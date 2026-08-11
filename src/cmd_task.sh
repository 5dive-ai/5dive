
# -------- 5dive task — host-shared task queue --------

_task_usage() {
  cat <<USAGE
5dive task — shared task queue (sqlite at ${STATE_DIR}/tasks/tasks.db)

  init                                          one-time root bootstrap of the store
  add <title...> [--body=<text>|--body-file=<path>] [--from=<who>] [--parent=<id>]
      [--priority=low|medium|high|urgent] [--branch=<name>]
      [--assignee=<agent|role:<r>|charter:<kw>>]
      [--recurring="<5-field cron>"] [--accept=<criteria>|--accept-file=<path>] [--verify=<cmd>]
      [--verifier=<agent>] [--max-iters=<n>] [--no-verify] [--task-budget=<tokens|\$cost>]
      [--customer] [--already-blocked=<what it blocked>]   escapes for the internal-filing cap
  ls [--status=] [--assignee=] [--mine] [--all] [--recurring]   open rows, priority-ordered
  show <id|DIVE-N>                              full detail + subtasks + blockers
  assign <id> <agent>                           reassign
  verifier <id> <agent> [--accept=] [--max-iters=]   attach or re-point the verifier rail
  set-body <id> <text...>|--file=<path> [--append]   replace the body, or append to it
  set-title <id> <text...>                      overwrite the title (audited; refused once closed)
  set-branch <id> <branch>                      bind the row to a git branch
  wip-cap-install [--relane=<lane>]             snapshot each lane's actionable count as its
                                                frozen WIP ceiling (deliberate, once)
  set-budget <id> <tokens|\$cost|none>           raise/lower the token budget, or 'none' to exempt
  set-overlap <tmpl> <skip|spawn> [bound]       recurring template: does an open instance suppress the next slot?
                                                the row from the enforced ${_TASK_BUDGET_BUILTIN:-5000000}-token default

  start <id>                                    -> in_progress
  done <id> [--result=<text>|--result-file=<path>] [--no-graded-sha]
                                                -> done, or hand to the verifier if one is set
                                                verifiers: put \`graded-sha: <sha>\` in the result;
                                                --no-graded-sha is the audited escape
  deliver <id> --pr=<url> [--result=|--result-file=<path>]   record the delivery PR, hand to the verifier
  verify <id> [--cmd=] [--result=|--result-file=<path>] [--no-done] [--timeout=]
                                                run the check; exit 0 = pass
  reject <id> [--feedback=<what to fix>]        verifier FAIL: bounce back to the maker
  cancel <id> [--result=<text>]                 -> cancelled
  done|cancel [--keep-worktree]                 keep node_modules in that row's worktrees
  done|cancel|deliver [--append-result|--force-result]   close a row that already has a result

  block <id> --by=<id>                          add a blocks edge
  unblock <id> [--by=<id>]                      drop edge(s); back to todo if clear
  park <id> --reason="..." --wake=<date|+Nd>    quiet timed wait; auto-unparks at --wake
  unpark <id>                                   clear a park early
  escalate <id> [--from=<who>]                  bump priority a tier, ping the owner
  rm <id>                                       delete (cascades subtasks + edges)

  need <id> --type=decision|secret|approval|manual|access --ask="..."|--ask-file=<path>
      [--options=A|B] [--recommend=<A>|--recommend-file=<path>] [--tier=0|1|2]
      [--needs=<capability>] [--discusses=<why>] [--rubber-stamp-ok="<why>"]
      [--mode=approve-to-send|confirm-after-send]   --type=approval: is the action
                                                    already DONE? (default: not yet)
      [--probe='<cmd>']                           --type=access: self-check the block
      [--secret-key=<ENV> --connector=<stem> | --out-of-band="<where>"]   (--type=secret needs one)
      WHO CAN CLEAR IT, by type (DIVE-3228 — check this BEFORE you file, not after
      'task answer' refuses you):
        decision            any agent. Tier 1 by default.
        approval            tier 1 by default: the routed lead clears it. At tier 2
                            (you typed --tier=2, or the category floor fired on the
                            ask) it is HUMAN-ONLY — a routed lead's answer is
                            escalated to a human tap, not accepted.
        access              tier 2 by default, but lead-clearable at that default:
                            the routed lead clears it. Pinned --tier=2 or a category
                            floor hit makes it HUMAN-ONLY.
        manual              HUMAN-ONLY at tier 2 (its default) — a step only a person
                            can perform.
        secret              ALWAYS HUMAN-ONLY, at every tier. Never routed.
      And on ANY type, --needs=spend_authority|human_tap|secret_provision is
      HUMAN-ONLY by declaration: it outranks the tier and every routing kind.
  need <id> --withdraw                          cancel a pending gate that is now moot
  answer <id> --value="..." [--proof=<token>] [--channel-proof=<chat> [--channel-msg=<id>]]
      [--tap-uid=<tg user id> [--tap-username=<handle>] [--tap-msg=<message id>]]
      [--relay-agent=<name>]     a button tap: WHO tapped, and whose bot carried it
  clear-recs --channel-proof=<chat_id> [--only=<id>]     apply pending recommendations
  inbox [--send [--channel-proof=<chat>]]       human-gated rows; --send DMs the owner
  coordinator [--json]                          the agent fronting the needs-you banner

  loops [--stuck] [--escalate-stuck] [--all] [--runs] [--watch[=secs]] [--kill <loopId>]
  merge-audit [--limit=N] [--json]              closed rows whose named PR never merged
  merge-gate-selftest [--pr=<url>] [--json]     can THIS seat's merge-gate actually query GitHub?
  gate-history <id>                             displaced gates + when they retired
  reclaim <id>|--all [--dry-run]                reclaim node_modules from closed worktrees

  status: todo | in_progress | blocked | done | cancelled
  A verifier (!= the assignee) makes 'done' a handoff, not a close.
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
  [[ $# -gt 0 ]] || { _task_usage; mark_reported; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    init)            cmd_task_init "$@" ;;
    add|new)         cmd_task_add "$@" ;;
    ls|list)         cmd_task_ls "$@" ;;
    show|view)       cmd_task_show "$@" ;;
    gate-history)    cmd_task_gate_history "$@" ;;
    assign)          cmd_task_assign "$@" ;;
    set-branch)      cmd_task_set_branch "$@" ;;
    set-body)        cmd_task_set_body "$@" ;;
    set-title)       cmd_task_set_title "$@" ;;
    set-budget)      cmd_task_set_budget "$@" ;;
    set-overlap)     cmd_task_set_overlap "$@" ;;
    wip-cap-install) cmd_task_wip_cap_install "$@" ;;
    start)           cmd_task_start "$@" ;;
    done|close)      cmd_task_done "$@" ;;
    deliver)         cmd_task_deliver "$@" ;;
    merge-audit)     cmd_task_merge_audit "$@" ;;   # DIVE-1935 retrospective sweep
    merge-gate-selftest) cmd_task_merge_gate_selftest "$@" ;;  # DIVE-1935 instrument check
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
  # DIVE-2627: --file's text, kept separate until the positional words are known.
  local file_text="" text_src=""
  local -a words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --append)      append=1 ;;
      --append=*)    fail "$E_USAGE" '--append is a boolean flag; pass the text as a positional argument: task set-body <id> --append "<text>"' ;;
      # DIVE-2627: the body read VERBATIM from a file. Note this is strictly more
      # faithful than the positional form even with a well-behaved shell: the
      # positional words are re-joined with single spaces below, so a multi-line
      # body typed inline is already flattened before it reaches the row.
      --file=*)      _prose_flag_dupe --file "$text_src"
                     _read_prose_file --file "${1#*=}"
                     file_text="$_PROSE_FILE_VALUE"; text_src="--file" ;;
      --)            shift; words+=("$@"); break ;;
      -*)            fail "$E_USAGE" "unknown flag: $1" ;;
      *)             if [[ -z "$task" ]]; then task="$1"; else words+=("$1"); fi ;;
    esac
    shift
  done
  local text="${words[*]:-}"
  if [[ -n "$text_src" ]]; then
    [[ -z "$text" ]] \
      || fail "$E_USAGE" "--file conflicts with the positional text — pass the body exactly once, either inline or from a file."
    text="$file_text"
  fi
  [[ -n "$task" && -n "$text" ]] \
    || fail "$E_USAGE" "usage: 5dive task set-body <id|DIVE-N> <text...>|--file=<path> [--append]"
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local st
  st=$(db "SELECT status FROM tasks WHERE id=${id};")
  [[ "$st" != "done" && "$st" != "cancelled" ]] \
    || fail "$E_VALIDATION" "$ident is already $st — bounce it back first: 5dive task reject $ident --feedback=\"…\""
  local body; body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
  local prior_len=${#body} prior_lines=0
  if [[ -n "$body" ]]; then
    local prior_without_newlines="${body//$'\n'/}"
    prior_lines=$(( ${#body} - ${#prior_without_newlines} + 1 ))
  fi
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
  local new_len=${#newbody} new_lines=0
  if [[ -n "$newbody" ]]; then
    local new_without_newlines="${newbody//$'\n'/}"
    new_lines=$(( ${#newbody} - ${#new_without_newlines} + 1 ))
  fi
  local mode="replaced"; (( append )) && mode="appended"
  _task_store_audit_log "task set-body" "ok" 0 -- \
    "task=$ident" "actor=$(task_actor)" "mode=$mode" "prior_len=$prior_len" || true
  local prose="$ident body $mode"
  if (( ! append )); then
    local line_delta=$(( new_lines - prior_lines )) char_delta=$(( new_len - prior_len ))
    local line_delta_display="$line_delta" char_delta_display="$char_delta"
    (( line_delta > 0 )) && line_delta_display="+$line_delta"
    (( char_delta > 0 )) && char_delta_display="+$char_delta"
    local prior_line_word="lines" new_line_word="lines"
    (( prior_lines == 1 )) && prior_line_word="line"
    (( new_lines == 1 )) && new_line_word="line"
    prose+=" ($prior_lines $prior_line_word -> $new_lines $new_line_word, $line_delta_display; $prior_len chars -> $new_len chars, $char_delta_display)"
  fi
  ok "$prose" \
    '{ident:$id, mode:$m, prior_len:$pl, new_len:$nl, prior_lines:$pls, new_lines:$nls}' \
    --arg id "$ident" --arg m "$mode" \
    --argjson pl "$prior_len" --argjson nl "$new_len" \
    --argjson pls "$prior_lines" --argjson nls "$new_lines"
}

# `5dive task set-title <id|DIVE-N> <text...>` — DIVE-2848. `set-body` has existed
# since DIVE-1920 for exactly this reason and the title had no equivalent: after
# `task add` it was immutable except by a direct sqlite UPDATE, which scoped-sudo
# makers cannot do. That asymmetry is the wrong way round. A body correction lands
# where a careful reader will find it; a WRONG TITLE is what the next reader sees
# FIRST, on the board, in the digest, in every gate alert — and this ticket's own
# sibling DIVE-2846 shipped with an overstated claim in its title that only a body
# appendix retracts. Overwrite-only (there is no coherent "append" to a title), and
# audited with the PRIOR title, because a retitle is exactly the edit that makes the
# earlier discussion of a row unreadable if nobody can see what it used to say.
# Refuses on a closed task, same guard as set-body: a closed row is frozen.
# DIVE-2794 — set/raise/exempt a row's token budget AFTER it was filed.
#
# This verb is the difference between a usable carve-out and a theoretical one.
# The enforced 5M default parks a row the heartbeat finds over budget, and the
# incident case main flagged is a LIVE row at 3am that nobody filed with
# `--task-budget=none` because nobody was thinking about budgets when the box
# went down. Without a post-hoc setter the only escape is re-filing the row,
# which loses its history mid-incident — so the exemption would exist only for
# people who predicted they would need it. Unparking alone is NOT enough and is
# the trap this closes: the sweep re-parks the row on the very next tick unless
# the budget itself changed.
# DIVE-2794 arm two — install the per-lane WIP caps. Deliberate, once, and the
# ONLY thing that creates a cap: no cap is ever minted as a side effect of a
# filing. Snapshots each lane's current actionable count as its frozen ceiling.
#
# Idempotent by default: a lane that already has a cap keeps it, because
# re-snapshotting is exactly the "cap tracks the count" lock this arm exists to
# avoid — running install twice must not ratchet anybody. --relane <lane> resets
# one lane deliberately (a lead clear, the one sanctioned way a cap moves).
cmd_task_wip_cap_install() {
  tasks_db_init
  local one=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --relane=*) one="${1#--relane=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $1 (usage: 5dive task wip-cap-install [--relane=<lane>])" ;;
    esac
    shift
  done
  local lane n installed=0 lines=""
  while IFS= read -r lane; do
    [[ -n "$lane" ]] || continue
    [[ -z "$one" || "$lane" == "$one" ]] || continue
    if [[ -z "$one" ]]; then
      local have; have=$(db "SELECT value FROM task_prefs WHERE key=$(sqlq "wip_cap:$lane");" 2>/dev/null || echo "")
      [[ "$have" =~ ^[0-9]+$ ]] && continue     # already installed: never re-snapshot
    fi
    n=$(_task_lane_actionable "$lane")
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    # Floor of 1: a lane with no actionable rows would otherwise install cap 0,
    # and `actionable >= cap` is then 0 >= 0 — a breach — so an EMPTY lane could
    # never accept its first row and a brand-new agent would be frozen at birth.
    (( n < 1 )) && n=1
    db "INSERT INTO task_prefs (key,value) VALUES ($(sqlq "wip_cap:$lane"),$(sqlq "$n"))
        ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now');"
    installed=$((installed+1)); lines+="  ${lane}: ${n}"$'\n'
  done < <(db "SELECT DISTINCT assignee FROM tasks WHERE assignee IS NOT NULL AND assignee!='' AND kind='standard';" 2>/dev/null)
  ok "installed WIP caps for ${installed} lane(s)${lines:+
$lines}" '{installed:$n}' --argjson n "${installed:-0}"
}

# DIVE-2272 (decision DIVE-2270). Classify an EXISTING recurring template.
#
# WHY A VERB AND NOT ONLY AN `add` FLAG: every template on the board predates the
# column, and the classification the decision calls for is a per-template judgment
# its AUTHOR has to make ("would tomorrow's run discharge today's obligation?").
# Requiring a template to be deleted and re-created to answer that would lose its
# ident, its history and its last_fired_at — i.e. the cost of classifying would be
# paid in exactly the record that says whether the beat is healthy.
cmd_task_set_overlap() {
  tasks_db_init
  local task="" pol="" bound=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  if [[ -z "$task" ]]; then task="$1"
          elif [[ -z "$pol" ]]; then pol="$1"
          elif [[ -z "$bound" ]]; then bound="$1"
          else fail "$E_USAGE" "unexpected extra argument '$1'"; fi ;;
    esac
    shift
  done
  [[ -n "$task" && -n "$pol" ]] \
    || fail "$E_USAGE" "usage: 5dive task set-overlap <template|DIVE-N> <skip|spawn> [bound]  (skip = an open instance suppresses the next slot, today's default; spawn = fire anyway up to <bound> open instances, then skip and record it)"
  [[ "$pol" == "skip" || "$pol" == "spawn" ]] \
    || fail "$E_VALIDATION" "bad policy '$pol' (skip|spawn)"
  if [[ -n "$bound" ]]; then
    [[ "$pol" == "spawn" ]] \
      || fail "$E_VALIDATION" "a bound only means anything under 'spawn' (under skip the FIRST open instance already suppresses, so no bound is ever reached)"
    [[ "$bound" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "bad bound '$bound' (positive integer)"
  fi
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local kind; kind=$(db "SELECT kind FROM tasks WHERE id=${id};")
  [[ "$kind" == "recurring" ]] \
    || fail "$E_VALIDATION" "$ident is kind='$kind', not a recurring TEMPLATE — the overlap policy governs whether a template's NEXT SLOT fires, and a one-off row has no next slot. Did you mean the template this instance came from? (5dive task show $ident)"
  local prior prior_bound
  prior=$(db "SELECT COALESCE(on_overlap,'skip') FROM tasks WHERE id=${id};")
  prior_bound=$(db "SELECT COALESCE(overlap_bound,'') FROM tasks WHERE id=${id};")
  # An explicit 'skip' stores 'skip' rather than NULL: "the author looked at this
  # and chose dedup" and "nobody has classified it yet" are different states, and
  # the classification pass needs to be able to see which templates it still owes.
  # The bound is cleared under skip — leaving a stale one would imply a threshold
  # that nothing consults.
  local bound_sql="NULL"
  [[ "$pol" == "spawn" && -n "$bound" ]] && bound_sql="$bound"
  [[ "$pol" == "spawn" && -z "$bound" && -n "$prior_bound" ]] && bound_sql="$prior_bound"
  db "UPDATE tasks SET on_overlap=$(sqlq "$pol"), overlap_bound=${bound_sql}, updated_at=datetime('now') WHERE id=${id};"
  local eff_bound; eff_bound=$(db "SELECT COALESCE(overlap_bound, ${TASKS_OVERLAP_BOUND_DEFAULT:-3}) FROM tasks WHERE id=${id};")
  local open_now; open_now=$(db "SELECT COUNT(*) FROM tasks WHERE from_template_id=${id} AND status NOT IN ('done','cancelled');" 2>/dev/null) || open_now="?"
  [[ "$open_now" =~ ^[0-9]+$ ]] || open_now="?"
  local note=""
  if [[ "$pol" == "spawn" ]]; then
    note=" Next slot fires while fewer than ${eff_bound} instances are open (${open_now} now); at the bound it skips and stamps last_skipped_at, exactly as skip does today."
    # Say the already-over-bound case out loud: switching to spawn does not, by
    # itself, restart a beat that is already past its threshold.
    [[ "$open_now" =~ ^[0-9]+$ ]] && (( open_now >= eff_bound )) \
      && note+=" NOTE: ${open_now} open is ALREADY at/over the bound, so this template stays suppressed until some of those close — switching to spawn did not restart it."
  else
    note=" Any open instance now suppresses the next slot (5dive task ls --recurring shows which one under blocked_by)."
  fi
  ledger_emit "task.overlap_policy_set" ident="$ident" task_id="$id" \
    actor="$(task_actor)" \
    detail="on_overlap ${prior} -> ${pol} (bound ${bound_sql/NULL/default ${TASKS_OVERLAP_BOUND_DEFAULT:-3}})" || true
  ok "$ident on-overlap ${prior} → ${pol} (bound ${eff_bound}).${note}" \
     '{ident:$i, on_overlap:$p, prior:$pr, bound:($b|tonumber), open_instances:$o}' \
     --arg i "$ident" --arg p "$pol" --arg pr "$prior" --arg b "$eff_bound" --arg o "$open_now"
}

cmd_task_set_budget() {
  tasks_db_init
  local task="" val=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  if [[ -z "$task" ]]; then task="$1"; elif [[ -z "$val" ]]; then val="$1"; fi ;;
    esac
    shift
  done
  [[ -n "$task" && -n "$val" ]] \
    || fail "$E_USAGE" "usage: 5dive task set-budget <id|DIVE-N> <tokens|\$cost|none>  (none = exempt this row from the enforced default)"
  [[ "$val" =~ ^[1-9][0-9]*$ || "$val" =~ ^\$[0-9]+(\.[0-9]+)?$ || "$val" == "none" ]] \
    || fail "$E_VALIDATION" "budget must be a token count (e.g. 50000), a dollar cost (e.g. \$1.50), or 'none'"
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local st; st=$(db "SELECT status FROM tasks WHERE id=${id};")
  [[ "$st" != "done" && "$st" != "cancelled" ]] \
    || fail "$E_VALIDATION" "$ident is already $st — a closed row spends nothing, so its budget is moot"
  local prior; prior=$(db "SELECT COALESCE(task_budget,'(default)') FROM tasks WHERE id=${id};")
  db "UPDATE tasks SET task_budget=$(sqlq "$val"), updated_at=datetime('now') WHERE id=${id};"
  # Say the parked case out loud rather than leaving the caller to discover that
  # raising a budget did not, by itself, restart anything.
  local parked; parked=$(db "SELECT CASE WHEN parked_at IS NOT NULL THEN 1 ELSE 0 END FROM tasks WHERE id=${id};")
  local hint=""
  [[ "${parked:-0}" == "1" ]] && hint=" It is still PARKED — 5dive task unpark $ident to resume it."
  ok "$ident budget ${prior} → ${val}.${hint}" '{ident:$i, budget:$b, parked:$p}' \
     --arg i "$ident" --arg b "$val" --arg p "${parked:-0}"
}

cmd_task_set_title() {
  tasks_db_init
  local task=""
  local -a words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --)            shift; words+=("$@"); break ;;
      -*)            fail "$E_USAGE" "unknown flag: $1" ;;
      *)             if [[ -z "$task" ]]; then task="$1"; else words+=("$1"); fi ;;
    esac
    shift
  done
  local text="${words[*]:-}"
  [[ -n "$task" && -n "$text" ]] \
    || fail "$E_USAGE" "usage: 5dive task set-title <id|DIVE-N> <text...>"
  # A title is a single line by construction — it renders on one row of the board
  # and inside one Telegram alert. Collapse rather than refuse: the caller's shell
  # may have handed us words that already lost their newlines anyway.
  text="${text//$'\n'/ }"
  [[ ${#text} -le 200 ]] \
    || fail "$E_VALIDATION" "title is ${#text} chars; keep it under 200 so it survives the board, the digest and a gate alert without truncation. Put the detail in the body: 5dive task set-body $task --append \"...\""
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  local st; st=$(db "SELECT status FROM tasks WHERE id=${id};")
  [[ "$st" != "done" && "$st" != "cancelled" ]] \
    || fail "$E_VALIDATION" "$ident is already $st — its title is frozen (closed tasks don't get retro-edited; bounce it back first with: 5dive task reject $ident --feedback=\"…\")"
  local prior; prior=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
  if [[ "$prior" == "$text" ]]; then
    ok "$ident title unchanged (already \"$text\")" '{ident:$id, changed:false, title:$t}' \
       --arg id "$ident" --arg t "$text"
    return 0
  fi
  db "UPDATE tasks SET title=$(sqlq "$text") WHERE id=${id};"
  # The PRIOR title is the payload here. Without it the audit row records that a
  # retitle happened and destroys the only copy of what it replaced.
  _task_store_audit_log "task set-title" "ok" 0 -- \
    "task=$ident" "actor=$(task_actor)" "prior=$prior" "new=$text" || true
  ok "$ident retitled: \"$prior\" -> \"$text\"" \
     '{ident:$id, changed:true, prior_title:$p, title:$t}' \
     --arg id "$ident" --arg p "$prior" --arg t "$text"
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
#   2. else the lone agent carrying the coordinator MARKER inside their role prose
#      (DIVE-2041, below), when exactly one does
#   3. else the lone org root (the single-CEO case — zero config)
#   4. else empty — ambiguous (multi-root, none tagged) or empty org chart; we
#      leave the task unassigned exactly as before rather than guess wrong.
# Prints the coordinator name (or nothing). Safe on an empty/missing org table.
#
# DIVE-2041 — WHY TIER 2 EXISTS. `agents_org.role` does double duty: it is the
# human prose the org chart and council roster RENDER ("AI CEO — conducts the
# fleet (advisory)", "QA / testing") AND, at tier 1, an exact-match machine
# sentinel. So the only way to tag a coordinator was to DESTROY that agent's
# display text — which is exactly why DIVE-2031 was fixed by re-parenting an org
# root instead (option B, `org set olivia --role=coordinator`, was rejected for
# this reason). Tier 2 lets the marker live INSIDE the prose ("AI CEO — fleet
# coordinator"), so tagging costs nothing. Space-anchored so "coordinator"
# matches and "uncoordinated" does not, and uniqueness-checked like every other
# resolver here: >1 holder is ambiguous and yields nothing rather than a guess.
# Tier 1 is kept ahead of it so an exact tag still wins when prose elsewhere also
# mentions the word. Measured on the live chart 2026-08-09: zero of 13 roles
# contain the marker, so this tier adds no candidate today and the resolution
# stays on the lone-root fallback — it widens what an operator CAN express, it
# does not re-route anything already resolved.
_task_resolve_coordinator() {
  if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE role='coordinator';")" == "1" ]]; then
    db "SELECT name FROM agents_org WHERE role='coordinator' LIMIT 1;"
    return
  fi
  local _marker="lower(' '||COALESCE(role,'')) LIKE '% coordinator%'"
  if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE ${_marker};")" == "1" ]]; then
    db "SELECT name FROM agents_org WHERE ${_marker} LIMIT 1;"
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

# DIVE-2719: THE DEPTH DECISION IS MADE AT THE ONE MOMENT IT CANNOT BE ANSWERED.
# _task_verify_skip_reason above runs at `task add`, where there is no branch, no
# diff and no PR — so it is forced onto the only axis that exists then: the words
# in the title. Measured on DIVE-2712: the title described a real user-facing
# Telegram defect (correctly), so it earned the full rail; the delivered change
# was ONE LINE in a test stub, and four verifier iterations graded it. No title
# classifier could have known — the fact had not happened yet.
#
# So re-ask the question at DELIVERY, where the answer is a MEASUREMENT instead
# of a guess: the paths the work actually touched. `task add`'s guess stays the
# provisional default; delivery either confirms it, downgrades it (nothing here
# a human round-trip can catch that CI does not) or upgrades it (a "docs" row
# that turned out to touch the scheduler).
#
# WHY THIS IS NOT THE done-time WAIVER DIVE-969 BANNED, which is the obvious
# objection: that ruling refuses a waiver the MAKER ASSERTS at peak
# completion-incentive (`task done --no-verify`). This asserts nothing. The input
# is the diff the work already produced — to be classified shallow you must have
# genuinely changed only tests/docs, and if you did, there is nothing for a
# grader to grade.
#
# THE ADD-TIME OPT-OUT IS RECORDED HERE, as of DIVE-2730, AND STILL LOSES TO THE
# UPGRADE — two claims, and the second is the load-bearing one. This comment once
# said the opt-out was "untouched"; main's review refuted it at source, because
# `--no-verify` was a local var in `task add` with no column behind it. It died
# with that process, so at `task done` a `--no-verify` row was INDISTINGUISHABLE
# from a DIVE-969 auto-skipped one — both read verifier NULL, verify_unavailable
# NULL. A decision and a default that produce the same stored state ARE the same
# state; no amount of downstream reasoning recovers the difference.
# `tasks.verify_optout` now stores it, so the override can be NAMED — which was
# the actual defect, the silence, not the override.
# The override itself is CORRECT and stays: the flag is declared at FILE time and
# the blast radius is measured at DELIVERY time, so honouring the flag here would
# let a sentence typed before the diff existed pre-authorise closing a scheduler
# or credentials change ungraded. That is a waiver in DIVE-969's banned direction,
# and it is the one way persisting this column could have turned a fix into a
# bypass. The filer opted out of ROUTINE grading, not of grading a diff they had
# not written yet.
# (`verify_unavailable=1` is the genuine self-handling case, by a different route:
# _task_default_verifier returns empty again in that org, so the upgrade cannot
# fire for want of a grader rather than for want of permission.)
#
# Print the changed paths of the delivery bound to task <id>, one per line.
# Empty output means UNKNOWN — no binding, no gh, no credential, no PR found —
# and unknown must stay unknown: every caller below treats it as "change
# nothing", so a missing credential can never widen OR narrow the rail.
_task_delivery_paths() {
  local _id="$1" _dref _body _branch="" _slug _tok _pr="" _n
  _dref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=${_id};")
  _body=$(db "SELECT COALESCE(body,'')         FROM tasks WHERE id=${_id};")
  [[ -n "$_dref" ]] || _branch=$(_push_branch_from_body "$_body")
  # No declared delivery at all -> return before spending a single gh call, so an
  # ordinary unbound close keeps its current latency exactly.
  [[ -n "$_dref" || -n "$_branch" ]] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  _tok=$(_gate_gh_token); [[ -n "$_tok" ]] || return 0
  _slug=$(_gate_task_repo_slug "$_dref" "$_body")
  if [[ "$_dref" =~ ^https?:// ]]; then
    _pr="$_dref"
  else
    # A bare `#N` delivery_ref is left to the merge gate's own DIVE-1955 refusal;
    # here it simply reads as unknown rather than being resolved against a guess.
    [[ -n "$_branch" && -n "$_slug" ]] || return 0
    _n=$(GH_TOKEN="$_tok" gh pr list --repo "$_slug" --head "$_branch" --state all \
           --json number -q '.[0].number' 2>/dev/null || echo "")
    [[ -n "$_n" ]] || return 0
    _pr="https://github.com/${_slug}/pull/${_n}"
  fi
  GH_TOKEN="$_tok" gh pr view "$_pr" --json files -q '.files[].path' 2>/dev/null || return 0
}

# Classify a path list (on stdin) as 'deep' | 'shallow' | '' (unknown/ordinary).
# PATH GLOBS ONLY — deliberately not a taxonomy (scope cap from the ticket: if
# this needs more than about ten entries the design is wrong).
#   deep    — any path in the blast radius where a human round-trip earns its
#             cost: the scheduler, the task store itself, credentials, deploy.
#   shallow — EVERY path is a test, a doc or a changelog fragment. CI is already
#             the gate for those; a verifier round adds latency and no signal.
#   ''      — anything else, and any empty list: current behaviour, unchanged.
# deep is checked first and wins outright, so a mixed set is never downgraded.
_task_delivery_depth() {
  local p have=0 all_shallow=1
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    have=1
    case "$p" in
      src/cmd_heartbeat.sh|src/cmd_task.sh|src/cmd_auth*|lib/db.sh|scripts/deploy*|\
      .github/workflows/*|install.sh|*credential*|*secret*|*token*)
        printf 'deep'; return 0 ;;
    esac
    case "$p" in
      tests/*|docs/*|changelog.d/*|*.md) ;;
      *) all_shallow=0 ;;
    esac
  done
  (( have )) || return 0
  (( all_shallow )) && printf 'shallow'
  return 0
}

# Boolean form, kept for readability at the call site.
_task_is_trivial() {
  [[ -n "$(_task_verify_skip_reason "$1" "$2" "$3")" ]]
}

# DIVE-2449: parse the narrow title shape that implies a numbered follow-up to
# an existing epic. This is deliberately NOT a generic DIVE-N mention parser:
# "follow-up to DIVE-2382" is ordinary prose, while "DIVE-2382 fix #3" carries
# the series coordinate that board readers otherwise mistake for a real parent
# link. Results are globals so callers can invoke this bare (rather than through
# a command substitution that would hide assignments).
_task_numbered_followup_parse() {
  local _title="${1^^}"
  local _re='(^|[^A-Z0-9])(DIVE-[0-9]+)[[:space:]]+(FIX|ORPHAN|PART|ITEM)[[:space:]]*#?([0-9]+)([^A-Z0-9]|$)'
  _TASK_FOLLOWUP_IDENT=""
  _TASK_FOLLOWUP_KIND=""
  _TASK_FOLLOWUP_NUMBER=""
  if [[ "$_title" =~ $_re ]]; then
    _TASK_FOLLOWUP_IDENT="${BASH_REMATCH[2]}"
    _TASK_FOLLOWUP_KIND="${BASH_REMATCH[3],,}"
    _TASK_FOLLOWUP_NUMBER="${BASH_REMATCH[4]}"
  fi
  return 0
}

# Inspect an unparented title and expose an advisory only when all of these are
# measured: the numbered-follow-up shape above, the cited ident exists, and no
# --parent was supplied by the caller. Open rows with the SAME coordinate are
# returned as a comma-separated ident list so the add output answers the
# existence question by text as well as warning that no graph edge was made.
# Empty/no-match is a normal result and always returns zero: an advisory must
# never make `task add` fail under set -e.
_task_unparented_followup_advisory() {
  local _title="$1" _target_ident _target_kind _target_number
  local _candidate_id _candidate_title _candidate_ident _matches=""
  _TASK_FOLLOWUP_WARN_IDENT=""
  _TASK_FOLLOWUP_WARN_KIND=""
  _TASK_FOLLOWUP_WARN_NUMBER=""
  _TASK_FOLLOWUP_WARN_MATCHES=""

  _task_numbered_followup_parse "$_title"
  _target_ident="$_TASK_FOLLOWUP_IDENT"
  _target_kind="$_TASK_FOLLOWUP_KIND"
  _target_number="$_TASK_FOLLOWUP_NUMBER"
  [[ -n "$_target_ident" ]] || return 0
  [[ "$(db "SELECT COUNT(*) FROM tasks WHERE upper(ident)=$(sqlq "$_target_ident");")" == "1" ]] || return 0

  while IFS= read -r _candidate_id; do
    [[ -n "$_candidate_id" ]] || continue
    _candidate_title=$(db "SELECT title FROM tasks WHERE id=${_candidate_id};")
    _task_numbered_followup_parse "$_candidate_title"
    if [[ "$_TASK_FOLLOWUP_IDENT" == "$_target_ident" \
       && "$_TASK_FOLLOWUP_KIND" == "$_target_kind" \
       && "$_TASK_FOLLOWUP_NUMBER" == "$_target_number" ]]; then
      _candidate_ident=$(db "SELECT ident FROM tasks WHERE id=${_candidate_id};")
      _matches+="${_matches:+,}${_candidate_ident}"
    fi
  done < <(db "SELECT id FROM tasks
               WHERE status NOT IN ('done','cancelled')
                 AND instr(upper(title), $(sqlq "$_target_ident")) > 0
               ORDER BY id;")

  _TASK_FOLLOWUP_WARN_IDENT="$_target_ident"
  _TASK_FOLLOWUP_WARN_KIND="$_target_kind"
  _TASK_FOLLOWUP_WARN_NUMBER="$_target_number"
  _TASK_FOLLOWUP_WARN_MATCHES="$_matches"
  return 0
}

# ---------------------------------------------------------------------------
# ── DIVE-2794 arm two: the per-LANE WIP cap ──────────────────────────────────
#
# Tokens cap what one row may SPEND; this caps how many rows a lane may HOLD.
# Same verb, same refusal path, same carve-out — one mechanism over two
# resources, because two independent refusals on `task add` would disagree,
# print different remedies, and teach the fleet that a failed add is noise.
#
# WHAT IS COUNTED: todo + in_progress only. Not blocked, not parked, not
# recurring templates. The fleet holds 55 blocked rows right now; a cap that
# counted them would be over on day one for every lane, with no satisfiable path
# back under — the unsatisfiable-gate shape we have shipped once and had to
# unwind. A blocked row consumes no attention, and attention is the resource.
#
# THE CAP IS FROZEN, NOT TRACKING. Initialised to the lane's own actionable count
# the first time the lane is seen, then it never moves except by a lead clear.
# A close lowers the COUNT, which is what creates headroom; it does NOT lower the
# cap. The first spec said every close lowers the cap, and that is a lock rather
# than a ratchet: after each close actionable == cap again, so the next add
# refuses forever and the lane drains to zero and stops working (caught in review
# before it was built). Frozen keeps every property that was actually wanted —
# close-one-to-file-one, no lane can grow, nobody defends a magic N.
_task_lane_actionable() {
  db "SELECT COUNT(*) FROM tasks
      WHERE assignee=$(sqlq "$1") AND kind='standard'
        AND status IN ('todo','in_progress') AND parked_at IS NULL;" 2>/dev/null || echo ""
}

# _task_wip_cap <lane> — READ ONLY. A lane with no INSTALLED cap is not capped,
# and the caller must treat a non-zero return as "no cap", never as zero.
#
# THE CAP IS INSTALLED, NEVER MINTED LAZILY, and the difference is the whole
# defect CI found. The spec says "initialise each lane's cap to its own
# actionable count AT INSTALL"; the first cut substituted "mint it the first time
# anyone looks", which is not the same thing and is strictly worse. Minting on
# first sight means the baseline is whatever the store happened to contain at
# that instant — so every harness that points FIVEDIVE_PROD_TASKS_DB at its own
# fixture (they do it deliberately, to exercise DIVE-2681) minted a cap from a
# half-built fixture and then refused the rest of its own setup. DIVE-2681's
# header already warns about exactly this: "a rig building a fixture is not a
# filing decision". A title-based cap survives it because fixture titles rarely
# classify; a COUNT-based cap cannot. Install is an explicit act
# (`5dive task wip-cap-install`), so a store nobody installed against is a store
# with no caps, which is the correct answer for every fixture and every fresh
# board.
_task_wip_cap() {
  local key="wip_cap:$1" cur
  cur=$(db "SELECT value FROM task_prefs WHERE key=$(sqlq "$key");" 2>/dev/null || echo "")
  [[ "$cur" =~ ^[0-9]+$ ]] || return 1
  # FLOOR OF 1, and this is the whole zero-lock defect rather than a rounding
  # nicety. A lane with no actionable rows mints cap 0, and `actionable >= cap`
  # is then 0 >= 0 — a breach — so an EMPTY lane could never accept its first
  # row. A brand-new agent would be frozen from birth, and any lane that
  # legitimately drained to empty would freeze permanently. That is the exact
  # drain-to-zero failure this arm's frozen cap was designed to avoid, let back
  # in through the INITIALISATION path instead of the update rule. Caught by CI
  # (gate_evidence_form_unit / audit_task_store_fence_unit both start from an
  # empty fixture lane), not by the arms I wrote — every one of those seeds rows
  # first, so none of them could see it.
  (( cur < 1 )) && cur=1
  printf '%s' "$cur"
}

# _task_lanes_with_headroom <exclude> — lanes strictly under their cap, for the
# redirect. Naming them is the whole point: "this lane is full" is a dead end,
# "this lane is full, dev2 and quinn have room" is a next action.
_task_lanes_with_headroom() {
  local skip="$1" lane cap act out=""
  while IFS= read -r lane; do
    [[ -n "$lane" && "$lane" != "$skip" ]] || continue
    cap=$(_task_wip_cap "$lane") || continue
    act=$(_task_lane_actionable "$lane")
    [[ "$act" =~ ^[0-9]+$ ]] || continue
    (( act < cap )) && out+="${out:+, }${lane} ($((cap - act)) free)"
  done < <(db "SELECT DISTINCT assignee FROM tasks WHERE assignee IS NOT NULL AND assignee!='' AND kind='standard';" 2>/dev/null)
  printf '%s' "$out"
}

# _task_lane_oldest <lane> <n> — the oldest actionable rows, so a refusal says
# what is actually holding the lane rather than only that it is held.
_task_lane_oldest() {
  db "SELECT '  · '||COALESCE(ident,'?')||'  '||substr(COALESCE(title,''),1,60)
      FROM tasks
      WHERE assignee=$(sqlq "$1") AND kind='standard'
        AND status IN ('todo','in_progress') AND parked_at IS NULL
      ORDER BY COALESCE(created_at,'') ASC LIMIT ${2:-3};" 2>/dev/null || echo ""
}

# THE FILING CAP (DIVE-2681). Two controls over one classifier.
#
# The measured problem: across the 508 rows filed in the 8 days to 2026-08-02,
# 54% concerned our own machinery and 5.5% touched anything a customer sees —
# roughly 10:1. The fleet audits itself because auditing is always available,
# and every internal row costs TWICE, because the DIVE-969 rail then books a
# grading pass against it. The rule has existed as a directive since 2026-08-02
# and did not hold: the agent that wrote it filed 55 rows the next day. A rule
# recalled BY TOPIC cannot fire at a MOMENT, and `task add` is the moment.
#
# So the cap lives here, at the keystroke, and not in anyone's instructions.
#
# THE CLASSIFIER IS A CANDIDATE SET, NEVER AN ACTION SET. A title-keyword scan
# cannot tell a harness row from a product row that happens to say "queue" —
# "Free OSS web UI: three views (org chart, queue, gates)" is a customer
# surface and matches on two words. So every consequence below is (a) announced
# in the output, never silent, and (b) one declared flag away from off:
#   --customer          this touches a customer surface; classifier was wrong
#   --already-blocked=  it IS internal, and it is the stated exception
# A false positive costs one flag. It never costs the row.
# A MISS IS NOT CHEAP — MEASURED 2026-08-09. The first cut of this scan was
# deliberately narrow on the reasoning that "a miss here is cheap and a false hit
# taxes someone's real work". Only the second half of that held. Over the 946
# hand-filed rows of the preceding 14 days the narrow set flagged **15%** where a
# read of the same titles says ~67% are our own machinery, so the gating window
# sat at 3/20 against a 5/20 threshold and the cap **never fired once**. The
# fleet filed 55 rows a day, two of every three about itself, for five days after
# the guard shipped and went live in 0.19.6.
#
# The narrow set failed for one structural reason: it keyed on MULTI-WORD phrases
# ("verifier rail", "merge gate", "task add") while the rows that actually get
# filed say the same things in one word — "gate" (102 occurrences in the missed
# set), "agent" (97), "task" (80), then verifier, guard, rail, council, probe,
# board. The vocabulary was right and the arity was wrong.
#
# So the set below is single-token where our machinery owns the token outright.
# Two words stay OUT on purpose because the product IS agent hosting and they
# cannot discriminate: **agent** and **queue**. Word boundaries do real work
# here — "dashboard" does not match `board`, "webhook" does not match `hook`,
# "latest" does not match `test`. Measured detection after widening: 45%, still
# under the ~67% human read, which is the safe direction for a refusal.
# Is the ACTIVE task store the production board? The filing cap is a rule about
# how many rows the fleet puts on the shared board, so a run against a fixture
# store has nothing for it to govern. Deliberately its own function rather than a
# call to _task_human_send_allowed: that one also refuses on FIVEDIVE_TEST and
# friends because SENDING to a human from a fixture is the risk it guards, and
# borrowing it here would couple a quota to a notification policy. Same store
# comparison (DIVE-1506), different question.
_task_filing_cap_store_is_prod() {
  local active prod ra rp
  active="${TASKS_DB:-${STATE_DIR:-/var/lib/5dive}/tasks/tasks.db}"
  prod="$(_task_prod_tasks_db)"
  ra="$(readlink -f "$active" 2>/dev/null || printf '%s' "$active")"
  rp="$(readlink -f "$prod" 2>/dev/null || printf '%s' "$prod")"
  [[ -n "$ra" && "$ra" == "$rp" ]]
}

_task_internal_subject_reason() {
  local t="${1,,}"
  # Our own machinery: the task engine, gates, verifier rails, CI, the release
  # cut, harnesses, the board, agent plumbing. Still a candidate set, never an
  # action set — see the two declared escapes above.
  [[ "$t" =~ (^|[^a-z])(harness|harnesses|smoke|full[-_ ]sweep|pipefail|shellcheck|actionlint|lint|verifier|verifiers|rail|rails|gate|gates|gating|task[[:space:]](add|done|need|ls)|taskboard|worktree|worktrees|heartbeat|release[-_ ]cut|version[-_ ]bump|changelog|pre[-_ ]push|hook|hooks|guard|guards|council|probe|probes|ci|nightly|budget[-_ ]report|backlog|board|cron|crontab|digest|recurring|maker|regression|flaky|unit|test|tests)([^a-z]|$) ]] \
    && { printf 'internal machinery'; return 0; }
  return 0
}

# DIVE-3245 — THE PER-FILER VOLUME CAP: how many low/medium rows this filer has
# created in the last ROLLING 24 HOURS.
#
# ROLLING, NOT CALENDAR, and that is the whole design (main, 2026-08-11). The
# thing being bound is a BURST, not a mean: one filer put 65 low/medium rows on
# the board in a day, and the fleet peaked at 163. A calendar-day cap lets a burst
# straddle midnight and clear itself, which is the shape that produced the damage.
#
# WHAT IS EXCLUDED, each for its own reason:
#   from_template_id  a recurring instance is MATERIALIZED by the scheduler, not
#                     filed by a person. Counting it fires the cap on a cadence
#                     nobody chose that day.
#   kind != standard  templates and their machinery are not filings.
#   priority          high/urgent never reach here (see the caller) — capping a
#                     serious finding is the failure direction lodar ruled out.
# NOT excluded: rows later cancelled or done. The cap is about INFLOW, and a row
# that was filed and then cancelled cost exactly what this exists to stop.
# <derived-filer> -> count. KEYED ON THE DERIVATION, NOT ON `created_by` (DIVE-3245
# it.2). `created_by` is the CLAIM when `--from` supplied one (the DIVE-2518 epoch),
# so counting it made the count agree with the stamp and disagree with reality: one
# fresh `--from` token started a fresh budget. `derived_actor` is measured from the
# uid and no argv can move it, so it is the only column a quota can honestly count.
#
# COALESCE, not a bare compare, for TWO populations and they are not the same one:
#   · rows filed before the `derived_actor` column existed — NULL, no derivation was
#     ever recorded, and `created_by` is the best evidence there is. Dropping them
#     would hand every filer an empty budget on the day this ships.
#   · rows a uid-less relay principal filed (`council`, `telegram`) carry BOTH, and
#     the derivation wins — those are charged to the seat that really ran the process,
#     which is the entity a quota is trying to bind.
# NULLIF because a written-but-empty string is not a recorded derivation.
# THE ONLY DOOR TO THE MATERIALIZATION EXEMPTION (DIVE-3245 it.3).
#
# The six in-process writers that turn ONE already-approved decision into N rows
# (cmd_goal x2, cmd_loop, cmd_loop_pack, cmd_objective, cmd_proof) call this
# instead of passing a flag. A cap firing halfway through leaves a HALF-materialized
# plan, which is strictly worse than an uncapped lane — that is why the exemption
# exists and it has not changed. What changed is who can stand in it.
#
# WHY THE CALL STACK AND NOT A FLAG OR AN ENV VAR. `--materialized` was an argv
# token with an unguarded parse, so any caller could assert membership: measured by
# quinn grading it.2, 20/20 low rows over a full budget. An env marker is the same
# defect one layer out — exportable, and invisible in the record. `FUNCNAME` is
# neither: it is the running shell's own call stack, propagated into `$(...)`
# substitutions, and no argv or environment can write it. Reaching it requires
# already executing inside this CLI's source, at which point the quota is not the
# weakest thing you can edit.
task_add_materialized() { cmd_task_add "$@"; }
_task_add_materialized_caller() {
  local f
  for f in "${FUNCNAME[@]}"; do
    [[ "$f" == "task_add_materialized" ]] && return 0
  done
  return 1
}

_task_filer_low_med_24h() { # <derived-filer> -> count
  local who="$1"
  [[ -n "$who" ]] || { printf '0'; return 0; }
  # LOOP SCAFFOLDING IS MATERIALIZATION, NOT FILING (quinn, grading it.1 — flagged
  # not blocking, fixed here because it is the row's own named failure: "counting
  # rows the filer did not create"). `task loop` INSERTs its run parent and every
  # step directly at priority medium, kind standard — so they never reach the cap's
  # own materialization exemption and a five-step loop silently spent a third of
  # its author's daily budget. One decision, N rows, same shape the WIP cap already
  # exempts by name.
  #
  # EVERY TERM OF THIS QUERY IS PART OF THE KEY — ASK WHO CAN ASSERT EACH ONE
  # (DIVE-3245 it.3, quinn's second reject). it.1's lesson was about the KEY: count
  # the derived actor, not the claim. That left the row SET, and it.2 spelled this
  # exclusion as `body NOT LIKE '%[[5dive-loop:%'` — `--body` is an ordinary
  # `task add` flag, so 25 low rows carrying the marker filed straight over a full
  # budget and the count read 0. An exemption is a bypass flag whenever the exempt
  # class is SELF-DECLARED. Clause by clause, as they stand now:
  #   derived_actor/created_by  MEASURED from the uid (it.1)
  #   priority                  a visible claim about severity, with a second reader
  #   kind                      no `task add` flag writes it
  #   from_template_id          written by the scheduler, unreachable from argv
  #   origin                    written by the INSERTING VERB, likewise unreachable
  # `origin` replaces the body marker for exactly that reason. `_LOOP_MARK` stays
  # the discriminator `task loop` itself QUERIES by — it is a fine way to find loop
  # rows, and an unsafe way to decide anything, because the caller writes it.
  db "SELECT COUNT(*) FROM tasks
       WHERE COALESCE(NULLIF(derived_actor,''), created_by)=$(sqlq "$who")
         AND kind='standard'
         AND priority IN ('low','medium')
         AND COALESCE(from_template_id,0)=0
         AND COALESCE(origin,'')=''
         AND created_at > datetime('now','-24 hours');" 2>/dev/null
}

# THE NUMBER, AND WHY IT IS THIS NUMBER. Derived from 30 days of the real board
# (low/medium, template-materialized and cli/system excluded), by asking how many
# rows each cap WOULD have refused:
#
#     cap   main  olivia  dev  dev3  everyone else
#      10    327     151   78     3              0
#      12    313     129   47     1              0
#      15    282      97   18     0              0     <- chosen
#      20    227      60    7     0              0
#
# 15 is the smallest cap at which NO filer outside the top three is ever touched.
# Below it the cap starts catching dev3, who is not the problem; above it the
# heavy filers keep more of the headroom that produced 245 cancelled rows out of
# 1092. The median filer's worst rolling-24h in that window is 4.5 and ten of
# fourteen filers never exceed 6, so this leaves the ordinary case untouched by
# more than 2x while binding all three runaway filers — including dev, which is
# the point: a cap its author is exempt from is a suggestion.
#
# NOT `${_TASK_FILING_DAILY_CAP:-15}`. An env-overridable cap IS the bypass flag
# this row forbids, just spelled differently and invisible in the record — and the
# population it exists to slow down is the population that would export it. It is
# a constant, and the harness trips it by seeding real rows rather than by
# lowering the bar, which also means the tests exercise the REAL threshold.
_TASK_FILING_DAILY_CAP=15

# How many of the last N standard rows read as internal machinery. Counted by
# running the SAME classifier over recent titles rather than storing a column —
# no schema change, and the count can never disagree with the rule that gates
# the next add. Prints "<internal> <total>".
_task_internal_recent_ratio() {
  local window="${1:-20}" n=0 hits=0 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    n=$((n + 1))
    # `if`, not `[[ ]] && ...`: as the LAST command in a loop body a false
    # `&&` list makes the body — and so the loop — exit 1, which `set -e`
    # takes as a failure. Same family as the defect this whole ticket exists
    # to stop generating.
    if [[ -n "$(_task_internal_subject_reason "$line")" ]]; then
      hits=$((hits + 1))
    fi
  done < <(db "SELECT REPLACE(title, char(10), ' ') FROM tasks WHERE kind='standard' ORDER BY id DESC LIMIT ${window};")
  # THE TRAILING NEWLINE IS LOAD-BEARING. `read` returns 1 when it hits EOF
  # without a delimiter, so a bare "%s %s" makes the CALLER's `read` fail, and
  # under src/header.sh's `set -euo pipefail` that killed `task add` outright
  # with no error path reached — the exact silent-death class of DIVE-2604.
  printf '%s %s\n' "$hits" "$n"
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
# DIVE-2719: the org's DESIGNATED GRADER — the agent whose own role/title says
# QA / testing / verification — excluding $1 (the maker). Same shape as
# _task_resolve_deputy (leading-space-anchored keyword scan, must be UNIQUE, >1
# is ambiguous and yields nothing), because it answers the same kind of question
# off the same table.
#
# It goes FIRST in the chain below, and that placement is the fix for a live
# directive violation, not a preference. lodar ruled 2026-08-04 07:51: "you
# should never be verifier yourself" / "why our ceo acts as ci tool". The remedy
# applied that morning MOVED 58 rows off main and cleared 6 more — it did not
# touch this picker, so by 21:1x six MORE rows created that same day had
# regenerated verifier=main. Correcting the output of a rule leaves the rule
# producing it. Every rung this function had walks UP the chart (lead,
# coordinator, manager, root, deputy), so a leader was structurally guaranteed to
# win; a chart that names a QA agent has already answered who should grade, and
# nobody had asked it.
#
# DIVE-2912: the UNIQUENESS rule above is defensible; its SILENCE was not, and
# the silence is what shipped a live routing change. Seating main2 with
# "verifier" in its TITLE made the count 2, so this function returned empty and
# the chain fell through to the next rung — which did not make main2 a candidate
# (main2 is nowhere in a dev-assigned row's chain), it made QUINN, the dedicated
# QA agent, stop being one. An unrelated agent's job title silently removed the
# QA rail from the picker for every row on the board, and nothing said so.
# Three changes, each aimed at that:
#   1. A DECLARED role outranks a descriptive title. Pass 1 scans `role` only;
#      only if that names nobody do we widen to role||title (pass 2), which is
#      what keeps an org whose QA agent is marked in the title alone working.
#      A clone's self-description can no longer outvote `role='QA / testing'`.
#   2. FIVE_VERIFY_EXCLUDE is honoured HERE too, not just in the chain below.
#      Excluding a name there used to leave it still counting toward the
#      ambiguity that suppressed the pick — the documented data lever could not
#      resolve the one thing it is shaped to resolve. Now it can.
#   3. A decline is LOUD. Genuine ambiguity warns and NAMES every match; the
#      rung is skipped either way, but the caller can now see that the QA rail
#      was skipped and why. Silence is kept for the one case that is not an
#      event: no QA agent matches at all, the ordinary shape for an org that
#      never named one, where warning would fire on every `task add`.
# Prints the grader name, or nothing.
_task_resolve_qa() {
  local _skip="$1" _pass _label _pred _n
  local -a _cands=()
  for _pass in role any; do
    if [[ "$_pass" == role ]]; then
      _pred="$(_task_qa_kw_clause "COALESCE(role,'')")"; _label='declared role'
    else
      _pred="$(_task_qa_kw_clause "COALESCE(role,'')||' '||COALESCE(title,'')")"; _label='role or title'
    fi
    _cands=()
    while IFS= read -r _n; do
      [[ -n "$_n" ]] || continue
      _task_verify_excluded "$_n" && continue
      _cands+=("$_n")
    done < <(db "SELECT name FROM agents_org WHERE ${_pred} AND name <> $(sqlq "$_skip") ORDER BY name;")
    case "${#_cands[@]}" in
      1) printf '%s' "${_cands[0]}"; return 0 ;;
      0) continue ;;   # nobody at this precision — widen, or fall out silently
      *) warn "verifier auto-pick: the QA rung was SKIPPED — ${#_cands[@]} agents match the QA scan by ${_label} (${_cands[*]}), so it cannot name one. The verifier falls through to the next rung (project lead, then up the chart). Disambiguate with FIVE_VERIFY_EXCLUDE=<name>, a narrower role/title, or set the verifier explicitly."
         return 1 ;;
    esac
  done
  return 1
}

# The QA keyword scan, over whichever SQL expression the caller passes, so the
# role-only and role||title passes cannot drift apart. Leading-space-anchored
# (so "QA" matches but "kanban" does not), same convention as
# _task_resolve_deputy.
_task_qa_kw_clause() {
  local _e="lower(' '||$1)"
  printf "( %s LIKE '%% qa%%' OR %s LIKE '%% test%%' OR %s LIKE '%% verif%%' OR %s LIKE '%% quality%%' )" \
    "$_e" "$_e" "$_e" "$_e"
}

# DIVE-2719: a NAMED EXCLUSION LIST, so the next such ruling is data rather than
# a code change. Comma/space separated agent names in FIVE_VERIFY_EXCLUDE are
# excluded from the default chain exactly the way the maker is — they can still
# be set explicitly with `--verifier=` / `task verifier`, which stays a deliberate
# human act. Empty by default: this ships INERT and changes no selection until an
# org sets it.
_task_verify_excluded() {
  local _n="$1" _e _list="${FIVE_VERIFY_EXCLUDE:-}"
  [[ -n "$_n" ]] || return 1
  for _e in ${_list//,/ }; do
    [[ "$_e" == "$_n" ]] && return 0
  done
  return 1
}

_task_default_verifier() {
  local _assignee="$1" _proj_lead="$2" c=""
  local -a cands=(
    "$(_task_resolve_qa "$_assignee")"
    "$_proj_lead"
    "$(_task_resolve_coordinator)"
    "$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$_assignee") LIMIT 1;")"
    "$(_task_resolve_org_root)"
    "$(_task_resolve_deputy "$_assignee")"
  )
  for c in "${cands[@]}"; do
    if [[ -n "$c" && "$c" != "$_assignee" ]] && ! _task_verify_excluded "$c"; then
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
#     by $EUID resolved against /etc/passwd in pure bash. DIVE-2330: this line used
#     to say `id -un` "which a process cannot spoof" — it could, because `id`
#     resolves through the CALLER'S PATH and a shim printing any name won.
# Prints one of: "agent <name>" | "human" | "none". Never reads --from ($from stays
# ATTRIBUTION-only) nor $USER (also env-spoofable). The determined root-sudo residual
# (an agent that truly sudo's then forges) is shared with the whole gate system and
# out of scope here — same boundary cmd_task_answer draws. _gate_is_root is a seam so
# the unit harness can exercise BOTH branches with the REAL resolver (not stubbed).
# _gate_is_root now lives in src/lib/actor.sh alongside the rest of the sealed
# derivation (DIVE-2517). Unchanged body, unchanged seam contract.
_gate_withdraw_actor() {
  if _gate_is_root; then
    local a; a=$(auto_sender_from_sudo)
    [[ -n "$a" ]] && { printf 'agent %s' "$a"; return; }
    _gate_sudo_uid_nonagent && { printf 'human'; return; }
    printf 'none'; return
  fi
  # DIVE-2330 iteration 2: route BOTH the uid and the passwd source through the seams.
  # This is the SAME defect dev found in the refusal guard, a second time in this
  # function: reading $EUID and /etc/passwd inline made the non-root branch resolve the
  # REAL runner, so gate_withdraw_unit's IDUN pin could not reach it and two arms graded
  # the runner's identity instead of the one under test. Semantics are unchanged —
  # _gate_caller_uid's whole body is `printf '%s' "$EUID"` and _gate_passwd_stream's is
  # /etc/passwd — which is exactly why routing through them widens nothing.
  local _cuid; _cuid=$(_gate_caller_uid)
  local _a; _a=$(_gate_uid_to_agent "$_cuid")
  if [[ -n "$_a" ]]; then printf 'agent %s' "$_a"; return; fi
  local _n _x _u; while IFS=: read -r _n _x _u _; do
    [[ "$_u" == "$_cuid" ]] && { printf 'human'; return; }
  done < <(_gate_passwd_stream)
  printf 'none'
}

# DIVE-980: shared org-chart assignee resolution. Resolve an assignee TOKEN to a
# concrete agent via the org chart (agents_org). Prints the resolved name, or
# NOTHING when a role/charter token has no UNIQUE holder — callers decide whether
# that empty is a hard error (task add) or a fall-through (goal validate).
# Deterministic + explainable: a role/charter routes ONLY on an unambiguous
# single match; >1 holder or unknown -> empty (never guess which one).
#   @name / bare name  -> taken as-is (explicit override; never re-routed)
#   role:<r>           -> the lone holder whose role/title CONTAINS <r> (ci, DIVE-2041)
#   charter:<kw>       -> the lone holder whose title (charter) contains <kw> (ci)
# Safe on an empty/missing org table (COUNT != 1 -> empty).
#
# DIVE-2041 — `role:<r>` WAS DEAD FOR EVERY AGENT ON EVERY CHART. It matched
# `lower(role) = lower(<r>)`, full-string equality, against a column whose every
# real value is human prose: "QA / testing", "Backend lane — OSS CLI, API, core
# council/constitution engine", "AI CEO — conducts the fleet (advisory)". So
# `role:QA` could not match quinn, and in practice NO role: token could match ANY
# agent. Same shape as the DIVE-2031 banner outage it was found next to: the
# lookup resolved to empty, the task simply landed unassigned, and an unassigned
# task is indistinguishable from ordinary behaviour — so nobody ever reported it.
#
# The predicate is the one already used by `_task_resolve_deputy` ~450 lines
# above: space-anchored substring over role||title, uniqueness-checked. Not a new
# mechanism — the sibling `charter:` token below has always done the substring
# thing correctly, against `title`. Exact equality is TRIED FIRST so a chart that
# does use terse role values keeps its existing, sharper resolution; the
# substring pass only runs when exact found no unique holder, so this can only
# turn empties into matches, never re-point an already-working token.
#
# `%` and `_` in the token are ESCAPED: they are LIKE wildcards, and an assignee
# token is caller input, so `role:%` would otherwise "match" whatever single row
# happened to exist and route work by accident.
_org_like_escape() { local s="${1//\\/\\\\}"; s="${s//%/\\%}"; printf '%s' "${s//_/\\_}"; }

_org_resolve_assignee() {
  local v="${1#@}"
  case "$v" in
    role:*)
      local r="${v#role:}"
      if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE role IS NOT NULL AND lower(role)=lower($(sqlq "$r"));" 2>/dev/null)" == "1" ]]; then
        db "SELECT name FROM agents_org WHERE role IS NOT NULL AND lower(role)=lower($(sqlq "$r")) LIMIT 1;"
        return
      fi
      local _rp="lower(' '||COALESCE(role,'')||' '||COALESCE(title,'')) LIKE '% '||lower($(sqlq "$(_org_like_escape "$r")"))||'%' ESCAPE '\'"
      [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE ${_rp};" 2>/dev/null)" == "1" ]] || { printf ''; return; }
      db "SELECT name FROM agents_org WHERE ${_rp} LIMIT 1;"
      ;;
    charter:*)
      local kw="${v#charter:}"
      local _cp="title IS NOT NULL AND lower(title) LIKE '%'||lower($(sqlq "$(_org_like_escape "$kw")"))||'%' ESCAPE '\'"
      [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE ${_cp};" 2>/dev/null)" == "1" ]] || { printf ''; return; }
      db "SELECT name FROM agents_org WHERE ${_cp} LIMIT 1;"
      ;;
    *)
      printf '%s' "$v"
      ;;
  esac
}

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
      # DIVE-2794 arm two used to be `--materialized`, an ARGV TOKEN, and DIVE-3245
      # it.3 removed it: the guard was `-z "$materialized"` and the flag was parsed
      # off argv unguarded, so 20/20 low rows filed over a full budget by asserting
      # membership in the exemption. The exemption is now DERIVED from the call
      # stack (see `task_add_materialized` and `_task_add_materialized_caller`), so
      # the token below is deliberately absent and reaches the `-*` arm as an
      # unknown flag. Do not re-add it: an exemption anything can assert is a
      # bypass flag with a different name.
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
  # THE MATERIALIZATION EXEMPTION IS DERIVED, NOT ASSERTED (DIVE-3245 it.3).
  # Nothing the caller supplies reaches this variable; it is true iff this call is
  # nested inside `task_add_materialized`, which only in-process CLI code can enter.
  _task_add_materialized_caller && materialized="1"
  local title="${words[*]:-}"
  [[ -n "$title" ]] || fail "$E_USAGE" "usage: 5dive task add <title...> [flags: 5dive task --help]"
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
    || fail "$E_VALIDATION" "--task-budget must be a token count (e.g. 50000), a dollar cost (e.g. \$1.50), or 'none' to exempt this row from the enforced default"
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
    resolve_task_id "$parent"; parent_sql="$RESOLVED_TASK_ID"
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
  if [[ -n "$assignee" ]]; then
    case "$assignee" in
      role:*|charter:*|@*)
        local _resolved; _resolved=$(_org_resolve_assignee "$assignee")
        [[ -n "$_resolved" ]] || fail "$E_NOT_FOUND" "--assignee='$assignee' has no unique holder in the org chart — name an agent, or fix the role: 5dive org set"
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
    # KEY ON THE DERIVATION, NOT THE CLAIM (DIVE-3245 it.2, quinn's reject).
    # `task_actor "$from"` returns the CLAIM whenever one is supplied, so this line
    # WAS the bypass flag the row's first failure condition forbids — spelled as an
    # argv token instead of a flag, which is worse, because nothing named it.
    # Reproduced at a9618e4 on a fixture declared prod, filer seeded to exactly the
    # cap: `--from=heavy` rc 3 refused, `--from=heavy-2` rc 0 FILED, and
    # `filing_volume_cap_trips` — the counter the ship note called "the evidence" —
    # stayed at zero while the cap was walked around.
    #
    # The convention was already written down and this was the site that needed it,
    # in tasks_db.sh beside `task_actor` itself: "Sites that DECIDE rather than
    # record call `task_actor \"\"` explicitly." Recording sites want the claim (a
    # uid-less principal like `council` can only ever be NAMED). A quota decides.
    # `created_by` is untouched at :1798 and still stamps the claim — only the count
    # key moves, so provenance keeps its vocabulary and the quota stops taking argv.
    local _vfiler; _vfiler=$(task_actor "") || _vfiler=""
    # `cli` is the unmeasurable-actor sentinel, not a person with a filing habit.
    # It is now DERIVED (root, a build bot, a uid absent from passwd) rather than
    # claimed, which closes the second half of the same hole: `--from=cli` used to
    # reach this skip and file freely.
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
    printf '%s' "$rows" | jq -c '{ok:true, data:{tasks:.}}'
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
  fi
}

cmd_task_show() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task show <id|DIVE-N>"
  resolve_task_id "$1"; local id="$RESOLVED_TASK_ID"
  if (( JSON_MODE )); then
    local task subs deps previous_gates
    task=$(dbfmt -json "SELECT * FROM tasks WHERE id=${id};")
    subs=$(dbfmt -json "SELECT id,ident,title,status FROM tasks WHERE parent_id=${id} ORDER BY id;")
    deps=$(dbfmt -json "SELECT t.id,t.ident,t.title,t.status FROM task_deps d JOIN tasks t ON t.id=d.blocked_by WHERE d.task_id=${id} ORDER BY t.id;")
    previous_gates=$(_gate_history_summary_json "$id")
    [[ -n "$subs" ]] || subs="[]"
    [[ -n "$deps" ]] || deps="[]"
    jq -cn --argjson t "$task" --argjson s "$subs" --argjson b "$deps" \
      --argjson g "$previous_gates" \
      '{ok:true, data:{task:($t[0]), subtasks:$s, blocked_by:$b, previous_gates:$g}}'
  else
    # DIVE-2316: delivery_ref is an enforcement input, so omission here made a
    # missing binding indistinguishable from a presenter that never read it.
    # Keep the field present in both states; "absent" is the observable value.
    # DIVE-3251: first_started_at sits next to started_at because the whole point
    # of the split is that a reader can tell "reclaimed after real work" from
    # "never started" FROM THE BOARD ALONE. A fix that records the first start but
    # does not surface it here does not satisfy that.
    dbfmt -line "SELECT ident, title, status, priority, assignee, created_by, parent_id, created_at, first_started_at, started_at, done_at, COALESCE(NULLIF(delivery_ref,''),'absent') AS delivery_ref, body, result FROM tasks WHERE id=${id};"
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

# DIVE-1935 (iteration 2): THE GATE ASSERTS ITS OWN INSTRUMENT.
#
# Iteration 1 was rejected for a reason that is about EVIDENCE, not about the arm it
# added: `_gate_gh_token`'s last arm was justified by "agents hold passwordless sudo
# on this host", which is a per-SEAT grant written as a HOST property. Census from
# `5dive agent list --json` at the time: root-all 7, cli-root 4, cli-scoped 5 — and a
# `cli-scoped` sudoers (`NOPASSWD: /usr/local/bin/5dive *`) cannot run `gh` as
# `claude` at all, so `sudo -n` is refused, `-n` makes that silent, `|| true` swallows
# it, and resolution returns EMPTY on 9 of 16 seats.
#
# THE DEFECT WAS UNFALSIFIABLE FROM THE CODE, which is why a fourth fallback would
# have inherited it: nothing the resolver does tells you WHICH arm declined, so an
# inert gate looks identical from the seat where it works and from the seat where it
# does not. Every arm below therefore leaves a CRUMB naming its own outcome, and the
# refusals/warnings downstream print the crumbs plus the seat they were taken on.
# `5dive task merge-gate-selftest` runs the same resolution deliberately and grades it
# against a known-merged PR, so the census above is reproducible by anyone on their own
# seat instead of being a one-off measurement by whoever happened to hold root.
#
# SUBSHELL, SO A FILE (the `_GATE_ANON_STATEF` idiom next door, same reason): every
# caller reads the resolver through `$(...)`, so a variable set inside it dies with the
# child. `$$` is the top-level pid even inside a command substitution, which is exactly
# the property needed to hand the crumbs back to the parent.
_GATE_TOK_TRACEF="${TMPDIR:-/tmp}/.5dive-gate-tok-trace.$$"

_gate_tok_note() { printf '%s\n' "$1" >>"$_GATE_TOK_TRACEF" 2>/dev/null || true; }

# _gate_seat — WHICH seat this ran on. The answer to "is the gate inert here?" is a
# property of the account, not of the host, and every diagnostic that omits it invites
# the same host-wide generalisation that produced this ticket.
_gate_seat() {
  printf '%s@%s uid=%s' "$(id -un 2>/dev/null || printf '?')" \
                        "$(hostname -s 2>/dev/null || printf '?')" \
                        "$(id -u 2>/dev/null || printf '?')"
}

# _gate_tok_why — the per-arm trace of the LAST resolution in this process, one line.
# Non-destructive (unlike `_gate_anon_why`): several sites may print it, and a second
# reader getting silence would reproduce this ticket's own failure shape.
_gate_tok_why() {
  local _t
  # awk, not `paste -sd'; '`: paste treats a multi-char -d as a CYCLE of single
  # delimiters, so it joins with ';' then ' ' alternately and the trace comes out
  # mis-punctuated. Caught by reading the live output, not by the syntax check.
  _t=$(awk '{printf "%s%s", (NR>1?"; ":""), $0}' "$_GATE_TOK_TRACEF" 2>/dev/null || printf '')
  [[ -n "$_t" ]] || { printf 'no token resolution ran in this process'; return 0; }
  printf 'seat %s: %s' "$(_gate_seat)" "$_t"
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
  : >"$_GATE_TOK_TRACEF" 2>/dev/null || true
  t="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$t" ]]; then
    _gate_tok_note "[1 env GH_TOKEN/GITHUB_TOKEN] RESOLVED"; printf '%s' "$t"; return 0
  fi
  _gate_tok_note "[1 env GH_TOKEN/GITHUB_TOKEN] absent"
  u="${SUDO_USER:-}"
  if [[ -n "$u" && "$u" != "root" ]] && command -v sudo >/dev/null 2>&1; then
    t=$(sudo -n -u "$u" gh auth token 2>/dev/null || true)
    if [[ -n "$t" ]]; then
      _gate_tok_note "[2 sudo -u $u gh auth token] RESOLVED"; printf '%s' "$t"; return 0
    fi
    _gate_tok_note "[2 sudo -u $u gh auth token] empty (invoker not gh-authed, or sudo refused)"
  else
    _gate_tok_note "[2 sudo -u \$SUDO_USER] skipped (no non-root SUDO_USER)"
  fi
  # Our own gh login, when we happen to be running as an authed user directly.
  # DIVE-1935: this MUST stay ahead of the `claude` fallback below — a caller's own
  # credential always wins over borrowing another account's.
  t=$(gh auth token 2>/dev/null || true)
  if [[ -n "$t" ]]; then
    _gate_tok_note "[3 own gh auth token] RESOLVED"; printf '%s' "$t"; return 0
  fi
  _gate_tok_note "[3 own gh auth token] empty (this account has no gh login)"
  # DIVE-1935: the `claude` fallback was gated on `id -un == root`, so it only ran
  # for root/sudo callers. Every agent-* account closes tasks as ITSELF (plain
  # `5dive task done`, no sudo) and none of them are gh-authed — so resolution
  # returned EMPTY for the entire fleet, and the fail-OPEN auto-detect gate below
  # was inert on every close it was written to police. Agents hold passwordless
  # sudo on this host, so try `claude` for non-root callers too; `sudo -n` keeps it
  # a silent no-op (never a password prompt) where that isn't true.
  # DIVE-1935 iteration 2: `sudo -n` is REFUSED (not merely empty) on a cli-scoped
  # seat, and the two outcomes have different remedies — "claude has no gh login"
  # is a host fault, "you may not run sudo as claude" is this seat's sudoers. `-n`
  # made both silent, so they were indistinguishable; separate them here.
  if command -v sudo >/dev/null 2>&1 && [[ "$(id -un 2>/dev/null)" != "claude" ]]; then
    # The classification reads sudo's OWN stderr rather than asking a second time
    # (`sudo -n -u claude true`). Deliberate: an extra probe changes the call
    # sequence three sibling harnesses assert on, and a diagnostic that alters the
    # thing it is diagnosing is worth less than the sentence it prints.
    local _e4; _e4="${TMPDIR:-/tmp}/.5dive-gate-sudo-err.$$"
    t=$(sudo -n -u claude gh auth token 2>"$_e4" || true)
    if [[ -n "$t" ]]; then
      rm -f "$_e4" 2>/dev/null || true
      _gate_tok_note "[4 sudo -u claude gh auth token] RESOLVED"; printf '%s' "$t"; return 0
    fi
    if grep -qiE 'password is required|not allowed to execute|may not run|no tty' "$_e4" 2>/dev/null; then
      _gate_tok_note "[4 sudo -u claude gh auth token] REFUSED by sudoers on this seat (scoped grant: no general sudo)"
    else
      _gate_tok_note "[4 sudo -u claude gh auth token] empty (sudo permitted; claude holds no gh login)"
    fi
    rm -f "$_e4" 2>/dev/null || true
  else
    _gate_tok_note "[4 sudo -u claude] skipped (no sudo, or already running as claude)"
  fi
  printf ''
}

# DIVE-2605: THE BOT RAIL — a second way to ASK GitHub, for callers who can never
# HOLD a token.
#
# Everything above resolves a token the caller may then use. For a standard-isolation
# builder that resolution is empty by construction, and DIVE-2318 already wrote down
# why: their sudoers is `ALL=(root) NOPASSWD: /usr/local/bin/5dive *`, which permits
# exactly one binary as root and nothing as `claude`, so the last-resort arm above
# ("sudo -n -u claude gh auth token") exits "a password is required". Measured again
# 2026-08-04 from agent-dev2's own uid, which is the only uid the answer is true of.
#
# DIVE-2318 made that refusal HONEST — it stopped rendering "no credential" as "not
# merged". This makes it RARE. The same builder that cannot borrow a token CAN run
# `sudo -n /usr/local/bin/5dive _gh_do`: it is that one permitted binary, and DIVE-2448
# already built it to read the machine account's PAT root-side and exec gh with it.
# Measured from agent-dev2: `_gh_do` returns `5dive-bot` for `api user` and answers
# `pr view 430 --repo 5dive-ai/5dive --json state,mergedAt` with real state. The rail
# the gate needs was already shipped; nothing routed the gate onto it.
#
# WHY THIS DOES NOT WEAKEN THE GATE. The rail is READ-ONLY here (`pr view`, `pr list`,
# `api` GETs) and `_gh_do` re-derives its own routing class as root, so a caller cannot
# talk it into a write. It is tried ONLY after every caller-credential arm comes back
# empty, so no close that resolves a token today changes path at all.
#
# WHY THE BOT AND NOT THE CALLER, when `5dive gh` routes reads the other way: that
# preference exists because the bot's visibility is NARROWER, so routing a read there
# could turn a working query into a 404. That trade needs a working caller credential
# to be a trade. Here there is none — the choice is the bot or no query — and a repo
# the bot cannot see still yields empty, which is the SAME unverified verdict the
# caller gets today. This arm can only ever add answers, never subtract one.
readonly _GATE_GH_DO=/usr/local/bin/5dive

# _gate_gh_bot_ok — 0 when THIS caller may route through the root-only `_gh_do`.
# Asks sudo, not the sudoers text: `sudo -n -l <cmd>` is 0 exactly when this account
# may run it, which is the property that matters and the one an admin's blanket
# `NOPASSWD: ALL` also satisfies. No network, no token, no side effect.
_gate_gh_bot_ok() {
  command -v sudo >/dev/null 2>&1 || return 1
  [[ -x "$_GATE_GH_DO" ]] || return 1
  sudo -n -l "$_GATE_GH_DO" _gh_do >/dev/null 2>&1
}

# _gate_gh_reachable <tok> — 0 when SOME way to ask GitHub exists. This is the
# predicate the refusals want; `[[ -z "$tok" ]]` was only ever a proxy for it, and
# it stopped being a correct one the moment a second rail existed.
_gate_gh_reachable() {
  [[ -n "${1:-}" ]] && return 0
  _gate_gh_bot_ok && return 0
  # DIVE-2770: a third way to ASK — see the anonymous rail below.
  _gate_anon_ok
}

# _gate_gh_credentialed <tok> — 0 when the caller HOLDS a rail of its OWN (a token,
# or the `_gh_do` grant), as opposed to only the anonymous one.
#
# DIVE-2770: `_gate_gh_reachable` is now true for a caller holding nothing, because
# the anon rail can answer for a PUBLIC repo. That is the fix — and it makes the two
# states downstream diverge. "A credential resolved and the query came back empty"
# and "there was never a credential, and the credential-free rail could not see this
# repo either" have DIFFERENT remedies, and a refusal that prints the first sentence
# for the second case is the exact DIVE-2318 defect this ticket inherited, one
# refusal further down: measured here on a private-repo close, which landed on
# `done-pr-state-unresolved` saying "a gh credential resolved" to a seat that has
# never held one. Reachability decides whether to ASK; this decides what an empty
# answer MEANS.
_gate_gh_credentialed() {
  [[ -n "${1:-}" ]] && return 0
  _gate_gh_bot_ok
}

# DIVE-2770: ONE refusal string, TWO sites. The EARLY site fires when no rail of any
# kind exists (no token, no bot grant, and no curl/jq to read anonymously with). The
# LATE site fires when the anonymous rail was the only one and it could not see this
# repo — a private repo, which is the ordinary case. Same epistemic state and the same
# remedy, so the same words, emitted from one place: two copies of a refusal this long
# drift, and then they disagree about which remedies a verifier seat can reach, which
# is the failure this ticket is about.
# DIVE-1935 (found by quinn, 2026-08-11): CLAUSE 1 OF THE DOCUMENTED EXIT WAS A
# TIP-EQUALITY TEST WEARING A MERGE TEST'S COSTUME, and it shipped in v0.19.20.
#
#     git ls-remote <repo-url> refs/heads/main | grep -q <merge-sha>
#
# `ls-remote <url> refs/heads/main` resolves ONE ref to its CURRENT VALUE, so that
# matches only while the merge sha IS STILL THE TIP of main. Main moves 20+ commits a
# day here, so the window in which the gate's own authorised exit works is about one
# commit wide — and outside it the script exits non-zero and reports NOT MERGED for a
# PR that merged. Failing CLOSED, on precisely the rows the exit exists to rescue, and
# handed to the caller as the thing to run. quinn measured it against the live ref and
# refused to run it.
#
# `git merge-base --is-ancestor <sha> origin/main` asks the question that was meant:
# is the merge REACHABLE from main, whenever it landed. CLAUSE 3 (`git grep` over
# origin/main for a symbol the PR added) is KEPT deliberately — it is the squash-proof
# half, and it still answers when the sha exists nowhere on main because the PR was
# squashed. The rewrite also drops a pipe that was never needed: `cmd | grep -q` under
# `set -o pipefail` returns 141 when grep exits early on a match, i.e. it can fail
# EXACTLY when it succeeds (community/wiki/grep-q-under-pipefail-turns-a-match-into-a
# -failed-check.md). Latent for a one-line producer like this, per quinn, and not the
# bug being fixed — but there is no reason to re-introduce the shape while rewriting
# the line.
_gate_refuse_no_rail() {
  local ident="$1" subject="$2"
  # DIVE-2770: name WHICH way the credential-free rail failed. Rate-limited clears
  # by itself; a private repo never will. One sentence, and it decides whether the
  # reader waits or reaches for `task verify`.
  local _why; _why="$(_gate_anon_why)"
  # DIVE-1935 iteration 2: name WHICH seat and WHICH arm, not just "no credential".
  # The generic sentence reads the same on a seat that is momentarily unauthed and on
  # one that structurally can never resolve, and that ambiguity is what let an inert
  # gate stay invisible for a fleet-wide census.
  local _tokwhy; _tokwhy="$(_gate_tok_why)"
  policy_refuse "$E_CONFLICT" done-merge-gate-no-credential DIVE-2318 "$ident" "$ident cannot close: the merge gate COULD NOT CHECK whether ${subject} landed — no gh credential resolved in this caller's environment, the machine-account rail is unreachable, AND the credential-free rail could not answer either (DIVE-2770: an unauthenticated read of a public repo). No query ran at all. ${_why} This says NOTHING about the merge; do not read it as 'not merged'. WHICH OF TWO CAUSES THIS IS decides what you should do, and the gate cannot tell them apart from here. (a) BY FAULT: a builder that should hold the \`_gh_do\` grant is missing it — a provisioning problem with a name. Check it with \`5dive gh whoami\`; if the bot line is UNRESOLVED and you are a builder, that is the thing to fix (\`agent create --can-push\`), or re-run with a token (\`GH_TOKEN=\$(sudo -u claude gh auth token) 5dive task done $ident ...\`). (b) BY DESIGN: on a VERIFIER seat an UNRESOLVED bot line is the CORRECT state — \`_gh_do\` is the can-push grant a grader must not hold, so no credential is coming, and handing the close to agent-main is not open to you either when the DIVE-477 writer-is-not-grader rail names YOU as the verifier of record. In case (b) the authorised terminal move is \`5dive task verify $ident --cmd=<script>\`, where the script'\''s EXIT STATUS proves the merge rather than asserting it — e.g. \`git fetch -q origin main && git merge-base --is-ancestor <merge-sha> origin/main && git grep -q <a-symbol-the-PR-added> origin/main -- <path>\`. That answers this gate'\''s question by another instrument instead of bypassing it, and it is squash-proof where a sha comparison is not. \`--force-merge-gate\` does NOT reach this refusal: it escapes a gate that RAN and disagreed, never one that asked nothing. Copy your verdict into the BODY before you close (\`task set-body --append\`) — \`task verify\` OVERWRITES result, and a closed body is frozen. \`task merge-audit --limit=1\` reports the same missing credential. WHERE IT ACTUALLY STOPPED (DIVE-1935) — ${_tokwhy}; machine-account rail: $(_gate_gh_bot_ok && printf 'available' || printf 'not permitted on this seat'). Re-run that resolution on its own, graded against a known-merged PR, with \`5dive task merge-gate-selftest\`."
}

# DIVE-2770: THE ANONYMOUS RAIL — the gate's own question has a credential-free
# answer, and demanding a credential for it deadlocked a MERGED row.
#
# ORIGIN, measured (DIVE-2449 / PR #483, squash 0396d920). The DIVE-477 rail
# requires a close come from the VERIFIER OF RECORD. That seat holds no gh
# credential BY DESIGN — `_gh_do` is the can-push grant a grader must not hold —
# so `_gate_gh_reachable` was false and the close refused. The one agent permitted
# to close could not see the evidence; the one who could see it was barred from
# closing. Neither was misconfigured. The two rails enclosed each other, and the
# refusal printed two remedies (`5dive gh whoami`, "hand it to agent-main") that
# the caller the rail requires cannot reach.
#
# THE DEFECT IS THE PREMISE, NOT THE PLUMBING. "Did pull/483 land?" is answerable
# ANONYMOUSLY on a public repo: `GET /repos/O/R/pulls/N` needs no token, and
# `git ls-remote` reads refs without one. The gate was asking a public question
# through a private door. This rail asks it through the public one, and it is
# tried LAST — after the caller's token and after the bot rail — so no close that
# resolves a credential today changes path at all. The rail can only ever ADD an
# answer where there was none.
#
# WHY THIS IS NOT A WIDENING, which is the objection to answer first. It grants
# nobody anything: an unauthenticated read of a public repo is available to the
# whole internet, and it is READ-ONLY by construction (a curl GET with no
# credential to escalate with). On a PRIVATE repo it 404s and the close lands on
# exactly the refusal it lands on today. This is the fix DIVE-2770 asked for in
# preference to granting verifier seats `_gh_do`, which would trade a bookkeeping
# problem for a security regression.
#
# SQUASH IS THE SECOND BUG WEARING THE FIRST ONE'S CLOTHES, and it lives in the
# reshape below rather than in a separate branch. REST reports a squash-merged PR
# as `state: "closed"`; gh's `--json state` reports `"MERGED"`. Copying `.state`
# across would render every merged PR as CLOSED and false-refuse
# `done-before-pr-merged` on precisely the population this rail exists to unblock.
# So gh's state is DERIVED from `.merged`, never copied — and `merged` is a fact a
# squash does not disturb, which is why this rail answers "did it land" for a
# squash merge where no sha comparison can.
_GATE_ANON_API="${FIVE_GATE_ANON_API:-https://api.github.com}"

# _gate_anon_ok — 0 when an unauthenticated GitHub read is even possible here.
# FIVE_GATE_NO_ANON=1 turns the rail off: harnesses that grade the no-rail
# refusal need the pre-DIVE-2770 world back, and so does any operator who wants
# it. It is an opt-OUT, not an opt-in — a fix nobody enables is not a fix.
_gate_anon_ok() {
  [[ "${FIVE_GATE_NO_ANON:-0}" == "1" ]] && return 1
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

# DIVE-2770: THE ANONYMOUS RAIL HAS A BUDGET, AND IT IS SHARED. Unauthenticated
# api.github.com is 60 requests/hour PER IP — not per agent, per IP — so the whole
# fleet on one box draws from one bucket, and the bucket is small enough to empty by
# hand (measured: exhausted during this ticket's own end-to-end run, with
# `x-ratelimit-remaining: 0`, and the rail correctly declined rather than guessing).
# Two consequences are designed for here rather than discovered later:
#
#   1. EXHAUSTION MUST NOT WEAR THE PRIVATE-REPO COSTUME. A 403-with-remaining-0 and
#      a 404 are both "the rail could not answer", and stopping there prints "this
#      repo is private" for a condition that clears by itself inside an hour. That is
#      the same defect this whole ticket is about — an unreached question rendered as
#      an answered one — so the code that cannot tell them apart is the code that has
#      to. `_gate_anon_why` is where the difference is spent.
#   2. SPEND LESS. The declared path asks for the SAME PR twice (once for `.state`,
#      once for `.mergedAt`) and `_gate_pr_shas` asks a third time. Memoising the
#      response for the life of the process turns three requests into one, which is
#      the difference between ~10 closes an hour and ~30 for the whole fleet.
# SUBSHELL, AND WHY THIS IS A FILE. Every gate call site reads `_gate_gh` through a
# command substitution — `_state=$(_gate_gh ... || echo "")` — so the rail runs in a
# CHILD shell and any variable it sets dies with that child. Measured here: a shell
# variable carrying the outcome read back EMPTY at the refusal, and an in-memory
# response cache never hit once because each call had its own copy. So the outcome
# crosses the boundary in a file, keyed by the top-level pid (`$$` is the parent's
# even inside `$( )`, which is exactly the property needed). The sibling
# `.5dive-gate-gh-err.$$` file next door is the same idiom for the same reason.
#
# An in-memory cache is deliberately NOT reinstated on top of this: it would be
# inert for the same reason, and an optimisation that a test asserts but that never
# fires is worse than no optimisation. The duplicate reads were removed at the CALL
# SITE instead (one `pr view` for state AND mergedAt), which spends less on every
# rail rather than only on this one.
_GATE_ANON_STATEF="${TMPDIR:-/tmp}/.5dive-anon-outcome.$$"

# _gate_anon_get <secs> <api-path> — ONE bounded, unauthenticated GET.
# stdout is the body; a NON-ZERO rc means the read did not happen. The outcome is
# recorded for `_gate_anon_why`: an absent answer is unresolved, never "no"
# (DIVE-2318, one rail further down), and the three ways it can be absent have three
# different remedies.
_gate_anon_get() {
  local secs="${1:-10}" path="${2#/}" code="" out="" reset="" _b _h
  [[ "$secs" == "0" ]] && secs=10
  _b="${TMPDIR:-/tmp}/.5dive-anon.$$.$BASHPID"; _h="${_b}.h"
  code=$(timeout "${secs}s" curl -sSL -o "$_b" -D "$_h" -w '%{http_code}' \
          -H 'Accept: application/vnd.github+json' \
          -H 'X-GitHub-Api-Version: 2022-11-28' \
          "${_GATE_ANON_API}/${path}" 2>/dev/null) || code=""
  out=$(cat "$_b" 2>/dev/null || printf '')
  if [[ "$code" == "403" || "$code" == "429" ]] \
     && grep -qi '^x-ratelimit-remaining:[[:space:]]*0' "$_h" 2>/dev/null; then
    reset=$(grep -i '^x-ratelimit-reset:' "$_h" 2>/dev/null | tr -dc '0-9' || printf '')
    printf 'ratelimit|%s' "$reset" >"$_GATE_ANON_STATEF" 2>/dev/null || true
  else
    printf '%s|' "${code:-network}" >"$_GATE_ANON_STATEF" 2>/dev/null || true
  fi
  rm -f "$_b" "$_h" 2>/dev/null || true
  [[ "$code" == 2* ]] || return 1
  printf '%s' "$out"
}

# _gate_anon_why — ONE clause naming why the anonymous rail could not answer, for a
# refusal to paste. Empty when the rail answered or was never tried: a refusal that
# explains a rail nobody used is noise, and noise is how a reader learns to skip the
# sentence that matters.
_gate_anon_why() {
  local _st="" _code="" _reset=""
  _st=$(cat "$_GATE_ANON_STATEF" 2>/dev/null || printf '')
  # Read once, then unlink: this is a per-invocation crumb in TMPDIR, and the only
  # reader is the refusal it was written for. A close that never refuses leaves one
  # ~12-byte file behind, which is the same shape as the `.5dive-gate-gh-err.$$`
  # sibling and is bounded at ONE per CLI invocation (fixed name, last write wins)
  # rather than one per request.
  rm -f "$_GATE_ANON_STATEF" 2>/dev/null || true
  _code="${_st%%|*}"; _reset="${_st#*|}"
  case "$_code" in
    ""|2*)     printf '' ;;
    ratelimit) local _w=""
               [[ -n "$_reset" ]] \
                 && _w=" (it refills at $(date -u -d "@${_reset}" '+%H:%M UTC' 2>/dev/null || printf 'the top of the hour'))"
               printf 'AND NOTE WHICH FAILURE THIS WAS: the credential-free rail is RATE-LIMITED, not blind — unauthenticated api.github.com allows 60 requests per hour PER IP, and this host shares one IP across every agent on it%s. That is TRANSIENT: re-run `task done` after it refills and the gate should answer without any credential.' "$_w" ;;
    404)       printf 'AND NOTE WHICH FAILURE THIS WAS: the credential-free rail got a 404, which for an unauthenticated read means the repo is PRIVATE (or the ref is gone). There is no anonymous read of it at all, so waiting will not clear this one.' ;;
    network)   printf 'AND NOTE WHICH FAILURE THIS WAS: the credential-free rail could not reach github.com at all — network or timeout, so retry is worth one attempt.' ;;
    *)         printf 'AND NOTE WHICH FAILURE THIS WAS: the credential-free rail was refused with HTTP %s.' "$_code" ;;
  esac
}

# The REST->gh reshape. Only the fields the gate actually asks for, so a shape it
# has never requested cannot be silently invented. `statusCheckRollup` is injected
# by the caller as $roll because it is a SECOND request — leaving the key absent
# would let the rollup filter render NONE ("no checks reported") for a question
# nobody asked, which is the succeeding-in-appearance shape DIVE-1935 is about.
readonly _GATE_ANON_PR_SHAPE='{
  state: (if (.merged // false) then "MERGED"
          elif ((.state // "") == "open") then "OPEN"
          else "CLOSED" end),
  mergedAt: .merged_at,
  title: (.title // ""),
  headRefName: (.head.ref // ""),
  headRefOid: (.head.sha // ""),
  mergeCommit: (if ((.merge_commit_sha // "") == "") then null
                else {oid: .merge_commit_sha} end),
  number: (.number // 0),
  url: (.html_url // "")
}'

# _gate_anon_rollup <secs> <slug> <sha> — the check state of one commit, as a
# gh-shaped statusCheckRollup array. Two GETs because GitHub keeps check-runs
# (Actions) and commit statuses (legacy/external) in different places and gh
# merges them; asking only one would report OK for a repo whose reds live in the
# other. Conclusions are upcased because the rollup filter matches "FAILURE",
# and REST spells it "failure".
_gate_anon_rollup() {
  local secs="${1:-10}" slug="$2" sha="$3" cr="" st=""
  [[ -n "$sha" ]] || { printf '[]'; return 1; }
  cr=$(_gate_anon_get "$secs" "repos/${slug}/commits/${sha}/check-runs" \
        | jq -c '[ (.check_runs // [])[]
                   | {name: (.name // ""),
                      conclusion: ((.conclusion // "") | ascii_upcase),
                      completedAt: (.completed_at // .started_at // "")} ]' 2>/dev/null) || cr=""
  st=$(_gate_anon_get "$secs" "repos/${slug}/commits/${sha}/status" \
        | jq -c '[ (.statuses // [])[]
                   | {context: (.context // ""),
                      state: ((.state // "") | ascii_upcase),
                      createdAt: (.created_at // "")} ]' 2>/dev/null) || st=""
  # Both unreachable is UNRESOLVED, not "no checks" — say so with the rc.
  if [[ -z "$cr" && -z "$st" ]]; then printf '[]'; return 1; fi
  jq -cn --argjson a "${cr:-[]}" --argjson b "${st:-[]}" '$a + $b' 2>/dev/null || { printf '[]'; return 1; }
}

# _gate_anon_gh <secs> <gh args...> — serve a READ-ONLY gh call over the anon rail.
#
# rc 0 with output = ANSWERED. rc 1 = this rail could not answer, for any reason:
# an unsupported query shape, a private repo, a network failure, OR a listing that
# matched nothing. That last one is deliberate and is the whole discipline of this
# function: the anon rail cannot see a fork-headed PR and does not paginate a long
# closed-PR list, so an empty listing here is a question that was not REACHED, and
# rendering it as "not merged" would reintroduce DIVE-2318 on a new rail. Only a
# POSITIVE finding is allowed to travel.
#
# Shapes served, and the omission is deliberate: `pr view` and `pr list --head
# --state merged` are the two ways the fail-CLOSED gate asks "did this land", and
# `api` passes through because those call sites are written against REST already.
# `pr list --state open` — the fail-OPEN auto-detect scan — is NOT served: it is a
# 200-row listing whose emptiness the scan reads as coverage, and an anon rail
# that pages differently would convert "I did not see it" into "there is none".
# That scan keeps reporting UNVERIFIED for a credential-less caller, exactly as
# it does today.
_gate_anon_gh() {
  local secs="${1:-10}"; shift
  _gate_anon_ok || return 1
  local -a a=("$@") pos=()
  local expr='.' repo="" json="" head="" pstate="" i=0
  while [[ $i -lt ${#a[@]} ]]; do
    case "${a[$i]}" in
      -q|--jq)  expr="${a[$((i+1))]:-.}";  i=$((i+2)) ;;
      -q*)      expr="${a[$i]#-q}";        i=$((i+1)) ;;
      --repo)   repo="${a[$((i+1))]:-}";   i=$((i+2)) ;;
      --json)   json="${a[$((i+1))]:-}";   i=$((i+2)) ;;
      --head)   head="${a[$((i+1))]:-}";   i=$((i+2)) ;;
      --state)  pstate="${a[$((i+1))]:-}"; i=$((i+2)) ;;
      --limit)  i=$((i+2)) ;;
      -*)       i=$((i+1)) ;;
      *)        pos+=("${a[$i]}");         i=$((i+1)) ;;
    esac
  done
  local _body="" _out="" _slug="" _num="" _roll="null" _sha=""
  case "${pos[0]:-}" in
    api)
      # REST in, REST out — these call sites already speak this schema.
      [[ -n "${pos[1]:-}" ]] || return 1
      _body=$(_gate_anon_get "$secs" "${pos[1]}") || return 1
      ;;
    pr)
      case "${pos[1]:-}" in
        view)
          local _ref="${pos[2]:-}"
          if [[ "$_ref" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
            _slug="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"; _num="${BASH_REMATCH[3]}"
          elif [[ "$_ref" =~ ^[0-9]+$ && -n "$repo" ]]; then
            _slug="$repo"; _num="$_ref"
          else
            return 1
          fi
          _body=$(_gate_anon_get "$secs" "repos/${_slug}/pulls/${_num}") || return 1
          ;;
        list)
          # Only the fail-CLOSED "did this branch land" listing. See the header.
          [[ -n "$repo" && -n "$head" && "$pstate" == "merged" ]] || return 1
          _slug="$repo"
          _body=$(_gate_anon_get "$secs" \
                    "repos/${_slug}/pulls?state=closed&per_page=100&head=${_slug%%/*}:${head}") || return 1
          _body=$(printf '%s' "$_body" | jq -c '[ .[] | select((.merged_at // null) != null) ]' 2>/dev/null) || return 1
          # Nothing matched is NOT REACHED, never "not merged" (see the header).
          [[ -n "$_body" && "$_body" != "[]" ]] || return 1
          ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  [[ -n "$_body" ]] || return 1
  if [[ "${pos[0]:-}" == "api" ]]; then
    _out=$(printf '%s' "$_body" | jq -r "($expr)" 2>/dev/null) || return 1
    [[ -n "$_out" ]] || return 1
    printf '%s' "$_out"
    return 0
  fi
  # A rollup is fetched only when the caller ASKED for one, and a rollup that
  # could not be read declines the whole call rather than answering "no checks".
  if [[ ",${json}," == *,statusCheckRollup,* ]]; then
    _sha=$(printf '%s' "$_body" | jq -r 'if type == "array" then (.[0].head.sha // "") else (.head.sha // "") end' 2>/dev/null) || _sha=""
    _roll=$(_gate_anon_rollup "$secs" "$_slug" "$_sha") || return 1
  fi
  if [[ "${pos[1]:-}" == "list" ]]; then
    _out=$(printf '%s' "$_body" \
            | jq -r --argjson roll "$_roll" \
                "[ .[] | ${_GATE_ANON_PR_SHAPE} + {statusCheckRollup: \$roll} ] | ($expr)" 2>/dev/null) || return 1
  else
    _out=$(printf '%s' "$_body" \
            | jq -r --argjson roll "$_roll" \
                "${_GATE_ANON_PR_SHAPE} + {statusCheckRollup: \$roll} | ($expr)" 2>/dev/null) || return 1
  fi
  [[ -n "$_out" ]] || return 1
  printf '%s' "$_out"
}

# _gate_gh <tok> <secs> <gh args...> — run ONE read-only gh call by whichever rail
# is available, printing gh's stdout and nothing else. Empty output keeps its
# existing meaning at every call site: COULD NOT RESOLVE, never "fine".
#
# <secs> is the call site's OWN wall-clock bound, carried in rather than fixed here:
# the sites do not agree (10s on the declared-ref probes, 5s on the fail-open
# autodetect scan, none at all on four others) and each number is load-bearing where
# it sits — the 5s one is what keeps a slow gh from stalling a close that is allowed
# to proceed. `0` means the site had no bound and keeps none on the token rail.
# The BOT rail is always bounded (10s when the site names nothing) because it spends
# a sudo round-trip on top of the network, and an unbounded new rail is a new way to
# hang a close.
#
# Args reach `_gh_do` NUL-separated over STDIN (never argv), the same posture
# `cmd_gh` uses: the jq filters below carry newlines and quotes, and the NOPASSWD
# grant stays an exact command path with no argument wildcard.
# DIVE-2705: the stderr of the most recent _gate_gh call, or empty. Read it to
# tell a DEAD call apart from a successful empty one — see the contract below.
_GATE_GH_LAST_ERR=""

# DIVE-2705 — THE CONTRACT, and why it needed both halves.
#
# This used to end `|| true; return 0` on BOTH rails, and swallow stderr on both.
# That left a failed call and a successful-but-empty one indistinguishable on
# EVERY channel at once: same empty stdout, same empty stderr, same exit 0. Most
# call sites are output-driven and were unharmed (DIVE-2318 reads `-z "$_state"`
# / `-z "$_attr"` and refuses as UNRESOLVED, which is why those paths were already
# honest). But the autodetect scan counts a repo as SCANNED on the exit status:
#   _hit=$(_gate_gh ...) && _sc_ok=$((_sc_ok+1)) || _hit=""
# so an unlistable repo incremented _sc_ok, _sc_ok==_sc_total set _scan_ran=1, and
# the whole DIVE-1935/1955 partial-repo-scan block — warn, audit row, UNVERIFIED
# stamp — never fired. Partial coverage was announced as a clean scan, which is
# the exact defect DIVE-1955 exists to delete, surviving one level down inside its
# own remedy.
#
# So: the status is now REAL, and stderr is CAPTURED rather than discarded. Empty
# stdout keeps its documented meaning (COULD NOT RESOLVE, never "fine"); the
# status says whether the call itself ran; _GATE_GH_LAST_ERR says why it did not.
# Stderr is captured rather than passed through on purpose — a repo this token
# cannot see is an ordinary, expected condition on a multi-repo close, and
# spraying gh's error text on every gate would be noise that trains readers to
# ignore it (the alarm-fatigue shape DIVE-2711 names).
_gate_gh() {
  local tok="${1:-}" secs="${2:-0}"; shift 2
  local -a bound=()
  local _rc=0 _errf
  _GATE_GH_LAST_ERR=""
  _errf="${TMPDIR:-/tmp}/.5dive-gate-gh-err.$$"
  if [[ -n "$tok" ]]; then
    [[ "$secs" != "0" ]] && bound=(timeout "${secs}s")
    GH_TOKEN="$tok" "${bound[@]}" gh "$@" 2>"$_errf" || _rc=$?
  else
    # No rail at all is NOT "the query ran and found nothing" — there was nothing
    # to run it with. Returning 0 here made an unusable bot rail count as a
    # completed scan, which is the same laundering as a failed listing.
    if ! _gate_gh_bot_ok; then
      # DIVE-2770: LAST rail, and only reached when the caller holds nothing.
      # An unauthenticated read of a public repo answers "did this land" without
      # any grant at all; on a private repo it declines and we fall through to
      # the same no-rail state as before.
      local _anon_out=""
      if _anon_out=$(_gate_anon_gh "$secs" "$@"); then
        _GATE_GH_LAST_ERR=""
        rm -f "$_errf" 2>/dev/null || true
        printf '%s' "$_anon_out"
        return 0
      fi
      _GATE_GH_LAST_ERR="no gh rail: no token, the gate bot is not usable here, and the anonymous rail could not answer (private repo, or a query it does not serve)"
      rm -f "$_errf" 2>/dev/null || true
      printf ''
      return 1
    fi
    [[ "$secs" == "0" ]] && secs=10
    printf '%s\0' "$@" | timeout "${secs}s" sudo -n "$_GATE_GH_DO" _gh_do 2>"$_errf" || _rc=$?
  fi
  [[ -s "$_errf" ]] && _GATE_GH_LAST_ERR="$(cat "$_errf" 2>/dev/null || printf '')"
  rm -f "$_errf" 2>/dev/null || true
  return "$_rc"
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

# DIVE-2577: every parser above this line only ever recognizes a PR — '#N', a pull
# URL, the word "PR". DIVE-2556 closed done with its OWN result stating "commit
# dc336f7 on branch dive-2556-maker-credit is UNPUSHED (dev3 has no push route)" —
# real, checkable evidence of unlanded work, and nothing upstream of this function
# could see it, because a branch was never a PR. The declared-binding gate (DIVE-1830,
# above in this file) already runs the ancestry+attribution scan for a `Branch:` line
# the maker BOUND; this teaches the mandatory auto-detect gate to run that same scan
# for a branch the maker's own TEXT names but never bound, so describing the branch
# in prose instead of `task set-branch`-ing it is not an escape from the gate.
#
# Anchored to the task's own ident (case-insensitive), followed by our house
# kebab-case branch convention — a candidate MUST carry "<ident>-" as a prefix, the
# same word-boundary discipline the PR-title/head-branch scan already applies. This
# is deliberately narrow: ordinary prose that happens to contain the word "branch"
# ("three branches of this problem") can never match, so closes with no code at all
# (research, decisions, coordination) are untouched — this is the DIVE-1690 shape
# named as itself, not a blanket PR-or-branch requirement.
#
# DIVE-3265 — A FILE IS NOT A BRANCH, AND THE ANCHOR ABOVE CANNOT TELL THEM APART.
# "<ident>-<kebab>" is also how we name the ARTIFACT a non-repo row delivers.
# DIVE-3264's deliverable is a design doc, `community/designs/dive-3264-svc-5dive-
# api-account-split.md`; that basename matched, and the gate then demanded a branch
# of that name land on main. No branch could exist: the deliverable is a file in a
# directory tree that is not a git repo at all. The row became UNCLOSEABLE BY
# CONSTRUCTION, and every obvious escape is shut — results are PRESERVED (DIVE-2483)
# so the offending text cannot be edited out of a later close, and `task set-branch
# <id> ''` is rejected ("invalid branch name") so a binding that was never set cannot
# be cleared. Scoped by CLASS, not by the instance (olivia, DIVE-3264): this fires
# for EVERY non-repo deliverable — design docs, wiki-only rows, anything landing
# under `community/` — so fixing the one filename would leave the next such row
# blocked identically.
#
# THE DISCRIMINATOR IS THE EXTENSION, and the DIRECTION OF THE BIAS is the whole
# argument for choosing it. The two errors are not symmetric:
#   a MISS      — a maker describes an unlanded branch and we do not catch it. Costs
#                 one unlanded branch, which the weekly hygiene digest (#139) still
#                 flags, and the DIVE-1830 declared-`Branch:` gate still catches the
#                 bound case. Recoverable.
#   a FALSE HIT — the row can never close, by construction, with no escape short of
#                 an audited `--force-merge-gate` on a row that has nothing to force.
# So this filter drops rather than guesses. It is a suffix test on the candidate,
# NOT a path test: a branch legitimately appears after a `/` in a forge URL
# (`.../tree/<branch>`), so rejecting path-shaped tokens would cost that shape for
# nothing the extension rule does not already buy.
#
# WHAT STAYS UNCOVERED, named so the next reader does not have to rediscover it: an
# extension-LESS artifact path (a delivered directory, `community/designs/dive-N-x/`)
# still reads as a branch. Unmeasured — every artifact in the measured population
# carries an extension — and a one-line follow-up if it ever bites.
_gate_branch_refs_from_text() {
  local text="$1" ident="$2"
  printf '%s\n' "$text" \
    | grep -ioE "(^|[^A-Za-z0-9])${ident}-[A-Za-z0-9][A-Za-z0-9_.-]*" 2>/dev/null \
    | sed -E 's/^[^A-Za-z0-9]//' \
    | grep -ivE '\.(md|mdx|markdown|txt|rst|patch|diff|json|ya?ml|toml|sh|bash|[jt]sx?|mjs|cjs|py|rb|go|rs|sql|log|csv|tsv|html?|pdf|png|jpe?g|gif|svg|webp|zip|gz|tgz|tar|lock|env|ini|conf|cfg)$' \
    | tr 'A-Z' 'a-z' | sort -u
}

# DIVE-1955: the repos the merge-gate knows about, one slug per line, CLI first.
# `_PUSH_DEFAULT_REPO` used to be the whole world: every bare `#N` resolved against
# 5dive-ai/5dive, so lodar/5dive-api (== prod) and lodar/5dive-frontend had ZERO
# coverage AND — worse — an api task naming "PR #6" got a CONFIDENT verdict about an
# unrelated CLI pull request. Overridable so a new repo is config, not a patch, and
# so the tests can point the whole gate at fixtures.
# DIVE-2431: the default was exactly those three, and a delivery to any OTHER repo we
# ship from was graded by a set that never contained it. Both directions were live and
# both were measured on DIVE-2303, whose delivery landed in 5dive-ai/character-packs:
#   FALSE ACCEPT  — the gate found the ident in 5dive-ai/5dive (step 1 of the same
#                   ticket, days earlier) and closed clean having never looked at
#                   character-packs. Correct by luck.
#   FALSE REFUSE  — strip that coincidence and genuinely-landed work is refused with
#                   "nothing on main in <3 slugs> shows branch ... landed", whose remedy
#                   is an audited `--force-merge-gate` override for a gate that was
#                   simply looking in the wrong place.
#
# WHY A LIST AND NOT A DERIVATION. Deriving the set from the git remotes on the box, or
# from the org's repo list, removes the drift but buys a worse property: the gate's
# verdict would then depend on host filesystem state or on network reachability at close
# time. A gate that answers differently on two boxes, or refuses when offline, is not a
# gate. The list is deterministic and auditable; drift is the price.
#
# WHAT PAYS FOR THE DRIFT: every verdict names the set it searched — the refusals always
# did, and DIVE-2431 added it to the ACCEPT, which was the silent half. A stale list now
# announces itself at the exact moment it matters, to the person it is failing. That is
# the property to preserve if this list is ever edited; adding a repo without it just
# moves the blind spot.
# ---------------------------------------------------------------------------
# DIVE-2414 — THE SUBJECT-STATE READER. ONE reader, pointed TWO directions.
#
# THE DEFECT IT REPLACES. "A gate whose task looks shipped retires with it" reads
# the ROW's own commit stream (`git log --grep=<ident>`, _hb_repo_grep_ident) and
# calls that evidence about the GATE. It is not. A row carrying a six-item program
# gets one commit for item #5 and reads as complete: DIVE-2382 was flagged
# "likely shipped, verify+close" while its live human gate asked about a
# completely different item. On a ticket that lands in pieces that nudge points
# the right way for the wrong reason and arrives with the authority of an
# automatic check. So the rule this file now enforces:
#
#   THE READER RESOLVES WHAT THE GATE IS ABOUT — the pull request it NAMES — and
#   NEVER inherits the row's commit stream as evidence. A gate that names NO
#   subject does not auto-retire; it stays open and SAYS so.
#
# TWO DIRECTIONS, ONE READER (olivia's scope, and it is a correctness argument,
# not just anti-duplication — built as two rows it repeats DIVE-2382's own defect):
#   (a) retire/flag a gate when the PR its ASK names has merged   — _gate_subject_verdict
#   (b) the DIVE-1830 merge-gate's cited-not-delivered gap, where a PR named in
#       prose is never read for its state AT ALL                 — _gate_cited_state_note
# Same blindness, opposite directions: one asks "is my subject resolved?", the
# other "what state is the thing you are citing actually in?".
#
# _gate_subject_refs_from_text <text> — of the refs this text names, which ones is
# it ASKING ABOUT? Emits the qualified `<slug>|<n>` subset, same shape as
# _gate_delivery_refs_from_text (DIVE-1965), and for the same reason: the subject
# must come from a STRUCTURED, INTENTIONAL signal, never from "a number appeared in
# the text". DIVE-2382's own ask is the pinned negative — it says "fix #5 is
# already in review as PR #335", a PR it is NOT about, and a mention-predicate
# would have retired a live approval on the strength of it.
#   Accepted: a `Subject:` / `Gate-subject:` / `Blocked-on:` line, or an
# ACTION-REQUEST verb adjacent to the ref (approve / merge / land / sign off) —
# the ask wants something DONE to that PR. Report verbs (review, shipped, cited)
# are deliberately NOT in the set: "in review as PR #335" is the exact shape that
# must miss, and "shipped as PR #N" describes a PR rather than asking about it.
# The asymmetry is deliberate and is the whole safety argument: reading a citation
# as the subject retires a live human question, reading the subject as a citation
# costs ONE nudge. Line-scoped, negations rejected, `tolower` for matching only so
# offsets still index the original line (a URL keeps its owner/repo case).
#
# THE VERB LIST IS A CLOSED VOCABULARY, AND THAT IS THE DESIGN, not an oversight
# left for the next person to finish (Marcus, verifying DIVE-2414). An ask phrased
# outside it — "can you OK PR #123" — yields NO subject, and a gate with no subject
# withholds the flag. That is the fail-closed direction and it costs a nudge.
# Widening the vocabulary is how the pinned negatives come back: E3 (DIVE-2382's
# "already in review as PR #335"), E4 (a bare mention) and E8 ("shipped as PR #N")
# in tests/gate_subject_state_unit.sh each pass only because some phrasing is
# OUTSIDE the set. If you add a verb, add it with the arm that proves the
# citations still miss — and note that the two halves are pinned by mutations the
# other survives: subject:=any-mention reds E3/E4/E5/E8, subject:=nothing reds
# E1/E2/E6/E7, a clean 4/4 partition with no overlap. Keep that property.
_gate_subject_refs_from_text() {
  printf '%s' "$1" | awk '
    BEGIN {
      RE   = "(https://github\\.com/[a-z0-9._-]+/[a-z0-9._-]+/pull/[0-9]+[a-z0-9]*)|((^|[^a-z0-9])(prs?|pull request)[[:space:]]*#?[[:space:]]*[0-9]+[a-z0-9]*)"
      VERB = "(approve|approves|approved|approval|merge|merges|merging|land|lands|landing|sign[- ]?off|signs[- ]?off|signed[- ]?off)"
      CONN = "([[:space:]]+(as|in|on|of|to|into|via|by|the|this|that|is|was|it))*"
      PRE  = "(^|[^a-z0-9])" VERB CONN "[^[:alnum:]]*$"
      NEG  = "(^|[^a-z0-9])(not|never|no|un|cannot|can[[:space:]]not|dont|do[[:space:]]not)[- ]?" VERB CONN "[^[:alnum:]]*$"
      POST = "^[[:space:]]*(is|was|needs|need)[[:space:]]+(your[[:space:]]+|a[[:space:]]+)?(approval|approving|sign[- ]?off|merging|merged|landing)"
    }
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
      sline = (low ~ /^[[:space:]]*(subject|gate-subject|gate subject|blocked-on|blocked on)[[:space:]]*:/)
      pos = 1
      while (match(substr(low, pos), RE)) {
        st = pos + RSTART - 1; ln = RLENGTH
        key = refkey(substr(line, st, ln))
        if (key != "") {
          pre = tolower(substr(line, 1, st - 1)); post = tolower(substr(line, st + ln))
          if (sline || (pre ~ PRE && pre !~ NEG) || post ~ POST)
            if (!seen[key]++) print key
        }
        pos = st + ln
      }
    }'
}

# _gate_ref_states <tok> <ident> <task_slug> — THE READER. Qualified refs on
# STDIN, one MEASURED state line per ref on stdout:
#
#   <number>|<STATE>|<where>     STATE ∈ MERGED | MERGED-RED | OPEN | CLOSED
#                                        | AMBIGUOUS | UNRESOLVED
#
# Every state comes from `gh pr view` on the ref ITSELF, through the DIVE-1955
# qualified resolver (a bare `#N` is looked up in the declared repo, or bound by
# ident evidence, or reported AMBIGUOUS — never guessed against a default slug).
# There is deliberately NO git call anywhere in this path: the moment this reader
# can reach the row's commit stream, the defect it exists to delete is back.
# MERGED-RED is kept DISTINCT from MERGED because "merged" is not the same claim
# as "landed and green" (DIVE-1935), and a caller retiring a human ask must not
# collapse them.
_gate_ref_states() {
  local tok="$1" ident="$2" task_slug="$3" qref st rslug
  while IFS= read -r qref; do
    [[ -n "$qref" ]] || continue
    st=$(_gate_resolve_qualified "$qref" "$tok" "$ident" "$task_slug")
    rslug="${st%%|*}"; st="${st#*|}"
    case "$rslug|$st" in
      AMBIGUOUS\|*)          printf '%s|AMBIGUOUS|%s\n' "${qref#*|}" "$st" ;;
      \|)                    printf '%s|UNRESOLVED|%s\n' "${qref#*|}" "$(_gate_search_scope "$qref" "$task_slug")" ;;
      *\|MERGED\|*\|FAILURE) printf '%s|MERGED-RED|%s\n' "${qref#*|}" "$rslug" ;;
      *\|MERGED\|*)          printf '%s|MERGED|%s\n' "${qref#*|}" "$rslug" ;;
      *\|OPEN\|*)            printf '%s|OPEN|%s\n' "${qref#*|}" "$rslug" ;;
      *)                     printf '%s|%s|%s\n' "${qref#*|}" "${st%%|*}" "$rslug" ;;
    esac
  done
}
_GATE_SUBJECT_CAP=5

# _gate_subject_verdict <ask-text> <tok> <ident> <task_slug> — DIRECTION (a).
# One line: `NO-SUBJECT` | `UNKNOWN|<why>` | `OPEN|<detail>` | `MERGED|<detail>`.
#
# Feed it the gate's own ASK and nothing else. NOT the row body: the body carries
# the whole program and every PR it cites, which is exactly how a row-level signal
# gets read as a gate-level one — the DIVE-2382 misread, one input earlier.
#
# Precedence, strictest first, because these are answers to "may this ask be
# retired without a human":
#   OPEN     — a subject is still open. Nothing else matters; the ask is live.
#   UNKNOWN  — a subject exists and its state could not be READ (no gh, no token,
#              dead parser, unresolvable, ambiguous, merged-but-red). A non-verdict
#              is not a negative (DIVE-2318) and must never read as "resolved".
#   MERGED   — every subject named resolved, and all of them merged green.
#   NO-SUBJECT — the ask names no pull request AT ALL. Not a failure: most gates
#              ask for a decision, not for a merge. Nothing can retire them
#              automatically and the caller has to say that out loud.
_gate_subject_verdict() {
  local text="$1" tok="$2" ident="$3" task_slug="$4"
  local refs n
  refs=$(_gate_subject_refs_from_text "$text")
  refs=$(printf '%s\n' "$refs" | grep . || true)
  [[ -n "$refs" ]] || { printf 'NO-SUBJECT'; return 0; }
  # A ref was named, so from here on silence is never an accept. An unrunnable
  # parser or a missing credential is UNKNOWN — the same distinction DIVE-1955
  # drew between "I looked and could not tell" and "there was nothing to look at".
  _gate_pr_refs_engine_ok || { printf 'UNKNOWN|ref-parser-broken'; return 0; }
  command -v gh >/dev/null 2>&1 || { printf 'UNKNOWN|gh-absent'; return 0; }
  [[ -n "$tok" ]] || { printf 'UNKNOWN|no-gh-token'; return 0; }
  n=$(printf '%s\n' "$refs" | grep -c .) || n=0
  local states open="" merged="" unk=""
  states=$(printf '%s\n' "$refs" | head -n "$_GATE_SUBJECT_CAP" | _gate_ref_states "$tok" "$ident" "$task_slug")
  local num st where
  while IFS='|' read -r num st where; do
    [[ -n "$num" ]] || continue
    case "$st" in
      OPEN)   open="${open:+$open, }#${num} in ${where}" ;;
      MERGED) merged="${merged:+$merged, }#${num} in ${where}" ;;
      *)      unk="${unk:+$unk; }#${num} ${st} (${where})" ;;
    esac
  done <<<"$states"
  (( n > _GATE_SUBJECT_CAP )) && unk="${unk:+$unk; }only the first ${_GATE_SUBJECT_CAP} of ${n} named refs were checked"
  [[ -n "$open" ]] && { printf 'OPEN|%s' "$open"; return 0; }
  [[ -n "$unk"  ]] && { printf 'UNKNOWN|%s' "$unk"; return 0; }
  [[ -n "$merged" ]] && { printf 'MERGED|%s' "$merged"; return 0; }
  printf 'UNKNOWN|no state read for any named subject'
}

# _gate_cited_state_note <qualified-refs> <tok> <ident> <task_slug> — DIRECTION (b).
# The DIVE-1830 merge-gate sets CITED refs aside and, until now, did not read them
# at all: "nothing binds them to this task, so their merge state was NOT checked".
# The set-aside is right — a cited PR is another task's delivery and must never
# gate this close (DIVE-1965 deleted that fleet-wide blocker on purpose). Reading
# it is a different act from judging it. DIVE-2382's own close cited PR #337 while
# it was OPEN and nothing said so; the same open PR then outlived the row that was
# its only tracker. This returns the MEASURED state as a note. It never refuses,
# never stamps UNVERIFIED, and never changes a verdict — it is disclosure only.
# Bounded to 3 (a close that cites ten PRs must not pay ten round-trips) and the
# cap is named in the note, because a silent cap reads as "all of them checked".
_gate_cited_state_note() {
  local qrefs="$1" tok="$2" ident="$3" task_slug="$4"
  local refs n out="" num st where
  refs=$(printf '%s\n' "$qrefs" | grep . || true)
  [[ -n "$refs" ]] || { printf 'no cited reference resolved to read'; return 0; }
  [[ -n "$tok" ]] || { printf 'state NOT read (no gh credential resolved)'; return 0; }
  n=$(printf '%s\n' "$refs" | grep -c .) || n=0
  while IFS='|' read -r num st where; do
    [[ -n "$num" ]] || continue
    out="${out:+$out; }#${num} ${st} in ${where}"
  done < <(printf '%s\n' "$refs" | head -n 3 | _gate_ref_states "$tok" "$ident" "$task_slug")
  [[ -n "$out" ]] || out="state NOT read"
  (( n > 3 )) && out="$out (first 3 of $n cited refs read)"
  printf '%s' "$out"
}

_gate_repo_slugs() {
  local raw="${FIVE_GATE_REPOS:-}"
  if [[ -z "$raw" ]]; then
    # The repos task deliveries actually land in. Kept to ACTIVE product repos rather
    # than every repo we own — an inactive repo costs a lookup on every close and has
    # never received a delivery.
    raw="$(_push_repo_slug "$_PUSH_DEFAULT_REPO") lodar/5dive-api lodar/5dive-frontend"
    raw="$raw 5dive-ai/character-packs 5dive-ai/skills 5dive-ai/5dive-plugins"
    raw="$raw 5dive-ai/5dive-mcp 5dive-ai/openagent 5dive-ai/ops"
    raw="$raw lodar/5dive-blog lodar/5dive-mobile"
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

# _gate_merged_not_deployed <accepting-repo-slug> — DIVE-2641 (split from DIVE-2621,
# item b+c). The sentence EVERY accepting arm of the merge gate appends to its own
# receipt.
#
# WHY HERE. Each accepting arm prints `done=merged-to-main satisfied`, which is TRUE,
# at the exact moment the reader assumes the STRONGER claim nobody checked: that the
# change is RUNNING. Four agents made that substitution independently on 2026-08-03
# (olivia DIVE-2587, dev DIVE-2571, dev3 on marketplace clones, main across the
# v0.18.3-v0.18.6 cuts). They were not careless — the system told them they were done.
# So the close gate is the cheapest place to interrupt it: same breath as the grade.
#
# THIS CHANGES NO ACCEPTANCE. It appends text to warns that already fire on paths that
# already passed; no arm refuses, no new failure mode exists, and every refusal is
# untouched. Merged-to-main is necessary and correctly verified — this only stops the
# SENTENCE AFTER the grade travelling further than the evidence.
# community/wiki/merged-to-main-is-a-claim-about-the-authors-artifact-not-the-readers.md
#
# ONE SHORT SENTENCE, deliberately. A paragraph gets skipped, and the entire value is
# that it is read at the instant of the inference.
#
# The DEPLOYED-ARTIFACT prompt (item c) is keyed off the repo the ACCEPTING EVIDENCE
# was found in — never off the task text, which is the maker's prose and describes what
# they meant rather than where it landed. Only repos whose artifact a reader EXECUTES
# get a prompt, and each names the surface that actually measures THAT artifact: the
# host CLI check cannot see a marketplace clone and vice versa, so naming one for the
# other would be a check that cannot answer the question it was cited for.
#
# WHICH IS WHY THE GENERIC HALF NAMES BARE `5dive doctor` AND NO CATEGORY. It said
# `--category=host` in the first cut, and that is only right for the host binary: on a
# marketplace row the FIRST surface the reader was handed was the one that reads
# /usr/local/bin/5dive and can say nothing about a clone in an agent's own $HOME. Bare
# `5dive doctor` runs every category (cmd_doctor.sh: an empty filter sets run_host=1 AND
# run_plugins=1), so it is true for every repo and the keyed half below narrows it.
# Caught by RENDERING the three shapes and reading them, not by any assertion — the two
# arms that now grade it (D5/D6) were written after the fact, which is the honest ordering.
_gate_merged_not_deployed() {
  local _slug="${1:-}"
  printf '%s' ' NOT ESTABLISHED by this: that the change is DEPLOYED — merged is a property of the repo, not of the artifact anyone is RUNNING, so check the installed side (`5dive doctor`) before you report this live (DIVE-2621/2641).'
  case "${_slug##*/}" in
    5dive|5dive-cli)
      printf ' DEPLOYED-ARTIFACT ROW: %s ships /usr/local/bin/5dive, which cron and every agent execute — a host still on the previous release runs the OLD code whatever main says; `5dive doctor --category=host` reports installed vs published (DIVE-2640).' "$_slug" ;;
    5dive-plugins)
      printf ' DEPLOYED-ARTIFACT ROW: %s ships the marketplace clone each agent runs out of its OWN $HOME, so freshness is per-agent and one refresh does not fix the fleet — `5dive doctor --category=plugins` reports it per clone (DIVE-2642).' "$_slug" ;;
  esac
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
  _gate_gh "$tok" 10 pr view "$n" --repo "$slug" \
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
  _gate_gh "$tok" 10 pr view "$ref" "${repo_arg[@]}" \
      --json state,mergedAt,statusCheckRollup \
      -q "[ .state, (.mergedAt // \"null\"), $_GATE_ROLLUP_JQ ] | join(\"|\")" \
      2>/dev/null || true
}

# DIVE-2296: _gate_branch_open_pr <slug> <branch> <tok> — is there an OPEN PR for
# this head, and where are its checks? Prints `N|CHECKS` (CHECKS as in
# _gate_pr_state: FAILURE / NONE / OK) or EMPTY for "no open PR found, or the
# query could not run".
#
# WHY THIS EXISTS AT ALL. The branch-path refusal below reports the SAME sentence
# for two states that demand opposite responses: no PR exists for this branch (go
# open one), and a PR exists and is sitting in an 18-minute CI run (wait). For a
# maker holding no gh credential that refusal is the ONLY window onto their own
# work, so the collapse does not merely under-inform, it manufactures round trips:
# measured on DIVE-2286, dev2 filed a gate asking main to open a PR that dev2 had
# opened fifteen minutes earlier, then two more asking for a merge that was
# waiting on checks. Three asks, all of them answerable by one read.
#
# This is DIAGNOSTIC ONLY and deliberately so: an OPEN PR accepts NOTHING here and
# must not — done=merged-to-main is the whole point of the DIVE-1830 gate, and a
# refusal that explains itself better is not a refusal that yields. It is called
# from the refusal arm only, never on an accepting path, so a close that passes
# pays nothing for it.
_gate_branch_open_pr() {
  local slug="$1" branch="$2" tok="$3" out rc=0
  out=$(_gate_gh "$tok" 10 pr list --repo "$slug" --head "$branch" --state open \
      --json number,statusCheckRollup \
      -q "[ (.[0].number // empty | tostring), ( .[0] // {} | $_GATE_ROLLUP_JQ ) ] | join(\"|\")" \
      2>/dev/null) || rc=$?
  # THREE ANSWERS, NOT TWO. A query that could not RUN — no rail, an invalid token,
  # a timeout, gh absent — must never render as "there is no open PR". That is the
  # DIVE-2318 defect exactly, and it is the one this ticket is downstream of: an
  # unreached question printed as a measured no. It has already bitten the sibling
  # surface (an invalid credential made `task done` refuse on a row whose merge WAS
  # on main, because the gate asked gh and not git), so it is guarded here at birth.
  #   Two independent signals, because either alone is incomplete: a non-zero rc,
  # and EMPTY output. The second matters because the no-PR case is not empty — jq
  # renders it as a bare rollup ("NONE"), so nothing at all means the payload was
  # never valid JSON, whatever the exit status said.
  if (( rc != 0 )) || [[ -z "$out" ]]; then printf 'UNREADABLE'; return 0; fi
  # A number is required before believing there is a PR: an absence that still
  # LOOKS like a value is the collapse this function exists to undo.
  [[ "$out" =~ ^[0-9]+\| ]] || out=""
  printf '%s' "$out"
}

# DIVE-2656 PART 2: _gate_graded_sha <text> — the sha a verifier STATES it graded.
#
# This is a FENCE, not a scrape. It matches only a labelled declaration —
# `graded-sha: <7-40 hex>` (also `graded sha`, `graded_sha`, `=` for `:`,
# any case) — and deliberately NOT a bare 40-hex string sitting in prose. A
# result routinely names shas it did not grade (the base it rebased onto, a
# squash sha it is citing, a sha in a quoted error), so "there is a hex blob in
# here" is a different claim from "this is what I graded" and only the second
# one may drive a refusal. Prose that forks the map is how this surface breaks;
# an explicit label is the whole reason the comparison downstream is safe.
#
# LAST occurrence wins: `--append-result` prepends the earlier close's text, so
# the most recent statement is the later one.
# Prints lowercase hex, or EMPTY when the result makes no such claim. Empty is
# "the verifier said nothing", never "it matched" — the caller must not read it
# as a pass.
_gate_graded_sha() {
  local txt="${1:-}" line sha=""
  while IFS= read -r line; do
    if [[ "$line" =~ [Gg][Rr][Aa][Dd][Ee][Dd][-_\ ][Ss][Hh][Aa][[:space:]]*[:=][[:space:]]*([0-9a-fA-F]{7,40}) ]]; then
      sha="${BASH_REMATCH[1]}"
    fi
  done <<<"$txt"
  printf '%s' "${sha,,}"
}

# DIVE-2835: _gate_version_claim <text> — the version a close STATES it verified on.
#
# Sibling of `_gate_graded_sha` above, and deliberately a LOOSER fence, for one
# reason worth stating because it looks like an inconsistency: THE TIGHTNESS OF A
# FENCE BELONGS TO THE CONSEQUENCE IT DRIVES. `graded-sha` drives a REFUSAL, so a
# false positive blocks a close and the fence must be a labelled declaration only.
# This one can never do more than WARN, so its false positive costs one line of
# output while its false NEGATIVE costs what DIVE-2762 cost: a result reading
# "VERIFIED ON v0.19.2" while this host ran 0.19.1, the board reading fixed for a
# full day, and the live defect eating maker text twice with a verifier signature
# on the row. A label-only fence (`verified-on:`) would be tidy and would have
# matched NOTHING in the incident that motivates this, because the claim was
# ordinary prose. A guard that cannot fire on its own founding case is decoration.
#
# So: a verification VERB and a full x.y.z version on the SAME line, verb first.
# Requiring all three parts is what keeps it from matching the versions a result
# routinely names without claiming to have verified against them — "fixed in
# v0.19.2, rollout tracked in DIVE-2816", a version in a quoted log line, a
# changelog citation. LAST occurrence wins, same as graded-sha: `--append-result`
# prepends the earlier close's text, so the later statement is the current one.
#
# Prints the bare version (no leading v), or EMPTY when the result makes no such
# claim. Empty is "nothing was claimed", never "it matched".
_gate_version_claim() {
  local txt="${1:-}" line ver=""
  # One regex, and the ORDER inside it is the fence: the verb, then a gap, then the
  # version. The gap class `[^0-9;,]*` is doing the real work and it is worth being
  # precise about why, because the obvious `[^0-9]*` is NOT enough: "verified the
  # retirement; separately, the box runs 0.19.1" has no digits between the verb and
  # the version, so a digit-only gap matches it and attributes a claim to a sentence
  # that never made one. Excluding `;` and `,` means the gap cannot cross into the
  # next clause, which is where an unrelated version lives. Measured both ways.
  # The pattern lives in a VARIABLE, not inline: an unquoted `;` inside `[[ =~ ]]`
  # terminates the command and bash reports a syntax error at parse time, so the
  # class that makes this fence work cannot be written inline at all.
  local _re='(VERIFIED|Verified|verified|TESTED|Tested|tested|CONFIRMED|Confirmed|confirmed|VALIDATED|Validated|validated|SMOKED|Smoked|smoked|REPRODUCED|Reproduced|reproduced)[^0-9;,]*[vV]?([0-9]+\.[0-9]+\.[0-9]+)'
  while IFS= read -r line; do
    [[ "$line" =~ $_re ]] && ver="${BASH_REMATCH[2]}"
  done <<<"$txt"
  printf '%s' "$ver"
}

# DIVE-2835: _gate_installed_cli — the DEPLOYED artifact, as `<path>|<version>`.
#
# The point of the whole check is that a version STRING is not evidence (DIVE-2819),
# so this resolves a FILE and asks that file what it reports, rather than trusting
# `$FIVE_VERSION` of whatever bundle happens to be executing — which on a maker's
# worktree is not what the control plane runs. `/usr/local/bin/5dive` first because
# that is the path cron and every agent execute (the same path
# `_gate_merged_not_deployed` names); `command -v` only as a fallback for a box that
# installed elsewhere. Empty means the artifact could not be read, which the caller
# must report as NOT CHECKED rather than as agreement.
_gate_installed_cli() {
  local p v
  for p in /usr/local/bin/5dive "$(command -v 5dive 2>/dev/null)"; do
    [[ -n "$p" && -f "$p" && -x "$p" ]] || continue
    v=$("$p" --version 2>/dev/null | head -1 | awk '{print $2}')
    [[ -n "$v" ]] || continue
    printf '%s|%s' "$p" "$v"; return 0
  done
  return 1
}

# DIVE-2835: _gate_version_vs_installed <ident> <verb> <result-text>
#
# Converts a discipline into machinery. DIVE-2762 closed "verified on v0.19.2" onto a
# host running 0.19.1; DIVE-2819's pass then turned on a human REMEMBERING to grep the
# installed artifact. This runs that comparison at the only moment the closer can act
# on it, and it always points at the FILE.
#
# WARN, never refuse, and that is not timidity: the guard cannot know WHICH artifact a
# version names. "verified on v2.1.0" may be a plugin, the api, or a dependency, and a
# refusal would be a confident claim about something this code did not identify. So it
# reports the comparison and names its own scope, which is the honest shape for a check
# whose subject is inferred rather than declared.
#
# Direction matters and is reported separately. Installed OLDER than claimed is the
# DIVE-2762 shape — the artifact carrying the fix is not the artifact running here, and
# the board is about to read fixed. Installed NEWER is ordinarily fine (it shipped, and
# more shipped after), so it gets a note rather than the loud line.
_gate_version_vs_installed() {
  local ident="${1:-}" verb="${2:-}" txt="${3:-}"
  local claimed; claimed=$(_gate_version_claim "$txt")
  [[ -n "$claimed" ]] || return 0
  local inst ipath iver
  if ! inst=$(_gate_installed_cli); then
    warn "$ident: this $verb states it verified on v$claimed, but the INSTALLED 5dive artifact could not be read (tried /usr/local/bin/5dive and \$PATH) — the deployed-vs-claimed comparison did NOT run (DIVE-2835). That is 'not checked', not 'agreed'."
    return 0
  fi
  ipath="${inst%%|*}"; iver="${inst##*|}"
  if [[ "$iver" == 0.0.0* || "$iver" == *-dev* ]]; then
    warn "$ident: this $verb states it verified on v$claimed; $ipath reports '$iver', a dev build whose ordering against a release is meaningless, so no comparison was made (DIVE-2835). Grep the artifact for the change itself — the version string was never the evidence."
    return 0
  fi
  if [[ "$iver" == "$claimed" ]]; then
    step "$ident: verified-on v$claimed matches the installed artifact ($ipath reports $iver) — the claim describes what this host actually runs (DIVE-2835)."
    return 0
  fi
  local older; older=$(printf '%s\n%s\n' "$claimed" "$iver" | sort -V | head -1)
  if [[ "$older" == "$iver" ]]; then
    warn "$ident: DEPLOYED-VS-CLAIMED MISMATCH — this $verb states it verified on v$claimed, but $ipath reports $iver, which is OLDER (DIVE-2835). The board is about to read this as fixed while the artifact every agent and cron actually executes does not carry it: that is exactly DIVE-2762, which stayed live for a day under a verifier's signature. Confirm against the FILE, not the version string — grep $ipath for the change — and if the rollout has not happened, this row is a rollout row, not a done one."
  else
    warn "$ident: this $verb states it verified on v$claimed; $ipath reports $iver, which is NEWER (DIVE-2835). Usually fine — it shipped and more shipped after — but the claim describes an artifact nobody is running now, so grep $ipath if the behaviour still matters."
  fi
}

# DIVE-2656 PART 1: _gate_pr_shas <ref> <tok> — the two shas a merged PR can be
# legitimately said to carry, as `<headRefOid>|<mergeCommit.oid>`.
#
# BOTH, on purpose. A verifier who graded the BRANCH states its head; one who
# graded the LANDED result states the merge commit. Accepting only the first
# would false-REFUSE the second, and a false refuse blocks every close while a
# false green closes one row wrongly (community/wiki/a-stored-graded-sha-cannot-
# survive-a-squash-merge.md). Note what is NOT asked here: ancestry. Under
# squash the branch head is never an ancestor of main, so ancestry against a
# stored sha false-REDs 100% of rows — this is an EQUALITY test between the sha
# the verifier named and the sha the PR actually carried, which squash does not
# touch. GitHub keeps headRefOid on a merged PR even after the branch is deleted.
#
# Prints EMPTY (or `|`) when the query could not be reached; the caller renders
# that as NOT CHECKED, never as a mismatch.
_gate_pr_shas() {
  local ref="$1" tok="$2" slug="${3:-}"
  local -a repo_arg=()
  [[ "$ref" =~ ^[0-9]+$ ]] && repo_arg=(--repo "$slug")
  _gate_gh "$tok" 10 pr view "$ref" "${repo_arg[@]}" \
      --json headRefOid,mergeCommit \
      -q '[(.headRefOid // ""), (.mergeCommit.oid // "")] | join("|")' \
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
  out=$(_gate_gh "$tok" 10 api \
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
  # DIVE-1935, 2026-08-11: default raised 50 -> 250 ON FRICTION GROUNDS ONLY, and the
  # distinction is the whole reason this comment exists. THERE ARE ZERO STUCK ROWS:
  # of 37 rows refused in 24h, 30 closed and 5 were cancelled. Nobody should read this
  # as unblocking a backlog and go looking for movement in a number that was never
  # moving.
  #
  # What it buys is RETRIES. The refusal is inconclusive-by-construction — it walks the
  # bound per repo across 8 repos and gives up — so a caller below the bound pays for it
  # in attempts, not in a permanent block: DIVE-2093 burned 2, and quinn's DIVE-3184,
  # DIVE-3229 and DIVE-3230 burned 3 each. On a day where main takes 20+ commits, 50 is
  # simply too short to answer the question the scan was asked.
  #
  # `FIVE_GATE_ANCESTRY_SCAN` stays as the override, and stays deliberately: the bound
  # exists so the walk terminates, and a raised default is not a reason to remove the
  # knob that makes it tunable in either direction.
  n="${FIVE_GATE_ANCESTRY_SCAN:-250}"
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || n=250
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
    out=$(_gate_gh "$tok" 10 api \
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
          "$ident is DELIVERED to verifier '${_vfier}' (iteration ${_iter}, maker '${_maker}') and has NOT been graded — a 'task done' from '${_actor}' would close it ungraded, which is the maker grading its own work (writer != grader, DIVE-477). Only '${_vfier}' can close it. To CORRECT the result text do NOT re-run done: send the correction to '${_vfier}' (5dive agent send ${_vfier} \"...\") and let them fold it in. Real exits: '5dive task reject $ident --feedback=...' (verifier bounces it back), '5dive task verify $ident --cmd=\"<acceptance test>\"' (evidence-backed close), or '5dive task cancel $ident --result=...' (abandon)."
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
      local _cg_filer; _cg_filer=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''), assignee, '') FROM tasks WHERE id=${id};")
      policy_refuse "$E_CONFLICT" cancel-over-open-gate DIVE-2773 "$ident" \
        "$ident has a PENDING '${_gt}' gate (filed by '${_cg_filer:-unknown}') and a cancel deletes the question, silently retiring the human's buttons — withdraw it first: 5dive task need $ident --withdraw"
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
    if [[ -n "$_dref" || -n "$_branch" ]]; then
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
          policy_refuse "$E_CONFLICT" done-before-pr-merged DIVE-1830 "$ident" "$ident cannot close: $_dref is not merged to main (state=$_state, measured) — merge it, then task done"
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
    [[ -n "$_open_gate" ]] && { _task_gate_retire_buttons "$ident" "task ${verb} with the gate still open" || true; }
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
  # OSS-37: the definition moved to _task_stuck_loop_pred (lib/tasks_db.sh) when the
  # objective planner became its second caller. Held here as a local it could only be
  # reused by re-typing, and two copies that agree today is the thing DIVE-1963 named.
  local stuck_pred; stuck_pred="$(_task_stuck_loop_pred)"
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
  # origin='task-loop' (DIVE-3245 it.3): scaffolding, not a filing. Written HERE,
  # by the verb that materialises it, because that is the one fact `task add`
  # cannot state about itself — the filing cap's exclusion keys on this column
  # rather than on the `_LOOP_MARK` in the body, which any `--body` can carry.
  run=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, project_key, kind, origin)
            VALUES ($(sqlq "$title"), $(sqlq "$run_body"), 'medium',
                    $(sqlq_or_null "$owner"), $(sqlq "$creator"), $(sqlq "${project,,}"), 'standard', 'task-loop');
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
    sid=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, parent_id, project_key, kind, origin)
              VALUES ($(sqlq "$label"), $(sqlq "$sbody"), 'medium',
                      $(sqlq_or_null "$sassignee"), $(sqlq "$creator"), ${run}, $(sqlq "${project,,}"), 'standard', 'task-loop');
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
  local task="" cmd="" no_done=0 timeout_s="" prose="" have_prose=0 prose_src=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cmd=*)      cmd="${1#*=}" ;;
      --no-done|--check) no_done=1 ;;
      # DIVE-2832: the verifier's own words. Every other writer of this column is
      # either the MAKER's verb (deliver) or machine output, so a verifier who
      # graded by READING had no way to put a prose PASS on an OPEN row at all.
      --result=*)   _prose_flag_dupe --result "$prose_src"
                    prose="${1#*=}"; have_prose=1; prose_src="--result" ;;
      # DIVE-3018: same file sibling as `task done` / `task deliver`. A verifier's
      # verdict is the LONGEST prose any of these verbs takes, so this is the one
      # most exposed to the quoting trap the argv form carries.
      --result-file=*) _prose_flag_dupe --result-file "$prose_src"
                    _read_prose_file --result-file "${1#*=}"
                    prose="$_PROSE_FILE_VALUE"; have_prose=1; prose_src="--result-file" ;;
      --timeout=*)  timeout_s="${1#*=}" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] \
    || fail "$E_USAGE" "usage: 5dive task verify <id|DIVE-N> [--cmd=\"<command>\"] [--result=\"<prose verdict>\"|--result-file=<path>] [--no-done] [--timeout=<seconds>]"
  [[ -z "$timeout_s" || "$timeout_s" =~ ^[1-9][0-9]*$ ]] \
    || fail "$E_VALIDATION" "--timeout must be a positive integer (seconds)"
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # DIVE-2832: --result is a RECORDING path, never a closing one. A prose verdict is
  # an assertion about work; it is not evidence that anything reached main, and the
  # DIVE-1830 merge gate this verb already bypasses (DIVE-2938) is exactly what would
  # otherwise be riding on it. So --result requires --no-done and says so.
  if (( have_prose )) && (( ! no_done )); then
    fail "$E_USAGE" "--result records a verifier's prose verdict WITHOUT closing, so it requires --no-done (alias --check). A prose PASS asserts the work is good; it is not evidence the work MERGED, and \`task verify\`'s close does not run the DIVE-1830 merge gate (DIVE-2938). To record the grade: 5dive task verify $task --no-done --result=\"<verdict>\". To close on evidence, pass a --cmd whose EXIT STATUS proves what you are claiming."
  fi
  if (( have_prose )) && [[ -z "${prose//[[:space:]]/}" ]]; then
    fail "$E_VALIDATION" "--result was given an EMPTY value. A zero-length verdict is indistinguishable from one that was never written (DIVE-2483), so it is refused rather than stored."
  fi
  # DIVE-476: --cmd is now optional — when omitted, fall back to the task's stored
  # verify_command (the declarative loop spec). Persisted input, no re-passing.
  #
  # DIVE-2832: and with --result there may be NO command at all, which is the whole
  # point. The row's receipts were graded by READING a diff, and this fail() was the
  # reason the "record without flipping" flag could not reach them: it demanded a
  # runnable acceptance test, so the only way in was to contrive one — manufacturing
  # a green to satisfy a gate, which is the anti-pattern the row exists to name.
  local ran_cmd=1
  if [[ -z "$cmd" ]]; then
    cmd=$(db "SELECT COALESCE(verify_command,'') FROM tasks WHERE id=${id};")
    if [[ -z "$cmd" ]]; then
      (( have_prose )) \
        || fail "$E_USAGE" "no --cmd given and task has no stored verify_command (set one: 5dive task add … --verify=\"<cmd>\"). If you graded by READING rather than by running something, record it as prose instead: 5dive task verify $task --no-done --result=\"<your verdict>\" (DIVE-2832)."
      ran_cmd=0
    fi
  fi

  # Run it. Combined stdout+stderr. The `if` wrapper captures the exit code
  # WITHOUT tripping `set -e` (a failing $() in a bare assignment would abort).
  local out rc
  if (( ! ran_cmd )); then
    out=""; rc=0
  elif [[ -n "$timeout_s" ]]; then
    if out=$(timeout "${timeout_s}" bash -c "$cmd" 2>&1); then rc=0; else rc=$?; fi
    (( rc == 124 )) && out="${out}"$'\n'"[timed out after ${timeout_s}s]"
  else
    if out=$(bash -c "$cmd" 2>&1); then rc=0; else rc=$?; fi
  fi
  # Tail the output so a chatty command can't bloat the result row.
  local tail_out; tail_out=$(printf '%s\n' "$out" | tail -n 25)

  local verdict result_txt
  # DIVE-2832: with a prose verdict and no command, the record must not LOOK like a
  # machine verdict. The whole value of the existing text is that "exit 0" is a fact
  # a reader can re-derive; a grader's assertion is not, and rendering them the same
  # way would buy the recording path at the cost of the one property that made the
  # machine path trustworthy. So the prose is labelled as UNEXECUTED and attributed.
  if (( have_prose )) && (( ! ran_cmd )); then
    verdict="pass"
    result_txt="✅ verify PASS (verifier's prose grade — NO command was run, DIVE-2832): recorded by $(task_actor "")"$'\n'"${prose}"
  elif (( rc == 0 )); then
    verdict="pass"
    result_txt="✅ verify PASS (exit 0): ${cmd}"$'\n'"--- output tail ---"$'\n'"${tail_out}"
    # Both given: the command's evidence AND the grader's words, prose first, because
    # the prose is the part a human wrote and the tail is the part they were reading.
    (( have_prose )) && result_txt="${prose}"$'\n'"--- evidence ---"$'\n'"${result_txt}"
  else
    verdict="fail"
    result_txt="❌ verify FAIL (exit ${rc}): ${cmd}"$'\n'"--- output tail ---"$'\n'"${tail_out}"
  fi

  # DIVE-2483: `task verify` is the THIRD writer of this column and the only one
  # that reached the OPEN cell completely unguarded. DIVE-2067 added preservation
  # here, but inside `if [[ "$_v_st" == 'done' ]]` — so every not-done write below
  # (the pending-gate refusal, the auth-failure exit, the done-flip, and the FAIL
  # branch) put result_txt straight over whatever was there.
  #
  # A DELIVERED row is not done, which is what makes this live rather than
  # theoretical: it is the cell a maker→verifier loop is in for its whole life.
  # Measured on DIVE-2624 — dev's maker-delivery record was replaced by
  # "✅ verify PASS (exit 0): bash /tmp/.../prove_2624.sh" and was gone from the
  # board. That path is not an accident either: the DIVE-2318 merge-gate refuses a
  # `task done` with no gh credential and suggests handing the close to an agent
  # that holds one, DIVE-477 forbids that, and the refusal at :2707 then NAMES
  # `task verify --cmd=` among its exits — so a no-gh verifier is ROUTED here by
  # construction. The verb that a whole class of agents is funnelled into is the
  # last one that should be the unguarded one.
  #
  # Deliberately scoped to the NOT-done cell: the closed cell already has
  # DIVE-2067's own refusal and its "superseded result (DIVE-2067, preserved)"
  # append below, and running both would append twice. This is keyed on status at
  # the CALL SITE — which is fine and is not the defect this ticket is about — to
  # avoid two preservation mechanisms overlapping on one write.
  # DIVE-2835: run the deployed-vs-claimed comparison on THIS close's own text,
  # deliberately before the guard below prepends the prior result. After that
  # prepend the cell also carries the MAKER's words, and warning "this verify
  # states it verified on vX" about a sentence the verifier did not write would be
  # a true finding attributed to the wrong author — the same misattribution
  # DIVE-2725 spent two iterations removing from a probe verdict.
  _gate_version_vs_installed "$ident" verify "$result_txt"
  local _v_guard_st
  _v_guard_st=$(db "SELECT COALESCE(status,'') FROM tasks WHERE id=${id};")
  if [[ "$_v_guard_st" != "done" && "$_v_guard_st" != "cancelled" ]]; then
    _task_guard_result_over_closed "$id" "$ident" verify "$result_txt" 0 0 verify-result-over-open
    result_txt="$_TASK_GUARDED_RESULT"
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
    # mean invisible, though. When the kernel-authenticated caller is the recorded
    # maker and the still-live row is held by its verifier, stamp the durable task
    # result, emit a separately classifiable audit event, and warn on stderr. The
    # mark names every fact a later reader needs to weigh the close: maker,
    # verifier who never recorded a grade, and loop iteration. An unidentified
    # caller cannot safely be classified as maker or verifier, so its passing
    # evidence is retained but it cannot close a live delivered loop.
    #
    # This belongs in audit_log, not policy_refusals: nothing was refused. Route
    # through the task-store fence so fixture DBs cannot write real-looking task
    # telemetry into the fleet audit log (DIVE-2010).
    local _svc_auth_actor _svc_row _svc_assignee _svc_status
    _svc_auth_actor=$(_gate_authenticated_actor)
    _svc_row=$(db "SELECT COALESCE(maker_agent,'')||x'1f'||
                        COALESCE(verifier,'')||x'1f'||
                        COALESCE(assignee,'')||x'1f'||
                        COALESCE(iteration,0)||x'1f'||status
                   FROM tasks WHERE id=${id};")
    IFS=$'\x1f' read -r self_verify_maker self_verify_verifier \
      _svc_assignee self_verify_iteration _svc_status <<<"$_svc_row"
    if [[ -n "$self_verify_maker" && -n "$self_verify_verifier" \
          && "$_svc_assignee" == "$self_verify_verifier" \
          && "$_svc_status" != "done" && "$_svc_status" != "cancelled" ]]; then
      if [[ -z "$_svc_auth_actor" ]]; then
        db "UPDATE tasks SET result=$(sqlq "$result_txt") WHERE id=${id};"
        fail "$E_PERMISSION" "$ident verify passed and was recorded, but auto-close was refused: the caller identity could not be authenticated"
      fi
      if [[ "$_svc_auth_actor" == "$self_verify_maker" ]]; then
        self_verified_close=1
        result_txt="⚠ self-verified-close: maker=${self_verify_maker}; verifier=${self_verify_verifier} never graded; iteration=${self_verify_iteration}"$'\n'"${result_txt}"
      fi
    fi
    # DIVE-2067: `task verify --cmd` had NO guard against closing an ALREADY-CLOSED task,
    # so a second close REPLACED the result field outright. Measured on DIVE-2059: the
    # verifier closed it with the ACK at 10:22:37, the MAKER closed it again 39s later via
    # `verify --cmd`, and the ACK — two operational caveats, the red-team evidence, and a
    # follow-up split — was silently discarded. It survived only because the verifier had
    # also compiled it to the wiki.
    #
    # Note this path is a SANCTIONED escape: the DIVE-2007 refusal message names
    # `task verify --cmd` as a real exit for a maker whose delivery was refused. So the fix
    # must NOT close that door — it blocks only the case where there is nothing to escape
    # FROM, i.e. the task is already done and the closer is not the recorded verifier.
    #
    # RE-LAND NOTE (main, DIVE-2389): this compares `task_actor`, a PROVENANCE string the
    # caller can set, and not the kernel-authenticated identity DIVE-2330 introduced after
    # this fix was written. That is deliberate and it is a real limitation, so read it
    # before extending this guard. The measured incident was an ACCIDENTAL clobber (a maker
    # re-closing 39s later), not a forgery, and the cost of the two failure modes is not
    # symmetric here: a forged actor loses one result field, whereas keying on the
    # authenticated actor breaks every harness that models a verifier by setting USER —
    # exactly what DIVE-2330 did to the gate suite. I tried the authenticated form first
    # ($_svc_auth_actor is already in scope three lines up) and it takes C1 red for that
    # reason. Hardening it needs a caller-uid seam in this harness, which is its own row,
    # not a re-land.
    local _v_st _v_vfier _v_actor _v_prev
    _v_st=$(db "SELECT COALESCE(status,'') FROM tasks WHERE id=${id};")
    _v_vfier=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${id};")
    _v_actor=$(task_actor "")
    if [[ "$_v_st" == 'done' && -n "$_v_vfier" && "$_v_actor" != "$_v_vfier" ]]; then
      policy_refuse "$E_CONFLICT" verify-over-closed DIVE-2067 "$ident" \
        "$ident is ALREADY done and its recorded verifier is '${_v_vfier}', not '${_v_actor}'. A second close here would REPLACE the verifier's result field and silently discard their ACK (DIVE-2067). There is nothing to escape from: the grade already exists. To ADD evidence, send it to '${_v_vfier}' (5dive agent send ${_v_vfier} \"...\") and let them fold it in; to reopen, '5dive task reject $ident --feedback=...'."
    fi
    # DIVE-2067 rec 3: never silently discard. If a close still lands on an already-done
    # task (the verifier re-closing their own), PRESERVE the prior result by appending.
    if [[ "$_v_st" == 'done' ]]; then
      _v_prev=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${id};")
      [[ -n "$_v_prev" ]] && result_txt="${result_txt}"$'\n'"--- superseded result (DIVE-2067, preserved) ---"$'\n'"${_v_prev}"
    fi
    # DIVE-2938: THIS CLOSE DOES NOT RUN THE MERGE GATE, AND UNTIL NOW IT DID NOT SAY SO.
    #
    # The DIVE-1830 merge gate lives in `_task_status_cmd` (the done/cancel verbs). This
    # flip is a raw UPDATE in a different function, so a row can reach status=done with
    # its delivery unmerged and nothing anywhere records that the question was never
    # asked. Measured: DIVE-2743 closed on `verify --cmd` running a unit test inside a
    # LOCAL WORKTREE and its test file is absent from main today; DIVE-2645 was graded
    # "at worktree tip c2baa6b" with its PR still open.
    #
    # This is NOT the gate. Gating here would re-create the deadlock DIVE-2318 routes
    # OUT of — its no-credential refusal names `task verify --cmd` as the authorised
    # terminal move for a verifier who holds no gh, so refusing here without a working
    # `--no-done` (still unreachable for a read-grader per DIVE-2832) would strand
    # exactly the seat the exit was built for. That build waits on DIVE-2832.
    #
    # What ships instead is LEGIBILITY: when the row carries a binding the merge gate
    # WOULD have checked, say on the record that it was not checked. Two properties
    # earn it. (1) The reader of a done row currently cannot distinguish "merged and
    # graded" from "graded on a branch" — both render as a green result. (2) It is the
    # only way to FIND the class: `task merge-audit` scans for PR *numbers*, so a row
    # binding a bare `Branch:` line — which is what both receipts did — is structurally
    # invisible to it. A fixed token in the result field is greppable where the audit is
    # blind.
    #
    # Deliberately scoped to rows that HAVE a binding. A row with nothing to merge has
    # no question to leave unanswered, and stamping it would be noise that trains people
    # to skip the line — the failure mode of every warning that fires too often.
    local _mg_body _mg_dref _mg_bind=""
    _mg_dref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=${id};")
    _mg_body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_mg_dref" ]]; then
      _mg_bind="delivery_ref ${_mg_dref}"
    elif _gate_text_names_a_ref "$_mg_body"; then
      _mg_bind="a PR named in the body"
    else
      # DIVE-2577's own discovery rule, reused rather than re-spelt: a branch the row's
      # prose names, anchored on the "<ident>-" prefix. Reusing it is the point — if the
      # gate's idea of a binding changes, this stamp must change with it or it will go
      # quiet on exactly the rows the gate started catching.
      # DIVE-3265: AN EMPTY BRANCH SET IS AN ANSWER, NOT A FAILURE — `|| _mg_branches=""`
      # is load-bearing and its absence killed the verb outright. The extractor is a
      # PROBE that legitimately finds nothing (most rows name no branch). Its pipeline
      # ends in `grep`, which exits 1 on no-match; `pipefail` promotes that out of the
      # function and through `head | paste`, and a bare `var=$(...)` under `set -euo
      # pipefail` (src/header.sh) then kills the whole run. Measured on DIVE-3264 with
      # the CLI's own suggested trace, last lines before exit:
      #     ++ paste -sd, - / + _mg_branches= / + on_exit_audit / + local code=1
      # That is why the two verbs behaved DIFFERENTLY on one row: `task done` found a
      # (bogus) branch, so extraction succeeded and it refused cleanly, while `task
      # verify --cmd` found none and CRASHED before any error path could print.
      # DIVE-2603 fixed exactly this at the sibling call site ~2000 lines up; this site
      # shipped later (DIVE-2938) and re-introduced it. Grepped the class, not the form:
      # these two are the only callers of the extractor and both are guarded now, and
      # tests/verify_close_merge_gate_stamp_unit.sh arm C pins THIS one from both ends.
      local _mg_branches
      _mg_branches=$(_gate_branch_refs_from_text "$_mg_body" "$ident" 2>/dev/null | head -3 | paste -sd, -) || _mg_branches=""
      [[ -n "$_mg_branches" ]] && _mg_bind="branch(es) named in the body: ${_mg_branches}"
    fi
    if [[ -n "$_mg_bind" ]]; then
      result_txt="⚠ merge-gate NOT EVALUATED (DIVE-2938) — closed via \`task verify\`, which does not run the DIVE-1830 gate. This row binds ${_mg_bind}; whether it reached main was NOT checked by this close. Confirm with a positive existence test on the canonical ref (e.g. \`git cat-file -e origin/main:<a file the change created>\`) before relying on it."$'\n'"${result_txt}"
    fi
    # DIVE-2477: the THIRD close writer. DIVE-2067 taught this lesson one column
    # over — when you guard one verb, ask which OTHERS write the field. A
    # verifier re-verifying their own already-done row (the case DIVE-2067's
    # refusal deliberately allows) refreshed done_at here, same as the close
    # verbs did. COALESCE for the same reason and by the same rule: first close wins.
    db "UPDATE tasks SET status='done', done_at=COALESCE(done_at, datetime('now')), result=$(sqlq "$result_txt") WHERE id=${id};"
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
    # DIVE-3098: --no-done records a VERIFIER GRADE. Stamp it structurally as well
    # as in prose, because the predicate that exempts this row from the goal hook
    # and the rot-nudger must not be forgeable. `task deliver --result=` is the
    # MAKER's verb and writes the same column; if the predicate keyed on result
    # TEXT, a maker could satisfy it by typing the right words and walking away —
    # exactly the fail-open _hb_loop_terminal_clause already warns about one layer
    # up. graded_by is the ACTOR, so terminal_for_verifier can additionally require
    # grader != maker and a self-verified close cannot buy the exemption.
    # COALESCE: first grade wins, same rule as done_at (DIVE-2477).
    db "UPDATE tasks SET result=$(sqlq "$result_txt"),
           graded_at=COALESCE(graded_at, datetime('now')),
           graded_by=COALESCE(graded_by, $(sqlq "$(task_actor "")"))
        WHERE id=${id};"
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
    policy_refuse "$E_USAGE" bare-block-forbidden DIVE-1357 "$task" "a bare 'task block $task' needs a revisit anchor — add --by=<id>, or use 'task park --reason --wake'"
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
  [[ -n "$wake" ]]   || fail "$E_USAGE" "park needs --wake=<when> (e.g. +7d, +12h, YYYY-MM-DD) — unknown date? pick a re-check; waiting on a person? 'task need'"
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
    policy_refuse "$E_USAGE" park-over-open-gate DIVE-1453 "$tident" "$tident has an open ${_gt} gate awaiting a human — it is already blocked; answer the gate instead of parking"
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
            need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL,
            -- DIVE-2354: a parked row holds no gate, so it must not keep reporting
            -- which ORDER that gate was in. The archive above copied it to history.
            gate_mode=NULL
      WHERE id=${tid} AND status NOT IN ('done','cancelled');
      COMMIT;"
  # DIVE-2410: park clears the gate columns, so whatever button that gate put in a
  # human's chat now points at a question the task no longer holds.
  _task_gate_retire_buttons "$tident" "parked" || true
  # DIVE-2877: A PARK'S BLAST RADIUS EXCEEDS THE ROW IT IS APPLIED TO, and until
  # now nothing said so at the moment of the park. On an instance materialized
  # from a recurring template (from_template_id set) a park is not a delay of one
  # row — it is a stop of the whole beat, with no catch-up:
  #
  #   - the materializer dedups on `status NOT IN ('done','cancelled')`
  #     (_hb_materialize_recurring, src/cmd_heartbeat.sh) and a park sets
  #     status='blocked', so the parked instance HOLDS the template's only open
  #     slot. Every occurrence inside the park window is DROPPED, not deferred —
  #     the materializer carries an explicit `V1 LIMITATION: no catch-up`.
  #   - the DIVE-2693 stall ladder requires `status='todo' AND parked_at IS NULL`
  #     at BOTH rungs (rung 2 added by DIVE-2853), so the row that stopped the
  #     beat is the one state the watchdog cannot see.
  #
  # THE LADDER IS NOT THE DEFECT and this guard is deliberately not there. Rung 2's
  # remedy is AUTO-CANCEL: widening its population to parked rows would convert an
  # operator's "not now" into a destruction, on exactly the rows most likely to have
  # been frozen for a real reason. Rung 1 is the same argument one notch softer — a
  # parked row is pending BY DESIGN, and pinging it every beat is the false-positive
  # class already fixed once (DIVE-639/711). Both clauses are correct FOR THE ACTION
  # EACH RUNG TAKES, which is why the guard belongs here instead: the fact is
  # knowable at park time from the row itself, so it needs no watchdog at all.
  #
  # WARN, NEVER REFUSE. This command cannot know whether the operator means to stop
  # the beat (DIVE-2694 was parked by a legitimate fleet-wide token freeze), and a
  # refusal would be a confident claim about intent. Naming the template and the two
  # levers that actually mean "pause the job" is the whole job here.
  #
  # Cost of not having had it: DIVE-2694 (daily character drip) parked 2026-08-07,
  # 9 days of dropped occurrences, downstream +3 days, and nothing red anywhere.
  # CLASS: this is the SECOND entry into the DIVE-2237 trap (skip-if-open switches a
  # template off silently) and strictly worse, because park also mutes the watchdog
  # that surfaced the first. Fixing an entry path is not fixing the trap.
  local _tmpl_ident=""
  local _park_landed; _park_landed=$(db "SELECT CASE WHEN parked_at IS NOT NULL THEN 1 ELSE 0 END FROM tasks WHERE id=${tid};" 2>/dev/null || echo 0)
  if [[ "$_park_landed" == "1" ]]; then
    # ident has no spaces, so one row split on the first space keeps this to a
    # single query. Empty when the row is not a materialized instance.
    local _tmpl_row=""
    # DIVE-2272: carry the template's overlap policy. A park's blast radius is
    # policy-dependent — under skip it stops the beat outright, under spawn it
    # consumes one bounded slot — and a warning that names the wrong one is worse
    # than none: it teaches the operator the warning does not mean what it says.
    # ident/schedule/policy/bound are all whitespace-free EXCEPT schedule (a cron
    # expr has spaces), so the tail fields are peeled off the RIGHT and whatever
    # remains in the middle is the schedule.
    _tmpl_row=$(db "SELECT p.ident || ' ' || COALESCE(p.schedule,'?') || ' ' || COALESCE(p.on_overlap,'skip') || ' ' || COALESCE(p.overlap_bound, ${TASKS_OVERLAP_BOUND_DEFAULT:-3})
                    FROM tasks t JOIN tasks p ON p.id = t.from_template_id
                    WHERE t.id=${tid};" 2>/dev/null || echo "")
    if [[ -n "$_tmpl_row" ]]; then
      local _tmpl_rest _tmpl_pol _tmpl_bound
      _tmpl_ident="${_tmpl_row%% *}"; _tmpl_rest="${_tmpl_row#* }"
      _tmpl_bound="${_tmpl_rest##* }"; _tmpl_rest="${_tmpl_rest% *}"
      _tmpl_pol="${_tmpl_rest##* }";   _tmpl_rest="${_tmpl_rest% *}"
      local _tmpl_sched="$_tmpl_rest"
      local _park_blast
      if [[ "$_tmpl_pol" == "spawn" ]]; then
        # Under spawn the beat keeps firing, so the honest warning is about the
        # BOUND, not a stop. Still worth saying: a parked row counts open forever,
        # the stall watchdog skips parked rows, and enough of them silently
        # convert a spawn template into a suppressed one.
        local _park_open
        _park_open=$(db "SELECT COUNT(*) FROM tasks i JOIN tasks p ON p.id=i.from_template_id WHERE p.ident=$(sqlq "$_tmpl_ident") AND i.status NOT IN ('done','cancelled');" 2>/dev/null) || _park_open="?"
        [[ "$_park_open" =~ ^[0-9]+$ ]] || _park_open="?"
        _park_blast="this park does NOT stop that beat — ${_tmpl_ident} is on-overlap=spawn, so later slots keep firing — but it does CONSUME one of its ${_tmpl_bound} overlap slots for as long as it stays parked (the materializer counts a parked instance as open; ${_park_open} open now). At the bound the template degrades to skip-and-stamp, i.e. the beat stops after all, and the recurring-stall watchdog skips parked rows so nothing will report the drift."
      else
        _park_blast="this park STOPS THAT BEAT, it does not delay one row (DIVE-2877). The materializer counts a parked instance as ${_tmpl_ident}'s open slot, so ${_tmpl_ident} will not fire again until this row is unparked or closed, and the occurrences inside the window are DROPPED with no catch-up. The recurring-stall watchdog skips parked rows, so nothing will report it."
      fi
      warn "$tident is a recurring INSTANCE of ${_tmpl_ident} (schedule: ${_tmpl_sched}) — ${_park_blast} If you meant to pause the JOB: park the template instead — '5dive task park ${_tmpl_ident} --reason=<why> --wake=<when>' (a blocked template is skipped by the materializer, and unparking it resumes the schedule). If you meant to skip just THIS occurrence: '5dive task cancel $tident --result=\"<why>\"' — a cancel frees the slot, so the next tick fires normally."
    fi
  fi
  local wake_note=""; [[ "$wake_sql" != "NULL" ]] && wake_note=" — wakes $(db "SELECT wake_at FROM tasks WHERE id=${tid};") UTC"
  ok "$tident parked (no action needed)${reason:+ — $reason}${wake_note}" \
     '{task:($t|tonumber), task_ident:$ti, parked:true, reason:$r, wake_at:(($w|select(length>0)) // null), stops_recurring_template:(($tm|select(length>0)) // null)}' \
     --arg t "$tid" --arg ti "$tident" --arg r "$reason" --arg w "$([[ "$wake_sql" != "NULL" ]] && db "SELECT wake_at FROM tasks WHERE id=${tid};" || echo "")" \
     --arg tm "$_tmpl_ident"
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

# DIVE-2629: THE FLOOR MUST READ THE ACTION, NOT THE SUBJECT MATTER OF THE CODE.
#
# THE DEFECT, measured by main 2026-08-03 by running _gate_tier2_floor_hit on four
# ask strings that differ by ONE token:
#
#   'approve delegated push for review of branch dive-2613-teardown-outcomes-...'  -> T2
#   'approve delegated push for review of branch dive-2613-outcomes-hetzner-only'  -> T1
#   'approve delegated push for review of branch dive-XXXX-teardown-foo'           -> T2
#   'approve delegated push for review of branch dive-2592-budget-variance'        -> T1
#
# The word 'teardown' appearing ONLY inside a git branch NAME forces tier 2. The
# floor exists to catch DESTRUCTIVE ACTIONS; the action here is "push a feature
# branch to a remote for review" — inert by construction, no merge, no prod touch,
# reversible. What is destructive-sounding is the SUBJECT of the code on the
# branch. The floor was reading what the work is ABOUT and grading it as what the
# gate DOES, so the better a branch name describes the work the likelier it floors:
# the naming convention we WANT is the one that trips it.
#
# WHY THAT IS A RATCHET AND NOT ONE EXTRA TAP. A tier-2 approval is filed with NO
# routed_reviewer, and cmd_task_answer's designated-reviewer exception requires
# actor == routed_reviewer. So NO agent can ever clear it — not the filer, not
# their lead, not the org coordinator — and no agent action hands it back. It is
# permanently the human's. DIVE-2613 is one of the six eng gates lodar objected to
# on 2026-08-03 ("can you stop pinging me for dev stuff") and dev2 stayed blocked
# behind it. The floor's usual "a false positive costs one tap" bias does not hold
# on this path, because there is no tap that gives it back.
#
# THE FIX SCOPES THE MATCH, NOT THE VERDICT (main's shape, adopted). Exempting the
# individual words would be the tempting non-fix — it keeps the wrong question and
# tidies the answer, the same way stripping +suffix was the non-fix on DIVE-2594.
# Instead: when — and only when — the text is recognised as an INERT
# push-for-review, the git branch IDENTIFIER is removed before the floor reads it.
# A branch name is a label, never a statement of the action a gate authorises.
# Everything else in the ask is still read, unchanged: a push ask that ALSO names a
# spend, a secret or a publish still floors, because those words are in the prose.
#
# THREE NARROWINGS, all deliberate, all biased toward KEEPING the floor:
#
#   1. NOT the whole eng-ship class. _gate_eng_ship_hit also covers merge, deploy,
#      roll-to-fleet and push-to-main — those TOUCH PROD and are not inert, so they
#      must keep flooring on their subject matter. _GATE_PUSH_NOT_INERT_RX kicks
#      the text back out of this exemption the moment it names one of them, which
#      is why "push branch X for review, then merge to main" is unchanged.
#   2. Only BRANCH-SHAPED tokens are redacted, not every hyphenated word. A slug
#      qualifies on a slash (feat/x), a ticket prefix (dive-2613-...), or two or
#      more hyphens (a-b-c). So 'auto-teardown' in prose survives and still floors:
#      one hyphen and no ticket prefix is a WORD, and when the shape is ambiguous
#      the floor stays on.
#   3. Applied HERE, at the single match site, so every consumer — cmd_task_need's
#      filing floor, the approval/manual routing arm, and cmd_goal's low-risk
#      check — inherits the same verdict from the same inputs, which is the
#      property _gate_floor_axis exists to preserve.
#
# NOT ATTEMPTED, and it is a separate ticket: DIVE-2592 routed to olivia when its
# filer dev reports_to main. That is _gate_route_reviewer, not the floor, and main
# explicitly did not diagnose it — do not fold it in here.
_GATE_PUSH_FOR_REVIEW_RX='delegated push|push[- ]for[- ]review|5dive push|push[^.]*(for review|for a pr|for code review|branch)'
# The DESTINATION clause is `\bto\b … (main|master|prod)`, NOT `push to (main|…)`.
# Found by the pre-land corpus sweep, and it is the one arm the fix got wrong on
# first writing: DIVE-1940's real ask is "Push branch dive-1940-token-ux @ 3d9851a0
# to 5dive-frontend MAIN". The adjacent form `push to main` cannot see a repo name
# sitting between the verb and its destination, so a push to a repo's default
# branch was inheriting the inert-push exemption. It floored before this change
# only by accident — on the word 'token' inside the branch name — so the sweep is
# what caught it, not the defect it was sweeping for. Bounded distance is safe here
# in a way DIVE-2224 forbids across a seam: this matches inside ONE field.
_GATE_PUSH_NOT_INERT_RX='\bmerg(e|es|ed|ing)\b|deploy|redeploy|\brelease\b|roll ?out|\broll(ing|ed)? out\b|roll[^.]*fleet|fleet[- ]?roll|\bto\b[^.]{0,60}\b(main|master|prod|production|trunk)\b|\bland (the|it|this)\b'

# 0 iff the text describes an INERT push-for-review: a feature branch going to a
# remote for PR review. Fails closed — anything that also names a prod-touching
# verb is NOT inert and gets no exemption.
_gate_push_for_review_hit() {
  local text; text=$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')
  [[ "$text" =~ $_GATE_PUSH_FOR_REVIEW_RX ]] || return 1
  [[ "$text" =~ $_GATE_PUSH_NOT_INERT_RX ]] && return 1
  return 0
}

# 0 iff $1 (already lowercased, punctuation trimmed) has the shape of a git ref.
# Three qualifying shapes; a single-hyphen word with no ticket prefix does NOT
# qualify, because that is how English compounds are written.
_gate_branch_slug_token() {
  local w="${1-}" hy
  [[ "$w" =~ ^[a-z0-9._/-]+$ ]] || return 1
  [[ "$w" == */* ]] && return 0
  [[ "$w" =~ ^[a-z]+-[0-9]+(-|$) ]] && return 0
  hy=${w//[^-]/}
  (( ${#hy} >= 2 )) && return 0
  return 1
}

# Drop branch-identifier tokens from $1. Globbing is disabled around the split so
# a ref containing * or ? cannot expand against the cwd.
_gate_redact_branch_refs() {
  local out="" w core noglob=0
  [[ $- == *f* ]] || { noglob=1; set -f; }
  for w in ${1-}; do
    core="$w"
    [[ "$w" =~ ^[^a-z0-9]*([a-z0-9._/-]+)[^a-z0-9]*$ ]] && core="${BASH_REMATCH[1]}"
    _gate_branch_slug_token "$core" && continue
    out+="$w "
  done
  (( noglob )) && set +f
  printf '%s' "$out"
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
  #
  # DIVE-2629: an inert push-for-review ask NAMES A GIT BRANCH, and the branch name
  # is the subject of the work, not the action being authorised. Redact refs before
  # matching so the floor grades what the gate DOES. Scoped, not exempted — the
  # rest of the ask is read exactly as before. Full rationale at the RX above.
  if _gate_push_for_review_hit "$text"; then
    text=$(_gate_redact_branch_refs "$text")
  fi
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
# _gate_authenticated_actor, _gate_uid_to_agent, _gate_caller_uid, _gate_is_root,
# _gate_passwd_stream and _gate_agent_for_uid MOVED to src/lib/actor.sh (DIVE-2517,
# v0.18 "Proof of who"). Same names, same semantics, one definition — the strict
# uid-first derivation is now the shared one in lib/ rather than a local helper in
# the file that happened to need it first. Call sites here are unchanged.

_GATE_ENG_SHIP_RX='\bmerg(e|es|ed|ing)\b|pull request|\bpr\b|\bdiff\b|ship it|ship the|ship this|\bship(ping|ped)\b|deploy|redeploy|roll ?out|\broll(ing|ed)? out\b|land the|land it|land this|\bland(ing|ed)\b|rebase|hotfix|cut a branch|cut the release|push(es|ed|ing)? to (main|prod|production|origin)|push[^.]*github|delegated push|push[- ]for[- ]review|push .*(branch|for review|for a? ?pr|for code review)|5dive push|roll[^.]*fleet|fleet[- ]?roll|code review|approve the (merge|diff|change|pr|build|deploy|ship|commit)|build\.sh|smoke test|ci\b'
_gate_eng_ship_hit() {
  local text; text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$text" =~ $_GATE_ENG_SHIP_RX ]]
}

# --- DIVE-2093: say WHO the gate routed to and WHY, at FILE TIME --------------
#
# The routed `ok` line has always named the reviewer and the ROLE ("routed to
# main2 for verifier review"). What it never named is the PROPERTY that picked
# that reviewer, and that omission is the whole defect: three agents in 36 hours
# (dev3 on DIVE-2084, main on DIVE-2146, olivia right behind them; then main2 on
# DIVE-2798 and DIVE-2808) filed a gate asking for an ACTION and had it land on
# the loop's verifier, who could judge the work and could not perform the act.
# Every one of those cost a round trip, and none of them was visible on the
# board — a gate pending on the wrong principal renders exactly like a gate
# pending on the right one.
#
# The filer is the only party who knows what the ask actually needs, and the
# moment of filing is the only moment at which re-filing is free. So the fix is
# to hand them the routing basis right there instead of leaving them to infer it
# from an answer that never comes.
#
# `basis` is the property that chose the target, NOT the trigger that made the
# gate routable at all — those are different questions and the filer needs both.
# `basis` is `tasks.route_provenance` VERBATIM — the same value the row is stamped
# with, threaded from the one place it is computed rather than re-derived here.
# DIVE-2093 iteration 3, and the reason is a defect this function shipped with: it
# used to take a two-valued lead/verifier flag and print the ORG CHART sentence for
# everything that was not `verifier`. DIVE-3171 then added a THIRD route (the sealed
# standing lead, which fires precisely when the chart resolves NOBODY), so the
# catch-all asserted an `agents_org.reports_to` edge that by construction does not
# exist — a routing explanation naming the wrong property, which is this row's own
# defect class emitted by the fix for it.
#
# THE GENERAL RULE, and it is why the last arm reads the way it does: a catch-all in
# an EXPLANATION is not a default, it is an assertion about every case you did not
# enumerate. `*)` is safe when it says "some other reason"; it is a falsehood
# generator when it names a specific mechanism and cites a specific table. A
# diagnostic must degrade to UNKNOWN, never to the most common case — the same
# absent-vs-forbidden reasoning as DIVE-2318.
# community/wiki/a-why-clause-that-enumerates-bases-lies-about-the-one-it-omits.md
#
# _gate_route_why <route_provenance> <reviewer> <filer> <trigger>
_gate_route_why() {
  local basis="$1" reviewer="$2" filer="$3" trigger="$4"
  case "$basis" in
    verifier-loop)
      printf 'why: routed by LOOP MEMBERSHIP — %s is this task'"'"'s verifier of record (tasks.verifier). That property carries NO information about which capabilities %s holds, so if this ask needs an ACTION performed (open a PR, push, spend, provision a secret) rather than a judgement made, it is on the wrong desk: re-file with --tier=2, or --needs=<capability>, or hand it to a holder. trigger=%s' \
        "$reviewer" "$reviewer" "$trigger" ;;
    seal:standing-lead)
      printf 'why: routed by the SEALED STANDING LEAD — the org chart resolved NOBODY above %s (they are its root), so this went to %s under the sealed authority.eng_approval_lead and NOT along an agents_org.reports_to edge, which does not exist here (route_provenance=seal:standing-lead, DIVE-3171/2099). That seal names an ENGINEERING-APPROVAL holder and says nothing else about what %s can do, so an ask needing some other capability is still on the wrong desk. trigger=%s' \
        "${filer:-the filer}" "$reviewer" "$reviewer" "$trigger" ;;
    chart)
      printf 'why: routed by the ORG CHART — %s is the lead %s reports to (agents_org.reports_to). trigger=%s' \
        "$reviewer" "${filer:-the filer}" "$trigger" ;;
    *)
      printf 'why: routed to %s by a basis this build does not name (route_provenance=%s) — so this line cannot tell you WHICH property picked them, and you should not read it as the org chart having resolved anybody. Check the routing source before relying on %s being able to answer. trigger=%s' \
        "$reviewer" "${basis:-<empty>}" "$reviewer" "$trigger" ;;
  esac
}

# Can this seat mint a DIVE-756 closure signature? Echoes `<yes|no|unknown>|<class>`.
#
# The classes come from the same measurement `agent info` renders
# (classify_sudo_grant), and the yes/no split is the one DIVE-2760's own answer-
# time warning already states in prose: root-all and cli-root seats hold sudo for
# `5dive gate-proof sign`; cli-scoped seats do not.
#
# `custom` and `unknown` return UNKNOWN and never `no`. DIVE-2318: an unmeasured
# grant is the absence of a measurement, not evidence of absence, and the cost of
# the two errors is asymmetric here — a false `no` sends the filer to re-route a
# gate that would have cleared fine, on a box where the peer read simply did not
# work (DIVE-2135 makes that read possible, not guaranteed).
_gate_seat_can_sign() {
  local name="$1" grant cls
  [[ -n "$name" ]] || { printf 'unknown|unknown\n'; return 0; }
  grant=$(agent_sudo_grant "agent-${name}" 2>/dev/null) || grant=""
  cls="${grant%%|*}"; [[ -n "$cls" ]] || cls="unknown"
  case "$cls" in
    root-all|cli-root) printf 'yes|%s\n' "$cls" ;;
    cli-scoped|none)   printf 'no|%s\n' "$cls" ;;
    *)                 printf 'unknown|%s\n' "$cls" ;;
  esac
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

# DIVE-3228 — THE COMMENT AND THE CONDITION DISAGREED, AND THE CONDITION WON.
#
# `access` defaults to tier 2 (the `*) tier=2` arm at the type-default case below),
# and DIVE-1243 made it lead-clearable BY TYPE: it is routable regardless of tier,
# it bypasses the gate_builder_routing pref, and cmd_task_answer's
# designated-reviewer exception lists it alongside approval/manual. So filing one
# tells the filer it routed, and `routed_reviewer` really is set.
#
# Then the tier-2 floor in cmd_task_answer (`gtier == 2 && ! human`) refuses the
# routed lead's answer, and the DIVE-1437 escalation immediately below it is scoped
# `[[ $nt == approval || $nt == manual ]]` — `access` is not in that list, so it
# does not even get the escalation's tap button; it takes the original hard
# refusal. The comment eight lines above that condition asserts the opposite
# ("`access` is DELIBERATELY lead-clearable by DIVE-1243"), which is how this
# survived: every reader who checked the intent found it documented and correct.
#
# MEASURED, DIVE-3212 (ops -> main, 2026-08-11): filed --type=access, routed at
# main explicitly, `task answer` refused with "DIVE-3212 is a tier-2 human gate
# (access) — only a human can clear it; tap the button in Telegram". The filer did
# everything right and still produced a gate only lodar could clear, for a push to
# our own repo. It was already MOOT when it refused — the branch was pushed and
# PR #585 opened before the answer was attempted — so it sat in the human inbox
# describing work that was done.
#
# WHY THIS IS NOT "let the lead clear tier 2". The exemption is re-derived FROM THE
# ROW rather than inferred from `_lead_clear` alone, and that is deliberate: relying
# on the file-time invariant ("a floored/pinned access gate never gets routed, so a
# routed one must be clean") is exactly the necessary-but-not-sufficient trap this
# same row already produced once — the six-harness population that was derived
# statically and measured to zero. A row written by an older build, or by any future
# path that sets routed_reviewer, must not inherit clearance from an argument about
# what cmd_task_need does today.
#
# So `access` at tier 2 is lead-clearable ONLY when the store can say it is tier 2
# for the one reason that carries no human class:
#   axis=type-default   -> 2 because `access` defaults to 2. Nobody chose it. ALLOW.
#   axis=pinned         -> the caller typed --tier=2. DIVE-1957: a hard-human
#                          contract no KIND-based override may cross. DENY.
#   axis=ask / title-fallback -> the T2 category floor fired on money / secrets /
#                          destructive / publish. DENY.
#   '' or NULL          -> a pre-DIVE-2615 row: the column was never written, so the
#                          reason is UNKNOWN. An unknown is not a type-default. DENY.
# and a declared human-class `--needs` (spend_authority / human_tap / secret_provision)
# denies on top of all of it — the filer STATING what the ask consumes outranks any
# inference about the tier (DIVE-2241).
#
# `secret` can never reach here: it is never routed, so `_lead_clear` is 0 for it by
# construction, and it is not this predicate's type anyway.
#
# _gate_access_lead_clearable <need_type> <tier> <floor_provenance> <needs_capability>
#   -> 0 when a tier-2 `access` gate's ROUTED lead may clear it despite the T2 floor.
_gate_access_lead_clearable() {
  local nt="${1:-}" tier="${2:-}" floor_prov="${3:-}" needs="${4:-}"
  [[ "$nt" == "access" ]] || return 1
  [[ "$tier" == "2" ]] || return 1
  # DIVE-2241: the declaration outranks the tier's provenance, so it is checked
  # first and independently. An UNRECOGNISED capability is not a human one and
  # changes nothing here, exactly as it changes nothing at filing time.
  if [[ -n "${needs//[[:space:]]/}" ]] && _gate_needs_human "$needs"; then return 1; fi
  # The ONE allowed provenance. Everything else — including empty — denies.
  [[ "$floor_prov" == "axis=type-default" ]] || return 1
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
  #
  # DIVE-2629: and that invariant is exactly why the branch-ref redaction has to be
  # mirrored here. Without it this helper would keep reporting 'teardown' — a term
  # read out of a git branch name — for a text the floor itself no longer floors,
  # which is the drift the paragraph above forbids.
  if _gate_push_for_review_hit "$text"; then
    text=$(_gate_redact_branch_refs "$text")
  fi
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

# DIVE-2212: decision options are authored by the filer but read and selected by
# the answerer. Second-person wording therefore has two natural frames on the
# same bytes ("you" can be read as either side). Keep options free-form, but make
# that risky shape observable at filing and render the concrete account frame on
# answer. Boundaries deliberately exclude innocent substrings such as "youtube".
_gate_option_has_second_person() {
  LC_ALL=C grep -Eiq '(^|[^[:alnum:]_])(you|your|yours|yourself|yourselves)([^[:alnum:]_]|$)' <<<"${1:-}"
}

# DIVE-2848 — THE KEYSTROKE CAP ON RUBBER-STAMP GATES.
#
# lodar, 2026-08-06 04:11Z: "im fighting with unnecessary human gates for the past
# three weeks", after "im tired of rubber tapping". The policy that should have
# prevented it has been in CLAUDE.md since 2026-06-29, is unambiguous, and is
# fleet-visible. Measured over 2026-07-16..2026-08-07 anyway: of 107 human-answered
# JUDGMENT gates that carried a --recommend, 96 (90%) came back as the human tapping
# that same value. Only 7 gates in the whole window were keyword-floored to tier 2 —
# the rest of the tier-2 population is agents TYPING --tier=2 on decision, a type
# that defaults to 1. `--tier=0` was used 0 times in 346 gates.
#
# So this is not an intent problem and not a floor-heuristic problem. A policy is
# indexed by TOPIC (a bullet in a doc you read when thinking about gates); the act is
# a KEYSTROKE (you are mid-task, you type the flag). The two never meet. Same defect
# shape the filing cap already solved once: it does not ask agents to file fewer rows,
# it REFUSES at `task add` and names the exits.
#
# The rule encoded below: A GATE WHOSE RECOMMENDATION YOU ARE CONFIDENT ENOUGH TO
# WRITE IS A GATE YOU CAN TAKE. Writing --recommend is deciding; what remains is
# asking a person to agree with a decision already made, which is reassurance.
#
# DELIBERATELY OUT OF SCOPE of the refusal — each of these is a real tier 2:
#   * the T2 category floor (money / public comms / secrets / destructive). Those are
#     tier 2 on SUBJECT MATTER, the filer cannot lower them, and --discusses is their
#     own audited appeal. `tier_floored==1` excludes them here.
#   * a DECLARED --needs=human_tap|spend_authority|secret_provision (DIVE-2241) — that
#     names a capability the filer does not hold, which is the honest hard gate.
#   * manual / secret / access, which are tier 2 by TYPE. Those defaults are the other
#     half of this ticket and are NOT touched here: on --type=secret a tier-2 default
#     is correct and must stay permanent.
#
# _gate_tapback_stats <filer> — this filer's recent rubber-stamp rate over their own
# last _GATE_TAPBACK_WINDOW human-answered judgment gates that carried a
# recommendation. Prints "<taps> <total>"; prints "0 0" on any error, i.e. FAIL-OPEN,
# because the instance-level cap is the enforcing rail and a measurement that cannot
# run must not become a block nobody can explain.
#
# The tap test is SEMANTIC, not string equality, and that is load-bearing. This
# ticket's first measurement read 45% because it compared need_answer to recommend
# with `=`: on an approval the human's tap normalises to 'approved' while the
# recommendation is free text ("approve", "Push it", ...), so 45 of 47 genuine taps
# scored as overrides. lodar caught it himself ("i tap on recs much more... more like
# 98%"). The denominator is judgment gates WITH a recommendation only — manual /
# secret / access carry nothing to tap back, and mixing them in dilutes precisely the
# number being acted on.
_GATE_TAPBACK_WINDOW=20      # M — the filer's own last M answered judgment gates
_GATE_TAPBACK_MIN=8          # below this a share is noise, not a pattern
_GATE_TAPBACK_MAX_TAPS=10    # N — refuse the escape above N taps within the window
_gate_tapback_stats() {
  local who="$1" out=""
  [[ -n "$who" ]] || { printf '0 0'; return 0; }
  out=$(db "SELECT COALESCE(SUM(tap),0)||' '||COUNT(*) FROM (
        SELECT CASE
          WHEN need_type='decision'
               AND lower(trim(need_answer))=lower(trim(recommend)) THEN 1
          WHEN need_type='approval'
               AND lower(trim(need_answer)) LIKE 'approv%'
               AND lower(trim(recommend)) NOT LIKE 'den%'
               AND lower(trim(recommend)) NOT LIKE 'reject%'
               AND lower(trim(recommend)) NOT LIKE 'no%' THEN 1
          WHEN need_type='approval'
               AND (lower(trim(need_answer)) LIKE 'den%' OR lower(trim(need_answer)) LIKE 'reject%')
               AND (lower(trim(recommend)) LIKE 'den%' OR lower(trim(recommend)) LIKE 'reject%'
                    OR lower(trim(recommend)) LIKE 'no%') THEN 1
          ELSE 0 END AS tap
        FROM tasks
        WHERE gate_filed_by=$(sqlq "$who")
          AND need_type IN ('decision','approval')
          AND recommend IS NOT NULL AND trim(recommend) <> ''
          AND need_answer IS NOT NULL
          AND need_answered_by LIKE 'human:%'
        ORDER BY COALESCE(need_asked_at, updated_at) DESC
        LIMIT ${_GATE_TAPBACK_WINDOW});" 2>/dev/null) || out=""
  [[ "$out" =~ ^[0-9]+\ [0-9]+$ ]] || out='0 0'
  printf '%s' "$out"
}

cmd_task_need() {
  tasks_db_init
  local type="" ask="" options="" recommend="" from="" tier="" secret_key="" connector="" probe="" withdraw="" discusses="" needs="" oob="" rubber_stamp="" gate_mode=""
  # DIVE-2627: which flag supplied each prose value (see _read_prose_file).
  local ask_src="" recommend_src=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type=*)      type="${1#*=}" ;;
      --ask=*)       _prose_flag_dupe --ask "$ask_src"; ask="${1#*=}"; ask_src="--ask" ;;
      # DIVE-2627: the ask read VERBATIM from a file. This is the WORST member of
      # the class to corrupt: it is a permanent gate record AND the text a HUMAN is
      # paged to read, with no reader present at the file to notice the missing
      # words. A gate that asks half a question gets half an answer.
      --ask-file=*)  _prose_flag_dupe --ask-file "$ask_src"
                     _read_prose_file --ask-file "${1#*=}"
                     ask="$_PROSE_FILE_VALUE"; ask_src="--ask-file" ;;
      --options=*)   options="${1#*=}" ;;
      --recommend=*) _prose_flag_dupe --recommend "$recommend_src"; recommend="${1#*=}"; recommend_src="--recommend" ;;
      # DIVE-2627: the recommendation read VERBATIM from a file — it is what the
      # owner sees FIRST on the gate, so a hole in it steers the answer.
      --recommend-file=*) _prose_flag_dupe --recommend-file "$recommend_src"
                          _read_prose_file --recommend-file "${1#*=}"
                          recommend="$_PROSE_FILE_VALUE"; recommend_src="--recommend-file" ;;
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
      # DIVE-2411: the explicit opt-in to out-of-band delivery, and it must NAME
      # the channel. A secret gate with no drop target used to be the DEFAULT
      # (both flags omitted) — see the refusal below.
      --out-of-band=*) oob="${1#*=}" ;;
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
      # DIVE-2848: the AUDITED exception to the keystroke cap below. Declared,
      # never inferred, and written to the gate row — an escape that leaves no
      # record is `--tier=2` with extra steps, which is the thing being fixed.
      --rubber-stamp-ok=*) rubber_stamp="${1#*=}" ;;
      # DIVE-2354: WHICH ORDER this gate is in. Declared, never inferred — the
      # filer is the only party who knows whether the action has already happened,
      # and inferring it from timestamps would be a guess presented as a record.
      --mode=*)      gate_mode="${1#*=}" ;;
      --)          shift; positional+=("$@"); break ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           positional+=("$1") ;;
    esac
    shift
  done
  # DIVE-2848: the FILER'S OWN --recommend, captured before anything can write to
  # `recommend`. The cap below refuses a hand-typed tier 2 on the premise "you wrote
  # a recommendation, so you already decided" — and by the time the cap runs,
  # `recommend` may have been PREFILLED from a precedent (OSS-11/OSS-20/OSS-21) that
  # the filer never typed. Keying the cap on the post-prefill variable would refuse a
  # gate for a decision the machine made on the filer's behalf, which inverts the
  # rule. Caught by tests/gate_precedent_unit.sh A5, whose fixture passes no
  # --recommend at all and was refused anyway.
  local recommend_arg="$recommend"
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task need <id> --type=decision|secret|approval|manual|access --ask=\"...\"  (flags: 5dive task --help)"
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
    [[ -z "$type$ask$options$recommend$tier$secret_key$connector$oob$probe$discusses$needs" ]] \
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
    # SUDO_* or the real id -un — see its comment), NEVER on --from. The gate's FILER OF
    # RECORD, their routed lead, or the org coordinator may withdraw, as may a genuine
    # human. An agent that is none of these is refused.
    #
    # DIVE-2382 (approved by olivia as org coordinator; main ruled the shape): this site
    # used to authorize on COALESCE(assignee,'') — the HOLDER. That was the bigger half of
    # the defect this ticket was filed about, and it was wrong in BOTH directions at once:
    #   under-permissive — an agent who files a gate on someone else's task could not
    #                      withdraw their OWN ask (DIVE-2015: gate_filed_by=codex,
    #                      assignee=main, so main could and codex could not);
    #   over-permissive  — a reassigned holder could retire a question they never asked,
    #                      which is precisely the DIVE-2133 shape.
    # A fifth authorizer would have fixed only the first, so this REPLACES the principal.
    #
    # THE SHAPE IS DELIBERATELY STRICTER THAN :6154's, which is the one amendment olivia
    # made to the proposal. :6154 (display/routing) ends its COALESCE on `assignee`;
    # authorizing on that would silently RE-ADMIT the reassigned-holder route in exactly
    # the state where both other columns are empty — the route we are removing. So the
    # authorization site stops at created_by. Two shapes for two jobs, deliberately: the
    # display readers keep their assignee rung, and what this ticket retires is THREE
    # shapes for ONE job. Authorizer-existence does not rest on that rung anyway —
    # conditions 1 (human) and 4 (coordinator) never consult the filer at all, probed
    # against an all-columns-empty row.
    local w_filer w_id w_kind w_name="" w_lead w_coord w_ok=0 w_holder w_who
    w_filer=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''),NULLIF(created_by,''),'') FROM tasks WHERE id=${id};")
    # The HOLDER, for the refusal text only — it no longer authorizes anything. Named
    # when it differs so a refused holder learns why, rather than reading a list that
    # simply omits them.
    w_holder=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")
    w_id=$(_gate_withdraw_actor)                          # "agent <name>" | "human" | "none"
    w_kind="${w_id%% *}"
    [[ "$w_kind" == "agent" ]] && w_name="${w_id#agent }"
    # The lead route follows the PRINCIPAL, so it moves with it: condition 3 is "the
    # filer's lead", and resolving it from the holder would leave a second copy of the
    # same defect one rung up.
    w_lead=$(_gate_route_reviewer "$w_filer")
    w_coord=$(_task_resolve_coordinator)
    [[ "$w_kind" == "human" ]] && w_ok=1                                    # a genuine human caller
    [[ -n "$w_name" && "$w_name" == "$w_filer" ]] && w_ok=1                # the filer
    [[ -n "$w_name" && -n "$w_lead"  && "$w_name" == "$w_lead"  ]] && w_ok=1  # filer's lead
    [[ -n "$w_name" && -n "$w_coord" && "$w_name" == "$w_coord" ]] && w_ok=1  # org coordinator
    # DIVE-2382: name EVERY identity the block above actually walked, with its resolved
    # value. The old text named only "the gate's filer, their lead, or a human" and
    # silently dropped the org coordinator — a FILER-INDEPENDENT condition — so a caller
    # who WAS the coordinator, and was authorized, read a message saying they were not.
    # Two agents independently concluded from that text that DIVE-2106 could never be
    # retired; both were wrong, and that is the mechanism behind the stale-gate class.
    # Unresolvable conditions render as "none" rather than vanishing, so a reader can
    # tell "this route does not exist here" from "this route was never offered".
    # DIVE-2382: "unrecorded" rather than "?" — the placeholder shipped in the first pass
    # and reads as a rendering bug rather than as a fact about the row (olivia approved
    # the swap in the same pass). An empty principal is reachable by CONFIGURATION, not by
    # data: created_by is nullable, so a row with neither column set resolves to nothing,
    # and the reader needs to see that as a stated absence.
    w_who="the gate's filer (${w_filer:-unrecorded})"
    [[ -n "$w_holder" && "$w_holder" != "$w_filer" ]] && w_who+=" — held by ${w_holder}, who does NOT authorize a withdraw since they did not file it"
    (( w_ok )) || policy_refuse "$E_AUTH_REQUIRED" gate-withdraw-not-authorized DIVE-1401 "$ident" "only ${w_who}, their lead (${w_lead:-none}), the org coordinator (${w_coord:-none}) or a human can withdraw this gate"
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
              -- DIVE-2354: same reason as the park path — a withdrawn gate has no
              -- order to report, and the archive row above already carries it.
              gate_mode=NULL,
              secret_key=NULL, connector=NULL, secret_oob=NULL, ask_shape=NULL,
              precedent_ref=NULL, precedent_kind=NULL, routed_reviewer=NULL,
              needs_capability=NULL,
              -- DIVE-2615: a withdrawn gate has no tier, so it must not keep
              -- reporting why it had one. The archive above already copied this
              -- value onto the history row, which is where it belongs afterwards.
              floor_provenance=NULL,
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
    # DIVE-2410: a withdrawn gate is a settled gate from the human's side — the
    # question is gone, so the button must go with it. A withdrawal is the path
    # most likely to leave a stale button standing, because unlike an answer
    # nothing about it ever reaches the human's chat.
    _task_gate_retire_buttons "$ident" "withdrawn by ${w_name:-$w_kind}" || true
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
      || fail "$E_VALIDATION" "--discusses only applies to --type=decision — a $type gate requests an ACTION; re-file it as --type=decision"
    [[ ${#discusses} -ge 12 ]] \
      || fail "$E_VALIDATION" "--discusses must state WHY this gate discusses rather than performs — it is shown to the reviewer who clears it"
  fi
  # DIVE-2848: --rubber-stamp-ok is the audited exception to the keystroke cap
  # further down. Same shape as --discusses on purpose: declared by the filer,
  # required to have substance, recorded on the row, and REFUSED where it would be
  # meaningless rather than silently ignored.
  if [[ -n "$rubber_stamp" ]]; then
    [[ "$type" == "decision" || "$type" == "approval" ]] \
      || fail "$E_VALIDATION" "--rubber-stamp-ok only applies to --type=decision or --type=approval — those are the two types the keystroke cap governs. manual/secret/access default to tier 2 by TYPE and need no escape from it."
    [[ ${#rubber_stamp} -ge 12 ]] \
      || fail "$E_VALIDATION" "--rubber-stamp-ok must state WHY a person has to answer this despite your own --recommend (it is recorded on the gate and read by whoever counts these exceptions later)"
  fi

  # DIVE-2354 — THE TWO ORDERS A GATE CAN BE IN, as data on the row.
  #
  # THE DEFECT, measured on the first run of the DIVE-2348 customer-feedback loop:
  # a gate worded "lodar approves the reply BEFORE it is sent" cannot be satisfied
  # honestly once the send has already happened (emails 13:27/13:30, loop fired the
  # drafting step 13:40). Answering it asserts a before-the-fact approval that did
  # not occur; cancelling it erases the decision point AND, on that run, deleted
  # marketing's escalation path for a genuinely unapproved second email; leaving it
  # open reads as a bypassed human. Nobody bypassed anyone and the record said
  # somebody had. It recurs by construction: these loops race a LIVE Telegram
  # thread, so a loop materialised from the board is routinely behind the
  # conversation. That is the normal case for anything customer-facing, not a
  # timing accident.
  #
  # THE FIX IS A THIRD STATE, not a new verb. `confirm-after-send` records that the
  # tap came AFTER the action — a RATIFICATION. It is not "approved" and must never
  # render as it (same shape as unreadable-vs-absent, DIVE-2327, and NOT-REACHED-vs-
  # pass, DIVE-2039). NULL is the third value: a gate filed before this shipped
  # does not say which order it was, and inferring one for it would manufacture the
  # very claim this ticket is about.
  #
  # WHAT THIS DOES NOT DO, deliberately: nothing here clears anything. The human tap
  # stays mandatory in BOTH modes. `confirm-after-send` is `--type=approval` only —
  # approval is human-class (root-gated in cmd_task_answer, excluded from precedent
  # auto-clear by _gate_human_class), so restricting the mode to it makes
  # "ratification requires a person" true BY CONSTRUCTION rather than by a rule
  # someone has to keep. A `decision` that already happened re-files as an approval;
  # that is the same direction [[standing-authorisation-is-per-thread-dive2353]]
  # already prescribes for an answer that licenses something.
  if [[ -n "$gate_mode" ]]; then
    case "$gate_mode" in
      approve-to-send|confirm-after-send) ;;
      *) fail "$E_VALIDATION" "bad --mode '$gate_mode' (approve-to-send|confirm-after-send)" ;;
    esac
    [[ "$type" == "approval" ]] \
      || fail "$E_VALIDATION" "--mode only applies to --type=approval — a $type gate has no before/after order to record. If the action already happened and you need it ratified, re-file it as --type=approval --mode=confirm-after-send (a ratification must be a human tap, and approval is the type that guarantees one)."
    # A tier-0 gate APPLIES the filer's own --recommend with no ping. On a
    # confirm-after-send that is auto-ratification of an action the filer already
    # took — precisely the thing this ticket says it is NOT asking for. Refused
    # here rather than relying on approval's tier-2 type default, so the guarantee
    # does not depend on a default someone may later think is a formality.
    [[ "$tier" == "0" && "$gate_mode" == "confirm-after-send" ]] \
      && fail "$E_VALIDATION" "--tier=0 auto-applies your own recommendation, which on --mode=confirm-after-send would ratify an action you have already taken with no human involved. A ratification needs the tap; file it at the type default."
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
      fail "$E_CONFLICT" "self-check passed (\`$probe\` succeeded) — you already have this access; re-check the real blocker"
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
  # than at mint time.
  #
  # DIVE-2411: both omitted used to mean "legacy secret gate, out-of-band
  # delivery" — a DEFAULT nobody chose. Measured on DIVE-2232: the gate pinged
  # correctly, the ask read as complete, and there was NO PATH for the value to
  # reach the box, so the only remaining answer was pasting a live credential
  # into a persistent chat log. main nearly received one.
  #
  # WHY THE REFUSAL BELONGS AT FILING TIME. The gate is complete in APPEARANCE and
  # only the delivery MECHANISM is missing. A human staring at the ask cannot see
  # that the drop is absent — nothing in the message is about the drop. Only the
  # filer can see it, and only here. So an omission must not select the shape with
  # no delivery path: name a drop target (DIVE-931) or declare the out-of-band
  # channel explicitly.
  # DIVE-2411: a RE-FILE inherits the delivery path the row already carries. A
  # re-file otherwise DESTROYS it (DIVE-2119 resets the gate columns from the
  # flags given), and the programmatic re-filers pass no delivery flags at all:
  # the council escalation builds `task need <ident> --type=secret --tier=2
  # --ask=...` (src/council/engine.mjs, preserving the TYPE and nothing else). So
  # before this ticket, escalating a properly-targeted secret gate through the
  # council silently converted it into the DIVE-2232 shape — the defect had a
  # generator, not just an author. Inheriting is not "defaulting into no delivery
  # path": it carries forward a path a filer CHOSE, and a row with nothing to
  # inherit still falls through to the refusal below.
  if [[ "$type" == "secret" && -z "$secret_key$connector$oob" ]]; then
    local _pv; _pv=$(db "SELECT COALESCE(secret_key,'')||x'1f'||COALESCE(connector,'')||x'1f'||COALESCE(secret_oob,'') FROM tasks WHERE id=${id};")
    local _pv_sk="${_pv%%$'\x1f'*}" _pv_rest="${_pv#*$'\x1f'}"
    local _pv_conn="${_pv_rest%%$'\x1f'*}" _pv_oob="${_pv_rest#*$'\x1f'}"
    if [[ -n "$_pv_sk" && -n "$_pv_conn" ]]; then
      secret_key="$_pv_sk"; connector="$_pv_conn"
      warn "$ident: re-filed secret gate inherits the existing drop target (${secret_key} -> ${connector}); pass --secret-key/--connector to change it (DIVE-2411)"
    elif [[ -n "$_pv_oob" ]]; then
      oob="$_pv_oob"
      warn "$ident: re-filed secret gate inherits the declared out-of-band delivery (${oob}); pass --secret-key/--connector for a drop target instead (DIVE-2411)"
    fi
  fi
  if [[ -n "$oob" ]]; then
    [[ "$type" == "secret" ]] \
      || fail "$E_VALIDATION" "--out-of-band only applies to --type=secret (it declares how a CREDENTIAL will reach the box)"
    [[ -z "$secret_key$connector" ]] \
      || fail "$E_VALIDATION" "--out-of-band is mutually exclusive with --secret-key/--connector — a gate has ONE delivery path"
    # Must NAME the channel: the whole point is that the human (and the reader of
    # the answered row six months out) can see where the value was meant to land.
    # A bare "yes" opt-in would restore the defect with a flag in front of it.
    [[ ${#oob} -ge 12 ]] \
      || fail "$E_VALIDATION" "--out-of-band must NAME where the value will land (e.g. \"already in my .env on this box\") — the human is shown it"
  elif [[ "$type" == "secret" && -z "$secret_key$connector" ]]; then
    fail "$E_VALIDATION" "a secret gate must name a delivery path — pass --secret-key=<ENV> --connector=<stem>, or --out-of-band=\"<where>\""
  fi
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
  # DIVE-2615: WHY this gate has the tier it has, recorded at the moment it is
  # decided. Every input below is computed here and then thrown away, so the store
  # could say a gate was tier 2 and never say what made it tier 2 — floor_provenance
  # was NULL on all 79 gate_history rows because nothing has ever written it.
  # Answering "how many of tonight's human pings were the floor over-firing?" needed
  # a bundle rig sourcing this file's predicates against asks re-read from the store,
  # two of my attempts at which were void. That is a question the store should
  # answer, and after this it does.
  #
  # NULL vs 'axis=none' IS THE WHOLE POINT and they are not the same fact. NULL means
  # this build never recorded it (a pre-DIVE-2615 row). 'axis=none' means the floor
  # RAN and did not fire. Conflating them is exactly what made the existing column
  # unusable — an empty value that means both "no data" and "no hit" measures nothing.
  local _floor_prov=""
  if [[ "$tier" == "2" ]]; then
    # Tier 2 BEFORE the floor is consulted, and the two ways of getting there are
    # different facts about different people, so they get different values.
    # `pinned` is the caller's explicit --tier=2 — a LARGE population (12 of the 48
    # tier-2 gates that pinged the human in the 7 days to 2026-08-03) and invisible
    # from the row today, which makes the filer's own choice read as the
    # classifier's doing. `type-default` is manual/secret/access, where 2 is the
    # type's default and nobody chose anything. Reading `tier_arg`, not `tier`, is
    # what separates them: by this line the type default has already been applied,
    # so the effective tier cannot tell them apart — the same distinction DIVE-1182
    # captured `tier_arg` for two lines above.
    if [[ "$tier_arg" == "2" ]]; then _floor_prov="axis=pinned"; else _floor_prov="axis=type-default"; fi
  fi
  if [[ "$tier" != "2" ]]; then
    if [[ "$type" == "secret" ]]; then
      tier=2; tier_floored=1
      _floor_prov="axis=secret-type"
    else
      local ttl_title; ttl_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
      # DIVE-2224: per-field, never the join; and the ASK is the subject (answer A).
      _floor_axis=$(_gate_floor_axis "$ask" "$ttl_title")
      local _floor_term=""
      case "$_floor_axis" in
        ask)  _floor_term=$(_gate_tier2_floor_term "$ask" 2>/dev/null) || _floor_term="" ;;
        title|title-fallback)
          _floor_term=$(_gate_tier2_floor_term "$ttl_title" 2>/dev/null) || _floor_term="" ;;
      esac
      _floor_prov="axis=${_floor_axis}${_floor_term:+;term=${_floor_term}}"
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
      # DIVE-2518: `task_actor ""` rather than `task_actor "$from"`, and the two are
      # now IDENTICAL — task_actor ignores the claim entirely. The empty argument is
      # documentation, not a fix: it says at the call site that no claim is consulted.
      #
      # THIS IS NOT THE ROUTING DECISION, despite the variable name. All four
      # `_*_reviewer` locals in this function only test whether a lead EXISTS, to
      # decide `tier=1`; the reviewer actually persisted to `routed_reviewer` is
      # computed once at the `_routable` block below from `$actor`. I changed these
      # four first believing they were the decision, and a mutant that reverted all
      # four left the T23 arm green — which is how the mistake surfaced.
      local _cc_reviewer; _cc_reviewer=$(_gate_route_reviewer "$(task_actor "")")
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
      local _io_reviewer; _io_reviewer=$(_gate_route_reviewer "$(task_actor "")")   # DIVE-2518: tier-flag only; see note above
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
        # DIVE-2751 iteration 4 (main2): TWO defects on the one line this replaces.
        # `$_dd_residual` occurred exactly ONCE in the whole repo — here — so it
        # has never held a value: under `set -u` the substitution died "unbound
        # variable" and the plain assignment inherited its rc, aborting `task need`
        # with no message on the Rule 3 path. And the term must be read off the
        # residual that ACTUALLY hit; concatenating the two would re-open the
        # phantom seam match the DIVE-2224 comment above forbids, so this mirrors
        # _gate_hit_either's own order (ask first, then title) and absorbs the rc.
        local _dd_term=""
        if _gate_tier2_floor_hit "$_dd_res_ask"; then
          _dd_term=$(_gate_tier2_floor_term "$_dd_res_ask" 2>/dev/null) || _dd_term=""
        else
          _dd_term=$(_gate_tier2_floor_term "$_dd_res_title" 2>/dev/null) || _dd_term=""
        fi
        warn "--discusses REFUSED: this gate names a non-appealable category (matched '${_dd_term}'). Money, outbound customer comms and irreversible infra/access stay hard-human however they are framed. Staying at tier 2."
      else
        local _dd_reviewer; _dd_reviewer=$(_gate_route_reviewer "$(task_actor "")")   # DIVE-2518: tier-flag only; see note above
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

  # DIVE-2012: THE VERIFIER-SCOPING DEAD-END, made visible.
  #
  # The shape: the MAKER of a live maker→verifier loop files a `decision` gate
  # asking the VERIFIER to scope that task's own acceptance criteria — a question
  # whose only correct answerer is that verifier — and the ask NARRATES the work
  # under test, so the T2 category floor fires on the narration. Measured on the
  # ticket's own repro: tier goes to 2, the DIVE-1495 verifier-route below is
  # guarded on `tier != 2` so it never runs, `routed_reviewer` stays NULL, and the
  # DIVE-1117 provenance floor then refuses the verifier's answer. Net: the paired
  # human is pinged for a call that was never theirs AND the designated answerer is
  # locked out. dev's actual remedy on DIVE-1968 was to message olivia out of band.
  #
  # WHY THIS IS A WARNING AND NOT A SIXTH DOWNGRADE CLASS. The ticket asks for an
  # exemption ("routed decision gates should skip the floor"). Building one means a
  # sixth vocabulary guesser, and DIVE-2099's design note is explicit that adding
  # one reproduces this bug with the polarity REVERSED — a false negative there
  # routes a real money/secret ask to whichever agent happens to be grading the
  # ticket, which is the exact defect DIVE-2241 had just closed. The appeal
  # DIVE-2089 shipped is the supported answer and it already lands correctly:
  # `--discusses` downgrades to tier 1, and because the verifier-route below runs
  # AFTER every downgrade class, the gate then routes to the VERIFIER rather than
  # the lead. Measured: tier=1, routed_reviewer=<verifier>, human not pinged.
  #
  # So the residual defect is not the tier — it is that the remedy is INVISIBLE at
  # exactly the moment it is needed. `--discusses` landed after this ticket was
  # filed, the floor's own warning never mentions it, and nothing tells the filer
  # that the agent they are trying to reach is one flag away. An undiscoverable
  # remedy is indistinguishable from no remedy, which is why this ticket exists.
  #
  # The trigger is STRUCTURAL, never vocabulary: a live loop (both ends present),
  # the filer IS the maker, the verifier is someone else, and the type is the one
  # type an appeal exists for. It changes NO tier and NO route — a floored gate
  # still reaches the human, and the floor is untouched. It only ensures the filer
  # is told, on the record, who they were trying to reach and how to reach them.
  if [[ "$tier_floored" == "1" && "$type" == "decision" && "$_discusses_applied" == "0" \
        && "$_curation" == "0" && "$_internal_ops" == "0" && "$_needs_human" == "0" \
        && "$tier_arg" != "2" ]]; then
    local _vs_filer; _vs_filer=$(task_actor "")
    local _vs_vf _vs_mk
    _vs_vf=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${id};")
    _vs_mk=$(db "SELECT COALESCE(maker_agent,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_vs_vf" && -n "$_vs_mk" && "$_vs_vf" != "$_vs_filer" && "$_vs_mk" == "$_vs_filer" ]]; then
      # DIVE-2801 CLASS — do not recommend a remedy the code will refuse. This
      # advice names `--discusses` as the way to reach the verifier, so it may
      # only be printed when the appeal would actually be ACCEPTED. Both of
      # DIVE-2089's refusal paths have to be evaluated here, not assumed:
      #
      #   Rule 3 — the residual still names a non-appealable category (money /
      #   outbound comms / irreversible infra). Measured before this guard
      #   existed: on a `spend` ask the appeal printed `--discusses REFUSED …
      #   Staying at tier 2` and this warning then told the filer to re-file with
      #   `--discusses` — the remedy they had just been refused, on the same
      #   invocation. On that class there is also no dead-end to announce: the
      #   floored gate is CORRECT and the human genuinely is the right answerer,
      #   which is what the safety arm in the harness has always claimed.
      #
      #   Rule 4 — no lead sits above the filer, so the appeal has nobody to
      #   route to and refuses. Promising a route we cannot mint is the same
      #   defect with a different cause.
      #
      # Computed with the appeal's OWN helpers and its own per-field residual, so
      # the two can never drift apart into a warning that predicts the wrong
      # verdict. Silence here is the stock floor warning's job, not a gap.
      local _vs_res_ask _vs_res_title
      _vs_res_ask=$(_gate_floor_appeal_residual "$ask")
      _vs_res_title=$(_gate_floor_appeal_residual "$_ft_title")
      if _gate_hit_either _gate_tier2_floor_hit "$_vs_res_ask" "$_vs_res_title"; then
        _vs_vf=""   # non-appealable: the human keeps this call, say nothing
      elif [[ -z "$(_gate_route_reviewer "$_vs_filer")" ]]; then
        _vs_vf=""   # no reviewer above the filer: the appeal would refuse
      fi
    fi
    if [[ -n "$_vs_vf" && -n "$_vs_mk" && "$_vs_vf" != "$_vs_filer" && "$_vs_mk" == "$_vs_filer" ]]; then
      # ABSORB the rc. `_gate_tier2_floor_term` is an allowlisted rc-bearing
      # contract: it returns non-zero when it finds no term, so a plain
      # assignment inherits that status and dies under `set -e`. Same shape
      # main's DIVE-2751 fix uses two blocks up, and the call-site guard in
      # tests/task_show_exit_code_unit.sh enforces it — that guard landed on
      # main after this block was first written, and caught it on the rebase.
      local _vs_term=""
      _vs_term=$(_gate_tier2_floor_term "$ask" 2>/dev/null) || _vs_term=""
      [[ -n "$_vs_term" ]] || { _vs_term=$(_gate_tier2_floor_term "$_ft_title" 2>/dev/null) || _vs_term=""; }
      warn "this gate is floored to tier 2 (matched '${_vs_term}'), so it pings the paired human and ${_vs_vf} — the verifier on this task's loop, and the only agent who can answer a question about your own acceptance criteria — CANNOT clear it (tier-2 gates refuse a non-human answer, DIVE-1117). If the term is narration of the work under test rather than something you are asking to DO, re-file with --discusses=\"<why>\": the appeal downgrades the gate to tier 1 and routes it to ${_vs_vf}, not to the human. If you really are asking for that, leave it — the human is the right answerer."
      # The dead-end this ticket was filed about was invisible in the record: the
      # gate simply sat there while dev messaged olivia out of band. Audit the
      # occurrence, not just the advice, so the NEXT instance is countable.
      _task_store_audit_log "task need verifier-scoping floored" "warned" 0 -- \
        "task=$ident" "filer=$_vs_filer" "verifier=$_vs_vf" "term=$_vs_term" || true
    fi
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
      local _es_reviewer; _es_reviewer=$(_gate_route_reviewer "$(task_actor "")")   # DIVE-2518: tier-flag only; see note above
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
  if [[ "$type" == "decision" ]] && _gate_option_has_second_person "$options"; then
    warn "--options contains second-person wording whose referent can invert between filer and answerer. Prefer account names (for example, main-runs-task-done|dev3-gets-a-credential). Filing continues; the answer receipt will name filer ${actor} and the concrete answerer (DIVE-2212)."
  fi
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
  # DIVE-2233 item 2 — mint the per-gate human nonce BEFORE the gate is persisted, and
  # refuse to persist it at all if a tier-2 gate cannot arm itself.
  #
  # ORDERING IS THE WHOLE FIX, and getting it wrong was worse than not fixing it. The
  # refusal originally sat after this UPDATE, so a mint failure aborted the command
  # having ALREADY written need_type/ask/tier — leaving exactly the half-armed tier-2
  # gate it refuses to create, while telling the caller it had failed. Caught by arm M2
  # of gate_t2_nonce_proof_unit ("no half-filed gate is left behind"), which is the arm
  # I nearly did not write because the refusal "obviously" prevented the state.
  #
  # WHY IT MUST FAIL CLOSED. An empty mint used to be silent: no UPDATE, hash NULL, gate
  # files normally, no warning and no audit row — indistinguishable from a properly
  # minted gate. Survivable while nothing read the column; NOT survivable once the
  # tier-2 floor treats a NULL hash as "skip the check", because then a box with a
  # broken RNG has no floor while every gate on it still LOOKS protected. That is
  # DIVE-2131 restated. `_human_nonce_verify` already fails closed on a missing hash;
  # the floor inverted that into a fail-open by skipping, so the refusal belongs HERE,
  # where the absence is created, not there, where it is only observed.
  #
  # Scoped to tier 2 deliberately: for the other human types a NULL hash still means
  # what it always meant and DIVE-916's verify path fails closed on it unchanged, so
  # widening this would break gate filing for no security gain. With the /dev/urandom
  # fallback in `_human_nonce_mint`, reaching this refusal means both the CSPRNG and
  # openssl are gone — a broken box, not a routine one.
  # DIVE-2365 (rebase onto DIVE-2356): the condition is "hard-human TYPE **or**
  # tier>=2", NOT `tier == "2"`. This branch and the persist site below were written
  # against different mint conditions on two branches; a string compare misses tier
  # 3+, so the arm-or-refuse decision would cover a NARROWER set than the floor it
  # exists to protect — the fail-open this commit closes, reintroduced one tier up.
  # `_t2` is what the refusal keys on, so it tracks the tier arm alone: a hard-human
  # type at tier 0/1 still files on an empty mint exactly as it always did.
  local human_nonce="" _mint_nonce=0 _t2=0
  case "$type" in approval|secret|manual|access) _mint_nonce=1 ;; esac
  [[ "${tier:-}" =~ ^[0-9]+$ ]] && (( tier >= 2 )) && { _mint_nonce=1; _t2=1; }
  (( _mint_nonce )) && human_nonce=$(_human_nonce_mint)
  if (( _t2 )) && [[ -z "$human_nonce" ]]; then
    # DIVE-2054: DELIBERATELY UNFENCED — a hard gate that could not arm itself is a
    # fleet-health event, and it must leave evidence even though the caller is told.
    audit_log "task need nonce-mint-failed" error 0 -- \
      "task=$ident" "type=$type" "tier=$tier" \
      "reason=could not mint a per-gate human nonce (openssl and /dev/urandom both unusable)" \
      2>/dev/null || true
    fail "$E_GENERIC" "$ident: refusing to file a tier-2 gate that cannot mint its own human proof — openssl and /dev/urandom are both unusable; fix the box's RNG, or file it at a lower --tier"
  fi

  # DIVE-2410: filing REPLACES any gate already on this task (that is what the
  # archive-and-clear is for), so whatever button the OUTGOING gate put in a human
  # chat now asks a question this task no longer holds. Retire BEFORE the new
  # delivery, not after: the delivery log is the input, so once task_need_notify
  # has run, the gate's own fresh button is in there too and would be stripped by
  # its own filing. Order is the correctness condition here, not a preference.
  # DIVE-2848: THE KEYSTROKE CAP. See the block comment above cmd_task_need for the
  # measurement and the rule. Placed HERE, after every floor / downgrade / declaration
  # has had its turn, so the condition reads exactly as "this gate is tier 2 for no
  # reason other than that the filer typed --tier=2": tier_floored==0 excludes the T2
  # category floor AND the --needs re-assert, both of which set it.
  #
  # tier_floored==0 IS NOT "no category applies" ON THIS PATH, and assuming it was
  # is the one way this cap could do damage. The T2 category floor only ever runs
  # to RAISE a tier below 2 — there is nothing for it to raise when the filer typed
  # --tier=2, so a money/secret/destructive gate filed AT tier 2 arrives here with
  # tier_floored still 0, indistinguishable from a rubber stamp. Caught by the
  # money control in tests/gate_recommend_cap_unit.sh (B3), which refused
  # "approve the monthly spend on the paid Hetzner plan". Re-running the classifier
  # here is the fix; reading the flag is not. (The refusal would not have AUTHORISED
  # anything — a re-file at --tier=0 gets floored straight back to 2 — but it would
  # have told an agent holding a genuine spend gate that they were rubber-stamping,
  # which is worse than useless from a cap whose whole claim is that it knows the
  # difference.)
  local _rs_capped=0 _rs_taps=0 _rs_tot=0 _rs_title=""
  _rs_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
  if [[ ( "$type" == "decision" || "$type" == "approval" ) \
        && "$tier" == "2" && "$tier_arg" == "2" && "$tier_floored" == "0" \
        && "$_needs_human" != "1" && -n "$recommend_arg" ]] \
     && ! _gate_hit_either _gate_tier2_floor_hit "$ask" "$_rs_title"; then
    read -r _rs_taps _rs_tot <<<"$(_gate_tapback_stats "$actor")"
    if [[ -z "$rubber_stamp" ]]; then
      _task_store_audit_log "task need rubber-stamp-cap" "refused" 0 -- \
        "task=$ident" "filer=$actor" "type=$type" "recommend=$recommend" \
        "tapbacks=${_rs_taps}/${_rs_tot}" "reason=tier-2 with a recommendation and no declared capability" || true
      fail "$E_VALIDATION" "$ident: refusing this --tier=2 ${type} gate. You wrote --recommend=\"${recommend}\", which means you have already decided — what is left is asking a person to agree, and that is reassurance, not a gate. (Measured 2026-07-16..08-07: 96 of 107 judgment gates carrying a recommendation came back as the human tapping that same value. Only 7 gates in 346 were floored by category; the rest of tier 2 was typed by hand.) A tier is a CAPABILITY, not a difficulty. Your exits:
  --tier=0    apply \"${recommend}\" NOW. No ping, and still a permanent gate record plus a digest line. This is the exit you want on a decision you have already made — it was used 0 times in the 346 gates measured, which is a discoverability failure, not a missing feature.
  --tier=1    route to your lead, or to this task's verifier if it carries a loop — except a push-for-review ask, which goes to the LEAD even on a loop, because the verifier cannot read the diff until it is pushed (DIVE-3117); the 48h TTL applies your recommendation if nobody answers. Use it when you want a second pair of eyes, not a person's authority.
  --needs=human_tap|spend_authority|secret_provision    DECLARE the human-held capability this ask consumes (a person's call on brand/strategy, money, or a credential only a human can issue). Tier 2 by declaration, never refused here.
  --rubber-stamp-ok=\"<why a person must answer this despite your recommendation>\"    the audited exception. Recorded on the gate row and readable afterwards.
If you cannot name the capability, this is a decision you find uncomfortable, not a human gate."
    fi
    # The escape exists for an EXCEPTION. Rate-limit the CLASS, not just the
    # instance (ticket item 3): past the cap, the exception IS the pattern, and the
    # only honest exit left is naming a capability. Fail-open below the minimum
    # sample — a new filer with no history must not inherit a refusal.
    if (( _rs_tot >= _GATE_TAPBACK_MIN && _rs_taps > _GATE_TAPBACK_MAX_TAPS )); then
      _task_store_audit_log "task need rubber-stamp-cap" "refused-rate" 0 -- \
        "task=$ident" "filer=$actor" "type=$type" "tapbacks=${_rs_taps}/${_rs_tot}" \
        "declared=$rubber_stamp" || true
      fail "$E_VALIDATION" "$ident: refusing this --tier=2 ${type} gate AND its --rubber-stamp-ok escape. ${_rs_taps} of your last ${_rs_tot} human-answered gates that carried a recommendation came back as the human tapping that same value; the cap is ${_GATE_TAPBACK_MAX_TAPS} in ${_GATE_TAPBACK_WINDOW}. The escape is for an exception, and at this rate it is your pattern. Remaining exits: --tier=0 (apply \"${recommend}\" now, no ping, permanent record), --tier=1 (lead/verifier, TTL applies the rec), or --needs=<capability> if this genuinely consumes something you do not hold. The window is rolling — as those gates age out, the cap lifts on its own."
    fi
    _rs_capped=1
    warn "tier-2 escape ACCEPTED and RECORDED: --rubber-stamp-ok=\"${rubber_stamp}\". You wrote a recommendation and are still sending this to a person; the reason is now on the gate row (task show) and in the audit log, so this exception is countable instead of invisible. Your recent rubber-stamp rate is ${_rs_taps}/${_rs_tot}."
  fi
  if [[ -n "$rubber_stamp" && "$_rs_capped" == "0" ]]; then
    warn "--rubber-stamp-ok changed nothing on this gate — the keystroke cap did not fire (type=${type}, tier=${tier}$( ((tier_floored)) && printf ', floored by category or declaration')). The declaration is still written to the row, so it stays readable; it just did not need to buy anything."
  fi

  _task_gate_retire_buttons "$ident" "superseded by a re-filed gate" || true

  db "BEGIN IMMEDIATE;
      $(_gate_archive_and_clear_sql file "id=${id}")
      UPDATE tasks
        -- DIVE-2624: DO NOT STEAL THE ASSIGNEE off a live maker-to-verifier handoff.
        -- The handoff line in task show is DERIVED (assignee=verifier AND
        -- maker_agent IS NOT NULL AND status NOT IN done/cancelled), so writing
        -- assignee=<filer> unconditionally FALSIFIED THE PREDICATE and the delivery
        -- vanished from the board. Nothing was lost -- handoff_delivered_at was never
        -- touched -- but every reader (task show, the loop board, the stall sweep)
        -- reads the predicate, not the column, so the work sat in the verifier
        -- queue looking un-delivered. Measured on DIVE-2619/DIVE-2594; the
        -- withdraw+re-file was only the filing someone happened to watch, a single
        -- fresh gate does it too.
        --
        -- This is the exact CONVERSE of the handoff_ack_at CASE directly below,
        -- which already asks whether the filer is the verifier of a delivered row.
        -- When the filer IS the verifier this CASE is a no-op by construction
        -- (assignee=verifier=actor), so the only behaviour it changes is the
        -- third-party filing -- which is the one that did the damage.
        --
        -- Column refs on the right of SET are evaluated against the PRE-update row
        -- (same property cmd_task_assign relies on), so this and the ACK CASE below
        -- both see the original assignee regardless of clause order.
        --
        -- The assignee was doing a second job here -- task answer read it to know
        -- who to ping to resume -- so preserving it would have moved the resume ping
        -- onto the verifier. That reader now prefers gate_filed_by, the column
        -- that actually records the filer (see cmd_task_answer). One fact, one
        -- column: the filer is provenance, the assignee is who holds the row.
        --
        -- NO BACKTICKS AND NO DOUBLE QUOTES IN THIS COMMENT, and that is not style.
        -- An SQL comment here is bash-parsed BEFORE sqlite ever sees it, because the
        -- whole statement is one double-quoted bash string: a backtick runs a command
        -- and a double quote ends the string. The first draft of this block did both,
        -- handed sqlite an incomplete statement, wrote NO GATE, and still printed a
        -- successful filing -- which is what the post-write assertion below now
        -- refuses to let happen again.
        -- DIVE-3097: a SECOND, narrower preserve-don't-steal arm, added beside the
        -- DIVE-2624 one above rather than folded into it, because it guards a
        -- different shape. DIVE-2624 protects a LIVE, DELIVERED handoff
        -- (maker_agent set, already routed) from being un-delivered by a
        -- third-party filing. This arm protects a row that was NEVER delivered
        -- at all: if the actor filing this gate happens to be the row's own
        -- verifier, the unconditional ELSE below would set assignee=actor=verifier
        -- while maker_agent is still NULL -- manufacturing FRESH the exact
        -- assignee==verifier, no-handoff-ever-recorded shape DIVE-2899 named
        -- (assignee=dev3, verifier=dev3, delivered_at NULL), via a THIRD writer
        -- neither of this ticket's other two fixes (task add, task assign) can
        -- see, because filing a gate has no ownership check and this column write
        -- is a side effect of it, not its stated purpose. Scoped to assignee<>
        -- verifier so it is a no-op on every row the DIVE-2624 arm or the
        -- DIVE-2196 review-escalation case (assignee=verifier=actor already)
        -- already cover -- this only stops a NEW collision, never touches an
        -- existing one (no retro-grading, same as the rest of DIVE-3097).
        SET status='blocked',
            assignee=CASE
              WHEN maker_agent IS NOT NULL AND verifier IS NOT NULL
                   AND assignee=verifier AND handoff_delivered_at IS NOT NULL
                   AND verifier IS NOT $(sqlq "$actor")
              THEN assignee
              WHEN verifier IS NOT NULL AND verifier=$(sqlq "$actor") AND assignee IS NOT verifier
              THEN assignee
              ELSE $(sqlq "$actor") END,
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
            secret_oob=$(sqlq_or_null "$oob"),
            ask_shape=$(sqlq_or_null "$ask_shape"),
            precedent_ref=${precedent_ref:-NULL},
            precedent_kind=$(sqlq_or_null "$precedent_kind"),
            -- DIVE-2615: why this gate has this tier. Written on the SAME statement
            -- that writes the tier, so the two can never disagree about one filing.
            floor_provenance=$(sqlq_or_null "$_floor_prov"),
            -- DIVE-2241: the capability the filer DECLARED, recorded verbatim —
            -- including one that resolved to nothing. What was claimed is the
            -- provenance; whether it resolved is recomputable from the sealed
            -- list, and a mis-declaration you cannot see is one you cannot correct.
            needs_capability=$(sqlq_or_null "$needs"),
            -- DIVE-2848: the declared reason a gate carrying its own recommendation
            -- still went to a person. The cap's value is that the exception is
            -- COUNTABLE afterwards — an escape that leaves no row is --tier=2 with
            -- extra steps, which is the thing this ticket exists to end.
            gate_rubber_stamp=$(sqlq_or_null "$rubber_stamp"),
            -- DIVE-2354: the declared order (approve-to-send | confirm-after-send).
            -- Written on the SAME statement as need_type, so a row can never hold a
            -- mode belonging to a gate it no longer carries.
            gate_mode=$(sqlq_or_null "$gate_mode"),
            tier=${tier}, need_asked_at=datetime('now'), gate_pinged_at=NULL,
            gate_filed_by=$(sqlq "$actor")
      WHERE id=${id};
      COMMIT;"

  # DIVE-2624: ASSERT THE WRITE LANDED. `db` is not checked anywhere on this path,
  # so a statement sqlite refuses (it prints "Error: in prepare, incomplete input"
  # to stderr and returns) wrote NO gate — and every line below still ran: the
  # ledger recorded gate.filed, the router pinged a reviewer about a question the
  # row does not hold, and the caller was told the gate was filed. That is not a
  # hypothetical: it is how the first cut of the assignee CASE above failed, and
  # nothing in the output distinguished it from success. One cheap read-back turns
  # the whole class (bad SQL, a locked store, a failed BEGIN IMMEDIATE) from a
  # false green into a refusal, BEFORE anyone is notified about it.
  if [[ "$(db "SELECT CASE WHEN status='blocked' AND need_type IS NOT NULL
                             AND need_asked_at IS NOT NULL THEN 1 ELSE 0 END
               FROM tasks WHERE id=${id};" 2>/dev/null)" != "1" ]]; then
    fail "$E_GENERIC" "$ident: the gate write did not land — the task store still shows no filed gate on this row, so nothing has been asked of anyone. Nothing was notified and no ledger entry was made. Re-run; if it repeats, the task store is refusing the write (check for a lock or a schema mismatch with 5dive task show $ident)."
  fi

  # INST-4: the gate is the authority record — who asked whom for permission, at
  # what tier. The ask text is hashed, not stored: a tier-2 ask routinely names
  # the money, the box, or the destructive verb it is asking about.
  ledger_emit gate.filed ident="$ident" task_id="$id" actor="$actor" \
    policy="tier${tier}:${type}" in="$ask" \
    detail="${type} gate filed at tier ${tier}${recommend:+ (recommend: ${recommend})}"

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

  # DIVE-3117: THE ONE GATE CLASS WHERE THE VERIFIER-ROUTE DEFAULT INVERTS ITSELF.
  #
  # A push-for-review ask asks for the branch to be pushed. On a maker→verifier row
  # the DIVE-1495 route above hands that gate to the VERIFIER — i.e. it asks the
  # grader to authorise the push that is the only way the grader can read the diff.
  # quinn stated it exactly on DIVE-2183: cannot approve a push before reading the
  # diff, cannot read the diff until it is pushed. Measured FOUR times on
  # 2026-08-09/10 (DIVE-3113, DIVE-2130, DIVE-2183, DIVE-2192), every one blocking a
  # real push, every one cleared by hand from the root seat.
  #
  # THE TEST AT THE KEYSTROKE: if this gate clears, does the answerer GAIN the thing
  # they needed in order to answer it? If yes, it is a cycle. Route it to the lead —
  # the one seat that can authorise the push and is not the party blocked by it. The
  # verifier still grades the work afterwards; that is `task reject`/`accept`, a
  # different surface, and it is untouched here.
  #
  # WHY THIS IS A FLOOR ON THE ROUTING AXIS AND NOT A ROUTER REWRITE (main's framing,
  # and it is the sharper one). The TIER machinery is correct — DIVE-2629 already put
  # a floor on the tier axis of this exact gate class (branch names stop forcing T2)
  # and it produced tier 1 on all four instances. What was missing is the SIBLING
  # floor, on routing: `floor_provenance=axis=none` on all four, i.e. nothing
  # engaged. DIVE-2629 left routed_reviewer EMPTY (no agent can clear it); this left
  # it equal to the GRADER (the one agent who cannot answer it). Same symptom, and a
  # tier-axis fix cannot reach the second case — which is why 2629 shipping did not
  # prevent four occurrences of 3117 in one day.
  #
  # THE ASK ONLY, never the title (DIVE-2224). A title is written at ticket-creation
  # time to describe a DEFECT; only the ask can be a REQUEST. This very ticket is
  # titled "push-for-review gate routes to the loop VERIFIER…", so a title-reading
  # classifier would strip the verifier off every genuine question filed on it. The
  # negative control is graded in tests/gate_verifier_route_unit.sh.
  #
  # `_gate_push_for_review_hit` fails closed and is the SAME predicate DIVE-2629's
  # tier floor uses, so the two axes cannot disagree about what an inert push is: a
  # push ask that also names a merge/deploy/land-to-main is NOT inert, keeps its
  # existing routing, and keeps flooring on its subject matter.
  local _verifier_route=0 _route_target="" _pfr_lead_route=0
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
      if [[ "$_vf_is_agent" == "1" ]]; then
        if _gate_push_for_review_hit "$ask"; then
          _pfr_lead_route=1
        else
          _verifier_route=1; _route_target="$_vf"
        fi
      fi
    fi
  fi

  # DIVE-3171 — EVERY GATE THE ORG ROOT FILES REACHES THE HUMAN BY CONSTRUCTION.
  #
  # `_gate_route_reviewer` walks UP the chart — reports_to, then the coordinator/root —
  # skipping any candidate equal to the filer. For the ROOT of the chart BOTH candidates
  # are the filer, so the walk falls off the end empty and the gate drops to the human
  # ping. Not intermittently, and not about any one gate's subject: it is every gate the
  # root ever files. DIVE-2612 already wrote the shape down from the FILER's side (its
  # warn text: "for the root of the chart the coordinator fallback resolves to
  # themselves"); this is the routing half of the same fact, which that ticket described
  # and did not fix. lodar, 2026-08-10, in the third week of it: "why still this goes to
  # me????? i was complaining for 3 weeks already".
  #
  # WHAT MAKES IT INVISIBLE: for every other seat the same code is correct, and the root
  # is the one seat that files engineering gates while sitting ABOVE the engineering lead.
  #
  # THE SAME PREDICATE ON BOTH SIDES OF THE SAME DECISION. DIVE-2099 gave a NAMED agent
  # STANDING authority over tier-1 engineering approvals, and `_gate_lead_standing_eligible`
  # already decides whether a given gate is in scope. So `cmd_task_answer` ALREADY knows
  # this gate is lead-clearable while the router does not — and a gate a lead is ALLOWED
  # to clear must not be DELIVERED to a human. The predicate is REUSED verbatim rather
  # than restated: two copies of "is this lead-clearable" are two things that can
  # disagree, and the dangerous direction of disagreement is the router handing an agent
  # a gate the answer path will then refuse.
  #
  # SEALED SOURCE, NEVER THE CHART. The fallback holder is `_gate_standing_lead` — the
  # agent named in the constitution, trusted only while the live bytes still match the
  # digest sealed into the council lineage. `agents_org` is agent-writable on a
  # NOPASSWD:ALL host, which is exactly why DIVE-2099/2233 anchored authority to the seal;
  # resolving THIS fallback from the chart would hand back the self-grant path they closed
  # (re-parent yourself above the root, receive the root's gates). Note the direction the
  # widening runs: the standing lead can ALREADY clear these gates unrouted (the DIVE-2099
  # branch ignores `routed_reviewer` entirely), so this moves who is PINGED and shown the
  # gate, never who may answer it.
  #
  # NARROW, AND FAIL CLOSED THREE WAYS — the ticket's negative arm is "do NOT widen this
  # to route ALL unrouteable gates to the lead":
  #   1. only when the chart resolves NOBODY. A filer who has a lead keeps that lead, and
  #      a `decision` the root files (agent-clearable by type already) is untouched.
  #   2. only when `_gate_lead_standing_eligible` says yes — `approval`, tier exactly 1, a
  #      POSITIVE engineering classification, minus the tier-2 floor and the deny list. A
  #      money/secret/brand/customer-box/tier-2 gate filed by the root still reaches the
  #      human. That is the arm that stops this becoming a way to launder a hard gate past
  #      a person, and it is why the eligibility predicate is the whole condition rather
  #      than a piece of it.
  #   3. only when the seal resolves a plain name that is NOT the filer. Drifted, unsealed,
  #      no `authority.eng_approval_lead` key, an empty value, no council loader in scope,
  #      or the root IS the named lead -> nothing -> the gate falls through to the human
  #      exactly as it does today. Fail closed, same direction as everything it reuses.
  #
  # The verifier route wins where it fired: that gate already has an agent routee, so this
  # is not the "nobody" case.
  #
  # `_sr_unrouteable` / `_sr_outcome` exist so the DECLINING branch is countable too.
  # The three weeks this ticket is about were invisible in the store: an unrouted gate
  # simply pinged the human and left no row saying a route had been ATTEMPTED and refused.
  # A fix that only records its successes leaves the next regression with nothing to count
  # (DIVE-3117's lesson, and its suppression row is the model).
  local _standing_route=0 _standing_target="" _sr_filer="" _sr_unrouteable=0 _sr_outcome=""
  if [[ "$_verifier_route" != "1" ]] && declare -F _gate_standing_lead >/dev/null 2>&1; then
    _sr_filer=$(task_actor "")   # DIVE-2518: the DERIVATION, never the `--from` claim — same line the reviewer resolution below takes, for the same reason (this decides who may later clear).
    if [[ -n "$_sr_filer" && -z "$(_gate_route_reviewer "$_sr_filer")" ]]; then
      _sr_unrouteable=1; _sr_outcome=not-standing-eligible
      local _sr_title; _sr_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
      # DIVE-2224: ask and title as SEPARATE arguments — pre-joining them lets a
      # bounded-distance pattern straddle the seam and GRANT on a phantom hit.
      if _gate_lead_standing_eligible "$type" "$tier" "$ask" "$_sr_title"; then
        _sr_outcome=no-standing-lead
        local _sr_lead; _sr_lead=$(_gate_standing_lead 2>/dev/null || printf '')
        if [[ -n "$_sr_lead" && "$_sr_lead" == "$_sr_filer" ]]; then _sr_outcome=standing-lead-is-filer; fi
        if [[ -n "$_sr_lead" && "$_sr_lead" != "$_sr_filer" ]]; then
          _standing_route=1; _standing_target="$_sr_lead"; _sr_outcome=routed
        fi
      fi
    fi
  fi

  # DIVE-3266: ROUTE ON ROW STATE, NOT ON THE ASK'S PROSE.
  #
  # Every routable KIND above classifies by reading text a human wrote for a human —
  # `_eng_ship` is a regex over the ask and the title, and with gate_builder_routing
  # OFF (the default) it is the ONLY live route for an ordinary builder ship gate.
  # Miss the regex and `routed_reviewer` stays NULL, which is the first clause of
  # cmd_task_inbox's human predicate: an unrouted gate IS a founder gate. Measured
  # 2026-08-11 filing DIVE-3224's own push gate — "open both PRs" lowercases to
  # `prs` and the member is `\bpr\b`, so the word boundary fails on a sentence that
  # was entirely about pushing a branch and opening PRs.
  #
  # A `Branch: <name>` line is the opposite kind of input: STRUCTURED STATE, written
  # deliberately by `task set-branch` / `task add --branch` and validated to a git
  # ref-name there. It is the same binding `5dive push` requires before it will push
  # this row, so a branch-bound row IS a ship handoff whatever the ask's wording is.
  # Read the binding; do not parse prose for it.
  #
  # NOT a widened regex (`prs`, `PR's`, `pull-request`, the next synonym — unbounded,
  # and each addition looks locally correct). This removes the class for rows that
  # already record the answer instead of enlarging the classifier.
  #
  # Scoped to ROUTING ONLY, deliberately. It does NOT feed the DIVE-1359 tier
  # downgrade: tier decides CLEARANCE, routing decides WHO IS WOKEN, and widening a
  # tier control to unblock a routing complaint is how a safety control gets widened
  # mid-ship. Same guards as eng-ship (tier_floored=0, the three routable types), and
  # the DIVE-1957 `--tier=2` veto plus the DIVE-2241 `_needs_human` backstop both run
  # BELOW this line, so a pinned or human-class gate still crosses it untouched.
  # Sibling instance of the same defect, one subsystem over: DIVE-3265, where the
  # merge gate scraped a branch name out of the maker's result prose and then demanded
  # that phantom branch land.
  local _row_ship=0
  if [[ "$tier_floored" == "0" && ( "$type" == "decision" || "$type" == "approval" || "$type" == "manual" ) ]]; then
    local _rowship_body _rowship_branch=""
    _rowship_body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
    # Split rather than `[[ … ]] && v=$(f)`: an assignment's rc is its last command
    # substitution's, so the helper's non-zero on "no binding" would leak into the
    # compound (the DIVE-2751 shape). Absorbed here instead of argued about.
    _rowship_branch=$(_push_branch_from_body "$_rowship_body" 2>/dev/null) || _rowship_branch=""
    [[ -n "$_rowship_branch" ]] && _row_ship=1
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
  # DIVE-3266: a branch-bound row is lead-routed BY ROW STATE, for the same reason
  # eng-ship is by kind — routable-but-pref-gated would leave the human pinged, and
  # who is pinged is the entire complaint.
  [[ "$_row_ship" == "1" ]] && _routable=1
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
  # DIVE-3171: the standing-lead fallback is routable BY KIND, for the same reason
  # eng-ship is — `gate_builder_routing` defaults to OFF, so routable-but-pref-gated
  # would move the ROUTING byte and still ping the human, which is the entire thing the
  # ticket is about. And the root filer cannot reach the eng-ship kind to inherit its
  # bypass: that downgrade only fires when `_es_reviewer` is non-empty, i.e. when a chart
  # lead sits above the filer, which is precisely what the root does not have.
  [[ "$_standing_route" == "1" ]] && _routable=1
  # DIVE-3117: there is deliberately NO `_pfr_lead_route && _routable=1` line here.
  # Suppressing the verifier route is the WHOLE change: the gate then takes the
  # SAME path a push-for-review gate on a row with no loop already takes (eng-ship
  # by kind, or the pref), so the loop's existence stops being an input to routing
  # rather than becoming a second input pointing the other way. That is what the
  # ticket's negative arm asks for, and it is why a no-verifier row keeps its
  # routing byte-for-byte. Adding a line here would give a looped row a route a
  # non-looped one does not have — the eng-ship guards (a resolvable lead, no true-
  # human floor) would be crossed only in the one case that happened to be measured.
  # Graded both ways in tests/gate_verifier_route_unit.sh.
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
  # DIVE-3117: record the suppression AT THE MOMENT IT HAPPENS, with the verifier it
  # would have gone to. The four measured instances were only findable because each
  # left a row naming its routed_reviewer; a fix that silently stops writing that
  # name leaves the next regression with nothing to count. `routed=` says where it
  # went INSTEAD — which is the pre-existing lead/human path, not a new one, so an
  # empty value here is the honest "no lead resolved, this fell through to the
  # human" and is exactly the state the DIVE-2004 warn below is about to explain.
  # DIVE-2054: task-store state for $ident, no channel proof — fenced.
  if [[ "$_pfr_lead_route" == "1" ]]; then
    # Split rather than `[[ … ]] && x=$(f)`: an assignment's rc is its last command
    # substitution's, and _gate_route_reviewer returns non-zero when it resolves
    # nobody — the DIVE-2751 shape, absorbed here instead of argued about.
    local _pfr_dest=""
    if [[ "$_routable" == "1" ]]; then _pfr_dest=$(_gate_route_reviewer "$(task_actor "")") || _pfr_dest=""; fi
    _task_store_audit_log "task need push-for-review verifier-route suppressed" ok 0 -- \
      "task=$ident" "type=$type" "filer=$actor" "verifier=${_vf-}" \
      "routed=${_pfr_dest:-human}" || true
  fi
  # DIVE-3171: one row per gate whose filer the ORG CHART could not route — recorded
  # AFTER the `tier_arg=2` / `_needs_human` backstops, so `routed=` is what actually
  # happened and not what this branch proposed. `outcome=` says which conjunct decided:
  # `routed` (the seal named a lead and it took the gate), `not-standing-eligible` (the
  # tier-2 floor / deny list / non-engineering / wrong type — acceptance arm 2, the human
  # keeps it), `no-standing-lead` (drift, unsealed, absent key — arm 3, fail closed), or
  # `standing-lead-is-filer` (the root IS the named holder; routing to them would be the
  # self-clear path). Without this the declining branches are indistinguishable from a
  # build that never had this code.
  # DIVE-2054: task-store state for $ident, no channel proof — fenced.
  if [[ "$_sr_unrouteable" == "1" ]]; then
    local _sr_routed=human
    [[ "$_standing_route" == "1" && "$_routable" == "1" ]] && _sr_routed="$_standing_target"
    _task_store_audit_log "task need org-root standing-route" ok 0 -- \
      "task=$ident" "type=$type" "tier=$tier" "filer=$_sr_filer" \
      "outcome=$_sr_outcome" "standing_lead=${_standing_target:-<none>}" "routed=$_sr_routed" || true
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
    # DIVE-3266: row-state ship routing bypasses the pref too — a branch binding is a
    # harder fact than any regex hit, so pref-gating it would re-open the exact hole.
    if [[ "$_route" == "on" || "$type" == "access" || "$_eng_ship" == "1" || "$_row_ship" == "1" || "$_curation" == "1" || "$_internal_ops" == "1" || "$_discusses_applied" == "1" || "$_verifier_route" == "1" || "$_floored_by_title" == "1" || "$_standing_route" == "1" ]]; then
      # DIVE-1495: a verifier-route targets the task's verifier directly; every
      # other kind resolves the filer's lead via the org chart.
      local _reviewer
      # DIVE-2518: THIS is the routing decision — the one thing `--from` DECIDED
      # rather than recorded, since routed_reviewer is who may later CLEAR the gate.
      # It takes `task_actor ""` (the derivation) and NOT `$actor`, which carries the
      # claim so that `gate_filed_by` can keep naming a uid-less relay principal.
      # Recording the claim and obeying it are different things, and this is the line
      # where they part. Graded by T23, which seeds two DIFFERENT leads so a claim
      # that won would route somewhere visible.
      # DIVE-3171: the standing-lead fallback resolves from the SEAL, and only in the
      # case the chart already answered "nobody" — so it can never re-point a gate the
      # chart did route.
      if [[ "$_verifier_route" == "1" ]]; then _reviewer="$_route_target"
      elif [[ "$_standing_route" == "1" ]]; then _reviewer="$_standing_target"
      else _reviewer=$(_gate_route_reviewer "$(task_actor "")"); fi
      if [[ -n "$_reviewer" ]]; then
        # Persist the designated reviewer on the row. For approval/manual this is
        # what authorizes agent-<_reviewer> to clear the gate later; for decision
        # it is provenance only (decision is already agent-clearable by type).
        # DIVE-3171: record WHY this reviewer, in the same statement that records WHO.
        # `cmd_task_answer` reads this to decide whether the clear is stamped `lead:`
        # or `lead:standing:`, and the two facts must not be able to arrive separately
        # — a row naming a reviewer with no source is the state this column exists to
        # abolish. NULL therefore means "a build before this one wrote the name", never
        # "the route had no source". Sibling to floor_provenance on the tier axis.
        local _route_prov=chart
        [[ "$_verifier_route" == "1" ]] && _route_prov=verifier-loop
        [[ "$_standing_route" == "1" ]] && _route_prov=seal:standing-lead
        db "UPDATE tasks SET routed_reviewer=$(sqlq "$_reviewer"), route_provenance=$(sqlq "$_route_prov") WHERE id=${id};"
        local _rrole="lead review"; [[ "$_verifier_route" == "1" ]] && _rrole="verifier review"
        # DIVE-3171: name the SEALED fallback distinctly. "lead review" would read as the
        # org chart having resolved somebody, and the whole point of this branch is that
        # it did not — the reader needs to know which source picked this reviewer.
        [[ "$_standing_route" == "1" ]] && _rrole="standing lead review (org root: no chart lead above the filer)"
        # DIVE-2093: the routable cascade above is a DISJUNCTION, so "which clause
        # fired" is a short-circuit artefact and not a fact about the gate. Name the
        # most SPECIFIC kind that applies instead — that is the one the filer can act
        # on. The pref is reported only when no kind applies, because then it really
        # is the only reason this gate routed at all.
        #
        # DIVE-2093 iteration 3 (main2's blocker 2): the standing arm sits at the BOTTOM,
        # immediately above the pref. A specific KIND still wins when one applies — the
        # standing route decides the TARGET, not what made the gate routable — but when
        # no kind applies, `_standing_route` is why this routed and the pref is NOT, so
        # reporting `gate_builder_routing=on` there is the same false-basis defect this
        # row exists to fix, one field over.
        local _rtrigger
        if   [[ "$_verifier_route"   == "1" ]]; then _rtrigger="verifier-route"
        elif [[ "$type"              == "access" ]]; then _rtrigger="access-type"
        elif [[ "$_eng_ship"         == "1" ]]; then _rtrigger="eng-ship"
        # DIVE-3266: BELOW eng-ship on purpose. When the ask/title already read as an
        # eng ship, that is what the filer can act on and every existing receipt stays
        # byte-for-byte; `row-ship-state` is named only when the BINDING is the sole
        # reason this routed — i.e. exactly the case the prose classifier missed.
        elif [[ "$_row_ship"         == "1" ]]; then _rtrigger="row-ship-state"
        elif [[ "$_curation"         == "1" ]]; then _rtrigger="curation"
        elif [[ "$_internal_ops"     == "1" ]]; then _rtrigger="internal-ops"
        elif [[ "$_discusses_applied" == "1" ]]; then _rtrigger="declared-discussion"
        elif [[ "$_floored_by_title" == "1" ]]; then _rtrigger="floored-by-title"
        elif [[ "$_standing_route"   == "1" ]]; then _rtrigger="standing-lead"
        else _rtrigger="gate_builder_routing=on"
        fi
        # DIVE-2093 iteration 3 (main2's blocker 1): the basis is `$_route_prov` ITSELF,
        # not a second variable derived alongside it. The old code kept `_rbasis` as a
        # parallel two-valued lead/verifier flag, so DIVE-3171's THIRD route landed in
        # the catch-all and the prose asserted an `agents_org.reports_to` edge that by
        # construction does not exist — main's own comment four lines up names that exact
        # hazard. One assignment now feeds the DB column and the sentence, so they cannot
        # diverge, and a FOURTH route cannot be added without `_gate_route_why` seeing a
        # basis string it does not know (which it now reports as unknown, not as chart).
        local _rwhy
        _rwhy=$(_gate_route_why "$_route_prov" "$_reviewer" "$(task_actor "")" "$_rtrigger")
        # DIVE-2093 (2026-08-07 recurrence, DIVE-2808): the sharper variant. Routing
        # reached a principal who could ANSWER and could not SIGN, which is worse than
        # the original "could not act", because it fails SILENTLY at answer time and
        # surfaces on somebody ELSE's command — the board shows an APPROVED gate whose
        # authorization no privileged path will honour, and a closed-unsigned gate looks
        # DONE where a pending-on-the-wrong-person one at least looks unfinished.
        #
        # DIVE-2760 already warns the ANSWERER when the mint comes back empty, and that
        # notice fires correctly. It shortens the loop, it does not close it: by then a
        # diff has been read and an answer given. Filing is the only point at which
        # nobody has yet acted, so this is where the check belongs.
        #
        # Deliberately narrow (DIVE-1955 wallpaper): require_sig is 1 only on the push
        # and deploy root executors, so this fires only when the ask is push/deploy
        # shaped. It is a warn and never a `fail` — the same reasoning as DIVE-2760's
        # write: a gate no broker will ever check is unharmed by an unsigned closure,
        # and refusing the filing would cost more than the misroute does.
        local _rsig="" _cs="" _csv="" _csc=""
        if _gate_eng_ship_hit "$ask" || [[ "$_eng_ship" == "1" ]]; then
          _cs=$(_gate_seat_can_sign "$_reviewer"); _csv="${_cs%%|*}"; _csc="${_cs#*|}"
          case "$_csv" in
            yes) _rsig=" [require_sig: ${_reviewer} can sign this closure (grant=${_csc})]" ;;
            no)
              _rsig=" [require_sig: ⚠ ${_reviewer} CANNOT sign this closure (grant=${_csc}) — see the warning above]"
              warn "$ident routed to $_reviewer, who CANNOT MINT A CLOSURE SIGNATURE (sudo grant: ${_csc})."
              warn "  This ask is push/deploy shaped, and the root-only executor verifies the"
              warn "  DIVE-756 signed closure before any delegated push or deploy."
              warn "  what happens if you leave it: $_reviewer can ANSWER the gate and the board"
              warn "    will show it APPROVED — but need_answer_sig lands EMPTY, and the push is"
              warn "    REFUSED later, on the MAKER's command, reading as tampering rather than"
              warn "    as this (DIVE-2760/2808). 'task answer' is not a re-sign verb, so the"
              warn "    only repair at that point is to re-file the gate from scratch."
              warn "  fix: get it answered from a seat that signs — root (\`sudo 5dive task answer"
              warn "    $ident ...\`) or an agent whose grant is root-all/cli-root; --tier=2 if it"
              warn "    is genuinely the human's. Do NOT grant \`gate-proof sign\` to a cli-scoped"
              warn "    seat: it signs arbitrary stdin, so the grant forges ANY closure, human:* included."
              ;;
            *) _rsig=" [require_sig: whether ${_reviewer} can sign is NOT MEASURABLE from this seat (grant=${_csc}) — unknown, not a no; check it first if a delegated push is refused later]" ;;
          esac
        fi
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
        # DIVE-2751 iteration 4 — decided explicitly rather than left as "guarded in
        # practice". An assignment's rc is its LAST command substitution's, so
        # `[[ test ]] && v="...$(f)..."` hands f's status to the compound with the
        # test TRUE. `_ft_title` is the text that just matched, so the helper does
        # return 0 here — but "in practice" is exactly the reasoning the previous
        # three iterations got wrong, and this false rc arrives from the RHS, where
        # no detector that classifies the LEFT side of `&&` can ever see it. Split
        # so the status is absorbed instead of argued about.
        local _fbt="" _fbt_term=""
        if [[ "$_floored_by_title" == "1" ]]; then
          _fbt_term=$(_gate_tier2_floor_term "$_ft_title" 2>/dev/null) || _fbt_term=""
          _fbt=" [floored_by=title: the T2 category floor matched '${_fbt_term}' in the TASK TITLE, not in the ask — escalate to the human if the ask really is asking for that]"
        fi
        ok "$ident routed to $_reviewer for ${_rrole} ($type, tier $tier)${_rnote}${_fbt}${_rsig} [${_rwhy}] — $ask" \
           '{id:($i|tonumber), ident:$id, status:"blocked", need_type:$ty, tier:($tr|tonumber), routed_to:$rv, route_basis:$rb, route_trigger:$rt, require_sig_seat:(($cs|select(length>0)) // null), delivery:$ds, notified:($ds=="delivered"), ask:$ak, recommend:(($rc|select(length>0)) // null)}' \
           --arg i "$id" --arg id "$ident" --arg ty "$type" --arg tr "$tier" --arg rv "$_reviewer" --arg ds "$_rstate" --arg ak "$ask" --arg rc "$recommend" \
           --arg rb "$_route_prov" --arg rt "$_rtrigger" --arg cs "$_csv"
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
  #
  # DIVE-2612 extends this, and it is two separate defects — both found by grading
  # DIVE-2610, a tier-1 eng-ship APPROVAL filed by the org root that came out
  # unrouted, pinged the human, and could then be lead-cleared by nobody.
  #
  #   1. THE SCOPE WAS INVERTED. An unrouted `decision` is answerable by ANY agent;
  #      an unrouted `approval`/`manual` is answerable by NO agent — cmd_task_answer's
  #      provenance floor makes those types human-only, and routed_reviewer is the
  #      SOLE basis for the designated-reviewer exception to it. The warning fired
  #      for the recoverable case and stayed silent for the unrecoverable one.
  #   2. THE REMEDY TEXT WAS FALSE FOR THE ONE FILER IT COULD NOT HELP. "Re-file
  #      with --type=approval (it routes to the org lead ...)" assumes the org
  #      resolver returns somebody. For the ROOT of the org chart it never can:
  #      _gate_route_reviewer tries reports_to, then _task_resolve_coordinator, and
  #      skips any candidate equal to the filer — and absent a literal
  #      role='coordinator' row the coordinator IS the unique root, so both
  #      candidates are the filer and it falls off the end empty. Following that
  #      advice would move the root from "clearable by any agent" to "clearable by
  #      none". So the clause is now printed ONLY when the resolver returns a name.
  #
  # The approval/manual arm is scoped to `_routable=1` on purpose. A tier-2 floored
  # or human-class-declared gate is human-only BY DESIGN, and announcing that there
  # would be the wallpaper DIVE-1955 warns about. This fires only where human-only
  # is an ACCIDENT of the resolver coming back empty.
  local _u_warn=0
  if _gate_eng_ship_hit "$ask"; then
    case "$type" in
      decision)        _u_warn=1 ;;
      approval|manual) [[ "$_routable" == "1" ]] && _u_warn=1 ;;
    esac
  fi
  if (( _u_warn )); then
    # Resolved here rather than reused from `_es_reviewer`: that one is set only
    # inside the eng-ship downgrade block (tier_floored=0, ask-OR-title hit), so it
    # is unset on paths that reach here — and an unset remedy predicate is exactly
    # the defect being fixed.
    local _u_filer _u_reviewer _u_msg
    _u_filer=$(task_actor "")
    _u_reviewer=$(_gate_route_reviewer "$_u_filer")
    local _u_noroute="the org chart resolves no reviewer for ${_u_filer} (for the root of the chart the coordinator fallback resolves to themselves), so re-filing will not route it either"
    if [[ "$type" == "decision" ]]; then
      _u_msg="$ident is a push-for-review ask filed as --type=decision with no routed reviewer, so '5dive push' will REFUSE it: an unrouted decision can be answered by any agent, and push only accepts a human, a lead-clear, or a decision answered by this gate's own routed reviewer."
      if [[ -n "$_u_reviewer" ]]; then
        _u_msg+=" Re-file with --type=approval (it routes to $_u_reviewer as a tier-1 they can clear), or keep the decision and route it to a reviewer."
      else
        _u_msg+=" Do NOT re-file it as --type=approval: ${_u_noroute} — and an unrouted approval can be cleared by NO agent at all, only by the paired human. Keep the decision (any agent can answer it) or route it to a reviewer explicitly."
      fi
    else
      _u_msg="$ident is a push-for-review ask filed as --type=$type with no routed reviewer, so NO AGENT CAN CLEAR THIS GATE — it is human-only. approval/manual are human-only unless routed, and routed_reviewer is the sole basis for the designated-reviewer exception in 'task answer', so this gate now sits on the paired human and no agent can lift it."
      if [[ -n "$_u_reviewer" ]]; then
        _u_msg+=" $_u_reviewer is your reviewer in the org chart but this gate did not route to them — re-file as --type=decision (lead-clearable by design) if a lead can resolve it."
      else
        _u_msg+=" ${_u_noroute}; --type=decision is the only shape any agent could clear."
      fi
    fi
    warn "$_u_msg"
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
  # THE EMIT HALF NOW LANDS ALONGSIDE THIS (DIVE-2233 item 2). An earlier draft of
  # this comment said the nonce was "not yet reachable by a decision TAP" and
  # deferred it as a plugin-side ticket. `_task_gate_reply_markup` now appends
  # `:${nonce}` to the decision option buttons too, and the answer path verifies it
  # (see the tier-2 floor in cmd_task_answer). What made that safe rather than a
  # plugin break is graded in gate_t2_nonce_proof_unit S12b/S12e: the DEPLOYED
  # TNA_RE accepts the wider callback_data unchanged, and the fork scan reads each
  # tna.ts variant's OWN on-disk regex rather than assuming. Two forks (opencode,
  # pi) still parse the option token greedily and would swallow the nonce — they
  # are named, fenced by that arm, and tracked, not silently shipped past.
  #
  # STILL NOT DONE HERE, and this is the part that must stay undone: refuse a
  # tier-2 answer whose human_nonce_hash IS NULL. The floor is scoped to gates that
  # HAVE a nonce (S16), so every gate already in flight keeps clearing. See the
  # ORDERING note above — refuse-on-NULL waits for tier-2 decisions to accumulate
  # nonces in the wild.
  # THE MINT ITSELF HAS MOVED UP (DIVE-2054 ordering fix, above the first tasks UPDATE):
  # a tier-2 gate that cannot arm itself must refuse BEFORE any row is written, not after.
  # Only the persist survives here.
  [[ -n "$human_nonce" ]] \
    && db "UPDATE tasks SET human_nonce_hash=$(sqlq "$(_human_nonce_sha "$human_nonce")") WHERE id=${id};"
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
    # DIVE-2751: `_gate_tier2_floor_term` is trailing-test-terminated — it returns 1
    # when it finds no term — so this PLAIN assignment made "the floor fired but the
    # helper could not name the word" kill `task need` under `set -e`. The helper's
    # own rc contract is left alone (a value producer may report "no match"); the
    # call site absorbs it, exactly as the two sites at _floor_term above already do.
    floor_term=$(_gate_tier2_floor_term "${ask} $(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")") || floor_term=""
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
  # DIVE-3266: SAY THAT IT DID NOT ROUTE, AND NAME THE AXIS THAT DECIDED.
  #
  # Reaching here means routed_reviewer is NULL, and an empty routed_reviewer is the
  # FIRST clause of cmd_task_inbox's human predicate — so this gate is the paired
  # human's. The routed arm has printed WHO and WHY since DIVE-2093; this arm printed
  # a cheerful `OK — <id> needs a human (approval, tier 1)` and nothing else, so the
  # only difference between "routed to your lead" and "landed on the founder" was a
  # clause that ISN'T THERE. A reader cannot see an absent clause, and `--tier=1` is
  # no protection: tier and routing are separate axes and only routing keeps a gate
  # off the founder. Measured on DIVE-3224 (both receipts in this row's body).
  #
  # This is the cheap half of the fix and it is the half that generalises: it cannot
  # make the classifier right, but it converts a SILENT miss into a visible one, for
  # every miss including the ones no row-state binding can catch. Unconditional on
  # purpose — the DIVE-1955 wallpaper test asks whether a warning fires where nothing
  # is wrong, and here nothing is ever "not wrong": the founder is being woken every
  # time this line prints, and the reasons differ, so the reason is the payload.
  local _nr_reason
  if [[ "$_needs_human" == "1" ]]; then
    _nr_reason="a human-class capability was declared (--needs=${needs}), which resolves to the human by constant, not by lookup"
  elif [[ "$type" == "secret" ]]; then
    _nr_reason="secret gates are human-only by type and never route"
  elif [[ "$tier_floored" == "1" ]]; then
    _nr_reason="the T2 category floor fired${floor_term:+ on '${floor_term}'}, and a floored gate is human-only by class"
  elif [[ "$tier_arg" == "2" ]]; then
    _nr_reason="you passed --tier=2, a hard-human contract no routing kind may cross"
  elif [[ "$_routable" != "1" ]]; then
    _nr_reason="a $type at tier $tier is not routable by type"
  else
    # Routable, and it still did not route. Both remaining causes are invisible at
    # the filing site, and they take OPPOSITE remedies — re-word vs. do not bother.
    local _nr_rev _nr_pref
    _nr_rev=$(_gate_route_reviewer "$(task_actor "")") || _nr_rev=""
    _nr_pref=$(_task_pref_get gate_builder_routing); _nr_pref="${_nr_pref:-off}"
    if [[ -z "$_nr_rev" ]]; then
      _nr_reason="the org chart resolves no lead above $(task_actor "") (for the chart's root the coordinator fallback resolves to themselves), so re-wording or re-filing will not route it either"
    else
      _nr_reason="no routing kind matched — the ask and the row TITLE did not read as an eng ship, and this row carries no 'Branch:' binding — and gate_builder_routing is ${_nr_pref}, so ${_nr_rev} was never considered. Bind the branch (5dive task set-branch ${ident} <branch>) or say 'push-for-review'/'pull request' in the ask, then re-file"
    fi
  fi
  local _nr_note=" [NOT ROUTED — no lead was named, so this gate sits on the PAIRED HUMAN: ${_nr_reason}]"
  ok "$ident needs a human ($type, tier $tier)${floor_note}${prec_note}${unnotified_note}${_nr_note} — $ask" \
     '{id:($i|tonumber), ident:$id, status:"blocked", need_type:$ty, tier:($tr|tonumber), tier_floored:($fl=="1"), floor_term:(($ft|select(length>0)) // null), needs_capability:(($nc|select(length>0)) // null), needs_human:($nh=="1"), rubber_stamp_ok:(($rs|select(length>0)) // null), notified:($nf=="1"), routed_to:null, route_declined:$rd, ask:$ak, need_options:(($op|select(length>0)) // null), recommend:(($rc|select(length>0)) // null), precedent_ref:(($pr|select(length>0)|tonumber?) // null), assignee:$ac}' \
     --arg i "$id" --arg id "$ident" --arg ty "$type" --arg tr "$tier" --arg fl "$tier_floored" --arg ft "$floor_term" --arg nc "$needs" --arg nh "$_needs_human" --arg rs "$rubber_stamp" --arg nf "$notified" --arg rd "$_nr_reason" --arg ak "$ask" --arg op "$options" --arg rc "$recommend" --arg pr "$precedent_ref" --arg ac "$actor"
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
    fail "$E_AUTH_REQUIRED" "$ident: a channel resolved above ${filer:-the filer} but the send was not confirmed — delivery UNVERIFIED, not refused"
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

# DIVE-2412: the Bot API seam for a channel citation, isolated in ONE function so
# a unit harness can drive every branch of the verifier below with no network and
# no bot token. Every attestation call goes through here.
_gate_channel_api() { # <token> <method> [curl -d args...]
  local token="$1" method="$2"; shift 2
  curl -sS --max-time 15 "https://api.telegram.org/bot${token}/${method}" "$@" 2>/dev/null
}

# DIVE-2412 (DIVE-2382 fix #4): CITED-MESSAGE channel proof — the evidence form a
# TIER-2 gate accepts, so a decision the human already made in prose clears
# WITHOUT re-entering it as a button tap (the rubber-stamp lodar refused
# 2026-07-29 01:06).
#
# WHY THE DIVE-1305 FORM IS NOT ENOUGH HERE, said plainly because the ticket's
# premise reads the other way: _gate_channel_proof_ok proves the cited CHAT is the
# paired human's own verified DM. It does NOT prove the human said anything. The
# chat id is a number the calling agent's own session already knows, so on its own
# it is exactly the agent-relayed assertion this must refuse ("he told me").
# At tier<2 that weaker bar is lodar's deliberate scope; at tier 2 it is not
# evidence, so tier 2 requires a CITATION on top: the message_id of the human's
# OWN message, attested by TELEGRAM rather than by us.
#
# THE ATTESTATION IS REMOTE, which is the entire reason the caller cannot forge
# it. The plugin and the agent share a unix user, so NO local artifact separates
# them — same uid, same cgroup, same files (community/wiki/
# the-dashboard-t2-clear-and-the-t2-forge-are-one-path.md). What an agent cannot do
# is make Telegram's servers claim a message exists that does not: forwardMessage
# on the cited id returns the message's forward_origin (who really sent it) and its
# original date. The forwarded echo is deleted immediately — this is a probe, not a
# post.
#
# FOUR CONDITIONS, all required, each with its own refusal reason:
#   1. the chat is the paired human's verified DM (the DIVE-1305 anchor),
#   2. Telegram confirms the cited message EXISTS in that chat,
#   3. its forward origin is a USER whose id is that chat's human — a bot's own
#      message and a third party both refuse (in a DM the human's user id IS the
#      chat id), and a privacy-HIDDEN origin refuses because it attests nobody,
#   4. it is FRESH (<= 3600s, a HARDCODED ceiling — see below) and it NAMES BOTH
#      this task's ident and this answer, so neither a stale "yes" nor a live one
#      about another gate can be replayed onto this one.
# Anything unresolvable — no token, no response, malformed JSON — REFUSES. The
# ticket's rule is explicit and is the whole boundary: if a verified-session
# message cannot be told apart from an agent's report of one, refuse.
#
# THE FRESHNESS BOUND IS NOT THE CALLER'S TO SET, and the shared-value replay is
# closed by BINDING, not by the window. Iteration 1 shipped both the other way
# round and olivia's reject measured the consequence: the window was read from
# GATE_CHANNEL_SESSION_MAX_AGE in the environment of the agent that runs
# `task answer`, and the residual note named that window as what bounded a replay
# of a non-unique value — a mitigation set by the party it defends against. Now
# the ident is REQUIRED (a value is unique to no gate; an ident is unique to one)
# and the env knob can only TIGHTEN a hardcoded 3600s ceiling. What remains is
# genuinely residual: a human message naming this ident and this value, inside the
# hour, cited for this gate, is the human answering this gate.
#
# Sets TASK_CS_REASON (why refused), TASK_CS_ORIGIN, TASK_CS_AGE. Returns 0 only
# when all four conditions hold.
_gate_channel_session_ok() { # <chat_id> <message_id> <answer_value> <ident>
  local chat="$1" msg="$2" bind="$3" ident="$4"
  TASK_CS_REASON="" TASK_CS_ORIGIN="" TASK_CS_AGE=""
  # (1) same trust anchor as DIVE-1305 — and it resolves TASK_CH_TOKEN for us.
  if ! _gate_channel_proof_ok "$chat"; then
    TASK_CS_REASON="chat $chat is not this bot's paired-human DM (not in access.json allowFrom)"
    return 1
  fi
  if [[ ! "$msg" =~ ^[0-9]+$ ]]; then
    TASK_CS_REASON="--channel-msg is not a numeric Telegram message id"
    return 1
  fi
  if [[ -z "${TASK_CH_TOKEN:-}" ]]; then
    TASK_CS_REASON="no readable bot token for this channel, so the citation cannot be attested — refused rather than assumed (fail closed)"
    return 1
  fi
  # (2) does Telegram say this message exists in that chat? The forward is the
  # probe; its own copy is deleted right after, whatever the verdict below.
  local resp; resp=$(_gate_channel_api "$TASK_CH_TOKEN" forwardMessage     -d "chat_id=${chat}" -d "from_chat_id=${chat}" -d "message_id=${msg}" -d "disable_notification=true")
  if [[ -z "$resp" ]]; then
    TASK_CS_REASON="the Bot API returned nothing for forwardMessage (unreachable) — the citation is UNVERIFIED, not accepted"
    return 1
  fi
  local _echo_id; _echo_id=$(jq -r '.result.message_id // empty' <<<"$resp" 2>/dev/null)
  if [[ -n "$_echo_id" ]]; then
    _gate_channel_api "$TASK_CH_TOKEN" deleteMessage -d "chat_id=${chat}" -d "message_id=${_echo_id}" >/dev/null 2>&1 || true
  fi
  if ! jq -e '.ok == true' <<<"$resp" >/dev/null 2>&1; then
    local _desc; _desc=$(jq -r '.description // "no description"' <<<"$resp" 2>/dev/null || echo "unparseable response")
    TASK_CS_REASON="Telegram refused the citation (${_desc}) — message ${msg} is not a live message in chat ${chat}"
    return 1
  fi
  # (3) WHO sent it. forward_origin is Telegram's attribution, not the caller's.
  local otype osender odate otext
  otype=$(jq -r '.result.forward_origin.type // empty' <<<"$resp" 2>/dev/null)
  osender=$(jq -r '.result.forward_origin.sender_user.id // empty' <<<"$resp" 2>/dev/null)
  odate=$(jq -r '.result.forward_origin.date // empty' <<<"$resp" 2>/dev/null)
  otext=$(jq -r '.result.text // .result.caption // ""' <<<"$resp" 2>/dev/null)
  TASK_CS_ORIGIN="${otype:-none}:${osender:-none}"
  if [[ "$otype" != "user" ]]; then
    TASK_CS_REASON="the cited message's forward origin is '${otype:-absent}', not a named user — no human sender is attested (a hidden-origin forward attests nobody)"
    return 1
  fi
  if [[ "$osender" != "$chat" ]]; then
    TASK_CS_REASON="the cited message was sent by user ${osender:-unknown}, not by the paired human of chat ${chat} — the bot's own messages and any third party are refused"
    return 1
  fi
  # (4) FRESH, and about THIS gate.
  if [[ ! "$odate" =~ ^[0-9]+$ ]]; then
    TASK_CS_REASON="the cited message carries no usable timestamp, so its freshness cannot be established"
    return 1
  fi
  # THE BOUND MUST NOT COME FROM THE CALLER (olivia, iteration-1 reject). This
  # window is what stops a stale human line being replayed onto a newer gate, and
  # the caller of `task answer` IS the agent — so reading it straight from the
  # environment made the mitigation settable by the party it defends against, with
  # no forgery needed. Measured on 8312851: a 400-day-old "approved" in the human's
  # own chat refused at the default (rc=6, gate open) and CLEARED under
  # GATE_CHANNEL_SESSION_MAX_AGE=999999999 (rc=0, human_evidence=channel-session) —
  # a row affirmatively attesting a human cleared a tier-2 gate nobody touched.
  # So the ceiling is hardcoded here and the env knob may only TIGHTEN it: a
  # deployment that wants a stricter window still gets one, while wider, zero,
  # negative and non-numeric all fall back to the ceiling itself.
  local _ceil=3600 _max="${GATE_CHANNEL_SESSION_MAX_AGE:-}"
  if [[ ! "$_max" =~ ^[0-9]+$ ]] || (( _max <= 0 || _max > _ceil )); then _max=$_ceil; fi
  local _now _age
  _now=$(date +%s)
  _age=$(( _now - odate )); (( _age < 0 )) && _age=0
  TASK_CS_AGE="$_age"
  if (( _age > _max )); then
    TASK_CS_REASON="the cited message is ${_age}s old (limit ${_max}s) — a stale human message must not be replayed onto a newer gate"
    return 1
  fi
  # WHICH GATE, AND WHICH ANSWER — both, not either (olivia, iteration-1 reject).
  # The first cut cleared on the answer value OR the ident, and each alone leaves a
  # hole: the VALUE is not unique (an ordinary "approved"/"yes" fits any number of
  # open gates, which is the shared-value replay the window was wrongly asked to
  # bound), and the IDENT alone attests only that the human spoke ABOUT this gate —
  # `--value` still comes from the agent, so a human writing "DIVE-x, no" would
  # clear it with value=yes. The ident is unique per gate and the value is the
  # decision, so tier 2 requires the message to carry both. An empty `--value`
  # (a bare approval) requires the ident alone, because there is no answer string
  # to corroborate. tier<2 callers who want the loose form already have the
  # citation-free DIVE-1305 chat-only path, so nothing is lost by making this one
  # strict for everybody.
  local _hay _nv _ni
  _hay=$(printf '%s' "$otext" | tr '[:upper:]' '[:lower:]')
  _nv=$(printf '%s' "$bind" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  _ni=$(printf '%s' "$ident" | tr '[:upper:]' '[:lower:]')
  if [[ -z "$_ni" || "$_hay" != *"$_ni"* ]]; then
    TASK_CS_REASON="the cited message does not name ${ident}, so it is not attributable to THIS gate — the answer value alone is not unique to one gate"
    return 1
  fi
  if [[ -n "$_nv" && "$_hay" != *"$_nv"* ]]; then
    TASK_CS_REASON="the cited message names ${ident} but not the answer ('${bind}'), so it does not attest WHICH answer the human gave"
    return 1
  fi
  return 0
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

# ---- DIVE-2410: retire a settled gate's buttons -----------------------------
#
# THE DEFECT. A gate's approve button outlived its gate. Confirmed on DIVE-2400:
# two buttons delivered (03:20:02Z message_id=15491, 04:05:02Z message_id=15492,
# both via=marketing), gate closed 04:28:41Z, and NOTHING edited, disabled or
# expired either keyboard. From the close onward there were two live-LOOKING
# approve buttons in the human's chat for a question already settled.
#
# WHY THAT IS A DEFECT AND NOT COSMETIC. A tap on a closed gate correctly records
# nothing. But the human gets no error, no "already closed", no visual change, so
# the only conclusion available to them is that they approved. The record and the
# human's belief diverge, and the human has no way to see it — the same class of
# harm as DIVE-2406 approached from the other side (there the record claimed an
# approval nobody gave; here the human believes an approval the record lacks).
# Read a human's frustration with a control as data about the control: lodar's
# "I tap the approve again. wtf is the human gate. I hate it" is the symptom.
#
# The plugin's `tna:` handler ALREADY answers a stale tap with a toast and strips
# the keyboard (server.ts, resolveTnaAnswer -> already/nogate). That is the wrong
# layer to rely on alone, for two reasons: it fires only if the human taps (so
# until then the chat keeps showing a live control), and a toast is a 2-second
# mobile banner that is genuinely easy to miss. The button must stop LOOKING
# tappable at CLOSE time, from the process that did the closing.
#
# WHY THIS LIVES IN THE CLI. Gates close from paths with no Telegram session at
# all: `task answer` on the dashboard, a lead-clear, `task need --withdraw`,
# `task park`, the verifier's auto:reject, a done/cancel that moots an open gate.
# Every one of those runs here. A plugin-side fix cannot cover any of them.

# The token for the bot that CARRIED a delivery. Deliberately NOT
# _task_agent_channel: that clobbers TASK_CH_* (token, access, type, agent),
# which live callers are mid-flight on — _task_close_notify sends through those
# globals and retirement can run beside it. We need only the token, and
# connector files are the same group-claude-readable source _task_agent_channel
# reads, so read it directly and leave the globals alone.
# via=<agent> matters and is not decorative: message_id is scoped to a bot-chat
# PAIR, so editing 15491 with the wrong bot's token edits a different message or
# nothing (DIVE-2073 is why the delivery row carries `via` at all).
_task_gate_bot_token() { # <agent-name> -> token on stdout
  local name="${1:-}" token="" f
  if [[ -n "$name" && "$name" != "none" ]]; then
    f="${CONNECTORS_DIR}/telegram-${name}.env"
    [[ -r "$f" ]] && token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$f" | head -1)
  fi
  [[ -n "$token" ]] || token="${TELEGRAM_BOT_TOKEN:-}"
  printf '%s' "$token"
}

# Every button-bearing message this task's gate put in a human chat, as
# chat<TAB>message_id<TAB>via, deduped. The set is already knowable: the
# gate-delivery log records chat + message_id + via per delivery, which is
# exactly what DIVE-2410 needs and nobody had read back yet.
#
# Four exclusions, each for its own reason — a wrong row here edits a message
# that was never this gate's:
#   result=error rows      no message exists to edit (message_id is empty).
#   message_id 0 / none    a dry-run receipt or an ok-without-id; not a real message.
#   chat=agent:<name>      the maker->verifier handoff leg (see the reviewer-ping
#                          delivery rows). An agent inbox, not a Telegram chat.
#   another task's ident   `tasks=` is a COMMA LIST — the re-nag batches several
#                          gates into one message. Match a whole field, never a
#                          substring, or DIVE-24 retires DIVE-2410's button.
# A batched message covering a still-open gate is retired too, and that is
# correct-but-blunt: its keyboard carries a button per task, and the Bot API
# cannot remove one button without rebuilding the whole markup. Losing a live
# button is recoverable — the re-nag re-delivers pending gates — while leaving a
# settled one tappable is the bug being fixed. Noted, not silently accepted.
_task_gate_deliveries() { # <ident>
  local ident="$1"
  local logf="${FIVEDIVE_GATE_NOTIFY_LOG:-}"
  [[ -n "$logf" ]] || logf=/var/log/5dive/notify/gate-notify.log
  if [[ ! -r "$logf" ]]; then
    # Make the absence observable ONCE per process. This log is the ONLY record of
    # which messages a gate put in a human's chat, so if it cannot be read the
    # retirement is a total silent no-op — every settled button stays tappable and
    # nothing anywhere says so. It is 0664 today, but "unreadable" and "no
    # deliveries" must never share an answer in a function whose failure mode is
    # invisible (the DIVE-1927 absent-vs-forbidden rule, one layer over).
    if [[ -e "$logf" && -z "${_TASK_GATE_RETIRE_BLIND:-}" ]]; then
      _TASK_GATE_RETIRE_BLIND=1
      warn "cannot read the gate-delivery log ($logf) — settled gates' buttons cannot be retired from this process, so a closed gate may keep showing a live approve button (DIVE-2410)."
    fi
    return 0
  fi
  awk -v want="$ident" '
    /gate-delivery result=ok/ {
      tasks=""; chat=""; mid=""; via=""
      for (i = 1; i <= NF; i++) {
        if      (substr($i, 1, 6)  == "tasks=")      tasks = substr($i, 7)
        else if (substr($i, 1, 5)  == "chat=")       chat  = substr($i, 6)
        else if (substr($i, 1, 11) == "message_id=") mid   = substr($i, 12)
        else if (substr($i, 1, 4)  == "via=")        via   = substr($i, 5)
      }
      if (chat == "" || chat == "none" || chat ~ /^agent:/) next
      if (mid == "" || mid == "none" || mid == "0") next
      n = split(tasks, T, ",")
      for (j = 1; j <= n; j++) if (T[j] == want) { print chat "\t" mid "\t" via; next }
    }
  ' "$logf" 2>/dev/null | awk -F'\t' '!seen[$1 FS $2]++'
}

# Strip the inline keyboard off every message that delivered this gate. Call it
# AFTER the settling write has committed, always best-effort: a gate is settled
# by the DB row, and a Telegram edit that fails must never unsettle it or fail
# the caller's command.
#
# FENCE. Same rail as the send whose message it edits — refuse unless the active
# store is the prod store (_task_human_send_allowed, the DIVE-1506 positive
# allowlist), EXCEPT when the dry-run quarantine is on, which is the one case a
# harness can exercise this end to end while being physically unable to reach
# Telegram (_mirror_edit_markup enforces that itself). An opt-in-only fence is
# the mistake DIVE-1968 removed; this is store identity first, as there.
_task_gate_retire_buttons() { # <ident> <why>
  local ident="$1" why="${2:-gate closed}"
  local _dry=0
  [[ -n "${FIVEDIVE_NOTIFY_DRYRUN:-}" && "${FIVEDIVE_NOTIFY_DRYRUN}" != "0" ]] && _dry=1
  if ! _task_human_send_allowed && (( ! _dry )); then
    return 0
  fi
  local rows; rows=$(_task_gate_deliveries "$ident") || return 0
  [[ -n "$rows" ]] || return 0
  local chat mid via token resp ok desc result
  while IFS=$'\t' read -r chat mid via; do
    [[ -n "$chat" && -n "$mid" ]] || continue
    token=$(_task_gate_bot_token "$via")
    if [[ -z "$token" ]]; then
      # Name the miss. A retirement that cannot resolve the delivering bot leaves
      # a tappable button behind, which is the defect — so it is a row, not a
      # shrug. (Reachable when the delivering agent was torn down after filing.)
      _task_store_audit_log "gate button retire" "error" 1 -- \
        "task=$ident" "chat=$chat" "message_id=$mid" "via=${via:-none}" \
        "detail=no bot token for delivering agent; button left live" || true
      continue
    fi
    resp=$(_mirror_edit_markup "$token" "$chat" "$mid") || resp="${resp:-}"
    ok=$(jq -r '.ok // false' <<<"$resp" 2>/dev/null) || ok=false
    desc=$(jq -r '.description // empty' <<<"$resp" 2>/dev/null) || desc=""
    result=error
    if [[ "$ok" == "true" ]]; then
      result=ok; desc="keyboard removed"
    elif [[ "$desc" == *"not modified"* || "$desc" == *"message to edit not found"* ]]; then
      # Already un-tappable — the end state we wanted, reached without us.
      result=ok
    fi
    _task_store_audit_log "gate button retire" "$result" \
      "$([[ "$result" == "ok" ]] && echo 0 || echo 1)" -- \
      "task=$ident" "chat=$chat" "message_id=$mid" "via=${via:-none}" \
      "why=$why" "detail=${desc:-unconfirmed Bot API edit}" || true
    [[ "$result" == "ok" ]] || warn "$ident: could not retire the gate button on message $mid in chat $chat (${desc:-unknown}) — a settled gate may still show a live approve button there."
  done <<<"$rows"
  return 0
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

# DIVE-3077 — the same fail-closed store-identity idea, applied to the board WRITE
# path. On 2026-08-09 the prod board read 128 open rows of which 98 were test
# fixtures filed that same day by three agents (`prose A`-`prose E`, `stamp arm
# C/D/E`), burying a 27-row real backlog. The cost was not the count, it was
# occlusion: a backlog you cannot read is one you cannot triage.
#
# WHY THIS IS NOT `! _task_human_send_allowed`, which is the obvious edit and is
# wrong. That predicate refuses on EITHER a marker OR a non-prod store, because a
# human send from a fixture store is never wanted. A board WRITE from a fixture
# store into that fixture's OWN throwaway DB is the normal, correct case — it is
# what nearly every harness in the corpus does. Inverting the send predicate here
# would refuse all of them. The write rail cares about exactly one combination:
# a run that has DECLARED itself a test, writing to the REAL production store.
#
#   refuse  <=>  (a test/harness marker is set)  AND  (the active TASKS_DB is the
#                                                      real prod board)
#
# WHY THE PROD PATH HERE IGNORES FIVEDIVE_PROD_TASKS_DB, which is the one real
# asymmetry with the send predicate and is deliberate. That variable exists so a
# harness can DECLARE its own fixture store to be "prod" and exercise the send
# predicate's allowed arm — 29 harnesses in the corpus do exactly that. A fence
# that lets the caller redefine the thing it is protecting is fail-open by
# construction, and honouring it here would refuse those 29 harnesses' own writes
# to their own throwaway stores. The defect this closes was 98 fixture rows landing
# on ONE file, so this fence names that file.
#
# THE SEAM, and why it is a SECOND variable rather than reusing the one above.
# tests/task_board_write_fence_unit.sh must drive `task add` end to end against
# "the prod board" to grade that the fence is WIRED and not merely correct. With
# no seam its only option is to point TASKS_DB at the real board — and the arm
# that grades "the fence refuses" then WRITES A REAL FIXTURE ROW the moment the
# fence regresses. That is not hypothetical: it happened during this ticket's own
# mutation testing and put DIVE-3082/3083/3084 on the live board. A guard whose
# test reproduces, on its failure path, the exact defect the guard exists to
# prevent is worse than no test. FIVEDIVE_FENCE_PROD_DB is set by that harness and
# by nothing else; unset, this resolves to the real board, which the harness
# asserts before it uses the seam.
# Returns 0=allow, 1=refuse.
_task_real_prod_tasks_db() { printf '%s' "${FIVEDIVE_FENCE_PROD_DB:-/var/lib/5dive/tasks/tasks.db}"; }
_task_board_write_allowed() {
  [[ -n "${FIVEDIVE_HARNESS:-}" || -n "${FIVEDIVE_NO_HUMAN_SEND:-}" \
     || -n "${COUNCIL_MOCK:-}" || -n "${FIVEDIVE_E2E:-}" \
     || -n "${FIVEDIVE_TEST:-}" ]] || return 0
  local active prod ra rp
  active="${TASKS_DB:-${STATE_DIR:-/var/lib/5dive}/tasks/tasks.db}"
  prod="$(_task_real_prod_tasks_db)"
  ra="$(readlink -f "$active" 2>/dev/null || printf '%s' "$active")"
  rp="$(readlink -f "$prod" 2>/dev/null || printf '%s' "$prod")"
  [[ -n "$ra" && "$ra" == "$rp" ]] && return 1
  return 0
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
# DIVE-2799: the evidence form was ALREADY named — in the wrong place.
#
# DIVE-2412 named it in `tasks.human_evidence`, which is the right fact in a
# column that cannot answer the question this row asks. That column is ONE cell on
# ONE mutable row: a re-answer overwrites it, `_gate_archive_and_clear_sql` clears
# it when the gate retires, and it is not a history at all — so "grep separates the
# evidence forms ACROSS HISTORY" (DIVE-2799 acceptance clause 3) is unanswerable
# from it, for every gate that has since been retired or re-answered. The
# append-only audit log is the only sink with that property, and it carried the
# per-form BOOLEANS but never the form's NAME.
#
# WHY THE BOOLEANS ARE NOT ALREADY THE ANSWER, which is the substance and not a
# style preference. A reader asking "which form cleared this?" had to AND together
# `nonce_valid`/`sudo_nonagent`/`channel_session`/`cs_ok`/`cp_ok` — a DIFFERENT
# subset at each of the two audit sites, and a subset that has grown over time.
# That makes the answer PATH-DEPENDENT: a sweep keyed on a field under-counts by
# exactly the paths that log a different arg set, and a query against a field that
# did not exist yet returns a confident zero. Both failures happened inside this
# very row's own measurement (main's five, then olivia's 37-as-a-floor).
#
# THIS FUNCTION IS EXTRACTED FROM the DIVE-2412 inline block at the write site,
# not written beside it. Two vocabularies for one fact is the DIVE-2777 shape this
# ticket explicitly warns about — a class fixed at the call sites someone happened
# to be looking at. The token spelling is therefore UNCHANGED and load-bearing:
# `nonce`, `sudo-uid`, `channel-session`, `channel-chat`, `lead`, `+`-joined in
# this order, `none` when empty. The column and the log now say the same word for
# the same thing, so a historical sweep can join them.
#
# THE VALUE IS EXACT-MATCHABLE ON PURPOSE. In the JSON audit log each arg is its
# own array element, so `grep '"evidence=nonce"'` — WITH the closing quote —
# selects the sole-nonce class and does NOT prefix-match
# `evidence=nonce+channel-session`. Never reorder the tokens or vary the
# separator: a historical sweep compares string literals across months of rows.
#
# WHAT THIS DOES **NOT** BUY, stated here because the field name invites the
# stronger reading. It does not separate a relayed human tap from a
# filer-presented nonce. It cannot: the deployed Telegram plugin's tap sends
# `--human --human-proof=<nonce>` and nothing else, so the two are byte-identical
# AT THE INPUT and no CLI-side field can tell them apart. What it buys is that the
# nonce-only class stops being a reconstruction and becomes a fact the row states
# about itself — which is what makes the population countable and a floor legible
# AS a floor.
_gate_evidence_form() { # <nonce> <sudo_uid> <channel_session> <channel_chat> <lead>
  local out=""
  if [[ "${1:-0}" == "1" ]]; then out+="${out:++}nonce"; fi
  if [[ "${2:-0}" == "1" ]]; then out+="${out:++}sudo-uid"; fi
  if [[ "${3:-0}" == "1" ]]; then out+="${out:++}channel-session"; fi
  if [[ "${4:-0}" == "1" ]]; then out+="${out:++}channel-chat"; fi
  if [[ "${5:-0}" == "1" ]]; then out+="${out:++}lead"; fi
  printf '%s' "${out:-none}"
}

# DIVE-2799: the one discriminator that IS available CLI-side — is the caller
# answering a gate IT filed? `gate_filed_by` is written in the same transaction
# as the gate, so the filer of record is not the caller's to choose at answer
# time. `filer_answered=1` does not mean a forge (a legitimate relayed tap runs
# under the paired agent's own uid and will read 1 too); `filer_answered=0`
# means the answer came from a DIFFERENT principal than the one holding the
# minted proof, which is the strictly narrower and more exonerating case. Recorded
# because it is the only field on this rail that can ever exonerate, and a control
# that cannot exonerate is as broken as one that cannot convict.
# Falls back to `unknown` on a pre-DIVE-1958 row with gate_filed_by NULL — never
# to `0`, which would read as a positive finding it has not measured.
_gate_filer_answered() { # <task id> <caller os user>
  local _f; _f=$(db "SELECT COALESCE(gate_filed_by,'') FROM tasks WHERE id=${1};")
  if [[ -z "$_f" ]]; then printf 'unknown'; return; fi
  if [[ "${2#agent-}" == "$_f" ]]; then printf '1'; else printf '0'; fi
}

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
    warn "refused a human task-send — the active task DB is not the prod DB; set FIVEDIVE_PROD_TASKS_DB if this IS prod"
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
# _task_secret_gate_cta <ident> <row_id> <secret_key> <connector> <drop> — DIVE-2411.
# The "how do I clear this" instruction for a secret gate, extracted from the
# notify body so the PROSE is testable. Four shapes, in order of how directly the
# value can land: a minted burnable drop link, the on-box `secret write` (link
# unavailable / tokenless box), an explicitly declared out-of-band channel, and —
# for rows filed before this ticket — no delivery path at all, where the only
# honest instruction is that the gate must be re-filed. That last branch used to
# read "put the key where I expect it (my .env / our channel), then tap ✅
# Provided", which on a gate that never named a target asks the human to do
# something undefined and then attest to it; that attestation is what produced
# the DIVE-2232 record — signed, nonced, human-attested, empty.
_task_secret_gate_cta() {
  local ident="$1" numid="$2" secret_key="$3" connector="$4" _drop="$5"
  if [[ "$_drop" == "ONBOX" ]]; then
    printf '%s' "🔑 [${ident}] needs the ${secret_key} credential. On the box, drop it straight in (never paste it here):"$'\n'"  echo -n \"\$SECRET\" | sudo 5dive secret write ${secret_key} --connector=${connector} --task=${ident}"$'\n'"That writes it and clears this gate. Or tap ✅ Provided once it is done."
  elif [[ -n "$_drop" ]]; then
    local _url="${_drop%%|*}" _ttl="${_drop##*|}"
    printf '%s' "🔑 [${ident}] needs the ${secret_key} credential. Drop it securely (single-use, expires in ${_ttl}m):"$'\n'"${_url}"$'\n'"The value goes straight onto your box and is never shown in chat. Prefer the box? echo -n \"\$SECRET\" | sudo 5dive secret write ${secret_key} --connector=${connector} --task=${ident}"
  elif [[ -n "$secret_key" && -n "$connector" ]]; then
    # Target named, mint unavailable (api unreachable / tokenless): still name the
    # target, because the box-side write is a real delivery path.
    printf '%s' "🔑 [${ident}] needs the ${secret_key} credential. The drop link could not be minted right now, so put it in on the box (never paste it here):"$'\n'"  echo -n \"\$SECRET\" | sudo 5dive secret write ${secret_key} --connector=${connector} --task=${ident}"$'\n'"That writes it and clears this gate. Or tap ✅ Provided once it is done."
  else
    local _oob; _oob=$(db "SELECT COALESCE(secret_oob,'') FROM tasks WHERE id=${numid};" 2>/dev/null || echo "")
    if [[ -n "$_oob" ]]; then
      printf '%s' "🔑 [${ident}] needs a credential, delivered out-of-band: ${_oob}. Put it there, then tap ✅ Provided below — never paste it in this chat. Tap not working? On the box: sudo 5dive task answer ${ident}"
    else
      printf '%s' "⚠️ [${ident}] asks for a credential but names NO delivery path (no drop target, no declared out-of-band channel), so there is nowhere for the value to go and this gate cannot be cleared as it stands. Do NOT paste the credential here. It has to be re-filed with a delivery path: 5dive task need ${ident} --type=secret --secret-key=<ENV_NAME> --connector=<stem> --ask=\"…\" (DIVE-2411)."
    fi
  fi
}

_task_gate_reply_markup() { # <row_id> <type> <options> <recommend> <nonce> <channel_type> [label]
  local numid="$1" need_type="$2" options="$3" recommend="$4" human_nonce="$5" channel_type="$6" label="${7:-}"
  [[ -n "$label" ]] && label="[${label}] "
  local np=""; [[ -n "$human_nonce" ]] && np=":${human_nonce}"
  local reply_markup=""
  if [[ "$channel_type" =~ ^(claude|codex|grok|antigravity)$ ]]; then
    if [[ "$need_type" == "decision" && -n "$options" ]]; then
      # DIVE-2233: the decision buttons now carry the per-gate nonce suffix too, exactly
      # like approval/secret/manual. This is what makes a tier-2 decision tap PROVABLE
      # rather than merely asserted — the raw nonce goes into callback_data, which the
      # agent LLM never sees, and comes back as --human-proof.
      #
      # NO PLUGIN CHANGE IS NEEDED, and that is a measured fact, not an assumption: the
      # deployed contract is `TNA_RE = /^tna:(\d+):([^:]+)(?::([0-9a-f]{32}))?$/`, whose
      # nonce group is generic over the token — it was never conditioned on the gate type.
      # Verified against the INSTALLED artifacts (telegram 0.5.35 and 0.5.36 under
      # ~/.claude/plugins/cache), not just the plugins repo. The emitter here was the only
      # type-conditional half of the contract. `$np` is empty for gates that mint no nonce,
      # so the callback_data is byte-identical to today's for every one of them.
      reply_markup=$(printf '%s' "$options" | jq -Rc --arg id "$numid" --arg r "$recommend" --arg p "$label" --arg np "$np" '
        ($r | gsub("^\\s+|\\s+$"; "")) as $rr
        | [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ] as $o
        | ($o | to_entries
           | sort_by(.value == $rr and ($rr|length)>0 | not)
           | reduce .[] as $e ({rows: [], cur: [], w: 0};
               (($e.value | length) + (if $e.value == $rr and ($rr|length)>0 then 2 else 0 end)) as $len
               | {text: ($p + (if $e.value == $rr and ($rr|length)>0 then "⭐ " + $e.value else $e.value end)), callback_data: ("tna:" + $id + ":" + ($e.key | tostring) + $np)} as $btn
               | if (.cur | length) > 0 and ((.cur | length) >= 3 or (.w + $len + 2) > 24)
                 then {rows: (.rows + [.cur]), cur: [$btn], w: $len}
                 else {rows: .rows, cur: (.cur + [$btn]), w: (.w + $len + 2)}
                 end)
           | .rows + (if (.cur | length) > 0 then [.cur] else [] end)) as $kb
        | if ($kb | length) > 0 then {inline_keyboard: $kb} else empty end' 2>/dev/null) || reply_markup=""
    elif [[ "$need_type" == "approval" ]]; then
      local rl; rl=$(printf '%s' "$recommend" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
      # DIVE-2354: on a confirm-after-send gate the button that says "Approve" is
      # asking for a claim the human cannot truthfully make — the action is already
      # out. Only the LABELS change; callback_data stays byte-identical
      # (tna:<id>:approved|denied), so every shipped plugin handler is untouched.
      local _bm; _bm=$(db "SELECT COALESCE(gate_mode,'') FROM tasks WHERE id=${numid};" 2>/dev/null || echo "")
      local _yes="✅ Approve" _no="🚫 Deny"
      if [[ "$_bm" == "confirm-after-send" ]]; then _yes="✅ Confirm (after the fact)"; _no="🚫 Not authorised"; fi
      local appr='{"text":"'"${label}${_yes}"'","callback_data":"tna:'"${numid}"':approved'"${np}"'"}'
      local deny='{"text":"'"${label}${_no}"'","callback_data":"tna:'"${numid}"':denied'"${np}"'"}'
      case "$rl" in
        approve|approved) appr='{"text":"'"${label}"'⭐ '"${_yes}"'","callback_data":"tna:'"${numid}"':approved'"${np}"'"}'
                          reply_markup='{"inline_keyboard":[['"$appr"','"$deny"']]}' ;;
        deny|denied)      deny='{"text":"'"${label}"'⭐ '"${_no}"'","callback_data":"tna:'"${numid}"':denied'"${np}"'"}'
                          reply_markup='{"inline_keyboard":[['"$deny"','"$appr"']]}' ;;
        *)                reply_markup='{"inline_keyboard":[['"$appr"','"$deny"']]}' ;;
      esac
    elif [[ "$need_type" == "secret" ]]; then
      # DIVE-2411: the ✅ Provided affordance is offered ONLY on a secret gate that
      # names a delivery path — a drop target (secret_key+connector) or an explicit
      # --out-of-band declaration. On a gate with neither, the button MEANS
      # something the message never asked for: "I already put it where you said",
      # on a gate that never said where. Measured on DIVE-2232 — a real human
      # holding the raw nonce tapped it, and the row came back answered, signed,
      # nonced and uid-stamped over an EMPTY payload. Nothing had landed anywhere.
      #
      # THE FIX IS HERE, at the mint/affordance layer, and that placement is the
      # point: the tap that produced the false record landed on a BATCHED six-gate
      # message, and the batcher has no idea what any of the six drops targeted. It
      # could not have known to withhold the button, so it cannot be the layer that
      # decides. This function is called by BOTH the single-gate notify and the
      # batch re-send, and it reads the row, so both are covered without either
      # caller changing.
      #
      # Read from the ROW, not from a parameter: the state that decides is the
      # persisted gate, not what a caller happens to be holding (DIVE-2090).
      local _sk_row _oob_row
      _sk_row=$(db "SELECT COALESCE(secret_key,'')||COALESCE(connector,'') FROM tasks WHERE id=${numid};" 2>/dev/null || echo "")
      _oob_row=$(db "SELECT COALESCE(secret_oob,'') FROM tasks WHERE id=${numid};" 2>/dev/null || echo "")
      if [[ -n "$_sk_row" || -n "$_oob_row" ]]; then
        reply_markup='{"inline_keyboard":[[{"text":"'"${label}"'✅ Provided","callback_data":"tna:'"${numid}"':provided'"${np}"'"}]]}'
      else
        reply_markup=""
      fi
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
  # DIVE-2354: a ratification must not arrive looking like a prior approval — the
  # chat message IS the record the human answers from. Read from the ROW, not from a
  # parameter (DIVE-2090, same reason the secret branch below does): the batch
  # re-send calls this with whatever it happens to be holding.
  local _gmode
  _gmode=$(db "SELECT COALESCE(gate_mode,'') FROM tasks WHERE id=${numid};" 2>/dev/null || echo "")
  local text="🙋 [${ident}] needs you"
  if [[ "$_gmode" == "confirm-after-send" ]]; then
    text="↩︎ [${ident}] needs you to CONFIRM AN ACTION ALREADY TAKEN"
    text+=$'\n'"This is a RATIFICATION, not a prior approval — the action has already happened. Confirming records that you signed it off after the fact; denying records that you did not."
  fi
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
      # DIVE-2411: the CTA text is a FUNCTION (_task_secret_gate_cta) rather than
      # four inline branches, so the prose can be graded. The remedy half of a fix
      # normally ships with the zero coverage that let the bug in — and here the
      # prose IS half the fix: on a gate with no delivery path the old copy said
      # "put the key where I expect it, then tap ✅ Provided", which is an
      # instruction to do the impossible followed by the button that files the
      # false record. See tests/secret_gate_delivery_path_unit.sh arms T8/T8b.
      text+=$'\n\n'"$(_task_secret_gate_cta "$ident" "$numid" "$secret_key" "$connector" "$_drop")"
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
    # First message pings; the rest arrive silently.
    if (( first_sent )); then export FIVEDIVE_NOTIFY_SILENT=1; fi
    _task_send_owner "$gate_text" "$markup" "$id"
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
    _task_send_owner "…and $(( total - cap )) more gate(s) — 5dive task inbox on the box, or the dashboard." "" ""
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

# DIVE-2572: does a loop-gate answer BOUNCE to the previous step, or ADVANCE?
#
# THE DEFECT THIS REPLACES: five BARE SUBSTRING tests over the whole free-text
# answer — *"better"*, *"reject"*, *"deny"*, *"denied"*, *"declin"*. Any answer
# containing those letters ANYWHERE was classified as a bounce, whatever it
# actually decided.
#
# MEASURED ON THE LIVE BOARD before choosing a fix, because the row asked for
# that rather than a hunch: 268 answered gates, 14 carry a trigger substring. Of
# the answers that are a HUMAN decision on a loop-shaped row, FIVE OF FIVE would
# have been misclassified as bounces, and every one of them APPROVES:
#   DIVE-2552  "approve — ..."      trigger: "uppercase is rejected" (what a regex does)
#   DIVE-2565  "approve — ..."      trigger: "deny-by-default flow"  (a design pattern's NAME)
#   DIVE-2596  "approve — ..."      trigger: "See my reject feedback on this task"
#   CNCL-9     "clear-now ..."      trigger: "the rebase I filed in the reject"
#   DIVE-1572  "a — render inline"  trigger: "B rejected:" (naming the option NOT chosen)
# The only true denials in the whole set are the bare word "denied" (DIVE-1513,
# DIVE-1614) — short, leading, unambiguous.
#
# THE FAILURE IS SYSTEMATIC, NOT RANDOM, and that is what settles the design: an
# approval that RESOLVES a previous bounce naturally cites that bounce ("see my
# reject feedback", "the rebase I filed in the reject"), and a decision between
# options names the option it turned down ("B rejected"). So the reviewer doing
# the most careful job — referring back to what they asked for — is the one most
# likely to be read as bouncing. Option (d) from the row ("prose answers are the
# exception") is refuted by the same data: prose is what substantive answers ARE.
#
# SO: read the decision out of the DECISION SEGMENT (option (b)) — the first
# non-blank line up to the first em-dash, colon, semicolon, comma or stop — and
# warn rather than silently choose when a trigger appears later in the prose.
#
# Option (a), anchoring to the leading TOKEN, was built first and refuted by the
# existing suite: task_answer_cancelled_loop_bounce_unit went 5/7 on the fixture
# "Do better ↩", an ordinary bounce whose decision word is the SECOND token.
# Short imperatives are the register a real bounce is written in, so the leading
# token trades one systematic miss for another. Recorded because it generalises:
# the measurement above sampled only FALSE POSITIVES and said nothing about what
# TRUE bounces look like, and the true-bounce shape is what killed design (a).
#
# THREE THINGS INHERITED FROM THE SAME DEFECT ONE FILE OVER (DIVE-2614,
# community/wiki/a-verdict-regex-scans-every-line-not-the-verdict.md), applied
# here deliberately rather than rediscovered:
#   1. WORD BOUNDARY. Without \b, "deny" prefix-matches nothing useful but
#      "better" matches "betterment" and "decline" matches "declined" only by
#      accident of stemming.
#   2. INFLECTIONS ARE ENUMERATED BY HAND. With \b, `reject` no longer matches
#      "rejected" — that gap has now been confirmed three times in this codebase.
#      Collapsing to (reject|deny|declin)(e|es|ed|ing)?\b is NOT equivalent: it
#      re-admits stems we never intended. Any new stem needs its forms added here.
#   3. FIRST NON-BLANK LINE, NOT LINE 1. A leading blank line would otherwise
#      make the verdict read empty — and empty means ADVANCE here, i.e. a false
#      APPROVE, which is the worse direction and exactly the trap main caught in
#      review on DIVE-2614. `|| true` because grep exits 1 on an all-blank value
#      and pipefail would kill the caller.
#
# "better" is kept, but only inside the decision segment. Unanchored it was the
# worst arm in the set ("approve, this is better than the alternative" bounced);
# in a decision segment it is a real bounce signal ("better: rework it", "Do
# better").
#
# THE SAFETY PROPERTY THIS RELIES ON IS ABOUT SEGMENTS, NOT ABOUT FIRST WORDS, and
# it is measured rather than assumed (olivia's reject, iteration 1 — the earlier
# comment claimed "no answer on the board STARTS with it", which is a different
# and weaker claim than the code needs). Swept all 268 answered gates on the live
# board and extracted each one's decision segment: exactly TWO carry any stem at
# all — DIVE-1513 and DIVE-1614, both the bare word "denied", both true denials —
# and ZERO carry "better". So on the entire recorded population this rule fires
# twice and is right both times.
# Note the scope: that is a statement about answers ALREADY WRITTEN, not a
# guarantee about future phrasing. It is why the advisory below exists.
#
# Returns 0 for BOUNCE, 1 for ADVANCE. Sets _LOOP_BOUNCE_AMBIGUOUS=1 when the
# answer ADVANCES but carries a trigger word later on, so the caller can say so.
_LOOP_BOUNCE_STEMS='reject|rejects|rejected|rejecting|deny|denies|denied|denying|decline|declines|declined|declining|better'
_loop_answer_is_bounce() {
  local _v="${1:-}" _first="" _seg=""
  _LOOP_BOUNCE_AMBIGUOUS=0
  _first=$(printf '%s' "$_v" | grep -m1 -v '^[[:space:]]*$' || true)
  _first="${_first#"${_first%%[![:space:]]*}"}"
  # THE DECISION SEGMENT: the first non-blank line, cut at the first em-dash,
  # colon, semicolon, comma or sentence stop. Everything after that is the
  # REASONING, and the reasoning is where the false positives live.
  _seg="${_first%%[—:;,.]*}"
  if printf '%s' "$_seg" | grep -qE "\b(${_LOOP_BOUNCE_STEMS})\b"; then
    return 0
  fi
  # Advancing — but say so when the vocabulary appears anywhere, rather than
  # silently choosing. This is the compatibility window: it surfaces the real
  # population before anything is gated on it
  # (community/wiki/a-control-partitions-a-population-and-populations-drift.md).
  printf '%s' "$_v" | grep -qE "\b(${_LOOP_BOUNCE_STEMS})\b" && _LOOP_BOUNCE_AMBIGUOUS=1
  return 1
}

# ── DIVE-3128: a button tap, attributed and recorded ─────────────────────────
#
# WHO the tapping Telegram uid IS. Resolution order, widest evidence first:
#
#   1. ${STATE_DIR}/humans.json  — `{"humans": {"<tg-uid>": "<name>"}}`. An
#      explicit operator-maintained map. It is the only source that can give a
#      person the name the org actually calls them, so it wins.
#   2. the Telegram @username carried on the SAME callback. Telegram owns this
#      field; the relaying bot cannot set it for someone else. Shape-checked to
#      Telegram's own handle grammar so nothing exotic reaches a provenance
#      string.
#   3. `tg:<uid>` — the honest non-answer.
#
# RUNG 3 IS THE POINT OF THE LADDER, not its fallback embarrassment. The defect
# this closes is a row that named the WRONG principal, not a row that named
# nobody: `human:tg:1234567890` says "a person we have not put a name to tapped
# this", which a reader can act on, and it cannot collide with a roster name
# because agent names are bare tokens and this one carries a colon. There is
# deliberately no rung that falls back to the RELAYING AGENT'S name — that rung
# is precisely DIVE-3045.
#
# The map file is read at CALL time, not resolved at source time, so a harness
# that sets STATE_DIR after sourcing (every harness in tests/) points at its own
# fixture rather than the box's.
_gate_tap_human_name() {
  local uid="${1:-}" uname="${2:-}" mapped=""
  [[ "$uid" =~ ^-?[0-9]{1,20}$ ]] || { printf ''; return 1; }
  local map="${HUMANS_MAP:-${STATE_DIR}/humans.json}"
  if [[ -r "$map" ]]; then
    mapped=$(jq -r --arg u "$uid" '(.humans[$u] // empty)' "$map" 2>/dev/null || true)
    # A mapped value still has to be a plain token: this string is about to be
    # concatenated into `human:<name>` and stored as provenance, and a mapping
    # file carrying `lodar human:root` would forge a second field.
    [[ "$mapped" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,31}$ ]] && { printf '%s' "$mapped"; return 0; }
  fi
  uname="${uname#@}"
  # Telegram's own handle rule: 5-32 chars, letters/digits/underscore, letter
  # first. Same grammar cmd_telegram_resolve_handle validates against.
  [[ "$uname" =~ ^[A-Za-z][A-Za-z0-9_]{4,31}$ ]] && { printf '%s' "$uname"; return 0; }
  printf 'tg:%s' "$uid"
}

# THE TAP LEDGER. Before this, an inline-button tap was the LEAST logged path in
# the system for the control that is supposed to be the most rigorously evidenced:
# the callback arrived, a `task answer` ran, and the only trace was whatever the
# answer itself stored. Reconstructing "did a human really press this, and which
# human" meant reading someone else's shell history.
#
# Append-only JSONL next to the other append-only ledgers (the council's
# veto-audit.jsonl), same permissions posture: 0600, root-owned when we are root.
# Best-effort by construction — a box that cannot write this file must not lose a
# human's answer over it — but "best effort" here means the WRITE may fail, never
# that the call is skipped.
#
# THE RAW NONCE IS NEVER WRITTEN. `human_nonce_hash` is hash-only at rest for the
# reason DIVE-916 gives, and a ledger that recorded the presented nonce would undo
# that at a second address. We record only WHETHER one was presented.
_gate_tap_log() {
  local log="${GATE_TAP_LOG:-${STATE_DIR}/gate-taps.jsonl}"
  local dir="${log%/*}"
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
  local line
  line=$(jq -cn \
    --arg ts        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg ident     "${1:-}" \
    --arg tier      "${2:-}" \
    --arg type      "${3:-}" \
    --arg tap_uid   "${4:-}" \
    --arg tap_user  "${5:-}" \
    --arg tap_msg   "${6:-}" \
    --arg relay     "${7:-}" \
    --arg resolved  "${8:-}" \
    --arg stamp     "${9:-}" \
    --arg nonce     "${10:-}" \
    --arg verdict   "${11:-}" \
    --arg via       "${12:-}" \
    '{ts:$ts, gate:$ident, tier:$tier, type:$type, tap_uid:$tap_uid,
      tap_username:$tap_user, tap_message_id:$tap_msg, relay_agent:$relay,
      resolved_human:$resolved, resolved_via:$via, stamped_as:$stamp,
      human_proof:$nonce, verdict:$verdict}' 2>/dev/null) || return 0
  printf '%s\n' "$line" >>"$log" 2>/dev/null || return 0
  chmod 0600 "$log" 2>/dev/null || true
  [[ $EUID -eq 0 ]] && chown root:root "$log" 2>/dev/null || true
  return 0
}

# ── DIVE-3160: `_task_answer` — the delegated, SIGNED gate clear ─────────────
#
# THE DEFECT. A cli-scoped lead can CLEAR a gate it cannot SIGN. cmd_task_answer
# signs the DIVE-756 closure in-process only at EUID 0; every other caller shells
# out to `sudo -n 5dive gate-proof sign`, and a cli-scoped seat holds no grant for
# it (its own `_sig_why` string says so, a few hundred lines below). Signing is
# best-effort by design, so the answer LANDS UNSIGNED and `require_sig=1` on the
# push/deploy root executors refuses it later — on the MAKER's next round-trip,
# with a message about tampering. Standing to clear and capability to sign were
# decided in two different places and nothing lined them up.
#
# WHY NOT THE OBVIOUS FIX — this is the load-bearing paragraph. "Grant a narrow
# root verb that seals the STORED ROW" reads far safer than `gate-proof sign` over
# stdin, and is not safer at all: /var/lib/5dive/tasks/tasks.db is `rw-rw----
# root:claude` and EVERY agent seat is in group `claude` (measured 2026-08-10 on
# both a cli-scoped seat and a root-all one), so a caller writes
# `need_answered_by='human:lodar'` with plain sqlite3 FIRST and then asks for the
# seal. tasks_db.sh's own note — "a raw-sqlite write that never ran
# cmd_task_answer leaves an unsigned/invalid row that gate-proof verify flags" —
# is the reason this HMAC exists at all. Narrowing the ARGUMENT (stdin -> ident)
# changes the transport and never the trust: the payload is caller-authored
# either way. The question is not what the verb accepts, it is who authored the
# bytes it will attest to.
#
# So this primitive signs at ANSWER time, from facts it establishes ITSELF:
#
#   1. EUID 0 or refuse — reachable only through the exact-path NOPASSWD grant.
#   2. WHO comes from SUDO_UID under sudo's env_reset, never argv, never --from.
#      `_gate_uid_to_agent` fails closed on anything that is not an `agent-*` row.
#   3. STANDING is re-derived AS ROOT FROM THE ROW (routed_reviewer, or the
#      sealed constitution's standing lead) — never from anything the caller
#      passed. Identity alone is not enough: a lead with standing on gate X must
#      not clear gate Y. (_gh_do's posture, and main's condition 1.)
#   4. It cannot stamp `human:*`. An agent-invoked path is by definition not a
#      human tap, so the human-evidence flags are REFUSED here and `human` is
#      additionally forced to 0 inside cmd_task_answer for this path (main's
#      condition 2 — the DIVE-916/1115/2224 forged-human residual is a known open
#      threat and a new root path must not become a fresh entrance to it).
#   5. cmd_task_answer then runs its OWN authorization unchanged, at EUID 0, and
#      signs in-process. Every check above is a SUBSET guard that refuses EARLIER;
#      this primitive grants nothing and cannot widen who may clear what.
#
# SELF-CLEAR (main's open design question, settled here): a maker may not have its
# own gate signed, and the maker is `maker_agent` — the loop spec's maker — NEVER
# `assignee`. On DIVE-2159, the acceptance row for this ticket, `assignee` is the
# VERIFIER (main2) and `maker_agent` is dev: a self-clear check keyed on assignee
# would have refused the one legitimate clear this whole ticket exists to make
# signable. When a row names no maker the check stays SILENT rather than guessing
# from assignee — a guess in that column is exactly the error just described.
# Every argument to `task answer` that can raise `human`, or that names an actor
# the caller was not measured to be. A PREDICATE over ONE argument, so the harness
# can grade the exact list the executor loops over rather than a copy of it — and
# a source tripwire in that harness asserts the loop still calls this, because the
# usual failure of an extracted check is a call site that quietly stops using it.
_task_answer_forbidden_flag() {
  case "${1:-}" in
    --human|--human-proof=*|--channel-proof=*|--channel-msg=*|--tap-uid=*|--tap-username=*|--tap-msg=*|--relay-agent=*|--from=*) return 0 ;;
  esac
  return 1
}

cmd_task_answer_delegated() {
  [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "_task_answer is a privileged internal primitive (reachable only through the exact-path NOPASSWD grant)."

  # Parameters over stdin, NUL-separated, never argv (main's condition 3): nothing
  # gate-bearing lands in the process table, and the grant stays an exact command
  # path with no wildcard, so it holds identically under classic sudo and sudo-rs.
  # Same shape as _push_do and _gh_do.
  local -a args=(); local a
  while IFS= read -r -d '' a; do args+=("$a"); done
  (( ${#args[@]} )) || fail "$E_VALIDATION" "_task_answer got no arguments on stdin."

  # (2) WHO — the kernel's view of the DELEGATING caller. sudo's env_reset means
  # SUDO_UID here was set by sudo itself; a caller-supplied one is stripped before
  # this process starts. A root-all seat could of course forge it, but that seat
  # can already reach `gate-proof sign` directly — this grant hands it nothing new.
  local _ruid="${SUDO_UID:-}"
  [[ "$_ruid" =~ ^[0-9]+$ ]] \
    || fail "$E_AUTH_REQUIRED" "_task_answer: no SUDO_UID — reach this primitive through sudo from an agent seat, never as root directly (a root caller has no delegating agent to attribute the clear to)."
  [[ "$_ruid" != "0" ]] \
    || fail "$E_AUTH_REQUIRED" "_task_answer: SUDO_UID is root, which is not an agent seat."
  local _actor; _actor=$(_gate_uid_to_agent "$_ruid")
  [[ -n "$_actor" ]] \
    || fail "$E_AUTH_REQUIRED" "_task_answer: uid ${_ruid} owns no agent-* passwd row, so this clear has no attributable agent."

  # (4) NEVER human:*. Refused by NAME here so the refusal is greppable and lands
  # before any write; `human=0` is forced again inside cmd_task_answer so a flag
  # added later cannot reopen this.
  for a in "${args[@]}"; do
    _task_answer_forbidden_flag "$a" \
      && fail "$E_VALIDATION" "_task_answer refuses ${a%%=*}: an agent-invoked clear is never a human tap, and provenance here is derived from SUDO_UID rather than passed in. Use '5dive task answer' for a human-sourced answer."
  done

  local _ident=""
  for a in "${args[@]}"; do [[ "$a" == --* ]] && continue; _ident="$a"; break; done
  [[ -n "$_ident" ]] || fail "$E_VALIDATION" "_task_answer got no task ident on stdin."

  tasks_db_init
  # (3) STANDING, re-derived as root from the ROW. All four columns are
  # enum/agent-name/timestamp shaped, so the sqlite3 `|` separator is unambiguous.
  local _row
  _row=$(db "SELECT COALESCE(routed_reviewer,''),COALESCE(maker_agent,''),COALESCE(need_type,''),COALESCE(need_answered_at,'') FROM tasks WHERE ident=$(sqlq "$_ident") LIMIT 1;" 2>/dev/null || printf '')
  [[ -n "$_row" ]] || fail "$E_VALIDATION" "_task_answer: no task ${_ident}."
  local _rr _maker _ntype _answered _rest
  _rr="${_row%%|*}";     _rest="${_row#*|}"
  _maker="${_rest%%|*}"; _rest="${_rest#*|}"
  _ntype="${_rest%%|*}"; _answered="${_rest#*|}"

  [[ -n "$_ntype" ]]   || fail "$E_VALIDATION" "_task_answer: ${_ident} carries no gate."
  [[ -z "$_answered" ]] || fail "$E_CONFLICT" "_task_answer: the gate on ${_ident} was already answered at ${_answered} — answer-once has no re-sign path (re-file a fresh gate)."

  local _sl; _sl=$(_gate_standing_lead 2>/dev/null || printf '')
  if [[ "$_actor" != "$_rr" ]] && [[ -z "$_sl" || "$_actor" != "$_sl" ]]; then
    fail "$E_AUTH_REQUIRED" "_task_answer: ${_actor} holds no lead-clear standing on ${_ident} (routed reviewer: ${_rr:-<none>}). This primitive serves the lead-clear-that-cannot-sign case and nothing else."
  fi

  if [[ -n "$_maker" && "$_actor" == "$_maker" ]]; then
    fail "$E_AUTH_REQUIRED" "_task_answer: ${_actor} is the MAKER of ${_ident} — signing your own gate is a self-clear, refused here even when the row routes the clear back to you."
  fi

  TASK_ANSWER_DELEGATED=1
  cmd_task_answer "${args[@]}"
}

# The caller half: reach for the SIGNED path when, and only when, this seat is one
# whose closures land unsigned today. A seat that can sign directly keeps today's
# path byte for byte — routing a root-all seat through the executor would silently
# apply the new refusals to flows that never had them, which is a policy change
# this ticket was not asked to make. Failing closed is free here: on any refusal we
# fall through to the existing path, which lands the answer exactly as it does
# today (unsigned, with the DIVE-2760 notice naming the cause) — so this can make
# a closure signed and can never make an answer fail.
_task_answer_try_delegated() {
  [[ $EUID -ne 0 ]]                        || return 1   # root already signs in-process
  [[ -z "${TASK_ANSWER_DELEGATED:-}" ]]    || return 1   # no recursion from the executor
  sudo -n -l /usr/local/bin/5dive gate-proof sign >/dev/null 2>&1 && return 1
  sudo -n -l /usr/local/bin/5dive _task_answer    >/dev/null 2>&1 || return 1
  local _out _rc=0
  _out=$(printf '%s\0' "$@" | sudo -n /usr/local/bin/5dive _task_answer 2>&1) || _rc=$?
  if (( _rc == 0 )); then printf '%s\n' "$_out"; return 0; fi
  # It refused. Two different situations hide behind one exit code, so ASK THE ROW
  # rather than parse the message: if the gate is answered, the write landed and
  # re-running would trip answer-once or double-write; only an untouched gate may
  # fall through.
  local _ident="" a
  for a in "$@"; do [[ "$a" == --* ]] && continue; _ident="$a"; break; done
  if [[ -n "$_ident" ]]; then
    local _now; _now=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident=$(sqlq "$_ident") LIMIT 1;" 2>/dev/null || printf '')
    if [[ -n "$_now" ]]; then printf '%s\n' "$_out"; return 0; fi
  fi
  warn "the signed clear (_task_answer) refused, so this answer will store UNSIGNED:"
  printf '%s\n' "$_out" | sed 's/^/  /' >&2
  return 1
}

cmd_task_answer() {
  tasks_db_init
  # DIVE-3160: prefer the delegated SIGNED clear on a seat that cannot sign. Runs
  # before any parsing so the executor sees the caller's arguments verbatim.
  _task_answer_try_delegated "$@" && return 0
  local value="" value_set=0 from="" human=0 human_proof="" channel_proof="" channel_msg=""
  local tap_uid="" tap_username="" tap_msg="" relay_agent=""
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
      # DIVE-2412: the message_id of the human's OWN message in that verified DM.
      # This is the citation the tier-2 form is built on: the chat id above says
      # WHICH conversation, and only this says the human actually spoke in it —
      # and it is checked against Telegram, not against the caller's word.
      --channel-msg=*) channel_msg="${1#*=}" ;;
      # DIVE-3128: WHO TAPPED, and WHOSE BOT CARRIED IT — two flags because they
      # are two facts. The tap handler reads both straight off Telegram's
      # `callback_query`: `.from.id` is the person who pressed the button and
      # `.from.username` is their handle, neither of which the relaying agent
      # chooses. Before this the relay's own identity was all that reached the
      # row and it wore the `human:` prefix (DIVE-3045).
      #
      # These are PROVENANCE, not authority. Nothing below is authorized by them:
      # a tap still clears a tier-2 gate on the DIVE-916 nonce or a non-agent
      # SUDO_UID exactly as before, and passing --tap-uid without that evidence
      # buys nothing. What they change is what the record SAYS about an answer
      # that was already going to land.
      --tap-uid=*)      tap_uid="${1#*=}" ;;
      --tap-username=*) tap_username="${1#*=}" ;;
      --tap-msg=*)      tap_msg="${1#*=}" ;;
      --relay-agent=*)  relay_agent="${1#*=}" ;;
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

  # DIVE-2411: refuse to STAMP a secret gate that names no delivery path, before
  # any write. This is the same defect as the filing refusal in cmd_task_need, one
  # step later and strictly worse: the filing gap leaves a gate visibly stuck,
  # while this one CLOSES the loop with full provenance over nothing.
  #
  # MEASURED on DIVE-2232: need_answered_at set, need_answered_by=human:main,
  # uid 1004, need_answer_sig VALID, human_nonce_hash SET — a real human holding
  # the raw nonce tapped ✅ Provided — and no connector file was written that day,
  # no drop was ever minted, no value reached any channel. The record reads
  # "credential provided, human-attested, signed, nonced" and no credential exists.
  # Provenance and payload are INDEPENDENT and we only ever verified provenance.
  #
  # WHY THE AFFORDANCE FIX IS NOT ENOUGH ON ITS OWN. Withholding the button (see
  # _task_gate_reply_markup) only changes messages sent FROM NOW ON. Telegram inline
  # buttons on already-delivered messages never expire — the same fact DIVE-2228
  # turns on — so every legacy secret gate already in someone's chat history keeps a
  # live ✅ Provided button, and any of those taps still lands here. This is the
  # durable half; the affordance removal is the half that stops NEW ones.
  #
  # The predicate is the ROW's shape only — no caller-supplied input can satisfy it,
  # so there is nothing to forge. A gate that named a drop target still answers
  # normally (that is the legitimate "I ran `5dive secret write` myself" case), and
  # an explicitly out-of-band gate still answers, because its ask NAMED where the
  # value goes. Only "asks for a credential, names nowhere" is refused.
  if [[ "$nt" == "secret" ]]; then
    local _paths; _paths=$(db "SELECT COALESCE(secret_key,'')||COALESCE(connector,'')||COALESCE(secret_oob,'') FROM tasks WHERE id=${id};")
    [[ -n "$_paths" ]] || fail "$E_CONFLICT" "$ident is a secret gate that names NO delivery path, so nothing can have landed — re-file it with one: --secret-key=<ENV> --connector=<stem>, or --out-of-band=\"<where>\""
  fi

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
  local _lk _loop_bounce=0 _run="" _prev="" _prev_status="" _prev_ident="" _lv=""
  _lk=$(_loop_kind "$id")
  # DIVE-2572: the bounce/advance decision is read from the DECISION SEGMENT (the
  # first non-blank line up to its first dash/colon/comma/stop), not from a bare
  # substring over the whole answer. See _loop_answer_is_bounce.
  if [[ "$_lk" == gate:* ]]; then
    # Resolve the relay direction before any answer write.  A refusal below must
    # leave the gate pending; discovering the cancelled predecessor after the
    # answer was stamped would make a non-zero return lie about what committed.
    _lv=$(printf '%s' "${value:-}" | tr '[:upper:]' '[:lower:]')
    if _loop_answer_is_bounce "$_lv"; then
      _loop_bounce=1
      _run=$(db "SELECT COALESCE(parent_id,'') FROM tasks WHERE id=${id};")
      _prev=$(db "SELECT id FROM tasks WHERE parent_id=${_run:-0} AND id<${id} AND body LIKE '%${_LOOP_MARK}:%' ORDER BY id DESC LIMIT 1;")
      if [[ -n "$_prev" ]]; then
        _prev_status=$(db "SELECT status FROM tasks WHERE id=${_prev};")
        _prev_ident=$(db "SELECT ident FROM tasks WHERE id=${_prev};")
      fi
    elif (( ${_LOOP_BOUNCE_AMBIGUOUS:-0} )); then
      # DIVE-2572: ADVANCING, and the answer carries bounce vocabulary later in
      # its prose. Under the old bare-substring matcher this exact shape was
      # classified as a BOUNCE — five for five on the live board. Naming it is
      # the compatibility window: a reader who genuinely meant to bounce learns
      # the form in the one place they will read it, and nobody's careful prose
      # is silently reinterpreted in the meantime.
      warn "$ident: answered as ADVANCE. The decision is read from the first line up to its first dash/colon/comma/stop, and this answer carries bounce vocabulary only AFTER that — under the previous matcher its presence anywhere would have bounced this to the previous loop step (DIVE-2572). If you meant to BOUNCE, put the word in that opening segment: 'reject — <why>', or 'do better'."
    fi
  fi
  # DIVE-2261: cancellation is an abandonment record, not completed work ready
  # for another iteration.  Refuse conservatively instead of skipping farther
  # back (which silently changes which work the human rejected) or resurrecting
  # the cancelled row.  This is deliberately before every answer write, so both
  # rows and their dependency graph remain untouched and the same gate can be
  # answered after a human repairs the anomalous relay.
  if (( _loop_bounce )) && [[ "$_prev_status" == "cancelled" ]]; then
    policy_refuse "$E_CONFLICT" "task_loop_bounce_cancelled_previous" "DIVE-2261" "$ident" \
      "$ident cannot bounce to previous loop step ${_prev_ident:-$_prev}: it is cancelled, so reopening it would resurrect deliberately abandoned work. The gate is still open; resolve the cancelled step or choose an advancing answer."
  fi
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

  # DIVE-2406: the two PER-GATE human-evidence forms (valid nonce, non-agent
  # SUDO_UID) are computed inside the hard-gate block below, but the provenance
  # stamp near the end of this function needs them too — a `--human` claim with
  # no evidence behind it must not be labelled `human:*`. Declared at function
  # scope so that stamp reads an initialized 0 on the gate types that never enter
  # that block, rather than an unset variable. Values are still set there, once.
  local _hp=0 _su=0

  # DIVE-2412 (DIVE-2382 fix #4): the CITED-MESSAGE form, which a tier-2 gate DOES
  # accept. The chat-only proof above stays tier<2 for the reason lodar scoped it
  # that way — an agent's session already knows the chat id, so alone it proves
  # only that this bot has a paired human. A citation is different in kind: the
  # message_id is checked against TELEGRAM (_gate_channel_session_ok), which is the
  # one party in this system the caller cannot speak for. So the tier-2 floor below
  # is satisfied by CHANNEL PROOF of the answer, not only by a button tap.
  #
  # Order matters: this runs BEFORE the evidence block and the tier-2 floor, and it
  # is the only thing here that can raise `human` on a tier-2 gate.
  local _cs_ok=0
  if [[ -n "$channel_msg" ]]; then
    [[ -n "$channel_proof" ]] || fail "$E_USAGE" "--channel-msg=<message_id> also needs --channel-proof=<chat_id> — the verified DM the message was sent in"
    if _gate_channel_session_ok "$channel_proof" "$channel_msg" "${value:-}" "$ident"; then
      _cs_ok=1
    else
      # FAIL CLOSED, AND NAME THE CONDITION. A citation that does not attest must
      # never fall through to the weaker chat-only form, nor to the generic floor
      # message below: the caller asserted a human answer and the assertion did
      # not hold, which is the refusal this ticket is graded on. Nothing above
      # this point writes to the row, so the gate is still unanswered — that is
      # the property the refusal arm checks, not merely a non-zero rc.
      _task_store_audit_log "task answer gate" error 0 -- \
        "task=$ident" "type=$nt" "tier=$gtier" "reason=channel-session citation did not attest" \
        "channel_proof=${channel_proof}" "channel_msg=${channel_msg}" "origin=${TASK_CS_ORIGIN:-none}" \
        "age=${TASK_CS_AGE:-unknown}" "detail=${TASK_CS_REASON:-unknown}" 2>/dev/null || true
      fail "$E_AUTH_REQUIRED" "$ident: the cited channel message is not usable as the human's answer — ${TASK_CS_REASON:-unattested}"
    fi
  fi
  (( _cs_ok )) && human=1

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
  # DIVE-2330: that claim was FALSE until this fix — the function read a bare
  # `id -un`, resolved through the caller's PATH, so any agent could mint the
  # routed reviewer's name (measured: a shim made it return `lodar`). It now
  # resolves $EUID in pure bash over /etc/passwd, so the claim is true as written.
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
  # DIVE-3171 — THE ROUTED BRANCH MUST NOT SWALLOW THE STANDING PROVENANCE.
  #
  # This guard was `_lead_clear != 1`, i.e. "standing only gets a say when routing did
  # not already grant clearance". Correct until DIVE-3171, because a gate whose reviewer
  # came from the CHART is genuinely a routed clear. But DIVE-3171 routes the org root's
  # eligible approvals to the SEALED standing lead — so routing now grants clearance to
  # an agent whose authority came from the constitution, the routed branch fires first,
  # and the row stamps `lead:<n>` for a clear the seal is the entire reason for. The
  # authority chain stays intact and the RECORD stops carrying HOW, which is the exact
  # class that cost three incidents on 2026-08-10 (two unattributed human taps read as
  # agent self-clears; a census that reported "quinn cleared ZERO gates" and was wrong
  # by four). `lead:standing:` is the only thing on the row separating "a lead cleared a
  # gate routed to them" from "a lead cleared it under constitutional standing", and
  # those are different authorities even when the same name appears in both.
  #
  # THE COUNTING ARGUMENT IS WHY IT IS FIXED NOW AND NOT LATER: anyone tallying
  # `lead:standing:` for a root-filed gate would find it under `lead:` and conclude the
  # standing path went unused — a silent shift in a number nobody re-derives.
  #
  # IT GRANTS NOTHING. The added disjunct only lets the block RUN; every conjunct inside
  # is unchanged, so `_lead_standing=1` still requires the authenticated actor to BE the
  # sealed lead and the gate to pass `_gate_lead_standing_eligible`. `_lead_clear` is
  # already 1 on this path and cannot be raised by reaching here. The only reachable
  # effect is the label — and it is scoped by `route_provenance` to rows THIS build
  # wrote, so no historical stamp moves and the counts shift for exactly the population
  # that was mislabelled.
  local _lead_standing=0
  local _route_prov_row; _route_prov_row=$(db "SELECT COALESCE(route_provenance,'') FROM tasks WHERE id=${id};")
  if [[ ( "$_lead_clear" != "1" || "$_route_prov_row" == "seal:standing-lead" ) && "$nt" == "approval" ]]; then
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
    # DIVE-2330: was `id -un` (PATH-forgeable). This decides whether an agent is
    # REFUSED, so a caller faking a non-agent name would skip it.
    #
    # ITERATION 2 (dev's finding, and the comment above it used to justify the
    # bug): this read `$EUID` DIRECTLY, bypassing `_gate_caller_uid`. The
    # justification conflated two different things — routing through
    # `_gate_authenticated_actor` WOULD widen the refusal, because that function
    # adds the root+SUDO_UID branch; routing through `_gate_caller_uid` widens
    # NOTHING, because the seam's entire body is `printf '%s' "$EUID"`. The
    # EUID-only semantics live INSIDE the seam, which is the point of the seam.
    #
    # What the bypass cost: a harness could not model a non-agent caller here, so
    # on any `agent-*` runner this guard fired on the RUNNER'S OWN identity and
    # `fail` exited the sourced harness mid-suite (gate_nonce_unit T3's uncaptured
    # call, rc=6, 9/18 arms). The outcome of the test suite became a function of
    # whose uid ran it — the DIVE-2365 host-supplied-precondition shape, which
    # this branch named in its own body and then reintroduced one function over.
    local _caller; _caller=$(_gate_uid_to_agent "$(_gate_caller_uid)")
    if [[ -n "$_caller" && "$_lead_clear" != "1" ]]; then
      # No audit_log here: the blocked caller is an agent user that can't write
      # the root-owned audit log anyway (it would only leak a perms error to
      # stderr). The fail + non-zero exit is the record.
      # DIVE-2801: state the CALLER's standing, not a law about the gate type.
      # "an agent can't self-answer an approval gate" is false — the gate's
      # lead-clear seat reaches here with _lead_clear=1 and clears it with no
      # human at all (see the branch above; DIVE-2599/2665/2654 are live
      # instances). Human-only is the FALL-THROUGH for a caller without that
      # standing, not the rule for the type. The old wording was read as a
      # general rule by the agent it refused, who then rebuilt the gate around
      # it — a refusal that describes the wrong subject sends the reader to fix
      # the wrong thing, and unlike a wrong answer nobody audits a reason.
      # ...and the same discipline applies to the REMEDY, one clause later. An
      # unrouted gate has no lead-clear seat, so "its lead-clear seat can answer
      # this with no human involved" is, on that gate, the identical defect in
      # the opposite direction: a sentence true of the type and false of the row
      # in front of the reader. Only the routed branch may claim a seat exists.
      # ...and the same discipline again on TIER, which is the third way this
      # sentence can be true of the type and false of the row. The tier-2 floor
      # at `gtier == 2 && ! human` sits BELOW this refusal, so the routed
      # reviewer never reaches it from here — but they hit it on their own
      # answer, and it ESCALATES them to a human rather than letting them clear.
      # Telling a tier-2 caller "your routed reviewer can answer this with no
      # human involved" would therefore recommend a remedy this code refuses,
      # which is the very defect this row exists to fix, committed inside its
      # own fix. Only a sub-tier-2 routed gate may claim a seat that can finish.
      local _who_can="a human — this gate has no routed reviewer, so no seat holds lead-clear standing"
      if [[ -n "$_routed_rev" && "$gtier" == "2" ]]; then
        _who_can="a human — it is routed to '${_routed_rev}', but this gate is TIER 2 and the floor escalates even their answer to a human tap"
      elif [[ -n "$_routed_rev" ]]; then
        _who_can="'${_routed_rev}' (its routed reviewer), or a human"
      fi
      fail "$E_AUTH_REQUIRED" "$ident is a '$nt' gate and you ('${_caller}') do not hold lead-clear standing on it — it can be cleared by ${_who_can}. A human answers from Telegram (tap the button) or the dashboard."
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
    # (_hp/_su declared at function scope above — DIVE-2406 reads them at the stamp.)
    [[ -n "$human_proof" ]] && _human_nonce_verify "$id" "$human_proof" && _hp=1
    # DIVE-2371: AUTHORIZATION site — structural principal test, fails closed.
    _gate_human_principal && _su=1
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
    # DIVE-2412: _cs_ok is the attested cited-message form. Unlike _cp_ok it is
    # NOT tier-fenced, so it satisfies the evidence rule on a tier-2 approval too.
    local _evid=$(( _hp || _su || _lead_clear || _cp_ok || _cs_ok ))
    local _caller2; _caller2=$(_gate_caller_user)
    # DIVE-2054: the human-proof/nonce evidence being scored here is stored
    # against $ident in TASKS_DB (not an independent channel/delivery fact like
    # the 3 named exemptions) — fenced.
    # DIVE-2799: `evidence=` names the form(s) that satisfied the rule; the
    # per-form booleans stay for continuity of the historical sweeps that
    # already key on them.
    _task_store_audit_log "task answer gate" "$([[ $_evid -eq 1 ]] && echo ok || echo error)" 0 -- \
      "task=$ident" "type=$nt" "channel_proof=$([[ -n "$channel_proof" ]] && echo present || echo absent)" "cp_ok=$_cp_ok" \
      "channel_msg=${channel_msg:-none}" "cs_ok=$_cs_ok" "cs_origin=${TASK_CS_ORIGIN:-none}" "cs_age=${TASK_CS_AGE:-none}" \
      "human_proof=$([[ -n "$human_proof" ]] && echo present || echo absent)" "nonce_valid=$_hp" \
      "sudo_nonagent=$_su" "human=$human" \
      "evidence=$(_gate_evidence_form "$_hp" "$_su" "$_cs_ok" "$_cp_ok" "$_lead_clear")" \
      "filer_answered=$(_gate_filer_answered "$id" "$_caller2")" \
      "caller=$_caller2" "sudo_uid=${SUDO_UID:-}" \
      "enforce=$(_gate_proof_enforced && echo on || echo off)"
    # DIVE-525: a real human tap is NEVER rejected — every trusted path supplies
    # at least one evidence form (plugin→nonce, dashboard→proof/SUDO_UID=claude,
    # human-on-box→non-agent SUDO_UID, drop→SUDO_UID=claude). Under enforcement,
    # reject only when NONE is present (the forge: an agent's bare
    # `sudo task answer --human`). Ships DORMANT (audit-only) until the plugin
    # --human-proof injection is confirmed live fleet-wide; root then flips
    # `gate-proof enforce on` (Marcus ship-gates the flip).
    if _gate_proof_enforced && (( ! _evid )); then
      fail "$E_AUTH_REQUIRED" "$ident ($nt) needs a human to clear it — tap the button in Telegram or use the dashboard"
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
  # DIVE-2588: NO LONGER CONTINGENT ON THE ROLLOUT FLAG. The `_gate_proof_enforced`
  # conjunct was a staging envelope for a rollout that completed on 2026-07-30, and
  # while it stood it made a hard human floor switchable — the same variable that
  # armed it could disarm it, and until DIVE-2588 the party it constrains could set
  # that variable. A control whose OFF position is reachable by its subject is not a
  # control. The flag can now only make the floor STRICTER (see _gate_proof_enforced),
  # and this branch does not consult it at all. Safe to make unconditional: it refuses
  # only a NON-human answer on a tier-2 gate, which is precisely what a hard human
  # floor means on every box, armed or not — every real human path passes --human, so
  # DIVE-525 ("a real tap is never rejected") still holds by construction.
  # DIVE-3228: the `access` exemption, re-derived from the row (see
  # _gate_access_lead_clearable for why it is re-derived and not taken from
  # `_lead_clear` alone). `_lead_clear` is still REQUIRED — it carries the
  # unforgeable half (`_gate_authenticated_actor` == routed_reviewer, DIVE-2004/2330),
  # and this predicate only decides whether THAT seat's answer survives the floor.
  # An access gate that was never routed has _lead_clear=0 and is untouched here,
  # which is the DIVE-1243 fall-through the block below already describes.
  local _access_lead_ok=0
  if [[ "$_lead_clear" == "1" && "$nt" == "access" && "$gtier" == "2" ]]; then
    local _al_floor _al_needs
    _al_floor=$(db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE id=${id};")
    _al_needs=$(db "SELECT COALESCE(needs_capability,'') FROM tasks WHERE id=${id};")
    if _gate_access_lead_clearable "$nt" "$gtier" "$_al_floor" "$_al_needs"; then
      _access_lead_ok=1
    fi
    # Record BOTH directions. A fix that logs only its successes leaves the next
    # regression with nothing to count — this row's own DIVE-3117 lesson, and the
    # denying branch is the one that will be argued about (it is where a filer whose
    # access gate still reaches lodar has to be told WHY).
    # DIVE-2054: task-store state for $ident, no channel proof — fenced.
    _task_store_audit_log "task answer access-lead-clear" \
      "$( ((_access_lead_ok)) && echo allowed || echo denied )" 0 -- \
      "task=$ident" "type=$nt" "tier=$gtier" "routed_to=$_routed_rev" \
      "floor_provenance=${_al_floor:-<null>}" "needs=${_al_needs:-<none>}" || true
  fi
  if [[ "$gtier" == "2" ]] && (( ! human )) && (( ! _access_lead_ok )); then
    local _caller3; _caller3=$(_gate_caller_user)
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
    fail "$E_AUTH_REQUIRED" "$ident is a tier-2 human gate ($nt) — only a human can clear it; tap the button in Telegram"
  fi

  # DIVE-2233 (second item) — THE TIER-2 HUMAN CLAIM MUST BE PROVED, NOT ASSERTED.
  #
  # The floor above only fires when `--human` was NOT passed. That is the entire hole:
  # every guard on a tier-2 gate is downstream of a flag, and `--human` is a plain CLI
  # flag any agent that can `sudo` can pass. The gate that closed DIVE-2131 is the
  # worked example — a tier-2 hard gate whose row recorded need_answered_uid=1004
  # (agent-main, the plugin's own uid) and human_nonce_hash NULL. Nothing in that row is
  # non-forgeable. "Hard human floor" was a label on it, not a property of it.
  #
  # So when a tier-2 gate HAS a minted nonce, a `--human` answer must carry one of the
  # two DIVE-916 evidence forms — the per-gate nonce (the tap; its SUDO_UID is the
  # spawning agent, which is why the nonce exists) or a non-agent SUDO_UID (dashboard
  # exec, human-on-box login). Both are things an agent cannot produce for itself.
  #
  # SCOPED TO "HAS A NONCE" ON PURPOSE, and this is the compatibility hinge rather than
  # timidity: before this change, tier-2 decision/access gates minted nothing, so a gate
  # filed by the old code and answered by the new code has no hash to check. Demanding
  # evidence there would reject real human taps on every gate already in flight — and
  # those taps genuinely cannot comply, because the button they are attached to was
  # rendered without a nonce in its callback_data. `human_nonce_hash` non-empty is the
  # exact, per-row witness that this gate's buttons CAN carry proof.
  #
  # DIVE-2588: the `_gate_proof_enforced` conjunct is GONE here too, and this is the
  # branch the bypass actually rode. A forged `--human` was already refused by this
  # block on any gate carrying a minted nonce — main measured that on v0.18.2 AND
  # v0.17.11 — so the exploit was not the flag; it was that ONE env var switched this
  # block off and the floor above at the same time. Making it unconditional costs
  # nothing on a box where the rollout never happened: the block is already scoped to
  # gates whose `human_nonce_hash` is non-empty, i.e. the per-row witness that this
  # gate's buttons CAN carry proof, so a box that mints nothing reaches no assertion
  # here. That scoping, not the flag, was always what kept real taps safe.
  if [[ "$gtier" == "2" ]] && (( human )); then
    local _t2_hash; _t2_hash=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_t2_hash" ]]; then
      local _t2_hp=0 _t2_su=0
      [[ -n "$human_proof" ]] && _human_nonce_verify "$id" "$human_proof" && _t2_hp=1
      # DIVE-2371: AUTHORIZATION site (tier-2 floor) — same structural test.
      _gate_human_principal && _t2_su=1
      # DIVE-2412: THE CITATION IS THE THIRD EVIDENCE FORM, and it has to be named
      # HERE rather than only in the `human` flag it also raises. This site is what
      # decides whether a tier-2 `--human` claim was PROVED, and it is scoped to
      # gates that HAVE a minted nonce — which is every approval and manual gate,
      # i.e. exactly the ones this feature exists for. Omitted from this list, the
      # citation would raise `human`, clear the floor above, and then be refused
      # here as an unproven claim: the feature would be dead on its main case.
      # It is admitted on the same footing as the other two because it is not
      # weaker in kind — the nonce and the non-agent SUDO_UID are both local to
      # this box, while the citation is attested by Telegram, the one party the
      # caller cannot speak for (_gate_channel_session_ok).
      local _t2_cs="${_cs_ok:-0}"
      local _t2_caller; _t2_caller=$(_gate_caller_user)
      # DIVE-2054: the nonce being scored is task-store state for $ident — fenced.
      # DIVE-2799: same canonical `evidence=` field as the site below, so ONE
      # grep spans both audit sites and the `tasks.human_evidence` column.
      # `channel-chat` and `lead` are 0 here BY CONSTRUCTION — neither is admitted
      # at the tier-2 floor (`_cp_ok` is tier-fenced to <2, and a lead-clear is not
      # human evidence) — and they are passed explicitly rather than omitted so the
      # arity and token order are identical at both sites.
      _task_store_audit_log "task answer t2-human-evidence" \
        "$([[ $(( _t2_hp || _t2_su || _t2_cs )) -eq 1 ]] && echo ok || echo error)" 0 -- \
        "task=$ident" "type=$nt" "tier=$gtier" "nonce_valid=$_t2_hp" "sudo_nonagent=$_t2_su" \
        "channel_session=$_t2_cs" \
        "human_proof=$([[ -n "$human_proof" ]] && echo present || echo absent)" \
        "evidence=$(_gate_evidence_form "$_t2_hp" "$_t2_su" "$_t2_cs" 0 0)" \
        "filer_answered=$(_gate_filer_answered "$id" "$_t2_caller")" \
        "caller=$_t2_caller" "sudo_uid=${SUDO_UID:-}" 2>/dev/null || true
      if (( ! _t2_hp && ! _t2_su && ! _t2_cs )); then
        fail "$E_AUTH_REQUIRED" "$ident is a tier-2 human gate ($nt) and the --human claim is unproven — tap the button in Telegram"
      fi
    fi
  fi

  # Who resumes: the agent that FILED the gate, else the assignee, else the creator.
  # DIVE-2624: this used to read `assignee` first, and that reading is what forced
  # `task need` to overwrite the assignee at file time ("the agent hitting the gate
  # becomes the owner-of-record so task answer knows who to ping"). On a row already
  # delivered to a verifier that overwrite destroyed the derived handoff. gate_filed_by
  # is the column that records the filer — it is written in the same transaction as
  # the gate and reset by _gate_archive_and_clear_sql — so reading it here lets the
  # assignee go back to meaning only "who holds this row". The COALESCE tail keeps
  # pre-DIVE-1958 rows (gate_filed_by NULL) resolving exactly as before; the identical
  # COALESCE is already used by the DIVE-2011 delivery frame a few hundred lines down.
  local owner; owner=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''), NULLIF(assignee,''), NULLIF(created_by,''), '') FROM tasks WHERE id=${id};")
  # DIVE-394 provenance: record WHO answered. `human:` prefix when a trusted path
  # passed --human; otherwise the resolved actor label.
  local answered_by; answered_by=$(task_actor "$from")
  # DIVE-2406: `--human` is a SELF-ASSERTED flag — it is argv and nothing more. On
  # a lead-clearable gate it is the label, never the authority: the DIVE-1182/1243
  # routed lead-clear (or the DIVE-2099 standing clear) is what authorized the
  # answer, and that is an AGENT clear by construction. Before this, a lead who
  # also passed --human was stamped `human:<lead>` — and the `(( ! human ))`
  # guards just below, written on the assumption that human=1 meant a real human,
  # suppressed the honest `lead:` label that was already sitting right there.
  #
  # DIVE-2400 is the live case, and the cost was not cosmetic: the row read
  # `answered_by=human:marketing` with channel_proof absent, nonce_valid=0 and
  # sudo_nonagent=0 — every evidence form of a human absent — and the task's
  # result text then asserted "lodar approved all 7" when he had never answered.
  # The AUTHORITY was correct by design (the DIVE-1381 curation carve-out routes
  # a persona batch to the lead on purpose); it is the stamp that lied about who
  # exercised it, to `human:%` consumers that count human touches (cmd_trace,
  # cmd_digest, cmd_proof) and to the precedent engine, which auto-applies a
  # PRIOR HUMAN ANSWER to later gates and had a lead-clear to hand it.
  #
  # So an UNCORROBORATED --human on a lead-cleared gate is demoted here. Note
  # what is deliberately NOT in _human_evid: `_lead_clear`. It is a legitimate
  # AUTHORIZATION form for the block above (a lead-clear must not be refused for
  # lacking human evidence) and is precisely NOT evidence of a human here — that
  # conflation is the whole bug. A corroborated --human (valid per-gate nonce,
  # non-agent SUDO_UID, or verified channel proof) is untouched, so no genuine
  # Telegram tap, dashboard answer or human-on-box login is ever relabelled.
  # Conditioned on `_lead_clear` ALONE, and that is not an oversight about the
  # DIVE-2099 standing path: an eligible standing clear sets `_lead_clear=1` too
  # (see that block above), so one condition covers both and a second `||
  # _lead_standing` clause would be dead — untestable by mutation and green
  # forever. `_lead_clear=1` also implies nt is approval|manual|access, the types
  # that always enter the evidence block, so _hp/_su are measured values here and
  # never their declaration defaults.
  # DIVE-3160 (main's condition 2): the delegated executor must be STRUCTURALLY
  # incapable of writing a `human:*` label, not merely conventionally unlikely to.
  # `_task_answer` already refuses the human-evidence flags by name; this is the
  # backstop, placed at the one point every raise-site (--human, _cp_ok, _cs_ok,
  # and whatever the next one turns out to be) has already run and nothing has yet
  # read `human` to decide provenance. An agent-invoked clear is `lead:*`, full
  # stop — a new root path must not widen the DIVE-916/1115/2224 forged-human
  # residual, which is open.
  [[ -z "${TASK_ANSWER_DELEGATED:-}" ]] || human=0
  local _human_evid=$(( _hp || _su || _cp_ok ))
  local _human_claim="$human"
  if (( human && ! _human_evid )) && [[ "$_lead_clear" == "1" ]]; then
    human=0
  fi
  # ── DIVE-3128: NAME THE PERSON, NOT THE PIPE ──────────────────────────────
  #
  # `$answered_by` at this point is the ACTOR — the identity of the process that
  # ran `task answer`. On the tap path that process is a BOT, so prefixing it with
  # `human:` produced `human:olivia`: an assertion about a person, built out of a
  # measurement of a relay. That is DIVE-3045, and it is not a forgery — it is the
  # honest output of asking the wrong question.
  #
  # So when the caller carried a tap, the person who pressed the button is what
  # gets stamped, and the relay is recorded in its OWN column further down. When
  # no tap was carried, nothing here changes: `$answered_by` stays the actor and
  # every existing path keeps its current stamp.
  #
  # `(( human ))` fences the whole thing. --tap-uid is provenance, never
  # authority: an answer that did not already qualify as human-sourced does not
  # become one by naming a Telegram id, so a tap presented without the DIVE-916
  # nonce or a non-agent SUDO_UID is still refused upstream and never reaches here.
  local _tap_name="" _tap_src="none"
  if (( human )) && [[ -n "$tap_uid" ]]; then
    _tap_name=$(_gate_tap_human_name "$tap_uid" "$tap_username") || _tap_name=""
    if [[ -n "$_tap_name" ]]; then
      case "$_tap_name" in tg:*) _tap_src="unnamed-uid" ;; *) _tap_src="resolved" ;; esac
      answered_by="$_tap_name"
    else
      # A tap_uid that is not a Telegram id at all. Do NOT fall through to the
      # actor — that silently restores the exact substitution this block removes.
      _tap_src="bad-uid"
      answered_by="tg:invalid"
    fi
  fi

  # ── DIVE-3128: A `human:` STAMP MAY NOT NAME AN AGENT ─────────────────────
  #
  # The cheap invariant, and it is checked on EVERY human stamp rather than only
  # on the tap path — because the tap path is where this was DISCOVERED, not the
  # only place it can happen. Any relay that clears a gate while running as an
  # agent reaches this line with an agent name in `$answered_by`, and the fix
  # above only covers the callers that were taught to send `--tap-uid`.
  #
  # REFUSED, NOT REPAIRED. There is no honest repair available here: the code knows
  # the name is wrong and has nothing better to put in its place, so it declines to
  # make the claim. `unattributed:<name>` keeps every fact that WAS measured (a
  # --human answer arrived, this process ran it) while withholding the one that was
  # not, and it does not start with `human:` — so cmd_trace, cmd_digest, cmd_proof
  # and the precedent engine, all of which key on `need_answered_by LIKE 'human:%'`,
  # stop counting it as a human touch with no change on their side. That is the
  # DIVE-2406 demotion pattern one screen up, applied to a different lie.
  #
  # It is a DEMOTION rather than a `fail`, deliberately. The answer itself is
  # already authorized by evidence this block does not re-litigate, and refusing
  # the WRITE would discard a decision a person may really have made and leave a
  # tier-2 gate open with no way to close it. What is refused is the CLAIM.
  #
  # `human` is deliberately NOT cleared: the two `(( ! human ))` guards below add
  # `lead:` / `lead:standing:` prefixes, and firing them here would relabel a
  # refused human claim as an authorized lead clear — a second wrong answer.
  local _attr_why="" _attr_unverified=0
  if (( human )); then
    if actor_human_name_ok "$answered_by"; then
      [[ "${ACTOR_HUMAN_NAME_WHY:-}" == "roster-unmeasured" ]] && _attr_unverified=1
      answered_by="human:${answered_by}"
    else
      local _attr_name="$answered_by"
      _attr_why="${ACTOR_HUMAN_NAME_WHY:-refused}"
      answered_by="unattributed:${_attr_name}"
      warn "$ident: refusing to record this answer as human:${_attr_name} — '${_attr_name}' is a name on the AGENT roster, so the stamp would assert a human where the record can only show a relay (DIVE-3128). Stored as '${answered_by}'. A button tap should carry --tap-uid=<telegram user id> so the person who pressed it is named."
      # STDERR IS NOT REDIRECTED HERE, and that is a correction rather than a
      # style choice. `_task_store_audit_log`'s off-prod-store withholding is
      # announced ONCE per invocation (DIVE-2010, `_TASK_STORE_AUDIT_FENCED`), so
      # a `2>/dev/null` on the FIRST call through it eats the announcement for
      # every later one — measured against tests/gate_answer_audit_unit.sh, whose
      # "a silent fence is the same fail-open shape as no fence" arm went red the
      # moment this row was added ahead of the write-site row with its stderr
      # discarded. The sibling refusal sites can redirect because each of them
      # `fail`s immediately after; this one returns and the write-site row still
      # has to be able to speak.
      _task_store_audit_log "task answer human-attribution" error 0 -- \
        "task=$ident" "type=$nt" "tier=$gtier" "reason=$_attr_why" \
        "refused_stamp=human:${_attr_name}" "stored=${answered_by}" \
        "tap_uid=${tap_uid:-none}" "relay_agent=${relay_agent:-none}" || true
    fi
  fi
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
  # DIVE-2518: name the actor the standing check AUTHENTICATED, not the one the
  # caller claimed. `_lead_standing` is decided above by `_gate_authenticated_actor`
  # == `_gate_standing_lead` — the sealed uid-first derivation — while this label
  # was built from `task_actor "$from"`, which took `--from` verbatim. The two can
  # name DIFFERENT agents, and the row would then read `lead:standing:<claimed>`
  # for a standing that was granted to <derived>: a proof string asserting exactly
  # what the check did not verify. The label now comes from the same resolver as
  # the decision, which is the property `gate-proof verify` is reading it for.
  # `_gate_authenticated_actor` returns EMPTY for a caller it cannot resolve to an
  # agent, and an empty name here would stamp the bare string `lead:standing:` —
  # a proof label naming nobody, which `gate-proof verify` and the human:* demotion
  # both then read as a malformed grant. Fall back to the uid-derived board actor,
  # which is the same derivation and never empty.
  if [[ "$_lead_standing" == "1" ]] && (( ! human )); then
    local _ls_who; _ls_who=$(_gate_authenticated_actor)
    [[ -n "$_ls_who" ]] || _ls_who=$(task_actor "")
    answered_by="lead:standing:${_ls_who}"
  fi

  # DIVE-756: stamp the REAL invoker uid ($SUDO_UID survives `sudo -u agent-X`,
  # unlike need_answered_by) and a tamper-evidence signature over the closure
  # facts. We compute the timestamp in shell (not datetime('now')) so the exact
  # same string is signed AND stored, letting `gate-proof verify` recompute it.
  # Signing needs the root-only key: in a root context we sign in-process; from
  # the non-root trusted path (dashboard exec as claude) we re-exec the root-only
  # `gate-proof sign` over sudo. Best-effort — a box that can't sign just stores
  # an empty sig (verify reports "unsigned"); the answer NEVER fails on this.
  #
  # DIVE-2760: best-effort is still the right posture for the WRITE — losing a
  # human's answer because a box cannot sign would be worse than storing it
  # unsigned — but "never fails" was implemented as "never says anything", and
  # those are different. Record WHY the mint came back empty so the notice below
  # can name it. The three causes have three different remedies and are otherwise
  # indistinguishable from an empty column.
  local _uid; _uid=$(_gate_closure_subject_uid)
  local _ts; _ts=$(date -u '+%Y-%m-%d %H:%M:%S')
  local _vfs=""; [[ "$nt" != "secret" ]] && _vfs="$value"
  local _sig="" _sig_why=""
  if [[ -n "$_uid" ]]; then
    if [[ $EUID -eq 0 ]]; then
      _gate_proof_ensure_key 2>/dev/null || true
      _sig=$(_gate_closure_sign "$id" "$nt" "$_vfs" "$answered_by" "$_ts" "$_uid" 2>/dev/null || echo "")
      [[ -n "$_sig" ]] || _sig_why="running as root, but the gate-proof key could not be created or read on this box"
    else
      _sig=$(_gate_closure_payload "$id" "$nt" "$_vfs" "$answered_by" "$_ts" "$_uid" \
               | sudo -n 5dive gate-proof sign 2>/dev/null || echo "")
      [[ -n "$_sig" ]] || _sig_why="this seat has no passwordless sudo for \`5dive gate-proof sign\` (cli-scoped agents do not; root-all and cli-root seats do)"
    fi
  else
    _sig_why="no invoker uid could be derived, so the closure has no subject to sign for"
  fi
  local _uidsql="NULL"; [[ -n "$_uid" ]] && _uidsql="$_uid"

  # Record the answer. A `secret` gate NEVER stores its value — writing a raw
  # key into this group-claude-readable db is a plaintext-secret-at-rest leak.
  # We only stamp need_answered_at (the "provided" signal); the agent loads the
  # key out-of-band. decision/approval/manual store the value in need_answer.
  if [[ "$nt" == "secret" ]]; then
    (( value_set )) && fail "$E_USAGE" "$ident is a secret gate — do not pass --value; run: 5dive task answer $ident"
    db "UPDATE tasks SET need_answered_at=$(sqlq "$_ts"), need_answered_by=$(sqlq "$answered_by"), need_answered_uid=${_uidsql}, need_answer_sig=$(sqlq "$_sig") WHERE id=${id};"
  else
    (( value_set )) || fail "$E_USAGE" "--value is required (the human's answer)"
    db "UPDATE tasks SET need_answer=$(sqlq "$value"), need_answered_at=$(sqlq "$_ts"), need_answered_by=$(sqlq "$answered_by"), need_answered_uid=${_uidsql}, need_answer_sig=$(sqlq "$_sig") WHERE id=${id};"
  fi

  # DIVE-2760: an unsigned closure is stored, reported OK, and then refused by a
  # broker somewhere else, later, in a different command, to a DIFFERENT agent —
  # with a message about tampering. Say it HERE, at the moment the row is written,
  # because this is the only point where the cause and the remedy are both in view.
  #
  # Three facts the reader cannot derive from an empty column, so all three are
  # stated: (1) the answer LANDED — this is not a failed answer and re-answering
  # is not a retry of a lost write; (2) WHO gets refused is not who is being
  # warned — the signature is minted here by the ANSWERER and nothing re-signs at
  # act time (broker.sh:103 reads the stored `need_answer_sig`, and the acting
  # agent's tier never enters the check), so the refusal surfaces on the maker's
  # next round-trip; (3) the remedy is a different ANSWERER, not a new grant.
  #
  # Deliberately a warn and not a `fail`: `require_sig` is 1 only on the push and
  # deploy root executors, so a gate that no broker will ever check is unharmed by
  # an empty sig and must not lose its answer over one. This fires exactly when
  # something is already broken — the legitimate non-root path (dashboard exec as
  # `claude`) signs fine, so a healthy box prints nothing.
  if [[ -z "$_sig" ]]; then
    warn "gate closure for ${ident} was stored UNSIGNED (need_answer_sig is empty)."
    warn "  The answer IS recorded and the gate is cleared — what is missing is the"
    warn "  DIVE-756 tamper-evidence signature over the closure."
    warn "  why: ${_sig_why:-the signing step produced no signature}"
    warn "  consequence: a DELEGATED PUSH or DEPLOY on ${ident} will be REFUSED later"
    warn "    (\"gate on ${ident} has no valid signed closure\"). The closure is signed by"
    warn "    the ANSWERER, not by the agent acting on it, so that refusal lands on the"
    warn "    maker's next round-trip and reads as tampering rather than as this."
    warn "  fix: have this gate re-answered from a seat that can sign — root"
    warn "    (\`sudo 5dive task answer ${ident} ...\`) or an agent whose sudo covers"
    warn "    \`5dive gate-proof sign\`. Do NOT grant that to a cli-scoped seat: it signs"
    warn "    arbitrary stdin, so the grant forges any closure, including a human:* one."
  fi

  # DIVE-2410: the gate is settled, so its buttons must stop looking tappable.
  # AFTER the write, never before — the settled state is the DB row, and a
  # Telegram edit is best-effort. Covers the human tap, a lead-clear, and a
  # dashboard/CLI answer, since all three land in this one function.
  _task_gate_retire_buttons "$ident" "answered by ${answered_by}" || true

  # INST-4: the gate CLEAR — the row that decides whether this task's timeline
  # reads "zero-human" or "a human authorized it", so it is worth more care than
  # the emits around it.
  #
  # Provenance is read BACK OUT of the row, not taken from $answered_by, for the
  # DIVE-2090 reason spelled out below: the shell variable is the intent to
  # write, and only the persisted column is the state that landed. A ledger that
  # records intent would attest to clears that never happened.
  #
  # The answer VALUE is hashed, never stored — and for a secret gate not even
  # hashed: `_vfs` is empty there by construction, so the one gate type whose
  # payload is a live credential contributes no digest at all. A digest of a
  # short, guessable answer is not the protection it looks like.
  local _lg_prov; _lg_prov=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${id};" 2>/dev/null)
  ledger_emit gate.answered ident="$ident" task_id="$id" actor="${_lg_prov:-unknown}" \
    policy="tier${gtier}:${nt}" out="$_vfs" \
    detail="${nt} gate cleared by ${_lg_prov:-<unrecorded>}$([[ "$_lg_prov" == human:* ]] && echo ' (human touchpoint)')"

  # DIVE-2412 acceptance: WHICH evidence form cleared this gate must be
  # recoverable FROM THE ROW, not only from a log line that can rotate or diverge
  # from it (DIVE-2090). A tap (`nonce`), a dashboard/on-box exec (`sudo-uid`), the
  # tier<2 chat-only proof (`channel-chat`) and the tier-2 citation
  # (`channel-session`) all persist as need_answered_by=human:*, so without this
  # column the four are indistinguishable afterwards — and `channel-session` is the
  # only one that cleared a tier-2 gate with nobody touching a button. That
  # distinction is the audit question this feature creates, so it is stored, not
  # derived. `+`-joined when more than one form was present; `none` when a
  # non-human path (a decision gate, an auto-answer) wrote the row.
  # _hp/_su are function-scope locals initialized to 0 since DIVE-2406, and the
  # other flags are set only on the paths that raise them — hence the :-0
  # defaults, which are belt-and-braces rather than a guess.
  # DIVE-2799: the five append lines that used to sit here are now
  # `_gate_evidence_form`, because the SAME string has to reach the append-only
  # audit log as well and two copies of this vocabulary would drift. The token
  # spelling and order are unchanged, so this column's values are byte-identical
  # to what DIVE-2412 shipped — EXCEPT for the tier-2 decision case below, which
  # they were wrong about.
  #
  # THE `_t2_*` OR IS A BUG FIX, NOT DEFENSIVENESS, and it was found by the
  # harness for this change rather than reasoned out. `_hp`/`_su` are raised ONLY
  # inside the approval/secret/manual/access evidence block, which does not run
  # for a `decision` gate. The tier-2 floor computes its OWN `_t2_hp`/`_t2_su` and
  # never fed them back here. So a tier-2 DECISION gate cleared by a valid nonce
  # stored `human_evidence='none'` — the form was verified, admitted, and then not
  # recorded. Measured on this tree: the t2 audit row read `nonce_valid=1` while
  # the column on the same answer read `none`.
  #
  # That is precisely the population DIVE-2799's body flags as separately
  # unmeasured ("decision-type tier-2 gates ... never reach this audit line"), so
  # a fix that named the form everywhere EXCEPT there would have reproduced the
  # ticket at a different address — the DIVE-2777 shape the body warns about.
  #
  # SCOPED TO THE RECORD ON PURPOSE: `_hp`/`_su` themselves are left alone because
  # DIVE-2406 reads them at the provenance stamp, and this change must not move
  # any authorization or provenance outcome — only what the record SAYS about one.
  # `${_t2_*:-0}` because those locals exist only when the tier-2 branch ran.
  local _evform; _evform=$(_gate_evidence_form \
    "$(( ${_hp:-0} || ${_t2_hp:-0} ))" "$(( ${_su:-0} || ${_t2_su:-0} ))" \
    "${_cs_ok:-0}" "${_cp_ok:-0}" "${_lead_clear:-0}")
  db "UPDATE tasks SET human_evidence=$(sqlq "${_evform:-none}") WHERE id=${id};"

  # DIVE-3128: the RELAY and the TAPPING UID, in their own columns.
  #
  # Written unconditionally (empty when there was no tap) so the columns mean
  # "this is what the answer carried", not "somebody remembered to set them".
  # A reader can now separate the two questions the old single string conflated:
  # `need_answered_by` says who decided, `need_answered_relay` says whose bot
  # carried it.
  #
  # NOT INSIDE THE DIVE-756 SIGNED CLOSURE, and say so rather than let a reader
  # assume otherwise. The closure signs need_answer/at/by/uid — so the HUMAN NAME
  # is tamper-evident, which is the field this ticket is about — while the relay
  # is corroborating context that a raw DB edit could change without failing
  # `gate-proof verify`. Widening the signed payload would invalidate every
  # signature already stored on the board, so it is a separate decision.
  db "UPDATE tasks SET need_answered_relay=$(sqlq "${relay_agent}"), need_answered_tap_uid=$(sqlq "${tap_uid}") WHERE id=${id};"

  # DIVE-3128: THE TAP LEDGER. A button tap was the least-recorded path in the
  # system for the most rigorously evidenced control. Written AFTER the row, and
  # reading the persisted stamp back out rather than the variable, for the
  # DIVE-2090 reason: a ledger built from intent greens identically whether or not
  # the write landed.
  if [[ -n "$tap_uid" || -n "$relay_agent" || -n "$tap_msg" ]]; then
    local _tap_persisted; _tap_persisted=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${id};")
    # THE VERDICT IS THREE-VALUED for the same reason the roster predicate is:
    # `stored` must mean "checked the name against the roster and it was clean",
    # never "could not look". A run with no readable registry says so in the
    # ledger instead of producing a line indistinguishable from a verified one.
    local _tap_verdict="stored"
    if [[ -n "$_attr_why" ]]; then _tap_verdict="refused:${_attr_why}"
    elif (( _attr_unverified )); then _tap_verdict="stored:roster-unmeasured"
    fi
    local _tap_nonce="absent"; [[ -n "$human_proof" ]] && _tap_nonce="presented"
    _gate_tap_log "$ident" "${gtier:-}" "$nt" "$tap_uid" "$tap_username" "$tap_msg" \
      "$relay_agent" "${_tap_name:-}" "$_tap_persisted" \
      "$_tap_nonce" "$_tap_verdict" "$_tap_src" || true
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
  #
  # DIVE-2799: `evidence=` BELONGS HERE most of all, and putting it only at the
  # pre-check sites would have missed the population the ticket flags as
  # separately unmeasured. The approval/secret/manual evidence block does not run
  # for a `decision` gate at all, so a tier-2 decision clear reaches NEITHER
  # pre-check row — "decision-type tier-2 gates never reach this audit line" is
  # written into DIVE-2799's own body as an unmeasured class. This site fires for
  # EVERY answered gate regardless of type, and per the paragraph above its
  # presence implies a WRITE rather than a passed check. So this is the row that
  # makes "grep separates the evidence forms across history" true of the whole
  # population instead of only the human-gate subset.
  # `$_evform` is the SAME string written to `tasks.human_evidence` sixty lines
  # up — deliberately the same variable, not a recomputation, so the column and
  # the log cannot disagree about one answer.
  local _caller4; _caller4=$(_gate_caller_user)
  _task_store_audit_log "task answer gate" ok 0 -- \
    "task=$ident" "type=$nt" "tier=${gtier:-}" "answered_by=$answered_by" \
    "uid=${_uid:-}" "sig=$([[ -n "$_sig" ]] && echo present || echo absent)" \
    "human=$human" "lead_clear=$_lead_clear" "cp_ok=$_cp_ok" \
    "human_claim=$_human_claim" \
    "evidence=${_evform:-none}" "filer_answered=$(_gate_filer_answered "$id" "$_caller4")" \
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
  # DIVE-2406 made this branch REACHABLE for a case that used to slip past it: a
  # lead-cleared loop approval gate whose clearer also passed `--human` was
  # stamped `human:<lead>` and advanced the relay. It is now stamped `lead:<lead>`
  # and does NOT advance — which is what the paragraph above always said should
  # happen ("if a non-human path ever clears it ... the relay simply doesn't
  # advance"); the advance was previously bought with a label that was not true.
  # Deliberately NOT widened to `lead:*`: that would hand a lead the loop-advance
  # authority DIVE-560 reserves for the human, which is a grant, not a relabel.
  # Measured before shipping: 2 answers fleet-wide have ever carried
  # lead_clear=1 + human=1 (DIVE-2121, DIVE-2400) and neither was a loop step, so
  # no live loop changes behaviour — but a future routed loop gate will stall here
  # rather than advance, and that is the intended reading of DIVE-560.
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
      if (( _loop_bounce )); then
        if [[ -n "$_prev" ]]; then
          # DIVE-2228: the fence goes IN THE WHERE, matching the idiom the
          # else-branch above has always used, so a future write here either
          # copies its neighbours or looks visibly different from all of them.
          # THE ${_prev} WRITE IS DELIBERATELY NOT FENCED — it targets a
          # DIFFERENT row, and reopening completed work is the whole point of a
          # bounce. DIVE-2261 preflights the exceptional CANCELLED state before
          # any answer write; a WHERE status fence here would create a partial
          # commit (answered gate, no redo) instead of an honest refusal.
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
  # DIVE-2212: do not make the answerer re-read the ambiguous option as the only
  # confirmation. Name both accounts and declare the authored frame. The raw
  # value remains in the structured need_answer field for compatibility, but the
  # human receipt does not merely echo it back and leave both readings intact.
  local _account_frame=0 _frame_filer="" _frame_answerer="" _frame_note=""
  if [[ "$nt" == "decision" ]] && _gate_option_has_second_person "$value"; then
    _account_frame=1
    _frame_filer=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''), NULLIF(assignee,''), NULLIF(created_by,''), 'unknown') FROM tasks WHERE id=${id};")
    case "$answered_by" in
      human:*)         _frame_answerer="${answered_by#human:}" ;;
      lead:standing:*) _frame_answerer="${answered_by#lead:standing:}" ;;
      lead:*)          _frame_answerer="${answered_by#lead:}" ;;
      auto:*)          _frame_answerer="${answered_by#auto:}" ;;
      *)               _frame_answerer="$answered_by" ;;
    esac
    [[ -n "$_frame_answerer" ]] || _frame_answerer="unknown"
    _frame_note=" — account frame: filer=${_frame_filer}, answerer=${_frame_answerer}; second-person terms in the selected filer-authored option refer to ${_frame_answerer}"
  fi
  ok "$ident answered ($nt) — now ${newstatus}${note}${_frame_note}" \
     '{id:($i|tonumber), status:$st, need_type:$nt, provided:true, need_answer:(if $nt=="secret" then null else $v end), owner:(($o|select(length>0)) // null), pinged:($p=="1"), option_account_frame:(if $af=="1" then {filer:$gf, answerer:$ga, second_person_refers_to:$ga} else null end)}' \
     --arg i "$id" --arg st "$newstatus" --arg nt "$nt" --arg v "$value" --arg o "$owner" --arg p "$pinged" \
     --arg af "$_account_frame" --arg gf "$_frame_filer" --arg ga "$_frame_answerer"
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
