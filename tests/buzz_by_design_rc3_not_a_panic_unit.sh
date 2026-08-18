#!/usr/bin/env bash
# DIVE-3558 — A BY-DESIGN rc=3 ON THE BUZZ ARC MUST NOT RENDER AS THE PANIC BANNER.
#
# THE DEFECT, measured on sure-redwood at CLI 0.19.41 and reproduced here on a
# built bundle at origin/main a4f794f: `5dive agent buzz status <seat>` on a seat
# that declares the channel but has no plugin/config/binary returns 3 — the
# DESIGNED "declared but not usable" value a caller branches on (cmd_agent_buzz.sh
# says so in its own header) — and the EXIT backstop in lib/output.sh then appends
#
#   "5dive agent exited 3 without reporting a reason. This is a bug in the CLI ...
#    the command did NOT run to completion and its effect is UNKNOWN ... file it"
#
# to it, because `_buzz_status` never called `mark_reported`. It DID run to
# completion and its effect is exactly nothing. This is the FIRST verb of the
# Connect Buzz path, so every correctly-wired-but-not-yet-ready seat read as a
# crash to the customer.
#
# WHY A NEW FILE AND NOT AN ARM IN tests/silent_nonzero_exit_backstop_unit.sh.
# That harness enumerates its population by `exit N` SITES over the built bundle
# (its census A). None of these four sites is an `exit` — they are `return 3` from
# a verb function, promoted to the process status by main's dispatch. An exit-site
# census cannot see them, the same way it could not see a trap-clobbering line
# that contains no `exit`. So the shape gets its own census here, over the four
# buzz verbs that return non-zero ON PURPOSE.
#
# THE FIX IS TWO HALVES AND BOTH ARE GRADED. `mark_reported` claims "this exit
# already told the caller why" — which is a LIE unless something told them. So
# arm 3 pins that the run still prints a real reason naming what is missing;
# a fix that only silences the backstop would leave a bare table and rc=3.
#
# NON-VACUITY: arm 2 runs the identical invocation on a bundle with the
# `mark_reported` line cut out of `_buzz_status` and requires the banner BACK. If
# that arm ever goes quiet, arm 1 is grading nothing.
#
# Runs the SHIPPED artifact: builds a throwaway bundle via BUILD_OUT and executes
# it against a temp STATE_DIR holding a two-agent registry. Root is neutered by
# rewriting `require_root` in the throwaway bundle (the arms are read-only; the
# real gate is not what is under test). No network, no relay, no root, and it
# never reads the host's /var/lib/5dive.
# Run: bash tests/buzz_by_design_rc3_not_a_panic_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
. "$(dirname "${BASH_SOURCE[0]}")/lib/env_isolation.sh" 2>/dev/null || true
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
declare -F _five_env_isolate >/dev/null && _five_env_isolate
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/buzz-rc3-panic.XXXXXX)"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

BANNER_RE='without reporting a reason'

BIN="$TMP/5dive"
if ! BUILD_OUT="$BIN" bash build.sh >"$TMP/build.log" 2>&1; then
  bad_t 'build a throwaway bundle to grade' "$(tail -3 "$TMP/build.log")"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi

