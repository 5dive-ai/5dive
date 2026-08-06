#!/usr/bin/env bash
# `5dive ui` — the free single-host web UI (DIVE-2655): three read-only views
# (org chart, queue, gates) served by the CLI itself.
#
# WHY THIS IS IN THE OSS BUNDLE AT ALL. Withholding a screen only creates upgrade
# pressure while the alternative to paying is NOTHING, and since 2026-07-29 it is
# not (yc-software/qm is MIT and ships a full web UI). What people pay us for is
# the box: provisioning, capacity, updates, uptime — and multi-box. A self-hoster
# with a dashboard still has to run their own infra.
#
# THE LINE THIS COMMAND MUST NOT CROSS. Three views, ONE host. Everything here
# reads the LOCAL task store and the LOCAL org chart and nothing else. There is
# deliberately no endpoint that aggregates across boxes, no fleet roll-up and no
# hosted-council surface: that is the paid tier. If you find yourself adding a
# `--fleet` flag or a second host to a query here, you are in the wrong file.
#
# READ-MOSTLY BY CONSTRUCTION, not by convention. The HTTP surface answers GET
# and HEAD on exactly three paths and returns 405 for every other method, so no
# amount of client-side code can make this write. Anything that mutates state
# already has a CLI verb; the UI's job is to make the org layer VISIBLE.
#
# NO ACCOUNTS, SO NO ROUTABLE BIND. There is no sign-in and there will not be
# one, which makes the loopback bind the only thing standing between an
# unauthenticated view of the board and the network. `--host` therefore accepts
# loopback addresses only; binding elsewhere needs FIVE_UI_ALLOW_REMOTE=1 set
# deliberately, and says so once, loudly, at startup.
#
# WHY PYTHON3 HOLDS THE SOCKET. bash cannot listen on one. python3 (stdlib only,
# no pip, no venv) is on every box the CLI provisions and on every distro the
# installer supports; the alternative — a serial `nc -l` loop — drops requests
# the moment a browser opens its second connection. The server script is
# generated from this file at runtime into a private temp dir, so the shipped
# artifact is still exactly one file.

# Default port: 8735 = "5DIV" on a phone keypad, above the privileged range and
# clear of the usual dev-server squatters (3000/5173/8000/8080).
readonly FIVE_UI_DEFAULT_PORT=8735

_ui_usage() {
  cat <<'USAGE'
5dive ui: the local web UI (org chart, queue, gates). One host, read-only, no sign-in.

  5dive ui                        # serve on http://127.0.0.1:8735 (Ctrl-C to stop)
  5dive ui --port=9000            # pick the port
  5dive ui --data                 # print the JSON the views render (no server)
  5dive ui --html                 # print the page itself (no server)
  5dive ui --once                 # serve exactly one request, then exit (tests/probes)

  --host=<addr>   loopback only unless FIVE_UI_ALLOW_REMOTE=1 (there is no sign-in)

Paid tier, deliberately absent here: anything fleet-wide (more than one box),
the marketplace, hosted council.
USAGE
}

