#!/usr/bin/env bash
# DIVE-2517 (v0.18 "Proof of who") — `5dive whoami` and the ONE sealed actor
# derivation in src/lib/actor.sh.
#
# WHAT THIS GRADES, and why each arm can fail:
#   identity is uid-first    the answer comes from $EUID -> /etc/passwd and from
#                            nothing else. Arms 2 and 3 run the REAL forgeries
#                            (a PATH shim for `id`/`getent`; SUDO_USER, USER,
#                            LOGNAME and FIVEDIVE_AUDIT_USER all naming another
#                            agent) and demand the real name back.
#   the prefix rule is gone  from the IDENTITY axis (DIVE-2371). Arm 4 is
#                            differential: it fails if the two resolvers AGREE,
#                            because then it is grading nothing.
#   unmeasurable REFUSES     arms 5, 6 and 9 make the actor genuinely
#                            unresolvable and demand a NON-ZERO return plus a
#                            reason that names the failure. Each is anchored
#                            against a baseline that must SUCCEED, so a resolver
#                            that always fails cannot pass them.
#   not-an-agent is MEASURED arm 7. `root` is an answer, not a hole, and it must
#                            return 0 — the absent-vs-not-measured line
#                            tier_unmeasured() already draws for tiers.
#   the SUDO_UID branch      arm 8 exercises both sides of the real root check.
#   the verb, end to end     arms 10-12 run the BUILT bundle, including the exit
#                            status under a bind-mounted passwd in a mount
#                            namespace — the only way to reach the refusal
#                            through a fresh bash that redefines its own seams.
#
# GROUND TRUTH IS TAKEN WITHOUT THE CODE UNDER TEST: the expected name comes from
# /proc/self/status's real uid resolved against /etc/passwd by awk. Never from
# `id`, never from the resolver being graded.
#
# Run: bash tests/whoami_sealed_actor_unit.sh   (no network; arm 12 wants sudo)
set -uo pipefail

