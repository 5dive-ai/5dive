#!/usr/bin/env bash
# DIVE-9254 — the onboarder visitor door: a firm is FILES until its link opens,
# then it adopts a warm seat; 2 h quiet removes the seat. Contract pinned here
# (9254-work/contract.md, "Box CLI verbs" and "Client CLI"):
#   V* the brief now also takes field, size, country and insight; emails still refused
#   C* box create stores brief + instructions, makes no seat; cron runs `box tick`
#   W* box wake adopts a warm seat, writes a root-owned CLAUDE.md with the firm's
#      instructions + "## The chat so far"; an empty pool makes a locked seat
#   T* box tick removes a seat quiet 2 h, starts one with a queued message, refills
#      the warm pool one seat per tick, never two ticks at once
#   L/R box ls --json (with facts) and box rm
#   A* client add: contact.email stays in sqlite, never in the POST; bearer on stdin
#   S* client ls writes counts, marks a vanished slug removed; rm; mark
#   M* the firm table migration ALTERs a missing column into an old DB
#
# Run: bash tests/dive9254_onboarder_door_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d /tmp/onboarder-door.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
t() {  # t <name> <expected> <got>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   expected: %s\n   got:      %s\n' "$1" "$2" "$3"; fi
}
has() { [[ "$2" == *"$1"* ]] && echo yes || echo no; }  # has <needle> <haystack>
ex() { [[ -e "$1" ]] && echo yes || echo no; }

# --- stubs ----------------------------------------------------------------------------
LOG="$TMP/calls.log"; : > "$LOG"
fail() { echo "FAIL[$1] ${*:2}" >&2; exit "$1"; }
step() { :; }; warn() { :; }; require_root() { :; }; lazy_need() { :; }
E_USAGE=2 E_VALIDATION=3 E_NOT_FOUND=4 E_GENERIC=1 E_PERMISSION=6
JSON_MODE=0
REGF="$TMP/registry.json"; echo '{"agents":{}}' > "$REGF"
registry_read() { cat "$REGF"; }
with_registry_lock() { "$@"; }
cmd_create() {
  echo "create _ONBOARDER_OVERRIDE=${_ONBOARDER_OVERRIDE:-} _CREATE_STOPPED=${_CREATE_STOPPED:-} marker=$([[ -e "$ONBOARDER_MARKER_DIR/$1" ]] && echo yes || echo no) $*" >> "$LOG"
  jq --arg n "$1" '.agents[$n] = {type: "claude"}' "$REGF" > "$REGF.n" && mv "$REGF.n" "$REGF"
  mkdir -p "$ONBOARDER_HOME_ROOT/agent-$1/.claude"
}
cmd_rm() {
  echo "rm $*" >> "$LOG"
  jq --arg n "$1" 'del(.agents[$n])' "$REGF" > "$REGF.n" && mv "$REGF.n" "$REGF"
  rm -rf "${ONBOARDER_HOME_ROOT:?}/agent-$1"
}
RUNNING=" "
systemctl() {
  echo "systemctl $*" >> "$LOG"
  case "$1" in
    is-active) u=${3#5dive-agent@}; [[ "$RUNNING" == *" ${u%.service}"* ]] ;;
    *) return 0 ;;
  esac
}
five_api_base() { printf 'https://api.test'; }
export CONNECTORD_TOKEN=tok-secret-123
_partner_box_token() { printf '%s' "$CONNECTORD_TOKEN"; }
CURL_CODE=201; CURL_BODY='{}'
curl() {  # records method, url, body and the header that came in on stdin
  local o="" m=GET d="" u="" all="$*"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o) o="$2"; shift ;; -X) m="$2"; shift ;; --data-binary) d="${2#@}"; shift ;;
      -H|-w|--max-time) shift ;; -*) ;; *) u="$1" ;;
    esac; shift
  done
  { echo "curl $m $u"; echo "argv-has-token=$([[ "$all" == *tok-secret* ]] && echo yes || echo no)"
    echo "stdin=$(cat)"; [[ -n "$d" ]] && echo "body=$(cat "$d")"; } >> "$LOG"
  printf '%s' "$CURL_BODY" > "$o"; printf '%s' "$CURL_CODE"
}
export ONBOARDER_STATE_DIR="$TMP/state" ONBOARDER_MARKER_DIR="$TMP/markers" ONBOARDER_FACT_SHEET="$TMP/sheet.md" \
       ONBOARDER_CRON_FILE="$TMP/cron" ONBOARDER_HOME_ROOT="$TMP/home" ONBOARDER_FIRMS_DB="$TMP/mkt/push/firms.sqlite"
