create_agent_user() {
  # DIVE-1002: least-privilege by default — callers pass an explicitly resolved
  # tier (cmd_create resolves standard-by-default + bootstrap-admin). The
  # fallback here is 'standard', never 'admin', so no path silently grants root.
  local name="$1" isolation="${2:-standard}" can_push="${3:-0}"
  local can_deploy="${4:-0}"     # INST-5: the broker's delegated-deploy surface
  local user="agent-${name}"
  if ! id -u "$user" &>/dev/null; then
    adduser --disabled-password --gecos "" "$user" >/dev/null
  fi
  # Admin/standard join the claude group (shared workspace access); sandboxed stays isolated.
  local groups="systemd-journal"
  [[ "$isolation" != "sandboxed" ]] && groups="claude,systemd-journal"
  usermod -aG "$groups" "$user"
  # DIVE-1033: sandboxed agents are NOT in the claude group, so /home/claude
  # (0750) is unreachable — but the shared runtime lives there (claude at
  # ~/.local/bin, node at ~/.nvm). Without traverse access both the plugin
  # install (install_channel_plugin_for_agent runs as the agent user) and
  # 5dive-agent-start fail to exec claude ("Permission denied"). Grant
  # traverse-ONLY (--x: no read, no directory listing) on /home/claude so the
  # agent can exec binaries by their known path while still being unable to
  # enumerate or read claude's home; secrets stay behind their own 0600/0700
  # perms, unreachable. bun lives in /usr/local/bin (world-rx) so needs no grant.
  # The real fix (relocate the runtime out of /home/claude) is DIVE-1034.
  if [[ "$isolation" == "sandboxed" ]]; then
    if ! setfacl -m "u:${user}:--x" /home/claude 2>/dev/null; then
      warn "setfacl failed granting ${user} traverse on /home/claude (is the 'acl' package installed?); the sandboxed agent will not reach the shared runtime — plugin install and startup will fail (DIVE-1033)"
    fi
  fi
  # Admin gets sudo SCOPED to fleet-management ops (not blanket root). standard
  # gets a NARROW grant for real-time inter-agent send (DIVE-1065: ONLY the
  # hardened `5dive agent _deliver` subcommand, nothing else). sandboxed gets no
  # sudoers at all. All branches keep the visudo-validated discipline.
  if [[ "$isolation" == "admin" ]]; then
    write_admin_sudoers "$user"
  elif [[ "$isolation" == "standard" ]]; then
    write_standard_sudoers "$user" "$can_push" "$can_deploy"
  else
    rm -f "/etc/sudoers.d/${user}"
  fi
  seed_agent_git_identity "$name"
}

# DIVE-2051: give every agent user an EXPLICIT, non-personal git identity at
# provisioning time, so who authors a commit is never left to be inferred.
#
# The gap this closes: git refuses to commit with no identity ("Please tell me
# who you are"), which puts an agent one step from resolving one itself — and
# the most available value on the box is the operator's personal email, because
# Claude Code injects it into every agent's system prompt BY DEFAULT with no
# opt-out (anthropics/claude-code#81138, where it bit a user upstream by
# overwriting their repo's anonymized commit email with their personal one). A
# box with a deliberate identity never reaches that step. This is not
# hypothetical downstream: `5dive proof publish` authors PUBLIC commits with
# whatever identity it finds, on a daily cron.
#
# Deliberately NON-CLOBBERING: an identity the operator already set always wins,
# on a fresh create and on a re-run. Deliberately synthetic and obviously so —
# nobody should mistake it for a real mailbox — and a repo with an author policy
# of its own can still override it per-checkout (`git config user.email`).
_agent_git_identity_email() { printf 'agent-%s@agents.noreply.5dive.ai\n' "$1"; }

seed_agent_git_identity() {
  local name="$1" user="agent-${1}"
  command -v git >/dev/null 2>&1 || return 0
  id -u "$user" &>/dev/null || return 0
  local have_name have_email
  have_name="$(sudo -u "$user" -H git config --global user.name 2>/dev/null || true)"
  have_email="$(sudo -u "$user" -H git config --global user.email 2>/dev/null || true)"
  [[ -n "$have_name" && -n "$have_email" ]] && return 0
  # A half-set identity is completed rather than left alone: git fills the
  # missing half from the environment (user@hostname), which is the same guess
  # this exists to prevent.
  if [[ -z "$have_name" ]]; then
    sudo -u "$user" -H git config --global user.name "5dive agent ${name}" 2>/dev/null \
      || warn "could not set a git identity for ${user}; it will have to resolve one itself before it can commit, and the most available value is the operator's personal email (DIVE-2051)"
  fi
  if [[ -z "$have_email" ]]; then
    sudo -u "$user" -H git config --global user.email "$(_agent_git_identity_email "$name")" 2>/dev/null \
      || warn "could not set a git email for ${user} (DIVE-2051)"
  fi
  return 0
}

# DIVE-1002: an 'admin' agent can run the company, not `rm -rf` the box. Its sudo
# is scoped to a single mediated surface — the 5dive CLI (the sanctioned API for
# create/rm/provision/restart agents and box ops). Service lifecycle (start|stop|
# restart of the box's 5dive systemd units) is done THROUGH the CLI, which is
# already root under this grant, so no raw `systemctl` entry is required.
#
# DIVE-1088: the previous version also granted raw `systemctl <verb> 5dive-agent@*`
# / `5dive-*.service`. sudo-rs (visudo-rs, the DEFAULT sudo on Ubuntu 26.04) REJECTS
# wildcards INSIDE a command argument ("wildcards are not allowed in command
# arguments"), so those lines made `5dive agent create` (default admin isolation)
# fail on 26.04 with no partial install. A bare trailing `*` (any-args, e.g.
# `/usr/local/bin/5dive *`) IS accepted by sudo-rs — that's why standard isolation
# worked. Fix: drop the raw systemctl lines (redundant — the CLI runs systemctl
# internally as root via `5dive *`, and `5dive agent restart|start|stop` +
# `5dive agent _svc <verb> <5dive-unit>` cover every case the raw grant did),
# leaving only sudo-rs-valid bare-`*` forms.
#
# What is deliberately NOT granted, and why (all are one-line root escapes):
#   - `systemd-run *`    runs ANY command as root (`systemd-run --pty bash`) —
#                        a wildcard on it == NOPASSWD: ALL. Agents that need a
#                        deferred self-restart use `5dive agent restart --defer`,
#                        which runs systemd-run internally under the already-root
#                        CLI, so no raw grant is required.
#
# DIVE-2079 — say this outright, because two agents read the `systemd-run *` line
# above as a claim about the grant this function WRITES and concluded their own
# `/usr/local/bin/5dive *` was equivalent to `NOPASSWD: ALL`:
#
#   It is not, and the difference is not the wildcard. `systemd-run *` collapses
#   to full root because systemd-run's PURPOSE is to exec an arbitrary command as
#   root — any argument wildcard on such a binary hands over everything. The
#   5dive CLI is the opposite case: it is only as wide as its own subcommands,
#   and the standing invariant stated below (no 5dive subcommand may exec
#   agent-controlled input as root) is precisely what keeps `5dive *` from
#   collapsing the same way. The invariant is load-bearing, not decorative — the
#   day one subcommand execs caller input as root, `cli-root` DOES become
#   `root-all` and this grant stops being a boundary.
#
#   What this grant genuinely does NOT give is a runas target. Every line this
#   function and render_standard_sudoers write is `(root)` only, so neither an
#   admin nor a standard agent can `sudo -u claude ...` — they cannot borrow the
#   `claude` user's authenticated gh/GitHub identity. A legacy pre-DIVE-1002
#   `(ALL) NOPASSWD: ALL` agent can. That runas breadth, not the command
#   scoping, is the real split between the two populations that both report
#   `isolation=admin` today, which is why agent_sudo_grant reports runas
#   separately from class.
#   - `journalctl *`     pages through less by default -> `!sh` GTFOBins escape.
#                        Logs go through `5dive agent logs` (--no-pager path).
#   - `systemctl status` also pages by default -> same `!sh` escape. Service
#                        lifecycle goes through the non-paging `5dive agent _svc`.
#   - `sudo bash|su|-u <x> -i` — direct root/other-user shells.
# Granting the whole `5dive` CLI as root makes it a standing invariant that NO
# 5dive subcommand may exec agent-controlled input as root (else it becomes an
# admin->root vector). See DIVE-756/916 (sudo reduction), DIVE-950 (forge).
#
# The file is `visudo -c` validated before install so a malformed entry can never
# lock the box out; on failure we remove it and fail loudly.
write_admin_sudoers() {
  local user="$1" f="/etc/sudoers.d/${user}" tmp
  tmp=$(mktemp)
  # Only bare-trailing-`*` (any-args) forms — the single wildcard shape sudo-rs
  # accepts (DIVE-1088). The CLI-as-root grant covers all fleet + service ops.
  cat > "$tmp" <<SUDOERS
# Managed by 5dive (DIVE-1002/1088). Fleet-management scope for admin agent ${user}.
# Do not edit by hand; regenerated on agent create/provision.
${user} ALL=(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *
SUDOERS
  chmod 440 "$tmp"
  if visudo -cf "$tmp" >/dev/null 2>&1; then
    chown root:root "$tmp"
    mv "$tmp" "$f"
    chmod 440 "$f"
  else
    rm -f "$tmp"
    fail "$E_GENERIC" "generated sudoers for ${user} failed visudo validation; aborting (no partial install)"
  fi
}

# DIVE-2079: read back a user's ENFORCED sudo grant and classify it — the inverse
# of the two writers above, so `agent info` can report what an agent can actually
# do rather than only the label the registry happens to store.
#
# Why this exists: `isolation` in the registry is a STORED LABEL, not a
# measurement, and nothing keeps it honest. The DIVE-1002 v1->v2 migration
# stamped isolation:"admin" on every pre-existing agent WITHOUT looking at its
# sudoers file, so an agent provisioned before least-privilege (blanket
# `(ALL) NOPASSWD: ALL`) reports the same `admin` as one provisioned after it
# (the CLI-scoped grant write_admin_sudoers emits). Measured 2026-07-26 on
# poke-two: agent-dev/main/olivia/marketing/community/creative are the former,
# agent-dev2/dev3/codex/don the latter, and `agent info` called all of them
# admin. Two agents reasoned about their own privilege from that label and got
# it wrong in OPPOSITE directions. A label that cannot be wrong is worth more
# than one that is convenient, so we now report the measurement beside it.
#
# Classes, in DESCENDING breadth (classify_sudo_grant reports the widest match):
#   root-all   `NOPASSWD: ALL` — any command. WIDER than today's `admin`.
#   cli-root   the whole 5dive CLI as root — exactly what `admin` means today.
#   cli-scoped only the named hidden subcommands render_standard_sudoers emits
#              (`agent _deliver|_capture|_self_restart`, `_audit_append`, and
#              `_push_do` under --can-push) — what `standard` means.
#   none       no sudoers entries at all — what `sandboxed` means.
#   custom     entries matching none of the above (hand-edited / drifted).
#   unknown    not measurable from where this ran (see sudo_grant_lines).
#
# Runas breadth is reported SEPARATELY because it, not the command scoping, is
# what actually separates the two `admin` populations in practice: every grant
# this CLI writes is `(root)` only, so a standard-or-modern-admin agent cannot
# `sudo -u claude ...` at all, while a legacy `(ALL)` agent can become any user
# on the box — including `claude`, whose gh credential is the human's GitHub
# identity. That is the difference an operator is really asking about.

# Emit the raw grant lines for a user on stdout; rc=1 if unmeasurable from here.
#
# Precedence is deliberate: `sudo -l` is the AUTHORITATIVE answer (it resolves
# /etc/sudoers, group entries and drop-ins together), so we prefer it and only
# fall back to reading the managed drop-in directly.
#
# SUDOERS_D overridden by the caller means "measure from these files only" —
# that is the test seam, and it also stops a root-run harness from consulting
# the live policy for a fixture user that does not exist.
#
# DIVE-2152: that contract is enforced by ONE predicate, used by BOTH escalating
# paths — the `sudo -l` below and the privileged dump. Every way of asking a
# more-powerful process to answer is gated on the dir being the real one, so an
# overridden SUDOERS_D cannot mean "these files, unless the caller can escalate
# past the permissions the fixture set". Escalation defeats a fixture's mode
# bits, so without this the same commit reads 37/0 as a cli-scoped caller and
# 30/7 as a full-sudo one — a harness grading its runner, not the code. A stub
# fixes that per harness and must be REMEMBERED; the predicate fixes the class.
sudoers_dir_is_real() { [[ "${1:-}" == "/etc/sudoers.d" ]]; }

sudo_grant_lines() {
  local user="$1" d="${SUDOERS_D:-/etc/sudoers.d}" out=""
  if sudoers_dir_is_real "$d"; then
    # root may list any user; a non-root caller may list only itself, and that
    # answer is authoritative for it (this is the `sudo -n -l` an agent is told
    # to run on itself). -n so a policy needing a password never blocks `info`.
    if [[ "$(id -u)" == "0" ]]; then
      if out=$(sudo -n -l -U "$user" 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
    elif [[ "$user" == "$(id -un)" ]]; then
      if out=$(sudo -n -l 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
    fi
  fi
  [[ -r "${d}/${user}" ]] && { cat "${d}/${user}"; return 0; }
  # Drop-in absent AND the directory readable => genuinely no managed grant.
  # (An UNREADABLE directory is not evidence of absence — that is `unknown`.)
  [[ -r "$d" && ! -e "${d}/${user}" ]] && return 0
  # DIVE-2135: everything above is CALLER-SCOPED, and /etc/sudoers.d is 0700
  # root, so for any realistic non-root caller every PEER fell out here as
  # `unknown` — measured by olivia 2026-07-27 as agent-olivia AND as `claude`
  # (the dashboard's caller). Honest, but the three-populations-render-
  # identically problem DIVE-2079/2088 exist to solve is only un-lied-about,
  # not solved, until the measurement can actually see a peer. Last resort: ask
  # sudo to do the read. Fails closed to `unknown` (rc=1) by every path.
  sudo_grant_lines_privileged "$user" "$d"
}

# --- DIVE-2135: the privileged read -----------------------------------------
#
# One protocol serves both readers. The dump is only trusted when it is
# COMPLETE: it opens with an OK marker and closes with an END marker, and a
# missing END discards the WHOLE dump. That is the absent-vs-forbidden
# discipline (DIVE-2120) surviving batching — a read that half-succeeded must
# never let the entries it could not cover inherit the ones it could, because
# "no file for this user" means `none` ONLY if the whole directory was seen.
_SUDOERS_DUMP_OK='===5DIVE-SUDOERS-DUMP-OK'
_SUDOERS_DUMP_END='===5DIVE-SUDOERS-DUMP-END'
_SUDOERS_DUMP_FILE='===5DIVE-SUDOERS-FILE:'

# The one place a privileged read is attempted — the seam a test overrides so
# the harness never depends on the real sudo policy of whoever runs it (that
# caller-scoping is the defect under repair; a test that inherits it grades the
# runner, not the code). Args are passed POSITIONALLY to sh, never interpolated
# into the snippet, so a name can never become shell.
#
# NOT attempted as root: root already got an authoritative `sudo -l -U` above,
# and re-entering sudo would only turn a settled answer into a second exec.
#
# NOT attempted for any directory but the real one (DIVE-2152) — the guard lives
# HERE, at the single seam, rather than at the two call sites, for two reasons:
# it covers `sudo_grant_batch_load`'s call as well as `sudo_grant_lines`', and a
# harness that overrides the seam still reaches the whole fallback path with a
# fixture dir, because its stub replaces the function this guard sits inside.
# Confinement and testability are not in tension; placement is what reconciles
# them. In production SUDOERS_D is never set, so this costs no real capability.
sudoers_privileged_dump() {
  local dir="$1" one="${2:-}"
  sudoers_dir_is_real "$dir" || return 1
  [[ "$(id -u)" == "0" ]] && return 1
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n /bin/sh -c '
    d=$1; one=$2
    [ -d "$d" ] || exit 3
    printf "%s\n" "'"$_SUDOERS_DUMP_OK"'"
    if [ -n "$one" ]; then
      if [ -f "$d/$one" ]; then
        printf "%s%s\n" "'"$_SUDOERS_DUMP_FILE"'" "$one"
        cat "$d/$one" || exit 4
      fi
    else
      for f in "$d"/*; do
        [ -f "$f" ] || continue
        printf "%s%s\n" "'"$_SUDOERS_DUMP_FILE"'" "${f##*/}"
        cat "$f" || exit 4
      done
    fi
    printf "%s\n" "'"$_SUDOERS_DUMP_END"'"
  ' sh "$dir" "$one" 2>/dev/null
}

# rc=0 only for a dump that is well-formed AND complete.
_sudoers_dump_valid() {
  [[ "$1" == "$_SUDOERS_DUMP_OK"* ]] || return 1
  [[ "$1" == *"$_SUDOERS_DUMP_END" ]] || return 1
  return 0
}

# Per-user privileged read — the `agent info` path, which resolves ONE agent and
# so pays the exec once. Echoes the drop-in (empty output = the directory was
# fully seen and holds no file for this user, i.e. a real `none`); rc=1 when the
# read was denied or unavailable, which the caller renders as `unknown`.
sudo_grant_lines_privileged() {
  local user="$1" d="$2" dump=""
  # A batch already loaded by `agent list` answers without another exec.
  if [[ "${_SUDOERS_BATCH_STATE:-}" == "ok" ]]; then
    printf '%s' "${_SUDOERS_BATCH[$user]:-}"
    return 0
  fi
  [[ "${_SUDOERS_BATCH_STATE:-}" == "failed" ]] && return 1
  dump=$(sudoers_privileged_dump "$d" "$user") || return 1
  _sudoers_dump_valid "$dump" || return 1
  _sudoers_dump_extract "$dump" "$user"
  return 0
}

# Echo one user's lines out of a validated dump. No output is a legitimate
# answer here (`none`), which is why validity is decided by the caller BEFORE
# this runs and never inferred from emptiness.
_sudoers_dump_extract() {
  local dump="$1" want="$2" line cur="" out=""
  while IFS= read -r line; do
    case "$line" in
      "$_SUDOERS_DUMP_FILE"*) cur="${line#"$_SUDOERS_DUMP_FILE"}"; continue ;;
      "$_SUDOERS_DUMP_OK"|"$_SUDOERS_DUMP_END") continue ;;
    esac
    [[ "$cur" == "$want" ]] && out+="$line"$'\n'
  done <<<"$dump"
  printf '%s' "$out"
}