# DIVE-2211 / DIVE-2286: name the tree this harness grades. Sourced BEFORE the cd
# so ${BASH_SOURCE[0]} still resolves relative to tests/. Deliberately NO
# `2>/dev/null` — redirecting it also swallows the helper's own stderr line, which
# IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASS=0; FAIL=0; SKIP=0
ok(){   PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no(){   FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
# A skip is NOT a pass. An unavailable precondition must never inflate a green log.
skip(){ SKIP=$((SKIP+1)); printf 'skip - %s\n' "$1"; }

# --- ground truth, independent of the code under test -----------------------
REAL_UID=$(awk '/^Uid:/{print $2; exit}' /proc/self/status)
REAL_GID=$(awk '/^Gid:/{print $2; exit}' /proc/self/status)
REAL_NAME=$(awk -F: -v u="$REAL_UID" '$3==u{print $1; exit}' /etc/passwd)

# --- load the sealed derivation, and NOTHING else ---------------------------
# One-liner bodies included: `sed '/^f()/,/^}/p'` over `f() { ...; }` on a single
# line captures that line and then runs to the NEXT `^}` in the file, swallowing
# whatever sits between. Anchor each extraction to its own definition and verify
# the function loaded rather than trusting the range.
for _fn in _gate_passwd_stream actor_uid_to_name _gate_uid_to_agent _gate_is_root \
           _gate_caller_uid _gate_authenticated_actor actor_derive actor_registry_agent; do
  eval "$(awk -v f="^${_fn}\\\\(\\\\)" '$0 ~ f {p=1} p {print} p && /^}$/ {exit} p && /^[a-z_]+\(\)[[:space:]]*\{.*\}$/ {exit}' src/lib/actor.sh)"
done
for _f in _gate_passwd_stream actor_uid_to_name _gate_uid_to_agent _gate_is_root \
          _gate_caller_uid _gate_authenticated_actor actor_derive actor_registry_agent; do
  declare -F "$_f" >/dev/null || { printf 'NOT OK - %s did not load; every arm below would be vacuous\n' "$_f"; exit 1; }
done
# tier_unmeasured is registry.sh's, not this file's — arms 13-15 grade
# actor_registry_agent's PARTITION over it, with agent_tier stubbed. Stubbing the
# lookup is deliberate: registry.sh already owns whether agent_tier reads the file
# correctly, and what is untested is what actor_registry_agent DOES with each verdict.
eval "$(sed -n '/^tier_unmeasured()/,/^}/p' src/lib/registry.sh)"
declare -F tier_unmeasured >/dev/null || { printf 'NOT OK - tier_unmeasured did not load\n'; exit 1; }

# ---------------------------------------------------------------------------
# 1. identity is the uid's passwd name, taken from the kernel
if [[ -z "$REAL_NAME" ]]; then
  skip "T1 caller uid $REAL_UID has no passwd row on this runner"
else
  actor_derive; rc=$?
  if (( rc == 0 )) && [[ "$ACTOR_UNIX" == "$REAL_NAME" && "$ACTOR_UID" == "$REAL_UID" && "$ACTOR_SOURCE" == "euid" ]]; then
    ok "T1 actor_derive = $REAL_NAME (uid $REAL_UID, source euid), rc 0"
  else
    no "T1 expected $REAL_NAME/$REAL_UID/euid rc0, got '$ACTOR_UNIX'/'$ACTOR_UID'/'$ACTOR_SOURCE' rc$rc"
  fi
fi

# 2. a PATH shim for `id` and `getent` must change nothing
SHIM=$(mktemp -d)
printf '#!/bin/sh\necho agent-lodar\n'          > "$SHIM/id";     chmod +x "$SHIM/id"
printf '#!/bin/sh\necho agent-lodar:x:0:0:::\n' > "$SHIM/getent"; chmod +x "$SHIM/getent"
if [[ -z "$REAL_NAME" ]]; then
  skip "T2 no passwd row for the caller; the forgery has nothing to displace"
else
  ( PATH="$SHIM:$PATH"; actor_derive; printf '%s' "$ACTOR_UNIX" ) > "$SHIM/out"
  got=$(<"$SHIM/out")
  # Non-vacuity: the shim must actually be winning PATH, or this arm proves nothing.
  shimmed=$(PATH="$SHIM:$PATH" id -un 2>/dev/null)
  if [[ "$shimmed" != "agent-lodar" ]]; then
    no "T2 VACUOUS — the PATH shim never took effect (\`id -un\` returned '$shimmed')"
  elif [[ "$got" == "$REAL_NAME" ]]; then
    ok "T2 PATH shim printing agent-lodar did not move the identity (still $REAL_NAME)"
  else
    no "T2 PATH shim moved the identity to '$got'"
  fi
fi

# 3. the four caller-supplied identity env vars must all be ignored
if [[ -z "$REAL_NAME" ]]; then
  skip "T3 no passwd row for the caller"
else
  # In-process, not `bash -c`: a fresh shell would not have the function loaded and
  # the arm would grade an empty string against an empty string.
  ( export SUDO_USER=agent-olivia USER=claude LOGNAME=claude FIVEDIVE_AUDIT_USER=lodar
    actor_derive; printf '%s' "$ACTOR_UNIX" ) > "$SHIM/out3"
  got=$(<"$SHIM/out3")
  if [[ "$got" == "$REAL_NAME" ]]; then
    ok "T3 SUDO_USER/USER/LOGNAME/FIVEDIVE_AUDIT_USER=<other> did not move the identity"
  else
    no "T3 env forgery moved the identity to '$got'"
  fi
fi

# 4. DIFFERENTIAL: the identity read has no `agent-` prefix rule; the legacy gate
#    resolver still does. If they agree, this arm is grading nothing and FAILS.
root_name=$(actor_uid_to_name 0)
root_agent=$(_gate_uid_to_agent 0)
if [[ "$root_name" != "root" ]]; then
  no "T4 precondition: uid 0 did not resolve to 'root' (got '$root_name')"
elif [[ -n "$root_agent" ]]; then
  no "T4 _gate_uid_to_agent(0) returned '$root_agent'; the gate resolver's prefix rule regressed"
elif [[ "$root_name" == "$root_agent" ]]; then
  no "T4 VACUOUS — both resolvers agree on uid 0, so the axis split is not being graded"
else
  ok "T4 uid 0: identity='root' (no prefix rule) vs gate resolver='' (prefix rule kept)"
fi

# 5. UNMEASURABLE: the uid has no passwd row -> non-zero, and the reason names it.
#    Anchored: the SAME call against the real passwd must SUCCEED, so a resolver
#    that always refuses cannot pass this.
FIX=$(mktemp -d)/passwd
printf 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534::/:/usr/sbin/nologin\n' > "$FIX"
(
  actor_derive; base_rc=$?
  _gate_caller_uid() { printf '424242'; }
  actor_derive; mut_rc=$?
  if (( base_rc != 0 )); then
    printf 'ANCHOR_FAIL %s\n' "$base_rc"
  elif (( mut_rc == 0 )); then
    printf 'MUT_PASSED %s\n' "$ACTOR_UNIX"
  else
    printf 'REFUSED %s %s\n' "$ACTOR_REASON" "${ACTOR_UNIX:-<empty>}"
  fi
) > "$SHIM/out5"
read -r verdict a b < "$SHIM/out5"
case "$verdict" in
  REFUSED) if [[ "$a" == "uid-not-in-passwd" && "$b" == "<empty>" ]]; then
             ok "T5 uid with no passwd row -> rc!=0, reason=uid-not-in-passwd, name empty"
           else no "T5 refused but reason='$a' name='$b'"; fi ;;
  MUT_PASSED)  no "T5 an unresolvable uid returned rc 0 as '$a'" ;;
  ANCHOR_FAIL) no "T5 ANCHOR — the baseline derive already failed (rc $a); the mutant proves nothing" ;;
  *)           no "T5 harness produced no verdict" ;;
