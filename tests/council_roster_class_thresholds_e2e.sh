#!/usr/bin/env bash
# DIVE-2890 roster PER-CLASS THRESHOLD e2e — proves `5dive council roster` reports the bar for the
# decision class a seat is actually voting in, not the default (`ordinary`) spec alone.
#
# The defect this guards: roster printed ONE unconditional line — "threshold: 4 to pass, quorum 4
# (spec: {"rule":"majority"})" — which is the ordinary rule. The constitutional class is 2/3 with
# quorum ALL and require_quorum:true, so on a 6-seat council roster under-reported quorum as 4 when
# it is 6. The direction is what makes it dangerous: it is wrong REASSURINGLY. A seat that runs
# roster mid-ballot to decide whether its vote still matters reads "quorum 4", sees 4 already cast,
# infers "we are quorate, mine is redundant", and abstains — which under require_quorum:true is the
# one action that inquorates the motion. The constitutional class had already failed INQUORATE twice
# (4/6 and 5/6) when this was filed. `--class=constitutional` was ALSO silently accepted and
# ignored, so the one flag that looks like it answers the question returned the wrong answer without
# erroring, and `--help` just re-printed the roster.
#
# Drives the BUILT binary (the bash surface a seat invokes), not `node cli.mjs`, because the whole
# defect lived in the bash print + arg handling. No root/sudo/seal needed — `council init` seals
# through the gate-proof rail unprivileged into an isolated STATE_DIR. Exit 0 == green.
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # fires on every exit path (incl. SKIP early-exits)

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for b in node jq openssl sha256sum; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (roster class-threshold e2e needs it)"; exit 0; }
done

TMP="$(mktemp -d)"
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi
export STATE_DIR="$TMP" COUNCIL_MOCK=1 COUNCIL_5DIVE_BIN="$FIVE"   # isolate — never touch a live state dir

P=0; F=0
ok(){ echo "  ok:   $1"; P=$((P+1)); }
no(){ echo "  FAIL: $1"; F=$((F+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want=$2 got=$3)"; fi; }

# Six seats — the live Council's size, and the size at which the two numbers DIVERGE: majority
# quorum is 4, all-seats quorum is 6. A 3-seat fixture would hide half the defect (2 vs 3 still
# differ, but 6/4 is the exact pair the two inquorate rounds were decided on).
"$FIVE" council init --seats="a:chair,b,c,d,e,f" --threshold="majority" --veto="tg:1234567890" >/dev/null 2>&1 \
  || { echo "SKIP: council init could not seal genesis in this environment (no gate-proof rail)"; exit 0; }

J="$("$FIVE" --json council roster 2>/dev/null)"
[[ -n "$J" ]] || { echo "FAIL: roster --json produced nothing"; exit 1; }

# --- 1. the per-class table exists and every declared class is resolved over the LIVE seat count ---
chk "roster resolves 6 seats" "6" "$(printf '%s' "$J" | jq -r '.data.seatCount')"
for cls in ordinary promote demote expel constitutional; do
  chk "class '$cls' present in the table" "1" \
    "$(printf '%s' "$J" | jq -r --arg c "$cls" '[.data.classes[] | select(.class==$c)] | length')"
done

# --- 2. THE REGRESSION: the constitutional quorum is ALL SIX, not the default 4 -------------------
# Pre-fix the only quorum roster emitted was 4. This is the assertion the old build cannot pass.
chk "constitutional quorum = 6 (ALL seats)" "6" \
  "$(printf '%s' "$J" | jq -r '.data.classes[] | select(.class=="constitutional") | .quorum')"
chk "constitutional threshold = ceil(2/3 * 6) = 4" "4" \
  "$(printf '%s' "$J" | jq -r '.data.classes[] | select(.class=="constitutional") | .threshold')"
chk "constitutional carries require_quorum" "true" \
  "$(printf '%s' "$J" | jq -r '.data.classes[] | select(.class=="constitutional") | .requireQuorum')"
chk "ordinary quorum stays majority(6) = 4" "4" \
  "$(printf '%s' "$J" | jq -r '.data.classes[] | select(.class=="ordinary") | .quorum')"

# The TEXT rail is the one a seat actually reads — assert the 6 reaches stdout, not just JSON.
T="$("$FIVE" council roster 2>/dev/null)"
if printf '%s' "$T" | grep -qE '^\s*constitutional\s+4 to pass, quorum 6'; then
  ok "text roster prints 'constitutional 4 to pass, quorum 6'"
else
  no "text roster does not print the constitutional row with quorum 6"; printf '%s\n' "$T" | sed 's/^/    | /'
fi
# No unlabelled bare threshold line may survive: pre-fix output led with "threshold: N to pass,
# quorum N" with nothing naming which class it described. That exact shape is what misled a reader.
if printf '%s' "$T" | grep -qE '^threshold: [0-9]+ to pass, quorum [0-9]+'; then
  no "the old unlabelled 'threshold: N to pass, quorum N' line is still printed"
else
  ok "no unlabelled class-less threshold line remains"
fi

# --- 3. --class=<name> NARROWS (it used to be accepted and ignored) ------------------------------
JC="$("$FIVE" --json council roster --class=constitutional 2>/dev/null)"
chk "--class=constitutional returns exactly one row" "1" "$(printf '%s' "$JC" | jq -r '.data.classes | length')"
chk "--class=constitutional returns THAT row" "constitutional" "$(printf '%s' "$JC" | jq -r '.data.classes[0].class')"
chk "--class=constitutional row still says quorum 6" "6" "$(printf '%s' "$JC" | jq -r '.data.classes[0].quorum')"

# --- 4. an unknown class FAILS CLOSED (a typo must not silently return the default bar) ----------
out="$("$FIVE" council roster --class=bogus 2>&1)"; rc=$?
chk "unknown --class exits non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
if printf '%s' "$out" | grep -q "unknown decision class 'bogus'"; then
  ok "unknown --class names the class and lists the valid ones"
else
  no "unknown --class did not explain itself: $out"
fi
# DIVE-2711 idiom: a deliberate usage refusal must be MARKED REPORTED, or lib/output.sh's EXIT
# backstop appends "exited N without reporting a reason … a bug in the CLI" — and under --json
# emits a SECOND document, breaking every reader that pipes roster through jq.
if printf '%s' "$out" | grep -q "without reporting a reason"; then
  no "the generic CLI-bug backstop fired over a deliberate usage refusal (missing mark_reported)"
else
  ok "no spurious 'this is a bug in the CLI' backstop on a usage refusal"
fi
if "$FIVE" --json council roster --class=bogus 2>/dev/null | jq -e . >/dev/null 2>&1 || [[ -z "$("$FIVE" --json council roster --class=bogus 2>/dev/null)" ]]; then
  ok "--json stays ONE document (or empty) on the refusal"
else
  no "--json emitted more than one document on the refusal"
fi

# --- 5. --help explains the surface instead of re-printing the roster ----------------------------
H="$("$FIVE" council roster --help 2>&1)"
if printf '%s' "$H" | grep -q -- "--class=" && ! printf '%s' "$H" | grep -q "^council:   council"; then
  ok "roster --help prints usage (not the roster itself)"
else
  no "roster --help did not print usage"
fi
# An unrecognised flag must refuse rather than answer a different question.
"$FIVE" council roster --nope >/dev/null 2>&1; rc=$?
chk "unknown roster flag exits non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"

echo "roster class-threshold e2e: $P passed, $F failed"
[[ $F -eq 0 ]] || exit 1
exit 0
