#!/usr/bin/env bash
# DIVE-2218 — AGENT_ISOLATION read out of the agent env file must never come back
# as a GUESSED tier, and the shared-relay wiring must never PERSIST one.
#
# THE DEFECT. cmd_agent_teambot.sh rebuilt `<name>.env` from three values it had
# just read out of that same file, under `iso="${iso:-admin}"`. A missing file, an
# unreadable one and a genuinely-admin agent produced the identical string, and
# then write_agent_env wrote it down: a transient read failure becoming a durable
# ADMIN label on disk, at the exact site `5dive agent info` compares against the
# enforced sudoers grant. Not a wrong read — a MANUFACTURED top tier.
#
# WHAT IS GRADED. The resolver's five reasons (T1-T8), the two-source composition
# and its disagreement flag (T9-T13), the teambot rewrite decision including the
# blank-the-workdir case the tier-only reading of this bug misses (T14-T19), the
# unchanged fail-safe at the pairing site (T20-T21), and the WIRING in the three
# call sites (T22-T25) — the extracted helper is only worth grading if the loop
# actually routes through it.
#
# POLARITY IS NOT UNIFORM AND THAT IS THE POINT (DIVE-2213). teambot REFUSES to
# write, cmd_skill.sh DEGRADES to the non-sandboxed strategy, cmd_agent_pairing.sh
# falls back to `standard`. T18 and T21 pin two of those three going opposite ways
# on the same input, so a later "let's just default it centrally" cannot go green.
#
# MUTATION GRADE — 7/7 killed, RUN not predicted (2026-08-10, 27/0 clean baseline).
# Each mutation was applied by a script that ASSERTS its search string was present
# before writing (an inert sed is a green run that graded nothing — the first
# attempt at the third one below was exactly that):
#   * restore `iso="${iso:-admin}"` + drop the guard in the teambot loop -> 25/2:
#     T22, T23. The wiring pins are the only thing that sees this; the helper
#     itself still passes, which is exactly why they are here.
#   * agent_env_isolation: `[[ -e ]]` -> `[[ -r ]]`                    -> 25/2:
#     T3 AND T19 — an existing-but-unreadable file collapses into no-env-file, so
#     the teambot refusal loses the reason it refused for.
#   * agent_env_isolation: drop the ^[a-z][a-z0-9_-]{0,31}$ check      -> 26/1: T7.
#   * agent_isolation_2src: return the registry value on a disagreement instead of
#     the env file's                                                  -> 26/1: T11.
#   * _team_bot_env_rewrite_iso: fall back to `standard` instead of rc 1 when both
#     sources are unmeasured                                          -> 25/2: T16, T17.
#   * _team_bot_env_rewrite_iso: accept unknown:env-unreadable and let the registry
#     answer (the plausible "the registry knows, just use it" refactor) -> 26/1:
#     T19 — the case where the tier is right and the WORKDIR is still gone.
#   * cmd_agent_pairing: `iso="standard"` -> `iso="admin"`             -> 25/2: T20, T21.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# No 2>/dev/null on the source — the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/agent-env-iso.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/registry.sh lib/agent_env.sh \
         lib/agent_setup.sh lib/state.sh lib/validation.sh cmd_agent_create.sh \
         cmd_agent_teambot.sh cmd_agent_pairing.sh; do
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; ENV_DIR="$STATE_DIR/agents.d"; REGISTRY="$STATE_DIR/agents.json"
mkdir -p "$ENV_DIR"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "want '$3' got '$2'"; }

mk_reg() { printf '%s\n' "$1" > "$REGISTRY"; }
mk_reg '{"agents":{"boxed":{"isolation":"sandboxed"},"plain":{"isolation":"standard"},"root":{"isolation":"admin"},"notier":{},"disagree":{"isolation":"sandboxed"}}}'

# ---------------------------------------------------------------- T1-T8: resolver
eq_t "T1  no name supplied is its own reason" "$(agent_env_isolation "")" "unknown:no-name"
eq_t "T2  absent env file does not read as a tier" "$(agent_env_isolation ghost)" "unknown:no-env-file"

printf 'AGENT_ISOLATION=admin\n' > "$ENV_DIR/locked.env"; chmod 000 "$ENV_DIR/locked.env"
if [[ $(id -u) -eq 0 ]]; then
  ok_t "T3  SKIPPED as root — mode 000 is not unreadable to uid 0 (recorded, not silently passed)"
