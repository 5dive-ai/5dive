#!/usr/bin/env bash
# DIVE-5168 — `5dive partner hire <pack> [--as=<name>]`: a partner client's agent
# hires a colleague THROUGH THE PARTNER PATH (5dive-api POST /server/partner/agents,
# authenticated with the box's CONNECTORD_TOKEN), not with root-only `5dive hire`.
#
# What is pinned, against a fake curl on PATH that records its argv, its stdin and
# the request body (no network, no root, no box):
#   H1-H4   202: the request (url, body, default name, --as both spellings, the
#           pack case-folded), the token in a header ON STDIN and NOT in argv, the
#           human line, FIVE_API_BASE honoured.
#   H5-H6   an invalid pack / name is refused locally with NO curl call.
#   H7-H13  each API refusal maps to its own message and exit code.
#   H14-H15 no box identity (unreadable / absent) refuses with NO curl call.
#   H16-H17 the --json envelopes, including error.reason (the API's code).
#   H18     transport failure.
#   W1-W3   the wiring: main.sh's arm reaches cmd_partner with no require_root and
#           no registry lock, the module never sudos, build.sh loads it.
#   NC1     NEGATIVE CONTROL, in-harness: a copy of the module mutated to pass the
#           bearer on argv (the shape the older box->API callers use) must be
#           CAUGHT by H1's argv check — proving that check can go red at all.
# Run: bash tests/partner_hire_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/partner-hire-unit.XXXXXX")"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh cmd_partner.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e

