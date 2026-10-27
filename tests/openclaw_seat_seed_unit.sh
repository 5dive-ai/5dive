#!/usr/bin/env bash
# DIVE-3442: an openclaw BYO seat booted with NO credential and NO model pin.
#
# Measured on a live throwaway seat (openclaw + openrouter, --isolation=standard,
# no --auth-profile): /home/agent-<name>/.openclaw/agents/main/agent/
# auth-profiles.json DID NOT EXIST and the seat's openclaw.json carried
# primary=null, while /home/claude's copy was correct on every field. Telegram
# worked (channel/gateway config is written straight into the seat and needs no
# credential); every provider call 401'd.
#
# The seed in 5dive-agent-start is a PULL: the seat reads claude's copy at launch.
# Both its arms fail for a BYO seat — /home/claude/.openclaw is 0700 claude:claude
# so a group member cannot traverse it, and a standard-isolation seat has no
# NOPASSWD sudo for the fallback. The profile-scoped path escapes this only
# because normalize_profile_seed_perms relaxes it at bind time; the DEFAULT
# (no --auth-profile) path is never normalized, which is the shape lodar hit.
#
# The fix is a PUSH from root at create/auth-set time. This harness grades the
# push helper, its wiring, and the two silences that let the defect ship:
# selfcheck_cred_reached_agent had no witness that looks at the SEAT, and
# assert_cred_seeded's unreadable-source verdict never left a breadcrumb (the
# only channel `agent list`'s health rail reads).
#
# Pure: no root, no network, no runtime state.  bash tests/openclaw_seat_seed_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (want=$3 got=$2)"; fail=1; fi; }
has()   { if grep -qF -- "$2" <<<"$1"; then echo "ok: $3"; else echo "FAIL: $3"; fail=1; fi; }
hasnt() { if grep -qF -- "$2" <<<"$1"; then echo "FAIL: $3"; fail=1; else echo "ok: $3"; fi; }

TMP="$(mktemp -d /tmp/openclaw-seat-seed.XXXXXX)"

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/lib/agent_setup.sh
# shellcheck disable=SC1091
source src/cmd_agent_create.sh
step() { :; }
WARNS=""
warn() { WARNS+="$*"$'\n'; }

# ---------- 1. the push helper ----------
# Shared source, as _apply_byo_openclaw leaves it.
SHARED="$TMP/shared"
mkdir -p "$SHARED/.openclaw/agents/main/agent"
# DIVE-3489: the CREDENTIAL is openclaw-agent.sqlite. A byte blob stands in for
# the real store — the helper copies it, it never parses it, so the format is not
# what is under test here; the fact that the credential-bearing file travels is.
# The -wal sibling is deliberately EMPTY: a 0-byte -wal is the normal state after
# a clean checkpoint, and treating it as a failed read is a live bug shape.
printf 'SQLite format 3\000fake-store-bytes\n' \
  > "$SHARED/.openclaw/agents/main/agent/openclaw-agent.sqlite"
: > "$SHARED/.openclaw/agents/main/agent/openclaw-agent.sqlite-wal"
# Legacy JSON alongside it: still carried (additive), never the credential.
printf '{"version":1,"profiles":{"openrouter:manual":{"type":"api_key","provider":"openrouter","key":"sk-or-test-1234567890"}}}\n' \
  > "$SHARED/.openclaw/agents/main/agent/auth-profiles.json"
# auth.profiles is the REGISTRATION half `models auth paste-api-key` writes into
# openclaw.json (provider + mode, no key). The store is unselectable without it.
printf '{"agents":{"defaults":{"model":{"primary":"openrouter/auto"}}},"models":{"providers":{"zai":{"baseUrl":"https://example.invalid/coding"}}},"auth":{"profiles":{"openrouter:manual":{"provider":"openrouter","mode":"api_key"}}}}\n' \
  > "$SHARED/.openclaw/openclaw.json"

