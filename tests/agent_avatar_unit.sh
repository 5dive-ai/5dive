#!/usr/bin/env bash
# DIVE-5104 — the one per-agent portrait path. Grades every writer's guard
# (_agent_avatar_install), the persona face.ref reader the backfill uses, the
# home-escape refusal, and the `avatar` field the agent-list snapshot reports.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/agent-avatar-unit.XXXXXX)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
pass=0; fail=0
okk() { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# shellcheck source=/dev/null
source "$ROOT/src/cmd_agent_avatar.sh"
export AGENT_HOME_ROOT="$TMP/home"
mkdir -p "$AGENT_HOME_ROOT/agent-alpha/.claude"

png() { printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR' >"$1"; }
png "$TMP/a.png"
printf '\xff\xd8\xff\xe0\x00\x10JFIF' >"$TMP/a.jpg"
printf 'RIFF\x10\x00\x00\x00WEBPVP8 ' >"$TMP/a.webp"
printf 'GIF89a\x01\x00\x01\x00' >"$TMP/a.gif"
printf '<!doctype html><title>404</title>' >"$TMP/a.html"
: >"$TMP/empty.png"

# --- sniff ---------------------------------------------------------------
for f in png jpg webp gif; do
  _agent_avatar_sniff "$TMP/a.$f" >/dev/null && okk "sniff accepts .$f" || bad "sniff refused .$f"
done
_agent_avatar_sniff "$TMP/a.html" >/dev/null && bad 'sniff accepted an HTML error page' || okk 'sniff refuses an HTML error page'

# --- install -------------------------------------------------------------
dst="$AGENT_HOME_ROOT/agent-alpha/.claude/avatar.png"
if (( EUID != 0 )); then
  out=$(_agent_avatar_install alpha "$TMP/a.png") && [[ "$out" == png ]] && cmp -s "$TMP/a.png" "$dst" \
    && okk 'an agent that owns its home installs its own portrait' || bad "self install failed: $out"
  [[ "$(stat -c %a "$dst")" == 644 ]] && okk 'portrait is installed 644' || bad 'portrait mode is not 644'
  ls -a "$AGENT_HOME_ROOT/agent-alpha/.claude" | grep -q '^\.avatar' && bad 'install left a temp file' || okk 'install leaves no temp file'
else
  echo "skip: self-install arms (running as root)"
fi
out=$(_agent_avatar_install alpha "$TMP/a.html") && bad 'install accepted a non-image' \
  || { [[ "$out" == *"not a PNG"* ]] && okk 'install refuses a non-image and says why' || bad "wrong refusal: $out"; }
out=$(_agent_avatar_install alpha "$TMP/empty.png") && bad 'install accepted an empty file' || okk 'install refuses an empty file'
out=$(AGENT_AVATAR_MAX_BYTES=8 _agent_avatar_install alpha "$TMP/a.png") && bad 'install ignored the size cap' \
  || { [[ "$out" == *"cap"* ]] && okk 'install refuses an image over the cap' || bad "wrong refusal: $out"; }
out=$(_agent_avatar_install nobodyhere "$TMP/a.png") && bad 'install wrote for an agent with no home' || okk 'install refuses an agent with no home'
mkdir -p "$AGENT_HOME_ROOT/agent-beta" "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$AGENT_HOME_ROOT/agent-beta/.claude"
out=$(_agent_avatar_install beta "$TMP/a.png") && bad 'install wrote through a symlinked .claude' \
  || { [[ ! -e "$TMP/elsewhere/avatar.png" && "$out" == *symlink* ]] && okk 'install refuses a symlinked .claude' || bad "symlink arm: $out"; }
if (( EUID != 0 )); then
  mkdir -p "$TMP/foreign"; chmod 755 "$TMP/foreign"
  # A home the caller does not own: simulate with a root-owned dir when one exists.
  if [[ -d /root && ! -O /root ]]; then
    out=$(AGENT_HOME_ROOT=/ _agent_avatar_install root "$TMP/a.png" 2>/dev/null); rc=$?
    (( rc != 0 )) && okk 'a non-root caller cannot set a home it does not own' || bad 'non-owner install succeeded'
  fi
fi

# --- get --data: the bytes the dashboard draws ----------------------------
# shellcheck source=/dev/null
source "$ROOT/src/lib/output.sh"
require_agent() { :; }; valid_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,15}$ ]]; }
fail() { echo "FAILCALL: $2"; return 1; }
png "$AGENT_HOME_ROOT/agent-alpha/.claude/avatar.png"
G=$(JSON_MODE=1 _agent_avatar_get alpha --data)
[[ "$(jq -r '.data.avatar.dataUri' <<<"$G")" == "data:image/png;base64,$(base64 -w0 "$AGENT_HOME_ROOT/agent-alpha/.claude/avatar.png")" ]] \
  && okk 'get --data returns the exact bytes as a typed data URI' || bad "get --data: $G"
