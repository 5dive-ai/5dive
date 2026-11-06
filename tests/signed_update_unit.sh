#!/usr/bin/env bash
# DIVE-7816: every online `5dive self-update` checks the release against 5dive's
# root key before anything runs.
#
# Keys are generated here; every signed file is made by the REAL signing tool
# (packaging/signing/5dive-release-sign); every check runs the SHIPPED bytes of
# src/lib/signed_update.sh (the fenced verifier block).
#
# PART 1 — the verifier, arm by arm: a good release; one byte changed in the
# bundle, in the installer; a release signed by a revoked key (the list served
# with it, and an OLDER list served while the box keeps the newer one); a cert
# from another root; an edited manifest; a manifest for another tag; an expired
# cert; a cert naming one key and carrying another; no root key; a root key file
# others can write. Then MUTANTS: the bundle-hash check, the revocation check
# and the kept-list rule are each removed and the arm that names them must flip
# to "installs" — an integrity arm that cannot be seen to fail grades nothing.
#
# PART 2 — `5dive self-update` end to end, the BUILT bundle, against a stand-in
# network (curl is a fixture that serves the release tree, the GitHub release
# files and main's legacy installer from disk; systemctl answers nothing):
#   (a) a correctly signed release installs, the installer gets the signed
#       commit and the signed bundle;
#   (b) the same release with ONE BYTE of the bundle changed is refused, nothing
#       runs, the box keeps its CLI (enforcing build);
#   (c) a release signed by a revoked key is refused (enforcing build);
#   plus the warn-only build (this release): the bad release is logged and
#   recorded for `5dive doctor`, and the old path runs.
# self-update refuses non-root. As root (CI: SU_REQUIRE_ROOT_ARM=1 under sudo,
# a throwaway runner) it runs as shipped. As non-root it runs a COPY whose one
# root check is patched out, and every arm says so in its name.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
done_t(){ echo "$PASS passed, $FAIL failed"; (( FAIL == 0 )); exit $?; }

LIB="$ROOT/src/lib/signed_update.sh"
SIGN="$ROOT/packaging/signing/5dive-release-sign"
BLOCK="$(sed -n '/^# >>> DIVE-7816 signed update verifier/,/^# <<< DIVE-7816 signed update verifier/p' "$LIB")"
[[ -n "$BLOCK" ]] && grep -q '_su_sig_verify()' <<<"$BLOCK" \
  || { bad_t "verifier fences missing in $LIB"; done_t; }
for c in openssl jq sha256sum; do command -v "$c" >/dev/null || { bad_t "$c not installed"; done_t; }; done

WORK="$(mktemp -d)"; chmod 755 "$WORK"
K="$WORK/keys"; mkdir -p "$K"
q(){ "$@" >/dev/null 2>&1; }

# ------------------------------------------------------------------ keys + certs
for k in root evilroot A B C; do q "$SIGN" keygen "$K/$k.pem" || { bad_t "keygen $k"; done_t; }; done
idB="$("$SIGN" key-id "$K/B.pem.pub")"
q "$SIGN" certify --root="$K/root.pem" --pub="$K/A.pem.pub" --days=365 --out="$WORK/certA"
q "$SIGN" certify --root="$K/root.pem" --pub="$K/B.pem.pub" --days=365 --out="$WORK/certB"
q "$SIGN" certify --root="$K/evilroot.pem" --pub="$K/C.pem.pub" --days=365 --out="$WORK/certEvil"
q "$SIGN" certify --root="$K/root.pem" --pub="$K/A.pem.pub" --days=1 --out="$WORK/certShort"
q "$SIGN" revocations --root="$K/root.pem" --serial=1 --out="$WORK/rev1"
q "$SIGN" revocations --root="$K/root.pem" --serial=2 --revoke="$idB" --out="$WORK/rev2"
q "$SIGN" revocations --root="$K/evilroot.pem" --serial=1 --out="$WORK/revEvil"
# A cert dir = one cert + one revocation list.
certs(){ local d="$WORK/certs-$1-$2"; mkdir -p "$d"; cp "$WORK/$1"/signing-key.* "$WORK/$2"/revoked.* "$d/"; printf '%s' "$d"; }
[[ "$("$SIGN" key-id "$K/root.pem.pub")" =~ ^[0-9a-f]{64}$ && -s "$WORK/rev2/revoked.sig" ]] \
  && ok_t "signing tool: keygen, certify, revocations all produced signed files" \
  || bad_t "signing tool did not produce its files"
