#!/usr/bin/env bash
# DIVE-9109 — make ONE premium team file for ONE buyer: a team bundle
# (`5dive team export`) stamped with the buyer and signed by 5dive's team key.
#
#   packaging/premium-team/build.sh --bundle=<team.tar.gz> --key=<team-key.pem> \
#       --trust=<dir> --buyer-account=<id> --buyer-name=<name> --version=X.Y.Z \
#       -o <out.premium.tar.gz> [--issued-at=<epoch>]
#
# --trust is the team key's certificate from 5dive's root key ceremony
# (packaging/signing/root-key.html, "Premium team key"): the page's
# 5dive-master-key-PUBLIC-team.json, or a folder of team-key.json, team-key.sig,
# revoked.json, revoked.sig. The far side is `5dive team import
# <file>`, which checks it in src/cmd_team_pack.sh (_team_premium_verify).
#
# The buyer is written twice: on the signed wrapper (manifest.json .buyer) and
# inside the team's own manifest (.licensed_to), so a copy with the wrapper torn
# off still names whose it was. Not DRM: the file can be passed on.
#
# Needs: bash, tar, gzip, jq, openssl (ed25519), sha256sum, base64.
set -euo pipefail

die() { printf 'premium-team build: %s\n' "$*" >&2; exit 1; }
bundle="" key="" trust="" account="" name="" version="" out="" issued=""
while (( $# )); do
  case "$1" in
    --bundle=*) bundle="${1#*=}" ;;
    --key=*) key="${1#*=}" ;;
    --trust=*) trust="${1#*=}" ;;
    --buyer-account=*) account="${1#*=}" ;;
    --buyer-name=*) name="${1#*=}" ;;
    --version=*) version="${1#*=}" ;;
    --issued-at=*) issued="${1#*=}" ;;
    --out=*) out="${1#*=}" ;;
    -o) out="${2:-}"; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
[[ -f "$bundle" ]] || die "--bundle=<team.tar.gz> is required (made by: 5dive team export <team>)"
[[ -f "$key" ]] || die "--key=<team-key.pem> is required"
[[ -d "$trust" || -f "$trust" ]] || die "--trust is required: the ceremony's 5dive-master-key-PUBLIC-team.json, or a folder of team-key.json/.sig, revoked.json/.sig"
[[ -n "$account" ]] || die "--buyer-account is required"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version must be X.Y.Z"
[[ -n "$out" ]] || die "-o <out.premium.tar.gz> is required"
[[ -z "$issued" ]] && issued=$(date +%s)
[[ "$issued" =~ ^[0-9]{1,12}$ ]] || die "--issued-at must be a unix time"
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
if [[ -f "$trust" ]]; then   # the ceremony page's public file: base64 fields -> the four files
  mkdir "$w/trust"
  for p in team_key_json:team-key.json team_key_sig:team-key.sig revoked_json:revoked.json revoked_sig:revoked.sig; do
    jq -r --arg k "${p%%:*}_b64" '.[$k] // empty' "$trust" 2>/dev/null | base64 -d >"$w/trust/${p#*:}" 2>/dev/null || true
  done
  trust="$w/trust"
fi
for f in team-key.json team-key.sig revoked.json revoked.sig; do
  [[ -s "$trust/$f" ]] || die "the trust given has no $f (is it the PUBLIC file for a premium team key?)"
done
mkdir -p "$w/team" "$w/out/payload"

# 1. The bundle must be a team bundle with no traversal or link member.
tar -tzf "$bundle" >"$w/list" 2>/dev/null || die "$bundle is not a .tar.gz"
grep -qE '(^/|(^|/)\.\.(/|$))' "$w/list" && die "$bundle holds a path outside its folder"
tar -tvzf "$bundle" 2>/dev/null | grep -q '^[lh]' && die "$bundle holds a link"
tar -xzf "$bundle" -C "$w/team" --no-same-owner
jq -e '.kind == "5dive-team"' "$w/team/manifest.json" >/dev/null 2>&1 || die "$bundle is not a team bundle (made by: 5dive team export <team>)"
team=$(jq -r '.team' "$w/team/manifest.json")
[[ "$team" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || die "the bundle names no usable team"

# 2. The key must be the one the certificate carries, certified as a team key.
jq -e '.format == 1 and .kind == "5dive-team-key"' "$trust/team-key.json" >/dev/null 2>&1 \
  || die "the certificate in $trust is not for a premium team key (kind 5dive-team-key)"
openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}' >"$w/kid"
[[ "$(cat "$w/kid")" == "$(jq -r '.key_id' "$trust/team-key.json")" ]] \
  || die "--key is not the key the certificate in $trust approves"

# 3. Stamp the team, then pack it (sorted, root-owned, no timestamps to leak).
jq -c --arg a "$account" --arg n "$name" --argjson t "$issued" \
  '. + {licensed_to: {account: $a, name: $n, issued_at: $t}}' "$w/team/manifest.json" >"$w/m" \
  && mv "$w/m" "$w/team/manifest.json"
( cd "$w/team" && LC_ALL=C find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort >"$w/members" \
  && tar -czf "$w/out/payload/team.tar.gz" --owner=0 --group=0 --numeric-owner --mtime=@"$issued" \
       --no-recursion -T "$w/members" )

# 4. The signed wrapper.
sha=$(sha256sum "$w/out/payload/team.tar.gz" | awk '{print $1}')
b64() { base64 -w0 <"$1"; }
jq -cjn --arg team "$team" --arg v "$version" --arg a "$account" --arg n "$name" --argjson t "$issued" \
  --arg s "$sha" --arg k "$(b64 "$trust/team-key.json")" --arg ks "$(b64 "$trust/team-key.sig")" \
  --arg r "$(b64 "$trust/revoked.json")" --arg rs "$(b64 "$trust/revoked.sig")" \
  '{format:1, kind:"5dive-premium-team", team:$team, version:$v, buyer:{account:$a, name:$n},
    issued_at:$t, files:{"payload/team.tar.gz":$s},
    trust:{team_key:$k, team_key_sig:$ks, revoked:$r, revoked_sig:$rs}}' >"$w/out/manifest.json"
openssl pkeyutl -sign -inkey "$key" -rawin -in "$w/out/manifest.json" -out "$w/out/manifest.sig" \
  || die "could not sign (is --key an ed25519 private key?)"
openssl pkey -in "$key" -pubout -out "$w/pub.pem" 2>/dev/null
openssl pkeyutl -pubin -inkey "$w/pub.pem" -verify -rawin -in "$w/out/manifest.json" -sigfile "$w/out/manifest.sig" >/dev/null 2>&1 \
  || die "the signature failed its own check; do not ship this file"
tar -czf "$out.tmp" --owner=0 --group=0 --numeric-owner -C "$w/out" manifest.json manifest.sig payload/team.tar.gz
mv -f "$out.tmp" "$out"
printf '%s\n' "$out"
