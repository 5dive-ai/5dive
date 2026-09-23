#!/usr/bin/env bash
# DIVE-4890 unit: the pacing floors are a box setting (`5dive config pace-week=…`,
# `pace-5h=…`), not only an env var on a root cron line.
#
# WHAT IS ASSERTED HERE (the row's acceptance, one arm each)
#   OFF.     `pace-week=off` → no row is ever held by the weekly band, at any
#            reading — blind, unparseable and absent documents included — and it
#            leaves the 5h floor alone. `pace-5h=off` is the same for the session
#            window.
#   8595.    `pace-week=85/95` → a high row passes at 91% and a medium row is held.
#   DEFAULT. `pace-week=default` clears the key and restores 60/90.
#   ENV.     an explicit FIVE_PACE_7D_* / FIVE_PACE_5H still wins over the config.
#   PARITY.  the digest reports the same weekly band as the tick for the same
#            reading, under every setting — and the digest's bash really hands the
#            python block the tick's resolved value.
#   BAD.     a bad value (95/85, abc, …) is refused and NOTHING is written, even
#            when it shares the call with a valid key.
#   MUTANTS. each arm above is shown to red against the defect it exists for —
#            above all, a digest that ignores the config reds PARITY.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/pace-box-config.XXXXXX")"
trap 'rc=$?; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT

# Isolation: the box file, STATE_DIR and the account-reading cache all live in
# scratch, and no env floor leaks in from the invoking shell.
export STATE_DIR="$TMPD/state"; mkdir -p "$STATE_DIR"
export BOX_CONFIG="$TMPD/box.json"
export FIVE_PACE_READING_CACHE_DIR="$TMPD/pace-reading"
unset FIVE_PACE_7D_SOFT FIVE_PACE_7D_HARD FIVE_PACE_5H FIVE_PACE_BLIND FIVE_PACE_UNMETERED

# shellcheck disable=SC1090
for f in lib/error_codes.sh lib/output.sh lib/verify_policy.sh cmd_box_config.sh task/grader_pool.sh; do
  source "src/$f"
done
require_root() { return 0; }     # the harness is not root; the setter's logic is the subject
JSON_MODE=0
# A 7d meter that cannot come from anywhere but the fixture: no account reading,
# no bound, and every account window-capable (so a null reads as BLIND, the
# weekly band's own hold, rather than as unmeterable).
_PACE_ACCOUNT_CMD=false
_PACE_ACCOUNT_BOUND_CMD=false
_PACE_WINDOW_CAPABLE_CMD=true

NOW=1789294364
FAR=$(( NOW + 6*86400 ))       # the soft floor binds
F5=$(( NOW + 3600 ))           # a live session window

setcfg(){ printf '%s\n' "$1" > "$BOX_CONFIG"; }
# <7d-pct|null> [<5h-pct|null>] -> the combined band's rc
doc(){ printf '{"agents":[{"name":"s1","account":"acct","sevenDayPct":%s,"sevenDayResetsAt":%s,"fiveHourPct":%s,"fiveHourResetsAt":%s}]}' \
         "$1" "$FAR" "${2:-null}" "$F5"; }
band(){ local rc=0; doc "$1" "${2:-null}" | _pace_band acct "$NOW" >/dev/null || rc=$?; printf '%s' "$rc"; }
adm(){ local rc=0; _pace_admits "$1" "$2" "${3:-standard}" || rc=$?; printf '%s' "$rc"; }

