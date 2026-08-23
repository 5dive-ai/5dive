#!/usr/bin/env bash
# DIVE-3554: install.sh must give `buzz` and `buzz-pair` a real, checksum-verified,
# version-pinned install path — the shipped Connect Buzz panel (DIVE-3551) shells
# out to buzz-pair and nothing on any box installed it.
#
# This harness EXECUTES the shipped block against file:// fixtures rather than
# grepping it. A text-only assertion cannot tell a guard that refuses from a
# guard that logs and installs anyway, and the two mutation arms below are the
# only thing that proves the checksum guards are load-bearing rather than
# decorative.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

WORK="$(mktemp -d)"

# --- 1. the block is extractable, and pinned -------------------------------
BLOCK="$WORK/block.sh"
sed -n '/^# >>> DIVE-3554 buzz binary staging/,/^# <<< DIVE-3554 buzz binary staging/p' install.sh > "$BLOCK"
if [[ -s "$BLOCK" ]] && grep -q 'stage_buzz_binaries() {' "$BLOCK"; then
  ok_t "DIVE-3554 block is extractable from install.sh"
else
  bad_t "DIVE-3554 fence missing or empty" "nothing else in this harness can run"
  printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"; exit 1
fi

tag="$(sed -n 's/^BUZZ_CLI_TAG="\${BUZZ_CLI_TAG:-\([^}]*\)}"/\1/p' "$BLOCK")"
if [[ "$tag" =~ ^cli-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  ok_t "buzz release is pinned to an explicit tag ($tag)"
else
  bad_t "buzz release is not pinned to a version tag" "got '${tag:-<none>}' — 'latest' or a moving ref hands every box a different binary on any publish"
fi
sums_pin="$(sed -n 's/^BUZZ_SUMS_SHA256="\${BUZZ_SUMS_SHA256:-\([0-9a-f]*\)}"/\1/p' "$BLOCK")"
if [[ "$sums_pin" =~ ^[0-9a-f]{64}$ ]]; then
  ok_t "the SHA256SUMS manifest itself is pinned to a digest in install.sh"
else
  bad_t "no pinned manifest digest" "a release asset is mutable on an immutable tag; verifying against a manifest fetched beside the payload proves nothing"
fi

# refresh_managed_files() is the one function reached by fresh install, --upgrade
# AND the customer nightly (5dive-api/scripts/update.sh re-curls install.sh). If
# the call drifts out of it, existing boxes silently stop being covered.
body="$(sed -n '/^refresh_managed_files() {/,/^}/p' install.sh)"
if grep -qE '^\s*stage_buzz_binaries\s*$' <<<"$body"; then
  ok_t "stage_buzz_binaries is called from refresh_managed_files (fresh + --upgrade + nightly)"
else
  bad_t "stage_buzz_binaries not called from refresh_managed_files" "existing boxes are only covered because the nightly re-enters that function"
fi

# --- fixture helpers -------------------------------------------------------
# A fake release directory served over file://, plus a fake BIN_DIR.
mk_release() {                      # mk_release <dir> <buzz-bytes> <buzzpair-bytes>
  local d="$1"; mkdir -p "$d"
  printf '%s' "$2" > "$d/buzz"
  printf '%s' "$3" > "$d/buzz-pair"
  ( cd "$d" && sha256sum buzz buzz-pair > SHA256SUMS )
}
sums_digest() { sha256sum "$1/SHA256SUMS" | awk '{print $1}'; }

# Run the SHIPPED bytes under the SHIPPED flags. `set -euo pipefail` is install.sh
# line 6; running the block without it would hide exactly the class of abort that
# reddened docker-install in DIVE-1271.
run_block() {                       # run_block <block> <bindir> <relbase> <sumspin> [extra-path]
  local blk="$1" bindir="$2" relbase="$3" pin="$4" extra="${5:-}"
  PATH="${extra:+$extra:}$PATH" bash -c '
    set -euo pipefail
    ok(){ echo "  ok $*"; }
    BIN_DIR="'"$bindir"'"; GH_ORG="unused"
    BUZZ_REL_BASE="'"$relbase"'"
    BUZZ_SUMS_SHA256="'"$pin"'"
    . "'"$blk"'"
    stage_buzz_binaries
    echo "RC=$?"
  ' 2>&1
}

# --- 2. happy path: both binaries land, verified ---------------------------
REL="$WORK/rel"; mk_release "$REL" "BUZZ-BINARY-v1" "BUZZPAIR-BINARY-v1"
BIN="$WORK/bin1"; mkdir -p "$BIN"
out="$(run_block "$BLOCK" "$BIN" "file://$REL" "$(sums_digest "$REL")")"
if [[ "$(cat "$BIN/buzz" 2>/dev/null)" == "BUZZ-BINARY-v1" \
   && "$(cat "$BIN/buzz-pair" 2>/dev/null)" == "BUZZPAIR-BINARY-v1" ]]; then
  ok_t "fresh box: buzz AND buzz-pair are installed from the pinned release"
else
  bad_t "fresh box did not get both binaries" "$out"
fi
if [[ -x "$BIN/buzz-pair" && "$(stat -c %a "$BIN/buzz-pair")" == "755" ]]; then
  ok_t "buzz-pair is installed executable (0755) — the verb resolves an -x path"
else
  bad_t "buzz-pair not executable 0755" "mode=$(stat -c %a "$BIN/buzz-pair" 2>/dev/null)"
fi
grep -q 'RC=0' <<<"$out" && ok_t "happy path returns 0" || bad_t "happy path did not return 0" "$out"

# --- 3. idempotent: a second run downloads nothing -------------------------
# Prove it by DELETING the payload assets and leaving only the manifest. If the
# second run still succeeds, it did not re-fetch the binaries. This is what keeps
# the nightly cheap (one 147-byte manifest fetch on an unchanged box).
rm -f "$REL/buzz" "$REL/buzz-pair"
out="$(run_block "$BLOCK" "$BIN" "file://$REL" "$(sums_digest "$REL")")"
if grep -q 'already at' <<<"$out" && [[ "$(cat "$BIN/buzz-pair")" == "BUZZPAIR-BINARY-v1" ]]; then
  ok_t "re-run on an up-to-date box re-downloads no binary (nightly is cheap)"
else
  bad_t "re-run re-downloaded (or broke) the binaries" "$out"
fi
mk_release "$REL" "BUZZ-BINARY-v1" "BUZZPAIR-BINARY-v1"

# --- 4. a tampered PAYLOAD is refused, and the old binary survives ----------
BAD="$WORK/rel-badpayload"; mk_release "$BAD" "BUZZ-BINARY-v1" "BUZZPAIR-BINARY-v1"
pin_bad="$(sums_digest "$BAD")"
printf '%s' "EVIL-PAYLOAD" > "$BAD/buzz-pair"      # manifest now lies about buzz-pair
BIN2="$WORK/bin2"; mkdir -p "$BIN2"
printf '%s' "PREEXISTING" > "$BIN2/buzz-pair"; chmod 755 "$BIN2/buzz-pair"
out="$(run_block "$BLOCK" "$BIN2" "file://$BAD" "$pin_bad")"
if [[ "$(cat "$BIN2/buzz-pair")" == "PREEXISTING" ]] && grep -qi 'checksum mismatch' <<<"$out"; then
  ok_t "payload that fails SHA256SUMS is refused and the existing binary is untouched"
else
  bad_t "tampered payload was installed (or the old binary was destroyed)" "$out"
fi
if [[ "$(cat "$BIN2/buzz" 2>/dev/null)" == "BUZZ-BINARY-v1" ]]; then
  ok_t "one bad binary does not block the other (buzz still installed)"
else
  bad_t "a single bad binary aborted the whole staging" "$out"
fi
grep -q 'RC=0' <<<"$out" && ok_t "a refusal still returns 0 (never aborts the CLI update)" || bad_t "refusal aborted the run" "$out"
# temp files must not be left lying in BIN_DIR after a refusal
if ! compgen -G "$BIN2/.buzz-pair.*" >/dev/null; then
  ok_t "refused download leaves no partial temp in BIN_DIR"
else
  bad_t "partial temp left in BIN_DIR after refusal" "$(ls -a "$BIN2")"
fi

# --- 5. a SWAPPED MANIFEST is refused — and the mutation arm proves it ------
# The real attack this guards: replace the release assets AND their SHA256SUMS
# under the same tag. Internally consistent, so a payload-vs-manifest check
# passes it. Only the pinned manifest digest catches it.
SWAP="$WORK/rel-swapped"; mk_release "$SWAP" "EVIL-BUZZ" "EVIL-BUZZPAIR"
BIN3="$WORK/bin3"; mkdir -p "$BIN3"
out="$(run_block "$BLOCK" "$BIN3" "file://$SWAP" "$sums_pin")"   # pin is from the REAL release
if [[ ! -e "$BIN3/buzz" && ! -e "$BIN3/buzz-pair" ]] && grep -q 'does not match the digest pinned' <<<"$out"; then
  ok_t "internally-consistent swapped release is refused (pinned manifest digest holds)"
else
  bad_t "swapped release was installed" "$out"
fi
# MUTATION: delete the pinned-manifest guard. The same fixture must then install
# the evil bytes. If it still refuses, the guard above is not what stopped it and
# the assertion is worthless.
MUT="$WORK/block-mut.sh"
awk '/if \[\[ "\$sums" != "\$BUZZ_SUMS_SHA256" \]\]; then/{skip=1} skip&&/^  fi$/{skip=0;next} !skip' "$BLOCK" > "$MUT"
BIN4="$WORK/bin4"; mkdir -p "$BIN4"
out="$(run_block "$MUT" "$BIN4" "file://$SWAP" "$sums_pin")"
if [[ "$(cat "$BIN4/buzz-pair" 2>/dev/null)" == "EVIL-BUZZPAIR" ]]; then
  ok_t "mutation control: without the pinned-digest guard the swapped release DOES install"
else
  bad_t "mutation control failed — the swap test proves nothing" "removing the guard changed no behaviour; out=$out"
fi

# --- 6. unreachable release: fail-soft, keep what the box has --------------
BIN5="$WORK/bin5"; mkdir -p "$BIN5"
printf '%s' "PREEXISTING" > "$BIN5/buzz"; chmod 755 "$BIN5/buzz"
out="$(run_block "$BLOCK" "$BIN5" "file://$WORK/does-not-exist" "$sums_pin")"
if grep -q 'RC=0' <<<"$out" && [[ "$(cat "$BIN5/buzz")" == "PREEXISTING" ]] && grep -q 'could not fetch' <<<"$out"; then
  ok_t "unreachable release is fail-soft under set -euo pipefail (nightly CLI update survives)"
else
  bad_t "unreachable release aborted the run or clobbered the binary" "$out"
fi

# --- 7. non-x86_64 says so instead of installing an unrunnable binary ------
SHIM="$WORK/shim"; mkdir -p "$SHIM"
printf '#!/bin/sh\necho aarch64\n' > "$SHIM/uname"; chmod 755 "$SHIM/uname"
BIN6="$WORK/bin6"; mkdir -p "$BIN6"
out="$(run_block "$BLOCK" "$BIN6" "file://$REL" "$(sums_digest "$REL")" "$SHIM")"
if [[ ! -e "$BIN6/buzz" ]] && grep -q 'x86_64 builds only' <<<"$out" && grep -q 'RC=0' <<<"$out"; then
  ok_t "non-x86_64 box is told why, and gets no unrunnable binary"
else
  bad_t "arch guard did not fire" "$out"
fi

printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
