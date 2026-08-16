# -------- 5dive task — answer --------
#
# Split out of src/cmd_task.sh (DIVE-3278): answering a gate: bounce detection, the tap log, delegated answers, `task
# answer`, `task escalate`, `task rm`.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
# src/cmd_task.sh when the split tree is used (tests source src/cmd_task.sh).
# Function definitions only — never execute this file directly.
# DIVE-2572: does a loop-gate answer BOUNCE to the previous step, or ADVANCE?
#
# THE DEFECT THIS REPLACES: five BARE SUBSTRING tests over the whole free-text
# answer — *"better"*, *"reject"*, *"deny"*, *"denied"*, *"declin"*. Any answer
# containing those letters ANYWHERE was classified as a bounce, whatever it
# actually decided.
#
# MEASURED ON THE LIVE BOARD before choosing a fix, because the row asked for
# that rather than a hunch: 268 answered gates, 14 carry a trigger substring. Of
# the answers that are a HUMAN decision on a loop-shaped row, FIVE OF FIVE would
# have been misclassified as bounces, and every one of them APPROVES:
#   DIVE-2552  "approve — ..."      trigger: "uppercase is rejected" (what a regex does)
#   DIVE-2565  "approve — ..."      trigger: "deny-by-default flow"  (a design pattern's NAME)
#   DIVE-2596  "approve — ..."      trigger: "See my reject feedback on this task"
#   CNCL-9     "clear-now ..."      trigger: "the rebase I filed in the reject"
#   DIVE-1572  "a — render inline"  trigger: "B rejected:" (naming the option NOT chosen)
# The only true denials in the whole set are the bare word "denied" (DIVE-1513,
# DIVE-1614) — short, leading, unambiguous.
#
# THE FAILURE IS SYSTEMATIC, NOT RANDOM, and that is what settles the design: an
# approval that RESOLVES a previous bounce naturally cites that bounce ("see my
# reject feedback", "the rebase I filed in the reject"), and a decision between
# options names the option it turned down ("B rejected"). So the reviewer doing
# the most careful job — referring back to what they asked for — is the one most
# likely to be read as bouncing. Option (d) from the row ("prose answers are the
# exception") is refuted by the same data: prose is what substantive answers ARE.
#
# SO: read the decision out of the DECISION SEGMENT (option (b)) — the first
# non-blank line up to the first em-dash, colon, semicolon, comma or stop — and
# warn rather than silently choose when a trigger appears later in the prose.
#
# Option (a), anchoring to the leading TOKEN, was built first and refuted by the
# existing suite: task_answer_cancelled_loop_bounce_unit went 5/7 on the fixture
# "Do better ↩", an ordinary bounce whose decision word is the SECOND token.
# Short imperatives are the register a real bounce is written in, so the leading
# token trades one systematic miss for another. Recorded because it generalises:
# the measurement above sampled only FALSE POSITIVES and said nothing about what
# TRUE bounces look like, and the true-bounce shape is what killed design (a).
#
# THREE THINGS INHERITED FROM THE SAME DEFECT ONE FILE OVER (DIVE-2614,
# community/wiki/a-verdict-regex-scans-every-line-not-the-verdict.md), applied
# here deliberately rather than rediscovered:
#   1. WORD BOUNDARY. Without \b, "deny" prefix-matches nothing useful but
#      "better" matches "betterment" and "decline" matches "declined" only by
#      accident of stemming.
#   2. INFLECTIONS ARE ENUMERATED BY HAND. With \b, `reject` no longer matches
#      "rejected" — that gap has now been confirmed three times in this codebase.
#      Collapsing to (reject|deny|declin)(e|es|ed|ing)?\b is NOT equivalent: it
#      re-admits stems we never intended. Any new stem needs its forms added here.
#   3. FIRST NON-BLANK LINE, NOT LINE 1. A leading blank line would otherwise
#      make the verdict read empty — and empty means ADVANCE here, i.e. a false
#      APPROVE, which is the worse direction and exactly the trap main caught in
#      review on DIVE-2614. `|| true` because grep exits 1 on an all-blank value
#      and pipefail would kill the caller.
#
# "better" is kept, but only inside the decision segment. Unanchored it was the
# worst arm in the set ("approve, this is better than the alternative" bounced);
# in a decision segment it is a real bounce signal ("better: rework it", "Do
# better").
#
# THE SAFETY PROPERTY THIS RELIES ON IS ABOUT SEGMENTS, NOT ABOUT FIRST WORDS, and
# it is measured rather than assumed (olivia's reject, iteration 1 — the earlier
# comment claimed "no answer on the board STARTS with it", which is a different
# and weaker claim than the code needs). Swept all 268 answered gates on the live
# board and extracted each one's decision segment: exactly TWO carry any stem at
# all — DIVE-1513 and DIVE-1614, both the bare word "denied", both true denials —
# and ZERO carry "better". So on the entire recorded population this rule fires
# twice and is right both times.
# Note the scope: that is a statement about answers ALREADY WRITTEN, not a
# guarantee about future phrasing. It is why the advisory below exists.
#
# Returns 0 for BOUNCE, 1 for ADVANCE. Sets _LOOP_BOUNCE_AMBIGUOUS=1 when the
# answer ADVANCES but carries a trigger word later on, so the caller can say so.
_LOOP_BOUNCE_STEMS='reject|rejects|rejected|rejecting|deny|denies|denied|denying|decline|declines|declined|declining|better'
_loop_answer_is_bounce() {
  local _v="${1:-}" _first="" _seg=""
  _LOOP_BOUNCE_AMBIGUOUS=0
  _first=$(printf '%s' "$_v" | grep -m1 -v '^[[:space:]]*$' || true)
  _first="${_first#"${_first%%[![:space:]]*}"}"
  # THE DECISION SEGMENT: the first non-blank line, cut at the first em-dash,
  # colon, semicolon, comma or sentence stop. Everything after that is the
  # REASONING, and the reasoning is where the false positives live.
  _seg="${_first%%[—:;,.]*}"
  if printf '%s' "$_seg" | grep -qE "\b(${_LOOP_BOUNCE_STEMS})\b"; then
    return 0
  fi
  # Advancing — but say so when the vocabulary appears anywhere, rather than
  # silently choosing. This is the compatibility window: it surfaces the real
  # population before anything is gated on it
  # (community/wiki/a-control-partitions-a-population-and-populations-drift.md).
  printf '%s' "$_v" | grep -qE "\b(${_LOOP_BOUNCE_STEMS})\b" && _LOOP_BOUNCE_AMBIGUOUS=1
  return 1
}

# ── DIVE-3128: a button tap, attributed and recorded ─────────────────────────
#
# WHO the tapping Telegram uid IS. Resolution order, widest evidence first:
#
#   1. ${STATE_DIR}/humans.json  — `{"humans": {"<tg-uid>": "<name>"}}`. An
#      explicit operator-maintained map. It is the only source that can give a
#      person the name the org actually calls them, so it wins.
#   2. the Telegram @username carried on the SAME callback. Telegram owns this
#      field; the relaying bot cannot set it for someone else. Shape-checked to
#      Telegram's own handle grammar so nothing exotic reaches a provenance
#      string.
#   3. `tg:<uid>` — the honest non-answer.
#
# RUNG 3 IS THE POINT OF THE LADDER, not its fallback embarrassment. The defect
# this closes is a row that named the WRONG principal, not a row that named
# nobody: `human:tg:1234567890` says "a person we have not put a name to tapped
# this", which a reader can act on, and it cannot collide with a roster name
# because agent names are bare tokens and this one carries a colon. There is
# deliberately no rung that falls back to the RELAYING AGENT'S name — that rung
# is precisely DIVE-3045.
#
# The map file is read at CALL time, not resolved at source time, so a harness
# that sets STATE_DIR after sourcing (every harness in tests/) points at its own
# fixture rather than the box's.
_gate_tap_human_name() {
  local uid="${1:-}" uname="${2:-}" mapped=""
  [[ "$uid" =~ ^-?[0-9]{1,20}$ ]] || { printf ''; return 1; }
  local map="${HUMANS_MAP:-${STATE_DIR}/humans.json}"
  if [[ -r "$map" ]]; then
    mapped=$(jq -r --arg u "$uid" '(.humans[$u] // empty)' "$map" 2>/dev/null || true)
    # A mapped value still has to be a plain token: this string is about to be
    # concatenated into `human:<name>` and stored as provenance, and a mapping
    # file carrying `lodar human:root` would forge a second field.
    [[ "$mapped" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,31}$ ]] && { printf '%s' "$mapped"; return 0; }
  fi
  uname="${uname#@}"
  # Telegram's own handle rule: 5-32 chars, letters/digits/underscore, letter
  # first. Same grammar cmd_telegram_resolve_handle validates against.
  [[ "$uname" =~ ^[A-Za-z][A-Za-z0-9_]{4,31}$ ]] && { printf '%s' "$uname"; return 0; }
  printf 'tg:%s' "$uid"
}

# THE TAP LEDGER. Before this, an inline-button tap was the LEAST logged path in
# the system for the control that is supposed to be the most rigorously evidenced:
# the callback arrived, a `task answer` ran, and the only trace was whatever the
# answer itself stored. Reconstructing "did a human really press this, and which
# human" meant reading someone else's shell history.
#
# Append-only JSONL next to the other append-only ledgers (the council's
# veto-audit.jsonl), same permissions posture: 0600, root-owned when we are root.
# Best-effort by construction — a box that cannot write this file must not lose a
# human's answer over it — but "best effort" here means the WRITE may fail, never
# that the call is skipped.
#
# THE RAW NONCE IS NEVER WRITTEN. `human_nonce_hash` is hash-only at rest for the
# reason DIVE-916 gives, and a ledger that recorded the presented nonce would undo
# that at a second address. We record only WHETHER one was presented.
_gate_tap_log() {
  local log="${GATE_TAP_LOG:-${STATE_DIR}/gate-taps.jsonl}"
  local dir="${log%/*}"
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
  local line
  line=$(jq -cn \
    --arg ts        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg ident     "${1:-}" \
    --arg tier      "${2:-}" \
    --arg type      "${3:-}" \
    --arg tap_uid   "${4:-}" \
    --arg tap_user  "${5:-}" \
    --arg tap_msg   "${6:-}" \
    --arg relay     "${7:-}" \
    --arg resolved  "${8:-}" \
    --arg stamp     "${9:-}" \
    --arg nonce     "${10:-}" \
    --arg verdict   "${11:-}" \
    --arg via       "${12:-}" \
    '{ts:$ts, gate:$ident, tier:$tier, type:$type, tap_uid:$tap_uid,
      tap_username:$tap_user, tap_message_id:$tap_msg, relay_agent:$relay,
      resolved_human:$resolved, resolved_via:$via, stamped_as:$stamp,
      human_proof:$nonce, verdict:$verdict}' 2>/dev/null) || return 0
  printf '%s\n' "$line" >>"$log" 2>/dev/null || return 0
  chmod 0600 "$log" 2>/dev/null || true
  [[ $EUID -eq 0 ]] && chown root:root "$log" 2>/dev/null || true
  return 0
}

# ── DIVE-3160: `_task_answer` — the delegated, SIGNED gate clear ─────────────
#
# THE DEFECT. A cli-scoped lead can CLEAR a gate it cannot SIGN. cmd_task_answer
# signs the DIVE-756 closure in-process only at EUID 0; every other caller shells
# out to `sudo -n 5dive gate-proof sign`, and a cli-scoped seat holds no grant for
# it (its own `_sig_why` string says so, a few hundred lines below). Signing is
# best-effort by design, so the answer LANDS UNSIGNED and `require_sig=1` on the
# push/deploy root executors refuses it later — on the MAKER's next round-trip,
# with a message about tampering. Standing to clear and capability to sign were
# decided in two different places and nothing lined them up.
#
# WHY NOT THE OBVIOUS FIX — this is the load-bearing paragraph. "Grant a narrow
# root verb that seals the STORED ROW" reads far safer than `gate-proof sign` over
# stdin, and is not safer at all: /var/lib/5dive/tasks/tasks.db is `rw-rw----
# root:claude` and EVERY agent seat is in group `claude` (measured 2026-08-10 on
# both a cli-scoped seat and a root-all one), so a caller writes
# `need_answered_by='human:lodar'` with plain sqlite3 FIRST and then asks for the
# seal. tasks_db.sh's own note — "a raw-sqlite write that never ran
# cmd_task_answer leaves an unsigned/invalid row that gate-proof verify flags" —
# is the reason this HMAC exists at all. Narrowing the ARGUMENT (stdin -> ident)
# changes the transport and never the trust: the payload is caller-authored
# either way. The question is not what the verb accepts, it is who authored the
# bytes it will attest to.
#
# So this primitive signs at ANSWER time, from facts it establishes ITSELF:
#
#   1. EUID 0 or refuse — reachable only through the exact-path NOPASSWD grant.
#   2. WHO comes from SUDO_UID under sudo's env_reset, never argv, never --from.
#      `_gate_uid_to_agent` fails closed on anything that is not an `agent-*` row.
#   3. STANDING is re-derived AS ROOT FROM THE ROW (routed_reviewer, or the
#      sealed constitution's standing lead) — never from anything the caller
#      passed. Identity alone is not enough: a lead with standing on gate X must
#      not clear gate Y. (_gh_do's posture, and main's condition 1.)
#   4. It cannot stamp `human:*`. An agent-invoked path is by definition not a
#      human tap, so the human-evidence flags are REFUSED here and `human` is
#      additionally forced to 0 inside cmd_task_answer for this path (main's
#      condition 2 — the DIVE-916/1115/2224 forged-human residual is a known open
#      threat and a new root path must not become a fresh entrance to it).
#   5. cmd_task_answer then runs its OWN authorization unchanged, at EUID 0, and
#      signs in-process. Every check above is a SUBSET guard that refuses EARLIER;
#      this primitive grants nothing and cannot widen who may clear what.
#
# SELF-CLEAR (main's open design question, settled here): a maker may not have its
# own gate signed, and the maker is `maker_agent` — the loop spec's maker — NEVER
# `assignee`. On DIVE-2159, the acceptance row for this ticket, `assignee` is the
# VERIFIER (main2) and `maker_agent` is dev: a self-clear check keyed on assignee
# would have refused the one legitimate clear this whole ticket exists to make
# signable. When a row names no maker the check stays SILENT rather than guessing
# from assignee — a guess in that column is exactly the error just described.
# Every argument to `task answer` that can raise `human`, or that names an actor
# the caller was not measured to be. A PREDICATE over ONE argument, so the harness
# can grade the exact list the executor loops over rather than a copy of it — and
# a source tripwire in that harness asserts the loop still calls this, because the
# usual failure of an extracted check is a call site that quietly stops using it.
_task_answer_forbidden_flag() {
  case "${1:-}" in
    --human|--human-proof=*|--channel-proof=*|--channel-msg=*|--tap-uid=*|--tap-username=*|--tap-msg=*|--relay-agent=*|--from=*) return 0 ;;
  esac
  return 1
}

