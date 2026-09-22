# ── DIVE-4251: verification is a CUSTOMER choice ────────────────────────────
#
# lodar, 2026-09-10: "about new maker spawns verifier feature. can it be
# optional? some 5dive customers dont need their tasks to be verified."
#
# Until now "every standard row gets a grader" was a property of the CODE, not
# of the box. That was affordable while a verifier was a standing seat already
# paid for; DIVE-4164/4217 made the grader an EPHEMERAL SPAWNED SESSION, so a
# grader is now a second session per delivery and the default is a spend
# decision somebody other than us should be making.
#
# THREE VALUES, AND THE MIDDLE ONE IS THE INTERESTING ONE:
#   always          — every standard row gets a grader (our own fleet).
#   delivered-only  — a grader is attached when the row is BOUND TO A DELIVERY
#                     (`task deliver --pr=…`), i.e. code that ships. Knowledge,
#                     ops and coordination rows close without one.
#   never           — no row gets a grader from the box default.
#
# THE ROW OVERRIDE ALWAYS WINS OVER THE BOX DEFAULT, in both directions:
# `--no-verify` skips a grader on an `always` box, `--verify` demands one on a
# `never` box. That is what makes `never` safe to choose — it is a default, not
# a ceiling, exactly as DIVE-1880 said of the low-priority auto-skip.
#
# WHY A FILE AND NOT A COLUMN OR AN ENV VAR. A column would be per-row and this
# is per-BOX. `FIVE_VERIFY_DEFAULT=0` already exists and is a FLEET KILL-SWITCH
# living in whatever environment happened to invoke the CLI — it cannot be read
# back, cannot be shown in `task show`, and a customer cannot set it once and
# have every seat honour it. A root-owned file in STATE_DIR is readable by group
# `claude` (the same 2750 tree agents.json sits in), so every seat reads the
# same answer without sudo, and only root writes it.
# RESOLVED AT READ TIME, not at load time. STATE_DIR is reassigned after the libs
# are sourced by ~60 test harnesses (and by `STATE_DIR=… 5dive …` in the field),
# so a top-level expansion here would freeze the path at /var/lib/5dive and a
# harness would silently read the LIVE box's policy — the same class of defect as
# a test that writes the production task board.
_box_config_path() { printf '%s' "${BOX_CONFIG:-${STATE_DIR:-/var/lib/5dive}/box.json}"; }

# The three legal values, in one place, so the setter, the validator and the
# help text cannot drift apart.
_VERIFY_POLICIES="always delivered-only never"

_verify_policy_valid() {  # <value>
  local v="${1:-}" p
  for p in $_VERIFY_POLICIES; do [[ "$v" == "$p" ]] && return 0; done
  return 1
}

# `box_verify_policy` — the box default. Prints one of the three values.
#
# DEFAULTS TO `delivered-only`, the customer default approved on DIVE-4251.
# Absence means nobody chose a policy, so fresh, pre-wizard, and manually
# provisioned boxes all get the same answer: unbound knowledge/ops work spends
# no grader session, while code acquires one when `task deliver --pr=` binds it.
# An existing box that deliberately chose `always` keeps that explicit value.
box_verify_policy() {
  local v=""
  # FIVE_VERIFY_DEFAULT=0 is the pre-existing fleet kill-switch. It is honoured
  # here rather than left as a second, separately-consulted rail: two switches
  # that answer the same question are how one of them stops being read.
  if [[ "${FIVE_VERIFY_DEFAULT:-1}" == "0" ]]; then printf 'never'; return 0; fi
  local f; f=$(_box_config_path)
  if [[ -r "$f" ]]; then
    v=$(jq -r '.verify // empty' "$f" 2>/dev/null || printf '')
  fi
  _verify_policy_valid "$v" || v="delivered-only"
  printf '%s' "$v"
}

