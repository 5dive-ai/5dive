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
# The fixture agents (alpha, beta, ...) are not real users, so a real `runuser -u
# agent-alpha` cannot drop to them: every arm takes the caller branch, even when
# the pre-push rail runs this as root. The root branch is graded by as_root below.
_agent_avatar_is_root() { return 1; }
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
# avatar.png itself planted as a link to a directory: GNU `mv -f tmp dst` would
# move the image INTO that directory and report success (quinn, DIVE-5104 iter 1).
mkdir -p "$AGENT_HOME_ROOT/agent-zeta/.claude" "$TMP/rootonly"
ln -s "$TMP/rootonly" "$AGENT_HOME_ROOT/agent-zeta/.claude/avatar.png"
out=$(_agent_avatar_install zeta "$TMP/a.gif"); rc=$?
(( rc == 1 )) && [[ -z "$(ls -A "$TMP/rootonly")" && -L "$AGENT_HOME_ROOT/agent-zeta/.claude/avatar.png" ]] \
  && ! compgen -G "$AGENT_HOME_ROOT/agent-zeta/.claude/.avatar*" >/dev/null \
  && okk 'install refuses an avatar.png that is a symlink to a directory' || bad "dir-symlink arm: rc=$rc out=$out rootonly=$(ls -A "$TMP/rootonly")"
mkdir -p "$AGENT_HOME_ROOT/agent-eta/.claude/avatar.png"
out=$(_agent_avatar_install eta "$TMP/a.png"); rc=$?
(( rc == 1 )) && [[ -z "$(ls -A "$AGENT_HOME_ROOT/agent-eta/.claude/avatar.png")" ]] \
  && okk 'install refuses an avatar.png that is a directory' || bad "dir arm: rc=$rc out=$out"
# The TEMP name is predictable too: plant .avatar.png.<pid> as a link. The $(...)
# subshell keeps this shell's $$, so this is the exact name install writes to.
# Without `install -T`, a link to a directory gets the image copied INTO it under
# the source's basename, rc 0, and mv then renames the link to avatar.png (quinn, iter 2).
mkdir -p "$AGENT_HOME_ROOT/agent-tau/.claude" "$TMP/rootonly3"
ln -s "$TMP/rootonly3" "$AGENT_HOME_ROOT/agent-tau/.claude/.avatar.png.$$"
out=$(_agent_avatar_install tau "$TMP/a.gif"); rc=$?
dst="$AGENT_HOME_ROOT/agent-tau/.claude/avatar.png"
[[ -z "$(ls -A "$TMP/rootonly3")" && ! -L "$dst" ]] && { (( rc == 1 )) || { [[ -f "$dst" ]] && cmp -s "$TMP/a.gif" "$dst"; }; } \
  && okk 'install does not follow a temp-name link to a directory' \
  || bad "temp dir-link arm: rc=$rc out=$out rootonly3=$(ls -A "$TMP/rootonly3") dst=$(ls -ld "$dst" 2>&1)"
mkdir -p "$AGENT_HOME_ROOT/agent-upsilon/.claude"; printf 'victim\n' >"$TMP/victim"
ln -s "$TMP/victim" "$AGENT_HOME_ROOT/agent-upsilon/.claude/.avatar.png.$$"
out=$(_agent_avatar_install upsilon "$TMP/a.gif"); rc=$?
[[ "$(cat "$TMP/victim")" == victim && ! -L "$AGENT_HOME_ROOT/agent-upsilon/.claude/avatar.png" ]] \
  && okk 'install does not write through a temp-name link to a file' || bad "temp file-link arm: rc=$rc out=$out victim=$(cat "$TMP/victim")"
