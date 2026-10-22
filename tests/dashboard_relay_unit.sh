#!/usr/bin/env bash
# DIVE-5894: a standard seat's dashboard chat adapter crosses ONE exact-path,
# self-scoped root rail (_dashboard_relay) for its three control-plane calls,
# because DIVE-5690 closed the box token to the seat.
#   * the standard sudoers template grants it once, with no wildcard, and still
#     classifies cli-scoped with no extra entries (so the installer's
#     `agent _reconcile_sudoers` carries the line to every existing seat); both
#     classifiers and the builtin-verb list know it
#   * the root half derives the seat from SUDO_UID and makes it the agent of
#     every call: pending, ack and event can only speak as the caller
#   * it prints the control plane's status and body, re-reads the token per call
#     (a rotation lands with no reload), and never prints the token
#   * the token NEVER touches curl's argv (/proc is not hidepid on our boxes):
#     the bearer goes in on stdin (-H @-), the body from a root-only file; a
#     control runs the same arm on the first-delivered shape and sees it red
#   * an ack may name only ids this seat's own pending poll was offered (the
#     control plane scopes a DM ack by owner, not by agent)
#   * negative controls: non-root, an argument, uid 0, a non-seat uid, an unknown
#     op, a bad id, an id not offered to this seat, a bad chat id, an empty text, a reply file outside the
#     outbox (or a symlink in it), no token file: none reaches the network
#   * DIVE-6715: status <chat_id> <0|1> [label] and ask <chat_id> <text>
#     <question_id> (<label> <description>){2,10} post jq-built bodies as the
#     caller seat, the bearer on stdin, the text and labels off argv; every
#     malformed wire is refused with its own reason before the network
# Isolation: src/ sourced, the network call is a seam. Run: bash tests/dashboard_relay_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/dashboard-relay.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
  lib/state.sh lib/audit.sh lib/registry.sh lib/actor.sh cmd_agent_create.sh cmd_dashboard_relay.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
P=0; F=0
ok(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL %s\n' "$1" >&2; }

# ── the grant ────────────────────────────────────────────────────────────────
SUD=$(render_standard_sudoers agent-tap 0 0)
[[ $(grep -cE '^agent-tap ALL=\(root\) NOPASSWD: /usr/local/bin/5dive _dashboard_relay$' <<<"$SUD") == 1 ]] \
  && ok 'exact-path dashboard relay grant is rendered once' || bad 'exact-path dashboard relay grant is rendered once'
[[ $(grep -v '^#' <<<"$SUD" | grep '_dashboard_relay') != *'*'* ]] \
  && ok 'relay grant has no wildcard' || bad 'relay grant has no wildcard'
[[ "$(classify_sudo_grant <<<"$SUD")" == 'cli-scoped|root|0' ]] \
  && ok 'rendered standard grant classifies cli-scoped, extra=0' \
  || bad "rendered standard grant classifies cli-scoped, extra=0 (got $(classify_sudo_grant <<<"$SUD"))"
grep -qF 'command == "/usr/local/bin/5dive _dashboard_relay"' "$SRC/cmd_agent.sh" \
  && ok 'python agent-list classifier knows the verb' || bad 'python agent-list classifier knows the verb'
grep -q 'cmd_dashboard_relay "\$@"' <<<"$(grep -A9 '^    _dashboard_relay)' "$SRC/main.sh")" \
  && ok 'main.sh dispatches _dashboard_relay' || bad 'main.sh dispatches _dashboard_relay'
grep -qx '  src/cmd_dashboard_relay.sh' build.sh && ok 'build.sh bundles the verb' || bad 'build.sh bundles the verb'
if command -v visudo >/dev/null 2>&1; then
  printf '%s\n' "$SUD" > "$TMP/sudoers"
  visudo -cf "$TMP/sudoers" >/dev/null 2>&1 && ok 'visudo accepts the template' || bad "visudo: $(visudo -cf "$TMP/sudoers" 2>&1)"
fi

# ── the root half ────────────────────────────────────────────────────────────
export FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env"
export DASHBOARD_OUTBOX="$TMP/outbox"
export FIVE_API_BASE="https://cp.example.test/"
export FIVEDIVE_DASHBOARD_RELAY_DIR="$TMP/seen"
mkdir -p "$TMP/tmpd"; export TMPDIR="$TMP/tmpd"   # so a leaked mktemp file is visible
mkdir -p "$DASHBOARD_OUTBOX" "$TMP/home"
printf 'OTHER=x\nCONNECTORD_TOKEN=tok-one\n' > "$FIVEDIVE_CONNECTORD_ENV"
CALLS="$TMP/calls"; STDINS="$TMP/stdins"; BODY="$TMP/body"
_gate_uid_to_agent(){ case "$1" in 1042) printf 'tap' ;; 1043) printf 'Bad_Name' ;; *) printf '' ;; esac; }
_gate_is_root(){ [[ -z "${NOT_ROOT:-}" ]]; }
# The fake curl, on PATH, so the REAL call line runs (mirrors
# tests/partner_hire_unit.sh): argv one per line, stdin verbatim, the
# --data-binary @file read at call time (the relay deletes it after).
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" prev=""
for a in "$@"; do
  [[ "$prev" == -o ]] && out="$a"
  [[ "$prev" == --data-binary && "$a" == @* ]] && cat -- "${a#@}" >"$STUB_BODY"
  prev="$a"
