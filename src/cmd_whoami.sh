
# -------- 5dive whoami (DIVE-2517, v0.18 "Proof of who") --------
#
# Print the actor, the authority, the tier — and the SOURCE of each — from the one
# sealed derivation in lib/actor.sh. Read-only: no lock, no write, no audit row.
#
# The verb exists because "who is acting" had six answers in this CLI and no way to
# ask which one a given rail would use. Printing the source next to each value is
# the payload, not decoration: `sudo:claude` and `self` can carry the same identity
# and are not the same act, and an operator debugging a gate refusal needs to see
# that the identity came from the kernel while the elevation's NAME came from an
# env var.
#
# EXIT STATUS IS PART OF THE CONTRACT. An unmeasurable actor exits
# E_AUTH_REQUIRED, never rc=0 with the word `unknown` printed. A caller that can
# branch on `5dive whoami >/dev/null` is the smallest useful form of this verb, and
# it only works if the failure is in the status.

cmd_whoami() {
  local a subject=""
  for a in "$@"; do
    case "$a" in
      # DIVE-2519 (W3): the READ half. `--for` switches the verb from "who am I,
      # now" to "who did this, then" — the same question asked of the RECORD.
      # Parsed here rather than in a wrapper so `cmd_whoami` stays the single
      # entry point the sealed harness already grades.
      --for)   fail "$E_USAGE" "--for needs a subject: 5dive whoami --for=<id|DIVE-N>" ;;
      --for=*) subject="${a#--for=}"
               [[ -n "$subject" ]] || fail "$E_USAGE" "--for needs a subject: 5dive whoami --for=<id|DIVE-N>" ;;
      -h|--help)
        cat <<'EOF'
5dive whoami [--json]
5dive whoami --for=<id|DIVE-N> [--json]

Print the actor, authority and tier of the CURRENT process, with the source of each.

  actor      the unix principal owning the acting uid, and the board agent the
             registry maps it to. Read from $EUID (a kernel-backed bash builtin)
             resolved against /etc/passwd in pure bash. At real EUID 0, sudo's
             $SUDO_UID names the pre-elevation invoker instead.
  authority  root | sudo:<who> | self — under whose powers this process acts.
  tier       the registry's isolation tier for the resolved agent.

NOT consulted for identity: --from/argv, created_by, $USER, $SUDO_USER,
$LOGNAME, $FIVEDIVE_AUDIT_USER, `id`, `getent`. The first six are caller-supplied
and the last two resolve through the caller's own PATH.

Exit status: 0 when the actor was measured, 6 (auth_required) when it was not.
"Not an agent" is a MEASUREMENT and exits 0; "this uid resolves to nothing" is not.

--for=<id|DIVE-N>   render the RECORDED authority chain for one board row —
                    who created / started / delivered / answered-a-gate-on /
                    closed it, and under whose authority — from the ledger.
                    Scope it with --for=task:DIVE-N, gate:DIVE-N, action:DIVE-N.

  Every link resolves to exactly one of three verdicts:
    measured      an event of the right kind exists and names an identity.
    n/a           the STATE row says the transition never happened. By design.
    unmeasurable  the state row says it DID happen and the record cannot say
                  who, or under what authority.

  Exit status under --for: 0 when every link that happened is measured, 1 when
  any is unmeasurable, 4 for no such subject. Distinct from the bare verb's 6 on
  purpose: 6 means "I cannot measure YOU", 1 means "the record has a hole". A
  hole is a finding about the ledger, not a failure to authenticate the caller.
