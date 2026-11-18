# DIVE-5501: `agent switch <name> --to=claude|codex|grok` — move ONE agent between
# Claude Code, Codex and Grok IN PLACE (Grok since DIVE-7414).
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
#
# DIVE-7414: Grok both ways. A Grok agent could never move: a new login is the
# default for new hires (DIVE-7152), so an agent hired on a Grok login was on
# Grok for good. Grok reads ~/.claude/CLAUDE.md (TYPE_PERSONA_FILE) and its
# memory is the 5dive store, so Claude <-> Grok shares both files: nothing is
# copied, the carried block only points at the handoff (and, to Grok, which
# loads no MEMORY.md, the memory index). Grok is on by default (DIVE-7802); to
# Grok is refused only after the owner's `5dive grok disable`, like create.
#
# DIVE-8672: Hermes and OpenClaw -> Claude Code, one way (switching back is a
# later row). Same verb, same seven steps; per source harness a small converter
# reads the bot token and allowlist, the instructions (SOUL.md / workspace
# AGENTS.md+SOUL.md+IDENTITY.md, minus the harness's own template text), the
# memory (into atoms + an index block, like codex) and the skills, and stops the
# harness's own Telegram poller first (one token polled twice = Telegram 409).
# The move is onto the owner's Claude plan: pre-flight refuses without a Claude
# sign-in, and the result says the harness's own scheduled jobs did not move.

SWITCH_CARRY_MARKER="5dive:carried-instructions"
SWITCH_CODEX_MEM_MARKER="5dive:codex-memory"
SWITCH_HANDOFF_FILE=".5dive-handoff.md"
# The harnesses this verb moves between, in the order an account that serves
# several of them is read (claude first: it is the one every box can run).
SWITCH_TYPES=(claude codex grok)
# Carried memory index budget: AGENTS.md is loaded every turn, so the index is
# cut at a byte budget and the rest is reached by search (DIVE-3821's lesson).
SWITCH_INDEX_BUDGET="${FIVEDIVE_SWITCH_INDEX_BUDGET:-8000}"
# The carried instructions are cut too when the target is codex: codex reads at
# most 32 KiB of AGENTS.md and drops the rest without a word (DIVE-4923), so
# 15000 bytes of instructions + the 8000-byte index + the block's own lines stay
# under 24 KB, which leaves the target's own baseline room inside it. BYTES, not
# characters: the limit is in bytes, and Cyrillic is two of them per character.
SWITCH_INSTR_BUDGET="${FIVEDIVE_SWITCH_INSTR_BUDGET:-15000}"

_switch_home() { printf '%s/agent-%s\n' "${SWITCH_HOME_ROOT:-/home}" "$1"; }

_switch_label() {
  case "$1" in
    claude) printf 'Claude Code' ;; codex) printf 'Codex' ;; grok) printf 'Grok' ;;
    hermes) printf 'Hermes' ;; openclaw) printf 'OpenClaw' ;; *) printf '%s' "$1" ;;
  esac
}

_switch_is_type() { [[ " ${SWITCH_TYPES[*]} " == *" ${1:-} "* ]]; }

# DIVE-8672: harnesses an agent can move OFF, one way, onto Claude Code (and so
# onto the owner's Claude plan). Never a target: switching back is a later row.
SWITCH_SOURCES=(hermes openclaw)
_switch_is_source() { [[ " ${SWITCH_SOURCES[*]} " == *" ${1:-} "* ]]; }

# DIVE-8371: is this switch running INSIDE the seat it switches? An agent that
# runs `sudo 5dive agent switch <itself>` lives in 5dive-agent@<itself>.service,
# so step 1's `systemctl stop` of that unit SIGTERMs the switch with it: the unit
# stops, nothing is converted, nothing restarts it (a partner box: the seat stayed dead
# 20 h). setsid/nohup do not leave the cgroup (wiki: setsid-does-not-leave-the-
# cgroup); only a transient service does. Either signal is enough: the process's
# cgroup sits under that unit, or sudo was called by that seat's own user.
_switch_inside_own_unit() { # <name>
  local name="$1" cg="${SWITCH_SELF_CGROUP_FILE:-/proc/self/cgroup}"
  [[ "${SUDO_USER:-}" == "agent-${name}" ]] && return 0
  [[ -r "$cg" ]] || return 1
  grep -qE "/5dive-agent@${name//./\\.}\\.service(/|\$)" "$cg"
}

# On unless the owner ran `5dive grok disable` (cmd_grok.sh): the marker create reads.
_switch_grok_on() { [[ ! -e "${FIVE_GROK_OFF_MARKER:-/etc/5dive/arm/grok-off}" ]]; }

# The plain sentence every surface shows before a switch. One string, so the
# CLI refusal, the Mini App and the dashboard cannot drift apart.
switch_harness_warning() { # <name> <from> <to> [kept-provider]
  local plan
  case "$3" in codex) plan="ChatGPT" ;; grok) plan="Grok" ;; *) plan="Claude" ;; esac
  # DIVE-8675: --keep-model is not a plan, it is the seat's own key.
  local onto="your $plan plan"
  [[ -n "${4:-}" ]] && onto="$(_switch_label "$3") on its own ${BYO_PROVIDER_LABEL[$4]:-$4} model"
  # DIVE-8672: off Hermes/OpenClaw is one way for now, so it never promises a way back.
  local back='You can switch back any time.'
  _switch_is_source "$2" && back="Its own scheduled jobs do not move, and there is no switching back to $(_switch_label "$2") yet."
  printf 'Moving %s to %s switches it from %s to %s. Its memory and instructions are converted; this chat'"'"'s history is not. %s' \
    "$1" "$onto" "$(_switch_label "$2")" "$(_switch_label "$3")" "$back"
}

# The harnesses an account signs in for, among those this verb moves between,
# one per line in SWITCH_TYPES order. "" = the box default credentials.
switch_account_types() { # <profile>
  local p="${1:-}" t path
  local -a got=()
  if [[ -z "$p" || "$p" == default ]]; then
    for t in "${SWITCH_TYPES[@]}"; do
      path=$(profile_type_auth_path "" "$t" 2>/dev/null) || path=""
      [[ -n "$path" && -s "$path" ]] && got+=("$t")
    done
  else
    account_types_authed_arr "$p"
    got=(${ACCOUNT_TYPES_AUTHED[@]+"${ACCOUNT_TYPES_AUTHED[@]}"})
  fi
  for t in "${SWITCH_TYPES[@]}"; do
    [[ " ${got[*]-} " == *" $t "* ]] && printf '%s\n' "$t"
  done
  return 0
}

# Does <profile> hold a sign-in for <type>?
switch_account_serves() { # <profile> <type>
  switch_account_types "$1" | grep -qx -- "$2"
}

# The Claude/Codex half of switch_account_types, as compose reads it: claude,
# codex, both, or nothing.
switch_account_harness() { # <profile>
  local h c=0 x=0
  h=$(switch_account_types "${1:-}")
  grep -qx claude <<<"$h" && c=1
  grep -qx codex <<<"$h" && x=1
  if (( c && x )); then printf 'both\n'
  elif (( c )); then printf 'claude\n'
  elif (( x )); then printf 'codex\n'
  fi
}

# Is moving a <type> seat to <profile> a harness switch? Prints the target type
# when the account does not serve this harness and does serve another (the first
# in SWITCH_TYPES order); nothing otherwise (same harness, or an account with no
# sign-in yet — those bind as before).
switch_target_for_account() { # <type> <profile>
  local type="$1" h
  _switch_is_type "$type" || return 0
  h=$(switch_account_types "$2")
  grep -qx -- "$type" <<<"$h" && return 0
  [[ -n "$h" ]] && printf '%s\n' "$(head -1 <<<"$h")"
  return 0
}

