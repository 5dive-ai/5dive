
# -------- self-update (fetch installer + --upgrade, then restart agents) --------
#
# `5dive self-update` is the on-demand counterpart to the managed nightly
# soft-update, for OSS self-hosted boxes that have no scheduler of their own.
# It does two things:
#
#   1. Fetches install.sh and runs `--upgrade` — refreshes the 5dive CLI,
#      5dive-agent-start, hooks, skills, the systemd template, and the plugins
#      (via 5dive-refresh-plugins.sh). This reuses the same installer that
#      `uninstall` shells out to, so there's a single source of truth for
#      "what gets updated" rather than a second copy that drifts.
#
#   2. Restarts the agents whose IN-MEMORY payload the upgrade actually
#      changed. A live agent keeps its plugins, its skills and its CLAUDE.md in
#      memory until it restarts — that's the usual reason a plugin "still shows
#      the old version" after an upgrade — so those, and only those, are worth
#      a bounce.
#
# The agent AI CLIs themselves (claude/codex/grok/antigravity) self-update via
# their own vendor autoupdaters. Managed boxes have their own scheduler so they
# don't need this, but running it there is harmless — `--upgrade` and the
# restart loop are both idempotent.
#
# DIVE-3172 — THE CLI VERSION IS NOT A REASON TO RESTART ANYONE. This loop used
# to bounce EVERY running agent unconditionally, on a nightly schedule, and a
# `systemctl restart` mid-turn drops the agent's session and its in-flight work
# with no record: a killed turn is indistinguishable afterwards from an agent
# that simply went quiet. lodar reported it as "our nightly updates kills some
# active agents mid tasks" (2026-08-10).
#
# The unconditional restart was buying nothing on most nights. MEASURED on this
# host 2026-08-10: /usr/local/bin/5dive was replaced 0.19.10 -> 0.19.14 with
# ZERO restarts and every running agent reported the new version on its next
# command (`sudo -u agent-olivia 5dive --version` -> 0.19.14 immediately). The
# CLI is exec'd per invocation, not held open, so a binary swap propagates on
# its own. Only what the agent PROCESS holds across its lifetime needs a bounce.
# On a CLI-only update the correct number of restarts is zero.

# json_array <items...> — emit a compact JSON string array, "[]" when empty.
# Guards the empty-array case (printf with no args would otherwise emit a stray
# empty element).
json_array() {
  if [[ $# -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "$@" | jq -R . | jq -cs .
  fi
}

# >>> DIVE-3172 agent payload fingerprint
#     (tests/self_update_restart_predicate_unit.sh extracts this block VERBATIM
#      between these markers and runs the shipped bytes — keep them.)
#
# _agent_home <unit-name> — the home directory whose payload that unit loads.
# Resolved from passwd rather than assembled as a string: the fleet's agents are
# `agent-<name>`, but the root seat runs as `claude` out of /home/claude, and a
# hardcoded /home/agent-claude would fingerprint a directory that does not exist
# — which reads as "unreadable", which restarts it every night. Falls back to the
# conventional path so a box with no passwd entry still gets the old behaviour.
_agent_home() {
  local n="${1:-}" h=""
  [[ -n "$n" ]] || return 0
  h=$(getent passwd "agent-$n" 2>/dev/null | cut -d: -f6) || h=""
  [[ -n "$h" ]] || h=$(getent passwd "$n" 2>/dev/null | cut -d: -f6) || h=""
  printf '%s\n' "${h:-/home/agent-$n}"
}

# _agent_config_hashable <type> — is this agent type's CONFIG file inside the set
# _agent_payload_fingerprint actually hashes?
#
# Only `claude` is, via the literal ~/.claude/settings.json below. Every other type
# keeps its config somewhere we have NO map to derive (~/.codex/config.toml,
# ~/.grok/config.toml, ~/.pi/agent/settings.json), written ad hoc by the boot path.
#
# This function exists because of what the conditional would otherwise DO to those
# types. Today's unconditional restart picks a config-only change up — loudly and
# wastefully, but correctly. Under a fingerprint that cannot see the file, the agent
# compares EQUAL and is SKIPPED: a change that ships today would stop shipping. That
# is a NEW silent failure introduced by this fix, not a pre-existing gap being
# documented, and it is the same shape as the skills defect one layer down.
#
# So an unmeasurable type is never claimed unchanged. It restarts — the caller's own
# rule ("an absent reading resolves to neither answer") applied per TYPE instead of
# fleet-wide, which preserves today's exact behaviour for precisely the agents we
# cannot measure and keeps the savings for the ones we can. An unknown or empty type
# is unmeasurable too and takes the same branch.
#
# OWED, NOT HERE: a TYPE_CONFIG_FILE map is the real fix and would let these types
# be compared like any other. It means touching every boot path that writes those
# files ad hoc — different change, different risk — so it is on DIVE-3172's body as
# owed rather than bundled into a fix that is otherwise ready.
_agent_config_hashable() {
  case "${1:-}" in
    claude) return 0 ;;
    *)      return 1 ;;
  esac
}

# _agent_restart_needed <before> <after> <type> — 0 when the unit must be bounced.
# The whole skip/restart decision lives here rather than inline in the loop so the
# unit harness grades the SHIPPED bytes of it instead of a restatement that can drift.
_agent_restart_needed() {
  local before="${1:-}" after="${2:-}" type="${3:-}"
  # UNREADABLE IS NOT UNCHANGED. If either side of the comparison is empty we could
  # not observe the payload, so we fall back to the old unconditional behaviour and
  # restart. Skipping on an unknown would convert a permission problem into a fleet
  # that silently never picks up a plugin fix — a much quieter failure than the one
  # this change is fixing. (DIVE-2230's rule: an absent reading resolves to neither
  # answer.)
  [[ -n "$before" && -n "$after" && "$before" == "$after" ]] || return 0
  # NON-DERIVABLE CONFIG TYPES ALWAYS RESTART, DELIBERATELY. See above: equal
  # fingerprints on such a type do not mean the payload held still, only that the
  # part we can hash did.
  _agent_config_hashable "$type" || return 0
  return 1
}

# _agent_payload_fingerprint <agent-home> [lib-dir] — one hash over everything a
# running agent loaded at startup and cannot pick up without a restart. Empty
# output means "could not be read", which is NOT the same as "unchanged" — see
# the caller.
#
# WHAT IS ON THE LIST, AND WHY THE CLI IS NOT.
#   - $LIB_DIR/skills        staged skills, read when the agent session starts
#   - ~/.claude/skills       the agent's own skills, same
#   - ~/.claude/plugins/installed_plugins.json
#                            the plugin VERSION PINS. `5dive-refresh-plugins.sh`
#                            downloads each new version into
#                            ~/.claude/plugins/cache/<mp>/<plugin>/<version>/ and
#                            REPOINTS this manifest, so the manifest moving is
#                            exactly the event a plugin update is. We hash the
#                            manifest and not the cache on purpose: each cached
#                            version is ~29M with its own node_modules, the old
#                            versions linger, and hashing them would cost more
#                            than the restart it is trying to avoid.
#   - ~/.claude/settings.json  hooks, model and provider pins — read at startup
#   - ~/.claude/CLAUDE.md      loaded into context at session start
# The 5dive CLI binary is deliberately absent: it is exec'd per command, so a
# swap needs no restart (measured — see the header).
#
# THE PAYLOAD PATHS ARE DERIVED FROM THE INSTALLER'S OWN MAPS, NEVER RE-LITERALED.
# Skills and the instructions doc do NOT live under ~/.claude for every agent: the
# install dir is resolved PER TYPE from SKILLS_INSTALL_DIR / TYPE_PERSONA_FILE, and
# `5dive-refresh-skills.sh` writes through that same resolution. A hardcoded
# ".claude/skills" therefore watched the wrong directory for every non-claude type.
#
# MEASURED on this fleet 2026-08-10, all 13 running units (`5dive agent skill <a> list`):
#   andy 2 / codex 5 / ocqa 2 skill dirs under .agents/skills and ZERO under
#   .claude/skills — 100% invisible; creative 15/7 and marketing 3/8 — partially
#   invisible. 5 of 13 agents, 27 skill dirs. Those agents compared EQUAL forever and
#   were SKIPPED every night, silently: the quiet failure the caller's comment below
#   explicitly refuses. Note creative and marketing are type=claude and STILL have
#   .agents/skills dirs, so this is NOT a clean type split and must not be "fixed" by
#   special-casing non-claude types.
#
# WHY DERIVED AND NOT ONE MORE LITERAL. A path the fingerprint does not know about is
# INDISTINGUISHABLE from a payload that did not change, so adding ".agents/skills" as a
# second literal would fix today's three types and fail identically and silently on the
# next type someone maps. Iterating the maps means the predicate cannot fall behind the
# installer by construction: adding a type to SKILLS_INSTALL_DIR extends this hash for
# free. The ".claude/*" entries stay in the set unconditionally because
# skills_install_dir() falls back to ".claude/skills" for an UNMAPPED type.
#
# SORTED, and that is load-bearing rather than tidy. Bash associative-array iteration
# order is not a contract; if the path list came out in a different order on the second
# snapshot the hash would move on an unchanged payload and restart the whole fleet —
# precisely the regression this change exists to prevent.
#
# STILL LITERAL, DELIBERATELY, AND NOT AN OVERSIGHT: ~/.claude/settings.json and
# ~/.claude/plugins/installed_plugins.json. The plugin manifest is Claude-only (no other
# harness has a plugin system). Per-type CONFIG does have real parallels — ~/.codex/
# config.toml, ~/.grok/config.toml, ~/.pi/agent/settings.json — but unlike skills and the
# persona doc there is NO map to derive them from; they are written ad hoc by the boot
# path. Enumerating them here would recreate exactly the literal-drift defect this
# function just fixed, one layer down, so it is raised as a DECISION (expose a
# TYPE_CONFIG_FILE map vs enumerate) rather than quietly taken. Until that lands, a
# config-only change on a non-claude agent is NOT detected — named so nobody reads this
# fix as wider than it is.
#
# CONTENT, NEVER mtime OR SIZE. `refresh_managed_files()` in install.sh swaps the
# managed files in UNCONDITIONALLY (`mv -f "$_bundle_tmp" ...`) with no
# already-current branch, so the nightly rewrites them every night whether or not
# a byte moved. An mtime predicate would therefore report "changed" on every run
# and restart the whole fleet — today's behaviour wearing a conditional, which is
# worse than today's because it would look fixed. (This is the same trap
# DIVE-2287's freeze observer documents two functions down, for the same file.)
#
# The path is hashed alongside the bytes, so a file APPEARING or being REMOVED
# moves the fingerprint too — a deleted skill is a payload change.
_agent_payload_fingerprint() {
  local home="${1:-}" lib="${2:-${LIB_DIR:-/usr/local/lib/5dive}}"
  [[ -n "$home" ]] || return 0
  command -v sha256sum >/dev/null 2>&1 || return 0
  local p out rel
  # Build the $HOME-relative payload set from the installer's maps. `[@]-` keeps
  # this safe under `set -u` if a map is absent (the unit harness extracts this
  # function on its own), and the .claude entries below mean an empty map still
  # yields the documented fallback set rather than nothing.
  local -a rels=()
  # DIVE-2609: the skills dirs come from `skills_install_dirs_all`, NOT from a second
  # read of SKILLS_INSTALL_DIR. The map has exactly one executable value-read in src/
  # (the resolver in header.sh) and this file used to be a second one — a real
  # regression, caught by tests/skills_install_dir_callers_unit.sh on its first
  # contact with this code. TYPE_PERSONA_FILE has no such contract and is still read
  # directly; `[@]-` keeps that safe under `set -u` when the map is absent.
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && rels+=("$rel")
  done < <(skills_install_dirs_all)
  for rel in "${TYPE_PERSONA_FILE[@]-}"; do
    [[ -n "$rel" ]] && rels+=("$rel")
  done
  rels+=(".claude/skills" ".claude/CLAUDE.md" \
         ".claude/plugins/installed_plugins.json" ".claude/settings.json")
  local -a paths=("$lib/skills")
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && paths+=("$home/$rel")
  done < <(printf '%s\n' "${rels[@]}" | LC_ALL=C sort -u)
  out=$({
    for p in "${paths[@]}"; do
      [[ -e "$p" ]] || continue
      if [[ -d "$p" ]]; then
        # -print0/-z/-0 throughout: a path with a space or newline in it must
        # not split into two hashed entries.
        find "$p" -type f -print0 2>/dev/null | LC_ALL=C sort -z \
          | xargs -0 -r sha256sum 2>/dev/null
      else
        sha256sum "$p" 2>/dev/null
      fi
    done
  } | sha256sum) || return 0
  # An agent home we could read NOTHING from yields the hash of the empty
  # string. Return empty instead: "nothing to hash" and "hashed nothing" must
  # not be the same value, or an unreadable home would compare equal to itself
  # across the upgrade and silently never restart.
  [[ "${out%% *}" == "$(printf '' | sha256sum | awk '{print $1}')" ]] && return 0
  printf '%s\n' "${out%% *}"
}
# <<< DIVE-3172 agent payload fingerprint

