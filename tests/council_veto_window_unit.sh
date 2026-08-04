#!/usr/bin/env bash
# DIVE-2257 — the founder-veto HOLD-WINDOW invariant, measured against the six offers that were
# actually recorded in /var/lib/5dive/council/veto-pings.jsonl.
#
# THE DEFECT: every veto offer ever sent advertised "Execution holds until <T>" with T already in
# the PAST at the moment of sending, so the founder veto has never once been exercisable.
#
# THE INVARIANT: `_council_veto_ping` refuses at WRITE time any offer whose executeAfter <= its own
# ts — no ledger row, no delivery on either leg, one auditable refusal row instead.
#
# HOW THE SIX ARE REPLAYED: an offer's window is the SIGNED OFFSET between its ts and the
# executeAfter it advertised (the absolute wall-clock date is not the defect — the offset is). Each
# recorded pair is replayed by re-basing its offset onto the write moment: executeAfter = now +
# (recorded_ea - recorded_ts). All six offsets are <= 0, so all six must be REFUSED.
#
# The harness runs the REAL extracted functions from the built src/cmd_council.sh (not a
# re-implementation), and is three-sided: the six-way replay must refuse, a genuine +900s window
# must still SEND, and a mutant with the window check neutered must let all six through (so a green
# replay cannot be vacuous).
#
# Offline: no key, no network, no live tasks.db, no root.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

for b in jq sha256sum date sed; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (council veto-window unit needs it)"; exit 0; }
done
SRC="$ROOT/src/cmd_council.sh"
[[ -r "$SRC" ]] || { echo "SKIP: $SRC not readable"; exit 0; }
date -u -d "+900 seconds" +%s >/dev/null 2>&1 || { echo "SKIP: GNU date -d not available"; exit 0; }

TMP="$(mktemp -d)"
pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

# --- extract the real functions under test -------------------------------------------------------
extract(){ sed -n "/^$1() {/,/^}/p" "$SRC"; }
PING_SRC="$(extract _council_veto_ping)"
HDR_SRC="$(extract _council_veto_offer_header)"
[[ -n "$PING_SRC" && -n "$HDR_SRC" ]] || { echo "FAIL: could not extract the veto functions from $SRC"; exit 1; }

# ANCHOR COUNT: the mutation below rewrites exactly ONE decision. If the anchor ever moves or
# doubles, the mutation would silently neuter nothing (or something else) and the negative control
# would read as green for the wrong reason.
GUARD_ANCHOR='(( _vo_ea_e <= _vo_ts_e ))'
anchors="$(printf '%s\n' "$PING_SRC" | grep -cF "$GUARD_ANCHOR")"
if [[ "$anchors" == "1" ]]; then ok "window-check anchor appears exactly once in _council_veto_ping"
else no "window-check anchor count = $anchors (expected 1) — mutation grading below is unsound"; fi

mkharness(){ # $1 = out path, $2 = "mutate" to neuter the window check
  local out="$1" mode="${2:-}" body="$PING_SRC"
  [[ "$mode" == "mutate" ]] && body="${body//$GUARD_ANCHOR/(( 0 ))}"
  {
    echo 'COUNCIL_DIR="$1"; shift'
    echo 'warn(){ printf "warn: %s\n" "$*" >&2; }'
    echo '_council_constitution_path(){ printf "%s" "$COUNCIL_DIR/constitution.yaml"; }'
    echo '_council_sha256(){ printf "%s" "$1" | sha256sum | awk "{print \$1}"; }'
    printf '%s\n' "$HDR_SRC"
    printf '%s\n' "$body"
    echo '_council_veto_ping "$@"'
  } > "$out"
  bash -n "$out" || return 1
}
mkharness "$TMP/honest.sh"          || { echo "FAIL: honest harness does not parse"; exit 1; }
mkharness "$TMP/mutant.sh" mutate   || { echo "FAIL: mutant harness does not parse"; exit 1; }
if ! cmp -s "$TMP/honest.sh" "$TMP/mutant.sh"; then ok "mutant differs from honest harness"
else no "mutation was a no-op — the negative control below proves nothing"; fi

