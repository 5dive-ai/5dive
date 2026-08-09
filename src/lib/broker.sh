# lib/broker.sh — INST-5: the capability broker, generalized off delegated push.
#
# Delegated push (DIVE-1376/1460/1461/1462/1496) was our first brokered
# capability. INST-5 asks to fold the remaining dangerous surfaces in behind the
# same template — email, deploy, DNS, payments, secrets, data-export — one at a
# time. The design pass that preceded this file measured which half of the push
# template actually ports, and the answer is counterintuitive enough to belong
# next to the code rather than only in the wiki
# ([[which-half-of-the-delegated-push-template-generalizes]]):
#
#   The HEADLINE security property of delegated push — a repo-SCOPED,
#   SHORT-LIVED installation token minted per use — is the half that does NOT
#   generalize. It exists only because GitHub Apps expose a mint-on-demand API
#   we can drive from the control plane. No other surface we hold a credential
#   for does (for deploy this is MEASURED, not assumed — see cmd_deploy.sh).
#   Defining the broker as "it mints scoped short-lived credentials" would put
#   five of six surfaces out of scope BY DEFINITION and stall the project.
#
# So the portable contract is the part that reads as plumbing:
#
#   (policy predicate + target binding)
#     -> (root-only single-action executor, params on STDIN)
#       -> (audit + capability row)
#
# This file holds the first stage, surface-agnostic. `_push_gate_check` and
# `_push_bind_branch` were already surface-agnostic in everything but their
# names and the body key they read; what follows is those two functions with the
# body key, the target noun and the action noun lifted into a table. Push passes
# exactly the values it used to hardcode, so its behaviour AND its refusal
# strings are byte-identical — tests/broker_surface_unit.sh proves that
# inertness against origin/main's copies before deploy is allowed to rely on it.
#
# Adding surface N+1 is then: one row in the table below, one root-only
# executor, one name in _capability_names_for_standard, one sudoers block. The
# security model is not rewritten per surface, which was the whole point.

# broker_surfaces — every surface folded into the broker, one per line. The
# capability registry drift test enumerates THIS, so a surface that gains a
# sudoers grant without a registry name (or the reverse) fails a test rather
# than becoming a silently unrecorded authority.
broker_surfaces() {
  printf '%s\n' push deploy
}

# broker_surface <surface> <field> — the per-surface constants the predicates
# below need. ONE table, so the capability registry, the sudoers policy and the
# refusal strings cannot each carry a private copy of "what deploy is".
#
# fields:
#   noun    the action, lowercase, as it appears in a refusal    (push / deploy)
#   Noun    the same word, sentence-initial
#   cap     the capability-registry name                       (delegated_push)
#   verb    the root-only executor subcommand                        (_push_do)
#   key     the task-body key a cleared gate binds to                  (Branch)
#   target  the bound thing, lowercase, as it appears in a refusal     (branch)
#   ask     the example --ask the no-gate refusal suggests
#   ticket  the ticket that introduced the binding, cited in the refusal
#
# Unknown surface/field is a HARD failure, not an empty string: a refusal
# rendered with an empty noun still refuses, so it would ship as "works".
broker_surface() {
  local s="$1"
  local f="$2"
  case "${s}.${f}" in
    push.noun)     printf 'push' ;;
    push.Noun)     printf 'Push' ;;
    push.cap)      printf 'delegated_push' ;;
    push.verb)     printf '_push_do' ;;
    push.key)      printf 'Branch' ;;
    push.target)   printf 'branch' ;;
    push.ask)      printf 'approve delegated push for review of branch <b>' ;;
    push.ticket)   printf 'DIVE-1462' ;;
    # DIVE-3081: the verb that OWNS the body line, named in the look-alike-values
    # refusal so the reader is pointed at the canonical writer instead of hand-
    # editing the body again (hand-editing is how the malformed value got in).
    # Empty is a legal answer — deploy has no such verb yet, and the refusal then
    # just omits the repair sentence rather than naming a command that does not
    # exist. Any surface added here must answer this field.
    push.fixcmd)   printf '5dive task set-branch' ;;
    deploy.fixcmd) printf '' ;;
    deploy.noun)   printf 'deploy' ;;
    deploy.Noun)   printf 'Deploy' ;;
    deploy.cap)    printf 'delegated_deploy' ;;
    deploy.verb)   printf '_deploy_do' ;;
    deploy.key)    printf 'Deploy' ;;
    deploy.target) printf 'deploy target' ;;
    deploy.ask)    printf 'approve production deploy of <project>@<ref>' ;;
    deploy.ticket) printf 'INST-5' ;;
    *) fail "$E_GENERIC" "broker: unknown surface/field '${s}.${f}' (add it to broker_surface in src/lib/broker.sh)" ;;
  esac
}

