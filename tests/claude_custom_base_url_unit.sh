#!/usr/bin/env bash
# DIVE-2757: `agent create --base-url=<url>` — point a claude-type agent at an
# Anthropic-compatible endpoint that is NOT in the CLAUDE_PROVIDER_BASEURL
# catalog (self-hosted open weights, a vendor host we ship no row for).
#
# Grades three things the feature is worthless without:
#   1. valid_base_url's scheme policy — https anywhere, http ONLY on loopback,
#      and no character that could forge a second line in combined.env.
#   2. _apply_byo_claude writes the OPERATOR's url and pins all THREE tiers,
#      including HAIKU. Haiku is the one that fails silently: it is background
#      traffic, not the tier anyone selects, so an unset value looks fine
#      interactively and 404s later.
#   3. A custom provider with no --model is REFUSED, not defaulted.
#
# No root, network, credentials, users, or runtime state are touched.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -f "${capture:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/lib/error_codes.sh   # E_USAGE / E_VALIDATION — without these every
                                # `fail "$E_..."` dies on `set -u` FIRST, and a
                                # refusal arm then "passes" on an unbound
                                # variable instead of on the guard it grades.
# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/lib/agent_setup.sh
# shellcheck disable=SC1091
source src/cmd_agent_create.sh

capture=$(mktemp)
step() { :; }
warn() { :; }
profile_set_var() {
  local profile="$1" var="$2" value
  value=$(cat)
  printf 'PROFILE %s %s=%s\n' "$profile" "$var" "$value" >>"$capture"
}
# fail() is the CLI's exit path and it EXITS — a stub that merely `return 1`s
# would let the function run on past its own refusal and write the profile
# anyway, so the harness would grade a code path production never takes. Keep
# the exit and run each refusal arm in a SUBSHELL instead.
fail() { printf 'FAIL[%s] %s\n' "$1" "$2" >&2; exit "$1"; }

fails=0 rc=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }

# --- 1. valid_base_url ------------------------------------------------------
echo "valid_base_url: scheme + shape policy"
for u in \
  "https://llm.example.com/anthropic" \
  "https://llm.example.com:8443/v1/anthropic" \
  "http://localhost:8000" \
  "http://127.0.0.1:8000/anthropic" \
  "http://[::1]:8000/anthropic" \
; do
  if valid_base_url "$u"; then ok "accepts $u"; else bad "rejected valid url: $u"; fi
done

# Rejections. Each is a distinct failure mode, not five spellings of one.
#  - plaintext to an OFF-BOX host puts the API key on the wire
#  - a private-LAN address is off-box too: "the LAN is trusted" is the wrong
#    assumption, and it is the one an exemption here would bake in
#  - a newline forges a second variable in the systemd EnvironmentFile
#  - a space/quote changes how systemd parses the line
#  - a non-http scheme is not an endpoint this harness can speak to
for u in \
  "http://llm.example.com/anthropic" \
  "http://192.0.2.10:8000" \
  "https://llm.example.com/a
FOO=bar" \
  "https://llm.example.com /anthropic" \
  "https://llm.example.com/\"x" \
  "ftp://llm.example.com" \
  "llm.example.com/anthropic" \
  "" \
; do
  if valid_base_url "$u"; then bad "accepted INVALID url: $(printf '%q' "$u")"
  else ok "rejects $(printf '%q' "$u")"; fi
done

# --- 2. the operator's url and all three tiers reach the profile ------------
echo "_apply_byo_claude: custom endpoint wins and pins every tier"
: >"$capture"
_apply_byo_claude custom sk-selfhost-123456 qa-prof qwen3.8-max "https://llm.example.com/anthropic"
assert_line() {
  if grep -qxF "$1" "$capture"; then ok "$1"; else bad "missing: $1"; fi
}
assert_line 'PROFILE qa-prof ANTHROPIC_BASE_URL=https://llm.example.com/anthropic'
assert_line 'PROFILE qa-prof ANTHROPIC_AUTH_TOKEN=sk-selfhost-123456'
assert_line 'PROFILE qa-prof ANTHROPIC_DEFAULT_OPUS_MODEL=qwen3.8-max'
assert_line 'PROFILE qa-prof ANTHROPIC_DEFAULT_SONNET_MODEL=qwen3.8-max'
# The one that would have been empty: no catalog row means no haiku default.
assert_line 'PROFILE qa-prof ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3.8-max'
# The shared-account neutralisers still fire on this path.
assert_line 'PROFILE qa-prof CLAUDE_CODE_OAUTH_TOKEN='
assert_line 'PROFILE qa-prof ANTHROPIC_API_KEY='

