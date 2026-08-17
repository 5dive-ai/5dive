#!/usr/bin/env bash
# DIVE-2792 — a legitimate non-zero from a WRAPPED external tool must reach the
# caller as that tool's status, with that tool's message, and WITHOUT the
# silent-exit backstop's "this is a bug in the CLI ... its effect is UNKNOWN"
# banner. And `5dive bug --file` must not lose the report when its own route out
# (gh) is the thing that is down.
#
# Graded END TO END, through the BUILT BUNDLE, with a stub that reports the argv
# it received — the DIVE-3135 lesson: the stripper is correct in isolation and
# the verb is correct in isolation, so a harness that sources a function and
# calls it directly passes while the shipped CLI is dead
# (community/wiki/a-global-flag-stripper-eats-a-passthrough-verbs-argv.md).
#
# Every negative arm here pins THREE things — the exact exit code, a string only
# the subject can produce, and the ABSENCE of the banner. "did it fail?" alone is
# satisfied by the scaffold dying before it reached the code under test
# (community/wiki/a-negative-arm-that-greps-for-failure-passes-on-any-failure.md).
set -uo pipefail

# DIVE-2211: name the tree this harness grades. The absence of `2>/dev/null` is
# deliberate — redirecting the source's stderr would swallow the helper's own
# stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$ROOT/5dive"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (want '$2', got '$1')"; fi; }

if [[ ! -x "$BUNDLE" ]]; then
  echo "SKIP: no built bundle at $BUNDLE — run ./build.sh first" >&2
  exit 0
fi

BANNER='without reporting a reason'
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stub" "$TMP/home"

cat > "$TMP/stub/gh" <<'STUB'
#!/usr/bin/env bash
# Reports the argv it received, so an arm can prove what REACHED the tool —
# never just what the tool then did.
[[ "$1" == "auth" && "$2" == "token" ]] && exit "${GH_STUB_AUTH_RC:-1}"
printf 'GH-STUB-ARGV: %s\n' "$*" >&2
printf '%s\n' "${GH_STUB_MSG:-gh stub message}" >&2
exit "${GH_STUB_RC:-0}"
STUB
chmod +x "$TMP/stub/gh"

# THE WRITE PATH MUST BE SEVERED TOO, and a PATH-level `gh` stub does not do it.
# `issue create` is class=write, so cmd_gh routes it to the machine account via
# `sudo -n /usr/local/bin/5dive _gh_do` — a different binary, run as root, with
# root's PATH. An earlier draft of this harness stubbed only `gh` and FILED TWO
# REAL PUBLIC ISSUES (5dive-ai/5dive#693, #694, closed as harness noise). Stub
# sudo as well, and prove below that it was actually consulted.
cat > "$TMP/stub/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'SUDO-STUB: %s\n' "$*" >> "${SUDO_STUB_LOG:-/dev/null}"
# The routed write itself: drain the NUL-separated argv off stdin so the parent's
# `printf | sudo` does not SIGPIPE, then answer LOCALLY. Never a network call.
if [[ "$*" == *"_gh_do"* && "$*" != *" -l "* ]]; then
  cat >/dev/null
  rc="${SUDO_STUB_GH_DO_RC:-1}"
  (( rc == 0 )) && echo "https://github.com/example/5dive/issues/1"
  exit "$rc"
fi
exit "${SUDO_STUB_LIST_RC:-1}"
STUB
chmod +x "$TMP/stub/sudo"
export SUDO_STUB_LOG="$TMP/sudo.log"; : > "$SUDO_STUB_LOG"

echo "== A. 5dive gh: gh's own exit status survives, gh's own message survives, no banner =="
for rc in 1 4 8; do
  out=$(PATH="$TMP/stub:$PATH" GH_STUB_RC=$rc GH_STUB_MSG="gh-said-$rc" \
        "$BUNDLE" gh --as=caller pr view 51 2>&1); got=$?
  check "$got" "$rc" "A$rc: exit status is gh's own ($rc), not remapped"
  [[ "$out" == *"gh-said-$rc"* ]] \
    && ok "A$rc: gh's own message survives to the caller" \
    || bad "A$rc: gh's message was lost"
  [[ "$out" != *"$BANNER"* ]] \
    && ok "A$rc: no internal-CLI-bug banner" \
    || bad "A$rc: the banner fired on a legitimate tool status"
  # what REACHED gh — the seam DIVE-3135 lived in
  [[ "$out" == *"GH-STUB-ARGV: pr view 51"* ]] \
    && ok "A$rc: argv reached gh verbatim" \
    || bad "A$rc: argv was mangled before gh saw it"
done

echo "== A5. positive control: rc=0 exits 0 and says nothing about a failure =="
out=$(PATH="$TMP/stub:$PATH" GH_STUB_RC=0 "$BUNDLE" gh --as=caller pr view 51 2>&1); got=$?
check "$got" "0" "A5: a successful passthrough exits 0"
[[ "$out" != *"that is gh's OWN exit status"* ]] \
  && ok "A5: no failure narration on the happy path" \
  || bad "A5: narrated a failure that did not happen"

