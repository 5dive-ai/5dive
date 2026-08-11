# -------- 5dive task — routing --------
#
# Split out of src/cmd_task.sh (DIVE-3278): resolution + policy helpers: coordinator / deputy / QA lookup, verify-skip
# reasons, delivery paths, lane + WIP-cap arithmetic, the filing cap, and
# assignee resolution.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
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
_task_lanes_with_headroom() {
  local skip="$1" lane cap act out=""
  while IFS= read -r lane; do
    [[ -n "$lane" && "$lane" != "$skip" ]] || continue
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
    if [[ -n "$c" && "$c" != "$_assignee" ]] && ! _task_verify_excluded "$c"; then
      printf '%s' "$c"; return
    fi
  done
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