# The standing instructions a carried block in <file> holds (from an earlier
# Codex trip), so a Claude <-> Grok switch, which rewrites the block in the same
# file, keeps them instead of dropping them with the old block.
_switch_block_instructions() { # <file>
  [[ -f "$1" ]] || return 0
  awk -v id="$SWITCH_CARRY_MARKER" '
    index($0, "<!-- " id ":begin") { inb = 1; next }
    inb && index($0, "<!-- " id ":end") { inb = 0; on = 0; next }
    inb && $0 == "## Standing instructions" { on = 1; next }
    inb && on && $0 == "## Memory" { on = 0 }
    on { print }' "$1"
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
      | _switch_strip_block 5dive:team \
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
    if [[ "$to" == codex ]] && (( $(printf '%s' "$body" | LC_ALL=C wc -c) > SWITCH_INSTR_BUDGET )); then
      # Slice the bytes, then back off to the last whole line (never half a
      # multibyte character).
      body=$(printf '%s' "$body" | LC_ALL=C head -c "$SWITCH_INSTR_BUDGET" | python3 -c '
import sys
t = sys.stdin.buffer.read().decode("utf-8", "ignore")
if "\n" in t:
    t = t[: t.rfind("\n")]
sys.stdout.write(t)')
      body+=$'\n\n'"(cut at ${SWITCH_INSTR_BUDGET} bytes for Codex's 32 KiB limit; the full text is in ~/.claude/CLAUDE.md)"
    fi
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
# Runs as root inside a directory the seat owns: every write refuses a symlinked
# target, and (given <home>) a symlinked directory between <home> and it, so an
# agent cannot aim the conversion at a root file.
switch_codex_memory_to_atoms() { # <codex-memories-dir> <memdir> [user] [home]
  local src="$1" mdir="$2" user="${3:-}" home="${4:-}" stage insrc f nm base a=0 u=0 r=0 s=0
  _switch_no_symlink "$mdir" "$home" || return 1
  _switch_no_symlink "$src" "$home" || return 1
  stage=$(mktemp -d) || return 1
  if [[ -d "$src" ]]; then
    # Read through a private copy of the regular files only, so root never
    # reads a linked file into atoms the seat then owns.
    insrc="$stage/.src"; mkdir -p "$insrc"
    for nm in MEMORY.md memory_summary.md raw_memories.md; do
      [[ -f "$src/$nm" && ! -L "$src/$nm" ]] && cp "$src/$nm" "$insrc/$nm"
    done
    _pack_codex_to_atoms "$insrc" "$stage" all >/dev/null || true
  fi
  mkdir -p "$mdir"
  for f in "$stage"/codex-*.md; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    if [[ -L "$mdir/$base" ]]; then warn "refusing to write through a symlink: $mdir/$base"
    elif [[ ! -f "$mdir/$base" ]]; then _switch_install_file "$user" "$f" "$mdir/$base" 644 "$home" && a=$((a + 1))
    elif ! cmp -s "$f" "$mdir/$base"; then _switch_install_file "$user" "$f" "$mdir/$base" 644 "$home" && u=$((u + 1))
    else s=$((s + 1)); fi
  done
  for f in "$mdir"/codex-tg-*.md "$mdir"/codex-profile-*.md "$mdir"/codex-thread-*.md; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    [[ -f "$stage/$(basename "$f")" ]] || { rm -f "$f"; r=$((r + 1)); }
  done
  rm -rf "$stage"
  _switch_index_codex_atoms "$mdir" "$user" "$home"
  printf '%s %s %s %s\n' "$a" "$u" "$r" "$s"
}

# Keep MEMORY.md's codex block in step with the codex-* atoms (budgeted; the
# seat's own index outside the block is untouched).
_switch_index_codex_atoms() { # <memdir> [user] [home]
  _switch_index_prefixed_atoms "$1" "$SWITCH_CODEX_MEM_MARKER" Codex codex "${2:-}" "${3:-}" \
    codex-tg- codex-profile- codex-thread-
}

# One harness's converted atoms (named <prefix>*) indexed in their own marker
# block of MEMORY.md; DIVE-8672 shares it between codex, hermes and openclaw.
_switch_index_prefixed_atoms() { # <memdir> <marker> <label> <short> <user> <home> <prefix...>
  local mdir="$1" marker="$2" label="$3" short="$4" user="$5" home="$6" idx="$1/MEMORY.md"
  local tmp lines="" f nm d n=0 more=0 pfx
  shift 6
  # Checked before the READ too: root must not copy a linked file into the seat.
  _switch_no_symlink "$idx" "$home" || return 0
  for pfx in "$@"; do
    for f in "$mdir/$pfx"*.md; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      n=$((n + 1))
      nm=$(basename "$f" .md)
      d=$(sed -n 's/^description: *"\{0,1\}\(.*\)"\{0,1\}$/\1/p' "$f" | head -1 | sed 's/"$//')
      if (( ${#lines} < 4000 )); then lines+="- [${nm}](${nm}.md) — ${d}"$'\n'; else more=$((more + 1)); fi
    done
  done
  tmp=$(mktemp) || return 1
  if [[ -f "$idx" ]]; then _switch_strip_block "$marker" <"$idx" >"$tmp"
  else printf '# Memory Index\n' >"$tmp"; fi
  if (( n > 0 )); then
    {
      printf '\n<!-- %s:begin -->\n## Converted from %s memory (%s atoms)\n\n' "$marker" "$label" "$n"
      printf '%s' "$lines"
      (( more > 0 )) && printf -- '- …and %s more %s-* atoms: `5dive memory search`\n' "$more" "$short"
      printf '<!-- %s:end -->\n' "$marker"
    } >>"$tmp"
  fi
  _switch_install_file "$user" "$tmp" "$idx" 644 "$home"; rm -f "$tmp"
}

# All claude memory index text of a seat, for carrying into AGENTS.md (or, to
# Grok, the carried block of CLAUDE.md). The codex block is left out going to
# Codex, which has those facts in its own store; Grok has no other copy of them.
_switch_claude_index_text() { # <name> <out-file> [to]
  local home d
  home=$(_switch_home "$1")
  : >"$2"
  for d in "$home"/.claude/projects/*/memory; do
    [[ -f "$d/MEMORY.md" ]] || continue
    _switch_no_symlink "$d/MEMORY.md" "$home" || continue
    if [[ "${3:-codex}" == codex ]]; then
      _switch_strip_block "$SWITCH_CODEX_MEM_MARKER" <"$d/MEMORY.md" >>"$2"
    else
      cat "$d/MEMORY.md" >>"$2"
    fi
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

# DIVE-8667: a skill 5dive itself installs PER HARNESS — the default skills
# (installed per type by install_default_skill_for_agent, backfilled nightly by
# 5dive-refresh-skills.sh) and notify-user (each channel plugin ships its own).
# Copying the <from> side's body across would plant one harness's version on the
# other, so these are never copied; the target gets its own the usual way.
_switch_harness_owned_skill() { # <skill>
  [[ "$1" == notify-user ]] && return 0
  skill_default_source "$1" >/dev/null 2>&1
}

# Carry the seat's skills to the target harness: every skill folder on <from>
# that <to> lacks is copied into <to>'s skills dir (DIVE-8667; DIVE-5501 only
# listed them). The <from> copy stays, so a switch back reuses it. Prints one
# line per skill that was missing on <to>: "copied <skill>" or "dropped <skill>",
# and, for a harness that ships its own set (Hermes), one "builtin <count>".
#   - a harness-owned skill (above) is dropped, not copied;
#   - the copy runs AS THE SEAT, so it can only read what the seat could already
#     read and only write where the seat could already write (a link inside the
#     skill is followed with the seat's rights, never root's);
#   - something that is not a folder already at the target name is left alone.
_switch_carry_skills() { # <name> <from> <to>
  local home user a b s sd src builtin=0
  home=$(_switch_home "$1"); user="agent-$1"
  b="$home/$(skills_install_dir "$3")"
  while IFS= read -r sd; do
    [[ -n "$sd" && -d "$sd" ]] || continue
    a=$(dirname "$sd"); s=$(basename "$sd")
    [[ "$a" != "$b" ]] || continue
    [[ -d "$b/$s" ]] && continue
    if _switch_source_builtin_skill "$home" "$2" "$s"; then builtin=$((builtin + 1)); continue; fi
    if [[ -e "$b/$s" || -L "$b/$s" ]] || _switch_harness_owned_skill "$s" \
       || ! valid_skill_id "$s" || [[ ! -f "$sd/SKILL.md" ]]; then
      printf 'dropped %s\n' "$s"; continue
    fi
    if agent_owned_dir "$user" "$home" "$b" \
       && sudo -u "$user" cp -RL -- "$sd" "$b/$s" >/dev/null 2>&1; then
      src=$(jq -r --arg k "$s" '.[$k].source // empty' "$a/.skills-manifest.json" 2>/dev/null || true)
      [[ -z "$src" ]] || _skill_manifest_note "$user" "$home" "$(skills_install_dir "$3")" "$s" "$src"
      printf 'copied %s\n' "$s"
    else
      # Nothing was at $b/$s before the copy, so whatever is there now is ours.
      sudo -u "$user" rm -rf -- "$b/$s" >/dev/null 2>&1 || true
      printf 'dropped %s\n' "$s"
    fi
  done < <(_switch_skill_dirs "$home" "$2")
  (( builtin == 0 )) || printf 'builtin %s\n' "$builtin"
  return 0
}

_switch_tg_token() { # <home> <type>
  { sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$1/.$2/channels/telegram/.env" 2>/dev/null || true; } | head -1
}

# Refuse <path> when it, or any directory between <base> and it, is a symlink.
# The switch runs as root and everything under the seat's home is the seat's to
# plant, so following a link there writes (or reads) a root file for the agent.
# Without <base> only <path> itself is checked.
_switch_no_symlink() { # <path> [base]
  local p="$1" base="${2:-}" cur rest
  [[ ! -L "$p" ]] || { warn "refusing to follow a symlink: $p"; return 1; }
  [[ -n "$base" ]] || return 0
  case "$p" in "$base"/*) ;; *) warn "refusing a path outside $base: $p"; return 1 ;; esac
  cur="$base"; rest="${p#"$base"/}"
  while [[ "$rest" == */* ]]; do
    cur+="/${rest%%/*}"; rest="${rest#*/}"
    [[ ! -L "$cur" ]] || { warn "refusing to follow a symlink: $cur"; return 1; }
  done
}

# Write <content-file> to <path> owned by the seat, refusing a symlinked target
# or (given <base>, default the seat's home) a symlinked directory above it.
# install(1) unlinks the target before it writes, so a link planted after the
# check is replaced, not followed.
_switch_install_file() { # <user> <content-file> <path> [mode] [base]
  local user="$1" content="$2" path="$3" mode="${4:-644}" base="${5-}"
  local -a own=()
  [[ -n "$user" ]] && own=(-o "$user" -g "$user")
  [[ $# -ge 5 || -z "$user" ]] || base=$(_switch_home "${user#agent-}")
  _switch_no_symlink "$path" "$base" || return 1
  install -d ${own[@]+"${own[@]}"} -m 700 "$(dirname "$path")" 2>/dev/null || true
  install ${own[@]+"${own[@]}"} -m "$mode" "$content" "$path"
}

# ======================================================================
# DIVE-8672: Hermes / OpenClaw -> Claude Code, in place.
#
# Where each harness keeps what moves, read from its own code (Hermes at the
# pinned install, hermes_cli/ + tools/memory_tool.py; OpenClaw 2026.11.5's
# docs/channels/telegram.md, docs/concepts/memory.md, docs/tools/skills.md) and
# from 5dive's own writers (install_channel_for_{hermes,openclaw}_agent):
#   bot token     hermes   ~/.hermes/.env TELEGRAM_BOT_TOKEN
#                 openclaw ~/.openclaw/openclaw.json channels.telegram.botToken
#                          or .tokenFile (5dive writes ~/.openclaw/secrets/
#                          telegram-bot-token), the same under accounts.default,
#                          else TELEGRAM_BOT_TOKEN in ~/.openclaw/.env
#   allowlist     hermes   TELEGRAM_ALLOWED_USERS in ~/.hermes/.env
#                 openclaw channels.telegram.allowFrom
#   instructions  hermes   ~/.hermes/SOUL.md
#                 openclaw workspace AGENTS.md + SOUL.md + IDENTITY.md
#   memory        hermes   ~/.hermes/memories/{MEMORY,USER}.md, entries split by
#                          a line holding only "§"
#                 openclaw workspace MEMORY.md, USER.md, memory/**/*.md
#   skills        hermes   ~/.hermes/skills/[<category>/]<skill>/SKILL.md; its
#                          own bundled ones are listed in skills/.bundled_manifest
#                 openclaw workspace skills/, ~/.openclaw/skills/
#   gateway       hermes   its own systemd --user unit (`hermes gateway install`)
#                 openclaw `openclaw gateway run` inside the 5dive unit, or its
#                          own user unit when the owner installed one
# Nothing here is written back to the source side: switching back reuses it.
# ======================================================================

_switch_hermes_dir() { printf '%s\n' "${HERMES_AGENT_DIR:-/home/claude/.hermes/hermes-agent}"; }

# The OpenClaw package dir (holds docs/reference/templates), from its launcher.
_switch_openclaw_pkg() {
  local b
  b=$(readlink -f "${TYPE_BIN[openclaw]:-/home/claude/.local/bin/openclaw}" 2>/dev/null) || return 1
  [[ -n "$b" && -f "$b" ]] || return 1
  printf '%s\n' "$(dirname "$b")"
}

# Read one regular file under the seat's home as root, or nothing: a symlink at
# it or above it is refused (the seat plants everything under its home).
_switch_read_seat_file() { # <home> <path>
  [[ -f "$2" ]] || return 0
  _switch_no_symlink "$2" "$1" 2>/dev/null || return 0
  cat -- "$2" 2>/dev/null || true
}

_switch_env_value() { # <home> <env-file> <KEY> -> the last value, quotes stripped
  _switch_read_seat_file "$1" "$2" | sed -n "s/^$3=//p" | tail -1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# openclaw.json is JSON5 when a person edited it; what 5dive's `config set` and
# `channels add` write is plain JSON. Comments and trailing commas are dropped
# before parsing; anything still unparsable reads as {}.
_switch_openclaw_conf() { # <home>
  _switch_read_seat_file "$1" "$1/.openclaw/openclaw.json" | python3 -c '
import json, re, sys
t = sys.stdin.read()
try:
    print(json.dumps(json.loads(t)))
except Exception:
    t = re.sub(r"(?m)^\s*//.*$", "", t)
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    t = re.sub(r",(\s*[}\]])", r"\1", t)
    try:
        print(json.dumps(json.loads(t)))
    except Exception:
        print("{}")'
}

_switch_source_tg_token() { # <home> <type>
  local home="$1" tok="" conf f
  case "$2" in
    hermes) tok=$(_switch_env_value "$home" "$home/.hermes/.env" TELEGRAM_BOT_TOKEN) ;;
    openclaw)
      conf=$(_switch_openclaw_conf "$home")
      tok=$(jq -r '[.channels.telegram.botToken, .channels.telegram.accounts.default.botToken]
                   | map(select(type == "string" and length > 0)) | first // empty' <<<"$conf" 2>/dev/null)
      if [[ -z "$tok" ]]; then
        local tfiles
        tfiles=$(jq -r '.channels.telegram.tokenFile, .channels.telegram.accounts.default.tokenFile
                        | select(type == "string" and length > 0)' <<<"$conf" 2>/dev/null)
        while IFS= read -r f; do
          [[ -n "$f" ]] || continue
          f="${f/#\~/$home}"
          [[ "$f" == /* ]] || f="$home/.openclaw/$f"
          tok=$(_switch_read_seat_file "$home" "$f" | head -1 | tr -d '[:space:]')
          [[ -n "$tok" ]] && break
        done <<<"$tfiles"
      fi
      [[ -n "$tok" ]] || tok=$(_switch_env_value "$home" "$home/.openclaw/.env" TELEGRAM_BOT_TOKEN) ;;
  esac
  printf '%s\n' "$tok"
}

# The source side's Telegram allowlist as a CSV of numeric ids (what the claude
# installer takes). OpenClaw writes some entries as "telegram:<id>".
_switch_source_tg_allow() { # <home> <type>
  local home="$1" raw=""
  case "$2" in
    hermes) raw=$(_switch_env_value "$home" "$home/.hermes/.env" TELEGRAM_ALLOWED_USERS | tr ',' '\n') ;;
    openclaw) raw=$(_switch_openclaw_conf "$home" | jq -r '(.channels.telegram.allowFrom // [])[] | tostring' 2>/dev/null) ;;
  esac
  # DIVE-8675: `|| true` — no numeric id at all (a seat with no allowlist) is
  # an empty list, not a failure: under pipefail the grep's 1 ended the whole
  # switch silently, after the source gateway was already down.
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^\(telegram\|tg\)://' <<<"$raw" \
    | { grep -E '^-?[0-9]+$' || true; } | awk '!seen[$0]++' | paste -sd, -
}

# Scheduled jobs the source harness ran itself. They are NOT carried: the owner
# is told, with a count where the store is readable ("" = unknown).
_switch_source_job_count() { # <home> <type>
  local f
  case "$2" in
    hermes) f="$1/.hermes/cron/jobs.json" ;;
    openclaw) f="$1/.openclaw/cron/jobs.json" ;;
    *) return 0 ;;
  esac
  _switch_read_seat_file "$1" "$f" | jq -r 'if type == "array" then length elif (.jobs|type) == "array" then (.jobs|length) else empty end' 2>/dev/null || true
}

# Stop the source harness's own Telegram poller BEFORE the Claude bridge starts:
# the same token polled twice gets Telegram 409 and one side goes deaf. The 5dive
# unit is already stopped (that ends an OpenClaw gateway run inside it); this
# takes down the poller that lives in the seat's own user manager, disabled so
# linger does not bring it back at boot. Returns 1 when one still runs.
_switch_stop_source_gateway() { # <name> <type>
  local user="agent-$1" pat i
  case "$2" in
    hermes)
      sudo -u "$user" -H "${TYPE_BIN[hermes]}" gateway uninstall </dev/null >/dev/null 2>&1 || true
      systemctl --user -M "${user}@" disable --now hermes-gateway.service >/dev/null 2>&1 || true
      pat='hermes.*gateway' ;;
    openclaw)
      systemctl --user -M "${user}@" disable --now openclaw-gateway.service >/dev/null 2>&1 || true
      pat='openclaw.*gateway' ;;
    *) return 0 ;;
  esac
  pkill -u "$user" -f "$pat" >/dev/null 2>&1 || true
  for i in 1 2 3 4 5; do
    pgrep -u "$user" -f "$pat" >/dev/null 2>&1 || return 0
    sleep 1
  done
  pkill -KILL -u "$user" -f "$pat" >/dev/null 2>&1 || true
  sleep 1
  ! pgrep -u "$user" -f "$pat" >/dev/null 2>&1
}

# The harness's own boilerplate, written out as fragments that switch_carry_doc
# removes verbatim: Hermes's default SOUL.md (read off its source as a literal,
# never executed) and OpenClaw's workspace templates (front matter dropped, the
# way OpenClaw seeds them). Prints one file per line, made in <dir>.
_switch_source_frags() { # <type> <dir>
  local t="$1" d="$2" pkg f
  case "$t" in
    hermes)
      f="$(_switch_hermes_dir)/hermes_cli/default_soul.py"
      [[ -f "$f" ]] || return 0
      python3 - "$f" >"$d/frag-hermes-soul.md" 2>/dev/null <<'PY' || return 0
import ast, sys
for n in ast.walk(ast.parse(open(sys.argv[1]).read())):
    if isinstance(n, ast.Assign) and any(getattr(x, "id", "") == "DEFAULT_SOUL_MD" for x in n.targets):
        sys.stdout.write(ast.literal_eval(n.value)); break
PY
      [[ -s "$d/frag-hermes-soul.md" ]] && printf '%s\n' "$d/frag-hermes-soul.md" ;;
    openclaw)
      pkg=$(_switch_openclaw_pkg) || return 0
      for f in AGENTS SOUL IDENTITY USER; do
        [[ -f "$pkg/docs/reference/templates/$f.md" ]] || continue
        awk 'NR == 1 && /^---[[:space:]]*$/ { fm = 1; next } fm && /^---[[:space:]]*$/ { fm = 0; next } !fm' \
          "$pkg/docs/reference/templates/$f.md" >"$d/frag-openclaw-$f.md"
        printf '%s\n' "$d/frag-openclaw-$f.md"
      done ;;
  esac
}

# The source side's standing instructions as one document (OpenClaw splits them
# over three workspace files; Hermes keeps one).
_switch_source_instructions() { # <home> <type> <out>
  local home="$1" f first=1
  : >"$3"
  case "$2" in
    hermes) _switch_read_seat_file "$home" "$home/${TYPE_PERSONA_FILE[hermes]}" >"$3" ;;
    openclaw)
      for f in AGENTS.md SOUL.md IDENTITY.md; do
        [[ -f "$home/.openclaw/workspace/$f" ]] || continue
        (( first )) || printf '\n' >>"$3"
        _switch_read_seat_file "$home" "$home/.openclaw/workspace/$f" >>"$3"
        first=0
      done ;;
  esac
}

# Hermes / OpenClaw memory -> atoms in <memdir>, the way codex -> claude does it:
# only this harness's atoms are rewritten (and only when changed), ones no longer
# produced are removed, every other atom is kept, and MEMORY.md gets a budgeted
# index block. Prints "added updated removed unchanged".
#   hermes   every §-entry is one atom (USER.md entries typed user)
#   openclaw MEMORY.md is split at its "## " headings, USER.md is one user atom,
#            each memory/**/*.md note is one atom
# Atom names carry a content hash, so an edited entry replaces its old atom.
switch_harness_memory_to_atoms() { # <type> <home> <memdir> [user] [frag...]
  local t="$1" home="$2" mdir="$3" user="${4:-}" stage insrc f rel base a=0 u=0 r=0 s=0
  shift 4 2>/dev/null || shift $#
  _switch_no_symlink "$mdir" "$home" || return 1
  stage=$(mktemp -d) || return 1
  insrc="$stage/.src"; mkdir -p "$insrc"
  # A private copy of the regular files only: root never reads a link into
  # atoms the seat then owns.
  case "$t" in
    hermes)
      for f in MEMORY.md USER.md; do
        _switch_read_seat_file "$home" "$home/.hermes/memories/$f" >"$insrc/$f"
      done ;;
    openclaw)
      local ws="$home/.openclaw/workspace"
      for f in MEMORY.md USER.md; do _switch_read_seat_file "$home" "$ws/$f" >"$insrc/$f"; done
      if [[ -d "$ws/memory" ]] && _switch_no_symlink "$ws/memory" "$home" 2>/dev/null; then
        mkdir -p "$insrc/memory"
        while IFS= read -r -d '' f; do
          rel="${f#"$ws/memory/"}"
          mkdir -p "$insrc/memory/$(dirname "$rel")"
          cat -- "$f" >"$insrc/memory/$rel" 2>/dev/null || true
        done < <(find -P "$ws/memory" -maxdepth 3 -type f -name '*.md' -print0 2>/dev/null)
      fi ;;
    *) rm -rf "$stage"; return 1 ;;
  esac
  python3 - "$t" "$insrc" "$stage" "$@" <<'PY' || true
import hashlib, os, re, sys
kind, src, out, frags = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
boiler = []
for f in frags:
    try:
        b = open(f).read().strip()
    except OSError:
        continue
    if b:
        boiler.append(b)

def clean(text):
    for b in boiler:
        text = text.replace(b, "")
    return text.strip()

def slug(text, n=6):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return "-".join(s.split("-")[:n])[:48].strip("-")

def desc(text):
    for line in text.splitlines():
        line = line.strip().lstrip("#").strip()
        if line:
            return (line[:137] + "...") if len(line) > 140 else line
    return ""

def emit(prefix, label, body, typ, srcname):
    body = body.strip()
    if not body:
        return
    h = hashlib.sha1(body.encode()).hexdigest()[:8]
    s = slug(label)
    name = f"{prefix}-{s}-{h}" if s else f"{prefix}-{h}"
    d = desc(label) or desc(body)
    d = d.replace("\\", "\\\\").replace('"', '\\"')
    with open(os.path.join(out, name + ".md"), "w") as fh:
        fh.write(f'---\nname: {name}\ndescription: "{d}"\nmetadata:\n  type: {typ}\n  source: {kind}/{srcname}\n---\n\n{body}\n')

def read(rel):
    try:
        return open(os.path.join(src, rel)).read()
    except OSError:
        return ""

if kind == "hermes":
    for fname, prefix, typ in (("MEMORY.md", "hermes-mem", "project"), ("USER.md", "hermes-user", "user")):
        for entry in re.split(r"\n[ \t]*§[ \t]*\n", "\n" + read(fname) + "\n"):
            emit(prefix, entry, entry, typ, fname)
else:
    text = clean(read("MEMORY.md"))
    parts = re.split(r"(?m)^(?=## )", text)
    if len(parts) == 1:
        emit("openclaw-mem", "", text, "project", "MEMORY.md")
    else:
        for p in parts:
            emit("openclaw-mem", p.splitlines()[0] if p.startswith("## ") else "", p, "project", "MEMORY.md")
    emit("openclaw-user", "", clean(read("USER.md")), "user", "USER.md")
    mroot = os.path.join(src, "memory")
    for dp, _, files in os.walk(mroot):
        for fn in sorted(files):
            rel = os.path.relpath(os.path.join(dp, fn), mroot)
            emit("openclaw-note", rel[:-3], read(os.path.join("memory", rel)), "project", "memory/" + rel)
PY
  mkdir -p "$mdir"
  for f in "$stage"/"$t"-*.md; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    if [[ -L "$mdir/$base" ]]; then warn "refusing to write through a symlink: $mdir/$base"
    elif [[ ! -f "$mdir/$base" ]]; then _switch_install_file "$user" "$f" "$mdir/$base" 644 "$home" && a=$((a + 1))
    elif ! cmp -s "$f" "$mdir/$base"; then _switch_install_file "$user" "$f" "$mdir/$base" 644 "$home" && u=$((u + 1))
    else s=$((s + 1)); fi
  done
  # Removed only when it is one of OURS: the prefix and the source line both say so.
  for f in "$mdir/$t"-mem-*.md "$mdir/$t"-user-*.md "$mdir/$t"-note-*.md; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    [[ -f "$stage/$(basename "$f")" ]] && continue
    grep -q "^  source: $t/" "$f" 2>/dev/null || continue
    rm -f "$f"; r=$((r + 1))
  done
  rm -rf "$stage"
  _switch_index_prefixed_atoms "$mdir" "5dive:$t-memory" "$(_switch_label "$t")" "$t" "$user" "$home" "$t-mem-" "$t-user-" "$t-note-"
  printf '%s %s %s %s\n' "$a" "$u" "$r" "$s"
}

# Every skill folder the <type> side holds, one path per line, first name wins.
_switch_skill_dirs() { # <home> <type>
  local home="$1" t="$2" d f seen=" "
  local -a roots=()
  case "$t" in
    hermes)
      d="$home/.hermes/skills"
      [[ -d "$d" ]] && _switch_no_symlink "$d" "$home" 2>/dev/null || return 0
      while IFS= read -r -d '' f; do
        f=$(dirname "$f")
        [[ "${f#"$d"/}" == .* || "${f#"$d"/}" == */.* ]] && continue
        [[ "$seen" == *" $(basename "$f") "* ]] && continue
        seen+="$(basename "$f") "; printf '%s\n' "$f"
      done < <(find -P "$d" -mindepth 2 -maxdepth 3 -type f -name SKILL.md -print0 2>/dev/null | sort -z)
      return 0 ;;
    openclaw) roots=("$home/.openclaw/workspace/skills" "$home/.openclaw/skills" "$home/$(skills_install_dir openclaw)") ;;
    *) roots=("$home/$(skills_install_dir "$t")") ;;
  esac
  for d in "${roots[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*/; do
      [[ -d "$f" ]] || continue
      f="${f%/}"
      [[ "$seen" == *" $(basename "$f") "* ]] && continue
      seen+="$(basename "$f") "; printf '%s\n' "$f"
    done
  done
}

# A skill the source harness ships itself (Hermes's bundled set): the target
# has its own tools for that, so it is not copied, and it is counted, not named.
_switch_source_builtin_skill() { # <home> <type> <skill>
  [[ "$2" == hermes ]] || return 1
  local m
  m=$(_switch_read_seat_file "$1" "$1/.hermes/skills/.bundled_manifest")
  grep -qxF -- "$3" <<<"$(cut -d: -f1 <<<"$m")"
}

# ======================================================================
# DIVE-8675: --keep-model. A Hermes or OpenClaw seat on DeepSeek, Kimi, Qwen,
# GLM or OpenRouter moves to Claude Code on ITS OWN provider, key and model
# instead of the owner's Claude plan. Claude Code reaches those five through
# their Anthropic-format endpoints (CLAUDE_PROVIDER_BASEURL), so the seat gets
# its own account written by the same writer as `agent create --provider=`
# (_apply_byo_claude). A provider with no such endpoint (plain OpenAI, Google)
# is refused before anything changes.
#
# Where each harness keeps the three facts (seat home first, then the account
# the seat was bound to, which its unit also loads as env):
#   provider  hermes   ~/.hermes/config.yaml model.provider (a native id:
#                      kimi, alibaba, ... — HERMES_PROVIDER_ID reversed)
#             openclaw openclaw.json agents.defaults.model.primary, first
#                      segment ("deepseek/deepseek-v4-pro")
#   model     hermes   model.default · openclaw the rest of primary
#   key       hermes   auth.json credential_pool.<native>[].access_token, else
#                      the provider's *_API_KEY in ~/.hermes/.env
#             openclaw the authProfiles.store row of its sqlite state
#                      (DIVE-7101 ~/.openclaw/state/openclaw.sqlite; DIVE-3489
#                      agents/main/agent/openclaw-agent.sqlite), else the
#                      provider's *_API_KEY in ~/.openclaw/.env
# ======================================================================

# The env names each harness reads a provider's key from (hermes_cli/auth.py
# api_key_env_vars; openclaw takes the same names), keyed by canonical id.
declare -gA SWITCH_PROVIDER_KEY_VARS=(
  [deepseek]="DEEPSEEK_API_KEY"
  [moonshot]="KIMI_API_KEY MOONSHOT_API_KEY"
  [openrouter]="OPENROUTER_API_KEY"
  [zai]="GLM_API_KEY ZAI_API_KEY Z_AI_API_KEY"
  [qwen]="DASHSCOPE_API_KEY ALIBABA_CODING_PLAN_API_KEY QWEN_API_KEY"
  [openai]="OPENAI_API_KEY"
  [google]="GEMINI_API_KEY GOOGLE_API_KEY"
)

# A hermes native provider id -> canonical. Hermes renames kimi to kimi-coding
# itself and has a coding-plan id for Alibaba, neither in HERMES_PROVIDER_ID.
_switch_hermes_canonical() { # <native>
  case "$1" in
    kimi-coding|kimi-coding-cn) echo moonshot ;;
    alibaba-coding-plan) echo qwen ;;
    glm|z-ai|zhipu) echo zai ;;
    *) resolve_canonical_provider_hermes "$1" ;;
  esac
}