# `verify_grants_grader <policy> <override> <bound-to-delivery>` — the single
# resolver. Exit 0 = this row gets a grader; non-zero = it does not.
#
#   <override>  force | skip | ""   (the row's `--verify` / `--no-verify`)
#   <bound>     1 when the row is bound to a delivery ref, else 0
#
# ONE FUNCTION, FOUR CALLERS (task add, task deliver, the done routing fork, the
# grader pool tick). The 9-arm matrix is a property of THIS function, so a
# caller that forgets the box default is a caller that stopped calling it — and
# that is what tests/verify_policy_matrix_unit.sh's mutation arm asserts.
verify_grants_grader() {  # <policy> <override> <bound>
  local policy="${1:-always}" override="${2:-}" bound="${3:-0}"
  case "$override" in
    force) return 0 ;;   # the row demanded a grade — box default cannot refuse
    skip)  return 1 ;;   # the row opted out — box default cannot force
  esac
  case "$policy" in
    always)         return 0 ;;
    never)          return 1 ;;
    delivered-only) [[ "$bound" == "1" ]] && return 0 || return 1 ;;
    *)              return 0 ;;   # unknown value reads as `always`, never as off
  esac
}

# `verify_policy_source <override>` — the provenance string `task show` prints
# beside the policy, so a reader can tell a box default from a row override
# without reconstructing the resolver in their head.
verify_policy_source() {  # <override>
  case "${1:-}" in
    force) printf 'row override --verify' ;;
    skip)  printf 'row override --no-verify' ;;
    *)     printf 'box default' ;;
  esac
}

# `_task_verify_grants <task-id> [ignore-skip]` — the resolver, applied to a ROW
# that already exists. Exit 0 = this row may have a grader.
#
# `ignore-skip=1` deliberately drops the row's `--no-verify` while keeping the
# box default and the row's `--verify`. That single argument is DIVE-2730 kept
# intact: the delivery-time blast-radius UPGRADE in `task done` must still fire
# on an opted-out row, because `--no-verify` is a sentence typed before the diff
# existed. A BOX policy is a different animal — it is a standing customer choice
# about spend, not a claim about one diff — so it is honoured on both paths.
_task_verify_grants() {  # <task-id> [ignore-skip]
  local id="$1" ignore_skip="${2:-0}" optout forced ref bound=0 ov=""
  optout=$(db "SELECT COALESCE(verify_optout,0) FROM tasks WHERE id=${id};" 2>/dev/null || printf 0)
  forced=$(db "SELECT COALESCE(verify_forced,0) FROM tasks WHERE id=${id};" 2>/dev/null || printf 0)
  ref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=${id};" 2>/dev/null || printf '')
  [[ -n "$ref" ]] && bound=1
  [[ "$optout" == "1" && "$ignore_skip" != "1" ]] && ov="skip"
  [[ "$forced" == "1" ]] && ov="force"
  verify_grants_grader "$(box_verify_policy)" "$ov" "$bound"
}

# `_task_verify_row_source <task-id>` — the provenance string for `task show`.
_task_verify_row_source() {  # <task-id>
  local id="$1" optout forced ov=""
  optout=$(db "SELECT COALESCE(verify_optout,0) FROM tasks WHERE id=${id};" 2>/dev/null || printf 0)
  forced=$(db "SELECT COALESCE(verify_forced,0) FROM tasks WHERE id=${id};" 2>/dev/null || printf 0)
  [[ "$optout" == "1" ]] && ov="skip"
  [[ "$forced" == "1" ]] && ov="force"
  verify_policy_source "$ov"
}

# ── DIVE-4324: the review MODE, one field, chosen at filing ──────────────────
#
# lodar, 2026-09-11: "I think it should be per task. easy tasks no reviewer at
# all. some with spawnable temp reviewer some with agent reviewer .. encoded
# into 5dive and 5dive skill"
#
# All four modes were already reachable before this — through four unrelated
# flags nobody picks between at filing time (`--no-verify`, `--verify=<cmd>`,
# the DIVE-969 default, `--verifier=<agent>`). What was missing is a single
# question asked ONCE, at the only moment the filer is thinking about the row:
# who, if anyone, grades this?
#
#   none          nobody. `task done` closes it outright.
#   check         a COMMAND grades it (`--verify=<cmd>`). No session is spent.
#   temp          one fresh pool session grades one delivery, then is gone
#                 (DIVE-4164's ephemeral grader — today's default).
#   seat:<agent>  a pinned standing reviewer grades it in its own session.
#
# THE MODE IS NOT THE AUTHORITY ON SPEND. `verify_grants_grader` above is, and
# the box policy still CAPS the mode: on a `verify=never` box every mode that
# would cost a session resolves to `none`. A mode is what the filer asked for; a
# policy is what the box will pay for, and conflating them is how `--tier=1` on
# an approval became a no-op that looked like a control (see the rules file).
_REVIEW_MODE_FIXED="none check rubric temp"

