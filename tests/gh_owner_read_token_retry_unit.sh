#!/usr/bin/env bash
# DIVE-4494 — `5dive gh` IS NOT OWNER-AWARE, AND THE GRADER POOL READS THROUGH IT.
#
# THE MEASUREMENT (2026-09-14, /var/log/5dive-grader.log 05:45–05:50Z). DIVE-4417's
# parallel grader lane probes a candidate seat with
# `sudo -n -u agent-<seat> 5dive gh pr view <delivery_ref> --json state`. Every
# lodar/* delivery — app, api, blog, mobile, i.e. most of what we ship — came back
#     queue DIVE-4489 (… has headroom but cannot read the delivery ref)
#     queue DIVE-4481 (… has headroom but cannot read the delivery ref)
# while the SAME TICK spawned DIVE-4482 (5dive-ai/5dive) as a one-shot. The lane
# worked; the READ did not.
#
# THE CAUSE IS NOT A MISSING CREDENTIAL. `gh` holds ONE token per host, `hosts.yml`
# carries the 5dive-ai installation's, and root mints a read-only token for EVERY
# installation into `~/.config/5dive/gh-read-tokens.env` (`GH_READ_TOKEN_<OWNER>`).
# DIVE-3888 taught the MERGE GATE to open that file; `cmd_gh` never learned. Two
# rails, one blind — and the one the grader pool reads through is the blind one.
#
# WHAT THIS FILE GRADES. That `5dive gh` now escalates a READ that failed blind to
# the seat's own owner-scoped read token, and — the half that matters more — that it
# escalates NOTHING ELSE. Every anchor below is there so no arm is satisfiable by
# deleting a guard: a call that ANSWERS never retries (T3), a NON-blind failure never
# retries (T6), a WRITE and an ADMIN call are never offered the read token (T7/T8),
# an argv naming no owner is never guessed at (T9), and a seat with no tokens file
# gets back the ORIGINAL status and the ORIGINAL stderr byte for byte (T4/T5).
#
# ISOLATION. `_gate_read_tokens_file` has a second arm that walks getent/passwd to
# the CALLING account's real home BY DESIGN — a `HOME` pin does not isolate it, which
# is what quinn's DIVE-3888 iteration-1 reject was about (29/0 on dev, 28/1 on quinn
# at the same sha). So tests/lib/isolate_read_tokens.sh is installed and PROVEN with
# a positive control (T0/T0i) before any "this seat holds nothing" arm runs.
#
# Run: bash tests/gh_owner_read_token_retry_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gh-owner-read-retry.XXXXXX)"
mkdir -p "$TMP/bin" "$TMP/home/.config/5dive"
export TMPDIR="$TMP"

LODAR_TOK="tok-lodar-4494"
AI_TOK="tok-5dive-ai-4494"