printf '5dive runs a team of AI agents on your own server.\n' > "$ONBOARDER_FACT_SHEET"
# shellcheck source=src/cmd_onboarder.sh
. src/cmd_onboarder.sh

# --- V: the wider brief ---------------------------------------------------------------------
prob() { _onboarder_brief_problem <<<"$1"; }
BRIEF='{"firm":"Acme Law","domains":["example.com"],"band":"Team","setup":"cloud","field":"law","size":"120","country":"UK","facts":["120 lawyers"],"insight":{"kind":"hiring","text":"Hiring two paralegals in Leeds"},"contact":{"name":"Jo Bloggs","role":"Managing partner"}}'
t 'V1 field, size, country and insight pass' '' "$(prob "$BRIEF")"
t 'V2 an email inside insight is refused' yes "$(has email "$(prob '{"firm":"A","domains":["a.com"],"insight":{"kind":"x","text":"mail user@example.com"}}')")"
t 'V2 ...an email in contact is refused (the box never takes one)' yes "$(has contact "$(prob '{"firm":"A","domains":["a.com"],"contact":{"name":"J","email":"user@example.com"}}')")"
t 'V3 an insight over 2000 characters is refused' yes "$(has insight "$(prob "$(jq -cn '{firm:"A",domains:["a.com"],insight:{kind:"k",text:("x" * 2001)}}')")")"
t 'V3 ...and one with an extra key' yes "$(has insight "$(prob '{"firm":"A","domains":["a.com"],"insight":{"text":"t","url":"u"}}')")"
n=onb-w0a1b2c
t 'V4 a seat name fits a Linux user name' yes "$(_onboarder_valid_seat "$n" && (( ${#n} <= 16 )) && echo yes || echo no)"

# --- C: box create is files only ------------------------------------------------------------
out=$(jq -cn --argjson b "$BRIEF" '{brief: $b, instructions: "# Acme rules\nAnswer from the fact sheet."}' \
       | (cmd_onboarder_box create acme --json) 2>&1)
t 'C1 box create answers {ok,slug}' '{"ok":true,"slug":"acme","updated":false}' "$out"
t 'C1 ...and makes no seat' 0 "$(grep -c '^create ' "$LOG")"
t 'C1 ...stores the brief with the new fields' '["Acme Law","law","hiring"]' "$(jq -c '[.firm,.field,.insight.kind]' "$TMP/state/acme.json")"
t 'C1 ...and the instructions as sent' '# Acme rules' "$(head -1 "$TMP/state/acme/instructions.md")"
t 'C2 the minute timer runs box tick' 1 "$(grep -c '^\* \* \* \* \* root /usr/local/bin/5dive onboarder box tick' "$TMP/cron")"
(echo '{"brief":{"firm":"Beta","domains":["beta.example"]}}' | cmd_onboarder_box create beta >/dev/null 2>&1)
t 'C3 no instructions: the generated rules + fact sheet + brief' 2 "$(grep -c -e "^# You are 5dive's AI assistant for Beta" -e '5dive runs a team of AI agents' "$TMP/state/beta/instructions.md")"
t 'C4 a brief with an email is refused, nothing stored' "3 no" "$( (echo '{"brief":{"firm":"O","domains":["o.com"],"facts":["user@example.com"]}}' | cmd_onboarder_box create other) >/dev/null 2>&1; echo "$? $(ex "$TMP/state/other.json")")"

# --- L: box ls -----------------------------------------------------------------------------------
t 'L1 box ls --json: no agent yet, facts carried' '{"slug":"acme","firm":"Acme Law","domains":["example.com"],"band":"Team","setup":"cloud","facts":["120 lawyers"],"agent":null,"running":false}' \
  "$(cmd_onboarder_box ls --json | jq -c '.[] | select(.slug == "acme")')"
t 'L1 ...facts is [] when the brief has none' '[]' "$(cmd_onboarder_box ls --json | jq -c '.[] | select(.slug == "beta") | .facts')"

