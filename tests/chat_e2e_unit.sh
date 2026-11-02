#!/usr/bin/env bash
# DIVE-6878: encrypted 5dive.app chat on a self-hosted server, the root side
# (src/cmd_chat.sh), against a fake key directory and REAL crypto on bun.
#   * the grant: one exact-path `_chat_e2e` line, no wildcard, still cli-scoped
#     with no extra entries; both classifiers, main.sh, build.sh and the builtin
#     verbs know it; the envelope is byte-identical to the plugin's e2e.ts
#   * enable <secret>: keys wait in <dir>.pairing/ (0700, files 0600); nothing is
#     published and the plugin's switch (<dir>) stays off until a device pairs
#   * sync: the device whose proof verifies under the secret is paired (box key
#     + its proof up FIRST, then <dir> goes live, then the approval, the secret
#     deleted, the sealed device list posted); a device with a proof under any
#     other secret is not
#   * the seat's rail: open, seal (root writes the type), seal-file, the id
#     rules; an approved device's `approve` message changes the list, the API
#     mirror gets it and the seat never sees the mirror note
#   * devices approve <code> / revoke <code>, sync drops what the API dropped
#   * THE SECRET never appears in any process's argv (curl, jq, bun), any curl
#     stdin or body, any output, the audit log or any file left on disk; a
#     control runs the same check on a leaky shape and sees it red
# Isolation: src/ sourced, curl is a fake API on PATH. Needs bun.
# Run: bash tests/chat_e2e_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/chat-e2e.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
REAL_BUN=$(command -v bun) || { echo "FAIL bun is required" >&2; exit 1; }
REAL_JQ=$(command -v jq)
export STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
  lib/state.sh lib/audit.sh lib/registry.sh lib/actor.sh cmd_agent_create.sh cmd_dashboard_relay.sh cmd_chat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
P=0; F=0
ok(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL %s\n' "$1" >&2; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ── the grant and the wiring ─────────────────────────────────────────────────
SUD=$(render_standard_sudoers agent-tap 0 0)
check 'exact-path _chat_e2e grant is rendered once' \
  '[[ $(grep -cE "^agent-tap ALL=\(root\) NOPASSWD: /usr/local/bin/5dive _chat_e2e$" <<<"$SUD") == 1 ]]'
check 'the grant has no wildcard' '[[ $(grep -v "^#" <<<"$SUD" | grep _chat_e2e) != *"*"* ]]'
check 'rendered standard grant still classifies cli-scoped, extra=0' '[[ "$(classify_sudo_grant <<<"$SUD")" == "cli-scoped|root|0" ]]'
check 'python agent-list classifier knows the verb' 'grep -qF "command == \"/usr/local/bin/5dive _chat_e2e\"" "$SRC/cmd_agent.sh"'
check 'main.sh dispatches _chat_e2e and chat' \
  'grep -A7 "^    _chat_e2e)" "$SRC/main.sh" | grep -q "cmd_chat_e2e_root \"\$@\"" && grep -A9 "^    chat)" "$SRC/main.sh" | grep -q "cmd_chat \"\$@\""'
check 'chat e2e enable is audited with NO arguments' \
  'grep -A6 "^    chat)" "$SRC/main.sh" | grep -qF "AUDIT_CMD=\"chat e2e enable\"; AUDIT_ARGS=();"'
check 'build.sh bundles the module' 'grep -qx "  src/cmd_chat.sh" build.sh'
check 'both verbs are builtin (no plugin may shadow them)' 'grep -q " chat _chat_e2e " "$SRC/cmd_plugin.sh"'
# dashboard@5dive-plugins 0.5.16 plugins/dashboard/e2e.ts (DIVE-6876): one envelope, two copies.
check 'the envelope is byte-identical to the plugin e2e.ts' \
  '[[ "$(_chat_e2e_envelope_ts | sha256sum | cut -d" " -f1)" == f16852df7ab1bacc0186b8cc3680ff2b95f0e4b6186fe6e4ca7a3f97377af720 ]]'

# ── the fake world ───────────────────────────────────────────────────────────
SECRET=$("$REAL_BUN" -e 'const b=crypto.getRandomValues(new Uint8Array(32));process.stdout.write(Buffer.from(b).toString("base64url"))')
OTHER=$("$REAL_BUN" -e 'const b=crypto.getRandomValues(new Uint8Array(32));process.stdout.write(Buffer.from(b).toString("base64url"))')
export FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env" FIVE_API_BASE="https://cp.example.test"
export FIVEDIVE_CHAT_E2E_DIR="$TMP/etc/chat-e2e" FIVEDIVE_CHAT_E2E_LIB="$TMP/lib/chat-e2e"
LIVE="$FIVEDIVE_CHAT_E2E_DIR"; PAIR="$LIVE.pairing"
mkdir -p "$TMP/tmpd" "$TMP/bin" "$TMP/etc"; export TMPDIR="$TMP/tmpd"
printf '{"agents":{"tap":{"channels":"telegram,dashboard"},"quiet":{"channels":"telegram"}}}' >"$STATE_DIR/agents.json"
export AUDIT_LOG="$TMP/audit.log"
LOGS="$TMP/logs"; mkdir -p "$LOGS"; export LOGS
export DEVICES="$TMP/api-devices.json"; echo '[]' >"$DEVICES"
# curl: the key directory. argv one per line, stdin verbatim, the body file read at call time.
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" prev="" url="" method=GET
for a in "$@"; do
  [[ "$prev" == -o ]] && out="$a"
  [[ "$prev" == -X ]] && method="$a"
  [[ "$prev" == --data-binary && "$a" == @* ]] && { cat -- "${a#@}" >>"$LOGS/bodies"; echo >>"$LOGS/bodies"; }
  prev="$a"; url="$a"
done
printf '%s\n' "$@" >>"$LOGS/curl.argv"; printf -- '--\n' >>"$LOGS/curl.argv"
cat >>"$LOGS/curl.stdin"
printf '%s %s\n' "$method" "${url#https://cp.example.test}" >>"$LOGS/calls"
case "$method ${url#https://cp.example.test}" in
  "GET /server/chat-e2e/box/devices") jq -c '{devices: .}' "$DEVICES" >"$out" ;;
  *) printf '{"ok":true}' >"$out" ;;
