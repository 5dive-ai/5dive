# -------- DIVE-5190: box disk — the SAFE sweep and the low-disk alarm --------
#
# 2026-09-29 05:15Z lodar's own box (exact-swallow, 38G) hit 100%. What filled it
# was not user data: /tmp held 3.0G of Chrome leftovers — 256 entries of
# `.com.google.Chrome.*` (9.7M each) and `scoped_dir*` (52M each). Chrome leaves
# them when it is KILLED rather than closed, so a day of browser use grows the
# disk by gigabytes. main cleared it by hand (100% -> 87%) with the Chrome temp
# entries, the npm and nvm download caches, apt's archive cache and disabled snap
# revisions. This file is that hand-clear, made safe enough to run unattended.
#
# lodar, same thread: "deleting users storage unattended is not good idea can end
# up deleting something useful" / "so should be safe logic only". So:
#
# AN ALLOWLIST, NEVER A DENYLIST. Each class below is named, and anything not
# named is never touched — no home, no project, no agent memory or transcript,
# no model cache, no reaped-agent backup, no node version. A class is on the list
# only if a tool REBUILDS it on its own:
#
#   chrome-tmp  top-level entries of /tmp named `.com.google.Chrome.*`,
#               `.org.chromium.Chromium.*` or `scoped_dir*`, older than 60 min
#               (nothing inside modified since) AND not held by any process —
#               no open fd, no cwd, no memory map (Chrome MAPS its shared-memory
#               files, so an fd scan alone would call a live browser's file dead).
#               Regular files and directories only; a symlink is never followed.
#   npm         `npm cache clean --force`, per user, as that user — never rm on a
#               path. Skipped for a user with an npm/npx running right now.
#   nvm         `nvm cache clear`, per user, as that user.
#   apt         `apt-get clean`.
#   snap        `snap remove <name> --revision=<rev>` for revisions snapd itself
#               lists as `disabled`.
#   journald is NOT swept: install.sh already caps it with a SystemMaxUse drop-in
#               (DIVE-948), which is the bound the row asks for.
#
# THREE STATES for a chrome-tmp entry, and only one of them deletes: DEAD (old and
# unheld) is removed; LIVE (held) and YOUNG are kept; UNKNOWN is kept. UNKNOWN is
# what an unprivileged run sees for any entry whose owner has processes it cannot
# read — the cron runs as root, where the /proc scan is complete. The scan reads
# `Permission denied` specifically (LC_ALL=C): /proc churns while it is walked and
# a vanished pid is a race, not blindness (community/wiki/a-scoped-reclaim-behind-
# an-unscoped-alarm-can-only-offer-spend.md). A non-root run ignores root-owned
# holders it cannot see; it can only unlink its OWN entries anyway (sticky /tmp).
#
# THE ALARM. Under 5% free (lodar 2026-09-30: tell them at 95% full, not 90%)
# the box owner is told ONCE, through the same paired
# chat the gate alerts use, and is not told again until the disk recovers past
# the re-arm line. A tick that cannot deliver does not mark the episode told, so
# it retries next hour rather than going silent.
#
# CADENCE: /etc/cron.d/5dive-disk runs `disk tick` hourly. The tick sweeps once a
# day, or every hour while the disk is under the pressure line (10% free), then
# checks the alarm.

DISK_TMP_ROOT="${FIVEDIVE_DISK_TMP_ROOT:-/tmp}"
# Test seam: the harness points this at a proc tree of its own holders (plus a
# planted unreadable pid) so blindness is a fixture, not whatever else this uid
# happens to run. IGNORED as root: an empty proc root would make every entry read
# as unheld, and the cron is root.
DISK_PROC="/proc"
if [[ -n "${FIVEDIVE_DISK_PROC_ROOT:-}" && "$EUID" -ne 0 ]]; then DISK_PROC="$FIVEDIVE_DISK_PROC_ROOT"; fi
DISK_CHROME_MIN_AGE="${FIVEDIVE_DISK_CHROME_MIN_AGE_MIN:-60}"
DISK_SWEEP_LOG="${FIVEDIVE_DISK_SWEEP_LOG:-/var/log/5dive/disk-sweep.log}"
DISK_ALARM_PATH="${FIVEDIVE_DISK_ALARM_PATH:-/}"
DISK_ALARM_PCT="${FIVEDIVE_DISK_ALARM_PCT:-5}"
DISK_REARM_PCT="${FIVEDIVE_DISK_REARM_PCT:-10}"
DISK_PRESSURE_PCT="${FIVEDIVE_DISK_PRESSURE_PCT:-10}"   # hourly sweeps start here, ahead of the alarm
DISK_SWEEP_EVERY="${FIVEDIVE_DISK_SWEEP_EVERY_S:-82800}"   # ~daily; the cron is hourly
DISK_PRESSURE_SWEEP_EVERY="${FIVEDIVE_DISK_PRESSURE_SWEEP_EVERY_S:-3600}"

