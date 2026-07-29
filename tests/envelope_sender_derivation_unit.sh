#!/usr/bin/env bash
# DIVE-2281 — the envelope's sender must be derived from an identity the CALLER
# CANNOT CHOOSE.
#
# THE DEFECT: auto_sender_from_sudo read only $SUDO_USER, set only when the caller
# reached the CLI THROUGH sudo. The scoped a2a path always does; a full-trust agent
# running `5dive agent send` as itself does not. An empty sender skips the envelope
# block in cmd_send ENTIRELY, so the most privileged sender on the box produced a
# message with NO `[5dive-msg …]` header — byte-indistinguishable from the paired
# human typing into that pane. Measured against a live pane before the fix.
#
# THE TWO FORGERY VECTORS THIS PINS, both demonstrated by running them:
#   1. A bare `id -un` resolves through the caller's PATH. The FIRST cut of this fix
#      used one, and this harness drove it with a PATH shim — i.e. the test
#      PERFORMED the attack while asserting the function was sound. Caught by olivia
#      from DIVE-1401, where she had retracted a PASS over exactly this.
#   2. $SUDO_USER is just an environment variable, and this was PRE-EXISTING. Under
#      sudo it is safe (sudo sets it itself under env_reset); on the direct path
#      nothing sanitises it, so `tier=` — documented as "the one unforgeable field
#      in [5dive-msg …]" — was already forgeable by anyone who could set an env var.
#
# $EUID is a bash BUILTIN: not PATH-resolved, not settable from the environment.
# T2-T4 are ADVERSARIAL — they run the actual attacks and require the REAL identity
# to come back anyway.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/src/lib/validation.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# shellcheck disable=SC1091
source "$LIB"

# Fixture passwd. Reserved-fake values only — never a real account's numbers.
FIX="$TMP/passwd"
cat >"$FIX" <<'EOF'
root:x:0:0:root:/root:/bin/bash
somehuman:x:4000:4000:somehuman:/home/somehuman:/bin/bash
agent-alpha:x:4001:4001:agent-alpha:/home/agent-alpha:/bin/bash
agent-beta2:x:4002:4002:agent-beta2:/home/agent-beta2:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF

# --- uid -> label resolution -------------------------------------------------
got="$(_agent_label_from_uid 4001 "$FIX")"
[[ "$got" == "alpha" ]] && ok_t 'T1 an agent uid resolves to its label' \
                        || bad_t 'T1 agent uid did not resolve' "got='$got' want='alpha'"

got="$(_agent_label_from_uid 4000 "$FIX")"
[[ -z "$got" ]] && ok_t 'T1b a HUMAN uid resolves EMPTY (unenveloped shape preserved)' \
               || bad_t 'T1b human was given an identity' "got='$got' want=''"

got="$(_agent_label_from_uid 0 "$FIX")"
[[ -z "$got" ]] && ok_t 'T1c root resolves EMPTY (no invented identity)' \
               || bad_t 'T1c root was given an identity' "got='$got' want=''"

got="$(_agent_label_from_uid 65534 "$FIX")"
[[ -z "$got" ]] && ok_t 'T1d a non-agent system user resolves EMPTY' \
               || bad_t 'T1d non-agent leaked an identity' "got='$got' want=''"

got="$(_agent_label_from_uid 4242 "$FIX")"
[[ -z "$got" ]] && ok_t 'T1e an unknown uid resolves EMPTY (fail-closed)' \
               || bad_t 'T1e unknown uid did not fail closed' "got='$got' want=''"

got="$(_agent_label_from_uid 'not-a-number' "$FIX")"
[[ -z "$got" ]] && ok_t 'T1f a non-numeric uid is refused' \
               || bad_t 'T1f non-numeric uid accepted' "got='$got' want=''"

got="$(_agent_label_from_uid 4002 "$FIX")"
[[ "$got" == "beta2" ]] && ok_t 'T1g the agent- prefix is stripped, digits preserved' \
                        || bad_t 'T1g prefix stripping wrong' "got='$got' want='beta2'"

# --- ADVERSARIAL ---------------------------------------------------------------
# Ground truth is established WITHOUT the function under test, so a broken function
# cannot supply its own expected answer.
REAL_UID="$(grep -m1 '^Uid:' /proc/self/status | awk '{print $2}')"
REAL="$(_agent_label_from_uid "$REAL_UID" /etc/passwd)"

if [[ -z "$REAL" ]]; then
  ok_t "T2-T5 SKIPPED: runner uid $REAL_UID is not an agent-* user (adversarial arms need one)"
else
  # T2 — PATH-substituted `id`: the DIVE-1401 vector, and the bug the first cut shipped.
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\necho agent-impostor\n' > "$TMP/bin/id"; chmod +x "$TMP/bin/id"
  got="$(env -u SUDO_USER -u SUDO_UID PATH="$TMP/bin:$PATH" \
         bash -c "source '$LIB'; auto_sender_from_sudo")"
  [[ "$got" == "$REAL" ]] \
    && ok_t "T2 ADVERSARIAL: a PATH-substituted \`id\` does NOT forge the sender (got '$got')" \
    || bad_t 'T2 PATH substitution FORGED the sender' "got='$got' want='$REAL'"

  # T3 — forged $SUDO_USER: exactly what the ORIGINAL function trusted outright.
  # NOTE the flag order: `env` takes its options BEFORE any VAR=VAL assignment, so
  # `env SUDO_USER=x -u SUDO_UID …` treats `-u` as the COMMAND and fails. The first
  # cut did that and the arm reported a forgery failure that was really a harness
  # failure — an arm that reds for its own reasons is indistinguishable from a real
  # finding, which is the defect this whole ticket family is about.
  got="$(env -u SUDO_UID SUDO_USER=agent-impostor bash -c "source '$LIB'; auto_sender_from_sudo")"
  [[ "$got" == "$REAL" ]] \
    && ok_t "T3 ADVERSARIAL: a forged \$SUDO_USER does NOT forge the sender (got '$got')" \
    || bad_t 'T3 forged SUDO_USER FORGED the sender' "got='$got' want='$REAL'"

  # T4 — forged $SUDO_UID from a NON-root process; only meaningful at EUID 0.
  got="$(env SUDO_UID=0 SUDO_USER=agent-impostor bash -c "source '$LIB'; auto_sender_from_sudo")"
  [[ "$got" == "$REAL" ]] \
    && ok_t "T4 ADVERSARIAL: a forged \$SUDO_UID is ignored below root (got '$got')" \
    || bad_t 'T4 forged SUDO_UID FORGED the sender' "got='$got' want='$REAL'"

  # T5 — THE _deliver PATH end to end: root WITH a sudo-set SUDO_UID must still
  # resolve the invoking agent. This is what proves the scoped a2a route is intact.
  if sudo -n true 2>/dev/null; then
    got="$(sudo -n bash -c "source '$LIB'; auto_sender_from_sudo" 2>/dev/null)"
    [[ "$got" == "$REAL" ]] \
      && ok_t "T5 the root/_deliver path still resolves the sudo invoker (got '$got')" \
      || bad_t 'T5 root/_deliver path regressed' "got='$got' want='$REAL'"
  else
    ok_t 'T5 SKIPPED: no passwordless sudo on this runner'
  fi
fi

echo "-----"
echo "envelope_sender_derivation_unit: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
