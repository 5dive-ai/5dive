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
  # DIVE-2099 adds a SECOND minting path under the same `lead:` prefix:
  # `lead:standing:X` records the org lead clearing an ENGINEERING approval under
  # their standing authority, with no routing involved (so `reviewer` is legitimately
  # empty there). It is authorized by the generic `lead:*` arm below on purpose —
  # push-for-review on our own repos is in-scope item #1 of that grant — and it is
  # equally signature-bound, since `need_answered_by` is inside the signed closure.
  # Read `lead:standing:X` as "the org lead X, standing authority"; `lead:X` stays
  # "the designated reviewer X".
  # Requiring routed_reviewer to still match at push time was the bug: routing
  # can be mutated after the clear (a re-route, or the DIVE-1437 T2-escalation
  # NULLs routed_reviewer), stranding a correctly lead-cleared push with an empty
  # `reviewer` and a valid `lead:X` provenance. This is not a weakening: `_push_do`
  # passes require_sig=1, and `need_answered_by` is part of the signed closure
  # (see _gate_closure_verify below), so a raw DB edit forging `lead:X` fails the
  # signature check. (The exact-match line is kept as belt-and-braces.)
  [[ "$gby" == lead:* ]] && authorized=1
  [[ -n "$reviewer" && "$gby" == "lead:${reviewer}" ]] && authorized=1
  # DIVE-2004: a `decision` gate cleared by its own designated reviewer could never
  # authorize a push, because `lead:` is minted ONLY for approval|manual|access —
  # so the refusal accused the reviewer who had in fact cleared it. The predicate
  # push actually needs is "was this authorized by the party it was routed to";
  # the stamp is one way to prove that, not the only one. The claim `gby ==
  # reviewer` is NOT sufficient on its own (`task answer --from=<reviewer>` writes
  # it verbatim), so it must be corroborated by the stored `need_answered_uid`,
  # which DIVE-756 stamps from the real pre-sudo invoker and no flag can set.
  local uid_agent=""
  if (( ! authorized )) && [[ "$gtype" == "decision" && -n "$reviewer" && "$gby" == "$reviewer" ]]; then
    uid_agent=$(_gate_agent_for_uid "$guid")
    [[ -n "$uid_agent" && "$uid_agent" == "$reviewer" ]] && authorized=1
  fi
  if (( ! authorized )); then
    # Name the stamp REQUIRED and the one FOUND. A refusal that says "unauthorized
    # provenance" while the designated reviewer is exactly who cleared it sends the
    # reader off to audit the reviewer instead of the gate type (DIVE-1970/2000).
    local detail=""
    if [[ "$gtype" == "decision" && -n "$reviewer" && "$gby" == "$reviewer" ]]; then
      detail=" — '${gby}' IS this gate's routed reviewer, but the recorded invoker uid ${guid:-<none>} maps to '${uid_agent:-no agent}', so the answer cannot be attributed to them. If that is unexpected, the answer was recorded with a --from that did not match who ran it."
    elif [[ -n "$reviewer" ]]; then
      detail=" — required 'human:*', 'lead:${reviewer}', or a decision answered by '${reviewer}' with a matching invoker uid; found '${gby:-unknown}'. A ${gtype:-gate} answered by the lead is only stamped 'lead:' for approval/manual/access."
    else
      detail=" — required 'human:*' or 'lead:*'; found '${gby:-unknown}', and this gate has no routed reviewer to attribute a decision answer to."
    fi
    fail "$E_VALIDATION" "gate on ${ident} was not cleared by an authority delegated push accepts${detail}"
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

# _push_repo_from_worktree <repo-path> — DIVE-1970: the GitHub repo THIS WORK TREE
# actually belongs to, normalized to the https form `_push_validate_inputs`
# accepts. Empty when the tree has no `origin`, or `origin` is not a github.com
# URL (a local path remote in a fixture, a self-hosted forge, a fork remote named
# something else) — the caller then falls back to the constant AND says so.
# Deliberately reads only `origin`: picking among several remotes would be the
# same guess this ticket exists to delete.
_push_repo_from_worktree() {
  local repopath="$1" url slug
  url=$(git -C "$repopath" -c "safe.directory=$repopath" remote get-url origin 2>/dev/null) || return 0
  [[ -n "$url" ]] || return 0
  case "$url" in
    https://github.com/*|git@github.com:*|ssh://git@github.com/*) ;;
    *) return 0 ;;
  esac
  url="${url%.git}"
  slug="${url#*github.com}"; slug="${slug#[:/]}"
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 0
  printf 'https://github.com/%s.git' "$slug"
}

