#!/usr/bin/env bash
# DIVE-3104 unit: `agent auth status` can be asked about ONE AGENT, and every
# answer carries the credential scope it was actually resolved from.
#
# The defect (DIVE-3100 follow-up, corroborated against cmd_auth.sh by quinn):
# `auth_creds_present` resolves its credential path from its optional `profile`
# argument. A bare `--type=hermes` query passes no profile, so it opens the
# TYPE's DEFAULT sentinel path — never any specific agent's profile-scoped
# path. A per-TYPE probe therefore cannot see a per-AGENT credential gap BY
# CONSTRUCTION: `agent auth status --probe --type=hermes|openclaw` returned
# `ok` for seats whose own credential was empty and which could not think.
#
# What is graded here is the ROUTING (which scope the answer came from), not
# whether any particular credential file is valid — `auth_creds_present` and
# `agent_auth_health` already own presence, and re-testing them here would
# grade the instrument rather than this change. `auth_status_one` is therefore
# stubbed to echo back the profile it was handed, which is precisely the fact
# the defect got wrong.
#
# Both directions, because a scope line that is always the same is decoration:
#   - --agent=<n> resolves that agent's OWN authProfile from the registry;
#   - an agent with NO authProfile resolves the default scope, and says so
#     (that agent really does read the shared connectors env — the honest
#     answer, but it must not be silent about which one it is);
#   - a bare --type answer NAMES the profile-bound agents it does not cover...
#   - ...and names ZERO when there are none (the positive control: without it,
#     the "names them" assertion could pass on an empty list forever);
#   - --agent + --auth-profile, an unknown agent, and a type/agent mismatch are
#     all refused rather than silently resolving the wrong scope.
# Pure, no root, no network:
#   bash tests/auth_status_per_agent_scope_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# Guarded on BASHPID: bash fires an inherited EXIT trap when a SUBSHELL ends,
# and the refusal arms below run cmd_auth_status (whose `fail` exits) inside
# command substitutions. Unguarded, the first refusal rm -rf'd "$TMP" and
# printed a HARNESS-RC line mid-run, ending the corpus early with a passing
# tail — a harness that stops is not a harness that passed.
trap 'rc=$?; [[ "$BASHPID" == "$$" ]] || exit "$rc"; rm -rf "${TMP:-}" 2>/dev/null; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/auth-status-per-agent-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

AUTH_PROFILES_DIR="$TMP/auth-profiles"
CONNECTORS_DIR="$TMP/connectors"
mkdir -p "$CONNECTORS_DIR"

declare -A TYPE_AUTH=([hermes]="$TMP/home/claude/.hermes/auth.json" \
                      [openclaw]="$TMP/home/claude/.openclaw/auth.json" \
                      [claude]="$TMP/connectors/anthropic.env:CLAUDE_CODE_OAUTH_TOKEN")
declare -A TYPE_BIN=([hermes]="/bin/true" [openclaw]="/bin/true" [claude]="/bin/true")
declare -A TYPE_API_FILE=()
is_known_type() { case "$1" in hermes|openclaw|claude) return 0;; *) return 1;; esac; }

# The registry the fix reads --agent out of. `finn` is the DIVE-3100 shape (a
# hermes seat on its own profile); `nobody` carries no authProfile at all.
cat > "$TMP/agents.json" <<'JSON'
{"agents":{
  "finn":   {"type":"hermes",   "authProfile":"hermes-finn"},
  "ray":    {"type":"openclaw", "authProfile":"openclaw-ray"},
  "nobody": {"type":"hermes",   "authProfile":""},
  "cc":     {"type":"claude",   "authProfile":"cc-prof"}
}}
JSON
registry_read() { cat "$TMP/agents.json"; }
# The seam the coverage list actually lives in. registry_read() cannot express
# "I could not read it" — it returns {"agents":{}} for absent / unreadable /
# truncated alike — so an always-succeeding stub of it makes the fail-open
# unreachable by construction (quinn, iteration 1). REG_RC drives the CHECKED
# helper's documented codes: 3 absent, 4 unreadable, 5 unparseable.
REG_RC=0
registry_read_checked() {
  [[ "$REG_RC" == "0" ]] || return "$REG_RC"
  cat "$TMP/agents.json"
}

# shellcheck source=/dev/null
source "$SRC/cmd_auth.sh"

# Stub the leaf so the harness grades WHICH SCOPE reached it. Real
# auth_status_one would shell out to a vendor CLI; the routing is the change.
auth_status_one() { printf 'scope=%s' "${3:-DEFAULT}"; }