# --- 2b. a KNOWN vendor redirected to another host keeps its catalog models --
# Redirecting z.ai to a different host changes WHERE the models are served, not
# WHICH models exist, so the catalog's per-tier ids must survive the override.
echo "_apply_byo_claude: known vendor + --base-url keeps catalog model ids"
: >"$capture"
_apply_byo_claude zai sk-zai-123456 qa-prof2 "" "https://open.bigmodel.cn/api/anthropic"
assert_line 'PROFILE qa-prof2 ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic'
assert_line "PROFILE qa-prof2 ANTHROPIC_DEFAULT_OPUS_MODEL=${CLAUDE_PROVIDER_OPUS_MODEL[zai]}"
assert_line "PROFILE qa-prof2 ANTHROPIC_DEFAULT_HAIKU_MODEL=${CLAUDE_PROVIDER_HAIKU_MODEL[zai]}"

# --- 3. refusals ------------------------------------------------------------
echo "_apply_byo_claude: refusals"
: >"$capture"
rc=0; ( _apply_byo_claude custom sk-selfhost-123456 qa-prof "" "https://llm.example.com/anthropic" ) 2>/dev/null || rc=$?
# The CODE, not merely non-zero: an unbound variable also exits non-zero, and
# that is exactly how this arm first passed while grading nothing.
if (( rc == E_USAGE )); then ok "custom provider with no --model is refused (exit $rc)"
else bad "expected exit $E_USAGE for missing --model, got $rc"; fi
# Positive control for the assertion above: the same call WITH a model passes,
# so the refusal is attributable to the missing model and not to the arm being
# broken in some other way.
: >"$capture"
if ( _apply_byo_claude custom sk-selfhost-123456 qa-prof m1 "https://llm.example.com/anthropic" ) 2>/dev/null; then
  ok "positive control: same call with --model succeeds"
else
  bad "positive control FAILED — the no-model refusal above proves nothing"
fi

: >"$capture"
rc=0; ( _apply_byo_claude custom sk-selfhost-123456 qa-prof m1 "http://llm.example.com" ) 2>/dev/null || rc=$?
if (( rc == E_VALIDATION )); then ok "off-box http:// endpoint is refused (exit $rc)"
else bad "expected exit $E_VALIDATION for off-box http://, got $rc"; fi

# apply_byo_provider gates --base-url to claude only.
rc=0; ( apply_byo_provider hermes custom sk-test-123456 qa-prof m1 "https://x.example.com" ) 2>/dev/null || rc=$?
if (( rc == E_VALIDATION )); then ok "--base-url is refused for non-claude types (exit $rc)"
else bad "expected exit $E_VALIDATION for --base-url on hermes, got $rc"; fi

# --- 4. the custom id is NOT a vendor --------------------------------------
# It must stay out of BYO_PROVIDER_LABEL, or every picker that enumerates that
# table offers a vendor with no endpoint behind it.
if valid_byo_provider "$CLAUDE_CUSTOM_PROVIDER_ID"; then
  bad "CLAUDE_CUSTOM_PROVIDER_ID leaked into BYO_PROVIDER_LABEL"
else
  ok "custom id is a label, not a catalog vendor"
fi

