# DIVE-5501: `agent switch <name> --to=claude|codex` — move ONE agent between
# Claude Code and Codex IN PLACE.
#
# The trigger is the account move. An account is a Claude sign-in or a ChatGPT
# (Codex) sign-in, never a neutral one (wiki: an-auth-profile-serves-one-harness),
# so binding a Claude seat to a ChatGPT account IS a harness switch. Before this,
# `agent config <n> set auth-profile=<chatgpt>` accepted it and restarted the seat
# into a login failure (DIVE-5432), and building the other-harness twin by hand
# took six steps and still missed the browser store (luna, DIVE-5478).
#
# In place means the SAME name and unix user: sudo grants, browser store, tasks,
# a2a, heartbeat and the Telegram bot token all stay. What moves:
#   1. handoff  — the running seat is asked to write ~/.5dive-handoff.md; the
#                 carried instructions tell the target harness to read it first.
#   2. memory   — claude -> codex: the atoms STAY in the 5dive store
#                 (~/.claude/projects/*/memory), which `5dive memory search` reads
#                 for every harness (DIVE-4923), and their index is carried into
#                 AGENTS.md, the one file codex always loads. codex's native
#                 ~/.codex/memories is codex-written and is not hand-edited here.
#                 codex -> claude: those three documents are CONVERTED into atoms
#                 (DIVE-4541's splitter) and indexed in a marker block of MEMORY.md.
#   3. instructions — CLAUDE.md <-> AGENTS.md through one marker block; 5dive's
#                 own per-harness fragments are not carried (each side has its own).
#   4. channels — the same bot token and allowFrom on the other bridge.
#   5. account  — re-pointed; the model is the target side's own setting, or the
#                 harness default on a side that never ran.
#   6. the source side's files are KEPT, so switching back reuses them and only
#      what changed since (the carried block, codex atoms) is rewritten.
#   7. start, and report whether the unit came back.
# Nothing is mutated until every pre-flight check passes.

SWITCH_CARRY_MARKER="5dive:carried-instructions"
SWITCH_CODEX_MEM_MARKER="5dive:codex-memory"
SWITCH_HANDOFF_FILE=".5dive-handoff.md"
# Carried memory index budget: AGENTS.md is loaded every turn, so the index is
# cut at a byte budget and the rest is reached by search (DIVE-3821's lesson).
SWITCH_INDEX_BUDGET="${FIVEDIVE_SWITCH_INDEX_BUDGET:-8000}"

_switch_home() { printf '%s/agent-%s\n' "${SWITCH_HOME_ROOT:-/home}" "$1"; }

_switch_label() {
  case "$1" in claude) printf 'Claude Code' ;; codex) printf 'Codex' ;; *) printf '%s' "$1" ;; esac
}

# The plain sentence every surface shows before a switch. One string, so the
# CLI refusal, the Mini App and the dashboard cannot drift apart.
switch_harness_warning() { # <name> <from> <to>
  local plan
  [[ "$3" == codex ]] && plan="ChatGPT" || plan="Claude"
  printf 'Moving %s to your %s plan switches it from %s to %s. Its memory and instructions are converted; this chat'"'"'s history is not. You can switch back any time.' \
    "$1" "$plan" "$(_switch_label "$2")" "$(_switch_label "$3")"
}

# The harness an account signs in for, among the two this verb moves between.
# Prints claude, codex, both, or nothing. "" = the box default credentials.
switch_account_harness() { # <profile>
  local p="${1:-}" t c=0 x=0 path
  if [[ -z "$p" || "$p" == default ]]; then
    for t in claude codex; do
      path=$(profile_type_auth_path "" "$t" 2>/dev/null) || path=""
      if [[ -n "$path" && -s "$path" ]]; then
        [[ "$t" == claude ]] && c=1 || x=1
      fi
    done
  else
    account_types_authed_arr "$p"
    for t in ${ACCOUNT_TYPES_AUTHED[@]+"${ACCOUNT_TYPES_AUTHED[@]}"}; do
      [[ "$t" == claude ]] && c=1
      [[ "$t" == codex ]] && x=1
    done
  fi
  if (( c && x )); then printf 'both\n'
  elif (( c )); then printf 'claude\n'
  elif (( x )); then printf 'codex\n'
  fi
}

