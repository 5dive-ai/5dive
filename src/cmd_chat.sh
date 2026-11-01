# ---------------------------------------------------------------------------
# DIVE-6878: encrypted 5dive web chat on a self-hosted (chat-only) server, the
# root side. Protocol v1 and the seat's contract: the dashboard plugin's
# docs/chat-e2e.md (DIVE-6876); the key directory is 5dive-api's (DIVE-6877).
#
#   5dive _chat_e2e                 the seat's rail: open / seal / seal-file, one
#                                   JSON request on stdin (exact-path NOPASSWD,
#                                   no args). The seat never reads the box key or
#                                   the device list.
#   5dive chat e2e enable <secret>  make the box key and keep the pairing secret
#                                   the browser put in the link line ("-" reads it
#                                   from stdin, which is how the link script
#                                   passes it). The secret is never printed,
#                                   logged, audited or sent: it lives only in
#                                   pair.secret (root 0600) until a device pairs.
#   5dive chat e2e status
#   5dive chat devices [ls|approve <code>|revoke <code|device>|sync]
#
# WHEN IT TURNS ON. The key material waits in <dir>.pairing/ and the box key is
# NOT published at enable: the API makes a chat encrypted-only the moment a box
# key is live, and the plugin starts sealing the moment <dir> exists, and both
# need a device to seal to. So the first device that pairs (its key carries an
# HMAC under the secret: `sync`, which the link's reporter runs every minute) or
# is approved by its code here flips all three at once: the box key and its
# proof go up, <dir>.pairing/ becomes <dir>/, the device is approved, and the
# secret is deleted.
#
# Crypto is WebCrypto on bun (openssl's CLI has no AES-GCM): the two files below
# are staged root-owned into $(_chat_e2e_lib) and run as root. The envelope is a
# byte-identical copy of the plugin's e2e.ts (sha256 pinned in
# tests/chat_e2e_unit.sh). The device list a reader trusts is roster.json here;
# the API's approved_at is a mirror, and a device the API drops (the owner
# revoked it in the app) is dropped here too, which can only remove a reader.
# ---------------------------------------------------------------------------

_chat_e2e_live()    { local d="${FIVEDIVE_CHAT_E2E_DIR:-/etc/5dive/chat-e2e}"; printf '%s' "${d%/}"; }
_chat_e2e_pairing() { printf '%s.pairing' "$(_chat_e2e_live)"; }
_chat_e2e_lib()     { local d="${FIVEDIVE_CHAT_E2E_LIB:-/usr/local/lib/5dive/chat-e2e}"; printf '%s' "${d%/}"; }

# DIVE-7440: the key dirs are 0700, their PARENT (/etc/5dive) is not. Every seat
# stats <live> to know whether to seal (the dashboard plugin's isE2E) and reads
# /etc/5dive/chat-only, so a parent at 0700 makes encryption invisible to the
# agent: it delivers envelopes raw and its plaintext replies bounce with 409.
# 0.111.0's enable did exactly that (`install -d -m 0700 parent dir` sets BOTH).
_chat_e2e_mkparent() {
  local parent; parent=$(dirname -- "$(_chat_e2e_live)")
  [[ -d "$parent" ]] || install -d -m 0755 -- "$parent"
}
# Undo that on a box it hit: only the exact signature (parent 0700 AND a key dir
# under it), so a parent someone locked down on purpose is left alone. Prints
# one line when it changed something; never fails the caller.
_chat_e2e_heal_parent() {
  local live parent mode
  live=$(_chat_e2e_live); parent=$(dirname -- "$live")
  [[ -d "$live" || -d "$live.pairing" ]] || return 0
  mode=$(stat -c '%a' -- "$parent" 2>/dev/null) || return 0
  [[ "$mode" == 700 ]] || return 0
  chmod 0755 -- "$parent" 2>/dev/null || return 0
  echo "Repaired $parent (was 0700, now 0755): agents can see that chat is encrypted again."
}

# The dir that holds the keys: the live one, else the one waiting for its first
# device, else nothing.
_chat_e2e_keydir() {
  local live; live=$(_chat_e2e_live)
  if [[ -d "$live" && ! -L "$live" ]]; then printf '%s' "$live"
  elif [[ -d "$live.pairing" && ! -L "$live.pairing" ]]; then printf '%s' "$live.pairing"
  fi
}

