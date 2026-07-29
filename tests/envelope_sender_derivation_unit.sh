#!/usr/bin/env bash
# DIVE-2281 — auto_sender_from_sudo must identify the REAL caller on EVERY path.
#
# THE DEFECT THIS GRADES: the function read only $SUDO_USER, which is set only when
# the caller reached us THROUGH sudo. The scoped a2a path does (it execs
# `sudo -n … agent _deliver`), but a FULL-TRUST agent runs `5dive agent send` as
# itself, so SUDO_USER is unset and this returned "". An empty sender skips the
# envelope block in cmd_send entirely, so the most privileged sender on the box
# produced a message with NO `[5dive-msg …]` header at all — byte-indistinguishable
# from the paired human typing into that pane.
#
# Measured on the real box 2026-07-29 before the fix: agent-main (NOPASSWD:ALL,
# isolation=admin) sent on the direct path; the receiving pane showed `❯ <message>`
# and ZERO occurrences of `5dive-msg`.
#
# So the trust gradient ran BACKWARDS: the sender that cannot forge --from arrived
# with a real tier; the sender that can forge it arrived with none.
#
# `id -un` is the right source because it is not caller-supplied and cannot be set
# by an argument. SUDO_USER stays FIRST: under `sudo 5dive …` the meaningful
# identity is the invoker, not root.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# shellcheck disable=SC1091
source "$ROOT/src/lib/validation.sh"

# Stub `id` so we can drive the non-sudo identity deterministically. A PATH shim
# is used rather than a function override because the code under test calls `id`
# as a command, and a harness that stubs something the code does not actually
# invoke grades nothing.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/id" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-un" ]] && { printf '%s\n' "${FAKE_WHOAMI:-root}"; exit 0; }
exec /usr/bin/id "$@"
STUB
chmod +x "$TMP/bin/id"
PATH="$TMP/bin:$PATH"

# Non-vacuity canary: the stub must actually be the `id` that answers, or every
# arm below is measuring /usr/bin/id and the suite is theatre.
# NOTE the assignment form: `VAR=x got="$(cmd)"` is TWO ASSIGNMENTS, not a command
# prefix, so VAR never reaches the subshell — the first cut of this canary did
# exactly that and reported the stub missing while the stub was working fine. A
# canary that fails for its own reasons is worse than none: it would have sent the
# next reader hunting a PATH problem that does not exist.
got="$(FAKE_WHOAMI=agent-canary id -un)"
[[ "$got" == "agent-canary" ]] \
  && ok_t 'CANARY: the id stub is on PATH and answering (arms below are real)' \
  || bad_t 'CANARY: id stub not in effect — every arm below is vacuous' "got=$got"

run() { # run <SUDO_USER-or-EMPTY> <fake-whoami>
  local su="$1" who="$2"
  if [[ -z "$su" ]]; then
    env -u SUDO_USER FAKE_WHOAMI="$who" PATH="$PATH" bash -c \
      "source '$ROOT/src/lib/validation.sh'; auto_sender_from_sudo"
  else
    env SUDO_USER="$su" FAKE_WHOAMI="$who" PATH="$PATH" bash -c \
      "source '$ROOT/src/lib/validation.sh'; auto_sender_from_sudo"
  fi
}

# --- T1 REGRESSION GUARD: the sudo path is unchanged and still wins -----------
got="$(run 'agent-scoped' 'root')"
[[ "$got" == "scoped" ]] \
  && ok_t 'T1 sudo caller still resolves from SUDO_USER (scoped/_deliver path unchanged)' \
  || bad_t 'T1 SUDO_USER path regressed' "got='$got' want='scoped'"

# --- T2 THE FIX: full-trust agent, NO sudo, must now identify itself ----------
got="$(run '' 'agent-main')"
[[ "$got" == "main" ]] \
  && ok_t 'T2 FIX: no SUDO_USER but running AS agent-main -> "main" (was "" = no envelope at all)' \
  || bad_t 'T2 the direct-path caller is still unidentified' "got='$got' want='main'"

# --- T3 SUDO_USER present but NOT an agent -> fall through to the real self ---
# `sudo` from a human shell into an agent context: SUDO_USER=claude is not an
# agent, and the old code stopped there. The running identity is what matters.
got="$(run 'claude' 'agent-dev')"
[[ "$got" == "dev" ]] \
  && ok_t 'T3 non-agent SUDO_USER falls through to the real running identity' \
  || bad_t 'T3 non-agent SUDO_USER did not fall through' "got='$got' want='dev'"

# --- T4 HUMAN keeps the unenveloped shape (this is the behaviour to PRESERVE) -
got="$(run '' 'claude')"
[[ -z "$got" ]] \
  && ok_t 'T4 a human (claude) still returns EMPTY — unenveloped shape preserved' \
  || bad_t 'T4 a human was given an agent identity' "got='$got' want=''"

# --- T5 ROOT/cron keeps returning empty --------------------------------------
# _deliver runs as root WITH SUDO_USER=agent-X, so it resolves via T1. A bare root
# caller (cron, systemd) has no agent identity and must not invent one.
got="$(run '' 'root')"
[[ -z "$got" ]] \
  && ok_t 'T5 bare root/cron returns EMPTY (no invented identity)' \
  || bad_t 'T5 root was given an identity' "got='$got' want=''"

# --- T6 a nobody-user is not an agent ----------------------------------------
got="$(run '' 'nobody')"
[[ -z "$got" ]] \
  && ok_t 'T6 a non-agent system user returns EMPTY' \
  || bad_t 'T6 non-agent user leaked an identity' "got='$got' want=''"

# --- T7 the label is the SUFFIX, not the whole username ----------------------
got="$(run '' 'agent-main2')"
[[ "$got" == "main2" ]] \
  && ok_t 'T7 the agent- prefix is stripped, digits preserved' \
  || bad_t 'T7 prefix stripping wrong' "got='$got' want='main2'"

echo "-----"
echo "envelope_sender_derivation_unit: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
