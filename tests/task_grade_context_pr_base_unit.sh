#!/usr/bin/env bash
# TIER: core — ~3.5s measured (agent-dev seat, worktree cli-6147, 2026-10-13).
#   No root, no network, no tmux: the forge reads are stubbed at `_gate_pr_shas`
#   and `_gate_pr_base_oid`, and "origin" is a local bare repo.
#
# DIVE-6147 — THE PACKET'S DIFF IS THE PULL REQUEST'S DIFF, OR IT SAYS IT IS NOT.
#
# THE SPECIMEN (teal-fox, 2026-10-12, `5dive task grade-context DIVE-712`):
# BASE_SHA came from `merge-base <sha> origin/main` in the delivery repo, whose
# origin/main nothing fetches. It sat 64 commits behind PR #1311's baseRefOid, so
# base..sha spanned 221 files / 1.48 MB while the PR changed 3, and the 128 KB cap
# left only the changelog fragment. The grader is told to use ONLY the packet.
#
#   A  stale local origin/main, PR base present: the packet's file list equals
#      the PR's three-dot diff (what `gh pr diff` shows), and the maker's code
#      survives the byte cap.
#   B  the PR's base moved past anything in the checkout: it is FETCHED as
#      objects only — no ref moves, no FETCH_HEAD — and A still holds.
#   C  the base cannot be fetched: merge-base fallback, labelled, and the label
#      says the diff may carry commits the maker did not write.
#   D  unbound/unreadable PR: still a merge-base packet, labelled as such.
#
# Negative control: run this file against the pre-fix src/ and A1/A2/B1 go red
# (the packet carries the upstream files and the cap cuts src/x.sh out).
#
# Run: bash tests/task_grade_context_pr_base_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/dive6147.XXXXXX)
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
  lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
  lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh \
  cmd_push.sh cmd_org.sh cmd_project.sh; do source "$SRC/$f"; done
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"; HOME="$TMP/grader-home"; XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$TASKS_DIR" "$HOME"; chmod 700 "$HOME"; JSON_MODE=0; set +e
printf '{"verify":"always"}\n' >"$BOX_CONFIG"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
PASS=0; FAILN=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
tasks_db_init >/dev/null 2>&1

# THE SEAMS ARE THE TWO FORGE READS AND NOTHING ELSE.
_PR_PAIR=""; _PR_BASE=""
_gate_gh_token() { printf ''; }
_gate_slug_from_url() { printf '5dive-ai/5dive'; }
_gate_pr_shas() { printf '%s' "$_PR_PAIR"; }
_gate_pr_base_oid() { printf '%s' "$_PR_BASE"; }

UP="$TMP/up.git"; W="$TMP/w"; REPO="$TMP/repo"
git init -q --bare -b main "$UP"
git init -q -b main "$W"; git -C "$W" remote add origin "$UP"
mkdir -p "$W/src"; printf 'old\n' >"$W/src/x.sh"
git -C "$W" add -A; git -C "$W" commit -qm c0; git -C "$W" push -q origin main
git clone -q "$UP" "$REPO"                       # the delivery checkout: origin/main = c0
STALE=$(git -C "$REPO" rev-parse origin/main)
# Upstream moves on in files that sort BEFORE the maker's, each bigger than the
# cap, so a wrong base both carries them and cuts the maker's code out.
mkdir -p "$W/aaa"
for n in 1 2 3; do
  head -c 150000 /dev/zero | tr '\0' 'u' | fold -w 100 >"$W/aaa/up$n.txt"
  git -C "$W" add -A; git -C "$W" commit -qm "upstream $n"
done
git -C "$W" push -q origin main; PRBASE=$(git -C "$W" rev-parse HEAD)
git -C "$W" checkout -q -b feat
mkdir -p "$W/changelog.d"; printf 'fix\n' >"$W/changelog.d/PR-1.md"
printf 'old\nnflags=$(grep -c . <<<"$flags") || nflags=0\n' >"$W/src/x.sh"
git -C "$W" add -A; git -C "$W" commit -qm "the maker's change"
SHA=$(git -C "$W" rev-parse HEAD); git -C "$W" push -q origin feat
git -C "$REPO" fetch -q origin feat              # brings the branch, NOT origin/main
rm -f "$REPO/.git/FETCH_HEAD"
[[ "$(git -C "$REPO" rev-parse origin/main)" == "$STALE" && "$STALE" != "$PRBASE" ]] \
  && ok_t "PRECONDITION: the checkout's origin/main is stale (behind the PR's base)" \
  || bad_t "PRECONDITION: fixture origin/main is not stale"
WANT=$(git -C "$W" diff --name-only "main...feat" | sort | tr '\n' ' ')