# Batched privileged read for the SURVEY reader (`agent list`).
#
# WHY list batches and info does not — expect this question, it is not an
# inconsistency to tidy away: sharing the MEASUREMENT (`sudo_grant_lines` stays
# the one instrument for both readers — that is the whole point of DIVE-2088, and
# a second cheaper measurement under a friendlier name is the defect DIVE-2079
# removed) does not oblige sharing the CALL PATTERN. `info` resolves one agent
# and pays one exec; `list` resolves the fleet — 16 agents on this host today —
# so a per-row fallback would write 16 auth-log rows EVERY TIME anyone runs the
# survey. The cost that bites is not latency, it is making the honest-fleet-
# survey feature the noisiest writer in the audit log, whose predictable end
# state is someone silencing it and taking the honesty with it.
#
# Idempotent per process; `_SUDOERS_BATCH_STATE=failed` is remembered so a
# denied dir is not re-probed once per row.
sudo_grant_batch_load() {
  local d="${SUDOERS_D:-/etc/sudoers.d}" dump="" line cur=""
  [[ -n "${_SUDOERS_BATCH_STATE:-}" ]] && return 0
  declare -gA _SUDOERS_BATCH=()
  # Nothing to gain where the plain read already works (a readable dir — which
  # includes every root caller, whose per-row `sudo -l -U` is authoritative and
  # never reaches the fallback): keep those on the per-row path untouched. The
  # test is the DIRECTORY's readability, not who the caller is, so a harness
  # grades this code rather than the sudo policy of whoever ran it.
  if [[ -r "$d" ]]; then _SUDOERS_BATCH_STATE="skip"; return 0; fi
  if ! dump=$(sudoers_privileged_dump "$d") || ! _sudoers_dump_valid "$dump"; then
    # Denied, unavailable, or truncated => EVERY row reports `unknown`. Never
    # the stored label, never a measured `none`.
    _SUDOERS_BATCH_STATE="failed"; return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      "$_SUDOERS_DUMP_FILE"*) cur="${line#"$_SUDOERS_DUMP_FILE"}"; _SUDOERS_BATCH[$cur]=""; continue ;;
      "$_SUDOERS_DUMP_OK"|"$_SUDOERS_DUMP_END") continue ;;
    esac
    [[ -n "$cur" ]] && _SUDOERS_BATCH[$cur]+="$line"$'\n'
  done <<<"$dump"
  _SUDOERS_BATCH_STATE="ok"
}

# Test seam / long-lived-process hygiene: forget a loaded batch.
sudo_grant_batch_reset() { unset _SUDOERS_BATCH_STATE; declare -gA _SUDOERS_BATCH=(); }

# Classify grant lines read from stdin. Echoes `class|runas|extra`:
#   class  one of the classes documented above (never `unknown` — the caller
#          decides that from sudo_grant_lines' rc, since no output legitimately
#          means `none`).
#   runas  `any` if any entry allows an ALL runas (can become any user incl.
#          claude), else `root`, else `-` when there are no entries.
#   extra  1 when unrecognised entries exist ALONGSIDE a wider recognised one,
#          so a drifted grant is never silently absorbed into a known class.
#
# Parses both shapes with one pass, since both carry `(runas)` then commands:
#   sudoers file  `agent-x ALL=(root) NOPASSWD: /usr/local/bin/5dive, ...`
#   sudo -l       `    (root) NOPASSWD: /usr/local/bin/5dive, ...`
# `sudo -l`'s "Matching Defaults entries" preamble carries no parens, so it is
# skipped by the same test.
classify_sudo_grant() {
  local line runas cmds cmd
  local has_all=0 has_cli=0 has_a2a=0 has_other=0 any=0 runas_any=0
  while IFS= read -r line; do
    line="${line%%#*}"
    [[ "$line" == *"("*")"* ]] || continue
    runas="${line#*\(}"; runas="${runas%%\)*}"
    cmds="${line#*\)}"
    cmds="${cmds#*:}"   # drop the NOPASSWD:/PASSWD: tag; a no-colon tail is unchanged
    # Split on commas WITHOUT word-splitting: a grant legitimately contains `*`
    # and IFS-splitting an unquoted `$cmds` would glob-expand it against the cwd.
    while [[ -n "$cmds" ]]; do
      case "$cmds" in
        *,*) cmd="${cmds%%,*}"; cmds="${cmds#*,}" ;;
        *)   cmd="$cmds"; cmds="" ;;
      esac
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
      [[ -n "$cmd" ]] || continue
      any=1
      [[ "$runas" == *ALL* ]] && runas_any=1
      case "$cmd" in
        ALL)                                            has_all=1 ;;
        "/usr/local/bin/5dive"|"/usr/local/bin/5dive *") has_cli=1 ;;
        "/usr/local/bin/5dive agent _deliver"*|"/usr/local/bin/5dive agent _capture"*|\
        "/usr/local/bin/5dive agent _self_restart"*|"/usr/local/bin/5dive _audit_append"*|\
        "/usr/local/bin/5dive _push_do"*|\
        "/usr/local/bin/5dive _gh_do"*)                  has_a2a=1 ;;
        *)                                              has_other=1 ;;
      esac
    done
  done
  local class extra=0
  if   (( has_all )); then class="root-all"
  elif (( has_cli )); then class="cli-root"
  elif (( has_a2a )); then class="cli-scoped"
  elif (( has_other )); then class="custom"
  else class="none"
  fi
  [[ "$class" != "custom" ]] && (( has_other )) && extra=1
  local runas="-"
  (( any )) && { runas="root"; (( runas_any )) && runas="any"; }
  printf '%s|%s|%s\n' "$class" "$runas" "$extra"
}

# The isolation label each class WOULD justify. `root-all` maps to no label at
# all: nothing this CLI can provision is that wide, so it is named for what it
# is rather than rounded down to the nearest label an operator would misread.
isolation_implied_by_grant() {
  case "$1" in
    root-all) printf 'beyond-admin\n' ;;
    cli-root) printf 'admin\n' ;;
    cli-scoped) printf 'standard\n' ;;
    none)     printf 'sandboxed\n' ;;
    custom)   printf 'custom\n' ;;
    # DIVE-2098: `unknown` is NOT a class, it is the absence of a measurement,
    # and it used to fall through the catch-all into `custom` — a GENUINE class
    # in this vocabulary, so an unmeasurable grant rendered as a confident
    # privilege claim. Map it (and any class this function does not recognise)
    # to `unknown`: a derived class must never be more certain than the
    # measurement it is derived from.
    *)        printf 'unknown\n' ;;
  esac
}

# One-line human summary of a class, for `agent info`.
sudo_grant_english() {
  case "$1" in
    root-all) printf 'any command, no restriction\n' ;;
    cli-root) printf 'the 5dive CLI only\n' ;;
    cli-scoped) printf 'a few named 5dive subcommands only\n' ;;
    none)     printf 'no sudo\n' ;;
    custom)   printf 'entries this CLI did not write\n' ;;
    *)        printf 'not measurable from here\n' ;;
  esac
}

# Measure + classify in one call. Echoes `class|runas|extra`, or
# `unknown|-|0` when the grant could not be read from where this ran.
agent_sudo_grant() {
  local lines
  if ! lines=$(sudo_grant_lines "$1" 2>/dev/null); then
    printf 'unknown|-|0\n'; return 0
  fi
  printf '%s\n' "$lines" | classify_sudo_grant
}

# DIVE-1065/1074: scoped inter-agent a2a grants for a 'standard'-isolation agent.
# A standard agent has NO broad sudo, so it can't run the `sudo -u agent-X tmux`
# inject/capture that `5dive agent send`/`ask` use (those need root). This grants
# EXACTLY three hidden, single-purpose subcommands as root, NOPASSWD:
#   * `5dive agent _deliver` (DIVE-1065) — the send/ask INJECT half.
#   * `5dive agent _capture` (DIVE-1074) — the ask reply-READ half.
#   * `5dive _audit_append`  (DIVE-1268) — append-only audit-log write (so a
#     non-root agent's mutating actions still land in the tamper-evident log;
#     re-stamps the real caller, never execs input).
#
# Why this is safe (same invariant as write_admin_sudoers above): both are
# single-purpose primitives that NEVER exec caller-controlled input (no eval /
# sh -c / printf-format), so the `*` wildcard on their args cannot become an
# agent->root vector. `_deliver` does ONLY a LITERAL tmux inject (send-keys -l --)
# of a provenance-wrapped message into a validated, registered target. `_capture`
# does ONLY a read-back of that target's pane, server-side-sliced to the caller's
# OWN reply window (lines after its marker id, up to the next marker) — it cannot
# read a peer's pre-existing pane or unbounded later activity. The worst a standard
# agent can do is inject text into a peer's pane and read the reply to its own
# question — precisely the sanctioned a2a capability this feature exists to give.
#
# Crucially this does NOT grant the whole `5dive` CLI as root — that stays
# admin-only. Only the one hardened subcommand is reachable, upholding the
# write_admin_sudoers standing invariant that no 5dive subcommand execs
# agent-controlled input as root (DIVE-756/916/950).
#
# visudo -c validated before install so a malformed entry can never lock the box
# out; on failure we remove it and fail loudly.
# render_standard_sudoers <user> <can_push> — emit (to stdout) the sudoers policy
# for a standard-isolation agent. The a2a + audit grants are UNCONDITIONAL. The
# delegated-push grant (`_push_do`) is added ONLY when can_push=1 — i.e. a BUILDER
# agent explicitly given the push capability (`agent create --can-push`), NOT
# every standard agent (DIVE-1462/STEER-4: a QA or art-director standard agent
# must not be able to ship). Exact command path with params over stdin (no arg
# wildcard) so the grant holds identically under classic sudo and sudo-rs. Kept
# pure (no root, no I/O) so it's unit-testable without a box; the writer below
# visudo-validates + installs it.
render_standard_sudoers() {
  local user="$1" can_push="${2:-0}"
  # INST-5: delegated deploy, the broker's second surface, on its own axis.
  local can_deploy="${3:-0}"
  cat <<SUDOERS
# Managed by 5dive (DIVE-1065/1074). Scoped inter-agent a2a grants for standard agent ${user}.
# Do not edit by hand; regenerated on agent create/provision.
${user} ALL=(root) NOPASSWD: /usr/local/bin/5dive agent _deliver *
${user} ALL=(root) NOPASSWD: /usr/local/bin/5dive agent _capture *
${user} ALL=(root) NOPASSWD: /usr/local/bin/5dive _audit_append
# DIVE-1813: let this agent restart its OWN service (so /model + /restart work).
# EXACT path, NO args, NO wildcard — the target unit is derived from SUDO_USER
# inside _self_restart, never from argv, so it can restart ONLY itself, never a
# peer. Deferred internally; needs no raw systemd-run/systemctl grant.
${user} ALL=(root) NOPASSWD: /usr/local/bin/5dive agent _self_restart
SUDOERS
  if [[ "$can_push" == "1" ]]; then
    cat <<SUDOERS
# DIVE-1462/STEER-4: delegated-push capability (builder agent). Exact command
# path; params travel over stdin (never argv), so no arg wildcard is needed and
# the grant is sudo-rs-safe. Gates re-verified authoritatively inside _push_do.
${user} ALL=(root) NOPASSWD: /usr/local/bin/5dive _push_do
# DIVE-2448: the same builder capability, one surface over -- actor-routed gh.
# A builder that may ship must also be able to have its WRITES recorded as the
# machine account rather than the human's (DIVE-2232), or attribution stays a
# thing each agent has to remember. Exact command path, args over stdin; _gh_do
# re-derives the routing class as root and refuses admin-class calls, so this
# grant cannot become a general "act as the bot" capability.
# NOTE FOR THE NEXT EDITOR: this heredoc is UNQUOTED (it interpolates ${user}),
# so a backtick or $ in a COMMENT is executed and its output lands in the
# sudoers file. A backtick-quoted word here once injected gh's help text and
# visudo rejected the result. Keep this block free of backticks and $.
${user} ALL=(root) NOPASSWD: /usr/local/bin/5dive _gh_do
SUDOERS
  fi
  if [[ "$can_deploy" == "1" ]]; then
    cat <<SUDOERS
# INST-5: delegated-deploy capability, the capability broker's SECOND surface.
# Same template as the push grant: exact command path, params over stdin (no arg
# wildcard, so it holds identically under classic sudo and sudo-rs), gate
# re-verified authoritatively inside _deploy_do under signature, and the target
# bound to the Deploy line the task itself declares.
# Deliberately a SEPARATE axis from can_push: shipping a branch for review and
# shipping to PRODUCTION are different authorities, and the capability registry
# records them under different names.
# NOTE FOR THE NEXT EDITOR: this heredoc is UNQUOTED (it interpolates the user),
# so a backtick or a dollar sign in a COMMENT is executed and its output lands
# in the sudoers file. Keep this block free of both.
${user} ALL=(root) NOPASSWD: /usr/local/bin/5dive _deploy_do
SUDOERS
  fi
}

write_standard_sudoers() {
  local user="$1" can_push="${2:-0}"
  local can_deploy="${3:-0}"
  local f="/etc/sudoers.d/${user}" tmp
  tmp=$(mktemp)
  render_standard_sudoers "$user" "$can_push" "$can_deploy" > "$tmp"
  chmod 440 "$tmp"
  if visudo -cf "$tmp" >/dev/null 2>&1; then
    chown root:root "$tmp"
    mv "$tmp" "$f"
    chmod 440 "$f"
    # DIVE-2102: mint the capability rows HERE, on the same file that just
    # passed `visudo -c` and is now installed — not alongside it later. The env
    # file's AGENT_CAN_PUSH is documented in-tree as an "informational" second
    # copy of a fact written authoritatively by create_agent_user, and two
    # copies minted at different moments IS the drift shape. This is the record
    # OF the authoritative write, taken at the instant it succeeds.
    # Best-effort: it never fails the install (see capability_declare_standard).
    capability_declare_standard "$user" "$can_push" provisioned "$can_deploy"
  else
    rm -f "$tmp"
    fail "$E_GENERIC" "generated sudoers for ${user} failed visudo validation; aborting (no partial install)"
  fi
}

