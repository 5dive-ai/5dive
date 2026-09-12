#!/usr/bin/env bash
# DIVE-4334 — `5dive gh --as=reviewer`, the CODEOWNERS attester rail.
#
# WHAT IT EXISTS FOR: .github/CODEOWNERS requires a code-owner review on
# /install.sh and /src/cmd_selfupdate.sh. CODEOWNERS resolves USERS and TEAMS
# only, so the App identity can never be named there; and GitHub 422s a
# self-approval, so the owner cannot be 5dive-bot, which authors every installer
# PR. The owner is therefore a third login and this rail is the only thing on the
# box that can speak as it.
#
# WHAT IS TESTED HERE, and it is the whole of what DECIDES:
#   - the allowlist: `pr review` and `api user` in, everything else out
#   - --as=reviewer refuses a non-allowlisted call BEFORE any credential is read
#   - the root helper RE-DERIVES the allowlist rather than trusting the sentinel,
#     so typing --identity=reviewer by hand buys nothing the flag does not
#   - the sentinel is consumed and never reaches gh
#   - CODEOWNERS names a login that is neither the App nor the PR author
# The live token path (_gh_do reading a root-only connector, exec'ing real gh) is
# smoked on a box, not here — same boundary as gh_actor_routing_unit.sh.
# Run: bash tests/gh_reviewer_rail_unit.sh   (no root, no network, no gh needed)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_gh.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
JSON_MODE=0
set +e

PASS=0; FAIL=0; SKIP=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- 1. The allowlist is a set, so test members AND non-members. A predicate
# tested only on what it admits is untested in the direction that matters.
for shape in "pr review 880 --approve" "pr review 880 --body x" "api user" "api user --jq .login"; do
  # shellcheck disable=SC2086
  if _gh_reviewer_allowed $shape; then ok_t "allowlist ADMITS: $shape"
  else bad_t "allowlist admits: $shape" "refused"; fi
done
for shape in "pr merge 880 --squash" "pr create --title x" "api repos/5dive-ai/5dive" \
             "api -X PUT repos/5dive-ai/5dive/branches/main/protection" "release create v1" \
             "pr comment 880" "api user/repos" "review pr 880" "" ; do
  # shellcheck disable=SC2086
  if _gh_reviewer_allowed $shape; then bad_t "allowlist REFUSES: ${shape:-<empty>}" "admitted"
  else ok_t "allowlist REFUSES: ${shape:-<empty>}"; fi
done

# --- 2. The flag refuses before it reaches a credential. A refusal that happens
# after the token is read is a leak waiting for a bug.
out=$(cmd_gh --as=reviewer pr merge 880 --squash 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "serves 'pr review'" <<<"$out" \
  && ok_t "--as=reviewer refuses a non-allowlisted operation, by name" \
  || bad_t "--as=reviewer refuses a non-allowlisted operation" "rc=$rc out=${out}"
grep -q 'GH_REVIEWER_TOKEN' <<<"$out" \
  && bad_t "the refusal names no token value" "token key echoed into the refusal" \
  || ok_t "the refusal reaches the user without touching the credential"

# --- 3. --as= validation still names every accepted value, so a typo is a
# sentence and not a silent fall-through to the caller credential.
out=$(cmd_gh --as=revewer pr review 880 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'reviewer' <<<"$out" \
  && ok_t "--as= rejects a typo and lists reviewer among the valid values" \
  || bad_t "--as= rejects a typo" "rc=$rc out=${out}"

# --- 4. The root helper re-derives. This is the property that makes the leading
# sentinel safe to accept from a non-root parent at all.
grep -q '_gh_reviewer_allowed "${args\[@\]}"' "$SRC/cmd_gh.sh" \
  && ok_t "_gh_do re-derives the allowlist instead of trusting the sentinel" \
  || bad_t "_gh_do re-derives the allowlist" "no re-derivation in the root helper"
grep -q 'args=("${args\[@\]:1}")' "$SRC/cmd_gh.sh" \
  && ok_t "_gh_do CONSUMES the sentinel, so it cannot reach gh" \
  || bad_t "_gh_do consumes the sentinel" "sentinel is not stripped"

# --- 5. No new root entry point: the NOPASSWD grant names _gh_do exactly, and a
# second one would be a sudoers change on every box, not a CLI release.
[[ "$(grep -c 'sudo -n /usr/local/bin/5dive _gh_[a-z_]*' "$SRC/cmd_gh.sh")" -gt 0 ]] \
  && ! grep -qE 'sudo -n /usr/local/bin/5dive _gh_(?!do)' "$SRC/cmd_gh.sh" 2>/dev/null \
  && ! grep -E 'sudo -n /usr/local/bin/5dive _gh_[a-z_]+' "$SRC/cmd_gh.sh" | grep -qv '_gh_do' \
  && ok_t "the rail adds NO second root entry point (no sudoers change needed)" \
  || bad_t "the rail adds no second root entry point" "a _gh_* helper other than _gh_do is sudo'd"

# --- 6. The connector is named, and named ONCE, and is not the bot's.
grep -q '^readonly _GH_REVIEWER_ENV="/etc/5dive/connectors/github-reviewer.env"$' "$SRC/cmd_gh.sh" \
  && ok_t "the attester connector is a fixed path, not env-overridable" \
  || bad_t "the attester connector is a fixed path" "missing or overridable"
[[ "$_GH_REVIEWER_ENV" != "$_GH_BOT_ENV" ]] \
  && ok_t "the attester credential is NOT the machine account's" \
  || bad_t "the attester credential is not the machine account's" "same connector"

# --- 7. CODEOWNERS: the owner must be a plain @login (not an App, not a team
# that does not exist — the DIVE-2144 header's own warning) and must not be the
# author of every installer PR.
CO=.github/CODEOWNERS
owners=$(grep -E '^/(install\.sh|src/cmd_selfupdate\.sh)' "$CO" | grep -oE '@[A-Za-z0-9_.-]+' | sort -u)
[[ -n "$owners" ]] \
  && ok_t "CODEOWNERS still gates both installer paths" \
  || bad_t "CODEOWNERS still gates both installer paths" "no owner line found"
grep -q '5dive-bot' <<<"$owners" \
  && bad_t "the owner is not the PR author" "5dive-bot authors installer PRs; GitHub 422s a self-approval" \
  || ok_t "the owner is not 5dive-bot (GitHub refuses a self-approval)"
grep -qE '@5dive-ai/' <<<"$owners" \
  && bad_t "the owner is not a team" "no team exists in this org; a nonexistent team silently requests nobody" \
  || ok_t "the owner is a user, which is what CODEOWNERS can resolve"
[[ "$(wc -l <<<"$owners")" -eq 1 ]] \
  && ok_t "both installer paths carry the SAME single owner" \
  || bad_t "both installer paths carry the same single owner" "owners: $(tr '\n' ' ' <<<"$owners")"

echo "-----"
printf 'gh_reviewer_rail_unit: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