done
printf '%s\n' "$@" >>"$STUB_CALLS"; printf -- '--\n' >>"$STUB_CALLS"
cat >>"$STUB_STDINS"; printf -- '--\n' >>"$STUB_STDINS"
[[ -n "${CURL_FAILS:-}" ]] && exit 7
printf '%s' "${CURL_BODY:-{\"pending\":[]\}}" >"$out"
printf '%s' "${CURL_CODE:-200}"
STUB
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" STUB_CALLS="$CALLS" STUB_STDINS="$STDINS" STUB_BODY="$BODY"
run_root(){
  local uid="$1"; shift
  : >"$CALLS"; : >"$STDINS"; rm -f "$BODY"
  ( export SUDO_UID="$uid"; printf '%s\0' "$@" | cmd_dashboard_relay ) >"$TMP/out" 2>"$TMP/err"
}
called(){ grep -c '^--$' "$CALLS"; }
# The secrecy arm, as a function so the control below runs the SAME check on
# the shape this rail first shipped (bearer in curl's argv, /proc-readable).
token_on_argv(){ grep -qF "$1" "$CALLS"; }
token_safe(){
  (( $(called) >= 1 )) && ! token_on_argv "$1" && grep -qx -- '@-' "$CALLS" \
    && grep -qx "Authorization: Bearer $1" "$STDINS"
}

run_root 1042 ping; rc=$?
[[ $rc == 0 && "$(head -1 "$TMP/out")" == 200 && "$(called)" == 0 ]] \
  && ok 'ping answers 200 with no network call' || bad "ping (rc=$rc, $(cat "$TMP/out" "$TMP/err"))"
grep -q '"agent":"tap"' "$TMP/out" && ok 'ping names the caller seat' || bad 'ping names the caller seat'

CURL_BODY='{"pending":[{"id":7,"text":"hi"}]}' run_root 1042 pending; rc=$?
[[ $rc == 0 && "$(head -1 "$TMP/out")" == 200 && "$(sed -n 2p "$TMP/out")" == '{"pending":[{"id":7,"text":"hi"}]}' ]] \
  && ok 'pending prints status then the body' || bad "pending output (rc=$rc, $(cat "$TMP/out" "$TMP/err"))"
grep -qx 'https://cp.example.test/server/messages/pending?agent=tap' "$CALLS" \
  && ok 'pending asks for the CALLER seat at the fixed URL' || bad "pending URL ($(cat "$CALLS"))"