# Is moving a <type> seat to <profile> a harness switch? Prints the target type
# when the account serves the OTHER harness and not this one; nothing otherwise
# (same harness, both, or an account with no sign-in yet — those bind as before).
switch_target_for_account() { # <type> <profile>
  local type="$1" h
  [[ "$type" == claude || "$type" == codex ]] || return 0
  h=$(switch_account_harness "$2")
  case "$h" in
    claude) [[ "$type" == codex ]] && printf 'claude\n' ;;
    codex)  [[ "$type" == claude ]] && printf 'codex\n' ;;
  esac
  return 0
}

# Remove one marker block (<!-- id:begin ... --> .. <!-- id:end -->) from stdin.
_switch_strip_block() { # <id>
  awk -v id="$1" '
    index($0, "<!-- " id ":begin") { skip = 1; next }
    skip { if (index($0, "<!-- " id ":end")) skip = 0; next }
    { print }'
}

# Pure: the TARGET instruction document after carrying <src> into it.
#   src  the source harness's instruction file (may be missing)
#   dst  the target harness's instruction file (may be missing)
#   memidx  optional file whose text is carried as the memory index (to codex)
#   frag... files whose text is 5dive's own source-harness fragment, removed
#           verbatim from what is carried (the target side has its own).
# Text that was itself carried INTO src earlier is dropped, so a round trip does
# not stack copies; the target's own text outside the block is kept byte-for-byte.
switch_carry_doc() { # <src> <dst> <from> <to> <memidx|""> [frag...]
  local src="$1" dst="$2" from="$3" to="$4" memidx="$5"; shift 5
  local body
  body=$(
    { [[ -f "$src" ]] && cat "$src"; } \
      | _switch_strip_block "$SWITCH_CARRY_MARKER" \
      | _switch_strip_block "$CODEX_BASELINE_MARKER" \
      | _switch_strip_block "$SWITCH_CODEX_MEM_MARKER" \
      | python3 -c '
import sys
text = sys.stdin.read()
for f in sys.argv[1:]:
    try:
        frag = open(f).read().strip()
    except OSError:
        continue
    if frag:
        text = text.replace(frag, "")
lines = [l.rstrip() for l in text.strip().splitlines()]
out, blank = [], 0
for l in lines:
    blank = blank + 1 if not l else 0
    if blank <= 1:
        out.append(l)
print("\n".join(out))
' "$@"
  )
  local keep=""
  [[ -f "$dst" ]] && keep=$(_switch_strip_block "$SWITCH_CARRY_MARKER" <"$dst" \
    | python3 -c 'import sys; print(sys.stdin.read().rstrip())')
  [[ -n "$keep" ]] && printf '%s\n' "$keep"
  [[ -n "$keep" ]] && printf '\n'
  printf '<!-- %s:begin from=%s -->\n' "$SWITCH_CARRY_MARKER" "$from"
  printf '# Carried over from %s\n\n' "$(_switch_label "$from")"
  printf 'This agent was switched from %s to %s. Before anything else on your\n' \
    "$(_switch_label "$from")" "$(_switch_label "$to")"
  printf 'first turn, read ~/%s (what was in flight). 5dive rewrites this block\n' "$SWITCH_HANDOFF_FILE"
  printf 'on every switch; put your own instructions outside it.\n'
  if [[ -n "$body" ]]; then
    printf '\n## Standing instructions\n\n%s\n' "$body"
  fi
  if [[ -n "$memidx" && -s "$memidx" ]]; then
    printf '\n## Memory\n\nYour memory stays in the 5dive store. Search it with\n'
    printf '`5dive memory search --index "<topic>"`, then `5dive memory get <slug>`.\n\n'
    head -c "$SWITCH_INDEX_BUDGET" "$memidx" | python3 -c '
import sys
t = sys.stdin.read()
# never end on half a line: the cut is at the budget, the text at a line end
if not t.endswith("\n") and "\n" in t:
    t = t[: t.rfind("\n") + 1]
sys.stdout.write(t)'
    [[ $(wc -c <"$memidx") -gt "$SWITCH_INDEX_BUDGET" ]] \
      && printf '\n(index cut at %s bytes; search for the rest)\n' "$SWITCH_INDEX_BUDGET"
  fi
  printf '<!-- %s:end -->\n' "$SWITCH_CARRY_MARKER"
}