# rows() counts jq-emitted ledger records of one kind. NB `"kind":"veto-offer"` is a PREFIX of
# `"kind":"veto-offer-refused"`, so match the closing brace too — a substring count would report
# every refusal as an offer and invert this whole test.
rows(){ grep -cF "\"kind\":\"$2\"}" "$1" 2>/dev/null || true; }

# --- the six recorded offers (ts | executeAfter as written to veto-pings.jsonl) -------------------
REPLAY=(
  "2026-07-21T07:19:17Z|2026-07-21T07:04:04Z"
  "2026-07-22T10:01:03Z|2026-07-22T09:16:31Z"
  "2026-07-26T01:52:57Z|2026-07-26T01:52:57Z"
  "2026-07-26T01:54:14Z|2026-07-26T01:54:13Z"
  "2026-07-28T12:11:57Z|2026-07-28T12:11:56Z"
  "2026-07-28T12:13:33Z|2026-07-28T12:13:32Z"
)

replay_one(){ # $1=harness $2=dir $3=offset-secs $4=subject ; echoes "<offers> <refusals> <sent>"
  local h="$1" d="$2" off="$3" subj="${4:-DIVE-2257}" ea
  mkdir -p "$d"; : > "$d/sink"
  ea="$(date -u -d "+${off} seconds" +%Y-%m-%dT%H:%M:%SZ)"
  COUNCIL_MOCK=1 COUNCIL_VETO_OFFER_SINK="$d/sink" bash "$h" "$d" \
    "1234567890" "deadbeefcafe0001" "$ea" "nonce-abc" "ship it?" "carried 3/3 approve (0 reject, 0 escalate)" "" "$subj" >/dev/null 2>&1
  printf '%s %s %s\n' "$(rows "$d/veto-pings.jsonl" veto-offer)" "$(rows "$d/veto-pings.jsonl" veto-offer-refused)" "$(grep -c '' "$d/sink" 2>/dev/null || true)"
}

echo "--- the six recorded offers, replayed against the invariant"
refused=0; i=0
for r in "${REPLAY[@]}"; do
  i=$((i+1)); ts="${r%%|*}"; ea="${r##*|}"
  off=$(( $(date -u -d "$ea" +%s) - $(date -u -d "$ts" +%s) ))
  read -r offers refusals sent <<< "$(replay_one "$TMP/honest.sh" "$TMP/h$i" "$off" "DIVE-2257")"
  # graded on BOTH sides: nothing written/sent AND a refusal actually recorded (so an absent row
  # cannot pass as a refusal, and a crashed harness cannot pass as a clean refusal).
  if [[ "$offers" == "0" && "$sent" == "0" && "$refusals" == "1" ]]; then
    ok "offer $i (ts=$ts, offset=${off}s) REFUSED at write time, refusal audited"; refused=$((refused+1))
  else
    no "offer $i (ts=$ts, offset=${off}s) offers=$offers refusals=$refusals sent=$sent (want 0/1/0)"
  fi
done
if [[ "$refused" == "6" ]]; then ok "all 6 recorded offers refused (6/6)"; else no "only $refused/6 refused"; fi

echo "--- two-sided: a real window with a real subject still sends"
read -r offers refusals sent <<< "$(replay_one "$TMP/honest.sh" "$TMP/pos" 900 "DIVE-2257")"
if [[ "$offers" == "1" && "$refusals" == "0" && "$sent" == "1" ]]; then
  ok "a +900s window is written AND delivered (offers=1 refusals=0 sent=1)"
else
  no "positive control offers=$offers refusals=$refusals sent=$sent (want 1/0/1) — the invariant is over-refusing"
fi
if grep -q "DIVE-2257" "$TMP/pos/veto-pings.jsonl" 2>/dev/null; then ok "the delivered offer carries its subject"; else no "delivered offer has no subject"; fi

echo "--- the offer text names WHAT is being vetoed"
hdr="$(bash -c 'source "$1"; _council_veto_offer_header "ship it?" "carried 3/3 approve" "" "DIVE-2257"' _ "$TMP/honest.sh" 2>/dev/null)"
if [[ "$hdr" == *"Subject: DIVE-2257"* && "$hdr" == *"Decision: ship it?"* ]]; then ok "header renders Subject + Decision"
else no "header missing subject/decision: $hdr"; fi