esac
printf 200
STUB
# jq and bun: log every argv, then run the real one.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$LOGS/jq.argv"\nexec %q "$@"\n' "$REAL_JQ" >"$TMP/bin/jq"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$LOGS/bun.argv"\nexec %q "$@"\n' "$REAL_BUN" >"$TMP/bin/bun"
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" FIVEDIVE_CHAT_E2E_BUN="$TMP/bin/bun"
MYUID=$(id -u)
_gate_uid_to_agent(){ case "$1" in 1042|"$MYUID") printf 'tap' ;; *) printf '' ;; esac; }
_gate_is_root(){ [[ -z "${NOT_ROOT:-}" ]]; }
# A browser or phone: its own key, its pairing proof, sealing and opening (secret from the env).
cat >"$TMP/dev.ts" <<'TS'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
const E = await import(process.env.ENV_TS!)
const [cmd, name, ...rest] = process.argv.slice(2)
const file = `${process.env.DEVDIR}/${name}.jwk`
const P = { name: 'ECDH', namedCurve: 'P-256' } as const
const stdin = async () => new Response(Bun.stdin.stream()).text()
const me = async () => crypto.subtle.importKey('jwk', JSON.parse(readFileSync(file, 'utf8')), P, false, ['deriveBits'])
const pubOf = () => { const j = JSON.parse(readFileSync(`${file}.pub`, 'utf8')); return j }
if (cmd === 'new') {
  const kp = await E.newIdentity(true)
  writeFileSync(file, JSON.stringify(await crypto.subtle.exportKey('jwk', kp.privateKey)))
  const pub = await E.exportPublic(kp.publicKey)
  writeFileSync(`${file}.pub`, JSON.stringify(pub))
  const s = process.env.DEV_SECRET
  console.log(JSON.stringify({ device: name, pub, proof: s ? await E.pairProof(s, 'device', 'box', pub) : null, approvedAt: null, createdAt: '2026-10-31T00:00:00.000Z' }))
} else if (cmd === 'pub') console.log(pubOf())
else if (cmd === 'fp') console.log(await E.fingerprint(pubOf()))
else if (cmd === 'seal') {
  const [conv, m, boxPub] = rest
  console.log(JSON.stringify(await E.seal({ senderId: name, senderPriv: await me(), recipients: [{ id: 'box', pub: await E.importPublic(boxPub) }], conv, msgId: m, dir: 'in', plaintext: await stdin() })))
} else if (cmd === 'open') {
  const [conv, boxPub] = rest
  const env = JSON.parse(await stdin())
  console.log(await E.openText({ env, myId: name, myPriv: await me(), senderPub: await E.importPublic(boxPub), expect: { conv, dir: 'out' } }))
} else if (cmd === 'verify-box') {
  const [pub, proof] = rest
  console.log(await E.pairVerify(process.env.DEV_SECRET!, 'box', 'box', pub, proof))
}
TS
export DEVDIR="$TMP/devs" ENV_TS="$FIVEDIVE_CHAT_E2E_LIB/chat-e2e-envelope.ts"; mkdir -p "$DEVDIR"
dev(){ "$REAL_BUN" "$TMP/dev.ts" "$@"; }
run(){ ( "$@" ) >"$TMP/out" 2>"$TMP/err"; }
calls(){ cat "$LOGS/calls" 2>/dev/null; }
: >"$LOGS/calls"

