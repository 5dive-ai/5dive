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
#
# DIVE-3081: strips a markdown/quote wrapper via broker_strip_md_quotes, and MUST
# keep doing so in lockstep with broker_task_target's use of the same helper — the
# DIVE-1462 refusal compares this function's value against the broker's, so a
# strip applied to only one side still refuses, just with a different pair of
# look-alike names. Same reason the helper is shared rather than inlined.
_push_branch_from_body() {
  local raw
  # `|| true` so a no-match grep can't trip `set -euo pipefail` when this runs
  # inside a command substitution (branch=$(...)).
  raw=$(printf '%s\n' "$1" | grep -ioP '^\s*branch:\s*\K\S+' | head -1 || true)
  broker_strip_md_quotes "$raw"
}

# _push_repo_slug <url> — OWNER/REPO from an https/ssh github URL, no .git.
_push_repo_slug() {
  printf '%s' "$1" | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##'
}

# _push_repo_name <url> — bare repo name (no owner, no .git), for token scoping.
_push_repo_name() {
  local n="${1##*/}"; printf '%s' "${n%.git}"
}

# _push_gate_check <id> <ident> [require-signature] — push's binding of the
# broker's ONE cleared-gate predicate. INST-5 moved the logic VERBATIM to
# broker_gate_check (src/lib/broker.sh) so a second surface could not fork it;
# the `push` surface row supplies exactly the nouns this function used to
# hardcode, so every refusal string is byte-identical to the pre-INST-5 copy
# (asserted against origin/main's text in tests/broker_surface_unit.sh).
_push_gate_check() {
  broker_gate_check push "$@"
}

# _push_task_branch <id> — the branch a task AUTHORITATIVELY declares via a
# "Branch: <name>" line in its body. Empty if the task names none. This is the
# server-side value a cleared gate binds to (DIVE-1462), read fresh from the DB.
# INST-5: now the broker's generic body-key read; `Branch` is push's surface key.
_push_task_branch() {
  broker_task_target push "$1"
}

# _push_bind_branch <id> <ident> <branch> — DIVE-1462 (STEER-4), now push's
# binding of the broker's generic target binding (INST-5). A cleared gate
# authorizes shipping exactly the task it sits on, and that task declares its
# branch, so the branch actually being pushed MUST equal the branch the task
# itself declares. Same belt-and-braces posture as before: called by BOTH the
# cmd_push pre-flight (friendly) AND the root-only `_push_do` (authoritative).
_push_bind_branch() {
  broker_bind_target push "$1" "$2" "$3"
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
    # DIVE-2566: these three used to share ONE string — 'no git credential is
    # available to this user for that repo'. They are different faults and the
    # collapsed wording sent a builder after the wrong one: on DIVE-1560 it read
    # as a missing sudo grant for an hour, when the real cause was a GitHub App
    # with no installation on the target account. A cause list is not a cause.
    #
    # ASKED-AND-COULD-NOT-ASK: git wanted to PROMPT, and prompting is disabled.
    # Nothing was presented, so nothing was rejected.
    *"could not read Username"*|*"terminal prompts disabled"*)
      printf 'this user has no git credential helper for that repo, so git fell back to prompting and prompts are disabled here' ;;
    # PRESENTED-AND-REJECTED: a credential existed and the remote turned it down.
    # The opposite diagnosis from the arm above, and the fix is different too.
    *"Authentication failed"*)
      printf 'a git credential WAS presented and the remote REJECTED it — this is a wrong/expired credential, not a missing one' ;;
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