# The seat as `agent create` leaves it just before the push: its own
# openclaw.json already holds channels + gateway token, and NO credential.
SEATS="$TMP/home"
mkdir -p "$SEATS/agent-octest/.openclaw"
printf '{"gateway":{"mode":"local","token":"gw-secret"},"channels":{"telegram":{"enabled":true}}}\n' \
  > "$SEATS/agent-octest/.openclaw/openclaw.json"

# profile="" -> the DEFAULT path, which is the measured-broken one. Point the
# helper's two roots at the fixture: AGENT_HOME_ROOT is the existing test seam,
# and the shared base is /home/claude, so run with a stubbed profile_type_dir
# only on the profiled leg below.
HOME_ROOT_SEAM_OK=0
grep -q 'AGENT_HOME_ROOT' <<<"$(declare -f seed_openclaw_state_into_seat)" && HOME_ROOT_SEAM_OK=1
check "helper honours the AGENT_HOME_ROOT test seam" "$HOME_ROOT_SEAM_OK" "1"

# Exercise the default (no-profile) path by pointing /home/claude's stand-in at
# the fixture through profile_type_dir's caller: the helper hardcodes
# /home/claude for profile="", so grade the profiled leg (identical code below
# the base resolution) plus an explicit assertion that the default base is
# /home/claude — the path the live repro used.
has "$(declare -f seed_openclaw_state_into_seat)" 'base="/home/claude"' \
    "helper defaults to the shared /home/claude base (the measured-broken path)"

profile_type_dir() { printf '%s' "$SHARED"; }
AGENT_HOME_ROOT="$SEATS" seed_openclaw_state_into_seat octest qa-profile

SEAT_DIR="$SEATS/agent-octest/.openclaw/agents/main/agent"
SEAT_AUTH="$SEAT_DIR/openclaw-agent.sqlite"
SEAT_JSON="$SEAT_DIR/auth-profiles.json"
SEAT_CFG="$SEATS/agent-octest/.openclaw/openclaw.json"
check "seat now has its own auth STORE (openclaw-agent.sqlite)" "$( [[ -s "$SEAT_AUTH" ]] && echo yes )" "yes"
check "seat credential is byte-identical to the shared one" \
      "$(cmp -s "$SEAT_AUTH" "$SHARED/.openclaw/agents/main/agent/openclaw-agent.sqlite" && echo same)" "same"
check "seat credential is 0600" "$(stat -c '%a' "$SEAT_AUTH")" "600"
# DIVE-3489: a 0-byte -wal is the normal post-checkpoint state and must still
# travel — an -s guard on the siblings would silently drop it.
check "empty -wal sibling travels rather than being read as a failed copy" \
      "$( [[ -e "$SEAT_AUTH-wal" ]] && echo yes )" "yes"
# Additive, not the credential: the legacy JSON is still carried so a profile
# written by an older CLI is not dropped.
check "legacy auth-profiles.json still carried alongside the store" \
      "$( [[ -s "$SEAT_JSON" ]] && echo yes )" "yes"
# The half a store copy cannot supply. Without the registration the seat holds a
# credential nothing selects — this row's defect with the halves swapped.
check "profile REGISTRATION reaches the seat's openclaw.json" \
      "$(jq -r '.auth.profiles["openrouter:manual"].provider' "$SEAT_CFG")" "openrouter"
check "registration carries no key" \
      "$(jq -r '.auth.profiles["openrouter:manual"].key // "absent"' "$SEAT_CFG")" "absent"
# The seat's pre-existing config must survive the merge — it holds the gateway
# token and channels by the time we run.
check "seat gateway token survives the merge" \
      "$(jq -r '.gateway.token' "$SEAT_CFG")" "gw-secret"
check "seat model pin lands" "$(jq -r '.agents.defaults.model.primary' "$SEAT_CFG")" "openrouter/auto"
# models.providers is in the copy set on purpose: the boot seed syncs only
# agents.defaults, so a zai baseUrl override reached the shared config and never
# the seat — same failure class, one line away.
check "provider baseUrl override reaches the seat too" \
      "$(jq -r '.models.providers.zai.baseUrl' "$SEAT_CFG")" "https://example.invalid/coding"
