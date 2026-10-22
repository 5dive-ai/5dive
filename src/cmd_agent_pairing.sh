# Read ~/.claude/channels/telegram/access.json for a claude-type agent. Used
# by the dashboard's access-control modal to render the current allowlist /
# groups / dmPolicy. Returns the parsed JSON in `data`. If the file doesn't
# exist yet (plugin hasn't persisted state), returns the same defaults the
# plugin would write on first run.
# Resolve the telegram-plugin state dir (where access.json lives) for an agent
# by type. claude, codex and grok each store it under ~/.<type>/channels/telegram/
# — the home subdir name matches the agent type, and all use the same
# access.json schema {dmPolicy, allowFrom, groups}. Echoes the dir on success;
# returns nonzero for types that have no telegram access.json (openclaw/hermes
# manage approvals through their own tooling, not this file). antigravity is the
# odd one out: its home subdir is ~/.gemini (not ~/.antigravity) because agy
# reuses Google's ~/.gemini parent, so it gets an explicit branch.
_tg_access_state_dir() {
  local user="$1" type="$2"
  case "$type" in
    claude|codex|grok|pi) printf '/home/%s/.%s/channels/telegram' "$user" "$type" ;;
    antigravity)       printf '/home/%s/.gemini/channels/telegram' "$user" ;;
    *) return 1 ;;
  esac
}