# --- stub gh. It models the ONE fact this row is about: a token is LIVE and BLIND
# against a repo whose installation it was not minted for. `GH_TOKEN` is what the
# retry sets, so the stub keys on it and logs it — that is how the arms below tell
# "the retry ran" from "the first call ran twice".
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "token" ]]; then
  printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"
  [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1
  exit 0
fi
printf 'CALL token=[%s] args=[%s]\n' "${GH_TOKEN:-}" "$*" >>"${GH_ARGS_LOG:-/dev/null}"
owner=""; prev=""
for a in "$@"; do
  case "$a" in
    https://github.com/*/*|http://github.com/*/*) x="${a#*github.com/}"; owner="${x%%/*}" ;;
    --repo=*) x="${a#--repo=}"; owner="${x%%/*}" ;;
  esac
  [[ "$prev" == "--repo" && "$a" == */* ]] && owner="${a%%/*}"
  prev="$a"
done
# A failure that is NOT "cannot see this repository" — the discriminator T6 needs.
if [[ -n "${GH_STUB_HARD_FAIL:-}" ]]; then printf '%s\n' "$GH_STUB_HARD_FAIL" >&2; exit 1; fi
tok="${GH_TOKEN:-${GH_STUB_AUTH_TOKEN:-}}"
if [[ -n "$owner" ]]; then
  want="GH_STUB_SEES_$(printf '%s' "$owner" | tr 'a-z-' 'A-Z_')"
  if [[ "$tok" != "${!want:-__nothing_sees_this__}" ]]; then
    # The blind message NAMES ITS RAIL. Without that the primary call's stderr and
    # the retry's are byte-identical, and "the original stderr survived the capture"
    # (T12c) is satisfied by the retry's own message — an arm that cannot fail.
    if [[ -n "${GH_TOKEN:-}" ]]; then rail="RETRY-RAIL"; else rail="PRIMARY-RAIL"; fi
    printf "GraphQL: Could not resolve to a Repository with the name '%s/x'. (%s)\n" "$owner" "$rail" >&2
    exit 1
  fi
fi
printf '%s\n' "${GH_STUB_STATE:-MERGED}"
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"
export GH_STUB_SEES_LODAR="$LODAR_TOK"
export GH_STUB_SEES_5DIVE_AI="$AI_TOK"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/gh_config.sh lib/state.sh lib/actor.sh task/gate_evidence.sh cmd_gh.sh; do
  source "$SRC/$f"
done
JSON_MODE=0
# src/header.sh turns on `set -e`; the arms below deliberately run calls that FAIL.
set +e
. tests/lib/isolate_read_tokens.sh
isolate_read_tokens "$TMP/bin"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
chk()   { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "want=[$3] got=[$2]"; }

TOKENS="$TMP/home/.config/5dive/gh-read-tokens.env"
write_tokens() { printf '%s\n' "$@" >"$TOKENS"; }
no_tokens()    { rm -f "$TOKENS"; }

export HOME="$TMP/home"
# The caller's OWN credential, in the shape the fleet actually has it: `hosts.yml`
# carries the 5dive-ai installation token, so the caller SEES 5dive-ai/* and is live
# but BLIND against lodar/*. Resolvable, so the route stays on the caller and never
# takes the DIVE-2296 credential-less diversion to the bot.
export GH_STUB_AUTH_TOKEN="$AI_TOK"

run_gh() { : >"$GH_ARGS_LOG"; OUT=$(cmd_gh "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }
calls()  { grep -c '^CALL ' "$GH_ARGS_LOG" 2>/dev/null || printf 0; }

# ── T0 — the isolation, PROVEN, before anything depends on it ───────────────────
chk "T0 the sandbox HOME is the only tokens file that can resolve" \
    "$(read_tokens_isolated_probe)" ""
chk "T0i and OUR getent is the one on PATH (positive control, not an absence)" \
    "$(read_tokens_stub_control)" "STUBBED"

# ── T1/T2 — the row itself ─────────────────────────────────────────────────────
write_tokens "GH_READ_TOKEN_5DIVE_AI=$AI_TOK" "GH_READ_TOKEN_LODAR=$LODAR_TOK"
run_gh pr view https://github.com/lodar/5dive-frontend/pull/264 --json state -q .state
chk "T1 a lodar/* read that the caller's credential cannot see now ANSWERS" "$OUT" "MERGED"
chk "T1b and exits 0, which is what the grader read probe keys on"          "$RC"  "0"
[[ "$ERR" == *"read-only token for 'lodar'"* && "$ERR" == *"GH_READ_TOKEN_LODAR"* ]] \
  && ok_t "T1c and SAYS which rail answered, by variable name" \
  || bad_t "T1c retry note" "err=$ERR"
grep -q "CALL token=\[$LODAR_TOK\]" "$GH_ARGS_LOG" \
  && ok_t "T2 the retry really used the OWNER-scoped token, not the caller's" \
  || bad_t "T2 retry token" "log=$(cat "$GH_ARGS_LOG")"
chk "T2b exactly two gh calls: the blind one, then the retry" "$(calls)" "2"

run_gh pr view 264 --repo lodar/5dive-frontend --json state -q .state
chk "T2c the --repo form resolves the owner too (both forms the probe emits)" "$OUT" "MERGED"

# ── T3 — ANCHOR: a call that ANSWERS never escalates ───────────────────────────
run_gh pr view 962 --repo 5dive-ai/5dive --json state -q .state
chk "T3 ANCHOR a read the caller CAN make still answers on the caller's own token" "$OUT" "MERGED"
chk "T3b ANCHOR and spends exactly ONE request — no green call changes path"       "$(calls)" "1"
[[ "$ERR" != *"read-only token"* ]] \
  && ok_t "T3c ANCHOR and says nothing about an escalation that did not happen" \
  || bad_t "T3c spurious note" "err=$ERR"

# ── T4/T5 — FAIL CLOSED. The old behaviour, byte for byte. ─────────────────────
no_tokens
run_gh pr view https://github.com/lodar/5dive-frontend/pull/264 --json state -q .state
chk "T4 with NO tokens file the call fails exactly as before"         "$RC" "1"
chk "T4b and spends one request (no blind second attempt)"            "$(calls)" "1"
[[ "$ERR" == *"Could not resolve to a Repository"* && "$ERR" != *"read-only token"* ]] \
  && ok_t "T4c and gh's ORIGINAL stderr is what the caller reads" \
  || bad_t "T4c original stderr must survive" "err=$ERR"

write_tokens "GH_READ_TOKEN_5DIVE_AI=$AI_TOK"
run_gh pr view https://github.com/lodar/5dive-frontend/pull/264 --json state -q .state
chk "T5 a tokens file with no entry for THIS owner also fails closed"  "$RC" "1"
chk "T5b and does not retry with some other owner's token"             "$(calls)" "1"

# ── T6 — a NON-blind failure is not an escalation trigger ──────────────────────
write_tokens "GH_READ_TOKEN_LODAR=$LODAR_TOK"
GH_STUB_HARD_FAIL="GraphQL: Could not resolve to a PullRequest with the number 999." \
  run_gh pr view https://github.com/lodar/5dive-frontend/pull/999 --json state -q .state
chk "T6 a credential that CAN see the repo but not the PR is not retried" "$(calls)" "1"
chk "T6b and the failure is passed through"                              "$RC" "1"

# ── T7/T8/T9 — the read token is offered to reads, and to nothing else ─────────
_gh_owner_read_token write pr create --repo lodar/5dive-frontend \
  && bad_t "T7 ANCHOR a WRITE must never be offered the read-only token" "resolved one" \
  || ok_t  "T7 ANCHOR a WRITE is never offered the read-only token"
# The argv here NAMES the owner with `--repo`, so this arm fails for the reason it
# claims: without the read-class guard the resolver WOULD hand an admin-class call a
# token. An `api /repos/<owner>/...` path would have passed vacuously — the owner
# resolver reads `--repo` and github.com URLs only, so it declines that shape anyway.
_gh_owner_read_token admin secret list --repo lodar/5dive-frontend \
  && bad_t "T8 ANCHOR an ADMIN-class call must never be offered it" "resolved one" \
  || ok_t  "T8 ANCHOR an ADMIN-class call is never offered it"
_gh_owner_read_token read pr view 264 \
  && bad_t "T9 an argv naming no owner must resolve nothing" "resolved one" \
  || ok_t  "T9 an argv naming no owner resolves nothing — an unrecognised call is not guessed at"
_gh_owner_read_token read pr view --repo lodar/5dive-frontend \
  && ok_t  "T9b ANCHOR and the resolver is not vacuous: a named owner DOES resolve" \
  || bad_t "T9b resolver must not be vacuous" "resolved nothing with --repo lodar/..."

# ── T12 — the retry RAN and could not answer either ────────────────────────────
# The only path that captures gh's stderr instead of streaming it. If the escalation
# fails, the caller must end up exactly where they started: the ORIGINAL status and
# the ORIGINAL message. A swallowed stderr here is the worst outcome of the change —
# a read that fails silently reads as "nothing to see" rather than "I could not see".
write_tokens "GH_READ_TOKEN_LODAR=tok-lodar-stale"
run_gh pr view https://github.com/lodar/5dive-frontend/pull/264 --json state -q .state
chk "T12 a stale owner token IS tried"                       "$(calls)" "2"
chk "T12b and its failure returns the ORIGINAL status"       "$RC" "1"
[[ "$ERR" == *"PRIMARY-RAIL"* ]] \
  && ok_t "T12c and gh's ORIGINAL stderr still reaches the caller (never swallowed)" \
  || bad_t "T12c original stderr swallowed by the capture" "err=$ERR"
[[ "$ERR" == *"could not answer either"* ]] \
  && ok_t "T12d and the caller is told the second rail was tried and failed" \
  || bad_t "T12d must name the failed escalation" "err=$ERR"
write_tokens "GH_READ_TOKEN_5DIVE_AI=$AI_TOK" "GH_READ_TOKEN_LODAR=$LODAR_TOK"

# ── T10 — credential posture ───────────────────────────────────────────────────
run_gh pr view https://github.com/lodar/5dive-frontend/pull/264 --json state -q .state
[[ "$ERR" != *"$LODAR_TOK"* && "$OUT" != *"$LODAR_TOK"* ]] \
  && ok_t "T10 the token itself is never printed — only the variable that holds it" \
  || bad_t "T10 token leak" "err=$ERR out=$OUT"
chk "T10b and it does not leak into the caller's own environment" "${GH_READ_TOKEN_LODAR:-unset}" "unset"

# ── T11 — no pointless second request ─────────────────────────────────────────
# The live shape of this: `hosts.yml` carries the 5dive-ai installation token and the
# tokens file carries the SAME one as GH_READ_TOKEN_5DIVE_AI. When a 5dive-ai read
# comes back blind (a repo outside the installation, a genuine 404), the "owner
# token" is byte-identical to the one that just failed — retrying with it is a second
# request that cannot answer, and a note claiming another rail answered would be false.
write_tokens "GH_READ_TOKEN_5DIVE_AI=$AI_TOK" "GH_READ_TOKEN_LODAR=$LODAR_TOK"
GH_STUB_SEES_5DIVE_AI="" run_gh pr view --repo 5dive-ai/ghost --json state -q .state
chk "T11 when the owner token IS the credential that just failed, nothing is retried" "$(calls)" "1"
chk "T11b and the original failure is what the caller gets"                            "$RC" "1"

printf -- '-----\n%s: %s passed, %s failed\n' "$(basename "$0" .sh)" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
