#!/usr/bin/env bash
# DIVE-6800: the `5dive` .deb (packaging/deb/). What can be graded without
# root or a container: the package carries every file install.sh fetches from
# $REPO (a missing one is a fail-soft warning on a real box, so nothing else
# notices), the build is reproducible (the repo rebuilds old tags on every
# publish), a non-release tree is refused, and the README's apt lines are the
# two the container arm runs. The install, upgrade and signature arms run in
# .github/workflows/apt-repo.yml.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
tmp="$(mktemp -d)"
trap 'rc=$?; rm -rf "$tmp"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1" >&2; }

pk=packaging/deb

# 0. Every script parses.
for f in $pk/build-deb.sh $pk/build-repo.sh $pk/test-apt.sh $pk/5dive-setup; do
  if bash -n "$f"; then ok "parses: $f"; else bad "does not parse: $f"; fi
done
if sh -n $pk/postinst; then ok "parses: $pk/postinst (sh)"; else bad "does not parse: $pk/postinst"; fi

# A release-shaped tree from this checkout: a tag carries the built bundle,
# main does not, so a stand-in bundle carries the version.
tree="$tmp/tree"
mkdir -p "$tree/scripts/git-hooks-portable" "$tree/.github"
cp -a install.sh LICENSE bin prompts hooks systemd "$tree/"
cp -a scripts/install-pii-push-guard.sh scripts/pii-scan.sh "$tree/scripts/"
cp -a scripts/git-hooks-portable/pre-push scripts/git-hooks-portable/prepare-commit-msg "$tree/scripts/git-hooks-portable/"
cp -a .github/pii-denylist.txt "$tree/.github/"
printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="1.2.3"\n' > "$tree/5dive"

# 1. Builds, named and versioned from the bundle.
if deb="$(SOURCE_DATE_EPOCH=1700000000 bash $pk/build-deb.sh "$tree" "$tmp/a" 2>&1)" && [[ "$deb" == */5dive_1.2.3_all.deb ]]; then
  ok "builds 5dive_1.2.3_all.deb"
else
  bad "build failed or misnamed: $deb"; deb=""
fi
if [[ -n "$deb" ]]; then
  ctl="$(dpkg-deb -f "$deb" Package Version Architecture)"
  [[ "$ctl" == $'Package: 5dive\nVersion: 1.2.3\nArchitecture: all' ]] && ok "control: 5dive 1.2.3 all" || bad "control fields: $ctl"
  [[ "$(dpkg-deb -f "$deb" Description)" == *"sudo 5dive-setup"* ]] && ok "description names sudo 5dive-setup" || bad "description lost the setup command"

  # 2. Reproducible: same tree, same bytes — after a fresh checkout's mtimes.
  sleep 1; find "$tree" -exec touch -h {} +
  deb2="$(SOURCE_DATE_EPOCH=1700000000 bash $pk/build-deb.sh "$tree" "$tmp/b")"
  [[ "$(sha256sum <"$deb")" == "$(sha256sum <"$deb2")" ]] && ok "reproducible: two builds, one sha256" || bad "two builds of one tree differ"

  # 3. Every static $REPO/<path> install.sh fetches, every host script the
  #    manifest names and every hook is in the bundle.
  # Read whole, never piped into grep -q: under pipefail an early-exiting grep
  # SIGPIPEs dpkg-deb and reads as a miss.
  cont="$(dpkg-deb -c "$deb")"
  list="$(awk '{print $6}' <<<"$cont" | sed -n 's#^\./usr/share/5dive/bundle/##p')"
  want="$(grep -oE '\$REPO/[^" )]+' install.sh | sed 's#^\$REPO/##; s#\${PIN_BIN}#bin/#; s#\${PIN_PROMPTS}#prompts/#' \
          | grep -vE '\$|<|…|^5dive\.sha256$' | sort -u)" || want=""
  [[ -n "$want" ]] || bad "read no \$REPO paths from install.sh"
  want+=$'\n'"$(grep -vE '^\s*(#|$)' bin/host-scripts.manifest | awk '{print "bin/"$1}')"
  want+=$'\n'"$(cd hooks && ls | sed 's#^#hooks/#')"
  miss=""
  while read -r p; do [[ -z "$p" ]] || grep -qxF "$p" <<<"$list" || miss+=" $p"; done <<<"$want"
  [[ -z "$miss" ]] && ok "bundle carries all $(grep -c . <<<"$want") paths install.sh fetches" || bad "bundle is missing:$miss"
  grep -qxF 'systemd/5dive-agent%40.service' <<<"$list" && ok "unit reachable by its %40 name" || bad "no systemd/5dive-agent%40.service"
  grep -q ' \./usr/sbin/5dive-setup$' <<<"$cont" && ok "ships /usr/sbin/5dive-setup" || bad "no /usr/sbin/5dive-setup"
  awk '{print $1}' <<<"$cont" | grep -q '^d.....s' && bad "a setgid dir leaked into the package" || ok "no setgid dirs"
