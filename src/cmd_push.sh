# cmd_push — DIVE-1376/1460: delegated push behind a gated `5dive push <task>`.
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
#     scan — so the Vercel team author check stays green. The App provides
#     TRANSPORT auth only; it is fully decoupled from commit authorship.
#   - Fully logged (audit_log via the main.sh dispatch wrapper).
#
# DIVE-1460 (security hardening — the mint must not be a side door):
#   - The privileged work (gate re-verify + author scan + token mint + the one
#     push) happens ATOMICALLY inside a single root-only helper `_push_do`, so
#     the agent process NEVER holds a token it could exfil and reuse. This
#     realizes the design's own "agent never holds a token" goal.
#   - The installation token is minted SCOPED to just the target repo
#     (repositories:[<repo>] + permissions:{contents:write}), so even a captured
#     token can't reach other org repos — blast radius is one repo, not the org.
#   - `_push_do` reads its parameters over STDIN, never argv, so the NOPASSWD
#     grant stays an EXACT command path (`/usr/local/bin/5dive _push_do`) with no
#     trailing-`*` arg match — it therefore holds identically under classic sudo
#     and under sudo-rs, where argument wildcards are ignored.

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

# _push_repo_name <url> — bare repo name (no owner, no .git), for token scoping.
_push_repo_name() {
  local n="${1##*/}"; printf '%s' "${n%.git}"
}

# _push_gate_check <id> <ident> — the ONE cleared-gate predicate (DIVE-1376/1460).
# The task must carry a gate that is ANSWERED and whose answer is not a rejection.
# Called by BOTH the `cmd_push` pre-flight AND the root-only `_push_do` (which is
# authoritative), so a direct `sudo 5dive _push_do` can't bypass the human gate.
# Fails via `fail` on any miss (no gate / open / rejected); returns 0 only when
# the gate is genuinely cleared.
_push_gate_check() {
  local id="$1" ident="$2" gtype ganswer gansweredat
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
}

# _push_author_scan <repo-path> <repo-url> <branch> — fail-closed author scan.
# Every commit on <branch> not already on the remote's main must be authored by
# lodar, or the Vercel team gate rejects the push. Runs in agent pre-flight (a
# friendly early error) AND authoritatively inside `_push_do`. `git -C` + a
# scoped safe.directory so it also works when root operates on the agent's tree.
_push_author_scan() {
  local repopath="$1" repourl="$2" branch="$3"
  local -a G=(git -C "$repopath" -c "safe.directory=$repopath")
  local base rangespec offenders
  "${G[@]}" fetch --quiet "$repourl" main 2>/dev/null || true
  if base=$("${G[@]}" merge-base FETCH_HEAD "refs/heads/${branch}" 2>/dev/null) && [[ -n "$base" ]]; then
    rangespec="${base}..refs/heads/${branch}"
  else
    rangespec="refs/heads/${branch}"   # no shared base (new branch) — scan all
  fi
  offenders=$("${G[@]}" log --format='%H %an <%ae>' "$rangespec" 2>/dev/null \
              | grep -vF " ${_PUSH_LODAR_AUTHOR}" || true)
  if [[ -n "$offenders" ]]; then
    printf '%s\n' "$offenders" | sed 's/^/  /' >&2
    fail "$E_VALIDATION" \
      "author check FAILED — the commit(s) above are not authored '${_PUSH_LODAR_AUTHOR}'. Re-author (git rebase --exec 'git commit --amend --author=\"${_PUSH_LODAR_AUTHOR}\" --no-edit') before pushing; Vercel would reject them."
  fi
}

