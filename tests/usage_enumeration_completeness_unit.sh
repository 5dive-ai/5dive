#!/usr/bin/env bash
# DIVE-2029 — a verb that dispatches must also be NAMED by the usage string that
# enumerates its siblings.
#
# THE DEFECT this pins: `5dive agent auth reap` shipped in 0.15.33 (DIVE-1884), was
# added to the top-level `5dive --help` block, and was invisible from the surface a
# user actually hits by guessing:
#
#   5dive agent auth        ->  "usage: 5dive agent auth status|login|set|start|poll|submit|cancel"
#
# Each usage string is a separate hard-coded literal, not generated from one sibling
# list, so every one of them is an independent place to forget. The verb passes its own
# tests either way, which is exactly why nothing caught it for four months.
#
# THE INVARIANT, stated so it survives new verbs: wherever a dispatch `case` has a usage
# or unknown-command string that ALREADY enumerates siblings with `|`, that string must
# name every arm the case dispatches. Silence is allowed (a case with no enumeration is
# not graded); an enumeration that is WRONG is not.
#
# Deliberately NOT graded, said plainly rather than left as a surprise:
#   - alias arms — `ls|list)` passes when the string names either one; hidden aliases are
#     a real convention here and documenting both would be noise.
#   - `-h|--help|help)` groups, and `_`-prefixed internal verbs (`_push_do` etc.) — both
#     are deliberately undocumented.
#   - a case with NO enumerating string at all. That is a different defect class (an
#     undocumented dispatcher) and folding it in here would bury this one in noise.

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set +e -o pipefail
TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

command -v python3 >/dev/null 2>&1 || {
  printf 'FAIL - T0 python3 absent — the checker cannot run, so every arm below is UNGRADED\n'
  echo "TESTS pass=0 fail=1"; exit 1; }

# ── the checker ────────────────────────────────────────────────────────────────
# Prints one line per gap: "<file>:<line> case $<var>  MISSING=<arm-groups>".
# Exits 0 always; the ARMS grade its output, so a crash reads as a failure, not a pass.
cat > "$TMP/check.py" <<'PYEOF'
import re, sys, os, glob

root = sys.argv[1]
files = sorted(glob.glob(os.path.join(root, 'src', '*.sh'))
               + glob.glob(os.path.join(root, 'src', 'council', '*.sh')))