# Does <branch> change anything under .github/workflows/ relative to the
# remote's default branch? Decides whether the delegated-push token needs
# workflows:write on top of contents:write (gh#250).
# Echoes "yes" | "no" | "unknown" — unknown when no range can be computed.
_push_touches_workflows() { # <repopath> <repourl> <branch>
  local repopath="$1" repourl="$2" branch="$3" b base="" files
  local -a g=(git -C "$repopath" -c "safe.directory=$repopath")
  for b in main master; do
    if "${g[@]}" fetch --quiet "$repourl" "$b" 2>/dev/null; then base="FETCH_HEAD"; break; fi
  done
  # DIVE-2547: that fetch is UNAUTHENTICATED — it hands git a bare $repourl with no
  # credential — so against a PRIVATE repo it can never succeed. The old code then
  # returned "unknown" and the caller requested workflows:write defensively, on
  # EVERY push to every private repo, forever. That is a permanently over-scoped
  # token minted by a probe that never once measured anything, which is the exact
  # inversion of what DIVE-1460's one-permission scope is for. Measured 2026-08-03:
  # it blocked dev on lodar/5dive-api (DIVE-1999) and dev2 on the same repo
  # (DIVE-2033), and the escalated request 422s because the App is not granted
  # workflows:write — so the defensive branch does not even degrade gracefully, it
  # fails the push outright after the human already cleared the gate.
  #
  # Degrade to the CACHED remote-tracking ref instead, exactly as the author scan
  # one function over already does (DIVE-2161: "resolve the bound, degrade to a
  # CACHED bound and SAY it may be stale, or refuse and name what is missing").
  # The same lesson was learned here and never applied.
  #
  # A stale cached base is SAFE IN THE DIRECTION THAT MATTERS: base...branch shows
  # what the branch adds relative to base, so an older base widens the range and can
  # only report MORE files. It can therefore turn a "no" into a "yes" (request the
  # scope we did not need) but never a "yes" into a "no" (push a workflow change
  # under contents:write alone). Only when neither a live nor a cached bound exists
  # is the answer genuinely unknown.
  if [[ -z "$base" ]]; then
    for b in main master; do
      if "${g[@]}" rev-parse --verify --quiet "refs/remotes/origin/${b}" >/dev/null 2>&1; then
        base="refs/remotes/origin/${b}"
        echo "[5dive] could not fetch the remote default branch (unauthenticated probe); diffing '${branch}' against the cached ${base}, which may be stale — a stale base can only over-report touched files, never under-report them" >&2
        break
      fi
    done
  fi
  [[ -n "$base" ]] || { echo "unknown"; return; }
  files=$("${g[@]}" diff --name-only "${base}...refs/heads/${branch}" 2>/dev/null)     || { echo "unknown"; return; }
  if grep -qE '^\.github/workflows/' <<<"$files"; then echo "yes"; else echo "no"; fi
}

