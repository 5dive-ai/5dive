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
#   - Commit-author enforcement is CONFIG-ONLY: if the deployment configures a
#     committer (GITHUB_APP_COMMIT_AUTHOR in github-app.env), a fail-closed scan
#     requires every pushed commit to match it, so a provider author-gate (e.g.
#     Vercel's) stays green. Unset = no author restriction. No committer identity
#     is baked into this (public) source. The App provides TRANSPORT auth only;
#     it is fully decoupled from commit authorship.
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
readonly _PUSH_DEFAULT_REPO="https://github.com/5dive-ai/5dive.git"

# _push_expected_author — the commit author to enforce, or EMPTY for "no
# restriction". Config-only (DIVE-1461): the value comes from
# GITHUB_APP_COMMIT_AUTHOR (set directly in the environment, or sourced from
# github-app.env by the caller). Deliberately has NO hardcoded default — no
# committer identity lives in this public source; our own on-box env carries it.
_push_expected_author() {
  printf '%s' "${GITHUB_APP_COMMIT_AUTHOR:-}"
}

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

# _push_gate_check <id> <ident> [require-signature] — the ONE cleared-gate
# predicate (DIVE-1376/1460/1496). The task must carry an answered, non-rejected
# gate cleared by either a proven human OR the gate's designated routed reviewer.
# A bare agent answer and every auto-clear provenance are deliberately excluded:
# neither authorizes a git write. The friendly agent-side preflight checks the
# persisted provenance; root `_push_do` passes require-signature=1 and also
# verifies the root-HMAC closure, so raw DB edits cannot forge authorization.
_push_gate_check() {
  local id="$1" ident="$2" require_sig="${3:-0}"
  local gtype ganswer gansweredat gby guid gsig reviewer authorized=0
  gtype=$(db "SELECT COALESCE(need_type,'')          FROM tasks WHERE id=${id};")
  gansweredat=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")
  ganswer=$(db "SELECT COALESCE(need_answer,'')       FROM tasks WHERE id=${id};")
  gby=$(db "SELECT COALESCE(need_answered_by,'')      FROM tasks WHERE id=${id};")
  guid=$(db "SELECT COALESCE(need_answered_uid,'')    FROM tasks WHERE id=${id};")
  gsig=$(db "SELECT COALESCE(need_answer_sig,'')      FROM tasks WHERE id=${id};")
  reviewer=$(db "SELECT COALESCE(routed_reviewer,'')  FROM tasks WHERE id=${id};")
  if [[ -z "$gtype" ]]; then
    fail "$E_VALIDATION" "no gate on ${ident}: file a push-for-review gate first (5dive task need ${ident} --type=approval --ask='approve delegated push for review of branch <b>') — a push-for-review ask files as a lead-routed tier-1 gate the org lead can clear (not a human-only tier-2 in the human's DM), and push runs once a human OR that lead clears it."
  fi
  if [[ -z "$gansweredat" ]]; then
    fail "$E_VALIDATION" "gate on ${ident} is OPEN (unanswered ${gtype}) — push refused until it clears (5dive task answer ${ident} ...)."
  fi
  if printf '%s' "$ganswer" | grep -qiE '^\s*(no|reject|deny|denied|block)'; then
    fail "$E_VALIDATION" "gate on ${ident} was REJECTED ('${ganswer}') — push refused."
  fi
  [[ "$gby" == human:* ]] && authorized=1
  # DIVE-1555: accept ANY lead-clear provenance (`lead:*`), not only one whose
  # routed_reviewer STILL equals the clearer. `lead:X` is stamped ONLY by the
  # sanctioned lead-clear path in `task answer` (cmd_task.sh), which fires only
  # when the caller was `agent-X` AND X was the gate's routed_reviewer at clear
  # time — so the value after `lead:` IS the designated reviewer who cleared it.
  # Requiring routed_reviewer to still match at push time was the bug: routing
  # can be mutated after the clear (a re-route, or the DIVE-1437 T2-escalation
  # NULLs routed_reviewer), stranding a correctly lead-cleared push with an empty
  # `reviewer` and a valid `lead:X` provenance. This is not a weakening: `_push_do`
  # passes require_sig=1, and `need_answered_by` is part of the signed closure
  # (see _gate_closure_verify below), so a raw DB edit forging `lead:X` fails the
  # signature check. (The exact-match line is kept as belt-and-braces.)
  [[ "$gby" == lead:* ]] && authorized=1
  [[ -n "$reviewer" && "$gby" == "lead:${reviewer}" ]] && authorized=1
  if (( ! authorized )); then
    fail "$E_VALIDATION" "gate on ${ident} was cleared by unauthorized provenance '${gby:-unknown}' — delegated push requires a human or a lead-clear (its designated routed reviewer)."
  fi
  if [[ "$require_sig" == "1" ]] \
      && ! _gate_closure_verify "$id" "$gtype" "$ganswer" "$gby" "$gansweredat" "$guid" "$gsig"; then
    fail "$E_VALIDATION" "gate on ${ident} has no valid signed closure — delegated push refused (the authoritative gate record may be unsigned or tampered)."
  fi
}