# --- 5. THE ACCEPT PATH (DIVE-2757 iteration 2, olivia's reject) -------------
# Every arm above this line is a REFUSAL. 11 refusals / 0 creates means the YES
# path was unexercised, and the YES path is where this feature actually writes:
# six assignments into a systemd EnvironmentFile that the agent reads at boot.
# A malformed file there does not refuse — the agent comes up and fails later,
# which is the exact failure this row pins haiku to prevent.
#
# Driven through the REAL profile_set_var (src/cmd_auth.sh), not a re-typed
# copy, so the arm grades the writer that ships.
. ./src/cmd_auth.sh
_ap_root=$(mktemp -d); export FIVE_STATE_DIR="$_ap_root"
_ap_dir="$_ap_root/profiles/acceptarm"; mkdir -p "$_ap_dir"
_ap_env="$_ap_dir/combined.env"; : > "$_ap_env"
# minimal stand-in for the writer's contract: replace any prior VAR= line, append.
# Drive the REAL profile_set_var from src/cmd_auth.sh — a re-typed copy would
# grade the copy, and a copy of a writer is exactly what drifts away from the
# guard it is supposed to be testing. Only the root-owned side effects are stubbed.
ensure_profile_dir() { printf '%s' "$_ap_dir"; }
chown() { :; }; chmod() { :; }
_ap_set() { profile_set_var acceptarm "$1"; }

_AP_URL="https://weights.example.com/v1"
_AP_MODEL="qwen3.8-max"
printf '%s' "$_AP_URL"   | _ap_set ANTHROPIC_BASE_URL
printf '%s' "sk-test"    | _ap_set ANTHROPIC_AUTH_TOKEN
printf '%s' "$_AP_MODEL" | _ap_set ANTHROPIC_DEFAULT_OPUS_MODEL
printf '%s' "$_AP_MODEL" | _ap_set ANTHROPIC_DEFAULT_SONNET_MODEL
printf '%s' "$_AP_MODEL" | _ap_set ANTHROPIC_DEFAULT_HAIKU_MODEL
printf '%s' "3000000"    | _ap_set API_TIMEOUT_MS

# 5a. ALL THREE TIERS PINNED. haiku is the one that fails silently — it is never
# the tier an operator selects, it is what background turns reach for.
_ap_missing=""
for _t in OPUS SONNET HAIKU; do
  grep -q "^ANTHROPIC_DEFAULT_${_t}_MODEL=${_AP_MODEL}$" "$_ap_env" || _ap_missing="$_ap_missing $_t"
done
if [[ -z "$_ap_missing" ]]; then ok "accept path pins all three model tiers"
else bad "accept path left tier(s) unpinned:$_ap_missing"; fi

# 5b. WELL-FORMED: every line is exactly one KEY=VALUE, no blanks, no strays.
_ap_bad=$(grep -cvE '^[A-Z_][A-Z0-9_]*=' "$_ap_env" || true)
if [[ "$_ap_bad" == "0" ]]; then ok "EnvironmentFile is well-formed (every line one KEY=VALUE)"
else bad "EnvironmentFile has $_ap_bad malformed line(s)"; fi