# The claude memory dir this seat uses: the workdir's project slug, else the one
# existing store, else the workdir slug (created).
switch_claude_memdir() { # <name> <workdir>
  local home d slug n=0 only=""
  home=$(_switch_home "$1")
  slug=$(printf '%s' "${2:-$DEFAULT_WORKDIR}" | sed 's/[^a-zA-Z0-9]/-/g')
  if [[ -d "$home/.claude/projects/$slug/memory" ]]; then
    printf '%s\n' "$home/.claude/projects/$slug/memory"; return 0
  fi
  for d in "$home"/.claude/projects/*/memory; do
    [[ -d "$d" ]] || continue
    n=$((n + 1)); only="$d"
  done
  if (( n == 1 )); then printf '%s\n' "$only"; else printf '%s\n' "$home/.claude/projects/$slug/memory"; fi
}

# codex -> claude: convert ~/.codex/memories into atoms in <memdir>, rewriting
# only codex-* atoms that changed, removing ones no longer produced, and keeping
# every claude-native atom. Prints "added updated removed unchanged".
switch_codex_memory_to_atoms() { # <codex-memories-dir> <memdir>
  local src="$1" mdir="$2" stage f base a=0 u=0 r=0 s=0
  stage=$(mktemp -d) || return 1
  if [[ -d "$src" ]]; then
    _pack_codex_to_atoms "$src" "$stage" all >/dev/null || true
  fi
  mkdir -p "$mdir"
  for f in "$stage"/codex-*.md; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    if [[ ! -f "$mdir/$base" ]]; then cp "$f" "$mdir/$base"; a=$((a + 1))
    elif ! cmp -s "$f" "$mdir/$base"; then cp "$f" "$mdir/$base"; u=$((u + 1))
    else s=$((s + 1)); fi
  done
  for f in "$mdir"/codex-tg-*.md "$mdir"/codex-profile-*.md "$mdir"/codex-thread-*.md; do
    [[ -f "$f" ]] || continue
    [[ -f "$stage/$(basename "$f")" ]] || { rm -f "$f"; r=$((r + 1)); }
  done
  rm -rf "$stage"
  _switch_index_codex_atoms "$mdir"
  printf '%s %s %s %s\n' "$a" "$u" "$r" "$s"
}

# Keep MEMORY.md's codex block in step with the codex-* atoms (budgeted; the
# seat's own index outside the block is untouched).
_switch_index_codex_atoms() { # <memdir>
  local mdir="$1" idx="$1/MEMORY.md" tmp lines="" f nm d n=0 more=0
  for f in "$mdir"/codex-tg-*.md "$mdir"/codex-profile-*.md "$mdir"/codex-thread-*.md; do
    [[ -f "$f" ]] || continue
    n=$((n + 1))
    nm=$(basename "$f" .md)
    d=$(sed -n 's/^description: *"\{0,1\}\(.*\)"\{0,1\}$/\1/p' "$f" | head -1 | sed 's/"$//')
    if (( ${#lines} < 4000 )); then lines+="- [${nm}](${nm}.md) — ${d}"$'\n'; else more=$((more + 1)); fi
  done
  tmp=$(mktemp) || return 1
  if [[ -f "$idx" ]]; then _switch_strip_block "$SWITCH_CODEX_MEM_MARKER" <"$idx" >"$tmp"
  else printf '# Memory Index\n' >"$tmp"; fi
  if (( n > 0 )); then
    {
      printf '\n<!-- %s:begin -->\n## Converted from Codex memory (%s atoms)\n\n' "$SWITCH_CODEX_MEM_MARKER" "$n"
      printf '%s' "$lines"
      (( more > 0 )) && printf -- '- …and %s more codex-* atoms: `5dive memory search`\n' "$more"
      printf '<!-- %s:end -->\n' "$SWITCH_CODEX_MEM_MARKER"
    } >>"$tmp"
  fi
  cat "$tmp" >"$idx"; rm -f "$tmp"
}

# All claude memory index text of a seat, for carrying into AGENTS.md.
_switch_claude_index_text() { # <name> <out-file>
  local home d
  home=$(_switch_home "$1")
  : >"$2"
  for d in "$home"/.claude/projects/*/memory; do
    [[ -f "$d/MEMORY.md" ]] || continue
    _switch_strip_block "$SWITCH_CODEX_MEM_MARKER" <"$d/MEMORY.md" >>"$2"
  done
}

