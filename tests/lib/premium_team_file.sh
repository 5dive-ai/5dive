#!/usr/bin/env bash
# DIVE-9330 — a TEST producer of premium team files, so core's harnesses can
# feed its verifier (_team_premium_verify, src/cmd_team_pack.sh) a signed file.
#
# The real producer left core (step 6e of DIVE-9262): 5dive's API makes the
# files a buyer gets (5dive-api src/lib/premium-team-file.ts), and the shell
# reference producer lives in hosted@5dive-plugins
# (plugins/hosted/tools/premium-team-build.sh) with its own harness. This one
# takes the same flags but checks nothing: a test hands it a rogue, expired or
# revoked certificate on purpose, to watch the VERIFIER refuse it.
#
#   tests/lib/premium_team_file.sh --bundle=<team.tar.gz> --key=<team-key.pem> \
#       --trust=<dir of team-key.json/.sig, revoked.json/.sig> --buyer-account=<id> \
#       [--buyer-name=<name>] --version=X.Y.Z -o <out.gz> [--issued-at=<epoch>]
set -euo pipefail
bundle="" key="" trust="" account="" name="" version="" out="" issued="$(date +%s)"
while (( $# )); do
  case "$1" in
    --bundle=*) bundle="${1#*=}" ;;          --key=*) key="${1#*=}" ;;
    --trust=*) trust="${1#*=}" ;;            --buyer-account=*) account="${1#*=}" ;;
    --buyer-name=*) name="${1#*=}" ;;        --version=*) version="${1#*=}" ;;
    --issued-at=*) issued="${1#*=}" ;;       -o) out="$2"; shift ;;
    *) echo "premium_team_file: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
mkdir -p "$w/team" "$w/out/payload"
tar -xzf "$bundle" -C "$w/team"
team=$(jq -r '.team' "$w/team/manifest.json")
# The buyer goes inside the team too (licensed_to), as the real producers write it.
jq -c --arg a "$account" --arg n "$name" --argjson t "$issued" \
  '. + {licensed_to: {account: $a, name: $n, issued_at: $t}}' "$w/team/manifest.json" >"$w/m"
mv "$w/m" "$w/team/manifest.json"
# shellcheck disable=SC2046  # member names are a team bundle's: no spaces
( cd "$w/team" && tar -czf "$w/out/payload/team.tar.gz" $(find . -mindepth 1 -maxdepth 1 -printf '%P\n' | LC_ALL=C sort) )
b64() { base64 -w0 <"$trust/$1"; }
jq -cjn --arg team "$team" --arg v "$version" --arg a "$account" --arg n "$name" --argjson t "$issued" \
  --arg s "$(sha256sum "$w/out/payload/team.tar.gz" | awk '{print $1}')" \
  --arg k "$(b64 team-key.json)" --arg ks "$(b64 team-key.sig)" --arg r "$(b64 revoked.json)" --arg rs "$(b64 revoked.sig)" \
  '{format:1, kind:"5dive-premium-team", team:$team, version:$v, buyer:{account:$a, name:$n},
    issued_at:$t, files:{"payload/team.tar.gz":$s},
    trust:{team_key:$k, team_key_sig:$ks, revoked:$r, revoked_sig:$rs}}' >"$w/out/manifest.json"
openssl pkeyutl -sign -inkey "$key" -rawin -in "$w/out/manifest.json" -out "$w/out/manifest.sig"
tar -czf "$out" -C "$w/out" manifest.json manifest.sig payload/team.tar.gz
