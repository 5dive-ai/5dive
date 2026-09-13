#!/usr/bin/env bash
# --- gh CONFIG DIR for a run that carries its own credential. DIVE-4341. ---
#
# THE DEFECT. `gh` loads its config BEFORE it consults GH_TOKEN. On a provisioned
# 5dive box `scripts/install/users.sh` writes /etc/profile.d/5dive-shared-configs.sh,
# which exports GH_CONFIG_DIR=/home/claude/.config/gh (and XDG_CONFIG_HOME) into every
# claude-group login shell — and `gh` creates hosts.yml 0600 no matter what umask the
# profile sets. So under ANY agent-<seat> uid every gh invocation dies at
#
#   failed to load config: open /home/claude/.config/gh/config.yml: permission denied
#
# before the token the CLI just resolved for it is looked at. That is why the DIVE-1830
# merge gate records EVERY agent-seat close UNVERIFIED on every customer box
# (`merge-gate HELD a rail but the repo scan FAILED (partial-repo-scan-0-of-11)`), and
# why `task start` preflight says gh "isn't logged in" while claude's gh IS. The token
# arms were never broken: `merge-gate-selftest` prints
# `[4 sudo -u claude gh auth token] RESOLVED` four lines after `this seat CANNOT query
# GitHub`. It resolves the token and then cannot use it.
#
# THE FIX IS NOT A CHMOD. Widening /home/claude/.config/gh/hosts.yml to 0640 hands the
# live OAuth token to every uid in group `claude`, which is the isolation the per-seat
# push design exists to keep. gh needs NO shared config when GH_TOKEN is set — so give
# the invocation a config dir this uid can actually read, and leave claude's alone.
#
# WHY THIS CANNOT CHANGE A WORKING SEAT. `gh_config_dir` returns the seat's own
# effective dir UNCHANGED whenever that dir is usable, which is every seat on which gh
# works today (claude's own, this control plane, CI, root). The substitution fires only
# where gh currently dies with a config error — so it can convert a failed call into an
# answered one and nothing else. Same contract as DIVE-2605's bot rail.
#
# WHY NOT A FIXED PATH IN /tmp. A predictable world-writable path is a planting target:
# another seat in group `claude` could pre-create it with a hosts.yml naming a token of
# its choosing and silently redirect this seat's gh. That is the same cross-seat
# exposure the chmod route was rejected for, in the other direction — it is the trap the
# on-host fix hit when its `mkdir -p` inherited `umask 002` and produced a 0775
# group-writable dir. So: the seat's own $HOME, verified OWNED BY THIS UID and not
# group/other-writable after creation, and an unpredictable `mktemp -d` when it is not.

# _gh_cfg_effective — the dir THIS process's gh would use, with no override applied.
# Mirrors gh's own resolution order: GH_CONFIG_DIR, then XDG_CONFIG_HOME/gh, then
# ~/.config/gh. Prints empty when none of them can be named (no HOME, no XDG).
_gh_cfg_effective() {
  if [[ -n "${GH_CONFIG_DIR:-}" ]]; then printf '%s' "$GH_CONFIG_DIR"; return 0; fi
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then printf '%s' "${XDG_CONFIG_HOME%/}/gh"; return 0; fi
  [[ -n "${HOME:-}" ]] && { printf '%s' "${HOME%/}/.config/gh"; return 0; }
  printf ''
}

