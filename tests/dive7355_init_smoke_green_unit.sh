#!/usr/bin/env bash
# DIVE-7355: the four reds the first keyed init-smoke on main found (10-31).
#   1. hermes: a turn read as idle (byte-stable pane, no idle marker), so `ask`
#      pressed Enter five times and called its own question unconfirmed. Hermes
#      draws "msg=interrupt · /queue ..." exactly while a turn runs: that is busy.
#   2. hermes on 24.04: the Anthropic SDK was missing ("The 'anthropic' package
#      is required"). The recipe now installs it through Hermes's own lazy_deps.
#   3. openclaw web chat: in a container the gateway's default bind is 0.0.0.0
#      and it refuses to start without a token. Setup now binds it to loopback.
#   4. the smoke driver waited 1500s on Hermes's "[Y/n]"; it now fails once init
#      sits quiet on a question nobody answers, and never on one it answered.
# Run: bash tests/dive7355_init_smoke_green_unit.sh (no root, no network, ~6s)
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad_t() { FAIL=$((FAIL+1)); echo "FAIL $1${2:+ — $2}"; }

# --- 1. hermes busy footer ----------------------------------------------------
eval "$(awk '/^_hb_agent_pane_idle\(\) \{/,/^\}/' src/cmd_heartbeat.sh)"
_hb_pane_status_line() { return 1; }
_hb_idle_marker() { printf ''; }
agent_type() { echo hermes; }
sudo() { cat "$PANE"; }
printf 'Initializing agent...\n────\n☤ ❯ msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel\n────\n' >"$TMP/busy"
printf 'Your message was not sent.\n────\n❯ Find and fix a failing test\n────\n' >"$TMP/idle"
PANE="$TMP/busy" _hb_agent_pane_idle x 0.05; rc=$?
(( rc == 1 )) && ok_t "a hermes turn in flight reads busy" || bad_t "a hermes turn in flight read rc=$rc (want 1)"
PANE="$TMP/idle" _hb_agent_pane_idle x 0.05; rc=$?
(( rc == 0 )) && ok_t "hermes at its placeholder reads idle" || bad_t "hermes at rest read rc=$rc (want 0)"
unset -f sudo

# --- 2. hermes recipe installs the Anthropic SDK -------------------------------
# shellcheck disable=SC1091
source src/header.sh
set +e  # header.sh turns errexit on; a red arm must not end the harness
recipe="${TYPE_INSTALL[hermes]}"
[[ "$recipe" == *"ensure(\"provider.anthropic\", prompt=False)"* ]] \
  && ok_t "the hermes recipe installs provider.anthropic" || bad_t "no provider.anthropic in the recipe" "$recipe"
bash -n -c "$recipe" && ok_t "the hermes recipe parses" || bad_t "the hermes recipe does not parse"
# Run it against a stub tree: hermes present, so only the SDK step runs.
mkdir -p "$TMP/h/tools" "$TMP/h/venv/bin"
printf 'def ensure(f, prompt=True):\n    print("ENSURE", f, prompt)\n' >"$TMP/h/tools/lazy_deps.py"
ln -s "$(command -v python3)" "$TMP/h/venv/bin/python"
r="${recipe//\/home\/claude\/.hermes\/hermes-agent/$TMP/h}"; r="${r//${TYPE_BIN[hermes]}//bin/true}"
out=$(bash -c "$r" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "ENSURE provider.anthropic False" ]] \
  && ok_t "an installed hermes still gets the SDK step" || bad_t "SDK step rc=$rc" "$out"
printf 'def ensure(f, prompt=True):\n    raise SystemExit(1)\n' >"$TMP/h/tools/lazy_deps.py"
out=$(bash -c "$r" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"warn: could not install the Anthropic SDK"* ]] \
  && ok_t "a failed SDK install warns and does not fail the install" || bad_t "failed SDK step rc=$rc" "$out"

# --- 3. openclaw gateway bound to loopback, both setup paths --------------------
n=$(grep -c 'config set gateway.bind loopback' src/lib/agent_setup.sh)
(( n >= 2 )) && ok_t "openclaw web chat + telegram setup bind the gateway to loopback" \
  || bad_t "gateway.bind loopback set in $n of 2 setup paths"

# --- 4. the init driver: fail fast on an unanswered question ---------------------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/5dive" <<'SH'
#!/bin/bash
echo "Which?"; echo "    1. Alpha  first"; printf 'Choose [1]: '; read -r a; echo "got $a"
case "$MODE" in
  stuck) printf 'Install ripgrep for faster file search? [Y/n] '; sleep 30 ;;
  slow)  printf 'Paste your API key: '; read -rs k; sleep 3; echo; echo "my-agent is ready" ;;
esac
SH
chmod +x "$TMP/bin/5dive"
echo '[{"wait":"Which\\?[\\s\\S]*?Choose \\[\\d+\\]: ","pick":"Alpha","secs":20}]' >"$TMP/s1.json"
echo '[{"wait":"Which\\?[\\s\\S]*?Choose \\[\\d+\\]: ","pick":"Alpha","secs":20},{"wait":"Paste your API key: ","secret":true,"secs":20}]' >"$TMP/s2.json"
PATH="$TMP/bin:$PATH" MODE=stuck INIT_SMOKE_QUIET_SECS=2 \
  python3 scripts/init-smoke-drive.py "$TMP/s1.json" "$TMP/l1" "$TMP/r1.json"; rc=$?
d=$(jq -r .detail "$TMP/r1.json"); s=$(jq -r .secs "$TMP/r1.json")
[[ $rc -ne 0 && "$d" == *"question no step answers"*"[Y/n]"* ]] && (( ${s%.*} < 10 )) \
  && ok_t "an unanswered [Y/n] fails in ${s}s, naming it" || bad_t "unanswered prompt: rc=$rc in ${s}s" "$d"
PATH="$TMP/bin:$PATH" MODE=slow INIT_SMOKE_QUIET_SECS=1 INIT_SMOKE_KEY=sk-init-smoke-not-a-real-key-0000 \
  python3 scripts/init-smoke-drive.py "$TMP/s2.json" "$TMP/l2" "$TMP/r2.json"; rc=$?
[[ $rc -eq 0 ]] && ok_t "an answered prompt followed by silence is not 'stuck'" \
  || bad_t "answered prompt tripped the stuck check" "$(jq -r .detail "$TMP/r2.json")"

echo "--- $PASS pass, $FAIL fail"
(( FAIL == 0 ))