# ── enable ───────────────────────────────────────────────────────────────────
NOT_ROOT=1 run _chat_cmd_e2e enable "$SECRET"; check 'enable as non-root is refused' '[[ $? == "$E_PERMISSION" ]]'
run _chat_cmd_e2e enable "$SECRET"; rc=$?
check 'enable before the link is refused, with no network call' '[[ $rc == "$E_AUTH_REQUIRED" && ! -s "$LOGS/calls" && ! -e "$PAIR" ]]'
printf 'CONNECTORD_TOKEN=tok-one\n' >"$FIVEDIVE_CONNECTORD_ENV"
run _chat_cmd_e2e enable not-a-secret; check 'a malformed secret is refused' '[[ $? == "$E_VALIDATION" && ! -e "$PAIR" ]]'
chmod 0755 "$TMP/etc"   # the parent as the installer leaves /etc/5dive
# The heal is stubbed for this one call (it runs inside enable's sync and would
# hide a regression in enable itself); its own arms are below.
enable_noheal(){ _chat_e2e_heal_parent(){ :; }; _chat_cmd_e2e enable -; }
printf '%s\n' "$SECRET" | run enable_noheal; rc=$?
check 'DIVE-7440: enable leaves the PARENT at 0755 (seats must still see the key dir)' '[[ "$(stat -c %a "$TMP/etc")" == 755 ]]'
check 'enable - (secret on stdin) makes the pairing dir' '[[ $rc == 0 && -d "$PAIR" && "$(stat -c %a "$PAIR")" == 700 ]]'
check 'box key, proof and secret are 0600 files' \
  '[[ "$(stat -c %a "$PAIR/box.jwk") $(stat -c %a "$PAIR/box.proof") $(stat -c %a "$PAIR/pair.secret")" == "600 600 600" ]]'
check 'nothing is turned on before a device pairs: no live dir, no box key published' \
  '[[ ! -e "$LIVE" ]] && ! grep -q "PUT" "$LOGS/calls"'
check 'enable says what to do next' 'grep -q "turns on when the browser that asked for it pairs" "$TMP/out"'

# ── sync pairs the first device whose proof verifies ─────────────────────────
DEV_SECRET="$SECRET" dev new dev-laptop1 >"$TMP/laptop.json"
DEV_SECRET="$OTHER" dev new dev-evil0001 >"$TMP/evil.json"
jq -s '.' "$TMP/evil.json" "$TMP/laptop.json" >"$DEVICES"
: >"$LOGS/calls"; : >"$LOGS/bodies"
run _chat_cmd_devices sync; rc=$?
check 'sync pairs the laptop' '[[ $rc == 0 && -d "$LIVE" && ! -e "$PAIR" ]] && grep -q "POST /server/chat-e2e/box/devices/dev-laptop1/approve" "$LOGS/calls"'
check 'a device whose proof is under another secret is not paired' '! grep -q dev-evil0001 "$LOGS/calls"'
check 'the box key goes up before the approval' \
  '[[ "$(grep -n "PUT /server/chat-e2e/box/key" "$LOGS/calls" | cut -d: -f1)" -lt "$(grep -m1 -n "dev-laptop1/approve" "$LOGS/calls" | cut -d: -f1)" ]]'