pass=0; fail=0
ok_t()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { fail=$((fail+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

SECRET="tok-SECRET-5168-abcdef"
mkdir -p "$TMP/bin"
printf 'ADMIN_PUBKEY_B64=\nCONNECTORD_TOKEN=%s\nAUTOMATION_TOKEN=\n' "$SECRET" >"$TMP/connectord.env"
chmod 640 "$TMP/connectord.env"

# The fake curl: argv one per line, stdin verbatim, the --data-binary payload, and
# an answer shaped like `-w '\n%{http_code}'` from STUB_HTTP / STUB_BODY / STUB_RC.
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_DIR/curl.argv"
cat >"$STUB_DIR/curl.stdin"
prev=""
for a in "$@"; do
  [[ "$prev" == "--data-binary" ]] && printf '%s' "$a" >"$STUB_DIR/curl.body"
  prev="$a"
done
if [[ "${STUB_RC:-0}" != 0 ]]; then printf '\n000'; exit "$STUB_RC"; fi
printf '%s\n%s' "${STUB_BODY:-}" "${STUB_HTTP:-202}"
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" STUB_DIR="$TMP"
export FIVE_CONNECTORD_ENV="$TMP/connectord.env"
unset CONNECTORD_TOKEN FIVE_API_BASE

# run <json 0|1> <args...> — one hire in a subshell (fail() exits). Sets OUT, ERR, RC.
run() {
  local j="$1"; shift
  rm -f "$TMP/curl.argv" "$TMP/curl.stdin" "$TMP/curl.body"
  # shellcheck disable=SC2034  # JSON_MODE is read by fail()/ok() inside cmd_partner
  ( JSON_MODE="$j"; cmd_partner "$@" ) >"$TMP/out" 2>"$TMP/err"; RC=$?
  OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err")
}
curl_called() { [[ -f "$TMP/curl.argv" ]]; }
# The argv check, as a function so NC1 can run the SAME assertion on a mutant.
token_on_argv() { grep -qF "$SECRET" "$TMP/curl.argv"; }
h1_arm() {
  STUB_HTTP=202 STUB_BODY='{"name":"galina","pack":"galina","status":"installing"}' run 0 hire galina
  curl_called && ! token_on_argv \
    && grep -qx -- '@-' "$TMP/curl.argv" \
    && grep -qx "Authorization: Bearer $SECRET" "$TMP/curl.stdin"
}

# ── H1: happy path — request shape, token on stdin and NOT on argv ────────────
if h1_arm; then ok_t "H1 202: the bearer reaches curl on STDIN (-H @-) and is absent from its argv"
else bad_t "H1 202: the bearer reaches curl on STDIN (-H @-) and is absent from its argv" \
  "argv=$(tr '\n' ' ' <"$TMP/curl.argv" 2>/dev/null) stdin=$(cat "$TMP/curl.stdin" 2>/dev/null)"; fi
[[ "$(cat "$TMP/curl.body")" == '{"pack":"galina"}' ]] \
  && ok_t "H1b default name: the body is exactly {pack} — the API picks the name" \
  || bad_t "H1b default name: the body is exactly {pack}" "body=$(cat "$TMP/curl.body")"
grep -qx 'https://api.5dive.com/server/partner/agents' "$TMP/curl.argv" \
  && ok_t "H1c POSTs to <api>/server/partner/agents (production default)" \
  || bad_t "H1c POSTs to <api>/server/partner/agents" "argv=$(tr '\n' ' ' <"$TMP/curl.argv")"
[[ $RC -eq 0 && "$OUT" == "OK — Hiring galina (galina) — they will appear in a minute." ]] \
  && ok_t "H1d 202 prints the hiring line, rc 0" \
  || bad_t "H1d 202 prints the hiring line, rc 0" "rc=$RC out=$OUT err=$ERR"

# ── H2: --as, both spellings ──────────────────────────────────────────────────
STUB_BODY='{"name":"gala","pack":"galina","status":"installing"}' run 0 hire galina --as=gala
[[ $RC -eq 0 && "$(cat "$TMP/curl.body")" == '{"pack":"galina","name":"gala"}' && "$OUT" == *"Hiring gala (galina)"* ]] \
  && ok_t "H2 --as=gala sends {pack,name} and names gala in the line" \
  || bad_t "H2 --as=gala sends {pack,name}" "rc=$RC body=$(cat "$TMP/curl.body" 2>/dev/null) out=$OUT"
STUB_BODY='{"name":"gala","pack":"galina","status":"installing"}' run 0 hire --as gala galina
[[ $RC -eq 0 && "$(cat "$TMP/curl.body")" == '{"pack":"galina","name":"gala"}' ]] \
  && ok_t "H2b '--as gala' (separate word, before the pack) is the same request" \
  || bad_t "H2b '--as gala' is the same request" "rc=$RC body=$(cat "$TMP/curl.body" 2>/dev/null)"

# ── H3: what a person types is case-folded ────────────────────────────────────
STUB_BODY='{"name":"galina","pack":"galina","status":"installing"}' run 0 hire Galina
[[ $RC -eq 0 && "$(cat "$TMP/curl.body")" == '{"pack":"galina"}' ]] \
  && ok_t "H3 'Galina' is sent as pack galina" \
  || bad_t "H3 'Galina' is sent as pack galina" "rc=$RC body=$(cat "$TMP/curl.body" 2>/dev/null)"

# ── H4: FIVE_API_BASE is the same knob every box->API caller reads ────────────
FIVE_API_BASE="https://api.example.test/" STUB_BODY='{"name":"galina","pack":"galina","status":"installing"}' run 0 hire galina
grep -qx 'https://api.example.test/server/partner/agents' "$TMP/curl.argv" \
  && ok_t "H4 FIVE_API_BASE (trailing slash trimmed) picks the API" \
  || bad_t "H4 FIVE_API_BASE picks the API" "argv=$(tr '\n' ' ' <"$TMP/curl.argv" 2>/dev/null)"

# ── H5/H6: local validation, and nothing leaves the box ───────────────────────
for bad in '../etc' 'gal ina' '-x' "$(printf 'a%.0s' {1..65})" 'galina;rm'; do
  run 0 hire -- "$bad"
  if [[ $RC -eq $E_VALIDATION && "$ERR" == *"invalid pack"* ]] && ! curl_called; then
    ok_t "H5 invalid pack '${bad:0:20}' refused rc 3, no curl call"
  else bad_t "H5 invalid pack '${bad:0:20}' refused rc 3, no curl call" "rc=$RC err=$ERR curl=$(curl_called && echo yes || echo no)"; fi
done
for bad in 'Gala' 'g' '1gala' 'gala_x' 'abcdefghijklmnopq'; do
  run 0 hire galina --as="$bad"
  if [[ $RC -eq $E_VALIDATION && "$ERR" == *"invalid name"* ]] && ! curl_called; then
    ok_t "H6 invalid --as '$bad' refused rc 3, no curl call"
  else bad_t "H6 invalid --as '$bad' refused rc 3, no curl call" "rc=$RC err=$ERR curl=$(curl_called && echo yes || echo no)"; fi
done
run 0 hire
[[ $RC -eq $E_USAGE ]] && ! curl_called && ok_t "H6b no pack is a usage error, no curl call" \
  || bad_t "H6b no pack is a usage error, no curl call" "rc=$RC err=$ERR"

# ── H7-H13: each API answer has its own line and exit code ────────────────────
# expect <label> <http> <body> <rc> <substring> [args...]
expect() {
  local label="$1" http="$2" body="$3" want_rc="$4" want="$5"; shift 5
  STUB_HTTP="$http" STUB_BODY="$body" run 0 hire "${@:-galina}"
  if [[ $RC -eq $want_rc && "$ERR" == *"$want"* ]]; then ok_t "$label"
  else bad_t "$label" "rc=$RC (want $want_rc) err=$ERR"; fi
}
expect "H7 400 not_in_catalog -> '<pack> is not in this partner's catalogue', rc 4" \
  400 '{"error":"pack not in catalog","code":"not_in_catalog"}' "$E_NOT_FOUND" "zeus is not in this partner's catalogue" zeus
expect "H8 403 not_a_partner_box -> 'use \`5dive hire\`', rc 10" \
  403 '{"error":"not a partner box","code":"not_a_partner_box"}' "$E_PERMISSION" 'this box is not a partner box — use `5dive hire`'
expect "H9 409 agent_exists -> name taken, pick another with --as, rc 5" \
  409 '{"error":"exists","code":"agent_exists"}' "$E_CONFLICT" "(gala) is already taken on this box — pick another with --as=<name>" galina --as=gala
expect "H10 409 box_not_ready -> try again in a few minutes, rc 5" \
  409 '{"error":"not ready","code":"box_not_ready"}' "$E_CONFLICT" "not ready to take a new agent yet"
expect "H11 502 box_unreachable -> rc 8, nothing hired" \
  502 '{"code":"box_unreachable"}' "$E_NOT_RUNNING" "could not reach this box to install galina — nothing was hired"
expect "H12 503 catalog_unavailable -> catalogue unavailable, rc 1" \
  503 '{"code":"catalog_unavailable"}' "$E_GENERIC" "catalogue is unavailable right now"
expect "H13 401 -> box identity refused, rc 6" \
  401 '{"error":"unauthorized"}' "$E_AUTH_REQUIRED" "did not accept this box's identity"
expect "H13b 400 invalid_name from the API is a validation refusal, rc 3" \
  400 '{"error":"name reserved","code":"invalid_name"}' "$E_VALIDATION" "the API refused the name 'root1': name reserved" galina --as=root1

# ── H14/H15: no box identity -> clear refusal, no curl ────────────────────────
if [[ $EUID -eq 0 ]]; then
  printf 'skip - H14 unreadable token file: root reads a mode-000 file, so this arm cannot be staged as root\n'
else
  cp "$TMP/connectord.env" "$TMP/locked.env"; chmod 000 "$TMP/locked.env"
  FIVE_CONNECTORD_ENV="$TMP/locked.env" run 0 hire galina
  if [[ $RC -eq $E_PERMISSION && "$ERR" == *"this seat cannot reach the box's identity"* \
        && "$ERR" == *"hiring from chat needs a non-sandboxed seat on a partner box"* ]] && ! curl_called; then
    ok_t "H14 unreadable connectord.env -> 'cannot reach the box's identity', rc 10, no curl call"
  else bad_t "H14 unreadable connectord.env -> clear refusal, no curl call" "rc=$RC err=$ERR"; fi
fi
FIVE_CONNECTORD_ENV="$TMP/absent.env" run 0 hire galina
if [[ $RC -eq $E_NOT_FOUND && "$ERR" == *"this seat cannot reach the box's identity"* ]] && ! curl_called; then
  ok_t "H15 absent connectord.env -> same refusal, rc 4, no curl call"
else bad_t "H15 absent connectord.env -> same refusal, no curl call" "rc=$RC err=$ERR"; fi
printf 'ADMIN_PUBKEY_B64=\n' >"$TMP/notoken.env"
FIVE_CONNECTORD_ENV="$TMP/notoken.env" run 0 hire galina
if [[ $RC -eq $E_NOT_FOUND ]] && ! curl_called; then ok_t "H15b a file with no CONNECTORD_TOKEN line refuses, no curl call"
else bad_t "H15b a file with no CONNECTORD_TOKEN line refuses, no curl call" "rc=$RC err=$ERR"; fi

# ── H16/H17: --json envelopes ─────────────────────────────────────────────────
STUB_HTTP=202 STUB_BODY='{"name":"galina","pack":"galina","status":"installing"}' run 1 hire galina
[[ $RC -eq 0 ]] && jq -e '.ok == true and .data == {name:"galina",pack:"galina",status:"installing"}' <<<"$OUT" >/dev/null \
  && ok_t "H16 --json 202 -> {ok:true,data:{name,pack,status}}" \
  || bad_t "H16 --json 202 envelope" "rc=$RC out=$OUT"
STUB_HTTP=400 STUB_BODY='{"error":"x","code":"not_in_catalog"}' run 1 hire zeus
[[ $RC -eq $E_NOT_FOUND ]] && jq -e '.ok == false and .error.code == 4 and .error.class == "not_found"
      and .error.reason == "not_in_catalog" and .error.http == 400
      and (.error.message | contains("not in this partner'"'"'s catalogue"))' <<<"$OUT" >/dev/null \
  && ok_t "H17 --json 400 -> {ok:false,error:{code:4,class,message,reason:not_in_catalog,http:400}}" \
  || bad_t "H17 --json 400 envelope" "rc=$RC out=$OUT"
run 1 hire 'Bad Pack'
[[ $RC -eq $E_VALIDATION ]] && jq -e '.ok == false and .error.reason == "invalid_pack" and (.error | has("http") | not)' <<<"$OUT" >/dev/null \
  && ok_t "H17b --json local refusal carries reason and no http" \
  || bad_t "H17b --json local refusal envelope" "rc=$RC out=$OUT"

# ── H18: the API never answered ───────────────────────────────────────────────
STUB_RC=7 run 0 hire galina
[[ $RC -eq $E_GENERIC && "$ERR" == *"could not reach the 5dive API"* && "$ERR" == *"nothing was hired"* ]] \
  && ok_t "H18 transport failure -> 'could not reach the 5dive API', rc 1" \
  || bad_t "H18 transport failure" "rc=$RC err=$ERR"
STUB_RC=28 run 0 hire galina
[[ $RC -eq $E_TIMEOUT ]] && ok_t "H18b curl timeout -> rc 11" || bad_t "H18b curl timeout -> rc 11" "rc=$RC err=$ERR"

# ── W1-W3: wiring ─────────────────────────────────────────────────────────────
# Comment lines dropped: the arm's own comment NAMES require_root to say it is absent.
arm=$(awk '/^    partner\)$/{on=1} on && !/^[[:space:]]*#/{print} on && /;;[[:space:]]*$/ && !/^        /{exit}' src/main.sh)
if [[ "$arm" == *'cmd_partner "$@"'* && "$arm" != *require_root* && "$arm" != *with_registry_lock* && "$arm" != *EUID* ]]; then
  ok_t "W1 main.sh 'partner)' reaches cmd_partner with no root gate and no registry lock"
else bad_t "W1 main.sh 'partner)' arm" "arm=$arm"; fi
if ! grep -nE '(^|[^_])(require_root|sudo )|EUID' src/cmd_partner.sh >/dev/null; then
  ok_t "W2 cmd_partner.sh never requires root and never sudos"
else bad_t "W2 cmd_partner.sh never requires root and never sudos" "$(grep -nE '(^|[^_])(require_root|sudo )|EUID' src/cmd_partner.sh)"; fi
grep -qx '  src/cmd_partner.sh' build.sh \
  && ok_t "W3 build.sh bundles src/cmd_partner.sh" || bad_t "W3 build.sh bundles src/cmd_partner.sh"

# ── NC1: negative control — the argv check can go red ─────────────────────────
MUT="$TMP/cmd_partner.mut.sh"
sed 's#-X POST "$url" -H @- \\#-X POST "$url" -H "Authorization: Bearer ${token}" \\#' src/cmd_partner.sh >"$MUT"
if cmp -s "$MUT" src/cmd_partner.sh; then
  bad_t "NC1 mutation applied (bearer moved onto argv)" "the sed matched nothing: the curl line moved, so NC1 graded nothing"
else
  # shellcheck source=/dev/null
  ( source "$MUT"; h1_arm ); nrc=$?
  (( nrc != 0 )) && token_on_argv \
    && ok_t "NC1 with the bearer on argv, H1 goes RED (the argv check is live)" \
    || bad_t "NC1 with the bearer on argv, H1 goes RED" "h1 rc=$nrc argv=$(tr '\n' ' ' <"$TMP/curl.argv" 2>/dev/null)"
fi
h1_arm && ok_t "NC1 control: the unmutated module stays green on H1" \
  || bad_t "NC1 control: the unmutated module stays green on H1"

echo
echo "TESTS pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
