#!/usr/bin/env bash
# DIVE-1963 isolated unit harness — an INFERRED repo must not bind, and a warning
# must not overstate the sweep it performed.
#
# DIVE-1955 made the repo travel with the binding. Its resolver took the task's repo
# from three places, and the third was "any github URL sitting anywhere in the body".
# That reads a URL the body MENTIONS as a declaration of where the work lives.
# DIVE-1955's own close is the specimen: the body quotes the constant the ticket is
# about (`_PUSH_DEFAULT_REPO="https://github.com/5dive-ai/5dive.git"`), so every bare
# `#N` bound to the CLI repo and api + frontend were never searched. The ticket about
# an implicit repo standing in for a missing one triggered a narrower version of
# itself, sourced from prose instead of from a constant.
#
# What is pinned here:
#   1. a quoted URL in the body declares NOTHING — `_gate_task_repo_slug` returns
#      empty — while delivery_ref and a `Repo:` line still declare (the two
#      structured signals, unchanged);
#   2. NARROWING IS GONE: a delivered bare #N that lives only in api is now found
#      there even though the body quotes a CLI URL (it used to come back
#      unresolvable, and the close was stamped rather than refused);
#   3. THE DANGEROUS HALF IS GONE TOO, and this is the case a "fall back to the
#      sweep only when the inferred repo misses" fix would NOT have caught: when the
#      inferred repo DOES have a #N, the old path blessed a close with a confident
#      verdict about a pull request nobody claimed. It must now report AMBIGUOUS;
#   4. a DECLARED repo still narrows — dropping inference must not loosen the
#      binding that DIVE-1955 built (an api task's `#N` never gets judged against
#      the CLI repo's unrelated `#N`);
#   5. the unresolvable warning names the repo(s) ACTUALLY searched, in all three
#      scopes (own-URL / declared / swept), and never claims a sweep that did not run.
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_merge_gate_inferred_repo_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-inferred-repo-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Repo-aware gh stub, same contract as tests/task_merge_gate_multirepo_unit.sh: a PR
# number exists in a SPECIFIC repo, never in the abstract, so a stub that ignores
# --repo would manufacture collisions and report a defect that lives only in itself.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1; exit 0; fi
a=("$@"); expr='.'; repo=""; i=0
while [[ $i -lt ${#a[@]} ]]; do
  case "${a[$i]}" in
    -q)      expr="${a[$((i+1))]}"; i=$((i+2)) ;;
    -q*)     expr="${a[$i]#-q}";    i=$((i+1)) ;;
    --repo)  repo="${a[$((i+1))]}"; i=$((i+2)) ;;
    *)       i=$((i+1)) ;;
  esac