# --- T: tick fills the warm pool ----------------------------------------------------------------
: > "$LOG"; cmd_onboarder_box tick 2>/dev/null
t 'T1 tick makes one warm seat per tick' 1 "$(grep -c '^create ' "$LOG")"
c=$(grep '^create ' "$LOG")
t 'T1 ...a sandboxed claude seat on dashboard only, no skills/team bot/heartbeat' yes "$(has '--type=claude --channels=dashboard --isolation=sandboxed --no-skills --no-team-bot --no-heartbeat' "$c")"
t 'T1 ...stamped onboarder, created stopped, marker first' yes "$(has '_ONBOARDER_OVERRIDE=1 _CREATE_STOPPED=1 marker=yes onb-w' "$c")"
t 'T1 ...and never left enabled' 1 "$(grep -c 'systemctl disable --now 5dive-agent@onb-w' "$LOG")"
cmd_onboarder_box tick 2>/dev/null; : > "$LOG"; cmd_onboarder_box tick 2>/dev/null
t 'T1 ...up to ONBOARDER_WARM (2), then stops' "2 0" "$(ls "$TMP/state/warm" | wc -l) $(grep -c '^create ' "$LOG")"
exec 7>"$TMP/state/.refill.lock"; flock 7
: > "$LOG"; mv "$TMP/state/warm" "$TMP/warm.keep"; mkdir "$TMP/state/warm"; cmd_onboarder_box tick 2>/dev/null
t 'T2 a tick while another runs does nothing' 0 "$(grep -c '^create ' "$LOG")"
exec 7>&-
rm -rf "$TMP/state/warm"; mv "$TMP/warm.keep" "$TMP/state/warm"

# --- W: wake adopts a warm seat --------------------------------------------------------------------
: > "$LOG"
out=$(printf 'visitor: how much is it?\nbot: Team is on the Buy card.\n' | cmd_onboarder_box wake acme --json)
seat=$(jq -r .agent <<<"$out")
t 'W1 wake adopts a warm seat and starts it' "true yes" "$(jq -r .started <<<"$out") $([[ "$seat" == onb-w* ]] && echo yes || echo no)"
t 'W1 ...takes it out of the pool and names it in <slug>.seat' "no $seat" "$(ex "$TMP/state/warm/$seat") $(cat "$TMP/state/acme.seat")"
t 'W1 ...no new seat was made' 0 "$(grep -c '^create ' "$LOG")"
t 'W1 ...started it' 1 "$(grep -c "systemctl start 5dive-agent@$seat.service" "$LOG")"
md="$TMP/home/agent-$seat/.claude/CLAUDE.md"
t 'W2 CLAUDE.md is the firm instructions + the chat so far' "# Acme rules|1|1" "$(head -1 "$md")|$(grep -c '^## The chat so far$' "$md")|$(grep -c '^visitor: how much is it?$' "$md")"
t 'W2 ...root-owned 640' 640 "$(stat -c %a "$md")"
t 'L2 box ls shows the agent' "\"$seat\"" "$(cmd_onboarder_box ls --json | jq -c '.[] | select(.slug == "acme") | .agent')"
RUNNING=" $seat"; : > "$LOG"
out=$(cmd_onboarder_box wake acme --json </dev/null)
t 'W3 a running seat is left alone' "false 0" "$(jq -r .started <<<"$out") $(grep -c 'systemctl start' "$LOG")"
rm -f "$TMP/state/warm/"*; : > "$LOG"
out=$(cmd_onboarder_box wake beta --json </dev/null)
b=$(jq -r .agent <<<"$out")
t 'W4 an empty pool: wake makes a locked seat and starts it' "1 true" "$(grep -c '_CREATE_STOPPED=1 marker=yes onb-w' "$LOG") $(jq -r .started <<<"$out")"
t 'W4 ...without a chat, CLAUDE.md has no chat section' 0 "$(grep -c 'The chat so far' "$TMP/home/agent-$b/.claude/CLAUDE.md")"
t 'W5 an unknown slug is not found' 4 "$( (cmd_onboarder_box wake nope </dev/null) >/dev/null 2>&1; echo $?)"

