# ── DIVE-7782: share links — any agent becomes a public link ────────────────
#
#   5dive agent share <name>              root: print the agent's public link
#   5dive agent share <name> --with-memory   ...and it brings what it learned
#   5dive agent share --list              every live share on this box
#   5dive agent unshare <name|link|id>    root: the link stops working
#   5dive config public-address=<https://name>|clear   root: a self-hosted box's address
#
# A share is a RECIPE, not a clone: the agent's name, portrait, instructions,
# skills and first-party plugins, exported for the PUBLISH audience. Never its
# logins, files, keys, hooks (custom scripts) or channels, and its memory only
# when the owner opts in.
#
# MEMORY IS OPT-IN (DIVE-7806, lodar 2026-11-06: "opt-in memory with the privacy
# scan"). Memory holds customers, names and addresses, so a default share
# carries none. `--with-memory` carries the same distilled set a published
# `agent export` does: only 'reference' and 'project' facts (what the agent
# learned), never 'user' or 'feedback' (notes about its people), never a fact
# marked private. Those facts then go through the SAME scan as everything else
# below (_share_scan, over the whole stage, memory/ included): one hit refuses
# the whole share and names memory/<file>:<line>. Nothing is trimmed.
#
# WHERE IT IS SERVED (lodar 2026-11-05: "it goes to the user own url"): from the
# sharing box itself, on the https front the box already has for secret links
# (`_secret_drop_base_url`): an owner's SECRET_DROP_BASE_URL, else
# secrets.<FIVE_DOMAIN> on a hosted box, else a self-hosted box's own front
# (SECRET_HTTPS_HOST). No new name and no new certificate: a new hosted name
# would cost one of Let's Encrypt's 50-a-week certificates for the shared
# registered domain. The page server is the same loopback page (port 3127);
# shares are static files it reads from SHARE_DIR, and while any share is live
# it does not idle out. A small boot unit starts it again after a reboot.
#
# REFUSALS, never trims: a share whose instructions or persona carry
# operational detail (host paths, names, ids, hostnames, sudo, credential
# locations — the export's own publish leak-scan) is refused with each hit.
# Only the 5dive-managed blocks of CLAUDE.md (re-written on every box) are left
# out before the scan.
#
# Shared agents are untrusted: `agent import --from-url=<share link>` gives the
# copy standard isolation, never admin, and the page says it is community-made.

SHARE_DIR="${SHARE_DIR:-${STATE_DIR}/shares}"
SHARE_BOOT_UNIT="5dive-share-serve"
SHARE_UNIT_DIR="${SHARE_UNIT_DIR:-/etc/systemd/system}"
SHARE_APP_ADD_URL="${SHARE_APP_ADD_URL:-https://my.5dive.ai/add}"
# The id in a link: 22 base64url chars (16 random bytes).
SHARE_ID_RE='^[A-Za-z0-9_-]{22}$'

