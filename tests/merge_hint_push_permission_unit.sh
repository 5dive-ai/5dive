#!/usr/bin/env bash
# DIVE-4999 — the board must not tell a seat to merge when this box's merge
# account cannot.
#
# THE DEFECT (luca, teal-fox, 2026-09-25). On every clean PASS the verify path
# wrote `auto-mergeable at the graded sha — run \`5dive task merge <ident>\``
# into merge_hold_reason, and `task show` renders it as the merge_owner line.
# Nothing on that path asked whether the account `_merge_do` merges WITH may
# push to the base repo. The box's account was pull-only on the upstream, and
# the seats followed the line anyway: a tier-2 secret gate for a merge token
# (5dive-browser#16) and an approval gate to a lead with no rights (5dive#1129).
#
# WHAT IS EXECUTED HERE:
#   A. the pure verdict over a `.permissions` object;
#   B. the ROOT half `_merge_do_push_probe`, against a stubbed `gh` on PATH
#      (the stub records its argv, so the call shape is asserted, not assumed);
#   C. the CALLER half `_merge_push_probe`, against a stubbed `sudo`;
#   D. the shipped `cmd_task_verify`, end to end in a child process, reading
#      the column the PRODUCT wrote — one arm per permission case;
#   E. a MUTANT of src/task/loops.sh with the hint made unconditional again,
#      which must red the pull-only arm (so D is not vacuous).
# WHAT IS NOT: the sudo hop itself (root-only; the dispatch in
# cmd_task_merge_do is asserted structurally in F), and a real GitHub.
#
# Run: bash tests/merge_hint_push_permission_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/merge-hint-push-unit.XXXXXX)"
STATE_DIR="$TMP"
export FIVE_MERGE_HOLD_ROSTER="$TMP/agents.json"
printf '%s\n' '{"agents":{"main":{},"ops":{},"dev":{},"quinn":{}}}' > "$FIVE_MERGE_HOLD_ROSTER"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/broker.sh lib/gh_config.sh cmd_push.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init

PASS=0; FAIL=0
t() {  # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "ok   - $1"; else
    FAIL=$((FAIL+1)); echo "FAIL - $1 — expected '$2', got '$3'"
  fi
}
has() { [[ "$2" == *"$1"* ]] && echo yes || echo no; }

PR=https://github.com/5dive-ai/5dive-browser/pull/16
REPO=5dive-ai/5dive-browser
J_PULL='{"admin":false,"maintain":false,"pull":true,"push":false,"triage":false}'
J_PUSH='{"admin":false,"maintain":false,"pull":true,"push":true,"triage":true}'
J_MAINT='{"admin":false,"maintain":true,"pull":true,"push":false,"triage":true}'

# ── the gh stub: a PATH binary, because the probe runs it under `timeout` ────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${GH_ARGV_LOG:-/dev/null}"
printf '%s\n' "${GH_TOKEN:-}" > "${GH_TOKEN_LOG:-/dev/null}"
[[ "${GH_STUB_RC:-0}" == "0" ]] || { echo "HTTP 404: Not Found" >&2; exit "$GH_STUB_RC"; }
printf '%s\n' "${GH_STUB_PERMS:-}"
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_ARGV_LOG="$TMP/gh.argv" GH_TOKEN_LOG="$TMP/gh.tok"

# ── A. the pure verdict ─────────────────────────────────────────────────────
t "A1 push:true reads push"                    push      "$(_merge_push_verdict "$J_PUSH")"
t "A2 maintain:true alone reads push"          push      "$(_merge_push_verdict "$J_MAINT")"
t "A3 the teal-fox object reads pull-only"     pull-only "$(_merge_push_verdict "$J_PULL")"
t "A4 empty is unknown, never pull-only"       unknown   "$(_merge_push_verdict "")"
t "A5 null is unknown"                         unknown   "$(_merge_push_verdict "null")"
t "A6 an error body is unknown"                unknown   "$(_merge_push_verdict '{"message":"Not Found"}')"
t "A7 non-JSON is unknown"                     unknown   "$(_merge_push_verdict 'HTTP 502')"