# DIVE-2138 (gh#222, A-MO7SEN): where agent homes live, and where a removed
# agent's home goes. Quarantine, not delete — an agent home can hold work the
# operator still wants, and teardown is not the moment to make that call
# irreversibly. Root-owned 0700 so a RECYCLED uid cannot read what it inherits
# the number of. AGENT_HOME_ROOT is the same STATE_DIR-style override the rest
# of the CLI uses; it is what lets the rootless unit harness drive these paths.
AGENT_HOME_ROOT="${AGENT_HOME_ROOT:-/home}"
REAPED_DIR="${REAPED_DIR:-${AGENT_HOME_ROOT}/.5dive-reaped}"

# DIVE-2138: move a removed agent's home into the reaped area.
#
# `deluser` here runs WITHOUT --remove-home (deliberately, see delete_agent_user),
# so /home/agent-<name> outlived the user — and `adduser` RECYCLES freed uids.
# The next agent created therefore took the dead agent's uid and with it
# ownership of the dead agent's home, auth.json / credentials.toml / channel
# .env files included. Not a privilege escalation, but no operator expects
# `agent rm` to leave that behind. Moving the home aside is what actually
# closes it: after this, the recycled uid inherits a number and nothing else.
#
# Sets _RM_HOME_DISPOSITION for the caller's JSON/receipt. Best-effort: a
# failure here is LOUD (it is the security-relevant half) but never fails the
# remove, which has already torn down the unit and the secrets.
quarantine_agent_home() {
  local name="$1" home="$2" purge="${3:-0}"
  _RM_HOME_DISPOSITION="absent"
  [[ -n "$home" && -d "$home" ]] || return 0
  # Hard guard. `home` comes from getent, i.e. from a file this code does not
  # own, and everything below is a recursive chown or an rm -rf. Act ONLY on
  # the exact conventional path for THIS agent; anything else (a custom
  # --home, /home/claude, /, a symlink target) is reported and left alone.
  if [[ "$home" != "${AGENT_HOME_ROOT}/agent-${name}" || -L "$home" ]]; then
    _RM_HOME_DISPOSITION="left-in-place"
    warn "home for agent '${name}' is '${home}', not the expected ${AGENT_HOME_ROOT}/agent-${name} — leaving it untouched. Check it by hand: a home left on disk can be inherited by a later agent that recycles this uid (DIVE-2138)."
    return 0
  fi
  if [[ "$purge" == "1" ]]; then
    if rm -rf -- "$home" 2>/dev/null; then
      _RM_HOME_DISPOSITION="purged"
      step "purged home ${home} (--purge-home)"
    else
      _RM_HOME_DISPOSITION="failed"
      warn "could not purge ${home} — it stays on disk and a later agent recycling this uid would inherit it. Remove it by hand: sudo rm -rf ${home}"
    fi
    return 0
  fi
  local ts dest
  ts=$(date +%Y%m%d%H%M%S)
  dest="${REAPED_DIR}/${name}-${ts}"
  if ! mkdir -p "$REAPED_DIR" 2>/dev/null; then
    _RM_HOME_DISPOSITION="failed"
    warn "could not create ${REAPED_DIR} — ${home} stays on disk and a later agent recycling this uid would inherit it (DIVE-2138). Move it aside by hand."
    return 0
  fi
  chown root:root "$REAPED_DIR" 2>/dev/null || true
  chmod 0700 "$REAPED_DIR" 2>/dev/null || true
  if mv -- "$home" "$dest" 2>/dev/null; then
    # Order matters: chown BEFORE chmod is fine either way here because the
    # destination is already inside a 0700 root-only directory, so nothing
    # unprivileged can traverse into it at any point in between.
    chown -R root:root "$dest" 2>/dev/null || true
    chmod 0700 "$dest" 2>/dev/null || true
    _RM_HOME_DISPOSITION="quarantined:${dest}"
    step "quarantined home ${home} -> ${dest} (root-only 0700; delete when you are sure)"
  else
    _RM_HOME_DISPOSITION="failed"
    warn "could not move ${home} aside — it stays on disk and a later agent recycling this uid would inherit it, credentials included (DIVE-2138). Move it by hand: sudo mv ${home} ${dest}"
  fi
}

delete_agent_user() {
  local name="$1" purge_home="${2:-0}"
  local user="agent-${name}"
  _RM_HOME_DISPOSITION="absent"
  id -u "$user" &>/dev/null || return 0
  # DIVE-2138: resolve the home from passwd BEFORE deluser, while the name
  # still resolves — afterwards there is no record of where it was.
  local home
  home=$(getent passwd "$user" | cut -d: -f6)
  [[ -n "$home" ]] || home="${AGENT_HOME_ROOT}/agent-${name}"
  # DIVE-1033: drop any traverse ACL we granted a sandboxed agent on
  # /home/claude BEFORE deluser, while the name still resolves — afterwards the
  # entry would linger as a bare numeric uid. No-op (harmless) for admin/standard.
  setfacl -x "u:${user}" /home/claude 2>/dev/null || true
  # Skip --remove-home: DIVE-2138 quarantines the home below instead, so the
  # operator keeps whatever was in it while a recycled uid inherits nothing.
  deluser --quiet "$user" 2>/dev/null || true
  rm -f "/etc/sudoers.d/${user}"
  # DIVE-2102: the grant is gone as of the line above, so the capability rows
  # recording it stop being true HERE. Mirrors the mint site: rows are written
  # on the write that installs the grant and dropped on the write that removes
  # it. Without this a reaped agent stays a CONFIRMED holder forever — and
  # confirmed-holder is the only claim this registry makes, so a stale one is
  # the only kind of wrong answer it can produce. DIVE-2138 documents that
  # names and uids really are recycled on this host, so the successor would
  # inherit its predecessor's confirmations.
  capability_forget_agent "$user" || true
  quarantine_agent_home "$name" "$home" "$purge_home"
}

# DIVE-2138 (gh#222, A-MO7SEN): refuse a create whose home dir is a leftover.
#
# The reported failure was NOT the warning — it was WHERE the warning landed.
# `adduser` only warns on an existing home ("Not touching this directory"), so
# create sailed on, registered the agent in agents.json AND attached it to the
# team bot, and only THEN died on the first write into a directory it did not
# own. That left a half-created agent in the registry. Checked here, up front,
# before any mutation, the same box state is a clean refusal.
#
# Returns 0 (silent) for the two legitimate shapes: no home at all, and a home
# already owned by the user we are about to (re-)provision.
agent_home_conflict_check() {
  local name="$1"
  # Separate lines: a same-`local` ${name} is not yet assigned, which under
  # `set -u` aborts the whole CLI rather than merely reading empty.
  local user="agent-${name}"
  local home="${AGENT_HOME_ROOT}/agent-${name}"
  [[ -e "$home" ]] || return 0
  local owner_u owner_n
  owner_u=$(stat -c '%u' "$home" 2>/dev/null) || return 0
  owner_n=$(stat -c '%U' "$home" 2>/dev/null || echo "$owner_u")
  # Existing user that already owns it => ordinary re-provision, not a leftover.
  if id -u "$user" &>/dev/null && [[ "$owner_u" == "$(id -u "$user")" ]]; then
    return 0
  fi
  # Name the uid explicitly: the whole failure mode is uid recycling, and on the
  # reported box the owner did not resolve to a name at all (uid 1006, no such
  # user) — a report that only prints a name says nothing in exactly that case.
  fail "$E_CONFLICT" "${home} already exists, owned by ${owner_n} (uid ${owner_u}) — not by the agent-${name} user this create would make. That is a leftover home from a previously removed agent, and uids get recycled, so continuing would hand the new agent someone else's home and any credentials left in it (DIVE-2138). Move it aside first: sudo mv ${home} ${REAPED_DIR}/${name}-\$(date +%Y%m%d%H%M%S)"
}

# DIVE-499: accepted autonomy modes. 'son-of-anton' is a yolo synonym (a Silicon
# Valley nod); the runtime (5dive-agent-start) maps both to the same directive.
valid_autonomy() { [[ "$1" =~ ^(standard|yolo|son-of-anton)$ ]]; }

write_agent_env() {
  local name="$1" type="$2" channels="$3" workdir="${4:-}" profile="${5:-}" isolation="${6:-standard}"
  local env_file="${ENV_DIR}/${name}.env"
  # DIVE-499: per-agent autonomy mode (standard|yolo, alias son-of-anton). The
  # caller sets _AUTONOMY_OVERRIDE to change it (create --yolo / `set autonomy=`);
  # otherwise we PRESERVE whatever is already in the file, so an unrelated rewrite
  # (channels/workdir/auth set) never silently drops it. 'standard' = no line.
  local autonomy="${_AUTONOMY_OVERRIDE:-}"
  if [[ -z "$autonomy" && -r "$env_file" ]]; then
    autonomy=$(sed -n 's/^AGENT_AUTONOMY=//p' "$env_file" | head -1)
  fi
  # DIVE-1462/STEER-4: delegated-push capability, same PRESERVE-unless-overridden
  # discipline as autonomy. The caller sets _CAN_PUSH_OVERRIDE (create --can-push)
  # to change it; otherwise keep the file's current value so an unrelated rewrite
  # doesn't silently drop the builder capability. '1' = builder; anything else = no
  # line. Informational/audit record + future re-provision source (the sudoers
  # grant itself is written authoritatively by create_agent_user at create time).
  local can_push="${_CAN_PUSH_OVERRIDE:-}"
  if [[ -z "$can_push" && -r "$env_file" ]]; then
    can_push=$(sed -n 's/^AGENT_CAN_PUSH=//p' "$env_file" | head -1)
  fi
  # INST-5: same PRESERVE-unless-overridden discipline for delegated deploy.
  local can_deploy="${_CAN_DEPLOY_OVERRIDE:-}"
  if [[ -z "$can_deploy" && -r "$env_file" ]]; then
    can_deploy=$(sed -n 's/^AGENT_CAN_DEPLOY=//p' "$env_file" | head -1)
  fi
  {
    printf 'AGENT_NAME=%s\n' "$name"
    printf 'AGENT_TYPE=%s\n' "$type"
    printf 'AGENT_CHANNELS=%s\n' "$channels"
    [[ -n "$workdir" ]] && printf 'AGENT_WORKDIR=%s\n' "$workdir"
    [[ -n "$profile" ]] && printf 'AGENT_AUTH_PROFILE=%s\n' "$profile"
    printf 'AGENT_ISOLATION=%s\n' "$isolation"
    [[ -n "$autonomy" && "$autonomy" != "standard" ]] && printf 'AGENT_AUTONOMY=%s\n' "$autonomy"
    [[ "$can_push" == "1" ]] && printf 'AGENT_CAN_PUSH=1\n'
    [[ "$can_deploy" == "1" ]] && printf 'AGENT_CAN_DEPLOY=1\n'
    # New telegram agents flow through our 5dive-plugins fork (bundled
    # hooks, richer slash commands). 5dive-agent-start reads this var to
    # build the runtime --channels arg, defaulting to claude-plugins-official
    # when unset — so existing agents created before this change keep
    # routing to the upstream plugin until manually migrated. Membership
    # check, not equality: "telegram,dashboard" must still get the var or
    # the telegram plugin resolves against the wrong marketplace and the
    # session boots with no telegram tool (DIVE-856).
    channel_in_list telegram "$channels" && printf 'AGENT_CHANNEL_MARKETPLACE=5dive-plugins\n'
  } > "$env_file"
  chown root:claude "$env_file"
  chmod 640 "$env_file"
}

# Point /var/lib/5dive/agents.d/<name>-auth.env at the profile's combined.env
# (systemd picks it up via EnvironmentFile=-/var/lib/5dive/agents.d/%i-auth.env).
# Empty <profile> removes the link — agent falls back to the shared
# /etc/5dive/connectors/*.env files, same as before profiles existed.
link_agent_profile() {
  local name="$1" profile="${2:-}"
  local link="${ENV_DIR}/${name}-auth.env"
  rm -f "$link"
  [[ -n "$profile" ]] || return 0
  local target="${AUTH_PROFILES_DIR}/${profile}/combined.env"
  [[ -f "$target" ]] \
    || fail "$E_NOT_FOUND" "auth profile '$profile' not configured — run: sudo 5dive agent auth set <type> --api-key=... --auth-profile=$profile"
  ln -s "$target" "$link"
  # DIVE-1188: a NEW agent bound to an EXISTING profile (no re-login in between)
  # must still be able to seed codex/grok auth.json without sudo, so normalize
  # the profile's file creds to 0640 group=claude at bind time. Guarded because
  # this lib is also sourced in contexts without cmd_auth.sh.
  declare -F normalize_profile_seed_perms >/dev/null 2>&1 \
    && normalize_profile_seed_perms "$profile"
  return 0   # DIVE-2751: the guard above is the point — in a context WITHOUT
             # cmd_auth.sh the declare fails, and as the last statement that
             # false test became this function's rc at five bare call sites.
}

# Write a BYO (bring-your-own) API-key credential for hermes/openclaw into
# the canonical state dir that 5dive-agent-start.sh seeds from at launch.
# Called from cmd_create (--provider=<canonical> --api-key=<key>) and
# cmd_auth_set (same flags, on already-created agents). Runs as the
# `claude` user so the resulting files land owned by claude:claude — the
# agent's start hook re-copies them into agent-<name>'s home with mode 0600.
#
# <type> hermes uses `hermes auth add <provider> --type api-key --api-key`
# which writes ~/.hermes/auth.json with the right base_url auto-resolved
# from hermes' built-in provider catalog. <type> openclaw has no scriptable
# auth-add path (paste-token requires TTY) — write auth-profiles.json
# directly with the {type:"api_key", provider, key} shape. Both binaries
# read what we write at startup; cmd_auth_set restarts every agent bound
# to the profile so the seed loop in 5dive-agent-start.sh picks up the
# new files and bounces the hermes/openclaw gateway daemon.
apply_byo_provider() {
  local type="$1" canonical="$2" api_key="$3" profile="${4:-}" model="${5:-}"
  valid_byo_provider "$canonical" \
    || fail "$E_VALIDATION" "unknown provider '$canonical' (known: ${!BYO_PROVIDER_LABEL[*]})"
  valid_api_key "$api_key" \
    || fail "$E_VALIDATION" "api key looks wrong (>=10 printable non-space chars)"
  local native
  native=$(resolve_native_provider "$type" "$canonical")
  [[ -n "$native" ]] \
    || fail "$E_VALIDATION" "$type does not support provider '$canonical' (${BYO_PROVIDER_LABEL[$canonical]})"

  case "$type" in
    hermes)   _apply_byo_hermes "$native" "$canonical" "$api_key" "$profile" "$model" ;;
    openclaw) _apply_byo_openclaw "$native" "$canonical" "$api_key" "$profile" "$model" ;;
    claude)   _apply_byo_claude "$canonical" "$api_key" "$profile" "$model" ;;
    *) fail "$E_VALIDATION" "BYO provider not supported for type '$type' (only: hermes, openclaw, claude)" ;;
  esac
}

