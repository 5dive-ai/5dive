#!/usr/bin/env bash
# DIVE-7861: two verbs told the caller "bug in the CLI, effect UNKNOWN" (the
# generic `exited 1 without reporting a reason` banner) when the real answer was
# "this seat drifted" or "this needs root". Both arms drive the BUILT bundle, so
# they run under the bundle's own `set -euo pipefail`, the way a seat runs it.
#
# Arms:
#   I  `agent info` on a seat whose env file and -auth.env link name a different
#      account than the registry (teal-fox's three rotation seats): rc 0,
#      authProfileOnDisk.state=drift naming all three, in --json and in text
#   A  an agreeing seat stays `agrees`, rc 0
#   U  an unreadable env file is `unmeasured`, rc 0 (skipped as root: root reads it)
#   C  `agent cos verify` whose runner dir cannot be written: rc 10 (doctor's
#      E_PERMISSION) naming the verb, no banner, nothing written
#   W  with a writable runner dir both files are installed, and a second call
#      leaves them untouched (same inode, same mtime)
#
# NEGATIVE CONTROL: FIVEDIVE_BASE_BUNDLE=<bundle built from origin/main> (FIVEDIVE_,
# not FIVE_: tests/lib/env_isolation.sh unsets every inherited FIVE_*). Arms I (rc and
# state) and C go red there: rc 1 and the generic banner. Build one with
#   git worktree add --detach /tmp/x origin/main && BUILD_OUT=/tmp/5dive-base /tmp/x/build.sh
#
# Run: bash tests/info_drift_cos_root_unit.sh  (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d /tmp/info-drift-cos.XXXXXX)
trap 'rc=$?; chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
t()   { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi; }
tc()  { if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n  expected to contain: %s\n  actual: %s\n' "$1" "$2" "$3"; fi; }
tnc() { if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n  expected NOT to contain: %s\n  actual: %s\n' "$1" "$2" "$3"; fi; }

BUNDLE="${FIVEDIVE_BASE_BUNDLE:-}"
if [[ -n "$BUNDLE" ]]; then
  echo "NEGATIVE CONTROL: bundle $BUNDLE"
else
  BUNDLE="$TMP/5dive"
  BUILD_OUT="$BUNDLE" ./build.sh >"$TMP/build.log" 2>&1 || { cat "$TMP/build.log"; echo "FAIL: build"; exit 1; }
fi
BANNER='without reporting a reason'

# ── state: two seats, both registered on acct-1; seata's files boot on acct-2 ─
D="$TMP/state"; mkdir -p "$D/agents.d" "$D/profiles/acct-1" "$D/profiles/acct-2"
cat >"$D/agents.json" <<'J'
{"agents":{"seata":{"type":"claude","authProfile":"acct-1"},"seatb":{"type":"claude","authProfile":"acct-1"},"seatc":{"type":"claude","authProfile":"acct-1"}}}
J
for s in seata:acct-2 seatb:acct-1 seatc:acct-1; do
  printf 'AGENT_AUTH_PROFILE=%s\n' "${s#*:}" >"$D/agents.d/${s%%:*}.env"
  ln -s "$D/profiles/${s#*:}/auth.env" "$D/agents.d/${s%%:*}-auth.env"
done
info() { STATE_DIR="$D" timeout 60 "$BUNDLE" agent info "$@" 2>&1; }

# ── I: drift is an answer, not a crash ─────────────────────────────────────────
OUT=$(info seata --json); RC=$?
t   "I --json on a drifted seat exits 0" "0" "$RC"
tnc "I --json ...without the generic banner" "$BANNER" "$OUT"
J=$(sed -n '/^{/,$p' <<<"$OUT")
t   "I --json state is drift" "drift" "$(jq -r '.data.authProfileOnDisk.state' <<<"$J" 2>/dev/null)"
t   "I --json detail names all three" "registry=acct-1 env=acct-2 link=acct-2" "$(jq -r '.data.authProfileOnDisk.detail' <<<"$J" 2>/dev/null)"
OUT=$(info seata); RC=$?
t   "I text on a drifted seat exits 0" "0" "$RC"
tc  "I text flags the drift on the profile line" "DRIFT: registry=acct-1 env=acct-2 link=acct-2" "$OUT"
tc  "I text says how to heal it" "5dive agent set-account seata acct-1" "$OUT"

# ── A: an agreeing seat stays agrees ───────────────────────────────────────────
OUT=$(info seatb --json); RC=$?
t   "A agreeing seat exits 0" "0" "$RC"
t   "A agreeing seat is agrees" "agrees" "$(sed -n '/^{/,$p' <<<"$OUT" | jq -r '.data.authProfileOnDisk.state' 2>/dev/null)"

# ── U: unreadable is unmeasured, never drift ───────────────────────────────────
if (( EUID != 0 )); then
  chmod 000 "$D/agents.d/seatc.env"
  OUT=$(info seatc --json); RC=$?
  t   "U unreadable env exits 0" "0" "$RC"
  t   "U unreadable env is unmeasured" "unmeasured|null" \
      "$(sed -n '/^{/,$p' <<<"$OUT" | jq -r '.data.authProfileOnDisk | "\(.state)|\(.detail)"' 2>/dev/null)"
  chmod 644 "$D/agents.d/seatc.env"
else
  echo "SKIP: U (root reads a mode-000 file)"
fi

# ── C: a runner dir the caller cannot write is a named refusal ─────────────────
: >"$TMP/notadir"
OUT=$(STATE_DIR="$D" COS_RUN_DIR="$TMP/notadir/run" COS_ENV_FILE="$TMP/none.env" \
      timeout 60 "$BUNDLE" agent cos verify 2>&1 </dev/null); RC=$?
t   "C unwritable runner dir exits E_PERMISSION (10), as doctor does" "10" "$RC"
tnc "C ...without the generic banner" "$BANNER" "$OUT"
tc  "C ...naming the verb" "agent cos verify" "$OUT"
tnc "C ...and not a raw shell error" "Permission denied" "$OUT"

# ── W: writable dir installs once and leaves unchanged files alone ─────────────
R="$TMP/run"
cos() { STATE_DIR="$D" COS_RUN_DIR="$R" COS_ENV_FILE="$TMP/none.env" timeout 60 "$BUNDLE" agent cos verify </dev/null >/dev/null 2>&1; }
cos
t   "W both runner files are installed" "2" "$(ls "$R"/cos-lib.ts "$R"/cos-runner.ts 2>/dev/null | wc -l)"
t   "W ...readable by every seat (644)" "644 644" "$(stat -c %a "$R"/cos-lib.ts "$R"/cos-runner.ts 2>/dev/null | paste -sd' ')"
touch -d '2001-01-01' "$R"/cos-lib.ts "$R"/cos-runner.ts
BEFORE=$(stat -c '%i %Y' "$R"/cos-lib.ts "$R"/cos-runner.ts 2>/dev/null)
cos
t   "W a second call rewrites neither file" "$BEFORE" "$(stat -c '%i %Y' "$R"/cos-lib.ts "$R"/cos-runner.ts 2>/dev/null)"
t   "W ...and leaves no temp file behind" "2" "$(find "$R" -type f | wc -l)"

echo "info_drift_cos_root_unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
