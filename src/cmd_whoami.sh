
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
  local a
  for a in "$@"; do
    case "$a" in
      -h|--help)
        cat <<'EOF'
5dive whoami [--json]

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
EOF
        return 0 ;;
      *) fail "$E_USAGE" "unknown flag: $a" ;;
    esac
  done

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
