
# -------- 5dive human — human accounts (DIVE-3342) --------
#
# WHY THIS TABLE EXISTS. Until it did, the only representation of a person in
# this system was a numeric telegram chat id sitting inside one bot's
# access.json `allowFrom`. Two consequences followed from that, and both are the
# ticket:
#
#   1. Gate routing selects an AGENT (`routed_reviewer`) and has never been able
#      to name a PERSON. So which human's phone rang was decided downstream, by
#      `_task_send_owner`, from `last-human-chat.json` — whoever most recently
#      DM'd that agent's bot — and with no valid pointer it fanned the alert out
#      to EVERY id in allowFrom.
#   2. Pairing was therefore first-come-first-served: the last human to talk to a
#      bot inherited its gates, because ordinary inbound traffic writes that
#      pointer.
#
# On a box with exactly one paired human those two mechanisms coincide with the
# right answer and nothing misroutes — which is the CURRENT SUPPORTED
# CONFIGURATION and why this shipped (lodar, 2026-08-12: multi-human gates are a
# capability, not a bug). On a customer box running ~8 distinct human chat ids
# across 18 paired agents they do not coincide: their CTO was re-nagged nightly
# for six days on rows he had no relationship to.
#
# WHAT A RECORD HERE IS, AND WHAT IT IS NOT. It is an IDENTITY: one row per
# person, carrying that person's id on each transport (telegram / buzz / discord)
# so a gate can name its owner. It is NOT a grant. A telegram id in this table
# is still only deliverable if it is in the receiving bot's `allowFrom` — the
# registry may narrow the audience for a gate, never widen it. That invariant is
# enforced at the send site (`_task_send_gate_owner`), not here, because that is
# where the bot is known.
#
# ADOPTION IS BY PRESENCE. Zero rows = registry not in use = gate delivery keeps
# its pre-DIVE-3342 behaviour byte for byte, because every existing host is a
# single-human host and must not have its gate delivery changed underneath it.
# The first `5dive human add` is what turns the new routing on.
#
# Reads are open (any agent, no sudo). Writes are root-only, for exactly the
# reason `org set` is (DIVE-2124): this table is trusted input to gate routing,
# so an agent that could write it could choose which person reviews its own
# gates — or, worse, point every gate at a person who is not watching.

_HUMAN_ID_RX='^[a-z0-9][a-z0-9_-]{0,31}$'

_human_usage() {
  cat <<USAGE
5dive human — human accounts: the people who can CLEAR a gate (DIVE-3342)

  5dive human add <id> [--name=<text>] [--telegram=<chat id>]
                       [--buzz=<npub>] [--discord=<id>]     # upsert (alias: set)
  5dive human ls                                            # everyone on record
  5dive human show <id>                                     # ids + owned agents
  5dive human link <id> --agent=<name>                       # they own that agent's gates
  5dive human unlink <id> --agent=<name>
  5dive human owner <agent>                                 # resolved owner of that agent
  5dive human recipient <ident|row id>                      # who a gate on that row pages
  5dive human rm <id>

  READS  (ls/show/owner/recipient) — any agent (group claude), no sudo.
  WRITES (add/set/link/unlink/rm)  — root only. This table is trusted input to
                                     gate delivery, so writing it is a fleet
                                     privilege change, not bookkeeping.
  Add --json for machine output.

  A record here is an IDENTITY, never a grant: a telegram id still has to be in
  the receiving bot's access.json allowFrom to be deliverable. With ZERO rows,
  gate delivery behaves exactly as it did before this table existed.
USAGE
}

cmd_human() {
  [[ $# -gt 0 ]] || { _human_usage; mark_reported; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    add|set)         cmd_human_set "$@" ;;
    ls|list)         cmd_human_ls "$@" ;;
    show)            cmd_human_show "$@" ;;
    link)            cmd_human_link "$@" ;;
    unlink)          cmd_human_link --unlink "$@" ;;
    owner)           cmd_human_owner "$@" ;;
    recipient)       cmd_human_recipient "$@" ;;
    rm|delete)       cmd_human_rm "$@" ;;
    -h|--help|help)  _human_usage ;;
    *) fail "$E_USAGE" "unknown human command: $sub (try: 5dive human --help)" ;;
  esac
}

