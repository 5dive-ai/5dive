#!/usr/bin/env bash
# DIVE-6800: build the `5dive` .deb from ONE release tree.
#
#   packaging/deb/build-deb.sh <release-tree> <out-dir>
#
# <release-tree> is a checkout of a release tag (vX.Y.Z): those trees carry the
# BUILT bundle `5dive` (main does not, DIVE-2091). The version is read from it,
# so the package version is the CLI version and cannot drift from it.
#
# WHAT THE PACKAGE IS. It does not lay the box out itself. It ships the tag's
# installer bundle to /usr/share/5dive/bundle — the same set docker/Dockerfile
# stages at /opt/5dive-bundle — and `5dive-setup` runs that tag's install.sh
# against it (REPO=file://…). install.sh stays the one place that knows how a
# box is laid out; this script only decides what goes in the bundle.
#
# Debian norms (the row's ask): the maintainer scripts fetch nothing and create
# no user. postinst prints one line; the box setup, which does both, is the
# owner's own `sudo 5dive-setup`.
#
# REPRODUCIBLE ON PURPOSE. build-repo.sh rebuilds the last few tags on every
# publish instead of storing the old .debs anywhere, so a rebuild of the same
# tag must give the same bytes: an apt client holding yesterday's Packages
# index would otherwise get a hash mismatch on a file whose version never
# changed. Every mtime is clamped to the tag's commit time and dpkg-deb gets
# SOURCE_DATE_EPOCH; tests/apt_package_unit.sh builds twice and compares.
set -euo pipefail

die() { echo "build-deb: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: build-deb.sh <release-tree> <out-dir>"
tree="$(cd "$1" && pwd)" || die "no such tree: $1"
out="$2"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$tree/5dive" ]] || die "$tree/5dive is missing — build from a release TAG, which carries the built bundle"
ver="$(grep -m1 'readonly FIVE_VERSION=' "$tree/5dive" | sed -E 's/.*="([^"]+)".*/\1/')" || ver=""
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the bundle's FIVE_VERSION is '${ver}', not a release version"
[[ -f "$tree/bin/host-scripts.manifest" ]] || die "$tree has no bin/host-scripts.manifest — tags before the DIVE-6849 layout are not packaged"

if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH="$(git -C "$tree" log -1 --format=%ct HEAD 2>/dev/null)" \
    || die "SOURCE_DATE_EPOCH unset and $tree is not a git checkout"
fi
export SOURCE_DATE_EPOCH

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
root="$stage/root"
bundle="$root/usr/share/5dive/bundle"
install -d "$bundle" "$root/DEBIAN" "$root/usr/sbin" "$root/usr/share/doc/5dive"

# The bundle: every path install.sh fetches as $REPO/<path>. Dockerfile's COPY
# list plus the pii-guard files it leaves to install.sh's fail-soft branch.
# tests/apt_package_unit.sh checks this list against install.sh's own fetches.
cp -a "$tree/5dive" "$tree/install.sh" "$bundle/"
[[ -f "$tree/5dive.sha256" ]] && cp -a "$tree/5dive.sha256" "$bundle/"
for d in bin prompts hooks systemd; do
  cp -a "$tree/$d" "$bundle/$d"
done
install -d "$bundle/scripts/git-hooks-portable" "$bundle/.github"
cp -a "$tree/scripts/install-pii-push-guard.sh" "$tree/scripts/pii-scan.sh" "$bundle/scripts/"
cp -a "$tree/scripts/git-hooks-portable/pre-push" "$tree/scripts/git-hooks-portable/prepare-commit-msg" \
  "$bundle/scripts/git-hooks-portable/"
cp -a "$tree/.github/pii-denylist.txt" "$bundle/.github/"
# install.sh fetches the unit as 5dive-agent%40.service; curl's file:// decodes
# %40 to @, so a symlink makes both names resolve (same as docker/Dockerfile).
ln -sf 5dive-agent@.service "$bundle/systemd/5dive-agent%40.service"

install -m 755 "$here/5dive-setup" "$root/usr/sbin/5dive-setup"
install -m 755 "$here/postinst" "$root/DEBIAN/postinst"
install -m 644 "$tree/LICENSE" "$root/usr/share/doc/5dive/copyright"

# Depends = install.sh's APT_PKGS, so its apt step finds them all present and
# skips (no apt run inside a setup apt itself started), plus what it calls
# without installing: sudo, gpg-less curl over TLS, bash.
cat > "$root/DEBIAN/control" <<EOF
Package: 5dive
Version: $ver
Architecture: all
Maintainer: 5dive <noreply@5dive.ai>
Depends: bash, ca-certificates, curl, sudo, jq, tmux, git, python3-yaml, unzip, sqlite3, acl, cron, systemd
Section: admin
Priority: optional
Homepage: https://github.com/5dive-ai/5dive
Description: a team of AI agents on one box
 5dive runs AI agents (Claude Code, Codex, and others) as services on this
 machine, each with its own Linux user, chat channel and task board.
 .
 This package installs the 5dive CLI bundle. Run: sudo 5dive-setup once
 to set up the box; run it again after an upgrade to apply the new version.
EOF

find "$root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
chmod -R u+rwX,go+rX,go-w,g-s "$root"
install -d "$out"
deb="$out/5dive_${ver}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "$root" "$deb" >/dev/null
echo "$deb"
