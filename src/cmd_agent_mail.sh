# -------- agent mail (DIVE-5161) --------
#
# Connect ONE mailbox to an agent with an app password, so the agent reads (and,
# with the client's explicit yes, sends) mail through the himalaya CLI.
#
# The caller is a partner client with no terminal and no box access: 5dive-api
# reaches the box over /shell/exec, which runs `5dive <argv>` as root and can
# hand it a stdin string. So this verb is the whole box side of the flow:
#
#   agent mail set <agent> --email= --imap= --smtp= [--caldav=] --password=- --json
#   agent mail remove <agent> --json
#   agent mail list --json | agent mail show <agent> --json
#
# THE PASSWORD. It arrives on stdin and nowhere else (`--password=-` is the only
# accepted spelling), because argv is world-readable in /proc and lands in the
# audit log. After that it is only ever handed to a child on STDIN (printf is a
# builtin, so `printf … | dd` puts it in no argv), stripped from any error text
# before that text is printed, and written to exactly one 0600 file the agent
# owns. himalaya reads it back through `password.command = "cat <file>"`.
#
# LOGIN IS VERIFIED BEFORE ANYTHING PERMANENT IS WRITTEN. A throwaway config and
# password file go in a 0700 temp dir the AGENT owns, himalaya runs AS the agent
# against them, and only a clean `mailbox list` lets the real files land. The API
# keys off two exact message prefixes: `login_failed:` (E_AUTH_REQUIRED) and
# `mail_unreachable:` (E_VALIDATION).
#
# EVERY TOUCH OF AN AGENT PATH RUNS AS THE AGENT (_agent_mail_as), the rule
# cmd_agent_avatar.sh learned over three rejection rounds: root must not resolve a
# path inside a home the agent controls, because every check is a snapshot the
# agent can race. As the agent, a planted link reaches only what the agent could
# already write.

_agent_mail_is_root() { (( EUID == 0 )); }

# Seams: the tests point these at a temp tree / a stub binary. Production values
# are /home and /usr/local/bin/himalaya.
_agent_mail_home() { printf '%s/agent-%s\n' "${AGENT_HOME_ROOT:-/home}" "$1"; }
_agent_mail_bin() { printf '%s\n' "${AGENT_MAIL_HIMALAYA_BIN:-/usr/local/bin/himalaya}"; }
_agent_mail_stdin_is_tty() { [[ -t 0 ]]; }

_agent_mail_marker() { printf '%s\n' '# managed by 5dive agent mail (DIVE-5161); `5dive agent mail remove` deletes it'; }
_agent_mail_block_begin() { printf '%s' '<!-- 5dive:mail -->'; }
_agent_mail_block_end() { printf '%s' '<!-- /5dive:mail -->'; }

# The pinned himalaya release for this box's arch: "<url> <sha256>".
_agent_mail_himalaya_asset() {
  local base="https://github.com/pimalaya/himalaya/releases/download/v2.1.0"
  case "$(uname -m)" in
    x86_64|amd64)
      printf '%s %s\n' "$base/himalaya.x86_64-linux.tgz" 683a2ab8e1534f01e6bda3a69e204d564c31fbfbe20511fc7bc60b67f2e85884 ;;
    aarch64|arm64)
      printf '%s %s\n' "$base/himalaya.aarch64-linux.tgz" c41adab4bc220ba816cdbf865a5df8dc3b358b39ec58b4be0ed2f64e46b1d182 ;;
    *) return 1 ;;
  esac
}

# Run <cmd> as agent-<agent> when we are root, else as the caller (the tests,
# and an agent reading its own mailbox). `runuser`, not `sudo -u`: runas is
# narrowed on this fleet (DIVE-3263) and runuser consults no policy. No runuser
# means no drop, and root does not act in its place.
_agent_mail_as() { # <agent> <cmd...>
  local agent="$1"; shift
  if _agent_mail_is_root; then
    command -v runuser >/dev/null 2>&1 || { printf 'runuser not found; refusing to touch agent-%s as root\n' "$agent" >&2; return 1; }
    # From /: the caller's cwd (often /root) is not the agent's to enter.
    (cd / && runuser -u "agent-${agent}" -- "$@")
  else
    "$@"
  fi
}