_share_new_id() { head -c 16 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'; }

# The base a link starts with, or rc 1 (no public address on this box).
_share_base_url() { _secret_drop_base_url; }

# What `agent share` says when the box has no address. Written to be passed on.
_share_no_address_msg() {
  printf '%s' "this box has no public address, so a share link would not open. Tell your lead agent your public address (\"my public address is https://...\"), or run: sudo 5dive config public-address=https://<your name>"
}

# DIVE-7862: a refusal the app branches on, by a machine-readable reason in the
# --json envelope (error.reason), never by matching its sentence. The sentence
# stays for a terminal. Reasons: no_public_address (agent share), and from
# `config public-address`: hosted, invalid_address, unreachable.
_share_fail() { # <code> <reason> <message>
  local code="$1" reason="$2"; shift 2
  if (( JSON_MODE )); then
    jq -cn --argjson c "$code" --arg cl "$(err_class_for "$code")" --arg m "$*" --arg r "$reason" \
      '{ok:false, error:{code:$c, class:$cl, message:$m, reason:$r}}'
  fi
  echo "error: $*" >&2
  mark_reported
  exit "$code"
}

# The share dir of an agent, or rc 1.
_share_dir_of_agent() {
  local a="$1" d
  for d in "$SHARE_DIR"/*/; do
    [[ -f "${d}share.json" ]] || continue
    [[ "$(jq -r '.agent // empty' "${d}share.json" 2>/dev/null)" == "$a" ]] && { printf '%s' "${d%/}"; return 0; }
  done
  return 1
}

# Remove the 5dive-managed blocks (<!-- 5dive:<x>:begin ... 5dive:<x>:end -->)
# from a CLAUDE.md, in place. The receiving box writes its own.
_share_strip_managed() {
  local f="$1" tmp
  [[ -f "$f" ]] || return 0
  tmp=$(mktemp "${f}.XXXXXX") || return 1
  awk '/<!-- 5dive:[a-z0-9_-]+:begin/ { skip = 1; next }
       skip && /5dive:[a-z0-9_-]+:end/ { skip = 0; next }
       !skip { print }' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || return 1
  return 0
}

# Turn an exported stage into the recipe: drop what does not travel, pin the
# copy to standard, mark it community-made. Re-seals the checksums.
_share_sanitize_stage() {
  local stage="$1" mf="$1/manifest.json" t
  _share_strip_managed "$stage/CLAUDE.md" || return 1
  t=$(mktemp "${mf}.XXXXXX") || return 1
  jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      del(.config.authProfile, .config.workdir, .hooks, .files)
      | .config.isolation = "standard" | .config.channels = "none"
      | .share = {community_made: true, shared_at: $at}' "$mf" > "$t" || { rm -f "$t"; return 1; }
  mv -f "$t" "$mf"
  local hp=false; [[ -f "$stage/persona.yaml" ]] && hp=true
  _pack_bundle_manifest "$stage" "$hp"
}

# The leak scan over EVERYTHING the page will serve except the manifest we
# just wrote ourselves: instructions, persona, every skill body, the memory
# facts of a --with-memory share (memory/*.md) and any other file the export
# staged (DIVE-7782 iteration 2: skill bodies travel in
# pack.tar.gz, so a scan of CLAUDE.md alone published them unread). Hits on
# stderr as "<path>:<line>: <category>: <match>", path relative to the stage
# (skills/research/SKILL.md:3: ...). rc 1 = refuse.
_share_scan() {
  local stage="$1" name="$2" d
  d=$(mktemp -d) || return 1
  # Copy the stage minus manifest.json, keeping relative paths so a hit names
  # the file the reader will find in the pack. Symlinks are not followed.
  (cd "$stage" && tar -cf - --exclude=./manifest.json .) | (cd "$d" && tar -xf -) \
    || { rm -rf "$d"; return 1; }
  # The agent's own account name (agent-<name>) is not a leak in its own share:
  # the page is published under that name. Every other hit stands.
  local hits; hits=$(_pack_memory_leakscan "$d" "$name" 2>&1 >/dev/null) || true
  rm -rf "$d"
  hits=$(printf '%s\n' "$hits" | grep -viE ": identity-name: agent-${name}$" | grep -v '^$' || true)
  [[ -z "$hits" ]] && return 0
  printf '%s\n' "$hits" >&2
  return 1
}

# The facts a share carries: memory/*.md minus the index. <stage>
_share_memory_count() {
  [[ -d "$1/memory" ]] || { echo 0; return 0; }
  find "$1/memory" -maxdepth 1 -type f -name '*.md' ! -name MEMORY.md 2>/dev/null | wc -l
}

# The seat's shareable facts, distilled into <out>: the publish set of `agent
# export` ('reference'/'project' only, private ones out; a codex store is
# converted to atoms first). Echoes "<kept> <left out>"; rc 1 = no store.
_share_memory_distill() {   # <name> <out>
  local name="$1" out="$2" memdir src tmp="" counts
  memdir=$(_pack_memory_dir "$name" 2>/dev/null) || memdir=""
  [[ -n "$memdir" && -d "$memdir" ]] || return 1
  src="$memdir"
  if [[ "$(_pack_memory_kind "$name" 2>/dev/null)" == "codex" ]]; then
    tmp=$(mktemp -d) || return 1
    _pack_codex_to_atoms "$memdir" "$tmp" knowledge >/dev/null || { rm -rf "$tmp"; return 1; }
    src="$tmp"
  fi
  counts=$(_pack_scope_memory "$src" "$out") || { [[ -n "$tmp" ]] && rm -rf "$tmp"; return 1; }
  [[ -n "$tmp" ]] && rm -rf "$tmp"
  printf '%s\n' "$counts"
}

# Write index.html for a share from its stage. <stage> <out> <page url> <has avatar 0|1>
_share_render_page() {
  SHARE_STAGE="$1" SHARE_OUT="$2" SHARE_URL="$3" SHARE_AVATAR="$4" SHARE_ADD="$SHARE_APP_ADD_URL" \
    SHARE_MEM="$(_share_memory_count "$1")" python3 - <<'PY'
import html, json, os, re, urllib.parse
stage, out, url, has_av = os.environ["SHARE_STAGE"], os.environ["SHARE_OUT"], os.environ["SHARE_URL"], os.environ["SHARE_AVATAR"] == "1"
mem = int(os.environ.get("SHARE_MEM") or 0)
m = json.load(open(os.path.join(stage, "manifest.json")))
persona = {}
try:
    import yaml  # noqa
    persona = yaml.safe_load(open(os.path.join(stage, "persona.yaml"))) or {}
except Exception:
    try:
        for line in open(os.path.join(stage, "persona.yaml")):
            k, _, v = line.partition(":")
            if k in ("name", "role", "tagline", "description") and v.strip():
                persona.setdefault(k, v.strip().strip("'\""))
    except OSError:
        pass
def s(x): return x.strip() if isinstance(x, str) else ""
name = s(persona.get("name")) or m.get("agentName") or "Agent"
job = s(persona.get("tagline")) or s(persona.get("description")) or s(persona.get("role"))
job = re.sub(r"\s+", " ", job)
if len(job) > 140: job = job[:137].rstrip() + "..."
skills = [re.sub(r"^.*[:/]", "", str(x)) for x in (m.get("skills") or [])]
plugins = sorted({k.split("@")[0] for k, v in (m.get("plugins") or {}).items() if v})
E = html.escape
add = os.environ["SHARE_ADD"] + "?from=" + urllib.parse.quote(url, safe="")
chips = lambda xs: "".join("<li>%s</li>" % E(x) for x in xs)
av = ("<img class=av src='avatar.png' alt='' width=96 height=96>" if has_av
      else "<div class='av mono' aria-hidden=true>%s</div>" % E(name[:1].upper()))
brings = ""
if skills: brings += "<h2>Skills</h2><ul class=chips>%s</ul>" % chips(skills)
if plugins: brings += "<h2>Tools</h2><ul class=chips>%s</ul>" % chips(plugins)
# DIVE-7806: say plainly whether it comes with what it learned.
if mem:
    brings += ("<h2>Memory</h2><p class=stay>Comes with what it learned: %d %s.</p>"
               % (mem, "note" if mem == 1 else "notes"))
    stays = "Logins, files, keys and its private notes about people. You connect your own."
else:
    brings += "<h2>Memory</h2><p class=stay>Starts fresh: it comes without its memory.</p>"
    stays = "Logins, files, keys and private memory. You connect your own."
CSS = ("*{box-sizing:border-box}body{font:16px/1.5 system-ui,-apple-system,Segoe UI,sans-serif;margin:0;background:#f6f6f4;color:#1b1b1a}"
       "main{max-width:30rem;margin:0 auto;padding:2rem 1rem 3rem}"
       ".top{text-align:center}.av{width:96px;height:96px;border-radius:50%;object-fit:cover;display:block;margin:0 auto .75rem}"
       ".mono{background:#1b1b1a;color:#fff;font:600 2.5rem/96px system-ui,sans-serif;text-align:center}"
       "h1{font-size:1.6rem;margin:0}.job{margin:.25rem 0 .5rem;color:#444}"
       ".badge{display:inline-block;font-size:.8rem;padding:.15rem .6rem;border-radius:99px;background:#fff6dc;color:#6b5200}"
       "a.add{display:block;text-align:center;margin:1.25rem 0;padding:.9rem;border-radius:10px;background:#1b1b1a;color:#fff;font-weight:600;text-decoration:none}"
       "h2{font-size:.85rem;text-transform:uppercase;letter-spacing:.04em;color:#666;margin:1.25rem 0 .4rem}"
       ".chips{list-style:none;padding:0;margin:0;display:flex;flex-wrap:wrap;gap:.4rem}"
       ".chips li{background:#fff;border:1px solid #ddd;border-radius:99px;padding:.15rem .7rem;font-size:.9rem}"
       ".stay{color:#555;margin:0}small{color:#666;display:block;margin-top:1.5rem;overflow-wrap:anywhere}"
       "@media (prefers-color-scheme:dark){body{background:#151514;color:#eee}.job,.stay{color:#bbb}"
       ".chips li{background:#1f1f1e;border-color:#333}a.add{background:#eee;color:#151514}.mono{background:#eee;color:#151514}"
       ".badge{background:#3a3220;color:#f3d98b}small,h2{color:#aaa}}")
body = ("<div class=top>%s<h1>%s</h1>%s<span class=badge>Community-made</span></div>"
        "<a class=add href='%s'>Add %s to my 5dive</a>%s"
        "<h2>Stays behind</h2><p class=stay>%s</p>"
        "<small>Shared from someone's own 5dive server. Look it over before you add it. "
        "Already on 5dive? Tell your lead agent: add the agent at %s</small>"
        % (av, E(name), ("<p class=job>%s</p>" % E(job)) if job else "", E(add), E(name), brings, E(stays), E(url)))
title = "%s — a 5dive agent" % name
desc = job or "An AI agent you can add to your own 5dive."
doc = ("<!doctype html><html lang=en><head><meta charset=utf-8>"
       "<meta name=viewport content='width=device-width,initial-scale=1'>"
       "<title>%s</title><meta name=description content='%s'>"
       "<meta property=og:title content='%s'><meta property=og:description content='%s'>"
       "<style>%s</style></head><body><main>%s</main></body></html>"
       % (E(title), E(desc), E(title), E(desc), CSS, body))
open(out, "w").write(doc)
PY
}

# The boot unit: a reboot starts the page again while shares are live.
_share_boot_unit_install() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] || return 0
  local self; self="$(five_self_bundle 2>/dev/null || true)"; [[ -n "$self" ]] || return 0
  local f="$SHARE_UNIT_DIR/$SHARE_BOOT_UNIT.service"
  [[ -f "$f" ]] && return 0
  cat > "$f" <<UNIT || return 0
# Written by \`5dive agent share\` (DIVE-7782): serve this box's share links after a reboot.
[Unit]
Description=5dive share links: start the page after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$self agent share _serve

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "$SHARE_BOOT_UNIT" >/dev/null 2>&1 || true
}
_share_boot_unit_remove() {
  local f="$SHARE_UNIT_DIR/$SHARE_BOOT_UNIT.service"
  [[ -f "$f" ]] || return 0
  systemctl disable "$SHARE_BOOT_UNIT" >/dev/null 2>&1 || true
  rm -f "$f"
  systemctl daemon-reload >/dev/null 2>&1 || true
}
_share_any_live() { compgen -G "$SHARE_DIR/*/share.json" >/dev/null; }

# Start the page (and the hosted route) for the shares. rc 0 = serving.
_share_serve() {
  _share_any_live || return 0
  _secret_drop_ensure_route >/dev/null 2>&1 || true
  local uid rc=0
  uid=$(_secret_drop_ensure_server) || rc=$?
  (( rc == 2 )) && { warn "share: $(_secret_drop_squat_msg "$uid")"; return 1; }
  return "$rc"
}

_share_list() {
  local d rows="[]"
  for d in "$SHARE_DIR"/*/; do
    [[ -f "${d}share.json" ]] || continue
    rows=$(jq -c --slurpfile r "${d}share.json" '. + $r' <<<"$rows")
  done
  if (( JSON_MODE )); then ok "" '{shares:$r}' --argjson r "$rows"; return 0; fi
  [[ "$rows" == "[]" ]] && { echo "No shared agents on this box."; return 0; }
  jq -r '.[] | "\(.agent)\t\(.url)\t\(.shared_at)"' <<<"$rows"
}

cmd_agent_share() {
  local name="" a with_memory=0
  for a in "$@"; do
    case "$a" in
      --json) JSON_MODE=1 ;;
      --with-memory) with_memory=1 ;;
      --list) _share_list; return 0 ;;
      _serve) require_root agent share; _share_serve; return $? ;;
      -h|--help) printf '%s\n' \
        "usage: 5dive agent share <name>     # print <name>'s public link" \
        "       5dive agent share <name> --with-memory   # it brings what it learned" \
        "       5dive agent share --list     # every live share on this box" \
        "       5dive agent unshare <name|link>" \
        "" \
        "  The link opens a page on this box: name, portrait, job, skills, and an" \
        "  Add button. A share is a recipe: never logins, files, keys or custom" \
        "  scripts. Memory only with --with-memory: what it learned, never its notes" \
        "  about people, and refused whole if one line names a path, host or person." \
        "  A copy someone adds starts at standard isolation." \
        "  Sharing again refreshes the page and keeps the same link." \
        "  A self-hosted box needs its public address first:" \
        "    sudo 5dive config public-address=https://<your name>"
        return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $a" ;;
      *) [[ -z "$name" ]] || fail "$E_USAGE" "extra arg: $a"; name="$a" ;;
    esac
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent share <name> | --list"
  valid_name "$name" || fail "$E_VALIDATION" "invalid agent name: $name"
  require_root agent share
  command -v python3 >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" "agent share needs python3"
  local base; base=$(_share_base_url) || _share_fail "$E_CONFLICT" no_public_address "$(_share_no_address_msg)"

  local work; work=$(mktemp -d) || fail "$E_GENERIC" "no temp dir"
  # DIVE-7806: --with-memory distils the seat's facts and seals them into the
  # export (its seal re-applies the same type filter and the secret tripwire).
  # The export is told audience=self ONLY to move its operational-detail check
  # here: _share_scan below runs that same check over the whole stage, memory/
  # included, and names memory/<file>:<line> the way the page will serve it.
  # A refusal from it is a refusal of the share, as for every other file.
  local exp_args=(--audience=publish) mem_kept=0 mem_left=0
  if (( with_memory )); then
    local counts
    if counts=$(_share_memory_distill "$name" "$work/memory"); then
      mem_kept="${counts%% *}"; mem_left="${counts##* }"
    fi
    if (( mem_kept > 0 )); then
      exp_args=(--audience=self "--approve-memory=$work/memory")
    else
      warn "share: '$name' has nothing it learned to share yet (0 knowledge notes; $mem_left private ones stay here). Sharing it without memory."
    fi
  fi
  # The export runs in a subshell: its refusals `fail` (exit) and must come back
  # here as a reason, not end this command without one.
  local err=""
  if ! err=$( (JSON_MODE=0; cmd_export "$name" "${exp_args[@]}" -o "$work/pack.tar.gz") 2>&1 >/dev/null ); then
    rm -rf "$work"
    fail "$E_GENERIC" "could not share '$name': the export refused it: $(printf '%s' "$err" | grep -v '^==>' | tail -3 | tr '\n' ' ')"
  fi
  mkdir -p "$work/stage" && tar -xzf "$work/pack.tar.gz" -C "$work/stage" 2>/dev/null \
    || { rm -rf "$work"; fail "$E_GENERIC" "could not read the export of '$name'"; }
  _share_sanitize_stage "$work/stage" || { rm -rf "$work"; fail "$E_GENERIC" "could not prepare the share of '$name'"; }
  local hits=""
  if ! hits=$(_share_scan "$work/stage" "$name" 2>&1); then
    rm -rf "$work"
    [[ -n "$hits" ]] && printf '%s\n' "$hits" >&2
    fail "$E_VALIDATION" "not shared: '$name's instructions, skills or memory carry private detail a public link must not (each line above: file:line: kind: what). Rewrite those lines without the path, name, id or host, then share again. Nothing was published."
  fi
  local mem_n; mem_n=$(_share_memory_count "$work/stage")

  local dir id
  if dir=$(_share_dir_of_agent "$name"); then id="${dir##*/}"
  else id=$(_share_new_id); dir="$SHARE_DIR/$id"; fi
  [[ "$id" =~ $SHARE_ID_RE ]] || { rm -rf "$work"; fail "$E_GENERIC" "bad share id"; }
  local url="${base}/a/${id}"
  local new; new=$(mktemp -d "$SHARE_DIR.new.XXXXXX" 2>/dev/null) \
    || { mkdir -p "$SHARE_DIR" && new=$(mktemp -d "$SHARE_DIR.new.XXXXXX"); } \
    || { rm -rf "$work"; fail "$E_GENERIC" "cannot write $SHARE_DIR"; }
  (cd "$work/stage" && tar -czf "$new/pack.tar.gz" .) || { rm -rf "$work" "$new"; fail "$E_GENERIC" "could not pack the share"; }
  local has_av=0 avf; avf=$(_agent_avatar_path "$name" 2>/dev/null || true)
  if [[ -n "$avf" && -f "$avf" && ! -L "$avf" ]] && (( $(stat -c %s "$avf" 2>/dev/null || echo 0) < 4194304 )); then
    cp "$avf" "$new/avatar.png" && has_av=1
  fi
  _share_render_page "$work/stage" "$new/index.html" "$url" "$has_av" \
    || { rm -rf "$work" "$new"; fail "$E_GENERIC" "could not render the share page"; }
  jq -n --arg id "$id" --arg a "$name" --arg u "$url" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson m "$mem_n" \
    '{id:$id, agent:$a, url:$u, shared_at:$at, memory:$m}' > "$new/share.json"
  rm -rf "$work"
  mkdir -p "$SHARE_DIR"; chmod 755 "$new"; chmod 644 "$new"/*
  rm -rf "${dir:?}.old"; [[ -d "$dir" ]] && mv "$dir" "$dir.old"
  mv "$new" "$dir"; rm -rf "${dir:?}.old"

  _share_boot_unit_install
  local serving=true; _share_serve || serving=false
  local served=false
  [[ "$serving" == true ]] && curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:${SECRET_DROP_PORT}/a/${id}" 2>/dev/null && served=true
  [[ "$served" == true ]] || warn "share: the page is not answering on this box yet; the link opens once it does ($SHARE_BOOT_UNIT starts it at boot)"
  local stays="logins, files, keys and memory stay here"
  (( mem_n > 0 )) && stays="it brings $mem_n note(s) of what it learned; logins, files, keys and its notes about people stay here"
  ok "share link for '$name': $url
   Anyone who opens it can add a copy of '$name' to their own 5dive ($stays).
   Stop it any time: sudo 5dive agent unshare $name" \
    '{agent:$a, url:$u, id:$id, serving:$s, memory:$m}' --arg a "$name" --arg u "$url" --arg id "$id" --argjson s "$served" --argjson m "$mem_n"
}

cmd_agent_unshare() {
  local what="" a
  for a in "$@"; do
    case "$a" in
      --json) JSON_MODE=1 ;;
      -h|--help) echo "usage: 5dive agent unshare <name|link|id>   # the link stops working"; return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $a" ;;
      *) [[ -z "$what" ]] || fail "$E_USAGE" "extra arg: $a"; what="$a" ;;
    esac
  done
  [[ -n "$what" ]] || fail "$E_USAGE" "usage: 5dive agent unshare <name|link|id>"
  require_root agent unshare
  local id="" dir=""
  if [[ "$what" == https://* ]]; then
    id="${what%/}"; id="${id##*/a/}"; id="${id%%/*}"
  elif [[ "$what" =~ $SHARE_ID_RE ]] && [[ -d "$SHARE_DIR/$what" ]]; then
    id="$what"
  elif dir=$(_share_dir_of_agent "$what"); then
    id="${dir##*/}"
  fi
  [[ -n "$id" && "$id" =~ $SHARE_ID_RE && -d "$SHARE_DIR/$id" ]] \
    || fail "$E_NOT_FOUND" "no live share for '$what' on this box (see: 5dive agent share --list)"
  local agent; agent=$(jq -r '.agent // empty' "$SHARE_DIR/$id/share.json" 2>/dev/null || true)
  rm -rf "${SHARE_DIR:?}/${id:?}"
  _share_any_live || _share_boot_unit_remove
  ok "unshared${agent:+ '$agent'}: the link no longer opens" '{agent:$a, id:$id, unshared:true}' --arg a "$agent" --arg id "$id"
}