# broker_gate_check <surface> <id> <ident> [require-signature] — the ONE
# cleared-gate predicate, formerly _push_gate_check (DIVE-1376/1460/1496). The
# task must carry an answered, non-rejected gate cleared by either a proven
# human OR the gate's designated routed reviewer. A bare agent answer and every
# auto-clear provenance are deliberately excluded: neither authorizes a
# privileged write. The friendly agent-side preflight checks the persisted
# provenance; the root-only executor passes require-signature=1 and also
# verifies the root-HMAC closure, so raw DB edits cannot forge authorization.
broker_gate_check() {
  local surface="$1" id="$2" ident="$3" require_sig="${4:-0}"
  local noun; noun=$(broker_surface "$surface" noun)
  local ask;  ask=$(broker_surface "$surface" ask)
  local gtype ganswer gansweredat gby guid gsig reviewer authorized=0
  # DIVE-2801: cleared FIRST, before any of the arms below can `fail` out. Every
  # earlier refusal (no gate, open, rejected, unauthorized) returns without ever
  # reaching the signature block, and a state left over from a PREVIOUS call would
  # then be rendered as this call's answer — a stale "verified" is the same false
  # green in a longer-lived process. Unset renders as "NOT CHECKED", by design.
  BROKER_GATE_SIG_STATE=""
  gtype=$(db "SELECT COALESCE(need_type,'')          FROM tasks WHERE id=${id};")
  gansweredat=$(db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")
  ganswer=$(db "SELECT COALESCE(need_answer,'')       FROM tasks WHERE id=${id};")
  gby=$(db "SELECT COALESCE(need_answered_by,'')      FROM tasks WHERE id=${id};")
  guid=$(db "SELECT COALESCE(need_answered_uid,'')    FROM tasks WHERE id=${id};")
  gsig=$(db "SELECT COALESCE(need_answer_sig,'')      FROM tasks WHERE id=${id};")
  reviewer=$(db "SELECT COALESCE(routed_reviewer,'')  FROM tasks WHERE id=${id};")
  if [[ -z "$gtype" ]]; then
    fail "$E_VALIDATION" "no gate on ${ident}: file a ${noun}-for-review gate first (5dive task need ${ident} --type=approval --ask='${ask}') — a ${noun}-for-review ask files as a lead-routed tier-1 gate the org lead can clear (not a human-only tier-2 in the human's DM), and ${noun} runs once a human OR that lead clears it."
  fi
  if [[ -z "$gansweredat" ]]; then
    fail "$E_VALIDATION" "gate on ${ident} is OPEN (unanswered ${gtype}) — ${noun} refused until it clears (5dive task answer ${ident} ...)."
  fi
  # DIVE-2614: the verdict word is read off the FIRST NON-BLANK LINE, as a
  # whole word (`\b`). Either half of the old check alone still misreads real
  # approvals — `grep -qiE` with no `-z`/`^` scope is line-based, so a verdict
  # word on ANY later line of a multi-line answer tripped it (an approval whose
  # line 3 says "BLOCKING NOTHING, BUT FIX BEFORE MERGE" inverted); and with no
  # word boundary the five stems are prefixes, so "Note:", "Nothing", "None",
  # "Not", "non-agent", "Blocking", "Rejecting" all matched too. Both fixes are
  # required together: line-scoping alone still prefix-matches a first line
  # that opens with "Nothing to fix.", and a word boundary alone still reads a
  # later "Blocking issues: none" as the verdict.
  # NOT `head -n1`: "the first line" and "line 1" diverge the moment line 1 is
  # blank/whitespace-only (main, 2026-08-04) — `head -n1` on
  # $'\nNo — rejected' reads as '', which cleared the gate on a genuine
  # rejection. `grep -m1 -v` skips blank lines to find the first one that
  # actually has content.
  # Guarded: under `set -euo pipefail`, an all-blank $ganswer makes grep exit
  # 1 (no non-blank line found) and pipefail promotes that to the whole
  # substitution, which would kill this function. An empty gverdict correctly
  # falls through the reject check below (no verdict word to match).
  local gverdict
  gverdict=$(printf '%s\n' "$ganswer" | grep -m1 -v '^[[:space:]]*$') || gverdict=""
  # Every stem's inflected forms are enumerated explicitly (reject/rejected,
  # deny/denied, block/blocked) rather than matched with an ending like
  # `(reject|deny|block)(ed|ing)?\b` — `\b` alone doesn't extend a bare stem
  # to its inflections ("block" has no boundary inside "blocked"), and a
  # collapsed `(ed|ing)?` re-admits "Blocking issues: none" and "Rejecting
  # the null hypothesis" as false positives (main, DIVE-2614 review). Any new
  # stem added here needs its own inflected forms added too, deliberately —
  # this list is maintained by hand, not enforced by the pattern.
  if printf '%s' "$gverdict" | grep -qiE '^\s*(no|reject|rejected|deny|denied|block|blocked)\b'; then
    audit_log "${surface} gate" error "$E_VALIDATION" -- "ident=${ident}" "line=${gverdict}"
    fail "$E_VALIDATION" "gate on ${ident} was REJECTED ('${ganswer}') — ${noun} refused."
  fi
  [[ "$gby" == human:* ]] && authorized=1
  # DIVE-1555: accept ANY lead-clear provenance (`lead:*`), not only one whose
  # routed_reviewer STILL equals the clearer. `lead:X` is stamped ONLY by the
  # sanctioned lead-clear path in `task answer` (cmd_task.sh), which fires only
  # when the caller was `agent-X` AND X was the gate's routed_reviewer at clear
  # time — so the value after `lead:` IS the designated reviewer who cleared it.
  # DIVE-2099 adds a SECOND minting path under the same `lead:` prefix:
  # `lead:standing:X` records the org lead clearing an ENGINEERING approval under
  # their standing authority, with no routing involved (so `reviewer` is legitimately
  # empty there). It is authorized by the generic `lead:*` arm below on purpose —
  # push-for-review on our own repos is in-scope item #1 of that grant — and it is
  # equally signature-bound, since `need_answered_by` is inside the signed closure.
  # Read `lead:standing:X` as "the org lead X, standing authority"; `lead:X` stays
  # "the designated reviewer X".
  # Requiring routed_reviewer to still match at act time was the bug: routing
  # can be mutated after the clear (a re-route, or the DIVE-1437 T2-escalation
  # NULLs routed_reviewer), stranding a correctly lead-cleared action with an empty
  # `reviewer` and a valid `lead:X` provenance. This is not a weakening: the root
  # executor passes require_sig=1, and `need_answered_by` is part of the signed
  # closure (see _gate_closure_verify), so a raw DB edit forging `lead:X` fails the
  # signature check. (The exact-match line is kept as belt-and-braces.)
  [[ "$gby" == lead:* ]] && authorized=1
  [[ -n "$reviewer" && "$gby" == "lead:${reviewer}" ]] && authorized=1
  # DIVE-2004: a `decision` gate cleared by its own designated reviewer could never
  # authorize an action, because `lead:` is minted ONLY for approval|manual|access —
  # so the refusal accused the reviewer who had in fact cleared it. The predicate
  # we actually need is "was this authorized by the party it was routed to";
  # the stamp is one way to prove that, not the only one. The claim `gby ==
  # reviewer` is NOT sufficient on its own (`task answer --from=<reviewer>` writes
  # it verbatim), so it must be corroborated by the stored `need_answered_uid`,
  # which DIVE-756 stamps from the real pre-sudo invoker and no flag can set.
  local uid_agent=""
  if (( ! authorized )) && [[ "$gtype" == "decision" && -n "$reviewer" && "$gby" == "$reviewer" ]]; then
    uid_agent=$(_gate_agent_for_uid "$guid")
    [[ -n "$uid_agent" && "$uid_agent" == "$reviewer" ]] && authorized=1
  fi
  if (( ! authorized )); then
    # Name the stamp REQUIRED and the one FOUND. A refusal that says "unauthorized
    # provenance" while the designated reviewer is exactly who cleared it sends the
    # reader off to audit the reviewer instead of the gate type (DIVE-1970/2000).
    local detail=""
    if [[ "$gtype" == "decision" && -n "$reviewer" && "$gby" == "$reviewer" ]]; then
      detail=" — '${gby}' IS this gate's routed reviewer, but the recorded invoker uid ${guid:-<none>} maps to '${uid_agent:-no agent}', so the answer cannot be attributed to them. If that is unexpected, the answer was recorded with a --from that did not match who ran it."
    elif [[ -n "$reviewer" ]]; then
      detail=" — required 'human:*', 'lead:${reviewer}', or a decision answered by '${reviewer}' with a matching invoker uid; found '${gby:-unknown}'. A ${gtype:-gate} answered by the lead is only stamped 'lead:' for approval/manual/access."
    else
      detail=" — required 'human:*' or 'lead:*'; found '${gby:-unknown}', and this gate has no routed reviewer to attribute a decision answer to."
    fi
    fail "$E_VALIDATION" "gate on ${ident} was not cleared by an authority delegated ${noun} accepts${detail}"
  fi
  # DIVE-2801: THREE closure states, not two, and the preflight can tell them apart.
  #
  # The agent-side preflight cannot VERIFY the root-HMAC closure — it has no root
  # key, and that is the design, not a gap. But it can read whether a signature
  # EXISTS, and an absent one is NOT "unverified": `_gate_closure_verify` returns 1
  # on an empty sig before it computes anything, so an unsigned closure is a refusal
  # the root executor is CERTAIN to make. The preflight therefore has exactly enough
  # information to predict the real run on this axis, and reporting "gate cleared" on
  # it was a green the privileged write does not honour — DIVE-2798 measured it:
  # `push --dry-run` printed OK and the real push refused the same row seconds later
  # with nothing changed between them.
  #
  # So the state is published for callers to RENDER (a dry-run must say what it did
  # NOT check), and the one state we can decide unprivileged is decided here:
  #   absent     — no signature at all; the executor will refuse -> refuse now
  #   unverified — a signature is present and this caller could not check it
  #   verified   — checked against the root HMAC and it holds (require_sig=1 only)
  # Refusing on `absent` in the preflight is not a new policy: it is the executor's
  # existing policy, applied where it can still be applied honestly. Every other gate
  # defect (open, rejected, unauthorized) already hard-fails the preflight; not
  # failing on this one was the inconsistency that made the rehearsal lie.
  # The EXECUTOR arm is unchanged, deliberately, down to the byte: it covers both
  # unsigned AND tampered, its message is the one DIVE-2798 measured, and a preflight
  # that preempted it would move the authoritative refusal to a less privileged
  # reader. The new arm below is the `elif` — it fires only where require_sig=0.
  BROKER_GATE_SIG_STATE="unverified"
  if [[ "$require_sig" == "1" ]]; then
    if ! _gate_closure_verify "$id" "$gtype" "$ganswer" "$gby" "$gansweredat" "$guid" "$gsig"; then
      fail "$E_VALIDATION" "gate on ${ident} has no valid signed closure — delegated ${noun} refused (the authoritative gate record may be unsigned or tampered)."
    fi
    BROKER_GATE_SIG_STATE="verified"
  elif [[ -z "$gsig" ]]; then
    BROKER_GATE_SIG_STATE="absent"
    fail "$E_VALIDATION" "gate on ${ident} carries NO closure signature — the root-only executor verifies the root-HMAC closure before any delegated ${noun} and refuses an unsigned one, so this preflight refuses HERE rather than report a rehearsal success the real ${noun} will not honour (DIVE-2801). Re-answer the gate (5dive task answer ${ident} ...) on a box that can sign; 'task answer' warns when a closure mints unsigned (DIVE-2760)."
  fi
}

# broker_gate_sig_note — the one sentence a REHEARSAL owes its reader about the
# closure check (DIVE-2801). Reads BROKER_GATE_SIG_STATE, which broker_gate_check
# sets on every call. Empty state means no gate check ran in this process, and that
# is reported as such: a dry-run that stayed silent because it never measured is the
# same false green in a different costume.
broker_gate_sig_note() {
  case "${BROKER_GATE_SIG_STATE:-}" in
    verified)   printf 'closure signature VERIFIED against the root HMAC' ;;
    unverified) printf 'closure signature present but NOT verified here — the root executor verifies it at %s time' "$(broker_surface "${1:-push}" noun)" ;;
    absent)     printf 'closure signature ABSENT' ;;
    *)          printf 'closure signature NOT CHECKED — no gate check ran in this process' ;;
  esac
}