esac

# 6. UNMEASURABLE: passwd itself unreadable. `$(</etc/passwd)` leaves printf's
#    status at 0 on a failed open, so emptiness — not rc — has to be the signal.
(
  _gate_passwd_stream() { printf ''; }
  actor_derive; rc=$?
  printf '%s %s\n' "$rc" "${ACTOR_REASON:-<none>}"
) > "$SHIM/out6"
read -r rc reason < "$SHIM/out6"
if (( rc != 0 )) && [[ "$reason" == "passwd-unreadable" ]]; then
  ok "T6 empty passwd stream -> rc $rc, reason=passwd-unreadable (not a silent empty name)"
else
  no "T6 expected rc!=0 + passwd-unreadable, got rc=$rc reason=$reason"
fi

# 7. not-an-agent is a MEASUREMENT, not a hole: uid 0 -> root, rc 0.
(
  _gate_caller_uid() { printf '0'; }
  _gate_is_root()    { return 1; }   # model a non-root caller whose uid maps to root
  actor_derive; printf '%s %s\n' "$?" "${ACTOR_UNIX:-<empty>}"
) > "$SHIM/out7"
read -r rc name < "$SHIM/out7"
if (( rc == 0 )) && [[ "$name" == "root" ]]; then
  ok "T7 a non-agent uid is MEASURED (root, rc 0), not reported as unmeasurable"
else
  no "T7 expected rc 0 + root, got rc=$rc name=$name"
fi

# 8. the SUDO_UID branch is gated on the REAL root check, both ways.
(
  _gate_caller_uid() { printf '0'; }
  _gate_is_root()    { return 1; }
  SUDO_UID=65534 actor_derive
  printf 'nonroot %s %s\n' "$ACTOR_SOURCE" "$ACTOR_UNIX"
) > "$SHIM/out8a"
(
  _gate_caller_uid() { printf '0'; }
  _gate_is_root()    { return 0; }
  SUDO_UID=65534 actor_derive
  printf 'root %s %s\n' "$ACTOR_SOURCE" "$ACTOR_UNIX"
) > "$SHIM/out8b"
read -r _ s_a n_a < "$SHIM/out8a"
read -r _ s_b n_b < "$SHIM/out8b"
nobody=$(awk -F: '$3==65534{print $1; exit}' /etc/passwd)
if [[ -z "$nobody" ]]; then
  skip "T8 no uid 65534 on this runner to model the pre-elevation invoker"