if "$SIGN" sign-files --key="$K/B.pem" --certs="$(certs certB rev2)" --tag=v9.9.9 --commit="$(printf '%040d' 0)" \
     --bundle="$LIB" --installer="$LIB" --out="$WORK/never" >/dev/null 2>&1; then
  bad_t "signing tool refuses to sign with a key on the revocation list" "it signed"
else ok_t "signing tool refuses to sign with a key on the revocation list"; fi

# ------------------------------------------------------------------ releases
RAW="$WORK/raw"; REL="$WORK/rel"; mkdir -p "$RAW" "$REL"
# mk_release <tag> <version> <signing-key> <certs-dir>  — prints the commit.
mk_release() {
  local tag="$1" ver="$2" key="$3" cd="$4" commit
  commit="$(printf '%s-%s' "$tag" "$RANDOM$RANDOM" | sha1sum | awk '{print $1}')"
  mkdir -p "$RAW/$commit"
  printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="%s"\necho "fixture 5dive %s"\n' "$ver" "$ver" > "$RAW/$commit/5dive"
  printf '%s\n' "fixture-hash-of-$ver" > "$RAW/$commit/5dive.sha256"
  cat > "$RAW/$commit/install.sh" <<'INST'
#!/usr/bin/env bash
# fixture installer (signed): records what self-update handed it, installs the
# handed bundle the way install.sh's DIVE-7816 block does.
set -euo pipefail
{ echo "kind=signed"; echo "gh_sha=${GH_SHA:-}"; echo "bundle=${FIVE_VERIFIED_BUNDLE:-}"
  echo "bundle_sha=$(sha256sum "${FIVE_VERIFIED_BUNDLE:-/dev/null}" | awk '{print $1}')"
  echo "want_sha=${FIVE_VERIFIED_BUNDLE_SHA256:-}"; echo "args=$*"; } > "$SU_FIXTURE_MARK"
[[ "$(sha256sum "$FIVE_VERIFIED_BUNDLE" | awk '{print $1}')" == "$FIVE_VERIFIED_BUNDLE_SHA256" ]] || exit 9
install -m 755 "$FIVE_VERIFIED_BUNDLE" "$SU_FIXTURE_BIN/5dive"
INST
  ln -sfn "$commit" "$RAW/$tag"
  q "$SIGN" sign-files --key="$K/$key.pem" --certs="$cd" --tag="$tag" --commit="$commit" \
     --bundle="$RAW/$commit/5dive" --installer="$RAW/$commit/install.sh" --out="$REL/$tag" || return 1
  printf '%s' "$commit"
}
# flip <file> — change ONE byte (the second-to-last, inside the last line).
flip(){ local n; n=$(stat -c %s "$1"); printf 'X' | dd of="$1" bs=1 seek=$((n-2)) conv=notrunc 2>/dev/null; }
C_GOOD="$(mk_release v2.0.0 2.0.0 A "$(certs certA rev1)")" || bad_t "sign v2.0.0"
C_BYTE="$(mk_release v2.0.1 2.0.1 A "$(certs certA rev1)")" || bad_t "sign v2.0.1"
flip "$RAW/$C_BYTE/5dive"     # one byte, after signing
C_INST="$(mk_release v2.0.2 2.0.2 A "$(certs certA rev1)")" || bad_t "sign v2.0.2"
flip "$RAW/$C_INST/install.sh"
# Signed by B while B was still good, then B is revoked (rev2 published with it).
C_REV="$(mk_release v2.0.3 2.0.3 B "$(certs certB rev1)")" || bad_t "sign v2.0.3"
cp "$WORK/rev2"/revoked.* "$REL/v2.0.3/"
# Signed by B, served with the OLD list (an attacker withholding rev2).
C_REVOLD="$(mk_release v2.0.4 2.0.4 B "$(certs certB rev1)")" || bad_t "sign v2.0.4"
C_EVIL="$(mk_release v2.0.5 2.0.5 C "$(certs certEvil revEvil)")" || bad_t "sign v2.0.5"
C_EDIT="$(mk_release v2.0.6 2.0.6 A "$(certs certA rev1)")" || bad_t "sign v2.0.6"
jq -c '.commit = "'"$C_GOOD"'"' "$REL/v2.0.6/release.json" > "$WORK/t" && mv "$WORK/t" "$REL/v2.0.6/release.json"
C_TAG="$(mk_release v2.0.7 2.0.7 A "$(certs certA rev1)")" || bad_t "sign v2.0.7"
cp "$REL/v2.0.0"/release.* "$REL/v2.0.7/"                   # v2.0.0's valid manifest served as v2.0.7
C_EXP="$(mk_release v2.0.8 2.0.8 A "$(certs certShort rev1)")" || bad_t "sign v2.0.8"
C_SWAP="$(mk_release v2.0.9 2.0.9 A "$(certs certA rev1)")" || bad_t "sign v2.0.9"
# A cert that names A's key_id but carries C's key, root-signed: the root signed
# a broken certificate. The key_id is recomputed, never believed.
jq --rawfile p "$K/C.pem.pub" '.pubkey = $p' "$WORK/certA/signing-key.json" > "$REL/v2.0.9/signing-key.json"
openssl pkeyutl -sign -inkey "$K/root.pem" -rawin -in "$REL/v2.0.9/signing-key.json" -out "$REL/v2.0.9/signing-key.sig"

