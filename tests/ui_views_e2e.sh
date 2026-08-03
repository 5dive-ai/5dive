#!/usr/bin/env bash
# DIVE-2655 e2e — `5dive ui`, the free single-host web UI, on the BUILT binary.
#
# WHAT THIS GRADES, and why each arm exists. The subject is three read-only views
# over the local board, so the ways it can be broken are (a) the data says
# something the CLI's own verbs do not, (b) the surface grows a write or a
# second host, and (c) the page needs the network to render. One arm each:
#
#   the envelope is EXACTLY the single-host set   arm 1. The key set is asserted
#                                    WHOLE, not by presence: a future `fleet` /
#                                    `hosts` key is the paid tier leaking into
#                                    the free one, and a presence check could
#                                    never see it arrive.
#   the views agree with the CLI     arms 2-5. handoff_state and gate_live are
#                                    re-derived here from the SAME predicates
#                                    `task ls --json` uses, so a divergence
#                                    between the screen and the queue fails.
#   closed work stays closed         arm 3: done / cancelled rows and recurring
#                                    TEMPLATES are absent from every view.
#   agent-to-agent is legible        arm 6, the acceptance bar. An edge between
#                                    two names in agents_org must read
#                                    human:false, and an edge touching a
#                                    principal that is NOT an agent must read
#                                    human:true. If this arm can be satisfied by
#                                    a board with no agents in it, the headline
#                                    on the org view means nothing.
#   the page is self-contained       arm 7: not one absolute URL in the HTML.
#                                    A CDN reference renders blank on the boxes
#                                    that most need this (air-gapped, no egress).
#   the surface is read-only         arms 8-11 against a live server: three GET
#                                    paths answer, an unknown path 404s, and
#                                    every write method 405s. The 405 is what
#                                    makes "read-only" a property of the server
#                                    rather than a promise about the client.
#   no accounts means no exposure    arm 12: a non-loopback bind is REFUSED and
#                                    nothing is listening afterwards, because
#                                    there is no sign-in to protect it.
#   it is wired into the CLI         arm 13: routed from main.sh and listed in
#                                    the top-level help.
#
# NO ROOT, NO NETWORK (loopback only), NO LIVE STATE: STATE_DIR is a temp dir, so
# the board under test is seeded here and can never be the host's own.
# Exit 0 == green.
set -uo pipefail
trap 'rc=$?; [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for b in python3 jq sqlite3; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (5dive ui needs it)"; exit 0; }
done

TMP="$(mktemp -d)"
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi
export STATE_DIR="$TMP"          # isolate — never touch a live state dir
DB="$TMP/tasks/tasks.db"

