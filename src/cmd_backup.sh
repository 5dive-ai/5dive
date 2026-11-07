# -------- 5dive backup (DIVE-7873) --------
#
# Every night the box sends an encrypted, deduplicated copy of its agents (homes,
# memory, chats, registry, task board, box config) to Cloudflare R2, a provider
# other than the one the box runs on. A restore is a fresh box plus that copy.
# The existing provider snapshots stay as they are; this is an extra copy.
#
# THE KEY IS THE OWNER'S (lodar 2026-11-07: «i hope we will not see any files»).
# restic encrypts with a password made HERE, on the box, and shown to the owner
# once as a recovery code. The API, the prod DB, R2 and every 5dive seat only
# ever see ciphertext: nothing in this file sends the code anywhere except to
# restic (through a 0600 file, never argv) and once to the owner's own Telegram
# DM from the box's own bot. If an owner loses both the box and the code, nobody
# can restore it, 5dive included. The message that carries the code says so.
#
# STORAGE ISOLATION is Cloudflare's, minted by the API (5dive-api
# src/lib/r2-backup.ts): before every run the box enrols with its box identity
# (CONNECTORD_TOKEN, the DIVE-5168 rule: on curl's stdin, never argv) and gets a
# 36 h R2 temporary credential for its OWNER's prefix `o-<hash>/` in one shared
# bucket, and nothing else. A box cannot name another prefix; the API derives it
# from the authenticated box. Under that prefix each box writes its own restic
# repository `box-<server id>`, so a fresh box of the same owner can restore a
# named older one.
#
# Layout (FIVE_BACKUP_* are harness seams; nothing on a box sets them):
#   /etc/5dive/backup/key      the recovery code, normalised (0600 root)
#   /etc/5dive/backup/r2.env   endpoint, bucket, prefix, repo, the current 36 h credential (0600 root)
#   /var/lib/5dive/backup/     status.json, state, code-delivered, run.lock (not in the copy)
#   /var/lib/5dive/backup-users.tsv  the agent users by uid, so a restore can recreate them
#   /etc/cron.d/5dive-backup   the nightly run
BACKUP_RESTIC_VERSION="0.17.3"
declare -A BACKUP_RESTIC_SHA256=(
  [amd64]="5097faeda6aa13167aae6e36efdba636637f8741fed89bbf015678334632d4d3"
  [arm64]="db27b803534d301cef30577468cf61cb2e242165b8cd6d8cd6efd7001be2e557"
)
# The recovery code's alphabet: no 0/O/1/I, so it survives being read aloud or
# copied by hand. 28 symbols of 32 = 140 bits.
BACKUP_CODE_ALPHABET="ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
BACKUP_CODE_LEN=28

_bk_dir()    { printf '%s' "${FIVE_BACKUP_DIR:-/etc/5dive/backup}"; }
_bk_state()  { printf '%s' "${FIVE_BACKUP_STATE:-${STATE_DIR:-/var/lib/5dive}/backup}"; }
_bk_cron()   { printf '%s' "${FIVE_BACKUP_CRON:-/etc/cron.d/5dive-backup}"; }
_bk_root()   { printf '%s' "${FIVE_BACKUP_ROOT:-}"; }   # prefix for every restored path (harness)
_bk_restic() { printf '%s' "${FIVE_BACKUP_RESTIC:-/usr/local/bin/restic}"; }
_bk_users()  { printf '%s' "${FIVE_BACKUP_USERS:-${STATE_DIR:-/var/lib/5dive}/backup-users.tsv}"; }   # inside /var/lib/5dive, so it rides the copy
_bk_log()    { printf '%s' "${FIVE_BACKUP_LOG:-/var/log/5dive/backup.log}"; }
_bk_connectord_env() { printf '%s' "${FIVE_CONNECTORD_ENV:-/etc/5dive/connectord.env}"; }

# What a restore needs to bring the agents back working. /etc/systemd/system is
# kept whole in the copy but only the 5dive agent drop-ins come back (below).
BACKUP_PATHS=(
  /home
  /var/lib/5dive
  /etc/5dive
  /etc/claude-code
  /etc/sudoers.d
  /etc/systemd/system
  /var/spool/cron/crontabs
)
# Caches, build output and our own local backups: big, and rebuilt on demand.
BACKUP_EXCLUDES=(
  node_modules .cache .npm .bun/install/cache .local/share/pnpm .pnpm-store
  .cargo/registry go/pkg/mod .gradle/caches __pycache__ .venv/lib .next/cache
  'Cache' 'Code Cache' 'GPUCache' 'Service Worker/CacheStorage' 'ShaderCache'
  /etc/5dive/backup
  /var/lib/5dive/backup
  /var/lib/5dive/tasks-backups /var/lib/5dive/cli-backups /var/lib/5dive/snapshots
  /var/lib/5dive/crucial-backups /var/lib/5dive/plugins-mirror.git
  '*.bak-*' '*.bak.*' 'cli-version.bak*'
  /home/.5dive-reaped
)
# A restore must never bring back the OLD box's identity onto the new one: the
# new box enrolled with its own token, name and API base.
BACKUP_RESTORE_SKIP=(
  /etc/5dive/connectord.env /etc/5dive/provisioning.env /etc/5dive/api-base
  /etc/5dive/backup /var/lib/5dive/backup
  /var/lib/5dive/cli-version /var/lib/5dive/cli-target.json
)