BOXPUB=$(grep -m1 '"proof"' "$LOGS/bodies" | jq -r .pub); BOXPROOF=$(grep -m1 '"proof"' "$LOGS/bodies" | jq -r .proof)
check 'the published proof verifies under the secret (the browser can check the key)' '[[ "$(DEV_SECRET="$SECRET" dev verify-box x "$BOXPUB" "$BOXPROOF")" == true ]]'
check 'the secret is deleted once a device paired' '[[ ! -e "$LIVE/pair.secret" ]]'
ROSTER_POST=$(grep '"agent":"tap"' "$LOGS/bodies" | tail -1)
check 'the device list is posted to the dashboard agent only, marked e2e' \
  '[[ -n "$ROSTER_POST" ]] && [[ "$(jq -r .metadata.e2e.v <<<"$ROSTER_POST")" == 1 ]] && ! grep -q "\"agent\":\"quiet\"" "$LOGS/bodies"'
check 'the laptop opens the posted list and finds itself on it' \
  '[[ "$(jq -r .body <<<"$ROSTER_POST" | dev open dev-laptop1 dashboard "$BOXPUB" | jq -r "[.t, (.devices|map(.id)|join(\",\"))]|join(\" \")")" == "roster dev-laptop1" ]]'
run _chat_cmd_e2e status; check 'status says on, one device' 'grep -q "on, 1 device" "$TMP/out"'

# ── the seat's rail ──────────────────────────────────────────────────────────
rail(){ ( export SUDO_UID="${UID_:-1042}"; printf '%s' "$1" | cmd_chat_e2e_root ) >"$TMP/out" 2>"$TMP/err"; }
ENV1=$(printf '{"t":"msg","text":"hello box"}' | dev seal dev-laptop1 dashboard c-1 "$BOXPUB")
rail "$(jq -nc --argjson e "$ENV1" '{op:"open", kind:"msg", conv:"dashboard", env:$e}')"; rc=$?
check 'open: the box reads the laptop message' \
  '[[ $rc == 0 ]] && [[ "$(jq -r .pt "$TMP/out" | "$REAL_BUN" -e "process.stdout.write(Buffer.from(await Bun.stdin.text(),\"base64url\").toString())" | jq -r .text)" == "hello box" ]]'
rail "$(jq -nc --argjson e "$ENV1" '{op:"open", kind:"msg", conv:"other", env:$e}')"
check 'open: the wrong conversation does not open' '[[ $? != 0 ]]'
rail '{"op":"seal","conv":"dashboard","m":"r-1","msg":{"t":"roster","text":"hi"}}'
check 'seal: root writes the type, a seat t is ignored' \
  '[[ "$(jq -r .env "$TMP/out" | jq -c . | dev open dev-laptop1 dashboard "$BOXPUB" | jq -r .t)" == msg ]]'
rail '{"op":"seal","conv":"dashboard","m":"roster-9","msg":{"text":"x"}}'; check 'seal: a roster- id is refused' '[[ $? != 0 ]]'
rail '{"op":"seal-file","conv":"dashboard","m":"r-1","data":"aGk"}'; check 'seal-file: an id without #f<n> is refused' '[[ $? != 0 ]]'
rail '{"op":"seal-file","conv":"dashboard","m":"r-1#f0","data":"aGk"}'; check 'seal-file: #f0 seals' '[[ $? == 0 ]] && jq -e .env "$TMP/out" >/dev/null'
UID_=1077 rail '{"op":"seal","conv":"dashboard","m":"r-2","msg":{"text":"x"}}'; check 'a uid that is not a seat is refused' '[[ $? == "$E_AUTH_REQUIRED" ]]'
( printf '{}' | cmd_chat_e2e_root extra ) >/dev/null 2>&1; check 'an argument is refused' '[[ $? == "$E_USAGE" ]]'
# DIVE-7440: the plugin asks this when it cannot see the key dir. Its contract:
# answer {on:true} when on, exit E_NOT_FOUND (4) when off, and heal the parent.
rail '{"op":"state"}'; check 'state: on answers {"on":true}' '[[ $? == 0 && "$(jq -c . "$TMP/out")" == "{\"on\":true}" ]]'
chmod 0700 "$TMP/etc"; rail '{"op":"state"}'
check 'state: the rail puts a 0700 parent back to 0755' '[[ $? == 0 && "$(stat -c %a "$TMP/etc")" == 755 ]]'
FIVEDIVE_CHAT_E2E_DIR="$TMP/nope/chat-e2e" rail '{"op":"state"}'
check 'state: off exits 4 (E_NOT_FOUND), the code the plugin reads as off' '[[ $? == 4 && $E_NOT_FOUND == 4 ]]'
dev new dev-phone001 >/dev/null; PHONEPUB=$(dev pub dev-phone001)
APPROVE=$(jq -nc --arg p "$PHONEPUB" '{t:"approve", device:"dev-phone001", pub:$p}' | dev seal dev-laptop1 dashboard c-2 "$BOXPUB")
: >"$LOGS/calls"
rail "$(jq -nc --argjson e "$APPROVE" '{op:"open", kind:"msg", conv:"dashboard", env:$e}')"; rc=$?
check 'an approved device approves the phone: answer is the sealed list' \
  '[[ $rc == 0 ]] && [[ "$(jq -c .roster "$TMP/out" | dev open dev-phone001 dashboard "$BOXPUB" | jq -r ".devices|map(.id)|sort|join(\",\")")" == "dev-laptop1,dev-phone001" ]]'
