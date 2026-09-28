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
#   agent avatar backfill [--once]       one pass over *.persona.yaml face.ref
# and ONE reader: `agent list --json` reports `avatar: {path,bytes,mtime}` (the
# snapshot python in cmd_agent.sh), and the dashboard then asks for the bytes
# with `agent avatar get <agent> --data --json` over the exec tunnel.
#
# The name stays avatar.png whatever the bytes are (a face.ref is often a JPEG):
# every consumer — the browser, Telegram's setMyProfilePhoto — sniffs the bytes.

AGENT_AVATAR_MAX_BYTES="${AGENT_AVATAR_MAX_BYTES:-2097152}"

_agent_avatar_path() { # <name>
  printf '%s/agent-%s/.claude/avatar.png\n' "${AGENT_HOME_ROOT:-/home}" "$1"
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
_agent_avatar_fetch() { # <src> <dst>
  local src="$1" dst="$2"
  if [[ "$src" =~ ^https?:// ]]; then
    curl -fsSL --max-time 20 --max-filesize "$AGENT_AVATAR_MAX_BYTES" \
      --proto '=http,https' -o "$dst" -- "$src" 2>/dev/null
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
  # Root writes into an agent-owned tree: never follow a link the agent planted.
  [[ ! -L "$dir" ]] || { printf '%s is a symlink; refusing to write through it\n' "$dir"; return 1; }
  tmp="$dir/.avatar.png.$$"
  if (( EUID == 0 )); then
    install -d -o "agent-${agent}" -g "agent-${agent}" -m 755 "$dir" 2>/dev/null \
      && install -o "agent-${agent}" -g "agent-${agent}" -m 644 -- "$file" "$tmp" 2>/dev/null \
      || { rm -f -- "$tmp"; printf 'could not write %s\n' "$dst"; return 1; }
  elif [[ -O "$home" ]]; then
    # An agent setting its OWN portrait (it owns its home) needs no privilege.
    mkdir -p -- "$dir" 2>/dev/null && install -m 644 -- "$file" "$tmp" 2>/dev/null \
      || { rm -f -- "$tmp"; printf 'could not write %s\n' "$dst"; return 1; }
  else
    printf "setting another agent's avatar needs root (run with sudo)\n"; return 1
  fi
  mv -f -- "$tmp" "$dst" 2>/dev/null || { rm -f -- "$tmp"; printf 'could not write %s\n' "$dst"; return 1; }
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
  local dst size mtime fmt
  dst=$(_agent_avatar_path "$agent")
  if [[ -f "$dst" && ! -L "$dst" ]] && size=$(stat -c %s -- "$dst" 2>/dev/null) \
     && (( size > 0 && size <= AGENT_AVATAR_MAX_BYTES )) \
     && mtime=$(stat -c %Y -- "$dst" 2>/dev/null) && fmt=$(_agent_avatar_sniff "$dst"); then
    # The URI goes to jq through a FILE: a real portrait's base64 (~450 KB for
    # 340 KB) is over the kernel's 128 KB limit for one argv string.
    local uri; uri=$(mktemp) || fail "$E_GENERIC" "mktemp failed"
    if (( data )); then
      { printf 'data:image/%s;base64,' "$fmt"; base64 -w0 -- "$dst"; } >"$uri" \
        || { rm -f -- "$uri"; fail "$E_GENERIC" "could not read $dst"; }
    fi
    ok "'$agent' has an avatar ($fmt, $size bytes) at $dst" \
      '{agent:$a, avatar:({path:$p, bytes:$b, mtime:$m, format:$f} + (if $u == "" then {} else {dataUri:$u} end))}' \
      --arg a "$agent" --arg p "$dst" --argjson b "$size" --argjson m "$mtime" --arg f "$fmt" --rawfile u "$uri"
    rm -f -- "$uri"
  else
    ok "'$agent' has no avatar" '{agent:$a, avatar:null}' --arg a "$agent"
  fi
}

# One pass: every registered agent WITHOUT an avatar whose home holds a persona
# yaml with a resolvable face.ref gets that portrait. Never overwrites a portrait
# that is already there, so it is safe to re-run; `--once` makes `5dive update`
# run it a single time per box.
_agent_avatar_backfill() {
  local once=0 dry=0 a
  for a in "$@"; do
    case "$a" in
      --once) once=1 ;;
      --dry-run) dry=1 ;;
      *) fail "$E_USAGE" "usage: 5dive agent avatar backfill [--once] [--dry-run]" ;;
    esac
  done
  local marker="$STATE_DIR/avatar-backfill.v1.done"
  if (( once )) && [[ -e "$marker" ]]; then
    ok "avatar backfill already ran on this box" '{skipped:"already-ran", set:[], missing:[]}'
    return 0
  fi
  (( EUID == 0 || dry )) || fail "$E_GENERIC" "avatar backfill writes into every agent's home: run with sudo"
  ensure_state_ro
  local names; names=$(registry_read | jq -r '.agents | keys[]')
  local set_list=() missing=() name home dst yaml ref src tmp why
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    home="${AGENT_HOME_ROOT:-/home}/agent-${name}"
    dst=$(_agent_avatar_path "$name")
    [[ -d "$home" ]] || continue
    [[ -f "$dst" ]] && continue
    src=""
    # Newest persona first: the one the agent last edited is its current face.
    while IFS= read -r yaml; do
      ref=$(_agent_avatar_persona_ref "$yaml")
      [[ -n "$ref" ]] || continue
      src=$(_agent_avatar_resolve_ref "$name" "$yaml" "$ref") && break
      src=""
    done < <(find "$home" -maxdepth 4 \( -name node_modules -o -name .git -o -name .cache \) -prune \
               -o -type f \( -name '*.persona.yaml' -o -name 'persona.yaml' \) -printf '%T@ %p\n' 2>/dev/null \
             | sort -rn | cut -d' ' -f2-)
    [[ -n "$src" ]] || continue
    if (( dry )); then set_list+=("$name"); step "would set '$name' from $src"; continue; fi
    tmp=$(mktemp)
    if _agent_avatar_fetch "$src" "$tmp" && why=$(_agent_avatar_install "$name" "$tmp"); then
      set_list+=("$name"); step "set '$name' avatar from $src"
    else
      missing+=("$name"); warn "could not set '$name' avatar from $src${why:+: $why}"
    fi
    rm -f -- "$tmp"; why=""
  done <<<"$names"
  (( once && !dry )) && { : >"$marker" 2>/dev/null || true; }
  local sj mj
  sj=$(json_array "${set_list[@]+"${set_list[@]}"}")
  mj=$(json_array "${missing[@]+"${missing[@]}"}")
  ok "avatar backfill: ${#set_list[@]} set, ${#missing[@]} unresolved" '{set:$s, missing:$m, dryRun:$d}' \
    --argjson s "$sj" --argjson m "$mj" --argjson d "$( (( dry )) && echo true || echo false)"
}
