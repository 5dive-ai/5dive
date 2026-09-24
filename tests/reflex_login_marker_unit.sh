#!/usr/bin/env bash
# DIVE-4928 — `5dive reflex login-marker`: reflex drafts a browser adapter's login
# check from two renders, in SHADOW. The code proposes and verifies; the model
# only picks; nothing is written to an adapter directory.
#
# WHAT THIS GRADES
#  L1. Both-halves bar. Every signed-out candidate matches the signed-out render
#      and matches the signed-in render ZERO times, counted by grep -iE. A token on
#      both pages (the search box) is not a candidate.
#  L2. fake:first proposes the heuristic's top pick as an adapter in the browser's
#      own shape, and --compare scores it against a hand-written adapter.
#  L3. Fail closed. A backend choosing a key that is not an option, a backend that
#      hangs past --timeout, and a backend that prints nothing each propose NOTHING
#      (choice none, an error named, no adapter).
#  L4. What leaves the box. The request carries candidate markers and counts, never
#      page text. --spa signed-in candidates never carry a digit or a value that is
#      page content (the account name in a class, a numeric user id).
#  L5. A challenge render (captcha, "Prove your humanity") is refused, exit 3.
#  L6. Shadow is structural. --out into an adapters/ or .adapters/ directory is
#      refused and writes nothing; --out elsewhere writes the adapter.
#  L7. The receipt. decision.browser-login-marker, mode=shadow, carries a marker
#      HASH and no marker or page text; `reflex log --policy=browser-login-marker`
#      lists it; the replay does not count it.
#  L8. The built-in OpenRouter call sends this request's own instructions and
#      criteria, and a gate request is sent exactly as before (fake curl on PATH).
#  L9. Real-shaped: every shipped hand-written marker is itself among the
#      candidates of a render that carries it (a fixture per shipped marker form).
#  L10. A per-render token (hex suffix, UUID, digit run) is never a candidate.
#  L11. A second signed-out render: a candidate must match every one.
#  M.  Mutants: drop the signed-in filter -> L1 red; drop the challenge check -> L5
#      red; random-token filter off -> L10 red. Each with an unmutated control.
#
# Throwaway STATE_DIR, fake backends and a fake curl only: no root, no network, no key.
# Run: bash tests/reflex_login_marker_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/reflex-login-marker-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/routing_receipt.sh lib/reflex.sh \
         cmd_task.sh cmd_reflex.sh cmd_reflex_login_marker.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
JSON_MODE=0
audit_log() { return 0; }

pass=0; fail=0
ok_t()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { fail=$((fail+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == 0 ]]; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }

STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$STATE_DIR/agents.json"; BOX_CONFIG="$STATE_DIR/box.json"
mkdir -p "$TASKS_DIR"; printf '{"agents":{"main":{},"dev":{}}}\n' >"$REGISTRY"; printf '{}\n' >"$BOX_CONFIG"
tasks_db_init >/dev/null 2>&1
db() { sqlite3 "$TASKS_DB" "$1"; }

# ── fixtures ────────────────────────────────────────────────────────────────
OUT="$TMP/out.html"; IN="$TMP/in.html"
cat >"$OUT" <<'EOF'
<html><head><title>Sign in to Example</title><meta name="viewport" content="width=device-width"></head>
<body><header><form role="search" action="/search"><input name="q" type="text"></form></header>
<main class="auth-page login-box"><h1>Sign in</h1>
<form action="/session" method="post"><input type="text" name="login" id="login_field" autocomplete="username">
<input type="password" name="password" id="password" autocomplete="current-password">
<button type="submit" data-testid="signin-button">Sign in</button></form>
<a href="/password_reset">Forgot?</a></main><footer class="site-footer">PAGETEXT-PUBLIC</footer></body></html>
EOF
cat >"$IN" <<'EOF'
<html><head><title>Example - alice99 inbox</title><meta name="viewport" content="width=device-width"></head>
<body><header><form role="search" action="/search"><input name="q" type="text"></form>
<nav id="account-menu" class="app-shell-nav"><a href="/alice99" class="avatar-alice99" id="user-1234567">alice99</a></nav></header>
<main id="app-shell" class="chatlist main-feed"><div data-testid="primaryColumn">SECRETDM hello from a friend</div></main>
<footer class="site-footer">PAGETEXT-PUBLIC</footer></body></html>
EOF
HAND="$TMP/hand.json"
jq -n '{site:"example.test", probe:{url:"https://example.test/settings", logged_out_when_dom_matches:"action=[\"'"'"']?/session"}, actions:{}}' >"$HAND"