_backup_usage() {
  cat <<'EOF'
usage: 5dive backup <command>

Nightly encrypted copy of this box's agents in Cloudflare R2, outside the
server provider. Only the owner holds the key (the recovery code).

  enable [--auto] [--new-key]
                        set up and schedule the nightly backup (root). Makes the
                        key, sends the owner the recovery code once. --auto: the
                        unattended form the nightly update runs; it never fails it.
                        A box whose owner already has a backup waits for a restore
                        instead; --new-key starts a new key anyway (the owner lost
                        the old code and gives up those backups).
  run                   back up now (root; the nightly job runs this)
  status [--json]       last backup, its result, and whether it is scheduled
  code                  show the recovery code again (root)
  restore --code=<code> [--from=<box-N>] [--snapshot=<id>] [--yes]
                        on a fresh box: bring back a backup of this owner's box
                        (default: this box's own; --from names an older box)
  sources               the boxes of this owner that have a backup

The recovery code is the only key. 5dive cannot read the backups and cannot
restore them without it.
EOF
}

cmd_backup() {
  local sub="${1:-}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    enable)  cmd_backup_enable "$@" ;;
    run)     cmd_backup_run "$@" ;;
    status)  cmd_backup_status "$@" ;;
    code)    cmd_backup_code "$@" ;;
    restore) cmd_backup_restore "$@" ;;
    sources) cmd_backup_sources "$@" ;;
    ""|-h|--help|help) _backup_usage ;;
    *) fail "$E_USAGE" "unknown backup command: $sub (see: 5dive backup --help)" ;;
  esac
}

# ---- the recovery code ----------------------------------------------------------