token_safe tok-one && ok 'the bearer rides curl STDIN (-H @-), never argv' || bad "bearer placement ($(cat "$CALLS" "$STDINS"))"
grep -q 'tok-one' "$TMP/out" "$TMP/err" && bad 'the token never reaches the caller' || ok 'the token never reaches the caller'

CURL_CODE=401 CURL_BODY=unauthorized run_root 1042 pending; rc=$?
[[ $rc == 0 && "$(head -1 "$TMP/out")" == 401 ]] && ok 'a rejection is passed through as a status' || bad "401 passthrough (rc=$rc)"
CURL_FAILS=1 run_root 1042 pending; rc=$?
[[ $rc != 0 ]] && ok 'a transport failure exits non-zero' || bad 'transport failure exits non-zero'

# a rotation by shelld lands on the next call
printf 'CONNECTORD_TOKEN=tok-two\n' > "$FIVEDIVE_CONNECTORD_ENV"
run_root 1042 pending
token_safe tok-two && ok 'a rotated token is read on the next call, still off argv' || bad 'rotation'

CURL_BODY='{"pending":[{"id":7,"text":"a"},{"id":8,"text":"b"}]}' run_root 1042 pending
[[ "$(stat -c %a "$TMP/seen" 2>/dev/null)" == 700 && "$(stat -c %a "$TMP/seen/tap.ids" 2>/dev/null)" == 600 ]] \
  && ok 'the ids offered to the seat are kept root-only' || bad "seen-ids posture ($(ls -la "$TMP/seen" 2>&1))"
CURL_BODY='{"ok":true,"acked":2}' run_root 1042 ack 7 008; rc=$?
body=$(cat "$BODY" 2>/dev/null)
[[ $rc == 0 && "$body" == '{"agent":"tap","ids":[7,8]}' ]] && ok 'ack posts the caller seat and numeric ids' || bad "ack body (rc=$rc, $body)"
grep -qx 'https://cp.example.test/server/messages/pending/ack' "$CALLS" && ok 'ack hits the fixed URL' || bad 'ack URL'

printf 'x' > "$DASHBOARD_OUTBOX/tap-1-report.txt"
run_root 1042 event dashboard 'hello "owner"' "$DASHBOARD_OUTBOX/tap-1-report.txt"; rc=$?
body=$(cat "$BODY" 2>/dev/null)
want=$(jq -nc --arg f "$(realpath "$DASHBOARD_OUTBOX/tap-1-report.txt")" '{agent:"tap",body:"hello \"owner\"",metadata:{chat_id:"dashboard",files:[$f]}}')
[[ $rc == 0 && "$body" == "$want" ]] && ok 'event builds the reply as the caller seat, with the outbox file' || bad "event body (rc=$rc, $body)"
run_root 1042 event dashboard 'no files'; body=$(cat "$BODY" 2>/dev/null)
[[ "$body" == '{"agent":"tap","body":"no files","metadata":{"chat_id":"dashboard"}}' ]] && ok 'event without files has no files key' || bad "event no files ($body)"
grep -qx 'https://cp.example.test/server/messages/event' "$CALLS" && ok 'event hits the fixed URL' || bad 'event URL'
grep -qF 'no files' "$CALLS" && bad 'the reply text stays off argv' || ok 'the reply text stays off argv (body from a root-only file)'
token_safe tok-two && ok 'event: bearer on stdin, not argv' || bad 'event bearer placement'
ls "$TMP/tmpd"/tmp.* >/dev/null 2>&1 && bad 'no temp file is left behind' || ok 'no temp file is left behind'

# ── DIVE-6715: status and ask ────────────────────────────────────────────────
run_root 1042 status dashboard 1 'Running the tests'; rc=$?
body=$(cat "$BODY" 2>/dev/null)
[[ $rc == 0 && "$body" == '{"agent":"tap","chat_id":"dashboard","active":true,"label":"Running the tests"}' ]] \
  && ok 'status posts the caller seat, a JSON boolean and the label' || bad "status body (rc=$rc, $body, $(cat "$TMP/err"))"
