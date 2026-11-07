#!/usr/bin/env bash
# DIVE-7888: updates by disk trust an OFFLINE ROOT key. The root certifies the
# signing key (with an expiry) and signs a revocation list; both ride inside
# manifest.json as "trust". A box holding the root REQUIRES the chain; a box
# without one keeps the pinned-key path unchanged.
#
# Throwaway ed25519 keys (openssl, in a temp dir): ROOT, ROOT2 (another root),
# SK (the certified signing key), SK2 (another signing key). The good file is
# built by the REAL builder (packaging/offline/build-offline.sh) with
# OFFLINE_TRUST_DIR; the bad variants are the good file re-signed with one thing
# changed. Checked by the SHIPPED bytes of src/lib/offline_update.sh (sourced whole).
#
# Arms: (a) chained file verifies (+ key order/whitespace of the certified JSON
# does not matter); (b) a payload byte / a certified byte changed; (c) revoked
# key; (d) expired cert; (e) cert by another root; (f) key_id not its pubkey's;
# (g) manifest signed by an uncertified key; (h) root present, no trust; (i) no
# root: the direct pin, unchanged; (j) the kept list: a lower serial does not
# un-revoke, an EQUAL serial with other bytes does not either (both lists
# apply), and a list is kept only after the whole file verified; (k) a root
# key file others can write; (l) the pre-DIVE-7888 verifier takes a file WITH
# trust. Then the builder's refusals, --write-pubkey, and MUTANTS that drop one
# check each and must let the matching bad file through.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
finish(){ echo; echo "$PASS passed, $FAIL failed"; exit $(( FAIL > 0 )); }

LIB="$ROOT/src/lib/offline_update.sh"
B="$ROOT/packaging/offline/build-offline.sh"
# The last verifier before DIVE-7888 (this row's base): what boxes run today.
OLD_SHA=75d2559f

WORK="$(mktemp -d)"; chmod 755 "$WORK"
# ---------------------------------------------------------------- keys
for k in root root2 sk sk2; do
  openssl genpkey -algorithm ed25519 -out "$WORK/$k.pem" 2>/dev/null
  openssl pkey -in "$WORK/$k.pem" -pubout -out "$WORK/$k.pub" 2>/dev/null
  chmod 644 "$WORK/$k.pub"