# Neuter the two lines that need root, and NOTHING else. `require_root` is the
# gate; `ensure_state` chowns the state dir to root:claude. Both are bootstrap,
# neither is under test here — but a rewrite that silently missed would turn every
# behaviour arm into "refused at the root gate" (rc=10, no banner), i.e. GREEN for
# the wrong reason. So the rewrite is asserted below before anything is graded.
neuter_root() { # <src> [cut] — writes to stdout; `cut` also removes _buzz_status's mark_reported
  awk -v cut="${2:-}" '
    /^require_root\(\) \{/  { print "require_root() { : ; }"; skip=1; next }
    /^ensure_state\(\) \{/  { print "ensure_state() { mkdir -p \"$STATE_DIR\"; }"; skip=1; next }
    skip && /^\}/ { skip=0; next }
    skip { next }
    cut == "cut" && /^    mark_reported$/ { next }
    { print }
  ' "$1"
}
neuter_root "$BIN"     > "$TMP/5dive-noroot";  chmod +x "$TMP/5dive-noroot"
neuter_root "$BIN" cut > "$TMP/5dive-mutant";  chmod +x "$TMP/5dive-mutant"
NOROOT="$TMP/5dive-noroot"; MUT="$TMP/5dive-mutant"
for b in "$NOROOT" "$MUT"; do
  grep -q '^require_root() { : ; }' "$b" && grep -q '^ensure_state() { mkdir -p' "$b" \
    || bad_t 'the root-gate rewrite took' "every behaviour arm below would grade a permission refusal instead ($b)"
done
# The mutant must differ from the fixed bundle by exactly the removed call(s).
if [[ "$(grep -c '^    mark_reported$' "$NOROOT")" -gt "$(grep -c '^    mark_reported$' "$MUT")" ]]; then
  ok_t 'the mutant bundle is the fixed one minus its mark_reported call — the differential is real'
else
  bad_t 'mutant rewrite did not remove mark_reported' 'arm 2 would be comparing a bundle to itself'
fi

ST="$TMP/state"; mkdir -p "$ST"
cat > "$ST/agents.json" <<'JSON'
{"schemaVersion":99,"agents":{"probe":{"type":"claude","channels":"buzz","status":"stopped"},
           "nobuzz":{"type":"claude","channels":"telegram","status":"stopped"}}}
JSON

RC=0; OUT=""; ERR=""
run() { local bin="$1"; shift; RC=0
  OUT=$(STATE_DIR="$ST" "$bin" "$@" 2>"$TMP/err.txt") || RC=$?
  ERR=$(cat "$TMP/err.txt"); }

# --- 1. THE DEFECT, FIXED ----------------------------------------------------
# `probe` declares buzz and has no plugin and no config (no such user, no such
# home) — the DIVE-3536 shape. rc MUST still be 3: the panel branches on it.
run "$NOROOT" agent buzz status probe
if [[ $RC -eq 3 ]]; then
  ok_t 'agent buzz status still returns the designed rc=3 on declared-but-not-usable'
else
  bad_t 'the by-design exit code must not move' "rc=$RC — a caller (the Connect Buzz panel) branches on this, stdout=[${OUT:0:200}] stderr=[${ERR:0:200}]"
fi
if [[ ! "$ERR" =~ $BANNER_RE && ! "$OUT" =~ $BANNER_RE ]]; then
  ok_t 'and it no longer renders the generic "this is a bug in the CLI" panic banner'
else
  bad_t 'the panic banner is back on a by-design rc=3' "stderr=[${ERR:0:400}]"
fi

# --- 2. NON-VACUITY: the same run, mark_reported cut out ---------------------
run "$MUT" agent buzz status probe
if [[ $RC -eq 3 && "$ERR" =~ $BANNER_RE ]]; then
  ok_t "non-vacuity: with mark_reported removed the SAME invocation is rc=3 WITH the banner"
else
  bad_t 'the mutant must reproduce the defect' "rc=$RC stderr=[${ERR:0:400}] — if this is not the banner, arm 1 proves nothing"
fi

# --- 3. mark_reported CLAIMS a report, so there must BE one ------------------
run "$NOROOT" agent buzz status probe
[[ "$ERR$OUT" == *'NOT WIRED YET'* ]] \
  && ok_t 'the run says out loud that the seat is not wired yet (rc=3 is not silent)' \
  || bad_t 'silencing the backstop must not silence the reason' "mark_reported means 'already told the caller why'; stderr=[${ERR:0:400}]"
[[ "$ERR$OUT" == *'the buzz plugin'* ]] \
  && ok_t 'and it NAMES the missing piece rather than leaving three `no`s in a table' \
  || bad_t 'the reason must name what is missing' "stderr=[${ERR:0:400}]"
[[ "$ERR$OUT" == *'5dive agent buzz enable probe'* ]] \
  && ok_t 'and prints the command that fixes it' \
  || bad_t 'the reason should carry the next step' "stderr=[${ERR:0:400}]"

# --- 4. CONTROL: a seat that does not declare buzz is rc=0 and quiet ---------
# Without this, a fix that made status ALWAYS return 0, or always warn, passes
# every arm above.
run "$NOROOT" agent buzz status nobuzz
if [[ $RC -eq 0 && "$ERR$OUT" != *'NOT WIRED YET'* && ! "$ERR" =~ $BANNER_RE ]]; then
  ok_t 'control: an undeclared seat is rc=0, no warning, no banner'
else
  bad_t 'the undeclared control moved' "rc=$RC stderr=[${ERR:0:300}]"
fi

# --- 5. CENSUS: every by-design non-zero return on the buzz arc claims it -----
# The population, by inspection of the three buzz files (the exit-site census in
# tests/silent_nonzero_exit_backstop_unit.sh cannot see `return`-shaped ones):
#   cmd_agent_buzz.sh      _buzz_status        return 3            declared-but-unusable
#   cmd_agent_buzz.sh      _buzz_enable        return $last_mile_rc  last mile's rc
#   cmd_agent_buzz_join.sh _buzz_join          return 3            some channels unwired
#   cmd_agent_buzz_pair.sh _buzz_pair          return 3            pairing failed/timed out
# Each already prints its own reason; each must therefore mark_reported. Graded on
# SOURCE, because a new by-design rc added later will not be covered by arms 1-4.
census_unmarked() { # prints any `return <n>`/`return "$var"` in the buzz files with no
                    # mark_reported in the 8 lines above it
  local f
  for f in "$SRC/cmd_agent_buzz.sh" "$SRC/cmd_agent_buzz_join.sh" "$SRC/cmd_agent_buzz_pair.sh"; do
    awk -v F="$f" '
      { for (i = NR>8 ? NR-8 : 1; i <= NR; i++) {} 
        buf[NR]=$0 }
      /^[[:space:]]*return[[:space:]]+("?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?|[1-9][0-9]*)[[:space:]]*$/ {
        marked=0
        for (i = (NR>8 ? NR-8 : 1); i < NR; i++) if (buf[i] ~ /mark_reported/) marked=1
        if (!marked) printf "%s:%d:%s\n", F, NR, $0
      }
    ' "$f"
  done
}
UNMARKED="$(census_unmarked)"
# The known-and-classified exceptions: helpers whose non-zero is consumed by a
# CALLER inside the same process and never becomes the exit status.
#   _buzz_resolve_binary / _buzz_lists_channel_id / _buzz_channel_id / _buzz_xonly_pubkey
#   / _buzz_source_supports — predicates, `|| true`-guarded or branched on.
if [[ -z "$UNMARKED" ]]; then
  ok_t 'census: no unmarked by-design non-zero return anywhere on the buzz arc'
else
  # Any hit inside a verb function (the four above) is a defect; hits inside the
  # predicate helpers are expected. Report the whole set so a new one is visible.
  BAD=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    f="${line%%:*}"; rest="${line#*:}"; n="${rest%%:*}"
    fn=$(awk -v n="$n" 'NR<=n && /^[_A-Za-z][_A-Za-z0-9]*\(\) \{/ {f=$1} END{print f}' "$f")
    case "$fn" in
      '_buzz_status()'|'_buzz_enable()'|'_buzz_join()'|'_buzz_pair()') BAD+="$line  (in $fn)"$'\n' ;;
    esac
  done <<< "$UNMARKED"
  if [[ -z "$BAD" ]]; then
    ok_t 'census: the only unmarked non-zero returns are the classified in-process predicates'
  else
    bad_t 'a verb returns non-zero without claiming its report' "$BAD