cmd_task_answer_delegated() {
  [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "_task_answer is a privileged internal primitive (reachable only through the exact-path NOPASSWD grant)."

  # Parameters over stdin, NUL-separated, never argv (main's condition 3): nothing
  # gate-bearing lands in the process table, and the grant stays an exact command
  # path with no wildcard, so it holds identically under classic sudo and sudo-rs.
  # Same shape as _push_do and _gh_do.
  local -a args=(); local a
  while IFS= read -r -d '' a; do args+=("$a"); done
  (( ${#args[@]} )) || fail "$E_VALIDATION" "_task_answer got no arguments on stdin."

  # (2) WHO — the kernel's view of the DELEGATING caller. sudo's env_reset means
  # SUDO_UID here was set by sudo itself; a caller-supplied one is stripped before
  # this process starts. A root-all seat could of course forge it, but that seat
  # can already reach `gate-proof sign` directly — this grant hands it nothing new.
  local _ruid="${SUDO_UID:-}"
  [[ "$_ruid" =~ ^[0-9]+$ ]] \
    || fail "$E_AUTH_REQUIRED" "_task_answer: no SUDO_UID — reach this primitive through sudo from an agent seat, never as root directly (a root caller has no delegating agent to attribute the clear to)."
  [[ "$_ruid" != "0" ]] \
    || fail "$E_AUTH_REQUIRED" "_task_answer: SUDO_UID is root, which is not an agent seat."
  local _actor; _actor=$(_gate_uid_to_agent "$_ruid")
  [[ -n "$_actor" ]] \
    || fail "$E_AUTH_REQUIRED" "_task_answer: uid ${_ruid} owns no agent-* passwd row, so this clear has no attributable agent."

  # (4) NEVER human:*. Refused by NAME here so the refusal is greppable and lands
  # before any write; `human=0` is forced again inside cmd_task_answer so a flag
  # added later cannot reopen this.
  for a in "${args[@]}"; do
    _task_answer_forbidden_flag "$a" \
      && fail "$E_VALIDATION" "_task_answer refuses ${a%%=*}: an agent-invoked clear is never a human tap, and provenance here is derived from SUDO_UID rather than passed in. Use '5dive task answer' for a human-sourced answer."
  done

  local _ident=""
  for a in "${args[@]}"; do [[ "$a" == --* ]] && continue; _ident="$a"; break; done
  [[ -n "$_ident" ]] || fail "$E_VALIDATION" "_task_answer got no task ident on stdin."

  tasks_db_init
  # (3) STANDING, re-derived as root from the ROW. All four columns are
  # enum/agent-name/timestamp shaped, so the sqlite3 `|` separator is unambiguous.
  local _row
  _row=$(db "SELECT COALESCE(routed_reviewer,''),COALESCE(maker_agent,''),COALESCE(need_type,''),COALESCE(need_answered_at,'') FROM tasks WHERE ident=$(sqlq "$_ident") LIMIT 1;" 2>/dev/null || printf '')
  [[ -n "$_row" ]] || fail "$E_VALIDATION" "_task_answer: no task ${_ident}."
  local _rr _maker _ntype _answered _rest
  _rr="${_row%%|*}";     _rest="${_row#*|}"
  _maker="${_rest%%|*}"; _rest="${_rest#*|}"
  _ntype="${_rest%%|*}"; _answered="${_rest#*|}"

  [[ -n "$_ntype" ]]   || fail "$E_VALIDATION" "_task_answer: ${_ident} carries no gate."
  [[ -z "$_answered" ]] || fail "$E_CONFLICT" "_task_answer: the gate on ${_ident} was already answered at ${_answered} — answer-once has no re-sign path (re-file a fresh gate)."

  local _sl; _sl=$(_gate_standing_lead 2>/dev/null || printf '')
  if [[ "$_actor" != "$_rr" ]] && [[ -z "$_sl" || "$_actor" != "$_sl" ]]; then
    fail "$E_AUTH_REQUIRED" "_task_answer: ${_actor} holds no lead-clear standing on ${_ident} (routed reviewer: ${_rr:-<none>}). This primitive serves the lead-clear-that-cannot-sign case and nothing else."
  fi

  if [[ -n "$_maker" && "$_actor" == "$_maker" ]]; then
    fail "$E_AUTH_REQUIRED" "_task_answer: ${_actor} is the MAKER of ${_ident} — signing your own gate is a self-clear, refused here even when the row routes the clear back to you."
  fi

  TASK_ANSWER_DELEGATED=1
  cmd_task_answer "${args[@]}"
}

# The caller half: reach for the SIGNED path when, and only when, this seat is one
# whose closures land unsigned today. A seat that can sign directly keeps today's
# path byte for byte — routing a root-all seat through the executor would silently
# apply the new refusals to flows that never had them, which is a policy change
# this ticket was not asked to make. Failing closed is free here: on any refusal we
# fall through to the existing path, which lands the answer exactly as it does
# today (unsigned, with the DIVE-2760 notice naming the cause) — so this can make
# a closure signed and can never make an answer fail.
_task_answer_try_delegated() {
  [[ $EUID -ne 0 ]]                        || return 1   # root already signs in-process
  [[ -z "${TASK_ANSWER_DELEGATED:-}" ]]    || return 1   # no recursion from the executor
  sudo -n -l /usr/local/bin/5dive gate-proof sign >/dev/null 2>&1 && return 1
  sudo -n -l /usr/local/bin/5dive _task_answer    >/dev/null 2>&1 || return 1
  local _out _rc=0
  _out=$(printf '%s\0' "$@" | sudo -n /usr/local/bin/5dive _task_answer 2>&1) || _rc=$?
  if (( _rc == 0 )); then printf '%s\n' "$_out"; return 0; fi
  # It refused. Two different situations hide behind one exit code, so ASK THE ROW
  # rather than parse the message: if the gate is answered, the write landed and
  # re-running would trip answer-once or double-write; only an untouched gate may
  # fall through.
  local _ident="" a
  for a in "$@"; do [[ "$a" == --* ]] && continue; _ident="$a"; break; done
  if [[ -n "$_ident" ]]; then
    local _now; _now=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident=$(sqlq "$_ident") LIMIT 1;" 2>/dev/null || printf '')
    if [[ -n "$_now" ]]; then printf '%s\n' "$_out"; return 0; fi
  fi
  warn "the signed clear (_task_answer) refused, so this answer will store UNSIGNED:"
  printf '%s\n' "$_out" | sed 's/^/  /' >&2
  return 1
}

cmd_task_answer() {
  tasks_db_init
  # DIVE-3160: prefer the delegated SIGNED clear on a seat that cannot sign. Runs
  # before any parsing so the executor sees the caller's arguments verbatim.
  _task_answer_try_delegated "$@" && return 0
  local value="" value_set=0 from="" human=0 human_proof="" channel_proof="" channel_msg=""
  local tap_uid="" tap_username="" tap_msg="" relay_agent=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --value=*) value="${1#*=}"; value_set=1 ;;
      --from=*)  from="${1#*=}" ;;
      # DIVE-394: trusted human paths (the Telegram tap handler, the dashboard/API
      # exec) pass --human to mark the answer as human-sourced. Recorded as
      # provenance in need_answered_by; the enforced boundary for hard-line gates
      # is still root (below), so an agent passing --human gains nothing.
      --human)   human=1 ;;
      # DIVE-950: evidence-form (b), the DIVE-519 --proof token, is DROPPED — it
      # was agent-forgeable (`5dive gate-proof` mint is require_root only, so any
      # agent could `sudo`-mint a valid token: the easy one-sudo forge). The flag
      # is still PARSED but IGNORED — a rollout-safe no-op — so an in-flight caller
      # that still sends --proof=AUTO/<token> (an old dashboard/shelld mid-deploy)
      # does not hit "unknown flag"; it falls through to the surviving evidence
      # forms: (a) --human-proof nonce, or (c) a non-agent SUDO_UID.
      --proof=*) : ;;
      # DIVE-916: per-gate HUMAN nonce (from the Telegram tap callback_data /
      # dashboard payload) — the evidence form for the plugin-tap path, whose
      # SUDO_UID is the spawning agent. Verified against human_nonce_hash below.
      --human-proof=*) human_proof="${1#*=}" ;;
      # DIVE-1305: paired-human channel proof — a chat_id the trusted plugin
      # verified as the paired human's OWN verified DM (∈ access.json allowFrom).
      # Honored as human evidence ONLY for tier<2 gates (see below); a tier-2
      # hard gate (money/destructive/secret) NEVER accepts it and keeps its
      # per-gate button tap. This is the "go with recs from your own channel"
      # clear (lodar's chosen scope, DIVE-1305 decision 2026-07-16).
      --channel-proof=*) channel_proof="${1#*=}" ;;
      # DIVE-2412: the message_id of the human's OWN message in that verified DM.
      # This is the citation the tier-2 form is built on: the chat id above says
      # WHICH conversation, and only this says the human actually spoke in it —
      # and it is checked against Telegram, not against the caller's word.
      --channel-msg=*) channel_msg="${1#*=}" ;;
      # DIVE-3128: WHO TAPPED, and WHOSE BOT CARRIED IT — two flags because they
      # are two facts. The tap handler reads both straight off Telegram's
      # `callback_query`: `.from.id` is the person who pressed the button and
      # `.from.username` is their handle, neither of which the relaying agent
      # chooses. Before this the relay's own identity was all that reached the
      # row and it wore the `human:` prefix (DIVE-3045).
      #
      # These are PROVENANCE, not authority. Nothing below is authorized by them:
      # a tap still clears a tier-2 gate on the DIVE-916 nonce or a non-agent
      # SUDO_UID exactly as before, and passing --tap-uid without that evidence
      # buys nothing. What they change is what the record SAYS about an answer
      # that was already going to land.
      --tap-uid=*)      tap_uid="${1#*=}" ;;
      --tap-username=*) tap_username="${1#*=}" ;;
      --tap-msg=*)      tap_msg="${1#*=}" ;;
      --relay-agent=*)  relay_agent="${1#*=}" ;;
      --)        shift; positional+=("$@"); break ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task answer <id|DIVE-N> --value=\"...\"  (omit --value for a secret gate)"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # Must have a pending (unanswered) gate to answer.
  local nt
  nt=$(db "SELECT CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL THEN need_type ELSE '' END FROM tasks WHERE id=${id};")
  [[ -n "$nt" ]] || fail "$E_CONFLICT" "$ident has no pending human gate (nothing to answer)"

  # DIVE-2411: refuse to STAMP a secret gate that names no delivery path, before
  # any write. This is the same defect as the filing refusal in cmd_task_need, one
  # step later and strictly worse: the filing gap leaves a gate visibly stuck,
  # while this one CLOSES the loop with full provenance over nothing.
  #
  # MEASURED on DIVE-2232: need_answered_at set, need_answered_by=human:main,
  # uid 1004, need_answer_sig VALID, human_nonce_hash SET — a real human holding
  # the raw nonce tapped ✅ Provided — and no connector file was written that day,
  # no drop was ever minted, no value reached any channel. The record reads
  # "credential provided, human-attested, signed, nonced" and no credential exists.
  # Provenance and payload are INDEPENDENT and we only ever verified provenance.
  #
  # WHY THE AFFORDANCE FIX IS NOT ENOUGH ON ITS OWN. Withholding the button (see
  # _task_gate_reply_markup) only changes messages sent FROM NOW ON. Telegram inline
  # buttons on already-delivered messages never expire — the same fact DIVE-2228
  # turns on — so every legacy secret gate already in someone's chat history keeps a
  # live ✅ Provided button, and any of those taps still lands here. This is the
  # durable half; the affordance removal is the half that stops NEW ones.
  #
  # The predicate is the ROW's shape only — no caller-supplied input can satisfy it,
  # so there is nothing to forge. A gate that named a drop target still answers
  # normally (that is the legitimate "I ran `5dive secret write` myself" case), and
  # an explicitly out-of-band gate still answers, because its ask NAMED where the
  # value goes. Only "asks for a credential, names nowhere" is refused.
  if [[ "$nt" == "secret" ]]; then
    local _paths; _paths=$(db "SELECT COALESCE(secret_key,'')||COALESCE(connector,'')||COALESCE(secret_oob,'') FROM tasks WHERE id=${id};")
    [[ -n "$_paths" ]] || fail "$E_CONFLICT" "$ident is a secret gate that names NO delivery path, so nothing can have landed — re-file it with one: --secret-key=<ENV> --connector=<stem>, or --out-of-band=\"<where>\""
  fi

  # DIVE-1117: resolve the gate's stored risk tier now — the human-only + evidence
  # blocks below key on need_type (approval/secret/manual), but tier 2 is the true
  # hard-human floor. A `decision` gate can be FLOORED to tier 2 by the T2 category
  # heuristic (cmd_task_need), yet decision is agent-clearable BY TYPE, so those
  # blocks let it through. The tier-2 provenance floor further down uses this.
  local gtier; gtier=$(db "SELECT COALESCE(tier,'') FROM tasks WHERE id=${id};")

  # DIVE-2228: refuse a STATUS-MOVING answer on an already-CLOSED row, before any
  # write. cmd_task_answer's only precondition is the one above — "this row has an
  # unanswered gate" — and nothing in it is about status, while a closed task
  # carrying a dangling gate is an ordinary state (file a gate, then close or
  # cancel without answering it). Two writers below then ran with no status
  # predicate at all: the DIVE-909 close-as-done branch (WHERE id=${id}) and the
  # DIVE-552 loop-gate advance/bounce. MEASURED on an isolated fixture as a third
  # party who is neither maker nor verifier: on a `done` row, rc=0 and done_at
  # RE-STAMPED to now (the verifier's close time destroyed); on a `cancelled` row,
  # rc=0 and cancelled -> done, with _task_cascade_unblock then releasing its
  # dependents — something `task cancel` itself never does.
  #
  # `result` survived both, because DIVE-2067's CASE WHEN result='' guard was
  # already applied. THAT is why this was missed for so long: the field everyone
  # learned to watch was protected, so the row looked defended while status and
  # done_at were not. When auditing a status writer, check every field the close
  # sets, not just the one the verb names.
  #
  # REACHABILITY, stated precisely: every gate LIST query carries
  # status NOT IN ('done','cancelled'), so a freshly rendered inbox never offers
  # the button on a closed task. The exposure is the message ALREADY SENT —
  # callback_data tna:<id>:done -> teambot -> `task answer --value=done`. Telegram
  # inline buttons on delivered messages DO NOT EXPIRE, so a manual gate pinged
  # while the task was open keeps a live ✅ Done button in chat history
  # indefinitely, and a tap months later lands the write. The live surface is
  # filtered; the historical surface is not, and it outlives the state it was
  # rendered against.
  #
  # SCOPE is DIVE-2067's, not symmetry. Only the paths that MOVE the row are
  # refused. Answering a decision/approval/secret gate on a closed row is
  # measured clean (its else-branch is fenced on status='blocked') and stays
  # working — including the DIVE-931 secret-drop write, which may legitimately
  # land after the task closed. The refusal fires here rather than at the write
  # so the command is all-or-nothing: past this point the answer is already
  # recorded, and refusing there would leave a gate answered under a non-zero rc.
  local _lk _loop_bounce=0 _run="" _prev="" _prev_status="" _prev_ident="" _lv=""
  _lk=$(_loop_kind "$id")
  # DIVE-2572: the bounce/advance decision is read from the DECISION SEGMENT (the
  # first non-blank line up to its first dash/colon/comma/stop), not from a bare
  # substring over the whole answer. See _loop_answer_is_bounce.
  if [[ "$_lk" == gate:* ]]; then
    # Resolve the relay direction before any answer write.  A refusal below must
    # leave the gate pending; discovering the cancelled predecessor after the
    # answer was stamped would make a non-zero return lie about what committed.
    _lv=$(printf '%s' "${value:-}" | tr '[:upper:]' '[:lower:]')
    if _loop_answer_is_bounce "$_lv"; then
      _loop_bounce=1
      _run=$(db "SELECT COALESCE(parent_id,'') FROM tasks WHERE id=${id};")
      _prev=$(db "SELECT id FROM tasks WHERE parent_id=${_run:-0} AND id<${id} AND body LIKE '%${_LOOP_MARK}:%' ORDER BY id DESC LIMIT 1;")
      if [[ -n "$_prev" ]]; then
        _prev_status=$(db "SELECT status FROM tasks WHERE id=${_prev};")
        _prev_ident=$(db "SELECT ident FROM tasks WHERE id=${_prev};")
      fi
    elif (( ${_LOOP_BOUNCE_AMBIGUOUS:-0} )); then
      # DIVE-2572: ADVANCING, and the answer carries bounce vocabulary later in
      # its prose. Under the old bare-substring matcher this exact shape was
      # classified as a BOUNCE — five for five on the live board. Naming it is
      # the compatibility window: a reader who genuinely meant to bounce learns
      # the form in the one place they will read it, and nobody's careful prose
      # is silently reinterpreted in the meantime.
      warn "$ident: answered as ADVANCE. The decision is read from the first line up to its first dash/colon/comma/stop, and this answer carries bounce vocabulary only AFTER that — under the previous matcher its presence anywhere would have bounced this to the previous loop step (DIVE-2572). If you meant to BOUNCE, put the word in that opening segment: 'reject — <why>', or 'do better'."
    fi
  fi
  # DIVE-2261: cancellation is an abandonment record, not completed work ready
  # for another iteration.  Refuse conservatively instead of skipping farther
  # back (which silently changes which work the human rejected) or resurrecting
  # the cancelled row.  This is deliberately before every answer write, so both
  # rows and their dependency graph remain untouched and the same gate can be
  # answered after a human repairs the anomalous relay.
  if (( _loop_bounce )) && [[ "$_prev_status" == "cancelled" ]]; then
    policy_refuse "$E_CONFLICT" "task_loop_bounce_cancelled_previous" "DIVE-2261" "$ident" \
      "$ident cannot bounce to previous loop step ${_prev_ident:-$_prev}: it is cancelled, so reopening it would resurrect deliberately abandoned work. The gate is still open; resolve the cancelled step or choose an advancing answer."
  fi
  local _close_done=0
  if [[ "$nt" == "manual" && "$_lk" != gate:* ]]; then
    local _dv; _dv=$(printf '%s' "${value:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    [[ "$_dv" == "done" ]] && _close_done=1
  fi
  local _row_status; _row_status=$(db "SELECT status FROM tasks WHERE id=${id};")
  local _row_closed=0
  case "$_row_status" in done|cancelled) _row_closed=1 ;; esac
  if (( _row_closed )) && { (( _close_done )) || [[ "$_lk" == gate:* ]]; }; then
    policy_refuse "$E_CONFLICT" "task_answer_closed_row" "DIVE-2228" "$ident" \
      "$ident is already ${_row_status} — answering this gate would move a closed task's status, so it is refused. The close record (status, done_at, result) stands."
  fi

  # DIVE-1305: the paired-human channel proof is a valid human-evidence form, but
  # STRICTLY for tier<2 gates. tier 2 is the hard-human floor (money/destructive/
  # secret are floored there) and lodar's chosen scope keeps those a
  # deliberate per-gate button tap — a plain chat line must NOT clear them. So we
  # honor --channel-proof only when the gate is tier<2 AND the chat_id verifies
  # against the bot's own access.json allowFrom (the paired human's verified DM).
  # When valid it marks the answer human-sourced (human=1 -> need_answered_by
  # human:*), so provenance is honest. For a tier-2 gate _cp_ok stays 0, human is
  # untouched, and the tier-2 provenance floor below rejects it exactly as before.
  local _cp_ok=0
  if [[ -n "$channel_proof" && "$gtier" != "2" ]]; then
    _gate_channel_proof_ok "$channel_proof" && _cp_ok=1
  fi
  (( _cp_ok )) && human=1

  # DIVE-2406: the two PER-GATE human-evidence forms (valid nonce, non-agent
  # SUDO_UID) are computed inside the hard-gate block below, but the provenance
  # stamp near the end of this function needs them too — a `--human` claim with
  # no evidence behind it must not be labelled `human:*`. Declared at function
  # scope so that stamp reads an initialized 0 on the gate types that never enter
  # that block, rather than an unset variable. Values are still set there, once.
  local _hp=0 _su=0

  # DIVE-2412 (DIVE-2382 fix #4): the CITED-MESSAGE form, which a tier-2 gate DOES
  # accept. The chat-only proof above stays tier<2 for the reason lodar scoped it
  # that way — an agent's session already knows the chat id, so alone it proves
  # only that this bot has a paired human. A citation is different in kind: the
  # message_id is checked against TELEGRAM (_gate_channel_session_ok), which is the
  # one party in this system the caller cannot speak for. So the tier-2 floor below
  # is satisfied by CHANNEL PROOF of the answer, not only by a button tap.
  #
  # Order matters: this runs BEFORE the evidence block and the tier-2 floor, and it
  # is the only thing here that can raise `human` on a tier-2 gate.
  local _cs_ok=0
  if [[ -n "$channel_msg" ]]; then
    [[ -n "$channel_proof" ]] || fail "$E_USAGE" "--channel-msg=<message_id> also needs --channel-proof=<chat_id> — the verified DM the message was sent in"
    if _gate_channel_session_ok "$channel_proof" "$channel_msg" "${value:-}" "$ident"; then
      _cs_ok=1
    else
      # FAIL CLOSED, AND NAME THE CONDITION. A citation that does not attest must
      # never fall through to the weaker chat-only form, nor to the generic floor
      # message below: the caller asserted a human answer and the assertion did
      # not hold, which is the refusal this ticket is graded on. Nothing above
      # this point writes to the row, so the gate is still unanswered — that is
      # the property the refusal arm checks, not merely a non-zero rc.
      _task_store_audit_log "task answer gate" error 0 -- \
        "task=$ident" "type=$nt" "tier=$gtier" "reason=channel-session citation did not attest" \
        "channel_proof=${channel_proof}" "channel_msg=${channel_msg}" "origin=${TASK_CS_ORIGIN:-none}" \
        "age=${TASK_CS_AGE:-unknown}" "detail=${TASK_CS_REASON:-unknown}" 2>/dev/null || true
      fail "$E_AUTH_REQUIRED" "$ident: the cited channel message is not usable as the human's answer — ${TASK_CS_REASON:-unattested}"
    fi
  fi
  (( _cs_ok )) && human=1

  # DIVE-394: approval/secret are HUMAN-ONLY gates. Reject answers that come from
  # an agent acting as itself — that's the DIVE-391 incident, where an Olivia
  # endorsement (running as agent-<name>) silently cleared a human approval gate.
  # The boundary is the CALLER's unix identity, because the legitimate human
  # paths run as privileged, non-agent users while an agent runs as `agent-<name>`:
  #   - Telegram tap  -> plugin shells `sudo -n 5dive task answer` -> root
  #   - dashboard     -> API exec tunnel -> shelld runs as `claude` (non-root)
  #   - human on box  -> their own (non-agent) login
  #   - agent itself  -> `agent-<name>`  <- the only case we block
  # So: block when the caller is an `agent-*` user. This closes the reported
  # incident WITHOUT breaking either live path (root tap OR claude dashboard),
  # and needs no coordinated plugin/API deploy. decision/manual stay open: agents
  # legitimately resolve those. Residual: an agent that runs `sudo 5dive task
  # answer` becomes root and passes — closing that (require a --human secret the
  # trusted paths inject) is the documented fast-follow; the --human flag is
  # already parsed + recorded as provenance to stage it.
  # DIVE-916: `manual` joins approval/secret as a hard human gate here — it's a
  # step only a person can do, so an agent must not self-answer it either.
  # DIVE-1182: a builder ship-gate (approval/manual) that DIVE-1145 routing sent
  # to the org lead carries routed_reviewer. The designated lead — and ONLY that
  # agent, on ONLY this routed gate — may clear it, closing the gap where such a
  # gate was human-only and pinged lodar instead of Marcus. Resolve it up front so
  # both the uid block and the evidence block below honour the exception. `secret`
  # is never routed (routed_reviewer stays NULL), so it can never take this path.
  # DIVE-1243: `access` joins approval/manual as lead-clearable — the designated
  # routed_reviewer (and only that agent, on only this routed gate) may clear it.
  # DIVE-2004: the caller identity here must be the one the KERNEL enforced, not
  # the one the CLI was told. `need_answered_by` is provenance — `task_actor`
  # returns `--from=<anything>` verbatim — so authorizing on it would let any agent
  # mint `lead:<the reviewer>` for itself. `_gate_authenticated_actor` is the
  # unforgeable half, and it FAILS CLOSED (empty -> no lead-clear).
  # DIVE-2330: that claim was FALSE until this fix — the function read a bare
  # `id -un`, resolved through the caller's PATH, so any agent could mint the
  # routed reviewer's name (measured: a shim made it return `lodar`). It now
  # resolves $EUID in pure bash over /etc/passwd, so the claim is true as written.
  local _routed_rev; _routed_rev=$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE id=${id};")
  local _lead_clear=0 _rc_sealed=0 _rc_deny=""
  if [[ ( "$nt" == "approval" || "$nt" == "manual" || "$nt" == "access" ) && -n "$_routed_rev" ]]; then
    local _auth; _auth=$(_gate_authenticated_actor)
    if [[ -n "$_auth" && "$_auth" == "$_routed_rev" ]]; then
      # DIVE-2233 PHASE 1 — READER ONLY, DECIDES NOTHING. Routing still carries the
      # clearance exactly as it does today; `_lead_clear=1` is unconditional here and
      # this release changes no gate's outcome. What the seal WOULD have decided is
      # resolved and recorded on the audit row below (`sealed=`), and phase 3 flips
      # this one branch to make it binding.
      #
      # Reader-before-enforcer, and the ordering is forced rather than cautious: the
      # constitution normalizer REJECTS unknown top-level authority keys and
      # loadConstitution fails closed to shipped defaults, so a council motion sealing
      # `gate_clear_leads` BEFORE this release ships would not merely fail to help —
      # it would invalidate the whole document on every box still running the current
      # CLI and silently collapse it to defaults. The key has to be READABLE before it
      # can safely be SEALED, and sealed before it can be ENFORCED.
      #
      # Deliberately NOT a feature flag: a flag on an agent-writable surface reopens
      # the exact self-grant this ticket closes. The gate between phases is a release,
      # which agents cannot cut for themselves.
      #
      # Recording it now is not bookkeeping. `sealed=0` rows are the fleet-wide
      # measurement of which lead-clears phase 3 will start refusing — collected for a
      # whole release, from production traffic, before anything breaks. Running the
      # reader on every lead-clear also keeps it from rotting unexercised between the
      # two cuts.
      _lead_clear=1
      if _gate_clear_lead_allowed "$_routed_rev"; then
        _rc_sealed=1
      else
        _rc_deny="$(_gate_clear_lead_denied_reason)"
      fi
    fi
  fi
  # DIVE-2099: the org lead's STANDING authority over ENGINEERING approvals — the
  # same clearance as the routed lead-clear above, but WITHOUT requiring that this
  # gate was routed to them at filing time. Identity is the unforgeable half and
  # is checked FIRST: `_gate_authenticated_actor` reads the kernel-enforced unix
  # caller (never --from, which `task_actor` returns verbatim — DIVE-2004), and
  # `_gate_standing_lead` resolves the holder and itself fails closed to EMPTY.
  # Both empty-checks are load-bearing: without them "" == "" would hand the
  # authority to every caller on a box with no constitution.
  #
  # WHO the lead is comes from the agent NAMED in the SEALED constitution, never
  # from the org chart (iteration 2; lodar answered `anchor-to-named-agent`
  # 2026-07-27). See `_gate_standing_lead` for why the chart is a self-grant path
  # on a NOPASSWD:ALL host and why the seal is what makes the anchor hold.
  #
  # `_ls_filer` is read for the AUDIT ROW ONLY and grants nothing. It stays the
  # stored assignee (the agent that hit the gate — `task need` stamps it) falling
  # back to created_by, the same COALESCE `owner` uses below, so the log still
  # answers "whose gate was this" without the answer feeding the decision.
  # DIVE-3171 — THE ROUTED BRANCH MUST NOT SWALLOW THE STANDING PROVENANCE.
  #
  # This guard was `_lead_clear != 1`, i.e. "standing only gets a say when routing did
  # not already grant clearance". Correct until DIVE-3171, because a gate whose reviewer
  # came from the CHART is genuinely a routed clear. But DIVE-3171 routes the org root's
  # eligible approvals to the SEALED standing lead — so routing now grants clearance to
  # an agent whose authority came from the constitution, the routed branch fires first,
  # and the row stamps `lead:<n>` for a clear the seal is the entire reason for. The
  # authority chain stays intact and the RECORD stops carrying HOW, which is the exact
  # class that cost three incidents on 2026-08-10 (two unattributed human taps read as
  # agent self-clears; a census that reported "quinn cleared ZERO gates" and was wrong
  # by four). `lead:standing:` is the only thing on the row separating "a lead cleared a
  # gate routed to them" from "a lead cleared it under constitutional standing", and
  # those are different authorities even when the same name appears in both.
  #
  # THE COUNTING ARGUMENT IS WHY IT IS FIXED NOW AND NOT LATER: anyone tallying
  # `lead:standing:` for a root-filed gate would find it under `lead:` and conclude the
  # standing path went unused — a silent shift in a number nobody re-derives.
  #
  # IT GRANTS NOTHING. The added disjunct only lets the block RUN; every conjunct inside
  # is unchanged, so `_lead_standing=1` still requires the authenticated actor to BE the
  # sealed lead and the gate to pass `_gate_lead_standing_eligible`. `_lead_clear` is
  # already 1 on this path and cannot be raised by reaching here. The only reachable
  # effect is the label — and it is scoped by `route_provenance` to rows THIS build
  # wrote, so no historical stamp moves and the counts shift for exactly the population
  # that was mislabelled.
  local _lead_standing=0
  local _route_prov_row; _route_prov_row=$(db "SELECT COALESCE(route_provenance,'') FROM tasks WHERE id=${id};")
  if [[ ( "$_lead_clear" != "1" || "$_route_prov_row" == "seal:standing-lead" ) && "$nt" == "approval" ]]; then
    local _ls_auth _ls_lead _ls_filer
    _ls_auth=$(_gate_authenticated_actor)
    _ls_filer=$(db "SELECT COALESCE(NULLIF(assignee,''), NULLIF(created_by,''), '') FROM tasks WHERE id=${id};")
    _ls_lead=$(_gate_standing_lead 2>/dev/null || true)
    if [[ -n "$_ls_auth" && -n "$_ls_lead" && "$_ls_auth" == "$_ls_lead" ]]; then
      # DIVE-2224: read the two fields SEPARATELY rather than ||' '|| in SQL.
      local _ls_ask _ls_title
      _ls_ask=$(db "SELECT COALESCE(ask,'') FROM tasks WHERE id=${id};")
      _ls_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
      if _gate_lead_standing_eligible "$nt" "$gtier" "$_ls_ask" "$_ls_title"; then
        _lead_standing=1
        _lead_clear=1
      fi
    fi
  fi
  # DIVE-1243: `access` is NOT open-agent-clearable (unlike decision) — a random
  # agent must not self-grant. It is gated here like the human-only types, so only
  # the routed lead (_lead_clear above) OR a human may clear it. When access fell
  # through to a human (T2 floor / no distinct lead), routed_reviewer is NULL, so
  # _lead_clear=0 and a human is required — exactly the intended fall-through.
  if [[ "$nt" == "approval" || "$nt" == "secret" || "$nt" == "manual" || "$nt" == "access" ]]; then
    # DIVE-2330: was `id -un` (PATH-forgeable). This decides whether an agent is
    # REFUSED, so a caller faking a non-agent name would skip it.
    #
    # ITERATION 2 (dev's finding, and the comment above it used to justify the
    # bug): this read `$EUID` DIRECTLY, bypassing `_gate_caller_uid`. The
    # justification conflated two different things — routing through
    # `_gate_authenticated_actor` WOULD widen the refusal, because that function
    # adds the root+SUDO_UID branch; routing through `_gate_caller_uid` widens
    # NOTHING, because the seam's entire body is `printf '%s' "$EUID"`. The
    # EUID-only semantics live INSIDE the seam, which is the point of the seam.
    #
    # What the bypass cost: a harness could not model a non-agent caller here, so
    # on any `agent-*` runner this guard fired on the RUNNER'S OWN identity and
    # `fail` exited the sourced harness mid-suite (gate_nonce_unit T3's uncaptured
    # call, rc=6, 9/18 arms). The outcome of the test suite became a function of
    # whose uid ran it — the DIVE-2365 host-supplied-precondition shape, which
    # this branch named in its own body and then reintroduced one function over.
    local _caller; _caller=$(_gate_uid_to_agent "$(_gate_caller_uid)")
    if [[ -n "$_caller" && "$_lead_clear" != "1" ]]; then
      # No audit_log here: the blocked caller is an agent user that can't write
      # the root-owned audit log anyway (it would only leak a perms error to
      # stderr). The fail + non-zero exit is the record.
      # DIVE-2801: state the CALLER's standing, not a law about the gate type.
      # "an agent can't self-answer an approval gate" is false — the gate's
      # lead-clear seat reaches here with _lead_clear=1 and clears it with no
      # human at all (see the branch above; DIVE-2599/2665/2654 are live
      # instances). Human-only is the FALL-THROUGH for a caller without that
      # standing, not the rule for the type. The old wording was read as a
      # general rule by the agent it refused, who then rebuilt the gate around
      # it — a refusal that describes the wrong subject sends the reader to fix
      # the wrong thing, and unlike a wrong answer nobody audits a reason.
      # ...and the same discipline applies to the REMEDY, one clause later. An
      # unrouted gate has no lead-clear seat, so "its lead-clear seat can answer
      # this with no human involved" is, on that gate, the identical defect in
      # the opposite direction: a sentence true of the type and false of the row
      # in front of the reader. Only the routed branch may claim a seat exists.
      # ...and the same discipline again on TIER, which is the third way this
      # sentence can be true of the type and false of the row. The tier-2 floor
      # at `gtier == 2 && ! human` sits BELOW this refusal, so the routed
      # reviewer never reaches it from here — but they hit it on their own
      # answer, and it ESCALATES them to a human rather than letting them clear.
      # Telling a tier-2 caller "your routed reviewer can answer this with no
      # human involved" would therefore recommend a remedy this code refuses,
      # which is the very defect this row exists to fix, committed inside its
      # own fix. Only a sub-tier-2 routed gate may claim a seat that can finish.
      local _who_can="a human — this gate has no routed reviewer, so no seat holds lead-clear standing"
      if [[ -n "$_routed_rev" && "$gtier" == "2" ]]; then
        _who_can="a human — it is routed to '${_routed_rev}', but this gate is TIER 2 and the floor escalates even their answer to a human tap"
      elif [[ -n "$_routed_rev" ]]; then
        _who_can="'${_routed_rev}' (its routed reviewer), or a human"
      fi
      fail "$E_AUTH_REQUIRED" "$ident is a '$nt' gate and you ('${_caller}') do not hold lead-clear standing on it — it can be cleared by ${_who_can}. A human answers from Telegram (tap the button) or the dashboard."
    fi
    # DIVE-2054: routed_reviewer is task-store state for $ident — fenced.
    # DIVE-2099: `standing=` distinguishes the two clearances that reach here.
    # This row records the DECISION TO ALLOW, which is not the same event as the
    # answer landing in the DB — the authoritative post-write row is emitted
    # after the UPDATE below (DIVE-2090: a pre-check row is not an audit of the
    # write; the two diverge in both directions).
    # DIVE-2233 phase 1: `sealed=` records what the SEAL would have decided about this
    # clear, and `denied=` why not. Nothing here changes the outcome — the row is the
    # instrument. Counting `sealed=0` rows fleet-wide over this release is how we size
    # phase 3's blast radius from real traffic instead of predicting it.
    [[ "$_lead_clear" == "1" ]] && _task_store_audit_log "task answer lead-clear" "ok" 0 -- "task=$ident" "type=$nt" "reviewer=${_routed_rev:-<none>}" "standing=$_lead_standing" "sealed=$_rc_sealed" "would_deny=${_rc_deny:-<none>}" 2>/dev/null || true
  fi

  # DIVE-916/950: hard human gates (approval/secret/manual) need HUMAN evidence
  # beyond the agent-* uid block above — that block sees `sudo`->root as non-agent,
  # so it cannot catch the agent->sudo->root path. The trusted human paths supply
  # ONE of two evidence forms (see below): the per-gate --human-proof nonce (the
  # plugin tap, whose SUDO_UID is the spawning agent) or a non-agent SUDO_UID (the
  # dashboard exec as claude, the DIVE-931 drop write, a human-on-box login). We
  # ALWAYS audit the attempt; we only REJECT when NEITHER form is present, and only
  # once enforcement is flipped on (`gate-proof enforce on`). Ships DORMANT until
  # the nonce-carrying plugin is confirmed live FLEET-WIDE (else a live tap that
  # can't supply the nonce yet would fail closed). DIVE-950 dropped the old DIVE-519
  # --proof form: it was agent-forgeable via the require_root `gate-proof` mint.
  #
  # DIVE-525 (UX): a HUMAN's tap must NEVER be rejected — "you tapped but it's not
  # enough" is the exact confusion lodar hit dogfooding. Under enforcement we reject
  # ONLY when no evidence form is present (the forge: an agent's bare
  # `sudo task answer --human`, SUDO_UID=agent, no nonce). Every trusted path
  # supplies at least one form, so a real human is never blocked. The agent-* uid
  # block above + this rule stop the DIVE-515/516 incident (an agent silently
  # self-clearing). Bar-raise scope: closes the one-liner + the easy sudo-mint
  # forge, NOT a determined root-sudo agent (separate sudo-reduction track).
  if [[ "$nt" == "approval" || "$nt" == "secret" || "$nt" == "manual" || "$nt" == "access" ]]; then
    # DIVE-916/950: TWO EQUIVALENT human-evidence forms — accept EITHER one, never
    # require both (double-gating a real tap violates DIVE-525):
    #   (a) --human-proof=<nonce> matching this gate's stored hash — the plugin
    #       tap / dashboard payload, the one path whose SUDO_UID is the agent,
    #   (c) a non-agent SUDO_UID — a claude/root interactive login, the dashboard
    #       exec (shelld runs as SUDO_UID=claude), AND the DIVE-931 secret-drop
    #       write (SUDO_UID=claude survives the nested non-sudo task-answer exec;
    #       verified empirically).
    # DIVE-950 dropped the former form (b), a DIVE-519 --proof token: it was
    # agent-forgeable (`sudo 5dive gate-proof` mint is require_root only), so it
    # raised the bar no higher than the sudo it already required. This still
    # supersedes the DIVE-519 "proof OR bare --human" rule: a bare --human is NOT
    # sufficient — that was the sudo→--human forge (DIVE-916 threat).
    # (_hp/_su declared at function scope above — DIVE-2406 reads them at the stamp.)
    [[ -n "$human_proof" ]] && _human_nonce_verify "$id" "$human_proof" && _hp=1
    # DIVE-2371: AUTHORIZATION site — structural principal test, fails closed.
    _gate_human_principal && _su=1
    # DIVE-1305: a verified paired-human channel proof is the fourth evidence
    # form — but _cp_ok is already gated to tier<2 above, so it can satisfy the
    # evidence rule only for a tier-1 approval/access gate (never a tier-2 hard
    # gate, whose _cp_ok is 0). A tier-2 approval still requires the nonce/SUDO_UID
    # forms + is caught by the tier-2 floor below.
    # DIVE-1182: a routed builder gate cleared by its designated lead reviewer is a
    # sanctioned agent path — count the lead-clear as evidence so enforcement (the
    # "no human evidence ⇒ reject" rule) does not block the very exception granted
    # by the uid block above. Scoped to approval/manual with a matching
    # routed_reviewer (never secret), so no un-routed human gate is affected.
    # DIVE-2412: _cs_ok is the attested cited-message form. Unlike _cp_ok it is
    # NOT tier-fenced, so it satisfies the evidence rule on a tier-2 approval too.
    local _evid=$(( _hp || _su || _lead_clear || _cp_ok || _cs_ok ))
    local _caller2; _caller2=$(_gate_caller_user)
    # DIVE-2054: the human-proof/nonce evidence being scored here is stored
    # against $ident in TASKS_DB (not an independent channel/delivery fact like
    # the 3 named exemptions) — fenced.
    # DIVE-2799: `evidence=` names the form(s) that satisfied the rule; the
    # per-form booleans stay for continuity of the historical sweeps that
    # already key on them.
    _task_store_audit_log "task answer gate" "$([[ $_evid -eq 1 ]] && echo ok || echo error)" 0 -- \
      "task=$ident" "type=$nt" "channel_proof=$([[ -n "$channel_proof" ]] && echo present || echo absent)" "cp_ok=$_cp_ok" \
      "channel_msg=${channel_msg:-none}" "cs_ok=$_cs_ok" "cs_origin=${TASK_CS_ORIGIN:-none}" "cs_age=${TASK_CS_AGE:-none}" \
      "human_proof=$([[ -n "$human_proof" ]] && echo present || echo absent)" "nonce_valid=$_hp" \
      "sudo_nonagent=$_su" "human=$human" \
      "evidence=$(_gate_evidence_form "$_hp" "$_su" "$_cs_ok" "$_cp_ok" "$_lead_clear")" \
      "filer_answered=$(_gate_filer_answered "$id" "$_caller2")" \
      "caller=$_caller2" "sudo_uid=${SUDO_UID:-}" \
      "enforce=$(_gate_proof_enforced && echo on || echo off)"
    # DIVE-525: a real human tap is NEVER rejected — every trusted path supplies
    # at least one evidence form (plugin→nonce, dashboard→proof/SUDO_UID=claude,
    # human-on-box→non-agent SUDO_UID, drop→SUDO_UID=claude). Under enforcement,
    # reject only when NONE is present (the forge: an agent's bare
    # `sudo task answer --human`). Ships DORMANT (audit-only) until the plugin
    # --human-proof injection is confirmed live fleet-wide; root then flips
    # `gate-proof enforce on` (Marcus ship-gates the flip).
    if _gate_proof_enforced && (( ! _evid )); then
      fail "$E_AUTH_REQUIRED" "$ident ($nt) needs a human to clear it — tap the button in Telegram or use the dashboard"
    fi
  fi

  # DIVE-1117 (companion to DIVE-1115, CLI side / defense in depth): tier 2 is the
  # HARD human floor and NEVER auto-applies, so `task answer` must refuse a
  # NON-HUMAN answer on a tier-2 gate regardless of need_type. The blocks above
  # only fire for the approval/secret/manual types; a `decision` gate floored to
  # tier 2 by the T2 category heuristic (OSS-16, keyword-floored by "secrets")
  # slipped past and accepted a bare-agent answer (need_answered_by=main) with
  # `gate-proof enforce` ON. The floor is provenance: an answer is human-sourced
  # only when a trusted path passed --human (recorded human:* below). Every real
  # human path — the Telegram tap, the dashboard/API exec — passes --human, so a
  # genuine human answer is NEVER rejected here (DIVE-525). We gate this on
  # `gate-proof enforce` for the SAME rollout envelope as the evidence block
  # above; enforce is ON fleet-wide (DIVE-950). We deliberately do NOT require the
  # evidence forms here: a tier-2 `decision` gate's tap runs as SUDO_UID=agent and
  # its option buttons carry NO nonce in their callback_data, so demanding evidence
  # would reject a real human decision tap — provenance is the correct, tap-safe
  # floor. Residual (an agent sudo->--human-forging human:* on a tier-2 *decision*)
  # is the forged-human threat DIVE-916/DIVE-1115 own; tracked as follow-up.
  #
  # DIVE-2356 UPDATED THE FIRST HALF OF THAT REASONING, AND READ THIS BEFORE
  # TIGHTENING THIS BLOCK. A tier-2 decision now DOES mint a per-gate nonce at
  # filing — so "it has no nonce" is no longer why evidence is not required here.
  # The reason was then narrowed to the TAP — the decision option buttons carried
  # no nonce, because telegram-pi's TNA_RE was greedy and would swallow it — so a
  # real human tap arrived with no proof to offer and an evidence requirement would
  # have rejected it, the DIVE-525 trap.
  #
  # DIVE-2269: THAT TAP-SIDE REASON IS SPENT, ON BOTH CLAUSES. DIVE-2233 put the
  # nonce suffix on decision buttons exactly like approval/secret/manual, and
  # DIVE-2374 brought telegram-pi and telegram-opencode to the tolerant regex, so
  # no shipped fork swallows it any more (pinned empty by S12e in
  # tests/gate_t2_nonce_proof_unit.sh, and by test/tna-harness.test.ts in
  # 5dive-plugins). A real human decision tap now DOES arrive with proof.
  # This is a comment correction only — the block below is unchanged, because what
  # still blocks tightening is the BACKLOG, not the tap: see the next paragraph.
  #
  # The sanctioned next step is NOT an evidence requirement. It is the far weaker
  # "refuse a tier>=2 answer whose human_nonce_hash IS NULL", and it must not land
  # until tier-2 decision gates filed BEFORE DIVE-2356 have aged out or been
  # rescued by the digest/re-nag mints: at the time of writing that rule would
  # refuse 43 of the last 47 tier-2 decision answers. Check the live NULL count
  # first; do not infer that it has drained. NO downgrade path from the answer side by design: an over-fired T2
  # (the heuristic can over-match) waits for a human — the conservative correct
  # default for a hard floor; re-file at a lower --tier if the floor misfired.
  # DIVE-2588: NO LONGER CONTINGENT ON THE ROLLOUT FLAG. The `_gate_proof_enforced`
  # conjunct was a staging envelope for a rollout that completed on 2026-07-30, and
  # while it stood it made a hard human floor switchable — the same variable that
  # armed it could disarm it, and until DIVE-2588 the party it constrains could set
  # that variable. A control whose OFF position is reachable by its subject is not a
  # control. The flag can now only make the floor STRICTER (see _gate_proof_enforced),
  # and this branch does not consult it at all. Safe to make unconditional: it refuses
  # only a NON-human answer on a tier-2 gate, which is precisely what a hard human
  # floor means on every box, armed or not — every real human path passes --human, so
  # DIVE-525 ("a real tap is never rejected") still holds by construction.
  # DIVE-3228: the `access` exemption, re-derived from the row (see
  # _gate_access_lead_clearable for why it is re-derived and not taken from
  # `_lead_clear` alone). `_lead_clear` is still REQUIRED — it carries the
  # unforgeable half (`_gate_authenticated_actor` == routed_reviewer, DIVE-2004/2330),
  # and this predicate only decides whether THAT seat's answer survives the floor.
  # An access gate that was never routed has _lead_clear=0 and is untouched here,
  # which is the DIVE-1243 fall-through the block below already describes.
  local _access_lead_ok=0
  if [[ "$_lead_clear" == "1" && "$nt" == "access" && "$gtier" == "2" ]]; then
    local _al_floor _al_needs
    _al_floor=$(db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE id=${id};")
    _al_needs=$(db "SELECT COALESCE(needs_capability,'') FROM tasks WHERE id=${id};")
    if _gate_access_lead_clearable "$nt" "$gtier" "$_al_floor" "$_al_needs"; then
      _access_lead_ok=1
    fi
    # Record BOTH directions. A fix that logs only its successes leaves the next
    # regression with nothing to count — this row's own DIVE-3117 lesson, and the
    # denying branch is the one that will be argued about (it is where a filer whose
    # access gate still reaches lodar has to be told WHY).
    # DIVE-2054: task-store state for $ident, no channel proof — fenced.
    _task_store_audit_log "task answer access-lead-clear" \
      "$( ((_access_lead_ok)) && echo allowed || echo denied )" 0 -- \
      "task=$ident" "type=$nt" "tier=$gtier" "routed_to=$_routed_rev" \
      "floor_provenance=${_al_floor:-<null>}" "needs=${_al_needs:-<none>}" || true
  fi
  if [[ "$gtier" == "2" ]] && (( ! human )) && (( ! _access_lead_ok )); then
    local _caller3; _caller3=$(_gate_caller_user)
    # DIVE-1437: a tier-2 gate that was LEAD-ROUTED (routed_reviewer set) but is an
    # approval/manual builder gate is the DIVE-1429 stall — the DIVE-1145/1182
    # routing sent it to the org lead, but the T2 hard-human floor here refuses the
    # lead's non-human answer, AND cmd_task_need RETURNED before task_need_notify
    # so the human never got a tap button. The lead then hand-asks the human in
    # plain chat with no button to tap. Instead of dead-ending here, ESCALATE to
    # the human via the normal ping path so task_need_notify fires WITH the tap
    # keyboard, and take the lead out of the loop (clear routed_reviewer). We mint
    # a FRESH per-gate human nonce (approval/manual are hard human gates), so
    # anti-forge is preserved: only a real human tap/nonce or non-agent SUDO_UID
    # can clear the escalated gate — the escalation itself grants no clearance.
    # Scoped to approval/manual routed gates (the DIVE-1429 case): `access` is
    # DELIBERATELY lead-clearable by DIVE-1243, `secret` is never routed, and a
    # non-routed tier-2 gate already got its human button at filing — those keep
    # the original refuse. eng_ship/curation are forced tier-1 at filing, so they
    # never reach this block. Ties to DIVE-1330/1243 handoff patterns.
    if [[ -n "$_routed_rev" ]] && [[ "$nt" == "approval" || "$nt" == "manual" ]]; then
      local _esc_ask _esc_opts _esc_rec _esc_sk _esc_conn
      _esc_ask=$(db "SELECT COALESCE(ask,'') FROM tasks WHERE id=${id};")
      _esc_opts=$(db "SELECT COALESCE(need_options,'') FROM tasks WHERE id=${id};")
      _esc_rec=$(db "SELECT COALESCE(recommend,'') FROM tasks WHERE id=${id};")
      _esc_sk=$(db "SELECT COALESCE(secret_key,'') FROM tasks WHERE id=${id};")
      _esc_conn=$(db "SELECT COALESCE(connector,'') FROM tasks WHERE id=${id};")
      # Mint a fresh human nonce so the escalated tap can clear it (mirrors the
      # cmd_task_need mint for approval/manual). Take the lead out (routed_reviewer
      # NULL) and re-arm the ping (gate_pinged_at NULL) so task_need_notify fires
      # fresh with the tap keyboard.
      local _esc_nonce=""; _esc_nonce=$(_human_nonce_mint)
      db "UPDATE tasks SET routed_reviewer=NULL, gate_pinged_at=NULL$([[ -n "$_esc_nonce" ]] && echo ", human_nonce_hash=$(sqlq "$(_human_nonce_sha "$_esc_nonce")")") WHERE id=${id};"
      # DIVE-2054: DELIBERATELY UNFENCED (ticket-named exemption) — records an
      # escalation actually leaving the fleet.
      audit_log "task answer escalate-to-human" ok 0 -- \
        "task=$ident" "type=$nt" "tier=$gtier" "reason=T2-floor refused routed gate — escalated to human with buttons" \
        "was_routed_to=$_routed_rev" "caller=$_caller3" "sudo_uid=${SUDO_UID:-}" 2>/dev/null || true
      task_need_notify "$ident" "$nt" "$_esc_ask" "$_esc_opts" "$_esc_rec" "$_esc_sk" "$_esc_conn" "$_esc_nonce" "" || true
      ok "$ident is a tier-2 human gate ($nt) — the org lead can't clear it, so it was ESCALATED to the human with a tap button. Awaiting their answer." \
         '{id:($i|tonumber), ident:$id, status:"blocked", need_type:$ty, tier:2, escalated_to_human:true, was_routed_to:$rv, ask:$ak}' \
         --arg i "$id" --arg id "$ident" --arg ty "$nt" --arg rv "$_routed_rev" --arg ak "$_esc_ask"
      return 0
    fi
    # DIVE-2054: same reasoning as the "task answer gate" site above — fenced.
    _task_store_audit_log "task answer gate" error 0 -- \
      "task=$ident" "type=$nt" "tier=$gtier" "reason=non-human answer on tier-2 floor" \
      "human=$human" "caller=$_caller3" "sudo_uid=${SUDO_UID:-}"
    fail "$E_AUTH_REQUIRED" "$ident is a tier-2 human gate ($nt) — only a human can clear it; tap the button in Telegram"
  fi

  # DIVE-2233 (second item) — THE TIER-2 HUMAN CLAIM MUST BE PROVED, NOT ASSERTED.
  #
  # The floor above only fires when `--human` was NOT passed. That is the entire hole:
  # every guard on a tier-2 gate is downstream of a flag, and `--human` is a plain CLI
  # flag any agent that can `sudo` can pass. The gate that closed DIVE-2131 is the
  # worked example — a tier-2 hard gate whose row recorded need_answered_uid=1004
  # (agent-main, the plugin's own uid) and human_nonce_hash NULL. Nothing in that row is
  # non-forgeable. "Hard human floor" was a label on it, not a property of it.
  #
  # So when a tier-2 gate HAS a minted nonce, a `--human` answer must carry one of the
  # two DIVE-916 evidence forms — the per-gate nonce (the tap; its SUDO_UID is the
  # spawning agent, which is why the nonce exists) or a non-agent SUDO_UID (dashboard
  # exec, human-on-box login). Both are things an agent cannot produce for itself.
  #
  # SCOPED TO "HAS A NONCE" ON PURPOSE, and this is the compatibility hinge rather than
  # timidity: before this change, tier-2 decision/access gates minted nothing, so a gate
  # filed by the old code and answered by the new code has no hash to check. Demanding
  # evidence there would reject real human taps on every gate already in flight — and
  # those taps genuinely cannot comply, because the button they are attached to was
  # rendered without a nonce in its callback_data. `human_nonce_hash` non-empty is the
  # exact, per-row witness that this gate's buttons CAN carry proof.
  #
  # DIVE-2588: the `_gate_proof_enforced` conjunct is GONE here too, and this is the
  # branch the bypass actually rode. A forged `--human` was already refused by this
  # block on any gate carrying a minted nonce — main measured that on v0.18.2 AND
  # v0.17.11 — so the exploit was not the flag; it was that ONE env var switched this
  # block off and the floor above at the same time. Making it unconditional costs
  # nothing on a box where the rollout never happened: the block is already scoped to
  # gates whose `human_nonce_hash` is non-empty, i.e. the per-row witness that this
  # gate's buttons CAN carry proof, so a box that mints nothing reaches no assertion
  # here. That scoping, not the flag, was always what kept real taps safe.
  if [[ "$gtier" == "2" ]] && (( human )); then
    local _t2_hash; _t2_hash=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_t2_hash" ]]; then
      local _t2_hp=0 _t2_su=0
      [[ -n "$human_proof" ]] && _human_nonce_verify "$id" "$human_proof" && _t2_hp=1
      # DIVE-2371: AUTHORIZATION site (tier-2 floor) — same structural test.
      _gate_human_principal && _t2_su=1
      # DIVE-2412: THE CITATION IS THE THIRD EVIDENCE FORM, and it has to be named
      # HERE rather than only in the `human` flag it also raises. This site is what
      # decides whether a tier-2 `--human` claim was PROVED, and it is scoped to
      # gates that HAVE a minted nonce — which is every approval and manual gate,
      # i.e. exactly the ones this feature exists for. Omitted from this list, the
      # citation would raise `human`, clear the floor above, and then be refused
      # here as an unproven claim: the feature would be dead on its main case.
      # It is admitted on the same footing as the other two because it is not
      # weaker in kind — the nonce and the non-agent SUDO_UID are both local to
      # this box, while the citation is attested by Telegram, the one party the
      # caller cannot speak for (_gate_channel_session_ok).
      local _t2_cs="${_cs_ok:-0}"
      local _t2_caller; _t2_caller=$(_gate_caller_user)
      # DIVE-2054: the nonce being scored is task-store state for $ident — fenced.
      # DIVE-2799: same canonical `evidence=` field as the site below, so ONE
      # grep spans both audit sites and the `tasks.human_evidence` column.
      # `channel-chat` and `lead` are 0 here BY CONSTRUCTION — neither is admitted
      # at the tier-2 floor (`_cp_ok` is tier-fenced to <2, and a lead-clear is not
      # human evidence) — and they are passed explicitly rather than omitted so the
      # arity and token order are identical at both sites.
      _task_store_audit_log "task answer t2-human-evidence" \
        "$([[ $(( _t2_hp || _t2_su || _t2_cs )) -eq 1 ]] && echo ok || echo error)" 0 -- \
        "task=$ident" "type=$nt" "tier=$gtier" "nonce_valid=$_t2_hp" "sudo_nonagent=$_t2_su" \
        "channel_session=$_t2_cs" \
        "human_proof=$([[ -n "$human_proof" ]] && echo present || echo absent)" \
        "evidence=$(_gate_evidence_form "$_t2_hp" "$_t2_su" "$_t2_cs" 0 0)" \
        "filer_answered=$(_gate_filer_answered "$id" "$_t2_caller")" \
        "caller=$_t2_caller" "sudo_uid=${SUDO_UID:-}" 2>/dev/null || true
      if (( ! _t2_hp && ! _t2_su && ! _t2_cs )); then
        fail "$E_AUTH_REQUIRED" "$ident is a tier-2 human gate ($nt) and the --human claim is unproven — tap the button in Telegram"
      fi
    fi
  fi

  # Who resumes: the agent that FILED the gate, else the assignee, else the creator.
  # DIVE-2624: this used to read `assignee` first, and that reading is what forced
  # `task need` to overwrite the assignee at file time ("the agent hitting the gate
  # becomes the owner-of-record so task answer knows who to ping"). On a row already
  # delivered to a verifier that overwrite destroyed the derived handoff. gate_filed_by
  # is the column that records the filer — it is written in the same transaction as
  # the gate and reset by _gate_archive_and_clear_sql — so reading it here lets the
  # assignee go back to meaning only "who holds this row". The COALESCE tail keeps
  # pre-DIVE-1958 rows (gate_filed_by NULL) resolving exactly as before; the identical
  # COALESCE is already used by the DIVE-2011 delivery frame a few hundred lines down.
  local owner; owner=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''), NULLIF(assignee,''), NULLIF(created_by,''), '') FROM tasks WHERE id=${id};")
  # DIVE-394 provenance: record WHO answered. `human:` prefix when a trusted path
  # passed --human; otherwise the resolved actor label.
  local answered_by; answered_by=$(task_actor "$from")
  # DIVE-2406: `--human` is a SELF-ASSERTED flag — it is argv and nothing more. On
  # a lead-clearable gate it is the label, never the authority: the DIVE-1182/1243
  # routed lead-clear (or the DIVE-2099 standing clear) is what authorized the
  # answer, and that is an AGENT clear by construction. Before this, a lead who
  # also passed --human was stamped `human:<lead>` — and the `(( ! human ))`
  # guards just below, written on the assumption that human=1 meant a real human,
  # suppressed the honest `lead:` label that was already sitting right there.
  #
  # DIVE-2400 is the live case, and the cost was not cosmetic: the row read
  # `answered_by=human:marketing` with channel_proof absent, nonce_valid=0 and
  # sudo_nonagent=0 — every evidence form of a human absent — and the task's
  # result text then asserted "lodar approved all 7" when he had never answered.
  # The AUTHORITY was correct by design (the DIVE-1381 curation carve-out routes
  # a persona batch to the lead on purpose); it is the stamp that lied about who
  # exercised it, to `human:%` consumers that count human touches (cmd_trace,
  # cmd_digest, cmd_proof) and to the precedent engine, which auto-applies a
  # PRIOR HUMAN ANSWER to later gates and had a lead-clear to hand it.
  #
  # So an UNCORROBORATED --human on a lead-cleared gate is demoted here. Note
  # what is deliberately NOT in _human_evid: `_lead_clear`. It is a legitimate
  # AUTHORIZATION form for the block above (a lead-clear must not be refused for
  # lacking human evidence) and is precisely NOT evidence of a human here — that
  # conflation is the whole bug. A corroborated --human (valid per-gate nonce,
  # non-agent SUDO_UID, or verified channel proof) is untouched, so no genuine
  # Telegram tap, dashboard answer or human-on-box login is ever relabelled.
  # Conditioned on `_lead_clear` ALONE, and that is not an oversight about the
  # DIVE-2099 standing path: an eligible standing clear sets `_lead_clear=1` too
  # (see that block above), so one condition covers both and a second `||
  # _lead_standing` clause would be dead — untestable by mutation and green
  # forever. `_lead_clear=1` also implies nt is approval|manual|access, the types
  # that always enter the evidence block, so _hp/_su are measured values here and
  # never their declaration defaults.
  # DIVE-3160 (main's condition 2): the delegated executor must be STRUCTURALLY
  # incapable of writing a `human:*` label, not merely conventionally unlikely to.
  # `_task_answer` already refuses the human-evidence flags by name; this is the
  # backstop, placed at the one point every raise-site (--human, _cp_ok, _cs_ok,
  # and whatever the next one turns out to be) has already run and nothing has yet
  # read `human` to decide provenance. An agent-invoked clear is `lead:*`, full
  # stop — a new root path must not widen the DIVE-916/1115/2224 forged-human
  # residual, which is open.
  [[ -z "${TASK_ANSWER_DELEGATED:-}" ]] || human=0
  local _human_evid=$(( _hp || _su || _cp_ok ))
  local _human_claim="$human"
  if (( human && ! _human_evid )) && [[ "$_lead_clear" == "1" ]]; then
    human=0
  fi
  # ── DIVE-3128: NAME THE PERSON, NOT THE PIPE ──────────────────────────────
  #
  # `$answered_by` at this point is the ACTOR — the identity of the process that
  # ran `task answer`. On the tap path that process is a BOT, so prefixing it with
  # `human:` produced `human:olivia`: an assertion about a person, built out of a
  # measurement of a relay. That is DIVE-3045, and it is not a forgery — it is the
  # honest output of asking the wrong question.
  #
  # So when the caller carried a tap, the person who pressed the button is what
  # gets stamped, and the relay is recorded in its OWN column further down. When
  # no tap was carried, nothing here changes: `$answered_by` stays the actor and
  # every existing path keeps its current stamp.
  #
  # `(( human ))` fences the whole thing. --tap-uid is provenance, never
  # authority: an answer that did not already qualify as human-sourced does not
  # become one by naming a Telegram id, so a tap presented without the DIVE-916
  # nonce or a non-agent SUDO_UID is still refused upstream and never reaches here.
  local _tap_name="" _tap_src="none"
  if (( human )) && [[ -n "$tap_uid" ]]; then
    _tap_name=$(_gate_tap_human_name "$tap_uid" "$tap_username") || _tap_name=""
    if [[ -n "$_tap_name" ]]; then
      case "$_tap_name" in tg:*) _tap_src="unnamed-uid" ;; *) _tap_src="resolved" ;; esac
      answered_by="$_tap_name"
    else
      # A tap_uid that is not a Telegram id at all. Do NOT fall through to the
      # actor — that silently restores the exact substitution this block removes.
      _tap_src="bad-uid"
      answered_by="tg:invalid"
    fi
  fi

  # ── DIVE-3128: A `human:` STAMP MAY NOT NAME AN AGENT ─────────────────────
  #
  # The cheap invariant, and it is checked on EVERY human stamp rather than only
  # on the tap path — because the tap path is where this was DISCOVERED, not the
  # only place it can happen. Any relay that clears a gate while running as an
  # agent reaches this line with an agent name in `$answered_by`, and the fix
  # above only covers the callers that were taught to send `--tap-uid`.
  #
  # REFUSED, NOT REPAIRED. There is no honest repair available here: the code knows
  # the name is wrong and has nothing better to put in its place, so it declines to
  # make the claim. `unattributed:<name>` keeps every fact that WAS measured (a
  # --human answer arrived, this process ran it) while withholding the one that was
  # not, and it does not start with `human:` — so cmd_trace, cmd_digest, cmd_proof
  # and the precedent engine, all of which key on `need_answered_by LIKE 'human:%'`,
  # stop counting it as a human touch with no change on their side. That is the
  # DIVE-2406 demotion pattern one screen up, applied to a different lie.
  #
  # It is a DEMOTION rather than a `fail`, deliberately. The answer itself is
  # already authorized by evidence this block does not re-litigate, and refusing
  # the WRITE would discard a decision a person may really have made and leave a
  # tier-2 gate open with no way to close it. What is refused is the CLAIM.
  #
  # `human` is deliberately NOT cleared: the two `(( ! human ))` guards below add
  # `lead:` / `lead:standing:` prefixes, and firing them here would relabel a
  # refused human claim as an authorized lead clear — a second wrong answer.
  local _attr_why="" _attr_unverified=0
  if (( human )); then
    if actor_human_name_ok "$answered_by"; then
      [[ "${ACTOR_HUMAN_NAME_WHY:-}" == "roster-unmeasured" ]] && _attr_unverified=1
      answered_by="human:${answered_by}"
    else
      local _attr_name="$answered_by"
      _attr_why="${ACTOR_HUMAN_NAME_WHY:-refused}"
      answered_by="unattributed:${_attr_name}"
      warn "$ident: refusing to record this answer as human:${_attr_name} — '${_attr_name}' is a name on the AGENT roster, so the stamp would assert a human where the record can only show a relay (DIVE-3128). Stored as '${answered_by}'. A button tap should carry --tap-uid=<telegram user id> so the person who pressed it is named."
      # STDERR IS NOT REDIRECTED HERE, and that is a correction rather than a
      # style choice. `_task_store_audit_log`'s off-prod-store withholding is
      # announced ONCE per invocation (DIVE-2010, `_TASK_STORE_AUDIT_FENCED`), so
      # a `2>/dev/null` on the FIRST call through it eats the announcement for
      # every later one — measured against tests/gate_answer_audit_unit.sh, whose
      # "a silent fence is the same fail-open shape as no fence" arm went red the
      # moment this row was added ahead of the write-site row with its stderr
      # discarded. The sibling refusal sites can redirect because each of them
      # `fail`s immediately after; this one returns and the write-site row still
      # has to be able to speak.
      _task_store_audit_log "task answer human-attribution" error 0 -- \
        "task=$ident" "type=$nt" "tier=$gtier" "reason=$_attr_why" \
        "refused_stamp=human:${_attr_name}" "stored=${answered_by}" \
        "tap_uid=${tap_uid:-none}" "relay_agent=${relay_agent:-none}" || true
    fi
  fi
  # DIVE-1182: a routed builder gate cleared by its designated lead is recorded as
  # lead-sourced provenance (NOT human:*) — honest that an agent lead, not a human,
  # cleared it. Never overrides a genuine human:* answer.
  [[ "$_lead_clear" == "1" ]] && (( ! human )) && answered_by="lead:${answered_by}"
  # DIVE-2099 (design note 3): a STANDING-authority clear must stay distinguishable
  # from a human tap AND from a routed lead-clear, forever — not merely in a log
  # line that can rotate or diverge from the row (DIVE-2090). So the distinction
  # is carried by the persisted provenance itself: `lead:standing:<actor>`. The
  # `lead:` prefix is preserved deliberately, so every existing `lead:*` consumer
  # (cmd_push's delegated-push predicate, the digest's human-touch count, the
  # proof ledger) keeps treating it as agent-sourced-not-human with no change;
  # the `standing:` infix is the new, additive fact. `need_answered_by` is inside
  # the DIVE-756 signed closure, so this marker is tamper-evident: a raw DB edit
  # that downgrades `lead:standing:main` to `lead:main` fails `gate-proof verify`.
  # DIVE-2518: name the actor the standing check AUTHENTICATED, not the one the
  # caller claimed. `_lead_standing` is decided above by `_gate_authenticated_actor`
  # == `_gate_standing_lead` — the sealed uid-first derivation — while this label
  # was built from `task_actor "$from"`, which took `--from` verbatim. The two can
  # name DIFFERENT agents, and the row would then read `lead:standing:<claimed>`
  # for a standing that was granted to <derived>: a proof string asserting exactly
  # what the check did not verify. The label now comes from the same resolver as
  # the decision, which is the property `gate-proof verify` is reading it for.
  # `_gate_authenticated_actor` returns EMPTY for a caller it cannot resolve to an
  # agent, and an empty name here would stamp the bare string `lead:standing:` —
  # a proof label naming nobody, which `gate-proof verify` and the human:* demotion
  # both then read as a malformed grant. Fall back to the uid-derived board actor,
  # which is the same derivation and never empty.
  if [[ "$_lead_standing" == "1" ]] && (( ! human )); then
    local _ls_who; _ls_who=$(_gate_authenticated_actor)
    [[ -n "$_ls_who" ]] || _ls_who=$(task_actor "")
    answered_by="lead:standing:${_ls_who}"
  fi

  # DIVE-756: stamp the REAL invoker uid ($SUDO_UID survives `sudo -u agent-X`,
  # unlike need_answered_by) and a tamper-evidence signature over the closure
  # facts. We compute the timestamp in shell (not datetime('now')) so the exact
  # same string is signed AND stored, letting `gate-proof verify` recompute it.
  # Signing needs the root-only key: in a root context we sign in-process; from
  # the non-root trusted path (dashboard exec as claude) we re-exec the root-only
  # `gate-proof sign` over sudo. Best-effort — a box that can't sign just stores
  # an empty sig (verify reports "unsigned"); the answer NEVER fails on this.
  #
  # DIVE-2760: best-effort is still the right posture for the WRITE — losing a
  # human's answer because a box cannot sign would be worse than storing it
  # unsigned — but "never fails" was implemented as "never says anything", and
  # those are different. Record WHY the mint came back empty so the notice below
  # can name it. The three causes have three different remedies and are otherwise
  # indistinguishable from an empty column.
  local _uid; _uid=$(_gate_closure_subject_uid)
  local _ts; _ts=$(date -u '+%Y-%m-%d %H:%M:%S')
  local _vfs=""; [[ "$nt" != "secret" ]] && _vfs="$value"
  local _sig="" _sig_why=""
  if [[ -n "$_uid" ]]; then
    if [[ $EUID -eq 0 ]]; then
      _gate_proof_ensure_key 2>/dev/null || true
      _sig=$(_gate_closure_sign "$id" "$nt" "$_vfs" "$answered_by" "$_ts" "$_uid" 2>/dev/null || echo "")
      [[ -n "$_sig" ]] || _sig_why="running as root, but the gate-proof key could not be created or read on this box"
    else
      _sig=$(_gate_closure_payload "$id" "$nt" "$_vfs" "$answered_by" "$_ts" "$_uid" \
               | sudo -n 5dive gate-proof sign 2>/dev/null || echo "")
      [[ -n "$_sig" ]] || _sig_why="this seat has no passwordless sudo for \`5dive gate-proof sign\` (cli-scoped agents do not; root-all and cli-root seats do)"
    fi
  else
    _sig_why="no invoker uid could be derived, so the closure has no subject to sign for"
  fi
  local _uidsql="NULL"; [[ -n "$_uid" ]] && _uidsql="$_uid"

  # Record the answer. A `secret` gate NEVER stores its value — writing a raw
  # key into this group-claude-readable db is a plaintext-secret-at-rest leak.
  # We only stamp need_answered_at (the "provided" signal); the agent loads the
  # key out-of-band. decision/approval/manual store the value in need_answer.
  if [[ "$nt" == "secret" ]]; then
    (( value_set )) && fail "$E_USAGE" "$ident is a secret gate — do not pass --value; run: 5dive task answer $ident"
    db "UPDATE tasks SET need_answered_at=$(sqlq "$_ts"), need_answered_by=$(sqlq "$answered_by"), need_answered_uid=${_uidsql}, need_answer_sig=$(sqlq "$_sig") WHERE id=${id};"
  else
    (( value_set )) || fail "$E_USAGE" "--value is required (the human's answer)"
    db "UPDATE tasks SET need_answer=$(sqlq "$value"), need_answered_at=$(sqlq "$_ts"), need_answered_by=$(sqlq "$answered_by"), need_answered_uid=${_uidsql}, need_answer_sig=$(sqlq "$_sig") WHERE id=${id};"
  fi

  # DIVE-2760: an unsigned closure is stored, reported OK, and then refused by a
  # broker somewhere else, later, in a different command, to a DIFFERENT agent —
  # with a message about tampering. Say it HERE, at the moment the row is written,
  # because this is the only point where the cause and the remedy are both in view.
  #
  # Three facts the reader cannot derive from an empty column, so all three are
  # stated: (1) the answer LANDED — this is not a failed answer and re-answering
  # is not a retry of a lost write; (2) WHO gets refused is not who is being
  # warned — the signature is minted here by the ANSWERER and nothing re-signs at
  # act time (broker.sh:103 reads the stored `need_answer_sig`, and the acting
  # agent's tier never enters the check), so the refusal surfaces on the maker's
  # next round-trip; (3) the remedy is a different ANSWERER, not a new grant.
  #
  # Deliberately a warn and not a `fail`: `require_sig` is 1 only on the push and
  # deploy root executors, so a gate that no broker will ever check is unharmed by
  # an empty sig and must not lose its answer over one. This fires exactly when
  # something is already broken — the legitimate non-root path (dashboard exec as
  # `claude`) signs fine, so a healthy box prints nothing.
  if [[ -z "$_sig" ]]; then
    warn "gate closure for ${ident} was stored UNSIGNED (need_answer_sig is empty)."
    warn "  The answer IS recorded and the gate is cleared — what is missing is the"
    warn "  DIVE-756 tamper-evidence signature over the closure."
    warn "  why: ${_sig_why:-the signing step produced no signature}"
    warn "  consequence: a DELEGATED PUSH or DEPLOY on ${ident} will be REFUSED later"
    warn "    (\"gate on ${ident} has no valid signed closure\"). The closure is signed by"
    warn "    the ANSWERER, not by the agent acting on it, so that refusal lands on the"
    warn "    maker's next round-trip and reads as tampering rather than as this."
    warn "  fix: have this gate re-answered from a seat that can sign — root"
    warn "    (\`sudo 5dive task answer ${ident} ...\`) or an agent whose sudo covers"
    warn "    \`5dive gate-proof sign\`. Do NOT grant that to a cli-scoped seat: it signs"
    warn "    arbitrary stdin, so the grant forges any closure, including a human:* one."
  fi

  # DIVE-2410: the gate is settled, so its buttons must stop looking tappable.
  # AFTER the write, never before — the settled state is the DB row, and a
  # Telegram edit is best-effort. Covers the human tap, a lead-clear, and a
  # dashboard/CLI answer, since all three land in this one function.
  _task_gate_retire_buttons "$ident" "answered by ${answered_by}" || true

  # INST-4: the gate CLEAR — the row that decides whether this task's timeline
  # reads "zero-human" or "a human authorized it", so it is worth more care than
  # the emits around it.
  #
  # Provenance is read BACK OUT of the row, not taken from $answered_by, for the
  # DIVE-2090 reason spelled out below: the shell variable is the intent to
  # write, and only the persisted column is the state that landed. A ledger that
  # records intent would attest to clears that never happened.
  #
  # The answer VALUE is hashed, never stored — and for a secret gate not even
  # hashed: `_vfs` is empty there by construction, so the one gate type whose
  # payload is a live credential contributes no digest at all. A digest of a
  # short, guessable answer is not the protection it looks like.
  local _lg_prov; _lg_prov=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${id};" 2>/dev/null)
  ledger_emit gate.answered ident="$ident" task_id="$id" actor="${_lg_prov:-unknown}" \
    policy="tier${gtier}:${nt}" out="$_vfs" \
    detail="${nt} gate cleared by ${_lg_prov:-<unrecorded>}$([[ "$_lg_prov" == human:* ]] && echo ' (human touchpoint)')"

  # DIVE-2412 acceptance: WHICH evidence form cleared this gate must be
  # recoverable FROM THE ROW, not only from a log line that can rotate or diverge
  # from it (DIVE-2090). A tap (`nonce`), a dashboard/on-box exec (`sudo-uid`), the
  # tier<2 chat-only proof (`channel-chat`) and the tier-2 citation
  # (`channel-session`) all persist as need_answered_by=human:*, so without this
  # column the four are indistinguishable afterwards — and `channel-session` is the
  # only one that cleared a tier-2 gate with nobody touching a button. That
  # distinction is the audit question this feature creates, so it is stored, not
  # derived. `+`-joined when more than one form was present; `none` when a
  # non-human path (a decision gate, an auto-answer) wrote the row.
  # _hp/_su are function-scope locals initialized to 0 since DIVE-2406, and the
  # other flags are set only on the paths that raise them — hence the :-0
  # defaults, which are belt-and-braces rather than a guess.
  # DIVE-2799: the five append lines that used to sit here are now
  # `_gate_evidence_form`, because the SAME string has to reach the append-only
  # audit log as well and two copies of this vocabulary would drift. The token
  # spelling and order are unchanged, so this column's values are byte-identical
  # to what DIVE-2412 shipped — EXCEPT for the tier-2 decision case below, which
  # they were wrong about.
  #
  # THE `_t2_*` OR IS A BUG FIX, NOT DEFENSIVENESS, and it was found by the
  # harness for this change rather than reasoned out. `_hp`/`_su` are raised ONLY
  # inside the approval/secret/manual/access evidence block, which does not run
  # for a `decision` gate. The tier-2 floor computes its OWN `_t2_hp`/`_t2_su` and
  # never fed them back here. So a tier-2 DECISION gate cleared by a valid nonce
  # stored `human_evidence='none'` — the form was verified, admitted, and then not
  # recorded. Measured on this tree: the t2 audit row read `nonce_valid=1` while
  # the column on the same answer read `none`.
  #
  # That is precisely the population DIVE-2799's body flags as separately
  # unmeasured ("decision-type tier-2 gates ... never reach this audit line"), so
  # a fix that named the form everywhere EXCEPT there would have reproduced the
  # ticket at a different address — the DIVE-2777 shape the body warns about.
  #
  # SCOPED TO THE RECORD ON PURPOSE: `_hp`/`_su` themselves are left alone because
  # DIVE-2406 reads them at the provenance stamp, and this change must not move
  # any authorization or provenance outcome — only what the record SAYS about one.
  # `${_t2_*:-0}` because those locals exist only when the tier-2 branch ran.
  local _evform; _evform=$(_gate_evidence_form \
    "$(( ${_hp:-0} || ${_t2_hp:-0} ))" "$(( ${_su:-0} || ${_t2_su:-0} ))" \
    "${_cs_ok:-0}" "${_cp_ok:-0}" "${_lead_clear:-0}")
  db "UPDATE tasks SET human_evidence=$(sqlq "${_evform:-none}") WHERE id=${id};"

  # DIVE-3128: the RELAY and the TAPPING UID, in their own columns.
  #
  # Written unconditionally (empty when there was no tap) so the columns mean
  # "this is what the answer carried", not "somebody remembered to set them".
  # A reader can now separate the two questions the old single string conflated:
  # `need_answered_by` says who decided, `need_answered_relay` says whose bot
  # carried it.
  #
  # NOT INSIDE THE DIVE-756 SIGNED CLOSURE, and say so rather than let a reader
  # assume otherwise. The closure signs need_answer/at/by/uid — so the HUMAN NAME
  # is tamper-evident, which is the field this ticket is about — while the relay
  # is corroborating context that a raw DB edit could change without failing
  # `gate-proof verify`. Widening the signed payload would invalidate every
  # signature already stored on the board, so it is a separate decision.
  db "UPDATE tasks SET need_answered_relay=$(sqlq "${relay_agent}"), need_answered_tap_uid=$(sqlq "${tap_uid}") WHERE id=${id};"

  # DIVE-3128: THE TAP LEDGER. A button tap was the least-recorded path in the
  # system for the most rigorously evidenced control. Written AFTER the row, and
  # reading the persisted stamp back out rather than the variable, for the
  # DIVE-2090 reason: a ledger built from intent greens identically whether or not
  # the write landed.
  if [[ -n "$tap_uid" || -n "$relay_agent" || -n "$tap_msg" ]]; then
    local _tap_persisted; _tap_persisted=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${id};")
    # THE VERDICT IS THREE-VALUED for the same reason the roster predicate is:
    # `stored` must mean "checked the name against the roster and it was clean",
    # never "could not look". A run with no readable registry says so in the
    # ledger instead of producing a line indistinguishable from a verified one.
    local _tap_verdict="stored"
    if [[ -n "$_attr_why" ]]; then _tap_verdict="refused:${_attr_why}"
    elif (( _attr_unverified )); then _tap_verdict="stored:roster-unmeasured"
    fi
    local _tap_nonce="absent"; [[ -n "$human_proof" ]] && _tap_nonce="presented"
    _gate_tap_log "$ident" "${gtier:-}" "$nt" "$tap_uid" "$tap_username" "$tap_msg" \
      "$relay_agent" "${_tap_name:-}" "$_tap_persisted" \
      "$_tap_nonce" "$_tap_verdict" "$_tap_src" || true
  fi

  # DIVE-2099: the authoritative record of a STANDING-authority clear. Emitted
  # AFTER the write and reading `need_answered_by` BACK OUT of the row, so it
  # audits the state that actually landed rather than the intent to write it
  # (DIVE-2090: gate-answer state was reaching the DB off the audited path, and a
  # pre-check row greens identically whether or not the write happened). This is
  # a privilege being exercised by the party that asked for it, so it names the
  # authenticated caller, the real invoker uid, the tier and type it was allowed
  # under, and the persisted provenance — enough to re-derive the eligibility
  # decision from the log alone. Never fails the answer.
  #
  # `standing_lead=` is the NAME the sealed constitution carried at clear time and
  # `authority_source=` says where it came from, so a reader can tell an anchored
  # clear from the iteration-1 chart-derived one without diffing the binary.
  # `filer=`/`routed_reviewer=` are recorded as context and are NOT inputs to the
  # decision — the audit must not imply an authority the code does not consult.
  if [[ "$_lead_standing" == "1" ]]; then
    local _ls_persisted; _ls_persisted=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${id};")
    _task_store_audit_log "task answer lead-standing-clear" \
      "$([[ "$_ls_persisted" == lead:standing:* ]] && echo ok || echo error)" 0 -- \
      "task=$ident" "type=$nt" "tier=$gtier" "authority=DIVE-2099 org-lead standing (engineering approval)" \
      "authority_source=sealed-constitution:authority.eng_approval_lead" \
      "authenticated_caller=${_ls_auth:-}" "standing_lead=${_ls_lead:-}" "filer=${_ls_filer:-}" "routed_reviewer=${_routed_rev:-<none>}" \
      "persisted_provenance=${_ls_persisted:-<none>}" "invoker_uid=${_uid:-}" "human=$human" 2>/dev/null || true
  fi

  # DIVE-2090: audit the answer AT THE WRITE, for EVERY need_type. Until now the
  # only `task answer gate` rows came from the PRE-CHECKS above — the
  # approval/secret/manual/access evidence block and the tier-2 floor refusal —
  # so a `decision` gate, and any gate that is neither one of those four types
  # nor tier-2-refused, stored need_answer/at/by/uid/sig with NO audit event
  # behind it at all. That is the reported defect (three instances on DIVE-2051 /
  # DIVE-2084): a stored, signed, nonce-bearing gate answer that the audit log
  # cannot account for, which is exactly the property DIVE-756 exists to provide.
  # Scale when this landed: AT LEAST 78 answered `decision` gates on the live
  # board, none of them auditable (2026-07-26 17:16 UTC; need_type='decision' AND
  # need_answered_at IS NOT NULL AND need_answered_by NOT LIKE 'auto:%'; 127
  # across all types). A lower bound at a moment, not a fixed fact — it climbs
  # with every gate the fleet answers.
  #
  # The divergence ran BOTH ways, so this is not just a missing row. The
  # pre-check rows are emitted BEFORE the write and report a CHECK outcome: an
  # approval that passes the evidence block and then trips the tier-2 floor, or
  # hits the `--value is required` / secret `--value` usage `fail` just above,
  # leaves an `ok` row behind with no answer stored. This row is emitted AFTER
  # the UPDATE and reports the provenance AS STORED, so `task answer gate` at
  # last means "an answer was written" rather than "a check passed". The two are
  # distinguishable by the `answered_by=` field, which only this site carries.
  #
  # Fenced like its sibling call sites (DIVE-2054): a row built from live
  # TASKS_DB state must not be written into the fleet audit log by a fixture
  # store. `|| true` because the write has ALREADY landed — an audit log that
  # cannot be written must never fail an answer that is already durable (a
  # missing row is the defect we are fixing, but losing the answer would be
  # worse, and the caller has no way to retry a half-applied answer). NEVER logs
  # $value: a secret gate stores nothing, and a decision answer is the human's
  # prose, neither of which belongs in the fleet log.
  #
  # DIVE-2799: `evidence=` BELONGS HERE most of all, and putting it only at the
  # pre-check sites would have missed the population the ticket flags as
  # separately unmeasured. The approval/secret/manual evidence block does not run
  # for a `decision` gate at all, so a tier-2 decision clear reaches NEITHER
  # pre-check row — "decision-type tier-2 gates never reach this audit line" is
  # written into DIVE-2799's own body as an unmeasured class. This site fires for
  # EVERY answered gate regardless of type, and per the paragraph above its
  # presence implies a WRITE rather than a passed check. So this is the row that
  # makes "grep separates the evidence forms across history" true of the whole
  # population instead of only the human-gate subset.
  # `$_evform` is the SAME string written to `tasks.human_evidence` sixty lines
  # up — deliberately the same variable, not a recomputation, so the column and
  # the log cannot disagree about one answer.
  local _caller4; _caller4=$(_gate_caller_user)
  _task_store_audit_log "task answer gate" ok 0 -- \
    "task=$ident" "type=$nt" "tier=${gtier:-}" "answered_by=$answered_by" \
    "uid=${_uid:-}" "sig=$([[ -n "$_sig" ]] && echo present || echo absent)" \
    "human=$human" "lead_clear=$_lead_clear" "cp_ok=$_cp_ok" \
    "human_claim=$_human_claim" \
    "evidence=${_evform:-none}" "filer_answered=$(_gate_filer_answered "$id" "$_caller4")" \
    "caller=$_caller4" "sudo_uid=${SUDO_UID:-}" || true

  # DIVE-909: a standalone MANUAL gate answered "done" is the human saying "this
  # is handled / complete" — close the task as DONE, not back to todo. Without
  # this a park-marker holding COMPLETED work had no honest close: the agent
  # can't `task done` (blocked by its own pending gate, DIVE-555) and the only
  # agent-allowed escape was `task cancel`, which mislabels finished work as
  # cancelled (DIVE-524). The already-shipped ✅ Done tap (tna:<id>:done ->
  # `task answer --value=done`, DIVE-356) now lands here and closes cleanly — no
  # plugin/fork change needed. Loop GATE steps are EXEMPT (_lk=gate:*): a manual
  # answer there drives the relay advance below, which owns that status move.
  # DIVE-2228: _lk and _close_done are resolved ABOVE, before any write, because
  # the closed-row refusal keys on them. Do not recompute them here.
  if (( _close_done )); then
    # Close as done + stamp a result IF empty (never clobber real work notes) so
    # the dashboard/creator sees why it closed rather than a blank card.
    # DIVE-2228: the status predicate is defence in depth — the refusal above is
    # the real fence. It is kept so this UPDATE cannot re-stamp a graded row even
    # if a future caller reaches it by another route.
    db "UPDATE tasks SET status='done', done_at=datetime('now'),
           result=CASE WHEN COALESCE(result,'')='' THEN 'Closed via manual-gate tap — marked done by '||$(sqlq "$answered_by") ELSE result END
        WHERE id=${id} AND status NOT IN ('done','cancelled');"
    # DIVE-1415: a manual-gate answer that closes the task DONE is terminal — its
    # dependents must release just as they would on `task done`.
    _task_cascade_unblock "$id" || true
  else
    # Clearing the gate ≠ unblocking. `status='blocked'` is overloaded (human
    # gate AND task-task `block` edges), so RECOMPUTE rather than hardcode todo:
    # flip to todo only if no block edges remain — same edge-check `unblock` does
    # — else stay blocked (still waiting on another task). Answered-ness lives in
    # need_answered_at, so the task already left the inbox regardless of status.
    db "UPDATE tasks SET status='todo'
        WHERE id=${id} AND status='blocked'
          AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id});"
  fi
  local newstatus; newstatus=$(db "SELECT status FROM tasks WHERE id=${id};")

  # DIVE-552: a loop GATE step was just answered → advance the relay. Approve
  # (decision "Approve →", or any manual answer) closes the gate step and frees
  # the next step; "Do better ↩" bounces to the previous step to redo (re-blocks
  # the gate by it; when that step re-completes the gate re-fires fresh). Reuses
  # _task_loop_advance + the block edges. Best-effort; never fails the answer.
  # (_lk was resolved above for the DIVE-909 close-as-done check — reuse it.)
  # DIVE-560: a loop APPROVAL gate only advances on a HUMAN-cleared answer
  # (need_answered_by=human:*). The answer path above already blocks an agent
  # self-answering an approval gate; this makes the loop's "the final say is
  # yours" guarantee explicit and regression-proof — if a non-human path ever
  # clears it (e.g. a future regression, or the audited sudo-bypass), the relay
  # simply doesn't advance. manual gates stay agent-answerable (agents
  # legitimately resolve those), so they're exempt. Falling through here without
  # advancing still records the answer + emits the success output below.
  # DIVE-2406 made this branch REACHABLE for a case that used to slip past it: a
  # lead-cleared loop approval gate whose clearer also passed `--human` was
  # stamped `human:<lead>` and advanced the relay. It is now stamped `lead:<lead>`
  # and does NOT advance — which is what the paragraph above always said should
  # happen ("if a non-human path ever clears it ... the relay simply doesn't
  # advance"); the advance was previously bought with a label that was not true.
  # Deliberately NOT widened to `lead:*`: that would hand a lead the loop-advance
  # authority DIVE-560 reserves for the human, which is a grant, not a relabel.
  # Measured before shipping: 2 answers fleet-wide have ever carried
  # lead_clear=1 + human=1 (DIVE-2121, DIVE-2400) and neither was a loop step, so
  # no live loop changes behaviour — but a future routed loop gate will stall here
  # rather than advance, and that is the intended reading of DIVE-560.
  local _gate_may_advance=1
  if [[ "$_lk" == "gate:approval" ]]; then
    local _ab; _ab=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE id=${id};")
    case "$_ab" in human:*) : ;; *) _gate_may_advance=0 ;; esac
  fi
  case "$_lk" in
    gate:*)
      if (( _gate_may_advance )); then
      # Bounce (redo the previous step) vs advance. Match the reject vocabulary
      # of BOTH gate styles: the old decision options ("Do better ↩") and the
      # approval buttons ("denied" — DIVE-560). NB "denied" does NOT contain the
      # substring "deny", so it must be matched explicitly; missing it would let a
      # human's DENY silently ADVANCE the loop. Anything else (approve/approved)
      # advances.
      if (( _loop_bounce )); then
        if [[ -n "$_prev" ]]; then
          # DIVE-2228: the fence goes IN THE WHERE, matching the idiom the
          # else-branch above has always used, so a future write here either
          # copies its neighbours or looks visibly different from all of them.
          # THE ${_prev} WRITE IS DELIBERATELY NOT FENCED — it targets a
          # DIFFERENT row, and reopening completed work is the whole point of a
          # bounce. DIVE-2261 preflights the exceptional CANCELLED state before
          # any answer write; a WHERE status fence here would create a partial
          # commit (answered gate, no redo) instead of an honest refusal.
          # tests/task_answer_closed_row_unit.sh enumerates these writes and
          # asserts the rule per target, so the exemption is graded, not assumed.
          db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES (${id}, ${_prev});
              UPDATE tasks SET status='blocked' WHERE id=${id} AND status NOT IN ('done','cancelled');
              UPDATE tasks SET status='todo', started_at=NULL WHERE id=${_prev};"
          local _pw _pl; _pw=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${_prev};"); _pl=$(db "SELECT title FROM tasks WHERE id=${_prev};")
          [[ -n "$_pw" ]] && ( cmd_send "$_pw" --from="loop" --message="↩ Loop bounced back — redo: ${_pl}" ) >/dev/null 2>&1 || true
        fi
      else
        # DIVE-2228: defence in depth, same as the close-as-done branch — a
        # gate STEP that is already closed is refused above, before any write.
        db "UPDATE tasks SET status='done', done_at=datetime('now') WHERE id=${id} AND status NOT IN ('done','cancelled');"
        _task_loop_advance "$id" || true
        # DIVE-1415: _task_loop_advance only frees this gate's loop-STEP siblings;
        # a non-loop task blocked_by this gate step is a cross-DAG dependent it
        # never touches. Cascade so those release on the gate's terminal close.
        _task_cascade_unblock "$id" || true
      fi
      fi
      ;;
  esac

  # Best-effort resume ping over the existing agent-send path. We deliberately
  # do NOT embed the answer value: cmd_send mirrors the outbound into the group
  # chat, so a `secret` answer would leak. The agent reads need_answer itself
  # via `task show` (its own pane only). A stopped or non-agent owner just
  # yields pinged:false — it never fails the answer.
  local pinged=0
  # DIVE-909: a close-as-done manual gate needs no "resume the task" ping — the
  # task is finished, not waiting to resume. Skip it (the `now done` output is
  # the signal); pinging the owner to resume a closed task is just confusing.
  if [[ -n "$owner" ]] && (( ! _close_done )); then
    local pingmsg
    if [[ "$nt" == "secret" ]]; then
      pingmsg="${ident} secret gate marked provided — resume the task and load the key from where it was placed (its .env / your own channel), NOT from the task."
    else
      pingmsg="${ident} gate cleared — your '${nt}' ask was answered. Resume the task; run \`5dive task show ${ident}\` for the value."
    fi
    local actor; actor=$(task_actor "$from")
    if valid_sender_label "$actor"; then
      ( cmd_send "$owner" --from="$actor" --message="$pingmsg" ) >/dev/null 2>&1 && pinged=1 || true
    else
      ( cmd_send "$owner" --message="$pingmsg" ) >/dev/null 2>&1 && pinged=1 || true
    fi
  fi

  local note=""
  [[ $pinged -eq 1 ]] && note=" + pinged $owner"
  # DIVE-2212: do not make the answerer re-read the ambiguous option as the only
  # confirmation. Name both accounts and declare the authored frame. The raw
  # value remains in the structured need_answer field for compatibility, but the
  # human receipt does not merely echo it back and leave both readings intact.
  local _account_frame=0 _frame_filer="" _frame_answerer="" _frame_note=""
  if [[ "$nt" == "decision" ]] && _gate_option_has_second_person "$value"; then
    _account_frame=1
    _frame_filer=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''), NULLIF(assignee,''), NULLIF(created_by,''), 'unknown') FROM tasks WHERE id=${id};")
    case "$answered_by" in
      human:*)         _frame_answerer="${answered_by#human:}" ;;
      lead:standing:*) _frame_answerer="${answered_by#lead:standing:}" ;;
      lead:*)          _frame_answerer="${answered_by#lead:}" ;;
      auto:*)          _frame_answerer="${answered_by#auto:}" ;;
      *)               _frame_answerer="$answered_by" ;;
    esac
    [[ -n "$_frame_answerer" ]] || _frame_answerer="unknown"
    _frame_note=" — account frame: filer=${_frame_filer}, answerer=${_frame_answerer}; second-person terms in the selected filer-authored option refer to ${_frame_answerer}"
  fi
  ok "$ident answered ($nt) — now ${newstatus}${note}${_frame_note}" \
     '{id:($i|tonumber), status:$st, need_type:$nt, provided:true, need_answer:(if $nt=="secret" then null else $v end), owner:(($o|select(length>0)) // null), pinged:($p=="1"), option_account_frame:(if $af=="1" then {filer:$gf, answerer:$ga, second_person_refers_to:$ga} else null end)}' \
     --arg i "$id" --arg st "$newstatus" --arg nt "$nt" --arg v "$value" --arg o "$owner" --arg p "$pinged" \
     --arg af "$_account_frame" --arg gf "$_frame_filer" --arg ga "$_frame_answerer"
}

