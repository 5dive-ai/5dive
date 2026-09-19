
# -------- wall (one screen holding every agent's live TUI, read-only) --------
#
# DIVE-4614. Every seat already runs its own tmux session (`agent-<seat>`) on its
# own user's socket. This tiles one READ-ONLY client per seat into a single tmux
# session called `wall`, so it holds no state of its own and cannot be the thing
# that breaks a seat. Re-running it JOINS the same session (the `screen -x`
# behaviour lodar asked for on 2026-09-18).
#
# READ-ONLY IS A SAFETY PROPERTY, NOT A PREFERENCE. `attach -r` is what stops a
# stray keystroke reaching a live agent; a Ctrl-C into an agent pane kills its
# unit. Writable is an explicit, one-pane, opt-in keybinding (C-b w) and never
# the default and never the whole wall.
#
# WINDOW-SIZE latest: each pane sizes the agent's OWN session, so six panes
# render each agent at about a third of the terminal's width. That is the
# accepted trade — the alternative (`largest` plus cropping) hides the BOTTOM of
# the TUI, which is where the prompt and the spinner live, i.e. the part you
# actually scan a wall for. It is in the help text so it is not discovered as a
# bug report.

WALL_SESSION="${WALL_SESSION:-wall}"

# --- grid -------------------------------------------------------------------
#
# THE LAYOUT IS BUILT BY HAND, never `select-layout tiled`. `tiled` derives its
# shape from the window's aspect ratio, so the same six seats came out 3x2 on
# one terminal and 2x3 on another. For a wall whose whole job is that you LEARN
# where each seat lives, a layout that moves between screens is a defect.
#
# `--grid=<cols>x<rows>` is the only knob (lodar, 2026-09-18 15:10Z: "in the task
# we filed it can be flexible" — the operator chooses, we pick a good default).

# wall_parse_grid <spec> -> "<cols> <rows>"; exit 2 on anything malformed.
# A silent reinterpretation of a bad grid is worse than a refusal: the operator
# would get a wall that is not the one they asked for and no way to tell.
wall_parse_grid() {
  local spec="${1:-}" c r
  [[ "$spec" =~ ^([0-9]+)x([0-9]+)$ ]] || {
    printf 'wall: --grid must look like <cols>x<rows>, e.g. --grid=3x2 (got: %s)\n' "$spec" >&2
    return 2
  }
  c="${BASH_REMATCH[1]}"; r="${BASH_REMATCH[2]}"
  if (( c < 1 || r < 1 )); then
    printf 'wall: --grid=%s has a zero dimension\n' "$spec" >&2
    return 2
  fi
  printf '%s %s' "$c" "$r"
}

# wall_default_grid <n> -> "<cols> <rows>". Three columns, then as many rows as
# the roster needs. Three is the readable ceiling for a Claude TUI at normal
# terminal widths; a fourth column makes each pane too narrow to read the status
# line, which is most of what a wall is for. At six seats this IS 3x2, the shape
# confirmed on the live wall.
wall_default_grid() {
  local n="${1:-0}" cols=3 rows
  (( n > 0 )) || n=1
  (( n < cols )) && cols="$n"
  rows=$(( (n + cols - 1) / cols ))
  printf '%s %s' "$cols" "$rows"
}

_wall_box_config() { printf '%s' "${BOX_CONFIG:-${STATE_DIR:-/var/lib/5dive}/box.json}"; }

# The operator's saved choice, per BOX (root-owned file in STATE_DIR, group
# readable — the same place the verify policy lives), so the wall comes back the
# way they left it instead of needing the flag every time. Prints nothing when
# nothing was saved or the saved value no longer parses.
wall_saved_grid() {
  local f v; f=$(_wall_box_config)
  [[ -r "$f" ]] || return 0
  v=$(jq -r '.wall.grid // empty' "$f" 2>/dev/null || printf '')
  [[ -n "$v" ]] || return 0
  wall_parse_grid "$v" 2>/dev/null || return 0
}

# Best effort by construction: only root writes box.json, and a non-root
# operator passing --grid must still GET that grid this run. So a failed save is
# a notice, never an error — but it is a LOUD notice, because "it forgot my
# grid" with no explanation is the confusing half of this feature.
wall_save_grid() {  # <cols> <rows>
  local f tmp; f=$(_wall_box_config)
  [[ -n "${1:-}" && -n "${2:-}" ]] || return 0
  tmp="${f}.wall.$$"
  local cur='{}'
  [[ -r "$f" ]] && cur=$(cat "$f" 2>/dev/null || printf '{}')
  if jq --arg g "${1}x${2}" '.wall = ((.wall // {}) | .grid = $g)' <<<"$cur" >"$tmp" 2>/dev/null \
     && mv -f "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  printf 'wall: could not save the grid to %s (need root) — using %sx%s for this run only\n' \
    "$f" "$1" "$2" >&2
  return 0
}

