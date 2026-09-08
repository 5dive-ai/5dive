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
# A challenge page usually still carries the login form's markup. That overlap is
# the whole reason T8 exists: classify this as "expired" and the operator is told
# to re-authenticate a session that is fine.
CHALLENGE_DOM='<html><body><form action="/login"></form><div class="g-recaptcha"></div></body></html>'

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

run "$BROWSER" status dead
t  'T4b --status reports a dead profile as cold' 75 "$RC"
tc 'T4b ...in the words the adopted design names' 'session expired — human action required' "$OUT"
run "$BROWSER" auth --status dead
t  'T4b2 auth --status is still an alias, so neither name is a dead link' 75 "$RC"
run "$BROWSER" status x
t  'T4c ...and a live one as live' 0 "$RC"
tc 'T4c ...positive control'       'authenticated' "$OUT"

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

# ======================= T8 a security challenge is a HARD STOP, never a bypass
# Decided 2026-09-07: "if a platform presents a security challenge, the executor
# stops and requests human action rather than attempting to bypass it." The mutant
# is not "it tries to solve it" — nothing here could — it is that a challenge gets
# classified as an expired session, which sends a human to re-authenticate a
# session that is fine and teaches them the signal is noise.
mkprofile chal "$CHALLENGE_DOM" >/dev/null
mkadapter chal "file://$TMP/artifact.html" 'PUBLISHED'
run "$BROWSER" status chal
t  'T8a a challenge is its own state, not "expired"' 75 "$RC"
tc 'T8a ...named as a challenge'                     'CHALLENGE' "$OUT"
tn 'T8a ...and NOT reported as an expired session'   'session expired' "$OUT"
mkdriver 0
rm -f "$TMP/driver-plan.json"
run "$BROWSER" run chal publish --body=hi
t  'T8b run stops on a challenge'          75 "$RC"
t  'T8b ...without invoking the driver'    'no' "$([[ -f "$TMP/driver-plan.json" ]] && echo yes || echo no)"
tc 'T8b ...saying it is a decision, not a limitation' 'does not attempt to solve' "$ERR"
# The framing lodar closed: this is persistent human-authenticated sessions. The
# anti-bot wording is the one that was ruled out for docs, marketing AND the
# plugin description, so grade the shipped strings rather than trusting a review.
for f in "$ROOT/plugins/browser/.claude-plugin/plugin.json" "$ROOT/plugins/browser/README.md" "$ROOT/plugins/.claude-plugin/marketplace.json"; do
  tn "T8c $(basename "$f") does not sell anti-bot evasion" 'fingerprint' "$(cat "$f")"
done
tc 'T8d the manifest uses the adopted framing' 'human-authenticated'   "$(jq -r '.description' "$ROOT/plugins/browser/.claude-plugin/plugin.json")"

# ===================== T9 the classifier must work in the size regime PRODUCTION has
# WHY THIS BLOCK EXISTS, and it is the lesson not the arm: every fixture above is
# a one-line DOM, so the whole suite lived below the old 200KB capture cap and
# graded a regime real pages never enter. Sixty-six green arms and ten killed
# mutants all agreed, and the classifier still reported UNKNOWN for every real
# page — and UNKNOWN fell through to the driver. The discriminating input was
# never a new assertion; it was an EXISTING assertion at a realistic size.
#
# On the size: it has to be well past the cap, not cap+1. A document a little
# over the cap often still fits the reader's last block plus the 64KB pipe
# buffer, so the writer never takes SIGPIPE and the bug does not fire — at
# 250KB it is a coin flip. 1MB is past every buffer on the path, so the arm is
# deterministic. A "cap+1" arm here would have been flaky, which is worse than
# absent because it teaches the suite to be ignored.
PAD="$(head -c 1000000 /dev/zero | tr '\0' 'x')"

# T9a — the SAME logged-out markup as T4a, only large. T4a is its negative control:
# identical verdict at 40 lines, so a difference here is size and nothing else.
mkprofile bigdead "$DEAD_DOM<!-- $PAD -->" >/dev/null
mkadapter bigdead "file://$TMP/artifact.html" 'PUBLISHED'
run "$BROWSER" status bigdead
t  'T9a a logged-out profile over the old cap is still read as expired' 75 "$RC"
tc 'T9a ...and not discarded as unreadable' 'session expired — human action required' "$OUT"
tn 'T9a ...so the healthy path is not the one nobody sees' 'UNKNOWN' "$OUT"