echo "--- FINDING 2 fence: only the genesis-sealed council may reach the founder"
FSRC="$(extract _council_veto_offer_eligible)"
[[ -n "$FSRC" ]] || { echo "FAIL: could not extract _council_veto_offer_eligible"; exit 1; }
{ printf '%s\n' "$FSRC"; echo '_council_veto_offer_eligible "$@"'; } > "$TMP/fence.sh"
bash -n "$TMP/fence.sh" || { echo "FAIL: fence harness does not parse"; exit 1; }
fence(){ local o rc; o="$(bash "$TMP/fence.sh" "$@" 2>/dev/null)"; rc=$?; printf '%s|%s' "$rc" "$o"; }
# args: bench seats_given default_bench subject motion-subject motion-kind
#                                                            want      case
FENCE_CASES=(
  '""|1|council|DIVE-2257|""|""            @1|                 an ad-hoc --seats panel (the 07-26/07-28 offers) is REFUSED the founder'
  'ship|0|council|DIVE-2257|""|""           @1|                 an alternate bench is REFUSED the founder'
  '""|0|ship|DIVE-2257|""|""                @1|                 a non-council default bench is REFUSED the founder'
  'council|0|council|DIVE-2257|""|""        @0|DIVE-2257        the primary council WITH a subject is eligible'
  '""|0|council|DIVE-2257|""|""             @0|DIVE-2257        the implicit primary council is eligible'
  'council|0|council|""|olivia|demote       @0|olivia           a motion supplies its own subject'
  'council|0|council|""|""|amend            @0|motion:amend     a subjectless motion is identified by its kind'
  'council|0|council|""|""|""               @2|                 the primary council with NO subject is refused + recorded'
)
for c in "${FENCE_CASES[@]}"; do
  argstr="${c%%@*}"; rest="${c#*@}"; want="${rest%%|*}"; rest2="${rest#*|}"
  wantout="$(printf '%s' "${rest2%% *}")"; desc="$(printf '%s' "${rest2#* }" | sed 's/^ *//')"
  IFS='|' read -r a1 a2 a3 a4 a5 a6 <<< "$(printf '%s' "$argstr" | tr -d ' ')"
  unq(){ [[ "$1" == '""' ]] && printf '' || printf '%s' "$1"; }
  got="$(fence "$(unq "$a1")" "$(unq "$a2")" "$(unq "$a3")" "$(unq "$a4")" "$(unq "$a5")" "$(unq "$a6")")"
  if [[ "$got" == "${want}|${wantout}" ]]; then ok "$desc"; else no "$desc (want ${want}|${wantout}, got $got)"; fi
done

echo "--- negative control: neuter the window check and the six-way replay must go RED"
leaked=0
for i in 1 2 3 4 5 6; do
  r="${REPLAY[$((i-1))]}"; ts="${r%%|*}"; ea="${r##*|}"
  off=$(( $(date -u -d "$ea" +%s) - $(date -u -d "$ts" +%s) ))
  read -r offers refusals sent <<< "$(replay_one "$TMP/mutant.sh" "$TMP/m$i" "$off" "DIVE-2257")"
  [[ "$offers" == "1" && "$sent" == "1" ]] && leaked=$((leaked+1))
done
if [[ "$leaked" == "6" ]]; then ok "mutant re-sends all 6 expired offers — the replay is graded by the window check, not by luck"
else no "mutant leaked only $leaked/6 — the six-way replay is NOT actually measuring the window check"; fi

echo "--- FINDING 4: an ad-hoc receipt must not enter the precedent chain"
if command -v node >/dev/null 2>&1; then
  # Pull the REAL precedent-pool jq program out of the built bundle rather than retyping it here —
  # a retyped filter would only test itself.
  POOL_JQ="$(node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");const m=s.match(/if jq -s \x27([\s\S]*?)\x27 \\\n/);if(!m)process.exit(1);process.stdout.write(m[1])' "$SRC" 2>/dev/null)" || POOL_JQ=""
  if [[ -z "$POOL_JQ" ]]; then
    no "could not extract the precedent-pool filter from $SRC"
  else
    mkdir -p "$TMP/rcpt"
    jq -n '{sealedDigest:"aaa",council:"council",question:"clear DIVE-1?",stampedAt:"2026-07-20T00:00:00Z",verdict:{recommendation:"approve",brief:"real"}}' > "$TMP/rcpt/1.json"
    jq -n '{sealedDigest:"bbb",council:"ad-hoc",question:"ship it?",stampedAt:"2026-07-26T01:52:57Z",verdict:{recommendation:"approve",brief:"fine by me"}}' > "$TMP/rcpt/2.json"
    pool="$(jq -s "$POOL_JQ" "$TMP/rcpt"/*.json 2>/dev/null)" || pool='[]'
    n="$(printf '%s' "$pool" | jq -r 'length' 2>/dev/null || echo -1)"
    d="$(printf '%s' "$pool" | jq -r '.[0].digest // ""' 2>/dev/null)"
    # graded on BOTH sides: the ad-hoc receipt is gone AND the real one survived (a filter that
    # dropped everything would otherwise read as a pass).
    if [[ "$n" == "1" && "$d" == "aaa" ]]; then ok "the ad-hoc receipt is excluded, the council receipt is kept (pool=1, digest=aaa)"
    else no "precedent pool length=$n first=$d (want 1/aaa)"; fi
    # negative control: neuter the ad-hoc clause and the same fixtures must both come back.
    MUT_JQ="${POOL_JQ//!= \"ad-hoc\"/!= \"zz-no-such-bench\"}"
    if [[ "$MUT_JQ" == "$POOL_JQ" ]]; then no "ad-hoc clause not found in the filter — the check above proves nothing"
    else
      mn="$(jq -s "$MUT_JQ" "$TMP/rcpt"/*.json 2>/dev/null | jq -r 'length' 2>/dev/null || echo -1)"
      if [[ "$mn" == "2" ]]; then ok "neutering the ad-hoc clause lets the test receipt back into the pool (2) — the clause is load-bearing"
      else no "mutant pool length=$mn (want 2)"; fi
    fi
  fi
