#!/usr/bin/env bash
# DIVE-2604 — the class scanner for unguarded probe substitutions.
#
# THE CLASS. The bundle runs under `set -euo pipefail` (src/header.sh). A bare
# assignment `var=$(… grep …)` therefore KILLS the caller when the probe finds
# nothing, before any handler prints anything: rc set, both streams empty. Three
# instances shipped in one day — DIVE-2566 (`5dive push`, curl -f rc=22),
# DIVE-2603 (`5dive task done`, pipeline ending in grep), DIVE-2598 (the report
# of the second, measured from the outside). See
# community/wiki/a-cli-that-exits-non-zero-without-a-reason.md
#
# `local var=$(…)` is NOT this class: `local` always returns 0, so it MASKS the
# failure instead. Splitting the declaration onto its own line is the correct
# habit and is exactly what makes this one fatal, so the scanner deliberately
# looks only at BARE assignments. Fixing one by re-merging the `local` would
# trade a loud death for a silent wrong value; the fix is `|| var=""`.
#
# WHY NOT SHELLCHECK. shellcheck 0.9 has no check for this and cannot have a
# general one: whether a non-zero exit is a defect depends on whether the probe
# is ALLOWED to find nothing, which is a fact about intent. This scanner encodes
# that intent as a fixed list of probe commands (grep/rg/jq -e/curl -f) whose
# "nothing" answer is a non-zero exit.
#
# usage: scripts/unguarded-probe-scan.sh [--root=DIR]... [--stats] [--quiet]
# exit:  0 clean · 1 offenders found · 2 usage or internal error
set -uo pipefail

ROOTS=(); STATS=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --root=*) ROOTS+=("${a#--root=}") ;;
    --stats)  STATS=1 ;;
    --quiet)  QUIET=1 ;;
    -h|--help) sed -n '/^# usage:/,/^# exit:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unguarded-probe-scan: unknown argument %s\n' "$a" >&2; exit 2 ;;
  esac