# wall_resolve_grid <n> [<flag-spec>] -> "<cols> <rows>"
# Precedence: the flag, then the saved choice, then the default.
#
# A GRID TOO SMALL FOR THE ROSTER IS REFUSED, LOUDLY. Silently dropping the
# tail of the seat list would hide a seat, and a seat you cannot see is the
# exact failure this feature exists to prevent.
wall_resolve_grid() {  # <n> [<spec>]
  local n="${1:-0}" spec="${2:-}" grid=""
  if [[ -n "$spec" ]]; then
    grid=$(wall_parse_grid "$spec") || return 2
  else
    grid=$(wall_saved_grid)
    [[ -n "$grid" ]] || grid=$(wall_default_grid "$n")
  fi
  local c r; read -r c r <<<"$grid"
  if (( c * r < n )); then
    printf 'wall: --grid=%sx%s holds %d panes but there are %d seats to show.\n' \
      "$c" "$r" $((c*r)) "$n" >&2
    printf '      Refusing rather than dropping %d seat(s) off the wall. Try --grid=%s, or name fewer seats.\n' \
      $(( n - c*r )) "$(wall_default_grid "$n" | tr ' ' x)" >&2
    return 2
  fi
  printf '%s %s' "$c" "$r"
}

# --- seats ------------------------------------------------------------------

# Is this seat's unit up? Seam, so the harness can drive the roster without
# systemd. `is-active` exits non-zero for inactive AND for unknown units, which
# is the answer we want in both cases: nothing to watch.
_wall_unit_active() {  # <seat>
  systemctl is-active --quiet "5dive-agent@${1}.service" 2>/dev/null
}

# wall_registry_seats <max> -> newline-separated seat names.
#
# THE ONE THING THAT HAD TO CHANGE TO BE A FEATURE. The host script carried
# `DEFAULT_SEATS=(main olivia dev quinn ops)` — OUR seats. On a customer box
# those do not exist and the wall comes up as six "no tmux session" panes, which
# is a bad first impression of an otherwise good feature. Read the registry.
#
# type=claude only: a codex seat has no tmux TUI to mirror, so a pane on one is
# a guaranteed blank. Running units only, for the same reason.
wall_registry_seats() {  # <max>
  local max="${1:-6}" reg name n=0
  reg=$(registry_read 2>/dev/null) || return 0
  while read -r name; do
    [[ -n "$name" ]] || continue
    _wall_unit_active "$name" || continue
    printf '%s\n' "$name"
    n=$(( n + 1 ))
    (( n >= max )) && break
  done < <(jq -r '(.agents // {}) | to_entries
                  | map(select(.value.type == "claude"))
                  | .[].key' <<<"$reg" 2>/dev/null)
  return 0
}

# --- privilege --------------------------------------------------------------
#
# Each seat's tmux server is its OWN user's, on socket /tmp/tmux-<uid>/default,
# mode srw-rw----. A pane reaches it only as that user, i.e. via
# `sudo -u agent-<seat>`. Who may do that is a per-box decision: root always can,
# and a named sudoers grant for the attach alone is the narrow alternative.
#
# THE FAILURE PATHS MUST NOT LOOK ALIKE. A denied `sudo -u` exits non-zero
# EXACTLY like a real "no session", so the naive probe renders a permissions
# problem as an empty fleet — the operator sees a dead company and goes looking
# for dead agents. The runas is therefore POSITIVE-CONTROLLED first, with a
# command that cannot fail for any other reason, and only then is the session
# asked about.
#
# wall_probe_seat <seat> -> prints one of: ok | no-session | denied
wall_probe_seat() {  # <seat>
  local seat="${1:-}" u="agent-${1:-}"
  if [[ "$(id -u)" != "0" ]]; then
    # POSITIVE CONTROL: `true` as that user succeeds whenever the runas is
    # granted, so a failure here is the GRANT and never the session.
    if ! sudo -n -u "$u" true >/dev/null 2>&1; then
      printf 'denied'; return 0
    fi
  fi
  if sudo -n -u "$u" tmux has-session -t "$u" >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'no-session'
  fi
}

_wall_denied_help() {  # <seat>
  printf '\n  [%s] NOT PERMITTED — this is a permissions problem, not a dead agent.\n' "$1"
  printf '\n  This box does not let %s run commands as user agent-%s, so the pane\n' "$(id -un 2>/dev/null || printf '?')" "$1"
  printf '  cannot reach that seat'\''s tmux socket at all.\n'
  printf '\n    sudo 5dive wall            # run the wall as root, or\n'
  printf '    grant a sudoers rule for the attach only:\n'
  printf '      <user> ALL=(agent-%s) NOPASSWD: /usr/bin/tmux\n\n' "$1"
}

# --- panes ------------------------------------------------------------------

# One pane's whole job: follow a seat and SURVIVE that seat restarting. A seat
# whose session goes away must not kill the pane, or the layout collapses around
# it — a restarting seat is normal, not an error.
wall_watch_seat() {  # <seat> [rw]
  local seat="$1" rw="${2:-}" u="agent-$1" state
  # ERREXIT IS OFF FOR THE WHOLE LOOP, DELIBERATELY, AND IT IS NOT DEFENSIVE
  # CODING. The bundle runs under header.sh's `set -euo pipefail`; the host
  # prototype this came from ran under `set -uo pipefail` and never met the
  # difference. Every branch below is a NON-ZERO EXIT THAT IS NORMAL: the seat
  # has no session yet, the operator lacks the runas, or tmux refuses the
  # attach. Under errexit the first of those kills the pane, the pane takes its
  # slot with it, and the layout collapses around a seat that merely restarted —
  # which is the exact property the row says must hold ("a seat's session going
  # away must not kill the pane"). Caught on the real-tmux acceptance run, where
  # every pane died inside a second and the wall vanished behind its own
  # attached client.
  set +e
  while :; do
    state=$(wall_probe_seat "$seat")
    case "$state" in
      ok)
        if [[ "$rw" == "rw" ]]; then
          sudo -n -u "$u" tmux attach -t "$u" || true
        else
          sudo -n -u "$u" tmux attach -r -t "$u" || true
        fi
        ;;
      denied)
        clear
        _wall_denied_help "$seat"
        sleep 10
        ;;
      *)
        clear
        printf '\n  [%s] no tmux session%s\n\n  the unit may be down:\n    systemctl status 5dive-agent@%s\n\n  retrying every 5s...\n' \
          "$seat" "$([[ "$rw" == "rw" ]] && printf ' (WRITABLE)')" "$seat"
        sleep 5
        ;;
    esac
    sleep 1
  done
}

