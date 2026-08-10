#!/usr/bin/env bash
# DIVE-3135 — `5dive gh` is a PASSTHROUGH, and this harness grades the three ways
# it stopped being one. Public issues #526 ("gh exited 1", v0.19.5) and #553
# ("gh exited 4", v0.19.10) are the same defect wearing two exit codes.
#
# WHY THIS IS AN E2E AND NOT A UNIT. The bug did not live in cmd_gh.sh at all —
# cmd_gh has always done `gh "$@"`. It lived in main()'s global `--json` stripper,
# which removed the flag from argv BEFORE dispatch, leaving gh's field list
# (`state`) behind as a stray positional so gh's own cobra parser answered
# "accepts at most 1 arg(s), received 2". Neither half is wrong in isolation, so
# there is no unit that can see it: only the composed argv path can. Sourcing
# cmd_gh.sh and calling it directly would pass while the shipped CLI stayed broken
# — the whole reason a unit harness never caught this in the first place.
#
# The real gh is never called. A stub named `gh` sits first on PATH and reports
# the argv it received, so we grade what REACHES the tool rather than what the
# tool then does with it.
#
# Arms:
#   A  argv after a passthrough verb reaches gh byte for byte (`--json state`)
#   B  the equals form still works (it was the documented workaround — it must
#      not have been "fixed" into something else)
#   C  `5dive --json gh ...` — the flag BEFORE the verb is still 5dive's
#   D  a non-passthrough verb still gets `--json` stripped (no collateral)
#   E  gh's non-zero is reported as GH's status, not as "a bug in the CLI"
#   F  the DIVE-2792 discriminator survives: internal failure keeps class=generic
#   G  the banner does not name a credential that has not resolved
#   H  whoami and --explain — the two single-token forms that always worked — still do
# Run: bash tests/gh_passthrough_argv_e2e.sh   (no root, no network, no real gh)
#
# TIER: core by default, deliberately. Measured 4.3s on the control plane (a
# contended reading, so CI is likely faster); ~3.9s of that is the one build.sh.
# It guards a documented public interface that was totally broken in two shipped
# releases, and the defect lives in main.sh — a PR can re-introduce it without
# touching this file, which is exactly the case `changed-harnesses` cannot cover.
# Baseline, run against pristine origin/main @ 6763609: 14 passed, 6 FAILED
# (both A arms, two E arms, the JSON class, and G). It detects the bug it names.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d /tmp/gh-passthrough-e2e.XXXXXX)"
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi
export STATE_DIR="$TMP"          # isolate — never touch a live state dir

# --- the stub gh -------------------------------------------------------------
# Writes its argv NUL-joined (so an empty or space-bearing argument is still
# countable) to $TMP/gh.argv, and exits with whatever GH_STUB_RC says. It also
# answers `auth token`, which is how the new banner resolves the caller identity
# WITHOUT a network call — a stub that did not would make arm G grade the probe's
# failure rather than its answer.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "token" ]]; then
  [[ -n "${GH_STUB_TOKEN:-}" ]] || { echo "no token" >&2; exit 1; }
  printf '%s\n' "$GH_STUB_TOKEN"; exit 0
fi
: >"${GH_STUB_ARGV:?}"
for a in "$@"; do printf '%s\0' "$a" >>"$GH_STUB_ARGV"; done
printf 'STUB-GH-STDERR: the reason gh itself would have given\n' >&2
exit "${GH_STUB_RC:-0}"
STUB
chmod +x "$TMP/bin/gh"
export GH_STUB_ARGV="$TMP/gh.argv"
export GH_STUB_TOKEN="ghp_stub_not_a_real_token"
export PATH="$TMP/bin:$PATH"