grep -qx 'https://cp.example.test/server/messages/status' "$CALLS" && ok 'status hits the fixed URL' || bad "status URL ($(cat "$CALLS"))"
token_safe tok-two && ok 'status: bearer on stdin, not argv' || bad 'status bearer placement'
(( $(called) == 1 )) && ! grep -qF 'Running the tests' "$CALLS" && ok 'status: the label stays off argv' || bad 'status: the label stays off argv'
[[ "$(head -1 "$TMP/out")" == 200 ]] && ok 'status prints the control plane status' || bad "status output ($(cat "$TMP/out"))"
run_root 1042 status dashboard 0; rc=$?; body=$(cat "$BODY" 2>/dev/null)
[[ $rc == 0 && "$body" == '{"agent":"tap","chat_id":"dashboard","active":false,"label":null}' ]] \
  && ok 'status 0 with no label sends active false, label null' || bad "status off body (rc=$rc, $body)"
run_root 1042 status dashboard 1 ''; rc=$?; body=$(cat "$BODY" 2>/dev/null)
[[ $rc == 0 && "$body" == '{"agent":"tap","chat_id":"dashboard","active":true,"label":null}' ]] \
  && ok 'status with an empty label sends label null' || bad "status empty label body (rc=$rc, $body)"
run_root 1042 status dashboard 1 '","agent":"other'; rc=$?; body=$(cat "$BODY" 2>/dev/null)
[[ $rc == 0 && "$(jq -r .agent <<<"$body")" == tap && "$(jq -r .label <<<"$body")" == '","agent":"other' ]] \
  && ok 'status: a label cannot inject another agent (jq-built)' || bad "status injection (rc=$rc, $body)"
L120=$(printf 'L%.0s' {1..120})
run_root 1042 status dashboard 1 "$L120"; rc=$?
[[ $rc == 0 && "$(jq -r .label "$BODY" 2>/dev/null)" == "$L120" ]] && ok 'status accepts a 120-character label' || bad "status 120 label (rc=$rc)"

run_root 1042 ask dashboard 'Ship "it"?' q-1.a 'Yes' 'Merge now' 'No' ''; rc=$?
body=$(cat "$BODY" 2>/dev/null)
want='{"agent":"tap","body":"Ship \"it\"?","metadata":{"chat_id":"dashboard","question":{"id":"q-1.a","options":[{"label":"Yes","description":"Merge now"},{"label":"No"}]}}}'
[[ $rc == 0 && "$body" == "$want" ]] \
  && ok 'ask posts the question as the caller seat, an empty description left out' || bad "ask body (rc=$rc, $body, $(cat "$TMP/err"))"
grep -qx 'https://cp.example.test/server/messages/event' "$CALLS" && ok 'ask hits the fixed event URL' || bad "ask URL ($(cat "$CALLS"))"
token_safe tok-two && ok 'ask: bearer on stdin, not argv' || bad 'ask bearer placement'
(( $(called) == 1 )) && ! grep -qF -e 'Ship' -e 'Merge now' "$CALLS" && ok 'ask: the text and options stay off argv' || bad 'ask: the text and options stay off argv'
[[ "$(head -1 "$TMP/out")" == 200 ]] && ok 'ask prints the control plane status' || bad "ask output ($(cat "$TMP/out"))"
D200=$(printf 'D%.0s' {1..200}); Q64=$(printf 'q%.0s' {1..64})
opts=(); for i in 1 2 3 4 5 6 7 8 9; do opts+=("opt$i" "desc$i"); done; opts+=("$L120" "$D200")
run_root 1042 ask dashboard 'Pick one' "$Q64" "${opts[@]}"; rc=$?
[[ $rc == 0 && "$(jq -r '.metadata.question.options | length' "$BODY" 2>/dev/null)" == 10 \
   && "$(jq -r '.metadata.question.options[9].description' "$BODY" 2>/dev/null)" == "$D200" \
   && "$(jq -r '.metadata.question.id' "$BODY" 2>/dev/null)" == "$Q64" ]] \
  && ok 'ask accepts 10 options, a 120/200-character option and a 64-character id' || bad "ask boundaries (rc=$rc, $(cat "$TMP/err"))"
