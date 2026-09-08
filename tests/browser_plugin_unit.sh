#!/usr/bin/env bash
# DIVE-4021 — `5dive browser`: profile-per-site auth and a deterministic executor.
#
# WHAT THIS SUITE IS ARRANGED AROUND. The row names three structural gaps, and a
# test that only proved "the happy path prints something" would grade none of
# them. So every arm below is a MUTANT of the specific defect the design exists
# to prevent, driven through the real bin/browser as a subprocess:
#
#   gap 1 sessions die   -> T4x: a cold profile FAILS CLOSED. The mutant is an
#                           executor that finds out mid-publish and improvises.
#   gap 2 verification   -> T5x: exit status follows the OUT-OF-BAND re-read and
#                           NOT the driver. Two mutants, and the second is the
#                           dangerous one: driver-red + artifact-live must exit 0,
#                           because a "failure" there is what double-posts on retry.
#   gap 3 profiles ARE   -> T2x: a directory this seat does not own, or that is
#         credentials       group-readable, is refused rather than repaired.
#
# There is no chrome on a CI runner and this suite must not need one, so the
# probe is driven by putting a FAKE `google-chrome` first on PATH. That is not a
# test hook in the product — bin/browser has no probe override to set, and could
# not, because a way to declare a profile live without looking is the one backdoor
# this design cannot afford. The fake is exercising the real _probe.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$PWD"
BROWSER="$ROOT/plugins/browser/bin/browser"

PASS=0; FAIL=0
t()  { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi; }
tc() { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }
tn() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n   expected NOT to contain: %s\n   got: %s\n' "$1" "$2" "$3"; fi; }

TMP="$(mktemp -d)"
OUT=""; ERR=""; RC=0
run() { local o="$TMP/.o" e="$TMP/.e"; "$@" >"$o" 2>"$e"; RC=$?; OUT=$(cat "$o"); ERR=$(cat "$e"); return 0; }

SEAT="$(id -un)"
export FIVEDIVE_BROWSER_PROFILE_ROOT="$TMP/profiles"
export FIVEDIVE_BROWSER_ADAPTER_DIR="$TMP/adapters"
mkdir -p "$FIVEDIVE_BROWSER_ADAPTER_DIR"

# --- fake chrome, and the DOM it serves is switchable per site ---------------
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/google-chrome" <<'CHROME'
#!/usr/bin/env bash
# Serves whatever DOM the arm parked for this profile. Ignores every flag; the
# point is only that _probe gets a document back and greps it.
for a in "$@"; do case "$a" in --user-data-dir=*) d="${a#*=}" ;; esac; done
cat "${d:-/nonexistent}/.fake-dom" 2>/dev/null || echo "<html><body>feed</body></html>"
CHROME
chmod +x "$FAKEBIN/google-chrome"
export PATH="$FAKEBIN:$PATH"

# --- fixtures ----------------------------------------------------------------
mkprofile() {  # mkprofile <site> <dom>
  local d="$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/$1"
  mkdir -p "$d"; chmod 700 "$d"; printf '%s' "$2" > "$d/.fake-dom"
  chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
  echo "$d"
}
LIVE_DOM='<html><body><div id="feed">posts</div></body></html>'
DEAD_DOM='<html><body><form action="/login"><input name="pw"></form></body></html>'

mkadapter() {  # mkadapter <site> <verify-url> <expect> [extra-step-op]
  local extra=""
  [[ -n "${4:-}" ]] && extra=",{\"op\":\"$4\",\"selector\":\"x\"}"
  cat > "$FIVEDIVE_BROWSER_ADAPTER_DIR/$1.json" <<JSON
{ "site": "$1",
  "probe": { "url": "https://$1.test/feed", "logged_out_when_dom_matches": "action=\"/login\"" },
  "actions": { "publish": {
      "steps": [ {"op":"goto","url":"https://$1.test/compose"},
                 {"op":"fill","selector":"#e","value":"{body}"},
                 {"op":"click","selector":"#pub"}$extra ],
      "verify": { "url": "$2", "expect": "$3" } } } }
JSON
}
mkdriver() {  # mkdriver <exit-code>
  cat > "$TMP/driver" <<DRV
#!/usr/bin/env bash
cat > "$TMP/driver-plan.json"
exit $1
DRV
  chmod +x "$TMP/driver"; export FIVEDIVE_BROWSER_DRIVER="$TMP/driver"
}