lm() { ( JSON_MODE=0; FIVEDIVE_REFLEX_RECEIPTS=0 _reflex_login_marker "$@" ) 2>"$TMP/err"; }
lmj() { lm "$@" --json; }

# ── L1: the both-halves bar ─────────────────────────────────────────────────
l1_arm() { # prints nothing; rc 0 when every candidate is out>=1 and in==0, and q is absent
  local r; r=$(lmj example.test --logged-out="$OUT" --logged-in="$IN" --url=https://example.test/settings --backend=fake:first) || return 1
  jq -e '(.logged_out.candidates | length) > 0
         and all(.logged_out.candidates[]; .out >= 1 and .in == 0)
         and ([.logged_out.candidates[].marker] | index("name=[\"'"'"']?q") == null)
         and ([.logged_out.candidates[].marker] | index("class=\"[^\"]*site-footer") == null)' <<<"$r" >/dev/null || return 1
  # Re-count every candidate with grep itself: the report's numbers are the engine's.
  local m
  while IFS= read -r m; do
    [[ $(grep -oiE -- "$m" "$IN" | wc -l) -eq 0 && $(grep -oiE -- "$m" "$OUT" | wc -l) -ge 1 ]] || return 1
  done < <(jq -r '.logged_out.candidates[].marker' <<<"$r")
  return 0
}
l1_arm; check "L1 every signed-out candidate matches signed-out and never signed-in; the search box and footer are not candidates" $?

# ── L2: fake:first + compare ─────────────────────────────────────────────────
R2=$(lmj example.test --logged-out="$OUT" --logged-in="$IN" --compare="$HAND" --backend=fake:first); rc=$?
check "L2 rc 0" "$rc" "$(cat "$TMP/err")"
jq -e '.logged_out.choice == "m1" and .logged_out.marker == .logged_out.heuristic_top
       and .adapter.site == "example.test" and .adapter.probe.url == "https://example.test/settings"
       and .adapter.probe.logged_out_when_dom_matches == .logged_out.marker and .adapter.actions == {}
       and (.adapter._comment | test("SHADOW")) and .written == false and .mode == "shadow"' <<<"$R2" >/dev/null
check "L2 fake:first proposes the heuristic top pick as an adapter in the browser's shape" $?
jq -e '.compare.logged_out.hand_out == 1 and .compare.logged_out.hand_in == 0 and .compare.logged_out.hand_classifies == true
       and .compare.logged_out.hand_among_candidates == true
       and (.compare.logged_out.pick_is_hand == (.logged_out.marker == "action=[\"'"'"']?/session"))' <<<"$R2" >/dev/null
check "L2 --compare counts the hand marker on both renders and scores the pick against it" $?
H=$(lm example.test --logged-out="$OUT" --url=https://example.test/x --backend=fake:first)
grep -q 'NOT SUPPLIED' <<<"$H" && grep -q 'UNMEASURED' <<<"$H"
check "L2 no signed-in render: the human report and the adapter comment say the half is unmeasured" $?

# ── L3: fail closed ──────────────────────────────────────────────────────────
R3=$(lmj example.test --logged-out="$OUT" --logged-in="$IN" --url=https://example.test/s --backend='echo "{\"choice\":\"m999\",\"confidence\":0.99}"')
jq -e '.logged_out.choice == "none" and .logged_out.error == "invalid_choice" and .adapter == null' <<<"$R3" >/dev/null
check "L3 a choice that is not an option proposes nothing (invalid_choice)" $?
t0=$(date +%s)
R3=$(lmj example.test --logged-out="$OUT" --logged-in="$IN" --url=https://example.test/s --backend='sleep 30' --timeout=1)
t1=$(date +%s)
jq -e '.logged_out.choice == "none" and .logged_out.error == "timeout" and .adapter == null' <<<"$R3" >/dev/null && (( t1 - t0 < 10 ))
check "L3 a backend that hangs is cut off at --timeout and proposes nothing" $?
R3=$(lmj example.test --logged-out="$OUT" --logged-in="$IN" --url=https://example.test/s --backend='cat >/dev/null')
jq -e '.logged_out.choice == "none" and .logged_out.error == "no_response" and .adapter == null' <<<"$R3" >/dev/null
check "L3 a backend that prints nothing proposes nothing (no_response)" $?
R3=$(lmj example.test --logged-out="$OUT" --logged-in="$IN" --url=https://example.test/s --backend='echo "{\"choice\":\"none\",\"confidence\":0.9}"')
jq -e '.logged_out.choice == "none" and .logged_out.error == null and .adapter == null' <<<"$R3" >/dev/null
check "L3 the model answering none proposes nothing, and is not an error" $?

# ── L4: what leaves the box ──────────────────────────────────────────────────
export RX_REQ_LOG="$TMP/req.jsonl"; : >"$RX_REQ_LOG"
TEE='tee -a "$RX_REQ_LOG" | jq -c "{choice: .options[0], confidence: 0.8}"'
R4=$(lmj example.test --logged-out="$OUT" --logged-in="$IN" --url=https://example.test/s --spa --backend="$TEE")
[[ $(wc -l <"$RX_REQ_LOG") -eq 2 ]] && ! grep -qE 'SECRETDM|PAGETEXT|alice99|1234567|hello from' "$RX_REQ_LOG"
check "L4 two requests (signed-out, signed-in), neither carries page text, the account name or its id" $? "$(cat "$RX_REQ_LOG")"
jq -e '.logged_in.candidates | length > 0 and all(.[]; (.marker | test("[0-9]") | not) and .in >= 1 and .out == 0)' <<<"$R4" >/dev/null \
  && jq -e '[.logged_in.candidates[].marker] | (index("id=[\"'"'"']?app-shell") != null) and (index("class=\"[^\"]*chatlist") != null)' <<<"$R4" >/dev/null
check "L4 --spa signed-in candidates are digit-free, signed-in-only, and include the app shell" $?
jq -e '.adapter.probe.logged_in_when_dom_matches == .logged_in.marker and .logged_in.marker != null' <<<"$R4" >/dev/null
check "L4 --spa puts the signed-in pick in the proposed adapter" $?
head -n1 "$RX_REQ_LOG" | jq -e '.state.page_title == "Sign in to Example" and .state.half == "logged_out"
     and (.options | last) == "none" and (.criteria | has("none")) and (.criteria.m1 | test("signed out"))' >/dev/null \
  && sed -n 2p "$RX_REQ_LOG" | jq -e '.state | has("page_title") | not' >/dev/null
check "L4 the signed-out request carries the public page title; the signed-in one carries no title" $?
lm example.test --logged-out="$OUT" --url=https://example.test/s --spa --backend=fake:first >/dev/null; rc=$?
check "L4 --spa without a signed-in render is a usage error" "$(( rc == E_USAGE ? 0 : 1 ))"

# ── L5: challenge refused ────────────────────────────────────────────────────
CH="$TMP/challenge.html"
printf '<html><head><title>Reddit - Prove your humanity</title></head><body><form action="/login/?x=1"><input name="username"></form></body></html>\n' >"$CH"
CH2="$TMP/challenge2.html"
printf '<html><head><title>Sign in</title></head><body><div class="g-recaptcha"></div><form action="/session"><input name="login"></form></body></html>\n' >"$CH2"
l5_arm() {
  local rc1 rc2
  lm example.test --logged-out="$CH" --url=https://example.test/s --backend=fake:first >/dev/null; rc1=$?
  lm example.test --logged-out="$CH2" --url=https://example.test/s --backend=fake:first >/dev/null; rc2=$?
  (( rc1 == E_VALIDATION && rc2 == E_VALIDATION )) && grep -q 'challenge page' "$TMP/err"
}
l5_arm; check "L5 a challenge render (interstitial title, recaptcha) is refused with exit 3" $?
lm example.test --logged-out="$OUT" --url=https://example.test/s --backend=fake:first >/dev/null
check "L5 a real sign-in page that mentions captcha in a script is NOT refused" $?

# ── L6: shadow is structural ─────────────────────────────────────────────────
mkdir -p "$TMP/seat/.adapters" "$TMP/pkg/adapters"
lm example.test --logged-out="$OUT" --url=https://example.test/s --backend=fake:first --out="$TMP/seat/.adapters/example.test.json" >/dev/null; r1=$?
lm example.test --logged-out="$OUT" --url=https://example.test/s --backend=fake:first --out="$TMP/pkg/adapters/example.test.json" >/dev/null; r2=$?
(( r1 == E_VALIDATION && r2 == E_VALIDATION )) && [[ ! -e "$TMP/seat/.adapters/example.test.json" && ! -e "$TMP/pkg/adapters/example.test.json" ]]
check "L6 --out into .adapters/ or adapters/ is refused and writes nothing" $?
ln -s "$TMP/seat/.adapters" "$TMP/adlink"
lm example.test --logged-out="$OUT" --url=https://example.test/s --backend=fake:first --out="$TMP/adlink/example.test.json" >/dev/null; r3=$?
(( r3 == E_VALIDATION )) && [[ ! -e "$TMP/seat/.adapters/example.test.json" ]]
check "L6 --out through a symlink into .adapters/ is refused and writes nothing" $?
lm example.test --logged-out="$OUT" --logged-in="$IN" --url=https://example.test/s --backend=fake:first --out="$TMP/proposal.json" >/dev/null
jq -e '.site == "example.test" and (.probe.logged_out_when_dom_matches | type) == "string" and .actions == {}' "$TMP/proposal.json" >/dev/null
check "L6 --out elsewhere writes the proposed adapter" $?

# ── L7: the receipt ──────────────────────────────────────────────────────────
( JSON_MODE=0; _reflex_login_marker example.test --logged-out="$OUT" --logged-in="$IN" --compare="$HAND" --backend=fake:first ) >/dev/null 2>&1
RC7=$(db "SELECT detail FROM lifecycle_events WHERE kind='decision.browser-login-marker' ORDER BY id DESC LIMIT 1;")
jq -e '.mode == "shadow" and .policy == "browser-login-marker" and .result == "m1" and .effect.acted == false
       and .effect.written == false and (.effect.marker_hash | test("^sha256:[0-9a-f]{16}$"))
       and .signals.site == "example.test" and .signals.signed_in_render == true
       and (.effect.compare | has("pick_is_hand")) and (.candidates | index("none") != null)' <<<"$RC7" >/dev/null \
  && ! grep -qE 'session|password|login_field|PAGETEXT|Sign in|autocomplete' <<<"$RC7"
check "L7 a shadow receipt with a marker hash, the compare booleans, and no marker or page text" $? "$RC7"
LOG=$( ( JSON_MODE=0; _reflex_log --policy=browser-login-marker ) 2>&1 ); rc=$?
(( rc == 0 )) && grep -q 'browser-login-marker' <<<"$LOG"
check "L7 reflex log --policy=browser-login-marker lists it" $? "$LOG"
( JSON_MODE=0; _reflex_replay --policy=browser-login-marker ) >/dev/null 2>&1; rc=$?
check "L7 the replay still refuses the shadow-only policy (it has no history to score)" "$(( rc == E_VALIDATION ? 0 : 1 ))"
REP=$( ( JSON_MODE=1; _reflex_replay --since=1d ) 2>/dev/null)
jq -e '[.policies[].policy] | index("browser-login-marker") == null' <<<"$REP" >/dev/null
check "L7 the replay report does not count the shadow receipt" $? "$REP"

# ── L8: the built-in OpenRouter call, through a fake curl ────────────────────
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
# fake curl: save the body, answer m2 (or opt1 for a gate) with 0.91
out="" body=""
while (( $# )); do case "$1" in -o) out="$2"; shift ;; --data-binary) body="${2#@}"; shift ;; esac; shift; done
cp "$body" "$FAKE_CURL_BODY"
c=$(jq -r 'if (.questions.decision.criteria | has("m2")) then "m2" else "opt1" end' "$body")
printf '{"answers":{"decision":{"choice":"%s","confidence":0.91}}}' "$c" >"$out"
printf '200'
EOF
chmod +x "$TMP/bin/curl"
KEYF="$TMP/key"; printf 'sk-test\n' >"$KEYF"; chmod 600 "$KEYF"
export FAKE_CURL_BODY="$TMP/curl-body.json"
R8=$(PATH="$TMP/bin:$PATH" FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$KEYF" lmj example.test --logged-out="$OUT" --logged-in="$IN" --url=https://example.test/s)
jq -e '.logged_out.choice == "m2" and .logged_out.confidence == 0.91 and .backend == "openrouter" and .model == "typesafe/jev-1.13"' <<<"$R8" >/dev/null \
  && jq -e '(.questions.decision.instructions | test("sign-in|SIGN-IN"; "i")) and (.questions.decision.criteria | has("m1") and has("none"))
            and (.state.site == "example.test") and (has("instructions") | not)' "$FAKE_CURL_BODY" >/dev/null
check "L8 the built-in call sends this request's instructions and criteria, and the pick comes back" $? "$(cat "$FAKE_CURL_BODY" 2>/dev/null | head -c 400)"
GREQ='{"policy":"gate-answer","version":1,"type":"choice","state":{"task":"DIVE-1","gate":{"options":{"opt1":"Keep"}}},"options":["opt1","approve","other"]}'
PATH="$TMP/bin:$PATH" FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$KEYF" _reflex_openrouter_decide typesafe/jev-1.13 5 <<<"$GREQ" >/dev/null
jq -e '.questions.decision.instructions == "A person was asked to answer a gate on this task. Predict which answer they gave."
       and .questions.decision.criteria == {opt1: "Keep", approve: "Approve.", other: "Some other, free-text answer."}' "$FAKE_CURL_BODY" >/dev/null
check "L8 a gate request still gets the gate instructions and the gate criteria" $? "$(cat "$FAKE_CURL_BODY")"
( unset FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE; FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$TMP/nokey" lm example.test --logged-out="$OUT" --url=https://example.test/s >/dev/null ); rc=$?
(( rc == E_PERMISSION )) && grep -q 'sudo' "$TMP/err"
check "L8 with no readable key the built-in backend refuses and names sudo or fake:first" $?

# ── L9: every shipped marker form is a candidate where it occurs ─────────────
F9="$TMP/shipped-forms.html"
printf '<html><head><title>Log in</title></head><body><form action="/session"><input name="username"><input name="username_or_email"></form></body></html>\n' >"$F9"
R9=$(lmj example.test --logged-out="$F9" --url=https://example.test/s --backend=fake:first)
jq -e '[.logged_out.candidates[].marker] as $c
       | ($c | index("action=[\"'"'"']?/session") != null) and ($c | index("name=[\"'"'"']?username") != null)
         and ($c | index("name=[\"'"'"']?username_or_email") != null)' <<<"$R9" >/dev/null
check "L9 the shipped github/reddit/x marker forms are generated verbatim from a page that carries them" $? "$R9"

# ── L10: a per-render token is never a candidate (DIVE-4929) ────────────────
# Measured on github.com: two renders of the SAME signed-out page, fed as the
# two halves, left four "verified" candidates, all random: honeypot fields
# required_field_<hex> and a UUID id. Each passes the both-halves bar by
# construction and would never match again as a marker.
RND="$TMP/random.html"
cat >"$RND" <<'HTML'
<html><head><title>Sign in</title></head><body><form action="/session">
<input name="required_field_6df7"><input name="required_field_dca6"><input name="csrf_12345">
<button id="icon-button-0d47aed3-e915-4c11-a46e-da351a291fcc">x</button><input name="login"></form></body></html>
HTML
l10_arm() {
  local r; r=$(lmj example.test --logged-out="$RND" --logged-in="$IN" --url=https://example.test/s --backend=fake:first) || return 1
  jq -e '[.logged_out.candidates[].marker] as $c
         | ($c | map(select(test("required_field|0d47aed3|csrf_12345"))) | length) == 0
           and ($c | index("action=[\"'"'"']?/session") != null) and ($c | index("name=[\"'"'"']?login") != null)' <<<"$r" >/dev/null
}
l10_arm; check "L10 random per-render tokens (hex suffixes, a UUID, a digit run) are never candidates; the real ones are" $?

# ── L11: a second signed-out render is a stability check ────────────────────
OUT2="$TMP/out2.html"
sed 's|<a href="/password_reset">Forgot?</a>|<input name="step_alpha">|' "$OUT" >"$TMP/out1b.html"
cp "$OUT" "$OUT2"
R11a=$(lmj example.test --logged-out="$TMP/out1b.html" --logged-in="$IN" --url=https://example.test/s --backend=fake:first)
R11b=$(lmj example.test --logged-out="$TMP/out1b.html" --logged-out="$OUT2" --logged-in="$IN" --url=https://example.test/s --backend=fake:first)
jq -e '[.logged_out.candidates[].marker] | index("name=[\"'"'"']?step_alpha") != null' <<<"$R11a" >/dev/null \
  && jq -e '([.logged_out.candidates[].marker] | index("name=[\"'"'"']?step_alpha") == null) and .signed_out_renders == 2
            and ([.logged_out.candidates[].marker] | index("action=[\"'"'"']?/session") != null)' <<<"$R11b" >/dev/null
check "L11 a token on only one of two signed-out renders is dropped (control: kept with one render)" $?
grep -q 'stability across renders is unmeasured' <<<"$(lm example.test --logged-out="$OUT" --url=https://example.test/s --backend=fake:first)"
check "L11 one signed-out render: the report says stability is unmeasured" $?
printf '<html><head><title>Sign in to Example</title></head><body><div class="g-recaptcha"></div></body></html>\n' >"$TMP/ch3.html"
lm example.test --logged-out="$OUT" --logged-out="$TMP/ch3.html" --url=https://example.test/s --backend=fake:first >/dev/null; rc=$?
check "L11 a challenge page as the SECOND signed-out render is refused too" "$(( rc == E_VALIDATION ? 0 : 1 ))"

# ── M: mutants ───────────────────────────────────────────────────────────────
MUT="$TMP/mut1.sh"
sed 's/\[\[ "\$ci" == null || "\$ci" == 0 \]\] || continue/true/' "$SRC/cmd_reflex_login_marker.sh" >"$MUT"
if cmp -s "$MUT" "$SRC/cmd_reflex_login_marker.sh"; then bad_t "M1 the mutant did not apply"; else
  ( source "$MUT"; l1_arm ); MRC=$?
  check "M1 with the signed-in filter dropped, L1 goes RED" "$(( MRC != 0 ? 0 : 1 ))"
fi
( l1_arm ); check "M1 control: the unmutated source stays green on L1" $?
MUT2="$TMP/mut2.sh"
sed 's/^  if \[\[ "\$challenge" == true \]\]; then$/  if false; then/' \
  "$SRC/cmd_reflex_login_marker.sh" >"$MUT2"
if cmp -s "$MUT2" "$SRC/cmd_reflex_login_marker.sh"; then bad_t "M2 the mutant did not apply"; else
  ( source "$MUT2"; l5_arm ); MRC=$?
  check "M2 with the challenge check dropped, L5 goes RED" "$(( MRC != 0 ? 0 : 1 ))"
fi
( l5_arm ); check "M2 control: the unmutated source stays green on L5" $?
MUT3="$TMP/mut3.sh"
sed 's/^    function randomish(v,   n, i, seg) {$/    function randomish(v,   n, i, seg) { return 0/' "$SRC/cmd_reflex_login_marker.sh" >"$MUT3"
if cmp -s "$MUT3" "$SRC/cmd_reflex_login_marker.sh"; then bad_t "M3 the mutant did not apply"; else
  ( source "$MUT3"; l10_arm ); MRC=$?
  check "M3 with the random-token filter off, L10 goes RED" "$(( MRC != 0 ? 0 : 1 ))"
fi
( l10_arm ); check "M3 control: the unmutated source stays green on L10" $?

echo
echo "passed $pass, failed $fail"
[[ $fail -eq 0 ]]