elif [[ "$s_a" == "euid" && "$n_a" == "root" && "$s_b" == "sudo_uid" && "$n_b" == "$nobody" ]]; then
  ok "T8 SUDO_UID ignored below root (euid/root) and honoured at real root (sudo_uid/$nobody)"
else
  no "T8 expected euid+root then sudo_uid+$nobody, got '$s_a'+'$n_a' then '$s_b'+'$n_b'"
fi

# 9. a malformed SUDO_UID at root REFUSES rather than silently falling back to the
#    (root) euid — a fallback there would launder a broken elevation into an identity.
(
  _gate_caller_uid() { printf '0'; }
  _gate_is_root()    { return 0; }
  SUDO_UID='0; rm -rf /' actor_derive; rc=$?
  printf '%s %s %s\n' "$rc" "${ACTOR_REASON:-<none>}" "${ACTOR_UNIX:-<empty>}"
) > "$SHIM/out9"
read -r rc reason name < "$SHIM/out9"
if (( rc != 0 )) && [[ "$reason" == "sudo-uid-not-numeric" && "$name" == "<empty>" ]]; then
  ok "T9 malformed SUDO_UID at root -> rc $rc, reason=sudo-uid-not-numeric, no fallback identity"
else
  no "T9 expected rc!=0 + sudo-uid-not-numeric + empty, got rc=$rc reason=$reason name=$name"
fi

# ---------------------------------------------------------------------------
# 13. the THREE registry verdicts must stay distinguishable in the report. This is
#     the absent-vs-not-measured line DIVE-2213 drew for tiers, re-drawn one layer
#     up: `not an agent` is an ANSWER, `could not read the registry` is not, and a
#     registered agent with no isolation is a hole that must still name the agent.
#     The arm FAILS if any two of the three collapse.
probe13() {  # $1 = stubbed agent_tier verdict; prints "<agent>|<tier>|<measured>"
  local verdict="$1"
  ( agent_tier() { printf '%s' "$verdict"; }
    actor_registry_agent "agent-dev"
    tier_unmeasured "$ACTOR_TIER" && m=no || m=yes
    printf '%s|%s|%s' "${ACTOR_AGENT:-<none>}" "$ACTOR_TIER" "$m" )
}
r_unreg=$(probe13 'unknown:unregistered')
r_notier=$(probe13 'unknown:no-tier')
r_noreg=$(probe13 'unknown:no-registry')
r_real=$(probe13 'shared')
if [[ "$r_unreg" == "$r_noreg" || "$r_unreg" == "$r_notier" || "$r_notier" == "$r_noreg" ]]; then
  no "T13 COLLAPSED — two registry verdicts render identically (unreg=$r_unreg no-tier=$r_notier no-registry=$r_noreg)"
elif [[ "$r_unreg" == "<none>|unknown:unregistered|yes" \
     && "$r_notier" == "dev|unknown:no-tier|no" \
     && "$r_noreg"  == "<none>|unknown:no-registry|no" \
     && "$r_real"   == "dev|shared|yes" ]]; then
  ok "T13 unregistered=MEASURED/no agent, no-tier=agent named/NOT measured, no-registry=claims nothing, shared=dev"
else
  no "T13 unreg=$r_unreg no-tier=$r_notier no-registry=$r_noreg real=$r_real"
fi

# 17. a FAILED LOOKUP must not be rescued by the next candidate. The stub answers
#     differently per name — lookup-failed for the stripped one, a real tier for the
#     full one — which is the only shape that separates `return` from `continue` on
#     the residual unknown:* branch. Continuing there launders a read that did not
#     happen into a confident agent identity.
f_out=$( agent_tier() { [[ "$1" == dev ]] && printf 'unknown:lookup-failed' || printf 'shared'; }
         actor_registry_agent "agent-dev"; printf '%s|%s' "${ACTOR_AGENT:-<none>}" "$ACTOR_TIER" )
if [[ "$f_out" == "<none>|unknown:lookup-failed" ]]; then
  ok "T17 a failed registry lookup stops the search and claims no agent (not rescued by candidate 2)"
