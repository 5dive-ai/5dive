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
# The export, as the real one stages it: --audience=publish -o <out>, or (a
# --with-memory share) --audience=self --approve-memory=<dir> -o <out>, whose
# seal re-scopes the approved dir into memory/ and labels the manifest.
cmd_export() {
  local n="$1" out="" appr="" st; shift; printf '%s' "$*" > "$TMP/export.args"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --audience=publish) ;;
      --audience=self) [[ -n "${2:-}" && "$2" == --approve-memory=* ]] || { echo "self without memory" >&2; return 1; } ;;
      --approve-memory=*) appr="${1#--approve-memory=}" ;;
      -o) shift; out="$1" ;;
      *) echo "bad arg $1" >&2; return 1 ;;
    esac; shift
  done
  [[ -d "$TMP/fixture/$n" ]] || fail "$E_NOT_FOUND" "agent '$n' not found"
  st=$(mktemp -d); cp -a "$TMP/fixture/$n/." "$st/"
  if [[ -n "$appr" ]]; then
    _pack_scope_memory "$appr" "$st/memory" >/dev/null
    jq '.includes = {memory:"distilled", memoryShape:"atoms", persona:true}' "$st/manifest.json" > "$st/m" && mv "$st/m" "$st/manifest.json"
  fi
  (cd "$st" && tar -czf "$out" .); rm -rf "$st"
}
# The seat's memory store: $TMP/mem/<name>, one atom per fact.
_pack_memory_kind() { printf 'claude\n'; }
_pack_memory_dir() { [[ -d "$TMP/mem/$1" ]] && printf '%s' "$TMP/mem/$1"; }
atom() { # <name> <slug> <type> <body line>
  mkdir -p "$TMP/mem/$1"
  printf -- '---\nname: %s\ndescription: a fact\nmetadata:\n  type: %s\n---\n\n%s\n' "$2" "$3" "$4" > "$TMP/mem/$1/$2.md"
}
memfix() { # <name>: two knowledge facts, two private ones, an index
  rm -rf "$TMP/mem/$1"
  atom "$1" leads-first reference "Ask for the decision maker before the price."
  atom "$1" brief-shape project "A brief is one page: problem, offer, next step."
  atom "$1" owner-likes user "The owner is Ana Ruiz at /home/ana, ana@example.org."
  atom "$1" said-no feedback "Ana said: never call before 10am."
  printf '# index\n- [x](leads-first.md)\n' > "$TMP/mem/$1/MEMORY.md"
}
packlist() { tar -tzf "$1" 2>/dev/null | sed 's#^\./##' | grep -v '/$'; }

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

