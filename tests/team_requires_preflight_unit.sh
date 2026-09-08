#!/usr/bin/env bash
# DIVE-4103 — `team.requires:` must tell the truth about the BOX, and the Deploy
# Team template must carry the rail it claims.
#
# THE DEFECT THIS GUARDS: an import that provisions a team which cannot do the
# job it was imported for, and says nothing. The Deploy Team's job is to merge
# code; on a box with no GitHub credential it can grade and file but never land
# anything. That is a legitimate reduced mode — it is not a legitimate SILENT
# one. So the preflight is graded on three things at once: it must NAME the
# absence, it must NOT be fatal (a review-only team is still worth having), and
# it must not claim to have checked a key it has no probe for.
#
# The template arms grade the OTHER half of the row: the queue rail engages
# because exactly one seat carries a verifier/QA role marker. Two such seats and
# `_task_resolve_qa` reports ambiguity and SKIPS the rung — the imported team
# would quietly file rows with no grader. That arm carries its own negative
# control, because a uniqueness check that cannot see a duplicate is vacuous.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set +e -o pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src/cmd_compose.sh"
TPL="$ROOT/team-templates/deploy-team.5dive.yaml"
TMP="$(mktemp -d)"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

[[ -s "$SRC" ]] \
  && ok_t 'T0 cmd_compose.sh is present — the arms below are not reading an empty file' \
  || { bad_t 'T0 cmd_compose.sh missing — every arm is vacuous' "src=$SRC"; echo "-----"; exit 1; }
[[ -s "$TPL" ]] \
  && ok_t 'T0a the deploy-team template is present' \
  || { bad_t 'T0a deploy-team.5dive.yaml missing' "tpl=$TPL"; echo "-----"; exit 1; }

command -v jq >/dev/null || { printf 'SKIP - jq unavailable\n'; echo "-----"; exit 0; }
command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null || {
  printf 'SKIP - python3 + PyYAML unavailable; the parser arms cannot run\n'; echo "-----"; exit 0; }

# ---- load the units under test, without the rest of the CLI -----------------
awk '/^_compose_parse\(\)/{f=1} f{print} f&&/^PY$/{p=1} p&&/^}$/{exit}' "$SRC" > "$TMP/parse.sh"
for fn in _team_capability_label _team_capability_degraded _team_capability_present _compose_requires_preflight; do
  sed -n "/^${fn}()/,/^}/p" "$SRC" >> "$TMP/req.sh"
done
bash -n "$TMP/parse.sh" && bash -n "$TMP/req.sh" \
  && ok_t 'T0b both extracted units parse — the extraction anchors still hold' \
  || { bad_t 'T0b extraction produced unparseable bash — the anchors moved; every arm below is vacuous' ''; echo "-----"; exit 1; }

parse() { ( set -uo pipefail; . "$TMP/parse.sh"; _compose_parse "$1" ); }

# The preflight under a controlled PATH, with the CLI's own output helpers
# stubbed to plain prefixes so an arm can grade WHICH line was printed.
#   $1 = spec JSON · $2 = "present" | "absent" (whether a gh credential exists)
preflight() {
  local spec="$1" mode="$2"
  ( set -uo pipefail
    export PATH="$TMP/bin-$mode:$PATH"
    . "$TMP/req.sh"
    step() { printf 'STEP %s\n' "$*"; }
    warn() { printf 'WARN %s\n' "$*" >&2; }
    _compose_self() { printf '%s' "$TMP/bin-$mode/nosuchcli"; }
    _compose_requires_preflight "$spec"
    printf 'RC=%s\n' "$?" )
}