# MERGE, not overwrite: the seat's gateway token and channels predate the push.
check "seat gateway token survives the merge" "$(jq -r '.gateway.token' "$SEAT_CFG")" "gw-secret"
check "seat channel config survives the merge" "$(jq -r '.channels.telegram.enabled' "$SEAT_CFG")" "true"

# Idempotent: a re-run (key rotation via `agent auth set`) must not corrupt it.
AGENT_HOME_ROOT="$SEATS" seed_openclaw_state_into_seat octest qa-profile
check "second push is idempotent" "$(jq -r '.gateway.token + "|" + .agents.defaults.model.primary' "$SEAT_CFG")" \
      "gw-secret|openrouter/auto"

# A seat that does not exist is a no-op, never an error.
AGENT_HOME_ROOT="$TMP/nope" seed_openclaw_state_into_seat ghost qa-profile
check "missing seat home is a silent no-op (rc 0)" "$?" "0"

# ---------- 2. wiring: create + auth set must actually call it ----------
create_src=$(cat src/cmd_agent_create.sh)
has "$create_src" 'seed_openclaw_state_into_seat "$name" "$profile"' \
    "cmd_create pushes openclaw state into the seat"
# It has to run AFTER the channel install, or the channel writer's own
# openclaw.json write lands on top of the merge.
# `|| var=` on both: under `set -o pipefail` a grep that finds nothing makes the
# whole substitution non-zero, and an unguarded one aborted this harness mid-run
# under mutation — it reported the first FAIL and then never reached RESULT.
create_line=$(grep -n 'seed_openclaw_state_into_seat "\$name"' src/cmd_agent_create.sh | head -1 | cut -d: -f1) || create_line=""
chan_line=$(grep -n 'install_channel_for_agent "\$type" telegram' src/cmd_agent_create.sh | head -1 | cut -d: -f1) || chan_line=""
if [[ -n "$create_line" && -n "$chan_line" && "$create_line" -gt "$chan_line" ]]; then
  echo "ok: the push runs after the channel install (merge lands on top)"
else
  echo "FAIL: the push must run after install_channel_for_agent (create=$create_line channel=$chan_line)"; fail=1
fi
has "$(cat src/cmd_auth.sh)" 'seed_openclaw_state_into_seat "$_agent" "$profile"' \
    "agent auth set pushes a rotated key into each bound openclaw seat"

# ---------- 3. selfcheck must grade the SEAT, not just the source ----------
# The broken seat printed a CLEAN create: on the BYO path with no profile,
# witness 2 resolves src="" and returns without a word.
AUTH_PROFILES_DIR="$TMP/profiles"; mkdir -p "$AUTH_PROFILES_DIR"
out=$(AGENT_HOME_ROOT="$TMP/broken" selfcheck_cred_reached_agent octest2 openclaw "" openrouter 2>&1)
mkdir -p "$TMP/broken/agent-octest2"
out=$(AGENT_HOME_ROOT="$TMP/broken" selfcheck_cred_reached_agent octest2 openclaw "" openrouter 2>&1)
has "$out" "issue:openclaw credential never reached the seat" \
    "selfcheck flags a seat with no credential of its own"

# Credential present, model pin null — the DIVE-3113/3130 shape: reports AUTH ok,
# 401s on every message because openclaw falls back to a built-in default whose
# provider prefix selects a credential nobody wrote.
mkdir -p "$TMP/nullmodel/agent-octest3/.openclaw/agents/main/agent"
printf 'SQLite format 3\000fake-store-bytes\n' \
  > "$TMP/nullmodel/agent-octest3/.openclaw/agents/main/agent/openclaw-agent.sqlite"
printf '{"agents":{"defaults":{"model":{"primary":null}}},"gateway":{"mode":"local"}}\n' \
  > "$TMP/nullmodel/agent-octest3/.openclaw/openclaw.json"