done
(( ${#ROOTS[@]} )) || ROOTS=(src scripts)

command -v python3 >/dev/null 2>&1 \
  || { printf 'unguarded-probe-scan: python3 is required\n' >&2; exit 2; }

# The scanner needs balanced-paren and quote tracking to know where a `$( )`
# ends and whether a `||` is at the group top level. That is not expressible in
# grep, and getting it wrong in awk would make the guard itself the next silent
# failure. python3 is already a build-time dependency (scripts/supply-chain-scan.sh).
PROBE_STATS=0 python3 - "$STATS" "$QUIET" "${ROOTS[@]}" <<'PY'
import os, re, sys

stats_on = sys.argv[1] == "1"
quiet    = sys.argv[2] == "1"
roots    = sys.argv[3:]

# A probe is a command whose "I found nothing" answer is a NON-ZERO exit. That
# is the whole class: the empty result is ordinary, and the shell treats it as
# an error. Anything whose empty answer is empty STDOUT (awk, sed, tr, cut,
# head, sort, paste) is not here, because it exits 0 and cannot kill anything.
PROBE = re.compile(
    r'(?:^|[\s|;&(){}])(?:grep|egrep|fgrep|rg)(?:\s|$)'
    r'|(?:^|[\s|;&(){}])jq\s+(?:-\w*\s+)*-\w*e\b'
    r'|(?:^|[\s|;&(){}])curl\s+(?:[^|;&]*\s)?-\w*f\w*(?:\s|$)'
)
# A `||` right-hand side that cannot itself fail, i.e. one that really does
# convert the failure into a value. `|| fail …` and `|| return 1` also count:
# they are a deliberate handled path, which is the point — the death is no
# longer silent.
FALLBACK = re.compile(r'\|\|\s*(true\b|:\s|:$|echo\b|printf\b|[A-Za-z_][A-Za-z0-9_]*=|fail\b|die\b|return\b|continue\b|break\b|exit\b|\{)')

# `var="$(…)"` is the SAME statement as `var=$(…)` — the quotes change word
# splitting, not the exit status. Missing it was this scanner's third blind spot
# and the most common form in the tree.
# An assignment that STARTS A COMMAND, wherever that command starts. Anchoring at
# line start missed `local n; n=$(… | grep -c .)` — the declaration split onto the
# same line, which is the *recommended* habit written compactly, and six live sites
# wore exactly that form. Keying a sweep on the shape of the instance you already
# found is how the class survives the sweep; this scanner had that bug too.
#
# `||` is excluded on purpose: an assignment after `||` IS the fallback (`… || v=""`),
# not a new candidate. `local`/`export`/`declare`/`readonly`/`typeset` immediately
# before are excluded because those builtins return 0 and MASK — a different defect.
ASSIGN = re.compile(
    r'(?:^|(?<=;)|(?<=&&)|(?<=\{)|(?:^|[;&{])\s*(?:then|do|else)\s)'
    r'\s*(?!local\s|export\s|declare\s|readonly\s|typeset\s)'
    r'([A-Za-z_][A-Za-z0-9_]*)=("?)\$\(')
SET_E = re.compile(r'^[ \t]*set +-[a-zA-Z]*e', re.M)

def errexit_applies(path, text):
    """THE CLASS NEEDS `set -e`. Without it a failed assignment leaves an empty
    value and execution continues — the shape is then merely untidy, not fatal,
    and flagging it is a false positive. That distinction is not cosmetic: over
    half of scripts/ runs under `set -uo pipefail` with NO -e (supply-chain-scan,
    run-harnesses, stamp-changelog, …), and so does most of tests/.

    src/*.sh are the exception and must not be judged on their own text: they
    carry no `set` line because build.sh CONCATENATES them under src/header.sh,
    whose line 14 is `set -euo pipefail`. The bundle is the unit of execution,
    so the header's flags are the file's flags."""
    if path.startswith('src/') or '/src/' in path:
        return True
    return bool(SET_E.search(text))
# `(?<!<)<<(?!<)` so a here-STRING (`<<<"$out"`) never opens a heredoc. It once
# did: `# <<< DIVE-2287 …` in a COMMENT matched at the second `<` and swallowed
# the rest of cmd_selfupdate.sh, which then reported clean.
HEREDOC = re.compile(r'(?<!<)<<(?!<)-?\s*(["\']?)([A-Za-z_][A-Za-z0-9_]*)\1')

def scan_groups(text):
    """Walk text, returning (depth, index) for every char, honouring quotes.
    depth counts (, {, [[ nesting; quoted regions are depth-frozen and marked."""
    depth = [0] * len(text)
    quoted = [False] * len(text)
    d = 0; i = 0; q = None
    while i < len(text):
        c = text[i]
        if q:
            quoted[i] = True; depth[i] = d
            if c == '\\' and q == '"':
                quoted[i+1:i+2] = [True]; depth[i+1:i+2] = [d]; i += 2; continue
            if c == q: q = None
            i += 1; continue
        if c == '\\':
            # `'\''` — close, ESCAPED quote, reopen. Missing this flipped the
            # quote state for the rest of the line and lost a real offender.
            depth[i] = d; depth[i+1:i+2] = [d]; i += 2; continue
        if c in ('"', "'"):
            q = c; quoted[i] = True; depth[i] = d; i += 1; continue
        if c in '({':
            d += 1; depth[i] = d
        elif c in ')}':
            depth[i] = d; d -= 1
        else:
            depth[i] = d
        i += 1
    return depth, quoted

def substitution_end(text, start):
    """start indexes the '$' of a '$('. Return index of its matching ')' or -1."""
    d = 0; i = start + 1; q = None
    while i < len(text):
        c = text[i]
        if q:
            if c == '\\' and q == '"': i += 2; continue
            if c == q: q = None
            i += 1; continue
        if c == '\\': i += 2; continue
        if c in ('"', "'"): q = c; i += 1; continue
        if c == '(': d += 1
        elif c == ')':
            d -= 1
            if d == 0: return i
        i += 1
    return -1

def group_span(depth, quoted, pos):
    """Extent of the group enclosing pos, at pos's own depth."""
    d = depth[pos]
    lo = pos
    while lo > 0 and not (depth[lo-1] < d and not quoted[lo-1]): lo -= 1
    hi = pos
    while hi < len(depth) - 1 and not (depth[hi+1] < d and not quoted[hi+1]): hi += 1
    return lo, hi

offenders = []
examined = 0
files = 0
skipped = 0

for root in roots:
    if not os.path.isdir(root): continue
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d != '.git']
        for name in sorted(fn):
            if not name.endswith('.sh'): continue
            path = os.path.join(dp, name)
            files += 1
            _text = open(path, encoding='utf-8', errors='replace').read()
            if not errexit_applies(path, _text):
                skipped += 1
                continue
            lines = _text.split('\n')
            heredoc_term = None
            for idx, line in enumerate(lines):
                if heredoc_term is not None:
                    if line.strip() == heredoc_term: heredoc_term = None
                    continue
                if line.lstrip().startswith('#'): continue
                hd = HEREDOC.search(line)
                if hd: heredoc_term = hd.group(2)
                for m in ASSIGN.finditer(line):
                  var = m.group(1)
                  if line[:m.start()].rstrip().endswith('||'): continue
                  blob = '\n'.join(lines[idx:idx+80])
                  s = blob.index('$(', m.start())
                  e = substitution_end(blob, s)
                  if e < 0: continue
                  inner = blob[s+2:e]
                  # `) \` + `|| fail …` on the next line is one statement. Reading
                  # only the first physical line called cmd_deploy.sh's guarded curl
                  # an offender — a false positive is how a lint gets switched off.
                  _rest = blob[e+1:]
                  if m.group(2) and _rest.startswith('"'): _rest = _rest[1:]
                  _t = _rest.split('\n'); tail = _t[0]
                  _k = 0
                  while tail.rstrip().endswith('\\') and _k + 1 < len(_t):
                      _k += 1; tail = tail.rstrip()[:-1] + ' ' + _t[_k]
                  examined += 1
                  # An outer guard on the statement itself absorbs everything.
                  if re.match(r'\s*(\|\||&&\s*\S+\s*\|\|)', tail): continue
                  depth, quoted = scan_groups(inner)
                  bad = None
                  for pm in PROBE.finditer(inner):
                      p = pm.start()
                      while p < len(inner) and inner[p].isspace(): p += 1
                      if p >= len(inner) or quoted[p]: continue
                      lo, hi = group_span(depth, quoted, p)
                      after = inner[p:hi+1]
                      # A `||` at this probe's own group level, AFTER it, means the
                      # group's status is the fallback's, not the probe's.
                      guarded = False
                      for fm in FALLBACK.finditer(after):
                          gp = p + fm.start()
                          if not quoted[gp] and depth[gp] <= depth[p]:
                              guarded = True; break
                      if not guarded:
                          bad = pm.group(0).strip(); break
                  if bad:
                      offenders.append((path, idx + 1, var, ' '.join(inner.split())[:110], bad))

if offenders and not quiet:
    sys.stderr.write(
        "unguarded probe substitution(s) — each DIES on the no-match path under\n"
        "`set -euo pipefail`, with nothing on stdout or stderr (DIVE-2566/2603/2604):\n\n")
    for path, ln, var, inner, bad in offenders:
        sys.stderr.write("  %s:%d\n      %s=$(%s)\n      probe: %s\n" % (path, ln, var, inner, bad))
    sys.stderr.write(
        "\nRemedy, per site: append `|| %s=\"\"` (or `|| %s=0` for a counter) to the\n"
        "assignment. NOT `|| true`: the empty/zero value states the post-condition the\n"
        "code below actually reads, where `|| true` reads as noise-suppression and\n"
        "leaves the value to the substitution's behaviour. NOT `local %s=$(…)`: that\n"
        "masks the failure instead of handling it.\n" % (offenders[0][2], offenders[0][2], offenders[0][2]))

if stats_on:
    sys.stderr.write("unguarded-probe-scan: %d file(s) (%d skipped: no set -e, so not this class), "
                     "%d bare $( ) assignment(s) examined, %d offender(s)\n"
                     % (files, skipped, examined, len(offenders)))
    sys.stdout.write("files=%d skipped=%d examined=%d offenders=%d\n" % (files, skipped, examined, len(offenders)))

sys.exit(1 if offenders else 0)
PY
