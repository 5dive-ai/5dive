# cmd_push — DIVE-1376: delegated push behind a gated `5dive push <task>`.
#
# Bobby gripe #1. Agents can read/inspect a repo but cannot authenticate Git
# transport to the private HTTPS remote (see the DIVE-1367 gap: the missing
# primitive is a repo/branch/op-scoped, short-lived, non-exportable Git
# capability). This verb is that primitive:
#
#   - ONE bot identity (a GitHub App) whose credential lives in the control
#     plane (/etc/5dive/connectors/github-app.env + a root-600 private key),
#     NEVER a human token and NEVER handed to the agent.
#   - `5dive push <task>` pushes ONLY the branch named in the task and ONLY
#     after the task's gate has cleared (reuses the gate primitive).
#   - Commit author stays lodar <markounik@gmail.com> — enforced by a fail-closed
#     pre-push scan — so the Vercel team author check stays green. The App
#     provides TRANSPORT auth only; it is fully decoupled from commit authorship.
#   - Fully logged (audit_log via the main.sh dispatch wrapper).
#
# The short-lived (1h) GitHub App installation token is minted on demand by a
# root-only helper (`5dive _push_mint_token`) over NOPASSWD sudo, exactly like
# the `_audit_append` primitive — so the agent process never reads the private
# key and never persists a token. The token is used for exactly one push and
# discarded.

readonly _PUSH_APP_ENV_DEFAULT="/etc/5dive/connectors/github-app.env"
readonly _PUSH_LODAR_AUTHOR="lodar <markounik@gmail.com>"
readonly _PUSH_DEFAULT_REPO="https://github.com/5dive-ai/5dive.git"

# _push_branch_from_body <body> — pull a "Branch: <name>" line out of a task
# body (case-insensitive, first match). Empty if absent.
_push_branch_from_body() {
  # `|| true` so a no-match grep can't trip `set -euo pipefail` when this runs
  # inside a command substitution (branch=$(...)).
  printf '%s\n' "$1" | grep -ioP '^\s*branch:\s*\K\S+' | head -1 || true
}

# _push_repo_slug <url> — OWNER/REPO from an https/ssh github URL, no .git.
_push_repo_slug() {
  printf '%s' "$1" | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##'
}

