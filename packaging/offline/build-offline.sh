#!/usr/bin/env bash
# DIVE-7577: build the update file a local-only box installs from a USB disk.
#
#   packaging/offline/build-offline.sh <release-tree> <plugins-tree> <skills-tree> <bun> <out-dir> [<signing-key.pem>]
#
# <release-tree>  a checkout of a release tag (it carries the BUILT `5dive`)
# <plugins-tree>  a 5dive-plugins checkout whose plugins already have their
#                 node_modules (the workflow runs `bun install` first). Refused
#                 if any plugin is missing a dependency: offline, a plugin with
#                 no node_modules falls back to `bun install` and dials the npm
#                 registry (DIVE-7559), so a file without them is not offline.
# <skills-tree>   a checkout of the skills repo
# <bun>           the bun binary the plugins run on
# <signing-key>   the ed25519 private key (PEM). Without it the file is built
#                 UNSIGNED, and every box refuses an unsigned file.
#
# Prints the path of <out-dir>/5dive-offline-<version>.tar. The format is read
# by src/lib/offline_update.sh (_ou_verify); change the two together.
#
# DIVE-7665: the file is that tar, GZIPPED as a whole (the name stays .tar).
# bun is 102 MB stored raw and the rest is already gzipped, so the outer gzip
# is bun's: 144 MB -> about 83 MB. The members, the manifest and the signature
# are exactly format 1, and GNU tar reads a gzipped archive from a file with the
# same `tar -tvf`/`tar -xf` and no flag, so every reader already installed
# (0.117.0's _ou_verify, build-usb.sh, the USB starter) opens it unchanged.
# Source maps (*.map) in the plugins' node_modules are dropped: nothing runs
# them and they were 46 MB of the plugins, 8 MB packed.
set -euo pipefail

die() { echo "build-offline: $*" >&2; exit 1; }

