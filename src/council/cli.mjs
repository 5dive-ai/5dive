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
    let reply = ''
    try {
      const stdout = execFileSync(bin, ['agent', 'ask', seat.id, prompt,
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
// Deterministic, network-free, NO `5dive` exec — every seat approves so the full dispatch path
// (blind round -> tally -> synthesis -> receipt) exercises offline in tests + VM smoke.
function mockSeatVote() {
  return async (seat) => ({ vote: 'approve', rationale: `mock: ${seat.id} sees no blocker.` })
}
function seatVoteFor() {
  if (process.env.COUNCIL_MOCK) return mockSeatVote()
  return dispatchSeatVote({ timeout: flag('timeout'), idle: flag('idle-secs'), poll: flag('poll-secs'), from: flag('from') })
}

// ---- subcommands -----------------------------------------------------------
async function cmdConvene() {
  const question = positionals[0]
  if (!question) die('convene needs a question: 5dive council convene "<q>" --seats=a,b,c')
  const registryPath = flag('registry')
  const reg = loadRegistry(registryPath)
  const benchName = flag('bench')
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
  const input = {
    role: 'convene', question, seats, mode,
    councilName: effBench || 'ad-hoc',
    decisionClass: flag('class') || (bench && bench.decisionClass) || 'ordinary',
    stampedAt: flag('stamped-at') || '',
  }
  const th = flag('threshold'); if (th != null && th !== true) input.threshold = Number(th)
  const tr = flag('threshold-rule'); if (tr) input.thresholdRule = tr
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
    })
  } catch (e) { die(String(e && e.message || e)) }
  // Seed / re-seat the primary council bench in the persisted registry (bench edits on it are
  // refused elsewhere — init and, later, motions are the ONLY writers).
  const reg = loadRegistry(registryPath)
  reg.council = E.genesisToBench(rec)
  saveRegistry(registryPath, reg)
  out({ genesis: rec, canonical: E.canonicalGenesis(rec), bench: 'council', seats: rec.seats.map(s => s.id), chair: rec.chair })
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

const main = async () => {
  if (sub === 'convene') return cmdConvene()
  if (sub === 'bench') return cmdBench()
  if (sub === 'init') return cmdInit()
  if (sub === 'veto') return cmdVeto()
  if (sub === 'seal-augment') return cmdSealAugment()
  if (sub === 'read-binding') return cmdReadBinding()
  die(`unknown council subcommand: ${sub} (convene|bench|init|veto|seal-augment|read-binding)`)
}
main().catch(e => die(String(e && e.message || e), 1))
