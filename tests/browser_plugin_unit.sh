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


# ================================== T10 server mode + the one-time viewer (DIVE-4118)
#
# The viewer is a live keyboard on a logged-in profile, so every arm here is a
# MUTANT of a way that keyboard gets handed to the wrong person:
#
#   T10b  the ticket file keeps the raw nonce  -> a stolen box is a stolen session
#   T10e  a leaked URL is replayable           -> a TTL alone never closes this
#   T10f  the URL works past its expiry
#   T10g  the URL works in a DIFFERENT session -> pasted-link theft
#   T10h  the nonce is accepted from argv      -> /proc/<pid>/cmdline is not a vault
#   T10i  a wrong nonce is accepted
#   T10j  revoke leaves the ticket redeemable
#   T10c  a box missing the packages half-starts instead of saying so
#   T10k  a viewer is minted with no session binding at all
#   T10m  x11vnc/websockify/Xvfb are started with a flag that opens the box
#   T10n  the VNC server dies before the ticket it was minted for expires
#   T10o  a spent ticket still tells an attacker whether a nonce was right
#   T10p  a ticket outlives the browser it views, and redeems onto a dead port
#   T10q  a REPLAY kills the live viewer -> a hoisted refusal that is not pure
#   T10r  a missing VNC credential SPENDS the customer's one-time link
#
# There is no X server on a CI runner, so Xvfb/x11vnc/websockify are FAKES on
# PATH. They are not product hooks: liveness is still the real PID check in
# _serve_running, and redemption is the real sha256 compare. The only override is
# the X socket DIRECTORY, which is a path — pointing it somewhere else cannot make
# a dead display read as live.
#
# AND THE FAKES RECORD THEIR ARGV. The first version of them ran `exec sleep 300`
# and threw "$@" away, which quietly deleted a whole test surface: the property
# this design LEADS with — nothing listens off-box — lives entirely in the flags
# we pass these three programs, so with argv discarded, dropping -localhost, or
# binding websockify to 0.0.0.0, or dropping -nolisten tcp changed nothing any arm
# could see (measured: 125/0 for each). A fake that ignores argv cannot grade a
# flag. These write "$*" to a file the T10m arms below assert on, so the flags are
# MEASURED here and not merely unverified against the real programs.
SBIN="$TMP/sbin"; mkdir -p "$SBIN"
ARGV="$TMP/argv"; mkdir -p "$ARGV"
export FIVEDIVE_BROWSER_X11_DIR="$TMP/x11"; mkdir -p "$FIVEDIVE_BROWSER_X11_DIR"
cat > "$SBIN/Xvfb" <<XVFB
#!/usr/bin/env bash
printf '%s\\n' "\$*" > "$ARGV/Xvfb.argv"
d="\${1#:}"
: > "$TMP/x11/X\$d"
exec sleep 300
XVFB
# AND THEY BIND THE PORT THEY WERE GIVEN. A fake that records its flags and
# listens on nothing is a bridge that is never up, which is indistinguishable
# from a bridge that is merely slow — and the difference between those two is the
# arm T10s exists to be. `exec` keeps the recorded pid the listening pid, so the
# product's own liveness bookkeeping stays honest.
listen_forever='import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1); time.sleep(300)'
cat > "$SBIN/x11vnc" <<VNC
#!/usr/bin/env bash
printf '%s\\n' "\$*" > "$ARGV/x11vnc.argv"
port=""; while (( \$# )); do [[ "\$1" == -rfbport ]] && port="\$2"; shift; done
exec python3 -c '$listen_forever' "\$port"
VNC
cat > "$SBIN/websockify" <<WS
#!/usr/bin/env bash
printf '%s\\n' "\$*" > "$ARGV/websockify.argv"
exec python3 -c '$listen_forever' "\${1##*:}"
WS
chmod +x "$SBIN/Xvfb" "$SBIN/x11vnc" "$SBIN/websockify"

# THE FAKES ARE STARTED IN THE BACKGROUND BY THE PRODUCT, so a capture read the
# instant the command returns can be missing for a reason that has nothing to do
# with the flag under test. That matters most for `tn`: "expected NOT to contain"
# passes on an EMPTY file exactly as it passes on a correct one, so an unlucky
# read turns a security arm into a green no-op. Every read below therefore waits,
# bounded, for a NON-EMPTY capture; every capture is cleared before the mint that
# should rewrite it (a stale one from the previous mint is the same lie with a
# later timestamp); and every `tn` over a capture is paired with a control arm
# that asserts the capture is not empty.
_reset_argv() { local n; for n in "$@"; do rm -f "$ARGV/$n.argv"; done; }
_wait_argv() {  # _wait_argv <prog> -> echoes its recorded argv, or nothing
  local f="$ARGV/$1.argv" i=0
  while (( i < 200 )); do [[ -s "$f" ]] && { cat "$f"; return 0; }; sleep 0.05; i=$(( i + 1 )); done
  return 1
}
nonempty() { [[ -n "$1" ]] && echo yes || echo no; }
# Reads /proc, never connects: connecting to the bridge would spend the -once
# admission this whole design hands to the customer.
port_state() {
  local hex; hex=$(printf '%04X' "$1")
  awk -v pat="$hex" '$4=="0A" && $2 ~ (":" pat "$") {f=1} END{exit !f}' /proc/net/tcp \
    && echo listening || echo dead
}

# The fake chrome above exits immediately (it cats a DOM). Server mode needs a
# chrome that STAYS UP, because "is the browser still serving" is a live PID.
SRVBIN="$TMP/srvbin"; mkdir -p "$SRVBIN"
cat > "$SRVBIN/google-chrome" <<'SRVC'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in --headless) exec sleep 0 ;; esac; done
exec sleep 300
SRVC
chmod +x "$SRVBIN/google-chrome"
SPATH="$SRVBIN:$SBIN:$PATH"

mkprofile viewsite "$LIVE_DOM" >/dev/null
VDIR="$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/viewsite"

# Is the customer still looking at their viewer? Read it the only way that cannot
# lie: the PIDs the product recorded, probed with kill -0. "The command exited 77"
# says nothing about whether it killed something on the way out.
vnc_state() {
  local f="$VDIR/.5dive-viewer" p
  [[ -f "$f" ]] || { echo dead; return; }
  for p in $(sed -n 's/^vnc_pid=//p' "$f") $(sed -n 's/^ws_pid=//p' "$f"); do
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null || { echo dead; return; }
  done
  echo live
}

# --- T10a a display-less box SERVES instead of refusing -----------------------
run env PATH="$SPATH" DISPLAY= "$BROWSER" serve viewsite
t  'T10a serve starts on a box with no display' 0 "$RC"
tc 'T10a ...and says which display it took' 'serving viewsite on :' "$OUT"
t  'T10a ...and records a live browser' '0' "$(env PATH="$SPATH" bash -c '
     f='"$VDIR"'/.5dive-serve; kill -0 "$(sed -n s/^chrome_pid=//p "$f")" 2>/dev/null && echo 0 || echo 1')"
run env PATH="$SPATH" DISPLAY= "$BROWSER" serve viewsite
tc 'T10a ...and a second serve REUSES it, never a second chrome on one profile' \
   'already serving' "$OUT"

# 4021 refused here. That refusal is what made the product need ssh -X.
run env PATH="$SPATH" DISPLAY= "$BROWSER" auth viewsite
t  'T10a auth on a display-less box no longer dead-ends' 0 "$RC"
tn 'T10a ...and does not tell a paying customer to forward an X display' 'Forward one' "$ERR"

# --- T10b the ticket is a hash, never the nonce ------------------------------
_reset_argv x11vnc websockify
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=600
t  'T10b viewer mints' 0 "$RC"
NONCE="${OUT##*/}"
tc 'T10b ...printing a path with the nonce in it' '/browser/viewer/viewsite/' "$OUT"
t  'T10b ...a 64-hex nonce' 64 "${#NONCE}"
t  'T10b THE TICKET FILE DOES NOT CONTAIN THE RAW NONCE' 'absent' \
   "$(grep -qF "$NONCE" "$VDIR/.5dive-viewer.ticket" && echo present || echo absent)"
tc 'T10b ...it contains its sha256' "$(printf '%s' "$NONCE" | sha256sum | cut -d' ' -f1)" \
   "$(cat "$VDIR/.5dive-viewer.ticket")"
t  'T10b ...and the ticket is 0600' '600' "$(stat -c '%a' "$VDIR/.5dive-viewer.ticket")"

# --- T10d/T10e it redeems ONCE ------------------------------------------------
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10d the right nonce in the right session redeems' 0 "$RC"
tc 'T10d ...handing the relay a LOOPBACK target and nothing routable' 'target=127.0.0.1:' "$OUT"
tn 'T10d ...never a routable one' '0.0.0.0' "$OUT"
# x11vnc is started with -passwdfile inside the 0700 profile dir, which is the one
# place DIVE-4021's isolation stops the relay from reading. If redemption does not
# emit the password, the relay gets a port that prompts for a secret nobody has —
# a viewer that provably cannot be entered, in a PR whose whole point is the login.
REDEEMED_PW="$(sed -n 's/^password=//p' <<<"$OUT")"
t  'T10d THE VIEWER PASSWORD IS EMITTED WITH THE TARGET, not stranded in the profile dir' \
   'yes' "$([[ -n "$REDEEMED_PW" ]] && echo yes || echo no)"
t  'T10d ...and it is the password x11vnc was actually started with' 'match' \
   "$([[ "$REDEEMED_PW" == "$(cat "$VDIR/.5dive-viewer.pw" 2>/dev/null)" ]] && echo match || echo differs)"
VNC_ARGV_D="$(_wait_argv x11vnc)"
t  'T10d (control) x11vnc recorded its argv, so the two arms below are graded' \
   'yes' "$(nonempty "$VNC_ARGV_D")"
tc 'T10d ...which x11vnc was handed as a FILE, never in argv' '-passwdfile' "$VNC_ARGV_D"
tn 'T10d ...so the password itself never reaches /proc/<pid>/cmdline' \
   "$REDEEMED_PW" "$VNC_ARGV_D"
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10e A REPLAY OF THE SAME LINK IS REFUSED' 77 "$RC"
tc 'T10e ...saying so in words a customer can act on' 'already been used' "$ERR"

# --- T10f expiry --------------------------------------------------------------
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=60
NONCE2="${OUT##*/}"
python3 - "$VDIR/.5dive-viewer.ticket" <<'EXPIRE'
import sys,re,time
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(re.sub(r'^expires_at=.*$','expires_at=%d'%(time.time()-1),s,flags=re.M))
EXPIRE
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE2' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10f AN EXPIRED LINK IS REFUSED even with the right nonce' 77 "$RC"
tc 'T10f ...and says the browser session itself survived' 'untouched' "$ERR"

# --- T10g the binding ---------------------------------------------------------
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=600
NONCE3="${OUT##*/}"
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE3' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-B"
t  'T10g A VALID LINK IN A DIFFERENT SESSION IS REFUSED' 77 "$RC"
tc 'T10g ...naming the reason, because this is the pasted-link case' 'different dashboard session' "$ERR"
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE3' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10g ...and the failed attempt did NOT consume it for the rightful session' 0 "$RC"

# --- T10h the nonce never goes in argv ---------------------------------------
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=600
NONCE4="${OUT##*/}"
# stdin from /dev/null on purpose: a MUTANT that accepts the argv nonce falls
# through to the stdin read, and an arm that hangs on a regression is an arm that
# hangs CI instead of failing it.
run env PATH="$SPATH" bash -c "'$BROWSER' viewer-redeem viewsite '--nonce=$NONCE4' --session=sess-A < /dev/null"
t  'T10h A NONCE PASSED IN ARGV IS REFUSED, not quietly accepted' 64 "$RC"
tc 'T10h ...naming why' '/proc/<pid>/cmdline' "$ERR"

# --- T10i a wrong nonce -------------------------------------------------------
run env PATH="$SPATH" bash -c "printf '%s' 'deadbeef' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10i a wrong nonce is refused' 77 "$RC"
tn 'T10i ...without leaking the real one' "$NONCE4" "$ERR$OUT"

# --- T10j revoke --------------------------------------------------------------
run env PATH="$SPATH" "$BROWSER" viewer-revoke viewsite
t  'T10j revoke exits 0' 0 "$RC"
tc 'T10j ...and says the login SURVIVES the view dying' 'stays logged in' "$OUT"
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE4' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10j A REVOKED LINK IS DEAD' 77 "$RC"

# --- T10k binding is mandatory ------------------------------------------------
run env PATH="$SPATH" "$BROWSER" viewer viewsite --ttl=600
t  'T10k AN UNBOUND TICKET CANNOT BE MINTED AT ALL' 64 "$RC"
tc 'T10k ...and the escape is explicit, never implicit' '--bind=local' "$ERR"
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=99999
t  'T10k a ttl past the re-auth window is refused' 64 "$RC"

# --- T10m NOTHING LISTENS OFF-BOX, measured on the argv the fakes recorded -----
# This is the property the README and the design note LEAD with, and until the
# fakes recorded argv it was graded by zero arms. Each assertion below is the
# mutant it kills: drop -localhost and x11vnc answers every seat on the box;
# bind websockify to 0.0.0.0 and the bridge is reachable from the internet; drop
# -nolisten tcp and the X display itself is an unauthenticated remote keyboard.
_reset_argv x11vnc websockify
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=900
t  'T10m viewer mints (fixture for the argv arms)' 0 "$RC"
NONCE5="${OUT##*/}"
VNC_ARGV="$(_wait_argv x11vnc)"; WS_ARGV="$(_wait_argv websockify)"; X_ARGV="$(_wait_argv Xvfb)"
t  'T10m (control) x11vnc recorded its argv'     'yes' "$(nonempty "$VNC_ARGV")"
t  'T10m (control) websockify recorded its argv' 'yes' "$(nonempty "$WS_ARGV")"
t  'T10m (control) Xvfb recorded its argv'       'yes' "$(nonempty "$X_ARGV")"
tc 'T10m x11vnc IS BOUND TO LOOPBACK'                 '-localhost'   "$VNC_ARGV"
tc 'T10m ...and accepts exactly one client'           '-once'        "$VNC_ARGV"
tc 'T10m the websocket bridge LISTENS ON 127.0.0.1'   '127.0.0.1:'   "$WS_ARGV"
tn 'T10m ...and never on every interface'             '0.0.0.0'      "$WS_ARGV"
tc 'T10m ...bridging to a loopback VNC port, not a routable one' '127.0.0.1:' "${WS_ARGV#* }"
tc 'T10m THE X DISPLAY REFUSES TCP ENTIRELY'          '-nolisten tcp' "$X_ARGV"

# --- T10n the VNC timeout IS the ticket TTL -----------------------------------
# x11vnc -timeout n exits unless a client connects inside the first n seconds. A
# hardcoded 30 meant the viewer was dead half a minute into a ticket that
# advertises 60-3600s, while redemption still exited 0 and SPENT the ticket: the
# customer gets a used-up link and a port with nothing behind it. The window the
# ticket promises and the window x11vnc honours must be one number.
tc 'T10n x11vnc is given the TICKET TTL, not a constant shorter than the minimum' \
   '-timeout 900' "$VNC_ARGV"
_reset_argv x11vnc
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=60
VNC_ARGV_N="$(_wait_argv x11vnc)"
t  'T10n (control) the second mint recorded a FRESH argv, not the one before it' \
   'yes' "$(nonempty "$VNC_ARGV_N")"
tc 'T10n ...and it TRACKS the ttl rather than matching one value by luck' \
   '-timeout 60' "$VNC_ARGV_N"

# --- T10o a spent ticket is not an oracle ------------------------------------
# The design note claims the spent-state check runs BEFORE the nonce compare. Move
# the compare first and every other arm still passes (measured 125/0): the only
# thing that changes is WHICH refusal a used ticket gives to a WRONG nonce — and
# that difference is exactly the oracle. A dead ticket must not grade guesses.
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=600
NONCE6="${OUT##*/}"
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE6' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10o (fixture) the ticket is spent' 0 "$RC"
run env PATH="$SPATH" bash -c "printf '%s' 'deadbeef' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10o a WRONG nonce on a SPENT ticket is refused' 77 "$RC"
tc 'T10o ...for being spent, so it cannot answer "was that the right nonce"' \
   'already been used' "$ERR"
tn 'T10o ...and never grades the guess' 'not valid for' "$ERR"

# --- T10p stopping the browser takes the ticket with it -----------------------
# A ticket that outlives its viewer redeems 0 onto a dead port — the same
# customer-facing failure as the timeout bug, arriving by a different door.
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=600
NONCE7="${OUT##*/}"
run env PATH="$SPATH" DISPLAY= "$BROWSER" serve viewsite --stop
t  'T10p serve --stop exits 0' 0 "$RC"
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE7' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10p A TICKET DOES NOT SURVIVE THE BROWSER IT VIEWS' 77 "$RC"
t  'T10p ...and the VNC password is not left behind in the profile' 'no' \
   "$([[ -f "$VDIR/.5dive-viewer.pw" ]] && echo yes || echo no)"
t  'T10p ...while the PROFILE ITSELF survives — the durable half' 'yes' \
   "$([[ -d "$VDIR" ]] && echo yes || echo no)"
env PATH="$SPATH" DISPLAY= "$BROWSER" serve viewsite >/dev/null 2>&1 || true

# --- T10q A REPLAY DOES NOT KILL THE LIVE VIEWER ------------------------------
# The spent-state check is hoisted above the session binding and the nonce compare
# for a LEAK reason (T10o). That hoist also puts it ahead of everything that
# establishes the caller is anyone at all, so any side effect attached to it fires
# for a call carrying NO valid nonce and NO valid session — naming the site is the
# entire cost of entry. When that side effect was _viewer_stop, one such call
# killed the customer's LIVE viewer and deleted its credential: exactly the denial
# the binding exists to prevent (design note §4, "a wrong-session attempt does not
# spend the ticket for the rightful one"). The likeliest trigger was never an
# attacker but the customer's own phone reloading the viewer URL mid-login. A
# refusal hoisted for a leak reason must be PURE: compute, die, touch nothing.
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=600
t  'T10q viewer mints onto the live browser' 0 "$RC"
NONCE8="${OUT##*/}"
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE8' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10q the customer redeems it legitimately' 0 "$RC"
t  'T10q ...and the viewer they are now looking at is LIVE' 'live' "$(vnc_state)"
run env PATH="$SPATH" bash -c "printf '%s' 'totally-wrong-nonce' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-EVIL"
t  'T10q a replay with a WRONG nonce AND a WRONG session is refused' 77 "$RC"
t  'T10q ...AND THE CUSTOMER IS STILL LOOKING AT THEIR VIEWER' 'live' "$(vnc_state)"
t  'T10q ...and its credential was not deleted out from under them' 'yes' \
   "$([[ -s "$VDIR/.5dive-viewer.pw" ]] && echo yes || echo no)"
tc 'T10q ...and the refusal SAYS the session survived, so the customer waits instead of re-logging in' \
   'untouched' "$ERR"

# --- T10r a viewer with no credential REFUSES WITHOUT SPENDING THE TICKET -----
# Redemption reads the VNC password BEFORE it consumes the ticket, so a viewer
# whose credential is gone cannot burn the customer's one-time link merely to
# report that it is gone. The die string PROMISES "The ticket was NOT spent" —
# until these arms nothing checked the promise was kept: moving the consume ahead
# of the read passed all 147 other arms, the same unmeasured-claim shape as T10m.
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=600
t  'T10r viewer mints' 0 "$RC"
NONCE9="${OUT##*/}"
PW_SAVED="$(cat "$VDIR/.5dive-viewer.pw")"
rm -f "$VDIR/.5dive-viewer.pw"
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE9' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10r a redemption onto a viewer with no credential is refused' 69 "$RC"
tc 'T10r ...because a target without its password is a port nobody can enter' 'credential is gone' "$ERR"
t  'T10r THE TICKET IS STILL OPEN — the refusal did not spend it' 'state=open' \
   "$(grep '^state=' "$VDIR/.5dive-viewer.ticket")"
# An EMPTY credential file is the same customer outcome through a different door.
( umask 077; : > "$VDIR/.5dive-viewer.pw" )
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE9' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10r an EMPTY credential file is refused too' 69 "$RC"
t  'T10r ...and also leaves the ticket open' 'state=open' \
   "$(grep '^state=' "$VDIR/.5dive-viewer.ticket")"
# ...and "not spent" only means anything if the SAME link still works afterwards.
( umask 077; printf '%s\n' "$PW_SAVED" > "$VDIR/.5dive-viewer.pw" )
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE9' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10r AND THE SAME NONCE REDEEMS AFTERWARDS' 0 "$RC"
tc 'T10r ...handing over the credential it could not find a moment ago' "password=$PW_SAVED" "$OUT"

# --- T10s A LINK IS NEVER ISSUED ONTO A BRIDGE THAT IS NOT LISTENING YET ------
# The mint starts x11vnc and websockify in the BACKGROUND and returns. "Started"
# and "accepting" are two different moments, and the product's own shape is a
# one-time link handed to a relay that redeems it AT ONCE — dashboard mints,
# relay redeems, customer's phone connects. Redeem inside that window and the
# relay is handed 127.0.0.1:<port> with nothing behind it: a blank viewer and a
# SPENT link, the same customer-facing failure as the old hardcoded -timeout,
# reached by a race instead of by a constant. These arms read /proc rather than
# connecting, because connecting is itself the single admission x11vnc -once
# gives the customer.
_reset_argv x11vnc websockify
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=600
t  'T10s viewer mints' 0 "$RC"
NONCE10="${OUT##*/}"
PORT10="$(sed -n 's/^port=//p' "$VDIR/.5dive-viewer.ticket")"
t  'T10s (control) the ticket names a bridge port' 'yes' "$(nonempty "$PORT10")"
t  'T10s BY THE TIME THE LINK EXISTS, THE BRIDGE IS ALREADY ACCEPTING' \
   'listening' "$(port_state "$PORT10")"
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE10' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10s a relay that redeems the INSTANT it gets the link is served' 0 "$RC"
TGT10="$(sed -n 's/^target=127.0.0.1://p' <<<"$OUT")"
t  'T10s ...and the target it was handed has something on it' 'listening' "$(port_state "$TGT10")"

# The mutant: a bridge that never binds. Without the wait, this mints a ticket
# and exits 0 onto a dead port — the failure above, made permanent.
NOBIND="$TMP/nobind"; mkdir -p "$NOBIND"
cat > "$NOBIND/websockify" <<WS
#!/usr/bin/env bash
printf '%s\\n' "\$*" > "$ARGV/websockify.argv"
exec sleep 300
WS
chmod +x "$NOBIND/websockify"
# An OPEN ticket is left standing on purpose: the failing mint kills the viewer
# that ticket points at, so it must take the ticket with it. Otherwise the
# customer holds a live one-time link to a viewer that no longer exists — the
# dead-port failure again, now reached by a mint that FAILED.
_reset_argv x11vnc websockify
run env PATH="$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=600
t  'T10s (fixture) an OPEN ticket stands before the failing mint' 'state=open' \
   "$(grep '^state=' "$VDIR/.5dive-viewer.ticket")"
NONCE11="${OUT##*/}"
_reset_argv websockify
run env PATH="$NOBIND:$SPATH" "$BROWSER" viewer viewsite --bind=sess-A --ttl=600
t  'T10s A BRIDGE THAT NEVER BINDS ISSUES NO LINK AT ALL' 69 "$RC"
t  'T10s (control) it really was started, it just never listened' 'yes' \
   "$(nonempty "$(_wait_argv websockify)")"
tn 'T10s ...so there is no nonce for a relay to redeem' '/browser/viewer/' "$OUT"
tc 'T10s ...and the refusal names what did not come up' 'never started listening' "$ERR"
t  'T10s ...no ticket is left OPEN onto the dead port' 'no' \
   "$(grep -q '^state=open' "$VDIR/.5dive-viewer.ticket" && echo yes || echo no)"
t  'T10s ...the half-started viewer was reaped, not left running' 'dead' "$(vnc_state)"
t  'T10s ...its credential did not survive the failed mint' 'no' \
   "$([[ -f "$VDIR/.5dive-viewer.pw" ]] && echo yes || echo no)"
run env PATH="$SPATH" bash -c "printf '%s' '$NONCE11' | '$BROWSER' viewer-redeem viewsite --nonce=- --session=sess-A"
t  'T10s ...AND THE TICKET THAT WAS STANDING BEFORE IT DIED WITH THE VIEWER' 77 "$RC"
t  'T10s ...and the BROWSER survives, because a failed view is not a lost login' '0' \
   "$(env PATH="$SPATH" bash -c '
        f='"$VDIR"'/.5dive-serve; kill -0 "$(sed -n s/^chrome_pid=//p "$f")" 2>/dev/null && echo 0 || echo 1')"

# --- T10c a box without the packages says so, and starts nothing --------------
mkprofile barebox "$LIVE_DOM" >/dev/null
# This host HAS Xvfb, so "a bare box" has to be constructed rather than assumed:
# a PATH of everything except the three server-mode packages. Trimming PATH to
# /usr/bin silently passed this arm against a box that had them.
MINBIN="$TMP/minbin"; mkdir -p "$MINBIN"
for b in /usr/bin/* /bin/*; do
  case "${b##*/}" in Xvfb|x11vnc|websockify|chrom*|google-chrome*) continue ;; esac
  [[ -x "$b" ]] && ln -sf "$b" "$MINBIN/${b##*/}" 2>/dev/null