# ============================================================== T1 the manifest
M="$ROOT/plugins/browser/.claude-plugin/plugin.json"
run jq -e . "$M";                                              t 'T1a manifest is valid JSON' 0 "$RC"
t 'T1b declares contract 1'      '1'       "$(jq -r '.fivedive.contract' "$M")"
t 'T1c declares the verb capability' 'true' "$(jq -r '.fivedive.capabilities|index("verb")!=null' "$M")"
t 'T1d the verb is named browser' 'browser' "$(jq -r '.fivedive.verbs[0].name' "$M")"
# The dispatcher resolves <plugin>/bin/<verb> and refuses a non-executable file,
# so a declared verb whose file is not +x installs and can never run.
t 'T1e bin/<verb> exists and is executable, or the verb is inert' 'yes' \
  "$([[ -x "$ROOT/plugins/browser/bin/browser" ]] && echo yes || echo no)"
t 'T1f the bundled marketplace lists it' 'browser' \
  "$(jq -r '.plugins[]|select(.name=="browser")|.name' "$ROOT/plugins/.claude-plugin/marketplace.json")"
# $REPO is a flat fetch URL with no directory listing, so a bundled file that is
# not enumerated in install.sh is simply absent on a real box. Enumerate or inert.
for f in browser/.claude-plugin/plugin.json browser/README.md browser/bin/browser browser/adapters/example.json; do
  tc "T1g install.sh stages $f" "$f" "$(grep -o "$f" "$ROOT/install.sh" | head -1)"
done
run bash "$ROOT/plugins/browser/bin/browser" --help;           t 'T1h --help exits 0' 0 "$RC"

# ========================================= T2 a profile directory IS a credential
run "$BROWSER" ls
t  'T2a no store at all is not a crash' 69 "$RC"
tc 'T2a ...it names the one command that fixes it' '5dive browser setup' "$ERR"

mkprofile x "$LIVE_DOM" >/dev/null
run "$BROWSER" ls;                                             t 'T2b a sane store lists' 0 "$RC"
tc 'T2b ...naming the site'  'x' "$OUT"

# THE MUTANT: group/other-readable seat dir. Anything that can READ the directory
# can replay the session, so this must refuse — and must NOT quietly chmod it,
# because a silent repair means the window it was open in is never noticed.
chmod 750 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"
run "$BROWSER" ls
t  'T2c a group-readable seat dir is refused' 77 "$RC"
tc 'T2c ...naming the mode'                  '750' "$ERR"
t  'T2c ...and is NOT silently repaired'     '750' "$(stat -c '%a' "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT")"
chmod 700 "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT"

# A site name becomes a directory name.
for bad in ../etc "a/b" "" "UPPER"; do
  run "$BROWSER" auth "$bad"
  t "T2d refuses site name '$bad'" 64 "$RC"
done
# ...and the positive control, or "refuses everything" would pass T2d.
run "$BROWSER" auth x
tn 'T2e a VALID name is not refused as a name' 'not a usable profile name' "$ERR"

# setup is a root act because the alternative is a world-writable parent a
# hostile seat can squat.
run "$BROWSER" setup
t  'T2f setup as non-root is refused' 77 "$RC"
tc 'T2f ...naming the sudo form'      'sudo 5dive browser setup' "$ERR"

# ================================================= T3 adapters are data, not code
mkdriver 0
mkadapter x "file://$TMP/artifact.html" 'PUBLISHED'
printf 'PUBLISHED' > "$TMP/artifact.html"

# THE MUTANT the fixed vocabulary exists for: a step that is a program.
python3 - "$FIVEDIVE_BROWSER_ADAPTER_DIR/x.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d['actions']['publish']['steps'].append({"op":"eval","script":"require('child_process')"})
json.dump(d,open(p,'w'))
PY
run "$BROWSER" run x publish --body=hi
t  'T3a a step outside the vocabulary is refused' 64 "$RC"
tc 'T3a ...naming the offending op'               'eval' "$ERR"
mkadapter x "file://$TMP/artifact.html" 'PUBLISHED'

# An action with no out-of-band verify is refused BEFORE a step runs — an
# unverifiable action must not be half-executed and then found unverifiable.
rm -f "$TMP/driver-plan.json"
python3 - "$FIVEDIVE_BROWSER_ADAPTER_DIR/x.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); del d['actions']['publish']['verify']; json.dump(d,open(p,'w'))
PY
run "$BROWSER" run x publish --body=hi
t  'T3b an action with no verify block is refused'  64 "$RC"
tc 'T3b ...saying why in the operator words'        'grade its own homework' "$ERR"
t  'T3b ...and NOT after running the steps'         'no' "$([[ -f "$TMP/driver-plan.json" ]] && echo yes || echo no)"
mkadapter x "file://$TMP/artifact.html" 'PUBLISHED'

run "$BROWSER" run x nosuchaction --body=hi
t 'T3c an undefined action is refused' 64 "$RC"