# gh_config_dir_usable <dir> — 0 when gh started by THIS uid could load its config
# from <dir>.
#
# ABSENT IS NOT UNUSABLE: gh creates the dir on first run, so an absent dir is fine
# exactly when its parent is writable here. That keeps a fresh seat with no gh state
# on the unchanged path.
#
# PRESENT means the dir must be readable AND traversable, and each of the two files gh
# opens must be readable IF IT EXISTS — config.yml is the one named in the customer
# error, hosts.yml is the one gh pins to 0600 and the one that actually holds the
# credential. A file that is absent is not a failure; a file that exists and cannot be
# read is the whole ticket.
gh_config_dir_usable() {
  local d="${1:-}" f
  [[ -n "$d" ]] || return 1
  if [[ ! -d "$d" ]]; then
    # gh creates the WHOLE path (MkdirAll), so walk up to the nearest ancestor that
    # exists and ask whether we could create under it. Stopping at the immediate
    # parent called a fresh seat's ~/.config/gh unusable, which pushed a seat with no
    # gh state at all onto the substitution path for nothing.
    local parent="$d"
    while [[ -n "$parent" && ! -d "$parent" ]]; do
      local up="${parent%/*}"
      [[ "$up" == "$parent" ]] && up=""
      parent="${up:-/}"
      [[ "$parent" == "/" ]] && break
    done
    [[ -d "$parent" && -w "$parent" && -x "$parent" ]]
    return
  fi
  [[ -r "$d" && -x "$d" ]] || return 1
  for f in config.yml hosts.yml; do
    [[ -e "$d/$f" && ! -r "$d/$f" ]] && return 1
  done
  return 0
}