# `review_mode_kind <mode>` — none|check|temp|seat|invalid. `seat` is any other
# non-empty token, validated as an agent name by the caller (which has the lane
# helpers); this function is pure string classification so the harness can call
# it without a task store.
review_mode_kind() {  # <mode>
  local m="${1:-}" f
  [[ -n "$m" ]] || { printf 'invalid'; return 1; }
  for f in $_REVIEW_MODE_FIXED; do [[ "$m" == "$f" ]] && { printf '%s' "$f"; return 0; }; done
  [[ "$m" == seat:* ]] && m="${m#seat:}"
  # An agent name. Deliberately narrow: a mode that accepted arbitrary text
  # would store a typo'd seat as a pinned reviewer that never wakes.
  [[ "$m" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { printf 'invalid'; return 1; }
  printf 'seat'
}

# `review_mode_cost_note <mode>` — what this mode COSTS, in the words the filer
# reads on the `task add` line. DIVE-4251 deliverable 3 established that the
# cost is said where the choice is made; this keeps the four answers in one
# place so the add line, `task show` and the help table cannot drift apart.
review_mode_cost_note() {  # <mode>
  case "$(review_mode_kind "${1:-}")" in
    none)  printf 'no grader — "task done" closes it outright' ;;
    check) printf 'graded by a command, no grader session' ;;
    rubric) printf 'one fixed six-question cheap pass; flags escalate to a full grade' ;;
    temp)  printf 'one grader session per delivery, then gone' ;;
    seat)  printf 'graded by %s in its own session' "${1#seat:}" ;;
    *)     printf 'unknown' ;;
  esac
}

# ── DIVE-4623: A CHECK THAT CANNOT FAIL IS NOT A GRADE ───────────────────────
#
# `check` was never trusted as a DEFAULT, and the reason was not that a command
# grades badly — it is that nothing proved the command could go red. `--verify=true`
# is a passing grade on every tree that will ever exist, and it is indistinguishable,
# in the store and on the board, from a real acceptance run. So the mode carries a
# NEGATIVE CONTROL: the command that breaks the delivered tree. Both arms run at
# delivery and a check that survives the break is refused as evidence.
#
# The measurement that forced it (main, 2026-09-19, summed `message.usage` over
# seven days of transcripts): the single grader seat out-burned the maker seat it
# grades, 2318.8M vs 2307.0M quota tokens, 97.8% of it cache-read — a second full
# session re-loading a diff that had already been made. A command grade with a
# proven-red control costs a command.
#
# `mutant_escape_reason <value>` — prints the reason when the stored value is the
# audited escape (`none: <why>`), and returns 1 for a real command or an empty
# cell. One place decides what the prefix means, so the filer's refusal, the
# delivery arm and `task show` cannot drift apart on it.
mutant_escape_reason() {  # <stored mutant_command>
  local v="${1:-}"
  [[ "$v" == none:* ]] || return 1
  local r="${v#none:}"
  printf '%s' "${r# }"
}

# `mutant_control_note <stored mutant_command>` — what the row's negative control
# IS, in the words the filer and the board read. Same reason as
# `review_mode_cost_note` above: the add line, `task show` and the help table
# must not each invent their own sentence for the same stored state.
mutant_control_note() {  # <stored mutant_command>
  local v="${1:-}" r
  if [[ -z "$v" ]]; then
    printf 'NO negative control — nothing proves this check can fail'
  elif r=$(mutant_escape_reason "$v"); then
    printf 'negative control waived (audited): %s' "$r"
  else
    printf 'negative control: %s' "$v"
  fi
}

