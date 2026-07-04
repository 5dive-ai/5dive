#!/usr/bin/env bash
# DIVE-992 isolated unit harness for the recall + compile tick-prompt injections.
#
# Exercises the two pure helpers added to cmd_heartbeat.sh:
#   _hb_is_knowledge_task  — keyword sniff over title+body
#   _hb_recall_cite        — compact single-line memory citation, best-effort
# Both are prompt-injection-into-tick surfaces that share the _hb_wake seam.
# Asserts: knowledge-shaped text is detected and plain build text is not; the
# recall citation surfaces a seeded memory hit as a single line, cites the
# heading, and degrades to empty (never errors) on no-query / no-store.
# Run: bash tests/heartbeat_recall_compile_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-recall-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_memory.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e   # header.sh enabled set -e; asserts below probe non-zero paths

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---- _hb_is_knowledge_task ------------------------------------------------
_hb_is_knowledge_task "Competitor research digest on A2A vendors" \
  && ok_t "knowledge: research/digest text detected" \
  || bad_t "knowledge: research/digest text detected" "should match"

_hb_is_knowledge_task "market scan of loop marketplaces, write-up to wiki" \
  && ok_t "knowledge: market scan / write-up detected" \
  || bad_t "knowledge: market scan / write-up detected" "should match"

if _hb_is_knowledge_task "Fix the sqlite lock in cmd_agent create-path"; then
  bad_t "knowledge: plain build task NOT flagged" "false positive"
else
  ok_t "knowledge: plain build task NOT flagged"
fi

# ---- _hb_recall_cite ------------------------------------------------------
# Seed a tiny memory store and point the recall search at it via --roots by
# shadowing _memory_default/own roots through a temp HOME store. Simplest: build
# a store dir and call _memory_search directly through _hb_recall_cite's path by
# overriding _memory_own_roots for a throwaway agent name.
STORE="$TMP/.claude/projects/proj/memory"
mkdir -p "$STORE"
cat > "$STORE/nginx-dotfile.md" <<'MD'
---
name: nginx-dotfile-deny
description: nginx dotfile-deny 404s all /.well-known dotpaths on api.5dive.com
---
# nginx dotfile deny blocks well-known
The location ~ /\. rule 404s every dotpath including agent-card.json.
MD

# Override the root resolver so --agent=probe maps to our throwaway store.
_memory_own_roots() { echo "$STORE"; }
_memory_wiki_root() { echo ""; }

cite=$(_hb_recall_cite "probe" "nginx well-known agent card dotfile" 3)
if [[ -n "$cite" && "$cite" == *"nginx"* && "$cite" != *$'\n'* ]]; then
  ok_t "recall: seeded hit cited on one line ($cite)"
else
  bad_t "recall: seeded hit cited on one line" "got: [$cite]"
fi

empty=$(_hb_recall_cite "probe" "" 3)
[[ -z "$empty" ]] && ok_t "recall: empty query -> empty (no error)" \
  || bad_t "recall: empty query -> empty" "got: [$empty]"

# A query with zero lexical overlap must yield empty, not error.
none=$(_hb_recall_cite "probe" "zzzqqxx nomatch token" 3)
[[ -z "$none" ]] && ok_t "recall: no-hit query -> empty (no error)" \
  || bad_t "recall: no-hit query -> empty" "got: [$none]"

echo
printf 'tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