[[ $# -eq 5 || $# -eq 6 ]] || die "usage: build-offline.sh <release-tree> <plugins-tree> <skills-tree> <bun> <out-dir> [<signing-key.pem>]"
tree="$(cd "$1" && pwd)" || die "no such tree: $1"
plugins="$(cd "$2" && pwd)" || die "no such plugins tree: $2"
skills="$(cd "$3" && pwd)" || die "no such skills tree: $3"
bun="$4"; out="$5"; key="${6:-}"

[[ -f "$tree/5dive" ]] || die "$tree/5dive is missing — build from a release TAG, which carries the built bundle"
ver="$(grep -m1 'readonly FIVE_VERSION=' "$tree/5dive" | sed -E 's/.*="([^"]+)".*/\1/')" || ver=""
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the bundle's FIVE_VERSION is '${ver}', not a release version"
# install.sh checks $REPO/5dive against $REPO/5dive.sha256 and refuses on a
# mismatch, so a pair that disagrees here is an install that fails on the box
# (DIVE-7598: CI rewrote the version in 5dive and kept the old hash). Refuse it
# at build time instead.
if [[ -f "$tree/5dive.sha256" ]]; then
  want="$(tr -d '[:space:]' < "$tree/5dive.sha256")"
  got="$(sha256sum "$tree/5dive" | awk '{print $1}')"
  [[ "$want" == "$got" ]] || die "$tree/5dive.sha256 does not match $tree/5dive (want ${want:0:16}…, got ${got:0:16}…) — re-hash it after any change to 5dive"
fi
[[ -f "$tree/bin/host-scripts.manifest" ]] || die "$tree has no bin/host-scripts.manifest — tags before the DIVE-6849 layout are not packaged"
grep -q '^offline_update()' "$tree/install.sh" || die "$tree/install.sh predates updates from a file (DIVE-7577) — it would dial out during the update; package a newer tag"
[[ -f "$plugins/.claude-plugin/marketplace.json" ]] || die "$plugins is not a 5dive-plugins checkout"
[[ -f "$skills/5dive-cli/SKILL.md" ]] || die "$skills has no 5dive-cli skill"
[[ -x "$bun" && -s "$bun" ]] || die "no bun binary at $bun"
[[ -z "$key" || -s "$key" ]] || die "no signing key at $key"

# Every plugin's dependencies present (the same test the box's offline start
# makes, src/lib/local_only.sh plugin_deps_complete).
missing=""
for d in "$plugins"/plugins/*/; do
  [[ -f "$d/package.json" ]] || continue
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    [[ -f "$d/node_modules/$dep/package.json" ]] || missing+=" $(basename "$d"):$dep"
  done < <(jq -r '(.dependencies // {}) | keys[]' "$d/package.json")
done
[[ -z "$missing" ]] || die "plugins are missing dependencies (run bun install in each first):$missing"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
install -d "$stage/payload" "$stage/cli" "$stage/plugins/5dive-plugins-main" "$stage/skills/skills-main"
TARD=(--sort=name --owner=0 --group=0 --numeric-owner)

# The CLI: every path install.sh reads as $REPO/<path> — the same set as
# packaging/deb/build-deb.sh's bundle (tests/apt_package_unit.sh grades that
# list against install.sh's own fetches).
c="$stage/cli"
cp -a "$tree/5dive" "$tree/install.sh" "$c/"
[[ -f "$tree/5dive.sha256" ]] && cp -a "$tree/5dive.sha256" "$c/"
for d in bin prompts hooks systemd; do cp -a "$tree/$d" "$c/$d"; done
install -d "$c/scripts/git-hooks-portable" "$c/.github"
cp -a "$tree/scripts/install-pii-push-guard.sh" "$tree/scripts/pii-scan.sh" "$c/scripts/"
cp -a "$tree/scripts/git-hooks-portable/pre-push" "$tree/scripts/git-hooks-portable/prepare-commit-msg" "$c/scripts/git-hooks-portable/"
cp -a "$tree/.github/pii-denylist.txt" "$c/.github/"
ln -sf 5dive-agent@.service "$c/systemd/5dive-agent%40.service"
tar "${TARD[@]}" -czf "$stage/payload/cli.tar.gz" -C "$c" .

# The plugins, WITH node_modules, under the top folder install.sh's tarball
# filters name (5dive-plugins-main/…). No .git: a box gets files, not history.
tar -C "$plugins" --exclude=./.git -cf - . | tar -C "$stage/plugins/5dive-plugins-main" -xf -
find "$stage/plugins/5dive-plugins-main" -path '*/node_modules/*' -type f -name '*.map' -delete
tar "${TARD[@]}" -czf "$stage/payload/plugins.tar.gz" -C "$stage/plugins" 5dive-plugins-main
tar -C "$skills" --exclude=./.git -cf - . | tar -C "$stage/skills/skills-main" -xf -
tar "${TARD[@]}" -czf "$stage/payload/skills.tar.gz" -C "$stage/skills" skills-main
install -m 755 "$bun" "$stage/payload/bun"

files='{}'
for p in payload/bun payload/cli.tar.gz payload/plugins.tar.gz payload/skills.tar.gz; do
  files="$(jq -c --arg p "$p" --arg h "$(sha256sum "$stage/$p" | awk '{print $1}')" '. + {($p): $h}' <<<"$files")"
done
# The processor bun and the plugins' native packages were built for: this
# machine's, unless OFFLINE_ARCH says otherwise. A box of another kind refuses it.
arch="${OFFLINE_ARCH:-$(uname -m)}"
jq -n --arg v "$ver" --arg a "$arch" --arg c "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson f "$files" \
  '{format: 1, version: $v, arch: $a, created: $c, files: $f}' > "$stage/manifest.json"

members=(manifest.json)
if [[ -n "$key" ]]; then
  openssl pkeyutl -sign -inkey "$key" -rawin -in "$stage/manifest.json" -out "$stage/manifest.sig" \
    || die "signing failed (the key must be an ed25519 private key in PEM)"
  openssl pkey -in "$key" -pubout -out "$stage/pub.pem"
  openssl pkeyutl -verify -pubin -inkey "$stage/pub.pem" -rawin -in "$stage/manifest.json" -sigfile "$stage/manifest.sig" >/dev/null \
    || die "the signature does not verify against its own key"
  members+=(manifest.sig)
else
  echo "build-offline: no signing key — the file is UNSIGNED and every box will refuse it" >&2
fi
members+=(payload/bun payload/cli.tar.gz payload/plugins.tar.gz payload/skills.tar.gz)

install -d "$out"
f="$out/5dive-offline-$ver.tar"
tar "${TARD[@]}" --no-recursion -cf - -C "$stage" "${members[@]}" | gzip -9n > "$f.tmp"
mv -f "$f.tmp" "$f"
echo "$f"