# ── DIVE-4576: THE DELIVERY CARRIES ITS EVIDENCE ─────────────────────────────
#
# lodar, 2026-09-15: "yes. thats important for our tight tokens subscriptions"
#
# Grading is RE-DERIVATION today. A grader clone cold-reloads the pull request
# and re-runs the maker's investigation, because the result field it is handed
# says what the maker BELIEVES and not what the maker RAN — so the only way to
# grade a claim is to go and make it yourself. That is a second full session per
# close, and a reject repeats it on both seats (DIVE-4440: five iterations, 34h,
# for a diff that ended as comments plus a changelog line).
#
# A claim with evidence attached is CHEAP to grade: the grader re-runs the named
# command against the named sha and compares. A claim with none is not gradeable
# at all without redoing the work. So the fields below are not a report format —
# each one is the input to a check the grader would otherwise have to invent:
#
#   CHANGED    which files moved              → what the diff spot-check reads
#   CHECKED    the commands run + pass/fail    → what the grader RE-RUNS
#   DELIVERED-SHA the sha those numbers came from → what it re-runs them AGAINST
#   CI         the CI state at delivery        → already required to be LOOKED at
#   CRITERIA   each acceptance criterion → its evidence  → the grade's own rubric
#
# ONE MARKER PER FIELD, NOT A PROSE CLASSIFIER, for the reason DIVE-4144's FIX
# marker is one: the property being asserted is that the field is LABELLED and
# greppable, never that its contents are good — no regex holds that, and a check
# that pretended to would be a worse lie than the one it replaced. Aliases are
# accepted because makers already write these five things under several names,
# and refusing a delivery over a synonym teaches makers to fight the rail.
#
# THE SEPARATOR AND THE LEADING BOUNDARY ARE LOAD-BEARING, exactly as in
# _REJECT_FIX_MARKER_RE: without the non-alphanumeric boundary "unchecked:" and
# "prefixed-sha:" satisfy their own fields, and without demanding an alphanumeric
# AFTER the separator an empty label passes.
#
# THE SHA FIELD IS `DELIVERED-SHA`, NOT `GRADED-SHA`, AND THE DIFFERENCE IS A
# CONTROL, NOT A WORD (DIVE-4576 iteration 1, rejected for exactly this).
# `_gate_graded_sha` is a LABEL-ONLY fence whose subject is the VERIFIER's
# attestation — DIVE-2940 refuses a close whose result states no `graded-sha`,
# and DIVE-2656 then compares that sha to what the PR actually merged, precisely
# because "the maker can push after the verdict". Mandating the byte-identical
# label on every bound DELIVERY would make the MAKER the author of that operand
# on every row: DIVE-2940 would be pre-satisfied before anyone graded anything,
# and DIVE-2656 would compare a maker-authored, delivery-time sha against the
# head — the "every other check on this gate would still pass" case it exists to
# catch. The fence is label-only, so a label that does not overlap is the whole
# fix; `SHA` and `HEAD-SHA` are dropped from the alias list below for the same
# reason (`graded sha` / `graded_sha` / `graded-sha` are the tokens that overlap,
# and a bare `SHA` alias re-admits every one of them).
_DELIVERY_EVIDENCE_FIELDS='CHANGED CHECKED DELIVERED-SHA CI CRITERIA'

# `_delivery_evidence_field_re <field>` — the marker regex for one field.
# Aliases live HERE and nowhere else, so the refusal, the template and the tests
# cannot drift into describing three different contracts.
_delivery_evidence_field_re() {  # <field>
  local alts
  case "${1:-}" in
    CHANGED)    alts='CHANGED|FILES' ;;
    CHECKED)    alts='CHECKED|HOW|EVIDENCE|RAN' ;;
    DELIVERED-SHA) alts='DELIVERED-SHA|DELIVERED_SHA|DELIVEREDSHA|DELIVERY-SHA|DELIVERY_SHA' ;;
    CI)         alts='CI|CI-STATE|CHECKS' ;;
    CRITERIA)   alts='CRITERIA|ACCEPTANCE|CRITERION' ;;
    *)          return 1 ;;
  esac
  printf '(^|[^[:alnum:]_])(%s)[[:space:]]*([(:=-]|—)[^[:alnum:]]*[[:alnum:]]' "$alts"
}

# `_delivery_evidence_missing <result-text>` — prints the MISSING field labels,
# space separated. rc=0 when nothing is missing.
#
# Case-insensitive on the label (`shopt -s nocasematch` is process state a
# caller may rely on, so it is saved and restored rather than set globally).
_delivery_evidence_missing() {  # <result text>
  local text="${1:-}" f re missing="" _nc
  _nc=$(shopt -p nocasematch); shopt -s nocasematch
  for f in $_DELIVERY_EVIDENCE_FIELDS; do
    re=$(_delivery_evidence_field_re "$f") || continue
    [[ "$text" =~ $re ]] || missing="${missing}${missing:+ }${f}"
  done
  eval "$_nc"
  printf '%s' "$missing"
  [[ -z "$missing" ]]
}