out=$(AGENT_HOME_ROOT="$TMP/nullmodel" selfcheck_cred_reached_agent octest3 openclaw "" openrouter 2>&1)
has "$out" "issue:openclaw seat has a credential but NO model pin" \
    "selfcheck flags a credential with a null model pin"

# The healthy seat the fix produces must NOT alarm — a witness that always fires
# is not a witness.
out=$(AGENT_HOME_ROOT="$SEATS" selfcheck_cred_reached_agent octest openclaw "" openrouter 2>&1)
has "$out" "ok:openclaw seat has its own credential and model pin (openrouter/auto)" \
    "selfcheck passes the seat the fix produces"
hasnt "$out" "issue:openclaw" "no false alarm on a correctly seeded seat"

# A bare-string model (openclaw accepts it) must not blow up the jq probe —
# indexing a string with .primary is a jq ERROR, not a null.
mkdir -p "$TMP/strmodel/agent-octest4/.openclaw/agents/main/agent"
printf 'SQLite format 3\000fake-store-bytes\n' \
  > "$TMP/strmodel/agent-octest4/.openclaw/agents/main/agent/openclaw-agent.sqlite"
printf '{"agents":{"defaults":{"model":"openrouter/auto"}}}\n' \
  > "$TMP/strmodel/agent-octest4/.openclaw/openclaw.json"
out=$(AGENT_HOME_ROOT="$TMP/strmodel" selfcheck_cred_reached_agent octest4 openclaw "" openrouter 2>&1)
has "$out" "ok:openclaw seat has its own credential and model pin (openrouter/auto)" \
    "string-shaped model pin is read, not mis-flagged"

# ---------- DIVE-3489: the regression this row was filed for ----------
# A seat holding ONLY auth-profiles.json is exactly what every openclaw BYO
# create shipped: a byte-valid credential in a store openclaw does not read. It
# reported AUTH ok and died at first use with ProviderAuthError. The witness must
# now call it what it is. This arm is the one that reds on the pre-fix witness,
# so it is what makes the rest of this section evidence rather than fixture
# maintenance — with the model pin PRESENT and valid, so the only thing it can
# be reacting to is the credential.
mkdir -p "$TMP/jsononly/agent-octest5/.openclaw/agents/main/agent"
printf '{"version":1,"profiles":{"openrouter:manual":{"type":"api_key","provider":"openrouter","key":"sk-or-test-1234567890"}}}\n' \
  > "$TMP/jsononly/agent-octest5/.openclaw/agents/main/agent/auth-profiles.json"
printf '{"agents":{"defaults":{"model":{"primary":"openrouter/auto"}}}}\n' \
  > "$TMP/jsononly/agent-octest5/.openclaw/openclaw.json"
out=$(AGENT_HOME_ROOT="$TMP/jsononly" selfcheck_cred_reached_agent octest5 openclaw "" openrouter 2>&1)
has "$out" "issue:openclaw credential never reached the seat" \
    "a seat with ONLY the inert auth-profiles.json is flagged, not passed as healthy"
hasnt "$out" "ok:openclaw seat has its own credential" \
    "the inert JSON is never accepted as the credential witness"

# ---------- 4. the boot-time verdict must leave a breadcrumb ----------
# assert_cred_seeded already printed an ERROR for a present-but-unreadable
# source — to journald, which neither the health rail nor selfcheck reads.
extract_fn() { awk -v m="$1() {" 'substr($0,1,length(m))==m { on=1 } on { print } on && $0 == "}" { exit }' bin/5dive-agent-start; }
HELPER=""
for _fn in assert_cred_seeded cred_seed_breadcrumb_path cred_seed_breadcrumb_write cred_seed_failed cred_seed_ok cred_src_readable cred_seed_why; do
  _def="$(extract_fn "$_fn")"
  [[ -n "$_def" ]] || { echo "FAIL: could not extract $_fn from 5dive-agent-start"; fail=1; }
  HELPER+="$_def"$'\n'
