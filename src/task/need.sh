# -------- 5dive task — need --------
#
# Split out of src/cmd_task.sh (DIVE-3278): `task need` — the human gate. Every predicate that decides whether a gate needs
# a human, which seat may clear it, and what tier it floors to; plus the filing
# verb itself and the precedent/routing read-only views.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
# src/cmd_task.sh when the split tree is used (tests source src/cmd_task.sh).
# Function definitions only — never execute this file directly.
# --- Human Task Inbox (DIVE-103; parent feature DIVE-102) ----------------
# `need` parks a task on a human; `inbox` lists what's waiting; `answer`
# records the human's reply, unblocks, and pings the agent that hit the gate.

# OSS-21: precedent auto-clear policy switch. `5dive task precedent [on|off]`
# (bare / `status` reports state). When ON, a resolved tier-1 gate that matches
# proven human precedent clears itself at file-time (see cmd_task_need). Default
# is OFF fleet-wide until the OSS-16 policy owner (lodar) flips it. Read-only
# `status` needs no privilege; on/off is a policy write.
cmd_task_precedent() {
  tasks_db_init
  local sub="${1:-status}"
  case "$sub" in
    status|"")
      local v; v=$(_task_pref_get precedent_autoclear); v="${v:-off}"
      ok "precedent auto-clear: ${v}" \
         '{pref:"precedent_autoclear", value:$v}' --arg v "$v"
      ;;
    on|enable)
      _task_pref_set precedent_autoclear on
      # DIVE-2054: a fleet-wide pref toggle keyed off the active store — fenced.
      _task_store_audit_log "task precedent" "on" 0 -- "pref=precedent_autoclear" || true
      ok "precedent auto-clear: ON — resolved tier-1 gates with proven human precedent now clear at file-time" \
         '{pref:"precedent_autoclear", value:"on"}'
      ;;
    off|disable)
      _task_pref_set precedent_autoclear off
      # DIVE-2054: same as the "on" branch above — fenced.
      _task_store_audit_log "task precedent" "off" 0 -- "pref=precedent_autoclear" || true
      ok "precedent auto-clear: OFF — tier-1 gates always surface to a human" \
         '{pref:"precedent_autoclear", value:"off"}'
      ;;
    *)
      fail "$E_USAGE" "usage: 5dive task precedent [on|off|status]"
      ;;
  esac
}

# DIVE-1145: ship-gating routing policy switch. `5dive task routing [on|off]`
# (bare / `status` reports state). When ON, a NON-lead agent's decision gate
# (tier < 2) routes to the org lead first (see cmd_task_need) instead of pinging
# the human. Default is OFF fleet-wide until the org lead (main) flips it after
# reviewing the diff. True-human categories (tier-2-floored decisions, and every
# approval/manual/secret gate) are never routed. Read-only `status` needs no
# privilege; on/off is a policy write. Mirrors `task precedent` (OSS-21).
cmd_task_routing() {
  tasks_db_init
  local sub="${1:-status}"
  case "$sub" in
    status|"")
      local v; v=$(_task_pref_get gate_builder_routing); v="${v:-off}"
      ok "builder-gate routing: ${v}" \
         '{pref:"gate_builder_routing", value:$v}' --arg v "$v"
      ;;
    on|enable)
      _task_pref_set gate_builder_routing on
      # DIVE-2054: same reasoning as "task precedent" above — fenced.
      _task_store_audit_log "task routing" "on" 0 -- "pref=gate_builder_routing" || true
      ok "builder-gate routing: ON — a non-lead agent's tier<2 decision gate now routes to the org lead before pinging the human" \
         '{pref:"gate_builder_routing", value:"on"}'
      ;;
    off|disable)
      _task_pref_set gate_builder_routing off
      # DIVE-2054: same reasoning as "task routing on" above — fenced.
      _task_store_audit_log "task routing" "off" 0 -- "pref=gate_builder_routing" || true
      ok "builder-gate routing: OFF — decision gates ping the human directly" \
         '{pref:"gate_builder_routing", value:"off"}'
      ;;
    *)
      fail "$E_USAGE" "usage: 5dive task routing [on|off|status]"
      ;;
  esac
}

# DIVE-891/CNCL-14: the T2 category floor. The shipped defaults make money,
# public/customer comms, secrets, and destructive/irreversible actions a hard
# human gate; a valid company constitution replaces those classes as data.
# A matched class is ALWAYS a hard human gate, regardless of the tier the
# filing agent asked for — the floor is enforced here, not trusted from the
# filer. Matched case-insensitively over ask + title. The bias is deliberately
# toward false positives: a wrongly-ELEVATED gate costs the human one tap; a
# wrongly-lowered one would let a spend/publish call auto-apply. Bar-raise,
# same posture as gate-proof (a determined agent can still word around it —
# but only by loudly not-naming what it's asking for, which the ask text then
# fails to justify).
# DIVE-2241: the HUMAN-CLASS capability constants. A gate may DECLARE the
# capability its ask consumes with `--needs=<capability>`; exactly three names
# resolve to the paired human, and they resolve as CONSTANTS, not as a lookup.
#
# Why a constant and not the DIVE-2102 capability registry this was originally
# sequenced behind: that registry is a SUDOERS MIRROR — its vocabulary is five
# command grants and its holder key is `holder_agent`. lodar has no agent account
# and no sudoers entry, so these three are not "undeclared, pending declaration",
# they are INEXPRESSIBLE in that schema and always will be. A registry derived
# from a permission system answers "who may RUN this", never "who may DECIDE
# this". See community/wiki/an-oracle-that-mirrors-sudoers-answers-permission-\
# not-authority.md.
#
# Why a shipped shell constant is the DIVE-2099 anchor and a routing table is not:
# agents here hold NOPASSWD:ALL, so any table an agent can `sudo 5dive ... set` is
# an authority the beneficiary can grant itself — naming itself the holder of
# human_tap is one command. This list is a name sealed into the release artifact:
# changing it means changing the code that ships and passes review, and the
# installed binary's sha256 (5dive.sha256) no longer matches. There is deliberately
# NO write path — not root-guarded, ABSENT — because `require_root` answers "can
# this principal write here", which on this host is always yes (DIVE-2131).
#
#   human_tap        — a person's call: brand, strategy, an irreversible choice.
#   spend_authority  — billing / paid accounts. NOT smoke runs: lodar pre-approved
#                      those 2026-07-27, so a smoke gate declares nothing here.
#   secret_provision — a new token / credential must come FROM a human.
#
# Anything else — including a typo, and including a real agent capability like
# delegated_push — is UNRECOGNISED and falls through to today's routing untouched
# (see _gate_needs_human below). Absence means UNDECLARED, never non-holding.
_GATE_HUMAN_CAPABILITIES='human_tap spend_authority secret_provision'
# True iff $1 is one of the human-class constants. Whitespace-fenced substring
# match so no capability can hit by prefix (`human_tap_delegate` must NOT match).
#
# NORMALISE FIRST (Marcus, pre-merge read on #288). Exact matching makes a TYPO
# SILENTLY WEAKER: `--needs=human-tap` / `HUMAN_TAP` fell through to a tier-1,
# agent-clearable, TTL-auto-appliable gate while the filer believed they had just
# secured a human. The fall-through is loud — but the warn goes to whoever ran the
# command, and the common caller is an agent filing programmatically in a headless
# session: the reader least likely to see it and most likely to believe the
# declaration held.
#
# Why NORMALISE and not REFUSE-on-unknown, which was the other way to close it: an
# unknown name must keep falling through, because gh_push / root / delegated_push
# are deliberately unroutable here pending DIVE-2156, and hard-failing them would
# break a newer capability on an older CLI. Normalising kills the whole near-miss
# class (case + separator, the only two ways to write these names wrong) while
# leaving forward-compat intact. Deliberately NOT edit distance: a resolver that
# guesses what you meant is a new thing to be wrong about, and this one decides
# whether a human is required.
_gate_needs_human() {
  local c="${1:-}"
  [[ -n "$c" ]] || return 1
  c=$(printf '%s' "$c" | tr '[:upper:]-' '[:lower:]_')
  [[ " $_GATE_HUMAN_CAPABILITIES " == *" $c "* ]]
}

# DIVE-2629: THE FLOOR MUST READ THE ACTION, NOT THE SUBJECT MATTER OF THE CODE.
#
# THE DEFECT, measured by main 2026-08-03 by running _gate_tier2_floor_hit on four
# ask strings that differ by ONE token:
#
#   'approve delegated push for review of branch dive-2613-teardown-outcomes-...'  -> T2
#   'approve delegated push for review of branch dive-2613-outcomes-hetzner-only'  -> T1
#   'approve delegated push for review of branch dive-XXXX-teardown-foo'           -> T2
#   'approve delegated push for review of branch dive-2592-budget-variance'        -> T1
#
# The word 'teardown' appearing ONLY inside a git branch NAME forces tier 2. The
# floor exists to catch DESTRUCTIVE ACTIONS; the action here is "push a feature
# branch to a remote for review" — inert by construction, no merge, no prod touch,
# reversible. What is destructive-sounding is the SUBJECT of the code on the
# branch. The floor was reading what the work is ABOUT and grading it as what the
# gate DOES, so the better a branch name describes the work the likelier it floors:
# the naming convention we WANT is the one that trips it.
#
# WHY THAT IS A RATCHET AND NOT ONE EXTRA TAP. A tier-2 approval is filed with NO
# routed_reviewer, and cmd_task_answer's designated-reviewer exception requires
# actor == routed_reviewer. So NO agent can ever clear it — not the filer, not
# their lead, not the org coordinator — and no agent action hands it back. It is
# permanently the human's. DIVE-2613 is one of the six eng gates lodar objected to
# on 2026-08-03 ("can you stop pinging me for dev stuff") and dev2 stayed blocked
# behind it. The floor's usual "a false positive costs one tap" bias does not hold
# on this path, because there is no tap that gives it back.
#
# THE FIX SCOPES THE MATCH, NOT THE VERDICT (main's shape, adopted). Exempting the
# individual words would be the tempting non-fix — it keeps the wrong question and
# tidies the answer, the same way stripping +suffix was the non-fix on DIVE-2594.
# Instead: when — and only when — the text is recognised as an INERT
# push-for-review, the git branch IDENTIFIER is removed before the floor reads it.
# A branch name is a label, never a statement of the action a gate authorises.
# Everything else in the ask is still read, unchanged: a push ask that ALSO names a
# spend, a secret or a publish still floors, because those words are in the prose.
#
# THREE NARROWINGS, all deliberate, all biased toward KEEPING the floor:
#
#   1. NOT the whole eng-ship class. _gate_eng_ship_hit also covers merge, deploy,
#      roll-to-fleet and push-to-main — those TOUCH PROD and are not inert, so they
#      must keep flooring on their subject matter. _GATE_PUSH_NOT_INERT_RX kicks
#      the text back out of this exemption the moment it names one of them, which
#      is why "push branch X for review, then merge to main" is unchanged.
#   2. Only BRANCH-SHAPED tokens are redacted, not every hyphenated word. A slug
#      qualifies on a slash (feat/x), a ticket prefix (dive-2613-...), or two or
#      more hyphens (a-b-c). So 'auto-teardown' in prose survives and still floors:
#      one hyphen and no ticket prefix is a WORD, and when the shape is ambiguous
#      the floor stays on.
#   3. Applied HERE, at the single match site, so every consumer — cmd_task_need's
#      filing floor, the approval/manual routing arm, and cmd_goal's low-risk
#      check — inherits the same verdict from the same inputs, which is the
#      property _gate_floor_axis exists to preserve.
#
# NOT ATTEMPTED, and it is a separate ticket: DIVE-2592 routed to olivia when its
# filer dev reports_to main. That is _gate_route_reviewer, not the floor, and main
# explicitly did not diagnose it — do not fold it in here.
_GATE_PUSH_FOR_REVIEW_RX='delegated push|push[- ]for[- ]review|5dive push|push[^.]*(for review|for a pr|for code review|branch)'
# The DESTINATION clause is `\bto\b … (main|master|prod)`, NOT `push to (main|…)`.
# Found by the pre-land corpus sweep, and it is the one arm the fix got wrong on
# first writing: DIVE-1940's real ask is "Push branch dive-1940-token-ux @ 3d9851a0
# to 5dive-frontend MAIN". The adjacent form `push to main` cannot see a repo name
# sitting between the verb and its destination, so a push to a repo's default
# branch was inheriting the inert-push exemption. It floored before this change
# only by accident — on the word 'token' inside the branch name — so the sweep is
# what caught it, not the defect it was sweeping for. Bounded distance is safe here
# in a way DIVE-2224 forbids across a seam: this matches inside ONE field.
_GATE_PUSH_NOT_INERT_RX='\bmerg(e|es|ed|ing)\b|deploy|redeploy|\brelease\b|roll ?out|\broll(ing|ed)? out\b|roll[^.]*fleet|fleet[- ]?roll|\bto\b[^.]{0,60}\b(main|master|prod|production|trunk)\b|\bland (the|it|this)\b'

# 0 iff the text describes an INERT push-for-review: a feature branch going to a
# remote for PR review. Fails closed — anything that also names a prod-touching
# verb is NOT inert and gets no exemption.
_gate_push_for_review_hit() {
  local text; text=$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')
  [[ "$text" =~ $_GATE_PUSH_FOR_REVIEW_RX ]] || return 1
  [[ "$text" =~ $_GATE_PUSH_NOT_INERT_RX ]] && return 1
  return 0
}

