# cmd_deploy — INST-5: the SECOND brokered capability. Delegated production
# deploy, behind the same gate → bind → root-only-executor template as
# `5dive push`, built on lib/broker.sh.
#
# WHY DEPLOY IS FIRST OF THE FIVE REMAINING SURFACES, and it is not a
# preference. INST-5 names six surfaces (email, deploy, DNS, payments, secrets,
# data-export). Reading the control plane on 2026-07-29 and again 2026-08-01,
# /etc/5dive/connectors/ holds vercel.env, npm.env and expo.env and NOTHING
# matching mail/smtp/resend/sendgrid/dns/cloudflare/namecheap/route53/stripe/
# paypal/export. Deploy is therefore the ONLY surface whose first commit is not
# blocked on a human dropping a credential. (Payments is additionally blocked on
# a spend decision.)
#
# WHAT DOES NOT PORT FROM PUSH, MEASURED RATHER THAN ASSUMED. Delegated push's
# headline property is a repo-scoped, short-lived installation token minted per
# use (set A: A1 scoped mint, A2 short-lived). It has no analogue here:
#
#   probe, 2026-08-01, with the on-box VERCEL_TOKEN:
#     POST https://api.vercel.com/v3/user/tokens  ->  HTTP 403
#     {"error":{"code":"forbidden","message":"To create a token you must be
#      authenticated to scope \"lodar\""}}
#
# So there is no mint-on-demand API we can drive from the control plane, and the
# wiki row's "none we drive" is now a measurement instead of a claim about our
# own code. The blast-radius bound must come entirely from set B — the executor,
# not the credential — which is exactly the inversion lib/broker.sh documents.
#
# Concretely, the bound here is:
#   B1  VERCEL_TOKEN read root-only from /etc/5dive/connectors/vercel.env, never
#       handed to the agent (broker_connector_read, which also flags a connector
#       whose mode already leaks it).
#   B2  gate re-verify + project resolve + deploy happen atomically inside the
#       one root helper `_deploy_do`; the agent process never holds the token.
#   B3  params over STDIN, never argv, so the NOPASSWD grant is an EXACT command
#       path with no trailing `*` — identical under classic sudo and sudo-rs.
#   B4  broker_gate_check with require-signature=1 inside root.
#   B5  the target is bound to the `Deploy: <project>@<ref>` line the TASK
#       declares, read fresh from the DB.
#   B6  audited via the main.sh dispatch wrapper + a `delegated_deploy`
#       capability row minted by the same path that installs the sudoers grant.
#
# And one bound this surface gets that push does not: THE REPO IS NOT A
# PARAMETER. The git repo deployed is read from the Vercel project's own link
# (GET /v9/projects/<project> -> .link), so a granted agent cannot point one of
# our projects at a repo it chose. The only things it supplies are which
# already-linked project, and which ref of that project's own repo.

readonly _DEPLOY_ENV_DEFAULT="/etc/5dive/connectors/vercel.env"
readonly _DEPLOY_API="https://api.vercel.com"

# _deploy_split_target <project@ref> — echo "<project> <ref>". Empty on a value
# that is not exactly one '@'-separated pair.
_deploy_split_target() {
  local v="$1"
  [[ "$v" == *@* ]] || return 0
  local proj="${v%@*}" ref="${v##*@}"
  [[ -n "$proj" && -n "$ref" && "$proj" != *@* ]] || return 0
  printf '%s %s' "$proj" "$ref"
}

# _deploy_validate_target <project> <ref> <env> — treat all three as hostile.
# They reach a URL path and a JSON body, and `ref` additionally names what runs
# in production, so "looks fine" is not the bar.
_deploy_validate_target() {
  local proj="$1" ref="$2" env="$3"
  [[ "$proj" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]] \
    || fail "$E_VALIDATION" "unsafe project name '${proj}' (allowed: letters, digits, . _ -; no leading punctuation; max 100)."
  [[ "$ref" =~ ^[A-Za-z0-9._/][A-Za-z0-9._/-]*$ ]] \
    || fail "$E_VALIDATION" "unsafe git ref '${ref}' (allowed: letters, digits, . _ / -; no leading '-')."
  [[ "$ref" == *..* ]] \
    && fail "$E_VALIDATION" "ref may not contain '..'."
  case "$env" in
    production|preview) ;;
    *) fail "$E_VALIDATION" "--env must be production or preview (got '${env}')." ;;
  esac
  return 0
}