# `_delivery_evidence_template` — the five labelled lines a maker fills in. ONE
# string: `task show` prints it on an in-progress row so the maker FILLS it, the
# refusal prints it so a maker who hit the rail is not left guessing, and the
# help text quotes it. DIVE-4144's `_REJECT_TEMPLATE_HINT` is the precedent.
_delivery_evidence_template() {
  cat <<'TPL'
CHANGED: <the files that moved, and in one clause what each change does>
CHECKED: <every command you ran, each with its pass/fail counts — "17 arms, 17 pass; 3 mutation arms red on the pre-fix tree">
DELIVERED-SHA: <the sha those numbers were produced at — the head the grader re-runs them against. NOT `graded-sha`: that label is the verifier's, and writing it here would pre-satisfy the gate that checks the verdict>
CI: <what CI said at delivery, or "not finished at delivery" (you must LOOK, you must not WAIT)>
CRITERIA: <each acceptance criterion, and the line of evidence above that closes it>
TPL
}

# ── DIVE-4559: the SMALL-delivery downgrade — the inverse of DIVE-2730 ───────
#
# lodar, Telegram 2026-09-15: "can we set verification off for small tasks? we
# can be flexible" — asked immediately after "maybe we shouldn't turn off
# grader?". Both sentences are the spec: keep grading what ships, stop spending
# a whole cold grader session (a fresh seat reloading a PR from nothing) on a
# two-line fix.
#
# THE BOX KNOB IS A SECOND QUESTION, NOT A FOURTH POLICY VALUE. `verify` asks
# *which rows* get a grader and is answered at filing; this asks *how big a
# delivery has to be* to be worth one, and can only be answered at delivery.
# Folding it into `_VERIFY_POLICIES` would have made the 9-arm matrix a 12-arm
# one in which three arms mean "it depends on a number stored somewhere else".
#
# DEFAULT `off`, INCLUDING ON THIS BOX until it is set explicitly. A downgrade
# that arrives switched on would retroactively ungrade every small delivery on
# every box that upgrades the CLI, which is a spend decision made for the
# customer — the exact thing DIVE-4251 exists to stop.
_verify_small_valid() {  # <value>
  local v="${1:-}"
  [[ "$v" == "off" ]] && return 0
  [[ "$v" =~ ^[1-9][0-9]*$ ]]
}

# `box_verify_small` — the changed-line threshold under which a delivery closes
# without booking a grader. Prints a positive integer, or `off`.
#
# Read at call time and validated on the way out, for the same two reasons
# `box_verify_policy` is: STATE_DIR is reassigned by ~60 harnesses after the
# libs load, and a hand-edited box.json must never be able to make an unreadable
# value mean "a very large number". Anything unparseable reads as `off` — the
# direction that keeps grading.
box_verify_small() {
  local v="" f; f=$(_box_config_path)
  if [[ -r "$f" ]]; then
    v=$(jq -r '.verify_small // empty' "$f" 2>/dev/null || printf '')
  fi
  _verify_small_valid "$v" || v="off"
  printf '%s' "$v"
}

# `_task_grade_table_from_body <id>` — the LAST computed table written onto the
# row, or nothing.
#
# READ BACK OUT OF THE BODY because that is where it was written for a human to
# find on `task show`, and a second copy in a column is a second thing to keep in
# sync. The fence is the contract: `_task_grade_flagged_route` writes the header
# and then one fenced block, so the extraction is the last fence after the last
# header rather than a guess at where the prose ends.
_task_grade_table_from_body() {  # <id>
  local body; body=$(db "SELECT COALESCE(body,'') FROM tasks WHERE id=${1};" 2>/dev/null || printf '')
  [[ "$body" == *"COMPUTED GRADE (DIVE-4825)"* ]] || return 1
  printf '%s\n' "$body" | awk '
    /COMPUTED GRADE \(DIVE-4825\)/ { seen=1; buf=""; infence=0; next }
    seen && /^```$/ { infence = !infence; if (!infence && buf != "") { last=buf; buf="" } ; next }
    seen && infence { buf = buf $0 "\n" }
    END { printf "%s", last }'
}
