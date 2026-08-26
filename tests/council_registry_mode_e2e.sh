#!/usr/bin/env bash
# DIVE-3729 — the bench registry must stay READABLE, and an unreadable one must SAY SO.
#
# What broke: the motion path persists the new roster with `mktemp` + `mv`. `mv` replaces the
# destination INODE, so benches.json inherited the temp file's 0600 root:root instead of its own
# 0644 root:claude, and every non-root seat was locked out from that moment. It was invisible
# because loadRegistry() failed OPEN (`catch { return {} }`) into resolveBench(), which fails
# CLOSED — so an EACCES surfaced as `unknown bench: <name>`, and a name that IS a built-in did not
# surface at all: it silently resolved to the genesis default, voiding a sealed motion for 5 weeks.
#
# THREE arms, and each names its own limit:
#   A. READER (real surface, built binary): an unreadable registry must be a loud read failure on
#      `bench ls`/`bench show`, NOT an empty registry and NOT a silent built-in fallback.
#      Needs a non-root euid — root reads a 0000 file, so the arm cannot fire as root and SKIPs.
#   B. JS WRITER (real surface): `bench add` must not leave the registry root-only, and must not
#      downgrade the mode of a registry that already exists.
#   C. SHELL WRITER (property + negative control): the motion rewrite itself needs root AND a
#      gate-proof seal, so it is NOT driven here. What IS driven is the staged-replace pattern the
#      fix installs, against the pre-fix `mktemp`+`mv` form as the negative control — plus a guard
#      on the SHIPPED bundle that the motion path actually uses that pattern. That guard is what
#      ties arm C to the caller; without it this arm would grade the instrument, not the product.
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for b in node jq; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council registry-mode e2e needs it)"; exit 0; }
done

TMP="$(mktemp -d)"
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi

P=0; F=0
chk(){ if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $1 (want=$2 got=$3)"; fi; }

STATE="$TMP/state"; mkdir -p "$STATE/council"
REG="$STATE/council/benches.json"
cat > "$REG" <<'JSON'
{
  "strategy": {
    "description": "strategy — custom council bench.",
    "mode": "deliberate",
    "seats": [{"id":"alpha","lens":"alpha — council seat."},{"id":"beta","lens":"beta — council seat."}]
  }
}
JSON
chmod 0644 "$REG"

# ---------------------------------------------------------------- A. READER
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP-ARM A: running as root — root reads a 0000 file, so the EACCES arm cannot FIRE here."
else
  # positive control first: readable registry resolves the custom bench.
  OK_LS="$(STATE_DIR="$STATE" "$FIVE" council bench ls 2>&1 || true)"
  case "$OK_LS" in *strategy*) chk "control: readable registry lists the custom bench" y y ;;
                   *)          chk "control: readable registry lists the custom bench" y n ;; esac

  chmod 0000 "$REG"
  # negative control on the control: confirm this euid really cannot read it.
  if cat "$REG" >/dev/null 2>&1; then
    echo "SKIP-ARM A: this euid can still read a 0000 file (acl/cap?) — arm cannot fire."
  else
    BAD_LS="$(STATE_DIR="$STATE" "$FIVE" council bench ls 2>&1 || true)"
    case "$BAD_LS" in
      *"READ FAILURE"*) chk "unreadable registry is a READ FAILURE on bench ls" y y ;;
      *)                chk "unreadable registry is a READ FAILURE on bench ls" y n; echo "  got: $BAD_LS" ;;
    esac
    case "$BAD_LS" in
      *"unknown bench"*) chk "unreadable registry does NOT name the wrong fault" y n ;;
      *)                 chk "unreadable registry does NOT name the wrong fault" y y ;;
    esac
    # THE SILENT HALF: a BUILT-IN name must not quietly resolve to the genesis default while the
    # persisted overlay (which may hold a carried motion's roster) is unreadable.
    BAD_SHOW="$(STATE_DIR="$STATE" "$FIVE" council bench show council 2>&1 || true)"
    case "$BAD_SHOW" in
      *"READ FAILURE"*) chk "a built-in name does not silently fall back past an unreadable overlay" y y ;;
      *)                chk "a built-in name does not silently fall back past an unreadable overlay" y n; echo "  got: $BAD_SHOW" ;;
    esac
  fi
  chmod 0644 "$REG"