# Union the source side's Telegram allowlist + groups into the target's
# access.json (the target's own dmPolicy and entries win). Prints allowFrom size.
switch_merge_access() { # <src-access.json> <dst-access.json>
  python3 - "$1" "$2" <<'PY'
import json, os, sys, tempfile
src, dst = sys.argv[1], sys.argv[2]
def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return None
s = load(src) or {}
d = load(dst)
if d is None:
    d = {k: v for k, v in s.items() if k != "pending"}
allow = list(d.get("allowFrom") or [])
for x in s.get("allowFrom") or []:
    if x not in allow:
        allow.append(x)
d["allowFrom"] = allow
groups = dict(d.get("groups") or {})
for k, v in (s.get("groups") or {}).items():
    groups.setdefault(k, v)
d["groups"] = groups
d.setdefault("pending", {})
d.setdefault("dmPolicy", s.get("dmPolicy") or ("allowlist" if allow else "pairing"))
os.makedirs(os.path.dirname(dst), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst), prefix=".access.", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, dst)
print(len(allow))
PY
}

# Skill names on <from> that the seat does not have on <to> after the switch.
_switch_dropped_skills() { # <name> <from> <to>
  local home a b s out=()
  home=$(_switch_home "$1")
  a="$home/$(skills_install_dir "$2")"; b="$home/$(skills_install_dir "$3")"
  [[ -d "$a" ]] || return 0
  for s in "$a"/*/; do
    [[ -d "$s" ]] || continue
    s=$(basename "$s")
    [[ -d "$b/$s" ]] || out+=("$s")
  done
  printf '%s\n' ${out[@]+"${out[@]}"}
}

_switch_tg_token() { # <home> <type>
  { sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$1/.$2/channels/telegram/.env" 2>/dev/null || true; } | head -1
}

# Write <content-file> to <path> owned by the seat, refusing a symlinked target.
_switch_install_file() { # <user> <content-file> <path> [mode]
  local user="$1" content="$2" path="$3" mode="${4:-644}"
  [[ ! -L "$path" ]] || { warn "refusing to write through a symlink: $path"; return 1; }
  install -d -o "$user" -g "$user" -m 700 "$(dirname "$path")" 2>/dev/null || true
  install -o "$user" -g "$user" -m "$mode" "$content" "$path"
}

cmd_agent_switch() {
  require_root "agent switch"
  local name="" to="" account="" account_set=0 handoff_wait=90 handoff=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to=*)           to="${1#--to=}" ;;
      --account=*)      account="${1#--account=}"; account_set=1 ;;
      --handoff-wait=*) handoff_wait="${1#--handoff-wait=}" ;;
      --no-handoff)     handoff=0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" && -n "$to" ]] \
    || fail "$E_USAGE" "usage: 5dive agent switch <name> --to=claude|codex [--account=<account|default>] [--no-handoff] [--handoff-wait=<seconds>]"
  [[ "$handoff_wait" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "--handoff-wait must be a number of seconds"
  [[ "$to" == claude || "$to" == codex ]] \
    || fail "$E_VALIDATION" "--to must be claude or codex (got '$to')"
  ensure_state
  local reg from channels workdir prev_profile isolation
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  from=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels // "none"' <<<"$reg")
  workdir=$(jq -r --arg n "$name" '.agents[$n].workdir // empty' <<<"$reg")
  prev_profile=$(jq -r --arg n "$name" '.agents[$n].authProfile // ""' <<<"$reg")
  isolation=$(jq -r --arg n "$name" '.agents[$n].isolation // "standard"' <<<"$reg")
  [[ "$from" == claude || "$from" == codex ]] \
    || fail "$E_VALIDATION" "agent '$name' is type $from — switch moves between claude and codex only"
  [[ "$from" != "$to" ]] || fail "$E_VALIDATION" "agent '$name' already runs $(_switch_label "$to")"

  # ---- pre-flight: every refusal below changes nothing ----
  local ch
  for ch in ${channels//,/ }; do
    case "$ch" in
      none|telegram|dashboard) ;;
      *) [[ "$to" == codex ]] && fail "$E_VALIDATION" \
           "agent '$name' uses the $ch channel, which Codex does not have — remove it first (5dive agent config $name set channels=…)" ;;
    esac
  done
  (( account_set )) || account="$prev_profile"
  [[ "$account" == default ]] && account=""
  if [[ -n "$account" ]]; then
    valid_profile_name "$account" || fail "$E_VALIDATION" "invalid account name '$account'"
    [[ -f "${AUTH_PROFILES_DIR}/${account}/combined.env" ]] \
      || fail "$E_NOT_FOUND" "account '$account' is not configured"
  fi
  local serves
  serves=$(switch_account_harness "$account")
  if [[ "$serves" != "$to" && "$serves" != both ]]; then
    if (( account_set )); then
      fail "$E_VALIDATION" "account '${account:-default}' has no $(_switch_label "$to") sign-in — sign in first (5dive agent auth start $to --auth-profile=<account>), then pass it with --account="
    fi
    fail "$E_VALIDATION" "agent '$name' is on account '${account:-default}', which has no $(_switch_label "$to") sign-in — pass --account=<an account signed in to $(_switch_label "$to")>"
  fi
  local home user token=""
  home=$(_switch_home "$name"); user="agent-${name}"
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"
  if channel_in_list telegram "$channels"; then
    token=$(_switch_tg_token "$home" "$from")
    [[ -n "$token" ]] || token=$(_switch_tg_token "$home" "$to")
    [[ -n "$token" ]] || fail "$E_VALIDATION" "agent '$name' has channels=telegram but no bot token on disk — reconnect the bot first"
    if [[ "$to" == codex ]]; then
      codex_plugin_dir >/dev/null \
        || fail "$E_NOT_INSTALLED" "the Codex Telegram bridge (telegram-codex) is not deployed on this box"
    fi
  fi
  if [[ ! -x "${TYPE_BIN[$to]}" ]]; then
    [[ -n "${TYPE_INSTALL[$to]:-}" ]] \
      || fail "$E_NOT_INSTALLED" "$to is not installed and has no installer"
    step "$to not installed — installing now"
    cmd_install "$to" >&2
  fi

  local warning
  warning=$(switch_harness_warning "$name" "$from" "$to")
  step "$warning"

  # ---- 1. handoff: ask the running seat for a note, then stop it ----
  local unit="5dive-agent@${name}.service" hf="$home/$SWITCH_HANDOFF_FILE" t0 waited=0 handoff_state=skipped
  t0=$(date +%s)
  if (( handoff )) && systemctl is-active --quiet "$unit" 2>/dev/null; then
    step "Asking $name for a handoff note (up to ${handoff_wait}s)"
    if "${FIVEDIVE_SELF:-$(command -v 5dive || echo /usr/local/bin/5dive)}" agent send "$name" \
        "[5dive] You are being switched from $(_switch_label "$from") to $(_switch_label "$to") in a moment. Write a short handoff to ~/${SWITCH_HANDOFF_FILE} now (overwrite it): what you were doing, open threads, the next step. Nothing else." >/dev/null 2>&1; then
      handoff_state=timeout
      while (( waited < handoff_wait )); do
        if [[ -f "$hf" ]] && (( $(stat -c %Y "$hf" 2>/dev/null || echo 0) >= t0 )); then
          handoff_state=written; break
        fi
        sleep 3; waited=$((waited + 3))
      done
    else
      handoff_state=unreachable
    fi
  fi
  {
    printf '\n## Harness switch %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '- From %s to %s, account %s.\n' "$(_switch_label "$from")" "$(_switch_label "$to")" "${account:-default}"
    [[ "$handoff_state" == written ]] || printf -- '- No handoff note was written by the previous session (%s).\n' "$handoff_state"
  } | sudo -u "$user" tee -a "$hf" >/dev/null 2>&1 || true
  step "Stopping $unit"
  systemctl stop "$unit" >&2 2>/dev/null || true

  # Everything from here mutates the seat, under the registry lock. The handoff
  # wait above is deliberately OUTSIDE it: up to --handoff-wait seconds of a
  # held lock would stall every other registry writer on the box.
  with_registry_lock _agent_switch_apply
}

# The mutating half of cmd_agent_switch. Reads the caller's locals (bash scope is
# dynamic) — it is never called on its own.
_agent_switch_apply() {
  local _now
  _now=$(registry_read | jq -r --arg n "$name" '.agents[$n].type // ""')
  [[ "$_now" == "$from" ]] \
    || fail "$E_CONFLICT" "agent '$name' changed type while the handoff ran (now '$_now') — nothing switched; the unit is stopped, start it with: 5dive agent start $name"

  # ---- 2-4. side files for the target harness ----
  local carry_from carry_to memidx="" tmpdoc mem_json='{}'
  carry_from="$home/${TYPE_PERSONA_FILE[$from]}"
  carry_to="$home/${TYPE_PERSONA_FILE[$to]}"
  local -a frags=()
  if [[ "$from" == claude ]]; then
    frags=("$TELEGRAM_AGENT_CLAUDE_MD" "$MODEL_TIERING_CLAUDE_MD" "$OPERATIONAL_COMMS_CLAUDE_MD")
  fi

  if [[ "$to" == claude ]]; then
    if [[ ! -f "$home/.claude/settings.json" ]]; then
      local _m
      _m=$(claude_create_start_model "" "" "" "$account")
      model_latest "$_m" >/dev/null 2>&1 && _m=$(resolve_model_for_profile "$_m" "$account")
      step "Preseeding Claude Code for $user (first time on this harness)"
      preseed_claude_agent "$name" "$channels" "$_m" high
    fi
  fi

  # Channels on the target bridge, same token, merged allowlist.
  local allow_n=0 tg_note=""
  if channel_in_list telegram "$channels"; then
    local sa="$home/.$from/channels/telegram/access.json" da="$home/.$to/channels/telegram/access.json"
    local allow_csv
    allow_csv=$(jq -r '(.allowFrom // []) | join(",")' "$sa" 2>/dev/null || true)
    if [[ "$to" == claude && -d "$home/.claude/plugins/cache/5dive-plugins/telegram" ]]; then
      # Kept from the last time this seat ran Claude: refresh the token line
      # only, so the claude side's settings.json and CLAUDE.md stay as they were.
      set_claude_telegram_env_key "$name" TELEGRAM_BOT_TOKEN "$token"
    else
      install_channel_for_agent "$to" telegram "$name" "$token" "" "$allow_csv"
    fi
    allow_n=$(switch_merge_access "$sa" "$da")
    chown "$user:$user" "$da" 2>/dev/null || true
    if [[ "$to" == codex ]] && grep -q '^TELEGRAM_PROFILE=lite' "$home/.claude/channels/telegram/.env" 2>/dev/null; then
      tg_note="telegram lite profile (Codex's bridge has no lite mode)"
    fi
  fi
  if channel_in_list dashboard "$channels"; then
    if [[ "$to" == codex || ! -d "$home/.claude/plugins/cache/5dive-plugins/dashboard" ]]; then
      install_channel_for_agent "$to" dashboard "$name" ""
    fi
  fi
  if [[ "$to" == codex ]]; then
    preseed_codex_return_channel "$name" >/dev/null \
      || warn "could not reconcile the Codex operating baseline for $user"
  fi
  if declare -F plugin_seat_backfill >/dev/null 2>&1; then
    plugin_seat_backfill "$name" "$to" || true
  fi
  if [[ "$to" == claude ]] && declare -F mod_seat_enabled >/dev/null 2>&1 && mod_seat_enabled; then
    mod_seat_ensure "$name" || warn "the mod guard was NOT seated on $user"
  fi

  # Memory.
  if [[ "$to" == codex ]]; then
    memidx=$(mktemp)
    _switch_claude_index_text "$name" "$memidx"
    local atoms
    atoms=$({ find "$home"/.claude/projects/*/memory -maxdepth 1 -name '*.md' ! -name MEMORY.md 2>/dev/null || true; } | wc -l)
    mem_json=$(jq -cn --argjson n "$atoms" '{direction:"claude->codex", atoms:$n, store:"5dive (memory search)", indexCarried:true}')
  else
    local mdir counts _a _u _r _s
    mdir=$(switch_claude_memdir "$name" "$workdir")
    counts=$(switch_codex_memory_to_atoms "$home/.codex/memories" "$mdir")
    chown -R "$user:$user" "$home/.claude/projects" 2>/dev/null || true
    read -r _a _u _r _s <<<"$counts"
    mem_json=$(jq -cn --arg d "$mdir" --argjson a "${_a:-0}" --argjson u "${_u:-0}" --argjson r "${_r:-0}" --argjson s "${_s:-0}" \
      '{direction:"codex->claude", memdir:$d, added:$a, updated:$u, removed:$r, unchanged:$s}')
  fi

  # Instructions, AFTER the channel install (claude's installer writes CLAUDE.md).
  tmpdoc=$(mktemp)
  switch_carry_doc "$carry_from" "$carry_to" "$from" "$to" "$memidx" ${frags[@]+"${frags[@]}"} >"$tmpdoc"
  _switch_install_file "$user" "$tmpdoc" "$carry_to" 644 \
    || warn "could not write $carry_to"
  rm -f "$tmpdoc" ${memidx:+"$memidx"}

  # ---- 5. registry, env, account ----
  reg=$(registry_read)
  reg=$(jq --arg n "$name" --arg t "$to" --arg f "$from" --arg p "$account" --arg ts "$(date -Iseconds)" '
      .agents[$n].type = $t
    | (if $p == "" then del(.agents[$n].authProfile) else .agents[$n].authProfile = $p end)
    | .agents[$n].harnessSwitch = {from: $f, to: $t, at: $ts}' <<<"$reg")
  echo "$reg" | registry_write
  if [[ "$account" != "$prev_profile" ]] && declare -F account_binding_record >/dev/null 2>&1; then
    account_binding_record "$name" "$account" "harness-switch" || true
  fi
  write_agent_env "$name" "$to" "$channels" "$workdir" "$account" "$isolation"
  link_agent_profile "$name" "$account"

  # ---- 7. start and check ----
  step "Starting $unit on $(_switch_label "$to")"
  systemctl start "$unit" >&2 2>/dev/null || true
  local up=false i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    systemctl is-active --quiet "$unit" 2>/dev/null && { up=true; break; }
    sleep 2
  done

  local dropped_json
  dropped_json=$( { _switch_dropped_skills "$name" "$from" "$to"; if [[ -n "$tg_note" ]]; then printf '%s\n' "$tg_note"; fi; } \
    | jq -R . | jq -cs 'map(select(length > 0))')
  ok "agent '$name' switched from $(_switch_label "$from") to $(_switch_label "$to") (account ${account:-default}); unit active: $up" \
     '{name:$n, from:$f, to:$t, account:$a, warning:$w, handoff:$h, memory:$m, telegram:{tokenKept:($tk == 1), allowFrom:$al}, dropped:$d, running:$up}' \
     --arg n "$name" --arg f "$from" --arg t "$to" --arg a "${account:-default}" --arg w "$warning" \
     --arg h "$handoff_state" --argjson m "$mem_json" --argjson tk "$([[ -n "$token" ]] && echo 1 || echo 0)" \
     --argjson al "${allow_n:-0}" --argjson d "$dropped_json" --argjson up "$up"
}