else
  eq_t "T3  unreadable env file is DISTINCT from an absent one" \
       "$(agent_env_isolation locked)" "unknown:env-unreadable"
fi

printf 'AGENT_NAME=blank\nAGENT_WORKDIR=/w\n' > "$ENV_DIR/blank.env"
eq_t "T4  readable file with no AGENT_ISOLATION line" "$(agent_env_isolation blank)" "unknown:no-field"

printf 'AGENT_ISOLATION=\n' > "$ENV_DIR/empty.env"
eq_t "T5  present-but-empty value is no-field, not a tier" "$(agent_env_isolation empty)" "unknown:no-field"

printf 'AGENT_ISOLATION=sandboxed\n' > "$ENV_DIR/boxed.env"
eq_t "T6  a real value comes back bare" "$(agent_env_isolation boxed)" "sandboxed"

printf 'AGENT_ISOLATION=admin; rm -rf /\n' > "$ENV_DIR/evil.env"
eq_t "T7  a non-token value is unusable, never ranked" "$(agent_env_isolation evil)" "unknown:malformed-tier"

printf 'AGENT_ISOLATION="admin"\r\n' > "$ENV_DIR/crlf.env"
eq_t "T8  quoted + CRLF value still resolves" "$(agent_env_isolation crlf)" "admin"

# Its OWN counter, not $FAIL: gating this ok_t on the global would make T8b's
# result depend on unrelated earlier failures, and a harness whose assertion COUNT
# moves with the mutation under test cannot be compared run to run.
t8b=0
for v in unknown:no-name unknown:no-env-file unknown:env-unreadable unknown:no-field unknown:malformed-tier; do
  agent_env_isolation_unmeasured "$v" || t8b=1
done
agent_env_isolation_unmeasured admin && t8b=1
[[ $t8b -eq 0 ]] \
  && ok_t "T8b unmeasured predicate is TOTAL over unknown:* (unlike tier_unmeasured)" \
  || bad_t "T8b unmeasured predicate is TOTAL over unknown:*" "a reason escaped the predicate"

# ------------------------------------------------------- T9-T13: two-source compose
printf 'AGENT_ISOLATION=standard\n' > "$ENV_DIR/plain.env"
eq_t "T9  env answers, registry agrees -> env" "$(agent_isolation_2src plain)" "$(printf 'standard\tenv')"

printf 'AGENT_ISOLATION=sandboxed\n' > "$ENV_DIR/orphan.env"   # not in the registry at all
eq_t "T10 env answers, registry has no such agent -> env" \
     "$(agent_isolation_2src orphan)" "$(printf 'sandboxed\tenv')"

printf 'AGENT_ISOLATION=admin\n' > "$ENV_DIR/disagree.env"      # registry says sandboxed
eq_t "T11 BOTH measured and DIFFERENT -> env value, disagreement NAMED" \
     "$(agent_isolation_2src disagree)" "$(printf 'admin\tenv:disagrees-registry:sandboxed')"

eq_t "T12 env silent, registry answers -> registry value + the env's reason" \
     "$(agent_isolation_2src root)" "$(printf 'admin\tregistry:no-env-file')"

eq_t "T13 neither answers -> NOT a tier, both reasons named" \
     "$(agent_isolation_2src nobody)" "$(printf 'unknown:unmeasured\tunmeasured:no-env-file:unregistered')"

# -------------------------------------------- T14-T19: the teambot rewrite decision
out=$(_team_bot_env_rewrite_iso plain); rc=$?
eq_t "T14 measured env tier is returned for the rewrite" "$rc/$out" "0/standard"

out=$(_team_bot_env_rewrite_iso ghost 2>/dev/null); rc=$?
eq_t "T15 ABSENT env file: refuse to rewrite (rc 1), reason on stdout" "$rc/$out" "1/unknown:no-env-file"

out=$(_team_bot_env_rewrite_iso blank 2>/dev/null); rc=$?    # readable, no field; not in registry
eq_t "T16 readable file, no field, registry silent: still refuse" "$rc/$out" "1/unmeasured:no-field:unregistered"

printf 'AGENT_NAME=notier\n' > "$ENV_DIR/notier.env"          # registry key exists, no isolation
out=$(_team_bot_env_rewrite_iso notier 2>/dev/null); rc=$?
eq_t "T17 BOTH sources unmeasured: refuse — a smaller guess is still a guess" \
     "$rc/$out" "1/unmeasured:no-field:no-tier"