cmd_telegram_access_get() {
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-access get <name>"
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  [[ ",$channels," == *",telegram,"* ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-access only applies to telegram"

  local user="agent-${name}"
  local state_dir
  state_dir=$(_tg_access_state_dir "$user" "$type") \
    || fail "$E_VALIDATION" "telegram-access supports claude, codex, grok, pi and antigravity agents (got type=$type)"
  local access="${state_dir}/access.json"
  local raw
  raw=$(sudo -u "$user" cat "$access" 2>/dev/null || true)
  if [[ -z "$raw" ]] || ! jq -e . >/dev/null 2>&1 <<<"$raw"; then
    raw='{"dmPolicy":"pairing","allowFrom":[],"groups":{}}'
  fi
  ok "" '{access: $a, botUsername: $u}' \
     --argjson a "$raw" \
     --arg u "$(jq -r --arg n "$name" '.agents[$n].botUsername // ""' <<<"$reg")"
}

# Write the telegram access.json for a claude/codex/grok agent (path resolved
# by type via _tg_access_state_dir — all three share the same schema).
# The new JSON body comes in on stdin (the dashboard sends it via the
# `stdin` field on /server/agents/exec so it never lands in argv).
#
# Schema validated server-side: dmPolicy in {pairing,allowlist,disabled},
# allowFrom = array of numeric-string ids, groups = object keyed by chat id
# whose values are {requireMention: bool, allowFrom: string[]}. Any keys we
# don't expose (pending, mentionPatterns, replyToMode, textChunkLimit,
# chunkMode, ackReaction) are merged from the existing file rather than
# clobbered, so opaque settings the dashboard hasn't surfaced survive a
# save. Plugin re-reads on every inbound message — no agent restart needed.
cmd_telegram_access_set() {
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-access set <name>  (JSON body on stdin)"
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  [[ ",$channels," == *",telegram,"* ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-access only applies to telegram"
  local user="agent-${name}"
  local state_dir
  state_dir=$(_tg_access_state_dir "$user" "$type") \
    || fail "$E_VALIDATION" "telegram-access supports claude, codex, grok, pi and antigravity agents (got type=$type)"

  local body
  body=$(cat)
  [[ -n "$body" ]] || fail "$E_USAGE" "telegram-access set expects JSON on stdin"
  jq -e . >/dev/null 2>&1 <<<"$body" \
    || fail "$E_VALIDATION" "stdin is not valid JSON"

  step "Updating telegram access for agent '$name'"
  # Validation + atomic write live in the same python step so a bad shape
  # exits non-zero before we touch the file. STATE is the agent's plugin
  # state dir; PATCH is the dashboard's proposed {dmPolicy, allowFrom,
  # groups, botToBot?} blob. Unknown keys in the existing file (pending,
  # mentionPatterns, replyToMode, textChunkLimit, chunkMode, ackReaction)
  # survive the merge — only the dashboard-owned keys are replaced, and
  # botToBot (DIVE-161) only when the patch includes it.
  local script
  script=$(cat <<'PY'
import json, os, re, sys, tempfile

ID_RE = re.compile(r"^-?[0-9]+$")
state = os.environ['STATE']
try:
    patch = json.loads(os.environ['PATCH'])
except json.JSONDecodeError as e:
    print(f"invalid JSON: {e}", file=sys.stderr); sys.exit(2)

def bad(msg):
    print(msg, file=sys.stderr); sys.exit(2)

if not isinstance(patch, dict):
    bad("top-level must be an object")
if patch.get('dmPolicy') not in ('pairing', 'allowlist', 'disabled'):
    bad("dmPolicy must be one of pairing|allowlist|disabled")
allow = patch.get('allowFrom')
if not isinstance(allow, list) or not all(isinstance(s, str) and ID_RE.match(s) for s in allow):
    bad("allowFrom must be an array of numeric-string ids")
groups = patch.get('groups')
if not isinstance(groups, dict):
    bad("groups must be an object")
for gid, gcfg in groups.items():
    if not ID_RE.match(gid):
        bad(f"group key '{gid}' is not numeric")
    if not isinstance(gcfg, dict):
        bad(f"group '{gid}' value must be an object")
    if 'requireMention' in gcfg and not isinstance(gcfg['requireMention'], bool):
        bad(f"group '{gid}'.requireMention must be a boolean")
    if 'allowFrom' in gcfg:
        gallow = gcfg['allowFrom']
        if not isinstance(gallow, list) or not all(isinstance(s, str) and ID_RE.match(s) for s in gallow):
            bad(f"group '{gid}'.allowFrom must be an array of numeric-string ids")

# botToBot (DIVE-161) is OPTIONAL — present only when the dashboard's bot-to-bot
# section is in play. Shape mirrors the plugin's BotToBotConfig (botguard.ts):
# {enabled:bool, allowFrom?:[bot username/id strings], maxPerMin?:int>0,
# dedupeWindowMs?:int>=0}. Omitting the key leaves any existing config untouched.
b2b = patch.get('botToBot')
if b2b is not None:
    if not isinstance(b2b, dict):
        bad("botToBot must be an object")
    if not isinstance(b2b.get('enabled'), bool):
        bad("botToBot.enabled must be a boolean")
    if 'allowFrom' in b2b:
        ba = b2b['allowFrom']
        if not isinstance(ba, list) or not all(isinstance(s, str) and s for s in ba):
            bad("botToBot.allowFrom must be an array of non-empty strings (bot @usernames or ids)")
    if 'maxPerMin' in b2b and not (isinstance(b2b['maxPerMin'], int) and not isinstance(b2b['maxPerMin'], bool) and b2b['maxPerMin'] > 0):
        bad("botToBot.maxPerMin must be a positive integer")
    if 'dedupeWindowMs' in b2b and not (isinstance(b2b['dedupeWindowMs'], int) and not isinstance(b2b['dedupeWindowMs'], bool) and b2b['dedupeWindowMs'] >= 0):
        bad("botToBot.dedupeWindowMs must be a non-negative integer")

os.makedirs(state, mode=0o700, exist_ok=True)
path = os.path.join(state, 'access.json')

try:
    with open(path) as f:
        existing = json.load(f)
except FileNotFoundError:
    existing = {}

merged = dict(existing)
for k in ('dmPolicy', 'allowFrom', 'groups'):
    merged[k] = patch[k]
if b2b is not None:
    merged['botToBot'] = b2b

fd, tmp = tempfile.mkstemp(dir=state, prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(merged, f, indent=2)
os.replace(tmp, path)
PY
)
  local err
  if ! err=$(sudo -u "$user" env STATE="$state_dir" PATCH="$body" python3 -c "$script" 2>&1 >/dev/null); then
    fail "$E_VALIDATION" "${err:-telegram access.json write failed for agent '$name'}"
  fi

  ok "telegram access updated for '$name'" \
     '{name:$n, updated:true}' \
     --arg n "$name"
}

# DIVE-6675: "In groups, answer: when called by name · every message", the
# app's one setting for how an agent answers in its groups. It is
# requireMention on EVERY group in access.json (true = called by name, the
# plugin's default; false = every message), plus `groupsRequireMention`, the
# value the telegram plugin (0.5.103+) gives a group an owner adds later and
# the one its hello line reads. Without that key a box with no group yet would
# forget the choice, and the next group would come back "by name".
#
#   5dive agent telegram-access groups <name>                 # read
#   5dive agent telegram-access groups <name> --answer=name   # when called by name
#   5dive agent telegram-access groups <name> --answer=every  # every message
#   5dive agent telegram-access groups <name> --names="Оля,Liv,奥利维亚"  # also answers to
#   5dive agent telegram-access groups <name> --names=          # clear them
#
# data: {name, answer: "name"|"every", groups: <approved groups>, mixed: bool,
#        names: [...]}.
# `answer` is the stored key, else "every" when every group already answers
# every message, else "name". `mixed` = some group differs from `answer` (one
# was flipped on its own in Who can talk to); a write clears it. The plugin
# re-reads access.json per message, so no restart.
#
# DIVE-6684: `--names=` is the app's "Also answers to": extra names that call
# the agent in a group, in any language, stored as `groupsCallNames` (telegram
# plugin 0.5.105+ matches each like her display name). Comma-separated, at most
# 10, each 2-32 letters, marks, spaces or hyphens, 2+ letters a word: a name,
# never a pattern. A bad list is refused before anything is written.
#
# DIVE-6729: the app's field is now "Answers to", EVERY name that calls the
# agent. `names` on a read is that whole list: before the owner first saves it,
# the word the plugin takes from the bot's Telegram name (getMe first_name)
# comes first, then the stored extras. `--names=` writes the whole list and sets
# `groupsCallNamesComplete`, which tells the plugin (0.5.107+) not to add that
# word on its own, so the owner can remove it. An empty list is allowed: then
# only an @mention or a reply wakes it. `namesComplete: true` on a read means
# "names is the whole list and --names= replaces it". It is false only when
# the bot's name could not be read and the list was never saved, so a caller
# keeps the old "Also answers to" field instead of saving a list without it.
_tg_group_answer_py() {
  cat <<'PY'
import json, os, re, sys, tempfile, unicodedata

state = os.environ['STATE']
want = os.environ.get('ANSWER', '')
names_set = os.environ.get('NAMES_SET') == '1'
replace = names_set

def call_name(n):
    return (isinstance(n, str) and n == n.strip() and 2 <= len(n) <= 32
            and all(c in ' -' or unicodedata.category(c)[0] in 'LM' for c in n)
            and all(sum(unicodedata.category(c)[0] == 'L' for c in w) >= 2
                    for w in re.split(r'[ -]+', n)))

names = []
if names_set:
    for n in os.environ.get('NAMES', '').split(','):
        n = unicodedata.normalize('NFC', ' '.join(n.split()))
        if not n:
            continue
        if not call_name(n):
            print(f"names: '{n}' is not a name (2-32 letters, spaces or hyphens, 2+ letters a word)", file=sys.stderr); sys.exit(3)
        if n.casefold() not in [m.casefold() for m in names]:
            names.append(n)
    if len(names) > 10:
        print("names: at most 10", file=sys.stderr); sys.exit(3)
path = os.path.join(state, 'access.json')
try:
    with open(path, encoding='utf-8') as f:
        access = json.load(f)
except FileNotFoundError:
    access = {}
except json.JSONDecodeError as e:
    print(f"access.json is not valid JSON: {e}", file=sys.stderr); sys.exit(2)
if not isinstance(access, dict):
    print("access.json is not an object", file=sys.stderr); sys.exit(2)
groups = access.get('groups')
if not isinstance(groups, dict):
    groups = {}
cfgs = [g for g in groups.values() if isinstance(g, dict)]

# DIVE-6701: NAMES_ADD appends to the names already kept (the hire's card name),
# skipping one already there in any case and stopping at 10. Nothing to add
# writes nothing.
seed = os.environ.get('NAMES_ADD', '')
added = []
if seed and not names_set:
    stored_names = access.get('groupsCallNames')
    names = [n for n in stored_names if call_name(n)] if isinstance(stored_names, list) else []
    for n in seed.split(','):
        n = unicodedata.normalize('NFC', ' '.join(n.split()))
        if call_name(n) and len(names) < 10 and n.casefold() not in [m.casefold() for m in names]:
            names.append(n)
            added.append(n)
    names_set = bool(added)

if want or names_set:
    if want:
        on = want == 'name'
        for g in cfgs:
            g['requireMention'] = on
        access['groups'] = groups
        access['groupsRequireMention'] = on
    if replace:
        access['groupsCallNames'] = names
        access['groupsCallNamesComplete'] = True
    elif names_set:
        access['groupsCallNames'] = names
    os.makedirs(state, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=state, prefix='.access.', suffix='.tmp')
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump(access, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)

stored = access.get('groupsRequireMention')
if isinstance(stored, bool):
    on = stored
else:
    on = not (cfgs and all(g.get('requireMention') is False for g in cfgs))
mixed = any((g.get('requireMention') is not False) != on for g in cfgs)
stored_names = access.get('groupsCallNames')
names = [n for n in stored_names if call_name(n)][:10] if isinstance(stored_names, list) else []
# The plugin's callName(): the first run of letters and marks in the bot's
# first_name, 2+ of them.
def bot_word(first):
    run = ''
    for c in first:
        if unicodedata.category(c)[0] in 'LM':
            run += c
        elif run:
            break
    return run if len(run) >= 2 and call_name(run) else None
complete = access.get('groupsCallNamesComplete') is True
known = complete or os.environ.get('BOT_KNOWN') == '1'
if not complete:
    own = bot_word(os.environ.get('BOT_FIRST', ''))
    if own:
        names = [own] + [n for n in names if n.casefold() != own.casefold()]
out = {'answer': 'name' if on else 'every', 'groups': len(cfgs), 'mixed': mixed, 'names': names,
       'namesComplete': known}
if seed:
    out['added'] = added
print(json.dumps(out))
PY
}

# _tg_bot_first_name <name> — the agent's bot display name (getMe first_name),
# or exit 1 when there is no token or Telegram does not answer. The token stays
# on the box.
_tg_bot_first_name() {
  local token resp
  token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "${CONNECTORS_DIR}/telegram-${1}.env" 2>/dev/null | head -1 || true)
  [[ -n "$token" ]] || return 1
  resp=$(curl -sS -m 5 "https://api.telegram.org/bot${token}/getMe" 2>/dev/null) || return 1
  jq -e '.ok == true' >/dev/null 2>&1 <<<"$resp" || return 1
  jq -r '.result.first_name // ""' <<<"$resp"
}

cmd_telegram_access_groups() {
  local name="" answer="" names="" names_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --answer=*) answer="${1#*=}" ;;
      --names=*) names="${1#*=}"; names_set=1 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-access groups <name> [--answer=name|every] [--names=<a,b,...>]"
  case "$answer" in
    ""|name|every) ;;
    *) fail "$E_USAGE" "--answer must be name (when called by name) or every (every message), got '$answer'" ;;
  esac
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  [[ ",$channels," == *",telegram,"* ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-access only applies to telegram"
  local user="agent-${name}"
  local state_dir
  state_dir=$(_tg_access_state_dir "$user" "$type") \
    || fail "$E_VALIDATION" "telegram-access supports claude, codex, grok, pi and antigravity agents (got type=$type)"

  local verb=read
  [[ -n "$answer" || "$names_set" == 1 ]] && verb=write
  [[ -n "$answer" ]] && step "Setting how '$name' answers in groups: $answer"
  [[ "$names_set" == 1 ]] && step "Setting the names '$name' answers to in groups"
  # DIVE-6729: the reply lists the bot-name word too, so it needs the bot's
  # name, unless this write replaces the list.
  local bot_first="" bot_known=0
  if [[ "$names_set" != 1 ]] && bot_first=$(_tg_bot_first_name "$name"); then
    bot_known=1
  fi
  local out
  if ! out=$(sudo -u "$user" env STATE="$state_dir" ANSWER="$answer" NAMES="$names" NAMES_SET="$names_set" \
      BOT_FIRST="$bot_first" BOT_KNOWN="$bot_known" python3 -c "$(_tg_group_answer_py)" 2>&1); then
    fail "$E_VALIDATION" "${out:-telegram access.json ${verb} failed for agent '$name'}"
  fi
  local said
  said=$(jq -r '"\(if .answer == "name" then "when called by name" else "every message" end) (\(.groups) group(s)\(if .mixed then ", some set apart" else "" end))\(if (.names // []) != [] then "; answers to: \(.names | join(", "))" elif .namesComplete then "; answers to no name, only an @mention or a reply" else "" end)"' <<<"$out")
  ok "in groups, '$name' answers: $said" '{name:$n} + $r' --arg n "$name" --argjson r "$out"
}

# DIVE-6701 (lodar 2026-10-21: "need to preseed names from openagent or
# marketplace ... not just tg name"): an agent also answers to its card name in
# its groups, with no hand edit. The card name is `name:` in the OpenAgent
# persona at ~/.claude/persona.yaml (a marketplace or team pack installs its
# persona there under the pack's own name, so a "ceo" seat keeps "Tencha"). It
# is added to "Also answers to" ONCE: a root-owned marker remembers every name
# offered, so a name the owner removed in the app never comes back. (The marker
# is not in access.json: the plugin rewrites that file with only the keys it
# knows.) The seat id is not a name and is never offered. No translations: the
# plugin already matches Latin and Cyrillic spellings and Russian case forms.
# An everyday word ("Max", "Sage") is offered like any other name; the app
# shows it under "Also answers to", where the owner removes it.
_tg_call_names_marker() { printf '%s/call-names-seeded/%s' "$STATE_DIR" "$1"; }

# _tg_call_names_candidate <name> — the card name to offer, or nothing: none on
# the persona, not a name, the seat id, or offered before.
_tg_call_names_candidate() {
  local name="$1"
  PERSONA="${AGENT_HOME_ROOT:-/home}/agent-${name}/.claude/persona.yaml" \
  MARKER="$(_tg_call_names_marker "$name")" SEAT="$name" python3 - 2>/dev/null <<'PY' || true
import os, re, unicodedata
try:
    text = open(os.environ['PERSONA'], encoding='utf-8').read()
except OSError:
    raise SystemExit
name = None
try:
    import yaml
    p = yaml.safe_load(text)
    name = p.get('name') if isinstance(p, dict) else None
except Exception:
    m = re.search(r'^name:\s*["\']?(.+?)["\']?\s*$', text, re.M)
    name = m.group(1) if m else None
if not isinstance(name, str):
    raise SystemExit
name = unicodedata.normalize('NFC', ' '.join(name.split()))
if not name or name.casefold() == os.environ['SEAT'].casefold():
    raise SystemExit
try:
    offered = open(os.environ['MARKER'], encoding='utf-8').read().splitlines()
except OSError:
    offered = []
if name.casefold() not in [o.casefold() for o in offered]:
    print(name)
PY
}

# _tg_call_names_seed <name> <type> — offer the card name once. Prints the name
# when it was added (an owner's own copy of it, in any case, is kept as is).
_tg_call_names_seed() {
  local name="$1" type="$2" state_dir card out marker
  state_dir=$(_tg_access_state_dir "agent-${name}" "$type") || return 0
  card=$(_tg_call_names_candidate "$name")
  [[ -n "$card" ]] || return 0
  out=$(sudo -u "agent-${name}" env STATE="$state_dir" NAMES_ADD="$card" python3 -c "$(_tg_group_answer_py)" 2>/dev/null) || return 1
  marker=$(_tg_call_names_marker "$name")
  mkdir -p "${marker%/*}" && printf '%s\n' "$card" >>"$marker"
  jq -r '.added[]?' <<<"$out"
}

#   5dive agent telegram-access seed-names [<name>]
# Offers each Telegram agent's card name (or just <name>'s) once. Self-update
# runs it, so agents hired before DIVE-6701 get theirs.
cmd_telegram_access_seed_names() {
  local only=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$only" ]] && only="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  ensure_state
  local reg; reg=$(registry_read)
  if [[ -n "$only" ]]; then
    jq -e --arg n "$only" '.agents[$n] != null' <<<"$reg" >/dev/null \
      || fail "$E_NOT_FOUND" "no agent named '$only'"
  fi
  local seeded='[]' checked=0 name type got
  while IFS=$'\t' read -r name type; do
    [[ -n "$name" ]] || continue
    checked=$((checked+1))
    got=$(_tg_call_names_seed "$name" "$type") || { warn "could not seed the names '$name' answers to"; continue; }
    [[ -n "$got" ]] && seeded=$(jq -c --arg n "$name" --arg c "$got" '. + [{name:$n, added:$c}]' <<<"$seeded")
  done < <(jq -r --arg o "$only" '.agents | to_entries[]
      | select($o == "" or .key == $o)
      | select((",\(.value.channels // "none"),") | contains(",telegram,"))
      | "\(.key)\t\(.value.type // "claude")"' <<<"$reg")
  ok "card names seeded: $(jq -r 'if length == 0 then "none new" else map("\(.name) also answers to \(.added)") | join("; ") end' <<<"$seeded") ($checked Telegram agent(s) checked)" \
     '{seeded:$s, checked:$c}' --argjson s "$seeded" --argjson c "$checked"
}

# Drop a pending pairing entry without approving it. The dashboard's inbox
# UI calls this when the operator clicks "Ignore" on a stranger's DM —
# removes the code from access.json's pending map so it stops showing in
# the modal, but does NOT add the senderId to allowFrom. The plugin will
# re-prompt with a fresh code if the same sender messages again.
cmd_telegram_pending_ignore() {
  local name="" code=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  if [[ -z "$name" ]]; then name="$1"
          elif [[ -z "$code" ]]; then code="$1"
          else fail "$E_USAGE" "extra arg: $1"; fi ;;
    esac
    shift
  done
  [[ -n "$name" && -n "$code" ]] \
    || fail "$E_USAGE" "usage: 5dive agent telegram-pending-ignore <name> <code>"
  [[ "$code" =~ ^[A-Za-z0-9]{4,16}$ ]] \
    || fail "$E_VALIDATION" "invalid code format"
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  [[ ",$channels," == *",telegram,"* ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-pending-ignore only applies to telegram"

  local user="agent-${name}"
  local state_dir
  state_dir=$(_tg_access_state_dir "$user" "$type") \
    || fail "$E_VALIDATION" "telegram-pending-ignore supports claude, codex, grok, pi and antigravity agents (got type=$type)"
  local access="${state_dir}/access.json"
  local err
  err=$(sudo -u "$user" env ACCESS="$access" CODE="$code" python3 - <<'PY' 2>&1 >/dev/null
import json, os, sys, tempfile

path = os.environ['ACCESS']
code = os.environ['CODE']

try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    print("access.json not found — nothing pending", file=sys.stderr); sys.exit(2)

pending = data.get('pending') or {}
if code not in pending:
    print(f"code '{code}' is not pending", file=sys.stderr); sys.exit(2)
pending.pop(code, None)
data['pending'] = pending

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
PY
  ) || fail "$E_PAIRING" "${err:-pending-ignore failed}"

  ok "ignored pending pairing '$code' for '$name'" \
     '{name:$n, code:$c, ignored:true}' \
     --arg n "$name" --arg c "$code"
}

# Resolve a Telegram chat reference — either a public @handle or a numeric
# chat id — to its full identity (id, displayName, type, isBot) via the
# agent's own bot token calling getChat. Used by the dashboard's
# add-allowlist UX (paste @handle instead of digging up an id) AND by the
# load-time name enrichment (turn cryptic ids in allowFrom into "Mark ·
# @lodar"). Token stays server-side. Returned id can then be written into
# allowFrom by the regular telegram-access set path — no schema change.
cmd_telegram_resolve_handle() {
  local name="" handle=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -[0-9]*) # leading-minus numeric — a group/channel id, not a flag
        if [[ -z "$name" ]]; then name="$1"
        elif [[ -z "$handle" ]]; then handle="$1"
        else fail "$E_USAGE" "extra arg: $1"; fi ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  if [[ -z "$name" ]]; then name="$1"
          elif [[ -z "$handle" ]]; then handle="$1"
          else fail "$E_USAGE" "extra arg: $1"; fi ;;
    esac
    shift
  done
  [[ -n "$name" && -n "$handle" ]] \
    || fail "$E_USAGE" "usage: 5dive agent telegram-resolve-handle <name> <@handle|chat_id>"
  # Note on arg parsing: a leading '-' on the handle arg (e.g. group id
  # -100123…) would normally match the -* flag glob and error out. The
  # case branch above handles this by accepting -[0-9]* positionally.
  # Normalise: accept "@foo", "foo", or a numeric chat id. Anything else is
  # rejected. Numeric ids may be negative for groups/channels.
  local lookup
  if [[ "$handle" =~ ^-?[0-9]{1,20}$ ]]; then
    # Numeric id — pass through verbatim. getChat accepts these for chats
    # the bot can see (users who've messaged it, groups it's in, public
    # channels). Failures map to NOT_FOUND below.
    lookup="$handle"
  else
    handle="${handle#@}"
    [[ "$handle" =~ ^[A-Za-z][A-Za-z0-9_]{3,31}$ ]] \
      || fail "$E_VALIDATION" "invalid handle (expected 5-32 chars, letters/digits/underscore, or a numeric id)"
    lookup="@${handle}"
  fi
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  case "$type" in
    claude|codex|grok|pi|antigravity) ;;
    *) fail "$E_VALIDATION" "telegram-resolve-handle supports claude, codex, grok, pi and antigravity agents (got type=$type)" ;;
  esac
  [[ ",$channels," == *",telegram,"* ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-resolve-handle only applies to telegram"

  local token_env="${CONNECTORS_DIR}/telegram-${name}.env"
  local token
  token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$token_env" 2>/dev/null | head -1 || true)
  [[ -n "$token" ]] \
    || fail "$E_AUTH_REQUIRED" "no telegram bot token for agent '$name' (expected ${token_env})"

  local resp
  resp=$(curl -sS -m 10 --get \
    --data-urlencode "chat_id=${lookup}" \
    "https://api.telegram.org/bot${token}/getChat" 2>/dev/null || true)
  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    fail "$E_GENERIC" "telegram api unreachable"
  fi
  if [[ "$(jq -r '.ok' <<<"$resp" 2>/dev/null)" != "true" ]]; then
    local desc
    desc=$(jq -r '.description // "telegram api error"' <<<"$resp" 2>/dev/null)
    # getChat returns "Bad Request: chat not found" for unknown handles; map
    # to NOT_FOUND so the dashboard can show a friendly "no such bot" message.
    case "$desc" in
      *"chat not found"*|*"chat_id is empty"*) fail "$E_NOT_FOUND" "telegram: $desc" ;;
      *) fail "$E_GENERIC" "telegram: $desc" ;;
    esac
  fi

  # Per Bot API: getChat returns a Chat object (not User), which has no
  # is_bot field — that lives on User and is only delivered with inbound
  # messages. We derive isBot from the handle convention: Telegram requires
  # all bot usernames to end in "bot" at registration (case-insensitive),
  # so the suffix is a reliable signal for type=private chats.
  #
  # Chat objects: users/bots have first_name + optional last_name + optional
  # username. Groups/supergroups/channels have title + optional username.
  # We read both branches and prefer whichever populates.
  local chat_id chat_type username first_name last_name title
  chat_id=$(jq -r '.result.id // empty'         <<<"$resp")
  chat_type=$(jq -r '.result.type // empty'     <<<"$resp")
  username=$(jq -r '.result.username // empty'  <<<"$resp")
  first_name=$(jq -r '.result.first_name // empty' <<<"$resp")
  last_name=$(jq -r '.result.last_name // empty'   <<<"$resp")
  title=$(jq -r '.result.title // empty'        <<<"$resp")
  [[ -n "$chat_id" ]] \
    || fail "$E_GENERIC" "telegram getChat returned no id"

  local is_bot=false
  if [[ "$chat_type" == "private" ]] && [[ "${username,,}" == *bot ]]; then
    is_bot=true
  fi

  # Compose displayName by chat type. Falls back through: title (group/channel)
  # → first+last (user/bot) → @username → @handle from input → numeric id.
  local display="$title"
  if [[ -z "$display" ]]; then
    display="$first_name"
    [[ -n "$last_name" ]] && display="${display:+$display }${last_name}"
  fi
  if [[ -z "$display" ]]; then
    if [[ -n "$username" ]]; then display="@${username}"
    elif [[ -n "${handle:-}" ]]; then display="@${handle}"
    else display="$chat_id"
    fi
  fi

  local label="$display"
  [[ -n "$username" && "$display" != "@${username}" ]] && label="$display · @${username}"

  ok "resolved $label → $chat_id" \
     '{id:$id, isBot:($b == "true"), type:$t, username:$u, displayName:$d}' \
     --arg id "$chat_id" \
     --arg b  "$is_bot" \
     --arg t  "$chat_type" \
     --arg u  "$username" \
     --arg d  "$display"
}

# ---- DIVE-4698: the pairing that makes a PERSON, not just an allowlist entry ----
#
# WHAT WAS MISSING. `5dive human` (DIVE-3342) gave a person a row — identity on
# each transport, so a gate can name whose phone rings. Nothing ever wrote one:
# `git grep` found no INSERT outside src/cmd_human.sh, so the table was empty on
# this box and, in effect, on every box. Meanwhile pairing DID learn the person —
# it wrote their numeric id into the bot's allowFrom and into the box-wide
# operator allowlist — and then threw the identity away. So the one moment where
# a human demonstrably proves who they are was also the one moment we recorded
# them as an anonymous integer.
#
# THIS IS THE WRITE, and it belongs at pairing approval rather than at create or
# in the UI, because pairing is the only step where the person themselves acted.
#
# ADOPTION IS BY PRESENCE, AND THAT IS WHY THIS IS CAREFUL. `_human_registry_active`
# is `COUNT(*) > 0`: the FIRST row on a box switches every gate send from the
# pre-DIVE-3342 pointer/fan-out path onto registry routing, where an unresolved
# recipient is HELD on the agent rail rather than broadcast. That switch is safe
# at one row and only at one row — `_human_gate_recipient`'s last arm resolves a
# one-person registry to that person unconditionally, so a single-human box (the
# supported configuration, and what every box on the fleet is) routes to exactly
# the person it used to reach. At two rows that arm switches off by design.
#
# So this function:
#   * writes AND links, always together. A row with no `human_agents` edge is
#     the state that resolves to nobody; writing one without the link would be
#     the regression, not the feature.
#   * reuses an existing identity when this telegram id is already on record,
#     rather than minting a second row for the same person (the registry's own
#     one-id-one-person invariant, enforced in cmd_human_set with a CONFLICT).
#   * WARNS when its write is the one that takes the box from one human to two,
#     naming the consequence and the remedy — that is the threshold where an
#     unlinked agent's gate stops reaching anyone, and it must not cross in
#     silence.
#   * is best-effort in every failure mode, exactly like `_operator_record`
#     beside it: a pairing that worked must not be reported as failed because a
#     bookkeeping write did not land.
#
# The id is the person's Telegram @username lowercased when they have one (a
# name a human recognises on `5dive human ls`), else `tg-<numeric id>`. The
# profile read is one getChat through the agent's own bot token and is allowed to
# fail — an id of `tg-<n>` with no display name is a complete, correct record.
#
# RUN IN A SUBSHELL, ALWAYS RETURN 0. `tasks_db_init` and `db` report failure by
# calling `fail`, which EXITS — so on a box whose task store is unreadable this
# helper would have aborted `cmd_pair` after the pairing had already been written
# to access.json, reporting a completed pairing as a failure. Containment here is
# what makes "best-effort" true rather than intended; arm A8 in
# tests/human_at_pairing_unit.sh holds it.
_pair_record_human() {
  ( _pair_record_human_do "$@" ) || true
  return 0
}

_pair_record_human_do() {
  local agent="$1" sender="${2:-}" chat="${3:-}" token="${4:-}"
  [[ -n "$agent" && -n "$sender" ]] || return 0
  valid_telegram_chat_id "$sender" || return 0
  declare -F tasks_db_init >/dev/null 2>&1 || return 0
  tasks_db_init >/dev/null 2>&1 || return 0

  local before hid=""
  before=$(db "SELECT COUNT(*) FROM humans;" 2>/dev/null) || return 0
  [[ "${before:-}" =~ ^[0-9]+$ ]] || return 0

  # Already on record? Then this pairing adds an AGENT to a person we know, and
  # the identity — including a display name someone may have corrected by hand —
  # is left exactly as it is.
  hid=$(db "SELECT id FROM humans WHERE telegram_id=$(sqlq "$sender") LIMIT 1;" 2>/dev/null) || hid=""

  if [[ -z "$hid" ]]; then
    local uname="" first="" last="" display=""
    if [[ -n "$token" ]]; then
      local resp
      resp=$(curl -sS -m 10 --get --data-urlencode "chat_id=${sender}" \
        "https://api.telegram.org/bot${token}/getChat" 2>/dev/null || true)
      if [[ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" == "true" ]]; then
        uname=$(jq -r '.result.username // empty'   <<<"$resp" 2>/dev/null)
        first=$(jq -r '.result.first_name // empty' <<<"$resp" 2>/dev/null)
        last=$(jq -r '.result.last_name // empty'   <<<"$resp" 2>/dev/null)
      fi
    fi
    display="$first"
    [[ -n "$last" ]] && display="${display:+$display }${last}"

    # The slug. A @username is the readable choice; anything that does not fit
    # the registry's own id rule falls back rather than being mangled into a
    # near-miss, because a half-sanitised handle is a second identity for the
    # same person the next time this runs.
    local cand=""
    if [[ -n "$uname" ]]; then
      cand=$(printf '%s' "${uname,,}" | tr -c 'a-z0-9_-' '-')
      [[ "$cand" =~ $_HUMAN_ID_RX ]] || cand=""
    fi
    [[ -n "$cand" ]] || cand="tg-${sender#-}"
    [[ "$cand" =~ $_HUMAN_ID_RX ]] || cand="tg-${sender#-}"
    # That slug may already belong to somebody else (two Telegram accounts, same
    # handle history). Never overwrite another person's row: fall back to the id
    # that cannot collide.
    local taken
    taken=$(db "SELECT COALESCE(telegram_id,'') FROM humans WHERE id=$(sqlq "$cand") LIMIT 1;" 2>/dev/null) || taken=""
    if [[ -n "$taken" && "$taken" != "$sender" ]]; then
      cand="tg-${sender#-}"
    fi
    hid="$cand"
    db "INSERT OR IGNORE INTO humans (id) VALUES ($(sqlq "$hid"));
        UPDATE humans SET telegram_id=$(sqlq "$sender"),
               display_name=COALESCE(display_name, $(sqlq_or_null "$display")),
               updated_at=datetime('now')
         WHERE id=$(sqlq "$hid");" 2>/dev/null || return 0
  fi

  # WRITE AND LINK ARE ONE ACT. Same replace-not-accumulate rule as
  # `human link`: one agent has one human owner.
  db "DELETE FROM human_agents WHERE agent=$(sqlq "$agent");
      INSERT OR IGNORE INTO human_agents (human_id, agent) VALUES ($(sqlq "$hid"), $(sqlq "$agent"));" \
    2>/dev/null || return 0

  local after
  after=$(db "SELECT COUNT(*) FROM humans;" 2>/dev/null) || after="$before"
  audit_log "human auto-record" ok 0 -- "human=$hid" "agent=$agent" "telegram=$sender" \
    "humans_before=$before" "humans_after=$after" "source=pair" 2>/dev/null || true

  if (( before == 0 )); then
    step "Recorded '$hid' as a person on this box and linked them to '$agent' (5dive human ls). Gate delivery now names them instead of guessing from bot traffic."
  elif (( before == 1 && after == 2 )); then
    # THE THRESHOLD. Stated in full because it is the one behaviour change a
    # second pairing makes, and it is invisible otherwise.
    warn "This box now has TWO people on record, so gates are no longer auto-resolved to a single owner: a gate whose agent has no linked human is HELD on the agent rail instead of reaching anyone (DIVE-3342). Check with '5dive human ls' and link the rest: sudo 5dive human link <id> --agent=<name>"
  fi
  return 0
}

# Interactive pairing for a telegram- or discord-enabled claude-family agent.
# Two paths:
#   --code=<code>     classic: user DMs bot, bot replies with "pair <code>",
#                     dashboard pastes that here. We pop <code> from access.json's
#                     pending map, add the senderId to allowFrom, drop
#                     approved/<senderId>.
#   --user-id=<id>    auto: caller already discovered the chat (via
#                     cmd_telegram_discover or out-of-band) and wants to seed
#                     access.json directly. Skips the code roundtrip — writes
#                     allowFrom/approved with the supplied id immediately.
#                     For private DMs chat_id == user_id, so --chat-id is
#                     optional.
#
# Telegram and Discord plugins use the same access.json schema + approved/
# dir layout, so the JSON patch is identical — only the paths, token env
# var, and welcome-delivery mechanism differ.
cmd_pair() {
  local name="" precode="" preuser="" prechat=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --code=*)     precode="${1#--code=}" ;;
      --user-id=*)  preuser="${1#--user-id=}" ;;
      --chat-id=*)  prechat="${1#--chat-id=}" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent pair <name> [--code=<code> | --user-id=<id> [--chat-id=<id>]]"
  if [[ -n "$precode" && -n "$preuser" ]]; then
    fail "$E_USAGE" "--code and --user-id are mutually exclusive"
  fi
  if [[ -n "$preuser" ]]; then
    valid_telegram_chat_id "$preuser" \
      || fail "$E_VALIDATION" "invalid --user-id (numeric, optionally negative)"
    if [[ -n "$prechat" ]]; then
      valid_telegram_chat_id "$prechat" \
        || fail "$E_VALIDATION" "invalid --chat-id (numeric, optionally negative)"
    else
      # Private DM convention: chat_id matches user_id. Groups need explicit --chat-id.
      prechat="$preuser"
    fi
  fi
  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  local type channels
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  # channels is a comma-separable list (DIVE-856) — match membership, not the
  # whole string, so telegram+dashboard (the default claude combo) still pairs.
  # Mirrors the ",telegram," idiom the telegram-* subcommands already use.
  if [[ ",$channels," != *",telegram,"* && ",$channels," != *",discord,"* ]]; then
    fail "$E_VALIDATION" "agent '$name' has channels=$channels — pairing only applies to telegram or discord"
  fi
  # channels may be a comma-separated list (e.g. telegram,dashboard — the default
  # claude combo). Everything below (token env/var, access.json path, welcome,
  # INTRO copy) operates on ONE pairable channel, so pick it with the same
  # membership idiom: telegram takes precedence, else discord. Using the raw
  # $channels string here produced token_var unbound + a bogus
  # channels/telegram,dashboard/ path (DIVE-1767).
  local pair_channel
  if [[ ",$channels," == *",telegram,"* ]]; then
    pair_channel="telegram"
  else
    pair_channel="discord"
  fi
  # cmd_pair applies to claude, codex, grok and antigravity — their
  # telegram/discord plugins use a code-roundtrip (user DMs bot, bot replies with a code,
  # dashboard pastes the code back to seed access.json) and share the same
  # access.json schema + path layout (~/.<type>/channels/<channel>/). openclaw
  # and hermes are token-only: the bot token alone is enough to authorise the
  # agent, and inbound user approvals flow through openclaw's own `pairing`
  # subcommand rather than this code path.
  case "$type" in
    claude|codex|grok|antigravity) ;;
    openclaw|hermes)
      fail "$E_VALIDATION" "type=$type does not use pair codes — approve users with: sudo -u agent-${name} openclaw pairing list" ;;
    *)
      fail "$E_VALIDATION" "pairing only applies to claude, codex, grok and antigravity agents (got type=$type)" ;;
  esac

  local user="agent-${name}"
  local access="/home/${user}/.${type}/channels/${pair_channel}/access.json"
  local token_env token_var
  case "$pair_channel" in
    telegram) token_env="${CONNECTORS_DIR}/telegram-${name}.env"; token_var="TELEGRAM_BOT_TOKEN" ;;
    discord)  token_env="${CONNECTORS_DIR}/discord-${name}.env";  token_var="DISCORD_BOT_TOKEN"  ;;
  esac

  local bot_token
  bot_token=$(sed -n "s/^${token_var}=//p" "$token_env" 2>/dev/null | head -1 || true)
  [[ -n "$bot_token" ]] \
    || fail "$E_AUTH_REQUIRED" "no bot token for agent '$name' — run: sudo 5dive agent config $name set ${pair_channel}.token=<token>"

  # Auto-pair path: caller already knows the (user_id, chat_id) — typically
  # because cmd_telegram_discover surfaced them from getUpdates. Seed
  # access.json directly without waiting for the plugin: the plugin only
  # writes access.json when it has state to persist (a pending pairing
  # entry, etc.), so on a freshly-created agent that's never received a
  # message the file may never appear. Writing it ourselves means the
  # plugin reads our allowFrom on first message — same end state as the
  # code-roundtrip path, no race with a pending entry.
  if [[ -n "$preuser" ]]; then
    local chat_id="$prechat"
    local state_dir="/home/${user}/.${type}/channels/${pair_channel}"
    sudo -u "$user" env SENDER="$preuser" CHAT="$chat_id" STATE="$state_dir" python3 - <<'PY' >&2 \
      || fail "$E_PAIRING" "auto-pair seed failed"
