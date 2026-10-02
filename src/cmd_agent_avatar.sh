# -------- agent avatar (DIVE-5104) --------
#
# ONE canonical portrait path per agent: ~/.claude/avatar.png under the agent's
# own home. Marketplace import already wrote it (cmd_pack.sh), but nothing else
# did and nothing read it, so a hired persona lost its face the moment it landed
# in the dashboard's agent list (lodar, 2026-09-28: "we hired clicker from
# marketplace ... but no avatar showing on agent list").
#
# Every writer goes through `_agent_avatar_install`, so the file on disk is
# always a real image under the size cap:
#   agent avatar set <agent> <png|url>   the openagent skill, once the portrait is final
#   agent cos set-avatar                 the Telegram bot photo writes the same file
#   agent avatar backfill [--once]       one pass over *.persona.yaml face.ref,
#                                        then the box's own /openagent/<agent>.png
# and ONE reader: `agent list --json` reports `avatar: {path,bytes,mtime}` (the
# snapshot python in cmd_agent.sh), and the dashboard then asks for the bytes
# with `agent avatar get <agent> --data --json` over the exec tunnel.
#
# The name stays avatar.png whatever the bytes are (a face.ref is often a JPEG):
# every consumer — the browser, Telegram's setMyProfilePhoto — sniffs the bytes.

AGENT_AVATAR_MAX_BYTES="${AGENT_AVATAR_MAX_BYTES:-2097152}"
# Where the box's public domain is recorded (FIVE_DOMAIN). Overridable for the
# harness only: under sudo it is reset, so a caller cannot point root at a file.
AGENT_AVATAR_PROVISIONING="${AGENT_AVATAR_PROVISIONING:-/etc/5dive/provisioning.env}"
if (( EUID == 0 )) && [[ -n "${SUDO_UID:-}" ]]; then AGENT_AVATAR_PROVISIONING=/etc/5dive/provisioning.env; fi

_agent_avatar_path() { # <name>
  printf '%s/agent-%s/.claude/avatar.png\n' "${AGENT_HOME_ROOT:-/home}" "$1"
}

_agent_avatar_is_root() { (( EUID == 0 )); }

# Run <cmd> as agent-<agent> when we are root, else as the caller. Every root
# access to the CONTENT of an agent-owned path goes through here (the writes,
# the backfill's reads of persona files and face.ref, get's read of avatar.png):
# the agent can swap any component for a link at any moment, and as the agent a
# link reaches nothing the agent could not already reach. `runuser`, not
# `sudo -u`: runas is narrowed on this fleet (DIVE-3263) and runuser consults no
# policy. No runuser means no drop, and root does not write in its place.
_agent_avatar_as() { # <agent> <cmd...>
  local agent="$1"; shift
  if _agent_avatar_is_root; then
    command -v runuser >/dev/null 2>&1 || { printf 'runuser not found; refusing to touch agent-%s as root\n' "$agent" >&2; return 1; }
    runuser -u "agent-${agent}" -- "$@"
  else
    "$@"
  fi
}

# Echo png|jpeg|webp|gif for a file whose leading bytes are that image format;
# return 1 for anything else (an HTML error page, a YAML file, /etc/shadow).
_agent_avatar_sniff() { # <file>
  local hex
  hex=$(head -c 12 -- "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n') || return 1
  case "$hex" in
    89504e470d0a1a0a*)          printf 'png\n' ;;
    ffd8ff*)                    printf 'jpeg\n' ;;
    52494646????????57454250)   printf 'webp\n' ;;
    474946383?61*)              printf 'gif\n' ;;
    *) return 1 ;;
  esac
}