# Claude (Claude Code) BYO custom-provider path. Unlike hermes/openclaw — which
# write native auth.json/auth-profiles.json — the claude harness reads its
# credentials and endpoint from the environment, so we upsert the override env
# vars into the auth-profile's combined.env. systemd loads that as
# EnvironmentFile=%i-auth.env *after* the shared anthropic.env (last-wins), so
# these override any default-account OAuth token that template otherwise leaks
# in. profile_set_var takes the value on stdin (keeps secrets out of argv).
_apply_byo_claude() {
  local canonical="$1" api_key="$2" profile="${3:-}" override_model="${4:-}"
  [[ -n "$profile" ]] \
    || fail "$E_USAGE" "claude BYO provider requires --auth-profile (custom-provider creds are profile-scoped)"
  local base_url="${CLAUDE_PROVIDER_BASEURL[$canonical]:-}"
  [[ -n "$base_url" ]] \
    || fail "$E_VALIDATION" "claude does not support provider '$canonical' (${BYO_PROVIDER_LABEL[$canonical]:-unknown}: no Anthropic-compatible endpoint)"
  step "Configuring claude BYO provider '$canonical' → ${base_url} (profile=$profile)"
  printf '%s' "$base_url"  | profile_set_var "$profile" ANTHROPIC_BASE_URL
  printf '%s' "$api_key"   | profile_set_var "$profile" ANTHROPIC_AUTH_TOKEN
  # DIVE-1103: an operator-supplied --model overrides the primary (opus+sonnet)
  # tiers with any slug the provider serves (OpenRouter translates every family;
  # the Chinese providers serve their own). The background/fast HAIKU slot stays
  # on the catalogue's caching-capable default so background turns stay cheap.
  local opus_model="${CLAUDE_PROVIDER_OPUS_MODEL[$canonical]}"
  local sonnet_model="${CLAUDE_PROVIDER_SONNET_MODEL[$canonical]}"
  if [[ -n "$override_model" ]]; then opus_model="$override_model"; sonnet_model="$override_model"; fi
  printf '%s' "$opus_model"   | profile_set_var "$profile" ANTHROPIC_DEFAULT_OPUS_MODEL
  printf '%s' "$sonnet_model" | profile_set_var "$profile" ANTHROPIC_DEFAULT_SONNET_MODEL
  printf '%s' "${CLAUDE_PROVIDER_HAIKU_MODEL[$canonical]}"  | profile_set_var "$profile" ANTHROPIC_DEFAULT_HAIKU_MODEL
  # Custom endpoints (esp. z.ai during peak hours) can be slow; raise the
  # client-side request timeout so long tool turns don't get cut off.
  printf '%s' "3000000" | profile_set_var "$profile" API_TIMEOUT_MS
  # Neutralize any shared-account creds the template's unconditional
  # anthropic.env EnvironmentFile= would inject ahead of our override —
  # combined.env loads last so empty values win, forcing the harness onto
  # ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL instead of OAuth-to-Anthropic.
  printf '%s' "" | profile_set_var "$profile" CLAUDE_CODE_OAUTH_TOKEN
  printf '%s' "" | profile_set_var "$profile" ANTHROPIC_API_KEY
}

_apply_byo_hermes() {
  # override_model (DIVE-1318): an operator-supplied --model wins over the
  # per-provider catalog default (HERMES_PROVIDER_MODEL) — e.g. dashboard
  # openrouter creates pass a concrete slug instead of "openrouter/auto".
  local native="$1" canonical="$2" api_key="$3" profile="${4:-}" override_model="${5:-}"
  local bin="${TYPE_BIN[hermes]}"
  [[ -x "$bin" ]] || fail "$E_NOT_INSTALLED" "hermes not installed at $bin"

  # HERMES_HOME is the dir that contains auth.json/config.yaml directly —
  # `profile_type_dir` already returns that for profiled installs, matching
  # the path 5dive-agent-start.sh syncs from. Appending /.hermes here put
  # the credential one dir too deep and the per-agent seed silently no-op'd
  # (left every BYO-key hermes agent stuck on whatever auth was there at
  # create time). Default profile keeps writing to the shared dir.
  local hermes_home="/home/claude/.hermes"
  if [[ -n "$profile" ]]; then
    hermes_home="$(profile_type_dir "$profile" hermes)"
  fi

  # Kimi/Moonshot env-var path: hermes' Kimi provider reads KIMI_API_KEY from
  # ~/.hermes/.env at gateway startup; there is no `hermes auth add moonshot`
  # to populate auth.json. Write the env var into the shared dir (cmd_create
  # mirrors it into the agent-user's .env via seed_hermes_byo_env before the
  # gateway starts) and stamp a minimal auth.json so the cmd_create auth gate
  # (auth_creds_present → `-s ${TYPE_AUTH[hermes]}`) doesn't reject the agent
  # for "no credentials." `{}` is hermes' own pre-login shape.
  if [[ "$canonical" == "moonshot" ]]; then
    step "Writing hermes BYO credential for '$canonical' (KIMI_API_KEY → ${hermes_home}/.env)"
    install -d -m 0775 -o claude -g claude "$hermes_home"
    if ! sudo -u claude -H env HERMES_HOME="$hermes_home" KEY="$api_key" bash -s >&2 <<'KIMI_ENV'
set -euo pipefail
ENV_FILE="$HERMES_HOME/.env"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
TMP=$(mktemp --tmpdir="$HERMES_HOME" .env.XXXXXX)
chmod 600 "$TMP"
grep -v '^KIMI_API_KEY=' "$ENV_FILE" > "$TMP" || true
printf 'KIMI_API_KEY=%s\n' "$KEY" >> "$TMP"
mv "$TMP" "$ENV_FILE"
AUTH_FILE="$HERMES_HOME/auth.json"
if [[ ! -s "$AUTH_FILE" ]]; then
  printf '{}\n' > "$AUTH_FILE"
  chmod 600 "$AUTH_FILE"
fi
KIMI_ENV
    then
      fail "$E_GENERIC" "hermes BYO env write failed for moonshot"
    fi
    # Point hermes at the Kimi provider so first launch doesn't hit the
    # "Hermes isn't configured yet" prompt. Non-fatal: if hermes' CLI rejects
    # the value, the agent can still run (KIMI_API_KEY is in .env) and the
    # user can pick the model via `5dive agent <name> tui`. `kimi` is an
    # alias on the upstream kimi-coding provider — see
    # plugins/model-providers/kimi-coding/__init__.py.
    sudo -u claude -H env HERMES_HOME="$hermes_home" \
      "$bin" config set model.provider "$native" >&2 \
      || warn "hermes config set model.provider=$native failed (user can pick the model in TUI)"
    local model="${override_model:-${HERMES_PROVIDER_MODEL[$canonical]:-}}"
    if [[ -n "$model" ]]; then
      sudo -u claude -H env HERMES_HOME="$hermes_home" \
        "$bin" config set model.default "$model" >&2 \
        || warn "hermes config set model.default=$model failed"
    fi
    return 0
  fi

  step "Writing hermes BYO credential for '$canonical' (native id: $native)"
  # Pass the key on STDIN only, never on argv. `hermes auth add` reads the key
  # from its secure prompt (getpass), which falls back to reading stdin when
  # there's no tty — verified against hermes v0.19.0: the piped key lands in
  # auth.json with no --api-key argv. Passing --api-key "$api_key" here would
  # expose the BYO secret in /proc/<pid>/cmdline + ps for the life of the call
  # (DIVE-1818).
  printf '%s' "$api_key" | sudo -u claude -H env HERMES_HOME="$hermes_home" \
    "$bin" auth add "$native" --type api-key --label "${canonical}-byo" >&2 \
    || fail "$E_GENERIC" "hermes auth add $native failed"
  sudo -u claude -H env HERMES_HOME="$hermes_home" \
    "$bin" config set model.provider "$native" >&2 \
    || warn "hermes config set model.provider=$native failed (rerun: sudo -u claude -H $bin config set model.provider $native)"
  # hermes auto-resolves model.base_url from its provider catalog when
  # model.base_url is unset, and we unset any stale value so a prior openai-codex
  # oauth base_url can't pin the agent to chatgpt.com. But for a provider whose
  # catalog entry resolves the WRONG endpoint, the unset lets hermes hit a URL
  # the key won't auth against. z.ai is exactly this: its coding models are served
  # in anthropic wire format at api.z.ai/api/anthropic (what pi + the claude
  # anthropic-skin use), but hermes' catalog resolves a different zai URL, so
  # hermes+zai failed "Provider authentication failed" even with a correct key
  # (DIVE-1819). When we have a verified override for this provider, pin it
  # explicitly; otherwise fall back to the stale-value-clearing unset.
  local hermes_base_url="${HERMES_PROVIDER_URL[$canonical]:-}"
  if [[ -n "$hermes_base_url" ]]; then
    sudo -u claude -H env HERMES_HOME="$hermes_home" \
      "$bin" config set model.base_url "$hermes_base_url" >&2 2>/dev/null \
      || warn "hermes config set model.base_url=$hermes_base_url failed"
  else
    sudo -u claude -H env HERMES_HOME="$hermes_home" \
      "$bin" config set model.base_url "" >&2 2>/dev/null || true
  fi
  # z.ai key-TYPE hint (DIVE-1819): the anthropic endpoint we pin above is z.ai's
  # officially-supported *coding* route, which authorizes a GLM Coding-Plan key.
  # A standard prepaid/API-only z.ai key may 401 "Provider authentication failed"
  # there. Surface it so an auth failure reads as key-type, not a broken config.
  if [[ "$canonical" == "zai" ]]; then
    step "z.ai note: use your GLM Coding-Plan key (z.ai → Coding Plan) for GLM coding models; a standard prepaid API key may fail auth on the anthropic endpoint."
  fi
  local model="${override_model:-${HERMES_PROVIDER_MODEL[$canonical]:-}}"
  if [[ -n "$model" ]]; then
    sudo -u claude -H env HERMES_HOME="$hermes_home" \
      "$bin" config set model.default "$model" >&2 \
      || warn "hermes config set model.default=$model failed"
  fi
}

_apply_byo_openclaw() {
  # override_model (DIVE-1318): --model wins over OPENCLAW_PROVIDER_MODEL default.
  local native="$1" canonical="$2" api_key="$3" profile="${4:-}" override_model="${5:-}"
  local base="/home/claude"
  if [[ -n "$profile" ]]; then
    base="$(profile_type_dir "$profile" openclaw)"
    install -d -m 2750 -o claude -g claude "$base"
  fi
  local oc_dir="${base}/.openclaw/agents/main/agent"
  install -d -m 0750 -o claude -g claude \
    "${base}/.openclaw" \
    "${base}/.openclaw/agents" \
    "${base}/.openclaw/agents/main" \
    "$oc_dir"

  local profile_id="${native}:manual"
  local auth_file="${oc_dir}/auth-profiles.json"
  step "Writing openclaw BYO auth-profiles.json for '$canonical' (native id: $native)"
  local tmp
  tmp=$(mktemp -p "$oc_dir" .auth-profiles.XXXXXX) \
    || fail "$E_GENERIC" "mktemp failed in $oc_dir"
  jq -cn --arg pid "$profile_id" --arg p "$native" --arg k "$api_key" \
    '{version:1, profiles:{($pid):{type:"api_key", provider:$p, key:$k}}}' \
    > "$tmp" \
    || { rm -f "$tmp"; fail "$E_GENERIC" "failed to write $auth_file"; }
  chown claude:claude "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$auth_file"

  local openclaw_base_url="${OPENCLAW_PROVIDER_URL[$canonical]:-}"
  local model="${override_model:-${OPENCLAW_PROVIDER_MODEL[$canonical]:-}}"

  # Any openclaw.json write (provider base_url pin and/or default model) goes
  # through the same stable-node invocation — resolve the runtime once.
  if [[ -n "$openclaw_base_url" || -n "$model" ]]; then
    local openclaw_bin="${TYPE_BIN[openclaw]}"
    local openclaw_node="/home/claude/.local/bin/node"
    # The npm launcher uses `#!/usr/bin/env node`. Do not rely on sudo/systemd's
    # PATH to resolve that shebang during fresh create: invoke the stable Node
    # link installed alongside OpenClaw explicitly. Keep ~/.local/bin on PATH
    # for any subprocess OpenClaw starts while writing the config.
    [[ -x "$openclaw_node" ]] \
      || fail "$E_NOT_INSTALLED" "node runtime missing for openclaw (run: 5dive agent install openclaw --upgrade)"

    # DIVE-1826: pin the provider endpoint when we have a verified override.
    # openclaw's zai provider otherwise defaults to the GENERAL /paas/v4 surface
    # (its zai-api-key auto-detect probes general endpoints before the Coding Plan
    # ones, and a bare BYO auth profile never runs that probe), so a GLM
    # Coding-Plan key 401s there. models.providers.<id>.baseUrl (a mode:merge
    # overlay on openclaw's built-in catalog) points the provider at the correct
    # endpoint. NOTE: for z.ai this is the openai-compat *coding* URL, NOT the
    # api.z.ai/api/anthropic endpoint hermes/pi pin — openclaw talks
    # openai-completions to z.ai (see OPENCLAW_PROVIDER_URL).
    if [[ -n "$openclaw_base_url" ]]; then
      sudo -u claude -H env \
        HOME="$base" \
        PATH="/home/claude/.local/bin:/usr/bin:/bin" \
        "$openclaw_node" "$openclaw_bin" \
        config set "models.providers.${native}.baseUrl" "$openclaw_base_url" >&2 \
        || warn "openclaw config set models.providers.${native}.baseUrl=$openclaw_base_url failed"
    fi

    # Default model lands in openclaw.json's agents.defaults.model.primary;
    # 5dive-agent-start.sh syncs it from the shared/profile copy into the
    # per-agent openclaw.json on every launch.
    if [[ -n "$model" ]]; then
      sudo -u claude -H env \
        HOME="$base" \
        PATH="/home/claude/.local/bin:/usr/bin:/bin" \
        "$openclaw_node" "$openclaw_bin" \
        config set agents.defaults.model.primary "$model" >&2 \
        || warn "openclaw config set agents.defaults.model.primary=$model failed"
    fi
  fi

  # z.ai key-TYPE hint (DIVE-1826, the openclaw sibling of the DIVE-1819 hermes
  # note): the coding endpoint we pin above authorizes a GLM Coding-Plan key. A
  # standard prepaid / API-only z.ai key may 401 there, so surface it — an auth
  # failure then reads as key-type, not a broken config.
  if [[ "$canonical" == "zai" ]]; then
    step "z.ai note: use your GLM Coding-Plan key (z.ai → Coding Plan) for GLM coding models; a standard prepaid API key may fail auth on the coding endpoint."
  fi
}

# ── DIVE-990: memory-as-onboarding ──────────────────────────────────────────
# A new hire should boot knowing the company instead of cold-starting. When
# `create --inherit-memory=<scope>` is passed we seed the new agent's own recall
# store (~/.claude/projects/<slug>/memory/) so `5dive memory search` returns
# team knowledge from the first minute. Scope is a comma-list of sources:
#   wiki            the shared team wiki (community/wiki) — canonical shared facts
#   <agent-name>    that sibling's SHAREABLE facts only (reference/project, never
#                   user/feedback — deny-by-default, same L1 scoping as `export`)
#   all | team      wiki + every sibling agent's shareable facts
# Everything copied is safe-to-share by construction; private facts (who the
# human is / how to work with them) never leave their owner's 0600 store.