# ── the arms, as functions so the mutants below can re-run them ─────────────
arm_off() {  # 0 = every reading is open under pace-week=off, and nothing is held
  setcfg '{"pace_week":"off"}'
  local p rc prio kind
  for p in 0 59 60 89 90 95 100 null '"78%"'; do
    rc=$(band "$p"); [[ "$rc" == 0 ]] || { echo "7d=$p -> band $rc under off"; return 1; }
  done
  rc=0; printf '' | _pace_band acct "$NOW" >/dev/null || rc=$?
  [[ "$rc" == 0 ]] || { echo "absent document -> band $rc under off"; return 1; }
  rc=0; ( _PACE_BLIND=refuse; doc null | _pace_band acct "$NOW" >/dev/null ) || rc=$?
  [[ "$rc" == 0 ]] || { echo "blind under FIVE_PACE_BLIND=refuse -> band $rc under off"; return 1; }
  for prio in low medium high urgent ''; do for kind in standard recurring; do
    [[ "$(adm "$(band 99)" "$prio" "$kind")" == 0 ]] || { echo "${prio:-<none>}/$kind held at 99% under off"; return 1; }
  done; done
  return 0
}
arm_8595() {
  setcfg '{"pace_week":"85/95"}'
  local r91; r91=$(band 91)
  [[ "$r91" == 2 ]]                      || { echo "91% -> band $r91, want 2 (soft)"; return 1; }
  [[ "$(adm "$r91" high)" == 0 ]]        || { echo "a high row was held at 91%"; return 1; }
  [[ "$(adm "$r91" medium)" == 1 ]]      || { echo "a medium row passed at 91%"; return 1; }
  [[ "$(band 84)" == 0 ]]                || { echo "84% held under 85/95"; return 1; }
  [[ "$(band 85)" == 2 ]]                || { echo "85% not soft under 85/95"; return 1; }
  [[ "$(band 94)" == 2 ]]                || { echo "94% not soft under 85/95"; return 1; }
  [[ "$(band 95)" == 3 ]]                || { echo "95% not hard under 85/95"; return 1; }
  return 0
}
arm_env() {
  setcfg '{"pace_week":"85/95","pace_5h":"off"}'
  local rc
  rc=$( FIVE_PACE_7D_SOFT=40; band 45 ); [[ "$rc" == 2 ]] || { echo "env soft 40 over config 85/95: 45% -> $rc, want 2"; return 1; }
  setcfg '{"pace_week":"off"}'
  rc=$( FIVE_PACE_7D_HARD=90; band 95 ); [[ "$rc" == 3 ]] || { echo "env hard 90 over config off: 95% -> $rc, want 3"; return 1; }
  setcfg '{"pace_5h":"off"}'
  rc=$( FIVE_PACE_5H=50; band 20 60 ); [[ "$rc" == 3 ]] || { echo "env 5h 50 over config off: 5h 60% -> $rc, want 3"; return 1; }
  return 0
}
arm_bad() {  # 0 = every bad value refused and the file byte-identical
  local v out rc before after
  setcfg '{"verify":"always","pace_week":"70/80"}'
  before=$(sha256sum "$BOX_CONFIG")
  for v in 95/85 abc 85 85/101 101/101 085/95 -1/50 85/95/99 '' ' 85/95' 85.5/95 85/ /95 OFF; do
    rc=0; out=$(cmd_box_config "pace-week=$v" 2>&1) || rc=$?
    (( rc != 0 )) && [[ "$out" == *pace-week* ]] || { echo "pace-week='$v' accepted (rc=$rc): ${out:0:160}"; return 1; }
  done
  for v in abc 101 -5 085 '' 8.5 85/95; do
    rc=0; out=$(cmd_box_config "pace-5h=$v" 2>&1) || rc=$?
    (( rc != 0 )) && [[ "$out" == *pace-5h* ]] || { echo "pace-5h='$v' accepted (rc=$rc): ${out:0:160}"; return 1; }
  done
  # One bad key in the call writes NONE of them — the valid one included.
  rc=0; ( cmd_box_config pace-5h=70 pace-week=95/85 ) >/dev/null 2>&1 || rc=$?
  (( rc != 0 )) || { echo "a mixed good+bad call succeeded"; return 1; }
  after=$(sha256sum "$BOX_CONFIG")
  [[ "$before" == "$after" ]] || { echo "the box file changed: $(cat "$BOX_CONFIG")"; return 1; }
  # …and no file is created on a box that had none.
  rm -f "$BOX_CONFIG"
  ( cmd_box_config pace-week=abc ) >/dev/null 2>&1
  [[ ! -e "$BOX_CONFIG" ]] || { echo "a refused value created the box file"; return 1; }
  return 0
}