_bk_code_new() {
  local c
  # tr dies of SIGPIPE when head has enough; under pipefail that is not a failure.
  c=$(LC_ALL=C tr -dc "$BACKUP_CODE_ALPHABET" </dev/urandom 2>/dev/null | head -c "$BACKUP_CODE_LEN") || true
  [[ ${#c} -eq $BACKUP_CODE_LEN ]] || return 1
  printf '%s' "$c"
}
# Uppercase, drop spaces and dashes; anything else outside the alphabet refuses.
_bk_code_normalize() {
  local c="${1^^}"; c="${c//[[:space:]-]/}"
  [[ ${#c} -eq $BACKUP_CODE_LEN && "$c" =~ ^[${BACKUP_CODE_ALPHABET}]+$ ]] || return 1
  printf '%s' "$c"
}
_bk_code_pretty() { printf '%s' "$1" | sed -E 's/(....)/\1-/g; s/-$//'; }

_bk_write0600() {   # <path> <content>
  local d tmp; d=$(dirname "$1"); mkdir -p "$d" && chmod 0700 "$d" 2>/dev/null
  tmp=$(mktemp "$1.XXXXXX") || return 1
  chmod 0600 "$tmp" && printf '%s' "$2" >"$tmp" && mv -f "$tmp" "$1" || { rm -f "$tmp"; return 1; }
}

# ---- restic -------------------------------------------------------------------

_bk_restic_install() {
  local bin arch sum tmp; bin=$(_bk_restic)
  if [[ -x "$bin" ]] && "$bin" version 2>/dev/null | grep -q "restic ${BACKUP_RESTIC_VERSION} "; then return 0; fi
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) return 1 ;; esac
  sum="${BACKUP_RESTIC_SHA256[$arch]}"
  tmp=$(mktemp -d) || return 1
  if curl -fsSL --max-time 120 -o "$tmp/r.bz2" \
       "https://github.com/restic/restic/releases/download/v${BACKUP_RESTIC_VERSION}/restic_${BACKUP_RESTIC_VERSION}_linux_${arch}.bz2" \
     && [[ "$(sha256sum "$tmp/r.bz2" | awk '{print $1}')" == "$sum" ]] \
     && bunzip2 -f "$tmp/r.bz2" && install -m 0755 "$tmp/r" "$bin"; then
    rm -rf "$tmp"; return 0
  fi
  rm -rf "$tmp"; return 1
}

# Loads r2.env into the RESTIC_/AWS_ environment for one restic call. The
# password reaches restic through RESTIC_PASSWORD_FILE, never argv or env.
_bk_env_load() {   # [repo override]
  local f; f="$(_bk_dir)/r2.env"
  [[ -r "$f" ]] || return 1
  local R2_ENDPOINT="" R2_BUCKET="" R2_PREFIX="" BACKUP_REPO="" R2_ACCESS_KEY_ID="" R2_SECRET_ACCESS_KEY="" R2_SESSION_TOKEN=""
  # shellcheck disable=SC1090
  source "$f"
  [[ -n "$R2_ENDPOINT" && -n "$R2_BUCKET" && -n "$R2_PREFIX" && -n "$BACKUP_REPO" && -n "$R2_ACCESS_KEY_ID" && -n "$R2_SESSION_TOKEN" ]] || return 1
  export RESTIC_REPOSITORY="s3:${R2_ENDPOINT%/}/${R2_BUCKET}/${R2_PREFIX}${1:-$BACKUP_REPO}"
  export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" AWS_SESSION_TOKEN="$R2_SESSION_TOKEN"
  export AWS_DEFAULT_REGION=auto
  BK_ENDPOINT="$R2_ENDPOINT" BK_BUCKET="$R2_BUCKET" BK_PREFIX="$R2_PREFIX" BK_REPO="$BACKUP_REPO"
}
_bk_r() {   # restic with the box key; <password file> <args...>
  local pw="$1"; shift
  RESTIC_PASSWORD_FILE="$pw" RESTIC_CACHE_DIR="$(_bk_state)/cache" "$(_bk_restic)" -o s3.region=auto "$@"
}
# 0 the key opens the repo · 10 no repo there yet · 12 wrong key · else unreachable
_bk_repo_probe() {   # <password file>
  local rc=0; _bk_r "$1" cat config >/dev/null 2>&1 || rc=$?
  return "$rc"
}
# Re-key a repository: the new password opens it, every other key is removed.
_bk_rekey() {   # <password file that opens it now> <new password file>
  _bk_r "$1" key add --new-password-file "$2" >/dev/null 2>&1 || return 1
  local ids id; ids=$(_bk_r "$2" key list --json 2>/dev/null | jq -r '.[] | select(.current | not) | .id') || return 1
  for id in $ids; do _bk_r "$2" key remove "$id" >/dev/null 2>&1 || return 1; done
  _bk_repo_probe "$2" && ! _bk_repo_probe "$1"
}

# ---- the API ------------------------------------------------------------------

_bk_box_token() {
  local f t=""; f=$(_bk_connectord_env)
  [[ -r "$f" ]] || return 1
  t=$(sed -n 's/^CONNECTORD_TOKEN=//p' "$f" | head -n 1); t="${t%$'\r'}"; t="${t//\"/}"; t="${t//\'/}"
  [[ -n "$t" ]] && printf '%s' "$t"
}
_bk_api() {   # <method> <path> [json body]  — body on stdout, sets BK_HTTP
  local tok out; BK_HTTP=""
  tok=$(_bk_box_token) || { BK_HTTP=000; return 1; }
  out=$(mktemp) || return 1
  BK_HTTP=$(printf 'authorization: Bearer %s\n' "$tok" | curl -sS -o "$out" -w '%{http_code}' --max-time 60 \
    -X "$1" -H @- -H 'content-type: application/json' ${3:+--data "$3"} "$(five_api_base)/server/backup$2" 2>/dev/null) || BK_HTTP=${BK_HTTP:-000}
  cat "$out"; rm -f "$out"
  [[ "$BK_HTTP" == 2* ]]
}
_bk_enroll() {
  local j; j=$(_bk_api POST /enroll '{}') || { echo "$j" | jq -r '.code // empty' 2>/dev/null; return 1; }
  local ep b px ak sk st sid
  ep=$(jq -r '.endpoint // empty' <<<"$j"); b=$(jq -r '.bucket // empty' <<<"$j"); px=$(jq -r '.prefix // empty' <<<"$j")
  ak=$(jq -r '.accessKeyId // empty' <<<"$j"); sk=$(jq -r '.secretAccessKey // empty' <<<"$j")
  st=$(jq -r '.sessionToken // empty' <<<"$j"); sid=$(jq -r '.serverId // empty' <<<"$j")
  # Every value lands in a file `source`d as root: only shell-inert characters.
  [[ "$ep" =~ ^https://[a-z0-9.-]+$ && "$b" =~ ^[a-z0-9-]{3,63}$ && "$px" =~ ^o-[0-9a-f]{24}/$ \
     && "$ak" =~ ^[A-Za-z0-9]+$ && "$sk" =~ ^[A-Za-z0-9]+$ && "$st" =~ ^[A-Za-z0-9+/=._-]+$ && "$sid" =~ ^[0-9]+$ ]] || return 1
  _bk_write0600 "$(_bk_dir)/r2.env" "$(printf 'R2_ENDPOINT=%s\nR2_BUCKET=%s\nR2_PREFIX=%s\nBACKUP_REPO=box-%s\nR2_ACCESS_KEY_ID=%s\nR2_SECRET_ACCESS_KEY=%s\nR2_SESSION_TOKEN=%s\n' "$ep" "$b" "$px" "$sid" "$ak" "$sk" "$st")"
}
_bk_report() {   # <ok true|false> <error> <bytes> <snapshot>
  local body; body=$(jq -cn --argjson ok "$1" --arg e "${2:0:500}" --arg b "${3:-0}" --arg s "${4:-}" --arg r "${BK_REPO:-}" \
    '{ok:$ok, repo:$r} + (if $e=="" then {} else {error:$e} end) + (if ($b|test("^[0-9]+$")) then {bytes:($b|tonumber)} else {} end) + (if $s=="" then {} else {snapshot:$s} end)')
  _bk_api POST /report "$body" >/dev/null 2>&1 || true
}

# ---- status -------------------------------------------------------------------

_bk_status_write() {   # <ok> <error> <bytes> <snapshot>
  local s; s=$(_bk_state); mkdir -p "$s"
  local prev_ok; prev_ok=$(jq -r '.lastOkAt // empty' "$s/status.json" 2>/dev/null)
  local now; now=$(date -u +%FT%TZ)
  jq -n --argjson ok "$1" --arg e "$2" --arg b "$3" --arg sn "$4" --arg now "$now" --arg prev "$prev_ok" \
    '{lastRunAt:$now, ok:$ok, lastOkAt:(if $ok then $now elif $prev=="" then null else $prev end),
      error:(if $e=="" then null else $e end), bytesAdded:($b|tonumber? // null), snapshot:(if $sn=="" then null else $sn end)}' \
    >"$s/status.json.tmp" && mv -f "$s/status.json.tmp" "$s/status.json"
}

cmd_backup_status() {
  local a; for a in "$@"; do case "$a" in --json) JSON_MODE=1 ;; *) fail "$E_USAGE" "unknown flag: $a" ;; esac; done
  local s st sched=false code=false keyed=false
  s=$(_bk_state); st=$(cat "$s/status.json" 2>/dev/null || echo '{}')
  [[ -f "$(_bk_cron)" ]] && sched=true
  [[ -f "$s/code-delivered" ]] && code=true
  [[ -f "$(_bk_dir)/key" ]] && keyed=true
  local state; state=$(cat "$s/state" 2>/dev/null || echo off)
  if (( JSON_MODE )); then
    jq -cn --argjson st "$st" --arg state "$state" --argjson sched "$sched" --argjson code "$code" --argjson keyed "$keyed" \
      '{ok:true, state:$state, scheduled:$sched, keyOnBox:$keyed, codeDelivered:$code} + $st'
    return 0
  fi
  echo "backup: $state$([[ $sched == true ]] && echo ', nightly')"
  if [[ "$st" != "{}" ]]; then
    jq -r '"last run: \(.lastRunAt) \(if .ok then "ok" else "FAILED: \(.error)" end)", "last good backup: \(.lastOkAt // "never")"' <<<"$st"
  fi
  [[ "$state" == restore-available ]] && echo "an earlier backup of this owner's server exists: restore it with 5dive backup restore --code=<recovery code> --from=<box-N> (5dive backup sources lists them)"
  return 0
}

cmd_backup_code() {
  require_root
  local k; k="$(_bk_dir)/key"
  [[ -r "$k" ]] || fail "$E_NOT_FOUND" "no backup key on this box (5dive backup enable makes one)"
  _bk_code_pretty "$(cat "$k")"; echo
}

# ---- owner delivery -------------------------------------------------------------

# The owner's Telegram DM, through a bot on THIS box: Telegram carries it, 5dive's
# API and DB never do. DMs only (the paired humans in access.json allowFrom), never
# a group or team topic, where a partner's staff could read it. Same agent walk as
# the disk alarm (_disk_alarm_deliver); the first agent whose bot reaches a DM wins.
_bk_send() { _mirror_send "$@"; }   # seam for the harness
_bk_owner_dm() {   # <text> — 0 when at least one DM took it
  local text="$1" name names chat sent=1
  names=$(jq -r '.agents // {} | keys[]' "$REGISTRY" 2>/dev/null)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    _task_agent_channel "$name" || continue
    while IFS= read -r chat; do
      [[ "$chat" =~ ^[0-9]+$ ]] || continue
      if _bk_send "$TASK_CH_TOKEN" "$chat" "" "$text" 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1; then sent=0; fi
    done < <(jq -r '(.allowFrom // [])[]' "$TASK_CH_ACCESS" 2>/dev/null)
    (( sent == 0 )) && return 0
  done <<<"$names"
  return "$sent"
}
_bk_code_message() {
  cat <<EOF
Your server's backup key: $(_bk_code_pretty "$1")

Save it somewhere safe outside this chat (a password manager). Every night your agents are copied, encrypted with this key, to a second provider.

Only you hold this key. 5dive cannot open your backups. If you lose both the server and this key, nobody can restore them, us included.
EOF
}
_bk_deliver_code() {
  local s; s=$(_bk_state)
  [[ -f "$s/code-delivered" ]] && return 0
  if _bk_owner_dm "$(_bk_code_message "$(cat "$(_bk_dir)/key")")"; then
    date -u +%FT%TZ >"$s/code-delivered"; return 0
  fi
  return 1
}

# ---- enable ---------------------------------------------------------------------

_bk_cron_install() {
  local sid m h; sid="${BK_REPO#box-}"; [[ "$sid" =~ ^[0-9]+$ ]] || sid=0
  m=$(( sid % 60 )); h=$(( 2 + (sid / 60) % 3 ))   # 02:00-04:59, spread by box
  local c; c=$(_bk_cron); mkdir -p "$(dirname "$c")"
  printf '# DIVE-7873: nightly encrypted backup to R2 (5dive backup --help)\n%s %s * * * root /usr/local/bin/5dive backup run >/dev/null 2>&1\n' "$m" "$h" >"$c.tmp" \
    && chmod 0644 "$c.tmp" && mv -f "$c.tmp" "$c"
}

_bk_enable_fail() {   # <auto> <code> <msg> — --auto never fails the nightly update
  local s; s=$(_bk_state); mkdir -p "$s"
  printf '%s %s\n' "$(date -u +%FT%TZ)" "enable: $3" >>"$(_bk_log)" 2>/dev/null || true
  if (( $1 )); then echo "backup: $3" >&2; return 0; fi
  fail "$2" "$3"
}

cmd_backup_enable() {
  require_root
  local auto=0 newkey=0 a
  for a in "$@"; do case "$a" in --auto) auto=1 ;; --new-key) newkey=1 ;; --json) JSON_MODE=1 ;; *) fail "$E_USAGE" "unknown flag: $a" ;; esac; done
  (( auto && newkey )) && fail "$E_USAGE" "--new-key is the owner's choice; the unattended --auto never makes it"
  local dir s; dir=$(_bk_dir); s=$(_bk_state); mkdir -p "$s" "$dir"; chmod 0700 "$dir"
  _bk_restic_install || { _bk_enable_fail "$auto" "$E_NOT_INSTALLED" "could not install restic ${BACKUP_RESTIC_VERSION}"; return 0; }
  local why; why=$(_bk_enroll) || { _bk_enable_fail "$auto" "$E_GENERIC" "the 5dive API did not give this box backup storage (${why:-http ${BK_HTTP:-?}})"; return 0; }
  _bk_env_load || { _bk_enable_fail "$auto" "$E_GENERIC" "backup storage settings are unreadable"; return 0; }
  local rc=0
  if [[ -r "$dir/key" ]]; then
    _bk_repo_probe "$dir/key" || rc=$?
    case "$rc" in
      0) ;;
      10) _bk_r "$dir/key" init >/dev/null 2>&1 || { _bk_enable_fail "$auto" "$E_GENERIC" "could not create the backup repository"; return 0; } ;;
      12) _bk_enable_fail "$auto" "$E_AUTH_REQUIRED" "this box's key does not open its backup ($BK_REPO)"; return 0 ;;
      *) _bk_enable_fail "$auto" "$E_GENERIC" "backup storage unreachable (restic rc $rc)"; return 0 ;;
    esac
  else
    # No key here. A backup already under this OWNER's prefix (this box's place,
    # or an earlier box's: a fresh box gets a new server id) means the owner
    # has a key already. Never make a second one over it, and never DM a second
    # code an owner in a disaster could save over the only one that opens it.
    local probe; probe=$(mktemp); printf 'x' >"$probe"
    _bk_repo_probe "$probe" || rc=$?; rm -f "$probe"
    if [[ $rc -eq 12 || $rc -eq 0 ]]; then
      echo restore-available >"$s/state"
      echo "backup: an earlier backup of this box exists. Restore it: 5dive backup restore --code=<recovery code>"
      return 0
    fi
    [[ $rc -eq 10 ]] || { _bk_enable_fail "$auto" "$E_GENERIC" "backup storage unreachable (restic rc $rc)"; return 0; }
    local repos; repos=$(_bk_list_repos) || { _bk_enable_fail "$auto" "$E_GENERIC" "could not list this owner's earlier backups, so no key was made"; return 0; }
    if [[ -n "$repos" ]] && (( ! newkey )); then
      echo restore-available >"$s/state"
      echo "backup: this owner already has a backup ($(paste -sd, <<<"$repos")). Restore it: 5dive backup restore --code=<recovery code> --from=$(tail -n 1 <<<"$repos")"
      echo "backup: or, if the code is lost, start over with a new key: 5dive backup enable --new-key"
      return 0
    fi
    local code; code=$(_bk_code_new) || { _bk_enable_fail "$auto" "$E_GENERIC" "could not make a key"; return 0; }
    _bk_write0600 "$dir/key" "$code" || { _bk_enable_fail "$auto" "$E_GENERIC" "could not save the key"; return 0; }
    _bk_r "$dir/key" init >/dev/null 2>&1 || { _bk_enable_fail "$auto" "$E_GENERIC" "could not create the backup repository"; return 0; }
  fi
  _bk_cron_install
  echo on >"$s/state"
  if ! _bk_deliver_code; then
    echo "backup: the recovery code could not be sent to the owner's Telegram yet; it will be retried every night (5dive backup code shows it)" >&2
  fi
  if (( JSON_MODE )); then jq -cn --arg r "$BK_REPO" '{ok:true, state:"on", repo:$r}'; else echo "backup: on, nightly ($BK_REPO)"; fi
}