# ------------------------------------------------------------------ PART 1
install -m 644 "$K/root.pem.pub" "$WORK/root.pub"
# verify <tag> <state-dir> [block-file] [VAR=val...] -> "rc|why|commit"
verify() {
  local tag="$1" st="$2" blk="${3:-}"; shift 3 2>/dev/null || shift $#
  local w; w="$(mktemp -d "$WORK/w.XXXXXX")"
  [[ -n "$blk" ]] || { blk="$WORK/block.sh"; printf '%s\n' "$BLOCK" > "$blk"; }
  env SIGNED_UPDATE_BASE="file://$REL" SIGNED_UPDATE_RAW="file://$RAW" SIGNED_UPDATE_STATE_DIR="$st" \
    SIGNED_UPDATE_ROOT_PUBKEY_FILE="${ROOTFILE:-$WORK/root.pub}" SIGNED_UPDATE_NOW="${NOW:-$(date +%s)}" \
    "$@" bash -c '
    set -uo pipefail
    gh_org(){ echo org; }
    SIGNED_UPDATE_ROOT_PUBKEY_PEM="${SIGNED_UPDATE_ROOT_PUBKEY_PEM:-}"; SIGNED_UPDATE_ENFORCE=1
    . "$1"
    _su_sig_verify "$2" "$3"; rc=$?
    printf "%s|%s|%s\n" "$rc" "$_SU_SIG_WHY" "$SU_SIG_COMMIT"' _ "$blk" "$tag" "$w" 2>/dev/null
}
expect_ok(){ local r; r="$(verify "$2" "$WORK/st-$RANDOM" "" "${@:4}")"
  [[ "${r%%|*}" == 0 && "${r##*|}" == "$3" ]] && ok_t "$1" || bad_t "$1" "got: $r"; }
expect_no(){ local r; r="$(verify "$2" "${ST:-$WORK/st-$RANDOM}" "${BLK:-}")"
  [[ "${r%%|*}" == 1 ]] && grep -qi -- "$3" <<<"$r" && ok_t "$1 — \"$(cut -d'|' -f2 <<<"$r")\"" || bad_t "$1" "got: $r (want refusal matching '$3')"; }

expect_ok "a correctly signed release verifies and names its signed commit" v2.0.0 "$C_GOOD"
expect_no "one byte changed in the bundle after signing is refused" v2.0.1 "5dive program.*changed after signing"
expect_no "one byte changed in the installer after signing is refused" v2.0.2 "installer.*changed after signing"
expect_no "a release signed by a key revoked in the list served with it is refused" v2.0.3 "revoked"
ST="$WORK/st-kept"; expect_no "seeing that list once is remembered (same box, v2.0.3 again)" v2.0.3 "revoked"
expect_no "an OLDER list served with a revoked key's release does not un-revoke it (box kept serial 2)" v2.0.4 "revoked"
unset ST
expect_ok "...while a box that never saw the newer list still takes it (the expiry is that box's limit)" v2.0.4 "$C_REVOLD"
expect_no "a signing key certified by another root is refused" v2.0.5 "not certified"
expect_no "a manifest edited after signing is refused" v2.0.6 "does not match 5dive's signing key"
expect_no "a valid manifest for another version is refused" v2.0.7 "is for v2.0.0, not v2.0.7"
NOW=$(( $(date +%s) + 3 * 86400 )) expect_no "a release signed by an expired key is refused" v2.0.8 "expired"
expect_no "a certificate that names one key and carries another is refused" v2.0.9 "names a different key"
expect_no "a version with no signature files is refused as unsigned" v3.0.0 "not signed"
ROOTFILE="$WORK/none" expect_no "a missing root key file is refused" v2.0.0 "could not read"
r="$(verify v2.0.0 "$WORK/st-nokey" "" SIGNED_UPDATE_ROOT_PUBKEY_FILE= )"
# shellcheck disable=SC2015
[[ "${r%%|*}" == 1 ]] && grep -q "no update signing key built in" <<<"$r" \
  && ok_t "no root key built in: every release is refused (the safe failure)" || bad_t "no root key built in" "$r"
