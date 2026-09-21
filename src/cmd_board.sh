#!/usr/bin/env bash
# `5dive board` — THE READ CONTRACT. DIVE-4779 step 1.
#
# WHAT THIS IS AND WHY IT IS NOT IN cmd_ui.sh. The UI is leaving core to become a
# standalone plugin (`5dive-ai/5dive-ui`), so that an outside developer can fork,
# run and send a PR to the control plane WITHOUT cloning 121k lines of core. The
# blocker quinn named on DIVE-4618 is that the ported plugin does not read core
# through a seam at all: it opens core's private sqlite store and issues five
# queries naming `tasks`, `agents_org`, `event_triggers`, `event_deliveries` and
# roughly thirty columns, two of them derived expressions. That coupling is a
# STRING, so nothing in core can see it break — not a compiler, not `declare -F`,
# not a test in either repo.
#
# THE SEAM, stated once: CORE OWNS THE DOCUMENT, THE PLUGIN OWNS THE PRESENTATION.
# `board` emits one versioned JSON document describing this host's board; the
# plugin renders it. The board is a fact about core's own data model, so core is
# the only thing that can say what is on it. Layout, routes, styling, interaction
# and every other contributor-facing surface are 100% plugin-side.
#
# WHY NOT A PUBLISHED READ-ONLY VIEW, the alternative considered and refused: a
# view renames the coupling instead of removing it. The plugin would still open
# `tasks.db` directly — still needing the path, the sqlite3 binary, read
# permission on a 640 root:claude file and the box'"'"'s migration state — and a view
# arrives by MIGRATION, which is exactly what an installed box may not have run.
# A plugin on a box whose core predates the views discovers that by returning
# `no such table` into a browser at request time, because there is no way to ASK
# a view which contract it serves without already being able to read the store.
# That is DIVE-2512'"'"'s class of failure, shipped to every box at once. Full
# reasoning, and the third option (a bare schema-version floor over the plugin'"'"'s
# own SQL, rejected because it detects drift instead of removing it):
# docs/board-contract.md.
#
# NEGOTIATION IS CHEAP, TOTAL, AND HAPPENS BEFORE THE BROWSER. `board
# --contract-version` prints the integer alone and nothing else, so a plugin
# checks compatibility with ONE exec, and a box too old to carry this verb fails
# that exec instead of failing a request. That is the property the view option
# cannot have at any price.
#
# THE VERSION IS BUMPED ON A BREAK, NEVER ON A GROWTH. Adding a field is additive
# and does not move it; REMOVING a field, renaming one, or changing its type does.
# A plugin therefore pins the versions it understands and refuses an unknown one
# by name. Every change to the document'"'"'s shape owes an entry in
# docs/board-contract.md — tests/board_contract_unit.sh reds if the constant here
# and the number in that document disagree.
FIVEDIVE_BOARD_CONTRACT_NAME="5dive.board"
FIVEDIVE_BOARD_CONTRACT_VERSION=1