run_root 1042 ask dashboard 'Pick' q1 'A","agent":"other' '' 'B' ''; rc=$?; body=$(cat "$BODY" 2>/dev/null)
[[ $rc == 0 && "$(jq -r .agent <<<"$body")" == tap && "$(jq -r '.metadata.question.options[0].label' <<<"$body")" == 'A","agent":"other' ]] \
  && ok 'ask: an option cannot inject another agent (jq-built)' || bad "ask injection (rc=$rc, $body)"
[[ -s "$BODY" ]] && ! ls "$TMP/tmpd"/tmp.* >/dev/null 2>&1 && ok 'status/ask leave no temp file behind' || bad 'status/ask leave no temp file behind'

# ── control: the SAME arm reds on the shape first delivered (eebe2ee8 line 59) ──
MUT="$TMP/mutant.sh"
sed -e 's|-X "$method" -H @-)|-X "$method" -H "Authorization: Bearer ${tok}")|' \
    -e "s|code=\$(printf 'Authorization: Bearer %s\\\\n' \"\$tok\" \| curl |code=\$(curl |" \
    "$SRC/cmd_dashboard_relay.sh" >"$MUT"
if ! cmp -s "$MUT" "$SRC/cmd_dashboard_relay.sh" && grep -qF -- '-H "Authorization: Bearer ${tok}")' "$MUT" \
   && ! grep -qF '| curl' "$MUT"; then
  : >"$CALLS"; : >"$STDINS"
  ( source "$MUT"; export SUDO_UID=1042; printf '%s\0' pending | cmd_dashboard_relay ) >/dev/null 2>&1
  token_on_argv tok-two && ! token_safe tok-two \
    && ok 'control: the arm catches a bearer on argv (old line 59)' \
    || bad "control: the arm did not catch the old shape ($(cat "$CALLS"))"
else
  bad 'control: could not build the old-shape mutant'
fi

# negative controls: nothing reaches the network
neg(){ local label="$1"; shift; "$@"; local r=$?
  [[ $r != 0 && "$(called)" == 0 ]] && ok "refused: $label" || bad "refused: $label (rc=$r, $(cat "$CALLS"))"; }
: >"$CALLS"; ( NOT_ROOT=1; export SUDO_UID=1042; printf '%s\0' pending | cmd_dashboard_relay ) >/dev/null 2>&1; r=$?
[[ $r != 0 && "$(called)" == 0 ]] && ok 'refused: a non-root caller' || bad 'refused: a non-root caller'
: >"$CALLS"; ( export SUDO_UID=1042; printf '%s\0' pending | cmd_dashboard_relay other ) >/dev/null 2>&1; r=$?
[[ $r != 0 && "$(called)" == 0 ]] && ok 'refused: an argv argument' || bad 'refused: an argv argument'
neg 'uid 0'               run_root 0 pending
neg 'no SUDO_UID'         run_root '' pending
neg 'a non-seat uid'      run_root 2000 pending
neg 'a seat name off the agent-name shape' run_root 1043 pending
neg 'an unknown op'       run_root 1042 messages
neg 'pending with an arg' run_root 1042 pending other
neg 'ack with no ids'     run_root 1042 ack
neg 'ack with a non-number' run_root 1042 ack 7 'x'
neg 'ack of an id never offered to this seat' run_root 1042 ack 7 9
cp "$TMP/seen/tap.ids" "$TMP/seen/other.ids"; rm -f "$TMP/seen/tap.ids"
neg 'ack of an id offered to ANOTHER seat' run_root 1042 ack 7
neg 'event with a bad chat id' run_root 1042 event '../x' hi
neg 'event with empty text' run_root 1042 event dashboard '   '
neg 'event with a file outside the outbox' run_root 1042 event dashboard hi "$FIVEDIVE_CONNECTORD_ENV"
neg 'event with a traversal path' run_root 1042 event dashboard hi "$DASHBOARD_OUTBOX/../connectord.env"
ln -s "$FIVEDIVE_CONNECTORD_ENV" "$DASHBOARD_OUTBOX/tap-2-link.txt"
neg 'event with a symlink in the outbox' run_root 1042 event dashboard hi "$DASHBOARD_OUTBOX/tap-2-link.txt"
mkdir -p "$DASHBOARD_OUTBOX/sub"; printf 'x' > "$DASHBOARD_OUTBOX/sub/f"
neg 'event with a file below the outbox' run_root 1042 event dashboard hi "$DASHBOARD_OUTBOX/sub/f"
# DIVE-6715 refusals: each names ITS reason, so an op that does not exist (the
# catch-all refusal) cannot pass them.
negm(){ local label="$1" want="$2"; shift 2; "$@"; local r=$?
  [[ $r != 0 && "$(called)" == 0 ]] && grep -qF -- "$want" "$TMP/err" \
    && ok "refused: $label" || bad "refused: $label (rc=$r, $(cat "$CALLS" "$TMP/err"))"; }