# Real `fail` EXITS, so every refusal site is terminal. Every call below runs
# cmd_auth_status inside a command substitution, i.e. a subshell, so exiting
# here reproduces that without killing the harness. A `return` stub would let
# execution fall through past a refusal and emit a SECOND, contradictory
# message — which is a harness artefact, not product behaviour.
fail() { echo "FAILCALL: $2" >&2; exit 66; }

fails=0
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want=$3 got=$2)"; fails=1; fi; }
contains() { if [[ "$2" == *"$3"* ]]; then echo "ok: $1"; else echo "FAIL: $1 (want substring=$3 got=$2)"; fails=1; fi; }

# Every invocation runs in an explicit subshell with the EXIT trap CLEARED: the
# `fail` stub above exits, and bash fires an inherited EXIT trap when a subshell
# exits — which would rm -rf "$TMP" out from under the rest of the run.
run_json() { ( trap - EXIT; JSON_MODE=1 cmd_auth_status "$@" 2>/dev/null ); }
run_err()  { ( trap - EXIT; JSON_MODE=1 cmd_auth_status "$@" 2>&1 >/dev/null ); }
run_text_err() { ( trap - EXIT; JSON_MODE=0 cmd_auth_status "$@" 2>&1 >/dev/null ); }

# --- 1. THE FIX: --agent resolves that agent's own profile ----------------
out=$(run_json --agent=finn)
check "--agent=finn probes the agent's own profile-scoped credential" \
  "$(jq -r '.data.hermes' <<<"$out")" "scope=hermes-finn"
check "--agent=finn reports scope kind" "$(jq -r '.scope.kind' <<<"$out")" "agent"
check "--agent=finn reports the resolved profile" \
  "$(jq -r '.scope.authProfile' <<<"$out")" "hermes-finn"
check "--agent=finn infers the type from the registry" \
  "$(jq -r '.data | keys | join(",")' <<<"$out")" "hermes"

out=$(run_json --agent=ray)
check "--agent=ray (openclaw) resolves its own profile too" \
  "$(jq -r '.data.openclaw' <<<"$out")" "scope=openclaw-ray"

# --- 2. an agent with no profile is DEFAULT, and says so ------------------
out=$(run_json --agent=nobody)
check "--agent with no authProfile resolves the default scope" \
  "$(jq -r '.data.hermes' <<<"$out")" "scope=DEFAULT"
check "...and names it rather than staying silent" \
  "$(jq -r '.scope.label' <<<"$out")" "agent nobody (profile: default)"

# --- 3. THE FALSE GREEN: a bare --type answer names what it misses --------
out=$(run_json --type=hermes)
check "bare --type=hermes is still the DEFAULT scope (unchanged behaviour)" \
  "$(jq -r '.data.hermes' <<<"$out")" "scope=DEFAULT"
check "bare --type=hermes declares its scope" "$(jq -r '.scope.kind' <<<"$out")" "default"
check "bare --type=hermes names the profile-bound hermes agents it cannot cover" \
  "$(jq -r '[.scope.uncoveredAgents[].name] | sort | join(",")' <<<"$out")" "finn"
check "...and does NOT claim agents of other types" \
  "$(jq -r '[.scope.uncoveredAgents[].type] | unique | join(",")' <<<"$out")" "hermes"
check "...and excludes the default-profile agent (it IS covered)" \
  "$(jq -r '[.scope.uncoveredAgents[].name] | index("nobody") // "absent"' <<<"$out")" "absent"

# POSITIVE CONTROL for the assertion above: a type with no profile-bound agent
# must report an EMPTY uncovered list. Without this, "names them" would pass
# just as well on a list that is always empty.
cat > "$TMP/agents.json" <<'JSON'
{"agents":{"nobody":{"type":"hermes","authProfile":""}}}
JSON
out=$(run_json --type=hermes)
check "no profile-bound agents of the type -> uncovered list is empty" \
  "$(jq -r '.scope.uncoveredAgents | length' <<<"$out")" "0"
cat > "$TMP/agents.json" <<'JSON'
{"agents":{
  "finn":   {"type":"hermes",   "authProfile":"hermes-finn"},
  "ray":    {"type":"openclaw", "authProfile":"openclaw-ray"},
  "nobody": {"type":"hermes",   "authProfile":""},
  "cc":     {"type":"claude",   "authProfile":"cc-prof"}
}}
JSON

check "a measured coverage list says so" \
  "$(jq -r '.scope.uncoveredStatus' <<<"$(run_json --type=hermes)")" "measured"

