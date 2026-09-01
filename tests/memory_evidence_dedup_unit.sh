#!/usr/bin/env bash
# DIVE-3106 unit harness for the two additive `memory add` mechanisms lifted
# (idea-derived, not code-derived) from TencentDB-Agent-Memory (MIT):
#
#   1. EVIDENCE BACK-REFS — --evidence=<kind>:<ref>, repeatable, structural, so
#      "re-verify this claim" is a mechanical walk instead of re-reading prose.
#      Plus the doctor's new evidence-ref check that walks file: targets.
#   2. WRITE-TIME DEDUP — advisory ONLY. It must WARN and STILL WRITE; a second
#      refusal on the same verb as the secret tripwire is exactly what lodar
#      ruled out on 2026-08-09.
#
# Both are ADDITIVE: a memory with no --evidence must be byte-identical to what
# pre-3106 `memory add` produced, and must not be flagged by the doctor. The
# negative controls below are the point of this harness, not decoration.
# Run: bash tests/memory_evidence_dedup_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/mem-ev-unit.XXXXXX)"

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

# DIVE-3885: `--type=reference` now requires a checkability decision at write
# time (--check=<cmd> or a recorded --no-check=<why>). These fixtures exercise
# evidence + dedup, not checkability, so they take the RECORDED opt-out — which
# is itself the point of that field: an unchecked fact is countable, not absent.
NC=(--no-check='DIVE-3106 evidence/dedup fixture — no real-world fact to re-derive')

# Isolated fake agent home so `--store=mine` resolves here and nothing touches
# the real store. _memory_add picks the dir that already has a MEMORY.md.
STORE="$TMP/home/.claude/projects/proj/memory"
mkdir -p "$STORE"; : > "$STORE/MEMORY.md"
export HOME="$TMP/home"

# add <args...> ; body on stdin. Subshell: `fail` exits, and we want the code.
add() { ( _memory_add "$@" ) ; }

BODY_A='The provisioning queue takes a postgres advisory lock so a second api
instance declines to dispatch instead of claiming queued rows and firing real
customer hetzner builds against the production database.'

echo "── evidence back-refs (own store) ──"
printf '%s\n' "$BODY_A" | add --name=ev-one --type=reference "${NC[@]}" \
  --description="advisory lock on the provision queue" \
  --evidence=file:src/cmd_memory.sh:586 --evidence=task:DIVE-3106 \
  --evidence="cmd:5dive task show DIVE-3106" >/dev/null 2>&1
check "add with --evidence exits 0" "$?" "0"
F="$STORE/reference_ev_one.md"
[ -f "$F" ] && ok "file written" || bad "file written"
grep -q '^  evidence:$' "$F" && ok "nested evidence: key under metadata" || bad "nested evidence: key under metadata"
grep -q '^    - "file:src/cmd_memory.sh:586"$' "$F" && ok "file: ref emitted" || bad "file: ref emitted"
grep -q '^    - "task:DIVE-3106"$' "$F" && ok "task: ref emitted" || bad "task: ref emitted"
grep -q '^    - "cmd:5dive task show DIVE-3106"$' "$F" && ok "cmd: ref emitted (spaces survive)" || bad "cmd: ref emitted"
check "all three refs, in order" "$(grep -c '^    - "' "$F")" "3"

echo "── --evidence validation refuses a ref that could not be walked ──"
for badref in "notakind:x" "file:" "task:dive-3106" "task:DIVE" "sha:zzzz" "url:ftp://x/y" "bare-string"; do
  printf '%s\n' "$BODY_A" | add --name=ev-bad --type=reference "${NC[@]}" --description=d \
    --evidence="$badref" >/dev/null 2>&1
  [ "$?" -ne 0 ] && ok "refused --evidence=$badref" || bad "refused --evidence=$badref"
done
[ -f "$STORE/reference_ev_bad.md" ] && bad "refusal wrote no file" || ok "refusal wrote no file"
for goodref in "file:a/b.ts" "task:DIVE-1" "sha:40fdcbf" "url:https://x/y" "run:abc123" "cmd:echo hi"; do
  printf '%s\n' "$BODY_A" | add --name=ev-ok --type=reference "${NC[@]}" --description=d \
    --evidence="$goodref" --force --no-dedup >/dev/null 2>&1
  [ "$?" -eq 0 ] && ok "accepted --evidence=$goodref" || bad "accepted --evidence=$goodref"