cmd_push() {
  require_loaded push broker_gate_check broker_bind_target broker_task_target broker_gate_sig_note
  tasks_db_init
  local branch="" repo="" dry=0 yes=0
  # DIVE-2605: --open-pr and its two body sources. Parsed here, validated before the
  # push so a bad --pr-body-file cannot cost you a push you then cannot follow up.
  local open_pr=0 pr_base="" pr_title="" pr_body_file="" pr_draft=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch=*) branch="${1#*=}" ;;
      --repo=*)   repo="${1#*=}" ;;
      --dry-run)  dry=1 ;;
      --yes|-y)   yes=1 ;;
      --open-pr)      open_pr=1 ;;
      --open-pr=*)    open_pr=1; pr_base="${1#*=}" ;;
      --pr-title=*)   pr_title="${1#*=}" ;;
      --pr-body-file=*) pr_body_file="${1#*=}" ;;
      --pr-draft)     pr_draft=1 ;;
      --) shift; positional+=("$@"); break ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" \
    "usage: 5dive push <id|DIVE-N> [--branch=<b>] [--repo=<url>] [--dry-run] [--open-pr[=<base>]] [--pr-title=<t>] [--pr-body-file=<f>] [--pr-draft]"
  # A PR flag without --open-pr is silently inert otherwise, and a silently inert
  # flag on a verb you run once per branch is a body you think you attached.
  if [[ $open_pr -eq 0 ]]; then
    [[ -n "$pr_title" || -n "$pr_body_file" || $pr_draft -eq 1 ]] && fail "$E_USAGE" \
      "--pr-title/--pr-body-file/--pr-draft do nothing without --open-pr; add --open-pr or drop them."
  fi
  if [[ -n "$pr_body_file" ]]; then
    [[ -r "$pr_body_file" ]] || fail "$E_USAGE" "--pr-body-file: '${pr_body_file}' is not readable."
  fi

  resolve_task_id "${positional[0]}"
  local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"

  # --- branch: --branch wins, else a "Branch: <name>" line in the task body.
  if [[ -z "$branch" ]]; then
    local body; body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
    branch=$(_push_branch_from_body "$body")
  fi
  # DIVE-2801: name BOTH requirements. `--branch` satisfies this usage check but
  # NOT the DIVE-1462 gate binding in _push_do, which reads the branch fresh from
  # the task body — so offering `--branch` alone as an alternative sends the
  # caller down a path whose only outcome is the next refusal. Same defect as the
  # dry-run this row is named for: an early check answering on behalf of a later
  # one it does not share a predicate with.
  [[ -n "$branch" ]] || fail "$E_USAGE" \
    "no branch for ${ident}: add a 'Branch: <name>' line to the task body (push refuses to guess). The task body is REQUIRED — the cleared gate binds to the branch the task itself declares (DIVE-1462), so --branch=<name> alone gets past this check and is then refused by that binding; pass it as well only to override which branch is read."
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
    # DIVE-2605: --open-pr is part of what the dry run is previewing, and a dry run
    # that stays silent about it reads as "this flag was ignored".
    local pr_preview="" pr_base_preview="${pr_base:-${FIVE_GATE_MAIN_BRANCH:-main}}"
    if [[ $open_pr -eq 1 ]]; then
      if sudo -n -l /usr/local/bin/5dive _gh_do >/dev/null 2>&1; then
        pr_preview=" then open a PR ${branch} -> ${pr_base_preview} as 5dive-bot"
      else
        pr_preview=" — but NOT open a PR: this account has no '_gh_do' grant, so --open-pr would warn and leave the branch for someone else to open"
      fi
    fi
    # DIVE-2801: the rehearsal names the check it did NOT run. `gate cleared` alone
    # asserted the whole gate predicate while having evaluated the weaker half of it
    # — the preflight runs with require_sig=0, the real push with 1 — so a green here
    # generalised, in the reader's head, to the check most likely to stop the write.
    # Same shape as `author_state` above (DIVE-2161): name the bound the verdict rests on.
    local sig_state; sig_state=$(broker_gate_sig_note push)
    ok "dry-run: would push ${branch}@${sha} to ${slug}${pr_preview} — target from ${repo_src} (gate cleared, ${sig_state}, author ${author_state})" \
       "$(jq -n --arg t "$ident" --arg b "$branch" --arg s "$sha" --arg r "$slug" --arg a "$author_state" --arg rs "$repo_src" \
             --argjson op "$open_pr" --arg pb "$pr_base_preview" --arg gs "${BROKER_GATE_SIG_STATE:-unknown}" \
             '{task:$t,branch:$b,sha:$s,repo:$r,repoSource:$rs,dryRun:true,gate:"cleared",gateSignature:$gs,author:$a,openPr:($op==1),prBase:$pb}')"
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

  # DIVE-2605: the branch is up; open the PR on the SAME rail rather than messaging
  # an agent that holds a credential. Deliberately AFTER the push and never fatal to
  # it — a failed PR open leaves a pushed branch anyone can open a PR from by hand,
  # while making it fatal would turn a successful push into a red exit and invite a
  # re-push. The push is the irreversible half; the PR is the recoverable one.
  if [[ $open_pr -eq 1 ]]; then
    _push_open_pr "$ident" "$slug" "$branch" "$pr_base" "$pr_title" "$pr_body_file" "$pr_draft" \
      || warn "the branch pushed but the pull request was not opened (see above) — re-run just the PR with: 5dive gh pr create --repo ${slug} --head ${branch}"
  fi
}