echo '== DIVE-7806: memory is opt-in, and goes through the same scan =='
fixture mia ""; memfix mia
# Arm 1: a default share carries none of it, though the seat has some.
out=$( (JSON_MODE=1; cmd_agent_share mia) 2>/dev/null ); rc=$?
eq_t '7806/1 default share exits 0' 0 "$rc"
mid=$(jq -r '.data.id' <<<"$out"); md="$SHARE_DIR/$mid"
eq_t '7806/1 default pack has no memory files' "" "$(packlist "$md/pack.tar.gz" | grep '^memory/')"
ea=$(cat "$TMP/export.args"); eq_t '7806/1 default export is the publish one, no memory' "--audience=publish -o" "${ea% *}"
eq_t '7806/1 default reports 0 memory' 0 "$(jq -r '.data.memory' <<<"$out")"
has_t '7806/1 page says it comes without memory' "$(cat "$md/index.html")" "it comes without its memory"
# Arm 2: --with-memory on a clean store carries the knowledge, never the private.
out=$( (JSON_MODE=1; cmd_agent_share mia --with-memory) 2>/dev/null ); rc=$?
eq_t '7806/2 --with-memory exits 0' 0 "$rc"
eq_t '7806/2 same link as before' "$mid" "$(jq -r '.data.id' <<<"$out")"
mem_in_pack=$(packlist "$md/pack.tar.gz" | grep '^memory/' | grep -v 'MEMORY.md$' | sort)
eq_t '7806/2 pack holds the 2 knowledge atoms' "memory/brief-shape.md memory/leads-first.md" "$(echo $mem_in_pack)"
not_t '7806/2 a user fact never travels' "$mem_in_pack" "owner-likes"
not_t '7806/2 a feedback fact never travels' "$mem_in_pack" "said-no"
eq_t '7806/2 --json counts 2' 2 "$(jq -r '.data.memory' <<<"$out")"
eq_t '7806/2 share.json counts 2' 2 "$(jq -r '.memory' "$md/share.json")"
has_t '7806/2 page says it comes with what it learned' "$(cat "$md/index.html")" "Comes with what it learned: 2 notes."
rm -rf "$TMP/m2"; mkdir -p "$TMP/m2" && tar -xzf "$md/pack.tar.gz" -C "$TMP/m2"
eq_t '7806/2 manifest says distilled (import seeds on this)' distilled "$(jq -r .includes.memory "$TMP/m2/manifest.json")"
bad=$(cd "$TMP/m2" && jq -r '.files | to_entries[] | "\(.key)\t\(.value)"' manifest.json | while IFS=$'\t' read -r p s; do [[ "$(sha256sum <"$p" | cut -d' ' -f1)" == "$s" ]] || echo "$p"; done)
eq_t '7806/2 memory files are in the sealed checksums' "" "$bad"
eq_t '7806/2 checksums list the memory files' 3 "$(jq '[.files | keys[] | select(startswith("memory/"))] | length' "$TMP/m2/manifest.json")"
# The import's own seeding step (cmd_import -> _pack_seed_claude_memory) on the pack.
seat="$TMP/seat/projects/-home-agent-new/memory"
landed=$(_pack_seed_claude_memory "$TMP/m2/memory" "$seat" atoms)
eq_t '7806/2 import lands every packed file (2 atoms + index)' 3 "$landed"
eq_t '7806/2 new seat store holds the 2 atoms' 2 "$(find "$seat" -name '*.md' ! -name MEMORY.md | wc -l)"
# A seat with nothing it learned: shared without memory, said so, not refused.
fixture noor ""; rm -rf "$TMP/mem/noor"; atom noor only-private user "likes tea"
out=$( (cmd_agent_share noor --with-memory) 2>&1 ); rc=$?
eq_t '7806/2 nothing to share yet still shares' 0 "$rc"
has_t '7806/2 ...and says why there is no memory' "$out" "nothing it learned to share yet"
eq_t '7806/2 ...with no memory files' "" "$(packlist "$(_share_dir_of_agent noor)/pack.tar.gz" | grep '^memory/')"
# A long-lived seat: enough facts that the checksum map is over one argv
# string's 128 KB (a real 2.8k-fact seat hit "Argument list too long").
fixture big ""; rm -rf "$TMP/mem/big"; mkdir -p "$TMP/mem/big"
for i in $(seq 1 1600); do printf -- '---\nname: f%s\nmetadata:\n  type: reference\n---\nLesson number %s.\n' "$i" "$i" > "$TMP/mem/big/a-long-fact-name-number-$i.md"; done
out=$( (JSON_MODE=1; cmd_agent_share big --with-memory) 2>&1 ); rc=$?
eq_t '7806/2 a 1600-fact store shares' 0 "$rc"
eq_t '7806/2 ...carrying all 1600' 1600 "$(jq -r '.data.memory' <<<"$(grep '^{' <<<"$out" | tail -1)")"
rm -rf "$TMP/mb"; mkdir -p "$TMP/mb" && tar -xzf "$(_share_dir_of_agent big)/pack.tar.gz" -C "$TMP/mb"
eq_t '7806/2 ...each one in the sealed checksums' 1601 "$(jq '[.files | keys[] | select(startswith("memory/"))] | length' "$TMP/mb/manifest.json")"
(cmd_agent_unshare big) >/dev/null 2>&1
# DIVE-7813: the distil reads every fact in ONE awk pass. A directory named
# *.md in the store must be left out unread, on mawk too: mawk dies on a
# getline from a directory (gawk only warns), and that death would drop every
# fact after it.
if command -v mawk >/dev/null 2>&1; then
  mkdir -p "$TMP/mawkbin" "$TMP/mem/mk/odd.md"; ln -sf "$(command -v mawk)" "$TMP/mawkbin/awk"
  atom mk zz-last reference "The last fact still lands."; atom mk aa-first project "So does the first."
  got=$(PATH="$TMP/mawkbin:$PATH" _pack_scope_memory "$TMP/mem/mk" "$TMP/mk-out")
  eq_t '7813 mawk: a *.md directory is left out, both facts kept' "2 1" "$got"
  eq_t '7813 mawk: ...and both are in the index' 2 "$(grep -c '^- \[' "$TMP/mk-out/MEMORY.md")"
else
  ok_t '7813 mawk arm skipped: no mawk on this runner'