_disk_state_file() { printf '%s/disk.json' "$STATE_DIR"; }
_disk_is_root()    { [[ "${FIVEDIVE_DISK_EUID:-$EUID}" -eq 0 ]]; }

_disk_log() {
  local line; line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  printf '%s\n' "$line"
  mkdir -p "$(dirname "$DISK_SWEEP_LOG")" 2>/dev/null || true
  printf '%s\n' "$line" >>"$DISK_SWEEP_LOG" 2>/dev/null || true
}

# Percent of the filesystem still free to write, the way df's Use% counts it
# (used/(used+avail)), so this and `df -h` never disagree. Test seam: a fake
# "<used_kb> <avail_kb>" pair.
_disk_free_pct() {
  local used avail
  if [[ -n "${FIVEDIVE_DISK_FAKE_DF:-}" ]]; then read -r used avail <<<"$FIVEDIVE_DISK_FAKE_DF"
  else read -r used avail < <(df -P -k "$1" 2>/dev/null | awk 'NR==2{print $3, $4}'); fi
  [[ "${used:-}" =~ ^[0-9]+$ && "${avail:-}" =~ ^[0-9]+$ ]] || return 1
  (( used + avail > 0 )) || return 1
  printf '%s' $(( avail * 100 / (used + avail) ))
}

_disk_kb() { local k; k=$(du -sk -x -- "$1" 2>/dev/null | awk '{print $1}') || true; printf '%s' "${k:-0}"; }
_disk_dry_tag() { if [[ "$1" == 1 ]]; then printf ' dry_run=1'; fi; }

# _disk_scan_holders — every path under DISK_TMP_ROOT that a live process holds
# (fd, cwd or memory map) goes into _DISK_HELD; the uid of every process we could
# not read goes into _DISK_BLIND. Globals, not stdout: `x=$(fn)` would run this in
# a subshell and lose the blind set, which is a flag about the measurement.
declare -gA _DISK_HELD=() _DISK_BLIND=()
_disk_scan_holders() {
  _DISK_HELD=() _DISK_BLIND=()
  local root="$DISK_TMP_ROOT" errf p pid uid
  errf=$(mktemp) || return 1
  while IFS= read -r p; do
    [[ -n "$p" ]] && _DISK_HELD["$p"]=1
  done < <(
    LC_ALL=C find "$DISK_PROC"/[0-9]*/fd "$DISK_PROC"/[0-9]*/cwd -maxdepth 1 -lname "$root/*" -printf '%l\n' 2>>"$errf"
    LC_ALL=C grep -hF -- " $root/" "$DISK_PROC"/[0-9]*/maps 2>>"$errf" \
      | awk -v r="$root/" '{i=index($0, r); if (i) { s=substr($0, i); sub(/ \(deleted\)$/, "", s); print s }}'
  )
  while IFS= read -r pid; do
    # EFFECTIVE uid: it is what owns /proc/<pid>/fd, and so what we are blind to.
    uid=$(awk '/^Uid:/{print $3; exit}' "$DISK_PROC/$pid/status" 2>/dev/null) || uid=""
    [[ -n "$uid" ]] && _DISK_BLIND["$uid"]=1
  done < <(grep -F 'Permission denied' "$errf" | grep -oE "^[a-z]+: '?$DISK_PROC/[0-9]+/" | grep -oE '[0-9]+/$' | tr -d / | sort -u)
  rm -f "$errf"
}

# _disk_held <entry> — is the entry, or anything under it, held by a process?
_disk_held() {
  local e="$1" p
  [[ -n "${_DISK_HELD[$e]:-}" ]] && return 0
  for p in "${!_DISK_HELD[@]}"; do
    [[ "$p" == "$e/"* ]] && return 0
  done
  return 1
}