else
  echo "  skip: node not on PATH (precedent-pool extraction)"
fi

echo "--- FINDING 3 (iteration 2): a subject-less PRIMARY convene is refused AT CONVENE TIME"
# WHY THIS IS GRADED HERE AND NOT ONLY IN council_veto_e2e.sh: that suite needs root to seal a
# genesis, so it SKIPS in a scoped session — and a skip is NOT-REACHED, never PASS. The iteration-1
# build shipped precisely because the only test that could see this class never ran. These arms are
# offline: no key, no root, no live state.
#
# The iteration-1 defect was NOT in the predicate — `_council_veto_offer_eligible` correctly said
# "primary bench, no subject" (rc 2). It was in what the CALL SITE did with that answer: record the
# omission and convene anyway. The receipt sealed, no offer was minted, and the founder veto
# silently ceased to exist with nothing red anywhere. So both halves are graded, and so is the SEAM
# between them — the seam is where it broke.
CHK_SRC="$(extract _council_convene_subject_check)"
ELIG_SRC="$(extract _council_veto_offer_eligible)"
if [[ -z "$CHK_SRC" || -z "$ELIG_SRC" ]]; then
  no "could not extract _council_convene_subject_check / _council_veto_offer_eligible from $SRC"
else
  # (a) the predicate pair: primary + no subject is the ONLY combination that refuses.
  cat > "$TMP/subj.sh" <<EOSH
