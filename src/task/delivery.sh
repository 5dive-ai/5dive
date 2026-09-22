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

# ── DIVE-4623 — THE CHECK MUST BE ABLE TO FAIL, AND WE MAKE IT FAIL ────────
#
# AXIS: the autonomy number. Measured by main on 2026-09-19 over seven days of
# per-seat transcripts (`message.usage`, quota basis): the single grader seat
# burned 2318.8M tokens against the maker seat's 2307.0M — 97.8% of it cache-read,
# a second full session re-loading a diff that had already been made. Every
# ordinary row is paid for twice. `--review=check` already removes the second
# payment for a command-graded row (DIVE-4576 above), and it was still not the
# default, for one honest reason: NOTHING PROVED THE COMMAND COULD GO RED.
# `--verify=true` is a passing grade on every tree that will ever exist, and in
# the column and on the board it is indistinguishable from a real acceptance run.
#
# So the mode carries a NEGATIVE CONTROL and the delivery RUNS it. Both arms, from
# a clean checkout at the delivered sha:
#
#   arm A (as delivered)       the check must PASS
#   arm B (after the mutant)   the check must FAIL
#
# Arm B passing means the check is vacuous, and a vacuous check is not weaker
# evidence than a real one — it is ZERO evidence, the same distinction DIVE-3175
# drew about testing the instrument instead of the product. So the delivery is
# refused with that as the finding.
#
# WHY A CLEAN CHECKOUT AND NOT THE MAKER'S TREE. The maker's worktree is dirty by
# construction at delivery time (that is what was just pushed), and it is the one
# tree where a check can pass for a reason that is not in the commit — an
# untracked fixture, a stale build output, an export in the shell. Arm A from a
# detached worktree at the delivered sha is therefore a second finding in its own
# right when it goes red: it says the pushed tree does not carry what the grade
# claims. Arm B additionally needs a tree it may DESTROY, so it gets its own.
#
# WHY THIS RUNS bash ITSELF INSTEAD OF DELEGATING TO cmd_task_verify, which is the
# opposite of the choice the DIVE-4576 block above makes, deliberately: arm B's
# pass/fail is INVERTED. A red arm B is the healthy outcome, and routing it through
# the verb that records grades would stamp a ❌ FAIL on a row whose control just
# worked — the verdict and the record would disagree. Nothing else that verb owns
# (the result-preservation rail, the merge hold, the ledger receipt) applies to a
# run whose whole purpose is to be thrown away. The PRIMARY grade still goes
# through it, unchanged.
#
# ── DIVE-4825: THE COMPUTED GRADE TABLE — no model in the mechanical grade ───
#
# DIVE-4623 gave the command grade two arms (as-delivered, mutated) and a prose
# receipt. What a grader session still did by hand, ~78 model turns at a time,
# was the other half of the same procedure: stand up a CONTROL tree with the
# changed SOURCE reverted to the merge-base and show the new harness goes red on
# it; run each mutant and name the arm that killed it; then write one table.
#
# Every one of those steps is deterministic given the delivered sha. A model
# executing them spends a ~200k-token context per shell call (the measurement on
# DIVE-4825: 78 calls / 15.7M cache-read for ONE grade, 98 % of it cache reads),
# and a script does not skip step 4 at hour 50. So the executor is a script and
# the model is kept for the thing a script cannot do: reading the diff.
#
# WHAT IS COMPUTED, AND WHAT IS STILL A MODEL'S JOB.
#   computed  suite at the delivered sha · control (changed source @ base) ·
#             each mutant killed-or-SURVIVED · the rails · the verdict
#   model     any FLAGGED line, and only that line · rows with no computable
#             harness · the sampled read of a green table (intent, honesty)
#
# A GREEN TABLE COSTS ZERO GRADER TOKENS: the row is stamped graded->merge on
# the delivery path that DIVE-4576 already built. A FLAGGED table does NOT
# refuse and does NOT close — it writes the table onto the row and falls through
# to the ordinary grader route, so the seat that wakes reads the table in its
# goal and re-derives the flagged line ALONE.

# `_task_grade_arm_counts <output>` — "<pass> <fail> <failing-ids csv>" read off
# the house harness convention (`ok   - <name>` / `FAIL - <name>`).
#
# The ID is the arm name's FIRST TOKEN because that is what the harnesses
# actually name them (`A2c`, `D4b`) and what a maker's CHECKED claim quotes. A
# harness that does not use the convention yields 0 0 "" and the caller degrades
# to the exit status — a parse miss must not be readable as "zero failures".
_task_grade_arm_counts() {  # <output>
  printf '%s\n' "${1:-}" | awk '
    /^[[:space:]]*ok[[:space:]]+-[[:space:]]+/   { p++; next }
    /^[[:space:]]*FAIL[[:space:]]+-[[:space:]]+/ {
      f++; s=$0; sub(/^[[:space:]]*FAIL[[:space:]]+-[[:space:]]+/,"",s);
      split(s,a,/[[:space:]]+/); ids = ids (ids?",":"") a[1]; next }
    END { printf "%d %d %s", p+0, f+0, ids }'
}

# `_task_grade_changed_src <repo> <sha>` — the changed NON-TEST files, NUL-free,
# one per line. Tests are excluded on purpose: the control tree is "the new
# harness against the OLD source", so reverting the harness too would revert the
# very thing being controlled and the arm would go vacuously green.
# DELIBERATELY `ACMR` AND NOT `D`: a file the diff DELETED is not restored in the
# control tree. Restoring it would run the new harness against a tree that is
# neither head nor base, and the landing assert catches the one case this makes
# vacuous — a diff that ONLY deletes source leaves the control byte-identical to
# head and prints DID NOT APPLY, which flags rather than passes.
_task_grade_changed_src() {  # <repo> <sha> <base>
  git -C "$1" diff --name-only --diff-filter=ACMR "$3" "$2" -- 2>/dev/null \
    | grep -Ev '^(tests/|test/|.*_test\.|.*\.test\.)' || true
}

# `_task_grade_worktree <repo> <sha> <dir>` — a clean detached checkout, or rc 1.
_task_grade_worktree() {  # <repo> <sha> <dir>
  git -C "$1" worktree add --detach -q "$3" "$2" >/dev/null 2>&1
}