done

echo "── ADDITIVE: no --evidence ⇒ no evidence key at all (negative control) ──"
printf 'A wholly unrelated fact about caddy reverse proxy ports and shelld.\n' \
  | add --name=ev-none --type=reference "${NC[@]}" --description="nothing cited here" >/dev/null 2>&1
grep -qE '^ *evidence:' "$STORE/reference_ev_none.md" \
  && bad "absent --evidence leaves NO evidence key" || ok "absent --evidence leaves NO evidence key"
grep -q '^  provenance:' "$STORE/reference_ev_none.md" \
  && bad "no provenance key when unset" || ok "no provenance key when unset"

echo "── --provenance is untouched and coexists with --evidence ──"
printf '%s\n' "$BODY_A" | add --name=ev-both --type=reference "${NC[@]}" --description=d \
  --provenance="measured by main 2026-08-09" --evidence=task:DIVE-3106 \
  --no-dedup >/dev/null 2>&1
grep -q '^  provenance: "measured by main 2026-08-09"$' "$STORE/reference_ev_both.md" \
  && ok "--provenance still emitted verbatim" || bad "--provenance still emitted verbatim"
grep -q '^    - "task:DIVE-3106"$' "$STORE/reference_ev_both.md" \
  && ok "--evidence sits beside it" || bad "--evidence sits beside it"

echo "── write-time dedup: WARNS, and still writes (advisory, never refuses) ──"
ERR="$TMP/err.txt"
printf '%s\n' "$BODY_A" | add --name=ev-dup --type=reference "${NC[@]}" \
  --description="a near copy of ev-one" >/dev/null 2>"$ERR"
check "near-duplicate add still exits 0" "$?" "0"
[ -f "$STORE/reference_ev_dup.md" ] && ok "near-duplicate STILL WRITTEN" || bad "near-duplicate STILL WRITTEN"
grep -q 'near-duplicate' "$ERR" && ok "warned on stderr" || bad "warned on stderr ($(cat "$ERR"))"
grep -q 'reference_ev_one.md' "$ERR" && ok "names the overlapping file" || bad "names the overlapping file"

echo "── dedup negative control: a distinct body warns about nothing ──"
printf 'Caddy terminates tls on 443 and shelld owns the ssh recovery path for a
locked out box; unrelated vocabulary throughout this particular sentence.\n' \
  | add --name=ev-distinct --type=reference "${NC[@]}" --description=d >/dev/null 2>"$ERR"
grep -q 'near-duplicate' "$ERR" && bad "no warning on a distinct body" || ok "no warning on a distinct body"

echo "── --no-dedup silences the warning ──"
printf '%s\n' "$BODY_A" | add --name=ev-dup2 --type=reference "${NC[@]}" --description=d \
  --no-dedup >/dev/null 2>"$ERR"
grep -q 'near-duplicate' "$ERR" && bad "--no-dedup silences" || ok "--no-dedup silences"

echo "── --force update-in-place must not match ITSELF ──"
printf '%s\n' "$BODY_A" | add --name=ev-one --type=reference "${NC[@]}" --description=d \
  --force >/dev/null 2>"$ERR"
grep -q 'reference_ev_one.md' "$ERR" && bad "self not reported as its own dup" || ok "self not reported as its own dup"

echo "── REGRESSION: the secret tripwire still refuses, --force does not bypass ──"
printf 'the token is sk-abcdefghijklmnop and it is live\n' \
  | add --name=ev-secret --type=reference "${NC[@]}" --description=d --force >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "tripwire still refuses (with --force)" || bad "tripwire still refuses (with --force)"