# Validate the per-transport ids. Deliberately narrow: a malformed telegram id
# is not a cosmetic problem, it is a gate that silently reaches nobody, and the
# send site cannot tell "typo" from "this person is not on this bot".
_human_check_telegram() {
  [[ "$1" =~ ^-?[0-9]{1,20}$ ]] \
    || fail "$E_VALIDATION" "bad telegram id '$1' — a numeric chat id (e.g. 1234567890)"
}
_human_check_buzz() {
  [[ "$1" =~ ^npub1[023456789acdefghjklmnpqrstuvwxyz]{20,80}$ ]] \
    || fail "$E_VALIDATION" "bad buzz id '$1' — an npub1… bech32 pubkey"
}
_human_check_discord() {
  [[ "$1" =~ ^[0-9]{5,25}$ ]] \
    || fail "$E_VALIDATION" "bad discord id '$1' — a numeric snowflake"
}

cmd_human_set() {
  require_root "human add"
  tasks_db_init
  local id="" name="" tg="" buzz="" disc=""
  local name_set=0 tg_set=0 buzz_set=0 disc_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name=*)     name="${1#*=}";  name_set=1 ;;
      --telegram=*) tg="${1#*=}";    tg_set=1 ;;
      --buzz=*)     buzz="${1#*=}";  buzz_set=1 ;;
      --discord=*)  disc="${1#*=}";  disc_set=1 ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            [[ -z "$id" ]] && id="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || fail "$E_USAGE" "usage: 5dive human add <id> [--name=] [--telegram=] [--buzz=] [--discord=]"
  [[ "$id" =~ $_HUMAN_ID_RX ]] \
    || fail "$E_VALIDATION" "bad human id '$id' — lowercase slug, e.g. 'lodar'"
  (( tg_set ))   && [[ -n "$tg" ]]   && _human_check_telegram "$tg"
  (( buzz_set )) && [[ -n "$buzz" ]] && _human_check_buzz "$buzz"
  (( disc_set )) && [[ -n "$disc" ]] && _human_check_discord "$disc"

  # A transport id must identify ONE person. Two rows sharing a telegram id is
  # the registry version of the defect this table exists to end: the resolver
  # would answer with whichever row sorted first, i.e. arbitrarily.
  local clash
  if (( tg_set )) && [[ -n "$tg" ]]; then
    clash=$(db "SELECT id FROM humans WHERE telegram_id=$(sqlq "$tg") AND id<>$(sqlq "$id") LIMIT 1;")
    [[ -z "$clash" ]] || fail "$E_CONFLICT" "telegram id $tg is already on human '$clash'"
  fi
  if (( buzz_set )) && [[ -n "$buzz" ]]; then
    clash=$(db "SELECT id FROM humans WHERE buzz_npub=$(sqlq "$buzz") AND id<>$(sqlq "$id") LIMIT 1;")
    [[ -z "$clash" ]] || fail "$E_CONFLICT" "buzz id is already on human '$clash'"
  fi
  if (( disc_set )) && [[ -n "$disc" ]]; then
    clash=$(db "SELECT id FROM humans WHERE discord_id=$(sqlq "$disc") AND id<>$(sqlq "$id") LIMIT 1;")
    [[ -z "$clash" ]] || fail "$E_CONFLICT" "discord id $disc is already on human '$clash'"
  fi

  local existed; existed=$(db "SELECT 1 FROM humans WHERE id=$(sqlq "$id");")
  db "INSERT OR IGNORE INTO humans (id) VALUES ($(sqlq "$id"));"
  # An explicitly empty value CLEARS that transport (--telegram= drops the id)
  # so a person who leaves a channel can be removed from it without deleting
  # the identity and its agent links.
  (( name_set )) && db "UPDATE humans SET display_name=$(sqlq_or_null "$name"), updated_at=datetime('now') WHERE id=$(sqlq "$id");"
  (( tg_set ))   && db "UPDATE humans SET telegram_id=$(sqlq_or_null "$tg"),    updated_at=datetime('now') WHERE id=$(sqlq "$id");"
  (( buzz_set )) && db "UPDATE humans SET buzz_npub=$(sqlq_or_null "$buzz"),    updated_at=datetime('now') WHERE id=$(sqlq "$id");"
  (( disc_set )) && db "UPDATE humans SET discord_id=$(sqlq_or_null "$disc"),   updated_at=datetime('now') WHERE id=$(sqlq "$id");"

  # by_claimed, not by: SUDO_USER is a forgeable env var on a NOPASSWD host —
  # the same honesty DIVE-2124 forced onto `org set`'s record.
  audit_log "human set" ok 0 -- "human=$id" "new=$([[ -n "$existed" ]] && echo 0 || echo 1)" \
    "telegram=$( (( tg_set )) && echo "${tg:-(cleared)}" || echo '(unchanged)')" \
    "by_claimed=${SUDO_USER:-root}"

  if (( JSON_MODE )); then
    local row; row=$(dbfmt -json "SELECT id, display_name, telegram_id, buzz_npub, discord_id FROM humans WHERE id=$(sqlq "$id");")
    jq -cn --argjson r "$row" '{ok:true, data:($r[0])}'
  else
    ok "human $id recorded$( (( tg_set )) && [[ -n "$tg" ]] && echo " (telegram $tg)")"
  fi
}