# 5c. NEWLINE FORGERY IS AN ACCEPT-PATH PROPERTY. The refusal arms shape-check
# the URL; this checks what happens if one gets through — a value carrying a
# newline must not become a SECOND assignment the agent would honour.
_ap_before=$(cat "$_ap_env")
if ( printf '%s' "https://evil.example.com/v1
ANTHROPIC_AUTH_TOKEN=stolen" | _ap_set ANTHROPIC_BASE_URL ) >/dev/null 2>&1; then
  bad "newline value was ACCEPTED by profile_set_var (it must refuse)"
else
  if [[ "$(cat "$_ap_env")" == "$_ap_before" ]]; then
    ok "a newline value is REFUSED and the EnvironmentFile is left untouched"
  else
    bad "profile_set_var refused but still modified the file"
  fi
fi
# positive control: the same writer still accepts an ordinary single-line value,
# so the arm above grades the newline and not a writer that refuses everything.
if printf '%s' "https://ok.example.com/v1" | _ap_set ANTHROPIC_BASE_URL 2>/dev/null \
   && grep -q '^ANTHROPIC_BASE_URL=https://ok.example.com/v1$' "$_ap_env"; then
  ok "positive control: an ordinary single-line value still writes"
else
  bad "positive control failed — the writer refuses valid values too"
fi
rm -rf "$_ap_root"


# ============================================================================
# DIVE-2809 — the same endpoint, one command later.
#
# Folded into this file rather than shipped as its own harness because it is the
# same subject (a claude BYO endpoint that is NOT in the catalog) and the core
# tier is at its cap: a separate file pays a second bash start and a second
# source of six libraries to re-reach the state arm 5 already builds. Merging by
# subject is the budget runner's own first remedy and it drops no assertion.
#
# `agent auth set claude --provider=<vendor> --auth-profile=<p>` re-derived
# ANTHROPIC_BASE_URL from CLAUDE_PROVIDER_BASEURL and wrote the catalog's url
# over the one --base-url pinned above. The agent did not break afterwards —
# that is the defect. The value is a real vendor URL, so nothing downstream
# looks wrong while a self-hosted agent resumes sending its traffic AND ITS KEY
# to a vendor the operator deliberately moved off.
#
# Everything below drives the REAL writer against a REAL EnvironmentFile in a
# mktemp dir and reads it off disk before and after; only root-owned side
# effects are stubbed.
# ============================================================================
root=$(mktemp -d)
AUTH_PROFILES_DIR="$root/auth-profiles"

# Root-owned side effects only. profile_set_var itself is the shipped writer.
step() { :; }
warn() { :; }
require_root() { :; }
chown() { :; }
chmod() { :; }
ensure_profile_dir() { local d="$AUTH_PROFILES_DIR/$1"; mkdir -p "$d"; : >>"$d/combined.env"; printf '%s' "$d"; }
# fail() EXITS in production; a stub that merely returns would let a refused
# call run on and write the profile anyway. Keep the exit, run refusals in a
# SUBSHELL.
fail() { printf 'FAIL[%s] %s\n' "$1" "$2" >&2; exit "$1"; }

CUSTOM_URL="https://weights.example.com/v1"
ZAI_URL="${CLAUDE_PROVIDER_BASEURL[zai]}"

# Stand up the profile the way `agent create --base-url=<custom> --model=<slug>`
# leaves it: a custom endpoint plus all three pinned tiers.
seed_custom_profile() {
  local p="$1" url="${2:-$CUSTOM_URL}"
  rm -rf "${AUTH_PROFILES_DIR:?}/$p"
  ensure_profile_dir "$p" >/dev/null
  printf '%s' "$url"           | profile_set_var "$p" ANTHROPIC_BASE_URL
  printf '%s' "sk-selfhost-12" | profile_set_var "$p" ANTHROPIC_AUTH_TOKEN
  printf '%s' "qwen3.8-max"    | profile_set_var "$p" ANTHROPIC_DEFAULT_OPUS_MODEL
  printf '%s' "qwen3.8-max"    | profile_set_var "$p" ANTHROPIC_DEFAULT_SONNET_MODEL
  printf '%s' "qwen3.8-max"    | profile_set_var "$p" ANTHROPIC_DEFAULT_HAIKU_MODEL
}
env_of() { printf '%s' "$AUTH_PROFILES_DIR/$1/combined.env"; }
url_in()  { grep -E '^ANTHROPIC_BASE_URL=' "$(env_of "$1")" | tail -1 | cut -d= -f2-; }

# --- 1. the silent revert is refused, and the file is untouched -------------
echo "auth set on a custom-endpoint profile: refuse, do not revert"
seed_custom_profile p1
before=$(cat "$(env_of p1)")
before_sum=$(sha256sum < "$(env_of p1)")
rc=0
( _apply_byo_claude zai sk-zai-rotate-12 p1 "" "" ) >/dev/null 2>&1 || rc=$?
if (( rc == E_VALIDATION )); then ok "catalog re-derivation over a custom endpoint is refused (exit $rc)"
else bad "expected exit $E_VALIDATION, got $rc — the custom endpoint was reverted"; fi
after_sum=$(sha256sum < "$(env_of p1)")
if [[ "$before_sum" == "$after_sum" ]]; then ok "EnvironmentFile is byte-identical after the refusal"
else bad "EnvironmentFile CHANGED across a refusal:"$'\n'"--- before ---"$'\n'"$before"$'\n'"--- after ---"$'\n'"$(cat "$(env_of p1)")"; fi
# The refusal has to NAME the endpoint it is protecting and the flag that
# resolves it, or the operator is told "no" with nowhere to go.
msg=$( ( _apply_byo_claude zai sk-zai-rotate-12 p1 "" "" ) 2>&1 || true )
for want in "$CUSTOM_URL" "--base-url" "p1"; do
  case "$msg" in *"$want"*) ok "refusal names: $want" ;;
                 *) bad "refusal does not name '$want': $msg" ;; esac