done
if [[ $EUID -eq 0 ]]; then
  echo "skip: breadcrumb leg needs a non-root euid (root can read anything)"
else
  mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
  UNREADABLE="$TMP/unreadable/.openclaw/agents/main/agent/auth-profiles.json"
  mkdir -p "$(dirname "$UNREADABLE")"
  printf '{"version":1}\n' > "$UNREADABLE"; chmod 0000 "$UNREADABLE"
  BCHOME="$TMP/bchome"; mkdir -p "$BCHOME"
  out=$(env PATH="$TMP/bin:$PATH" HOME="$BCHOME" bash -c "
    set -uo pipefail
    $HELPER
    assert_cred_seeded openclaw '$UNREADABLE' '$BCHOME/nonexistent-local.json'
  " 2>&1)
  has "$out" "ERROR: openclaw credential EXISTS" "boot verdict still names the fault on stderr"
  has "$out" "Malformed auth code" "boot verdict still names the misleading downstream symptom"
  check "the verdict now leaves the breadcrumb the health rail reads" \
        "$( [[ -s "$BCHOME/.5dive-cred-seed-failed" ]] && echo yes )" "yes"
  has "$(cat "$BCHOME/.5dive-cred-seed-failed" 2>/dev/null)" "UNAUTHENTICATED" \
      "breadcrumb text names the consequence"
  chmod 0644 "$UNREADABLE"
fi

# ---------- 5. DIVE-7101: the 2026.10.x key lives in the state db ----------
# openclaw 2026.10.7 writes a pasted key into ~/.openclaw/state/openclaw.sqlite
# (config_machine_state row `authProfiles.store`) and never creates
# agents/main/agent/. Measured in a throwaway HOME against the real 2026.10.7
# CLI: a seat without that row fails every turn on `No API key found for
# provider "openrouter"`; a seat given the row by openclaw_carry_state_auth
# sends the key (OpenRouter answered 401 for the fake key). The fixtures below
# are that db's real schema; the CLI itself is not run here.
mkstate() { # <db> <profiles-json|""> [own-row-key] — WAL db, openclaw's schema
  mkdir -p "$(dirname "$1")"
  python3 -I - "$@" <<'PY'
import json, sqlite3, sys
db, prof = sys.argv[1], sys.argv[2]
own = sys.argv[3] if len(sys.argv) > 3 else ""
c = sqlite3.connect(db)
c.execute("PRAGMA journal_mode=WAL")
c.execute("CREATE TABLE IF NOT EXISTS config_machine_state (state_key TEXT NOT NULL PRIMARY KEY, value_json TEXT NOT NULL, updated_at_ms INTEGER NOT NULL) STRICT")
c.execute("INSERT OR REPLACE INTO config_machine_state VALUES ('config.lastTouchedAt', '\"x\"', 1)")
if prof:
    c.execute("INSERT OR REPLACE INTO config_machine_state VALUES ('auth.sharedStore', '{\"location\":\"state-db\"}', 2)")
    c.execute("INSERT OR REPLACE INTO config_machine_state VALUES ('authProfiles.store', ?, 3)", (json.dumps({"version": 1, "profiles": json.loads(prof)}),))
if own:
    c.execute("INSERT OR REPLACE INTO config_machine_state VALUES (?, '\"seat-own\"', 4)", (own,))
c.commit(); c.close()
PY
}
profiles_of() { python3 -I -c 'import json,sqlite3,sys; r=sqlite3.connect(sys.argv[1]).execute("SELECT value_json FROM config_machine_state WHERE state_key=?",("authProfiles.store",)).fetchone(); print(",".join(sorted((json.loads(r[0]).get("profiles") or {}).keys())) if r else "")' "$1"; }
row_of() { python3 -I -c 'import sqlite3,sys; r=sqlite3.connect(sys.argv[1]).execute("SELECT value_json FROM config_machine_state WHERE state_key=?",(sys.argv[2],)).fetchone(); print(r[0] if r else "")' "$1" "$2"; }

OR='{"openrouter:manual":{"type":"api_key","provider":"openrouter","key":"sk-or-test-7101"}}'
ST="$TMP/st"
mkstate "$ST/src.sqlite" "$OR"
mkstate "$ST/nokey.sqlite" ""
py_has() { local r=0; python3 -I -c "$OPENCLAW_STATE_AUTH_PY" has "$1" 2>/dev/null || r=$?; echo $r; }
check "state probe: a db holding a profile has a key" "$(py_has "$ST/src.sqlite")" "0"
check "state probe: a db openclaw only RAN in holds none (rc 3)" "$(py_has "$ST/nokey.sqlite")" "3"

# a. the seat already has its own live db: carry the auth rows only, keep the rest
mkstate "$ST/seatA/openclaw.sqlite" '{"anthropic:manual":{"type":"api_key","provider":"anthropic","key":"sk-ant-own"}}' gateway.pairing
rc=0; openclaw_carry_state_auth "$ST/src.sqlite" "$ST/seatA" "$(id -un)" || rc=$?
check "carry into a live seat db: rc 0" "$rc" "0"
check "carry merges profiles by id (the seat's own login survives)" "$(profiles_of "$ST/seatA/openclaw.sqlite")" "anthropic:manual,openrouter:manual"
has "$(row_of "$ST/seatA/openclaw.sqlite" authProfiles.store)" "sk-or-test-7101" "the carried key is the account's"
check "the seat's own state rows are untouched" "$(row_of "$ST/seatA/openclaw.sqlite" gateway.pairing)" '"seat-own"'
check "auth.sharedStore travels with the key" "$(row_of "$ST/seatA/openclaw.sqlite" auth.sharedStore)" '{"location":"state-db"}'

# b. a seat openclaw has never run in: it takes the snapshot whole, 0600
rc=0; openclaw_carry_state_auth "$ST/src.sqlite" "$ST/seatB" "$(id -un)" || rc=$?
check "carry into a seat with no db: rc 0" "$rc" "0"
check "the new seat db holds the key" "$(profiles_of "$ST/seatB/openclaw.sqlite")" "openrouter:manual"
check "the new seat db is 0600" "$(stat -c %a "$ST/seatB/openclaw.sqlite")" "600"

# c. an account db that holds no key carries nothing and says so (rc 3)
mkstate "$ST/seatC/openclaw.sqlite" "" gateway.pairing
rc=0; openclaw_carry_state_auth "$ST/nokey.sqlite" "$ST/seatC" "$(id -un)" || rc=$?
check "no key in the account: rc 3, nothing written" "$rc:$(profiles_of "$ST/seatC/openclaw.sqlite")" "3:"

# d. a key still in the source's -wal (never checkpointed) is not lost
python3 -I - "$ST/walsrc.sqlite" "$OR" <<'PY'
import json, os, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA wal_autocheckpoint=0")
c.execute("CREATE TABLE config_machine_state (state_key TEXT NOT NULL PRIMARY KEY, value_json TEXT NOT NULL, updated_at_ms INTEGER NOT NULL) STRICT")
c.commit()
c.execute("INSERT INTO config_machine_state VALUES ('authProfiles.store', ?, 3)", (json.dumps({"version": 1, "profiles": json.loads(sys.argv[2])}),))
c.commit()
os._exit(0)   # no close: the row stays in the -wal only
PY
check "fixture: the key row is in the -wal, not yet in the main file" "$( [[ -s "$ST/walsrc.sqlite-wal" ]] && echo yes )" "yes"
rc=0; openclaw_carry_state_auth "$ST/walsrc.sqlite" "$ST/seatD" "$(id -un)" || rc=$?
check "carry reads through the source's -wal" "$rc:$(profiles_of "$ST/seatD/openclaw.sqlite")" "0:openrouter:manual"

# e. the seed helper itself, on the 2026.10.x layout: no agents/main/agent at
# all, the key only in state/. This is the 10-27 QA shape, and it reds on the
# pre-fix helper (it returned at its `-s` guard having copied nothing).
SH7101="$TMP/shared7101"
mkstate "$SH7101/.openclaw/state/openclaw.sqlite" "$OR"
printf '{"auth":{"profiles":{"openrouter:manual":{"provider":"openrouter","mode":"api_key"}}},"agents":{"defaults":{"model":{"primary":"openrouter/auto"}}}}\n' \
  > "$SH7101/.openclaw/openclaw.json"
mkdir -p "$SEATS/agent-oc7101/.openclaw"
printf '{"gateway":{"mode":"local"}}\n' > "$SEATS/agent-oc7101/.openclaw/openclaw.json"
profile_type_dir() { printf '%s' "$SH7101"; }
WARNS=""
AGENT_HOME_ROOT="$SEATS" seed_openclaw_state_into_seat oc7101 theo-or
check "seed: the 2026.10.x key reaches the seat's state db" \
      "$(profiles_of "$SEATS/agent-oc7101/.openclaw/state/openclaw.sqlite" 2>/dev/null)" "openrouter:manual"
hasnt "$WARNS" "could not carry" "seed: no carry warning on the healthy path"

# e2. the create-path witness Olivia trusted ("his own check shows a readable
# key and a model pin"): a seat with the openclaw.json label + pin but a state
# db with no key row is the 10-27 seat, and must be an issue, not ok.
# The witness resolves through _openclaw_cred_path (cmd_auth.sh): without it
# the witness falls back to the legacy path and these arms would grade that.
# shellcheck disable=SC1091
source src/cmd_auth.sh
step() { :; }
declare -F _openclaw_cred_path >/dev/null && echo "ok: witness arms run with the real credential ladder" \
  || { echo "FAIL: _openclaw_cred_path not defined — the witness arms grade nothing"; fail=1; }
mkdir -p "$TMP/label/agent-oclabel/.openclaw"
printf '{"auth":{"profiles":{"openrouter:manual":{"provider":"openrouter","mode":"api_key"}}},"agents":{"defaults":{"model":{"primary":"openrouter/auto"}}}}\n' \
  > "$TMP/label/agent-oclabel/.openclaw/openclaw.json"
mkstate "$TMP/label/agent-oclabel/.openclaw/state/openclaw.sqlite" ""
out=$(AGENT_HOME_ROOT="$TMP/label" selfcheck_cred_reached_agent oclabel openclaw "" openrouter 2>&1)
has "$out" "issue:openclaw credential never reached the seat" \
    "witness: the label without the key row is flagged (the 10-27 false ok)"
out=$(AGENT_HOME_ROOT="$SEATS" selfcheck_cred_reached_agent oc7101 openclaw "" openrouter 2>&1)
has "$out" "ok:openclaw seat has its own credential and model pin" \
    "witness: the seat the 2026.10.x carry produces passes"

# f. 5dive-agent-start carries the same program; drift would make the boot seed
# and the root push disagree about what a key is.
launcher_py=$(awk "/^  OPENCLAW_STATE_AUTH_PY='\$/{on=1; next} on && /^'\$/{exit} on" bin/5dive-agent-start)
check "launcher's state-db program is byte-identical to the CLI's" \
      "$( [[ -n "$launcher_py" && $'\n'"$launcher_py"$'\n' == "$OPENCLAW_STATE_AUTH_PY" ]] && echo same )" "same"

# Verdict shape is load-bearing, not style: tests/meta/harness-verdict-probe.sh
# proves a harness is WIRED by injecting `fail=$((fail+1))` before the verdict and
# asserting the exit status flips. It recognises `exit $(( VAR > 0 ))` (and a few
# siblings) within the last handful of statements; a bare `if (( fail )); then
# exit 1; fi` is UNPROBEABLE — "not counted clean", which is a red check, not a
# green one. Keep the counter numeric-only for the same reason.
if (( fail )); then echo "RESULT: FAIL"; else echo "RESULT: PASS"; fi
exit $(( fail > 0 ))
