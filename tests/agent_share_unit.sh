#!/usr/bin/env bash
# DIVE-7782 — `agent share` / `agent unshare` / `config public-address` and the
# share routes of the box's page server. Grades: the refusal with no address,
# the recipe (what travels and what does not), the leak-scan refusal (never a
# trim), the public page, the static routes over real HTTP, unshare, and that
# `agent import --from-url=<share link>` never comes up admin.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""; SRV_PID=""
trap 'rc=$?; [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP=$(mktemp -d)
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/lib/validation.sh
# shellcheck source=/dev/null
source src/cmd_pack.sh
# shellcheck source=/dev/null
source src/cmd_secret_drop.sh
# shellcheck source=/dev/null
source src/cmd_agent_share.sh
set +e
JSON_MODE=0
SHARE_DIR="$TMP/shares"
SHARE_UNIT_DIR="$TMP/units"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }
has_t() { [[ "$2" == *"$3"* ]] && ok_t "$1" || bad_t "$1" "missing [$3] in: ${2:0:300}"; }
not_t() { [[ "$2" != *"$3"* ]] && ok_t "$1" || bad_t "$1" "unexpected [$3]"; }

# Stubs: root, the roster, the server start, the boot unit, the export itself.
require_root() { :; }
_pack_leak_roster() { printf 'zed\n'; }
_pack_leak_roster_generic() { :; }
_share_serve() { return 0; }
_share_boot_unit_install() { :; }
_agent_avatar_path() { printf '%s/fixture/%s.png' "$TMP" "$1"; }

# A fixture agent as `agent export --audience=publish` stages it.
fixture() { # <name> <claude-md-extra-line> [<skill-body-extra-line>]
  local d="$TMP/fixture/$1"; rm -rf "$d"; mkdir -p "$d/skills/research"
  jq -n --arg n "$1" '{packFormat:1, agentName:$n,
    config:{type:"claude", isolation:"admin", channels:"telegram", workdir:"/srv/x", authProfile:"ownerlogin", model:"opus"},
    plugins:{"telegram@5dive-plugins":true, "browser@5dive-browser":true, "x@y":false},
    skills:["research", "acme/tools:sheets"],
    hooks:{Stop:[{hooks:[{type:"command", command:"/opt/custom.sh"}]}]}}' > "$d/manifest.json"
  printf '# %s\nYou find leads and write them up.\n%s\n<!-- 5dive:team:begin (managed) -->\n- run sudo 5dive agent list\n<!-- 5dive:team:end -->\n' "$1" "$2" > "$d/CLAUDE.md"
  printf "openagent: '0.1'\nname: %s\nrole: Finds sales leads & writes <b>one-page</b> briefs\n" "${1^}" > "$d/persona.yaml"
  printf -- '---\nname: research\n---\nbody\n%s\n' "${3:-}" > "$d/skills/research/SKILL.md"
}
cmd_export() { # <name> --audience=publish -o <out>
  local n="$1" out=""
  [[ "$2" == --audience=publish ]] || { echo "not publish" >&2; return 1; }
  out="$4"; [[ -d "$TMP/fixture/$n" ]] || fail "$E_NOT_FOUND" "agent '$n' not found"
  (cd "$TMP/fixture/$n" && tar -czf "$out" .)
}

echo '== no public address: refused, with the two doors =='
_secret_drop_base_url() { return 1; }
fixture alpha ""
out=$( (cmd_agent_share alpha) 2>&1 ); rc=$?
eq_t 'no address exits E_CONFLICT' "$E_CONFLICT" "$rc"
has_t 'no address says why' "$out" "no public address, so a share link would not open"
has_t 'no address names the lead door' "$out" "Tell your lead agent your public address"
has_t 'no address names the command' "$out" "sudo 5dive config public-address=https://"
[[ ! -d "$SHARE_DIR" ]] && ok_t 'no address publishes nothing' || bad_t 'no address publishes nothing' "$(ls -R "$SHARE_DIR")"