# The ROOT branch (backfill from `5dive update`, `sudo 5dive agent avatar set`, get
# over the exec tunnel) must never touch an agent path as root: each check is a
# snapshot the agent can race (quinn, iter 3: a link swapped in during install's
# chmod-by-name made root chmod a 600 victim 644, 20/20). The harness is non-root,
# so it SIMULATES root: _agent_avatar_is_root says yes, `runuser` is a stub that
# marks what runs under it, and every file command is shadowed to log a call that
# names a path under the agent homes WITHOUT that mark. Any such call is a root
# syscall on an agent-controlled path, and the arm goes red.
AS_LOG="$TMP/as.log"; ROOT_LOG="$TMP/rootwrite.log"; : >"$AS_LOG"; : >"$ROOT_LOG"
as_root() { # <fn> <args...>: run one avatar function down its root branch
  (
    _agent_avatar_is_root() { return 0; }
    runuser() {
      [[ "$1" == -u && "$2" == agent-* && "$3" == -- ]] || { echo "BAD-RUNUSER $*" >>"$ROOT_LOG"; return 97; }
      echo "$2 ${4:-}" >>"$AS_LOG"; local _AS_USER="$2"; shift 3; "$@"
    }
    _watch() { # <cmd> <args...>
      local a; if [[ -z "${_AS_USER:-}" ]]; then
        for a in "${@:2}"; do [[ "$a" == *"$AGENT_HOME_ROOT"* ]] && { echo "ROOT $*" >>"$ROOT_LOG"; break; }; done
      fi
      command "$@"
    }
    for c in mkdir rm dd chmod chown mv install cp cat head find ln tee base64 touch; do
      eval "$c() { _watch $c \"\$@\"; }"
    done
    "$@"
  )
}
h="$AGENT_HOME_ROOT/agent-kappa"; mkdir -p "$h"
out=$(as_root _agent_avatar_install kappa "$TMP/a.gif"); rc=$?
(( rc == 0 )) && cmp -s "$TMP/a.gif" "$h/.claude/avatar.png" && [[ ! -s "$ROOT_LOG" ]] \
  && grep -q '^agent-kappa dd$' "$AS_LOG" && grep -q '^agent-kappa mv$' "$AS_LOG" && grep -q '^agent-kappa mkdir$' "$AS_LOG" \
  && okk 'root install: mkdir, temp write and rename all run as agent-kappa; root touches no agent path' \
  || bad "root install: rc=$rc out=$out root=[$(tr '\n' ';' <"$ROOT_LOG")] as=[$(tr '\n' ';' <"$AS_LOG")]"
: >"$AS_LOG"; : >"$ROOT_LOG"
out=$(as_root _agent_avatar_install kappa "$TMP/a.png"); rc=$?
(( rc == 0 )) && cmp -s "$TMP/a.png" "$h/.claude/avatar.png" && [[ ! -s "$ROOT_LOG" ]] \
  && okk 'root install replaces an existing portrait, still only as the agent' || bad "root replace: rc=$rc root=[$(tr '\n' ';' <"$ROOT_LOG")]"
# Backfill end to end down the root branch: walk, persona read, face.ref read, write.
: >"$AS_LOG"; : >"$ROOT_LOG"
h="$AGENT_HOME_ROOT/agent-lambda"; mkdir -p "$h/cards"
cp "$TMP/a.gif" "$h/cards/card.png"; cp "$TMP/inline.persona.yaml" "$h/cards/lambda.persona.yaml" 2>/dev/null \
  || printf 'id: lambda\nface: {ref: card.png, style: holo}\n' >"$h/cards/lambda.persona.yaml"
BF=$(
  registry_read() { printf '{"agents":{"lambda":{}}}\n'; }
  ensure_state_ro() { :; }; step() { echo "STEP: $*"; }; warn() { echo "WARN: $*"; }
  ok() { echo "OK: $1"; }; json_array() { :; }; fail() { echo "FAILCALL: $2"; exit 1; }
  STATE_DIR="$TMP" as_root _agent_avatar_backfill 2>&1
)
cmp -s "$TMP/a.gif" "$h/.claude/avatar.png" && [[ ! -s "$ROOT_LOG" ]] \
  && grep -q '^agent-lambda find$' "$AS_LOG" && grep -q '^agent-lambda head$' "$AS_LOG" && grep -q '^agent-lambda dd$' "$AS_LOG" \
  && okk 'root backfill walks, reads the persona and face.ref, and writes, all as the agent' \
  || bad "root backfill: $BF root=[$(tr '\n' ';' <"$ROOT_LOG")] as=[$(tr '\n' ';' <"$AS_LOG")]"
