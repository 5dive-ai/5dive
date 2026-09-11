#!/usr/bin/env bash
# TIER: core — one bun driver plus a handful of file writes; no root, no network,
# no model turns. Measured budget below.
#
# DIVE-3963 — ONE gate across the Codex channel seam: the fresh-agent create path
# in THIS repo, and the dispatcher that drains it in 5dive-plugins.
#
# WHY THIS EXISTS AND WHY IT IS NOT FOUR HARNESSES. The seam that made the codex
# seat deaf for ~2.2 days (DIVE-4036) is a FILE CONTRACT spanning two repos with
# two independent writers and nothing forcing them to agree:
#
#   5dive-cli   _agent_dispatch_inbox_send        writes <inbox>/<id>.json
#   5dive-plugins  plugins/dashboard/dispatcher-inbox.ts  writes the same shape
#   5dive-plugins  plugins/telegram-codex/dispatcher.ts   ingest() ACCEPTS or DROPS it
#
# Each side is already tested against ITSELF — tests/codex_dispatch_delivery_unit.sh
# grades where the CLI payload lands, test/codex-dispatcher.test.ts grades the
# dispatcher's turn scheduling against hand-built messages. Neither grades the
# HANDOFF, so a field renamed on either side is green on both sides and silent in
# production. That is the same shape as the outage: not a missing assertion, a
# missing SUBJECT.
#
# So every arm here moves a payload the REAL CLI code produced into the REAL
# dispatcher code, and asserts on what came out the other end.
#
# THE RECEIPT ARM IS THE LOAD-BEARING ONE. `_agent_dispatch_inbox_send` returns 0
# only after the message is UNLINKED — drained, i.e. the dispatcher accepted a
# turn. "The write succeeded" is exactly the assertion that stayed green through
# the outage, so the undrained and unwritable branches are graded as their own
# arms, by their reason text, and asserted NOT to be a success.
#
# NO SILENT SKIP. The dispatcher half needs the 5dive-plugins tree. If it is not
# resolvable this harness FAILS, loudly, naming the tree it wanted — it does not
# skip. An E2E gate whose end-to-end arms quietly vanish on the runner is the
# false green this row was filed to remove; see the CI note at the bottom for the
# checkout that makes it resolvable.
#
#   bash tests/codex_channel_e2e_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected '$2', got '$3'"; fi; }

RT=src/cmd_agent_runtime.sh
START=5dive-agent-start

# ---------------------------------------------------------------------------
# Resolve the other half of the seam. Same order 5dive-agent-start uses, plus
# the two shapes a CI checkout takes. Unresolvable is a FAILURE, never a skip.
# ---------------------------------------------------------------------------
PLUGIN_DIR=""
# ORDER MATTERS AND IS NOT 5dive-agent-start's. The boot script wants whatever
# is DEPLOYED on the box; a gate wants the SOURCE OF TRUTH, so a checked-out
# 5dive-plugins beats /usr/local/lib/5dive. Grading the deployed copy would be
# the wrong-target class (tests/lib/grading_tree.sh): a stale install passes
# while the tree that will ship has already moved.
for _c in "${TELEGRAM_CODEX_PLUGIN_DIR:-}" \
          "$(pwd)/../5dive-plugins/plugins/telegram-codex" \
          "${GITHUB_WORKSPACE:-/nonexistent}/../5dive-plugins/plugins/telegram-codex" \
          /home/claude/projects/5dive/5dive-plugins/plugins/telegram-codex \
          /usr/local/lib/5dive/telegram-codex; do
  [[ -n "$_c" && -f "$_c/dispatcher-core.ts" ]] && { PLUGIN_DIR="$(cd "$_c" && pwd)"; break; }
done
printf 'seam: cli=%s plugins=%s\n' "$(pwd)" "${PLUGIN_DIR:-UNRESOLVED}"

BUN=""
for _b in /usr/local/bin/bun "$HOME/.bun/bin/bun" "$(command -v bun 2>/dev/null || true)"; do
  [[ -n "$_b" && -x "$_b" ]] && { BUN="$_b"; break; }