# >>> DIVE-3173 deferred restart for a busy agent
#     (tests/self_update_busy_defer_unit.sh extracts this block VERBATIM
#      between these markers and runs the shipped bytes — keep them.)
#
# DIVE-3172 made the nightly restart CONDITIONAL on the payload actually moving,
# which takes CLI-only nights to zero restarts. This block is the belt for the
# nights when the payload genuinely moved and a bounce IS required: those are
# exactly the nights the restart still lands on whoever is mid-task, drops their
# session, and leaves no record distinguishable from an agent that went quiet
# (lodar, 2026-08-10: "our nightly updates kills some active agents mid tasks").
#
# THE PREDICATE IS THE BOARD, NOT THE PANE. "Busy" here means the agent holds a
# row in `in_progress` — a fact with a durable record that survives this process
# exiting, which a pane scrape does not. The pane check is used, but only as a
# second guard at FIRING time (below), never as the thing we remember.
#
# WHY A MARKER FILE AND NOT A CONDITIONAL. Something has to remember the owed
# restart and fire it AFTER self-update has exited — a conditional can only skip.
# The marker is that memory, and every later root pass (`heartbeat tick`, the
# next `self-update`) sweeps it.
#
# WHY THE BOUNDARY IS OBSERVED AND NOT HOOKED. A row leaves `in_progress` from
# ~20 different call sites (`task done/cancel/park/reject/deliver`, the loop
# engine, the heartbeat reaper, the gate answer path). Hooking them is a promise
# to hook the one that gets added next, and a deferral that never fires is a
# WORSE bug than the restart it replaced. So the sweep asks the board the same
# question self-update asked, on every tick, and fires the moment the answer
# flips — the boundary is detected rather than intercepted.
#
# EVERY UNCERTAIN READING DEFERS. An unreadable board, an unreadable stamp, a
# non-idle pane: all hold the restart. The failure that costs work is restarting
# an agent we cannot see; the failure that costs a payload update is bounded by
# the ceiling below and is LOUD.
_pending_restart_dir() {
  printf '%s\n' "${PENDING_RESTART_DIR:-${STATE_DIR:-/var/lib/5dive}/pending-restart}"
}

# How long a marker may sit unfired before every sweep says so out loud. It does
# NOT force the restart when it expires — forcing is precisely the bug this row
# exists to remove, and a row held `in_progress` for a day is an anomaly the
# heartbeat's own reaper owns. The ceiling exists so "deferred forever" cannot be
# silent, which is the only part of it we can honestly fix here.
_PENDING_RESTART_MAX_DEFER_SECS=$((24 * 3600))

# _agent_busy_state <name> -> busy | idle | unknown
# `unknown` is a THIRD value on purpose and is never folded into `idle`: a board
# we could not read must take the same branch as a board that said busy.
_agent_busy_state() {
  local name="${1:-}" n=""
  [[ -n "$name" ]] || { printf 'unknown\n'; return 0; }
  if ! declare -F db >/dev/null 2>&1 || ! declare -F sqlq >/dev/null 2>&1; then
    printf 'unknown\n'; return 0
  fi
  n=$(db "SELECT COUNT(*) FROM tasks WHERE assignee=$(sqlq "$name") AND status='in_progress';" 2>/dev/null) || n=""
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    if (( n > 0 )); then printf 'busy\n'; else printf 'idle\n'; fi
  else
    printf 'unknown\n'
  fi
  return 0
}

_pending_restart_mark() {
  local name="${1:-}" reason="${2:-payload changed}" dir
  [[ -n "$name" ]] || return 1
  dir="$(_pending_restart_dir)"
  mkdir -p "$dir" 2>/dev/null || return 1
  printf 'marked_at=%s\nreason=%s\n' "$(date +%s)" "$reason" > "$dir/$name" 2>/dev/null || return 1
  chmod 0644 "$dir/$name" 2>/dev/null || true
  return 0
}

_pending_restart_clear()  { local n="${1:-}"; [[ -n "$n" ]] && rm -f "$(_pending_restart_dir)/$n" 2>/dev/null; return 0; }
_pending_restart_reason() { local f; f="$(_pending_restart_dir)/${1:-}"; [[ -f "$f" ]] && sed -n 's/^reason=//p' "$f" 2>/dev/null | head -n1; return 0; }

# Echo the marker's epoch. A marker whose stamp is CORRUPT reads as "marked now",
# not as 0: with 0 any unit start looks later than the mark, the decision below
# would read `already-bounced`, and the owed restart would be dropped silently.
# Treating it as now can only cost one extra deferral cycle.
_pending_restart_marked_at() {
  local f v=""
  f="$(_pending_restart_dir)/${1:-}"
  [[ -f "$f" ]] || return 1
  v=$(sed -n 's/^marked_at=\([0-9][0-9]*\)$/\1/p' "$f" 2>/dev/null | head -n1)
  [[ "$v" =~ ^[0-9]+$ ]] || v=$(date +%s)
  printf '%s\n' "$v"
}

# Seconds since the unit last entered `active`, or 0 when unreadable. 0 means
# "no evidence of a restart", which keeps the marker owed.
_unit_active_enter_epoch() {
  local unit="${1:-}" ts=""
  command -v systemctl >/dev/null 2>&1 || { printf '0\n'; return 0; }
  ts=$(systemctl show "$unit" --property=ActiveEnterTimestamp --value 2>/dev/null) || ts=""
  [[ -n "$ts" ]] || { printf '0\n'; return 0; }
  date -d "$ts" +%s 2>/dev/null || printf '0\n'
  return 0
}

# _pending_restart_decide <marked_at> <unit_started_at> <busy> <now> <max_defer>
#   already-bounced | fire | defer | overdue
#
# CLEARED BY OBSERVATION, NOT BY THE FIRING PATH. The marker is satisfied by any
# restart that happened after it was written — an operator bounce, a crash
# restart, a plugin `/restart` — because all of them load the new payload. Firing
# is not the only way the debt gets paid, and a marker that only its own firing
# path could clear would bounce an agent a second time for a payload it already
# has.
_pending_restart_decide() {
  local marked="${1:-0}" started="${2:-0}" busy="${3:-unknown}" now="${4:-0}" maxd="${5:-0}"
  [[ "$marked"  =~ ^[0-9]+$ ]] || marked=0
  [[ "$started" =~ ^[0-9]+$ ]] || started=0
  [[ "$now"     =~ ^[0-9]+$ ]] || now=0
  [[ "$maxd"    =~ ^[0-9]+$ ]] || maxd=0
  if (( marked > 0 && started > marked )); then printf 'already-bounced\n'; return 0; fi
  if [[ "$busy" == "idle" ]]; then printf 'fire\n'; return 0; fi
  if (( maxd > 0 && marked > 0 && now - marked >= maxd )); then printf 'overdue\n'; return 0; fi
  printf 'defer\n'
  return 0
}

_pr_log() {
  if declare -F _hb_log >/dev/null 2>&1; then _hb_log "$*"
  else printf '%s [pending-restart] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; fi
}

