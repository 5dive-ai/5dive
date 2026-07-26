# --- selfcheck: prove the rails ACTED (DIVE-2039, v0.16 "Fails loud") ---------
#
# The v0.16 headline capability. Every other check we own grades a rail on what it
# REPORTED. This one grades it on what it CHANGED.
#
# 24h of defects (0.15.8 -> 0.15.30) had one shape: a rail that reported success and
# changed nothing. A harness exiting 0 with a stranded verdict (DIVE-2003). Nine audit
# sub-events gated on $EUID so an agent's own actions left no row (DIVE-1989). Gates
# filed, reported pinged, recording nothing — 194 undelivered rows AFTER the first fix
# (DIVE-1968/1927). crontab-snapshot exiting 0 having saved nothing (DIVE-1991/1994).
# install/self-update serving a bundle and its checksum from different cache
# generations (DIVE-1977). A scorecard rendering a partial read as a number
# (DIVE-1929/1937). None of these was caught by running the rail and reading its output,
# because running the rail and reading its output is exactly what they all survive.
#
# THREE VERDICTS, NOT TWO. Every probe reports pass | fail | NOT-REACHED, and
# NOT-REACHED is a first-class third state that is NEVER folded into pass. That is the
# DIVE-2018 gap stated as a design rule: a probe whose precondition is absent has not
# been shown to work, and a check that cannot say so reports "fine" for a rail nobody
# measured. A NOT-REACHED with no reason is not excusable and exits non-zero — the
# escape hatch is the precondition, never the silence.
#
# NOT-REACHED IS NOT FREE. It is excusable in ONE run and never in ALL of them:
# `--report=<file>` emits a machine-readable verdict per probe, and
# tests/meta/selfcheck-union.sh asserts the corpus is REACHED in the union of the
# pristine and installed-host jobs. A probe not-reached everywhere is permanently
# unmeasured and permanently green — the same defect one level up in the instrument.
#
# ISOLATED, ALWAYS. Every probe that writes runs against its own STATE_DIR / TASKS_DB /
# AUDIT_LOG / notify log under a throwaway dir, never the live store. This is not
# politeness: the DIVE-1968 diagnosis was mis-read for a day because fixture rows and
# real rows shared one file (DIVE-2010), so a prover that contaminated the evidence
# base would be building the next mis-diagnosis. Human sends are fenced twice over —
# FIVEDIVE_NO_HUMAN_SEND plus a non-prod TASKS_DB (the DIVE-1506 positive allowlist).
#
# PROVEN BY MUTATION, NOT BY A GREEN RUN. A green run cannot tell a working probe from
# a probe that asserts nothing. tests/selfcheck_mutation_e2e.sh breaks each of the
# first three rails for real and requires selfcheck to go red, then restores and
# requires green. "It passed" is not evidence here; "it failed when I broke it" is.

# The corpus, in order. Declared in ONE place: the report header, the --list output and
# the union script's contract all read this, so they cannot drift into three lists.
SELFCHECK_PROBES=(
  gate-delivery
  audit-root
  audit-nonroot
  harness-verdicts
  bundle-integrity
  snapshot-rails
  scorecard-honesty
)

_sc_title() {
  case "$1" in
    gate-delivery)     echo "a filed gate leaves a delivery row on the filer's own channel" ;;
    audit-root)        echo "a privileged action lands an audit row" ;;
    audit-nonroot)     echo "an UNPRIVILEGED agent action lands an audit row, or leaves a drop marker" ;;
    harness-verdicts)  echo "every test harness's exit status is wired to its own verdict" ;;
    bundle-integrity)  echo "the installed bundle's sha256 matches the commit it claims" ;;
    snapshot-rails)    echo "the crontab snapshot committed what it says it saved" ;;
    scorecard-honesty) echo "a partial read renders as NO DATA, never as a number" ;;
    *)                 echo "$1" ;;
  esac
}

# Probes speak one line back to the runner: <verdict>|<reason>|<detail>
#   verdict = pass | fail | not-reached | error
#   reason  = machine-readable precondition id; REQUIRED for not-reached, else the
#             run exits non-zero. "I did not measure this" without "because X" is the
#             silence this verb exists to remove.
#   detail  = one human sentence, always populated, including on pass — a pass that
#             cannot say WHAT it observed is indistinguishable from a pass that
#             observed nothing.
# Progress goes to STDERR, always, in every mode. stdout is the machine-readable
# surface (--json, the report) and must never carry chatter; stderr is where a human
# and a CI log watch the thing move.
#
# This exists because --full ran >15 minutes writing ZERO bytes (found by main). The
# duration is inherent — it mutates every harness in the corpus — but the SILENCE was
# a defect on its own terms: a long job that prints nothing cannot be told apart from
# a wedged one, which is this release's whole subject applied to its own flagship.
_sc_note() { printf '%s\n' "$*" >&2; }