# _disk_sweep_chrome_tmp <dry> — the one class that deletes by path, so it carries
# every guard. Prints one summary line.
_disk_sweep_chrome_tmp() {
  local dry="$1" e kb owner mode me freed=0 removed=0 live=0 young=0 unknown=0 failed=0 blind_other=0 u
  me=$(id -u)
  [[ -d "$DISK_TMP_ROOT" ]] || { _disk_log "disk-sweep class=chrome-tmp skipped=no-dir root=$DISK_TMP_ROOT"; return 0; }
  _disk_scan_holders || { _disk_log "disk-sweep class=chrome-tmp skipped=scan-failed"; return 0; }
  for u in "${!_DISK_BLIND[@]}"; do [[ "$u" != 0 ]] && blind_other=1; done
  while IFS= read -r -d '' e; do
    owner=$(stat -c %u -- "$e" 2>/dev/null) || continue
    mode=$(stat -c %a -- "$e" 2>/dev/null) || continue
    if ! _disk_is_root && [[ "$owner" != "$me" ]]; then continue; fi
    # UNKNOWN: a process we could not read could be holding it.
    if [[ -n "${_DISK_BLIND[$owner]:-}" ]] || { (( 10#${mode: -2} != 0 )) && (( blind_other )); }; then
      unknown=$((unknown + 1)); continue
    fi
    if [[ -n "$(find "$e" -mmin "-$DISK_CHROME_MIN_AGE" -print -quit 2>/dev/null)" ]]; then
      young=$((young + 1)); continue
    fi
    if _disk_held "$e"; then live=$((live + 1)); continue; fi
    kb=$(_disk_kb "$e")
    if [[ "$dry" == 1 ]]; then
      removed=$((removed + 1)); freed=$((freed + kb))
    elif rm -rf --one-file-system -- "$e" 2>/dev/null && [[ ! -e "$e" ]]; then
      removed=$((removed + 1)); freed=$((freed + kb))
    else
      failed=$((failed + 1))
    fi
  done < <(find "$DISK_TMP_ROOT" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) \
             \( -name '.com.google.Chrome.*' -o -name '.org.chromium.Chromium.*' -o -name 'scoped_dir*' \) \
             -print0 2>/dev/null)
  _DISK_FREED_KB=$(( _DISK_FREED_KB + freed ))
  _disk_log "disk-sweep class=chrome-tmp freed_kb=$freed removed=$removed kept_live=$live kept_young=$young kept_unknown=$unknown failed=$failed$(_disk_dry_tag "$dry")"
}

# Users whose caches the sweep may clean, as "name:home" lines: root and real
# login accounts (uid >= 1000), never nobody. Test seam: FIVEDIVE_DISK_USERS.
_disk_users() {
  if [[ -n "${FIVEDIVE_DISK_USERS:-}" ]]; then tr ' ' '\n' <<<"$FIVEDIVE_DISK_USERS"; return 0; fi
  getent passwd | awk -F: '($3 == 0 || $3 >= 1000) && $3 != 65534 && $6 != "" {print $1 ":" $6}'
}

# _disk_as <user> <cmd...> — run a cleaner as the cache's owner, so it can never
# write a root-owned file into a user's home.
_disk_as() {
  local u="$1"; shift
  if [[ "$u" == "$(id -un)" ]]; then "$@"; else sudo -n -u "$u" -H "$@"; fi
}

# The npm a user would get: their nvm's newest, else the one on PATH. Any npm
# cleans the same ~/.npm cache; node has to sit next to it on PATH.
_disk_npm_for() {
  local home="$1" n
  n=$(ls -1d "$home"/.nvm/versions/node/*/bin/npm 2>/dev/null | sort -V | tail -1) || n=""
  [[ -n "$n" && -x "$n" ]] || n=$(command -v npm 2>/dev/null) || n=""
  printf '%s' "$n"
}

_disk_sweep_node_caches() {
  local dry="$1" line u home npm before after freed=0 cleaned=0 busy=0 skipped=0 nvm_freed=0 nvm_cleaned=0
  while IFS= read -r line; do
    u="${line%%:*}" home="${line#*:}"
    [[ -n "$u" && -d "$home" ]] || continue
    if ! _disk_is_root && [[ "$u" != "$(id -un)" ]]; then continue; fi
    if [[ -d "$home/.npm/_cacache" ]]; then
      npm=$(_disk_npm_for "$home")
      if [[ -z "$npm" ]]; then skipped=$((skipped + 1))
      elif pgrep -u "$u" -f 'npm-cli\.js|npx-cli\.js|/bin/npm( |$)|/bin/npx( |$)' >/dev/null 2>&1; then busy=$((busy + 1))
      else
        before=$(_disk_kb "$home/.npm/_cacache")
        if [[ "$dry" == 1 ]]; then freed=$((freed + before)); cleaned=$((cleaned + 1))
        elif _disk_as "$u" env HOME="$home" PATH="$(dirname "$npm"):/usr/local/bin:/usr/bin:/bin" \
               timeout 600 "$npm" cache clean --force >/dev/null 2>&1; then
          after=$(_disk_kb "$home/.npm/_cacache"); freed=$((freed + (before > after ? before - after : 0))); cleaned=$((cleaned + 1))
        else skipped=$((skipped + 1)); fi
      fi
    fi
    if [[ -s "$home/.nvm/nvm.sh" && -d "$home/.nvm/.cache" ]]; then
      before=$(_disk_kb "$home/.nvm/.cache")
      if [[ "$dry" == 1 ]]; then nvm_freed=$((nvm_freed + before)); nvm_cleaned=$((nvm_cleaned + 1))
      elif _disk_as "$u" env HOME="$home" NVM_DIR="$home/.nvm" timeout 300 bash -c \
             '. "$NVM_DIR/nvm.sh" --no-use >/dev/null 2>&1 && nvm cache clear' >/dev/null 2>&1; then
        after=$(_disk_kb "$home/.nvm/.cache"); nvm_freed=$((nvm_freed + (before > after ? before - after : 0))); nvm_cleaned=$((nvm_cleaned + 1))
      fi
    fi
  done < <(_disk_users)
  _DISK_FREED_KB=$(( _DISK_FREED_KB + freed + nvm_freed ))
  _disk_log "disk-sweep class=npm freed_kb=$freed users_cleaned=$cleaned users_busy=$busy users_skipped=$skipped"
  _disk_log "disk-sweep class=nvm freed_kb=$nvm_freed users_cleaned=$nvm_cleaned"
}

_disk_sweep_system() {
  local dry="$1" before after freed name rev removed=0
  if ! _disk_is_root; then _disk_log "disk-sweep class=apt skipped=not-root"; _disk_log "disk-sweep class=snap skipped=not-root"; return 0; fi
  if command -v apt-get >/dev/null 2>&1; then
    before=$(_disk_kb /var/cache/apt/archives)
    if [[ "$dry" == 1 ]]; then freed=$before
    else timeout 300 apt-get clean >/dev/null 2>&1 || true; after=$(_disk_kb /var/cache/apt/archives); freed=$(( before > after ? before - after : 0 )); fi
    _DISK_FREED_KB=$(( _DISK_FREED_KB + freed ))
    _disk_log "disk-sweep class=apt freed_kb=$freed"
  fi
  if command -v snap >/dev/null 2>&1; then
    before=$(_disk_kb /var/lib/snapd/snaps)
    while read -r name rev; do
      [[ -n "$name" && "$rev" =~ ^[0-9]+$ ]] || continue
      if [[ "$dry" == 1 ]] || timeout 300 snap remove "$name" --revision="$rev" >/dev/null 2>&1; then removed=$((removed + 1)); fi
    done < <(LC_ALL=C snap list --all 2>/dev/null | awk 'NR>1 && $NF ~ /(^|,)disabled(,|$)/ {print $1, $3}')
    after=$(_disk_kb /var/lib/snapd/snaps); freed=$(( before > after ? before - after : 0 ))
    _DISK_FREED_KB=$(( _DISK_FREED_KB + freed ))
    _disk_log "disk-sweep class=snap freed_kb=$freed revisions_removed=$removed$(_disk_dry_tag "$dry")"
  fi
}

_DISK_FREED_KB=0
cmd_disk_sweep() {
  local dry=0 a pct_before pct_after
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      -h|--help) echo "usage: 5dive disk sweep [--dry-run]   # delete ONLY rebuildable caches (see: 5dive disk --help)"; return 0 ;;
      *) die "disk sweep: unknown flag '$a'" ;;
    esac
  done
  _DISK_FREED_KB=0
  pct_before=$(_disk_free_pct "$DISK_ALARM_PATH" || echo '?')
  _disk_sweep_chrome_tmp "$dry"
  _disk_sweep_node_caches "$dry"
  _disk_sweep_system "$dry"
  pct_after=$(_disk_free_pct "$DISK_ALARM_PATH" || echo '?')
  _disk_log "disk-sweep total freed_kb=$_DISK_FREED_KB free_pct_before=$pct_before free_pct_after=$pct_after$(_disk_dry_tag "$dry")"
}

# The owner's normal channel: the paired chat of the first telegram-enabled seat,
# the same resolution `digest tick` uses. Returns 0 only on a Bot API receipt.
_disk_alarm_deliver() {
  local msg="$1" name names
  names=$(jq -r '.agents | keys[]' "$REGISTRY" 2>/dev/null)   # captured: the loop returns early
  while IFS= read -r name; do
    [[ -n "$name" && -r "${CONNECTORS_DIR}/telegram-${name}.env" ]] || continue
    _task_agent_channel "$name" || continue
    _task_send_owner "$msg"
    [[ "${TASK_SEND_DELIVERED:-0}" == 1 ]] && return 0
  done <<<"$names"
  return 1
}

_disk_state_get() { jq -r "$1 // empty" "$(_disk_state_file)" 2>/dev/null || true; }
_disk_state_set() { # <jq filter> [--arg k v]...
  local f; f="$(_disk_state_file)"; local cur='{}'
  [[ -s "$f" ]] && cur=$(cat "$f" 2>/dev/null)
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  # Never fatal: under the bundle's `set -e` a failed state write would kill the
  # tick before the alarm ran. A lost stamp costs one extra sweep, nothing more.
  { jq "${@:2}" "$1" <<<"$cur" >"$f.tmp" && mv -f "$f.tmp" "$f"; } 2>/dev/null || _disk_log "disk-state write failed: $f"
}

cmd_disk_alarm() {
  local pct told msg host
  pct=$(_disk_free_pct "$DISK_ALARM_PATH") || { _disk_log "disk-alarm unreadable path=$DISK_ALARM_PATH"; return 0; }
  told=$(_disk_state_get '.alarm_told')
  if (( pct >= DISK_REARM_PCT )); then
    if [[ "$told" == true ]]; then _disk_state_set '.alarm_told=false'; _disk_log "disk-alarm re-armed free_pct=$pct"; fi
    return 0
  fi
  (( pct < DISK_ALARM_PCT )) || return 0
  if [[ "$told" == true ]]; then _disk_log "disk-alarm low free_pct=$pct already_told=1"; return 0; fi
  host=$(hostname -s 2>/dev/null || echo 'your box')
  msg="Your 5dive box ${host} is almost out of disk space: ${pct}% free. I already cleared the caches that are safe to delete, and it is still low. When it reaches 0, agents and the browser stop working. Ask your agent what is using the space and what you would like to remove."
  if _disk_alarm_deliver "$msg"; then
    _disk_state_set '.alarm_told=true | .alarm_told_at=$t | .alarm_free_pct=($p|tonumber)' --arg t "$(date -u +%FT%TZ)" --arg p "$pct"
    _disk_log "disk-alarm told owner free_pct=$pct"
  else
    _disk_log "disk-alarm UNDELIVERED free_pct=$pct (no paired chat answered; retrying next tick)"
  fi
}

# Hourly from /etc/cron.d/5dive-disk. Always returns 0: a cron that fails loudly
# every hour mails root and fixes nothing.
cmd_disk_tick() {
  local now last pct
  now=$(date +%s); last=$(_disk_state_get '.last_sweep_at'); [[ "$last" =~ ^[0-9]+$ ]] || last=0
  pct=$(_disk_free_pct "$DISK_ALARM_PATH" || echo 100)
  if (( now - last >= DISK_SWEEP_EVERY )) || { (( pct < DISK_PRESSURE_PCT )) && (( now - last >= DISK_PRESSURE_SWEEP_EVERY )); }; then
    cmd_disk_sweep || true
    _disk_state_set '.last_sweep_at=($t|tonumber)' --arg t "$now"
  fi
  cmd_disk_alarm || true
  return 0
}

cmd_disk() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    sweep) cmd_disk_sweep "$@" ;;
    alarm) cmd_disk_alarm "$@" ;;
    tick)  cmd_disk_tick "$@" ;;
    ""|-h|--help|help)
      cat <<'EOF'
usage: 5dive disk sweep [--dry-run]   delete ONLY caches a tool rebuilds on its own:
                                      old, unheld Chrome temp files in /tmp; npm and nvm
                                      download caches (via npm/nvm); apt-get clean;
                                      disabled snap revisions. Logs what it freed.
       5dive disk alarm               tell the box owner once when the disk is under 5% free
       5dive disk tick                the hourly cron driver: daily sweep (hourly under
                                      pressure), then the alarm
Never touched: homes, projects, agent memory and transcripts, model caches,
reaped-agent backups, node versions. Log: /var/log/5dive/disk-sweep.log
EOF
      ;;
    *) die "disk: unknown subcommand '$sub' (try: 5dive disk --help)" ;;
  esac
}