mkdriver 0
rm -f "$TMP/driver-plan.json"
run "$BROWSER" run bigdead publish --body=hi
t 'T9b ...and run still fails closed at that size' 75 "$RC"
t 'T9b ...without invoking the driver' 'no' "$([[ -f "$TMP/driver-plan.json" ]] && echo yes || echo no)"

# T9c — a marker PAST the cap. Independent of the exit-status half: a truncating
# capture cannot see it even with the status fixed, and a challenge banner is as
# likely to sit late in a large document as early. The mutant is the worst verdict
# this file can produce: a challenged session reported as authenticated.
mkprofile latechal "<html><body><div id=\"feed\">posts</div><!-- $PAD --><div class=\"g-recaptcha\"></div></body></html>" >/dev/null
mkadapter latechal "file://$TMP/artifact.html" 'PUBLISHED'
run "$BROWSER" status latechal
t  'T9c a challenge marker past the old cap is still found' 75 "$RC"
tc 'T9c ...classified as a challenge'                       'CHALLENGE' "$OUT"
tn 'T9c ...and NOT as a live session'                       'authenticated' "$OUT"

# T9d/e — UNKNOWN is ASYMMETRIC, and both halves are the finding. Quiet at the
# scheduler (body item: a network blip must not page a human) and FATAL at the
# action (an unverified session is as likely to be a challenge page as a healthy
# one, and the action is the irreversible half). A `!= CHALLENGE && != expired`
# pair satisfies neither: it publishes on every state it has no name for.
#
# Chrome is absent here BY CONSTRUCTION — a bin dir holding only the commands
# bin/browser uses — not by hoping the runner has none. The T9d0 positive control
# is the point: a stripped PATH that broke `jq` would fail these arms for the
# wrong reason and read exactly like a pass.
NOCHROME="$TMP/nochrome"; mkdir -p "$NOCHROME"
for c in bash basename cat chmod curl date dirname env grep head id jq mkdir mktemp rm stat; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$NOCHROME/$c"
done
t 'T9d0 positive control: the stripped PATH still resolves jq, so a failure below means no chrome' \
  'yes' "$(PATH="$NOCHROME" command -v jq >/dev/null 2>&1 && echo yes || echo no)"
t 'T9d0 ...and resolves no browser at all' 'none' \
  "$(PATH="$NOCHROME" bash -c 'for c in google-chrome chromium chromium-browser google-chrome-stable; do command -v $c >/dev/null 2>&1 && { echo found; exit; }; done; echo none')"

mkprofile nochrome "$LIVE_DOM" >/dev/null
mkadapter nochrome "file://$TMP/artifact.html" 'PUBLISHED'
rm -f "$TMP/driver-plan.json"
run env PATH="$NOCHROME" "$BROWSER" run nochrome publish --body=hi
t  'T9d run on a box with no browser REFUSES rather than publishing unchecked' 75 "$RC"
t  'T9d ...and the driver was never invoked' 'no' "$([[ -f "$TMP/driver-plan.json" ]] && echo yes || echo no)"
tc 'T9d ...saying it will not act on a session it did not verify' 'did not verify' "$ERR"

run env PATH="$NOCHROME" "$BROWSER" status nochrome
t  'T9e status on the same box stays QUIET — a probe that did not load must not page a person' 0 "$RC"
tc 'T9e ...while still naming what it could not do' 'UNKNOWN' "$OUT"

# T9f — the other UNKNOWN: a browser that IS present and fails. Same asymmetry,
# and it is a separate branch in the code from "no browser at all".
BROKENBIN="$TMP/brokenbin"; mkdir -p "$BROKENBIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BROKENBIN/google-chrome"; chmod +x "$BROKENBIN/google-chrome"
mkprofile brokenprobe "$LIVE_DOM" >/dev/null
mkadapter brokenprobe "file://$TMP/artifact.html" 'PUBLISHED'
rm -f "$TMP/driver-plan.json"
run env PATH="$BROKENBIN:$PATH" "$BROWSER" run brokenprobe publish --body=hi
t 'T9f a probe that failed to load refuses at the action' 75 "$RC"
t 'T9f ...without invoking the driver' 'no' "$([[ -f "$TMP/driver-plan.json" ]] && echo yes || echo no)"
run env PATH="$BROKENBIN:$PATH" "$BROWSER" status brokenprobe
t 'T9f ...and stays quiet at the scheduler' 0 "$RC"

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