done

# A `sudo` that drops `-u <user>` and runs as the caller. It is a FUNCTION, not a
# PATH shim, for a reason worth writing down: tests/lib/env_isolation.sh installs
# its own `sudo` function on any host whose /etc/environment carries FIVE_* knobs
# (DIVE-3096), and a function beats PATH — so a PATH shim works in CI, is
# refused with rc 125 on a control-plane seat, and the harness would be
# environmentally red in exactly one of the two places it runs. Overriding the
# function is deterministic in both. Everything downstream of the sudo is the
# real shipped code.
sudo() {
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -u) shift 2 ;;
      -u*) shift ;;
      --) shift; break ;;
      *) shift ;;
    esac
  done
  command "$@"
}

# ===========================================================================
# STAGE A — a freshly created codex seat DECLARES dispatcher delivery, and the
# path it declares is the path the dispatcher actually watches.
# ===========================================================================

# A1/A2 — the boot predicate decides delivery mode from the channel list. Driven
# through the REAL function sourced out of the shipped boot script, not re-typed.
_codex_pred="$(awk '/^codex_dispatcher_enabled\(\) \{$/{on=1} on{print} on&&/^\}$/{exit}' "$START")"
if [[ -z "$_codex_pred" ]]; then
  bad_t "stage A: could not extract codex_dispatcher_enabled from $START"
else
  eval "$_codex_pred"
  for _ch in telegram dashboard telegram,dashboard dashboard,telegram; do
    if codex_dispatcher_enabled "$_ch"; then ok_t "stage A: channels='$_ch' selects the dispatcher"
    else bad_t "stage A: channels='$_ch' did NOT select the dispatcher"; fi
  done
  # The negative control, and it is not decoration: andy/vesper run codex with no
  # channel and MUST stay on the pane. Re-routing them into an inbox nothing
  # drains is the outage with the polarity flipped.
  for _ch in "" none; do
    if codex_dispatcher_enabled "$_ch"; then bad_t "stage A CONTROL: channels='$_ch' was re-routed off the pane"
    else ok_t "stage A CONTROL: channels='$_ch' stays on the pane path"; fi
  done
fi

# A3 — THE FRESH SEAT. Drive the REAL create-path env writer, then the REAL
# delivery resolver over what it wrote. This is the "fresh agent" end of the
# gate: no hand-built state dir, no hand-written declaration — the same function
# `5dive agent create` calls decides, and the same function `agent _deliver`
# calls reads it back.
export STATE_DIR="$TMP/state"
export ENV_DIR="$STATE_DIR/agents.d"
mkdir -p "$ENV_DIR"
_write_env_fn="$(awk '/^write_agent_env\(\) \{$/{on=1} on{print} on&&/^\}$/{exit}' src/cmd_agent_create.sh)"
_mode_fn="$(awk '/^_agent_delivery_mode\(\) \{$/{on=1} on{print} on&&/^\}$/{exit}' "$RT")"
_inbox_fn="$(awk '/^_agent_delivery_inbox\(\) \{$/{on=1} on{print} on&&/^\}$/{exit}' "$RT")"
_pred_fn="$(awk '/^_codex_dispatcher_enabled\(\) \{$/{on=1} on{print} on&&/^\}$/{exit}' "$RT")"
if [[ -z "$_write_env_fn" || -z "$_mode_fn" || -z "$_inbox_fn" || -z "$_pred_fn" ]]; then
  bad_t "stage A3: could not extract the create/delivery functions" \
    "write_agent_env=${#_write_env_fn} mode=${#_mode_fn} inbox=${#_inbox_fn} pred=${#_pred_fn}"
