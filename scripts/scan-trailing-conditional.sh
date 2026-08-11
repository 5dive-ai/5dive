#!/usr/bin/env bash
# DIVE-2751 — find every place a function's EXIT STATUS is supplied by a
# conditional that is allowed to be false.
#
#     render() { ...; [[ -n "$x" ]] && printf '%s\n' "$x"; }
#
# The compound returns 1 when the test is false, that becomes the function's rc,
# and `set -euo pipefail` kills the script at the call site — AFTER the output
# has already printed. So it reads as success to a human and failure to a script.
#
# WHY THIS IS A SCRIPT AND NOT A GREP. Two earlier iterations shipped a regex
# built from the instances already found, and each time a live instance walked
# through it:
#   iteration 1 matched `[[ ]]` + a braced block  -> blind to `(( )) && echo`
#   iteration 2 tested the last PHYSICAL line     -> blind to a wrapped `&& printf \`
# Enumerating syntaxes is the defect one level up. So this works from the
# property instead:
#
#   1. join line continuations, so a statement is one record whatever its width;
#   2. find the statement that SUPPLIES the rc — walk back from the function's
#      closing brace, and follow a bare `return` back to the statement whose $?
#      it inherits (a bare `return` is an alias, not a statement of its own);
#   3. ask whether that statement is an `&&` compound with a real command on the
#      right and no `||` fallback.
#
# Step 3 decides by ELIMINATION, not by listing printers: strip command
# substitutions, quoted strings and every bracketed test region, and see what
# `&&` survives. A predicate — `[[ a && b ]]`, `[ -r f ] && [ x = y ]` — reduces
# to nothing and is excluded structurally, because its consequent was only ever
# another test. A pipeline is excluded too: its rc comes from the pipe's tail.
#
# Anything left over is a genuine judgement call and is named in ALLOWLIST below
# with the reason, so the guard stays armed instead of being widened until quiet.
#
# SECOND MODE — `--call-sites`. An allowlist entry is only as good as the reason
# it rests on, and iteration 3 shipped a false one: "every call site absorbs it"
# had been checked by a grep anchored to the start of the line, so an unguarded
# assignment written `local v; v=$(f ...)` was invisible to it while a guarded one
# four lines away matched. Same failure mode as the two blind detectors above,
# moved one level out — into the justification. So the justification is checked by
# this script too: `--call-sites` masks quotes and command-substitution bodies,
# splits on TOP-LEVEL `;` (a statement is not a line, in either direction), and
# asks of each statement whether the substitution's rc can become the statement's.
#
# Usage: scripts/scan-trailing-conditional.sh [--call-sites] [file ...]
#        (default file set: src/*.sh src/lib/*.sh src/task/*.sh src/council/*.sh scripts/*.sh
#         plus the customer-facing runners)
# Exit 0 = nothing found, 1 = offenders printed to stdout, 2 = could not scan.
set -uo pipefail

# Deliberate survivors. Each is a contract that is intentionally rc-bearing and
# whose call sites already absorb it — NOT an instance we could not fix. Re-audited
# call site by call site in iteration 4; `--call-sites` is what keeps these honest.
ALLOWLIST='_gate_tier2_floor_term|_compose_create_args|_gate_anon_ok'
# _gate_tier2_floor_term - value producer; rc 1 means "named no term". FIVE call
#   sites in src/cmd_task.sh: 7208 and 7210 absorb with `|| _floor_term=""`, 8299
#   the same; the Rule 3 site in cmd_task_need and the `_fbt` string assembly did
#   NOT until iteration 4 and now do. The claim is asserted by `--call-sites`
#   below, run from task_show_exit_code_unit.sh — not by a grep, and not by prose.
# _compose_create_args   - one call site, cmd_compose.sh:421, read through a
#   process substitution (`mapfile -t args < <(...)`) where the rc never reaches
#   errexit. Re-checked: `_compose_create_args` appears nowhere else in the tree.
# _gate_anon_ok          - a genuine predicate whose consequent happens to be a
#   `command -v` probe rather than a bracket test, so elimination cannot see it
#   is a test. Returning "is anonymous access possible" IS its contract. Two call
#   sites, both predicate-context: cmd_task.sh:1757 is the last statement of
#   _gate_gh_reachable (itself a predicate, so the rc is the answer) and 1989 is
#   `_gate_anon_ok || return 1`.

cd "$(dirname "$0")/.." || { echo "scan: cannot reach repo root" >&2; exit 2; }
MODE=trailing
while [[ ${1:-} == --* ]]; do
  case "$1" in
    --call-sites) MODE=callsites; shift ;;
    --trailing)   MODE=trailing;  shift ;;
    *) echo "scan: unknown option $1" >&2; exit 2 ;;
  esac
