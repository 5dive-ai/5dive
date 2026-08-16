#!/usr/bin/env bash
# TIER: core — 0.5s measured (DIVE-2538): pure text analysis, no db, no network, no root.
# DIVE-2538 — the eight raw identity reads that still fed DECISIONS after DIVE-2518
# collapsed the attribution sites onto the sealed derivation. This harness is the
# COMPLETENESS check for that set, and it is deliberately not a grep for the token
# that led us to each site.
#
# WHY NOT A TOKEN GREP, which is the obvious and wrong implementation. Item 8
# (`_task_owner_channel`) had two forgeable arms: a PRIMARY one reading $SUDO_USER
# through `auto_sender_from_sudo`, and a FALLBACK `${USER:-$(id -un)}`. Two
# consecutive reviews read the line the identifier pointed at, judged the FUNCTION on
# it, and the axis lived one branch up. Patch only the fallback and a grep for
# `${USER:-$(id -un)}` returns ZERO while the branch that actually selects the
# recipient is untouched — the completeness check would certify exactly the fix that
# misses. So each arm below extracts the whole DECIDING FUNCTION and demands no raw
# identity primitive survives anywhere in it.
#   community/wiki/a-recomputed-triage-drops-the-sites-the-parent-named.md
#
# Every arm carries a POSITIVE CONTROL: the pre-fix text of that same function is run
# through the identical predicate and must come back RED. A completeness harness that
# has never been shown to fail is decoration — and on this row that is not a general
# worry, it is the specific failure mode being guarded.
#
# Run: bash tests/identity_decision_sites_unit.sh   (no root, no network, no db)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# The class, not the form. `id -un`/`id -u` resolve through the CALLER'S PATH
# (DIVE-2330); $SUDO_USER/$USER/$LOGNAME are plain env vars below root (DIVE-1413);
# `logname` is both. A bare SUDO_UID read is only safe behind a real-root check, which
# is why it is in the class too — `actor_routing_agent` is the ONE sanctioned reader
# of it outside root, and it is exempted by name below.
#
# `auto_sender_from_sudo` is in the class too, and that is not padding — it is the
# arm that made the half-fix control below pass on the first run of this harness. The
# forgeable read can hide behind a HELPER NAME containing no primitive at all, so a
# predicate that only knows tokens grades a wrapper as clean. The class is "reaches a
# forgeable identity input", not "contains one of these strings".
RAW_RE='\$\(id -un?[^)]*\)|`id -un?|\$\{?SUDO_USER|\$\{?LOGNAME|\$\(logname|\$\{?USER[:}]|\$\{?SUDO_UID|auto_sender_from_sudo'

# Per-site exemptions. Each needs a WRITTEN reason, and each is a claim a reviewer can
# refute — that is the point of listing them here rather than narrowing the regex until
# the harness is green.
#
#   _gate_gh_token arm 2 — `u="${SUDO_USER:-}"` then `sudo -n -u "$u" gh auth token`.
#   Found by this class-grep; NOT one of the parent's seven, and triaged as not-a-defect.
#   $SUDO_USER here is a TARGET SELECTOR for sudo, not an identity the code believes:
#   sudo itself enforces whether the caller may become $u, so a forged value borrows
#   only a token sudoers would already have handed over. The one real effect is
#   ARM PRECEDENCE — a forged SUDO_USER=claude fires arm 2 before the caller's own
#   arm 3, inverting DIVE-1935's "a caller's own credential always wins". That is
#   reachable anyway through GH_TOKEN at arm 1, so it grants nothing new. Left alone
#   deliberately: the uid-derived rewrite REGRESSES it, because under a real
#   `sudo 5dive` the euid is root and the invoker's name is only in SUDO_UID.
EXEMPT_gate_evidence_gh='u="\$\{SUDO_USER:-\}"|sudo -u \\\$SUDO_USER'

