# -------- 5dive task — notify --------
#
# Split out of src/cmd_task.sh (DIVE-3278): gate NOTIFICATION: channel resolution, the escalation chain, Telegram delivery
# of a filed gate, the reply markup, and button retirement.
#
# Concatenated into the single-file bundle by build.sh, and sourced by
# src/cmd_task.sh when the split tree is used (tests source src/cmd_task.sh).
# Function definitions only — never execute this file directly.
# _task_owner_channel — resolve the filing agent's bot token + the per-type
# access.json that holds the paired human's DM/group targets. Sets globals
# TASK_CH_TOKEN / TASK_CH_ACCESS / TASK_CH_TYPE and returns 0 on success, 1 if
# anything is missing (so callers `_task_owner_channel || return 0` to stay
# best-effort — a missing channel must never fail a committed DB write). Works
# whether run directly as agent-<name> (common — task verbs need no sudo) or via
# sudo (resolved like task_actor; token from the group-claude-readable connector
# file or an inherited env var). Shared by task_need_notify + _task_close_notify.
TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE=""
# DIVE-1927: set by task_need_notify when the alert was escalated off an unpaired
# filer, so the message can name whose ask the recipient is looking at.
TASK_NOTIFY_ESCALATED_FROM=""
# DIVE-1927: why the alert could not be delivered, so the caller's hard failure
# states what we actually know rather than the worst-sounding of the two causes.
TASK_NOTIFY_FAIL_REASON=""
# DIVE-1968: the privileged re-send's stderr, kept so the parent can name WHY it
# failed instead of only THAT it did. Empty when it succeeded or was never run.
TASK_GATE_ESCALATE_ERR=""
# DIVE-891: the by-NAME half of the resolution, split out so the heartbeat's
# gate-TTL sweep (which runs as root from cron — no sudo chain, no agent-* USER)
# can resolve a FILING AGENT's channel per gate row instead of from the caller.
_task_agent_channel() {
  # DIVE-2073: TASK_CH_AGENT is set HERE, not only in _task_chain_channel. This
  # is the one resolver every send path funnels through (own channel, by-name
  # privileged, chain walk), so it is the only place that can name WHOSE bot
  # carried a message on all of them. Without it the delivery row could say a
  # message_id but never which bot's id space it lives in — and since each bot
  # holds its OWN conversation with the same human, ids from different bots are
  # not comparable. That is exactly why DIVE-1927's residual 2 could not be
  # discharged from the log alone.
  TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE="" TASK_CH_AGENT=""
  local name="$1"
  [[ -n "$name" ]] || return 1
  local token="" token_file="${CONNECTORS_DIR}/telegram-${name}.env"
  [[ -r "$token_file" ]] && token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$token_file" | head -1)
  [[ -z "$token" ]] && token="${TELEGRAM_BOT_TOKEN:-}"
  [[ -n "$token" ]] || return 1
  local t d
  for t in claude codex grok antigravity; do
    d=$(_tg_access_state_dir "agent-${name}" "$t") || continue
    if [[ -r "${d}/access.json" ]]; then
      TASK_CH_TOKEN="$token" TASK_CH_ACCESS="${d}/access.json" TASK_CH_TYPE="$t" TASK_CH_AGENT="$name"
      return 0
    fi
  done
  return 1
}

_task_owner_channel() {
  local name="" s
  s=$(auto_sender_from_sudo)
  if [[ -n "$s" ]]; then
    name="$s"
  else
    local u="${USER:-$(id -un 2>/dev/null)}"
    [[ "$u" == agent-* ]] && name="${u#agent-}"
  fi
  _task_agent_channel "$name"
}

# DIVE-1927: is <name> PAIRED AT ALL — independent of whether THIS uid may read
# its access.json? Every agent's channel dir is 0700 and its access.json 0600, so
# a sibling agent can NEVER read a peer's pairing state; the parent .../channels
# dir is 0755 root:root, so a bare -d probe still answers. Pairing = a resolvable
# bot token (connector files are group-claude readable) AND an existing per-type
# channel dir. This is the only honest way to tell "nobody is reachable" (the gate
# must then fail LOUDLY) apart from "reachable, but I lack the privilege to read
# the target" (re-run the send as root). Getting that distinction wrong is exactly
# how DIVE-1243's lead fallback degraded into a silent no-op: it probed
# readability, read Permission-denied as "unpaired", and returned OK.
# Three-valued ON PURPOSE: 0 = paired, 1 = PROVABLY not paired, 2 = undetermined
# (we are blind, because something we needed to look at exists but is forbidden,
# or sits behind a directory we may not search). Only a PROVABLE 1 may be treated
# as "this ask can reach nobody" — an undetermined 2 must be handled like paired,
# i.e. escalated to a privileged sender who can actually see.
#
# The three-valued return is the whole point. A boolean here would reintroduce the
# absent-vs-forbidden conflation ONE LAYER OVER: the connector env is currently
# 0640 root:claude and every agent is in group claude, so a plain `-r` works today
# — but the day a connector file is tightened to 0600, or an agent lands outside
# group claude, an unreadable token would read as "unpaired". Before this fix that
# would have cost a delayed gate. WITH the fail-closed `task need` it would REFUSE
# a gate on a chain that is perfectly fine. Absence and denial must never share an
# answer in a probe whose false-negative refuses work. (Found by main reviewing
# PR #160 — the second instance of the exact mechanism the fix exists to remove,
# inside the fix. Third instance the same night: DIVE-1929, where
# os.path.exists() answers False under a mode-700 home.)
_task_agent_paired() {
  local name="${1:-}"; [[ -n "$name" ]] || return 1
  local blind=0 token="" token_file="${CONNECTORS_DIR}/telegram-${name}.env"
  if [[ -r "$token_file" ]]; then
    # Readable and genuinely tokenless is the one case that PROVES unpaired.
    token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$token_file" | head -1)
    [[ -n "$token" ]] || return 1
  elif [[ -e "$token_file" ]]; then
    blind=1                                   # exists, forbidden -> not evidence
  elif [[ ! -d "$CONNECTORS_DIR" || ! -x "$CONNECTORS_DIR" ]]; then
    blind=1                                   # can't even search the dir -> ditto
  else
    return 1                                  # dir searchable, file really absent
  fi

  local t d
  for t in claude codex grok antigravity; do
    d=$(_tg_access_state_dir "agent-${name}" "$t") || continue
    [[ -d "$d" ]] || continue
    (( blind )) && return 2
    return 0
  done
  # No channel dir found. Same question again: absence, or blindness? A home we
  # may not traverse cannot tell us anything about what is inside it.
  local home="/home/agent-${name}"
  [[ -d "$home" && -x "$home" ]] || return 2
  (( blind )) && return 2
  return 1
}

# DIVE-1968: WHY is this filer's chain empty? Three unrelated causes produced one
# indistinguishable message, and that is why 28 real rows sat unreadable underneath
# ~840 fixture ones. Naming the shape in the detail is what makes the acceptance
# criterion ("zero error rows on production-store idents") checkable at all: a row
# that cannot say what happened cannot be triaged, only counted.
#   absent-from-org  the filer has NO agents_org row at all. It can file gates while
#                    being outside the structure the rail walks, and nothing
#                    reconciles the two. Largest real shape measured: 13 of 28.
#   top-of-org       the filer IS in the chart and has no manager. Real, and 1 of 28.
#   no-chain         in the chart, has a manager, chain still came back empty — the
#                    shape neither the ticket nor the diagnosis named. 13 of 28, and
#                    it is the reason this labelling landed BEFORE any rail fix.
_task_filer_chain_shape() {
  local filer="${1:-}" n rt
  [[ -n "$filer" ]] || { printf 'no-filer'; return 0; }
  n=$(db "SELECT COUNT(*) FROM agents_org WHERE name=$(sqlq "$filer");" 2>/dev/null) || n=""
  [[ -n "$n" ]] || { printf 'org-unreadable'; return 0; }   # a failed read is NOT an empty org
  [[ "$n" == "0" ]] && { printf 'absent-from-org'; return 0; }
  rt=$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$filer") LIMIT 1;" 2>/dev/null) || rt=""
  [[ -z "$rt" ]] && { printf 'top-of-org'; return 0; }
  printf 'no-chain'
}

# DIVE-1927: emit the escalation chain for <filer> — every candidate recipient
# ABOVE it, nearest manager first, ending with the coordinator. Cycle-guarded and
# depth-capped so a reports_to loop can never spin. The filer itself is never
# emitted. This is the multi-hop generalisation of _gate_route_reviewer (which
# stops at ONE hop + coordinator): if dev3 -> main -> olivia and main is unpaired,
# the ask still has to reach olivia rather than dying at the first miss.
_task_escalation_chain() {
  local filer="${1:-}" seen=$'\n' hops=0 nxt cur
  cur="$filer"
  [[ -n "$filer" ]] || return 0
  while (( hops < 8 )); do
    nxt=$(db "SELECT COALESCE(reports_to,'') FROM agents_org WHERE name=$(sqlq "$cur") LIMIT 1;" 2>/dev/null) || nxt=""
    [[ -n "$nxt" && "$nxt" != "$filer" ]] || break
    [[ "$seen" == *$'\n'"$nxt"$'\n'* ]] && break
    seen+="${nxt}"$'\n'
    printf '%s\n' "$nxt"
    cur="$nxt"; hops=$((hops+1))
  done
  local coord; coord=$(_task_resolve_coordinator)
  [[ -n "$coord" && "$coord" != "$filer" && "$seen" != *$'\n'"$coord"$'\n'* ]] && printf '%s\n' "$coord"
  return 0
}

# DIVE-1927 (review round 2): does this DEPLOYMENT deliver gates by channel at
# all? A box with no channel anywhere — solo OSS, fresh install, CI, any headless
# environment — answers gates on the dashboard "Needs you" card or with
# `5dive task answer`, and there an unnotified gate is the NORMAL mode rather
# than a failure. This is the discriminator for the hard refusal: only where
# notification IS the delivery mechanism does "reached nobody" mean a human will
# never see the ask.
# Deliberately fails PERMISSIVE: an unreadable/absent connector dir answers
# "no channels", i.e. never refuse. That is the same absent-vs-forbidden
# ambiguity as everywhere else on this page, pointed at the safe side on purpose
# — a probe whose false negative REFUSES work must never guess in that direction.
_task_deployment_has_channels() {
  local f
  for f in "${CONNECTORS_DIR}"/telegram-*.env; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

# DIVE-1927: resolve the nearest channel up the chain that THIS uid can actually
# read. Sets TASK_CH_* (the send target) and TASK_CH_AGENT (whose it is); returns
# 1 if none is readable from here. It must NEVER be called in a command
# substitution — that runs it in a subshell and the TASK_CH_* it resolved die
# with it, leaving the caller to "successfully" send with an empty token to an
# empty access file. Hence the name comes back in a GLOBAL, not on stdout.
TASK_CH_AGENT=""
_task_chain_channel() {
  local filer="$1" c
  local -a chain=()
  TASK_CH_AGENT=""
  mapfile -t chain < <(_task_escalation_chain "$filer")
  for c in "${chain[@]}"; do
    [[ -n "$c" ]] || continue
    if _task_agent_channel "$c"; then TASK_CH_AGENT="$c"; return 0; fi
  done
  return 1
}

# DIVE-1927: is anyone up the chain PAIRED (i.e. deliverable by a privileged
# run, even though this uid can't read their access.json)? Echoes the first such
# agent. Empty + rc 1 means the ask is genuinely undeliverable to any human.
_task_chain_paired() {
  local filer="$1" c rc
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    _task_agent_paired "$c"; rc=$?
    # 0 paired, 2 undetermined — both mean "a privileged sender may well reach
    # this agent", and only an all-1 chain licenses refusing the gate.
    [[ "$rc" == "0" || "$rc" == "2" ]] && { printf '%s' "$c"; return 0; }
  done < <(_task_escalation_chain "$filer")
  return 1
}

# DIVE-1927: re-run this gate's alert as root, which can read every agent's
# access.json. Agents carry NOPASSWD sudo for the 5dive binary, so this is the
# one privilege step that turns a reachable-but-unreadable manager channel into a
# real delivery. The raw human nonce goes over STDIN (the DIVE-880 `-` sentinel),
# never argv, so it can't leak through ps/audit. Returns the child's status:
# 0 delivered, non-zero not delivered (the caller then fails loudly).
_task_gate_escalate_via_sudo() {
  local ident="$1" nonce="${2:-}"
  command -v sudo >/dev/null 2>&1 || return 1
  # MUST be the installed path: agents' sudoers grants NOPASSWD for exactly
  # `/usr/local/bin/5dive` (and `/usr/local/bin/5dive *`). A `command -v` result
  # pointing at a worktree/dev build would be REFUSED by sudo, so the escalation
  # would fail for a reason that has nothing to do with the channel.
  local cli=/usr/local/bin/5dive
  [[ -x "$cli" ]] || cli=$(command -v 5dive 2>/dev/null) || return 1
  [[ -n "$cli" ]] || return 1
  # DIVE-1968: KEEP THE CHILD'S REASON. This used to be `>/dev/null 2>&1`, so the
  # parent could only ever report "privileged re-send FAILED" with no cause, and a
  # whole diagnosis round went into deciding whether sudo had refused the
  # invocation or gate-escalate had returned non-zero for its own reason — a
  # distinction the child prints and we were throwing away. Stdout stays discarded
  # (it is the ok/JSON envelope); stderr is captured into a global the caller names
  # in its warn and its audit row. Truncated because it rides a log line.
  TASK_GATE_ESCALATE_ERR=""
  local _err _rc=0
  _err=$(printf '%s' "$nonce" | sudo -n "$cli" task gate-escalate "$ident" --nonce=- 2>&1 >/dev/null) || _rc=$?
  TASK_GATE_ESCALATE_ERR="${_err//$'\n'/ }"
  TASK_GATE_ESCALATE_ERR="${TASK_GATE_ESCALATE_ERR:0:300}"
  return $_rc
}

# DIVE-1927: `5dive task gate-escalate <ident> [--nonce=-]` — internal, root-only.
# Re-send an ALREADY-FILED, still-pending gate's alert from a privileged context
# so the escalation chain can be read. It mints nothing and decides nothing: the
# recipient, text, options and tier all come from the stored row, so the only
# thing this verb can do is deliver an ask that is already on the board to the
# human it was always meant for. Refuses anything that is not a live gate.
# Undocumented in `task --help` (not an operator verb) but usable by hand for
# recovery. Exit 0 = delivered, non-zero = not delivered.
cmd_task_gate_escalate() {
  tasks_db_init
  local ident_arg="" nonce=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --nonce=-) IFS= read -r nonce || true ;;
      --nonce=*) fail "$E_USAGE" "--nonce accepts only '-' (read from stdin)" ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         [[ -z "$ident_arg" ]] && ident_arg="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$ident_arg" ]] || fail "$E_USAGE" "usage: 5dive task gate-escalate <ident>"
  # DIVE-1968: through the `_gate_is_root` seam (already the convention in this file,
  # see the DIVE-1401 withdraw path) rather than reading $EUID inline. $EUID is
  # READONLY in bash, so an inline test makes this verb unreachable from a unit
  # harness — and an unreachable verb is how the hardcoded audit code below survived
  # since DIVE-1927. Same lesson as the rest of this ticket: a check nobody can
  # exercise is a check nobody can trust.
  _gate_is_root || fail "$E_PERMISSION" "task gate-escalate must run as root (it reads other agents' channel state)"

  resolve_task_id "$ident_arg"; local id="$RESOLVED_TASK_ID" ident="$RESOLVED_TASK_IDENT"
  # DIVE-1945: the filer is the gate's FILER-OF-RECORD (gate_filed_by, stamped by
  # cmd_task_need from the acting agent), NOT the task's created_by. They differ
  # whenever one agent files a gate on another agent's task — and then this walked
  # the CREATOR's branch of the org chart and the alert read "filed by <creator>
  # (no channel of its own)", wrong attribution about an agent that may well have
  # one. Same bug DIVE-1927 fixed on the `task need` path via TASK_GATE_FILER,
  # surviving here because this process cannot see that env var: it is a separate
  # privileged run driven by the re-nag, so the filer has to come off the ROW.
  # created_by remains the fallback for gates filed before the column existed.
  local grow
  grow=$(db "SELECT COALESCE(need_type,'')||x'1f'||COALESCE(ask,'')||x'1f'||COALESCE(need_options,'')||x'1f'||
                    COALESCE(recommend,'')||x'1f'||COALESCE(secret_key,'')||x'1f'||COALESCE(connector,'')||x'1f'||
                    COALESCE(NULLIF(gate_filed_by,''),NULLIF(created_by,''),assignee,'')
             FROM tasks
             WHERE id=${id} AND need_type IS NOT NULL AND need_answered_at IS NULL
               AND status NOT IN ('done','cancelled');")
  [[ -n "$grow" ]] || fail "$E_CONFLICT" "$ident is not a pending gate — nothing to escalate"
  local nt ask opts rec skey conn filer
  IFS=$'\x1f' read -r nt ask opts rec skey conn filer <<<"$grow"

  # TASK_GATE_ESCALATING stops the recursion: this IS the privileged run, so a
  # miss here must fall through to the loud failure, never re-sudo itself.
  local rc=0
  TASK_SEND_DELIVERED=0
  TASK_GATE_ESCALATING=1 TASK_GATE_FILER="$filer" \
    task_need_notify "$ident" "$nt" "$ask" "$opts" "$rec" "$skey" "$conn" "$nonce" "" || rc=$?
  # A resolved channel is NOT a delivery. task_need_notify is best-effort about
  # the actual Bot API call, so this verb — whose entire contract is "the ask
  # reached a human" — asserts the CONFIRMED receipt, not the attempt. Reporting
  # ok on an unconfirmed send would rebuild the exact bug this fixes one layer up.
  [[ "$rc" == "0" && "${TASK_SEND_DELIVERED:-0}" != "1" ]] && rc=2
  if [[ "$rc" == "0" ]]; then
    # DIVE-2054: task-store re-send outcome — fenced.
    _task_store_audit_log "task gate-escalate" "ok" 0 -- "task=$ident" "type=$nt" "filer=${filer:-unknown}" || true
    ok "$ident gate alert re-sent from a privileged context (filer ${filer:-unknown} is unpaired)" \
       '{ident:$id, escalated:true, filer:$f}' --arg id "$ident" --arg f "$filer"
    return 0
  fi
  # DIVE-1968: the code was a hardcoded `1`, so the ONE durable record of this verb
  # could not distinguish rc=2 (a channel resolved, the Bot API send was simply not
  # confirmed) from a genuine no-recipient failure — and the message below asserts
  # the second reading whichever happened. Record the real rc, and say which of the
  # two it was, because "zero error rows after ship" is only checkable if the rows
  # can say what happened.
  # DIVE-2054: same reasoning as the "ok" branch above — fenced.
  _task_store_audit_log "task gate-escalate" "error" "$rc" -- "task=$ident" "type=$nt" "filer=${filer:-unknown}" "rc=$rc" || true
  if [[ "$rc" == "2" ]]; then
    fail "$E_AUTH_REQUIRED" "$ident: a channel resolved above ${filer:-the filer} but the send was not confirmed — delivery UNVERIFIED, not refused"
  fi
  fail "$E_AUTH_REQUIRED" "$ident could not be delivered — no paired channel for ${filer:-the filer} or anyone above it"
}

