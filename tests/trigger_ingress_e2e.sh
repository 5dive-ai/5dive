#!/usr/bin/env bash
# DIVE-3931 acceptance harness: signed GitHub + generic webhook -> ordinary task.
# No root, no external network, no live board. The built single-file artifact is
# the subject, and every state write is confined to a throwaway STATE_DIR.
set -uo pipefail
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null; echo "HARNESS-RC=$rc"' EXIT

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

P=0 F=0 S=0
chk(){ if [[ "$2" == "$3" ]]; then P=$((P+1)); else F=$((F+1)); printf 'FAIL: %s (want=%s got=%s)\n' "$1" "$2" "$3"; fi; }
summary(){ printf 'PASS=%s FAIL=%s SKIP=%s\n' "$P" "$F" "$S"; }
bail(){ S=$((S+1)); printf 'SKIP: %s\n' "$1"; summary; exit 0; }
for b in python3 jq sqlite3 flock install; do command -v "$b" >/dev/null 2>&1 || bail "$b unavailable"; done

TMP="$(mktemp -d /tmp/trigger-ingress.XXXXXX)"
FIVE="$TMP/5dive"
BUILD_OUT="$FIVE" bash build.sh >/dev/null 2>&1 || bail "could not build 5dive"
export STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR/tasks"
"$FIVE" ui --data >/dev/null 2>&1 || bail "could not initialize isolated task store"
DB="$STATE_DIR/tasks/tasks.db"
sq(){ sqlite3 "$DB" "$1"; }

sq "INSERT INTO agents_org(name,role,title) VALUES
  ('alpha','engineering','Alpha engineer'),('beta','verifier','Beta verifier');"

SECRET='0123456789abcdef0123456789abcdef'
printf '%s\n' "$SECRET" | "$FIVE" trigger add github --name=issues --event=issues.labeled \
  --repo=acme/app --assignee=alpha --where='label.name == "5dive"' \
  --secret-from-stdin --json > "$TMP/add.json" 2>"$TMP/add.err"
chk "github trigger configured" true "$(jq -r '.ok' "$TMP/add.json")"
chk "secret is owner-only" 600 "$(stat -c %a "$STATE_DIR/triggers/secrets/issues.secret")"

# The task DB is group-readable/writable by design, so a secret_ref field must
# never be trusted as a root file-write target during rotation.
sq "UPDATE event_triggers SET secret_ref='$TMP/escape-target' WHERE name='issues';"
printf '%s\n' "$SECRET" | "$FIVE" trigger rotate issues --secret-from-stdin --json >/dev/null
chk "database cannot redirect secret rotation" 0 "$([[ -e "$TMP/escape-target" ]] && echo 1 || echo 0)"
chk "rotation uses slug-derived root-side path" "$SECRET" "$(<"$STATE_DIR/triggers/secrets/issues.secret")"

printf '%s' '{"action":"labeled","repository":{"full_name":"acme/app"},"sender":{"login":"octocat"},"label":{"name":"5dive"},"issue":{"number":7,"title":"Fix the thing"}}' > "$TMP/github.json"
sign(){ python3 - "$1" "$SECRET" <<'PY'
import hashlib,hmac,sys
print("sha256="+hmac.new(sys.argv[2].encode(),open(sys.argv[1],"rb").read(),hashlib.sha256).hexdigest())
PY
}
SIG="$(sign "$TMP/github.json")"

"$FIVE" trigger receive issues --payload-file="$TMP/github.json" --signature="$SIG" \
  --delivery-id=gh-1 --event=issues --json > "$TMP/first.json" 2>"$TMP/first.err"
TASK="$(jq -r '.data.task' "$TMP/first.json")"
chk "valid GitHub delivery accepted" accepted "$(jq -r '.data.outcome' "$TMP/first.json")"
chk "one task materialized" 1 "$(sq 'SELECT COUNT(*) FROM tasks;')"
chk "trigger-created task has an honest principal" trigger "$(sq "SELECT created_by FROM tasks WHERE ident='$TASK';")"
chk "task link recorded" "$TASK" "$(sq "SELECT t.ident FROM event_deliveries d JOIN tasks t ON t.id=d.task_id WHERE d.source_delivery_id='gh-1';")"
chk "raw authenticated payload stored 0600" 600 "$(stat -c %a "$STATE_DIR/triggers/payloads/1.json")"