# Copy the shared wiki (index first — the onboarding entry point) into <target>.
# Echoes the number of files seeded. Pure (no root/chown) so it's unit-testable.
_seed_wiki_memory() {
  local target="$1" wiki wf b n=0
  wiki=$(_memory_wiki_root); [[ -n "$wiki" ]] || { printf '0'; return 0; }
  for wf in "$wiki"/index.md "$wiki"/*.md; do
    [[ -f "$wf" ]] || continue
    b=$(basename "$wf")
    [[ "$b" == "index.md" ]] && b="wiki-index.md" || b="wiki-${b}"
    [[ -e "$target/$b" ]] && continue   # index.md matches both globs; dedup
    cp "$wf" "$target/$b" 2>/dev/null && n=$((n+1))
  done
  printf '%s' "$n"
}

# Copy a sibling agent's SHAREABLE facts (via the same deny-by-default scoping
# `agent export` uses) into <target>, prefixed with the source name to avoid
# collisions across multiple sources. Echoes the count. Pure (no root).
_seed_agent_memory() {
  local src_agent="$1" target="$2" memdir tmp f b n=0
  memdir=$(_pack_memory_dir "$src_agent") || { printf '0'; return 0; }
  [[ -n "$memdir" && -d "$memdir" ]] || { printf '0'; return 0; }
  tmp=$(mktemp -d) || { printf '0'; return 0; }
  _pack_scope_memory "$memdir" "$tmp" >/dev/null 2>&1 || true
  for f in "$tmp"/*.md; do
    [[ -e "$f" ]] || continue
    b=$(basename "$f")
    [[ "$b" == "MEMORY.md" ]] && continue
    [[ -e "$target/${src_agent}-${b}" ]] && continue
    cp "$f" "$target/${src_agent}-${b}" 2>/dev/null && n=$((n+1))
  done
  rm -rf "$tmp"
  printf '%s' "$n"
}

# Regenerate a MEMORY.md index over everything seeded into <dir> so the agent's
# recall boots with a browsable table of contents (same shape the memory rules
# expect). Pure (no root).
_rebuild_inherited_index() {
  local dir="$1" f nm desc
  {
    echo "# Memory Index (inherited at hire — DIVE-990)"
    echo
    echo "Seeded from shared team knowledge so this agent starts warm. Search with \`5dive memory search \"<query>\"\`; add your own facts with \`5dive memory add\`."
    echo
    for f in "$dir"/*.md; do
      [[ -e "$f" ]] || continue
      [[ "$(basename "$f")" == "MEMORY.md" ]] && continue
      nm=$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^name:[[:space:]]*/{sub(/^name:[[:space:]]*/,""); print; exit}' "$f")
      desc=$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^description:[[:space:]]*/{sub(/^description:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}' "$f")
      [[ -n "$nm" ]] || nm=$(basename "$f" .md)
      echo "- [$nm]($(basename "$f")) — ${desc}"
    done
  } > "$dir/MEMORY.md"
}

# Expand a scope string into a deduped list of concrete source tokens
# (wiki + agent names), resolving all/team against the live registry.
# $1=scope  $2=agent-being-created (excluded from all/team). Echoes one per line.
_resolve_inherit_sources() {
  local scope="$1" self="$2" t a seen=" " out=()
  local IFS=,
  for t in $scope; do
    case "$t" in
      all|team)
        out+=("wiki")
        while read -r a; do
          [[ -n "$a" && "$a" != "$self" ]] && out+=("$a")
        done < <(registry_read | jq -r '(.agents // {}) | keys[]' 2>/dev/null)
        ;;
      *) out+=("$t") ;;
    esac
  done
  unset IFS
  for t in "${out[@]}"; do
    [[ "$seen" == *" $t "* ]] && continue
    seen+="$t "
    printf '%s\n' "$t"
  done
}

# DIVE-2025: can the agent actually READ its credential?
#
# The self-check used to answer this by reading `defer_auth` — a flag recording
# what the OPERATOR CHOSE, not what the agent GOT. On the completed-login path
# nothing was checked at all (not even an ok entry), so a credential that
# silently never reached the agent still printed "self-check PASS — reachable &
# autonomous". That is the DIVE-1900 shape: every status surface agrees and
# every one is wrong.
#
# THE PROBE MUST BE GROUNDED IN THE AGENT'S UID. `agent create` runs as root,
# and root reads every credential on the box, so a readability test run from
# here would pass unconditionally and prove nothing — it would replace a lie
# with a vacuous truth. Presence is answered as root (root traverses every
# 0700 dir, so its `-e` is the only trustworthy ABSENT verdict); readability is
# answered as agent-<name>. Two different questions, two different uids.
#
# ABSENT and UNREADABLE stay distinct because they take different fixes:
# absence is "go log in", unreadability is "the credential is fine, the perms
# are not" (and presents as `invalid_grant "Malformed auth code"`, which reads
# as an EXPIRED token, so the intuitive fix — a re-tap — changes nothing).
#
# The single seam where the agent-uid read happens, so a harness can stub it
# without needing a real agent user, real sudo, or root.
cred_readable_by_agent() { # <agent-user> <path>
  sudo -n -u "$1" test -r "$2" 2>/dev/null
}

# selfcheck_cred_reached_agent <name> <type> <profile> <byo_provider>
# Emits zero or more `ok:<text>` / `issue:<text>` lines on stdout. Never fails.
# Kept as a named function (rather than inlined in the self-check) so the
# agent-list health-badge rail (DIVE-1219) can call the same probe and re-check
# continuously instead of only once at creation.
selfcheck_cred_reached_agent() { # <name> <type> <profile> <byo_provider>
  local name="$1" type="$2" profile="$3" byo="${4:-}"
  local user="agent-${name}"

  # Witness 1: the boot seed's own breadcrumb. 5dive-agent-start runs AS the
  # agent and records a failed seed at ~/.5dive-cred-seed-failed (removing it
  # on success), with ABSENT vs UNREADABLE already resolved by cred_seed_why.
  # Until now that verdict only reached the unit's journal, where nobody looks.
  # Reading it here costs nothing and duplicates no path knowledge.
  # AGENT_HOME_ROOT is a test seam (default /home, as everywhere else in this
  # file); a harness cannot create /home/agent-<name> without root.
  local bc="${AGENT_HOME_ROOT:-/home}/${user}/.5dive-cred-seed-failed" why=""
  if [[ -s "$bc" ]]; then
    why=$(tr -d '\n' < "$bc" 2>/dev/null | cut -c1-400)
    printf 'issue:credential did NOT reach the agent (it is UNAUTHED despite a completed login) — the boot seed recorded: %s. Re-seed as root: sudo 5dive agent restart %s\n' \
      "$why" "$name"
    return 0
  fi

  # Witness 2: the source the seed reads from, probed as the agent. Catches
  # what the breadcrumb cannot — a seed that never ran because the unit had not
  # reached it yet, and the no-seed types that never write a breadcrumb at all.
  local src=""
  if [[ -n "$byo" ]]; then
    # BYO writes an API key into combined.env, not the type's OAuth sentinel;
    # probing the sentinel would report a false ABSENT.
    [[ -n "$profile" ]] && src="${AUTH_PROFILES_DIR}/${profile}/combined.env"
  elif [[ -n "$profile" && -s "${AUTH_PROFILES_DIR}/${profile}/combined.env" ]]; then
    # api-key / claude-OAuth path: create's own auth gate accepts combined.env
    # in place of the per-type file, so the probe has to accept it too.
    src="${AUTH_PROFILES_DIR}/${profile}/combined.env"
  else
    src=$(profile_type_auth_path "$profile" "$type" 2>/dev/null) || src=""
    # `claude` is the one type whose shared sentinel is a `path:jsonkey` pair
    # (DIVE-1803); every other type's is a bare path.
    src="${src%%:*}"
  fi
  [[ -n "$src" ]] || return 0        # opencode/pi/devin: no credential sentinel

  if [[ ! -e "$src" ]]; then
    printf 'issue:no auth credential at %s (agent is UNAUTHED — it cannot think until you log in): sudo 5dive agent auth login %s%s\n' \
      "$src" "$type" "${profile:+ --auth-profile=$profile}"
  elif [[ ! -s "$src" ]]; then
    printf 'issue:auth credential at %s is EMPTY (a login was started but never finalized) — re-run: sudo 5dive agent auth login %s%s\n' \
      "$src" "$type" "${profile:+ --auth-profile=$profile}"
  elif cred_readable_by_agent "$user" "$src"; then
    printf 'ok:auth credential readable by %s\n' "$user"
  else
    printf 'issue:auth credential EXISTS at %s but is NOT readable by %s — a perms fault, NOT an expired token (the agent will fail token exchange with '"'"'Malformed auth code'"'"'; re-tapping the login changes nothing). Re-normalize perms as root: sudo 5dive agent restart %s\n' \
      "$src" "$user" "$name"
  fi
  return 0
}

# Top-level seeding (root): builds the target store, seeds every resolved
# source, rebuilds the index, and hands the whole tree to the agent user.
seed_inherited_memory() {
  local name="$1" scope="$2" workdir="$3"
  local user="agent-${name}" slug target t seeded=0 got
  slug=$(printf '%s' "$workdir" | sed 's:/:-:g')   # matches the running agent's project slug
  target="/home/${user}/.claude/projects/${slug}/memory"
  install -d -m 700 -o "$user" -g "$user" \
    "/home/${user}/.claude" "/home/${user}/.claude/projects" \
    "/home/${user}/.claude/projects/${slug}" "$target" || {
      warn "inherit-memory: could not create store for $user — skipping"; return 0; }
  while read -r t; do
    [[ -n "$t" ]] || continue
    if [[ "$t" == "wiki" ]]; then
      got=$(_seed_wiki_memory "$target")
    else
      got=$(_seed_agent_memory "$t" "$target")
    fi
    seeded=$((seeded + ${got:-0}))
  done < <(_resolve_inherit_sources "$scope" "$name")
  _rebuild_inherited_index "$target"
  chown -R "$user":"$user" "/home/${user}/.claude/projects/${slug}"
  step "Inherited $seeded memory file(s) into agent-${name}'s recall (scope: $scope)"
}