seed() { # <board-sha>
  db "DELETE FROM tasks;"
  local result=$'CHANGED: src/x.sh\nDELIVERED-SHA: '"$1"
  local i; i=$(db "INSERT INTO tasks (title,body,status,assignee,verifier,maker_agent,kind,priority,created_by,acceptance_criteria,result,review_mode,delivery_repo_path,delivered_sha,delivery_ref,delivered_at)
    VALUES ('pr base','','todo','quinn','quinn','dev','standard','high','dev','The guard is added.',$(sqlq "$result"),'temp',$(sqlq "$REPO/.git"),$(sqlq "$1"),'https://github.com/5dive-ai/5dive/pull/1311',datetime('now')); SELECT last_insert_rowid();")
  db "SELECT ident FROM tasks WHERE id=$i;"
}
pkt()   { cmd_task_grade_context "$1" 2>&1; }
field() { sed -n "s/^$2: //p" <<<"$1" | head -1; }
files() { grep -oE '^diff --git a/[^ ]+' <<<"$1" | sed 's|^diff --git a/||' | sort | tr '\n' ' '; }

echo "── A. stale origin/main, PR read: the packet's diff is the PR's ──"
_PR_PAIR="${SHA}|"; _PR_BASE="$PRBASE"; IDENT=$(seed "$SHA"); OUT=$(pkt "$IDENT")
[[ "$(files "$OUT")" == "$WANT" ]] \
  && ok_t "A1 the packet's file list equals the PR's three-dot diff ($WANT)" \
  || bad_t "A1 packet file list is not the PR's" "got: $(files "$OUT")| want: $WANT"
[[ "$OUT" == *'|| nflags=0'* ]] \
  && ok_t "A2 THE SPECIMEN: the maker's own code survives the byte cap" \
  || bad_t "A2 the cap cut the maker's code out of the packet"
[[ "$(field "$OUT" BASE_SOURCE)" == pr-base* && "$(field "$OUT" BASE_SHA)" == "$PRBASE" ]] \
  && ok_t "A3 BASE_SOURCE names the PR base, and BASE_SHA is it" \
  || bad_t "A3 base source/sha wrong" "$(field "$OUT" BASE_SOURCE) / $(field "$OUT" BASE_SHA)"

echo "── B. the PR's base is past anything in the checkout: fetched, refs untouched ──"
printf 'later\n' >"$W/later.txt"; git -C "$W" checkout -q main
git -C "$W" add -A; git -C "$W" commit -qm "upstream after the branch"; git -C "$W" push -q origin main
NEWBASE=$(git -C "$W" rev-parse HEAD); git -C "$W" checkout -q feat
git -C "$REPO" cat-file -e "${NEWBASE}^{commit}" 2>/dev/null \
  && bad_t "B0 PRECONDITION: the new base is already in the checkout" || ok_t "B0 PRECONDITION: the PR's new base is absent from the checkout"
_PR_BASE="$NEWBASE"; IDENT=$(seed "$SHA"); OUT=$(pkt "$IDENT")
[[ "$(files "$OUT")" == "$WANT" && "$(field "$OUT" BASE_SOURCE)" == pr-base* ]] \
  && ok_t "B1 the absent base is fetched and the packet is still exactly the PR's diff" \
  || bad_t "B1 fetched-base packet wrong" "$(field "$OUT" BASE_SOURCE) | $(files "$OUT")"
[[ "$(git -C "$REPO" rev-parse origin/main)" == "$STALE" && ! -e "$REPO/.git/FETCH_HEAD" ]] \
  && ok_t "B2 ...and no ref in the other seat's checkout moved (origin/main unchanged, no FETCH_HEAD)" \
  || bad_t "B2 the fetch moved a ref" "origin/main=$(git -C "$REPO" rev-parse origin/main)"

echo "── C. the base cannot be fetched: fallback, labelled, and warned ──"
_PR_BASE=2222222222222222222222222222222222222222; IDENT=$(seed "$SHA"); OUT=$(pkt "$IDENT"); RC=$?
(( RC == 0 )) && ok_t "C1 an unfetchable base still builds a packet" || bad_t "C1 packet refused" "rc=$RC"
[[ "$(field "$OUT" BASE_SOURCE)" == merge-base-local* && "$(field "$OUT" BASE_SOURCE)" == *"MAY CARRY COMMITS THE MAKER DID NOT WRITE"* ]] \
  && ok_t "C2 ...labelled merge-base-local, naming the unfetchable PR base and the risk" \
  || bad_t "C2 fallback not labelled" "$(field "$OUT" BASE_SOURCE)"

echo "── D. no PR readable: still a merge-base packet, labelled as such ──"
_PR_PAIR=""; _PR_BASE="$PRBASE"; IDENT=$(seed "$SHA"); OUT=$(pkt "$IDENT"); RC=$?
[[ $RC == 0 && "$(field "$OUT" BASE_SHA)" == "$STALE" ]] \
  && ok_t "D1 an unbound/unreadable row keeps the local merge-base (no forge read was trusted)" \
  || bad_t "D1 unread row base wrong" "rc=$RC base=$(field "$OUT" BASE_SHA)"
[[ "$(field "$OUT" BASE_SOURCE)" == merge-base-local*"no pull-request base was readable"* ]] \
  && ok_t "D2 ...and BASE_SOURCE says merge-base-local" || bad_t "D2 label missing" "$(field "$OUT" BASE_SOURCE)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAILN"
exit $(( FAILN > 0 ? 1 : 0 ))
