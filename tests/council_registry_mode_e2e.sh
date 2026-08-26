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
#   D. RECEIPT/VETO DROP (real convene, end to end): the third gap the filer appended to this row —
#      the receipt write and the founder-veto ping share ONE `-w` guard with no else, so an
#      unprivileged scheduled convene sealed a digest, stored no receipt and never offered the veto,
#      silently. Needs a reachable seal (`sudo -n 5dive gate-proof sign`); SKIPs by name without one.
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
    # DIVE-3729 iteration 2 (ops hold on #734). The harness OWNS this file, so a 0000 mode is one
    # the process can fix — and it now does: the read REPAIRS the mode and carries on. That is the
    # outcome the fleet actually needs (the scheduled convene runs under sudo, so it self-heals the
    # legacy root-0600 registry on first run) and it is strictly better than either the original
    # fail-open OR iteration 1's fail-closed: the custom bench comes BACK, rather than being
    # silently skipped or turned into exit 2.
    BAD_LS="$(STATE_DIR="$STATE" "$FIVE" council bench ls 2>&1 || true)"
    case "$BAD_LS" in
      *"repaired the bench registry"*) chk "an unreadable registry we OWN is repaired, loudly" y y ;;
      *)                               chk "an unreadable registry we OWN is repaired, loudly" y n; echo "  got: $BAD_LS" ;;
    esac
    case "$BAD_LS" in
      *strategy*) chk "the repair restores the custom bench, not just the mode" y y ;;
      *)          chk "the repair restores the custom bench, not just the mode" y n; echo "  got: $BAD_LS" ;;
    esac
    case "$BAD_LS" in
      *"unknown bench"*) chk "the repair path does NOT name the wrong fault" y n ;;
      *)                 chk "the repair path does NOT name the wrong fault" y y ;;
    esac
    MODE_AFTER="$(stat -c '%a' "$REG" 2>/dev/null || echo '?')"
    case "$MODE_AFTER" in
      644) chk "the repair actually persisted 0644 to disk" y y ;;
      *)   chk "the repair actually persisted 0644 to disk" y n; echo "  got mode: $MODE_AFTER" ;;
    esac

    # ---- THE UNREPAIRABLE HALF: EACCES this euid genuinely cannot fix -----------------------
    # A 0000 file we own is repairable, so it cannot reach the degrade branch. A 0000 PARENT is:
    # traversal fails, so both the read AND the chmod return EACCES, with no root and no sudo (which
    # tests/lib/env_isolation.sh shadows anyway, DIVE-3096 — a sudo probe here measures the harness).
    # This is the shape CI's full-installed-host job has for real: a root-0600 registry under a
    # non-root runner. That job is what iteration 1 turned red, and this arm is its stand-in.
    LOCK="$STATE/locked"; mkdir -p "$LOCK"; cp "$REG" "$LOCK/benches.json"; chmod 0000 "$LOCK"
    if cat "$LOCK/benches.json" >/dev/null 2>&1; then
      echo "SKIP-ARM A2: this euid can still traverse a 0000 dir — the unrepairable arm cannot fire."
    else
      # Driven at cli.mjs because --registry is the only way to aim the read at a path the shell
      # wrapper cannot name (it derives COUNCIL_REGISTRY from COUNCIL_DIR unconditionally).
      DEG="$(node "$ROOT/src/council/cli.mjs" bench ls --registry="$LOCK/benches.json" 2>&1 || true)"
      DEG_RC=0; node "$ROOT/src/council/cli.mjs" bench ls --registry="$LOCK/benches.json" >/dev/null 2>&1 || DEG_RC=$?
      case "$DEG_RC" in
        0) chk "an UNREPAIRABLE registry degrades instead of exiting 2 (the ops hold)" y y ;;
        *) chk "an UNREPAIRABLE registry degrades instead of exiting 2 (the ops hold)" y n; echo "  got rc: $DEG_RC" ;;
      esac
      case "$DEG" in
        *benchRegistryUnreadable*) chk "the degrade rides the ENVELOPE (--json callers capture 2>&1)" y y ;;
        *)                         chk "the degrade rides the ENVELOPE (--json callers capture 2>&1)" y n; echo "  got: $DEG" ;;
      esac
      case "$DEG" in
        *"READ FAILURE"*) chk "the degrade still names the read failure, not an empty registry" y y ;;
        *)                chk "the degrade still names the read failure, not an empty registry" y n; echo "  got: $DEG" ;;
      esac
      # The whole point of degrading rather than dying: the built-ins still resolve, so a convene
      # that can proceed still proceeds.
      case "$DEG" in
        *council*) chk "built-ins still resolve while degraded (the working path still works)" y y ;;
        *)         chk "built-ins still resolve while degraded (the working path still works)" y n ;;
      esac
      # ...but a MUTATION must stay fatal: a read-modify-write over a registry we could not read
      # would delete every custom bench in it.
      ADD_RC=0; node "$ROOT/src/council/cli.mjs" bench add panel2 --seats=a,b --registry="$LOCK/benches.json" >/dev/null 2>&1 || ADD_RC=$?
      case "$ADD_RC" in
        0) chk "a MUTATION over an unreadable registry is still refused" y n; echo "  bench add succeeded over an unreadable store" ;;
        *) chk "a MUTATION over an unreadable registry is still refused" y y ;;
      esac
      chmod 0755 "$LOCK"
    fi
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