cmd_human_ls() {
  tasks_db_init
  [[ $# -eq 0 ]] || fail "$E_USAGE" "usage: 5dive human ls"
  local count; count=$(db "SELECT COUNT(*) FROM humans;")
  if [[ "$count" == "0" ]]; then
    if (( JSON_MODE )); then jq -cn '{ok:true, data:{humans:[], registry_active:false}}'
    else echo "(no human accounts — gate delivery is on its pre-DIVE-3342 path; add one with: sudo 5dive human add <id> --telegram=<chat id>)"; fi
    return 0
  fi
  if (( JSON_MODE )); then
    local rows; rows=$(dbfmt -json "SELECT h.id, h.display_name, h.telegram_id, h.buzz_npub, h.discord_id,
        (SELECT COUNT(*) FROM human_agents ha WHERE ha.human_id=h.id) AS agents
      FROM humans h ORDER BY h.id;")
    [[ -n "$rows" ]] || rows="[]"
    printf '%s' "$rows" | jq -c '{ok:true, data:{humans:., registry_active:true}}'
  else
    dbfmt -table "SELECT h.id, COALESCE(h.display_name,'') AS name, COALESCE(h.telegram_id,'-') AS telegram,
        CASE WHEN h.buzz_npub IS NULL THEN '-' ELSE 'yes' END AS buzz,
        COALESCE(h.discord_id,'-') AS discord,
        (SELECT COUNT(*) FROM human_agents ha WHERE ha.human_id=h.id) AS agents
      FROM humans h ORDER BY h.id;"
  fi
}

cmd_human_show() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive human show <id>"
  local id="$1"
  local exists; exists=$(db "SELECT 1 FROM humans WHERE id=$(sqlq "$id");")
  [[ -n "$exists" ]] || fail "$E_NOT_FOUND" "no human account '$id'"
  if (( JSON_MODE )); then
    local self agents
    self=$(dbfmt -json "SELECT id, display_name, telegram_id, buzz_npub, discord_id, created_at, updated_at FROM humans WHERE id=$(sqlq "$id");")
    agents=$(dbfmt -json "SELECT agent FROM human_agents WHERE human_id=$(sqlq "$id") ORDER BY agent;")
    [[ -n "$agents" ]] || agents="[]"
    jq -cn --argjson s "$self" --argjson a "$agents" '{ok:true, data:($s[0] + {agents:($a|map(.agent))})}'
  else
    dbfmt -line "SELECT id, COALESCE(display_name,'') AS display_name, COALESCE(telegram_id,'(none)') AS telegram_id,
        COALESCE(buzz_npub,'(none)') AS buzz_npub, COALESCE(discord_id,'(none)') AS discord_id FROM humans WHERE id=$(sqlq "$id");"
    local ags; ags=$(db "SELECT agent FROM human_agents WHERE human_id=$(sqlq "$id") ORDER BY agent;")
    echo
    if [[ -n "$ags" ]]; then echo "owns the gates of:"; printf '%s\n' "$ags" | indent2
    else echo "owns the gates of: (no agents linked — link one with: sudo 5dive human link $id --agent=<name>)"; fi
  fi
}

cmd_human_link() {
  local unlink=0
  [[ "${1:-}" == "--unlink" ]] && { unlink=1; shift; }
  require_root "human link"
  tasks_db_init
  local id="" agent=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent=*) agent="${1#*=}" ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         [[ -z "$id" ]] && id="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$id" && -n "$agent" ]] \
    || fail "$E_USAGE" "usage: 5dive human $( (( unlink )) && echo unlink || echo link) <id> --agent=<name>"
  valid_sender_label "$agent" || fail "$E_VALIDATION" "bad agent name '$agent'"
  local exists; exists=$(db "SELECT 1 FROM humans WHERE id=$(sqlq "$id");")
  [[ -n "$exists" ]] || fail "$E_NOT_FOUND" "no human account '$id' (add it first: sudo 5dive human add $id)"

  if (( unlink )); then
    db "DELETE FROM human_agents WHERE human_id=$(sqlq "$id") AND agent=$(sqlq "$agent");"
    audit_log "human unlink" ok 0 -- "human=$id" "agent=$agent" "by_claimed=${SUDO_USER:-root}"
    ok "$id no longer owns ${agent}'s gates"
    return 0
  fi
  # One agent, one human owner. Two owners on one agent is the arbitrary-recipient
  # defect again, so the link REPLACES rather than accumulating.
  local prev; prev=$(db "SELECT human_id FROM human_agents WHERE agent=$(sqlq "$agent") AND human_id<>$(sqlq "$id") LIMIT 1;")
  db "DELETE FROM human_agents WHERE agent=$(sqlq "$agent");
      INSERT OR IGNORE INTO human_agents (human_id, agent) VALUES ($(sqlq "$id"), $(sqlq "$agent"));"
  audit_log "human link" ok 0 -- "human=$id" "agent=$agent" "replaced=${prev:-none}" "by_claimed=${SUDO_USER:-root}"
  if (( JSON_MODE )); then
    jq -cn --arg h "$id" --arg a "$agent" --arg p "$prev" \
      '{ok:true, data:{human:$h, agent:$a, replaced:(($p|select(length>0)) // null)}}'
  else
    ok "$id owns ${agent}'s gates${prev:+ (was $prev)}"
  fi
}