# DIVE-1305: verify a chat_id is the paired human's OWN verified DM — i.e. it is
# listed in the bot's access.json `allowFrom` (the users who /started the bot and
# were approved). This is the trust anchor for the "go with recs from your own
# channel" clear: the plugin only ever passes a chat_id it already matched against
# access.json, and we RE-verify here so the CLI never trusts the flag blindly.
# DMs only (allowFrom) — groups (.groups, negative ids) are multi-member and a
# weaker identity, so a group message is NOT accepted as one human's proof. The
# caller's own bot channel is resolved via _task_owner_channel (SUDO_UID -> agent
# -> that agent's access.json), so an agent can only ever assert ITS OWN paired
# human, never another bot's. Returns 0 when the chat verifies. Scope guard: this
# proof clears only tier<2 gates (enforced at the call site, cmd_task_answer).
_gate_channel_proof_ok() {
  local chat="$1"
  [[ -n "$chat" ]] || return 1
  # Numeric chat id only (a DM id is a positive integer) — rejects junk / any
  # attempt to smuggle a jq filter or a negative group id through the flag.
  [[ "$chat" =~ ^[0-9]+$ ]] || return 1
  _task_owner_channel || return 1
  [[ -n "$TASK_CH_ACCESS" && -r "$TASK_CH_ACCESS" ]] || return 1
  jq -e --arg c "$chat" '(.allowFrom // []) | index($c) != null' "$TASK_CH_ACCESS" >/dev/null 2>&1
}

# DIVE-2412: the Bot API seam for a channel citation, isolated in ONE function so
# a unit harness can drive every branch of the verifier below with no network and
# no bot token. Every attestation call goes through here.
_gate_channel_api() { # <token> <method> [curl -d args...]
  local token="$1" method="$2"; shift 2
  curl -sS --max-time 15 "https://api.telegram.org/bot${token}/${method}" "$@" 2>/dev/null
}