# _push_validate_inputs <branch> <url> <repo-path> — DIVE-1460 hardening. `_push_do`
# runs as ROOT on strings an agent controls, so reject anything that could act as
# a git flag, an alternate remote, or a path traversal BEFORE it reaches git in
# argument position. `fail`s on any violation; on success prints the canonical
# (realpath'd) repo-path. `ident` is separately constrained by resolve_task_id's
# <PREFIX>-<n> grammar.
_push_validate_inputs() {
  local branch="$1" repourl="$2" repopath="$3"
  #   branch: safe ref charset, never flag-like ('-' lead) or a '..' rev range.
  [[ "$branch" =~ ^[A-Za-z0-9._/][A-Za-z0-9._/-]*$ ]] \
    || fail "$E_VALIDATION" "unsafe branch name '${branch}' (allowed: letters, digits, . _ / -; no leading '-')."
  [[ "$branch" == *..* ]] \
    && fail "$E_VALIDATION" "branch may not contain '..'."
  #   url: EXACTLY an https github.com/<org>/<repo>(.git)? — no ssh, no other
  #   host, nothing flag-like or with an embedded credential.
  [[ "$repourl" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\.git)?$ ]] \
    || fail "$E_VALIDATION" "repo url must be https://github.com/<org>/<repo> — got '${repourl}'."
  #   repo-path: canonicalize (blocks traversal / surprise targets); must exist +
  #   be absolute.
  local rp; rp=$(realpath -e -- "$repopath" 2>/dev/null) \
    || fail "$E_VALIDATION" "repo-path '${repopath}' does not resolve."
  [[ "$rp" == /* ]] || fail "$E_VALIDATION" "repo-path must be absolute."
  printf '%s' "$rp"
}

# cmd_push <task-id> [--branch=<b>] [--repo=<url>] [--dry-run] [--yes]
# Agent-context front door: resolve the task, pick the branch, run the same
# guards as a friendly pre-flight (so --dry-run needs no privilege and errors are
# clear), then hand the actual gated push to the root-only `_push_do`. The agent
# never receives a token.
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

  # --- GATE pre-flight (re-verified authoritatively in _push_do).
  _push_gate_check "$id" "$ident"

  # --- repo + work-tree sanity.
  repo="${repo:-$_PUSH_DEFAULT_REPO}"
  local repopath
  repopath=$(git rev-parse --show-toplevel 2>/dev/null) || fail "$E_GENERIC" \
    "run 5dive push from inside the repo work tree (current dir is not a git repo)."
  git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null || fail "$E_GENERIC" \
    "local branch '${branch}' not found — check it out here before pushing."

  # --- AUTHOR SCAN pre-flight (re-verified authoritatively in _push_do).
  _push_author_scan "$repopath" "$repo" "$branch"

  local slug sha; slug=$(_push_repo_slug "$repo")
  sha=$(git rev-parse --short "refs/heads/${branch}")

  if [[ $dry -eq 1 ]]; then
    ok "dry-run: would push ${branch}@${sha} to ${slug} (gate cleared, author ok)" \
       "$(jq -n --arg t "$ident" --arg b "$branch" --arg s "$sha" --arg r "$slug" \
             '{task:$t,branch:$b,sha:$s,repo:$r,dryRun:true,gate:"cleared",author:"ok"}')"
    return 0
  fi

  # --- Hand off to the root helper: it re-verifies the gate + author scan, mints
  # a token SCOPED to just this repo, pushes the one branch, and discards the
  # token — all as root. The agent process never sees a credential. Parameters go
  # over STDIN (never argv) so the NOPASSWD grant is an exact command path.
  local rc=0
  printf '%s\n' "$ident" "$repopath" "$branch" "$repo" \
    | sudo -n /usr/local/bin/5dive _push_do || rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "$E_GENERIC" \
      "delegated push failed — the task gate is not cleared, the GitHub App credential is not provisioned (${_PUSH_APP_ENV_DEFAULT}), the NOPASSWD grant for '_push_do' is missing, or the push itself failed (see above). See DIVE-1376/1460."
  fi
}

# cmd_push_do — ROOT-ONLY, the atomic gated push (DIVE-1460). Reads four lines on
# STDIN: <ident> <repo-path> <branch> <repo-url>. Re-verifies the human gate and
# the author scan AUTHORITATIVELY (never trusts the caller), mints an installation
# token SCOPED to just the target repo, pushes ONLY the named branch, and discards
# the token. Prints only the result — never the token, never the private key.
# Invoked over NOPASSWD sudo by cmd_push; parameters on stdin keep the grant
# exact-path (sudo-rs safe). Not advertised; not itself audited (the parent
# `push` verb is).
cmd_push_do() {
  [[ "$(id -u)" -eq 0 ]] || fail "$E_PERMISSION" "_push_do is root-only"
  local ident repopath branch repourl
  IFS= read -r ident    || true
  IFS= read -r repopath || true
  IFS= read -r branch   || true
  IFS= read -r repourl  || true
  [[ -n "$ident" && -n "$repopath" && -n "$branch" && -n "$repourl" ]] \
    || fail "$E_USAGE" "_push_do expects <ident> <repo-path> <branch> <repo-url> on stdin (DIVE-1460)."

  # Input hardening — treat branch/url/repo-path as hostile (see below). On
  # success it echoes the canonicalized repo-path (realpath'd); on any violation
  # it `fail`s. Runs BEFORE any of these strings reaches git.
  repopath=$(_push_validate_inputs "$branch" "$repourl" "$repopath")

  # Authoritative gate re-verify — the whole point of the hardening. Read FRESH
  # from the DB by task id (never trust a gate verdict passed over stdin).
  tasks_db_init
  resolve_task_id "$ident"
  local id="$RESOLVED_TASK_ID"; ident="$RESOLVED_TASK_IDENT"
  _push_gate_check "$id" "$ident"

  case "$branch" in
    main|master|HEAD) fail "$E_VALIDATION" "refusing protected branch '${branch}'." ;;
  esac

  local -a G=(git -C "$repopath" -c "safe.directory=$repopath")
  "${G[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "$E_GENERIC" "_push_do: '$repopath' is not a git work tree."
  "${G[@]}" rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null \
    || fail "$E_GENERIC" "_push_do: local branch '${branch}' not found."

  # Authoritative author scan (fail-closed).
  _push_author_scan "$repopath" "$repourl" "$branch"

  # --- credential ---
  local envf="${GITHUB_APP_ENV:-$_PUSH_APP_ENV_DEFAULT}"
  [[ -r "$envf" ]] || fail "$E_GENERIC" "missing GitHub App credential: $envf"
  # shellcheck disable=SC1090
  set -a; . "$envf"; set +a
  local app_id="${GITHUB_APP_ID:-}" inst="${GITHUB_APP_INSTALLATION_ID:-}"
  local pem="${GITHUB_APP_PRIVATE_KEY_FILE:-/etc/5dive/connectors/github-app.pem}"
  [[ -n "$app_id" && -n "$inst" && -r "$pem" ]] || \
    fail "$E_GENERIC" "GitHub App env incomplete (need GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, readable GITHUB_APP_PRIVATE_KEY_FILE)"

  # Build a short-lived App JWT (iat -60s for clock skew, exp +9min < 10min max).
  local now iat exp header payload unsigned sig jwt
  now=$(date +%s); iat=$((now - 60)); exp=$((now + 540))
  b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | b64)
  unsigned="${header}.${payload}"
  sig=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$pem" -binary | b64)
  jwt="${unsigned}.${sig}"

  # Exchange for an installation token SCOPED to just the target repo +
  # contents:write (DIVE-1460 refinement 1) — a captured token can't touch other
  # org repos, and the scoped body caps the permission to the one op we need.
  local reponame body tok
  reponame=$(_push_repo_name "$repourl")
  body=$(jq -cn --arg r "$reponame" '{repositories:[$r],permissions:{contents:"write"}}')
  tok=$(curl -fsS --max-time 15 -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d "$body" \
        "https://api.github.com/app/installations/${inst}/access_tokens" \
        | jq -r '.token // empty')
  [[ -n "$tok" ]] || fail "$E_GENERIC" "installation token exchange failed"

  # Push ONLY the named branch, token via extraheader so it never lands in argv
  # (no leak via ps/audit). Discard the token immediately after.
  local authhdr rc=0
  authhdr="Authorization: Basic $(printf 'x-access-token:%s' "$tok" | base64 -w0)"
  "${G[@]}" -c http."https://github.com/".extraheader="$authhdr" \
      push "$repourl" "refs/heads/${branch}:refs/heads/${branch}" 2>&1 | sed 's/^/  /' || rc=$?
  tok=""; authhdr=""   # discard

  [[ $rc -eq 0 ]] || fail "$E_GENERIC" "push failed (branch ${branch}); see output above."
  local slug sha; slug=$(_push_repo_slug "$repourl")
  sha=$("${G[@]}" rev-parse --short "refs/heads/${branch}")
  ok "pushed ${branch}@${sha} → ${slug} (delegated, repo-scoped token, author=lodar, gate cleared)" \
     "$(jq -n --arg t "$ident" --arg b "$branch" --arg s "$sha" --arg r "$slug" \
           '{task:$t,branch:$b,sha:$s,repo:$r,pushed:true,scoped:true}')"
}