# PARITY: the digest's own python block, extracted from the file named, run with
# the value the digest's bash would hand it — against the tick's own band.
DPROBE="$TMPD/parity.py"
cat > "$DPROBE" <<'PYEOF'
import os, sys, time, json, datetime as dt
src = open(sys.argv[1]).read()
_a = src.index('def to_epoch(s):'); _b = src.index('\n\n', _a)
_ns = {"dt": dt}; exec(src[_a:_b], _ns); to_epoch = _ns["to_epoch"]
try:
    a = src.index('# DIVE-4430 — the PACING FLOOR')
    tail = 'paced = [p for p in pace_l if p["band"] != "open"]'
    b = src.index(tail) + len(tail)
except ValueError:
    print('EXTRACT-FAILED'); sys.exit(2)
block = src[a:b]
now = int(time.time())
out = {}
for p in sys.argv[2].split(","):
    pct = None if p == "null" else int(p)
    ns = {"os": os, "time": time, "to_epoch": to_epoch, "acct_snap": {}, "_unmet": {},
          "agents": [{"name": "s1", "account": "acct", "sevenDayPct": pct,
                      "sevenDayResetsAt": now + 6*86400}]}
    exec(block, ns)
    out[p] = ns["pace_l"][0]["band"]
print(json.dumps(out))
PYEOF
READINGS="0,40,45,59,60,69,70,84,85,89,90,91,94,95,99,100,null"
dg_week() {  # -> what the digest's bash hands its python block, from <cmd_digest file>
  local blk; blk=$(awk '/^  local _dg_pace_week=""$/{f=1} f{print} f&&/^  fi$/{exit}' "$1")
  [[ -n "$blk" ]] || { printf 'EXTRACT-FAILED'; return 0; }
  eval "_dgw(){ $blk
  printf '%s' \"\$_dg_pace_week\"; }"
  _dgw
}
arm_parity() {  # <cmd_digest file>
  local f="${1:-src/cmd_digest.sh}" cfg envs w got p tb dbnd
  grep -q 'DIGEST_PACE_WEEK="$_dg_pace_week"' "$f" \
    || { echo "the digest's python invocation is not handed DIGEST_PACE_WEEK=\$_dg_pace_week"; return 1; }
  for cfg in '{}' '{"pace_week":"85/95"}' '{"pace_week":"off"}' '{"pace_week":"70/70"}' '{"pace_week":"0/100"}' \
             'ENV:40/50:{"pace_week":"85/95"}'; do
    envs=""
    if [[ "$cfg" == ENV:* ]]; then envs="${cfg#ENV:}"; envs="${envs%%:*}"; cfg="${cfg#ENV:*:}"; fi
    setcfg "$cfg"
    w=$( [[ -n "$envs" ]] && { FIVE_PACE_7D_SOFT="${envs%/*}"; FIVE_PACE_7D_HARD="${envs#*/}"; }; dg_week "$f" )
    [[ "$w" != EXTRACT-FAILED && -n "$w" ]] || { echo "the digest's week-resolve block could not be run ($w)"; return 1; }
    got=$( [[ -n "$envs" ]] && export FIVE_PACE_7D_SOFT="${envs%/*}" FIVE_PACE_7D_HARD="${envs#*/}"
           DIGEST_PACE_WEEK="$w" timeout 60 python3 "$DPROBE" "$f" "$READINGS" 2>&1 ) || true
    [[ "$got" == \{* ]] || { echo "digest probe failed: ${got:0:200}"; return 1; }
    for p in ${READINGS//,/ }; do
      tb=0; ( [[ -n "$envs" ]] && { FIVE_PACE_7D_SOFT="${envs%/*}"; FIVE_PACE_7D_HARD="${envs#*/}"; }
              doc "$p" | _pace_band_7d acct "$NOW" >/dev/null ) || tb=$?
      tb=$(_pace_band_name "$tb")
      dbnd=$(jq -r --arg p "$p" '.[$p]' <<<"$got")
      [[ "$dbnd" == blind ]] && dbnd=soft        # the digest's name for the tick's blind soft hold
      [[ "$tb" == "$dbnd" ]] || { echo "config=$cfg env=${envs:-none} 7d=$p: tick=$tb digest=$dbnd (digest was handed '$w')"; return 1; }
    done
  done
  return 0
}

# ── the arms, on the shipping source ─────────────────────────────────────────
r=$(arm_off) && ok_ "OFF: pace-week=off holds no row at any weekly reading (blind, unparseable, absent and refuse-policy included), every priority and kind admitted" \
  || bad_ "OFF" "$r"
setcfg '{"pace_week":"off"}'
[[ "$(band 20 90)" == 3 ]] && ok_ "OFF: pace-week=off leaves the 5h floor armed (5h=90% still urgent-only)" \
  || bad_ "OFF: 5h independence" "5h=90% under pace-week=off -> $(band 20 90)"
setcfg '{"pace_5h":"off"}'
[[ "$(band 20 101)" == 0 && "$(band 70 101)" == 2 ]] && ok_ "OFF: pace-5h=off drops the session floor (5h=101% no hold) and leaves the weekly one armed" \
  || bad_ "OFF: pace-5h=off" "20/101 -> $(band 20 101), 70/101 -> $(band 70 101)"

r=$(arm_8595) && ok_ "8595: pace-week=85/95 — at 91% a high row passes and a medium row is held; 84 open, 85 soft, 95 hard" \
  || bad_ "8595" "$r"

rm -f "$BOX_CONFIG"
cmd_box_config pace-week=85/95 pace-5h=70 >/dev/null 2>&1
[[ "$(jq -r '.pace_week + " " + .pace_5h' "$BOX_CONFIG" 2>/dev/null)" == "85/95 70" ]] \
  && ok_ "SET: the setter stores .pace_week and .pace_5h" || bad_ "SET" "$(cat "$BOX_CONFIG" 2>&1)"
cmd_box_config pace-week=default pace-5h=default >/dev/null 2>&1
[[ "$(jq -c '[has("pace_week"), has("pace_5h")]' "$BOX_CONFIG")" == "[false,false]" ]] \
  && ok_ "DEFAULT: pace-week=default / pace-5h=default CLEAR the keys rather than storing the word" \
  || bad_ "DEFAULT: cleared" "$(cat "$BOX_CONFIG")"
[[ "$(band 59)" == 0 && "$(band 60)" == 2 && "$(band 89)" == 2 && "$(band 90)" == 3 && "$(_pace_week_effective)" == 60/90 && "$(_pace_5h_effective)" == 85 ]] \
  && ok_ "DEFAULT: after default the floors are 60/90 and 85 again (59 open, 60 soft, 90 hard)" \
  || bad_ "DEFAULT: restored" "59=$(band 59) 60=$(band 60) 90=$(band 90) week=$(_pace_week_effective) 5h=$(_pace_5h_effective)"

r=$(arm_env) && ok_ "ENV: FIVE_PACE_7D_SOFT / FIVE_PACE_7D_HARD / FIVE_PACE_5H each win over the box config (including over off)" \
  || bad_ "ENV" "$r"

# SHOW names the value and where it came from.
setcfg '{"pace_week":"85/95"}'
s1=$(cmd_box_config 2>&1)
s2=$(FIVE_PACE_7D_SOFT=70 cmd_box_config 2>&1)
rm -f "$BOX_CONFIG"; s3=$(cmd_box_config 2>&1)
setcfg '{"pace_week":"95/85","pace_5h":"off"}'; s4=$(cmd_box_config 2>&1)
[[ "$s1" == *"pace-week = 85/95 (config)"* && "$s1" == *"pace-5h = 85 (default)"* \
   && "$s2" == *"pace-week = 70/90 (env FIVE_PACE_7D_SOFT/FIVE_PACE_7D_HARD)"* \
   && "$s3" == *"pace-week = 60/90 (default)"* \
   && "$s4" == *"pace-week = 60/90 (default — the stored pace_week '95/85' is not a valid value and is ignored)"* \
   && "$s4" == *"pace-5h = off (config)"* ]] \
  && ok_ "SHOW: 5dive config prints each effective floor and its source (config, env, default, and a hand-edited bad value named as ignored)" \
  || bad_ "SHOW" "s1=[$s1] s2=[$s2] s3=[$s3] s4=[$s4]"
setcfg '{"pace_week":"off"}'
sj=$(JSON_MODE=1 cmd_box_config 2>&1)
[[ "$(jq -r '.data.pace_week + "|" + .data.pace_week_source + "|" + .data.pace_5h' <<<"$sj" 2>/dev/null)" == "off|config|85" ]] \
  && ok_ "SHOW: --json carries pace_week, pace_week_source and pace_5h" || bad_ "SHOW --json" "$sj"

r=$(arm_parity src/cmd_digest.sh) && ok_ "PARITY: the digest's band equals the tick's at 17 readings under default, 85/95, off, 70/70, 0/100 and env-over-config — and the digest's bash hands its python the tick's resolved week" \
  || bad_ "PARITY" "$r"

r=$(arm_bad) && ok_ "BAD: 95/85, abc, 85, 85/101, 085/95, -1/50 … and pace-5h abc/101/-5/085 are refused, a mixed good+bad call writes nothing, and the file is byte-identical" \
  || bad_ "BAD" "$r"

# ── MUTANTS: each arm reds against the defect it exists for ─────────────────
mutant_gp(){ # <sed-expr> -> path of a mutated grader_pool.sh, or empty if the sed matched nothing
  local m="$TMPD/gp_mut.sh"
  sed "$1" src/task/grader_pool.sh > "$m"
  cmp -s "$m" src/task/grader_pool.sh && { printf ''; return 0; }
  printf '%s' "$m"
}
run_mut(){ # <mutated-file> <arm-fn> -> rc of the arm against the mutant
  ( source "$1"; _PACE_ACCOUNT_CMD=false; _PACE_ACCOUNT_BOUND_CMD=false; _PACE_WINDOW_CAPABLE_CMD=true
    "$2" >/dev/null 2>&1 )
}
mut(){ # <label> <sed> <arm-fn>
  local m; m=$(mutant_gp "$2")
  if [[ -z "$m" ]]; then bad_ "$1" "the sed matched nothing — this mutant is vacuous"; return; fi
  if run_mut "$m" "$3"; then bad_ "$1" "the mutant survived — $3 is not grading it"
  else ok_ "$1"; fi
}
mut "M1: the loader ignores the box config -> 8595 reds" \
    's|^    mapfile -t kv < <(jq .*|    kv=()|' arm_8595
mut "M2: the off branch is removed from the weekly band -> OFF reds" \
    's|^  if (( _PACE_WEEK_OFF )); then$|  if false; then|' arm_off
mut "M3: env loses to config for the week -> ENV reds" \
    's|^  if \[\[ -n "${FIVE_PACE_7D_SOFT:-}" \|\| -n "${FIVE_PACE_7D_HARD:-}" \]\]; then|  if false; then|' arm_env
mut "M4: the validator stops checking soft <= hard -> BAD reds" \
    's|^  (( s <= h ))$|  true|' arm_bad

# M5 — THE ONE THE ROW NAMES: a digest that ignores the config. The python block
# goes back to reading only the env, exactly as it did before this row.
DM="$TMPD/digest_mut.sh"
sed 's|^_pace_week = (os.environ.get("DIGEST_PACE_WEEK") or "").strip()$|_pace_week = ""|' src/cmd_digest.sh > "$DM"
if cmp -s "$DM" src/cmd_digest.sh; then bad_ "M5: digest ignores config" "the sed matched nothing — this mutant is vacuous"
elif arm_parity "$DM" >/dev/null 2>&1; then bad_ "M5: digest ignores config" "the mutant survived — PARITY is not grading the digest's read of the config"
else ok_ "M5: a digest python block that ignores the config (env only, the pre-row shape) reds PARITY"; fi
# M6 — the wiring half: the bash stops handing python the resolved week.
sed 's|^  DIGEST_PACE_WEEK="$_dg_pace_week" \\$|  DIGEST_PACE_WEEK="" \\|' src/cmd_digest.sh > "$DM"
if cmp -s "$DM" src/cmd_digest.sh; then bad_ "M6: digest wiring dropped" "the sed matched nothing — this mutant is vacuous"
elif arm_parity "$DM" >/dev/null 2>&1; then bad_ "M6: digest wiring dropped" "the mutant survived"
else ok_ "M6: a digest whose bash no longer hands python the resolved week reds PARITY"; fi

# RESTORE — the mutants ran in subshells; this process still grades the product.
r=$(arm_8595) && ok_ "RESTORE: the shipping source is what this process holds" || bad_ "RESTORE" "$r"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
