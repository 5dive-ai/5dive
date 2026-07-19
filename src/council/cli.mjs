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

// ---- subcommands -----------------------------------------------------------
async function cmdConvene() {
  const question = positionals[0]
  if (!question) die('convene needs a question: 5dive council convene "<q>" --seats=a,b,c')
  const registryPath = flag('registry')
  const reg = loadRegistry(registryPath)
  const benchName = flag('bench')
  let seats, mode, bench = null
  if (benchName) {
    bench = resolveBench(benchName, reg)
    if (!bench) die(`unknown bench: ${benchName} (fail-closed — see 'council bench ls')`, 3)
    seats = bench.seats
    mode = flag('mode', bench.mode || 'deliberate')
  } else {
    seats = parseSeats(flag('seats'))
    if (!seats.length) seats = E.DEFAULT_COUNCIL.seats
    mode = flag('mode', 'deliberate')
  }
  const input = {
    role: 'convene', question, seats, mode,
    councilName: benchName || 'ad-hoc',
    decisionClass: flag('class') || (bench && bench.decisionClass) || 'ordinary',
    stampedAt: flag('stamped-at') || '',
  }
  const th = flag('threshold'); if (th != null && th !== true) input.threshold = Number(th)
  const tr = flag('threshold-rule'); if (tr) input.thresholdRule = tr
  const vetoBy = flag('veto-by'); if (vetoBy) input.veto = { by: vetoBy, reason: flag('veto-reason') || '' }
  let result
  try { result = await E.runCouncil(input, { modelCall: modelCallFor(), verbose: !!flag('verbose') }) }
  catch (e) { die(String(e && e.message || e), 1) }
  out({
    council: input.councilName, mode: result.mode, question,
    seats: result.seats.map(s => s.id),
    verdict: result.verdict,
    disposition: E.dispositionOf(result.verdict),
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

const main = async () => {
  if (sub === 'convene') return cmdConvene()
  if (sub === 'bench') return cmdBench()
  die(`unknown council subcommand: ${sub} (convene|bench)`)
}
main().catch(e => die(String(e && e.message || e), 1))