# Which seat is the pane we are running inside showing? The pane TITLE is the
# seat name (set at build time, preserved across respawn-pane), so the key
# bindings stay static and the pane answers for itself at run time.
# ALWAYS pass -t "$TMUX_PANE": the bare form guesses from the CLIENT's active
# pane, so C-b w on a non-active pane read the wrong title — or none — and
# respawned as "vacant" instead of the seat it was showing.
_wall_pane_seat() {
  [[ -n "${TMUX_PANE:-}" ]] || return 0
  tmux display-message -p -t "$TMUX_PANE" '#{pane_title}' 2>/dev/null
}

wall_vacant_pane() {  # <pane index>
  set +e   # same reason as wall_watch_seat: this pane must outlive anything.
  clear
  printf '\n  VACANT SLOT\n\n  fill it without restarting the wall:\n    tmux respawn-pane -k -t %s.%s "5dive wall --follow <seat>"\n\n  or list who is running:\n    5dive agent ls\n' \
    "$WALL_SESSION" "${1:-0}"
  # Keep the pane alive so the layout does not collapse.
  while :; do sleep 3600; done
}

# --- build ------------------------------------------------------------------

wall_build() {  # <cols> <rows> <seat>...
  local cols="$1" rows="$2"; shift 2
  # The bundle re-invokes ITSELF for every pane, so the path must survive a
  # symlink and a relative invocation; a pane that cannot find the binary is a
  # pane that dies and takes its slot with it.
  local seats=("$@") self="${FIVE_WALL_SELF:-$(readlink -f "$0" 2>/dev/null || printf '5dive')}"
  local -a ids=()
  local total=$(( cols * rows )) i c

  _pane_cmd() {  # "" = vacant
    if [[ -z "${1:-}" ]]; then printf '%s wall --vacant %s' "$self" "${2:-0}"
    else printf '%s wall --follow %s' "$self" "$1"; fi
  }

  # FEWER SEATS THAN SLOTS keeps the vacant-pane behaviour: the grid is built to
  # its full size and the spare panes hold their slots, because a collapsing
  # layout is what made the panes unreadable in the first place.
  local -a slots=()
  for (( i = 0; i < total; i++ )); do slots+=("${seats[$i]:-}"); done

  ids[0]=$(tmux new-session -d -s "$WALL_SESSION" -x 240 -y 60 -n agents \
             -P -F '#{pane_id}' "$(_pane_cmd "${slots[0]}" 0)")

  # Columns 2..N, each split off the pane to its left, then even them out.
  for (( c = 1; c < cols; c++ )); do
    ids[$c]=$(tmux split-window -h -t "${ids[$((c-1))]}" \
                -P -F '#{pane_id}' "$(_pane_cmd "${slots[$c]}" "$c")")
  done
  tmux select-layout -t "$WALL_SESSION":agents even-horizontal >/dev/null

  # The remaining rows: cut each column in half, left to right, top to bottom.
  local r
  for (( r = 1; r < rows; r++ )); do
    for (( c = 0; c < cols; c++ )); do
      i=$(( r * cols + c ))
      local above=$(( (r - 1) * cols + c ))
      [[ -n "${ids[$above]:-}" ]] || continue
      ids[$i]=$(tmux split-window -v -t "${ids[$above]}" \
                  -P -F '#{pane_id}' "$(_pane_cmd "${slots[$i]}" "$i")")
    done
  done

  # PANES ARE ADDRESSED BY tmux PANE ID (%N), NEVER BY INDEX. An index shifts
  # under you on every split, so index-addressed labelling titles the wrong pane
  # as soon as the build order changes. Six identical Claude TUIs are unreadable
  # without labels.
  for i in "${!slots[@]}"; do
    [[ -n "${ids[$i]:-}" ]] || continue
    tmux select-pane -t "${ids[$i]}" -T "${slots[$i]:-vacant}"
  done

  tmux set-option -t "$WALL_SESSION" pane-border-status top
  tmux set-option -t "$WALL_SESSION" pane-border-format ' #{pane_index}: #{pane_title} '
  tmux set-option -t "$WALL_SESSION" mouse on
  tmux set-option -t "$WALL_SESSION" status-left ' 5dive wall (read-only · C-b w to type) '

  # TYPE INTO ONE PANE, ON PURPOSE. C-b w makes the CURRENT pane writable; C-b r
  # puts it back. One pane at a time and never the default, because a wall you
  # can type into everywhere is N agents one stray Ctrl-C from dying, on a screen
  # whose whole job is being glanced at.
  tmux bind-key -T prefix w respawn-pane -k "$self wall --follow-rw"
  tmux bind-key -T prefix r respawn-pane -k "$self wall --follow"
}

