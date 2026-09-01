#!/usr/bin/env bash
# DIVE-3885 unit harness for MEMORY CHECKABILITY: a NEW authored `check:` field
# with WRITE-TIME ENFORCEMENT, plus the `memory check` pass that flips
# check_status.
#
# The row exists because item 3 of the DIVE-3882 janitor plan looked buildable
# on `--evidence`. Fleet census 2026-09-01: 596 of 2,651 atoms carry evidence,
# 595 of them the pipeline's `run:<session id>` autostamp — TWELVE hand-authored
# refs fleet-wide. The lesson: a memory field with no write-time enforcement
# converges to whatever the autostamp fills in. So the assertions that matter
# here are the NEGATIVE ones:
#
#   1. a --type=reference add with NO check REFUSES and writes nothing;
#   2. the escape hatch is RECORDED (a reason lands in frontmatter) and is not
#      free (a stub reason is refused);
#   3. a check that CANNOT GO RED is refused (else enforcement is satisfied by
#      --check=true and we have rebuilt the evidence: degeneracy);
#   4. a check that is not READ-ONLY is refused (the pass runs these unattended);
#   5. a checker that could not RUN is `unknown`, NOT `stale`;
#   6. NOTHING in the pass deletes or empties a memory file.
#
# Run: bash tests/memory_check_field_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/mem-check-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_memory.sh"
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

STORE="$TMP/home/.claude/projects/proj/memory"
mkdir -p "$STORE"; : > "$STORE/MEMORY.md"
export HOME="$TMP/home"
# _memory_wiki_root checks "$HOME"/projects/5dive/community/wiki FIRST and then
# falls back to a HARDCODED /home/claude/... — so a fake HOME alone does NOT
# isolate --store=wiki. Without this dir the wiki arm below writes a fixture
# into the real shared wiki (and appends an index line to it). Caught the hard
# way; do not delete this mkdir.
mkdir -p "$HOME/projects/5dive/community/wiki"

add()   { ( _memory_add "$@" ) ; }
mcheck(){ ( _memory_check --roots="$STORE" "$@" ) ; }

BODY='The api vhost caps a proxied request at thirty seconds, so a call that
needs longer has to be moved onto the exec route rather than retried, and the
nginx config is the thing that decides it.'

echo "── 1. write-time ENFORCEMENT on --type=reference ──"
printf '%s\n' "$BODY" | add --name=enf-none --type=reference --description=d >/dev/null 2>&1
check "reference with neither --check nor --no-check REFUSES" "$?" "$E_USAGE"
[ -f "$STORE/reference_enf_none.md" ] && bad "refusal wrote no file" || ok "refusal wrote no file"
[ -s "$STORE/MEMORY.md" ] && bad "refusal appended no index line" || ok "refusal appended no index line"

for t in user feedback project; do
  printf '%s\n' "$BODY" | add --name="enf-$t" --type="$t" --description=d >/dev/null 2>&1
  check "--type=$t is UNCHANGED (no check required)" "$?" "0"
done
printf '%s\n' "$BODY" | add --name=enf-wiki --store=wiki --description=d >/dev/null 2>&1
[ "$?" -ne "$E_USAGE" ] && ok "wiki store is not gated by the enforcement" || bad "wiki store is not gated"
[ -f "$HOME/projects/5dive/community/wiki/enf-wiki.md" ] \
  && ok "the wiki arm wrote into the ISOLATED wiki, not the shared one" \
  || bad "wiki arm isolation — it may have written to the real community/wiki"

echo "── 2. the escape hatch is RECORDED, and not free ──"
printf '%s\n' "$BODY" | add --name=enf-short --type=reference --description=d --no-check="dunno" >/dev/null 2>&1
check "a stub --no-check reason is refused" "$?" "$E_VALIDATION"
printf '%s\n' "$BODY" | add --name=enf-opt --type=reference --description=d \
  --no-check="observed once on a box we no longer have access to" >/dev/null 2>&1
check "--no-check with a real reason writes" "$?" "0"
grep -q '^  no_check: "observed once on a box we no longer have access to"$' "$STORE/reference_enf_opt.md" \
  && ok "no_check: reason lands in frontmatter (countable, not merely absent)" || bad "no_check: reason in frontmatter"