done
t 'T10c ...(control) the bare-box PATH really has no Xvfb' 'no' \
  "$(PATH="$FAKEBIN:$MINBIN" command -v Xvfb >/dev/null 2>&1 && echo yes || echo no)"
run env PATH="$FAKEBIN:$MINBIN" "$BROWSER" serve barebox
t  'T10c serve on a box with no Xvfb fails closed' 69 "$RC"
tc 'T10c ...naming what is missing' 'Xvfb' "$ERR"
t  'T10c ...and leaves no half-started state behind' 'no' \
   "$([[ -f "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/barebox/.5dive-serve" ]] && echo yes || echo no)"
tc 'T10c ...refusing on the PRECONDITION, not on a launch that then failed' \
   'cannot run a server-mode browser' "$ERR"
# The missing-Xvfb arm alone does NOT grade the precondition: with it deleted,
# Xvfb-not-on-PATH still dies at the "did not start" check with the same exit
# status and the same word in the message. A box that has Xvfb and NO chromium
# is the case that separates them — without the precondition the chrome launch
# runs with an empty binary name and a pidfile is written for a browser that was
# never started, which is exactly "the tile says connected and nothing is there".
mkprofile nochrome "$LIVE_DOM" >/dev/null
run env PATH="$MINBIN:$SBIN" "$BROWSER" serve nochrome
t  'T10c2 a box with a display server but no chromium fails closed' 69 "$RC"
tc 'T10c2 ...naming chromium' 'chromium' "$ERR"
t  'T10c2 ...and writes NO pidfile for a browser that never started' 'no' \
   "$([[ -f "$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/nochrome/.5dive-serve" ]] && echo yes || echo no)"

# --- T10l a profile this seat cannot own is refused BEFORE any of this --------
BADV="$FIVEDIVE_BROWSER_PROFILE_ROOT/$SEAT/loosev"; mkdir -p "$BADV"; chmod 755 "$BADV"
run env PATH="$SPATH" "$BROWSER" serve loosev
t  'T10l a group-readable profile is refused by serve, not repaired' 77 "$RC"
run env PATH="$SPATH" "$BROWSER" viewer loosev --bind=sess-A
t  'T10l ...and by viewer' 77 "$RC"
chmod 700 "$BADV"

env PATH="$SPATH" "$BROWSER" serve viewsite --stop >/dev/null 2>&1 || true

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
