#!/usr/bin/env bash
# DIVE-5926 — `5dive bug --file` goes to OUR API with the box key, only after the
# owner says yes, and never asks twice about one defect.
#
# The transport is graded for real: _bug_post's curl talks to a mock endpoint on
# 127.0.0.1 that records the path, the Authorization header and the body of every
# request it receives. Every "nothing was sent" arm reads that record, so it is
# graded by what reached the wire, not by what the verb printed.
#
# Arms: the no-TTY refusal without --owner-approved (rc, text, zero requests);
# the approved POST (path, bearer, allowlisted keys); offline -> spooled -> the
# next approved call drains it; a 4xx is an answer, not spooled; the asked-ledger
# (same defect -> "already asked on <date>", another defect the same day -> "today");
# a token-shaped --what is refused; and the negative control that no GitHub route
# is left in cmd_bug.sh. DIVE-6616 (arm 5): no key file -> the open /bug-reports
# route and its spool drain; a readable one -> the keyed route, unchanged.
# DIVE-7248 (5d): an unreadable key (a non-root seat on one of our boxes) -> the
# open route too, and it drains what that seat spooled before; only if the open
# route fails is it spooled, with the access reason.
# DIVE-9000 (arm 9): a keyless report's reply token lands in the seat's 0600
# ledger; the heartbeat's daily poll hands 5dive's answer to the lead agent once,
# drops the entry after "fixed", after 30 days or on a 404, and keeps a send that
# failed for the next tick.
set -uo pipefail

TMP=""; SRV_PID=""
trap 'rc=$?; [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
chk()    { if [[ "$2" == "$3" ]]; then ok_t "$1"; else fail_t "$1 (expected '$2', got '$3')"; fi }

if ! command -v python3 >/dev/null || ! command -v curl >/dev/null; then
  ok_t "SKIP: no python3/curl on this host for the mock endpoint"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 0
fi

TMP=$(mktemp -d)
mkdir -p "$TMP/reqs" "$TMP/gets" "$TMP/replies"
export XDG_STATE_HOME="$TMP/state" FIVE_BUG_ASKED_LEDGER="$TMP/box-asked.tsv"
export CONNECTORD_TOKEN="fake-box-token-0000" FIVE_BUG_POST_TIMEOUT=5
SPOOL="$TMP/state/5dive/bug-spool"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/self.sh cmd_selfcheck.sh cmd_partner.sh cmd_bug.sh; do
  source "src/$f"
done
set +e
_sc_dispatch() { printf '%s\n' "pass||clean"; }

# ── the mock endpoint ──────────────────────────────────────────────────────────
# Status comes from $TMP/status (default 201) so one server covers every arm.
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 - "$TMP" "$PORT" >/dev/null 2>&1 <<'PY' &
import http.server, json, os, sys
d, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode()
        i = len(os.listdir(os.path.join(d, "reqs")))
        with open(os.path.join(d, "reqs", "%03d.json" % i), "w") as f:
            json.dump({"path": self.path, "auth": self.headers.get("Authorization"), "body": body}, f)
        try:
            status = int(open(os.path.join(d, "status")).read().strip())
        except Exception:
            status = 201
        ok = {"ok": True, "id": "42"}
        if self.path == "/bug-reports": ok["reply_token"] = "ab" * 32
        out = json.dumps(ok if status < 300 else {"error": "nope"}).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    # DIVE-9000: GET /bug-reports/<id>/replies serves $TMP/replies/<id> once.
    def do_GET(self):
        i = len(os.listdir(os.path.join(d, "gets")))
        with open(os.path.join(d, "gets", "%03d.json" % i), "w") as f:
            json.dump({"path": self.path, "token": self.headers.get("X-Reply-Token")}, f)
        try:
            status = int(open(os.path.join(d, "getstatus")).read().strip())
        except Exception:
            status = 200
        rid = self.path.split("/")[2] if self.path.count("/") >= 3 else ""
        rf = os.path.join(d, "replies", rid)
        body = {"notices": []}
        if status == 200 and os.path.exists(rf):
            body = json.load(open(rf)); os.remove(rf)
        out = json.dumps(body if status == 200 else {"error": "nope"}).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