# Structural twin of the arms above (a redirection is not a command the shadows
# can see): inside _agent_avatar_install every write command is behind the drop,
# and the drop itself is runuser as agent-<agent>.
body=$(awk '/^_agent_avatar_install\(\)/{e=1} e{print} e&&/^}/{exit}' "$ROOT/src/cmd_agent_avatar.sh")
bare=$(grep -nE '(^|[;&|{(!]|&&|\|\|)[[:space:]]*(mkdir|rm|dd|chmod|chown|mv|install|cp|ln|touch)[[:space:]]' <<<"$body" | grep -v '^[0-9]*:[[:space:]]*#')
[[ -z "$bare" ]] && okk 'no write in _agent_avatar_install runs outside _agent_avatar_as' || bad "bare write in install: $bare"
grep -qE '^\s*runuser -u "agent-\$\{agent\}" -- "\$@"' "$ROOT/src/cmd_agent_avatar.sh" \
  && okk '_agent_avatar_as drops to agent-<agent> with runuser' || bad '_agent_avatar_as does not runuser to the agent'
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
# Root branch of get (the exec tunnel runs it as root): see as_root above.
: >"$AS_LOG"; : >"$ROOT_LOG"
G=$(JSON_MODE=1 as_root _agent_avatar_get kappa --data)
[[ "$(jq -r '.data.avatar.dataUri' <<<"$G")" == "data:image/png;base64,$(base64 -w0 "$TMP/a.png")" && ! -s "$ROOT_LOG" ]] \
  && grep -q '^agent-kappa head$' "$AS_LOG" \
  && okk 'root get reads avatar.png once, as the agent, and serves that copy' || bad "root get: ${G:0:200} root=[$(tr '\n' ';' <"$ROOT_LOG")]"

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

# --- backfill never replaces an existing entry, link or not ---------------
# Dry-run is enough: the skip is decided before the dry/real split, and a
# "would set" line for theta is exactly the root write quinn's probe landed.
h="$AGENT_HOME_ROOT/agent-theta"; mkdir -p "$h/.claude" "$h/cards" "$TMP/rootonly2"
png "$h/cards/card.png"; cp "$TMP/inline.persona.yaml" "$h/cards/theta.persona.yaml"
ln -s "$TMP/rootonly2" "$h/.claude/avatar.png"
h="$AGENT_HOME_ROOT/agent-iota"; mkdir -p "$h/.claude" "$h/cards"
png "$h/cards/card.png"; cp "$TMP/inline.persona.yaml" "$h/cards/iota.persona.yaml"
BF=$(
  registry_read() { printf '{"agents":{"theta":{},"iota":{}}}\n'; }
  ensure_state_ro() { :; }; step() { echo "STEP: $*"; }; warn() { echo "WARN: $*"; }
  ok() { echo "OK: $1"; }; json_array() { :; }; fail() { echo "FAILCALL: $2"; exit 1; }
  STATE_DIR="$TMP" _agent_avatar_backfill --dry-run 2>&1
)
[[ "$BF" != *"'theta'"* && "$BF" == *"would set 'iota'"* ]] \
  && okk 'backfill skips an avatar.png that is a symlink (and still sets a clean agent)' || bad "backfill link arm: $BF"