# --- T: idle removal, queued start ------------------------------------------------------------------
: > "$LOG"; cmd_onboarder_box tick 2>/dev/null
t 'T3 a seat seen just now stays' 0 "$(grep -c '^rm ' "$LOG")"
touch -d '-121 minutes' "$TMP/state/acme.active"
: > "$LOG"; cmd_onboarder_box tick 2>/dev/null
t 'T3 a seat quiet 2 h is REMOVED with its home' 1 "$(grep -cx "rm $seat --purge-home" "$LOG")"
t 'T3 ...its .seat and marker go, the firm files stay' "no no yes" "$(ex "$TMP/state/acme.seat") $(ex "$TMP/markers/$seat") $(ex "$TMP/state/acme/instructions.md")"
t 'T4 the same tick refills the pool' 1 "$(grep -c '^create ' "$LOG")"
RUNNING=" "
inbox="$TMP/home/agent-$b/.claude/channels/dashboard/agent-inbox"; mkdir -p "$inbox"; echo '{}' > "$inbox/1.json"
touch -d '-121 minutes' "$TMP/state/beta.active" "$inbox/1.json" "$inbox"
: > "$LOG"; cmd_onboarder_box tick 2>/dev/null
t 'T5 a stopped seat with a queued message is started, not removed' "1 0" "$(grep -c "systemctl start 5dive-agent@$b.service" "$LOG") $(grep -c '^rm ' "$LOG")"

# --- R: box rm -------------------------------------------------------------------------------------------
: > "$LOG"; out=$(cmd_onboarder_box rm beta --json)
t 'R1 box rm answers {ok,slug,removed}' '{"ok":true,"slug":"beta","removed":true}' "$out"
t 'R1 ...removes the seat and every file' "1 no no no no" "$(grep -cx "rm $b --purge-home" "$LOG") $(ex "$TMP/state/beta.json") $(ex "$TMP/state/beta") $(ex "$TMP/state/beta.seat") $(ex "$TMP/markers/$b")"

# --- M: the firm table migration ----------------------------------------------------------------------
mkdir -p "$TMP/mkt/push"
sqlite3 "$ONBOARDER_FIRMS_DB" "CREATE TABLE firms (slug TEXT PRIMARY KEY, firm TEXT, opened INTEGER NOT NULL DEFAULT 0); INSERT INTO firms (slug, firm, opened) VALUES ('old', 'Old Co', 4);"
_onboarder_db >/dev/null
cols=$(sqlite3 "$ONBOARDER_FIRMS_DB" "SELECT group_concat(name, ',') FROM pragma_table_info('firms');")
t 'M1 an old table gets the missing columns' "yes yes yes" "$(has contact_email "$cols") $(has agent_status "$cols") $(has counts_at "$cols")"
t 'M1 ...and keeps its rows' 'Old Co|4|asleep|0' "$(sqlite3 "$ONBOARDER_FIRMS_DB" "SELECT firm, opened, agent_status, opted_out FROM firms WHERE slug='old';")"

# --- A: client add ------------------------------------------------------------------------------------
jq -n --argjson b "$BRIEF" '$b | .contact.email = "User@example.com"' > "$TMP/acme-brief.json"
CURL_CODE=201; CURL_BODY='{"slug":"acme","link":"https://5dive.ai/enterprise/for/acme"}'; : > "$LOG"
out=$(cmd_onboarder add acme --brief="$TMP/acme-brief.json")
t 'A1 add prints the link alone on the last line' 'https://5dive.ai/enterprise/for/acme' "$(tail -1 <<<"$out")"
t 'A1 ...POSTs to /server/onboarders' 1 "$(grep -cx 'curl POST https://api.test/server/onboarders' "$LOG")"
body=$(sed -n 's/^body=//p' "$LOG")
t 'A2 the POST carries {slug, brief} without contact.email' '"acme" "Jo Bloggs" null' "$(jq -c '.slug, .brief.contact.name, .brief.contact.email' <<<"$body" | paste -sd ' ')"
t 'A2 ...no address anywhere in it' no "$(has '@' "$body")"
t 'A3 the bearer rides stdin, never argv' "no yes" "$(sed -n 's/^argv-has-token=//p' "$LOG") $(has 'Authorization: Bearer tok-secret-123' "$(grep '^stdin=' "$LOG")")"
t 'A4 the row holds the address and the link; its brief does not' 'user@example.com|https://5dive.ai/enterprise/for/acme|Acme Law|law|hiring|asleep|0' \
  "$(sqlite3 "$ONBOARDER_FIRMS_DB" "SELECT contact_email, link, firm, field, insight_kind, agent_status, json_extract(brief, '\$.contact.email') IS NOT NULL FROM firms WHERE slug='acme';")"