check 'the API mirror gets the approval; the seat never sees the mirror note' \
  'grep -q "POST /server/chat-e2e/box/devices/dev-phone001/approve" "$LOGS/calls" && ! jq -e "has(\"applied\")" "$TMP/out" >/dev/null'

# ── DIVE-7502: the relay's sealed ops (a standard seat on a 5dive server) ────
# The seat seals through its rail (real crypto above) and hands _dashboard_relay
# only ciphertext. The relay posts it marked e2e, and refuses anything that is
# not one box->device envelope, so nothing leaves it marked sealed in the clear.
export DASHBOARD_OUTBOX="$TMP/outbox" FIVEDIVE_DASHBOARD_RELAY_DIR="$TMP/relay-seen"
mkdir -p "$DASHBOARD_OUTBOX"
relay(){ ( export SUDO_UID="${RUID:-$MYUID}"; printf '%s\0' "$@" | cmd_dashboard_relay ) >"$TMP/out" 2>"$TMP/err"; }
rail '{"op":"seal","conv":"dashboard","m":"b-7502","msg":{"text":"sealed hello"}}'; RENV=$(jq -r .env "$TMP/out")
rail '{"op":"seal-file","conv":"dashboard","m":"b-7502#f0","data":"aGVsbG8gZmlsZQ"}'
BLOB="$DASHBOARD_OUTBOX/tap-1730000000000-0-a1b2c3d4e5f6.e2e"; jq -r .env "$TMP/out" >"$BLOB"
check 'the seat sealed a reply and a file envelope to hand the relay' \
  '[[ "$(jq -r .h.d <<<"$RENV")" == out && "$(jq -r .h.d "$BLOB")" == out ]]'
last_body(){ tail -n 1 "$LOGS/bodies"; }
: >"$LOGS/calls"; : >"$LOGS/bodies"
relay event-e2e dashboard "$RENV" "$BLOB"; rc=$?
check 'event-e2e: posts the envelope verbatim to the event URL, answer passed through' \
  '[[ $rc == 0 && "$(head -n1 "$TMP/out")" == 200 ]] && [[ "$(calls)" == "POST /server/messages/event" ]] && [[ "$(last_body | jq -r .body)" == "$RENV" ]]'
check 'event-e2e: the agent is the sudo caller, the metadata says e2e {v:1} and names the blob' \
  '[[ "$(last_body | jq -c "[.agent, .metadata.chat_id, .metadata.e2e, .metadata.files]")" == "[\"tap\",\"dashboard\",{\"v\":1},[\"$BLOB\"]]" ]]'
check 'event-e2e: the box laptop opens what the relay posted' \
  '[[ "$(last_body | jq -r .body | dev open dev-laptop1 dashboard "$BOXPUB" | jq -r .text)" == "sealed hello" ]]'
