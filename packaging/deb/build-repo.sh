#!/usr/bin/env bash
# DIVE-6800: lay out and sign the apt repository from a directory of .debs.
#
#   packaging/deb/build-repo.sh <debs-dir> <out-dir> [<live-base-url>]
#
# Signs with the secret key GPG already holds for $APT_GPG_KEY_ID (fingerprint),
# in $GNUPGHOME. The CI job imports it from the APT_SIGNING_KEY secret; the PR
# arm and tests/apt_package_unit.sh make a throwaway one.
#
# Output (served at <base>/, e.g. https://5dive-ai.github.io/5dive/apt):
#   5dive.gpg                         the public key, binary, for signed-by=
#   5dive.asc                         the same key, armored, for humans
#   pool/main/5/5dive/*.deb
#   dists/stable/{InRelease,Release,Release.gpg}
#   dists/stable/main/binary-{amd64,arm64}/Packages{,.gz} + by-hash/SHA256/
#
# The package is Architecture: all. It is listed under every binary-<arch>
# (Debian's own "No-Support-for-Architecture-all: Packages" shape) rather than
# under a binary-all apt might or might not fetch.
#
# WHY BY-HASH, AND WHY THE LIVE ONES ARE CARRIED. GitHub Pages caches every file
# for up to 10 minutes, each on its own clock, so right after a publish a client
# can read the NEW InRelease next to the OLD Packages (or the reverse) and apt
# stops on "Hash Sum mismatch". With Acquire-By-Hash apt fetches each index by
# its hash, a path whose bytes never change, so the only thing left to get right
# is that the hash a cached InRelease names still exists. A Pages deploy
# replaces the whole site, so <live-base-url>'s current by-hash files are fetched
# and published again beside the new ones. Fail-soft: the first publish has none.
set -euo pipefail

die() { echo "build-repo: $*" >&2; exit 1; }

[[ $# -ge 2 && $# -le 3 ]] || die "usage: build-repo.sh <debs-dir> <out-dir> [<live-base-url>]"
debs="$(cd "$1" && pwd)" || die "no such dir: $1"
out="$2"
live="${3:-}"
: "${APT_GPG_KEY_ID:?APT_GPG_KEY_ID (the signing key fingerprint) is required}"

SUITE=stable
COMP=main
ARCHES=(amd64 arm64)

compgen -G "$debs/5dive_*_all.deb" >/dev/null || die "no 5dive_*_all.deb in $debs"
rm -rf "$out"
install -d "$out/pool/$COMP/5/5dive"
cp "$debs"/5dive_*_all.deb "$out/pool/$COMP/5/5dive/"

cd "$out"
for a in "${ARCHES[@]}"; do
  d="dists/$SUITE/$COMP/binary-$a"
  install -d "$d"
  apt-ftparchive packages "pool/$COMP" > "$d/Packages"
  gzip -9n < "$d/Packages" > "$d/Packages.gz"
  install -d "$d/by-hash/SHA256"
  for f in Packages Packages.gz; do
    cp "$d/$f" "$d/by-hash/SHA256/$(sha256sum "$d/$f" | cut -d' ' -f1)"
  done
done

# Carry the live site's by-hash indexes (see the header).
if [[ -n "$live" ]]; then
  if rel="$(curl -fsSL --max-time 30 "$live/dists/$SUITE/Release" 2>/dev/null)"; then
    # SHA256 section lines: " <hash> <size> main/binary-amd64/Packages.gz"
    awk '/^SHA256:/{s=1;next} /^[^ ]/{s=0} s{print $1, $3}' <<<"$rel" \
      | while read -r h p; do
          [[ "$h" =~ ^[0-9a-f]{64}$ && "$p" =~ ^$COMP/binary-[a-z0-9]+/Packages(\.gz)?$ ]] || continue
          dst="dists/$SUITE/${p%/*}/by-hash/SHA256/$h"
          [[ -d "${dst%/*}" && ! -f "$dst" ]] || continue
          tmp="$(mktemp)"
          if curl -fsSL --max-time 30 -o "$tmp" "$live/dists/$SUITE/${p%/*}/by-hash/SHA256/$h" \
             && [[ "$(sha256sum "$tmp" | cut -d' ' -f1)" == "$h" ]]; then
            mv "$tmp" "$dst"; chmod 644 "$dst"
            echo "carried $p@${h:0:12} from the live repo"
          else
            rm -f "$tmp"; echo "warn: could not carry $p@${h:0:12} from the live repo" >&2
          fi
        done
  else
    echo "note: no live Release at $live — nothing to carry (first publish?)" >&2
  fi
fi

apt-ftparchive \
  -o "APT::FTPArchive::Release::Origin=5dive" \
  -o "APT::FTPArchive::Release::Label=5dive" \
  -o "APT::FTPArchive::Release::Suite=$SUITE" \
  -o "APT::FTPArchive::Release::Codename=$SUITE" \
  -o "APT::FTPArchive::Release::Components=$COMP" \
  -o "APT::FTPArchive::Release::Architectures=${ARCHES[*]}" \
  -o "APT::FTPArchive::Release::Description=5dive CLI" \
  -o "APT::FTPArchive::Release::Acquire-By-Hash=yes" \
  release "dists/$SUITE" > .Release.tmp
mv .Release.tmp "dists/$SUITE/Release"
# apt-ftparchive release lists every file under the dir, by-hash copies too;
# apt ignores entries it does not ask for, so that is harmless.

gpg --batch --yes --local-user "$APT_GPG_KEY_ID" --clearsign -o "dists/$SUITE/InRelease" "dists/$SUITE/Release"
gpg --batch --yes --local-user "$APT_GPG_KEY_ID" --armor --detach-sign -o "dists/$SUITE/Release.gpg" "dists/$SUITE/Release"
gpg --batch --yes --export "$APT_GPG_KEY_ID" > 5dive.gpg
gpg --batch --yes --armor --export "$APT_GPG_KEY_ID" > 5dive.asc
[[ -s 5dive.gpg ]] || die "exported an empty public key for $APT_GPG_KEY_ID"
echo "repo ready at $out ($(ls pool/$COMP/5/5dive | tr '\n' ' '))"