# _push_task_branch <id> — the branch a task AUTHORITATIVELY declares via a
# "Branch: <name>" line in its body. Empty if the task names none. This is the
# server-side value a cleared gate binds to (DIVE-1462), read fresh from the DB.
_push_task_branch() {
  local id="$1" body
  body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
  _push_branch_from_body "$body"
}

# _push_bind_branch <id> <ident> <branch> — DIVE-1462 (STEER-4). Bind the cleared
# gate to a SPECIFIC branch. A cleared gate authorizes shipping exactly the task
# it sits on, and that task declares its branch (a "Branch: <name>" line in its
# body). Without this, a granted agent could cite ANY cleared-gate task's ident
# but push an arbitrary feature branch — the gate would clear while an unrelated
# branch shipped. So the branch actually being pushed MUST equal the branch the
# task itself declares; anything else is refused. Called by BOTH the cmd_push
# pre-flight (friendly) AND the root-only `_push_do` (authoritative), the same
# belt-and-braces posture as _push_gate_check.
_push_bind_branch() {
  local id="$1" ident="$2" branch="$3" task_branch
  task_branch=$(_push_task_branch "$id")
  if [[ -z "$task_branch" ]]; then
    fail "$E_VALIDATION" "task ${ident} declares no branch — add a 'Branch: <name>' line to its body so the cleared gate binds to a specific branch (delegated push refuses an unbound branch)."
  fi
  if [[ "$branch" != "$task_branch" ]]; then
    fail "$E_VALIDATION" "branch '${branch}' is not the branch bound to ${ident}'s cleared gate ('${task_branch}') — a cleared gate authorizes only its task's own declared branch. Push refused (DIVE-1462)."
  fi
}