EOF
        return 0 ;;
      *) fail "$E_USAGE" "unknown flag: $a" ;;
    esac
  done

  if [[ -n "$subject" ]]; then
    _whoami_for "$subject"
    return $?
  fi

  local measured=1
  actor_derive || measured=0
  # jq wants real booleans, and a uid that failed to resolve must be `null` rather
  # than an empty string pretending to be a number.
  local j_measured=true; (( measured )) || j_measured=false
  local j_uid=null; [[ "$ACTOR_UID" =~ ^[0-9]+$ ]] && j_uid="$ACTOR_UID"
  actor_registry_agent "$ACTOR_UNIX"

  local authority; authority=$(_actor_authority)
  # Name the source honestly per branch. `sudo:<who>` is the one value on this
  # report whose payload is env-derived — the elevation is proven by EUID 0, but
  # WHO elevated is read from $SUDO_USER. Saying so is the difference between a
  # report and a claim.
  local auth_src
  case "$authority" in
    sudo:*) auth_src='euid=0 + $SUDO_USER (env: names the invoker, elevation itself proven by euid)' ;;
    root)   auth_src='euid=0, no invoking user' ;;
    *)      auth_src='euid (unelevated)' ;;
  esac

  local id_src
  case "$ACTOR_SOURCE" in
    sudo_uid) id_src='$SUDO_UID (trusted: real euid=0) -> /etc/passwd (pure bash)' ;;
    *)        id_src='$EUID (kernel) -> /etc/passwd (pure bash)' ;;
  esac

  # `unknown:unregistered` is a MEASUREMENT (this principal is not an agent), which
  # is why tier_unmeasured() excludes it. Every other unknown:* means the lookup
  # itself did not happen, and the report must say so rather than print a hole.
  local tier_src='registry .agents[<agent>].isolation'
  if tier_unmeasured "$ACTOR_TIER"; then tier_src='registry — NOT measured'; fi

  local ignored; ignored=$(actor_ignored_identity_env)

  if (( JSON_MODE )); then
    # Superset of the standard envelope on purpose: `.ok` and `.error.code` keep
    # their usual meaning, and `.data` is present on BOTH branches so a caller that
    # exits non-zero can still read what was measured before the refusal.
    local expr='{
      actor: {measured: $m, unix: $u, agent: $ag, uid: $uid, source: $isrc, reason: $rsn},
      authority: {value: $auth, source: $asrc},
      tier: {value: $tier, measured: $tm, source: $tsrc},
      ignored_for_identity: $ign
    }'
    local -a jargs=(
      --argjson m  "$j_measured"
      --arg     u  "$ACTOR_UNIX"
      --arg     ag "$ACTOR_AGENT"
      --argjson uid "$j_uid"
      --arg     isrc "$ACTOR_SOURCE"
      --arg     rsn  "$ACTOR_REASON"
      --arg     auth "$authority"
      --arg     asrc "$auth_src"
      --arg     tier "$ACTOR_TIER"
      --argjson tm   "$(tier_unmeasured "$ACTOR_TIER" && echo false || echo true)"
      --arg     tsrc "$tier_src"
      --arg     ign  "$ignored"
    )
    if (( measured )); then
      jq -cn "${jargs[@]}" "{ok:true, data: ($expr)}"
      return 0
    fi
    jq -cn "${jargs[@]}" \
      --argjson c 6 --arg cl auth_required \
      --arg m2 "actor is UNMEASURABLE ($ACTOR_REASON) — refusing to guess" \
      "{ok:false, error:{code:\$c, class:\$cl, message:\$m2}, data: ($expr)}"
    echo "error: actor is UNMEASURABLE ($ACTOR_REASON) — refusing to guess" >&2
    # DIVE-2598: this refusal builds its own --json envelope (it carries `data`
    # alongside the error, which fail() cannot express) and exits directly. It has
    # already said why, so the EXIT-trap backstop must not append a second
    # envelope — two objects on stdout is not JSON, and the caller parsing it gets
    # nothing at all from a command that answered correctly.
    mark_reported
    exit "$E_AUTH_REQUIRED"
  fi

  if (( measured )); then
    printf 'actor      %s\n' "${ACTOR_AGENT:-$ACTOR_UNIX}"
    printf '           unix=%s uid=%s%s\n' "$ACTOR_UNIX" "$ACTOR_UID" \
      "$( [[ -n "$ACTOR_AGENT" ]] && printf ' agent=%s' "$ACTOR_AGENT" || printf ' agent=<none> (not a registered agent)' )"
    printf '           source: %s\n' "$id_src"
  else
    printf 'actor      UNMEASURABLE (%s)\n' "$ACTOR_REASON"
    printf '           uid=%s source: %s\n' "${ACTOR_UID:-<none>}" "$id_src"
  fi
  printf 'authority  %s\n' "$authority"
  printf '           source: %s\n' "$auth_src"
  printf 'tier       %s\n' "$ACTOR_TIER"
  printf '           source: %s\n' "$tier_src"
  printf 'ignored for identity: %s\n' "${ignored:-<none set>}"

  (( measured )) || fail "$E_AUTH_REQUIRED" "actor is UNMEASURABLE ($ACTOR_REASON) — refusing to guess"
  return 0
}