mkdir -p "$TMP/bin-present" "$TMP/bin-absent"
printf '#!/usr/bin/env bash\n[[ "$1 $2" == "auth token" ]] && { echo ghp_stub; exit 0; }\nexit 1\n' > "$TMP/bin-present/gh"
chmod +x "$TMP/bin-present/gh"
# bin-absent holds no gh at all. PATH still carries the real one, so the absent
# arm needs a shim that REFUSES rather than an empty dir — otherwise this box's
# own credential decides the test result, which is the arm failing open.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin-absent/gh"
chmod +x "$TMP/bin-absent/gh"

# ---------------------------------------------------------------------------
# PREFLIGHT ARMS
# ---------------------------------------------------------------------------
out=$(preflight '{"team":{},"agents":{}}' present 2>&1)
if grep -q 'RC=0' <<<"$out" && ! grep -qE 'STEP|WARN' <<<"$out"; then
  ok_t 'T1 a spec that declares no requires: prints nothing and is not an error'
else
  bad_t 'T1 a spec with no requires: was not silent' "out=$out"
fi

out=$(preflight '{"team":{"requires":["github_push"]},"agents":{}}' present 2>&1)
if grep -q 'RC=0' <<<"$out" && grep -q '^STEP precondition ok' <<<"$out" && ! grep -q '^WARN' <<<"$out"; then
  ok_t 'T2 a credential the box HAS is reported as satisfied, with no warning'
else
  bad_t 'T2 a satisfied precondition did not report clean' "out=$out"
fi

out=$(preflight '{"team":{"requires":["github_push"]},"agents":{}}' absent 2>&1)
if grep -q 'RC=0' <<<"$out"; then
  ok_t 'T3a an ABSENT precondition does NOT fail the import — the roster still comes up'
else
  bad_t 'T3a the preflight made a missing capability fatal — a review-only team is worth having' "out=$out"
fi
if grep -q 'PRECONDITION ABSENT' <<<"$out" && grep -q 'REVIEW-ONLY' <<<"$out"; then
  ok_t 'T3b an ABSENT credential NAMES the reduced mode (REVIEW-ONLY), which is the whole defect'
else
  bad_t 'T3b a missing credential was not named as review-only — the silent half of the defect survives' "out=$out"
fi
if grep -qi 're-run the import' <<<"$out"; then
  ok_t 'T3c the absence carries the recovery, not just the diagnosis'
else
  bad_t 'T3c no recovery instruction on an absent precondition' "out=$out"
fi

# A key with no probe must not be reported as either satisfied or absent. Both
# lies are worse than the truth: "satisfied" ships a team that cannot work,
# "absent" sends the user hunting for a credential that is already there.
out=$(preflight '{"team":{"requires":["teleportation"]},"agents":{}}' present 2>&1)
if grep -q 'RC=0' <<<"$out" && grep -q 'no probe for' <<<"$out" \
   && ! grep -q 'PRECONDITION ABSENT' <<<"$out" && ! grep -q '^STEP precondition ok' <<<"$out"; then
  ok_t 'T4 an unprobeable key says so — it is claimed neither satisfied nor absent'
else
  bad_t 'T4 an unknown requires: key was mis-reported' "out=$out"
fi

# Forward-compat / malformed shapes must not take the import down.
for shape in '"github_push"' 'null' '{"a":1}' '42'; do
  out=$(preflight "{\"team\":{\"requires\":$shape},\"agents\":{}}" absent 2>&1)
  grep -q 'RC=0' <<<"$out" \
    && ok_t "T5 requires: as $shape is survived, not fatal" \
    || bad_t "T5 requires: as $shape killed the preflight" "out=$out"
done
out=$(preflight '{"team":{"requires":"github_push"},"agents":{}}' absent 2>&1)
grep -q 'PRECONDITION ABSENT' <<<"$out" \
  && ok_t 'T5a a bare string requires: is still CHECKED, not silently skipped' \
  || bad_t 'T5a a string requires: was dropped instead of checked' "out=$out"