"$FIVE" trigger receive issues --payload-file="$TMP/github.json" --signature="$SIG" \
  --delivery-id=gh-1 --event=issues --json > "$TMP/dupe.json" 2>"$TMP/dupe.err"
chk "redelivery is duplicate" duplicate "$(jq -r '.data.outcome' "$TMP/dupe.json")"
chk "redelivery creates no second task" 1 "$(sq 'SELECT COUNT(*) FROM tasks;')"
chk "duplicate attempt audited" 2 "$(sq 'SELECT COUNT(*) FROM event_delivery_attempts WHERE delivery_id=1;')"

# An existing delivery id is not an authentication shortcut, and even a valid
# signer cannot quietly reuse it for different bytes.
set +e
"$FIVE" trigger receive issues --payload-file="$TMP/github.json" --signature=sha256=bad \
  --delivery-id=gh-1 --event=issues --json > "$TMP/bad-redelivery.json" 2>"$TMP/bad-redelivery.err"
BAD_REDELIVERY_RC=$?
set -e
chk "bad-signature redelivery is rejected" 6 "$BAD_REDELIVERY_RC"
chk "bad redelivery preserves accepted fact" accepted "$(sq 'SELECT outcome FROM event_deliveries WHERE id=1;')"

printf '%s' '{"action":"labeled","repository":{"full_name":"acme/app"},"sender":{"login":"octocat"},"label":{"name":"5dive"},"issue":{"number":8,"title":"Different bytes"}}' > "$TMP/collision.json"
COLLISION_SIG="$(sign "$TMP/collision.json")"
set +e
"$FIVE" trigger receive issues --payload-file="$TMP/collision.json" --signature="$COLLISION_SIG" \
  --delivery-id=gh-1 --event=issues --json > "$TMP/collision.out" 2>"$TMP/collision.err"
COLLISION_RC=$?
set -e
chk "delivery-id payload collision is conflict" 5 "$COLLISION_RC"
chk "rejected redeliveries create no task" 1 "$(sq 'SELECT COUNT(*) FROM tasks;')"

# Invalid HMAC over deliberately invalid JSON proves the reject path does not
# parse into work: it returns auth_required, records invalid_signature, stores
# no payload, and leaves task count unchanged.
printf '%s' '{not-json' > "$TMP/untrusted.bin"
set +e
"$FIVE" trigger receive issues --payload-file="$TMP/untrusted.bin" --signature=sha256=bad \
  --delivery-id=gh-bad --event=issues --json > "$TMP/bad.json" 2>"$TMP/bad.err"
BAD_RC=$?
set -e
chk "invalid HMAC is auth failure" 6 "$BAD_RC"
chk "invalid HMAC recorded" invalid_signature "$(sq "SELECT outcome FROM event_deliveries WHERE source_delivery_id='gh-bad';")"
chk "invalid HMAC payload not stored" 0 "$(sq "SELECT payload_path IS NOT NULL FROM event_deliveries WHERE source_delivery_id='gh-bad';")"
chk "invalid HMAC creates no task" 1 "$(sq 'SELECT COUNT(*) FROM tasks;')"

"$FIVE" trigger receive issues --payload-file="$TMP/github.json" --signature="$SIG" \
  --delivery-id=gh-disallowed --event=pull_request --json > "$TMP/ignored.json" 2>"$TMP/ignored.err"
chk "disallowed event is ignored" ignored "$(jq -r '.data.outcome' "$TMP/ignored.json")"
chk "ignored event creates no task" 1 "$(sq 'SELECT COUNT(*) FROM tasks;')"