# ── `5dive config public-address=<https://name>|clear` ──────────────────────
# A self-hosted box's public address (lodar 2026-11-05: "we cannot control. so
# it goes to agent lead or a command"). It REUSES the existing setting secret
# links already read: an address that already reaches this box (the owner's own
# proxy or tunnel) is kept as SECRET_DROP_BASE_URL; a bare name pointed at this
# box gets the box's own https front (`secret https enable --via=domain`).
# Checked on set: a one-time probe file must come back through the address.
_public_address_probe() { # <base url> → rc 0 when it reaches THIS box's page
  local base="$1" nonce; nonce=$(_share_new_id)
  mkdir -p "$SHARE_DIR/.probe" || return 1
  : > "$SHARE_DIR/.probe/$nonce"
  local body; body=$(curl -fsS --proto '=https' --max-time 8 "${base}/a/_probe/${nonce}" 2>/dev/null) || body=""
  rm -f "$SHARE_DIR/.probe/$nonce"
  [[ "$body" == "$nonce" ]]
}

cmd_public_address() {
  local v="${1:-}"
  require_root config public-address
  if _secret_drop_domain >/dev/null 2>&1; then
    _share_fail "$E_CONFLICT" hosted "this box is hosted by 5dive: its public address is set already ($(_share_base_url))"
  fi
  if [[ "$v" == clear || "$v" == default ]]; then
    if [[ -f "$SECRET_DROP_CONF" ]]; then
      local t; t=$(mktemp "${SECRET_DROP_CONF}.XXXXXX") && grep -v '^SECRET_DROP_BASE_URL=' "$SECRET_DROP_CONF" > "$t"; chmod 644 "$t"; mv -f "$t" "$SECRET_DROP_CONF"
    fi
    ok "public-address cleared" '{public_address:null}'; return 0
  fi
  [[ "$v" == http://* ]] && _share_fail "$E_VALIDATION" invalid_address "The address must start with https:// (got http)."
  [[ "$v" == https://* ]] || v="https://$v"
  v="${v%/}"
  [[ "$v" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]] \
    || _share_fail "$E_VALIDATION" invalid_address "That doesn't look like a web address. Write it like https://box.example.com (got '$1')."
  _secret_drop_ensure_server >/dev/null 2>&1 || true
  if _public_address_probe "$v"; then
    mkdir -p "${SECRET_DROP_CONF%/*}"
    local t; t=$(mktemp "${SECRET_DROP_CONF}.XXXXXX") || fail "$E_GENERIC" "cannot write $SECRET_DROP_CONF"
    [[ -f "$SECRET_DROP_CONF" ]] && grep -v '^SECRET_DROP_BASE_URL=' "$SECRET_DROP_CONF" > "$t"
    printf 'SECRET_DROP_BASE_URL=%s\n' "$v" >> "$t"; chmod 644 "$t"; mv -f "$t" "$SECRET_DROP_CONF"
    ok "public-address = $v (checked: it reaches this box)" '{public_address:$v, via:"proxy"}' --arg v "$v"; return 0
  fi
  local host="${v#https://}"
  if [[ "$host" != */* && "$host" != *:* ]]; then
    step "$v does not reach this box yet; setting up https on this box for $host (ports 80 and 443 must reach it)"
    if _secret_https_enable domain "$host" && _public_address_probe "https://$host"; then
      ok "public-address = https://$host (checked: it reaches this box)" '{public_address:$v, via:"box"}' --arg v "https://$host"; return 0
    fi
    _share_fail "$E_CONFLICT" unreachable "Not saved: https://$host doesn't lead to this server yet (${SECRET_HTTPS_WHY:-the check came back empty}). Point the name at this server's IP address, open ports 80 and 443, and try again."
  fi
  _share_fail "$E_CONFLICT" unreachable "Not saved: $v doesn't lead to this server. Its proxy or tunnel must forward to port ${SECRET_DROP_PORT} on this server."
}