# -------- 5dive whoami --for=<subject> (DIVE-2519, v0.18 W3) --------
#
# The READ half of "proof of who". INST-4 landed the recording layer
# (lifecycle_events: actor + authority, where authority is root | sudo:<who> |
# self — the elevation the audit log never captured) and `trace` already reads
# that table as a TIMELINE. Nothing read it as a CHAIN, and nothing REFUSED when
# the chain could not be measured. A timeline that silently omits the row nobody
# recorded looks identical to a clean history.
#
# The acceptance bar is DIVE-2224's: the event must be detectable FROM THE RECORD
# ALONE, by a reader with no memory of the conversation. So every link resolves to
# exactly one of three verdicts, and the third is the whole point:
#
#   measured      an event of the right kind exists and names an identity, under
#                 a recorded authority.
#   n/a           the STATE row says this transition never happened. Absent by
#                 design — conflating "did not happen" with "happened,
#                 unrecorded" is the absent-vs-forbidden bug this codebase has
#                 paid for repeatedly (DIVE-1989, DIVE-2318).
#   unmeasurable  the state row says the transition DID happen, and the record
#                 cannot tell us who did it or under what authority.
#
# The discriminator between `n/a` and `unmeasurable` is the tasks row's own
# transition columns (started_at, handoff_delivered_at, need_answered_at,
# done_at). That is the only honest way to have one: the ledger cannot
# distinguish its own silence from a thing that never occurred.
#
# UNMEASURABLE REASONS:
#   predates-ledger      created before task_prefs.ledger_started. The great
#                        majority of the board is in this bucket and always will
#                        be. Not a bug, and not a pass either.
#   ledger-start-unknown the start marker itself is missing, so we cannot even say
#                        WHICH of the two an empty ledger means. Weaker than
#                        predates-ledger; named separately on purpose.
#                        REACHABILITY, stated because a check nobody can exercise
#                        is a check nobody can trust (lib/audit.sh:154): through
#                        THIS verb the branch is unreachable, since tasks_db_init
#                        INSERT OR IGNOREs ledger_started and _whoami_for calls it
#                        first. Kept because the reason to distrust an empty marker
#                        does not depend on today's caller, and the harness reaches
#                        it through the tasks_db_init seam rather than pretending
#                        the verb can produce it.
#   no-recorded-event    post-ledger, the transition happened, no row was written.
#   actor-placeholder    the event exists and its actor is not an identity. The
#                        live table carries `cli` (task_actor's literal
#                        else-branch — resolution FAILED and recorded a value
#                        anyway) and `unknown` (_actor_identity's genuine-failure
#                        value, DIVE-2073). A placeholder in the actor column is a
#                        failed derivation wearing a name.
#   human-claim-undiscriminated  the actor is `human:<x>`. Per
#                        community/wiki/gate-record-cannot-distinguish-tap-from-selfclear.md
#                        NO field separates an authorized human tap from an agent
#                        self-clear: `human=1` is a self-assertable flag any
#                        root-capable agent may pass. Every `human:*` name on the
#                        live board is an agent short-name. --for must SAY so
#                        rather than render a green chain over it. UNMEASURABLE,
#                        not FORGED — the claim may well be true, we cannot grade it.
#   authority-absent     an actor with no recorded authority. Who, but not under
#                        what powers — half a link.
#
# DIVE-2518 RECONCILIATION, and it is the one thing this verb could not have said
# before W2. `--from` is now a CLAIM that is recorded beside the derivation rather
# than replacing it: when the two DISAGREE, ledger_record folds the measured
# principal into `detail` as `derived_actor=<name>` (tasks_db.sh:2110) and leaves
# the claim in the `actor` column. So on those rows the `actor` column is the
# LEAST reliable field in the row, and a reader that renders it as the answer
# prints the claim while the measurement sits one column over.
#
# That case is MEASURED, not unmeasurable, and the distinction is load-bearing:
# we know exactly who ran it. What we also know is that the row is attributed to
# somebody else, so the chain renders the DERIVED actor and carries the claim
# alongside it. Silently preferring either one would destroy the only record of
# the disagreement — which is the whole reason W2 wrote both down.
#
# Read-only: touches the shared task DB only. No mutation, no lock, no audit line
# of its own — same posture as trace/usage/digest.

# Actor values that are NOT identities. Kept as one list so the reason string and
# the test fixture cannot drift from the check.
_WHOAMI_PLACEHOLDER_ACTORS=" cli unknown - none null "