# >>> DIVE-4033 an operator-parked agent stays parked
#     (tests/self_update_parked_agent_unit.sh extracts this block VERBATIM
#      between these markers and runs the shipped bytes — keep them.)
#
# It lives INSIDE the DIVE-3173 fence on purpose: `_pending_restart_sweep` calls
# it, and that sweep is graded by extracting the DIVE-3173 block and running it.
# A helper defined outside would be absent from those extracted bytes, so the
# harness would grade a sweep whose parked branch silently could not fire —
# a test of something the box never runs.
#
# `desiredState: stopped` is the operator's recorded intent (`5dive agent stop`
# writes it). Every other consumer honours it — the supervisor, the heartbeat,
# `agent send --wake`, the objective preflight — and the update restart sweep was
# the one path that never asked. DIVE-4033: a customer-facing sales bot parked
# when its project closed was restarted by the 0.26.0 sweep and then ran for
# weeks reported as `active / disabled`. An agent coming back from a park on its
# own is a consent problem, not a wasted seat, which is why this is not a tidy-up.
#
# ABSENT IS NOT STOPPED (DIVE-2318, and the `// "running"` default every other
# reader already uses). An agent never start/stop'd through the CLI carries no
# field at all — the common case — so it restarts, byte for byte as today.
#
# AN UNREADABLE REGISTRY RESTARTS TOO, and that direction is deliberate. The two
# failures are not symmetric: a wrong skip leaves the fleet silently frozen on the
# old payload (DIVE-3173 calls it NEVER FIRES, and DIVE-1095 is a whole row about
# a fix shipping dormant), while a wrong restart is loud and recoverable. So only
# an explicit, parseable `stopped` skips; a missing file, absent jq, or a parse
# failure all read as running.
_agent_is_parked() {
  local name="${1:-}" desired=""
  [[ -n "$name" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [[ -n "${REGISTRY:-}" && -f "$REGISTRY" ]] || return 1
  desired=$(jq -r --arg n "$name" '.agents[$n].desiredState // "running"' "$REGISTRY" 2>/dev/null) || return 1
  [[ "$desired" == "stopped" ]]
}

# The line an operator reads, in both the nightly log and the interactive run.
# It names BOTH exits because either can be the correct one and only a person
# knows which: the stop is real (enforce it) or the stop is stale (clear it).
# "skipped" on its own would read as a decision already taken.
_parked_override_note() {
  local n="${1:-}"
  printf "agent '%s' is RUNNING but the registry says desiredState=stopped — not restarting it, and not stopping it either. The owed restart is REMEMBERED, not dropped. Reconcile: '5dive agent stop %s' if the stop is real, '5dive agent start %s' if the intent is stale — start only flips the registry (systemctl start is a no-op on a live unit), and the next sweep is what bounces it onto the new payload." "$n" "$n" "$n"
}
# <<< DIVE-4033 an operator-parked agent stays parked

# The sweep. Root-only by what it does (systemctl restart); best-effort by
# contract — a failure here must never abort its caller's pass. Counters are
# globals so the caller can put them in its own summary.
_PR_FIRED=0; _PR_DEFERRED=0; _PR_OVERDUE=0; _PR_CLEARED=0; _PR_FAILED=0; _PR_PARKED=0
_pending_restart_sweep() {
  local dir f name marked started busy verdict now unit why
  _PR_FIRED=0; _PR_DEFERRED=0; _PR_OVERDUE=0; _PR_CLEARED=0; _PR_FAILED=0; _PR_PARKED=0
  dir="$(_pending_restart_dir)"
  [[ -d "$dir" ]] || return 0
  now=$(date +%s)
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    name="${f##*/}"
    unit="5dive-agent@${name}.service"
    marked="$(_pending_restart_marked_at "$name")" || continue
    # A unit that is not running has nothing to bounce — it loads the new payload
    # on its next start by construction, so the debt is already paid. Without
    # this an auto-slept agent (DIVE-1858 stops the unit) would hold a marker
    # forever and every sweep would count it as owed.
    if command -v systemctl >/dev/null 2>&1 \
       && ! systemctl is-active --quiet "$unit" 2>/dev/null; then
      _pending_restart_clear "$name"; _PR_CLEARED=$((_PR_CLEARED + 1)); continue
    fi
    # DIVE-4033: the unit IS running, and the registry says this agent was
    # parked. Asked after the is-active guard, not before it: a parked agent
    # whose unit is already down is the state the operator asked for, and
    # shouting about it every sweep would bury the case that is actually wrong.
    #
    # THE MARKER IS HELD, NOT CLEARED (iteration 2). Clearing it read as "both
    # exits load the new payload by construction", and that is false for one of
    # the two exits this branch prints: `5dive agent start` runs `systemctl
    # start`, which is a NO-OP on an already-active unit (cmd_start, and this
    # row's own body measured dev2 surviving one: uptime 4987s -> 4996s, session
    # intact). It only flips desiredState back to "running" — so with the marker
    # gone the agent keeps running the PRE-UPDATE payload with no marker, no
    # counter and no line. That is exactly the silent FREEZES direction this fix
    # exists to avoid, scoped to the one population the row is about.
    #
    # Held, each exit resolves itself on the next sweep with no new machinery:
    #   `5dive agent stop`  -> the unit goes inactive -> the is-active guard
    #                          above clears the marker; the debt is genuinely
    #                          paid, since the next start loads the new payload.
    #   `5dive agent start` -> desiredState=running -> this branch no longer
    #                          fires and the normal decide/fire path bounces it.
    # PARKED is its own counter and is NOT folded into DEFERRED/OVERDUE: it is a
    # debt whose payment is blocked on an operator, not on a task boundary.
    #
    # CONSEQUENCE, stated because it is a real change: a held marker means this
    # line is logged on EVERY sweep until the operator reconciles, where the
    # cleared marker logged it once. That is deliberate — the only agents that
    # reach here are running-but-parked, i.e. the contradiction itself, and a
    # correctly-parked agent (unit down) is already filtered by the guard above,
    # so nothing benign repeats. A one-shot line for a state that persists for
    # weeks is how katya ran for three of them unnoticed.
    if _agent_is_parked "$name"; then
      _PR_PARKED=$((_PR_PARKED + 1))
      _pr_log "[$name] $(_parked_override_note "$name")"
      continue
    fi
    started="$(_unit_active_enter_epoch "$unit")"
    busy="$(_agent_busy_state "$name")"
    verdict="$(_pending_restart_decide "$marked" "$started" "$busy" "$now" "$_PENDING_RESTART_MAX_DEFER_SECS")"
    case "$verdict" in
      already-bounced)
        _pending_restart_clear "$name"; _PR_CLEARED=$((_PR_CLEARED + 1)) ;;
      fire)
        # The board says the row is closed; this asks whether the SESSION is
        # between turns. Leaving the last task is not the same as being done
        # talking about it, and a bounce one second into the closing turn is the
        # same lost work in a smaller window. Any non-idle answer (busy, pane
        # unreadable, blocked on a prompt) defers to the next sweep — the marker
        # survives, so nothing is lost by waiting.
        if declare -F _hb_agent_idle >/dev/null 2>&1 && ! _hb_agent_idle "$name" 0.4; then
          _PR_DEFERRED=$((_PR_DEFERRED + 1))
          continue
        fi
        # Read the reason BEFORE the clear — the log line is the only place the
        # deferral's cause survives, and clearing first would print an empty one.
        why="$(_pending_restart_reason "$name")"
        if systemctl restart "$unit" 2>/dev/null; then
          _pending_restart_clear "$name"; _PR_FIRED=$((_PR_FIRED + 1))
          _pr_log "[$name] task boundary reached — bouncing for the deferred payload update (${why:-payload changed})"
        else
          _PR_FAILED=$((_PR_FAILED + 1))
          _pr_log "[$name] deferred restart failed (marker kept, will retry next sweep)"
        fi ;;
      overdue)
        _PR_OVERDUE=$((_PR_OVERDUE + 1)); _PR_DEFERRED=$((_PR_DEFERRED + 1))
        _pr_log "[$name] restart owed since $(( (now - marked) / 3600 ))h and the agent is STILL not idle — not forcing it; check whether its row is genuinely in flight" ;;
      *)
        _PR_DEFERRED=$((_PR_DEFERRED + 1)) ;;
    esac
  done
  return 0
}
# <<< DIVE-3173 deferred restart for a busy agent

# >>> DIVE-4068 post-install health gate
#     (tests/self_update_health_gate_unit.sh extracts this block VERBATIM
#      between these markers and runs the shipped bytes — keep them.)
#
# 0.26.1 shipped a launcher that could not start any agent (DIVE-4067). The
# update path installed it, then restarted every agent, and every box that took
# the release emptied itself and STAYED empty until a human noticed.
#
# WHAT THE UPDATE PATH ALREADY GRADED, AND WHAT IT DID NOT. install.sh grades
# the ARTIFACT — it fetched, the sha256 matches, `bash -n` parses, the version
# does not go backwards. Every one of those passed on 0.26.1: a self-referencing
# `local` is syntactically valid, so the file that could not start a single agent
# is indistinguishable from a good one by every check the installer runs. The
# OUTCOME — "an agent still starts on this box" — was never asked, and it is the
# one question whose answer the box can produce for itself in about twenty
# seconds.
#
# THE PROBE IS ONE AGENT, AND IT IS ONE THE PASS WAS GOING TO BOUNCE ANYWAY.
# DIVE-3172 took the nightly from "restart everyone" to "restart whoever's
# payload moved", and a gate that adds an unconditional canary restart would put
# that cost straight back. So the canary is the FIRST unit this pass restarts:
# on a night with restarts the gate is free, and it fires before the second agent
# is touched — which is what keeps the blast radius of a bad release at one agent
# instead of the fleet.
#
# THE ONE NIGHT THAT BUYS NOTHING, AND WHY IT IS HANDLED SEPARATELY. The launcher
# is NOT in DIVE-3172's payload fingerprint (it lives in /usr/local/bin, not in
# an agent's home), so a launcher-only release changes no fingerprint, restarts
# nobody, and would never be probed — which is EXACTLY the shape of 0.26.1. When
# the launcher's own hash moved and the pass restarted no one, the gate probes an
# idle agent deliberately. That is a restart that would not otherwise happen, and
# it is bounded to the rare night the startup path itself changed.
#
# THREE OUTCOMES, NOT TWO. `unknown` is not folded into either answer:
#   healthy    -> the rest of the restart loop proceeds, byte for byte as today.
#   broken     -> restore the previous artifacts, restart the canary onto them,
#                 and touch NO other agent.
#   unknown    -> stop the loop, roll back NOTHING. Halting needs only the
#                 ABSENCE of evidence of health; reverting a release across a box
#                 needs positive evidence of breakage. Reverting on an unreadable
#                 systemctl would freeze a box on an old build every night the
#                 reading fails, silently — the failure mode DIVE-3173 and
#                 DIVE-1095 both name as the worse one.
#
# A rollback point is captured BEFORE the installer runs, because afterwards
# there is nothing left to restore from — install.sh has no rollback point of its
# own (its own header says so: "one upgrade cycle, with no tag, no cut, and no
# rollback point").

# The artifacts an update swaps that can, on their own, stop every agent from
# starting. Deliberately NOT the whole managed set (hooks, skills, refresh
# scripts, the digest cron): those are read by an agent that is already up, and
# reverting them would widen a targeted rollback into a general one. These three
# are the startup path itself.
#   $BIN/5dive                        the bundle; `5dive-agent-start` shells into it
#   $BIN/5dive-agent-start            the launcher — DIVE-4067's file
#   $SYSTEMD/5dive-agent@.service     ExecStart, Restart=, RestartPreventExitStatus
_hg_artifacts() {
  printf '%s\n' \
    "${HEALTH_GATE_BIN_DIR:-/usr/local/bin}/5dive" \
    "${HEALTH_GATE_BIN_DIR:-/usr/local/bin}/5dive-agent-start" \
    "${HEALTH_GATE_SYSTEMD_DIR:-/etc/systemd/system}/5dive-agent@.service"
}

_hg_rollback_dir() {
  printf '%s\n' "${HEALTH_GATE_ROLLBACK_DIR:-${STATE_DIR:-/var/lib/5dive}/rollback}"
}

