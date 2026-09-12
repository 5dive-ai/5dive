#!/usr/bin/env bash
# DIVE-4223 — THE FLEET BRAKE. A red nightly smoke could only page a human; the
# fleet's 04:00Z `5dive self-update` arrived whether or not one answered, because
# flagging the release "prerelease" is a measured NO-OP on a tag-list resolver
# (community/wiki/a-brake-is-only-a-brake-if-the-fleets-resolver-reads-it.md).
#
# The brake is a `.release-hold` file on `main` — which `self-update` re-fetches
# on every run, making `main` a live fleet control plane — and the property this
# harness grades is that BOTH resolvers obey it and that an UNREADABLE hold is
# not silently the same observation as "no hold".
#
# Two resolvers, deliberately mirrored, and a control enforced on one path is
# absent on the parallel one. So both are extracted from the SHIPPED files and
# run against stubbed git/curl — no network, no paraphrase:
#   A. install.sh's pin-resolution block  (what a box installs)
#   B. cmd_selfupdate.sh's _published_cli_probe  (what `update --check` reports)
# If B drifts from A the operator is told they are behind, naming a version
# `self-update` refuses to install — permanently, both messages correct
# (the DIVE-2287 shape).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# TAG_OLD sorts LEXICALLY ABOVE TAG_NEW, the real shape of the 285-tag repo — so
# "held the newest, landed on the previous" cannot be faked by a lexical sort.
TAG_NEW="v0.15.34"; SHA_NEW="1111111111111111111111111111111111111111"
TAG_OLD="v0.9.9";   SHA_OLD="2222222222222222222222222222222222222222"

BANNER='# 5dive-release-hold v1'
HOLD_NONE="$BANNER"
HOLD_NEW="$BANNER
$TAG_NEW   red nightly smoke 2026-09-10 — onboarding wizard dead"
HOLD_ALL="$BANNER
$TAG_NEW
$TAG_OLD"
# Lines that LOOK like holds and are not. A near-miss must not hold (it would be
# an unexplained fleet-wide freeze), and the file must say so where it is armed.
HOLD_MALFORMED="$BANNER
  $TAG_NEW
#$TAG_NEW
v0.15
${TAG_NEW}x"
# A 200 of something that is not our file — a captive portal, a CDN error page,
# an html 404 body. The banner check is what turns this into `unknown` instead of
# into `no holds are armed`, which is the direction that greens on nothing.
HOLD_GARBAGE='<!DOCTYPE html><html><title>404: Not Found</title></html>'

block="$(sed -n '/^# >>> DIVE-1977 pin-resolution block/,/^# <<< DIVE-1977 pin-resolution block/p' install.sh)"
probe="$(sed -n '/^_published_cli_probe() {/,/^}$/p' src/cmd_selfupdate.sh)"
if [[ -n "$block" ]] && grep -q 'load_release_hold' <<<"$block"; then
  ok_t "install.sh's pin-resolution block is extractable and reads the release hold"
else
  bad_t "install.sh pin block missing or does not read the hold" "wanted load_release_hold inside the DIVE-1977 markers"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
if [[ -n "$probe" ]] && grep -q 'release-hold' <<<"$probe"; then
  ok_t "_published_cli_probe is extractable and reads the release hold (parallel path is not exempt)"
else
  bad_t "_published_cli_probe missing or does not read the hold" \
    "a hold only install.sh obeys makes 'update --check' name a version self-update refuses to install"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# --- stubs -------------------------------------------------------------------
# git serves the two tags and their commits; it never serves the hold (the hold
# is an https object, deliberately not a ref, so it can be edited without a tag).
git_stub='case "$*" in
  *--refs*) printf "aaaaaaa\trefs/tags/'"$TAG_OLD"'\nbbbbbbb\trefs/tags/'"$TAG_NEW"'\n" ;;
  *"refs/tags/'"$TAG_NEW"'"*) printf "'"$SHA_NEW"'\trefs/tags/'"$TAG_NEW"'^{}\n" ;;
  *"refs/tags/'"$TAG_OLD"'"*) printf "'"$SHA_OLD"'\trefs/tags/'"$TAG_OLD"'\n" ;;
  *) exit 1 ;;