_sc_pass()       { printf 'pass||%s\n' "$1"; }
_sc_fail()       { printf 'fail||%s\n' "$1"; }
_sc_notreached() { printf 'not-reached|%s|%s\n' "$1" "$2"; }
_sc_error()      { printf 'error||%s\n' "$1"; }

# A throwaway state dir for one probe. Callers rm -rf it themselves (a trap inside a
# command substitution fires in the wrong shell for some of these).
_sc_tmp() { mktemp -d "${TMPDIR:-/tmp}/5dive-selfcheck.XXXXXX" 2>/dev/null; }

# _sc_self — the binary under test is the one THIS CODE IS PART OF, never whatever
# `5dive` happens to resolve to on PATH.
#
# This is where probe 7 shipped BLIND, found by main against 93f2ca9. It resolved
# `command -v 5dive 2>/dev/null || echo "$0"` — and `command -v` wins whenever 5dive
# is installed, which is every agent's box. So a mutated worktree bundle ran its
# scorecard probe against the HEALTHY INSTALLED CLI: `./5dive proof scorecard` printed
# 0.42 for all seven metrics while `./5dive selfcheck` reported ok, rc 0, and its own
# message claimed "6 degraded to NO DATA". It graded a different artifact than the one
# it lives in and could not tell — the [[worktree is not the commit]] error inverted,
# and invisible in CI precisely because CI has no installed 5dive so `$0` won there.
#
# Order is running-bundle first, PATH last, and every candidate must actually BE a
# 5dive bundle (a sourced `src/cmd_selfcheck.sh` under a test harness would otherwise
# resolve `$0` to the harness itself). Returns 1 rather than guessing.
_sc_self() {
  local c
  for c in "${BASH_SOURCE[0]:-}" "$0" "$(command -v 5dive 2>/dev/null)"; do
    [[ -n "$c" && -x "$c" && -f "$c" ]] || continue
    grep -qm1 '^readonly FIVE_VERSION=' "$c" 2>/dev/null || continue
    readlink -f "$c" 2>/dev/null || printf '%s' "$c"
    return 0
  done
  return 1
}