_hg_sha() { [[ -f "${1:-}" ]] && sha256sum "$1" 2>/dev/null | awk '{print $1}'; return 0; }

# _hg_capture — snapshot the current startup path. Exactly ONE generation is
# kept: a rollback that could choose between generations would need someone to
# choose, and the only answer this gate can defend is "the thing that was
# working ten seconds ago".
#
# Returns non-zero when the snapshot is not usable. That does NOT stop the probe
# — detection without a rollback is still strictly better than the silence this
# row exists to remove, and the operator is told which of the two they got.
_hg_capture() {
  local dir f base rc=0
  dir="$(_hg_rollback_dir)"
  rm -rf "$dir.new" 2>/dev/null
  mkdir -p "$dir.new" 2>/dev/null || return 1
  : > "$dir.new/manifest" 2>/dev/null || return 1
  while read -r f; do
    [[ -n "$f" ]] || continue
    base="${f##*/}"
    # An artifact that is ABSENT is recorded as absent rather than skipped. A
    # box with no systemd template must not have one conjured onto it by a
    # rollback, and "we never saw this file" and "we failed to copy it" have to
    # be distinguishable at restore time.
    if [[ ! -f "$f" ]]; then
      printf 'absent\t%s\t-\n' "$f" >> "$dir.new/manifest"
      continue
    fi
    if cp -p "$f" "$dir.new/$base" 2>/dev/null; then
      printf 'present\t%s\t%s\n' "$f" "$(_hg_sha "$f")" >> "$dir.new/manifest"
    else
      printf 'uncopied\t%s\t%s\n' "$f" "$(_hg_sha "$f")" >> "$dir.new/manifest"
      rc=1
    fi
  done < <(_hg_artifacts)
  rm -rf "$dir" 2>/dev/null
  mv -f "$dir.new" "$dir" 2>/dev/null || return 1
  return $rc
}

# _hg_artifact_moved <path> — did the upgrade change this file since the capture?
# "no snapshot line" answers UNKNOWN (2), never "no": the launcher-only probe
# below must not be skipped because the manifest was unreadable.
_hg_artifact_moved() {
  local f="${1:-}" line was now
  line=$(awk -F'\t' -v p="$f" '$2==p{print; exit}' "$(_hg_rollback_dir)/manifest" 2>/dev/null) || line=""
  [[ -n "$line" ]] || return 2
  was="${line##*$'\t'}"
  now="$(_hg_sha "$f")"
  [[ -n "$now" ]] || return 2
  case "$line" in
    absent*) return 0 ;;
  esac
  [[ "$was" == "$now" ]] && return 1
  return 0
}

# _hg_restore — put the captured startup path back. Echoes the basenames it
# restored, one per line; empty output means nothing was restored.
_hg_restore() {
  local dir line status f base restored=0
  dir="$(_hg_rollback_dir)"
  [[ -f "$dir/manifest" ]] || return 1
  while IFS=$'\t' read -r status f _; do
    [[ -n "$f" ]] || continue
    base="${f##*/}"
    [[ "$status" == "present" ]] || continue
    [[ -f "$dir/$base" ]] || continue
    # Same-fs temp + mv, the shape install.sh uses for the bundle swap: a box
    # that loses power mid-restore keeps a whole file rather than a half-written
    # one that execs into garbage.
    if cp -p "$dir/$base" "$f.hgtmp" 2>/dev/null && mv -f "$f.hgtmp" "$f" 2>/dev/null; then
      printf '%s\n' "$base"; restored=$((restored + 1))
    else
      rm -f "$f.hgtmp" 2>/dev/null
    fi
  done < "$dir/manifest"
  (( restored > 0 )) || return 1
  # The unit template is one of the three, and systemd does not re-read it on
  # its own. Unconditional and best-effort: a reload with nothing to reload is
  # free, and skipping it after restoring the template would leave the box
  # running the bad ExecStart it just reverted.
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null
  return 0
}

# _hg_unit_field <unit> <property> — one systemd property, empty when unreadable.
_hg_unit_field() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl show "${1:-}" --property="${2:-}" --value 2>/dev/null || true
}

# _hg_verdict <ActiveState> <SubState> <NRestarts-before> <NRestarts-after>
#   healthy | crash-loop | failed | down | unknown
#
# Pure, so the harness grades the decision itself rather than a restatement.
#
# NRestarts IS THE FAST SIGNAL, and it is why this does not just read is-active.
# The unit is Type=simple, so a launcher that execs and dies one line later is
# `active` for the instant between them — the very reading a naive check would
# take. RestartSec=3 means systemd's first re-start lands ~3s in and NRestarts
# ticks to 1, which is decisive long before StartLimitBurst=10 finally parks the
# unit in `failed` some 30s later. So a crash-loop is caught by the counter, and
# the two exits the launcher itself uses for permanent conditions (2 unknown
# type, 3 not installed) are caught by `failed` via RestartPreventExitStatus.
_hg_verdict() {
  local active="${1:-}" sub="${2:-}" before="${3:-}" after="${4:-}"
  [[ -n "$active" ]] || { printf 'unknown\n'; return 0; }
  [[ "$before" =~ ^[0-9]+$ ]] || before=""
  [[ "$after"  =~ ^[0-9]+$ ]] || after=""
  [[ "$active" == "failed" ]] && { printf 'failed\n'; return 0; }
  if [[ -n "$before" && -n "$after" ]] && (( after > before )); then
    printf 'crash-loop\n'; return 0
  fi
  [[ "$active" == "active" && "$sub" == "running" ]] && { printf 'healthy\n'; return 0; }
  # Still coming up when the window ran out. NOT `down` — we did not watch long
  # enough to say, and `down` reverts a release.
  [[ "$active" == "activating" || "$active" == "reloading" ]] && { printf 'unknown\n'; return 0; }
  printf 'down\n'
}

# _hg_watch <unit> <baseline-NRestarts> [window-secs] [poll-secs]
# Echoes the verdict after watching the unit settle. Short-circuits on a
# DECISIVE failure only: an early `healthy` reading is not an answer, because
# "started" is not the question — "stayed up past the restart burst" is.
_hg_watch() {
  local unit="${1:-}" base="${2:-}" window="${3:-${HEALTH_GATE_WINDOW_SECS:-20}}" poll="${4:-${HEALTH_GATE_POLL_SECS:-1}}"
  local waited=0 v
  [[ "$window" =~ ^[0-9]+$ ]] || window=20
  [[ "$poll" =~ ^[0-9]+$ && "$poll" -gt 0 ]] || poll=1
  while :; do
    v="$(_hg_verdict "$(_hg_unit_field "$unit" ActiveState)" "$(_hg_unit_field "$unit" SubState)" \
                     "$base" "$(_hg_unit_field "$unit" NRestarts)")"
    case "$v" in
      crash-loop|failed) printf '%s\n' "$v"; return 0 ;;
    esac
    (( waited >= window )) && break
    sleep "$poll" 2>/dev/null || true
    waited=$((waited + poll))
  done
  printf '%s\n' "$v"
}

# _hg_probe <unit> — restart the unit and grade the outcome. Echoes the verdict.
# The baseline is read BEFORE the restart: NRestarts is cumulative for the life
# of the unit, so only the DELTA across this restart is about this release.
# _hg_canary_ok <unit> — is this unit a unit we can LEARN anything from?
#
# The gate reads a crash-loop as "the release broke the box". An agent that was
# ALREADY crash-looping before the update reads exactly the same, and would make
# the gate revert a perfectly good release for the whole box because one agent
# was independently sick — a false rollback is the one way this row can make a
# night worse than it found it.
#
# `systemctl list-units --state=running` does not settle it: a unit that dies and
# is re-started every 3s IS running at the instant it is enumerated. So this takes
# TWO samples a second apart and requires the unit to be active/running at both,
# with the counter still between them. A unit that fails this is not judged
# broken — it is judged UNREADABLE as an instrument, and the canary role moves to
# the next agent.
_hg_canary_ok() {
  local unit="${1:-}" a1 n1 a2 n2
  a1="$(_hg_unit_field "$unit" ActiveState)"; n1="$(_hg_unit_field "$unit" NRestarts)"
  [[ "$a1" == "active" && "$(_hg_unit_field "$unit" SubState)" == "running" ]] || return 1
  sleep "${HEALTH_GATE_PRECHECK_SECS:-1}" 2>/dev/null || true
  a2="$(_hg_unit_field "$unit" ActiveState)"; n2="$(_hg_unit_field "$unit" NRestarts)"
  [[ "$a2" == "active" && "$(_hg_unit_field "$unit" SubState)" == "running" ]] || return 1
  # Counters unreadable on both samples is not evidence of a loop — the verdict
  # path already treats an unreadable counter as no-delta, and being stricter
  # here would disqualify every canary on a systemd too old to report it.
  [[ -n "$n1" && -n "$n2" && "$n1" != "$n2" ]] && return 1
  return 0
}

_hg_probe() {
  local unit="${1:-}" base
  # POSITIVE CONTROL BEFORE THE MEASUREMENT. `Id` is set for every unit systemd
  # knows, so an empty one means systemd answered NOTHING — not that the unit is
  # sick. Without this control an uninterrogable systemd reads exactly like a
  # unit in an unclassifiable state, and the gate would halt the nightly on every
  # such box forever. (The same failure shape the CLAUDE.md rule names for a
  # cross-seat probe: a denial and a real negative are the same empty string
  # until something known-present is read alongside it.)
  if [[ -z "$(_hg_unit_field "$unit" Id)" ]]; then
    systemctl restart "$unit" 2>/dev/null || { printf 'restart-refused\n'; return 0; }
    printf 'gate-unavailable\n'; return 0
  fi
  # A unit that was already sick cannot answer a question about the release.
  if ! _hg_canary_ok "$unit"; then
    printf 'not-a-canary\n'; return 0
  fi
  base="$(_hg_unit_field "$unit" NRestarts)"
  if ! systemctl restart "$unit" 2>/dev/null; then
    printf 'restart-refused\n'; return 0
  fi
  _hg_watch "$unit" "$base"
}
# _hg_action <verdict> -> proceed | rollback | halt | next-canary
#
# The split is asymmetric on purpose, and the two outcomes that are NOT `halt`
# are the ones worth reading twice — each exists because halting there would
# introduce a NEW fleet-wide failure in the name of preventing one.
#
#   ROLLBACK needs POSITIVE evidence of breakage — the unit died, systemd
#     re-started it, or it parked in `failed`. Reverting a box's startup path is
#     itself a change; doing it on a hunch is how a box never takes an update
#     again.
#   HALT needs only the ABSENCE of evidence of health. It costs the agents this
#     pass had not yet reached one night's payload refresh, it is loud, and it is
#     what holds the blast radius at one agent.
#   GATE-UNAVAILABLE PROCEEDS. This is not a reading we could not classify — it
#     is systemd declining to answer anything at all about the unit, on a box
#     where the gate therefore never ran. Halting there would take every box with
#     an uninterrogable systemd off updates entirely, permanently and for a
#     reason nobody would connect to this row: a new fleet-wide freeze introduced
#     by a safety check. Proceeding is exactly today's behaviour, and it is said
#     out loud at the call site rather than folded into a pass.
#   NOT-A-CANARY TAKES THE NEXT AGENT INSTEAD, and this one is load-bearing. An
#     agent that was already crash-looping before the update is indistinguishable
#     from a release that broke the box, and treating it as the latter reverts a
#     good release for every agent on the box. A false rollback is the one way
#     this row can make a night worse than it found it, so a canary that cannot
#     be read as an instrument is skipped rather than believed.
#   RESTART-REFUSED TAKES THE NEXT AGENT INSTEAD. systemctl declining to restart
#     one unit (masked, mid-stop, a bad drop-in) says nothing about the artifact,
#     and before this row that agent simply landed in `failed` and the loop went
#     on. Halting on it would let one stuck unit stop the nightly for the whole
#     box, so the canary role moves to the next agent the pass restarts and this
#     one is reported exactly as it always was.
_hg_action() {
  case "${1:-}" in
    healthy|gate-unavailable) printf 'proceed\n' ;;
    crash-loop|failed|down)   printf 'rollback\n' ;;
    restart-refused|not-a-canary) printf 'next-canary\n' ;;
    *)                        printf 'halt\n' ;;
  esac
}

