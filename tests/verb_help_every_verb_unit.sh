#!/usr/bin/env bash
# DIVE-9485: `--help` answers on EVERY verb's leaves, not one verb at a time.
#
# THE DEFECT (reported 6 times from 2 boxes; measured at origin/main eae5f4ac):
#
#   5dive secret link --help     -> error: unknown flag: --help              rc 2
#   5dive secret link -h         -> error: bad task ref '-h'                 rc 3
#   5dive market search --help   -> error: unknown flag: --help              rc 2
#   5dive market search -h       -> rc 0, but a market SEARCH for "-h"
#
# DIVE-569 fixed agent/account/task, DIVE-9374 host/route/pkg/usage — each a named
# list, and each left the next verb behind. main() now has one generic arm
# (_verb_leaf_help, src/lib/output.sh) for every verb not on _VERB_HELP_SELF.
#
# Section C is the class guard: it reads main()'s verb table the way
# scripts/install-contract.sh T4 does, and for every verb with a documented
# subcommand asks `5dive <verb> <first sub> --help`. A new verb that forgets
# --help is red here with no list to edit. The mutant deletes the arm's one line
# from a copy of the bundle and must fail arms A and C.
#
# Graded on the BUILT BUNDLE, sandboxed (own HOME and STATE_DIR, no task store),
# as tests/verb_help_remainder_unit.sh does.
#
#   bash tests/verb_help_every_verb_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/verb-help-every.XXXXXX)"
chmod 755 "$TMP"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

BUNDLE="$TMP/5dive"
if ! BUILD_OUT="$BUNDLE" ./build.sh >"$TMP/build.log" 2>&1; then
  bad_t "P0: a bundle builds" "$(tail -3 "$TMP/build.log")"
  echo "-----"; printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"; exit 1
fi
ok_t "P0: a bundle builds (the artifact the fix ships in)"

MUTANT="$TMP/5dive-mutant"
grep -v -F '  _verb_leaf_help "$top" "$@" && exit 0' "$BUNDLE" >"$MUTANT"
chmod +x "$MUTANT"
removed=$(( $(wc -l <"$BUNDLE") - $(wc -l <"$MUTANT") ))
[[ "$removed" == 1 ]] && bash -n "$MUTANT" \
  && ok_t "P1: the mutant drops exactly the generic arm's one line, and parses" \
  || bad_t "P1: mutant removed $removed lines (want 1) or does not parse" "$(bash -n "$MUTANT" 2>&1 | head -2)"

# The secret case must run as a NON-ROOT seat (secret link is root-only, and the
# question must not need root). Under uid 0, drop to nobody.
mkdir -p "$TMP/home" "$TMP/state"; chmod 777 "$TMP/home" "$TMP/state"
AS=()
if (( EUID == 0 )); then
  if command -v setpriv >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
    AS=(setpriv --reuid="$(id -u nobody)" --regid="$(id -g nobody)" --clear-groups --)
  else
    bad_t "P2: a non-root uid to run as" "uid 0 and no setpriv/nobody"
  fi
fi
run() { local b="$1"; shift
  ( HOME="$TMP/home" STATE_DIR="$TMP/state" timeout 30 "${AS[@]}" "$b" "$@" ) </dev/null >"$TMP/out" 2>"$TMP/err"
  printf '%s' "$?"; }
out() { cat "$TMP/out"; }
err() { cat "$TMP/err"; }
run "$BUNDLE" whoami >/dev/null
ok_t "P2: the leaves run as uid $( "${AS[@]}" id -u 2>/dev/null || id -u ) (not root)"

# --- A) the two reported leaves --------------------------------------------------
# "<args>|<needle>|<needle>..." — every needle on stdout, rc 0, no `error:`.
CASES=(
  "secret link --help|5dive secret link|--save|--ttl"
  "secret link -h|5dive secret link|--save|--ttl"
  "secret link DIVE-1 --help|5dive secret link|--save|--ttl"
  "market search --help|5dive market search|--role|--rarity"
  "market search -h|5dive market search|--role|--rarity"
)
check_cases() {   # <bundle> <label> → how many cases answered, in $TMP/answered
  local b="$1" label="$2" c args needles n nd rc good answered=0
  for c in "${CASES[@]}"; do
    args="${c%%|*}"; needles="${c#*|}"
    # shellcheck disable=SC2086
    rc=$(run "$b" $args)
    good=1; [[ "$rc" == 0 ]] || good=0
    IFS='|' read -r -a n <<<"$needles"
    for nd in "${n[@]}"; do has "$(out)" "$nd" || good=0; done
    has "$(err)$(out)" "error:" && good=0
    if [[ "$label" == fixed ]]; then
      (( good )) && ok_t "A1: 5dive $args -> rc 0, names: ${needles//|/, }" \
        || bad_t "A1: 5dive $args" "rc=$rc out=$(out | head -3) err=$(err | head -3)"
    fi
    (( good )) && answered=$((answered+1))
  done
  printf '%s' "$answered" >"$TMP/answered"
}
check_cases "$BUNDLE" fixed

# --- N) negative controls: a call that asks nothing behaves as before -------------
rc=$(run "$BUNDLE" secret link --bogus)
[[ "$rc" == 2 ]] && has "$(err)" "unknown flag: --bogus" \
  && ok_t "N1: secret link --bogus -> rc 2 unknown flag: --bogus" \
  || bad_t "N1: secret link --bogus" "rc=$rc err=$(err)"