done
[[ -s "$WORK/root.pub" && -s "$WORK/sk.pub" ]] || { bad_t "openssl could not make ed25519 keys"; finish; }
kid() { openssl pkey -pubin -in "$1" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'; }
SK_ID="$(kid "$WORK/sk.pub")"; SK2_ID="$(kid "$WORK/sk2.pub")"
NOW="$(date +%s)"; LATER=$((NOW + 30*86400))
sign() { openssl pkeyutl -sign -inkey "$1" -rawin -in "$2" -out "$3"; } # <priv> <data> <sig>

# mkcert <dir> <root-priv> <pub> <not_after> [key_id] — signing-key.json + .sig
mkcert() {
  mkdir -p "$1"
  printf '%s' "$(jq -cn --arg id "${5:-$(kid "$3")}" --arg pk "$(cat "$3")" --argjson na "$4" \
    '{format:1,kind:"5dive-signing-key",key_id:$id,pubkey:$pk,not_after:$na}')" > "$1/signing-key.json"
  sign "$2" "$1/signing-key.json" "$1/signing-key.sig"
}
# mkrev <dir> <root-priv> <serial> [key_id…] — revoked.json + .sig
mkrev() {
  local d="$1" r="$2" n="$3"; shift 3; mkdir -p "$d"
  printf '%s' "$(jq -cn --argjson n "$n" '{format:1,kind:"5dive-revocations",serial:$n,revoked:$ARGS.positional}' --args "$@")" > "$d/revoked.json"
  sign "$r" "$d/revoked.json" "$d/revoked.sig"
}

# ---------------------------------------------------------------- fixtures
mk_release() { # <dir> <version>
  local t="$1" v="$2"
  mkdir -p "$t"/{bin,prompts,hooks,systemd,scripts/git-hooks-portable,.github}
  printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="%s"\n' "$v" > "$t/5dive"; chmod 755 "$t/5dive"
  echo 5dive-agent-start > "$t/bin/host-scripts.manifest"
  : > "$t/prompts/team-CLAUDE.md"; : > "$t/hooks/h.sh"; : > "$t/systemd/5dive-agent@.service"
  : > "$t/scripts/install-pii-push-guard.sh"; : > "$t/scripts/pii-scan.sh"
  : > "$t/scripts/git-hooks-portable/pre-push"; : > "$t/scripts/git-hooks-portable/prepare-commit-msg"
  : > "$t/.github/pii-denylist.txt"
  printf '#!/usr/bin/env bash\noffline_update() { :; }\n' > "$t/install.sh"
}
mk_release "$WORK/rel" 2.0.0
P="$WORK/plugins"; mkdir -p "$P/.claude-plugin" "$P/plugins/dashboard"
echo '{"name":"5dive-plugins","plugins":[]}' > "$P/.claude-plugin/marketplace.json"
echo 'console.log("v2")' > "$P/plugins/dashboard/server.ts"
S="$WORK/skills"; mkdir -p "$S/5dive-cli"; echo '# 5dive-cli' > "$S/5dive-cli/SKILL.md"
printf '#!/bin/sh\necho bun\n' > "$WORK/bun"; chmod 755 "$WORK/bun"

T1="$WORK/trust1"; mkcert "$T1" "$WORK/root.pem" "$WORK/sk.pub" "$LATER"; mkrev "$T1" "$WORK/root.pem" 1
build() { # <out-dir> <signing-key> [trust-dir] — prints the file
  OFFLINE_TRUST_DIR="${3:-}" bash "$B" "$WORK/rel" "$P" "$S" "$WORK/bun" "$WORK/$1" "$2" 2>"$WORK/build.err"
}
GOOD="$(build out-good "$WORK/sk.pem" "$T1")" || GOOD=""
[[ -f "$GOOD" ]] || { bad_t "builder: no file with a trust folder" "$(cat "$WORK/build.err")"; finish; }
PLAIN="$(build out-plain "$WORK/sk.pem")" || PLAIN=""
[[ -f "$PLAIN" ]] || { bad_t "builder: no file without a trust folder" "$(cat "$WORK/build.err")"; finish; }

# The builder embeds the four files byte for byte, as base64, in the signed manifest.
man="$(tar -xOf "$GOOD" manifest.json)"; embedded=1
for pair in signing_key:signing-key.json signing_key_sig:signing-key.sig revoked:revoked.json revoked_sig:revoked.sig; do
  cmp -s <(jq -r --arg k "${pair%%:*}" '.trust[$k]' <<<"$man" | base64 -d) "$T1/${pair#*:}" || embedded=0
done
(( embedded )) && [[ "$(jq -r '.format' <<<"$man")" == 1 ]] \
  && ok_t "builder: the trust folder rides in manifest.json as base64, byte for byte, format still 1" \
  || bad_t "builder: trust not embedded exactly" "$man"
[[ "$(tar -xOf "$PLAIN" manifest.json | jq -r 'has("trust")')" == false ]] \
  && ok_t "builder: no trust folder, no trust field (the file is built as before)" || bad_t "builder: trust field without a trust folder"

# ---------------------------------------------------------------- the verifier
eval "$(sed -n '/^version_lt() {/,/^}/p' "$ROOT/src/cmd_selfupdate.sh")"
declare -F version_lt >/dev/null || bad_t "version_lt not extractable from src/cmd_selfupdate.sh"
warn() { echo "warn: $*" >&2; }
# shellcheck disable=SC1090
. "$LIB"
# A box with the root: the box file, the compiled key cleared (box file wins anyway).
export OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$WORK/root.pub"
export OFFLINE_UPDATE_PUBKEY_FILE="$WORK/sk2.pub"   # a pin that must NOT be what verifies on the root path
OFFLINE_UPDATE_ROOT_PUBKEY_PEM=''
fresh_state() { export OFFLINE_UPDATE_STATE_DIR; OFFLINE_UPDATE_STATE_DIR="$(mktemp -d "$WORK/state.XXXXXX")"; }
fresh_state

verify() { # <file> — rc of _ou_verify; reason in $WORK/why
  local st; st="$(mktemp -d "$WORK/st.XXXXXX")"
  _ou_verify "$1" "$st" 1.0.0 0; local rc=$?
  printf '%s\n' "$_OU_WHY" > "$WORK/why"; return $rc
}
accepted() { # <label> <file>
  if verify "$2"; then ok_t "$1"; else bad_t "$1" "REFUSED: $(cat "$WORK/why")"; fi
}
refused() { # <label> <file> <why-substring>
  if verify "$2"; then bad_t "$1" "ACCEPTED — the box would have installed it"
  elif grep -qi -- "$3" "$WORK/why"; then ok_t "$1 — \"$(cat "$WORK/why")\""
  else bad_t "$1 (refused for the wrong reason)" "$(cat "$WORK/why")"; fi
}
# variant <name> <trust-dir|-> <manifest-key> [fn] — the good file with its trust
# replaced (- = removed) and the manifest re-signed by <manifest-key>; <fn> runs
# inside the unpacked copy before signing. Prints the path.
variant() {
  local d="$WORK/v-$1" f="$WORK/$1.tar" t="$2"; rm -rf "$d"; mkdir -p "$d"
  tar -xf "$GOOD" -C "$d"
  if [[ "$t" == - ]]; then jq -c 'del(.trust)' "$d/manifest.json" > "$d/m"
  else
    jq -c --arg a "$(base64 -w0 < "$t/signing-key.json")" --arg b "$(base64 -w0 < "$t/signing-key.sig")" \
      --arg c "$(base64 -w0 < "$t/revoked.json")" --arg e "$(base64 -w0 < "$t/revoked.sig")" \
      '.trust = {signing_key: $a, signing_key_sig: $b, revoked: $c, revoked_sig: $e}' "$d/manifest.json" > "$d/m"
  fi
  mv "$d/m" "$d/manifest.json"
  [[ -n "${4:-}" ]] && ( cd "$d" && "$4" )
  sign "$3" "$d/manifest.json" "$d/manifest.sig"
  tar --no-recursion -cf "$f" -C "$d" manifest.json manifest.sig payload/bun payload/cli.tar.gz payload/plugins.tar.gz payload/skills.tar.gz
  printf '%s\n' "$f"
}
flip() { python3 -c 'import sys;p=sys.argv[1];b=bytearray(open(p,"rb").read());b[len(b)//2]^=1;open(p,"wb").write(b)' "$1"; }

# (a) GOOD.
if verify "$GOOD" && [[ "$_OU_VERSION" == 2.0.0 && -f "$OFFLINE_UPDATE_STATE_DIR/update-revoked.json" ]]; then
  ok_t "(a) GOOD: root -> certified key -> manifest verifies; the serial-1 list is kept"
else bad_t "(a) GOOD: the chained file was refused" "$(cat "$WORK/why")"; fi
# Keeping the list never re-modes the state dir (on a box it is /var/lib/5dive, 2750).
fresh_state; chmod 2750 "$OFFLINE_UPDATE_STATE_DIR"
if verify "$GOOD" && [[ "$(stat -c %a "$OFFLINE_UPDATE_STATE_DIR")" == 2750 && -f "$OFFLINE_UPDATE_STATE_DIR/update-revoked.json" ]]; then
  ok_t "(a) keeping the list leaves an existing state dir's mode alone (2750 stays 2750)"
else bad_t "(a) the state dir was re-moded" "$(stat -c %a "$OFFLINE_UPDATE_STATE_DIR") $(cat "$WORK/why")"; fi
# Key order and whitespace of the certified JSON do not matter (exact bytes, then jq).
TW="$WORK/trust-ws"; mkdir -p "$TW"
jq -n --arg id "$SK_ID" --arg pk "$(cat "$WORK/sk.pub")" --argjson na "$LATER" \
  '{not_after:$na, pubkey:$pk, key_id:$id, kind:"5dive-signing-key", format:1}' > "$TW/signing-key.json"
sign "$WORK/root.pem" "$TW/signing-key.json" "$TW/signing-key.sig"
printf '{ "revoked" : [ ],\n  "serial" : 1, "kind":"5dive-revocations", "format" : 1 }\n' > "$TW/revoked.json"
sign "$WORK/root.pem" "$TW/revoked.json" "$TW/revoked.sig"
fresh_state; accepted "(a) GOOD: reordered keys and pretty-printed whitespace in the certified files verify" "$(variant ws "$TW" "$WORK/sk.pem")"

# (b) ONE BYTE CHANGED.
fresh_state
fx() { flip payload/bun; }
refused "(b) a byte of payload/bun changed (manifest re-signed by the certified key)" "$(variant flipbun "$T1" "$WORK/sk.pem" fx)" "changed after the file was signed"
TB="$WORK/trust-b"; cp -r "$T1" "$TB"; sed -i "s/\"not_after\":$LATER/\"not_after\":$((LATER + 1))/" "$TB/signing-key.json"
refused "(b) a byte of the certified signing-key.json changed (expiry pushed out)" "$(variant flipcert "$TB" "$WORK/sk.pem")" "not certified by 5dive's root key"
cp "$GOOD" "$WORK/flipgood.tar"; d="$WORK/fg"; mkdir -p "$d"; tar -xf "$GOOD" -C "$d"; flip "$d/payload/skills.tar.gz"
tar --no-recursion -cf "$WORK/flipgood.tar" -C "$d" manifest.json manifest.sig payload/bun payload/cli.tar.gz payload/plugins.tar.gz payload/skills.tar.gz
refused "(b) a byte of payload/skills.tar.gz changed, signature untouched" "$WORK/flipgood.tar" "changed after the file was signed"

# (c) REVOKED: a serial-2 list naming the signing key.
fresh_state
TC="$WORK/trust-c"; mkcert "$TC" "$WORK/root.pem" "$WORK/sk.pub" "$LATER"; mkrev "$TC" "$WORK/root.pem" 2 "$SK2_ID" "$SK_ID"
REVOKED="$(variant revoked "$TC" "$WORK/sk.pem")"
refused "(c) the signing key is on the root's serial-2 revocation list" "$REVOKED" "has been revoked"
[[ ! -e "$OFFLINE_UPDATE_STATE_DIR/update-revoked.json" ]] \
  && ok_t "(c) a refused file's revocation list is not kept (only a fully verified file's is)" \
  || bad_t "(c) the list of a refused file was kept"
TC2="$WORK/trust-c2"; mkcert "$TC2" "$WORK/root.pem" "$WORK/sk.pub" "$LATER"; mkrev "$TC2" "$WORK/root2.pem" 2
refused "(c) a revocation list signed by another root" "$(variant revroot2 "$TC2" "$WORK/sk.pem")" "not signed by 5dive's root key"

# (d) EXPIRED.
TD="$WORK/trust-d"; mkcert "$TD" "$WORK/root.pem" "$WORK/sk.pub" $((NOW - 60)); mkrev "$TD" "$WORK/root.pem" 1
EXPIRED="$(variant expired "$TD" "$WORK/sk.pem")"
refused "(d) the certificate expired a minute ago" "$EXPIRED" "expired on $(date -u -d "@$((NOW - 60))" +%F)"
grep -q "clock" "$WORK/why" && ok_t "(d) the expiry refusal tells the owner to check the box clock" || bad_t "(d) no clock hint" "$(cat "$WORK/why")"
OFFLINE_UPDATE_NOW=$((LATER - 1)) accepted "(d) a second before not_after the good file still verifies" "$GOOD"
OFFLINE_UPDATE_NOW=$LATER refused "(d) at not_after exactly the good file is refused" "$GOOD" "expired on"

# (e) ANOTHER ROOT certified the key (the revocation list is the real root's).
TE="$WORK/trust-e"; mkcert "$TE" "$WORK/root2.pem" "$WORK/sk.pub" "$LATER"; mkrev "$TE" "$WORK/root.pem" 1
OTHERROOT="$(variant otherroot "$TE" "$WORK/sk.pem")"
refused "(e) the signing key is certified by another root" "$OTHERROOT" "not certified by 5dive's root key"

# (f) key_id NOT the pubkey's (names SK2, carries SK).
TF="$WORK/trust-f"; mkcert "$TF" "$WORK/root.pem" "$WORK/sk.pub" "$LATER" "$SK2_ID"; mkrev "$TF" "$WORK/root.pem" 1
BADID="$(variant badid "$TF" "$WORK/sk.pem")"
refused "(f) the certificate's key_id is not the sha256 of the key it carries" "$BADID" "names a different key than it carries"

# (g) MANIFEST SIGNED BY AN UNCERTIFIED KEY (the cert is valid, for SK; SK2 signed).
UNCERT="$(variant uncert "$T1" "$WORK/sk2.pem")"
refused "(g) the manifest is signed by a key the root did not certify" "$UNCERT" "root key certified"

# (h) ROOT PRESENT, NO TRUST.
refused "(h) a box with the root refuses a file with no certificate (the builder's plain file)" "$PLAIN" "not signed by 5dive's root key"
refused "(h) the same with the trust field stripped and re-signed by the certified key" "$(variant notrust - "$WORK/sk.pem")" "not signed by 5dive's root key"
fx() { jq -c '.trust.revoked_sig = "%%%not-base64"' manifest.json > m && mv m manifest.json; }
refused "(h) a trust object with a damaged field" "$(variant badb64 "$T1" "$WORK/sk.pem" fx)" "incomplete or damaged"
# The compiled-in root (no box file) is a root too.
OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$WORK/no-root-file.pem" OFFLINE_UPDATE_ROOT_PUBKEY_PEM="$(cat "$WORK/root.pub")" \
  accepted "(h) the compiled-in root (no box file): the chained file verifies" "$GOOD"
OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$WORK/no-root-file.pem" OFFLINE_UPDATE_ROOT_PUBKEY_PEM="$(cat "$WORK/root.pub")" \
  refused "(h) the compiled-in root (no box file): a file with no certificate is refused" "$PLAIN" "not signed by 5dive's root key"

# (i) NO ROOT: the direct pin, as before.
noroot() { OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$WORK/no-root-file.pem" OFFLINE_UPDATE_ROOT_PUBKEY_PEM='' OFFLINE_UPDATE_PUBKEY_FILE="$WORK/sk.pub" "$@"; }
noroot accepted "(i) no root: the plain file verifies by the pinned key" "$PLAIN"
noroot accepted "(i) no root: a file WITH trust verifies by the pinned key (trust ignored)" "$GOOD"
noroot refused "(i) no root: a file with a revoked/uncertified chain is still judged by the pin only" "$UNCERT" "does not match 5dive's update key"
noroot refused "(i) no root: a file signed by another key is refused with today's words" "$(build out-sk2 "$WORK/sk2.pem")" "the signature does not match 5dive's update key — the file was changed or was not made by 5dive"
noroot verify "$GOOD"; [[ ! -e "$WORK/no-root-file.pem" ]] && ok_t "(i) no root: nothing creates a root file" || bad_t "(i) a root file appeared"

# (j) THE KEPT LIST. SKOLD is a second certified key; serial 2 revokes it.
openssl genpkey -algorithm ed25519 -out "$WORK/skold.pem" 2>/dev/null; openssl pkey -in "$WORK/skold.pem" -pubout -out "$WORK/skold.pub" 2>/dev/null
SKOLD_ID="$(kid "$WORK/skold.pub")"
TJ2="$WORK/trust-j2"; mkcert "$TJ2" "$WORK/root.pem" "$WORK/sk.pub" "$LATER"; mkrev "$TJ2" "$WORK/root.pem" 2 "$SKOLD_ID"
TJ1="$WORK/trust-j1"; mkcert "$TJ1" "$WORK/root.pem" "$WORK/skold.pub" "$LATER"; mkrev "$TJ1" "$WORK/root.pem" 1
SER2="$(variant ser2 "$TJ2" "$WORK/sk.pem")"; OLDKEY="$(variant oldkey "$TJ1" "$WORK/skold.pem")"
fresh_state
accepted "(j) control: on a box that never saw serial 2, SKOLD's file (serial-1 list) verifies" "$OLDKEY"
fresh_state; KEPT_DIR="$OFFLINE_UPDATE_STATE_DIR"
accepted "(j) a file signed by SK carrying the serial-2 list (revokes SKOLD) verifies" "$SER2"
[[ "$(jq -r .serial "$KEPT_DIR/update-revoked.json" 2>/dev/null)" == 2 ]] && cmp -s "$KEPT_DIR/update-revoked.json" "$TJ2/revoked.json" \
  && ok_t "(j) the box now keeps the serial-2 list, byte for byte" || bad_t "(j) serial-2 list not kept"
JKILL="$OLDKEY"
refused "(j) then SKOLD's file carrying serial 1 (which revokes nothing) is STILL refused" "$OLDKEY" "has been revoked"
[[ "$(jq -r .serial "$KEPT_DIR/update-revoked.json")" == 2 ]] && ok_t "(j) the lower serial did not replace the kept list" || bad_t "(j) kept list went backwards"
TJ3="$WORK/trust-j3"; mkcert "$TJ3" "$WORK/root.pem" "$WORK/sk.pub" "$LATER"; mkrev "$TJ3" "$WORK/root.pem" 3
fx() { flip payload/plugins.tar.gz; }
refused "(j) a serial-3 file that fails later (payload changed)" "$(variant ser3bad "$TJ3" "$WORK/sk.pem" fx)" "changed after the file was signed"
[[ "$(jq -r .serial "$KEPT_DIR/update-revoked.json")" == 2 ]] \
  && ok_t "(j) its serial-3 list was NOT kept: a list is kept only after the whole file verified" || bad_t "(j) a failed file's list was kept"
# A kept list others can write is not trusted: the file's own list applies.
LOOSE="$WORK/state-loose"; cp -a "$KEPT_DIR" "$LOOSE"; chmod 666 "$LOOSE/update-revoked.json"
OFFLINE_UPDATE_STATE_DIR="$LOOSE" accepted "(j) a kept list others can write is ignored (the file's own list applies)" "$OLDKEY"
fresh_state; cp "$TJ2/revoked.json" "$OFFLINE_UPDATE_STATE_DIR/update-revoked.json"; cp "$TJ1/revoked.sig" "$OFFLINE_UPDATE_STATE_DIR/update-revoked.sig"
accepted "(j) a kept list whose signature does not verify is ignored" "$OLDKEY"

# (j) EQUAL SERIAL (quinn, DIVE-7888 iteration 1): the box keeps serial-1 [SKOLD];
# SKOLD's file carries a DIFFERENT serial-1 list ([]). Equal serials cannot be
# ordered, so both lists apply and SKOLD stays revoked.
TQ="$WORK/trust-q"; mkcert "$TQ" "$WORK/root.pem" "$WORK/sk.pub" "$LATER"; mkrev "$TQ" "$WORK/root.pem" 1 "$SKOLD_ID"
TIE1="$(variant tie1 "$TQ" "$WORK/sk.pem")"
fresh_state; TIE_DIR="$OFFLINE_UPDATE_STATE_DIR"
accepted "(j=) a file signed by SK carrying serial-1 [SKOLD] verifies on a fresh box" "$TIE1"
cmp -s "$TIE_DIR/update-revoked.json" "$TQ/revoked.json" && ok_t "(j=) the box keeps serial-1 [SKOLD]" || bad_t "(j=) serial-1 [SKOLD] not kept"
cp -a "$TIE_DIR" "$WORK/state-tie"   # an untouched copy for the mutant
refused "(j=) then SKOLD's file with the OTHER serial-1 list ([]) is refused" "$OLDKEY" "has been revoked"
cmp -s "$TIE_DIR/update-revoked.json" "$TQ/revoked.json" \
  && ok_t "(j=) an equal serial did not replace the kept list" || bad_t "(j=) the equal-serial list replaced the kept one"
accepted "(j=) control: SK's file with serial-1 [] still verifies there (the union refuses only what a list names)" "$GOOD"

# (k) ROOT KEY FILE OTHERS CAN WRITE.
cp "$WORK/root.pub" "$WORK/loose-root.pub"; chmod 666 "$WORK/loose-root.pub"
OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$WORK/loose-root.pub" refused "(k) a root key file others can write is not trusted (refused, not skipped)" "$GOOD" "cannot be trusted as the root key"
OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$WORK/loose-root.pub" OFFLINE_UPDATE_PUBKEY_FILE="$WORK/sk.pub" \
  refused "(k) ... and the box does not fall back to the pinned key either" "$PLAIN" "cannot be trusted as the root key"

# (l) THE PRE-DIVE-7888 VERIFIER (what boxes run today) takes a file WITH trust.
if old="$(git show "$OLD_SHA:src/lib/offline_update.sh" 2>/dev/null)" && [[ -n "$old" ]]; then
  oldblk="$(sed -n '/^# >>> DIVE-7577 offline update verifier/,/^# <<< DIVE-7577 offline update verifier/p' <<<"$old")"
  if [[ "$oldblk" != *OFFLINE_UPDATE_ROOT* && "$oldblk" == *"_ou_verify()"* ]] \
     && ( eval "$oldblk"; export OFFLINE_UPDATE_PUBKEY_FILE="$WORK/sk.pub"
          st="$(mktemp -d "$WORK/old.XXXXXX")"; _ou_verify "$GOOD" "$st" 1.0.0 0 && [[ "$_OU_VERSION" == 2.0.0 ]] ); then
    ok_t "(l) the verifier at $OLD_SHA (no root support) accepts a file WITH the trust object — old boxes take new files"
  else bad_t "(l) the pre-DIVE-7888 verifier refuses a file with trust" "old boxes could not update"; fi
else bad_t "(l) commit $OLD_SHA not in this checkout (CI checks out with fetch-depth 0)"; fi

# ---------------------------------------------------------------- the builder
build out-x "$WORK/sk2.pem" "$T1" >/dev/null && bad_t "builder: signed with SK2 using SK's certificate" \
  || { grep -q 'for another key' "$WORK/build.err" && ok_t "builder: refuses a certificate for another key than the signing key" \
       || bad_t "builder refused for another reason" "$(cat "$WORK/build.err")"; }
build out-x "$WORK/sk.pem" "$TD" >/dev/null && bad_t "builder: built with an expired certificate" \
  || { grep -q 'expired' "$WORK/build.err" && ok_t "builder: refuses an expired certificate" || bad_t "builder expiry refusal" "$(cat "$WORK/build.err")"; }
build out-x "$WORK/sk.pem" "$TC" >/dev/null && bad_t "builder: built with a revoked key" \
  || { grep -q 'revocation list' "$WORK/build.err" && ok_t "builder: refuses a signing key on the revocation list" || bad_t "builder revocation refusal" "$(cat "$WORK/build.err")"; }
# The root compiled into the tag's 5dive: a cert by ROOT2 is refused, by ROOT built.
cp "$WORK/rel/5dive" "$WORK/5dive.orig"
{ printf "OFFLINE_UPDATE_PUBKEY_PEM='x'\n"; printf "OFFLINE_UPDATE_ROOT_PUBKEY_PEM='%s'\n" "$(cat "$WORK/root.pub")"; echo "OTHER='y'"; } >> "$WORK/rel/5dive"
build out-x "$WORK/sk.pem" "$TE" >/dev/null && bad_t "builder: built with a certificate the compiled root did not sign" \
  || { grep -q 'does not verify against the root key compiled' "$WORK/build.err" && ok_t "builder: refuses a certificate the tag's compiled root did not sign" \
       || bad_t "builder compiled-root refusal" "$(cat "$WORK/build.err")"; }
[[ -f "$(build out-y "$WORK/sk.pem" "$T1")" ]] && ok_t "builder: builds when the tag's compiled (multi-line) root signed the certificate" \
  || bad_t "builder: refused a certificate the compiled root signed" "$(cat "$WORK/build.err")"
build out-z "$WORK/sk.pem" >/dev/null; grep -q 'boxes that hold the root will refuse this file' "$WORK/build.err" \
  && ok_t "builder: a tag with a compiled root and no trust folder is warned about" || bad_t "builder: no warning" "$(cat "$WORK/build.err")"
cp "$WORK/5dive.orig" "$WORK/rel/5dive"; { echo "OFFLINE_UPDATE_ROOT_PUBKEY_PEM=''"; echo "OTHER='y'"; } >> "$WORK/rel/5dive"
[[ -f "$(build out-w "$WORK/sk.pem" "$TE")" ]] && ok_t "builder: an EMPTY compiled root ('' on one line) is no root (nothing to compare)" \
  || bad_t "builder: an empty compiled root was read as a key" "$(cat "$WORK/build.err")"
cp "$WORK/5dive.orig" "$WORK/rel/5dive"

# ---------------------------------------------------------------- --write-pubkey
WK="$WORK/etc5"; mkdir -p "$WK"
( OFFLINE_UPDATE_PUBKEY_FILE="$WK/update-pubkey.pem" OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$WK/update-root.pem"
  OFFLINE_UPDATE_ROOT_PUBKEY_PEM="$(cat "$WORK/root.pub")"; _ou_write_pubkey )
[[ "$(cat "$WK/update-root.pem")" == "$(cat "$WORK/root.pub")" && "$(stat -c %a "$WK/update-root.pem")" == 644 && -s "$WK/update-pubkey.pem" ]] \
  && ok_t "--write-pubkey: a compiled root is written to update-root.pem (644) beside the release key" \
  || bad_t "--write-pubkey: root not written" "$(ls -la "$WK")"
( OFFLINE_UPDATE_PUBKEY_FILE="$WK/update-pubkey.pem" OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$WK/update-root.pem"
  OFFLINE_UPDATE_ROOT_PUBKEY_PEM=''; _ou_write_pubkey )
[[ "$(cat "$WK/update-root.pem")" == "$(cat "$WORK/root.pub")" ]] \
  && ok_t "--write-pubkey: an empty compiled root writes nothing and removes nothing" || bad_t "--write-pubkey: empty root touched the file"
# shellcheck disable=SC2034  # read by _ou_write_pubkey
( OFFLINE_UPDATE_PUBKEY_FILE="$WK/p2.pem" OFFLINE_UPDATE_ROOT_PUBKEY_FILE="$WK/r2.pem" OFFLINE_UPDATE_ROOT_PUBKEY_PEM=''; _ou_write_pubkey )
[[ ! -e "$WK/r2.pem" ]] && ok_t "--write-pubkey: no compiled root, no root file" || bad_t "--write-pubkey: wrote an empty root file"
grep -q "^OFFLINE_UPDATE_ROOT_PUBKEY_PEM=''$" "$LIB" \
  && ok_t "SHIPPED: the compiled root is empty until the owner's key ceremony (behaviour unchanged on release)" \
  || ok_t "SHIPPED: a root key is compiled in"

# ---------------------------------------------------------------- mutants
# Each drops ONE check from a copy of the shipped verifier; the matching bad
# file must then verify, which proves that arm grades that check.
mutant() { # <label> <sed-expr> <file> [state-dir]
  local mut; mut="$(sed "$2" "$LIB")"
  if [[ "$mut" == "$(cat "$LIB")" ]]; then bad_t "MUTANT $1" "the patch matched nothing — the arm is unproven"; return; fi
  # A fresh state dir each (a mutant that lets a list through also KEEPS it).
  if ( eval "$mut"; OFFLINE_UPDATE_STATE_DIR="${4:-$(mktemp -d "$WORK/mstate.XXXXXX")}"; verify "$3" ); then
    ok_t "MUTANT $1: with that check dropped the bad file verifies (the arm is live)"
  else bad_t "MUTANT $1" "still refused with the check dropped: $(cat "$WORK/why")"; fi
}
mutant "no revocation check (c)" 's/index(\$k) != null/false/' "$REVOKED"
mutant "no expiry check (d)" 's/(( now < not_after ))/true/' "$EXPIRED"
mutant "no root check on the certificate (e)" 's/_ou_sig_ok "\$root" "\$t\/signing_key"/true/' "$OTHERROOT"
mutant "no key_id recomputation (f)" 's/"\$(_ou_key_id "\$skey")" == "\$key_id"/1 == 1/' "$BADID"
mutant "the manifest checked with the pinned key, not the certified one (g)" 's/^    key="\$meta\/certified.pem"$/    key="$OFFLINE_UPDATE_PUBKEY_FILE"/' "$UNCERT"
cp -a "$KEPT_DIR" "$WORK/state-j"
mutant "the higher kept serial ignored (j)" 's/if (( kept_serial >= got )); then union=1/if false; then :/' "$JKILL" "$WORK/state-j"
mutant "an equal kept serial ignored (j=)" 's/if (( kept_serial >= got )); then union=1/if (( kept_serial > got )); then union=1/' "$OLDKEY" "$WORK/state-tie"

finish