# fn_body <file> <fn> — the text of one function, brace-to-brace at column 0.
fn_body() {
  local f="$1" fn="$2"
  [[ -r "$f" ]] || { printf ''; return 1; }
  awk -v FN="^${fn}\\\\(\\\\)" '$0 ~ FN {inside=1} inside {print} inside && /^}/ {exit}' "$f"
}

# offenders <text> [exempt_re] — the raw identity reads left in a deciding function.
# Comments are stripped FIRST: every fixed site carries a comment naming the construct
# it replaced, and a wrapped comment otherwise returns a false RED here exactly as it
# returns a false absence to a grep.
offenders() {
  local txt="$1" ex="${2:-}"
  if [[ -n "$ex" ]]; then
    printf '%s\n' "$txt" | sed 's/#.*$//' | grep -nE "$RAW_RE" | grep -vE "$ex" || true
  else
    printf '%s\n' "$txt" | sed 's/#.*$//' | grep -nE "$RAW_RE" || true
  fi
}
is_clean() { [[ -z "$(offenders "$1" "${2:-}")" ]]; }

# --- the eight sites, by identifier ------------------------------------------
# file | function | item | what the value DECIDES (the axis, which is the payload —
# the identifier is only the handle).
SITES=(
  "src/cmd_agent_runtime.sh|cmd_deliver|1|a2a sender class + the round-cap key"
  "src/cmd_agent_create.sh|cmd_create|2|whether a new agent gets the default skill"
  "src/cmd_agent_create.sh|sudo_grant_lines|3|whose sudo grants may be published as \$user's"
  "src/cmd_proof.sh|_proof_identity|4|whether the target user's gitconfig is read at all"
  "src/task/gate_evidence.sh|_gate_gh_token|5|whether the last token arm runs (fail-OPEN gate below)|$EXEMPT_gate_evidence_gh"
  "src/cmd_proof.sh|_proof_publish|6|the STORED lastPublishedBy.user staleness record"
  "src/cmd_objective.sh|cmd_objective_add|7|the STORED objectives.created_by acting agent"
  "src/task/notify.sh|_task_owner_channel|8|WHICH AGENT'S TELEGRAM BOT a notification reaches"
  # Item 9 is NOT one of the parent's seven, nor the reconciliation's eight. It came out
  # of grepping the CLASS (`auto_sender_from_sudo` included) across all of src/ instead
  # of only the named sites — the exact move this row's own wiki page prescribes and the
  # exact one a fix-the-list pass skips, because the list resolved and a resolved list
  # feels like the check. Same construct as item 7, one function over, and it is the
  # field DIVE-2512's tombstone rests on: a forgeable `retired_by` is what makes an
  # authorized retirement indistinguishable from a wipe again.
  "src/cmd_objective.sh|cmd_objective_rm|9|the STORED objectives.retired_by tombstone attribution"
)

for spec in "${SITES[@]}"; do
  # `ex` MUST be its own variable: with one fewer name than fields, `read` folds the
  # remainder into the LAST one, so a 4-name read silently appends the exemption regex
  # to $axis and passes NOTHING to the predicate. That is not a cosmetic bug — it is
  # this harness reproducing, in itself, the failure it grades: an exemption that
  # resolves to a field and never reaches the check it names.
  IFS='|' read -r file fn item axis ex <<<"$spec"
  body=$(fn_body "$file" "$fn")
  if [[ -z "$body" ]]; then
    no "item $item: ${fn} not found in ${file} — the site MOVED and this arm is now vacuous, re-resolve it by identifier"
    continue
  fi
  if is_clean "$body" "$ex"; then
    ok "item $item ${fn}(): no raw identity primitive decides — ${axis}"
  else
    no "item $item ${fn}() still reads a raw identity primitive (${axis}): $(offenders "$body" "$ex" | head -3 | tr '\n' ' ')"
  fi
done

# --- POSITIVE CONTROLS -------------------------------------------------------
# The predicate must go RED on the pre-fix text of the very functions above.