rc=$(run "$BUNDLE" secret link DIVE-1)
[[ "$rc" != 0 ]] && has "$(err)" "must run as root" \
  && ok_t "N2: non-root secret link DIVE-1 is still refused for root (rc $rc)" \
  || bad_t "N2: secret link DIVE-1 non-root" "rc=$rc err=$(err)"
same_as_mutant() {   # <label> <args...>
  local label="$1"; shift
  local r1 o1 e1 r2
  r1=$(run "$BUNDLE" "$@"); o1=$(out); e1=$(err)
  r2=$(run "$MUTANT" "$@")
  [[ "$r1" == "$r2" && "$o1" == "$(out)" && "$e1" == "$(err)" ]] \
    && ok_t "$label (rc $r1, identical to the pre-fix bundle)" \
    || bad_t "$label" "fixed rc=$r1 err=$e1 | base rc=$r2 err=$(err)"
}
same_as_mutant "N3: secret link --ttl=--help is a VALUE, not a question" secret link --ttl=--help
same_as_mutant "N4: help after -- is not a question" secret link -- --help
same_as_mutant "N5: tool ls (no help asked) is untouched" tool ls
# market search goes to the network, so compare the SHAPE, not the bytes: the
# fixed bundle searches (no usage block) exactly when the base does.
rc=$(run "$BUNDLE" market search zzzz-no-such-pack); o1=$(out)
r2=$(run "$MUTANT" market search zzzz-no-such-pack)
[[ "$rc" == "$r2" ]] && ! has "$o1" "browse & search the agent market before you hire" \
  && ok_t "N6: market search <kw> still searches (rc $rc, as the base; no usage block)" \
  || bad_t "N6: market search <kw>" "fixed rc=$rc base rc=$r2 out=$(printf '%s' "$o1" | head -3)"

# --- C) the class guard: every verb in main()'s verb table ------------------------
# The same extractor as scripts/install-contract.sh T4, and the same DENY (verbs
# that act whatever argv says). Hidden _verbs are stdin-fed primitives.
DENY=' uninstall self-update self_update update paperclip-seed fire hire '
mapfile -t VERBS < <(
  awk '/^  case "\$top" in$/{n++} n==2{ if ($0 ~ /^    \*\)/) exit; print }' "$BUNDLE" \
    | grep -oE '^    [a-z][a-z0-9|_-]*\)' | tr -d ' )' | tr '|' '\n' | sort -u
)
if (( ${#VERBS[@]} < 40 )); then
  bad_t "C0: verb table enumerated" "only ${#VERBS[@]} verbs — the extractor went blind; fix it, do not lower the floor"
else
  ok_t "C0: ${#VERBS[@]} verbs enumerated from the bundle's verb table"
fi
( HOME="$TMP/home" STATE_DIR="$TMP/state" "${AS[@]}" "$BUNDLE" --help ) </dev/null >"$TMP/top" 2>&1
first_sub() {   # <verb> → the first subcommand its usage text documents, or nothing
  local v="$1"
  { cat "$TMP/top"; ( HOME="$TMP/home" STATE_DIR="$TMP/state" timeout 30 "${AS[@]}" "$BUNDLE" "$v" --help ) </dev/null 2>&1; } \
    | grep -oE "^[[:space:]]*(sudo )?5dive $v [a-z][a-z0-9_-]*([[:space:]|]|\$)" \
    | sed -E "s/^[[:space:]]*(sudo )?5dive $v //; s/[[:space:]|]+\$//" \
    | grep -vx 'help' | head -1
}
: >"$TMP/c-fixed"; : >"$TMP/c-mutant"
checked=0
for v in "${VERBS[@]}"; do
  [[ $DENY == *" $v "* ]] && continue
  sub=$(first_sub "$v")
  [[ -n "$sub" ]] || continue
  checked=$((checked+1))
  for b in fixed mutant; do
    bin="$BUNDLE"; [[ $b == mutant ]] && bin="$MUTANT"
    rc=$(run "$bin" "$v" "$sub" --help)
    if [[ "$rc" == 0 ]] && ! grep -q '^error:' "$TMP/err" "$TMP/out"; then
      echo "$v $sub" >>"$TMP/c-$b"
      [[ $b == fixed ]] && ok_t "C1: 5dive $v $sub --help -> rc 0, no error:"
    elif [[ $b == fixed ]]; then
      bad_t "C1: 5dive $v $sub --help" "rc=$rc $(grep -h -m1 'error:' "$TMP/err" "$TMP/out" | head -1)"
    fi
  done
done
(( checked >= 25 )) && ok_t "C2: $checked verbs with a documented subcommand were asked" \
  || bad_t "C2: only $checked verbs had a documented subcommand" "the sub extractor went blind"

# --- M) the mutant (arm removed) is red on A and C --------------------------------
check_cases "$MUTANT" mutant
m=$(cat "$TMP/answered")
[[ "$m" == 0 ]] && ok_t "M1: MUTANT answers 0 of ${#CASES[@]} arm-A cases (red on the base)" \
  || bad_t "M1: mutant answered $m of ${#CASES[@]}" "arm A cannot tell the fix from the base"
nf=$(wc -l <"$TMP/c-fixed"); nm=$(wc -l <"$TMP/c-mutant")
(( nm < nf )) && ok_t "M2: MUTANT answers $nm of $checked class-guard verbs, the fix $nf ($(( nf - nm )) red without the arm)" \
  || bad_t "M2: mutant answered $nm, fix $nf" "arm C cannot tell the fix from the base"

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