# A new process sees the durable task and normal queue verbs can advance it
# through the existing maker->verifier rail.
chk "new process sees task" "$TASK" "$("$FIVE" task show "$TASK" --json | jq -r '.data.task.ident')"
"$FIVE" task start "$TASK" --json >/dev/null
"$FIVE" task "done" "$TASK" --result='fixture delivery checked' --json >/dev/null
chk "ordinary verifier handoff applies" beta "$(sq "SELECT assignee FROM tasks WHERE ident='$TASK';")"
chk "ordinary task remains standard" standard "$(sq "SELECT kind FROM tasks WHERE ident='$TASK';")"

"$FIVE" trigger replay 1 --json > "$TMP/replay.json" 2>"$TMP/replay.err"
chk "replay reuses original task" "$TASK" "$(jq -r '.data.task' "$TMP/replay.json")"
chk "replay creates no second task" 1 "$(sq 'SELECT COUNT(*) FROM tasks;')"
chk "replay count durable" 1 "$(sq 'SELECT replay_count FROM event_deliveries WHERE id=1;')"
chk "replay attempt audited" replay "$(sq 'SELECT attempt_kind FROM event_delivery_attempts WHERE delivery_id=1 ORDER BY id DESC LIMIT 1;')"

# Rotation must not let replay mint a fresh signature for old bytes. The failed
# replay is an append-only attempt and cannot rewrite the original accepted fact.
NEW_SECRET='fedcba9876543210fedcba9876543210'
printf '%s\n' "$NEW_SECRET" | "$FIVE" trigger rotate issues --secret-from-stdin --json >/dev/null
set +e
"$FIVE" trigger replay 1 --json > "$TMP/rotated-replay.json" 2>"$TMP/rotated-replay.err"
ROTATE_RC=$?
set -e
chk "rotated secret rejects old replay" 6 "$ROTATE_RC"
chk "failed replay preserves original outcome" accepted "$(sq 'SELECT outcome FROM event_deliveries WHERE id=1;')"
chk "failed replay attempt says invalid signature" invalid_signature "$(sq 'SELECT outcome FROM event_delivery_attempts WHERE delivery_id=1 ORDER BY id DESC LIMIT 1;')"
chk "failed replay creates no task" 1 "$(sq 'SELECT COUNT(*) FROM tasks;')"
printf '%s\n' "$SECRET" | "$FIVE" trigger rotate issues --secret-from-stdin --json >/dev/null

# Simulate a receiver dying after the dedupe row committed but before task
# creation. A redelivery resumes outcome=processing and materializes once.
GH_SHA="$(python3 - "$TMP/github.json" <<'PY'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())
PY
)"
sq "INSERT INTO event_deliveries(trigger_id,source_delivery_id,event_header,signature_status,signature,dedupe_key,materialization_key,payload_sha256,outcome)
    VALUES(1,'gh-crash','issues','valid','$SIG','gh-crash','crash-recovery-key','$GH_SHA','processing');"
"$FIVE" trigger receive issues --payload-file="$TMP/github.json" --signature="$SIG" \
  --delivery-id=gh-crash --event=issues --json > "$TMP/crash-resume.json"
chk "restart resumes processing delivery" accepted "$(jq -r '.data.outcome' "$TMP/crash-resume.json")"
chk "restart creates exactly one recovered task" 1 "$(sq "SELECT COUNT(*) FROM event_deliveries d JOIN tasks t ON t.id=d.task_id WHERE d.source_delivery_id='gh-crash';")"

# Generic signed source plus max-pending backpressure.
printf '%s\n' "$SECRET" | "$FIVE" trigger add webhook --name=payments --event=payment.failed \
  --assignee=alpha --max-pending=1 --secret-from-stdin --json >/dev/null
printf '%s' '{"actor":"billing","customer":"example"}' > "$TMP/generic.json"
GSIG="$(sign "$TMP/generic.json")"
"$FIVE" trigger receive payments --payload-file="$TMP/generic.json" --signature="$GSIG" \
  --delivery-id=pay-1 --event=payment.failed --json > "$TMP/pay1.json"
"$FIVE" trigger receive payments --payload-file="$TMP/generic.json" --signature="$GSIG" \
  --delivery-id=pay-2 --event=payment.failed --json > "$TMP/pay2.json"
