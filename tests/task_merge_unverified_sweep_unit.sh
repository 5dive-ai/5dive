#!/usr/bin/env bash
# DIVE-3526 isolated unit harness for `5dive task merge-unverified` — the consumer
# for the `task.merge-gate-unverified` audit stamp.
#
# The stamp itself has worked since DIVE-1935 (the auto-detect merge gate warns,
# writes the row, and lets the close proceed). Nothing ever read it back, so a close
# the gate could not check looked exactly like a verified-clean one from the outside.
# This harness grades the reader: it must re-derive each stamped ident's PR state NOW
# and, above all, it must NOT report partial coverage as a clean sweep — that is the
# DIVE-1935 defect itself, rebuilt one layer down in the consumer.
#
# Isolation matches the sibling gate harnesses: src/ libs into a throwaway STATE_DIR
# (the live shared tasks.db is NEVER touched), `gh` STUBBED on PATH, and the audit log
# is a FIXTURE FILE under $TMP — never /var/log/5dive/agent-audit.log, which is the
# real fleet record and is root-owned.
# Run: bash tests/task_merge_unverified_sweep_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# The credential-free rail would reach the real network and grade LIVE pull requests
# instead of the stub. Must sit after grading_tree.sh, which clears inherited FIVE_*.
export FIVE_GATE_NO_ANON=1
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/merge-unverified-unit.XXXXXX)"
mkdir -p "$TMP/bin"

# sudo fail-closed: the token resolver's last arm shells out to `sudo -n -u claude gh
# auth token` and would otherwise reach the HOST's real credential.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"

# --- stub gh ---------------------------------------------------------------
# Only one call shape matters here: the per-repo open-PR listing the sweep makes
# once per repo. Each repo's answer is read from a fixture file named for the slug;
# a MISSING fixture means "this repo did not answer" (exit 1), which is how the
# partial-coverage arm is driven.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
repo=""
for a in "$@"; do
  [[ "$prev" == "--repo" ]] && repo="$a"
  prev="$a"
done
f="$GH_STUB_DIR/$(printf '%s' "$repo" | tr '/' '_')"
[[ -r "$f" ]] || exit 1
cat "$f"
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_STUB_DIR="$TMP/prs"; mkdir -p "$GH_STUB_DIR"
# A resolved token short-circuits _gate_gh_reachable; the stub ignores its value.
export GH_TOKEN=stub-token

# Two repos, so "one answered, one did not" is expressible.
export FIVE_GATE_REPOS="5dive-ai/5dive lodar/5dive-api"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh" \
  || { printf 'NOT OK - tests/lib/actor_seam.sh not reachable; the actor cannot be pinned\n'; exit 1; }
actor_seam_selftest dev \
  || { printf 'NOT OK - actor seam is inert: task_actor did not resolve to dev under the pin\n'; exit 1; }
actor_seam_as dev
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }
audit_log() { :; }

mkrow() { # <ident> <status>
  db "INSERT INTO tasks (ident,title,status,assignee,created_by,created_at)
      VALUES ('$1','row for $1','$2','dev','main',datetime('now'));" >/dev/null 2>&1
}
stamp() { # <ident> <ts> [reason]
  printf '{"ts":"%s","user":"agent-dev","cmd":"task.merge-gate-unverified","result":"ok","code":0,"args":["%s","reason=%s","seat=agent-dev"]}\n' \
    "$2" "$1" "${3:-partial-repo-scan-7-of-11}" >>"$AUDIT_LOG"
}
prlist() { # <slug> <number> <title> <headRefName>
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >>"$GH_STUB_DIR/$(printf '%s' "$1" | tr '/' '_')"
}
answers() { : >"$GH_STUB_DIR/$(printf '%s' "$1" | tr '/' '_')"; }   # answered, zero open PRs

AUDIT_LOG="$TMP/audit.log"; : >"$AUDIT_LOG"

# ── T1: an audit log this seat cannot read must REFUSE, never report 0 stamps ──
# The whole ticket is a record written and never read. A reader that answers
# "0 stamped closes, all clean" out of a log it never opened is worse than no
# reader at all: it manufactures the clearance the stamp exists to withhold.
AUDIT_LOG="$TMP/does-not-exist.log"
out=$( (cmd_task_merge_unverified 2>&1) ); rc=$?
if (( rc != 0 )) && grep -qi "cannot find the audit log" <<<"$out"; then
  ok_t "T1 absent audit log REFUSES (rc=$rc) instead of reporting an empty backlog"
else
  bad_t "T1 absent audit log did not refuse" "rc=$rc: $out"
fi
grep -qi "NOT an empty backlog" <<<"$out" \
  && ok_t "T1b the refusal says explicitly that this is not an empty backlog" \
  || bad_t "T1b refusal does not distinguish unreadable from clean" "$out"
AUDIT_LOG="$TMP/audit.log"