# _whoami_for <subject>
# subject := [task:|gate:|action:]<id|DIVE-N>
_whoami_for() {
  tasks_db_init
  local raw="$1" scope="all"
  case "$raw" in
    task:*)   scope="task";   raw="${raw#task:}" ;;
    gate:*)   scope="gate";   raw="${raw#gate:}" ;;
    action:*) scope="action"; raw="${raw#action:}" ;;
  esac
  [[ -n "$raw" ]] || fail "$E_USAGE" "--for needs a subject after the class prefix"

  resolve_task_id "$raw"
  local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"

  # ---- the STATE row: which transitions actually happened -----------------
  # This is the discriminator between "n/a" and "unmeasurable". Read it from the
  # tasks row, never from the ledger — the ledger cannot testify to its own gaps.
  local srow
  srow=$(db "SELECT COALESCE(created_at,'')||'|'||COALESCE(started_at,'')||'|'||
                    COALESCE(handoff_delivered_at,'')||'|'||COALESCE(need_answered_at,'')||'|'||
                    COALESCE(done_at,'')||'|'||COALESCE(status,'')
               FROM tasks WHERE id=${id};")
  local s_created s_started s_delivered s_answered s_done s_status
  IFS='|' read -r s_created s_started s_delivered s_answered s_done s_status <<<"$srow"

  # ---- the ledger start marker -------------------------------------------
  local ledger_started
  ledger_started=$(db "SELECT value FROM task_prefs WHERE key='ledger_started';" 2>/dev/null || true)
  local predates=0 start_unknown=0
  if [[ -z "$ledger_started" ]]; then
    start_unknown=1
  elif [[ -n "$s_created" && "$s_created" < "$ledger_started" ]]; then
    predates=1
  fi

  # ---- link table: name | class | happened? | matching ledger kinds -------
  # Each row is one link of the authority chain. `kinds` is a comma-separated SQL
  # IN-list; a terminal close matches EITHER task.done or task.cancelled because
  # the state column (done_at) cannot say which and both are the same link.
  local -a L_NAME=(created started delivered answered closed)
  local -a L_CLASS=(task task task gate action)
  local -a L_WHEN=("$s_created" "$s_started" "$s_delivered" "$s_answered" "$s_done")
  local -a L_KINDS=("'task.created'" "'task.started'" "'task.delivered'" "'gate.answered'" "'task.done','task.cancelled'")

  local rows_json="" any_unmeasurable=0 n_measured=0 n_unmeasurable=0 n_na=0 n_divergent=0
  local i
  for i in "${!L_NAME[@]}"; do
    local name="${L_NAME[$i]}" class="${L_CLASS[$i]}" when="${L_WHEN[$i]}" kinds="${L_KINDS[$i]}"
    [[ "$scope" == "all" || "$scope" == "$class" ]] || continue

    local verdict reason="" ev_ts="" ev_actor="" ev_auth="" ev_kind="" ev_detail=""
    local eff_actor="" claimed=""
    if [[ -z "$when" ]]; then
      # The state row says this transition never occurred. Absent by design.
      verdict="n/a"; reason="did-not-happen"; n_na=$(( n_na + 1 ))
    else
      local ev
      # char(9), NOT a '\t' literal: SQLite's || concatenation does not interpret
      # backslash escapes, so '\t' concatenates a BACKSLASH and a t and the
      # IFS=$'\t' read below then finds no field separator at all — every field
      # lands in $ev_ts and the actor reads EMPTY, which this verb would report as
      # actor-placeholder. A measurement bug that fabricates the exact finding the
      # verb exists to report is the worst possible failure here.
      ev=$(db "SELECT ts||char(9)||kind||char(9)||actor||char(9)||authority||char(9)||COALESCE(detail,'')
                 FROM lifecycle_events
                WHERE ident=$(sqlq "$ident") AND kind IN (${kinds})
                ORDER BY id LIMIT 1;" 2>/dev/null || true)
      if [[ -z "$ev" ]]; then
        verdict="unmeasurable"
        if (( start_unknown )); then      reason="ledger-start-unknown"
        elif (( predates )); then         reason="predates-ledger"
        else                              reason="no-recorded-event"; fi
      else
        IFS=$'\t' read -r ev_ts ev_kind ev_actor ev_auth ev_detail <<<"$ev"
        # DIVE-2518: `derived_actor=` in the detail means --from was a claim that
        # DISAGREED with the measurement. The derived name is the measured one;
        # the actor column holds the claim. Grade the derived name, keep the claim.
        eff_actor="$ev_actor"
        if [[ "$ev_detail" == *derived_actor=* ]]; then
          local d="${ev_detail##*derived_actor=}"; d="${d%% *}"
          if [[ -n "$d" ]]; then claimed="$ev_actor"; eff_actor="$d"; fi
        fi
        local a_lower="${eff_actor,,}"
        if [[ -z "$eff_actor" || "$_WHOAMI_PLACEHOLDER_ACTORS" == *" $a_lower "* ]]; then
          verdict="unmeasurable"; reason="actor-placeholder:${eff_actor:-<empty>}"
        elif [[ "$a_lower" == human:* ]]; then
          verdict="unmeasurable"; reason="human-claim-undiscriminated"
        elif [[ -z "$ev_auth" ]]; then
          verdict="unmeasurable"; reason="authority-absent"
        else
          verdict="measured"
          if [[ -n "$claimed" ]]; then
            reason="claim-divergent:${claimed}"; n_divergent=$(( n_divergent + 1 ))
          fi
        fi
      fi
      # $(( x + 1 )), never (( x++ )): a post-increment from 0 EVALUATES to 0, so
      # the arithmetic command exits 1 and `set -e` kills the run mid-loop — the
      # first unmeasurable link would abort the render and print nothing at all.
      if [[ "$verdict" == "measured" ]]; then n_measured=$(( n_measured + 1 ))
      else n_unmeasurable=$(( n_unmeasurable + 1 )); any_unmeasurable=1; fi
    fi

    rows_json+="$(jq -nc --arg link "$name" --arg class "$class" --arg verdict "$verdict" \
                        --arg reason "$reason" --arg state_at "$when" --arg ts "$ev_ts" \
                        --arg kind "$ev_kind" --arg actor "$eff_actor" --arg authority "$ev_auth" \
                        --arg claimed "$claimed" \
                  '{link:$link,class:$class,verdict:$verdict,reason:$reason,
                    state_at:$state_at,
                    event:{ts:$ts,kind:$kind,actor:$actor,authority:$authority,
                           claimed_by:(if $claimed=="" then null else $claimed end)}}')"$'\n'
  done

  local links
  links=$(printf '%s' "$rows_json" | jq -sc '.')
  [[ -n "$links" ]] || links='[]'

  local chain_verdict="measured"
  (( any_unmeasurable )) && chain_verdict="unmeasurable"

  if [[ "${JSON_MODE:-0}" == "1" ]]; then
    jq -n --arg ident "$ident" --arg scope "$scope" --arg status "$s_status" \
          --arg chain "$chain_verdict" --arg ledger_started "$ledger_started" \
          --argjson predates "$predates" \
          --argjson measured "$n_measured" --argjson unmeasurable "$n_unmeasurable" \
          --argjson na "$n_na" --argjson divergent "$n_divergent" --argjson links "$links" \
      '{ident:$ident,scope:$scope,status:$status,chain:$chain,
        ledger_started:$ledger_started,predates_ledger:($predates==1),
        counts:{measured:$measured,unmeasurable:$unmeasurable,na:$na,claim_divergent:$divergent},
        links:$links}'
  else
    printf 'authority chain for %s  (scope: %s, status: %s)\n\n' "$ident" "$scope" "${s_status:-?}"
    printf '  %-10s %-7s %-13s %-20s %-16s %s\n' LINK CLASS VERDICT ACTOR AUTHORITY WHEN/REASON
    printf '%s' "$rows_json" | jq -r '
      "  \(.link[0:10] | . + (" " * (10 - length)))"
      + " \(.class[0:7] | . + (" " * (7 - length)))"
      + " \(.verdict[0:13] | . + (" " * (13 - length)))"
      + " \((if .verdict=="measured" then .event.actor else "-" end)[0:20] as $a | $a + (" " * (20 - ($a|length))))"
      + " \((if .verdict=="measured" then .event.authority else "-" end)[0:16] as $x | $x + (" " * (16 - ($x|length))))"
      + " \(if .verdict=="measured" and .reason=="" then .event.ts else .reason end)"'
    printf '\n  chain: %s   (measured %d · unmeasurable %d · n/a %d)\n' \
      "$chain_verdict" "$n_measured" "$n_unmeasurable" "$n_na"
    if (( n_divergent )); then
      printf '  note: %d link(s) carry a --from claim that DISAGREED with the derivation\n' "$n_divergent"
      printf '        (DIVE-2518). The actor shown is the DERIVED one; claimed_by holds the claim.\n'
    fi
    if (( predates )); then
      printf '  note: this row was created before the ledger opened (%s), so its early links\n' "$ledger_started"
      printf '        were never recordable. Unmeasurable, not clean.\n'
    fi
    if (( start_unknown )); then
      printf '  note: task_prefs.ledger_started is MISSING, so an empty ledger cannot be told\n'
      printf '        apart from work that predates it. Weakest possible reading.\n'
    fi
    if [[ "$chain_verdict" == "unmeasurable" ]]; then
      printf '\n  REFUSED: the chain cannot be measured from the record alone. Exit 1.\n'
    fi
  fi

  if (( any_unmeasurable )); then return 1; fi
  return 0
}