_chat_e2e_bun() {
  local c
  if [[ -n "${FIVEDIVE_CHAT_E2E_BUN:-}" ]]; then printf '%s' "$FIVEDIVE_CHAT_E2E_BUN"; return 0; fi
  for c in /usr/local/bin/bun /home/claude/.bun/bin/bun "$(command -v bun 2>/dev/null)"; do
    [[ -n "$c" && -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  fail "$E_NOT_INSTALLED" "encrypted chat runs on bun, and this server has none (the 5dive install puts it at /usr/local/bin/bun)."
}

# Stage the two files root-owned (a seat must not be able to swap what root runs)
# and rewrite them only when they changed.
_chat_e2e_stage() {
  local lib f tmp
  lib=$(_chat_e2e_lib)
  [[ -L "$lib" ]] && fail "$E_PERMISSION" "chat-e2e: $lib is a symlink."
  install -d -m 0755 -- "$lib" 2>/dev/null || fail "$E_GENERIC" "chat-e2e: cannot create $lib."
  [[ -O "$lib" ]] || fail "$E_PERMISSION" "chat-e2e: $lib is not owned by $(id -un)."
  for f in chat-e2e-envelope.ts chat-e2e.ts; do
    tmp=$(mktemp -p "$lib" ".stage.XXXXXX") || fail "$E_GENERIC" "chat-e2e: cannot write in $lib."
    if [[ "$f" == chat-e2e.ts ]]; then _chat_e2e_root_ts >"$tmp"; else _chat_e2e_envelope_ts >"$tmp"; fi
    if cmp -s -- "$tmp" "$lib/$f" && [[ -O "$lib/$f" && ! -L "$lib/$f" ]]; then rm -f -- "$tmp"
    else { chmod 0644 -- "$tmp" && mv -fT -- "$tmp" "$lib/$f"; } || fail "$E_GENERIC" "chat-e2e: cannot install $lib/$f."; fi
  done
  return 0
}

# _chat_e2e_run <call|admin> <dir> [side-file] — the request on stdin, the answer on stdout.
_chat_e2e_run() {
  local bun; bun=$(_chat_e2e_bun)
  _chat_e2e_stage
  ( umask 077; "$bun" "$(_chat_e2e_lib)/chat-e2e.ts" "$@" )
}

# _chat_e2e_admin <dir> <json> — one admin request; fails with bun's reason.
_chat_e2e_admin() {
  local dir="$1" req="$2" out err rc=0
  err=$(mktemp) || fail "$E_GENERIC" "chat-e2e: cannot create a temp file."
  out=$(printf '%s' "$req" | _chat_e2e_run admin "$dir" 2>"$err") || rc=$?
  if (( rc != 0 )); then
    local why; why=$(head -c 300 -- "$err"); rm -f -- "$err"
    fail "$E_VALIDATION" "chat-e2e: ${why:-the key step failed (rc=$rc)}"
  fi
  rm -f -- "$err"
  printf '%s' "$out"
}

# _chat_e2e_api <method> <path> [json] — one call to the key directory as this
# box (the token on curl's stdin, never argv: _dash_relay_call). Prints
# "<status>\n<body>".
_chat_e2e_api() {
  local tok
  tok=$(_dash_relay_token)
  [[ -n "$tok" ]] || fail "$E_AUTH_REQUIRED" "this server is not linked to 5dive.app (no $(_sp_connectord_env)). Link it from 5dive.app first."
  _dash_relay_call "$1" "$(_dash_relay_api_base)/server/chat-e2e$2" "${3:-}" "$tok"
}
_chat_e2e_status_of() { printf '%s' "${1%%$'\n'*}"; }
_chat_e2e_body_of()   { [[ "$1" == *$'\n'* ]] && printf '%s' "${1#*$'\n'}"; return 0; }

# The device list the API holds (pending ones included), or fail.
_chat_e2e_api_devices() {
  local ans; ans=$(_chat_e2e_api GET /box/devices) || exit $?
  [[ "$(_chat_e2e_status_of "$ans")" == 200 ]] \
    || fail "$E_GENERIC" "5dive.app did not give the device list (HTTP $(_chat_e2e_status_of "$ans"))."
  _chat_e2e_body_of "$ans" | jq -ce '.devices | arrays' 2>/dev/null \
    || fail "$E_GENERIC" "5dive.app sent a device list this CLI cannot read."
}

# Post the device list, sealed, to every agent that has 5dive.app chat on, in its
# own chat ("dashboard"): that is where an app reads it. Best effort.
_chat_e2e_announce() {
  local dir="$1" agents ans env a n=0
  agents=$(registry_read | jq -r '.agents // {} | to_entries[] | select((.value.channels // "") | split(",") | index("dashboard")) | .key' 2>/dev/null | head -n 50) || agents=""
  [[ -n "$agents" ]] || return 0
  ans=$(_chat_e2e_admin "$dir" '{"op":"announce","convs":["dashboard"]}') || return 0
  env=$(jq -c '.posts[0].env // empty' <<<"$ans") || return 0
  [[ -n "$env" ]] || return 0
  while IFS= read -r a; do
    [[ "$a" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || continue
    local body; body=$(jq -nc --arg a "$a" --arg b "$env" '{agent:$a, body:$b, metadata:{chat_id:"dashboard", e2e:{v:1}}}')
    _dash_relay_call POST "$(_dash_relay_api_base)/server/messages/event" "$body" "$(_dash_relay_token)" >/dev/null 2>&1 && n=$((n + 1))
  done <<<"$agents"
  return 0
}

# Turn it on: publish the box key with its proof, make the pairing dir the live
# one, forget the secret. Only from <dir>.pairing/ with a device on the roster.
_chat_e2e_activate() {
  local dir="$1" live key ans
  live=$(_chat_e2e_live)
  key=$(_chat_e2e_admin "$dir" '{"op":"key"}')
  [[ "$(jq -r '.proof // empty' <<<"$key")" != "" ]] \
    || fail "$E_VALIDATION" "the box key has no pairing proof yet: run the link line from 5dive.app (or sudo 5dive chat e2e enable) first."
  ans=$(_chat_e2e_api PUT /box/key "$(jq -c '{pub, proof}' <<<"$key")") || exit $?
  [[ "$(_chat_e2e_status_of "$ans")" == 200 ]] \
    || fail "$E_GENERIC" "5dive.app did not take the box key (HTTP $(_chat_e2e_status_of "$ans")); nothing was turned on."
  if [[ "$dir" != "$live" ]]; then
    mv -T -- "$dir" "$live" || fail "$E_GENERIC" "could not move $dir to $live."
    chmod 0700 -- "$live"
  fi
  rm -f -- "$live/pair.secret"
  printf '%s' "$live"
}

# _chat_e2e_approve <dir> <device> <pub> — add one device and say so everywhere.
# Prints the dir the keys are in afterwards.
_chat_e2e_approve() {
  local dir="$1" device="$2" pub="$3" ans
  _chat_e2e_admin "$dir" "$(jq -nc --arg d "$device" --arg p "$pub" '{op:"set", add:{device:$d, pub:$p}}')" >/dev/null
  [[ "$dir" == "$(_chat_e2e_live)" ]] || dir=$(_chat_e2e_activate "$dir")
  rm -f -- "$dir/pair.secret"
  ans=$(_chat_e2e_api POST "/box/devices/${device}/approve") || exit $?
  [[ "$(_chat_e2e_status_of "$ans")" == 200 ]] \
    || echo "warning: 5dive.app did not record the approval (HTTP $(_chat_e2e_status_of "$ans")); this server trusts the device anyway." >&2
  _chat_e2e_announce "$dir"
  printf '%s' "$dir"
}

# Normalised device code: the 20 characters of fingerprint(), no dashes.
_chat_e2e_code() { local c="${1^^}"; printf '%s' "${c//[^A-Z0-9]/}"; }

# Every device the API lists, with its code and whether this server trusts it.
_chat_e2e_table() {
  local dir="$1" api roster fps
  api=$(_chat_e2e_api_devices)
  roster=$(_chat_e2e_admin "$dir" '{"op":"roster"}')
  fps=$(_chat_e2e_admin "$dir" "$(jq -c '{op:"fp", pubs:[.[].pub]}' <<<"$api")")
  jq -c --argjson r "$roster" --argjson f "$fps" '
    ($r.devices | map({key:.id, value:.pub}) | from_entries) as $ok
    | map({device, pub, code: ($f.fps[.pub] // "?"), createdAt,
           state: (if $ok[.device] == .pub then "approved" elif $ok[.device] then "other-key" else "waiting" end)})' <<<"$api"
}

cmd_chat() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    e2e) _chat_cmd_e2e "$@" ;;
    devices|device) _chat_cmd_devices "$@" ;;
    ""|-h|--help|help)
      cat <<'USAGE'
5dive chat — encrypted chat in 5dive.app on this self-hosted server

  sudo 5dive chat e2e enable <secret>    pair this server (the 5dive.app link line runs it)
  sudo 5dive chat e2e status
  sudo 5dive chat devices                list the browsers and phones, with their codes
  sudo 5dive chat devices approve <code> let a new browser or phone read the chat
  sudo 5dive chat devices revoke <code>  stop one
USAGE
      ;;
    *) fail "$E_USAGE" "chat: unknown subcommand '$sub' (e2e, devices)." ;;
  esac
}