relay event-e2e dashboard "$RENV"; rc=$?
check 'event-e2e: no files leaves files off and keeps e2e' '[[ $rc == 0 ]] && last_body | jq -e "(.metadata|has(\"files\")|not) and .metadata.e2e.v == 1" >/dev/null'
: >"$LOGS/calls"
relay event-e2e dashboard "plain words"; rc1=$?
relay event-e2e dashboard "$ENV1"; rc2=$?
relay event-e2e dashboard "$RENV$RENV"; rc3=$?
relay event-e2e dashboard "$(jq -c --arg p "$(head -c 70000 /dev/zero | tr '\0' a)" '.ct = $p' <<<"$RENV")"; rc4=$?
relay event-e2e 'bad chat!' "$RENV"; rc5=$?
check 'event-e2e refuses plaintext, a device->box envelope, two envelopes, one over 64 KiB, a bad chat id: no call' \
  '[[ "$rc1 $rc2 $rc3 $rc4 $rc5" == "$E_VALIDATION $E_VALIDATION $E_VALIDATION $E_VALIDATION $E_VALIDATION" && ! -s "$LOGS/calls" ]]'
printf 'the plain photo' >"$DASHBOARD_OUTBOX/tap-1730000000001-photo.jpg"
printf 'the plain photo' >"$DASHBOARD_OUTBOX/tap-1730000000002-0-ffffffffffff.e2e"
cp "$BLOB" "$DASHBOARD_OUTBOX/other-1730000000003-0-ffffffffffff.e2e"
cp "$BLOB" "$TMP/tap-1730000000004-0-ffffffffffff.e2e"
ln -s "$BLOB" "$DASHBOARD_OUTBOX/tap-1730000000005-0-ffffffffffff.e2e"
for f in tap-1730000000001-photo.jpg tap-1730000000002-0-ffffffffffff.e2e other-1730000000003-0-ffffffffffff.e2e tap-1730000000005-0-ffffffffffff.e2e; do
  relay event-e2e dashboard "$RENV" "$DASHBOARD_OUTBOX/$f"; printf '%s ' "$?" >>"$TMP/rcs"
done
relay event-e2e dashboard "$RENV" "$TMP/tap-1730000000004-0-ffffffffffff.e2e"; printf '%s' "$?" >>"$TMP/rcs"
check 'event-e2e refuses a plain file, a .e2e that is not an envelope, another seat'"'"'s blob, a symlink, a blob outside the outbox: no call' \
  '[[ "$(cat "$TMP/rcs")" == "$E_VALIDATION $E_VALIDATION $E_VALIDATION $E_VALIDATION $E_VALIDATION" && ! -s "$LOGS/calls" ]]'
rail '{"op":"seal","conv":"dashboard","m":"s-7502","status":{"label":"reading the logs"}}'; SENV=$(jq -r .env "$TMP/out")
: >"$LOGS/bodies"
relay status-e2e dashboard 1 "$SENV"; rc=$?
check 'status-e2e 1 <envelope>: posts the sealed step to the status URL, marked e2e' \
  '[[ $rc == 0 ]] && [[ "$(calls)" == "POST /server/messages/status" ]] && [[ "$(last_body | jq -c "[.agent, .chat_id, .active, (.label == \$e), .e2e]" --arg e "$SENV")" == "[\"tap\",\"dashboard\",true,true,{\"v\":1}]" ]]'
relay status-e2e dashboard 0; rc=$?
check 'status-e2e 0 (no envelope): label null, still marked e2e' \
  '[[ $rc == 0 ]] && [[ "$(last_body | jq -c "[.active, .label, .e2e]")" == "[false,null,{\"v\":1}]" ]]'
: >"$LOGS/calls"
relay status-e2e dashboard 1 "reading the logs"; rc1=$?
relay status-e2e dashboard 1 "$(jq -c --arg p "$(head -c 9000 /dev/zero | tr '\0' a)" '.ct = $p' <<<"$SENV")"; rc2=$?
relay status-e2e dashboard 2 "$SENV"; rc3=$?
check 'status-e2e refuses a plain label, one over 8 KiB, a bad flag: no call' \
  '[[ "$rc1 $rc2 $rc3" == "$E_VALIDATION $E_VALIDATION $E_VALIDATION" && ! -s "$LOGS/calls" ]]'
relay put "$BLOB"; rc=$?
check 'put accepts the seat'"'"'s sealed .e2e blob (a chat-only box posts it to the files URL)' \
  '[[ $rc == 0 && "$(head -n1 "$TMP/out")" == 200 ]] && grep -q "^POST /server/selfhost/files?path=.*a1b2c3d4e5f6.e2e$" "$LOGS/calls"'
