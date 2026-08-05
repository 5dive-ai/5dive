#!/usr/bin/env bash
# TIER: nightly — 10.0s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2233 ITEM 2 — the tier-2 human claim, proved instead of asserted.
#
# Cut onto its own branch at Marcus's direction, and the reason is the point: the tier-2
# "hard human floor" is currently a LABEL. The gate that closed DIVE-2131 recorded
# need_answered_uid=1004 (the plugin's own uid) and human_nonce_hash NULL — a tier-2 hard
# gate closed with no non-forgeable principal. The floor only ever fired when `--human` was
# ABSENT, and `--human` is a flag any agent that can sudo simply passes.
#
# This ships INDEPENDENTLY of the sealed gate-clear (item 1 / phase 3): it touches no
# constitution key and waits on no council motion. A live floor that is decorative must not
# wait on governance it does not depend on.
#
# THREE PARTS. Tier 2 now mints a per-gate nonce for EVERY type (it skipped `decision`);
# the decision buttons CARRY it in callback_data; and a `--human` answer on a nonce-bearing
# tier-2 gate must produce that nonce or a non-agent SUDO_UID. Scoped to gates that HAVE a
# nonce, which is the compatibility hinge rather than timidity — a gate filed by the old
# code has no hash to check, and demanding evidence there would reject real taps on every
# gate already in flight, whose buttons were rendered without a nonce to carry.
#
# Run: bash tests/gate_t2_nonce_proof_unit.sh (no root, no network).

# DIVE-2211: name the tree this harness grades. NOTE the absence of `2>/dev/null` —
# redirecting the source's stderr also swallows the helper's own stderr line, which IS
# the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -o pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2573: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-t2-nonce-proof.XXXXXX)"

# STATE_DIR must be set BEFORE cmd_council.sh is sourced (COUNCIL_DIR/COUNCIL_LINEAGE are
# source-time globals derived from it).
STATE_DIR="$TMP"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_council.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# cmd_council.sh LAST, matching the production bundle order (CNCL-14). Sourcing it is not
# convenience: the anchor lives in those council helpers, and a harness that stubbed them
# would be grading its own stubs.
COUNCIL_DIR="$STATE_DIR/council"; COUNCIL_LINEAGE="$COUNCIL_DIR/lineage.jsonl"
TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

AUDIT_FILE="$TMP/audit"; : > "$AUDIT_FILE"
audit_log() { printf '%s\n' "$*" >> "$AUDIT_FILE"; }
_af_reset() { : > "$AUDIT_FILE"; }
_af()       { cat "$AUDIT_FILE" 2>/dev/null; }
# Capture the RAW nonce cmd_task_need hands to the notifier ($8). This is the only place
# it is ever exposed — it is deliberately never printed to stdout, so the filing agent
# cannot see it. The item-2 arms need it to simulate a real tap.
NONCE_FILE="$TMP/nonce"; : > "$NONCE_FILE"
task_need_notify() { printf '%s' "${8:-}" > "$NONCE_FILE"; return 0; }
last_nonce() { cat "$NONCE_FILE" 2>/dev/null; }
# The task-store audit fence (DIVE-2054) checks the store is production; this harness is
# isolated, so open it or every row is withheld and the audit assertions pass vacuously.
_task_human_send_allowed() { return 0; }

# Only the CALLER IDENTITY is pinned. _gate_authenticated_actor, _gate_route_reviewer,
# _task_resolve_coordinator and the whole _council_* chain run for real — THEY decide.
#
# DIVE-2601: the pin used to be an `id -un` stub, and the derivation has not read
# `id` since DIVE-2330 (it resolves $EUID over a passwd stream in pure bash, so a
# PATH shim cannot forge it). Measured over a full run of this file the stub took
# ZERO calls — "the caller is agent-marcus" was decided by whoever ran the suite.
# The passwd fixture is derived from FAKE_CALLER at call time so the flip to
# agent-main further down keeps working, and it is PREPENDED to the real
# /etc/passwd so every other uid on the box still resolves.
FAKE_CALLER="agent-marcus"
_PIN_UID=987654
_gate_caller_uid()    { printf '%s' "$_PIN_UID"; }
_gate_passwd_stream() {
  printf '%s:x:%s:%s::/nonexistent:/bin/false\n' "$FAKE_CALLER" "$_PIN_UID" "$_PIN_UID"
  printf '%s\n' "$(</etc/passwd)"
}
# Assert the pin through the real resolver before any arm leans on it (DIVE-2588).
_pin_check="$(_gate_uid_to_agent "$(_gate_caller_uid)")"
[[ "$_pin_check" == "${FAKE_CALLER#agent-}" ]] \
  || { printf 'NOT OK - identity pin is inert: uid %s resolved to %s, expected %s\n' "$_PIN_UID" "'$_pin_check'" "'${FAKE_CALLER#agent-}'"; exit 1; }

