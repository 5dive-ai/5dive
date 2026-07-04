#!/usr/bin/env bash
# OSS-8 guard: lib/tasks_db.sh intentionally defines some tables TWICE — the
# canonical schema in _tasks_schema() (applied to fresh DBs) and a copy inside
# a one-shot, gated migration block in _tasks_db_migrate() (applied to existing
# DBs that predate the table). Only one of the two ever runs on a given box, so
# if the copies diverge, fresh boxes and migrated boxes end up with silently
# different schemas. This test fails the moment any duplicated CREATE TABLE
# definition stops being identical (comments/whitespace ignored).
# Run: bash tests/schema_sync_unit.sh   (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip - python3 not available"; exit 0; }

python3 - <<'EOF'
import re, sys
src = open('src/lib/tasks_db.sh').read()
blocks = re.findall(r'(CREATE TABLE IF NOT EXISTS (\w+) \((?:[^;]*?)\);)', src, re.S)
seen, fail = {}, 0
for blk, name in blocks:
    norm = re.sub(r'--[^\n]*', '', blk)
    norm = re.sub(r'\s+', ' ', norm).strip()
    seen.setdefault(name, []).append(norm)
for name, defs in sorted(seen.items()):
    if len(defs) == 1:
        continue
    if len(set(defs)) == 1:
        print(f"ok   - {name}: {len(defs)} definitions identical")
    else:
        fail += 1
        print(f"FAIL - {name}: definitions diverged between _tasks_schema and _tasks_db_migrate")
        import difflib
        for line in difflib.unified_diff(defs[0].split(','), defs[1].split(','), lineterm=''):
            if line.startswith(('+', '-')) and not line.startswith(('+++', '---')):
                print("      " + line)
print("-----")
print(f"schema_sync_unit: {len([d for d in seen.values() if len(d) > 1]) - fail} in sync, {fail} diverged")
sys.exit(1 if fail else 0)
EOF