# cmd_push <task-id> [--branch=<b>] [--repo=<url>] [--dry-run] [--yes]
cmd_push() {
  tasks_db_init
  local branch="" repo="" dry=0 yes=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch=*) branch="${1#*=}" ;;
      --repo=*)   repo="${1#*=}" ;;
      --dry-run)  dry=1 ;;
      --yes|-y)   yes=1 ;;
      --) shift; positional+=("$@"); break ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" \
    "usage: 5dive push <id|DIVE-N> [--branch=<b>] [--repo=<url>] [--dry-run]"

  resolve_task_id "${positional[0]}"
  local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"

  # --- branch: --branch wins, else a "Branch: <name>" line in the task body.
  if [[ -z "$branch" ]]; then
    local body; body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
    branch=$(_push_branch_from_body "$body")
  fi
  [[ -n "$branch" ]] || fail "$E_USAGE" \
    "no branch for ${ident}: pass --branch=<name> or add a 'Branch: <name>' line to the task body (push refuses to guess)."
  case "$branch" in
    main|master|HEAD) fail "$E_VALIDATION" "refusing to push to protected branch '${branch}' — delegated push targets feature branches only." ;;
  esac

  # --- GATE: reuse the gate primitive. The task must carry an ANSWERED gate,
  # and the answer must not be a rejection. No gate / unanswered => refuse.
  local gtype ganswer gansweredat
  gtype=$(db "SELECT COALESCE(need_type,'')          FROM tasks WHERE id=${id};")
  gansweredat=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")
  ganswer=$(db "SELECT COALESCE(need_answer,'')       FROM tasks WHERE id=${id};")
  if [[ -z "$gtype" ]]; then
    fail "$E_VALIDATION" "no gate on ${ident}: file a ship gate first (5dive task need ${ident} --type=approval --ask=...) — push only runs after a human clears it."
  fi
  if [[ -z "$gansweredat" ]]; then
    fail "$E_VALIDATION" "gate on ${ident} is OPEN (unanswered ${gtype}) — push refused until it clears (5dive task answer ${ident} ...)."
  fi
  if printf '%s' "$ganswer" | grep -qiE '^\s*(no|reject|deny|denied|block)'; then
    fail "$E_VALIDATION" "gate on ${ident} was REJECTED ('${ganswer}') — push refused."
  fi

  # --- repo + remote sanity.
  repo="${repo:-$_PUSH_DEFAULT_REPO}"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "$E_GENERIC" \
    "run 5dive push from inside the repo work tree (current dir is not a git repo)."
  git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null || fail "$E_GENERIC" \
    "local branch '${branch}' not found — check it out here before pushing."

  # --- AUTHOR SCAN (fail-closed): every commit on <branch> not already on the
  # remote's main must be authored by lodar, or the Vercel team gate rejects it.
  local base rangespec offenders
  git fetch --quiet "$repo" main 2>/dev/null || true
  if base=$(git merge-base FETCH_HEAD "refs/heads/${branch}" 2>/dev/null) && [[ -n "$base" ]]; then
    rangespec="${base}..refs/heads/${branch}"
  else
    rangespec="refs/heads/${branch}"   # no shared base (new branch) — scan all
  fi
  offenders=$(git log --format='%H %an <%ae>' "$rangespec" 2>/dev/null \
              | grep -vF " ${_PUSH_LODAR_AUTHOR}" || true)
  if [[ -n "$offenders" ]]; then
    printf '%s\n' "$offenders" | sed 's/^/  /' >&2
    fail "$E_VALIDATION" \
      "author check FAILED — the commit(s) above are not authored '${_PUSH_LODAR_AUTHOR}'. Re-author (git rebase --exec 'git commit --amend --author=\"${_PUSH_LODAR_AUTHOR}\" --no-edit') before pushing; Vercel would reject them."
  fi

  local slug sha; slug=$(_push_repo_slug "$repo")
  sha=$(git rev-parse --short "refs/heads/${branch}")

  if [[ $dry -eq 1 ]]; then
    ok "dry-run: would push ${branch}@${sha} to ${slug} (gate cleared, author ok)" \
       "$(jq -n --arg t "$ident" --arg b "$branch" --arg s "$sha" --arg r "$slug" \
             '{task:$t,branch:$b,sha:$s,repo:$r,dryRun:true,gate:"cleared",author:"ok"}')"
    return 0
  fi

  # --- MINT a short-lived installation token via the root-only helper. The
  # agent process never touches the private key; the token is scoped to the App
  # installation and expires in ~1h. Discarded immediately after the push.
  local token
  token=$(sudo -n /usr/local/bin/5dive _push_mint_token 2>/dev/null) || token=""
  if [[ -z "$token" ]]; then
    fail "$E_GENERIC" \
      "could not mint a push token — the GitHub App credential is not provisioned (${_PUSH_APP_ENV_DEFAULT}) or the NOPASSWD sudo rule for '_push_mint_token' is missing. See DIVE-1376."
  fi

  # Push ONLY the named branch, using the token as HTTPS Basic auth. The token
  # never lands in argv (extraheader) so it cannot leak via ps/audit argv.
  local authhdr rc=0
  authhdr="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 -w0)"
  git -c http."https://github.com/".extraheader="$authhdr" \
      push "$repo" "refs/heads/${branch}:refs/heads/${branch}" 2>&1 | sed 's/^/  /' || rc=$?
  token=""   # discard

  if [[ $rc -ne 0 ]]; then
    fail "$E_GENERIC" "push failed (branch ${branch} → ${slug}); see output above."
  fi
  ok "pushed ${branch}@${sha} → ${slug} (delegated, author=lodar, gate cleared)" \
     "$(jq -n --arg t "$ident" --arg b "$branch" --arg s "$sha" --arg r "$slug" \
           '{task:$t,branch:$b,sha:$s,repo:$r,pushed:true}')"
}

# _push_mint_token — ROOT-ONLY. Reads the GitHub App credential from the control
# plane, signs a JWT with the App private key, exchanges it for a short-lived
# installation access token, and prints ONLY that token to stdout. Never echoes
# the private key. Invoked over NOPASSWD sudo by cmd_push (like _audit_append).
cmd_push_mint_token() {
  [[ "$(id -u)" -eq 0 ]] || fail "$E_PERMISSION" "_push_mint_token is root-only"
  local envf="${GITHUB_APP_ENV:-$_PUSH_APP_ENV_DEFAULT}"
  [[ -r "$envf" ]] || fail "$E_GENERIC" "missing GitHub App credential: $envf"
  # shellcheck disable=SC1090
  set -a; . "$envf"; set +a
  local app_id="${GITHUB_APP_ID:-}" inst="${GITHUB_APP_INSTALLATION_ID:-}"
  local pem="${GITHUB_APP_PRIVATE_KEY_FILE:-/etc/5dive/connectors/github-app.pem}"
  [[ -n "$app_id" && -n "$inst" && -r "$pem" ]] || \
    fail "$E_GENERIC" "GitHub App env incomplete (need GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, readable GITHUB_APP_PRIVATE_KEY_FILE)"

  # Build a short-lived App JWT (iat -60s for clock skew, exp +9min < 10min max).
  local now iat exp b64 header payload unsigned sig jwt
  now=$(date +%s); iat=$((now - 60)); exp=$((now + 540))
  b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | b64)
  unsigned="${header}.${payload}"
  sig=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$pem" -binary | b64)
  jwt="${unsigned}.${sig}"

  # Exchange the JWT for an installation token (github API).
  local tok
  tok=$(curl -fsS --max-time 15 -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/app/installations/${inst}/access_tokens" \
        | jq -r '.token // empty')
  [[ -n "$tok" ]] || fail "$E_GENERIC" "installation token exchange failed"
  printf '%s\n' "$tok"
}