# ---- run ------------------------------------------------------------------------

_bk_users_manifest() {   # agent and lead users, so a restore can recreate them by uid
  local out="$1"
  getent passwd | awk -F: '$3>=1000 && $3<60000 && ($1=="claude" || $1 ~ /^agent-/)' | while IFS=: read -r n _ uid gid _ home shell; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$uid" "$gid" "$(getent group "$gid" | cut -d: -f1)" "$home" "$shell" "$(id -nG "$n" 2>/dev/null | tr ' ' ',')"
  done >"$out"
}

cmd_backup_run() {
  require_root
  local a; for a in "$@"; do case "$a" in --json) JSON_MODE=1 ;; *) fail "$E_USAGE" "unknown flag: $a" ;; esac; done
  local s dir; s=$(_bk_state); dir=$(_bk_dir); mkdir -p "$s"
  # Not a 5dive-managed box (no box identity): nothing to back up to.
  [[ -r "$(_bk_connectord_env)" ]] || { echo "backup: not a 5dive-managed box" >&2; return 0; }
  # The rollout: the nightly job enables itself on a box that has never been
  # set up, so a CLI update is all a box needs. A box that refuses (storage not
  # ready, an earlier backup waiting for its code) stays off and says why.
  if [[ ! -r "$dir/key" && "$(cat "$s/state" 2>/dev/null)" != restore-available ]]; then
    ( JSON_MODE=0 cmd_backup_enable --auto ) >/dev/null 2>&1 || true
  fi
  if [[ "$(cat "$s/state" 2>/dev/null)" == restore-available ]]; then
    _bk_env_load >/dev/null 2>&1 || true
    _bk_report false "waiting for the owner's recovery code to restore an earlier backup (5dive backup restore), or 5dive backup enable --new-key" "" ""
    return 0
  fi
  exec 9>"$s/run.lock"; flock -n 9 || fail "$E_CONFLICT" "a backup is already running"
  local log; log=$(_bk_log); mkdir -p "$(dirname "$log")" 2>/dev/null || true
  local err="" bytes="" snap="" rc=0 out errf
  if [[ ! -r "$dir/key" ]]; then
    err="no backup key on this box"
  elif ! _bk_enroll >/dev/null; then
    err="the 5dive API did not give this box backup storage (http ${BK_HTTP:-?})"
  elif ! _bk_env_load; then
    err="backup storage settings missing"
  else
    _bk_deliver_code >/dev/null 2>&1 || true   # retried nightly until the owner has it
    _bk_users_manifest "$(_bk_users)"
    local ex=() e p paths=()
    for e in "${BACKUP_EXCLUDES[@]}"; do ex+=(--exclude "$e"); done
    for p in "${BACKUP_PATHS[@]}"; do [[ -e "$p" ]] && paths+=("$p"); done
    errf=$(mktemp)
    out=$(_bk_r "$dir/key" backup --json --exclude-caches "${ex[@]}" "${paths[@]}" 2>"$errf") || rc=$?
    cat "$errf" >>"$log" 2>/dev/null
    # rc 3 = some files could not be read (a socket, a file gone mid-run): the
    # snapshot is still written and usable.
    if [[ $rc -eq 0 || $rc -eq 3 ]]; then
      snap=$(jq -r 'select(.message_type=="summary") | .snapshot_id // empty' <<<"$out" | tail -1)
      bytes=$(jq -r 'select(.message_type=="summary") | .data_added // empty' <<<"$out" | tail -1)
      [[ -n "$snap" ]] || err="backup finished without a snapshot"
      if [[ -z "$err" ]]; then
        local fr=0
        _bk_r "$dir/key" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune >>"$log" 2>&1 || fr=$?
        (( fr )) && printf '%s forget rc=%s (snapshot %s is safe)\n' "$(date -u +%FT%TZ)" "$fr" "$snap" >>"$log"
      fi
    else
      # The error is THIS run's restic stderr, never an older line of the log.
      local last; last=$(grep -v '^[[:space:]]*$' "$errf" 2>/dev/null | tail -n 1 | cut -c1-300)
      err="restic backup failed (rc $rc): ${last:-restic printed no error}"
    fi
    rm -f "$errf"
  fi
  local ok=true; [[ -n "$err" ]] && ok=false
  _bk_status_write "$ok" "$err" "${bytes:-0}" "$snap"
  _bk_report "$ok" "$err" "$bytes" "$snap"
  printf '%s run ok=%s snapshot=%s bytes=%s %s\n' "$(date -u +%FT%TZ)" "$ok" "${snap:--}" "${bytes:--}" "$err" >>"$log" 2>/dev/null || true
  [[ "$ok" == true ]] || fail "$E_GENERIC" "backup failed: $err"
  if (( JSON_MODE )); then jq -cn --arg s "$snap" --arg b "$bytes" '{ok:true, snapshot:$s, bytesAdded:($b|tonumber? // null)}'
  else echo "backup: ok, snapshot $snap"; fi
}