# 0 iff $1 (already lowercased, punctuation trimmed) has the shape of a git ref.
# Three qualifying shapes; a single-hyphen word with no ticket prefix does NOT
# qualify, because that is how English compounds are written.
_gate_branch_slug_token() {
  local w="${1-}" hy
  [[ "$w" =~ ^[a-z0-9._/-]+$ ]] || return 1
  [[ "$w" == */* ]] && return 0
  [[ "$w" =~ ^[a-z]+-[0-9]+(-|$) ]] && return 0
  hy=${w//[^-]/}
  (( ${#hy} >= 2 )) && return 0
  return 1
}

# Drop branch-identifier tokens from $1. Globbing is disabled around the split so
# a ref containing * or ? cannot expand against the cwd.
_gate_redact_branch_refs() {
  local out="" w core noglob=0
  [[ $- == *f* ]] || { noglob=1; set -f; }
  for w in ${1-}; do
    core="$w"
    [[ "$w" =~ ^[^a-z0-9]*([a-z0-9._/-]+)[^a-z0-9]*$ ]] && core="${BASH_REMATCH[1]}"
    _gate_branch_slug_token "$core" && continue
    out+="$w "
  done
  (( noglob )) && set +f
  printf '%s' "$out"
}

_GATE_T2_FLOOR_RX='spend|billing|invoice|charge|payment|refund|subscription|price|pricing|\$[0-9]|€[0-9]|publish|public post|announce|launch post|press|customer email|email customers|newsletter|blast|secret|credential|api key|token|password|delete|destroy|teardown|wipe|purge|drop[^.]{0,20}table|truncate|irreversible|revoke|dns|domain transfer'
_gate_tier2_floor_hit() {
  local text floor_rx="$_GATE_T2_FLOOR_RX" loaded_rx="" constitution_path="" ere_rc=0
  text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  # CNCL-14: production bundles include the council loader later in the file;
  # isolated task tests that source cmd_task alone retain the byte-identical
  # legacy regex. The overwhelmingly common no-file path must stay in-process:
  # do not start Node or materialize the embedded council runtime merely to
  # rediscover the same default. A present-but-malformed file still goes through
  # the loader and atomically resolves to the legacy regex.
  if declare -F _council_hard_gate_rx >/dev/null 2>&1 \
     && declare -F _council_constitution_path >/dev/null 2>&1; then
    constitution_path="$(_council_constitution_path 2>/dev/null || true)"
    if [[ -n "$constitution_path" && -f "$constitution_path" ]]; then
      # DIVE-1695: the on-disk constitution is trusted for the human-gate floor
      # ONLY when it matches the digest SEALED into the council lineage. The
      # sealed chain is the authority, not the forgeable file. A drifted/tampered
      # constitution.yaml — e.g. an unsanctioned edit that DELETES a hard class to
      # weaken the floor — must never be enforced: fail closed to the shipped
      # defaults, the exact verdict `council verify`/`convene` reach on drift.
      # No seal in the lineage yet (pre-constitution org) leaves CNCL-14 behavior
      # unchanged: the present file is loaded as before.
      if declare -F _council_constitution_drifted >/dev/null 2>&1 \
         && _council_constitution_drifted; then
        warn "constitution.yaml drifted from the sealed digest; enforcing the shipped tier-2 floor, not the on-disk file (amend via a constitutional-class council motion) (${constitution_path})"
      else
        loaded_rx="$(_council_hard_gate_rx 2>/dev/null || true)"
        if [[ -n "$loaded_rx" ]]; then
          floor_rx="$loaded_rx"
          # CNCL-28: engine.mjs can reject known JS-only syntax, but Bash is the
          # consumer and therefore the authority on POSIX ERE validity. Bash =~
          # returns 2 for an invalid expression; treat that as a whole-policy
          # failure so one bad class can never silently disable the T2 floor.
          [[ x =~ $floor_rx ]] || ere_rc=$?
          if (( ere_rc == 2 )); then
            warn "constitution hard_gates regex is invalid POSIX ERE; falling back to the shipped tier-2 floor (${constitution_path})"
            floor_rx="$_GATE_T2_FLOOR_RX"
          fi
        fi
      fi
    fi
  fi
  # DIVE-2301: the floor terms are a bare alternation with no boundary, so every
  # one of them is a SUBSTRING matcher: 'press' fires on suppression/expression/
  # compressed/depression, 'charge' on recharge/supercharge. Both live on the
  # NON-APPEALABLE list, so an ask that legitimately says "stop forging a
  # suppression" floored to tier 2 with no appeal path, on a word that has nothing
  # to do with press or money.
  #
  # The boundary is applied HERE, at the match site, and not by writing \b onto
  # each term in $_GATE_T2_FLOOR_RX. Two reasons, both measured:
  #
  #   1. $floor_rx is POLICY DATA and may have been replaced wholesale by a sealed
  #      constitution.yaml a few lines up. Anchoring the shipped default would
  #      leave the defect live in exactly the path where the policy is
  #      authoritative, and an org's own terms would still be substring matchers.
  #   2. \b CANNOT anchor the money terms. \b asserts a word/non-word transition,
  #      and '$' is not a word character, so `\b\$[0-9]` never matches: with a
  #      per-term \b, "approve $500 for ads" and "wire €900 to the vendor" stop
  #      flooring ALTOGETHER. That trades a false positive for a false NEGATIVE on
  #      the one class with no escape path. `(^|[^[:alnum:]_])` is a leading
  #      boundary that a non-word term can also sit behind, and it keeps both.
  #
  # LEADING only, deliberately: the terms are unanchored at the tail so inflections
  # keep matching (revoked, truncated, charges, pressing). Containment inside an
  # unrelated STEM is the defect; containment at the start of a longer word
  # (pressure, deleterious) still fires and is the accepted cost of that choice.
  #
  # DIVE-2629: an inert push-for-review ask NAMES A GIT BRANCH, and the branch name
  # is the subject of the work, not the action being authorised. Redact refs before
  # matching so the floor grades what the gate DOES. Scoped, not exempted — the
  # rest of the ask is read exactly as before. Full rationale at the RX above.
  if _gate_push_for_review_hit "$text"; then
    text=$(_gate_redact_branch_refs "$text")
  fi
  [[ "$text" =~ (^|[^[:alnum:]_])($floor_rx) ]]
}

# DIVE-2224: NEVER concatenate two SUBJECTS into one classifier input. The ASK is
# what is being asked for, written at gate-filing time; the TITLE is what the
# ticket is about, written at ticket-creation time. They are different statements,
# and joining them with a space lets any BOUNDED-DISTANCE pattern match ACROSS the
# seam and fabricate a classification present in NEITHER field.
#
# Measured on origin/main with the shipped floor: ask "confirm we can drop" MISSES,
# title "table stakes: the onboarding rewrite" MISSES, the join HITS -- on
# `drop[^.]{0,20}table`, a database-deletion guard, between two texts about neither.
# Second instance of the shape after DIVE-1481's 20-char co-reference window, so it
# is a property of the JOIN and not of one regex; every classifier that reads both
# fields has it.
#
# Evaluating each field SEPARATELY preserves "either field can trip it" -- the
# DIVE-1957 title axis, which is load-bearing in both directions -- and removes only
# the phantoms. It cannot suppress a real single-field match, so it is strictly
# safer than the join for an UPGRADE classifier (the floor) and for a DOWNGRADE one
# (eng-ship / curation / internal-ops), where a fabricated hit is the dangerous
# direction because it REMOVES a human.
_gate_hit_either() {   # <predicate-fn> <ask> <title>
  local _fn="$1"; "$_fn" "${2-}" || "$_fn" "${3-}"
}

# DIVE-2224 PART 2 — lodar answered A on 2026-07-28. The floor's SUBJECT is the ASK.
#
# WHY. A title cannot be a REQUEST. It is written at ticket-creation time to describe
# a DEFECT; the ask is written at gate-filing time to describe what is being asked
# for. Flooring on the title treats a description as a request, and the filer cannot
# reword their way out of it -- DIVE-2216 could not file a push gate AT ALL, because
# 'deleted' sits in its own title. Measured over the 177 filed gates carrying an ask:
# 40 match on the ask (unchanged), 15 match TITLE-ONLY (move to the lead), 122 match
# neither -- so this moves ~27% of human gates to the lead, and understates it,
# because gates that could never be filed never entered the count.
#
# THE FALLBACK IS LOAD-BEARING, NOT A FOOTNOTE (olivia's condition, adopted). A
# works only while the ask is a TRUTHFUL statement of the request. The failure case
# is a lazy filing -- ask "approve this", title "delete all customer data" -- where
# the title genuinely IS the only statement of the request. An ask that names nothing
# is a badly-filed gate, and the floor FAILS CLOSED on it rather than trusting the
# filer. Bias is deliberately toward NOT-substantive: a wrongly-floored gate costs
# one tap, a wrongly-unfloored one lets a destructive ask reach an agent.
_GATE_ASK_FILLER_RX='approve|approved|approval|please|confirm|confirmation|ok|okay|yes|no|this|that|these|those|it|its|the|a|an|and|or|to|for|of|on|in|is|are|be|go|ahead|proceed|sign|off|signoff|thanks|thank|you|we|i|can|could|would|should|do|does|did|need|needs|needed|want|review|now|asap|me|my|our|us|us|pls|plz'
_gate_ask_substantive() {   # <ask> -> 0 when the ask states something of its own
  local t n
  t=$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g')
  t=$(printf '%s' "$t" | sed -E "s/\b(${_GATE_ASK_FILLER_RX})\b//g")
  n=$(printf '%s' "$t" | wc -w)
  (( n >= 3 ))
}
# _gate_floor_axis <ask> <title> -> echoes WHICH field decided, so every consumer
# (the filing floor and the approval/manual routing arm) makes the SAME call from
# the same inputs instead of each re-deriving it:
#   ask            floor fires -- hard human, unchanged from before DIVE-2224
#   title-fallback floor fires -- title matched and the ask states nothing (olivia's
#                  fail-closed condition)
#   title          floor does NOT fire -- lead-routed, stamped floored_by=title
#   none           floor does not fire
_gate_floor_axis() {
  local a="${1-}" t="${2-}"
  if _gate_tier2_floor_hit "$a"; then printf 'ask'; return 0; fi
  if _gate_tier2_floor_hit "$t"; then
    if _gate_ask_substantive "$a"; then printf 'title'; else printf 'title-fallback'; fi
    return 0
  fi
  printf 'none'
}

# DIVE-1359: the ENG-SHIP gate class. An eng ship / merge / diff / deploy
# approval is NOT a human call — it is the org lead's (Marcus) to clear. But a
# builder can file one as a hard-human gate (default, or explicit --tier=2),
# which (a) pings the paired human and (b) is UNCLEARABLE by the lead, since
# tier-2 is human-only by system rule. Observed twice: dev (DIVE-1349/1314) +
# codex (DIVE-907) escalated eng ship approvals to the human. We classify these
# by kind and force them DOWN to a lead-routed tier-1 — the mirror of the T2
# floor (which forces true-human categories UP to tier-2). The true-human floor
# ALWAYS wins and is checked FIRST: an eng gate that also names money / secrets /
# destructive stays tier-2 (a "ship the pricing change" gate is still a
# human call). Bias, like the floor, is deliberate: a wrongly-classified eng gate
# costs the lead one clear; the floor guards the only genuinely-human direction.
# DIVE-1555: a delegated push-for-review (5dive push / DIVE-1376) is an eng-ship
# action — it pushes a FEATURE branch for PR review (no merge, no prod touch), so
# it must file as a lead-routed tier-1, not a tier-2 human-only approval that
# lands in the human's DM. `push to (main|prod|...)` deliberately does NOT match a
# feature-branch push-for-review, so name it explicitly here.
# DIVE-1698: a VERIFIED builder ship — "push the tested commit to GitHub + roll to
# the fleet" (DIVE-1674 telegram undefined-guard) — is the same eng-ship kind, yet
# it missed the classifier: `push to (main|prod|origin)` excludes "to GitHub", and
# `roll ?out` excludes "roll/rolling to the fleet". Both stayed at the approval
# tier-2 default → the human's DM. Add `push … github` and `roll … fleet` /
# `fleet roll` so a tested-code push+fleet-roll files as a lead-routed tier-1. The
# true-human floor still runs FIRST and wins (a "push the pricing change" gate
# stays human), so these can only ever cost the lead one clear.
# _gate_authenticated_actor, _gate_uid_to_agent, _gate_caller_uid, _gate_is_root,
# _gate_passwd_stream and _gate_agent_for_uid MOVED to src/lib/actor.sh (DIVE-2517,
# v0.18 "Proof of who"). Same names, same semantics, one definition — the strict
# uid-first derivation is now the shared one in lib/ rather than a local helper in
# the file that happened to need it first. Call sites here are unchanged.

_GATE_ENG_SHIP_RX='\bmerg(e|es|ed|ing)\b|pull request|\bpr\b|\bdiff\b|ship it|ship the|ship this|\bship(ping|ped)\b|deploy|redeploy|roll ?out|\broll(ing|ed)? out\b|land the|land it|land this|\bland(ing|ed)\b|rebase|hotfix|cut a branch|cut the release|push(es|ed|ing)? to (main|prod|production|origin)|push[^.]*github|delegated push|push[- ]for[- ]review|push .*(branch|for review|for a? ?pr|for code review)|5dive push|roll[^.]*fleet|fleet[- ]?roll|code review|approve the (merge|diff|change|pr|build|deploy|ship|commit)|build\.sh|smoke test|ci\b'
_gate_eng_ship_hit() {
  local text; text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$text" =~ $_GATE_ENG_SHIP_RX ]]
}

# --- DIVE-2093: say WHO the gate routed to and WHY, at FILE TIME --------------
#
# The routed `ok` line has always named the reviewer and the ROLE ("routed to
# main2 for verifier review"). What it never named is the PROPERTY that picked
# that reviewer, and that omission is the whole defect: three agents in 36 hours
# (dev3 on DIVE-2084, main on DIVE-2146, olivia right behind them; then main2 on
# DIVE-2798 and DIVE-2808) filed a gate asking for an ACTION and had it land on
# the loop's verifier, who could judge the work and could not perform the act.
# Every one of those cost a round trip, and none of them was visible on the
# board — a gate pending on the wrong principal renders exactly like a gate
# pending on the right one.
#
# The filer is the only party who knows what the ask actually needs, and the
# moment of filing is the only moment at which re-filing is free. So the fix is
# to hand them the routing basis right there instead of leaving them to infer it
# from an answer that never comes.
#
# `basis` is the property that chose the target, NOT the trigger that made the
# gate routable at all — those are different questions and the filer needs both.
# `basis` is `tasks.route_provenance` VERBATIM — the same value the row is stamped
# with, threaded from the one place it is computed rather than re-derived here.
# DIVE-2093 iteration 3, and the reason is a defect this function shipped with: it
# used to take a two-valued lead/verifier flag and print the ORG CHART sentence for
# everything that was not `verifier`. DIVE-3171 then added a THIRD route (the sealed
# standing lead, which fires precisely when the chart resolves NOBODY), so the
# catch-all asserted an `agents_org.reports_to` edge that by construction does not
# exist — a routing explanation naming the wrong property, which is this row's own
# defect class emitted by the fix for it.
#
# THE GENERAL RULE, and it is why the last arm reads the way it does: a catch-all in
# an EXPLANATION is not a default, it is an assertion about every case you did not
# enumerate. `*)` is safe when it says "some other reason"; it is a falsehood
# generator when it names a specific mechanism and cites a specific table. A
# diagnostic must degrade to UNKNOWN, never to the most common case — the same
# absent-vs-forbidden reasoning as DIVE-2318.
# community/wiki/a-why-clause-that-enumerates-bases-lies-about-the-one-it-omits.md
#
# _gate_route_why <route_provenance> <reviewer> <filer> <trigger>
_gate_route_why() {
  local basis="$1" reviewer="$2" filer="$3" trigger="$4"
  case "$basis" in
    verifier-loop)
      printf 'why: routed by LOOP MEMBERSHIP — %s is this task'"'"'s verifier of record (tasks.verifier). That property carries NO information about which capabilities %s holds, so if this ask needs an ACTION performed (open a PR, push, spend, provision a secret) rather than a judgement made, it is on the wrong desk: re-file with --tier=2, or --needs=<capability>, or hand it to a holder. trigger=%s' \
        "$reviewer" "$reviewer" "$trigger" ;;
    seal:standing-lead)
      printf 'why: routed by the SEALED STANDING LEAD — the org chart resolved NOBODY above %s (they are its root), so this went to %s under the sealed authority.eng_approval_lead and NOT along an agents_org.reports_to edge, which does not exist here (route_provenance=seal:standing-lead, DIVE-3171/2099). That seal names an ENGINEERING-APPROVAL holder and says nothing else about what %s can do, so an ask needing some other capability is still on the wrong desk. trigger=%s' \
        "${filer:-the filer}" "$reviewer" "$reviewer" "$trigger" ;;
    chart)
      printf 'why: routed by the ORG CHART — %s is the lead %s reports to (agents_org.reports_to). trigger=%s' \
        "$reviewer" "${filer:-the filer}" "$trigger" ;;
    *)
      printf 'why: routed to %s by a basis this build does not name (route_provenance=%s) — so this line cannot tell you WHICH property picked them, and you should not read it as the org chart having resolved anybody. Check the routing source before relying on %s being able to answer. trigger=%s' \
        "$reviewer" "${basis:-<empty>}" "$reviewer" "$trigger" ;;
  esac
}

# Can this seat mint a DIVE-756 closure signature? Echoes `<yes|no|unknown>|<class>`.
#
# The classes come from the same measurement `agent info` renders
# (classify_sudo_grant), and the yes/no split is the one DIVE-2760's own answer-
# time warning already states in prose: root-all and cli-root seats hold sudo for
# `5dive gate-proof sign`; cli-scoped seats do not.
#
# `custom` and `unknown` return UNKNOWN and never `no`. DIVE-2318: an unmeasured
# grant is the absence of a measurement, not evidence of absence, and the cost of
# the two errors is asymmetric here — a false `no` sends the filer to re-route a
# gate that would have cleared fine, on a box where the peer read simply did not
# work (DIVE-2135 makes that read possible, not guaranteed).
_gate_seat_can_sign() {
  local name="$1" grant cls
  [[ -n "$name" ]] || { printf 'unknown|unknown\n'; return 0; }
  grant=$(agent_sudo_grant "agent-${name}" 2>/dev/null) || grant=""
  cls="${grant%%|*}"; [[ -n "$cls" ]] || cls="unknown"
  case "$cls" in
    root-all|cli-root) printf 'yes|%s\n' "$cls" ;;
    cli-scoped|none)   printf 'no|%s\n' "$cls" ;;
    *)                 printf 'unknown|%s\n' "$cls" ;;
  esac
}

# DIVE-2099: the org lead's STANDING authority to clear an ENGINEERING approval
# gate. lodar granted it 2026-07-26 ("agreed") in response to main asking for it
# directly; main filed the ticket rather than implementing it because the
# requester is the beneficiary. The boundary is therefore deliberately narrow and
# the mechanism is deliberately visible in the record.
#
# WHAT IT ADDS: DIVE-1182/1243 already let the lead clear a gate that was ROUTED
# to them at filing time (routed_reviewer == the authenticated caller). That is
# the only lead-clear path today, so an engineering approval that reached the
# human WITHOUT routing — pref off, filer-is-lead, a re-route that NULLed the
# reviewer, or a gate filed before routing existed — is human-only forever, even
# though its entire content is a judgement the lead can make. Three of the 14
# gates in lodar's inbox on 2026-07-26 were exactly that. This predicate is the
# standing authority: no routing required, but every other guard stays.
#
# WHY IT IS NOT "another keyword match" (design note 1 on the ticket, and the
# DIVE-2089 trap): a keyword match here would be a false-NEGATIVE machine — the
# dangerous polarity, where the lead self-clears something that should have gone
# to the human. So vocabulary is never sufficient on its own. Eligibility is a
# CONJUNCTION of an unforgeable identity check, a structural type/tier check, a
# positive engineering classification, AND two independent exclusion tests. Text
# can only ever REMOVE authority here; the guards that GRANT it are structural.
#
# FAIL CLOSED (design note 2): every unknown answers "no". An empty ask, an empty
# or legacy-NULL tier, an unresolvable org lead, an unauthenticated caller, or a
# text that does not positively classify as engineering all deny. An
# unclassifiable gate is a human gate.
_GATE_LEAD_STANDING_DENY_RX='customer.{0,20}(box|vm|host|server|instance|machine|account|repo|data|db)|client.{0,20}(box|vm|host|server|instance|machine)|(on|to|their) (a )?customer.s|marketing site|landing page|5dive\.com|public repo|docs site|blog post|\bbrand\b|rebrand|positioning|pricing page|go.to.market|\bstrategic\b|public relations|\bpr (agency|firm|retainer)\b|agent (create|creation|rm|remove|delete|fire|hire|repurpose|provision)|(create|remove|delete|fire|hire|repurpose|provision)( an?| the)? agent|sudoers|sudo (grant|access|rule|rules|policy)|grant.{0,20}sudo|root access|fleet privilege|privilege (grant|change|escalat)'
_gate_lead_standing_denied() {
  local text; text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$text" =~ $_GATE_LEAD_STANDING_DENY_RX ]]
}
# _gate_lead_standing_eligible <need_type> <tier> <text>  -> 0 when the standing
# authority reaches this gate. <text> is the ask AND the title, because the gate
# classifiers on both sides of this file read both (DIVE-1957) and a scope word
# that appears only in the title must still be able to REMOVE authority.
_gate_lead_standing_eligible() {
  # DIVE-2224: <ask> and <title> are SEPARATE arguments. They used to arrive
  # pre-joined (`ask||' '||title` in SQL), which let a bounded-distance pattern
  # straddle the seam -- and here a phantom `_gate_eng_ship_hit` GRANTS standing
  # authority on a gate neither field classifies as engineering. The 4th argument
  # is optional so a 3-argument caller keeps its exact single-text behaviour.
  local nt="${1:-}" tier="${2:-}" text="${3:-}" text2="${4-}"
  # Type: `approval` ONLY. `secret` is never lead-clearable at any tier;
  # `manual` is by definition a step only a person can perform; `access` already
  # has its own DIVE-1243 route; `decision` is lead-clearable by type already and
  # needs no new authority. Narrowing to one type keeps the blast radius of a
  # misclassification to the one class lodar actually granted.
  [[ "$nt" == "approval" ]] || return 1
  # Tier: exactly 1. Tier 2 is the hard human floor and this authority does NOT
  # pierce it — an engineering gate that got floored to 2 (DIVE-2089's subject-
  # matter misread) stays human-only until 2089 fixes the floor itself. Empty /
  # legacy-NULL / 0 deny: an unknown tier is not a tier-1 gate.
  [[ "$tier" == "1" ]] || return 1
  # A gate with nothing to classify cannot be classified as engineering.
  [[ -n "${text//[[:space:]]/}" || -n "${text2//[[:space:]]/}" ]] || return 1
  # Positive engineering evidence. Absence of this is a DENY, not a default —
  # this is the fail-closed direction: "not recognised as engineering" routes to
  # the human exactly as it does today.
  _gate_hit_either _gate_eng_ship_hit "$text" "$text2" || return 1
  # Exclusion 1 — the shared true-human floor (money, secrets/credentials,
  # destructive, publish/press/customer-comms, dns). Belt-and-braces: a tier-1
  # gate should already have failed this floor at filing, but a row filed before
  # the floor existed, or one whose floor terms live in a title added later, must
  # not inherit authority from a stale tier column.
  ! _gate_hit_either _gate_tier2_floor_hit "$text" "$text2" || return 1
  # Exclusion 2 — the ticket's EXPLICITLY OUT OF SCOPE list that the T2 floor does
  # NOT already cover: a customer's box, our customer-facing/public surfaces, a
  # brand or strategic call, and fleet privilege changes.
  ! _gate_hit_either _gate_lead_standing_denied "$text" "$text2" || return 1
  return 0
}

# DIVE-3228 — THE COMMENT AND THE CONDITION DISAGREED, AND THE CONDITION WON.
#
# `access` defaults to tier 2 (the `*) tier=2` arm at the type-default case below),
# and DIVE-1243 made it lead-clearable BY TYPE: it is routable regardless of tier,
# it bypasses the gate_builder_routing pref, and cmd_task_answer's
# designated-reviewer exception lists it alongside approval/manual. So filing one
# tells the filer it routed, and `routed_reviewer` really is set.
#
# Then the tier-2 floor in cmd_task_answer (`gtier == 2 && ! human`) refuses the
# routed lead's answer, and the DIVE-1437 escalation immediately below it is scoped
# `[[ $nt == approval || $nt == manual ]]` — `access` is not in that list, so it
# does not even get the escalation's tap button; it takes the original hard
# refusal. The comment eight lines above that condition asserts the opposite
# ("`access` is DELIBERATELY lead-clearable by DIVE-1243"), which is how this
# survived: every reader who checked the intent found it documented and correct.
#
# MEASURED, DIVE-3212 (ops -> main, 2026-08-11): filed --type=access, routed at
# main explicitly, `task answer` refused with "DIVE-3212 is a tier-2 human gate
# (access) — only a human can clear it; tap the button in Telegram". The filer did
# everything right and still produced a gate only lodar could clear, for a push to
# our own repo. It was already MOOT when it refused — the branch was pushed and
# PR #585 opened before the answer was attempted — so it sat in the human inbox
# describing work that was done.
#
# WHY THIS IS NOT "let the lead clear tier 2". The exemption is re-derived FROM THE
# ROW rather than inferred from `_lead_clear` alone, and that is deliberate: relying
# on the file-time invariant ("a floored/pinned access gate never gets routed, so a
# routed one must be clean") is exactly the necessary-but-not-sufficient trap this
# same row already produced once — the six-harness population that was derived
# statically and measured to zero. A row written by an older build, or by any future
# path that sets routed_reviewer, must not inherit clearance from an argument about
# what cmd_task_need does today.
#
# So `access` at tier 2 is lead-clearable ONLY when the store can say it is tier 2
# for the one reason that carries no human class:
#   axis=type-default   -> 2 because `access` defaults to 2. Nobody chose it. ALLOW.
#   axis=pinned         -> the caller typed --tier=2. DIVE-1957: a hard-human
#                          contract no KIND-based override may cross. DENY.
#   axis=ask / title-fallback -> the T2 category floor fired on money / secrets /
#                          destructive / publish. DENY.
#   '' or NULL          -> a pre-DIVE-2615 row: the column was never written, so the
#                          reason is UNKNOWN. An unknown is not a type-default. DENY.
# and a declared human-class `--needs` (spend_authority / human_tap / secret_provision)
# denies on top of all of it — the filer STATING what the ask consumes outranks any
# inference about the tier (DIVE-2241).
#
# `secret` can never reach here: it is never routed, so `_lead_clear` is 0 for it by
# construction, and it is not this predicate's type anyway.
#
# _gate_access_lead_clearable <need_type> <tier> <floor_provenance> <needs_capability>
#   -> 0 when a tier-2 `access` gate's ROUTED lead may clear it despite the T2 floor.
_gate_access_lead_clearable() {
  local nt="${1:-}" tier="${2:-}" floor_prov="${3:-}" needs="${4:-}"
  [[ "$nt" == "access" ]] || return 1
  [[ "$tier" == "2" ]] || return 1
  # DIVE-2241: the declaration outranks the tier's provenance, so it is checked
  # first and independently. An UNRECOGNISED capability is not a human one and
  # changes nothing here, exactly as it changes nothing at filing time.
  if [[ -n "${needs//[[:space:]]/}" ]] && _gate_needs_human "$needs"; then return 1; fi
  # The ONE allowed provenance. Everything else — including empty — denies.
  [[ "$floor_prov" == "axis=type-default" ]] || return 1
  return 0
}

# DIVE-2099 iteration 2 — WHO holds the standing authority, anchored to a NAMED
# agent. lodar answered the tier-2 decision gate 2026-07-27 with
# `anchor-to-named-agent`, over `keep-chart-derived`.
#
# WHY THE ORG CHART CANNOT BE THE SOURCE (what iteration 1 got wrong): iteration 1
# resolved the holder live at clear time with `_gate_route_reviewer(filer)`, which
# reads `agents_org.reports_to`. DIVE-2124 put `require_root` on `org set`/`org rm`,
# but every agent on this host holds (ALL) NOPASSWD:ALL, so `sudo 5dive org set` is
# still reachable by any of them, and the column recording who wrote the row
# (`by_claimed`) is caller-supplied and explicitly labelled non-evidence
# (residual: DIVE-2131). Deriving the authority from a table the beneficiary can
# rewrite is a self-grant path on the very authority being granted: rewrite the
# chart to make yourself somebody's lead, then clear their gate as your own lead.
#
# THE ANCHOR: the agent NAMED in the constitution, trusted only when the on-disk
# constitution still matches the digest SEALED into the council lineage. This is
# the DIVE-1695 precedent, already load-bearing for the tier-2 hard-gate floor a
# few hundred lines up: the file is forgeable, the chain is not. An agent CAN
# `sudo` a new name into constitution.yaml — and the moment it does, the live
# sha256 stops matching the sealed one, `_council_constitution_drifted` says
# DRIFTED, and this function denies EVERYONE, including the name that was there
# before. Re-sealing is a constitutional-class council motion (2/3 + full quorum +
# founder veto), which no agent can convene against itself. So the write is not
# prevented, it is made self-defeating and tamper-evident — which is the property
# `require_root` alone does not have on a NOPASSWD:ALL host.
#
# FAIL CLOSED at every unknown: no council loader in scope, no sealed digest in
# the lineage (a bare constitution.yaml is then just a file anyone can write), a
# drifted file, a missing file, no `authority.eng_approval_lead` key, an empty
# value, or a value that is not a plain agent name -> no standing authority for
# anyone. Absence of a name is NOT "everyone" and is NOT "fall back to the chart".
#
# The org chart is still read for ROUTING (`_gate_route_reviewer`, unchanged) and
# the resolved filer is still recorded in the audit row — but neither is consulted
# for AUTHORITY any more. That separation is what the required test pins: mutate
# the chart after filing and the clear must still be refused.
_GATE_STANDING_LEAD_NAME_RX='^[a-z0-9][a-z0-9_-]{0,31}$'
# Node-free reader for the one constitution field this authority needs, mirroring
# `_council_constitution_drifted`'s reason for existing: the gate path must not
# spin up the Node runtime (and must stay testable when cmd_task.sh is sourced
# alone). Deliberately a STRICT subset of YAML — a top-level `authority:` block
# and a scalar `eng_approval_lead:` inside it. Anything it cannot parse reads as
# absent, which denies.
_gate_constitution_standing_lead() {
  local path="${1:-}" line val in_block=0
  [[ -n "$path" && -f "$path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # A non-indented line starts a new top-level key: we are inside `authority:`
    # only while that key is the current one. Nested keys elsewhere in the file
    # named `eng_approval_lead` therefore cannot grant anything.
    if [[ "$line" =~ ^[^[:space:]] ]]; then
      if [[ "$line" =~ ^authority:[[:space:]]*(#.*)?$ ]]; then in_block=1; else in_block=0; fi
      continue
    fi
    (( in_block )) || continue
    [[ "$line" =~ ^[[:space:]]+eng_approval_lead:[[:space:]]*(.*)$ ]] || continue
    val="${BASH_REMATCH[1]}"
    val="${val%%#*}"                       # strip a trailing comment
    val="${val#"${val%%[![:space:]]*}"}"   # ltrim
    val="${val%"${val##*[![:space:]]}"}"   # rtrim
    val="${val%\"}"; val="${val#\"}"       # unquote "…"
    val="${val%\'}"; val="${val#\'}"       # unquote '…'
    [[ -n "$val" ]] || return 1
    printf '%s' "$val"
    return 0
  done < "$path"
  return 1
}
# _gate_standing_lead -> prints the named holder on stdout, or nothing + rc 1.
_gate_standing_lead() {
  declare -F _council_constitution_path >/dev/null 2>&1 || return 1
  declare -F _council_sealed_constitution_digest >/dev/null 2>&1 || return 1
  declare -F _council_constitution_drifted >/dev/null 2>&1 || return 1
  # A constitution that was never sealed carries no authority: without a lineage
  # record to drift FROM, the file is exactly as writable as the org chart, and
  # anchoring to it would reproduce the self-grant path in a different file.
  local sealed; sealed="$(_council_sealed_constitution_digest 2>/dev/null || true)"
  [[ -n "$sealed" ]] || return 1
  # Sealed but the live bytes differ (or the file is gone) -> deny everyone.
  ! _council_constitution_drifted || return 1
  local path; path="$(_council_constitution_path 2>/dev/null || true)"
  local name; name="$(_gate_constitution_standing_lead "$path" 2>/dev/null || true)"
  # A plain agent name only. Rejecting `human:main`, `*`, `all`, a path or a shell
  # metacharacter keeps this a name comparison and nothing more.
  [[ "$name" =~ $_GATE_STANDING_LEAD_NAME_RX ]] || return 1
  printf '%s' "$name"
}

# DIVE-2233 — the SECOND authority that was still derived from the org chart, and the
# one DIVE-2099 explicitly left alone ("the org chart is still read for ROUTING,
# unchanged"). Routing turned out not to be only routing:
#
#   _gate_route_reviewer(filer)  reads agents_org.reports_to           (agent-writable)
#     -> UPDATE tasks SET routed_reviewer=<that name>                  (persisted at FILE time)
#       -> cmd_task_answer: nt in approval|manual|access AND actor == routed_reviewer
#          -> _lead_clear=1 -> that agent CLEARS A HUMAN-ONLY GATE
#
# So `sudo 5dive org set <victim> --manager=<me>` is a one-command self-grant: re-parent
# a builder, wait for (or provoke) their next ship gate, and clear it as their lead. The
# `require_root` on `org set` (DIVE-2124) does not help on a NOPASSWD:ALL host, and the
# `by_claimed` record of who wrote the row is caller-supplied and explicitly non-evidence.
#
# THE SPLIT THAT FIXES IT: routing and authorization are two different questions and only
# one of them has to be trustworthy.
#   - WHO IS PINGED stays chart-derived. That is a notification: routing a gate to the
#     wrong agent wastes their attention, it does not clear anything. Left unchanged so
#     re-parenting an org keeps working the way an org expects.
#   - WHO MAY CLEAR comes from these sealed bytes and nowhere else. An agent that writes
#     itself into somebody's `reports_to` still gets the ping and still cannot clear; the
#     gate falls through to the human exactly as if no lead had been named.
# Deriving BOTH from the chart is what made the write an authority grant. Deriving only
# the ping from it makes the same write inert.
#
# The seal is what carries the property, same as DIVE-2099: an agent CAN sudo a new name
# into constitution.yaml, and the moment it does the live sha256 stops matching the digest
# sealed in the council lineage, `_council_constitution_drifted` says DRIFTED, and this
# returns EMPTY — denying every lead including the legitimate ones. Re-sealing is a
# constitutional-class motion (2/3 + full quorum + founder veto) no agent convenes against
# itself. The write is not prevented, it is made self-defeating.
#
# FAIL CLOSED at every unknown (no council loader, no sealed digest, drift, missing file,
# no key, empty list, a malformed entry) -> NO name may lead-clear. Absence is not
# "everyone" and is NOT "fall back to the chart" — falling back would restore the exact
# path this closes. Note the operational consequence and that it is intended: on a box
# whose constitution does not name `gate_clear_leads`, routed lead-clear is INERT and
# every routed approval/manual/access gate waits for a human. That is a real posture
# change, so the refusal is logged with a REASON (see `_gate_clear_lead_denied_reason`)
# rather than being a silent nothing — an authority that quietly stopped working is the
# failure mode DIVE-1935 cost us a day on.
_GATE_CLEAR_LEAD_NAME_RX="$_GATE_STANDING_LEAD_NAME_RX"
# Node-free reader for `authority.gate_clear_leads`, a STRICT subset of YAML: a top-level
# `authority:` block containing a `gate_clear_leads:` key whose value is a BLOCK SEQUENCE
# of plain scalars. Prints one name per line. A flow sequence (`[a, b]`), a nested map, or
# anything else it cannot parse reads as ABSENT, which denies — a reader that guessed at a
# shape it does not really support would be granting authority from bytes nobody verified.
_gate_constitution_clear_leads() {
  local path="${1:-}" line val in_block=0 in_list=0 n=0
  [[ -n "$path" && -f "$path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # A non-indented line starts a new top-level key. `gate_clear_leads` nested under any
    # other top-level key therefore grants nothing.
    if [[ "$line" =~ ^[^[:space:]] ]]; then
      if [[ "$line" =~ ^authority:[[:space:]]*(#.*)?$ ]]; then in_block=1; else in_block=0; fi
      in_list=0
      continue
    fi
    (( in_block )) || continue
    # An indented NON-list key ends the sequence — `gate_clear_leads:` followed by
    # `eng_approval_lead:` must not swallow the latter as an entry.
    if [[ ! "$line" =~ ^[[:space:]]+- ]]; then
      if [[ "$line" =~ ^[[:space:]]+gate_clear_leads:[[:space:]]*(.*)$ ]]; then
        val="${BASH_REMATCH[1]}"; val="${val%%#*}"
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        # Only an EMPTY value opens a block sequence. An inline value here is a scalar or a
        # flow sequence — neither is the supported shape, so refuse the whole key rather
        # than parse half of `[a, b]` into a name.
        [[ -n "$val" ]] && return 1
        in_list=1
      else
        in_list=0
      fi
      continue
    fi
    (( in_list )) || continue
    [[ "$line" =~ ^[[:space:]]+-[[:space:]]*(.*)$ ]] || continue
    val="${BASH_REMATCH[1]}"
    val="${val%%#*}"                       # strip a trailing comment
    val="${val#"${val%%[![:space:]]*}"}"   # ltrim
    val="${val%"${val##*[![:space:]]}"}"   # rtrim
    val="${val%\"}"; val="${val#\"}"       # unquote "…"
    val="${val%\'}"; val="${val#\'}"       # unquote '…'
    [[ -n "$val" ]] || continue
    printf '%s\n' "$val"
    n=$((n+1))
  done < "$path"
  (( n > 0 ))
}
# _gate_clear_leads -> prints the sealed allowlist, one name per line, or nothing + rc 1.
# Same fail-closed chain as _gate_standing_lead, for the same reasons.
_gate_clear_leads() {
  declare -F _council_constitution_path >/dev/null 2>&1 || return 1
  declare -F _council_sealed_constitution_digest >/dev/null 2>&1 || return 1
  declare -F _council_constitution_drifted >/dev/null 2>&1 || return 1
  # Never sealed = the file is exactly as writable as the org chart, so anchoring to it
  # would reproduce the self-grant in a different file.
  local sealed; sealed="$(_council_sealed_constitution_digest 2>/dev/null || true)"
  [[ -n "$sealed" ]] || return 1
  ! _council_constitution_drifted || return 1
  local path; path="$(_council_constitution_path 2>/dev/null || true)"
  local names; names="$(_gate_constitution_clear_leads "$path" 2>/dev/null || true)"
  [[ -n "$names" ]] || return 1
  # Validate EVERY entry and refuse the whole list if any one is malformed. Dropping the
  # bad entry and keeping the rest would let a hostile edit that fails validation still
  # shift the effective allowlist, which is a partial grant from bytes we just rejected.
  local nm
  while IFS= read -r nm; do
    [[ "$nm" =~ $_GATE_CLEAR_LEAD_NAME_RX ]] || return 1
  done <<< "$names"
  printf '%s\n' "$names"
}
# Is $1 named in the sealed allowlist? rc 0 = yes. Everything else = no.
_gate_clear_lead_allowed() {
  local who="${1:-}" nm; [[ -n "$who" ]] || return 1
  local names; names="$(_gate_clear_leads 2>/dev/null || true)"
  [[ -n "$names" ]] || return 1
  while IFS= read -r nm; do [[ "$nm" == "$who" ]] && return 0; done <<< "$names"
  return 1
}
# Why was a routed lead-clear refused? Emitted into the audit row so "the seal is not set
# up on this box" is distinguishable from "this agent is not a lead" — the two demand
# completely different responses (convene a motion vs. investigate a self-grant attempt)
# and are indistinguishable from the gate's behaviour alone.
_gate_clear_lead_denied_reason() {
  declare -F _council_sealed_constitution_digest >/dev/null 2>&1 || { printf 'no-council-loader'; return; }
  local sealed; sealed="$(_council_sealed_constitution_digest 2>/dev/null || true)"
  [[ -n "$sealed" ]] || { printf 'constitution-unsealed'; return; }
  if _council_constitution_drifted 2>/dev/null; then printf 'constitution-drifted'; return; fi
  local names; names="$(_gate_clear_leads 2>/dev/null || true)"
  [[ -n "$names" ]] || { printf 'no-gate-clear-leads-key'; return; }
  printf 'not-a-sealed-lead'
}

# DIVE-1381: the CONTENT-CURATION gate class — the third downgrade kind, mirror
# of the eng-ship class (DIVE-1359) for our early-stage content surfaces
# (OpenAgent / character-packs / the daily persona drip). Surfaced by DIVE-1366:
# a persona/pack QUEUE-READINESS approval is not a human call — per ship-gating,
# OpenAgent/character-packs is an early-stage surface, safe to push, no approval
# gate to the paired human; it is the org lead's (Marcus) to clear. But the T2
# floor matches 'publish' in the ask/title and forces the gate hard-human
# (tier-2 = unclearable by the lead), the exact wall DIVE-1366 hit. This class
# marks curation/queue-readiness asks so the caller below can downgrade them to
# a lead-routed tier-1 — BUT ONLY when the *sole* reason the floor fired was a
# content-publish-LATER term (see _GATE_CONTENT_PUBLISH_RX): the real publish
# happens downstream via the drip, not now. The true-human floor still wins for
# a genuine publish-NOW / press / customer-comms / money / secret /
# destructive ask — the caller re-tests the floor with the publish-later terms
# stripped and only downgrades if nothing else trips it. secret/manual are never
# curation; filer-is-lead ⇒ no reviewer ⇒ not downgraded.
# NB word-anchored where a bare substring would over-match: \bpersonas?\b (not
# 'personal'/'personalize'), \bcurat (curate/curation/curator, not 'accurate').
_GATE_CONTENT_CURATION_RX='\bpersonas?\b|character.?pack|char.?pack|openagent|promote.?queue|drip queue|drip schedule|queue.?readiness|ready for the (queue|drip)|ready to (queue|drip)|\bcurat|skill.?set|gallery (card|pack|entry)'
_gate_content_curation_hit() {
  local text; text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$text" =~ $_GATE_CONTENT_CURATION_RX ]]
}
# The content-publish-LATER terms — the subset of the T2 floor whose match is
# safe to carve out for a curation-shaped ask, because for our drip the actual
# publish is a downstream, automated step, not the thing being approved now.
# Deliberately NARROW: 'press', 'customer email', 'newsletter', and 'blast'
# and every money/secret/destructive term stay in the floor (they are genuine
# human calls even in a curation context). Used to compute the residual-floor
# test in cmd_task_need.
_GATE_CONTENT_PUBLISH_RX='publish|public post|announce|launch post'

# DIVE-1480: the INTERNAL-OPS / RECOVERY decision class — the fourth downgrade
# kind, mirror of eng-ship (DIVE-1359) and content-curation (DIVE-1381). Surfaced
# by the 2026-07-19 board wipe: dev's STEER-1 "keep vs discard my work / rebuild
# the board" decision gate (filed FOR the lead) got FORCED to hard-human tier-2
# purely because its ask NARRATED the wipe — 'destroyed', 'wiped', 'purge' — so
# the T2 destructive floor tripped and it landed on lodar instead of Marcus, whose
# call it actually was. A decision about our OWN control-plane state (the task
# board / an agent's uncommitted work / a wipe recovery) is the org lead's to
# clear, not the paired human's. This class marks such asks so the caller
# downgrades them to a lead-routed tier-1, BUT ONLY when the SOLE reason the floor
# fired was an INTERNAL-destructive term (see _GATE_INTERNAL_DESTRUCTIVE_RX): a
# genuine prod/customer/infra destructive ask (drop a prod table, teardown infra,
# revoke a key, a dns/domain change) keeps those terms in the residual floor and
# stays hard-human. The class regex is deliberately NARROW — task-board / dev-
# workspace / recovery vocabulary that essentially never appears in an external
# destructive gate — so it is the real safety gate, not the term carve-out.
# secret/manual are never internal-ops; filer-is-lead ⇒ no reviewer ⇒ not
# downgraded (a lead may legitimately pin a human gate).
_GATE_INTERNAL_OPS_RX='task ?board|tasks?\.db|\btask db\b|the backlog|board (wipe|wiped|reset|reconstruct|rebuild|recovery)|(wipe|wiped|reset|lost|rebuild|reconstruct|restore).{0,20}(board|backlog)|my (uncommitted|wip|in.?flight|local|unmerged) (work|changes|edits|branch)|discard (my|the|dev.s) (work|changes|edits|wip)|keep (vs|or) discard|steer-[0-9]|the audit (trail|log)|heartbeat log'
_gate_internal_ops_hit() {
  local text; text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$text" =~ $_GATE_INTERNAL_OPS_RX ]]
}
# The internal-destructive terms — the subset of the T2 floor whose match is safe
# to carve out for an internal-ops ask, because they NARRATE/act-on our own
# recoverable dev state, not production. Deliberately NARROW: 'teardown', 'drop
# table', 'revoke', 'dns', 'domain transfer' STAY in the floor (real infra / prod
# / access, human calls even in a recovery context), as does every money / secret
# / publish term. Used to compute the residual-floor test below.
_GATE_INTERNAL_DESTRUCTIVE_RX='destroy|wipe|purge|delete|irreversible'

# DIVE-1481: the internal-ops OBJECT vocabulary — the control-plane nouns a
# carved-out destructive term is allowed to act on (task board / tasks.db /
# backlog / an agent's own wip). The residual test below strips a destructive
# term ONLY when it is CO-REFERENT (adjacent) to one of these, never merely
# co-present in the same ask. That closes the residual gap DIVE-1480 left open:
# 'delete the production database as part of board recovery' matches the
# internal-ops CLASS ('board recovery') and has its 'delete' stripped by a blanket
# carve-out, silently downgrading a PROD-destructive action to lead review — but
# 'delete' governs 'production database', not the board, so it must stay
# hard-human. `\bboard\b` (not bare 'board') so 'dashboard'/'keyboard' don't match.
_GATE_INTERNAL_OBJECT_RX='task ?board|tasks?\.db|\btask db\b|backlog|\bboard\b|\bwip\b|uncommitted|in.?flight|unmerged|audit (trail|log)|heartbeat log'
# _gate_internal_residual <text>: lower-cases <text>, then removes each internal-
# destructive term ONLY where an internal-ops object sits within ~20 chars on
# either side (active 'wipe the board' OR passive 'the board was wiped'). A verb
# whose object is external (a prod table, a customer record) is left intact so the
# residual still trips the T2 floor and the gate stays hard-human. Iterates to a
# fixpoint so several verbs sharing one object all clear; non-/g single pass per
# step keeps the object available for the next verb.
# DIVE-1487: external destructive TARGETS — a prod/customer/infra object. When one
# appears anywhere in the ask, a destructive verb may govern IT rather than (or in
# addition to) the internal object — in a compound ("delete the board and the
# production database"), across a coordination span, or over a passive window the
# 20-char heuristic mis-reads ("wipe the board then delete the prod customer
# records"). The nearest-object active/passive strip can't tell these from a purely
# internal ask, so we REFUSE to strip any destructive verb once an external target
# is present: the verb survives into the residual, trips the T2 floor, and the gate
# stays hard-human. Biased to over-elevate (the safe direction); the carve-out then
# only fires for asks whose destructive framing is PURELY internal. Narrowly
# external (prod/customer/live/user-data) so a plain internal ask ("discard my
# uncommitted work", "rebuild the board from the audit log") is untouched.
_GATE_EXTERNAL_TARGET_RX='\bprod\b|production|customers?\b|user data|\bpii\b|live (data|site|db|database)|user records?|customer records?'
_gate_internal_residual() {
  local text prev; text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  # An external prod/customer target is present → a destructive verb may govern it;
  # do not strip, so the residual keeps the verb and the T2 floor still fires.
  [[ "$text" =~ $_GATE_EXTERNAL_TARGET_RX ]] && { printf '%s' "$text"; return; }
  local i=0
  while [[ $i -lt 8 ]]; do
    prev="$text"
    # active: destructive verb governs a following internal object
    text=$(printf '%s' "$text" | sed -E "s/(${_GATE_INTERNAL_DESTRUCTIVE_RX})([^.]{0,20}(${_GATE_INTERNAL_OBJECT_RX}))/ \2/")
    # passive: internal object precedes the destructive verb
    text=$(printf '%s' "$text" | sed -E "s/((${_GATE_INTERNAL_OBJECT_RX})[^.]{0,20})(${_GATE_INTERNAL_DESTRUCTIVE_RX})/\1 /")
    [[ "$text" == "$prev" ]] && break
    i=$((i+1))
  done
  printf '%s' "$text"
}

# DIVE-2089: the DECLARED-DISCUSSION appeal — the fifth (and last text-driven)
# treatment of the T2 floor, and the only one that does NOT try to infer intent
# from vocabulary.
#
# THE DEFECT IT ANSWERS. The floor reads SUBJECT MATTER and picks the audience
# from it. dev3 filed a tier-1 SIZING gate on DIVE-2078 — "how should we model
# capability vs clearance" — and it was floored hard-human because the ask
# contains the words "credentials" and "privileged". The gate DISCUSSES
# credential handling as a design question and performs NO credential operation.
# Talking about credentials is not handling credentials.
#
# WHY NOT ANOTHER CLASS REGEX. eng-ship / curation / internal-ops all guess the
# KIND from more vocabulary, and DIVE-2099's design note 1 is explicit that
# adding a sixth guesser reproduces this bug with the polarity reversed — a
# false NEGATIVE there routes a real secret gate to an agent. There is no
# phrasing that reliably separates "discussing X" from "doing X": that is a fact
# about the filer's intent, not about the text. So we stop inferring and make
# the filer DECLARE it, on the record, with `--discusses="<why>"`.
#
# WHY A DECLARATION BEATS THE WORKAROUND IT REPLACES. dev3's actual remedy was
# to re-file with neutral wording, which is the worst outcome available: it
# works, it teaches the fleet to launder vocabulary to reach the right audience,
# and it is INVISIBLE — a laundered ask is byte-indistinguishable from an ask
# that never had the words. A declaration is the opposite on every axis: it is
# attributable to its filer, it is written into the gate the LEAD then reads, and
# it is audited. An agent that lies in a `--discusses` string is caught by the
# reviewer looking at the claim; an agent that launders is caught by nobody.
#
# THE SAFETY MODEL, and it is deliberately four-deep — the declaration is NOT
# trusted on its own:
#   1. `--type=decision` ONLY. approval / manual / secret / access DECLARE AN
#      ACTION by construction ("approve me doing X", "hand me the key"), so no
#      appeal exists for them. decision is the one type whose content is a
#      question. This is the ticket's own suggested shape: key off the declared
#      action, not the substrings.
#   2. Fires ONLY when the floor ACTUALLY over-fired (tier_floored==1), like
#      DIVE-1480 — a non-floored decision's routing is untouched.
#   3. NON-APPEALABLE CORE. Money, irreversible infra and real-comms terms can
#      never be appealed, no matter what is declared: we re-test the floor with
#      only the APPEALABLE terms stripped and refuse the appeal if anything
#      still trips it. A "should we refund these customers, A or B" decision is
#      a human call whether or not it is framed as design.
#   4. It downgrades to a LEAD-ROUTED tier-1, never to tier-0 and never to the
#      filer. A human is replaced by a reviewer, not by nobody; filer-is-lead ⇒
#      no reviewer ⇒ no appeal (a lead cannot self-appeal to themselves).
# Plus: an explicit --tier=2 vetoes it (DIVE-1957), and the appeal is refused
# LOUDLY rather than silently ignored, so a filer never believes an appeal
# applied when it did not.
#
# WHAT THIS DOES NOT REMOVE — the DIVE-2146 pre-condition, discharged by
# construction rather than by enumeration. olivia's precondition on this ticket
# is that the floor is currently the SOLE ENFORCER of at least one directive
# (the self-restart confirm at projects/CLAUDE.md:13) and that a control which
# stops firing emits NO signal. This design cannot regress any such gate,
# because NOTHING here changes a gate's tier unless the filer PASSES A NEW FLAG.
# An agent that files the self-restart approval exactly as before gets the exact
# tier it got before — and `--discusses` is unavailable to it anyway, since that
# gate is --type=approval (rule 1). The directive still needs encoding as its own
# artifact; DIVE-2146 owns that arm and gates it on its own precondition.
#
# APPEALABLE: the vocabulary that routinely appears in DESIGN discussion of a
# category without any action being requested — secrets/credentials handling
# (2089's reported case), the content-publish-later terms DIVE-1381 already
# treats as over-firing, and the recoverable-destructive verbs DIVE-1480 does.
_GATE_FLOOR_APPEALABLE_RX='secret|credential|api key|token|password|publish|public post|announce|launch post|delete|destroy|wipe|purge'
# NON-APPEALABLE (everything else in the floor, stated positively so a future
# edit to the floor regex cannot silently widen what an appeal reaches): money,
# real outbound comms, and irreversible infra/access. Never carved out.
#
# DIVE-2301: this constant is DOCUMENTATION OF RECORD, not a matcher — nothing
# matches against it (grep the tree: one definition, zero uses). The non-appealable
# decision is reached by SUBTRACTION: strip the appealable terms and re-test the
# FULL floor, so the boundary fix at _gate_tier2_floor_hit is what actually stops
# 'suppression' from being read as the non-appealable 'press' in an appeal refusal.
# If this list is ever promoted to a live matcher it must go through the same
# leading-boundary wrapper and NOT per-term \b, which cannot anchor \$[0-9]/€[0-9]
# and would silently drop the money class out of the un-appealable half.
#
# The appeal path depends on an invariant this pair must keep: no APPEALABLE term
# may be a substring of a NON-APPEALABLE one, or stripping the former would erase
# the latter and hand an appeal to a class that has none. Asserted in
# tests/gate_floor_word_boundary_unit.sh rather than left to review.
_GATE_FLOOR_NONAPPEALABLE_RX='spend|billing|invoice|charge|payment|refund|subscription|price|pricing|\$[0-9]|€[0-9]|press|customer email|email customers|newsletter|blast|teardown|drop[^.]{0,20}table|truncate|irreversible|revoke|dns|domain transfer'
# _gate_floor_appeal_residual <text>: lower-case <text> and remove ONLY the
# appealable terms. The caller re-tests the full floor against the result; if it
# still fires, a non-appealable class is present and the appeal is refused.
_gate_floor_appeal_residual() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E "s/(${_GATE_FLOOR_APPEALABLE_RX})//g"
}
# _gate_tier2_floor_term <text>: the SUBSTRING that tripped the floor, or empty.
# DIVE-2089 defect 2 — the floor was SILENT. dev3 only discovered the escalation
# by re-reading their own filed gate; an agent that files and moves on leaves a
# design question in the founder's inbox indefinitely. "[tier forced to 2 — T2
# category floor]" does not say WHICH word did it, and a filer cannot appeal or
# even understand an escalation whose cause is unnamed. Reuses the same resolved
# policy regex as the floor itself (constitution-aware, drift-fail-closed) so the
# term reported is always the term that actually matched.
_gate_tier2_floor_term() {
  local text rx="$_GATE_T2_FLOOR_RX" loaded=""
  text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if declare -F _council_hard_gate_rx >/dev/null 2>&1 \
     && declare -F _council_constitution_path >/dev/null 2>&1; then
    local cp; cp="$(_council_constitution_path 2>/dev/null || true)"
    if [[ -n "$cp" && -f "$cp" ]] \
       && ! { declare -F _council_constitution_drifted >/dev/null 2>&1 && _council_constitution_drifted; }; then
      loaded="$(_council_hard_gate_rx 2>/dev/null || true)"
      # Same ERE-validity guard as the floor (CNCL-28): Bash returns 2 for an
      # invalid expression, and this helper must never report a term the floor
      # itself did not use.
      if [[ -n "$loaded" ]]; then
        local ere_rc=0; [[ x =~ $loaded ]] || ere_rc=$?
        (( ere_rc == 2 )) || rx="$loaded"
      fi
    fi
  fi
  # DIVE-2301: same leading-boundary wrapper as the floor itself — this helper must
  # never report a term the floor did not use, and that includes never reporting a
  # term the floor no longer matches. BASH_REMATCH[0] now carries the boundary
  # character too (" press"), so the TERM is group 2; reporting [0] would print a
  # leading space into the warn line and into the gate record.
  #
  # DIVE-2629: and that invariant is exactly why the branch-ref redaction has to be
  # mirrored here. Without it this helper would keep reporting 'teardown' — a term
  # read out of a git branch name — for a text the floor itself no longer floors,
  # which is the drift the paragraph above forbids.
  if _gate_push_for_review_hit "$text"; then
    text=$(_gate_redact_branch_refs "$text")
  fi
  [[ "$text" =~ (^|[^[:alnum:]_])($rx) ]] && printf '%s' "${BASH_REMATCH[2]}"
}

# OSS-11 (DIVE-976) — _gate_ask_shape <ask>: normalize an ask into its "shape
# key" so two gates that ask structurally the same question but about different
# targets collapse to one key. Precedent matching uses EXACT shape-key equality
# (no fuzzy/embedding match) to bound false positives. Volatile tokens become
# typed placeholders; the ORDER below matters — each rule must run before any
# later rule that could re-consume its output (dates/hosts before the bare-number
# rule; quoted names first so their contents aren't mangled). Placeholders carry
# no digits, hyphenated-digit runs, or dots, so no rule ever re-fires on them.
_gate_ask_shape() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E \
        -e 's/"[^"]*"/<name>/g' \
        -e "s/'[^']*'/<name>/g" \
        -e 's#https?://[^[:space:]]+#<host>#g' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}/<date>/g' \
        -e 's/\b(today|tomorrow|yesterday)\b/<date>/g' \
        -e 's/([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}/<host>/g' \
        -e 's/\$[0-9][0-9,]*(\.[0-9]+)?[kmb]?/<amount>/g' \
        -e 's/\b[a-z]+-[0-9]+\b/<ident>/g' \
        -e 's/[0-9]+(\.[0-9]+)?/<num>/g' \
        -e 's/[[:space:]]+/ /g' \
        -e 's/^ +//; s/ +$//'
}

# OSS-20 — _gate_shape_jaccard <shapeA> <shapeB>: token-set Jaccard similarity of
# two ask_shapes, printed as an integer 0..100 (percent). Tokens are the
# whitespace-split words of each shape (order- and duplicate-insensitive; the set
# is what matters). Jaccard = |A∩B| / |A∪B|. Empty-vs-empty and any empty side is
# 0 (the caller only fuzzy-matches non-empty shapes anyway). Used by the fuzzy
# precedent fallback: two shapes at >=80 are "same question, paraphrased".
_gate_shape_jaccard() {
  awk -v a="$1" -v b="$2" '
    BEGIN {
      na = split(a, ta, /[ ]+/); for (i = 1; i <= na; i++) if (ta[i] != "") A[ta[i]] = 1
      nb = split(b, tb, /[ ]+/); for (i = 1; i <= nb; i++) if (tb[i] != "") B[tb[i]] = 1
      inter = 0; for (k in A) if (k in B) inter++
      uni = 0; for (k in A) uni++; for (k in B) if (!(k in A)) uni++
      if (uni == 0) { print 0; exit }
      printf "%d", (inter * 100) / uni
    }'
}

# DIVE-2212: decision options are authored by the filer but read and selected by
# the answerer. Second-person wording therefore has two natural frames on the
# same bytes ("you" can be read as either side). Keep options free-form, but make
# that risky shape observable at filing and render the concrete account frame on
# answer. Boundaries deliberately exclude innocent substrings such as "youtube".
_gate_option_has_second_person() {
  LC_ALL=C grep -Eiq '(^|[^[:alnum:]_])(you|your|yours|yourself|yourselves)([^[:alnum:]_]|$)' <<<"${1:-}"
}

# DIVE-2848 — THE KEYSTROKE CAP ON RUBBER-STAMP GATES.
#
# lodar, 2026-08-06 04:11Z: "im fighting with unnecessary human gates for the past
# three weeks", after "im tired of rubber tapping". The policy that should have
# prevented it has been in CLAUDE.md since 2026-06-29, is unambiguous, and is
# fleet-visible. Measured over 2026-07-16..2026-08-07 anyway: of 107 human-answered
# JUDGMENT gates that carried a --recommend, 96 (90%) came back as the human tapping
# that same value. Only 7 gates in the whole window were keyword-floored to tier 2 —
# the rest of the tier-2 population is agents TYPING --tier=2 on decision, a type
# that defaults to 1. `--tier=0` was used 0 times in 346 gates.
#
# So this is not an intent problem and not a floor-heuristic problem. A policy is
# indexed by TOPIC (a bullet in a doc you read when thinking about gates); the act is
# a KEYSTROKE (you are mid-task, you type the flag). The two never meet. Same defect
# shape the filing cap already solved once: it does not ask agents to file fewer rows,
# it REFUSES at `task add` and names the exits.
#
# The rule encoded below: A GATE WHOSE RECOMMENDATION YOU ARE CONFIDENT ENOUGH TO
# WRITE IS A GATE YOU CAN TAKE. Writing --recommend is deciding; what remains is
# asking a person to agree with a decision already made, which is reassurance.
#
# DELIBERATELY OUT OF SCOPE of the refusal — each of these is a real tier 2:
#   * the T2 category floor (money / public comms / secrets / destructive). Those are
#     tier 2 on SUBJECT MATTER, the filer cannot lower them, and --discusses is their
#     own audited appeal. `tier_floored==1` excludes them here.
#   * a DECLARED --needs=human_tap|spend_authority|secret_provision (DIVE-2241) — that
#     names a capability the filer does not hold, which is the honest hard gate.
#   * manual / secret / access, which are tier 2 by TYPE. Those defaults are the other
#     half of this ticket and are NOT touched here: on --type=secret a tier-2 default
#     is correct and must stay permanent.
#
# _gate_tapback_stats <filer> — this filer's recent rubber-stamp rate over their own
# last _GATE_TAPBACK_WINDOW human-answered judgment gates that carried a
# recommendation. Prints "<taps> <total>"; prints "0 0" on any error, i.e. FAIL-OPEN,
# because the instance-level cap is the enforcing rail and a measurement that cannot
# run must not become a block nobody can explain.
#
# The tap test is SEMANTIC, not string equality, and that is load-bearing. This
# ticket's first measurement read 45% because it compared need_answer to recommend
# with `=`: on an approval the human's tap normalises to 'approved' while the
# recommendation is free text ("approve", "Push it", ...), so 45 of 47 genuine taps
# scored as overrides. lodar caught it himself ("i tap on recs much more... more like
# 98%"). The denominator is judgment gates WITH a recommendation only — manual /
# secret / access carry nothing to tap back, and mixing them in dilutes precisely the
# number being acted on.
_GATE_TAPBACK_WINDOW=20      # M — the filer's own last M answered judgment gates
_GATE_TAPBACK_MIN=8          # below this a share is noise, not a pattern
_GATE_TAPBACK_MAX_TAPS=10    # N — refuse the escape above N taps within the window
_gate_tapback_stats() {
  local who="$1" out=""
  [[ -n "$who" ]] || { printf '0 0'; return 0; }
  out=$(db "SELECT COALESCE(SUM(tap),0)||' '||COUNT(*) FROM (
        SELECT CASE
          WHEN need_type='decision'
               AND lower(trim(need_answer))=lower(trim(recommend)) THEN 1
          WHEN need_type='approval'
               AND lower(trim(need_answer)) LIKE 'approv%'
               AND lower(trim(recommend)) NOT LIKE 'den%'
               AND lower(trim(recommend)) NOT LIKE 'reject%'
               AND lower(trim(recommend)) NOT LIKE 'no%' THEN 1
          WHEN need_type='approval'
               AND (lower(trim(need_answer)) LIKE 'den%' OR lower(trim(need_answer)) LIKE 'reject%')
               AND (lower(trim(recommend)) LIKE 'den%' OR lower(trim(recommend)) LIKE 'reject%'
                    OR lower(trim(recommend)) LIKE 'no%') THEN 1
          ELSE 0 END AS tap
        FROM tasks
        WHERE gate_filed_by=$(sqlq "$who")
          AND need_type IN ('decision','approval')
          AND recommend IS NOT NULL AND trim(recommend) <> ''
          AND need_answer IS NOT NULL
          AND need_answered_by LIKE 'human:%'
        ORDER BY COALESCE(need_asked_at, updated_at) DESC
        LIMIT ${_GATE_TAPBACK_WINDOW});" 2>/dev/null) || out=""
  [[ "$out" =~ ^[0-9]+\ [0-9]+$ ]] || out='0 0'
  printf '%s' "$out"
}

cmd_task_need() {
  tasks_db_init
  local type="" ask="" options="" recommend="" from="" tier="" secret_key="" connector="" probe="" withdraw="" discusses="" needs="" oob="" rubber_stamp="" gate_mode=""
  # DIVE-2627: which flag supplied each prose value (see _read_prose_file).
  local ask_src="" recommend_src=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type=*)      type="${1#*=}" ;;
      --ask=*)       _prose_flag_dupe --ask "$ask_src"; ask="${1#*=}"; ask_src="--ask" ;;
      # DIVE-2627: the ask read VERBATIM from a file. This is the WORST member of
      # the class to corrupt: it is a permanent gate record AND the text a HUMAN is
      # paged to read, with no reader present at the file to notice the missing
      # words. A gate that asks half a question gets half an answer.
      --ask-file=*)  _prose_flag_dupe --ask-file "$ask_src"
                     _read_prose_file --ask-file "${1#*=}"
                     ask="$_PROSE_FILE_VALUE"; ask_src="--ask-file" ;;
      --options=*)   options="${1#*=}" ;;
      --recommend=*) _prose_flag_dupe --recommend "$recommend_src"; recommend="${1#*=}"; recommend_src="--recommend" ;;
      # DIVE-2627: the recommendation read VERBATIM from a file — it is what the
      # owner sees FIRST on the gate, so a hole in it steers the answer.
      --recommend-file=*) _prose_flag_dupe --recommend-file "$recommend_src"
                          _read_prose_file --recommend-file "${1#*=}"
                          recommend="$_PROSE_FILE_VALUE"; recommend_src="--recommend-file" ;;
      --tier=*)      tier="${1#*=}" ;;
      --from=*)      from="${1#*=}" ;;
      # DIVE-1401: withdraw a still-pending gate the team ITSELF filed but that is
      # now moot (e.g. a secret gate for fixtures never needed). This is NOT a
      # grant — it never records a secret/approval as provided — so it is safe for
      # the gate's filer or an org lead to run without a human tap. See branch below.
      --withdraw)    withdraw=1 ;;
      # DIVE-931 secure credential drop: name WHERE a secret gate's value lands.
      # Both together enable the burnable drop link in the gate message.
      --secret-key=*) secret_key="${1#*=}" ;;
      --connector=*)  connector="${1#*=}" ;;
      # DIVE-2411: the explicit opt-in to out-of-band delivery, and it must NAME
      # the channel. A secret gate with no drop target used to be the DEFAULT
      # (both flags omitted) — see the refusal below.
      --out-of-band=*) oob="${1#*=}" ;;
      # DIVE-1243: opt-in self-check for --type=access. The command MUST FAIL
      # (non-zero) for the gate to file; if it SUCCEEDS the block isn't real.
      --probe=*)     probe="${1#*=}" ;;
      # DIVE-2089: declare that this DECISION gate DISCUSSES a floored category
      # rather than performing it, with the reason. See the class comment above
      # _GATE_FLOOR_APPEALABLE_RX — decision-type only, floor-over-fire only,
      # non-appealable core excepted, lead-routed, audited.
      --discusses=*) discusses="${1#*=}" ;;
      # DIVE-2241: DECLARE the capability this ask consumes. Declared, never
      # inferred — inferring it from --type or from the ask text would be the
      # DIVE-2089 mistake one layer up (reading subject matter to guess intent).
      --needs=*)     needs="${1#*=}" ;;
      # DIVE-2848: the AUDITED exception to the keystroke cap below. Declared,
      # never inferred, and written to the gate row — an escape that leaves no
      # record is `--tier=2` with extra steps, which is the thing being fixed.
      --rubber-stamp-ok=*) rubber_stamp="${1#*=}" ;;
      # DIVE-2354: WHICH ORDER this gate is in. Declared, never inferred — the
      # filer is the only party who knows whether the action has already happened,
      # and inferring it from timestamps would be a guess presented as a record.
      --mode=*)      gate_mode="${1#*=}" ;;
      --)          shift; positional+=("$@"); break ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           positional+=("$1") ;;
    esac
    shift
  done
  # DIVE-2848: the FILER'S OWN --recommend, captured before anything can write to
  # `recommend`. The cap below refuses a hand-typed tier 2 on the premise "you wrote
  # a recommendation, so you already decided" — and by the time the cap runs,
  # `recommend` may have been PREFILLED from a precedent (OSS-11/OSS-20/OSS-21) that
  # the filer never typed. Keying the cap on the post-prefill variable would refuse a
  # gate for a decision the machine made on the filer's behalf, which inverts the
  # rule. Caught by tests/gate_precedent_unit.sh A5, whose fixture passes no
  # --recommend at all and was refused anyway.
  local recommend_arg="$recommend"
  [[ ${#positional[@]} -gt 0 ]] || fail "$E_USAGE" "usage: 5dive task need <id> --type=decision|secret|approval|manual|access --ask=\"...\"  (flags: 5dive task --help)"
  resolve_task_id "${positional[0]}"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"


  # DIVE-1401: --withdraw path. Secret/approval/manual gates are human-only to
  # CLEAR by deliberate security scope (an agent can't fake a secret grant). But
  # WITHDRAWING a still-pending request the team itself filed is not a grant — it
  # cancels a moot gate and unblocks the task WITHOUT ever writing need_answer /
  # need_answered_at, so no secret is recorded as provided. Allowed for the gate's
  # FILER (assignee of record, set at file time), the filer's routed lead /
  # coordinator, or a human caller (non-agent unix id). Genuine GRANT-clears stay
  # human-only via cmd_task_answer — this branch never touches that path.
  if [[ -n "$withdraw" ]]; then
    [[ -z "$type$ask$options$recommend$tier$secret_key$connector$oob$probe$discusses$needs" ]] \
      || fail "$E_USAGE" "--withdraw takes no other gate flags (it cancels the existing gate, not re-files one)"
    local w_type w_ans w_status
    w_type=$(db "SELECT COALESCE(need_type,'')        FROM tasks WHERE id=${id};")
    w_ans=$(db  "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${id};")
    w_status=$(db "SELECT status FROM tasks WHERE id=${id};")
    [[ "$w_status" == "done" || "$w_status" == "cancelled" ]] \
      && fail "$E_CONFLICT" "$ident is $w_status — nothing to withdraw"
    [[ -n "$w_type" ]] || fail "$E_CONFLICT" "$ident has no gate to withdraw"
    [[ -z "$w_ans" ]]  || fail "$E_CONFLICT" "$ident's gate is already answered — --withdraw only applies to a still-pending gate (need_answered_at IS NULL)"
    # Authorize on the TRUSTED caller identity from _gate_withdraw_actor (EUID-gated
    # SUDO_* or the real id -un — see its comment), NEVER on --from. The gate's FILER OF
    # RECORD, their routed lead, or the org coordinator may withdraw, as may a genuine
    # human. An agent that is none of these is refused.
    #
    # DIVE-2382 (approved by olivia as org coordinator; main ruled the shape): this site
    # used to authorize on COALESCE(assignee,'') — the HOLDER. That was the bigger half of
    # the defect this ticket was filed about, and it was wrong in BOTH directions at once:
    #   under-permissive — an agent who files a gate on someone else's task could not
    #                      withdraw their OWN ask (DIVE-2015: gate_filed_by=codex,
    #                      assignee=main, so main could and codex could not);
    #   over-permissive  — a reassigned holder could retire a question they never asked,
    #                      which is precisely the DIVE-2133 shape.
    # A fifth authorizer would have fixed only the first, so this REPLACES the principal.
    #
    # THE SHAPE IS DELIBERATELY STRICTER THAN :6154's, which is the one amendment olivia
    # made to the proposal. :6154 (display/routing) ends its COALESCE on `assignee`;
    # authorizing on that would silently RE-ADMIT the reassigned-holder route in exactly
    # the state where both other columns are empty — the route we are removing. So the
    # authorization site stops at created_by. Two shapes for two jobs, deliberately: the
    # display readers keep their assignee rung, and what this ticket retires is THREE
    # shapes for ONE job. Authorizer-existence does not rest on that rung anyway —
    # conditions 1 (human) and 4 (coordinator) never consult the filer at all, probed
    # against an all-columns-empty row.
    local w_filer w_id w_kind w_name="" w_lead w_coord w_ok=0 w_holder w_who
    w_filer=$(db "SELECT COALESCE(NULLIF(gate_filed_by,''),NULLIF(created_by,''),'') FROM tasks WHERE id=${id};")
    # The HOLDER, for the refusal text only — it no longer authorizes anything. Named
    # when it differs so a refused holder learns why, rather than reading a list that
    # simply omits them.
    w_holder=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${id};")
    w_id=$(_gate_withdraw_actor)                          # "agent <name>" | "human" | "none"
    w_kind="${w_id%% *}"
    [[ "$w_kind" == "agent" ]] && w_name="${w_id#agent }"
    # The lead route follows the PRINCIPAL, so it moves with it: condition 3 is "the
    # filer's lead", and resolving it from the holder would leave a second copy of the
    # same defect one rung up.
    w_lead=$(_gate_route_reviewer "$w_filer")
    w_coord=$(_task_resolve_coordinator)
    [[ "$w_kind" == "human" ]] && w_ok=1                                    # a genuine human caller
    [[ -n "$w_name" && "$w_name" == "$w_filer" ]] && w_ok=1                # the filer
    [[ -n "$w_name" && -n "$w_lead"  && "$w_name" == "$w_lead"  ]] && w_ok=1  # filer's lead
    [[ -n "$w_name" && -n "$w_coord" && "$w_name" == "$w_coord" ]] && w_ok=1  # org coordinator
    # DIVE-2382: name EVERY identity the block above actually walked, with its resolved
    # value. The old text named only "the gate's filer, their lead, or a human" and
    # silently dropped the org coordinator — a FILER-INDEPENDENT condition — so a caller
    # who WAS the coordinator, and was authorized, read a message saying they were not.
    # Two agents independently concluded from that text that DIVE-2106 could never be
    # retired; both were wrong, and that is the mechanism behind the stale-gate class.
    # Unresolvable conditions render as "none" rather than vanishing, so a reader can
    # tell "this route does not exist here" from "this route was never offered".
    # DIVE-2382: "unrecorded" rather than "?" — the placeholder shipped in the first pass
    # and reads as a rendering bug rather than as a fact about the row (olivia approved
    # the swap in the same pass). An empty principal is reachable by CONFIGURATION, not by
    # data: created_by is nullable, so a row with neither column set resolves to nothing,
    # and the reader needs to see that as a stated absence.
    w_who="the gate's filer (${w_filer:-unrecorded})"
    [[ -n "$w_holder" && "$w_holder" != "$w_filer" ]] && w_who+=" — held by ${w_holder}, who does NOT authorize a withdraw since they did not file it"
    (( w_ok )) || policy_refuse "$E_AUTH_REQUIRED" gate-withdraw-not-authorized DIVE-1401 "$ident" "only ${w_who}, their lead (${w_lead:-none}), the org coordinator (${w_coord:-none}) or a human can withdraw this gate"
    # Clear every gate field and unblock back to todo when no dependency edge
    # still holds it. The withdrawn gate is archived to gate_history first, in
    # the same transaction (DIVE-2119).
    #
    # DIVE-2119: this comment used to read "Clear every gate field (NEVER
    # need_answer/need_answered_at — this is not a grant)" while the UPDATE it
    # sits on cleared 12 fields and left need_answered_by / need_answered_uid /
    # need_answer_sig standing — so a withdrawn gate left orphaned answer
    # provenance behind (13 of the 21 rows DIVE-2094 measured were this path and
    # `task park`). Two things were wrong with the old wording: it claimed a
    # completeness it did not have, and its parenthetical is backwards — the
    # answer columns ARE nulled here (a withdrawal records no grant, which is the
    # property it was reaching for). Both are now true: _gate_archive_and_clear_sql
    # resets all six provenance columns, so no answer or answerer survives a
    # withdrawal, and the outgoing gate is preserved in gate_history instead.
    db "BEGIN IMMEDIATE;
        $(_gate_archive_and_clear_sql withdraw "id=${id}")
        UPDATE tasks
          SET need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL,
              -- DIVE-2354: same reason as the park path — a withdrawn gate has no
              -- order to report, and the archive row above already carries it.
              gate_mode=NULL,
              secret_key=NULL, connector=NULL, secret_oob=NULL, ask_shape=NULL,
              precedent_ref=NULL, precedent_kind=NULL, routed_reviewer=NULL,
              needs_capability=NULL,
              -- DIVE-2615: a withdrawn gate has no tier, so it must not keep
              -- reporting why it had one. The archive above already copied this
              -- value onto the history row, which is where it belongs afterwards.
              floor_provenance=NULL,
              need_asked_at=NULL, gate_pinged_at=NULL, gate_filed_by=NULL
        WHERE id=${id};
        UPDATE tasks SET status='todo'
          WHERE id=${id} AND status='blocked'
            AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id});
        COMMIT;"
    # DIVE-2054: DELIBERATELY UNFENCED. Carries asserted_from=, the identity-assertion
    # audit trail red-teamed on DIVE-1401 — a fixture store must never be able to
    # suppress it (fencing here would trade a contamination bug for an
    # evidence-suppression bug, the DIVE-1968 fail-open family). See DIVE-2054 wiki.
    audit_log "task need withdraw" "ok" 0 -- "task=$ident" "type=$w_type" "by=${w_name:-$w_kind}" "asserted_from=${from:-}" || true
    # DIVE-2410: a withdrawn gate is a settled gate from the human's side — the
    # question is gone, so the button must go with it. A withdrawal is the path
    # most likely to leave a stale button standing, because unlike an answer
    # nothing about it ever reaches the human's chat.
    _task_gate_retire_buttons "$ident" "withdrawn by ${w_name:-$w_kind}" || true
    local w_new; w_new=$(db "SELECT status FROM tasks WHERE id=${id};")
    ok "$ident gate withdrawn (${w_type}) — moot request cleared, no secret/grant recorded; task now ${w_new}" \
       '{ident:$id, withdrawn:true, was_type:$wt, status:$st}' \
       --arg id "$ident" --arg wt "$w_type" --arg st "$w_new"
    return
  fi

  valid_need_type "$type" || fail "$E_VALIDATION" "bad --type '$type' (decision|secret|approval|manual|access)"
  [[ -n "$ask" ]] || fail "$E_USAGE" "--ask is required (what does the human need to provide?)"

  # DIVE-2089: --discusses is a DECISION-only appeal. approval / manual / secret /
  # access declare an ACTION by construction, so "I'm only discussing it" is not a
  # coherent claim on them — refuse rather than accept-and-ignore, so a filer can
  # never believe an appeal applied when it did not. Rule 1 of the four-deep safety
  # model above; it is also what keeps this change unable to regress the
  # DIVE-2146 self-restart APPROVAL gate.
  if [[ -n "$discusses" ]]; then
    [[ "$type" == "decision" ]] \
      || fail "$E_VALIDATION" "--discusses only applies to --type=decision — a $type gate requests an ACTION; re-file it as --type=decision"
    [[ ${#discusses} -ge 12 ]] \
      || fail "$E_VALIDATION" "--discusses must state WHY this gate discusses rather than performs — it is shown to the reviewer who clears it"
  fi
  # DIVE-2848: --rubber-stamp-ok is the audited exception to the keystroke cap
  # further down. Same shape as --discusses on purpose: declared by the filer,
  # required to have substance, recorded on the row, and REFUSED where it would be
  # meaningless rather than silently ignored.
  if [[ -n "$rubber_stamp" ]]; then
    [[ "$type" == "decision" || "$type" == "approval" ]] \
      || fail "$E_VALIDATION" "--rubber-stamp-ok only applies to --type=decision or --type=approval — those are the two types the keystroke cap governs. manual/secret/access default to tier 2 by TYPE and need no escape from it."
    [[ ${#rubber_stamp} -ge 12 ]] \
      || fail "$E_VALIDATION" "--rubber-stamp-ok must state WHY a person has to answer this despite your own --recommend (it is recorded on the gate and read by whoever counts these exceptions later)"
  fi

  # DIVE-2354 — THE TWO ORDERS A GATE CAN BE IN, as data on the row.
  #
  # THE DEFECT, measured on the first run of the DIVE-2348 customer-feedback loop:
  # a gate worded "lodar approves the reply BEFORE it is sent" cannot be satisfied
  # honestly once the send has already happened (emails 13:27/13:30, loop fired the
  # drafting step 13:40). Answering it asserts a before-the-fact approval that did
  # not occur; cancelling it erases the decision point AND, on that run, deleted
  # marketing's escalation path for a genuinely unapproved second email; leaving it
  # open reads as a bypassed human. Nobody bypassed anyone and the record said
  # somebody had. It recurs by construction: these loops race a LIVE Telegram
  # thread, so a loop materialised from the board is routinely behind the
  # conversation. That is the normal case for anything customer-facing, not a
  # timing accident.
  #
  # THE FIX IS A THIRD STATE, not a new verb. `confirm-after-send` records that the
  # tap came AFTER the action — a RATIFICATION. It is not "approved" and must never
  # render as it (same shape as unreadable-vs-absent, DIVE-2327, and NOT-REACHED-vs-
  # pass, DIVE-2039). NULL is the third value: a gate filed before this shipped
  # does not say which order it was, and inferring one for it would manufacture the
  # very claim this ticket is about.
  #
  # WHAT THIS DOES NOT DO, deliberately: nothing here clears anything. The human tap
  # stays mandatory in BOTH modes. `confirm-after-send` is `--type=approval` only —
  # approval is human-class (root-gated in cmd_task_answer, excluded from precedent
  # auto-clear by _gate_human_class), so restricting the mode to it makes
  # "ratification requires a person" true BY CONSTRUCTION rather than by a rule
  # someone has to keep. A `decision` that already happened re-files as an approval;
  # that is the same direction [[standing-authorisation-is-per-thread-dive2353]]
  # already prescribes for an answer that licenses something.
  if [[ -n "$gate_mode" ]]; then
    case "$gate_mode" in
      approve-to-send|confirm-after-send) ;;
      *) fail "$E_VALIDATION" "bad --mode '$gate_mode' (approve-to-send|confirm-after-send)" ;;
    esac
    [[ "$type" == "approval" ]] \
      || fail "$E_VALIDATION" "--mode only applies to --type=approval — a $type gate has no before/after order to record. If the action already happened and you need it ratified, re-file it as --type=approval --mode=confirm-after-send (a ratification must be a human tap, and approval is the type that guarantees one)."
    # A tier-0 gate APPLIES the filer's own --recommend with no ping. On a
    # confirm-after-send that is auto-ratification of an action the filer already
    # took — precisely the thing this ticket says it is NOT asking for. Refused
    # here rather than relying on approval's tier-2 type default, so the guarantee
    # does not depend on a default someone may later think is a formality.
    [[ "$tier" == "0" && "$gate_mode" == "confirm-after-send" ]] \
      && fail "$E_VALIDATION" "--tier=0 auto-applies your own recommendation, which on --mode=confirm-after-send would ratify an action you have already taken with no human involved. A ratification needs the tap; file it at the type default."
  fi

  # DIVE-1243: self-check for the manager-clearable `access` class. An access gate
  # claims "I'm blocked on a grant a teammate can give" — but a FALSE block (codex
  # DIVE-1234 filed 'grant me wiki write access' when it ALREADY had it) wastes a
  # lead ping. --probe=<cmd> is an opt-in real self-check run AS the filing agent:
  # it MUST FAIL (non-zero) for the gate to file; if it SUCCEEDS the access already
  # works, so we refuse. With no --probe we still NUDGE (never hard-block — the
  # probe can't be expressed for every kind of block).
  if [[ -n "$probe" ]]; then
    [[ "$type" == "access" ]] || fail "$E_VALIDATION" "--probe only applies to --type=access"
    if bash -c "$probe" >/dev/null 2>&1; then
      fail "$E_CONFLICT" "self-check passed (\`$probe\` succeeded) — you already have this access; re-check the real blocker"
    fi
  elif [[ "$type" == "access" ]]; then
    warn "--type=access filed without --probe — confirm you actually tested the block (e.g. --probe='test -w /path'). False blocks (DIVE-1234) waste a lead ping."
  fi
  # Options are the choice list for a decision; reject them on the other types
  # so the gate shape stays honest for the dashboard. (An approval gate is
  # deliberately approved/denied only — the plugin tap handler resolves no
  # option index for it; see DIVE-560 note in _task_loop_advance.)
  if [[ -n "$options" && "$type" != "decision" ]]; then
    fail "$E_VALIDATION" "--options only applies to --type=decision"
  fi
  # DIVE-2074: a decision gate on a branch-bound (delegated-push) task is a trap —
  # `5dive push` only accepts a decision answer from the gate's OWN routed reviewer
  # (matching invoker uid) or a human/lead stamp; a lead who answers on someone
  # else's behalf (e.g. the org lead clearing a decision routed to a named
  # reviewer) stamps as a bare agent name, which push refuses. That refusal lands
  # on the PUSHER, one step after the lead believed they'd unblocked the work (see
  # DIVE-2073/DIVE-2004). Surface the trap at FILE time, while --type can still be
  # changed, instead of after an unusable answer is already recorded.
  if [[ "$type" == "decision" ]]; then
    local _need_body _need_branch
    _need_body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
    _need_branch=$(_push_branch_from_body "$_need_body")
    if [[ -n "$_need_branch" ]]; then
      warn "$ident is branch-bound (Branch: ${_need_branch}) — a --type=decision gate only authorizes 'push' when answered by ITS OWN routed reviewer; a lead clearing it on someone else's behalf will NOT satisfy push (DIVE-2073). If this gate is meant to unblock a delegated push, file --type=approval instead."
    fi
  fi
  # DIVE-931: --secret-key / --connector name the drop target and only make sense
  # on a secret gate. Require them together (a key with no connector has nowhere
  # to land, and vice versa) and validate against the same charsets the box-side
  # `secret write` + the api /drop/mint enforce, so a bad value fails here rather
  # than at mint time.
  #
  # DIVE-2411: both omitted used to mean "legacy secret gate, out-of-band
  # delivery" — a DEFAULT nobody chose. Measured on DIVE-2232: the gate pinged
  # correctly, the ask read as complete, and there was NO PATH for the value to
  # reach the box, so the only remaining answer was pasting a live credential
  # into a persistent chat log. main nearly received one.
  #
  # WHY THE REFUSAL BELONGS AT FILING TIME. The gate is complete in APPEARANCE and
  # only the delivery MECHANISM is missing. A human staring at the ask cannot see
  # that the drop is absent — nothing in the message is about the drop. Only the
  # filer can see it, and only here. So an omission must not select the shape with
  # no delivery path: name a drop target (DIVE-931) or declare the out-of-band
  # channel explicitly.
  # DIVE-2411: a RE-FILE inherits the delivery path the row already carries. A
  # re-file otherwise DESTROYS it (DIVE-2119 resets the gate columns from the
  # flags given), and the programmatic re-filers pass no delivery flags at all:
  # the council escalation builds `task need <ident> --type=secret --tier=2
  # --ask=...` (src/council/engine.mjs, preserving the TYPE and nothing else). So
  # before this ticket, escalating a properly-targeted secret gate through the
  # council silently converted it into the DIVE-2232 shape — the defect had a
  # generator, not just an author. Inheriting is not "defaulting into no delivery
  # path": it carries forward a path a filer CHOSE, and a row with nothing to
  # inherit still falls through to the refusal below.
  if [[ "$type" == "secret" && -z "$secret_key$connector$oob" ]]; then
    local _pv; _pv=$(db "SELECT COALESCE(secret_key,'')||x'1f'||COALESCE(connector,'')||x'1f'||COALESCE(secret_oob,'') FROM tasks WHERE id=${id};")
    local _pv_sk="${_pv%%$'\x1f'*}" _pv_rest="${_pv#*$'\x1f'}"
    local _pv_conn="${_pv_rest%%$'\x1f'*}" _pv_oob="${_pv_rest#*$'\x1f'}"
    if [[ -n "$_pv_sk" && -n "$_pv_conn" ]]; then
      secret_key="$_pv_sk"; connector="$_pv_conn"
      warn "$ident: re-filed secret gate inherits the existing drop target (${secret_key} -> ${connector}); pass --secret-key/--connector to change it (DIVE-2411)"
    elif [[ -n "$_pv_oob" ]]; then
      oob="$_pv_oob"
      warn "$ident: re-filed secret gate inherits the declared out-of-band delivery (${oob}); pass --secret-key/--connector for a drop target instead (DIVE-2411)"
    fi
  fi
  if [[ -n "$oob" ]]; then
    [[ "$type" == "secret" ]] \
      || fail "$E_VALIDATION" "--out-of-band only applies to --type=secret (it declares how a CREDENTIAL will reach the box)"
    [[ -z "$secret_key$connector" ]] \
      || fail "$E_VALIDATION" "--out-of-band is mutually exclusive with --secret-key/--connector — a gate has ONE delivery path"
    # Must NAME the channel: the whole point is that the human (and the reader of
    # the answered row six months out) can see where the value was meant to land.
    # A bare "yes" opt-in would restore the defect with a flag in front of it.
    [[ ${#oob} -ge 12 ]] \
      || fail "$E_VALIDATION" "--out-of-band must NAME where the value will land (e.g. \"already in my .env on this box\") — the human is shown it"
  elif [[ "$type" == "secret" && -z "$secret_key$connector" ]]; then
    fail "$E_VALIDATION" "a secret gate must name a delivery path — pass --secret-key=<ENV> --connector=<stem>, or --out-of-band=\"<where>\""
  fi
  if [[ -n "$secret_key" || -n "$connector" ]]; then
    [[ "$type" == "secret" ]] || fail "$E_VALIDATION" "--secret-key/--connector only apply to --type=secret"
    [[ -n "$secret_key" && -n "$connector" ]] \
      || fail "$E_VALIDATION" "--secret-key and --connector must be given together (both name the drop target)"
    [[ "$secret_key" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] \
      || fail "$E_VALIDATION" "invalid --secret-key '$secret_key' (env-var name: ^[A-Z][A-Z0-9_]{0,63}\$)"
    [[ "$connector" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] \
      || fail "$E_VALIDATION" "invalid --connector '$connector' (^[a-z0-9][a-z0-9-]{0,63}\$)"
  fi
  # DIVE-148: --recommend surfaces the agent's advised choice first in the human
  # alert (and ⭐-marks its button). Only meaningful for the two finite-choice
  # gate types; reject it elsewhere so the gate shape stays honest. For a
  # decision it MUST be one of --options (same split rule as the buttons:
  # split '|', trim, drop empties) or a tapped/displayed recommend wouldn't
  # match any real option. For approval it's free text (e.g. approved/denied).
  if [[ -n "$recommend" ]]; then
    case "$type" in
      decision)
        [[ -n "$options" ]] || fail "$E_VALIDATION" "--recommend on a decision needs --options to match against"
        local _match
        _match=$(printf '%s' "$options" | jq -Rr --arg r "$recommend" '
          [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ]
          | (($r | gsub("^\\s+|\\s+$"; "")) as $rr | any(.[]; . == $rr)) | tostring' 2>/dev/null) || _match="false"
        [[ "$_match" == "true" ]] || fail "$E_VALIDATION" "--recommend \"$recommend\" must match one of --options ($options)"
        ;;
      approval) : ;;
      *) fail "$E_VALIDATION" "--recommend only applies to --type=decision or --type=approval" ;;
    esac
  fi
  local cur; cur=$(db "SELECT status FROM tasks WHERE id=${id};")
  [[ "$cur" == "done" || "$cur" == "cancelled" ]] \
    && fail "$E_CONFLICT" "$ident is $cur — reopen it before gating on a human"

  # DIVE-891: resolve the gate's risk tier (adopted DIVE-861 design).
  #   0 = auto-clear: the recommendation applies immediately, no ping, digest line
  #   1 = agent-clearable; 48h unanswered -> the heartbeat TTL sweep applies the rec
  #   2 = hard human gate: never auto-applies, TTL only batches reminder pings
  # Defaults by type when --tier is omitted: decision/approval -> 1 (agents
  # legitimately resolve these; "approve this ship/close/commit" is the most
  # common builder gate and the human blanket-cleared them in practice), manual/
  # secret -> 2. Explicit --tier can lower an approval/decision/manual gate,
  # EXCEPT: a secret gate is always tier 2, and the T2 category floor below
  # overrides everything (money/public-comms/secrets/destructive still
  # route to a human regardless of this default — see _gate_tier2_floor_hit).
  # DIVE-1284: default 'approval' to tier 1 too — the old default sent the bulk
  # of delegatable ship/close/commit approvals straight to the paired human.
  # DIVE-1182: remember whether --tier was EXPLICIT (a caller's hard-human
  # contract) vs. only the type default. manual/secret default to tier 2, so the
  # effective tier alone can't tell "builder ship-gate" from "caller pinned
  # hard-human"; the routing predicate below needs the explicit signal.
  local tier_arg="$tier"
  if [[ -n "$tier" ]]; then
    [[ "$tier" == "0" || "$tier" == "1" || "$tier" == "2" ]] \
      || fail "$E_VALIDATION" "bad --tier '$tier' (0=auto-clear | 1=48h-TTL-applies-rec | 2=hard human gate)"
  else
    case "$type" in decision|approval) tier=1 ;; *) tier=2 ;; esac  # DIVE-1284
  fi
  local tier_floored=0
  local _floored_by_title=0 _floor_axis=none _ft_title=""   # DIVE-2224
  # DIVE-2615: WHY this gate has the tier it has, recorded at the moment it is
  # decided. Every input below is computed here and then thrown away, so the store
  # could say a gate was tier 2 and never say what made it tier 2 — floor_provenance
  # was NULL on all 79 gate_history rows because nothing has ever written it.
  # Answering "how many of tonight's human pings were the floor over-firing?" needed
  # a bundle rig sourcing this file's predicates against asks re-read from the store,
  # two of my attempts at which were void. That is a question the store should
  # answer, and after this it does.
  #
  # NULL vs 'axis=none' IS THE WHOLE POINT and they are not the same fact. NULL means
  # this build never recorded it (a pre-DIVE-2615 row). 'axis=none' means the floor
  # RAN and did not fire. Conflating them is exactly what made the existing column
  # unusable — an empty value that means both "no data" and "no hit" measures nothing.
  local _floor_prov=""
  if [[ "$tier" == "2" ]]; then
    # Tier 2 BEFORE the floor is consulted, and the two ways of getting there are
    # different facts about different people, so they get different values.
    # `pinned` is the caller's explicit --tier=2 — a LARGE population (12 of the 48
    # tier-2 gates that pinged the human in the 7 days to 2026-08-03) and invisible
    # from the row today, which makes the filer's own choice read as the
    # classifier's doing. `type-default` is manual/secret/access, where 2 is the
    # type's default and nobody chose anything. Reading `tier_arg`, not `tier`, is
    # what separates them: by this line the type default has already been applied,
    # so the effective tier cannot tell them apart — the same distinction DIVE-1182
    # captured `tier_arg` for two lines above.
    if [[ "$tier_arg" == "2" ]]; then _floor_prov="axis=pinned"; else _floor_prov="axis=type-default"; fi
  fi
  if [[ "$tier" != "2" ]]; then
    if [[ "$type" == "secret" ]]; then
      tier=2; tier_floored=1
      _floor_prov="axis=secret-type"
    else
      local ttl_title; ttl_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
      # DIVE-2224: per-field, never the join; and the ASK is the subject (answer A).
      _floor_axis=$(_gate_floor_axis "$ask" "$ttl_title")
      local _floor_term=""
      case "$_floor_axis" in
        ask)  _floor_term=$(_gate_tier2_floor_term "$ask" 2>/dev/null) || _floor_term="" ;;
        title|title-fallback)
          _floor_term=$(_gate_tier2_floor_term "$ttl_title" 2>/dev/null) || _floor_term="" ;;
      esac
      _floor_prov="axis=${_floor_axis}${_floor_term:+;term=${_floor_term}}"
      case "$_floor_axis" in
        ask) tier=2; tier_floored=1 ;;
        title-fallback)
          tier=2; tier_floored=1
          warn "gate floored on the TITLE because the ask states nothing of its own ('${ask}'). A self-contained ask is the standing rule; the floor fails closed rather than trust a filing whose only statement of the request is the ticket title."
          ;;
        title)
          # Not floored. The reviewer is told WHY in one line so 'this ticket is
          # about deletion' is a fact they hold, and escalating is one step.
          _floored_by_title=1; _ft_title="$ttl_title"
          warn "gate NOT floored: the tier-2 category term is in the TASK TITLE, not in the ask (DIVE-2224 answer A). Routed to the lead, stamped floored_by=title — escalate it if the ask really is asking for that."
          ;;
      esac
    fi
  fi

  # DIVE-2241: the DECLARED human-class capability. This is the sibling of the
  # keyword floor directly above — same destination, opposite epistemics. The
  # floor READS the ask and guesses ("this says 'billing', so it is probably
  # money"); `--needs` is the filer STATING what the ask consumes. A declaration
  # is the stronger signal, so it is applied AFTER the floor and simply overrides:
  # a human-class capability is tier-2 by definition (never auto-applies, always
  # reaches the person), and marking it tier_floored=1 puts it in the same bucket
  # every downstream reader already treats as true-human.
  #
  # THE DEFECT THIS CLOSES: a gate on a verifier-loop task routes to the VERIFIER
  # regardless of what is being ASKED — so "may I spend $X" landed on whichever
  # agent happened to be grading the ticket. Three instances in 36h across three
  # agents (dev3/DIVE-2084, main/DIVE-2146, olivia immediately after). The routing
  # veto is at the _routable backstop below, next to the DIVE-1957 tier-2 one, so
  # it holds against every KIND-based override by construction rather than
  # per-branch.
  #
  # FALL THROUGH, NEVER REFUSE (scope item 4): an unrecognised capability warns
  # and resolves to today's routing. A router that hard-fails on an unknown name
  # turns a mis-declared gate into a STUCK one, and the whole point of the class
  # is that a mis-declaration should cost a re-file, not a block. `--needs=`
  # (empty) is the same as absent: undeclared, never non-holding.
  local _needs_human=0
  if [[ -n "$needs" ]]; then
    if _gate_needs_human "$needs"; then
      _needs_human=1
      tier=2; tier_floored=1
    else
      warn "--needs='${needs}' is not a human-class capability, so it changes nothing about where this gate goes (routing is unchanged). The three that resolve to the paired human are: ${_GATE_HUMAN_CAPABILITIES// /, }. Agent capabilities (delegated_push, root, gh_push) are NOT routable this way yet — see DIVE-2156."
    fi
  fi

  # DIVE-1381: content-curation carve-out. Mirror of the eng-ship class (DIVE-1359)
  # for our early-stage content surfaces (OpenAgent / character-packs / the persona
  # drip). A persona/pack QUEUE-READINESS approval is lead-clearable, not a human
  # call — but the T2 floor matches 'publish' in the ask/title and forces it
  # hard-human (tier-2, unclearable by the lead), the exact wall DIVE-1366 hit.
  # Like eng-ship the routing is intrinsic to the KIND, so this fires whether or
  # not the floor tripped: a curation-shaped decision/approval from a NON-lead is
  # forced to a lead-routed tier-1 — downgrading tier-2 when the floor fired. The
  # true-human floor still WINS for a genuine publish-NOW / press /
  # customer-comms / money / secret / destructive ask: we re-test the floor with
  # only the content-publish-LATER terms stripped (_GATE_CONTENT_PUBLISH_RX — the
  # real publish happens downstream via the drip, not now) and refuse to downgrade
  # if anything else still trips it. Clearing tier_floored lets the routing
  # predicate treat it as a tier-1 gate; _curation (like _eng_ship) forces
  # lead-routing regardless of the gate_builder_routing pref. secret/manual are
  # never curation; filer-is-lead ⇒ no reviewer ⇒ not downgraded.
  # DIVE-1957: an EXPLICIT --tier=2 vetoes this downgrade (tier_arg==2). Note the
  # tier==2 short-circuit above means an explicitly-pinned gate never sets
  # tier_floored, so without this guard curation downgraded a pinned brand/money
  # ask that the floor would otherwise have caught.
  local _curation=0
  if [[ "$tier_arg" != "2" && ( "$type" == "decision" || "$type" == "approval" ) ]]; then
    local _cc_title; _cc_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
    # DIVE-2224: classify and strip PER FIELD. Building one residual from the join
    # let the publish-strip and the re-tested floor both straddle the seam.
    local _cc_res_ask _cc_res_title
    _cc_res_ask=$(printf '%s' "$ask" \
      | tr '[:upper:]' '[:lower:]' | sed -E "s/(${_GATE_CONTENT_PUBLISH_RX})//g")
    _cc_res_title=$(printf '%s' "$_cc_title" \
      | tr '[:upper:]' '[:lower:]' | sed -E "s/(${_GATE_CONTENT_PUBLISH_RX})//g")
    if _gate_hit_either _gate_content_curation_hit "$ask" "$_cc_title" \
       && ! _gate_hit_either _gate_tier2_floor_hit "$_cc_res_ask" "$_cc_res_title"; then
      # DIVE-2518: `task_actor ""` rather than `task_actor "$from"`, and the two are
      # now IDENTICAL — task_actor ignores the claim entirely. The empty argument is
      # documentation, not a fix: it says at the call site that no claim is consulted.
      #
      # THIS IS NOT THE ROUTING DECISION, despite the variable name. All four
      # `_*_reviewer` locals in this function only test whether a lead EXISTS, to
      # decide `tier=1`; the reviewer actually persisted to `routed_reviewer` is
      # computed once at the `_routable` block below from `$actor`. I changed these
      # four first believing they were the decision, and a mutant that reverted all
      # four left the T23 arm green — which is how the mistake surfaced.
      local _cc_reviewer; _cc_reviewer=$(_gate_route_reviewer "$(task_actor "")")
      if [[ -n "$_cc_reviewer" ]]; then
        tier=1; tier_floored=0; _curation=1
      fi
    fi
  fi

  # DIVE-1480: internal-ops / recovery carve-out. Same shape as content-curation
  # above: an internal control-plane decision (task board / an agent's own work /
  # a wipe recovery) is lead-clearable, but the T2 destructive floor over-fires on
  # the ask NARRATING a wipe ('destroyed'/'wiped'/'purge') and forces it hard-human
  # — the exact wall the STEER-1 keep-vs-discard gate hit (landed on lodar, not
  # Marcus). UNLIKE eng-ship/curation this fires ONLY when the floor ACTUALLY
  # over-fired (tier_floored==1): a precise fix for the over-escalation, leaving a
  # non-floored internal decision's normal tier-1 routing untouched. We re-test the
  # floor with only the INTERNAL-destructive terms stripped
  # (_GATE_INTERNAL_DESTRUCTIVE_RX); only if the ask matches the narrow internal-ops
  # class AND nothing else in the residual still trips the floor (a real prod/infra
  # destructive term — teardown / drop table / revoke / dns — or any money / secret
  # / publish term wins and stays hard-human) do we downgrade to a
  # lead-routed tier-1 so it reaches the lead, not lodar. Guarded to decision/
  # approval with a reviewer (filer-is-lead ⇒ no downgrade); runs after curation so
  # a curation-shaped ask keeps its own class.
  # DIVE-1957: explicit --tier=2 vetoes this downgrade too. (Belt-and-braces: the
  # tier==2 short-circuit above already leaves tier_floored=0 for a pinned gate,
  # so this arm was unreachable with a pin — the guard is stated so the invariant
  # survives any future change to where the floor is evaluated.)
  local _internal_ops=0
  if [[ "$tier_arg" != "2" && "$tier_floored" == "1" && "$_curation" == "0" \
        && ( "$type" == "decision" || "$type" == "approval" ) ]]; then
    local _io_title; _io_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
    # DIVE-1481: strip a destructive term only where it is CO-REFERENT to an
    # internal-ops object, not everywhere it appears — a prod-object verb survives
    # into the residual and keeps the gate hard-human.
    # DIVE-2224: run that strip PER FIELD. DIVE-1481's window is 20 characters, and
    # on the joined string it reached across the seam and manufactured a
    # co-reference present in neither text -- which STRIPS a destructive term the
    # floor should have kept, i.e. it removes a human. This is the dangerous
    # direction of the seam bug, not the annoying one.
    local _io_res_ask _io_res_title
    _io_res_ask=$(_gate_internal_residual "$ask")
    _io_res_title=$(_gate_internal_residual "$_io_title")
    if _gate_hit_either _gate_internal_ops_hit "$ask" "$_io_title" \
       && ! _gate_hit_either _gate_tier2_floor_hit "$_io_res_ask" "$_io_res_title"; then
      local _io_reviewer; _io_reviewer=$(_gate_route_reviewer "$(task_actor "")")   # DIVE-2518: tier-flag only; see note above
      if [[ -n "$_io_reviewer" ]]; then
        tier=1; tier_floored=0; _internal_ops=1
      fi
    fi
  fi

  # DIVE-2089: the DECLARED-DISCUSSION appeal. Runs after the three inferring
  # classes so an ask that already qualifies as curation / internal-ops keeps its
  # own class (and needs no declaration). Structure is DIVE-1480's — fires only on
  # an ACTUAL over-fire, re-tests the floor on a residual, requires a reviewer,
  # downgrades to a LEAD-routed tier-1 — with one deliberate difference: the class
  # membership is DECLARED by the filer, not guessed from vocabulary. See the
  # comment block on _GATE_FLOOR_APPEALABLE_RX for why that inversion is the whole
  # point of the ticket.
  # Every refusal path below is LOUD. A silently-ignored appeal would reproduce
  # defect 2 (the escalation nobody sees) one layer up.
  local _discusses_applied=0
  if [[ -n "$discusses" ]]; then
    if [[ "$tier_arg" == "2" ]]; then
      # DIVE-1957: an explicit pin is the caller's hard-human contract and vetoes
      # every downgrade class. Nothing to appeal — the floor never even ran.
      warn "--discusses ignored: you pinned --tier=2, which is a hard-human contract and outranks the appeal. Drop the pin to appeal the floor."
    elif [[ "$tier_floored" != "1" ]]; then
      warn "--discusses ignored: the T2 category floor did not fire on this gate (tier $tier), so there is nothing to appeal."
    elif [[ "$_curation" == "1" || "$_internal_ops" == "1" ]]; then
      : # already downgraded by its own class; the declaration is recorded below
    else
      local _dd_title; _dd_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
      # DIVE-2224: appeal residual is computed PER FIELD too — a phantom seam match
      # here would REFUSE a legitimate appeal, naming a term neither text contains.
      local _dd_res_ask _dd_res_title
      _dd_res_ask=$(_gate_floor_appeal_residual "$ask")
      _dd_res_title=$(_gate_floor_appeal_residual "$_dd_title")
      if _gate_hit_either _gate_tier2_floor_hit "$_dd_res_ask" "$_dd_res_title"; then
        # Rule 3: a non-appealable class (money / real comms / irreversible infra)
        # is present. Name the surviving term so the refusal is actionable rather
        # than mysterious — the filer can see it is not the word they meant.
        # DIVE-2751 iteration 4 (main2): TWO defects on the one line this replaces.
        # `$_dd_residual` occurred exactly ONCE in the whole repo — here — so it
        # has never held a value: under `set -u` the substitution died "unbound
        # variable" and the plain assignment inherited its rc, aborting `task need`
        # with no message on the Rule 3 path. And the term must be read off the
        # residual that ACTUALLY hit; concatenating the two would re-open the
        # phantom seam match the DIVE-2224 comment above forbids, so this mirrors
        # _gate_hit_either's own order (ask first, then title) and absorbs the rc.
        local _dd_term=""
        if _gate_tier2_floor_hit "$_dd_res_ask"; then
          _dd_term=$(_gate_tier2_floor_term "$_dd_res_ask" 2>/dev/null) || _dd_term=""
        else
          _dd_term=$(_gate_tier2_floor_term "$_dd_res_title" 2>/dev/null) || _dd_term=""
        fi
        warn "--discusses REFUSED: this gate names a non-appealable category (matched '${_dd_term}'). Money, outbound customer comms and irreversible infra/access stay hard-human however they are framed. Staying at tier 2."
      else
        local _dd_reviewer; _dd_reviewer=$(_gate_route_reviewer "$(task_actor "")")   # DIVE-2518: tier-flag only; see note above
        if [[ -z "$_dd_reviewer" ]]; then
          # Rule 4: the appeal replaces a human with a REVIEWER, never with nobody.
          warn "--discusses REFUSED: no lead sits above you in the org chart, so there is nobody to route the appeal to (a lead cannot self-appeal). Staying at tier 2."
        else
          tier=1; tier_floored=0; _discusses_applied=1
        fi
      fi
    fi
    # Audited whether or not it applied — the DECLARATION is the artifact that
    # replaces the invisible rewording, so it has to survive a refusal too.
    _task_store_audit_log "task need floor-appeal" \
      "$( ((_discusses_applied)) && echo applied || echo refused )" 0 -- \
      "task=$ident" "filer=$(task_actor "$from")" "declared=$discusses" || true
  fi

  # DIVE-2012: THE VERIFIER-SCOPING DEAD-END, made visible.
  #
  # The shape: the MAKER of a live maker→verifier loop files a `decision` gate
  # asking the VERIFIER to scope that task's own acceptance criteria — a question
  # whose only correct answerer is that verifier — and the ask NARRATES the work
  # under test, so the T2 category floor fires on the narration. Measured on the
  # ticket's own repro: tier goes to 2, the DIVE-1495 verifier-route below is
  # guarded on `tier != 2` so it never runs, `routed_reviewer` stays NULL, and the
  # DIVE-1117 provenance floor then refuses the verifier's answer. Net: the paired
  # human is pinged for a call that was never theirs AND the designated answerer is
  # locked out. dev's actual remedy on DIVE-1968 was to message olivia out of band.
  #
  # WHY THIS IS A WARNING AND NOT A SIXTH DOWNGRADE CLASS. The ticket asks for an
  # exemption ("routed decision gates should skip the floor"). Building one means a
  # sixth vocabulary guesser, and DIVE-2099's design note is explicit that adding
  # one reproduces this bug with the polarity REVERSED — a false negative there
  # routes a real money/secret ask to whichever agent happens to be grading the
  # ticket, which is the exact defect DIVE-2241 had just closed. The appeal
  # DIVE-2089 shipped is the supported answer and it already lands correctly:
  # `--discusses` downgrades to tier 1, and because the verifier-route below runs
  # AFTER every downgrade class, the gate then routes to the VERIFIER rather than
  # the lead. Measured: tier=1, routed_reviewer=<verifier>, human not pinged.
  #
  # So the residual defect is not the tier — it is that the remedy is INVISIBLE at
  # exactly the moment it is needed. `--discusses` landed after this ticket was
  # filed, the floor's own warning never mentions it, and nothing tells the filer
  # that the agent they are trying to reach is one flag away. An undiscoverable
  # remedy is indistinguishable from no remedy, which is why this ticket exists.
  #
  # The trigger is STRUCTURAL, never vocabulary: a live loop (both ends present),
  # the filer IS the maker, the verifier is someone else, and the type is the one
  # type an appeal exists for. It changes NO tier and NO route — a floored gate
  # still reaches the human, and the floor is untouched. It only ensures the filer
  # is told, on the record, who they were trying to reach and how to reach them.
  if [[ "$tier_floored" == "1" && "$type" == "decision" && "$_discusses_applied" == "0" \
        && "$_curation" == "0" && "$_internal_ops" == "0" && "$_needs_human" == "0" \
        && "$tier_arg" != "2" ]]; then
    local _vs_filer; _vs_filer=$(task_actor "")
    local _vs_vf _vs_mk
    _vs_vf=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${id};")
    _vs_mk=$(db "SELECT COALESCE(maker_agent,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_vs_vf" && -n "$_vs_mk" && "$_vs_vf" != "$_vs_filer" && "$_vs_mk" == "$_vs_filer" ]]; then
      # DIVE-2801 CLASS — do not recommend a remedy the code will refuse. This
      # advice names `--discusses` as the way to reach the verifier, so it may
      # only be printed when the appeal would actually be ACCEPTED. Both of
      # DIVE-2089's refusal paths have to be evaluated here, not assumed:
      #
      #   Rule 3 — the residual still names a non-appealable category (money /
      #   outbound comms / irreversible infra). Measured before this guard
      #   existed: on a `spend` ask the appeal printed `--discusses REFUSED …
      #   Staying at tier 2` and this warning then told the filer to re-file with
      #   `--discusses` — the remedy they had just been refused, on the same
      #   invocation. On that class there is also no dead-end to announce: the
      #   floored gate is CORRECT and the human genuinely is the right answerer,
      #   which is what the safety arm in the harness has always claimed.
      #
      #   Rule 4 — no lead sits above the filer, so the appeal has nobody to
      #   route to and refuses. Promising a route we cannot mint is the same
      #   defect with a different cause.
      #
      # Computed with the appeal's OWN helpers and its own per-field residual, so
      # the two can never drift apart into a warning that predicts the wrong
      # verdict. Silence here is the stock floor warning's job, not a gap.
      local _vs_res_ask _vs_res_title
      _vs_res_ask=$(_gate_floor_appeal_residual "$ask")
      _vs_res_title=$(_gate_floor_appeal_residual "$_ft_title")
      if _gate_hit_either _gate_tier2_floor_hit "$_vs_res_ask" "$_vs_res_title"; then
        _vs_vf=""   # non-appealable: the human keeps this call, say nothing
      elif [[ -z "$(_gate_route_reviewer "$_vs_filer")" ]]; then
        _vs_vf=""   # no reviewer above the filer: the appeal would refuse
      fi
    fi
    if [[ -n "$_vs_vf" && -n "$_vs_mk" && "$_vs_vf" != "$_vs_filer" && "$_vs_mk" == "$_vs_filer" ]]; then
      # ABSORB the rc. `_gate_tier2_floor_term` is an allowlisted rc-bearing
      # contract: it returns non-zero when it finds no term, so a plain
      # assignment inherits that status and dies under `set -e`. Same shape
      # main's DIVE-2751 fix uses two blocks up, and the call-site guard in
      # tests/task_show_exit_code_unit.sh enforces it — that guard landed on
      # main after this block was first written, and caught it on the rebase.
      local _vs_term=""
      _vs_term=$(_gate_tier2_floor_term "$ask" 2>/dev/null) || _vs_term=""
      [[ -n "$_vs_term" ]] || { _vs_term=$(_gate_tier2_floor_term "$_ft_title" 2>/dev/null) || _vs_term=""; }
      warn "this gate is floored to tier 2 (matched '${_vs_term}'), so it pings the paired human and ${_vs_vf} — the verifier on this task's loop, and the only agent who can answer a question about your own acceptance criteria — CANNOT clear it (tier-2 gates refuse a non-human answer, DIVE-1117). If the term is narration of the work under test rather than something you are asking to DO, re-file with --discusses=\"<why>\": the appeal downgrades the gate to tier 1 and routes it to ${_vs_vf}, not to the human. If you really are asking for that, leave it — the human is the right answerer."
      # The dead-end this ticket was filed about was invisible in the record: the
      # gate simply sat there while dev messaged olivia out of band. Audit the
      # occurrence, not just the advice, so the NEXT instance is countable.
      _task_store_audit_log "task need verifier-scoping floored" "warned" 0 -- \
        "task=$ident" "filer=$_vs_filer" "verifier=$_vs_vf" "term=$_vs_term" || true
    fi
  fi

  # DIVE-1359: eng-ship downgrade. A builder cannot file a hard-human (tier-2)
  # gate for an eng ship/merge/diff/deploy decision — that class is lead-clearable,
  # not a human call. When a NON-lead filer's decision/approval gate hits the
  # eng-ship kind AND did NOT trip the true-human floor above (which already ran
  # and wins — money/secrets/destructive stay tier-2), force it to a
  # lead-routed tier-1, OVERRIDING an explicit --tier=2. `_eng_ship=1` also makes
  # the routing predicate below send it to the lead regardless of the
  # gate_builder_routing pref, exactly like the DIVE-1243 `access` class — the
  # routing is intrinsic to the kind, not part of the pref's staged rollout.
  # secret/manual are never eng-ship. Filer-is-lead ⇒ _gate_route_reviewer empty
  # ⇒ not downgraded (a lead may legitimately pin a human gate). `actor` is not
  # yet set here (defined further down), so resolve the filer inline.
  local _eng_ship=0
  if [[ "$tier_floored" == "0" && ( "$type" == "decision" || "$type" == "approval" || "$type" == "manual" ) ]]; then
    local _es_title; _es_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
    if _gate_hit_either _gate_eng_ship_hit "$ask" "$_es_title"; then   # DIVE-2224: per-field
      local _es_reviewer; _es_reviewer=$(_gate_route_reviewer "$(task_actor "")")   # DIVE-2518: tier-flag only; see note above
      # DIVE-1738: builder ship-handoff nudge. approval/manual gates are
      # HUMAN-ONLY (cmd_task_answer's provenance floor) UNLESS routed — they
      # lean on routed_reviewer + the designated-reviewer exception, and manual
      # is not even eng-ship-downgraded below, so pref-OFF a manual ship gate
      # still pings the human. `decision` is lead-clearable by TYPE (tier-1, no
      # human_nonce, no routing dependency), which is what a builder->lead ship/
      # deploy handoff wants. Steer the filer to --type=decision. Fires only when
      # a lead sits above the filer (_es_reviewer non-empty ⇒ a builder, not the
      # lead re-escalating). Non-fatal + stderr-only: JSON stdout stays clean and
      # routing/tiering are unchanged (the DIVE-1359 downgrade below is intact).
      if [[ -n "$_es_reviewer" && ( "$type" == "approval" || "$type" == "manual" ) ]]; then
        warn "this looks like an engineering ship/deploy handoff filed as --type=$type. Prefer --type=decision for a builder ship gate — it's lead-clearable by design, so $_es_reviewer can resolve it without a human ping (approval/manual are human-only unless routed to the lead)."
      fi
      # DIVE-1359 downgrade stays scoped to decision/approval (manual is never
      # downgraded — the nudge above is its only treatment).
      # DIVE-1957: an EXPLICIT --tier=2 vetoes the downgrade. Overriding the TYPE
      # DEFAULT for a builder ship-gate is the point of this class and stays;
      # overriding the caller's hard-human contract was the bug — a brand/money
      # decision filed --tier=2 on a task merely TITLED "land/merge/ship X" was
      # silently re-tiered to 1 and routed to an agent, and the filer could not
      # fix it from the ask (the classifier reads ask + title). Warn instead of
      # silently obeying, so a builder who pinned by habit sees why their ship
      # gate went to the human rather than to their lead.
      if [[ -n "$_es_reviewer" && "$tier_arg" == "2" \
            && ( "$type" == "decision" || "$type" == "approval" ) ]]; then
        warn "explicit --tier=2 kept this eng-ship-shaped gate hard-human, so it pings the paired human instead of $_es_reviewer. Drop --tier=2 if a lead can clear it (ship/merge/deploy calls are lead-clearable by design); keep it only for a genuine brand/money/destructive call."
        # The warn corrects the NEXT filer; this row lets us MEASURE whether the
        # habit is real. The standing remedy for this very bug was "pin
        # --tier=2", so every agent carrying that advice may now escalate routine
        # ship gates past their lead to the paired human. Audit the branch that
        # declines to act, not just the one that acts — otherwise the only signal
        # is the human complaining about gate spam.
        # DIVE-2054: task-store measurement of a filer/lead pattern — fenced.
        _task_store_audit_log "task.gate-tier2-pin-escalated" ok 0 -- "$ident" "filer=$(task_actor "$from")" "lead=$_es_reviewer" "type=$type"
      elif [[ -n "$_es_reviewer" && ( "$type" == "decision" || "$type" == "approval" ) ]]; then
        tier=1; _eng_ship=1
      fi
    fi
  fi
  [[ "$tier" == "0" && -z "$recommend" ]] \
    && fail "$E_USAGE" "--tier=0 auto-applies the recommendation, so --recommend is required"

  # OSS-11 (DIVE-976) decision-memory precedent prefill. This runs AFTER the tier
  # + T2 category floor are settled and the tier-0-requires-recommend check above,
  # so precedent can NEVER satisfy that requirement or change the resolved tier —
  # it only sources the VALUE of an advisory recommend. The DIVE-916 invariant
  # holds by construction: no tier mutation, no touch of the clear path
  # (cmd_task_answer / TTL / nonce), and a blank rec is filled ONLY when the tier
  # would have surfaced/applied a rec anyway.
  local ask_shape precedent_ref="" precedent_cite="" precedent_kind=""
  ask_shape=$(_gate_ask_shape "$ask")
  # DIVE-2089: an APPLIED appeal is written into the ask the reviewer reads, so
  # the claim it rests on is graded by the person it moved the gate to. This is
  # the property the vocabulary workaround it replaces does not have — a
  # laundered ask carries no trace of having been laundered. Appended AFTER
  # ask_shape so the precedent key still matches the question, not the appeal.
  if [[ "$_discusses_applied" == "1" ]]; then
    ask="${ask}"$'\n\n'"[DIVE-2089 floor appeal — filer declared this DISCUSSES a tier-2 category rather than performing it: ${discusses}. Routed to you instead of the human on that claim; if it is wrong, this belongs with the human.]"
  fi
  # Best prior ANSWERED gate: same need_type, EXACT ask_shape, from an equally- or
  # more-scrutinized tier (COALESCE(tier,2) so legacy NULL counts as T2 — a
  # rubber-stamped T0 can never prefill a T2 gate), answered within 90 days; most
  # recent wins. Exclude self (id<>).
  local _prow
  _prow=$(db "SELECT id||x'1f'||ident||x'1f'||COALESCE(need_answer,'')||x'1f'||
                     COALESCE(need_answered_at,'')||x'1f'||COALESCE(need_answered_by,'')
              FROM tasks
              WHERE need_answer IS NOT NULL AND id<>${id}
                AND need_type=$(sqlq "$type")
                AND ask_shape IS NOT NULL AND ask_shape=$(sqlq "$ask_shape")
                AND COALESCE(tier,2) >= ${tier}
                AND need_answered_at >= datetime('now','-90 day')
              ORDER BY need_answered_at DESC LIMIT 1;")
  [[ -n "$_prow" ]] && precedent_kind="exact"

  # OSS-20 fuzzy fallback. Hand-written asks almost never collide EXACTLY, so the
  # exact path prefilled ~0 gates in practice. When it misses, scan the SAME
  # candidate set (same need_type, tier>=this, answered in 90d, non-empty shape,
  # not self) newest-first and take the most-recent whose ask_shape is token-set
  # Jaccard >= 0.8 to this one — "the same question, paraphrased". This is
  # advisory-ONLY and stays strictly inside the DIVE-916 invariant: it may prefill
  # a blank recommend + cite (recorded precedent_kind='fuzzy'), but it NEVER
  # mutates the tier and is NEVER eligible for auto-clear — OSS-21's auto-clear
  # keys on precedent_kind='exact', so a fuzzy match can only ever advise a human.
  if [[ -z "$_prow" && -n "$ask_shape" ]]; then
    local _cands
    _cands=$(db "SELECT id||x'1f'||ident||x'1f'||COALESCE(need_answer,'')||x'1f'||
                        COALESCE(need_answered_at,'')||x'1f'||COALESCE(need_answered_by,'')||x'1f'||
                        COALESCE(ask_shape,'')
                 FROM tasks
                 WHERE need_answer IS NOT NULL AND id<>${id}
                   AND need_type=$(sqlq "$type")
                   AND ask_shape IS NOT NULL AND ask_shape<>''
                   AND COALESCE(tier,2) >= ${tier}
                   AND need_answered_at >= datetime('now','-90 day')
                 ORDER BY need_answered_at DESC;")
    if [[ -n "$_cands" ]]; then
      local _cid _cident _cans _cat _cby _cshape _j
      while IFS=$'\x1f' read -r _cid _cident _cans _cat _cby _cshape; do
        [[ -n "$_cshape" ]] || continue
        _j=$(_gate_shape_jaccard "$ask_shape" "$_cshape")
        if [[ "$_j" -ge 80 ]]; then
          _prow="${_cid}"$'\x1f'"${_cident}"$'\x1f'"${_cans}"$'\x1f'"${_cat}"$'\x1f'"${_cby}"
          precedent_kind="fuzzy"
          break
        fi
      done <<<"$_cands"
    fi
  fi

  if [[ -n "$_prow" ]]; then
    local _pid _pident _pans _pat _pby
    IFS=$'\x1f' read -r _pid _pident _pans _pat _pby <<<"$_prow"
    precedent_ref="$_pid"
    local _pwho="${_pby#human:}"; _pwho="${_pwho#auto:}"
    # A fuzzy hit is a paraphrase, not an identical gate — flag it in the citation
    # so the human reads the prefill as advisory-by-similarity, not a rubber stamp.
    local _sim=""; [[ "$precedent_kind" == "fuzzy" ]] && _sim=" [similar gate]"
    precedent_cite="Precedent: you answered '${_pans}' on ${_pident} (${_pat%% *}${_pwho:+, $_pwho})${_sim}"
    # Prefill ONLY a blank recommend — never override an explicit filer rec. For a
    # decision the precedent answer must ALSO be one of THIS gate's options (shapes
    # match but option sets can differ); if it isn't, keep the citation but skip
    # the prefill so a tapped/displayed rec always maps to a real option.
    if [[ -z "$recommend" && -n "$_pans" ]]; then
      local _pok=1
      if [[ "$type" == "decision" ]]; then
        _pok=$(printf '%s' "$options" | jq -Rr --arg r "$_pans" '
          [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ]
          | (($r | gsub("^\\s+|\\s+$"; "")) as $rr | any(.[]; . == $rr)) | if . then "1" else "0" end' 2>/dev/null) || _pok=0
      fi
      [[ "$_pok" == "1" ]] && recommend="$_pans"
    fi
  fi

  # DIVE-2235 class-over-tier, applied BEFORE the write below so the stored tier
  # is the floored one (a record showing tier=0 on a gate that was pinged would
  # be its own small lie). Tier 0 IS an auto-answer: it applies `recommend` at
  # file time and never pings. A human-class gate must not be auto-answered at
  # any tier, so tier 0 on one of those is floored to 1 — the gate is filed,
  # a nonce is minted, and a person is asked. Cost of a mis-classification is
  # now one ping instead of a silent self-clear that nothing in the record
  # distinguishes from a considered call. Deliberately NOT floored to 2: this
  # change corrects the class violation only, it does not re-tier the fleet.
  if [[ "$tier" == "0" ]] && _gate_human_class "$type"; then
    tier=1
    _task_store_audit_log "task need class-floor" "ok" 0 -- \
      "task=$ident" "type=$type" "from_tier=0" "to_tier=1" "reason=human_class" || true
  fi

  # assignee=actor: the agent hitting the gate becomes the owner-of-record, so
  # `task answer` knows who to ping to resume. The inbox is defined by the gate
  # (need_type set), not by assignee, so it still surfaces to the human.
  local actor; actor=$(task_actor "$from")
  if [[ "$type" == "decision" ]] && _gate_option_has_second_person "$options"; then
    warn "--options contains second-person wording whose referent can invert between filer and answerer. Prefer account names (for example, main-runs-task-done|dev3-gets-a-credential). Filing continues; the answer receipt will name filer ${actor} and the concrete answerer (DIVE-2212)."
  fi
  # DIVE-2196: filing a gate on a task DELIVERED to you IS an act of review — the
  # verifier demonstrably opened it and escalated. Stamp the handoff ACK in the same
  # transaction, so "reviewed it and escalated to a human" stops being byte-identical
  # to "never looked at it": handoff_ack_at NULL is what the stall sweep, `task show`
  # and the loop board all read as UNACKNOWLEDGED, and on DIVE-2146 that made the
  # sweep nag a verifier who had already graded and escalated. Same receiver rule as
  # DIVE-1378's `task start` ACK — the REAL actor only (never --from, which would let
  # a third party forge the verifier's receipt), only while they are the assigned
  # verifier of a delivered row, COALESCE so a set ACK never moves.
  local _ack_actor; _ack_actor=$(task_actor)
  # DIVE-2119: a re-file DESTROYS the previous gate — archive it to gate_history
  # and reset all six provenance columns in the same transaction, before the
  # SET below overwrites need_type/ask/tier. Without the archive the previous
  # gate leaves nothing but a stale answerer; without the reset the incoming
  # gate wears that answerer's identity, uid and signature (DIVE-2094).
  # DIVE-2233 item 2 — mint the per-gate human nonce BEFORE the gate is persisted, and
  # refuse to persist it at all if a tier-2 gate cannot arm itself.
  #
  # ORDERING IS THE WHOLE FIX, and getting it wrong was worse than not fixing it. The
  # refusal originally sat after this UPDATE, so a mint failure aborted the command
  # having ALREADY written need_type/ask/tier — leaving exactly the half-armed tier-2
  # gate it refuses to create, while telling the caller it had failed. Caught by arm M2
  # of gate_t2_nonce_proof_unit ("no half-filed gate is left behind"), which is the arm
  # I nearly did not write because the refusal "obviously" prevented the state.
  #
  # WHY IT MUST FAIL CLOSED. An empty mint used to be silent: no UPDATE, hash NULL, gate
  # files normally, no warning and no audit row — indistinguishable from a properly
  # minted gate. Survivable while nothing read the column; NOT survivable once the
  # tier-2 floor treats a NULL hash as "skip the check", because then a box with a
  # broken RNG has no floor while every gate on it still LOOKS protected. That is
  # DIVE-2131 restated. `_human_nonce_verify` already fails closed on a missing hash;
  # the floor inverted that into a fail-open by skipping, so the refusal belongs HERE,
  # where the absence is created, not there, where it is only observed.
  #
  # Scoped to tier 2 deliberately: for the other human types a NULL hash still means
  # what it always meant and DIVE-916's verify path fails closed on it unchanged, so
  # widening this would break gate filing for no security gain. With the /dev/urandom
  # fallback in `_human_nonce_mint`, reaching this refusal means both the CSPRNG and
  # openssl are gone — a broken box, not a routine one.
  # DIVE-2365 (rebase onto DIVE-2356): the condition is "hard-human TYPE **or**
  # tier>=2", NOT `tier == "2"`. This branch and the persist site below were written
  # against different mint conditions on two branches; a string compare misses tier
  # 3+, so the arm-or-refuse decision would cover a NARROWER set than the floor it
  # exists to protect — the fail-open this commit closes, reintroduced one tier up.
  # `_t2` is what the refusal keys on, so it tracks the tier arm alone: a hard-human
  # type at tier 0/1 still files on an empty mint exactly as it always did.
  local human_nonce="" _mint_nonce=0 _t2=0
  case "$type" in approval|secret|manual|access) _mint_nonce=1 ;; esac
  [[ "${tier:-}" =~ ^[0-9]+$ ]] && (( tier >= 2 )) && { _mint_nonce=1; _t2=1; }
  (( _mint_nonce )) && human_nonce=$(_human_nonce_mint)
  if (( _t2 )) && [[ -z "$human_nonce" ]]; then
    # DIVE-2054: DELIBERATELY UNFENCED — a hard gate that could not arm itself is a
    # fleet-health event, and it must leave evidence even though the caller is told.
    audit_log "task need nonce-mint-failed" error 0 -- \
      "task=$ident" "type=$type" "tier=$tier" \
      "reason=could not mint a per-gate human nonce (openssl and /dev/urandom both unusable)" \
      2>/dev/null || true
    fail "$E_GENERIC" "$ident: refusing to file a tier-2 gate that cannot mint its own human proof — openssl and /dev/urandom are both unusable; fix the box's RNG, or file it at a lower --tier"
  fi

  # DIVE-2410: filing REPLACES any gate already on this task (that is what the
  # archive-and-clear is for), so whatever button the OUTGOING gate put in a human
  # chat now asks a question this task no longer holds. Retire BEFORE the new
  # delivery, not after: the delivery log is the input, so once task_need_notify
  # has run, the gate's own fresh button is in there too and would be stripped by
  # its own filing. Order is the correctness condition here, not a preference.
  # DIVE-2848: THE KEYSTROKE CAP. See the block comment above cmd_task_need for the
  # measurement and the rule. Placed HERE, after every floor / downgrade / declaration
  # has had its turn, so the condition reads exactly as "this gate is tier 2 for no
  # reason other than that the filer typed --tier=2": tier_floored==0 excludes the T2
  # category floor AND the --needs re-assert, both of which set it.
  #
  # tier_floored==0 IS NOT "no category applies" ON THIS PATH, and assuming it was
  # is the one way this cap could do damage. The T2 category floor only ever runs
  # to RAISE a tier below 2 — there is nothing for it to raise when the filer typed
  # --tier=2, so a money/secret/destructive gate filed AT tier 2 arrives here with
  # tier_floored still 0, indistinguishable from a rubber stamp. Caught by the
  # money control in tests/gate_recommend_cap_unit.sh (B3), which refused
  # "approve the monthly spend on the paid Hetzner plan". Re-running the classifier
  # here is the fix; reading the flag is not. (The refusal would not have AUTHORISED
  # anything — a re-file at --tier=0 gets floored straight back to 2 — but it would
  # have told an agent holding a genuine spend gate that they were rubber-stamping,
  # which is worse than useless from a cap whose whole claim is that it knows the
  # difference.)
  local _rs_capped=0 _rs_taps=0 _rs_tot=0 _rs_title=""
  _rs_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
  if [[ ( "$type" == "decision" || "$type" == "approval" ) \
        && "$tier" == "2" && "$tier_arg" == "2" && "$tier_floored" == "0" \
        && "$_needs_human" != "1" && -n "$recommend_arg" ]] \
     && ! _gate_hit_either _gate_tier2_floor_hit "$ask" "$_rs_title"; then
    read -r _rs_taps _rs_tot <<<"$(_gate_tapback_stats "$actor")"
    if [[ -z "$rubber_stamp" ]]; then
      _task_store_audit_log "task need rubber-stamp-cap" "refused" 0 -- \
        "task=$ident" "filer=$actor" "type=$type" "recommend=$recommend" \
        "tapbacks=${_rs_taps}/${_rs_tot}" "reason=tier-2 with a recommendation and no declared capability" || true
      fail "$E_VALIDATION" "$ident: refusing this --tier=2 ${type} gate. You wrote --recommend=\"${recommend}\", which means you have already decided — what is left is asking a person to agree, and that is reassurance, not a gate. (Measured 2026-07-16..08-07: 96 of 107 judgment gates carrying a recommendation came back as the human tapping that same value. Only 7 gates in 346 were floored by category; the rest of tier 2 was typed by hand.) A tier is a CAPABILITY, not a difficulty. Your exits:
  --tier=0    apply \"${recommend}\" NOW. No ping, and still a permanent gate record plus a digest line. This is the exit you want on a decision you have already made — it was used 0 times in the 346 gates measured, which is a discoverability failure, not a missing feature.
  --tier=1    route to your lead, or to this task's verifier if it carries a loop — except a push-for-review ask, which goes to the LEAD even on a loop, because the verifier cannot read the diff until it is pushed (DIVE-3117); the 48h TTL applies your recommendation if nobody answers. Use it when you want a second pair of eyes, not a person's authority.
  --needs=human_tap|spend_authority|secret_provision    DECLARE the human-held capability this ask consumes (a person's call on brand/strategy, money, or a credential only a human can issue). Tier 2 by declaration, never refused here.
  --rubber-stamp-ok=\"<why a person must answer this despite your recommendation>\"    the audited exception. Recorded on the gate row and readable afterwards.
If you cannot name the capability, this is a decision you find uncomfortable, not a human gate."
    fi
    # The escape exists for an EXCEPTION. Rate-limit the CLASS, not just the
    # instance (ticket item 3): past the cap, the exception IS the pattern, and the
    # only honest exit left is naming a capability. Fail-open below the minimum
    # sample — a new filer with no history must not inherit a refusal.
    if (( _rs_tot >= _GATE_TAPBACK_MIN && _rs_taps > _GATE_TAPBACK_MAX_TAPS )); then
      _task_store_audit_log "task need rubber-stamp-cap" "refused-rate" 0 -- \
        "task=$ident" "filer=$actor" "type=$type" "tapbacks=${_rs_taps}/${_rs_tot}" \
        "declared=$rubber_stamp" || true
      fail "$E_VALIDATION" "$ident: refusing this --tier=2 ${type} gate AND its --rubber-stamp-ok escape. ${_rs_taps} of your last ${_rs_tot} human-answered gates that carried a recommendation came back as the human tapping that same value; the cap is ${_GATE_TAPBACK_MAX_TAPS} in ${_GATE_TAPBACK_WINDOW}. The escape is for an exception, and at this rate it is your pattern. Remaining exits: --tier=0 (apply \"${recommend}\" now, no ping, permanent record), --tier=1 (lead/verifier, TTL applies the rec), or --needs=<capability> if this genuinely consumes something you do not hold. The window is rolling — as those gates age out, the cap lifts on its own."
    fi
    _rs_capped=1
    warn "tier-2 escape ACCEPTED and RECORDED: --rubber-stamp-ok=\"${rubber_stamp}\". You wrote a recommendation and are still sending this to a person; the reason is now on the gate row (task show) and in the audit log, so this exception is countable instead of invisible. Your recent rubber-stamp rate is ${_rs_taps}/${_rs_tot}."
  fi
  if [[ -n "$rubber_stamp" && "$_rs_capped" == "0" ]]; then
    warn "--rubber-stamp-ok changed nothing on this gate — the keystroke cap did not fire (type=${type}, tier=${tier}$( ((tier_floored)) && printf ', floored by category or declaration')). The declaration is still written to the row, so it stays readable; it just did not need to buy anything."
  fi

  _task_gate_retire_buttons "$ident" "superseded by a re-filed gate" || true

  db "BEGIN IMMEDIATE;
      $(_gate_archive_and_clear_sql file "id=${id}")
      UPDATE tasks
        -- DIVE-2624: DO NOT STEAL THE ASSIGNEE off a live maker-to-verifier handoff.
        -- The handoff line in task show is DERIVED (assignee=verifier AND
        -- maker_agent IS NOT NULL AND status NOT IN done/cancelled), so writing
        -- assignee=<filer> unconditionally FALSIFIED THE PREDICATE and the delivery
        -- vanished from the board. Nothing was lost -- handoff_delivered_at was never
        -- touched -- but every reader (task show, the loop board, the stall sweep)
        -- reads the predicate, not the column, so the work sat in the verifier
        -- queue looking un-delivered. Measured on DIVE-2619/DIVE-2594; the
        -- withdraw+re-file was only the filing someone happened to watch, a single
        -- fresh gate does it too.
        --
        -- This is the exact CONVERSE of the handoff_ack_at CASE directly below,
        -- which already asks whether the filer is the verifier of a delivered row.
        -- When the filer IS the verifier this CASE is a no-op by construction
        -- (assignee=verifier=actor), so the only behaviour it changes is the
        -- third-party filing -- which is the one that did the damage.
        --
        -- Column refs on the right of SET are evaluated against the PRE-update row
        -- (same property cmd_task_assign relies on), so this and the ACK CASE below
        -- both see the original assignee regardless of clause order.
        --
        -- The assignee was doing a second job here -- task answer read it to know
        -- who to ping to resume -- so preserving it would have moved the resume ping
        -- onto the verifier. That reader now prefers gate_filed_by, the column
        -- that actually records the filer (see cmd_task_answer). One fact, one
        -- column: the filer is provenance, the assignee is who holds the row.
        --
        -- NO BACKTICKS AND NO DOUBLE QUOTES IN THIS COMMENT, and that is not style.
        -- An SQL comment here is bash-parsed BEFORE sqlite ever sees it, because the
        -- whole statement is one double-quoted bash string: a backtick runs a command
        -- and a double quote ends the string. The first draft of this block did both,
        -- handed sqlite an incomplete statement, wrote NO GATE, and still printed a
        -- successful filing -- which is what the post-write assertion below now
        -- refuses to let happen again.
        -- DIVE-3097: a SECOND, narrower preserve-don't-steal arm, added beside the
        -- DIVE-2624 one above rather than folded into it, because it guards a
        -- different shape. DIVE-2624 protects a LIVE, DELIVERED handoff
        -- (maker_agent set, already routed) from being un-delivered by a
        -- third-party filing. This arm protects a row that was NEVER delivered
        -- at all: if the actor filing this gate happens to be the row's own
        -- verifier, the unconditional ELSE below would set assignee=actor=verifier
        -- while maker_agent is still NULL -- manufacturing FRESH the exact
        -- assignee==verifier, no-handoff-ever-recorded shape DIVE-2899 named
        -- (assignee=dev3, verifier=dev3, delivered_at NULL), via a THIRD writer
        -- neither of this ticket's other two fixes (task add, task assign) can
        -- see, because filing a gate has no ownership check and this column write
        -- is a side effect of it, not its stated purpose. Scoped to assignee<>
        -- verifier so it is a no-op on every row the DIVE-2624 arm or the
        -- DIVE-2196 review-escalation case (assignee=verifier=actor already)
        -- already cover -- this only stops a NEW collision, never touches an
        -- existing one (no retro-grading, same as the rest of DIVE-3097).
        SET status='blocked',
            assignee=CASE
              WHEN maker_agent IS NOT NULL AND verifier IS NOT NULL
                   AND assignee=verifier AND handoff_delivered_at IS NOT NULL
                   AND verifier IS NOT $(sqlq "$actor")
              THEN assignee
              WHEN verifier IS NOT NULL AND verifier=$(sqlq "$actor") AND assignee IS NOT verifier
              THEN assignee
              ELSE $(sqlq "$actor") END,
            handoff_ack_at=CASE
              WHEN maker_agent IS NOT NULL AND verifier IS NOT NULL
                   AND assignee=verifier AND verifier=$(sqlq "$_ack_actor")
                   AND handoff_delivered_at IS NOT NULL
              THEN COALESCE(handoff_ack_at, datetime('now'))
              ELSE handoff_ack_at END,
            need_type=$(sqlq "$type"), ask=$(sqlq "$ask"),
            need_options=$(sqlq_or_null "$options"),
            recommend=$(sqlq_or_null "$recommend"),
            secret_key=$(sqlq_or_null "$secret_key"),
            connector=$(sqlq_or_null "$connector"),
            secret_oob=$(sqlq_or_null "$oob"),
            ask_shape=$(sqlq_or_null "$ask_shape"),
            precedent_ref=${precedent_ref:-NULL},
            precedent_kind=$(sqlq_or_null "$precedent_kind"),
            -- DIVE-2615: why this gate has this tier. Written on the SAME statement
            -- that writes the tier, so the two can never disagree about one filing.
            floor_provenance=$(sqlq_or_null "$_floor_prov"),
            -- DIVE-2241: the capability the filer DECLARED, recorded verbatim —
            -- including one that resolved to nothing. What was claimed is the
            -- provenance; whether it resolved is recomputable from the sealed
            -- list, and a mis-declaration you cannot see is one you cannot correct.
            needs_capability=$(sqlq_or_null "$needs"),
            -- DIVE-2848: the declared reason a gate carrying its own recommendation
            -- still went to a person. The cap's value is that the exception is
            -- COUNTABLE afterwards — an escape that leaves no row is --tier=2 with
            -- extra steps, which is the thing this ticket exists to end.
            gate_rubber_stamp=$(sqlq_or_null "$rubber_stamp"),
            -- DIVE-2354: the declared order (approve-to-send | confirm-after-send).
            -- Written on the SAME statement as need_type, so a row can never hold a
            -- mode belonging to a gate it no longer carries.
            gate_mode=$(sqlq_or_null "$gate_mode"),
            tier=${tier}, need_asked_at=datetime('now'), gate_pinged_at=NULL,
            gate_filed_by=$(sqlq "$actor")
      WHERE id=${id};
      COMMIT;"

  # DIVE-2624: ASSERT THE WRITE LANDED. `db` is not checked anywhere on this path,
  # so a statement sqlite refuses (it prints "Error: in prepare, incomplete input"
  # to stderr and returns) wrote NO gate — and every line below still ran: the
  # ledger recorded gate.filed, the router pinged a reviewer about a question the
  # row does not hold, and the caller was told the gate was filed. That is not a
  # hypothetical: it is how the first cut of the assignee CASE above failed, and
  # nothing in the output distinguished it from success. One cheap read-back turns
  # the whole class (bad SQL, a locked store, a failed BEGIN IMMEDIATE) from a
  # false green into a refusal, BEFORE anyone is notified about it.
  if [[ "$(db "SELECT CASE WHEN status='blocked' AND need_type IS NOT NULL
                             AND need_asked_at IS NOT NULL THEN 1 ELSE 0 END
               FROM tasks WHERE id=${id};" 2>/dev/null)" != "1" ]]; then
    fail "$E_GENERIC" "$ident: the gate write did not land — the task store still shows no filed gate on this row, so nothing has been asked of anyone. Nothing was notified and no ledger entry was made. Re-run; if it repeats, the task store is refusing the write (check for a lock or a schema mismatch with 5dive task show $ident)."
  fi

  # INST-4: the gate is the authority record — who asked whom for permission, at
  # what tier. The ask text is hashed, not stored: a tier-2 ask routinely names
  # the money, the box, or the destructive verb it is asking about.
  ledger_emit gate.filed ident="$ident" task_id="$id" actor="$actor" \
    policy="tier${tier}:${type}" in="$ask" \
    detail="${type} gate filed at tier ${tier}${recommend:+ (recommend: ${recommend})}"

  # DIVE-891 tier 0: apply the recommendation right now — the gate exists only
  # as a signed-off record in the log/digest, never as a ping. Provenance is
  # 'auto:t0' (never human:*, so a loop approval gate can NOT be advanced this
  # way — _task_loop_advance requires human:*). No task_need_notify. The direct
  # answer write here intentionally skips cmd_task_answer's human-only checks:
  # tier 0 was validated above as outside every T2 category, which is exactly
  # the delegation the adopted design grants.
  if [[ "$tier" == "0" ]]; then
    local _ts0; _ts0=$(date -u '+%Y-%m-%d %H:%M:%S')
    db "UPDATE tasks SET need_answer=$(sqlq "$recommend"), need_answered_at=$(sqlq "$_ts0"),
          need_answered_by='auto:t0' WHERE id=${id};
        UPDATE tasks SET status='todo'
          WHERE id=${id} AND status='blocked'
            AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id});"
    # DIVE-2054: auto-clear applied from task-store data — fenced.
    _task_store_audit_log "task need t0-auto" "ok" 0 -- "task=$ident" "type=$type" "applied=$recommend" || true
    ok "$ident tier-0 gate auto-cleared — applied: $recommend" \
       '{id:($i|tonumber), ident:$id, tier:0, auto_applied:$rc, need_type:$ty}' \
       --arg i "$id" --arg id "$ident" --arg rc "$recommend" --arg ty "$type"
    return
  fi

  # OSS-21: tier-1 precedent auto-clear (behind pref precedent_autoclear, default
  # OFF). Runs AFTER tier resolution + the T2 floor (both unchanged) and AFTER the
  # main gate write above, so it can only ever act on a gate that has ALREADY
  # resolved to tier 1 — T0 returned above, and T2/HUMAN-CLASS are excluded by the
  # guard. Qualify precedent = EXACT ask_shape + same need_type, >=2 DISTINCT prior
  # gates answered by a VERIFIED human (see below) that were NOT themselves fuzzy-
  # prefilled (precedent_kind<>'fuzzy' — OSS-20's advisory fuzzy match can never
  # leak into the auto-clear seed set; exact human precedent only), IDENTICAL
  # need_answer, within
  # 90d, precedent tier >= 1, and ZERO contradicting human answers on that shape in
  # 90d (i.e. exactly ONE distinct human answer). On qualification we clear via the
  # SAME immediate direct-write path as tier-0/auto:ttl (never cmd_task_answer, so
  # NO human nonce is ever minted), provenance 'auto:precedent', precedent_ref = the
  # most-recent qualifying gate. The digest surfaces it through the auto:* Auto-
  # cleared section with the precedent citation (DIVE-891 path). Secret gates and
  # T2 provably never reach here; pref OFF is exact pre-OSS-21 behaviour.
  #
  # DIVE-2235 changes the SEED TEST, and this is the subtle half of the ticket.
  # The old filter was `need_answered_by LIKE 'human:%'`, with a comment saying
  # it excludes every auto:* seed — true, and it does stop the auto writers
  # compounding. But `human:<name>` is a SELF-DECLARATION written from the
  # caller's own username: on DIVE-2224 two agent self-clears were stamped
  # `human:olivia` and would have QUALIFIED AS HUMAN PRECEDENT. The guard built
  # to stop laundering was checking the one field that cannot be trusted. So the
  # seed now additionally requires a per-gate human nonce to have been minted and
  # survived to the answer (human_nonce_hash non-empty — _gate_archive_and_clear
  # nulls it on a re-file, so it can only be the nonce this answer was given).
  #
  # HONEST CONSEQUENCE, stated rather than discovered later: combined with the
  # class guard, the only class that still reaches here is 'decision', and
  # decision gates do not mint a nonce (_gate_human_class's list is the mint
  # list). So precedent auto-clear is INERT until decision gates mint — that is
  # the v0.18 "proof of who" work. Inert is the correct direction for a pref
  # that ships OFF and whose failure mode is "ask the human instead", but inert
  # AND SILENT is the DIVE-1935 shape, so the decline is logged loudly below.
  if [[ "$tier" == "1" && -n "$ask_shape" ]] && ! _gate_human_class "$type"; then
    local _ac; _ac=$(_task_pref_get precedent_autoclear); _ac="${_ac:-off}"
    if [[ "$_ac" == "on" ]]; then
      # One atomic read of the human-precedent set on this exact shape: newest
      # qualifying gate (id + its answer), the count of DISTINCT human answers
      # (>1 ⇒ contradiction ⇒ disqualified), and the total human-gate count.
      local _qrow
      _qrow=$(db "SELECT t1.id||x'1f'||COALESCE(t1.need_answer,'')||x'1f'||
          (SELECT COUNT(DISTINCT need_answer) FROM tasks
             WHERE need_answer IS NOT NULL AND id<>${id}
               AND need_type=$(sqlq "$type")
               AND ask_shape IS NOT NULL AND ask_shape=$(sqlq "$ask_shape")
               AND need_answered_by LIKE 'human:%'
               AND human_nonce_hash IS NOT NULL AND human_nonce_hash <> ''
               AND COALESCE(precedent_kind,'') <> 'fuzzy'
               AND COALESCE(tier,2) >= 1
               AND need_answered_at >= datetime('now','-90 day'))
          ||x'1f'||
          (SELECT COUNT(*) FROM tasks
             WHERE need_answer IS NOT NULL AND id<>${id}
               AND need_type=$(sqlq "$type")
               AND ask_shape IS NOT NULL AND ask_shape=$(sqlq "$ask_shape")
               AND need_answered_by LIKE 'human:%'
               AND human_nonce_hash IS NOT NULL AND human_nonce_hash <> ''
               AND COALESCE(precedent_kind,'') <> 'fuzzy'
               AND COALESCE(tier,2) >= 1
               AND need_answered_at >= datetime('now','-90 day'))
        FROM tasks t1
        WHERE t1.need_answer IS NOT NULL AND t1.id<>${id}
          AND t1.need_type=$(sqlq "$type")
          AND t1.ask_shape IS NOT NULL AND t1.ask_shape=$(sqlq "$ask_shape")
          AND t1.need_answered_by LIKE 'human:%'
          AND t1.human_nonce_hash IS NOT NULL AND t1.human_nonce_hash <> ''
          AND COALESCE(t1.precedent_kind,'') <> 'fuzzy'
          AND COALESCE(t1.tier,2) >= 1
          AND t1.need_answered_at >= datetime('now','-90 day')
        ORDER BY t1.need_answered_at DESC LIMIT 1;")
      # DIVE-2235: make the DECLINE observable. If no nonce-verified seed
      # qualified, count the seeds the OLD self-declaration filter would have
      # accepted. A non-zero count is exactly the laundering this change stops,
      # and it is the number that says "the nonce path is not live for this
      # class yet" — without this row the feature would simply never fire and
      # nothing would say why (DIVE-1935: inert while reporting itself working).
      if [[ -z "$_qrow" ]]; then
        local _unverified
        _unverified=$(db "SELECT COUNT(*) FROM tasks
             WHERE need_answer IS NOT NULL AND id<>${id}
               AND need_type=$(sqlq "$type")
               AND ask_shape IS NOT NULL AND ask_shape=$(sqlq "$ask_shape")
               AND need_answered_by LIKE 'human:%'
               AND COALESCE(precedent_kind,'') <> 'fuzzy'
               AND COALESCE(tier,2) >= 1
               AND need_answered_at >= datetime('now','-90 day');" 2>/dev/null || echo 0)
        [[ "$_unverified" =~ ^[0-9]+$ ]] || _unverified=0
        if (( _unverified > 0 )); then
          _task_store_audit_log "task need precedent-declined" "ok" 0 -- \
            "task=$ident" "type=$type" "unverified_seeds=$_unverified" \
            "reason=no_nonce_verified_precedent" || true
        fi
      fi
      if [[ -n "$_qrow" ]]; then
        local _qid _qans _qdistinct _qtotal
        IFS=$'\x1f' read -r _qid _qans _qdistinct _qtotal <<<"$_qrow"
        # Qualified: exactly one distinct human answer, backed by >=2 gates.
        if [[ "$_qdistinct" == "1" && "$_qtotal" -ge 2 && -n "$_qans" ]]; then
          # For a decision the consensus answer must ALSO be a current option
          # (shapes match but option sets can drift); if it isn't, fall through
          # to the normal human ping rather than apply an off-menu answer.
          local _dok=1
          if [[ "$type" == "decision" ]]; then
            _dok=$(printf '%s' "$options" | jq -Rr --arg r "$_qans" '
              [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ]
              | (($r | gsub("^\\s+|\\s+$"; "")) as $rr | any(.[]; . == $rr)) | if . then "1" else "0" end' 2>/dev/null) || _dok=0
          fi
          if [[ "$_dok" == "1" ]]; then
            local _tsp; _tsp=$(date -u '+%Y-%m-%d %H:%M:%S')
            db "UPDATE tasks SET need_answer=$(sqlq "$_qans"), need_answered_at=$(sqlq "$_tsp"),
                  need_answered_by='auto:precedent', precedent_ref=${_qid}, precedent_kind='exact'
                WHERE id=${id};
                UPDATE tasks SET status='todo'
                  WHERE id=${id} AND status='blocked'
                    AND NOT EXISTS (SELECT 1 FROM task_deps WHERE task_id=${id});"
            # DIVE-2054: same reasoning as "task need t0-auto" above — fenced.
            _task_store_audit_log "task need precedent-auto" "ok" 0 -- "task=$ident" "type=$type" "applied=$_qans" "precedent=$_qid" || true
            ok "$ident tier-1 gate auto-cleared from human precedent — applied: $_qans (precedent #$_qid)" \
               '{id:($i|tonumber), ident:$id, tier:1, need_type:$ty, auto_applied:$rc, need_answered_by:"auto:precedent", precedent_ref:($pr|tonumber)}' \
               --arg i "$id" --arg id "$ident" --arg ty "$type" --arg rc "$_qans" --arg pr "$_qid"
            return
          fi
        fi
      fi
    fi
  fi

  # DIVE-1145: ship-gating routing. Root-cause fix for builders over-filing
  # gates straight to the human (DIVE-1127/1142). Before the human ping, route a
  # NON-true-human builder gate to the org lead first, as an agent handoff. Gated
  # on pref `gate_builder_routing` (default OFF — same ship-safe posture as
  # OSS-21 precedent_autoclear; the lead flips it on after reviewing this diff).
  # Scope is deliberately DECISION-only in v1: decision gates are agent-clearable
  # (tier 1, no human_nonce) so the lead can actually resolve them, whereas
  # approval/manual/secret are enforced human-only by `task answer` (DIVE-1117
  # provenance floor) — routing those to an agent-reviewer needs the floor to
  # trust a designated reviewer, a deeper change deferred to a follow-up. We
  # never route a tier-2 gate — whether floored (true-human category: money/
  # destructive/secret, per _gate_tier2_floor_hit) OR filed with an
  # explicit --tier=2 (the caller's hard-human contract; 2 = never auto-applies,
  # always pings the human). Guarding on the EFFECTIVE tier (tier != 2) subsumes
  # the floor, since a floored gate always sets tier=2, and closes the hole where
  # `--type=decision --tier=2` with no floor keyword left tier_floored=0 and
  # silently routed past the human. We also never route one filed BY a lead
  # (_gate_route_reviewer returns empty → falls through to the human, which is
  # also how the lead re-escalates). Reviewer notify is best-effort + detached so
  # the 45s tmux-inject wait never blocks or fails the already-committed gate.
  # DIVE-1182 closes the DIVE-1145 gap: a builder's ship-gate is filed as
  # `approval` (or `manual`), NOT `decision`, so v1 left it human-only — it pinged
  # lodar instead of being clearable by the org lead (Marcus). We now route
  # approval/manual too, so a NON-true-human builder gate reaches the lead first.
  # `secret` is deliberately EXCLUDED (a secret must be delivered by a human,
  # never an agent), and tier-2 gates are never routed (guarded by tier != 2,
  # which subsumes the true-human category floor: money/destructive/secret).
  # Unlike decision (agent-clearable by type), approval/manual are human-only in
  # cmd_task_answer; routing them therefore PERSISTS routed_reviewer, the single
  # basis for the designated-reviewer floor exception there — so the exception is
  # scoped to exactly this routed gate + this reviewer, and every un-routed
  # approval/manual gate stays hard-human (DIVE-391/515/516 boundary intact).
  # Routability differs by type because of the tier-2 defaults:
  #   decision — defaults to tier 1, so `tier != 2` cleanly means "not pinned/
  #     floored hard-human" (subsumes explicit --tier=2 AND the category floor,
  #     which already ran above for tier<2).
  #   approval/manual — default to tier 2, so the effective tier can't discriminate.
  #     Route them UNLESS the caller EXPLICITLY pinned --tier=2 (hard-human
  #     contract) OR the ask/title hits the true-human category floor (money/
  #     destructive/secret) — the same floor decision that gates a decision,
  #     re-run here because the tier==2 short-circuit above skipped it for these.
  #   secret — never routable (must be delivered by a human).
  #
  # DIVE-1495: verifier-route. When the task carries a maker→verifier loop whose
  # VERIFIER is a distinct fleet agent, a decision/approval gate the maker files
  # is really a question FOR that verifier — not the paired human (CNCL-9: dev, as
  # maker, filed `task need --type=decision` to ask main the verifier and it
  # pinged lodar). Route it to the verifier's agent-send rail: they clear it via
  # `task answer` (already allowed for a decision; for approval the routed_reviewer
  # persisted below authorizes them, DIVE-1182). Intrinsic to the KIND, so it
  # bypasses the gate_builder_routing pref like eng-ship/curation. Never fires when
  # the filer IS the verifier (self-route — e.g. the max_iters escalation files
  # its manual gate --from the verifier) or on secret/manual/access. We still guard
  # tier!=2 so a money/brand/destructive decision stays human even inside a loop.
  # DIVE-2241: re-assert the declared human class AFTER every downgrade kind has
  # had its turn. eng-ship / curation / internal-ops / --discusses each force a
  # floored gate back down to a lead-routed tier-1, and they classify on the ask's
  # SHAPE ("this looks like a ship") — which a declared capability outranks, because
  # it states what the ask CONSUMES. One re-assert here rather than a veto bolted
  # onto each of the four guards: the DIVE-1957 lesson is that a promise held
  # per-branch is a promise that breaks when branch five is added.
  if [[ "$_needs_human" == "1" && "$tier" != "2" ]]; then
    warn "--needs=${needs} restored this gate to tier 2: a downgrade kind (eng-ship / curation / internal-ops / floor appeal) classified it as lead-clearable off the ask's shape, but you declared it consumes a human-held capability, and the declaration wins."
    tier=2; tier_floored=1
  fi

  # DIVE-3117: THE ONE GATE CLASS WHERE THE VERIFIER-ROUTE DEFAULT INVERTS ITSELF.
  #
  # A push-for-review ask asks for the branch to be pushed. On a maker→verifier row
  # the DIVE-1495 route above hands that gate to the VERIFIER — i.e. it asks the
  # grader to authorise the push that is the only way the grader can read the diff.
  # quinn stated it exactly on DIVE-2183: cannot approve a push before reading the
  # diff, cannot read the diff until it is pushed. Measured FOUR times on
  # 2026-08-09/10 (DIVE-3113, DIVE-2130, DIVE-2183, DIVE-2192), every one blocking a
  # real push, every one cleared by hand from the root seat.
  #
  # THE TEST AT THE KEYSTROKE: if this gate clears, does the answerer GAIN the thing
  # they needed in order to answer it? If yes, it is a cycle. Route it to the lead —
  # the one seat that can authorise the push and is not the party blocked by it. The
  # verifier still grades the work afterwards; that is `task reject`/`accept`, a
  # different surface, and it is untouched here.
  #
  # WHY THIS IS A FLOOR ON THE ROUTING AXIS AND NOT A ROUTER REWRITE (main's framing,
  # and it is the sharper one). The TIER machinery is correct — DIVE-2629 already put
  # a floor on the tier axis of this exact gate class (branch names stop forcing T2)
  # and it produced tier 1 on all four instances. What was missing is the SIBLING
  # floor, on routing: `floor_provenance=axis=none` on all four, i.e. nothing
  # engaged. DIVE-2629 left routed_reviewer EMPTY (no agent can clear it); this left
  # it equal to the GRADER (the one agent who cannot answer it). Same symptom, and a
  # tier-axis fix cannot reach the second case — which is why 2629 shipping did not
  # prevent four occurrences of 3117 in one day.
  #
  # THE ASK ONLY, never the title (DIVE-2224). A title is written at ticket-creation
  # time to describe a DEFECT; only the ask can be a REQUEST. This very ticket is
  # titled "push-for-review gate routes to the loop VERIFIER…", so a title-reading
  # classifier would strip the verifier off every genuine question filed on it. The
  # negative control is graded in tests/gate_verifier_route_unit.sh.
  #
  # `_gate_push_for_review_hit` fails closed and is the SAME predicate DIVE-2629's
  # tier floor uses, so the two axes cannot disagree about what an inert push is: a
  # push ask that also names a merge/deploy/land-to-main is NOT inert, keeps its
  # existing routing, and keeps flooring on its subject matter.
  local _verifier_route=0 _route_target="" _pfr_lead_route=0
  if [[ ( "$type" == "decision" || "$type" == "approval" ) && "$tier" != "2" ]]; then
    local _vf; _vf=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${id};")
    if [[ -n "$_vf" && "$_vf" != "$actor" ]]; then
      # Confirm the verifier is a real fleet agent (a live maker→verifier loop by
      # construction, or present in the org chart) so we never misroute to a
      # non-agent token.
      local _vf_is_agent; _vf_is_agent=$(db "SELECT CASE WHEN
            (SELECT COALESCE(maker_agent,'') FROM tasks WHERE id=${id}) <> ''
            OR EXISTS(SELECT 1 FROM agents_org WHERE name=$(sqlq "$_vf"))
          THEN 1 ELSE 0 END;")
      if [[ "$_vf_is_agent" == "1" ]]; then
        if _gate_push_for_review_hit "$ask"; then
          _pfr_lead_route=1
        else
          _verifier_route=1; _route_target="$_vf"
        fi
      fi
    fi
  fi

  # DIVE-3171 — EVERY GATE THE ORG ROOT FILES REACHES THE HUMAN BY CONSTRUCTION.
  #
  # `_gate_route_reviewer` walks UP the chart — reports_to, then the coordinator/root —
  # skipping any candidate equal to the filer. For the ROOT of the chart BOTH candidates
  # are the filer, so the walk falls off the end empty and the gate drops to the human
  # ping. Not intermittently, and not about any one gate's subject: it is every gate the
  # root ever files. DIVE-2612 already wrote the shape down from the FILER's side (its
  # warn text: "for the root of the chart the coordinator fallback resolves to
  # themselves"); this is the routing half of the same fact, which that ticket described
  # and did not fix. lodar, 2026-08-10, in the third week of it: "why still this goes to
  # me????? i was complaining for 3 weeks already".
  #
  # WHAT MAKES IT INVISIBLE: for every other seat the same code is correct, and the root
  # is the one seat that files engineering gates while sitting ABOVE the engineering lead.
  #
  # THE SAME PREDICATE ON BOTH SIDES OF THE SAME DECISION. DIVE-2099 gave a NAMED agent
  # STANDING authority over tier-1 engineering approvals, and `_gate_lead_standing_eligible`
  # already decides whether a given gate is in scope. So `cmd_task_answer` ALREADY knows
  # this gate is lead-clearable while the router does not — and a gate a lead is ALLOWED
  # to clear must not be DELIVERED to a human. The predicate is REUSED verbatim rather
  # than restated: two copies of "is this lead-clearable" are two things that can
  # disagree, and the dangerous direction of disagreement is the router handing an agent
  # a gate the answer path will then refuse.
  #
  # SEALED SOURCE, NEVER THE CHART. The fallback holder is `_gate_standing_lead` — the
  # agent named in the constitution, trusted only while the live bytes still match the
  # digest sealed into the council lineage. `agents_org` is agent-writable on a
  # NOPASSWD:ALL host, which is exactly why DIVE-2099/2233 anchored authority to the seal;
  # resolving THIS fallback from the chart would hand back the self-grant path they closed
  # (re-parent yourself above the root, receive the root's gates). Note the direction the
  # widening runs: the standing lead can ALREADY clear these gates unrouted (the DIVE-2099
  # branch ignores `routed_reviewer` entirely), so this moves who is PINGED and shown the
  # gate, never who may answer it.
  #
  # NARROW, AND FAIL CLOSED THREE WAYS — the ticket's negative arm is "do NOT widen this
  # to route ALL unrouteable gates to the lead":
  #   1. only when the chart resolves NOBODY. A filer who has a lead keeps that lead, and
  #      a `decision` the root files (agent-clearable by type already) is untouched.
  #   2. only when `_gate_lead_standing_eligible` says yes — `approval`, tier exactly 1, a
  #      POSITIVE engineering classification, minus the tier-2 floor and the deny list. A
  #      money/secret/brand/customer-box/tier-2 gate filed by the root still reaches the
  #      human. That is the arm that stops this becoming a way to launder a hard gate past
  #      a person, and it is why the eligibility predicate is the whole condition rather
  #      than a piece of it.
  #   3. only when the seal resolves a plain name that is NOT the filer. Drifted, unsealed,
  #      no `authority.eng_approval_lead` key, an empty value, no council loader in scope,
  #      or the root IS the named lead -> nothing -> the gate falls through to the human
  #      exactly as it does today. Fail closed, same direction as everything it reuses.
  #
  # The verifier route wins where it fired: that gate already has an agent routee, so this
  # is not the "nobody" case.
  #
  # `_sr_unrouteable` / `_sr_outcome` exist so the DECLINING branch is countable too.
  # The three weeks this ticket is about were invisible in the store: an unrouted gate
  # simply pinged the human and left no row saying a route had been ATTEMPTED and refused.
  # A fix that only records its successes leaves the next regression with nothing to count
  # (DIVE-3117's lesson, and its suppression row is the model).
  local _standing_route=0 _standing_target="" _sr_filer="" _sr_unrouteable=0 _sr_outcome=""
  if [[ "$_verifier_route" != "1" ]] && declare -F _gate_standing_lead >/dev/null 2>&1; then
    _sr_filer=$(task_actor "")   # DIVE-2518: the DERIVATION, never the `--from` claim — same line the reviewer resolution below takes, for the same reason (this decides who may later clear).
    if [[ -n "$_sr_filer" && -z "$(_gate_route_reviewer "$_sr_filer")" ]]; then
      _sr_unrouteable=1; _sr_outcome=not-standing-eligible
      local _sr_title; _sr_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
      # DIVE-2224: ask and title as SEPARATE arguments — pre-joining them lets a
      # bounded-distance pattern straddle the seam and GRANT on a phantom hit.
      if _gate_lead_standing_eligible "$type" "$tier" "$ask" "$_sr_title"; then
        _sr_outcome=no-standing-lead
        local _sr_lead; _sr_lead=$(_gate_standing_lead 2>/dev/null || printf '')
        if [[ -n "$_sr_lead" && "$_sr_lead" == "$_sr_filer" ]]; then _sr_outcome=standing-lead-is-filer; fi
        if [[ -n "$_sr_lead" && "$_sr_lead" != "$_sr_filer" ]]; then
          _standing_route=1; _standing_target="$_sr_lead"; _sr_outcome=routed
        fi
      fi
    fi
  fi

  # DIVE-3266: ROUTE ON ROW STATE, NOT ON THE ASK'S PROSE.
  #
  # Every routable KIND above classifies by reading text a human wrote for a human —
  # `_eng_ship` is a regex over the ask and the title, and with gate_builder_routing
  # OFF (the default) it is the ONLY live route for an ordinary builder ship gate.
  # Miss the regex and `routed_reviewer` stays NULL, which is the first clause of
  # cmd_task_inbox's human predicate: an unrouted gate IS a founder gate. Measured
  # 2026-08-11 filing DIVE-3224's own push gate — "open both PRs" lowercases to
  # `prs` and the member is `\bpr\b`, so the word boundary fails on a sentence that
  # was entirely about pushing a branch and opening PRs.
  #
  # A `Branch: <name>` line is the opposite kind of input: STRUCTURED STATE, written
  # deliberately by `task set-branch` / `task add --branch` and validated to a git
  # ref-name there. It is the same binding `5dive push` requires before it will push
  # this row, so a branch-bound row IS a ship handoff whatever the ask's wording is.
  # Read the binding; do not parse prose for it.
  #
  # NOT a widened regex (`prs`, `PR's`, `pull-request`, the next synonym — unbounded,
  # and each addition looks locally correct). This removes the class for rows that
  # already record the answer instead of enlarging the classifier.
  #
  # Scoped to ROUTING ONLY, deliberately. It does NOT feed the DIVE-1359 tier
  # downgrade: tier decides CLEARANCE, routing decides WHO IS WOKEN, and widening a
  # tier control to unblock a routing complaint is how a safety control gets widened
  # mid-ship. Same guards as eng-ship (tier_floored=0, the three routable types), and
  # the DIVE-1957 `--tier=2` veto plus the DIVE-2241 `_needs_human` backstop both run
  # BELOW this line, so a pinned or human-class gate still crosses it untouched.
  # Sibling instance of the same defect, one subsystem over: DIVE-3265, where the
  # merge gate scraped a branch name out of the maker's result prose and then demanded
  # that phantom branch land.
  local _row_ship=0
  if [[ "$tier_floored" == "0" && ( "$type" == "decision" || "$type" == "approval" || "$type" == "manual" ) ]]; then
    local _rowship_body _rowship_branch=""
    _rowship_body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${id};")
    # Split rather than `[[ … ]] && v=$(f)`: an assignment's rc is its last command
    # substitution's, so the helper's non-zero on "no binding" would leak into the
    # compound (the DIVE-2751 shape). Absorbed here instead of argued about.
    _rowship_branch=$(_push_branch_from_body "$_rowship_body" 2>/dev/null) || _rowship_branch=""
    [[ -n "$_rowship_branch" ]] && _row_ship=1
  fi

  local _routable=0
  case "$type" in
    decision) [[ "$tier" != "2" ]] && _routable=1 ;;
    approval|manual)
      if [[ "$tier_arg" != "2" ]]; then
        local _rt_title; _rt_title=$(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")
        # DIVE-2224: identical axis call as the filing floor -- an approval/manual
        # gate must not be routable by one rule and floored by another.
        case "$(_gate_floor_axis "$ask" "$_rt_title")" in ask|title-fallback) ;; *) _routable=1 ;; esac
      fi ;;
    # DIVE-1243: the manager-clearable class routes to the lead FIRST regardless
    # of tier — that is the whole point of the type. The ONLY fall-through to the
    # human is the T2 category floor (money/destructive/secrets), which sets
    # tier_floored=1 above. An access gate is therefore routable unless floored.
    access) (( tier_floored )) || _routable=1 ;;
  esac
  # DIVE-1359: an eng-ship gate is lead-routed by kind (set above), so it is
  # always routable regardless of type default / explicit --tier.
  [[ "$_eng_ship" == "1" ]] && _routable=1
  # DIVE-3266: a branch-bound row is lead-routed BY ROW STATE, for the same reason
  # eng-ship is by kind — routable-but-pref-gated would leave the human pinged, and
  # who is pinged is the entire complaint.
  [[ "$_row_ship" == "1" ]] && _routable=1
  # DIVE-1381: a content-curation gate is likewise lead-routed by kind.
  [[ "$_curation" == "1" ]] && _routable=1
  # DIVE-1480: an internal-ops/recovery gate the destructive floor over-fired on is
  # lead-routed by kind (set above), so the lead clears it instead of lodar.
  [[ "$_internal_ops" == "1" ]] && _routable=1
  # DIVE-2224 (answer A): a gate the floor declined to fire on BECAUSE the term was
  # in the title is lead-routed BY KIND. Being un-floored is not the same as being
  # routed -- with gate_builder_routing at its default (off) an ordinary tier-1 gate
  # still pings the paired human, so without this line answer A would move the tier
  # and change nothing about who gets woken, which is the entire point of the ticket.
  [[ "$_floored_by_title" == "1" ]] && _routable=1
  # DIVE-2089: a DECLARED-DISCUSSION appeal that survived every guard is
  # lead-routed by kind — the appeal's entire effect is "a reviewer instead of the
  # human", so it must not fall back to the human via the pref (rule 4).
  [[ "$_discusses_applied" == "1" ]] && _routable=1
  # DIVE-1495: a verifier-route gate is routable by kind (to the verifier agent).
  [[ "$_verifier_route" == "1" ]] && _routable=1
  # DIVE-3171: the standing-lead fallback is routable BY KIND, for the same reason
  # eng-ship is — `gate_builder_routing` defaults to OFF, so routable-but-pref-gated
  # would move the ROUTING byte and still ping the human, which is the entire thing the
  # ticket is about. And the root filer cannot reach the eng-ship kind to inherit its
  # bypass: that downgrade only fires when `_es_reviewer` is non-empty, i.e. when a chart
  # lead sits above the filer, which is precisely what the root does not have.
  [[ "$_standing_route" == "1" ]] && _routable=1
  # DIVE-3117: there is deliberately NO `_pfr_lead_route && _routable=1` line here.
  # Suppressing the verifier route is the WHOLE change: the gate then takes the
  # SAME path a push-for-review gate on a row with no loop already takes (eng-ship
  # by kind, or the pref), so the loop's existence stops being an input to routing
  # rather than becoming a second input pointing the other way. That is what the
  # ticket's negative arm asks for, and it is why a no-verifier row keeps its
  # routing byte-for-byte. Adding a line here would give a looped row a route a
  # non-looped one does not have — the eng-ship guards (a resolvable lead, no true-
  # human floor) would be crossed only in the one case that happened to be measured.
  # Graded both ways in tests/gate_verifier_route_unit.sh.
  # DIVE-1957: backstop — an EXPLICIT --tier=2 is the caller's hard-human contract
  # and no KIND-based override may cross it, so the DIVE-1145 promise ("we never
  # route a tier-2 gate, floored OR filed with an explicit --tier=2") holds by
  # construction instead of per-branch. eng-ship/curation/internal-ops are already
  # vetoed at the downgrade sites above; `access` is routable regardless of tier by
  # DIVE-1243 and was the last path a pinned gate could still reach an agent through.
  [[ "$tier_arg" == "2" ]] && _routable=0
  # DIVE-2241: THE constant resolution. A declared human-class capability resolves
  # to lodar — and "lodar" is not a name this router looks up, it is the human path
  # itself: refuse to hand the gate to ANY agent and let it fall through to
  # task_need_notify's human ping. That is what makes it a constant rather than a
  # row. It sits at the backstop with the DIVE-1957 tier-2 veto so no KIND-based
  # override above (eng-ship / curation / internal-ops / access / verifier-route)
  # can cross it — the verifier-route being the one this ticket exists to stop.
  [[ "$_needs_human" == "1" ]] && _routable=0
  # Record the declaration and what it did, at the moment it did it. DIVE-2093 will
  # PRINT the routing decision at file time; until it lands this row is the only
  # place a mis-declared gate is visible without diffing where it ended up.
  # DIVE-2054: task-store state for $ident, no channel proof — fenced.
  if [[ -n "$needs" ]]; then
    _task_store_audit_log "task need declared-capability" \
      "$( ((_needs_human)) && echo human-class || echo unrecognised )" 0 -- \
      "task=$ident" "type=$type" "declared=$needs" "filer=$actor" \
      "resolved=$( ((_needs_human)) && echo human || echo unchanged )" || true
  fi
  # DIVE-3117: record the suppression AT THE MOMENT IT HAPPENS, with the verifier it
  # would have gone to. The four measured instances were only findable because each
  # left a row naming its routed_reviewer; a fix that silently stops writing that
  # name leaves the next regression with nothing to count. `routed=` says where it
  # went INSTEAD — which is the pre-existing lead/human path, not a new one, so an
  # empty value here is the honest "no lead resolved, this fell through to the
  # human" and is exactly the state the DIVE-2004 warn below is about to explain.
  # DIVE-2054: task-store state for $ident, no channel proof — fenced.
  if [[ "$_pfr_lead_route" == "1" ]]; then
    # Split rather than `[[ … ]] && x=$(f)`: an assignment's rc is its last command
    # substitution's, and _gate_route_reviewer returns non-zero when it resolves
    # nobody — the DIVE-2751 shape, absorbed here instead of argued about.
    local _pfr_dest=""
    if [[ "$_routable" == "1" ]]; then _pfr_dest=$(_gate_route_reviewer "$(task_actor "")") || _pfr_dest=""; fi
    _task_store_audit_log "task need push-for-review verifier-route suppressed" ok 0 -- \
      "task=$ident" "type=$type" "filer=$actor" "verifier=${_vf-}" \
      "routed=${_pfr_dest:-human}" || true
  fi
  # DIVE-3171: one row per gate whose filer the ORG CHART could not route — recorded
  # AFTER the `tier_arg=2` / `_needs_human` backstops, so `routed=` is what actually
  # happened and not what this branch proposed. `outcome=` says which conjunct decided:
  # `routed` (the seal named a lead and it took the gate), `not-standing-eligible` (the
  # tier-2 floor / deny list / non-engineering / wrong type — acceptance arm 2, the human
  # keeps it), `no-standing-lead` (drift, unsealed, absent key — arm 3, fail closed), or
  # `standing-lead-is-filer` (the root IS the named holder; routing to them would be the
  # self-clear path). Without this the declining branches are indistinguishable from a
  # build that never had this code.
  # DIVE-2054: task-store state for $ident, no channel proof — fenced.
  if [[ "$_sr_unrouteable" == "1" ]]; then
    local _sr_routed=human
    [[ "$_standing_route" == "1" && "$_routable" == "1" ]] && _sr_routed="$_standing_target"
    _task_store_audit_log "task need org-root standing-route" ok 0 -- \
      "task=$ident" "type=$type" "tier=$tier" "filer=$_sr_filer" \
      "outcome=$_sr_outcome" "standing_lead=${_standing_target:-<none>}" "routed=$_sr_routed" || true
  fi
  if [[ "$_routable" == "1" ]]; then
    # DIVE-1243: `access` routing is intrinsic to the TYPE, so it does NOT wait on
    # the gate_builder_routing pref (which ship-gates the decision/approval/manual
    # routing rollout). The other types still honour the pref.
    # DIVE-1359: eng-ship routing is likewise intrinsic to the KIND — it bypasses
    # the pref too, so the fix is live under the default (pref OFF) posture.
    local _route; _route=$(_task_pref_get gate_builder_routing); _route="${_route:-off}"
    # DIVE-2224: a title-only floor is intrinsic to the KIND too, and must bypass the
    # pref for the same reason eng-ship does. Routable-but-pref-gated would have left
    # answer A moving the TIER while the human still got the ping -- two layers, and
    # only the second one decides who is woken.
    # DIVE-3266: row-state ship routing bypasses the pref too — a branch binding is a
    # harder fact than any regex hit, so pref-gating it would re-open the exact hole.
    if [[ "$_route" == "on" || "$type" == "access" || "$_eng_ship" == "1" || "$_row_ship" == "1" || "$_curation" == "1" || "$_internal_ops" == "1" || "$_discusses_applied" == "1" || "$_verifier_route" == "1" || "$_floored_by_title" == "1" || "$_standing_route" == "1" ]]; then
      # DIVE-1495: a verifier-route targets the task's verifier directly; every
      # other kind resolves the filer's lead via the org chart.
      local _reviewer
      # DIVE-2518: THIS is the routing decision — the one thing `--from` DECIDED
      # rather than recorded, since routed_reviewer is who may later CLEAR the gate.
      # It takes `task_actor ""` (the derivation) and NOT `$actor`, which carries the
      # claim so that `gate_filed_by` can keep naming a uid-less relay principal.
      # Recording the claim and obeying it are different things, and this is the line
      # where they part. Graded by T23, which seeds two DIFFERENT leads so a claim
      # that won would route somewhere visible.
      # DIVE-3171: the standing-lead fallback resolves from the SEAL, and only in the
      # case the chart already answered "nobody" — so it can never re-point a gate the
      # chart did route.
      if [[ "$_verifier_route" == "1" ]]; then _reviewer="$_route_target"
      elif [[ "$_standing_route" == "1" ]]; then _reviewer="$_standing_target"
      else _reviewer=$(_gate_route_reviewer "$(task_actor "")"); fi
      if [[ -n "$_reviewer" ]]; then
        # Persist the designated reviewer on the row. For approval/manual this is
        # what authorizes agent-<_reviewer> to clear the gate later; for decision
        # it is provenance only (decision is already agent-clearable by type).
        # DIVE-3171: record WHY this reviewer, in the same statement that records WHO.
        # `cmd_task_answer` reads this to decide whether the clear is stamped `lead:`
        # or `lead:standing:`, and the two facts must not be able to arrive separately
        # — a row naming a reviewer with no source is the state this column exists to
        # abolish. NULL therefore means "a build before this one wrote the name", never
        # "the route had no source". Sibling to floor_provenance on the tier axis.
        local _route_prov=chart
        [[ "$_verifier_route" == "1" ]] && _route_prov=verifier-loop
        [[ "$_standing_route" == "1" ]] && _route_prov=seal:standing-lead
        db "UPDATE tasks SET routed_reviewer=$(sqlq "$_reviewer"), route_provenance=$(sqlq "$_route_prov") WHERE id=${id};"
        local _rrole="lead review"; [[ "$_verifier_route" == "1" ]] && _rrole="verifier review"
        # DIVE-3171: name the SEALED fallback distinctly. "lead review" would read as the
        # org chart having resolved somebody, and the whole point of this branch is that
        # it did not — the reader needs to know which source picked this reviewer.
        [[ "$_standing_route" == "1" ]] && _rrole="standing lead review (org root: no chart lead above the filer)"
        # DIVE-2093: the routable cascade above is a DISJUNCTION, so "which clause
        # fired" is a short-circuit artefact and not a fact about the gate. Name the
        # most SPECIFIC kind that applies instead — that is the one the filer can act
        # on. The pref is reported only when no kind applies, because then it really
        # is the only reason this gate routed at all.
        #
        # DIVE-2093 iteration 3 (main2's blocker 2): the standing arm sits at the BOTTOM,
        # immediately above the pref. A specific KIND still wins when one applies — the
        # standing route decides the TARGET, not what made the gate routable — but when
        # no kind applies, `_standing_route` is why this routed and the pref is NOT, so
        # reporting `gate_builder_routing=on` there is the same false-basis defect this
        # row exists to fix, one field over.
        local _rtrigger
        if   [[ "$_verifier_route"   == "1" ]]; then _rtrigger="verifier-route"
        elif [[ "$type"              == "access" ]]; then _rtrigger="access-type"
        elif [[ "$_eng_ship"         == "1" ]]; then _rtrigger="eng-ship"
        # DIVE-3266: BELOW eng-ship on purpose. When the ask/title already read as an
        # eng ship, that is what the filer can act on and every existing receipt stays
        # byte-for-byte; `row-ship-state` is named only when the BINDING is the sole
        # reason this routed — i.e. exactly the case the prose classifier missed.
        elif [[ "$_row_ship"         == "1" ]]; then _rtrigger="row-ship-state"
        elif [[ "$_curation"         == "1" ]]; then _rtrigger="curation"
        elif [[ "$_internal_ops"     == "1" ]]; then _rtrigger="internal-ops"
        elif [[ "$_discusses_applied" == "1" ]]; then _rtrigger="declared-discussion"
        elif [[ "$_floored_by_title" == "1" ]]; then _rtrigger="floored-by-title"
        elif [[ "$_standing_route"   == "1" ]]; then _rtrigger="standing-lead"
        else _rtrigger="gate_builder_routing=on"
        fi
        # DIVE-2093 iteration 3 (main2's blocker 1): the basis is `$_route_prov` ITSELF,
        # not a second variable derived alongside it. The old code kept `_rbasis` as a
        # parallel two-valued lead/verifier flag, so DIVE-3171's THIRD route landed in
        # the catch-all and the prose asserted an `agents_org.reports_to` edge that by
        # construction does not exist — main's own comment four lines up names that exact
        # hazard. One assignment now feeds the DB column and the sentence, so they cannot
        # diverge, and a FOURTH route cannot be added without `_gate_route_why` seeing a
        # basis string it does not know (which it now reports as unknown, not as chart).
        local _rwhy
        _rwhy=$(_gate_route_why "$_route_prov" "$_reviewer" "$(task_actor "")" "$_rtrigger")
        # DIVE-2093 (2026-08-07 recurrence, DIVE-2808): the sharper variant. Routing
        # reached a principal who could ANSWER and could not SIGN, which is worse than
        # the original "could not act", because it fails SILENTLY at answer time and
        # surfaces on somebody ELSE's command — the board shows an APPROVED gate whose
        # authorization no privileged path will honour, and a closed-unsigned gate looks
        # DONE where a pending-on-the-wrong-person one at least looks unfinished.
        #
        # DIVE-2760 already warns the ANSWERER when the mint comes back empty, and that
        # notice fires correctly. It shortens the loop, it does not close it: by then a
        # diff has been read and an answer given. Filing is the only point at which
        # nobody has yet acted, so this is where the check belongs.
        #
        # Deliberately narrow (DIVE-1955 wallpaper): require_sig is 1 only on the push
        # and deploy root executors, so this fires only when the ask is push/deploy
        # shaped. It is a warn and never a `fail` — the same reasoning as DIVE-2760's
        # write: a gate no broker will ever check is unharmed by an unsigned closure,
        # and refusing the filing would cost more than the misroute does.
        local _rsig="" _cs="" _csv="" _csc=""
        if _gate_eng_ship_hit "$ask" || [[ "$_eng_ship" == "1" ]]; then
          _cs=$(_gate_seat_can_sign "$_reviewer"); _csv="${_cs%%|*}"; _csc="${_cs#*|}"
          case "$_csv" in
            yes) _rsig=" [require_sig: ${_reviewer} can sign this closure (grant=${_csc})]" ;;
            no)
              _rsig=" [require_sig: ⚠ ${_reviewer} CANNOT sign this closure (grant=${_csc}) — see the warning above]"
              warn "$ident routed to $_reviewer, who CANNOT MINT A CLOSURE SIGNATURE (sudo grant: ${_csc})."
              warn "  This ask is push/deploy shaped, and the root-only executor verifies the"
              warn "  DIVE-756 signed closure before any delegated push or deploy."
              warn "  what happens if you leave it: $_reviewer can ANSWER the gate and the board"
              warn "    will show it APPROVED — but need_answer_sig lands EMPTY, and the push is"
              warn "    REFUSED later, on the MAKER's command, reading as tampering rather than"
              warn "    as this (DIVE-2760/2808). 'task answer' is not a re-sign verb, so the"
              warn "    only repair at that point is to re-file the gate from scratch."
              warn "  fix: get it answered from a seat that signs — root (\`sudo 5dive task answer"
              warn "    $ident ...\`) or an agent whose grant is root-all/cli-root; --tier=2 if it"
              warn "    is genuinely the human's. Do NOT grant \`gate-proof sign\` to a cli-scoped"
              warn "    seat: it signs arbitrary stdin, so the grant forges ANY closure, human:* included."
              ;;
            *) _rsig=" [require_sig: whether ${_reviewer} can sign is NOT MEASURABLE from this seat (grant=${_csc}) — unknown, not a no; check it first if a delegated push is refused later]" ;;
          esac
        fi
        # DIVE-2011: the handoff goes through the SAME delivery assertion as the
        # human ping (task_need_notify dispatches on TASK_GATE_ROUTE_TO), so a
        # routed gate can no longer exit without a delivery verdict or leave the
        # one dataset DIVE-1968 reads with no row for it. TASK_GATE_FILER pins the
        # send's `--from` to the gate's own filer for the same reason the human
        # path sets it: under `sudo -u agent-X` the ambient identity is the
        # invoker, not the filer.
        local _nrc=0
        TASK_GATE_FILER="$actor" TASK_GATE_ROUTE_TO="$_reviewer" TASK_GATE_ROUTE_ROLE="$_rrole" \
        TASK_GATE_FLOORED_BY="$([[ "$_floored_by_title" == "1" ]] && printf 'title' || printf '')" \
          task_need_notify "$ident" "$type" "$ask" "$options" "$recommend" || _nrc=$?
        # Never print a bare "routed to X" on an unobserved send again. The claim
        # is exactly what the delivery state supports: pinged, not-yet, or NOT.
        local _rstate="${TASK_GATE_ROUTE_STATE:-inflight}" _rnote=""
        # DIVE-2011 (olivia's second finding on DIVE-1968, read off the installed
        # binary): this audit row's result was a HARDCODED "ok", so the routed rail
        # did not merely emit nothing to the telemetry — it emitted a GREEN row for a
        # send whose exit status had been discarded. An absent row is a gap; a false
        # green is worse, because it is the shape a reader trusts. The row now
        # carries the delivery verdict, and is only `ok` when the send was confirmed.
        local _rres="ok" _rrc=0
        [[ "$_rstate" == "failed" ]] && { _rres="error"; _rrc=1; }
        # DIVE-2054: internal lead-routing telemetry keyed off task-store data —
        # unlike the escalate-to-human/clear-recs exemptions this carries no
        # channel/chat proof, so fenced (not exempted).
        _task_store_audit_log "task need lead-route" "$_rres" "$_rrc" -- "task=$ident" "type=$type" \
          "reviewer=$_reviewer" "filer=$actor" "delivery=$_rstate" || true
        case "$_rstate" in
          delivered) ;;
          inflight)  _rnote=" [handoff dispatched — delivery not yet confirmed; the gate-delivery row lands when the send completes]" ;;
          *)         _rnote=" [HANDOFF NOT DELIVERED — ${_reviewer} was NOT pinged${TASK_NOTIFY_FAIL_REASON:+ (${TASK_NOTIFY_FAIL_REASON})}; the gate stands, the re-nag escalates it (<=15 min), and it is answerable now with: 5dive task answer ${ident}]" ;;
        esac
        # DIVE-2224: when the floor declined to fire only because the term was in the
        # TITLE, say so HERE. A stderr warn is not the durable surface -- the routed
        # reviewer reads this line, and "escalate if the ask really is asking for
        # that" is only actionable if they are told which term and from where.
        # DIVE-2751 iteration 4 — decided explicitly rather than left as "guarded in
        # practice". An assignment's rc is its LAST command substitution's, so
        # `[[ test ]] && v="...$(f)..."` hands f's status to the compound with the
        # test TRUE. `_ft_title` is the text that just matched, so the helper does
        # return 0 here — but "in practice" is exactly the reasoning the previous
        # three iterations got wrong, and this false rc arrives from the RHS, where
        # no detector that classifies the LEFT side of `&&` can ever see it. Split
        # so the status is absorbed instead of argued about.
        local _fbt="" _fbt_term=""
        if [[ "$_floored_by_title" == "1" ]]; then
          _fbt_term=$(_gate_tier2_floor_term "$_ft_title" 2>/dev/null) || _fbt_term=""
          _fbt=" [floored_by=title: the T2 category floor matched '${_fbt_term}' in the TASK TITLE, not in the ask — escalate to the human if the ask really is asking for that]"
        fi
        ok "$ident routed to $_reviewer for ${_rrole} ($type, tier $tier)${_rnote}${_fbt}${_rsig} [${_rwhy}] — $ask" \
           '{id:($i|tonumber), ident:$id, status:"blocked", need_type:$ty, tier:($tr|tonumber), routed_to:$rv, route_basis:$rb, route_trigger:$rt, require_sig_seat:(($cs|select(length>0)) // null), delivery:$ds, notified:($ds=="delivered"), ask:$ak, recommend:(($rc|select(length>0)) // null)}' \
           --arg i "$id" --arg id "$ident" --arg ty "$type" --arg tr "$tier" --arg rv "$_reviewer" --arg ds "$_rstate" --arg ak "$ask" --arg rc "$recommend" \
           --arg rb "$_route_prov" --arg rt "$_rtrigger" --arg cs "$_csv"
        # No separate undelivered row: the lead-route row above already carries
        # delivery=<state>, and a second row for the same event is how one send
        # becomes two data points (the re-inflation DIVE-1968 spent a round undoing).
        return
      fi
    fi
  fi

  # DIVE-2004: LOUD AT FILE TIME. Reaching here means the gate was NOT lead-routed,
  # so it has no routed_reviewer. A `decision` in that state can be answered by any
  # agent, which is exactly why delegated push will not accept it — and the filer
  # only finds out later, from a refusal that reads as if the answerer was at
  # fault. If the ask is push-for-review shaped, say so now, while the filer is
  # still standing here and re-filing costs nothing. Deliberately narrow: the ask
  # must LOOK like a push gate, the type must be the one push cannot attribute, and
  # the gate must be unrouted — a warning that fires on ordinary decisions would be
  # wallpaper (DIVE-1955).
  #
  # DIVE-2612 extends this, and it is two separate defects — both found by grading
  # DIVE-2610, a tier-1 eng-ship APPROVAL filed by the org root that came out
  # unrouted, pinged the human, and could then be lead-cleared by nobody.
  #
  #   1. THE SCOPE WAS INVERTED. An unrouted `decision` is answerable by ANY agent;
  #      an unrouted `approval`/`manual` is answerable by NO agent — cmd_task_answer's
  #      provenance floor makes those types human-only, and routed_reviewer is the
  #      SOLE basis for the designated-reviewer exception to it. The warning fired
  #      for the recoverable case and stayed silent for the unrecoverable one.
  #   2. THE REMEDY TEXT WAS FALSE FOR THE ONE FILER IT COULD NOT HELP. "Re-file
  #      with --type=approval (it routes to the org lead ...)" assumes the org
  #      resolver returns somebody. For the ROOT of the org chart it never can:
  #      _gate_route_reviewer tries reports_to, then _task_resolve_coordinator, and
  #      skips any candidate equal to the filer — and absent a literal
  #      role='coordinator' row the coordinator IS the unique root, so both
  #      candidates are the filer and it falls off the end empty. Following that
  #      advice would move the root from "clearable by any agent" to "clearable by
  #      none". So the clause is now printed ONLY when the resolver returns a name.
  #
  # The approval/manual arm is scoped to `_routable=1` on purpose. A tier-2 floored
  # or human-class-declared gate is human-only BY DESIGN, and announcing that there
  # would be the wallpaper DIVE-1955 warns about. This fires only where human-only
  # is an ACCIDENT of the resolver coming back empty.
  local _u_warn=0
  if _gate_eng_ship_hit "$ask"; then
    case "$type" in
      decision)        _u_warn=1 ;;
      approval|manual) [[ "$_routable" == "1" ]] && _u_warn=1 ;;
    esac
  fi
  if (( _u_warn )); then
    # Resolved here rather than reused from `_es_reviewer`: that one is set only
    # inside the eng-ship downgrade block (tier_floored=0, ask-OR-title hit), so it
    # is unset on paths that reach here — and an unset remedy predicate is exactly
    # the defect being fixed.
    local _u_filer _u_reviewer _u_msg
    _u_filer=$(task_actor "")
    _u_reviewer=$(_gate_route_reviewer "$_u_filer")
    local _u_noroute="the org chart resolves no reviewer for ${_u_filer} (for the root of the chart the coordinator fallback resolves to themselves), so re-filing will not route it either"
    if [[ "$type" == "decision" ]]; then
      _u_msg="$ident is a push-for-review ask filed as --type=decision with no routed reviewer, so '5dive push' will REFUSE it: an unrouted decision can be answered by any agent, and push only accepts a human, a lead-clear, or a decision answered by this gate's own routed reviewer."
      if [[ -n "$_u_reviewer" ]]; then
        _u_msg+=" Re-file with --type=approval (it routes to $_u_reviewer as a tier-1 they can clear), or keep the decision and route it to a reviewer."
      else
        _u_msg+=" Do NOT re-file it as --type=approval: ${_u_noroute} — and an unrouted approval can be cleared by NO agent at all, only by the paired human. Keep the decision (any agent can answer it) or route it to a reviewer explicitly."
      fi
    else
      _u_msg="$ident is a push-for-review ask filed as --type=$type with no routed reviewer, so NO AGENT CAN CLEAR THIS GATE — it is human-only. approval/manual are human-only unless routed, and routed_reviewer is the sole basis for the designated-reviewer exception in 'task answer', so this gate now sits on the paired human and no agent can lift it."
      if [[ -n "$_u_reviewer" ]]; then
        _u_msg+=" $_u_reviewer is your reviewer in the org chart but this gate did not route to them — re-file as --type=decision (lead-clearable by design) if a lead can resolve it."
      else
        _u_msg+=" ${_u_noroute}; --type=decision is the only shape any agent could clear."
      fi
    fi
    warn "$_u_msg"
  fi

  # DIVE-105: DM the paired human right now so the gate doesn't sit unseen.
  # `|| true` + the helper's own self-gating make this fully best-effort — a
  # failed DM must never fail the gate write that just committed above.
  # DIVE-891: tier 1 gates still notify (they're answerable early); the 48h TTL
  # is a backstop, not a silencer. Only tier 0 skips the ping.
  # DIVE-916: mint the per-gate HUMAN nonce for hard human gates (approval/
  # secret/manual — the types `task answer` enforces as human-only). Store ONLY
  # its hash; the raw nonce is handed to task_need_notify to embed in the tap
  # callback_data. It is never printed to stdout, so the agent that filed the
  # gate never sees it. decision gates are agent-clearable → no nonce.
  # DIVE-1243: `access` mints a nonce too. It only reaches this human-ping path
  # when it FELL THROUGH to a human — either the T2 category floor fired (genuine
  # human-territory) or the org named no distinct lead (the filer IS the lead, who
  # is re-escalating). Both are legitimate human clears, so it needs the same
  # tap-safe nonce as approval/secret/manual for the Telegram tap.
  #
  # DIVE-2356 (from the DIVE-2355 measurement): the mint was gated on gate TYPE
  # ALONE, and the "decision gates are agent-clearable → no nonce" line above is
  # true only at tier 0/1. A `decision` FLOORED to tier 2 is by definition NOT
  # agent-clearable — the DIVE-1117 floor refuses a non-human answer on it — yet
  # it minted nothing, so it carried no per-gate human evidence at all. Measured
  # across every answered gate on the live board: approval/manual/secret tier-2
  # were 40/40 nonce-SET, decision tier-2 was 4/47 (and those 4 came from the
  # escalate-to-human path below, the one unconditional mint). So the mint
  # condition is now "hard-human TYPE **or** tier>=2", which is what the DIVE-916
  # comment always meant by "the types `task answer` enforces as human-only".
  #
  # ORDERING, DELIBERATE — this ships ALONE. The companion rule (refuse a tier-2
  # answer whose human_nonce_hash IS NULL) must NOT land until tier-2 decision
  # gates have accumulated nonces in the wild: shipped together, it would refuse
  # the overwhelming majority of tier-2 decision answers, i.e. the dominant
  # working path. Safe to land alone on the ANSWER side, which is the side that
  # could break: the tier-2 floor in cmd_task_answer is provenance-only
  # (`(( ! human ))`), and the DIVE-916 evidence block never fires for `decision`.
  #
  # BUT THE HASH IS NOT INERT, AND AN EARLIER DRAFT OF THIS COMMENT SAID IT WAS.
  # `_proof_ledger` (cmd_proof.sh) counts a done row as an ASK when
  # `human_nonce_hash IS NOT NULL`, as an OR-arm beside the human-answered test,
  # and the published zero-human badge is `1 - asks/shipped`. Measured on the live
  # board when this landed: 704 shipped, 101 asks, of which 20 came from the nonce
  # arm ALONE — rows with no human answer at all, counted only because a nonce
  # existed. So widening the mint moves a PUBLISHED METRIC DOWNWARD, and every
  # future tier-2 decision joins that arm.
  #
  # That is intended, not incidental. A tier-2 decision IS a human ask; counting
  # it is more truthful than not, and the ledger's own header says the arm is
  # deliberately conservative so the badge understates autonomy rather than
  # flattering it. Named here because the comment above that query warns against
  # moving this metric as a SIDE EFFECT — which is a rule about surprise, not
  # about direction, and so applies to lowering it too.
  #
  # If you are here to add a nonce mint somewhere new: check what it does to the
  # ledger before you assume it is a no-op. This one was assumed to be.
  #
  # THE EMIT HALF NOW LANDS ALONGSIDE THIS (DIVE-2233 item 2). An earlier draft of
  # this comment said the nonce was "not yet reachable by a decision TAP" and
  # deferred it as a plugin-side ticket. `_task_gate_reply_markup` now appends
  # `:${nonce}` to the decision option buttons too, and the answer path verifies it
  # (see the tier-2 floor in cmd_task_answer). What made that safe rather than a
  # plugin break is graded in gate_t2_nonce_proof_unit S12b/S12e: the DEPLOYED
  # TNA_RE accepts the wider callback_data unchanged, and the fork scan reads each
  # tna.ts variant's OWN on-disk regex rather than assuming. Two forks (opencode,
  # pi) still parse the option token greedily and would swallow the nonce — they
  # are named, fenced by that arm, and tracked, not silently shipped past.
  #
  # STILL NOT DONE HERE, and this is the part that must stay undone: refuse a
  # tier-2 answer whose human_nonce_hash IS NULL. The floor is scoped to gates that
  # HAVE a nonce (S16), so every gate already in flight keeps clearing. See the
  # ORDERING note above — refuse-on-NULL waits for tier-2 decisions to accumulate
  # nonces in the wild.
  # THE MINT ITSELF HAS MOVED UP (DIVE-2054 ordering fix, above the first tasks UPDATE):
  # a tier-2 gate that cannot arm itself must refuse BEFORE any row is written, not after.
  # Only the persist survives here.
  [[ -n "$human_nonce" ]] \
    && db "UPDATE tasks SET human_nonce_hash=$(sqlq "$(_human_nonce_sha "$human_nonce")") WHERE id=${id};"
  # DIVE-1927: rc 3 = filed and answerable, but NOBODY was pinged. The gate always
  # stands — the dashboard "Needs you" card, `task inbox` and `task answer` need no
  # channel, and a headless/solo/CI box answers gates exactly that way. What must
  # never happen is an unnotified gate reading identically to a notified one, which
  # is the indistinguishability this whole ticket started from, so the miss is
  # marked on the result, logged as a delivery error, left with gate_pinged_at NULL
  # and re-driven by the 15-minute re-nag until it lands.
  # TASK_GATE_FILER pins the escalation chain to the gate's OWN filer. Without it
  # the chain starts from the ambient identity (auto_sender_from_sudo), which under
  # a `sudo -u agent-X` invocation is the INVOKER, not the filer — so the walk
  # would climb the wrong branch of the org chart.
  local _nrc=0
  TASK_GATE_FILER="$actor" \
    task_need_notify "$ident" "$type" "$ask" "$options" "$recommend" "$secret_key" "$connector" "$human_nonce" "$precedent_cite" || _nrc=$?
  # DIVE-2010: this used to also require $EUID to be root before auditing — the
  # exact anti-pattern audit.sh's own audit_log doc says never to use (it
  # predates _emit_audit_line's non-root privileged fallback, DIVE-1989) AND
  # carried no store-identity fence, so a fixture-TASKS_DB suite run as root
  # wrote real-looking rows with fixture idents into the real audit log. Fixed
  # by dropping the root condition (audit_log/_task_store_audit_log handle the
  # non-root case) and routing through the store fence instead.
  [[ "$_nrc" == "3" ]] \
    && _task_store_audit_log "task need unnotified" "error" 1 -- "task=$ident" "type=$type" "filer=$actor" || true
  # DIVE-2089 defect 2 — the floor was SILENT about WHY. "[tier forced to 2 — T2
  # category floor]" says an escalation happened but not what caused it, so the
  # filer cannot tell a correct escalation from a subject-matter false positive,
  # and cannot act on either. dev3 discovered their sizing gate had been floored
  # only by re-reading it; an agent that files and moves on leaves a design
  # question in the founder's inbox indefinitely. Name the matched term on the
  # result AND warn on stderr, and — for a decision gate, the one type where an
  # appeal exists — say what the sanctioned appeal is. Stating the appeal here is
  # the anti-laundering lever: the filer who would otherwise re-file with neutral
  # wording is shown an attributable, audited path to the same audience.
  local floor_note="" floor_term=""
  # DIVE-2241: a DECLARED human-class gate is also tier_floored, but it did not get
  # there by the keyword floor — so it must not wear the floor's explanation. Saying
  # "the T2 category floor fired" over a declaration is wrong twice: it credits a
  # match that may not exist (floor_term comes back empty and the note degrades to a
  # bare claim), and it hands the filer the --discusses appeal for a category call
  # they made THEMSELVES. Nobody should be invited to appeal their own declaration.
  if [[ "$_needs_human" == "1" ]]; then
    floor_note=" [tier 2 — DECLARED --needs=${needs}, a human-held capability; routed to the paired human, not to a lead or verifier]"
    warn "this gate is hard-human because you DECLARED --needs=${needs}. It bypasses lead- and verifier-routing by constant, and only the paired human can answer it. If the ask does not actually consume that capability, withdraw and re-file without --needs — do not appeal it, the declaration is yours."
  elif (( tier_floored )); then
    # DIVE-2751: `_gate_tier2_floor_term` is trailing-test-terminated — it returns 1
    # when it finds no term — so this PLAIN assignment made "the floor fired but the
    # helper could not name the word" kill `task need` under `set -e`. The helper's
    # own rc contract is left alone (a value producer may report "no match"); the
    # call site absorbs it, exactly as the two sites at _floor_term above already do.
    floor_term=$(_gate_tier2_floor_term "${ask} $(db "SELECT COALESCE(title,'') FROM tasks WHERE id=${id};")") || floor_term=""
    floor_note=" [tier forced to 2 — T2 category floor${floor_term:+: matched '$floor_term'}]"
    local _fw="this gate was FORCED to tier 2 (hard human) by the T2 category floor"
    [[ -n "$floor_term" ]] && _fw="$_fw because the ask or the task title contains '${floor_term}'"
    if [[ "$type" == "decision" && -z "$discusses" ]]; then
      _fw="$_fw. The floor matches SUBJECT MATTER, not the action you asked for. If this decision only DISCUSSES that category and performs nothing, re-file with --discusses=\"<why>\" — it is recorded on the gate and routed to your lead. Do NOT reword the ask to dodge the floor: that reaches the same audience with no record of how."
    else
      _fw="$_fw. It is answerable only by the paired human."
    fi
    warn "$_fw"
  fi
  local prec_note=""; [[ -n "$precedent_cite" ]] && prec_note=" [${precedent_cite}]"
  # rc 3 = filed, answerable, but nobody was PINGED. Say so on the record instead
  # of letting an unnotified gate read exactly like a notified one — that
  # indistinguishability is the whole defect this ticket started from.
  local notified=1 unnotified_note=""
  if [[ "$_nrc" == "3" ]]; then
    notified=0
    unnotified_note=" [UNNOTIFIED — nobody was pinged; answer on the dashboard or: 5dive task answer ${ident}]"
  fi
  # DIVE-3266: SAY THAT IT DID NOT ROUTE, AND NAME THE AXIS THAT DECIDED.
  #
  # Reaching here means routed_reviewer is NULL, and an empty routed_reviewer is the
  # FIRST clause of cmd_task_inbox's human predicate — so this gate is the paired
  # human's. The routed arm has printed WHO and WHY since DIVE-2093; this arm printed
  # a cheerful `OK — <id> needs a human (approval, tier 1)` and nothing else, so the
  # only difference between "routed to your lead" and "landed on the founder" was a
  # clause that ISN'T THERE. A reader cannot see an absent clause, and `--tier=1` is
  # no protection: tier and routing are separate axes and only routing keeps a gate
  # off the founder. Measured on DIVE-3224 (both receipts in this row's body).
  #
  # This is the cheap half of the fix and it is the half that generalises: it cannot
  # make the classifier right, but it converts a SILENT miss into a visible one, for
  # every miss including the ones no row-state binding can catch. Unconditional on
  # purpose — the DIVE-1955 wallpaper test asks whether a warning fires where nothing
  # is wrong, and here nothing is ever "not wrong": the founder is being woken every
  # time this line prints, and the reasons differ, so the reason is the payload.
  local _nr_reason
  if [[ "$_needs_human" == "1" ]]; then
    _nr_reason="a human-class capability was declared (--needs=${needs}), which resolves to the human by constant, not by lookup"
  elif [[ "$type" == "secret" ]]; then
    _nr_reason="secret gates are human-only by type and never route"
  elif [[ "$tier_floored" == "1" ]]; then
    _nr_reason="the T2 category floor fired${floor_term:+ on '${floor_term}'}, and a floored gate is human-only by class"
  elif [[ "$tier_arg" == "2" ]]; then
    _nr_reason="you passed --tier=2, a hard-human contract no routing kind may cross"
  elif [[ "$_routable" != "1" ]]; then
    _nr_reason="a $type at tier $tier is not routable by type"
  else
    # Routable, and it still did not route. Both remaining causes are invisible at
    # the filing site, and they take OPPOSITE remedies — re-word vs. do not bother.
    local _nr_rev _nr_pref
    _nr_rev=$(_gate_route_reviewer "$(task_actor "")") || _nr_rev=""
    _nr_pref=$(_task_pref_get gate_builder_routing); _nr_pref="${_nr_pref:-off}"
    if [[ -z "$_nr_rev" ]]; then
      _nr_reason="the org chart resolves no lead above $(task_actor "") (for the chart's root the coordinator fallback resolves to themselves), so re-wording or re-filing will not route it either"
    else
      _nr_reason="no routing kind matched — the ask and the row TITLE did not read as an eng ship, and this row carries no 'Branch:' binding — and gate_builder_routing is ${_nr_pref}, so ${_nr_rev} was never considered. Bind the branch (5dive task set-branch ${ident} <branch>) or say 'push-for-review'/'pull request' in the ask, then re-file"
    fi
  fi
  local _nr_note=" [NOT ROUTED — no lead was named, so this gate sits on the PAIRED HUMAN: ${_nr_reason}]"
  ok "$ident needs a human ($type, tier $tier)${floor_note}${prec_note}${unnotified_note}${_nr_note} — $ask" \
     '{id:($i|tonumber), ident:$id, status:"blocked", need_type:$ty, tier:($tr|tonumber), tier_floored:($fl=="1"), floor_term:(($ft|select(length>0)) // null), needs_capability:(($nc|select(length>0)) // null), needs_human:($nh=="1"), rubber_stamp_ok:(($rs|select(length>0)) // null), notified:($nf=="1"), routed_to:null, route_declined:$rd, ask:$ak, need_options:(($op|select(length>0)) // null), recommend:(($rc|select(length>0)) // null), precedent_ref:(($pr|select(length>0)|tonumber?) // null), assignee:$ac}' \
     --arg i "$id" --arg id "$ident" --arg ty "$type" --arg tr "$tier" --arg fl "$tier_floored" --arg ft "$floor_term" --arg nc "$needs" --arg nh "$_needs_human" --arg rs "$rubber_stamp" --arg nf "$notified" --arg rd "$_nr_reason" --arg ak "$ask" --arg op "$options" --arg rc "$recommend" --arg pr "$precedent_ref" --arg ac "$actor"
}