# --- DIVE-5413: a portrait hosted only on the box's own OpenAgent page -------
# ceo (lodar 10-02, a customer box): made his OpenAgent portrait in June, and
# the box serves it at https://<domain>/openagent/ceo.png, but no persona
# under his home names it. curl is stubbed: that one URL answers the image, every
# other path answers the box app's HTML (what a box with no /openagent route does).
printf 'FIVE_DOMAIN="pale-plain.5dive.com"\n' >"$TMP/provisioning.env"
mkdir -p "$TMP/site/openagent" "$AGENT_HOME_ROOT/agent-able/.claude" "$AGENT_HOME_ROOT/agent-ceo/.claude" "$AGENT_HOME_ROOT/agent-rook/.claude" "$TMP/state"
{ printf '\x89PNG\r\n\x1a\n'; head -c 3000 /dev/urandom; } >"$TMP/site/openagent/ceo.png"
: >"$TMP/state/avatar-backfill.v1.done" # the box already ran the persona-only pass
CURL_LOG="$TMP/curl.log"
oa_backfill() { # <provisioning.env> -> the backfill's output, down the root branch
  : >"$CURL_LOG"; : >"$AS_LOG"; : >"$ROOT_LOG"
  (
    curl() {
      local o="" u=""
      while (( $# )); do case "$1" in -o) o="$2"; shift 2 ;; --) u="$2"; shift 2 ;; *) shift ;; esac; done
      echo "$u" >>"$CURL_LOG"
      [[ -e "$TMP/site-down" ]] && return 7 # couldn't connect
      if [[ "$u" == https://pale-plain.5dive.com/openagent/*.png && -f "$TMP/site/openagent/${u##*/}" ]]; then
        command cp "$TMP/site/openagent/${u##*/}" "$o"; return 0
      fi
      [[ -e "$TMP/site-big" && "$u" == */able.png ]] && return 63 # able's portrait is over --max-filesize
      [[ -e "$TMP/site-404" ]] && return 22 # a box whose site 404s an unknown path
      printf '<!doctype html><title>5dive</title>' >"$o"
    }
    registry_read() { printf '{"agents":{"able":{},"ceo":{},"rook":{}}}\n'; }
    ensure_state_ro() { :; }; step() { echo "STEP: $*"; }; warn() { echo "WARN: $*"; }
    ok() { echo "OK: $1"; }; json_array() { :; }; fail() { echo "FAILCALL: $2"; exit 1; }
    AGENT_AVATAR_PROVISIONING="$1" STATE_DIR="$TMP/state" as_root _agent_avatar_backfill --once 2>&1
  )
}
BF=$(oa_backfill "$TMP/provisioning.env")
cmp -s "$TMP/site/openagent/ceo.png" "$AGENT_HOME_ROOT/agent-ceo/.claude/avatar.png" \
  && grep -qx 'https://pale-plain.5dive.com/openagent/ceo.png' "$CURL_LOG" \
  && okk "backfill copies a portrait served only at the box's /openagent/<agent>.png" \
  || bad "openagent backfill: $BF curl=[$(tr '\n' ';' <"$CURL_LOG")]"
[[ ! -s "$ROOT_LOG" ]] && grep -q '^agent-ceo dd$' "$AS_LOG" \
  && okk 'the openagent portrait is written as the agent; root touches no agent path' \
  || bad "openagent root write: root=[$(tr '\n' ';' <"$ROOT_LOG")] as=[$(tr '\n' ';' <"$AS_LOG")]"
[[ ! -e "$AGENT_HOME_ROOT/agent-rook/.claude/avatar.png" && "$BF" != *rook* && "$BF" == *"1 set, 0 unresolved"* ]] \
  && okk "a box page that answers HTML is no portrait, and not an 'unresolved' warning" || bad "rook arm: $BF"
[[ -e "$TMP/state/avatar-backfill.v2.done" && "$BF" != *already-ran* && "$BF" != *"already ran"* ]] \
  && okk 'a box that ran the persona-only pass (v1 marker) runs this one once, and marks v2' || bad "marker arm: $BF"
BF2=$(oa_backfill "$TMP/provisioning.env")
[[ "$BF2" == *"already ran"* && ! -s "$CURL_LOG" ]] && okk 'the v2 pass runs once per box' || bad "rerun: $BF2"
rm -f "$TMP/state/avatar-backfill.v2.done" "$AGENT_HOME_ROOT/agent-ceo/.claude/avatar.png"
BF3=$(oa_backfill "$TMP/nope.env")
[[ ! -s "$CURL_LOG" && ! -e "$AGENT_HOME_ROOT/agent-ceo/.claude/avatar.png" ]] \
  && okk 'no recorded domain, no fetch' || bad "no-domain arm: $BF3 curl=[$(tr '\n' ';' <"$CURL_LOG")]"
rm -f "$TMP/state/avatar-backfill.v2.done"; : >"$TMP/site-down"
BF4=$(oa_backfill "$TMP/provisioning.env"); rm -f "$TMP/site-down"
[[ "$(wc -l <"$CURL_LOG")" -eq 1 && ! -e "$AGENT_HOME_ROOT/agent-ceo/.claude/avatar.png" ]] \
  && okk "a box that cannot reach its own site is asked once, not once per agent" || bad "site-down arm: $BF4 curl=[$(tr '\n' ';' <"$CURL_LOG")]"
rm -f "$TMP/state/avatar-backfill.v2.done"; : >"$TMP/site-404"
BF5=$(oa_backfill "$TMP/provisioning.env"); rm -f "$TMP/site-404"
grep -q '/openagent/able.png$' "$CURL_LOG" && cmp -s "$TMP/site/openagent/ceo.png" "$AGENT_HOME_ROOT/agent-ceo/.claude/avatar.png" \
  && [[ "$BF5" != *able* ]] && okk "a 404 for one agent does not stop the next agent's fetch" || bad "404 arm: $BF5 curl=[$(tr '\n' ';' <"$CURL_LOG")]"
# An over-cap portrait is the site answering, not the site down: the earlier
# agent (able) is reported, and the later one (ceo) still gets its portrait.
rm -f "$TMP/state/avatar-backfill.v2.done" "$AGENT_HOME_ROOT/agent-ceo/.claude/avatar.png"; : >"$TMP/site-big"
BF6=$(oa_backfill "$TMP/provisioning.env"); rm -f "$TMP/site-big"
grep -q '/openagent/able.png$' "$CURL_LOG" && grep -q '/openagent/ceo.png$' "$CURL_LOG" \
  && cmp -s "$TMP/site/openagent/ceo.png" "$AGENT_HOME_ROOT/agent-ceo/.claude/avatar.png" \
  && [[ "$BF6" == *"WARN: could not set 'able'"*"over the cap"* && "$BF6" == *"1 set, 1 unresolved"* ]] \
  && okk "a portrait over the cap is reported unresolved and does not stop the next agent" || bad "63 arm: $BF6 curl=[$(tr '\n' ';' <"$CURL_LOG")]"
# A blip on the box's own site during the --once pass is not "done": the
# marker stays unwritten and the agents are reported, so the next update
# (site back up) still sets the portrait.
rm -f "$TMP/state/avatar-backfill.v2.done" "$AGENT_HOME_ROOT/agent-ceo/.claude/avatar.png"; : >"$TMP/site-down"
BF7=$(oa_backfill "$TMP/provisioning.env"); rm -f "$TMP/site-down"
[[ ! -e "$TMP/state/avatar-backfill.v2.done" && "$BF7" == *"WARN: could not reach this box's own site"* \
   && "$BF7" == *"0 set, 0 unresolved, 3 not checked"* ]] \
  && okk 'an unreachable own site leaves the --once marker unwritten and says so' || bad "site-down marker arm: $BF7"
BF8=$(oa_backfill "$TMP/provisioning.env")
cmp -s "$TMP/site/openagent/ceo.png" "$AGENT_HOME_ROOT/agent-ceo/.claude/avatar.png" && [[ -e "$TMP/state/avatar-backfill.v2.done" ]] \
  && okk 'the next update, with the site back, sets the portrait and marks the pass' || bad "site-up retry arm: $BF8"
printf 'FIVE_DOMAIN="evil.test/x?"\n' >"$TMP/bad.env"
AGENT_AVATAR_PROVISIONING="$TMP/bad.env" _agent_avatar_openagent_url ceo >/dev/null \
  && bad 'a malformed FIVE_DOMAIN made a URL' || okk 'a malformed FIVE_DOMAIN makes no URL'
# What the row asks for, end to end: after the update's pass, `agent list --json`
# reports the portrait at the one path, and `avatar get --data` serves its bytes.
rm -f "$TMP/state/avatar-backfill.v2.done"; BF=$(oa_backfill "$TMP/provisioning.env")
printf '{"agents":{"ceo":%s}}\n' "$row" >"$TMP/agents-oa.json"
OUT=$(python3 "$PY" "$TMP/agents-oa.json" "$TMP/profiles" "$TMP/connectors" "$AGENT_HOME_ROOT" "$TMP/sudoers" /default 2>/dev/null)
[[ "$(jq -r '.[0].avatar.path' <<<"$OUT")" == "$AGENT_HOME_ROOT/agent-ceo/.claude/avatar.png" \
   && "$(jq -r '.[0].avatar.bytes' <<<"$OUT")" == "$(stat -c %s "$TMP/site/openagent/ceo.png")" ]] \
  && okk 'agent list --json reports the OpenAgent portrait at avatar.png' || bad "list arm: $(jq -c '.[0].avatar' <<<"$OUT")"
G=$(JSON_MODE=1 _agent_avatar_get ceo --data)
[[ "$(jq -r '.data.avatar.dataUri' <<<"$G")" == "data:image/png;base64,$(base64 -w0 "$TMP/site/openagent/ceo.png")" ]] \
  && okk 'avatar get --data serves the OpenAgent portrait' || bad "get arm: ${G:0:200}"

# --- wiring ---------------------------------------------------------------
grep -q '^  src/cmd_agent_avatar.sh$' "$ROOT/build.sh" && okk 'module is bundled' || bad 'module missing from build.sh'
grep -q 'cmd_agent_avatar "\$@"' "$ROOT/src/main.sh" && okk '`agent avatar` is dispatched' || bad 'agent avatar not dispatched'
grep -q '_agent_avatar_install "\$agent" "\$avatar"' "$ROOT/src/cmd_cos.sh" \
  && okk 'cos set-avatar writes the same canonical file' || bad 'cos set-avatar does not write avatar.png'
grep -q 'agent avatar backfill --once' "$ROOT/src/cmd_selfupdate.sh" && okk '5dive update runs the one-time backfill' || bad 'backfill not wired into update'

echo "pass=$pass fail=$fail"
(( fail == 0 ))
