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
# defect ride a full upstream release invisibly. Four arms, in both directions:
#   1. 2026.8.1 layout, credential written  -> ok            (the regression)
#   2. pre-2026.8.1 layout, credential      -> ok            (fallback intact)
#   3. 2026.8.1 layout, NO credential       -> needs_login   (the ABSENT case:
#      openclaw.json exists and the old dir exists-but-empty, i.e. everything
#      the tree-shape looks-right test would pass. DIVE-3130's lesson is that a
#      guard which cannot fire on absence is not a guard.)
#   4. the app's own lazily-created store alone -> needs_login (it is created by
#      openclaw having RUN, not by having AUTHENTICATED, so it must not be
#      admitted as a credential rung).
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
         lib/agent_setup.sh lib/state.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

AUTH_PROFILES_DIR="$TMP/auth-profiles"
CONNECTORS_DIR="$TMP/connectors"
mkdir -p "$CONNECTORS_DIR" "$AUTH_PROFILES_DIR"

declare -A TYPE_AUTH=(
  [openclaw]="$TMP/home/claude/.openclaw/agents/main/agent/openclaw-agent.sqlite"
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

# --- arm 1: openclaw 2026.8.1 layout with a real BYO credential --------------
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

# --- arm 2: pre-2026.8.1 layout still passes (fallback intact) ---------------
p=old-authed
root="$AUTH_PROFILES_DIR/$p/openclaw"
mkdir -p "$root/.openclaw/agents/main/agent"
printf 'SQLite format 3\0' > "$root/.openclaw/agents/main/agent/openclaw-agent.sqlite"
if auth_creds_present openclaw "$p"; then ok "pre-2026.8.1 layout: auth_creds_present"
else bad "pre-2026.8.1 layout: regressed to ABSENT — the fix swapped the path instead of laddering"; fi
s=$(state_of "$p")
[[ "$s" == ok ]] && ok "pre-2026.8.1 layout: state=ok" \
                 || bad "pre-2026.8.1 layout: state=$s, want ok"

# --- arm 3: the ABSENT case on 2026.8.1 must still fire ----------------------
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

# --- arm 4: openclaw's own lazily-created store is not a credential ----------
p=new-ran-only
root="$AUTH_PROFILES_DIR/$p/openclaw"
mkdir -p "$root/.openclaw/agents/main/agent" "$root/.openclaw/state"
printf 'SQLite format 3\0' > "$root/.openclaw/state/openclaw.sqlite"
if auth_creds_present openclaw "$p"; then
  bad "app store only: reported PRESENT — 'openclaw has run' is not 'openclaw is authed'"
else ok "app store only: auth_creds_present says absent"; fi

# --- arm 5: an empty auth.profiles map is not a credential -------------------
p=new-empty-map
root="$AUTH_PROFILES_DIR/$p/openclaw"
mkdir -p "$root/.openclaw/agents/main/agent"
echo '{"auth":{"profiles":{}}}' > "$root/.openclaw/openclaw.json"
if auth_creds_present openclaw "$p"; then
  bad "empty auth.profiles: reported PRESENT — gated on the file, not the map"
else ok "empty auth.profiles: auth_creds_present says absent"; fi

if (( fails )); then printf '\nFAIL: %d assertion(s)\n' "$fails"; exit 1; fi
printf '\nPASS: openclaw auth layout ladder\n'
