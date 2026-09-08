#!/usr/bin/env bash
# DIVE-4067 — the SELF-REFERENCING DECLARATION scanner.
#
# WHAT IT CLOSES, and it is not hypothetical. On 2026-09-07 the 23:00 nightly
# installed 0.26.1 on every box and every agent on those boxes stopped. One line,
# added by DIVE-4036 to `5dive-agent-start`:
#
#     local dir="$HOME/.5dive" f="$dir/delivery.env" tmp
#
# `local` is a BUILTIN. Bash expands all of its arguments before performing any of
# its assignments, so the `$dir` in the second word is resolved against the
# ENCLOSING scope — not against the `dir=` standing next to it. In a function with
# no caller-side `dir`, under the launcher's `set -euo pipefail`, that is a fatal
# `dir: unbound variable` before the pane is ever started. Every agent unit failed
# identically, systemd gave up, and `5dive agent list` read `failed` for all of
# them. The nightly updater restarts agents after installing, so a bad release on
# disk became a dark box with no human in the loop.
#
# WHY NOTHING CAUGHT IT, and this is the whole argument for a scanner:
#   * `bash -n` ACCEPTS it. The syntax is valid; the defect is in evaluation order.
#   * The unit corpus never runs the launcher — it grades functions it sources.
#   * install-smoke installs the bundle; it does not START an agent and watch it
#     stay up, so a launcher that exits 1 on line 1687 reads as a clean install.
#   * `5dive doctor` hashes /usr/local/bin/5dive and reported `cli-provenance` OK
#     while the launcher beside it was fatal — the launcher is not in that hash.
#
# WHY A CORPUS SCAN AND NOT THE ONE-LINE FIX. The one line was fixed in the same
# commit as this file. Then this scanner was run over the shipped shell for the
# first time and found THREE MORE live instances of the identical shape —
# `5dive-stage-fork-plugins.sh` twice and `write_admin_sudoers()` in
# `src/cmd_agent_create.sh`, which composes the path of a file it writes into
# /etc/sudoers.d. All three were surviving on luck: each one's caller happens to
# hold a variable of the same name carrying the same value, so bash's DYNAMIC
# scoping resolves them correctly by coincidence. Rename a caller's loop variable
# and `write_admin_sudoers` starts writing an admin NOPASSWD grant to a path
# derived from some other agent's name. That is the argument: the shape is not
# rare, it is invisible in review, and whether a given instance is fatal today is
# decided by a caller in another file.
#
#   Usage:  scripts/local-selfref-scan.sh [--no-canary] [FILES...]
#   Exit:   0 = clean   1 = findings   2 = COULD NOT SCAN
#
# THE CANARY IS THE POINT, not garnish — same reason scripts/actionlint-scan.sh
# carries one. Every failure mode of a text scanner (python missing, a target glob
# that matches nothing after a rename, a regex that stopped matching) presents as
# "no findings", which is indistinguishable from a clean tree. So before the real
# targets are read, the scanner is run against a fixture carrying the DIVE-4067
# defect and a fixture known to be correct, and it must reject the first and
# accept the second. If it cannot, this exits 2 and grades nothing.
#
# EXIT 2 IS A THIRD OUTCOME, deliberately: "I could not tell" is neither pass nor
# fail, and folding it into either is the class this repo keeps re-learning
# (tests/lib/grading_tree.sh, DIVE-2274). An empty target set is exit 2 for the
# same reason — a rename of `src/` must not read as "clean".
#
# SCOPE, and the boundary is deliberate. SHIPPED shell only: the launcher, the
# installer, the bundle inputs under src/, the host scripts, and scripts/ itself.
# Not tests/ — a self-referencing `local` in a harness is still a bug, but it
# fails where someone is looking, and reding every PR on 270 files of pre-existing
# harness debt would get this guard disabled inside a week. Pass the files
# explicitly to scan anything outside the default set.
set -uo pipefail

CANARY=1
declare -a ARGS=()
for a in "$@"; do
  case "$a" in
    --no-canary) CANARY=0 ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
command -v python3 >/dev/null 2>&1 || {
  echo "local-selfref-scan: python3 not found — CANNOT SCAN" >&2; exit 2; }

# The scanner core. Reads file paths on argv, prints one finding per line,
# exits 0 clean / 1 findings / 2 could-not-scan. Quote-aware on both sides: a
# single-quoted value does not expand, and a word split must not break inside
# quotes or the name list comes out wrong.
read -r -d '' CORE <<'PYEOF' || true
import re, sys

DECL = re.compile(r'^[ \t]*(?:local|declare|typeset|export|readonly)\b')
NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*\Z')

def words(stmt):
    """Split a declaration statement into shell-ish words, respecting quotes."""
    out, cur, q, i = [], '', None, 0
    while i < len(stmt):
        c = stmt[i]
        if q:
            cur += c
            if c == '\\' and q == '"' and i + 1 < len(stmt):
                cur += stmt[i + 1]; i += 2; continue
            if c == q:
                q = None
            i += 1; continue
        if c in '"\'':
            q = c; cur += c; i += 1; continue
        if c == '\\' and i + 1 < len(stmt):
            cur += c + stmt[i + 1]; i += 2; continue
        if c in ' \t':
            if cur: out.append(cur); cur = ''
            i += 1; continue
        if c in ';&|#':
            break
        cur += c; i += 1
    if cur: out.append(cur)
    return out