# cmd_deploy <task-id> [--target=<project@ref>] [--env=production|preview] [--dry-run]
# Agent-context front door: resolve the task, take the target from the task's own
# `Deploy:` line, run the same guards as a friendly pre-flight (so --dry-run
# needs no privilege and the errors are readable), then hand the actual gated
# deploy to the root-only `_deploy_do`. The agent never receives a token.
cmd_deploy() {
  require_loaded deploy broker_gate_check broker_bind_target broker_task_target broker_connector_read broker_gate_sig_note
  tasks_db_init
  local target="" env="production" dry=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target=*) target="${1#*=}" ;;
      --env=*)    env="${1#*=}" ;;
      --dry-run)  dry=1 ;;
      --) shift; positional+=("$@"); break ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" \
    "usage: 5dive deploy <id|DIVE-N> [--target=<project@ref>] [--env=production|preview] [--dry-run]"

  resolve_task_id "${positional[0]}"
  local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"

  # Target: --target wins, else the task's own `Deploy: <project>@<ref>` line.
  # Either way broker_bind_target below re-derives it from the DB and refuses a
  # flag that disagrees, so the flag is a convenience, never an override.
  [[ -n "$target" ]] || target=$(broker_task_target deploy "$id")
  [[ -n "$target" ]] || fail "$E_USAGE" \
    "no deploy target for ${ident}: add a 'Deploy: <project>@<ref>' line to the task body (deploy refuses to guess)."

  local pair; pair=$(_deploy_split_target "$target")
  [[ -n "$pair" ]] || fail "$E_VALIDATION" \
    "deploy target must be exactly '<project>@<ref>' — got '${target}'."
  local proj="${pair%% *}" ref="${pair##* }"
  _deploy_validate_target "$proj" "$ref" "$env"

  # --- GATE pre-flight (re-verified authoritatively, signature-bound, in root).
  broker_gate_check deploy "$id" "$ident"
  # --- TARGET BINDING pre-flight (re-verified authoritatively in root).
  broker_bind_target deploy "$id" "$ident" "$target"

  if (( dry )); then
    # DIVE-2801: deploy's rehearsal runs the SAME require_sig=0 preflight push's does
    # (B4 passes 1 inside root), so it inherits the same defect and the same fix —
    # wired here in the one commit rather than left for the surface to rediscover.
    local sig_state; sig_state=$(broker_gate_sig_note deploy)
    ok "dry-run: would deploy ${proj}@${ref} to ${env} (gate cleared, ${sig_state}, target bound to ${ident})" \
       "$(jq -n --arg t "$ident" --arg p "$proj" --arg r "$ref" --arg e "$env" --arg gs "${BROKER_GATE_SIG_STATE:-unknown}" \
             '{task:$t,project:$p,ref:$r,env:$e,dryRun:true,gate:"cleared",gateSignature:$gs}')"
    return 0
  fi

  # --- Hand off to the root helper: it re-verifies the gate under signature,
  # resolves the project's OWN linked repo, reads the token root-only and fires
  # the one deployment. Parameters go over STDIN (never argv) so the NOPASSWD
  # grant stays an exact command path.
  local rc=0
  printf '%s\n' "$ident" "$proj" "$ref" "$env" \
    | sudo -n /usr/local/bin/5dive _deploy_do || rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "$E_GENERIC" \
      "delegated deploy failed — the task gate is not cleared, the Vercel credential is not provisioned (${_DEPLOY_ENV_DEFAULT}), the NOPASSWD grant for '_deploy_do' is missing (agent create --can-deploy), or the deploy itself failed (see above). See INST-5."
  fi
}