# ── B. the root half, against the gh stub ───────────────────────────────────
row() {  # <delivery_ref> -> ident
  local id
  id=$(db "INSERT INTO tasks (title, assignee, created_by, kind, status, maker_agent, verifier, delivery_ref, iteration)
           VALUES ('probe row','quinn','main','standard','in_progress','dev','quinn',$(sqlq "$1"),1);
           SELECT last_insert_rowid();")
  db "SELECT ident FROM tasks WHERE id=$id;"
}
_merge_bot_token() { [[ -n "${BOT_TOK:-}" ]] || return 1; printf '%s' "$BOT_TOK"; }
IB=$(row "$PR")
out=$(BOT_TOK=tok-bot GH_STUB_PERMS="$J_PULL" _merge_do_push_probe "$IB")
t "B1 pull-only account -> 'pull-only <repo>'" "pull-only $REPO" "$out"
t "B2 ...and gh was asked exactly: api repos/<r> --jq .permissions" \
  "api repos/$REPO --jq .permissions" "$(cat "$TMP/gh.argv")"
t "B3 ...with the MERGE account's token, not the seat's" "tok-bot" "$(cat "$TMP/gh.tok")"
out=$(BOT_TOK=tok-bot GH_STUB_PERMS="$J_PUSH" _merge_do_push_probe "$IB")
t "B4 push account -> 'push <repo>'" "push $REPO" "$out"
out=$(BOT_TOK=tok-bot GH_STUB_RC=1 _merge_do_push_probe "$IB")
t "B5 gh fails -> 'unknown <repo>' (fail closed, never pull-only or push)" "unknown $REPO" "$out"
rm -f "$TMP/gh.argv"
out=$(BOT_TOK='' GH_STUB_PERMS="$J_PUSH" _merge_do_push_probe "$IB")
t "B6 no merge account on the box -> 'no-credential <repo>'" "no-credential $REPO" "$out"
t "B7 ...and gh is not called without one" "no" "$([[ -e "$TMP/gh.argv" ]] && echo yes || echo no)"
out=$(BOT_TOK=tok-bot GH_STUB_PERMS="$J_PUSH" _merge_do_push_probe "$(row '')")
t "B8 a row with no delivery_ref -> unknown (no repo to ask about)" "unknown" "$out"

# ── C. the caller half, against a stubbed sudo ──────────────────────────────
sudo() { cat >/dev/null; printf '%s' "${SUDO_OUT:-}"; return "${SUDO_RC:-0}"; }
t "C1 a well-formed pull-only line passes through" "pull-only $REPO" \
  "$(SUDO_OUT="pull-only $REPO" _merge_push_probe DIVE-1)"
t "C2 a refused sudo reads unknown" "unknown" "$(SUDO_OUT='' SUDO_RC=1 _merge_push_probe DIVE-1)"
t "C3 an older installed binary (rejects two args) reads unknown" "unknown" \
  "$(SUDO_OUT='error: _merge_do takes exactly one task ident' SUDO_RC=2 _merge_push_probe DIVE-1)"
t "C4 a line outside the strict shape reads unknown" "unknown" \
  "$(SUDO_OUT="push $REPO; rm -rf /" _merge_push_probe DIVE-1)"
t "C5 'unknown <repo>' from the root half stays unknown" "unknown" \
  "$(SUDO_OUT="unknown $REPO" _merge_push_probe DIVE-1)"
unset -f sudo

# ── D. the WRITE, through the shipped cmd_task_verify ───────────────────────
cat > "$TMP/drive.sh" <<'DRIVER'
#!/usr/bin/env bash
# <src dir> <perm-case: push|pull|maint|ghfail|nocred|nosudo> -> "<merge_owner>|<reason>|<show line>"
set -uo pipefail
SRCD="$1"; CASE="$2"
TMP="$(mktemp -d /tmp/mhpp-drive.XXXXXX)"; STATE_DIR="$TMP"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/broker.sh lib/gh_config.sh cmd_push.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRCD/$f"
done
TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
task_actor() { local f="${1:-}"; [[ -n "$f" ]] && printf '%s' "$f" || printf '%s' quinn; }
# The disposition probe is the one gh read upstream of this change; stub it to
# the answer this row is about — clean, green, low risk at the graded sha.
_merge_disp_probe() { printf 'merge'; }
_merge_bot_token() { [[ "$CASE" == nocred ]] && return 1; printf 'tok-bot'; }
case "$CASE" in
  push)  export GH_STUB_PERMS='{"maintain":false,"pull":true,"push":true}' ;;
  maint) export GH_STUB_PERMS='{"maintain":true,"pull":true,"push":false}' ;;
  pull)  export GH_STUB_PERMS='{"admin":false,"maintain":false,"pull":true,"push":false,"triage":false}' ;;
  ghfail) export GH_STUB_RC=1 ;;
