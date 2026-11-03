#!/usr/bin/env bash
# 5dive — install a fully local server from this one file, with no internet.
#
#   sudo bash 5dive-usb-@@VERSION@@.run [--claude=<file>] [--ntp=<office time server>] [--no-chat]
#
# For a fresh Ubuntu 24.04 server (@@ARCH@@). It puts in the system packages 5dive
# needs from the file itself, installs 5dive, and leaves the server in local-only
# mode: nothing on it connects outside your network. Claude Code is Anthropic's
# and 5dive may not hand it out, so put Anthropic's own two files (claude and
# manifest.json) next to this one on the stick and they are found by themselves.
#
# DIVE-7598. This header is packaging/offline/usb-install.sh; the builder
# (packaging/offline/build-usb.sh) fills in the four values below and appends the
# payload: the signed update file 5dive-offline-<version>.tar and debs/*.deb.
# The payload's sha256 is checked before anything is unpacked; the update file's
# signature is then checked by the 5dive inside it, against 5dive's release key,
# exactly as `self-update --from=` checks one.
set -euo pipefail

FIVE_USB_VERSION="@@VERSION@@"
FIVE_USB_ARCH="@@ARCH@@"
FIVE_USB_PAYLOAD_SHA256="@@PAYLOAD_SHA256@@"
FIVE_USB_PKGS="@@PKGS@@"

say() { echo "→ $*"; }
installed() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]; }
die() { echo "error: $*" >&2; exit 1; }

usage() {
  sed -n '4p' "$0" | sed 's/^# *//'
  echo
  echo "  --claude=<file>   Anthropic's Claude Code file (its manifest.json beside it)"
  echo "  --ntp=<server>    your office time server (else the clock is not synced)"
  echo "  --no-chat         do not start the office chat page"
}

claude="" pass=()
for a in "$@"; do
  case "$a" in
    --claude=*) claude="${a#--claude=}" ;;
    --ntp=*|--no-chat) pass+=("$a") ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $a (see: bash $0 --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run it as root: sudo bash $0"
self="$(readlink -f "$0")"; here="$(dirname "$self")"
[[ "$(uname -m)" == "$FIVE_USB_ARCH" ]] || die "this file is for $FIVE_USB_ARCH servers and this one is $(uname -m)"
os_ok=0
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] && os_ok=1
fi

# Anthropic's Claude Code, when it sits next to this file.
if [[ -z "$claude" && -f "$here/claude" ]]; then claude="$here/claude"; fi
if [[ -n "$claude" ]]; then
  claude="$(readlink -f "$claude")"
  [[ -f "$claude" ]] || die "no Claude Code file at $claude"
  [[ -f "$(dirname "$claude")/manifest.json" ]] || die "Claude Code's manifest.json must be next to $claude (download both from Anthropic)"
fi

# Room to unpack: the file's own size again, plus half for the packages.
parent="${FIVE_USB_WORK_PARENT:-/var/tmp}"
need_kb=$(( $(stat -c %s "$self") * 3 / 2 / 1024 ))
free_kb="$(df -Pk "$parent" | awk 'NR==2 {print $4}')"
(( free_kb > need_kb )) || die "not enough free disk in $parent: $(( need_kb / 1024 )) MB needed, $(( free_kb / 1024 )) MB free"

work="$(mktemp -d "$parent/5dive-usb.XXXXXX")"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

say "Checking the file (5dive $FIVE_USB_VERSION)"
line="$(awk '/^__5DIVE_USB_PAYLOAD__$/ { print NR + 1; exit }' "$self")"
[[ "$line" =~ ^[0-9]+$ ]] || die "this file is damaged (no payload in it)"
tail -n +"$line" "$self" > "$work/payload.tar"
[[ "$(sha256sum "$work/payload.tar" | awk '{print $1}')" == "$FIVE_USB_PAYLOAD_SHA256" ]] \
  || die "this file is damaged or was changed (its checksum does not match) — copy it to the stick again"
tar -xf "$work/payload.tar" -C "$work" --no-same-owner
rm -f "$work/payload.tar"
upd="$work/5dive-offline-$FIVE_USB_VERSION.tar"
[[ -f "$upd" ]] || die "this file is damaged (no update file in it)"

# The system packages, from the file. Only the ones this server lacks: a
# package it already has stays at its own (maybe newer) version.
missing=()
for p in $FIVE_USB_PKGS; do
  installed "$p" || missing+=("$p")
done
if (( ${#missing[@]} )); then
  (( os_ok )) || die "this server lacks ${missing[*]} and is not Ubuntu 24.04, so the packages in this file may not fit it. Install those packages, then run the file again."
  say "Installing system packages from the file: ${missing[*]}"
  compgen -G "$work/debs/*.deb" >/dev/null || die "the file holds no package for: ${missing[*]}"
  # apt, not a bare `dpkg -i`: dpkg unpacks in the order it is given, so a
  # package whose Pre-Depends sorts after it (python3-minimal before
  # python3.12-minimal) is refused and everything above it fails (DIVE-7598 CI).
  # The .debs become a flat local package source (an index written here with
  # dpkg-deb, which every Ubuntu has), and apt is pointed at ONLY that source,
  # with its own empty list and cache folders: there is no other source, so it
  # cannot reach a mirror, and a dependency missing from the file is an error.
  # Not --no-download: with it apt 2.7 dies "Pathname to install is not
  # absolute" on every package (DIVE-7598 CI run 41595689732).
  : > "$work/debs/Packages"
  for d in "$work"/debs/*.deb; do
    { dpkg-deb -f "$d" | sed '/^$/d'
      printf 'Filename: ./%s\nSize: %s\nSHA256: %s\n\n' "${d##*/}" "$(stat -c %s "$d")" "$(sha256sum "$d" | cut -d' ' -f1)"
    } >> "$work/debs/Packages" || die "this file is damaged (a package in it cannot be read)"
  done
  a="$work/apt"; mkdir -p "$a/sources.d" "$a/lists/partial" "$a/cache/archives/partial"
  echo "deb [trusted=yes] file:$work/debs ./" > "$a/sources.list"
  ao=(-o Dir::Etc::SourceList="$a/sources.list" -o Dir::Etc::SourceParts="$a/sources.d"
      -o Dir::State::Lists="$a/lists" -o Dir::Cache="$a/cache" -o APT::Sandbox::User=root)
  { apt-get update -q "${ao[@]}" \
      && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${ao[@]}" "${missing[@]}"
  } >"$work/apt.log" 2>&1 \
    || { grep -E '^(E:|W:|dpkg: |Errors were| [a-z0-9.+-]+ : Depends)' "$work/apt.log" | tail -25 >&2 || tail -25 "$work/apt.log" >&2
         die "the system packages did not install (above)"; }
  for p in "${missing[@]}"; do
    installed "$p" || die "package $p did not install"
  done
fi

# 5dive, by the 5dive inside the (still to be checked) update file.
mkdir -p "$work/cli"
tar -xOf "$upd" payload/cli.tar.gz | tar -xz -C "$work/cli" ./5dive \
  || die "this file is damaged (no 5dive in it)"
say "Installing 5dive"
"${FIVE_USB_SHELL:-bash}" "$work/cli/5dive" _usb_install --from="$upd" ${claude:+"--claude=$claude"} ${pass[@]+"${pass[@]}"}
exit $?