# Write stdin to <dst> as the agent: temp name created O_EXCL, 0600, renamed over
# the destination (-T: never INTO a directory planted at that name).
_agent_mail_put() { # <agent> <dst>   (content on stdin)
  local agent="$1" dst="$2" tmp="$2.5dive-new.$$"
  _agent_mail_as "$agent" rm -f -- "$tmp" 2>/dev/null || true
  if _agent_mail_as "$agent" dd of="$tmp" conv=excl status=none 2>/dev/null \
     && _agent_mail_as "$agent" chmod 600 -- "$tmp" 2>/dev/null \
     && _agent_mail_as "$agent" mv -fT -- "$tmp" "$dst" 2>/dev/null; then
    return 0
  fi
  _agent_mail_as "$agent" rm -f -- "$tmp" 2>/dev/null || true
  return 1
}

# Is the agent's himalaya config absent (0) or ours (0), or someone else's (1)?
_agent_mail_config_is_ours_or_absent() { # <agent>
  local agent="$1" cfg first
  cfg="$(_agent_mail_home "$agent")/.config/himalaya/config.toml"
  _agent_mail_as "$agent" test -e "$cfg" 2>/dev/null || _agent_mail_as "$agent" test -L "$cfg" 2>/dev/null || return 0
  first=$(_agent_mail_as "$agent" head -n 1 -- "$cfg" 2>/dev/null) || return 1
  [[ "$first" == "$(_agent_mail_marker)" ]]
}

# host[:port] -> "host port", lowercased, default port applied. Returns 1 when
# the value is not a bare authority.
_agent_mail_hostport() { # <value> <default-port>
  local v="${1,,}" def="$2" host port
  [[ "$v" =~ ^[a-z0-9.-]+(:[0-9]{1,5})?$ ]] || return 1
  host="${v%%:*}"; port="$def"
  [[ "$v" == *:* ]] && port="${v##*:}"
  [[ "$host" =~ ^[a-z0-9] && "$host" =~ [a-z0-9]$ ]] || return 1
  port=$((10#$port))
  (( port >= 1 && port <= 65535 )) || return 1
  printf '%s %s\n' "$host" "$port"
}

# TOML for one account. No secret in it: the password is read back from <pwfile>.
_agent_mail_toml() { # <email> <imap-host> <imap-port> <smtp-host> <smtp-port> <pwfile>
  local email="$1" ih="$2" ip="$3" sh="$4" sp="$5" pwf="$6"
  _agent_mail_marker
  printf '[accounts.mail]\ndefault = true\nemail = "%s"\n' "$email"
  if (( ip == 143 )); then
    printf 'imap.server = "imap://%s:%s"\nimap.starttls = true\n' "$ih" "$ip"
  else
    printf 'imap.server = "imaps://%s:%s"\n' "$ih" "$ip"
  fi
  printf 'imap.sasl.plain.username = "%s"\nimap.sasl.plain.password.command = "cat %s"\n' "$email" "$pwf"
  case "$sp" in
    465) printf 'smtp.server = "smtps://%s:%s"\n' "$sh" "$sp" ;;
    587|25|2525) printf 'smtp.server = "smtp://%s:%s"\nsmtp.starttls = true\n' "$sh" "$sp" ;;
    *) printf 'smtp.server = "smtps://%s:%s"\n' "$sh" "$sp" ;;
  esac
  printf 'smtp.sasl.plain.username = "%s"\nsmtp.sasl.plain.password.command = "cat %s"\n' "$email" "$pwf"
}