# A real portrait is hundreds of KB: its base64 must not ride argv (128 KB cap).
{ printf '\x89PNG\r\n\x1a\n'; head -c 400000 /dev/urandom; } >"$AGENT_HOME_ROOT/agent-alpha/.claude/avatar.png"
G=$(JSON_MODE=1 _agent_avatar_get alpha --data 2>&1)
[[ "$(jq -r '.data.avatar.dataUri | length' <<<"$G" 2>/dev/null)" -gt 500000 ]] \
  && okk 'get --data carries a 400 KB portrait (no argv-length failure)' || bad "large get --data: ${G:0:200}"
png "$AGENT_HOME_ROOT/agent-alpha/.claude/avatar.png"
G=$(JSON_MODE=1 _agent_avatar_get alpha)
[[ "$(jq -r '.data.avatar | has("dataUri")' <<<"$G")" == false && "$(jq -r '.data.avatar.format' <<<"$G")" == png ]] \
  && okk 'get without --data carries metadata only' || bad "get: $G"
G=$(JSON_MODE=1 AGENT_AVATAR_MAX_BYTES=8 _agent_avatar_get alpha --data)
[[ "$(jq -r '.data.avatar' <<<"$G")" == null ]] && okk 'get never serves a file over the cap' || bad "over-cap get: $G"
printf 'not an image' >"$AGENT_HOME_ROOT/agent-alpha/.claude/avatar.png"
G=$(JSON_MODE=1 _agent_avatar_get alpha --data)
[[ "$(jq -r '.data.avatar' <<<"$G")" == null ]] && okk 'get never serves a non-image' || bad "non-image get: $G"
G=$(JSON_MODE=1 _agent_avatar_get gamma-x --data)
[[ "$(jq -r '.data.avatar' <<<"$G")" == null ]] && okk 'get on an agent with no portrait is null' || bad "absent get: $G"

# --- persona face.ref ----------------------------------------------------
printf 'id: alpha\nface:\n  ref: "https://example.test/p.png"\n  style: holo\nvoice: x\n' >"$TMP/block.persona.yaml"
printf 'id: alpha\nface: {ref: card.png, style: holo}\n' >"$TMP/inline.persona.yaml"
printf 'id: alpha\nface:\n  ref: monogram:A\n' >"$TMP/mono.persona.yaml"
printf 'id: alpha\nvoice: x\n' >"$TMP/noface.persona.yaml"
[[ "$(_agent_avatar_persona_ref "$TMP/block.persona.yaml")" == "https://example.test/p.png" ]] \
  && okk 'reads face.ref from a block mapping' || bad 'block face.ref not read'
[[ "$(_agent_avatar_persona_ref "$TMP/inline.persona.yaml")" == "card.png" ]] \
  && okk 'reads face.ref from an inline mapping' || bad 'inline face.ref not read'
[[ -z "$(_agent_avatar_persona_ref "$TMP/noface.persona.yaml")" ]] \
  && okk 'a persona with no face yields nothing' || bad 'invented a face.ref'

# --- resolve (the backfill runs as root over agent-written text) -----------
h="$AGENT_HOME_ROOT/agent-alpha"; mkdir -p "$h/cards"; png "$h/cards/card.png"
cp "$TMP/inline.persona.yaml" "$h/cards/alpha.persona.yaml"
[[ "$(_agent_avatar_resolve_ref alpha "$h/cards/alpha.persona.yaml" card.png)" == "$(realpath "$h/cards/card.png")" ]] \
  && okk 'a relative face.ref resolves beside its yaml' || bad 'relative ref did not resolve'
_agent_avatar_resolve_ref alpha "$h/cards/alpha.persona.yaml" ../../../../etc/passwd >/dev/null \
  && bad 'a ../ face.ref escaped the home' || okk 'a ../ face.ref cannot leave the agent home'