import json, os, tempfile

state = os.environ['STATE']
sender = os.environ['SENDER']
chat = os.environ['CHAT']

os.makedirs(state, mode=0o700, exist_ok=True)
path = os.path.join(state, 'access.json')

try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {"dmPolicy": "pairing", "allowFrom": [], "groups": {}, "pending": {}}

allow = list(data.get('allowFrom') or [])
if sender not in allow:
    allow.append(sender)
data['allowFrom'] = allow

approved = os.path.join(state, 'approved')
os.makedirs(approved, mode=0o700, exist_ok=True)
with open(os.path.join(approved, sender), 'w') as f:
    f.write(chat)

fd, tmp = tempfile.mkstemp(dir=state, prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
print(f"Auto-paired user {sender} (chat {chat})")
PY

    # Remember this operator id box-wide so future agents auto-pair to it
    # (shared operator allowlist — DIVE-320/325).
    _operator_record "$preuser"
    # DIVE-4698: and record the PERSON. Deliberately IN LOCK-STEP with
    # _operator_record rather than derived from it — see the note on
    # _pair_record_human. Best-effort, never fails the pairing.
    _pair_record_human "$name" "$preuser" "$chat_id" "$bot_token" || true
    local welcome_rc=0
    if [[ ",$channels," == *",telegram,"* ]]; then
      send_welcome_message "$chat_id" "$bot_token" "$name" "$type" || welcome_rc=$?
    fi
    # rc 3 = the operator id was auto-allowlisted but has never opened the bot,
    # so the welcome DM 403'd (DIVE-1768). Flag it in the result so the CLI +
    # dashboard show an open-your-bot nudge instead of a clean-but-silent pair.
    if [[ "$welcome_rc" -eq 3 ]]; then
      ok "agent '$name' paired with chat $chat_id, but the welcome DM is pending: open the bot in Telegram and press Start." \
         '{name:$n, channels:$ch, chatId:$c, paired:true, welcomePending:true, nudge:"Open your bot in Telegram and press Start (or send it any message) so it can DM you the welcome."}' \
         --arg n "$name" --arg ch "$channels" --arg c "$chat_id"
    else
      ok "agent '$name' paired with chat $chat_id." \
         '{name:$n, channels:$ch, chatId:$c, paired:true}' \
         --arg n "$name" --arg ch "$channels" --arg c "$chat_id"
    fi
    return
  fi

  # Pair-code path: the bot writes access.json with a pending entry when the
  # user DMs it, so wait for that before trying to consume the code. Cold
  # start can take ~45s on a fresh box (skill preinstalls + plugin install
  # run during agent startup), so wait 90s.
  step "Waiting for $pair_channel plugin on agent '$name'..."
  local waited=0
  for _ in $(seq 1 90); do
    if sudo -u "$user" test -f "$access" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited+1))
  done
  sudo -u "$user" test -f "$access" 2>/dev/null \
    || fail "$E_TIMEOUT" "$access not found after 90s. Is the agent running? (systemctl status 5dive-agent@${name})"

  # Interactive INTRO is only shown to a human at a TTY. JSON callers must
  # pass --code=<code>; the non-precode path is unreachable over the API.
  if [[ -z "$precode" && "$JSON_MODE" == "0" ]]; then
    local app_label example_code
    case "$pair_channel" in
      telegram) app_label="Telegram"; example_code="d13dc3" ;;
      discord)  app_label="Discord";  example_code="a4f2b1" ;;
    esac
    cat >&2 <<INTRO
