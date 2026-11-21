
# -------- DIVE-9001: only the 5dive CLI opens the task board --------
#
# Before this, /var/lib/5dive/tasks was 2770 root:claude and tasks.db 0660, so
# every agent user (all in group `claude`) could run
# `sqlite3 tasks.db "update tasks set assignee=..."` and reassign a row, close
# its own row or clear a verifier. That made the maker/verifier split a habit,
# not a rule. The DIVE-2249 store fence (tasks_db.sh) only stops a SOURCED
# library caller; it could never stop a process that opens the file itself.
#
# THE SHAPE. The board dir belongs to a group no agent is in, `5dive-board`
# (root:5dive-board 2770), so an agent user cannot even get into the directory.
# When a board verb runs as a non-root seat, the CLI re-runs itself once through
# `sudo -g 5dive-board` (one rule in /etc/sudoers.d/5dive-board, for group
# `claude`, for the CLI only, through the symlink FIVEDIVE_BOARD_HOP_PATH).
#
# WHY A GROUP AND NOT A SEPARATE USER (the row left this to dev). `sudo -g`
# keeps the caller's UID, HOME, supplementary groups, tmux socket and Telegram
# files. Only the primary group changes. So:
#   * the actor is still the kernel's uid. task_actor already derives it from
#     $EUID (DIVE-2518), so it needs no SUDO_USER plumbing and cannot be spoofed;
#   * every side effect a task verb has today (agent send, notify via the seat's
#     own bot, heartbeat wake) runs as the same seat it always did.
# Switching to a board USER would have changed all of that in ~40 files.
#
# WHAT THE HOP CLEANS. sudo's env_reset drops the caller's environment and sets
# PATH to secure_path, so BASH_ENV, LD_PRELOAD, a PATH-shadowed jq or sqlite3 and
# every *_BIN override never reach the board-group process. The sudoers file
# keeps a short, named list of env vars the board verbs read (see
# board_sudoers_render). Inside the hop, sqlite3 always runs with `-init
# /dev/null`: it reads ~/.sqliterc from the passwd home (not $HOME), so without
# that one agent-written file would run arbitrary SQL on the next `task ls`.
#
# WHAT IT DOES NOT CLOSE, stated plainly. A process in the board group can open
# the board, and some board verbs start tools that read the seat's own dotfiles
# (git config, gh config). A seat that sets out to plant code in those can still
# reach the file. This change removes the direct path: a seat cannot open the
# board with its own sqlite3, python or node, and a CLI verb that is not a board
# verb cannot be run in the board group at all. Seats with full root sudo (admin
# tier) are root, so this does not constrain them.
#
# ONLY THE PRODUCTION STORE HOPS. A harness or a dev build pointing
# STATE_DIR/TASKS_DIR/TASKS_DB anywhere else never hops: sudo would drop those
# overrides and the run would land on the live board.

FIVEDIVE_BOARD_GROUP="5dive-board"
FIVEDIVE_BOARD_BIN="/usr/local/bin/5dive"
# The path the hop runs, a root-owned symlink to FIVEDIVE_BOARD_BIN. A DIFFERENT
# BASENAME ON PURPOSE: sudo matches a command by basename and then by inode, so a
# sudoers entry naming /usr/local/bin/5dive itself would also catch every
# `sudo 5dive ...` an admin seat runs as root, and the env_keep, !log_allowed
# and !pam_session below would silently apply to those root runs too. Naming
# the symlink keeps those settings on the hop alone.
FIVEDIVE_BOARD_HOP_PATH="/usr/local/lib/5dive/5dive-board"
FIVEDIVE_BOARD_SUDOERS="/etc/sudoers.d/5dive-board"
# Seams for tests/board_cli_only_writer_unit.sh. Moving them can only make this
# process decide NOT to hop, or hop to the one binary sudoers allows: the
# privilege boundary is the sudoers rule, not these names.
_BOARD_PROD_DIR="${_BOARD_PROD_DIR:-/var/lib/5dive/tasks}"

# The verbs that read or write the board as a non-root seat. A positive list:
# a verb missing here fails loudly ("cannot open the task board", tasks_db_init),
# while a verb wrongly ADDED here would run with the board group and a cleaned
# PATH. `gh` is deliberately absent: it hands its arguments to gh, whose aliases
# can run shell.
FIVEDIVE_BOARD_VERBS="task trigger triggers gate-proof org human humans people owner-ask board project projects loop goal objective objectives heartbeat liveness supervisor usage cost activity digest run runs reflex trace whoami company team account fleet helper proof push deploy"
# `agent` is mostly root-side or tmux-side; only these subverbs touch the board
# from a seat.
FIVEDIVE_BOARD_AGENT_SUBVERBS="proactive"