done
files=("$@")
if (( ${#files[@]} == 0 )); then
  shopt -s nullglob
  # src/council/*.template.sh is in the default set on purpose: src/cmd_council.sh
  # is GENERATED from it, so guarding only the derived artifact is silently
  # reverted by the next regen — the DIVE-2604 lesson, same file pair.
  # install/update/build are the customer-facing runners that call into these
  # functions (paperclip_seed_all_from_registry is reached from update.sh), and
  # they run under `set -e` themselves.
  # Literal names are filtered by existence — `install.sh` is present, `update.sh`
  # ships from elsewhere. An ABSENT default is not the same event as an
  # UNREADABLE argument: the caller naming a file it cannot read is exit 2.
  files=()
  for f in src/*.sh src/lib/*.sh src/task/*.sh src/council/*.sh scripts/*.sh install.sh update.sh build.sh; do
    [[ -r "$f" ]] && files+=("$f")
  done
  shopt -u nullglob
fi
(( ${#files[@]} )) || { echo "scan: no files to scan" >&2; exit 2; }

scan_one() {
  local f="$1"
  # Pass 1: join backslash continuations, keeping the FIRST physical line number.
  awk '
    { if (cont) { line = line " " $0 } else { line = $0; ln = FNR }
      if (line ~ /\\$/) { sub(/\\[ \t]*$/, "", line); cont = 1; next }
      cont = 0
      printf "%d\t%s\n", ln, line }
    END { if (cont) printf "%d\t%s\n", ln, line }
  ' "$f" |
  # Pass 2: structural walk.
  awk -v FNAME="$f" -v ALLOW="$ALLOWLIST" '
    function strip(l,   prev) {
      # command substitutions, innermost first
      do { prev = l; sub(/\$\([^()]*\)/, " ", l) } while (l != prev)
      gsub(/\x27[^\x27]*\x27/, " ", l)          # single-quoted
      gsub(/"[^"]*"/, " ", l)                   # double-quoted
      do { prev = l; sub(/\[\[.*?\]\]/, " ", l) } while (l != prev)
      do { prev = l; sub(/\(\([^()]*\)\)/, " ", l) } while (l != prev)
      do { prev = l; sub(/\[ [^]]*\]/, " ", l) } while (l != prev)
      return l
    }
    # Does this statement hand a false-able status to whoever inherits it?
    function offends(raw,   s, rhs) {
      if (raw ~ /^[ \t]*(if|while|until|elif)[ \t]/) return 0  # rc is the branch taken
      s = strip(raw)
      if (s !~ /&&/) return 0                    # no top-level && survived -> predicate
      if (s ~ /\|\|/) return 0                   # a fallback makes it always succeed
      if (s ~ /(^|[^|])\|([^|]|$)/) return 0     # pipeline: rc is the pipe tail
      if (s ~ /(^|[; \t])(return|exit)([ \t;]|$)/) return 0   # status stated explicitly
      rhs = s; sub(/^.*&&/, "", rhs)
      gsub(/[ \t]/, "", rhs)
      return (rhs != "")                         # a real command on the right
    }
    function noise(s) { return (s == "" || s ~ /^#/ || s == "fi" || s == "done" ||
                                s == "esac" || s == "else" || s == ";;" || s == "}") }
    function report(i, why,   nm) {
      nm = fn
      if (nm ~ "^(" ALLOW ")$") return
      printf "%s:%d  %s  [%s]\n    %s\n", FNAME, lno[i], nm, why, substr(txt[i], 1, 120)
      found = 1
    }
    { ln = $1; sub(/^[0-9]+\t/, "") }
    /^[a-zA-Z_][a-zA-Z0-9_]*[ \t]*\([ \t]*\)[ \t]*\{/ {
      fn = $0; sub(/[ \t]*\(.*/, "", fn); inf = 1; n = 0; next
    }
    inf && /^\}/ {
      # (a) the statement that supplies the function rc
      i = n
      while (i >= 1) {
        s = txt[i]; gsub(/[ \t]/, "", s)
        if (noise(s)) { i--; continue }
        if (s == "return" || s == "return;") { i--; continue }   # alias, keep walking
        if (offends(txt[i])) report(i, "function rc")
        break
      }
      inf = 0; next
    }
    inf {
      n++; txt[n] = $0; lno[n] = ln
      # (b) every bare `return` inherits $? from the statement before it — this is
      # the early-return path a walk-back from `}` can never reach.
      s = $0; gsub(/[ \t]/, "", s)
      if (s == "return" || s == "return;") {
        j = n - 1
        while (j >= 1) {
          t = txt[j]; gsub(/[ \t]/, "", t)
          if (noise(t)) { j--; continue }
          if (offends(txt[j])) report(j, "bare return inherits this")
          break
        }
      }
    }
    END { exit 0 }
  '
}