esac'

# $1 = hold body, or "" meaning EVERY hold fetch fails (both rungs).
# $2 = the tag the FLEET STABLE ROUTE serves (api.5dive.com/cli-version), or ""
#      meaning the route is unreachable. DIVE-4366: since DIVE-4140 this route is
#      what a customer box actually follows, so a hold harness that can only
#      drive the tag-list resolver grades the canary rung and nothing else.
mk_curl() {
  local route_arm=""
  [[ -n "${2:-}" ]] && route_arm="$(printf 'case "$*" in *cli-version*) printf \x27%%s\\n\x27 "%s"; exit 0 ;; esac\n' "$2")"
  if [[ -n "$1" ]]; then
    printf '%s\ncase "$*" in *release-hold*) cat <<%s\n%s\n%s\nexit 0 ;; esac\nexit 22\n' \
      "$route_arm" "'HOLDEOF'" "$1" "HOLDEOF"
  else
    printf '%s\nexit 22\n' "$route_arm"
  fi
}

# Run the install.sh block. Echoes REPO=, PIN=, then RC=.
#
# EVERY file resolve_cli_target consults is pointed inside $stubs. Left at its
# defaults this harness reads the HOST it runs on — /etc/5dive/cli-canary and
# /usr/local/bin/5dive exist on a 5dive box, so the fixture tags (v0.15.34) sit
# below the real installed floor (0.35.1) and every behavioural arm fails for a
# reason that has nothing to do with the hold. A harness whose verdict depends on
# the machine grades the machine.
run_install() { # $1=hold body  [$2=block override]  [$3=rung: canary(default)|route]
  local blk="${2:-$block}" rung="${3:-canary}" stubs out rc route_tag=""
  stubs="$(mktemp -d)"
  local canary_file="$stubs/canary-absent"
  case "$rung" in
    canary) canary_file="$stubs/canary"; : > "$canary_file" ;;
    route)  route_tag="$TAG_NEW" ;;
    *)      bad_t "unknown rung '$rung'" "run_install takes canary|route"; rm -rf "$stubs"; return ;;
  esac
  printf '#!/usr/bin/env bash\n%s\n' "$git_stub" > "$stubs/git"; chmod +x "$stubs/git"
  printf '#!/usr/bin/env bash\n%s\n' "$(mk_curl "$1" "$route_tag")" > "$stubs/curl"; chmod +x "$stubs/curl"
  out="$(env -i PATH="$stubs:/usr/bin:/bin" GH_ORG="testorg" \
    CLI_VERSION_OVERRIDE_FILE="$stubs/override-absent" \
    CLI_CANARY_FILE="$canary_file" \
    CLI_VERSION_KNOWN_FILE="$stubs/last-known" \
    CLI_VERSION_URL="https://route.invalid/cli-version" \
    CLI_INSTALLED_BIN="$stubs/installed-absent" \
    CLI_TARGET_RECEIPT_FILE="$stubs/cli-target.json" \
    bash -c "set -euo pipefail
$blk
printf 'REPO=%s\nPIN=%s\n' \"\$REPO\" \"\$GH_PINNED_SHA\"" install.sh 2>&1)"; rc=$?
  rm -rf "$stubs"; printf '%s\nRC=%s\n' "$out" "$rc"
}

# Run the probe. Echoes its four lines: state / version / detail / sha256.
# The bundle fixture is served per-tag so a WRONG tag choice is visible in the
# reported VERSION, not merely in a state word.
run_probe() { # $1=hold body  [$2=probe override]
  local prb="${2:-$probe}" stubs out; stubs="$(mktemp -d)"
  printf '#!/usr/bin/env bash\n%s\n' "$git_stub" > "$stubs/git"; chmod +x "$stubs/git"
  cat > "$stubs/curl" <<CURLEOF
#!/usr/bin/env bash
args="\$*"
$(mk_curl "$1" | sed '$d')
# -o <file> is how the probe fetches the bundle and its checksum.
out=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-o" ]] && out="\$a"; prev="\$a"; done
body=""
case "\$args" in
  *"/$TAG_NEW/5dive.sha256"*) body="\$(printf 'readonly FIVE_VERSION="0.15.34"\n' | sha256sum | awk '{print \$1}')  5dive" ;;
  *"/$TAG_OLD/5dive.sha256"*) body="\$(printf 'readonly FIVE_VERSION="0.9.9"\n' | sha256sum | awk '{print \$1}')  5dive" ;;
  *"/$TAG_NEW/5dive"*) body="\$(printf 'readonly FIVE_VERSION="0.15.34"\n')" ;;
  *"/$TAG_OLD/5dive"*) body="\$(printf 'readonly FIVE_VERSION="0.9.9"\n')" ;;
  *) exit 22 ;;