ctl_primary='_task_owner_channel() {
  local name="" s
  s=$(auto_sender_from_sudo)
  if [[ -n "$s" ]]; then
    name="$s"
  else
    local u="${USER:-$(id -un 2>/dev/null)}"
    [[ "$u" == agent-* ]] && name="${u#agent-}"
  fi
  _task_agent_channel "$name"
}'
is_clean "$ctl_primary" \
  && no "CONTROL FAILED — the predicate passes the PRE-FIX item 8; every arm above is vacuous" \
  || ok "CONTROL: the pre-fix _task_owner_channel is caught"

# The half-fix control, and the reason this harness exists in this shape. Only the
# FALLBACK is closed; `auto_sender_from_sudo` (the branch that actually decides)
# remains. A token grep for ${USER:-$(id -un)} returns ZERO on this text.
ctl_halffix='_task_owner_channel() {
  local name="" s
  s=$(auto_sender_from_sudo)
  [[ -n "$s" ]] && name="$s"
  _task_agent_channel "$name"
}'
if printf '%s\n' "$ctl_halffix" | grep -qE '\$\{USER:-\$\(id -un'; then
  no "CONTROL SETUP BROKEN — the half-fix fixture still contains the token it must not"
elif is_clean "$ctl_halffix"; then
  no "CONTROL FAILED — the HALF-FIX passes: closing only the fallback would be certified complete, which is the exact defect on this row"
else
  ok "CONTROL: the half-fix (fallback closed, forgeable PRIMARY branch left) is still caught"
fi

ctl_id='sudo_grant_lines() {
  if [[ "$(id -u)" == "0" ]]; then :
  elif [[ "$user" == "$(id -un)" ]]; then :
  fi
}'
is_clean "$ctl_id" \
  && no "CONTROL FAILED — the predicate passes a bare PATH-resolved 'id -un' comparison" \
  || ok "CONTROL: a bare PATH-resolved 'id -un' comparison is caught"

# And a NEGATIVE control: the sanctioned resolvers must NOT trip the predicate, or
# every arm above passes only because nothing could ever pass.
ctl_fixed='_task_owner_channel() {
  _task_agent_channel "$(actor_routing_agent)"
}'
is_clean "$ctl_fixed" \
  && ok "CONTROL: the sanctioned actor_routing_agent form passes (the predicate is not vacuously red)" \
  || no "CONTROL FAILED — the predicate rejects the sanctioned form; the arms above cannot distinguish a fix"

# --- the item-5 exemption is load-bearing, not a dead regex -------------------
# An exemption that matches nothing is indistinguishable from a clean function, and
# the arm above would read `ok` either way. Show it does work: with the exemption
# removed the same function must go RED, which also proves the predicate reaches it.
_ge=$(fn_body src/task/gate_evidence.sh _gate_gh_token)
if [[ -z "$_ge" ]]; then
  no "CONTROL: _gate_gh_token not found — the item-5 exemption control is vacuous"
elif is_clean "$_ge" ""; then
  no "CONTROL FAILED — _gate_gh_token is clean even WITHOUT the arm-2 exemption, so that exemption is dead text hiding nothing; delete it or the arm is not saying what it claims"
else
  ok "CONTROL: the item-5 arm-2 exemption is load-bearing (removing it reddens _gate_gh_token)"
fi