# broker_strip_md_quotes <value> — DIVE-3081. Drop the markdown/quote wrapper a
# human reflexively puts around a value that lives in a PROSE body.
#
# The `<Key>: <value>` line is simultaneously human prose (it renders as markdown
# on the dashboard) and a machine binding (it is the value a cleared gate binds
# to). A maker note that opens "Branch: `my-branch` — head `abc123`, PR #521" is
# the natural way to write the first and an unsatisfiable value for the second:
# `\S+` keeps the backticks, and no git ref can ever equal `` `my-branch` ``. The
# gate is answered, the push refuses with DIVE-1462's ANTI-SUBSTITUTION error, and
# the two names it quotes differ only by two invisible characters — so the error
# reads as "the binding is stale, re-file the gate" and spends a second human tap
# for zero semantic change. See
# community/wiki/a-markdown-quoted-value-cannot-satisfy-a-machine-read-binding.md
#
# Symmetric by construction: the ONLY safe fix is one both readers of the line
# apply, because the refusal compares two independently-parsed values. Stripping
# in one parser and not the other converts an unsatisfiable binding into a
# DIFFERENT unsatisfiable binding. Hence one function, called by both
# broker_task_target (the authoritative bound value) and _push_branch_from_body
# (the value push derives to act on). Do not inline this.
#
# Strips only PAIRED wrappers, and only ones no legal git ref name can contain
# anyway (backtick, single/double quote, <>, and a trailing markdown comma/period
# is NOT stripped — a ref may legally end in a period-free token and we refuse to
# guess where prose ends). An unpaired leading backtick is left alone: that is a
# malformed line, and a value we silently half-repaired is worse than a refusal.
broker_strip_md_quotes() {
  local v="$1"
  case "$v" in
    '`'*'`')  v="${v#\`}"; v="${v%\`}" ;;
    '"'*'"')  v="${v#\"}"; v="${v%\"}" ;;
    "'"*"'")  v="${v#\'}"; v="${v%\'}" ;;
    '<'*'>')  v="${v#<}";  v="${v%>}"  ;;
  esac
  printf '%s' "$v"
}