P=0; F=0
ok(){  P=$((P+1)); printf 'ok   - %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
chk(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "want='$2' got='$3'"; }

# argv the stub last received, rendered as space-joined tokens for comparison.
seen(){ tr '\0' ' ' <"$GH_STUB_ARGV" 2>/dev/null | sed 's/ $//'; }

# --- ARM A: the reported failure ---------------------------------------------
# `5dive gh pr view 51 --repo R --json state` — the exact shape in issue #526 and
# in the wiki note that told everyone to use the equals form instead. gh must see
# `--json` AND `state`; before the fix it saw `state` alone, as a 2nd positional.
GH_STUB_RC=0 "$FIVE" gh pr view 51 --repo lodar/5dive-frontend --json state >/dev/null 2>&1
chk "A argv reaches gh verbatim (space form)" \
  "pr view 51 --repo lodar/5dive-frontend --json state" "$(seen)"
# and the count, which is the assertion that actually mirrors gh's complaint:
# gh counts POSITIONALS, so the bug is visible as an argv one token short.
chk "A argv token count" "7" "$(tr -cd '\0' <"$GH_STUB_ARGV" | wc -c | tr -d ' ')"

# multi-field, and a second flag after it — the generalisation the wiki note made
GH_STUB_RC=0 "$FIVE" gh run view 123 --json headSha,conclusion --repo o/r >/dev/null 2>&1
chk "A multi-field list survives" "run view 123 --json headSha,conclusion --repo o/r" "$(seen)"

# --- ARM B: the equals form must not regress ---------------------------------
# It was the documented workaround (community/wiki/5dive-gh-json-flag-needs-equals-not-space.md),
# so every caller written in the last three days uses it. A fix that broke it
# would trade one outage for another.
GH_STUB_RC=0 "$FIVE" gh pr view 51 --json=state >/dev/null 2>&1
chk "B equals form still passes through" "pr view 51 --json=state" "$(seen)"

# --- ARM C: --json BEFORE the verb is still 5dive's --------------------------
# The flag's own contract is unchanged where it belongs. `5dive --json gh` must
# still emit a 5dive envelope and must NOT hand `--json` to gh.
out=$(GH_STUB_RC=3 "$FIVE" --json gh pr view 51 2>/dev/null)
chk "C pre-verb --json is consumed by 5dive" "pr view 51" "$(seen)"
chk "C pre-verb --json still turns on JSON_MODE" "false" "$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)"

# --- ARM D: no collateral on ordinary verbs ----------------------------------
# The stripper's original job — a trailing `--json` on a normal subcommand still
# sets JSON_MODE regardless of placement. If this fails, the fix was too wide.
chk "D ordinary verb still honours a trailing --json" "true" \
  "$("$FIVE" agent list --json 2>/dev/null | jq -r 'has("ok")' 2>/dev/null)"

# --- ARM E: gh's non-zero is GH's, not "a bug in the CLI" --------------------
# This is the half that made #526 (rc 1) and #553 (rc 4) look unrelated: the
# backstop overwrote gh's own message with a paragraph asserting the CLI broke.
err=$(GH_STUB_RC=4 "$FIVE" gh pr view 51 2>&1 >/dev/null); rc=$?
chk "E gh's exit status is passed through" "4" "$rc"
case "$err" in *"STUB-GH-STDERR"*) ok "E gh's own stderr survives" ;;
  *) bad "E gh's own stderr survives" "not in output: $err" ;; esac
case "$err" in *"This is a bug in the CLI"*)
    bad "E no false 'bug in the CLI' claim" "backstop still fired: $err" ;;
  *) ok "E no false 'bug in the CLI' claim" ;; esac
case "$err" in *"gh exited 4"*) ok "E the status is named as gh's" ;;
  *) bad "E the status is named as gh's" "no attribution line: $err" ;; esac
# and in JSON mode the class is the discriminator a reader can branch on
cls=$(GH_STUB_RC=1 "$FIVE" --json gh pr view 51 2>/dev/null | jq -r '.error.class' 2>/dev/null)
chk "E JSON class is 'passthrough'" "passthrough" "$cls"

# --- ARM F: DIVE-2792 survives -----------------------------------------------
# The backstop must still fire for a genuine INTERNAL failure. Graded on a verb
# that is not a passthrough, so a green here means the two cases remain
# distinguishable rather than that the backstop was disabled wholesale.
int=$(GH_STUB_RC=0 "$FIVE" gh --as=nonsense pr view 51 2>&1 >/dev/null)
case "$int" in *"--as must be auto, bot or caller"*) ok "F an internal refusal still reports itself" ;;
  *) bad "F an internal refusal still reports itself" "got: $int" ;; esac
case "$int" in *"class=read"*|*"actor="*)
    bad "F an internal refusal runs nothing" "banner printed before validation: $int" ;;
  *) ok "F an internal refusal runs nothing" ;; esac

# --- ARM G: do not name an identity that has not resolved --------------------
# quinn's seat held no gh credential and the banner said `actor=your own gh
# credential` anyway — an identity asserted before it was resolved (the DIVE-3128
# class). Both directions are graded: a resolved seat must NOT gain the warning.
noc=$(GH_STUB_TOKEN="" GH_STUB_RC=0 "$FIVE" gh pr view 51 2>&1 >/dev/null)
case "$noc" in *"NONE IS RESOLVED"*) ok "G credential-less seat is told so" ;;
  *) bad "G credential-less seat is told so" "banner asserted an identity: $noc" ;; esac
yes=$(GH_STUB_RC=0 "$FIVE" gh pr view 51 2>&1 >/dev/null)
case "$yes" in *"NONE IS RESOLVED"*)
    bad "G a resolved seat is NOT warned" "false warning on a seat with a token: $yes" ;;
  *) ok "G a resolved seat is NOT warned" ;; esac
case "$yes" in *"actor=your own gh credential"*) ok "G a resolved seat still names the actor" ;;
  *) bad "G a resolved seat still names the actor" "no actor line: $yes" ;; esac

# --- ARM H: the forms that always worked still do ----------------------------
# `whoami` and `--explain` are single-token and so were never hit by the
# stripper; the task names them as the negative arm. --explain must still run
# NOTHING, which is graded by the stub's argv file staying untouched.
: >"$GH_STUB_ARGV"
GH_STUB_RC=0 "$FIVE" gh --explain pr view 51 --json state >/dev/null 2>&1
chk "H --explain runs nothing" "" "$(seen)"
exp=$(GH_STUB_RC=0 "$FIVE" gh --explain pr view 51 --json state 2>&1 >/dev/null)
case "$exp" in *"class=read"*) ok "H --explain still prints the routing decision" ;;
  *) bad "H --explain still prints the routing decision" "got: $exp" ;; esac
"$FIVE" gh whoami >/dev/null 2>&1
chk "H whoami still exits 0" "0" "$?"

echo "-----"
printf 'gh_passthrough_argv_e2e: %d passed, %d failed\n' "$P" "$F"
[[ $F -eq 0 ]]
