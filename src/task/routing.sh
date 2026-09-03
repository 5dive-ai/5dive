# -------- 5dive task — routing --------
#
# Split out of src/cmd_task.sh (DIVE-3278): resolution + policy helpers: coordinator / deputy / QA lookup, verify-skip
# reasons, delivery paths, lane + WIP-cap arithmetic, the filing cap, and
# assignee resolution.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
# src/cmd_task.sh when the split tree is used (tests source src/cmd_task.sh).
# Function definitions only — never execute this file directly.
# Resolve the task-queue coordinator (DIVE-333): the agent who owns unassigned
# tasks so they don't stall (the heartbeat only wakes an assignee). Org-agnostic,
# resolved live from the org chart — never a hardcoded agent:
#   1. an agent explicitly tagged `--role=coordinator` (reuses the existing org
#      role field; the disambiguator a multi-root org sets), when exactly one holds it
#   2. else the lone agent carrying the coordinator MARKER inside their role prose
#      (DIVE-2041, below), when exactly one does
#   3. else the lone org root (the single-CEO case — zero config)
#   4. else empty — ambiguous (multi-root, none tagged) or empty org chart; we
#      leave the task unassigned exactly as before rather than guess wrong.
# Prints the coordinator name (or nothing). Safe on an empty/missing org table.
#
# DIVE-2041 — WHY TIER 2 EXISTS. `agents_org.role` does double duty: it is the
# human prose the org chart and council roster RENDER ("AI CEO — conducts the
# fleet (advisory)", "QA / testing") AND, at tier 1, an exact-match machine
# sentinel. So the only way to tag a coordinator was to DESTROY that agent's
# display text — which is exactly why DIVE-2031 was fixed by re-parenting an org
# root instead (option B, `org set olivia --role=coordinator`, was rejected for
# this reason). Tier 2 lets the marker live INSIDE the prose ("AI CEO — fleet
# coordinator"), so tagging costs nothing. Space-anchored so "coordinator"
# matches and "uncoordinated" does not, and uniqueness-checked like every other
# resolver here: >1 holder is ambiguous and yields nothing rather than a guess.
# Tier 1 is kept ahead of it so an exact tag still wins when prose elsewhere also
# mentions the word. Measured on the live chart 2026-08-09: zero of 13 roles
# contain the marker, so this tier adds no candidate today and the resolution
# stays on the lone-root fallback — it widens what an operator CAN express, it
# does not re-route anything already resolved.
_task_resolve_coordinator() {
  if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE role='coordinator';")" == "1" ]]; then
    db "SELECT name FROM agents_org WHERE role='coordinator' LIMIT 1;"
    return
  fi
  local _marker="lower(' '||COALESCE(role,'')) LIKE '% coordinator%'"
  if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE ${_marker};")" == "1" ]]; then
    db "SELECT name FROM agents_org WHERE ${_marker} LIMIT 1;"
    return
  fi
  if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org);")" == "1" ]]; then
    db "SELECT name FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org) LIMIT 1;"
  fi
}

# DIVE-969: verifier-by-default posture (Karpathy autonomy slider). Non-trivial
# work should get graded by someone other than the maker (writer!=grader,
# DIVE-474/477) UNLESS the creator explicitly opts out. These two helpers decide
# WHEN the default engages and WHO grades — deliberately conservative so trivial
# tasks stay frictionless and we never block an add.

# Is this task trivial enough to skip the verifier default? Trivial = low-signal
# work where a grading round-trip is pure overhead: low priority, OR a bodyless
# task whose title reads as a mechanical chore (typo/bump/rename/docs/lint/…).
# Anything with a real body or medium+ priority is treated as non-trivial.
#
# DIVE-1880: prints the REASON the rail is being skipped (empty = not trivial =
# the default engages). The reason exists so the skip can be ANNOUNCED at add
# time — a control that looks applied and is not is the defect this fixes.
_task_verify_skip_reason() {
  local _title="$1" _body="$2" _priority="$3"
  [[ "$_priority" == "low" ]] && { printf 'low priority'; return 0; }
  if [[ -z "$_body" ]]; then
    local t="${_title,,}"
    [[ "$t" =~ (^|[^a-z])(typo|typos|bump|rename|tweak|nit|nits|lint|format|reformat|comment|comments|whitespace|changelog|readme|docs|doc|wording|copy[[:space:]]fix|version[[:space:]]bump)([^a-z]|$) ]] \
      && { printf 'bodyless chore title'; return 0; }
  fi
  return 0
}