echo "== A6. control: the banner EMITTER is still shipped (arms above are not vacuous) =="
# Scope, stated so it is not read as more than it is: this greps for the emitter's
# own runtime template ($code, not the "exited N ..." spelling every comment in the
# tree uses), so it catches the banner being DELETED — the mutation that would make
# every no-banner arm above pass for free. It does NOT prove the backstop can still
# FIRE; tests/silent_nonzero_exit_backstop_unit.sh owns that, including the liveness
# pair, and this harness deliberately does not duplicate it.
grep -qF 'exited $code without reporting a reason' "$BUNDLE" \
  && ok "A6: the backstop's own emitter template is still in the bundle" \
  || bad "A6: the emitter is gone, so every no-banner arm above proves nothing"

echo "== B. 5dive bug --file spools locally when the gh route is down =="
# gh present but failing — the exact case the verb is invoked from.
spooldir="$TMP/home/.local/state/5dive/bug-spool"
out=$(PATH="$TMP/stub:$PATH" XDG_STATE_HOME="$TMP/home/.local/state" \
      GH_STUB_RC=1 GH_STUB_MSG="gh refused" \
      "$BUNDLE" bug --what="DIVE-2792 harness probe" --verb=gh --exit=4 --no-probes --file </dev/null 2>&1); got=$?
[[ "$got" -ne 0 ]] \
  && ok "B1: --file that could not file exits non-zero" \
  || bad "B1: reported success for a report that never left the box"
[[ "$out" == *"it is saved locally at"* ]] \
  && ok "B2: the caller is told the report was saved, and where" \
  || bad "B2: no spool path in the failure text"
n=$(find "$spooldir" -type f -name '*.md' 2>/dev/null | wc -l)
check "$n" "1" "B3: exactly one spool file was written"
f=$(find "$spooldir" -type f -name '*.md' 2>/dev/null | head -1)
if [[ -n "$f" ]]; then
  grep -q "DIVE-2792 harness probe" "$f" \
    && ok "B4: the spooled file carries the report's own --what text" \
    || bad "B4: spool file does not contain the report"
  check "$(stat -c %a "$f")" "600" "B5: spool file is 0600"
  check "$(stat -c %a "$spooldir")" "700" "B6: spool dir is 0700"
fi

echo "== B7. control: a report that DOES file spools nothing =="
rm -rf "$spooldir"
PATH="$TMP/stub:$PATH" XDG_STATE_HOME="$TMP/home/.local/state" \
  GH_STUB_RC=0 SUDO_STUB_GH_DO_RC=0 SUDO_STUB_LIST_RC=0 \
  "$BUNDLE" bug --what="DIVE-2792 happy path" --verb=gh --exit=0 --no-probes --file </dev/null >/dev/null 2>&1
n=$(find "$spooldir" -type f -name '*.md' 2>/dev/null | wc -l)
check "${n:-0}" "0" "B7: nothing is spooled when the issue actually files"

echo "== B8. the harness never reached the real write path =="
# Without this, B1-B6 would pass identically whether the route was stubbed or
# whether it went out over the network and really filed — which is how #693/#694
# happened. Assert the sudo route was ATTEMPTED and REFUSED by the stub.
grep -q 'SUDO-STUB: -n /usr/local/bin/5dive _gh_do' "$SUDO_STUB_LOG" \
  && ok "B8: the bot-routed write went to the stub, not to GitHub" \
  || bad "B8: the write path was NOT severed — this harness may have filed a real issue"

echo "== C. 5dive agent logs: the passthrough the SWEEP found, not the one the row named =="
# WHY THIS BLOCK EXISTS (DIVE-2792 iteration 2, quinn). The first draft of this
# harness graded `gh` (A) and the bug spool (B) — and `gh` was ALREADY correct
# before this branch, via DIVE-3135's `_gh_child_exit`. So
# `git checkout origin/main -- src/cmd_agent_runtime.sh && ./build.sh && bash <this>`
# still printed 23 passed / 0 failed: reverting the ONE live defect the sweep
# turned up cost zero arms. A row that says "fix X, and sweep for others" ships a
# harness aimed at X; when the sweep moves the value, the harness has to move with
# it. community/wiki/a-sweep-that-finds-a-second-defect-must-move-the-harness-to-it.md
#
# journalctl is called bare, so a PATH stub reaches it (unlike gh's class=write
# route above, which re-enters through an absolute path as root — see B8).
# STATE_DIR is redirected so `require_agent` resolves against a fixture registry
# and no arm depends on which agents this host happens to have.
cat > "$TMP/stub/journalctl" <<'STUB'
#!/usr/bin/env bash
printf 'JCTL-STUB-ARGV: %s\n' "$*" >&2
[[ -n "${JCTL_OUT:-}" ]] && printf '%s\n' "$JCTL_OUT"
[[ -n "${JCTL_ERR:-}" ]] && printf '%s\n' "$JCTL_ERR" >&2
exit "${JCTL_RC:-0}"
STUB
chmod +x "$TMP/stub/journalctl"
mkdir -p "$TMP/state"
printf '{"agents":{"probe":{"type":"claude"}}}\n' > "$TMP/state/agents.json"
# Leading NAME=VALUE args are the stub's knobs; everything from the first
# non-assignment on is the bundle's argv. Passing both to `env` in one list would
# make `env` treat the first CLI word as the program (rc=127) — which C11 exists
# to catch, and did.
jlogs() {
  local envs=()
  while [[ "${1:-}" == [A-Z_]*=* ]]; do envs+=("$1"); shift; done
  PATH="$TMP/stub:$PATH" STATE_DIR="$TMP/state" env "${envs[@]}" "$BUNDLE" "$@"
}