# ── T2: a stamped close with an open PR naming the ident is a FINDING, rc=1 ──
mkrow DIVE-9001 done
stamp DIVE-9001 "2026-08-12T02:49:11+00:00"
answers lodar/5dive-api
prlist 5dive-ai/5dive 777 "DIVE-9001 buzz-pair envelope" "dive-9001-envelope"
out=$( (cmd_task_merge_unverified 2>&1) ); rc=$?
if (( rc == 1 )) && grep -q "OPEN-PR" <<<"$out" && grep -q "#777" <<<"$out"; then
  ok_t "T2 stamped close with a still-open PR is reported OPEN-PR and exits 1"
else
  bad_t "T2 open PR behind a stamped close was not surfaced" "rc=$rc: $out"
fi

# ── T3: full coverage + no open PR = clean, and it exits 0 ──
: >"$AUDIT_LOG"; rm -f "$GH_STUB_DIR"/*
mkrow DIVE-9002 done
stamp DIVE-9002 "2026-08-12T03:00:00+00:00"
answers 5dive-ai/5dive; answers lodar/5dive-api
out=$( (cmd_task_merge_unverified 2>&1) ); rc=$?
if (( rc == 0 )) && grep -q "clean" <<<"$out" && ! grep -q "OPEN-PR" <<<"$out"; then
  ok_t "T3 a quiet ident under FULL coverage reads clean and exits 0"
else
  bad_t "T3 clean arm wrong" "rc=$rc: $out"
fi

# ── T4: THE ONE THAT MATTERS — partial coverage is `unconfirmed`, never clean ──
# Identical fixture to T3 except one repo does not answer. If this arm ever reads
# `clean`, the sweep has laundered a scan it did not complete, which is precisely
# the DIVE-1935/1955 defect it was built to consume.
rm -f "$GH_STUB_DIR"/*
answers 5dive-ai/5dive            # lodar/5dive-api deliberately absent => exit 1
out=$( (cmd_task_merge_unverified 2>&1) ); rc=$?
# Assert on the ROW's verdict column, not on the whole output: the summary line
# legitimately contains the word "clean" in its `0 clean` tally, and matching that
# would make this arm pass on a laundered sweep.
row=$(grep '^DIVE-9002' <<<"$out")
if grep -q "unconfirmed" <<<"$row" && ! grep -qw "clean" <<<"${row%%no open PR*}"; then
  ok_t "T4 a quiet ident under PARTIAL coverage reads unconfirmed, not clean"
else
  bad_t "T4 partial coverage was laundered as a clean sweep" "rc=$rc: $out"
fi
grep -q "1/2" <<<"$out" \
  && ok_t "T4b the summary states the coverage it actually achieved (1/2 repos)" \
  || bad_t "T4b coverage not stated" "$out"
grep -qi "did NOT answer: lodar/5dive-api" <<<"$out" \
  && ok_t "T4c the unanswered repo is NAMED, not just counted" \
  || bad_t "T4c unanswered repo not named" "$out"

# ── T5: a row that is no longer done is `reopened`, not a finding ──
: >"$AUDIT_LOG"; rm -f "$GH_STUB_DIR"/*
mkrow DIVE-9003 todo
stamp DIVE-9003 "2026-08-12T04:00:00+00:00"
answers 5dive-ai/5dive; answers lodar/5dive-api
prlist 5dive-ai/5dive 778 "DIVE-9003 still in flight" "dive-9003"
out=$( (cmd_task_merge_unverified 2>&1) ); rc=$?
if (( rc == 0 )) && grep -q "reopened" <<<"$out" && ! grep -q "OPEN-PR" <<<"$out"; then
  ok_t "T5 a stamped ident whose row reopened is not counted as a silent close"
else
  bad_t "T5 reopened arm wrong" "rc=$rc: $out"
fi

# ── T6: the ident matches at WORD BOUNDARIES, as the gate's own scan does ──
# DIVE-900 must not be matched by an open PR naming DIVE-9004, or every low-numbered
# ident in the backlog reports a finding it does not own.
: >"$AUDIT_LOG"; rm -f "$GH_STUB_DIR"/*
mkrow DIVE-900 done
stamp DIVE-900 "2026-08-12T05:00:00+00:00"
answers lodar/5dive-api
prlist 5dive-ai/5dive 779 "DIVE-9004 unrelated work" "dive-9004-unrelated"
out=$( (cmd_task_merge_unverified 2>&1) ); rc=$?
if (( rc == 0 )) && ! grep -q "OPEN-PR" <<<"$out"; then
  ok_t "T6 DIVE-900 is not matched by an open PR naming DIVE-9004 (word boundaries)"
else
  bad_t "T6 substring match leaked a finding" "rc=$rc: $out"
fi
# ...and the same ident IS matched when the PR really names it — a negative control
# for T6, so a match predicate broken to never-match cannot pass this file.
prlist 5dive-ai/5dive 780 "fix: DIVE-900 for real" "dive-900-real"
out=$( (cmd_task_merge_unverified 2>&1) ); rc=$?
if (( rc == 1 )) && grep -q "#780" <<<"$out"; then
  ok_t "T6b control: an exact ident match in the title IS found"
else
  bad_t "T6b the match predicate finds nothing at all" "rc=$rc: $out"
fi

# ── T7: two stamps for one ident collapse to a single row (re-closed after a bounce) ──
: >"$AUDIT_LOG"; rm -f "$GH_STUB_DIR"/*
mkrow DIVE-9005 done
stamp DIVE-9005 "2026-08-12T06:00:00+00:00"
stamp DIVE-9005 "2026-08-13T06:00:00+00:00"
answers 5dive-ai/5dive; answers lodar/5dive-api
out=$( (cmd_task_merge_unverified 2>&1) ); rc=$?
n=$(grep -c '^DIVE-9005' <<<"$out")
if [[ "$n" == "1" ]]; then
  ok_t "T7 a twice-stamped ident is reported once (newest stamp wins)"
else
  bad_t "T7 duplicate stamps produced $n rows" "$out"
fi

# ── T8: --since filters on the stamp's own timestamp ──
: >"$AUDIT_LOG"; rm -f "$GH_STUB_DIR"/*
mkrow DIVE-9006 done
stamp DIVE-9006 "2020-01-01T00:00:00+00:00"
answers 5dive-ai/5dive; answers lodar/5dive-api
out=$( (cmd_task_merge_unverified --since=7d 2>&1) ); rc=$?
if ! grep -q "DIVE-9006" <<<"$out"; then
  ok_t "T8 --since=7d excludes a stamp from 2020"
else
  bad_t "T8 --since did not filter" "$out"
fi
out=$( (cmd_task_merge_unverified 2>&1) )
grep -q "DIVE-9006" <<<"$out" \
  && ok_t "T8b control: without --since the same stamp IS swept" \
  || bad_t "T8b unfiltered sweep lost the row" "$out"

# ── T9: a malformed line must not take the sweep with it, and must be DISCLOSED ──
# Measured on the live log 2026-08-17: `jq -s` over /var/log/5dive/agent-audit.log
# exits 5 and yields NOTHING. The log is world-appendable by every seat, so appends
# interleave and truncated lines exist — one of them 9 MB back would otherwise silence
# the entire sweep, and under the bundle's `set -euo pipefail` it killed the CLI run.
: >"$AUDIT_LOG"; rm -f "$GH_STUB_DIR"/*
mkrow DIVE-9007 done
stamp DIVE-9007 "2026-08-14T06:00:00+00:00"
printf '{"ts":"2026-08-14T06:30:00+00:00","cmd":"task.merge-gate-unverified","args":["DIVE-99\n' >>"$AUDIT_LOG"
answers lodar/5dive-api
prlist 5dive-ai/5dive 781 "DIVE-9007 still open" "dive-9007"
out=$( (cmd_task_merge_unverified 2>&1) ); rc=$?
if (( rc == 1 )) && grep -q "DIVE-9007" <<<"$out" && grep -q "#781" <<<"$out"; then
  ok_t "T9 a truncated log line does not stop the sweep — the good stamps still resolve"
else
  bad_t "T9 one malformed line silenced the whole sweep" "rc=$rc: $out"
fi
grep -qi "did not parse" <<<"$out" \
  && ok_t "T9b the skipped line is DISCLOSED, not silently dropped" \
  || bad_t "T9b unparseable line was swallowed without a word" "$out"

# ── T9c: ORDERING. T9 alone is not enough and passing it is not evidence. ──────
# A single streaming jq over the whole candidate set ABORTS on the first bad line and
# drops every stamp AFTER it, so T9 with the bad line LAST goes green on exactly the
# implementation this arm exists to forbid. Pin the bad line FIRST: the sweep must still
# find the good stamp behind it, still exit 1, and still disclose the skip. Without this
# arm the defect regresses invisibly (quinn, DIVE-3526 iteration 1).
: >"$AUDIT_LOG"; rm -f "$GH_STUB_DIR"/*
mkrow DIVE-9008 done
printf '{"ts":"2026-08-14T06:30:00+00:00","cmd":"task.merge-gate-unverified","args":["DIVE-99\n' >>"$AUDIT_LOG"
stamp DIVE-9008 "2026-08-14T07:00:00+00:00"
answers lodar/5dive-api
prlist 5dive-ai/5dive 782 "DIVE-9008 still open" "dive-9008"
out=$( (cmd_task_merge_unverified 2>&1) ); rc=$?
if (( rc == 1 )) && grep -q "DIVE-9008" <<<"$out" && grep -q "#782" <<<"$out"; then
  ok_t "T9c a malformed line BEFORE the stamp does not swallow it (bad-line-first ordering)"
else
  bad_t "T9c a leading malformed line dropped every stamp behind it" "rc=$rc: $out"
fi
grep -qi "did not parse" <<<"$out" \
  && ok_t "T9d the leading skipped line is DISCLOSED too" \
  || bad_t "T9d leading unparseable line was swallowed without a word" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
