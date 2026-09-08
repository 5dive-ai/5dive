#!/usr/bin/env bash
# tests/shellcheck_sc2318_gate_unit.sh — DIVE-4067.
#
# THE INCIDENT. 0.26.1 shipped a launcher that could not start any agent, on any
# box. One line, added to `5dive-agent-start` by DIVE-4036:
#
#     local dir="$HOME/.5dive" f="$dir/delivery.env" tmp
#
# `local` is a builtin — bash expands ALL of its arguments before performing ANY of
# its assignments, so `$dir` resolved against the ENCLOSING scope and `set -u` made
# it a fatal exit before the pane started. The nightly restarts every agent after
# installing, so every box that took the release emptied itself unattended.
#
# THE PART THIS FILE GUARDS. shellcheck already named it — SC2318 — and the
# `shellcheck` job in install-smoke.yml already linted that exact file. SC2318 is a
# WARNING, that job runs `-S error`, and the filter dropped it. The instrument was
# present and configured off, which reports green and is therefore worse than an
# absent one. DIVE-4067 added a second pass, `--include=SC2318`, over the same file
# set, and widened that set to the three installed scripts nobody was linting.
#
# WHY A TEXT ASSERTION AND NOT A LINT RUN. This harness must grade the same thing in
# every environment the corpus runs in, and shellcheck is not installed in all of
# them. A harness that skips when the binary is missing grades nothing while
# printing a pass — the exact failure shape this row is about. So the LINTING stays
# in CI, where the binary is installed and the check is required, and what is graded
# here is that the workflow still ASKS for it. That is the half that can be deleted
# by a well-meaning diff; the pass itself cannot go silently green.
#
# The two arms are the two ways the gate dies: the pass is removed, or the file set
# it runs over is narrowed back to the list that omitted the stage-fork script —
# which is where two of the four findings actually lived.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

WF="$PWD/.github/workflows/install-smoke.yml"
[[ -r "$WF" ]] || { printf 'FAIL: %s not found\n' "$WF"; exit 1; }

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP %s\n     %s\n' "$1" "${2:-}"; }

# ---------------------------------------------------------------------------
# ARM 1 — THE PASS EXISTS, and it runs over BOTH file populations. The shebang
# files and the src/ fragments need different invocations (the fragments carry no
# shebang, so the dialect has to be stated), so a pass that covers only one of them
# leaves half the shipped shell unguarded while looking present.
# ---------------------------------------------------------------------------
n=$(grep -c -- '--include=SC2318' "$WF")
if (( n >= 2 )); then
  ok "install-smoke.yml runs an SC2318 pass over both file populations ($n invocations)"
else bad "install-smoke.yml runs an SC2318 pass over both file populations" \
         "found $n invocation(s) of --include=SC2318, expected >= 2"; fi

# ---------------------------------------------------------------------------
# ARM 2 — IT IS WIRED TO THE EXIT CODE. A lint pass whose result is discarded is
# the same green as no pass at all, and `|| rc=1` is one character from `|| true`.
# ---------------------------------------------------------------------------
if grep -- '--include=SC2318' "$WF" | grep -qv '|| rc=1'; then
  bad "every SC2318 invocation feeds the job's exit code" \
      "an --include=SC2318 line does not end in '|| rc=1'"
else
  ok "every SC2318 invocation feeds the job's exit code"
fi

# ---------------------------------------------------------------------------
# ARM 3 — THE FILE SET STILL CARRIES THE THREE INSTALLED SCRIPTS. These were linted
# by nothing before DIVE-4067, and `5dive-stage-fork-plugins.sh` held two of the
# four findings. Narrowing this list back is a silent re-opening of the gap, and it
# reads in review as tidying a long line.
# ---------------------------------------------------------------------------
for f in 5dive-stage-fork-plugins.sh 5dive-refresh-plugins.sh 5dive-refresh-skills.sh; do
  if grep -q -- "$f" "$WF"; then
    ok "the shellcheck file set still covers $f"
  else bad "the shellcheck file set still covers $f" "not named anywhere in install-smoke.yml"; fi
done

# ---------------------------------------------------------------------------
# ARM 4 — THE INCIDENT LINE ITSELF, named rather than inferred, so a future reader
# of a red does not have to reconstruct which function it was.
# ---------------------------------------------------------------------------
if [[ -r 5dive-agent-start ]]; then
  if grep -q 'local dir="\$HOME/\.5dive" f=' 5dive-agent-start; then
    bad "write_delivery_declaration() declares dir and f in separate statements" \
        "the DIVE-4067 fleet outage, reintroduced verbatim"
  else
    ok "write_delivery_declaration() declares dir and f in separate statements"
  fi
else
  skip "write_delivery_declaration() declares dir and f in separate statements" \
       "5dive-agent-start not present in this tree"
fi

# ---------------------------------------------------------------------------
# ARM 5 — THE RULE ACTUALLY NAMES THE DEFECT. Runs only where shellcheck is
# installed, and SKIPS LOUDLY otherwise rather than passing: this is the one arm
# that could quietly stop discriminating if SC2318's meaning ever moved, so a
# silent skip here would be the same defect as `-S error` was.
# ---------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  fx=$(mktemp "${TMPDIR:-/tmp}/sc2318.XXXXXX.sh") || exit 2
  printf '#!/usr/bin/env bash\nset -euo pipefail\nf() {\n  local dir="$HOME/.5dive" f="$dir/x" tmp\n  echo "$f$tmp"\n}\nf\n' > "$fx"
  if shellcheck --include=SC2318 "$fx" >/dev/null 2>&1; then
    bad "SC2318 still fires on the exact line that emptied the boxes" \
        "shellcheck $(shellcheck --version | awk '/version:/{print $2}') reported clean on the DIVE-4067 shape"
  else
    ok "SC2318 still fires on the exact line that emptied the boxes"
  fi
  # And it must not accuse the documented remedy, or the gate cannot be satisfied.
  printf '#!/usr/bin/env bash\nset -euo pipefail\nf() {\n  local dir="$HOME/.5dive"\n  local f="$dir/x"\n  local tmp\n  echo "$f$tmp"\n}\nf\n' > "$fx"
  if shellcheck --include=SC2318 "$fx" >/dev/null 2>&1; then
    ok "SC2318 accepts the split form, so the gate is satisfiable"
  else
    bad "SC2318 accepts the split form, so the gate is satisfiable" \
        "the documented remedy is still accused"
  fi
  rm -f "$fx"
else
  skip "SC2318 still fires on the exact line that emptied the boxes" \
       "shellcheck not installed here; the required CI job is where this rule runs"
  skip "SC2318 accepts the split form, so the gate is satisfiable" \
       "shellcheck not installed here"
fi

printf -- '-----\nRESULT: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
