#!/usr/bin/env bash
# DIVE-8809: the office server installs and serves the 5dive app file, and ONE
# private "Office server" file carries the installer and the app together.
#
#   V. the checker (src/lib/office_app.sh `_oa_verify`, the SHIPPED bytes): an
#      app file is trusted only through 5dive's root, by a key certified as the
#      OFFICE APP key — a tampered app, an update-key certificate, another root,
#      an expired or revoked key, extra members, links and paths out of the folder
#      are each refused; not-newer is refused unless --allow-downgrade.
#   I. install (`_oa_install_file`): root-owned folder per version, `current`
#      switched in one rename, one version kept back, a refusal leaves the served
#      app untouched.
#   B. the Office server file (packaging/offline/build-office.sh): the public USB
#      installer + the app file in its payload, checksum re-written; refuses an
#      unsigned app, an installer from before this change, a damaged installer.
#   S. the starter (packaging/offline/usb-install.sh as the builder fills it in):
#      installs 5dive, then the app it carries; the public file installs no app.
#   P. the panel's Update slot takes the app file and the Office server file.
#   H. the REAL server on bun: / opens the app for a signed-in device, the page's
#      sign-in for a signed-out one; /lite is the page always; the app's files with
#      their fallbacks, cache rules and CSP; nothing outside the app folder; a new
#      install is served with no restart; the app's sign-out (DELETE /api/proxy/me).
#
# Throwaway root, office and update keys; no network. Needs bun, openssl, jq, curl.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok_ "$1"; else bad_ "$1" "$2"; fi; }
for t in openssl jq curl sha256sum; do command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 0; }; done

T="$(mktemp -d "${TMPDIR:-/tmp}/office-app-install.XXXXXX")"; chmod 755 "$T"
SRV_PID=""
trap 'rc=$?; [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "$T"; echo "HARNESS-RC=$rc"' EXIT
for f in header.sh lib/error_codes.sh lib/output.sh lib/offline_update.sh lib/office_app.sh cmd_local_chat.sh cmd_local_chat_server.sh cmd_local_panel.sh; do source "src/$f"; done
eval "$(sed -n '/^version_lt() {/,/^}/p' src/cmd_selfupdate.sh)"
require_root() { :; }
set +e

# ── keys and certificates (the ceremony page's exact bytes) ─────────────────
key(){ openssl genpkey -algorithm ed25519 -out "$T/$1.pem" 2>/dev/null; openssl pkey -in "$T/$1.pem" -pubout -out "$T/$1.pub" 2>/dev/null; }
kid(){ openssl pkey -pubin -in "$T/$1.pub" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'; }
sign(){ openssl pkeyutl -sign -inkey "$T/$1.pem" -rawin -in "$2" -out "$3"; }
for k in root root2 office office2 upd; do key "$k"; done
NOW=$(date +%s); LATER=$((NOW + 86400 * 30))
cert(){ # <signer-root> <key> <kind> <not_after> <out-prefix>
  jq -cjn --arg k "$3" --arg id "$(kid "$2")" --rawfile p "$T/$2.pub" --argjson n "$4" \
    '{format:1, kind:$k, key_id:$id, pubkey:$p, not_after:$n}' >"$5.json"; sign "$1" "$5.json" "$5.sig"; }
revl(){ # <root> <serial> <out-prefix> [revoked-id...]
  local r="$1" s="$2" o="$3"; shift 3
  jq -cjn --argjson s "$s" '{format:1, kind:"5dive-revocations", serial:$s, revoked:$ARGS.positional}' --args "$@" >"$o.json"; sign "$r" "$o.json" "$o.sig"; }
cert root office 5dive-office-app-key "$LATER" "$T/c-office"
cert root upd 5dive-signing-key "$LATER" "$T/c-upd"
cert root2 office 5dive-office-app-key "$LATER" "$T/c-other-root"
cert root office 5dive-office-app-key $((NOW - 10)) "$T/c-expired"
revl root 1 "$T/rv1"
revl root 2 "$T/rv-office" "$(kid office)"

# ── an app export and the file package.sh makes of it ────────────────────────
mkexport(){ # <dir> <marker>
  mkdir -p "$1/tg/chat/_" "$1/tg/team" "$1/_next/static/chunks"
  printf '<!doctype html><title>app %s</title>tg-home\n' "$2" >"$1/tg/index.html"
  printf '<!doctype html>chat-page %s\n' "$2" >"$1/tg/chat/_/index.html"
  printf '<!doctype html>team %s\n' "$2" >"$1/tg/team/index.html"
  printf 'console.log("%s")\n' "$2" >"$1/_next/static/chunks/main-abc123.js"
  printf 'self.addEventListener("fetch",()=>{})\n' >"$1/sw.js"
  printf '{"name":"5dive","start_url":"/tg/"}\n' >"$1/manifest.webmanifest"
  printf '<!doctype html>not-found-page\n' >"$1/404.html"
}
pack(){ # <export> <version> <out.tar> <cert-prefix> <revl-prefix> <signing-key> [manifest-jq-edit]
  local s; s="$(mktemp -d "$T/pk.XXXXXX")"; mkdir -p "$s/payload"
  # files only, as package.sh packs — plus any link, which only a hostile packer would put in
  (cd "$1" && find . \( -type f -o -type l \) -printf '%P\n' | LC_ALL=C sort) >"$s/list"
  tar -C "$1" --owner=0 --group=0 --numeric-owner --no-recursion -cf - -T "$s/list" | gzip -9n >"$s/payload/app.tar.gz"
  local b; b(){ base64 -w0 <"$1"; }
  jq -cjn --arg v "$2" --arg s "$(sha256sum "$s/payload/app.tar.gz" | awk '{print $1}')" \
    --arg a "$(b "$4.json")" --arg b "$(b "$4.sig")" --arg c "$(b "$5.json")" --arg d "$(b "$5.sig")" \
    '{format:1, kind:"5dive-office-app", version:$v, arch:"web", created:1, files:{"payload/app.tar.gz":$s},
      app:{index:"/tg/", api:"/api/proxy", fallbacks:[{prefix:"/tg/chat/", file:"tg/chat/_/index.html"}]},
      trust:{office_key:$a, office_key_sig:$b, revoked:$c, revoked_sig:$d}}' >"$s/manifest.json"
  [[ -n "${7:-}" ]] && { jq -cj "$7" "$s/manifest.json" >"$s/m2" && mv "$s/m2" "$s/manifest.json"; }
  sign "$6" "$s/manifest.json" "$s/manifest.sig"
  tar -C "$s" --owner=0 --group=0 --numeric-owner --no-recursion -cf "$3" manifest.json manifest.sig payload/app.tar.gz
  rm -rf "$s"
}
mkexport "$T/exp1" v1; mkexport "$T/exp2" v2; mkexport "$T/exp3" v3
pack "$T/exp1" 1.0.0 "$T/app-1.0.0.tar" "$T/c-office" "$T/rv1" office
pack "$T/exp2" 1.1.0 "$T/app-1.1.0.tar" "$T/c-office" "$T/rv1" office
pack "$T/exp3" 1.2.0 "$T/app-1.2.0.tar" "$T/c-office" "$T/rv1" office

export OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$T/root.pub" OFFLINE_UPDATE_STATE_DIR="$T/state"
mkdir -p "$T/state"; chmod 644 "$T/root.pub"
vf(){ # <file> [installed] [allow] — the reason on stdout, rc of _oa_verify
  local st; st="$(mktemp -d "$T/st.XXXXXX")"; _oa_verify "$1" "$st" "${2:-}" "${3:-0}"; local rc=$?
  printf '%s|%s|%s' "$rc" "$_OU_WHY" "$st"; return "$rc"; }

# ── V. the checker ───────────────────────────────────────────────────────────
r=$(vf "$T/app-1.0.0.tar"); st=${r##*|}
check 'V1 a file signed by the office app key the root certified is accepted, unpacked, its manifest kept' '[[ ${r%%|*} == 0 && -f "$st/app/tg/index.html" && -f "$st/app/_next/static/chunks/main-abc123.js" && "$(jq -r .version "$st/manifest.json")" == 1.0.0 ]]'

d="$(mktemp -d "$T/x.XXXXXX")"; tar -xf "$T/app-1.0.0.tar" -C "$d"; printf x >>"$d/payload/app.tar.gz"
tar -C "$d" --no-recursion -cf "$T/bad-payload.tar" manifest.json manifest.sig payload/app.tar.gz
r=$(vf "$T/bad-payload.tar"); check 'V2 one byte added to the app after signing: refused' '[[ ${r%%|*} == 1 && "$r" == *"changed after the file was signed"* ]]'

d="$(mktemp -d "$T/x.XXXXXX")"; tar -xf "$T/app-1.0.0.tar" -C "$d"; sed -i 's/"1.0.0"/"9.0.0"/' "$d/manifest.json"
tar -C "$d" --no-recursion -cf "$T/bad-manifest.tar" manifest.json manifest.sig payload/app.tar.gz
r=$(vf "$T/bad-manifest.tar"); check 'V3 the manifest changed after signing (version raised): refused on the signature' '[[ ${r%%|*} == 1 && "$r" == *"signature does not match"* ]]'

pack "$T/exp1" 1.0.0 "$T/app-updkey.tar" "$T/c-upd" "$T/rv1" upd
r=$(vf "$T/app-updkey.tar"); check 'V4 signed by 5dive'"'"'s UPDATE key (root-certified, kind 5dive-signing-key): refused — only the office app key signs an app' '[[ ${r%%|*} == 1 && "$r" == *"not certified for the office app"* ]]'

pack "$T/exp1" 1.0.0 "$T/app-root2.tar" "$T/c-other-root" "$T/rv1" office
r=$(vf "$T/app-root2.tar"); check 'V5 an office key certified by ANOTHER root: refused' '[[ ${r%%|*} == 1 && "$r" == *"not certified by 5dive'"'"'s root key"* ]]'

pack "$T/exp1" 1.0.0 "$T/app-expired.tar" "$T/c-expired" "$T/rv1" office
r=$(vf "$T/app-expired.tar"); check 'V6 an expired office key: refused' '[[ ${r%%|*} == 1 && "$r" == *expired* ]]'

pack "$T/exp1" 1.0.0 "$T/app-revoked.tar" "$T/c-office" "$T/rv-office" office
r=$(vf "$T/app-revoked.tar"); check 'V7 the office key on the root'"'"'s revocation list: refused' '[[ ${r%%|*} == 1 && "$r" == *revoked* ]]'
# The box keeps the highest list it ever accepted (from an UPDATE file too): an app file carrying list 1 does not un-revoke.
cp "$T/rv-office.json" "$T/state/update-revoked.json"; cp "$T/rv-office.sig" "$T/state/update-revoked.sig"; chmod 644 "$T/state"/update-revoked.*
r=$(vf "$T/app-1.0.0.tar"); check 'V7a a key revoked by the list this box kept stays revoked when the file carries an older list' '[[ ${r%%|*} == 1 && "$r" == *revoked* ]]'
rm -f "$T/state"/update-revoked.*

r=$(OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$T/none.pem" OFFLINE_UPDATE_ROOT_PUBKEY_PEM="" vf "$T/app-1.0.0.tar")
check 'V8 a server with no root key refuses every app file (no pinned-key fallback)' '[[ ${r%%|*} == 1 && "$r" == *"holds no 5dive root key"* ]]'

d="$(mktemp -d "$T/x.XXXXXX")"; tar -xf "$T/app-1.0.0.tar" -C "$d"; echo hi >"$d/extra.sh"
tar -C "$d" --no-recursion -cf "$T/bad-extra.tar" manifest.json manifest.sig payload/app.tar.gz extra.sh
r=$(vf "$T/bad-extra.tar"); check 'V9 a member outside the three names: refused before anything is unpacked' '[[ ${r%%|*} == 1 && "$r" == *"does not (extra.sh)"* ]]'
d="$(mktemp -d "$T/x.XXXXXX")"; tar -xf "$T/app-1.0.0.tar" -C "$d"; ln -s /etc/passwd "$d/payload/app2"
tar -C "$d" --no-recursion -cf "$T/bad-link.tar" manifest.json manifest.sig payload/app2
r=$(vf "$T/bad-link.tar"); check 'V9a a link member: refused' '[[ ${r%%|*} == 1 && "$r" == *"link or special file"* ]]'

mkdir -p "$T/evil/tg"; printf x >"$T/evil/tg/index.html"; ln -s /etc "$T/evil/etc"
pack "$T/evil" 1.0.0 "$T/app-innerlink.tar" "$T/c-office" "$T/rv1" office
r=$(vf "$T/app-innerlink.tar"); check 'V10 the app holds a link (signed!): refused, nothing points out of its folder' '[[ ${r%%|*} == 1 && "$r" == *"app holds a link"* ]]'
s="$(mktemp -d "$T/pk.XXXXXX")"; mkdir -p "$s/a/tg"; printf x >"$s/a/tg/index.html"
(cd "$s/a" && tar --owner=0 --group=0 -czf "$s/inner.tgz" tg/index.html --transform='s#^tg/index.html#../escape.html#' 2>/dev/null)
# pack a payload whose member name climbs out (made by hand: package.sh never would)
mkdir -p "$s/p/payload"; cp "$s/inner.tgz" "$s/p/payload/app.tar.gz"
jq -cjn --arg s "$(sha256sum "$s/p/payload/app.tar.gz" | awk '{print $1}')" --arg a "$(base64 -w0 <"$T/c-office.json")" --arg b "$(base64 -w0 <"$T/c-office.sig")" \
  --arg c "$(base64 -w0 <"$T/rv1.json")" --arg d "$(base64 -w0 <"$T/rv1.sig")" \
  '{format:1, kind:"5dive-office-app", version:"1.0.0", arch:"web", files:{"payload/app.tar.gz":$s}, app:{index:"/tg/"}, trust:{office_key:$a, office_key_sig:$b, revoked:$c, revoked_sig:$d}}' >"$s/p/manifest.json"
sign office "$s/p/manifest.json" "$s/p/manifest.sig"; tar -C "$s/p" --no-recursion -cf "$T/app-dotdot.tar" manifest.json manifest.sig payload/app.tar.gz
r=$(vf "$T/app-dotdot.tar"); check 'V10a the app holds a path that climbs out of its folder (signed!): refused' '[[ ${r%%|*} == 1 && "$r" == *"outside its folder"* ]]'

r=$(vf "$T/app-1.0.0.tar" 1.0.0); check 'V11 the version this server already serves: refused as not newer' '[[ ${r%%|*} == 1 && "$r" == *"nothing newer"* ]]'
r=$(vf "$T/app-1.0.0.tar" 1.1.0); check 'V11a an older version: refused' '[[ ${r%%|*} == 1 && "$r" == *"nothing newer"* ]]'
r=$(vf "$T/app-1.0.0.tar" 1.1.0 1); check 'V11b an older version with --allow-downgrade: accepted' '[[ ${r%%|*} == 0 ]]'

d="$(mktemp -d "$T/x.XXXXXX")"; jq -cjn '{format:1, version:"2.0.0", arch:"x86_64", files:{}}' >"$d/manifest.json"; sign office "$d/manifest.json" "$d/manifest.sig"
mkdir -p "$d/payload"; echo x >"$d/payload/app.tar.gz"; tar -C "$d" --no-recursion -cf "$T/not-app.tar" manifest.json manifest.sig payload/app.tar.gz
r=$(vf "$T/not-app.tar"); check 'V12 a file that is not an office app (an update file'"'"'s manifest) says so plainly' '[[ ${r%%|*} == 1 && "$r" == *"not an office app file"* ]]'
pack "$T/exp1" 1.0.0 "$T/app-fb.tar" "$T/c-office" "$T/rv1" office '.app.fallbacks = [{prefix:"/tg/chat/", file:"../../etc/passwd"}]'
r=$(vf "$T/app-fb.tar"); check 'V13 a fallback naming a file outside the app (signed!): refused' '[[ ${r%%|*} == 1 && "$r" == *"not an office app manifest"* ]]'
# The update verifier keeps refusing an office app file (the kinds cannot stand in for each other).
st="$(mktemp -d "$T/st.XXXXXX")"; OFFLINE_UPDATE_ARCH=web _ou_verify "$T/app-1.0.0.tar" "$st" "" 0; rc=$?
check 'V14 the CLI update check refuses an office app file (it carries no update key certificate)' '[[ $rc == 1 && "$_OU_WHY" == *"certificate"* ]]'

# ── I. install ───────────────────────────────────────────────────────────────
export OFFICE_APP_DIR="$T/opt/office-app"
_oa_install_file "$T/app-1.0.0.tar" 0; rc=$?
check 'I1 install puts the app in <dir>/1.0.0 and serves it through current' '[[ $rc == 0 && "$(readlink "$OFFICE_APP_DIR/current")" == 1.0.0 && -f "$OFFICE_APP_DIR/current/app/tg/index.html" && "$(_oa_installed)" == 1.0.0 ]]'
check 'I1a nobody but the owner can write the app (go-w), the manifest sits beside it' '[[ -z "$(find "$OFFICE_APP_DIR/1.0.0" -perm /022 -print -quit)" && -f "$OFFICE_APP_DIR/1.0.0/manifest.json" ]]'
_oa_install_file "$T/app-1.1.0.tar" 0; _oa_install_file "$T/app-1.2.0.tar" 0
check 'I2 a newer app takes over; one version is kept back, older ones are removed' '[[ "$(readlink "$OFFICE_APP_DIR/current")" == 1.2.0 && -d "$OFFICE_APP_DIR/1.1.0" && ! -e "$OFFICE_APP_DIR/1.0.0" ]]'
_oa_install_file "$T/bad-payload.tar" 1; rc=$?
check 'I3 a refused file leaves the served app as it was and no stage behind' '[[ $rc == 1 && "$(readlink "$OFFICE_APP_DIR/current")" == 1.2.0 && -z "$(find "$OFFICE_APP_DIR" -maxdepth 1 -name ".stage.*" -print -quit)" ]]'
_oa_install_file "$T/app-1.1.0.tar" 0; rc=$?
check 'I4 going back needs --allow-downgrade' '[[ $rc == 1 && "$_OU_WHY" == *"nothing newer"* ]]'
_oa_install_file "$T/app-1.1.0.tar" 1; rc=$?
check 'I4a with it, the version kept back is served again' '[[ $rc == 0 && "$(readlink "$OFFICE_APP_DIR/current")" == 1.1.0 && -f "$OFFICE_APP_DIR/current/app/tg/team/index.html" ]]'

# ── B. the Office server file ────────────────────────────────────────────────
# A public USB installer as build-usb.sh lays it out (its starter, @@ values, marker, payload).
mkpublic(){ # <out-dir> <cli-version> [starter]
  local s; s="$(mktemp -d "$T/u.XXXXXX")"; mkdir -p "$s/debs"
  # The update file stands in (the starter's 5dive is faked in S); its name is what counts here.
  mkdir -p "$s/u/payload"; printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="%s"\n' "$2" >"$s/u/5dive"
  tar -C "$s/u" -czf "$s/u/payload/cli.tar.gz" ./5dive; tar -C "$s/u" -cf "$s/5dive-offline-$2.tar" payload/cli.tar.gz
  echo deb >"$s/debs/x.deb"
  tar --sort=name --owner=0 --group=0 --numeric-owner -cf "$s/payload.tar" -C "$s" "5dive-offline-$2.tar" debs
  local sum; sum="$(sha256sum "$s/payload.tar" | awk '{print $1}')"
  mkdir -p "$1"
  sed -e "s/@@VERSION@@/$2/g" -e "s/@@ARCH@@/$(uname -m)/g" -e "s/@@PAYLOAD_SHA256@@/$sum/g" -e "s/@@PKGS@@/jq/g" "${3:-packaging/offline/usb-install.sh}" >"$1/5dive-usb-$2.run"
  printf '__5DIVE_USB_PAYLOAD__\n' >>"$1/5dive-usb-$2.run"; cat "$s/payload.tar" >>"$1/5dive-usb-$2.run"; chmod 755 "$1/5dive-usb-$2.run"
  rm -rf "$s"
}
mkpublic "$T/pub" 3.4.5
cp "$T/app-1.2.0.tar" "$T/5dive-office-app-1.2.0.tar"
OUT=$(bash packaging/offline/build-office.sh "$T/pub/5dive-usb-3.4.5.run" "$T/5dive-office-app-1.2.0.tar" "$T/dist" 2>"$T/b.err"); rc=$?
check 'B1 one file, named for both versions, with its .sha256' '[[ $rc == 0 && "$OUT" == "$T/dist/5dive-office-server-3.4.5-app-1.2.0.run" && -x "$OUT" ]] && (cd "$T/dist" && sha256sum -c --quiet 5dive-office-server-3.4.5-app-1.2.0.run.sha256)'
line=$(awk '/^__5DIVE_USB_PAYLOAD__$/ { print NR + 1; exit }' "$OUT"); tail -n +"$line" "$OUT" >"$T/opay.tar"
check 'B2 its payload holds the update file, the packages and the app; the starter names the new checksum' '[[ "$(tar -tf "$T/opay.tar" | grep -cE "^(5dive-offline-3.4.5.tar|5dive-office-app-1.2.0.tar|debs/x.deb)$")" == 3 ]] && grep -q "^FIVE_USB_PAYLOAD_SHA256=\"$(sha256sum "$T/opay.tar" | cut -d" " -f1)\"$" "$OUT"'
pline=$(awk '/^__5DIVE_USB_PAYLOAD__$/ { print NR + 1; exit }' "$T/pub/5dive-usb-3.4.5.run"); publist=$(tail -n +"$pline" "$T/pub/5dive-usb-3.4.5.run" | tar -t 2>/dev/null)
check 'B2a the public installer is untouched (it never carries the app)' 'grep -qx "5dive-offline-3.4.5.tar" <<<"$publist" && ! grep -q office-app <<<"$publist"'
d="$(mktemp -d "$T/x.XXXXXX")"; tar -xf "$T/app-1.2.0.tar" -C "$d"; mkdir -p "$T/u"; tar -C "$d" --no-recursion -cf "$T/u/5dive-office-app-1.2.0.tar" manifest.json payload/app.tar.gz
bash packaging/offline/build-office.sh "$T/pub/5dive-usb-3.4.5.run" "$T/u/5dive-office-app-1.2.0.tar" "$T/dist-u" >/dev/null 2>"$T/b.err"; rc=$?
check 'B3 an UNSIGNED app file is refused' '[[ $rc != 0 ]] && grep -q UNSIGNED "$T/b.err"'
sed '/^# DIVE-8809: the office app/d' packaging/offline/usb-install.sh >"$T/old-starter.sh"; mkpublic "$T/oldpub" 3.4.4 "$T/old-starter.sh"
bash packaging/offline/build-office.sh "$T/oldpub/5dive-usb-3.4.4.run" "$T/5dive-office-app-1.2.0.tar" "$T/dist-o" >/dev/null 2>"$T/b.err"; rc=$?
check 'B4 an installer from before this change (it would ignore the app) is refused' '[[ $rc != 0 ]] && grep -q "predates the office app" "$T/b.err"'
mkdir -p "$T/dmg"; cp "$T/pub/5dive-usb-3.4.5.run" "$T/dmg/"
sz=$(stat -c %s "$T/dmg/5dive-usb-3.4.5.run"); printf Z | dd of="$T/dmg/5dive-usb-3.4.5.run" bs=1 seek=$((sz - 100)) conv=notrunc 2>/dev/null
bash packaging/offline/build-office.sh "$T/dmg/5dive-usb-3.4.5.run" "$T/5dive-office-app-1.2.0.tar" "$T/dist-d" >/dev/null 2>"$T/b.err"; rc=$?
check 'B5 a damaged installer is refused (its payload no longer matches its checksum)' '[[ $rc != 0 ]] && grep -q damaged "$T/b.err"'
bash packaging/offline/build-office.sh "$OUT" "$T/5dive-office-app-1.2.0.tar" "$T/dist-2" >/dev/null 2>&1; rc=$?
check 'B6 an Office server file is never bundled twice' '[[ $rc != 0 ]]'

# Updating a running server from the same file: `local app install` takes the .run.
rm -rf "$OFFICE_APP_DIR"; _oa_install_file "$OUT" 0; rc=$?
check 'I5 `local app install <Office server file>` installs the app inside it' '[[ $rc == 0 && "$(_oa_installed)" == 1.2.0 ]]'
_oa_install_file "$T/pub/5dive-usb-3.4.5.run" 0; rc=$?
check 'I6 the public installer holds no app, and says so' '[[ $rc == 1 && "$_OU_WHY" == *"holds no office app"* ]]'

# ── S. the starter ───────────────────────────────────────────────────────────
STUB="$T/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\necho "5dive $*" >>"%s/calls"\n' "$T" >"$STUB/fake-shell"
printf '#!/usr/bin/env bash\necho "app-cli $*" >>"%s/calls"; cp "$4" "%s/app-seen.tar"\n' "$T" "$T" >"$STUB/fake-cli"
chmod +x "$STUB"/*
start(){ # <run> — as root would, with the system steps stubbed (the 7598 harness grades those)
  sed 's#^\[\[ \$EUID -eq 0 \]\] ||#true ||#' "$1" >"$1.t"
  : >"$T/calls"; rm -f "$T/app-seen.tar"
  FIVE_USB_SHELL="$STUB/fake-shell" FIVE_USB_APP_CLI="$STUB/fake-cli" FIVE_USB_WORK_PARENT="$T" bash "$1.t" >"$T/s.out" 2>&1
}
# the stick's packages: say jq is installed (the only one the fixture names)
cp "$OUT" "$T/os.run"; start "$T/os.run"; rc=$?
check 'S1 the Office server file installs 5dive, THEN the app it carries (the app file reaches `local app install` intact)' '[[ $rc == 0 && "$(sed -n 1p "$T/calls")" == "5dive "*"/cli/5dive _usb_install --from="* && "$(sed -n 2p "$T/calls")" == "app-cli local app install "*5dive-office-app-1.2.0.tar ]] && cmp -s "$T/app-seen.tar" "$T/5dive-office-app-1.2.0.tar"'
cp "$T/pub/5dive-usb-3.4.5.run" "$T/ps.run"; start "$T/ps.run"; rc=$?
check 'S2 the public file installs 5dive and no app' '[[ $rc == 0 && "$(grep -c . "$T/calls")" == 1 && "$(cat "$T/calls")" == "5dive "*"/cli/5dive _usb_install"* ]]'
printf '#!/usr/bin/env bash\necho "5dive $*" >>"%s/calls"; exit 7\n' "$T" >"$STUB/fake-shell"
cp "$OUT" "$T/os2.run"; start "$T/os2.run"; rc=$?
check 'S3 when 5dive does not install, the app is not tried and the starter fails' '[[ $rc == 7 && "$(grep -c app-cli "$T/calls")" == 0 ]]'

# ── P. the panel's Update slot ───────────────────────────────────────────────
export FIVE_LOCAL_CHAT_ROOT="$T/root" FIVE_PANEL_CLI="$T/fake5dive"
cat >"$FIVE_PANEL_CLI" <<FAKE
#!/usr/bin/env bash
echo "\$*" >>"$T/panel.calls"
case "\$*" in
  "--json self-update --from="*) cp "\${3#--from=}" "$T/upd-seen.tar"; echo '{"ok":true,"data":{}}' ;;
  "--json local app install "*) echo '{"ok":true,"data":{"installed":"1.2.0"}}' ;;
  "--json --version") echo '{"ok":true,"data":{"version":"3.4.5"}}' ;;
esac
FAKE
chmod +x "$FIVE_PANEL_CLI"
_lp_audit(){ :; }
panel_run(){ : >"$T/panel.calls"; install -d "$(_lp_update_dir)"; cp "$1" "$(_lp_update_dir)/update.tar"; ( _lp_update_run ); }
panel_run "$T/app-1.2.0.tar"
check 'P1 the Update slot installs an app file with `local app install` (no self-update)' '[[ "$(cat "$T/panel.calls")" == "--json local app install "* && "$(jq -r .state "$(_lp_update_dir)/status.json")" == done && "$(jq -r .message "$(_lp_update_dir)/status.json")" == *"5dive app 1.2.0 is installed"* ]]'
panel_run "$OUT"
check 'P2 the Office server file: 5dive from its update file first, then the app, by the new 5dive' '[[ "$(sed -n 1p "$T/panel.calls")" == "--json self-update --from="*5dive-offline-3.4.5.tar && "$(sed -n 2p "$T/panel.calls")" == "--json local app install "* ]] && cmp -s "$T/upd-seen.tar" <(tail -n +"$line" "$OUT" | tar -xO 5dive-offline-3.4.5.tar) && [[ "$(jq -r .message "$(_lp_update_dir)/status.json")" == "Updated to 5dive 3.4.5 and the 5dive app 1.2.0." ]]'
check 'P2a the uploaded copy is removed after the run' '[[ ! -e "$(_lp_update_dir)/update.tar" ]]'
unset FIVE_LOCAL_CHAT_ROOT FIVE_PANEL_CLI

# ── H. the real server ───────────────────────────────────────────────────────
BUN=$(command -v bun || echo /usr/local/bin/bun)
if [[ ! -x "$BUN" ]]; then bad_ 'H0 bun present' "no bun"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; fi
_local_chat_server_ts >"$T/server.ts"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj "/CN=t" \
  -addext "subjectAltName=IP:127.0.0.1" -keyout "$T/key.pem" -out "$T/cert.pem" >/dev/null 2>&1
printf 'CONNECTORD_TOKEN="boxtok-123"\n' >"$T/connectord.env"; printf '["alice"]\n' >"$T/agents.json"
STATE="$T/chat-state"; mkdir -p "$STATE"
OWNER=ownerCookie0123456789abcdefABCDEF; OTHER=otherCookie0123456789abcdefABCDE
"$BUN" -e '
import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
const h = (s) => createHash("sha256").update(s).digest("hex");
const db = new Database(process.argv[1] + "/chat.db", { create: true });
db.exec(`CREATE TABLE devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, cookie_hash TEXT NOT NULL UNIQUE,
  created INTEGER NOT NULL, last_seen INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, role TEXT NOT NULL DEFAULT "chat");`);
db.query("INSERT INTO devices VALUES (?, ?, ?, 1, 1, 0, ?)").run("aaaa0001", "Boss laptop", h(process.argv[2]), "owner");
db.query("INSERT INTO devices VALUES (?, ?, ?, 2, 2, 0, ?)").run("aaaa0002", "Boss phone", h(process.argv[3]), "owner");
' "$STATE" "$OWNER" "$OTHER"
rm -rf "$OFFICE_APP_DIR"
LAN=$((20000 + RANDOM % 20000)); LOOP=$((LAN + 1))
LC_STATE="$STATE" LC_LAN_ADDR=127.0.0.1 LC_LAN_PORT=$LAN LC_LOOP_PORT=$LOOP LC_CERT="$T/cert.pem" LC_KEY="$T/key.pem" \
  LC_TOKEN_FILE="$T/connectord.env" LC_AGENTS_FILE="$T/agents.json" LC_UPLOADS="$T/uploads" LC_PANEL_SOCK="$T/none.sock" \
  LC_APP_DIR="$OFFICE_APP_DIR/current" "$BUN" "$T/server.ts" serve >"$T/server.log" 2>&1 & SRV_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$LOOP/" && break; sleep 0.1; done
W="https://127.0.0.1:$LAN"
jar(){ printf '127.0.0.1\tFALSE\t/\tTRUE\t0\tlc_dev\t%s\n' "$2" >"$T/$1"; }
jar boss "$OWNER"; jar phone "$OTHER"
get(){ curl -sk "$@"; }
hdr(){ curl -sk -D - -o /dev/null "$@" | tr -d '\r' | tr 'A-Z' 'a-z'; }
code(){ curl -sk -o /dev/null -w '%{http_code}' "$@"; }

check 'H1 no app installed: / is the office chat page, as before' '[[ "$(get -b "$T/boss" "$W/")" == *"Office chat"* && "$(get -b "$T/boss" "$W/")" != *data-app* ]]'
check 'H1a no app installed: an app path is not served' '[[ "$(code "$W/tg/")" != 200 ]]'
_oa_install_file "$T/app-1.1.0.tar" 0 >/dev/null
check 'H2 app installed, signed in: / opens the app (302 to its start page), with no restart' '[[ "$(hdr -b "$T/boss" "$W/?x=1" | tr -d "\r" | grep -i "^location:")" == "location: /tg/?x=1" ]]'
check 'H3 app installed, signed out: / is the page'"'"'s sign-in, marked to go to the app once in' '[[ "$(code "$W/")" == 200 && "$(get "$W/")" == *"data-app=\"1\""* ]]'
check 'H3a /join (a join link) is the page too, marked the same' '[[ "$(get "$W/join")" == *"data-app=\"1\""* && "$(get "$W/join")" == *"/api/proxy/team/accept"* ]]'
check 'H4 /lite is the old page, always, signed in or out, never sent on to the app' '[[ "$(get -b "$T/boss" "$W/lite")" == *"Office chat"* && "$(get -b "$T/boss" "$W/lite")" != *data-app* && "$(code "$W/lite")" == 200 ]]'
check 'H5 the app'"'"'s pages are served from its folder' '[[ "$(get "$W/tg/")" == *"app v2"*tg-home* && "$(get "$W/tg/team/")" == *"team v2"* ]]'
check 'H5a /tg/chat/<agent>/ is the one chat page (the manifest'"'"'s fallback)' '[[ "$(get "$W/tg/chat/marcus/")" == *"chat-page v2"* && "$(code "$W/tg/chat/marcus/")" == 200 ]]'
h=$(hdr "$W/tg/" | tr -d '\r')
csp=$(grep -i '^content-security-policy:' <<<"$h")
check 'H6 the app pages carry a CSP that lets them talk only to this server' '[[ "$csp" == *"default-src '"'"'self'"'"';"* && "$csp" == *"connect-src '"'"'self'"'"';"* && "$h" == *"cache-control: no-cache"* && "$h" == *"x-frame-options: deny"* ]]'
h=$(hdr "$W/_next/static/chunks/main-abc123.js" | tr -d '\r')
check 'H6a content-hashed files are cached for good, as JavaScript' '[[ "$h" == *"cache-control: public, max-age=31536000, immutable"* && "$h" == *"content-type: text/javascript"* ]]'
check 'H6b the service worker and the web manifest are at the root, with their types' '[[ "$(hdr "$W/sw.js" | tr -d "\r" | grep -i ^content-type)" == *text/javascript* && "$(hdr "$W/manifest.webmanifest" | tr -d "\r" | grep -i ^content-type)" == *application/manifest+json* ]]'
check 'H7 a path the app does not have is its 404 page, with a 404' '[[ "$(code "$W/nope/")" == 404 && "$(get "$W/nope/")" == *not-found-page* ]]'
check 'H7a nothing outside the app folder: encoded dot-dot and a double slash get 404' '[[ "$(code --path-as-is "$W/%2e%2e/%2e%2e/manifest.json")" == 404 && "$(code --path-as-is "$W/tg/..%2f..%2fmanifest.json")" == 404 && "$(get --path-as-is "$W/%2e%2e/manifest.json")" != *trust* ]]'
check 'H7b an /api path is never the app: unknown ones stay the JSON 404' '[[ "$(code -b "$T/boss" "$W/api/nope")" == 404 && "$(get -b "$T/boss" "$W/api/nope")" == *"not found"* ]]'
_oa_install_file "$T/app-1.2.0.tar" 0 >/dev/null
check 'H8 a new install is served at once, no restart' '[[ "$(get "$W/tg/")" == *v3* ]]'
check 'H9 the app'"'"'s sign-out: DELETE /api/proxy/me signs THIS device out (204, cookie cleared)' '[[ "$(code -b "$T/boss" -X DELETE -H "origin: $W" "$W/api/proxy/me")" == 204 && "$(code -b "$T/boss" "$W/api/proxy/me")" == 401 && "$(hdr -b "$T/phone" -X DELETE -H "origin: $W" "$W/api/proxy/me" | grep ^set-cookie)" == *"lc_dev=;"*"max-age=0"* ]]'
check 'H9a it needs this origin (a page elsewhere cannot sign a device out)' 'jar phone2 "$OTHER"; [[ "$(code -b "$T/phone2" -X DELETE -H "origin: https://evil.example" "$W/api/proxy/me")" == 403 ]]'
check 'H9b the signed-out device gets the sign-in at /, not the app' '[[ "$(code -b "$T/boss" "$W/")" == 200 ]]'
rm -rf "$OFFICE_APP_DIR"
check 'H10 the app removed: / is the page again, no restart' '[[ "$(code "$W/tg/")" != 200 && "$(get "$W/")" != *data-app* ]]'

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