_chat_cmd_e2e() {
  local sub="${1:-status}"; shift || true
  _gate_is_root || fail "$E_PERMISSION" "chat e2e needs root: sudo 5dive chat e2e $sub"
  _chat_e2e_heal_parent >&2
  case "$sub" in
    heal) return 0 ;;   # self-update's call: the repair above, nothing else
    enable)
      (( $# == 1 )) || fail "$E_USAGE" "usage: sudo 5dive chat e2e enable <secret>   (copy the line from 5dive.app)"
      local secret="$1" dir live key
      [[ "$secret" == - ]] && { IFS= read -r secret || true; }
      [[ "$secret" =~ ^[A-Za-z0-9_-]{43}$ ]] \
        || fail "$E_VALIDATION" "that is not the pairing code from 5dive.app. Copy the whole line again."
      [[ -n "$(_dash_relay_token)" ]] \
        || fail "$E_AUTH_REQUIRED" "this server is not linked to 5dive.app yet. Run the whole line from 5dive.app."
      live=$(_chat_e2e_live)
      dir=$(_chat_e2e_keydir)
      if [[ -z "$dir" ]]; then
        dir="$live.pairing"
        # The parent keeps its own mode (DIVE-7440); only the key dir is 0700.
        { _chat_e2e_mkparent && install -d -m 0700 -- "$dir"; } || fail "$E_GENERIC" "cannot create $dir."
      fi
      # printf is a builtin: the secret goes into the file without being any
      # process's argument.
      ( umask 077; printf '%s\n' "$secret" >"$dir/pair.secret" ) || fail "$E_GENERIC" "cannot write $dir/pair.secret."
      secret=""
      _chat_e2e_admin "$dir" '{"op":"keygen"}' >/dev/null
      key=$(_chat_e2e_admin "$dir" '{"op":"proof"}')
      if [[ "$dir" == "$live" ]]; then
        # Already on (a new pairing after every browser lost its key): the new
        # proof goes up now, so the new browser can check this server's key.
        local ans; ans=$(_chat_e2e_api PUT /box/key "$(jq -c '{pub, proof}' <<<"$key")") || exit $?
        [[ "$(_chat_e2e_status_of "$ans")" == 200 ]] \
          || fail "$E_GENERIC" "5dive.app did not take the box key (HTTP $(_chat_e2e_status_of "$ans"))."
      fi
      _chat_cmd_devices sync >/dev/null 2>&1 || true
      if [[ -d "$live" ]]; then
        echo "Encrypted chat is on. Server key: $(_chat_e2e_admin "$live" '{"op":"key"}' | jq -r .fp)"
      else
        echo "Encrypted chat is ready: open 5dive.app in the browser you copied the line from. It pairs within a minute."
      fi ;;
    status)
      local dir; dir=$(_chat_e2e_keydir)
      if [[ -z "$dir" ]]; then echo "Encrypted chat: off."
      elif [[ "$dir" == "$(_chat_e2e_live)" ]]; then
        echo "Encrypted chat: on, $(_chat_e2e_admin "$dir" '{"op":"roster"}' | jq -r '.devices | length') device(s). Server key: $(_chat_e2e_admin "$dir" '{"op":"key"}' | jq -r .fp)"
      else echo "Encrypted chat: waiting for the first browser to pair."
      fi ;;
    *) fail "$E_USAGE" "chat e2e: unknown subcommand '$sub' (enable, status)." ;;
  esac
}

