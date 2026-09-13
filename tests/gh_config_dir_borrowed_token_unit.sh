#!/usr/bin/env bash
# DIVE-4341 — A RESOLVED TOKEN IS NOT A gh THAT CAN START.
#
# `gh` loads its config file BEFORE it looks at GH_TOKEN. On a provisioned 5dive box
# /etc/profile.d/5dive-shared-configs.sh exports GH_CONFIG_DIR=/home/claude/.config/gh
# to every claude-group login shell and gh pins hosts.yml to 0600, so under any
# agent-<seat> uid every gh invocation exits on
#   failed to load config: open /home/claude/.config/gh/config.yml: permission denied
# with the borrowed token sitting unused in its environment. Measured consequence:
# every agent-seat `task done` on every customer box is recorded UNVERIFIED
# (`partial-repo-scan-0-of-11`), and `merge-gate-selftest` prints
# `[4 sudo -u claude gh auth token] RESOLVED` four lines under `this seat CANNOT query
# GitHub` — it resolves the token and then cannot use it.
#
# WHAT THIS HARNESS GRADES, and it is deliberately two different things:
#  * the PREDICATE (T1-T4, T9): can this uid load a config from <dir>, and does the
#    resolver leave a WORKING seat untouched. The no-change invariant is the one that
#    keeps this from being a risk: if T4 ever goes red the fix has started moving
#    seats that were fine.
#  * the PRODUCT (T5-T7): a gh call made through the gate's own `_gate_gh` with an
#    unreadable shared config dir must still ANSWER, using the borrowed token. The gh
#    stub models real gh — it FAILS on the unreadable dir and succeeds on a readable
#    one — so an arm cannot pass by the substitution merely being attempted.
#
# ROOT CANNOT RUN THE PERMISSION ARMS (DIVE-3729): uid 0 reads a 0000 file, so a run
# as root would pass them for the wrong reason. Every such arm carries a NEGATIVE
# CONTROL that confirms this euid really cannot read the fixture before asserting
# anything, and SKIPs by name when it can.
#
# Isolation: src/ sourced into a throwaway tree, gh and sudo STUBBED on PATH. No
# network, no root, the live tasks.db is never touched.
# Run: bash tests/gh_config_dir_borrowed_token_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gh-cfgdir-unit.XXXXXX)"
mkdir -p "$TMP/bin"

# --- stub gh: MODELS THE REAL FAILURE. It reads GH_CONFIG_DIR the way gh does and
# exits 1 with gh's own wording when it cannot open config.yml there. Without that the
# harness would grade "the variable was set" instead of "the call answered", and the
# whole ticket is the gap between those two.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'CFG=%s TOKEN=%s ARGS=%s\n' "${GH_CONFIG_DIR:-<unset>}" "${GH_TOKEN:+set}" "$*" >>"$GH_ARGS_LOG"
d="${GH_CONFIG_DIR:-$HOME/.config/gh}"
if [[ -e "$d/config.yml" && ! -r "$d/config.yml" ]]; then
  echo "failed to create root command: failed to read configuration: open $d/config.yml: permission denied" >&2
  exit 1
fi
if [[ "$1" == "auth" && "$2" == "token" ]]; then
  printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; [[ -n "${GH_STUB_AUTH_TOKEN:-}" ]] || exit 1; exit 0
fi
[[ -n "${GH_TOKEN:-}" ]] || exit 1
printf '%s' "${GH_STUB_BODY:-MERGED}"
STUB
chmod +x "$TMP/bin/gh"

# --- stub sudo: `-u claude gh auth token` yields a token only when SUDO_CLAUDE_TOKEN
# is set (the borrow this ticket is about); `-n -l` refuses, so the bot rail is absent
# unless an arm asks for it.
cat >"$TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" && "${2:-}" == "-u" && "${3:-}" == "claude" ]]; then
  [[ -n "${SUDO_CLAUDE_TOKEN:-}" ]] || exit 1
  printf '%s\n' "$SUDO_CLAUDE_TOKEN"; exit 0
