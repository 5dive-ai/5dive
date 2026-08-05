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
# Usage: scripts/scan-trailing-conditional.sh [file ...]   (default: src/*.sh src/lib/*.sh)
# Exit 0 = nothing found, 1 = offenders printed to stdout, 2 = could not scan.
set -uo pipefail

# Deliberate survivors. Each is a contract that is intentionally rc-bearing and
# whose call sites already absorb it — NOT an instance we could not fix.
ALLOWLIST='_gate_tier2_floor_term|_compose_create_args|_gate_anon_ok'
# _gate_tier2_floor_term - value producer; rc 1 means "named no term". Every call
#   site absorbs it (`|| v=""`), asserted directly in task_show_exit_code_unit.sh.
# _compose_create_args   - its only caller reads it through a process substitution
#   (`mapfile -t args < <(...)`), where the rc never reaches errexit.
# _gate_anon_ok          - a genuine predicate whose consequent happens to be a
#   `command -v` probe rather than a bracket test, so elimination cannot see it
#   is a test. Returning "is anonymous access possible" IS its contract.

cd "$(dirname "$0")/.." || { echo "scan: cannot reach repo root" >&2; exit 2; }
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
  for f in src/*.sh src/lib/*.sh src/council/*.sh scripts/*.sh install.sh update.sh build.sh; do
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

rc=0
for f in "${files[@]}"; do
  [[ -r "$f" ]] || { echo "scan: cannot read $f" >&2; exit 2; }
  out=$(scan_one "$f") || { echo "scan: awk failed on $f" >&2; exit 2; }
  if [[ -n "$out" ]]; then printf '%s\n' "$out"; rc=1; fi
done
exit "$rc"