# --- SUDO_UID: every read is guarded, sanctioned, or a named exemption --------
# `actor_routing_agent` reads SUDO_UID outside a root check on purpose (a de-elevated
# `sudo -u` relay; sudo itself stamps the value). That is a deliberate, argued
# exception, and the risk is that it becomes a PATTERN somebody copies. The first cut
# of this arm asserted "SUDO_UID appears in exactly one FILE" and went red on seven —
# every one of them a false positive, because a file-level grep counts prose. Four of
# the seven were comments, help heredocs and an SQL comment; the arm was measuring
# the wrong thing and would have been narrowed into uselessness to get it green.
#
# What it asserts instead, per READ rather than per file: each one is
#   (a) inside a function carrying a real-root guard — below EUID 0, SUDO_UID is a
#       plain env var (DIVE-1413), so a root guard is what makes the read sound; or
#   (b) `actor_routing_agent`, the ONE sanctioned unguarded decider; or
#   (c) a named exemption below, each with a written reason and a SHAPE assertion so
#       the exemption cannot silently start covering a decision.
# Anything else is a new reader that owes its own corroboration argument.
#
#   answer.sh / cmd_task_answer — `sudo_uid=${SUDO_UID:-}` passed to the audit sink,
#   beside a derived `caller=`. Recording the raw CLAIM next to the derived truth is
#   the DIVE-2383 shape and is the point: nothing branches on it. Shape-asserted to
#   `sudo_uid=` so a decision cannot hide under this reason.
#   main.sh / usage, cmd_whoami.sh / cmd_whoami, tasks_db.sh / _tasks_schema — help
#   heredocs, a single-quoted display label and an SQL comment. Text, never read.
sudo_uid_exempt() {   # <file> <fn> <code-line> -> 0 if a named exemption covers it
  case "$1:$2" in
    src/task/answer.sh:cmd_task_answer) [[ "$3" == *'sudo_uid='* ]] ;;
    src/main.sh:usage|src/cmd_whoami.sh:cmd_whoami|src/lib/tasks_db.sh:_tasks_schema) return 0 ;;
    *) return 1 ;;
  esac
}
_su_enclosing_fn() {  # <file> <lineno> -> "<fn>\t<startline>" of the nearest preceding definition
  awk -v L="$2" 'NR<=L && /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ {n=$0; sub(/\(\).*/,"",n); ln=NR} END{print n"\t"ln}' "$1"
}
_su_unclassified=""; _su_guarded=0; _su_sanctioned=0; _su_exempt=0
while IFS=: read -r f l rest; do
  code=$(printf '%s' "$rest" | sed 's/#.*$//')
  [[ "$code" == *SUDO_UID* ]] || continue      # comment-only line
  IFS=$'\t' read -r fn fl < <(_su_enclosing_fn "$f" "$l")
  fbody=$(awk -v S="$fl" 'NR>=S {print} NR>=S && /^}/ {exit}' "$f")
  if [[ "$fn" == "actor_routing_agent" ]]; then _su_sanctioned=$((_su_sanctioned+1))
  elif printf '%s' "$fbody" | grep -qE '_gate_is_root|EUID -eq 0|require_root'; then _su_guarded=$((_su_guarded+1))
  elif sudo_uid_exempt "$f" "$fn" "$code"; then _su_exempt=$((_su_exempt+1))
  else _su_unclassified+="${f}:${l} (${fn:-<top level>}) "
  fi
done < <(grep -rnE '\$\{?SUDO_UID' src/ 2>/dev/null)

[[ "$_su_sanctioned" -gt 0 ]] \
  && ok "SUDO_UID: the sanctioned unguarded reader actor_routing_agent is present (${_su_sanctioned} read(s)) — this arm is not passing because the fix vanished" \
  || no "SUDO_UID: actor_routing_agent reads no SUDO_UID — the de-elevated relay branch is GONE, so the sudo -u regression is back"
[[ -z "$_su_unclassified" ]] \
  && ok "SUDO_UID: every read is root-guarded (${_su_guarded}), the sanctioned reader (${_su_sanctioned}), or a named exemption (${_su_exempt}) — no unargued reader" \
  || no "SUDO_UID read with no root guard, outside actor_routing_agent, and covered by no named exemption — it owes a corroboration argument: ${_su_unclassified}"