# Org chart: marcus is the lead, dev reports to marcus.
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('marcus','coordinator',NULL);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('dev','builder','marcus');"
[[ "$(_gate_route_reviewer dev)" == "marcus" ]] \
  || { printf 'FAIL - harness precondition: routing did not resolve dev -> marcus\n'; exit 1; }

# --- the ANCHOR -----------------------------------------------------------------------
# `constitution_yaml <clear_leads csv> [eng_lead]` — writes the strict shape the node-free
# reader supports. NO `hard_gates:` key on purpose: absent keeps the SHIPPED defaults, so
# the tier-2 floor these arms lean on behaves exactly as in production. A trimmed
# hard_gates block would silently narrow the floor and green the T2 arms for the wrong
# reason (DIVE-2099's own lesson).
constitution_yaml() {
  local leads="${1:-}" eng="${2:-}" n
  printf 'ship:\ncomms:\n'
  if [[ -n "$leads" || -n "$eng" ]]; then
    printf 'authority:\n'
    [[ -n "$eng" ]] && printf '  eng_approval_lead: %s\n' "$eng"
    if [[ -n "$leads" ]]; then
      printf '  gate_clear_leads:\n'
      IFS=, read -ra _ls <<< "$leads"
      for n in "${_ls[@]}"; do printf '    - %s\n' "$n"; done
    fi
  fi
  return 0
}
write_constitution() { mkdir -p "$STATE_DIR"; printf '%s' "$1" > "$STATE_DIR/constitution.yaml"; }
seal_constitution()  { # seal whatever bytes are on disk RIGHT NOW
  mkdir -p "$COUNCIL_DIR"
  printf '{"seq":1,"record":{"constitutionDigest":"%s"}}\n' \
    "$(sha256sum < "$STATE_DIR/constitution.yaml" | awk '{print $1}')" > "$COUNCIL_LINEAGE"
}
unseal() { rm -f "$COUNCIL_LINEAGE"; }
anchor_to() { write_constitution "$(constitution_yaml "$1" "${2:-}")"; seal_constitution; }

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by, assignee) VALUES ('$1',$(sqlq "${2:-t}"),'todo','dev','dev');"; }
answered()  { db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }
provof()    { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }
tierof()    { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }
revof()     { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
hashof()    { db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE ident='$1';"; }
setrev()    { db "UPDATE tasks SET routed_reviewer=$(sqlq "$2") WHERE ident='$1';"; }

export SUDO_UID=1234          # agent-ish uid: NOT the non-agent human-evidence form
touch "$GATE_PROOF_ENFORCE"   # enforcement ON — the human-only floor is live

# ======================================================================================
# CALLER-IDENTITY PIN (DIVE-2365). The `export SUDO_UID` above is INERT, and every forge
# arm in this file depends on it.
#
# `_gate_sudo_uid_nonagent` reads SUDO_UID **only** in its root branch (DIVE-1413).
# Unprivileged — which is how this suite runs — it reads `id -u`: whoever launched the
# harness. On a 5dive box that is an `agent-*` user, so the arms below were handed their
# "the caller is an agent" precondition by the HOST, for free, and nobody noticed it was
# never established here. GitHub's runner is `runner`, a name that does not start with
# `agent-`, so the real resolver correctly reported non-agent human evidence, the forge
# CLEARED, and S13/S17 (and E3b next door) failed — with S14 falling over behind S13
# because its gate had already been closed by the answer S13 was supposed to refuse.
#
# The inversion is the dangerous half: the identical harness on a box where the caller is
# non-agent grades the OPPOSITE behaviour and still prints `ok`. So the precondition is
# pinned here and ASSERTED at each site, never inherited.
#
# `_gate_is_root` is the DIVE-1401 seam (S15 uses the same one). The passwd LOOKUP is
# stubbed for the pinned uid alone; anything else falls through to the real getent. The
# resolver itself is NOT stubbed — the root branch, the unknown-uid refusal and the
# `agent-*` prefix test all still run, against a name this file controls rather than one
# the host happens to supply.
# ======================================================================================
AGENT_UID=1234
agent_caller_on() {
  _gate_is_root() { return 0; }
  getent() {
    if [[ "${1:-}" == passwd && "${2:-}" == "$AGENT_UID" ]]; then
      printf 'agent-fixture:x:%s:%s::/home/agent-fixture:/bin/bash\n' "$AGENT_UID" "$AGENT_UID"
      return 0
    fi
    command getent "$@"
  }
  export SUDO_UID="$AGENT_UID"
}
agent_caller_off() { unset -f getent; _gate_is_root() { [[ $EUID -eq 0 ]]; }; }
# The anchor. Reads the REAL resolver and refuses to let a forge arm run under a caller
# it would treat as human — that is the exact state in which the arm inverts silently.
assert_agent_caller() { # <label>
  if _gate_sudo_uid_nonagent; then
    bad_t "$1 precond: caller pinned as an AGENT" \
      "the real resolver still reports NON-AGENT human evidence — the forge arm below would \
grade the opposite behaviour and report ok (this is DIVE-2365)"
  else
    ok_t "$1 precond: the pinned caller reads as an AGENT to the real resolver"
  fi
}
agent_caller_on

# A routed tier-1 approval owned by dev, routed to $1. Returns the ident.
mk_routed() { # <ident> <reviewer>
  seed_task "$1" "delegated push for the retry backoff fix"
  cmd_task_need "$1" --type=approval --tier=1 \
    --ask="approve delegated push for review of branch fix-retry-backoff" --from=dev >/dev/null 2>&1
  setrev "$1" "$2"
}

# ======================================================================================

# ITEM 2 — the tier-2 nonce: mint, EMIT, verify
# ======================================================================================

anchor_to marcus

# --------------------------------------------------------------------------------------
# S10 MINT. A tier-2 `decision` — the exact shape of the gate that closed DIVE-2131 —
#     now mints a per-gate nonce. Before this change the mint was type-conditional and
#     `decision` got nothing, so its answer row had no non-forgeable field at all.
# --------------------------------------------------------------------------------------
seed_task DIVE-506 "pick the rollout order"
cmd_task_need DIVE-506 --type=decision --tier=2 --options="A|B" --recommend=A \
  --ask="which rollout order" --from=dev >/dev/null 2>&1
[[ "$(tierof DIVE-506)" == "2" && -n "$(hashof DIVE-506)" ]] \
  && ok_t "S10 a tier-2 DECISION now mints a per-gate nonce (it minted none before)" \
  || bad_t "S10 t2 decision mints" "tier=$(tierof DIVE-506) hash='$(hashof DIVE-506)'"
T2_NONCE="$(last_nonce)"
[[ "$T2_NONCE" =~ ^[0-9a-f]{32}$ ]] \
  && ok_t "S10b the raw nonce reaches the notifier in the shape the deployed regex accepts" \
  || bad_t "S10b nonce shape" "'$T2_NONCE'"

# --------------------------------------------------------------------------------------
# S11 TIER 1 IS UNCHANGED. The mint widened to tier 2 only; a tier-1 decision must still
#     mint nothing, or every ordinary agent-clearable gate just grew a human floor.
# --------------------------------------------------------------------------------------
seed_task DIVE-507 "pick the rollout order"
cmd_task_need DIVE-507 --type=decision --tier=1 --options="A|B" \
  --ask="which rollout order" --from=dev >/dev/null 2>&1
[[ -z "$(hashof DIVE-507)" ]] \
  && ok_t "S11 a tier-1 decision still mints NO nonce (the widening is tier-scoped)" \
  || bad_t "S11 t1 mints nothing" "hash='$(hashof DIVE-507)'"

# --------------------------------------------------------------------------------------
# S12 EMIT — the half that makes verification possible at all. The decision buttons must
#     carry the nonce in callback_data, and the result must match the DEPLOYED contract
#     `TNA_RE = /^tna:(\d+):([^:]+)(?::([0-9a-f]{32}))?$/` (verified against the installed
#     telegram 0.5.35/0.5.36 artifacts, not just the plugins repo). Asserting our own
#     emitter against our own idea of the format would prove nothing — the regex literal
#     below is COPIED from the deployed plugin.
# --------------------------------------------------------------------------------------
TNA_RE_DEPLOYED='^tna:[0-9]+:[^:]+(:[0-9a-f]{32})?$'
mk=$(_task_gate_reply_markup 42 decision "A|B" "A" "$T2_NONCE" claude)
cb=$(printf '%s' "$mk" | jq -r '.inline_keyboard[0][0].callback_data')
[[ "$cb" == *":$T2_NONCE" ]] \
  && ok_t "S12 the DECISION callback_data now carries the nonce (it did not before)" \
  || bad_t "S12 decision emits nonce" "cb='$cb'"
[[ "$cb" =~ $TNA_RE_DEPLOYED ]] \
  && ok_t "S12b it still matches the DEPLOYED TNA_RE — no plugin change required" \
  || bad_t "S12b deployed regex match" "cb='$cb'"
(( ${#cb} <= 64 )) \
  && ok_t "S12c callback_data stays inside Telegram's 64-byte cap (${#cb} bytes)" \
  || bad_t "S12c callback cap" "${#cb} bytes: $cb"
mk0=$(_task_gate_reply_markup 42 decision "A|B" "A" "" claude)
cb0=$(printf '%s' "$mk0" | jq -r '.inline_keyboard[0][0].callback_data')
[[ "$cb0" == "tna:42:0" ]] \
  && ok_t "S12d a gate with NO nonce emits byte-identical callback_data to today's" \
  || bad_t "S12d no-nonce unchanged" "cb0='$cb0'"

# --------------------------------------------------------------------------------------
# S12e THE FENCE (DIVE-2233). S12b above grades a literal TRANSCRIBED from one plugin. A
#      copy cannot detect the case that actually bites: a FORK whose regex differs. It
#      does. telegram / -codex / -grok / -agy / -qwen carry the optional nonce group, but
#      telegram-opencode and telegram-pi still use the pre-DIVE-916 `/^tna:(\d+):(.+)$/`,
#      whose group 2 is GREEDY — it swallows ":<nonce>" into the token, and a decision
#      then resolves `opts[Number("0:<nonce>")]` = opts[NaN] = undefined = 'invalid'. The
#      tap is silently dropped. (Those two forks are already broken TODAY for approval /
#      secret / manual, which have carried the suffix since DIVE-916; this change would
#      extend it to `decision`, the last type still working there. No agent is currently
#      exposed — `5dive agent list` shows the only opencode agent with CHANNELS=none and
#      no pi agents — so the harm is prospective, not live.)
#
#      So this arm enumerates the real ARTIFACTS instead of trusting the transcription,
#      and pins the laggards as a KNOWN set. A new fork going greedy reds here; a laggard
#      being FIXED also reds, which is the nudge to shrink the list. The plugins tree is
#      not present on a bare CI checkout, so its absence SKIPS LOUDLY — a silent skip
#      would make this fence indistinguishable from a fence that passed.
PLUG=""
for _p in /home/claude/projects/5dive/5dive-plugins/plugins \
          "$HOME/.claude/plugins/marketplaces/5dive-plugins/plugins"; do
  [[ -d "$_p" ]] && { PLUG="$_p"; break; }
done
if [[ -z "$PLUG" ]]; then
  printf 'SKIP - S12e fork-regex fence: no 5dive-plugins tree reachable (NOT a pass)\n'
else
  _greedy=""; _tolerant=""
  for _f in "$PLUG"/telegram*/tna.ts; do
    [[ -f "$_f" ]] || continue
    _re=$(grep -h 'export const TNA_RE' "$_f" 2>/dev/null)
    [[ -n "$_re" ]] || continue
    if [[ "$_re" == *'[0-9a-f]{32}'* ]]; then _tolerant+=" $(basename "$(dirname "$_f")")"
    else                                      _greedy+=" $(basename "$(dirname "$_f")")"; fi
  done
  # Non-vacuity: the scan must actually have found forks, or "no greedy forks" is a lie.
  [[ -n "$_tolerant" ]] \
    && ok_t "S12e precond: the fork scan reached real tna.ts artifacts ($(echo $_tolerant | wc -w) nonce-tolerant)" \
    || bad_t "S12e scan found nothing" "PLUG=$PLUG"
  [[ "$(echo $_greedy | tr ' ' '\n' | sort | tr '\n' ' ')" == "telegram-opencode telegram-pi " ]] \
    && ok_t "S12e the greedy-token forks are EXACTLY the two known laggards (opencode, pi)" \
    || bad_t "S12e laggard set changed" "greedy='$_greedy' — a new fork drifted, or one was fixed; update the list"
  # And the emitted value must satisfy every TOLERANT fork's OWN regex, read from disk.
  _bad=""
  for _f in "$PLUG"/telegram*/tna.ts; do
    [[ -f "$_f" ]] || continue
    _re=$(grep -h 'export const TNA_RE' "$_f" 2>/dev/null); [[ "$_re" == *'[0-9a-f]{32}'* ]] || continue
    node -e 'const m=process.argv[1].match(/\/(\^.*\$)\//);if(!m)process.exit(2);process.exit(new RegExp(m[1]).test(process.argv[2])?0:1)' \
      "$_re" "$cb" 2>/dev/null || _bad+=" $(basename "$(dirname "$_f")")"
  done
  [[ -z "$_bad" ]] \
    && ok_t "S12e the emitted callback satisfies each tolerant fork's OWN on-disk regex" \
    || bad_t "S12e a tolerant fork rejects our callback" "rejected by:$_bad cb='$cb'"
fi

# --------------------------------------------------------------------------------------
# S13 VERIFY — THE DIVE-2131 FORGE. A bare `--human` on a tier-2 gate that HAS a nonce,
#     from an agent-ish SUDO_UID and with no proof, is exactly the answer that closed
#     DIVE-2131 with need_answered_uid=1004 and human_nonce_hash NULL. It is now REFUSED.
# --------------------------------------------------------------------------------------
FAKE_CALLER="agent-main"
assert_agent_caller S13
out=$(cmd_task_answer DIVE-506 --value=A --from=main --human 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-506)" == "open" ]] \
  && ok_t "S13 THE FORGE IS DEAD: bare --human on a nonce-bearing tier-2 gate is refused" \
  || bad_t "S13 forge refused" "rc=$rc state=$(answered DIVE-506) out=$out"

# --------------------------------------------------------------------------------------
# S14 NON-VACUITY FOR S13: the SAME gate, SAME caller, SAME uid, plus the real nonce —
#     clears. Without this, an implementation that rejects every tier-2 human answer
#     would pass S13 while having broken the tap entirely.
# --------------------------------------------------------------------------------------
out=$(cmd_task_answer DIVE-506 --value=A --from=main --human --human-proof="$T2_NONCE" 2>&1); rc=$?
[[ $rc -eq 0 && "$(answered DIVE-506)" == "closed" ]] \
  && ok_t "S14 the REAL TAP (same caller + the nonce) clears — only the proof differs" \
  || bad_t "S14 real tap clears" "rc=$rc state=$(answered DIVE-506) out=$out"

# --------------------------------------------------------------------------------------
# S15 THE OTHER EVIDENCE FORM. A non-agent SUDO_UID (dashboard exec / human-on-box) also
#     clears, with no nonce — the two DIVE-916 forms stay EQUIVALENT and are never
#     double-gated (DIVE-525).
#     This arm flips the caller pin to the OTHER side: SUDO_UID=0 under the DIVE-1401
#     root seam. It is the only arm that wants non-agent evidence. The resolver itself is
#     NOT stubbed and neither is this lookup — uid 0 misses the pinned-uid branch of the
#     `getent` stub, so `root` comes from the real passwd db and still has to survive the
#     real agent-* check inside the resolver.
#     (Historic note, DIVE-2365: this comment used to say the harness "falls to `id -u` =
#     the agent running the suite" — asserting as a property the very thing that was only
#     ever true by accident of who ran it. That is what the pin above now establishes.)
# --------------------------------------------------------------------------------------
seed_task DIVE-508 "pick the rollout order"
cmd_task_need DIVE-508 --type=decision --tier=2 --options="A|B" \
  --ask="which rollout order" --from=dev >/dev/null 2>&1
SAVED_UID="$SUDO_UID"; export SUDO_UID=0   # root: a real, non-agent uid
_gate_is_root() { return 0; }
# DIVE-2371: the non-agent evidence form now needs a STRUCTURAL half too
# (`_gate_human_principal` = the uid test AND `_gate_cgroup_human_capable`). This
# arm describes the dashboard exec / human-on-box, which IS the accepted surface,
# so flip the cgroup with the uid — otherwise the answer below reads the host's
# real cgroup and S15 grades the fixture. Scoped to S15 and restored with the uid
# below, so S16/S17 keep the agent pin. The precond on the next line deliberately
# still asserts the UID half alone: it is what it names.
_gate_caller_cgroup() { printf '%s' '/system.slice/shelld.service'; }
_gate_sudo_uid_nonagent \
  && ok_t "S15 precond: the real resolver accepts SUDO_UID=0 as non-agent evidence" \
  || bad_t "S15 precond" "_gate_sudo_uid_nonagent refused SUDO_UID=0 under the root seam"
out=$(cmd_task_answer DIVE-508 --value=A --from=main --human 2>&1); rc=$?
export SUDO_UID="$SAVED_UID"
# Restore the AGENT side of the structural half with the uid. Pinned explicitly
# rather than left to read the host, so S16/S17 grade the same on a box and on a
# runner — the DIVE-2365 lesson that a property true by accident of who ran the
# suite is not a property at all.
_gate_caller_cgroup() { printf '%s' '/system.slice/system-5dive.slice/5dive-agent@dev.service'; }
agent_caller_on                            # back to the AGENT pin for S16/S17 below
[[ $rc -eq 0 && "$(answered DIVE-508)" == "closed" ]] \
  && ok_t "S15 a non-agent SUDO_UID still clears with no nonce (forms stay equivalent)" \
  || bad_t "S15 sudo_uid form" "rc=$rc state=$(answered DIVE-508) out=$out"

# --------------------------------------------------------------------------------------
# S16 THE COMPATIBILITY HINGE. A tier-2 gate filed by the OLD code has no stored hash, and
#     its already-rendered buttons physically cannot carry a proof. Demanding evidence
#     there would reject real human taps on every gate in flight at deploy time. So a
#     no-hash tier-2 gate keeps clearing on provenance. This arm is why the rule is scoped
#     to "has a nonce" rather than to the tier.
# --------------------------------------------------------------------------------------
seed_task DIVE-509 "pick the rollout order"
cmd_task_need DIVE-509 --type=decision --tier=2 --options="A|B" \
  --ask="which rollout order" --from=dev >/dev/null 2>&1
db "UPDATE tasks SET human_nonce_hash=NULL WHERE ident='DIVE-509';"   # the pre-fix row shape
out=$(cmd_task_answer DIVE-509 --value=A --from=main --human 2>&1); rc=$?
[[ $rc -eq 0 && "$(answered DIVE-509)" == "closed" ]] \
  && ok_t "S16 a legacy tier-2 gate with NO minted nonce still clears (in-flight taps live)" \
  || bad_t "S16 legacy compat" "rc=$rc state=$(answered DIVE-509) out=$out"

# --------------------------------------------------------------------------------------
# S17 A WRONG nonce is not a nonce. Guards against a verifier that checks presence rather
#     than value.
# --------------------------------------------------------------------------------------
seed_task DIVE-510 "pick the rollout order"
cmd_task_need DIVE-510 --type=decision --tier=2 --options="A|B" \
  --ask="which rollout order" --from=dev >/dev/null 2>&1
assert_agent_caller S17
out=$(cmd_task_answer DIVE-510 --value=A --from=main --human --human-proof="$(printf '0%.0s' {1..32})" 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-510)" == "open" ]] \
  && ok_t "S17 a WRONG proof is refused (the value is checked, not its presence)" \
  || bad_t "S17 wrong proof" "rc=$rc state=$(answered DIVE-510) out=$out"

# --------------------------------------------------------------------------------------
# M — THE MINT ITSELF (DIVE-2233 item 2, found by Marcus on the pre-merge read).
#     Everything above assumes a nonce exists. If the mint silently yields nothing, the
#     tier-2 block is SKIPPED and a bare `--human` is accepted with no proof — the floor
#     is absent on that box while every gate on it still looks protected. That is
#     DIVE-2131 restated, so it is graded here rather than assumed away.
# --------------------------------------------------------------------------------------
# M1 THE FALLBACK. openssl broken must NOT disarm the floor: /dev/urandom is the same
#    kernel CSPRNG openssl seeds from, so the nonce is not weaker for coming from it.
( openssl() { return 1; }
  n=$(_human_nonce_mint) && [[ "$n" =~ ^[0-9a-f]{32}$ ]] ) \
  && ok_t "M1 a broken openssl falls back to /dev/urandom and still mints 32 hex chars" \
  || bad_t "M1 fallback mint" "no well-formed nonce when openssl fails"
# M1b the mint VALIDATES rather than trusting: a truncated 12-char read is not a nonce.
( _human_nonce_mint() { printf 'abc123'; }
  [[ "$(_human_nonce_mint)" =~ ^[0-9a-f]{32}$ ]] ) \
  && bad_t "M1b short value must not pass as a nonce" "12 chars accepted" \
  || ok_t "M1b a short/truncated value is not a well-formed nonce"

# M2 THE REFUSAL. Both sources gone => a tier-2 gate must REFUSE TO FILE. Filing it would
#    create a gate claiming a hard human floor it cannot enforce.
_af_reset 2>/dev/null || true
seed_task DIVE-520 "rotate the prod signing key"
out=$( _human_nonce_mint() { return 1; }
       cmd_task_need DIVE-520 --type=decision --tier=2 --options="A|B" \
         --ask="which rollout order" --from=dev 2>&1 ); rc=$?
[[ $rc -ne 0 ]] \
  && ok_t "M2 a tier-2 gate whose nonce cannot be minted REFUSES to file (rc=$rc)" \
  || bad_t "M2 mint-failure refused" "rc=$rc out=$out"
[[ "$out" == *"cannot mint its own human proof"* ]] \
  && ok_t "M2 the refusal names the cause (RNG), not a generic internal error" \
  || bad_t "M2 refusal names cause" "out=$out"
[[ -z "$(hashof DIVE-520)" && "$(db "SELECT COALESCE(need_type,'') FROM tasks WHERE ident='DIVE-520';")" == "" ]] \
  && ok_t "M2 no half-filed gate is left behind (need_type unset, no hash)" \
  || bad_t "M2 no partial gate" "type='$(db "SELECT COALESCE(need_type,'') FROM tasks WHERE ident='DIVE-520';")' hash='$(hashof DIVE-520)'"

# M3 SCOPE. The refusal is tier-2 ONLY. A tier-1 gate with the same broken mint still
#    files — its NULL hash means what it always meant, and DIVE-916's verify path fails
#    closed on it unchanged. Widening the refusal would take out gate filing for no gain.
seed_task DIVE-521 "pick the rollout order"
out=$( _human_nonce_mint() { return 1; }
       cmd_task_need DIVE-521 --type=decision --tier=1 --options="A|B" \
         --ask="which rollout order" --from=dev 2>&1 ); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "M3 a TIER-1 gate with the same broken mint still files (refusal is scoped)" \
  || bad_t "M3 tier-1 unaffected" "rc=$rc out=$out"

# M4 NON-VACUITY FOR M2. The same gate shape with a WORKING mint files fine — without
#    this, an M2 that passed because `cmd_task_need` is broken for every tier-2 gate
#    would be indistinguishable from one that passed for the right reason.
seed_task DIVE-522 "rotate the prod signing key"
out=$(cmd_task_need DIVE-522 --type=decision --tier=2 --options="A|B" \
        --ask="which rollout order" --from=dev 2>&1); rc=$?
[[ $rc -eq 0 && -n "$(hashof DIVE-522)" ]] \
  && ok_t "M4 the SAME gate with a working mint files and stores a hash (M2 is not vacuous)" \
  || bad_t "M4 non-vacuity" "rc=$rc hash='$(hashof DIVE-522)' out=$out"

printf '\n%s\n' "-----------------------------------------------"
printf 'DIVE-2233 item 2 — tier-2 nonce: mint, emit, verify: %d passed, %d failed\n' "$PASS" "$FAIL"
rc=0; [[ $FAIL -eq 0 ]] || rc=1
exit "$rc"
