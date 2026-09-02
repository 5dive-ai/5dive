#!/usr/bin/env bash
# TIER: core — pure function + stubbed-gh arms, no real network, no `task done` closes.
#
# DIVE-3888 — THE GATE'S OWN SEAT ALREADY HELD A TOKEN THAT COULD SEE THE REPO.
#
# `/usr/local/sbin/verifier-gh-read-token.sh` (cron, 30 min) mints one read-only App
# installation token PER INSTALLATION and writes them ALL to
# `~/.config/5dive/gh-read-tokens.env` as `GH_READ_TOKEN_<OWNER>`. `gh` reads one token
# per host, so only the 5dive-ai one lands in `hosts.yml` — and that is the only one
# `_gate_gh_token` arm 3 can see. The lodar token sat beside it, live and unused.
#
# MEASURED 2026-09-02 from agent-quinn's own uid, which is what makes this a fix and
# not a defence:
#   GH_READ_TOKEN_5DIVE_AI -> repos/lodar/5dive-api           : 404
#   GH_READ_TOKEN_LODAR    -> repos/lodar/5dive-api           : lodar/5dive-api
#   GH_READ_TOKEN_LODAR    -> pr view 140 --repo lodar/...    : state MERGED
#   GH_READ_TOKEN_LODAR    -> PATCH .../pulls/140             : 403 (the read-only control)
# End to end, same seat and same command, `task merge-gate-selftest --pr=<that PR>`:
# the installed build says "this seat CANNOT query GitHub"; the patched build reads MERGED.
#
# WHAT THESE ARMS PIN, and each maps to a way the arm could go wrong:
#   T1  the owner parse — only the two forms the gate emits, and empty for anything else,
#       because an unrecognised call must not be answered by a guess.
#   T2  the env lookup — the `5dive-ai` -> `5DIVE_AI` transform, absence, a bogus owner,
#       and that sourcing the file leaks NO name into the gate's own environment (a token
#       left in the ambient env would be picked up by arm 1 on a later call).
#   T3  it ANSWERS on the blind path — the whole point.
#   T4  NARROWNESS: a primary token that works never consults it (0 uses). This is the
#       DIVE-2605/2770 contract — the arm can only convert an unanswered query into an
#       answered one.
#   T5  owner MISMATCH: a token minted for another owner is never pointed at this repo.
#   T6  when the owner token also fails, the original non-zero status and empty stdout
#       survive, so the gate's fail-closed reading is untouched.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
export FIVE_GATE_NO_ANON=1
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-ownertok-unit.XXXXXX)"
mkdir -p "$TMP/bin"

# sudo always refuses: no bot rail, no borrowed token. That is the verifier seat.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
# curl always refuses: no anonymous rail either.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/curl"; chmod +x "$TMP/bin/curl"

# gh stub. It dispatches on the TOKEN it is handed, which is the property under test:
# GH_STUB_GOOD_TOKEN answers, anything else fails with the real blind stderr.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "token" ]]; then
  printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1; exit 0
fi
printf '%s\n' "${GH_TOKEN:-<none>}" >>"$TOK_LOG"
if [[ -n "${GH_STUB_GOOD_TOKEN:-}" && "${GH_TOKEN:-}" == "${GH_STUB_GOOD_TOKEN}" ]]; then
  printf '%s\n' "${GH_STUB_ANSWER:-MERGED}"; exit 0