# Copy <src> (an http(s) URL or a readable local file) into <dst>. The size cap
# applies to the fetch itself, so a huge or endless body is never written out.
# With <agent>, a local <src> is agent-written (a persona face.ref) and is read
# AS that agent: only <dst>, root's own temp file, is opened by this process.
_agent_avatar_fetch() { # <src> <dst> [agent]
  local src="$1" dst="$2" agent="${3:-}"
  if [[ "$src" =~ ^https?:// ]]; then
    curl -fsSL --max-time 20 --max-filesize "$AGENT_AVATAR_MAX_BYTES" \
      --proto '=http,https' -o "$dst" -- "$src" 2>/dev/null
  elif [[ -n "$agent" ]]; then
    _agent_avatar_as "$agent" head -c "$(( AGENT_AVATAR_MAX_BYTES + 1 ))" -- "$src" >"$dst" 2>/dev/null
  else
    [[ -f "$src" && -r "$src" ]] || return 1
    cp -- "$src" "$dst" 2>/dev/null
  fi
}

# Validate <file> and install it as <agent>'s avatar. Echoes the format on
# success; on failure echoes the reason and returns 1 (the caller decides
# whether that is fatal).
_agent_avatar_install() { # <agent> <file>
  local agent="$1" file="$2" size fmt
  local home; home="${AGENT_HOME_ROOT:-/home}/agent-${agent}"
  local dir="$home/.claude" dst tmp
  dst=$(_agent_avatar_path "$agent")
  [[ -d "$home" ]] || { printf 'no home directory for agent %s\n' "$agent"; return 1; }
  size=$(stat -c %s -- "$file" 2>/dev/null) || { printf 'unreadable image\n'; return 1; }
  (( size > 0 )) || { printf 'empty image\n'; return 1; }
  (( size <= AGENT_AVATAR_MAX_BYTES )) \
    || { printf 'image is %s bytes, over the %s-byte cap\n' "$size" "$AGENT_AVATAR_MAX_BYTES"; return 1; }
  fmt=$(_agent_avatar_sniff "$file") || { printf 'not a PNG, JPEG, WebP or GIF image\n'; return 1; }
  # Refuse the planted-link shapes up front, with a reason. These are lstat
  # snapshots, not the guard: the guard is that the write below runs as the agent.
  [[ ! -L "$dir" ]] || { printf '%s is a symlink; refusing to write through it\n' "$dir"; return 1; }
  # Same for the file itself: only a regular file at avatar.png is replaced.
  if [[ -L "$dst" ]] || { [[ -e "$dst" ]] && [[ ! -f "$dst" ]]; }; then
    printf '%s is a symlink or not a regular file; refusing to replace it\n' "$dst"; return 1
  fi
  # The WRITE runs as the agent, in both branches. Root must not resolve a path
  # inside an agent-owned dir: every check above is a snapshot, and the agent
  # can swap .claude, the temp name or avatar.png between that check and a root
  # syscall (quinn, iters 1-3: a planted avatar.png link, a planted temp link,
  # then a link swapped in during install's chmod-by-name, which made root chmod
  # /etc/shadow 644). As the agent, a swapped link reaches only what the agent
  # could already write. The image goes in on stdin, opened by THIS process,
  # because the agent cannot read root's mktemp source; dd conv=excl creates the
  # temp O_EXCL (a link planted at the name makes it fail, not follow).
  if ! _agent_avatar_is_root && [[ ! -O "$home" ]]; then
    printf "setting another agent's avatar needs root (run with sudo)\n"; return 1
  fi
  tmp="$dir/.avatar.png.$$"
  if ! { _agent_avatar_as "$agent" mkdir -p -- "$dir" \
      && _agent_avatar_as "$agent" rm -f -- "$tmp" \
      && _agent_avatar_as "$agent" dd of="$tmp" conv=excl status=none <"$file" \
      && _agent_avatar_as "$agent" chmod 644 -- "$tmp" \
      && _agent_avatar_as "$agent" mv -fT -- "$tmp" "$dst"; } 2>/dev/null; then # -T: never INTO dst
    _agent_avatar_as "$agent" rm -f -- "$tmp" 2>/dev/null
    printf 'could not write %s\n' "$dst"; return 1
  fi
  printf '%s\n' "$fmt"
}

# Print the face.ref of a persona yaml, or nothing. PyYAML when the box has it,
# else the two shapes the OpenAgent spec writes: a `face:` block with an indented
# `ref:`, or `face: {ref: ...}` inline.
_agent_avatar_persona_ref() { # <persona.yaml>
  /usr/bin/python3 - "$1" <<'PY' 2>/dev/null || true
import re, sys
path = sys.argv[1]
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError:
    sys.exit(0)
ref = None
try:
    import yaml
    doc = yaml.safe_load(text)
    face = doc.get("face") if isinstance(doc, dict) else None
    if isinstance(face, dict) and isinstance(face.get("ref"), str):
        ref = face["ref"]
except Exception:
    pass
if ref is None:
    m = re.search(r"^face:\s*\{[^}]*\bref:\s*['\"]?([^,'\"}\s]+)", text, re.M)
    if not m:
        m = re.search(r"^face:\s*\n((?:[ \t]+.*\n?)*)", text, re.M)
        if m:
            m = re.search(r"^[ \t]+ref:\s*['\"]?([^'\"\s#]+)", m.group(1), re.M)
    if m:
        ref = m.group(1)
if ref:
    print(ref.strip())
PY
}

# Resolve a face.ref found in <yaml> to something _agent_avatar_fetch takes:
# a URL as-is, a path relative to the yaml's directory, and ONLY when it lands
# inside the agent's own home — a persona file is agent-written text and the
# backfill runs as root.
_agent_avatar_resolve_ref() { # <agent> <yaml> <ref>
  local agent="$1" yaml="$2" ref="$3" home real
  home=$(realpath -e -- "${AGENT_HOME_ROOT:-/home}/agent-${agent}" 2>/dev/null) || return 1
  case "$ref" in
    http://*|https://*) printf '%s\n' "$ref"; return 0 ;;
    ""|monogram:*|data:*) return 1 ;;
  esac
  [[ "$ref" == /* ]] || ref="$(dirname -- "$yaml")/$ref"
  real=$(realpath -e -- "$ref" 2>/dev/null) || return 1
  [[ "$real" == "$home/"* ]] || return 1
  printf '%s\n' "$real"
}

# DIVE-5413 (lodar 10-02, of a CEO agent: "generated [his openagent avatar] in
# june ... and also online at <box>.5dive.com/openagent/<agent>.png"):
# before DIVE-5104 an OpenAgent portrait was hosted on the box's own site, as the
# openagent skill said to, and no persona under the agent's home names it. The
# public URL is the one place every such box agrees on, wherever the file sits on
# disk, so the backfill asks for it. Echoes the URL, or fails with no domain.
_agent_avatar_openagent_url() { # <agent>
  local d=""
  [[ -r "$AGENT_AVATAR_PROVISIONING" ]] && d=$(sed -n 's/^FIVE_DOMAIN=//p' "$AGENT_AVATAR_PROVISIONING" | tail -1)
  d="${d%\"}"; d="${d#\"}"
  [[ "$d" =~ ^[a-z0-9_]([a-z0-9_.-]*[a-z0-9])?$ && "$d" == *.* ]] || return 1
  printf 'https://%s/openagent/%s.png\n' "$d" "$1"
}

cmd_agent_avatar() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    set)      _agent_avatar_set "$@" ;;
    get)      _agent_avatar_get "$@" ;;
    backfill) _agent_avatar_backfill "$@" ;;
    *) fail "$E_USAGE" "usage: 5dive agent avatar set <agent> <png-path|https-url> | get <agent> [--data] | backfill [--once] [--dry-run]" ;;
  esac
}

_agent_avatar_set() {
  local agent="${1:-}" src="${2:-}"
  [[ -n "$agent" && -n "$src" ]] || fail "$E_USAGE" "usage: 5dive agent avatar set <agent> <png-path|https-url>"
  valid_name "$agent" || fail "$E_VALIDATION" "invalid agent name: $agent"
  require_agent "$agent"
  local tmp fmt
  tmp=$(mktemp) || fail "$E_GENERIC" "mktemp failed"
  if ! _agent_avatar_fetch "$src" "$tmp"; then
    rm -f -- "$tmp"; fail "$E_NOT_FOUND" "could not read an image from $src"
  fi
  if ! fmt=$(_agent_avatar_install "$agent" "$tmp"); then
    rm -f -- "$tmp"; fail "$E_VALIDATION" "avatar not set for '$agent': $fmt"
  fi
  rm -f -- "$tmp"
  local dst; dst=$(_agent_avatar_path "$agent")
  ok "avatar set for '$agent' ($fmt) → $dst" '{agent:$a, path:$p, format:$f}' \
    --arg a "$agent" --arg p "$dst" --arg f "$fmt"
}

# `--data` adds the bytes as a data: URI. That is how the dashboard gets them:
# the box's file proxy runs as `claude` and cannot enter an agent's 0750 home,
# while this verb runs as root through the exec tunnel and reads only this one
# path. The 2 MB cap keeps the base64 (~2.7 MB) inside that tunnel's 4 MB buffer.
_agent_avatar_get() {
  local agent="" data=0 a
  for a in "$@"; do
    case "$a" in
      --data) data=1 ;;
      -*) fail "$E_USAGE" "usage: 5dive agent avatar get <agent> [--data]" ;;
      *) [[ -z "$agent" ]] && agent="$a" ;;
    esac
  done
  [[ -n "$agent" ]] || fail "$E_USAGE" "usage: 5dive agent avatar get <agent> [--data]"
  valid_name "$agent" || fail "$E_VALIDATION" "invalid agent name: $agent"
  require_agent "$agent"
  local dst size mtime fmt snap
  dst=$(_agent_avatar_path "$agent")
  # ONE read, as the agent, into a temp file of ours; every check and the bytes
  # served come from that copy. Checking avatar.png and then reading it again as
  # root would let the agent swap in a link to a root-only file in between.
  snap=$(mktemp) || fail "$E_GENERIC" "mktemp failed"
  if [[ -f "$dst" && ! -L "$dst" ]] && mtime=$(stat -c %Y -- "$dst" 2>/dev/null) \
     && _agent_avatar_as "$agent" head -c "$(( AGENT_AVATAR_MAX_BYTES + 1 ))" -- "$dst" >"$snap" 2>/dev/null \
     && size=$(stat -c %s -- "$snap" 2>/dev/null) \
     && (( size > 0 && size <= AGENT_AVATAR_MAX_BYTES )) && fmt=$(_agent_avatar_sniff "$snap"); then
    # The URI goes to jq through a FILE: a real portrait's base64 (~450 KB for
    # 340 KB) is over the kernel's 128 KB limit for one argv string.
    local uri; uri=$(mktemp) || { rm -f -- "$snap"; fail "$E_GENERIC" "mktemp failed"; }
    if (( data )); then
      { printf 'data:image/%s;base64,' "$fmt"; base64 -w0 -- "$snap"; } >"$uri" \
        || { rm -f -- "$uri" "$snap"; fail "$E_GENERIC" "could not read $dst"; }
    fi
    ok "'$agent' has an avatar ($fmt, $size bytes) at $dst" \
      '{agent:$a, avatar:({path:$p, bytes:$b, mtime:$m, format:$f} + (if $u == "" then {} else {dataUri:$u} end))}' \
      --arg a "$agent" --arg p "$dst" --argjson b "$size" --argjson m "$mtime" --arg f "$fmt" --rawfile u "$uri"
    rm -f -- "$uri" "$snap"
  else
    rm -f -- "$snap"
    ok "'$agent' has no avatar" '{agent:$a, avatar:null}' --arg a "$agent"
  fi
}

# One pass: every registered agent WITHOUT an avatar whose home holds a persona
# yaml with a resolvable face.ref gets that portrait; failing that, the portrait
# its box serves at /openagent/<agent>.png (DIVE-5413). Never overwrites a
# portrait that is already there, so it is safe to re-run; `--once` makes
# `5dive update` run it a single time per box. The marker is v2 so a box that ran
# the persona-only pass once runs this one too.
_agent_avatar_backfill() {
  local once=0 dry=0 a
  for a in "$@"; do
    case "$a" in
      --once) once=1 ;;
      --dry-run) dry=1 ;;
      *) fail "$E_USAGE" "usage: 5dive agent avatar backfill [--once] [--dry-run]" ;;
    esac
  done
  local marker="$STATE_DIR/avatar-backfill.v2.done"
  if (( once )) && [[ -e "$marker" ]]; then
    ok "avatar backfill already ran on this box" '{skipped:"already-ran", set:[], missing:[]}'
    return 0
  fi
  _agent_avatar_is_root || (( dry )) || fail "$E_GENERIC" "avatar backfill writes into every agent's home: run with sudo"
  ensure_state_ro
  local names; names=$(registry_read | jq -r '.agents | keys[]')
  local set_list=() missing=() name home dst yaml ref src tmp why ytmp personas got="" oa_down=0 rc
  ytmp=$(mktemp) || fail "$E_GENERIC" "mktemp failed"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    home="${AGENT_HOME_ROOT:-/home}/agent-${name}"
    dst=$(_agent_avatar_path "$name")
    [[ -d "$home" ]] || continue
    # Any existing entry (a portrait, or a link/dir the agent planted) is left alone.
    [[ -e "$dst" || -L "$dst" ]] && continue
    src=""
    # Newest persona first: the one the agent last edited is its current face.
    # The walk, each persona read and the face.ref read below all run as the
    # agent (_agent_avatar_as): root reads nothing whose path the agent controls.
    # Captured whole before the loop reads it (no procsub: an interrupted one
    # would truncate the walk silently, the epipe census guard's shape).
    personas=$(_agent_avatar_as "$name" find "$home" -maxdepth 4 \( -name node_modules -o -name .git -o -name .cache \) -prune \
                 -o -type f \( -name '*.persona.yaml' -o -name 'persona.yaml' \) -printf '%T@ %p\n' 2>/dev/null \
               | sort -rn | cut -d' ' -f2-)
    while IFS= read -r yaml; do
      [[ -n "$yaml" ]] || continue
      _agent_avatar_as "$name" head -c 262144 -- "$yaml" >"$ytmp" 2>/dev/null || continue
      ref=$(_agent_avatar_persona_ref "$ytmp")
      [[ -n "$ref" ]] || continue
      src=$(_agent_avatar_resolve_ref "$name" "$yaml" "$ref") && break
      src=""
    done <<<"$personas"
    if [[ -z "$src" ]]; then
      # The box's own OpenAgent page. Most agents have none, and a box whose site
      # answers every path with its app returns HTML: only an image counts, and
      # a miss is not "unresolved" (nothing pointed here).
      # Fetched once, here, into root's own temp file; installed from that copy.
      # A box that cannot reach its own site at all (curl: resolve, connect,
      # timeout, TLS) is asked once, not 20s per agent inside update's 180s
      # budget. Any other failure is the site ANSWERING for this one agent: a
      # portrait over the cap is reported as unresolved and the walk goes on.
      (( oa_down )) && continue
      src=$(_agent_avatar_openagent_url "$name") || continue
      got=$(mktemp)
      _agent_avatar_fetch "$src" "$got"; rc=$?
      if (( rc != 0 )) || ! _agent_avatar_sniff "$got" >/dev/null; then
        rm -f -- "$got"; got=""
        case "$rc" in
          0|22) ;;
          5|6|7|28|35|52|56) oa_down=1 ;;
          63) missing+=("$name"); warn "could not set '$name' avatar from $src: portrait over the cap" ;;
          *)  missing+=("$name"); warn "could not set '$name' avatar from $src: fetch failed (curl $rc)" ;;
        esac
        continue
      fi
    fi
    if (( dry )); then
      set_list+=("$name"); step "would set '$name' from $src"
      [[ -z "$got" ]] || rm -f -- "$got"; got=""; continue
    fi
    tmp=${got:-$(mktemp)}
    if { [[ -n "$got" ]] || _agent_avatar_fetch "$src" "$tmp" "$name"; } && why=$(_agent_avatar_install "$name" "$tmp"); then
      set_list+=("$name"); step "set '$name' avatar from $src"
    else
      missing+=("$name"); warn "could not set '$name' avatar from $src${why:+: $why}"
    fi
    rm -f -- "$tmp"; why=""; got=""
  done <<<"$names"
  rm -f -- "$ytmp"
  (( once && !dry )) && { : >"$marker" 2>/dev/null || true; }
  local sj mj
  sj=$(json_array "${set_list[@]+"${set_list[@]}"}")
  mj=$(json_array "${missing[@]+"${missing[@]}"}")
  ok "avatar backfill: ${#set_list[@]} set, ${#missing[@]} unresolved" '{set:$s, missing:$m, dryRun:$d}' \
    --argjson s "$sj" --argjson m "$mj" --argjson d "$( (( dry )) && echo true || echo false)"
}