fi
if [[ "${1:-}" == "-n" && "${2:-}" == "-l" ]]; then
  [[ -n "${SUDO_BOT_RAIL:-}" ]] || exit 1
  exit 0
fi
exit 1
STUB
chmod +x "$TMP/bin/sudo"

export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/gh_config.sh lib/agent_setup.sh lib/state.sh lib/broker.sh \
         lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh \
         cmd_push.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
skip_t() { SKIP=$((SKIP+1)); printf 'SKIP - %s\n   %s\n' "$1" "${2:-}"; }

# The resolver memoises per process; every arm below re-asks, so clear it.
reset_cfg() { _FIVE_GH_CFG_DIR=""; _FIVE_GH_CFG_SHADOWED=""; : >"$GH_ARGS_LOG"; }

# --- fixtures ----------------------------------------------------------------
# SHARED: the customer shape — a config dir holding an unreadable config.yml.
SHARED="$TMP/shared/gh"; mkdir -p "$SHARED"
printf 'version: 1\n' >"$SHARED/config.yml"; printf 'github.com:\n' >"$SHARED/hosts.yml"
chmod 0000 "$SHARED/config.yml" "$SHARED/hosts.yml"
# OPEN: a config dir this uid can read, i.e. every seat on which gh works today.
OPEN="$TMP/open/gh"; mkdir -p "$OPEN"
printf 'version: 1\n' >"$OPEN/config.yml"; chmod 0644 "$OPEN/config.yml"
# A HOME this seat owns, for the substitution to land in.
SEATHOME="$TMP/home"; mkdir -p "$SEATHOME"

# NEGATIVE CONTROL (DIVE-3729): root reads a 0000 file, so the permission arms would
# pass for the wrong reason. Confirm this euid really cannot read the fixture.
CAN_READ_0000=0
cat "$SHARED/config.yml" >/dev/null 2>&1 && CAN_READ_0000=1
perm_arms_run() {
  (( CAN_READ_0000 == 0 )) && return 0
  return 1
}

# --- T1: an ABSENT dir is usable when its parent is writable ------------------
# gh creates the dir on first run. Rendering absent as unusable would push a fresh
# seat with no gh state onto the substitution path for no reason.
if gh_config_dir_usable "$TMP/nothing-here/gh"; then
  ok_t "T1 absent config dir with a writable parent is USABLE"
else
  bad_t "T1 absent config dir with a writable parent is USABLE" "predicate said no"
fi

# --- T2: a readable dir is usable --------------------------------------------
if gh_config_dir_usable "$OPEN"; then
  ok_t "T2 a config dir whose config.yml is readable is USABLE"
else
  bad_t "T2 a config dir whose config.yml is readable is USABLE" "predicate said no"
fi

# --- T3: THE DEFECT. An existing-but-unreadable config.yml is NOT usable ------
if perm_arms_run; then
  if gh_config_dir_usable "$SHARED"; then
    bad_t "T3 a config dir with an unreadable config.yml is NOT usable" \
          "predicate said yes — this is the shape that kills gh on every customer box"
  else
    ok_t "T3 a config dir with an unreadable config.yml is NOT usable"
  fi
else
  skip_t "T3 a config dir with an unreadable config.yml is NOT usable" \
         "this euid CAN read a 0000 file (running as root?) — the fixture cannot express the defect"
fi

# --- T4: THE NO-CHANGE INVARIANT. A seat whose dir works is left ALONE --------
# If this ever goes red the fix has started relocating seats that were already fine,
# which is the only way it could break something.
reset_cfg
GH_CONFIG_DIR="$OPEN" gh_config_dir >"$TMP/t4" 2>&1
reset_cfg
got=$(GH_CONFIG_DIR="$OPEN"; export GH_CONFIG_DIR; _FIVE_GH_CFG_DIR=""; _FIVE_GH_CFG_SHADOWED=""; gh_config_dir)
if [[ "$got" == "$OPEN" ]]; then
  ok_t "T4 a readable config dir is returned UNCHANGED (no seat that works today moves)"