_chat_cmd_devices() {
  local sub="${1:-ls}"; shift || true
  _gate_is_root || fail "$E_PERMISSION" "chat devices needs root: sudo 5dive chat devices $sub"
  _chat_e2e_heal_parent >&2   # `sync` runs every minute: a hit box heals within one
  local dir; dir=$(_chat_e2e_keydir)
  [[ -n "$dir" ]] || fail "$E_NOT_FOUND" "encrypted chat is off on this server. Turn it on from 5dive.app."
  case "$sub" in
    ls|list)
      local rows; rows=$(_chat_e2e_table "$dir")
      if (( JSON_MODE )); then jq -c '{ok:true, data:{devices:.}}' <<<"$rows"; return 0; fi
      [[ "$(jq 'length' <<<"$rows")" != 0 ]] || { echo "No browser or phone has asked yet."; return 0; }
      jq -r '.[] | "\(.code)  \(if .state == "approved" then "approved" else "waiting " end)  \(.device)  \(.createdAt[:10])"' <<<"$rows"
      jq -e 'any(.[]; .state != "approved")' <<<"$rows" >/dev/null \
        && echo "Approve one with: sudo 5dive chat devices approve <code>" ;;
    approve)
      (( $# == 1 )) || fail "$E_USAGE" "usage: sudo 5dive chat devices approve <code>   (the code the new browser or phone shows)"
      local want rows hit
      want=$(_chat_e2e_code "$1")
      [[ ${#want} == 20 ]] || fail "$E_VALIDATION" "a device code is 20 letters and digits (XXXX-XXXX-XXXX-XXXX-XXXX)."
      rows=$(_chat_e2e_table "$dir")
      hit=$(jq -c --arg w "$want" '[.[] | select((.code | gsub("-"; "")) == $w)]' <<<"$rows")
      [[ "$(jq length <<<"$hit")" == 1 ]] || fail "$E_NOT_FOUND" "no browser or phone shows that code. List them: sudo 5dive chat devices"
      [[ "$(jq -r '.[0].state' <<<"$hit")" != approved ]] || { echo "Already approved."; return 0; }
      _chat_e2e_approve "$dir" "$(jq -r '.[0].device' <<<"$hit")" "$(jq -r '.[0].pub' <<<"$hit")" >/dev/null
      echo "Approved. It reads new messages from now on." ;;
    revoke|rm)
      (( $# == 1 )) || fail "$E_USAGE" "usage: sudo 5dive chat devices revoke <code>"
      local want roster device ans
      want=$(_chat_e2e_code "$1")
      roster=$(_chat_e2e_admin "$dir" '{"op":"roster"}')
      device=$(jq -r --arg w "$want" --arg raw "$1" '[.devices[] | select((.fp | gsub("-"; "")) == $w or .id == $raw) | .id][0] // empty' <<<"$roster")
      [[ -n "$device" ]] || fail "$E_NOT_FOUND" "no approved browser or phone matches that. List them: sudo 5dive chat devices"
      _chat_e2e_admin "$dir" "$(jq -nc --arg d "$device" '{op:"set", remove:$d}')" >/dev/null
      ans=$(_chat_e2e_api POST "/box/devices/${device}/revoke") || exit $?
      [[ "$(_chat_e2e_status_of "$ans")" =~ ^(200|404)$ ]] \
        || echo "warning: 5dive.app did not record the revoke (HTTP $(_chat_e2e_status_of "$ans")); this server no longer seals to it anyway." >&2
      _chat_e2e_announce "$dir"
      echo "Revoked. It reads nothing new from now on."
      [[ "$(_chat_e2e_admin "$dir" '{"op":"roster"}' | jq '.devices | length')" != 0 ]] \
        || echo "No device is left: replies will not send until you approve one." ;;
    sync)
      # Every minute from the link's reporter. Pair the first device whose key
      # carries the secret's proof; drop a device the API dropped; mirror
      # approvals the API lost.
      local api roster paired d pub changed=0 just=""
      api=$(_chat_e2e_api_devices)
      roster=$(_chat_e2e_admin "$dir" '{"op":"roster"}')
      if [[ -f "$dir/pair.secret" ]]; then
        paired=$(_chat_e2e_admin "$dir" "$(jq -c --argjson r "$roster" \
          '{op:"paired", devices:[.[] | select(.proof != null) | select(.device as $d | $r.devices | all(.id != $d))]}' <<<"$api")")
        d=$(jq -r '.ok[0] // empty' <<<"$paired")
        if [[ -n "$d" ]]; then
          pub=$(jq -r --arg d "$d" '.[] | select(.device == $d) | .pub' <<<"$api")
          dir=$(_chat_e2e_approve "$dir" "$d" "$pub")
          just=$d
          echo "Paired $d."
          roster=$(_chat_e2e_admin "$dir" '{"op":"roster"}')
        fi
      fi
      for d in $(jq -r --argjson a "$api" '.devices[] | select(.id as $i | $a | all(.device != $i)) | .id' <<<"$roster"); do
        _chat_e2e_admin "$dir" "$(jq -nc --arg d "$d" '{op:"set", remove:$d}')" >/dev/null && changed=1
        echo "Dropped $d (revoked in 5dive.app)."
      done
      for d in $(jq -r --argjson r "$roster" '.[] | select(.approvedAt == null) | select(.device as $i | $r.devices | any(.id == $i and .pub != null)) | .device' <<<"$api"); do
        [[ "$d" == "$just" ]] && continue
        _chat_e2e_api POST "/box/devices/${d}/approve" >/dev/null || true
      done
      (( changed )) && _chat_e2e_announce "$dir"
      return 0 ;;
    *) fail "$E_USAGE" "chat devices: unknown subcommand '$sub' (ls, approve, revoke, sync)." ;;
  esac
}

# The seat's rail. Reached ONLY through the exact-path NOPASSWD grant (or by root).
cmd_chat_e2e_root() {
  _gate_is_root || fail "$E_PERMISSION" "_chat_e2e is a privileged internal primitive (reachable only through the exact-path NOPASSWD grant)."
  [[ $# -eq 0 ]] || fail "$E_USAGE" "_chat_e2e takes no arguments (the request is read from stdin)."
  local ruid="${SUDO_UID:-}"
  if [[ -n "$ruid" ]]; then
    [[ "$ruid" =~ ^[0-9]+$ && "$ruid" != 0 && "$(_gate_uid_to_agent "$ruid")" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] \
      || fail "$E_AUTH_REQUIRED" "_chat_e2e caller uid ${ruid} is not an agent seat."
  fi
  # DIVE-7440: a seat calls this when it cannot see the key dir; put the parent
  # back on the way, so the next look needs no call.
  _chat_e2e_heal_parent >/dev/null 2>&1 || true
  local live; live=$(_chat_e2e_live)
  [[ -d "$live" && ! -L "$live" && -f "$live/box.jwk" ]] \
    || fail "$E_NOT_FOUND" "encrypted chat is not on on this server."
  local side out rc=0 applied
  side=$(mktemp) || fail "$E_GENERIC" "_chat_e2e: cannot create a temp file."
  # A file envelope is ~4/3 of the 20 MB cap; past 32 MB is not a request.
  out=$(head -c 33554432 | _chat_e2e_run call "$live" "$side") || rc=$?
  if (( rc != 0 )); then rm -f -- "$side"; exit "$E_VALIDATION"; fi
  applied=$(cat -- "$side" 2>/dev/null); rm -f -- "$side"
  if [[ -n "$applied" ]]; then
    # An approved device changed the list: mirror it to the API (best effort;
    # the API's copy is never what a reader trusts).
    local t d
    t=$(jq -r '.t // empty' <<<"$applied"); d=$(jq -r '.device // empty' <<<"$applied")
    if [[ "$t" =~ ^(approve|revoke)$ && "$d" =~ ^[A-Za-z0-9_-]{8,64}$ ]]; then
      _chat_e2e_api POST "/box/devices/${d}/${t}" >/dev/null 2>&1 || true
    fi
  fi
  printf '%s' "$out"
}

_chat_e2e_root_ts() {
  cat <<'CHAT_E2E_TS'
// DIVE-6878: the root side of encrypted 5dive web chat (protocol v1: the
// envelope file beside this one, a byte-identical copy of the dashboard
// plugin's e2e.ts; contract: that plugin's docs/chat-e2e.md). Staged and run
// by the 5dive CLI as root, never by a seat:
//
//   bun chat-e2e.ts call  <dir> <side-file>   the `_chat_e2e` verb: open, seal, seal-file
//   bun chat-e2e.ts admin <dir>               box key, pairing, device list (the
//                                             `chat` verbs; root's own callers only)
//
// One JSON request on stdin, one JSON answer on stdout; a refusal exits 2 with
// the reason on stderr. <dir> holds box.jwk (the box key), box.proof (its
// pairing proof), roster.json (the approved devices, the one list a reader
// trusts) and, until the first device pairs, pair.secret. Every file is 0600.
// The pairing secret is only ever read from pair.secret: it is never on a
// command line, never in a request, never in an answer.

import { existsSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import * as E from './chat-e2e-envelope.ts'

const P256 = { name: 'ECDH', namedCurve: 'P-256' } as const
// The box's id in every envelope and in the pairing proofs (`box|box|<pub>`).
export const BOX = 'box'
const DEVICE_RE = /^[A-Za-z0-9_-]{8,64}$/
const CONV_RE = /^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,127}$/
const MAX_DEVICES = 20
const dec = new TextDecoder()

export type Roster = { n: number; devices: Record<string, string> }

class Refusal extends Error {}
const refuse = (why: string): never => { throw new Refusal(why) }

function writeSecret(path: string, data: string) {
  const tmp = `${path}.${process.pid}.tmp`
  writeFileSync(tmp, data, { mode: 0o600 })
  renameSync(tmp, path)
}

const isDevice = (s: unknown): s is string => typeof s === 'string' && DEVICE_RE.test(s) && s !== BOX
async function checkPub(raw: unknown): Promise<string> {
  if (typeof raw !== 'string' || !/^[A-Za-z0-9_-]{80,100}$/.test(raw)) refuse('not a P-256 public key')
  const b = E.unb64u(raw as string)
  if (b.length !== 65 || b[0] !== 4) refuse('not a P-256 public key')
  try { await E.importPublic(raw as string) } catch { refuse('not a P-256 public key') }
  return raw as string
}

export function makeBox(dir: string) {
  const f = (name: string) => join(dir, name)
  const roster = (): Roster => existsSync(f('roster.json')) ? JSON.parse(readFileSync(f('roster.json'), 'utf8')) : { n: 0, devices: {} }
  const saveRoster = (r: Roster) => writeSecret(f('roster.json'), JSON.stringify(r))
  const jwk = () => JSON.parse(readFileSync(f('box.jwk'), 'utf8')) as JsonWebKey
  const priv = () => crypto.subtle.importKey('jwk', jwk(), P256, false, ['deriveBits'])
  const pub = () => {
    const j = jwk()
    const raw = new Uint8Array(65)
    raw[0] = 4; raw.set(E.unb64u(j.x!), 1); raw.set(E.unb64u(j.y!), 33)
    return E.b64u(raw)
  }
  const secret = () => existsSync(f('pair.secret')) ? readFileSync(f('pair.secret'), 'utf8').trim() : ''
  const recipients = async () => {
    const list = Object.entries(roster().devices)
    if (list.length === 0) refuse('no device is approved yet')
    return Promise.all(list.map(async ([id, raw]) => ({ id, pub: await E.importPublic(raw) })))
  }
  const sealOut = async (conv: string, m: string, plaintext: Uint8Array | string) =>
    E.seal({ senderId: BOX, senderPriv: await priv(), recipients: await recipients(), conv, msgId: m, dir: 'out', plaintext })
  const rosterBody = (r: Roster) => JSON.stringify({ t: 'roster', n: r.n, devices: Object.entries(r.devices).map(([id, p]) => ({ id, pub: p })) })

  /** Apply one device-list change; null when it changes nothing. */
  async function change(add: { device: unknown; pub: unknown } | null, remove: unknown): Promise<Roster | null> {
    const r = roster()
    if (add) {
      if (!isDevice(add.device)) refuse('bad device id')
      const p = await checkPub(add.pub)
      const cur = r.devices[add.device as string]
      if (cur === p) return null
      // An approval never replaces a key: that would let one device swap another's.
      if (cur) refuse(`device ${add.device} is approved with another key: revoke it first`)
      if (Object.keys(r.devices).length >= MAX_DEVICES) refuse(`at most ${MAX_DEVICES} devices`)
      r.devices[add.device as string] = p
    } else {
      if (!isDevice(remove)) refuse('bad device id')
      if (!r.devices[remove as string]) return null
      delete r.devices[remove as string]
    }
    r.n++
    saveRoster(r)
    return r
  }

  // --- the seat's verb: open, seal, seal-file ------------------------------
  async function call(req: any, side: string): Promise<Record<string, unknown>> {
    // DIVE-7440: a seat that cannot see the key dir asks root whether it is on.
    if (req?.op === 'state') return { on: true }
    const conv = String(req?.conv ?? '')
    if (!CONV_RE.test(conv)) refuse('bad conversation id')
    if (req.op === 'open') {
      const env = req.env as E.Envelope
      if (!env?.h || typeof env.h.m !== 'string' || typeof env.h.s !== 'string') refuse('not an envelope')
      const isFile = req.kind === 'file'
      if (req.kind !== 'file' && req.kind !== 'msg') refuse('kind is msg or file')
      if (isFile !== env.h.m.includes('#')) refuse(`a ${isFile ? 'file' : 'message'} id must ${isFile ? '' : 'not '}carry #`)
      const raw = roster().devices[env.h.s]
      if (!raw || env.h.s === BOX) refuse(`sender ${env.h.s} is not an approved device`)
      let pt: Uint8Array
      try {
        pt = await E.open({ env, myId: BOX, myPriv: await priv(), senderPub: await E.importPublic(raw), expect: { conv, dir: 'in' } })
      } catch (err) { return refuse(`does not open: ${(err as Error).message}`) }
      if (!isFile) {
        let inner: any = null
        try { inner = JSON.parse(dec.decode(pt)) } catch {}
        if (inner?.t === 'approve' || inner?.t === 'revoke') {
          const r = inner.t === 'approve'
            ? await change({ device: inner.device, pub: inner.pub }, null)
            : await change(null, inner.device)
          const now = r ?? roster()
          // What the API's mirror needs; the CLI reads it, the seat never sees it.
          if (r) writeSecret(side, JSON.stringify({ t: inner.t, device: inner.device }))
          return { sender: env.h.s, m: env.h.m, roster: await sealOut(conv, `roster-${now.n}`, rosterBody(now)) }
        }
      }
      return { sender: env.h.s, m: env.h.m, pt: E.b64u(pt) }
    }
    if (req.op === 'seal') {
      const m = String(req.m ?? '')
      if (!/^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,127}$/.test(m) || m.startsWith('roster-')) refuse('a seat may not use that message id')
      // Root writes the type: a seat can never make a body read as a device list.
      let inner: Record<string, unknown>
      if (req.status) inner = { t: 'status', label: String(req.status.label ?? '').slice(0, 200) }
      else {
        const msg = req.msg ?? {}
        inner = { t: 'msg', text: String(msg.text ?? '') }
        if (Array.isArray(msg.files)) inner.files = msg.files.slice(0, 10).map((x: any) => ({ path: String(x?.path ?? ''), name: String(x?.name ?? ''), size: Number(x?.size ?? 0) }))
        if (msg.question && typeof msg.question === 'object') inner.question = { id: String(msg.question.id ?? ''), options: Array.isArray(msg.question.options) ? msg.question.options.slice(0, 10) : [] }
      }
      return { env: await sealOut(conv, m, JSON.stringify(inner)) }
    }
    if (req.op === 'seal-file') {
      const m = String(req.m ?? '')
      if (!/^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,127}#f\d{1,2}$/.test(m)) refuse('a file id must end in #f<n>')
      return { env: await sealOut(conv, m, E.unb64u(String(req.data ?? ''))) }
    }
    return refuse(`unknown op ${req?.op}`)
  }

  // --- root's own: box key, pairing, device list -----------------------------
  async function admin(req: any): Promise<Record<string, unknown>> {
    switch (req?.op) {
      case 'keygen': {
        let created = false
        if (!existsSync(f('box.jwk'))) {
          const kp = await E.newIdentity(true)
          writeSecret(f('box.jwk'), JSON.stringify(await crypto.subtle.exportKey('jwk', kp.privateKey)))
          created = true
        }
        if (!existsSync(f('roster.json'))) saveRoster({ n: 0, devices: {} })
        const p = pub()
        return { pub: p, fp: await E.fingerprint(p), created }
      }
      case 'proof': {
        // The box key's proof under the secret in pair.secret, kept in box.proof.
        const s = secret()
        if (!/^[A-Za-z0-9_-]{43}$/.test(s)) refuse('no pairing secret')
        const p = pub()
        const proof = await E.pairProof(s, 'box', BOX, p)
        writeSecret(f('box.proof'), proof)
        return { pub: p, proof }
      }
      case 'key': {
        const p = pub()
        return { pub: p, proof: existsSync(f('box.proof')) ? readFileSync(f('box.proof'), 'utf8').trim() : null, fp: await E.fingerprint(p) }
      }
      case 'paired': {
        // Which of these devices carry a proof made with the pairing secret.
        const s = secret()
        const ok: string[] = []
        if (/^[A-Za-z0-9_-]{43}$/.test(s)) {
          for (const d of Array.isArray(req.devices) ? req.devices : []) {
            if (!isDevice(d?.device) || typeof d?.pub !== 'string' || typeof d?.proof !== 'string') continue
            try { if (await E.pairVerify(s, 'device', BOX, d.pub, d.proof)) ok.push(d.device) } catch {}
          }
        }
        return { ok }
      }
      case 'fp': {
        const out: Record<string, string> = {}
        for (const p of Array.isArray(req.pubs) ? req.pubs : []) {
          try { out[p] = await E.fingerprint(await checkPub(p)) } catch {}
        }
        return { fps: out }
      }
      case 'roster': {
        const r = roster()
        return { n: r.n, devices: await Promise.all(Object.entries(r.devices).map(async ([id, p]) => ({ id, pub: p, fp: await E.fingerprint(p) }))) }
      }
      case 'set': {
        const r = req.add ? await change(req.add, null) : await change(null, req.remove)
        return { changed: r !== null, n: (r ?? roster()).n }
      }
      case 'announce': {
        // The device list, sealed to every device on it, for each conversation.
        const r = roster()
        const posts: { conv: string; m: string; env: E.Envelope }[] = []
        for (const conv of Array.isArray(req.convs) ? req.convs : []) {
          if (typeof conv !== 'string' || !CONV_RE.test(conv)) continue
          posts.push({ conv, m: `roster-${r.n}`, env: await sealOut(conv, `roster-${r.n}`, rosterBody(r)) })
        }
        return { n: r.n, posts }
      }
      case 'forget-secret':
        if (existsSync(f('pair.secret'))) unlinkSync(f('pair.secret'))
        return { ok: true }
    }
    return refuse(`unknown op ${req?.op}`)
  }
  return { call, admin, roster }
}

if (import.meta.main) {
  const [mode, dir, side] = process.argv.slice(2)
  try {
    if (!dir || (mode !== 'call' && mode !== 'admin') || (mode === 'call' && !side)) refuse('usage: chat-e2e.ts call <dir> <side-file> | admin <dir>')
    const raw = await new Response(Bun.stdin.stream()).text()
    let req: unknown
    try { req = JSON.parse(raw) } catch { refuse('the request is not JSON') }
    const box = makeBox(dir)
    const ans = mode === 'call' ? await box.call(req, side) : await box.admin(req)
    process.stdout.write(JSON.stringify(ans))
  } catch (err) {
    process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`)
    process.exit(2)
  }
}
CHAT_E2E_TS
}

# A byte-identical copy of 5dive-plugins plugins/dashboard/e2e.ts (DIVE-6876).
_chat_e2e_envelope_ts() {
  cat <<'CHAT_E2E_ENVELOPE_TS'
// DIVE-6876 (designed on DIVE-6875): the 5dive chat end-to-end envelope, v1.
//
// WebCrypto only (browser, Telegram webview, Bun), no dependency, so the app
// and the box can run byte-identical copies.
//
//   identity   ECDH P-256 per party: one for the box, one per browser/phone.
//              P-256, not X25519: older Android webviews lack X25519 in
//              WebCrypto, and the Telegram Mini App runs in one.
//   message    one random content key K, AES-256-GCM over the plaintext,
//              then K wrapped once per recipient under a key derived from
//              ECDH(sender static, recipient static) + HKDF-SHA256.
//   binding    the header (version, sender, conversation, message id,
//              direction, time, salt) is the AAD of the body; the wrap's AAD
//              is the header plus SHA-256 of the body ciphertext, so a
//              recipient who knows K cannot swap the body under the other
//              recipients' wraps.
//   pairing    the secret in the link line keys an HMAC over each side's
//              public key, so the API (which carries the keys) cannot swap one.
//
// Static-static: no forward secrecy in v1. A stolen box key reads past
// ciphertext the relay kept. That is a named item for the outside review.

const enc = new TextEncoder()
const dec = new TextDecoder()

export const VERSION = 1
const INFO_WRAP = '5dive-chat-e2e-v1 wrap'
const INFO_PAIR = '5dive-chat-e2e-v1 pair'

export type Direction = 'in' | 'out'
export interface Header {
  v: number
  s: string // sender id: 'box' or a device id
  c: string // conversation id
  m: string // message id (client id), the receiver's replay key
  d: Direction
  t: number // sender's clock, ms
  salt: string
}
export interface Envelope {
  h: Header
  iv: string
  ct: string
  k: Record<string, { iv: string; w: string }>
}

export function b64u(bytes: ArrayBuffer | Uint8Array): string {
  const u = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
  let s = ''
  for (const b of u) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}
export function unb64u(s: string): Uint8Array {
  const p = s.replace(/-/g, '+').replace(/_/g, '/')
  const bin = atob(p + '='.repeat((4 - (p.length % 4)) % 4))
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}
const rand = (n: number) => crypto.getRandomValues(new Uint8Array(n))

/** Canonical bytes of the header: fixed key order, no whitespace. */
function canon(h: Header): Uint8Array {
  return enc.encode(JSON.stringify([h.v, h.s, h.c, h.m, h.d, h.t, h.salt]))
}

export async function newIdentity(extractable = false): Promise<CryptoKeyPair> {
  return crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, extractable, ['deriveBits'])
}
export async function exportPublic(pub: CryptoKey): Promise<string> {
  return b64u(await crypto.subtle.exportKey('raw', pub))
}
export async function importPublic(raw: string): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', unb64u(raw), { name: 'ECDH', namedCurve: 'P-256' }, true, [])
}

/** What a person compares on two screens: 20 base32 chars of SHA-256(pub). */
export async function fingerprint(pubRaw: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', unb64u(pubRaw)))
  const A = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  let bits = 0, acc = 0, out = ''
  for (const b of d) {
    acc = (acc << 8) | b; bits += 8
    while (bits >= 5 && out.length < 20) { out += A[(acc >> (bits - 5)) & 31]; bits -= 5 }
    if (out.length >= 20) break
  }
  return out.match(/.{4}/g)!.join('-')
}

async function kek(priv: CryptoKey, pub: CryptoKey, salt: Uint8Array, from: string, to: string, header: Header): Promise<CryptoKey> {
  const shared = await crypto.subtle.deriveBits({ name: 'ECDH', public: pub }, priv, 256)
  const ikm = await crypto.subtle.importKey('raw', shared, 'HKDF', false, ['deriveKey'])
  return crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt, info: enc.encode(`${INFO_WRAP}|${from}|${to}|${header.c}`) },
    ikm, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt'],
  )
}

function wrapAad(h: Header, ctHash: Uint8Array): Uint8Array {
  const a = canon(h)
  const out = new Uint8Array(a.length + ctHash.length)
  out.set(a); out.set(ctHash, a.length)
  return out
}

export interface SealArgs {
  senderId: string
  senderPriv: CryptoKey
  recipients: { id: string; pub: CryptoKey }[]
  conv: string
  msgId: string
  dir: Direction
  plaintext: Uint8Array | string
  now?: number
}

export async function seal(a: SealArgs): Promise<Envelope> {
  if (a.recipients.length === 0) throw new Error('no recipients')
  const salt = rand(16)
  const h: Header = { v: VERSION, s: a.senderId, c: a.conv, m: a.msgId, d: a.dir, t: a.now ?? Date.now(), salt: b64u(salt) }
  const kRaw = rand(32)
  const k = await crypto.subtle.importKey('raw', kRaw, 'AES-GCM', false, ['encrypt'])
  const iv = rand(12)
  const pt = typeof a.plaintext === 'string' ? enc.encode(a.plaintext) : a.plaintext
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: canon(h) }, k, pt))
  const ctHash = new Uint8Array(await crypto.subtle.digest('SHA-256', ct))
  const wraps: Envelope['k'] = {}
  for (const r of a.recipients) {
    if (wraps[r.id]) throw new Error(`duplicate recipient ${r.id}`)
    const key = await kek(a.senderPriv, r.pub, salt, a.senderId, r.id, h)
    const wiv = rand(12)
    const w = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: wiv, additionalData: wrapAad(h, ctHash) }, key, kRaw)
    wraps[r.id] = { iv: b64u(wiv), w: b64u(w) }
  }
  kRaw.fill(0)
  return { h, iv: b64u(iv), ct: b64u(ct), k: wraps }
}

export interface OpenArgs {
  env: Envelope
  myId: string
  myPriv: CryptoKey
  /** The sender's key from the reader's OWN trusted roster, never from the envelope or the API. */
  senderPub: CryptoKey
  expect: { conv: string; dir: Direction }
}

/** The content key for `a.myId`. Exported for the co-recipient test only; callers use open(). */
export async function unwrap(a: OpenArgs, ct = unb64u(a.env.ct)): Promise<Uint8Array> {
  const { h } = a.env
  const mine = a.env.k[a.myId]
  if (!mine) throw new Error('not a recipient')
  const ctHash = new Uint8Array(await crypto.subtle.digest('SHA-256', ct))
  const key = await kek(a.myPriv, a.senderPub, unb64u(h.salt), h.s, a.myId, h)
  return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64u(mine.iv), additionalData: wrapAad(h, ctHash) }, key, unb64u(mine.w)))
}

/** Throws on anything off: wrong version, conversation, direction, key, or a single flipped bit. */
export async function open(a: OpenArgs): Promise<Uint8Array> {
  const { h } = a.env
  if (h.v !== VERSION) throw new Error(`unknown version ${h.v}`)
  if (h.c !== a.expect.conv) throw new Error('conversation mismatch')
  if (h.d !== a.expect.dir) throw new Error('direction mismatch')
  const ct = unb64u(a.env.ct)
  const kRaw = await unwrap(a, ct)
  const k = await crypto.subtle.importKey('raw', kRaw, 'AES-GCM', false, ['decrypt'])
  kRaw.fill(0)
  return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64u(a.env.iv), additionalData: canon(h) }, k, ct))
}
export const openText = async (a: OpenArgs) => dec.decode(await open(a))

async function pairKey(secret: string): Promise<CryptoKey> {
  const ikm = await crypto.subtle.importKey('raw', unb64u(secret), 'HKDF', false, ['deriveKey'])
  return crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32), info: enc.encode(INFO_PAIR) },
    ikm, { name: 'HMAC', hash: 'SHA-256', length: 256 }, false, ['sign', 'verify'],
  )
}
/** 32 random bytes, made in the browser, carried only in the link line the owner pastes on the server. */
export const newPairingSecret = () => b64u(rand(32))
const pairMsg = (role: string, boxId: string, pubRaw: string) => enc.encode(`${role}|${boxId}|${pubRaw}`)
export async function pairProof(secret: string, role: 'box' | 'device', boxId: string, pubRaw: string): Promise<string> {
  return b64u(await crypto.subtle.sign('HMAC', await pairKey(secret), pairMsg(role, boxId, pubRaw)))
}
export async function pairVerify(secret: string, role: 'box' | 'device', boxId: string, pubRaw: string, proof: string): Promise<boolean> {
  return crypto.subtle.verify('HMAC', await pairKey(secret), unb64u(proof), pairMsg(role, boxId, pubRaw))
}
CHAT_E2E_ENVELOPE_TS
}