# ---- sources ---------------------------------------------------------------------

# The repositories under this owner's prefix (box-<id>/), via S3 ListObjectsV2.
# The credential and session token reach curl from a 0600 config file, not argv.
# Non-zero when the listing itself failed: an empty answer is "no backups", a
# failed one is "unknown", and a caller deciding whether to make a key must
# never read the second as the first.
_bk_list_repos() {
  local cfg out rc=0; cfg=$(mktemp) || return 1; chmod 0600 "$cfg"
  printf 'user = "%s:%s"\nheader = "x-amz-security-token: %s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_SESSION_TOKEN" >"$cfg"
  local u="${BK_ENDPOINT%/}/${BK_BUCKET}?list-type=2&delimiter=%2F&prefix=${BK_PREFIX//\//%2F}"
  out=$(curl -sS --fail --max-time 30 --aws-sigv4 "aws:amz:auto:s3" -K "$cfg" "$u" </dev/null 2>/dev/null) || rc=$?
  rm -f "$cfg"
  [[ $rc -eq 0 && "$out" == *"<ListBucketResult"* ]] || return 1
  { grep -oE "<Prefix>${BK_PREFIX}box-[0-9]+/</Prefix>" <<<"$out" || true; } | sed -E 's#.*(box-[0-9]+)/</Prefix>#\1#' | sort -t- -k2,2n
}
cmd_backup_sources() {
  require_root
  _bk_enroll >/dev/null || fail "$E_GENERIC" "the 5dive API did not give this box backup storage"
  _bk_env_load || fail "$E_GENERIC" "backup storage settings are unreadable"
  local r; r=$(_bk_list_repos)
  [[ -n "$r" ]] || { echo "no backups yet"; return 0; }
  while IFS= read -r x; do echo "$x$([[ "$x" == "$BK_REPO" ]] && echo '  (this box)')"; done <<<"$r"
}