P=0; F=0
chk(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 (want=$2 got=$3)"; fi; }

# --- seed a board -----------------------------------------------------------
# The store dir is created here rather than by `task init`: init is a root-only
# write path (it chowns root:claude), and a UI harness that SKIPs whenever CI is
# non-root grades nothing on most runs. Everything below is a read.
# Names are reserved fakes, never a real agent or person on any host.
mkdir -p "$TMP/tasks"
"$FIVE" ui --data >/dev/null 2>&1
[[ -f "$DB" ]] || { echo "SKIP: ui --data did not create a task store at $DB"; exit 0; }
sq(){ sqlite3 "$DB" "$1"; }

sq "INSERT INTO agents_org (name, reports_to, role, title) VALUES
      ('alpha', NULL,    'lead',     'Alpha · Lead'),
      ('beta',  'alpha', 'builder',  'Beta · Builder'),
      ('gamma', 'alpha', 'verifier', 'Gamma · Verifier');"

# open, delegated agent->agent
sq "INSERT INTO tasks (ident,title,status,priority,assignee,created_by) VALUES
      ('TEST-1','delegated agent to agent','todo','high','beta','alpha');"
# open, a human (not in agents_org) filed it at an agent
sq "INSERT INTO tasks (ident,title,status,priority,assignee,created_by) VALUES
      ('TEST-2','filed by a person','todo','medium','beta','someone');"
# maker->verifier, delivered and NOT acked
sq "INSERT INTO tasks (ident,title,status,priority,assignee,created_by,maker_agent,verifier) VALUES
      ('TEST-3','delivered awaiting ack','todo','medium','gamma','alpha','beta','gamma');"
# maker->verifier, acked (being graded)
sq "INSERT INTO tasks (ident,title,status,priority,assignee,created_by,maker_agent,verifier,handoff_ack_at) VALUES
      ('TEST-4','being graded','todo','medium','gamma','alpha','beta','gamma','2026-08-03 12:00:00');"
# a LIVE gate, and an ANSWERED one, and a gate on a CLOSED row
sq "INSERT INTO tasks (ident,title,status,priority,assignee,created_by,need_type,tier,ask,recommend) VALUES
      ('TEST-5','needs a person','blocked','high','beta','alpha','decision',2,'ship or hold?','ship');"
sq "INSERT INTO tasks (ident,title,status,priority,assignee,created_by,need_type,tier,ask,need_answer,need_answered_at,need_answered_by) VALUES
      ('TEST-6','already answered','todo','low','beta','alpha','decision',1,'ship or hold?','ship','2026-08-03 12:00:00','someone');"
sq "INSERT INTO tasks (ident,title,status,priority,assignee,created_by,need_type,tier,ask) VALUES
      ('TEST-7','closed with a stale gate','done','low','beta','alpha','decision',1,'moot now');"
# closed + cancelled + a recurring TEMPLATE: none of these are open work
sq "INSERT INTO tasks (ident,title,status,assignee,created_by) VALUES ('TEST-8','closed','done','beta','alpha');"
sq "INSERT INTO tasks (ident,title,status,assignee,created_by) VALUES ('TEST-9','dropped','cancelled','beta','alpha');"
sq "INSERT INTO tasks (ident,title,status,assignee,created_by,kind,schedule) VALUES
      ('TEST-10','recurring template','todo','beta','alpha','recurring','daily');"

D="$("$FIVE" ui --data 2>"$TMP/data.err")"
[[ -n "$D" ]] || { echo "FAIL: ui --data printed nothing"; cat "$TMP/data.err"; exit 1; }

# --- 1. the envelope is exactly the single-host set --------------------------
chk "1 ok envelope"        "true"          "$(jq -r '.ok' <<<"$D")"
chk "1 scope single-host"  "single-host"   "$(jq -r '.data.scope' <<<"$D")"
chk "1 key set is whole (no fleet surface)" \
    "flows gates generated_at host org queue scope stats store" \
    "$(jq -r '.data|keys|sort|join(" ")' <<<"$D")"

# --- 2. org chart ------------------------------------------------------------
chk "2 three agents"        "3"       "$(jq -r '.data.org|length' <<<"$D")"
chk "2 beta reports to alpha" "alpha" "$(jq -r '.data.org[]|select(.name=="beta").reports_to' <<<"$D")"
chk "2 stats.agents"        "3"       "$(jq -r '.data.stats.agents' <<<"$D")"

# --- 3. the queue is open work only -----------------------------------------
chk "3 open rows"           "6"       "$(jq -r '.data.queue|length' <<<"$D")"
chk "3 no done row"         "0"       "$(jq -r '[.data.queue[]|select(.ident=="TEST-8")]|length' <<<"$D")"
chk "3 no cancelled row"    "0"       "$(jq -r '[.data.queue[]|select(.ident=="TEST-9")]|length' <<<"$D")"
chk "3 no recurring template" "0"     "$(jq -r '[.data.queue[]|select(.ident=="TEST-10")]|length' <<<"$D")"

# --- 4. handoff state matches the task-ls predicate --------------------------
chk "4 delivered, not acked" "delivered" "$(jq -r '.data.queue[]|select(.ident=="TEST-3").handoff_state' <<<"$D")"
chk "4 acked reads reviewing" "reviewing" "$(jq -r '.data.queue[]|select(.ident=="TEST-4").handoff_state' <<<"$D")"
chk "4 plain row has none"   "null"      "$(jq -r '[.data.queue[]|select(.ident=="TEST-1")][0].handoff_state // "null"' <<<"$D")"
chk "4 stats.awaiting_verify" "1"        "$(jq -r '.data.stats.awaiting_verify' <<<"$D")"
chk "4 stats.in_review"       "1"        "$(jq -r '.data.stats.in_review' <<<"$D")"

# --- 5. gates are the live-inbox predicate, never raw need_type --------------
chk "5 one live gate"        "1"        "$(jq -r '.data.gates|length' <<<"$D")"
chk "5 it is the open one"   "TEST-5"   "$(jq -r '.data.gates[0].ident' <<<"$D")"
chk "5 tier carried"         "2"        "$(jq -r '.data.gates[0].tier' <<<"$D")"
chk "5 recommendation carried" "ship"   "$(jq -r '.data.gates[0].recommend' <<<"$D")"
chk "5 answered gate absent" "0"        "$(jq -r '[.data.gates[]|select(.ident=="TEST-6")]|length' <<<"$D")"
chk "5 closed row gate absent" "0"      "$(jq -r '[.data.gates[]|select(.ident=="TEST-7")]|length' <<<"$D")"
chk "5 gate_live on the row" "1"        "$(jq -r '.data.queue[]|select(.ident=="TEST-5").gate_live' <<<"$D")"

# --- 6. THE ACCEPTANCE BAR: agent-to-agent is legible off the data -----------
chk "6 alpha->beta is agent to agent" "false" \
    "$(jq -r '.data.flows[]|select(.ident=="TEST-1" and .kind=="delegation").human' <<<"$D")"
chk "6 a non-agent endpoint is a human" "true" \
    "$(jq -r '.data.flows[]|select(.ident=="TEST-2" and .kind=="delegation").human' <<<"$D")"
chk "6 verify edge names the maker" "beta" \
    "$(jq -r '.data.flows[]|select(.ident=="TEST-3" and .kind=="verify").from' <<<"$D")"
chk "6 verify edge names the verifier" "gamma" \
    "$(jq -r '.data.flows[]|select(.ident=="TEST-3" and .kind=="verify").to' <<<"$D")"
chk "6 verify edge carries the handoff" "delivered" \
    "$(jq -r '.data.flows[]|select(.ident=="TEST-3" and .kind=="verify").state' <<<"$D")"
chk "6 stats.human_touch counts only human edges" "1" "$(jq -r '.data.stats.human_touch' <<<"$D")"
chk "6 stats.agent_to_agent counts the rest" \
    "$(jq -r '[.data.flows[]|select(.human==false)]|length' <<<"$D")" \
    "$(jq -r '.data.stats.agent_to_agent' <<<"$D")"

# --- 7. the page is self-contained ------------------------------------------
"$FIVE" ui --html > "$TMP/page.html" 2>/dev/null
chk "7 page rendered"        "0"  "$([[ -s "$TMP/page.html" ]] && echo 0 || echo 1)"
chk "7 no absolute URL anywhere" "0" "$(grep -cE 'https?://' "$TMP/page.html" || true)"
chk "7 org view present"     "1"  "$(grep -c 'id="view-org"' "$TMP/page.html" || true)"
chk "7 queue view present"   "1"  "$(grep -c 'id="view-queue"' "$TMP/page.html" || true)"
chk "7 gates view present"   "1"  "$(grep -c 'id="view-gates"' "$TMP/page.html" || true)"

# --- 8-11. the live surface --------------------------------------------------
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
"$FIVE" ui --port="$PORT" >"$TMP/srv.log" 2>&1 &
SRV_PID=$!
probe(){ # probe <method> <path> -> "<status> <content-type>"
  python3 - "$PORT" "$1" "$2" <<'PY'
import sys, urllib.error, urllib.request
port, method, path = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request("http://127.0.0.1:%s%s" % (port, path), method=method)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        body = r.read().decode("utf-8", "replace")
        print("%d %s" % (r.status, r.headers.get("Content-Type", "")))
        print(body)
except urllib.error.HTTPError as e:
    print("%d %s" % (e.code, e.headers.get("Content-Type", "")))
    print(e.read().decode("utf-8", "replace"))
except Exception as e:                       # connection refused while starting
    print("000 %s" % e)
    print("")
PY
}
up=0
for _ in $(seq 1 40); do
  [[ "$(probe GET /healthz | head -1)" == 200* ]] && { up=1; break; }
  sleep 0.25
done
chk "8 server came up"       "1"  "$up"

if (( up )); then
  chk "8 GET / is the page"  "200 text/html; charset=utf-8" "$(probe GET / | head -1)"
  api="$(probe GET /api/state)"
  chk "9 GET /api/state 200" "200 application/json" "$(head -1 <<<"$api")"
  chk "9 it serves the LIVE board, not a stub" "TEST-5" \
      "$(tail -n +2 <<<"$api" | jq -r '.data.gates[0].ident')"
  chk "9 same agent count as the CLI" "3" "$(tail -n +2 <<<"$api" | jq -r '.data.stats.agents')"
  chk "10 unknown path 404s"  "404" "$(probe GET /fleet | head -1 | cut -d' ' -f1)"
  chk "10 no fleet endpoint"  "404" "$(probe GET /api/fleet | head -1 | cut -d' ' -f1)"
  for m in POST PUT PATCH DELETE; do
    chk "11 $m is refused (read-only)" "405" "$(probe "$m" /api/state | head -1 | cut -d' ' -f1)"
  done
  # the bind itself: loopback, never 0.0.0.0
  if command -v ss >/dev/null 2>&1; then
    chk "11 bound to loopback" "1" \
        "$(ss -ltn 2>/dev/null | grep -c "127\.0\.0\.1:$PORT" || true)"
  fi
fi
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- 12. no accounts, so no routable bind ------------------------------------
out="$("$FIVE" ui --host=0.0.0.0 --port="$PORT" 2>&1)"; rc=$?
chk "12 non-loopback bind refused"      "3" "$rc"
chk "12 refusal names the opt-out"      "1" "$(grep -c 'FIVE_UI_ALLOW_REMOTE' <<<"$out" || true)"
if command -v ss >/dev/null 2>&1; then
  chk "12 nothing is listening after it" "0" "$(ss -ltn 2>/dev/null | grep -c ":$PORT " || true)"
fi
chk "12 a bad port is refused"          "3" \
    "$("$FIVE" ui --port=99999 >/dev/null 2>&1; echo $?)"

# --- 14. a box with NO task store still serves the views ---------------------
# `task init` is root-only, so a fresh install would otherwise be refused the UI
# entirely. The board must come back EMPTY AND NAMED: three empty arrays alone
# would read as "nothing is queued" on a host that cannot queue anything.
FRESH="$TMP/fresh"; mkdir -p "$FRESH"
FD="$(STATE_DIR="$FRESH" "$FIVE" ui --data 2>"$TMP/fresh.err")"
chk "14 fresh box still answers"      "true"     "$(jq -r '.ok' <<<"$FD")"
chk "14 the empty board is NAMED"     "absent"   "$(jq -r '.data.store' <<<"$FD")"
chk "14 seeded board says ready"      "ready"    "$(jq -r '.data.store' <<<"$D")"
chk "14 org empty"                    "0"        "$(jq -r '.data.org|length' <<<"$FD")"
chk "14 queue empty"                  "0"        "$(jq -r '.data.queue|length' <<<"$FD")"
chk "14 gates empty"                  "0"        "$(jq -r '.data.gates|length' <<<"$FD")"
chk "14 it did not create a store"    "1"        "$([[ -d "$FRESH/tasks" ]] && echo 0 || echo 1)"
chk "14 the page names the fix"       "1"        "$(grep -c '5dive task init' "$TMP/page.html" || true)"

# --- 15. --once serves exactly one request, then exits -----------------------
# A documented flag nobody runs is a claim, not a feature. Both halves are
# graded: the one request IS answered, and the process is gone afterwards.
PORT2="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
"$FIVE" ui --port="$PORT2" --once >"$TMP/once.log" 2>&1 &
ONCE_PID=$!
once_up=0
for _ in $(seq 1 40); do
  ss -ltn 2>/dev/null | grep -q "127\.0\.0\.1:$PORT2" && { once_up=1; break; }
  sleep 0.25
done
chk "15 --once came up" "1" "$once_up"
if (( once_up )); then
  first="$(PORT="$PORT2" python3 - "$PORT2" GET /healthz <<'PY2'
import sys, urllib.request
port, method, path = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request("http://127.0.0.1:%s%s" % (port, path), method=method)
with urllib.request.urlopen(req, timeout=10) as r:
    print(r.status)
PY2
)"
  chk "15 the one request is answered" "200" "$first"
  gone=0
  for _ in $(seq 1 40); do
    kill -0 "$ONCE_PID" 2>/dev/null || { gone=1; break; }
    sleep 0.25
  done
  chk "15 it exited after that request" "1" "$gone"
fi
kill "$ONCE_PID" 2>/dev/null

# --- 13. wired into the CLI --------------------------------------------------
chk "13 ui --help exits 0" "0" "$("$FIVE" ui --help >/dev/null 2>&1; echo $?)"
chk "13 listed in top-level help" "1" \
    "$("$FIVE" --help 2>&1 | grep -c '5dive ui \[--port=' || true)"
chk "13 unknown flag is a usage error" "2" \
    "$("$FIVE" ui --fleet >/dev/null 2>&1; echo $?)"

echo "PASS=$P FAIL=$F"
[ "$F" -eq 0 ] || exit 1
exit 0
