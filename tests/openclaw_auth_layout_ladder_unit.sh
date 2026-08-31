#!/usr/bin/env bash
# DIVE-3834 unit: openclaw BYO auth must report the seat AUTHENTICATED on
# upstream openclaw 2026.8.1, which moved the credential store.
#
# The defect (measured on the paid smoke box 62.238.11.92, run
# smoke-20260831T035510Z, openclaw 2026.8.1 ea80657): the write half succeeded
# and the read half was pointed at the pre-2026.8.1 path, which 2026.8.1 still
# CREATES and leaves EMPTY. A correctly-credentialled customer seat rendered
# `needs_login` with an instruction that cannot help. Nothing on our side
# changed — we install openclaw unpinned, so an upstream release did it.
#
# What is graded here is the reported auth STATE, never the existence of any
# particular file — keying the assertion to a path is exactly what let this
# defect ride a full upstream release invisibly. The arms cover both the
# shipped default home (profile='') and named-profile HOME redirects:
#   1. default home, 2026.8.1 credential / no credential -> ok / needs_login,
#      plus an expired blob proving health reads the resolved credential path
#   2. default home with the older JSON sentinel and a lazily-created sqlite
#      only -> needs_login (the configured legacy sentinel stays authoritative)
#   3. named profile, 2026.8.1 credential -> ok (the reported regression)
#   4. named profile, pre-2026.8.1 credential -> ok (fallback intact)
#   5. named profile, 2026.8.1, NO credential -> needs_login (the ABSENT case:
#      openclaw.json exists and the old dir exists-but-empty, i.e. everything
#      the tree-shape looks-right test would pass. DIVE-3130's lesson is that a
#      guard which cannot fire on absence is not a guard.)
#   6. the app's own lazily-created store alone -> needs_login (it is created by
#      openclaw having RUN, not by having AUTHENTICATED, so it must not be
#      admitted as a credential rung).
#   7. an empty .auth.profiles map -> needs_login.
#   8. the CREATE-path witness (selfcheck_cred_reached_agent, witness 1b) on a
#      2026.8.1-shaped seat -> the "ok:" line, NOT the false
#      "credential never reached the seat" issue; on a pre-2026.8.1 seat -> ok;
#      with no credential at all -> the issue still fires. This was the third
#      reader of the store and the one left hardcoded: a customer provisioning
#      today was told to re-seed a seat that is fine.
#   9. the `agent info` unpinned-model warning resolves the default-home seat
#      through the ladder (structural — see the arm for why an end-to-end
#      `agent info` is not gradable in a pure unit).
# Pure, no root, no network:
#   bash tests/openclaw_auth_layout_ladder_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; chmod -R u+rwX "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/openclaw-auth-ladder-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

AUTH_PROFILES_DIR="$TMP/auth-profiles"
CONNECTORS_DIR="$TMP/connectors"
mkdir -p "$CONNECTORS_DIR" "$AUTH_PROFILES_DIR"

default_root="$TMP/home/claude"
declare -A TYPE_AUTH=(
  # Same relative path as the shipped TYPE_AUTH constant; rooted in TMP so the
  # unit never reads or writes the real operator home.
  [openclaw]="$default_root/.openclaw/agents/main/agent/openclaw-agent.sqlite"
)
declare -A TYPE_API_FILE=()
is_known_type() { case "$1" in openclaw) return 0;; *) return 1;; esac; }

# shellcheck source=/dev/null
source "$SRC/cmd_auth.sh"

# profile_type_dir installs as root:claude on a real host; in the harness we
# just need the dir to exist under the throwaway root.
profile_type_dir() { local d="${AUTH_PROFILES_DIR}/$1/$2"; mkdir -p "$d"; echo "$d"; }

fails=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }

# state_of <profile> — the STATE half of agent_auth_health for an openclaw seat.
state_of() { agent_auth_health openclaw "$1" | cut -d'|' -f1; }