# --- entry point ------------------------------------------------------------

cmd_wall() {
  local grid_spec="" rebuild=0

  # FLAGS ARE SHIFTED OFF *ABOVE* THE SEAT LIST, and that ordering is the whole
  # bug this once had: `seats=("$@")` below would otherwise read "--rebuild" as a
  # SEAT NAME and build a one-pane wall titled --rebuild. Any flag added here
  # must be consumed in this loop, never after it.
  while (( $# > 0 )); do
    case "$1" in
      --grid=*)    grid_spec="${1#--grid=}"; shift ;;
      --rebuild)   rebuild=1; shift ;;
      -h|--help)   wall_usage; return 0 ;;
      # PANE MODES ARE RESOLVED FIRST, BEFORE the join-if-exists shortcut far
      # below. Backwards, a pane respawned once `wall` exists would exec
      # `tmux attach -t wall` and nest the wall inside its own pane; tmux
      # refuses, the pane dies, and the layout collapses with it. It reads like
      # a no-op reordering and silently breaks the whole feature, so
      # tests/wall_pane_mode_ordering_unit.sh pins it.
      --follow)
        shift
        local s="${1:-$(_wall_pane_seat)}"
        [[ -n "$s" ]] || { printf '5dive wall --follow <seat>\n' >&2; return 2; }
        wall_watch_seat "$s"; return 0 ;;
      --follow-rw)
        shift
        local sr="${1:-$(_wall_pane_seat)}"
        if [[ -z "$sr" || "$sr" == "vacant" ]]; then
          clear; printf '\n  no seat in this pane to type into.\n'; sleep 3
          wall_vacant_pane 0; return 0
        fi
        wall_watch_seat "$sr" rw; return 0 ;;
      --vacant)
        shift
        wall_vacant_pane "${1:-0}"; return 0 ;;
      --) shift; break ;;
      -*) printf '5dive wall: unknown flag %s (try --help)\n' "$1" >&2; return 2 ;;
      *)  break ;;
    esac
  done

  local -a seats=("$@")

  (( rebuild )) && tmux kill-session -t "$WALL_SESSION" 2>/dev/null

  # Already built? Just join it — the `screen -x` behaviour. NOTE this sits
  # BELOW every pane mode above, deliberately (see the comment on --follow).
  # --rebuild exists because the join shortcut means an existing wall keeps its
  # OLD layout after the grid changes, which is exactly how a layout change
  # looks like it did nothing.
  if (( ! rebuild )) && tmux has-session -t "$WALL_SESSION" 2>/dev/null; then
    exec tmux attach -t "$WALL_SESSION"
  fi

  # A grid named on the command line is the operator's choice, so it is
  # remembered for next time (per box).
  local n cols rows grid
  if (( ${#seats[@]} == 0 )); then
    # Cap the roster at the grid the operator asked for, or at the default 3x2,
    # so a 16-seat box does not silently produce an unreadable 16-pane wall.
    local cap=6
    if [[ -n "$grid_spec" ]]; then
      # Capture BEFORE read: `read <<<"$(f)"` succeeds on f's failure, so a bad
      # --grid would be swallowed here and only caught later, or not at all.
      local gspec gc gr
      gspec=$(wall_parse_grid "$grid_spec") || return 2
      read -r gc gr <<<"$gspec"
      cap=$(( gc * gr ))
    fi
    mapfile -t seats < <(wall_registry_seats "$cap")
  fi
  n=${#seats[@]}
  if (( n == 0 )); then
    printf '5dive wall: no running claude agents to show (5dive agent ls).\n' >&2
    return 1
  fi

  grid=$(wall_resolve_grid "$n" "$grid_spec") || return 2
  read -r cols rows <<<"$grid"
  [[ -n "$grid_spec" ]] && wall_save_grid "$cols" "$rows"

  # PREFLIGHT, so a permissions problem never renders as an empty fleet. Probing
  # every seat here (not just inside the panes) is what lets the wall refuse up
  # front with the reason, instead of coming up as N identical dead tiles.
  local s denied=0
  for s in "${seats[@]}"; do
    [[ "$(wall_probe_seat "$s")" == "denied" ]] && denied=$(( denied + 1 ))
  done
  if (( denied == n )); then
    printf '5dive wall: cannot attach to ANY seat — %s is not allowed to run commands as the agent users.\n' \
      "$(id -un 2>/dev/null || printf 'this user')" >&2
    printf "            This is a permissions problem, not a dead fleet. Run 'sudo 5dive wall', or grant\n" >&2
    printf '            a sudoers rule for the attach only (see 5dive wall --help).\n' >&2
    return 1
  fi

  wall_build "$cols" "$rows" "${seats[@]}"
  exec tmux attach -t "$WALL_SESSION"
}

wall_usage() {
  cat <<'WALLUSAGE'
5dive wall — one screen holding every agent's live TUI, read-only.

  5dive wall                       # every running claude seat, from the registry
  5dive wall main dev ops          # only these seats, in this order
  5dive wall --grid=4x2            # a different shape; remembered for this box
  5dive wall --rebuild             # tear the wall down and lay it out again

Inside the wall:
  C-b d   detach (agents keep running)     C-b z   zoom this pane fullscreen
  C-b w   make THIS pane writable          C-b r   back to read-only
  C-b ←→  move between panes

Read-only is the default and it is a safety property: a Ctrl-C into an agent
pane kills that seat's unit. C-b w opts ONE pane in, never the wall.

Seats come from the registry: running agents of type `claude`, in registry
order, capped at the grid's pane count. Spare slots stay as vacant panes so
the layout does not move when a seat is down.

The grid defaults to 3 columns and as many rows as the roster needs (3x2 at
six seats). Three columns is the readable ceiling for a Claude TUI; a fourth
makes each pane too narrow to read the status line. `--grid=` is refused if it
holds fewer panes than there are seats — a seat you cannot see is the failure
this feature exists to prevent. A grid you name is saved per box (needs root)
and used next time.

Each pane sizes the AGENT's own session (tmux `window-size latest`), so six
panes render each agent at about a third of the width. That is deliberate: the
alternative crops the bottom of the TUI, which is where the prompt and spinner
are.

PRIVILEGE: a pane reaches a seat's tmux socket only as that seat's user, so the
caller must be root or hold a runas grant for agent-<seat>. Without it the wall
says NOT PERMITTED per pane and refuses up front if no seat is reachable — it
never renders a permissions problem as a dead fleet.
WALLUSAGE
}
