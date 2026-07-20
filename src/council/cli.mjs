#!/usr/bin/env node
// CNCL-6 — `5dive council` CLI entrypoint. Thin arg-parser over the deliberation
// ENGINE (engine.mjs, written alongside this file into a temp dir by cmd_council.sh).
// It never seals or persists directly: it emits a JSON envelope on stdout and the
// bash layer does the root-only receipt seal (gate-proof) + registry file write.
//
// Contract (bash always passes --key=value form, so no positional/flag ambiguity):
//   convene "<question>" --seats=a,b,c --mode=quick|deliberate|adversarial
//           [--bench=<name>] [--registry=<path>] [--class=<decisionClass>]
//           [--threshold=<n>] [--threshold-rule=flat|majority|fraction]
//           [--veto-by=<who> --veto-reason=<why>] [--stamped-at=<iso>]
//   bench ls|show|add|rm  (persisted registry lives at --registry=<path>)
//
// COUNCIL_MOCK=1 swaps in a deterministic no-network modelCall (offline tests + VM smoke
// with no key). Otherwise the A-with-seam Anthropic adapter reads COUNCIL_API_KEY.
import * as E from './engine.mjs'
import fs from 'node:fs'
import { execFileSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'
import { randomBytes, createHash } from 'node:crypto'

const argv = process.argv.slice(2)
const sub = argv[0] || ''
const rest = argv.slice(1)
const positionals = rest.filter(a => !a.startsWith('--'))
const flag = (k, d) => {
  const hit = rest.find(a => a === `--${k}` || a.startsWith(`--${k}=`))
  if (hit == null) return d
  return hit.includes('=') ? hit.slice(hit.indexOf('=') + 1) : true
}
const die = (msg, code = 2) => { process.stderr.write(`council: ${msg}\n`); process.exit(code) }
// bash passes boolean flags as the STRINGS "0"/"1" — and JS `!"0"` is false, so never test a
// flag's truthiness for these. `--genesis-exists=0` MUST read as false (fail-closed correctness).
const flagBool = (k) => { const v = flag(k); return v === true || v === '1' || v === 'true' }
const out = (obj) => { process.stdout.write(JSON.stringify(obj) + '\n') }

// ---- persisted registry ----------------------------------------------------
// Built-ins are read-only defaults; the persisted file extends/overrides them and
// is the only thing `bench add|rm` mutate. Resolution is fail-closed on a miss.
const BUILTINS = { ...E.STANDING_COUNCILS, council: { ...E.DEFAULT_COUNCIL } }
function loadRegistry(p) {
  if (!p) return {}
  try { return JSON.parse(fs.readFileSync(p, 'utf-8')) } catch { return {} }
}
function saveRegistry(p, reg) {
  if (!p) die('bench mutation needs --registry=<path>')
  fs.writeFileSync(p, JSON.stringify(reg, null, 2) + '\n')
}
function resolveBench(name, reg) {
  // persisted wins over a same-named built-in (lets the council re-seat a standing bench).
  return E.resolveCouncil(name, { ...BUILTINS, ...reg })
}
function parseSeats(spec) {
  // "a,b,c" -> default lens; "a:the a lens|b:the b lens" -> explicit lenses.
  if (!spec) return []
  const parts = spec.includes('|') ? spec.split('|') : spec.split(',')
  return parts.map(s => s.trim()).filter(Boolean).map(s => {
    const i = s.indexOf(':')
    return i < 0 ? { id: s, lens: `${s} — council seat.` } : { id: s.slice(0, i).trim(), lens: s.slice(i + 1).trim() }
  })
}

// ---- model call (A-with-seam, or deterministic mock) -----------------------
function mockModelCall() {
  // Deterministic, network-free. Every seat approves with a canned take/vote so the
  // full convene path (takes -> votes -> chair -> tally -> veto -> receipt) exercises
  // offline. Shape matches whichever schema the engine forces.
  return async (prompt, schema) => {
    const req = new Set(schema.required || [])
    if (req.has('position')) return { seat: 'mock', position: 'proceed', keyRisk: 'none material' }
    if (req.has('vote')) return { seat: 'mock', vote: 'approve', rationale: 'mock: no blocker found.' }
    if (req.has('choice') && req.has('rationale')) return { seat: 'mock', choice: (String(flag('_opt', 'a')).split(',')[0] || 'a'), rationale: 'mock choice.' }
    if (req.has('confidence') && req.has('brief') && !req.has('recommendation') && !req.has('choice')) return { confidence: 0.9, dissent: 'none', brief: '' }
    return { recommendation: 'approve', tally: { approve: 1, reject: 0, escalate: 0 }, confidence: 0.9, dissent: 'none', escalated: false, brief: '' }
  }
}
function modelCallFor() {
  if (process.env.COUNCIL_MOCK) return mockModelCall()
  return E.makeAnthropicModelCall({})
}

// ---- CNCL-7 dispatch: convene -> real seated agents (default fleet path) ----
// Each seat votes via its OWN harness over the `5dive agent ask` rail — no shared model key.
// A per-seat timeout, a non-running agent, or a reply with no COUNCIL-VOTE line all resolve to
// an ABSTAIN (the engine records it; abstains still count toward the quorum denominator).
function dispatchSeatVote(opts) {
  const timeout = Number(opts.timeout) || 120
  const idle = Number(opts.idle) || 5
  const poll = Number(opts.poll) || 2
  const from = opts.from || 'council'
  const bin = process.env.COUNCIL_5DIVE_BIN || '5dive'
  return async (seat, ctx) => {
    const prompt = E.seatPrompt(seat, ctx)
    // CNCL-16: dispatch to the seat's REGISTRY agent (persona 'theo' -> 'marketing', etc.), not
    // its display id. Pre-flight (below) has already fail-closed on any unresolvable seat.
    const target = E.resolveSeatAgent(seat)
    let reply = ''
    try {
      const stdout = execFileSync(bin, ['agent', 'ask', target, prompt,
        '--json', `--from=${from}`, `--timeout=${timeout}`, `--idle-secs=${idle}`, `--poll-secs=${poll}`],
        { encoding: 'utf-8', timeout: (timeout + 30) * 1000, maxBuffer: 16 * 1024 * 1024 })
      const env = JSON.parse(stdout)
      reply = (env && env.data && env.data.reply) || ''
    } catch (e) {
      // ask timed out (E_TIMEOUT), the agent isn't running, or the exec failed -> ABSTAIN.
      return { vote: 'abstain', rationale: `no reply from ${seat.id} (${String(e && e.message || e).replace(/\s+/g, ' ').slice(0, 140)})` }
    }
    return E.parseVote(reply) || { vote: 'abstain', rationale: `${seat.id} reply had no COUNCIL-VOTE line` }
  }
}
// ---- CNCL-18 dispatch: NON-BLOCKING ballots via the task queue (default fleet path) --------
// Instead of injecting the ballot into the seat's LIVE session (the blocking `agent ask` pane
// scrape — disruptive, needs a quiet window, times mid-work seats out to abstain), we mint a
// DEADLINE-STAMPED task into the seat's queue. The seat surfaces + works that ballot at its next
// heartbeat boundary (a ballot is just a normal assigned task — NO heartbeat code change), casts
// its vote by closing the task with a COUNCIL-VOTE line in the result, and the convener COLLECTS
// by polling `task show` until the task closes with a result OR the deadline elapses. A missed
// deadline / unreadable result / unparseable vote all resolve to an ABSTAIN (the engine records
// it; abstains still count toward the quorum denominator). Blind-first-round is preserved: the
// round-1 ballot body is E.seatPrompt(seat, ctx) which the engine guarantees carries no other
// seat's take. Exec + clock are injectable (opts._exec/_now/_sleep) so the pure collection logic
// is unit-testable offline with no real `5dive` exec and no real timers.
export function dispatchBallotVote(opts = {}) {
  const bin = process.env.COUNCIL_5DIVE_BIN || '5dive'
  const from = opts.from || 'council'
  const deadlineSecs = Number(opts.deadline) > 0 ? Number(opts.deadline) : 900   // 15m default
  const pollSecs = Number(opts.poll) > 0 ? Number(opts.poll) : 5
  const now = opts._now || (() => Date.now())
  const sleep = opts._sleep || ((ms) => new Promise(r => setTimeout(r, ms)))
  // Default exec shells the real CLI; a test injects a stub reader. Returns stdout as a string.
  const exec = opts._exec || ((args) => execFileSync(bin, args,
    { encoding: 'utf-8', timeout: 60000, maxBuffer: 16 * 1024 * 1024 }))
  const clip = (e) => String(e && e.message || e).replace(/\s+/g, ' ').slice(0, 140)
  const emitBallot = opts._emitBallot || defaultEmitBallot()
  // (d) COLLECT (shared by the agent + human branches): poll task show until the ballot task closes
  // with a result, or the deadline elapses. The collection-loop deadline is AUTHORITATIVE regardless
  // of any stamp in the task body. A human tap and an agent heartbeat close the task identically, so
  // this loop is byte-identical for both — no new collection/quorum/abstain path (DIVE-1564).
  const collect = async (seat, taskId, deadlineAt, deadlineIso, kind) => {
    while (now() < deadlineAt) {
      let row = null
      try {
        const env = JSON.parse(exec(['task', 'show', String(taskId), '--json']))
        row = env && env.data && env.data.task
      } catch { row = null }
      if (row && (row.status === 'done' || row.status === 'cancelled')) {
        const result = row.result || ''
        return E.parseVote(result) ||
          { vote: 'abstain', rationale: `${seat.id} ${kind} ${taskId}: closed with no COUNCIL-VOTE line (deadline/no-vote)` }
      }
      await sleep(pollSecs * 1000)
    }
    return { vote: 'abstain', rationale: `${seat.id} ${kind} ${taskId}: no vote by deadline ${deadlineIso} (deadline/no-vote)` }
  }
  return async (seat, ctx) => {
    const prompt = E.seatPrompt(seat, ctx)   // blind in round 1 (engine-guaranteed)
    const deadlineAt = now() + deadlineSecs * 1000
    const deadlineIso = new Date(deadlineAt).toISOString()
    const question80 = String(ctx.question || '').replace(/\s+/g, ' ').slice(0, 80)
    // ---- DIVE-1564: HUMAN-AS-SEAT branch. A human seat holds no registry agent to `agent ask`; it
    // votes by TAPPING a Telegram ballot. We still mint the SAME deadline-stamped ballot task (so the
    // shared collect loop above is byte-identical for human + agent seats) and ALSO emit a Telegram
    // ballot to the seat's resolved chat: the BLIND body, a shown deadline, and three inline buttons
    // whose callback_data carries a one-time DIVE-916 nonce (never printed inline; 64B cap ->
    // prefix-accept per DIVE-1546). A human tap closes the ballot task with a COUNCIL-VOTE line via the
    // DIVE-1565 bridge; a no-tap by the deadline is the CNCL-18 miss==abstain path, unchanged.
    if (E.seatIsHuman(seat)) {
      const chat = E.resolveSeatChat(seat)
      // Fail CLOSED on an unbound human seat: never deliver to nowhere, never silently drop the ballot.
      if (!chat) return { vote: 'abstain', rationale: `${seat.id} human ballot: seat has no bound chat/principal — fail-closed, ballot NOT delivered (deadline/no-vote)` }
      // One-time DIVE-916 nonce: the RAW token rides ONLY in the buttons' callback_data. The task body
      // records only its sha256 DIGEST, so a reader of the ballot task can never forge/replay the tap.
      const nonce = randomBytes(16).toString('hex')
      const nonceDigest = createHash('sha256').update(nonce).digest('hex')
      const title = `Council ballot (human tap): ${question80} (vote by ${deadlineIso})`
      // Human seats are CLOSED by the tap bridge (DIVE-1565), never worked by an agent, so the ballot
      // task is filed to the convener (`from`); its assignee never `agent ask`-runs it. Body is BLIND +
      // carries the nonce DIGEST for the bridge to authenticate the tap against — NEVER the raw nonce.
      const body = `${prompt}\n\n[council ballot :: human tap] A council seat you hold is voting. Approve / Reject / Abstain via the Telegram buttons before the deadline. Deadline: ${deadlineIso}. A missed deadline counts as an abstain.\n[council ballot-auth] nonceDigest=${nonceDigest}`
      let taskId
      try {
        const stdout = exec(['task', 'add', title, `--body=${body}`, `--assignee=${from}`,
          `--from=${from}`, '--priority=high', '--no-verify', '--json'])
        const env = JSON.parse(stdout)
        taskId = env && env.data && (env.data.ident || env.data.id)
        if (taskId == null) throw new Error('task add returned no id')
      } catch (e) {
        return { vote: 'abstain', rationale: `${seat.id} human ballot: could not mint task (${clip(e)}) (deadline/no-vote)` }
      }
      // callback_data = cvote:<=12-char ballot-ref>:<a|r|e>:<nonce>. The ballot-ref is this ballot TASK
      // id — at DISPATCH time the sealed convene digest does not exist yet, so the task id is the stable
      // per-seat correlation the DIVE-1565 bridge PREFIX-ACCEPTS to the unique ballot task. Stays under
      // Telegram's 64B cap: "cvote:"(6) + ref(<=12) + ":"(1) + verb(1) + ":"(1) + nonce(32) ~= 53B.
      const ref = String(taskId).slice(0, 12)
      const button = (label, code) => ({ text: label, callback_data: `cvote:${ref}:${code}:${nonce}` })
      const payload = {
        chat, taskId, deadlineIso, seat: seat.id,
        text: `${prompt}\n\nCouncil ballot — vote by ${deadlineIso}.`,   // BLIND; the raw nonce is NEVER in the text
        buttons: [button('Approve', 'a'), button('Reject', 'r'), button('Abstain', 'e')],
      }
      // Emit is an injectable, never-throws seam. The CLI cannot send an inline keyboard itself
      // (DIVE-1546); the concrete button delivery is the telegram plugin tap handler (DIVE-1566), which
      // consumes this exact payload. A delivery gap just leaves the task un-tapped -> abstain-on-miss.
      try { await emitBallot(payload) } catch { /* best-effort: the missed-tap path is already an abstain */ }
      return collect(seat, taskId, deadlineAt, deadlineIso, 'human ballot')
    }
    // ---- agent seat (CNCL-18, unchanged) ----
    // CNCL-16: mint into the seat's REGISTRY agent (persona 'theo' -> 'marketing', etc.). Pre-flight
    // (preflightSeats) has already fail-closed on any unresolvable seat before we get here.
    const target = E.resolveSeatAgent(seat)
    const title = `Council ballot: ${question80} (vote by ${deadlineIso})`
    const body = `${prompt}\n\n[council ballot] Cast your vote by CLOSING this task with your COUNCIL-VOTE line as the result: 5dive task done <id> --result="...COUNCIL-VOTE: <approve|reject|escalate> :: <why>". Deadline: ${deadlineIso}. A missed deadline counts as an abstain.`
    // (c) mint the deadline-stamped ballot task. --no-verify keeps it a plain task that closes
    // directly on `task done` (no maker->grader handoff that would keep the result out of reach).
    let taskId
    try {
      const stdout = exec(['task', 'add', title, `--body=${body}`, `--assignee=${target}`,
        `--from=${from}`, '--priority=high', '--no-verify', '--json'])
      const env = JSON.parse(stdout)
      taskId = env && env.data && (env.data.ident || env.data.id)
      if (taskId == null) throw new Error('task add returned no id')
    } catch (e) {
      return { vote: 'abstain', rationale: `${seat.id} ballot: could not mint task (${clip(e)}) (deadline/no-vote)` }
    }
    return collect(seat, taskId, deadlineAt, deadlineIso, 'ballot')
  }
}
// DIVE-1564: default human-ballot emit. The CLI has no inline-keyboard send rail of its own — the
// three Approve/Reject/Abstain BUTTONS (with the raw nonce in callback_data) are rendered by the
// telegram plugin tap handler (DIVE-1566), which consumes this payload. Until that lands the default
// is a best-effort, never-throws breadcrumb: a delivery gap just leaves the ballot task un-tapped,
// which the collect loop already resolves to an abstain. NEVER logs the raw nonce / callback_data.
function defaultEmitBallot() {
  return async (payload) => {
    try {
      process.stderr.write(`[council] human ballot ${payload.taskId} queued for chat ${payload.chat} (vote by ${payload.deadlineIso}); inline buttons delivered by the telegram plugin (DIVE-1566)\n`)
    } catch { /* ignore */ }
    return { delivered: false, reason: 'no CLI inline-keyboard rail; plugin (DIVE-1566) renders buttons' }
  }
}
// ==================== DIVE-1565: human ballot TAP -> task-close BRIDGE ====================
// The alternate ACTUATOR for a human seat's vote. A Telegram Approve/Reject/Abstain tap (routed by
// the DIVE-1566 plugin from the `cvote:<ref>:<code>:<nonce>` callback_data DIVE-1564 minted) lands
// here and CLOSES the SAME CNCL-18 ballot task the convener already polls — it is NOT a second write
// path (DIVE-1548 design cut A). The convener never learns whether an agent heartbeat or a human tap
// wrote the COUNCIL-VOTE line, so there is no new collection/quorum/abstain semantics to reconcile.
// Fail-closed on EVERY ambiguity, and the raw nonce is NEVER logged.
//
//   ref   — the ballot task-id PREFIX from callback_data (DIVE-1564 mints `cvote:<taskId[:12]>:…`).
//           Prefix-ACCEPTED to a UNIQUE OPEN council human-ballot task; 0 matches = miss, >1 =
//           ambiguous — both fail-closed + audited (DIVE-1546 prefix-accept pattern). The one-time
//           property falls out for free: a tapped ballot is already `done`, so it no longer appears
//           among OPEN human ballots and a replay resolves to a miss.
//   code  — a|r|e  ->  approve|reject|abstain (the third button is Abstain; parseVote accepts all).
//   nonce — the DIVE-916 one-time token; its sha256 MUST equal the ballot body's stored nonceDigest
//           (store-digest / deliver-raw split — a reader of the ballot task can never forge the tap).
//
// Exec is injectable (opts._exec) + audit is injectable (opts._audit) so the whole bridge is
// unit-testable offline with a stub reader and no real `5dive` exec.
export function ballotTap(opts = {}) {
  const bin = opts.bin || process.env.COUNCIL_5DIVE_BIN || '5dive'
  const exec = opts._exec || ((args) => execFileSync(bin, args,
    { encoding: 'utf-8', timeout: 60000, maxBuffer: 16 * 1024 * 1024 }))
  const audit = opts._audit || ((m) => { try { process.stderr.write(`[council ballot-tap] ${m}\n`) } catch { /* ignore */ } })
  const clip = (e) => String(e && e.message || e).replace(/\s+/g, ' ').slice(0, 140)
  const VERB = { a: 'approve', r: 'reject', e: 'abstain' }
  // The ballot body records ONLY the sha256 DIGEST of the nonce (DIVE-1564): `nonceDigest=<64 hex>`.
  const digestOf = (body) => { const m = /nonceDigest=([0-9a-f]{64})\b/i.exec(String(body || '')); return m ? m[1].toLowerCase() : null }

  const ref = String(opts.ref || '').trim()
  const code = String(opts.vote || '').trim().toLowerCase()
  const nonce = String(opts.nonce || '').trim()
  const verb = VERB[code]
  // (0) fail-closed input validation — never touch the board on a malformed tap.
  if (!ref) { audit('refused: empty --ref (ballot-ref prefix)'); return { ok: false, reason: 'missing ref' } }
  if (!verb) { audit(`refused ref=${ref}: bad --vote=${code || '(empty)'} (want a|r|e)`); return { ok: false, reason: 'bad vote code' } }
  if (!nonce) { audit(`refused ref=${ref}: empty --nonce`); return { ok: false, reason: 'missing nonce' } }

  // (1) enumerate OPEN council human-ballot tasks and PREFIX-ACCEPT to a unique one. Scope to human
  // ballots only (their body carries `nonceDigest=` — agent ballots never do), so the prefix can only
  // ever resolve against real human ballots, never an arbitrary same-prefix task.
  let tasks = []
  try {
    const env = JSON.parse(exec(['task', 'ls', '--json']))
    tasks = (env && env.data && env.data.tasks) || []
  } catch (e) {
    audit(`refused ref=${ref}: could not list tasks (${clip(e)})`)
    return { ok: false, reason: 'task ls failed' }
  }
  const open = (s) => s !== 'done' && s !== 'cancelled'
  const candidates = tasks.filter(t =>
    t && open(t.status) && digestOf(t.body) &&
    (String(t.ident || '').startsWith(ref) || String(t.id || '').startsWith(ref)))
  if (candidates.length === 0) { audit(`refused ref=${ref}: no OPEN council human-ballot matches (miss — already voted / expired / bad ref)`); return { ok: false, reason: 'no match' } }
  if (candidates.length > 1) { audit(`refused ref=${ref}: AMBIGUOUS — ${candidates.length} open human-ballots match this prefix; fail-closed`); return { ok: false, reason: 'ambiguous' } }
  const task = candidates[0]
  const taskId = task.ident || task.id

  // (2) verify the one-time nonce against the ballot body's stored DIGEST. A tap whose nonce does not
  // hash to the stored digest is unauthenticated (only the human's chat ever held the raw nonce).
  const want = digestOf(task.body)
  const got = createHash('sha256').update(nonce).digest('hex')
  if (got !== want) { audit(`refused ${taskId}: nonce digest mismatch — tap NOT authenticated`); return { ok: false, reason: 'nonce mismatch', taskId: String(taskId) } }

  // (3) CLOSE the ballot task with the COUNCIL-VOTE line — the SAME ingress an agent heartbeat writes,
  // so the convener's unchanged CNCL-18 collect loop reads it identically. `(human tap)` is the only
  // provenance marker; the raw nonce is never written back.
  const result = `COUNCIL-VOTE: ${verb} :: (human tap)`
  try {
    exec(['task', 'done', String(taskId), `--result=${result}`])
  } catch (e) {
    audit(`ref=${ref} ${taskId}: nonce OK but task done failed (${clip(e)})`)
    return { ok: false, reason: 'task done failed', taskId: String(taskId), vote: verb }
  }
  audit(`ref=${ref} -> ${taskId}: recorded ${verb} (human tap)`)
  return { ok: true, taskId: String(taskId), vote: verb }
}

// Deterministic, network-free, NO `5dive` exec — every seat approves so the full dispatch path
// (blind round -> tally -> synthesis -> receipt) exercises offline in tests + VM smoke.
function mockSeatVote() {
  return async (seat) => ({ vote: 'approve', rationale: `mock: ${seat.id} sees no blocker.` })
}
// COUNCIL_MOCK -> offline mock (untouched). Otherwise the DEFAULT fleet path is the non-blocking
// ballot (CNCL-18). The old `agent ask` pane-scrape survives as an ESCAPE HATCH, opt-in via
// `--ask-rail` or COUNCIL_ASK_RAIL=1 (anything but "0"/empty).
function askRailSelected() {
  if (flagBool('ask-rail')) return true
  const e = process.env.COUNCIL_ASK_RAIL
  return !!e && e !== '0'
}
function seatVoteFor() {
  if (process.env.COUNCIL_MOCK) return mockSeatVote()
  if (askRailSelected()) {
    return dispatchSeatVote({ timeout: flag('timeout'), idle: flag('idle-secs'), poll: flag('poll-secs'), from: flag('from') })
  }
  return dispatchBallotVote({
    deadline: flag('ballot-deadline') !== undefined && flag('ballot-deadline') !== true ? flag('ballot-deadline') : flag('deadline'),
    poll: flag('ballot-poll'), from: flag('from'),
  })
}
// CNCL-16 pre-flight: the live set of registry agent names `5dive agent ask` can reach. Returns a
// Set, or null if the registry could not be read (transport/exec failure) — the caller fails CLOSED
// on null so a broken registry can't be mistaken for "every seat resolves".
function knownRegistryAgents() {
  const bin = process.env.COUNCIL_5DIVE_BIN || '5dive'
  try {
    const stdout = execFileSync(bin, ['agent', 'list', '--json'],
      { encoding: 'utf-8', timeout: 30000, maxBuffer: 16 * 1024 * 1024 })
    const env = JSON.parse(stdout)
    const arr = (env && env.data) || []
    if (!Array.isArray(arr)) return null
    return new Set(arr.map(a => a && a.name).filter(Boolean))
  } catch {
    return null
  }
}
// Resolve every seat to a registry agent and FAIL CLOSED (loud pre-flight error, exit 6) if any
// seat maps to no known agent — instead of the old behaviour where an unreachable persona seat
// (e.g. 'theo' vs registry 'marketing') was silently recorded as an ABSTAIN on every convene.
function preflightSeats(seats) {
  const known = knownRegistryAgents()
  if (known === null) {
    die("council pre-flight FAILED: could not read the agent registry (`5dive agent list --json`) — refusing to convene rather than silently abstain unreachable seats.", 6)
  }
  const unresolved = seats
    .map(s => ({ id: (s && s.id) || String(s), agent: E.resolveSeatAgent(s) }))
    .filter(x => !known.has(x.agent))
  if (unresolved.length) {
    die(`council pre-flight FAILED: ${unresolved.length} seat(s) resolve to no known registry agent — ${unresolved.map(u => `${u.id}→${u.agent}`).join(', ')}. Fix the bench seat's \`agent\` field / alias or re-seed. Known agents: ${[...known].sort().join(', ')}.`, 6)
  }
}

// ---- subcommands -----------------------------------------------------------
function cmdConstitution() {
  const p = flag('path')
  const path = p === true || p == null ? '' : String(p)
  out(E.loadConstitution(path))
}

async function cmdConvene() {
  const question = positionals[0]
  if (!question) die('convene needs a question: 5dive council convene "<q>" --seats=a,b,c')
  const registryPath = flag('registry')
  const reg = loadRegistry(registryPath)
  const cp = flag('constitution-path')
  const constitution = E.loadConstitution(cp === true || cp == null ? '' : String(cp))
  if (!constitution.valid) process.stderr.write(`council: invalid 5dive.md; using built-in defaults (${constitution.error})\n`)
  const explicitBench = flag('bench')
  const benchName = explicitBench || ((flag('seats') == null || flag('seats') === true) ? constitution.council.bench : null)
  // CNCL-8: convening THE primary council (by name, or the default with no explicit --seats)
  // fails closed until it has been human-seeded via `council init`. An ad-hoc panel (explicit
  // --seats) or an alternate bench (ship/brand/security) is a different, non-governance thing
  // and stays available. bash passes --genesis-exists=1 when the sealed genesis record is present.
  const primaryCouncil = benchName === 'council' || (!benchName && (flag('seats') == null || flag('seats') === true))
  if (primaryCouncil && !flagBool('genesis-exists')) {
    die('the Council has no genesis roster — it must be human-seeded first: sudo 5dive council init --seats=<a:chair,b,c> --threshold=<spec> --veto=<principal>', 8)
  }
  // The primary council convenes its HUMAN-SEEDED roster (the `council` bench init wrote),
  // never the hardcoded default — so init is the single source of truth for who sits.
  const effBench = benchName || (primaryCouncil ? 'council' : null)
  let seats, mode, bench = null
  if (effBench) {
    bench = resolveBench(effBench, reg)
    if (!bench) die(`unknown bench: ${effBench} (fail-closed — see 'council bench ls')`, 3)
    seats = bench.seats
    mode = flag('mode', bench.mode || 'deliberate')
  } else {
    seats = parseSeats(flag('seats'))
    if (!seats.length) seats = E.DEFAULT_COUNCIL.seats
    mode = flag('mode', 'deliberate')
  }
  // CNCL-15: a PRIMARY-council convene under a DRIFTED constitution does NOT deliberate. A live
  // 5dive.md that no longer matches the sealed digest is forged governance; we refuse to enforce
  // it and escalate to a human (verify fails closed on the same state). bash sets the flag after
  // comparing the sealed digest against the on-disk file. Ad-hoc panels are unaffected.
  if (flagBool('constitution-drift') && primaryCouncil) {
    const brief = 'Constitution drift: the live 5dive.md no longer matches the sealed constitution digest — forged governance is not enforced. This convene is escalated to a human. Restore the sealed 5dive.md, or change policy the sanctioned way: sudo 5dive council amend --file=<new 5dive.md>.'
    out({
      council: effBench || 'council', mode, question, seats: seats.map(s => s.id),
      dispatch: 'drift-escalated',
      verdict: { recommendation: 'escalate', tally: { approve: 0, reject: 0, escalate: 0 }, confidence: 0, dissent: '', escalated: true, brief },
      disposition: 'escalate', votes: [],
      constitution: { source: constitution.source, valid: constitution.valid, path: constitution.path, drift: true },
      driftEscalated: true,
    })
    return
  }
  const input = {
    role: 'convene', question, seats, mode,
    councilName: effBench || 'ad-hoc',
    decisionClass: flag('class') || (bench && bench.decisionClass) || 'ordinary',
    policy: constitution.thresholds,
    stampedAt: flag('stamped-at') || '',
  }
  const th = flag('threshold'); if (th != null && th !== true) input.threshold = Number(th)
  const tr = flag('threshold-rule'); if (tr) input.thresholdRule = tr
  // CNCL-11: a governance MOTION convene carries the motion descriptor (so the class is
  // auto-derived IN the engine, never trusted from --class) + the recused subject (dropped from
  // both dispatch and the tally base). bash passes these on `council promote|demote|expel`.
  const mkind = flag('motion-kind')
  if (mkind && mkind !== true) {
    input.motion = { kind: String(mkind), subject: flag('motion-subject') === true ? null : (flag('motion-subject') || null),
      param: flag('motion-param') === true ? null : (flag('motion-param') || null), to: flag('motion-to') === true ? null : (flag('motion-to') || null) }
    const rc = flag('recuse'); if (rc && rc !== true) input.recuse = String(rc).split(',').map(s => s.trim()).filter(Boolean)
    delete input.decisionClass   // the motion class wins; never a caller string
  }
  // CNCL-19: precedent (case-law) pool. The bash layer reads the SEALED receipt log, projects each
  // past verdict to {digest,question,recommendation,brief,stampedAt}, and hands it in via
  // --precedent-pool=<path|-> (JSON array; `-` = stdin). The engine deterministically selects the
  // top-k relevant precedents, injects them as HISTORY into every seat ballot (blind round stays
  // blind to CURRENT takes), and seals the followed/departed citation inside the receipt bytes.
  const pp = flag('precedent-pool')
  if (pp && pp !== true) {
    try {
      const raw = pp === '-' ? fs.readFileSync(0, 'utf8') : fs.readFileSync(String(pp), 'utf8')
      const arr = JSON.parse(raw)
      if (Array.isArray(arr)) input.precedentPool = arr
    } catch (e) { process.stderr.write(`council: ignoring unreadable --precedent-pool (${String(e && e.message || e)})\n`) }
  }
  const pk = flag('precedent-k'); if (pk != null && pk !== true) input.precedentK = Number(pk)
  // CNCL-9 FORGE REFUSAL: a veto can NEVER be asserted from a plain CLI string. Pre-CNCL-9,
  // `--veto-by=<who>` flipped the verdict inline, so any agent could forge lodar's veto into a
  // signed receipt. convene now REFUSES it outright (bash logs the attempt). convene only ever
  // OFFERS the veto to the authenticated genesis principal; the flip happens later via the
  // authenticated `council veto exercise` tap path, never here.
  if (flag('veto-by') != null || flag('veto-reason') != null) {
    die('refused: `--veto-by`/`--veto-reason` cannot assert a veto (a signed receipt is not forgeable from a string). The Council OFFERS the veto to the genesis principal; only an authenticated tap exercises it. This attempt is logged.', 9)
  }
  // Non-blocking veto OFFER: bash supplies the genesis-resolved principal + hold window on a
  // primary-council convene. On a PASS the engine records the offer inside the sealed bytes;
  // disposition stays `pass` (nobody waits — the ACTION waits, enforced downstream by CNCL-12).
  const vp = flag('veto-principal'), vr = flag('veto-resolved')
  if (vp && vp !== true && vr && vr !== true) {
    input.vetoOffer = { principal: String(vp), resolved: String(vr), windowSecs: Number(flag('veto-window')) || 0 }
  }
  // FLEET DEFAULT (CNCL-7): dispatch to the real seated agents (no model key). --standalone
  // (or COUNCIL_STANDALONE) selects the deferred single-key modelCall seam instead. COUNCIL_MOCK
  // runs either path offline. The engine records a timed-out/silent seat as an abstain.
  const standalone = !!flag('standalone') || !!process.env.COUNCIL_STANDALONE
  // CNCL-16: on the real-agents dispatch path, fail closed at convene START if any seat resolves
  // to no known registry agent. Skipped for the standalone seam and for COUNCIL_MOCK (offline).
  if (!standalone && !process.env.COUNCIL_MOCK) preflightSeats(seats)
  const deps = standalone
    ? { modelCall: modelCallFor(), verbose: !!flag('verbose') }
    : { seatVote: seatVoteFor(), verbose: !!flag('verbose') }
  let result
  try { result = await E.runCouncil(input, deps) }
  catch (e) { die(String(e && e.message || e), 1) }
  out({
    council: input.councilName, mode: result.mode, question,
    seats: result.seats.map(s => s.id),
    dispatch: standalone ? 'standalone-seam' : 'real-agents',
    verdict: result.verdict,
    disposition: E.dispositionOf(result.verdict),
    votes: (result.votes || []).map(v => ({ seat: v.seat, vote: v.vote, rationale: v.rationale })),
    round1Votes: result.round1Votes ? result.round1Votes.map(v => ({ seat: v.seat, vote: v.vote, rationale: v.rationale })) : undefined,
    rebuttalVotes: result.rebuttalVotes ? result.rebuttalVotes.map(v => ({ seat: v.seat, vote: v.vote, rationale: v.rationale })) : undefined,
    constitution: { source: constitution.source, valid: constitution.valid, path: constitution.path },
    // CNCL-17: the SUBJECT task ident (what this convene decided) rides on the output so bash can
    // persist it on the receipt — the going-forward link that scores seat votes against the task's
    // eventual outcome. Absent on an ad-hoc convene (those score via question-text ident parsing).
    subject: (flag('subject') && flag('subject') !== true) ? String(flag('subject')) : undefined,
    // CNCL-19: the case-law citation (which prior decisions this verdict followed vs departed
    // from) rides on the verdict and is sealed inside the receipt bytes; surface it for the
    // dashboard/log. Absent (undefined) when no precedent was found — output stays back-compatible.
    precedents: result.verdict && result.verdict.precedents ? result.verdict.precedents : undefined,
    precedentCitation: result.verdict && result.verdict.precedentCitation ? result.verdict.precedentCitation : undefined,
    receipt: result.receipt,   // { canonical, seal, verify } — bash seals canonical
  })
}

function cmdBench() {
  const action = positionals[0] || 'ls'
  const registryPath = flag('registry')
  const reg = loadRegistry(registryPath)
  if (action === 'ls') {
    const names = [...new Set([...Object.keys(BUILTINS), ...Object.keys(reg)])].sort()
    out({ benches: names.map(n => ({ name: n, builtin: n in BUILTINS, custom: n in reg })) })
    return
  }
  if (action === 'show') {
    const name = positionals[1]; if (!name) die('bench show needs a name')
    const b = resolveBench(name, reg)
    if (!b) die(`unknown bench: ${name} (fail-closed)`, 3)
    out({ name: b.name, description: b.description, mode: b.mode, seats: b.seats, builtin: name in BUILTINS, custom: name in reg })
    return
  }
  // CNCL-8: the primary council is special in EXACTLY one way — its membership changes ONLY
  // via promote/demote motions. A raw bench add/rm against it fails closed (otherwise a plain
  // `sudo bench rm council` would bypass the whole governance layer). Motions land in a later
  // wave; until then the guard is the load-bearing invariant.
  if ((action === 'add' || action === 'rm') && positionals[1] === 'council') {
    die("'council' is the primary governance body — its seats change ONLY via promote/demote motions, never raw bench add/rm (re-seed the whole roster with: sudo 5dive council init --force).", 7)
  }
  if (action === 'add') {
    const name = positionals[1]; if (!name) die('bench add needs a name')
    const seats = parseSeats(flag('seats'))
    if (!seats.length) die('bench add needs --seats=a:lens|b:lens (or a,b,c)')
    const entry = { description: flag('desc') || `${name} — custom council bench.`, mode: flag('mode') || 'deliberate', seats }
    const th = flag('threshold'); if (th != null && th !== true) { entry.threshold = Number(th); entry.thresholdRule = 'flat' }
    const tr = flag('threshold-rule'); if (tr) entry.thresholdRule = tr
    const cls = flag('class'); if (cls) entry.decisionClass = cls
    reg[name] = entry
    saveRegistry(registryPath, reg)
    out({ added: name, entry })
    return
  }
  if (action === 'rm') {
    const name = positionals[1]; if (!name) die('bench rm needs a name')
    if (!(name in reg)) {
      if (name in BUILTINS) die(`'${name}' is a built-in bench and cannot be removed (shadow it with a same-named custom bench instead)`, 4)
      die(`unknown custom bench: ${name}`, 3)
    }
    delete reg[name]
    saveRegistry(registryPath, reg)
    out({ removed: name })
    return
  }
  die(`unknown bench action: ${action} (ls|show|add|rm)`)
}

// ---- CNCL-8: council init (human-seeded genesis roster) --------------------
// Seeds the primary `council` bench ONCE from a human-supplied roster + veto principal.
// bash owns the sudo gate, the veto-principal resolution (--veto-resolved), the ROOT seal of
// the canonical bytes, and the hash-chained lineage write. cli owns: validate the roster,
// enforce one-time (fail-closed unless --force), seed the registry, and emit the record +
// canonical bytes for bash to seal. An agent can never call this to bootstrap its own council
// because the write path (COUNCIL_DIR) is root-owned — bash refuses a non-sudo init.
function cmdInit() {
  const registryPath = flag('registry')
  const genesisExists = flagBool('genesis-exists')
  const forced = !!flag('force')
  if (genesisExists && !forced) {
    die('council is already initialized (one-time). Re-seed with --force (the re-seed is logged in the lineage).', 5)
  }
  let parsed
  try { parsed = E.parseGenesisSeats(flag('seats')) }
  catch (e) { die(`bad --seats: ${String(e && e.message || e)}`) }
  const threshold = E.parseThresholdSpec(flag('threshold') || 'majority')
  if (!threshold) die(`bad --threshold (use: majority | all | <N> | <a>/<b>, e.g. 2/3)`)
  const principal = flag('veto')
  if (!principal || principal === true) die('init needs --veto=<principal> (a resolvable human, e.g. human:main)')
  const resolved = flag('veto-resolved')   // bash resolves the principal -> tg user_id
  if (!resolved || resolved === true) die(`veto principal "${principal}" did not resolve to a real recipient — init rejects an unknown/unresolvable principal (fail-closed).`, 6)
  let rec
  try {
    rec = E.buildGenesisRecord({
      seats: parsed.seats, chair: parsed.chair, threshold,
      veto: { principal: String(principal), resolved: String(resolved) },
      prevDigest: flag('prev-digest') || '', stampedAt: flag('stamped-at') || '',
      forced, seq: Number(flag('seq')) || 0,
      // CNCL-15: bash sha256sum's the seeded v0 5dive.md and passes it here so the digest is
      // sealed into the genesis bytes (drift baseline). '' if the caller seeded no constitution.
      constitutionDigest: flag('constitution-digest') === true ? '' : (flag('constitution-digest') || ''),
    })
  } catch (e) { die(String(e && e.message || e)) }
  // Seed / re-seat the primary council bench in the persisted registry (bench edits on it are
  // refused elsewhere — init and, later, motions are the ONLY writers).
  const reg = loadRegistry(registryPath)
  reg.council = E.genesisToBench(rec)
  saveRegistry(registryPath, reg)
  out({ genesis: rec, canonical: E.canonicalGenesis(rec), bench: 'council', seats: rec.seats.map(s => s.id), chair: rec.chair, constitutionDigest: rec.constitutionDigest })
}

// ---- CNCL-15: constitution v0 render + drift check + amend motion --------------------------
// `constitution-render` prints the v0 5dive.md `council init` seeds when none exists (the
// human-readable projection of the built-in defaults). bash writes it, then sha256sum's the
// on-disk bytes for the sealed digest — one digest realm across seed/amend/verify.
function cmdConstitutionRender() { process.stdout.write(E.renderConstitutionV0()) }

// `drift-check` — pure comparison of the sealed digest vs the live-file digest (both computed by
// bash with sha256sum). Exits non-zero when drifted so callers can fail closed on the exit code.
function cmdDriftCheck() {
  const sealed = flag('sealed') === true || flag('sealed') == null ? '' : String(flag('sealed'))
  const live = flag('live') === true || flag('live') == null ? '' : String(flag('live'))
  const res = E.constitutionDriftCheck({ sealedDigest: sealed, liveDigest: live })
  out(res)
  process.exit(res.drifted ? 7 : 0)
}

// `amend-plan` — validate the PROPOSED constitution (must parse+normalize), then emit the
// constitutional-class deliberation question over the full current roster (no recusal, full
// quorum + 2/3 + founder veto follow from the constitutional class). Fails closed on a bad file.
function cmdAmendPlan() {
  const roster = readJsonFlag('seats-json')
  if (!Array.isArray(roster) || !roster.length) die('amend-plan needs the current roster --seats-json (fail-closed)', 3)
  const proposed = flag('constitution')
  if (!proposed || proposed === true) die('amend-plan needs --constitution=@<file> (the proposed 5dive.md)')
  const text = String(proposed).startsWith('@') ? fs.readFileSync(String(proposed).slice(1), 'utf-8') : String(proposed)
  try { E.normalizeConstitution(E.parseConstitutionFrontmatter(text)) }
  catch (e) { die(`the proposed 5dive.md is not a valid constitution — refusing to convene an amendment on it: ${String(e && e.message || e)}`, 4) }
  const digest = flag('constitution-digest') === true || flag('constitution-digest') == null ? '' : String(flag('constitution-digest'))
  const question = `Constitution amendment motion (constitutional): should the Council RATIFY the proposed 5dive.md `
    + `(digest ${digest ? digest.slice(0, 12) + '…' : '?'})? This is the hardest bar — a 2/3 supermajority of ALL `
    + `${roster.length} seat(s) with full quorum, founder-veto-able. On a pass the new constitution is sealed into the `
    + `hash-chain and becomes the enforced governance policy. Approve to ratify, reject to keep the current constitution, escalate only if it genuinely needs a human.`
  out({ class: 'constitutional', recuse: [], subject: null, votingSeats: roster, votingSeatSpec: seatsToSpec(roster), question, constitutionDigest: digest })
}

// `amend-apply` — on a PASS only: build the hash-chained constitutional motion record carrying the
// ratified constitution digest + its canonical bytes for bash to root-seal. Roster is unchanged
// (an amend rewrites policy, not membership). Refuses a non-pass verdict (fail-closed).
function cmdAmendApply() {
  const roster = readJsonFlag('seats-json')
  if (!Array.isArray(roster) || !roster.length) die('amend-apply needs the current roster --seats-json (fail-closed)', 3)
  const verdict = readJsonFlag('verdict')
  if (!verdict || verdict.recommendation !== 'approve' || verdict.escalated) {
    die(`amendment did not carry (recommendation=${verdict && verdict.recommendation}) — the constitution is unchanged, no lineage record written`, 5)
  }
  const digest = flag('constitution-digest') === true || flag('constitution-digest') == null ? '' : String(flag('constitution-digest'))
  if (!digest) die('amend-apply needs --constitution-digest=<sha256 of the ratified 5dive.md> (fail-closed)', 4)
  const threshold = readJsonFlag('threshold-json', { optional: true }) || { rule: 'majority' }
  const veto = readJsonFlag('veto-json', { optional: true })
  let rec
  try {
    rec = E.buildMotionRecord({ motion: { kind: 'amend' }, verdict, seats: roster, threshold, veto,
      prevDigest: flag('prev-digest') === true ? '' : (flag('prev-digest') || ''),
      stampedAt: flag('stamped-at') === true ? '' : (flag('stamped-at') || ''),
      seq: Number(flag('seq')) || 0, receiptDigest: flag('receipt-digest') === true ? '' : (flag('receipt-digest') || ''),
      constitutionDigest: digest })
  } catch (e) { die(String(e && e.message || e)) }
  out({ record: rec, canonical: E.canonicalMotion(rec), class: 'constitutional', constitutionDigest: digest })
}

// ---- CNCL-9: council veto exercise (authenticated tap → chained veto record) ----------------
// Bash owns the authentication: it has already validated the tap came over the tier-2 nonce rail
// from the recipient the veto was OFFERED to (--resolved), and it reads the sealed convene receipt
// to supply --orig-digest + the original verdict. cli owns: reconstruct the flip, refuse a tap that
// doesn't match the recorded offer (fail-closed), and emit the chained record + its canonical bytes
// for bash to root-seal and hash-chain. cli NEVER trusts a --by string on its own — the resolved
// recipient must equal the offer's resolved recipient, which only bash's nonce check can honour.
function cmdVeto() {
  const action = positionals[0] || ''
  if (action !== 'exercise') die(`unknown veto action: ${action || '(none)'} (exercise)`)
  const origDigest = flag('orig-digest')
  if (!origDigest || origDigest === true) die('veto exercise needs --orig-digest=<sealed convene receipt digest>')
  const by = flag('by'); if (!by || by === true) die('veto exercise needs --by=<principal>')
  const resolved = flag('resolved'); if (!resolved || resolved === true) die('veto exercise needs --resolved=<recipient id> (the authenticated tap recipient)')
  const tier = flag('tier') === 'posthoc' ? 'posthoc' : 'hold'
  let verdict
  try { verdict = JSON.parse(flag('verdict') || '') }
  catch { die('veto exercise needs --verdict=<original verdict JSON> (bash reads it from the sealed receipt)') }
  // The offer must be present on the original verdict AND its resolved recipient must equal the tap
  // recipient — otherwise the tap did not come from the offered principal (fail-closed, refused).
  const offer = verdict && verdict.vetoOffer
  if (!offer || String(offer.resolved) !== String(resolved)) {
    die('refused: this verdict carries no veto offer for that recipient — the tap is not from the offered principal (fail-closed).', 9)
  }
  const flipped = E.exerciseFounderVeto(verdict, { by: String(by), resolved: String(resolved), reason: flag('reason') || '', tier })
  if (!flipped.vetoed) die('refused: verdict is not a vetoable pass (only an un-escalated pass with a matching offer can be vetoed).', 9)
  const rec = E.buildVetoRecord({
    origDigest: String(origDigest), tier, by: String(by), resolved: String(resolved),
    reason: flag('reason') || '', stampedAt: flag('stamped-at') || '', flippedVerdict: flipped,
  })
  out({ vetoRecord: rec, flippedVerdict: flipped, disposition: E.dispositionOf(flipped), canonical: E.canonicalVetoRecord(rec) })
}

// ---- CNCL-9 amendment: fold the veto seal-binding into the SEALED canonical ----------------
// At seal time bash mints the nonce digest + executeAfter (post-convene) and calls this to APPEND
// the deterministic seal-binding line to the canonical BEFORE sealing, so both are covered by the
// HMAC. Reads the base canonical from --canonical or stdin ("-"); prints the augmented canonical.
function readCanonicalArg() {
  const c = flag('canonical')
  if (c === '-' || c == null || c === true) { try { return fs.readFileSync(0, 'utf-8') } catch { die('seal-augment/read-binding needs the canonical on stdin or --canonical=<text>') } }
  return String(c)
}
function cmdSealAugment() {
  const canonical = readCanonicalArg()
  const nonceDigest = flag('nonce-digest') === true ? '' : (flag('nonce-digest') || '')
  const executeAfter = flag('execute-after') === true ? '' : (flag('execute-after') || '')
  process.stdout.write(E.augmentCanonicalVetoBinding(canonical, { nonceDigest, executeAfter }))
}
// At exercise time bash re-seals `.canonical` (proving it matches the stored digest) and calls this
// to read the nonce digest + executeAfter + stampedAt back OUT of the VERIFIED canonical — never
// from the raw wrapper, which is unsealed and forgeable. Fail-closed: present=false on no binding.
function cmdReadBinding() {
  out(E.parseCanonicalVetoBinding(readCanonicalArg()))
}

// ---- CNCL-12: gate-map (pure guardrail + verdict->action, no side effects) -----------------
// The auditable heart of `council gate-clear` (T1) and `council rot-triage` (T2). Bash owns
// every side effect (task show/answer/need/escalate + the convene). This verb ONLY decides:
//   phase 1 (no --verdict): run the escalate-only guardrail on the gate; emit whether it is
//           council-decidable + the deliberation QUESTION to convene on (T1), or, for --triage,
//           the triage question. A guardrail hit on a T1 gate emits the escalate command.
//   phase 2 (--verdict=<json>): map the sealed convene verdict -> the action command.
//           --triage forces the T2 mapping (triageVerdictToAction) which NEVER clears.
function cmdGateMap() {
  let gate
  try { gate = JSON.parse(flag('gate') || '') }
  catch { die('gate-map needs --gate=<json> (from `5dive task show <id> --json`, mapped to {ident,ask,type,tier,recommend,options})') }
  const triage = flagBool('triage')
  const verdictRaw = flag('verdict')
  if (verdictRaw == null || verdictRaw === true) {
    // Phase 1 — pre-convene guardrail. T2 rot-triage deliberately SKIPS the clearable check
    // (a tier-2 gate is never clearable; the triage convenes anyway, only to sharpen/re-brief).
    const guard = E.gateGuardrail(gate)
    if (triage) {
      out({ phase: 'guardrail', triage: true, clearable: false,
        question: `A tier-${gate.tier} gate has sat UNANSWERED for 48h+. You CANNOT clear it (tier-2 is human-only). Ask: "${gate.ask}". Deliberate ONLY to (a) re-brief it sharper for the human, (b) propose a rescope so the work no longer needs this gate, or (c) recommend a park with a wake date. Do NOT approve/clear it.` })
      return
    }
    if (guard.forceEscalate) {
      const verdict = { recommendation: 'escalate', escalated: true, tally: { approve: 0, reject: 0, escalate: 0 }, confidence: 1,
        dissent: 'none', brief: `Not council-clearable: ${guard.reason}.` }
      out({ phase: 'guardrail', clearable: false, reason: guard.reason, ...E.verdictToAction(gate, verdict) })
      return
    }
    out({ phase: 'guardrail', clearable: true, reason: '',
      question: `A tier-${gate.tier} gate is on the board and needs clearing. Ask: "${gate.ask}". `
        + (gate.recommend && gate.recommend !== '-'
            ? `The recommended answer is "${gate.recommend}"${gate.options ? ` (options: ${gate.options})` : ''}. Should the council APPLY that recommendation (approve), reject it, or escalate to a human?`
            : `Should the council approve, reject, or escalate to a human?`) })
    return
  }
  // Phase 2 — map the verdict to the action command.
  let verdict
  try { verdict = JSON.parse(verdictRaw) }
  catch { die('gate-map --verdict must be the convene verdict JSON') }
  out({ phase: 'action', ...(triage ? E.triageVerdictToAction(gate, verdict) : E.verdictToAction(gate, verdict)) })
}

// ---- CNCL-10: per-seat co-signed votes ------------------------------------
// SIGN-AT-SOURCE: a seat runs this INSIDE its own harness to sign its vote before it leaves the
// agent. bash resolves the seat's OWN private key (0600, owner-only) and passes --key-file; cli
// never fetches another seat's key. The convene binding (--convene + the question digest) is in
// the signed bytes, so the signature is replay-proof. Emits the `COUNCIL-SIG:` line the seat pastes
// after its COUNCIL-VOTE line (--emit=line, the dispatch default) or the full JSON row (--emit=json).
function cmdSignVote() {
  const seat = flag('seat'); if (!seat || seat === true) die('sign-vote needs --seat=<id>')
  const vote = flag('vote'); if (!['approve', 'reject', 'escalate', 'abstain'].includes(vote)) die('sign-vote needs --vote=<approve|reject|escalate|abstain>')
  const conveneId = flag('convene'); if (!conveneId || conveneId === true) die('sign-vote needs --convene=<convene id> (replay binding)')
  // The digest binds the exact question. Accept a precomputed --qdigest (bash passes it from the
  // convene) or compute it here from --question. One is required — never sign an unbound vote.
  let qdigest = flag('qdigest')
  if (!qdigest || qdigest === true) { const q = flag('question'); if (!q || q === true) die('sign-vote needs --qdigest=<hex> or --question=<text>'); qdigest = E.questionDigest(q) }
  const keyFile = flag('key-file'); if (!keyFile || keyFile === true) die('sign-vote needs --key-file=<path to the seat PKCS8 PEM> ("-" for stdin)')
  let privPem
  try { privPem = keyFile === '-' ? fs.readFileSync(0, 'utf-8') : fs.readFileSync(keyFile, 'utf-8') }
  catch (e) { die(`sign-vote cannot read the seat key: ${String(e && e.message || e)}`) }
  const row = { seat, vote, rationale: flag('rationale') === true || flag('rationale') == null ? `(${vote})` : String(flag('rationale')), stampedAt: flag('stamped-at') === true ? '' : (flag('stamped-at') || '') }
  const fp = flag('fingerprint') === true ? '' : (flag('fingerprint') || '')
  let signed
  try { signed = E.signSeatVote(row, { conveneId: String(conveneId), questionDigest: String(qdigest) }, privPem, fp) }
  catch (e) { die(`sign-vote failed to sign: ${String(e && e.message || e)}`) }
  if (flag('emit') === 'json') { out(signed); return }
  process.stdout.write(`COUNCIL-SIG: ${signed.sig}\n`)   // the line a seat pastes after COUNCIL-VOTE
}

// VERIFY-VOTES (the per-seat half of `council verify`): re-check EVERY co-signed vote against the
// roster pubkeys + revocation, bound to THIS convene (replay-proof). bash re-checks the ROOT seal
// separately; both must be green. --votes + --roster are JSON (inline or @file). Exits non-zero if
// any non-abstain vote is unsigned/forged/replayed/revoked — so a caller can gate on the exit code.
function cmdVerifyVotes() {
  const readJson = (v, what) => {
    if (!v || v === true) die(`verify-votes needs --${what}=<json or @file>`)
    try { return JSON.parse(String(v).startsWith('@') ? fs.readFileSync(String(v).slice(1), 'utf-8') : v) }
    catch (e) { die(`verify-votes: bad --${what} json: ${String(e && e.message || e)}`) }
  }
  const votes = readJson(flag('votes'), 'votes')
  const roster = readJson(flag('roster'), 'roster')
  const conveneId = flag('convene'); if (!conveneId || conveneId === true) die('verify-votes needs --convene=<convene id>')
  let qdigest = flag('qdigest')
  if (!qdigest || qdigest === true) { const q = flag('question'); if (!q || q === true) die('verify-votes needs --qdigest=<hex> or --question=<text>'); qdigest = E.questionDigest(q) }
  const res = E.verifyReceiptVotes(votes, { conveneId: String(conveneId), questionDigest: String(qdigest) }, roster)
  out({ ok: res.ok, badSeats: res.badSeats, results: res.results })
  process.exit(res.ok ? 0 : 5)
}

// ---- CNCL-11: governance surface — roster / motion (promote|demote|expel) / verify-chain -----
// The pure engine owns classification, recusal, the motion record + its canonical bytes, and the
// chain check. bash owns the sudo gate, the ROOT seal (gate-proof), the persisted lineage write,
// and reading the current roster off the sealed lineage head. cli NEVER trusts a caller class.
function readJsonFlag(name, { optional = false } = {}) {
  const v = flag(name)
  if (!v || v === true) { if (optional) return null; die(`needs --${name}=<json or @file>`) }
  try { return JSON.parse(String(v).startsWith('@') ? fs.readFileSync(String(v).slice(1), 'utf-8') : v) }
  catch (e) { die(`bad --${name} json: ${String(e && e.message || e)}`) }
}
function seatsToSpec(seats) {
  return (seats || []).map(s => `${s.id}:${(s.lens || `${s.id} — council seat.`).replace(/[|:]/g, ' ')}`).join('|')
}
function motionFromFlags() {
  const kind = flag('kind'); if (!['promote', 'demote', 'expel'].includes(kind)) die('needs --kind=promote|demote|expel')
  const subject = flag('subject'); if (!subject || subject === true) die('needs --subject=<seat id>')
  return { kind, subject: String(subject),
    param: flag('param') === true || flag('param') == null ? null : String(flag('param')),
    to: flag('to') === true || flag('to') == null ? null : String(flag('to')) }
}

// council roster — the current seats (from the persisted, motion-governed `council` bench) + the
// live pass threshold. bash augments with the veto principal + lineage head (root-owned files).
function cmdRoster() {
  const registryPath = flag('registry')
  const reg = loadRegistry(registryPath)
  // Read the RAW persisted bench (not resolveCouncil, which drops genesis/threshold/seededAt).
  const bench = { ...BUILTINS, ...reg }.council
  if (!bench || !bench.genesis) die('the Council has no genesis roster — human-seed it first: sudo 5dive council init …', 8)
  const seatCount = (bench.seats || []).length
  const threshold = E.resolveThreshold(seatCount, bench.threshold || { rule: 'majority' })
  const quorum = E.quorumSize(seatCount, bench.threshold || { rule: 'majority' })
  // CNCL-17: optionally fold each seat's TRACK RECORD (calibration vs real outcomes) into the
  // roster so membership is read alongside performance. bash passes the computed record via
  // --track-json (receipts scored against task outcomes); absent → roster stays as before.
  const tr = readJsonFlag('track-json', { optional: true })
  const seats = tr && Array.isArray(tr.seats)
    ? (bench.seats || []).map(s => {
        const row = tr.seats.find(r => r.seat === s.id)
        return row ? { ...s, trackRecord: { scored: row.scored, correct: row.correct, calibration: row.calibration, vindicated: row.vindicated } } : s
      })
    : bench.seats
  out({ council: 'council', seats, seatCount, threshold, quorum,
    thresholdSpec: bench.threshold || { rule: 'majority' }, seededAt: bench.seededAt || '',
    scoredReceipts: tr ? tr.scoredReceipts : undefined })
}

// council record — CNCL-17 seat track record. Pure: bash gathers the sealed receipts + resolves
// each subject's eventual outcome (from the decided task's terminal status) and hands both in;
// this scores every seat's votes against those outcomes (dissent VINDICATED when the outcome went
// bad; approve correct when it landed good) and emits the per-seat calibration.
function cmdRecord() {
  const receipts = readJsonFlag('receipts', { optional: true }) || []
  const outcomes = readJsonFlag('outcomes', { optional: true }) || {}
  out(E.seatTrackRecord(receipts, outcomes))
}

// council promote|demote|expel — PLAN phase (pre-convene): classify the motion IN CODE, compute
// recusal, and emit the deliberation question + the recused voting roster for bash to convene on.
function cmdMotionPlan() {
  const motion = motionFromFlags()
  const roster = readJsonFlag('seats-json')   // current roster [{id,lens,chair?}] off the lineage head
  const cls = E.classifyMotion(motion)
  const recuse = E.recusalFor(motion)
  const seated = (roster || []).some(s => String(s.id) === motion.subject)
  if ((cls === 'demote' || cls === 'expel') && !seated) die(`cannot ${cls} '${motion.subject}' — not a current council seat (fail-closed)`, 3)
  if (cls === 'promote' && seated) die(`'${motion.subject}' already holds a council seat — nothing to promote`, 4)
  const votingSeats = (roster || []).filter(s => !recuse.includes(String(s.id)))
  if (!votingSeats.length) die('no eligible voting seats after recusal (fail-closed)', 3)
  const verb = cls === 'promote' ? `SEAT '${motion.subject}' on the Council` : `${cls.toUpperCase()} '${motion.subject}' from the Council`
  const question = `Council membership motion (${cls}): should the Council ${verb}? `
    + `This is a ${cls} motion — the bar is ${cls === 'promote' ? 'a simple majority' : 'a 2/3 supermajority'} of the ${votingSeats.length} eligible seat(s)`
    + `${recuse.length ? ` ('${recuse.join(', ')}' recused as the subject)` : ''}. Approve to carry the motion, reject to deny, escalate only if it genuinely needs a human.`
  out({ class: cls, recuse, subject: motion.subject, votingSeats, votingSeatSpec: seatsToSpec(votingSeats), question })
}

// council promote|demote|expel — APPLY phase (post-convene, on a PASS only): mutate the roster,
// build the hash-chained motion record + its canonical bytes for bash to root-seal, and persist
// the new roster into the motion-governed `council` bench. Refuses a non-pass verdict (fail-closed).
function cmdMotionApply() {
  const motion = motionFromFlags()
  const roster = readJsonFlag('seats-json')
  const verdict = readJsonFlag('verdict')
  if (!verdict || verdict.recommendation !== 'approve' || verdict.escalated) {
    die(`motion did not carry (recommendation=${verdict && verdict.recommendation}) — the roster is unchanged, no lineage record written`, 5)
  }
  const cls = E.classifyMotion(motion)
  let newSeats
  if (cls === 'promote') {
    const lens = flag('lens') === true || flag('lens') == null ? undefined : String(flag('lens'))
    newSeats = E.addSeat(roster, { id: motion.subject, lens })
  } else {
    newSeats = E.removeSeat(roster, motion.subject)
    if (!newSeats.length) die('refused: a demote/expel cannot empty the Council (fail-closed)', 7)
  }
  const threshold = readJsonFlag('threshold-json', { optional: true }) || { rule: 'majority' }
  const veto = readJsonFlag('veto-json', { optional: true })
  let rec
  try {
    rec = E.buildMotionRecord({ motion, verdict, seats: newSeats, threshold, veto,
      prevDigest: flag('prev-digest') === true ? '' : (flag('prev-digest') || ''),
      stampedAt: flag('stamped-at') === true ? '' : (flag('stamped-at') || ''),
      seq: Number(flag('seq')) || 0, receiptDigest: flag('receipt-digest') === true ? '' : (flag('receipt-digest') || '') })
  } catch (e) { die(String(e && e.message || e)) }
  // Emit the record + canonical bytes + the new roster; bash root-seals FIRST, then persists the
  // roster into the motion-governed `council` bench only on a good seal (never split roster/lineage).
  const benchSeats = newSeats.map(s => ({ id: s.id, lens: s.lens || `${s.id} — council seat.` }))
  out({ record: rec, canonical: E.canonicalMotion(rec), seats: newSeats.map(s => s.id), benchSeats, bench: 'council', class: cls })
}

// council verify — the structural chain check (bash re-seals each record's canonical separately;
// both must be green). Detects an edited/dropped/reordered receipt across the WHOLE append-only log.
function cmdVerifyChain() {
  const entries = readJsonFlag('entries')
  const res = E.verifyLineageChain(entries)
  out(res)
  process.exit(res.ok ? 0 : 5)
}

// DIVE-1565: the tap->task-close bridge verb. The DIVE-1566 plugin parses `cvote:<ref>:<code>:<nonce>`
// out of the tapped button's callback_data and shells this. `--ref` is canonical (the ballot task-id
// prefix DIVE-1564 puts in callback_data); `--convene` is accepted as a compat alias for the same
// value (the DIVE-1548 design named the flag `--convene` before DIVE-1564 fixed the ref to the task id).
function cmdBallotTap() {
  const s = (k) => { const v = flag(k); return (v === true || v == null) ? '' : String(v) }
  const res = ballotTap({ ref: s('ref') || s('convene'), vote: s('vote'), nonce: s('nonce') })
  out(res)   // never carries the raw nonce
  process.exit(res.ok ? 0 : 5)
}

const main = async () => {
  if (sub === 'constitution') return cmdConstitution()
  if (sub === 'constitution-render') return cmdConstitutionRender()
  if (sub === 'drift-check') return cmdDriftCheck()
  if (sub === 'amend-plan') return cmdAmendPlan()
  if (sub === 'amend-apply') return cmdAmendApply()
  if (sub === 'convene') return cmdConvene()
  if (sub === 'roster') return cmdRoster()
  if (sub === 'record') return cmdRecord()
  if (sub === 'motion-plan') return cmdMotionPlan()
  if (sub === 'motion-apply') return cmdMotionApply()
  if (sub === 'verify-chain') return cmdVerifyChain()
  if (sub === 'bench') return cmdBench()
  if (sub === 'init') return cmdInit()
  if (sub === 'veto') return cmdVeto()
  if (sub === 'gate-map') return cmdGateMap()
  if (sub === 'seal-augment') return cmdSealAugment()
  if (sub === 'read-binding') return cmdReadBinding()
  if (sub === 'sign-vote') return cmdSignVote()
  if (sub === 'verify-votes') return cmdVerifyVotes()
  if (sub === 'ballot-tap') return cmdBallotTap()
  die(`unknown council subcommand: ${sub} (constitution|convene|bench|init|veto|gate-map|seal-augment|read-binding|sign-vote|verify-votes|ballot-tap|roster|motion-plan|motion-apply|verify-chain)`)
}
// Run as the CLI entrypoint only when executed directly (node cli.mjs …). Guarded so a test can
// `import` this module (e.g. to exercise dispatchBallotVote's pure logic) WITHOUT triggering the
// arg-parser + process.exit. When embedded and run via `node "$dir/cli.mjs"`, argv[1] IS this file.
const isEntrypoint = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href
if (isEntrypoint) main().catch(e => die(String(e && e.message || e), 1))