printf 'AGENT_NAME=root\n' > "$ENV_DIR/root.env"              # readable, no field; registry: admin
out=$(_team_bot_env_rewrite_iso root 2>/dev/null); rc=$?
eq_t "T18 readable file + MEASURED registry: persist the registry value, reconciling the two" \
     "$rc/$out" "0/admin"

# The case a tier-only reading of this bug misses: the registry knows the tier, but
# the env file could not be read, so AGENT_WORKDIR/AGENT_AUTH_PROFILE are holes too
# and rewriting the file would DROP them (write_agent_env omits an empty workdir).
if [[ $(id -u) -eq 0 ]]; then
  ok_t "T19 SKIPPED as root — cannot make a file unreadable to uid 0"
else
  mk_reg '{"agents":{"locked":{"isolation":"standard"}}}'
  out=$(_team_bot_env_rewrite_iso locked 2>/dev/null); rc=$?
  eq_t "T19 UNREADABLE file + measured registry: STILL refuse (workdir/profile are holes too)" \
       "$rc/$out" "1/unknown:env-unreadable"
  mk_reg '{"agents":{"boxed":{"isolation":"sandboxed"},"plain":{"isolation":"standard"},"root":{"isolation":"admin"},"notier":{},"disagree":{"isolation":"sandboxed"}}}'
fi

# Differential anchor: the PRE-FIX expression, extracted from origin/main rather
# than retyped, on the same input T15 refuses. A retyped baseline only agrees with
# my reading of the old code (DIVE-2213's technique).
old=$(git show origin/main:src/cmd_agent_teambot.sh 2>/dev/null \
        | grep -m1 -F 'iso="${iso:-admin}"')
if [[ -z "$old" ]]; then
  printf 'note - T19b baseline UNRESOLVED (no origin/main), pre-fix arm not graded\n'
else
  ef="$ENV_DIR/ghost.env"; eval "$old" ; # sets iso from the absent file, then defaults
  eq_t "T19b pre-fix expression really did manufacture 'admin' from an absent file" "$iso" "admin"
fi

# ------------------------------------------------- T20-T21: the pairing fail-safe
send_welcome_message() { :; }   # placeholder if the real one is absent
grep -q 'agent_env_isolation_unmeasured "\$iso" && iso="standard"' "$SRC/cmd_agent_pairing.sh" \
  && ok_t "T20 pairing site resolves through agent_env_isolation()" \
  || bad_t "T20 pairing site resolves through agent_env_isolation()" "raw sed read is back"
grep -q 'iso="standard"' "$SRC/cmd_agent_pairing.sh" \
  && ok_t "T21 pairing keeps its DIVE-1571 fail-safe polarity (standard, never admin)" \
  || bad_t "T21 pairing fail-safe polarity" "the welcome would over-claim"

# --------------------------------------------------------------- T22-T25: wiring
grep -q 'if ! iso=$(_team_bot_env_rewrite_iso "$name"); then' "$SRC/cmd_agent_teambot.sh" \
  && ok_t "T22 teambot loop ROUTES through the guarded helper" \
  || bad_t "T22 teambot loop routes through the helper" "the extracted unit is unwired"
# Comment lines are stripped first: both fixes QUOTE the idiom they removed, so a
# naive grep over the whole file reports the defect as still present. An absence
# assertion that cannot tell code from prose is worse than none — it fails green
# the day someone deletes the comment.
code_of() { grep -v '^[[:space:]]*#' "$1"; }
code_of "$SRC/cmd_agent_teambot.sh" | grep -q 'iso="${iso:-admin}"' \
  && bad_t "T23 the defaulted-admin idiom is GONE from teambot CODE" "it is back" \
  || ok_t "T23 the defaulted-admin idiom is GONE from teambot CODE"
code_of "$SRC/cmd_skill.sh" | grep -q 'echo "admin"' \
  && bad_t "T24 cmd_skill CODE no longer SPELLS a read failure as a tier" "|| echo \"admin\" is back" \
  || ok_t "T24 cmd_skill CODE no longer SPELLS a read failure as a tier"
grep -q 'agent_isolation_2src "$name"' "$SRC/cmd_skill.sh" \
  && ok_t "T25 cmd_skill resolves through the two-source resolver" \
  || bad_t "T25 cmd_skill resolves through the two-source resolver" "raw grep -oP read is back"

chmod 644 "$ENV_DIR/locked.env" 2>/dev/null
printf '\nDIVE-2218 env-file isolation resolver: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