# --- arm 1: default-home 2026.8.1 state, with and without a BYO credential ---
mkdir -p "$default_root/.openclaw/agents/main/agent"
: > "$default_root/.openclaw/agents/main/agent/openclaw-agent.sqlite"
cat > "$default_root/.openclaw/openclaw.json" <<'JSON'
{"auth":{"profiles":{"google:manual":{"provider":"google","mode":"api_key"}}}}
JSON
s=$(state_of "")
[[ "$s" == ok ]] && ok "default home, 2026.8.1 + credential: state=ok" \
                 || bad "default home, 2026.8.1 + credential: state=$s, want ok"
echo '{"auth":{"profiles":{}}}' > "$default_root/.openclaw/openclaw.json"
s=$(state_of "")
[[ "$s" == needs_login ]] && ok "default home, 2026.8.1 without credential: state=needs_login" \
                          || bad "default home, 2026.8.1 without credential: state=$s, want needs_login"
cat > "$default_root/.openclaw/openclaw.json" <<'JSON'
{"auth":{"profiles":{"oauth:test":{"provider":"openai","mode":"oauth"}}},
 "expiresAt":1}
JSON
s=$(state_of "")
[[ "$s" == expired ]] && ok "default home ladder feeds credential blob health: state=expired" \
                      || bad "default home ladder feeds credential blob health: state=$s, want expired"

# --- arm 2: a non-configured legacy default must ignore another sqlite ------
# The pre-DIVE-3489 default sentinel was auth-profiles.json. A different sqlite
# appearing beside it must not silently become proof of auth for that layout.
legacy_root="$TMP/legacy-home/claude"
TYPE_AUTH[openclaw]="$legacy_root/.openclaw/agents/main/agent/auth-profiles.json"
mkdir -p "$legacy_root/.openclaw/agents/main/agent"
printf 'SQLite format 3\0' > "$legacy_root/.openclaw/agents/main/agent/openclaw-agent.sqlite"
echo '{"auth":{"profiles":{}}}' > "$legacy_root/.openclaw/openclaw.json"
s=$(state_of "")
[[ "$s" == needs_login ]] && ok "legacy default + unrelated sqlite: state=needs_login" \
                          || bad "legacy default + unrelated sqlite: state=$s, want needs_login"
TYPE_AUTH[openclaw]="$default_root/.openclaw/agents/main/agent/openclaw-agent.sqlite"

# --- arm 3: named-profile 2026.8.1 with a real BYO credential ---------------
p=new-authed
root="$AUTH_PROFILES_DIR/$p/openclaw"
mkdir -p "$root/.openclaw/agents/main/agent" "$root/.openclaw/state"
# 2026.8.1 creates the OLD directory and leaves it empty — reproduce that, it
# is what made the failure silent.
: > "$root/.openclaw/state/openclaw.sqlite"
cat > "$root/.openclaw/openclaw.json" <<'JSON'
{"auth":{"profiles":{"google:manual":{"provider":"google","mode":"api_key"}}},
 "agents":{"defaults":{"model":{"primary":"google/gemini-2.5-pro"}}}}
JSON
if auth_creds_present openclaw "$p"; then ok "2026.8.1 + credential: auth_creds_present"
else bad "2026.8.1 + credential: auth_creds_present said ABSENT (the DIVE-3834 defect)"; fi
s=$(state_of "$p")
[[ "$s" == ok ]] && ok "2026.8.1 + credential: state=ok" \
                 || bad "2026.8.1 + credential: state=$s, want ok"

# --- arm 4: named-profile pre-2026.8.1 fallback remains intact ---------------
p=old-authed
root="$AUTH_PROFILES_DIR/$p/openclaw"
mkdir -p "$root/.openclaw/agents/main/agent"
printf 'SQLite format 3\0' > "$root/.openclaw/agents/main/agent/openclaw-agent.sqlite"
if auth_creds_present openclaw "$p"; then ok "pre-2026.8.1 layout: auth_creds_present"
else bad "pre-2026.8.1 layout: regressed to ABSENT — the fix swapped the path instead of laddering"; fi
s=$(state_of "$p")
[[ "$s" == ok ]] && ok "pre-2026.8.1 layout: state=ok" \
                 || bad "pre-2026.8.1 layout: state=$s, want ok"