# _push_fetch_why <git-fetch-stderr> — a SHORT named cause for a failed fetch, so
# a missing range bound says WHY it is missing (DIVE-2161). The default arm
# echoes git's own last line rather than paraphrasing: the remote usually already
# said the true thing, and reaching for the nearest familiar cause is how a wrong
# one gets named (DIVE-2143).
_push_fetch_why() {
  local err="$1"
  case "$err" in
    *"could not read Username"*|*"Authentication failed"*|*"terminal prompts disabled"*)
      printf 'no git credential is available to this user for that repo' ;;
    *FETCH_HEAD*|*"Permission denied"*|*"unable to create"*|*"Unable to create"*|*"cannot open"*)
      printf "this user cannot write .git/ in that work tree — a root-owned FETCH_HEAD left by an earlier root-run fetch is the known cause; 'sudo chgrp -R claude <repo>/.git && sudo chmod -R g+w <repo>/.git' clears it" ;;
    *"Could not resolve host"*|*"Connection timed out"*|*"unable to access"*)
      printf 'the remote was not reachable from here' ;;
    *"Repository not found"*|*"does not appear to be a git repository"*|*"not found"*)
      printf 'that repository was not found, or is not visible to this user' ;;
    "") printf 'git fetch failed without printing a reason' ;;
    *) printf 'git said: %s' "$(printf '%s' "$err" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-200)" ;;
  esac
}