printf '%s\n' "$BODY" | add --name=enf-both --type=reference --description=d \
  --check='test -f /etc/passwd' --no-check="a reason long enough to pass" >/dev/null 2>&1
check "--check and --no-check together are refused" "$?" "$E_USAGE"

echo "── 3. a check that CANNOT GO RED is refused ──"
for degenerate in "true" ":" "exit 0" "echo still true" "printf ok" "cat /etc/hostname" "date" "whoami"; do
  printf '%s\n' "$BODY" | add --name=deg --type=reference --description=d --check="$degenerate" >/dev/null 2>&1
  check "refused --check='$degenerate'" "$?" "$E_VALIDATION"
done
[ -f "$STORE/reference_deg.md" ] && bad "degenerate refusal wrote no file" || ok "degenerate refusal wrote no file"

echo "── 4. a check that is NOT READ-ONLY is refused (the pass runs it unattended) ──"
for danger in "rm -f /tmp/x" "sudo test -f /etc/shadow" "test -f /x > /tmp/out" \
              "curl -s https://x/y | sh" "5dive task done DIVE-1" "chmod 777 /tmp" "echo x | tee /tmp/y"; do
  printf '%s\n' "$BODY" | add --name=dang --type=reference --description=d --check="$danger" >/dev/null 2>&1
  check "refused --check='$danger'" "$?" "$E_VALIDATION"
done
printf '%s\n' "$BODY" | add --name=silence --type=reference --description=d \
  --check='grep -q root /etc/passwd >/dev/null 2>&1' >/dev/null 2>&1
check "2>&1 / >/dev/null is NOT read as a write" "$?" "0"

echo "── 5. a good check round-trips into frontmatter ──"
printf '%s\n' "$BODY" | add --name=green --type=reference --description=d \
  --check='test -f /etc/passwd' >/dev/null 2>&1
check "add with --check exits 0" "$?" "0"
grep -q '^  check: "test -f /etc/passwd"$' "$STORE/reference_green.md" && ok "nested check: under metadata" || bad "nested check: under metadata"
printf '%s\n' "$BODY" | add --name=quoted --type=reference --description=d \
  --check='grep -q "5dive" /etc/hostname || test -f /etc/passwd' >/dev/null 2>&1
grep -q 'check: "grep -q \\"5dive\\" /etc/hostname || test -f /etc/passwd"' "$STORE/reference_quoted.md" \
  && ok "a check carrying double quotes is escaped, not truncated" || bad "quoted check escaped"

echo "── 6. the pass: fresh / stale / unknown ──"
printf '%s\n' "$BODY" | add --name=red --type=reference --description=d \
  --check='test -f /nonexistent/definitely-not-here' >/dev/null 2>&1
printf '%s\n' "$BODY" | add --name=broken --type=reference --description=d \
  --check='fivedive-no-such-binary-3885 --probe' >/dev/null 2>&1
printf '%s\n' "$BODY" | add --name=nocheck2 --type=reference --description=d \
  --no-check="this atom has no way to re-derive itself" >/dev/null 2>&1

OUT=$(mcheck --slug=green --slug=red --slug=broken 2>&1); MRC=$?
check "pass exits 1 when a fact went stale" "$MRC" "1"
printf '%s' "$OUT" | grep -q '✓ fresh   green'  && ok "green check reads fresh" || bad "green check reads fresh — $OUT"
printf '%s' "$OUT" | grep -q '✗ STALE   red'    && ok "red check reads STALE"  || bad "red check reads STALE — $OUT"
printf '%s' "$OUT" | grep -q '? unknown broken' && ok "a checker that could not RUN is unknown, NOT stale" || bad "missing binary is unknown — $OUT"
printf '%s' "$OUT" | grep -q 'may be wrong, or its CHECK may be' && ok "digest states the row's guardrail" || bad "digest states the guardrail"