else
  eval "$_write_env_fn"; eval "$_mode_fn"; eval "$_inbox_fn"; eval "$_pred_fn"
  # chown root:claude at the end of the writer needs root we do not have; the
  # FILE is what the resolver reads, so grade the file, not the writer's rc.
  write_agent_env e2e   codex telegram,dashboard >/dev/null 2>&1
  write_agent_env e2ecl claude telegram          >/dev/null 2>&1
  write_agent_env e2enc codex none               >/dev/null 2>&1

  if grep -qx 'AGENT_TYPE=codex' "$ENV_DIR/e2e.env" \
     && grep -qx 'AGENT_CHANNELS=telegram,dashboard' "$ENV_DIR/e2e.env"; then
    ok_t "stage A3: the real create writer records the new seat's type and channels"
  else
    bad_t "stage A3: the created seat's env file does not carry type+channels" \
      "$(cat "$ENV_DIR/e2e.env" 2>&1 | head -5)"
  fi

  eq_t "stage A3: the fresh codex+channels seat resolves to dispatcher delivery" \
    "dispatcher-inbox" "$(_agent_delivery_mode e2e)"
  eq_t "stage A3 CONTROL: a claude seat with telegram stays on the pane" \
    "pane" "$(_agent_delivery_mode e2ecl)"
  eq_t "stage A3 CONTROL: a codex seat with no channel stays on the pane" \
    "pane" "$(_agent_delivery_mode e2enc)"

  _resolved_inbox="$(_agent_delivery_inbox e2e)"
  eq_t "stage A3: and it posts into the seat's dispatcher inbox" \
    "/home/agent-e2e/.codex/channels/dispatcher/inbox" "$_resolved_inbox"
  if _agent_delivery_inbox e2enc >/dev/null 2>&1; then
    bad_t "stage A3 CONTROL: a pane seat was handed an inbox path"
  else
    ok_t "stage A3 CONTROL: a pane seat is handed NO inbox path (rc 1)"
  fi

  # PATH PARITY ACROSS THE REPOS. The CLI hardcodes where it posts; the
  # dispatcher hardcodes where it watches. Two literals, two repos, no shared
  # constant — so assert they name the same directory rather than trusting them.
  if [[ -n "$PLUGIN_DIR" ]]; then
    _plug_state="$(grep -o "join(homedir(), *'\.codex', *'channels', *'dispatcher')" "$PLUGIN_DIR/dispatcher.ts" | head -1)"
    _plug_inbox="$(grep -o "INBOX_DIR = join(STATE_DIR, *'inbox')" "$PLUGIN_DIR/dispatcher.ts" | head -1)"
    if [[ -n "$_plug_state" && -n "$_plug_inbox" && "$_resolved_inbox" == *"/.codex/channels/dispatcher/inbox" ]]; then
      ok_t "stage A3: the dispatcher WATCHES the directory the CLI POSTS INTO (cross-repo path parity)"
    else
      bad_t "stage A3: the inbox path moved on one side — the CLI would post where nothing drains" \
        "cli=${_resolved_inbox} plugin_state=${_plug_state:-<none>} plugin_inbox=${_plug_inbox:-<none>}"
    fi
  else
    bad_t "stage A3: 5dive-plugins tree UNRESOLVED — the cross-repo path-parity arm cannot run" \
      "set TELEGRAM_CODEX_PLUGIN_DIR or check out 5dive-plugins beside this repo"
  fi
fi

# ===========================================================================
# STAGE B — the REAL delivery path writes a real message, and the RECEIPT is
# non-null only when the message was drained.
# ===========================================================================
INBOX="$TMP/inbox"; mkdir -p "$INBOX"


# Source only the two functions under test, so this harness does not boot the
# whole runtime (and cannot reach the live board).
_send_fn="$(awk '/^_agent_dispatch_inbox_send\(\) \{$/{on=1} on{print} on&&/^\}$/{exit}' "$RT")"
_reason_undrained="$(awk '/^_agent_dispatch_unconfirmed_reason\(\) \{$/{on=1} on{print} on&&/^\}$/{exit}' "$RT")"
_reason_unwritable="$(awk '/^_agent_dispatch_write_failed_reason\(\) \{$/{on=1} on{print} on&&/^\}$/{exit}' "$RT")"
if [[ -z "$_send_fn" ]]; then
  bad_t "stage B: could not extract _agent_dispatch_inbox_send from $RT"