# _push_open_pr <ident> <slug> <branch> <base> <title> <body-file> <draft>
# DIVE-2605, blockage #1. A builder holds no gh credential of any kind, so after
# `5dive push` puts the branch up they have historically messaged main with a
# prepared PR body for main to paste — two round-trips of agent-to-agent messaging
# and one agent's attention, for a step that carries no judgement. Five such proxied
# closes landed in one day (measured by main, 2026-08-03).
#
# The rail this uses is not new and no credential moves: `gh pr create` is class
# `write` in DIVE-2448's routing map, so it already goes out as 5dive-bot through the
# root-only `_gh_do`, which reads the PAT root-side and execs gh with it. Measured
# 2026-08-04 from agent-dev2 (standard isolation, `ALL=(root) NOPASSWD:
# /usr/local/bin/5dive *`): the rail answers, and the bot holds `push:true` on
# 5dive-ai/5dive, which is the permission `pr create` needs. So this verb adds a
# CALL, not a capability — the same posture as _push_do, one API call further on.
#
# The body travels over STDIN with the rest of the argv, NUL-separated, so a
# multi-paragraph PR body never lands in the process table. That is strictly better
# than the `gh pr create --body "$(cat f)"` a human would type.
_push_open_pr() {
  local ident="$1" slug="$2" branch="$3" base="$4" title="$5" body_file="$6" draft="$7"
  local body="" url

  [[ -n "$base" ]] || base="${FIVE_GATE_MAIN_BRANCH:-main}"
  if [[ -z "$title" ]]; then
    local t; t=$(db "SELECT COALESCE(title,'') FROM tasks WHERE ident=$(sqlq "$ident");" 2>/dev/null || true)
    # The task title is the honest default, but it is prose written for a board and
    # can run long; a PR title is a subject line. Truncate rather than refuse, and
    # keep the ident so the merge gate's own ident-match evidence still binds.
    [[ ${#t} -gt 80 ]] && t="${t:0:77}..."
    title="${ident}: ${t:-delegated push}"
  fi
  if [[ -n "$body_file" ]]; then
    body=$(cat "$body_file")
  else
    body="Delivers ${ident}."$'\n\n'"Opened by \`5dive push --open-pr\` (DIVE-2605): the branch and this pull request went out on the same root-side rail, as 5dive-bot. The authoring agent holds no GitHub credential."
  fi

  local -a args=(pr create --repo "$slug" --head "$branch" --base "$base"
                 --title "$title" --body "$body")
  [[ "$draft" == "1" ]] && args+=(--draft)

  # Same handoff as the push: NUL-separated over stdin, exact command path, and
  # `_gh_do` re-derives the routing class as root rather than trusting this caller.
  # stderr is CAPTURED rather than passed through because one specific failure has
  # to be read, not just relayed — see the already-exists arm below.
  local rc=0 out
  out=$(printf '%s\0' "${args[@]}" | sudo -n /usr/local/bin/5dive _gh_do 2>&1) || rc=$?
  url="$out"

  # ALREADY EXISTS IS THE DESIRED END STATE, not a failure. `--open-pr` means "make
  # sure this branch has a pull request", and re-running a push (a second commit on
  # the same branch, a retry after a red) hits this every time. Reporting it as a
  # failure and then advising `5dive gh pr create` — the exact command that just
  # refused — is advice that is wrong in the most likely failure mode there is.
  # gh names the existing PR and its URL in that message; surface those.
  if [[ $rc -ne 0 && "$out" == *"already exists"* ]]; then
    local existing; existing=$(printf '%s' "$out" | grep -oE 'https://github\.com/[^ ]+/pull/[0-9]+' | head -1) || existing=""
    ok "${ident} already has a pull request (${existing:-see above}) for ${branch} -> ${base} in ${slug} — branch pushed, nothing more to open" \
       "$(jq -n --arg t "$ident" --arg u "${existing:-}" --arg b "$branch" --arg base "$base" --arg r "$slug" \
             '{task:$t,pr:$u,branch:$b,base:$base,repo:$r,actor:"5dive-bot",created:false}')"
    return 0
  fi
  if [[ $rc -ne 0 ]]; then
    printf '%s\n' "$out" >&2
    # Distinguish "you may not route" from "the routed call failed" — sudo exits 1
    # for a missing grant and gh exits 1 for its own errors, so rc alone cannot tell
    # them apart. Ask sudo directly, and only after a failure.
    if ! sudo -n -l /usr/local/bin/5dive _gh_do >/dev/null 2>&1; then
      warn "opening the PR needs the NOPASSWD grant for '/usr/local/bin/5dive _gh_do', which this account does not have — so nothing ran and this says NOTHING about the PR itself. A builder gets the grant with 'agent create --can-push'."
    fi
    return 1
  fi
  url="${url##*$'\n'}"
  ok "opened ${url:-the pull request} for ${ident} (${branch} -> ${base} in ${slug}, as 5dive-bot)" \
     "$(jq -n --arg t "$ident" --arg u "$url" --arg b "$branch" --arg base "$base" --arg r "$slug" \
           '{task:$t,pr:$u,branch:$b,base:$base,repo:$r,actor:"5dive-bot"}')"
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
  require_loaded push broker_gate_check broker_bind_target broker_task_target
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
  local reponame body tok slug
  reponame=$(_push_repo_name "$repourl")
  # owner/repo, needed by the DIVE-2563 installation lookup below. Declared here
  # rather than at the summary line further down, which ran AFTER the mint.
  slug=$(_push_repo_slug "$repourl")
  # gh#250: contents:write alone CANNOT push .github/workflows/* — GitHub
  # refuses the push outright, and the error names the App's permissions rather
  # than this token's, so the operator chases the wrong thing. Ask for
  # workflows:write only when the branch actually touches a workflow file, so
  # the ordinary push keeps the one-permission scope DIVE-1460 intended.
  #
  # 'unknown' (no remote default branch reachable, so no range to diff) includes
  # the permission and says so: match the insurance to the recoverability — a
  # slightly over-scoped token for one gated push is bounded and visible, a push
  # that fails after the human already cleared the gate is not.
  local _wf; _wf=$(_push_touches_workflows "$repopath" "$repourl" "$branch")
  if [[ "$_wf" == "no" ]]; then
    body=$(jq -cn --arg r "$reponame" '{repositories:[$r],permissions:{contents:"write"}}')
  else
    [[ "$_wf" == "unknown" ]] \
      && echo "[5dive] cannot diff ${branch} against the remote default branch — requesting workflows:write defensively" >&2
    body=$(jq -cn --arg r "$reponame" '{repositories:[$r],permissions:{contents:"write",workflows:"write"}}')
  fi
  # DIVE-2563: RESOLVE THE INSTALLATION FOR THIS REPO'S OWNER, don't mint against a
  # single pinned id. GITHUB_APP_INSTALLATION_ID is one number in one env file, so
  # every push on this box minted against whichever account was installed first.
  # A GitHub App gets a SEPARATE installation per account it is installed on, and
  # the token exchange refuses any repository outside the installation it is
  # addressed to — with a message that names the repository rather than the
  # installation ("There is at least one repository that does not exist or is not
  # accessible to the parent installation"), which reads as a missing repo.
  #
  # Measured 2026-08-03: the App's only installation is the 5dive-ai ORG (20 repos,
  # all 5dive-ai/*), while `5dive-api` and `5dive-frontend` are `lodar/*` on a
  # PERSONAL account. So 5dive-ai/5dive pushed fine and every customer-facing repo
  # 422'd, and had since the rail was built. Pinning also means that installing the
  # App on the personal account does NOT fix it on its own: that mints a SECOND
  # installation id and the box would keep addressing the first one.
  #
  # Ask GitHub which installation owns the repo. Fall back to the pinned id when the
  # lookup cannot answer, so a box with one installation and no extra permission
  # behaves exactly as before.
  #
  # DIVE-2566: the assignment MUST NOT be allowed to fail the script. `curl -fsS`
  # exits 22 on any HTTP >= 400, `pipefail` promotes that through the `| jq`, and a
  # bare `var=$(...)` under `set -e` (src/header.sh:14) takes the whole push down —
  # so the `elif [[ -z "$_inst_for_repo" ]]` fallback five lines below was
  # UNREACHABLE in exactly the case it was written for: a repo outside every
  # installation, where that endpoint 404s. Delegated push to any lodar/* repo died
  # with a bare rc=22 and no message of its own.
  #
  # The trap is that the code was written the CAREFUL way. `local` is declared on
  # its own line precisely so the substitution's exit status is not masked — the
  # standard shellcheck-endorsed habit (`local x=$(cmd)` always returns 0 and hides
  # failures). Here that correct habit is what makes the failure fatal. When a probe
  # is ALLOWED to fail, splitting the declaration is not enough; the failure has to
  # be handled explicitly, which is what the `|| _inst_for_repo=""` below does.
  # Assigning empty rather than `|| true` is deliberate: it states the post-condition
  # the fallback branch reads, instead of leaving it to the substitution's behaviour.
  local _inst_for_repo
  _inst_for_repo=$(curl -fsS --max-time 15 \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${slug}/installation" 2>/dev/null \
        | jq -r '.id // empty') || _inst_for_repo=""
  if [[ -n "$_inst_for_repo" && "$_inst_for_repo" != "$inst" ]]; then
    echo "[5dive] ${slug} belongs to installation ${_inst_for_repo}, not the pinned ${inst} — minting against the repo's own installation" >&2
    inst="$_inst_for_repo"
  elif [[ -z "$_inst_for_repo" ]]; then
    echo "[5dive] could not resolve an installation for ${slug}; falling back to the pinned id ${inst}. If the exchange refuses, the App is probably not installed on $(printf '%s' "$slug" | cut -d/ -f1)." >&2
  fi

  # Keep the response body: `curl -fsS` prints nothing on a 4xx, so the old code
  # turned GitHub's own explanation into "installation token exchange failed" and
  # the operator had to re-run the call by hand to see the cause. A refusal must
  # carry what the remote actually said (DIVE-2143).
  local _tokresp _tokrc=0
  _tokresp=$(curl -sS --max-time 15 -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d "$body" \
        "https://api.github.com/app/installations/${inst}/access_tokens" 2>&1) || _tokrc=$?
  tok=$(printf '%s' "$_tokresp" | jq -r '.token // empty' 2>/dev/null)
  if [[ -z "$tok" ]]; then
    local _why; _why=$(printf '%s' "$_tokresp" | jq -r '.message // empty' 2>/dev/null)
    [[ -n "$_why" ]] || _why="$(printf '%s' "$_tokresp" | head -c 300)"
    local _owner; _owner="${slug%%/*}"
    # DIVE-2566: NOT $E_GENERIC, and not a number from someone else's namespace.
    # The original symptom of this whole row was an operator seeing rc=22 — curl's
    # exit for HTTP>=400 — which is not a 5dive code at all (error_codes.sh tops out
    # at E_PERMISSION=10), so the number carried no meaning and the message named
    # four possible causes at once. E_AUTH_REQUIRED is the honest class: the App
    # cannot authenticate FOR THIS REPO. It is deliberately distinct from
    # E_PERMISSION (which means "must run as root" here) and from the git-credential
    # faults _push_fetch_why now separates.
    #
    # No NEW code was added to the ladder on purpose: error_codes.sh says "keep
    # err_class_for() in sync if you add a code", so a new code has a reader outside
    # this file, and this failure genuinely IS an authentication class rather than a
    # class of its own. Widening a shared ladder for one call site is a bigger blast
    # radius than the fix needs.
    #
    # The no-installation case gets its own SENTENCE because it is the one an
    # operator cannot act on by retrying, and it is the case that actually happens:
    # the App is installed on the 5dive-ai org, while lodar/5dive-api and
    # lodar/5dive-frontend live on a personal account. Installing it there is
    # DIVE-2033, a human-only step. Until then this refusal is CORRECT behaviour and
    # only has to say why.
    case "$_why" in
      *"not installed"*|*"Not Found"*|*"not accessible"*|*"does not exist"*)
        fail "$E_AUTH_REQUIRED" "the GitHub App has no installation covering ${slug} — it cannot mint a token for a repo it was never installed on, so this push CANNOT succeed and retrying will not help. GitHub said: ${_why}. Install the App on '${_owner}' (DIVE-2033, a human-only account-level step), or relay this push to someone holding credentials for ${slug}. This is NOT a missing sudo grant and NOT a git-credential problem." ;;
      *)
        fail "$E_AUTH_REQUIRED" "installation token exchange failed for ${slug} against installation ${inst}. GitHub said: ${_why:-no response body}. If that names an inaccessible repository, the App is not installed on '${_owner}'." ;;
    esac
  fi

  # Push ONLY the named branch, token via extraheader so it never lands in argv
  # (no leak via ps/audit). Discard the token immediately after.
  local authhdr rc=0
  authhdr="Authorization: Basic $(printf 'x-access-token:%s' "$tok" | base64 -w0)"
  "${G[@]}" -c http."https://github.com/".extraheader="$authhdr" \
      push "$repourl" "refs/heads/${branch}:refs/heads/${branch}" 2>&1 | sed 's/^/  /' || rc=$?
  tok=""; authhdr=""   # discard

  [[ $rc -eq 0 ]] || fail "$E_GENERIC" "push failed (branch ${branch}); see output above."
  local sha
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