done

# --- 1b. the same thing through the COMMAND an operator actually types ------
# Arm 1 drives the applier. This drives `agent auth set` itself, because the
# row's acceptance is about that command and because a guard reachable only
# from an internal function is a guard the CLI does not have. Everything the
# refusal path touches before it exits is stubbed above; it never reaches the
# registry or systemctl.
echo "cmd_auth_set claude --provider=<vendor> on a custom-endpoint profile"
seed_custom_profile p6
before_sum=$(sha256sum < "$(env_of p6)")
rc=0
( cmd_auth_set claude --api-key=sk-zai-rotate-12 --provider=zai --auth-profile=p6 ) >/dev/null 2>&1 || rc=$?
if (( rc == E_VALIDATION )); then ok "the command refuses (exit $rc)"
else bad "expected exit $E_VALIDATION from cmd_auth_set, got $rc"; fi
if [[ "$before_sum" == "$(sha256sum < "$(env_of p6)")" ]]; then
  ok "EnvironmentFile byte-identical after the command refused"
else
  bad "cmd_auth_set modified the EnvironmentFile despite refusing"
fi
# ...and the same command WITH the flag goes all the way through, so the arm
# above is attributable to the pin and not to cmd_auth_set being unrunnable here.
registry_read() { printf '{"agents":{}}'; }
seed_custom_profile p7
if ( cmd_auth_set claude --api-key=sk-zai-rotate-12 --provider=zai --auth-profile=p7 \
       --base-url="$CUSTOM_URL" --model=qwen3.8-max ) >/dev/null 2>&1 \
   && [[ "$(url_in p7)" == "$CUSTOM_URL" ]]; then
  ok "positive control: the same command WITH --base-url completes and keeps the endpoint"
else
  bad "positive control: cmd_auth_set could not complete even with --base-url (url=$(url_in p7))"
fi

# --- 2. both doors the refusal offers actually open -------------------------
echo "the two exits the refusal names"
# 2a. KEEP: restate the same custom url.
seed_custom_profile p2
if ( _apply_byo_claude zai sk-zai-rotate-12 p2 "qwen3.8-max" "$CUSTOM_URL" ) >/dev/null 2>&1; then
  [[ "$(url_in p2)" == "$CUSTOM_URL" ]] \
    && ok "--base-url=<same> rotates the key and KEEPS the custom endpoint" \
    || bad "--base-url=<same> accepted but the url is now $(url_in p2)"
else
  bad "--base-url=<same> was refused — the 'keep' exit does not open"
fi
# ...and the rotation actually landed, so 2a is not passing on a no-op.
grep -q '^ANTHROPIC_AUTH_TOKEN=sk-zai-rotate-12$' "$(env_of p2)" \
  && ok "positive control: the new key reached the profile" \
  || bad "positive control: the key was NOT written — 2a proves nothing"
# 2b. MOVE: name the catalog url explicitly.
seed_custom_profile p3
if ( _apply_byo_claude zai sk-zai-rotate-12 p3 "" "$ZAI_URL" ) >/dev/null 2>&1; then
  [[ "$(url_in p3)" == "$ZAI_URL" ]] \
    && ok "--base-url=<catalog url> MOVES the profile onto the vendor deliberately" \
    || bad "--base-url=<catalog url> left the url at $(url_in p3)"
else
  bad "--base-url=<catalog url> was refused — there is no way back to a vendor"
fi

# --- 3. a catalog-pinned profile is NOT refused -----------------------------
# The guard keys on catalog membership, not on difference. Re-pointing a profile
# from one catalog vendor to another was named by --provider and is not silent,
# so refusing it would break an ordinary vendor switch.
echo "a profile already on a catalog url still switches vendors"
seed_custom_profile p4 "$ZAI_URL"
if ( _apply_byo_claude openrouter sk-or-rotate-12 p4 "" "" ) >/dev/null 2>&1; then
  [[ "$(url_in p4)" == "${CLAUDE_PROVIDER_BASEURL[openrouter]}" ]] \
    && ok "catalog->catalog vendor switch still applies" \
    || bad "vendor switch left the url at $(url_in p4)"