# _gh_cfg_owned_private <dir> — 0 when <dir> exists, is owned by this euid, and is not
# writable by group or other. Refuses to trust a directory somebody else can plant in;
# see the header. `stat -c` is coreutils and every 5dive host is Linux — a BSD stat
# would print nothing for -c and the empty comparison below fails closed, which is the
# right polarity for a trust check.
_gh_cfg_owned_private() {
  local d="${1:-}" owner mode
  [[ -n "$d" && -d "$d" ]] || return 1
  owner=$(stat -c '%u' "$d" 2>/dev/null || printf '')
  [[ -n "$owner" && "$owner" == "$(id -u 2>/dev/null || printf 'x')" ]] || return 1
  mode=$(stat -c '%a' "$d" 2>/dev/null || printf '')
  [[ ${#mode} -eq 3 ]] || mode="0${mode}"
  [[ -n "$mode" ]] || return 1
  # group and other write bits must both be clear
  (( (8#$mode & 0022) == 0 ))
}

# gh_config_dir — the dir to hand gh for an invocation that carries its own token.
#
# Memoised per process: the answer cannot change mid-run, and several gate call sites
# ask for it per PR in a scan.
_FIVE_GH_CFG_DIR=""
_FIVE_GH_CFG_SHADOWED=""
gh_config_dir() {
  if [[ -n "$_FIVE_GH_CFG_DIR" ]]; then printf '%s' "$_FIVE_GH_CFG_DIR"; return 0; fi
  local eff seat
  eff="$(_gh_cfg_effective)"
  if [[ -n "$eff" ]] && gh_config_dir_usable "$eff"; then
    _FIVE_GH_CFG_DIR="$eff"; _FIVE_GH_CFG_SHADOWED="no"
    printf '%s' "$_FIVE_GH_CFG_DIR"; return 0
  fi
  # The effective dir is unreadable here. Prefer a stable seat-owned one so repeated
  # runs do not each pay a fresh dir, and fall back to an unpredictable private temp
  # when $HOME cannot give us one we are allowed to trust.
  if [[ -n "${HOME:-}" && -d "$HOME" ]]; then
    seat="${HOME%/}/.config/gh"
    # The subshell around umask is load-bearing: without it the dir inherits the
    # profile's `umask 002` and lands 0775 group `claude`, i.e. plantable by every
    # sibling seat. `-d` short-circuits, so a dir created wrong earlier is NOT
    # silently adopted — _gh_cfg_owned_private below is what decides.
    [[ -d "$seat" ]] || (umask 077; mkdir -p "$seat" 2>/dev/null) || true
    if _gh_cfg_owned_private "$seat" && gh_config_dir_usable "$seat"; then
      _FIVE_GH_CFG_DIR="$seat"; _FIVE_GH_CFG_SHADOWED="yes"
      printf '%s' "$_FIVE_GH_CFG_DIR"; return 0
    fi
  fi
  # $HOME could not give us one. Fall back to a per-PROCESS dir under TMPDIR.
  #
  # It is named rather than `mktemp -d` on purpose: every caller reaches this through
  # a command substitution, so the memo above lives in a subshell and dies with it —
  # a fresh mktemp per call would leak one directory per gh invocation, and a repo
  # scan makes a lot of those. `$$` is the TOP-LEVEL pid even inside `$( )`, which is
  # exactly the property needed (the `_GATE_TOK_TRACEF` idiom next door, same reason).
  # Predictable is safe here only BECAUSE of the ownership check: `mkdir` fails if the
  # path already exists, and a pre-planted one is then refused rather than adopted.
  seat="${TMPDIR:-/tmp}/.5dive-gh-cfg.$(id -u 2>/dev/null || printf 'x').$$"
  [[ -d "$seat" ]] || (umask 077; mkdir -p "$seat" 2>/dev/null) || true
  if _gh_cfg_owned_private "$seat" && gh_config_dir_usable "$seat"; then
    _FIVE_GH_CFG_DIR="$seat"; _FIVE_GH_CFG_SHADOWED="yes"
    printf '%s' "$_FIVE_GH_CFG_DIR"; return 0
  fi
  # Nothing worked. Hand back the effective dir unchanged rather than inventing a
  # path: the call then fails exactly the way it fails today, which is a known state.
  _FIVE_GH_CFG_DIR="$eff"; _FIVE_GH_CFG_SHADOWED="no"
  printf '%s' "$_FIVE_GH_CFG_DIR"
}

# gh_config_dir_shadowed — 0 when gh_config_dir REPLACED an unreadable dir on this
# seat. Diagnostics only; it is what lets `merge-gate-selftest`, `doctor` and the
# gate's own crumbs say "the shared gh config was unreadable here, so this run used
# its own" instead of leaving the reader to guess.
gh_config_dir_shadowed() {
  [[ -n "$_FIVE_GH_CFG_SHADOWED" ]] || gh_config_dir >/dev/null
  [[ "$_FIVE_GH_CFG_SHADOWED" == "yes" ]]
}

# gh_config_note — one clause for a diagnostic line, or empty when nothing was
# substituted. Empty on the unchanged path so no existing message grows a sentence
# about a thing that did not happen.
gh_config_note() {
  gh_config_dir_shadowed || { printf ''; return 0; }
  printf "the shared gh config dir (%s) is not readable by this uid, so gh ran with its own (%s) — the token is unaffected (DIVE-4341)" \
    "$(_gh_cfg_effective)" "$(gh_config_dir)"
}

# gh_credential_rail — WHICH rail could authenticate a GitHub call from this seat,
# as one token: env | own | claude | bot | none.
#
# Added for the `task start` preflight (DIVE-4341), which asked `gh auth status` and
# nothing else and so warned "a push will prompt/fail" on every agent seat of every
# provisioned box — seats that push through the delegated rail all day. A warning that
# is wrong on every seat it fires on trains people to ignore the ones that are right,
# which is the second half of this ticket and the more expensive half.
#
# Ordered cheapest-first and short-circuits, so the sudo probes are only paid by a seat
# that really holds nothing of its own. Read-only: `auth token` and `sudo -n -l` make
# no network call and change nothing.
gh_credential_rail() {
  [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]] && { printf 'env'; return 0; }
  command -v gh >/dev/null 2>&1 || { printf 'none'; return 0; }
  GH_CONFIG_DIR="$(gh_config_dir)" gh auth token >/dev/null 2>&1 && { printf 'own'; return 0; }
  if command -v sudo >/dev/null 2>&1; then
    [[ -n "$(sudo -n -u claude gh auth token 2>/dev/null || true)" ]] && { printf 'claude'; return 0; }
    [[ -x /usr/local/bin/5dive ]] && sudo -n -l /usr/local/bin/5dive _gh_do >/dev/null 2>&1 \
      && { printf 'bot'; return 0; }
  fi
  printf 'none'
}