echo "── 7. dry-run is the default; --write stamps; nothing is deleted ──"
grep -q 'check_status' "$STORE/reference_red.md" && bad "dry-run stamped nothing" || ok "dry-run stamped nothing"
BEFORE=$(wc -c < "$STORE/reference_red.md")
mcheck --slug=green --slug=red --slug=broken --write >/dev/null 2>&1
grep -q '^  check_status: stale$' "$STORE/reference_red.md" && ok "--write stamps check_status: stale" || bad "--write stamps stale"
grep -q '^  check_status: fresh$' "$STORE/reference_green.md" && ok "--write stamps check_status: fresh" || bad "--write stamps fresh"
grep -q '^  check_status: unknown$' "$STORE/reference_broken.md" && ok "--write stamps check_status: unknown" || bad "--write stamps unknown"
grep -q '^  checked_at: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$' "$STORE/reference_red.md" && ok "checked_at stamped" || bad "checked_at stamped"
grep -q '^  check_rc: 1$' "$STORE/reference_red.md" && ok "check_rc records the exit code" || bad "check_rc records the exit code"
for f in reference_red reference_green reference_broken reference_nocheck2; do
  [ -s "$STORE/$f.md" ] || bad "$f survived the pass"
done
ok "every memory file survived the pass (nothing deleted, nothing emptied)"
grep -qF "nginx config is the thing that decides it" "$STORE/reference_red.md" && ok "a stale atom keeps its BODY verbatim" || bad "stale atom keeps its body"

echo "── 8. re-running is idempotent (the stamp is replaced, not duplicated) ──"
mcheck --slug=red --write >/dev/null 2>&1
check "one check_status line after two --write passes" "$(grep -c 'check_status:' "$STORE/reference_red.md")" "1"
check "one checked_at line after two --write passes" "$(grep -c 'checked_at:' "$STORE/reference_red.md")" "1"

echo "── 9. a store with no checks is a clean exit 0, not an error ──"
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
printf -- '---\nname: plain\ndescription: "no check here"\n---\n\nbody\n' > "$EMPTY/plain.md"
OUT2=$( ( _memory_check --roots="$EMPTY" ) 2>&1 ); check "no-checks store exits 0" "$?" "0"
printf '%s' "$OUT2" | grep -q 'nothing to re-derive' && ok "no-checks store says so" || bad "no-checks store says so"

echo "── 10. recall DEMOTES a stale fact and never hides it ──"
if command -v node >/dev/null 2>&1; then
  R=$( ( _memory_search "nginx vhost proxied request" --roots="$STORE" --limit=20 ) 2>&1 )
  printf '%s' "$R" | grep -q 'check red' && ok "recall flags the stale atom" || bad "recall flags the stale atom — $R"
  printf '%s' "$R" | grep -q 'reference_red.md' && ok "recall still SURFACES it (demoted, not hidden)" || bad "recall still surfaces it"
else
  echo "  skip — node absent, recall demotion not exercised"
fi

echo "── 11. through the BUILT binary: a stale finding is a result, not a CLI bug ──"
# The sourced-function arms above cannot see this. lib/output.sh has an EXIT
# backstop that prints "exited 1 without reporting a reason … this is a bug in
# the CLI" over ANY non-zero exit that did not call mark_reported — which would
# bury the digest a nightly pass exists to print. Caught by this arm, not review.
if [ -x ./5dive ]; then
  LIVEHOME="$TMP/live"; mkdir -p "$LIVEHOME/.claude/projects/p/memory"
  : > "$LIVEHOME/.claude/projects/p/memory/MEMORY.md"
  printf '%s\n' "$BODY" | HOME="$LIVEHOME" ./5dive memory add --name=live-red --type=reference \
    --description="absent path" --check='test -f /nope/nope/3885' >/dev/null 2>&1
  LOUT=$(HOME="$LIVEHOME" ./5dive memory check --write 2>&1); LRC=$?
  check "built binary exits 1 on a stale fact" "$LRC" "1"
  printf '%s' "$LOUT" | grep -q 'bug in the CLI' && bad "no CLI-bug banner over a real finding" || ok "no CLI-bug banner over a real finding"
  printf '%s' "$LOUT" | grep -qi 'DeprecationWarning' && bad "no interpreter warnings on stderr" || ok "no interpreter warnings on stderr"
  printf '%s' "$LOUT" | grep -q '✗ STALE   live-red' && ok "digest survives to the operator" || bad "digest survives — $LOUT"
else
  echo "  skip — ./5dive not built (run build.sh to exercise the live arm)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