# `agent config <n> set auth-profile=<p> --switch-harness` and
# `agent set-account <n> <p> --switch-harness`: the confirmed form of an account
# move. Crossing Claude <-> Codex runs `agent switch`; the same harness binds as
# it always did, so a surface can pass the flag after its confirm without first
# working out which case it is in.
agent_account_move_switch() { # config|set-account <args...>
  require_root
  local form="$1"; shift
  local -a rest=() ; local a name="" acct=""
  for a in "$@"; do [[ "$a" == --switch-harness ]] || rest+=("$a"); done
  if [[ "$form" == config ]]; then
    (( ${#rest[@]} == 3 )) && [[ "${rest[1]}" == set ]] \
      && [[ "${rest[2]}" == auth-profile=* || "${rest[2]}" == auth.profile=* ]] \
      || fail "$E_USAGE" "--switch-harness goes with exactly one key: 5dive agent config <name> set auth-profile=<account> --switch-harness"
    name="${rest[0]}"; acct="${rest[2]#*=}"
  else
    (( ${#rest[@]} == 2 )) || fail "$E_USAGE" "usage: 5dive agent set-account <agent> <account|default> [--switch-harness]"
    name="${rest[0]}"; acct="${rest[1]}"
  fi
  local type target
  type=$(registry_read | jq -r --arg n "$name" '.agents[$n].type // ""')
  [[ -n "$type" ]] || fail "$E_NOT_FOUND" "no agent named '$name'"
  target=$(switch_target_for_account "$type" "$acct")
  if [[ -n "$target" ]]; then
    cmd_agent_switch "$name" --to="$target" --account="${acct:-default}"
  else
    with_registry_lock cmd_config "$name" set "auth-profile=${acct}"
  fi
}