negm 'status with no flag'           'status takes a chat id' run_root 1042 status dashboard
negm 'status with 5 wire args'       'status takes a chat id' run_root 1042 status dashboard 1 lbl extra
negm 'status with a bad chat id'     'status: invalid chat id' run_root 1042 status '../x' 1
negm 'status with flag 2'            'status: the flag is 0 or 1' run_root 1042 status dashboard 2
negm 'status with flag true'         'status: the flag is 0 or 1' run_root 1042 status dashboard true
negm 'status with a 121-char label'  'status: the label is over 120' run_root 1042 status dashboard 1 "${L120}x"
negm 'status with a newline label'   'status: the label has a control' run_root 1042 status dashboard 1 $'two\nlines'
negm 'status with a tab label'       'status: the label has a control' run_root 1042 status dashboard 1 $'a\tb'
negm 'ask with one option'           'ask takes a chat id' run_root 1042 ask dashboard hi q1 A ''
negm 'ask with 11 options'           'ask takes a chat id' run_root 1042 ask dashboard hi q1 "${opts[@]}" K ''
negm 'ask with a label and no description slot' 'ask takes a chat id' run_root 1042 ask dashboard hi q1 A '' B
negm 'ask with no question id'       'ask takes a chat id' run_root 1042 ask dashboard hi
negm 'ask with a bad chat id'        'ask: invalid chat id' run_root 1042 ask '../x' hi q1 A '' B ''
negm 'ask with empty text'           'ask: the text is empty' run_root 1042 ask dashboard '  ' q1 A '' B ''
negm 'ask with text over 64 KiB'     'ask: the text is over 64 KiB' run_root 1042 ask dashboard "$(printf 'x%.0s' {1..65537})" q1 A '' B ''
negm 'ask with a question id starting with a dash' 'ask: invalid question id' run_root 1042 ask dashboard hi -q1 A '' B ''
negm 'ask with a question id with a slash' 'ask: invalid question id' run_root 1042 ask dashboard hi q/1 A '' B ''
negm 'ask with a 65-char question id' 'ask: invalid question id' run_root 1042 ask dashboard hi "${Q64}q" A '' B ''
negm 'ask with an empty label'       'ask: an option label is empty' run_root 1042 ask dashboard hi q1 A '' ' ' ''
negm 'ask with a 121-char label'     'ask: an option label is over 120' run_root 1042 ask dashboard hi q1 A '' "${L120}x" ''
negm 'ask with a 201-char description' 'ask: an option description is over 200' run_root 1042 ask dashboard hi q1 A "${D200}x" B ''
rm -f "$FIVEDIVE_CONNECTORD_ENV"
neg 'no token file'       run_root 1042 pending

printf '\n%d passed, %d failed\n' "$P" "$F"
(( F == 0 ))