# DIVE-2412 (DIVE-2382 fix #4): CITED-MESSAGE channel proof — the evidence form a
# TIER-2 gate accepts, so a decision the human already made in prose clears
# WITHOUT re-entering it as a button tap (the rubber-stamp lodar refused
# 2026-07-29 01:06).
#
# WHY THE DIVE-1305 FORM IS NOT ENOUGH HERE, said plainly because the ticket's
# premise reads the other way: _gate_channel_proof_ok proves the cited CHAT is the
# paired human's own verified DM. It does NOT prove the human said anything. The
# chat id is a number the calling agent's own session already knows, so on its own
# it is exactly the agent-relayed assertion this must refuse ("he told me").
# At tier<2 that weaker bar is lodar's deliberate scope; at tier 2 it is not
# evidence, so tier 2 requires a CITATION on top: the message_id of the human's
# OWN message, attested by TELEGRAM rather than by us.
#
# THE ATTESTATION IS REMOTE, which is the entire reason the caller cannot forge
# it. The plugin and the agent share a unix user, so NO local artifact separates
# them — same uid, same cgroup, same files (community/wiki/
# the-dashboard-t2-clear-and-the-t2-forge-are-one-path.md). What an agent cannot do
# is make Telegram's servers claim a message exists that does not: forwardMessage
# on the cited id returns the message's forward_origin (who really sent it) and its
# original date. The forwarded echo is deleted immediately — this is a probe, not a
# post.
#
# FOUR CONDITIONS, all required, each with its own refusal reason:
#   1. the chat is the paired human's verified DM (the DIVE-1305 anchor),
#   2. Telegram confirms the cited message EXISTS in that chat,
#   3. its forward origin is a USER whose id is that chat's human — a bot's own
#      message and a third party both refuse (in a DM the human's user id IS the
#      chat id), and a privacy-HIDDEN origin refuses because it attests nobody,
#   4. it is FRESH (<= 3600s, a HARDCODED ceiling — see below) and it NAMES BOTH
#      this task's ident and this answer, so neither a stale "yes" nor a live one
#      about another gate can be replayed onto this one.
# Anything unresolvable — no token, no response, malformed JSON — REFUSES. The
# ticket's rule is explicit and is the whole boundary: if a verified-session
# message cannot be told apart from an agent's report of one, refuse.
#
# THE FRESHNESS BOUND IS NOT THE CALLER'S TO SET, and the shared-value replay is
# closed by BINDING, not by the window. Iteration 1 shipped both the other way
# round and olivia's reject measured the consequence: the window was read from
# GATE_CHANNEL_SESSION_MAX_AGE in the environment of the agent that runs
# `task answer`, and the residual note named that window as what bounded a replay
# of a non-unique value — a mitigation set by the party it defends against. Now
# the ident is REQUIRED (a value is unique to no gate; an ident is unique to one)
# and the env knob can only TIGHTEN a hardcoded 3600s ceiling. What remains is
# genuinely residual: a human message naming this ident and this value, inside the
# hour, cited for this gate, is the human answering this gate.
#
# Sets TASK_CS_REASON (why refused), TASK_CS_ORIGIN, TASK_CS_AGE. Returns 0 only
# when all four conditions hold.
_gate_channel_session_ok() { # <chat_id> <message_id> <answer_value> <ident>
  local chat="$1" msg="$2" bind="$3" ident="$4"
  TASK_CS_REASON="" TASK_CS_ORIGIN="" TASK_CS_AGE=""
  # (1) same trust anchor as DIVE-1305 — and it resolves TASK_CH_TOKEN for us.
  if ! _gate_channel_proof_ok "$chat"; then
    TASK_CS_REASON="chat $chat is not this bot's paired-human DM (not in access.json allowFrom)"
    return 1
  fi
  if [[ ! "$msg" =~ ^[0-9]+$ ]]; then
    TASK_CS_REASON="--channel-msg is not a numeric Telegram message id"
    return 1
  fi
  if [[ -z "${TASK_CH_TOKEN:-}" ]]; then
    TASK_CS_REASON="no readable bot token for this channel, so the citation cannot be attested — refused rather than assumed (fail closed)"
    return 1
  fi
  # (2) does Telegram say this message exists in that chat? The forward is the
  # probe; its own copy is deleted right after, whatever the verdict below.
  local resp; resp=$(_gate_channel_api "$TASK_CH_TOKEN" forwardMessage     -d "chat_id=${chat}" -d "from_chat_id=${chat}" -d "message_id=${msg}" -d "disable_notification=true")
  if [[ -z "$resp" ]]; then
    TASK_CS_REASON="the Bot API returned nothing for forwardMessage (unreachable) — the citation is UNVERIFIED, not accepted"
    return 1
  fi
  local _echo_id; _echo_id=$(jq -r '.result.message_id // empty' <<<"$resp" 2>/dev/null)
  if [[ -n "$_echo_id" ]]; then
    _gate_channel_api "$TASK_CH_TOKEN" deleteMessage -d "chat_id=${chat}" -d "message_id=${_echo_id}" >/dev/null 2>&1 || true
  fi
  if ! jq -e '.ok == true' <<<"$resp" >/dev/null 2>&1; then
    local _desc; _desc=$(jq -r '.description // "no description"' <<<"$resp" 2>/dev/null || echo "unparseable response")
    TASK_CS_REASON="Telegram refused the citation (${_desc}) — message ${msg} is not a live message in chat ${chat}"
    return 1
  fi
  # (3) WHO sent it. forward_origin is Telegram's attribution, not the caller's.
  local otype osender odate otext
  otype=$(jq -r '.result.forward_origin.type // empty' <<<"$resp" 2>/dev/null)
  osender=$(jq -r '.result.forward_origin.sender_user.id // empty' <<<"$resp" 2>/dev/null)
  odate=$(jq -r '.result.forward_origin.date // empty' <<<"$resp" 2>/dev/null)
  otext=$(jq -r '.result.text // .result.caption // ""' <<<"$resp" 2>/dev/null)
  TASK_CS_ORIGIN="${otype:-none}:${osender:-none}"
  if [[ "$otype" != "user" ]]; then
    TASK_CS_REASON="the cited message's forward origin is '${otype:-absent}', not a named user — no human sender is attested (a hidden-origin forward attests nobody)"
    return 1
  fi
  if [[ "$osender" != "$chat" ]]; then
    TASK_CS_REASON="the cited message was sent by user ${osender:-unknown}, not by the paired human of chat ${chat} — the bot's own messages and any third party are refused"
    return 1
  fi
  # (4) FRESH, and about THIS gate.
  if [[ ! "$odate" =~ ^[0-9]+$ ]]; then
    TASK_CS_REASON="the cited message carries no usable timestamp, so its freshness cannot be established"
    return 1
  fi
  # THE BOUND MUST NOT COME FROM THE CALLER (olivia, iteration-1 reject). This
  # window is what stops a stale human line being replayed onto a newer gate, and
  # the caller of `task answer` IS the agent — so reading it straight from the
  # environment made the mitigation settable by the party it defends against, with
  # no forgery needed. Measured on 8312851: a 400-day-old "approved" in the human's
  # own chat refused at the default (rc=6, gate open) and CLEARED under
  # GATE_CHANNEL_SESSION_MAX_AGE=999999999 (rc=0, human_evidence=channel-session) —
  # a row affirmatively attesting a human cleared a tier-2 gate nobody touched.
  # So the ceiling is hardcoded here and the env knob may only TIGHTEN it: a
  # deployment that wants a stricter window still gets one, while wider, zero,
  # negative and non-numeric all fall back to the ceiling itself.
  local _ceil=3600 _max="${GATE_CHANNEL_SESSION_MAX_AGE:-}"
  if [[ ! "$_max" =~ ^[0-9]+$ ]] || (( _max <= 0 || _max > _ceil )); then _max=$_ceil; fi
  local _now _age
  _now=$(date +%s)
  _age=$(( _now - odate )); (( _age < 0 )) && _age=0
  TASK_CS_AGE="$_age"
  if (( _age > _max )); then
    TASK_CS_REASON="the cited message is ${_age}s old (limit ${_max}s) — a stale human message must not be replayed onto a newer gate"
    return 1
  fi
  # WHICH GATE, AND WHICH ANSWER — both, not either (olivia, iteration-1 reject).
  # The first cut cleared on the answer value OR the ident, and each alone leaves a
  # hole: the VALUE is not unique (an ordinary "approved"/"yes" fits any number of
  # open gates, which is the shared-value replay the window was wrongly asked to
  # bound), and the IDENT alone attests only that the human spoke ABOUT this gate —
  # `--value` still comes from the agent, so a human writing "DIVE-x, no" would
  # clear it with value=yes. The ident is unique per gate and the value is the
  # decision, so tier 2 requires the message to carry both. An empty `--value`
  # (a bare approval) requires the ident alone, because there is no answer string
  # to corroborate. tier<2 callers who want the loose form already have the
  # citation-free DIVE-1305 chat-only path, so nothing is lost by making this one
  # strict for everybody.
  local _hay _nv _ni
  _hay=$(printf '%s' "$otext" | tr '[:upper:]' '[:lower:]')
  _nv=$(printf '%s' "$bind" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  _ni=$(printf '%s' "$ident" | tr '[:upper:]' '[:lower:]')
  if [[ -z "$_ni" || "$_hay" != *"$_ni"* ]]; then
    TASK_CS_REASON="the cited message does not name ${ident}, so it is not attributable to THIS gate — the answer value alone is not unique to one gate"
    return 1
  fi
  if [[ -n "$_nv" && "$_hay" != *"$_nv"* ]]; then
    TASK_CS_REASON="the cited message names ${ident} but not the answer ('${bind}'), so it does not attest WHICH answer the human gave"
    return 1
  fi
  return 0
}

# DIVE-1490: append a queryable delivery event for a gate alert. The purpose-
# built notify log is group-writable for agent-filed gates (DIVE-1345), while
# audit_log provides the tamper-evident event stream. Failures are ALSO loud on
# stderr; an unanswered gate must never look delivered merely because curl ran.
_task_gate_delivery_log() { # <ok|error> <task_ids> <chat> <message_id> <detail> [next_step]
  local result="$1" task_ids="$2" chat="$3" message_id="$4" detail="$5"
  # DIVE-2011: the failure warn's tail used to state "trying a visible group
  # fallback" unconditionally, which is true only of the Bot API path. On the
  # lead-route rail there is no group fallback, so the caller says what actually
  # happens next. A wrong sentence in a shipped warn outlives the analysis that
  # produced it (see the "28 rows on 2 tasks" correction below) — so it is a
  # parameter, not a comment.
  local next_step="${6:-trying a visible group fallback}"
  # DIVE-1968 criterion 3: count the ATTEMPT, not the write. The delivery
  # assertion in task_need_notify needs to know whether this gate reached a
  # terminal verdict at all, and it must reach the same answer on a fenced
  # fixture store as on prod — otherwise every unit harness would trip it.
  TASK_GATE_DELIVERY_ROWS=$(( ${TASK_GATE_DELIVERY_ROWS:-0} + 1 ))
  local idents="$task_ids"
  if [[ "$task_ids" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    idents=$(db "SELECT group_concat(ident, ',') FROM tasks WHERE id IN (${task_ids});" 2>/dev/null) || idents="$task_ids"
  fi
  [[ -n "$idents" ]] || idents="unknown"
  detail=${detail//$'\n'/ }
  # DIVE-2073: NAME THE ACTOR AND THE CHANNEL ON EVERY PATH. The audit row's
  # `user` answers only "which uid ran the process", and on both privileged
  # paths that is root — which names nobody. A row reading "confirmed Bot API
  # send" while its actor is unnameable proves that SOMETHING sent it, not who,
  # and on the privileged re-send the whole question the path exists to answer
  # is "did the escalation reach a human through a DIFFERENT channel than the
  # filer's". Two facts have to live on the row itself:
  #   via=   whose bot/channel carried it (TASK_CH_AGENT — every resolver sets it)
  #   path=  which rail the send is on
  # Measured cost of not having them (2026-07-26, DIVE-1927 residual 2): a
  # delivery to lodar at 10:25:02 carried message_id 691 while the same day's
  # other rows sat at 26235-26309 — two id spaces, because each bot keeps its
  # own conversation with the same human, so ids from different bots are not
  # comparable. The row was circumstantially olivia's and could not be PROVEN
  # so, and a residual stayed open on evidence we should have been writing.
  # `via=none` is honest and DISTINCT from a resolved owner: an error row that
  # never resolved a channel has no owner. It must never borrow a stale one from
  # an earlier send in the same process, which is why _task_agent_channel clears
  # TASK_CH_AGENT on entry rather than only setting it on success.
  local _via="${TASK_CH_AGENT:-none}" _path="file-time"
  if [[ "${TASK_GATE_ESCALATING:-}" == "1" ]]; then _path="privileged-resend"
  elif [[ "${TASK_GATE_RENAG:-}" == "1" ]]; then _path="renag"
  fi
  local line
  line=$(printf 'gate-delivery result=%s tasks=%s chat=%s message_id=%s via=%s path=%s detail=%q' \
    "$result" "$idents" "${chat:-none}" "${message_id:-none}" "$_via" "$_path" "${detail:-none}")
  # DIVE-1968: FENCE THE TELEMETRY ON STORE IDENTITY. This log and the audit rows
  # are the ONLY dataset anyone reads to judge whether the gate rail works, and
  # until now every run wrote into them from a HARDCODED prod path regardless of
  # which task store it was driving. A unit harness points TASKS_DB at a throwaway
  # store whose `agents_org` is EMPTY — and an empty org table gives an EMPTY
  # escalation chain for every filer, so each fixture gate emitted a real-looking
  # "no paired channel for filer X or anyone above it" row into production
  # telemetry. Measured on this box: of 36 distinct idents in the error rows, 17
  # existed ONLY in fixture stores; the true post-DIVE-1927 production population
  # is far smaller than the 194 rows on 13 tasks the ticket was filed on.
  #
  # CORRECTION to this comment's first cut (and to PR #170's body), because the
  # number it quoted was derived the wrong way and is now cited knowledge: it said
  # "28 rows on 2 tasks", from an IDENT-EXISTS-IN-PROD-STORE filter. That filter is
  # insufficient — fixtures REUSE real idents. The sound discriminator is the
  # PENDING-GATE WINDOW: a row is a real delivery attempt only if
  # need_asked_at <= ts < need_answered_at, because the notify path will not
  # re-fire an answered gate and cmd_task_gate_escalate refuses anything not
  # pending. The fence is right; only PR #170's numbers and taxonomy were wrong.
  #
  # POSITIVE RESULT (DIVE-1988, re-derived on the full 1330-row union across all
  # seven days, method cited beside every number because this dataset has now
  # misled us four separate ways — see the wiki page linked below): the window
  # filter gives 112 in-window rows on 85 tasks — 11 error, 101 ok. The 11 are one
  # per task at filing time, and 9 of the 11 also carry a later `ok`. absent-from-org
  # is ZERO instances, not "the largest real shape, 13 of 28" as PR #170 had it. The
  # real shape is ORG-UNREADABLE: 10 of the 11 read "filing agent and org lead have
  # no paired channel", 1 reads "no allowlisted DM or deliverable group topic", and
  # every agent's access.json is 0600 — root can read it, a peer cannot.
  #
  # That shape has TWO causes and they take DIFFERENT fixes — do not collapse them:
  #   (a) the filer itself has NO channel of its own at all (quinn, dev2, dev3 — 1
  #       genuinely top-of-org, 2 with no access.json regardless): fix is SEED A
  #       CHANNEL.
  #   (b) the filer's OWN channel exists but its chain holds one nobody in that
  #       context may read — main -> olivia, whose access.json is 600 under a 750
  #       dir a peer can't even traverse, though root reads it fine: fix is PASS
  #       THE FILER NAME into a root-privileged probe so it resolves the chain
  #       with root's reach instead of the caller's.
  # Only 1 of the 11 (quinn) is genuine top-of-org-with-no-channel; main alone is
  # 8 of the 11, so the mass of the population is (b). Full derivation:
  # community/wiki/gate-delivery-telemetry-decontamination-dive1968.md (DIVE-1988).
  #
  # That contamination is worse than noise, and in BOTH directions: it inflated the
  # apparent blast radius AND it hid the real residual inside it. It also
  # manufactured the control that made the diagnosis look decisive — "13 tasks hold
  # 194 errors and not ONE ever recorded an ok, while the ok rows belong to 6
  # disjoint tasks" reads as proof of a broken rail, but a fixture ident can never
  # record an ok because it was never a real gate. Zero overlap was evidence of two
  # POPULATIONS IN ONE FILE, not of a failure.
  #
  # Fenced on STORE IDENTITY (_task_human_send_allowed, the DIVE-1506 positive
  # allowlist) rather than on an opt-out env var every harness must remember: the
  # failure mode of a forgotten override is SILENT contamination of prod telemetry,
  # which is precisely what we are standing in. An explicit FIVEDIVE_GATE_NOTIFY_LOG
  # is still honoured — a harness redirecting to its OWN file is the safe case and
  # the one we want to encourage — but it can never redirect INTO the prod default.
  # Withholding is announced once per process, because a fence that silently drops
  # rows is the same defect class one layer over.
  # PRIMARY is store identity and it needs NO env at all, so a harness that sets
  # nothing is fenced BY CONSTRUCTION — including harnesses nobody has written yet,
  # which no opt-in can manage. SECONDARY honours DIVE-1500's existing
  # FIVEDIVE_NOTIFY_DRYRUN quarantine so we reuse that vocabulary instead of
  # minting a rival one. The order matters: an opt-in fence is a fence you have to
  # REMEMBER, and "four harnesses set it, the rest do not" is the exact defect being
  # removed here. Do not fix an opt-out failure with a different opt-in.
  local logf="${FIVEDIVE_GATE_NOTIFY_LOG:-}" _prod_telemetry=0
  if _task_human_send_allowed \
     && [[ -z "${FIVEDIVE_NOTIFY_DRYRUN:-}" || "${FIVEDIVE_NOTIFY_DRYRUN}" == "0" ]]; then
    _prod_telemetry=1
  fi
  [[ -n "$logf" ]] || { (( _prod_telemetry )) && logf=/var/log/5dive/notify/gate-notify.log; }
  if [[ -n "$logf" ]] && ( umask 0002; : >>"$logf" ) 2>/dev/null; then
    chmod g+w "$logf" 2>/dev/null || true
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')" "$line" >>"$logf" 2>/dev/null || true
  fi
  if (( _prod_telemetry )); then
    audit_log "gate delivery" "$result" "$([[ "$result" == "ok" ]] && echo 0 || echo 1)" -- \
      "tasks=$idents" "chat=${chat:-none}" "message_id=${message_id:-none}" \
      "via=$_via" "path=$_path" "detail=${detail:-none}" || true
  elif [[ -z "${_TASK_GATE_TELEMETRY_FENCED:-}" ]]; then
    _TASK_GATE_TELEMETRY_FENCED=1
    warn "gate-delivery telemetry withheld: TASKS_DB is not the production store, so these rows are NOT written to the fleet log or audit (DIVE-1968). Set FIVEDIVE_GATE_NOTIFY_LOG to capture them locally."
  fi
  [[ "$result" == "ok" ]] || warn "$idents: gate alert delivery FAILED for chat ${chat:-none} (${detail:-unknown}); ${next_step}"
}

# ---- DIVE-2410: retire a settled gate's buttons -----------------------------
#
# THE DEFECT. A gate's approve button outlived its gate. Confirmed on DIVE-2400:
# two buttons delivered (03:20:02Z message_id=15491, 04:05:02Z message_id=15492,
# both via=marketing), gate closed 04:28:41Z, and NOTHING edited, disabled or
# expired either keyboard. From the close onward there were two live-LOOKING
# approve buttons in the human's chat for a question already settled.
#
# WHY THAT IS A DEFECT AND NOT COSMETIC. A tap on a closed gate correctly records
# nothing. But the human gets no error, no "already closed", no visual change, so
# the only conclusion available to them is that they approved. The record and the
# human's belief diverge, and the human has no way to see it — the same class of
# harm as DIVE-2406 approached from the other side (there the record claimed an
# approval nobody gave; here the human believes an approval the record lacks).
# Read a human's frustration with a control as data about the control: lodar's
# "I tap the approve again. wtf is the human gate. I hate it" is the symptom.
#
# The plugin's `tna:` handler ALREADY answers a stale tap with a toast and strips
# the keyboard (server.ts, resolveTnaAnswer -> already/nogate). That is the wrong
# layer to rely on alone, for two reasons: it fires only if the human taps (so
# until then the chat keeps showing a live control), and a toast is a 2-second
# mobile banner that is genuinely easy to miss. The button must stop LOOKING
# tappable at CLOSE time, from the process that did the closing.
#
# WHY THIS LIVES IN THE CLI. Gates close from paths with no Telegram session at
# all: `task answer` on the dashboard, a lead-clear, `task need --withdraw`,
# `task park`, the verifier's auto:reject, a done/cancel that moots an open gate.
# Every one of those runs here. A plugin-side fix cannot cover any of them.

# The token for the bot that CARRIED a delivery. Deliberately NOT
# _task_agent_channel: that clobbers TASK_CH_* (token, access, type, agent),
# which live callers are mid-flight on — _task_close_notify sends through those
# globals and retirement can run beside it. We need only the token, and
# connector files are the same group-claude-readable source _task_agent_channel
# reads, so read it directly and leave the globals alone.
# via=<agent> matters and is not decorative: message_id is scoped to a bot-chat
# PAIR, so editing 15491 with the wrong bot's token edits a different message or
# nothing (DIVE-2073 is why the delivery row carries `via` at all).
_task_gate_bot_token() { # <agent-name> -> token on stdout
  local name="${1:-}" token="" f
  if [[ -n "$name" && "$name" != "none" ]]; then
    f="${CONNECTORS_DIR}/telegram-${name}.env"
    [[ -r "$f" ]] && token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$f" | head -1)
  fi
  [[ -n "$token" ]] || token="${TELEGRAM_BOT_TOKEN:-}"
  printf '%s' "$token"
}

# Every button-bearing message this task's gate put in a human chat, as
# chat<TAB>message_id<TAB>via, deduped. The set is already knowable: the
# gate-delivery log records chat + message_id + via per delivery, which is
# exactly what DIVE-2410 needs and nobody had read back yet.
#
# Four exclusions, each for its own reason — a wrong row here edits a message
# that was never this gate's:
#   result=error rows      no message exists to edit (message_id is empty).
#   message_id 0 / none    a dry-run receipt or an ok-without-id; not a real message.
#   chat=agent:<name>      the maker->verifier handoff leg (see the reviewer-ping
#                          delivery rows). An agent inbox, not a Telegram chat.
#   another task's ident   `tasks=` is a COMMA LIST — the re-nag batches several
#                          gates into one message. Match a whole field, never a
#                          substring, or DIVE-24 retires DIVE-2410's button.
# A batched message covering a still-open gate is retired too, and that is
# correct-but-blunt: its keyboard carries a button per task, and the Bot API
# cannot remove one button without rebuilding the whole markup. Losing a live
# button is recoverable — the re-nag re-delivers pending gates — while leaving a
# settled one tappable is the bug being fixed. Noted, not silently accepted.
_task_gate_deliveries() { # <ident>
  local ident="$1"
  local logf="${FIVEDIVE_GATE_NOTIFY_LOG:-}"
  [[ -n "$logf" ]] || logf=/var/log/5dive/notify/gate-notify.log
  if [[ ! -r "$logf" ]]; then
    # Make the absence observable ONCE per process. This log is the ONLY record of
    # which messages a gate put in a human's chat, so if it cannot be read the
    # retirement is a total silent no-op — every settled button stays tappable and
    # nothing anywhere says so. It is 0664 today, but "unreadable" and "no
    # deliveries" must never share an answer in a function whose failure mode is
    # invisible (the DIVE-1927 absent-vs-forbidden rule, one layer over).
    if [[ -e "$logf" && -z "${_TASK_GATE_RETIRE_BLIND:-}" ]]; then
      _TASK_GATE_RETIRE_BLIND=1
      warn "cannot read the gate-delivery log ($logf) — settled gates' buttons cannot be retired from this process, so a closed gate may keep showing a live approve button (DIVE-2410)."
    fi
    return 0
  fi
  awk -v want="$ident" '
    /gate-delivery result=ok/ {
      tasks=""; chat=""; mid=""; via=""
      for (i = 1; i <= NF; i++) {
        if      (substr($i, 1, 6)  == "tasks=")      tasks = substr($i, 7)
        else if (substr($i, 1, 5)  == "chat=")       chat  = substr($i, 6)
        else if (substr($i, 1, 11) == "message_id=") mid   = substr($i, 12)
        else if (substr($i, 1, 4)  == "via=")        via   = substr($i, 5)
      }
      if (chat == "" || chat == "none" || chat ~ /^agent:/) next
      if (mid == "" || mid == "none" || mid == "0") next
      n = split(tasks, T, ",")
      for (j = 1; j <= n; j++) if (T[j] == want) { print chat "\t" mid "\t" via; next }
    }
  ' "$logf" 2>/dev/null | awk -F'\t' '!seen[$1 FS $2]++'
}

# Strip the inline keyboard off every message that delivered this gate. Call it
# AFTER the settling write has committed, always best-effort: a gate is settled
# by the DB row, and a Telegram edit that fails must never unsettle it or fail
# the caller's command.
#
# FENCE. Same rail as the send whose message it edits — refuse unless the active
# store is the prod store (_task_human_send_allowed, the DIVE-1506 positive
# allowlist), EXCEPT when the dry-run quarantine is on, which is the one case a
# harness can exercise this end to end while being physically unable to reach
# Telegram (_mirror_edit_markup enforces that itself). An opt-in-only fence is
# the mistake DIVE-1968 removed; this is store identity first, as there.
_task_gate_retire_buttons() { # <ident> <why>
  local ident="$1" why="${2:-gate closed}"
  local _dry=0
  [[ -n "${FIVEDIVE_NOTIFY_DRYRUN:-}" && "${FIVEDIVE_NOTIFY_DRYRUN}" != "0" ]] && _dry=1
  if ! _task_human_send_allowed && (( ! _dry )); then
    return 0
  fi
  local rows; rows=$(_task_gate_deliveries "$ident") || return 0
  [[ -n "$rows" ]] || return 0
  local chat mid via token resp ok desc result
  while IFS=$'\t' read -r chat mid via; do
    [[ -n "$chat" && -n "$mid" ]] || continue
    token=$(_task_gate_bot_token "$via")
    if [[ -z "$token" ]]; then
      # Name the miss. A retirement that cannot resolve the delivering bot leaves
      # a tappable button behind, which is the defect — so it is a row, not a
      # shrug. (Reachable when the delivering agent was torn down after filing.)
      _task_store_audit_log "gate button retire" "error" 1 -- \
        "task=$ident" "chat=$chat" "message_id=$mid" "via=${via:-none}" \
        "detail=no bot token for delivering agent; button left live" || true
      continue
    fi
    resp=$(_mirror_edit_markup "$token" "$chat" "$mid") || resp="${resp:-}"
    ok=$(jq -r '.ok // false' <<<"$resp" 2>/dev/null) || ok=false
    desc=$(jq -r '.description // empty' <<<"$resp" 2>/dev/null) || desc=""
    result=error
    if [[ "$ok" == "true" ]]; then
      result=ok; desc="keyboard removed"
    elif [[ "$desc" == *"not modified"* || "$desc" == *"message to edit not found"* ]]; then
      # Already un-tappable — the end state we wanted, reached without us.
      result=ok
    fi
    _task_store_audit_log "gate button retire" "$result" \
      "$([[ "$result" == "ok" ]] && echo 0 || echo 1)" -- \
      "task=$ident" "chat=$chat" "message_id=$mid" "via=${via:-none}" \
      "why=$why" "detail=${desc:-unconfirmed Bot API edit}" || true
    [[ "$result" == "ok" ]] || warn "$ident: could not retire the gate button on message $mid in chat $chat (${desc:-unknown}) — a settled gate may still show a live approve button there."
  done <<<"$rows"
  return 0
}

# DIVE-1506 — fail-closed guard: a gate alert (task_need_notify) or an /inbox digest
# (_task_inbox_send) may reach the PAIRED HUMAN only from the canonical PROD task DB. This is a
# POSITIVE ALLOWLIST, not a fixture blocklist — a rotted blocklist is exactly how DIVE-1500's guard
# missed the gate-notify + /inbox legs and let an isolated e2e's `task need` DM real fixture gates
# (dive1-4) to lodar. Every human-facing send now refuses unless the active TASKS_DB resolves to the
# prod path (operator-overridable via FIVEDIVE_PROD_TASKS_DB); an explicit test/e2e opt-out also
# refuses (belt-and-suspenders for a harness that forgets to repoint TASKS_DB). Returns 0=allow,1=refuse.
_task_prod_tasks_db() { printf '%s' "${FIVEDIVE_PROD_TASKS_DB:-/var/lib/5dive/tasks/tasks.db}"; }
_task_human_send_allowed() {
  # Explicit test/e2e markers force refuse regardless of path (covers COUNCIL_MOCK e2es etc.).
  [[ -n "${FIVEDIVE_NO_HUMAN_SEND:-}" || -n "${COUNCIL_MOCK:-}" || -n "${FIVEDIVE_E2E:-}" || -n "${FIVEDIVE_TEST:-}" ]] && return 1
  local active prod ra rp
  active="${TASKS_DB:-${STATE_DIR:-/var/lib/5dive}/tasks/tasks.db}"
  prod="$(_task_prod_tasks_db)"
  ra="$(readlink -f "$active" 2>/dev/null || printf '%s' "$active")"
  rp="$(readlink -f "$prod" 2>/dev/null || printf '%s' "$prod")"
  [[ -n "$ra" && "$ra" == "$rp" ]]
}

# DIVE-3077 — the same fail-closed store-identity idea, applied to the board WRITE
# path. On 2026-08-09 the prod board read 128 open rows of which 98 were test
# fixtures filed that same day by three agents (`prose A`-`prose E`, `stamp arm
# C/D/E`), burying a 27-row real backlog. The cost was not the count, it was
# occlusion: a backlog you cannot read is one you cannot triage.
#
# WHY THIS IS NOT `! _task_human_send_allowed`, which is the obvious edit and is
# wrong. That predicate refuses on EITHER a marker OR a non-prod store, because a
# human send from a fixture store is never wanted. A board WRITE from a fixture
# store into that fixture's OWN throwaway DB is the normal, correct case — it is
# what nearly every harness in the corpus does. Inverting the send predicate here
# would refuse all of them. The write rail cares about exactly one combination:
# a run that has DECLARED itself a test, writing to the REAL production store.
#
#   refuse  <=>  (a test/harness marker is set)  AND  (the active TASKS_DB is the
#                                                      real prod board)
#
# WHY THE PROD PATH HERE IGNORES FIVEDIVE_PROD_TASKS_DB, which is the one real
# asymmetry with the send predicate and is deliberate. That variable exists so a
# harness can DECLARE its own fixture store to be "prod" and exercise the send
# predicate's allowed arm — 29 harnesses in the corpus do exactly that. A fence
# that lets the caller redefine the thing it is protecting is fail-open by
# construction, and honouring it here would refuse those 29 harnesses' own writes
# to their own throwaway stores. The defect this closes was 98 fixture rows landing
# on ONE file, so this fence names that file.
#
# THE SEAM, and why it is a SECOND variable rather than reusing the one above.
# tests/task_board_write_fence_unit.sh must drive `task add` end to end against
# "the prod board" to grade that the fence is WIRED and not merely correct. With
# no seam its only option is to point TASKS_DB at the real board — and the arm
# that grades "the fence refuses" then WRITES A REAL FIXTURE ROW the moment the
# fence regresses. That is not hypothetical: it happened during this ticket's own
# mutation testing and put DIVE-3082/3083/3084 on the live board. A guard whose
# test reproduces, on its failure path, the exact defect the guard exists to
# prevent is worse than no test. FIVEDIVE_FENCE_PROD_DB is set by that harness and
# by nothing else; unset, this resolves to the real board, which the harness
# asserts before it uses the seam.
# Returns 0=allow, 1=refuse.
_task_real_prod_tasks_db() { printf '%s' "${FIVEDIVE_FENCE_PROD_DB:-/var/lib/5dive/tasks/tasks.db}"; }
_task_board_write_allowed() {
  [[ -n "${FIVEDIVE_HARNESS:-}" || -n "${FIVEDIVE_NO_HUMAN_SEND:-}" \
     || -n "${COUNCIL_MOCK:-}" || -n "${FIVEDIVE_E2E:-}" \
     || -n "${FIVEDIVE_TEST:-}" ]] || return 0
  local active prod ra rp
  active="${TASKS_DB:-${STATE_DIR:-/var/lib/5dive}/tasks/tasks.db}"
  prod="$(_task_real_prod_tasks_db)"
  ra="$(readlink -f "$active" 2>/dev/null || printf '%s' "$active")"
  rp="$(readlink -f "$prod" 2>/dev/null || printf '%s' "$prod")"
  [[ -n "$ra" && "$ra" == "$rp" ]] && return 1
  return 0
}

# DIVE-2010: fence a task-store-driven audit_log call on STORE IDENTITY, reusing
# the exact primitive _task_gate_delivery_log (DIVE-1968) already trusts for the
# same risk shape — a row built from live TASKS_DB state (a task ident, a filer,
# a gate type) written by a fixture store is a real-looking row with a fixture
# ident landing in the real fleet audit log. Measured on this box: a 41-suite
# run wrote 6 such rows via "task need unnotified" alone (fixture idents
# DIVE-1..4, filer=dev); re-sweeping tests/task_*unit.sh + tests/gate_*unit.sh
# after fixing that site found 2 MORE live call sites doing the same thing
# ("task set-body", "task.merge-gate-unverified") before they were routed
# through this wrapper too. Other unconditional task-store call sites remain
# (tracked in DIVE-2045) — untested is not the same claim as leak-free.
# Withholding is announced ONCE per process — a silent fence is the same
# fail-open shape as no fence (DIVE-1968 assertion 2).
# DIVE-2799: the evidence form was ALREADY named — in the wrong place.
#
# DIVE-2412 named it in `tasks.human_evidence`, which is the right fact in a
# column that cannot answer the question this row asks. That column is ONE cell on
# ONE mutable row: a re-answer overwrites it, `_gate_archive_and_clear_sql` clears
# it when the gate retires, and it is not a history at all — so "grep separates the
# evidence forms ACROSS HISTORY" (DIVE-2799 acceptance clause 3) is unanswerable
# from it, for every gate that has since been retired or re-answered. The
# append-only audit log is the only sink with that property, and it carried the
# per-form BOOLEANS but never the form's NAME.
#
# WHY THE BOOLEANS ARE NOT ALREADY THE ANSWER, which is the substance and not a
# style preference. A reader asking "which form cleared this?" had to AND together
# `nonce_valid`/`sudo_nonagent`/`channel_session`/`cs_ok`/`cp_ok` — a DIFFERENT
# subset at each of the two audit sites, and a subset that has grown over time.
# That makes the answer PATH-DEPENDENT: a sweep keyed on a field under-counts by
# exactly the paths that log a different arg set, and a query against a field that
# did not exist yet returns a confident zero. Both failures happened inside this
# very row's own measurement (main's five, then olivia's 37-as-a-floor).
#
# THIS FUNCTION IS EXTRACTED FROM the DIVE-2412 inline block at the write site,
# not written beside it. Two vocabularies for one fact is the DIVE-2777 shape this
# ticket explicitly warns about — a class fixed at the call sites someone happened
# to be looking at. The token spelling is therefore UNCHANGED and load-bearing:
# `nonce`, `sudo-uid`, `channel-session`, `channel-chat`, `lead`, `+`-joined in
# this order, `none` when empty. The column and the log now say the same word for
# the same thing, so a historical sweep can join them.
#
# THE VALUE IS EXACT-MATCHABLE ON PURPOSE. In the JSON audit log each arg is its
# own array element, so `grep '"evidence=nonce"'` — WITH the closing quote —
# selects the sole-nonce class and does NOT prefix-match
# `evidence=nonce+channel-session`. Never reorder the tokens or vary the
# separator: a historical sweep compares string literals across months of rows.
#
# WHAT THIS DOES **NOT** BUY, stated here because the field name invites the
# stronger reading. It does not separate a relayed human tap from a
# filer-presented nonce. It cannot: the deployed Telegram plugin's tap sends
# `--human --human-proof=<nonce>` and nothing else, so the two are byte-identical
# AT THE INPUT and no CLI-side field can tell them apart. What it buys is that the
# nonce-only class stops being a reconstruction and becomes a fact the row states
# about itself — which is what makes the population countable and a floor legible
# AS a floor.
_gate_evidence_form() { # <nonce> <sudo_uid> <channel_session> <channel_chat> <lead>
  local out=""
  if [[ "${1:-0}" == "1" ]]; then out+="${out:++}nonce"; fi
  if [[ "${2:-0}" == "1" ]]; then out+="${out:++}sudo-uid"; fi
  if [[ "${3:-0}" == "1" ]]; then out+="${out:++}channel-session"; fi
  if [[ "${4:-0}" == "1" ]]; then out+="${out:++}channel-chat"; fi
  if [[ "${5:-0}" == "1" ]]; then out+="${out:++}lead"; fi
  printf '%s' "${out:-none}"
}

# DIVE-2799: the one discriminator that IS available CLI-side — is the caller
# answering a gate IT filed? `gate_filed_by` is written in the same transaction
# as the gate, so the filer of record is not the caller's to choose at answer
# time. `filer_answered=1` does not mean a forge (a legitimate relayed tap runs
# under the paired agent's own uid and will read 1 too); `filer_answered=0`
# means the answer came from a DIFFERENT principal than the one holding the
# minted proof, which is the strictly narrower and more exonerating case. Recorded
# because it is the only field on this rail that can ever exonerate, and a control
# that cannot exonerate is as broken as one that cannot convict.
# Falls back to `unknown` on a pre-DIVE-1958 row with gate_filed_by NULL — never
# to `0`, which would read as a positive finding it has not measured.
_gate_filer_answered() { # <task id> <caller os user>
  local _f; _f=$(db "SELECT COALESCE(gate_filed_by,'') FROM tasks WHERE id=${1};")
  if [[ -z "$_f" ]]; then printf 'unknown'; return; fi
  if [[ "${2#agent-}" == "$_f" ]]; then printf '1'; else printf '0'; fi
}

_TASK_STORE_AUDIT_FENCED=""
_task_store_audit_log() { # <cmd> <result> <code> -- <args...>
  if _task_human_send_allowed; then
    audit_log "$@"
  elif [[ -z "${_TASK_STORE_AUDIT_FENCED:-}" ]]; then
    _TASK_STORE_AUDIT_FENCED=1
    warn "task audit telemetry withheld: TASKS_DB is not the production store, so this row is NOT written to the fleet audit log (DIVE-2010)."
  fi
  return 0
}

TASK_SEND_DELIVERED=0
TASK_SEND_MESSAGE_IDS=""
TASK_SEND_FAILED=0

_task_post_owner_target() { # <token> <chat> <thread> <text> <access> <markup> <task_ids>
  local token="$1" chat="$2" thread="$3" text="$4" access_file="$5" reply_markup="$6" task_ids="$7"
  _mirror_post "$token" "$chat" "$thread" "$text" "$access_file" "$reply_markup"
  if [[ "${MIRROR_POST_DELIVERED:-0}" == "1" ]]; then
    TASK_SEND_DELIVERED=1
    [[ -n "${MIRROR_POST_MESSAGE_ID:-}" ]] \
      && TASK_SEND_MESSAGE_IDS+="${TASK_SEND_MESSAGE_IDS:+,}${MIRROR_POST_MESSAGE_ID}"
    if [[ -n "$task_ids" ]]; then
      _task_gate_delivery_log ok "$task_ids" "${MIRROR_POST_CHAT:-$chat}" "${MIRROR_POST_MESSAGE_ID:-}" "confirmed Bot API send"
    fi
  else
    TASK_SEND_FAILED=1
    if [[ -n "$task_ids" ]]; then
      _task_gate_delivery_log error "$task_ids" "${MIRROR_POST_CHAT:-$chat}" "" "${MIRROR_POST_ERROR:-unconfirmed Bot API send}"
    fi
  fi
}

_task_send_owner_groups() { # <token> <access> <text> <markup> <task_ids> [exclude_chat]
  local token="$1" access_file="$2" text="$3" reply_markup="$4" task_ids="$5" exclude_chat="${6:-}"
  local groups n i g_chat g_thread
  groups=$(jq -c '(.groups // {}) | to_entries' "$access_file" 2>/dev/null) || groups="[]"
  n=$(jq 'length' <<<"$groups" 2>/dev/null) || n=0
  n=${n:-0}
  for (( i=0; i<n; i++ )); do
    g_chat=$(jq -r ".[$i].key" <<<"$groups" 2>/dev/null) || continue
    g_thread=$(jq -r ".[$i].value.message_thread_id // \"\"" <<<"$groups" 2>/dev/null) || g_thread=""
    [[ -n "$g_chat" && "$g_chat" != "$exclude_chat" ]] || continue
    _task_post_owner_target "$token" "$g_chat" "$g_thread" "$text" "$access_file" "$reply_markup" "$task_ids"
  done
}

_task_stamp_confirmed_delivery() { # <comma-separated numeric task ids>
  local task_ids="$1"
  [[ "${TASK_SEND_DELIVERED:-0}" == "1" && "$task_ids" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 0
  db "UPDATE tasks SET gate_pinged_at=datetime('now')
      WHERE id IN (${task_ids}) AND need_type IS NOT NULL AND need_answered_at IS NULL;" 2>/dev/null || true
}

# _task_send_owner — send ONE message ($1, optional reply_markup $2, optional
# comma-separated task row ids $3) to the
# paired human, using the channel resolved by _task_owner_channel. Routing
# (DIVE-259, Mark): follow the conversation — if the telegram plugin recorded
# where the human last talked to this agent (last-human-chat.json beside
# access.json), the alert and its tap buttons go THERE, but only when that
# chat is still allowlisted in access.json (a stale or hand-edited pointer
# must never widen the audience). No pointer (plugin predates the feature) =
# legacy flow: human DMs first (allowFrom — exactly the users who /started
# the bot), then the agent's bound forum topic(s) so nothing is silently
# lost. A Bot API {ok:true} is required before task ids are stamped delivered;
# failures are logged loudly and retry against an allowed group topic. Always
# returns 0 (best-effort); TASK_SEND_DELIVERED exposes the receipt to callers.
_task_send_owner() {
  local text="$1" reply_markup="${2:-}" task_ids="${3:-}"
  local token="$TASK_CH_TOKEN" access_file="$TASK_CH_ACCESS"
  TASK_SEND_DELIVERED=0 TASK_SEND_MESSAGE_IDS="" TASK_SEND_FAILED=0
  # DIVE-1506: fail-closed chokepoint. EVERY real human-facing task send (gate-notify + /inbox
  # digest) funnels here. Refuse unless the active task DB is the prod DB — an isolated e2e/fixture
  # DB (council_gate_e2e's `task need`, a replayed fixture digest) must never reach a paired human.
  # Leaves DELIVERED=0/FAILED=1 so callers' existing not-delivered fail-closed handling takes over.
  # Stub-based unit tests override _task_send_owner, so this never fires under a mocked send.
  if ! _task_human_send_allowed; then
    TASK_SEND_FAILED=1
    warn "refused a human task-send — the active task DB is not the prod DB; set FIVEDIVE_PROD_TASKS_DB if this IS prod"
    return 0
  fi

  local ptr_file="${access_file%/*}/last-human-chat.json"
  if [[ -r "$ptr_file" ]]; then
    local p_chat p_thread
    p_chat=$(jq -r '.chatId // empty' "$ptr_file" 2>/dev/null) || p_chat=""
    p_thread=$(jq -r '.messageThreadId // empty' "$ptr_file" 2>/dev/null) || p_thread=""
    if [[ -n "$p_chat" ]]; then
      if jq -e --arg c "$p_chat" '(.allowFrom // []) | index($c) != null' "$access_file" >/dev/null 2>&1; then
        _task_post_owner_target "$token" "$p_chat" "" "$text" "$access_file" "$reply_markup" "$task_ids"
        [[ "$TASK_SEND_DELIVERED" == "1" ]] || _task_send_owner_groups "$token" "$access_file" "$text" "$reply_markup" "$task_ids"
        _task_stamp_confirmed_delivery "$task_ids"
        return 0
      fi
      if jq -e --arg c "$p_chat" '(.groups // {}) | has($c)' "$access_file" >/dev/null 2>&1; then
        _task_post_owner_target "$token" "$p_chat" "$p_thread" "$text" "$access_file" "$reply_markup" "$task_ids"
        [[ "$TASK_SEND_DELIVERED" == "1" ]] || _task_send_owner_groups "$token" "$access_file" "$text" "$reply_markup" "$task_ids" "$p_chat"
        _task_stamp_confirmed_delivery "$task_ids"
        return 0
      fi
      # Pointer references a chat that is no longer allowed — ignore it.
    fi
  fi

  local dms attempted=0 chat
  dms=$(jq -r '(.allowFrom // [])[]' "$access_file" 2>/dev/null) || dms=""
  if [[ -n "$dms" ]]; then
    while IFS= read -r chat; do
      [[ -n "$chat" ]] || continue
      _task_post_owner_target "$token" "$chat" "" "$text" "$access_file" "$reply_markup" "$task_ids"
      attempted=1
    done <<<"$dms"
  fi
  # No DM target, or at least one DM rejected: post once per configured group so
  # the alert lands somewhere visible. A partial DM failure still falls back —
  # every allowlisted owner should have a recovery surface.
  if (( ! attempted )) || [[ "$TASK_SEND_FAILED" == "1" ]]; then
    _task_send_owner_groups "$token" "$access_file" "$text" "$reply_markup" "$task_ids"
  fi
  if (( ! attempted )) && [[ "$TASK_SEND_DELIVERED" != "1" && -n "$task_ids" ]]; then
    TASK_SEND_FAILED=1
    _task_gate_delivery_log error "$task_ids" "" "" "no allowlisted DM or deliverable group topic"
  fi
  _task_stamp_confirmed_delivery "$task_ids"
  return 0
}

# _task_send_gate_owner — DIVE-3342. The send path for a GATE, as distinct from
# the informational sends (digest, close-notify, escalation ping) that keep using
# _task_send_owner above. A gate has an owner; a digest does not.
#
# The rule this enforces, and it is the whole ticket: **a gate is delivered to the
# person who may CLEAR it, or it is not delivered to a person at all.** No pointer
# from bot traffic may redirect it, and an unresolved recipient does NOT fan out to
# every id in allowFrom — it stays on the agent rail with the reason recorded, and
# the caller's existing not-delivered handling takes over unchanged (the receipt is
# left unstamped, so the row keeps re-nagging and the agent rail keeps escalating).
#
# Three-state by construction:
#   registry empty  -> delegate to _task_send_owner. Every host today has one
#                      paired human, where the pointer and the fan-out both
#                      resolve to that person and nothing misroutes; changing
#                      their delivery would be a regression dressed as a fix.
#   resolved + on this bot -> send to exactly that chat. Nothing else is tried:
#                      not the pointer, not the other allowFrom ids, not the
#                      groups (a forum topic is multi-member, so falling back to
#                      one is the same wrong-audience defect the ticket reports).
#   resolved + NOT on this bot, or unresolved -> refuse, log why, stay on the rail.
#
# The allowFrom check is the invariant that keeps a `humans` row an IDENTITY rather
# than a GRANT: the registry may NARROW a gate's audience, never widen it. Same
# posture the pointer arm above already takes ("a stale or hand-edited pointer must
# never widen the audience") — applied to the registry, which is likewise written
# by a human editing state rather than by the person proving they can be reached.
# Always returns 0; TASK_SEND_DELIVERED / TASK_SEND_FAILED carry the outcome.
_task_send_gate_owner() {
  local text="$1" reply_markup="${2:-}" task_ids="${3:-}" owner_override="${4:-}"
  if ! _human_registry_active; then
    _task_send_owner "$text" "$reply_markup" "$task_ids"
    return 0
  fi
  TASK_SEND_DELIVERED=0 TASK_SEND_MESSAGE_IDS="" TASK_SEND_FAILED=0
  local token="$TASK_CH_TOKEN" access_file="$TASK_CH_ACCESS"
  # DIVE-1506 fail-closed chokepoint, same as _task_send_owner: a fixture/e2e DB
  # must never reach a paired human. Checked here too because this function is a
  # second door onto the same transport, and a chokepoint with a bypass is not one.
  if ! _task_human_send_allowed; then
    TASK_SEND_FAILED=1
    warn "DIVE-1506: refused a human gate-send — active task DB (${TASKS_DB:-${STATE_DIR:-/var/lib/5dive}/tasks/tasks.db}) is not the prod DB (fail-closed; set FIVEDIVE_PROD_TASKS_DB if this IS prod)"
    return 0
  fi

  # One send, one owner. A batch spanning several owners is refused rather than
  # split here: the text is already rendered and carries every row in the batch,
  # so "deliver it to each owner" would page each person with the others' gates.
  # Batch callers partition with _human_gate_ids_by_owner and render per owner.
  local hid="$owner_override" first=1 id owner
  [[ -n "$owner_override" ]] && task_ids=""      # a courtesy line addressed to an
                                                 # owner we already delivered to
                                                 # carries no rows of its own.
  local IFS=','
  for id in $task_ids; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    # No command substitution: HUMAN_RECIPIENT_BASIS is why the refusal below can
    # name a reason, and a $( ) subshell would drop it.
    _human_gate_recipient "$id" >/dev/null
    owner="$HUMAN_RECIPIENT_ID"
    if (( first )); then hid="$owner"; first=0
    elif [[ "$owner" != "$hid" ]]; then
      unset IFS
      TASK_SEND_FAILED=1
      _task_gate_delivery_log error "$task_ids" "" "" \
        "batch spans more than one human owner — not delivered; re-nag per owner (DIVE-3342)" \
        "partition the batch with _human_gate_ids_by_owner and render one message per owner"
      return 0
    fi
  done
  unset IFS

  if [[ -z "$hid" ]]; then
    TASK_SEND_FAILED=1
    _task_gate_delivery_log error "$task_ids" "" "" \
      "no human owns this gate's clearers (${HUMAN_RECIPIENT_BASIS:-unresolved}) — held on the agent rail, NOT broadcast to the allowlist (DIVE-3342)" \
      "name the person: sudo 5dive human link <human> --agent=<the gate's reviewer or filer>"
    return 0
  fi

  local chat; chat=$(_human_transport_id "$hid" telegram)
  if [[ -z "$chat" ]]; then
    TASK_SEND_FAILED=1
    _task_gate_delivery_log error "$task_ids" "" "" \
      "gate owner ${hid} has no telegram id on record — held on the agent rail (DIVE-3342)" \
      "sudo 5dive human add ${hid} --telegram=<chat id>"
    return 0
  fi
  # The narrowing invariant: on record is not the same as reachable on THIS bot.
  if ! jq -e --arg c "$chat" '(.allowFrom // []) | index($c) != null' "$access_file" >/dev/null 2>&1; then
    TASK_SEND_FAILED=1
    _task_gate_delivery_log error "$task_ids" "" "" \
      "gate owner ${hid} is not paired to this bot (chat ${chat} absent from access.json allowFrom) — held on the agent rail rather than sent to whoever is (DIVE-3342)" \
      "have ${hid} /start this agent's bot, or route the gate to an agent ${hid} owns"
    return 0
  fi
  _task_post_owner_target "$token" "$chat" "" "$text" "$access_file" "$reply_markup" "$task_ids"
  # Remembered so a follow-on courtesy line ("…and 3 more gates") goes to the SAME
  # person instead of resolving from nothing and fanning out.
  [[ "$TASK_SEND_DELIVERED" == "1" ]] && TASK_GATE_LAST_OWNER="$hid"
  _task_stamp_confirmed_delivery "$task_ids"
  return 0
}

# _task_stamp_human_owner <ident|numeric id> — DIVE-3342. Resolve and record the
# person this gate belongs to. No-op when the registry is unused (nothing to
# resolve, and a NULL there keeps every existing row exactly as it reads today) or
# when the row already names one.
_task_stamp_human_owner() {
  local key="${1:-}" numid who
  [[ -n "$key" ]] || return 0
  _human_registry_active || return 0
  if [[ "$key" =~ ^[0-9]+$ ]]; then numid="$key"
  else numid=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$key");" 2>/dev/null); fi
  [[ "$numid" =~ ^[0-9]+$ ]] || return 0
  local cur; cur=$(db "SELECT COALESCE(human_owner,'') FROM tasks WHERE id=${numid};" 2>/dev/null)
  [[ -z "$cur" ]] || return 0
  who=$(_human_gate_recipient "$numid")
  [[ -n "$who" ]] || return 0
  db "UPDATE tasks SET human_owner=$(sqlq "$who") WHERE id=${numid};" 2>/dev/null || true
}

# _task_close_notify — DM the paired human a one-line ✅/⚠️ summary when a task
# is closed with --notify (used by the heartbeat nudge so autonomous queue work
# surfaces a finish line without full progress streaming). Best-effort: every
# miss returns 0 so it can't fail the status write the caller just committed.
_task_close_notify() {
  local ident="$1" verb="$2" result="$3"
  _task_owner_channel || return 0
  local text
  if [[ "$verb" == "cancel" ]]; then
    text="⚠️ [${ident}] cancelled"
  else
    text="✅ [${ident}] done"
  fi
  # Ping shows only the result's FIRST line — done-results lead with a one-line
  # summary; a full paragraph is too noisy on the owner's phone. The complete
  # result stays on the record (`task show` renders all of it).
  [[ -n "$result" ]] && text+=": ${result%%$'\n'*}"
  _task_send_owner "$text" ""
  return 0
}

# task_need_notify — DIVE-105: the instant a human gate is filed, DM the paired
# human ONE alert so it doesn't sit unseen until someone opens the dashboard.
# Best-effort + self-gating in the shape of mirror_interagent_outbound, and
# reusing its _mirror_post send path (migration self-heal included). EVERY exit
# path returns 0: a missing token / access.json / dead Telegram call must NEVER
# block or fail the gate write (the DB UPDATE already committed before we run).
# The caller also invokes us as `... || true`, so set -e can't trip on anything
# inside either.
#
# Works whether `task need` is run directly as agent-<name> (the common path —
# task verbs need no sudo) OR via sudo: the agent is resolved the same way
# task_actor does; the token comes from the group-claude-readable connector
# file (or an inherited env var); and access.json is found by probing the
# per-type channel dirs (own file when direct, root-readable when sudo).
# _task_mint_drop_link — DIVE-931. Mint a one-time secure credential drop link
# for a secret gate (api POST /drop/mint, box-authed with the box's connectord
# token). Echoes exactly one of:
#   <url>|<ttlMinutes>   a live burnable link (api pushes the value to the box)
#   ONBOX                 api holds no usable token for this box -> on-box path
#   (empty)               mint unavailable (self-hosted / api down) -> legacy text
# Best-effort: never fails the caller and never touches the secret VALUE (only the
# destination coordinates). The value crosses solely via the drop page -> stdin.
_task_mint_drop_link() {
  local ident="$1" secret_key="$2" connector="$3"
  local token="" env_file="/etc/5dive/connectord.env"
  [[ -n "${CONNECTORD_TOKEN:-}" ]] && token="$CONNECTORD_TOKEN"
  [[ -z "$token" && -r "$env_file" ]] && token=$(sed -n 's/^CONNECTORD_TOKEN=//p' "$env_file" | head -1)
  [[ -n "$token" ]] || return 0   # no box identity (self-hosted OSS) -> legacy text
  local api="${FIVE_API_BASE:-https://api.5dive.com}" body resp
  body=$(jq -nc --arg t "$ident" --arg k "$secret_key" --arg c "$connector" \
           '{taskIdent:$t, secretKey:$k, connector:$c, ttlMinutes:30}') || return 0
  resp=$(curl -fsS --max-time 10 -X POST "${api%/}/drop/mint" \
           -H "authorization: Bearer ${token}" -H "content-type: application/json" \
           -d "$body" 2>/dev/null) || return 0
  if [[ "$(printf '%s' "$resp" | jq -r '.useOnBoxPath // false' 2>/dev/null)" == "true" ]]; then
    echo "ONBOX"; return 0
  fi
  local url ttl
  url=$(printf '%s' "$resp" | jq -r '.url // empty' 2>/dev/null)
  ttl=$(printf '%s' "$resp" | jq -r '.ttlMinutes // empty' 2>/dev/null)
  [[ -n "$url" ]] || return 0
  echo "${url}|${ttl:-15}"
}

# Render the canonical tap keyboard for one gate. Kept separate from the alert
# prose so heartbeat re-nags can combine N gates into one message without
# drifting from the callback contract used by the initial task-need alert.
# _task_secret_gate_cta <ident> <row_id> <secret_key> <connector> <drop> — DIVE-2411.
# The "how do I clear this" instruction for a secret gate, extracted from the
# notify body so the PROSE is testable. Four shapes, in order of how directly the
# value can land: a minted burnable drop link, the on-box `secret write` (link
# unavailable / tokenless box), an explicitly declared out-of-band channel, and —
# for rows filed before this ticket — no delivery path at all, where the only
# honest instruction is that the gate must be re-filed. That last branch used to
# read "put the key where I expect it (my .env / our channel), then tap ✅
# Provided", which on a gate that never named a target asks the human to do
# something undefined and then attest to it; that attestation is what produced
# the DIVE-2232 record — signed, nonced, human-attested, empty.
_task_secret_gate_cta() {
  local ident="$1" numid="$2" secret_key="$3" connector="$4" _drop="$5"
  if [[ "$_drop" == "ONBOX" ]]; then
    printf '%s' "🔑 [${ident}] needs the ${secret_key} credential. On the box, drop it straight in (never paste it here):"$'\n'"  echo -n \"\$SECRET\" | sudo 5dive secret write ${secret_key} --connector=${connector} --task=${ident}"$'\n'"That writes it and clears this gate. Or tap ✅ Provided once it is done."
  elif [[ -n "$_drop" ]]; then
    local _url="${_drop%%|*}" _ttl="${_drop##*|}"
    printf '%s' "🔑 [${ident}] needs the ${secret_key} credential. Drop it securely (single-use, expires in ${_ttl}m):"$'\n'"${_url}"$'\n'"The value goes straight onto your box and is never shown in chat. Prefer the box? echo -n \"\$SECRET\" | sudo 5dive secret write ${secret_key} --connector=${connector} --task=${ident}"
  elif [[ -n "$secret_key" && -n "$connector" ]]; then
    # Target named, mint unavailable (api unreachable / tokenless): still name the
    # target, because the box-side write is a real delivery path.
    printf '%s' "🔑 [${ident}] needs the ${secret_key} credential. The drop link could not be minted right now, so put it in on the box (never paste it here):"$'\n'"  echo -n \"\$SECRET\" | sudo 5dive secret write ${secret_key} --connector=${connector} --task=${ident}"$'\n'"That writes it and clears this gate. Or tap ✅ Provided once it is done."
  else
    local _oob; _oob=$(db "SELECT COALESCE(secret_oob,'') FROM tasks WHERE id=${numid};" 2>/dev/null || echo "")
    if [[ -n "$_oob" ]]; then
      printf '%s' "🔑 [${ident}] needs a credential, delivered out-of-band: ${_oob}. Put it there, then tap ✅ Provided below — never paste it in this chat. Tap not working? On the box: sudo 5dive task answer ${ident}"
    else
      printf '%s' "⚠️ [${ident}] asks for a credential but names NO delivery path (no drop target, no declared out-of-band channel), so there is nowhere for the value to go and this gate cannot be cleared as it stands. Do NOT paste the credential here. It has to be re-filed with a delivery path: 5dive task need ${ident} --type=secret --secret-key=<ENV_NAME> --connector=<stem> --ask=\"…\" (DIVE-2411)."
    fi
  fi
}

# DIVE-2818: IS THIS GATE HIGH-STAKES? lodar scoped the reply-to-clear prompt on
# the DIVE-2802 gate (answered 2026-08-05) to "spend / secrets / irreversible",
# explicitly NOT to every tier-2 gate, because the citation window is a hardcoded
# 3600s ceiling and a prompt that pushes everyone at a path that expires is a tax
# on the routine case.
#
# THE DISCRIMINATOR IS DECLARED, NEVER INFERRED FROM THE ASK'S WORDING. The other
# way to write this is keyword-sniffing the prose for "spend"/"delete"/"prod", and
# DIVE-2629 already measured what that costs on this exact rail: the word
# `teardown` appearing only inside a git BRANCH NAME moved a gate's tier. A rule
# that decides how a human is asked to authenticate must not be guessable from
# text the filer wrote for a different purpose.
#
# Two declarations qualify, and between them they cover lodar's three words:
#
#   --needs=<capability>   the DIVE-2241 sealed constants. `spend_authority` IS
#                          "spend"; `secret_provision` IS "secrets"; and
#                          `human_tap` is documented at the constant itself as
#                          "a person's call: brand, strategy, AN IRREVERSIBLE
#                          CHOICE", which is the third word.
#   --type=secret          a gate that hands over a credential is "secrets" by its
#                          own declared type, whether or not it ALSO declared the
#                          capability. This is not an inference: the filer typed
#                          the type.
#
# A bare approval / manual / decision gate that declared no capability is the
# routine tier-2 case lodar excluded, and its message is unchanged.
#
# Read from the ROW, not from a parameter (DIVE-2090): both notify sites call this
# and the persisted gate is the state that decides. `needs_capability` is stored
# VERBATIM as the filer typed it, so the normalising `_gate_needs_human` is what
# must read it — comparing against the constant list directly would make
# `--needs=Human-Tap` silently not-high-stakes, which is the DIVE-2241 near-miss
# class landing again one layer up.
_task_gate_high_stakes() { # <row_id>
  local _rid="${1:-}" _cap="" _ty=""
  [[ "$_rid" =~ ^[0-9]+$ ]] || return 1
  _cap=$(db "SELECT COALESCE(needs_capability,'') FROM tasks WHERE id=${_rid};" 2>/dev/null || printf '')
  _ty=$(db "SELECT COALESCE(need_type,'') FROM tasks WHERE id=${_rid};" 2>/dev/null || printf '')
  [[ "$_ty" == "secret" ]] && return 0
  _gate_needs_human "$_cap"
}

# DIVE-2818: the reply-to-clear CTA. TAP IS PRIMARY, REPLY IS RECOVERY — the
# re-scope olivia posted on the parent (2026-08-06) after lodar ruled live:
# "asking user to type is not good ux". That was not a preference stated in the
# abstract, it was observed: he tried the typed path, was refused because he sent
# the answer without the ident, then tapped the button and it worked first press.
# The earlier framing here made the typed string the DEFAULT ("Strongest clear")
# and the button a closing footnote; this is that inversion undone.
#
# NON-FORGEABILITY IS UNCHANGED by the reordering, which is why it is only a copy
# change: `_gate_channel_session_ok` condition 2 still requires the ident in the
# human's OWN words, and no plugin may compose that string for him. Which path
# the copy advertises first is not a security property.
#
# It must still print the EXACT string to send, because condition 5 requires the
# human's own text to contain BOTH the ident AND the answer value — "yes" alone
# refuses, and so does a reply that names the gate but not the decision. A
# recovery path that is described rather than quoted is a recovery path that
# refuses on the day it is finally needed.
#
# PRINTS NOTHING WHERE NO TAP BUTTON IS ATTACHED (<has_tap> empty), because
# recovery is recovery FOR something. The one high-stakes class that reaches here
# button-less is the DIVE-2411 secret gate naming NO delivery path, where the
# button is withheld deliberately: there, "reply <ident> provided" would clear the
# gate over an empty payload — the exact false record DIVE-2411 closed, walking
# back in through the typed door. The caller passes the markup it ACTUALLY
# computed rather than this function re-deriving the predicate, so the button and
# the copy about the button cannot drift.
#
# The value emitted here is the same string `task answer --value` receives on the
# tap path (approved/denied, done, provided, or the option VALUE), so the human's
# message and the agent's `--value` corroborate instead of merely coexisting.
_task_gate_reply_cta() { # <ident> <need_type> <options> <recommend> <has_tap>
  local _id="${1:-}" _ty="${2:-}" _opts="${3:-}" _rec="${4:-}" _tap="${5:-}" _ex="" _alt="" _out=""
  [[ -n "$_id" ]] || return 0
  [[ -n "$_tap" ]] || return 0
  case "$_ty" in
    approval) _ex="approved"; _alt="denied" ;;
    manual)   _ex="done" ;;
    secret)   _ex="provided" ;;
    decision)
      # Same split rule as _task_gate_reply_markup (split '|', trim, drop empties)
      # so the string offered here cannot drift from the option the buttons carry.
      _ex=$(printf '%s' "$_opts" | jq -Rr --arg r "$_rec" '
        ($r | gsub("^\\s+|\\s+$"; "")) as $rr
        | [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ] as $o
        | (if ($rr|length) > 0 and ($o | index($rr)) != null then $rr else ($o[0] // "") end)' 2>/dev/null) || _ex=""
      _alt=$(printf '%s' "$_opts" | jq -Rr --arg c "$_ex" '
        [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) | select(. != $c) ] | (.[0] // "")' 2>/dev/null) || _alt=""
      ;;
    *) return 0 ;;
  esac
  [[ -n "$_ex" ]] || return 0
  _out="🔐 High-stakes gate (spend, secrets or irreversible)."$'\n'
  _out+="Tap a button on this message to answer. That is the expected path, and a tap is never rejected."$'\n\n'
  _out+="Recovery only, if the button is stale, already used, or the tap rail is down: reply in this chat with exactly"$'\n'
  _out+="    ${_id} ${_ex}"
  [[ -n "$_alt" ]] && _out+=$'\n'"(or:  ${_id} ${_alt})"
  _out+=$'\n\n'"A typed reply is attested by Telegram, so the record can show a human answered rather than the agent that asked. A reply stays citable for 1 hour."
  printf '%s' "$_out"
}

_task_gate_reply_markup() { # <row_id> <type> <options> <recommend> <nonce> <channel_type> [label]
  local numid="$1" need_type="$2" options="$3" recommend="$4" human_nonce="$5" channel_type="$6" label="${7:-}"
  [[ -n "$label" ]] && label="[${label}] "
  local np=""; [[ -n "$human_nonce" ]] && np=":${human_nonce}"
  local reply_markup=""
  if [[ "$channel_type" =~ ^(claude|codex|grok|antigravity)$ ]]; then
    if [[ "$need_type" == "decision" && -n "$options" ]]; then
      # DIVE-2233: the decision buttons now carry the per-gate nonce suffix too, exactly
      # like approval/secret/manual. This is what makes a tier-2 decision tap PROVABLE
      # rather than merely asserted — the raw nonce goes into callback_data, which the
      # agent LLM never sees, and comes back as --human-proof.
      #
      # NO PLUGIN CHANGE IS NEEDED, and that is a measured fact, not an assumption: the
      # deployed contract is `TNA_RE = /^tna:(\d+):([^:]+)(?::([0-9a-f]{32}))?$/`, whose
      # nonce group is generic over the token — it was never conditioned on the gate type.
      # Verified against the INSTALLED artifacts (telegram 0.5.35 and 0.5.36 under
      # ~/.claude/plugins/cache), not just the plugins repo. The emitter here was the only
      # type-conditional half of the contract. `$np` is empty for gates that mint no nonce,
      # so the callback_data is byte-identical to today's for every one of them.
      reply_markup=$(printf '%s' "$options" | jq -Rc --arg id "$numid" --arg r "$recommend" --arg p "$label" --arg np "$np" '
        ($r | gsub("^\\s+|\\s+$"; "")) as $rr
        | [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ] as $o
        | ($o | to_entries
           | sort_by(.value == $rr and ($rr|length)>0 | not)
           | reduce .[] as $e ({rows: [], cur: [], w: 0};
               (($e.value | length) + (if $e.value == $rr and ($rr|length)>0 then 2 else 0 end)) as $len
               | {text: ($p + (if $e.value == $rr and ($rr|length)>0 then "⭐ " + $e.value else $e.value end)), callback_data: ("tna:" + $id + ":" + ($e.key | tostring) + $np)} as $btn
               | if (.cur | length) > 0 and ((.cur | length) >= 3 or (.w + $len + 2) > 24)
                 then {rows: (.rows + [.cur]), cur: [$btn], w: $len}
                 else {rows: .rows, cur: (.cur + [$btn]), w: (.w + $len + 2)}
                 end)
           | .rows + (if (.cur | length) > 0 then [.cur] else [] end)) as $kb
        | if ($kb | length) > 0 then {inline_keyboard: $kb} else empty end' 2>/dev/null) || reply_markup=""
    elif [[ "$need_type" == "approval" ]]; then
      local rl; rl=$(printf '%s' "$recommend" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
      # DIVE-2354: on a confirm-after-send gate the button that says "Approve" is
      # asking for a claim the human cannot truthfully make — the action is already
      # out. Only the LABELS change; callback_data stays byte-identical
      # (tna:<id>:approved|denied), so every shipped plugin handler is untouched.
      local _bm; _bm=$(db "SELECT COALESCE(gate_mode,'') FROM tasks WHERE id=${numid};" 2>/dev/null || echo "")
      local _yes="✅ Approve" _no="🚫 Deny"
      if [[ "$_bm" == "confirm-after-send" ]]; then _yes="✅ Confirm (after the fact)"; _no="🚫 Not authorised"; fi
      local appr='{"text":"'"${label}${_yes}"'","callback_data":"tna:'"${numid}"':approved'"${np}"'"}'
      local deny='{"text":"'"${label}${_no}"'","callback_data":"tna:'"${numid}"':denied'"${np}"'"}'
      case "$rl" in
        approve|approved) appr='{"text":"'"${label}"'⭐ '"${_yes}"'","callback_data":"tna:'"${numid}"':approved'"${np}"'"}'
                          reply_markup='{"inline_keyboard":[['"$appr"','"$deny"']]}' ;;
        deny|denied)      deny='{"text":"'"${label}"'⭐ '"${_no}"'","callback_data":"tna:'"${numid}"':denied'"${np}"'"}'
                          reply_markup='{"inline_keyboard":[['"$deny"','"$appr"']]}' ;;
        *)                reply_markup='{"inline_keyboard":[['"$appr"','"$deny"']]}' ;;
      esac
    elif [[ "$need_type" == "secret" ]]; then
      # DIVE-2411: the ✅ Provided affordance is offered ONLY on a secret gate that
      # names a delivery path — a drop target (secret_key+connector) or an explicit
      # --out-of-band declaration. On a gate with neither, the button MEANS
      # something the message never asked for: "I already put it where you said",
      # on a gate that never said where. Measured on DIVE-2232 — a real human
      # holding the raw nonce tapped it, and the row came back answered, signed,
      # nonced and uid-stamped over an EMPTY payload. Nothing had landed anywhere.
      #
      # THE FIX IS HERE, at the mint/affordance layer, and that placement is the
      # point: the tap that produced the false record landed on a BATCHED six-gate
      # message, and the batcher has no idea what any of the six drops targeted. It
      # could not have known to withhold the button, so it cannot be the layer that
      # decides. This function is called by BOTH the single-gate notify and the
      # batch re-send, and it reads the row, so both are covered without either
      # caller changing.
      #
      # Read from the ROW, not from a parameter: the state that decides is the
      # persisted gate, not what a caller happens to be holding (DIVE-2090).
      local _sk_row _oob_row
      _sk_row=$(db "SELECT COALESCE(secret_key,'')||COALESCE(connector,'') FROM tasks WHERE id=${numid};" 2>/dev/null || echo "")
      _oob_row=$(db "SELECT COALESCE(secret_oob,'') FROM tasks WHERE id=${numid};" 2>/dev/null || echo "")
      if [[ -n "$_sk_row" || -n "$_oob_row" ]]; then
        reply_markup='{"inline_keyboard":[[{"text":"'"${label}"'✅ Provided","callback_data":"tna:'"${numid}"':provided'"${np}"'"}]]}'
      else
        reply_markup=""
      fi
    elif [[ "$need_type" == "manual" ]]; then
      reply_markup='{"inline_keyboard":[[{"text":"'"${label}"'✅ Done","callback_data":"tna:'"${numid}"':done'"${np}"'"}]]}'
    fi
  fi
  printf '%s' "$reply_markup"
}

# DIVE-1968 criterion 3 — THE DELIVERY ASSERTION.
#
# Every branch below records a verdict: an `ok` row, an `error` row, or a
# privileged re-send whose child records one. The bug is what happens when NONE of
# them runs. Measured on this box while reading the residual: of 9 real post-fix
# gates, 5 recorded NEITHER an ok nor an error row — they were filed, they returned
# 0, and they left no trace in the only dataset anyone consults to judge whether
# the gate rail works. That is strictly worse than a logged failure. A logged
# failure is a bug report; silence is indistinguishable from success, and it is
# what let this whole class survive a live end-to-end verification of DIVE-1927.
#
# So the delivery verdict is now MANDATORY rather than emergent. If the inner path
# returns without any delivery row, we synthesise the missing verdict (error, with
# a detail that names the hole rather than guessing a cause), warn loudly at the
# filer, and downgrade a bare `return 0` to rc 3 — FILED, NOT NOTIFIED. rc 3 is an
# existing, handled contract: the gate row stands and is answerable on the
# dashboard, gate_pinged_at stays NULL, and the re-nag sweep escalates it. That
# matters more than the log line: an unrecorded delivery used to also claim the
# ping, which suppressed the one mechanism that would have rescued it.
#
# Deliberately a wrapper around the unchanged body: the invariant is "no exit from
# this function without a verdict", and a wrapper enforces it for the four exits
# that exist today AND for whichever ones get added later — which is the actual
# failure mode, since none of today's exits was written intending to be silent.
# The verdict FOLLOWS THE DELIVERY STATE — it is not assumed from the silence. Two
# different holes hide behind "no row", and collapsing them would have traded a
# missing row for a WRONG one:
#   * delivered, unrecorded  -> the send was confirmed (TASK_SEND_DELIVERED=1) and
#     only the bookkeeping is missing. Backfill the `ok` row. This is the larger
#     half of the measured 5, and calling it a failure would have manufactured
#     error rows for gates that reached their human — re-contaminating the dataset
#     with the opposite bias, on the very ticket about a mis-measured one.
#   * neither delivered nor recorded -> nobody can show a human was reached.
#     Synthesise the error row and downgrade rc 0 to 3.
# Found by two pre-existing tests (gate_channelless_escalation, gate_filer_own_channel)
# going red against the first cut, which asserted on the row alone. They were right
# and the assertion was wrong: both drive a stubbed send that reports DELIVERED,
# which is exactly the delivered-but-unrecorded shape. Both pass UNCHANGED here —
# that they were not edited to accommodate this diff is the point.
#
# DIVE-2011: the assertion now fences the LEAD-ROUTE rail too, by dispatch rather
# than by a second copy. A routed gate never reached this wrapper at all — it sent
# its handoff inline and `return`ed before the notify path was called — so
# "no exit without a delivery verdict" was true of the human ping ONLY, on the
# rail that now carries most builder gates. Measured: DIVE-1989's approval gate was
# filed and lead-cleared inside the post-assertion window and gate-notify.log holds
# nothing for it. One wrapper, two deliverers: a parallel assertion would be a
# second thing to go inert, which is the failure mode of the thing being fixed.
task_need_notify() {
  TASK_GATE_DELIVERY_ROWS=0
  TASK_SEND_DELIVERED=0
  local _rc=0
  # DIVE-3342: STAMP the gate's human owner here, once, before any delivery — the
  # one point both the routed and unrouted filing paths pass through. Recorded
  # rather than re-derived at send time for the DIVE-3171 reason: agents_org and
  # human_agents are both writable state, so a chart edit between filing and the
  # 24h rail expiry would silently move a live gate to a different person, and the
  # row would have no witness to what the routing DECIDED. Never overwrites an
  # existing value (an explicit `--owner=` or an earlier stamp on a re-nagged
  # gate); empty when nobody resolves, which is a real answer and not a broadcast.
  _task_stamp_human_owner "$1" || true
  if [[ -n "${TASK_GATE_ROUTE_TO:-}" ]]; then
    _task_need_route_deliver "$@" || _rc=$?
  else
    _task_need_notify_deliver "$@" || _rc=$?
  fi
  if (( ${TASK_GATE_DELIVERY_ROWS:-0} == 0 )); then
    if [[ "${TASK_SEND_DELIVERED:-0}" == "1" ]]; then
      _task_gate_delivery_log ok "$1" "${TASK_CH_CHAT:-}" "${TASK_SEND_MESSAGE_IDS%%,*}" \
        "confirmed send, backfilled by the delivery assertion (the notify path recorded no row of its own)"
    else
      _task_gate_delivery_log error "$1" "" "" \
        "no delivery verdict recorded by the notify path (rc=${_rc}) and no confirmed send; delivery is UNVERIFIABLE, treating as unnotified"
      warn "$1: gate delivery is UNVERIFIABLE — the notify path exited (rc=${_rc}) with neither a confirmed send nor a recorded verdict, so nobody can show a human was reached. Treated as FILED UNNOTIFIED: the re-nag will escalate it. Answer on the dashboard or: 5dive task answer $1"
      (( _rc == 0 )) && _rc=3
    fi
  fi
  return $_rc
}

# DIVE-2011 — the LEAD-ROUTE rail's deliverer, the routed twin of
# _task_need_notify_deliver. Same wrapper, same telemetry, same rc contract.
#
# What it replaces, verbatim from the branch it was lifted out of:
#
#   ( 5dive agent send "$_reviewer" "$_hmsg" --from="$actor" >/dev/null 2>&1 & ) || true
#   ok "$ident routed to $_reviewer ..."
#
# Three defects in two lines, and the third is the one that hides the other two:
# the send is backgrounded, both streams go to /dev/null, and `|| true` sits
# outside the subshell — so its exit status is not merely ignored, it is
# STRUCTURALLY UNOBSERVABLE. "routed to X" printed whether or not X existed, was
# running, or had a live tmux pane to inject into.
#
# The fix has to survive one hard constraint: `5dive agent send` waits up to 45s
# for the receiver's input prompt (wait_agent_input_ready) and a BUSY-but-healthy
# peer burns that whole budget. So neither of the two obvious fixes works —
# a synchronous send stalls the filer for the better part of a minute on the
# COMMON case, and a `timeout`-truncated one kills the child DURING the readiness
# wait, i.e. before the inject, converting a delivered handoff into a lost one.
# Making the send observable must not make it worse.
#
# So: observe the FAST FAILURES synchronously and let the slow tail run detached.
# Every shape we actually care about — unknown agent (require_agent), dead tmux
# session (E_NOT_RUNNING), sudo denied (the DIVE-1337 scoped-a2a gap), CLI absent
# — is decided in well under a second, BEFORE the readiness wait. A short poll on
# the child's own rc therefore catches all of them at the filer, while a peer that
# is merely mid-turn is left to finish in the background.
#
# THE CHILD WRITES THE ROW, not the parent, and writes its rc file only AFTER the
# row lands — so "parent observed an rc" implies "the row is already on disk", and
# there is exactly one writer per gate with no double-count. The parent credits
# TASK_GATE_DELIVERY_ROWS for the same reason the privileged re-send does: the row
# exists, it was just written one process over, and re-logging here would
# re-inflate the very telemetry DIVE-1968 spent a round decontaminating.
#
# The in-flight case is reported as in-flight, NOT as delivered and NOT as failed.
# Calling it a failure would manufacture error rows for healthy busy peers — the
# opposite-direction bias, on the ticket about a mis-measured dataset — and calling
# it delivered is the lie being removed. TASK_GATE_ROUTE_STATE carries the three
# states out to the caller's ok line, so the printed claim never exceeds what was
# observed. rc stays on the existing 0/3 contract (3 = filed, NOT notified) rather
# than minting a new code the human path's callers would not recognise.
TASK_GATE_ROUTE_TO=""
TASK_GATE_ROUTE_ROLE=""
TASK_GATE_ROUTE_STATE=""
_task_need_route_deliver() {
  local ident="$1" need_type="$2" ask="$3" options="${4:-}" recommend="${5:-}"
  local reviewer="${TASK_GATE_ROUTE_TO:-}" filer="${TASK_GATE_FILER:-}"
  local role="${TASK_GATE_ROUTE_ROLE:-review}"
  TASK_GATE_ROUTE_STATE="failed"
  [[ -n "$reviewer" ]] || return 3
  # The ident, not the row id: _task_gate_delivery_log resolves numeric ids with a
  # DB read, and the detached child must not touch the store the parent is writing.
  local msg="🧭 [${ident}] routed to you for ${role} (${need_type} gate). ${ask}"
  [[ -n "$options" ]]   && msg+=" Options: ${options}."
  [[ -n "$recommend" ]] && msg+=" ${filer} recommends: ${recommend}."
  msg+=" Resolve: 5dive task answer ${ident} --value=\"<choice>\" — or re-file to escalate to the human."
  if ! command -v 5dive >/dev/null 2>&1; then
    TASK_NOTIFY_FAIL_REASON="the 5dive CLI is not on PATH here, so the handoff to ${reviewer} could never be sent"
    _task_gate_delivery_log error "$ident" "agent:${reviewer}" "" \
      "lead-route handoff to ${reviewer} not attempted: no 5dive CLI on PATH" \
      "the gate stands and the re-nag escalates it"
    return 3
  fi
  local _d; _d=$(mktemp -d "${TMPDIR:-/tmp}/5dive-gate-route.XXXXXX" 2>/dev/null) || _d=""
  if [[ -z "$_d" ]]; then
    # No scratch dir means no rc channel, so the send would be unobservable again.
    # Send it anyway (delivery beats measurement) but record the blind spot as what
    # it is rather than claiming a verdict we cannot have.
    # DIVE-3318: a one-way machine notice nobody replies to is not a round — see
    # a2a_round_guard. NOT a sender exemption; never set this by hand.
    ( _5DIVE_A2A_NOTIFY=1 5dive agent send "$reviewer" "$msg" --from="$filer" >/dev/null 2>&1 & ) || true
    TASK_GATE_ROUTE_STATE="inflight"
    _task_gate_delivery_log error "$ident" "agent:${reviewer}" "" \
      "lead-route handoff to ${reviewer} dispatched UNOBSERVED: no writable scratch dir for the send's exit status" \
      "the gate stands and the re-nag escalates it"
    return 0
  fi
  # Detached so it outlives this command, but no longer mute: the child logs the
  # terminal verdict itself, then publishes its rc, then cleans up its own dir (so
  # cleanup has a single owner and cannot race the parent's poll).
  ( {
      local _crc=0 _cout=""
      # DIVE-3318: a one-way machine notice nobody replies to is not a round — see
      # a2a_round_guard. NOT a sender exemption; never set this by hand.
      _cout=$(_5DIVE_A2A_NOTIFY=1 5dive agent send "$reviewer" "$msg" --from="$filer" 2>&1) || _crc=$?
      if (( _crc == 0 )); then
        _task_gate_delivery_log ok "$ident" "agent:${reviewer}" "" \
          "lead-route handoff delivered to ${reviewer} (${role}) via 5dive agent send"
      else
        _task_gate_delivery_log error "$ident" "agent:${reviewer}" "" \
          "5dive agent send to ${reviewer} failed rc=${_crc}: ${_cout//$'\n'/ }" \
          "the gate stands and the re-nag escalates it"
      fi >/dev/null 2>&1
      printf '%s' "$_crc" >"${_d}/rc" 2>/dev/null || true
      sleep 5; rm -rf "$_d" 2>/dev/null || true
    } & ) || true
  # Bounded observation window. 3s is comfortably past every fast-failure shape
  # above and far short of the 45s readiness wait, so it separates "cannot deliver"
  # from "not delivered YET" without paying for the latter.
  local _w=0 _rc=""
  while (( _w < 30 )); do
    if [[ -s "${_d}/rc" ]]; then _rc=$(cat "${_d}/rc" 2>/dev/null) || _rc=""; break; fi
    sleep 0.1; _w=$((_w+1))
  done
  # The child owns the row in every branch below; credit it so the wrapper's
  # assertion does not synthesise a duplicate (see the privileged re-send).
  TASK_GATE_DELIVERY_ROWS=$(( ${TASK_GATE_DELIVERY_ROWS:-0} + 1 ))
  if [[ -z "$_rc" ]]; then
    TASK_GATE_ROUTE_STATE="inflight"
    return 0
  fi
  if [[ "$_rc" == "0" ]]; then
    TASK_SEND_DELIVERED=1
    TASK_GATE_ROUTE_STATE="delivered"
    return 0
  fi
  TASK_GATE_ROUTE_STATE="failed"
  TASK_NOTIFY_FAIL_REASON="the handoff send to ${reviewer} failed (rc=${_rc})"
  warn "${ident}: the lead-route handoff to ${reviewer} FAILED (5dive agent send rc=${_rc}) — the gate is filed and routed on the record but ${reviewer} was NOT pinged. The re-nag escalates it (<=15 min); answerable now with: 5dive task answer ${ident}"
  return 3
}

_task_need_notify_deliver() {
  local ident="$1" need_type="$2" ask="$3" options="$4" recommend="${5:-}"
  local secret_key="${6:-}" connector="${7:-}" human_nonce="${8:-}"
  local precedent_cite="${9:-}"  # OSS-11: prior-answer citation, empty if none
  # The delivery helper accepts numeric task row ids so it can stamp exactly the
  # alert(s) confirmed by Telegram. Resolve before channel routing so even a
  # total no-channel failure can be recorded against the gate.
  local numid; numid=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$ident");")
  # Resolve bot token + the human's DM/group targets (TASK_CH_* globals). The
  # matched access type (TASK_CH_TYPE) gates the tap-to-answer buttons below.
  # DIVE-1243: never DROP a gate alert silently. The filing agent being unpaired
  # (no access.json — the codex-gate-invisible bug: its gate was filed but no one
  # was ever pinged) used to `return 0` here and the gate sat unseen. Warn, then
  # fall back to the org lead's channel so the alert still surfaces; if even that
  # is missing, warn again — the gate still shows on the dashboard "Needs you"
  # card, but we never fail silently.
  # DIVE-1927: DIVE-1243's lead fallback existed but never fired in practice — it
  # probed the lead's channel by READABILITY (`-r access.json`), and a sibling
  # agent can never read a peer's 0600 access.json, so every escalation collapsed
  # to "no lead channel either" and `return 0` (a plain OK from `task need`). That
  # is the succeeding-in-appearance class aimed at the escalation rail itself:
  # dev3's DIVE-1926 manual gate was filed, reported OK, and reached NOBODY.
  # Three ordered attempts now, and NO silent success:
  #   1. nearest READABLE channel walking UP reports_to (multi-hop, not one).
  #   2. reachable-but-unreadable: re-run the send as root over sudo, which can
  #      read every access.json.
  #   3. nobody up the chain is paired at all -> return 2, and the caller UNDOES
  #      the gate and fails loudly. A gate nobody can answer is worse than a
  #      refused one: the refusal is visible, the silence is not.
  TASK_NOTIFY_ESCALATED_FROM=""; TASK_NOTIFY_FAIL_REASON=""
  # In a root sweep (heartbeat cron: no SUDO_UID, USER=root) the caller is not
  # the filer, so everything below must key off the gate row's own filer.
  local _self; _self="${TASK_GATE_FILER:-}"; [[ -n "$_self" ]] || _self=$(task_actor "")
  # DIVE-1968: try the FILER'S OWN channel BY NAME before anything else.
  # `_task_owner_channel` resolves the CALLER (auto_sender_from_sudo -> $SUDO_USER,
  # else $USER, and only when either is agent-*), never the gate's filer. So it is
  # a structural no-op in precisely the two contexts that matter — the root re-nag
  # sweep and the privileged re-send, where the name resolves EMPTY and
  # `_task_agent_channel ""` returns 1 immediately — and when a PEER agent drives
  # the send it resolves that peer's channel, i.e. alerts the wrong human. The
  # chain then walks strictly UP from the filer, so a top-of-org filer (olivia,
  # quinn: reports_to='') comes back empty and we report "no paired channel for
  # filer X or anyone above it" while X has a working channel sitting right there.
  # Root CAN read a peer's 0600 access.json, which is the whole reason the
  # privileged path exists — so by-name resolution is exactly what it was missing.
  # This is the answer to "why did _task_owner_channel not fire for olivia": it
  # never could. Prepending the filer is not papering over a second bug; the
  # second bug WAS that the own-channel probe is caller-scoped.
  if [[ -n "$_self" ]] && _task_agent_channel "$_self"; then
    : # the filer's own channel — the alert belongs to THEIR paired human
  elif ! _task_owner_channel; then
    warn "$ident: filing agent (${_self:-?}) has no paired channel — escalating up the org chart for the gate alert"
    local _fb=""
    _task_chain_channel "$_self" && _fb="$TASK_CH_AGENT"
    if [[ -n "$_fb" ]]; then
      TASK_NOTIFY_ESCALATED_FROM="$_self"
      warn "$ident: gate alert escalated to ${_fb} (nearest paired agent above the unpaired filer ${_self:-?})"
    else
      local _paired; _paired=$(_task_chain_paired "$_self") || _paired=""
      if [[ -n "$_paired" && $EUID -ne 0 && -z "${TASK_GATE_ESCALATING:-}" ]]; then
        if _task_gate_escalate_via_sudo "$ident" "$human_nonce"; then
          warn "$ident: gate alert delivered to ${_paired} via a privileged re-send (its channel is not readable as this agent)"
          # The row for this delivery was written by the CHILD process (it runs the
          # same notify path as root against the same prod store), so nothing is
          # missing from the log — but the counter lives in THIS shell, so credit it
          # here or the delivery assertion below would read a confirmed delivery as
          # an unrecorded one. Counted, not logged: logging here would double-count
          # one send as two rows and re-inflate exactly the telemetry this ticket
          # spent a whole round decontaminating.
          TASK_GATE_DELIVERY_ROWS=$(( ${TASK_GATE_DELIVERY_ROWS:-0} + 1 ))
          return 0
        fi
        warn "$ident: privileged re-send to ${_paired} FAILED${TASK_GATE_ESCALATE_ERR:+ — ${TASK_GATE_ESCALATE_ERR}}"
      fi
      # DIVE-1927 review round 2 (main, off RED CI on PR #160). The first cut
      # refused the gate here, and that equated "no paired TELEGRAM channel" with
      # "no human can answer" — which is false. The dashboard "Needs you" card and
      # `5dive task answer` are real answering surfaces that need no channel at
      # all. Refusing on this branch made a paired bot a hard dependency of the
      # entire gate rail: CI (nothing is ever paired) went red, and with it any
      # solo OSS user who never wired Telegram, any fresh install, any headless
      # box — including `5dive goal`, which could no longer file its plan gate.
      # So the hard refusal is now scoped to the one case where the gate really
      # can reach nobody, and everything else is filed DELIVERABLE-BUT-UNNOTIFIED
      # (rc 3): the row stands, it is answerable, gate_pinged_at stays NULL, and
      # the 15-minute re-nag escalates it. Losing a gate is worse than delaying it.
      if [[ -n "$_paired" ]]; then
        # Someone up the chain IS reachable; we merely could not reach them from
        # HERE. The root re-nag walks the same chain with strictly more privilege
        # and will deliver. Refusing would turn a delayed gate into a lost one —
        # literally the DIVE-1926 case, which the 07:10 re-nag rescued.
        TASK_NOTIFY_FAIL_REASON="the privileged re-send to ${_paired} failed, so delivery is unconfirmed"
        warn "$ident: could not hand this gate to ${_paired} from here — FILED UNNOTIFIED; the heartbeat re-nag escalates it (<=15 min). Answerable now on the dashboard or: 5dive task answer ${ident}"
        _task_gate_delivery_log error "$numid" "" "" "privileged re-send to ${_paired} failed${TASK_GATE_ESCALATE_ERR:+ (${TASK_GATE_ESCALATE_ERR})}; gate filed unnotified, re-nag will escalate"
        return 3
      fi
      # Nobody up the chain is paired. This is still NOT grounds to refuse: the
      # dashboard "Needs you" card, `task inbox` and `task answer` are answering
      # surfaces that need no channel, and tests/gate_parity_smoke.sh asserts
      # exactly that contract ("gate filed CLI-only with no Telegram present").
      # An earlier cut refused here and then tried to scope the refusal to
      # deployments that have channels configured — which still broke the parity
      # smoke, because whether some OTHER agent on the box is paired says nothing
      # about whether THIS gate can be answered. Every attempt to define
      # "nowhere to land" kept mis-firing in an environment I did not control,
      # which is the signal that the condition does not exist. So: always file,
      # and make the non-notification loud, recorded and persistent instead.
      # Only the WORDING forks, because an unnotified gate is routine on a box
      # with no channels and an anomaly on one that notifies.
      if _task_deployment_has_channels; then
        local _shape; _shape=$(_task_filer_chain_shape "${_self:-}")
        TASK_NOTIFY_FAIL_REASON="${_self:-the filer} has no paired channel and neither does anyone above it in the org chart (${_shape})"
        warn "$ident: NO paired channel for ${_self:-?} or anyone above it in the org chart [${_shape}] — gate FILED UNNOTIFIED on a deployment that notifies. Nobody was pinged; answer on the dashboard or: 5dive task answer ${ident}"
        _task_gate_delivery_log error "$numid" "" "" "no paired channel for filer ${_self:-?} or anyone above it; shape=${_shape}; gate filed unnotified on a channel-having deployment"
      else
        TASK_NOTIFY_FAIL_REASON=""
        warn "$ident: no channels configured on this deployment — gate filed UNNOTIFIED. Answer it on the dashboard, or: 5dive task answer ${ident}"
        _task_gate_delivery_log error "$numid" "" "" "no channel configured on this deployment; gate filed unnotified (dashboard-answerable)"
      fi
      return 3
    fi
  fi

  # The /task_<n> deep link and tna:<n>:… callback both carry a BARE NUMBER that
  # the plugin re-resolves via `5dive task show/answer <n>` — and a bare number
  # resolves by the GLOBAL ROW ID, not the per-project issue number. Derive it
  # from the row id, never from the ident: `${ident#DIVE-}` yields the issue
  # number, which diverges from the row id once a non-default project consumes
  # global ids (DIVE-484/DIVE-561), and for a non-DIVE prefix wouldn't strip at
  # all — either way the tap would resolve the WRONG row (DIVE-561).
  # One message. Blank lines separate the header / ask / options so a long ask
  # doesn't render as an unreadable wall on mobile. No footer: tap buttons cover
  # decision/approval, and button-less gates (secret/manual) still surface on
  # the dashboard "Needs you" card — a redirect line is just noise in chat.
  # Options are listed one per line (numbered to match the tap buttons) so long
  # labels stay readable even when Telegram crops the button text.
  # DIVE-148: lead with the agent's recommendation (✅ Recommended: <X>) before
  # the ask, so the human sees the advised choice first instead of hunting for
  # it. Applies to decision + approval gates; NULL/empty recommend = no line.
  # DIVE-2354: a ratification must not arrive looking like a prior approval — the
  # chat message IS the record the human answers from. Read from the ROW, not from a
  # parameter (DIVE-2090, same reason the secret branch below does): the batch
  # re-send calls this with whatever it happens to be holding.
  local _gmode
  _gmode=$(db "SELECT COALESCE(gate_mode,'') FROM tasks WHERE id=${numid};" 2>/dev/null || echo "")
  local text="🙋 [${ident}] needs you"
  if [[ "$_gmode" == "confirm-after-send" ]]; then
    text="↩︎ [${ident}] needs you to CONFIRM AN ACTION ALREADY TAKEN"
    text+=$'\n'"This is a RATIFICATION, not a prior approval — the action has already happened. Confirming records that you signed it off after the fact; denying records that you did not."
  fi
  # DIVE-1927: when the ask was escalated off an unpaired filer, NAME the filer.
  # The recipient's bot is not the asker's bot, so without this the alert reads as
  # the manager's own gate and there is no way to tell whose ask it is.
  [[ -n "${TASK_NOTIFY_ESCALATED_FROM:-}" ]] \
    && text+=$'\n'"↑ filed by ${TASK_NOTIFY_ESCALATED_FROM} (no channel of its own) — escalated to you"
  [[ -n "$recommend" ]] && text+=$'\n\n'"✅ Recommended: ${recommend}"
  # OSS-11 (DIVE-976): cite the precedent that sourced the recommendation so the
  # human sees WHY this choice is advised and can catch a wrong recall.
  [[ -n "$precedent_cite" ]] && text+=$'\n'"↩︎ ${precedent_cite}"
  # DIVE-390: append a bare, tappable /task_<id> link inline at the end of the
  # description sentence, before the options (Mark 2026-06-15). Telegram
  # auto-linkifies bare /commands, so tapping it fires the plugin's
  # ^/task_(\d+)$ handler -> `5dive task show <id>` (the full detail card). No
  # "details" label, numeric id only. A plain-text host shows an inert link.
  text+=$'\n\n'"${ask} /task_${numid}"
  if [[ "$need_type" == "decision" && -n "$options" ]]; then
    local opts_list
    # ⭐-mark the recommended option in the numbered list (numbering stays the
    # original option order so it still maps to need_options on the dashboard).
    opts_list=$(printf '%s' "$options" | jq -Rr --arg r "$recommend" '
      ($r | gsub("^\\s+|\\s+$"; "")) as $rr
      | [ split("|")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ]
      | to_entries | map("  \(.key + 1). \(.value)\(if .value == $rr and ($rr|length)>0 then " ⭐" else "" end)") | join("\n")' 2>/dev/null) || opts_list=""
    [[ -n "$opts_list" ]] && text+=$'\n\n'"Options:"$'\n'"${opts_list}"
  fi

  # DIVE-356: secret/manual gates used to carry NO instruction on how to clear
  # them — the core of Mark's "a needs-you that needs no obvious action is
  # confusing" complaint. Add a type-specific CTA telling the human exactly what
  # to do + tap (the matching ✅ button is emitted below for plugin types).
  # DIVE-894: every CTA also carries the on-box CLI line. Boxes with no
  # dashboard (CLI-only self-hosted — lodar hit this live on DIVE-790) had no
  # recovery path when a tap fails; the answer command works on EVERY box, run
  # as a human login (claude/root — the human path clears approval/secret gates).
  case "$need_type" in
    secret)
      # DIVE-931: when the gate names a drop target (secret_key + connector), mint
      # a burnable single-use link so the human drops the credential straight onto
      # the box — the VALUE never transits chat, only the link does. Falls back to
      # the on-box `secret write` (tokenless boxes) or the legacy out-of-band text
      # (self-hosted / api unreachable). The box-side write auto-clears this gate.
      local _drop=""
      if [[ -n "$secret_key" && -n "$connector" ]]; then
        _drop=$(_task_mint_drop_link "$ident" "$secret_key" "$connector")
      fi
      # DIVE-2411: the CTA text is a FUNCTION (_task_secret_gate_cta) rather than
      # four inline branches, so the prose can be graded. The remedy half of a fix
      # normally ships with the zero coverage that let the bug in — and here the
      # prose IS half the fix: on a gate with no delivery path the old copy said
      # "put the key where I expect it, then tap ✅ Provided", which is an
      # instruction to do the impossible followed by the button that files the
      # false record. See tests/secret_gate_delivery_path_unit.sh arms T8/T8b.
      text+=$'\n\n'"$(_task_secret_gate_cta "$ident" "$numid" "$secret_key" "$connector" "$_drop")"
      ;;
    manual) text+=$'\n\n'"✋ Tap ✅ Done below once it is handled, which closes this out. Or on the box: sudo 5dive task answer ${ident} --value=done" ;;
    # DIVE-1243: an `access` gate normally clears via the org lead; it only reaches
    # a human when it's genuinely human-territory (money/secrets/destructive) or no
    # lead was available. No tap button (the plugin `tna:` handler has no access
    # resolution — see the DIVE-118 no-dead-taps allowlist below); give the on-box
    # CLI line instead.
    access) text+=$'\n\n'"🔓 This is a grant request that reached you directly (human-territory, or no lead available). Clear it on the box: sudo 5dive task answer ${ident} --value=\"granted\" (or denied)" ;;
  esac

  # DIVE-117/118 tap-to-answer buttons. GATED to the plugin types whose `tna:`
  # callback_query handler exists AND splits options byte-identically to this
  # emit: claude, codex, grok, antigravity (DIVE-118 — parity verified against
  # the actual handlers). opencode has no `tna:` handler yet, so it stays
  # excluded to avoid dead taps; add it here when its handler lands. Explicit
  # allowlist (not != "") so a future new plugin type never auto-emits dead
  # taps. Only finite-option gates get
  # buttons: decision-with-options (index into need_options) and approval
  # (approved/denied). callback_data is `tna:<numericId>:<idx|approved|denied>`
  # — numeric id + index keeps it under Telegram's 64-byte cap; the value is
  # re-resolved from the DB on tap, never trusted from the payload.
  # The option-split rule here MUST be byte-identical to the plugin's `tna:`
  # handler (split '|', trim, drop empties) or a tapped index resolves the wrong
  # option. Filtering empties also avoids an empty-text button (Telegram rejects
  # it, which would 400 the whole message — see the text-fallback in
  # _mirror_post). If nothing survives the filter, emit no keyboard (plain text).
  # DIVE-1490: the initial alert and every re-nag share this exact renderer, so
  # option indexing, recommendation ordering, nonce handling, and the plugin
  # allowlist cannot drift between first delivery and subsequent reminders.
  local reply_markup
  reply_markup=$(_task_gate_reply_markup "$numid" "$need_type" "$options" "$recommend" "$human_nonce" "$TASK_CH_TYPE")

  # DIVE-2818: the reply-to-clear prompt, on HIGH-STAKES gates only.
  #
  # ORDER MATTERS AND IS WHY THIS MOVED BELOW THE MARKUP (DIVE-2824 iteration 3,
  # the tap-primary re-scope): the prompt's copy now speaks about the button and
  # is withheld where there is none, so it takes the markup this call ACTUALLY
  # produced instead of re-deriving the predicate and drifting from it. The two
  # statements are independent — neither reads the other's state — so this is a
  # reorder, not a behaviour change, and the emitted text is assembled after both.
  #
  # NARROWER THAN THE TAP ALLOWLIST, and the narrowing is measured rather than
  # cautious. The DIVE-118 rule is that an affordance must not be offered where no
  # handler answers it, and a dead PROMPT is worse than a dead button because the
  # human has to type before finding out. The tap list is
  # claude|codex|grok|antigravity because all four ship a `tna:` callback handler
  # — but the inbound-message handler this prompt depends on
  # (`plugins/telegram/gatereply.ts`, DIVE-2818) exists on the CLAUDE plugin only.
  #
  # The runtimes do NOT share a server: `plugins/telegram` is hand-maintained at
  # ~5.5k lines while `generator/generate.ts` builds agy/qwen from a DIFFERENT base
  # (`telegram-grok`, ~2.8k lines), and codex/pi/opencode are separate again. So
  # "add it to the plugin" is one job per runtime, not one job. Widen this regex in
  # the same change that lands each fork's handler, never before.
  if [[ "$TASK_CH_TYPE" == "claude" ]] && _task_gate_high_stakes "$numid"; then
    local _reply_cta; _reply_cta=$(_task_gate_reply_cta "$ident" "$need_type" "$options" "$recommend" "$reply_markup")
    [[ -n "$_reply_cta" ]] && text+=$'\n\n'"$_reply_cta"
  fi

  # DIVE-894: no tap buttons landed (non-tna channel type, or no valid options)
  # — a decision/approval gate would otherwise render with no way to act on a
  # dashboard-less box. Append the copy-pasteable on-box answer line.
  if [[ -z "$reply_markup" ]]; then
    case "$need_type" in
      decision) text+=$'\n\n'"Answer on the box: sudo 5dive task answer ${ident} --value=\"<option>\"" ;;
      approval) text+=$'\n\n'"Answer on the box: sudo 5dive task answer ${ident} --value=approved (or denied)" ;;
    esac
  fi

  _task_send_gate_owner "$text" "$reply_markup" "$numid"
  return 0
}

