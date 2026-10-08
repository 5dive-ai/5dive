#!/usr/bin/env bash
# DIVE-5874 — `5dive agent first-job` / `agent _first_job_run` / `first-job status`:
# the owner's first job at hire, run on the box through `agent ask`, the reply
# left for the agent's Telegram plugin, and the API told it is done.
#
# What is pinned, against stubs on PATH (systemd-run, systemctl, curl) and a fake
# `5dive` binary for the ask (no root, no network, no systemd, no agent):
#   V1-V5   argument validation: usage, token shape, name, unknown agent, job
#           base64 / empty / control chars / size — each refused with NO unit.
#   S1-S3   the start: {"ok":true}, the 0600 record, the systemd-run argv (unit
#           name from the token, the internal verb), url-safe base64, and a
#           refused systemd-run drops the record so the API's retry can start it.
#   I1      idempotency: a second call on the same token prints already:true and
#           starts nothing while its unit is live.
#   I2-I4   a "running" (or "watching") record with no live unit is restarted;
#           done/failed are not; a refused restart keeps the record.
#   R1-R6   the run: the prompt template, the ask argv, first-reply.json (shape,
#           0600, no temp left behind), the done POST (url, body with and without
#           botUsername, bearer on STDIN not argv), the failure body, the ask
#           retry on a not-running agent, the POST retry/back-off and its stop on
#           a 4xx, FIVE_API_BASE.
#   J0-J7   the watcher after done (fake clock, stubbed sleep that plays the
#           plugin): start/second reported once each, then exit; 72h expiry;
#           a restarted unit resumes without resending or re-asking; a 4xx stops
#           that event; a transient failure is retried next tick; a wrong token
#           or garbage stamps report nothing; a failed job does not watch.
#   W1-W3   wiring: the dispatch arms, the usage entry, build.sh loads the module.
#   NC1     NEGATIVE CONTROL: a copy of the module with the noclobber create
#           removed must be CAUGHT by I1's "started nothing" check.
# Run: bash tests/agent_first_job_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/first-job-unit.XXXXXX")"

export STATE_DIR="$TMP/state" AGENT_HOME_ROOT="$TMP/home"
mkdir -p "$STATE_DIR" "$AGENT_HOME_ROOT/agent-ada" "$AGENT_HOME_ROOT/agent-bob" "$TMP/bin"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_partner.sh cmd_agent_first_job.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e
# The harness is not root and must not become it: both seams say "not root" so
# the writes run as the caller even where CI runs this as root.
require_root() { :; }
_first_job_is_root() { return 1; }