fi

# ------------------------------------------------------------- B. JS WRITER
STATE_DIR="$STATE" "$FIVE" council bench add panel --seats=a,b >/dev/null 2>&1 \
  && chk "bench add on an existing registry succeeds" y y \
  || chk "bench add on an existing registry succeeds" y n
chk "bench add preserves the existing registry mode" 644 "$(stat -c '%a' "$REG")"

FRESH="$TMP/fresh"; mkdir -p "$FRESH/council"
( umask 077; STATE_DIR="$FRESH" "$FIVE" council bench add panel --seats=a,b >/dev/null 2>&1 ) \
  || echo "note: fresh-registry bench add returned non-zero"
if [[ -f "$FRESH/council/benches.json" ]]; then
  FM="$(stat -c '%a' "$FRESH/council/benches.json")"
  chk "a first write under a tight umask is not left root-only" 644 "$FM"
else
  chk "a first write under a tight umask created the registry" y n
fi

# ----------------------------------------------------------- C. SHELL WRITER
# C1 — the SHIPPED motion path uses the staged-replace pattern (ties C2 to the caller).
BUNDLE_LINES="$(grep -n 'jq --argjson seats "\$bench_seats"' "$FIVE" | head -1 | cut -d: -f1)"
if [[ -z "$BUNDLE_LINES" ]]; then
  chk "motion registry rewrite found in the shipped bundle" y n
else
  CTX="$(sed -n "$((BUNDLE_LINES-14)),$((BUNDLE_LINES+4))p" "$FIVE")"
  case "$CTX" in *'mktemp "${COUNCIL_REGISTRY}.XXXXXX"'*) chk "motion rewrite stages BESIDE the registry (rename, not cross-fs copy)" y y ;;
                 *) chk "motion rewrite stages BESIDE the registry (rename, not cross-fs copy)" y n ;; esac
  case "$CTX" in *'chmod --reference="$COUNCIL_REGISTRY"'*) chk "motion rewrite carries the destination MODE" y y ;;
                 *) chk "motion rewrite carries the destination MODE" y n ;; esac
  case "$CTX" in *'chown --reference="$COUNCIL_REGISTRY"'*) chk "motion rewrite carries the destination OWNER" y y ;;
                 *) chk "motion rewrite carries the destination OWNER" y n ;; esac
  case "$CTX" in *'warn "motion sealed into the chain but'*) chk "a failed roster persist is said out loud" y y ;;
                 *) chk "a failed roster persist is said out loud" y n ;; esac
fi

# C2 — the pattern itself, against the pre-fix form as the negative control.
DEST="$TMP/dest.json"; printf '{"a":1}\n' > "$DEST"; chmod 0644 "$DEST"
OLD_TMP="$(mktemp)"; printf '{"a":2}\n' > "$OLD_TMP"; mv "$OLD_TMP" "$DEST"
chk "NEGATIVE CONTROL: the pre-fix mktemp+mv form loses the destination mode" "600" "$(stat -c '%a' "$DEST")"

printf '{"a":1}\n' > "$DEST"; chmod 0644 "$DEST"
NEW_TMP="$(mktemp "${DEST}.XXXXXX")"
chmod --reference="$DEST" "$NEW_TMP" 2>/dev/null || chmod 0644 "$NEW_TMP"
printf '{"a":2}\n' > "$NEW_TMP"; mv "$NEW_TMP" "$DEST"
chk "the staged-replace form KEEPS the destination mode" "644" "$(stat -c '%a' "$DEST")"

echo "PASS=$P FAIL=$F"
[ "$F" -eq 0 ] || exit 1