# --- probe 1: gate delivery ---------------------------------------------------
# DIVE-1968's assertion loop, closed. The EFFECT of filing a gate is a DELIVERY ROW,
# and task_need_notify's wrapper promises one for every exit — including exits nobody
# has written yet, which is the actual failure mode (all four exits that existed were
# written intending to record something, and the hole appeared anyway).
#
# Both shapes are asserted, because collapsing them trades a missing row for a WRONG
# one: a silent delivery must synthesise an `error` row and downgrade rc 0 -> 3, while
# a CONFIRMED-but-unrecorded send must backfill an `ok` row carrying the chat it
# reached. Labelling the second a failure would manufacture error rows for gates that
# did reach their human — re-contaminating the dataset with the opposite bias.
_sc_probe_gate_delivery() {
  declare -F task_need_notify >/dev/null 2>&1 \
    || { _sc_notreached "no-gate-rail" "task_need_notify is not defined in this build"; return; }
  local d; d=$(_sc_tmp) || { _sc_notreached "no-tmpdir" "could not create an isolated state dir"; return; }
  local out; out=$(
    set +e
    STATE_DIR="$d"; TASKS_DIR="$d/tasks"; TASKS_DB="$d/tasks/tasks.db"
    mkdir -p "$TASKS_DIR"
    # Fenced twice: the explicit marker AND a non-prod store (DIVE-1506 allowlist).
    export FIVEDIVE_NO_HUMAN_SEND=1
    FIVEDIVE_GATE_NOTIFY_LOG="$d/gate-notify.log"
    : > "$FIVEDIVE_GATE_NOTIFY_LOG"

    # (a) the notify path returns 0 having recorded NOTHING.
    _task_need_notify_deliver() { return 0; }
    task_need_notify SELFCHECK-GATE-A decision "selfcheck probe" "" >/dev/null 2>&1
    printf 'rc_a=%s\n' "$?"

    # (b) the send was CONFIRMED but the notify path recorded no row of its own.
    _task_need_notify_deliver() { TASK_SEND_DELIVERED=1; TASK_CH_CHAT=424242; return 0; }
    task_need_notify SELFCHECK-GATE-B decision "selfcheck probe" "" >/dev/null 2>&1
    printf 'rc_b=%s\n' "$?"
    printf -- '--LOG--\n'
    cat "$FIVEDIVE_GATE_NOTIFY_LOG" 2>/dev/null
  )
  rm -rf "$d"
  local rc_a rc_b log
  rc_a=$(sed -n 's/^rc_a=//p' <<<"$out" | head -1)
  rc_b=$(sed -n 's/^rc_b=//p' <<<"$out" | head -1)
  log=$(sed -n '/^--LOG--$/,$p' <<<"$out")

  local -a bad=()
  [[ "$rc_a" == "3" ]] || bad+=("a gate whose delivery recorded nothing returned rc=${rc_a:-?}, not 3 (filed unnotified) — it reported as pinged")
  grep -q 'result=error' <<<"$log" && grep -q 'SELFCHECK-GATE-A' <<<"$log" \
    || bad+=("no error row was written for the unrecorded delivery — the gate stays invisible to the audit")
  [[ "$rc_b" == "0" ]] || bad+=("a confirmed send returned rc=${rc_b:-?} — a delivered gate was reported as failed")
  grep -q 'result=ok' <<<"$log" && grep -q 'SELFCHECK-GATE-B' <<<"$log" \
    || bad+=("no ok row was backfilled for the confirmed-but-unrecorded send")
  grep -q 'chat=424242' <<<"$log" \
    || bad+=("the backfilled row does not carry the channel the gate reached — delivery is unattributable")

  if (( ${#bad[@]} )); then
    _sc_fail "$(printf '%s; ' "${bad[@]}")"
  else
    _sc_pass "both delivery shapes recorded a row: silent path -> error row + rc 3, confirmed path -> ok row on chat 424242"
  fi
}

# --- probes 2+3: the audit rail, measured TWICE -------------------------------
# DIVE-1989 was invisible for as long as it was measured once. Nine sub-events were
# gated on `[[ $EUID -eq 0 ]]`; the same command as agent-dev wrote 0 rows and under
# sudo wrote 1, so "absent from the audit log" stopped meaning "did not happen" —
# aimed at our own evidence base. One measurement, from either side, sees nothing
# wrong. So root and non-root are two SEPARATE probes over one corpus, and each is
# honestly NOT-REACHED from the other side. The union across a root job and an agent
# job is what covers them; neither run alone can, and that is stated rather than
# papered over.
_sc_audit_leg() {
  local role="$1"
  local d; d=$(_sc_tmp) || { _sc_notreached "no-tmpdir" "could not create an isolated audit dir"; return; }
  command -v jq >/dev/null 2>&1 || { rm -rf "$d"; _sc_notreached "no-jq" "audit_log builds its row with jq, which is not installed"; return; }
  local out; out=$(
    set +e
    AUDIT_LOG="$d/log/agent-audit.log"
    mkdir -p "$d/log/notify"       # _audit_note_drop writes ${AUDIT_LOG%/*}/notify/
    : > "$AUDIT_LOG"
    audit_log "selfcheck probe" ok 0 -- "probe=audit-$role" >/dev/null 2>&1
    printf 'rows=%s\n' "$(grep -c 'selfcheck probe' "$AUDIT_LOG" 2>/dev/null || echo 0)"

    # The other half: when the append CANNOT happen, a marker must survive. A drop
    # that leaves nothing anywhere is what made DIVE-1988 unresolvable — a dropped
    # row and an action that never happened look identical, and no amount of
    # re-reading the log can tell them apart.
    #
    # `sudo` is shadowed by a function so the privileged fallback can never reach the
    # REAL /var/log/5dive audit log from inside a self-test. That is the point of the
    # isolation, not a convenience: a prover that writes fixture rows into the
    # evidence base is building the next mis-diagnosis (DIVE-2010).
    sudo() { return 1; }
    chmod 0444 "$AUDIT_LOG" 2>/dev/null
    if [[ $EUID -eq 0 ]]; then
      # root can append to a 0444 file, so the unwritable case is UNREACHABLE here.
      printf 'drops=skip\n'
    else
      audit_log "selfcheck drop probe" ok 0 -- "probe=audit-$role" >/dev/null 2>&1
      printf 'drops=%s\n' "$(grep -c 'selfcheck drop probe' "$d/log/notify/audit-drops.log" 2>/dev/null || echo 0)"
    fi
  )
  rm -rf "$d"
  local rows drops
  rows=$(sed -n 's/^rows=//p' <<<"$out" | head -1)
  drops=$(sed -n 's/^drops=//p' <<<"$out" | head -1)
  local -a bad=()
  [[ "${rows:-0}" -ge 1 ]] 2>/dev/null \
    || bad+=("an audit_log call as $role wrote NO row — an action by this actor class leaves no trace")
  if [[ "$drops" != "skip" ]]; then
    [[ "${drops:-0}" -ge 1 ]] 2>/dev/null \
      || bad+=("an audit append that could not be written left NO drop marker — a lost row is indistinguishable from an action that never happened")
  fi
  if (( ${#bad[@]} )); then
    _sc_fail "$(printf '%s; ' "${bad[@]}")"
  elif [[ "$drops" == "skip" ]]; then
    _sc_pass "an audit row landed for a $role action (the unwritable-log half is not reachable as root, and is covered by the audit-nonroot probe)"
  else
    _sc_pass "an audit row landed for a $role action, and a blocked append left a drop marker"
  fi
}

_sc_probe_audit_root() {
  [[ $EUID -eq 0 ]] \
    || { _sc_notreached "not-root" "this run is uid $EUID; the privileged half of the audit rail cannot be measured from here"; return; }
  _sc_audit_leg root
}

_sc_probe_audit_nonroot() {
  [[ $EUID -ne 0 ]] \
    || { _sc_notreached "running-as-root" "this run is root; the unprivileged half of the audit rail cannot be measured from here (it is the half DIVE-1989 hid in)"; return; }
  _sc_audit_leg nonroot
}

# --- probe 4: harness verdicts ------------------------------------------------
# DIVE-2013 + DIVE-2018. Static analysis cannot close this (three instruments were
# measured, all agreed, none was sound), so the probe is EMPIRICAL: it injects a
# failure into a harness and demands the harness reports it.
#
# The full sweep is ~150 harnesses x (clean run + mutated run) and does not belong in
# an interactive verb, so the default is a NAMED sample and the sample is PRINTED —
# never a silent cap. heartbeat_gate_shipped_unit.sh is in it by name because it is
# the harness that actually shipped unwired for three releases. `--full` runs the
# corpus; CI runs `--full` and unions the reports.
SELFCHECK_HARNESS_SAMPLE="heartbeat_gate_shipped_unit.sh,gate_delivery_assertion_unit.sh,audit_nonroot_unit.sh"

# --full costs ~10min (164 harnesses, --assume-clean, measured on an idle box; double
# bare). That cost is inherent and DOCUMENTED rather than discovered by whoever runs it
# first — but the silence was not inherent: it streams per-harness output to stderr as
# it goes, because a 15-minute job writing zero bytes is indistinguishable from a hang
# and CI would have to guess. Slow is a budget; silent is a defect.
#
# The first figure published here was ~70min, extrapolated from a per-harness rate
# sampled while a mutation e2e and CI polling were competing for the same box. It was
# 7x wrong and it was already being quoted back as guidance for CI timeouts. A
# measurement taken under unrecorded load is a guess wearing a number's clothes —
# re-measure on an idle box before publishing a budget.

_sc_probe_harness_verdicts() {
  local root="${SELFCHECK_REPO_ROOT:-}"
  [[ -n "$root" ]] || root=$(_sc_repo_root)
  [[ -n "$root" && -r "$root/tests/meta/harness-verdict-probe.sh" ]] \
    || { _sc_notreached "no-test-corpus" "no source checkout with tests/meta/harness-verdict-probe.sh is reachable from here (expected on an installed host; the pristine CI job reaches it)"; return; }
  local only="" scope="sample"
  if (( SELFCHECK_FULL )); then scope="full"; else only="--only=$SELFCHECK_HARNESS_SAMPLE"; fi
  (( SELFCHECK_ASSUME_CLEAN )) && only="$only --assume-clean"
  local out rc logf
  logf=$(mktemp "${TMPDIR:-/tmp}/5dive-hvp.XXXXXX") || { _sc_error "could not stage the harness probe log"; return; }
  if (( SELFCHECK_FULL )); then
    _sc_note "    mutating every harness in tests/*.sh — this is minutes, not seconds; live output follows"
    (( SELFCHECK_ASSUME_CLEAN )) || _sc_note "    (no --assume-clean: each harness runs twice, clean then mutated)"
  fi
  # tee to stderr in --full so the caller sees per-harness progress instead of a
  # silent multi-minute block. rc comes from PIPESTATUS, never $? through a pipe.
  ( cd "$root" && bash tests/meta/harness-verdict-probe.sh $only 2>&1 ) \
    | { if (( SELFCHECK_FULL )); then tee "$logf" >&2; else cat > "$logf"; fi; }
  rc=${PIPESTATUS[0]}
  out=$(cat "$logf"); rm -f "$logf"
  local corpus
  corpus=$(grep -oE '[0-9]+ wired' <<<"$out" | head -1)
  if (( rc != 0 )); then
    _sc_fail "harness-verdict-probe ($scope) exited $rc: $(grep -iE 'UNWIRED|UNPROBEABLE' <<<"$out" | head -3 | tr '\n' ' ')"
  else
    _sc_pass "mutation probe green over the $scope corpus [$( ((SELFCHECK_FULL)) && echo 'tests/*.sh' || echo "$SELFCHECK_HARNESS_SAMPLE")]${corpus:+ — $corpus}"
  fi
}

# --- probe 5: bundle integrity ------------------------------------------------
# DIVE-1977/1999. install.sh fetches the bundle and 5dive.sha256 as two requests to
# raw.githubusercontent, which serves them from independent cache generations — so a
# release can hand a box a NEW bundle and an OLD checksum (or the reverse) and the
# integrity check either fails a good install or passes a mismatched one. The EFFECT
# to assert is local and total: the tracked checksum is about the tracked bundle, and
# the tracked bundle is what src/ builds. Either half alone is satisfiable by a stale
# artifact.
_sc_repo_root() {
  local d="${PWD}"
  while [[ "$d" != "/" && -n "$d" ]]; do
    [[ -r "$d/build.sh" && -d "$d/src" && -r "$d/5dive.sha256" ]] && { printf '%s' "$d"; return 0; }
    d=$(dirname "$d")
  done
  local c
  for c in /home/claude/projects/5dive/5dive-cli "$HOME/5dive-cli"; do
    [[ -r "$c/build.sh" && -r "$c/5dive.sha256" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

_sc_probe_bundle_integrity() {
  command -v sha256sum >/dev/null 2>&1 \
    || { _sc_notreached "no-sha256sum" "sha256sum is not installed, so no checksum can be recomputed"; return; }
  local root="${SELFCHECK_REPO_ROOT:-}"
  [[ -n "$root" ]] || root=$(_sc_repo_root)
  [[ -n "$root" && -r "$root/5dive" && -r "$root/5dive.sha256" ]] \
    || { _sc_notreached "no-bundle-checkout" "no source checkout carrying both ./5dive and ./5dive.sha256 is reachable from here (expected on an installed host)"; return; }

  local want got
  want=$(tr -d '[:space:]' < "$root/5dive.sha256" | grep -oE '^[0-9a-f]{64}' || true)
  got=$(sha256sum "$root/5dive" | awk '{print $1}')
  local -a bad=()
  [[ -n "$want" ]] || bad+=("5dive.sha256 holds no 64-hex digest — install.sh would skip the integrity check entirely")
  [[ -n "$want" && "$want" == "$got" ]] \
    || bad+=("tracked checksum $want does not describe the tracked bundle $got — install and self-update would serve a bundle and a checksum from two different generations")

  # The other half: the bundle IS what src/ builds. A matching checksum over a stale
  # bundle is a self-consistent lie — the pair agrees and neither is the code.
  local tmpb; tmpb=$(mktemp "${TMPDIR:-/tmp}/5dive-bundle.XXXXXX" 2>/dev/null)
  if [[ -n "$tmpb" ]] && (cd "$root" && BUILD_OUT="$tmpb" bash build.sh >/dev/null 2>&1); then
    cmp -s "$tmpb" "$root/5dive" \
      || bad+=("./5dive is not what src/ builds — the bundle and the commit it claims are different code")
  else
    bad+=("build.sh could not be run, so the bundle could not be shown to match src/")
  fi
  [[ -n "$tmpb" ]] && rm -f "$tmpb"

  if (( ${#bad[@]} )); then _sc_fail "$(printf '%s; ' "${bad[@]}")"
  else _sc_pass "bundle, tracked checksum and src/ all agree (${got:0:12}…)"; fi
}

# --- probe 6: snapshot rails --------------------------------------------------
# DIVE-1991/1994/1995. crontab-snapshot ran daily for 22 days, logged Permission
# denied, and exited 0 having saved nothing. Two things must hold and they are
# independent: what is committed must MATCH the live crontabs (ground truth, not the
# script's own report), and a run that saved nothing must exit non-zero.
_sc_probe_snapshot_rails() {
  local snap="${SELFCHECK_SNAPSHOT_SH:-/home/claude/projects/5dive/ops/bin/crontab-snapshot.sh}"
  [[ -r "$snap" ]] \
    || { _sc_notreached "no-snapshot-script" "crontab-snapshot.sh is not present at $snap (it lives in the ops repo, absent on a pristine runner)"; return; }
  local repo; repo=$(sed -n 's/^REPO="\(.*\)"$/\1/p' "$snap" | head -1)
  [[ -n "$repo" && -d "$repo/crontabs" ]] \
    || { _sc_notreached "no-snapshot-repo" "the snapshot script names REPO=${repo:-?}, which has no crontabs/ dir here"; return; }

  local -a bad=() checked=()
  local u live committed
  for u in root claude $(ls /home 2>/dev/null | grep -E '^agent-' || true); do
    id "$u" >/dev/null 2>&1 || continue
    live=$(sudo -n crontab -l -u "$u" 2>/dev/null) || continue
    [[ -n "$live" ]] || continue
    checked+=("$u")
    committed="$repo/crontabs/$u.crontab"
    if [[ ! -s "$committed" ]]; then
      bad+=("$u has a live crontab and NO committed snapshot — a wipe would have nothing to restore from")
    elif ! diff -q <(printf '%s\n' "$live") "$committed" >/dev/null 2>&1; then
      bad+=("$u's committed snapshot differs from its live crontab — the rail reports saved and did not save this")
    fi
  done
  (( ${#checked[@]} )) \
    || { _sc_notreached "no-readable-crontabs" "no live crontab was readable from here (needs NOPASSWD 'sudo crontab -l -u'), so committed-vs-live cannot be compared"; return; }

  # A snapshot that saves nothing must exit non-zero. Run the REAL script against a
  # throwaway REPO with a `sudo` that yields no crontabs. The copy differs from the
  # original in exactly ONE line and that is ASSERTED — a probe free to rewrite the
  # script under test can prove anything.
  local d; d=$(_sc_tmp)
  if [[ -n "$d" ]]; then
    mkdir -p "$d/repo/crontabs" "$d/bin"
    sed "s|^REPO=\".*\"$|REPO=\"$d/repo\"|" "$snap" > "$d/snap.sh"
    local difflines; difflines=$(diff "$snap" "$d/snap.sh" | grep -c '^[<>]' || true)
    printf '#!/bin/sh\nexit 1\n' > "$d/bin/sudo"; chmod +x "$d/bin/sudo"
    printf '#!/bin/sh\nexit 0\n' > "$d/bin/git";  chmod +x "$d/bin/git"
    if [[ "$difflines" != "2" ]]; then
      bad+=("could not isolate the snapshot script by its REPO constant alone (the copy differs in $difflines lines) — refusing to grade a script this probe rewrote")
    else
      ( cd "$d" && PATH="$d/bin:$PATH" bash "$d/snap.sh" >/dev/null 2>&1 )
      local src=$?
      (( src != 0 )) \
        || bad+=("a snapshot run that saved NOTHING exited 0 — the 22-day silent failure (DIVE-1991) is live again")
    fi
    rm -rf "$d"
  fi

  if (( ${#bad[@]} )); then _sc_fail "$(printf '%s; ' "${bad[@]}")"
  else _sc_pass "committed snapshots match the live crontabs for ${checked[*]}, and a save-nothing run exits non-zero"; fi
}

# --- probe 7: scorecard honesty -----------------------------------------------
# DIVE-1929/1937/1923. A metric with no source must render NO DATA naming what was
# missed; the failure being guarded is a partial read rendering as a NUMBER, which is
# unfalsifiable downstream — the published autonomy badge is computed from these rows.
# Asserted against an EMPTY isolated store: with nothing to read, EVERY dimension must
# be NO DATA. A number here is a number invented from no input.
_sc_probe_scorecard_honesty() {
  local self; self=$(_sc_self) \
    || { _sc_notreached "no-bundle-under-test" "could not identify the running 5dive bundle to drive the scorecard"; return; }
  command -v python3 >/dev/null 2>&1 \
    || { _sc_notreached "no-python3" "the scorecard is computed in python3, which is not installed"; return; }
  command -v sqlite3 >/dev/null 2>&1 \
    || { _sc_notreached "no-sqlite3" "an isolated empty task store needs sqlite3"; return; }
  local d; d=$(_sc_tmp) || { _sc_notreached "no-tmpdir" "could not create an isolated state dir"; return; }
  mkdir -p "$d/tasks"
  local out rc
  out=$(STATE_DIR="$d" TASKS_DB="$d/tasks/tasks.db" FIVEDIVE_NO_HUMAN_SEND=1 \
        "$self" proof scorecard --7d 2>&1); rc=$?
  rm -rf "$d"
  # NOT "every row must be NO DATA". `policy-blocked action attempts  0 (across 11
  # instrumented policy sites)` is an HONEST zero: its source is the instrumented
  # call sites, it exists, and it holds nothing. Demanding NO DATA there would be a
  # false accusation, which DIVE-2018 is explicit is worse than a gap. The invariant
  # is narrower and it is the one DIVE-1929 actually names:
  #
  #   every metric row either says NO DATA AND NAMES WHAT WAS MISSED, or carries a
  #   number AND DECLARES ITS COVERAGE.
  #
  # A bare unqualified number is the defect — that is the shape a partial read takes
  # when it renders as a result, and the published badge is computed from these rows.
  local -a rows=(); local -a bare=(); local -a mute=()
  mapfile -t rows < <(grep -E '^  [^ ].*[0-9NO]' <<<"$out" | grep -v '^  no money figure')
  # A scorecard that never rendered a row was not measured — it is NOT a scorecard
  # caught lying. Distinguishing the two is this verb's whole thesis, so it has to
  # hold when the subject is the verb's own probe: an environment where the
  # scorecard cannot be computed at all (no digest source on a pristine runner) is
  # NOT-REACHED, and the union is what stops that from being free.
  if (( ${#rows[@]} == 0 )); then
    _sc_notreached "scorecard-uncomputable" "proof scorecard rendered no metric rows here (rc=$rc): $(head -2 <<<"$out" | tr '\n' ' ')"
    return
  fi
  local r
  for r in "${rows[@]}"; do
    if grep -q 'NO DATA' <<<"$r"; then
      # "NO DATA" alone is a shrug. It has to say what was missed.
      grep -qE 'NO DATA[^A-Za-z0-9]+[A-Za-z]' <<<"$r" || mute+=("$r")
    else
      # A number with no denominator/coverage/window qualifier beside it.
      grep -qE '\(.+\)|/|%|of ' <<<"$r" || bare+=("$r")
    fi
  done
  local nodata; nodata=$(grep -c 'NO DATA' <<<"$out" || true)

  local -a bad=()
  (( ${#rows[@]} >= 5 )) || bad+=("the scorecard rendered only ${#rows[@]} metric rows — too few to tell an honest read from a silent one")
  # Non-vacuity: over a store with nothing in it, the store-derived dimensions MUST
  # degrade. A scorecard that answers everything here is inventing input.
  (( nodata >= 4 )) || bad+=("only $nodata NO DATA row(s) over an EMPTY store — dimensions with no input are rendering as results")
  (( ${#mute[@]} == 0 )) || bad+=("${#mute[@]} NO DATA row(s) do not name what was missed: $(printf '%s ' "${mute[@]}")")
  (( ${#bare[@]} == 0 )) || bad+=("${#bare[@]} row(s) render a bare number with no coverage declared: $(printf '%s ' "${bare[@]}")")

  # Name the artifact that was graded. A probe that shells out has to say WHAT it
  # ran, or misgrading the wrong binary stays invisible in its own pass message.
  if (( ${#bad[@]} )); then _sc_fail "$(printf '%s; ' "${bad[@]}") [graded $self]"
  else _sc_pass "over an empty store ${#rows[@]} metric rows: $nodata degraded to NO DATA and each names what was missed; every number declares its coverage [graded $self]"; fi
}

_sc_dispatch() {
  case "$1" in
    gate-delivery)     _sc_probe_gate_delivery ;;
    audit-root)        _sc_probe_audit_root ;;
    audit-nonroot)     _sc_probe_audit_nonroot ;;
    harness-verdicts)  _sc_probe_harness_verdicts ;;
    bundle-integrity)  _sc_probe_bundle_integrity ;;
    snapshot-rails)    _sc_probe_snapshot_rails ;;
    scorecard-honesty) _sc_probe_scorecard_honesty ;;
    *)                 _sc_error "unknown probe: $1" ;;
  esac
}

cmd_selfcheck() {
  local json="${JSON_MODE:-0}" only="" report="" label="" strict=0 allow=""
  SELFCHECK_FULL=0; SELFCHECK_ASSUME_CLEAN=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)     json=1 ;;
      --only=*)   only="${1#*=}" ;;
      # Probes a DEPLOYMENT structurally cannot reach — not ones this run happened
      # to skip. GitHub CI has no ops repo, so snapshot-rails can never be reached
      # there no matter how many jobs run. Declared BY THE PRODUCER and carried in
      # the report, never restated in the union: two allowlists in two places are
      # one contract with two authors, and when they drift the consumer refuses a
      # state only the producer can mint (DIVE-2004). A NEW never-reached probe
      # still reds, which is the property that matters.
      --allow=*)  allow="${1#*=}" ;;
      --full)     SELFCHECK_FULL=1 ;;
      # The caller asserts the suite just ran green IN THIS ENVIRONMENT, so the
      # harness probe can skip its own clean run and only measure the mutation —
      # roughly halving --full. Sound only when that is actually true, which is why
      # it is opt-in and never the default: CI passes it because the `test` job it
      # depends on just established the baseline.
      --assume-clean) SELFCHECK_ASSUME_CLEAN=1 ;;
      --report=*) report="${1#*=}" ;;
      --label=*)  label="${1#*=}" ;;
      # For the union job: treat ANY not-reached as a failure. Off by default,
      # because a skip in one environment is not an accusation — the union is what
      # turns "not reached anywhere" into one.
      --strict)   strict=1 ;;
      --list)     printf '%s\n' "${SELFCHECK_PROBES[@]}"; return 0 ;;
      -h|--help)  _sc_usage; return 0 ;;
      *) fail "$E_USAGE" "selfcheck: unknown arg: $1" ;;
    esac
    shift
  done
  [[ -n "$label" ]] || label="$(hostname -s 2>/dev/null || echo host):uid$EUID"

  local -a run=()
  if [[ -n "$only" ]]; then
    local p
    IFS=',' read -r -a run <<< "$only"
    for p in "${run[@]}"; do
      printf '%s\n' "${SELFCHECK_PROBES[@]}" | grep -qx "$p" \
        || fail "$E_USAGE" "selfcheck: unknown probe '$p' (see: 5dive selfcheck --list)"
    done
  else
    run=("${SELFCHECK_PROBES[@]}")
  fi

  local -a v_id=() v_verdict=() v_reason=() v_detail=()
  local p line i=0 n=${#run[@]}
  for p in "${run[@]}"; do
    i=$((i+1))
    _sc_note "[$i/$n] $p — $(_sc_title "$p") …"
    # stderr is NOT swallowed here: it is how a probe streams progress out of a long
    # sweep. Only the LAST stdout line is the verdict, so a chatty probe cannot
    # corrupt it.
    line=$(_sc_dispatch "$p" | tail -1)
    [[ -n "$line" ]] || line="error||probe produced no verdict line"
    v_id+=("$p")
    v_verdict+=("${line%%|*}")
    local rest="${line#*|}"
    v_reason+=("${rest%%|*}")
    v_detail+=("${rest#*|}")
    _sc_note "[$i/$n] $p → ${line%%|*}"
  done

  local i fails=0 unexplained=0 notreached=0 passes=0 errors=0
  for i in "${!v_id[@]}"; do
    case "${v_verdict[$i]}" in
      pass) passes=$((passes+1)) ;;
      fail) fails=$((fails+1)) ;;
      error) errors=$((errors+1)) ;;
      not-reached)
        notreached=$((notreached+1))
        # A NOT-REACHED with no reason is the silence this verb removes. It is not
        # excusable and it is not a pass.
        [[ -n "${v_reason[$i]}" ]] || unexplained=$((unexplained+1))
        ;;
    esac
  done

  if [[ -n "$report" ]]; then
    { printf '# selfcheck report\n# probes=%s\n# allow=%s\n# label=%s\n' \
        "$(IFS=,; echo "${SELFCHECK_PROBES[*]}")" "$allow" "$label"
      for i in "${!v_id[@]}"; do
        printf '%s\t%s\t%s\n' "${v_verdict[$i]}" "${v_id[$i]}" "${v_reason[$i]}"
      done
    } > "$report" || fail "$E_GENERIC" "selfcheck: could not write report to $report"
  fi

  if [[ "$json" == "1" ]]; then
    local jarr=""
    for i in "${!v_id[@]}"; do
      jarr+=$(jq -cn --arg p "${v_id[$i]}" --arg v "${v_verdict[$i]}" \
                     --arg r "${v_reason[$i]}" --arg d "${v_detail[$i]}" \
                     --arg t "$(_sc_title "${v_id[$i]}")" \
                '{probe:$p, verdict:$v, reason:(if $r=="" then null else $r end), asserts:$t, detail:$d}')
      jarr+=$'\n'
    done
    printf '%s' "$jarr" | jq -s --arg label "$label" \
      --argjson fails "$fails" --argjson notreached "$notreached" \
      --argjson unexplained "$unexplained" --argjson passes "$passes" --argjson errors "$errors" \
      '{label:$label, probes:., summary:{pass:$passes, fail:$fails, "not-reached":$notreached,
        unexplained_not_reached:$unexplained, error:$errors}}'
  else
    printf '5dive selfcheck — do the rails ACT? (label=%s)\n\n' "$label"
    for i in "${!v_id[@]}"; do
      local mark
      case "${v_verdict[$i]}" in
        pass) mark="  ok        " ;;
        fail) mark="  FAIL      " ;;
        not-reached) mark="  NOT-REACHED" ;;
        *) mark="  ERROR     " ;;
      esac
      printf '%s %-18s %s\n' "$mark" "${v_id[$i]}" "$(_sc_title "${v_id[$i]}")"
      if [[ "${v_verdict[$i]}" == "not-reached" ]]; then
        printf '                                 reason: %s — %s\n' "${v_reason[$i]:-NONE GIVEN}" "${v_detail[$i]}"
      else
        printf '                                 %s\n' "${v_detail[$i]}"
      fi
    done
    printf '\n  %d pass, %d fail, %d not-reached (%d without a reason), %d error\n' \
      "$passes" "$fails" "$notreached" "$unexplained" "$errors"
    if (( notreached )); then
      printf '  NOT-REACHED is not a pass. It is excusable in ONE environment and in none of them:\n'
      printf '  run with --report=<file> in each job and union them (tests/meta/selfcheck-union.sh).\n'
    fi
  fi

  (( fails == 0 && errors == 0 && unexplained == 0 )) || return "$E_GENERIC"
  (( strict == 0 || notreached == 0 )) || return "$E_GENERIC"
  return 0
}

_sc_usage() {
  cat <<'USAGE'
5dive selfcheck [--json] [--only=<probe,...>] [--full] [--strict]
                [--report=<file>] [--label=<env>] [--list]

Runs each critical rail FOR REAL in an isolated state dir and asserts the EFFECT it
is supposed to have, not the string it printed.

Every probe reports pass | fail | NOT-REACHED. NOT-REACHED is a first-class third
state and is NEVER folded into pass — a probe whose precondition is absent has not
been shown to work. A NOT-REACHED with no reason exits non-zero.

  --full      run the harness mutation sweep over the WHOLE corpus instead of the
              named sample. MEASURED on an idle control plane: 10m21s wall for 164
              harnesses with --assume-clean (~3.8s each), roughly double bare, since
              each harness runs twice (clean, then mutated). Budget ~15min / ~30min
              bare and give it its own CI timeout; it does not belong on an
              interactive path. Per-harness progress streams to stderr throughout —
              it is slow, never silent.
  --assume-clean
              the suite just ran green IN THIS ENVIRONMENT, so skip the harness
              probe's own clean run. Halves --full. Sound only if that is true.
  --strict    treat any NOT-REACHED as a failure (for a single known-complete env)
  --allow=    probes this DEPLOYMENT structurally cannot reach, excused in the
              union (recorded in the report, never restated by the union)
  --report=   write a machine-readable verdict per probe, for the union check
  --label=    name this environment in the report (default: host:uid)
  --list      print the probe corpus, one per line

exit 0  every probe passed, or was NOT-REACHED with a declared reason
exit 1  any fail, any probe error, or any NOT-REACHED with no reason given

NOT-REACHED is excusable in ONE environment, never in all of them. Run selfcheck in
both the pristine and installed-host jobs with --report=, then:

  tests/meta/selfcheck-union.sh pristine.txt installed.txt

which fails if any probe reached a verdict NOWHERE.
USAGE
}
