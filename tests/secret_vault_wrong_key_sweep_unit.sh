#!/usr/bin/env bash
# TIER: nightly — 26.4s measured (poke-two, 2026-11-09, DIVE-8028): a 400-key statistical sweep, 3 pbkdf2 decrypts per key; it put core shard 1 over its 300s cap. Core keeps L17n (one wrong key) and L17t (deterministic forgery).
# DIVE-7274 L17s, moved out of tests/secret_drop_link_unit.sh by DIVE-8028.
#
# A saved Vault value read under ANOTHER box's key must be refused, never typed in
# as garbage. AES-CBC under a wrong key passes its padding check about 1 time in
# 256, and the pre-DIVE-7274 v1 format had nothing else to catch it, so a wrong
# key "decrypted" to junk. v2 encrypts a known check prefix ahead of the value and
# v1 is judged by its text (control bytes, invalid UTF-8). One wrong key cannot
# show that — 255 times in 256 the padding refuses it first — so this draws 400:
# the pre-fix tree accepts ~1.5 of them, so it reds here reliably.
#
# Isolation: src/ libs sourced, a throwaway vault key in TMP. No root, no network.
# Run: bash tests/secret_vault_wrong_key_sweep_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; [[ -n "${KEEP_TMP:-}" ]] || rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d /tmp/secret-vault-sweep-unit.XXXXXX)"

export STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh cmd_secret.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

SECRET_VAULT_KEY="$TMP/vault.key"; VK="$SECRET_VAULT_KEY"
openssl rand -hex 32 > "$VK"; chmod 600 "$VK"
PP='Pa55 w0rd with spaces '

# The two value lines, written under the box's own key: v2 by the product's
# encoder, v1 as an older box wrote it (openssl, no check prefix).
v2line=$(printf '%s' "$PP" | _vault_enc)
v1line="v1:$(printf '%s' "$PP" | openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -md sha256 -salt -a -A -pass "file:$VK" 2>/dev/null)"
[[ "$v2line" == v2:* && "$(_vault_dec "$v2line")" == "$PP" && "$(_vault_dec "$v1line")" == "$PP" ]] \
  && ok_t "L17s0 POSITIVE CONTROL: a v2 and a v1 value both read back under their own key" \
  || bad_t "L17s0 own-key read" "v2=[${v2line:0:3}] dec2=[$(_vault_dec "$v2line")] dec1=[$(_vault_dec "$v1line")]"

cp -p "$VK" "$TMP/vk.bak"
acc2=0 acc1=0 pad=0
for _ in $(seq 400); do
  openssl rand -hex 32 > "$VK"
  _vault_dec "$v2line" >/dev/null 2>&1 && acc2=$((acc2 + 1))
  _vault_open "${v1line#v1:}" >/dev/null 2>&1 && pad=$((pad + 1))
  _vault_dec "$v1line" >/dev/null 2>&1 && acc1=$((acc1 + 1))
done
cp -p "$TMP/vk.bak" "$VK"
[[ "$v2line" == v2:* && $acc2 -eq 0 && $acc1 -eq 0 ]] \
  && ok_t "L17s NEGATIVE CONTROL: 400 fresh wrong keys: every v2 and every v1 value refused ($pad v1 decrypts passed the padding check and were still refused)" \
  || bad_t "L17s wrong keys accepted" "v2=$acc2 v1=$acc1 pad=$pad line=${v2line:0:3}"

echo
echo "secret-vault wrong-key sweep unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