# The line an operator reads in the nightly log. It names the release that was
# reverted and the agent it was measured on, because "update rolled back" with
# no subject is the same silence in a louder font.
_hg_rollback_note() {
  printf "POST-INSTALL HEALTH GATE FAILED on agent '%s' (%s) — this box installed a build on which an agent does not stay running. The startup path has been RESTORED to the build that was on this box before the update (%s); no other agent was touched. Nothing here retries: this box stays on the old build until the next update pass, and if that pass installs the same release it will fail the same way. Check the release before re-running \`5dive self-update\`." "${1:-?}" "${2:-?}" "${3:-nothing restored}"
}
# <<< DIVE-4068 post-install health gate

# >>> DIVE-4140 stable installer handoff
# The installer owns target resolution (override/canary/stable/last-known/floor).
# Keep the caller explicit about the shared route instead of growing a second,
# drifting resolver inside self-update.
_self_update_run_installer() {
  local installer="$1"
  CLI_VERSION_URL="${CLI_VERSION_URL:-https://api.5dive.com/cli-version}" \
    bash "$installer" --upgrade
}
# <<< DIVE-4140 stable installer handoff

cmd_self_update() {
  [[ $# -eq 0 ]] || fail "$E_USAGE" "self-update takes no arguments"
  command -v curl >/dev/null 2>&1 || fail "$E_NOT_FOUND" "curl is required for 5dive self-update"

  local installer
  installer=$(mktemp) || fail "$E_GENERIC" "failed to create temp file"
  # shellcheck disable=SC2064
  trap "rm -f '$installer'" RETURN

  step "Fetching installer"
  curl -fsSL "https://raw.githubusercontent.com/$(gh_org)/5dive/main/install.sh" -o "$installer" \
    || fail "$E_GENERIC" "failed to fetch installer"

  # DIVE-3173: pay off any restart still owed from a PREVIOUS run before taking
  # this run's fingerprints. An agent that was busy last night and idle now gets
  # its bounce here even on a box whose heartbeat tick is off — this pass and the
  # tick are two callers of one sweep, so the deferral never depends on a single
  # timer being armed.
  _pending_restart_sweep || true
  (( _PR_FIRED )) && step "fired ${_PR_FIRED} restart(s) deferred by an earlier run"
  (( _PR_PARKED )) && warn "${_PR_PARKED} owed restart(s) HELD — the agent(s) are parked (desiredState=stopped) but their units are running; the bounce fires once the registry and the unit agree"

  # DIVE-3172: snapshot each running agent's in-memory payload BEFORE the
  # upgrade. It has to be taken here — after the upgrade there is nothing left
  # to compare against, which is why the old code had no predicate to apply.
  local -a units=() names=() befores=()
  local unit name
  if command -v systemctl >/dev/null 2>&1; then
    while read -r unit; do
      [[ -z "$unit" ]] && continue
      name="${unit#5dive-agent@}"; name="${name%.service}"
      units+=("$unit"); names+=("$name")
      befores+=("$(_agent_payload_fingerprint "$(_agent_home "$name")")")
    done < <(systemctl list-units '5dive-agent@*' --state=running --no-legend --plain 2>/dev/null | awk '{print $1}')
  fi

  # DIVE-4068: snapshot the startup path BEFORE the installer overwrites it —
  # afterwards there is nothing left to restore from. A capture that fails does
  # NOT abort the upgrade and does not disarm the probe: detection with no
  # rollback is still better than the silence this replaces, and the operator is
  # told which of the two this box has.
  local hg_capture=ok
  _hg_capture || { hg_capture=unusable; warn "could not capture a rollback point in $(_hg_rollback_dir) — the post-install health gate will still DETECT a box that cannot start an agent, but it will not be able to put the previous build back"; }

  step "Upgrading 5dive CLI + plugins"
  # Send installer chatter to stderr so JSON stdout stays parseable.
  _self_update_run_installer "$installer" >&2 || fail "$E_GENERIC" "upgrade failed"

  # Restart only the agents whose payload actually moved. Best-effort per unit —
  # one failed restart shouldn't abort the rest.
  local -a restarted=() failed=() skipped=() deferred=() parked=()
  local i after before atype why busy
  # DIVE-4068 gate state. `hg_verdict` stays "not-probed" until a unit is
  # actually restarted, and that is a THIRD value, not a pass — a pass has to be
  # something the box measured.
  local hg_canary="" hg_verdict="not-probed" hg_verdict_raw="" hg_action="proceed" hg_why=""
  for i in "${!units[@]}"; do
    name="${names[$i]}"; before="${befores[$i]}"
    # DIVE-4033: asked BEFORE the payload predicate, so the operator is told the
    # contradiction rather than "skipped (payload unchanged)" — which happens to
    # be true on a CLI-only night and would not be on the next one, when the same
    # parked agent gets bounced back to life with no line saying why.
    after="$(_agent_payload_fingerprint "$(_agent_home "$name")")"
    # An agent whose type we cannot read is unmeasurable, which restarts — same
    # branch as a type with non-derivable config, so a registry miss is safe.
    atype=$(agent_type "$name" 2>/dev/null) || atype=""
    if _agent_is_parked "$name"; then
      warn "$(_parked_override_note "$name")"
      parked+=("$name")
      # Iteration 2. The fingerprint above is taken BEFORE this branch so the
      # debt can be recorded, but the branch still short-circuits the payload
      # predicate's own `continue` — the operator is told the contradiction, not
      # "skipped (payload unchanged)", which happens to be true on a CLI-only
      # night and would not be on the next one.
      #
      # Mark the pending restart when the payload actually moved. Dropping it
      # here left the agent on the pre-update payload forever once the operator
      # took the `agent start` exit (a no-op on a live unit — it flips the
      # registry only), with nothing owed and nothing said. Marking is the same
      # ledger DIVE-3173 already fires from: the very next sweep sees
      # desiredState=running and bounces it.
      #
      # Conditional on the predicate on purpose: an unmarked parked agent whose
      # payload never moved owes nothing, and marking it unconditionally would
      # bounce a just-unparked agent for no reason. A marker we cannot WRITE is
      # only warned about — restarting it here is the resurrection this row is
      # about, so that fallback is not available on this branch.
      if _agent_restart_needed "$before" "$after" "$atype"; then
        _pending_restart_mark "$name" "payload changed while parked" \
          || warn "could not record the owed restart for parked agent '$name' — it will stay on the old payload until it is restarted"
      fi
      continue
    fi
    if ! _agent_restart_needed "$before" "$after" "$atype"; then
      step "skipped $name (payload unchanged)"
      skipped+=("$name")
      continue
    fi
    # Say WHICH reason out loud. "restarted" alone is emitted both by a real
    # payload change and by a type we simply cannot measure, and an operator
    # reading the nightly log has to be able to tell those apart — the second one
    # is the population a TYPE_CONFIG_FILE map would move into the first.
    why="payload changed"
    if [[ -n "$before" && -n "$after" && "$before" == "$after" ]]; then
      why="type '${atype:-unknown}' config not derivable — always restarts"
    fi
    # DIVE-3173: the payload moved and this agent is holding a row. Remember the
    # restart instead of taking it — the sweep above fires it at the agent's next
    # task boundary. `unknown` (board unreadable) defers too: not knowing is not
    # the same as knowing it is free.
    busy="$(_agent_busy_state "$name")"
    if [[ "$busy" != "idle" ]]; then
      if _pending_restart_mark "$name" "$why"; then
        step "deferred $name ($why; holds an in_progress row — bounces at its next task boundary)"
        deferred+=("$name")
        continue
      fi
      # We could not write the marker, so nothing would remember this restart.
      # Restart now: a bounce is loud and recoverable, an agent silently left on
      # the old payload is neither. Stated because it is the one path where this
      # change deliberately keeps the behaviour it exists to remove.
      warn "could not record a deferred restart for '$name' — restarting now"
    fi
    # DIVE-4068: the FIRST unit this pass bounces is the canary. Not an extra
    # restart — this agent was being restarted either way — and the gate settles
    # before the loop reaches agent number two, which is what keeps a bad release
    # to one dark agent instead of the box.
    if [[ -z "$hg_canary" ]]; then
      hg_canary="$name"; hg_why="first agent this pass restarts"
      hg_verdict="$(_hg_probe "${units[$i]}")"; hg_verdict_raw="$hg_verdict"
      hg_action="$(_hg_action "$hg_verdict")"
      if [[ "$hg_action" == "next-canary" ]]; then
        hg_canary=""; hg_verdict="not-probed"; hg_action=proceed
        if [[ "$hg_verdict_raw" == "not-a-canary" ]]; then
          # The unit was not steady BEFORE the update, so it cannot answer a
          # question about the release. Nothing has been restarted yet on this
          # branch — `_hg_probe` returns before the restart — so fall through to
          # the ORDINARY restart below and let the next agent take the canary
          # role. Believing this unit would revert a good release for the whole
          # box on one independently sick agent.
          step "not using $name as the health-gate canary (its unit was not steady before the update) — the next agent this pass restarts takes that role"
        else
          # systemctl would not restart this unit: the pre-DIVE-4068 `failed`
          # case verbatim, and not evidence about the release.
          warn "failed to restart agent '$name'"
          failed+=("$name"); continue
        fi
      elif [[ "$hg_action" != "proceed" ]]; then
        break
      else
        if [[ "$hg_verdict" == "gate-unavailable" ]]; then
          warn "restarted $name, but systemd answered nothing about the unit — the post-install health gate could NOT run on this box. This pass behaves exactly as it did before the gate existed: a release that cannot start an agent will not be caught here."
        else
          step "restarted $name ($why) — health gate PASSED (the unit was still running ${HEALTH_GATE_WINDOW_SECS:-20}s later, with no systemd re-start)"
        fi
        restarted+=("$name")
        continue
      fi
    fi
    if systemctl restart "${units[$i]}" 2>/dev/null; then
      step "restarted $name ($why)"
      restarted+=("$name")
    else
      warn "failed to restart agent '$name'"
      failed+=("$name")
    fi
  done

  # DIVE-4068: the pass restarted nobody, so nothing exercised the startup path
  # the installer just replaced — and a LAUNCHER-ONLY release is exactly that
  # shape. `5dive-agent-start` lives in /usr/local/bin, not in an agent's home,
  # so it is invisible to DIVE-3172's payload fingerprint: 0.26.1 would have
  # moved no fingerprint, restarted no one, and been probed by nothing. Then the
  # first crash-restart, operator bounce or deferred sweep to follow would have
  # found the box dark, with no gate anywhere near it.
  #
  # So on that night, and only that night, the gate spends one restart. An
  # UNREADABLE manifest probes too (`_hg_artifact_moved` exit 2): DIVE-2230's
  # rule, an absent reading resolves to neither answer, and the branch that costs
  # a restart is the recoverable one.
  if [[ -z "$hg_canary" && "$hg_action" == "proceed" ]] && command -v systemctl >/dev/null 2>&1; then
    # Declared and assigned SEPARATELY. `local hg_moved=$?` reads local's own
    # status on some shells, and this row exists because of a `local` that
    # referred to itself.
    local hg_moved=0
    _hg_artifact_moved "${HEALTH_GATE_BIN_DIR:-/usr/local/bin}/5dive-agent-start" || hg_moved=$?
    if (( hg_moved != 1 )); then
      local cand
      for i in "${!units[@]}"; do
        cand="${names[$i]}"
        # Every guard the loop above applies, applied again: an agent nobody
        # asked to restart must not be resurrected from a park, interrupted
        # mid-row, or bounced between turns of a closing one.
        _agent_is_parked "$cand" && continue
        [[ "$(_agent_busy_state "$cand")" == "idle" ]] || continue
        if declare -F _hb_agent_idle >/dev/null 2>&1 && ! _hb_agent_idle "$cand" 0.4; then continue; fi
        systemctl is-active --quiet "${units[$i]}" 2>/dev/null || continue
        hg_canary="$cand"
        hg_why="the launcher itself changed and this pass restarted no one$( (( hg_moved == 2 )) && printf ' (manifest unreadable — probed rather than assumed unchanged)')"
        step "no agent needed a restart, but the launcher changed — probing '$cand' so a build that cannot start an agent is found now rather than on its next bounce"
        hg_verdict="$(_hg_probe "${units[$i]}")"; hg_verdict_raw="$hg_verdict"
        hg_action="$(_hg_action "$hg_verdict")"
        if [[ "$hg_action" == "next-canary" ]]; then
          [[ "$hg_verdict_raw" == "restart-refused" ]] && { warn "failed to restart agent '$cand'"; failed+=("$cand"); }
          hg_canary=""; hg_verdict=not-probed; hg_action=proceed; continue
        fi
        [[ "$hg_action" == "proceed" ]] && restarted+=("$cand")
        break
      done
      if [[ -z "$hg_canary" ]]; then
        hg_verdict="no-safe-canary"
        warn "the launcher changed and no agent was safe to probe (all parked, busy or down) — this box installed a new startup path that NOTHING on it has exercised. The next agent restart, from any cause, is the first thing that will find out."
      fi
    fi
  fi

  # DIVE-4068: the gate said stop. Everything below this point — the rest of the
  # restart loop, the listener refresh, the ok summary — is skipped, because each
  # of them touches something else on a box we have just measured as unable to
  # keep an agent running.
  if [[ "$hg_action" != "proceed" ]]; then
    local hg_restored="" hg_rolled=false hg_canary_state=""
    if [[ "$hg_action" == "rollback" ]]; then
      if [[ "$hg_capture" == "unusable" ]]; then
        warn "the health gate would roll this box back and CANNOT — no rollback point was captured before the upgrade. The box is on the new build and agent '$hg_canary' is not running."
      else
        hg_restored="$(_hg_restore | paste -sd, - 2>/dev/null)" || hg_restored=""
        [[ -n "$hg_restored" ]] && hg_rolled=true
      fi
      if [[ "$hg_rolled" == true ]]; then
        # Bring the canary back UP on the restored path. Without this the gate
        # ends its run having darkened exactly one agent — a smaller version of
        # the failure it exists to prevent, and one nobody would be watching for.
        local hg_cu="5dive-agent@${hg_canary}.service" hg_cbase
        hg_cbase="$(_hg_unit_field "$hg_cu" NRestarts)"
        if systemctl restart "$hg_cu" 2>/dev/null \
           && [[ "$(_hg_watch "$hg_cu" "$hg_cbase")" == "healthy" ]]; then
          hg_canary_state=recovered
          step "agent '$hg_canary' is running again on the restored build"
        else
          hg_canary_state=still-down
          warn "agent '$hg_canary' did NOT come back after the rollback — the old build is back on disk but this agent needs a look. Start it with 'systemctl restart 5dive-agent@${hg_canary}.service' and read 'journalctl -u 5dive-agent@${hg_canary}'."
        fi
        warn "$(_hg_rollback_note "$hg_canary" "$hg_verdict" "$hg_restored")"
      fi
    else
      warn "POST-INSTALL HEALTH GATE INCONCLUSIVE on agent '$hg_canary' (verdict '$hg_verdict') — this box could not be read well enough to say whether an agent stays running on the new build. NOTHING was rolled back: reverting a release needs evidence it is broken, and this is the absence of evidence that it works. The other agents this pass had not yet reached were left alone, so the blast radius stays at one. Check 'systemctl status 5dive-agent@${hg_canary}' before re-running."
    fi
    fail "$E_GENERIC" "self-update HALTED by the post-install health gate — agent '$hg_canary' ($hg_why) did not stay running on the new build (verdict '$hg_verdict'); rolled_back=$hg_rolled${hg_restored:+ ($hg_restored)}, canary=${hg_canary_state:-not-recovered}, other agents untouched"
  fi

  # DIVE-1095: refresh the materialized shared team-bot listener. It lives at
  # /opt/5dive/team-bot-listener.ts and is (re)written ONLY by `team-bot shared`,
  # so listener-only fixes (e.g. DIVE-1093's tap handling) otherwise ship in the
  # bundle but stay DORMANT on auto-updating boxes until an operator re-runs that
  # command. Re-materialize the listener from the freshly-installed bundle and
  # restart its service. Guarded on the unit file so it's a no-op on boxes with
  # no shared team-bot; best-effort so a listener hiccup never fails self-update.
  local listener_refreshed=false
  if [[ -f /etc/systemd/system/5dive-team-bot-listener.service ]]; then
    if _team_bot_install_listener >&2; then
      step "refreshed shared team-bot listener"
      listener_refreshed=true
    else
      warn "team-bot listener refresh failed (prior listener left running)"
    fi
  fi

  local r f s d pk prose
  r=$(json_array "${restarted[@]}")
  f=$(json_array "${failed[@]}")
  s=$(json_array "${skipped[@]}")
  d=$(json_array "${deferred[@]}")
  pk=$(json_array "${parked[@]}")
  prose="self-update complete — ${#restarted[@]} agent(s) restarted"
  # Say the skip count out loud. "0 agents restarted" alone is emitted both by a
  # CLI-only night (the good case this change exists to produce) and by a box
  # with no agents running at all, and an operator reading the nightly log has to
  # be able to tell those apart.
  (( ${#skipped[@]} )) && prose+=", ${#skipped[@]} skipped (payload unchanged)"
  # DIVE-3173: a deferral is not a skip and must not read as one — the payload
  # DID move for these, the bounce is owed, and someone reading the nightly log
  # has to be able to see that it is outstanding rather than decided against.
  (( ${#deferred[@]} )) && prose+=", ${#deferred[@]} deferred (busy — bounce at next task boundary)"
  # DIVE-4033: a parked agent is neither a skip nor a deferral. Nothing was
  # decided — it is an operator contradiction that self-update declined to
  # resolve — but where the payload moved the restart IS owed and is held in the
  # DIVE-3173 ledger, so this must not read as "handled". The count is how the
  # contradiction reaches someone reading the log.
  (( ${#parked[@]} )) && prose+=", ${#parked[@]} left parked (desiredState=stopped but running — restart held, reconcile)"
  (( ${#failed[@]} )) && prose+=", ${#failed[@]} failed to restart"
  # DIVE-4068: say which of the three the gate did. "not-probed" is a real
  # answer and must not read as a pass — it means this pass bounced nobody and
  # the launcher had not moved, so the new startup path is untested on this box
  # by construction, not by measurement.
  case "$hg_verdict" in
    healthy)          prose+=", health gate passed on '$hg_canary'" ;;
    gate-unavailable) prose+=", health gate COULD NOT RUN (systemd answered nothing about '$hg_canary')" ;;
    not-probed) prose+=", health gate not probed (no agent restarted and the launcher did not change)" ;;
    *)          prose+=", health gate: $hg_verdict" ;;
  esac
  [[ "$listener_refreshed" == "true" ]] && prose+=", team-bot listener refreshed"
  # `skipped` and `deferred` are ADDITIVE — `restarted`/`failed` keep their exact
  # prior meaning, so every existing consumer reads the field it always did.
  ok "$prose" \
     '{restarted:$r, restarted_count:($r|length), skipped:$s, skipped_count:($s|length), deferred:$d, deferred_count:($d|length), parked:$pk, parked_count:($pk|length), failed:$f, listener_refreshed:$lr, health_gate:{verdict:$hgv, agent:(if $hgc == "" then null else $hgc end), reason:(if $hgw == "" then null else $hgw end), rollback_point:$hgcap}}' \
     --argjson r "$r" --argjson f "$f" --argjson s "$s" --argjson d "$d" --argjson pk "$pk" --argjson lr "$listener_refreshed" \
     --arg hgv "$hg_verdict" --arg hgc "$hg_canary" --arg hgw "$hg_why" --arg hgcap "$hg_capture"
}

# version_lt A B — true when semver A is strictly older than B (sort -V).
version_lt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

# How long the dashboard waits after a release before treating a still-behind
# box as "stale". One nightly soft-update (every 24h) should close the gap, so
# anything past ~1.5 days means the auto-update isn't keeping up.
readonly UPDATE_STALE_AFTER_SECS=$((36 * 3600))

# >>> DIVE-2287 version-freeze observer
#     (tests/version_freeze_observer_unit.sh extracts this block VERBATIM
#      between these markers and runs the shipped bytes — keep them.)
#
# Every staleness signal we have is a COMPARISON against a published "latest".
# That family shares one blind spot: when the release process itself stops, the
# comparand stops moving too, every box compares equal, and the whole fleet
# reports green while nothing has updated for a week. DIVE-2243's monotonicity
# guard sharpened this — it converted a silent fleet-wide DOWNGRADE into a loud
# refusal plus a frozen fleet, and nothing alarms on a frozen fleet. A guard
# that turns a wrong answer into no answer has moved which silence you live
# with, not removed it.
#
# So this observation is ABSOLUTE and takes no comparand: has the version this
# box RUNS changed, ever, within N days. It stays true when the cutter is dead,
# when the tag is frozen, when the probe is offline, and when --check is wrong.
#
# WHY IT NEEDS A RECORD AND CANNOT READ ONE OFF THE BOX. The obvious baseline is
# the installed binary's mtime — "when was 5dive last written". It is WRONG, and
# silently so: `refresh_managed_files()` swaps the bundle in UNCONDITIONALLY
# (`mv -f "$_bundle_tmp" "$BIN_DIR/5dive"`), with no already-current branch. The
# nightly rewrites the file every night whether or not the version moved, so
# mtime measures the last UPDATE ATTEMPT and never the last version CHANGE — the
# exact two things this alarm exists to tell apart. A freeze read off mtime
# would report "moved yesterday" forever, i.e. a monitor that cannot fire.
#
# ABSENT RECORD IS UNKNOWN, NOT FRESH (DIVE-2230's rule). A missing record is
# emitted identically by "first pass on a new box" and "record wiped", so it
# resolves to neither: we seed it and answer `unknown`. Reporting a green from
# an absent record would rebuild the fail-open one layer down.
#
# DIVE-2306 — AN UNKNOWN THAT WILL NEVER RESOLVE IS ITS OWN ANSWER. Everything
# above is about the reading; this is about whether the reading can ever be
# TAKEN on this box. The alarm needs a record it can both write and re-read: the
# state is derived by comparing the running version against a stored one, so a
# caller that cannot WRITE the record leaves it exactly where it was, and the
# next caller is in the identical position. Two ways that happens, and both are
# silent today:
#
#   1. `update --check` runs as an unprivileged operator against a STATE_DIR it
#      cannot write. It answers `unknown` — honestly — and will answer `unknown`
#      forever, because nothing it does moves the record.
#   2. `supervisor --tick` is the caller guaranteed to run as root and therefore
#      guaranteed able to write, and it NO-OPS unless the enable flag exists. On
#      a box where the tick is off, (1) may be the only caller there is.
#
# In both, "we have not observed a freeze" is indistinguishable from "we cannot
# observe one" — the alarm is UNARMED, and an unarmed alarm reporting `unknown`
# reads as a monitor doing its job. So the observation now says which it is.
# `armed=no` is not a state of the FLEET; it is a statement about this box's
# ability to answer at all, which is why it is a fourth field and not a fourth
# value of the state (a consumer reading only the state keeps its exact prior
# meaning — the same additive rule DIVE-2287 applied one layer up).
#
# Prints exactly four lines (never fails the caller):
#   1  state       moving | frozen | unknown
#   2  age_secs    seconds since the running version was first observed ('' if unknown)
#   3  detail      human phrase — always the OBSERVED claim ("not observed to
#                  change"), never the stronger unobserved one ("did not change")
#   4  armed       yes | no — whether this box can record the observation at all.
#                  `no` means the state above cannot change no matter how long
#                  the fleet stays frozen.
_CLI_FREEZE_AFTER_SECS=$((7 * 86400))
_cli_freeze_observe() {
  local cur="${1:-}" record="${2:-}" now="${3:-}"
  # 4th arg defaults to `yes`: every site that reaches a conclusion FROM a
  # readable record is by construction armed, so only the unrecordable paths
  # have to say so.
  _cfo_out() { printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "${4:-yes}"; }
  [[ -n "$now" ]] || now=$(date +%s)
  [[ -n "$cur" ]] || { _cfo_out unknown "" "the running version is unreadable" no; return 0; }
  [[ -n "$record" ]] || { _cfo_out unknown "" "no state dir to record version movement in" no; return 0; }

  local seen_ver="" seen_at=""
  if [[ -r "$record" ]]; then
    seen_ver=$(jq -r '.version // empty' "$record" 2>/dev/null) || seen_ver=""
    seen_at=$(jq -r '.first_seen_epoch // empty' "$record" 2>/dev/null) || seen_at=""
    [[ "$seen_at" =~ ^[0-9]+$ ]] || seen_at=""
  fi

  # A version we have never recorded, or an unusable record, restarts the clock
  # — and the restart is itself the movement signal on every case but the first.
  if [[ -z "$seen_ver" || -z "$seen_at" || "$seen_ver" != "$cur" ]]; then
    # Best-effort write. A read-only STATE_DIR (`update --check` runs as a
    # non-root operator) must not fail the command — it degrades to `unknown`,
    # which is what an unrecordable observation honestly is.
    #
    # DIVE-2306: whether the write LANDED is the armed/unarmed answer, and it is
    # only knowable here. `-w` on the directory is a permission, not an outcome
    # (a full disk, a read-only mount remounted under us, an immutable file all
    # pass it), so the flag is set from the redirect's own status.
    local wrote=0
    if [[ -w "$(dirname "$record")" || -w "$record" ]]; then
      if printf '{"version":%s,"first_seen_epoch":%s,"first_seen_at":%s}\n' \
        "$(printf '%s' "$cur" | jq -R .)" "$now" \
        "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null | jq -R .)" \
        > "$record" 2>/dev/null; then
        wrote=1
      fi
    fi
    local armed=no; (( wrote )) && armed=yes
    if [[ -n "$seen_ver" && "$seen_ver" != "$cur" ]]; then
      # An unwritable record here is the sharpest case: the version DID move,
      # the record still names the old one, and every future call re-reports
      # this same "changed" — a monitor stuck on a transition it can never
      # leave. Loud in the state, honest in `armed`.
      _cfo_out moving "0" "version changed ${seen_ver} -> ${cur}" "$armed"
    elif (( wrote )); then
      _cfo_out unknown "" "no prior observation of this box's version — clock starts now"
    else
      _cfo_out unknown "" \
        "the version observation cannot be recorded on this box (${record} is not writable by this caller) — the freeze alarm is UNARMED and will stay unknown" no
    fi
    return 0
  fi

  local age=$(( now - seen_at ))
  (( age < 0 )) && { _cfo_out unknown "" "recorded observation is in the future — clock skew"; return 0; }
  local days=$(( age / 86400 ))
  if (( age >= _CLI_FREEZE_AFTER_SECS )); then
    _cfo_out frozen "$age" "CLI ${cur} has not been observed to change in ${days}d"
  else
    _cfo_out moving "$age" "CLI ${cur} first observed ${days}d ago"
  fi
}
# <<< DIVE-2287 version-freeze observer

# >>> DIVE-2042 published-version probe
#     (tests/update_check_propagation_unit.sh extracts this block VERBATIM
#      between these markers and runs the shipped bytes — keep them.)
#
# _published_cli_probe — read the version the installer would actually give
# this box, and say how much we trust the read.
#
# "What does main publish?" is a THREE-state question, not a value.
# raw.githubusercontent serves the bundle and its `.sha256` as two independent
# cache objects, so for minutes after every push to main it can hand back a
# STALE bundle beside a FRESH checksum — DIVE-1977 is the same window on the
# install path, and it has since been observed on the contents API too. A probe
# that can only return a version returns the stale one; the caller compares it
# to the local version, finds them equal, and reports a confident "up to date"
# to an operator asking precisely the question we could not answer. That window
# opens on EVERY push to main, and main HEAD is what customer boxes self-update
# from, so every ship has a period where a box asking "am I current?" is told
# yes and is wrong.
#
# Two defences, in order:
#   1. PIN to an IMMUTABLE ref. The split-generation window exists because
#      `main` MOVES. A release tag does not, so fetching both objects from
#      raw/<tag>/ closes the same window that pinning main->sha closed, for the
#      same reason and with one fewer round trip. (Fetch by tag NAME, never by
#      the sha `git ls-remote` prints for it: 97 of our tags are annotated, and
#      an annotated tag's own sha is the tag object, which raw.githubusercontent
#      does not serve. install.sh peels `^{}` for exactly this; the name needs
#      no peel because GitHub resolves the ref server-side.)
#   2. VERIFY. Hash the bundle we were ACTUALLY served and compare it to the
#      `.sha256` we were ACTUALLY served. Their disagreement IS the propagation
#      signal, and it is the only one there is if the CDN ever skews a tag.
#
# DIVE-2287 — WHICH REF DEFINES "LATEST". This probe used to read `main`, while
# `install.sh` installs the newest release TAG. When main runs ahead of the
# newest tag (the DIVE-2238 cutter outage; 0.17.2 assigned on main, v0.17.1 the
# newest tag) the two disagree, and the operator gets both halves at once:
#
#     5dive update --check   ->  CLI 0.16.32 is behind (latest 0.17.2)
#     sudo 5dive self-update ->  5dive upgraded: 0.16.32 -> 0.17.1
#
# ...then is told they are STILL behind, permanently, by a checker naming a
# version that does not exist as a tag and that no installer can deliver. Worse
# with DIVE-2243's monotonicity guard in place: a box that ever lands above the
# newest tag is REFUSED every subsequent upgrade while --check keeps insisting
# it is behind, and both messages are correct.
#
# So the probe resolves what the INSTALLER would resolve. The rungs below mirror
# install.sh's `resolve_gh_tag` deliberately — a second resolver that drifts from
# the first gives two answers to the one question this command exists to answer.
# NO fallback to main: falling back is precisely the defect, because main's
# version is not installable. Unresolvable tags => `unavailable`, which is honest
# and is also what the installer does (it fails CLOSED on the same condition).
#
# Prints exactly four lines (never fails the caller):
#   1  state    consistent | indeterminate | unavailable
#   2  version  the published FIVE_VERSION — empty unless state is consistent
#   3  detail   the ref the answer came from (consistent), else the reason.
#               Never empty, so line 3 always exists.
#   4  sha256   the sha256 of the published bundle — empty unless state is
#               consistent. DIVE-2640: a version STRING is a claim the bundle
#               makes about itself and nothing more — the hand-stamped
#               `0.18.0+dive2563` bundle satisfied a `0.18.x` criterion while
#               running neither the release nor main. The bytes are what turn
#               that claim into provenance, so the one resolver that already
#               fetched and checksum-verified the published bundle hands its
#               digest out rather than making a second fetch drift from this one.
_published_cli_probe() {
  local state version detail
  _pcp_out() { printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "${4:-}"; }

  command -v curl >/dev/null 2>&1 \
    || { _pcp_out unavailable "" "curl is not installed"; return 0; }
  command -v sha256sum >/dev/null 2>&1 \
    || { _pcp_out unavailable "" "sha256sum is not installed"; return 0; }

  local org tags="" ref=""
  org=$(gh_org)
  # Rung 1: git ls-remote — exact, no API rate limit.
  if command -v git >/dev/null 2>&1; then
    tags=$(GIT_TERMINAL_PROMPT=0 timeout 10 git ls-remote --tags --refs \
      "https://github.com/$org/5dive" 'v*' 2>/dev/null | sed -n 's#.*refs/tags/##p') || tags=""
  fi
  # Rung 2: the tags atom feed — unauthenticated, not subject to the 60/hr
  # api.github.com limit a NAT'd fleet shares. Parse <id>, NOT <title>: the
  # title carries a human release headline after the tag and matches nothing.
  if [[ -z "$tags" ]]; then
    tags=$(curl -fsSL --max-time 10 "https://github.com/$org/5dive/tags.atom" 2>/dev/null \
      | sed -n 's#.*<id>tag:github.com,[0-9]*:Repository/[0-9]*/\([^<]*\)</id>.*#\1#p') || tags=""
  fi
  # Rung 3: the tags API, last before giving up.
  if [[ -z "$tags" ]]; then
    tags=$(curl -fsSL --max-time 10 "https://api.github.com/repos/$org/5dive/tags?per_page=100" 2>/dev/null \
      | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\(v[0-9][^"]*\)".*/\1/p') || tags=""
  fi
  # `sort -V`, never `sort`. The regex drops anything that is not a plain
  # vMAJOR.MINOR.PATCH release tag, so an rc or a `nightly` can never become the
  # thing we advertise — same filter install.sh applies before installing one.
  [[ -n "$tags" ]] && ref=$(printf '%s\n' "$tags" \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1) || ref=""
  if [[ -z "$ref" ]]; then
    _pcp_out unavailable "" "no release tag resolves — the installer could not upgrade this box either"
    return 0
  fi

  local tmp
  tmp=$(mktemp -d) || { _pcp_out unavailable "" "no writable temp dir"; return 0; }
  local base="https://raw.githubusercontent.com/$org/5dive/$ref" fetched=1
  curl -fsSL --max-time 10 -o "$tmp/5dive" "$base/5dive" 2>/dev/null || fetched=0
  curl -fsSL --max-time 10 -o "$tmp/5dive.sha256" "$base/5dive.sha256" 2>/dev/null || fetched=0
  if (( ! fetched )) || [[ ! -s "$tmp/5dive" || ! -s "$tmp/5dive.sha256" ]]; then
    rm -rf "$tmp"
    _pcp_out unavailable "" "could not fetch the published bundle and its checksum"
    return 0
  fi

  local served published
  served=$(sha256sum "$tmp/5dive" | awk '{print $1}')
  published=$(awk 'NR==1{print $1}' "$tmp/5dive.sha256")
  version=$(grep -m1 -oP '(?<=^readonly FIVE_VERSION=")[^"]+' "$tmp/5dive") || version=""
  rm -rf "$tmp"

  if [[ "$served" != "$published" ]]; then
    # DIVE-1977's rule: name only the cause we can justify. Both objects came
    # from ONE immutable tag, so this is NOT the mutable-ref cache skew the old
    # unpinned path suffered — but a freshly cut tag is still being cached for
    # the first time when a box asks, so "propagation" and "bad bytes" are both
    # live and we are not entitled to pick. State the fact, name the ref, say
    # retry; do not accuse an operator's mirror of tampering on a coin flip.
    detail="the bundle published at $ref does not match its own checksum — either the tag is still propagating or the bytes are bad"
    _pcp_out indeterminate "" "$detail"
    return 0
  fi
  if [[ -z "$version" ]]; then
    _pcp_out indeterminate "" "the published bundle carries no FIVE_VERSION"
    return 0
  fi
  _pcp_out consistent "$version" "$ref" "$served"
}
# <<< DIVE-2042 published-version probe

# cmd_update_check — read-only (no root, no mutation) version probe for the
# dashboard maintenance tile. Compares the installed CLI to the published
# release and reads the last nightly soft-update result, then reports whether
# the box is GENUINELY stale (behind AND the auto-update isn't catching up) vs
# merely a release or two behind with a healthy nightly that'll close the gap.
#
# DIVE-2042: this answers in THREE states, not two. up-to-date / behind /
# INDETERMINATE. A checker that can only say yes or no says yes when it does
# not know, and the propagation window (see _published_cli_probe) is exactly
# when it does not know. Indeterminate exits NON-ZERO so an unattended caller
# branches on status alone and never reads a green it wasn't given.
cmd_update_check() {
  [[ $# -eq 0 ]] || fail "$E_USAGE" "update --check takes no arguments"
  command -v curl >/dev/null 2>&1 || fail "$E_NOT_FOUND" "curl is required for update --check"

  local current="$FIVE_VERSION" probe
  probe=$(_published_cli_probe)
  local -a p=()
  mapfile -t p <<<"$probe"
  local state="${p[0]:-unavailable}" latest="${p[1]:-}" detail="${p[2]:-no detail}"

  case "$state" in
    consistent) ;;
    indeterminate)
      # Worded to avoid the substring "up to date" entirely: this line lands in
      # nightly logs beside the green one, and half a grep must not read as a
      # pass.
      fail "$E_GENERIC" \
        "cannot determine whether CLI $current is current — $detail; retry in a few minutes" ;;
    *)
      fail "$E_GENERIC" "could not determine the latest published version — $detail" ;;
  esac
  [[ -n "$latest" ]] || fail "$E_GENERIC" "could not determine the latest published version"

  local behind=false ahead=false
  version_lt "$current" "$latest" && behind=true
  # DIVE-2287: a box ABOVE the newest release is its own state, not "up to
  # date". It is the state DIVE-2243's guard REFUSES every upgrade from, so
  # folding it into the green is how an operator ends up staring at "up to
  # date" and "refusing to DOWNGRADE" at the same time with no thread to pull.
  version_lt "$latest" "$current" && ahead=true

  # Inspect the last managed nightly soft-update run (managed boxes log to
  # /tmp/claude-soft-updates.log). Best-effort: absent log → unknown.
  local log="/tmp/claude-soft-updates.log"
  local last_ok_json="null" last_at_json="null" last_epoch=""
  if [[ -r "$log" ]]; then
    local start_line
    start_line=$(grep -n "soft updates start" "$log" | tail -1 | cut -d: -f1) || start_line=""
    if [[ -n "$start_line" ]]; then
      if tail -n "+${start_line}" "$log" | grep -q "CLI upgrade via install.5dive.com failed"; then
        last_ok_json="false"
      else
        last_ok_json="true"
      fi
    fi
    local last_at
    last_at=$(grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+ soft updates done" "$log" \
      | tail -1 | grep -oE "^[^ ]+") || last_at=""
    if [[ -n "$last_at" ]]; then
      last_at_json="\"$last_at\""
      last_epoch=$(date -d "$last_at" +%s 2>/dev/null || echo "")
    fi
  fi

  # "stale" = behind AND the nightly auto-update isn't closing the gap: it
  # failed, never ran on record, or hasn't run inside the staleness window.
  local stale=false now
  now=$(date +%s)
  if [[ "$behind" == true ]]; then
    if [[ "$last_ok_json" == "false" || -z "$last_epoch" ]]; then
      stale=true
    elif (( now - last_epoch > UPDATE_STALE_AFTER_SECS )); then
      stale=true
    fi
  fi

  # DIVE-2287 freeze observation — absolute, independent of $latest, so it
  # survives the release process being down (which is exactly when every
  # comparison-based signal above goes quiet).
  local -a fz=()
  mapfile -t fz < <(_cli_freeze_observe "$current" "${STATE_DIR}/cli-version-seen.json")
  local frozen_state="${fz[0]:-unknown}" frozen_age="${fz[1]:-}" frozen_detail="${fz[2]:-}"
  # DIVE-2306. `update --check` is the caller most likely to be UNARMED — it is
  # the unprivileged one — and it is also the caller a human runs by hand, so it
  # is where "this box cannot answer that question" has to be said.
  local frozen_armed="${fz[3]:-yes}" frozen_armed_json=true
  [[ "$frozen_armed" == yes ]] || frozen_armed_json=false

  local prose
  if [[ "$behind" == true ]]; then
    prose="CLI $current is behind (latest $latest)"
    [[ "$stale" == true ]] && prose+=" — stale, update recommended"
  elif [[ "$ahead" == true ]]; then
    prose="CLI $current is AHEAD of the newest release $latest — the installer will refuse to move it (a release cut is owed)"
  else
    prose="CLI $current is up to date"
  fi
  [[ "$frozen_state" == frozen ]] && prose+=" · ⚠ $frozen_detail"
  # An unarmed alarm never says "frozen", so this line is the only thing that
  # distinguishes a fleet that is moving from one nobody is watching.
  [[ "$frozen_armed_json" == false ]] && prose+=" · ⚠ freeze alarm UNARMED: $frozen_detail"

  # `behind`/`stale` keep their existing meaning and are only ever emitted on
  # the consistent path — the indeterminate branch above exits before here, so
  # a false `stale:false` can no longer be minted from a stale read.
  # `source` names the ref the answer came from (a 40-char sha when pinned,
  # "main" on the unpinned fallback) so a surprising number can be re-fetched
  # at the exact identity that produced it.
  # `ahead` and `frozen` are ADDITIVE — `behind`/`stale` keep their exact prior
  # meaning so the dashboard tile and every existing caller read the same field
  # they always did. `frozen` is a THREE-state string, not a boolean: an absent
  # or unwritable record is "unknown", and a caller must not be able to read a
  # green out of an observation we never made.
  ok "$prose" \
     '{current:$cur, latest:$lat, behind:$beh, ahead:$ahd, stale:$stl, frozen:$fz, frozenAgeSec:$fza, frozenDetail:$fzd, frozenArmed:$fzarm, lastUpdateOk:$luo, lastUpdateAt:$lua, source:$src}' \
     --arg cur "$current" --arg lat "$latest" --arg src "$detail" \
     --arg fz "$frozen_state" --arg fzd "$frozen_detail" \
     --argjson fzarm "$frozen_armed_json" \
     --argjson fza "${frozen_age:-null}" \
     --argjson beh "$behind" --argjson ahd "$ahead" --argjson stl "$stale" \
     --argjson luo "$last_ok_json" --argjson lua "$last_at_json"
}