pass=0; fail=0
ok_t()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { fail=$((fail+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

TOKEN="AbCdEfGhIjKlMnOpQr_s-1"     # 22 chars, the API's shape
SECRET="tok-SECRET-5874-abcdef"
printf '{"agents":{"ada":{"type":"claude","botUsername":"ada_helper_bot"},"bob":{"type":"claude"}}}\n' >"$STATE_DIR/agents.json"
printf 'CONNECTORD_TOKEN=%s\n' "$SECRET" >"$TMP/connectord.env"
export FIVE_CONNECTORD_ENV="$TMP/connectord.env" STUB_DIR="$TMP"
unset CONNECTORD_TOKEN FIVE_API_BASE

# systemd-run: argv one per line, appended per call; STUB_SDRUN_RC fails it.
cat >"$TMP/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; echo ---; } >>"$STUB_DIR/sdrun.argv"
exit "${STUB_SDRUN_RC:-0}"
EOF
# systemctl: `is-active` answers STUB_ACTIVE_RC (0 = a live unit, the default).
printf '#!/usr/bin/env bash\n[[ "$1" == is-active ]] && exit "${STUB_ACTIVE_RC:-0}"\nexit 0\n' >"$TMP/bin/systemctl"
# curl: argv, stdin, body per call; the status comes from the next line of
# $STUB_DIR/http.seq (default 200).
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$STUB_DIR/curl.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STUB_DIR/curl.n"
printf '%s\n' "$@" >"$STUB_DIR/curl.argv"
cat >"$STUB_DIR/curl.stdin"
prev=""; for a in "$@"; do [[ "$prev" == "--data-binary" ]] && { printf '%s' "$a" >"$STUB_DIR/curl.body"; printf '%s\n' "$a" >>"$STUB_DIR/curl.bodies"; }; prev="$a"; done
code=$(sed -n "${n}p" "$STUB_DIR/http.seq" 2>/dev/null); printf '%s' "${code:-200}"
EOF
# the fake 5dive: only `--json agent ask` is expected. Mode from STUB_ASK:
#   ok       reply "$STUB_REPLY"
#   down1    exit 8 (not running) on the first call, then ok
#   auth     exit 6 with the fail() envelope
cat >"$TMP/bin/five" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$STUB_DIR/ask.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STUB_DIR/ask.n"
printf '%s\n' "$@" >"$STUB_DIR/ask.argv"
for a in "$@"; do [[ "$a" == --message-file=* ]] && cp "${a#--message-file=}" "$STUB_DIR/ask.prompt"; done
case "${STUB_ASK:-ok}" in
  down1) if (( n == 1 )); then printf '{"ok":false,"error":{"code":8,"class":"not_running","message":"tmux session not found"}}\n'; exit 8; fi ;;
  auth)  printf '{"ok":false,"error":{"code":6,"class":"auth_required","message":"agent is not signed in"}}\n'; exit 6 ;;
esac
jq -cn --arg r "${STUB_REPLY:-Here is your plan.}" '{ok:true, data:{name:"ada", reply:$r}}'
EOF
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" FIVE_FIRST_JOB_SELF="$TMP/bin/five"
export FIRST_JOB_POST_BACKOFF="0 0" FIRST_JOB_ASK_RETRY_SLEEP=0
# The watcher: a fake clock that `sleep` advances, and a short default window
# (2 ticks) so every run arm ends. A watcher tick (sleep 60) also plays the
# plugin: at tick STUB_START_TICK it stamps startAt, at STUB_SECOND_TICK
# secondAt. Past 200 ticks it kills the run, so a loop that never ends is a red
# arm, not a hung harness.
export FIRST_JOB_WATCH_SECS=120 FIRST_JOB_WATCH_SLEEP=60 TOKEN
export SF="$AGENT_HOME_ROOT/agent-ada/.claude/channels/telegram/first-reply.state.json"
_first_job_now() { cat "$TMP/clock"; }
cat >"$TMP/bin/sleep" <<'STUB'
#!/usr/bin/env bash
c=$(cat "$STUB_DIR/clock"); echo $(( c + ${1:-0} )) >"$STUB_DIR/clock"
[[ "${1:-}" == 60 ]] || exit 0
n=$(( $(cat "$STUB_DIR/ticks" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STUB_DIR/ticks"
(( n > 200 )) && kill "$PPID"
mkdir -p "$(dirname "$SF")"
if [[ -n "${STUB_GARBAGE:-}" ]]; then printf 'garbage{' >"$SF"; exit 0; fi
t="${STUB_STAMP_TOKEN:-$TOKEN}" s=null d=null
(( ${STUB_START_TICK:-0} > 0 && n >= STUB_START_TICK )) && s='"2026-10-08T10:00:00.000Z"'
(( ${STUB_SECOND_TICK:-0} > 0 && n >= STUB_SECOND_TICK )) && d='"2026-10-08T10:05:00.000Z"'
[[ $s == null && $d == null ]] || printf '{"token":"%s","startAt":%s,"secondAt":%s}' "$t" "$s" "$d" >"$SF"
exit 0
STUB
chmod +x "$TMP/bin/sleep"

b64() { printf '%s' "$1" | base64 -w0; }
reset() { rm -rf "$STATE_DIR/first-jobs" "$TMP"/sdrun.argv "$TMP"/curl.* "$TMP"/ask.* "$TMP/http.seq" "$TMP/ticks" \
          "$AGENT_HOME_ROOT"/agent-*/.claude; echo 1000000 >"$TMP/clock"; }
# run <fn> <args...> in a subshell (fail() exits). Sets OUT, ERR, RC.
run() { local fn="$1"; shift; ( JSON_MODE=0; "$fn" "$@" ) >"$TMP/out" 2>"$TMP/err"; RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err"); }
sd_calls() { grep -c '^---$' "$TMP/sdrun.argv" 2>/dev/null || echo 0; }
REPLY_F="$AGENT_HOME_ROOT/agent-ada/.claude/channels/telegram/first-reply.json"
STATE_F() { printf '%s/first-jobs/%s.json' "$STATE_DIR" "${1:-$TOKEN}"; }

# ── V1: usage ─────────────────────────────────────────────────────────────────
reset; run cmd_agent_first_job ada --token="$TOKEN"
[[ $RC -eq $E_USAGE && "$(sd_calls)" == 0 ]] && ok_t "V1 a missing --job-b64 is E_USAGE and starts nothing" || bad_t "V1 usage" "rc=$RC err=$ERR"
run cmd_agent_first_job ada --token="$TOKEN" --job-b64="$(b64 hi)" --bogus
[[ $RC -eq $E_USAGE ]] && ok_t "V1b an unknown flag is E_USAGE" || bad_t "V1b unknown flag" "rc=$RC"

# ── V2: token shape ──────────────────────────────────────────────────────────
v2=()
for t in short "${TOKEN}x" "AbCdEfGhIjKlMnOpQr.s-1" "../../../etc/passwd...." "AbCdEfGhIjKlMnOpQr s-1"; do
  run cmd_agent_first_job ada --token="$t" --job-b64="$(b64 hi)"
  [[ $RC -eq $E_VALIDATION ]] || v2+=("'$t' rc=$RC")
done
[[ ${#v2[@]} -eq 0 && "$(sd_calls)" == 0 && ! -d "$STATE_DIR/first-jobs" ]] \
  && ok_t "V2 a token that is not 22 chars of [A-Za-z0-9_-] is refused (5 shapes), no record, no unit" \
  || bad_t "V2 token shape" "${v2[*]} sd=$(sd_calls)"

# ── V3/V4: name ──────────────────────────────────────────────────────────────
run cmd_agent_first_job 'Ada;rm' --token="$TOKEN" --job-b64="$(b64 hi)"
[[ $RC -eq $E_VALIDATION ]] && ok_t "V3 an invalid agent name is E_VALIDATION" || bad_t "V3 name" "rc=$RC"
run cmd_agent_first_job carol --token="$TOKEN" --job-b64="$(b64 hi)"
[[ $RC -eq $E_NOT_FOUND && "$(sd_calls)" == 0 ]] && ok_t "V4 an agent not in the registry is E_NOT_FOUND, no unit" || bad_t "V4 unknown agent" "rc=$RC"

# ── V5: the job ──────────────────────────────────────────────────────────────
v5=()
long=$(printf 'x%.0s' {1..1201})
for j64 in 'not base64!' "$(b64 '   ')" "$(printf 'a\nb' | base64 -w0)" "$(printf 'a\033b' | base64 -w0)" "$(b64 "$long")"; do
  run cmd_agent_first_job ada --token="$TOKEN" --job-b64="$j64"
  [[ $RC -eq $E_VALIDATION ]] || v5+=("rc=$RC for ${j64:0:12}")
done
[[ ${#v5[@]} -eq 0 && "$(sd_calls)" == 0 ]] \
  && ok_t "V5 non-base64, blank, newline, ESC and >1200-byte jobs are refused, no unit" \
  || bad_t "V5 job validation" "${v5[*]}"

# ── S1: the start ────────────────────────────────────────────────────────────
reset; run cmd_agent_first_job ada --token="$TOKEN" --job-b64="$(b64 'Plan my week')"
[[ $RC -eq 0 && "$OUT" == '{"ok":true}' ]] && ok_t "S1 prints exactly {\"ok\":true}, rc 0" || bad_t "S1 output" "rc=$RC out=$OUT err=$ERR"
rec=$(cat "$(STATE_F)" 2>/dev/null)
[[ "$(jq -r '[.token,.name,.job,.status]|join("|")' <<<"$rec")" == "$TOKEN|ada|Plan my week|running" ]] \
  && ok_t "S1b the record holds token, name, the decoded job and status running" || bad_t "S1b record" "$rec"
[[ "$(stat -c %a "$(STATE_F)")" == 600 && "$(stat -c %a "$STATE_DIR/first-jobs")" == 700 ]] \
  && ok_t "S1c record 0600 in a 0700 dir" || bad_t "S1c modes" "$(stat -c '%a %n' "$(STATE_F)" "$STATE_DIR/first-jobs")"
mapfile -t A < <(sed '/^---$/,$d' "$TMP/sdrun.argv")
want_tail=("--" "$TMP/bin/five" agent _first_job_run ada "$TOKEN")
tail_ok=1; for i in 0 1 2 3 4 5; do [[ "${A[$(( ${#A[@]} - 6 + i ))]}" == "${want_tail[$i]}" ]] || tail_ok=0; done
argv_lines=$(printf '%s\n' "${A[@]}")
{ grep -qx -- "--unit=5dive-first-job-${TOKEN:0:12}" <<<"$argv_lines" \
  && grep -qx -- --collect <<<"$argv_lines" && grep -qx -- --quiet <<<"$argv_lines" && (( tail_ok )); } \
  && ok_t "S1d systemd-run --unit=5dive-first-job-<12> --collect --quiet -- <5dive> agent _first_job_run ada <token>" \
  || bad_t "S1d systemd-run argv" "${A[*]}"

# ── I1: idempotent ───────────────────────────────────────────────────────────
i1_arm() {  # the second call on the same token
  run cmd_agent_first_job ada --token="$TOKEN" --job-b64="$(b64 'Something else')"
  [[ $RC -eq 0 && "$OUT" == '{"ok":true,"already":true}' && "$(sd_calls)" == 1 ]] \
    && [[ "$(jq -r .job "$(STATE_F)")" == "Plan my week" ]]
}
i1_arm && ok_t "I1 a repeat on the same token prints already:true, starts no second unit, keeps the record" \
       || bad_t "I1 idempotency" "rc=$RC out=$OUT sd=$(sd_calls) job=$(jq -r .job "$(STATE_F)" 2>/dev/null)"

# ── I2-I4: a stale "running" record (no live unit) is restarted ─────────────
STUB_ACTIVE_RC=3 run cmd_agent_first_job ada --token="$TOKEN" --job-b64="$(b64 'Something else')"
{ [[ $RC -eq 0 && "$OUT" == '{"ok":true,"restarted":true}' && "$(sd_calls)" == 2 ]] \
  && [[ "$(jq -r '[.job,.status]|join("|")' "$(STATE_F)")" == "Plan my week|running" && "$(jq -r .restartedAt "$(STATE_F)")" =~ Z$ ]] \
  && [[ "$(sed -n '/^---$/,$p' "$TMP/sdrun.argv" | tail -2 | head -1)" == "$TOKEN" ]]; } \
  && ok_t "I2 running + no live unit: restarted:true, a second unit for the RECORDED job, restartedAt stamped" \
  || bad_t "I2 stale restart" "rc=$RC out=$OUT sd=$(sd_calls) rec=$(cat "$(STATE_F)")"
i3=()
for st in done failed; do
  jq -c --arg s "$st" '.status = $s' "$(STATE_F)" >"$TMP/r" && mv "$TMP/r" "$(STATE_F)"
  before=$(sd_calls)
  STUB_ACTIVE_RC=3 run cmd_agent_first_job ada --token="$TOKEN" --job-b64="$(b64 hi)"
  [[ $RC -eq 0 && "$OUT" == '{"ok":true,"already":true}' && "$(sd_calls)" == "$before" ]] || i3+=("$st: rc=$RC out=$OUT")
done
jq -c '.status = "watching"' "$(STATE_F)" >"$TMP/r" && mv "$TMP/r" "$(STATE_F)"
STUB_ACTIVE_RC=3 run cmd_agent_first_job ada --token="$TOKEN" --job-b64="$(b64 hi)"
[[ $RC -eq 0 && "$OUT" == '{"ok":true,"restarted":true}' ]] && ok_t "I2b a watching record with no live unit is restarted too" || bad_t "I2b watching restart" "rc=$RC out=$OUT"
(( ${#i3[@]} == 0 )) && ok_t "I3 done / failed with no live unit still answer already:true and start nothing" || bad_t "I3 finished states" "${i3[*]}"
jq -c '.status = "running"' "$(STATE_F)" >"$TMP/r" && mv "$TMP/r" "$(STATE_F)"
before=$(sd_calls); STUB_ACTIVE_RC=3 STUB_SDRUN_RC=1 run cmd_agent_first_job ada --token="$TOKEN" --job-b64="$(b64 hi)"
[[ $RC -eq $E_GENERIC && -e "$(STATE_F)" && "$(jq -r .status "$(STATE_F)")" == running ]] \
  && ok_t "I4 a refused restart fails but keeps the record, so the next retry restarts it" || bad_t "I4 refused restart" "rc=$RC out=$OUT"

# ── S2: url-safe, unpadded base64 ────────────────────────────────────────────
reset; j='??> ok'; u=$(b64 "$j" | tr '+/' '-_' | tr -d '=')
run cmd_agent_first_job ada --token="$TOKEN" --job-b64="$u"
[[ $RC -eq 0 && "$(jq -r .job "$(STATE_F)")" == "$j" ]] && ok_t "S2 url-safe unpadded base64 decodes to the same job" || bad_t "S2 base64url" "rc=$RC err=$ERR u=$u"

# ── S3: systemd-run refused → no record, retry works ─────────────────────────
reset; STUB_SDRUN_RC=1 run cmd_agent_first_job ada --token="$TOKEN" --job-b64="$(b64 hi)"
[[ $RC -eq $E_GENERIC && ! -e "$(STATE_F)" ]] && ok_t "S3 a refused systemd-run fails and drops the record" || bad_t "S3 refused unit" "rc=$RC"
run cmd_agent_first_job ada --token="$TOKEN" --job-b64="$(b64 hi)"
[[ $RC -eq 0 && "$OUT" == '{"ok":true}' ]] && ok_t "S3b ... so the API's retry starts it" || bad_t "S3b retry" "rc=$RC out=$OUT"

# ── R1: the run, happy path ──────────────────────────────────────────────────
start_job() { reset; run cmd_agent_first_job "$1" --token="$TOKEN" --job-b64="$(b64 "$2")"; }
start_job ada 'Plan my week'
REPLY_TXT=$'**Your week**\n- Mon: "focus"'
STUB_REPLY="$REPLY_TXT" run cmd_agent_first_job_run ada "$TOKEN"
[[ $RC -eq 0 ]] && ok_t "R1 the run exits 0" || bad_t "R1 rc" "rc=$RC err=$ERR"
want_prompt="Your new owner just hired you and picked your first job: «Plan my week». Do it now and keep it small: one page, one short list or one short plan. If you need something you don't have (a link, a name), make a sensible assumption, say which, and do the job anyway. Your answer is sent to your owner in Telegram as your first message to them, so write it as that message: start with the result, no preamble."
[[ "$(cat "$TMP/ask.prompt")" == "$want_prompt" ]] && ok_t "R1b the prompt is the static template with the job" || bad_t "R1b prompt" "$(cat "$TMP/ask.prompt")"
mapfile -t Q <"$TMP/ask.argv"
[[ "${Q[0]} ${Q[1]} ${Q[2]} ${Q[3]}" == "--json agent ask ada" && " ${Q[*]} " == *" --timeout=1200 "* && " ${Q[*]} " == *" --message-file="* ]] \
  && ok_t "R1c asks through '5dive --json agent ask ada --message-file=… --timeout=1200'" || bad_t "R1c ask argv" "${Q[*]}"
[[ "$(jq -r '[.token,.text]|join("|")' "$REPLY_F")" == "$TOKEN|$REPLY_TXT" && "$(jq -r .at "$REPLY_F")" =~ ^[0-9]{4}-.*Z$ ]] \
  && ok_t "R1d first-reply.json is {token,text,at} with the reply verbatim" || bad_t "R1d reply file" "$(cat "$REPLY_F" 2>/dev/null)"
[[ "$(stat -c %a "$REPLY_F")" == 600 && -z "$(find "$(dirname "$REPLY_F")" -name '.first-reply.*')" ]] \
  && ok_t "R1e ... 0600, and no temp file left behind" || bad_t "R1e reply mode/tmp" "$(ls -la "$(dirname "$REPLY_F")")"
[[ "$(cat "$TMP/curl.body")" == "{\"token\":\"$TOKEN\",\"ok\":true,\"botUsername\":\"ada_helper_bot\"}" ]] \
  && ok_t "R1f done body is {token, ok:true, botUsername} from the registry" || bad_t "R1f body" "$(cat "$TMP/curl.body")"
{ grep -qx 'https://api.5dive.com/server/first-jobs/done' "$TMP/curl.argv" && grep -qx -- '@-' "$TMP/curl.argv" \
  && ! grep -qF "$SECRET" "$TMP/curl.argv" && grep -qx "Authorization: Bearer $SECRET" "$TMP/curl.stdin"; } \
  && ok_t "R1g POSTs <api>/server/first-jobs/done; the box token on STDIN, absent from argv" \
  || bad_t "R1g POST" "argv=$(tr '\n' ' ' <"$TMP/curl.argv") stdin=$(cat "$TMP/curl.stdin")"
[[ "$(jq -r '[.status,(.posted|tostring),.http]|join("|")' "$(STATE_F)")" == "done|true|200" ]] \
  && ok_t "R1h the record ends done, posted, http 200" || bad_t "R1h record" "$(cat "$(STATE_F)")"

# ── R2: no bot username → the key is omitted ─────────────────────────────────
start_job bob 'Hi'; run cmd_agent_first_job_run bob "$TOKEN"
[[ $RC -eq 0 && "$(cat "$TMP/curl.body")" == "{\"token\":\"$TOKEN\",\"ok\":true}" ]] \
  && ok_t "R2 with no botUsername in the registry the body carries none" || bad_t "R2 body" "rc=$RC $(cat "$TMP/curl.body")"

# ── R3: the ask fails → ok:false, no reply file ──────────────────────────────
start_job ada 'Plan my week'; STUB_ASK=auth run cmd_agent_first_job_run ada "$TOKEN"
{ [[ $RC -ne 0 && ! -e "$REPLY_F" && "$(cat "$TMP/ask.n")" == 1 ]] \
  && [[ "$(cat "$TMP/curl.body")" == "{\"token\":\"$TOKEN\",\"ok\":false,\"error\":\"agent is not signed in\"}" ]] \
  && [[ "$(jq -r .status "$(STATE_F)")" == failed ]]; } \
  && ok_t "R3 a failed ask posts {token, ok:false, error}, writes no reply, is not retried, record failed" \
  || bad_t "R3 failure" "rc=$RC asks=$(cat "$TMP/ask.n") body=$(cat "$TMP/curl.body" 2>/dev/null)"

# ── R4: a not-yet-running agent is retried ───────────────────────────────────
start_job ada 'Plan my week'; STUB_ASK=down1 run cmd_agent_first_job_run ada "$TOKEN"
[[ $RC -eq 0 && "$(cat "$TMP/ask.n")" == 2 && -e "$REPLY_F" ]] \
  && ok_t "R4 an agent still booting (exit 8) is asked again, and the reply lands" || bad_t "R4 retry" "rc=$RC asks=$(cat "$TMP/ask.n" 2>/dev/null)"

# ── R5: POST retries on 5xx, stops on 4xx ────────────────────────────────────
start_job ada 'Plan my week'; printf '503\n000\n200\n' >"$TMP/http.seq"; run cmd_agent_first_job_run ada "$TOKEN"
[[ $RC -eq 0 && "$(cat "$TMP/curl.n")" == 3 ]] && ok_t "R5 503, then a transport failure, then 200: three attempts, success" || bad_t "R5 retry" "rc=$RC calls=$(cat "$TMP/curl.n")"
start_job ada 'Plan my week'; printf '503\n503\n503\n200\n' >"$TMP/http.seq"; run cmd_agent_first_job_run ada "$TOKEN"
[[ $RC -ne 0 && "$(cat "$TMP/curl.n")" == 3 && "$(jq -r '.posted' "$(STATE_F)")" == false ]] \
  && ok_t "R5b no more than 3 attempts; the record says posted:false" || bad_t "R5b cap" "rc=$RC calls=$(cat "$TMP/curl.n")"
start_job ada 'Plan my week'; printf '404\n200\n' >"$TMP/http.seq"; run cmd_agent_first_job_run ada "$TOKEN"
[[ $RC -ne 0 && "$(cat "$TMP/curl.n")" == 1 ]] && ok_t "R5c a 404 is an answer: one attempt" || bad_t "R5c 4xx" "rc=$RC calls=$(cat "$TMP/curl.n")"

# ── R6: FIVE_API_BASE ────────────────────────────────────────────────────────
start_job ada 'Plan my week'; FIVE_API_BASE="https://api.example.test/" run cmd_agent_first_job_run ada "$TOKEN"
grep -qx 'https://api.example.test/server/first-jobs/done' "$TMP/curl.argv" \
  && ok_t "R6 FIVE_API_BASE (trailing slash trimmed) picks the API" || bad_t "R6 api base" "$(tr '\n' ' ' <"$TMP/curl.argv")"
reset; run cmd_agent_first_job_run ada "$TOKEN"
[[ $RC -eq $E_NOT_FOUND && ! -e "$TMP/ask.n" ]] && ok_t "R6b a run with no record asks nothing" || bad_t "R6b no record" "rc=$RC"

# ── J: the watcher after done ────────────────────────────────────────────────
ticks() { cat "$TMP/ticks" 2>/dev/null || echo 0; }
ev()    { jq -r --arg e "$1" '.events[$e] | if . == null then "none" else "\(.ok)|\(.http)" end' "$(STATE_F)"; }
start_job ada 'Plan my week'
grep -qx -- '--property=RuntimeMaxSec=262800' "$TMP/sdrun.argv" \
  && ok_t "J0 the unit's hard limit is 73h (the ask, then 72h of watching)" || bad_t "J0 RuntimeMaxSec" "$(tr '\n' ' ' <"$TMP/sdrun.argv")"
STUB_START_TICK=1 STUB_SECOND_TICK=2 FIRST_JOB_WATCH_SECS=259200 run cmd_agent_first_job_run ada "$TOKEN"
want=$(printf '%s\n' "{\"token\":\"$TOKEN\",\"ok\":true,\"botUsername\":\"ada_helper_bot\"}" "{\"token\":\"$TOKEN\",\"event\":\"start\"}" "{\"token\":\"$TOKEN\",\"event\":\"second\"}")
{ [[ $RC -eq 0 && "$(cat "$TMP/curl.bodies")" == "$want" && "$(ticks)" == 2 ]] \
  && grep -qx 'https://api.5dive.com/server/first-jobs/event' "$TMP/curl.argv" && ! grep -qF "$SECRET" "$TMP/curl.argv"; } \
  && ok_t "J1 done, then {token,event:start} and {token,event:second} to /server/first-jobs/event (bearer on stdin), then exit — 2 ticks, not 72h" \
  || bad_t "J1 events" "rc=$RC ticks=$(ticks) bodies=$(cat "$TMP/curl.bodies" 2>/dev/null)"
[[ "$(jq -r '[.status,.watchEnded]|join("|")' "$(STATE_F)")|$(ev start)|$(ev second)" == "done|reported|true|200|true|200" ]] \
  && ok_t "J1b the record: done, watch ended 'reported', both events recorded ok" || bad_t "J1b record" "$(cat "$(STATE_F)")"

start_job ada 'Plan my week'; FIRST_JOB_WATCH_SECS=300 run cmd_agent_first_job_run ada "$TOKEN"
[[ $RC -eq 0 && "$(ticks)" == 5 && "$(cat "$TMP/curl.n")" == 1 && "$(jq -r '[.status,.watchEnded]|join("|")' "$(STATE_F)")" == "done|expired" ]] \
  && ok_t "J2 no stamps: the watch ends at the window (300s / 60s = 5 ticks), nothing reported" \
  || bad_t "J2 expiry" "rc=$RC ticks=$(ticks) curls=$(cat "$TMP/curl.n") $(cat "$(STATE_F)")"

start_job ada 'Plan my week'
jq -c '.status = "watching" | .doneEpoch = 1000000 | .events = {start:{ok:true,http:"200"}}' "$(STATE_F)" >"$TMP/r" && mv "$TMP/r" "$(STATE_F)"
mkdir -p "$(dirname "$SF")"; printf '{"token":"%s","startAt":"2026-10-08T10:00:00Z","secondAt":"2026-10-08T10:05:00Z"}' "$TOKEN" >"$SF"
run cmd_agent_first_job_run ada "$TOKEN"
{ [[ $RC -eq 0 && ! -e "$TMP/ask.n" && "$(cat "$TMP/curl.n")" == 1 ]] \
  && [[ "$(cat "$TMP/curl.bodies")" == "{\"token\":\"$TOKEN\",\"event\":\"second\"}" && "$(jq -r .watchEnded "$(STATE_F)")" == reported ]]; } \
  && ok_t "J3 a restarted watching unit asks nothing, does not resend start, sends second, ends" \
  || bad_t "J3 resume" "rc=$RC asks=$(cat "$TMP/ask.n" 2>/dev/null) bodies=$(cat "$TMP/curl.bodies" 2>/dev/null)"

start_job ada 'Plan my week'; printf '200\n404\n200\n' >"$TMP/http.seq"
STUB_START_TICK=1 STUB_SECOND_TICK=2 FIRST_JOB_WATCH_SECS=259200 run cmd_agent_first_job_run ada "$TOKEN"
[[ $RC -eq 0 && "$(cat "$TMP/curl.n")" == 3 && "$(ev start)" == "false|404" && "$(ev second)" == "true|200" ]] \
  && ok_t "J4 a 404 on start is recorded and not retried; second still goes" \
  || bad_t "J4 4xx" "curls=$(cat "$TMP/curl.n") start=$(ev start) second=$(ev second)"

start_job ada 'Plan my week'; printf '200\n503\n503\n503\n200\n' >"$TMP/http.seq"
STUB_START_TICK=1 FIRST_JOB_WATCH_SECS=180 run cmd_agent_first_job_run ada "$TOKEN"
[[ $RC -eq 0 && "$(cat "$TMP/curl.n")" == 5 && "$(ev start)" == "true|200" && "$(ev second)" == none ]] \
  && ok_t "J5 three 503s leave start unrecorded; the next tick sends it" \
  || bad_t "J5 transient" "curls=$(cat "$TMP/curl.n") start=$(ev start)"

start_job ada 'Plan my week'; STUB_START_TICK=1 STUB_SECOND_TICK=1 STUB_STAMP_TOKEN="ZZZZZZZZZZZZZZZZZZZZZZ" run cmd_agent_first_job_run ada "$TOKEN"
j6a="$(cat "$TMP/curl.n")|$(ev start)"
start_job ada 'Plan my week'; STUB_GARBAGE=1 run cmd_agent_first_job_run ada "$TOKEN"
[[ "$j6a" == "1|none" && "$(cat "$TMP/curl.n")|$(ev start)" == "1|none" ]] \
  && ok_t "J6 stamps for another token, or a garbage state file, report nothing" || bad_t "J6 foreign stamps" "$j6a / $(cat "$TMP/curl.n")|$(ev start)"

start_job ada 'Plan my week'; STUB_ASK=auth run cmd_agent_first_job_run ada "$TOKEN"
[[ $RC -ne 0 && "$(ticks)" == 0 && "$(jq -r .status "$(STATE_F)")" == failed ]] \
  && ok_t "J7 a failed job does not watch" || bad_t "J7 failed job" "rc=$RC ticks=$(ticks)"

# ── W: wiring ────────────────────────────────────────────────────────────────
arm=$(awk '/^_agent_verb_dispatch\(\) \{/{f=1} f&&/^\}/{exit} f' src/main.sh)
{ grep -qE '^        first-job\)' <<<"$arm" && grep -q 'cmd_agent_first_job "\$@"' <<<"$arm" \
  && grep -qE '^        _first_job_run\)' <<<"$arm" && grep -q 'cmd_agent_first_job_run "\$@"' <<<"$arm"; } \
  && ok_t "W1 _agent_verb_dispatch routes first-job and _first_job_run" || bad_t "W1 dispatch arms" ""
grep -q '^  5dive agent first-job <name> --token=' src/main.sh && ok_t "W2 the agent usage documents first-job" || bad_t "W2 usage" ""
lazy_files=$(sed -n '/^LAZY_FILES=(/,/^)/p' build.sh)
grep -qx '  src/cmd_agent_first_job.sh' <<<"$lazy_files" && ok_t "W3 build.sh loads the module" || bad_t "W3 build.sh" ""

# ── NC1: the idempotency check can go red ────────────────────────────────────
sed 's/set -o noclobber; //' src/cmd_agent_first_job.sh >"$TMP/mutant.sh"
if grep -q 'set -o noclobber' "$TMP/mutant.sh"; then bad_t "NC1 mutation did not apply" ""
else
  ( source "$TMP/mutant.sh"; _first_job_is_root() { return 1; }
    reset; run cmd_agent_first_job ada --token="$TOKEN" --job-b64="$(b64 'Plan my week')"
    i1_arm ) && bad_t "NC1 a create without noclobber passes I1 — the check cannot go red" "" \
             || ok_t "NC1 a create without noclobber is CAUGHT by I1 (a second unit started)"
fi

echo "-----"
echo "TESTS pass=$pass fail=$fail"
(( fail == 0 ))