cmd_ui() {
  local port="${FIVE_UI_DEFAULT_PORT}" host="127.0.0.1" mode="serve" once=0
  while (( $# )); do
    case "$1" in
      --port=*)  port="${1#*=}" ;;
      --host=*)  host="${1#*=}" ;;
      --data)    mode="data" ;;
      --html)    mode="html" ;;
      --once)    once=1 ;;
      -h|--help) _ui_usage; return 0 ;;
      *)         fail "$E_USAGE" "unknown flag: $1 (see '5dive ui --help')" ;;
    esac
    shift
  done

  case "$mode" in
    data) _ui_state_json; return 0 ;;
    html) _ui_html;       return 0 ;;
  esac

  [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) \
    || fail "$E_VALIDATION" "--port must be 1-65535, got '$port'"

  # The bind check. Loopback is any 127.x, ::1, or the name that resolves there.
  if [[ ! "$host" =~ ^(127(\.[0-9]{1,3}){3}|::1|localhost)$ ]]; then
    [[ "${FIVE_UI_ALLOW_REMOTE:-0}" == "1" ]] \
      || fail "$E_VALIDATION" "'$host' is not loopback and this UI has no sign-in. Set FIVE_UI_ALLOW_REMOTE=1 if you really mean to expose the board."
    warn "binding $host with NO authentication. Anyone who can reach this port reads your board and your gates."
  fi

  command -v python3 >/dev/null 2>&1 \
    || fail "$E_NOT_INSTALLED" "5dive ui needs python3 (stdlib only) to hold the socket. Install python3, or use '5dive ui --data' / the CLI verbs."

  local self; self="$(five_self_bundle || true)"
  [[ -n "$self" ]] || self="${FIVE_UI_BIN:-}"
  [[ -n "$self" ]] || fail "$E_GENERIC" "could not identify my own bundle, so the page would have nothing to poll"

  # No RETURN/EXIT trap for the cleanup: main.sh owns the EXIT trap, and a RETURN
  # trap set inside a function stays registered after that function returns, so
  # it re-fires in the NEXT function with its own `local` long gone (`unbound
  # variable` under set -u). Explicit removal on every exit path instead.
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/5dive-ui.XXXXXX")" || fail "$E_GENERIC" "could not create a temp dir for the server"
  chmod 700 "$tmp"
  trap 'rm -rf "$tmp"' INT TERM
  _ui_html > "$tmp/index.html"
  _ui_server_py > "$tmp/server.py"

  step "5dive ui on http://${host}:${port} (org chart, queue, gates: read-only, this host only)"
  local args=("$tmp/server.py" "$host" "$port" "$tmp/index.html" "$self") rc=0
  (( once )) && args+=("--once")
  # The server runs in the BACKGROUND and we wait on it, so a signal reaches it.
  # Foregrounded, bash defers a trap until the current command finishes, so
  # `kill <pid of 5dive ui>` would set a trap pending behind a server that never
  # returns and the caller would hang. Ctrl-C happened to work (SIGINT goes to
  # the whole process group); a plain TERM did not.
  python3 "${args[@]}" &
  local py=$!
  trap 'kill "$py" 2>/dev/null; rm -rf "$tmp"' INT TERM
  wait "$py" || rc=$?
  trap - INT TERM
  # `|| true` is load-bearing, not style. `wait` returned because the child is
  # already reaped, so this belt-and-braces kill can only ever get ESRCH — and
  # under `set -e` a bare failing command ends the function HERE: it published 1
  # as the exit code of a fully successful run, discarded the rc computed above,
  # and skipped the `rm` below, leaking a mode-700 temp dir per invocation. Note
  # which path that is: the trap two lines up cleans up correctly, so the leak
  # happened only on the runs that WORKED (DIVE-2813, and see
  # community/wiki/set-e-deletes-exactly-the-cleanup-a-trap-would-have-kept.md).
  kill "$py" 2>/dev/null || true
  rm -rf "$tmp"
  return "$rc"
}