# cmd_deploy_do — ROOT-ONLY, the atomic gated deploy. Reads four lines on STDIN:
# <ident> <project> <ref> <env>. Re-verifies the gate AUTHORITATIVELY under
# signature (never trusts the caller), re-binds the target to the task's own
# declared value, resolves the project's linked repo from Vercel itself, reads
# the token root-only and fires ONE deployment. Prints only the result — never
# the token. Invoked over NOPASSWD sudo by cmd_deploy; parameters on stdin keep
# the grant exact-path (sudo-rs safe). Not advertised; not itself audited (the
# parent `deploy` verb is).
cmd_deploy_do() {
  [[ "$(id -u)" -eq 0 ]] || fail "$E_PERMISSION" "_deploy_do is root-only"
  require_loaded deploy broker_gate_check broker_bind_target broker_task_target broker_connector_read
  local ident proj ref env
  IFS= read -r ident || true
  IFS= read -r proj  || true
  IFS= read -r ref   || true
  IFS= read -r env   || true
  [[ -n "$ident" && -n "$proj" && -n "$ref" && -n "$env" ]] \
    || fail "$E_USAGE" "_deploy_do expects <ident> <project> <ref> <env> on stdin (INST-5)."

  # Input hardening BEFORE any of these strings reaches a URL or a JSON body.
  _deploy_validate_target "$proj" "$ref" "$env"

  # Authoritative gate re-verify — read FRESH from the DB by task id, never
  # trusting a verdict passed over stdin. require-signature=1 so a raw DB edit
  # cannot forge the clearance.
  tasks_db_init
  resolve_task_id "$ident"
  local id="$RESOLVED_TASK_ID"; ident="$RESOLVED_TASK_IDENT"
  broker_gate_check deploy "$id" "$ident" 1

  # Authoritative target binding — the caller-supplied project@ref must be the
  # one the cited task itself declares, so a granted agent cannot reuse one
  # task's cleared gate to ship a different project or a different ref.
  broker_bind_target deploy "$id" "$ident" "${proj}@${ref}"

  # --- credential (B1): root-only read, never exported to the agent.
  broker_connector_read "${VERCEL_ENV_FILE:-$_DEPLOY_ENV_DEFAULT}" "the Vercel"
  local tok="${VERCEL_TOKEN:-}"
  [[ -n "$tok" ]] || fail "$E_GENERIC" "vercel.env is missing VERCEL_TOKEN"
  local team="${VERCEL_TEAM_ID:-}" q=""
  [[ -n "$team" ]] && q="?teamId=${team}"

  # --- resolve the project's OWN linked repo. The repo is deliberately NOT a
  # parameter: whatever the agent named, the code deployed comes from the repo
  # this Vercel project is already linked to.
  local pj
  pj=$(curl -fsS --max-time 20 -H "Authorization: Bearer ${tok}" \
        "${_DEPLOY_API}/v9/projects/${proj}${q}") \
    || fail "$E_GENERIC" "Vercel project '${proj}' not found or the token cannot read it."
  local link_type link_org link_repo repo_id
  link_type=$(jq -r '.link.type // empty'   <<<"$pj")
  link_org=$( jq -r '.link.org  // empty'   <<<"$pj")
  link_repo=$(jq -r '.link.repo // empty'   <<<"$pj")
  repo_id=$(  jq -r '.link.repoId // empty' <<<"$pj")
  [[ "$link_type" == "github" && -n "$link_org" && -n "$link_repo" ]] \
    || fail "$E_GENERIC" "Vercel project '${proj}' has no linked GitHub repo — delegated deploy will not choose one for it"

  # --- the ONE action.
  local body out rc=0
  body=$(jq -cn --arg n "$proj" --arg t "$env" --arg o "$link_org" --arg r "$link_repo" \
                --arg ref "$ref" --arg rid "$repo_id" \
        '{name:$n, target:$t,
          gitSource: ({type:"github", org:$o, repo:$r, ref:$ref}
                      + (if $rid == "" then {} else {repoId:($rid|tonumber? // $rid)} end))}')
  out=$(curl -fsS --max-time 60 -X POST \
        -H "Authorization: Bearer ${tok}" \
        -H "Content-Type: application/json" \
        -d "$body" "${_DEPLOY_API}/v13/deployments${q}") || rc=$?
  tok=""   # discard
  [[ $rc -eq 0 ]] || fail "$E_GENERIC" "Vercel deployment request failed for ${proj}@${ref} (${env})."

  local did durl
  did=$( jq -r '.id  // empty' <<<"$out")
  durl=$(jq -r '.url // empty' <<<"$out")
  [[ -n "$did" ]] || fail "$E_GENERIC" "Vercel accepted the request but returned no deployment id."
  ok "deployed ${proj}@${ref} → ${env} (${did}${durl:+, https://$durl}) — delegated, gate cleared, repo ${link_org}/${link_repo} from the project's own link" \
     "$(jq -n --arg t "$ident" --arg p "$proj" --arg r "$ref" --arg e "$env" \
              --arg d "$did" --arg u "$durl" --arg repo "${link_org}/${link_repo}" \
           '{task:$t,project:$p,ref:$r,env:$e,deploymentId:$d,url:$u,repo:$repo,deployed:true,scoped:false,boundBy:"executor"}')"
}