_agent_avatar_resolve_ref alpha "$h/cards/alpha.persona.yaml" /etc/hostname >/dev/null \
  && bad 'an absolute face.ref outside home resolved' || okk 'an absolute face.ref outside home is refused'
ln -s /etc/hostname "$h/cards/sneaky.png"
_agent_avatar_resolve_ref alpha "$h/cards/alpha.persona.yaml" sneaky.png >/dev/null \
  && bad 'a symlink out of home resolved' || okk 'a symlink pointing out of home is refused'
_agent_avatar_resolve_ref alpha "$TMP/mono.persona.yaml" monogram:A >/dev/null \
  && bad 'monogram resolved to a file' || okk 'a monogram ref is not a portrait'
[[ "$(_agent_avatar_resolve_ref alpha x https://example.test/p.png)" == https://example.test/p.png ]] \
  && okk 'a URL face.ref passes through for fetching' || bad 'URL ref mangled'

# --- the agent-list snapshot field --------------------------------------
PY="$TMP/snapshot.py"
awk '/^# __5DIVE_AGENT_LIST_PY_BEGIN__$/{e=1;next} /^# __5DIVE_AGENT_LIST_PY_END__$/{exit} e{print}' \
  "$ROOT/src/cmd_agent.sh" >"$PY"
mkdir -p "$TMP/profiles" "$TMP/connectors" "$TMP/sudoers" "$AGENT_HOME_ROOT/agent-gamma/.claude" "$AGENT_HOME_ROOT/agent-delta/.claude"
png "$AGENT_HOME_ROOT/agent-alpha/.claude/avatar.png"
ln -sf /etc/hostname "$AGENT_HOME_ROOT/agent-gamma/.claude/avatar.png"
head -c 2097153 /dev/zero >"$AGENT_HOME_ROOT/agent-delta/.claude/avatar.png"
row='{"type":"opencode","channels":"none","heartbeat":{"enabled":false}}'
printf '{"agents":{"alpha":%s,"gamma":%s,"delta":%s,"eps":%s}}\n' "$row" "$row" "$row" "$row" >"$TMP/agents.json"
OUT=$(python3 "$PY" "$TMP/agents.json" "$TMP/profiles" "$TMP/connectors" "$AGENT_HOME_ROOT" "$TMP/sudoers" /default 2>/dev/null)
[[ "$(jq -r '.[] | select(.name=="alpha") | .avatar.path' <<<"$OUT")" == "$AGENT_HOME_ROOT/agent-alpha/.claude/avatar.png" &&
   "$(jq -r '.[] | select(.name=="alpha") | .avatar.bytes' <<<"$OUT")" == 16 &&
   "$(jq -r '.[] | select(.name=="alpha") | .avatar.mtime | type' <<<"$OUT")" == number ]] \
  && okk 'agent list reports path, bytes and mtime for a portrait' || bad "alpha avatar row: $(jq -c '.[0].avatar' <<<"$OUT")"
[[ "$(jq -r '.[] | select(.name=="gamma") | .avatar' <<<"$OUT")" == null ]] && okk 'a symlinked avatar reads as none' || bad 'symlinked avatar reported'
[[ "$(jq -r '.[] | select(.name=="delta") | .avatar' <<<"$OUT")" == null ]] && okk 'an avatar over the cap reads as none' || bad 'oversized avatar reported'
[[ "$(jq -r '.[] | select(.name=="eps") | .avatar' <<<"$OUT")" == null ]] && okk 'an agent with no portrait reads null' || bad 'phantom avatar'

# --- wiring ---------------------------------------------------------------
grep -q '^  src/cmd_agent_avatar.sh$' "$ROOT/build.sh" && okk 'module is bundled' || bad 'module missing from build.sh'
grep -q 'cmd_agent_avatar "\$@"' "$ROOT/src/main.sh" && okk '`agent avatar` is dispatched' || bad 'agent avatar not dispatched'
grep -q '_agent_avatar_install "\$agent" "\$avatar"' "$ROOT/src/cmd_cos.sh" \
  && okk 'cos set-avatar writes the same canonical file' || bad 'cos set-avatar does not write avatar.png'
grep -q 'agent avatar backfill --once' "$ROOT/src/cmd_selfupdate.sh" && okk '5dive update runs the one-time backfill' || bad 'backfill not wired into update'

echo "pass=$pass fail=$fail"
(( fail == 0 ))
