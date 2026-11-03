#!/usr/bin/env bash
# DIVE-7598: build the ONE file that installs a fully local 5dive server from a
# USB stick, with no internet at all.
#
#   packaging/offline/build-usb.sh <update-file> <debs-dir> "<packages>" <out-dir>
#
# <update-file>  5dive-offline-<version>.tar from build-offline.sh, SIGNED (the
#                5dive inside it refuses an unsigned one, so a stick built from one
#                could never install).
# <debs-dir>     the .deb files for <packages> and everything they depend on that
#                a minimal Ubuntu 24.04 lacks (the workflow downloads them in a
#                clean ubuntu:24.04 container). Refused when one is missing.
# <packages>     the package names the box must end up with (install.sh's
#                APT_PKGS plus what the starter itself needs, e.g. openssl).
#
# Prints the path of <out-dir>/5dive-usb-<version>.run and writes its .sha256
# beside it. The .run is packaging/offline/usb-install.sh with its @@…@@ values
# filled in, a marker line, then an uncompressed tar of the update file and
# debs/ (both are compressed already).
#
# NOT IN IT: Claude Code. Its licence is "All rights reserved" (the npm package's
# LICENSE.md), so 5dive may not hand it out; the starter takes Anthropic's own
# file and manifest.json from the stick instead (docs/guide.md, "No internet at all").
set -euo pipefail

die() { echo "build-usb: $*" >&2; exit 1; }
[[ $# -eq 4 ]] || die "usage: build-usb.sh <update-file> <debs-dir> \"<packages>\" <out-dir>"
upd="$1"; debs="$(cd "$2" && pwd)" || die "no such folder: $2"; pkgs="$3"; out="$4"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
head_tpl="$here/usb-install.sh"
[[ -f "$head_tpl" ]] || die "no starter at $head_tpl"
[[ -f "$upd" ]] || die "no update file at $upd"

m="$(tar -xOf "$upd" manifest.json 2>/dev/null)" || die "$upd is not an update file (no manifest)"
tar -tf "$upd" manifest.sig >/dev/null 2>&1 || die "$upd is UNSIGNED — every box refuses it, so a stick built from it could never install"
ver="$(jq -r '.version' <<<"$m")"; arch="$(jq -r '.arch' <<<"$m")"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the update file's version is '$ver'"
[[ "$arch" =~ ^[a-z0-9_]+$ ]] || die "the update file names no processor"
[[ "$(basename "$upd")" == "5dive-offline-$ver.tar" ]] || die "the update file must be named 5dive-offline-$ver.tar"
[[ "$pkgs" =~ ^[a-z0-9.+\ -]+$ ]] || die "package names: '$pkgs'"
# The starter hands over to `5dive _usb_install` inside the file; a release
# before it has no such verb (and its install.sh would dial out on a fresh box).
# (captured first: `| grep -q` would stop reading early and pipefail would read
# the writer's SIGPIPE as a failure on a real, 8 MB bundle)
bundle="$(tar -xOf "$upd" payload/cli.tar.gz | tar -xzO ./5dive 2>/dev/null)" || bundle=""
grep -q '^cmd_usb_install()' <<<"$bundle" \
  || die "the 5dive in $upd predates the USB install (DIVE-7598) — build from a newer release"

# Every named package has its .deb (its dependencies are dpkg's to check on the box).
have=" "
for d in "$debs"/*.deb; do
  [[ -f "$d" ]] || continue
  have+="$(dpkg-deb -f "$d" Package) "
done
for p in $pkgs; do
  [[ "$have" == *" $p "* ]] || die "no .deb for $p in $debs"
done

stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
install -d "$stage/debs"
cp -a "$upd" "$stage/"
cp -a "$debs"/*.deb "$stage/debs/"
tar --sort=name --owner=0 --group=0 --numeric-owner -cf "$stage/payload.tar" -C "$stage" "$(basename "$upd")" debs
sum="$(sha256sum "$stage/payload.tar" | awk '{print $1}')"

install -d "$out"
f="$out/5dive-usb-$ver.run"
sed -e "s/@@VERSION@@/$ver/g" -e "s/@@ARCH@@/$arch/g" -e "s/@@PAYLOAD_SHA256@@/$sum/g" -e "s/@@PKGS@@/$pkgs/g" \
  "$head_tpl" > "$f.tmp"
grep -q '@@' "$f.tmp" && die "a @@ value was left unfilled in the starter"
printf '__5DIVE_USB_PAYLOAD__\n' >> "$f.tmp"
cat "$stage/payload.tar" >> "$f.tmp"
chmod 755 "$f.tmp"; mv -f "$f.tmp" "$f"
( cd "$out" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256" )
echo "$f"