echo '== share: the recipe =='
_secret_drop_base_url() { printf 'https://box.example.com'; }
printf 'PNGBYTES' > "$TMP/fixture/alpha.png"
out=$( (JSON_MODE=1; cmd_agent_share alpha) 2>/dev/null ); rc=$?
eq_t 'share exits 0' 0 "$rc"
url=$(jq -r '.data.url' <<<"$out"); id=$(jq -r '.data.id' <<<"$out")
[[ "$url" =~ ^https://box\.example\.com/a/[A-Za-z0-9_-]{22}$ ]] && ok_t "link is <address>/a/<22-char id> ($url)" || bad_t 'link shape' "$url"
d="$SHARE_DIR/$id"
for f in index.html pack.tar.gz avatar.png share.json; do [[ -f "$d/$f" ]] && ok_t "share has $f" || bad_t "share has $f"; done
mkdir -p "$TMP/x" && tar -xzf "$d/pack.tar.gz" -C "$TMP/x"
m=$(cat "$TMP/x/manifest.json")
eq_t 'copy is pinned to standard' standard "$(jq -r .config.isolation <<<"$m")"
eq_t 'no channels travel' none "$(jq -r .config.channels <<<"$m")"
eq_t 'no login travels' null "$(jq -c .config.authProfile <<<"$m")"
eq_t 'no workdir travels' null "$(jq -c .config.workdir <<<"$m")"
eq_t 'no hooks (custom scripts) travel' null "$(jq -c .hooks <<<"$m")"
eq_t 'marked community-made' true "$(jq -r .share.community_made <<<"$m")"
bad=$(cd "$TMP/x" && jq -r '.files | to_entries[] | "\(.key)\t\(.value)"' manifest.json | while IFS=$'\t' read -r p s; do [[ "$(sha256sum <"$p" | cut -d' ' -f1)" == "$s" ]] || echo "$p"; done)
eq_t 'checksums re-sealed after the trim' "" "$bad"
not_t 'managed block left out of CLAUDE.md' "$(cat "$TMP/x/CLAUDE.md")" "5dive:team:begin"
has_t 'own instructions travel' "$(cat "$TMP/x/CLAUDE.md")" "You find leads"

echo '== share: the page =='
p=$(cat "$d/index.html")
has_t 'page names the agent' "$p" "<h1>Alpha</h1>"
has_t 'page has the one-line job, escaped' "$p" "Finds sales leads &amp; writes &lt;b&gt;one-page&lt;/b&gt; briefs"
has_t 'page says community-made' "$p" "Community-made"
has_t 'page has ONE add button to the app, carrying the link' "$p" "href='https://my.5dive.ai/add?from=https%3A%2F%2Fbox.example.com%2Fa%2F${id}'"
eq_t 'exactly one add button' 1 "$(grep -o "class=add" <<<"$p" | wc -l)"
has_t 'page lists skills (short id)' "$p" "<li>sheets</li>"
has_t 'page lists enabled tools only' "$p" "<li>browser</li>"
not_t 'a disabled plugin is not listed' "$p" "<li>x</li>"
has_t 'page says what stays behind' "$p" "Logins, files, keys and private memory"
has_t 'page uses the portrait' "$p" "src='avatar.png'"
not_t 'page runs no script' "$p" "<script"
has_t 'page has a phone viewport' "$p" "width=device-width"

echo '== share again: same link, fresh page =='
out2=$( (JSON_MODE=1; cmd_agent_share alpha) 2>/dev/null )
eq_t 'resharing keeps the id' "$id" "$(jq -r '.data.id' <<<"$out2")"
eq_t 'one share dir for the agent' 1 "$(find "$SHARE_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l)"

echo '== a leaky agent is refused, never trimmed =='
fixture beta "Deploy notes live in /home/someone/notes and ping @zed."
out=$( (cmd_agent_share beta) 2>&1 ); rc=$?
eq_t 'leak exits E_VALIDATION' "$E_VALIDATION" "$rc"
has_t 'refusal names the line and kind' "$out" "CLAUDE.md:3: host-path: /home/someone"
has_t 'refusal says nothing was published' "$out" "Nothing was published"
_share_dir_of_agent beta >/dev/null && bad_t 'leaky agent has no share' || ok_t 'leaky agent has no share'
fixture delta "" "SSH to 62.238.117.176 as root, notes in /home/someone/notes, ping @zed"
out=$( (cmd_agent_share delta) 2>&1 ); rc=$?
eq_t 'leaky skill body exits E_VALIDATION' "$E_VALIDATION" "$rc"
has_t 'skill refusal names the skill file and line' "$out" "skills/research/SKILL.md:5: host-path: /home/someone"
has_t 'skill refusal names the address too' "$out" "skills/research/SKILL.md:5: hostname: 62.238.117.176"
has_t 'skill refusal says nothing was published' "$out" "Nothing was published"
_share_dir_of_agent delta >/dev/null && bad_t 'leaky skill body: nothing published' "$(ls -R "$SHARE_DIR")" || ok_t 'leaky skill body: nothing published'
fixture epsilon ""
printf 'see /root/.ssh/ for keys\n' > "$TMP/fixture/epsilon/notes.txt"
out=$( (cmd_agent_share epsilon) 2>&1 ); rc=$?
eq_t 'any other staged file is scanned too' "$E_VALIDATION" "$rc"
has_t 'other-file refusal names it' "$out" "notes.txt:1:"
fixture gamma "I am agent-gamma on this box."
(cmd_agent_share gamma) >/dev/null 2>&1 && ok_t "the agent's own account name is not a leak" || bad_t "own account name refused"

echo '== the page server serves shares =='
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
_secret_drop_server_py > "$TMP/server.py"
SHARE_DIR="$SHARE_DIR" python3 "$TMP/server.py" 127.0.0.1 "$port" /bin/false "$TMP/store" 0 2>/dev/null & SRV_PID=$!
for _ in $(seq 50); do curl -fs "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
B="http://127.0.0.1:$port"
h=$(curl -s -D - -o "$TMP/page.html" "$B/a/$id")
has_t 'GET /a/<id> is 200' "$h" "200"
has_t 'page is html' "$h" "Content-Type: text/html"
has_t 'page CSP allows only its own images' "$h" "img-src 'self'"
has_t 'page is cacheable briefly' "$h" "max-age=60"
cmp -s "$TMP/page.html" "$d/index.html" && ok_t 'served page is the file' || bad_t 'served page is the file'
curl -s -o "$TMP/p.tgz" "$B/a/$id/pack.tar.gz"; cmp -s "$TMP/p.tgz" "$d/pack.tar.gz" && ok_t 'pack served byte-for-byte' || bad_t 'pack served'
eq_t 'portrait served' PNGBYTES "$(curl -s "$B/a/$id/avatar.png")"
eq_t 'trailing slash serves the page' 200 "$(curl -s -o /dev/null -w '%{http_code}' "$B/a/$id/")"
eq_t 'unknown id is 404' 404 "$(curl -s -o /dev/null -w '%{http_code}' "$B/a/AAAAAAAAAAAAAAAAAAAAAA")"
eq_t 'share.json is not served' 404 "$(curl -s -o /dev/null -w '%{http_code}' "$B/a/$id/share.json")"
eq_t 'no path escape' 404 "$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$B/a/$id/../../../etc/passwd")"
mkdir -p "$SHARE_DIR/.probe"; : > "$SHARE_DIR/.probe/BBBBBBBBBBBBBBBBBBBBBB"
eq_t 'probe answers its nonce' BBBBBBBBBBBBBBBBBBBBBB "$(curl -s "$B/a/_probe/BBBBBBBBBBBBBBBBBBBBBB")"
eq_t 'an unknown probe is 404' 404 "$(curl -s -o /dev/null -w '%{http_code}' "$B/a/_probe/CCCCCCCCCCCCCCCCCCCCCC")"
rm -f "$SHARE_DIR/.probe/BBBBBBBBBBBBBBBBBBBBBB"
SHARE_DIR="$SHARE_DIR" SHARES="$SHARE_DIR" python3 -c "
import importlib.util,sys; sys.argv=['x','127.0.0.1','0','/bin/false','$TMP/store','0']
spec=importlib.util.spec_from_file_location('s','$TMP/server.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print('live' if m.live_links() else 'idle')" > "$TMP/live" 2>/dev/null
eq_t 'a live share keeps the page from idling out' live "$(cat "$TMP/live")"

echo '== import of a share link never comes up admin =='
_pack_fetch_url() { printf '%s' "$1" > "$TMP/fetched"; return 1; }
out=$( (cmd_import --from-url="https://box.example.com/a/$id" --as=al --isolation=admin) 2>&1 ); rc=$?
eq_t 'explicit admin on a share is refused' "$E_VALIDATION" "$rc"
has_t 'refusal says standard' "$out" "starts at standard, never admin"
[[ ! -f "$TMP/fetched" ]] && ok_t 'refused before any fetch' || bad_t 'refused before any fetch'
out=$( (cmd_import --from-url="https://box.example.com/a/$id" --as=al) 2>&1 )
eq_t 'the page link fetches the pack beside it' "https://box.example.com/a/$id/pack.tar.gz" "$(cat "$TMP/fetched" 2>/dev/null)"
has_t 'importer is told it is community-made' "$out" "community-made: it starts at standard"

echo '== unshare =='
out=$( (cmd_agent_unshare "$url") 2>&1 ); rc=$?
eq_t 'unshare by link exits 0' 0 "$rc"
[[ ! -d "$d" ]] && ok_t 'share dir removed' || bad_t 'share dir removed'
eq_t 'link is 404 after unshare' 404 "$(curl -s -o /dev/null -w '%{http_code}' "$B/a/$id")"
(cmd_agent_unshare alpha) >/dev/null 2>&1; eq_t 'unshare of an unshared agent is E_NOT_FOUND' "$E_NOT_FOUND" "$?"
gid=$(basename "$(_share_dir_of_agent gamma)")
(cmd_agent_unshare gamma) >/dev/null 2>&1; eq_t 'unshare by name exits 0' 0 "$?"
[[ ! -d "$SHARE_DIR/$gid" ]] && ok_t 'gamma removed' || bad_t 'gamma removed'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