# netrc line for curl. A password with whitespace or quotes is written quoted
# (curl >= 7.84 parses quoted netrc tokens; app passwords are often shown with
# spaces).
_agent_mail_netrc() { # <host> <login> <password>
  local pw="$3"
  if [[ "$pw" =~ [[:space:]\"\\] ]]; then
    pw="${pw//\\/\\\\}"; pw="${pw//\"/\\\"}"; pw="\"$pw\""
  fi
  printf 'machine %s\nlogin %s\npassword %s\n' "$1" "$2" "$pw"
}

# Ensure /usr/local/bin/himalaya is the pinned v2.1.0. Echoes nothing on success;
# on failure echoes the reason and returns 1.
_agent_mail_ensure_himalaya() {
  local bin ver asset url want got work own=()
  bin=$(_agent_mail_bin)
  ver=$("$bin" --version 2>/dev/null | head -n 1) || ver=""
  [[ "$ver" == "himalaya v2.1.0"* ]] && return 0
  asset=$(_agent_mail_himalaya_asset) || { printf 'no pinned build for arch %s\n' "$(uname -m)"; return 1; }
  url="${asset%% *}"; want="${asset##* }"
  work=$(mktemp -d) || { printf 'mktemp failed\n'; return 1; }
  if ! curl -fsSL --max-time 180 --proto '=https' -o "$work/h.tgz" -- "$url" 2>/dev/null; then
    rm -rf -- "$work"; printf 'download failed: %s\n' "$url"; return 1
  fi
  got=$(sha256sum "$work/h.tgz" 2>/dev/null | awk '{print $1}')
  if [[ -z "$got" || "$got" != "$want" ]]; then
    rm -rf -- "$work"; printf 'sha256 mismatch for %s (got %s, want %s)\n' "${url##*/}" "${got:-none}" "$want"; return 1
  fi
  mkdir -p -- "$work/x"
  if ! tar -xzf "$work/h.tgz" -C "$work/x" himalaya 2>/dev/null || [[ ! -f "$work/x/himalaya" ]]; then
    rm -rf -- "$work"; printf 'archive does not hold a himalaya binary\n'; return 1
  fi
  (( EUID == 0 )) && own=(-o root -g root)
  mkdir -p -- "$(dirname -- "$bin")" 2>/dev/null || true
  if ! install -m 0755 "${own[@]+"${own[@]}"}" -- "$work/x/himalaya" "$bin.5dive-new.$$" 2>/dev/null \
     || ! mv -f -- "$bin.5dive-new.$$" "$bin" 2>/dev/null; then
    rm -f -- "$bin.5dive-new.$$"; rm -rf -- "$work"; printf 'could not install %s\n' "$bin"; return 1
  fi
  rm -rf -- "$work"
  ver=$("$bin" --version 2>/dev/null | head -n 1) || ver=""
  [[ "$ver" == "himalaya v2.1.0"* ]] || { printf 'installed binary reports "%s", not himalaya v2.1.0\n' "${ver:-nothing}"; return 1; }
}

# Turn himalaya's failure output into one line: `error: source; source`, the
# password removed, at most 200 chars.
_agent_mail_error_text() { # <stdout> <stderr> <password>
  local out="$1" err="$2" pw="$3" txt
  txt=$(jq -r 'select(type == "object" and has("error"))
               | [.error] + ((.sources // []) | map(tostring)) | map(select(. != "")) | join(": ")' \
          <<<"$out" 2>/dev/null) || txt=""
  [[ -n "$txt" ]] || txt="$out${out:+ }$err"
  [[ -n "$pw" ]] && txt="${txt//"$pw"/***}"
  txt="${txt//$'\r'/ }"; txt="${txt//$'\n'/ }"
  [[ -n "${txt// /}" ]] || txt="himalaya exited without a message"
  printf '%s\n' "${txt:0:200}"
}

# 0 = the server refused the credentials. The IMAP `NO` response is matched
# case-SENSITIVELY: a case-blind \bNO\b also matches "No route to host", which is
# a network failure, not a login one.
_agent_mail_rmtemp() { # <agent> <dir>
  _agent_mail_as "$1" rm -rf -- "$2" 2>/dev/null || true
}

_agent_mail_is_auth_error() { # <text>
  grep -qiE 'AUTHENTICAT|LOGIN|credential|password|WEBALERT|ALERT' <<<"$1" && return 0
  grep -qE '\bNO\b' <<<"$1"
}

# Install or replace the marker-delimited block in the agent's instructions
# file, as the agent. Empty <block> removes it. Returns 1 (caller warns) when the
# file cannot be resolved or written.
_agent_mail_persona() { # <agent> <block-or-empty>
  local agent="$1" block="$2" type md
  type=$(agent_type "$agent" 2>/dev/null) || type=""
  [[ -n "$type" ]] || type=claude
  md=$(persona_target "$agent" "$type" 2>/dev/null) || return 1
  _agent_mail_as "$agent" env MD="$md" BLOCK="$block" \
    BEGIN="$(_agent_mail_block_begin)" END="$(_agent_mail_block_end)" \
    python3 -c '
import os, re, sys
md, block = os.environ["MD"], os.environ["BLOCK"].rstrip("\n")
b, e = os.environ["BEGIN"], os.environ["END"]
cur, mode = "", 0o644
if os.path.lexists(md):
    with open(md) as f:
        cur = f.read()
    mode = os.stat(md).st_mode & 0o777
pat = re.compile(re.escape(b) + r".*?" + re.escape(e) + r"\n?", re.S)
if block:
    if pat.search(cur):
        new = pat.sub(lambda _m: block + "\n", cur, count=1)
    else:
        new = (cur.rstrip("\n") + "\n\n" if cur.strip() else "") + block + "\n"
else:
    new = pat.sub("", cur, count=1)
    new = new.rstrip("\n") + ("\n" if new.strip() else "")
if new == cur:
    sys.exit(0)
if not block and not os.path.lexists(md):
    sys.exit(0)
os.makedirs(os.path.dirname(md), exist_ok=True)
tmp = md + ".5dive-new.%d" % os.getpid()
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(new)
    os.fchmod(f.fileno(), mode)
os.replace(tmp, md)
' 2>/dev/null
}

_agent_mail_block() { # <email> <calendar:true|false> <caldav-url>
  local email="$1" cal="$2" url="$3"
  _agent_mail_block_begin; printf '\n'
  cat <<EOF
## Mailbox

The mailbox **${email}** is connected for you (himalaya CLI, already configured).

- List: \`himalaya envelope list\` (add \`--json\` for JSON)
- Search: \`himalaya envelope search 'not flag seen and date <yyyy-mm-dd>'\`
  Query terms: \`date <yyyy-mm-dd>\`, \`after <yyyy-mm-dd>\`, \`from <pattern>\`,
  \`subject <pattern>\`, \`flag <seen|answered|flagged|draft>\`, joined with \`and\` / \`or\` / \`not\`.
- Read: \`himalaya message read <id>\`
- Replying and sending also go through himalaya.

**NEVER send, reply, forward or delete mail without the client's explicit yes in this
conversation.** Draft first, show the client the full draft, and wait for their yes.
EOF
  if [[ "$cal" == true ]]; then
    cat <<EOF

Calendar (CalDAV): ${url}
Query it with \`curl --netrc-file ~/.config/5dive-mail/netrc -X PROPFIND -H 'Depth: 1' '${url}'\`
(REPORT for events). Creating or changing events needs the same explicit yes.
EOF
  fi
  _agent_mail_block_end; printf '\n'
}

cmd_agent_mail() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    set)    _agent_mail_set "$@" ;;
    remove) _agent_mail_remove "$@" ;;
    list)   _agent_mail_list "$@" ;;
    show)   _agent_mail_show "$@" ;;
    *) fail "$E_USAGE" "usage: 5dive agent mail set|remove|list|show [<agent>] [--email=<addr> --imap=<host[:port]> --smtp=<host[:port]> [--caldav=<https-url>] --password=-]" ;;
  esac
}

# Common agent checks for set/remove/show: a registered agent with a Linux user.
_agent_mail_require_agent() { # <agent>
  local agent="$1"
  valid_name "$agent" || fail "$E_VALIDATION" "invalid agent name: $agent"
  require_agent "$agent"
  id -u "agent-${agent}" >/dev/null 2>&1 || fail "$E_NOT_FOUND" "agent '$agent' has no Linux user agent-${agent}"
}

_agent_mail_set() {
  local usage="usage: 5dive agent mail set <agent> --email=<addr> --imap=<host[:port]> --smtp=<host[:port]> [--caldav=<https-url>] --password=-"
  local agent="" email="" imap="" smtp="" caldav="" pwflag="" a
  for a in "$@"; do
    case "$a" in
      --email=*)    email="${a#--email=}" ;;
      --imap=*)     imap="${a#--imap=}" ;;
      --smtp=*)     smtp="${a#--smtp=}" ;;
      --caldav=*)   caldav="${a#--caldav=}" ;;
      --password=*) pwflag="${a#--password=}" ;;
      --password)   fail "$E_USAGE" "--password takes the password on stdin only: --password=-" ;;
      -*)           fail "$E_USAGE" "unknown flag: $a" ;;
      *) [[ -z "$agent" ]] && agent="$a" || fail "$E_USAGE" "$usage" ;;
    esac
  done
  [[ -n "$agent" && -n "$email" && -n "$imap" && -n "$smtp" && -n "$pwflag" ]] || fail "$E_USAGE" "$usage"
  # Never echo the value: a caller who put the password in argv must not have it
  # printed back into a log as well.
  [[ "$pwflag" == "-" ]] || fail "$E_USAGE" "--password must be '-' (the password is read from stdin, never argv)"
  _agent_mail_stdin_is_tty && fail "$E_USAGE" "--password=- reads the password from stdin; pipe it in (stdin is a terminal)"

  valid_name "$agent" || fail "$E_VALIDATION" "invalid agent name: $agent"
  local email_re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$'
  local caldav_re='^https://([A-Za-z0-9.-]+)(:[0-9]{1,5})?(/[^[:space:]"'"'"'`\\<>]*)?$'
  (( ${#email} <= 254 )) && [[ "$email" =~ $email_re ]] \
    || fail "$E_VALIDATION" "invalid email address: $email"
  local ihp shp ih ip sh sp
  ihp=$(_agent_mail_hostport "$imap" 993) || fail "$E_VALIDATION" "invalid --imap (want host[:port]): $imap"
  shp=$(_agent_mail_hostport "$smtp" 465) || fail "$E_VALIDATION" "invalid --smtp (want host[:port]): $smtp"
  ih="${ihp% *}"; ip="${ihp#* }"; sh="${shp% *}"; sp="${shp#* }"
  local cal_host=""
  if [[ -n "$caldav" ]]; then
    [[ "$caldav" =~ $caldav_re ]] \
      || fail "$E_VALIDATION" "--caldav must be an https:// URL: $caldav"
    cal_host="${BASH_REMATCH[1],,}"
  fi

  # The password: stdin only, one trailing \r?\n stripped, nothing else allowed.
  # read -d '' returns 0 only when it met a NUL, which is refused; -n caps it.
  local pw="" rrc=0
  IFS= read -r -d '' -n 4097 -t 30 pw || rrc=$?
  (( rrc > 128 )) && fail "$E_USAGE" "no password arrived on stdin within 30s"
  (( ${#pw} > 4096 )) && fail "$E_VALIDATION" "password is longer than 4096 characters"
  (( rrc == 0 )) && fail "$E_VALIDATION" "password contains a NUL byte"
  if [[ "$pw" == *$'\r\n' ]]; then pw="${pw%$'\r\n'}"
  elif [[ "$pw" == *$'\n' ]]; then pw="${pw%$'\n'}"; fi
  [[ "$pw" == *[$'\n\r']* ]] && fail "$E_VALIDATION" "password contains a newline or carriage return"
  [[ -n "$pw" ]] || fail "$E_VALIDATION" "empty password on stdin"

  _agent_mail_is_root || fail "$E_PERMISSION" "agent mail set writes into the agent's home: run as root"
  _agent_mail_require_agent "$agent"
  umask 077

  local home cfgdir maildir
  home=$(_agent_mail_home "$agent")
  cfgdir="$home/.config/himalaya"; maildir="$home/.config/5dive-mail"
  _agent_mail_config_is_ours_or_absent "$agent" \
    || fail "$E_CONFLICT" "himalaya_config_exists: $cfgdir/config.toml exists and was not written by 5dive; move it aside first"

  local why
  why=$(_agent_mail_ensure_himalaya) || fail "$E_NOT_INSTALLED" "himalaya_install_failed: ${why:-unknown error}"

  # --- verify, in a 0700 temp dir the agent owns --------------------------
  local vt
  vt=$(_agent_mail_as "$agent" mktemp -d 2>/dev/null) && [[ -n "$vt" ]] \
    || fail "$E_GENERIC" "could not create a temp dir as agent-$agent"
  if ! printf '%s' "$pw" | _agent_mail_put "$agent" "$vt/password" \
     || ! _agent_mail_toml "$email" "$ih" "$ip" "$sh" "$sp" "$vt/password" | _agent_mail_put "$agent" "$vt/config.toml"; then
    _agent_mail_rmtemp "$agent" "$vt"; fail "$E_GENERIC" "could not write the verification config as agent-$agent"
  fi
  local bin out errf err hrc=0
  bin=$(_agent_mail_bin)
  errf=$(mktemp) || { _agent_mail_rmtemp "$agent" "$vt"; fail "$E_GENERIC" "mktemp failed"; }
  out=$(_agent_mail_as "$agent" timeout 40 "$bin" -c "$vt/config.toml" --json mailbox list 2>"$errf") || hrc=$?
  err=$(head -c 4000 -- "$errf" 2>/dev/null); rm -f -- "$errf"
  if (( hrc != 0 )); then
    _agent_mail_rmtemp "$agent" "$vt"
    local txt
    if (( hrc == 124 )); then
      txt="timed out after 40s talking to $ih:$ip"
    else
      txt=$(_agent_mail_error_text "$out" "$err" "$pw")
    fi
    if (( hrc != 124 )) && _agent_mail_is_auth_error "$txt"; then
      fail "$E_AUTH_REQUIRED" "login_failed: $txt"
    fi
    fail "$E_VALIDATION" "mail_unreachable: $txt"
  fi

  # --- optional CalDAV: a 207 to PROPFIND Depth:0 means the calendar is usable --
  local calendar=false code
  if [[ -n "$caldav" ]]; then
    if _agent_mail_netrc "$cal_host" "$email" "$pw" | _agent_mail_put "$agent" "$vt/netrc"; then
      code=$(_agent_mail_as "$agent" curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
               --proto '=https' --netrc-file "$vt/netrc" -X PROPFIND -H 'Depth: 0' -- "$caldav" 2>/dev/null) || true
      [[ "$code" == 207 ]] && calendar=true
    fi
    [[ "$calendar" == true ]] || warn "CalDAV at $caldav did not answer PROPFIND with 207 (got ${code:-nothing}); mail is connected without the calendar"
  fi

  # --- persist: the login worked -------------------------------------------
  local persisted=1
  { _agent_mail_as "$agent" mkdir -p -- "$maildir" "$cfgdir" 2>/dev/null \
      && _agent_mail_as "$agent" chmod 700 -- "$maildir" "$cfgdir" 2>/dev/null \
      && printf '%s' "$pw" | _agent_mail_put "$agent" "$maildir/password"; } || persisted=0
  if (( persisted )); then
    if [[ "$calendar" == true ]]; then
      _agent_mail_netrc "$cal_host" "$email" "$pw" | _agent_mail_put "$agent" "$maildir/netrc" || persisted=0
    else
      _agent_mail_as "$agent" rm -f -- "$maildir/netrc" 2>/dev/null || true
    fi
  fi
  (( persisted )) && { _agent_mail_toml "$email" "$ih" "$ip" "$sh" "$sp" "$maildir/password" \
                        | _agent_mail_put "$agent" "$cfgdir/config.toml" || persisted=0; }
  (( persisted )) && { jq -cn --arg e "$email" --arg i "$ih:$ip" --arg s "$sh:$sp" --arg c "$caldav" \
                         --argjson cal "$calendar" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                         '{email:$e, imap:$i, smtp:$s, caldav:(if $c == "" then null else $c end), calendar:$cal, connectedAt:$t}' \
                       | _agent_mail_put "$agent" "$maildir/mail.json" || persisted=0; }
  _agent_mail_rmtemp "$agent" "$vt"
  (( persisted )) || fail "$E_GENERIC" "login worked but the mailbox files could not be written under $home/.config as agent-$agent"

  _agent_mail_persona "$agent" "$(_agent_mail_block "$email" "$calendar" "$caldav")" \
    || warn "mailbox connected, but the agent's instructions file could not be updated — tell the agent about $email yourself"

  ok "mailbox $email connected for '$agent'$([[ $calendar == true ]] && echo ' (with calendar)')" \
    '{agent:$a, email:$e, calendar:$c}' --arg a "$agent" --arg e "$email" --argjson c "$calendar"
}

_agent_mail_remove() {
  local agent="" a
  for a in "$@"; do
    case "$a" in
      -*) fail "$E_USAGE" "usage: 5dive agent mail remove <agent>" ;;
      *) [[ -z "$agent" ]] && agent="$a" || fail "$E_USAGE" "usage: 5dive agent mail remove <agent>" ;;
    esac
  done
  [[ -n "$agent" ]] || fail "$E_USAGE" "usage: 5dive agent mail remove <agent>"
  _agent_mail_is_root || fail "$E_PERMISSION" "agent mail remove writes into the agent's home: run as root"
  _agent_mail_require_agent "$agent"
  local home removed=false cfg maildir
  home=$(_agent_mail_home "$agent")
  maildir="$home/.config/5dive-mail"; cfg="$home/.config/himalaya/config.toml"
  if _agent_mail_as "$agent" test -e "$maildir" 2>/dev/null || _agent_mail_as "$agent" test -L "$maildir" 2>/dev/null; then
    _agent_mail_as "$agent" rm -rf -- "$maildir" 2>/dev/null || fail "$E_GENERIC" "could not remove $maildir"
    removed=true
  fi
  if _agent_mail_as "$agent" test -e "$cfg" 2>/dev/null && _agent_mail_config_is_ours_or_absent "$agent"; then
    _agent_mail_as "$agent" rm -f -- "$cfg" 2>/dev/null || fail "$E_GENERIC" "could not remove $cfg"
    removed=true
  fi
  _agent_mail_persona "$agent" "" || warn "could not update the agent's instructions file; remove the 5dive:mail block by hand"
  ok "mailbox $([[ $removed == true ]] && echo removed || echo 'was not connected') for '$agent'" \
    '{agent:$a, removed:$r}' --arg a "$agent" --argjson r "$removed"
}

# {agent,email,calendar} for one agent, or nothing. Read AS the agent, capped,
# and projected so no other field (and never a secret) can leave.
_agent_mail_entry() { # <agent>
  local agent="$1" f
  f="$(_agent_mail_home "$agent")/.config/5dive-mail/mail.json"
  _agent_mail_as "$agent" head -c 65536 -- "$f" 2>/dev/null \
    | jq -c --arg a "$agent" 'select(type == "object" and (.email | type) == "string")
                              | {agent:$a, email:.email, calendar:(.calendar == true)}' 2>/dev/null \
    | head -n 1
}

_agent_mail_list() {
  local a
  for a in "$@"; do fail "$E_USAGE" "usage: 5dive agent mail list"; done
  _agent_mail_is_root || fail "$E_PERMISSION" "agent mail list reads every agent's home: run as root"
  ensure_state_ro
  local names name row rows=()
  names=$(registry_read | jq -r '(.agents // {}) | keys[]' 2>/dev/null) || names=""
  while IFS= read -r name; do
    [[ -n "$name" ]] && valid_name "$name" || continue
    id -u "agent-${name}" >/dev/null 2>&1 || continue
    row=$(_agent_mail_entry "$name")
    [[ -n "$row" ]] && rows+=("$row")
  done <<<"$names"
  local arr='[]'
  (( ${#rows[@]} )) && arr=$(printf '%s\n' "${rows[@]}" | jq -cs .)
  ok "$(( ${#rows[@]} )) agent(s) with a mailbox$( (( ${#rows[@]} )) && printf ': %s' "$(jq -r 'map("\(.agent) <\(.email)>") | join(", ")' <<<"$arr")")" \
    '$r' --argjson r "$arr"
}

_agent_mail_show() {
  local agent="" a
  for a in "$@"; do
    case "$a" in
      -*) fail "$E_USAGE" "usage: 5dive agent mail show <agent>" ;;
      *) [[ -z "$agent" ]] && agent="$a" || fail "$E_USAGE" "usage: 5dive agent mail show <agent>" ;;
    esac
  done
  [[ -n "$agent" ]] || fail "$E_USAGE" "usage: 5dive agent mail show <agent>"
  _agent_mail_require_agent "$agent"
  if ! _agent_mail_is_root && [[ ! -O "$(_agent_mail_home "$agent")" ]]; then
    fail "$E_PERMISSION" "reading another agent's mailbox settings needs root"
  fi
  local row; row=$(_agent_mail_entry "$agent")
  if [[ -n "$row" ]]; then
    ok "'$agent' reads $(jq -r .email <<<"$row")" '$r' --argjson r "$row"
  else
    ok "'$agent' has no mailbox connected" 'null'
  fi
}