# ---- mode 2: are the ALLOWLIST contracts actually absorbed where they are CALLED? ----
# The rc of `v=$(f)` IS f's rc — and so is the rc of `v="text $(f) more"`, because
# an assignment inherits its LAST command substitution. Neither is visible to a
# detector that classifies the left side of `&&`, and neither is findable by a
# pattern anchored to the start of a line. Decided by elimination again:
#   * mask quoted regions and command-substitution BODIES to same-length filler,
#     so every `;` `&&` `||` found in the mask is top level by construction;
#   * cut the record into statements at those `;` — this is the whole point: the
#     escapee was the second statement of `local v; v=$(f ...)`;
#   * strip leading `then/else/do/{/!` and split each statement into && / || operands;
#   * an operand that is a bare ASSIGNMENT containing the call, with no top-level
#     `||` after it, is where the rc leaks. Everything else falls out structurally:
#     a test operand's rc is the test, a `local`/`export` prefix returns the
#     BUILTIN's status, and a call passed as an ARGUMENT hands its rc to the outer
#     command, not to the statement.
scan_call_sites_one() {
  local f="$1"
  awk '
    { if (cont) { line = line " " $0 } else { line = $0; ln = FNR }
      if (line ~ /\\$/) { sub(/\\[ \t]*$/, "", line); cont = 1; next }
      cont = 0
      printf "%d\t%s\n", ln, line }
    END { if (cont) printf "%d\t%s\n", ln, line }
  ' "$f" |
  awk -v FNAME="$f" -v ALLOW="$ALLOWLIST" '
    BEGIN { SQ = sprintf("%c", 39) }
    # same length as the input, with quotes and $( ) bodies blanked
    function mask(l,   i,c,n,out,inq,ind,depth) {
      n = length(l); out = ""; inq = 0; ind = 0; depth = 0
      for (i = 1; i <= n; i++) {
        c = substr(l, i, 1)
        if (depth > 0) {
          if (c == "(") depth++; else if (c == ")") depth--
          out = out "."; continue
        }
        if (inq) { if (c == SQ) inq = 0; out = out "."; continue }
        if (ind) { if (c == "\"") ind = 0; out = out "."; continue }
        if (c == SQ)   { inq = 1; out = out "."; continue }
        if (c == "\"") { ind = 1; out = out "."; continue }
        if (c == "$" && substr(l, i+1, 1) == "(") { depth = 1; out = out ".."; i++; continue }
        out = out c
      }
      return out
    }
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function dekeyword(s) {
      while (s ~ /^[ \t]*(then|else|do|\{|!)([ \t]|$)/) sub(/^[ \t]*(then|else|do|\{|!)[ \t]*/, "", s)
      return trim(s)
    }
    # rc of this operand comes from the call itself?
    function leaks(op) {
      op = dekeyword(op)
      if (op ~ /^(if|elif|while|until|case|for)([ \t]|$)/) return 0   # condition context
      if (op ~ /^(\[\[|\(\(|\[)([ \t]|$)/) return 0                  # rc is the test
      if (op ~ /^(local|declare|typeset|export|readonly)[ \t]/) return 0  # builtin rc
      if (op !~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/) return 0   # argument to a command
      return 1
    }
    { ln = $1; sub(/^[0-9]+\t/, "") }
    {
      raw = $0
      if (raw ~ /^[ \t]*#/) next
      if (raw !~ ("\\$\\((" ALLOW ")([ \t)]|$)")) next
      m = mask(raw)
      # cut into statements on top-level ;
      nstmt = 0; start = 1
      for (i = 1; i <= length(m); i++) {
        if (substr(m, i, 1) == ";") {
          nstmt++; stmt[nstmt] = substr(raw, start, i - start); smask[nstmt] = substr(m, start, i - start)
          start = i + 1
        }
      }
      nstmt++; stmt[nstmt] = substr(raw, start); smask[nstmt] = substr(m, start)
      for (s = 1; s <= nstmt; s++) {
        if (stmt[s] !~ ("\\$\\((" ALLOW ")([ \t)]|$)")) continue
        # split the statement into && / || operands, remembering where the || are
        nop = 0; ostart = 1; sawpipe = 0; hit = 0
        sm = smask[s]
        for (i = 1; i <= length(sm) - 1; i++) {
          op2 = substr(sm, i, 2)
          if (op2 == "&&" || op2 == "||") {
            nop++; opnd[nop] = substr(stmt[s], ostart, i - ostart); okind[nop] = op2
            ostart = i + 2; i++
          }
        }
        nop++; opnd[nop] = substr(stmt[s], ostart); okind[nop] = ""
        for (o = 1; o <= nop; o++) {
          if (opnd[o] !~ ("\\$\\((" ALLOW ")([ \t)]|$)")) continue
          if (!leaks(opnd[o])) continue
          # a top-level || anywhere after this operand absorbs the status
          sawpipe = 0
          for (k = o; k <= nop; k++) if (okind[k] == "||") sawpipe = 1
          if (sawpipe) continue
          printf "%s:%d  rc of an allowlisted call is not absorbed\n    %s\n", FNAME, ln, substr(trim(opnd[o]), 1, 120)
          hit = 1
        }
      }
    }
    END { exit 0 }
  '
}

rc=0
for f in "${files[@]}"; do
  [[ -r "$f" ]] || { echo "scan: cannot read $f" >&2; exit 2; }
  if [[ "$MODE" == callsites ]]; then
    out=$(scan_call_sites_one "$f") || { echo "scan: awk failed on $f" >&2; exit 2; }
  else
    out=$(scan_one "$f") || { echo "scan: awk failed on $f" >&2; exit 2; }
  fi
  if [[ -n "$out" ]]; then printf '%s\n' "$out"; rc=1; fi
done
exit "$rc"