# _push_author_scan <repo-path> <repo-url> <branch> <author> — fail-closed author
# scan. If <author> is EMPTY, the deployment configured no committer, so there is
# NO restriction and the scan is a no-op (DIVE-1461 config-only behavior). When
# set, every commit on <branch> not already on the remote's main must match
# <author>, or a provider author-gate would reject the push. Runs in agent
# pre-flight (a friendly early error, when the author is resolvable there) AND
# authoritatively inside `_push_do`. `git -C` + a scoped safe.directory so it also
# works when root operates on the agent's tree.
_push_author_scan() {
  local repopath="$1" repourl="$2" branch="$3" author="$4"
  [[ -n "$author" ]] || return 0   # unset committer -> no author restriction
  local -a G=(git -C "$repopath" -c "safe.directory=$repopath")
  local base rangespec offenders
  "${G[@]}" fetch --quiet "$repourl" main 2>/dev/null || true
  if base=$("${G[@]}" merge-base FETCH_HEAD "refs/heads/${branch}" 2>/dev/null) && [[ -n "$base" ]]; then
    rangespec="${base}..refs/heads/${branch}"
  else
    rangespec="refs/heads/${branch}"   # no shared base (new branch) — scan all
  fi
  offenders=$("${G[@]}" log --format='%H %an <%ae>' "$rangespec" 2>/dev/null \
              | grep -vF " ${author}" || true)
  if [[ -n "$offenders" ]]; then
    printf '%s\n' "$offenders" | sed 's/^/  /' >&2
    fail "$E_VALIDATION" \
      "author check FAILED — the commit(s) above are not authored '${author}' (the configured GITHUB_APP_COMMIT_AUTHOR). Re-author (git rebase --exec 'git commit --amend --author=\"${author}\" --no-edit') before pushing; your git host's author gate would reject them."
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

  # --- BRANCH BINDING pre-flight (DIVE-1462, re-verified authoritatively in
  # _push_do). The cleared gate authorizes only the branch the task itself
  # declares, so a --branch override that disagrees with the task body — or a
  # task that names no branch at all — is refused here with a friendly error.
  _push_bind_branch "$id" "$ident" "$branch"

  # --- repo + work-tree sanity.
  repo="${repo:-$_PUSH_DEFAULT_REPO}"
  local repopath
  repopath=$(git rev-parse --show-toplevel 2>/dev/null) || fail "$E_GENERIC" \
    "run 5dive push from inside the repo work tree (current dir is not a git repo)."
  git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null || fail "$E_GENERIC" \
    "local branch '${branch}' not found — check it out here before pushing."

  # --- AUTHOR SCAN pre-flight (re-verified authoritatively in _push_do). The
  # enforced committer is config-only (GITHUB_APP_COMMIT_AUTHOR). We resolve it
  # here best-effort for a friendly early error: honor a process-env value, else
  # source github-app.env IF we can read it (single-user/admin boxes). On a
  # hardened box the App env is root-only, so the agent can't see it — the author
  # then reads EMPTY here and the scan is a no-op, deferring to the authoritative
  # check inside root's `_push_do` (which sources the env). No false rejections.
  local envf="${GITHUB_APP_ENV:-$_PUSH_APP_ENV_DEFAULT}"
  local author=""
  if [[ -n "${GITHUB_APP_COMMIT_AUTHOR:-}" ]]; then
    author="$GITHUB_APP_COMMIT_AUTHOR"
  elif [[ -r "$envf" ]]; then
    author=$( set -a; . "$envf" 2>/dev/null; set +a; _push_expected_author )
  fi
  _push_author_scan "$repopath" "$repo" "$branch" "$author"

  local slug sha; slug=$(_push_repo_slug "$repo")
  sha=$(git rev-parse --short "refs/heads/${branch}")
  local author_state; [[ -n "$author" ]] && author_state="ok (${author})" || author_state="deferred to push-time (not readable here)"

  if [[ $dry -eq 1 ]]; then
    ok "dry-run: would push ${branch}@${sha} to ${slug} (gate cleared, author ${author_state})" \
       "$(jq -n --arg t "$ident" --arg b "$branch" --arg s "$sha" --arg r "$slug" --arg a "$author_state" \
             '{task:$t,branch:$b,sha:$s,repo:$r,dryRun:true,gate:"cleared",author:$a}')"
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
  _push_gate_check "$id" "$ident" 1

  # Authoritative branch binding (DIVE-1462) — the caller-supplied branch must be
  # the branch the cited task itself declares, so a granted agent can't reuse one
  # task's cleared gate to fast-forward an unrelated branch. Read FRESH from the
  # DB (never trust the branch alone; it's bound to the task, not the caller).
  _push_bind_branch "$id" "$ident" "$branch"

  case "$branch" in
    main|master|HEAD) fail "$E_VALIDATION" "refusing protected branch '${branch}'." ;;
  esac

  local -a G=(git -C "$repopath" -c "safe.directory=$repopath")
  "${G[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "$E_GENERIC" "_push_do: '$repopath' is not a git work tree."
  "${G[@]}" rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null \
    || fail "$E_GENERIC" "_push_do: local branch '${branch}' not found."

  # --- credential ---
  local envf="${GITHUB_APP_ENV:-$_PUSH_APP_ENV_DEFAULT}"
  [[ -r "$envf" ]] || fail "$E_GENERIC" "missing GitHub App credential: $envf"
  # shellcheck disable=SC1090
  set -a; . "$envf"; set +a
  local app_id="${GITHUB_APP_ID:-}" inst="${GITHUB_APP_INSTALLATION_ID:-}"
  local pem="${GITHUB_APP_PRIVATE_KEY_FILE:-/etc/5dive/connectors/github-app.pem}"
  [[ -n "$app_id" && -n "$inst" && -r "$pem" ]] || \
    fail "$E_GENERIC" "GitHub App env incomplete (need GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, readable GITHUB_APP_PRIVATE_KEY_FILE)"

  # Authoritative author scan (fail-closed). The enforced committer is config-only
  # (GITHUB_APP_COMMIT_AUTHOR, just sourced from the App env); empty = no
  # restriction. This is the authoritative gate — the agent pre-flight is only a
  # best-effort preview and may have deferred here.
  local author; author=$(_push_expected_author)
  _push_author_scan "$repopath" "$repourl" "$branch" "$author"

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
  local author_note; [[ -n "$author" ]] && author_note="author enforced" || author_note="no author restriction"
  ok "pushed ${branch}@${sha} → ${slug} (delegated, repo-scoped token, ${author_note}, gate cleared)" \
     "$(jq -n --arg t "$ident" --arg b "$branch" --arg s "$sha" --arg r "$slug" \
           --argjson ae "$([[ -n "$author" ]] && echo true || echo false)" \
           '{task:$t,branch:$b,sha:$s,repo:$r,pushed:true,scoped:true,authorEnforced:$ae}')"
}