Open $app_label and send any message to your bot. The bot will reply with
something like:

    Pairing required — run in Claude Code:
    /${pair_channel}:access pair ${example_code}

Paste the reply (or just the code) below.

INTRO
  fi

  # Either prompt interactively (TTY) or consume --code once (exec path).
  local msg code chat_id pair_out="" paired_sender="" tries_left=5
  [[ -n "$precode" ]] && tries_left=1
  while (( tries_left-- > 0 )); do
    if [[ -n "$precode" ]]; then
      msg="$precode"
    else
      read -r -p "Paste: " msg
    fi

    # grep with no match is expected when the user pastes just the bare code.
    code=$(printf '%s' "$msg" \
      | grep -oE 'pair[[:space:]]+[A-Za-z0-9]+' \
      | head -1 | awk '{print $2}' || true)
    if [[ -z "$code" ]]; then
      code=$(printf '%s' "$msg" | tr -d '[:space:]')
    fi
    if [[ ! "$code" =~ ^[A-Za-z0-9]{4,16}$ ]]; then
      warn "Could not extract a pair code from that. Paste the full bot reply or just the code."
      [[ -n "$precode" ]] && fail "$E_VALIDATION" "invalid --code=<code>"
      continue
    fi

    if pair_out=$(sudo -u "$user" env CODE="$code" ACCESS="$access" python3 - <<'PY'
import json, os, sys, tempfile

path = os.environ['ACCESS']
code = os.environ['CODE']

with open(path) as f:
    data = json.load(f)

pending = data.get('pending') or {}
entry = pending.pop(code, None)
if entry is None:
    print(f"Pair code '{code}' is not pending. Message the bot within the "
          "last hour, then retry.", file=sys.stderr)
    sys.exit(2)

sender = str(entry.get('senderId', '')).strip()
chat = str(entry.get('chatId', '')).strip()
if not sender:
    print("Pending entry missing senderId", file=sys.stderr)
    sys.exit(3)

allow = list(data.get('allowFrom') or [])
if sender not in allow:
    allow.append(sender)

data['allowFrom'] = allow
data['pending'] = pending

approved = os.path.join(os.path.dirname(path), 'approved')
os.makedirs(approved, mode=0o700, exist_ok=True)
with open(os.path.join(approved, sender), 'w') as f:
    f.write(chat)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
print(f"Paired user {sender}", file=sys.stderr)
# TWO LINES, sender then chat (DIVE-4698). The chat id alone was enough to send a
# welcome DM; recording the person needs the id that proves WHO pressed Start,
# and it was being printed to stderr for a human to read and then discarded.
# Order is load-bearing: the caller reads line 1 as the sender and line 2 as the
# chat, and the two differ for a group pairing.
print(sender)
print(chat)
PY
    ); then
      # sender on line 1, chat on line 2 (see the python above).
      paired_sender=$(printf '%s\n' "$pair_out" | sed -n '1p')
      chat_id=$(printf '%s\n' "$pair_out" | sed -n '2p')
      if [[ -n "$chat_id" ]]; then
        break
      fi
      warn "Pairing returned no chat id. Try again."
      [[ -n "$precode" ]] && fail "$E_PAIRING" "pairing failed"
    else
      warn "That code isn't pending. Message the bot first, then paste the reply."
      [[ -n "$precode" ]] && fail "$E_PAIRING" "pairing code not pending"
    fi
  done

  [[ -n "${chat_id:-}" ]] || fail "$E_PAIRING" "exhausted retries without a successful pairing"

  # DIVE-4698: the code path learns the person too. Same call, same best-effort
  # posture — and the same box-wide operator memory the auto path already had.
  # A code pairing was the ONE path that never seeded it, so an agent created
  # after a code pairing did not inherit the operator (DIVE-320/325).
  _operator_record "$paired_sender"
  _pair_record_human "$name" "$paired_sender" "$chat_id" "$bot_token" || true

  # Telegram: CLI sends a welcome DM via Telegram's HTTP API.
  # Discord: the plugin's channel server polls approved/<senderId> and sends
  # its own "you're in" DM through the gateway — we don't need (and don't
  # have) a simple HTTP send path here.
  local welcome_rc=0
  if [[ ",$channels," == *",telegram,"* ]]; then
    send_welcome_message "$chat_id" "$bot_token" "$name" || welcome_rc=$?
  fi
  if [[ "$welcome_rc" -eq 3 ]]; then
    ok "agent '$name' paired with chat $chat_id, but the welcome DM is pending: open the bot in Telegram and press Start." \
       '{name:$n, channels:$ch, chatId:$c, paired:true, welcomePending:true, nudge:"Open your bot in Telegram and press Start (or send it any message) so it can DM you the welcome."}' \
       --arg n "$name" --arg ch "$channels" --arg c "$chat_id"
  else
    ok "agent '$name' paired with chat $chat_id." \
       '{name:$n, channels:$ch, chatId:$c, paired:true}' \
       --arg n "$name" --arg ch "$channels" --arg c "$chat_id"
  fi
}