# ----------------------------------------------- D. RECEIPT/VETO DROP (real convene, end to end)
# D0 — STATIC, always runs: the shipped bundle must carry the else-arm. This is what keeps arm D
# from being worth nothing in the (normal) case where D1 cannot seal. It is a bundle guard, so it
# grades the product. Each string is checked to be ABSENT at origin/main: "is not writable by" was
# the obvious phrase and it matches three unrelated sites (proof, wiki, version-record), so it went
# green on the control — a substring that is not unique to the change is a false green, not a guard.
# grades the product; it is NOT a substitute for D1, which is the only arm that proves the branch
# actually fires on a real convene.
grep -q 'NO receipt was written' "$FIVE" \
  && chk "the shipped bundle carries a reason for a dropped receipt" y y \
  || chk "the shipped bundle carries a reason for a dropped receipt" y n
grep -q 'the founder veto was NOT offered' "$FIVE" \
  && chk "the shipped bundle names the veto that did not happen" y y \
  || chk "the shipped bundle names the veto that did not happen" y n
grep -q 'receiptDropped' "$FIVE" \
  && chk "the shipped bundle carries the drop in the --json envelope" y y \
  || chk "the shipped bundle carries the drop in the --json envelope" y n

# D1 — the live arm. Reaching the guard needs a SEALED digest, and a seal needs root or
# `sudo 5dive gate-proof sign`. NOTE the skip reason is measured, not assumed: on this corpus
# `sudo` is a REFUSING SHELL FUNCTION installed by tests/lib/env_isolation.sh (via grading_tree.sh,
# DIVE-3096) — the grant may be perfectly present on the host and the arm still cannot use it.
# Reporting that as "no passwordless sudo" would be a false negative about the HOST, so the two
# causes are distinguished here. Deliberately NOT worked around: `command sudo` would defeat the
# isolation control on purpose, which is not a thing a harness gets to do to itself.
_d_skip=""
if [[ "$(id -u)" -ne 0 ]]; then
  if [[ "$(type -t sudo 2>/dev/null)" == "function" ]]; then
    _d_skip="this harness's own env isolation (tests/lib/env_isolation.sh, DIVE-3096) refuses sudo — the HOST grant is untested by this, not absent"
  elif ! printf 'probe\n' | sudo -n 5dive gate-proof sign >/dev/null 2>&1; then
    _d_skip="no reachable gate-proof seal on this host (not root, no passwordless \`sudo 5dive gate-proof sign\`)"
  fi
fi
if [[ -n "$_d_skip" ]]; then
  echo "SKIP-ARM D1 (live convene): $_d_skip — verified BY HAND instead; see DIVE-3729's body for the transcript."
else
  D="$TMP/drop"; mkdir -p "$D/council/receipts"
  chmod 0555 "$D/council/receipts"
  DTXT="$(COUNCIL_MOCK=1 STATE_DIR="$D" "$FIVE" council convene "ship it?" --seats=a,b,c --mode=quick 2>&1 || true)"
  case "$DTXT" in
    *"is not writable by"*) chk "an unstorable receipt WARNS instead of skipping in silence" y y ;;
    *)                      chk "an unstorable receipt WARNS instead of skipping in silence" y n; echo "  got: $DTXT" ;;
  esac
  case "$DTXT" in
    *"the founder veto was NOT offered"*) chk "the warning names the veto that did not happen" y y ;;
    *)                                    chk "the warning names the veto that did not happen" y n ;;
  esac
  case "$DTXT" in
    *"sealed ("*"but NOT STORED"*) chk "the receipt line does not claim a receipt that was not stored" y y ;;
    *)                             chk "the receipt line does not claim a receipt that was not stored" y n; echo "  got: $(printf '%s' "$DTXT" | grep receipt:)" ;;
  esac
  # The file's own NB: --json callers capture 2>&1, so the warn must NOT ride stderr in JSON mode —
  # it rides the envelope. Both halves are asserted, because either alone is passable while broken.
  DJ="$(COUNCIL_MOCK=1 STATE_DIR="$D" "$FIVE" council convene "ship it?" --seats=a,b,c --mode=quick --json 2>&1 || true)"
  if printf '%s' "$DJ" | jq -e '.ok' >/dev/null 2>&1; then
    chk "a --json convene envelope survives 2>&1 with a dropped receipt" y y
  else
    chk "a --json convene envelope survives 2>&1 with a dropped receipt" y n; echo "  got: $DJ"
  fi
  if printf '%s' "$DJ" | jq -e '(.data.receiptDropped // "") | length > 0' >/dev/null 2>&1; then
    chk "the dropped receipt is carried IN the json envelope" y y
  else
    chk "the dropped receipt is carried IN the json envelope" y n
  fi
  # POSITIVE CONTROL: with the directory writable, no warning and a receipt on disk.
  chmod 0755 "$D/council/receipts"
  OTXT="$(COUNCIL_MOCK=1 STATE_DIR="$D" "$FIVE" council convene "ship it?" --seats=a,b,c --mode=quick 2>&1 || true)"
  case "$OTXT" in
    *"is not writable by"*) chk "control: a writable receipts dir does NOT warn" y n ;;
    *)                      chk "control: a writable receipts dir does NOT warn" y y ;;
  esac
  RC=$(find "$D/council/receipts" -name '*.json' 2>/dev/null | wc -l)
  if [[ "$RC" -ge 1 ]]; then chk "control: a writable receipts dir stores the receipt" y y
  else chk "control: a writable receipts dir stores the receipt" y n; fi
fi

echo "PASS=$P FAIL=$F"
[ "$F" -eq 0 ] || exit 1