done
rkey() { local k="${1##*/}"; printf '%s' "${k//[^A-Za-z0-9]/_}"; }
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  ref="$3"
  if [[ -z "$repo" && "$ref" == https://github.com/* ]]; then
    repo=$(printf '%s' "$ref" | cut -d/ -f4,5)
  fi
  n="${ref##*/}"
  fx="GH_STUB_PR_$(rkey "$repo")_${n}"; json="${!fx:-}"
  [[ -n "$json" ]] || exit 1
  printf '%s' "$json" | jq -r "$expr" 2>/dev/null; exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  ff="GH_STUB_LIST_FAIL_$(rkey "$repo")"; [[ -n "${!ff:-}" ]] && exit 1
  lx="GH_STUB_PRLIST_$(rkey "$repo")"
  printf '%s' "${!lx:-[]}" | jq -r "$expr" 2>/dev/null; exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
# real sudo resets PATH to secure_path and would reach the HOST's gh login.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_push.sh cmd_task.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
task_need_notify() { :; }
_task_close_notify() { :; }
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
export GH_STUB_AUTH_TOKEN="tok"
export FIVE_GATE_REPOS="5dive-ai/5dive,lodar/5dive-api,lodar/5dive-frontend"

OPEN_RED='{"state":"OPEN","mergedAt":null,"statusCheckRollup":[{"conclusion":"FAILURE"}],"title":"unrelated","headRefName":"unrelated"}'
MERGED_OK='{"state":"MERGED","mergedAt":"2026-07-25T02:52:00Z","statusCheckRollup":[{"conclusion":"SUCCESS"}],"title":"unrelated","headRefName":"unrelated"}'

# The exact prose that caused it: the body of a ticket ABOUT the constant.
QUOTES_CLI_URL='MECHANISM: _PUSH_DEFAULT_REPO is a readonly constant pinned to
https://github.com/5dive-ai/5dive.git and every bare reference resolved against it.'

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
seed()     { db "DELETE FROM tasks WHERE ident='$1';
                 INSERT INTO tasks (ident, title, body, status, created_by, assignee)
                   VALUES ('$1','t',$(sqlq "${2:-}"),'in_progress','main','main');"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }
resultof() { db "SELECT COALESCE(result,'') FROM tasks WHERE ident='$1';"; }
refusals() { db "SELECT COUNT(*) FROM policy_refusals WHERE ident='$1';"; }
run_done() { OUT=$(cmd_task_done "$@" 2>&1); RC=$?; }
clear_fx() { unset "${!GH_STUB_PR_@}" "${!GH_STUB_PRLIST_@}" "${!GH_STUB_LIST_FAIL_@}" 2>/dev/null; }

# --- 1. what DECLARES a repo, and what merely mentions one -------------------
slug_case() { # <name> <expected> <delivery_ref> <body>
  local name="$1" want="$2" got; got=$(_gate_task_repo_slug "$3" "$4")
  [[ "$got" == "$want" ]] && ok_t "repo binding: $name" \
                          || bad_t "repo binding: $name" "want [$want] got [$got]"
}
slug_case 'a github URL QUOTED in the body declares nothing (DIVE-1963)' \
  '' '' "$QUOTES_CLI_URL"
slug_case 'not even a full pull URL in prose — a citation is not a declaration' \
  '' '' 'same defect class as https://github.com/lodar/5dive-api/pull/12'
slug_case 'delivery_ref still declares (the PR carries its own repo)' \
  'lodar/5dive-api' 'https://github.com/lodar/5dive-api/pull/6' "$QUOTES_CLI_URL"
slug_case 'an explicit `Repo:` line still declares, and beats the quoted URL' \
  'lodar/5dive-frontend' '' "$QUOTES_CLI_URL
Repo: lodar/5dive-frontend"
slug_case 'a `Repo:` line given as a URL still declares' \
  'lodar/5dive-api' '' 'Repo: https://github.com/lodar/5dive-api'

# --- 1b. the precondition the superset claim rests on ------------------------
# "deleting inference cannot lose coverage" is true because the fallback sweep covers
# EVERY known repo — and "known" is `_gate_repo_slugs`, i.e. FIVE_GATE_REPOS when it is
# exported. This suite exports it (so it never follows a host's config), which would
# leave the claim resting on an env var the suite itself set. Assert the DEFAULT with
# the variable cleared, so the claim is pinned rather than assumed. A box that exports
# a narrower list narrows the sweep with it; that is a config choice, stated here.
want_default='5dive-ai/5dive
lodar/5dive-api
lodar/5dive-frontend'
got_default=$(FIVE_GATE_REPOS='' _gate_repo_slugs)
[[ "$got_default" == "$want_default" ]] \
  && ok_t 'with FIVE_GATE_REPOS unset the sweep really is all three repos (the superset precondition)' \
  || bad_t 'default repo set changed' "want [$want_default] got [$got_default]"

# --- 1c. the lookup and the sentence share ONE definition --------------------
# The message naming the searched scope used to derive the binding independently of the
# resolver. They agreed, but agreement between two copies is "does not currently drift",
# not "cannot" — so the derivation is now a single `_gate_bind_slug` both call. Pin the
# contract that couples them: whenever a ref binds to one repo, that is the repo the
# sentence names; when nothing binds it, the sentence names the whole sweep.
bind_case() { # <name> <qref> <task_slug>
  local b s; b=$(_gate_bind_slug "$2" "$3"); s=$(_gate_search_scope "$2" "$3")
  local want="$b"; [[ -z "$b" ]] && want=$(_gate_repo_slugs | paste -sd, -)
  [[ "$s" == "$want" ]] && ok_t "scope names what the lookup binds: $1" \
                        || bad_t "scope names what the lookup binds: $1" "bind=[$b] scope=[$s] want=[$want]"
}
bind_case 'a ref carrying its own repo'      'lodar/5dive-api|6' ''
bind_case 'a bare ref in a declaring task'   '|6' 'lodar/5dive-frontend'
bind_case 'the ref own repo BEATS the task declaration' 'lodar/5dive-api|6' 'lodar/5dive-frontend'
bind_case 'a bare ref with nothing to bind it' '|6' ''

# --- 2. THE NARROWING IS GONE ------------------------------------------------
# #10 exists ONLY in lodar/5dive-api, and it is OPEN. The body quotes the CLI URL.
# Before: bound to 5dive-ai/5dive, no #10 there, "resolve to no PR in any known
# repo" -> an UNVERIFIED stamp and the close PROCEEDS over an open PR.
# After: no declaration, so the sweep runs, finds api#10, and refuses.
clear_fx; export GH_STUB_PR_5dive_api_10="$OPEN_RED"
seed NARROW-1 "$QUOTES_CLI_URL"
run_done NARROW-1 --result='backend fix, merged as PR #10'
if [[ $RC -ne 0 && "$(statusof NARROW-1)" == "in_progress" \
      && "$OUT" == *"lodar/5dive-api"* && "$OUT" == *"#10"* ]]; then
  ok_t 'a quoted CLI URL no longer hides an OPEN api PR — the sweep runs and refuses'
else
  bad_t 'narrowing not fixed' "rc=$RC status=$(statusof NARROW-1) out=$OUT"
fi

# --- 3. THE DANGEROUS HALF: the inferred repo HAS the number -----------------
# This is the case a "fall back to the sweep only when the inferred repo misses"
# fix would have left in place. #6 is MERGED+green in the CLI repo and OPEN in api.
# Before: the quoted URL bound it to the CLI repo -> a clean, unstamped close, i.e.
# a confident verdict about a pull request this task never claimed, which BLESSES a
# close over an open api PR. After: two candidates, no ident evidence -> AMBIGUOUS.
clear_fx
export GH_STUB_PR_5dive_6="$MERGED_OK"
export GH_STUB_PR_5dive_api_6="$OPEN_RED"
: >"$AUDIT_CALLS"
seed BLESS-1 "$QUOTES_CLI_URL"
run_done BLESS-1 --result='merged as PR #6'
amb_row=$(grep -c 'task.merge-gate-ambiguous' "$AUDIT_CALLS")
res=$(resultof BLESS-1)
if [[ $RC -eq 0 && "$(statusof BLESS-1)" == "done" && "$OUT" == *AMBIGUOUS* \
      && "$OUT" == *"5dive-ai/5dive"* && "$OUT" == *"lodar/5dive-api"* \
      && "$amb_row" -ge 1 && "$(refusals BLESS-1)" == "0" \
      && "$res" == *"merge-gate: UNVERIFIED"* ]]; then
  ok_t 'a quoted URL no longer BLESSES a colliding #N — reports AMBIGUOUS, stamps the record'
else
  bad_t 'inferred repo still binds a colliding ref' \
        "rc=$RC status=$(statusof BLESS-1) audit=$amb_row refusals=$(refusals BLESS-1) result=[$res] out=$OUT"
fi
# ...and the mutation guard for the assertion above: with the SAME fixtures, a
# DECLARED CLI repo is still allowed to bind #6 and close clean. If it did not, the
# case above would be passing on something other than the missing declaration.
clear_fx
export GH_STUB_PR_5dive_6="$MERGED_OK"
export GH_STUB_PR_5dive_api_6="$OPEN_RED"
seed BLESS-2 "Repo: 5dive-ai/5dive"
run_done BLESS-2 --result='merged as PR #6'
res=$(resultof BLESS-2)
if [[ $RC -eq 0 && "$(statusof BLESS-2)" == "done" && "$OUT" != *AMBIGUOUS* \
      && "$res" != *"merge-gate"* ]]; then
  ok_t 'the SAME collision, DECLARED, still binds and closes clean — only the inference changed'
else
  bad_t 'declared binding regressed' "rc=$RC status=$(statusof BLESS-2) result=[$res] out=$OUT"
fi

# --- 4. a DECLARED repo still NARROWS ----------------------------------------
# Dropping inference must not loosen the declared binding into a sweep. #7 is
# MERGED+green in the CLI repo and absent from api; an api task must NOT be told its
# delivery landed — that is the "wrong, not blind" verdict DIVE-1955 deleted.
clear_fx; export GH_STUB_PR_5dive_7="$MERGED_OK"
seed DECL-1 'Repo: lodar/5dive-api'
run_done DECL-1 --result='merged as PR #7'
res=$(resultof DECL-1)
if [[ $RC -eq 0 && "$(statusof DECL-1)" == "done" \
      && "$res" == *"merge-gate: UNVERIFIED"* && "$OUT" == *"#7 in lodar/5dive-api"* \
      && "$OUT" != *"5dive-ai/5dive"* ]]; then
  ok_t 'a declared repo still narrows — the CLI repo #7 is never borrowed to bless an api close'
else
  bad_t 'declared repo leaked into a sweep' "rc=$RC status=$(statusof DECL-1) result=[$res] out=$OUT"
fi

# --- 5. THE WARNING MUST NOT OVERSTATE ITS OWN SWEEP -------------------------
# "resolve to no PR in any known repo" was printed after searching exactly one.
# All three scopes are pinned, because each is reached by a different branch.
scope_case() { # <name> <ident> <body> <result> <must-contain> <must-NOT-contain>
  clear_fx; seed "$2" "$3"; run_done "$2" --result="$4"
  local res; res=$(resultof "$2")
  if [[ "$OUT" == *"$5"* && ( -z "$6" || "$OUT" != *"$6"* ) && "$res" == *"$5"* ]]; then
    ok_t "scope honesty: $1"
  else
    bad_t "scope honesty: $1" "want [$5] absent [$6] out=$OUT result=[$res]"
  fi
}
scope_case 'a bare #N with NO declaration says it swept all three repos' \
  SCOPE-1 '' 'merged as PR #999' \
  '#999 in 5dive-ai/5dive,lodar/5dive-api,lodar/5dive-frontend' ''
scope_case 'a bare #N in a DECLARING task names that one repo, and claims no sweep' \
  SCOPE-2 'Repo: lodar/5dive-api' 'merged as PR #999' \
  '#999 in lodar/5dive-api' 'lodar/5dive-frontend'
scope_case 'a ref carrying its OWN pull URL names only that repo' \
  SCOPE-3 '' 'merged as https://github.com/lodar/5dive-frontend/pull/77' \
  '#77 in lodar/5dive-frontend' '5dive-ai/5dive'
# The phrase itself is retired: nothing may claim a sweep in the singular-scope text.
[[ "$OUT" != *"in any known repo"* ]] \
  && ok_t 'the "in any known repo" sentence is gone from the single-repo path' \
  || bad_t 'the overstated sentence survives' "out=$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