# One-shot "it works" DM after a successful pairing — labelled with the agent
# name + type so users running many bots can tell them apart. Token goes via
# URL-encoded POST body (not argv) so it doesn't show up in `ps`. Copy is
# per-type: claude surfaces its model/effort + voice (Claude-plugin features);
# codex/grok drop those lines since they're Claude-specific (and reading
# claude's settings.local.json would render wrong values for them).
send_welcome_message() {
  local chat_id="$1" bot_token="$2" agent_name="${3:-}" agent_type="${4:-claude}" text

  # FIVE_DOMAIN is the host's public subdomain (e.g. agent.example.com),
  # set during provisioning. Folded into the message only when present so
  # self-hosted boxes / dev VMs don't surface a half-rendered URL.
  local domain=""
  if [[ -r /etc/5dive/provisioning.env ]]; then
    domain=$(sed -n 's/^FIVE_DOMAIN=//p' /etc/5dive/provisioning.env 2>/dev/null | head -1)
  fi
  local live_line=""
  if [[ -n "$domain" ]]; then
    live_line=" Anything you build goes live at https://${domain} ready to share, or ask me to add your own domain."
  fi

  # "'<name>', " when we know the agent name, else "" → "I'm your X agent."
  local name_q=""
  [[ -n "$agent_name" ]] && name_q="'${agent_name}', "

  case "$agent_type" in
    codex|grok|antigravity)
      local kind
      if [[ "$agent_type" == "codex" ]]; then kind="Codex agent (OpenAI Codex)"
      elif [[ "$agent_type" == "antigravity" ]]; then kind="Antigravity agent (Google Gemini)"
      else kind="Grok agent (xAI Grok)"; fi
      text=$(cat <<EOF
👋 We're connected! I'm ${name_q}your ${kind}.

Here 24/7, ready to pick up where we left off. Send text, photos, or files.

Tell me what to build: app, site, bot, report, campaign. Consider it shipped.${live_line} Need more hands? Siblings on demand, working in parallel.
EOF
)
      ;;
    hermes|openclaw)
      # Hermes/OpenClaw are multi-provider runtimes — NEVER call them "Claude"
      # or read the base claude user's model (that's the DIVE bug a customer hit:
      # a Hermes+DeepSeek agent greeted as "Claude agent. Running opus."). Read
      # the REAL provider/model the agent actually signed in with.
      local kind
      [[ "$agent_type" == "hermes" ]] && kind="Hermes agent" || kind="OpenClaw agent"
      local detail provider model plabel
      detail=$(account_signin_detail "$agent_name" "$agent_type" 2>/dev/null || echo '{}')
      provider=$(jq -r '.provider // empty' <<<"$detail" 2>/dev/null || true)
      model=$(jq -r '.model // empty' <<<"$detail" 2>/dev/null || true)
      case "$provider" in
        deepseek)   plabel="DeepSeek" ;;
        anthropic)  plabel="Anthropic" ;;
        openai)     plabel="OpenAI" ;;
        openrouter) plabel="OpenRouter" ;;
        google)     plabel="Google" ;;
        "")         plabel="" ;;
        *)          plabel="${provider^}" ;;
      esac
      local model_line="Model and provider are switchable anytime, just ask."
      if [[ -n "$plabel" ]]; then
        if [[ -n "$model" ]]; then
          model_line="Running ${plabel} (${model}). Switchable anytime, just ask."
        else
          model_line="Running ${plabel}. Switchable anytime, just ask."
        fi
      fi
      text=$(cat <<EOF
👋 We're connected! I'm ${name_q}your ${kind}.

${model_line}

Here 24/7 with memory. Send text, photos, or files.

Tell me what to build: app, site, bot, report, campaign. Consider it shipped.${live_line} Need more hands? Siblings on demand, working in parallel.
EOF
)
      ;;
    *)
      # Read the agent's REAL model/effort from its own settings.json (where the
      # per-agent default — opus — is seeded). Fall back to the base claude user
      # and the legacy shared projects file. Never surface a raw "default"
      # placeholder: if we can't read a concrete model, show a generic line.
      local model="" effort="" f
      local candidates=()
      [[ -n "$agent_name" ]] && candidates+=("/home/agent-${agent_name}/.claude/settings.json")
      candidates+=("/home/claude/.claude/settings.json" "/home/claude/projects/.claude/settings.local.json")
      for f in "${candidates[@]}"; do
        [[ -r "$f" ]] || continue
        model=$(jq -r '.model // empty' "$f" 2>/dev/null)
        effort=$(settings_effective_effort <"$f")
        [[ -n "$model" ]] && break
      done
      local model_line="Model and effort are switchable anytime, just ask."
      if [[ -n "$model" && "$model" != "default" ]]; then
        if [[ -n "$effort" && "$effort" != "default" ]]; then
          model_line="Running ${model} at ${effort} effort. Switchable anytime, just ask."
        else
          model_line="Running ${model}. Switchable anytime, just ask."
        fi
      fi
      text=$(cat <<EOF
👋 We're connected! I'm ${name_q}your Claude agent.

${model_line}

Here 24/7 with memory. Send text, photos, or files, or ask for voice if you'd rather talk.

Tell me what to build: app, site, bot, report, campaign. Consider it shipped.${live_line} Need more hands? Siblings on demand, working in parallel.
EOF
)
      ;;
  esac

  # DIVE-1571: first-contact CONTROL-PLANE welcome. An admin-isolation agent can actually
  # run `company` / `agent create` / `council` / `goal`, so it LEADS with the approved
  # (lodar, 2026-07-20) capability pitch instead of the plain per-type welcome above. A
  # standard/sandboxed agent keeps that per-type text — it must NOT claim powers it lacks.
  # Isolation is read from the agent's env file (written at create/init BEFORE this pair
  # fires). The fallback is FAIL-SAFE: an unreadable/missing isolation defaults to STANDARD
  # (plain welcome), never admin — a mis-seeded/edge agent wrongly telling a user "i can spin
  # up a team/company/council" is worse than an admin agent missing the pitch (main gate,
  # DIVE-1571). No em-dashes (public-copy rule). {name}=agent name; a nameless agent drops
  # the name clause.
  # DIVE-2218: same fallback, said out loud. agent_env_isolation() cannot return
  # empty and cannot invent a tier, so "we could not read it" arrives as an
  # unknown:<reason> and the fail-safe below fires on the PREDICATE rather than on
  # an empty string that a missing file, an unreadable one and a blank field all
  # produce alike. Behaviour here is unchanged, deliberately: this site was never
  # the defect, it is the model the other two were fixed to match.
  local iso
  iso="$(agent_env_isolation "$agent_name")"
  agent_env_isolation_unmeasured "$iso" && iso="standard"
  if [[ "$iso" == "admin" ]]; then
    local intro="hey, i'm your agent, and i'm not alone."
    [[ -n "$agent_name" ]] && intro="hey, i'm ${agent_name}, your agent, and i'm not alone."
    text=$(cat <<EOF
${intro} through 5dive i can spin up a whole team, stand up a company, run a council, or turn a goal into a plan. tell me what you're building, or say 'show me what you can do'.

Here 24/7 with memory. Send text, photos, or files.${live_line}
EOF
)
  fi

  # Send + detect the unreachable-bot case. curl exits 0 on an HTTP 403, so the
  # old `-o /dev/null … || warn` swallowed Telegram's "bot can't initiate
  # conversation with a user" / "chat not found" — the DIVE-1768 bug: an owner
  # auto-paired into access.json (CoS-create / operator auto-pair) who never
  # opened the bot got allowlisted but no welcome and no signal at all. Read the
  # JSON body and branch on Telegram's description so we can surface an
  # actionable open-your-bot nudge instead of a silent warn.
  local resp
  resp=$(curl -sS \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    "https://api.telegram.org/bot${bot_token}/sendMessage" 2>/dev/null)

  if [[ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" == "true" ]]; then
    echo "Sent welcome message to chat ${chat_id}" >&2
    return 0
  fi

  local desc
  desc=$(jq -r '.description // empty' <<<"$resp" 2>/dev/null)
  case "$desc" in
    *"initiate conversation"*|*"can't initiate"*|*"chat not found"*|*"bot was blocked"*)
      # Reachability failure, NOT a real error: the paired chat has never opened
      # this bot (or blocked it), so Telegram forbids the proactive DM. Name the
      # bot precisely via getMe when we can, and tell the owner exactly how to
      # unblock the welcome. Return 3 so callers can flag the pending nudge.
      local bot_user who
      bot_user=$(curl -sS "https://api.telegram.org/bot${bot_token}/getMe" 2>/dev/null \
        | jq -r '.result.username // empty' 2>/dev/null)
      who="your ${agent_name:-agent} bot"
      [[ -n "$bot_user" ]] && who="@${bot_user}"
      warn "Welcome DM not delivered: chat ${chat_id} has not opened ${who} yet (${desc})."
      printf 'ACTION: open Telegram, find %s, and press Start (or send it any message). The welcome arrives once you open the chat.\n' "$who" >&2
      return 3
      ;;
    *)
      warn "Failed to send welcome message${desc:+: ${desc}}"
      return 1
      ;;
  esac
}

# -------- lifecycle / inspection (start, stop, logs, send, clone, stats) --------