set -uo pipefail
$ELIG_SRC
$CHK_SRC
EOSH
  probe(){ # $1=bench $2=seats_given $3=subject $4=msubject $5=mkind $6=genesis -> "eligrc|chkrc|msg"
    local e c m
    m="$(bash -c "source '$TMP/subj.sh'; _council_veto_offer_eligible '$1' '$2' council '$3' '$4' '$5'" 2>/dev/null)"; e=$?
    m="$(bash -c "source '$TMP/subj.sh'; _council_convene_subject_check '$e' '$6'" 2>/dev/null)"; c=$?
    printf '%s|%s|%s' "$e" "$c" "$m"
  }
  r="$(probe "" 0 "" "" "" 1)"
  [[ "${r%%|*}" == "2" && "$(printf '%s' "$r" | cut -d'|' -f2)" == "1" ]] \
    && ok "primary bench + no subject + genesis -> REFUSE (elig=2, check=1)" || no "primary/no-subject did not refuse (got $r)"
  printf '%s' "$r" | grep -q -- '--subject' && ok "the refusal message names the --subject flag the caller must supply" || no "refusal message does not name --subject (got $r)"
  # the three combinations that must NOT refuse — a check that refused everything would otherwise
  # read as a pass on the arm above.
  r="$(probe "" 0 "DIVE-1" "" "" 1)"
  [[ "$(printf '%s' "$r" | cut -d'|' -f2)" == "0" ]] && ok "primary bench WITH a subject convenes (check=0)" || no "a subject-bearing primary convene was refused (got $r)"
  r="$(probe "" 1 "" "" "" 1)"
  [[ "${r%%|*}" == "1" && "$(printf '%s' "$r" | cut -d'|' -f2)" == "0" ]] \
    && ok "an AD-HOC --seats panel with no subject is UNTOUCHED (elig=1, check=0)" || no "the subject requirement leaked onto ad-hoc panels (got $r)"
  r="$(probe "" 0 "" "" "amend" 1)"
  [[ "${r%%|*}" == "0" && "$(printf '%s' "$r" | cut -d'|' -f2)" == "0" ]] \
    && ok "a governance MOTION is self-identifying (kind supplies the subject; elig=0)" || no "a motion convene was refused (got $r)"
  r="$(probe "" 0 "" "" "" 0)"
  [[ "$(printf '%s' "$r" | cut -d'|' -f2)" == "0" ]] \
    && ok "with no sealed genesis the check stands down (cli.mjs already fails that convene closed)" || no "no-genesis leg refused in the wrong layer (got $r)"

  # (b) THE SEAM: run the real call-site block with the collaborators stubbed, and assert it ABORTS.
  # This is the arm that would have caught iteration 1 — the predicate was already right there.
  CALL_SRC="$(sed -n '/^  local _cv_refusal=""$/,/^  fi$/p' "$SRC" | sed 's/^  local /  /')"
  callsites="$(grep -cF '_council_convene_subject_check "$_cv_elig"' "$SRC")"
  [[ "$callsites" == "1" ]] && ok "the convene-time check has exactly ONE call site (seam grading below is sound)" \
    || no "call-site count = $callsites (expected 1) — the seam grade is unsound"
  if [[ -z "$CALL_SRC" ]]; then
    no "could not extract the convene-time call site from $SRC"
  else
    seam(){ # $1 = check rc to simulate -> writes a trace to stdout
      cat > "$TMP/seam.sh" <<EOSH
set -uo pipefail
E_USAGE=2
_cv_elig=2; genesis_exists=1
_council_convene_subject_check(){ printf '%s' "supply --subject"; return $1; }
_council_veto_offer_omitted(){ echo "OMITTED"; return 0; }
fail(){ echo "FAILED rc=\$1"; exit 99; }
$CALL_SRC
echo "CONVENE-PROCEEDED"
EOSH
      bash "$TMP/seam.sh" 2>&1
    }
    t="$(seam 1)"
    if printf '%s' "$t" | grep -q 'FAILED rc=2' && ! printf '%s' "$t" | grep -q 'CONVENE-PROCEEDED'; then
      ok "the call site ABORTS the convene on a refusal (fail rc=E_USAGE, deliberation never runs)"
    else
      no "the call site did not abort — this is the iteration-1 defect (trace: $t)"
    fi
    printf '%s' "$t" | grep -q 'OMITTED' && ok "the refusal is still written to the auditable veto ledger before aborting" \
      || no "a refused convene leaves no audit row (trace: $t)"
    # negative control: with the check standing down the SAME block must fall through and convene.
    t="$(seam 0)"
    printf '%s' "$t" | grep -q 'CONVENE-PROCEEDED' && ok "with nothing to refuse the same block falls through and the convene proceeds" \
      || no "the call site aborts unconditionally (trace: $t)"
  fi

  # (c) the in-repo PRIMARY-bench callers must each name a subject, or they self-refuse in prod.
  # (gate-clear and the motion path already did; rot-triage and schedule did not.)
  grep -q -- '_council_convene_json "$q" --mode=adversarial --subject=' "$SRC" \
    && ok "the rot-triage convene names its subject" || no "rot-triage convenes the primary council with no subject"
  grep -q -- '--subject="schedule:$name"' "$SRC" \
    && ok "the scheduled convene names its subject" || no "council schedule convenes the primary council with no subject"
fi

echo
echo "council veto-window unit: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