def strip_heredocs(lines):
    """Blank out heredoc BODIES. cmd_proof.sh's help heredoc contains prose like
    '(PUBLISHED / no-op / FAILED)' which parses as a case arm and invents gaps."""
    out, term = [], None
    for ln in lines:
        if term is not None:
            out.append('')
            if ln.strip() == term:
                term = None
            continue
        out.append(ln)
        m = re.search(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?\s*$", ln)
        if m:
            term = m.group(1)
    return out

gaps = []
for f in files:
    lines = strip_heredocs(open(f).read().split('\n'))
    for i, ln in enumerate(lines):
        if not re.match(r'^\s*case\s+"\$\{?(\w+)', ln):
            continue
        var = re.match(r'^\s*case\s+"\$\{?(\w+)', ln).group(1)
        # matching esac
        j, depth = i + 1, 1
        while j < len(lines):
            if re.match(r'^\s*case\s+', lines[j]):
                depth += 1
            elif re.match(r'^\s*esac', lines[j]):
                depth -= 1
                if depth == 0:
                    break
            j += 1
        body = lines[i + 1:j]

        # arm groups at THIS case's level only (skip nested cases)
        groups, catchall, d = [], [], 0
        for b in body:
            if re.match(r'^\s*case\s+', b):
                d += 1; continue
            if re.match(r'^\s*esac', b):
                d -= 1; continue
            if d != 0:
                continue
            am = re.match(r'^\s*([A-Za-z0-9_|*-]+)\)', b)
            if not am:
                continue
            raw = am.group(1).split('|')
            if '*' in raw:
                catchall.append(b); continue
            if any(a in ('-h', '--help') for a in raw):
                continue
            g = [a for a in raw if not a.startswith('-') and not a.startswith('_')]
            if g:
                groups.append(g)
        if not groups:
            continue

        # An enumerating string is only ASSOCIATED with this case if it is the guard
        # just above it or lives on its catch-all arm. Scanning whole arm bodies pulls
        # in a CHILD dispatcher's usage string and invents gaps in the parent.
        enums = []
        for w in lines[max(0, i - 6):i] + catchall:
            if '$E_USAGE' not in w:
                continue
            for s in re.findall(r'"([^"]*)"', w):
                if '|' in s and ('usage:' in s or 'unknown' in s):
                    enums.append(s)
        if not enums:
            continue

        blob = ' '.join(enums)
        miss = [g for g in groups
                if not any(re.search(r'(?<![A-Za-z0-9_-])' + re.escape(a) + r'(?![A-Za-z0-9_-])', blob)
                           for a in g)]
        if miss:
            gaps.append('%s:%d case $%s  MISSING=%s'
                        % (os.path.basename(f), i + 1, var, ','.join('|'.join(g) for g in miss)))

for g in gaps:
    print(g)
PYEOF

# ── T0 non-vacuity: the checker reads a real tree ──────────────────────────────
_n_src=$(ls "$ROOT"/src/*.sh 2>/dev/null | wc -l)
[[ "$_n_src" -gt 20 ]] \
  && ok_t "T0 checker input is a real source tree ($_n_src files in src/) — the arms below are not reading an empty dir" \
  || bad_t 'T0 src/ is empty or unreadable — every arm is vacuous' "n=$_n_src root=$ROOT"

# ── T1 the tree is clean ───────────────────────────────────────────────────────
_out="$(python3 "$TMP/check.py" "$ROOT" 2>"$TMP/err")"
_rc=$?
if [[ "$_rc" -ne 0 ]]; then
  bad_t 'T1 checker crashed — the tree is UNGRADED, not clean' "rc=$_rc $(head -3 "$TMP/err")"
elif [[ -z "$_out" ]]; then
  ok_t 'T1 every enumerating usage string names all the verbs its case dispatches'
else
  bad_t 'T1 a dispatch verb is missing from the usage string that enumerates its siblings' "$_out"
fi

# ── T2 NON-VACUITY: the checker can SEE the DIVE-2029 defect ──────────────────
# T1 passing proves nothing on its own — a checker that finds nothing anywhere would
# also print nothing here. Re-introduce the exact shipped defect in a COPY and require
# the checker to name it. Copy, never edit ROOT in place.
cp -a "$ROOT/src" "$TMP/src-mut" && mkdir -p "$TMP/mut" && mv "$TMP/src-mut" "$TMP/mut/src"
_anchor='status|login|set|start|poll|submit|cancel|reap'
_hits=$(grep -c -F -- "$_anchor" "$TMP/mut/src/main.sh")
if [[ "$_hits" -lt 1 ]]; then
  bad_t 'T2 mutation anchor not found — the usage string was reworded, so T2 grades NOTHING' \
        "anchor=$_anchor (update this test alongside the string)"
else
  python3 - "$TMP/mut/src/main.sh" <<'MUT'
import sys
p = sys.argv[1]
s = open(p).read()
open(p, 'w').write(s.replace('status|login|set|start|poll|submit|cancel|reap',
                             'status|login|set|start|poll|submit|cancel'))
MUT
  _mout="$(python3 "$TMP/check.py" "$TMP/mut" 2>/dev/null)"
  if grep -q 'main.sh.*case \$authcmd.*MISSING=reap' <<<"$_mout"; then
    ok_t "T2 dropping reap from the auth usage string is CAUGHT (anchor hits=$_hits) — T1 is not vacuous"
  else
    bad_t 'T2 the shipped defect is INVISIBLE to the checker — T1 proves nothing' \
          "checker said: ${_mout:-<nothing>}"
  fi
fi

# ── T3 the three DIVE-2029 surfaces, pinned by literal ────────────────────────
# The checker is a generic invariant; these pin the specific strings the ticket names,
# so a later loosening of the checker cannot silently drop this coverage.
grep -q 'usage: 5dive agent auth status|login|set|start|poll|submit|cancel|reap' "$ROOT/src/main.sh" \
  && ok_t 'T3a the no-arg `agent auth` usage line names reap (the highest-traffic surface)' \
  || bad_t 'T3a reap is missing from the no-arg agent-auth usage line' \
           "$(grep -n 'usage: 5dive agent auth' "$ROOT/src/main.sh")"

grep -q 'unknown auth command: \$authcmd (status|login|set|start|poll|submit|cancel|reap)' "$ROOT/src/main.sh" \
  && ok_t 'T3b the unknown-auth-command error enumerates the siblings, reap included' \
  || bad_t 'T3b the unknown-auth-command error names no siblings at all' \
           "$(grep -n 'unknown auth command' "$ROOT/src/main.sh")"

grep -q 'collect|status|install|uninstall|show' "$ROOT/src/cmd_loop.sh" \
  && ok_t 'T3c sweep: `loop uninstall` dispatches and is now named by the loop usage string' \
  || bad_t 'T3c loop uninstall is still missing from the loop enumeration' ''

grep -q 'publish|on|off|status|scorecard|tick' "$ROOT/src/cmd_proof.sh" \
  && ok_t 'T3d sweep: `proof scorecard` dispatches and is now named by the proof usage string' \
  || bad_t 'T3d proof scorecard is still missing from the proof enumeration' ''

# ── T4 the two --help surfaces resolve instead of erroring ────────────────────
# `5dive agent --help` and `5dive agent auth --help` both died on the catch-all
# ("unknown agent command: --help"), so the documented block was unreachable from
# inside the subcommand — the second of the ticket's two broken surfaces.
_agent_help=$(awk '/^      local sub="\$1"; shift$/{f=1} f&&/^        -h\|--help\|help\) usage ;;$/{print;exit}' "$ROOT/src/main.sh")
[[ -n "$_agent_help" ]] \
  && ok_t 'T4a `5dive agent --help` routes to usage rather than the unknown-command catch-all' \
  || bad_t 'T4a agent --help still falls through to "unknown agent command"' ''

_auth_help=$(awk '/case "\$authcmd" in/{f=1} f&&/-h\|--help\|help\) usage ;;/{print;exit}' "$ROOT/src/main.sh")
[[ -n "$_auth_help" ]] \
  && ok_t 'T4b `5dive agent auth --help` routes to usage rather than the unknown-command catch-all' \
  || bad_t 'T4b agent auth --help still falls through to "unknown auth command"' ''

echo "TESTS pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