else
  eval "$_send_fn"; eval "$_reason_undrained"; eval "$_reason_unwritable"

  # B1 — DRAINED. A background drainer plays the dispatcher: it unlinks the
  # message, which is the only thing the CLI accepts as a receipt.
  ( for _ in $(seq 1 120); do
      f=$(ls "$INBOX"/*.json 2>/dev/null | head -1) || true
      [[ -n "${f:-}" ]] && { cp "$f" "$TMP/drained.json"; rm -f "$f"; exit 0; }
      sleep 0.05
    done ) &
  _drainer=$!
  FIVE_DISPATCH_CONFIRM_TRIES=60 FIVE_DISPATCH_CONFIRM_SLEEP=0.05 \
    _agent_dispatch_inbox_send "e2e" "hello from the e2e gate" "$INBOX"
  _rc=$?
  wait "$_drainer" 2>/dev/null || true
  eq_t "stage B: a drained message returns a non-null receipt (rc 0)" "0" "$_rc"
  [[ -s "$TMP/drained.json" ]] \
    && ok_t "stage B: the drainer got a message to drain" \
    || bad_t "stage B: nothing was ever written to the inbox"

  # B2 — UNDRAINED is rc 1 and speaks. Nothing drains; the confirm window is
  # shortened by the shipped seam, so the DEFAULTS are still what ships.
  FIVE_DISPATCH_CONFIRM_TRIES=3 FIVE_DISPATCH_CONFIRM_SLEEP=0.02 \
    _agent_dispatch_inbox_send "e2e" "nobody is draining" "$INBOX"
  _rc=$?
  eq_t "stage B: an UNDRAINED message is rc 1, not a success" "1" "$_rc"
  case "$(_agent_dispatch_unconfirmed_reason)" in
    *"sitting undrained"*"DIVE-4036"*) ok_t "stage B: the undrained branch names the defect out loud" ;;
    *) bad_t "stage B: the undrained reason went quiet" "$(_agent_dispatch_unconfirmed_reason)" ;;
  esac
  rm -f "$INBOX"/*.json 2>/dev/null || true

  # B3 — UNWRITABLE is rc 2, distinct from rc 1. Same silence, different cause,
  # and collapsing them loses which one an operator has to fix.
  #
  # NOT `chmod 0500` ON A DIRECTORY WE OWN. Root ignores the permission bits, so
  # that arm writes fine and reports rc 1 whenever this harness runs privileged —
  # and it does: the pre-push rail runs the corpus as root while a desk run is not.
  # An arm that grades the uid it happens to have is a coin flip, and it lands on
  # the side that reads as a real defect. Block the path STRUCTURALLY instead: a
  # regular file where a directory must be makes `mkdir -p` fail for every uid.
  _blocked="$TMP/blocked-inbox"
  : > "$_blocked"
  FIVE_DISPATCH_CONFIRM_TRIES=2 FIVE_DISPATCH_CONFIRM_SLEEP=0.02 \
    _agent_dispatch_inbox_send "e2e" "unwritable" "$_blocked/inbox"
  _rc=$?
  eq_t "stage B: an UNWRITABLE inbox is rc 2, distinct from undrained" "2" "$_rc"
  case "$(_agent_dispatch_write_failed_reason)" in
    *"unwritable"*"DIVE-4036"*) ok_t "stage B: the unwritable branch names the defect out loud" ;;
    *) bad_t "stage B: the unwritable reason went quiet" "$(_agent_dispatch_write_failed_reason)" ;;
  esac
fi

# ===========================================================================
# STAGE C — the REAL ChannelDispatcher consumes the message the REAL CLI wrote.
# ===========================================================================
if [[ -z "$PLUGIN_DIR" ]]; then
  bad_t "stage C: 5dive-plugins tree UNRESOLVED — the dispatcher arms cannot run" \
        "this is a FAILURE, not a skip: an E2E gate whose end-to-end arms vanish is a false green"
elif [[ -z "$BUN" ]]; then
  bad_t "stage C: bun not found — the dispatcher arms cannot run" \
        "looked in /usr/local/bin, ~/.bun/bin, PATH"
elif [[ ! -s "$TMP/drained.json" ]]; then
  bad_t "stage C: no CLI-written message survived stage B to feed the dispatcher"
else
  cat > "$TMP/driver.ts" <<DRIVER_EOF
import { readFileSync } from 'node:fs'
import { ChannelDispatcher, type DispatchMessage, type DispatcherState, type RpcPort }
  from '${PLUGIN_DIR}/dispatcher-core.ts'

const out: string[] = []
const say = (k: string, v: unknown) => out.push(k + '=' + JSON.stringify(v))

function harness(initial: DispatcherState | null = null) {
  let saved = initial ? structuredClone(initial) : null
  const requests: Array<{ method: string; params: any }> = []
  const published: Array<{ route: any; text: string; meta: any }> = []
  let nextTurn = 1
  const rpc: RpcPort = {
    async request(method, params: any) {
      requests.push({ method, params })
      if (method === 'thread/start') return { thread: { id: 'thread-1' } }
      if (method === 'thread/resume') return { thread: { id: params.threadId } }
      if (method === 'turn/start') return { turn: { id: \`turn-\${nextTurn++}\` } }
      if (method === 'turn/steer') return { turnId: params.expectedTurnId }
      throw new Error('unexpected ' + method)
    },
  }
  const d = new ChannelDispatcher(rpc, {
    load: () => saved ? structuredClone(saved) : null,
    save: (s: DispatcherState) => { saved = structuredClone(s) },
  }, { publish: async (route, text, meta) => { published.push({ route, text, meta }) } }, '/workspace')
  return { d, requests, published, snapshot: () => saved }
}

// C1 — the message the CLI actually wrote is ACCEPTED by the real dispatcher.
const fromCli = JSON.parse(readFileSync('${TMP}/drained.json', 'utf8')) as DispatchMessage
{
  const h = harness()
  await h.d.initialize()
  say('c1_outcome', await h.d.submit(fromCli))
  const start = h.requests.find(r => r.method === 'turn/start')
  say('c1_trigger', start?.params?.turnTrigger)
  say('c1_text', start?.params?.input?.[0]?.text)
  say('c1_msgid', start?.params?.clientUserMessageId)
  // The ingest() acceptance predicate, applied to the CLI's own bytes.
  say('c1_ingestable', Boolean(fromCli?.id && fromCli?.text?.trim()
    && fromCli?.route?.source && fromCli?.route?.chat_id
    && ['telegram','dashboard','agent'].includes(fromCli.route.source)))
}

// C2 — COMBINED-CHANNEL ORIGIN ROUTING. Telegram owns the turn; a dashboard
// message waits; the reply reaches telegram ONLY.
{
  const h = harness()
  await h.d.initialize()
  const tg: DispatchMessage = { id: 'tg-1', text: 'from telegram', route: { source: 'telegram', chat_id: '42' } }
  const dash: DispatchMessage = { id: 'dash-1', text: 'from dashboard', route: { source: 'dashboard', chat_id: 'dashboard' } }
  say('c2_tg', await h.d.submit(tg))
  say('c2_dash', await h.d.submit(dash))
  say('c2_same_route_steers', await h.d.submit({ id: 'tg-2', text: 'more', route: { source: 'telegram', chat_id: '42' } }))
  await h.d.notification('item/completed', { turnId: 'turn-1', item: { type: 'agentMessage', id: 'i1', text: 'reply one' } })
  say('c2_reply_sources', h.published.map(p => p.route.source))
  say('c2_reply_chat', h.published.map(p => p.route.chat_id))
  // The queued dashboard message starts only once the telegram turn completes.
  await h.d.notification('turn/completed', { turn: { id: 'turn-1', status: 'completed' } })
  const starts = h.requests.filter(r => r.method === 'turn/start')
  say('c2_started_triggers', starts.map(r => r.params.turnTrigger))
  await h.d.notification('item/completed', { turnId: 'turn-2', item: { type: 'agentMessage', id: 'i2', text: 'reply two' } })
  say('c2_all_reply_sources', h.published.map(p => p.route.source))
}

// C3 — RESTART MID-FLOW. A dispatcher that dies holding an active turn tells the
// originating route on the way back up, and drains what queued behind it.
{
  const interrupted: DispatcherState = {
    threadId: 'thread-1',
    seen: ['tg-1'],
    pending: [{ id: 'dash-9', text: 'queued while it was down', route: { source: 'dashboard', chat_id: 'dashboard' } }],
    active: { turnId: 'turn-99', routeKey: 'telegram:42:', route: { source: 'telegram', chat_id: '42' },
              message: { id: 'tg-1', text: 'interrupted', route: { source: 'telegram', chat_id: '42' } } },
  }
  const h = harness(interrupted)
  await h.d.initialize()
  say('c3_notice_source', h.published[0]?.route?.source)
  say('c3_notice_kind', h.published[0]?.meta?.kind)
  say('c3_notice_says_restart', /restarted/.test(h.published[0]?.text ?? ''))
  const started = h.requests.filter(r => r.method === 'turn/start')
  say('c3_recovered_trigger', started[0]?.params?.turnTrigger)
  say('c3_recovered_text', started[0]?.params?.input?.[0]?.text)
  say('c3_pending_left', h.snapshot()?.pending?.length)
}

console.log(out.join('\n'))
DRIVER_EOF
  if "$BUN" run "$TMP/driver.ts" > "$TMP/driver.out" 2> "$TMP/driver.err"; then
    # shellcheck disable=SC1090
    _v() { sed -n "s/^$1=//p" "$TMP/driver.out"; }

    eq_t "stage C1: the real dispatcher ACCEPTS the message the real CLI wrote" '"started"' "$(_v c1_outcome)"
    eq_t "stage C1: it passes ingest()'s acceptance predicate on the CLI's own bytes" 'true' "$(_v c1_ingestable)"
    eq_t "stage C1: the turn is tagged with the originating channel" '"5dive:agent"' "$(_v c1_trigger)"
    eq_t "stage C1: the agent's text reached the model input unaltered" '"hello from the e2e gate"' "$(_v c1_text)"
    [[ "$(_v c1_msgid)" == '"5dive-'* ]] \
      && ok_t "stage C1: the CLI's message id is the app-server's client id (dedup survives the seam)" \
      || bad_t "stage C1: the message id did not survive the seam" "$(_v c1_msgid)"

    eq_t "stage C2: telegram inbound starts the turn" '"started"' "$(_v c2_tg)"
    eq_t "stage C2: a DIFFERENT channel waits instead of stealing the turn" '"queued"' "$(_v c2_dash)"
    eq_t "stage C2: the SAME channel steers the running turn" '"steered"' "$(_v c2_same_route_steers)"
    eq_t "stage C2: the reply goes to the originating channel only" '["telegram"]' "$(_v c2_reply_sources)"
    eq_t "stage C2: and to the originating conversation only" '["42"]' "$(_v c2_reply_chat)"
    eq_t "stage C2: the queued dashboard message starts after the telegram turn" \
      '["5dive:telegram","5dive:dashboard"]' "$(_v c2_started_triggers)"
    eq_t "stage C2: each reply lands on its own channel, never the other" \
      '["telegram","dashboard"]' "$(_v c2_all_reply_sources)"

    eq_t "stage C3: a restart tells the route whose turn it lost" '"telegram"' "$(_v c3_notice_source)"
    eq_t "stage C3: and tells it as an error, not as a model reply" '"error"' "$(_v c3_notice_kind)"
    eq_t "stage C3: the notice actually says it restarted" 'true' "$(_v c3_notice_says_restart)"
    eq_t "stage C3: work queued while it was down is recovered" '"5dive:dashboard"' "$(_v c3_recovered_trigger)"
    eq_t "stage C3: recovered with its text intact" '"queued while it was down"' "$(_v c3_recovered_text)"
    eq_t "stage C3: and the queue is empty afterwards" '0' "$(_v c3_pending_left)"
  else
    bad_t "stage C: the dispatcher driver did not run" "$(tail -5 "$TMP/driver.err")"
  fi
fi

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