cmd_create() {
  local name="" type="" channels="none" channels_explicit=0 telegram_token="" discord_token="" workdir="" profile=""
  local telegram_home_channel="" telegram_allowed_users="" telegram_cos="" telegram_cos_avatar=""
  local cos_owner_id=""
  local byo_provider="" byo_api_key="" byo_model=""
  local skills_arg="" skills_set=0 no_skills=0 defer_auth=0
  local isolation="" isolation_explicit=0 no_team_bot=0
  local autonomy="standard"   # DIVE-499
  local can_push=0            # DIVE-1462/STEER-4: delegated-push (builder) capability
  local can_deploy=0          # INST-5: delegated-deploy (production ship) capability
  local inherit_memory=""     # DIVE-990 memory-as-onboarding
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type=*)                    type="${1#--type=}" ;;
      --yolo)                      autonomy="yolo" ;;
      --autonomy=*)                autonomy="${1#--autonomy=}" ;;
      --channels=*)                channels="${1#--channels=}"; channels_explicit=1 ;;
      --telegram-token=*)          telegram_token="${1#--telegram-token=}" ;;
      --telegram-home-channel=*)   telegram_home_channel="${1#--telegram-home-channel=}" ;;
      --telegram-allowed-users=*)  telegram_allowed_users="${1#--telegram-allowed-users=}" ;;
      --telegram-cos=*)            telegram_cos="${1#--telegram-cos=}" ;;
      --telegram-cos-avatar=*)     telegram_cos_avatar="${1#--telegram-cos-avatar=}" ;;
      --discord-token=*)           discord_token="${1#--discord-token=}" ;;
      --workdir=*)                 workdir="${1#--workdir=}" ;;
      --auth-profile=*)            profile="${1#--auth-profile=}" ;;
      --provider=*)                byo_provider="${1#--provider=}" ;;
      --api-key=*)                 byo_api_key="${1#--api-key=}" ;;
      --model=*)                   byo_model="${1#--model=}" ;;
      --with-skills=*)             skills_arg="${1#--with-skills=}"; skills_set=1 ;;
      --no-skills)                 no_skills=1 ;;
      --no-team-bot)               no_team_bot=1 ;;
      --defer-auth)                defer_auth=1 ;;
      --isolation=*)               isolation="${1#--isolation=}"; isolation_explicit=1 ;;
      --inherit-memory=*)          inherit_memory="${1#--inherit-memory=}" ;;
      --can-push)                  can_push=1 ;;
      --can-deploy)                can_deploy=1 ;;
      -*)                          fail "$E_USAGE" "unknown flag: $1" ;;
      *)                           [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent create <name> --type=<type> [--channels=none|telegram|discord|dashboard[,ch...]] [--telegram-token=<token|->] [--telegram-cos=<child-username>] [--telegram-cos-avatar=<png>] [--telegram-home-channel=<id>] [--telegram-allowed-users=<csv>] [--discord-token=<token|->] [--workdir=<path>] [--auth-profile=<name>] [--provider=<id> --api-key=<key|->] [--model=<slug>] [--with-skills=<spec>[,...]] [--no-skills] [--no-team-bot] [--defer-auth] [--isolation=admin|standard|sandboxed] [--can-push] [--can-deploy] [--inherit-memory=wiki|all|team|<agent>[,...]]"
  [[ -n "$type" ]] || fail "$E_USAGE" "--type is required"
  valid_name "$name" || fail "$E_VALIDATION" "invalid name (lowercase letters/digits/hyphens, start letter, <=16 chars)"
  is_known_type "$type" || fail "$E_NOT_FOUND" "unknown type: $type (known: ${!TYPE_BIN[*]})"
  # DIVE-1221/1222: Grok provisioning is FROZEN. Grok Build CLI (xAI) has a
  # disclosed codebase-exfiltration issue with no client-side fix as of its
  # v0.2.98 changelog; xAI shipped only a revocable server-side mitigation. As a
  # precaution we refuse grok here. Every provisioning path (agent create, hire,
  # pack import, clone) funnels through cmd_create, so this blocks all of them.
  # Unfreeze condition (olivia): a VERIFIED xAI client-side patch + a pinnable
  # version, NEVER the server-side toggle alone. The override below exists ONLY
  # for that verified-unfreeze moment; do NOT set it to work around the freeze.
  if [[ "$type" == "grok" && "${FIVE_GROK_UNFREEZE_VERIFIED:-}" != "1" ]]; then
    fail "$E_VALIDATION" "grok provisioning is frozen (DIVE-1221): Grok Build has an unpatched codebase-exfiltration issue and xAI has shipped only a revocable server-side mitigation. Unfreeze needs a verified xAI client-side fix + pinnable version. See DIVE-1221."
  fi
  if [[ "$type" == "grok" ]]; then
    warn "FIVE_GROK_UNFREEZE_VERIFIED=1 set, bypassing the DIVE-1221 Grok exfiltration freeze. Only valid if a VERIFIED xAI client-side patch is pinned."
  fi
  valid_channel "$channels" || fail "$E_VALIDATION" "invalid channels: $channels (none|telegram|discord|dashboard, comma-separable)"
  # DIVE-856: claude agents are chat-capable in the web dashboard by default.
  # The dashboard channel needs no token (the plugin reads the box connectord
  # bearer itself), so fold it into every claude create: unset --channels
  # becomes "dashboard", and an explicit list gets ",dashboard" appended.
  # An explicit --channels=none stays the opt-out. Gated on the connectord
  # env existing so self-hosted boxes with no dashboard backend don't boot a
  # plugin that can never authenticate.
  if [[ "$type" == "claude" && -r /etc/5dive/connectord.env ]]; then
    if [[ "$channels" == "none" ]]; then
      (( channels_explicit )) || channels="dashboard"
    elif ! channel_in_list dashboard "$channels"; then
      channels="${channels},dashboard"
    fi
  fi
  # DIVE-1002: least-privilege by default. Absent an explicit --isolation, new
  # agents are 'standard'. Bootstrap exception: the FIRST agent on a fresh box
  # (empty registry) is auto-granted 'admin' so the box has a fleet-manager out
  # of the gate. We resolve the tier here and RECORD it explicitly in the
  # registry below — admin is never re-derived from create-order (which would
  # break if that agent is later deleted or a worker is created first). An
  # explicit --isolation always wins in either direction.
  if (( ! isolation_explicit )); then
    if [[ "$(registry_read | jq -r '(.agents // {}) | length')" == "0" ]]; then
      isolation="admin"
    else
      isolation="standard"
    fi
  fi
  valid_isolation "$isolation" || fail "$E_VALIDATION" "invalid --isolation (admin|standard|sandboxed)"
  valid_autonomy "$autonomy" || fail "$E_VALIDATION" "invalid --autonomy '$autonomy' (standard|yolo|son-of-anton)"
  # DIVE-1462/STEER-4: --can-push grants the delegated-push (builder) capability.
  # It is a STANDARD-isolation refinement: admin agents already reach `_push_do`
  # through their broad sudo (so the flag is a redundant no-op there — accept it,
  # just don't write a second grant), and sandboxed agents get no sudoers at all
  # so the capability is impossible. Refuse only the sandboxed contradiction.
  if (( can_push )); then
    case "$isolation" in
      sandboxed) fail "$E_VALIDATION" "--can-push is incompatible with --isolation=sandboxed (a sandboxed agent gets no sudoers, so it cannot be granted delegated push)." ;;
      admin)     can_push=0; warn "--can-push is redundant for an admin agent (admin sudo already permits '5dive _push_do'); ignoring." ;;
    esac
  fi
  # INST-5: --can-deploy, identical posture to --can-push above.
  if (( can_deploy )); then
    case "$isolation" in
      sandboxed) fail "$E_VALIDATION" "--can-deploy is incompatible with --isolation=sandboxed (a sandboxed agent gets no sudoers, so it cannot be granted delegated deploy)." ;;
      admin)     can_deploy=0; warn "--can-deploy is redundant for an admin agent (admin sudo already permits '5dive _deploy_do'); ignoring." ;;
    esac
  fi
  # DIVE-990: validate every inherit-memory scope token (wiki|all|team|<agent-name>).
  if [[ -n "$inherit_memory" ]]; then
    local _imt _imifs="$IFS"; IFS=,
    for _imt in $inherit_memory; do
      [[ "$_imt" =~ ^[a-z][a-z0-9-]*$ ]] \
        || { IFS="$_imifs"; fail "$E_VALIDATION" "invalid --inherit-memory scope '$_imt' (wiki|all|team|<agent-name>)"; }
    done
    IFS="$_imifs"
  fi
  if [[ -n "$workdir" ]]; then
    valid_workdir "$workdir" \
      || fail "$E_VALIDATION" "invalid --workdir (absolute path, allowed chars: letters/digits/._-/)"
  fi
  if [[ -n "$profile" ]]; then
    valid_profile_name "$profile" \
      || fail "$E_VALIDATION" "invalid --auth-profile (lowercase letters/digits/_-, start letter, <=32 chars)"
    if (( defer_auth )) || [[ -n "$byo_provider" ]]; then
      # "Set up later" path: the dashboard binds an auto-derived profile
      # (the slug) at create time before any auth has happened, so the
      # profile dir legitimately doesn't exist yet. Pre-create it now with
      # an empty combined.env so link_agent_profile's symlink target is
      # present (systemd's EnvironmentFile= loads the empty file as a
      # no-op) and the per-type *_HOME redirect (driven by
      # AGENT_AUTH_PROFILE in the unit env file) has a target dir for
      # first-run onboarding to write creds into.
      # Same treatment for the BYO API-key path: the dashboard's "fresh
      # account + paste key" flow names a new profile that doesn't exist
      # yet — apply_byo_provider populates the per-type dir below, and the
      # post-create auth gate accepts that as proof of auth.
      ensure_profile_dir "$profile" >/dev/null
    else
      # Non-defer path keeps the fail-fast check so a typo'd profile
      # name doesn't survive into agent state.
      [[ -f "${AUTH_PROFILES_DIR}/${profile}/combined.env" ]] \
        || fail "$E_NOT_FOUND" "auth profile '$profile' not configured — run: sudo 5dive agent auth set $type --api-key=... --auth-profile=$profile"
    fi
  fi

  if [[ "$channels" != "none" ]] && [[ "${TYPE_CHANNELS[$type]:-0}" != "1" ]]; then
    # Derive the supported list rather than hardcoding it: a hardcoded list is one
    # more place a new type has to be registered and silently won't be (DIVE-2076).
    local -a _ch_ok=()
    local _t
    for _t in "${!TYPE_CHANNELS[@]}"; do
      [[ "${TYPE_CHANNELS[$_t]:-0}" == "1" ]] && _ch_ok+=("$_t")
    done
    fail "$E_VALIDATION" "type '$type' does not support channels (only: ${_ch_ok[*]})"
  fi
  # codex + grok + antigravity + opencode ship a telegram bridge only — no discord build yet.
  if [[ "$type" == "codex" || "$type" == "grok" || "$type" == "antigravity" || "$type" == "opencode" ]] \
      && channel_in_list discord "$channels"; then
    fail "$E_VALIDATION" "type '$type' supports --channels=telegram only (no discord build)"
  fi
  # dashboard chat is a native-push claude plugin only (poll-fork runtimes
  # have no dashboard variant yet) — fail before any state is written.
  if [[ "$type" != "claude" ]] && channel_in_list dashboard "$channels"; then
    fail "$E_VALIDATION" "channels=dashboard is claude-only (got type=$type)"
  fi

  # DIVE-906: secrets via stdin, never argv. The "-" sentinel on --api-key,
  # --telegram-token, and --discord-token reads that value from stdin (same
  # contract as `config set *.token=-`, DIVE-880/888) so it never appears in
  # argv (and thus never in `ps`). The exec tunnel exposes a SINGLE stdin
  # channel, so at most ONE `=-` sentinel can be used per create — reject the
  # combination up front rather than blocking forever on a second `cat` that
  # will never receive input. Counted here (before the byo cat below rewrites
  # byo_api_key) so all three are still their raw sentinel values.
  local _stdin_sentinels=0
  # Pre-increment: `(( x++ ))` returns exit 1 when the pre-value is 0, which
  # trips `set -e`; `(( ++x ))` yields the new (>=1, truthy) value.
  [[ "$byo_api_key" == "-" ]]    && (( ++_stdin_sentinels ))
  [[ "$telegram_token" == "-" ]] && (( ++_stdin_sentinels ))
  [[ "$discord_token" == "-" ]]  && (( ++_stdin_sentinels ))
  (( _stdin_sentinels <= 1 )) \
    || fail "$E_USAGE" "only one of --api-key=- / --telegram-token=- / --discord-token=- can read from stdin per create (the exec tunnel has a single stdin channel)"

  # BYO API-key path (--provider=<canonical> + --api-key=<key|->).
  # Mutually exclusive with --defer-auth: BYO is the alternative to "I'll sign in
  # later", not an add-on. The key sentinel "-" reads from stdin so the value
  # never appears in argv (and thus never in `ps`).
  if [[ -n "$byo_provider" || -n "$byo_api_key" ]]; then
    # pi and opencode are API-key multi-provider types: --provider names the
    # vendor and the key is injected as its native environment variable, so
    # they skip the hermes/openclaw/claude BYO catalog checks below.
    [[ "$type" == "hermes" || "$type" == "openclaw" || "$type" == "claude" || "$type" == "pi" || "$type" == "opencode" ]] \
      || fail "$E_VALIDATION" "--provider/--api-key only supported for hermes/openclaw/claude/pi/opencode (got: $type)"
    # claude BYO points the harness at an Anthropic-compatible third-party
    # endpoint and stores the override env vars in the auth-profile's
    # combined.env — so it requires a profile to scope the creds to this agent
    # (otherwise the override would have to live in the shared default
    # connector and bleed into every other claude agent).
    [[ "$type" == "claude" && -z "$profile" ]] \
      && fail "$E_USAGE" "claude BYO (--provider) requires --auth-profile=<name> (custom-provider creds are profile-scoped)"
    [[ -n "$byo_provider" && -n "$byo_api_key" ]] \
      || fail "$E_USAGE" "--provider and --api-key must be passed together"
    (( defer_auth )) \
      && fail "$E_USAGE" "--defer-auth and --provider/--api-key are mutually exclusive"
    if [[ "$type" == "pi" ]]; then
      pi_provider_var "$byo_provider" >/dev/null \
        || fail "$E_VALIDATION" "pi provider '$byo_provider' not supported (known: ${!PI_PROVIDER_VAR[*]})"
    elif [[ "$type" == "opencode" ]]; then
      opencode_provider_var "$byo_provider" >/dev/null \
        || fail "$E_VALIDATION" "opencode provider '$byo_provider' not supported (known: ${!OPENCODE_PROVIDER_VAR[*]})"
    else
      valid_byo_provider "$byo_provider" \
        || fail "$E_VALIDATION" "unknown provider '$byo_provider' (known: ${!BYO_PROVIDER_LABEL[*]})"
      local _native
      _native=$(resolve_native_provider "$type" "$byo_provider")
      [[ -n "$_native" ]] \
        || fail "$E_VALIDATION" "$type does not support provider '$byo_provider'"
    fi
    if [[ -n "$byo_model" ]]; then
      valid_model "$byo_model" \
        || fail "$E_VALIDATION" "invalid --model '$byo_model' (allowed chars: letters/digits/._:/-)"
    fi
    if [[ "$byo_api_key" == "-" ]]; then
      [[ -t 0 ]] && fail "$E_USAGE" "--api-key=- expects the key on stdin, stdin is a TTY"
      byo_api_key=$(cat)
    fi
    valid_api_key "$byo_api_key" \
      || fail "$E_VALIDATION" "api key looks wrong (expected >=10 printable non-space chars)"
  fi

  # DIVE-906: drain the channel-token stdin sentinels. The guard above
  # guarantees at most one `=-` sentinel across api-key/telegram/discord, so if
  # the byo cat above already consumed stdin these are literal values (not "-")
  # and neither branch fires. Format validation happens in the channel blocks
  # below (valid_telegram_token / the discord non-empty check).
  if [[ "$telegram_token" == "-" ]]; then
    [[ -t 0 ]] && fail "$E_USAGE" "--telegram-token=- expects the bot token on stdin, stdin is a TTY"
    telegram_token=$(cat)
  fi
  if [[ "$discord_token" == "-" ]]; then
    [[ -t 0 ]] && fail "$E_USAGE" "--discord-token=- expects the bot token on stdin, stdin is a TTY"
    discord_token=$(cat)
  fi

  # Resolve --with-skills. Default policy: when this create call is being made
  # by another agent (SUDO_USER=agent-*), preinstall the 5dive-cli skill so
  # the new agent inherits inter-agent comms knowledge — applies to every
  # supported type, since the skills CLI handles per-type install paths via
  # --agent (see SKILLS_AGENT_ID above). Humans creating from the dashboard
  # get no skills by default — they typically don't need the recursion story
  # and the skill is just context noise. --no-skills opts out of the default;
  # --with-skills="" also opts out.
  local -a skills_specs=()
  if (( no_skills )); then
    :
  elif (( skills_set )); then
    if [[ -n "$skills_arg" ]]; then
      IFS=',' read -r -a skills_specs <<<"$skills_arg"
    fi
  else
    if [[ "${SUDO_USER:-}" == agent-* ]]; then
      skills_specs=("5dive-cli")
    fi
  fi
  # Validate every spec up front so we fail before adduser/registry mutation
  # on bad input. Empty entries (trailing comma) are skipped.
  local -a skills_resolved=()
  local s pair src sk
  for s in "${skills_specs[@]+"${skills_specs[@]}"}"; do
    [[ -z "$s" ]] && continue
    pair=$(parse_skill_spec "$s")
    src="${pair% *}"
    sk="${pair#* }"
    valid_skill_source "$src" \
      || fail "$E_VALIDATION" "invalid --with-skills source in '$s' (expected owner/repo, got '$src')"
    valid_skill_id "$sk" \
      || fail "$E_VALIDATION" "invalid --with-skills id in '$s' (got '$sk')"
    skills_resolved+=("${src}:${sk}")
  done

  # Telegram/Discord need their own bot/app token per agent — two agents can't
  # share a bot (both would call getUpdates and race each other). Require the
  # token at create time so the plugin doesn't spin up with empty creds.
  if channel_in_list telegram "$channels"; then
    # DIVE-320: --telegram-cos=<child-username> claims a CoS-minted child bot
    # token instead of pasting one. The customer's Chief-of-Staff bot must
    # already be set (`5dive agent cos set`) and the child bot must already be
    # created via the one-tap deep link (`cos mint-link`). The minted bot's
    # managed_bot update waits in the CoS getUpdates queue; `cos claim` fetches
    # the token + auto-configures name/description/avatar. Mutually exclusive
    # with an explicit --telegram-token; the paste path stays the fallback.
    if [[ -n "$telegram_cos" ]]; then
      [[ -z "$telegram_token" ]] \
        || fail "$E_USAGE" "--telegram-cos and --telegram-token are mutually exclusive (cos mints the token)"
      valid_telegram_bot_username "$telegram_cos" \
        || fail "$E_VALIDATION" "--telegram-cos must be the child bot's username (5-32 chars, ends in 'bot')"
      if [[ -n "$telegram_cos_avatar" ]]; then
        [[ -r "$telegram_cos_avatar" ]] \
          || fail "$E_NOT_FOUND" "--telegram-cos-avatar not readable: $telegram_cos_avatar"
      fi
      step "Claiming CoS-minted bot token for @$telegram_cos"
      local _cos_json _cos_rc=0 _cos_reason _cos_avatar_arg=()
      [[ -n "$telegram_cos_avatar" ]] && _cos_avatar_arg=(--avatar="$telegram_cos_avatar")
      # `|| _cos_rc=$?` so a non-zero claim doesn't trip errexit (set -e) before
      # we can map the failure — the same idiom used by every other fallible
      # command substitution in this file. A bare `_cos_json=$(...); rc=$?`
      # would abort the whole create at the assignment line on any failure.
      _cos_json=$(cmd_agent_cos claim --suggested="$telegram_cos" --name="$name" \
        --timeout-ms=120000 "${_cos_avatar_arg[@]+"${_cos_avatar_arg[@]}"}") || _cos_rc=$?
      if (( _cos_rc != 0 )); then
        # Map the failure to a precise exit class so the dashboard can give an
        # actionable message: a claim timeout (the user hasn't tapped the deep
        # link / created the bot yet) -> E_TIMEOUT; a missing CoS token (no
        # cos.env on the box) keeps the inner E_NOT_FOUND; anything else is
        # generic. The runner reports the cause in JSON `.reason`.
        _cos_reason=$(jq -r '.reason // empty' <<<"$_cos_json" 2>/dev/null)
        if [[ "$_cos_reason" == "timeout" ]]; then
          # A timeout has two likely causes and Telegram gives us no way to tell
          # them apart (a cap rejection silently produces no managed_bot update,
          # same as the user never tapping): either the Create link was not
          # tapped yet, OR the Chief-of-Staff account is at its managed-bot cap
          # (20 free / 40 with Telegram Premium). Name both so a whale is not
          # left guessing. (DIVE-323)
          fail "$E_TIMEOUT" "no bot @$telegram_cos appeared within the claim window — either you have not tapped the Create link in Telegram yet, or your Chief of Staff has hit its managed-bot limit (20 free, 40 with Telegram Premium). Tap the link to create it, or free a slot / upgrade to Premium, then retry"
        elif [[ "$_cos_reason" == "cos_token_stale" || "$_cos_reason" == "child_token_stale" ]]; then
          # DIVE-482: the CoS (or the just-minted child) token is dead — the bot
          # was deleted+recreated, so Telegram issued a new token and deactivated
          # the one we cached. Surface the runner's actionable detail as a
          # validation error (not a generic JSON blob) so the dashboard can route
          # the user to re-paste / rotate the token instead of a cryptic failure.
          local _cos_detail; _cos_detail=$(jq -r '.detail // empty' <<<"$_cos_json" 2>/dev/null)
          fail "$E_VALIDATION" "${_cos_detail:-Your Chief-of-Staff bot token is no longer valid — rotate it in BotFather and re-run: 5dive agent cos set --token=<new token>}"
        elif (( _cos_rc == E_NOT_FOUND )); then
          fail "$E_NOT_FOUND" "no Chief-of-Staff bot configured — run: 5dive agent cos set --token=<token>"
        fi
        fail "$E_GENERIC" "cos claim failed: ${_cos_json:-rc=$_cos_rc} (is the CoS bot set and the child bot created via the deep link?)"
      fi
      telegram_token=$(jq -r 'if .ok then .token else empty end' <<<"$_cos_json" 2>/dev/null)
      [[ -n "$telegram_token" ]] \
        || fail "$E_GENERIC" "cos claim returned no token: $_cos_json"
      # Learn the operator id from the mint event (the user who created the bot)
      # into the shared box-level allowlist — the common seed below auto-pairs
      # this agent (and every future one) to it. Keep the id around so we can
      # DM that owner a welcome message after auto-pair (the CoS path bypasses
      # cmd_pair, where the welcome normally fires).
      cos_owner_id=$(jq -r '.ownerId // empty' <<<"$_cos_json" 2>/dev/null)
      _operator_record "$cos_owner_id"
    fi
    if [[ -z "$telegram_token" ]]; then
      telegram_token=$(prompt_secret "Telegram bot token for agent '$name'") \
        || fail "$E_USAGE" "--channels=telegram requires --telegram-token=<token> or --telegram-cos=<child-username> (or run interactively to be prompted)"
    fi
    valid_telegram_token "$telegram_token" \
      || fail "$E_VALIDATION" "telegram token format looks wrong (expected <digits>:<20+ chars>)"
    if [[ -n "$telegram_home_channel" ]]; then
      valid_telegram_chat_id "$telegram_home_channel" \
        || fail "$E_VALIDATION" "invalid --telegram-home-channel (numeric chat id, optionally negative)"
    fi
    # Auto-pair: with no explicit allowlist, inherit the box's shared operator
    # id(s) (learned from prior pairings / a CoS mint) so the bot accepts the
    # operator's DMs immediately — no manual pairing step. Per-agent override
    # stays available via `telegram-access set`.
    if [[ -z "$telegram_allowed_users" ]]; then
      telegram_allowed_users=$(_operator_ids)
      [[ -n "$telegram_allowed_users" ]] \
        && step "Auto-pairing '$name' to known operator(s): $telegram_allowed_users"
    fi
    if [[ -n "$telegram_allowed_users" ]]; then
      valid_telegram_chat_id_list "$telegram_allowed_users" \
        || fail "$E_VALIDATION" "invalid --telegram-allowed-users (comma-separated numeric ids)"
    fi
  fi
  if channel_in_list discord "$channels"; then
    [[ -n "$discord_token" ]] \
      || fail "$E_USAGE" "--channels=discord requires --discord-token=<token>"
  fi

  ensure_state
  local reg
  reg=$(registry_read)
  if jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null; then
    fail "$E_CONFLICT" "agent '$name' already exists"
  fi
  # DIVE-2138: and refuse a stale home BEFORE any mutation. Deliberately placed
  # next to the name-conflict check rather than next to create_agent_user (~350
  # lines further down, after the team-bot attach and the registry write) — the
  # reported bug is that this failure used to happen there.
  agent_home_conflict_check "$name"

  # Install-on-demand: if the requested CLI isn't on disk, try the recipe.
  if [[ ! -x "${TYPE_BIN[$type]}" ]]; then
    if [[ -n "${TYPE_INSTALL[$type]:-}" ]]; then
      step "$type not installed — installing now"
      # cmd_install emits its own ok/fail; we want install output on stderr
      # (progress) so flip JSON_MODE off for the nested call and restore.
      local prev_json="$JSON_MODE"
      JSON_MODE=0
      cmd_install "$type" >&2
      JSON_MODE="$prev_json"
    else
      fail "$E_NOT_INSTALLED" "$type is not installed and no installer is configured (expected at ${TYPE_BIN[$type]})"
    fi
  fi

  # BYO API-key path: write the credential into the shared (or profile-scoped)
  # state dir before the auth gate runs — auth_status_one then sees the
  # sentinel and lets create proceed without falling back to "needs login".
  # Must come after the install-on-demand block so the agent CLI exists
  # when apply_byo_provider shells out to `hermes auth add`.
  if [[ -n "$byo_provider" ]]; then
    if [[ "$type" == "pi" ]]; then
      # pi injects the key as a native env var (no auth.json / endpoint
      # override), so it takes the env-var write path, not apply_byo_provider
      # (which is hermes/openclaw/claude only). DIVE-1200.
      pi_apply_provider_key "$byo_provider" "$byo_api_key" "$profile"
    elif [[ "$type" == "opencode" ]]; then
      # OpenCode consumes the selected provider's native API-key variable.
      # DIVE-1206: keep this on the same helper as `agent auth set` so a
      # create-time OpenRouter key reaches OPENROUTER_API_KEY, not OPENAI_API_KEY.
      opencode_apply_provider_key "$byo_provider" "$byo_api_key" "$profile"
    else
      apply_byo_provider "$type" "$byo_provider" "$byo_api_key" "$profile" "$byo_model"
    fi
  fi

  # Don't create an agent that can't log in. When an auth-profile is named,
  # accept either the profile's combined.env (api-key path / claude OAuth, which
  # promote tokens via profile_set_var) or the per-type credential file written
  # by the device-code flow (codex/hermes/openclaw write only auth.json /
  # auth-profiles.json — combined.env stays empty). Skip the
  # live probe here: a slow API blip shouldn't block `agent create`.
  # --defer-auth bypasses the gate: the caller (typically the dashboard's "Set
  # up later" wizard option) is opting to finish authentication inside the
  # agent's first-run UI on tmux attach.
  if (( defer_auth )); then
    :
  elif [[ -n "$profile" ]]; then
    local _profile_authed=0
    if [[ -s "${AUTH_PROFILES_DIR}/${profile}/combined.env" ]]; then
      _profile_authed=1
    else
      local _profile_auth_path
      _profile_auth_path=$(profile_type_auth_path "$profile" "$type" 2>/dev/null) || true
      [[ -n "$_profile_auth_path" && -s "$_profile_auth_path" ]] && _profile_authed=1
    fi
    (( _profile_authed )) \
      || fail "$E_AUTH_REQUIRED" "auth profile '$profile' is empty — run: sudo 5dive agent auth login $type --auth-profile=$profile (or: sudo 5dive agent auth set $type --api-key=... --auth-profile=$profile)"
  else
    local auth
    auth=$(auth_status_one "$type" --no-probe)
    if [[ "$auth" != "ok" ]]; then
      fail "$E_AUTH_REQUIRED" "$type is not authenticated ($auth) — run: sudo 5dive agent auth login $type (or: sudo 5dive agent auth set $type --api-key=<key>)"
    fi
  fi

  step "Creating user agent-${name}"
  create_agent_user "$name" "$isolation" "$can_push" "$can_deploy"

  if [[ "$isolation" == "sandboxed" ]]; then
    step "Applying sandbox resource limits for agent-${name}"
    local dropin_dir="/etc/systemd/system/5dive-agent@${name}.service.d"
    mkdir -p "$dropin_dir"
    printf '[Service]\nMemoryMax=512M\nCPUQuota=50%%\n' > "${dropin_dir}/isolation.conf"
    chmod 644 "${dropin_dir}/isolation.conf"
  fi

  # claude needs the onboarding preseed + settings the channel user got at
  # provision time — otherwise first run hits the theme picker / trust dialog
  # inside tmux. hermes/openclaw don't read ~/.claude (they have their own
  # state dirs), so preseeding it for them is just dead weight; their first-
  # run prompts are handled by their own CLIs.
  if [[ "$type" == "claude" ]]; then
    step "Preseeding claude config for agent-${name}"
    # A create-time BYO --model is per-agent intent. The auth profile's
    # ANTHROPIC_DEFAULT_* variables translate Claude's tier aliases, but the
    # preseeded settings.json model is the actual startup selection and used to
    # be hard-pinned to claude-opus-4-8, overriding that intent. Pass the model
    # through so this agent starts on the requested OpenRouter/vendor slug.
    local _claude_byo_model=""
    [[ -n "$byo_provider" ]] && _claude_byo_model="$byo_model"
    preseed_claude_agent "$name" "$channels" "$_claude_byo_model"
  elif [[ "$type" == "antigravity" ]]; then
    # antigravity needs no claude-style ~/.claude preseed (agy reads its own
    # ~/.gemini state). The default-skill seed every other type gets isn't
    # folded into a channel installer for the no-channel case, so run it
    # here unconditionally. When channels=telegram, install_channel_for_agent
    # (routed below) wires the bot token + access.json + notify-user skill on
    # top — the find-skills/5dive-cli seed below is idempotent so the overlap
    # is harmless.
    step "Preseeding antigravity default skills for agent-${name}"
    preseed_antigravity_agent "$name"

    # Seed the agy OAuth token into the agent user's runtime $HOME as root.
    # 5dive-agent-start also seeds at boot, but that path uses the agent's own
    # `sudo -n` to read the 0700 auth-profile dir — which only admin agents have
    # (standard/sandboxed get no NOPASSWD sudoers). Without seeding here a
    # non-admin agy agent boots unauthenticated and sits at the "select login
    # method" screen → the telegram bridge runs but the bot is silent (hit on a
    # customer standard-isolation create 2026-06-02). `agent create` runs as
    # root, so copy the token directly; agy is the only type whose credential is
    # a plain file (codex/grok land env/auth.json the agent can already read).
    local _agy_src _agy_home
    _agy_src=$(profile_type_auth_path "$profile" "$type" 2>/dev/null) || true
    if [[ -n "$_agy_src" ]] && [[ -s "$_agy_src" ]]; then
      _agy_home="/home/agent-${name}/.gemini/antigravity-cli"
      install -d -m 700 -o "agent-${name}" -g "agent-${name}" \
        "/home/agent-${name}/.gemini" "$_agy_home"
      if install -m 600 -o "agent-${name}" -g "agent-${name}" \
           "$_agy_src" "${_agy_home}/antigravity-oauth-token"; then
        step "Seeded agy OAuth token into agent-${name} runtime"
      fi
    fi
  elif [[ "$type" == "pi" && -n "$byo_model" ]]; then
    # DIVE-1205: pin the pi agent's default model. pi reads defaultProvider/
    # defaultModel from ~/.pi/agent/settings.json at startup (both the TUI and
    # the SDK the telegram-pi relay hosts pi through), so a create-time write
    # here makes the agent boot straight onto the chosen provider+model with no
    # /model step. Needed because pi has no PI_MODEL env var — the api-key is
    # env-injected (DIVE-1200) but the model selection is settings-file only.
    # Only pi's built-in providers reach this branch (validated above via
    # PI_PROVIDER_VAR), so pi already knows the base_url; we just name the model.
    pi_apply_model_default "$name" "$byo_provider" "$byo_model" "$byo_api_key"
  elif [[ "$type" == "opencode" && -n "$byo_model" ]]; then
    # OpenCode's persisted model uses provider_id/model_id. This lets an
    # OpenRouter-backed agent boot straight onto DeepSeek/GLM/Kimi/Qwen rather
    # than falling through to an unrelated last-used/default model. DIVE-1206.
    opencode_apply_model_default "$name" "$byo_provider" "$byo_model" "$byo_api_key"
  fi

  # DIVE-1535: give every new codex agent a return channel by default. A headless
  # codex worker (channels=none) prints its deliverable only to its own pane and
  # can't be polled, so seed the DIVE-1410 push-back convention into its standing
  # instructions. Non-destructive (skips an existing curated AGENTS.md) so it's
  # safe to run unconditionally for the type, independent of channel selection.
  if [[ "$type" == "codex" ]]; then
    step "Seeding a2a return-channel convention for agent-${name} (DIVE-1535)"
    preseed_codex_return_channel "$name" || true
  fi

  # DIVE-990: memory-as-onboarding. Seed the new agent's recall store from
  # shared team knowledge so it boots knowing the company. Runs after the user
  # exists (create_agent_user above) and before channels come up, so the store
  # is warm the moment the runtime starts. Store convention is ~/.claude/... for
  # every type (that's where `5dive memory` looks), so this is type-agnostic.
  if [[ -n "$inherit_memory" ]]; then
    step "Seeding inherited memory for agent-${name} (scope: $inherit_memory)"
    # Slug names the project dir under the agent's OWN home; `5dive memory`
    # globs every ~/.claude/projects/*/memory so the exact slug isn't load-
    # bearing, but the fleet convention (claude agents run from
    # /home/claude/projects/5dive) merges the seed with their working store.
    seed_inherited_memory "$name" "$inherit_memory" "${workdir:-/home/claude/projects/5dive}"
  fi

  # Channel registration is type-aware (see install_channel_for_agent's
  # comment above): claude installs claude-plugins-official's bun server,
  # openclaw shells out to `openclaw channels add`, hermes writes
  # ~/.hermes/.env. Each runs as agent-${name} so credentials land in that
  # user's home with correct ownership.
  local _ch
  for _ch in ${channels//,/ }; do
    case "$_ch" in
      telegram)
        install_channel_for_agent "$type" telegram "$name" "$telegram_token" \
          "$telegram_home_channel" "$telegram_allowed_users" ;;
      discord)
        install_channel_for_agent "$type" discord  "$name" "$discord_token" ;;
      # DIVE-841 dashboard chat: no token — the plugin reads the box's
      # connectord token from /etc/5dive/connectord.env itself.
      dashboard)
        install_channel_for_agent "$type" dashboard "$name" "" ;;
    esac
  done

  # Hermes BYO Kimi/Moonshot: KIMI_API_KEY lives in the agent user's
  # ~/.hermes/.env (hermes' Kimi provider reads it directly; there is no
  # `hermes auth add moonshot`). apply_byo_provider stamped it into the
  # shared dir for profile reuse; mirror it into the agent-user's .env here
  # so the gateway (started a few steps below) picks it up at first boot.
  # Runs after install_channel_for_agent so channel-token upserts can't
  # overwrite the KIMI_API_KEY line (they only touch their own var).
  if [[ "$type" == "hermes" && "$byo_provider" == "moonshot" ]]; then
    step "Seeding KIMI_API_KEY into ~/.hermes/.env for agent-${name}"
    seed_hermes_byo_env "$name" KIMI_API_KEY "$byo_api_key"
  fi

  if [[ -n "$telegram_token" ]]; then
    step "Writing telegram bot token (${CONNECTORS_DIR}/telegram-${name}.env)"
    write_channel_secret telegram "$name" TELEGRAM_BOT_TOKEN "$telegram_token"
  fi
  # CoS-create welcome DM: --telegram-cos auto-pairs the minting owner into
  # access.json at create time, which bypasses cmd_pair (where the welcome
  # message normally fires on a code-roundtrip pairing). Send it here so a
  # CoS-created bot greets its owner immediately. Best-effort — a send hiccup
  # must not fail an otherwise-successful create, so never abort on it.
  if [[ -n "$cos_owner_id" && -n "$telegram_token" ]] && channel_in_list telegram "$channels"; then
    step "Sending welcome DM to CoS owner ($cos_owner_id)"
    local cos_welcome_rc=0
    send_welcome_message "$cos_owner_id" "$telegram_token" "$name" "$type" || cos_welcome_rc=$?
    # rc 3 (DIVE-1768): the auto-paired owner has never opened this bot, so the
    # proactive welcome 403'd. Don't fail the create, but make the pending state
    # loud instead of silent so the owner knows to open the bot.
    if [[ "$cos_welcome_rc" -eq 3 ]]; then
      warn "Owner $cos_owner_id is allowlisted but has not opened this bot — welcome DM is pending. Open it in Telegram and press Start (or send any message) to receive it."
    fi
  fi
  if [[ -n "$discord_token" ]]; then
    step "Writing discord token (${CONNECTORS_DIR}/discord-${name}.env)"
    write_channel_secret discord "$name" DISCORD_BOT_TOKEN "$discord_token"
  fi

  # Sandboxed agents can't access /home/claude/projects (not in claude group).
  # Default their workdir to their own home so the TUI starts somewhere useful.
  if [[ "$isolation" == "sandboxed" && -z "$workdir" ]]; then
    workdir="/home/agent-${name}"
  fi

  step "Writing agent env"
  # DIVE-499: stamp the autonomy mode into the env file (yolo/son-of-anton add the
  # approved directive at launch; standard = nothing).
  _AUTONOMY_OVERRIDE="$autonomy" _CAN_PUSH_OVERRIDE="$can_push" _CAN_DEPLOY_OVERRIDE="$can_deploy" \
    write_agent_env "$name" "$type" "$channels" "$workdir" "$profile" "$isolation"
  link_agent_profile "$name" "$profile"

  # Resolve bot @username via Telegram getMe so the dashboard's agent list
  # can render a t.me/<bot> deep link without an extra round-trip per row.
  # Best-effort: a network blip here shouldn't fail agent creation — the
  # `agent telegram-info <name>` command can backfill on demand later.
  local bot_username=""
  if channel_in_list telegram "$channels" && [[ -n "$telegram_token" ]]; then
    bot_username=$(fetch_bot_username "$telegram_token" 2>/dev/null) || bot_username=""
  fi

  step "Registering in $REGISTRY"
  jq --arg n "$name" --arg t "$type" --arg c "$channels" --arg w "$workdir" --arg p "$profile" --arg bu "$bot_username" --arg ts "$(date -Iseconds)" --arg iso "$isolation" \
    '.agents[$n] = (
      {type: $t, channels: $c, createdAt: $ts, isolation: $iso}
      + (if $w == "" then {} else {workdir: $w} end)
      + (if $p == "" then {} else {authProfile: $p} end)
      + (if $bu == "" then {} else {botUsername: $bu} end)
    )' <<<"$reg" | registry_write

  # users.sh creates /home/claude/.hermes at 2770, but `hermes auth add
  # openai-codex` (kicked off by `agent auth start hermes` before create)
  # tightens it back to 0700 when writing auth.json. The chmod 0775 in the
  # install recipe only fires on the install path — short-circuited when the
  # binary already exists, and bypassed when auth runs after install. Without
  # group-traverse the systemd unit (which runs as agent-<name> in the claude
  # group) can't reach /home/claude/.hermes/hermes-agent/venv/bin/hermes and
  # crash-loops with `binary not installed`. Repair perms unconditionally
  # right before `systemctl enable --now`, regardless of what tightened them.
  if [[ "$type" == "hermes" ]] && [[ -d /home/claude/.hermes ]]; then
    chmod 0775 /home/claude/.hermes
    # DIVE-1394: hermes writes config.yaml/auth.json mode 0600 owner=claude, so
    # a standard-isolation agent (no passwordless sudo) can't read them and the
    # boot-time seed no-op'd — leaving the agent unconfigured on the Nous setup
    # wizard. Normalize the shared (no-profile) seed source to 0640 g=claude so
    # the plain-read seed path works for group-member agents. The profiled path
    # is already normalized by normalize_profile_seed_perms at bind time.
    for _hf in config.yaml auth.json; do
      if [[ -f "/home/claude/.hermes/${_hf}" ]]; then
        chgrp claude "/home/claude/.hermes/${_hf}" 2>/dev/null || true
        chmod 0640 "/home/claude/.hermes/${_hf}" 2>/dev/null || true
      fi
    done
  fi

  # Hermes onboarding finalization. The chat CLI's first-run check
  # (_has_any_provider_configured) inspects ~/.hermes/config.yaml for an
  # explicit model.provider/base_url. Without those, every fresh hermes
  # invocation hits "It looks like Hermes isn't configured yet -- run:
  # hermes setup" and the tmux loop sits at the prompt forever. Pin the
  # values to what the device-code OAuth flow already wrote into
  # auth.json's credential_pool, so the first launch lands straight in
  # chat. Skipped when --defer-auth is set: the user opted to finish
  # setup interactively on tmux attach, and we don't know which provider
  # they'll pick. Also skipped on the BYO path — apply_byo_provider
  # already wrote model.provider/model.default for the user's chosen
  # vendor; overwriting with openai-codex here would clobber the BYO
  # choice and route the agent at chatgpt.com instead of e.g. Anthropic.
  # The pin only matters when the profile *doesn't* already carry a
  # config.yaml. If it does (BYO write, or a prior device-code login that
  # left one behind), agent-start.sh will content-sync it into the agent's
  # per-user dir — and pinning openai-codex here would land a fresher
  # config.yaml at the per-user path, beating the seed's content-diff and
  # silently routing the agent back to chatgpt.com regardless of what the
  # profile says. Matches the same skip we apply when --provider is on argv.
  local _profile_has_hermes_cfg=0
  if [[ -n "$profile" ]] \
     && [[ -s "${AUTH_PROFILES_DIR}/${profile}/hermes/config.yaml" ]]; then
    _profile_has_hermes_cfg=1
  fi
  if [[ "$type" == "hermes" ]] && (( ! defer_auth )) && [[ -z "$byo_provider" ]] \
     && (( ! _profile_has_hermes_cfg )); then
    step "Pinning hermes model.provider for agent-${name}"
    local hermes_bin="${TYPE_BIN[hermes]}"
    sudo -u "agent-${name}" -H "$hermes_bin" config set model.provider openai-codex >&2 \
      || warn "hermes config set model.provider failed — first launch may show setup prompt (rerun: sudo -u agent-${name} -H $hermes_bin config set model.provider openai-codex)"
    sudo -u "agent-${name}" -H "$hermes_bin" config set model.base_url https://chatgpt.com/backend-api/codex >&2 \
      || warn "hermes config set model.base_url failed for agent '$name'"
    sudo -u "agent-${name}" -H "$hermes_bin" config set model.default gpt-5.5 >&2 \
      || warn "hermes config set model.default failed for agent '$name'"
  fi

  # For hermes telegram/discord channels, install + start the per-user
  # hermes messaging gateway. Skipped when --defer-auth: no auth means
  # the gateway can't talk to the model. See ensure_hermes_gateway for
  # the underlying systemd-user plumbing.
  if [[ "$type" == "hermes" ]] \
      && { channel_in_list telegram "$channels" || channel_in_list discord "$channels"; } \
      && (( ! defer_auth )); then
    ensure_hermes_gateway "$name"
  fi

  # DIVE-248 — auto-attach to the shared team bot. When this box has a team
  # bot configured (token + group persisted by `team-bot shared`), every new
  # relay-eligible agent (no personal bot, plugin-capable type) joins the team
  # group by default: own forum topic, send-only on the shared token, group
  # allowlisted. Opt out with --no-team-bot. Best-effort — a Telegram hiccup
  # must not roll back an otherwise healthy create.
  # Only channel-less creates qualify: the shared-attach path flips the agent
  # to channels=telegram (send-only), which would clobber a personal telegram
  # or discord setup requested in this very create.
  # MUST run before the service's first boot: the booting session races the
  # marketplace git clone inside the plugin install (ERR_STREAM_PREMATURE_CLOSE),
  # and the session should come up with the plugin already staged anyway.
  # _team_bot_do_shared's own restart at the end doubles as the first start.
  # "Channel-less" here means no personal bot (telegram/discord) — the
  # DIVE-856 default dashboard channel is not a bot and must not disqualify
  # an agent from the shared team group.
  local team_bot_status="off"
  if (( ! no_team_bot )) \
      && ! channel_in_list telegram "$channels" \
      && ! channel_in_list discord "$channels" \
      && [[ -r /etc/5dive/team-bot.token && -r /etc/5dive/team-bot.json ]]; then
    local tb_token tb_group tb_owner
    tb_token=$(cat /etc/5dive/team-bot.token 2>/dev/null)
    tb_group=$(jq -r '.group // empty' /etc/5dive/team-bot.json 2>/dev/null)
    tb_owner=$(jq -r '.owner // empty' /etc/5dive/team-bot.json 2>/dev/null)
    if [[ -z "$tb_token" || -z "$tb_group" ]]; then
      team_bot_status="off"
    elif _team_bot_relay_agent_list | grep -qxF "$name"; then
      step "Attaching $name to the shared team bot (group $tb_group)"
      local tb_prev_json="$JSON_MODE"
      JSON_MODE=0
      # Two attempts: on a never-booted agent, claude's first `plugin
      # marketplace add` reports a spurious ERR_STREAM_PREMATURE_CLOSE while
      # still completing the clone in the background (~5s) — the retry's
      # `marketplace update` then finds it and the install goes through.
      local tb_attached=0 tb_try
      for tb_try in 1 2; do
        if ( _team_bot_do_shared "$tb_group" "$tb_owner" "$name" "$tb_token" ) >/dev/null; then
          tb_attached=1; break
        fi
        (( tb_try == 1 )) && sleep 10
      done
      if (( tb_attached )); then
        team_bot_status="attached"
      else
        team_bot_status="failed"
        warn "team-bot auto-attach failed — agent is up; retry: sudo 5dive agent team-bot shared --group=$tb_group --agents=$name --token=<shared bot token>"
      fi
      JSON_MODE="$tb_prev_json"
    else
      # Team bot configured but this agent isn't a relay candidate (it has its
      # own personal bot, or its type ships no telegram plugin).
      team_bot_status="skipped"
    fi
  fi

  step "Enabling 5dive-agent@${name}.service"
  systemctl daemon-reload
  systemctl enable --now "5dive-agent@${name}.service" >&2

  # Install any preseeded skills. A failed install does NOT roll back the
  # agent — networks flake, the agent itself is fine, and the user can rerun
  # `5dive agent skill <name> add ...` to retry. We toggle JSON_MODE off
  # around cmd_skill_add and redirect its stdout so its own ok envelope
  # doesn't collide with this command's envelope; the failure path runs
  # under set -e because cmd_skill_add calls `fail` which exits — wrap in
  # a subshell so only the subshell exits, then catch the status.
  local installed_skills_json='[]' failed_skills_json='[]'
  if (( ${#skills_resolved[@]} > 0 )); then
    local prev_json="$JSON_MODE"
    JSON_MODE=0
    local entry pair src sk status
    for entry in "${skills_resolved[@]}"; do
      src="${entry%%:*}"
      sk="${entry##*:}"
      status=0
      ( cmd_skill_add "$name" --source="$src" --skill="$sk" ) >/dev/null || status=$?
      if (( status == 0 )); then
        installed_skills_json=$(jq -c --arg s "$src" --arg k "$sk" \
          '. + [{source:$s, skill:$k}]' <<<"$installed_skills_json")
      else
        warn "skill install failed for '$sk' from '$src' (exit $status) — agent is up; rerun: sudo 5dive agent skill $name add --source=$src --skill=$sk"
        failed_skills_json=$(jq -c --arg s "$src" --arg k "$sk" \
          '. + [{source:$s, skill:$k}]' <<<"$failed_skills_json")
      fi
    done
    JSON_MODE="$prev_json"
  fi

  # Wire paperclipai (running as user `claude`) to the new agent's auth so
  # its inner CLI-connection check stops reporting "not logged in" for this
  # type. No-op when the host-default credential location already holds a
  # real file — manual host logins win. Best-effort; never fails the create.
  paperclip_seed_for_type "$type" "$profile" 2>/dev/null || true

  local effective_workdir="${workdir:-$DEFAULT_WORKDIR}"
  # autoPaired: telegram agent whose allowFrom was seeded at create (explicit
  # --telegram-allowed-users or the shared operator store), so it accepts the
  # operator's DMs immediately — the dashboard uses this to safely skip the
  # pairing step only when pairing genuinely already happened.
  local auto_paired="false"
  [[ -n "$telegram_allowed_users" ]] && channel_in_list telegram "$channels" && auto_paired="true"
  # DIVE-1197: post-create self-health check — never leave a silently-deaf
  # agent looking healthy. Supersedes the DIVE-1190 telegram-only pair hint and
  # generalizes it: a freshly-created agent can look up-and-running yet be
  #   deaf     — a telegram/discord channel with an empty allowlist drops every DM
  #   mute     — the systemd unit / poller isn't actually active
  #   blind    — telegram getMe fails (token wrong/revoked)
  #   asleep   — no heartbeat, so it never self-acts on board work
  #   unauthed — auth was deferred, so its first turn stalls on login
  # We print a single PASS line when clean, or an itemized what-to-fix list with
  # the exact one-tap command for each gap. All to stderr so --json stdout stays
  # a clean envelope.
  local _hc_issues=() _hc_ok=()
  # reachability: systemd unit / poller actually running
  if systemctl is-active --quiet "5dive-agent@${name}.service" 2>/dev/null; then
    _hc_ok+=("poller up")
  else
    _hc_issues+=("service not active (agent is MUTE) — start it: sudo systemctl start 5dive-agent@${name}.service")
  fi
  # reachability: channel allowlist non-empty (deaf check) for each personal bot.
  # claude-family plugins persist access.json under ~/.<type>/channels/<ch>/;
  # a missing file or empty allowFrom means every inbound DM is refused.
  local _ch _access _n_allow _idlabel
  for _ch in telegram discord; do
    channel_in_list "$_ch" "$channels" || continue
    _access="/home/agent-${name}/.${type}/channels/${_ch}/access.json"
    _n_allow=0
    [[ -f "$_access" ]] && _n_allow=$(jq -r '(.allowFrom // []) | length' "$_access" 2>/dev/null || echo 0)
    if (( _n_allow > 0 )); then
      _hc_ok+=("$_ch paired (${_n_allow} allowed)")
    else
      if [[ "$_ch" == "discord" ]]; then
        _idlabel="yourDiscordUserId (enable Developer Mode, right-click your name -> Copy User ID)"
      else
        _idlabel="yourTelegramUserId (DM @userinfobot for your id)"
      fi
      _hc_issues+=("$_ch is DEAF (allowlist empty) — pair it: 5dive agent pair $name --user-id=<$_idlabel>")
    fi
  done
  # reachability: telegram getMe (the token actually resolves a live bot).
  # bot_username is only populated above for an exact channels==telegram create,
  # so re-probe here when telegram is present in a multi-channel set.
  if channel_in_list telegram "$channels" && [[ -n "$telegram_token" ]]; then
    local _bu="$bot_username"
    [[ -z "$_bu" ]] && _bu=$(fetch_bot_username "$telegram_token" 2>/dev/null || echo "")
    if [[ -n "$_bu" ]]; then
      _hc_ok+=("telegram getMe ok (@$_bu)")
    else
      _hc_issues+=("telegram getMe FAILED (agent is BLIND) — token may be wrong/revoked; re-check: 5dive agent telegram-getme --token=<token>")
    fi
  fi
  # autonomy: heartbeat enrolled so the agent self-acts on board tasks. Create
  # never wires heartbeat, so this normally fires — that's the point (DIVE-1197
  # gap "no heartbeat = won't self-act").
  local _hb
  _hb=$(jq -r --arg n "$name" '.agents[$n].heartbeat.enabled // false' <<<"$(registry_read)" 2>/dev/null || echo false)
  if [[ "$_hb" == "true" ]]; then
    _hc_ok+=("heartbeat on")
  else
    _hc_issues+=("no heartbeat (agent is ASLEEP — won't self-act on board work): sudo 5dive heartbeat on $name")
  fi
  # auth: deferred login still pending, so the first turn will stall.
  if (( defer_auth )); then
    _hc_issues+=("auth was deferred (agent is UNAUTHED — can't think until you log in): sudo 5dive agent auth login $type${profile:+ --auth-profile=$profile}")
  else
    # DIVE-2025: a completed login used to be checked by NOTHING — not even an
    # ok entry — so a credential that never reached the agent still printed
    # "self-check PASS". Probe the credential itself, as the agent's own uid.
    local _cred_line
    while IFS= read -r _cred_line; do
      [[ -n "$_cred_line" ]] || continue
      case "$_cred_line" in
        ok:*)    _hc_ok+=("${_cred_line#ok:}") ;;
        issue:*) _hc_issues+=("${_cred_line#issue:}") ;;
      esac
    done < <(selfcheck_cred_reached_agent "$name" "$type" "$profile" "$byo_provider")
  fi
  if (( ${#_hc_issues[@]} == 0 )); then
    warn "self-check PASS for '$name' — reachable & autonomous (${_hc_ok[*]})."
  else
    warn "self-check for '$name': ${#_hc_issues[@]} issue(s) will make it look broken until fixed:"
    local _hc_i
    for _hc_i in "${_hc_issues[@]}"; do warn "  - $_hc_i"; done
    (( ${#_hc_ok[@]} > 0 )) && warn "  (ok: ${_hc_ok[*]})"
  fi
  ok "agent '$name' (type=$type, channels=$channels${profile:+, profile=$profile}) is running." \
     '{name:$n, type:$t, channels:$c, workdir:$w, authProfile:$p, created:true, autoPaired:$ap, skills:{installed:$inst, failed:$fail}, teamBot:$tb}' \
     --arg n "$name" --arg t "$type" --arg c "$channels" --arg w "$effective_workdir" --arg p "${profile:-}" \
     --argjson ap "$auto_paired" \
     --argjson inst "$installed_skills_json" --argjson fail "$failed_skills_json" --arg tb "$team_bot_status"
}