# ---------------------------------------------------------------------------
# The data. One query set, three views, all of it local.
#
# Every field here already exists on the board — the UI derives nothing the CLI
# does not already print, so a view can never tell a different story than
# `task ls` / `task inbox` / `org tree` (the DIVE-2055 rule).
#
# handoff_state is the SAME expression `task ls --json` uses (cmd_task.sh): a
# maker→verifier row whose assignee has been swapped to the verifier reads
# 'delivered' until the verifier ACKs, then 'reviewing'. gate_live is likewise
# the canonical inbox predicate, never raw `need_type IS NOT NULL`.
# ---------------------------------------------------------------------------
_ui_state_json() {
  # A box with no task store yet is a REAL state, not an error: `sudo 5dive task
  # init` is root-only, and refusing here would mean a fresh install cannot open
  # the UI at all. So it serves the three views with a named empty board rather
  # than an unnamed one — `store: "absent"` is the difference between "nothing is
  # queued" and "there is nowhere to queue anything", which an empty array alone
  # cannot say.
  if [[ ! -d "$TASKS_DIR" ]]; then
    jq -n --arg host "$(hostname 2>/dev/null || echo localhost)" \
          --arg now "$(date -u '+%Y-%m-%d %H:%M:%SZ')" \
      '{ok: true, data: {scope: "single-host", store: "absent", host: $host, generated_at: $now,
        org: [], queue: [], gates: [], flows: [],
        stats: {agents: 0, open: 0, gates: 0, delegated: 0, agent_to_agent: 0,
                human_touch: 0, awaiting_verify: 0, in_review: 0}}}'
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
    --arg host "$(hostname 2>/dev/null || echo localhost)" \
    --arg now "$(date -u '+%Y-%m-%d %H:%M:%SZ')" '
    ($org[0] // []) as $org
    | ($queue[0] // []) as $queue
    | ($gates[0] // []) as $gates
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
        scope: "single-host",
        store: "ready",
        host: $host,
        generated_at: $now,
        org: $org,
        queue: $queue,
        gates: $gates,
        flows: $flows,
        stats: {
          agents: ($agents | length),
          open: ($queue | length),
          gates: ($gates | length),
          delegated: ([$flows[] | select(.kind == "delegation")] | length),
          agent_to_agent: ([$flows[] | select(.human == false)] | length),
          human_touch: ([$flows[] | select(.human)] | length),
          awaiting_verify: ([$queue[] | select(.handoff_state == "delivered")] | length),
          in_review: ([$queue[] | select(.handoff_state == "reviewing")] | length)
        }
      }}') || rc=$?
  rm -rf "$dir"
  (( rc == 0 )) || fail "$E_GENERIC" "could not assemble the view data (jq exit $rc)"
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# The page. One file, no build step, no CDN: the bundle is the only artifact, so
# a view cannot depend on anything the box may not be able to fetch.
# ---------------------------------------------------------------------------
_ui_html() {
  cat <<'HTML'
<!doctype html>
<html lang="en" data-view="org">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>5dive · this host</title>
<style>
  :root {
    --bg: #0b0d10; --panel: #14181d; --panel-2: #1b2027; --line: #262d36;
    --ink: #e8edf3; --dim: #93a1b0; --faint: #6b7887;
    --accent: #5ad1a0; --accent-dim: #1f4d3d;
    --warn: #f2b544; --hot: #ff6b6b; --cool: #6aa9ff;
    --radius: 10px;
    font-synthesis-weight: none;
  }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #f6f8fa; --panel: #ffffff; --panel-2: #f0f3f6; --line: #d8dee6;
      --ink: #14181d; --dim: #56606c; --faint: #7d8894;
      --accent: #0f8f63; --accent-dim: #cdeadd;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font: 15px/1.5 ui-sans-serif, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  }
  code, .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  header { border-bottom: 1px solid var(--line); background: var(--panel); }
  .bar { max-width: 1120px; margin: 0 auto; padding: 14px 20px; display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap; }
  .brand { font-weight: 700; letter-spacing: .01em; }
  .brand span { color: var(--accent); }
  .host { color: var(--dim); font-size: 13px; }
  .host b { color: var(--ink); font-weight: 600; }
  .spacer { flex: 1 1 auto; }
  .stamp { color: var(--faint); font-size: 12px; }
  nav { max-width: 1120px; margin: 0 auto; padding: 0 20px 12px; display: flex; gap: 8px; }
  nav button {
    font: inherit; font-size: 14px; color: var(--dim); background: transparent;
    border: 1px solid transparent; border-radius: 999px; padding: 6px 14px; cursor: pointer;
  }
  nav button:hover { color: var(--ink); background: var(--panel-2); }
  nav button[aria-selected="true"] { color: var(--ink); background: var(--panel-2); border-color: var(--line); }
  nav button .n { color: var(--faint); font-size: 12px; margin-left: 6px; }
  main { max-width: 1120px; margin: 0 auto; padding: 22px 20px 64px; }
  h2 { font-size: 15px; margin: 0 0 4px; }
  .sub { color: var(--dim); font-size: 13px; margin: 0 0 16px; }
  .card { background: var(--panel); border: 1px solid var(--line); border-radius: var(--radius); }
  .lede { padding: 16px 18px; margin-bottom: 20px; }
  .lede .big { font-size: 22px; font-weight: 650; }
  .lede .big em { font-style: normal; color: var(--accent); }
  .lede p { margin: 6px 0 0; color: var(--dim); font-size: 13px; }
  .tree { list-style: none; margin: 0; padding: 0; }
  .tree ul { list-style: none; margin: 0; padding-left: 26px; position: relative; }
  .tree ul::before {
    content: ""; position: absolute; left: 10px; top: 0; bottom: 18px; border-left: 1px solid var(--line);
  }
  .tree li { position: relative; margin: 8px 0; }
  .tree ul > li::before {
    content: ""; position: absolute; left: -16px; top: 22px; width: 14px; border-top: 1px solid var(--line);
  }
  .node { display: flex; align-items: center; gap: 10px; padding: 10px 14px; }
  .node .who { min-width: 0; }
  .node .name { font-weight: 650; }
  .node .name .mono { color: var(--accent); }
  .node .role { color: var(--dim); font-size: 12.5px; overflow-wrap: anywhere; }
  .chips { margin-left: auto; display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
  .chip {
    font-size: 11.5px; padding: 2px 8px; border-radius: 999px; white-space: nowrap;
    border: 1px solid var(--line); color: var(--dim); background: var(--panel-2);
  }
  .chip.on { color: var(--accent); border-color: var(--accent-dim); }
  .chip.warn { color: var(--warn); border-color: var(--warn); }
  .chip.hot { color: var(--hot); border-color: var(--hot); }
  .flow { display: flex; align-items: center; gap: 10px; padding: 9px 14px; border-top: 1px solid var(--line); font-size: 13.5px; flex-wrap: nowrap; }
  .flow:first-child { border-top: 0; }
  .flow .arrow { color: var(--faint); white-space: nowrap; flex: 0 0 auto; }
  .flow .who { font-weight: 600; white-space: nowrap; flex: 0 0 auto; }
  .flow .what { color: var(--dim); flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .flow .ident { color: var(--cool); white-space: nowrap; flex: 0 0 auto; }
  .flow .tag { margin-left: auto; flex: 0 0 auto; }
  table { width: 100%; border-collapse: collapse; font-size: 13.5px; }
  th { text-align: left; font-weight: 600; color: var(--dim); font-size: 12px; text-transform: uppercase; letter-spacing: .04em; padding: 10px 12px; border-bottom: 1px solid var(--line); }
  td { padding: 10px 12px; border-bottom: 1px solid var(--line); vertical-align: top; }
  tr:last-child td { border-bottom: 0; }
  td.ident { white-space: nowrap; color: var(--cool); }
  td.who { white-space: nowrap; }
  .scroll { overflow-x: auto; }
  .gate { padding: 14px 16px; margin-bottom: 12px; }
  .gate .head { display: flex; gap: 10px; row-gap: 8px; align-items: center; flex-wrap: wrap; }
  .gate .head strong { flex: 1 1 240px; }
  .gate .head .chips { flex: 0 0 auto; }
  .gate .ask { margin: 8px 0 0; }
  .gate .rec { margin: 8px 0 0; color: var(--dim); font-size: 13px; }
  .gate .rec b { color: var(--accent); font-weight: 600; }
  .empty { padding: 28px 18px; text-align: center; color: var(--faint); }
  footer { max-width: 1120px; margin: 0 auto; padding: 0 20px 40px; color: var(--faint); font-size: 12px; }
  [hidden] { display: none !important; }
</style>
</head>
<body>
<header>
  <div class="bar">
    <div class="brand">5<span>dive</span></div>
    <div class="host">host <b id="host">…</b> · single host, read only</div>
    <div class="spacer"></div>
    <div class="stamp" id="stamp">loading…</div>
  </div>
  <nav>
    <button id="tab-org"   aria-selected="true"  data-view="org">Org chart<span class="n" id="n-org"></span></button>
    <button id="tab-queue" aria-selected="false" data-view="queue">Queue<span class="n" id="n-queue"></span></button>
    <button id="tab-gates" aria-selected="false" data-view="gates">Gates<span class="n" id="n-gates"></span></button>
  </nav>
</header>

<main>
  <div class="card lede" id="no-store" hidden>
    <div class="big">There is no task store on this host yet</div>
    <p>The three views are empty because nothing has been created, not because the board is clear. Run <code class="mono">sudo 5dive task init</code> (or create your first agent) and reload.</p>
  </div>
  <section id="view-org">
    <div class="card lede">
      <div class="big" id="org-head">…</div>
      <p id="org-sub"></p>
    </div>
    <h2>Who reports to whom</h2>
    <p class="sub">Every name here is an addressable actor. Work is assigned to one, and it can assign work to another.</p>
    <ul class="tree" id="tree"></ul>
    <h2 style="margin-top:26px">Work in flight, hop by hop</h2>
    <p class="sub">Each row is a live handoff on this board: who gave the work, who holds it, who grades it.</p>
    <div class="card" id="flows"></div>
  </section>

  <section id="view-queue" hidden>
    <h2>Open rows</h2>
    <p class="sub">Everything not done or cancelled, in the order the queue works it.</p>
    <div class="card scroll">
      <table>
        <thead><tr><th>Task</th><th>Title</th><th>Status</th><th>Assignee</th><th>Verifier</th><th>Handoff</th></tr></thead>
        <tbody id="queue-body"></tbody>
      </table>
    </div>
  </section>

  <section id="view-gates" hidden>
    <h2>Blocked on a human</h2>
    <p class="sub">These are the asks the fleet could not answer for itself. Everything else moved without one.</p>
    <div id="gates-body"></div>
  </section>
</main>

<footer>
  Served by the 5dive CLI on this host. Read only: answer a gate with <code class="mono">5dive task answer</code>, move a row with <code class="mono">5dive task</code>.
</footer>

<script>
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var state = null;

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function chip(text, cls) { return el("span", "chip" + (cls ? " " + cls : ""), text); }

  // ---- org chart -----------------------------------------------------------
  function perAgent() {
    var m = {};
    (state.org || []).forEach(function (a) {
      m[a.name] = { open: 0, gates: 0, delivered: 0, grading: 0 };
    });
    var get = function (n) { if (!m[n]) m[n] = { open: 0, gates: 0, delivered: 0, grading: 0 }; return m[n]; };
    (state.queue || []).forEach(function (t) {
      if (t.assignee) get(t.assignee).open++;
      if (t.gate_live) get(t.assignee || "?").gates++;
      if (t.handoff_state === "delivered" && t.verifier) get(t.verifier).delivered++;
      if (t.handoff_state === "reviewing" && t.verifier) get(t.verifier).grading++;
    });
    return m;
  }

  function renderTree() {
    var counts = perAgent();
    var nodes = state.org || [];
    var byParent = {};
    var known = {};
    nodes.forEach(function (n) { known[n.name] = true; });
    nodes.forEach(function (n) {
      var p = n.reports_to && known[n.reports_to] ? n.reports_to : "";
      (byParent[p] = byParent[p] || []).push(n);
    });

    function card(n) {
      var li = el("li");
      var box = el("div", "card node");
      var who = el("div", "who");
      var name = el("div", "name");
      name.appendChild(el("span", "mono", n.name));
      if (n.title) name.appendChild(el("span", null, "  " + n.title));
      who.appendChild(name);
      if (n.role) who.appendChild(el("div", "role", n.role));
      box.appendChild(who);
      var c = counts[n.name] || { open: 0, gates: 0, delivered: 0, grading: 0 };
      var chips = el("div", "chips");
      if (c.open) chips.appendChild(chip(c.open + " open"));
      if (c.delivered) chips.appendChild(chip(c.delivered + " to grade", "on"));
      if (c.grading) chips.appendChild(chip(c.grading + " grading", "on"));
      if (c.gates) chips.appendChild(chip(c.gates + " gated", "warn"));
      if (!chips.childNodes.length) chips.appendChild(chip("idle"));
      box.appendChild(chips);
      li.appendChild(box);
      var kids = byParent[n.name] || [];
      if (kids.length) {
        var ul = el("ul");
        kids.forEach(function (k) { ul.appendChild(card(k)); });
        li.appendChild(ul);
      }
      return li;
    }

    var root = $("tree");
    root.textContent = "";
    var tops = byParent[""] || [];
    if (!tops.length) {
      root.appendChild(el("li", "card empty", "No org chart on this host yet. Build one with 5dive org set."));
      return;
    }
    tops.forEach(function (t) { root.appendChild(card(t)); });
  }

  function renderFlows() {
    var box = $("flows");
    box.textContent = "";
    var flows = (state.flows || []).slice().sort(function (a, b) {
      return (a.human === b.human) ? 0 : (a.human ? 1 : -1);
    });
    if (!flows.length) {
      box.appendChild(el("div", "empty", "Nothing in flight. Every row on this board is closed or unassigned."));
      return;
    }
    flows.forEach(function (f) {
      var row = el("div", "flow");
      row.appendChild(el("span", "who mono", f.from || "?"));
      row.appendChild(el("span", "arrow", f.kind === "verify" ? "grades for" : "delegated to"));
      row.appendChild(el("span", "who mono", f.to || "?"));
      row.appendChild(el("span", "ident mono", f.ident || ""));
      row.appendChild(el("span", "what", f.title || ""));
      var tag = el("div", "tag");
      if (f.human) {
        tag.appendChild(chip("human in the path", "warn"));
      } else if (f.kind === "verify") {
        tag.appendChild(chip(f.state === "delivered" ? "delivered, waiting on the grader"
                          : f.state === "reviewing" ? "being graded" : "agent grades agent", "on"));
      } else {
        tag.appendChild(chip("agent to agent", "on"));
      }
      row.appendChild(tag);
      box.appendChild(row);
    });
  }

  function renderLede() {
    var s = state.stats || {};
    var a2a = s.agent_to_agent || 0, all = (s.agent_to_agent || 0) + (s.human_touch || 0);
    var head = $("org-head");
    head.textContent = "";
    head.appendChild(document.createTextNode(a2a + " of " + all + " live handoffs "));
    var em = el("em", null, "have no human in the path");
    head.appendChild(em);
    $("org-sub").textContent =
      (s.agents || 0) + " agents, " + (s.open || 0) + " open rows, " + (s.awaiting_verify || 0) +
      " waiting on another agent to grade them, " + (s.gates || 0) + " asks parked on a person.";
  }

  // ---- queue ---------------------------------------------------------------
  function renderQueue() {
    var body = $("queue-body");
    body.textContent = "";
    var rows = state.queue || [];
    if (!rows.length) {
      var tr = el("tr");
      var td = el("td", "empty");
      td.colSpan = 6;
      td.textContent = "Nothing open. The board is clear.";
      tr.appendChild(td);
      body.appendChild(tr);
      return;
    }
    rows.forEach(function (t) {
      var tr = el("tr");
      tr.appendChild(el("td", "ident mono", t.ident || ""));
      tr.appendChild(el("td", null, t.title || ""));
      var st = el("td");
      st.appendChild(chip(t.status || "", t.status === "blocked" ? "hot" : t.status === "in_progress" ? "on" : null));
      if (t.priority === "urgent" || t.priority === "high") st.appendChild(chip(t.priority, "warn"));
      tr.appendChild(st);
      tr.appendChild(el("td", "who mono", t.assignee || "-"));
      tr.appendChild(el("td", "who mono", t.verifier || "-"));
      var h = el("td", "who");
      if (t.handoff_state === "delivered") h.appendChild(chip("delivered, awaiting ACK", "on"));
      else if (t.handoff_state === "reviewing") h.appendChild(chip("being graded", "on"));
      else if (t.gate_live) h.appendChild(chip("gated", "warn"));
      else h.appendChild(el("span", "role", "-"));
      tr.appendChild(h);
      body.appendChild(tr);
    });
  }

  // ---- gates ---------------------------------------------------------------
  function renderGates() {
    var box = $("gates-body");
    box.textContent = "";
    var gates = state.gates || [];
    if (!gates.length) {
      box.appendChild(el("div", "card empty", "No open gates. Nothing on this board is waiting on a person."));
      return;
    }
    gates.forEach(function (g) {
      var c = el("div", "card gate");
      var head = el("div", "head");
      head.appendChild(el("span", "ident mono", g.ident || ""));
      head.appendChild(el("strong", null, g.title || ""));
      var chips = el("div", "chips");
      chips.appendChild(chip(g.need_type || "gate", g.need_type === "secret" ? "hot" : null));
      chips.appendChild(chip("tier " + (g.tier == null ? "1" : g.tier), (g.tier >= 2) ? "hot" : "warn"));
      if (g.created_by) chips.appendChild(chip("filed by " + g.created_by));
      head.appendChild(chips);
      c.appendChild(head);
      if (g.ask) c.appendChild(el("p", "ask", g.ask));
      if (g.recommend) {
        var rec = el("p", "rec");
        rec.appendChild(document.createTextNode("recommended answer: "));
        rec.appendChild(el("b", null, g.recommend));
        if (g.need_options) rec.appendChild(document.createTextNode("   (options: " + g.need_options + ")"));
        c.appendChild(rec);
      }
      box.appendChild(c);
    });
  }

  // ---- shell ---------------------------------------------------------------
  function show(view) {
    ["org", "queue", "gates"].forEach(function (v) {
      $("view-" + v).hidden = (v !== view);
      $("tab-" + v).setAttribute("aria-selected", String(v === view));
    });
    document.documentElement.setAttribute("data-view", view);
    if (location.hash.slice(1) !== view) history.replaceState(null, "", "#" + view);
  }

  function render() {
    $("host").textContent = state.host || "localhost";
    var banner = $("no-store");
    banner.hidden = (state.store !== "absent");
    $("stamp").textContent = "as of " + (state.generated_at || "");
    $("n-org").textContent = (state.stats && state.stats.agents) || 0;
    $("n-queue").textContent = (state.stats && state.stats.open) || 0;
    $("n-gates").textContent = (state.stats && state.stats.gates) || 0;
    renderLede(); renderTree(); renderFlows(); renderQueue(); renderGates();
  }

  function load() {
    fetch("/api/state", { cache: "no-store" })
      .then(function (r) { return r.json(); })
      .then(function (doc) {
        if (!doc || !doc.ok) throw new Error((doc && doc.error) || "bad response");
        state = doc.data; render();
      })
      .catch(function (e) {
        $("stamp").textContent = "could not read the board: " + e.message;
      });
  }

  ["org", "queue", "gates"].forEach(function (v) {
    $("tab-" + v).addEventListener("click", function () { show(v); });
  });
  show(["org", "queue", "gates"].indexOf(location.hash.slice(1)) >= 0 ? location.hash.slice(1) : "org");
  load();
  setInterval(load, 15000);
})();
</script>
</body>
</html>
HTML
}

# ---------------------------------------------------------------------------
# The socket holder. stdlib only, three paths, GET/HEAD only.
#
# /api/state re-invokes THIS bundle (`5dive ui --data`) rather than reading the
# sqlite file directly: one query set, one place it can drift, and the server
# inherits every store fence and permission the CLI already enforces.
# ---------------------------------------------------------------------------
_ui_server_py() {
  cat <<'PY'
import json
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer

HOST, PORT, PAGE, BUNDLE = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
ONCE = "--once" in sys.argv[5:]

with open(PAGE, "rb") as fh:
    PAGE_BYTES = fh.read()


class Handler(BaseHTTPRequestHandler):
    server_version = "5dive-ui"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):          # one line per request, on stderr
        sys.stderr.write("%s %s\n" % (self.command, self.path.split("?", 1)[0]))

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        # No sign-in, so the page must never be framed or leak a referrer.
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        if ONCE:
            # One request means one connection. Under HTTP/1.1 the handler loops
            # on a kept-alive socket, so without this the single-shot server
            # stays inside handle_request() until the client hangs up.
            self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _state(self):
        try:
            proc = subprocess.run(
                [BUNDLE, "ui", "--data"],
                capture_output=True, timeout=30,
            )
        except Exception as exc:                # noqa: BLE001 - reported, not raised
            return 500, json.dumps({"ok": False, "error": str(exc)}).encode()
        if proc.returncode != 0 or not proc.stdout.strip():
            err = proc.stderr.decode("utf-8", "replace").strip() or "no output"
            return 500, json.dumps({"ok": False, "error": err}).encode()
        return 200, proc.stdout

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            return self._send(200, PAGE_BYTES, "text/html; charset=utf-8")
        if path == "/api/state":
            code, body = self._state()
            return self._send(code, body, "application/json")
        if path == "/healthz":
            return self._send(200, b'{"ok":true}', "application/json")
        return self._send(404, json.dumps(
            {"ok": False, "error": "not found", "paths": ["/", "/api/state", "/healthz"]}
        ).encode(), "application/json")

    do_HEAD = do_GET

    # Read-only by construction: no write method exists to reach a handler.
    def _readonly(self):
        self._send(405, json.dumps({
            "ok": False,
            "error": "5dive ui is read-only; use the CLI to change anything",
        }).encode(), "application/json")

    do_POST = do_PUT = do_PATCH = do_DELETE = _readonly


if __name__ == "__main__":
    # --once is served WITHOUT threading, deliberately. ThreadingHTTPServer hands
    # each request to a worker and returns from handle_request() on DISPATCH, not
    # on completion — the main thread falls straight through to server_close() and
    # exits, and interpreter shutdown kills the worker mid-write. Its threads are
    # daemonic, and socketserver's join-on-close list only ever tracks NON-daemon
    # threads, so nothing waits for the body. The signature is mostly a TRUNCATED
    # 200 (status line and headers delivered, body cut), not a refused connection,
    # so an arm grading only the status code scores it a pass. Served in-thread,
    # handle_request() cannot return before the response is on the socket.
    # serve_forever() keeps threading: there a slow /api/state (it shells out to
    # the bundle) would otherwise block every other request. (DIVE-2813)
    srv = (HTTPServer if ONCE else ThreadingHTTPServer)((HOST, PORT), Handler)
    sys.stderr.write("listening on http://%s:%d\n" % (HOST, PORT))
    sys.stderr.flush()
    try:
        if ONCE:
            srv.handle_request()
        else:
            srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
PY
}