# broker_task_target <surface> <id> — the target a task AUTHORITATIVELY declares
# via a "<Key>: <value>" line in its body. Empty if the task names none. This is
# the server-side value a cleared gate binds to, read fresh from the DB.
broker_task_target() {
  local surface="$1" id="$2"
  local key; key=$(broker_surface "$surface" key)
  local body; body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
  local raw
  # `|| true` so a no-match grep can't trip `set -euo pipefail` when this runs
  # inside a command substitution.
  raw=$(printf '%s\n' "$body" | grep -ioP "^\s*${key}:\s*\K\S+" | head -1 || true)
  broker_strip_md_quotes "$raw"
}

# broker_bind_target <surface> <id> <ident> <value> — DIVE-1462 (STEER-4),
# generalized. Bind the cleared gate to a SPECIFIC target. A cleared gate
# authorizes acting on exactly the task it sits on, and that task declares its
# target (a "<Key>: <value>" line in its body). Without this, a granted agent
# could cite ANY cleared-gate task's ident but act on an arbitrary target — the
# gate would clear while something unrelated shipped. So the target actually
# being acted on MUST equal the target the task itself declares; anything else
# is refused. Called by BOTH the friendly pre-flight AND the root-only executor,
# the same belt-and-braces posture as broker_gate_check.
broker_bind_target() {
  local surface="$1" id="$2" ident="$3" value="$4"
  local noun;   noun=$(broker_surface "$surface" noun)
  local Noun;   Noun=$(broker_surface "$surface" Noun)
  local key;    key=$(broker_surface "$surface" key)
  local target; target=$(broker_surface "$surface" target)
  local ticket; ticket=$(broker_surface "$surface" ticket)
  local task_value; task_value=$(broker_task_target "$surface" "$id")
  if [[ -z "$task_value" ]]; then
    fail "$E_VALIDATION" "task ${ident} declares no ${target} — add a '${key}: <name>' line to its body so the cleared gate binds to a specific ${target} (delegated ${noun} refuses an unbound ${target})."
  fi
  if [[ "$value" != "$task_value" ]]; then
    # DIVE-3081: this refusal is DIVE-1462's anti-substitution guard, so its plain
    # reading is "someone is acting on the wrong ${target}" and the natural repair
    # is to re-file the gate — a second human tap. But when the two values differ
    # only in characters that do not survive a glance (a leftover markdown wrapper,
    # a stray quote, a trailing CR from a pasted body), the binding is not stale and
    # re-filing changes nothing. Say so INSIDE the refusal: the reader is looking at
    # two strings they have already decided are identical, and asking them to diff
    # bytes only works if something tells them to. Cheap comparison, and it fires
    # only on the look-alike case — a genuinely different ${target} gets the plain
    # message, unchanged.
    local hint="" a b fixcmd
    a=$(printf '%s' "$value"      | tr -d '`'"'"'"<>[](),. \r\t')
    b=$(printf '%s' "$task_value" | tr -d '`'"'"'"<>[](),. \r\t')
    if [[ -n "$a" && "$a" == "$b" ]]; then
      hint=" NOTE: these two differ only in punctuation/whitespace, so the binding is NOT stale and re-filing the gate will not change that — the declared '${key}:' line is malformed."
      fixcmd=$(broker_surface "$surface" fixcmd)
      [[ -n "$fixcmd" ]] && hint+=" Rewrite it with the verb that owns it: ${fixcmd} ${ident} ${a}"
    fi
    fail "$E_VALIDATION" "${target} '${value}' is not the ${target} bound to ${ident}'s cleared gate ('${task_value}') — a cleared gate authorizes only its task's own declared ${target}. ${Noun} refused (${ticket}).${hint}"
  fi
}