# ---- restore --------------------------------------------------------------------

_bk_restore_users() {   # <users.tsv>
  local n uid gid gname home shell groups g
  while IFS=$'\t' read -r n uid gid gname home shell groups; do
    [[ "$n" =~ ^(claude|agent-[a-z0-9-]+)$ && "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || continue
    if ! getent group "$gname" >/dev/null; then
      groupadd -g "$gid" "$gname" 2>/dev/null || groupadd "$gname" 2>/dev/null || true
    fi
    if ! getent passwd "$n" >/dev/null; then
      if getent passwd "$uid" >/dev/null; then
        warn "uid $uid is taken on this box; $n gets a new uid and its files are re-owned"
        useradd -M -d "$home" -s "${shell:-/bin/bash}" -g "$gname" "$n" 2>/dev/null || { warn "could not recreate user $n"; continue; }
      else
        useradd -M -u "$uid" -d "$home" -s "${shell:-/bin/bash}" -g "$gname" "$n" 2>/dev/null || { warn "could not recreate user $n"; continue; }
      fi
    fi
    for g in ${groups//,/ }; do
      [[ "$g" == "$gname" ]] && continue
      getent group "$g" >/dev/null || groupadd "$g" 2>/dev/null || true
      usermod -aG "$g" "$n" 2>/dev/null || true
    done
  done <"$1"
}

# What comes back, from a staged restore at <stage>, onto <root>/.
_bk_restore_apply() {   # <stage> <root>
  local stage="$1" root="${2:-}" p
  command -v rsync >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync; } >/dev/null 2>&1 || return 1
  local set=(/home /var/lib/5dive /etc/5dive /etc/claude-code /etc/sudoers.d /var/spool/cron/crontabs)
  for p in "${set[@]}"; do
    [[ -e "$stage$p" ]] || continue
    mkdir -p "$root$p"
    # rsync's excludes are relative to the transfer root, so anchor each skip
    local rel=() q
    for q in "${BACKUP_RESTORE_SKIP[@]}"; do [[ "$q" == "$p"/* ]] && rel+=(--exclude "/${q#"$p"/}"); done
    rsync -aHAX --numeric-ids "${rel[@]}" "$stage$p/" "$root$p/" || return 1
  done
  # The agents' unit drop-ins; the unit template itself is the fresh box's own.
  local d
  for d in "$stage"/etc/systemd/system/5dive-agent@*.service.d; do
    [[ -d "$d" ]] || continue
    mkdir -p "$root/etc/systemd/system/${d##*/}"
    rsync -a "$d/" "$root/etc/systemd/system/${d##*/}/" || return 1
  done
}

cmd_backup_restore() {
  require_root
  local code="" from="" snap="latest" yes=0 a
  for a in "$@"; do
    case "$a" in
      --code=*) code="${a#--code=}" ;;
      --from=*) from="${a#--from=}" ;;
      --snapshot=*) snap="${a#--snapshot=}" ;;
      --yes|-y) yes=1 ;;
      --json) JSON_MODE=1 ;;
      *) fail "$E_USAGE" "unknown flag: $a (see: 5dive backup --help)" ;;
    esac
  done
  [[ -n "$code" ]] || code="${FIVE_BACKUP_CODE:-}"
  [[ -n "$code" ]] || fail "$E_USAGE" "restore needs the recovery code: 5dive backup restore --code=XXXX-XXXX-..."
  local norm; norm=$(_bk_code_normalize "$code") || fail "$E_VALIDATION" "that is not a recovery code (28 letters and digits, dashes optional)"
  [[ -z "$from" || "$from" =~ ^box-[0-9]+$ ]] || fail "$E_VALIDATION" "--from takes a box name like box-123 (see: 5dive backup sources)"
  [[ "$snap" == latest || "$snap" =~ ^[0-9a-f]{8,64}$ ]] || fail "$E_VALIDATION" "--snapshot takes a snapshot id or latest"
  local dir s; dir=$(_bk_dir); s=$(_bk_state); mkdir -p "$s" "$dir"; chmod 0700 "$dir"
  _bk_restic_install || fail "$E_NOT_INSTALLED" "could not install restic ${BACKUP_RESTIC_VERSION}"
  _bk_enroll >/dev/null || fail "$E_GENERIC" "the 5dive API did not give this box backup storage"
  _bk_env_load "$from" || fail "$E_GENERIC" "backup storage settings are unreadable"
  local src="${from:-$BK_REPO}"
  local pw; pw=$(mktemp); chmod 0600 "$pw"; printf '%s' "$norm" >"$pw"
  local rc=0; _bk_repo_probe "$pw" || rc=$?
  case "$rc" in
    0) ;;
    10) rm -f "$pw"; fail "$E_NOT_FOUND" "no backup named $src for this owner (see: 5dive backup sources)" ;;
    12) rm -f "$pw"; fail "$E_AUTH_REQUIRED" "that recovery code does not open the backup $src" ;;
    *) rm -f "$pw"; fail "$E_GENERIC" "backup storage unreachable (restic rc $rc)" ;;
  esac
  if (( ! yes )); then
    rm -f "$pw"
    echo "The key opens $src. Re-run with --yes to restore it onto this box: its agents, memory, chats and settings replace this box's."
    return 0
  fi
  local stage; stage="${FIVE_BACKUP_STAGE:-/var/lib/5dive-restore}/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$stage"; chmod 0700 "$stage"
  _bk_r "$pw" restore "$snap" --target "$stage" >>"$(_bk_log)" 2>&1 || { rm -f "$pw"; fail "$E_GENERIC" "restoring $src failed (see $(_bk_log))"; }
  local man="$stage/var/lib/5dive/backup-users.tsv"
  [[ -r "$man" ]] && _bk_restore_users "$man"
  local names=() n
  mapfile -t names < <(jq -r '.agents // {} | keys[]' "$stage/var/lib/5dive/agents.json" 2>/dev/null)
  for n in "${names[@]}"; do systemctl stop "5dive-agent@${n}.service" >/dev/null 2>&1 || true; done
  _bk_restore_apply "$stage" "$(_bk_root)" || { rm -f "$pw"; fail "$E_GENERIC" "copying the restored files into place failed; the staged copy is at $stage"; }
  # The restored key becomes this box's key: later backups use the owner's code.
  # Back up from here on: into THIS box's own repository, opened by the owner's
  # code. If that place already holds a repository under another key (one this
  # box made before the restore), re-key it with the box's old key; if nothing
  # here opens it, say backups are NOT running instead of claiming they are.
  _bk_env_load || true
  local own_err="" prc=0
  _bk_repo_probe "$pw" || prc=$?
  case "$prc" in
    0) ;;
    10) _bk_r "$pw" init >/dev/null 2>&1 || own_err="could not create this box's backup repository $BK_REPO" ;;
    12) if ! { [[ -r "$dir/key" ]] && _bk_repo_probe "$dir/key" && _bk_rekey "$dir/key" "$pw"; }; then
          own_err="$BK_REPO already holds a backup under a different key, and nothing on this box opens it"
        fi ;;
    *) own_err="backup storage unreachable (restic rc $prc)" ;;
  esac
  _bk_write0600 "$dir/key" "$norm"; rm -f "$pw"
  date -u +%FT%TZ >"$s/code-delivered"   # the owner just typed it
  systemctl daemon-reload >/dev/null 2>&1 || true
  for n in "${names[@]}"; do
    systemctl enable "5dive-agent@${n}.service" >/dev/null 2>&1 || true
    systemctl restart "5dive-agent@${n}.service" >/dev/null 2>&1 || warn "agent $n did not start; 5dive doctor shows why"
  done
  _bk_cron_install; echo on >"$s/state"
  rm -rf "$stage"
  if [[ -n "$own_err" ]]; then
    _bk_status_write false "$own_err" 0 ""
    _bk_report false "$own_err" "" ""
    printf '%s restore from %s ok; nightly backups NOT running: %s\n' "$(date -u +%FT%TZ)" "$src" "$own_err" >>"$(_bk_log)" 2>/dev/null || true
  fi
  if (( JSON_MODE )); then jq -cn --arg f "$src" --argjson n "${#names[@]}" --arg r "$BK_REPO" --arg e "$own_err" \
      '{ok:true, restoredFrom:$f, agents:$n, backupRepo:$r, backups:($e==""), backupError:(if $e=="" then null else $e end)}'
  elif [[ -n "$own_err" ]]; then
    echo "restored $src: ${#names[@]} agent(s) back"
    echo "WARNING: nightly backups are NOT running: $own_err" >&2
  else echo "restored $src: ${#names[@]} agent(s) back; nightly backups continue as $BK_REPO"; fi
}