fi

# 4. A tree that is not a release is refused.
cp -a "$tree" "$tmp/dev"; printf 'readonly FIVE_VERSION="0.0.0-dev"\n' > "$tmp/dev/5dive"
if out="$(SOURCE_DATE_EPOCH=1 bash $pk/build-deb.sh "$tmp/dev" "$tmp/c" 2>&1)"; then bad "built from a 0.0.0-dev bundle"; else
  [[ "$out" == *"not a release version"* ]] && ok "refuses a 0.0.0-dev bundle" || bad "refused for the wrong reason: $out"; fi
rm "$tmp/dev/5dive"
if out="$(SOURCE_DATE_EPOCH=1 bash $pk/build-deb.sh "$tmp/dev" "$tmp/c" 2>&1)"; then bad "built with no bundle"; else
  [[ "$out" == *"build from a release TAG"* ]] && ok "refuses a tree with no built bundle" || bad "refused for the wrong reason: $out"; fi

# 5. The README's apt lines: exactly two, the same in both languages.
en="$(awk '/<!-- apt-lines:start -->/{s=1;next} /<!-- apt-lines:end -->/{s=0} s && !/^```/' README.md)"
[[ "$(grep -c . <<<"$en")" -eq 2 ]] && ok "README carries two apt lines" || bad "README apt lines: $en"
[[ "$en" == *"https://5dive-ai.github.io/5dive/apt stable main"* && "$en" == *"sudo apt install 5dive && sudo 5dive-setup"* ]] \
  && ok "README lines name the repo and the setup" || bad "README apt lines changed shape: $en"
zh_ok=1; while read -r l; do grep -qxF "$l" README.zh-CN.md || zh_ok=0; done <<<"$en"
(( zh_ok )) && ok "README.zh-CN carries the same two lines" || bad "README.zh-CN apt lines differ from README.md"

# 6. The upgrade arm's postinst match holds on apt's real output: dpkg runs on
#    a pty, so each line ends "\r\n" (5dive#1490's first CI run). Still exact.
apt_out=$'Setting up 5dive (0.108.0) ...\r\nNext: sudo 5dive-setup\r\nSetting up git (1:2.43.0) ...\r'
up_out=$'Next: sudo 5dive-setup (moves this box from 0.108.0 to 0.108.1)\r'
if ( . $pk/test-apt.sh
     said 'Next: sudo 5dive-setup' "$apt_out" \
     && said 'Next: sudo 5dive-setup (moves this box from 0.108.0 to 0.108.1)' "$up_out" \
     && ! said 'Next: sudo 5dive-setup' "$up_out" \
     && ! said 'Next: sudo 5dive-setup' $'xNext: sudo 5dive-setup\r' ); then
  ok "postinst line matched exactly on CRLF apt output"
else
  bad "postinst line match: misses CRLF apt output, or matches a different line"
fi

echo "# $pass passed, $fail failed"
(( fail == 0 ))