# broker_connector_read <path> <what> — B1, the control-plane-only credential.
# Source a root-600 connector env file as root and NOTHING else. Two properties
# it enforces that a bare `. "$f"` does not:
#
#   1. root-only caller. The whole B1 invariant is that the agent process never
#      holds the credential; sourcing it under any other euid defeats that.
#   2. a LOUD warning when the file is group- or world-readable. Several
#      connectors on our own box predate the invariant and are 0644 — which
#      means every account on the host can already read them, and a broker
#      built on top would be recording an authority the filesystem already
#      hands out. Warn rather than refuse: refusing would make the executor
#      unusable on exactly the boxes that need it, and the operator fix
#      (chmod 600) is one command that this message names.
broker_connector_read() {
  local f="$1" what="${2:-connector}"
  [[ "$(id -u)" -eq 0 ]] || fail "$E_PERMISSION" "broker_connector_read is root-only (B1: the agent process must never hold ${what})"
  [[ -r "$f" ]] || fail "$E_GENERIC" "missing ${what} credential: ${f}"
  local mode; mode=$(stat -c '%a' "$f" 2>/dev/null || echo "")
  case "$mode" in
    600|400|"") ;;
    *) warn "connector ${f} is mode ${mode} — group/world readable, so the ${what} credential is NOT control-plane-only (B1 violated). Fix with: sudo chmod 600 ${f}" ;;
  esac
  # shellcheck disable=SC1090
  set -a; . "$f"; set +a
}