echo "── wiki store: evidence is TOP-LEVEL, not nested ──"
# Point _memory_wiki_root at a fake wiki INSIDE $HOME so the real
# /home/claude/projects/5dive/community/wiki is never written by a test.
WIKI="$HOME/projects/5dive/community/wiki"; mkdir -p "$WIKI"; : > "$WIKI/index.md"
check "wiki root resolves inside the sandbox" "$(_memory_wiki_root)" "$WIKI"
printf '%s\n' "$BODY_A" | add --name=ev-wiki --store=wiki --description="w" \
  --evidence=file:src/cmd_memory.sh --evidence=task:DIVE-3106 >/dev/null 2>&1
check "wiki add exits 0" "$?" "0"
grep -q '^evidence:$' "$WIKI/ev-wiki.md" && ok "top-level evidence: key" || bad "top-level evidence: key"
grep -q '^  - "task:DIVE-3106"$' "$WIKI/ev-wiki.md" && ok "wiki ref emitted" || bad "wiki ref emitted"
grep -q '^updated: ' "$WIKI/ev-wiki.md" && ok "wiki frontmatter still closes correctly" || bad "wiki frontmatter still closes correctly"
python3 - "$WIKI/ev-wiki.md" <<'PYCHK' && ok "wiki frontmatter is parseable YAML-ish (evidence is a list)" || bad "wiki frontmatter parses"
import re,sys
t=open(sys.argv[1]).read()
fm=t.split("---")[1]
assert re.search(r'^evidence:\n(  - ".*"\n)+', fm, re.M), fm
PYCHK
printf '%s\n' "$BODY_A" | add --name=ev-wiki2 --store=wiki --description="w2" >/dev/null 2>&1
grep -qE '^ *evidence:' "$WIKI/ev-wiki2.md" && bad "wiki without --evidence has no key" || ok "wiki without --evidence has no key"

echo "── doctor: evidence-ref walks file: targets only ──"
CODE="$TMP/code"; mkdir -p "$CODE/src"; : > "$CODE/src/real_file.ts"
DS="$TMP/dstore"; mkdir -p "$DS"
cat > "$DS/reference_walkable.md" <<'EOF'
---
name: walkable
description: "d"
metadata:
  type: reference
  evidence:
    - "file:src/real_file.ts:12"
    - "task:DIVE-3106"
    - "cmd:5dive task show DIVE-3106"
    - "url:https://example.com/x"
---

A body long enough to be considered by the other checks in this scanner pass.
EOF
cat > "$DS/reference_dangling.md" <<'EOF'
---
name: dangling
description: "d"
metadata:
  type: reference
  evidence:
    - "file:src/deleted_file.ts:3"
---

Another body of prose that exists purely so the scanner has something to read.
EOF
cat > "$DS/reference_noevidence.md" <<'EOF'
---
name: noevidence
description: "d"
metadata:
  type: reference
---

A third body with no evidence key whatsoever, which must not be flagged at all.
EOF
SCAN=$(_memory_scan_json "$CODE" "$DS")
N_EV=$(printf '%s' "$SCAN" | jq '[.findings[]|select(.kind=="evidence-ref")]|length')
check "exactly one evidence-ref finding" "$N_EV" "1"
HIT=$(printf '%s' "$SCAN" | jq -r '[.findings[]|select(.kind=="evidence-ref")][0].file')
check "it is the dangling one" "$HIT" "reference_dangling.md"
MSG=$(printf '%s' "$SCAN" | jq -r '[.findings[]|select(.kind=="evidence-ref")][0].message')
case "$MSG" in *deleted_file.ts*) ok "message names the dead ref" ;; *) bad "message names the dead ref ($MSG)" ;; esac
SEV=$(printf '%s' "$SCAN" | jq -r '[.findings[]|select(.kind=="evidence-ref")][0].severity')
check "severity is warn, never error" "$SEV" "warn"
printf '%s' "$SCAN" | jq -e '[.findings[]|select(.file=="reference_noevidence.md" and .kind=="evidence-ref")]|length==0' >/dev/null \
  && ok "a memory with NO evidence is not flagged" || bad "a memory with NO evidence is not flagged"

echo "── doctor: no code-root ⇒ evidence-ref stays silent (no crying wolf) ──"
SCAN2=$(_memory_scan_json "" "$DS")
check "silent without a code-root" \
  "$(printf '%s' "$SCAN2" | jq '[.findings[]|select(.kind=="evidence-ref")]|length')" "0"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