esac
# THE SUDO HOP, faked at the one place a harness cannot cross it: hand the
# NUL-delimited stdin to the ROOT function the executor dispatches to (F pins
# that dispatch in the source). Everything either side of the hop is real.
sudo() {
  [[ "$CASE" == nosudo ]] && { cat >/dev/null; return 1; }
  local -a a=(); local x
  while IFS= read -r -d '' x; do a+=("$x"); done
  [[ "${a[0]:-}" == --push-probe && ${#a[@]} -eq 2 ]] || return 2
  _merge_do_push_probe "${a[1]}"
}
id=$(db "INSERT INTO tasks (title, assignee, created_by, kind, status, maker_agent, verifier, delivery_ref, iteration)
         VALUES ('an upstream PR graded PASS','quinn','main','standard','in_progress','dev','quinn',
                 'https://github.com/5dive-ai/5dive-browser/pull/16',1);
         SELECT last_insert_rowid();")
ident=$(db "SELECT ident FROM tasks WHERE id=$id;")
( set +e; cmd_task_verify "$ident" --no-done \
    --result="PASS — re-derived from a fresh clone. graded-sha: aabbccdd11223344556677889900aabbccddeeff" \
    >/dev/null 2>&1 )
show=$(cmd_task_show "$ident" 2>/dev/null | grep -m1 'merge_owner =' || true)
printf '%s|%s|%s\n' \
  "$(db "SELECT COALESCE(merge_owner,'') FROM tasks WHERE id=$id;")" \
  "$(db "SELECT COALESCE(merge_hold_reason,'') FROM tasks WHERE id=$id;")" \
  "$show"
rm -rf "$TMP"
DRIVER
drive() { bash "$TMP/drive.sh" "$1" "$2"; }
reason() { cut -d'|' -f2 <<<"$1"; }
showl()  { cut -d'|' -f3- <<<"$1"; }

D_PUSH=$(drive "$PWD/src" push)
t "D1 push: the line is UNCHANGED — byte-identical to the shipped hint" \
  "auto-mergeable at the graded sha — run \`5dive task merge DIVE-1\`" "$(reason "$D_PUSH")"
t "D1a ...the owner is still the grading seat" "quinn" "${D_PUSH%%|*}"
t "D1b ...and task show renders it on the merge_owner line" yes "$(has '5dive task merge DIVE-1' "$(showl "$D_PUSH")")"
D_MAINT=$(drive "$PWD/src" maint)
t "D2 maintain without push is enough: the hint is printed" yes "$(has '5dive task merge' "$(reason "$D_MAINT")")"
D_PULL=$(drive "$PWD/src" pull)
t "D3 pull-only (the teal-fox case): NO task merge is suggested" no "$(has 'task merge' "$(reason "$D_PULL")")"
t "D3a ...the line says the PR waits on the upstream maintainer" yes \
  "$(has "waiting on the $REPO maintainer" "$(reason "$D_PULL")")"
t "D3b ...and task show renders that, not the verb" no "$(has 'task merge' "$(showl "$D_PULL")")"
t "D3c ...task show still has a merge_owner line (the render is not blocked)" yes \
  "$(has "waiting on the $REPO maintainer" "$(showl "$D_PULL")")"
D_FAIL=$(drive "$PWD/src" ghfail)
t "D4 gh fails: NO task merge is suggested (fail closed on the hint)" no "$(has 'task merge' "$(reason "$D_FAIL")")"
t "D4a ...but the line is still WRITTEN (the verify is not blocked)" yes \
  "$(has 'could not confirm' "$(reason "$D_FAIL")")"
D_NOSUDO=$(drive "$PWD/src" nosudo)
t "D5 the probe cannot be reached at all: NO task merge is suggested" no "$(has 'task merge' "$(reason "$D_NOSUDO")")"
D_NOCRED=$(drive "$PWD/src" nocred)
t "D6 no merge account on the box: waits on the maintainer, no verb" "no|yes" \
  "$(has 'task merge' "$(reason "$D_NOCRED")")|$(has "waiting on the $REPO maintainer" "$(reason "$D_NOCRED")")"

# ── E. the MUTANT: loops.sh with the hint unconditional again ───────────────
cat > "$TMP/mutate.py" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
blk = re.compile(r'          case "\$\{_md_push%% \*\}" in\n.*?\n          esac\n', re.S)
s, n = blk.subn('          _md_why="auto-mergeable at the graded sha — run \\`5dive task merge ${ident}\\`"\n', s, count=1)
open(p, 'w').write(s); print(n)
PY
MUT="$TMP/src-pre4999"; cp -r src "$MUT"
t "E1 the mutant applies exactly once" "1" "$(python3 "$TMP/mutate.py" "$MUT/task/loops.sh")"
E_PULL=$(drive "$MUT" pull)
t "E2 MUTANT: pull-only is told to run task merge — D3 is not vacuous" yes "$(has 'task merge DIVE-1' "$(reason "$E_PULL")")"
E_FAIL=$(drive "$MUT" ghfail)
t "E3 MUTANT: a failed read is told to run task merge — D4 is not vacuous" yes "$(has 'task merge DIVE-1' "$(reason "$E_FAIL")")"

# ── F. the executor dispatch, pinned at source (root-only; not executable here) ─
DO=$(declare -f cmd_task_merge_do)
probe_ln=$(grep -n -- '--push-probe' <<<"$DO" | head -1 | cut -d: -f1)
one_ln=$(grep -n '== 1 ' <<<"$DO" | head -1 | cut -d: -f1)
stand_ln=$(grep -n '_task_merge_standing_sql' <<<"$DO" | head -1 | cut -d: -f1)
t "F1 the executor dispatches --push-probe to the root probe" yes \
  "$(grep -q '_merge_do_push_probe' <<<"$DO" && echo yes || echo no)"
t "F2 ...BEFORE the one-ident contract, the standing query and the credential demand" yes \
  "$([[ -n "$probe_ln" && -n "$one_ln" && -n "$stand_ln" && $probe_ln -lt $one_ln && $probe_ln -lt $stand_ln ]] && echo yes || echo no)"
t "F3 ...and only on EXACTLY two arguments, so a one-ident merge call can never reach it" yes \
  "$(grep -q '#args\[@\]} == 2 )) && \[\[ "${args\[0\]}" == "--push-probe" \]\]' <<<"$DO" && echo yes || echo no)"
t "F4 the probe merges nothing: no merge verb in the root probe" no \
  "$(grep -qE 'pr merge|enqueuePullRequest|_merge_do_at_github' <<<"$(declare -f _merge_do_push_probe)" && echo yes || echo no)"

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
