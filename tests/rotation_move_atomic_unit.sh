#!/usr/bin/env bash
# DIVE-7747: an account move is all or nothing. On teal-fox 2026-11-04 three
# rotation seats had a registry that named the new account while the agents.d
# env file, the -auth.env link and the live process stayed on the old one: the
# rotate (fired by the seat's own StopFailure hook under an 8s timeout) was cut
# between the registry write and the env rewrite. This drives the REAL
# cmd_agent_rotation_rotate -> cmd_config -> write_agent_env/link_agent_profile
# path against a temp registry, env dir and profile dir, and cuts it on purpose.
#
# Arms:
#   A  a clean wall rotate: registry, env and link all name the target, the
#      restart is queued, rotated:true
#   P  stderr closes right after the registry write (the hook stopped reading):
#      afterwards registry == env == link
#   T  SIGTERM to the process group right after the registry write (a timeout
#      kill): afterwards registry == env == link
#   L  the link step fails: rotated:false naming "auth link"; registry, env and
#      link back on the old account; a rollback binding event; no restart
#   R  the restart cannot be queued: rotated:false naming "restart", rolled back
#   S  the same pipe/terminate cuts on `config set auth-profile=` (the call
#      set-account makes), under errexit like production: registry == env == link
#   D  drift is visible (agent_profile_drift) and re-setting the registry's
#      account heals it (env + link follow, restart queued)
#
# NEGATIVE CONTROL: PREFIX_TREE=<ref> (e.g. origin/main) sources output.sh,
# cmd_config and the rotate from that ref instead of the worktree. Arms P, T and L must go red
# there: the registry drifts from the env. So must S/pipe: on the base tree a
# `step` write to the closed stderr exits the verb after the registry write. The driver reads the files itself,
# so the control does not depend on any helper this fix adds.
#
# Run: bash tests/rotation_move_atomic_unit.sh  (no root, no network)
# TIER: core — 4.0s measured on the dev seat
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
ROOT=$PWD
TMP=$(mktemp -d /tmp/rotation-move-atomic.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
[[ -n "${PREFIX_TREE:-}" ]] && echo "NEGATIVE CONTROL: cmd_config + rotate from ${PREFIX_TREE}"

PASS=0; FAIL=0
t() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; else
    FAIL=$((FAIL+1)); printf 'FAIL %s — expected %s, got %s\n' "$1" "$2" "$3" >&2
  fi
}

# ── the driver: one rotate in its own process (and process group) ───────────
DRIVER="$TMP/driver.sh"
cat >"$DRIVER" <<'DRV'
set -uo pipefail
cd "$ROOT"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/actor.sh \
         lib/state.sh lib/registry.sh cmd_agent_create.sh; do
  source "src/$f"
done
if [[ -n "${PREFIX_TREE:-}" ]]; then
  source <(git show "${PREFIX_TREE}:src/lib/output.sh")   # step/warn as they were
  source <(git show "${PREFIX_TREE}:src/cmd_agent_config.sh")
  source <(git show "${PREFIX_TREE}:src/cmd_account.sh")
else
  source src/cmd_agent_config.sh
  source src/cmd_account.sh
fi
# PRODUCTION'S SHELL OPTIONS. src/header.sh runs every verb under
# `set -euo pipefail`; iteration 1 of this driver did `set +e` here, which hid
# the cut that kills `config set`/`set-account` (a `step` write to a closed
# stderr returned 1 and errexit exited after the registry write). Never relax it.
set -euo pipefail
ENV_DIR="$T/agents.d"; AUTH_PROFILES_DIR="$T/profiles"; STATE_DIR="$T/state"
REG="$T/agents.json"
require_root()   { :; }
ensure_state()   { :; }
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }
registry_read()  { cat "$REG"; }
chown() { :; }
switch_target_for_account() { :; }
resolve_agent_model() { :; }
account_has_live_headroom() { [[ "$1" == roomy ]]; }
account_near_wall_state() { printf unmeasured; }
usage_agent_home() { printf '%s/home/agent-%s\n' "$T" "$1"; }
model_family_of() { :; }
account_binding_record() { printf '%s %s\n' "$2" "$3" >>"$T/bindings"; }
systemd-run() {
  [[ "${CUT:-}" == restart ]] && return 1
  printf 'restart %s\n' "${*: -1}" >>"$T/restarts"
}
# The cut lands right after the write that moves authProfile, i.e. between
# registry_write and write_agent_env: the window the row names.
registry_write() {
  cat >"$REG.tmp" && mv "$REG.tmp" "$REG"
  if [[ ! -e "$T/cut-fired" && "$(jq -r '.agents.seat.authProfile' "$REG")" == roomy ]]; then
    : >"$T/cut-fired"
    case "${CUT:-}" in
      # The reader of our stderr goes away (the hook gave up). registry_write
      # runs in a pipeline subshell, so the cut is to KILL that reader, not to
      # redirect this subshell's own fd 2.
      pipe) kill "$(cat "$T/reader.pid")"; sleep 0.3 ;;
      term) kill -TERM -- "-$$" ;;    # a timeout kill of the whole group
    esac
  fi
  return 0
}
if [[ "${CUT:-}" == link ]]; then
  link_agent_profile() { rm -f "${ENV_DIR}/${1}-auth.env"; [[ -z "${2:-}" || "$2" != roomy ]] || return 1
                         ln -s "${AUTH_PROFILES_DIR}/${2}/combined.env" "${ENV_DIR}/${1}-auth.env"; }