elif [[ "$f_out" == "agent-dev|shared" ]]; then
  no "T17 a failed lookup on candidate 1 was papered over by candidate 2 -> reported agent-dev/shared"
else
  no "T17 expected <none>|unknown:lookup-failed, got $f_out"
fi

# 18. malformed-tier means REGISTERED with an unusable tier: name the agent, flag the
#     tier. It must NOT render like an unreadable registry, which names nobody.
m_out=$( agent_tier() { printf 'unknown:malformed-tier'; }
         actor_registry_agent "agent-dev"; printf '%s|%s' "${ACTOR_AGENT:-<none>}" "$ACTOR_TIER" )
u_out=$( agent_tier() { printf 'unknown:registry-unreadable'; }
         actor_registry_agent "agent-dev"; printf '%s|%s' "${ACTOR_AGENT:-<none>}" "$ACTOR_TIER" )
if [[ "$m_out" == "$u_out" ]]; then
  no "T18 COLLAPSED — malformed-tier and registry-unreadable render identically ($m_out)"
elif [[ "$m_out" == "dev|unknown:malformed-tier" && "$u_out" == "<none>|unknown:registry-unreadable" ]]; then
  ok "T18 malformed-tier names the agent (dev) while an unreadable registry names nobody"
else
  no "T18 expected dev|unknown:malformed-tier vs <none>|unknown:registry-unreadable, got $m_out vs $u_out"
fi

# 14. DIVE-2371: agent-ness is the REGISTRY's answer, not a username prefix. Under a
#     registry where only `claude` is an agent, the non-prefixed unix user resolves
#     to an agent and the `agent-`-prefixed one does NOT. Same stub, opposite result
#     — a prefix rule anywhere on this path cannot produce that pair.
stub_only_claude() { agent_tier() { [[ "$1" == claude ]] && printf 'shared' || printf 'unknown:unregistered'; }; }
c_out=$( stub_only_claude; actor_registry_agent "claude";    printf '%s' "${ACTOR_AGENT:-<none>}" )
d_out=$( stub_only_claude; actor_registry_agent "agent-dev"; printf '%s' "${ACTOR_AGENT:-<none>}" )
if [[ "$c_out" == "claude" && "$d_out" == "<none>" ]]; then
  ok "T14 registry decides agent-ness: claude=agent, agent-dev=<none> under the same stub (DIVE-2371)"
elif [[ "$c_out" == "$d_out" ]]; then
  no "T14 VACUOUS — both names resolved the same ('$c_out'); the registry is not deciding"
else
  no "T14 expected claude/<none>, got '$c_out'/'$d_out'"
fi

# 15. the `agent-` strip is a LOOKUP CANDIDATE, not the decision: with only the
#     stripped name registered, the board name is the stripped one.
s_out=$( agent_tier() { [[ "$1" == dev ]] && printf 'admin' || printf 'unknown:unregistered'; }
         actor_registry_agent "agent-dev"; printf '%s|%s' "$ACTOR_AGENT" "$ACTOR_TIER" )
if [[ "$s_out" == "dev|admin" ]]; then
  ok "T15 agent-dev -> board name dev via the stripped lookup candidate (tier admin)"
else
  no "T15 expected dev|admin, got $s_out"
fi

# ---------------------------------------------------------------------------
# END TO END, through the BUILT bundle.
BIN=./5dive
if [[ ! -x "$BIN" ]]; then
  skip "T10-T12 no built ./5dive bundle in the tree"
