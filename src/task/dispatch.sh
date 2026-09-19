# -------- 5dive task — dispatch --------
#
# Split out of src/cmd_task.sh (DIVE-3278): the ENTRY POINT: `task` usage text, the subcommand dispatcher, the worktree
# reclaim-on-close hook, and the set-* mutators (branch, body, title, overlap,
# budget, wip-cap) plus `task init`.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
# src/cmd_task.sh when the split tree is used (tests source src/cmd_task.sh).
# Function definitions only — never execute this file directly.

# -------- 5dive task — host-shared task queue --------

_task_usage() {
  cat <<USAGE
5dive task — shared task queue (sqlite at ${STATE_DIR}/tasks/tasks.db)

  init                                          one-time root bootstrap of the store
  add <title...> [--body=<text>|--body-file=<path>] [--from=<who>] [--parent=<DIVE-N>]
      [--priority=low|medium|high|urgent] [--branch=<name>]
      [--assignee=<agent|role:<r>|charter:<kw>>]
      [--recurring="<5-field cron>"] [--accept=<criteria>|--accept-file=<path>] [--verify=<cmd>]
      [--verifier=<agent>] [--max-iters=<n>] [--no-verify] [--verify] [--task-budget=<tokens|\$cost>]
      [--review=none|check|rubric|temp|<seat>] [--mutant=<cmd>|--no-mutant=<reason>]
                                          WHO GRADES THIS ROW — pick it when you file it:
        none          nobody. 'task done' closes it outright.       cost: no session
        check         a command grades it (needs --verify=<cmd> AND --mutant=<cmd>).
                      THE PREFERRED DEFAULT for any row whose result a command can
                      state: it spends no grader session.           cost: no session
        rubric        one cheap fixed six-question pass over the bounded claim packet.
                      Any flag, blast-radius path, or --verify escalates to temp.
        temp          one fresh pool session per delivery, gone after.
        <seat>        a pinned standing reviewer grades it in its own session.
        Default when you pass nothing: none for a low-priority row, a bodyless chore
        title, a body tagged mechanical/copy/doc or a body that is one read-back
        command; check when --verify=<cmd> is given; the filing seat when --customer
        is set; temp otherwise — and a row that lands on temp is told, on the created
        line, what it would take to be command-graded instead. The mode is printed
        back with its cost on the 'created DIVE-N' line and shown by 'task ls' /
        'task show'.
      --mutant=<cmd>   THE NEGATIVE CONTROL, required by --review=check (DIVE-4623).
                       The command that BREAKS the delivered tree — 'git apply -R
                       <fix>.patch', 'sed -i s/<new guard>/xx/ src/foo.sh',
                       'git checkout <base> -- src/'. At delivery both arms run from
                       a CLEAN CHECKOUT at the delivered sha: the check must PASS as
                       delivered and must FAIL after the mutant. A check that survives
                       the mutant is vacuous — it would grade every tree green — and
                       the delivery is REFUSED with that as the finding, without
                       booking a grader session. Both arms are recorded on the row.
      --no-mutant=<reason>  the audited escape, for a check that genuinely cannot be
                       inverted (an environment probe, a live-box reachability test).
                       The reason is stored: an unexplained escape and a forgotten
                       flag are otherwise the same state.
      --no-verify / --verify   skip / demand a grader session for THIS row, whatever the
                               box default is ('5dive config verify=always|delivered-only|never')
                               '5dive config verify=never' CAPS --review=temp and --review=<seat>
                               to none (both book a session; the box just said not to spend one) and
                               says so on the created line. 'check' is exempt — a command spends no
                               session. Bare --verify is the one way to buy a row back.
                               A box running '5dive config verify-small=<lines>' also DOWNGRADES at
                               delivery: a PR under that many changed lines, touching nothing in the
                               blast radius (scheduler, task store, credentials, deploy, shared libs,
                               sudo policy, systemd, schema, provisioning), closes without booking a
                               grader session and says so. --verify beats it; --no-verify never beats
                               the opposite, delivery-time UPGRADE (DIVE-2730).
      [--customer] [--already-blocked=<what it blocked>]   escapes for the internal-filing cap
  ls [--status=] [--assignee=] [--mine] [--all] [--recurring]   open rows, priority-ordered
  ls --gated[=human|agent]                      only rows holding a live gate. The 'gate' column is
                                                on EVERY ls: HUMAN:<type> a person owes an answer,
                                                <seat>:<type> an agent does, answered:<retire> the
                                                answer survives only in gate-history, '-' nothing.
                                                --gated=human is exactly the inbox set.
  show <id|DIVE-N>                              full detail + subtasks + blockers
  grade-context <id|DIVE-N> [--check=<path>]    materialize/check the private detached grading
                                                worktree and print the bounded grading packet
  assign <id> <agent>                           reassign
  verifier <id> <agent> [--accept=] [--max-iters=]   attach or re-point the verifier rail
  set-body <id> <text...>|--file=<path> [--append]   replace the body, or append to it
  set-title <id> <text...>                      overwrite the title (audited; refused once closed)
  set-branch <id> <branch>                      bind the row to a git branch
  set-parent <id> <DIVE-N|none>                 attach the row to its parent (audited; works on a
                                                closed row; 'none' detaches). Name the parent by
                                                IDENT — a bare number is the global row id, which
                                                is NOT the ident number
  orphans [--all]                               rows whose assignee/verifier/creator is not a
                                                registered agent (undispatchable, DIVE-3344)
  doctor [--fix <id> [--to=<agent>]           every open row nothing will dispatch, and WHY —
         [--dry-run]]                           no revisit anchor, a stale blocker edge, a park
                                                past its wake or with none, or a seat nothing
                                                wakes. A bare run reports and changes nothing;
                                                each finding names the verb that clears it
                                                (DIVE-3784). --fix runs that verb for ONE named
                                                row, re-deriving the finding first — there is no
                                                --all. A dead lane needs --to=<agent>, and the
                                                destination must itself be a seat something wakes
                                                (DIVE-3826)
  wip-cap-install [--relane=<lane>]             snapshot each lane's actionable count as its
                                                frozen WIP ceiling (deliberate, once)
  set-budget <id> <tokens|\$cost|none>           set this row's token ceiling. A bare token count is ENFORCED
                                                (DIVE-4430): past it the heartbeat parks the row and files a
                                                gate. The figure is the row's OWN — per-turn attribution
                                                cross-checked against a /goal dispatch of this ident
                                                (DIVE-2058) — so an unverified one never parks anything, which
                                                is what DIVE-3343 removed the old guard for. Default
                                                FIVE_TASK_BUDGET_DEFAULT (150M metered); 'none' exempts the
                                                row; the \$cost form is still advisory and belongs to the
                                                per-agent cost budget
  set-overlap <tmpl> <skip|spawn> [bound]       recurring template: does an open instance suppress the next slot?

  start <id>                                    -> in_progress
  done <id> [--result=<text>|--result-file=<path>] [--no-graded-sha]
                                                -> done, or hand to the verifier if one is set
                                                verifiers: put \`graded-sha: <sha>\` in the result;
                                                --no-graded-sha is the audited escape
  deliver <id> --pr=<url> [--result=|--result-file=<path>]   record the delivery PR, hand to the verifier
                               the result must name its EVIDENCE — CHANGED / CHECKED (commands + pass/fail
                               counts) / DELIVERED-SHA / CI / CRITERIA — so the grader RE-RUNS it instead of
                               re-deriving it ('task show' prints the template). --force-unevidenced=<why>
                               is the audited exit. (DIVE-4576)
           [--verify=<cmd>]    grade this row with a COMMAND at delivery — no grader session is booked
  verify <id> [--cmd=] [--result=|--result-file=<path>] [--no-done] [--merge-proof] [--timeout=]
                                                run the check; exit 0 = pass
  reject <id> --feedback="FINDING/FIX/VERIFY"    verifier FAIL: bounce back to the maker
                                                (DIVE-4144: the feedback must name a
                                                FIX, or --no-fix=<why>)
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
      [--options="<first choice spelled out>|<second choice spelled out>"]
      [--recommend="<one of the option texts>"|--recommend-file=<path>]
      [--tier=0|1|2]
                   Spell each option out. A bare letter records nothing once
                   the ask is forwarded, quoted or screenshotted — "recommend:
                   A" is a token with no dictionary. Mistyping is not a reason
                   to shorten them: on --type=decision a --recommend that does
                   not match an --options entry exactly fails here, at your
                   keyboard, before the gate exists; a letter never fails and
                   just means the wrong thing.
      [--needs=<capability>] [--discusses=<why>] [--rubber-stamp-ok="<why>"]
      [--ask-ok="<why>"]   DIVE-4176: a gate that reaches the PAIRED HUMAN is refused
                   when its --ask runs over 25 words or names an ident/sha/branch/
                   path/flag — that text is all he sees. Rewrite it as a choice
                   between outcomes; this flag is the audited exception.
      [--urgent]   a ROUTED gate normally QUEUES for the reviewer's next natural
                   wake instead of waking their session (DIVE-3474). --urgent
                   pings at file time. It is NOT --recommend: "I think the answer
                   is X" and "this cannot wait" are separate claims (measured: 54
                   of 121 answered gates returned the filer's recommendation).
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
  queue [--for=<agent>] [--json]                gates ROUTED TO YOU, filed without waking you
  inbox [--send [--channel-proof=<chat>]]       every unanswered human gate IN THE FLEET (already
                                                fleet-wide; --fleet accepted as a no-op); --send DMs the owner
  gates                                         alias of \`inbox\` (DIVE-4310)
  coordinator [--json]                          the agent fronting the needs-you banner

  loops [--stuck] [--escalate-stuck] [--all] [--runs] [--watch[=secs]] [--kill <loopId>]
  merge <id>                                    merge the PR on a row THIS seat graded PASS (DIVE-3474)
  merge-audit [--limit=N] [--json]              closed rows whose named PR never merged
  merge-unverified [--limit=N] [--since=Nd]     re-derive closes the merge-gate could NOT check
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

# -------- `--help` ON A SUBVERB, ANSWERED IN ONE PLACE --------
#
# `5dive task --help` printed the surface above, but every SUBVERB refused the
# flag. Each subverb parses its own flags, and 34 of those loops end in
# `-*) fail "$E_USAGE" "unknown flag: $1"` — so `5dive task ls --help`, which is
# what an operator types to ask a verb how it works, answered "unknown flag:
# --help" and then printed the usage line of whatever the loop thought it was
# doing, not of `ls`. The nearest thing to a verb-shaped answer anywhere in the
# tree is `5dive self-update --help`, which at least says "takes no arguments".
#
# ANSWERED HERE, before the dispatch, rather than in those 34 flag loops: a
# per-verb edit is 34 places to forget, and the 35th verb ships without it.
#
# THE TEXT IS NOT WRITTEN HERE EITHER. It is READ, at run time, from the two
# places this project already keeps it:
#
#   1. the surface usage above, which documents 41 of the subverbs; failing that,
#   2. the `usage: 5dive task <verb> …` literal the verb itself prints when you
#      get its arguments wrong.
#
# So there is no third copy of the text to drift, and a verb documented in
# NEITHER place is refused BY NAME rather than answered with an invented line —
# which is the failure mode this whole change exists to remove.
# tests/task_subverb_help_unit.sh walks the case statement below, label by
# label, and grades every one of them through this path.

# _task_help_wanted <args…> — do these args ASK for help? `--` ends the flags
# (several subverbs honour it), and only the two exact spellings count: the
# `--help` inside `--ask="… --help …"` is a VALUE, not a question.
_task_help_wanted() {
  local a
  for a in "$@"; do
    case "$a" in
      --)        return 1 ;;
      -h|--help) return 0 ;;
    esac
  done
  return 1
}

# _task_verb_arm <verb> — "<canonical spelling> <function>", read out of
# cmd_task's OWN case statement at run time. Reading it back rather than
# restating it here is what makes an alias (`list`, `view`, `close`, `gates`,
# `new`, `delete`) answer with the usage of the verb it actually runs, with no
# second alias list to rot — the same reason the pre-push rail extracts the
# title regex from the workflow instead of carrying a copy (DIVE-4208).
_task_verb_arm() {
  declare -f cmd_task | awk -v v="$1" '
    /^[[:space:]]+[^ (].*\)$/ {
      lab = $0; sub(/\)[[:space:]]*$/, "", lab); gsub(/[[:space:]]/, "", lab)
      n = split(lab, alt, "|")
      for (i = 1; i <= n; i++) if (alt[i] == v) {
        if ((getline body) > 0) { split(body, f, "[[:space:]]+"); fn = (f[1] == "" ? f[2] : f[1]) }
        print alt[1] " " fn; exit
      }
    }'
}

# _task_verb_own_usage <function> <verb> — the `usage: 5dive task <verb> …` line
# the verb prints itself when its arguments are wrong.
_task_verb_own_usage() {
  local fn="$1" verb="$2" body line
  body=$(declare -f "$fn" 2>/dev/null) || return 1
  # In the BUILT BUNDLE a lazy module is unparsed text until something calls into
  # it (DIVE-4087), so `declare -f` here yields the one-line autoload STUB, which
  # carries no usage text at all. Load the module the stub names, then read it
  # again. The split tree has no stubs and never takes this branch — which is why
  # the harness grades this path through a BUILT BUNDLE and not through src/.
  if [[ "$body" == *_lazy_autoload* ]] && declare -F _load_module >/dev/null 2>&1; then
    local mod="${body#*_lazy_autoload }"; mod="${mod%% *}"
    _load_module "$mod" >/dev/null 2>&1 || return 1
    body=$(declare -f "$fn" 2>/dev/null) || return 1
  fi
  line=$(printf '%s\n' "$body" | grep -o "usage: 5dive task ${verb}[^\"']*" | head -1) || true
  [[ -n "$line" ]] || return 1
  # A few of these literals are printf formats carrying a `\n` and a paragraph of
  # prose after it; take the usage line and leave the escape unrendered.
  printf '%s\n' "${line%%\\n*}"
}

# _task_subverb_help <verb> — print that verb's usage.
#   0  printed it
#   1  not a verb at all (the case below has better words for that than we do)
#   2  a verb this tree documents NOWHERE — say so rather than invent a line
_task_subverb_help() {
  local verb="$1" arm primary fn out=""
  arm=$(_task_verb_arm "$verb") || true
  [[ -n "$arm" ]] || return 1
  primary="${arm%% *}"; fn="${arm#* }"
  out=$(_task_usage 2>/dev/null | awk -v v="$primary" '
    /^  [a-z]/ {
      blk = 0; n = split($1, alt, "|")
      for (i = 1; i <= n; i++) if (alt[i] == v) blk = 1
      if (!blk) next
      if (seen++) { print; next }
      line = $0; sub(/^  /, "", line)
      printf "usage: 5dive task %s\n", line
      next
    }
    /^   / { if (blk) print; next }
    { blk = 0 }') || true
  [[ -n "$out" ]] || out=$(_task_verb_own_usage "$fn" "$primary") || true
  [[ -n "$out" ]] || return 2
  printf '%s\n' "$out"
}

# _task_help_intercept <verb> <args…> — 0 when the args asked for help and it has
# been answered. Kept out of cmd_task's body on purpose: _task_verb_arm reads
# that body back as text, and a second `case` inside it would look like arms.
_task_help_intercept() {
  local verb="$1"; shift
  _task_help_wanted "$@" || return 1
  local rc=0
  _task_subverb_help "$verb" || rc=$?
  case $rc in
    0) return 0 ;;
    2) fail "$E_USAGE" "5dive task $verb: no usage text — the verb is documented neither in '5dive task --help' nor in its own arguments check" ;;
  esac
  return 1
}

cmd_task() {
  [[ $# -gt 0 ]] || { _task_usage; mark_reported; exit "$E_USAGE"; }
  local sub="$1"; shift
  # `--help` after a subverb is a question about THAT verb, not an unknown
  # flag. Answered before the dispatch; see the block above.
  if _task_help_intercept "$sub" "$@"; then return 0; fi
  case "$sub" in
    init)            cmd_task_init "$@" ;;
    add|new)         cmd_task_add "$@" ;;
    ls|list)         cmd_task_ls "$@" ;;
    show|view)       cmd_task_show "$@" ;;
    grade-context)   cmd_task_grade_context "$@" ;;
    gate-history)    cmd_task_gate_history "$@" ;;
    assign)          cmd_task_assign "$@" ;;
    set-branch)      cmd_task_set_branch "$@" ;;
    set-body)        cmd_task_set_body "$@" ;;
    set-title)       cmd_task_set_title "$@" ;;
    set-parent)      cmd_task_set_parent "$@" ;;   # DIVE-3275 re-parent a filed row
    set-budget)      cmd_task_set_budget "$@" ;;
    set-overlap)     cmd_task_set_overlap "$@" ;;
    wip-cap-install) cmd_task_wip_cap_install "$@" ;;
    orphans)         cmd_task_orphans "$@" ;;       # DIVE-3344 undispatchable rows
    doctor)          cmd_task_doctor "$@" ;;        # DIVE-3784 every undispatchable class
    start)           cmd_task_start "$@" ;;
    done|close)      cmd_task_done "$@" ;;
    deliver)         cmd_task_deliver "$@" ;;
    merge)           cmd_task_merge "$@" ;;         # DIVE-3474 verifier merges what IT graded
    merge-audit)     cmd_task_merge_audit "$@" ;;   # DIVE-1935 retrospective sweep
    grader-replay)   cmd_task_grader_replay "$@" ;;  # DIVE-4164 dry-run capacity replay
    grader-tick)     cmd_task_grader_tick "$@" ;;    # DIVE-4164 pool lane (dark by default)
    merge-unverified) cmd_task_merge_unverified "$@" ;;  # DIVE-3526 consume the unverified stamp
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
    queue)           cmd_task_queue "$@" ;;         # DIVE-3474 gates routed TO ME
    # DIVE-4310: `gates` is the name a human reaches for — measured on lodar's
    # box, where `5dive task gates` returned "unknown task command" and the verb
    # that answers it is spelled `inbox`. Pure alias, same function, so the two
    # spellings can never diverge.
    inbox|gates)     cmd_task_inbox "$@" ;;
    coordinator)     cmd_task_coordinator "$@" ;;
    answer)          cmd_task_answer "$@" ;;
    clear-recs)      cmd_task_clear_recs "$@" ;;
    precedent)       cmd_task_precedent "$@" ;;
    pfr-autoclear)   cmd_task_pfr_autoclear "$@" ;;   # DIVE-3481 inert push-for-review auto-clear switch
    gate-undo-window) cmd_task_gate_undo_window "$@" ;;  # DIVE-4154 arm D: hold the phone ping for a 2-minute undo window
    track-record)    cmd_task_track_record "$@" ;;   # DIVE-3694 per-filer track-record auto-clear switch + view
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
    || fail "$E_VALIDATION" "$ident is already $st — bounce it back first: 5dive task reject $ident --feedback=\"FINDING/FIX/VERIFY\""
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
  # DIVE-4419: the check is on the RESULT of the edit, so an append that would
  # cross the cap is refused while a REPLACE that shrinks an oversized row still
  # lands — that replace is the documented way out, and a guard that blocked it
  # would trap exactly the rows it exists to prevent.
  _task_body_size_guard "$newbody" "$ident" "task set-body"
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
  # DIVE-3499: a body write is the third routing verb — it is how work is handed
  # over WITHOUT a message (rule 0: "handing work back is a row, not a message").
  # The measured ping this row exists to delete was exactly this shape: ops wrote
  # a full triage onto DIVE-3330's body, the row was already todo and already
  # assignee=dev2, and ops pinged a human-shaped seat anyway because nothing told
  # it the write had landed anywhere a person would see. Cannot fail; see
  # src/lib/routing_receipt.sh.
  local _sb_owner; _sb_owner=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};" 2>/dev/null || echo "")
  # The `|| true` and the stderr drop are the additive-only contract AT THE CALL
  # SITE, not belt-and-braces: a tree that sources a SUBSET of src/ — which is
  # what most harnesses do — has no routing_receipt, and bash turns that into
  # rc=127 on a verb that had already succeeded. Measured on
  # tests/task_reject_trace_unit.sh before this line existed. The wrapper's own
  # containment cannot cover the case where the wrapper is what is missing.
  routing_receipt "$ident" "$_sb_owner" "owns it (body $mode)" 2>/dev/null || true
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
  local lane n installed=0 lines="" skipped_lanes=""
  while IFS= read -r lane; do
    [[ -n "$lane" ]] || continue
    [[ -z "$one" || "$lane" == "$one" ]] || continue
    if [[ -z "$one" ]]; then
      local have; have=$(db "SELECT value FROM task_prefs WHERE key=$(sqlq "wip_cap:$lane");" 2>/dev/null || echo "")
      [[ "$have" =~ ^[0-9]+$ ]] && continue     # already installed: never re-snapshot
    fi
    # DIVE-3344: this loop reads the SAME unvalidated column, and it minted
    # `wip_cap:cli` in task_prefs — a lane ceiling for an agent that does not
    # exist. A cap on a name nothing dispatches to is not a control, it is a row
    # that makes the fake lane look real to the next reader of task_prefs.
    if ! _task_roster_has "$lane" && [[ "$_TASK_ROSTER_STATE" == "ok" ]]; then
      skipped_lanes+="  ${lane}"$'\n'; continue
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
  # NAMED, not silently dropped. A skip that prints nothing is how `wip_cap:cli`
  # got there in the first place — the installer's own output said only how many
  # lanes it wrote.
  ok "installed WIP caps for ${installed} lane(s)${lines:+
$lines}${skipped_lanes:+
  skipped — not a registered agent (see: 5dive task orphans):
$skipped_lanes}" '{installed:$n, skippedLanes:($s|split("\n")|map(select(length>0)|ltrimstr("  ")))}' \
    --argjson n "${installed:-0}" --arg s "$skipped_lanes"
}

# DIVE-3344 — the SURFACER. Prevention at the write does nothing for the rows
# already sitting on a dead lane, and those are the whole reported symptom: the
# customer's 7 `assignee='cli'` rows and our 3 sat silent for months because an
# undispatchable row is indistinguishable from a row whose turn has not come.
#
# Three columns, because all three are dispatch or routing targets and all three
# were unvalidated:
#   assignee    -> nothing wakes it. The row is never picked.
#   verifier    -> the row orphans at HANDOFF, one step later.
#   created_by  -> every gate this row files routes to a creator who is not there
#                  (the reported DIVE-350, orphaned since 2026-07-29). Sentinels
#                  (`cli`, `council`, `lodar`, …) are legal here and excluded.
#
# REFUSES TO ANSWER when the roster is unestablished rather than calling every row
# an orphan — an unreadable registry would otherwise print the whole board as
# broken, which is the loudest possible way to be wrong.
cmd_task_orphans() {
  tasks_db_init
  local all=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) all=1 ;;   # include closed rows (historical audit)
      -*) fail "$E_USAGE" "unknown flag: $1 (usage: 5dive task orphans [--all])" ;;
    esac
    shift
  done
  local lanes; lanes=$(_task_roster_sql_notin)
  if [[ -z "$lanes" ]]; then
    fail "$E_GENERIC" "cannot list orphans: the agent roster is ${_TASK_ROSTER_STATE} — with no roster every row would look orphaned, which is worse than no answer. Fix the registry first: 5dive doctor"
  fi
  local sentinels="" p
  for p in $_TASK_PRINCIPAL_SENTINELS; do sentinels+="${sentinels:+,}$(sqlq "$p")"; done
  local scope="status IN ('todo','in_progress','blocked')"
  [[ -n "$all" ]] && scope="1=1"
  # NULLIF(...,'') so dbfmt's null-key pruning drops the columns that found
  # nothing — a present `badAssignee` key then MEANS a bad assignee.
  local q="SELECT ident, status,
       NULLIF(CASE WHEN assignee   IS NOT NULL AND assignee   NOT IN (${lanes}) THEN assignee   ELSE '' END,'') AS badAssignee,
       NULLIF(CASE WHEN verifier   IS NOT NULL AND verifier   NOT IN (${lanes}) THEN verifier   ELSE '' END,'') AS badVerifier,
       NULLIF(CASE WHEN created_by IS NOT NULL AND created_by NOT IN (${lanes}) AND created_by NOT IN (${sentinels}) THEN created_by ELSE '' END,'') AS badCreator,
       substr(title,1,60) AS title
     FROM tasks
     WHERE ${scope} AND kind='standard'
       AND (   (assignee   IS NOT NULL AND assignee   NOT IN (${lanes}))
            OR (verifier   IS NOT NULL AND verifier   NOT IN (${lanes}))
            OR (created_by IS NOT NULL AND created_by NOT IN (${lanes}) AND created_by NOT IN (${sentinels})))
     ORDER BY id;"
  local rows; rows=$(dbfmt -json "$q")
  # dbfmt -json prints NOTHING for an empty result set (deliberate, DIVE-1610) —
  # not "[]". Normalise before jq so a clean board is a clean board and not a
  # parse error reported as zero orphans.
  [[ -n "$rows" ]] || rows='[]'
  local n; n=$(printf '%s' "$rows" | jq 'length')
  local scope_label; scope_label=$([[ -n "$all" ]] && echo all || echo open)
  if [[ "${n:-0}" == "0" ]]; then
    ok "no orphaned rows — every assignee, verifier and creator on the ${scope_label} board names a registered agent (a real NAME is not the same as a dispatchable row: 5dive task doctor)" \
       '{orphans:0, scope:$s}' --arg s "$scope_label"
    return 0
  fi
  # Read the JSON back rather than the raw sqlite3 output: `db` uses the default
  # `|` separator and a task TITLE may contain one, which would split a row.
  local out="" line ident st marks val col hint
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ident=$(printf '%s' "$line" | jq -r '.ident'); st=$(printf '%s' "$line" | jq -r '.status')
    marks=""
    for col in badAssignee badVerifier badCreator; do
      val=$(printf '%s' "$line" | jq -r --arg k "$col" '.[$k] // empty')
      [[ -n "$val" ]] || continue
      hint=$(_task_roster_nearmiss "$val")
      marks+="${marks:+, }${col#bad}='${val}'"
      # NOT `$([[ -n "$hint" ]] && printf …)`: on the no-hint path that
      # substitution exits 1, and an assignment takes the substitution's status —
      # which under the bundle's `set -euo pipefail` killed this verb mid-listing
      # with "exited 1 without reporting a reason".
      if [[ -n "$hint" ]]; then marks+=" (did you mean '${hint}'?)"; fi
    done
    out+="  ${ident}  [${st}]  ${marks}"$'\n'"        $(printf '%s' "$line" | jq -r '.title // ""')"$'\n'
  done < <(printf '%s' "$rows" | jq -c '.[]')
  warn "${n} row(s) name something that is not a registered agent — an undispatchable row is never picked and never says so:
${out}Re-point with: 5dive task assign <ident> <agent>   ·   roster: 5dive agent list
A bad NAME is one of four ways a row goes undispatchable — for the other three (no revisit anchor, a stale blocker edge, a park past its wake): 5dive task doctor"
  ok "" '{orphans:($n|tonumber), scope:$s, rows:$rows}' \
    --arg n "$n" --arg s "$scope_label" --argjson rows "$rows"
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
    || fail "$E_VALIDATION" "$ident is already $st — its title is frozen (closed tasks don't get retro-edited; bounce it back first with: 5dive task reject $ident --feedback=\"FINDING/FIX/VERIFY\")"
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

# ---------------------------------------------------------------------------
# `5dive task set-parent <id|DIVE-N> <DIVE-N|id|none>` — DIVE-3275.
#
# `parent_id` was INSERT-only: `task add --parent=<id>` was the sole moment a
# parent edge could ever be written, so a row split out of another one and filed
# without `--parent` could never be attached afterwards. The relationship then
# survives only as prose in a body, and `task show <parent>` renders no edge to
# it. That already cost a real verification: DIVE-3138 was split out of DIVE-2895
# in words but filed unparented, so the maker closing DIVE-2895 asserted an item
# was blocked on work DIVE-3138 had finished 2h36m earlier. The fix list said
# "set parent_id on DIVE-3138" and there was no verb that could.
# (community/wiki/a-split-out-row-with-no-parent-link-is-invisible-to-the-row-it-came-from.md)
#
# A CLOSED ROW CAN BE RE-PARENTED — deliberately NOT set-title's refusal (spec
# decided by olivia, 2026-08-12). Closing freezes the record of what was
# ASSERTED — body and result, the text a later reader quotes back. `parent_id` is
# not an assertion by the closer; it is a navigation edge, and its ABSENCE is the
# entire defect: DIVE-3138 was already closed when its missing edge produced the
# false premise. A blanket closed-row refusal would ship a verb that cannot fix
# the case that motivated it. So: audited like set-title, and it does not reopen
# the row, touch `done_at`, or bump `updated_at` — the write is to the graph, and
# nothing about the closed record's own timeline changes.
cmd_task_set_parent() {
  tasks_db_init
  local task="" parent="" parent_from_flag=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parent=*)  parent="${1#*=}"; parent_from_flag=1 ;;
      --)          shift; positional+=("$@"); break ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           positional+=("$1") ;;
    esac
    shift
  done
  task="${positional[0]:-}"
  if (( parent_from_flag )); then
    [[ ${#positional[@]} -le 1 ]] \
      || fail "$E_USAGE" "--parent conflicts with the positional parent — name the parent exactly once"
  else
    parent="${positional[1]:-}"
  fi
  [[ -n "$task" && -n "$parent" ]] \
    || fail "$E_USAGE" "usage: 5dive task set-parent <id|DIVE-N> <DIVE-N|none>   (none detaches)"
  [[ ${#positional[@]} -le 2 ]] \
    || fail "$E_USAGE" "usage: 5dive task set-parent <id|DIVE-N> <DIVE-N|none>   (got ${#positional[@]} positional arguments)"

  _task_resolve_ref_strict "$task" "the task to re-parent"
  local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"

  # A recurring TEMPLATE has no parent by construction — `task add` already
  # refuses `--recurring` with `--parent` because instances are top-level. Say
  # the same thing here rather than letting the graph disagree with the filer.
  local kind; kind=$(db "SELECT COALESCE(kind,'standard') FROM tasks WHERE id=${id};")
  [[ "$kind" != "recurring" ]] \
    || fail "$E_VALIDATION" "$ident is a recurring TEMPLATE — templates are top-level by construction (task add refuses --recurring with --parent for the same reason)"

  local prior_pid prior_ident
  prior_pid=$(db "SELECT COALESCE(parent_id,'') FROM tasks WHERE id=${id};")
  prior_ident="none"; [[ -n "$prior_pid" ]] && prior_ident=$(ident_of "$prior_pid")

  local new_pid="" new_ident="none"
  if [[ "${parent,,}" != "none" ]]; then
    _task_resolve_ref_strict "$parent" "the parent"
    new_pid="$RESOLVED_TASK_ID"; new_ident="$RESOLVED_TASK_IDENT"
    # `parent_id INTEGER REFERENCES tasks(id) ON DELETE CASCADE` — a row that is
    # its own parent is not merely odd, it is a cycle of length one, and every
    # tree walker here assumes acyclicity.
    [[ "$new_pid" != "$id" ]] \
      || fail "$E_VALIDATION" "$ident cannot be its own parent"
    _task_parent_cycle_check "$id" "$new_pid" "$ident" "$new_ident"
  fi

  if [[ "${prior_pid:-}" == "${new_pid:-}" ]]; then
    _task_print_children "${new_pid:-$prior_pid}" "$new_ident"
    ok "$ident parent unchanged (already $new_ident)" \
       '{ident:$id, changed:false, parent:$p, children:($c|split(",")|map(select(length>0)))}' \
       --arg id "$ident" --arg p "$new_ident" --arg c "$_TASK_CHILDREN_CSV"
    return 0
  fi

  local set_sql="NULL"; [[ -n "$new_pid" ]] && set_sql="$new_pid"
  db "UPDATE tasks SET parent_id=${set_sql} WHERE id=${id};"
  # The PRIOR parent is the payload: without it the audit row records that a
  # re-parent happened and destroys the only copy of the edge it replaced.
  _task_store_audit_log "task set-parent" "ok" 0 -- \
    "task=$ident" "actor=$(task_actor)" "prior=$prior_ident" "new=$new_ident" || true

  # A parent edge is verified by the READER's view, not by the writer's exit code
  # — that is the whole lesson of the wiki page above. Printing the parent's
  # resulting child list makes the command self-verifying and removes the
  # follow-up `task show <parent>` everyone forgets. On a detach we print the
  # FORMER parent's list, which is where the absence has to be visible.
  local shown_pid="$new_pid" shown_ident="$new_ident"
  [[ -n "$shown_pid" ]] || { shown_pid="$prior_pid"; shown_ident="$prior_ident"; }
  _task_print_children "$shown_pid" "$shown_ident"
  ok "$ident parent $prior_ident -> $new_ident" \
     '{ident:$id, changed:true, prior_parent:$pp, parent:$p, children:($c|split(",")|map(select(length>0)))}' \
     --arg id "$ident" --arg pp "$prior_ident" --arg p "$new_ident" \
     --arg c "$_TASK_CHILDREN_CSV"
}

# Refuse a cycle: walk the prospective parent's ancestor chain and refuse if the
# child appears in it. The walk is BOUNDED — a pre-existing cycle in the store
# (from a raw sqlite write, say) must make this command refuse, never hang.
_task_parent_cycle_check() {
  local child_id="$1" walk="$2" child_ident="$3" parent_ident="$4"
  local hops=0 seen=""
  while [[ -n "$walk" ]]; do
    if (( ++hops > 64 )); then
      fail "$E_VALIDATION" "ancestor chain above $parent_ident is deeper than 64 rows or already cyclic — refusing rather than walking it further (chain seen: ${seen#,})"
    fi
    seen+=",$(ident_of "$walk")"
    walk=$(db "SELECT COALESCE(parent_id,'') FROM tasks WHERE id=${walk};")
    [[ "$walk" != "$child_id" ]] \
      || fail "$E_VALIDATION" "that would make a cycle: $child_ident is already an ancestor of $parent_ident (chain: ${seen#,})"
  done
  return 0
}

# Render the parent's children, and expose them as a CSV for the --json arm.
_TASK_CHILDREN_CSV=""
_task_print_children() {
  local pid="$1" pident="$2" rows=""
  _TASK_CHILDREN_CSV=""
  [[ -n "$pid" ]] || return 0
  rows=$(db "SELECT ident||'  ['||status||']  '||title FROM tasks WHERE parent_id=${pid} ORDER BY id;")
  _TASK_CHILDREN_CSV=$(db "SELECT group_concat(ident, ',') FROM (SELECT ident FROM tasks WHERE parent_id=${pid} ORDER BY id);")
  (( JSON_MODE )) && return 0
  echo "subtasks of ${pident} now:"
  if [[ -n "$rows" ]]; then
    printf '%s\n' "$rows" | indent2
  else
    printf '%s\n' "(none)" | indent2
  fi
  return 0
}

cmd_task_init() {
  require_root "task init"
  tasks_db_init
  ok "tasks store ready at $TASKS_DB" '{path:$p}' --arg p "$TASKS_DB"
}