# --- arm 5: named-profile ABSENT case on 2026.8.1 must still fire ------------
p=new-unauthed
root="$AUTH_PROFILES_DIR/$p/openclaw"
mkdir -p "$root/.openclaw/agents/main/agent"
# Config written, no auth profile ever created. The tree LOOKS right.
echo '{"agents":{"defaults":{"model":{"primary":"google/gemini-2.5-pro"}}}}' \
  > "$root/.openclaw/openclaw.json"
if auth_creds_present openclaw "$p"; then
  bad "2026.8.1 without credential: reported PRESENT — the guard cannot fire on absence"
else ok "2026.8.1 without credential: auth_creds_present says absent"; fi
s=$(state_of "$p")
[[ "$s" == needs_login ]] && ok "2026.8.1 without credential: state=needs_login" \
                          || bad "2026.8.1 without credential: state=$s, want needs_login"

# --- arm 6: openclaw's own lazily-created store is not a credential ----------
p=new-ran-only
root="$AUTH_PROFILES_DIR/$p/openclaw"
mkdir -p "$root/.openclaw/agents/main/agent" "$root/.openclaw/state"
printf 'SQLite format 3\0' > "$root/.openclaw/state/openclaw.sqlite"
if auth_creds_present openclaw "$p"; then
  bad "app store only: reported PRESENT — 'openclaw has run' is not 'openclaw is authed'"
else ok "app store only: auth_creds_present says absent"; fi
s=$(state_of "$p")
[[ "$s" == needs_login ]] && ok "app store only: state=needs_login" \
                          || bad "app store only: state=$s, want needs_login"

# --- arm 7: an empty auth.profiles map is not a credential -------------------
p=new-empty-map
root="$AUTH_PROFILES_DIR/$p/openclaw"
mkdir -p "$root/.openclaw/agents/main/agent"
echo '{"auth":{"profiles":{}}}' > "$root/.openclaw/openclaw.json"
if auth_creds_present openclaw "$p"; then
  bad "empty auth.profiles: reported PRESENT — gated on the file, not the map"
else ok "empty auth.profiles: auth_creds_present says absent"; fi
s=$(state_of "$p")
[[ "$s" == needs_login ]] && ok "empty auth.profiles: state=needs_login" \
                          || bad "empty auth.profiles: state=$s, want needs_login"

# --- arm 8: the CREATE-path witness (selfcheck_cred_reached_agent) ----------
#
# DIVE-3834, second iteration. The ladder was wired into auth_creds_present and
# agent_auth_health, and there is a THIRD reader: witness 1b in
# selfcheck_cred_reached_agent hardcoded the pre-2026.8.1 sqlite and tested it
# with -s. On a 2026.8.1 seat whose credential is present and correct that
# prints `issue:openclaw credential never reached the seat ... Re-seed as root`
# — the same defect and the same wrong instruction this row was filed for, on
# the path a customer provisioning TODAY actually walks. Graded on the emitted
# verdict, never on a path.
#
# `cred_readable_by_agent` is the agent-uid seam; a pure unit cannot shell to
# `sudo -u`, and a harness that did would grade the runner's sudo policy rather
# than this code (the reasoning is spelled out in
# tests/selfcheck_cred_reached_unit.sh).
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"
set +e   # header.sh enables `set -e`; these arms assert on values, not exits
cred_readable_by_agent() { return 0; }
export AGENT_HOME_ROOT="$TMP/agent-homes"

# oc_seat <name> — build a seat home and echo its .openclaw root.
oc_seat() { local n="$1"; mkdir -p "$AGENT_HOME_ROOT/agent-$n/.openclaw/agents/main/agent"; echo "$AGENT_HOME_ROOT/agent-$n/.openclaw"; }

FALSE_ISSUE='issue:openclaw credential never reached the seat'
SEAT_OK='ok:openclaw seat has its own credential and model pin'