# And the classifier must be able to FAIL: a bare unguarded read in an ordinary
# function is the thing it exists to catch, so prove it catches one.
_su_ctl=$(mktemp); printf 'some_new_helper() {\n  local u="${SUDO_UID:-}"\n  printf %%s "$u"\n}\n' > "$_su_ctl"
_su_ctl_fn=$(_su_enclosing_fn "$_su_ctl" 2 | cut -f1)
if [[ "$_su_ctl_fn" == "some_new_helper" ]] \
   && ! printf 'some_new_helper() {\n  local u="${SUDO_UID:-}"\n}\n' | grep -qE '_gate_is_root|EUID -eq 0|require_root' \
   && ! sudo_uid_exempt "src/some_new.sh" "some_new_helper" 'local u="${SUDO_UID:-}"'; then
  ok "CONTROL: an unguarded SUDO_UID read in a new ordinary function is classified UNCLASSIFIED"
else
  no "CONTROL FAILED — the SUDO_UID classifier does not flag a bare unguarded read (enclosing fn resolved to '$_su_ctl_fn'); the arm above cannot fail"
fi
rm -f "$_su_ctl"

# --- the CLASS sweep: every remaining auto_sender_from_sudo caller ------------
# The site table above is a LIST, and a list only ever proves things about its own
# entries. Item 9 was not on it: `cmd_objective_rm` carried the identical construct as
# item 7 one function over, and the eight-item triage — itself already a reconciliation
# against a parent's hand-named sites — did not have it. What surfaced it was sweeping
# the CLASS across all of src/ rather than re-reading the list.
#
# So this arm is the one that outlives the row. `auto_sender_from_sudo` is
# `${SUDO_USER:-}` plus an `agent-*` prefix test and nothing else (lib/validation.sh),
# forgeable by any caller with no privilege. Every remaining call of it must be either
# inside a real-root guard — where sudo stamped the value — or a named, reasoned
# not-a-defect. A NEW caller is a red here even if nobody thinks to re-triage.
#
#   cmd_agent_runtime.sh `_envelope_caller` — the DIVE-2182/2183 gap, left open ON
#   PURPOSE with the argument written above the function; not this row's to close.
#   cmd_agent_runtime.sh `cmd_ask` — a label for THIS command's JSON summary. The
#   scoped `_deliver` path re-derives the sender independently, and that derivation is
#   item 1, now sealed. Display, and the comment at the site says so.
asfs_exempt() {
  case "$1:$2" in
    src/cmd_agent_runtime.sh:_envelope_caller|src/cmd_agent_runtime.sh:cmd_ask) return 0 ;;
    *) return 1 ;;
  esac
}
_asfs_bad=""; _asfs_guarded=0; _asfs_exempt=0
while IFS=: read -r f l rest; do
  [[ "$f" == src/lib/validation.sh ]] && continue           # the definition itself
  code=$(printf '%s' "$rest" | sed 's/#.*$//')
  [[ "$code" == *auto_sender_from_sudo* ]] || continue      # comment-only mention
  IFS=$'\t' read -r fn fl < <(_su_enclosing_fn "$f" "$l")
  fbody=$(awk -v S="$fl" 'NR>=S {print} NR>=S && /^}/ {exit}' "$f")
  if printf '%s' "$fbody" | grep -qE '_gate_is_root|EUID -eq 0|require_root'; then _asfs_guarded=$((_asfs_guarded+1))
  elif asfs_exempt "$f" "$fn"; then _asfs_exempt=$((_asfs_exempt+1))
  else _asfs_bad+="${f}:${l} (${fn:-<top level>}) "
  fi
done < <(grep -rn 'auto_sender_from_sudo' src/ 2>/dev/null)
[[ -z "$_asfs_bad" ]] \
  && ok "class sweep: every auto_sender_from_sudo caller is root-guarded (${_asfs_guarded}) or a named not-a-defect (${_asfs_exempt}) — no unguarded twin of items 7/9 left" \
  || no "an unguarded auto_sender_from_sudo caller decides outside a root check — triage it by AXIS (routing/storage/gating are all decisions; only never-branched-on text is display): ${_asfs_bad}"

printf '\nidentity_decision_sites_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