# DIVE-2719: THE DEPTH DECISION IS MADE AT THE ONE MOMENT IT CANNOT BE ANSWERED.
# _task_verify_skip_reason above runs at `task add`, where there is no branch, no
# diff and no PR — so it is forced onto the only axis that exists then: the words
# in the title. Measured on DIVE-2712: the title described a real user-facing
# Telegram defect (correctly), so it earned the full rail; the delivered change
# was ONE LINE in a test stub, and four verifier iterations graded it. No title
# classifier could have known — the fact had not happened yet.
#
# So re-ask the question at DELIVERY, where the answer is a MEASUREMENT instead
# of a guess: the paths the work actually touched. `task add`'s guess stays the
# provisional default; delivery either confirms it, downgrades it (nothing here
# a human round-trip can catch that CI does not) or upgrades it (a "docs" row
# that turned out to touch the scheduler).
#
# WHY THIS IS NOT THE done-time WAIVER DIVE-969 BANNED, which is the obvious
# objection: that ruling refuses a waiver the MAKER ASSERTS at peak
# completion-incentive (`task done --no-verify`). This asserts nothing. The input
# is the diff the work already produced — to be classified shallow you must have
# genuinely changed only tests/docs, and if you did, there is nothing for a
# grader to grade.
#
# THE ADD-TIME OPT-OUT IS RECORDED HERE, as of DIVE-2730, AND STILL LOSES TO THE
# UPGRADE — two claims, and the second is the load-bearing one. This comment once
# said the opt-out was "untouched"; main's review refuted it at source, because
# `--no-verify` was a local var in `task add` with no column behind it. It died
# with that process, so at `task done` a `--no-verify` row was INDISTINGUISHABLE
# from a DIVE-969 auto-skipped one — both read verifier NULL, verify_unavailable
# NULL. A decision and a default that produce the same stored state ARE the same
# state; no amount of downstream reasoning recovers the difference.
# `tasks.verify_optout` now stores it, so the override can be NAMED — which was
# the actual defect, the silence, not the override.
# The override itself is CORRECT and stays: the flag is declared at FILE time and
# the blast radius is measured at DELIVERY time, so honouring the flag here would
# let a sentence typed before the diff existed pre-authorise closing a scheduler
# or credentials change ungraded. That is a waiver in DIVE-969's banned direction,
# and it is the one way persisting this column could have turned a fix into a
# bypass. The filer opted out of ROUTINE grading, not of grading a diff they had
# not written yet.
# (`verify_unavailable=1` is the genuine self-handling case, by a different route:
# _task_default_verifier returns empty again in that org, so the upgrade cannot
# fire for want of a grader rather than for want of permission.)
#
# Print the changed paths of the delivery bound to task <id>, one per line.
# Empty output means UNKNOWN — no binding, no gh, no credential, no PR found —
# and unknown must stay unknown: every caller below treats it as "change
# nothing", so a missing credential can never widen OR narrow the rail.
_task_delivery_paths() {
  local _id="$1" _dref _body _branch="" _slug _tok _pr="" _n
  _dref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=${_id};")
  _body=$(db "SELECT COALESCE(body,'')         FROM tasks WHERE id=${_id};")
  [[ -n "$_dref" ]] || _branch=$(_push_branch_from_body "$_body")
  # No declared delivery at all -> return before spending a single gh call, so an
  # ordinary unbound close keeps its current latency exactly.
  [[ -n "$_dref" || -n "$_branch" ]] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  _tok=$(_gate_gh_token); [[ -n "$_tok" ]] || return 0
  _slug=$(_gate_task_repo_slug "$_dref" "$_body")
  if [[ "$_dref" =~ ^https?:// ]]; then
    _pr="$_dref"
  else
    # A bare `#N` delivery_ref is left to the merge gate's own DIVE-1955 refusal;
    # here it simply reads as unknown rather than being resolved against a guess.
    [[ -n "$_branch" && -n "$_slug" ]] || return 0
    _n=$(GH_TOKEN="$_tok" gh pr list --repo "$_slug" --head "$_branch" --state all \
           --json number -q '.[0].number' 2>/dev/null || echo "")
    [[ -n "$_n" ]] || return 0
    _pr="https://github.com/${_slug}/pull/${_n}"
  fi
  GH_TOKEN="$_tok" gh pr view "$_pr" --json files -q '.files[].path' 2>/dev/null || return 0
}

# Classify a path list (on stdin) as 'deep' | 'shallow' | '' (unknown/ordinary).
# PATH GLOBS ONLY — deliberately not a taxonomy (scope cap from the ticket: if
# this needs more than about ten entries the design is wrong).
#   deep    — any path in the blast radius where a human round-trip earns its
#             cost: the scheduler, the task store itself, credentials, deploy.
#   shallow — EVERY path is a test, a doc or a changelog fragment. CI is already
#             the gate for those; a verifier round adds latency and no signal.
#   ''      — anything else, and any empty list: current behaviour, unchanged.
# deep is checked first and wins outright, so a mixed set is never downgraded.
_task_delivery_depth() {
  local p have=0 all_shallow=1
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    have=1
    case "$p" in
      src/cmd_heartbeat.sh|src/cmd_task.sh|src/cmd_auth*|lib/db.sh|scripts/deploy*|\
      .github/workflows/*|install.sh|*credential*|*secret*|*token*)
        printf 'deep'; return 0 ;;
    esac
    case "$p" in
      tests/*|docs/*|changelog.d/*|*.md) ;;
      *) all_shallow=0 ;;
    esac
  done
  (( have )) || return 0
  (( all_shallow )) && printf 'shallow'
  return 0
}

# Boolean form, kept for readability at the call site.
_task_is_trivial() {
  [[ -n "$(_task_verify_skip_reason "$1" "$2" "$3")" ]]
}

# DIVE-2449: parse the narrow title shape that implies a numbered follow-up to
# an existing epic. This is deliberately NOT a generic DIVE-N mention parser:
# "follow-up to DIVE-2382" is ordinary prose, while "DIVE-2382 fix #3" carries
# the series coordinate that board readers otherwise mistake for a real parent
# link. Results are globals so callers can invoke this bare (rather than through
# a command substitution that would hide assignments).
_task_numbered_followup_parse() {
  local _title="${1^^}"
  local _re='(^|[^A-Z0-9])(DIVE-[0-9]+)[[:space:]]+(FIX|ORPHAN|PART|ITEM)[[:space:]]*#?([0-9]+)([^A-Z0-9]|$)'
  _TASK_FOLLOWUP_IDENT=""
  _TASK_FOLLOWUP_KIND=""
  _TASK_FOLLOWUP_NUMBER=""
  if [[ "$_title" =~ $_re ]]; then
    _TASK_FOLLOWUP_IDENT="${BASH_REMATCH[2]}"
    _TASK_FOLLOWUP_KIND="${BASH_REMATCH[3],,}"
    _TASK_FOLLOWUP_NUMBER="${BASH_REMATCH[4]}"
  fi
  return 0
}

# Inspect an unparented title and expose an advisory only when all of these are
# measured: the numbered-follow-up shape above, the cited ident exists, and no
# --parent was supplied by the caller. Open rows with the SAME coordinate are
# returned as a comma-separated ident list so the add output answers the
# existence question by text as well as warning that no graph edge was made.
# Empty/no-match is a normal result and always returns zero: an advisory must
# never make `task add` fail under set -e.
_task_unparented_followup_advisory() {
  local _title="$1" _target_ident _target_kind _target_number
  local _candidate_id _candidate_title _candidate_ident _matches=""
  _TASK_FOLLOWUP_WARN_IDENT=""
  _TASK_FOLLOWUP_WARN_KIND=""
  _TASK_FOLLOWUP_WARN_NUMBER=""
  _TASK_FOLLOWUP_WARN_MATCHES=""

  _task_numbered_followup_parse "$_title"
  _target_ident="$_TASK_FOLLOWUP_IDENT"
  _target_kind="$_TASK_FOLLOWUP_KIND"
  _target_number="$_TASK_FOLLOWUP_NUMBER"
  [[ -n "$_target_ident" ]] || return 0
  [[ "$(db "SELECT COUNT(*) FROM tasks WHERE upper(ident)=$(sqlq "$_target_ident");")" == "1" ]] || return 0

  while IFS= read -r _candidate_id; do
    [[ -n "$_candidate_id" ]] || continue
    _candidate_title=$(db "SELECT title FROM tasks WHERE id=${_candidate_id};")
    _task_numbered_followup_parse "$_candidate_title"
    if [[ "$_TASK_FOLLOWUP_IDENT" == "$_target_ident" \
       && "$_TASK_FOLLOWUP_KIND" == "$_target_kind" \
       && "$_TASK_FOLLOWUP_NUMBER" == "$_target_number" ]]; then
      _candidate_ident=$(db "SELECT ident FROM tasks WHERE id=${_candidate_id};")
      _matches+="${_matches:+,}${_candidate_ident}"
    fi
  done < <(db "SELECT id FROM tasks
               WHERE status NOT IN ('done','cancelled')
                 AND instr(upper(title), $(sqlq "$_target_ident")) > 0
               ORDER BY id;")

  _TASK_FOLLOWUP_WARN_IDENT="$_target_ident"
  _TASK_FOLLOWUP_WARN_KIND="$_target_kind"
  _TASK_FOLLOWUP_WARN_NUMBER="$_target_number"
  _TASK_FOLLOWUP_WARN_MATCHES="$_matches"
  return 0
}

# ---------------------------------------------------------------------------
# ── DIVE-2794 arm two: the per-LANE WIP cap ──────────────────────────────────
#
# Tokens cap what one row may SPEND; this caps how many rows a lane may HOLD.
# Same verb, same refusal path, same carve-out — one mechanism over two
# resources, because two independent refusals on `task add` would disagree,
# print different remedies, and teach the fleet that a failed add is noise.
#
# WHAT IS COUNTED: todo + in_progress only. Not blocked, not parked, not
# recurring templates. The fleet holds 55 blocked rows right now; a cap that
# counted them would be over on day one for every lane, with no satisfiable path
# back under — the unsatisfiable-gate shape we have shipped once and had to
# unwind. A blocked row consumes no attention, and attention is the resource.
#
# THE CAP IS FROZEN, NOT TRACKING. Initialised to the lane's own actionable count
# the first time the lane is seen, then it never moves except by a lead clear.
# A close lowers the COUNT, which is what creates headroom; it does NOT lower the
# cap. The first spec said every close lowers the cap, and that is a lock rather
# than a ratchet: after each close actionable == cap again, so the next add
# refuses forever and the lane drains to zero and stops working (caught in review
# before it was built). Frozen keeps every property that was actually wanted —
# close-one-to-file-one, no lane can grow, nobody defends a magic N.
_task_lane_actionable() {
  db "SELECT COUNT(*) FROM tasks
      WHERE assignee=$(sqlq "$1") AND kind='standard'
        AND status IN ('todo','in_progress') AND parked_at IS NULL;" 2>/dev/null || echo ""
}

# _task_wip_cap <lane> — READ ONLY. A lane with no INSTALLED cap is not capped,
# and the caller must treat a non-zero return as "no cap", never as zero.
#
# THE CAP IS INSTALLED, NEVER MINTED LAZILY, and the difference is the whole
# defect CI found. The spec says "initialise each lane's cap to its own
# actionable count AT INSTALL"; the first cut substituted "mint it the first time
# anyone looks", which is not the same thing and is strictly worse. Minting on
# first sight means the baseline is whatever the store happened to contain at
# that instant — so every harness that points FIVEDIVE_PROD_TASKS_DB at its own
# fixture (they do it deliberately, to exercise DIVE-2681) minted a cap from a
# half-built fixture and then refused the rest of its own setup. DIVE-2681's
# header already warns about exactly this: "a rig building a fixture is not a
# filing decision". A title-based cap survives it because fixture titles rarely
# classify; a COUNT-based cap cannot. Install is an explicit act
# (`5dive task wip-cap-install`), so a store nobody installed against is a store
# with no caps, which is the correct answer for every fixture and every fresh
# board.
_task_wip_cap() {
  local key="wip_cap:$1" cur
  cur=$(db "SELECT value FROM task_prefs WHERE key=$(sqlq "$key");" 2>/dev/null || echo "")
  [[ "$cur" =~ ^[0-9]+$ ]] || return 1
  # FLOOR OF 1, and this is the whole zero-lock defect rather than a rounding
  # nicety. A lane with no actionable rows mints cap 0, and `actionable >= cap`
  # is then 0 >= 0 — a breach — so an EMPTY lane could never accept its first
  # row. A brand-new agent would be frozen from birth, and any lane that
  # legitimately drained to empty would freeze permanently. That is the exact
  # drain-to-zero failure this arm's frozen cap was designed to avoid, let back
  # in through the INITIALISATION path instead of the update rule. Caught by CI
  # (gate_evidence_form_unit / audit_task_store_fence_unit both start from an
  # empty fixture lane), not by the arms I wrote — every one of those seeds rows
  # first, so none of them could see it.
  (( cur < 1 )) && cur=1
  printf '%s' "$cur"
}

# _task_lanes_with_headroom <exclude> — lanes strictly under their cap, for the
# redirect. Naming them is the whole point: "this lane is full" is a dead end,
# "this lane is full, dev2 and quinn have room" is a next action.
#
# DIVE-3366 — AND EVERY NAME IT OFFERS MUST BE DISPATCHABLE. This enumerates
# DISTINCT assignee over the whole tasks table, so any name anybody ever typed
# into that column becomes a suggestion the moment a cap exists for it. Measured
# 2026-08-13 while filing DIVE-3366: a refused `--assignee=dev2` offered ELEVEN
# lanes that are not registered agents — `__nosuchagent_probe__`, `cli`,
# `designer`, `distributor`, `editor`, `lodar`, `loop`, `proof`, `seo`,
# `tgfreeprobe`, `writer` — each reading "(1 free)" because `wip-cap-install`
# minted a ceiling for a name somebody once typed. This is the third live
# instance of the class DIVE-3344 fixed at `--assignee`, and it is the worst of
# the three: not a silent drop, but an active recommendation of an undispatchable
# lane, delivered at the exact moment the filer is looking for somewhere to put
# work — so the filer follows it, and the row is never picked.
#
# Roster-state-gated, not roster-emptiness-gated (`_task_require_lane`'s rule): a
# roster we could not establish must narrow nothing, or a box with an unreadable
# registry answers "no lanes have room" and the redirect becomes a dead end.
_task_lanes_with_headroom() {
  local skip="$1" lane cap act out=""
  _task_roster
  while IFS= read -r lane; do
    [[ -n "$lane" && "$lane" != "$skip" ]] || continue
    if [[ "$_TASK_ROSTER_STATE" == "ok" ]] && ! _task_roster_has "$lane"; then continue; fi
    cap=$(_task_wip_cap "$lane") || continue
    act=$(_task_lane_actionable "$lane")
    [[ "$act" =~ ^[0-9]+$ ]] || continue
    (( act < cap )) && out+="${out:+, }${lane} ($((cap - act)) free)"
  done < <(db "SELECT DISTINCT assignee FROM tasks WHERE assignee IS NOT NULL AND assignee!='' AND kind='standard';" 2>/dev/null)
  printf '%s' "$out"
}

# _task_lane_oldest <lane> <n> — the oldest actionable rows, so a refusal says
# what is actually holding the lane rather than only that it is held.
_task_lane_oldest() {
  db "SELECT '  · '||COALESCE(ident,'?')||'  '||substr(COALESCE(title,''),1,60)
      FROM tasks
      WHERE assignee=$(sqlq "$1") AND kind='standard'
        AND status IN ('todo','in_progress') AND parked_at IS NULL
      ORDER BY COALESCE(created_at,'') ASC LIMIT ${2:-3};" 2>/dev/null || echo ""
}

# THE FILING CAP (DIVE-2681). Two controls over one classifier.
#
# The measured problem: across the 508 rows filed in the 8 days to 2026-08-02,
# 54% concerned our own machinery and 5.5% touched anything a customer sees —
# roughly 10:1. The fleet audits itself because auditing is always available,
# and every internal row costs TWICE, because the DIVE-969 rail then books a
# grading pass against it. The rule has existed as a directive since 2026-08-02
# and did not hold: the agent that wrote it filed 55 rows the next day. A rule
# recalled BY TOPIC cannot fire at a MOMENT, and `task add` is the moment.
#
# So the cap lives here, at the keystroke, and not in anyone's instructions.
#
# THE CLASSIFIER IS A CANDIDATE SET, NEVER AN ACTION SET. A title-keyword scan
# cannot tell a harness row from a product row that happens to say "queue" —
# "Free OSS web UI: three views (org chart, queue, gates)" is a customer
# surface and matches on two words. So every consequence below is (a) announced
# in the output, never silent, and (b) one declared flag away from off:
#   --customer          this touches a customer surface; classifier was wrong
#   --already-blocked=  it IS internal, and it is the stated exception
# A false positive costs one flag. It never costs the row.
# A MISS IS NOT CHEAP — MEASURED 2026-08-09. The first cut of this scan was
# deliberately narrow on the reasoning that "a miss here is cheap and a false hit
# taxes someone's real work". Only the second half of that held. Over the 946
# hand-filed rows of the preceding 14 days the narrow set flagged **15%** where a
# read of the same titles says ~67% are our own machinery, so the gating window
# sat at 3/20 against a 5/20 threshold and the cap **never fired once**. The
# fleet filed 55 rows a day, two of every three about itself, for five days after
# the guard shipped and went live in 0.19.6.
#
# The narrow set failed for one structural reason: it keyed on MULTI-WORD phrases
# ("verifier rail", "merge gate", "task add") while the rows that actually get
# filed say the same things in one word — "gate" (102 occurrences in the missed
# set), "agent" (97), "task" (80), then verifier, guard, rail, council, probe,
# board. The vocabulary was right and the arity was wrong.
#
# So the set below is single-token where our machinery owns the token outright.
# Two words stay OUT on purpose because the product IS agent hosting and they
# cannot discriminate: **agent** and **queue**. Word boundaries do real work
# here — "dashboard" does not match `board`, "webhook" does not match `hook`,
# "latest" does not match `test`. Measured detection after widening: 45%, still
# under the ~67% human read, which is the safe direction for a refusal.
# Is the ACTIVE task store the production board? The filing cap is a rule about
# how many rows the fleet puts on the shared board, so a run against a fixture
# store has nothing for it to govern. Deliberately its own function rather than a
# call to _task_human_send_allowed: that one also refuses on FIVEDIVE_TEST and
# friends because SENDING to a human from a fixture is the risk it guards, and
# borrowing it here would couple a quota to a notification policy. Same store
# comparison (DIVE-1506), different question.
_task_filing_cap_store_is_prod() {
  local active prod ra rp
  active="${TASKS_DB:-${STATE_DIR:-/var/lib/5dive}/tasks/tasks.db}"
  prod="$(_task_prod_tasks_db)"
  ra="$(readlink -f "$active" 2>/dev/null || printf '%s' "$active")"
  rp="$(readlink -f "$prod" 2>/dev/null || printf '%s' "$prod")"
  [[ -n "$ra" && "$ra" == "$rp" ]]
}

_task_internal_subject_reason() {
  local t="${1,,}"
  # Our own machinery: the task engine, gates, verifier rails, CI, the release
  # cut, harnesses, the board, agent plumbing. Still a candidate set, never an
  # action set — see the two declared escapes above.
  [[ "$t" =~ (^|[^a-z])(harness|harnesses|smoke|full[-_ ]sweep|pipefail|shellcheck|actionlint|lint|verifier|verifiers|rail|rails|gate|gates|gating|task[[:space:]](add|done|need|ls)|taskboard|worktree|worktrees|heartbeat|release[-_ ]cut|version[-_ ]bump|changelog|pre[-_ ]push|hook|hooks|guard|guards|council|probe|probes|ci|nightly|budget[-_ ]report|backlog|board|cron|crontab|digest|recurring|maker|regression|flaky|unit|test|tests)([^a-z]|$) ]] \
    && { printf 'internal machinery'; return 0; }
  return 0
}

# DIVE-3245 — THE PER-FILER VOLUME CAP: how many low/medium rows this filer has
# created in the last ROLLING 24 HOURS.
#
# ROLLING, NOT CALENDAR, and that is the whole design (main, 2026-08-11). The
# thing being bound is a BURST, not a mean: one filer put 65 low/medium rows on
# the board in a day, and the fleet peaked at 163. A calendar-day cap lets a burst
# straddle midnight and clear itself, which is the shape that produced the damage.
#
# WHAT IS EXCLUDED, each for its own reason:
#   from_template_id  a recurring instance is MATERIALIZED by the scheduler, not
#                     filed by a person. Counting it fires the cap on a cadence
#                     nobody chose that day.
#   kind != standard  templates and their machinery are not filings.
#   priority          high/urgent never reach here (see the caller) — capping a
#                     serious finding is the failure direction lodar ruled out.
# NOT excluded: rows later cancelled or done. The cap is about INFLOW, and a row
# that was filed and then cancelled cost exactly what this exists to stop.
_task_filer_low_med_24h() { # <filer> -> count
  local who="$1"
  [[ -n "$who" ]] || { printf '0'; return 0; }
  db "SELECT COUNT(*) FROM tasks
       WHERE created_by=$(sqlq "$who")
         AND kind='standard'
         AND priority IN ('low','medium')
         AND COALESCE(from_template_id,0)=0
         AND created_at > datetime('now','-24 hours');" 2>/dev/null
}

# THE NUMBER, AND WHY IT IS THIS NUMBER. Derived from 30 days of the real board
# (low/medium, template-materialized and cli/system excluded), by asking how many
# rows each cap WOULD have refused:
#
#     cap   main  olivia  dev  dev3  everyone else
#      10    327     151   78     3              0
#      12    313     129   47     1              0
#      15    282      97   18     0              0     <- chosen
#      20    227      60    7     0              0
#
# 15 is the smallest cap at which NO filer outside the top three is ever touched.
# Below it the cap starts catching dev3, who is not the problem; above it the
# heavy filers keep more of the headroom that produced 245 cancelled rows out of
# 1092. The median filer's worst rolling-24h in that window is 4.5 and ten of
# fourteen filers never exceed 6, so this leaves the ordinary case untouched by
# more than 2x while binding all three runaway filers — including dev, which is
# the point: a cap its author is exempt from is a suggestion.
#
# NOT `${_TASK_FILING_DAILY_CAP:-15}`. An env-overridable cap IS the bypass flag
# this row forbids, just spelled differently and invisible in the record — and the
# population it exists to slow down is the population that would export it. It is
# a constant, and the harness trips it by seeding real rows rather than by
# lowering the bar, which also means the tests exercise the REAL threshold.
_TASK_FILING_DAILY_CAP=15

# How many of the last N standard rows read as internal machinery. Counted by
# running the SAME classifier over recent titles rather than storing a column —
# no schema change, and the count can never disagree with the rule that gates
# the next add. Prints "<internal> <total>".
_task_internal_recent_ratio() {
  local window="${1:-20}" n=0 hits=0 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    n=$((n + 1))
    # `if`, not `[[ ]] && ...`: as the LAST command in a loop body a false
    # `&&` list makes the body — and so the loop — exit 1, which `set -e`
    # takes as a failure. Same family as the defect this whole ticket exists
    # to stop generating.
    if [[ -n "$(_task_internal_subject_reason "$line")" ]]; then
      hits=$((hits + 1))
    fi
  done < <(db "SELECT REPLACE(title, char(10), ' ') FROM tasks WHERE kind='standard' ORDER BY id DESC LIMIT ${window};")
  # THE TRAILING NEWLINE IS LOAD-BEARING. `read` returns 1 when it hits EOF
  # without a delimiter, so a bare "%s %s" makes the CALLER's `read` fail, and
  # under src/header.sh's `set -euo pipefail` that killed `task add` outright
  # with no error path reached — the exact silent-death class of DIVE-2604.
  printf '%s %s\n' "$hits" "$n"
}

# Resolve the lone org root (the single top of the chart — reports_to NULL or a
# dangling manager). Prints the name, or nothing when the org is empty or has
# more than one root (ambiguous — never guess). Mirrors the coordinator's
# lone-root fallback but is exposed on its own so the grader chain can try it
# even in an org that DOES tag a distinct role='coordinator'.
_task_resolve_org_root() {
  [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org);")" == "1" ]] || return
  db "SELECT name FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org) LIMIT 1;"
}

# Resolve the org's designated technical deputy — the lone agent whose role or
# title marks them as a CTO / chief-technology / deputy — excluding $1 (the
# maker). This is the grader of last resort for the root/CEO's OWN work: when a
# task auto-coordinates to the lone-root coordinator, the maker IS the top of
# the chart with no manager above, so the chain would otherwise give up. The
# match is a leading-space-anchored keyword scan (so "CTO" matches but "factory"
# does not) and must be UNIQUE — >1 candidate is ambiguous and yields nothing.
_task_resolve_deputy() {
  local _skip="$1"
  local _pred="( lower(' '||COALESCE(role,'')||' '||COALESCE(title,'')) LIKE '% cto%'
                 OR lower(' '||COALESCE(role,'')||' '||COALESCE(title,'')) LIKE '% chief technolog%'
                 OR lower(' '||COALESCE(role,'')||' '||COALESCE(title,'')) LIKE '% deputy%' )
               AND name <> $(sqlq "$_skip")"
  [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE ${_pred};")" == "1" ]] || return
  db "SELECT name FROM agents_org WHERE ${_pred} LIMIT 1;"
}

# Pick a grader distinct from the maker (assignee) — a maker can't grade itself
# (DIVE-474). DIVE-969 established the verifier-by-default posture; DIVE-989
# widens WHO can grade so the default no longer silently no-ops when a task
# auto-coordinates TO the coordinator (maker==coordinator — the common
# default-project case where the lone-root CEO owns all unassigned work). We
# walk an ordered chain of DISTINCT candidates and take the FIRST that exists
# and differs from the maker:
#   1. project lead   — the task's own project owner
#   2. coordinator    — the queue owner (role=coordinator, else the lone root)
#   3. maker's manager — reports_to: the maker's natural up-reviewer
#   4. org root        — the lone top of the chart
#   5. technical deputy — the org's designated CTO/deputy, so the root/CEO's own
#                         work still gets a distinct grader
# The silent no-op survives ONLY when none of these yields a distinct agent (a
# genuinely solo org, or nobody but the maker anywhere). Prints the grader name.
# DIVE-2719: the org's DESIGNATED GRADER — the agent whose own role/title says
# QA / testing / verification — excluding $1 (the maker). Same shape as
# _task_resolve_deputy (leading-space-anchored keyword scan, must be UNIQUE, >1
# is ambiguous and yields nothing), because it answers the same kind of question
# off the same table.
#
# It goes FIRST in the chain below, and that placement is the fix for a live
# directive violation, not a preference. lodar ruled 2026-08-04 07:51: "you
# should never be verifier yourself" / "why our ceo acts as ci tool". The remedy
# applied that morning MOVED 58 rows off main and cleared 6 more — it did not
# touch this picker, so by 21:1x six MORE rows created that same day had
# regenerated verifier=main. Correcting the output of a rule leaves the rule
# producing it. Every rung this function had walks UP the chart (lead,
# coordinator, manager, root, deputy), so a leader was structurally guaranteed to
# win; a chart that names a QA agent has already answered who should grade, and
# nobody had asked it.
#
# DIVE-2912: the UNIQUENESS rule above is defensible; its SILENCE was not, and
# the silence is what shipped a live routing change. Seating main2 with
# "verifier" in its TITLE made the count 2, so this function returned empty and
# the chain fell through to the next rung — which did not make main2 a candidate
# (main2 is nowhere in a dev-assigned row's chain), it made QUINN, the dedicated
# QA agent, stop being one. An unrelated agent's job title silently removed the
# QA rail from the picker for every row on the board, and nothing said so.
# Three changes, each aimed at that:
#   1. A DECLARED role outranks a descriptive title. Pass 1 scans `role` only;
#      only if that names nobody do we widen to role||title (pass 2), which is
#      what keeps an org whose QA agent is marked in the title alone working.
#      A clone's self-description can no longer outvote `role='QA / testing'`.
#   2. FIVE_VERIFY_EXCLUDE is honoured HERE too, not just in the chain below.
#      Excluding a name there used to leave it still counting toward the
#      ambiguity that suppressed the pick — the documented data lever could not
#      resolve the one thing it is shaped to resolve. Now it can.
#   3. A decline is LOUD. Genuine ambiguity warns and NAMES every match; the
#      rung is skipped either way, but the caller can now see that the QA rail
#      was skipped and why. Silence is kept for the one case that is not an
#      event: no QA agent matches at all, the ordinary shape for an org that
#      never named one, where warning would fire on every `task add`.
# Prints the grader name, or nothing.
_task_resolve_qa() {
  local _skip="$1" _pass _label _pred _n
  local -a _cands=()
  for _pass in role any; do
    if [[ "$_pass" == role ]]; then
      _pred="$(_task_qa_kw_clause "COALESCE(role,'')")"; _label='declared role'
    else
      _pred="$(_task_qa_kw_clause "COALESCE(role,'')||' '||COALESCE(title,'')")"; _label='role or title'
    fi
    _cands=()
    while IFS= read -r _n; do
      [[ -n "$_n" ]] || continue
      _task_verify_excluded "$_n" && continue
      _cands+=("$_n")
    done < <(db "SELECT name FROM agents_org WHERE ${_pred} AND name <> $(sqlq "$_skip") ORDER BY name;")
    case "${#_cands[@]}" in
      1) printf '%s' "${_cands[0]}"; return 0 ;;
      0) continue ;;   # nobody at this precision — widen, or fall out silently
      *) warn "verifier auto-pick: the QA rung was SKIPPED — ${#_cands[@]} agents match the QA scan by ${_label} (${_cands[*]}), so it cannot name one. The verifier falls through to the next rung (project lead, then up the chart). Disambiguate with FIVE_VERIFY_EXCLUDE=<name>, a narrower role/title, or set the verifier explicitly."
         return 1 ;;
    esac
  done
  return 1
}

# The QA keyword scan, over whichever SQL expression the caller passes, so the
# role-only and role||title passes cannot drift apart. Leading-space-anchored
# (so "QA" matches but "kanban" does not), same convention as
# _task_resolve_deputy.
_task_qa_kw_clause() {
  local _e="lower(' '||$1)"
  printf "( %s LIKE '%% qa%%' OR %s LIKE '%% test%%' OR %s LIKE '%% verif%%' OR %s LIKE '%% quality%%' )" \
    "$_e" "$_e" "$_e" "$_e"
}

# DIVE-2719: a NAMED EXCLUSION LIST, so the next such ruling is data rather than
# a code change. Comma/space separated agent names in FIVE_VERIFY_EXCLUDE are
# excluded from the default chain exactly the way the maker is — they can still
# be set explicitly with `--verifier=` / `task verifier`, which stays a deliberate
# human act. Empty by default: this ships INERT and changes no selection until an
# org sets it.
_task_verify_excluded() {
  local _n="$1" _e _list="${FIVE_VERIFY_EXCLUDE:-}"
  [[ -n "$_n" ]] || return 1
  for _e in ${_list//,/ }; do
    [[ "$_e" == "$_n" ]] && return 0
  done
  return 1
}

# DIVE-3939: a grader is a DISPATCH TARGET — `task done` writes
# assignee=<verifier> — so the candidate chain must apply the SAME wakeability
# test the assignee lane already gets. Before this, the chain filtered on three
# things (non-empty, != assignee, not excluded) and never asked whether anything
# wakes the seat it landed on, which is
# community/wiki/a-control-enforced-on-one-path-is-absent-on-the-parallel-one.md
# instance 6: two COLUMNS of one rail, guarded on one. The unguarded column
# fails LATER — at handoff, after the maker has spent the work — so the row
# looks healthy for its whole life and dies at delivery. Six measured strands
# across four dates before this landed.
#
# ONE predicate, not a second copy: `_task_doctor_lane_wakeable`
# (src/task/doctor.sh) is the function `task doctor` reports off, so the picker
# and the report cannot drift into disagreeing about which seats are alive —
# which was itself half the filed defect (doctor printed "wakeable assignee" OK
# over a row the board digest called undispatchable).
#
# FAILURE DIRECTION IS DELIBERATE. That predicate returns 2 for "I could not
# find out" (registry unreadable), and 2 is treated as ACCEPTABLE here, not as
# dead. An unreadable agents.json must not silently strip the grading rail off
# every row the board files while it is missing; UNKNOWN degrades to the status
# quo, the same direction `_human_registry_active` takes. Only a DECIDED
# not-wakeable (rc 1) skips a candidate.
_task_verify_unwakeable() {
  local _n="$1" _rc
  [[ -n "$_n" ]] || return 1
  declare -F _task_doctor_lane_wakeable >/dev/null 2>&1 || return 1
  _task_doctor_lane_wakeable "$_n" && _rc=0 || _rc=$?
  [[ "$_rc" == "1" ]]
}

_task_default_verifier() {
  local _assignee="$1" _proj_lead="$2" c=""
  local -a cands=(
    "$(_task_resolve_qa "$_assignee")"
    "$_proj_lead"
    "$(_task_resolve_coordinator)"
    "$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$_assignee") LIMIT 1;")"
    "$(_task_resolve_org_root)"
    "$(_task_resolve_deputy "$_assignee")"
  )
  for c in "${cands[@]}"; do
    if [[ -n "$c" && "$c" != "$_assignee" ]] \
       && ! _task_verify_excluded "$c" && ! _task_verify_unwakeable "$c"; then
      printf '%s' "$c"; return
    fi
  done
  # Falls through to EMPTY when the whole chain is unwakeable, on purpose. The
  # caller's existing INST-2 `verifyUnavailable` path then labels the row
  # honestly ("no independent verifier available"). It must NOT fall back to the
  # assignee: that recreates the DIVE-3366 maker==grader skew, i.e. a row that
  # reads as graded and was reviewed by the person who wrote it.
}

# DIVE-1145: ship-gating routing. Resolve WHO a builder's gate should route to
# for lead review before it ever pings the human. Enforces the org policy
# "builder decision gates go through the org lead (main), not straight to the
# human" using the org-chart primitives already present — never a hardcoded
# agent. Prints the reviewer name, or NOTHING when the filer IS a lead (or the
# org can't name a distinct one), in which case the gate falls through to the
# human path unchanged. Ordered, DISTINCT-from-filer candidate chain:
#   1. the filer's manager      — reports_to: their natural up-reviewer
#   2. the org coordinator/root — role=coordinator, else the lone chart root
# Excluding the filer is what makes re-escalation free: when the LEAD files (or
# re-files) the same gate, they resolve to no distinct reviewer, so it goes to
# the human — exactly "only escalate to the human when the lead re-escalates".
_gate_route_reviewer() {
  local _filer="$1" c=""
  [[ -n "$_filer" ]] || return
  local -a cands=(
    "$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$_filer") LIMIT 1;")"
    "$(_task_resolve_coordinator)"
  )
  for c in "${cands[@]}"; do
    if [[ -n "$c" && "$c" != "$_filer" ]]; then
      printf '%s' "$c"; return
    fi
  done
}

# ---- DIVE-3342: which PERSON does a gate belong to? ----
#
# Everything above this line resolves an AGENT. That is what "routing" has meant
# since DIVE-1495, and it is only half of a gate's delivery: the other half —
# whose phone rings when the agent rail expires, or when the gate is human-only
# by tier — was never routed at all. It was read off `last-human-chat.json`,
# i.e. whoever most recently DM'd that bot, with a fan-out to the whole
# allowFrom when no pointer resolved. See src/cmd_human.sh for the measured harm
# and why zero human rows must keep the old behaviour exactly.
#
# _human_registry_active — is the human registry IN USE on this store? Presence,
# not a flag: a box with no `humans` rows is a box that has not adopted this, and
# gate delivery there must be byte-identical to its pre-DIVE-3342 self. Returns 1
# when the table is absent too (an old store mid-migration), because "cannot see
# the registry" and "registry is empty" both mean "do not change behaviour" — the
# opposite of the absent-vs-forbidden conflation _task_agent_paired warns about,
# and safe in this direction precisely because the fallback is the status quo.
_human_registry_active() {
  local n
  n=$(db "SELECT COUNT(*) FROM humans;" 2>/dev/null) || return 1
  [[ "${n:-0}" =~ ^[0-9]+$ ]] && (( n > 0 ))
}

# _human_owner_of_agent <agent> — the person who owns that agent's gates. Walks
# the explicit human_agents link, then UP the org chart, one level at a time.
#
# It does NOT fall back to the coordinator/org root the way _gate_route_reviewer
# does, and that omission is deliberate. The root fallback is what makes
# _gate_route_reviewer return the filer itself at the top of the chart
# (community/wiki/the-org-root-cannot-resolve-a-reviewer-because-it-is-its-own-fallback.md);
# reused here it would mean "no owner is linked anywhere" silently resolving to
# whichever person happens to be linked to the root — a confident wrong recipient,
# which is the exact failure being fixed. Empty is a legitimate answer here and
# the callers are built to handle it.
_human_owner_of_agent() {
  local cur="${1:-}" hit="" seen="" depth=0
  while [[ -n "$cur" ]] && (( depth < 8 )); do
    case ",$seen," in *",$cur,"*) return ;; esac   # cycle guard: the chart is agent-writable
    seen="${seen:+$seen,}$cur"
    hit=$(db "SELECT ha.human_id FROM human_agents ha JOIN humans h ON h.id=ha.human_id
              WHERE ha.agent=$(sqlq "$cur") ORDER BY ha.human_id LIMIT 1;" 2>/dev/null)
    if [[ -n "$hit" ]]; then printf '%s' "$hit"; return; fi
    cur=$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$cur") LIMIT 1;" 2>/dev/null)
    depth=$(( depth + 1 ))
  done
}

# _human_gate_recipient <numeric task id> — the person this gate belongs to, i.e.
# the human who may CLEAR it. Ordered candidates, first hit wins; every one of
# them is a CLEARANCE relationship, never a traffic observation:
#
#   1. tasks.human_owner        — stamped at file time (or declared with
#                                 `task need --owner=`). The gate's own record of
#                                 whose it is; re-resolving past it would let the
#                                 chart move a live gate to someone else.
#   2. owner-of(routed_reviewer) — the agent rail's owner. When a tier-1 gate's
#                                 24h rail expires, the person above THAT rail is
#                                 who inherits it.
#   3. owner-of(gate_filed_by)   — the filer's owner (gate_filed_by, not
#                                 created_by: a task and the gates on it have
#                                 different principals — DIVE-3171).
#   4. owner-of(assignee)/owner-of(created_by) — last structural resorts.
#   5. the SOLE human on record  — a one-person registry has exactly one possible
#                                 clearer, so requiring a link there would be
#                                 ceremony. With two or more rows this arm is off:
#                                 that is the ambiguity the ticket is about, and
#                                 guessing is what we are removing.
#
# Sets HUMAN_RECIPIENT_ID and HUMAN_RECIPIENT_BASIS — the answer and the arm that
# produced it — so both `5dive human recipient` and the delivery log can say WHY,
# rather than leaving a silent empty the way _gate_route_reviewer does. The id is
# ALSO printed for convenience, but callers that need the basis must call this
# WITHOUT a command substitution: `$( )` is a subshell, so a var it assigns dies
# with it and the basis would read empty exactly where the explanation matters.
_human_gate_recipient() {
  local numid="${1:-}" row who=""
  HUMAN_RECIPIENT_BASIS="no candidate"; HUMAN_RECIPIENT_ID=""
  [[ "$numid" =~ ^[0-9]+$ ]] || { HUMAN_RECIPIENT_BASIS="not a task row"; return; }
  row=$(db "SELECT COALESCE(human_owner,'')||x'1f'||COALESCE(routed_reviewer,'')||x'1f'||COALESCE(gate_filed_by,'')||x'1f'||COALESCE(assignee,'')||x'1f'||COALESCE(created_by,'')
            FROM tasks WHERE id=${numid};" 2>/dev/null)
  [[ -n "$row" ]] || { HUMAN_RECIPIENT_BASIS="no such row"; return; }
  local stamped reviewer filer assignee creator
  IFS=$'\x1f' read -r stamped reviewer filer assignee creator <<<"$row"

  if [[ -n "$stamped" ]]; then
    # Only a LIVE row counts. A stamp naming a deleted account must re-resolve,
    # not resolve to a person who is no longer on the box.
    who=$(db "SELECT id FROM humans WHERE id=$(sqlq "$stamped") LIMIT 1;" 2>/dev/null)
    if [[ -n "$who" ]]; then HUMAN_RECIPIENT_BASIS="gate owner (stamped)"; HUMAN_RECIPIENT_ID="$who"; printf '%s' "$who"; return; fi
  fi
  local pair
  for pair in "routed reviewer ${reviewer}" "gate filer ${filer}" "assignee ${assignee}" "creator ${creator}"; do
    local label="${pair% *}" agent="${pair##* }"
    [[ -n "$agent" ]] || continue
    who=$(_human_owner_of_agent "$agent")
    if [[ -n "$who" ]]; then HUMAN_RECIPIENT_BASIS="owner of ${label} ${agent}"; HUMAN_RECIPIENT_ID="$who"; printf '%s' "$who"; return; fi
  done
  local n; n=$(db "SELECT COUNT(*) FROM humans;" 2>/dev/null)
  if [[ "${n:-0}" == "1" ]]; then
    who=$(db "SELECT id FROM humans LIMIT 1;" 2>/dev/null)
    HUMAN_RECIPIENT_BASIS="sole human on record"; HUMAN_RECIPIENT_ID="$who"
    printf '%s' "$who"; return
  fi
  HUMAN_RECIPIENT_BASIS="no human owns this gate's clearers (${n:-0} humans on record, none linked up the chain)"
}

# _human_transport_id <human id> <telegram|buzz|discord> — that person's id on one
# transport, empty if they are not on it. One identity, three addresses: the whole
# point of the record is that a gate names the PERSON and delivery picks the
# address, instead of the address being all we ever had.
_human_transport_id() {
  local id="${1:-}" transport="${2:-telegram}" col
  case "$transport" in
    telegram) col="telegram_id" ;;
    buzz)     col="buzz_npub" ;;
    discord)  col="discord_id" ;;
    *) return ;;
  esac
  [[ -n "$id" ]] || return
  db "SELECT COALESCE(${col},'') FROM humans WHERE id=$(sqlq "$id") LIMIT 1;" 2>/dev/null
}

# _human_gate_ids_by_owner <comma-separated task ids> — partition a BATCH of gate
# rows by resolved owner, one line per owner: `<human|->\t<ids>`. Batch re-nags
# (the heartbeat sweep, `task inbox --send`) render one message for many gates;
# on a multi-human box those gates need not share an owner, and sending the
# rendered batch to all of them would page each person with other people's rows —
# the reported harm with the volume turned up. Callers loop over this instead.
_human_gate_ids_by_owner() {
  local idlist="${1:-}" id who
  [[ -n "$idlist" ]] || return
  local -A groups=()
  local IFS=','
  for id in $idlist; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    _human_gate_recipient "$id" >/dev/null
    who="$HUMAN_RECIPIENT_ID"
    groups["${who:--}"]="${groups["${who:--}"]:+${groups["${who:--}"]},}${id}"
  done
  unset IFS
  local k
  for k in $(printf '%s\n' "${!groups[@]}" | sort); do
    printf '%s\t%s\n' "$k" "${groups[$k]}"
  done
}

# DIVE-1401 (olivia review, iter 2): the TRUSTED caller identity for gate-withdraw
# AUTHORIZATION. This is deliberately NOT task_actor: --from is caller-asserted and
# SUDO_USER/SUDO_UID are plain env vars a NON-root process can forge with no real
# sudo (`SUDO_USER=agent-<filer> 5dive task need <id> --withdraw`). Trust rule:
#   - EUID==0 (real sudo / root): sudo set SUDO_* truthfully AND reaching EUID 0
#     required actually sudo-ing, so a non-root agent cannot forge in. Read the
#     agent id from SUDO_USER (auto_sender_from_sudo) and the human signal from a
#     non-agent SUDO_UID (_gate_sudo_uid_nonagent), mirroring cmd_task_answer.
#   - non-root: SUDO_* are UNTRUSTED (forgeable) — ignore them entirely and judge
#     by $EUID resolved against /etc/passwd in pure bash. DIVE-2330: this line used
#     to say `id -un` "which a process cannot spoof" — it could, because `id`
#     resolves through the CALLER'S PATH and a shim printing any name won.
# Prints one of: "agent <name>" | "human" | "none". Never reads --from ($from stays
# ATTRIBUTION-only) nor $USER (also env-spoofable). The determined root-sudo residual
# (an agent that truly sudo's then forges) is shared with the whole gate system and
# out of scope here — same boundary cmd_task_answer draws. _gate_is_root is a seam so
# the unit harness can exercise BOTH branches with the REAL resolver (not stubbed).
# _gate_is_root now lives in src/lib/actor.sh alongside the rest of the sealed
# derivation (DIVE-2517). Unchanged body, unchanged seam contract.
_gate_withdraw_actor() {
  if _gate_is_root; then
    local a; a=$(auto_sender_from_sudo)
    [[ -n "$a" ]] && { printf 'agent %s' "$a"; return; }
    _gate_sudo_uid_nonagent && { printf 'human'; return; }
    printf 'none'; return
  fi
  # DIVE-2330 iteration 2: route BOTH the uid and the passwd source through the seams.
  # This is the SAME defect dev found in the refusal guard, a second time in this
  # function: reading $EUID and /etc/passwd inline made the non-root branch resolve the
  # REAL runner, so gate_withdraw_unit's IDUN pin could not reach it and two arms graded
  # the runner's identity instead of the one under test. Semantics are unchanged —
  # _gate_caller_uid's whole body is `printf '%s' "$EUID"` and _gate_passwd_stream's is
  # /etc/passwd — which is exactly why routing through them widens nothing.
  local _cuid; _cuid=$(_gate_caller_uid)
  local _a; _a=$(_gate_uid_to_agent "$_cuid")
  if [[ -n "$_a" ]]; then printf 'agent %s' "$_a"; return; fi
  local _n _x _u; while IFS=: read -r _n _x _u _; do
    [[ "$_u" == "$_cuid" ]] && { printf 'human'; return; }
  done < <(_gate_passwd_stream)
  printf 'none'
}

# DIVE-3340: THE HUMAN-SIDE EXIT FROM A PENDING GATE, rendered in ONE place.
#
# Two refusals need this sentence — `cancel` over an open gate (task/status.sh) and
# `--withdraw` refused as unauthorized (task/need.sh) — and until this ticket NEITHER
# of them said it. Both named only `--withdraw`, which is the AGENT-side exit, and the
# authorized set for a withdraw is `human | filer | filer's lead | coordinator`
# (_gate_withdraw_actor above). **A person typing into a chat bot satisfies none of
# them**: the command runs on an agent seat, so the actor resolves to `agent <seat>`,
# and the human's identity deliberately does not travel through the bot (DIVE-1401,
# DIVE-2330 — SUDO_* are forgeable below root, so authorization fails closed and must
# keep doing so). Measured 2026-08-12 on a CUSTOMER box: the owner tried to cancel his
# own row, was told to withdraw first, and the withdraw refused him. Two refusals, each
# individually correct, composing into a closed loop.
#
# ANSWERING IS THE ROUTE OUT, and it needs no withdraw authorization at all: it is the
# human's own act, it is what the buttons in their chat are for, and once
# need_answered_at is set the cancel guard stops firing. So it is named FIRST wherever
# a human is the one reading — the door they can open, before the one they cannot.
#
# Shared rather than inlined twice on purpose: this is the same class as DIVE-2382,
# where a refusal that named a SMALLER set than the code checked converted an available
# action into an impossible one for every reader. Two copies of an exit route drift, and
# the drift is invisible — a refusal is read once, by someone who will not re-derive it.
# See community/wiki/a-refusal-that-names-a-smaller-set-than-the-code-checked.md.
#
# Type-shaped because the verb genuinely differs, and getting it wrong publishes a route
# that refuses — which is the defect this function exists to fix, one layer down. A
# `secret` must never be typed into the board (it would be recorded), and a `manual`
# gate records that the step was PERFORMED rather than carrying a value; both take
# `task answer <id>` with NO --value. The tap route is named for every type because a
# tier-2 gate's own alert carries the per-gate human nonce that only the CLI mints
# (DIVE-916) — the buttons are the answer surface a human actually has.
#   $1 = ident (DIVE-N)   $2 = need_type
_gate_answer_route() {
  local _ar_ident="$1" _ar_type="$2"
  case "$_ar_type" in
    secret)
      printf "answer it yourself — place the secret out-of-band, then '5dive task answer %s' with NO --value (the value must never be written to the board)" "$_ar_ident" ;;
    manual)
      printf "answer it yourself — '5dive task answer %s' with NO --value (it records that the step was performed)" "$_ar_ident" ;;
    *)
      printf "answer it yourself — tap a button on the gate's own alert in chat, or '5dive task answer %s --value=<answer>'" "$_ar_ident" ;;
  esac
}

# DIVE-980: shared org-chart assignee resolution. Resolve an assignee TOKEN to a
# concrete agent via the org chart (agents_org). Prints the resolved name, or
# NOTHING when a role/charter token has no UNIQUE holder — callers decide whether
# that empty is a hard error (task add) or a fall-through (goal validate).
# Deterministic + explainable: a role/charter routes ONLY on an unambiguous
# single match; >1 holder or unknown -> empty (never guess which one).
#   @name / bare name  -> taken as-is (explicit override; never re-routed)
#   role:<r>           -> the lone holder whose role/title CONTAINS <r> (ci, DIVE-2041)
#   charter:<kw>       -> the lone holder whose title (charter) contains <kw> (ci)
# Safe on an empty/missing org table (COUNT != 1 -> empty).
#
# DIVE-2041 — `role:<r>` WAS DEAD FOR EVERY AGENT ON EVERY CHART. It matched
# `lower(role) = lower(<r>)`, full-string equality, against a column whose every
# real value is human prose: "QA / testing", "Backend lane — OSS CLI, API, core
# council/constitution engine", "AI CEO — conducts the fleet (advisory)". So
# `role:QA` could not match quinn, and in practice NO role: token could match ANY
# agent. Same shape as the DIVE-2031 banner outage it was found next to: the
# lookup resolved to empty, the task simply landed unassigned, and an unassigned
# task is indistinguishable from ordinary behaviour — so nobody ever reported it.
#
# The predicate is the one already used by `_task_resolve_deputy` ~450 lines
# above: space-anchored substring over role||title, uniqueness-checked. Not a new
# mechanism — the sibling `charter:` token below has always done the substring
# thing correctly, against `title`. Exact equality is TRIED FIRST so a chart that
# does use terse role values keeps its existing, sharper resolution; the
# substring pass only runs when exact found no unique holder, so this can only
# turn empties into matches, never re-point an already-working token.
#
# `%` and `_` in the token are ESCAPED: they are LIKE wildcards, and an assignee
# token is caller input, so `role:%` would otherwise "match" whatever single row
# happened to exist and route work by accident.
_org_like_escape() { local s="${1//\\/\\\\}"; s="${s//%/\\%}"; printf '%s' "${s//_/\\_}"; }

_org_resolve_assignee() {
  local v="${1#@}"
  case "$v" in
    role:*)
      local r="${v#role:}"
      if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE role IS NOT NULL AND lower(role)=lower($(sqlq "$r"));" 2>/dev/null)" == "1" ]]; then
        db "SELECT name FROM agents_org WHERE role IS NOT NULL AND lower(role)=lower($(sqlq "$r")) LIMIT 1;"
        return
      fi
      local _rp="lower(' '||COALESCE(role,'')||' '||COALESCE(title,'')) LIKE '% '||lower($(sqlq "$(_org_like_escape "$r")"))||'%' ESCAPE '\'"
      [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE ${_rp};" 2>/dev/null)" == "1" ]] || { printf ''; return; }
      db "SELECT name FROM agents_org WHERE ${_rp} LIMIT 1;"
      ;;
    charter:*)
      local kw="${v#charter:}"
      local _cp="title IS NOT NULL AND lower(title) LIKE '%'||lower($(sqlq "$(_org_like_escape "$kw")"))||'%' ESCAPE '\'"
      [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE ${_cp};" 2>/dev/null)" == "1" ]] || { printf ''; return; }
      db "SELECT name FROM agents_org WHERE ${_cp} LIMIT 1;"
      ;;
    *)
      printf '%s' "$v"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# DIVE-3366 — ROUTE BY ROLE WHEN THE ROLE HAS TWO SEATS.
#
# `role:<r>` above routes ONLY on a unique holder and returns empty on two, and
# that empty is the lane skew. The refusal pushes the filer back to typing a
# name, and the name a filer remembers is the busiest seat — so the mechanism
# that exists to distribute work actively concentrates it as soon as a second
# holder is seated. Measured 2026-08-13 04:59Z with quinn and main2 both holding
# the verifier role: quinn 14 open, main2 0. lodar raised the same imbalance
# three times in one day; a directive repeated three times is a mechanism
# question, not a discipline question.
#
# WIDENING ONLY. These run where `_org_resolve_assignee` already came back EMPTY
# — an ambiguity that was a hard error one line later at the call site — so they
# can only turn a refusal into a route, never re-point a token that already
# resolved. Same discipline the DIVE-2041 substring pass was added under, and the
# reason `_org_resolve_assignee` itself is left exactly as it is: `goal validate`
# and `objective` read it to ask "does this resolve deterministically", and a
# load-based answer is not the same question.
#
# THE PICK IS RECORDED ON THE ROW, because a load-based choice cannot be
# reconstructed afterwards: the counts that decided it have moved by the time
# anyone reads the row. `_TASK_ROLE_PICK_BASIS` carries every candidate's count
# as measured at filing, and the caller writes it into the body.
#
# ONLY DISPATCHABLE SEATS ARE CANDIDATES. The org chart names lanes the registry
# does not — that is exactly the name DIVE-3344 refuses at `--assignee` — and
# picking one here would mint the undispatchable row through the back door, with
# the router's authority on it, so nobody would think to question the name. When
# the roster is `unestablished:*` the filter is skipped rather than treated as an
# empty roster, for the reason `_task_require_lane` documents: a roster we could
# not establish must refuse nothing.
# ---------------------------------------------------------------------------
_TASK_ROLE_PICK=""; _TASK_ROLE_PICK_BASIS=""

# _org_role_holders <role> — every chart seat matching the role token, one per
# line, name-ordered. Same two passes as `_org_resolve_assignee`, in the same
# order and with the same LIKE escaping: exact `role` equality first so a chart
# with terse role values keeps its sharp answer, substring over role||title only
# when exact matched nothing.
_org_role_holders() {
  local r="$1" exact
  exact=$(db "SELECT name FROM agents_org
              WHERE role IS NOT NULL AND lower(role)=lower($(sqlq "$r")) ORDER BY name;" 2>/dev/null || true)
  if [[ -n "$exact" ]]; then printf '%s\n' "$exact"; return 0; fi
  db "SELECT name FROM agents_org
      WHERE lower(' '||COALESCE(role,'')||' '||COALESCE(title,''))
            LIKE '% '||lower($(sqlq "$(_org_like_escape "$r")"))||'%' ESCAPE '\'
      ORDER BY name;" 2>/dev/null || true
  return 0
}

# _task_role_least_loaded <role> [exclude_lane] — SETS `_TASK_ROLE_PICK` (the
# chosen seat) and `_TASK_ROLE_PICK_BASIS` (the counts that chose it). Read the
# variables; this PRINTS NOTHING, for the `_task_roster` reason one function
# down — a caller writing `x=$(...)` assigns the globals in a subshell and loses
# them. Returns 0 when a seat was picked, 1 when none was (no holders, none
# dispatchable, or the only holder was the excluded one) so the caller can fall
# through to its own refusal.
#
# `exclude_lane` is how acceptance 2's second half is met: the verifier seat is
# simply not a candidate for the build, so `--assignee=role:verifier
# --verifier=quinn` routes the build to the OTHER holder instead of refusing.
_task_role_least_loaded() {
  local role="$1" exclude="${2:-}" lane act best="" best_n="" basis=""
  _TASK_ROLE_PICK=""; _TASK_ROLE_PICK_BASIS=""
  [[ -n "$role" ]] || return 1
  _task_roster
  while IFS= read -r lane; do
    [[ -n "$lane" ]] || continue
    [[ "$lane" == "$exclude" ]] && continue
    if [[ "$_TASK_ROSTER_STATE" == "ok" ]] && ! _task_roster_has "$lane"; then continue; fi
    act=$(_task_lane_actionable "$lane")
    [[ "$act" =~ ^[0-9]+$ ]] || continue
    basis+="${basis:+, }${lane} ${act}"
    # STRICTLY less-than over name-ordered candidates, so equal counts always
    # pick the same seat. A router that alternates on a tie files the two halves
    # of one decomposition into two different lanes, which is worse than either
    # lane being busy.
    if [[ -z "$best" ]] || (( act < best_n )); then best="$lane"; best_n="$act"; fi
  done < <(_org_role_holders "$role")
  [[ -n "$best" ]] || return 1
  _TASK_ROLE_PICK="$best"; _TASK_ROLE_PICK_BASIS="$basis"
  return 0
}

# _task_role_skew_note — acceptance 3. One line on the board when a role's
# busiest seat holds FACTOR times its idlest, NAMING BOTH COUNTS, because the
# bare ratio is what made this invisible for a day: "quinn is loaded" reads as a
# quinn problem, "quinn 14, main2 0" names the routing.
#
# THE WORST ROLE ONLY, once. The requirement is "say so once"; a per-role list
# printed under every `task ls` is the shape readers learn to skip, and this note
# has to survive being seen a hundred times a day.
#
# THE FACTOR NEEDS A FLOOR ON THE COUNT, and that floor is the whole reason this
# is not just `max >= FACTOR * min`: min=0 makes every ratio infinite, so a role
# whose two seats hold 2 and 0 would announce a skew on an essentially empty
# board. The floor is on the BUSY side, so the note fires only when there is
# genuinely something to re-lane.
#
# AND IT SPLITS THE BUSY SEAT'S COUNT INTO GRADING vs BUILDING, which is the part
# that stops this note from being read the way the depth number that prompted it
# was read. DIVE-3366 was filed on "quinn 14 open / main2 0, both verifiers" and
# diagnosed as nine build rows quinn was also booked to grade. Measured after the
# fact: four of those rows carried a NON-NULL `maker_agent`, which makes
# `assignee == verifier` the CORRECT shape of a DELIVERED row — the handoff
# reassigns the row to its grader and parks the builder in `maker_agent` — so
# they were deliveries awaiting a grade, not a seat grading its own build. A
# grading backlog and a mis-laned builder want OPPOSITE fixes (wake the grader vs
# re-lane the work), so a note that names one number for both sends half its
# readers the wrong way. `maker_agent` is the discriminator; the seat count never
# was. See community/wiki/assignee-equals-verifier-is-the-delivered-shape.md.
_task_role_skew_note() {
  local factor="${FIVE_ROLE_SKEW_FACTOR:-3}" floor="${FIVE_ROLE_SKEW_FLOOR:-3}"
  [[ "$factor" =~ ^[0-9]+$ && "$floor" =~ ^[0-9]+$ ]] || return 0
  (( factor >= 2 )) || return 0
  local role lane act n min max min_lane max_lane ratio
  local w_role="" w_ratio=0 w_max=0 w_min=0 w_maxlane="" w_minlane=""
  _task_roster
  while IFS= read -r role; do
    [[ -n "$role" ]] || continue
    min=""; max=""; min_lane=""; max_lane=""; n=0
    while IFS= read -r lane; do
      [[ -n "$lane" ]] || continue
      if [[ "$_TASK_ROSTER_STATE" == "ok" ]] && ! _task_roster_has "$lane"; then continue; fi
      act=$(_task_lane_actionable "$lane")
      [[ "$act" =~ ^[0-9]+$ ]] || continue
      n=$((n+1))
      if [[ -z "$min" ]] || (( act < min )); then min="$act"; min_lane="$lane"; fi
      if [[ -z "$max" ]] || (( act > max )); then max="$act"; max_lane="$lane"; fi
    done < <(db "SELECT name FROM agents_org
                 WHERE role IS NOT NULL AND lower(role)=lower($(sqlq "$role")) ORDER BY name;" 2>/dev/null || true)
    (( n >= 2 )) || continue
    (( max >= floor )) || continue
    (( max >= min * factor )) || continue
    ratio=$(( max / (min > 0 ? min : 1) ))
    if (( ratio > w_ratio )); then
      w_ratio=$ratio; w_role="$role"; w_max=$max; w_min=$min
      w_maxlane="$max_lane"; w_minlane="$min_lane"
    fi
  done < <(db "SELECT DISTINCT role FROM agents_org WHERE role IS NOT NULL AND role<>'' ORDER BY role;" 2>/dev/null || true)
  [[ -n "$w_role" ]] || return 0
  # The split, measured on the busy seat only: it is the seat whose number gets
  # acted on, and one extra query beats a reader guessing which fix applies.
  local grading building=""
  grading=$(db "SELECT COUNT(*) FROM tasks
                WHERE assignee=$(sqlq "$w_maxlane") AND kind='standard'
                  AND status IN ('todo','in_progress') AND parked_at IS NULL
                  AND maker_agent IS NOT NULL AND maker_agent<>'' AND assignee=verifier;" 2>/dev/null || echo "")
  if [[ "$grading" =~ ^[0-9]+$ ]] && (( grading <= w_max )); then
    building=" (${grading} awaiting its grade, $(( w_max - grading )) to build)"
  fi
  warn "LANE SKEW in role '${w_role}' (DIVE-3366): ${w_maxlane} holds ${w_max} open${building}, ${w_minlane} holds ${w_min} — a grading backlog wants the GRADER woken, a build backlog wants the work RE-LANED, so read the split before acting. File to the role, not the name (--assignee=role:${w_role} picks the idler seat and records why), or name ${w_minlane} on the next row."
  return 0
}

# ---------------------------------------------------------------------------
# DIVE-3344 — nothing validated that `assignee` / `created_by` named a REAL
# agent, and the two columns fail in OPPOSITE directions.
#
# The work-picker dispatches on `assignee`, so a row on a name that is not a
# registered agent is STRUCTURALLY UNDISPATCHABLE — not blocked, not parked, not
# flagged. It is never picked, and nothing anywhere says so. Reported from a
# customer box (7 rows on `assignee='cli'`, never once a dispatch target in their
# whole heartbeat log) and corroborated here: 3 open rows on `cli`, 1 on
# `agent-marketing`. `created_by` misroutes rather than drops — their DIVE-350 has
# been orphaned since 2026-07-29 because its gate routes to a creator that does
# not exist.
#
# TWO CLASSES, and the second is the nastier:
#   1. a name that is not an agent at all
#   2. PREFIX DRIFT — `agent-marketing` beside `marketing`, `agent-main` beside
#      `main`. Worse than class 1 because it LOOKS right to a reader and sorts
#      next to the real lane in any listing. So the refusal NAMES the near miss:
#      a bare "unknown agent" gets worked around by re-typing the same wrong name.
#
# `cli` IS NOT A TYPO, AND THIS IS THE MEASUREMENT THAT SPLIT THE VALIDATOR IN
# TWO. lib/actor.sh sets `ACTOR_BOARD="cli"` as its documented sentinel for "could
# not attribute this invocation" (root, cron, a build bot) — see actor_board_name,
# whose own header calls out that 43 call sites inherit it. 25 rows on this board
# carry `created_by='cli'` BY DESIGN; the recent ones are root-cron recurring
# instances. DIVE-3344's acceptance asked for "the same validation on created_by",
# and the same validation would have refused every root and cron filing on the
# board. So:
#   assignee / verifier -> must be a DISPATCHABLE LANE. `cli` is refused.
#   created_by / --from -> must be a KNOWN PRINCIPAL = lane OR sentinel. `cli` is
#                          accepted; `agent-main` is still refused, which is the
#                          class that actually misroutes gates.
#
# THE AUTHORITY IS THE REGISTRY, and when it cannot be read this REFUSES NOTHING.
# actor.sh already settled that question ("the registry is the authority on
# agent-ness — DIVE-2371: a username PREFIX is not"), and registry_read_checked
# exists precisely so a caller can tell an absent fleet from an unreadable one.
# A roster we could not establish is `unestablished:<why>`, never a silent empty:
# an empty roster treated as authoritative would refuse EVERY name, which on a
# fresh install or inside a unit harness means the guard breaks the board instead
# of the typo. `agents_org` is unioned in because it names lanes a lagging
# registry may miss, but it can only WIDEN acceptance — it never establishes the
# roster on its own, so an unreadable registry beside a populated org chart still
# refuses nothing rather than refusing the four agents the chart omits.
# ---------------------------------------------------------------------------

# Non-agent principals that legitimately own a `created_by` and NEVER an
# assignee — nothing wakes them. Measured on this board 2026-08-12: cli 25,
# council 97, lodar 4, editor 4, proof 2 (`5dive proof` files with --from=proof).
# `trigger` marks tasks materialized by signed Event-to-Task ingress; keeping it
# distinct from `cron` makes each external delivery's provenance queryable.
_TASK_PRINCIPAL_SENTINELS="cli council telegram dashboard lodar editor proof cron trigger"

_TASK_ROSTER=""; _TASK_ROSTER_STATE=""

# _task_roster — SETS `_TASK_ROSTER` (newline-separated lane names) and
# `_TASK_ROSTER_STATE` (`ok` or `unestablished:<why>`). Read the variables.
#
# IT DELIBERATELY PRINTS NOTHING, and that is a bug fix, not a style choice. The
# first cut of this returned the roster on stdout, so every caller wrote
# `roster=$(_task_roster)` — and a variable assigned inside `$( )` is assigned in
# a SUBSHELL and lost. `_TASK_ROSTER_STATE` therefore came back EMPTY at each of
# those call sites, which is neither `ok` nor `unestablished:*`, so `wip-cap-install`
# skipped nothing and `task orphans` reported "the roster is " and refused. The
# failure direction is what matters: the state that survived was the one that
# means "could not measure", so the guards went QUIET rather than loud. Callers
# must not re-introduce the substitution.
#
# CHECK THE STATE, never the emptiness of the roster: they are different facts.
_task_roster() {
  if [[ -z "$_TASK_ROSTER_STATE" ]]; then
    local body rc reg="" org="" why=""
    # THE ROSTER AND THE BOARD MUST COME FROM THE SAME STATE DIR, and that is why
    # the path is re-derived here instead of using the global $REGISTRY.
    # header.sh binds REGISTRY="${STATE_DIR}/agents.json" ONCE, at source time.
    # STATE_DIR is env-overridable (DIVE-1475) and ~60 unit harnesses repoint it
    # AFTER sourcing to get a scratch board — which moves TASKS_DB and leaves
    # REGISTRY pointing at the HOST's real fleet. A guard reading this host's 18
    # live agents while grading a temp board is comparing two different worlds: it
    # armed against every fixture on the box and reported 16 harnesses red, none of
    # which was about agent names. In production the two paths are the same string,
    # so this changes nothing there; the assignment-prefix keeps the override
    # scoped to the substitution's subshell.
    local _reg="${STATE_DIR:-/var/lib/5dive}/agents.json"
    # `&& rc=0 || rc=$?`, NOT `; rc=$?`. registry_read_checked's whole point is
    # that it returns 3/4/5 instead of inventing a body — and under the bundle's
    # `set -euo pipefail` an ASSIGNMENT whose substitution exits non-zero kills the
    # process before the next line runs. With `; rc=$?` a host with no registry
    # (every fresh store) died on `task add` with "exited 3 without reporting a
    # reason": the guard's own not-measured path took the board down. Being part of
    # an `||` list is what makes the non-zero survivable.
    body=$(REGISTRY="$_reg" registry_read_checked 2>/dev/null) && rc=0 || rc=$?
    case "$rc" in
      0) reg=$(printf '%s\n' "$body" | jq -r '(.agents // {}) | keys[]?' 2>/dev/null || true)
         [[ -n "$reg" ]] || why="registry-names-no-agents" ;;
      3) why="no-registry-file" ;;
      4) why="registry-unreadable" ;;
      5) why="registry-unparseable" ;;
      *) why="registry-rc${rc}" ;;
    esac
    org=$(db "SELECT name FROM agents_org WHERE name IS NOT NULL AND name<>'';" 2>/dev/null || true)
    # `|| true` on the grep: an all-blank union exits 1, and this file is cat into
    # a bundle that runs under `set -euo pipefail`.
    _TASK_ROSTER=$(printf '%s\n%s\n' "$reg" "$org" | grep -v '^[[:space:]]*$' | sort -u || true)
    # `ok` requires the AUTHORITY to have answered with at least one agent. The
    # org chart widens the roster but cannot establish it.
    if [[ -n "$reg" ]]; then _TASK_ROSTER_STATE="ok"
    else _TASK_ROSTER_STATE="unestablished:${why:-unknown}"; fi
  fi
  return 0
}

_task_roster_has() {
  [[ -n "$1" ]] || return 1
  _task_roster
  grep -qxF -- "$1" <<<"$_TASK_ROSTER"
}

# _task_roster_nearmiss <name> — the roster entry the caller most likely meant,
# or nothing. Ordered by how the drift actually occurs on real boards; the first
# two rungs are the `agent-` prefix, which is the measured case and is exactly
# the prefix actor_board_name strips on its passwd rung.
_task_roster_nearmiss() {
  local name="$1" roster cand
  _task_roster; roster="$_TASK_ROSTER"
  [[ -n "$name" && -n "$roster" ]] || { printf ''; return; }
  # EVERY branch below is an `if`, and this function ends in `return 0`, because
  # the bundle runs under `set -euo pipefail`: a trailing `[[ … ]] && printf …`
  # exits 1 on the no-suggestion path, and `marks+="$(_task_roster_nearmiss x)"`
  # would then kill `task orphans` mid-listing. That is how the first cut of this
  # shipped a verb that died with "exited 1 without reporting a reason" — the unit
  # harness runs `set +e` and could not see it.
  # 1. agent-<x> -> <x>   2. <x> -> agent-<x>
  for cand in "${name#agent-}" "agent-${name}"; do
    [[ "$cand" == "$name" ]] && continue
    if grep -qxF -- "$cand" <<<"$roster"; then printf '%s' "$cand"; return 0; fi
  done
  # 3. case only
  cand=$(grep -ixF -- "$name" <<<"$roster" | head -1 || true)
  if [[ -n "$cand" ]]; then printf '%s' "$cand"; return 0; fi
  # 4. a UNIQUE roster entry that contains, or is contained by, the name. Unique
  #    only — suggesting one of several is a guess dressed as help. `dev` would
  #    otherwise "suggest" dev2/dev3 arbitrarily.
  local hits n_hits
  hits=$(while IFS= read -r cand; do
           [[ -n "$cand" ]] || continue
           case "$name" in *"$cand"*) printf '%s\n' "$cand"; continue ;; esac
           case "$cand" in *"$name"*) printf '%s\n' "$cand" ;; esac
         done <<<"$roster")
  n_hits=$(printf '%s' "$hits" | grep -c . || true)
  if [[ "$n_hits" == "1" ]]; then printf '%s' "${hits//$'\n'/}"; fi
  return 0
}

# Emitted once per process when a guard could not run. A guard that cannot
# measure must SAY it did not measure — a silent skip and a pass look identical.
_TASK_ROSTER_WARNED=""
_task_roster_unestablished_note() {
  if [[ -n "$_TASK_ROSTER_WARNED" ]]; then return 0; fi
  _TASK_ROSTER_WARNED=1
  # A genuinely absent fleet (fresh install, unit harness) is not a defect and is
  # not worth a line on every add. An UNREADABLE or CORRUPT registry is.
  case "$_TASK_ROSTER_STATE" in
    unestablished:registry-unreadable|unestablished:registry-unparseable)
      warn "agent-name validation SKIPPED (${_TASK_ROSTER_STATE#unestablished:}) — ${STATE_DIR:-/var/lib/5dive}/agents.json could not be read, so '$1' was accepted unchecked. Fix the registry: 5dive doctor" ;;
  esac
  return 0
}

# _task_require_lane <name> <flag> — REFUSE a name that is not a dispatchable
# lane. Callers pass the flag spelling the user typed so the refusal is actionable.
_task_require_lane() {
  local name="$1" flag="$2" hint=""
  [[ -n "$name" ]] || return 0
  _task_roster
  [[ "$_TASK_ROSTER_STATE" == "ok" ]] || { _task_roster_unestablished_note "$name"; return 0; }
  if _task_roster_has "$name"; then return 0; fi
  # The sentinel gets its own refusal: it is a legal created_by, so "not a
  # registered agent" would read as a contradiction to anyone who has seen it in
  # that column.
  if grep -qw -- "$name" <<<"$_TASK_PRINCIPAL_SENTINELS"; then
    fail "$E_VALIDATION" "${flag}='${name}' is not a lane — '${name}' is the actor sentinel for an invocation that could not be attributed to an agent (root, cron, a build bot). It is legal as a CREATOR and never as an owner: nothing wakes it, so the row would sit undispatched forever. Name a real agent: 5dive agent list"
  fi
  hint=$(_task_roster_nearmiss "$name")
  fail "$E_VALIDATION" "${flag}='${name}' is not a registered agent$([[ -n "$hint" ]] && printf -- " — did you mean '%s'?" "$hint") (nothing wakes an unregistered lane, so this row would never be dispatched; see: 5dive agent list)"
}

# _task_require_principal <name> <flag> — for created_by/--from. Lane OR sentinel.
_task_require_principal() {
  local name="$1" flag="$2" hint=""
  [[ -n "$name" ]] || return 0
  _task_roster
  [[ "$_TASK_ROSTER_STATE" == "ok" ]] || { _task_roster_unestablished_note "$name"; return 0; }
  if _task_roster_has "$name"; then return 0; fi
  if grep -qw -- "$name" <<<"$_TASK_PRINCIPAL_SENTINELS"; then return 0; fi
  hint=$(_task_roster_nearmiss "$name")
  fail "$E_VALIDATION" "${flag}='${name}' is not a registered agent or a known principal$([[ -n "$hint" ]] && printf -- " — did you mean '%s'?" "$hint") (a creator that does not exist misroutes every gate this row ever files; known non-agent principals: ${_TASK_PRINCIPAL_SENTINELS})"
}

# _task_roster_sql_notin — a SQL fragment listing the roster, for the surfacer.
# Prints nothing when the roster is unestablished, so a caller that interpolates
# it cannot turn "could not measure" into "everything is an orphan".
_task_roster_sql_notin() {
  local roster n out=""
  _task_roster; roster="$_TASK_ROSTER"
  [[ "$_TASK_ROSTER_STATE" == "ok" ]] || { printf ''; return; }
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    out+="${out:+,}$(sqlq "$n")"
  done <<<"$roster"
  printf '%s' "$out"
}