esac
if [[ -n "\$out" ]]; then printf '%s\n' "\$body" > "\$out"; else printf '%s\n' "\$body"; fi
CURLEOF
  chmod +x "$stubs/curl"
  out="$(env -i PATH="$stubs:/usr/bin:/bin" bash -c "set -uo pipefail
gh_org() { printf 'testorg\n'; }
$prb
_published_cli_probe" 2>&1)"
  rm -rf "$stubs"; printf '%s\n' "$out"
}

# --- properties --------------------------------------------------------------
# Predicates are functions so the MUTANTS below are graded by the same assertion
# the shipped code is graded by — a mutant graded by a weaker check is not a
# non-vacuity proof, it is a second test.
installs_newest_when_open() { [[ "$(run_install "$HOLD_NONE" "${1:-$block}")" == *"PIN=$SHA_NEW"*"RC=0"* ]]; }
skips_held_newest()         { [[ "$(run_install "$HOLD_NEW"  "${1:-$block}")" == *"PIN=$SHA_OLD"*"RC=0"* ]]; }
unreadable_fails_closed()   { local o; o="$(run_install "" "${1:-$block}")"
                              [[ "$o" == *"RELEASE HOLD UNREADABLE"* && "$o" == *"RC=1"* && "$o" != *"REPO=https"* ]]; }

# 1. Open hold: the newest tag installs exactly as before. The brake at rest must
#    be indistinguishable from no brake, or nobody will leave it armed.
if installs_newest_when_open; then
  ok_t "hold present with no tags listed: installs the newest tag ($TAG_NEW) — the brake at rest is a no-op"
else bad_t "an empty hold changed the resolved tag" "got: $(run_install "$HOLD_NONE" | tr '\n' '|')"; fi

# 2. THE BRAKE. Hold the newest -> the box lands on the PREVIOUS release, not on
#    nothing. Holding one bad cut must not read to a box as a broken release rail.
if skips_held_newest; then
  ok_t "holding $TAG_NEW lands the box on the previous good release ($TAG_OLD), not on an error"
else bad_t "a held tag was still installed — THE BRAKE IS NOT CONNECTED" "got: $(run_install "$HOLD_NEW" | tr '\n' '|')"; fi

# 3. The parallel path reports the SAME answer. Not "also has a hold check" —
#    the same version string a box would actually end up running.
p_open="$(run_probe "$HOLD_NONE")"; p_held="$(run_probe "$HOLD_NEW")"
if [[ "$(sed -n 2p <<<"$p_open")" == "0.15.34" && "$(sed -n 2p <<<"$p_held")" == "0.9.9" ]]; then
  ok_t "update --check reports 0.15.34 when open and 0.9.9 when $TAG_NEW is held — one answer, two resolvers"
else
  bad_t "the probe and the installer disagree under a hold" \
    "open=$(tr '\n' '|' <<<"$p_open") held=$(tr '\n' '|' <<<"$p_held")"
fi

# 4. UNREADABLE IS NOT OPEN. Both rungs of the hold fetch dead => refuse, with a
#    message that says so in those words. A broken signal failing open and a real
#    outage are the same observation; only one of them may ship the release.
if unreadable_fails_closed; then
  ok_t "an unreadable hold FAILS CLOSED and is named as such (never collapsed into 'no hold is armed')"