# `_task_grade_mutant_specs <repo> <sha> <ident> <stored-mutant>` — "<id>\t<cmd>"
# per line. `tests/mutants/<ident>.sh` (one `mN() { … }` per mutant, run from the
# tree root) is the machine-readable form DIVE-4825 asked for; the row's single
# `mutant_command` stays the fallback so every DIVE-4623 row keeps its control.
_task_grade_mutant_specs() {  # <repo> <sha> <ident> <stored-mutant>
  local repo="$1" sha="$2" ident="$3" stored="$4" spec="tests/mutants/${3}.sh" body fn
  if body=$(git -C "$repo" show "${sha}:${spec}" 2>/dev/null) && [[ -n "$body" ]]; then
    while IFS= read -r fn; do
      [[ -n "$fn" ]] || continue
      printf '%s\t%s\n' "$fn" ". ${spec} && ${fn}"
    done < <(printf '%s\n' "$body" | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*()[[:space:]]*{.*$/\1/p')
    return 0
  fi
  [[ -n "$stored" ]] && printf 'M1\t%s\n' "$stored"
  return 0
}

# `_task_grade_table <ident> <check> <stored-mutant> <claimed-failing-csv>` —
# computes the whole pass and sets:
#   _TASK_GRADE_TABLE  the one table, verbatim, for the row
#   _TASK_GRADE_FLAGS  newline-separated flag lines (empty = PASS)
#   _TASK_GRADE_RC     0 pass · 1 flagged · 2 could not compute · 3 red at sha
#                      · 4 vacuous (a mutant the check could not kill at all)
_TASK_GRADE_TABLE=""; _TASK_GRADE_FLAGS=""; _TASK_GRADE_RC=0
_task_grade_table() {  # <ident> <check> <stored-mutant> <claimed-failing-csv>
  local ident="$1" check="$2" stored="$3" claimed="${4:-}"
  _TASK_GRADE_TABLE=""; _TASK_GRADE_FLAGS=""; _TASK_GRADE_RC=0
  local repo sha base
  repo=$(git rev-parse --show-toplevel 2>/dev/null) || repo=""
  sha=$(git rev-parse HEAD 2>/dev/null) || sha=""
  if [[ -z "$repo" || -z "$sha" ]]; then
    _TASK_GRADE_TABLE="GRADE ${ident} — NOT COMPUTED: 'task deliver' ran outside a git checkout, so there is no delivered sha to check out. Nothing below proves the check can fail."
    _TASK_GRADE_RC=2; return 2
  fi
  base=$(git -C "$repo" merge-base "$sha" origin/main 2>/dev/null || printf '')

  local scratch; scratch=$(mktemp -d "${TMPDIR:-/tmp}/5dive-grade.XXXXXX") || {
    _TASK_GRADE_TABLE="GRADE ${ident} — NOT COMPUTED: no scratch directory for the clean checkouts."
    _TASK_GRADE_RC=2; return 2; }
  local -a _gt_wts=()
  _gt_cleanup() {
    local d
    for d in "${_gt_wts[@]:-}"; do
      [[ -n "$d" ]] || continue
      git -C "$repo" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"
    done
    rm -rf "$scratch"
  }
  local tmo=(); command -v timeout >/dev/null 2>&1 \
    && tmo=(timeout "${FIVEDIVE_CONTROL_ARM_TIMEOUT:-900}")
  local flags="" lines=""

  # ── suite: the harness at the delivered sha, from a CLEAN checkout ──────────
  local wtS="$scratch/head" rcS=0 outS="" cS
  if ! _task_grade_worktree "$repo" "$sha" "$wtS"; then
    _gt_cleanup
    _TASK_GRADE_TABLE="GRADE ${ident} — NOT COMPUTED: could not create a clean checkout of ${sha:0:12}."
    _TASK_GRADE_RC=2; return 2
  fi
  _gt_wts+=("$wtS")
  if outS=$( (cd "$wtS" && "${tmo[@]}" bash -c "$check") 2>&1 ); then rcS=0; else rcS=$?; fi
  cS=$(_task_grade_arm_counts "$outS")
  lines+="suite   ${check}"$'\n'"        head @ ${sha:0:12}   $(awk '{printf "%s pass %s fail", $1, $2}' <<<"$cS")  rc=${rcS}"$'\n'
  if (( rcS != 0 )); then
    _gt_cleanup
    _TASK_GRADE_TABLE="GRADE ${ident} @ ${sha:0:12}"$'\n'"${lines}VERDICT computed: RED AT SHA — the check FAILED from a clean checkout at the delivered sha."$'\n'"        output tail: $(printf '%s\n' "$outS" | tail -n 10)"
    _TASK_GRADE_RC=3; return 3
  fi

  # ── control: the SAME harness, changed source reverted to the merge-base ────
  # This is the arm the grader session used to build by hand, and the one that
  # says the diff is what makes the suite green. A control that stays GREEN is a
  # harness that does not test the change — which is the exact defect a passing
  # exit status cannot see, so it is a FLAG, never a pass.
  # Did ANY arm show this check can go red? The source-revert control counts:
  # a harness proven to fail on the pre-fix source is evidence the mutant arm
  # exists to provide, so a row with a healthy control and no mutant is not the
  # uncontrolled case DIVE-4623 was written about.
  local ctl_healthy=0
  local ctl_line="control NOT RUN — no merge-base with origin/main"
  if [[ -n "$base" ]]; then
    local -a srcs=(); mapfile -t srcs < <(_task_grade_changed_src "$repo" "$sha" "$base")
    if (( ${#srcs[@]} == 0 )); then
      ctl_line="control NOT RUN — the diff touches no non-test file, so there is no source to revert"
    else
      local wtC="$scratch/control" rcC=0 outC="" cC
      if _task_grade_worktree "$repo" "$sha" "$wtC"; then
        _gt_wts+=("$wtC")
        # A FILE THE DIFF ADDED CANNOT BE CHECKED OUT FROM THE BASE — it is not
        # there. It is REMOVED instead, which is what "this file at the base"
        # means for a new file. This is not a corner: a delivery that adds a
        # changelog fragment (every one of ours) hits it, and `git checkout
        # <base> -- <paths>` fails ATOMICALLY on the missing path, so one added
        # file silently reverts NOTHING and the control then grades the
        # delivered tree twice. Measured on DIVE-4814's real delivery.
        local _cp; local -a _c_have=() _c_new=()
        for _cp in "${srcs[@]}"; do
          if git -C "$repo" cat-file -e "${base}:${_cp}" 2>/dev/null; then _c_have+=("$_cp")
          else _c_new+=("$_cp"); fi
        done
        (( ${#_c_have[@]} )) && ( cd "$wtC" && git checkout -q "$base" -- "${_c_have[@]}" >/dev/null 2>&1 ) || true
        (( ${#_c_new[@]} ))  && ( cd "$wtC" && git rm -q -f --ignore-unmatch -- "${_c_new[@]}" >/dev/null 2>&1 ) || true
        # THE REVERT MUST HAVE LANDED. A control tree byte-identical to head
        # grades the head twice and reads as a healthy red-free arm; that is the
        # "mutation not applied" failure, and it fails loudly here.
        # AGAINST HEAD, not against the index: `git checkout <tree> -- <path>`
        # updates BOTH, so a plain `git diff` is clean however much the file
        # moved, and the landing assert would pass on every revert it made.
        if ( cd "$wtC" && git diff --quiet HEAD -- "${srcs[@]}" >/dev/null 2>&1 ); then
          ctl_line="control DID NOT APPLY — ${srcs[*]} is byte-identical at ${base:0:12} and ${sha:0:12}, so this arm graded the delivered tree twice"
          flags+="CONTROL-NOT-APPLIED"$'\n'
        else
          if outC=$( (cd "$wtC" && "${tmo[@]}" bash -c "$check") 2>&1 ); then rcC=0; else rcC=$?; fi
          cC=$(_task_grade_arm_counts "$outC")
          local pC fC idsC; read -r pC fC idsC <<<"$cC"
          ctl_line="control ${srcs[*]} @ ${base:0:12}   ${pC} pass ${fC} fail  rc=${rcC}  failing={${idsC}}"
          if (( rcC == 0 )); then
            ctl_line+="  ← GREEN: the harness does not test this change"
            flags+="CONTROL-GREEN"$'\n'
          else
            ctl_healthy=1
          fi
          if (( rcC != 0 )) && [[ -n "$claimed" ]]; then
            if [[ ",$(tr ' ' ',' <<<"$idsC")," == ",$(tr ' ' ',' <<<"$claimed")," ]]; then
              ctl_line+="  claimed={${claimed}} MATCH"
            else
              ctl_line+="  claimed={${claimed}} MISMATCH"
              flags+="CONTROL-CLAIM-MISMATCH"$'\n'
            fi
          fi
        fi
      else
        ctl_line="control NOT RUN — could not create the control checkout"
      fi
    fi
  fi
  lines+="${ctl_line}"$'\n'

  # ── mutants: one clean tree each, applied, landing asserted, check re-run ────
  local -a specs=(); mapfile -t specs < <(_task_grade_mutant_specs "$repo" "$sha" "$ident" "$stored")
  if (( ${#specs[@]} == 0 )); then
    if (( ctl_healthy )); then
      # Recorded, NOT flagged. Re-booking a grader session for every row that
      # names no mutant is the burn this whole line of work exists to remove,
      # and the control above already showed the check goes red without the fix.
      lines+="mutant  NONE RECORDED — no mutant on this row; the control above is what shows '${check}' can fail (--mutant=, or tests/mutants/${ident}.sh)"$'\n'
    else
      lines+="mutant  NONE RECORDED — and the control did not run or stayed green, so NOTHING here proves '${check}' can fail (--mutant=, or tests/mutants/${ident}.sh)"$'\n'
      flags+="NO-EVIDENCE-CAN-FAIL"$'\n'
    fi
  fi
  local spec mid mcmd i=0
  for spec in "${specs[@]:-}"; do
    [[ -n "$spec" ]] || continue
    mid=${spec%%$'\t'*}; mcmd=${spec#*$'\t'}; i=$((i+1))
    local wtM="$scratch/mut$i" rcM=0 rcMc=0 outM="" outMc="" cM
    if ! _task_grade_worktree "$repo" "$sha" "$wtM"; then
      lines+="mutant  ${mid}  NOT RUN — could not create its checkout"$'\n'
      flags+="MUTANT-NOT-RUN:${mid}"$'\n'; continue
    fi
    _gt_wts+=("$wtM")
    if outM=$( (cd "$wtM" && "${tmo[@]}" bash -c "$mcmd") 2>&1 ); then rcM=0; else rcM=$?; fi
    if (( rcM != 0 )); then
      lines+="mutant  ${mid}  BROKEN CONTROL — the mutant command itself exited ${rcM}, so no mutated tree was produced and the check was never given a chance to fail"$'\n'
      lines+="        ${mcmd}"$'\n'"        $(printf '%s\n' "$outM" | tail -n 5 | tr '\n' ' ')"$'\n'
      flags+="MUTANT-BROKEN:${mid}"$'\n'; continue
    fi
    # THE MUTATION MUST HAVE LANDED. A sed that matched nothing leaves a tree
    # identical to head; the check then goes green for the honest reason and the
    # arm reads as SURVIVED-looking-fine. Absence of a diff is the failure.
    if ( cd "$wtM" && git diff --quiet HEAD >/dev/null 2>&1 ) \
       && [[ -z "$( cd "$wtM" && git status --porcelain 2>/dev/null )" ]]; then
      lines+="mutant  ${mid}  DID NOT APPLY — the tree is unchanged, so this arm graded the delivered tree again"$'\n'
      flags+="MUTANT-NOT-APPLIED:${mid}"$'\n'; continue
    fi
    if outMc=$( (cd "$wtM" && "${tmo[@]}" bash -c "$check") 2>&1 ); then rcMc=0; else rcMc=$?; fi
    if (( rcMc == 0 )); then
      lines+="mutant  ${mid}  SURVIVED — the check still passes on the mutated tree (${mcmd})"$'\n'
      flags+="MUTANT-SURVIVED:${mid}"$'\n'
    else
      cM=$(_task_grade_arm_counts "$outMc")
      local killer; killer=$(awk '{print $3}' <<<"$cM")
      lines+="mutant  ${mid}  killed-by ${killer:-<exit ${rcMc}>}"$'\n'
    fi
  done

  # ── rails: what ran alongside, recorded so the table is the whole receipt ────
  local rails="rails   changed-harness suite green at head"
  [[ -n "$base" ]] && rails+=" · base ${base:0:12}"
  lines+="${rails}"$'\n'

  _gt_cleanup
  _TASK_GRADE_FLAGS="$flags"
  local nflags=0; [[ -n "$flags" ]] && nflags=$(grep -c . <<<"$flags")
  local verdict
  if (( nflags == 0 )); then
    verdict="VERDICT computed: PASS — 0 flags"
  else
    verdict="VERDICT computed: FLAGGED — ${nflags} flag(s): $(tr '\n' ' ' <<<"$flags")
        A GRADER READS THIS TABLE AND RE-DERIVES THE FLAGGED LINE ONLY. The
        unflagged lines were computed from clean checkouts at the delivered sha
        and are not re-run: re-deriving them is the ~78-call burn DIVE-4825
        removed. Judge intent and honesty from the diff, then accept or reject."
  fi
  _TASK_GRADE_TABLE="GRADE ${ident} @ ${sha:0:12}${base:+ (base ${base:0:12})}"$'\n'"${lines}${verdict}"
  if [[ -n "$flags" ]]; then
    # A SURVIVED mutant and a mutant that NEVER APPLIED have the same
    # consequence: nothing here showed the check can go red, and an exit status
    # that cannot go red grades every tree green. Both are DIVE-4623's vacuity
    # and both are refused at delivery rather than handed to a reader — reading
    # does not repair a control that was never run.
    grep -qE '^MUTANT-(SURVIVED|NOT-APPLIED)' <<<"$flags" && { _TASK_GRADE_RC=4; return 4; }
    _TASK_GRADE_RC=1; return 1
  fi
  _TASK_GRADE_RC=0; return 0
}

# `_task_grade_claimed_failing <result>` — the failing-arm set the maker CLAIMED,
# read out of the DIVE-4576 template's CHECKED line (`failing={A2,A4b}`). Absent
# is absent: the control line then prints its own set and claims no match, which
# is honest, where inventing a claim to match would not be.
_task_grade_claimed_failing() {  # <result>
  printf '%s\n' "${1:-}" | sed -n 's/.*failing[[:space:]]*=[[:space:]]*{\([^}]*\)}.*/\1/p' \
    | head -n1 | tr -d ' '
}

# `_task_grade_flagged_route <id> <ident> <table> [flagged|sample]` — writes the
# table onto the ROW and lets the delivery fall through to the ordinary grader
# route. Nothing new is spawned here: the seat that wakes reads its goal off the
# row, so putting the table in the body IS putting it in the goal, and the one
# rule that makes the hand-off cheap rides with it.
_task_grade_flagged_route() {  # <id> <ident> <table> [kind]
  local id="$1" ident="$2" table="$3" kind="${4:-flagged}" hdr
  if [[ "$kind" == sample ]]; then
    hdr="## COMPUTED GRADE (DIVE-4825) — GREEN TABLE, DRAWN FOR A READ

The mechanical pass below is GREEN and must NOT be re-run — re-deriving a
computed line is the ~78-call burn this row removed. READ ONLY: the diff, this
table, and the maker's result template. You are grading the half a script
cannot: intent, and the honesty of the residual — a harness that is green but
tests the wrong thing, a criterion the result claims and the diff does not
close. Accept, or 'task reject' on intent. No clone, no worktree. Budget: 5 calls."
  else
    hdr="## COMPUTED GRADE (DIVE-4825) — FLAGGED

Re-derive the FLAGGED line ONLY. Every unflagged line was computed from clean
checkouts at the delivered sha and is not in question; re-running it is the burn
this row removed. Budget: 10 calls."
  fi
  db "UPDATE tasks SET body=COALESCE(body,'')||$(sqlq "$(printf '\n\n%s\n\n```\n%s\n```\n' "$hdr" "$table")") WHERE id=${id};"
  declare -F _five_flush_write_notes >/dev/null 2>&1 && _five_flush_write_notes
  warn "$ident: computed grade table written to the row (DIVE-4825) — routing to a grader for the ${kind} read; the mechanical arms are not re-run."
  return 0
}

# `_task_grade_sample_hit <id> <ident>` — rc 0 when a GREEN table still earns a
# model's read.
#
# WHY A GREEN TABLE IS EVER READ. The computed pass loses nothing on the
# mechanical half, but it cannot see intent: a harness that is green and tests
# the wrong thing passes it perfectly. lodar made that a design constraint on
# this row ("will it degrade our code quality?"), so a share of green tables
# still reaches a reader — and the share is a KNOB, not a constant, so it can be
# moved without a code change.
#   FIVEDIVE_GRADE_SAMPLE_N=5   1 in N green tables (0 disables the sample)
# plus EVERY green table whose diff touches the blast radius, which is the same
# path set DIVE-4634 already refuses to grade cheaply.
_task_grade_sample_hit() {  # <id> <ident>
  local id="$1" ident="$2" n p
  if declare -F _task_path_is_rubric_blast >/dev/null 2>&1; then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      if _task_path_is_rubric_blast "$p"; then
        warn "$ident: green computed table, but the diff touches ${p} — inside the blast radius, so it still gets a read (DIVE-4825)."
        return 0
      fi
    done < <({ _task_rubric_local_paths "$id" 2>/dev/null; _task_delivery_paths "$id" 2>/dev/null; } | sort -u)
  fi
  n="${FIVEDIVE_GRADE_SAMPLE_N:-}"
  if [[ -z "$n" && -r "${BOX_CONFIG:-/nonexistent}" ]]; then
    n=$(jq -r '.grade_sample_n // empty' "$BOX_CONFIG" 2>/dev/null || printf '')
  fi
  [[ "$n" =~ ^[0-9]+$ ]] || n=5
  (( n == 0 )) && return 1
  local h; h=$(printf '%s' "$ident" | cksum | awk '{print $1}')
  (( h % n == 0 )) || return 1
  warn "$ident: green computed table drawn by the 1-in-${n} read sample (DIVE-4825) — a READ, not a re-run."
  return 0
}

# `_task_grade_derive_check <id> <ident> <result>` — THE DEFAULT FLIP.
#
# `--review=check` has existed since DIVE-4324 and almost nothing uses it,
# because it has to be chosen at FILING by someone who does not yet know which
# harness the work will grow. The maker knows — they write it on the CHECKED
# line of the DIVE-4576 result template at delivery. So the command is DERIVED
# from that line, and a PR delivery that names exactly one runnable harness is
# graded by the computed pass instead of booking a session.
#
# IT ONLY EVER TAKES A `temp`/unset ROW. A named grader (`--review=<seat>`) is
# someone asking for that seat's judgement and is never downgraded; `rubric` has
# its own escalation rail. Exactly one harness must be named — two is ambiguous
# and a derivation that guesses is worse than no derivation.
#
# The failure mode is bounded in the safe direction: a derived check that goes
# red, flags, or cannot be computed routes to the grader the row would have got
# anyway. Off with FIVEDIVE_DERIVE_GRADE_CHECK=0.
_task_grade_derive_check() {  # <id> <ident> <result>
  local id="$1" ident="$2" result="$3" mode forced n cand
  [[ "${FIVEDIVE_DERIVE_GRADE_CHECK:-1}" == "1" ]] || return 1
  [[ -n "$result" ]] || return 1
  mode=$(db "SELECT COALESCE(review_mode,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
  case "$(review_mode_kind "$mode" 2>/dev/null || printf invalid)" in
    check|seat|rubric) return 1 ;;
  esac
  forced=$(db "SELECT COALESCE(verify_forced,0) FROM tasks WHERE id=${id};" 2>/dev/null || printf 0)
  [[ "$forced" == "1" ]] && return 1
  [[ -n "$(db "SELECT COALESCE(verify_command,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')" ]] && return 1
  # Only the CHECKED line, and only a path that exists at the delivered sha.
  local -a paths=()
  mapfile -t paths < <(printf '%s\n' "$result" | _task_grade_claim_block \
    | sed -n '/^CHECKED[[:space:]]*[:(=-]/,/^[A-Z][A-Z0-9_-]*[[:space:]]*[:(=-]/p' \
    | grep -oE '(tests|test)/[A-Za-z0-9_./-]+\.sh' | sort -u)
  n=${#paths[@]}
  (( n == 1 )) || return 1
  cand="${paths[0]}"
  git rev-parse HEAD >/dev/null 2>&1 || return 1
  git cat-file -e "HEAD:${cand}" 2>/dev/null || return 1
  db "UPDATE tasks SET verify_command=$(sqlq "bash ${cand}"), review_mode='check' WHERE id=${id};"
  warn "$ident: graded by the COMPUTED PASS (DIVE-4825) — the check was derived from your CHECKED line ('bash ${cand}') and no grader session is booked unless the table flags. File --review=<seat> if a seat's judgement, not a computed table, is what this row needs."
  return 0
}

# DIVE-4825 REMOVED `_task_check_control_arms` / `_TASK_CONTROL_RECEIPT`. Its
# two arms (as-delivered, mutated) are the first and the mutant lines of the
# computed table above, which also runs the source-revert control and EVERY
# mutant. A second executor kept "for the simple case" would be a second answer
# to what a passing command means, and the first fix to one of them would drift
# the other — the same reason the grade itself delegates to `cmd_task_verify`.

# ── DIVE-4576 deliverable 3 — A COMMAND-GRADED ROW NEVER BOOKS A SESSION ────
#
# `--review=check` has meant "a COMMAND grades it, no grader session" since
# DIVE-4324 — but only at FILING time, where it chose the mode and then nothing
# ran it. The delivery still emitted a spawn request, a clone still woke, cold-
# loaded the pull request, and ran the command the row had been carrying all
# along. The mode named the cheap path and the rail took the expensive one.
#
# So the delivery honours it: run the row's command HERE, record its exit status
# as the grade through the one verb that already knows how to record a grade
# (`task verify --no-done`, which stamps graded_at, preserves the maker's result
# rather than overwriting it, and renders the row as graded->merge), and return
# without attaching a grader or routing. No clone is created, so the grade costs
# a command instead of a session.
#
# WHY IT DELEGATES TO cmd_task_verify INSTEAD OF RUNNING bash ITSELF. A second
# executor would be a second answer to "what does a passing command mean": the
# timeout handling, the 25-line output tail, the DIVE-2483 result preservation,
# the DIVE-3330 merge-binding hold and the ledger receipt all live there, and a
# copy of them here would drift the first time one of them was fixed.
#
# A FAILING COMMAND BOUNCES WITHOUT A SESSION TOO, and that is the half worth
# having: today a red delivery costs a whole grader session to discover the red.
# The FAIL verdict is recorded on the row and the row stays with the maker — no
# handoff clock is started, so no reject is needed to undo one.
#
# rc: 0 = graded here (caller must not route) · 1 = not command-graded.
_task_deliver_command_grade() {  # <id> <ident> <cmd-given-at-delivery> <result> <want_result> [mutant-given-at-delivery]
  local id="$1" ident="$2" given="${3:-}" result="${4:-}" want_result="${5:-0}" given_mutant="${6:-}"
  local mode stored
  mode=$(db "SELECT COALESCE(review_mode,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
  stored=$(db "SELECT COALESCE(verify_command,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
  # DIVE-4623: a control named at delivery is persisted for the same reason the
  # command is — a grade whose negative control lives only in one process's argv
  # is not reproducible, and reproducibility is the whole reason a command may
  # stand in for a grader.
  if [[ -n "$given_mutant" ]]; then
    db "UPDATE tasks SET mutant_command=$(sqlq "$given_mutant") WHERE id=${id};"
  fi
  if [[ -n "$given" ]]; then
    # A command supplied at delivery is PERSISTED, so a later re-grade, a
    # `task loops` replay and `task show` all read the same command — a grade
    # whose command lives only in one process's argv is not reproducible, and
    # reproducibility is the entire reason a command may stand in for a grader.
    db "UPDATE tasks SET verify_command=$(sqlq "$given") WHERE id=${id};"
    stored="$given"
    case "$(review_mode_kind "$mode" 2>/dev/null || printf invalid)" in
      check) : ;;
      rubric)
        # An explicit command is evidence the fixed rubric cannot adjudicate by
        # itself. Keep it for the full grader and escalate; never silently turn a
        # deliberately independent model grade into the maker's own command.
        db "UPDATE tasks SET review_mode='temp' WHERE id=${id};"
        warn "$ident: --review=rubric escalated to a full grade because delivery supplied --verify=<cmd> (DIVE-4634)."
        return 1 ;;
      seat)
        # The row PINNED a NAMED grader at filing. A command given at delivery
        # does not overrule that choice — it is stored as evidence for the seat
        # that was chosen. Silently downgrading a named grade to a command is
        # the "a mode is not the authority on spend" confusion verify_policy.sh
        # warns about, one direction over: somebody asked for that seat's
        # judgement, and an exit status is not it.
        warn "$ident: --verify=<cmd> stored, but this row pins ${mode} as its grader — the command is recorded for that seat to run, not run in its place. File with --review=check to be graded by a command (DIVE-4576)."
        return 1 ;;
      temp)
        # `_task_deliver_rubric_escalate` may already have promoted rubric to
        # temp because the row is explicit/blast-radius. In that case the
        # command is evidence for the grader, not a reason to downgrade again.
        [[ "${_TASK_RUBRIC_ESCALATED:-0}" == "1" ]] && return 1
        # `temp` is the anonymous ephemeral clone, and it is also what a row gets
        # when the filer chose NOTHING (DIVE-4324's default) — the two are
        # indistinguishable in the column, so this cannot be read as a pin. A
        # maker naming the command that grades their own diff at delivery is the
        # cheaper of the two and is honoured, loudly: the clone it replaces is
        # the entire cost this row exists to remove. A filer who wants a session
        # regardless says so with a named grader (--review=<seat>), which the arm
        # above refuses to downgrade.
        db "UPDATE tasks SET review_mode='check' WHERE id=${id};"
        warn "$ident: filed --review=temp (a grader session) and delivered with --verify=<cmd> — graded by the command instead, and NO grader session is booked (DIVE-4576). Pin a session grader with --review=<seat> if a seat's judgement, not an exit status, is what this row needs."
        mode=check ;;
      *)
        db "UPDATE tasks SET review_mode='check' WHERE id=${id};"
        mode=check ;;
    esac
  fi
  # ── DIVE-4825: THE DEFAULT FLIP ───────────────────────────────────────────
  # A PR delivery whose result template names exactly one harness is graded by
  # the computed pass. Filing-time `--review=check` stays the explicit form; this
  # is the path that makes it the DEFAULT without asking the filer to predict,
  # months earlier, which harness the work would grow.
  if [[ "$mode" != "check" ]] && _task_grade_derive_check "$id" "$ident" "$result"; then
    mode=check
    stored=$(db "SELECT COALESCE(verify_command,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
  fi
  [[ "$mode" == "check" ]] || return 1
  if [[ -z "$stored" ]]; then
    warn "$ident: filed --review=check (graded by a command) but the row carries NO command, so there is nothing to grade with. Add one at delivery: 'task deliver $ident --pr=… --verify=\"<cmd>\"' (DIVE-4576)."
    return 1
  fi
  # ── DIVE-4623: THE NEGATIVE CONTROL, RUN BEFORE THE GRADE IS BELIEVED ─────
  # Read from the row rather than from argv so a row filed with `--mutant=` is
  # controlled whether or not this delivery re-passed it.
  local control ctl_rc=0 ctl_note="" ctl_escape="" _gt_computed=0
  control=$(db "SELECT COALESCE(mutant_command,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
  if [[ -z "$control" ]]; then
    # A row filed before this rail existed, or one that reached `check` through
    # the delivery-time downgrade above. Deliberately NOT a refusal: that would
    # re-book a grader session for every legacy command-graded row, which is the
    # burn this whole line of work exists to remove. It is recorded instead, so
    # "graded by an uncontrolled command" is countable on the board rather than
    # silently equal to a proven one.
    ctl_note="control: NONE RECORDED — this row names no mutant, so nothing here proves '$stored' can fail. File the control with --mutant=\"<cmd>\" (or record why it cannot be inverted with --no-mutant=\"<reason>\") (DIVE-4623)."
    warn "$ident: graded by a command with NO negative control. $ctl_note"
  elif ctl_escape=$(mutant_escape_reason "$control"); then
    ctl_note="control: WAIVED at filing (audited, DIVE-4623) — ${ctl_escape}. The check ran once, as delivered; nothing demonstrated it can fail."
  else
    # DIVE-4825: THE COMPUTED PASS, a strict superset of the two arms it
    # replaces — the suite at the sha, the source-revert control, EVERY mutant,
    # the rails, and one table. Its return codes are deliberately the same three
    # this path already handles, so the refusals below did not have to move.
    _gt_computed=1
    _task_grade_table "$ident" "$stored" "$control" "$(_task_grade_claimed_failing "$result")" || ctl_rc=$?
    ctl_note="$_TASK_GRADE_TABLE"
    # A mutant the check could not kill IS DIVE-4623's vacuous grade, and it is
    # refused there rather than flagged to a reader: an exit status that cannot
    # go red grades every tree green, and no amount of reading fixes that.
    (( ctl_rc == 4 )) && ctl_rc=1
  fi
  # A FLAGGED TABLE IS A HAND-OFF, NOT A REFUSAL. The computed lines stand; the
  # flagged one needs a judgement, so the table goes on the row (which is where
  # the grader's goal is built from) and the delivery falls through to the
  # ordinary route. A GREEN table is closed here for zero grader tokens unless
  # the read-sample or the blast radius draws it — the quality half of DIVE-4825.
  if (( _gt_computed )) && (( ctl_rc == 1 )) && [[ -n "$_TASK_GRADE_FLAGS" ]] \
     && ! grep -qE '^MUTANT-(SURVIVED|NOT-APPLIED)' <<<"$_TASK_GRADE_FLAGS"; then
    _task_grade_flagged_route "$id" "$ident" "$ctl_note" flagged
    return 1
  fi
  if (( _gt_computed )) && (( ctl_rc == 0 )) && _task_grade_sample_hit "$id" "$ident"; then
    _task_grade_flagged_route "$id" "$ident" "$ctl_note" sample
    return 1
  fi

  # A VACUOUS CHECK IS REFUSED, and the refusal is the finding. Written to the
  # row first: a delivery that is bounced for having no evidence must leave the
  # reason where the next reader looks, not only in the caller's scrollback.
  if (( ctl_rc == 1 || ctl_rc == 3 )); then
    local _cv_txt
    if (( ctl_rc == 1 )); then
      _cv_txt="❌ delivery REFUSED — the check that grades this row is VACUOUS (DIVE-4623): it was never shown to go red — either it passed on a tree the mutant had already broken, or the mutant never applied and left the tree untouched. Its exit status therefore says nothing about this diff; the table below names which arm."$'\n'"${ctl_note}"
    else
      _cv_txt="❌ delivery REFUSED — the check FAILED from a clean checkout at the delivered sha (DIVE-4623): it may be passing in the maker's tree for a reason that was not pushed."$'\n'"${ctl_note}"
    fi
    if declare -F _task_guard_result_over_closed >/dev/null 2>&1; then
      _task_guard_result_over_closed "$id" "$ident" deliver "$_cv_txt" 0 0 check-control-arm
      _cv_txt="$_TASK_GUARDED_RESULT"
    fi
    db "UPDATE tasks SET result=$(sqlq "$_cv_txt") WHERE id=${id};"
    _five_flush_write_notes
    if (( ctl_rc == 1 )); then
      policy_refuse "$E_CONFLICT" deliver-check-vacuous DIVE-4623 "$ident" \
        "$ident: the command grading this row was never shown able to fail — it passed on the mutated tree, or the mutant never changed the tree at all — so it is not evidence about anything — a check that cannot fail grades every tree green. NOT handed off: no grader session was spawned and no handoff clock is running, so there is no reject to undo. Both arms are recorded on the row ('5dive task show $ident'). Exits: make the check actually assert the behaviour, or name a mutant that really breaks it ('task deliver $ident --pr=… --mutant=\"<cmd>\"'), or buy a grader session for this row with '5dive task verifier $ident <seat>'."
    else
      policy_refuse "$E_CONFLICT" deliver-check-red-at-sha DIVE-4623 "$ident" \
        "$ident: the command grading this row FAILED in a clean checkout at the delivered sha, although it may pass where you ran it. That is the delivered tree missing something your worktree has — an untracked fixture, a stale build output, an exported variable. NOT handed off: no grader session was spawned. The arms are on the row ('5dive task show $ident'). Push what is missing and deliver again."
    fi
  fi

  # The maker's result is written BEFORE the grade runs, and only on this path —
  # every other arm of `task deliver` still writes it at its own point, because a
  # refusal further down (the byte-identical re-delivery guard) states that
  # nothing was written and an early write here would make that false. On THIS
  # path there is no later refusal that says so, and the order matters: the grade
  # receipt is appended to the maker's text by DIVE-2483's preservation rail, so
  # a result written after the grade would sit under its own evidence.
  if (( want_result )); then
    db "UPDATE tasks SET result=$(sqlq_or_null "$result") WHERE id=${id};"
    _five_flush_write_notes
  fi
  local out rc=0
  # The receipt rides in as the grade's prose, so BOTH ARMS ARE RECORDED ON THE
  # ROW in the one cell the board and the merge owner already read — rather than
  # in a second column nothing renders.
  out=$(cmd_task_verify "$ident" --no-done --cmd="$stored" --result="$ctl_note" 2>&1) || rc=$?
  printf '%s\n' "$out" >&2
  if (( rc == 0 )); then
    local _ok_ctl="with a PROVEN negative control (the check goes red on the mutated tree, DIVE-4623)"
    (( ctl_rc == 2 )) && _ok_ctl="control NOT RUN — see the row"
    [[ -z "$control" ]] && _ok_ctl="with NO negative control on the row"
    [[ -n "$ctl_escape" ]] && _ok_ctl="control waived at filing (audited)"
    ok "$ident delivered — GRADED BY COMMAND at delivery, no grader session spawned (review=check, DIVE-4576), ${_ok_ctl}: '$stored' exited 0. The grade is recorded on the row; the merge owner closes it through 'task done' once the binding is merged." \
       '{id:($i|tonumber), ident:$id, delivered:true, gradedBy:"command", command:$c, verdict:"pass", graderSession:false, routedTo:null}' \
       --arg i "$id" --arg id "$ident" --arg c "$stored"
    return 0
  fi
  policy_refuse "$E_CONFLICT" deliver-command-grade-failed DIVE-4576 "$ident" \
    "$ident: the command that grades this row FAILED at delivery (exit ${rc}) — '$stored'. The delivery ref is recorded and the FAIL verdict is on the row, but it was NOT handed off: no grader session was spawned to discover a red that a command had already found, and no handoff clock is running, so there is no reject to undo. The output tail is in the row's result ('5dive task show $ident'). Fix it and deliver again."
}

# DIVE-4634: rubric is the cheap lane, never the unsafe lane. Any explicit
# verification request or any path excluded from the small-delivery classifier
# promotes it to the ordinary full grade before routing.
_TASK_RUBRIC_ESCALATED=0
_task_rubric_local_paths() {  # <id>
  local id="$1" repo sha base
  repo=$(db "SELECT COALESCE(delivery_repo_path,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
  sha=$(db "SELECT COALESCE(delivered_sha,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
  [[ -d "$repo" && "$sha" =~ ^[0-9a-f]{40}$ ]] || return 0
  base=$(git --git-dir="$repo" merge-base "$sha" origin/main 2>/dev/null || printf '')
  [[ -n "$base" ]] || return 0
  git --git-dir="$repo" diff --name-only "$base" "$sha" -- 2>/dev/null || true
}

_task_path_is_rubric_blast() {  # <path>
  _task_path_small_denied "$1" && return 0
  case "${1:-}" in src/task/*) return 0 ;; esac
  return 1
}

_task_deliver_rubric_escalate() {  # <id> <ident> [delivery verify command]
  local id="$1" ident="$2" given="${3:-}" mode forced stored p reason=""
  _TASK_RUBRIC_ESCALATED=0
  mode=$(db "SELECT COALESCE(review_mode,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
  [[ "$mode" == "rubric" ]] || return 1
  forced=$(db "SELECT COALESCE(verify_forced,0) FROM tasks WHERE id=${id};" 2>/dev/null || printf 0)
  stored=$(db "SELECT COALESCE(verify_command,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
  if [[ "$forced" == "1" || -n "$stored" || -n "$given" ]]; then
    reason="explicit --verify"
  else
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      if _task_path_is_rubric_blast "$p"; then reason="blast-radius path: $p"; break; fi
    done < <({ _task_rubric_local_paths "$id"; _task_delivery_paths "$id"; } | sort -u)
  fi
  [[ -n "$reason" ]] || return 1
  db "UPDATE tasks SET review_mode='temp' WHERE id=${id};"
  _TASK_RUBRIC_ESCALATED=1
  warn "$ident: --review=rubric escalated to a full grade (${reason}, DIVE-4634)."
  return 0
}

# Extract only DIVE-4576's labelled claim block. A maker may write arbitrary
# prose after it; that prose is deliberately not grader context.
_task_grade_claim_block() {  # [stdin]
  awk '
    function allowed(s) { return s ~ /^(CHANGED|FILES|CHECKED|HOW|EVIDENCE|RAN|DELIVERED[-_]?SHA|DELIVERYSHA|CI|CI-STATE|CHECKS|CRITERIA|ACCEPTANCE|CRITERION)[[:space:]]*[:(=-]/ }
    /^[A-Z][A-Z0-9_-]*[[:space:]]*[:(=-]/ { on = allowed($0) }
    on { print }
  ' | head -c "${FIVEDIVE_GRADE_CLAIM_MAX_BYTES:-65536}" || true
}

_task_grade_tree_digest() {  # <tree>
  local tree="$1" p
  (
    cd "$tree" || exit 1
    while IFS= read -r -d '' p; do
      if [[ -L "$p" ]]; then printf 'link  %s  %s\n' "$(readlink "$p")" "$p"
      else sha256sum -- "$p"; fi
    done < <(git ls-files -z)
  ) | sha256sum | awk '{print $1}'
}

_task_grade_tree_assert() {  # <id> <ident> <tree> [quiet]
  local id="$1" ident="$2" tree="$3" quiet="${4:-0}" want got dirty base seal now
  want=$(db "SELECT COALESCE(delivered_sha,'') FROM tasks WHERE id=${id};")
  [[ "$want" =~ ^[0-9a-f]{40}$ ]] || fail "$E_CONFLICT" "$ident has no recorded delivered sha; re-deliver from the source checkout (DIVE-4634)"
  [[ -d "$tree" ]] || fail "$E_NOT_FOUND" "$ident grading tree does not exist: $tree"
  got=$(git -C "$tree" rev-parse HEAD 2>/dev/null || printf '')
  [[ "$got" == "$want" ]] || fail "$E_CONFLICT" "$ident grading tree HEAD is ${got:-unreadable}, expected delivered sha $want — REJECT (DIVE-4634)"
  dirty=$(git -C "$tree" status --porcelain --untracked-files=all 2>/dev/null || printf 'unreadable')
  [[ -z "$dirty" ]] || fail "$E_CONFLICT" "$ident grading tree is dirty — REJECT (DIVE-4634): ${dirty:0:300}"
  base="${tree%/*}"; seal="${base}/.${ident}-${want}.seal"
  [[ -r "$seal" ]] || fail "$E_CONFLICT" "$ident grading tree has no content seal — REJECT (DIVE-4634)"
  now=$(_task_grade_tree_digest "$tree")
  [[ "$now" == "$(cat "$seal")" ]] || fail "$E_CONFLICT" "$ident grading tree content changed after materialization — REJECT (DIVE-4634)"
  (( quiet )) || printf 'GRADE-TREE-OK: %s (HEAD=%s, clean, seal=%s)\n' "$tree" "$want" "$now"
}

# ── DIVE-4803 — THE GRADING TREE IS THE GRADER'S, SO ITS BOOKKEEPING MUST BE TOO ──
#
# `git worktree add` writes the tree's admin record into the SOURCE repository
# (`<git-dir>/worktrees/<name>`), so the grading tree only looked private: its
# state lived in the maker's checkout. Makers normally deliver from their own
# home and graders normally run as a different unix user, so on any
# maker != verifier pair the packet could not be built at all — measured
# 2026-09-21 grading DIVE-4802 (maker main, verifier quinn):
#
#   fatal: could not create leading directories of
#     '/home/agent-main/wt/cli-hotfix-ingress/.git/worktrees/DIVE-4802-33cb7c71c40f': Permission denied
#
# and the grader fell back to cloning the repo by hand — which is precisely the
# full re-derivation the bounded packet exists to avoid. It read as rare only
# because a row delivered from a SHARED checkout (group-writable) still worked,
# so the lane that failed was the one nobody graded.
#
# THE MATERIALIZATION IS READ-ONLY ON THE MAKER'S REPO: an empty repository in
# the grader's own state dir, its object store BORROWED through `objects/info/
# alternates`, then a detached checkout of the delivered sha. Nothing is written
# outside `$root`, so the only permission required is the one a grader already
# has — read.
#
# IT IS NOT A WEAKER TREE THAN THE WORKTREE IT REPLACES. A `git worktree` shares
# the source object store too, so the coupling to the maker's repo is unchanged;
# what changes is who owns the bookkeeping. The tree is still detached at the
# delivered sha, still sealed by `_task_grade_tree_digest`, and still asserted by
# `_task_grade_tree_assert` before any verdict.
#
# ONE PATH, ALWAYS TAKEN — not a fallback behind a writability probe. A lane that
# only some deliveries reach is exactly what hid this: the grade-time cost of the
# two shapes is the same, and a second shape would owe a second arm forever. It
# also stops leaving a `git worktree` registration behind in a repo whose owner
# never asked for one; nothing prunes those, and this host never does.
#
# `core.hooksPath=/dev/null` because `git checkout` runs `post-checkout`: the new
# repo has no hooks of its own, but an ambient `init.templateDir` could install
# some, and a grade must not execute code it did not read.
_task_grade_materialize_tree() {  # <repo-git-dir> <sha> <tree>
  local repo="$1" sha="$2" tree="$3" alt
  git init -q "$tree" >/dev/null 2>&1 || return 1
  alt="${tree}/.git/objects/info/alternates"
  mkdir -p "${alt%/*}" 2>/dev/null || return 1
  printf '%s\n' "${repo}/objects" >"$alt" 2>/dev/null || return 1
  git -C "$tree" -c core.hooksPath=/dev/null checkout -q --detach "$sha" >/dev/null 2>&1 || return 1
  return 0
}

# `task grade-context` is the grader's only entry point. It intentionally never
# selects tasks.body, routing history, or a maker transcript.
cmd_task_grade_context() {
  tasks_db_init
  local task="" check=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check=*) check="${1#*=}" ;;
      -h|--help) printf 'usage: 5dive task grade-context <id|DIVE-N> [--check=<grading-tree>]\n'; return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *) [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "usage: 5dive task grade-context <id|DIVE-N> [--check=<grading-tree>]" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task grade-context <id|DIVE-N> [--check=<grading-tree>]"
  resolve_task_id "$task"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  if [[ -n "$check" ]]; then _task_grade_tree_assert "$id" "$ident" "$check"; return 0; fi

  local repo sha criteria result root tree tree_q seal digest base diff claim mode criteria_b
  repo=$(db "SELECT COALESCE(delivery_repo_path,'') FROM tasks WHERE id=${id};")
  sha=$(db "SELECT COALESCE(delivered_sha,'') FROM tasks WHERE id=${id};")
  criteria=$(db "SELECT COALESCE(acceptance_criteria,'') FROM tasks WHERE id=${id};")
  result=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${id};")
  mode=$(db "SELECT COALESCE(review_mode,'temp') FROM tasks WHERE id=${id};")
  [[ -d "$repo" && "$sha" =~ ^[0-9a-f]{40}$ ]] \
    || fail "$E_CONFLICT" "$ident has no usable delivered checkout+sha; re-deliver from the source checkout (DIVE-4634)"
  git --git-dir="$repo" cat-file -e "${sha}^{commit}" 2>/dev/null \
    || fail "$E_CONFLICT" "$ident delivered sha $sha is absent from $repo — REJECT (DIVE-4634)"

  root="${XDG_STATE_HOME:-${HOME}/.local/state}/5dive/grades"
  mkdir -p "$root" || fail "$E_GENERIC" "cannot create private grader state at $root"
  chmod 700 "$root" 2>/dev/null || true
  tree="${root}/${ident}-${sha:0:12}"
  tree_q=$(printf '%q' "$tree")
  seal="${root}/.${ident}-${sha}.seal"
  if [[ ! -d "$tree" ]]; then
    # A half-built tree is removed rather than left for the next invocation to
    # find: the `-d "$tree"` test above is the only reuse gate, so a directory
    # that exists but never got its checkout would be graded as if it had.
    _task_grade_materialize_tree "$repo" "$sha" "$tree" \
      || { rm -rf "$tree"; fail "$E_GENERIC" "$ident could not create detached grading tree at $sha from $repo (DIVE-4803)"; }
    chmod -R go-w "$tree" 2>/dev/null || true
    digest=$(_task_grade_tree_digest "$tree") || fail "$E_GENERIC" "$ident could not seal grading worktree"
    printf '%s' "$digest" >"$seal"; chmod 600 "$seal" 2>/dev/null || true
  fi
  _task_grade_tree_assert "$id" "$ident" "$tree" 1
  base=$(git --git-dir="$repo" merge-base "$sha" origin/main 2>/dev/null || git --git-dir="$repo" rev-parse "${sha}^" 2>/dev/null || printf '')
  [[ -n "$base" ]] || fail "$E_CONFLICT" "$ident cannot resolve a diff base for $sha — REJECT (DIVE-4634)"
  diff=$(git -C "$tree" diff --no-ext-diff --unified=3 "$base" "$sha" -- | head -c "${FIVEDIVE_GRADE_DIFF_MAX_BYTES:-131072}" || true)
  claim=$(printf '%s\n' "$result" | _task_grade_claim_block)
  # DIVE-4825: THE COMPUTED TABLE RIDES IN THE PACKET. The goal tells the grader
  # to use ONLY this packet, so a table that lives anywhere else does not reach
  # the seat that was woken because of it — and the whole point of waking that
  # seat is the one line the computation could not settle.
  local ctable=""; ctable=$(_task_grade_table_from_body "$id" 2>/dev/null || printf '')
  # DIVE-4634 iteration 3: the truncation is hoisted OUT of the heredoc rather than
  # spelled inline. `<<PACKET` is deliberately unquoted — it has to interpolate
  # ${ident} ${mode} ${tree} ${sha} ${base} ${claim} ${diff} — and an unquoted heredoc
  # also EXECUTES any $(...) in its body, which is the class
  # tests/heredoc_substitution_unit.sh bans outside its allowlist. Quoting the
  # delimiter is NOT the fix here: it would turn every one of those expansions into
  # literal text and emit a packet naming no task, no tree and no sha.
  criteria_b=$(printf '%s' "$criteria" | head -c 16384)
  cat <<PACKET
BEGIN BOUNDED GRADING PACKET DIVE-4634
TASK: ${ident}
MODE: ${mode}
GRADE_TREE: ${tree}
DELIVERED_SHA: ${sha}
BASE_SHA: ${base}

ACCEPTANCE CRITERIA (bounded at 16384 bytes):
${criteria_b}

DELIVERY CLAIM BLOCK (the CHECKED lines are the commands and reported outputs to re-run):
${claim}
${ctable:+
COMPUTED GRADE TABLE (DIVE-4825 — produced from clean checkouts at DELIVERED_SHA; do NOT re-run the unflagged lines):
${ctable}}

GIT DIFF AT DELIVERED SHA (bounded at ${FIVEDIVE_GRADE_DIFF_MAX_BYTES:-131072} bytes):
${diff}
END BOUNDED GRADING PACKET DIVE-4634

Before recording a verdict, run:
  5dive task grade-context ${ident} --check=${tree_q}
PACKET
}

# ── DIVE-4576 — A DELIVERY THAT CARRIES NO EVIDENCE IS REFUSED ──────────────
#
# AXIS: tokens per closed row. The grader is an EPHEMERAL CLONE that cold-loads
# this row and the pull request from nothing (DIVE-4164/4496), so every claim it
# cannot CHECK it has to RE-DERIVE — it re-runs the maker's investigation to find
# out whether the maker's investigation was right. Measured on dev 2026-09-15:
# 97% of every grader turn is cache re-read, and a reject pays for the whole
# thing twice, on both seats.
#
# The fix is not a longer result. It is a result whose claims are ADDRESSED TO A
# RE-RUN: the five labelled fields in `_delivery_evidence_template` are exactly
# the inputs a grade needs (which files to spot-check, which commands to re-run,
# at which sha, what CI already said, and which criterion each answers). With
# them the grade is a comparison; without them it is a second investigation.
#
# SCOPE — ONLY A DELIVERY THAT BINDS A PULL REQUEST. Knowledge, ops and
# coordination rows close through `task done` with no binding and are untouched:
# there is no diff to name files in and no sha to grade at, and a rail that
# demanded one would teach makers to type "CHANGED: n/a" five times, which is
# the shape of every control that stopped meaning anything. `verify=delivered-
# only` (DIVE-4251) draws the same line for the same reason — bound means code
# that ships.
#
# NOTHING IS WRITTEN WHEN IT REFUSES, which is why every caller invokes it
# BEFORE its own UPDATE. It is the same contract as DIVE-4113/4144's byte-
# identical re-delivery refusal, and deliberately the same shape: the row is
# untouched, the refusal names the missing field, and there is one audited exit.
#
# THE AUDITED EXIT IS NOT A STYLE ESCAPE. `--force-unevidenced="<why>"` exists
# because a real delivery can genuinely have no sha (a revert of a revert, a
# binding re-pointed with no new work) and a rail with no exit is a rail people
# route around by pasting the labels with nothing under them. It WARNS, loudly,
# and the reason is recorded on the delivery — a grader reading it knows it is
# about to pay for a full re-derivation and can price the grade accordingly.
# DIVE-4733: a delivery with no source checkout under it binds a row that no
# grading packet can ever be built for. Refuses BEFORE the binding UPDATE; see
# the call site for why this is a refusal and not the warning it replaces.
#
# THE AUDITED EXIT IS NOT A STYLE ESCAPE, same posture as --force-unevidenced
# below: `--force-no-checkout="<why>"` exists for the delivery that genuinely has
# no tree to stand in (a row delivering a pull request in a repo that is not
# cloned on this box), and the reason is echoed for the grader to read, because
# the grader is the one who then pays for the full row read.
_task_guard_delivery_checkout() {  # <ident> <delivered-sha>
  local ident="$1" sha="${2:-}"
  [[ -z "$sha" ]] || return 0
  if [[ -n "${_TASK_NO_CHECKOUT_WAIVER:-}" ]]; then
    warn "$ident: delivered from OUTSIDE a git checkout (--force-no-checkout, DIVE-4733) — '${_TASK_NO_CHECKOUT_WAIVER}'. No delivered sha is recorded, so '5dive task grade-context' cannot build this row's packet and the grader falls back to reading the whole row."
    return 0
  fi
  policy_refuse "$E_VALIDATION" deliver-outside-checkout DIVE-4733 "$ident" \
    "$ident: this delivery was invoked from outside a git checkout ($PWD), so there is no delivered sha to record (DIVE-4733). NOTHING WAS WRITTEN — the row is unchanged, unbound, and still yours. WHY THIS IS REFUSED RATHER THAN WARNED: the binding would succeed and look finished, while '5dive task grade-context $ident' would silently be unable to materialize the tree and the grader would fall back to reading the entire row — the cost DIVE-4723 exists to remove, paid without anyone noticing it was avoidable (DIVE-4634). THE FIX IS A cd: run the same command again from the checkout the work was done in, the one whose HEAD is the sha you pushed. If this delivery genuinely has no tree to stand in (the pull request is in a repo that is not cloned on this box), say so and it proceeds, audited and recorded for the grader: --force-no-checkout=\"<why>\"."
}

_task_guard_delivery_evidence() {  # <id> <ident> <verb> <result-text> <want_result> [<binding-being-bound>]
  local id="$1" ident="$2" verb="$3" text="$4" want="${5:-0}" binding="${6:-}"
  # A delivery is only graded against a diff when one is bound. The binding is
  # read from the ROW, because `task done`'s routing fork reaches here on a row
  # whose ref was stamped by an EARLIER `task deliver` — and passed IN by
  # `task deliver` itself, because the whole point of running before the UPDATE
  # is that the ref is not on the row yet. Without that argument the guard would
  # be silent on exactly the first delivery of every row, which is the one the
  # grader pays most for.
  local _ev_ref="$binding"
  [[ -n "$_ev_ref" ]] || _ev_ref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
  [[ -n "$_ev_ref" ]] || return 0
  # THE RAIL GRADES THE CLAIM AT THE MOMENT THE CLAIM IS WRITTEN. When the maker
  # typed a result, that text is the claim and it is what is checked. When they
  # typed none, this verb is a BINDING operation — re-pointing the ref at a new
  # pull request is the legitimate act DIVE-2682 exists to keep cheap, and the
  # claim standing on the row was already checked when it was written. So a bare
  # delivery over an existing result passes.
  #
  # A bare delivery over an EMPTY result hands the grader a pull request and
  # NOTHING ELSE. It WARNS rather than refusing, and the reasoning is worth
  # recording because the other two answers were both defensible:
  #
  #   refuse it — it is the worst case, strictly worse than an unevidenced
  #     sentence. Rejected because a bare `task deliver --pr=` is also the
  #     legitimate RE-POINT of a binding (DIVE-2682) and the "bind now, write the
  #     result at close" shape that four existing harnesses and an unknown number
  #     of live rows use; refusing it turns one row's rail into a migration.
  #   say nothing — rejected: it is exactly the bypass a maker who resents the
  #     rail would find first.
  #
  # So it warns HERE and is FAILED THERE: deliverable 2 tells the grader that a
  # claim with no evidence is a FAIL, and "no claim at all" is that case at its
  # limit. The teeth are in the grade, which is where they cost the maker a round
  # rather than costing the fleet a migration.
  #
  # FORWARD-ONLY on the other branch, the posture DIVE-4144's hash took: a result
  # written before this rail existed was never checked by it, and a bare re-point
  # of such a row proceeds rather than refusing rows nobody can fix.
  local _ev_text="$text"
  if (( ! want )); then
    _ev_text=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
    if [[ -z "${_ev_text//[[:space:]]/}" ]]; then
      warn "$ident: delivered with NO result at all (DIVE-4576) — the grader gets a pull request and nothing to check, so it will re-derive your work to grade it, and a claim it cannot check is a FAIL ('FINDING: unevidenced'). Write the delivery's evidence before it is graded: '5dive task show $ident' prints the template while the row is in progress."
    fi
    return 0
  fi
  local _ev_missing; _ev_missing=$(_delivery_evidence_missing "$_ev_text") && return 0
  if [[ -n "${_TASK_EVIDENCE_WAIVER:-}" ]]; then
    warn "$ident: delivered WITHOUT $(printf '%s' "$_ev_missing" | tr ' ' ',') (--force-unevidenced, DIVE-4576) — '${_TASK_EVIDENCE_WAIVER}'. The grader cannot re-run what this result does not name, so this grade is a full re-derivation of your investigation and is priced accordingly."
    return 0
  fi
  policy_refuse "$E_VALIDATION" deliver-result-without-evidence DIVE-4576 "$ident" \
    "$ident: this ${verb} names a pull request but its result does not state: ${_ev_missing}. NOTHING WAS WRITTEN — the row is unchanged and still yours. WHY THIS IS REFUSED RATHER THAN WARNED: the grader is a fresh clone with no memory of your session, so a claim it cannot re-run it has to re-derive, which costs a second full investigation of a diff you have already investigated — and a reject pays it twice. Fill these in (the same template '5dive task show $ident' prints while the row is in progress):"$'\n'"$(_delivery_evidence_template)"$'\n'"Then re-run your ${verb}. If this delivery genuinely has no such evidence to give (a revert, a re-pointed binding with no new work), say so and it proceeds, audited and recorded for the grader to read: --force-unevidenced=\"<why>\"."
}

cmd_task_deliver() {
  tasks_db_init
  local task="" pr="" result="" want_result=0 result_src=""
  local deliver_cmd=""                   # DIVE-4576: --verify=<cmd> given at delivery
  local deliver_mutant=""   # DIVE-4623: the negative control, named at delivery
  # DIVE-4733: LOCAL, unlike _TASK_EVIDENCE_WAIVER beside it. Bash's dynamic
  # scoping still hands it to the guard below, and a waiver held in a bare global
  # outlives the command that set it — a second delivery in the same shell would
  # inherit it and be waived in silence. Not reachable from the CLI, where each
  # invocation is its own process; this is scope hygiene, and the harness's W3
  # arm is written to be able to SEE it (two calls, one subshell) rather than
  # passing vacuously the way a per-call subshell makes it.
  local _TASK_NO_CHECKOUT_WAIVER=""
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
                       result="${1#*=}"; want_result=1; result_src="--result"
                       _TASK_RAW_RESULT="$result" ;;   # DIVE-4144: see _task_route_to_verifier
      --result-file=*) _prose_flag_dupe --result-file "$result_src"
                       _read_prose_file --result-file "${1#*=}"
                       result="$_PROSE_FILE_VALUE"; want_result=1; result_src="--result-file"
                       _TASK_RAW_RESULT="$result" ;;
      --append-result) append_result=1 ;;
      --force-result)  force_result=1 ;;
      # DIVE-4144: the declared exit from the identical-redeliver refusal in
      # _task_route_to_verifier. Threaded as a global rather than a 7th positional
      # because that helper has three call sites across two files and a positional
      # nobody passes is how a guard silently stops applying.
      --force-redeliver=*) _TASK_REDELIVER_FORCE_REASON="${1#*=}" ;;
      --force-redeliver)   fail "$E_USAGE" "--force-redeliver needs a reason: --force-redeliver=\"<why the unchanged re-delivery is correct>\" (DIVE-4144)" ;;
      # DIVE-4576: the audited exit from the evidence refusal. A bare flag is a
      # usage error for DIVE-4144's reason — a waiver with no reason recorded is
      # a waiver nobody can price, and the grader is the party that pays.
      --force-unevidenced=*) _TASK_EVIDENCE_WAIVER="${1#*=}" ;;
      --force-unevidenced)   fail "$E_USAGE" "--force-unevidenced needs a reason: --force-unevidenced=\"<why this delivery has no such evidence to give>\" (DIVE-4576)" ;;
      # DIVE-4733: the audited exit from the no-checkout refusal. Same shape as
      # the flag above and for the same reason — a bare flag with no reason is a
      # usage error, because the reason is the whole point of the exit.
      --force-no-checkout=*) _TASK_NO_CHECKOUT_WAIVER="${1#*=}" ;;
      --force-no-checkout)   fail "$E_USAGE" "--force-no-checkout needs a reason: --force-no-checkout=\"<why this delivery has no source checkout to stand in>\" (DIVE-4733)" ;;
      # DIVE-4576 deliverable 3: a maker may ADD the grading command AT DELIVERY.
      # `task add --verify=<cmd>` already picks `--review=check` at filing, but a
      # row is frequently only gradeable by a command once the work exists — and
      # the alternative to accepting it here is a grader session spent running
      # the command the maker could have named.
      --verify=*)          deliver_cmd="${1#*=}" ;;
      # DIVE-4623: and the NEGATIVE CONTROL for it, same argument one step on — a
      # row is frequently only invertible once the diff exists, and the mutant is
      # usually written FROM that diff ('git apply -R' of the fix hunk).
      --mutant=*)          deliver_mutant="${1#*=}" ;;
      --no-mutant=*)       deliver_mutant="none: ${1#*=}" ;;
      -*)              fail "$E_USAGE" "unknown flag: $1" ;;
      *)               [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task deliver <id|DIVE-N> --pr=<url> [--result=<text>|--result-file=<path>] [--append-result|--force-result] [--verify=<cmd>] [--force-unevidenced=<why>] [--force-no-checkout=<why>]"
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
  # DIVE-4576: the evidence rail, BEFORE the delivery stamp, so a refused
  # delivery is wholly non-mutating exactly like DIVE-2476's guard above. The PR
  # is passed in because it is not on the row yet — see the guard's header.
  _task_guard_delivery_evidence "$id" "$ident" delivery "$result" "$want_result" "$pr"
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
  local _delivery_repo="" _delivered_sha=""
  _delivery_repo=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || printf '')
  _delivered_sha=$(git rev-parse HEAD 2>/dev/null || printf '')
  [[ "$_delivered_sha" =~ ^[0-9a-f]{40}$ ]] || { _delivery_repo=""; _delivered_sha=""; }
  # DIVE-4733: and if there is no checkout here, REFUSE — before the UPDATE on the
  # next line, so a refused delivery is wholly non-mutating exactly like DIVE-2317's
  # and DIVE-4576's guards above it.
  #
  # WHY THIS STOPPED BEING A WARNING. DIVE-4634 bound these two columns so the
  # grader could be handed a bounded packet instead of a full row read; DIVE-4723
  # then pointed the standing verifier at that packet. A delivery stamped from
  # outside a checkout leaves delivered_sha NULL, `task grade-context` cannot
  # materialize the tree, and the grader silently falls back to the full row read.
  # The warning described that outcome to the one person who could no longer act
  # on it — the delivery had already succeeded and the row was already bound, so
  # the maker's next act was `task done`, not a re-delivery. Measured at grading
  # on 2026-09-21 (DIVE-4733): of six real rows sampled, DIVE-4719 was row-read
  # for exactly this reason and nothing downstream noticed. Every such delivery is
  # a DIVE-4723 saving that does not happen.
  #
  # THE REMEDY IS A `cd`, which is why refusing is proportionate: the maker has
  # the checkout, they just were not standing in it.
  _task_guard_delivery_checkout "$ident" "$_delivered_sha"
  db "UPDATE tasks SET delivery_ref=$(sqlq "$pr"), delivered_at=datetime('now'), delivery_ref_iteration=COALESCE(iteration,0),
                       delivery_repo_path=$(sqlq_or_null "$_delivery_repo"), delivered_sha=$(sqlq_or_null "$_delivered_sha")
        WHERE id=${id};"
  # A DELIVERY IS A TASK STATE CHANGE, so it leaves an audit row like every other
  # one. `task start|done|cancel|set-body|merge|answer gate` all call this helper;
  # `deliver` did not, and the only trace of a delivery was the row's own mutable
  # columns. Measured on one box over the 24h to 2026-09-19: eight deliveries, and
  # the same window carried 8 `task start` and 14 `task done` rows — so a reader
  # asking "when was this bound, and to what" had a gap no other verb has.
  #
  # HERE, immediately after the binding UPDATE, because this is the one point
  # every deliver arm crosses: the command-graded arm returns before the routing
  # arm is reached, and the routing arm returns before the tail.
  #
  # The two fields are read in ONE query into locals rather than as command
  # substitutions in the argument list. `src/task/status.sh` measured that exact
  # shape: an argument-position `$(...)` is expanded BEFORE the callee runs, so
  # every non-production-store call paid a fork for a row the DIVE-2010 fence then
  # withheld.
  #
  # `iteration=` is the value STAMPED HERE. The routing arm below re-stamps it to
  # iteration+1 inside the same command (see _task_route_to_verifier's trailing
  # 1), so on that arm the row's final column reads one higher than this record —
  # which is correct: this row says what the binding was stamped at, not what the
  # counter ended the command at.
  local _dl_audit _dl_iter _dl_review
  _dl_audit=$(db "SELECT COALESCE(delivery_ref_iteration,0)||' '||COALESCE(review_mode,'-') FROM tasks WHERE id=${id};")
  _dl_iter="${_dl_audit%% *}"; _dl_review="${_dl_audit#* }"
  _task_store_audit_log "task deliver" ok 0 -- "$ident" "ref=$pr" "iteration=$_dl_iter" "review=$_dl_review"
  # DIVE-3496 (iteration 2): the ref is now bound — assert the gate's credential
  # can SEE it, here, rather than leaving the verifier to discover it at close.
  # Runs AFTER the write on purpose: the delivery is not conditional on it.
  _task_deliver_reach_probe "$ident" "$pr"
  _task_deliver_rubric_escalate "$id" "$ident" "$deliver_cmd" || true
  # DIVE-4576 deliverable 3: a command-graded row is graded HERE and never
  # reaches the grader attach below — placed after the ref is bound so the grade
  # is recorded against the binding it is a grade OF (DIVE-3330 reads it), and
  # before the attach so no spawn request is ever emitted for a row whose grade
  # has already happened.
  if _task_deliver_command_grade "$id" "$ident" "$deliver_cmd" "$result" "$want_result" "$deliver_mutant"; then
    return 0
  fi
  local _vfier _asignee
  _vfier=$(db "SELECT COALESCE(verifier,'')  FROM tasks WHERE id=${id};")
  _asignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")
  # DIVE-4251: `verify=delivered-only` — THIS is the moment the box said a grader
  # is warranted. The row was filed without one because at `task add` there was no
  # delivery to judge; binding a PR is what makes it "code that ships". Attaching
  # here, after delivery_ref is written, is what makes `bound=1` true for the
  # resolver — the ordering is load-bearing, not incidental.
  #
  # Only when the row has NO verifier: an explicitly wired grader is never
  # replaced, and a row the customer opted out of (`--no-verify`) is not
  # re-attached behind their back — `_task_verify_grants` answers both.
  if [[ -z "$_vfier" ]] && _task_verify_grants "$id"; then
    local _dl_grader; _dl_grader=$(_task_default_verifier "$_asignee" "")
    if [[ -n "$_dl_grader" ]]; then
      local _dl_title; _dl_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
      db "UPDATE tasks
             SET verifier=$(sqlq "$_dl_grader"),
                 acceptance_criteria=COALESCE(acceptance_criteria, $(sqlq "Deliverable meets the intent of: ${_dl_title}. Maker records in the done result WHAT was built and HOW it was checked; ${_dl_grader} confirms against this before the task closes."))
           WHERE id=${id};"
      _vfier="$_dl_grader"
      warn "$ident: grader attached at delivery (verify=$(box_verify_policy), DIVE-4251) — this row ships code, so a grader session will grade it. '5dive config verify=never' or 'task add --no-verify' opts out."
    fi
  fi
  # DIVE-4251: the box may grant no grader at all (verify=never, or a row's
  # --no-verify). Then the delivery is RECORDED and the handoff degrades to the
  # non-routing arm below, which leaves the row in_progress for its own close —
  # rather than routing it to a grader the customer is not paying for.
  if [[ -n "$_vfier" && "$_vfier" != "$_asignee" ]] && ! _task_verify_grants "$id"; then
    warn "$ident: delivery recorded, grading handoff DECLINED (verify=$(box_verify_policy), DIVE-4251) — the grader named on the row is '$_vfier', but this box's verification policy grants this row no grader session, so it is not routed and no grader is spawned. It stays with '$_asignee' to close. Change the box with '5dive config verify=always', or file the row with --verify."
    (( want_result )) && db "UPDATE tasks SET result=$(sqlq_or_null "$result") WHERE id=${id};"
    _five_flush_write_notes
    ok "$ident delivered ($pr) — recorded; not routed for grading (verify=$(box_verify_policy))" \
       '{id:($i|tonumber), ident:$id, deliveryRef:$p, delivered:true, routedTo:null, gradingDeclined:true, verifyPolicy:$vp, status:"in_progress"}' \
       --arg i "$id" --arg id "$ident" --arg p "$pr" --arg vp "$(box_verify_policy)"
    return 0
  fi
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
  _five_flush_write_notes
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
  # The three-state answer, from the shared helper the DIVE-2318 refusal also
  # prints — see `_gate_gh_bot_state`. "available" now means the credential is
  # there, not merely that this seat may reach for it.
  bot="$(_gate_gh_bot_state)"
  _gate_anon_ok   && anon="usable"   || anon="unusable (no curl/jq, or FIVE_GATE_NO_ANON=1)"
  # DIVE-4341: the instrument's blind spot was that a RESOLVED token and a gh that
  # cannot start look identical here — this very line printed `[4 sudo -u claude gh
  # auth token] RESOLVED` four rows under `this seat CANNOT query GitHub` on a
  # customer box, and the reason (an unreadable shared GH_CONFIG_DIR) appeared
  # nowhere. Empty on a seat where nothing was substituted, so the ordinary output
  # does not grow a sentence about something that did not happen.
  local cfgnote; cfgnote="$(gh_config_note)"

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
    ok "merge-gate selftest: $detail — $seat; token arms: ${trace:-none run}; machine-account rail: $bot; anonymous rail: $anon${cfgnote:+; $cfgnote}" \
       '{verdict:$v, seat:$s, controlPr:$p, state:$st, tokenResolved:($tk=="1"), tokenTrace:$tr, botRail:$b, anonRail:$a, ghConfig:$c}' \
       --arg v "$verdict" --arg s "$seat" --arg p "$pr" --arg st "$state" \
       --arg tk "$([[ -n "$tok" ]] && printf 1 || printf 0)" --arg tr "$trace" --arg b "$bot" --arg a "$anon" --arg c "$cfgnote"
    return 0
  fi
  # A failing self-test is a FINDING, not a crash: it is the only surface on which an
  # inert gate announces itself, so it prints the same fields and exits non-zero.
  #
  # DIVE-4282: AND IT MUST SAY SO TO THE EXIT-TRAP BACKSTOP. Without `mark_reported`,
  # lib/output.sh's `_report_silent_exit` sees a non-zero exit with nothing marked and
  # overprints this verb's own verdict with "5dive task exited 1 without reporting a
  # reason. This is a bug in the CLI ... Please file it: 5dive bug." Reported from a
  # customer box 2026-09-11 as a `set -euo pipefail` crash; it is not one — the verb
  # ran to completion, printed its finding, and returned its verdict. The damage is
  # that the merge-gate warning tells an operator to run THIS command, and the command
  # answers with a bug report instead of the diagnosis it just printed. Same fix, same
  # reason, as cmd_task_merge_unverified's findings exit two functions below.
  mark_reported
  if (( JSON_MODE )); then
    ok "merge-gate selftest: $detail" \
       '{verdict:$v, seat:$s, controlPr:$p, state:$st, tokenResolved:($tk=="1"), tokenTrace:$tr, botRail:$b, anonRail:$a, ghConfig:$c}' \
       --arg v "$verdict" --arg s "$seat" --arg p "$pr" --arg st "$state" \
       --arg tk "$([[ -n "$tok" ]] && printf 1 || printf 0)" --arg tr "$trace" --arg b "$bot" --arg a "$anon" --arg c "$cfgnote"
    return "$rc"
  fi
  warn "merge-gate selftest FAILED on $seat: $detail"
  warn "  token arms: ${trace:-none run}"
  warn "  machine-account rail: $bot · anonymous rail: $anon"
  [[ -n "$cfgnote" ]] && warn "  gh config: $cfgnote"
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
      if grep -qxF -e "$qref" -e "|${qref#*|}" <<<"$tdeliv"; then
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

  # THE LOG IS NOT SLURPABLE AND THAT IS NOT A BUG TO FIX HERE. `agent-audit.log` is
  # world-APPENDABLE by every seat on the box, so concurrent appends interleave and it
  # carries occasional truncated lines: measured 2026-08-17, `jq -s` over the live
  # 10 MB log exits 5 and yields NOTHING — one malformed line 9 MB back would take the
  # whole sweep with it, and under `set -euo pipefail` it took the whole CLI run.
  # So: grep the ~200 candidate lines out first (cheap, and it bounds the blast radius
  # of a bad line to itself), parse them ONE AT A TIME, and COUNT what did not parse.
  # A skipped line is a stamp this sweep did not consider and it is disclosed below —
  # silently dropping it would be the same "empty is not an answer" defect one layer on.
  local cand cand_n=0
  cand=$(grep -F '"task.merge-gate-unverified"' "$logf" 2>/dev/null || true)
  [[ -n "$cand" ]] && cand_n=$(printf '%s\n' "$cand" | grep -c . || true)

  # ident<TAB>ts<TAB>reason<TAB>seat. The --since cutoff and the newest-wins dedupe are
  # done in awk, not jq, so `parsed` below counts PARSE failures only and is not
  # confounded by rows the filter legitimately dropped.
  local jqout parsed_n=0
  # `jq -R` + `fromjson?` is the whole point and NOT a style choice: without -R a single
  # streaming jq parses the concatenated stream, so ONE truncated line ABORTS the parser
  # and every stamp AFTER it is silently dropped — the sweep then prints "0 still carry an
  # OPEN PR" and exits 0 while an open PR sits right there. With -R each line is read as a
  # raw string and `fromjson?` turns a bad line into `empty`, containing it to itself.
  jqout=$(printf '%s\n' "$cand" | jq -R -r '
      fromjson? // empty
      | select(.cmd == "task.merge-gate-unverified")
      | [ (.args[0] // ""),
          (.ts // ""),
          ([ .args[] | select(startswith("reason=")) ] | first // "reason=unrecorded"),
          (.user // "") ] | @tsv
    ' 2>/dev/null || true)
  [[ -n "$jqout" ]] && parsed_n=$(printf '%s\n' "$jqout" | grep -c . || true)
  local unparsed=$(( cand_n - parsed_n )); (( unparsed < 0 )) && unparsed=0

  local stamps
  stamps=$(printf '%s\n' "$jqout" \
    | awk -F'\t' -v cut="$cutoff" '$1 ~ /^DIVE-[0-9]+$/ && (cut == "" || $2 >= cut) { r[$1]=$0 }
                                   END { for (k in r) print r[k] }' \
    | sort -t$'\t' -k2,2r | head -n "$limit" || true)

  local total_stamps=0
  [[ -n "$stamps" ]] && total_stamps=$(printf '%s\n' "$stamps" | grep -c . || true)

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
    (( unparsed > 0 )) && warn "$unparsed stamp line(s) in $logf did not parse and were NOT swept — the log is world-appendable and interleaves; those closes are unexamined, not clean."
  fi
  ok "merge-unverified: $total_stamps stamped close(s) re-derived across $repos_ok/$repos_total repos — $findings still carry an OPEN PR ($clean clean, $unconf unconfirmed, $reopened reopened, $missing row-missing${unparsed:+; $unparsed unparseable log line(s) skipped})" \
     '{stamps:($n|tonumber), repos:($rp|split(",")), reposScanned:($ro|tonumber), reposTotal:($rt|tonumber), fullCoverage:($fc=="1"), unscanned:($us|split(", ")|map(select(.!=""))), pageCapped:($cp|split(", ")|map(select(.!=""))), findings:($f|tonumber), clean:($c|tonumber), unconfirmed:($u|tonumber), reopened:($re|tonumber), rowMissing:($m|tonumber), unparsedLogLines:($ul|tonumber), rows:($r|fromjson)}' \
     --arg n "$total_stamps" --arg rp "$slugs" --arg ro "$repos_ok" --arg rt "$repos_total" --arg fc "$full_coverage" \
     --arg us "$unscanned" --arg cp "$capped" --arg f "$findings" --arg c "$clean" --arg u "$unconf" \
     --arg re "$reopened" --arg m "$missing" --arg ul "$unparsed" --arg r "$payload"
  # Exit status is the consumable signal — a stamp with no consumer is what this verb
  # exists to fix, so `merge-unverified && echo ok` must mean something to cron.
  # `mark_reported` first: a findings exit is a REPORTED verdict (the rows are right
  # there above it), and without the flag the EXIT-trap backstop renders this verb's
  # own headline result as "exited 1 without reporting a reason — this is a bug in the
  # CLI", which tells a reader to file a bug instead of triaging the rows.
  if (( findings > 0 )); then mark_reported; return 1; fi
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
  # DIVE-4144 (arm 3): THE BARE RE-DELIVER. DIVE-4113 iteration 2 re-delivered
  # byte-identical text after a reject and the rail recorded it as a fresh pass;
  # the verifier discovered it by reading the diff. It is graded HERE because this
  # helper is the ONE funnel every delivery passes through (`task done`'s two
  # routing forks and `task deliver`), and it must run BEFORE the UPDATE below —
  # that UPDATE SPENDS the reject token (handoff_rejected_at=NULL), after which
  # "was there an unanswered reject" is no longer answerable from the row.
  #
  # THE OPERAND IS THE MAKER'S RAW SUPPLIED TEXT, and the first cut got this
  # wrong in a way worth recording. It compared `$result` — which by the time it
  # reaches here is the MERGED column, because DIVE-2483's guard preserves the
  # prior text and appends the new one under a seam. Two consequences, both fatal
  # to the check: the merged blob GROWS on every delivery, so two identical
  # deliveries never hash alike; and the reject's own output_hash is the hash of a
  # blob from a different generation. Measured on arm E, which passed the bare
  # re-deliver straight through.
  #
  # So: hash what the maker TYPED (`_TASK_RAW_RESULT`, captured at flag-parse
  # time before any guard rewrites it) and compare it to what the maker typed on
  # the previous delivery, which this helper records as `raw_result_hash=` in the
  # task.delivered ledger detail below. lifecycle_events is append-only and
  # nothing on the re-delivery path touches it (DIVE-2777's reason for choosing
  # it), so a new durable column would be a second answer to a question the store
  # already holds. FORWARD-ONLY: a delivery made before this change carries no
  # raw hash, so the first pass after the upgrade cannot be compared and is
  # silent — the same posture DIVE-2777 took, and preferable to guessing.
  #
  # BOUNDED, and say so rather than overclaim: this catches an identical RESULT
  # TEXT, which is the shape measured on DIVE-4113 and the only artifact the store
  # holds. A maker who edits the prose and pushes no code is NOT caught here — the
  # graded-sha gate (DIVE-2656) and delivery_ref_iteration (DIVE-2682) are the arms
  # that see the code. It is a warning-with-teeth on one shape, not a proof of
  # rework. Skipped when no result is being written at all: a `task done` with no
  # --result is a re-assertion, and DIVE-2624 already labels it "re-delivery of the
  # same pass, not rework" in the receipt below.
  local _rd_ident; _rd_ident=$(ident_of "$id")
  # DIVE-4576: the evidence rail on the OTHER delivery verb. This helper is the
  # one funnel every delivery passes through, so `task done`'s two routing forks
  # meet the same refusal `task deliver` met above; a row with no binding is not
  # in scope and returns immediately. Ordered with the byte-identical guard and
  # BEFORE the UPDATE for the same reason: both refusals promise an untouched row.
  _task_guard_delivery_evidence "$id" "$_rd_ident" "hand-off" "${_TASK_RAW_RESULT-${result:-}}" "$want_result"
  local _rd_rejected _rd_prev_hash _rd_new_hash
  _rd_rejected=$(db "SELECT COALESCE(handoff_rejected_at,'') FROM tasks WHERE id=${id};")
  if (( want_result )) && [[ -n "$_rd_rejected" ]] && declare -F ledger_hash >/dev/null 2>&1; then
    _rd_prev_hash=$(db "SELECT COALESCE(detail,'') FROM lifecycle_events
                          WHERE ident=$(sqlq "$_rd_ident") AND kind='task.delivered'
                            AND detail LIKE '%raw_result_hash=%'
                          ORDER BY id DESC LIMIT 1;" 2>/dev/null || printf '')
    _rd_prev_hash="${_rd_prev_hash##*raw_result_hash=}"; _rd_prev_hash="${_rd_prev_hash%% *}"
    _rd_new_hash=$(ledger_hash "${_TASK_RAW_RESULT-${result:-}}")
    if [[ -n "$_rd_prev_hash" && "$_rd_new_hash" == "$_rd_prev_hash" ]]; then
      if [[ -n "${_TASK_REDELIVER_FORCE_REASON:-}" ]]; then
        warn "$_rd_ident: re-delivered BYTE-IDENTICAL text after a reject (--force-redeliver, DIVE-4144) — '${_TASK_REDELIVER_FORCE_REASON}'. The verifier will read an unchanged result; the iteration counter still bumps, so the row will look like rework it is not."
      else
        policy_refuse "$E_CONFLICT" deliver-identical-after-reject DIVE-4144 "$_rd_ident" \
          "$_rd_ident: this delivery's result is BYTE-IDENTICAL to the one the verifier just rejected (same sha256 prefix ${_rd_new_hash}, compared against the task.rejected ledger row). Measured on DIVE-4113 iteration 2: a bare re-deliver reads as a fresh pass and costs the verifier a full cold reload of the PR to discover that nothing changed. NOTHING WAS WRITTEN — the row is still assigned to you and the iteration counter has not moved. The reject's FIX block is in the row's result ('5dive task show $_rd_ident'); address it, then deliver with a result that says what you changed. If the work DID change and only the summary is identical, restate it — that is the cheaper fix. If you are re-delivering unchanged work on purpose (the verifier misread it, or a lost handoff is being restored), say so and it proceeds (audited): '--force-redeliver=\"<why>\"'."
      fi
    fi
  fi
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
  # DIVE-3932: and the RUN, for the identical reason — this fork returns before
  # the status funnel's run hook. `handed_to_verifier` is the maker's end
  # boundary and it is a COMPLETED run, not an open one: the attempt reached a
  # durable boundary and the next thing that happens to this row is a different
  # agent's attempt. Ordered next to the segment close so the two receipts for
  # one boundary cannot drift apart.
  _run_event_for_task "$id" task.handoff "{\"verifier\":$(_run_json_str "$vfier")}" || true
  _run_close_for_task "$id" completed handed_to_verifier || true
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
  # DIVE-4144: `raw_result_hash` is the digest of the text the MAKER SUPPLIED, which
  # is not what `out` carries (that is the merged column, prior text included). It is
  # the operand the identical-redeliver guard above reads on the NEXT delivery. In
  # `detail` and not a new column, for DIVE-2518's reason: lifecycle_events is
  # append-only history and an ALTER leaves every pre-existing row with a NULL that
  # reads as "the maker typed nothing" rather than "not recorded yet".
  local _rd_emit_hash=""
  declare -F ledger_hash >/dev/null 2>&1 && (( want_result )) \
    && _rd_emit_hash=$(ledger_hash "${_TASK_RAW_RESULT-${result:-}}")
  ledger_emit task.delivered ident="$ident" task_id="$id" actor="$(task_actor "")" \
    out="${result:-}" detail="delivered to verifier ${vfier} (iteration ${iter}${iter_note}; awaiting ACK)${_rd_emit_hash:+ raw_result_hash=${_rd_emit_hash}}"
  # DIVE-4164: the delivery event asks for an ephemeral grader. Emitted HERE, in
  # the one funnel every delivery passes through, so "never maker-spawned" is
  # structural — see _grader_spawn_request. `|| true`: the row is already durably
  # updated and a bookkeeping write must never fail a recorded delivery.
  declare -F _grader_spawn_request >/dev/null 2>&1 \
    && _grader_spawn_request "$ident" "$id" "$vfier" "$iter" || true

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
# ── DIVE-4144 — A REJECT THAT NAMES NO FIX BUYS AN EXTRA ITERATION ───────────
#
# AXIS: the autonomy number. Every maker<->verifier round is a COLD RELOAD of a
# PR the maker had closed out, so an iteration is not a cheap retry — it is the
# most expensive shape the loop has. Measured on DIVE-4113 (2026-09-09): three
# iterations, of which iteration 2 was a bare re-deliver that changed NOTHING
# (olivia: "ITERATION 2 CHANGED NOTHING vs iteration 1"). What closed it in
# iteration 3 was already sitting in olivia's ITERATION-1 reject, in this shape:
#
#     FIX (either closes it): (a) ... (b) ...
#
# i.e. the information that ended the loop was present two rounds early and was
# not structured where the maker would act on it. So the three arms here are one
# change: make the fix SAYABLE (the template), make it REACH the maker (the wake
# nudge), and make a re-deliver that ignored it VISIBLE (the identical-redeliver
# refusal). Any one alone leaves the round in place.
#
# WHAT COUNTS AS NAMING A FIX, and it is deliberately ONE marker rather than a
# prose classifier: a `FIX` label followed by a separator and at least one
# alphanumeric character. Not a judgement about whether the fix is GOOD — that
# is the maker's read and no regex can hold it — only that the reject carries a
# labelled, greppable one, which is the property the wake nudge below needs in
# order to extract anything at all. The leading non-alphanumeric boundary is
# load-bearing: without it "prefix: ..." satisfies the check.
_REJECT_FIX_MARKER_RE='(^|[^[:alnum:]])[Ff][Ii][Xx][[:space:]]*([(:=-]|—)[^[:alnum:]]*[[:alnum:]]'

# The text every refusal prints. One string, so the refusal, the `--help` line
# and the tests cannot drift into describing three different templates.
_REJECT_TEMPLATE_HINT='FINDING: <what is wrong, and the evidence you read> / FIX: <the concrete testable change that closes it — "(a) ... (b) ..." alternatives are fine> / VERIFY: <what you will re-run to grade the next pass>'

# rc=0 when the feedback names a fix.
_reject_feedback_names_a_fix() {
  [[ "${1:-}" =~ $_REJECT_FIX_MARKER_RE ]]
}

# Print the FIX block of a reject's recorded text — from the LAST `FIX` marker to
# the end — flattened to one line and capped. The LAST occurrence, not the first,
# because `_task_guard_result_over_closed` appends: on a re-reject the row carries
# the superseded text FIRST and the live rejection last, so the first match would
# hand the maker the fix it has already addressed. Capped at 700 chars because the
# consumer is a single-line /goal nudge, not a document.
_reject_fix_block() {
  printf '%s' "${1:-}" | tr '\n\t' '  ' | awk '
    { line=$0; low=tolower(line); p=0; i=1
      while (match(substr(low,i), /fix[ ]*[(:=-]/)) { p = i + RSTART - 1; i = p + 1 }
      if (p>0) { b=substr(line,p); if (length(b)>700) b=substr(b,1,700) "…"; print b } }'
}

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
  # DIVE-3932: the verdict lands on the VERIFIER's own open run, and closes it —
  # producing a verdict is the verifier's end boundary. The maker's run for this
  # iteration was already closed `handed_to_verifier`; it is deliberately NOT
  # reopened or rewritten, because the rejection is a fact about a later attempt
  # by a different agent, and rewriting the maker's terminal record is exactly the
  # silent-overwrite the retry lineage exists to avoid. The maker's next pass gets
  # its own run, linked by parent_run_id.
  _run_event_for_task "$id" verifier.rejected \
    "{\"iteration\":$(_run_json_str "$iter"),\"disposition\":$(_run_json_str "$disposition")}" || true
  _run_close_for_task "$id" completed verifier_rejected || true
}

# ============================================================================
# DIVE-4476 — THE ESCALATION ASK IS WRITTEN BY THE PRODUCT, SO THE PRODUCT
# COMPOSES IT FROM THE ROW.
#
# lodar, 2026-09-14 02:36Z, reading the DIVE-4471 escalation on his phone:
# "confusing phrasing.. do i [open the PR] and submit approve?" and 02:37Z "our
# human gate is still unfriendly and not fixed then?". What he was sent was
# "A piece of work has failed review 2 times and stopped. Decide whether to keep
# going or drop it." — DIVE-4176's rewrite, which fixed the READABILITY (no ident,
# no pasted feedback) and left three things broken that readability does not grade:
#
#   1. it names NO WORK. "A piece of work" is every row on the board. He cannot
#      tell what he is deciding about without opening a link.
#   2. its BUTTON was not either outcome. `--type=manual` renders one "✋ Tap ✅
#      Done" (src/task/notify.sh) while the sentence offers "keep going or drop
#      it" — so the only tap available answers neither half of the question.
#   3. it went to HIM FIRST. `manual` is tier-2 by type, and a two-strike stop is
#      a lead's call (DIVE-4346/4365: the orchestrator clears first).
#
# The fix for all three is the same one: file the DECISION that is actually being
# taken — `--type=decision`, which defaults to tier 1 and therefore ROUTES to the
# filing verifier's lead, with two spelled-out options and the lead's default as
# `--recommend`. The human sees it only when the chart resolves nobody above the
# verifier, and by then it is a readable sentence with two real buttons.
#
# WHY THE COMPOSITION IS DEFENSIVE, AND THIS IS THE LOAD-BEARING PART. Naming the
# row means interpolating the TITLE, and titles on this board are written by
# agents for agents: "DIVE-4462 --options seam", "cli-3754 launcher entry point".
# Every one of those shapes is refused by the readability rule in `task need`,
# `cmd_task_need` exits rather than returns, and the refusal would make `task
# reject` ITSELF FAIL at the iteration cap — the exact failure DIVE-4176 hit and
# recorded (community/wiki/the-readability-rule-is-about-the-reader-not-the-tier.md,
# section 6: "the one bounce that ends a loop stops producing the gate that ends
# it"). A product-written ask must therefore be UNCONDITIONALLY fileable.
#
# So the subject is built by the SAME classifier that would refuse it
# (`_gate_ask_jargon_term`), taking words until the first token a person outside
# our codebase cannot read, and the composed ask is measured against the SAME word
# cap (`_GATE_ASK_MAX_WORDS`) before it is returned. If either the subject or the
# finding clause cannot be made readable, it is DROPPED and the sentence degrades
# to the subject-free form, which is lint-clean by construction. Degrading loses a
# hint; refusing loses the gate.
#
# DIVE-4537 — THE OPTIONS NAME WHAT THE ANSWER DOES, BECAUSE NOW IT DOES IT.
# "the lead takes it over" described who was left holding the row, not an
# outcome, and it was not even true: answering this gate cleared the question and
# left the loop exactly as stopped as it was (iteration == max_iterations, no
# maker, no resume verb — measured on DIVE-4520, where the disposition "keep
# going" sat written on the row for 83 minutes because the three verbs that
# execute it are `task verifier --max-iters`, `need --withdraw` and `task reject`,
# in that order, and the answering lead holds none of them:
# community/wiki/a-withdrawn-iteration-cap-gate-leaves-the-loop-with-no-owner-and-no-resume-verb.md).
# `cmd_task_answer` now performs the resume itself, so each option can say what
# its tap produces. Keep both readable: these two strings ARE the two buttons.
_ESCALATION_OPTIONS='keep going — send it back for another pass|drop it — stop the work, keep the findings'
_ESCALATION_RECOMMEND='keep going — send it back for another pass'

# Print a leading run of <max-words> readable words of <text>, stopping at the
# first token the gate-ask classifier calls an internal name. Stopping rather
# than DELETING is deliberate: a title reads as a phrase, and a hole punched in
# the middle of one ("the seam is unswept") is harder to read than a short one.
_task_escalation_phrase() { # <text> <max-words> -> phrase (possibly empty)
  local _ep_raw="${1:-}" _ep_max="${2:-10}" _ep_out="" _ep_w _ep_n=0
  # A title's tail clause is where the filer puts the mechanism and the
  # attribution — "… — name the work + two outcomes (lodar 2026-09-14)". Cut it
  # before word-counting so the budget is spent on the subject, not the aside.
  _ep_raw="${_ep_raw%%(*}"
  _ep_raw="${_ep_raw%%—*}"
  _ep_raw="${_ep_raw%%$'\n'*}"
  for _ep_w in $_ep_raw; do
    if declare -F _gate_ask_jargon_term >/dev/null 2>&1; then
      _gate_ask_jargon_term "$_ep_w" >/dev/null 2>&1 && break
    fi
    _ep_out="${_ep_out:+${_ep_out} }${_ep_w}"
    _ep_n=$(( _ep_n + 1 ))
    (( _ep_n >= _ep_max )) && break
  done
  # Trailing punctuation left behind by the cut reads as a typo on a phone, and
  # a phrase cut mid-clause ends on a dangling function word ("… writes a machine
  # ask a"). Strip both, repeatedly, because one exposes the other.
  local _ep_last
  while [[ -n "$_ep_out" ]]; do
    if [[ "$_ep_out" == *[,\;:.-] ]]; then _ep_out="${_ep_out%?}"; continue; fi
    _ep_last="${_ep_out##* }"
    case "${_ep_last,,}" in
      a|an|the|and|but|or|of|to|in|on|for|with|that|is|was|its|it|by|as|at|from|not|no)
        [[ "$_ep_out" == *" "* ]] || { _ep_out=""; break; }
        _ep_out="${_ep_out% *}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$_ep_out"
}

# The one clause of the verifier's last finding that a person can read. Taken
# from the FINDING half of the reject template (`_REJECT_TEMPLATE_HINT`) when it
# is present, because the FIX half is addressed to the maker and is machine
# prose by design. Empty whenever it cannot be made readable, which is the
# common case and is fine — the full text is on the row's `result`.
_task_escalation_finding() { # <feedback text> -> clause (possibly empty)
  local _ef_txt="${1:-}" _ef_cl
  _ef_txt=$(printf '%s' "$_ef_txt" | tr '\n\t' '  ')
  # the last FINDING, for the same reason _reject_fix_block takes the last FIX:
  # a re-reject carries the superseded text first.
  case "$_ef_txt" in
    *FINDING:*) _ef_cl="${_ef_txt##*FINDING:}" ;;
    # DIVE-4476 iteration 3: NO fallback. The call site hands this function
    # `fb_txt` AFTER `_task_guard_result_over_closed` merged the MAKER's prior
    # result into it (src/task/status.sh:122), so a "first colon wins" fallback
    # lands inside the maker's own delivered text and shows the maker's
    # self-report to the human AS the verifier's finding — on a gate whose two
    # buttons are keep-going / drop-it, which is to say it argues for the wrong
    # button in the maker's words. Unlabelled feedback is the COMMON case (the
    # refusal upstream requires a FIX label only, and `--no-fix=` is a second
    # legal exit with neither label): 196 of 285 recorded rejects on this board,
    # 69%. No FINDING label therefore means no clause, which is what the
    # docstring above already promises and what the composer degrades cleanly for.
    *) _ef_cl="" ;;
  esac
  # one clause only — the first sentence or separator wins. `FIX:` is a separator
  # too: the template writes "FINDING: … / FIX: …", but that " / " is a convention
  # and is not enforced, so a finding written "FINDING: the relay never lands FIX:
  # do X" would otherwise leak the very label the docstring means to exclude.
  _ef_cl="${_ef_cl%%FIX:*}"
  _ef_cl="${_ef_cl%%.*}"; _ef_cl="${_ef_cl%%;*}"; _ef_cl="${_ef_cl%% / *}"
  _ef_cl="${_ef_cl#"${_ef_cl%%[![:space:]]*}"}"
  _ef_cl=$(_task_escalation_phrase "$_ef_cl" 5)
  # A one- or two-word fragment is noise, not a hint.
  local -a _ef_w=(); read -r -a _ef_w <<<"$_ef_cl"
  (( ${#_ef_w[@]} >= 3 )) || _ef_cl=""
  printf '%s' "$_ef_cl"
}

# The ask itself. Contract: the return value ALWAYS passes the `task need`
# readability rule, whatever is on the row.
_task_escalation_ask() { # <row id> <iterations> [feedback text]
  local _ea_id="${1:-}" _ea_iter="${2:-2}" _ea_fb="${3:-}"
  local _ea_title="" _ea_subj="" _ea_find="" _ea_count _ea_ask _ea_max="${_GATE_ASK_MAX_WORDS:-25}"
  case "$_ea_iter" in
    # `max_iterations=1` is legal (tests/task_reject_trace_unit.sh's own fixture
    # uses it) and rendered "sent back 1 times" to the person deciding.
    1) _ea_count="once" ;;
    2) _ea_count="twice" ;;
    *) _ea_count="${_ea_iter} times" ;;
  esac
  # The subject-free sentence is the FLOOR: 14 words, no internal names, and it
  # is what every degradation below falls back to.
  local _ea_base="The work was sent back ${_ea_count} and has stopped. Keep going, or drop it?"
  [[ "$_ea_id" =~ ^[0-9]+$ ]] || { printf '%s' "$_ea_base"; return 0; }
  _ea_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${_ea_id};" 2>/dev/null) || _ea_title=""
  _ea_subj=$(_task_escalation_phrase "$_ea_title" 9)
  # Under three words the subject names nothing ("Loop two-strike" is not a
  # subject), so it buys a cut title at no readability gain.
  local -a _ea_sw=(); read -r -a _ea_sw <<<"$_ea_subj"
  (( ${#_ea_sw[@]} >= 3 )) || _ea_subj=""
  [[ -z "$_ea_subj" ]] && { printf '%s' "$_ea_base"; return 0; }
  _ea_find=$(_task_escalation_finding "$_ea_fb")
  _ea_ask="${_ea_subj}: sent back ${_ea_count} (${_ea_find}) and stopped. Keep going, or drop it?"
  [[ -n "$_ea_find" ]] || _ea_ask="${_ea_subj}: sent back ${_ea_count} and stopped. Keep going, or drop it?"
  # MEASURE THE COMPOSED STRING, do not trust the arithmetic of the budget. Drop
  # the finding first (it is the hint), then the subject (it is the name), then
  # the floor — each step strictly shorter and strictly more readable.
  if declare -F _gate_ask_word_count >/dev/null 2>&1; then
    if (( $(_gate_ask_word_count "$_ea_ask") > _ea_max )); then
      _ea_ask="${_ea_subj}: sent back ${_ea_count} and stopped. Keep going, or drop it?"
      (( $(_gate_ask_word_count "$_ea_ask") > _ea_max )) && _ea_ask="$_ea_base"
    fi
  fi
  if declare -F _gate_ask_jargon_term >/dev/null 2>&1; then
    _gate_ask_jargon_term "$_ea_ask" >/dev/null 2>&1 && _ea_ask="$_ea_base"
  fi
  printf '%s' "$_ea_ask"
}

cmd_task_reject() {
  tasks_db_init
  local task="" feedback="" no_fix=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --feedback=*) feedback="${1#*=}" ;;
      --reason=*)   feedback="${1#*=}" ;;
      # DIVE-4144: the DECLARED exit from the names-a-fix refusal below. A
      # verifier who has genuinely found a defect it cannot prescribe a fix for
      # must still be able to bounce — a refusal with no exit converts a
      # wrong-but-moving row into a stuck one and the next agent routes around
      # it. It takes a reason rather than being a bare switch for the same
      # reason --no-pr does: the reason is a claim the verifier can be held to,
      # and it is what the maker reads instead of a fix.
      --no-fix=*)   no_fix="${1#*=}" ;;
      --no-fix)     fail "$E_USAGE" "--no-fix needs a reason: --no-fix=\"<why you cannot name the fix>\" (DIVE-4144)" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            [[ -z "$task" ]] && task="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$task" ]] || fail "$E_USAGE" "usage: 5dive task reject <id|DIVE-N> [--feedback=\"FINDING: … FIX: … VERIFY: …\"]"
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
  # DIVE-4144 (arm 1): REFUSE A REJECT THAT NAMES NO FIX. Placed AFTER the
  # DIVE-2112 identity refusals and BEFORE any write, so an unstructured bounce
  # is a pure no-op — the row keeps the maker's delivered result, the loop counter
  # does not move, and the verifier re-runs one command. Placed after the identity
  # checks specifically because "you may not grade your own work" is the stronger
  # thing to say to a maker who reached this verb: telling them to add a FIX block
  # first would send them to write one for a reject they are not allowed to file.
  if ! _reject_feedback_names_a_fix "$feedback"; then
    if [[ -n "$no_fix" ]]; then
      warn "$ident: rejected WITHOUT a fix (--no-fix, DIVE-4144) — '${no_fix}'. The maker reads that instead of a FIX block, so expect it to come back asking; if you can name the change, say it and save the round."
      feedback="${feedback:-no feedback given} [no FIX named — ${no_fix}]"
    else
      policy_refuse "$E_VALIDATION" reject-names-no-fix DIVE-4144 "$ident" \
        "$ident: this reject names no FIX, so it costs the maker a full round to find out what you want. Measured on DIVE-4113: the fix that closed it was already in the iteration-1 reject, and iteration 2 changed nothing because the feedback was not actionable. NOTHING WAS WRITTEN — the row still carries the maker's delivered result and the iteration counter has not moved; re-run this verb with the fix named. TEMPLATE: --feedback=\"${_REJECT_TEMPLATE_HINT}\". A fix is 'named' when the feedback carries a FIX label with something after it; the wording is yours. If you genuinely cannot prescribe one, say why and it proceeds (audited): '5dive task reject $ident --feedback=\"...\" --no-fix=\"<why>\"'."
    fi
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
    _task_gate_card_apply "$ident" die "superseded by auto:reject" || true
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
    _five_flush_write_notes
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
    # DIVE-4176: this ask is written for a person — no ident, no branch, no
    # interpolated verifier feedback (that text is already on the row's `result`,
    # written six lines up, and the row is what the gate points at). The
    # readability refusal in `task need` grades this string like any other, so a
    # regression here would make `reject` itself fail at the iteration cap; the
    # composer above is written to be unconditionally fileable for that reason and
    # tests/escalation_ask_unit.sh grades the string it actually produces.
    #
    # DIVE-4476: `decision`, not `manual`. The type is not cosmetic — it is the
    # ROUTE and it is the BUTTONS. `manual` is tier-2 by type, so it went straight
    # to the paired human and rendered one "Tap ✅ Done" that answered neither half
    # of its own question. `decision` defaults to tier 1, which routes to the
    # filing verifier's lead (a two-strike stop is the orchestrator's call —
    # DIVE-4346/4365) and renders the two options below as the two taps. The human
    # is reached only when the chart resolves nobody above the verifier, which is
    # the fallback, not the destination.
    cmd_task_need "$id" --type=decision --from="${vfier:-verifier}" \
      --options="$_ESCALATION_OPTIONS" --recommend="$_ESCALATION_RECOMMEND" \
      --ask="$(_task_escalation_ask "$id" "$iter" "$fb_txt")"
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

# ── DIVE-4137 — the DISPOSITION of a graded pull request at the verifier's close ─
#
# THE DEFECT, measured by main 2026-09-09 (lodar, Telegram 04:22Z: "10 PRs and 21
# branches on the 5dive-ai/5dive — i think something is wrong with our merging to
# main or we forgetting to merge"). Nine open PRs, none forgotten, all inside the
# pipeline. Four of them — #799, #807, #809 and the frontend #220 — were graded
# PASS and rendered `graded->merge:<maker>`. The merge is routed BACK to the
# MAKER, who wakes cold or is at WIP cap, so the pull request waits; main moved
# all four by hand that night. That hand-move IS the loop, not the fix.
#
# Meanwhile the seat that just proved the head sha is green does NOTHING with that
# evidence. DIVE-3474 already gave it the rail (`task merge`) — this ticket makes
# the rail fire at the close instead of requiring a second, separate act.
#
# WHAT THIS IS NOT, and the boundary is the whole design: it is not a merge grant
# and it does not widen `_merge_do` by one byte. Standing is still re-derived as
# root from the row over `_TASKS_TFV_SQL AND graded_by = <this seat>`. All this
# adds is a DISPOSITION — three questions asked before the rail is called at all,
# each of which can only ever move a row from "merge" to "a human looks".
#
# THE POLARITY IS THE SAFETY ARGUMENT. Every unknown resolves to a HOLD: an
# unreadable head, an unreadable file list, a missing graded-sha, a merge state
# this function has not been taught, a probe that could not run. So the failure
# mode of a bug in here is the behaviour we have TODAY (the row waits), never an
# unreviewed merge. That is why the pure halves below return a hold STRING rather
# than an exit status — an exit status has one bit, and the reason is what the
# board has to render.
#
# WHO OWES THE LOOK. Today a hold always renders `graded->merge:<maker_agent>`,
# which is wrong in the common case: the maker has nothing left to do on a branch
# that is green and clean but merely needs a person's eyes. A hold now names
# `main` — the seat that can look — and names the MAKER only for the one condition
# a maker alone can clear: a conflicted branch needing a rebase.

# Paths whose merge a PERSON has to have looked at. This is NOT a danger list; it
# is the list of paths where our own rules already say a human moment exists —
# CODEOWNERS-covered files, and the schema-bearing paths where a merge to main
# runs `drizzle-kit push --force` against the prod DB and a redeploy does not
# undo it (projects/5dive/CLAUDE.md, "the gate is filed BEFORE THE MERGE").
readonly _MERGE_DISP_LOOK_RX='(^|/)install\.sh$|(^|/)CODEOWNERS$|(^|/)\.github/workflows/'
readonly _MERGE_DISP_SCHEMA_RX='(^|/)(drizzle|migrations)/|(^|/)schema\.ts$|(^|/)db/schema'
# A user-facing surface. "Tests grade code; they do not grade a page" — a surface
# does not merge unseen, and this rail cannot look at a Vercel preview.
readonly _MERGE_DISP_SURFACE_RX='\.(tsx|jsx|css|scss)$'

# DIVE-4326 — WHO OWES A HELD MERGE, and why this is no longer the literal `main`.
#
# Until now every hold below printed `hold:main:<why>`, so `merge_owner` read
# `main` on every graded-and-waiting row. That constant — not a decision anyone
# made — is what put main's seat on the hands-on end of a merge any seat holding
# the credential can perform, and the heartbeat's DIVE-4206 rule then made the row
# dispatchable to main ALONE: the most expensive window we have (5-min cadence,
# accumulating context, one merge per wake). lodar, 2026-09-11: "why you merging?
# shouldn't this be ops job? why you on hands now?"
#
# So the pure decider stops naming a seat at all. `merger` joins `maker` as a
# ROLE in the disposition's vocabulary, and BOTH are resolved to a seat exactly
# once, on the impure side, where the row (for `maker`) and the repo (for
# `merger`) are in hand. The order the board now renders is: the GRADER when the
# branch is auto-mergeable at the graded sha (DIVE-3474 already lets a grader
# merge its own PASS, and DIVE-4137 records it), then ops, and main only where
# ops cannot reach.
readonly _MERGE_HOLD_SEAT="${FIVE_MERGE_HOLD_SEAT:-ops}"
readonly _MERGE_HOLD_SEAT_FALLBACK="${FIVE_MERGE_HOLD_SEAT_FALLBACK:-main}"
# The repo owners ops's credential covers. A LIST, not a derivation, and for
# gate_evidence.sh's DIVE-1955 reason: a live probe would make the recorded owner
# depend on network reachability at grade time, i.e. two boxes would record two
# different owners for one row. Drift is the price; the hold reason NAMES the
# seat it chose (`…-not-ops-reachable`) so a stale list announces itself to the
# seat it is failing.
readonly _MERGE_HOLD_SEAT_OWNERS_RX="${FIVE_MERGE_HOLD_SEAT_OWNERS_RX:-^(5dive-ai|lodar)/}"
# The roster, so a resolved seat is one the heartbeat will actually wake. Without
# this the fix repeats DIVE-4220 in a new place: a row whose merge_owner names a
# seat with `heartbeat.enabled=false` is dispatchable to NOBODY, which reads on
# the board exactly like a row waiting on a person.
readonly _MERGE_HOLD_ROSTER="${FIVE_MERGE_HOLD_ROSTER:-/var/lib/5dive/agents.json}"

# _merge_hold_seat_live <seat> -> rc 0 if the heartbeat will wake that seat.
#
# UNREADABLE ROSTER IS A YES, deliberately. Every seat can read agents.json today
# (640 root:claude), but a tree that cannot must not silently re-pin every merge
# onto main — that is the constant this row exists to remove, reintroduced as a
# failure mode. A wrong yes costs one bounce; a wrong no costs main's window.
_merge_hold_seat_live() {
  local seat="${1:-}" ans
  [[ -n "$seat" ]] || return 1
  [[ -r "$_MERGE_HOLD_ROSTER" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  ans=$(jq -r --arg s "$seat" '
          if (.agents | type) == "object" and (.agents[$s] == null) then "absent"
          elif (.agents[$s].heartbeat.enabled == false) then "disabled"
          else "live" end' "$_MERGE_HOLD_ROSTER" 2>/dev/null) || return 0
  [[ "$ans" == "live" ]]
}

# _merge_hold_seat <repo_slug> -> the seat that owes a held merge.
#
# IMPURE (roster read). Two named ways to land on the fallback, and only two:
#   (1) the pull request is in a repo outside what ops's credential covers;
#   (2) ops is not a seat the heartbeat will wake on this box.
# An EMPTY repo is not case (1). "We could not resolve the slug" is not evidence
# ops cannot read it, and treating it as such would route the whole transient-read
# family (`pr-state-unreadable`, `repo-unresolved`) back onto main — i.e. the
# common case would be the constant again.
# _merge_hold_fallback_seat -> the seat that owes a merge ops cannot take, or
# empty when this box has nobody for it.
#
# DIVE-4571. The fallback above was PRINTED UNCHECKED: `_merge_hold_seat` asked
# the roster whether `ops` was live and then, on a no, named `main` without
# asking the same question about it. Both names exist on exactly one box in the
# world — ours — so on the customer chart DIVE-4551 was filed from (teal-fox:
# claude-aleks / claude-alena / claude-jane) every held merge was stamped
# `merge_owner=main`, a seat that is not in the roster at all. That is the row
# shape luca measured as the OTHER half of the same report: assigned on its face,
# dispatchable to nobody, and `task doctor` calls the board clean. A name is a
# resolver you have not written (community/wiki/
# a-hardcoded-recipient-is-a-single-box-assumption.md).
#
# So the fallback is now three rungs, and every rung is CHECKED:
#   (1) the configured fallback seat, if the heartbeat will wake it;
#   (2) `_task_resolve_gate_notifier` — the resolver whose job is "which seat
#       pages a person about fleet state", falling back to the coordinator, i.e.
#       the same resolver DIVE-4551/4554 put behind the alert rails. On an
#       untagged lone-root chart that is the root; here it is `main`, which is
#       what rung (1) already answers, so this box never reaches it;
#   (3) nothing — and an empty answer is an ANSWER, handled by both callers,
#       rather than a constant that merely looks like one.
_merge_hold_fallback_seat() {
  local _n=""
  if _merge_hold_seat_live "$_MERGE_HOLD_SEAT_FALLBACK"; then
    printf '%s' "$_MERGE_HOLD_SEAT_FALLBACK"; return 0
  fi
  if declare -F _task_resolve_gate_notifier >/dev/null 2>&1; then
    _n=$(_task_resolve_gate_notifier 2>/dev/null) || _n=""
  fi
  if [[ -n "$_n" ]] && _merge_hold_seat_live "$_n"; then
    printf '%s' "$_n"; return 0
  fi
  return 1
}

# rc 1 + empty output = this box has no seat that owes a held merge. Callers
# degrade to the MAKER role rather than stamping a seat that does not exist:
# DIVE-4326 moved the hold off the maker because they have nothing left to do on
# a clean branch, which is a COST argument, and it is strictly outranked by a row
# nothing can dispatch.
_merge_hold_seat() {
  local repo="${1:-}"
  if [[ -n "$repo" ]] && ! grep -qE "$_MERGE_HOLD_SEAT_OWNERS_RX" <<<"$repo"; then
    _merge_hold_fallback_seat; return $?
  fi
  _merge_hold_seat_live "$_MERGE_HOLD_SEAT" || { _merge_hold_fallback_seat; return $?; }
  printf '%s' "$_MERGE_HOLD_SEAT"
}

# _merge_hold_resolve <disposition> <repo_slug> -> the disposition with the
# `merger` ROLE replaced by the seat that owes it. Everything else — `merge`,
# `hold:maker:…`, a disposition already naming a seat — passes through untouched.
_merge_hold_resolve() {
  local disp="${1:-}" repo="${2:-}"
  case "$disp" in
    hold:merger:*)
      # DIVE-4571: a ROLE that resolves to nobody stays a role. `maker` is the
      # one seat a row always has, the probe and the verifier close both already
      # resolve it, and the reason token carries WHY it landed there so a box
      # with no merge seat says so on the board instead of naming a phantom.
      local _mhs=""
      _mhs=$(_merge_hold_seat "$repo") || _mhs=""
      if [[ -n "$_mhs" ]]; then
        printf 'hold:%s:%s' "$_mhs" "${disp#hold:merger:}"
      else
        printf 'hold:maker:%s-no-merge-seat' "${disp#hold:merger:}"
      fi
      ;;
    *) printf '%s' "$disp" ;;
  esac
}

# _merge_disp_risk <repo_slug> <files, one per line> -> "low" | "look:<reason>"
#
# PURE — no gh, no root, no db. That is the point of splitting it out: every (iii)
# branch is gradeable from a fixture instead of from a live pull request, which is
# the difference between a test of this rule and a test of GitHub.
_merge_disp_risk() {
  local repo="${1:-}" files="${2:-}"
  # An empty file list is "I could not read the diff", never "the diff is empty".
  [[ -n "$files" ]] || { printf 'look:file-list-unreadable'; return 0; }
  # NOTE the herestrings. A `printf ... | grep -q` here would be the DIVE-4108
  # shape — grep exits on first match, printf dies of SIGPIPE, pipefail promotes
  # 141, and the test reads as NO MATCH. In this function that inverts a `look`
  # into a `low`, i.e. it fails OPEN. Never reintroduce the pipeline.
  if grep -qE "$_MERGE_DISP_LOOK_RX" <<<"$files"; then
    printf 'look:codeowners-path'; return 0
  fi
  if grep -qE "$_MERGE_DISP_SCHEMA_RX" <<<"$files"; then
    printf 'look:schema-path'; return 0
  fi
  # 5dive-api is the sharp repo by NAME as well as by path: merge deploys AND
  # pushes the schema. Anything under its src/db is a look even if the filename
  # does not match the generic schema pattern above.
  if [[ "$repo" == */5dive-api ]] && grep -qE '(^|/)src/db/' <<<"$files"; then
    printf 'look:api-db-path'; return 0
  fi
  if grep -qE "$_MERGE_DISP_SURFACE_RX" <<<"$files"; then
    printf 'look:user-facing-surface'; return 0
  fi
  printf 'low'
}

# _merge_disp_decide <mergeable> <merge_state> <head_sha> <graded_sha> <risk>
#   -> "merge" | "hold:merger:<why>" | "hold:maker:<why>"
#
# PURE, same reason. <risk> is _merge_disp_risk's output; the caller passes it in
# rather than this function calling it, so each of (i), (ii) and (iii) can be
# driven independently in a harness.
_merge_disp_decide() {
  local mergeable="${1^^}" state="${2^^}" head="${3,,}" graded="${4,,}" risk="${5:-}"

  # (i) A GRADE IS BOUND TO A SHA, NOT TO A PULL REQUEST. This is DIVE-2656's rule
  # read forwards instead of at the close: if the head has moved since the grade,
  # the thing that would merge is not the thing that was graded.
  [[ -n "$graded" ]] || { printf 'hold:merger:no-graded-sha-stated'; return 0; }
  [[ -n "$head"   ]] || { printf 'hold:merger:head-sha-unreadable';  return 0; }
  # Prefix either way: a verifier routinely states an abbreviated sha against a
  # 40-char head, and DIVE-2656's own comparison is a prefix comparison.
  if [[ "$head" != "$graded"* && "$graded" != "$head"* ]]; then
    printf 'hold:merger:graded-sha-is-not-the-head'; return 0
  fi

  # THE ONE MAKER CASE, and it is deliberately the only one. A conflicted branch
  # needs a rebase and nobody but the maker can do that. Everything else that is
  # not clean is a LOOK — routing it to the maker is what this ticket exists to
  # stop, because the maker has nothing to change.
  if [[ "$mergeable" == "CONFLICTING" || "$state" == "DIRTY" ]]; then
    printf 'hold:maker:conflicting-needs-rebase'; return 0
  fi
  [[ "$mergeable" == "MERGEABLE" ]] || { printf 'hold:merger:mergeable-%s' "${mergeable:-unknown}"; return 0; }

  # (ii) REQUIRED CHECKS AT THAT SHA. BLOCKED is GitHub's single answer for both a
  # red/pending required check AND a required review (CODEOWNERS) — both are a
  # look, and collapsing them here is correct because the response is the same.
  #
  # UNSTABLE is held on purpose. It means "mergeable, some NON-required check is
  # not green", so branch protection would let it through — but a red check at the
  # graded head is exactly the thing a person should see before it lands, and this
  # rail has no way to tell a flaky non-required check from a real one. Holding
  # costs a look; merging costs the thing we cannot undo.
  case "$state" in
    CLEAN|HAS_HOOKS) : ;;
    *) printf 'hold:merger:merge-state-%s' "${state:-unknown}"; return 0 ;;
  esac

  # (iii) RISK.
  [[ "$risk" == "low" ]] || { printf 'hold:merger:%s' "${risk#look:}"; return 0; }
  printf 'merge'
}

# _merge_disp_probe <pr> <graded_sha> -> the disposition, on stdout.
#
# IMPURE: this is the half that talks to GitHub, and it is kept as thin as it can
# be — one read, then the two pure functions above. A read that fails for any
# reason yields a hold naming that fact, never a merge.
_merge_disp_probe() {
  local pr="${1:-}" graded="${2:-}" tok raw mergeable state head files repo url rest
  [[ -n "$pr" ]] || { printf '%s' "$(_merge_hold_resolve hold:merger:no-delivery-ref '')"; return 0; }
  tok=$(_gate_gh_token 2>/dev/null || printf '')
  # US (unit separator) BETWEEN fields, joined by jq. A newline separator would be
  # ambiguous against the file list, which is the one field that can be long.
  # WITHIN the file list a newline is the right join precisely because the list is
  # LAST: everything after the fourth US is the list, newlines and all. A space
  # join re-split with `tr` (what shipped at iteration 1) turns one path
  # containing a space into two tokens, and the look patterns are line-anchored,
  # so `a b/install.sh` would stop matching. Quinn flagged the shape; arm E13.
  raw=$(_gate_gh "$tok" 20 pr view "$pr" \
          --json mergeable,mergeStateStatus,headRefOid,files,url \
          -q '[ (.mergeable // ""), (.mergeStateStatus // ""), (.headRefOid // ""),
                (.url // ""), ([ (.files // [])[]?.path ] | join("\n")) ] | join("\u001f")' \
          2>/dev/null) || raw=""
  [[ -n "$raw" ]] || { printf '%s' "$(_merge_hold_resolve hold:merger:pr-state-unreadable '')"; return 0; }
  mergeable="${raw%%$'\x1f'*}"; rest="${raw#*$'\x1f'}"
  state="${rest%%$'\x1f'*}";    rest="${rest#*$'\x1f'}"
  head="${rest%%$'\x1f'*}";     rest="${rest#*$'\x1f'}"
  url="${rest%%$'\x1f'*}";      files="${rest#*$'\x1f'}"
  # owner/name out of the RESOLVED url, not out of the caller's ref: a bare `#12`
  # delivery_ref names no repo at all.
  repo=$(sed -nE 's#^https?://[^/]+/([^/]+/[^/]+)/pull/.*#\1#p' <<<"$url")
  # An unresolved slug is an UNKNOWN, and every unknown is a hold. Without this
  # the sharp-repo arm of _merge_disp_risk (`*/5dive-api` + src/db) silently
  # degrades to `low` on a record whose url field did not come back — i.e. an
  # unreadable url would fail OPEN on exactly the repo where merge pushes schema.
  [[ -n "$repo" ]] || { printf '%s' "$(_merge_hold_resolve hold:merger:repo-unresolved '')"; return 0; }
  # The ROLE the pure decider emits becomes a SEAT here, where the repo is known.
  _merge_hold_resolve \
    "$(_merge_disp_decide "$mergeable" "$state" "$head" "$graded" \
                          "$(_merge_disp_risk "$repo" "$files")")" \
    "$repo"
}

# _merge_disp_read <rc> <out> — THE ONE READER of the rail's disposition marker.
# `_merge_do` achieves one of two different things on a success, and they are not
# interchangeable: an ENQUEUE is a request the queue may still eject, a MERGE is
# on the target branch. Both of the rail's callers need to tell them apart, and
# DIVE-4428 iteration 1 shipped a fix that taught only ONE of them (`task merge`)
# to grep for the marker — `src/task/status.sh` went on auditing
# `task.merged-at-close` and telling the operator the seat "merged it (squash)"
# over a request GitHub had merely accepted. A second grep is how the two answers
# drift apart again, so there is exactly one, here.
#
# Prints `enqueued`, `merged`, or NOTHING AT ALL on a refusal — a rail that
# refused achieved no disposition, and naming one would be the same defect in the
# other direction.
_merge_disp_read() {
  local rc="${1:-1}" out="${2:-}"
  (( rc == 0 )) || return 0
  # ORDER IS NOT ALPHABETICAL: `already-merged` is tested first because it is the
  # outcome that performed NOTHING, and a reader that fell through to `merged`
  # would credit this seat with a landing the maintainer made. Same class of
  # false record as the enqueue-read-as-merge that DIVE-4428 fixed, one outcome
  # further out.
  if [[ "$out" == *'_merge_do: disposition=already-merged'* ]]; then
    printf 'already-merged\n'
  elif [[ "$out" == *'_merge_do: disposition=enqueued'* ]]; then
    printf 'enqueued\n'
  else
    printf 'merged\n'
  fi
}

# _merge_disp_do <ident> — call the DIVE-3474 rail. Returns non-zero on any
# refusal and prints the primitive's own words to stderr, so a hold can name them.
# Deliberately the SAME primitive `task merge` uses: no second door into a merge.
# On a success it prints the DISPOSITION on stdout (`enqueued` / `merged`) so the
# close-time caller can tell a landing from a queued request; before DIVE-4428
# iteration 2 it captured the executor's stderr into `$out` and DISCARDED it, so
# the close had only an exit status and asserted a merge over an enqueue.
_merge_disp_do() {
  local ident="$1" rc=0 out=""
  out=$(printf '%s\0' "$ident" | sudo -n /usr/local/bin/5dive _merge_do 2>&1) || rc=$?
  [[ -n "$out" ]] && printf '%s\n' "$out" >&2
  _merge_disp_read "$rc" "$out"
  return "$rc"
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
    fail "$E_PERMISSION" "$ident: this seat holds no _merge_do grant, so NOTHING RAN — the merge was not attempted and was not refused on standing. A seat provisioned before DIVE-3474 does not carry the grant until its managed sudoers is re-rendered: run 'sudo 5dive agent grant <seat> merge' as root on the box (DIVE-4183). Until then the merge stays with a seat that holds one."
  fi
  [[ -n "$out" ]] && printf '%s\n' "$out" >&2
  (( rc == 0 )) || { mark_reported; return "$rc"; }
  # An enqueue is not a landing. The primitive says which one happened; saying
  # "merged" over an enqueue is how a seat closes a row on a merge that has not
  # happened, and the queue can still eject it.
  local _disp; _disp=$(_merge_disp_read "$rc" "$out")
  if [[ "$_disp" == "already-merged" ]]; then
    # RETIRE THE HOLD, because the thing it was held for has happened. This is
    # the SAME record `_merge_at_close_do` makes on a landing (status.sh) and it
    # is made here for the same reason: a row whose pull request is on the target
    # branch is owed no merge by anybody, and leaving `merge_owner` set paints
    # the board with an action nobody can take.
    # DIVE-4654: AND IT LEAVES THE MERGING STAGE, not only the hold. Retiring
    # merge_owner alone still left the row matching `_TASKS_TFV_SQL`, so the
    # board went on painting it graded->merge (owner falling back to the maker)
    # and the picker went on excluding its assignee — the deadlock this branch
    # was already standing in the middle of. The record is the same one
    # `task merge-landed` writes, through the same function.
    local _am_id _am_dref _am_ml _am_sha="" _am_at=""
    _am_id=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$ident");" 2>/dev/null || printf '')
    _am_dref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE ident=$(sqlq "$ident");" 2>/dev/null || printf '')
    # The sha and the mergedAt come from the SAME credential-free read the
    # primitive itself used, not from parsing its sentence back out of stderr: a
    # message is a message, and a record built by scraping one is a record that
    # breaks the next time the wording improves.
    if [[ -n "$_am_dref" ]]; then
      _am_ml=$(_merge_landed_read "$_am_dref" "$(_gate_slug_from_url "$_am_dref")") || _am_ml=""
      [[ -n "$_am_ml" ]] && { _am_sha="${_am_ml%%|*}"; _am_at="${_am_ml#*|}"; }
    fi
    if [[ -n "$_am_id" && -n "$_am_dref" ]]; then
      _task_merge_landed_record "$_am_id" "$_am_sha" "$_am_at" "$actor" "$_am_dref" || true
    else
      db "UPDATE tasks SET merge_owner=NULL, merge_hold_reason=NULL WHERE ident=$(sqlq "$ident");" || true
    fi
    _task_store_audit_log "task.merge-already-landed" ok 0 -- "$ident" "actor=$actor"
    ok "$ident: the pull request this seat graded PASS was ALREADY MERGED upstream — recorded, NO MERGE PERFORMED and no machine account used. The merge hold is retired; this seat did not land it and is not credited with it" \
       '{ident:$id, merged:true, enqueued:false, already_merged:true, performed:false, actor:$ac}' --arg id "$ident" --arg ac "$actor"
    return 0
  fi
  if [[ "$_disp" == "enqueued" ]]; then
    ok "$ident ENQUEUED — the pull request this seat graded PASS is in the target branch's merge queue and NOT yet on it; no second seat was asked. The queue lands it or ejects it — confirm with mergedAt before calling it shipped" \
       '{ident:$id, merged:false, enqueued:true, actor:$ac}' --arg id "$ident" --arg ac "$actor"
    return 0
  fi
  ok "$ident merged — the pull request this seat graded PASS is on the target branch; no second seat was asked" \
     '{ident:$id, merged:true, enqueued:false, actor:$ac}' --arg id "$ident" --arg ac "$actor"
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

# ── DIVE-4654 — `task merge-landed`: THE EXIT FROM THE MERGING STAGE ──────────
#
# THE DEADLOCK, measured on DIVE-4632 2026-09-20. Its pull request (5dive-ai/ops#20)
# merged on the forge at 19:08:15Z and its owed host-side clause was discharged
# twelve minutes later. Nine hours on, the row was still `in_progress` and a forced
# wake printed the whole thing in one line:
#
#     stage=MERGING stage-owner=ops assignee=quinn pickable-by-quinn=no
#
# The tick dispatches on the STAGE OWNER (ops, forever); the close is gated on the
# ASSIGNEE (quinn, excluded from the picker by the very same predicate); and the
# only verb that advances the stage — `task merge` — is grader-only by construction
# and refuses ops by name. Dispatched and unable to act; able to act and never
# dispatched. Four dispatches, the last three no-ops costing a session each.
#
# THE CAUSE IS A CORRECT DECISION, NOT A MISTAKE. The grading seat positive-
# controlled its rights on that repo as push=false/admin=false and therefore
# deliberately withheld the `graded-sha:` token so `merge_owner` would route to the
# seat that CAN push. That is the documented play, and it is also the play that
# makes the stage unreachable: the verb that exits MERGING is bound to the seat
# that GRADED, while the merge itself is bound to the seat that can PUSH. Whenever
# a capability is split across two seats, a state machine that ties its transition
# to one of them has a hole the size of the other.
#
# SO THE TRANSITION IS REACHABLE BY THE SEAT THE STAGE DISPATCHES TO. This verb
# RECORDS an observation — that the bound pull request is already on the target
# branch — and records nothing else. It is the observation half of the same pair
# `_merge_do_already_landed` already makes for the grader (DIVE-4528's branch),
# lifted to the seat the board actually wakes.
#
# IT WIDENS NO AUTHORITY AND IT MERGES NOTHING. The pull request is read from the
# row's own delivery_ref, never from the caller; the read is credential-free by
# construction (`_merge_landed_read` is handed an EMPTY token — asking what a pull
# request IS has never needed a machine account); and a read that does not come
# back with a `mergedAt` is a REFUSAL, so an unreachable GitHub leaves the row
# exactly where it is. There is no flag through which a caller can assert a
# landing the forge did not report: the only writes are the ones the probe's own
# answer produces.
#
# AND IT HANDS THE ROW TO THE SEAT THAT CAN CLOSE IT, which is the other half of
# the deadlock. Exiting the stage without moving the row would leave a graded loop
# row assigned to its MAKER, whose `task done` re-delivers (DIVE-4520) — the
# deadlock displaced by one seat rather than removed. On a loop row the seat whose
# close is ungated is the VERIFIER, which is precisely what the merge-owner wake
# note already tells a seat to do by hand (`task assign <ident> <verifier>`); doing
# it here makes it one act instead of two, and it is a no-op when the row is
# already assigned there.
#
# _task_merge_landed_record <id> <sha> <at> <actor> <ref> — the write, in one
# place, so the verb and `task merge`'s already-merged branch record a landing the
# same way. RETIRES THE HOLD for the reason that branch already states: a merged
# pull request is owed a merge by nobody, and leaving merge_owner set paints the
# board with an action nobody can take.
_task_merge_landed_record() {
  local id="$1" sha="$2" at="$3" actor="$4" ref="$5"
  db "UPDATE tasks SET
        merge_landed_at=datetime('now'),
        merge_landed_sha=$(sqlq "$sha"),
        merge_landed_by=$(sqlq "$actor"),
        merge_landed_ref=$(sqlq "$ref"),
        merge_owner=NULL,
        merge_hold_reason=NULL
      WHERE id=${id};" || return 1
  _task_store_audit_log "task.merge-landed" ok 0 -- \
    "id=${id}" "ref=${ref}" "sha=${sha}" "merged_at=${at}" "actor=${actor}" 2>/dev/null || true
  return 0
}

# _task_merge_landed_handoff <id> <ident> <assignee> <verifier> — put the row on
# the seat whose close is ungated. Prints a sentence when it moved the row and
# nothing when it did not. NOT `cmd_task_assign`: that verb has its own refusals
# (it declines to hand a row to its own verifier while nothing is delivered —
# exactly this row shape), and this is not a routing decision anybody is making,
# it is the recorded consequence of a merge that has already happened.
_task_merge_landed_handoff() {
  local id="$1" ident="$2" assignee="$3" vfier="$4"
  [[ -n "$vfier" && "$vfier" != "$assignee" ]] || return 0
  # The same clock reset `task assign` makes, and for its reason: an inherited
  # in_progress row that keeps the previous owner's started_at is eligible for the
  # stale reaper on the new owner's very first tick.
  db "UPDATE tasks SET
        assignee=$(sqlq "$vfier"),
        started_at=CASE WHEN status='in_progress' THEN datetime('now') ELSE started_at END
      WHERE id=${id};" || return 0
  printf ' The row is now assigned to %s, the seat whose close is ungated on a loop row.' "$vfier"
}

cmd_task_merge_landed() {
  local ident="" json=0 a
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      -h|--help)
        printf 'usage: 5dive task merge-landed <ident> [--json]\n\n  Record that the pull request bound to a row MERGED ON THE FORGE, so the row\n  leaves the MERGING stage (DIVE-4654). Runnable by the seat that owes the merge,\n  the assignee, or the grader. Merges nothing and needs no credential: it asks\n  GitHub whether the bound pull request already landed and REFUSES if it has not.\n'
        return 0 ;;
      --*) fail "$E_VALIDATION" "task merge-landed: unknown flag '$a' — usage: 5dive task merge-landed <ident> [--json]" ;;
      *) [[ -z "$ident" ]] && ident="$a" ;;
    esac
  done
  [[ -n "$ident" ]] || fail "$E_VALIDATION" "task merge-landed needs a task ident — usage: 5dive task merge-landed <ident>"
  (( json )) && JSON_MODE=1
  tasks_db_init

  local actor; task_actor_claim ""; actor="$ACTOR_BOARD"

  local row
  row=$(db "SELECT id||x'1f'||COALESCE(delivery_ref,'')||x'1f'||COALESCE(status,'')||x'1f'||
                   COALESCE(assignee,'')||x'1f'||COALESCE(verifier,'')||x'1f'||
                   COALESCE(graded_by,'')||x'1f'||$(_tasks_merge_owner_sql)||x'1f'||
                   COALESCE(merge_landed_at,'')||x'1f'||COALESCE(merge_landed_ref,'')||x'1f'||
                   CASE WHEN (${_TASKS_TFV_SQL}) THEN '1' ELSE '0' END
              FROM tasks WHERE ident=$(sqlq "$ident") LIMIT 1;" 2>/dev/null || printf '')
  [[ -n "$row" ]] || fail "$E_VALIDATION" "no task ${ident}."
  local id dref st asgn vfier gb owner landed_at landed_ref tfv rest
  id="${row%%$'\x1f'*}";        rest="${row#*$'\x1f'}"
  dref="${rest%%$'\x1f'*}";     rest="${rest#*$'\x1f'}"
  st="${rest%%$'\x1f'*}";       rest="${rest#*$'\x1f'}"
  asgn="${rest%%$'\x1f'*}";     rest="${rest#*$'\x1f'}"
  vfier="${rest%%$'\x1f'*}";    rest="${rest#*$'\x1f'}"
  gb="${rest%%$'\x1f'*}";       rest="${rest#*$'\x1f'}"
  owner="${rest%%$'\x1f'*}";    rest="${rest#*$'\x1f'}"
  landed_at="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
  landed_ref="${rest%%$'\x1f'*}"; tfv="${rest#*$'\x1f'}"

  case "$st" in
    done|cancelled) fail "$E_CONFLICT" "${ident} is ${st} — a terminal row is owed no merge and records no landing." ;;
  esac
  [[ -n "$dref" ]] \
    || fail "$E_CONFLICT" "${ident} has no delivery_ref, so no pull request is bound to it and there is no landing to record. Bind it: 5dive task deliver ${ident} --pr=<url>."
  # IDEMPOTENT BY THE SAME BINDING TEST THE PREDICATE USES. A second run is a
  # seat re-reading the board, not a second event, and it must not look like a
  # failure — but a record against a delivery_ref the row no longer carries is a
  # record of a DIFFERENT pull request, so that one is re-recorded rather than
  # reported as already done.
  if [[ -n "$landed_at" && "$landed_ref" == "$dref" ]]; then
    ok "${ident}: the landing of ${dref} is ALREADY RECORDED (at ${landed_at}) — the row has left the merging stage and is owed a close by '${asgn:-its assignee}', not a merge by anyone. Nothing was written." \
       '{ident:$id, recorded:true, already:true, closer:$cl}' --arg id "$ident" --arg cl "$asgn"
    return 0
  fi
  [[ "$tfv" == "1" ]] \
    || fail "$E_CONFLICT" "${ident} is NOT in the merging stage — it is not graded PASS with a live binding (\`5dive task show ${ident}\` prints the fields: graded_at, graded_verdict, delivery_ref, handoff_rejected_at). This verb records the exit from a stage this row is not in; it cannot stand in for a grade."
  # STANDING: the seat the stage DISPATCHES to, the seat that must CLOSE, or the
  # seat that GRADED. Deliberately not "any seat": the record is an observation,
  # but it moves a row and retires a hold, and a row's moves belong to the seats
  # the row names. Deliberately not "the grader only" either — that is the
  # constraint this whole row exists to remove.
  [[ "$actor" == "$owner" || "$actor" == "$asgn" || ( -n "$gb" && "$actor" == "$gb" ) ]] \
    || fail "$E_AUTH_REQUIRED" "${ident} names '${owner}' as the seat that owes its merge, '${asgn:-nobody}' as its assignee and '${gb:-nobody}' as its grader — '${actor}' is none of them, REFUSED. This verb records a landing on a row that names the seat recording it; it is not a board-wide reconciliation."

  local _ml
  _ml=$(_merge_landed_read "$dref" "$(_gate_slug_from_url "$dref")") || _ml=""
  [[ -n "$_ml" ]] \
    || fail "$E_CONFLICT" "${dref} does NOT read as merged (no mergedAt came back), so nothing was recorded and ${ident} still holds at MERGING, owed by '${owner}'. That is the same answer for a pull request that is still open, one closed without merging, one the queue ejected, and a GitHub that could not be asked at all — this verb records only a landing the forge itself reports. If it IS merged and this still refuses, the read could not reach GitHub: re-run it, or check the binding with \`gh pr view ${dref} --json state,mergedAt\`."
  local _sha="${_ml%%|*}" _at="${_ml#*|}"
  _task_merge_landed_record "$id" "$_sha" "$_at" "$actor" "$dref" \
    || fail "$E_GENERIC" "${ident}: the landing of ${dref} could not be recorded (the task store refused the write). Nothing changed."
  local _moved; _moved=$(_task_merge_landed_handoff "$id" "$ident" "$asgn" "$vfier")
  ok "${ident}: ${dref} is ON THE TARGET BRANCH (merged ${_at} as ${_sha:0:12}) — recorded, NO MERGE PERFORMED and no machine account used. The row has LEFT the merging stage, the merge hold is retired, and what it is owed now is a close.${_moved}" \
     '{ident:$id, recorded:true, already:false, sha:$sha, merged_at:$at, closer:$cl, actor:$ac}' \
     --arg id "$ident" --arg sha "$_sha" --arg at "$_at" \
     --arg cl "$([[ -n "$vfier" ]] && printf '%s' "$vfier" || printf '%s' "$asgn")" --arg ac "$actor"
}


# ── DIVE-4778 — `task merge-declined`: THE MERGING STAGE'S OTHER EXIT ─────────
#
# WHAT IT RECORDS, AND WHY IT IS NOT `merge-landed` WITH A FLAG. `merge-landed`
# answers *did the forge merge this pull request* and may only be written by the
# probe's own answer — that is the merging rail's whole safety property. This verb
# answers a DIFFERENT question: *is anybody still owed a merge on this row at all*.
# A deliberately held, superseded or re-pointed pull request is owed a merge by
# nobody, and NO PROBE CAN REPORT THAT — a refusal cannot report intent, so a
# hold and an accident come back as the same error string (measured on DIVE-4773:
# main converted the pull request to a draft as the hold, and the merge rail read
# the draft flag as the one obstacle to remove; community/wiki/a-draft-flag-is-a-
# hold-the-merge-dispatch-cannot-see.md). So the fact is asserted by a seat, in
# words, and it lands in `merge_declined_*` — never in `merge_landed_*`.
#
# WHAT IT COSTS TO NOT HAVE IT. Before this verb a merge owner woken onto a row
# whose pull request will never merge had no move that was true: `task merge` is
# grader-only and `enqueuePullRequest` refuses a draft; `task merge-landed` is
# refused by `_merge_landed_read` (no mergedAt) and its own refusal text says it
# cannot distinguish a hold from an outage; `task reject` is wrong (nothing is
# red) and, at the iteration cap, destructive — it runs `UPDATE tasks SET result=
# <feedback>` over the delivery record and files a decision gate. Five ops merge
# dispatches on DIVE-4773, five declines, zero moves; DIVE-4370 in the same shape.
#
# WHY IT HANDS THE ROW TO THE MAKER AND NOT THE VERIFIER. `merge-landed` hands
# off to the verifier because a landed row is owed a CLOSE. A declined row is
# owed the opposite: the work is fine and its destination is not, so what happens
# next — re-point the binding at the pull request that will land, or take the row
# terminal — is the maker's act. Handing it to the verifier would ask the one seat
# that cannot re-deliver to move it.
#
# _task_merge_declined_record <id> <ref> <reason> <actor> — the write, in one
# place. RETIRES THE HOLD for merge-landed's reason (a row owed no merge must not
# paint an action nobody can take) and TOUCHES NO merge_landed_* COLUMN.
_task_merge_declined_record() {
  local id="$1" ref="$2" why="$3" actor="$4"
  db "UPDATE tasks SET
        merge_declined_at=datetime('now'),
        merge_declined_by=$(sqlq "$actor"),
        merge_declined_ref=$(sqlq "$ref"),
        merge_declined_reason=$(sqlq "$why"),
        merge_owner=NULL,
        merge_hold_reason=NULL
      WHERE id=${id};" || return 1
  _task_store_audit_log "task.merge-declined" ok 0 -- \
    "id=${id}" "ref=${ref}" "reason=${why}" "actor=${actor}" 2>/dev/null || true
  return 0
}

# _task_merge_declined_handoff <id> <ident> <assignee> <maker> — put the row on
# the seat that can re-point the binding. Prints a sentence when it moved the row
# and nothing when it did not. Not `cmd_task_assign`, for `_task_merge_landed_
# handoff`'s reason: this is not a routing decision anybody is making, it is the
# recorded consequence of a merge that is not going to happen.
_task_merge_declined_handoff() {
  local id="$1" ident="$2" assignee="$3" maker="$4"
  [[ -n "$maker" && "$maker" != "$assignee" ]] || return 0
  # The same clock reset `task assign` makes: an inherited in_progress row that
  # keeps the previous owner's started_at is eligible for the stale reaper on the
  # new owner's very first tick.
  db "UPDATE tasks SET
        assignee=$(sqlq "$maker"),
        started_at=CASE WHEN status='in_progress' THEN datetime('now') ELSE started_at END
      WHERE id=${id};" || return 0
  printf ' The row is now assigned to %s, the seat that can re-point the binding.' "$maker"
}

cmd_task_merge_declined() {
  local ident="" why="" json=0 a
  for a in "$@"; do
    case "$a" in
      --reason=*) why="${a#--reason=}" ;;
      --json) json=1 ;;
      -h|--help)
        printf 'usage: 5dive task merge-declined <ident> --reason="<why this pull request will never merge>" [--json]\n\n  Record that the pull request bound to a row IS NOT THE ONE THAT WILL LAND --\n  held, superseded, or re-pointed at another repository -- so the row leaves the\n  MERGING stage and stops being dispatched to a merge owner with no available\n  move (DIVE-4778). Runnable by the seat that owes the merge, the assignee, or\n  the grader. ASSERTS NO LANDING: it writes none of the merge_landed_* columns,\n  it asks GitHub nothing, and it merges nothing. If the pull request DID merge,\n  the verb is `5dive task merge-landed <ident>` instead.\n'
        return 0 ;;
      --*) fail "$E_VALIDATION" "task merge-declined: unknown flag '$a' — usage: 5dive task merge-declined <ident> --reason=\"<why>\"" ;;
      *) [[ -z "$ident" ]] && ident="$a" ;;
    esac
  done
  [[ -n "$ident" ]] || fail "$E_VALIDATION" "task merge-declined needs a task ident — usage: 5dive task merge-declined <ident> --reason=\"<why>\""
  (( json )) && JSON_MODE=1
  tasks_db_init

  local actor; task_actor_claim ""; actor="$ACTOR_BOARD"

  local row
  row=$(db "SELECT id||x'1f'||COALESCE(delivery_ref,'')||x'1f'||COALESCE(status,'')||x'1f'||
                   COALESCE(assignee,'')||x'1f'||COALESCE(maker_agent,'')||x'1f'||
                   COALESCE(graded_by,'')||x'1f'||$(_tasks_merge_owner_sql)||x'1f'||
                   COALESCE(merge_declined_at,'')||x'1f'||COALESCE(merge_declined_ref,'')||x'1f'||
                   COALESCE(merge_declined_reason,'')||x'1f'||
                   CASE WHEN (${_TASKS_TFV_SQL}) THEN '1' ELSE '0' END||x'1f'||
                   CASE WHEN (${_TASKS_MERGE_LANDED_SQL}) THEN '1' ELSE '0' END
              FROM tasks WHERE ident=$(sqlq "$ident") LIMIT 1;" 2>/dev/null || printf '')
  [[ -n "$row" ]] || fail "$E_VALIDATION" "no task ${ident}."
  local id dref st asgn maker gb owner dec_at dec_ref dec_why tfv landed rest
  id="${row%%$'\x1f'*}";        rest="${row#*$'\x1f'}"
  dref="${rest%%$'\x1f'*}";     rest="${rest#*$'\x1f'}"
  st="${rest%%$'\x1f'*}";       rest="${rest#*$'\x1f'}"
  asgn="${rest%%$'\x1f'*}";     rest="${rest#*$'\x1f'}"
  maker="${rest%%$'\x1f'*}";    rest="${rest#*$'\x1f'}"
  gb="${rest%%$'\x1f'*}";       rest="${rest#*$'\x1f'}"
  owner="${rest%%$'\x1f'*}";    rest="${rest#*$'\x1f'}"
  dec_at="${rest%%$'\x1f'*}";   rest="${rest#*$'\x1f'}"
  dec_ref="${rest%%$'\x1f'*}";  rest="${rest#*$'\x1f'}"
  dec_why="${rest%%$'\x1f'*}";  rest="${rest#*$'\x1f'}"
  tfv="${rest%%$'\x1f'*}";      landed="${rest#*$'\x1f'}"

  # THE REASON IS THE RECORD. A decline is the one write on this rail that no
  # probe corroborates, so the only thing standing behind it is the sentence the
  # seat wrote; an unexplained decline on the board is indistinguishable from a
  # seat clearing a dispatch it did not want. Required, and required to say
  # something — DIVE-4654's own board cell falls back to "no reason recorded" for
  # merge_hold_reason and that fallback is exactly what must not be reachable here.
  why="${why#"${why%%[![:space:]]*}"}"; why="${why%"${why##*[![:space:]]}"}"
  [[ -n "$why" ]] \
    || fail "$E_VALIDATION" "task merge-declined ${ident} needs --reason=\"<why this pull request will never merge>\" — held, superseded, re-pointed at another repository. This verb records a judgement no forge read can corroborate, so the sentence IS the record: it is painted on the board, written to the audit log, and read by whoever picks the row up. Nothing was written."

  case "$st" in
    done|cancelled) fail "$E_CONFLICT" "${ident} is ${st} — a terminal row is owed no merge by anybody already, so there is nothing to decline." ;;
  esac
  [[ -n "$dref" ]] \
    || fail "$E_CONFLICT" "${ident} has no delivery_ref, so no pull request is bound to it and there is no merge to decline. Bind it: 5dive task deliver ${ident} --pr=<url>."
  # A LANDING IS NOT DECLINABLE. This verb's whole contract is that it asserts no
  # landing; the mirror of that is that it must not be able to overwrite one. A
  # recorded landing against the current binding is the forge's own answer and
  # this verb never contradicts it.
  [[ "$landed" != "1" ]] \
    || fail "$E_CONFLICT" "${dref} is RECORDED AS MERGED on ${ident} — a landed pull request cannot be declined, and this verb never overwrites a landing (\`5dive task show ${ident}\` prints it). The row has already left the merging stage; what it is owed now is a close. Nothing was written."
  # IDEMPOTENT BY THE BINDING, exactly as merge-landed is: a second run is a seat
  # re-reading the board, not a second event. A decline recorded against a
  # delivery_ref the row no longer carries is a decline of a DIFFERENT pull
  # request, so that one is re-recorded rather than reported as already done.
  if [[ -n "$dec_at" && "$dec_ref" == "$dref" ]]; then
    ok "${ident}: the decline of ${dref} is ALREADY RECORDED (at ${dec_at}, reason: ${dec_why:-none recorded}) — the row has left the merging stage and is owed a merge by nobody. Nothing was written." \
       '{ident:$id, declined:true, already:true, reason:$why, owner:$cl}' \
       --arg id "$ident" --arg why "$dec_why" --arg cl "${maker:-$asgn}"
    return 0
  fi
  [[ "$tfv" == "1" ]] \
    || fail "$E_CONFLICT" "${ident} is NOT in the merging stage — it is not graded PASS with a live binding (\`5dive task show ${ident}\` prints the fields: graded_at, graded_verdict, delivery_ref, handoff_rejected_at). This verb records the exit from a stage this row is not in; it is not a way to disown a delivery that has not been graded."
  # STANDING: the seat the stage DISPATCHES to, the seat that must move the row,
  # or the seat that GRADED — merge-landed's three, and for its reason. The whole
  # point of this verb is to give the DISPATCHED seat a move, so that seat is
  # first; it is deliberately not board-wide, because this write retires a hold
  # and moves a row, and a row's moves belong to the seats the row names.
  [[ "$actor" == "$owner" || "$actor" == "$asgn" || ( -n "$maker" && "$actor" == "$maker" ) || ( -n "$gb" && "$actor" == "$gb" ) ]] \
    || fail "$E_AUTH_REQUIRED" "${ident} names '${owner}' as the seat that owes its merge, '${asgn:-nobody}' as its assignee, '${maker:-nobody}' as its maker and '${gb:-nobody}' as its grader — '${actor}' is none of them, REFUSED. This verb declines a merge on a row that names the seat declining it; it is not a board-wide reconciliation."

  _task_merge_declined_record "$id" "$dref" "$why" "$actor" \
    || fail "$E_GENERIC" "${ident}: the decline of ${dref} could not be recorded (the task store refused the write). Nothing changed."
  local _moved; _moved=$(_task_merge_declined_handoff "$id" "$ident" "$asgn" "$maker")
  ok "${ident}: ${dref} IS NOT THE PULL REQUEST THAT WILL LAND — recorded (${why}). NO LANDING WAS ASSERTED: nothing was merged, no machine account was used, GitHub was not asked and no merge_landed_* field was touched. The row has LEFT the merging stage and is owed a merge by nobody; re-pointing the binding (\`5dive task deliver ${ident} --pr=<url>\`) puts it back in.${_moved}" \
     '{ident:$id, declined:true, already:false, ref:$ref, reason:$why, owner:$cl, actor:$ac}' \
     --arg id "$ident" --arg ref "$dref" --arg why "$why" \
     --arg cl "$([[ -n "$maker" ]] && printf '%s' "$maker" || printf '%s' "$asgn")" --arg ac "$actor"
}

# _merge_landed_read <pr-ref> <repo-slug> — HAS THIS PULL REQUEST ALREADY MERGED?
# Prints `<merge-commit-sha>|<mergedAt>` when it has, and NOTHING otherwise (not
# merged, or GitHub could not be asked). Never fails the caller: an unanswerable
# read is indistinguishable from "not merged yet" for the ONE decision it feeds,
# which is whether there is still a merge left to perform — and that decision
# fails towards today's behaviour, the credential demand.
#
# WHY IT IS ITS OWN FUNCTION, and not three lines inside `cmd_task_merge_do`:
# that caller is root-only and reached through a sudo hop, so a harness cannot
# execute it. The same argument DIVE-4428 iteration 2 made when it split
# `_merge_do_at_github` out — "a branch graded by grepping the source is not
# graded at all" — applies here, and this branch decides whether a credential is
# demanded. So it is executed, over a stubbed `gh`, in
# tests/task_merge_already_merged_unit.sh.
#
# THE READ IS CREDENTIAL-FREE BY CONSTRUCTION: `_gate_gh` is handed an EMPTY
# token, which is the same cheapest rail `_gate_pr_state` uses for the merge gate
# and `merge-gate-selftest` — a seat's own `gh` auth, the bot rail if one exists,
# or DIVE-2770's anonymous rail for a public repo. Asking what a pull request IS
# has never needed a machine account; only merging one does.
_merge_landed_read() {
  local _p _rest
  _p=$(_merge_landed_probe "$1" "${2:-}")
  [[ "${_p%%$'\x1f'*}" == "MERGED" ]] || return 0
  _rest="${_p#*$'\x1f'}"
  printf '%s|%s\n' "${_rest%%$'\x1f'*}" "${_rest#*$'\x1f'}"
}

# _merge_landed_probe <pr-ref> <repo-slug> — ONE READ, THREE ANSWERS.
#
# DIVE-4701. `_merge_landed_read` above collapses "the forge says it has not
# landed" and "the forge could not be asked" into the same empty string, and that
# is exactly right for the decision IT feeds: is there still a merge to perform?
# Both answers mean yes. It is exactly wrong for a POLLER, which must report an
# unreachable rail as a standing condition and must never report an open pull
# request as one. So the read lives here and the three answers are named, and the
# verb above is re-expressed on top of it rather than reading GitHub a second
# time — the same "there is exactly one reader" argument `_merge_disp_read`
# makes twenty lines up, for the same reason: a second grep is how two answers
# drift apart.
#
# Prints exactly one x1f-separated record:
#   MERGED<US><merge-commit-sha><US><mergedAt>   the forge reports a landing
#   OPEN<US><state>                              the forge answered; no landing
#   UNKNOWN<US>                                  the forge could not be asked
#
# `mergedAt` is the operand for MERGED, not `state`: it is the field that only a
# LANDING sets. A queue-evicted pull request reads state=OPEN and a closed-
# unmerged one reads state=CLOSED, and neither carries a mergedAt (DIVE-4337) —
# both are OPEN to this function, which is a statement about the LANDING and not
# about whether the pull request is open for business.
#
# THE READ IS CREDENTIAL-FREE BY CONSTRUCTION, unchanged: `_gate_gh` is handed an
# EMPTY token. Never fails the caller — an unanswerable read is UNKNOWN, which is
# a verdict, not an error.
_merge_landed_probe() {
  local ref="$1" slug="${2:-}" out="" st sha at rest
  local -a repo_arg=()
  [[ "$ref" =~ ^[0-9]+$ ]] && repo_arg=(--repo "$slug")
  out=$(_gate_gh "" 10 pr view "$ref" "${repo_arg[@]}" \
          --json state,mergedAt,mergeCommit \
          -q '[ (.state // "null"), (.mergeCommit.oid // "null"), (.mergedAt // "null") ] | join("|")' \
          2>/dev/null) || out=""
  # THREE fields or it is not an answer. A short record is a rail that returned
  # something other than what was asked for, and reading field 1 out of it as a
  # state would invent a verdict — the failure direction that matters here, since
  # UNKNOWN changes nothing and OPEN also changes nothing, but MERGED WRITES.
  st="${out%%|*}"; rest="${out#*|}"
  sha="${rest%%|*}"; at="${rest#*|}"
  [[ -n "$out" && "$rest" != "$out" && "$at" != "$rest" ]] \
    || { printf 'UNKNOWN\x1f\n'; return 0; }
  if [[ -n "$at" && "$at" != "null" ]]; then
    printf 'MERGED\x1f%s\x1f%s\n' "$sha" "$at"
    return 0
  fi
  printf 'OPEN\x1f%s\n' "${st:-unknown}"
}

# _merge_do_already_landed <pr-ref> — 0 when the pull request has ALREADY merged
# and the marker has been written; 1 when there is still a merge to perform.
#
# The caller's whole use of it is `_merge_do_already_landed "$pr" && return 0`, so
# the 1 is load-bearing in the ordinary direction: everything that is not a
# confirmed landing — not merged, closed unmerged, evicted from the queue, or a
# GitHub that could not be asked at all — carries on to the credential demand and
# behaves exactly as it does today.
_merge_do_already_landed() {
  local pr="$1" _ml=""
  _ml=$(_merge_landed_read "$pr" "$(_gate_slug_from_url "$pr")") || _ml=""
  [[ -n "$_ml" ]] || return 1
  printf '%s is ALREADY MERGED upstream as %s at %s — NOTHING WAS MERGED by this call and no machine account was used. Recording the landing that already happened.\n_merge_do: disposition=already-merged\n' \
    "$pr" "${_ml%%|*}" "${_ml#*|}" >&2
  return 0
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

  # A READ NEEDS NO MACHINE ACCOUNT; ONLY A MERGE DOES — so ask what
  # the pull request IS before demanding the credential to change it.
  #
  # THE DEFECT THIS REMOVES. The demand below was unconditional, and it sat
  # AFTER standing but BEFORE anything had read the pull request. On a box with
  # no bot connector that made a row whose pull request THE MAINTAINER ALREADY
  # MERGED — the normal case for an outside contributor, who cannot merge in the
  # target repo at all — closable by nobody: this verb demanded a credential to
  # perform a merge that had already happened; `task done` refused with
  # done-redelivers-a-graded-merge (DIVE-4520) or done-before-pr-merged
  # (DIVE-1830); `--force-redeliver` wants delivery fields; and `task assign` is
  # refused when the closer is the verifier. What was left was re-pointing the
  # verifier, reassigning, and closing as the new assignee — three verbs and an
  # audit trail that says the GRADER CHANGED, to record a merge that happened
  # without us. Measured on DIVE-549 / 5dive-ai/5dive#998, 2026-09-17: merged
  # upstream 14:21Z, row graded PASS, every close path refused.
  #
  # IT WIDENS NO AUTHORITY. Standing is already re-derived above, as root, over
  # the shared predicate, and the pull request is still the row's own
  # delivery_ref — this branch reads that same pull request and returns; it
  # cannot reach a different one, cannot merge anything, and cannot be entered by
  # a row that failed the standing query. The only thing it changes is WHICH
  # rows have to hold a credential: the ones with a merge still to perform.
  #
  # IT FAILS TOWARDS TODAY'S BEHAVIOUR. `_merge_landed_read` prints nothing when
  # GitHub cannot be asked, which is the same answer it gives for "not merged" —
  # so an unreachable GitHub lands on the credential demand exactly as it does
  # now, rather than on a quiet success. The direction matters: the wrong way
  # round, an unanswerable read would report a merge that nobody has confirmed.
  #
  # IN ITS OWN FUNCTION, for the DIVE-4428 iteration-2 reason: `cmd_task_merge_do`
  # is root-only behind a sudo hop, so a harness cannot execute this branch here.
  # `_merge_do_already_landed` can be executed, and is — the arms over it run the
  # branch rather than grepping for it. What a harness still cannot execute is
  # this branch's POSITION, so the harness asserts that separately, by line
  # number, against the credential demand below.
  _merge_do_already_landed "$pr" && return 0

  [[ -r "$_GH_BOT_ENV" ]] \
    || fail "$E_GENERIC" "machine-account credential missing ($_GH_BOT_ENV) — 5dive secret write ${_GH_BOT_KEY} --connector=github-bot"
  local tok
  # shellcheck disable=SC1090
  tok=$(set -a; . "$_GH_BOT_ENV"; set +a; printf '%s' "${GH_BOT_TOKEN:-}")
  [[ -n "$tok" ]] || fail "$E_GENERIC" "$_GH_BOT_ENV exists but carries no ${_GH_BOT_KEY}."

  local _ghcfg; _ghcfg="$(gh_config_dir)"

  # Everything above this line is AUTHORITY — root, SUDO_UID, the standing
  # predicate, the pull request read from the row. Everything below it is GitHub,
  # and lives in its own function so the five outcomes at GitHub can be EXECUTED
  # by the harness over a stubbed `gh` (DIVE-4428 iteration 2: iteration 1 graded
  # them with eight greps over `declare -f`, and two mutants with every one of
  # those strings intact survived the whole suite). The split moves no check and
  # widens nothing: the authority half is still re-derived here, as root, and
  # `_merge_do_at_github` is unreachable except through it.
  _merge_do_at_github "$ident" "$pr" "$actor" "$tok" "$_ghcfg"
}

# _merge_do_at_github <ident> <pr> <actor> <token> <gh-config-dir> — the GitHub
# half of `_merge_do`, called ONLY from it and only after standing has been
# re-derived as root. It decides nothing about who may merge; it decides how the
# base branch's governance says a merge is performed, performs it, and names the
# disposition it actually achieved.
_merge_do_at_github() {
  local ident="$1" pr="$2" actor="$3" tok="$4" _ghcfg="$5"


  # STEP 1 — ask GitHub how this base branch is governed, in ONE round trip that
  # also yields the two values an enqueue needs. `mergeQueue` non-null IS the
  # governance test: this repo protects `main` with a RULESET, which populates no
  # `branchProtectionRule`, so `requiresMergeQueue` is the wrong field to reach
  # for. A read that fails leaves every value empty and falls through to the
  # plain merge below — a governance probe must never be the thing that refuses.
  local _mq_query _meta _rc_meta=0
  _mq_query='query($url:URI!){resource(url:$url){... on PullRequest{id headRefOid isInMergeQueue mergeQueue{id}}}}'
  _meta=$(GH_TOKEN="$tok" GITHUB_TOKEN="" GH_CONFIG_DIR="$_ghcfg" \
            gh api graphql -f query="$_mq_query" -f url="$pr" 2>/dev/null) || _rc_meta=$?
  local _pr_id="" _head_oid="" _has_queue="" _already=""
  if (( _rc_meta == 0 )) && [[ -n "$_meta" ]]; then
    _pr_id=$(jq -r '.data.resource.id // empty' <<<"$_meta" 2>/dev/null || printf '')
    _head_oid=$(jq -r '.data.resource.headRefOid // empty' <<<"$_meta" 2>/dev/null || printf '')
    _has_queue=$(jq -r 'if (.data.resource.mergeQueue|type) == "object" then "1" else "" end' <<<"$_meta" 2>/dev/null || printf '')
    _already=$(jq -r 'if (.data.resource.isInMergeQueue) == true then "1" else "" end' <<<"$_meta" 2>/dev/null || printf '')
  fi

  local rc=0 out=""

  # STEP 2 — a queue-governed branch is ENQUEUED, never merged with an explicit
  # strategy. `gh pr merge --squash` names a strategy the queue owns; GitHub
  # answers that combination with `The merge strategy for main is set by the
  # merge queue` and then a GraphQL 500, which reads as an outage and invites a
  # retry that cannot work (DIVE-4428: four attempts, two pull requests, two
  # credentials, one failure mode — and two verified-good fixes left for a human
  # to press by hand). `enqueuePullRequest` returns the entry synchronously, so
  # the call that enqueues is the call that proves it, and `expectedHeadOid`
  # pins the graded sha server-side.
  if [[ -n "$_has_queue" ]]; then
    if [[ -n "$_already" ]]; then
      _task_store_audit_log "task merge" "ok" 0 -- "task=$ident" "pr=$pr" "grader=$actor" "actor=$actor" "disposition=already-queued" 2>/dev/null || true
      printf '%s was ALREADY IN THE MERGE QUEUE before this call — nothing re-enqueued (a second enqueue is a no-op at best). It is NOT on the target branch yet; the queue lands it or ejects it.\n_merge_do: disposition=enqueued\n' "$pr" >&2
      return 0
    fi
    if [[ -z "$_pr_id" || -z "$_head_oid" ]]; then
      mark_reported
      printf '_merge_do: %s sits on a MERGE-QUEUE-governed branch, but the pull request node id / head sha could not be read (gh api graphql exited %s), so there is nothing to pin an enqueue to. %s DOES hold merge standing on %s — this is a read failure at GitHub, not a standing refusal. Re-run; if it persists the queue can be read by hand with `gh api graphql -f query=%s -f url=%s`.\n' \
        "$pr" "$_rc_meta" "$actor" "$ident" "'$_mq_query'" "$pr" >&2
      return 1
    fi
    local _enq_mutation _enq_state=""
    _enq_mutation='mutation($pr:ID!,$oid:GitObjectID!){enqueuePullRequest(input:{pullRequestId:$pr,expectedHeadOid:$oid}){mergeQueueEntry{state position}}}'
    out=$(GH_TOKEN="$tok" GITHUB_TOKEN="" GH_CONFIG_DIR="$_ghcfg" \
            gh api graphql -f query="$_enq_mutation" -f pr="$_pr_id" -f oid="$_head_oid" 2>&1) || rc=$?
    (( rc == 0 )) && _enq_state=$(jq -r '.data.enqueuePullRequest.mergeQueueEntry.state // empty' <<<"$out" 2>/dev/null || printf '')
    if (( rc != 0 )) || [[ -z "$_enq_state" ]]; then
      mark_reported
      # GitHub's OWN words, verbatim and first. The defect this replaced buried
      # them under a 500 and a retry suggestion.
      [[ -n "$out" ]] && printf '%s\n' "$out" >&2
      printf '_merge_do: ENQUEUE REFUSED for %s (`enqueuePullRequest` exited %s, no queue entry returned) as the machine account. That is GitHub'"'"'s answer above, not a standing refusal — %s DOES hold merge standing on %s here. A required check red or still running, a head that moved since the grade (the enqueue pins %s), and a machine account the queue will not admit all land on this line.\n' \
        "$pr" "$rc" "$actor" "$ident" "$_head_oid" >&2
      return "$(( rc != 0 ? rc : 1 ))"
    fi
    # Audited as the GRADER's act, not root's: the whole point of the rail is that
    # the seat that graded is the seat that merged.
    _task_store_audit_log "task merge" "ok" 0 -- "task=$ident" "pr=$pr" "grader=$actor" "actor=$actor" "disposition=enqueued" 2>/dev/null || true
    printf '%s ENQUEUED (state=%s, head pinned at %s) by %s (the seat that graded it) as the machine account. This is NOT a landed merge: the queue runs the required checks against a branch that does not exist yet and then lands it OR EJECTS it. Read `mergeQueueEntry` / `mergedAt` before calling it shipped.\n_merge_do: disposition=enqueued\n' \
      "$pr" "$_enq_state" "$_head_oid" "$actor" >&2
    return 0
  fi

  # STEP 3 — no queue on the base branch: the ordinary squash merge, unchanged
  # except that gh's own message is CAPTURED and reprinted, so a refusal arrives
  # with its reason instead of a pointer to output that a caller capturing our
  # stderr may never have shown.
  out=$(GH_TOKEN="$tok" GITHUB_TOKEN="" GH_CONFIG_DIR="$_ghcfg" gh pr merge "$pr" --squash 2>&1) || rc=$?
  [[ -n "$out" ]] && printf '%s\n' "$out" >&2
  if (( rc != 0 )); then
    mark_reported
    printf '_merge_do: `gh pr merge %s --squash` exited %s as the machine account. That is GitHub'"'"'s answer above, not a standing refusal — %s DOES hold merge standing on %s here. A required check that is red or still running, a protected branch the machine account cannot merge, and a conflict all land on this line.\n' \
      "$pr" "$rc" "$actor" "$ident" >&2
    return "$rc"
  fi
  _task_store_audit_log "task merge" "ok" 0 -- "task=$ident" "pr=$pr" "grader=$actor" "actor=$actor" "disposition=merged" 2>/dev/null || true
  printf '%s merged by %s (the seat that graded it) as the machine account.\n' "$pr" "$actor" >&2
  return 0
}