else
  bad_t "T4 a readable config dir is returned UNCHANGED" "got '$got', want '$OPEN'"
fi
shadow=$( GH_CONFIG_DIR="$OPEN" HOME="$SEATHOME" bash -c '
  cd '"$PWD"'; . src/lib/gh_config.sh; gh_config_dir >/dev/null; gh_config_dir_shadowed && echo yes || echo no' )
if [[ "$shadow" == "no" ]]; then
  ok_t "T4b and it does not report itself SHADOWED"
else
  bad_t "T4b and it does not report itself SHADOWED" "got '$shadow'"
fi

# --- T5: the substitution lands somewhere this uid OWNS and nobody can plant in
if perm_arms_run; then
  sub=$( GH_CONFIG_DIR="$SHARED" HOME="$SEATHOME" bash -c '
    cd '"$PWD"'; . src/lib/gh_config.sh; gh_config_dir' )
  if [[ -n "$sub" && "$sub" != "$SHARED" ]]; then
    ok_t "T5 an unreadable shared config dir is SUBSTITUTED ($sub)"
  else
    bad_t "T5 an unreadable shared config dir is SUBSTITUTED" "got '$sub'"
  fi
  mode=$(stat -c '%a' "$sub" 2>/dev/null || echo "")
  owner=$(stat -c '%u' "$sub" 2>/dev/null || echo "")
  if [[ -n "$mode" ]] && (( (8#0$mode & 0022) == 0 )) && [[ "$owner" == "$(id -u)" ]]; then
    ok_t "T5b the substitute is owned by this uid and not group/other-writable (mode $mode)"
  else
    bad_t "T5b the substitute is owned by this uid and not group/other-writable" \
          "mode='$mode' owner='$owner' uid='$(id -u)' — a plantable dir is the same cross-seat exposure the chmod route was rejected for"
  fi
else
  skip_t "T5 an unreadable shared config dir is SUBSTITUTED" "euid reads 0000 files"
  skip_t "T5b the substitute is owned by this uid and not group/other-writable" "euid reads 0000 files"
fi

# --- T6: THE PRODUCT ARM. The gate's own gh call ANSWERS with the borrowed token
# despite the unreadable shared dir. The stub fails exactly as real gh does, so this
# cannot pass on the substitution being attempted — only on it working.
if perm_arms_run; then
  reset_cfg
  out=$( GH_CONFIG_DIR="$SHARED" HOME="$SEATHOME" GH_STUB_BODY="MERGED" \
         bash -c 'cd '"$PWD"'; set +u
           for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/gh_config.sh \
                    lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
                    lib/tasks_db.sh lib/actor.sh cmd_push.sh cmd_task.sh; do source "src/$f"; done
           _gate_gh "borrowed-tok" 0 pr view https://github.com/o/r/pull/1 --json state' 2>/dev/null )
  if [[ "$out" == "MERGED" ]]; then
    ok_t "T6 _gate_gh ANSWERS with the borrowed token under an unreadable shared config dir"
  else
    bad_t "T6 _gate_gh ANSWERS with the borrowed token under an unreadable shared config dir" \
          "got '$out' — this is the customer's partial-repo-scan-0-of-N"
  fi
  # The other half of the same arm: the token really was the thing that authenticated,
  # and the config dir really was rewritten in the child's environment.
  if grep -q "TOKEN=set" "$GH_ARGS_LOG" 2>/dev/null && ! grep -q "CFG=$SHARED" "$GH_ARGS_LOG" 2>/dev/null; then
    ok_t "T6b gh saw the token AND a rewritten GH_CONFIG_DIR"
  else
    bad_t "T6b gh saw the token AND a rewritten GH_CONFIG_DIR" "$(cat "$GH_ARGS_LOG" 2>/dev/null)"
  fi
else
  skip_t "T6 _gate_gh ANSWERS with the borrowed token under an unreadable shared config dir" "euid reads 0000 files"
  skip_t "T6b gh saw the token AND a rewritten GH_CONFIG_DIR" "euid reads 0000 files"
fi

# --- T7: THE CONTROL. Without the substitution the same call DIES ---------------
# Proves the fixture expresses the defect rather than the harness being generous: run
# the identical call with GH_CONFIG_DIR forced to the unreadable dir at the gh layer.
if perm_arms_run; then
  : >"$GH_ARGS_LOG"
  cout=$( GH_CONFIG_DIR="$SHARED" GH_TOKEN="borrowed-tok" gh pr view https://github.com/o/r/pull/1 --json state 2>&1 )
  crc=$?
  if (( crc != 0 )) && [[ "$cout" == *"permission denied"* ]]; then
    ok_t "T7 CONTROL: the same call with the unreadable dir still in place DIES on the config read"
  else
    bad_t "T7 CONTROL: the same call with the unreadable dir still in place DIES on the config read" \
          "rc=$crc out='$cout' — the fixture is not expressing the defect, so T6 proves nothing"
  fi
else
  skip_t "T7 CONTROL: the same call with the unreadable dir still in place DIES" "euid reads 0000 files"
fi

# --- T8: the preflight stops crying wolf, and still fires when it should --------
# `task start` warned "a push will prompt/fail" on every agent seat of every box.
rail=$( SUDO_CLAUDE_TOKEN="ghp_borrowed" GH_STUB_AUTH_TOKEN="" GH_CONFIG_DIR="$SHARED" HOME="$SEATHOME" \
        bash -c 'cd '"$PWD"'; unset GH_TOKEN GITHUB_TOKEN; . src/lib/gh_config.sh; gh_credential_rail' )
if [[ "$rail" == "claude" ]]; then
  ok_t "T8 a seat with no login of its own but a working claude borrow reports rail=claude (no warning)"
else
  bad_t "T8 a seat with no login of its own but a working claude borrow reports rail=claude" "got '$rail'"
fi
rail=$( GH_STUB_AUTH_TOKEN="" GH_CONFIG_DIR="$SHARED" HOME="$SEATHOME" \
        bash -c 'cd '"$PWD"'; unset GH_TOKEN GITHUB_TOKEN SUDO_CLAUDE_TOKEN SUDO_BOT_RAIL; . src/lib/gh_config.sh; gh_credential_rail' )
if [[ "$rail" == "none" ]]; then
  ok_t "T8b a seat with NO rail at all still reports none (the warning is not simply deleted)"
else
  bad_t "T8b a seat with NO rail at all still reports none" "got '$rail'"
fi
rail=$( GH_TOKEN="tok" bash -c 'cd '"$PWD"'; . src/lib/gh_config.sh; gh_credential_rail' )
if [[ "$rail" == "env" ]]; then
  ok_t "T8c an explicit GH_TOKEN short-circuits to rail=env without paying a sudo"
else
  bad_t "T8c an explicit GH_TOKEN short-circuits to rail=env" "got '$rail'"
fi

# --- T9: THE TRAP main CAUGHT. A group-writable seat dir is NOT adopted ----------
# The on-host fix's first staging inherited `umask 002` and created the per-seat gh
# dir 0775 group `claude` — any sibling seat could plant a hosts.yml there and
# redirect this seat's gh to a token of its choosing. The `-d` short-circuit means an
# already-wrong dir is never re-created, so the ownership/mode check is what refuses.
PLANTED="$TMP/planted/gh"; mkdir -p "$PLANTED"; chmod 0775 "$PLANTED"
if _gh_cfg_owned_private "$PLANTED"; then
  bad_t "T9 a group-writable dir is NOT trusted as the seat's config dir" \
        "trusted a 0775 dir — that is the cross-seat exposure in the other direction"
else
  ok_t "T9 a group-writable dir is NOT trusted as the seat's config dir"
fi
chmod 0700 "$PLANTED"
if _gh_cfg_owned_private "$PLANTED"; then
  ok_t "T9b and a 0700 dir this uid owns IS trusted (the check is not vacuous)"
else
  bad_t "T9b and a 0700 dir this uid owns IS trusted" "refused a dir it should accept"
fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
