#!/usr/bin/env bash
# DIVE-8626: scripts/mirror-mac-app.sh copies the Mac app from 5dive-desktop's
# latest release onto this repo's Latest release, so
# github.com/5dive-ai/5dive/releases/latest/download/5dive.dmg serves it.
# Drives the REAL script; only `gh` (the network) is stubbed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/mirror-mac-app.sh"
TMP="$(mktemp -d)"
pass=0; fail=0
ok()  { printf '  ok   - %s\n' "$1"; pass=$((pass+1)); }
no()  { printf '  FAIL - %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail+1)); }

# Stub gh: `api <path>` prints $TMP/api/<path with / -> _>.json; download and
# upload are logged to $TMP/calls (download also writes the file it names).
mkdir -p "$TMP/bin" "$TMP/api"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls"
case "$1" in
  api) f="$STUB_DIR/api/$(tr '/' '_' <<< "$2").json"; [[ -f "$f" ]] || { echo "404 $2" >&2; exit 1; }; cat "$f" ;;
  release)
    if [[ "$2" == download ]]; then
      while [[ $# -gt 0 ]]; do case "$1" in -p) p="$2"; shift ;; -D) d="$2"; shift ;; esac; shift; done
      echo bytes > "$d/$p"
    fi ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" GITHUB_REPOSITORY=5dive-ai/5dive

src() { # src <dmg digest> [zip digest]  -> desktop latest release
  local zip=""
  [[ -n "${2:-}" ]] && zip=",{\"name\":\"5dive-mac.zip\",\"size\":20,\"digest\":\"$2\"}"
  printf '{"tag_name":"v0.2.0","assets":[{"name":"5dive.dmg","size":10,"digest":"%s"}%s]}' "$1" "$zip" \
    > "$TMP/api/repos_5dive-ai_5dive-desktop_releases_latest.json"
}
dst() { # dst <path-file-suffix> <tag> <assets json>
  printf '{"tag_name":"%s","assets":%s}' "$2" "$3" > "$TMP/api/repos_5dive-ai_5dive_releases_$1.json"
}
run() { : > "$TMP/calls"; out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?; }
uploads() { grep -c '^release upload' "$TMP/calls"; }

echo "1. fresh nightly Latest with no Mac files: both are copied onto IT"
src sha256:aaa sha256:zzz
dst latest v0.135.0 '[{"name":"5dive","size":1}]'
run
[[ $rc -eq 0 ]] && ok "exit 0" || no "exit 0" "rc=$rc out=$out"
[[ "$(uploads)" == 2 ]] && ok "two uploads" || no "two uploads" "$(cat "$TMP/calls")"
grep -q '^release upload v0.135.0 -R 5dive-ai/5dive .*/5dive.dmg --clobber' "$TMP/calls" \
  && ok "dmg uploaded onto this repo's Latest tag" || no "dmg upload target" "$(cat "$TMP/calls")"
grep -q '^release download v0.2.0 -R 5dive-ai/5dive-desktop -p 5dive-mac.zip' "$TMP/calls" \
  && ok "zip read from 5dive-desktop's latest tag" || no "zip source" "$(cat "$TMP/calls")"

echo "2. second run, same digests: no-op (the hourly run costs nothing)"
dst latest v0.135.0 '[{"name":"5dive.dmg","size":10,"digest":"sha256:aaa"},{"name":"5dive-mac.zip","size":20,"digest":"sha256:zzz"}]'
run
[[ $rc -eq 0 && "$(uploads)" == 0 ]] && ok "nothing uploaded" || no "idempotent" "rc=$rc $(cat "$TMP/calls")"

echo "3. new desktop build (dmg digest moved): only the dmg is replaced"
src sha256:bbb sha256:zzz
run
[[ $rc -eq 0 && "$(uploads)" == 1 ]] && grep -q 'upload .*5dive.dmg' "$TMP/calls" \
  && ok "dmg replaced, zip kept" || no "replace changed file" "rc=$rc $(cat "$TMP/calls")"

echo "4. no digest on one side: same size counts as same file"
dst latest v0.135.0 '[{"name":"5dive.dmg","size":10},{"name":"5dive-mac.zip","size":20}]'
run
[[ $rc -eq 0 && "$(uploads)" == 0 ]] && ok "size fallback" || no "size fallback" "rc=$rc $(cat "$TMP/calls")"

echo "5. a named tag targets releases/tags/<tag>, not Latest"
dst tags_v0.134.0 v0.134.0 '[]'
run v0.134.0
grep -q '^api repos/5dive-ai/5dive/releases/tags/v0.134.0' "$TMP/calls" && grep -q '^release upload v0.134.0 ' "$TMP/calls" \
  && ok "named tag" || no "named tag" "rc=$rc $(cat "$TMP/calls")"

echo "6. desktop release without the zip: refuse, upload nothing"
src sha256:bbb
dst latest v0.135.0 '[]'
run
[[ $rc -ne 0 && "$(uploads)" == 0 ]] && grep -q 'has no 5dive-mac.zip' <<< "$out" \
  && ok "missing source file is an error, nothing copied" || no "missing source" "rc=$rc out=$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
