# -------- signed online updates: every release is checked against OUR key (DIVE-7816) --------
#
# THE GAP THIS CLOSES. Before this file, the only integrity check on an online
# update was 5dive.sha256, fetched from the same tree as the bundle it checks,
# and the installer itself was re-fetched from `main` on every run. Anyone who
# could push to the repo (one stolen login), or serve a tree in its place, held
# both halves, and every box ran it as root at its next nightly.
#
# THE CHAIN, all ed25519, all checked with `openssl pkeyutl -rawin` — the same
# call the offline updater uses, so no box needs a new package:
#
#   ROOT KEY (offline; a password manager + one sealed backup). Its PUBLIC
#   half is compiled in below. It signs exactly two things:
#     signing-key.json  {"format":1,"kind":"5dive-signing-key","key_id":"<hex>",
#                        "pubkey":"<PEM>","not_after":<epoch>}       + signing-key.sig
#     revoked.json      {"format":1,"kind":"5dive-revocations","serial":<n>,
#                        "revoked":["<key_id>",…]}                   + revoked.sig
#   SIGNING KEY (its own machine — never GitHub Actions, never the API host,
#   never an agent seat). It signs one manifest per release:
#     release.json      {"format":1,"kind":"5dive-release","tag":"vX.Y.Z",
#                        "commit":"<40 hex>","bundle_sha256":"<64 hex>",
#                        "installer_sha256":"<64 hex>","key_id":"<hex>"} + release.sig
#
# All six files hang off the GitHub release of the tag. They MAY be replaced by
# anyone with write access — that is fine, because nothing here trusts where a
# file came from, only what signed it. key_id is the sha256 of the signing key's
# DER public key, recomputed here, so a certificate cannot name one key and
# carry another.
#
# THE BOX VERIFIES WITH WHAT IT ALREADY HAS. The root key is in THIS installed
# CLI; nothing fetched in the same download can vouch for itself. The installer
# and the bundle are fetched from the signed COMMIT (raw/<commit>/…), their
# sha256 checked against the signed manifest, and only then is the verified
# installer run, handed the verified bundle. A downgrade to an OLDER signed
# release is still refused by install.sh's monotonic guard (DIVE-2243).
#
# REVOCATION. The box keeps the newest root-signed revocation list it has ever
# accepted ($SIGNED_UPDATE_STATE_DIR/revoked.json). A release carrying an OLDER
# list than that does not un-revoke anything: the higher serial wins. A box that
# never saw a revocation trusts the certificate until its not_after — that is
# what the expiry is for.
#
# FIRST INSTALL (curl | bash) cannot do any of this: there is no installed CLI
# yet to hold the key. That is accepted and documented (docs/signed-updates.md),
# with the root key's fingerprint published for anyone who wants to check by
# hand.
#
# ROLLOUT. SIGNED_UPDATE_ENFORCE=0 is the warn-only release: a failed check is
# logged, recorded for `5dive doctor`, and the update proceeds the old way.
# The next release flips it to 1: a failed check REFUSES, the box keeps the CLI
# it has, and the owner sees one plain line. A box with no root key compiled in
# and enforcement on refuses everything — the safe failure is chosen, not
# inherited.

# The root PUBLIC key, compiled in. EMPTY until the root key ceremony (DIVE-7816
# gate) — then pasted here as `openssl pkey -in root.pem -pubout`.
SIGNED_UPDATE_ROOT_PUBKEY_PEM=''
SIGNED_UPDATE_ENFORCE=0

# >>> DIVE-7816 signed update verifier
#     (tests/signed_update_unit.sh extracts this block VERBATIM between these
#      markers and runs the shipped bytes — keep them.)

_su_sig_state_dir() { printf '%s\n' "${SIGNED_UPDATE_STATE_DIR:-${STATE_DIR:-/var/lib/5dive}/self-update}"; }
_su_sig_base()      { printf '%s\n' "${SIGNED_UPDATE_BASE:-https://github.com/$(gh_org)/5dive/releases/download}"; }
_su_sig_raw()       { printf '%s\n' "${SIGNED_UPDATE_RAW:-https://raw.githubusercontent.com/$(gh_org)/5dive}"; }