else bad_t "an unreadable hold was treated as no hold" "got: $(run_install "" | tr '\n' '|')"; fi
p_dead="$(run_probe "")"
if [[ "$(sed -n 1p <<<"$p_dead")" == "unavailable" && "$(sed -n 3p <<<"$p_dead")" == *"not 'no hold is armed'"* ]]; then
  ok_t "the probe reports an unreadable hold as unavailable, saying it is not 'no hold is armed'"
else bad_t "the probe read an unreadable hold as open" "got: $(tr '\n' '|' <<<"$p_dead")"; fi

# 5. A 200 that is not our file is UNKNOWN, not empty. This is the case a plain
#    "did curl exit 0?" check gets wrong, and it is the common one on a captive
#    portal or a CDN error page.
o="$(run_install "$HOLD_GARBAGE")"
if [[ "$o" == *"RELEASE HOLD UNREADABLE"* && "$o" == *"RC=1"* ]]; then
  ok_t "a bannerless 200 (html error page) is UNKNOWN, not an empty hold list"
else bad_t "a bannerless 200 was parsed as 'no tags held'" "got: ${o//$'\n'/ | }"; fi

# 6. Near-miss lines do not hold. An indented tag, a commented tag, a truncated
#    version and a suffixed one are all NOT holds — an accidental fleet freeze
#    with no armer is worse to diagnose than an accidental non-hold.
o="$(run_install "$HOLD_MALFORMED")"
if [[ "$o" == *"PIN=$SHA_NEW"* && "$o" == *"RC=0"* ]]; then
  ok_t "indented / commented / truncated tag lines are not holds"
else bad_t "a malformed line held the fleet" "got: ${o//$'\n'/ | }"; fi

# 7. Everything held => refuse, distinctly. Not "no tag resolved": the rail is
#    healthy and the refusal is deliberate, and the operator page must differ.
o="$(run_install "$HOLD_ALL")"
if [[ "$o" == *"RELEASE TARGET IS HELD"* && "$o" == *"RC=1"* && "$o" != *"REPO=https"* ]] \
   && [[ "$o" != *"NO STABLE RELEASE TAG RESOLVED"* ]]; then
  ok_t "all candidates held: refuses with its own message, not 'NO STABLE RELEASE TAG RESOLVED'"
else bad_t "all-held did not refuse distinctly" "got: ${o//$'\n'/ | }"; fi

# --- THE FLEET RUNG (DIVE-4366) ----------------------------------------------
# Arms 1-7 drive the CANARY rung, because when this harness was written the
# tag-list resolver WAS the fleet's resolver. DIVE-4140 moved customer boxes onto
# the fleet stable route (api.5dive.com/cli-version) and left the tag list
# answering the canary opt-in only. A hold subtracted from a candidate list is
# therefore a brake on the handful of canary boxes and on nothing else — the
# 04:00Z fleet would take a held release exactly as before, which is the same
# "deployed and connected to nothing" shape the prerelease flag had.
#
# The route rung hands back ONE tag, so there is no next-best candidate to fall
# to: a held target is a REFUSAL. Falling back to last-known would turn a hold
# into a silent downgrade, and a hold holds boxes back rather than pulling them
# back — the box keeps the CLI it has.
route_open_installs() { [[ "$(run_install "$HOLD_NONE" "${1:-$block}" route)" == *"PIN=$SHA_NEW"*"RC=0"* ]]; }
route_held_refuses()  { local o; o="$(run_install "$HOLD_NEW" "${1:-$block}" route)"
                        [[ "$o" == *"RELEASE TARGET IS HELD"* && "$o" == *"RC=1"* && "$o" != *"REPO=https"* ]]; }
route_unreadable_fails_closed() { local o; o="$(run_install "" "${1:-$block}" route)"
                        [[ "$o" == *"RELEASE HOLD UNREADABLE"* && "$o" == *"RC=1"* && "$o" != *"REPO=https"* ]]; }

if route_open_installs; then
  ok_t "fleet route rung, hold open: installs the tag the route names ($TAG_NEW) — the brake at rest is a no-op here too"
else bad_t "an empty hold changed what the fleet route resolved" "got: $(run_install "$HOLD_NONE" "$block" route | tr '\n' '|')"; fi