fi
printf "GraphQL: Could not resolve to a Repository with the name 'lodar/5dive-api'. (repository)\n" >&2
exit 1
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export TOK_LOG="$TMP/tokens.log"; : >"$TOK_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
chk()   { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
sub()   { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "want substring [$3] in: $2"; fi; }
nsub()  { if [[ "$2" != *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "unwanted [$3] in: $2"; fi; }

PR='https://github.com/lodar/5dive-api/pull/140'

# A seat home carrying exactly what the minting script writes. HOME is pointed here so
# no arm can accidentally read the real seat's file (or fail because it has none).
export HOME="$TMP/home"
mkdir -p "$HOME/.config/5dive"
cat >"$HOME/.config/5dive/gh-read-tokens.env" <<ENV
GH_READ_TOKEN_MINTED_AT=2026-09-02T01:30:01Z
GH_READ_TOKEN_EXPIRES_AT=2026-09-02T02:30:01Z
GH_READ_TOKEN_5DIVE_AI=tok-5dive-ai
GH_READ_TOKEN_LODAR=tok-lodar
ENV
chmod 600 "$HOME/.config/5dive/gh-read-tokens.env"

# ---------------------------------------------------------------------------
# T1 — the owner parse. Two forms, and empty for everything else.
# ---------------------------------------------------------------------------
chk "T1 a full pull URL"            "$(_gate_owner_from_args pr view "$PR" --json state)" "lodar"
chk "T1 --repo=<slug>"              "$(_gate_owner_from_args pr view 140 --repo=lodar/5dive-api)" "lodar"
chk "T1 --repo <slug> (separated)"  "$(_gate_owner_from_args pr view 140 --repo lodar/5dive-api)" "lodar"
chk "T1 the other owner parses too" "$(_gate_owner_from_args pr view https://github.com/5dive-ai/5dive/pull/1)" "5dive-ai"
chk "T1 a call naming no repo is EMPTY, not a guess" "$(_gate_owner_from_args api rate_limit -q .rate.remaining)" ""
chk "T1 a bare number is not an owner" "$(_gate_owner_from_args pr view 140 --json state)" ""

# ---------------------------------------------------------------------------
# T2 — the env lookup, including the leak guard.
# ---------------------------------------------------------------------------
chk "T2 lodar resolves"                      "$(_gate_owner_read_token lodar)" "tok-lodar"
chk "T2 the dash/case transform (5dive-ai)"  "$(_gate_owner_read_token 5dive-ai)" "tok-5dive-ai"
_gate_owner_read_token nosuchowner >/dev/null 2>&1
chk "T2 an owner with no minted token fails" "$?" "1"
_gate_owner_read_token 'lodar; rm -rf /' >/dev/null 2>&1
chk "T2 an owner that is not a name is refused" "$?" "1"
chk "T2 sourcing leaks NO token into the gate's own env" "${GH_READ_TOKEN_LODAR:-unset}" "unset"
( export HOME="$TMP/nohome"; _gate_owner_read_token lodar >/dev/null 2>&1 )
chk "T2 a seat with no tokens file simply fails"  "$?" "1"

# ---------------------------------------------------------------------------
# T3 — IT ANSWERS ON THE BLIND PATH. The caller's own token is live and blind; the
# owner token is the only thing that can see the repo, and the gate finds it.
# ---------------------------------------------------------------------------
export GH_STUB_GOOD_TOKEN=tok-lodar GH_STUB_ANSWER=MERGED
: >"$TOK_LOG"
OUT=$(_gate_gh "ghs_blind" 0 pr view "$PR" --json state,mergedAt -q '.state'); RC=$?
chk "T3 a blind caller token still gets an answer" "$RC" "0"
chk "T3 and the answer is the real state"          "$OUT" "MERGED"
sub "T3 the blind token WAS tried first"           "$(cat "$TOK_LOG")" "ghs_blind"
sub "T3 then the owner-scoped read token"          "$(cat "$TOK_LOG")" "tok-lodar"
chk "T3 exactly two calls — no rail is asked twice" "$(wc -l <"$TOK_LOG")" "2"

# ---------------------------------------------------------------------------
# T4 — NARROWNESS. A working primary token never reaches this arm.
# ---------------------------------------------------------------------------
export GH_STUB_GOOD_TOKEN=ghs_works
: >"$TOK_LOG"
OUT=$(_gate_gh "ghs_works" 0 pr view "$PR" --json state,mergedAt -q '.state'); RC=$?
chk "T4 a working token answers as before"        "$RC" "0"
chk "T4 and it is the answer that comes back"     "$OUT" "MERGED"
nsub "T4 the owner read token was NEVER consulted" "$(cat "$TOK_LOG")" "tok-lodar"
chk "T4 exactly one call — nothing extra is spent" "$(wc -l <"$TOK_LOG")" "1"

# ---------------------------------------------------------------------------
# T5 — SELECTION IS BY THE OWNER THE QUERY NAMES, never "any token in the file".
#
# Set up so the two readings DISAGREE: the query is a 5dive-ai PR, and the only token
# the stub will answer for is the LODAR one. Correct behaviour picks tok-5dive-ai,
# gets nothing, and never sends tok-lodar. A shortcut that grabs whichever token is
# present would answer here — which is a token pointed at a repo it was not minted
# for, and the arm's whole safety argument is that this cannot happen.
# ---------------------------------------------------------------------------
OTHER_PR='https://github.com/5dive-ai/5dive/pull/1'
export GH_STUB_GOOD_TOKEN=tok-lodar
: >"$TOK_LOG"
OUT=$(_gate_gh "ghs_blind" 0 pr view "$OTHER_PR" --json state,mergedAt -q '.state'); RC=$?
chk "T5 the other owner's token does not answer this repo" "$((RC != 0))" "1"
chk "T5 and no state is invented"                  "$OUT" ""
nsub "T5 a token minted for a DIFFERENT owner was never sent" "$(cat "$TOK_LOG")" "tok-lodar"
sub "T5 the owner named by the query is the one tried" "$(cat "$TOK_LOG")" "tok-5dive-ai"

# ---------------------------------------------------------------------------
# T6 — WHEN NOTHING ANSWERS, the pre-existing fail-closed state is byte-identical:
# original non-zero status, empty stdout, and a reason that names what was tried.
# ---------------------------------------------------------------------------
unset GH_STUB_GOOD_TOKEN
: >"$TOK_LOG"
# NOT a command substitution: `_gate_gh` sets `_GATE_GH_LAST_ERR` in the shell it runs
# in, and a subshell cannot hand it back — the same trap DIVE-3496 iteration 2 hit and
# solved with a sink file. Redirect to a file and stay in this shell instead.
_gate_gh "ghs_blind" 0 pr view "$PR" --json state,mergedAt -q '.state' >"$TMP/t6.out" 2>/dev/null
RC=$?; OUT="$(cat "$TMP/t6.out")"
chk "T6 an unanswerable query still fails"     "$((RC != 0))" "1"
chk "T6 and returns empty, not a verdict"      "$OUT" ""
sub "T6 the reason names the blind credential" "$_GATE_GH_LAST_ERR" "cannot see this repository"
sub "T6 and names the owner arm it tried"      "$_GATE_GH_LAST_ERR" "owner-scoped read token"

printf '\n%s\n' "---- $PASS passed, $FAIL failed ----"
[[ $FAIL -eq 0 ]]