SRV_PID=$!
for _ in $(seq 50); do curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/ready" && break; sleep 0.1; done
rm -f "$TMP"/reqs/*
export FIVE_API_BASE="http://127.0.0.1:$PORT"
nreq() { find "$TMP/reqs" -type f | wc -l; }
req()  { jq -r "$2" "$TMP/reqs/$(printf '%03d' "$1").json"; }
CLOSED=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')

WHAT="agent list died on port 4711 after 3 retries"

# ── 1. no TTY, no --owner-approved: refused, nothing sent ─────────────────────
err=$(cmd_bug --verb=agent --exit=1 --what="$WHAT" --no-probes --file </dev/null 2>&1)
chk "--file with no TTY and no --owner-approved exits E_USAGE" "$E_USAGE" "$?"
[[ "$err" == *"Ask them in one line, naming what failed"* && "$err" == *"--owner-approved only on their yes"* ]] \
  && ok_t "the refusal tells the agent to ask its owner in one line and pass --owner-approved on a yes" \
  || fail_t "refusal text: $err"
chk "...and nothing reached the endpoint" 0 "$(nreq)"

# ── 2. with the flag: one POST, box bearer, allowlisted payload ───────────────
out=$(cmd_bug --verb=agent --exit=1 --what="$WHAT" --argv="agent list --token=abc123" --no-probes --file --owner-approved </dev/null 2>&1)
chk "--file --owner-approved exits 0" 0 "$?"
chk "exactly one request reached the endpoint" 1 "$(nreq)"
chk "it went to /server/bug-reports" "/server/bug-reports" "$(req 0 .path)"
chk "authenticated with the box's own key" "Bearer fake-box-token-0000" "$(req 0 .auth)"
chk "the body's keys are exactly the allowlist" \
  '["bash_version","exit_code","install_method","invocation","os","probes","verb","version","what"]' \
  "$(req 0 .body | jq -cS keys)"
chk "...carrying --what verbatim" "$WHAT" "$(req 0 .body | jq -r .what)"
chk "...and --argv redacted" "agent list --token=<redacted>" "$(req 0 .body | jq -r .invocation)"
[[ "$out" == *"report 42"* ]] && ok_t "the API's report id is printed" || fail_t "no report id: $out"
[[ "$(req 0 .body)" != *"fake-box-token"* ]] && ok_t "the key is a header, never in the payload" \
  || fail_t "the box key reached the payload"

# ── 3. offline -> spooled -> drained by the next approved --file ──────────────
rm -f "$TMP"/reqs/*
err=$(FIVE_API_BASE="http://127.0.0.1:$CLOSED" cmd_bug --verb=task --exit=1 --what="offline one" --no-probes --file --owner-approved </dev/null 2>&1)
chk "an unreachable API exits E_TIMEOUT" "$E_TIMEOUT" "$?"
chk "one spool file was written" 1 "$(find "$SPOOL" -name '*.json' | wc -l)"
[[ "$err" == *"next approved '5dive bug --file' sends it"* ]] && ok_t "the caller is told the next approved --file sends it" \
  || fail_t "spool text: $err"
echo 503 > "$TMP/status"
( cmd_bug --verb=task --exit=1 --what="offline two (5xx)" --no-probes --file --owner-approved </dev/null ) >/dev/null 2>&1
chk "a 5xx is spooled too (two waiting now)" 2 "$(find "$SPOOL" -name '*.json' | wc -l)"
rm -f "$TMP/status" "$TMP"/reqs/*
out=$(cmd_bug --verb=task --exit=1 --what="back online" --no-probes --file --owner-approved </dev/null 2>&1)
chk "the next approved --file exits 0" 0 "$?"
chk "it sent itself plus both spooled reports" 3 "$(nreq)"
chk "the spool is empty after the drain" 0 "$(find "$SPOOL" -name '*.json' | wc -l)"
sent=$(for i in 0 1 2; do req "$i" .body | jq -r .what; done | sort | tr '\n' '|')
chk "the drained bodies are the spooled reports" "back online|offline one|offline two (5xx)|" "$sent"
[[ "$out" == *"also sent 2 saved earlier"* ]] && ok_t "the drain is reported" || fail_t "drain text: $out"
# A GitHub-era .md spool was written for a public issue: never sent here.
printf '# old\n' > "$SPOOL/20260801T000000Z-1.md"
rm -f "$TMP"/reqs/*
( cmd_bug --verb=task --exit=1 --what="md left alone" --no-probes --file --owner-approved </dev/null ) >/dev/null 2>&1
chk "a legacy .md spool is not sent" 1 "$(nreq)"

# ── 4. a 4xx is an answer: not spooled, not retried ───────────────────────────
rm -f "$TMP"/reqs/*; echo 413 > "$TMP/status"
err=$(cmd_bug --verb=task --exit=1 --what="too big" --no-probes --file --owner-approved </dev/null 2>&1)
chk "a 413 exits E_VALIDATION" "$E_VALIDATION" "$?"
chk "...and is not spooled" 0 "$(find "$SPOOL" -name '*.json' | wc -l)"
echo 401 > "$TMP/status"
( cmd_bug --verb=task --exit=1 --what="key refused" --no-probes --file --owner-approved </dev/null ) >/dev/null 2>&1
chk "a 401 exits E_AUTH_REQUIRED" "$E_AUTH_REQUIRED" "$?"
echo 404 > "$TMP/status"
( cmd_bug --verb=task --exit=1 --what="endpoint not deployed yet" --no-probes --file --owner-approved </dev/null ) >/dev/null 2>&1
chk "a 404 (CLI released before the API route) exits E_TIMEOUT" "$E_TIMEOUT" "$?"
chk "...and IS spooled for the next approved call" 1 "$(find "$SPOOL" -name '*.json' | wc -l)"
rm -f "$TMP/status" "$SPOOL"/*.json

# ── 5. DIVE-6616: which key the box has decides the route ────────────────────
# 5a. the key file is ABSENT (a self-installed box): sent anyway, to the open
# route, with no Authorization header — never spooled for a key that cannot come.
rm -f "$TMP"/reqs/*
out=$(CONNECTORD_TOKEN="" FIVE_CONNECTORD_ENV="$TMP/none.env" cmd_bug --verb=task --exit=1 --what="no key" --no-probes --file --owner-approved </dev/null 2>&1)
chk "5a no key file: exits 0 (sent)" 0 "$?"
chk "5a one request reached the endpoint" 1 "$(nreq)"
chk "5a it went to the open route /bug-reports" "/bug-reports" "$(req 0 .path)"
chk "5a with no Authorization header" "null" "$(req 0 .auth)"
chk "5a the body is the same allowlist" \
  '["bash_version","exit_code","install_method","invocation","os","probes","verb","version","what"]' \
  "$(req 0 .body | jq -cS keys)"
[[ "$out" == *"bug report sent to 5dive"* ]] && ok_t "5a says sent" || fail_t "5a text: $out"
chk "5a nothing spooled" 0 "$(find "$SPOOL" -name '*.json' 2>/dev/null | wc -l)"

# 5b. no key file AND the open route is not there yet (an API older than this
# CLI): spooled, and the reason names the self-installed case, not access.
rm -f "$TMP"/reqs/*; echo 404 > "$TMP/status"
err=$(CONNECTORD_TOKEN="" FIVE_CONNECTORD_ENV="$TMP/none.env" cmd_bug --verb=task --exit=1 --what="no key, old api" --no-probes --file --owner-approved </dev/null 2>&1)
chk "5b no key file + 404: exits E_TIMEOUT (spooled)" "$E_TIMEOUT" "$?"
[[ "$err" == *"this box has no 5dive key (self-installed)"* ]] && ok_t "5b the self-installed case is named" || fail_t "5b text: $err"
[[ "$err" != *"cannot read"* ]] && ok_t "5b ...and it does not blame access" || fail_t "5b blames access: $err"
chk "5b one spool file" 1 "$(find "$SPOOL" -name '*.json' | wc -l)"

# 5c. the spool drains over the open route too, on the next approved send.
rm -f "$TMP/status" "$TMP"/reqs/*
out=$(CONNECTORD_TOKEN="" FIVE_CONNECTORD_ENV="$TMP/none.env" cmd_bug --verb=task --exit=1 --what="no key, api back" --no-probes --file --owner-approved </dev/null 2>&1)
chk "5c next approved send exits 0" 0 "$?"
chk "5c it sent itself plus the spooled one" 2 "$(nreq)"
chk "5c both over the open route" "/bug-reports|/bug-reports|" "$(for i in 0 1; do req "$i" .path; done | tr '\n' '|')"
chk "5c the spool is empty" 0 "$(find "$SPOOL" -name '*.json' | wc -l)"
[[ "$out" == *"also sent 1 saved earlier"* ]] && ok_t "5c the drain is reported" || fail_t "5c text: $out"

# 5d. DIVE-7248: the key file EXISTS but this seat cannot read it (every non-root
# seat on one of our boxes). It goes keyless, like a self-installed box, instead of
# a spool that same seat could never drain.
rm -f "$TMP"/reqs/*
printf 'CONNECTORD_TOKEN=fake-file-token-1111\n' > "$TMP/locked.env"; chmod 000 "$TMP/locked.env"
if [[ -r "$TMP/locked.env" ]]; then
  ok_t "5d SKIP: running as root, a 000 file is still readable"
else
  # 5d1. the open route is not there (an older API): spooled, and the reason is access.
  echo 404 > "$TMP/status"
  err=$(CONNECTORD_TOKEN="" FIVE_CONNECTORD_ENV="$TMP/locked.env" cmd_bug --verb=task --exit=1 --what="locked key, old api" --no-probes --file --owner-approved </dev/null 2>&1)
  chk "5d1 unreadable key + 404: exits E_TIMEOUT (spooled)" "$E_TIMEOUT" "$?"
  [[ "$err" == *"this seat cannot read the box's key ($TMP/locked.env), and 5dive's API could not take the report without it (HTTP 404)"* ]] \
    && ok_t "5d1 the access reason names the file and the status" || fail_t "5d1 text: $err"
  chk "5d1 it tried the open route" "/bug-reports" "$(req 0 .path)"
  chk "5d1 one spool file (the report chill-gorge's head was left with)" 1 "$(find "$SPOOL" -name '*.json' | wc -l)"
  # 5d2. the open route answers: sent, exit 0, and the spooled one goes with it.
  rm -f "$TMP/status" "$TMP"/reqs/*
  out=$(CONNECTORD_TOKEN="" FIVE_CONNECTORD_ENV="$TMP/locked.env" cmd_bug --verb=task --exit=1 --what="locked key" --no-probes --file --owner-approved </dev/null 2>&1)
  chk "5d2 unreadable key: exits 0 (sent)" 0 "$?"
  [[ "$out" == *"bug report sent to 5dive (report 42); also sent 1 saved earlier"* ]] && ok_t "5d2 says sent, with the id and the drain" || fail_t "5d2 text: $out"
  chk "5d2 it sent itself plus the spooled one" 2 "$(nreq)"
  chk "5d2 both over the open route" "/bug-reports|/bug-reports|" "$(for i in 0 1; do req "$i" .path; done | tr '\n' '|')"
  chk "5d2 with no Authorization header" "null|null|" "$(for i in 0 1; do req "$i" .auth; done | tr '\n' '|')"
  chk "5d2 the body is the same allowlist" \
    '["bash_version","exit_code","install_method","invocation","os","probes","verb","version","what"]' \
    "$(req 0 .body | jq -cS keys)"
  chk "5d2 the spool is empty" 0 "$(find "$SPOOL" -name '*.json' | wc -l)"
fi
chmod 600 "$TMP/locked.env"; rm -f "$TMP/status" "$SPOOL"/*.json

# 5e. NEGATIVE CONTROL for 5d: the key file is readable: the keyed route, unchanged.
rm -f "$TMP"/reqs/*
printf 'CONNECTORD_TOKEN="fake-file-token-2222"\n' > "$TMP/box.env"
( CONNECTORD_TOKEN="" FIVE_CONNECTORD_ENV="$TMP/box.env" cmd_bug --verb=task --exit=1 --what="readable key" --no-probes --file --owner-approved </dev/null ) >/dev/null 2>&1
chk "5e readable key: exits 0" 0 "$?"
chk "5e to /server/bug-reports" "/server/bug-reports" "$(req 0 .path)"
chk "5e with the file's key" "Bearer fake-file-token-2222" "$(req 0 .auth)"

# 5f. a key file that is there but holds no key: still not the open route.
rm -f "$TMP"/reqs/*
printf 'OTHER=1\n' > "$TMP/empty.env"
err=$(CONNECTORD_TOKEN="" FIVE_CONNECTORD_ENV="$TMP/empty.env" cmd_bug --verb=task --exit=1 --what="empty key file" --no-probes --file --owner-approved </dev/null 2>&1)
chk "5f key file with no key: exits E_TIMEOUT (spooled)" "$E_TIMEOUT" "$?"
[[ "$err" == *"holds no 5dive key"* ]] && ok_t "5f says the file holds no key" || fail_t "5f text: $err"
chk "5f nothing reached the endpoint" 0 "$(nreq)"
rm -f "$SPOOL"/*.json

# ── 6. never ask twice about one defect; at most one ask a day ────────────────
rm -f "$FIVE_BUG_ASKED_LEDGER" "$XDG_STATE_HOME/5dive/bug-asked.tsv"; rm -f "$TMP"/reqs/*
p1=$(cmd_bug --verb=doctor --exit=3 --what="probe x failed after 12s" --no-probes 2>&1)
[[ "$p1" == *"ask your owner in one line"* ]] && ok_t "first preview of a defect says to ask the owner" || fail_t "first preview: $p1"
p2=$(cmd_bug --verb=doctor --exit=3 --what="Probe X failed after 97s" --no-probes 2>&1)
today=$(date -u +%F)
[[ "$p2" == *"Your owner was already asked about this on ${today}; don't ask again"* ]] \
  && ok_t "the same defect (digits and case differ) prints the do-not-re-ask line with the date" \
  || fail_t "second preview: $p2"
p3=$(cmd_bug --verb=agent --exit=1 --what="a different defect" --no-probes 2>&1)
[[ "$p3" == *"already asked about a 5dive bug today; don't ask again today"* ]] \
  && ok_t "a second defect the same day is not asked (one ask per day)" || fail_t "third preview: $p3"
j=$(JSON_MODE=1 cmd_bug --verb=doctor --exit=3 --what="probe x failed after 1s" --no-probes 2>/dev/null)
chk "--json carries ask_owner:false and the date" "false $today" "$(jq -r '"\(.data.ask_owner) \(.data.owner_already_asked)"' <<<"$j")"
chk "previews sent nothing" 0 "$(nreq)"
chk "one ask recorded (repeats and same-day defects add none), box-wide when writable" 1 "$(wc -l < "$FIVE_BUG_ASKED_LEDGER")"
# Yesterday's ask for another defect does not block today's first ask.
printf 'ffffffffffffffff\t2026-01-01\tx\t1\n' > "$FIVE_BUG_ASKED_LEDGER"
p4=$(cmd_bug --verb=agent --exit=1 --what="a different defect" --no-probes 2>&1)
[[ "$p4" == *"ask your owner in one line"* ]] && ok_t "an old ask of another defect does not block a new day's ask" || fail_t "p4: $p4"
# A box-wide ledger this seat cannot write falls back to the seat's own.
rm -f "$XDG_STATE_HOME/5dive/bug-asked.tsv"
( FIVE_BUG_ASKED_LEDGER="$TMP/no-such-dir/x.tsv" cmd_bug --verb=gh --exit=9 --what="fallback" --no-probes ) >/dev/null 2>&1
chk "unwritable box ledger -> the ask lands in the seat ledger" 1 "$(wc -l < "$XDG_STATE_HOME/5dive/bug-asked.tsv")"

# ── 7. a token-shaped --what is still refused, approved or not ────────────────
rm -f "$TMP"/reqs/*
( cmd_bug --verb=agent --exit=1 --what="broke with ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" --no-probes --file --owner-approved </dev/null ) >/dev/null 2>&1
chk "a token-shaped --what is refused (E_USAGE)" "$E_USAGE" "$?"
chk "...and nothing reached the endpoint" 0 "$(nreq)"

# ── 9. DIVE-9000: a self-installed box hears back ─────────────────────────────
LEDGER="$XDG_STATE_HOME/5dive/bug-replies.tsv"
TOK=$(printf 'ab%.0s' $(seq 32))
rm -f "$LEDGER" "$TMP"/reqs/*
out=$(CONNECTORD_TOKEN="" FIVE_CONNECTORD_ENV="$TMP/none.env" cmd_bug --verb=task --exit=1 --what="hear back" --no-probes --file --owner-approved </dev/null 2>&1)
chk "9a keyless filing exits 0" 0 "$?"
chk "9a the ledger holds the id and the token" "42 $TOK" "$(cut -f1,2 "$LEDGER" | tr '\t' ' ')"
chk "9a ...and is 0600" 600 "$(stat -c %a "$LEDGER")"
[[ "$out" == *"5dive's answer will come back to this box's lead agent"* ]] && ok_t "9a the caller is told the answer comes back" || fail_t "9a text: $out"
( CONNECTORD_TOKEN="" FIVE_CONNECTORD_ENV="$TMP/box.env" cmd_bug --verb=task --exit=1 --what="keyed" --no-probes --file --owner-approved </dev/null ) >/dev/null 2>&1
chk "9a a keyed report (answered to its owner) adds no entry" 1 "$(wc -l < "$LEDGER")"

# The poll, as the tick runs it: the seat's ledger under a fake home, a stubbed
# lead and a recorded send.
mkdir -p "$TMP/home1/.local/state/5dive" "$TMP/sd"
mv "$LEDGER" "$TMP/home1/.local/state/5dive/bug-replies.tsv"
L1="$TMP/home1/.local/state/5dive/bug-replies.tsv"
export FIVE_BUG_REPLIES_HOMES="$TMP/home1" STATE_DIR="$TMP/sd"
SENDS="$TMP/sends"; : > "$SENDS"; SEND_OK=1
_hb_escalation_recipient() { printf 'lead'; }
cmd_send() { (( SEND_OK )) || return 1; local m=""; for a in "$@"; do [[ "$a" == --message=* ]] && m="${a#--message=}"; done
  printf '%s|%s|%s\n' "$1" "$(printf '%s ' "$@" | grep -o -- '--from=[^ ]*')" "${m%%$'\n'*}" >> "$SENDS"; }
ngets() { find "$TMP/gets" -type f | wc -l; }
NOW=$(date +%s)

printf '{"notices":[{"kind":"update","text":"We found it: the spool path was wrong.","at":"2026-11-21T10:00:00Z"}]}' > "$TMP/replies/42"
_bug_replies_sweep "$NOW" 2>/dev/null
chk "9b one GET to the report's replies" "/bug-reports/42/replies" "$(jq -r .path "$TMP/gets/000.json")"
chk "9b the token rides in X-Reply-Token, not the URL" "$TOK" "$(jq -r .token "$TMP/gets/000.json")"
chk "9b the lead got it once, in plain words, from 5dive-support" \
  "lead|--from=5dive-support|5dive replied to your bug report 42: We found it: the spool path was wrong." "$(cat "$SENDS")"
chk "9b an update keeps the entry open" 1 "$(wc -l < "$L1")"

_bug_replies_sweep "$((NOW + 600))" 2>/dev/null
chk "9c the same day asks nothing more" 1 "$(ngets)"

printf '{"notices":[{"kind":"fixed","text":"Fixed in 0.130.","at":"2026-11-22T10:00:00Z"}]}' > "$TMP/replies/42"
_bug_replies_sweep "$((NOW + 86400))" 2>/dev/null
chk "9d the next day: the fixed notice reaches the lead" 2 "$(wc -l < "$SENDS")"
[[ "$(tail -n1 "$SENDS")" == *"report 42: Fixed in 0.130."* ]] && ok_t "9d ...with our text" || fail_t "9d send: $(tail -n1 "$SENDS")"
chk "9d ...and the entry is dropped after fixed" 0 "$(grep -c . "$L1")"

# 9e. a send that fails is kept and retried on the next tick, not lost.
: > "$SENDS"; printf '43\t%s\t%s\n' "$TOK" "$NOW" > "$L1"
printf '{"notices":[{"kind":"update","text":"Looking.","at":"2026-11-23T10:00:00Z"}]}' > "$TMP/replies/43"
SEND_OK=0; _bug_replies_sweep "$((NOW + 2*86400))" 2>/dev/null
chk "9e the failed send is kept in the pending file" 1 "$(wc -l < "$TMP/sd/bug-replies-pending.jsonl")"
SEND_OK=1; _bug_replies_sweep "$((NOW + 2*86400 + 300))" 2>/dev/null
chk "9e the next tick delivers it" "lead|--from=5dive-support|5dive replied to your bug report 43: Looking." "$(cat "$SENDS")"
chk "9e ...and the pending file is empty" 0 "$(cat "$TMP/sd/bug-replies-pending.jsonl" 2>/dev/null | grep -c .)"

# 9f. 30 days old: dropped unasked. A 404: dropped. A 503: kept, retried within the hour.
D=$((NOW + 3*86400)); rm -f "$TMP"/gets/*
printf '44\t%s\t%s\n45\t%s\t%s\n' "$TOK" "$((D - 31*86400))" "$TOK" "$D" > "$L1"
echo 404 > "$TMP/getstatus"; _bug_replies_sweep "$D" 2>/dev/null
chk "9f only the young entry was asked" "/bug-reports/45/replies" "$(jq -r .path "$TMP/gets/000.json")"
chk "9f both are dropped (30 days, 404)" 0 "$(grep -c . "$L1")"
printf '46\t%s\t%s\n' "$TOK" "$D" > "$L1"; echo 503 > "$TMP/getstatus"
_bug_replies_sweep "$((D + 86400))" 2>/dev/null
chk "9f a 503 keeps the entry" 1 "$(grep -c . "$L1")"
rm -f "$TMP/getstatus"; n=$(ngets)
_bug_replies_sweep "$((D + 86400 + 3600))" 2>/dev/null
chk "9f ...and it is asked again an hour later, not a day" "$((n + 1))" "$(ngets)"
unset FIVE_BUG_REPLIES_HOMES

# ── 8. negative control: no GitHub route is left ──────────────────────────────
chk "no 'gh issue create' left in cmd_bug.sh" 0 "$(grep -c 'gh issue create' src/cmd_bug.sh)"
chk "no cmd_gh call left in cmd_bug.sh" 0 "$(grep -vE '^[[:space:]]*#' src/cmd_bug.sh | grep -c 'cmd_gh')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