# The call site: this must run before the roster loop, or a user reads the
# precondition after four agents already exist.
pre_line=$(grep -n '_compose_requires_preflight "\$spec"' "$SRC" | head -1 | cut -d: -f1)
loop_line=$(grep -n 'for name in "\${names\[@\]}"' "$SRC" | head -1 | cut -d: -f1)
if [[ -n "$pre_line" && -n "$loop_line" ]] && (( pre_line < loop_line )); then
  ok_t 'T6 the preflight is called before the provisioning loop (source-level arm)'
else
  bad_t 'T6 the preflight does not precede provisioning' "pre=$pre_line loop=$loop_line"
fi

# ---------------------------------------------------------------------------
# TEMPLATE ARMS — the shipped deploy-team template
# ---------------------------------------------------------------------------
spec=$(parse "$TPL" 2>"$TMP/perr"); prc=$?
if (( prc == 0 )) && [[ -n "$spec" ]]; then
  ok_t 'T7 the deploy-team template parses with the real compose parser'
else
  bad_t 'T7 deploy-team.5dive.yaml does not parse' "rc=$prc err=$(cat "$TMP/perr")"
  echo "-----"; printf 'passed=%d failed=%d\n' "$pass" "$fail"; exit 1
fi

[[ "$(jq -r '.team.requires[0] // ""' <<<"$spec")" == github_push ]] \
  && ok_t 'T8 the template declares the github_push precondition' \
  || bad_t 'T8 deploy-team does not declare its precondition — the import would be silent about push' "$(jq -c '.team' <<<"$spec")"

n=$(jq -r '.agents | length' <<<"$spec")
[[ "$n" == 4 ]] \
  && ok_t 'T9 four seats, not a fifth invented one' \
  || bad_t 'T9 roster size changed' "n=$n"

# Every seat owns recurring work. A seat with none is the DIVE-4022 idle roster
# re-introduced one agent at a time.
noloop=$(jq -r '[.agents | to_entries[] | select((.value.loops // []) | length == 0) | .key] | join(",")' <<<"$spec")
[[ -z "$noloop" ]] \
  && ok_t 'T10 every seat owns at least one loop — no idle seat' \
  || bad_t 'T10 a seat has no recurring work' "seats=$noloop"

# The verifier rail engages on role text alone, so exactly one seat may carry a
# QA marker. This mirrors _task_qa_kw_clause (leading-space anchored).
qa_count() { jq -r '[.agents[] | (" " + (.role // "") | ascii_downcase)
                     | select(test(" qa| test| verif| quality"))] | length' <<<"$1"; }
c=$(qa_count "$spec")
[[ "$c" == 1 ]] \
  && ok_t 'T11 exactly ONE seat carries a verifier/QA role marker, so the grader auto-pick is unambiguous' \
  || bad_t 'T11 the QA marker is not unique — task add would skip the verifier rung and file rows with no grader' "count=$c"

# Negative control for T11: the counter must be able to SEE a duplicate.
dupe=$(jq -c '.agents.dario.role = "Engineer / Test"' <<<"$spec")
[[ "$(qa_count "$dupe")" == 2 ]] \
  && ok_t 'T11n negative control — the QA counter does detect a second marker (T11 is not vacuous)' \
  || bad_t 'T11n the QA counter cannot see a duplicate; T11 proves nothing' "count=$(qa_count "$dupe")"

# The engineer must not be told to wait on CI: deliver-on-push is the rule the
# maker seat exists to follow, and a template that omits it re-imports the
# polling cost into every customer box.
eng=$(jq -r '.agents.dario.instructions // ""' <<<"$spec")
grep -qi 'not on ci green' <<<"$eng" \
  && ok_t 'T12 the Engineer seat carries deliver-on-push' \
  || bad_t 'T12 the Engineer prompt does not carry deliver-on-push' ''
vfy=$(jq -r '.agents.vesper.instructions // ""' <<<"$spec")
grep -qi 'do not merge what you graded' <<<"$vfy" \
  && ok_t 'T13 the Verifier seat is told it does not merge what it graded' \
  || bad_t 'T13 the Verifier prompt does not separate grading from merging' ''