if route_held_refuses; then
  ok_t "fleet route rung, target held: REFUSES and pins nothing — the 04:00Z cron is braked, not just the canary"
else bad_t "a held tag was still installed on the FLEET rung — THE BRAKE REACHES THE CANARY ONLY" \
      "got: $(run_install "$HOLD_NEW" "$block" route | tr '\n' '|')"; fi

if route_unreadable_fails_closed; then
  ok_t "fleet route rung, hold unreadable: FAILS CLOSED (an unknown hold is not an open one on the fleet path either)"
else bad_t "an unreadable hold was treated as open on the fleet rung" "got: $(run_install "" "$block" route | tr '\n' '|')"; fi

# 8. THE HOLD IS READ FROM `main`, NEVER FROM THE TAG. Reading it from the
#    candidate tree would let a bad release exempt itself — the entire failure
#    this exists to prevent, and it is invisible to every behavioural arm above
#    because the stubs would answer either URL.
for f in install.sh src/cmd_selfupdate.sh; do
  urls="$(grep -o '[^"]*\.release-hold[^"]*' "$f" | grep -E 'raw\.githubusercontent|api\.github\.com')"
  if [[ -n "$urls" ]] && ! grep -qvE '/main/\.release-hold|contents/\.release-hold\?ref=main' <<<"$urls"; then
    ok_t "$f fetches .release-hold only from main (a held tag cannot exempt itself)"
  else
    bad_t "$f fetches .release-hold from something other than main" "urls: ${urls//$'\n'/ | }"
  fi
done

# 9. The file itself ships, with the banner both readers key on and the line
#    shape whoever arms it under incident pressure will copy.
if [[ -f .release-hold ]] && [[ "$(head -1 .release-hold)" == "$BANNER" ]]; then
  ok_t ".release-hold ships on main with the banner both resolvers require"
else
  bad_t ".release-hold missing or its banner drifted" \
    "both readers treat a bannerless body as UNKNOWN, so a drifted banner freezes the whole fleet"
fi

# --- NON-VACUITY -------------------------------------------------------------
# Each mutant reintroduces one of the two ways this control is fully deployed and
# connected to nothing, and each is asserted to have APPLIED first — a mutation
# that failed to apply grades green for the same reason a passing test does.
mutant_red() { # $1=label  $2=sed expr  $3=predicate
  local mutant; mutant="$(sed "$2" <<<"$block")"
  if [[ "$mutant" == "$block" ]]; then
    bad_t "mutation '$1' did not apply" "sed '$2' changed nothing — the arm is vacuous, not passing"; return
  fi
  if "$3" "$mutant"; then bad_t "mutation '$1' still passes" "predicate $3 cannot detect this bug"
  else ok_t "mutation '$1' is caught by $3"; fi
}
# (a) the hold is fetched and then ignored — the prerelease-flag failure exactly:
#     a control that exists, is deployed, and is read by nothing.
mutant_red "hold is fetched and then ignored" 's/if \[\[ -n "\$RELEASE_HOLD_LIST" \]\]; then/if false; then/' skips_held_newest
# (b) unreadable encoded as ok — absence encoded as presence, the direction that
#     ships the release the hold exists to stop.
mutant_red "unreadable hold reported as ok" 's/RELEASE_HOLD_STATE="unreadable"/RELEASE_HOLD_STATE="ok"/' unreadable_fails_closed
# (c) and the open case must still be the thing that breaks if the walk breaks,
#     so the two arms above cannot both be satisfied by refusing everything.
mutant_red "picks the OLDEST surviving tag" 's/| tail -1)"$/| head -1)"/' installs_newest_when_open
# (d) DIVE-4366's own defect, as a mutant: the hold wired into the TAG-LIST
#     resolver only. Every canary arm above still passes under it — which is
#     precisely why it shipped as a brake once and braked nothing.
mutant_red "hold checked on the candidate list only (canary braked, fleet not)" \
  's/if \[\[ -n "\$RELEASE_HOLD_LIST" \]\] && printf/if false \&\& printf/' route_held_refuses

echo; echo "$PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]