else
  bad "catalog->catalog vendor switch was REFUSED (guard is over-broad)"
fi

# --- 4. cmd_auth_set parses and forwards the flags --------------------------
echo "cmd_auth_set: --base-url / --model"
disp=$(declare -f cmd_auth_set)
grep -q -- '--base-url=\*)' <<<"$disp" \
  && ok "cmd_auth_set parses --base-url" || bad "cmd_auth_set does not parse --base-url"
grep -q -- '--model=\*)' <<<"$disp" \
  && ok "cmd_auth_set parses --model" || bad "cmd_auth_set does not parse --model"
grep -q 'apply_byo_provider "$type" "$byo_provider" "$api_key" "$profile" "$byo_model" "$base_url"' <<<"$disp" \
  && ok "cmd_auth_set forwards both to apply_byo_provider" \
  || bad "cmd_auth_set does not forward --model/--base-url (the parser would drop them)"
rc=0; ( cmd_auth_set claude --api-key=sk-test-123456 --base-url="$CUSTOM_URL" ) >/dev/null 2>&1 || rc=$?
(( rc == E_USAGE )) && ok "--base-url without --provider is refused (exit $rc)" \
                    || bad "expected $E_USAGE for --base-url with no --provider, got $rc"
rc=0; ( cmd_auth_set codex --api-key=sk-test-123456 --provider=zai --base-url="$CUSTOM_URL" ) >/dev/null 2>&1 || rc=$?
(( rc == E_VALIDATION )) && ok "--base-url on a non-claude type is refused (exit $rc)" \
                         || bad "expected $E_VALIDATION for --base-url on codex, got $rc"

# --- 5. MUTATION: cut the guard, arm 1 must go red --------------------------
# Cut from the LIVE file, so the mutant tracks the shipped source. Count the
# anchors BEFORE cutting: a range that matches nothing yields a mutant identical
# to the original, and this arm would then pass while grading nothing.
echo "mutation: remove the guard and the refusal must disappear"
src=src/cmd_agent_create.sh
mutant="$root/mutant_cmd_agent_create.sh"
n_begin=$(grep -c '^  # DIVE-2809 GUARD BEGIN' "$src" || true)
n_end=$(grep -c '^  # DIVE-2809 GUARD END' "$src" || true)
if [[ "$n_begin" == "1" && "$n_end" == "1" ]]; then
  ok "mutation anchors are present exactly once each (BEGIN=$n_begin END=$n_end)"
else
  bad "mutation anchors are not 1/1 (BEGIN=$n_begin END=$n_end) — the cut below would be a no-op"
fi
sed '/^  # DIVE-2809 GUARD BEGIN/,/^  # DIVE-2809 GUARD END/d' "$src" >"$mutant"
cut_lines=$(( $(wc -l <"$src") - $(wc -l <"$mutant") ))
if (( cut_lines > 0 )); then ok "the cut removed $cut_lines lines"
else bad "the cut removed NOTHING — the mutant is the original"; fi
if grep -q 'is pinned to a custom endpoint' "$mutant"; then
  bad "the guard's refusal survived the cut — the mutant still carries it"
else
  ok "the mutant no longer carries the guard's refusal"
fi

seed_custom_profile p5
rc=0
(
  # shellcheck disable=SC1090
  source "$mutant"
  _apply_byo_claude zai sk-zai-rotate-12 p5 "" ""
) >/dev/null 2>&1 || rc=$?
if (( rc == 0 )) && [[ "$(url_in p5)" == "$ZAI_URL" ]]; then
  ok "without the guard the custom endpoint IS silently reverted to $ZAI_URL — arm 1 is attributable"
else
  bad "the mutant did not reproduce the bug (rc=$rc url=$(url_in p5)) — arm 1 proves nothing"
fi
rm -rf "$root"

echo
if (( fails )); then echo "$fails failed"; exit 1; fi
echo "all assertions passed"