# The env vars a board verb reads from its caller (measured: grep of src/task,
# lib/tasks_db.sh, lib/runs.sh, cmd_loop.sh, cmd_wall.sh). Never PATH, never a
# *_BIN, never BASH_ENV or LD_*.
FIVEDIVE_BOARD_ENV_KEEP="AGENT_NAME CLAUDE_CODE_SESSION_ID CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN TELEGRAM_BOT_TOKEN FIVEDIVE_RUNTIME FIVEDIVE_WAKE_REASON FIVEDIVE_KEEP_ALIVE FIVE_TASK_ID TMUX TMUX_PANE COLUMNS NO_COLOR"

FIVE_BOARD_HOPPED=0

# The verb a command line names: the first word that is not the global --json.
_board_verb_of() {
  local a
  for a in "$@"; do
    [[ "$a" == "--json" ]] && continue
    printf '%s' "$a"; return 0
  done
  return 0
}

# Is `5dive <args>` a board command? Pure; no forks.
_board_is_board_cmd() {
  local verb sub="" a seen=0
  verb="$(_board_verb_of "$@")"
  [[ -n "$verb" ]] || return 1
  if [[ "$verb" == "agent" ]]; then
    for a in "$@"; do
      [[ "$a" == "--json" ]] && continue
      if (( seen )); then sub="$a"; break; fi
      [[ "$a" == "agent" ]] && seen=1
    done
    [[ -n "$sub" && " $FIVEDIVE_BOARD_AGENT_SUBVERBS " == *" $sub "* ]]
    return
  fi
  [[ " $FIVEDIVE_BOARD_VERBS " == *" $verb "* ]]
}

# Does this process point at the production board? Any override of the store
# path to somewhere else means no.
_board_store_is_prod() {
  local td db
  td="${TASKS_DIR:-${STATE_DIR:-/var/lib/5dive}/tasks}"
  db="${TASKS_DB:-$td/tasks.db}"
  [[ "$td" == "$_BOARD_PROD_DIR" && "$db" == "$_BOARD_PROD_DIR/tasks.db" ]]
}

# 0 = this invocation must re-run itself in the board group. Pure bash, no
# forks: it runs on every `5dive` call a seat makes.
#   <self> = $0 of the running bundle; the rest = its argv.
_board_hop_needed() {
  local self="$1"; shift
  (( ${_BOARD_EUID:-$EUID} != 0 )) || return 1
  (( FIVE_BOARD_HOPPED == 0 )) || return 1
  # Not a locked box (no board dir yet, or still the old root:claude 2770 one
  # this seat can enter): nothing to do.
  [[ -d "$_BOARD_PROD_DIR" && ! -x "$_BOARD_PROD_DIR" ]] || return 1
  _board_store_is_prod || return 1
  # sudoers allows exactly one binary. A dev build elsewhere does not hop; it
  # gets the plain "cannot open the board" error instead.
  [[ "$self" -ef "$FIVEDIVE_BOARD_BIN" ]] || return 1
  [[ "$FIVEDIVE_BOARD_HOP_PATH" -ef "$FIVEDIVE_BOARD_BIN" ]] || return 1
  _board_is_board_cmd "$@"
}

# The seat's own config for the tools a board-group process starts.
#   sqlite3 reads ~/.sqliterc from the PASSWD home, not $HOME, so one file the
#   seat writes would run arbitrary SQL on its next `task ls`. `-init /dev/null`
#   replaces it. This must hold in nested `5dive` calls a board verb makes too
#   (they inherit the group without hopping), so it is defined for every non-root
#   process on a box that has a board, not only in the hopped one. Outside the
#   board group it changes nothing.
#   python3 would import usercustomize and .pth files from the seat's site dir.
_board_neutralise_seat_config() {
  sqlite3() { command sqlite3 -init /dev/null "$@"; }
  export PYTHONNOUSERSITE=1
}

# Inside the hop: refuse anything that is not a board verb, so `sudo -g
# 5dive-board 5dive gh ...` (or any other verb) cannot be used to get a
# board-group process that runs the seat's own code.
_board_hopped_enter() {
  FIVE_BOARD_HOPPED=1
  _board_neutralise_seat_config
  if ! _board_is_board_cmd "$@"; then
    printf 'error: 5dive %s does not run in the task-board group (DIVE-9001). Run it without sudo -g.\n' \
      "$(_board_verb_of "$@")" >&2
    exit 10   # E_PERMISSION (lib/error_codes.sh loads after this file)
  fi
}

# The sudoers drop-in. Pure (no I/O) so a harness can grade it without root;
# board_lockdown visudo-validates it before installing.
board_sudoers_render() {
  cat <<SUDOERS
# Managed by 5dive (DIVE-9001). Lets an agent seat run the 5dive CLI with the
# task-board group, so the CLI is the only thing that opens the board.
# Same uid, primary group 5dive-board, environment reset except the named vars.
# Do not edit by hand; regenerated by install and self-update.
Cmnd_Alias FIVEDIVE_BOARD_CLI = ${FIVEDIVE_BOARD_HOP_PATH}
Defaults!FIVEDIVE_BOARD_CLI env_keep += "${FIVEDIVE_BOARD_ENV_KEEP}"
Defaults!FIVEDIVE_BOARD_CLI !pam_session, !log_allowed
%claude ALL=(:${FIVEDIVE_BOARD_GROUP}) NOPASSWD: FIVEDIVE_BOARD_CLI
SUDOERS
}