fi
if [[ "${VERB:-rotate}" == heal ]]; then
  JSON_MODE=1 cmd_config seat set "auth-profile=$(jq -r '.agents.seat.authProfile' "$REG")"
elif [[ "${VERB:-rotate}" == set ]]; then
  # `5dive agent config <n> set auth-profile=` / `set-account`: cmd_config in the
  # verb's own shell, no subshell around it (unlike the rotate), so errexit is live.
  JSON_MODE=1 cmd_config seat set auth-profile=roomy
else
  JSON_MODE=1 cmd_agent_rotation_rotate seat "--wall=$(( $(date +%s) + 6000 ))"
fi
DRV

seed() {   # registry, env and link all on "walled"
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/agents.d" "$d/state" "$d/profiles/walled" "$d/profiles/roomy"
  : >"$d/profiles/walled/combined.env"; : >"$d/profiles/roomy/combined.env"
  jq -cn '{agents:{seat:{type:"claude", channels:"none", authProfile:"walled",
           rotation:{enabled:true, accounts:["walled","roomy"], cooldowns:{}}}}}' >"$d/agents.json"
  printf 'AGENT_NAME=seat\nAGENT_TYPE=claude\nAGENT_CHANNELS=none\nAGENT_AUTH_PROFILE=walled\nAGENT_ISOLATION=standard\n' \
    >"$d/agents.d/seat.env"
  ln -s "$d/profiles/walled/combined.env" "$d/agents.d/seat-auth.env"
}
run() {   # <arm-dir> [CUT] -> envelope on stdout
  local d="$1"; shift
  if [[ " $* " == *" CUT=pipe "* ]]; then
    # stderr is a PIPE whose reader the cut kills: the hook's shape, where the
    # caller timed out and nobody reads the root half's stderr any more.
    ( cd "$d" && env ROOT="$ROOT" T="$d" PREFIX_TREE="${PREFIX_TREE:-}" "$@" \
        setsid bash "$DRIVER" 2> >(echo "$BASHPID" >"$d/reader.pid"; exec cat >>"$d/stderr") ) || true
    sleep 0.2
  else
    ( cd "$d" && env ROOT="$ROOT" T="$d" PREFIX_TREE="${PREFIX_TREE:-}" "$@" \
        setsid bash "$DRIVER" 2>"$d/stderr" ) || true
  fi
}
reg_of()  { jq -r '.agents.seat.authProfile // "-"' "$1/agents.json"; }
env_of()  { sed -n 's/^AGENT_AUTH_PROFILE=//p' "$1/agents.d/seat.env" | head -n1; }
link_of() { local l; l=$(readlink "$1/agents.d/seat-auth.env" 2>/dev/null) || { echo -; return; }; basename "$(dirname "$l")"; }
agree()   { [[ "$(reg_of "$1")" == "$(env_of "$1")" && "$(env_of "$1")" == "$(link_of "$1")" ]] && echo agree \
              || echo "drift(registry=$(reg_of "$1") env=$(env_of "$1") link=$(link_of "$1"))"; }
J() { jq -r "$2" <<<"$1" 2>/dev/null | tail -n1; }

# ── A: the clean move ────────────────────────────────────────────────────────
D="$TMP/a"; seed "$D"; OUT=$(run "$D")
t "A clean wall rotate says rotated" "true" "$(J "$OUT" '.data.rotated')"
t "A registry, env and link agree" "agree" "$(agree "$D")"
t "A they agree on the target" "roomy" "$(env_of "$D")"
t "A the restart is queued" "1" "$(grep -c '^restart 5dive-agent@seat' "$D/restarts" 2>/dev/null || echo 0)"

# ── P: stderr closes between registry write and env rewrite ─────────────────
D="$TMP/p"; seed "$D"; OUT=$(run "$D" CUT=pipe)
t "P the cut fired" "yes" "$([[ -e "$D/cut-fired" ]] && echo yes || echo no)"
t "P closed stderr: registry == env == link afterwards" "agree" "$(agree "$D")"
t "P the move that went on to finish queued its restart" \
  "$([[ "$(reg_of "$D")" == roomy ]] && echo 1 || echo 0)" \
  "$(grep -c '^restart' "$D/restarts" 2>/dev/null || echo 0)"

