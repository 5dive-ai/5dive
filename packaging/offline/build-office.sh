#!/usr/bin/env bash
# DIVE-8809: build the PRIVATE "Office server" file — the one Enterprise download
# that installs the server AND the 5dive app, so IT installs once:
#
#   packaging/offline/build-office.sh <5dive-usb-X.Y.Z.run> <5dive-office-app-A.B.C.tar> <out-dir>
#
# It is the public USB installer (build-usb.sh) with the signed office app file
# (lodar/5dive-frontend scripts/office/package.sh, DIVE-8806) added to its
# payload, and the payload checksum in the starter updated. The starter installs
# 5dive first, then runs `5dive local app install` on the app file, which checks
# its signature against 5dive's root key. The same file also updates a running
# office server: the panel's Update screen or `sudo 5dive local app install`.
#
# Prints <out-dir>/5dive-office-server-X.Y.Z-app-A.B.C.run and writes its .sha256.
# NEVER publish the output: it holds the app, which is only for Enterprise
# buyers (the private download on 5dive.ai/enterprise/files). The public USB
# file and the public update file never carry it.
set -euo pipefail

die() { echo "build-office: $*" >&2; exit 1; }
[[ $# -eq 3 ]] || die "usage: build-office.sh <5dive-usb-X.Y.Z.run> <5dive-office-app-A.B.C.tar> <out-dir>"
run="$1" app="$2" out="$3"
[[ -f "$run" ]] || die "no USB installer at $run"
[[ -f "$app" ]] || die "no office app file at $app"
[[ "$(basename "$run")" =~ ^5dive-usb-([0-9]+\.[0-9]+\.[0-9]+)\.run$ ]] || die "the installer must be named 5dive-usb-X.Y.Z.run"
cli="${BASH_REMATCH[1]}"
[[ "$(basename "$app")" =~ ^5dive-office-app-([0-9]+\.[0-9]+\.[0-9]+)\.tar$ ]] || die "the app file must be named 5dive-office-app-X.Y.Z.tar"
ver="${BASH_REMATCH[1]}"
command -v jq >/dev/null || die "needs jq"

# The app file: a signed office app manifest at the version its name says.
m="$(tar -xOf "$app" manifest.json 2>/dev/null)" || die "$app has no manifest"
jq -e --arg v "$ver" '.kind == "5dive-office-app" and .version == $v' <<<"$m" >/dev/null 2>&1 \
  || die "$app is not office app $ver (its manifest says otherwise)"
tar -tf "$app" manifest.sig >/dev/null 2>&1 || die "$app is UNSIGNED — every office server refuses it"
jq -e '.trust | type == "object"' <<<"$m" >/dev/null 2>&1 || die "$app carries no certificate from 5dive's root key — every office server refuses it"

# The installer: a starter that installs an app file it carries, and an intact payload.
line="$(awk '/^__5DIVE_USB_PAYLOAD__$/ { print NR; exit }' "$run")"
[[ "$line" =~ ^[0-9]+$ ]] || die "$run has no payload — not a 5dive USB installer"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
head -n "$line" "$run" > "$stage/head"
grep -q '^# DIVE-8809: the office app' "$stage/head" \
  || die "the installer in $run predates the office app (DIVE-8809) — build from a newer 5dive release"
grep -q "^FIVE_USB_VERSION=\"$cli\"$" "$stage/head" || die "the installer's own version is not $cli"
old_sum="$(sed -n 's/^FIVE_USB_PAYLOAD_SHA256="\([0-9a-f]\{64\}\)"$/\1/p' "$stage/head")"
[[ "$old_sum" =~ ^[0-9a-f]{64}$ ]] || die "the installer names no payload checksum"

tail -n +"$((line + 1))" "$run" > "$stage/payload.tar"
[[ "$(sha256sum "$stage/payload.tar" | awk '{print $1}')" == "$old_sum" ]] \
  || die "$run is damaged (its payload does not match its checksum) — download it again"
mkdir "$stage/p"
tar -xf "$stage/payload.tar" -C "$stage/p" --no-same-owner
rm -f "$stage/payload.tar"
[[ -f "$stage/p/5dive-offline-$cli.tar" ]] || die "$run holds no 5dive-offline-$cli.tar"
compgen -G "$stage/p/5dive-office-app-*.tar" >/dev/null && die "$run already holds an office app"
cp -a "$app" "$stage/p/"
( cd "$stage/p" && tar --sort=name --owner=0 --group=0 --numeric-owner -cf "$stage/payload.tar" -- * )
sum="$(sha256sum "$stage/payload.tar" | awk '{print $1}')"

install -d "$out"
f="$out/5dive-office-server-$cli-app-$ver.run"
sed "s/^FIVE_USB_PAYLOAD_SHA256=\"$old_sum\"$/FIVE_USB_PAYLOAD_SHA256=\"$sum\"/" "$stage/head" > "$f.tmp"
grep -q "^FIVE_USB_PAYLOAD_SHA256=\"$sum\"$" "$f.tmp" || die "could not write the new checksum into the starter"
cat "$stage/payload.tar" >> "$f.tmp"
chmod 755 "$f.tmp"; mv -f "$f.tmp" "$f"
( cd "$out" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256" )
echo "$f"