for rc in 1 4; do
  out=$(jlogs JCTL_RC=$rc JCTL_ERR="jctl-said-$rc" agent logs probe 2>&1); got=$?
  check "$got" "$rc" "C-text-$rc: exit status is journalctl's own ($rc), not remapped"
  [[ "$out" == *"jctl-said-$rc"* ]] \
    && ok "C-text-$rc: journalctl's own message survives to the caller" \
    || bad "C-text-$rc: journalctl's message was lost"
  [[ "$out" != *"$BANNER"* ]] \
    && ok "C-text-$rc: no internal-CLI-bug banner on a legitimate read failure" \
    || bad "C-text-$rc: the banner fired on journalctl's own status"
done

echo "== C4. --json: same status, class:\"passthrough\", and NO {ok:true} on stdout =="
# The --json half was the opposite lie from the text half: `journalctl | jq`
# reported JQ's status, so a failed read exited with an ok:true envelope already
# printed. Grade stdout ALONE — the narration on stderr is not the defect.
sout=$(jlogs JCTL_RC=4 JCTL_ERR="jctl-said-4" --json agent logs probe 2>/dev/null); got=$?
check "$got" "4" "C4: --json exit status is journalctl's own (4)"
# SLURP it, do not grep it and do not read a bare `.ok`. Two traps, both of which
# this arm fell into before it was measured against the reverted tree:
#   - the success envelope is jq's DEFAULT (pretty) output, `"ok": true` WITH a
#     space, while the error envelope is `jq -cn` compact — so a
#     `*'"ok":true'*` match reads false on the very envelope it forbids;
#   - on origin/main stdout carries BOTH objects (the premature `{ok:true}` and
#     then the backstop's `{ok:false}`), so `jq -r '.ok'` yields "true\nfalse",
#     which is != "true" and passes while the defect is present.
# The claim is "no object in this stream says ok:true", so slurp and count.
check "$(jq -s 'map(select(.ok == true)) | length' <<<"$sout" 2>/dev/null)" "0" \
  "C5: no {ok:true} envelope anywhere on stdout for a read that failed"
[[ "$sout" == *'"class":"passthrough"'* ]] \
  && ok "C6: the error envelope names the failure as a passthrough, not a CLI fault" \
  || bad "C6: no class:\"passthrough\" in the --json error envelope"

echo "== C7. happy path: an EMPTY successful read is lines:[] — not one phantom line =="
# A here-string appends a newline, so `<<<""` is one empty line to `jq -R … inputs`.
# The pipe→capture rewrite that fixed C4/C5 introduced this; an agent that has not
# logged yet is the ordinary case for it. Both sources take the same helper, so
# both are graded — `--tmux` had the same shape before this branch touched it.
sout=$(jlogs JCTL_RC=0 --json agent logs probe 2>/dev/null); got=$?
check "$got" "0" "C7: a successful read exits 0"
check "$(jq -c '.data.lines' <<<"$sout" 2>/dev/null)" "[]" \
  "C8: empty successful read reports lines:[] (not [\"\"])"
sout=$(jlogs JCTL_RC=0 JCTL_OUT=$'line-one\nline-two' --json agent logs probe 2>/dev/null)
check "$(jq -c '.data.lines' <<<"$sout" 2>/dev/null)" '["line-one","line-two"]' \
  "C9: a non-empty read reports exactly its lines, none invented"
check "$(jq -r '.ok' <<<"$sout" 2>/dev/null)" "true" \
  "C10: the success envelope IS printed when the read succeeded"

echo "== C11. control: the stub was actually consulted (C arms are not vacuous) =="
# Without this, every C arm passes identically if the bundle never reached
# journalctl at all — the arm-that-greps-for-failure trap, one layer up.
out=$(jlogs JCTL_RC=1 agent logs probe 2>&1)
[[ "$out" == *"JCTL-STUB-ARGV: -u 5dive-agent@probe.service"* ]] \
  && ok "C11: the resolved unit reached journalctl verbatim" \
  || bad "C11: journalctl was never reached — the C arms grade nothing"

echo
printf 'DIVE-2792 passthrough-exit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