# ========================================== T4 gap 1: a cold session fails CLOSED
mkprofile dead "$DEAD_DOM" >/dev/null
mkadapter dead "file://$TMP/artifact.html" 'PUBLISHED'
rm -f "$TMP/driver-plan.json"
run "$BROWSER" run dead publish --body=hi
t  'T4a a logged-out profile refuses to run' 75 "$RC"
tc 'T4a ...naming the human-only fix'        '5dive browser auth dead' "$ERR"
t  'T4a ...and the driver was never invoked' 'no' "$([[ -f "$TMP/driver-plan.json" ]] && echo yes || echo no)"
tc 'T4a ...and does not retry or improvise'  'no retry, no login attempt' "$ERR"

run "$BROWSER" auth --status dead
t  'T4b --status reports a dead profile as cold' 75 "$RC"
tc 'T4b ...by name'                              'COLD' "$OUT"
run "$BROWSER" auth --status x
t  'T4c ...and a live one as live' 0 "$RC"
tc 'T4c ...positive control'       'live' "$OUT"

# ================== T5 gap 2: the verdict is the out-of-band read, not the driver
# MUTANT 1 — driver green, artifact absent. "Posted a draft and reported success."
mkdriver 0
mkadapter x "file://$TMP/missing.html" 'PUBLISHED'
run "$BROWSER" run x publish --body=hi
t  'T5a driver-green + artifact-absent must NOT report success' 1 "$RC"
tc 'T5a ...and says the re-read is what failed' 'NOT VERIFIED' "$ERR"
tc 'T5a ...and warns against a blind retry'     'double-posts' "$ERR"

# MUTANT 2, and this is the dangerous one. Driver RED, artifact LIVE: the publish
# worked and the driver lied. Reporting failure here is what double-posts on the
# retry, so the out-of-band read has to overrule a red driver too. A verdict that
# only overrules green is not out-of-band verification, it is a second opinion
# nobody asked for.
mkdriver 3
mkadapter x "file://$TMP/artifact.html" 'PUBLISHED'
run "$BROWSER" run x publish --body=hi
t  'T5b driver-RED + artifact-live reports SUCCESS' 0 "$RC"
tc 'T5b ...naming the URL it re-read'               "$TMP/artifact.html" "$OUT"

# The happy path, or T5a/T5b could both pass on a `run` that never verifies.
mkdriver 0
run "$BROWSER" run x publish --body=hi
t 'T5c driver-green + artifact-live is success' 0 "$RC"

# The verify URL interpolates the caller's args, which is how a permalink is
# addressed at all. Substituted as a jq VALUE — it never reaches a shell.
printf 'slug-42 is live' > "$TMP/slug-42.html"
mkadapter x "file://$TMP/{slug}.html" '{slug}'
run "$BROWSER" run x publish --slug=slug-42
t  'T5d verify.url and .expect interpolate named args' 0 "$RC"
tc 'T5d ...against the interpolated permalink' 'slug-42.html' "$OUT"

# The plan handed to the driver carries the profile path and the args, and the
# driver is fed on STDIN — argv never carries user text.
t 'T5e the driver receives the profile' "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/x" \
  "$(jq -r '.profile' "$TMP/driver-plan.json")"
t 'T5f the driver receives the args'    'slug-42' "$(jq -r '.args.slug' "$TMP/driver-plan.json")"

# ============================================ T6 no executor is a refusal, not a fallback
unset FIVEDIVE_BROWSER_DRIVER
run "$BROWSER" run x publish --slug=slug-42
t  'T6a no driver refuses' 69 "$RC"
tc 'T6a ...rather than silently falling back to an automated browser' 'Browser Hand' "$ERR"

# ============================================ T7 the shipped example adapter is real
EX="$ROOT/plugins/browser/adapters/example.json"
run jq -e . "$EX";                                       t 'T7a the shipped adapter is valid JSON' 0 "$RC"
t 'T7b ...declares a verify for every action' '' \
  "$(jq -r '[.actions|to_entries[]|select((.value.verify.url and .value.verify.expect)|not)|.key]|join(",")' "$EX")"
t 'T7c ...and uses only the fixed vocabulary' '' \
  "$(jq -r '["goto","fill","click","wait_for","select","upload","press"] as $ok
            | [.actions[].steps[].op|select(. as $o|($ok|index($o))|not)]|unique|join(",")' "$EX")"
# The probe greps the DUMPED DOM, so a marker naming the address bar is a marker
# that never matches — the field name and the code have to agree.
t 'T7d ...and its probe marker is the one bin/browser reads' 'yes' \
  "$(jq -e '.probe.logged_out_when_dom_matches' "$EX" >/dev/null && echo yes || echo no)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