cto=$(jq -r '.agents.marcus.instructions // ""' <<<"$spec")
grep -qi 'does not merge unseen' <<<"$cto" \
  && ok_t 'T14 the CTO seat carries the user-facing-surface ship gate' \
  || bad_t 'T14 the CTO prompt does not carry the ship gate' ''

# DIVE-4103: `--auth-profile=` must not pass silently on a template that pins no
# account. Functional where it can be: the guard is a grep over the spec FILE, so
# the arm runs that same predicate over both shapes and requires it to separate
# them. A guard that answers the same for both is inert.
pins() { sed 's/[[:space:]]*#.*$//' "$1" 2>/dev/null | grep -q 'TEAM_AUTH_PROFILE'; }
if pins "$ROOT/team-templates/eng-studio.5dive.yaml" && ! pins "$TPL"; then
  ok_t 'T16 the inert-flag guard separates a template that pins an account from one that does not'
else
  bad_t 'T16 the --auth-profile guard cannot distinguish the two template shapes' "eng=$(pins "$ROOT/team-templates/eng-studio.5dive.yaml" && echo yes || echo no) deploy=$(pins "$TPL" && echo yes || echo no)"
fi
printf 'version: "2"\n# mentions ${TEAM_AUTH_PROFILE} only in a comment\nagents:\n  a:\n    type: claude\n' > "$TMP/comment-only.yaml"
pins "$TMP/comment-only.yaml" \
  && bad_t 'T16n a spec that names the var ONLY in a comment reads as pinned — the warning would be suppressed on exactly the template that needs it' '' \
  || ok_t 'T16n negative control — a comment mentioning the var does not count as a pin'
grep -q 'has no effect on this template' "$SRC" \
  && ok_t 'T16a `team import --auth-profile=` warns rather than passing silently (source-level arm)' \
  || bad_t 'T16a no warning on an inert --auth-profile' ''
# The flagless import must not be a hard error: an unset ${VAR} in a spec is
# fatal by design, so a one-tap template must reference none.
env -u TEAM_AUTH_PROFILE -u TEAM_TG_TOKEN bash -c ':' 2>/dev/null
if parse "$TPL" >/dev/null 2>&1; then
  ok_t 'T17 the template imports with NO env exported — the flagless one-tap path works'
else
  bad_t 'T17 deploy-team needs an env var set, so a one-tap dashboard import is a hard error' ''
fi

# Registry parity: `5dive team ls` reads the directory, but the marketplace
# index is what the dashboard renders. A template absent from it is invisible.
idx="$ROOT/team-templates/index.json"
if jq -e '.companies[] | select(.slug == "deploy-team")' "$idx" >/dev/null 2>&1; then
  ok_t 'T15 deploy-team is listed in the marketplace index'
  isize=$(jq -r '.companies[] | select(.slug=="deploy-team") | .size' "$idx")
  [[ "$isize" == "$n" ]] \
    && ok_t 'T15a the index roster size matches the template' \
    || bad_t 'T15a index size disagrees with the template' "index=$isize template=$n"
  ikeys=$(jq -r '[.companies[] | select(.slug=="deploy-team") | .roster[].key] | sort | join(",")' "$idx")
  tkeys=$(jq -r '[.agents | keys[]] | sort | join(",")' <<<"$spec")
  [[ "$ikeys" == "$tkeys" ]] \
    && ok_t 'T15b the index roster names the same four seats as the template' \
    || bad_t 'T15b index roster drifted from the template' "index=$ikeys template=$tkeys"
else
  bad_t 'T15 deploy-team is missing from team-templates/index.json — invisible to the marketplace' ''
fi

echo "-----"
printf 'passed=%d failed=%d\n' "$pass" "$fail"
(( fail == 0 ))
