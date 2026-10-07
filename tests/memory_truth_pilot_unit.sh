#!/usr/bin/env bash
# DIVE-5816 unit harness for the MEMORY-TRUTH PILOT: every new memory on a pilot
# seat carries a check or an expiry, a nightly pass backfills + checks + logs one
# line, and "may be outdated" shows wherever the seat reads memory.
#
# Two seats, two HOMEs: PILOT has the switch file, OTHER does not. The arms
# that matter are the OTHER-seat ones — the row's hard requirement is that no
# seat but the pilot changes behaviour, so every pilot arm has a twin that
# proves the same call on OTHER writes no expiry and prints no new text. When
# the pre-change tree is reachable (BASE below), OTHER's search/get/router
# output is also diffed byte-for-byte against it.
#
# Run: bash tests/memory_truth_pilot_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/mem-truth-unit.XXXXXX)"

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
has()  { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1 (no '$2' in output)"; fi; }
hasnt(){ if grep -qF -- "$2" <<<"$3"; then bad "$1 ('$2' present)"; else ok "$1"; fi; }

TODAY=$(date -u +%F)
P60=$(date -u -d "$TODAY +60 days" +%F)
P30=$(date -u -d "$TODAY +30 days" +%F)

PILOT="$TMP/pilot"; OTHER="$TMP/other"
PSTORE="$PILOT/.claude/projects/proj/memory"; OSTORE="$OTHER/.claude/projects/proj/memory"
# A wiki under each HOME so no arm can reach the real shared wiki (see
# memory_check_field_unit.sh for why a fake HOME alone does not isolate it).
for h in "$PILOT" "$OTHER"; do mkdir -p "$h/.claude/projects/proj/memory" "$h/projects/5dive/community/wiki"; done
mkdir -p "$PILOT/.config/5dive"; : > "$PILOT/.config/5dive/memory-truth"
as() { local h="$1"; shift; ( export HOME="$h"; "$@" ); }

fm_val() { sed -n '/^---$/,/^---$/p' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" | head -1; }

echo "── switch: a file in the seat's own home, nothing else ──"
as "$PILOT" _memory_truth_on && ok "pilot seat reads ON" || bad "pilot seat reads ON"
as "$OTHER" _memory_truth_on && bad "other seat reads OFF" || ok "other seat reads OFF"
OUT=$(as "$OTHER" _memory_truth run --log="$TMP/o.log" 2>&1); RC=$?
[ "$RC" -ne 0 ] && ok "run refuses on a seat with the pilot off" || bad "run refuses on a seat with the pilot off"
[ -e "$TMP/o.log" ] && bad "a refused run wrote no log line" || ok "a refused run wrote no log line"

echo "── memory add: an unchecked fact on the pilot seat gets an expiry ──"
add() { local h="$1"; shift; ( export HOME="$h"; printf 'Widgets ship from the east depot on Tuesdays only.\n' | _memory_add --no-dedup "$@" ) >/dev/null 2>&1; }
add "$PILOT" --name=plain-fact --type=project --description="widgets ship tuesdays"
check "pilot: add with no check → valid_to today+60" "$(fm_val "$PSTORE/project_plain_fact.md" valid_to)" "$P60"
add "$OTHER" --name=plain-fact --type=project --description="widgets ship tuesdays"
check "other: the same add writes no valid_to" "$(fm_val "$OSTORE/project_plain_fact.md" valid_to)" ""
add "$PILOT" --name=nocheck-fact --type=reference --description="depot hours" --no-check="no command can see the depot"
check "pilot: --no-check alone is not enough → valid_to today+60" "$(fm_val "$PSTORE/reference_nocheck_fact.md" valid_to)" "$P60"
add "$PILOT" --name=checked-fact --type=reference --description="the repo has a readme" --check='test -f /etc/hostname'
check "pilot: a fact WITH a check gets no expiry" "$(fm_val "$PSTORE/reference_checked_fact.md" valid_to)" ""
add "$PILOT" --name=dated-fact --type=project --description="explicit expiry wins" --valid-to=2027-01-01
check "pilot: an explicit --valid-to wins" "$(fm_val "$PSTORE/project_dated_fact.md" valid_to)" "2027-01-01"
add "$PILOT" --name=wiki-page --store=wiki --description="a shared page"
check "pilot: the shared wiki stays out of the pilot" "$(fm_val "$PILOT/projects/5dive/community/wiki/wiki-page.md" valid_to)" ""

echo "── memory consolidate: an auto-written atom gets valid_to today+30 ──"
mk_session() { # <home>
  local d="$1/.claude/projects/proj"
  python3 - "$d/sess-5816.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    fh.write(json.dumps({"type": "user", "message": {"role": "user", "content": "the depot moved to the north yard"}}) + "\n")
    fh.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Noted."}]}}) + "\n")
PY
  touch -d '3 hours ago' "$d/sess-5816.jsonl"
}
DIST="$TMP/distiller.sh"
cat > "$DIST" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo '{"atoms":[{"type":"project","name":"depot-moved-north","description":"the depot moved to the north yard","body":"The depot moved to the north yard in October.","confidence":"high"}]}'
SH
chmod +x "$DIST"
for h in "$PILOT" "$OTHER"; do mk_session "$h"; as "$h" _memory_consolidate --distiller="$DIST" --max-sessions=1 >/dev/null 2>&1; done
F="$PSTORE/project_depot_moved_north.md"
[ -f "$F" ] && ok "pilot: consolidate wrote its atom" || bad "pilot: consolidate wrote its atom"
check "pilot: consolidate atom → valid_to today+30" "$(fm_val "$F" valid_to)" "$P30"
F="$OSTORE/project_depot_moved_north.md"
[ -f "$F" ] && ok "other: consolidate wrote its atom" || bad "other: consolidate wrote its atom"
check "other: consolidate atom has NO valid_to" "$(fm_val "$F" valid_to)" ""

echo "── truth run: backfill from each atom's OWN date, mtime kept, nothing deleted ──"
mk_old() { # <store> — an old hand-written atom (harness-written: no compiled_at) and a stale-check one
  printf -- '---\nname: old-depot\ndescription: "the depot is in the south yard"\nmetadata:\n  type: project\n---\n\nThe depot is in the south yard.\n' > "$1/project_old_depot.md"
  touch -d '2026-01-10 12:00' "$1/project_old_depot.md"
  printf -- '---\nname: dated-old\ndescription: "a compiled fact about gates"\nmetadata:\n  type: feedback\n  compiled_at: 2026-02-01\n---\n\nGates close at six.\n' > "$1/feedback_dated_old.md"
  printf -- '---\nname: red-check\ndescription: "the marker file for gates exists"\nmetadata:\n  type: reference\n  check: "test -f /nonexistent/dive-5816-marker"\n---\n\nThe gates marker file exists.\n' > "$1/reference_red_check.md"
  printf 'a pointer file with no frontmatter about gates\n' > "$1/other_pointer.md"
  cat > "$1/MEMORY.md" <<'EOF'
# Memory router (seat) — test
<!-- router:generated -->

<!-- router:keep-start -->
**Pinned:** [south yard](project_old_depot.md) · [gates marker](reference_red_check.md) · [north yard](project_depot_moved_north.md)
<!-- router:keep-end -->
EOF
}
mk_old "$PSTORE"; mk_old "$OSTORE"
MT_BEFORE=$(stat -c %Y "$PSTORE/project_old_depot.md")
PTR_BEFORE=$(sha256sum < "$PSTORE/other_pointer.md")
N_BEFORE=$(find "$PSTORE" -name '*.md' | wc -l)
OUT=$(as "$PILOT" _memory_truth run --log="$TMP/p.log" 2>&1); RC=$?
check "run exits 0 even with a stale fact (a result, not a crash)" "$RC" "0"
check "mtime-dated atom → its mtime date + 60" "$(fm_val "$PSTORE/project_old_depot.md" valid_to)" "2026-03-11"
check "compiled_at atom → compiled_at + 60" "$(fm_val "$PSTORE/feedback_dated_old.md" valid_to)" "2026-04-02"
check "a checked atom gets no expiry" "$(fm_val "$PSTORE/reference_red_check.md" valid_to)" ""
check "the check ran and stamped stale" "$(fm_val "$PSTORE/reference_red_check.md" check_status)" "stale"
check "an atom that already had an expiry is untouched" "$(fm_val "$PSTORE/project_depot_moved_north.md" valid_to)" "$P30"
check "mtime preserved (the router ranks newest by it)" "$(stat -c %Y "$PSTORE/project_old_depot.md")" "$MT_BEFORE"
check "no-frontmatter file left byte-identical" "$(sha256sum < "$PSTORE/other_pointer.md")" "$PTR_BEFORE"
check "nothing deleted" "$(find "$PSTORE" -name '*.md' | wc -l)" "$N_BEFORE"
grep -q 'The depot is in the south yard.' "$PSTORE/project_old_depot.md" && ok "body intact" || bad "body intact"
check "wiki untouched by the run" "$(fm_val "$PILOT/projects/5dive/community/wiki/wiki-page.md" check_status)" ""

echo "── the log line: one line, the counts the pilot is judged on ──"
check "exactly one line appended" "$(wc -l < "$TMP/p.log" | tr -d ' ')" "1"
L=$(cat "$TMP/p.log")
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z seat=[a-z0-9._-]+ atoms=[0-9]+ fresh=[0-9]+ stale=[0-9]+ unknown=[0-9]+ expired=[0-9]+ no_check=[0-9]+ ' <<<"$L" \
  && ok "line shape: date seat fresh stale unknown expired no_check" || bad "line shape (got: $L)"
has "stale=1 (the red check)" " stale=1 " "$L"
has "fresh=1 (the green check)" " fresh=1 " "$L"
has "expired=2 (both backfilled old atoms)" " expired=2 " "$L"
has "no_frontmatter counted, not rewritten" " no_frontmatter=1 " "$L"

echo "── idempotent: a second run sweeps nothing and changes no file ──"
SUM1=$(cd "$PSTORE" && find . -name '*.md' -exec sha256sum {} + | sort)
as "$PILOT" _memory_truth run --log="$TMP/p.log" >/dev/null 2>&1
SUM2=$(cd "$PSTORE" && find . -name '*.md' -exec sha256sum {} + | sort)
check "store byte-identical across a re-run" "$SUM2" "$SUM1"
has "second line says swept=0" " swept=0 " "$(tail -1 "$TMP/p.log")"
OUT=$(as "$PILOT" _memory_truth run --dry-run --log="$TMP/p.log" 2>&1)
check "--dry-run appends no line" "$(wc -l < "$TMP/p.log" | tr -d ' ')" "2"

echo "── 'may be outdated' where the pilot seat READS: router, search, get ──"
IDX=$(cat "$PSTORE/MEMORY.md")
has "router: pinned EXPIRED line flagged" "(project_old_depot.md) ⚠ may be outdated (expired 2026-03-11)" "$IDX"
has "router: pinned CHECK-RED line flagged" "(reference_red_check.md) ⚠ may be outdated (check red $TODAY)" "$IDX"
hasnt "router: an in-date pinned line is NOT flagged" "(project_depot_moved_north.md) ⚠" "$IDX"
R=$(as "$PILOT" _memory_router --root="$PSTORE" 2>/dev/null)
has "router regen: keep-block flag survives (stripped + re-applied, not doubled)" "(project_old_depot.md) ⚠ may be outdated (expired 2026-03-11) ·" "$R"
check "router regen: pinned line carries exactly its 2 markers (none doubled)" "$(grep '^\*\*Pinned' <<<"$R" | grep -o 'may be outdated' | wc -l | tr -d ' ')" "2"
grep -qE '^- `old-depot` ⚠ may be outdated \(expired 2026-03-11\)' <<<"$R" && ok "router regen: newest-list line flagged" || bad "router regen: newest-list line flagged"
S=$(as "$PILOT" _memory_search --roots="$PSTORE" depot south yard --index 2>/dev/null)
has "search --index: expired atom says may be outdated" "old-depot  ·mine  [⚠ may be outdated (expired 2026-03-11)" "$S"
S=$(as "$PILOT" _memory_search --roots="$PSTORE" gates marker file 2>/dev/null)
has "search: check-red atom says may be outdated" "⚠ may be outdated (check red $TODAY)" "$S"
G=$(as "$PILOT" _memory_get --roots="$PSTORE" old-depot red-check 2>/dev/null)
has "get: expired atom warned above its body" "⚠ may be outdated (expired 2026-03-11) — re-verify before acting on it." "$G"
has "get: check-red atom warned above its body" "⚠ may be outdated (check red $TODAY) — re-verify before acting on it." "$G"
G=$(as "$PILOT" _memory_get --roots="$PSTORE" depot-moved-north 2>/dev/null)
hasnt "get: an in-date atom carries no warning" "may be outdated" "$G"

echo "── the same reads on OTHER: no new text, legacy flags unchanged ──"
# Give OTHER the same red/expired state by hand (it has no truth run).
sed -i 's/^  type: project$/  type: project\n  valid_to: 2026-03-11/' "$OSTORE/project_old_depot.md"
sed -i 's/^  check: \(.*\)$/  check: \1\n  check_status: stale\n  checked_at: '"$TODAY"'/' "$OSTORE/reference_red_check.md"
OS=$(as "$OTHER" _memory_search --roots="$OSTORE" depot south yard --index 2>/dev/null)
hasnt "other search: no 'may be outdated'" "may be outdated" "$OS"
has "other search: the legacy flag text is unchanged" "[⚠ expired 2026-03-11]" "$OS"
OG=$(as "$OTHER" _memory_get --roots="$OSTORE" old-depot red-check 2>/dev/null)
hasnt "other get: no warning line" "may be outdated" "$OG"
OR=$(as "$OTHER" _memory_router --root="$OSTORE" 2>/dev/null)
hasnt "other router: no marker" "may be outdated" "$OR"
OIDX_BEFORE=$(sha256sum < "$OSTORE/MEMORY.md")
as "$OTHER" _memory_router --root="$OSTORE" --annotate-only >/dev/null 2>&1
check "other router --annotate-only: MEMORY.md byte-identical" "$(sha256sum < "$OSTORE/MEMORY.md")" "$OIDX_BEFORE"

# Byte-for-byte against the pre-change tree, when this checkout can reach it.
BASE=a0b0c2fb
if git cat-file -e "$BASE:src/cmd_memory.sh" 2>/dev/null; then
  git show "$BASE:src/cmd_memory.sh" > "$TMP/base_memory.sh"
  base() { ( export HOME="$OTHER"; source "$TMP/base_memory.sh"; "$@" ) 2>/dev/null; }
  check "other search --index == pre-change tree" "$OS" "$(base _memory_search --roots="$OSTORE" depot south yard --index)"
  check "other search == pre-change tree" "$(as "$OTHER" _memory_search --roots="$OSTORE" gates marker file 2>/dev/null)" "$(base _memory_search --roots="$OSTORE" gates marker file)"
  check "other get == pre-change tree" "$OG" "$(base _memory_get --roots="$OSTORE" old-depot red-check)"
  check "other router == pre-change tree" "$OR" "$(base _memory_router --root="$OSTORE")"
else
  echo "  skip — pre-change tree $BASE not in this checkout (shallow clone); the structural arms above still ran"
fi

echo "── off again: markers come out, files keep their expiries ──"
as "$PILOT" _memory_truth off >/dev/null
as "$PILOT" _memory_router --root="$PSTORE" --annotate-only >/dev/null 2>&1
hasnt "switch off + re-flag strips every marker" "may be outdated" "$(cat "$PSTORE/MEMORY.md")"
check "the expiry written while on stays in the file" "$(fm_val "$PSTORE/project_old_depot.md" valid_to)" "2026-03-11"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