chk "generic signed webhook accepted" accepted "$(jq -r '.data.outcome' "$TMP/pay1.json")"
chk "backpressure parks excess" parked "$(jq -r '.data.outcome' "$TMP/pay2.json")"

# Exercise the actual HTTP receiver, not only its inner command.
PORT="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)"
"$FIVE" trigger serve --listen="127.0.0.1:$PORT" --once >"$TMP/server.out" 2>"$TMP/server.err" &
SRV_PID=$!
python3 - "$PORT" "$TMP/github.json" "$SIG" <<'PY' > "$TMP/http.status"
import sys,time,urllib.request
port,path,sig=sys.argv[1:]
for _ in range(40):
    try:
        req=urllib.request.Request("http://127.0.0.1:%s/hooks/issues"%port,data=open(path,"rb").read(),method="POST",
          headers={"Content-Type":"application/json","X-Hub-Signature-256":sig,"X-GitHub-Delivery":"gh-http","X-GitHub-Event":"issues"})
        with urllib.request.urlopen(req,timeout=3) as r:
            print(r.status); print(r.read().decode()); break
    except Exception:
        time.sleep(.05)
else:
    print(0); print("no response")
PY
wait "$SRV_PID"; SRV_PID=""
chk "HTTP receiver returns accepted" 202 "$(head -1 "$TMP/http.status")"
chk "HTTP receiver materialized a task" accepted "$(tail -n +2 "$TMP/http.status" | jq -r '.data.outcome')"

# A caller without a valid signature must not be able to enumerate configured
# trigger slugs. Both a missing slug and a registered slug with a bad signature
# return the same status and generic body at the HTTP boundary.
"$FIVE" trigger serve --listen="127.0.0.1:$PORT" >"$TMP/server-enum.out" 2>"$TMP/server-enum.err" &
SRV_PID=$!
python3 - "$PORT" "$TMP/github.json" <<'PY' > "$TMP/http-enum.json"
import json, sys, time, urllib.error, urllib.request
port, path = sys.argv[1:]
raw = open(path, "rb").read()
results = []
for _ in range(40):
    try:
        urllib.request.urlopen("http://127.0.0.1:%s/healthz" % port, timeout=1).read()
        break
    except Exception:
        time.sleep(.05)
for name in ("missing", "issues"):
    req = urllib.request.Request("http://127.0.0.1:%s/hooks/%s" % (port, name), data=raw, method="POST",
        headers={"Content-Type":"application/json", "X-Hub-Signature-256":"sha256=bad",
                 "X-GitHub-Delivery":"gh-enum-"+name, "X-GitHub-Event":"issues"})
    try:
        with urllib.request.urlopen(req, timeout=3) as response:
            results.append({"status": response.status, "body": response.read().decode()})
    except urllib.error.HTTPError as error:
        results.append({"status": error.code, "body": error.read().decode()})
print(json.dumps(results))
PY
kill "$SRV_PID" 2>/dev/null || true
wait "$SRV_PID" 2>/dev/null || true
SRV_PID=""
chk "unknown trigger is hidden behind not found" 404 "$(jq -r '.[0].status' "$TMP/http-enum.json")"
chk "bad signature does not reveal registered trigger" 404 "$(jq -r '.[1].status' "$TMP/http-enum.json")"
chk "enumeration responses are indistinguishable" "$(jq -r '.[0].body' "$TMP/http-enum.json")" "$(jq -r '.[1].body' "$TMP/http-enum.json")"

UI="$("$FIVE" ui --data)"
chk "dashboard lists trigger" 1 "$(jq -r '[.data.triggers[]|select(.name=="issues")]|length' <<<"$UI")"
chk "dashboard delivery links to task" "$TASK" "$(jq -r '.data.deliveries[]|select(.id==1).task' <<<"$UI")"
HTML="$("$FIVE" ui --html)"
chk "dashboard has trigger detail view" 1 "$(grep -c 'id="view-triggers"' <<<"$HTML")"
chk "dashboard renders delivery-to-task link" 1 "$(grep -c 'link.href = "#queue"' <<<"$HTML")"

summary
(( F == 0 ))