fi
# Arm 3: one leaky line in a knowledge fact refuses the WHOLE share, names it.
leak_arm() { # <agent> <line> <expected file:line: kind>
  fixture "$1" ""; memfix "$1"; atom "$1" deploy-notes project "$2"
  out=$( (cmd_agent_share "$1" --with-memory) 2>&1 ); rc=$?
  eq_t "7806/3 [$1] refused E_VALIDATION" "$E_VALIDATION" "$rc"
  has_t "7806/3 [$1] names memory file:line" "$out" "$3"
  has_t "7806/3 [$1] says nothing was published" "$out" "Nothing was published"
  _share_dir_of_agent "$1" >/dev/null && bad_t "7806/3 [$1] no share dir" "$(ls "$SHARE_DIR")" || ok_t "7806/3 [$1] no share dir"
}
leak_arm lpath "Notes sit in /home/ana/notes now." "memory/deploy-notes.md:8: host-path: /home/ana"
leak_arm lhost "The crm lives at crm.acme-corp.com for us." "memory/deploy-notes.md:8: hostname: crm.acme-corp.com"
leak_arm lmail "Send briefs to ana.ruiz@acmecorp.co on Fridays." "memory/deploy-notes.md:8: identity-name: ana.ruiz@acmecorp.co"
# A leak in a PRIVATE fact never reaches the stage, so it cannot refuse.
fixture priv ""; memfix priv
(cmd_agent_share priv --with-memory) >/dev/null 2>&1 && ok_t '7806/3 a private fact is left behind, not scanned into a refusal' || bad_t '7806/3 private fact refused'
# Arm 5 (mutation, in-harness): drop memory/ from the scan list and arm 3 publishes.
orig_scan=$(declare -f _share_scan)
eval "$(printf '%s\n' "$orig_scan" | sed 's#--exclude=./manifest.json#--exclude=./manifest.json --exclude=./memory#')"
fixture mut ""; memfix mut; atom mut deploy-notes project "Notes sit in /home/ana/notes now."
(cmd_agent_share mut --with-memory) >/dev/null 2>&1; mrc=$?
eval "$orig_scan"
[[ "$mrc" == 0 ]] && _share_dir_of_agent mut >/dev/null \
  && ok_t '7806/5 mutant (memory dropped from the scan) publishes the leak: arm 3 would go red' \
  || bad_t '7806/5 mutation not caught' "rc=$mrc"
(cmd_agent_unshare mut) >/dev/null 2>&1

echo '== import of a share link never comes up admin =='
_pack_fetch_url() { printf '%s' "$1" > "$TMP/fetched"; return 1; }
out=$( (cmd_import --from-url="https://box.example.com/a/$id" --as=al --isolation=admin) 2>&1 ); rc=$?
eq_t 'explicit admin on a share is refused' "$E_VALIDATION" "$rc"
has_t 'refusal says standard' "$out" "starts at standard, never admin"
[[ ! -f "$TMP/fetched" ]] && ok_t 'refused before any fetch' || bad_t 'refused before any fetch'
out=$( (cmd_import --from-url="https://box.example.com/a/$id" --as=al) 2>&1 )
eq_t 'the page link fetches the pack beside it' "https://box.example.com/a/$id/pack.tar.gz" "$(cat "$TMP/fetched" 2>/dev/null)"
has_t 'importer is told it is community-made' "$out" "community-made: it starts at standard"

echo '== DIVE-7806: unshare removes the memory from what is served =='
curl -s -o "$TMP/mp.tgz" "$B/a/$mid/pack.tar.gz"
eq_t '7806/4 served pack carries the memory before unshare' 2 "$(packlist "$TMP/mp.tgz" | grep '^memory/' | grep -vc 'MEMORY.md$')"
(cmd_agent_share mia) >/dev/null 2>&1
curl -s -o "$TMP/mp.tgz" "$B/a/$mid/pack.tar.gz"
eq_t '7806/4 sharing again without the flag drops it' "" "$(packlist "$TMP/mp.tgz" | grep '^memory/')"
(cmd_agent_share mia --with-memory) >/dev/null 2>&1
(cmd_agent_unshare mia) >/dev/null 2>&1; eq_t '7806/4 unshare exits 0' 0 "$?"
eq_t '7806/4 pack is 404 after unshare' 404 "$(curl -s -o /dev/null -w '%{http_code}' "$B/a/$mid/pack.tar.gz")"
eq_t '7806/4 no memory file left on disk' "" "$(find "$SHARE_DIR" -path '*memory*' 2>/dev/null)"

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