# _push_author_scan <repo-path> <repo-url> <branch> <author> [repo-source] [mode] — fail-closed author
# scan. If <author> is EMPTY, the deployment configured no committer, so there is
# NO restriction and the scan is a no-op (DIVE-1461 config-only behavior). When
# set, every commit on <branch> not already on the remote's main must match
# <author>, or a provider author-gate would reject the push. Runs in agent
# pre-flight (a friendly early error, when the author is resolvable there) AND
# authoritatively inside `_push_do`. `git -C` + a scoped safe.directory so it also
# works when root operates on the agent's tree.
#
# DIVE-2161: THE RANGE BOUND IS ITSELF A MEASUREMENT, AND IT CAN BE UNAVAILABLE.
# The old code discarded the fetch's exit status and its stderr, so "I cannot tell
# which commits this branch adds" silently became "scan the branch's ENTIRE
# history" — and every pre-policy commit in it was then reported as an author
# violation. dev2 got hundreds of phantom offenders for a one-commit branch that
# was correctly authored. Could-not-measure must never render as a measurement:
# resolve the bound, degrade to a CACHED bound and SAY it may be stale, or refuse
# and name what is missing. Never widen the range and grade against it.
#
# <mode> picks who the refusal belongs to:
#   authoritative (default) — root's `_push_do`, which fetches with the App
#     credential. No bound here is an anomaly: refuse rather than guess.
#   preflight — the agent's advisory pre-check. A delegated pusher legitimately
#     has NO GitHub credential (by design), so no bound is a NORMAL state: SKIP
#     with the reason and let the authoritative pass enforce. The predicate is the
#     condition itself, so a tree that regains a bound is re-armed automatically.
# Sets _PUSH_AUTHOR_SCAN_BOUND to fresh|unrelated|cached|unavailable so the caller
# can report which bound (if any) the verdict actually rests on.
_push_author_scan() {
  local repopath="$1" repourl="$2" branch="$3" author="$4" repo_src="${5:-}" mode="${6:-authoritative}"
  _PUSH_AUTHOR_SCAN_BOUND=unavailable
  [[ -n "$author" ]] || { _PUSH_AUTHOR_SCAN_BOUND=nocheck; return 0; }  # unset committer -> no author restriction
  local -a G=(git -C "$repopath" -c "safe.directory=$repopath")
  local base="" rangespec="" offenders scope="" fetch_err="" fetch_ok=0
  # A fresh fetch is the only authoritative bound. Keep its stderr — WHY it failed
  # is the diagnosis, and throwing it away is what left the tool with nothing to
  # say but a fabricated list. GIT_TERMINAL_PROMPT=0 so a credential-less caller
  # ERRORS with a readable reason instead of blocking on a username prompt.
  if fetch_err=$(GIT_TERMINAL_PROMPT=0 "${G[@]}" fetch --quiet "$repourl" main 2>&1) \
     && "${G[@]}" rev-parse --verify --quiet FETCH_HEAD >/dev/null 2>&1; then
    fetch_ok=1
    base=$("${G[@]}" merge-base FETCH_HEAD "refs/heads/${branch}" 2>/dev/null) || base=""
  fi
  if [[ $fetch_ok -eq 1 && -n "$base" ]]; then
    _PUSH_AUTHOR_SCAN_BOUND=fresh
    rangespec="${base}..refs/heads/${branch}"
    scope="the commits on '${branch}' not already on that repo's main"
  elif [[ $fetch_ok -eq 1 ]]; then
    # MEASURED, not assumed: main was fetched and shares no ancestor with this
    # branch, so every commit reachable from it really is new to that repo. This
    # is the one case where the whole branch is the honest range.
    _PUSH_AUTHOR_SCAN_BOUND=unrelated
    rangespec="refs/heads/${branch}"
    scope="EVERY commit reachable from '${branch}' — a FRESH fetch of that repo's main succeeded and shares NO common ancestor with this branch, so all of them are new to it"
  else
    # No fresh bound. Degrade to a CACHED remote-tracking main if the tree has
    # one, and say out loud that the bound may be stale; otherwise the bound is
    # simply unavailable and there is nothing honest to grade.
    local cref why; why=$(_push_fetch_why "$fetch_err")
    for cref in refs/remotes/origin/main refs/remotes/origin/master; do
      "${G[@]}" rev-parse --verify --quiet "$cref" >/dev/null 2>&1 || continue
      base=$("${G[@]}" merge-base "$cref" "refs/heads/${branch}" 2>/dev/null) || base=""
      [[ -n "$base" ]] && break
    done
    if [[ -n "$base" ]]; then
      _PUSH_AUTHOR_SCAN_BOUND=cached
      rangespec="${base}..refs/heads/${branch}"
      scope="the commits on '${branch}' not already on the CACHED ${cref} — that bound MAY BE STALE, because a fresh fetch was not possible (${why})"
      warn "author check: could not fetch ${repourl} (${why}) — bounding the scan with the cached ${cref} instead. If that ref is out of date this range can be too wide or too narrow; only a fresh fetch bounds it authoritatively. (DIVE-2161)"
    else
      # CANNOT MEASURE. Printing a list here would be a fabrication: the only
      # scannable range left is the branch's entire history, which reports every
      # pre-policy commit in it as a violation. Say what is missing instead.
      local diag="the author check could not determine WHICH commits '${branch}' adds to $(_push_repo_slug "$repourl") — fetching that repo's main failed (${why}) and this work tree has no cached refs/remotes/origin/main to fall back on. Without a bound the only scannable range is the branch's ENTIRE history, which would report every pre-policy commit in it as an author violation; that is a fabricated result, so it is not produced."
      [[ "$mode" == preflight ]] && { warn "author check SKIPPED here — ${diag} It is re-run authoritatively inside the push as root, which fetches with the App credential. (DIVE-2161)"; return 0; }
      fail "$E_GENERIC" "author check COULD NOT RUN — ${diag} Restore the bound and retry: give this tree a fetchable origin/main ('git remote add origin <url> && git fetch origin main'), or clear whatever blocked the fetch (see the reason above). (DIVE-2161)"
    fi
  fi
  offenders=$("${G[@]}" log --format='%H %an <%ae>' "$rangespec" 2>/dev/null \
              | grep -vF " ${author}" || true)
  if [[ -n "$offenders" ]]; then
    printf '%s\n' "$offenders" | sed 's/^/  /' >&2
    # DIVE-1970: the message must name the repo it checked AGAINST and where that
    # target came from. Without it a wrong-repo run reads as "my commits are bad"
    # and the maker goes off rewriting authorship on a clean branch.
    local against; against=$(_push_repo_slug "$repourl")
    [[ -n "$repo_src" ]] && against="${against} (target resolved from ${repo_src})"
    # DIVE-2051: `agent create` seeds every agent user a synthetic
    # agent-<name>@agents.noreply.5dive.ai identity, so no personal address can
    # be inferred into a commit. Correct, and it means an agent committing in a
    # repo with an author policy lands HERE. Hand it the fix instead of a wall —
    # the mitigation must not live as tribal knowledge (main's call).
    local seeded_hint=""
    if printf '%s\n' "$offenders" | grep -q '@agents\.noreply\.5dive\.ai>'; then
      local a_name a_email; a_name="${author%% <*}"; a_email="${author##*<}"; a_email="${a_email%>}"
      seeded_hint=" NOTE: the address above is the SYNTHETIC identity 5dive provisioning gives an agent user (DIVE-2051) — deliberate, not a mistake, but not an author this repo accepts. Set the repo-local author once in the checkout you commit from, then re-author:  git -C <your checkout> config user.name '${a_name}' && git -C <your checkout> config user.email '${a_email}'"
    fi
    fail "$E_VALIDATION" \
      "author check FAILED against ${against} — scanned ${scope}. The commit(s) above are not authored '${author}' (the configured GITHUB_APP_COMMIT_AUTHOR). If you do not recognise them, check the TARGET REPO first: a push aimed at the wrong repository lists that repository's unrelated history here. Otherwise re-author (git rebase --exec 'git commit --amend --author=\"${author}\" --no-edit') before pushing; your git host's author gate would reject them.${seeded_hint}"
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

  # --- repo + work-tree sanity. DIVE-1970: resolve the WORK TREE FIRST, then pick
  # the target FROM it. The old order applied the CLI-repo constant before the
  # tree was even resolved and never consulted the tree at all, so a push from a
  # 5dive-frontend tree silently targeted the CLI repo — and then reported an
  # AUTHOR failure, listing that repo's unrelated history, rather than naming the
  # wrong-repo cause. Precedence, most explicit first:
  #   --repo=<url>  >  this work tree's own `origin`  >  the built-in constant.
  local repopath
  repopath=$(git rev-parse --show-toplevel 2>/dev/null) || fail "$E_GENERIC" \
    "run 5dive push from inside the repo work tree (current dir is not a git repo)."
  local repo_src wt_repo
  wt_repo=$(_push_repo_from_worktree "$repopath")
  if [[ -n "$repo" ]]; then
    repo_src="--repo"
    # An explicit flag still wins, but a flag that disagrees with the tree you are
    # standing in is the exact confusion this ticket is about — say it out loud.
    if [[ -n "$wt_repo" && "$(_push_repo_slug "$wt_repo")" != "$(_push_repo_slug "$repo")" ]]; then
      warn "--repo targets $(_push_repo_slug "$repo") but this work tree's origin is $(_push_repo_slug "$wt_repo") — pushing '${branch}' across repos."
    fi
  elif [[ -n "$wt_repo" ]]; then
    repo="$wt_repo"; repo_src="this work tree's origin"
  else
    repo="$_PUSH_DEFAULT_REPO"; repo_src="the built-in default (this work tree has no github.com 'origin')"
    warn "this work tree has no github.com 'origin' remote — falling back to $(_push_repo_slug "$_PUSH_DEFAULT_REPO"). Pass --repo=<url> if that is not the target."
  fi
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
  # DIVE-2161: `preflight` — an agent delegated a push legitimately has no GitHub
  # credential, so "cannot bound the range" is normal HERE and skips with a
  # reason; root's authoritative pass refuses instead of guessing.
  _push_author_scan "$repopath" "$repo" "$branch" "$author" "$repo_src" preflight

  local slug sha; slug=$(_push_repo_slug "$repo")
  sha=$(git rev-parse --short "refs/heads/${branch}")
  # DIVE-2161: the reported state must name the bound the verdict rests on. A flat
  # "ok" over a skipped or cached-bound scan is the same could-not-measure-as-
  # measurement this ticket is about, one line further downstream.
  local author_state
  if [[ -z "$author" ]]; then
    author_state="deferred to push-time (not readable here)"
  else
    case "${_PUSH_AUTHOR_SCAN_BOUND:-}" in
      unavailable) author_state="NOT CHECKED here — range bound unavailable; enforced at push time" ;;
      cached)      author_state="ok against a CACHED bound, may be stale (${author})" ;;
      *)           author_state="ok (${author})" ;;
    esac
  fi

  if [[ $dry -eq 1 ]]; then
    # DIVE-1970: the dry-run names WHERE the target came from, not just what it
    # is — "5dive-ai/5dive" alone looks equally right whether it was resolved or
    # merely defaulted to, which is why --dry-run did not catch the wrong-repo bug.
    ok "dry-run: would push ${branch}@${sha} to ${slug} — target from ${repo_src} (gate cleared, author ${author_state})" \
       "$(jq -n --arg t "$ident" --arg b "$branch" --arg s "$sha" --arg r "$slug" --arg a "$author_state" --arg rs "$repo_src" \
             '{task:$t,branch:$b,sha:$s,repo:$r,repoSource:$rs,dryRun:true,gate:"cleared",author:$a}')"
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
# _push_record_ship_ledger <repopath> <branch> <ident> <slug> — DIVE-1923.
#
# Record what this push actually shipped, and which of those commits UNDO a
# previous ship. `5dive push` is the fleet's shipping rail, so it is the one
# place that observes a ship at the moment it happens — and a revert announces
# itself in a line git writes itself ("This reverts commit <sha>."), so the
# rollback half of the metric demands no new discipline from any agent. That
# matters: DIVE-1935's lesson was that the signal we needed was already sitting
# in plain text, and a capture path nobody has to remember is the only kind that
# stays true.
#
# Ships are recorded BEFORE rollbacks, in two passes, on purpose. `rev-list` is
# newest-first, and a branch can carry both a commit and its revert; recording
# in that order would look up the reverted sha before its ship row existed and
# mark a provable self-revert as unattributable.
#
# With no local main/master to fork from we record the TIP ONLY rather than
# walking the branch's whole history: inventing ship rows for commits this push
# did not ship would inflate the denominator, and an under-counted rate that
# names its own instrument is honest where an invented one is not.
#
# Wholly best-effort — every failure path is silent and non-fatal. The push has
# already succeeded by the time this runs, and telemetry must never turn a
# landed ship into an error.
_push_record_ship_ledger() {
  local repopath="$1" branch="$2" ident="$3" slug="$4"
  local -a G=(git -C "$repopath" -c "safe.directory=$repopath")
  local base="" ref range="" c rv
  for ref in refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master; do
    "${G[@]}" rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
    base=$("${G[@]}" merge-base "$ref" "refs/heads/${branch}" 2>/dev/null) || base=""
    [[ -n "$base" ]] && break
  done
  if [[ -n "$base" ]]; then range="${base}..refs/heads/${branch}"; else range="-n 1 refs/heads/${branch}"; fi

  local -a shas=()
  while IFS= read -r c; do [[ -n "$c" ]] && shas+=("$c"); done     < <("${G[@]}" rev-list --no-merges --max-count=500 $range 2>/dev/null || true)
  [[ ${#shas[@]} -gt 0 ]] || return 0

  for c in "${shas[@]}"; do
    ship_ledger_record ship "$ident" "$slug" "$branch" "$c" ""
  done
  for c in "${shas[@]}"; do
    rv=$("${G[@]}" show -s --format=%B "$c" 2>/dev/null \
         | sed -n 's/^[[:space:]]*This reverts commit \([0-9a-f]\{7,40\}\)\.\{0,1\}[[:space:]]*$/\1/p' | head -1)
    [[ -n "$rv" ]] && ship_ledger_record rollback "$ident" "$slug" "$branch" "$c" "$rv"
  done
  return 0
}

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
  # DIVE-2161: `authoritative` — this pass runs as root and is the one that
  # decides. If it cannot bound the range it REFUSES and names what is missing;
  # it never substitutes the whole history and grades against it.
  _push_author_scan "$repopath" "$repourl" "$branch" "$author" "the caller's resolved target" authoritative

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
  # DIVE-1923: ship ledger. After the push, never before — this records what
  # landed, so a failed push must leave no trace. Never fatal.
  _push_record_ship_ledger "$repopath" "$branch" "$ident" "$slug" 2>/dev/null || true
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