# 8a — 2026.8.1 shape: old dir created-and-EMPTY, credential + model pin in
# openclaw.json. This is the reproduction of the reported defect on the create
# path; before the ladder was wired in here it printed FALSE_ISSUE.
oc=$(oc_seat new81)
cat > "$oc/openclaw.json" <<'JSON'
{"auth":{"profiles":{"google:manual":{"provider":"google","mode":"api_key"}}},
 "agents":{"defaults":{"model":{"primary":"google/gemini-2.5-pro"}}}}
JSON
out=$(selfcheck_cred_reached_agent new81 openclaw "" "" 2>/dev/null)
[[ "$out" != *"$FALSE_ISSUE"* ]]   && ok "create witness, 2026.8.1 + credential: no false 'never reached the seat'"   || bad "create witness, 2026.8.1 + credential: printed the false issue — the create path still reads the old store"
[[ "$out" == *"$SEAT_OK"* ]]   && ok "create witness, 2026.8.1 + credential: reports the seat ok"   || bad "create witness, 2026.8.1 + credential: no ok line, got: $out"

# 8b — pre-2026.8.1 shape: the fallback must be unchanged.
oc=$(oc_seat old81)
printf 'SQLite format 3\0' > "$oc/agents/main/agent/openclaw-agent.sqlite"
echo '{"agents":{"defaults":{"model":{"primary":"google/gemini-2.5-pro"}}}}' > "$oc/openclaw.json"
out=$(selfcheck_cred_reached_agent old81 openclaw "" "" 2>/dev/null)
[[ "$out" == *"$SEAT_OK"* ]]   && ok "create witness, pre-2026.8.1 + credential: reports the seat ok"   || bad "create witness, pre-2026.8.1 + credential: regressed, got: $out"

# 8c — the ABSENT case must STILL fire. This is the arm that stops the fix from
# being "make the witness stop complaining": a seat with openclaw.json present
# (config written) and no auth profile ever created is unauthenticated, and the
# tree-shape looks right. DIVE-3130.
oc=$(oc_seat none81)
echo '{"auth":{"profiles":{}},"agents":{"defaults":{"model":{"primary":"google/gemini-2.5-pro"}}}}' > "$oc/openclaw.json"
out=$(selfcheck_cred_reached_agent none81 openclaw "" "" 2>/dev/null)
[[ "$out" == *"$FALSE_ISSUE"* ]]   && ok "create witness, 2026.8.1 without credential: the issue still fires"   || bad "create witness, 2026.8.1 without credential: silent — the witness can no longer fire on absence, got: $out"

# --- arm 9: `agent info`'s unpinned-model warning ----------------------------
#
# cmd_agent.sh resolved the DEFAULT-HOME openclaw seat straight from
# TYPE_AUTH[openclaw] and tested it with -s, so on 2026.8.1 (constant present,
# EMPTY) the DIVE-3112 unpinned-model warning was silently suppressed on exactly
# the seats that need it — a seat running on openclaw's built-in default, whose
# provider prefix selects a credential we never wrote, and 401s while looking
# configured. Lower stakes than arm 8 (a missing warning, not a wrong
# instruction) and the same class.
#
# Declared limitation, deliberately not papered over: this arm is STRUCTURAL.
# Grading it behaviourally means running cmd_agent_info, which reads systemd
# unit state, the on-disk registry and the enforced sudo grant — none of which
# a pure unit can supply, and stubbing all three would grade the stubs. The
# behaviour of the resolver it now calls IS graded, on real fixtures, by arm 1.
blk=$(sed -n '/DIVE-3113: for openclaw, an absent model is not a neutral/,/oc_unpinned=1/p' "$SRC/cmd_agent.sh")
[[ -n "$blk" ]]   && ok "agent info: the unpinned-model block was located"   || bad "agent info: could not locate the unpinned-model block — this arm graded nothing"
[[ "$blk" == *'profile_type_auth_path "" openclaw'* ]]   && ok "agent info: default-home seat resolves through the layout ladder"   || bad "agent info: default-home seat still reads TYPE_AUTH directly — suppressed on 2026.8.1"

if (( fails )); then
  printf '\nFAIL: %d assertion(s)\n' "$fails"
else
  printf '\nPASS: openclaw auth layout ladder\n'
fi
(( fails == 0 ))