# an address on the parent of the firm's only domain is not on its domain
jq -n --argjson b "$BRIEF" '$b | .domains = ["acme.example.com"] | .contact.email = "user@example.com"' > "$TMP/bad.json"
: > "$LOG"
t 'A5 an address off the firm'"'"'s domains is refused before any call' "3 0" "$( (cmd_onboarder add bad --brief="$TMP/bad.json") >/dev/null 2>&1; echo "$? $(grep -c '^curl' "$LOG")")"
CURL_CODE=409; CURL_BODY='{"error":"exists","message":"that slug is taken"}'
jq -n '{firm:"Gamma",domains:["gamma.example"]}' > "$TMP/gamma.json"
out=$( (cmd_onboarder add gamma --brief="$TMP/gamma.json") 2>&1 ); rc=$?
t 'A6 a refusal prints the API message and writes no row' "1 yes 0" "$rc $(has 'that slug is taken' "$out") $(sqlite3 "$ONBOARDER_FIRMS_DB" "SELECT count(*) FROM firms WHERE slug='gamma';")"
CURL_CODE=201; : > "$LOG"
out=$( (unset CONNECTORD_TOKEN; _partner_box_token() { return 2; }; cmd_onboarder add gamma --brief="$TMP/gamma.json") 2>&1 ); rc=$?
t 'A7 no box token: refused, nothing sent' "6 0" "$rc $(grep -c '^curl' "$LOG")"

# --- S: client ls, rm, mark ---------------------------------------------------------------------------
CURL_CODE=200
CURL_BODY='{"onboarders":[{"slug":"acme","firm":"Acme Law","domains":["example.com"],"band":"Team","agent":"onb-w123456","running":true,"counts":{"opened":3,"joined":2,"messages":7,"buyClicked":1,"bought":0}}]}'
out=$(cmd_onboarder ls --json)
t 'S1 ls writes the counts and awake' '[3,2,7,1,0,"awake"]' "$(jq -c '.[] | select(.slug == "acme") | [.opened,.joined,.messages,.buy_clicked,.bought,.agent_status]' <<<"$out")"
t 'S1 ...a slug 5dive no longer has is removed' '"removed"' "$(jq -c '.[] | select(.slug == "old") | .agent_status' <<<"$out")"
t 'S1 ...counts_at is stamped' yes "$(jq -r '.[] | select(.slug == "acme") | .counts_at' <<<"$out" | grep -q '^20' && echo yes || echo no)"
out=$(cmd_onboarder ls)
t 'S2 the table: slug, firm, counts, status, sent' yes "$(grep -Eq '^acme +Acme Law +3 +2 +7 +1 +0 +awake +-$' <<<"$out" && echo yes || echo no)"
CURL_BODY='{"onboarders":[{"slug":"acme","firm":"Acme Law","agent":null,"running":false,"counts":{"opened":3,"joined":2,"messages":7,"buyClicked":1,"bought":1}}]}'
cmd_onboarder ls >/dev/null
t 'S3 agent null reads asleep' 'asleep|1' "$(sqlite3 "$ONBOARDER_FIRMS_DB" "SELECT agent_status, bought FROM firms WHERE slug='acme';")"
cmd_onboarder mark acme --sent=2026-11-25T09:30:00Z >/dev/null
cmd_onboarder mark old --opted-out >/dev/null
t 'S4 mark --sent and --opted-out' '2026-11-25T09:30:00Z|0 |1' "$(sqlite3 "$ONBOARDER_FIRMS_DB" "SELECT coalesce(sent_at,'') || '|' || opted_out FROM firms WHERE slug IN ('acme','old') ORDER BY slug;" | paste -sd ' ')"
t 'S4 ...an unknown firm is not found' 4 "$( (cmd_onboarder mark nope --sent) >/dev/null 2>&1; echo $?)"
CURL_CODE=404; CURL_BODY='{"error":"not_found"}'; : > "$LOG"
cmd_onboarder rm acme >/dev/null
t 'S5 rm DELETEs; a 404 still marks it removed, the row stays' "1 removed|user@example.com" "$(grep -cx 'curl DELETE https://api.test/server/onboarders/acme' "$LOG") $(sqlite3 "$ONBOARDER_FIRMS_DB" "SELECT agent_status || '|' || contact_email FROM firms WHERE slug='acme';")"
u=$(_onboarder_usage); a=${u%%add <slug>*}; b=${u%%box create*}
t 'H1 help lists the client verbs before box' yes "$( (( ${#a} < ${#b} )) && echo yes || echo no)"

echo "---"; echo "pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