Each of these becomes the process exit status, so lib/output.sh will append
\"exited N without reporting a reason ... this is a bug in the CLI\" over it.
Print the reason, then \`mark_reported\` before the return (DIVE-3558)."
  fi
fi
# Liveness for the census: it must FIND the site when the call is removed.
MUTSRC="$TMP/mut_src"; mkdir -p "$MUTSRC"
cp "$SRC"/cmd_agent_buzz*.sh "$MUTSRC/"
grep -v '^    mark_reported$' "$SRC/cmd_agent_buzz.sh" > "$MUTSRC/cmd_agent_buzz.sh"
# The grep is deliberately NOT in a pipeline with the census: `grep -q` closes its
# stdin on the first match, the subshell dies of SIGPIPE, and `pipefail` then makes
# the whole pipeline non-zero — the arm would read RED on a census that worked.
LIVE_OUT="$(SRC="$MUTSRC"; census_unmarked)"
STATUS_RET_LINE=$(grep -n '^    return 3$' "$MUTSRC/cmd_agent_buzz.sh" | head -1 | cut -d: -f1)
if [[ -n "$STATUS_RET_LINE" ]] && grep -qF "cmd_agent_buzz.sh:${STATUS_RET_LINE}:" <<<"$LIVE_OUT"; then
  ok_t "liveness pair: the same census DOES flag _buzz_status's return 3 when mark_reported is cut"
else
  bad_t 'the census cannot detect the defect it exists for' "arm 5 is vacuous — cut-tree census was:
$LIVE_OUT"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