# ---------------------------------------------------------------------------
_board_state_json() {
  # A box with no task store yet is a REAL state, not an error: `sudo 5dive task
  # init` is root-only, and refusing here would mean a fresh install cannot open
  # the UI at all. So it serves the views with a named empty board rather
  # than an unnamed one — `store: "absent"` is the difference between "nothing is
  # queued" and "there is nowhere to queue anything", which an empty array alone
  # cannot say.
  if [[ ! -d "$TASKS_DIR" ]]; then
    jq -n --arg host "$(hostname 2>/dev/null || echo localhost)" \
          --arg now "$(date -u '+%Y-%m-%d %H:%M:%SZ')" \
      --argjson cv "$FIVEDIVE_BOARD_CONTRACT_VERSION" --arg cn "$FIVEDIVE_BOARD_CONTRACT_NAME" \
      '{ok: true, data: {contract: {name: $cn, version: $cv},
        scope: "single-host", store: "absent", host: $host, generated_at: $now,
        org: [], queue: [], gates: [], flows: [], triggers: [], deliveries: [],
        stats: {agents: 0, open: 0, gates: 0, delegated: 0, agent_to_agent: 0,
                human_touch: 0, awaiting_verify: 0, in_review: 0,
                triggers: 0, trigger_deliveries: 0}}}'
    return 0
  fi
  tasks_db_init
  local dir; dir="$(mktemp -d "${TMPDIR:-/tmp}/5dive-ui-data.XXXXXX")" || fail "$E_GENERIC" "could not create a temp dir"

  dbfmt -json "SELECT name, reports_to, role, title FROM agents_org ORDER BY COALESCE(reports_to,''), name;" > "$dir/org.json"
  [[ -s "$dir/org.json" ]] || printf '[]' > "$dir/org.json"

  dbfmt -json "SELECT ident, title, status, priority, assignee, created_by, verifier, maker_agent, project_key, created_at,
           CASE WHEN maker_agent IS NOT NULL AND assignee=verifier AND status NOT IN ('done','cancelled')
                THEN CASE WHEN handoff_ack_at IS NOT NULL THEN 'reviewing' ELSE 'delivered' END
                ELSE NULL END AS handoff_state,
           CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL AND status NOT IN ('done','cancelled') THEN 1 ELSE 0 END AS gate_live
         FROM tasks
         WHERE status NOT IN ('done','cancelled') AND COALESCE(kind,'') <> 'recurring'
         ORDER BY CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, created_at;" > "$dir/queue.json"
  [[ -s "$dir/queue.json" ]] || printf '[]' > "$dir/queue.json"

  dbfmt -json "SELECT ident, title, status, priority, assignee, created_by, need_type, tier, ask, recommend, need_options, created_at
         FROM tasks
         WHERE need_type IS NOT NULL AND need_answered_at IS NULL AND status NOT IN ('done','cancelled')
         ORDER BY COALESCE(tier,1) DESC, created_at;" > "$dir/gates.json"
  [[ -s "$dir/gates.json" ]] || printf '[]' > "$dir/gates.json"

  dbfmt -json "SELECT g.id,g.name,g.source,g.event_pattern AS event,g.source_scope AS repo,
           g.filter_json AS filters,g.target,g.enabled,g.max_pending,g.on_overflow,g.max_payload_bytes,
           COUNT(d.id) AS deliveries,
           SUM(CASE WHEN d.outcome='accepted' THEN 1 ELSE 0 END) AS accepted,
           SUM(CASE WHEN d.outcome IN ('failed','invalid_signature') THEN 1 ELSE 0 END) AS failed,
           MAX(d.received_at) AS last_delivery_at
         FROM event_triggers g LEFT JOIN event_deliveries d ON d.trigger_id=g.id
         GROUP BY g.id ORDER BY g.name;" > "$dir/triggers.json"
  [[ -s "$dir/triggers.json" ]] || printf '[]' > "$dir/triggers.json"

  dbfmt -json "SELECT d.id,g.name AS trigger,g.source,d.event_type,d.received_at,d.signature_status,
           d.outcome,t.ident AS task,d.error,d.replay_count
         FROM event_deliveries d JOIN event_triggers g ON g.id=d.trigger_id
         LEFT JOIN tasks t ON t.id=d.task_id ORDER BY d.id DESC LIMIT 100;" > "$dir/deliveries.json"
  [[ -s "$dir/deliveries.json" ]] || printf '[]' > "$dir/deliveries.json"

  # flows: who handed work to whom, on THIS board, right now.
  #
  # This is the view the org layer exists to make legible, so it is derived from
  # the rows themselves rather than asserted in copy. Two edge kinds:
  #   delegation  created_by -> assignee on an open row
  #   verify      assignee   -> verifier on a maker->verifier row
  # An endpoint that is not a name in agents_org is a human (or a channel
  # principal such as `telegram`/`council`), and any edge touching one is marked
  # human:true. "No human in the path" is then a COUNT off the board, not a claim.
  local out rc=0
  out=$(jq -n \
    --slurpfile org "$dir/org.json" \
    --slurpfile queue "$dir/queue.json" \
    --slurpfile gates "$dir/gates.json" \
    --slurpfile triggers "$dir/triggers.json" \
    --slurpfile deliveries "$dir/deliveries.json" \
    --arg host "$(hostname 2>/dev/null || echo localhost)" \
    --arg now "$(date -u '+%Y-%m-%d %H:%M:%SZ')" \
    --argjson cv "$FIVEDIVE_BOARD_CONTRACT_VERSION" --arg cn "$FIVEDIVE_BOARD_CONTRACT_NAME" '
    ($org[0] // []) as $org
    | ($queue[0] // []) as $queue
    | ($gates[0] // []) as $gates
    | ($triggers[0] // []) as $triggers
    | ($deliveries[0] // []) as $deliveries
    | ([$org[].name]) as $agents
    | ($agents | map({(.): true}) | add // {}) as $isAgent
    | ([ $queue[]
         | select(.created_by != null and .assignee != null and .created_by != .assignee)
         | {from: .created_by, to: .assignee, ident: .ident, title: .title, kind: "delegation",
            human: (($isAgent[.created_by] // false) == false or ($isAgent[.assignee] // false) == false)} ]
       + [ $queue[]
         | select(.verifier != null)
         | {from: (.maker_agent // .assignee), to: .verifier, ident: .ident, title: .title,
            kind: "verify", state: (.handoff_state // "assigned"),
            human: ((($isAgent[(.maker_agent // .assignee)] // false) == false) or ($isAgent[.verifier] // false) == false)} ]) as $flows
    | {ok: true, data: {
        contract: {name: $cn, version: $cv},
        scope: "single-host",
        store: "ready",
        host: $host,
        generated_at: $now,
        org: $org,
        queue: $queue,
        gates: $gates,
        triggers: $triggers,
        deliveries: $deliveries,
        flows: $flows,
        stats: {
          agents: ($agents | length),
          open: ($queue | length),
          gates: ($gates | length),
          delegated: ([$flows[] | select(.kind == "delegation")] | length),
          agent_to_agent: ([$flows[] | select(.human == false)] | length),
          human_touch: ([$flows[] | select(.human)] | length),
          awaiting_verify: ([$queue[] | select(.handoff_state == "delivered")] | length),
          in_review: ([$queue[] | select(.handoff_state == "reviewing")] | length),
          triggers: ($triggers | length),
          trigger_deliveries: ($deliveries | length)
        }
      }}') || rc=$?
  rm -rf "$dir"
  (( rc == 0 )) || fail "$E_GENERIC" "could not assemble the view data (jq exit $rc)"
  printf '%s\n' "$out"
}


cmd_board() {
  local a
  for a in "$@"; do
    case "$a" in
      # ONE EXEC, ONE INTEGER, NO STORE READ. Deliberately answered before
      # anything touches the task store: a consumer negotiating compatibility
      # must be able to do it on a box whose store is absent, unreadable, or
      # mid-migration — those are the boxes where getting the answer wrong is
      # most expensive. It prints the bare number and no JSON envelope so a
      # shell consumer needs no jq to read it.
      --contract-version) printf '%s\n' "$FIVEDIVE_BOARD_CONTRACT_VERSION"; return 0 ;;
      --contract-name)    printf '%s\n' "$FIVEDIVE_BOARD_CONTRACT_NAME"; return 0 ;;
      # `--json` is accepted and is a NO-OP: this verb has exactly one output
      # shape and it is JSON. Accepted anyway because every other read verb on
      # this CLI takes the flag, and a consumer that passes it out of habit must
      # not get a usage error on its negotiation path.
      --json) : ;;
      -h|--help)
        printf 'usage: 5dive board [--json] | --contract-version | --contract-name\n\n  Emit this host'"'"'s board as ONE versioned JSON document: the read contract a\n  UI or other consumer reads instead of opening core'"'"'s private sqlite store\n  (DIVE-4779). Keys: contract, scope, store, host, generated_at, org, queue,\n  gates, flows, triggers, deliveries, stats. Read-only, no root, no lock.\n\n  --contract-version  print the contract version integer and exit. Negotiate\n                      with this: it reads no store, so it answers on a box\n                      whose board does not exist yet. A box too old to carry\n                      this verb fails the exec, which is the same answer.\n\n  The version moves on a BREAKING change only (a field removed, renamed or\n  retyped); new fields are additive and do not move it. See\n  docs/board-contract.md.\n'
        return 0 ;;
      --*) fail "$E_VALIDATION" "board: unknown flag '$a' — usage: 5dive board [--json] | --contract-version | --contract-name" ;;
      *) fail "$E_VALIDATION" "board takes no positional arguments (got '$a') — usage: 5dive board [--json] | --contract-version" ;;
    esac
  done
  _board_state_json
}