# ── T: SIGTERM between registry write and env rewrite ───────────────────────
D="$TMP/t"; seed "$D"; OUT=$(run "$D" CUT=term)
t "T the cut fired" "yes" "$([[ -e "$D/cut-fired" ]] && echo yes || echo no)"
t "T terminate: registry == env == link afterwards" "agree" "$(agree "$D")"

# ── L: the link step fails ───────────────────────────────────────────────────
D="$TMP/l"; seed "$D"; OUT=$(run "$D" CUT=link)
t "L a failed link: registry == env == link afterwards" "agree" "$(agree "$D")"
t "L ...on the account it left" "walled" "$(reg_of "$D")"
t "L rotated:false" "false" "$(J "$OUT" '.data.rotated')"
t "L the envelope names the step" "auth link" "$(J "$OUT" '.data.failedStep')"
t "L the binding history records the move AND its rollback" "roomy rotation|walled rotation-rollback" \
  "$(paste -sd'|' "$D/bindings" 2>/dev/null)"
t "L no restart queued" "0" "$(grep -c '^restart' "$D/restarts" 2>/dev/null || echo 0)"

# ── R: the restart cannot be queued ─────────────────────────────────────────
D="$TMP/r"; seed "$D"; OUT=$(run "$D" CUT=restart)
t "R an unqueued restart: registry == env == link afterwards" "agree" "$(agree "$D")"
t "R ...on the account it left" "walled" "$(reg_of "$D")"
t "R rotated:false naming the restart" "false:restart" "$(J "$OUT" '.data.rotated'):$(J "$OUT" '.data.failedStep')"

# ── S: the same cuts on `config set auth-profile=` (and set-account, which is
#    this call), under production's errexit with no subshell to absorb an exit
D="$TMP/sp"; seed "$D"; OUT=$(run "$D" VERB=set CUT=pipe)
t "S/pipe the cut fired" "yes" "$([[ -e "$D/cut-fired" ]] && echo yes || echo no)"
t "S/pipe config set, closed stderr: registry == env == link afterwards" "agree" "$(agree "$D")"
t "S/pipe ...and the restart that makes the process read them is queued" \
  "$([[ "$(reg_of "$D")" == roomy ]] && echo 1 || echo 0)" \
  "$(grep -c '^restart' "$D/restarts" 2>/dev/null || echo 0)"
D="$TMP/st"; seed "$D"; OUT=$(run "$D" VERB=set CUT=term)
t "S/term config set, terminate: registry == env == link afterwards" "agree" "$(agree "$D")"
D="$TMP/sc"; seed "$D"; OUT=$(run "$D" VERB=set)
t "S/clean config set moves all three onto the target" "agree:roomy" "$(agree "$D"):$(env_of "$D")"
t "S/clean ...and queues the restart" "1" "$(grep -c '^restart' "$D/restarts" 2>/dev/null || echo 0)"

# ── D: drift is visible and re-setting the same account heals it ────────────
if [[ -z "${PREFIX_TREE:-}" ]]; then
  D="$TMP/d"; seed "$D"
  # claude-swan's shape: the registry moved, env and link never did.
  jq '.agents.seat.authProfile = "roomy"' "$D/agents.json" >"$D/x" && mv "$D/x" "$D/agents.json"
  DRIFT=$( ( ENV_DIR="$D/agents.d"; source src/cmd_account.sh; agent_profile_drift seat roomy; echo "rc=$?" ) )
  t "D drift is flagged with all three names" "registry=roomy env=walled link=walled|rc=1" "$(paste -sd'|' <<<"$DRIFT")"
  OUT=$(run "$D" VERB=heal)
  t "D re-setting the registry's account heals it" "agree" "$(agree "$D")"
  t "D ...onto the registry's account" "roomy" "$(env_of "$D")"
  t "D ...and restarts the seat onto it" "1" "$(grep -c '^restart' "$D/restarts" 2>/dev/null || echo 0)"
  CLEAN=$( ( ENV_DIR="$D/agents.d"; source src/cmd_account.sh; agent_profile_drift seat roomy; echo "rc=$?" ) )
  t "D after the heal no drift is flagged" "rc=0" "$CLEAN"
  UNREAD=$( ( ENV_DIR="$TMP/nonexistent"; source src/cmd_account.sh; agent_profile_drift seat roomy; echo "rc=$?" ) )
  t "D unreadable files are unmeasured, not drift" "rc=2" "$UNREAD"
fi

echo "rotation_move_atomic_unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