# cmd_push_setup — DIVE-1461: bring-your-own-GitHub-App onboarding for delegated
# push. Streamlines the credential drop + verifies the grant so an OSS self-hoster
# can stand up `5dive push` against THEIR OWN GitHub App. It scaffolds the env
# template, checks the private key + env presence/permissions, reports whether the
# root-only `_push_do` NOPASSWD grant is in place, and prints the remaining manual
# steps. It NEVER accepts a secret on argv (nothing lands in shell history): the
# human pastes the .pem file and fills the .env by hand. Root-only (writes under
# /etc/5dive/connectors). See docs/delegated-push.md for the full walkthrough.
# _push_env_set_author <envfile> <author> — upsert a shell-safe
# GITHUB_APP_COMMIT_AUTHOR line (config, not a secret) in the App env file.
_push_env_set_author() {
  local f="$1" a="$2" tmp; tmp=$(mktemp)
  { grep -v '^GITHUB_APP_COMMIT_AUTHOR=' "$f" 2>/dev/null || true; } > "$tmp"
  printf 'GITHUB_APP_COMMIT_AUTHOR=%q\n' "$a" >> "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"; chmod 600 "$f"
}

cmd_push_setup() {
  require_root push setup
  local dir="/etc/5dive/connectors"
  local envf="${dir}/github-app.env" pem="${dir}/github-app.pem"

  # Optional committer to enforce (config-only, DIVE-1461). Accept it on the flag
  # for non-interactive use, else prompt when attached to a terminal. No secret.
  local author_flag="" author_flag_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --author=*) author_flag="${1#*=}"; author_flag_set=1 ;;
      *) : ;;   # setup takes no positional/other flags
    esac
    shift
  done

  local dir_state="present"
  if [[ ! -d "$dir" ]]; then mkdir -p "$dir"; chmod 755 "$dir"; dir_state="created"; fi

  # Scaffold the env template (never overwrite a filled-in one).
  local env_state
  if [[ ! -e "$envf" ]]; then
    ( umask 077; cat > "$envf" <<'ENVT'
# 5dive delegated push — GitHub App credential (DIVE-1376 / DIVE-1461).
# Fill these from YOUR GitHub App: github.com → Settings → Developer settings →
# GitHub Apps → your app. INSTALLATION_ID is in the install URL
# (…/installations/<ID>). Place the App private key alongside this file as
# github-app.pem (root-600). See docs/delegated-push.md.
GITHUB_APP_ID=
GITHUB_APP_INSTALLATION_ID=
GITHUB_APP_PRIVATE_KEY_FILE=/etc/5dive/connectors/github-app.pem
# Optional: enforce a commit author on every pushed commit (set this if your git
# host enforces a committer identity, e.g. a Vercel author gate). Leave blank for
# no restriction. Format: 'Name <email>'.
GITHUB_APP_COMMIT_AUTHOR=
ENVT
    )
    chmod 600 "$envf"; chown root:root "$envf" 2>/dev/null || true
    env_state="scaffolded"
  else
    chmod 600 "$envf" 2>/dev/null || true
    env_state="present"
  fi

  # Resolve/prompt the committer, then persist it if provided.
  local cur_author=""
  [[ -r "$envf" ]] && cur_author=$( . "$envf" 2>/dev/null; printf '%s' "${GITHUB_APP_COMMIT_AUTHOR:-}" )
  if [[ $author_flag_set -eq 1 ]]; then
    _push_env_set_author "$envf" "$author_flag"; cur_author="$author_flag"
  elif [[ -t 0 && ! $JSON_MODE -eq 1 ]]; then
    local prompt_default="${cur_author}"
    printf 'Commit author to enforce on pushed commits (blank = no restriction)%s: ' \
      "${prompt_default:+ [${prompt_default}]}"
    local reply; IFS= read -r reply || reply=""
    if [[ -n "$reply" ]]; then _push_env_set_author "$envf" "$reply"; cur_author="$reply"; fi
  fi

  # Inspect what's configured (read the env in a subshell; never echo the key).
  local app_id="" inst="" env_ok=0
  if [[ -r "$envf" ]]; then
    app_id=$( . "$envf" 2>/dev/null; printf '%s' "${GITHUB_APP_ID:-}" )
    inst=$(   . "$envf" 2>/dev/null; printf '%s' "${GITHUB_APP_INSTALLATION_ID:-}" )
    [[ -n "$app_id" && -n "$inst" ]] && env_ok=1
  fi
  local pem_ok=0; [[ -r "$pem" ]] && pem_ok=1
  # The grant is per standard-agent user (written by `agent create`); admins run
  # NOPASSWD ALL and need no explicit line. Informational, never fatal.
  # `|| true` inside the pipe: grep exits 1 when nothing matches, which would
  # otherwise trip `set -euo pipefail` in this command substitution.
  local grant_n=0
  grant_n=$( { grep -rlsF "/usr/local/bin/5dive _push_do" /etc/sudoers.d/ 2>/dev/null || true; } | wc -l | tr -d ' ')
  local ready=0; [[ $env_ok -eq 1 && $pem_ok -eq 1 ]] && ready=1

  if (( JSON_MODE )); then
    ok "push setup" "$(jq -n \
        --arg dir "$dir" --arg dirst "$dir_state" --arg envst "$env_state" \
        --arg appid "$app_id" --arg inst "$inst" --arg author "$cur_author" \
        --argjson envok $env_ok --argjson pemok $pem_ok \
        --argjson grants "${grant_n:-0}" --argjson ready $ready \
        '{dir:$dir,dirState:$dirst,envState:$envst,appIdSet:($appid|length>0),
          installationIdSet:($inst|length>0),privateKeyPresent:($pemok==1),
          commitAuthor:$author,authorEnforced:($author|length>0),
          grantFiles:$grants,ready:($ready==1)}')"
    return 0
  fi

  echo "5dive delegated push — setup (bring your own GitHub App)"
  echo
  printf '  connector dir : %-38s [%s]\n' "$dir" "$dir_state"
  if [[ $env_ok -eq 1 ]]; then
    printf '  env           : %-38s [configured: app=%s install=%s]\n' "github-app.env" "$app_id" "$inst"
  else
    printf '  env           : %-38s [%s — fill GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID]\n' "github-app.env" "$env_state"
  fi
  if [[ $pem_ok -eq 1 ]]; then
    printf '  private key   : %-38s [present]\n' "github-app.pem"
  else
    printf '  private key   : %-38s [MISSING — drop your App .pem here, chmod 600]\n' "github-app.pem"
  fi
  if [[ -n "$cur_author" ]]; then
    printf '  commit author : %-38s [enforced]\n' "$cur_author"
  else
    printf '  commit author : %-38s [none — any author allowed; set with --author or when prompted]\n' "(unset)"
  fi
  if [[ "${grant_n:-0}" -gt 0 ]]; then
    printf '  fleet grant   : %-38s [present in %s sudoers file(s)]\n' "_push_do NOPASSWD" "$grant_n"
  else
    printf '  fleet grant   : %-38s [none found — admins use NOPASSWD ALL; standard agents get it on `agent create`]\n' "_push_do NOPASSWD"
  fi
  echo
  if [[ $ready -eq 1 ]]; then
    echo "Ready. Try a dry run from inside a repo work tree:"
    echo "  5dive push <task> --branch=<feature-branch> --dry-run"
    if [[ -n "$cur_author" ]]; then
      echo "A real push runs only after the task's ship gate clears, and only pushes commits authored '${cur_author}'."
    else
      echo "A real push runs only after the task's ship gate clears (no commit-author restriction is configured)."
    fi
  else
    echo "Remaining manual steps (a human must do these — no secret is ever passed on the CLI):"
    [[ $pem_ok -ne 1 ]] && echo "  1. Create a GitHub App (contents:write), install it on your ship repos, download its private key → ${pem} (chmod 600)."
    [[ $env_ok -ne 1 ]] && echo "  2. Edit ${envf}: set GITHUB_APP_ID and GITHUB_APP_INSTALLATION_ID."
    echo "  Then re-run: sudo 5dive push setup   (full guide: docs/delegated-push.md)"
  fi
}