_switch_openclaw_canonical() { # <native>
  local c
  for c in "${!OPENCLAW_PROVIDER_ID[@]}"; do
    [[ -n "${OPENCLAW_PROVIDER_ID[$c]}" && "${OPENCLAW_PROVIDER_ID[$c]}" == "$1" ]] && { echo "$c"; return 0; }
  done
  echo ""
}

# One key out of the seat's model: block of a hermes config.yaml. A bare
# `model: <id>` (older configs) answers `default`.
_switch_hermes_model_field() { # <home> <provider|default>
  _switch_read_seat_file "$1" "$1/.hermes/config.yaml" | awk -v k="$2" '
    function unq(s) { sub(/[[:space:]]+#.*$/, "", s); gsub(/^["'\'']|["'\'']$/, "", s); return s }
    /^model:[[:space:]]*[^[:space:]#]/ { if (k == "default") { s=$0; sub(/^model:[[:space:]]*/, "", s); print unq(s) } exit }
    /^model:/ { m=1; next }
    m && /^[^[:space:]]/ { exit }
    m && $0 ~ "^[[:space:]]+" k ":" { s=$0; sub("^[[:space:]]+" k ":[[:space:]]*", "", s); print unq(s); exit }'
}

# The first non-empty value of any of <vars> in an env file under the seat home.
_switch_env_first() { # <home> <env-file> <var...>
  local home="$1" file="$2" v; shift 2
  for v in "$@"; do
    v=$(_switch_env_value "$home" "$file" "$v")
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  done
  return 0
}

# The api-key profile for <native> in an openclaw sqlite state db, read from a
# copy (the seat owns the file; root never opens it in place).
_switch_openclaw_db_key() { # <home> <db> <native>
  local home="$1" db="$2" native="$3" tmp k=""
  [[ -f "$db" ]] || return 0
  _switch_no_symlink "$db" "$home" 2>/dev/null || return 0
  tmp=$(mktemp -d)
  cat -- "$db" >"$tmp/s.sqlite" 2>/dev/null
  [[ -f "$db-wal" && ! -L "$db-wal" ]] && cat -- "$db-wal" >"$tmp/s.sqlite-wal" 2>/dev/null
  k=$(python3 -I -c '
import json, sqlite3, sys
try:
    r = sqlite3.connect(sys.argv[1]).execute(
        "SELECT value_json FROM config_machine_state WHERE state_key = ?", ("authProfiles.store",)).fetchone()
    prof = (json.loads(r[0]) or {}).get("profiles") or {} if r else {}
except Exception:
    prof = {}
for pid, p in sorted(prof.items()):
    if isinstance(p, dict) and p.get("provider") == sys.argv[2] and p.get("type", "api_key") == "api_key":
        k = p.get("key") or p.get("apiKey") or ""
        if isinstance(k, str) and k:
            print(k); break' "$tmp/s.sqlite" "$native" 2>/dev/null) || k=""
  rm -rf "$tmp"
  printf '%s\n' "$k"
}

# switch_source_ai <home> <type> [account] — what the seat runs on, as
# SWITCH_SRC_{PROVIDER,MODEL,KEY} (canonical id, the model id as the provider's
# own API names it, the key). Any of the three may come back empty; the caller
# refuses on what is missing.
switch_source_ai() {
  local home="$1" type="$2" acct="${3:-}" native="" model="" key="" canonical="" v vars
  SWITCH_SRC_PROVIDER="" SWITCH_SRC_MODEL="" SWITCH_SRC_KEY=""
  case "$type" in
    hermes)
      native=$(_switch_hermes_model_field "$home" provider)
      model=$(_switch_hermes_model_field "$home" default)
      [[ -n "$native" ]] && canonical=$(_switch_hermes_canonical "$native")
      if [[ -n "$native" ]]; then
        key=$(_switch_read_seat_file "$home" "$home/.hermes/auth.json" | jq -r --arg p "$native" '
          (.credential_pool[$p] // []) | if type == "array" then . else [] end
          | map(select((.auth_type // "api_key") == "api_key" and ((.access_token // "") | length) > 0))
          | sort_by(.priority // 0) | first | .access_token // empty' 2>/dev/null) || key=""
      fi
      vars="${SWITCH_PROVIDER_KEY_VARS[$canonical]:-}"
      # shellcheck disable=SC2086  # a list of names
      [[ -n "$key" || -z "$vars" ]] || key=$(_switch_env_first "$home" "$home/.hermes/.env" $vars) ;;
    openclaw)
      v=$(_switch_openclaw_conf "$home" | jq -r '.agents.defaults.model
          | if type == "object" then .primary elif type == "string" then . else empty end
          | select(type == "string")' 2>/dev/null) || v=""
      if [[ "$v" == */* ]]; then
        native="${v%%/*}"; model="${v#*/}"
        canonical=$(_switch_openclaw_canonical "$native")
      fi
      if [[ -n "$native" ]]; then
        key=$(_switch_openclaw_db_key "$home" "$home/.openclaw/state/openclaw.sqlite" "$native")
        [[ -n "$key" ]] || key=$(_switch_openclaw_db_key "$home" "$home/.openclaw/agents/main/agent/openclaw-agent.sqlite" "$native")
      fi
      vars="${SWITCH_PROVIDER_KEY_VARS[$canonical]:-}"
      # shellcheck disable=SC2086
      [[ -n "$key" || -z "$vars" ]] || key=$(_switch_env_first "$home" "$home/.openclaw/.env" $vars) ;;
  esac
  # The account the seat was bound to: its combined.env is in the seat's unit
  # env, which is where both harnesses also look for a provider key.
  if [[ -z "$key" && -n "$acct" && -n "$vars" ]]; then
    for v in $vars; do
      key=$(profile_env_value "$acct" "$v"); [[ -n "$key" ]] && break
    done
  fi
  SWITCH_SRC_PROVIDER="$canonical" SWITCH_SRC_MODEL="$model" SWITCH_SRC_KEY="$key"
}

# The account a --keep-model seat gets: its own, named after it and the vendor,
# so no other seat's account is rewritten and the source side's stays as it was.
switch_keep_account_name() { # <name> <canonical>
  local p="${1}-${2}"
  valid_profile_name "$p" || p="keep-$(printf '%s' "$1" | cksum | cut -d' ' -f1)-${2}"
  printf '%s\n' "${p:0:32}"
}

# Pin settings.json's model on a seat that ran Claude Code before (a fresh one
# is preseeded with it). The rest of the file is kept as the seat left it.
switch_set_claude_model() { # <home> <user> <model>
  local f="$1/.claude/settings.json" tmp
  _switch_no_symlink "$f" "$1" || return 1
  tmp=$(mktemp)
  jq --arg m "$3" '.model = $m' "$f" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  _switch_install_file "$2" "$tmp" "$f" "$(stat -c %a "$f" 2>/dev/null || echo 644)" "$1"; local rc=$?
  rm -f "$tmp"; return "$rc"
}

cmd_agent_switch() {
  require_root "agent switch"
  local name="" to="" account="" account_set=0 handoff_wait=90 handoff=1 keep_model=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to=*)           to="${1#--to=}" ;;
      --account=*)      account="${1#--account=}"; account_set=1 ;;
      --handoff-wait=*) handoff_wait="${1#--handoff-wait=}" ;;
      --no-handoff)     handoff=0 ;;
      --keep-model)     keep_model=1 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" && -n "$to" ]] \
    || fail "$E_USAGE" "usage: 5dive agent switch <name> --to=claude|codex|grok [--account=<account|default>] [--no-handoff] [--handoff-wait=<seconds>]  (a hermes or openclaw agent: --to=claude [--keep-model])"
  [[ "$handoff_wait" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "--handoff-wait must be a number of seconds"
  _switch_is_type "$to" \
    || fail "$E_VALIDATION" "--to must be claude, codex or grok (got '$to')"
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
  # DIVE-8672: a Hermes or OpenClaw agent moves one way, onto Claude Code.
  local src_only=0
  if _switch_is_source "$from"; then
    src_only=1
    [[ "$to" == claude ]] \
      || fail "$E_VALIDATION" "agent '$name' runs $(_switch_label "$from"), which can move to Claude Code only for now (--to=claude)"
  else
    _switch_is_type "$from" \
      || fail "$E_VALIDATION" "agent '$name' is type $from — switch moves between claude, codex and grok, and from hermes or openclaw to claude"
  fi
  # DIVE-8675: --keep-model is the Hermes/OpenClaw seat's own key and model,
  # so it names its own account; --account would be a second answer to that.
  if (( keep_model )); then
    (( src_only )) \
      || fail "$E_VALIDATION" "--keep-model is for a Hermes or OpenClaw agent moving to Claude Code; '$name' runs $(_switch_label "$from") — use --account=<account> to pick what it runs on"
    (( account_set )) \
      && fail "$E_USAGE" "--keep-model keeps the AI key '$name' already runs on, so it takes no --account= (drop one of the two)"
  fi
  [[ "$from" != "$to" ]] || fail "$E_VALIDATION" "agent '$name' already runs $(_switch_label "$to")"
  # The owner's own opt-out, the one `agent create --type=grok` respects.
  if [[ "$to" == grok ]] && ! _switch_grok_on; then
    fail "$E_VALIDATION" "Grok is turned off on this server (the owner turned it off). To turn it back on: sudo 5dive grok enable"
  fi

  # ---- pre-flight: every refusal below changes nothing ----
  local ch
  for ch in ${channels//,/ }; do
    case "$ch" in
      none|telegram|dashboard) ;;
      # Only the Telegram token is read off a Hermes/OpenClaw seat; another
      # bot would come up on Claude with no credential.
      *) (( src_only )) && fail "$E_VALIDATION" \
           "agent '$name' uses the $ch channel, which this move does not carry from $(_switch_label "$from") yet — remove it first (5dive agent config $name set channels=…), then switch"
         [[ "$to" != claude ]] && fail "$E_VALIDATION" \
           "agent '$name' uses the $ch channel, which $(_switch_label "$to") does not have — remove it first (5dive agent config $name set channels=…)" ;;
    esac
  done
  local home user token=""
  home=$(_switch_home "$name"); user="agent-${name}"
  local keep_provider="" keep_model_id="" keep_key="" keep_url=""
  if (( keep_model )); then
    switch_source_ai "$home" "$from" "$prev_profile"
    keep_provider="$SWITCH_SRC_PROVIDER" keep_model_id="$SWITCH_SRC_MODEL" keep_key="$SWITCH_SRC_KEY"
    [[ -n "$keep_provider" ]] \
      || fail "$E_VALIDATION" "could not tell which AI provider '$name' runs on in its $(_switch_label "$from") settings, so its model cannot be kept — switch without --keep-model to move it onto your Claude plan; nothing was changed"
    keep_url="${CLAUDE_PROVIDER_BASEURL[$keep_provider]:-}"
    [[ -n "$keep_url" ]] \
      || fail "$E_VALIDATION" "'$name' runs on ${BYO_PROVIDER_LABEL[$keep_provider]:-$keep_provider}, which Claude Code cannot talk to (it only reaches DeepSeek, Kimi, Qwen, GLM and OpenRouter that way). Switch without --keep-model to move it onto your Claude plan; moving it to Codex on its own key is not built yet. Nothing was changed"
    [[ -n "$keep_key" ]] && valid_api_key "$keep_key" \
      || fail "$E_VALIDATION" "found no ${BYO_PROVIDER_LABEL[$keep_provider]:-$keep_provider} key for '$name' in its $(_switch_label "$from") files, so its model cannot be kept — switch without --keep-model to use your Claude plan, or set its key again first; nothing was changed"
    [[ -z "$keep_model_id" ]] || valid_model "$keep_model_id" \
      || fail "$E_VALIDATION" "'$name' names its model as '$keep_model_id', which is not a model id 5dive can carry — set it to a plain id first; nothing was changed"
    account=$(switch_keep_account_name "$name" "$keep_provider")
    # An account by that name that is not on this vendor already is someone's;
    # the writer would re-point it (or refuse it), so refuse here, unchanged.
    local _kp_url
    _kp_url=$(profile_env_value "$account" ANTHROPIC_BASE_URL)
    [[ -z "$_kp_url" || "$_kp_url" == "$keep_url" ]] \
      || fail "$E_CONFLICT" "an account named '$account' already exists on another AI provider ($_kp_url) — rename or remove it, then switch again; nothing was changed"
  fi
  (( account_set || keep_model )) || account="$prev_profile"
  # A Hermes/OpenClaw seat's own account is usually an API key for that harness
  # (or a BYO provider). The move is onto the Claude PLAN: keep the seat's
  # account only when it is a Claude sign-in that is not a BYO endpoint,
  # otherwise use the box default.
  if (( src_only && ! account_set && ! keep_model )) && [[ -n "$account" ]]; then
    if [[ ! -f "${AUTH_PROFILES_DIR}/${account}/combined.env" ]] \
       || grep -q '^ANTHROPIC_BASE_URL=.' "${AUTH_PROFILES_DIR}/${account}/combined.env" 2>/dev/null \
       || ! switch_account_serves "$account" claude; then
      account=""
    fi
  fi
  [[ "$account" == default ]] && account=""
  if [[ -n "$account" ]] && (( ! keep_model )); then
    valid_profile_name "$account" || fail "$E_VALIDATION" "invalid account name '$account'"
    [[ -f "${AUTH_PROFILES_DIR}/${account}/combined.env" ]] \
      || fail "$E_NOT_FOUND" "account '$account' is not configured"
  fi
  if (( ! keep_model )) && ! switch_account_serves "$account" "$to"; then
    if (( src_only )); then
      fail "$E_VALIDATION" "moving '$name' to Claude Code needs a Claude plan sign-in on this server, and account '${account:-default}' has none — sign in first (sudo 5dive agent auth start claude), then switch again; nothing was changed"
    fi
    if (( account_set )); then
      fail "$E_VALIDATION" "account '${account:-default}' has no $(_switch_label "$to") sign-in — sign in first (5dive agent auth start $to --auth-profile=<account>), then pass it with --account="
    fi
    fail "$E_VALIDATION" "agent '$name' is on account '${account:-default}', which has no $(_switch_label "$to") sign-in — pass --account=<an account signed in to $(_switch_label "$to")>"
  fi
  id -u "$user" &>/dev/null || fail "$E_GENERIC" "agent user missing: $user"
  if channel_in_list telegram "$channels"; then
    if (( src_only )); then
      token=$(_switch_source_tg_token "$home" "$from")
    else
      token=$(_switch_tg_token "$home" "$from")
    fi
    [[ -n "$token" ]] || token=$(_switch_tg_token "$home" "$to")
    [[ -n "$token" ]] || fail "$E_VALIDATION" "agent '$name' has channels=telegram but no bot token on disk — reconnect the bot first"
    if [[ "$to" == codex ]]; then
      codex_plugin_dir >/dev/null \
        || fail "$E_NOT_INSTALLED" "the Codex Telegram bridge (telegram-codex) is not deployed on this box"
    fi
    if [[ "$to" == grok ]]; then
      grok_plugin_dir >/dev/null \
        || fail "$E_NOT_INSTALLED" "the Grok Telegram bridge (telegram-grok) is not deployed on this box"
    fi
  fi
  # ---- DIVE-8371: a seat switching ITSELF hands the rest to a detached unit ----
  # Every refusal above already ran here, so the caller still hears them inline.
  # What follows (install, stop, convert, start) runs as a transient service
  # outside this seat's cgroup, after a short delay that lets the caller's turn
  # finish its reply. No handoff ask: the seat is the caller and cannot answer
  # while it waits on this command; it is told to write the note itself instead.
  if [[ "${FIVEDIVE_SWITCH_DETACHED:-0}" != 1 ]] && _switch_inside_own_unit "$name"; then
    local self_bin delay su t_now
    self_bin="${FIVEDIVE_SELF:-$(command -v 5dive || echo /usr/local/bin/5dive)}"
    delay="${FIVEDIVE_SWITCH_SELF_DELAY:-20}"
    [[ "$delay" =~ ^[0-9]+$ ]] || delay=20
    t_now=$(date +%s)
    su="5dive-switch-${name}-${t_now}-$$"
    local -a again=(--account="${account:-default}")
    (( keep_model )) && again=(--keep-model)
    systemd-run --unit="$su" --collect --on-active="$delay" --timer-property=AccuracySec=100ms \
        -p KillMode=process --setenv=PATH="$PATH" \
        --setenv=FIVEDIVE_SWITCH_DETACHED=1 --setenv=FIVEDIVE_SWITCH_T0="$t_now" \
        -- "$self_bin" agent switch "$name" --to="$to" "${again[@]}" >&2 \
      || fail "$E_GENERIC" "could not start the switch outside $name's own session — nothing switched; ask the owner to switch $name from the dashboard"
    local next_msg="switching $name to $(_switch_label "$to") (account ${account:-default}) in ${delay}s: this session stops then, and $name is back on $(_switch_label "$to") about a minute later. Write anything the next session needs into ~/${SWITCH_HANDOFF_FILE} now; it reads that file first. Progress: journalctl -u $su"
    ok "$next_msg" \
       '{name:$n, from:$f, to:$t, account:$a, warning:$w, detached:true, unit:$u, startsInSeconds:$d, next:$x}' \
       --arg x "$next_msg" \
       --arg n "$name" --arg f "$from" --arg t "$to" --arg a "${account:-default}" --arg w "$(switch_harness_warning "$name" "$from" "$to" "${keep_provider}")" \
       --arg u "$su" --argjson d "$delay"
    return 0
  fi

  if [[ ! -x "${TYPE_BIN[$to]}" ]]; then
    [[ -n "${TYPE_INSTALL[$to]:-}" ]] \
      || fail "$E_NOT_INSTALLED" "$to is not installed and has no installer"
    step "$to not installed — installing now"
    cmd_install "$to" >&2
  fi

  local warning
  warning=$(switch_harness_warning "$name" "$from" "$to" "$keep_provider")
  step "$warning"

  # ---- 1. handoff: ask the running seat for a note, then stop it ----
  local unit="5dive-agent@${name}.service" hf="$home/$SWITCH_HANDOFF_FILE" t0 waited=0 handoff_state=skipped
  t0=$(date +%s)
  if [[ "${FIVEDIVE_SWITCH_DETACHED:-0}" == 1 ]]; then
    # The detached half of a self-switch: the seat was told to write the note
    # itself when it queued this, so read the file, never ask.
    handoff=0; handoff_state=self
    [[ "${FIVEDIVE_SWITCH_T0:-}" =~ ^[0-9]+$ && -f "$hf" ]] \
      && (( $(stat -c %Y "$hf" 2>/dev/null || echo 0) >= FIVEDIVE_SWITCH_T0 )) && handoff_state=written
  fi
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

  # DIVE-8675: the seat's own account, written first by the same writer as
  # `agent create --provider=` (base URL, key, the model on the opus+sonnet
  # tiers, the vendor's cheap one on haiku). A refusal here leaves the source
  # side exactly as it was.
  if (( keep_model )); then
    step "Writing account '$account': ${BYO_PROVIDER_LABEL[$keep_provider]:-$keep_provider} at $keep_url${keep_model_id:+, model $keep_model_id}"
    ( _apply_byo_claude "$keep_provider" "$keep_key" "$account" "$keep_model_id" ) >&2 \
      || fail "$E_GENERIC" "could not write account '$account' for '$name' — nothing switched; the unit is stopped, start it with: 5dive agent start $name"
  fi

  # DIVE-8672: the source harness's own poller goes down before anything is
  # converted, so a stuck one leaves the seat exactly as it was (plus stopped).
  if (( src_only )); then
    step "Stopping $(_switch_label "$from")'s own gateway for $user"
    _switch_stop_source_gateway "$name" "$from" \
      || fail "$E_GENERIC" "$(_switch_label "$from")'s own Telegram gateway for $user would not stop, and two pollers on one bot make Telegram drop one (409) — nothing switched; the unit is stopped, start it with: 5dive agent start $name"
  fi

  # ---- 2-4. side files for the target harness ----
  local carry_from carry_to memidx="" tmpdoc mem_json='{}'
  local pf_from="${TYPE_PERSONA_FILE[$from]:-}" pf_to="${TYPE_PERSONA_FILE[$to]:-}"
  [[ -n "$pf_from" && -n "$pf_to" ]] \
    || fail "$E_GENERIC" "no instructions file is known for $from or $to — nothing switched; the unit is stopped, start it with: 5dive agent start $name"
  carry_from="$home/$pf_from"
  carry_to="$home/$pf_to"
  # Claude <-> Grok: one file serves both, so there is nothing to carry across;
  # the block is still rewritten (it points at the handoff, and to Grok holds
  # the memory index), and the text outside it is kept as it is.
  local carry_src="$carry_from" kept_block=""
  if [[ "$pf_from" == "$pf_to" ]]; then
    kept_block=$(mktemp)
    _switch_no_symlink "$carry_from" "$home" && _switch_block_instructions "$carry_from" >"$kept_block"
    carry_src="$kept_block"
  fi
  local -a frags=()
  local fragdir="" src_doc=""
  if [[ "$from" == claude || "$from" == grok ]]; then
    frags=("$TELEGRAM_AGENT_CLAUDE_MD" "$MODEL_TIERING_CLAUDE_MD" "$OPERATIONAL_COMMS_CLAUDE_MD")
  elif (( src_only )); then
    # The harness's own boilerplate is not carried; the owner's text is.
    fragdir=$(mktemp -d)
    mapfile -t frags < <(_switch_source_frags "$from" "$fragdir")
    src_doc=$(mktemp)
    _switch_source_instructions "$home" "$from" "$src_doc"
    carry_src="$src_doc"
  fi

  # DIVE-8675: a kept model is pinned by id. An Anthropic id left in
  # settings.json is NOT translated by the account's tier map (only the aliases
  # are, DIVE-5127), and OpenRouter would serve it as real Claude.
  local keep_start=""
  (( keep_model )) && keep_start="${keep_model_id:-${CLAUDE_PROVIDER_OPUS_MODEL[$keep_provider]:-}}"
  if [[ "$to" == claude ]]; then
    if [[ ! -f "$home/.claude/settings.json" ]]; then
      local _m
      _m=$(claude_create_start_model "$keep_start" "" "" "$account")
      model_latest "$_m" >/dev/null 2>&1 && _m=$(resolve_model_for_profile "$_m" "$account")
      step "Preseeding Claude Code for $user (first time on this harness)"
      preseed_claude_agent "$name" "$channels" "$_m" high
    elif [[ -n "$keep_start" ]]; then
      switch_set_claude_model "$home" "$user" "$keep_start" \
        || warn "could not pin model $keep_start in $home/.claude/settings.json"
    fi
  fi

  # Channels on the target bridge, same token, merged allowlist.
  local allow_n=0 tg_note=""
  if channel_in_list telegram "$channels"; then
    local sa="$home/.$from/channels/telegram/access.json" da="$home/.$to/channels/telegram/access.json"
    local allow_csv
    allow_csv=$(jq -r '(.allowFrom // []) | join(",")' "$sa" 2>/dev/null || true)
    (( src_only )) && allow_csv=$(_switch_source_tg_allow "$home" "$from")
    if [[ "$to" == claude && -d "$home/.claude/plugins/cache/5dive-plugins/telegram" ]]; then
      # Kept from the last time this seat ran Claude: refresh the token line
      # only, so the claude side's settings.json and CLAUDE.md stay as they were.
      set_claude_telegram_env_key "$name" TELEGRAM_BOT_TOKEN "$token"
    else
      install_channel_for_agent "$to" telegram "$name" "$token" "" "$allow_csv"
    fi
    if _switch_no_symlink "$sa" "$home" && _switch_no_symlink "$da" "$home"; then
      allow_n=$(switch_merge_access "$sa" "$da")
      chown -h "$user:$user" "$da" 2>/dev/null || true
    else
      warn "Telegram allowlist NOT merged: an access.json is reached through a symlink"
    fi
    if [[ "$to" != claude ]] && grep -q '^TELEGRAM_PROFILE=lite' "$home/.claude/channels/telegram/.env" 2>/dev/null; then
      tg_note="telegram lite profile ($(_switch_label "$to")'s bridge has no lite mode)"
    fi
  fi
  if channel_in_list dashboard "$channels"; then
    if [[ "$to" != claude || ! -d "$home/.claude/plugins/cache/5dive-plugins/dashboard" ]]; then
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

  # Memory. The atoms live in the 5dive store (~/.claude/projects/*/memory) for
  # Claude and Grok alike; only Codex keeps its own documents, converted on the
  # way out of it. Claude loads MEMORY.md itself; Codex and Grok get its index
  # in the carried block.
  local atoms
  if [[ "$from" == codex ]]; then
    local mdir counts _a _u _r _s
    mdir=$(switch_claude_memdir "$name" "$workdir")
    counts=$(switch_codex_memory_to_atoms "$home/.codex/memories" "$mdir" "$user" "$home") \
      || warn "the Codex memory was NOT converted: $mdir is reached through a symlink"
    chown -R "$user:$user" "$home/.claude/projects" 2>/dev/null || true
    read -r _a _u _r _s <<<"$counts"
    mem_json=$(jq -cn --arg d "$mdir" --arg dir "codex->$to" --argjson a "${_a:-0}" --argjson u "${_u:-0}" --argjson r "${_r:-0}" --argjson s "${_s:-0}" \
      '{direction:$dir, memdir:$d, added:$a, updated:$u, removed:$r, unchanged:$s}')
  elif (( src_only )); then
    local mdir counts _a _u _r _s
    mdir=$(switch_claude_memdir "$name" "$workdir")
    counts=$(switch_harness_memory_to_atoms "$from" "$home" "$mdir" "$user" ${frags[@]+"${frags[@]}"}) \
      || warn "the $(_switch_label "$from") memory was NOT converted: $mdir is reached through a symlink"
    chown -R "$user:$user" "$home/.claude/projects" 2>/dev/null || true
    read -r _a _u _r _s <<<"$counts"
    mem_json=$(jq -cn --arg d "$mdir" --arg dir "$from->$to" --argjson a "${_a:-0}" --argjson u "${_u:-0}" --argjson r "${_r:-0}" --argjson s "${_s:-0}" \
      '{direction:$dir, memdir:$d, added:$a, updated:$u, removed:$r, unchanged:$s, store:"5dive (memory search)"}')
  else
    atoms=$({ find "$home"/.claude/projects/*/memory -maxdepth 1 -name '*.md' ! -name MEMORY.md 2>/dev/null || true; } | wc -l)
    mem_json=$(jq -cn --arg dir "$from->$to" --argjson n "$atoms" --argjson c "$([[ "$to" == claude ]] && echo false || echo true)" \
      '{direction:$dir, atoms:$n, store:"5dive (memory search)", indexCarried:$c}')
  fi
  if [[ "$to" != claude ]]; then
    memidx=$(mktemp)
    _switch_claude_index_text "$name" "$memidx" "$to"
  fi

  # Instructions, AFTER the channel install (claude's installer writes CLAUDE.md).
  tmpdoc=$(mktemp)
  if _switch_no_symlink "$carry_from" "$home" && _switch_no_symlink "$carry_to" "$home"; then
    switch_carry_doc "$carry_src" "$carry_to" "$from" "$to" "$memidx" ${frags[@]+"${frags[@]}"} >"$tmpdoc"
    _switch_install_file "$user" "$tmpdoc" "$carry_to" 644 "$home" \
      || warn "could not write $carry_to"
  else
    warn "instructions NOT carried: $carry_from or $carry_to is reached through a symlink"
  fi
  rm -f "$tmpdoc" ${memidx:+"$memidx"} ${kept_block:+"$kept_block"} ${src_doc:+"$src_doc"}
  [[ -z "$fragdir" ]] || rm -rf "$fragdir"

  # Skills, before the unit starts so the target harness loads them on boot.
  local skill_lines copied_json
  skill_lines=$(_switch_carry_skills "$name" "$from" "$to")
  copied_json=$(sed -n 's/^copied //p' <<<"$skill_lines" | jq -R . | jq -cs 'map(select(length > 0))')

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
  # An operator park (desiredState=stopped, written only by `5dive agent stop`)
  # outranks the switch: the switch converts the seat and leaves it down, like
  # every other GUARDED restart path (tests/refresh_plugins_parked_agent_unit.sh).
  local up=false i desired parked=false state_note=""
  desired=$(jq -r --arg n "$name" '.agents[$n].desiredState // "running"' <<<"$reg" 2>/dev/null) || desired=running
  if [[ "$desired" == stopped ]]; then
    parked=true
    state_note="switched; left stopped, start it with 5dive agent start $name"
    step "$name is parked (desiredState=stopped) — $state_note"
  else
    step "Starting $unit on $(_switch_label "$to")"
    systemctl start "$unit" >&2 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
      systemctl is-active --quiet "$unit" 2>/dev/null && { up=true; break; }
      sleep 2
    done
    state_note="unit active: $up"
  fi

  # DIVE-8672: what a Hermes/OpenClaw seat had that does not come along: the
  # harness's own built-in skills, and every job its own scheduler ran. Said in
  # the result, so the owner is not left waiting on a job that no longer runs.
  local builtin_n jobs_n="" jobs_note="" jobs_json=null
  builtin_n=$(sed -n 's/^builtin //p' <<<"$skill_lines" | head -1)
  if (( src_only )); then
    jobs_n=$(_switch_source_job_count "$home" "$from")
    jobs_note="$(_switch_label "$from")'s own scheduled jobs${jobs_n:+ ($jobs_n)}"
    jobs_json=$(jq -cn --arg n "$jobs_n" '{carried:false, count:(if $n == "" then null else ($n|tonumber) end)}')
  fi
  local dropped_json
  dropped_json=$( { sed -n 's/^dropped //p' <<<"$skill_lines"
                    if [[ -n "$builtin_n" ]]; then printf '%s built-in %s skills (Claude Code has its own)\n' "$builtin_n" "$(_switch_label "$from")"; fi
                    if [[ -n "$tg_note" ]]; then printf '%s\n' "$tg_note"; fi
                    if [[ -n "$jobs_note" ]]; then printf '%s\n' "$jobs_note"; fi; } \
    | jq -R . | jq -cs 'map(select(length > 0))')
  local skills_note=""
  [[ "$copied_json" == "[]" ]] || skills_note="; skills copied: $(jq -r 'join(", ")' <<<"$copied_json")"
  [[ "$dropped_json" == "[]" ]] || skills_note+="; not carried: $(jq -r 'join(", ")' <<<"$dropped_json")"
  [[ -z "$jobs_note" ]] || skills_note+=" — those jobs no longer run; set them up again on Claude Code"
  local keep_json=null keep_note=""
  if (( keep_model )); then
    keep_json=$(jq -cn --arg p "$keep_provider" --arg m "$keep_start" --arg u "$keep_url" \
      '{provider:$p, model:$m, baseUrl:$u}')
    keep_note=" on its own ${BYO_PROVIDER_LABEL[$keep_provider]:-$keep_provider} model ${keep_start}"
  fi
  ok "agent '$name' switched from $(_switch_label "$from") to $(_switch_label "$to")${keep_note} (account ${account:-default}); $state_note$skills_note" \
     '{name:$n, from:$f, to:$t, account:$a, warning:$w, handoff:$h, memory:$m, telegram:{tokenKept:($tk == 1), allowFrom:$al}, copied:$c, dropped:$d, scheduledJobs:$jobs, running:$up, parked:$pk, keptModel:$keep}' \
     --argjson keep "$keep_json" \
     --arg n "$name" --arg f "$from" --arg t "$to" --arg a "${account:-default}" --arg w "$warning" \
     --arg h "$handoff_state" --argjson m "$mem_json" --argjson tk "$([[ -n "$token" ]] && echo 1 || echo 0)" \
     --argjson al "${allow_n:-0}" --argjson c "$copied_json" --argjson d "$dropped_json" --argjson up "$up" --argjson pk "$parked" \
     --argjson jobs "$jobs_json"
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