def expanded(val):
    """Names this value EXPANDS. Single-quoted spans expand nothing."""
    buf, q, i = '', None, 0
    while i < len(val):
        c = val[i]
        if q == "'":
            if c == "'": q = None
            i += 1; continue
        if c == "'" and q is None:
            q = "'"; i += 1; continue
        if c == '"':
            q = '"' if q is None else (None if q == '"' else q); i += 1; continue
        buf += c; i += 1
    return {m.group(1) for m in re.finditer(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)', buf)}

def scan(path):
    hits = []
    try:
        lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
    except OSError as e:
        print('local-selfref-scan: cannot read %s: %s' % (path, e), file=sys.stderr)
        return None
    for n, line in enumerate(lines, 1):
        if line.lstrip().startswith('#'): continue
        if not DECL.match(line): continue
        w = words(line.strip())
        if not w or w[0] not in ('local', 'declare', 'typeset', 'export', 'readonly'):
            continue
        declared = []
        for word in w[1:]:
            if word.startswith('-'): continue
            if '=' in word:
                name, _, val = word.partition('=')
                if not NAME.match(name): continue
                clash = expanded(val) & set(declared)
                if clash:
                    hits.append((n, sorted(clash)[0], name, line.strip()))
                declared.append(name)
            elif NAME.match(word):
                declared.append(word)
    return hits

targets = sys.argv[1:]
if not targets:
    print('local-selfref-scan: empty target set — CANNOT SCAN', file=sys.stderr)
    sys.exit(2)

total, unreadable = 0, 0
for t in targets:
    hits = scan(t)
    if hits is None:
        unreadable += 1; continue
    for n, earlier, name, line in hits:
        total += 1
        print('%s:%d: VIOLATION `%s` expands `$%s`, declared in the SAME statement'
              % (t, n, name, earlier))
        print('    %s' % line)
if unreadable:
    sys.exit(2)
sys.exit(1 if total else 0)
PYEOF

run_core() { python3 -c "$CORE" "$@"; }

# ---------------------------------------------------------------------------
# CANARY — prove the instrument fires before trusting a clean answer from it.
# ---------------------------------------------------------------------------
if (( CANARY )); then
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lsr-canary.XXXXXX") || exit 2
  trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/violating.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
f() {
  local dir="$HOME/.5dive" f="$dir/delivery.env" tmp
  echo "$f$tmp"
}
STUB
  cat > "$tmp/healthy.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
f() {
  local dir="$HOME/.5dive"
  local f="$dir/delivery.env"
  local tmp
  local lit='$dir is a literal here'
  echo "$f$tmp$lit"
}
STUB
  run_core "$tmp/violating.sh" >/dev/null 2>&1; rc=$?
  if (( rc != 1 )); then
    echo "local-selfref-scan: CANARY FAILED — the DIVE-4067 shape scored rc=$rc, expected 1. CANNOT SCAN" >&2
    exit 2
  fi
  run_core "$tmp/healthy.sh" >/dev/null 2>&1; rc=$?
  if (( rc != 0 )); then
    echo "local-selfref-scan: CANARY FAILED — a correct declaration scored rc=$rc, expected 0. CANNOT SCAN" >&2
    exit 2
  fi
  rm -rf "$tmp"; trap - EXIT
fi

# ---------------------------------------------------------------------------
# TARGETS
# ---------------------------------------------------------------------------
declare -a TARGETS=()
if (( ${#ARGS[@]} )); then
  TARGETS=("${ARGS[@]}")
else
  cd "$ROOT" || exit 2
  for f in 5dive-agent-start install.sh build.sh \
           5dive-refresh-plugins.sh 5dive-refresh-skills.sh 5dive-stage-fork-plugins.sh; do
    [[ -f "$f" ]] && TARGETS+=("$f")
  done
  # SELF-EXCLUSION, and it is not a formality: this file must CONTAIN the defective
  # shape in order to carry a canary that proves it can see it, so the default sweep
  # would otherwise accuse the scanner forever. The skip is by PATH, not by content,
  # and only in the DEFAULT set — hand this script's own path (or a copy of it) on
  # argv and it is scanned like anything else. tests/local_selfref_scan_unit.sh
  # grades both halves: the default sweep must stay clean, and a COPY of this file
  # must still be accused. A self-exclusion that silently stopped working would red
  # every PR; one that was never needed would leave that arm passing vacuously.
  self="scripts/$(basename "${BASH_SOURCE[0]}")"
  while IFS= read -r f; do
    [[ "$f" == "$self" ]] && continue
    TARGETS+=("$f")
  done < <(
    { find src -maxdepth 1 -name '*.sh' -type f
      find scripts -maxdepth 1 -name '*.sh' -type f
      find scripts/git-hooks -maxdepth 1 -type f 2>/dev/null
    } 2>/dev/null | sort)
fi

if (( ${#TARGETS[@]} == 0 )); then
  echo "local-selfref-scan: no targets resolved — CANNOT SCAN" >&2
  exit 2
fi

run_core "${TARGETS[@]}"; rc=$?
if (( rc == 0 )); then
  echo "local-selfref-scan: clean over ${#TARGETS[@]} shipped shell file(s)"
elif (( rc == 1 )); then
  echo "" >&2
  echo "local-selfref-scan: a declaration builtin expands ALL its arguments before" >&2
  echo "assigning ANY of them, so the marked read resolves against the ENCLOSING" >&2
  echo "scope. Split it into one statement per name (DIVE-4067)." >&2
fi
exit $rc