else
  # 10. the verb reports the ground-truth identity and exits 0.
  out=$("$BIN" whoami 2>&1); rc=$?
  if [[ -z "$REAL_NAME" ]]; then
    skip "T10 no passwd row for the caller"
  elif (( rc == 0 )) && grep -q "unix=$REAL_NAME" <<<"$out"; then
    ok "T10 \`5dive whoami\` rc 0 and reports unix=$REAL_NAME"
  else
    no "T10 rc=$rc, output did not carry unix=$REAL_NAME: $(head -2 <<<"$out" | tr '\n' ' ')"
  fi

  # 11. --json carries the same identity, real booleans, and a numeric uid.
  j=$("$BIN" whoami --json 2>/dev/null)
  if ! jq -e . >/dev/null 2>&1 <<<"$j"; then
    no "T11 --json did not emit parseable JSON"
  else
    j_unix=$(jq -r '.data.actor.unix' <<<"$j")
    j_meas=$(jq -r '.data.actor.measured|type' <<<"$j")
    j_uid=$(jq -r '.data.actor.uid|type' <<<"$j")
    j_ok=$(jq -r '.ok' <<<"$j")
    if [[ "$j_unix" == "$REAL_NAME" && "$j_meas" == "boolean" && "$j_uid" == "number" && "$j_ok" == "true" ]]; then
      ok "T11 --json: ok=true, actor.unix=$REAL_NAME, measured is a boolean, uid is a number"
    else
      no "T11 --json shape wrong: unix=$j_unix measured:$j_meas uid:$j_uid ok=$j_ok"
    fi
  fi

  # 12. THE CONTRACT: unmeasurable exits NON-ZERO through the real bundle.
  #     A fresh bash redefines its own seams, so the only honest way in is to
  #     change what /etc/passwd IS — bind-mounted inside a private mount
  #     namespace, so nothing on the host is touched. setpriv drops back to the
  #     caller's uid WITHOUT needing a passwd lookup to do it.
  if ! command -v unshare >/dev/null || ! command -v setpriv >/dev/null; then
    skip "T12 unshare/setpriv unavailable — the exit-status contract is UNPROBED here, not proven"
  elif ! sudo -n true 2>/dev/null; then
    skip "T12 no non-interactive sudo — the exit-status contract is UNPROBED here, not proven"
  else
    e2e=$(sudo -n unshare -m -- bash -c \
      "mount --bind '$FIX' /etc/passwd && setpriv --reuid=$REAL_UID --regid=$REAL_GID --clear-groups $PWD/5dive whoami --json" \
      2>/dev/null); e2erc=$?
    e2e_reason=$(jq -r '.data.actor.reason // empty' <<<"$e2e" 2>/dev/null)
    # NOT `.ok // empty` — jq's `//` treats a literal `false` as absent, so the one
    # value this arm exists to see would read as unset on the branch that matters.
    e2e_ok=$(jq -r 'if has("ok") then (.ok|tostring) else "" end' <<<"$e2e" 2>/dev/null)
    e2e_code=$(jq -r '.error.code // empty'         <<<"$e2e" 2>/dev/null)
    if (( e2erc == 6 )) && [[ "$e2e_ok" == "false" && "$e2e_code" == "6" && "$e2e_reason" == "uid-not-in-passwd" ]]; then
      ok "T12 bundle under a passwd with no row for uid $REAL_UID: exit 6, ok=false, reason=uid-not-in-passwd"
    elif (( e2erc == 0 )); then
      no "T12 the bundle exited 0 with an unmeasurable actor — the whole contract of this verb"
    else
      no "T12 expected exit 6 + ok:false + uid-not-in-passwd, got rc=$e2erc ok=$e2e_ok code=$e2e_code reason=$e2e_reason"
    fi
  fi

  # 16. the other two exit contracts, which are just as much part of the verb: an
  #     unknown flag is a usage error (2), and --help succeeds and STATES the
  #     exit-status rule rather than leaving it to be discovered from source.
  "$BIN" whoami --nope >/dev/null 2>&1; bad_rc=$?
  helptxt=$("$BIN" whoami --help 2>&1); help_rc=$?
  if (( bad_rc == 2 )) && (( help_rc == 0 )) && grep -qi 'exit status' <<<"$helptxt"; then
    ok "T16 unknown flag -> 2, --help -> 0 and documents the exit-status contract"
  else
    no "T16 bad-flag rc=$bad_rc (want 2), help rc=$help_rc (want 0), help names exit status: $(grep -qi 'exit status' <<<"$helptxt" && echo yes || echo NO)"
  fi
fi

rm -rf "$SHIM" "${FIX%/passwd}"
printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