# _su_sig_trusted_file <path> — 0 when root (or the caller) owns it and group/
# other cannot write it. A key or a revocation list anyone else can edit is not
# a pin.
_su_sig_trusted_file() {
  local f="$1" own mode
  own="$(stat -c %u "$f" 2>/dev/null)" || return 1
  mode="$(stat -c %a "$f" 2>/dev/null)" || return 1
  [[ "$own" == 0 || "$own" == "$(id -u)" ]] || return 1
  (( (8#$mode & 8#022) == 0 ))
}

# _su_sig_root_key <out> — the root public key this box trusts. The compiled-in
# key; SIGNED_UPDATE_ROOT_PUBKEY_FILE replaces it only when that file is a
# trusted pin (the harness uses it; root can already replace this CLI anyway).
_su_sig_root_key() {
  local out="$1" f="${SIGNED_UPDATE_ROOT_PUBKEY_FILE:-}"
  if [[ -n "$f" ]]; then
    [[ -f "$f" ]] || { _SU_SIG_WHY="could not read the update root key file $f"; return 1; }
    _su_sig_trusted_file "$f" || { _SU_SIG_WHY="the update root key file $f is not owned by root or is writable by others"; return 1; }
    cp "$f" "$out" 2>/dev/null && [[ -s "$out" ]] && return 0
    _SU_SIG_WHY="could not read the update root key file $f"; return 1
  fi
  if [[ -n "$SIGNED_UPDATE_ROOT_PUBKEY_PEM" ]]; then
    printf '%s\n' "$SIGNED_UPDATE_ROOT_PUBKEY_PEM" > "$out" && return 0
  fi
  _SU_SIG_WHY="this 5dive has no update signing key built in yet, so it cannot check who made an update"
  return 1
}

# _su_sig_check <pubkey.pem> <data> <sig> — raw ed25519 over the exact bytes.
_su_sig_check() {
  openssl pkeyutl -verify -pubin -inkey "$1" -rawin -in "$2" -sigfile "$3" >/dev/null 2>&1
}

# _su_sig_key_id <pubkey.pem> — sha256 of the DER public key.
_su_sig_key_id() {
  openssl pkey -pubin -in "$1" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

_su_sig_fetch() { # <url> <out>
  curl -fsSL --max-time "${SIGNED_UPDATE_TIMEOUT:-60}" -o "$2" "$1" 2>/dev/null && [[ -s "$2" ]]
}

# _su_sig_verify <tag> <work-dir>
# 0 = verified: $SU_SIG_INSTALLER and $SU_SIG_BUNDLE are the signed files (in
#     <work-dir>), $SU_SIG_COMMIT the signed commit, $SU_SIG_BUNDLE_SHA256 its hash.
# 1 = refused: $_SU_SIG_WHY says why in plain words.
# <work-dir> must be an empty directory the caller owns.
_su_sig_verify() {
  local tag="$1" w="$2"
  _SU_SIG_WHY="" SU_SIG_INSTALLER="" SU_SIG_BUNDLE="" SU_SIG_COMMIT="" SU_SIG_BUNDLE_SHA256="" SU_SIG_KEY_ID=""
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { _SU_SIG_WHY="no release version to check ('$tag')"; return 1; }
  [[ -d "$w" ]] || { _SU_SIG_WHY="internal: no work directory"; return 1; }
  command -v openssl >/dev/null 2>&1 || { _SU_SIG_WHY="openssl is not installed, so the signature cannot be checked"; return 1; }

  local root="$w/root.pem"
  _su_sig_root_key "$root" || return 1

  # 1. The six signed files for this tag.
  local base f; base="$(_su_sig_base)/$tag"
  for f in signing-key.json signing-key.sig revoked.json revoked.sig release.json release.sig; do
    _su_sig_fetch "$base/$f" "$w/$f" \
      || { _SU_SIG_WHY="release $tag is not signed (could not fetch $f)"; return 1; }
  done

  # 2. The signing key, certified by the ROOT key.
  _su_sig_check "$root" "$w/signing-key.json" "$w/signing-key.sig" \
    || { _SU_SIG_WHY="the signing key of $tag is not certified by 5dive's root key"; return 1; }
  jq -e '.format == 1 and .kind == "5dive-signing-key" and (.key_id|type == "string")
         and (.pubkey|type == "string") and (.not_after|type == "number")' "$w/signing-key.json" >/dev/null 2>&1 \
    || { _SU_SIG_WHY="the signing key certificate of $tag is not in a format this 5dive reads"; return 1; }
  local skey="$w/signing.pem" key_id not_after now
  jq -r '.pubkey' "$w/signing-key.json" > "$skey"
  key_id="$(jq -r '.key_id' "$w/signing-key.json")"
  [[ "$(_su_sig_key_id "$skey")" == "$key_id" && "$key_id" =~ ^[0-9a-f]{64}$ ]] \
    || { _SU_SIG_WHY="the signing key certificate of $tag names a different key than it carries"; return 1; }
  not_after="$(jq -r '.not_after | floor' "$w/signing-key.json")"
  now="${SIGNED_UPDATE_NOW:-$(date +%s)}"
  (( now < not_after )) \
    || { _SU_SIG_WHY="the key that signed $tag expired on $(date -u -d "@$not_after" +%F 2>/dev/null || echo "$not_after")"; return 1; }

  # 3. Revocation: the newest root-signed list this box has ever seen wins.
  _su_sig_check "$root" "$w/revoked.json" "$w/revoked.sig" \
    || { _SU_SIG_WHY="the revocation list of $tag is not signed by 5dive's root key"; return 1; }
  jq -e '.format == 1 and .kind == "5dive-revocations" and (.serial|type == "number")
         and (.revoked|type == "array")' "$w/revoked.json" >/dev/null 2>&1 \
    || { _SU_SIG_WHY="the revocation list of $tag is not in a format this 5dive reads"; return 1; }
  local st kept list="$w/revoked.json" got_serial kept_serial
  st="$(_su_sig_state_dir)"; kept="$st/revoked.json"
  got_serial="$(jq -r '.serial | floor' "$w/revoked.json")"
  if [[ -f "$kept" && -f "$st/revoked.sig" ]] && _su_sig_trusted_file "$kept" \
     && _su_sig_check "$root" "$kept" "$st/revoked.sig"; then
    kept_serial="$(jq -r '.serial | floor' "$kept" 2>/dev/null)" || kept_serial=0
    [[ "$kept_serial" =~ ^[0-9]+$ ]] || kept_serial=0
    if (( kept_serial > got_serial )); then
      list="$kept"
    fi
  fi
  if [[ "$list" == "$w/revoked.json" ]]; then
    # Newer (or first) root-signed list: keep it. Safe to store before the rest
    # of the check — it is root-signed whatever this release turns out to be.
    install -d -m 755 "$st" 2>/dev/null \
      && cp "$w/revoked.json" "$kept.tmp.$$" 2>/dev/null && cp "$w/revoked.sig" "$st/revoked.sig.tmp.$$" 2>/dev/null \
      && chmod 644 "$kept.tmp.$$" "$st/revoked.sig.tmp.$$" \
      && mv -f "$st/revoked.sig.tmp.$$" "$st/revoked.sig" && mv -f "$kept.tmp.$$" "$kept" \
      || rm -f "$kept.tmp.$$" "$st/revoked.sig.tmp.$$" 2>/dev/null
  fi
  if jq -e --arg k "$key_id" '.revoked | index($k) != null' "$list" >/dev/null 2>&1; then
    _SU_SIG_WHY="$tag was signed by a key 5dive has revoked"; return 1
  fi

  # 4. The release manifest, signed by the certified signing key.
  _su_sig_check "$skey" "$w/release.json" "$w/release.sig" \
    || { _SU_SIG_WHY="the signature on $tag does not match 5dive's signing key — the release was changed or was not made by 5dive"; return 1; }
  jq -e '.format == 1 and .kind == "5dive-release"' "$w/release.json" >/dev/null 2>&1 \
    || { _SU_SIG_WHY="the release manifest of $tag is not in a format this 5dive reads"; return 1; }
  local m_tag commit bsha isha mkid
  m_tag="$(jq -r '.tag // ""' "$w/release.json")"; commit="$(jq -r '.commit // ""' "$w/release.json")"
  bsha="$(jq -r '.bundle_sha256 // ""' "$w/release.json")"; isha="$(jq -r '.installer_sha256 // ""' "$w/release.json")"
  mkid="$(jq -r '.key_id // ""' "$w/release.json")"
  [[ "$m_tag" == "$tag" ]] || { _SU_SIG_WHY="the signed manifest is for ${m_tag:-no version}, not $tag"; return 1; }
  [[ "$mkid" == "$key_id" ]] || { _SU_SIG_WHY="the signed manifest of $tag names a different signing key"; return 1; }
  [[ "$commit" =~ ^[0-9a-f]{40}$ && "$bsha" =~ ^[0-9a-f]{64}$ && "$isha" =~ ^[0-9a-f]{64}$ ]] \
    || { _SU_SIG_WHY="the signed manifest of $tag is missing its commit or file hashes"; return 1; }

  # 5. The two files that run as root, from the signed commit, against the
  #    signed hashes.
  local raw; raw="$(_su_sig_raw)/$commit"
  _su_sig_fetch "$raw/install.sh" "$w/install.sh" || { _SU_SIG_WHY="could not download the installer of $tag"; return 1; }
  _su_sig_fetch "$raw/5dive" "$w/5dive" || { _SU_SIG_WHY="could not download the 5dive program of $tag"; return 1; }
  [[ "$(sha256sum "$w/install.sh" | awk '{print $1}')" == "$isha" ]] \
    || { _SU_SIG_WHY="the installer of $tag does not match its signature — it was changed after signing"; return 1; }
  [[ "$(sha256sum "$w/5dive" | awk '{print $1}')" == "$bsha" ]] \
    || { _SU_SIG_WHY="the 5dive program of $tag does not match its signature — it was changed after signing"; return 1; }

  SU_SIG_INSTALLER="$w/install.sh" SU_SIG_BUNDLE="$w/5dive" SU_SIG_COMMIT="$commit"
  SU_SIG_BUNDLE_SHA256="$bsha" SU_SIG_KEY_ID="$key_id"
  return 0
}

# _su_sig_record <outcome> <tag> <detail> — what `5dive doctor` reads.
# outcome: verified | unsigned-warned | refused
_su_sig_record() {
  local st; st="$(_su_sig_state_dir)"
  install -d -m 755 "$st" 2>/dev/null || return 0
  printf 'at=%s\noutcome=%s\ntag=%s\ndetail=%s\nenforce=%s\n' \
    "$(date +%s)" "$1" "${2:-}" "${3:-}" "$SIGNED_UPDATE_ENFORCE" > "$st/signature.tmp.$$" 2>/dev/null \
    && mv -f "$st/signature.tmp.$$" "$st/signature" 2>/dev/null || rm -f "$st/signature.tmp.$$" 2>/dev/null
  return 0
}
# <<< DIVE-7816 signed update verifier

# _su_sig_target — the tag the installer would install, from the same ladder
# (override > canary > route > last-known, release hold honoured), via the
# probe `5dive update --check` and `doctor` already use. Prints the tag, or
# nothing.
_su_sig_target() {
  local -a p=()
  mapfile -t p < <(_published_cli_probe 2>/dev/null)
  [[ "${p[0]:-}" == consistent && "${p[2]:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s\n' "${p[2]}"
  return 0
}

# doctor_check_update_signing — one plain line about the last online update's
# signature check.
doctor_check_update_signing() {
  local f; f="$(_su_sig_state_dir)/signature"
  local mode="warn-only"; [[ "$SIGNED_UPDATE_ENFORCE" == 1 ]] && mode="enforced"
  if [[ ! -r "$f" ]]; then
    if [[ -z "$SIGNED_UPDATE_ROOT_PUBKEY_PEM" ]]; then
      doctor_add host update-signature warn "updates are not signature-checked yet: this 5dive has no update signing key built in ($mode)"
    else
      doctor_add host update-signature ok "no online update has run since signature checks arrived ($mode)"
    fi
    return 0
  fi
  local outcome tag detail
  outcome="$(sed -n 's/^outcome=//p' "$f" | head -n1)"; tag="$(sed -n 's/^tag=//p' "$f" | head -n1)"
  detail="$(sed -n 's/^detail=//p' "$f" | head -n1)"
  case "$outcome" in
    verified) doctor_add host update-signature ok "the last update${tag:+ ($tag)} was signed by 5dive and checked before it ran ($mode)" ;;
    refused)  doctor_add host update-signature warn "the last update${tag:+ ($tag)} was REFUSED: $detail. This box kept the version it had" ;;
    *)        doctor_add host update-signature warn "the last update${tag:+ ($tag)} was NOT signature-checked: $detail. It was installed anyway because checks are $mode this release" ;;
  esac
}
