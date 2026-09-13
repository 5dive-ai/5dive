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
_REVIEW_MODE_FIXED="none check temp"

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
    temp)  printf 'one grader session per delivery, then gone' ;;
    seat)  printf 'graded by %s in its own session' "${1#seat:}" ;;
    *)     printf 'unknown' ;;
  esac
}