cmd_human_owner() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive human owner <agent>"
  local agent="$1" who
  valid_sender_label "$agent" || fail "$E_VALIDATION" "bad agent name '$agent'"
  who=$(_human_owner_of_agent "$agent")
  if (( JSON_MODE )); then
    jq -cn --arg a "$agent" --arg w "$who" \
      '{ok:true, data:{agent:$a, human:(($w|select(length>0)) // null)}}'
  elif [[ -n "$who" ]]; then
    ok "$agent -> $who"
  else
    ok "$agent -> (no human owner resolves; a gate that needs a person stays on the agent rail)"
  fi
}

# The observability the fix needs to be checkable by a person: for one gate row,
# print the human it would page and WHY that human (or why none). This is the
# verb to reach for when a customer asks "who is this bot going to wake up".
cmd_human_recipient() {
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive human recipient <ident|row id>"
  local key="$1" numid
  if [[ "$key" =~ ^[0-9]+$ ]]; then numid="$key"; else numid=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$key");"); fi
  [[ -n "$numid" ]] || fail "$E_NOT_FOUND" "no task '$key'"
  local who reason
  # Not `who=$(...)`: the basis is set by the resolver and a subshell would drop it.
  _human_gate_recipient "$numid" >/dev/null
  who="$HUMAN_RECIPIENT_ID"; reason="$HUMAN_RECIPIENT_BASIS"
  if (( JSON_MODE )); then
    jq -cn --arg h "$who" --arg b "$reason" --arg i "$numid" \
      '{ok:true, data:{task_id:($i|tonumber), human:(($h|select(length>0)) // null), basis:$b}}'
  elif [[ -n "$who" ]]; then
    ok "$who (via ${reason})"
  else
    ok "(no human recipient: ${reason}) — a gate here stays on the agent rail rather than paging the allowlist"
  fi
}

cmd_human_rm() {
  require_root "human rm"
  tasks_db_init
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive human rm <id>"
  local id="$1"
  local exists; exists=$(db "SELECT 1 FROM humans WHERE id=$(sqlq "$id");")
  [[ -n "$exists" ]] || fail "$E_NOT_FOUND" "no human account '$id'"
  # Gates already stamped with this owner keep the stamp — it is the historical
  # record of who the gate was routed to, and rewriting it would erase the trail.
  # Live resolution simply stops matching it (the resolver requires a live row).
  local stamped; stamped=$(db "SELECT COUNT(*) FROM tasks WHERE human_owner=$(sqlq "$id") AND need_type IS NOT NULL AND need_answered_at IS NULL;")
  db "DELETE FROM human_agents WHERE human_id=$(sqlq "$id"); DELETE FROM humans WHERE id=$(sqlq "$id");"
  audit_log "human rm" ok 0 -- "human=$id" "open_gates_stamped=${stamped:-0}" "by_claimed=${SUDO_USER:-root}"
  ok "removed human $id${stamped:+ — $stamped open gate(s) still name it; they now re-resolve}"
}