install -m 666 "$K/root.pem.pub" "$WORK/root-ww.pub"
ROOTFILE="$WORK/root-ww.pub" expect_no "a root key file others can write is not trusted" v2.0.0 "writable by others"
r="$(verify v2.0.0 "$WORK/st-pem" "" SIGNED_UPDATE_ROOT_PUBKEY_FILE= SIGNED_UPDATE_ROOT_PUBKEY_PEM="$(cat "$K/root.pem.pub")")"
[[ "${r%%|*}" == 0 ]] && ok_t "the compiled-in root key path (SIGNED_UPDATE_ROOT_PUBKEY_PEM) verifies too" || bad_t "compiled-in key path" "$r"

# Mutants — each removes ONE rule; its arm must flip to "installs".
mutant(){ local name="$1" pat="$2" f="$WORK/mut-$1.sh"
  printf '%s\n' "$BLOCK" | awk -v p="$pat" 'index($0,p){print "  true # MUTANT"; skip=1; next} skip&&/\|\| \{ _SU_SIG_WHY/{skip=0; next} {skip=0; print}' > "$f"
  grep -q MUTANT "$f" || { bad_t "mutant $name did not apply" "pattern: $pat"; return 1; }; printf '%s' "$f"; }
mut_flips(){ local f r; f="$(mutant "$1" "$2")" || return
  r="$(verify "$3" "$WORK/st-m$RANDOM" "$f")"
  [[ "${r%%|*}" == 0 ]] && ok_t "MUTANT $1: with that rule removed $3 installs — the arm above is live" || bad_t "MUTANT $1 still refused, so the arm does not grade the rule" "$r"; }
mut_flips bundle-hash '[[ "$(sha256sum "$w/5dive"' v2.0.1
mut_flips installer-hash '[[ "$(sha256sum "$w/install.sh"' v2.0.2
f="$WORK/mut-revoke.sh"; printf '%s\n' "$BLOCK" | sed 's/index(\$k) != null/false/' > "$f"
r="$(verify v2.0.3 "$WORK/st-mr" "$f")"; [[ "${r%%|*}" == 0 ]] && ok_t "MUTANT revocation-check: v2.0.3 installs without it — the revoked arm is live" || bad_t "MUTANT revocation-check" "$r"
f="$WORK/mut-kept.sh"; printf '%s\n' "$BLOCK" | sed 's/(( kept_serial > got_serial ))/false/' > "$f"
mkdir -p "$WORK/st-mk"; cp "$WORK/st-kept"/revoked.* "$WORK/st-mk/"
r="$(verify v2.0.4 "$WORK/st-mk" "$f")"; [[ "${r%%|*}" == 0 ]] && ok_t "MUTANT kept-list: v2.0.4 installs without the higher-serial rule — the anti-rollback arm is live" || bad_t "MUTANT kept-list" "$r"