# cmd_task_escalate — DIVE-449: the /task_<id> Telegram "Escalate" button (and a
# plain CLI verb). Semantics A (Mark's call 2026-06-17): "flag for attention" —
# bump the task's priority up ONE tier (capped at urgent) AND ping both the
# owning agent ("get eyes on it / I'm stuck") and the paired human, so a stuck
# task can't sit unseen at its old priority. Does NOT file a human gate (that's
# `task need`) or reassign (that's `task assign`). The bump + escalated_at/by
# audit stamp persist; the two pings are best-effort and never fail the verb.
cmd_task_escalate() {
  tasks_db_init
  local from=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from=*) from="${1#*=}" ;;
      --)       shift; positional+=("$@"); break ;;
      -*)       fail "$E_USAGE" "unknown flag: $1" ;;
      *)        positional+=("$1") ;;
    esac
    shift
  done
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task escalate <id|DIVE-N>"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"

  # Don't escalate a finished task — there's nothing to get eyes on.
  local status; status=$(db "SELECT status FROM tasks WHERE id=${id};")
  [[ "$status" == "done" || "$status" == "cancelled" ]] && \
    fail "$E_CONFLICT" "$ident is $status — nothing to escalate."

  local old_pri title assignee created_by
  old_pri=$(db "SELECT COALESCE(priority,'medium') FROM tasks WHERE id=${id};")
  title=$(db "SELECT title FROM tasks WHERE id=${id};")
  # Who to get eyes on it: the assignee, else the creator.
  local owner; owner=$(db "SELECT COALESCE(NULLIF(assignee,''), NULLIF(created_by,''), '') FROM tasks WHERE id=${id};")

  # Bump up one tier, capped at urgent. low/medium -> high keeps the common
  # "this is stuck" tap meaningful; a second tap on a high task reaches urgent.
  local new_pri
  case "$old_pri" in
    low|medium) new_pri="high" ;;
    high)       new_pri="urgent" ;;
    urgent)     new_pri="urgent" ;;
    *)          new_pri="high" ;;
  esac

  local actor; actor=$(task_actor "$from")
  db "UPDATE tasks SET priority=$(sqlq "$new_pri"), escalated_at=datetime('now'), escalated_by=$(sqlq "$actor") WHERE id=${id};"

  local pri_note="$old_pri → $new_pri"
  [[ "$old_pri" == "$new_pri" ]] && pri_note="$new_pri (already top tier)"

  # Ping the owning agent over the existing agent-send path — but never ping the
  # actor about its own task (an agent escalating its own work already knows).
  local pinged=0
  if [[ -n "$owner" && "$owner" != "$actor" ]]; then
    local pingmsg="🔺 ${ident} escalated by ${actor} — flagged as needing attention (priority ${pri_note}). Get eyes on it; run \`5dive task show ${ident}\`."
    if valid_sender_label "$actor"; then
      ( cmd_send "$owner" --from="$actor" --message="$pingmsg" ) >/dev/null 2>&1 && pinged=1 || true
    else
      ( cmd_send "$owner" --message="$pingmsg" ) >/dev/null 2>&1 && pinged=1 || true
    fi
  fi

  # Ping the paired human so an escalation surfaces on their phone (best-effort,
  # mirrors task_need_notify's owner-channel resolution + send path).
  local notified_human=0
  if _task_owner_channel; then
    local htext="🔺 [${ident}] escalated by ${actor} — needs attention"$'\n\n'"${title}"$'\n\n'"priority ${pri_note}"
    _task_send_owner "$htext" "" && notified_human=1 || true
  fi

  local note=""
  [[ $pinged -eq 1 ]] && note=" + pinged $owner"
  ok "$ident escalated — priority ${pri_note}${note}" \
     '{id:($i|tonumber), priority:$np, was:$op, owner:(($o|select(length>0)) // null), pinged:($p=="1"), human_notified:($h=="1")}' \
     --arg i "$id" --arg np "$new_pri" --arg op "$old_pri" --arg o "$owner" --arg p "$pinged" --arg h "$notified_human"
}

cmd_task_rm() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task rm <id|DIVE-N>"
  resolve_task_id "$1"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  db "DELETE FROM tasks WHERE id=${id};"
  ok "$ident deleted" '{id:($i|tonumber), deleted:true}' --arg i "$id"
}