# -------- root side: putting the board behind the group --------

# Escape hatch for a box that must go back to the old shape (an older CLI is
# being reinstalled, or the hop misbehaves): with this file present every root
# pass puts the dir back to root:claude 2770 instead of locking it.
FIVEDIVE_BOARD_UNLOCK_MARKER="${FIVEDIVE_BOARD_UNLOCK_MARKER:-/etc/5dive/board-unlocked}"

_board_group_exists() {
  local g; g="$(</etc/group)" 2>/dev/null || return 1
  [[ $'\n'"$g" == *$'\n'"${FIVEDIVE_BOARD_GROUP}:"* ]]
}

_board_sudoers_current() {
  [[ -r "$FIVEDIVE_BOARD_SUDOERS" ]] || return 1
  [[ "$(<"$FIVEDIVE_BOARD_SUDOERS")" == "$(board_sudoers_render)" ]]
}

# Install the group, the sudoers rule and the dir perms. Idempotent, root only,
# never fails the caller: a box where any step does not land keeps the old
# root:claude 2770 shape, because a locked board without the hop rule would cut
# every seat off it. ORDER IS THE SAFETY: the rule is installed and validated
# BEFORE the dir changes group.
# Args: <dir> (default: the production board dir). Any other dir is a harness
# or scratch store and always gets the old shape.
board_lockdown() {
  local dir="${1:-$_BOARD_PROD_DIR}" grp="claude" tmp
  (( ${_BOARD_EUID:-$EUID} == 0 )) || return 0
  [[ -d "$dir" ]] || return 0
  if [[ "$dir" == "$_BOARD_PROD_DIR" && ! -e "$FIVEDIVE_BOARD_UNLOCK_MARKER" ]]; then
    grp="$FIVEDIVE_BOARD_GROUP"
    if ! _board_group_exists && ! groupadd --system "$FIVEDIVE_BOARD_GROUP" >/dev/null 2>&1; then
      warn "DIVE-9001: could not create group $FIVEDIVE_BOARD_GROUP; the task board stays open to group claude"
      grp="claude"
    fi
    if [[ "$grp" != claude ]] && ! [[ -L "$FIVEDIVE_BOARD_HOP_PATH" && "$FIVEDIVE_BOARD_HOP_PATH" -ef "$FIVEDIVE_BOARD_BIN" ]]; then
      mkdir -p "${FIVEDIVE_BOARD_HOP_PATH%/*}" \
        && ln -sfn "$FIVEDIVE_BOARD_BIN" "$FIVEDIVE_BOARD_HOP_PATH" \
        || { warn "DIVE-9001: could not link $FIVEDIVE_BOARD_HOP_PATH; the task board stays open to group claude"; grp="claude"; }
    fi
    if [[ "$grp" != claude ]] && ! _board_sudoers_current; then
      tmp="$(mktemp "${TMPDIR:-/tmp}/5dive-board-sudoers.XXXXXX")"
      board_sudoers_render >"$tmp"
      if visudo -cf "$tmp" >/dev/null 2>&1 \
         && install -m 0440 -o root -g root "$tmp" "$FIVEDIVE_BOARD_SUDOERS"; then
        :
      else
        warn "DIVE-9001: the sudoers rule for the task board did not validate; the board stays open to group claude"
        grp="claude"
      fi
      rm -f "$tmp"
    fi
    # The box's admin user is root-equivalent already (NOPASSWD ALL). Its
    # crons back the board up (5dive-tasks-backup.sh) and its dashboard reads
    # it, so it keeps direct access through membership.
    if [[ "$grp" != claude ]] && id claude >/dev/null 2>&1 \
       && [[ " $(id -nG claude 2>/dev/null) " != *" $FIVEDIVE_BOARD_GROUP "* ]]; then
      usermod -aG "$FIVEDIVE_BOARD_GROUP" claude >/dev/null 2>&1 || true
    fi
  fi
  chgrp -R "$grp" "$dir" 2>/dev/null || true
  find "$dir" -type d -exec chmod g+s {} + 2>/dev/null || true
  chown root:"$grp" "$dir"
  chmod 2770 "$dir"
}

# Top level of the built bundle only (a harness that sources this file has
# BASH_SOURCE != $0 and gets the functions without the side effects).
if [[ "${BASH_SOURCE[0]-}" == "$0" ]]; then
  if [[ "${1:-}" == "--board-hopped" ]]; then
    shift
    _board_hopped_enter "$@"
  elif (( EUID != 0 )) && [[ -d "$_BOARD_PROD_DIR" ]]; then
    _board_neutralise_seat_config
  fi
  if (( FIVE_BOARD_HOPPED == 0 )) && _board_hop_needed "$0" "$@"; then
    exec sudo -n -g "$FIVEDIVE_BOARD_GROUP" -- "$FIVEDIVE_BOARD_HOP_PATH" --board-hopped "$@"
  fi
fi