# install.sh's half: the handed bundle is re-hashed against the signed hash.
IB="$(sed -n '/^  # >>> DIVE-7816 verified bundle/,/^  # <<< DIVE-7816 verified bundle/p' install.sh)"
if grep -q 'FIVE_VERIFIED_BUNDLE_SHA256' <<<"$IB"; then
  ib_run(){ bash -c 'set -euo pipefail; die(){ echo "DIE: $*"; exit 1; }; _bundle_tmp="$1"; '"$IB"'
  :; fi; echo INSTALLED' _ "$WORK/ib.$RANDOM" 2>&1; }
  o="$(FIVE_VERIFIED_BUNDLE="$RAW/$C_GOOD/5dive" FIVE_VERIFIED_BUNDLE_SHA256="$(jq -r .bundle_sha256 "$REL/v2.0.0/release.json")" ib_run)"
  [[ "$o" == *INSTALLED* ]] && ok_t "install.sh installs a handed bundle that matches its signed hash" || bad_t "install.sh verified-bundle happy path" "$o"
  o="$(FIVE_VERIFIED_BUNDLE="$RAW/$C_BYTE/5dive" FIVE_VERIFIED_BUNDLE_SHA256="$(jq -r .bundle_sha256 "$REL/v2.0.1/release.json")" ib_run)"
  [[ "$o" == *"DIE: the verified 5dive bundle does not match its signed hash"* ]] && ok_t "install.sh refuses a handed bundle one byte off its signed hash" || bad_t "install.sh verified-bundle refusal" "$o"
else bad_t "install.sh DIVE-7816 verified-bundle block missing"; fi

# ------------------------------------------------------------------ PART 2
BUILT="$WORK/5dive-built"
if ! BUILD_OUT="$BUILT" ./build.sh >/dev/null 2>&1 || [[ ! -s "$BUILT" ]]; then
  bad_t "build.sh did not produce a bundle"; done_t
fi
grep -q '^SIGNED_UPDATE_ENFORCE=0$' "$BUILT" && grep -q '_su_sig_verify()' "$BUILT" \
  && ok_t "the built bundle carries the verifier, warn-only this release (SIGNED_UPDATE_ENFORCE=0)" \
  || bad_t "built bundle lacks the verifier or is not warn-only"
mode="as root, unpatched"
if [[ $EUID -ne 0 ]]; then
  if [[ "${SU_REQUIRE_ROOT_ARM:-0}" == 1 ]]; then bad_t "PART 2 must run as root here (SU_REQUIRE_ROOT_ARM=1)"; done_t; fi
  mode="REHEARSAL as $(id -un): the one root check patched out of a copy"
  sed -i 's/\[\[ \$EUID -eq 0 \]\] || fail "\$E_PERMISSION" "self-update must run as root (sudo 5dive self-update)"/true/' "$BUILT"
fi
cp "$BUILT" "$WORK/5dive-enforce"; sed -i 's/^SIGNED_UPDATE_ENFORCE=0$/SIGNED_UPDATE_ENFORCE=1/' "$WORK/5dive-enforce"
chmod 755 "$BUILT" "$WORK/5dive-enforce"
FB="$WORK/fakebin"; mkdir -p "$FB"
cat > "$FB/curl" <<'CURL'
#!/usr/bin/env bash
# Stand-in network: serves the fixture trees; anything else is unreachable.
out="" url="" w=""
while (( $# )); do case "$1" in -o) out="$2"; shift ;; -w) w="$2"; shift ;; --max-time|-H|-X|-d) shift ;; -*) ;; *) url="$1" ;; esac; shift; done
src=""
case "$url" in
  https://raw.githubusercontent.com/org/5dive/main/.release-hold) printf '# 5dive-release-hold v1\n' > "${out:-/dev/stdout}"; exit 0 ;;
  https://raw.githubusercontent.com/org/5dive/main/install.sh) src="$SU_FX/legacy-install.sh" ;;
  https://raw.githubusercontent.com/org/5dive/*) src="$SU_FX/raw/${url#https://raw.githubusercontent.com/org/5dive/}" ;;
  https://github.com/org/5dive/releases/download/*) src="$SU_FX/rel/${url#https://github.com/org/5dive/releases/download/}" ;;
  file://*) src="${url#file://}" ;;
esac
echo "$url" >> "$SU_FX/curl.log"
[[ -n "$src" && -f "$src" ]] || exit 22
if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
CURL
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/systemctl"
cat > "$WORK/legacy-install.sh" <<'LEG'
#!/usr/bin/env bash
echo "kind=legacy" > "$SU_FIXTURE_MARK"; echo "args=$*" >> "$SU_FIXTURE_MARK"
LEG
chmod 755 "$FB"/* "$WORK/legacy-install.sh"
# For the bundle probe the tags must also resolve at raw/<tag>/ and carry a
# self-consistent 5dive.sha256 (it is the probe's own, unsigned check).
for t in "$RAW"/v*; do sha256sum "$t/5dive" | awk '{print $1}' > "$t/5dive.sha256.tmp" && mv "$t/5dive.sha256.tmp" "$t/5dive.sha256"; done
# The fixture bundle's version must read like a release for the probe.
install -m 644 "$K/root.pem.pub" "$WORK/root-e2e.pub"

# e2e <label> <bundle> <tag> -> sets E_RC E_OUT, box dir $E_BOX
e2e() {
  local bin="$2" tag="$3"
  E_BOX="$WORK/box-$1"; mkdir -p "$E_BOX"/{bin,st,rb,pr,sd,etc}
  printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="1.0.0"\necho "the CLI this box had"\n' > "$E_BOX/bin/5dive"
  printf '%s\n' "$tag" > "$E_BOX/etc/cli-version"
  : > "$WORK/curl.log"
  E_OUT="$(cd "$E_BOX" && env PATH="$FB:$PATH" GH_ORG=org SU_FX="$WORK" SU_FIXTURE_MARK="$E_BOX/mark" SU_FIXTURE_BIN="$E_BOX/bin" \
    STATE_DIR="$E_BOX/st" HEALTH_GATE_BIN_DIR="$E_BOX/bin" HEALTH_GATE_SYSTEMD_DIR="$E_BOX/sd" HEALTH_GATE_ROLLBACK_DIR="$E_BOX/rb" \
    PENDING_RESTART_DIR="$E_BOX/pr" CLI_VERSION_OVERRIDE_FILE="$E_BOX/etc/cli-version" CLI_CANARY_FILE="$E_BOX/etc/no-canary" \
    CLI_VERSION_KNOWN_FILE="$E_BOX/st/known" SIGNED_UPDATE_ROOT_PUBKEY_FILE="$WORK/root-e2e.pub" \
    FIVEDIVE_SELF_UPDATE_HINT=0 "$bin" self-update 2>&1)"; E_RC=$?
}
kv(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1; }

e2e a "$WORK/5dive-enforce" v2.0.0
if (( E_RC == 0 )) && [[ "$(kv "$E_BOX/mark" kind)" == signed && "$(kv "$E_BOX/mark" gh_sha)" == "$C_GOOD" ]] \
   && cmp -s "$E_BOX/bin/5dive" "$RAW/$C_GOOD/5dive" && [[ "$(kv "$E_BOX/st/self-update/signature" outcome)" == verified ]]; then
  ok_t "(a) [$mode] 5dive self-update installs a correctly signed release: installer ran with GH_SHA=${C_GOOD:0:12}, the box's 5dive is now the signed bundle, doctor state 'verified'"
else bad_t "(a) signed release did not install" "rc=$E_RC mark=$(tr '\n' ' ' < "$E_BOX/mark" 2>/dev/null) out=$(tail -5 <<<"$E_OUT")"; fi
! grep -q '/main/install.sh' "$WORK/curl.log" && ok_t "(a) main's installer was never fetched on the signed path" || bad_t "(a) main's installer was fetched" "$(cat "$WORK/curl.log")"

e2e b "$WORK/5dive-enforce" v2.0.1
if (( E_RC != 0 )) && [[ ! -e "$E_BOX/mark" ]] && grep -q 'the CLI this box had' "$E_BOX/bin/5dive" \
   && grep -q "update refused: the 5dive program of v2.0.1 does not match its signature" <<<"$E_OUT"; then
  ok_t "(b) [$mode] one byte changed in the bundle: refused, no installer ran, the box keeps its CLI — \"$(sed -n 's/.*\(update refused: [^—]*\).*/\1/p' <<<"$E_OUT" | head -1)\""
else bad_t "(b) tampered bundle not refused" "rc=$E_RC mark=$([[ -e "$E_BOX/mark" ]] && echo present) bin=$(tail -1 "$E_BOX/bin/5dive") out=$(tail -5 <<<"$E_OUT")"; fi

e2e c "$WORK/5dive-enforce" v2.0.3
if (( E_RC != 0 )) && [[ ! -e "$E_BOX/mark" ]] && grep -q 'the CLI this box had' "$E_BOX/bin/5dive" \
   && grep -q "update refused: v2.0.3 was signed by a key 5dive has revoked" <<<"$E_OUT" \
   && [[ "$(kv "$E_BOX/st/self-update/signature" outcome)" == refused ]]; then
  ok_t "(c) [$mode] a release signed by a revoked key: refused, the box keeps its CLI, doctor state 'refused'"
else bad_t "(c) revoked-key release not refused" "rc=$E_RC out=$(tail -5 <<<"$E_OUT")"; fi

e2e w "$BUILT" v2.0.1
if (( E_RC == 0 )) && [[ "$(kv "$E_BOX/mark" kind)" == legacy ]] \
   && grep -q "not signature-checked" <<<"$E_OUT" && [[ "$(kv "$E_BOX/st/self-update/signature" outcome)" == unsigned-warned ]]; then
  ok_t "warn-only build (this release): the tampered release is logged + recorded for doctor, and the old path runs"
else bad_t "warn-only build behaviour" "rc=$E_RC mark=$(cat "$E_BOX/mark" 2>/dev/null) out=$(tail -5 <<<"$E_OUT")"; fi

done_t