# --- 3b. UNMEASURED COVERAGE IS NOT ZERO COVERAGE ------------------------
# The fail-open this row exists to kill, one layer in: if the registry read
# fails, the "NOT COVERED: N agent(s)" block reads 0 and disappears, and the
# answer is a clean green again — silence rendered identically to safety. The
# uncovered list must therefore be null + a reason, never [].
for rc_case in "4:registry-unreadable" "5:registry-unparsable" "3:no-registry"; do
  REG_RC="${rc_case%%:*}"; want="unknown:${rc_case#*:}"
  out=$(run_json --type=hermes)
  check "registry rc=${REG_RC}: coverage reports ${want}, not a number" \
    "$(jq -r '.scope.uncoveredStatus' <<<"$out")" "$want"
  check "registry rc=${REG_RC}: uncoveredAgents is null, NOT an empty list" \
    "$(jq -r '.scope.uncoveredAgents | if . == null then "null" else "list(\(length))" end' <<<"$out")" "null"
  contains "registry rc=${REG_RC}: text mode says COVERAGE UNKNOWN out loud" \
    "$(REG_RC=$REG_RC run_text_err --type=hermes)" "COVERAGE UNKNOWN"
  contains "registry rc=${REG_RC}: text mode does NOT print a zero-uncovered green" \
    "$(REG_RC=$REG_RC run_text_err --type=hermes)" "NOT zero agents"
  # The type-level auth answer itself is still delivered — the registry says
  # nothing about whether the default credential is present.
  check "registry rc=${REG_RC}: the auth answer itself still arrives" \
    "$(jq -r '.data.hermes' <<<"$out")" "scope=DEFAULT"
  # ...and --agent must not answer "unknown agent" (i.e. "does not exist")
  # about an agent it simply could not look up.
  # A bare `err=$(...)` would take errexit (inherited from header.sh) straight
  # to the EXIT trap, because a refusal exits non-zero — the harness would stop
  # here with a passing tail. Grade the refusal instead of tripping over it.
  if err=$(REG_RC=$REG_RC run_err --agent=finn); then
    err="UNEXPECTED-SUCCESS(rc=0): $err"
  fi
  contains "registry rc=${REG_RC}: --agent=finn refuses with a registry reason" "$err" "registry"
  if [[ "$err" == *"unknown agent: finn"* ]]; then
    echo "FAIL: registry rc=${REG_RC}: --agent=finn reported the agent does not exist"; fails=1
  else
    echo "ok: registry rc=${REG_RC}: --agent=finn does not claim the agent does not exist"
  fi
done
REG_RC=0

# Malformed body that still READS: registry_read_checked is stubbed here, so
# this grades the caller's own jq failing rather than the helper's rc path.
cat > "$TMP/agents.json" <<'JSON'
{"agents":{"finn": {"type":"hermes", "authProf
JSON
out=$(run_json --type=hermes)
check "malformed registry body: coverage is unknown, not zero" \
  "$(jq -r '.scope.uncoveredStatus' <<<"$out")" "unknown:coverage-query-failed"
check "malformed registry body: uncoveredAgents is null" \
  "$(jq -r '.scope.uncoveredAgents | if . == null then "null" else "list" end' <<<"$out")" "null"
cat > "$TMP/agents.json" <<'JSON'
{"agents":{
  "finn":   {"type":"hermes",   "authProfile":"hermes-finn"},
  "ray":    {"type":"openclaw", "authProfile":"openclaw-ray"},
  "nobody": {"type":"hermes",   "authProfile":""},
  "cc":     {"type":"claude",   "authProfile":"cc-prof"}
}}
JSON

# --- 4. refusals: never silently resolve the wrong scope ------------------
contains "--agent with --auth-profile is refused" \
  "$(run_err --agent=finn --auth-profile=other)" "mutually exclusive"
contains "unknown agent is refused" "$(run_err --agent=ghost)" "unknown agent: ghost"
contains "type/agent mismatch is refused" \
  "$(run_err --agent=finn --type=claude)" "is type 'hermes'"

# --- 5. the pre-existing surfaces are untouched ---------------------------
out=$(run_json --type=hermes --auth-profile=hermes-finn)
check "--auth-profile still scopes to that profile" \
  "$(jq -r '.data.hermes' <<<"$out")" "scope=hermes-finn"
check "--auth-profile reports scope kind" "$(jq -r '.scope.kind' <<<"$out")" "profile"
contains "--auth-profile without --type is still refused" \
  "$(run_err --auth-profile=hermes-finn)" "requires --type"

# Harness reachability: if cmd_auth_status were undefined every check above
# would have compared empty-to-empty in some other file's shape.
if declare -F cmd_auth_status >/dev/null; then
  echo "ok: cmd_auth_status is defined (assertions above were reachable)"
else
  echo "FAIL: cmd_auth_status is NOT defined — every check above graded nothing"; fails=1
fi

(( fails == 0 )) || { echo "RESULT: FAIL"; exit 1; }
echo "RESULT: PASS"