RUID=1077 relay event-e2e dashboard "$RENV"; check 'event-e2e from a uid that is not a seat is refused' '[[ $? == "$E_AUTH_REQUIRED" ]]'
relay nope; check 'an unknown op names both sealed ops in its refusal' 'grep -q "event-e2e, status, status-e2e" "$TMP/err"'

# ── devices approve <code>, revoke <code>, sync drops ────────────────────────
dev new dev-tablet1 >"$TMP/tablet.json"
jq -s '.' "$TMP/laptop.json" "$TMP/tablet.json" <(dev new dev-phone001x >/dev/null; jq -c '.device="dev-phone001" | .pub=$p | .proof=null' --arg p "$PHONEPUB" "$TMP/tablet.json") >"$DEVICES"
run _chat_cmd_devices approve AAAA-BBBB-CCCC-DDDD-EEEE; check 'approve: an unknown code is refused' '[[ $? == "$E_NOT_FOUND" ]]'
CODE=$(dev fp dev-tablet1)
run _chat_cmd_devices ls; check 'ls shows the tablet waiting, with its code' 'grep -q "^$CODE  waiting" "$TMP/out"'
: >"$LOGS/calls"
run _chat_cmd_devices approve "${CODE,,}"; rc=$?
check 'approve <code> (any case) approves the tablet' \
  '[[ $rc == 0 ]] && grep -q "dev-tablet1/approve" "$LOGS/calls" && _chat_e2e_admin "$LIVE" "{\"op\":\"roster\"}" | jq -e "any(.devices[]; .id == \"dev-tablet1\")" >/dev/null'
run _chat_cmd_devices revoke "$CODE"; rc=$?
check 'revoke <code> drops the tablet' \
  '[[ $rc == 0 ]] && grep -q "dev-tablet1/revoke" "$LOGS/calls" && ! _chat_e2e_admin "$LIVE" "{\"op\":\"roster\"}" | jq -e "any(.devices[]; .id == \"dev-tablet1\")" >/dev/null'
jq -s '.' "$TMP/laptop.json" >"$DEVICES"
run _chat_cmd_devices sync
check 'sync drops a device the API no longer lists (revoked in the app)' \
  '! _chat_e2e_admin "$LIVE" "{\"op\":\"roster\"}" | jq -e "any(.devices[]; .id == \"dev-phone001\")" >/dev/null'

# ── DIVE-7440: heal a parent 0.111.0's enable locked to 0700 ─────────────────
chmod 0700 "$TMP/etc"
run _chat_cmd_e2e heal; rc=$?
check 'heal: parent at 0700 with chat-e2e under it goes back to 0755, and says so' \
  '[[ $rc == 0 && "$(stat -c %a "$TMP/etc")" == 755 ]] && grep -q "Repaired $TMP/etc" "$TMP/err"'
chmod 0700 "$TMP/etc"
run _chat_cmd_e2e status
check 'heal: status repairs it too' '[[ "$(stat -c %a "$TMP/etc")" == 755 ]]'
chmod 0700 "$TMP/etc"
run _chat_cmd_devices ls
check 'heal: the per-minute devices path repairs it too' '[[ "$(stat -c %a "$TMP/etc")" == 755 ]]'
chmod 0750 "$TMP/etc"
run _chat_cmd_e2e heal
check 'heal: a parent locked another way (0750) is left alone' '[[ "$(stat -c %a "$TMP/etc")" == 750 ]]'
chmod 0755 "$TMP/etc"
mkdir -p "$TMP/other"; chmod 0700 "$TMP/other"
FIVEDIVE_CHAT_E2E_DIR="$TMP/other/chat-e2e" run _chat_cmd_e2e heal
check 'heal: a 0700 parent with no key dir under it is left alone' '[[ "$(stat -c %a "$TMP/other")" == 700 ]]'
NOT_ROOT=1 run _chat_cmd_e2e heal; check 'heal as non-root is refused' '[[ $? == "$E_PERMISSION" ]]'
check 'self-update calls the fresh binary to heal' \
  'grep -q "5dive\" chat e2e heal" "$SRC/cmd_selfupdate.sh"'

# ── DIVE-7502: enable on a 5dive server (hosted) ─────────────────────────────
# The API runs `5dive chat e2e enable -` over the exec rail with "<secret>\n" on
# stdin and `5dive chat devices sync` after a device publishes. The box is a
# hosted one: connectord.env as the installer writes it (three lines), no
# chat-only mark. The token sent is that box's, and the pairing completes.
SECRET2=$("$REAL_BUN" -e 'const b=crypto.getRandomValues(new Uint8Array(32));process.stdout.write(Buffer.from(b).toString("base64url"))')
H="$TMP/hosted"; mkdir -p "$H/etc"; chmod 0755 "$H/etc"
printf 'CONNECTORD_TOKEN=tok-hosted\nADMIN_PUBKEY_B64=\nAUTOMATION_TOKEN=auto-x\n' >"$H/connectord.env"
hosted(){ FIVEDIVE_CHAT_E2E_DIR="$H/etc/chat-e2e" FIVEDIVE_CONNECTORD_ENV="$H/connectord.env" FIVEDIVE_CHAT_ONLY_MARK="$H/etc/chat-only" "$@"; }
check 'the hosted fixture is not a chat-only box' '! hosted box_is_chat_only'
echo '[]' >"$DEVICES"; : >"$LOGS/calls"; : >"$LOGS/curl.stdin"
printf '%s\n' "$SECRET2" | run hosted _chat_cmd_e2e enable -; rc=$?
check 'hosted: enable - (the API'"'"'s stdin shape) makes the pairing dir and publishes nothing yet' \
  '[[ $rc == 0 && -d "$H/etc/chat-e2e.pairing" && ! -e "$H/etc/chat-e2e" ]] && ! grep -q PUT "$LOGS/calls"'
DEV_SECRET="$SECRET2" dev new dev-hostweb1 >"$TMP/hostweb.json"; jq -s . "$TMP/hostweb.json" >"$DEVICES"
: >"$LOGS/calls"
run hosted _chat_cmd_devices sync; rc=$?
check 'hosted: the sync after the publish pairs the browser and turns it on' \
  '[[ $rc == 0 && -d "$H/etc/chat-e2e" && ! -e "$H/etc/chat-e2e.pairing" && ! -e "$H/etc/chat-e2e/pair.secret" ]] && grep -q "PUT /server/chat-e2e/box/key" "$LOGS/calls" && grep -q "dev-hostweb1/approve" "$LOGS/calls"'
check 'hosted: every call carried THIS box'"'"'s token, and only it' \
  'grep -q "^Authorization: Bearer tok-hosted$" "$LOGS/curl.stdin" && ! grep -q "tok-one\|auto-x" "$LOGS/curl.stdin"'
run hosted _chat_cmd_e2e status; check 'hosted: status says on, one device' 'grep -q "on, 1 device" "$TMP/out"'
printf 'ADMIN_PUBKEY_B64=\n' >"$H/connectord.env"; rm -rf "$H/etc/chat-e2e"; : >"$LOGS/calls"
printf '%s\n' "$SECRET2" | run hosted _chat_cmd_e2e enable -; rc=$?
check 'hosted: a box with no token is refused with no network call, and no key dir' \
  '[[ $rc == "$E_AUTH_REQUIRED" && ! -e "$H/etc/chat-e2e.pairing" && ! -s "$LOGS/calls" ]] && grep -q "Turn encrypted chat on from 5dive.app" "$TMP/err"'

# ── the secret ───────────────────────────────────────────────────────────────
leaks(){ # <secret> -> 0 when it shows up anywhere this harness can see
  grep -rqF -- "$1" "$LOGS" "$TMP/out" "$TMP/err" "$TMP/etc" "$TMP/lib" "$TMP/tmpd" "$STATE_DIR" "$AUDIT_LOG" 2>/dev/null
}
check 'the logger saw real traffic (curl, jq and bun argv)' '[[ -s "$LOGS/curl.argv" && -s "$LOGS/jq.argv" && -s "$LOGS/bun.argv" ]]'
check 'THE SECRET appears in no argv, curl stdin, body, output, log or file' '! leaks "$SECRET"'
check 'DIVE-7502: nor the hosted box'"'"'s secret (it came in on stdin)' '! leaks "$SECRET2" && ! grep -rqF -- "$SECRET2" "$H"'
# Control: the same check on a leaky shape (the secret handed to jq on its argv).
jq -nc --arg s "$SECRET" '{secret:$s}' >/dev/null
check 'control: the check goes red when the secret is on an argv' 'leaks "$SECRET"'

printf '\n%d passed, %d failed\n' "$P" "$F"
(( F == 0 ))
