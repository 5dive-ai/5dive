// CNCL-6 engine unit + contract test — offline, mock model (no live COUNCIL_API_KEY).
// Binds directly to the shipped engine (src/council/engine.mjs), so the ported P1/P2
// verdict->action maps + escalate-only guardrail + P3 receipt keep their contract, and
// the new CNCL-6 behavior (threshold tally, unbounded self-governed roster, founder veto,
// A-with-seam adapter) is proven. Exit 0 == green.
import {
  guardrail, gateGuardrail, nodeGuardrail, verdictToAction, verifierVerdictToAction,
  nodeVerdictToDecision, resolveCouncil, STANDING_COUNCILS, DEFAULT_COUNCIL, DEFAULT_THRESHOLD,
  resolveThreshold, tallyVotes, attachVetoOffer, exerciseFounderVeto, vetoConfig,
  buildVetoRecord, canonicalVetoRecord, VETO_DEFAULTS, dispositionOf, addSeat, removeSeat,
  THRESHOLD_POLICY, quorumSize, resolveSeatAgent, SEAT_AGENT_ALIAS,
  canonicalTranscript, validateAgainstSchema, makeAnthropicModelCall, runCouncil, TAKE, VOTE, NODE_VOTE,
  augmentCanonicalVetoBinding, parseCanonicalVetoBinding, triageVerdictToAction,
  classifyMotion, recusalFor, CONSTITUTIONAL_PARAMS,
  buildMotionRecord, canonicalMotion, chainEntryOf, verifyLineageChain,
  digestConstitution, constitutionDriftCheck, renderConstitutionV0,
  buildGenesisRecord, canonicalGenesis, normalizeConstitution, parseConstitutionFrontmatter,
} from '../src/council/engine.mjs'

let pass = 0, fail = 0
const ok = (c, m) => { c ? pass++ : (fail++, console.error('FAIL:', m)) }
const T = (a, r, e) => ({ approve: a, reject: r, escalate: e })
const V = (seat, vote) => ({ seat, vote })   // CNCL-11: a cast vote (seat id + choice)

// ---- escalate-only guardrail (ported P1/P2 contract) ----
ok(guardrail({ tier: 1, type: 'decision' }).forceEscalate === false, 'tier-1 decision is council-gradable')
ok(guardrail({ tier: 2, type: 'decision' }).forceEscalate === true, 'tier-2 -> escalate')
ok(gateGuardrail({ tier: 1, type: 'secret' }).forceEscalate === true, 'secret is human-only -> escalate')
ok(nodeGuardrail({ type: 'decision' }).forceEscalate === true, 'missing tier fails closed')
for (const t of ['approval', 'manual', 'access']) ok(guardrail({ tier: 1, type: t }).forceEscalate === true, `${t} human-only -> escalate`)

// ---- (P1) gate-clear map ----
const gate = { ident: 'DIVE-9', ask: 'ship copy fix', type: 'decision', tier: 1, recommend: 'ship', options: 'ship|hold' }
const clr = verdictToAction(gate, { recommendation: 'approve', escalated: false, tally: T(3, 0, 0), confidence: 0.9, dissent: 'none', brief: '' })
ok(clr.action === 'clear' && /^5dive task answer DIVE-9 --value=/.test(clr.command), 'gate approve -> task answer')
const gEsc = verdictToAction(gate, { recommendation: 'escalate', escalated: true, tally: T(1, 1, 1), confidence: 0.4, dissent: 'split', brief: 'human call' })
ok(gEsc.action === 'escalate' && /task need DIVE-9 .*--tier=2/.test(gEsc.command) && gEsc.command.includes('task escalate DIVE-9 --from=council'), 'gate escalate -> tier-2 + escalate')

// ---- (P2) verifier + node maps ----
const task = { ident: 'DIVE-10', ask: 'add --json', accept: 'valid JSON', type: 'decision', tier: 1 }
ok(verifierVerdictToAction(task, { recommendation: 'approve', escalated: false, tally: T(3, 0, 0), confidence: 0.9, dissent: 'none', brief: '' }).action === 'accept', 'verifier approve -> accept/task done')
const vrej = verifierVerdictToAction(task, { recommendation: 'reject', escalated: false, tally: T(1, 2, 0), confidence: 0.7, dissent: 'strip the log line', brief: '' })
ok(vrej.action === 'reject' && /task reject DIVE-10 --feedback=/.test(vrej.command) && !/task need|task escalate/.test(vrej.command), 'verifier reject -> task reject, stays in loop (no human)')
const node = { ident: 'DIVE-11', question: 'provider?', options: 'hetzner|ovh', type: 'decision', tier: 1 }
ok(nodeVerdictToDecision(node, { choice: 'ovh', escalated: false, tally: T(2, 1, 0), confidence: 0.8, dissent: '', brief: '' }).action === 'decide', 'node valid branch -> decide')
ok(nodeVerdictToDecision(node, { choice: 'aws', escalated: false, tally: T(1, 1, 1), confidence: 0.5, dissent: '', brief: 'no in-set winner' }).action === 'escalate', 'node off-list choice -> escalate (never invent a branch)')

// ---- resolveCouncil fail-closed (P3) ----
ok(resolveCouncil('ship', STANDING_COUNCILS).seats.length === 3, 'ship bench resolves')
ok(resolveCouncil('nope', STANDING_COUNCILS) === null, 'unknown bench -> null (fail-closed)')
ok(resolveCouncil('') === null, 'empty bench name -> null')

// ---- CNCL-6: default roster + threshold (NOT hardcoded) ----
ok(DEFAULT_COUNCIL.seats.map(s => s.id).join(',') === 'eng-lead,brand,builder,strategy,contrarian', 'starting roster = 5 role-archetype seats')
const builtinSeats = [DEFAULT_COUNCIL, ...Object.values(STANDING_COUNCILS)].flatMap(c => c.seats)
const privatePersonaIds = new Set(['main', 'mark', 'theo', 'codex', 'olivia', 'lilbro', 'redteam'])
ok(builtinSeats.every(s => !privatePersonaIds.has(s.id)), 'shipped council defaults contain no private persona ids')
ok(builtinSeats.every(s => !Object.hasOwn(s, 'agent')), 'shipped council defaults do not route to private registry agents')
ok(STANDING_COUNCILS.ship.seats.map(s => s.id).join(',') === 'reviewer,security,cost', 'ship bench uses role archetypes')
ok(STANDING_COUNCILS.brand.seats.map(s => s.id).join(',') === 'brand,operator,contrarian', 'brand bench uses role archetypes')
ok(STANDING_COUNCILS.security.seats.map(s => s.id).join(',') === 'security,red-team,reviewer', 'security bench uses role archetypes')
ok(DEFAULT_THRESHOLD === 3, 'default flat threshold = 3')
ok(resolveThreshold(5, { threshold: 3, thresholdRule: 'flat' }) === 3, 'flat threshold resolves to 3')
ok(resolveThreshold(5, { thresholdRule: 'majority' }) === 3, 'majority of 5 = 3')
ok(resolveThreshold(9, { thresholdRule: 'majority' }) === 5, 'majority of 9 = 5 (scales, unbounded)')
ok(resolveThreshold(7, { thresholdRule: 'majority' }) === 4, 'majority of 7 = 4')

// ---- CNCL-6: deterministic tally (pass 3/5) ----
const v5 = (a, r, e) => [...Array(a).fill({ vote: 'approve' }), ...Array(r).fill({ vote: 'reject' }), ...Array(e).fill({ vote: 'escalate' })]
ok(tallyVotes(v5(3, 2, 0), { threshold: 3, seatCount: 5 }).recommendation === 'approve', '3/5 approve -> PASS')
ok(tallyVotes(v5(2, 3, 0), { threshold: 3, seatCount: 5 }).recommendation === 'reject', '2/5 approve -> reject')
ok(tallyVotes(v5(2, 0, 3), { threshold: 3, seatCount: 5 }).recommendation === 'escalate', 'escalate plurality -> escalate')
ok(tallyVotes(v5(5, 0, 0), { thresholdRule: 'majority', seatCount: 5 }).recommendation === 'approve', 'majority rule pass drops in')
ok(tallyVotes(v5(6, 3, 0), { thresholdRule: 'majority', seatCount: 9 }).recommendation === 'approve', '6/9 majority -> PASS (unbounded seats)')

// ---- CNCL-6: TIERED thresholds per decision class + quorum-validity gate ----
ok(THRESHOLD_POLICY.ordinary.rule === 'majority' && THRESHOLD_POLICY.demote.rule === 'fraction' && THRESHOLD_POLICY.constitutional.requireQuorum === true, 'per-class policy: ordinary=majority, demote=2/3, constitutional requires quorum')
ok(quorumSize(5, { quorum: 'majority' }) === 3, 'quorum majority of 5 = 3')
ok(quorumSize(6, { quorum: 'all' }) === 6, 'constitutional full quorum = all seats')
ok(quorumSize(5, { quorum: 'none' }) === 0, 'quorum none = 0')
// quorum GATE: too few seats voted -> inquorate -> escalate (matters for async seats)
ok(tallyVotes(v5(2, 0, 0), { decisionClass: 'ordinary', seatCount: 5 }).quorumMet === false, 'only 2 of 5 voted -> quorum NOT met')
ok(tallyVotes(v5(2, 0, 0), { decisionClass: 'ordinary', seatCount: 5 }).recommendation === 'escalate', 'inquorate vote -> escalate (cannot decide)')
// ordinary = majority
ok(tallyVotes(v5(3, 2, 0), { decisionClass: 'ordinary', seatCount: 5 }).recommendation === 'approve', 'ordinary 3/5 majority -> PASS')
// demote/expel = 2/3
ok(tallyVotes(v5(4, 2, 0), { decisionClass: 'demote', seatCount: 6 }).recommendation === 'approve', 'demote 4/6 (>=2/3) -> PASS')
ok(tallyVotes(v5(3, 3, 0), { decisionClass: 'demote', seatCount: 6 }).recommendation === 'reject', 'demote 3/6 (<2/3) -> fail')
// constitutional = 2/3 + FULL quorum
ok(tallyVotes(v5(5, 1, 0), { decisionClass: 'constitutional', seatCount: 6 }).recommendation === 'approve', 'constitutional 5/6 with full quorum (all voted, >=2/3) -> PASS')
ok(tallyVotes(v5(5, 0, 0), { decisionClass: 'constitutional', seatCount: 6 }).quorumMet === false, 'constitutional needs FULL quorum: 5 of 6 voted -> inquorate')
ok(tallyVotes(v5(5, 0, 0), { decisionClass: 'constitutional', seatCount: 6 }).recommendation === 'escalate', 'constitutional short of full quorum -> escalate')

// ---- CNCL-6: self-governed roster (add/remove, unbounded, idempotent) ----
let roster = DEFAULT_COUNCIL.seats
roster = addSeat(roster, { id: 'dario', lens: 'builder' })
ok(roster.length === 6 && roster.some(s => s.id === 'dario'), 'addSeat promotes a 6th seat (unbounded)')
ok(addSeat(roster, 'dario').length === 6, 'addSeat is idempotent (no dup)')
ok(removeSeat(roster, 'dario').length === 5 && !removeSeat(roster, 'dario').some(s => s.id === 'dario'), 'removeSeat demotes a seat')

// ---- CNCL-9: authenticated founder veto (non-blocking OFFER + two-tier authenticated EXERCISE) ----
const passV = { recommendation: 'approve', escalated: false, tally: T(4, 1, 0), confidence: 0.9, dissent: 'none', brief: '' }
const rejV = { recommendation: 'reject', escalated: false, tally: T(1, 4, 0), confidence: 0.8, dissent: 'x', brief: '' }
const OFFER = { principal: 'human:main', resolved: '433634012', windowSecs: 900 }

// OFFER is non-blocking: a pass STAYS a pass; the offer just rides on the verdict.
const offered = attachVetoOffer(passV, OFFER)
ok(offered.vetoOffer && offered.vetoOffer.state === 'offered-not-exercised', 'offer recorded on a pass')
ok(offered.recommendation === 'approve' && offered.disposition === undefined, 'offer does NOT block — pass stays a pass')
ok(dispositionOf(offered) === 'pass', 'dispositionOf(offered pass) = pass')
ok(attachVetoOffer(rejV, OFFER).vetoOffer === undefined, 'no offer on a non-pass (nothing to veto)')
ok(attachVetoOffer(passV, { principal: 'x' }).vetoOffer === undefined, 'offer needs a resolved recipient (fail-closed)')

// EXERCISE (authenticated tap) — HOLD tier flips to blocked, no unwind.
const hold = exerciseFounderVeto(offered, { by: 'human:main', resolved: '433634012', reason: 'not now', tier: 'hold' })
ok(hold.vetoed === true && hold.disposition === 'blocked' && hold.vetoTier === 'hold' && hold.unwindRequired === false, 'hold-tier tap flips pass -> blocked (no unwind)')
ok(dispositionOf(hold) === 'blocked', 'dispositionOf(exercised) = blocked')
// POSTHOC tier flips + requires unwind.
const posthoc = exerciseFounderVeto(offered, { by: 'human:main', resolved: '433634012', tier: 'posthoc' })
ok(posthoc.vetoed === true && posthoc.vetoTier === 'posthoc' && posthoc.unwindRequired === true, 'posthoc-tier tap flips + requires unwind')
// FAIL-CLOSED: a tap from the wrong recipient, or on a verdict with no offer, is a no-op.
ok(exerciseFounderVeto(offered, { by: 'human:main', resolved: '999', tier: 'hold' }).vetoed !== true, 'tap from wrong recipient is refused (no flip)')
ok(exerciseFounderVeto(passV, { by: 'human:main', resolved: '433634012' }).vetoed !== true, 'exercise with no recorded offer is a no-op (fail-closed)')
ok(exerciseFounderVeto(offered, { by: 'human:main' }).vetoed !== true, 'exercise without a resolved recipient is a no-op')

// config seam (CNCL-13/14): defaults + env override, no hardcode leaks.
ok(vetoConfig().holdSecs === VETO_DEFAULTS.holdSecs && vetoConfig().posthocSecs === VETO_DEFAULTS.posthocSecs, 'vetoConfig defaults = 15m hold / 48h posthoc')
ok(vetoConfig({ COUNCIL_VETO_HOLD_SECS: '60' }).holdSecs === 60, 'vetoConfig honors env override')
ok(vetoConfig({ COUNCIL_VETO_HOLD_SECS: 'bad' }).holdSecs === VETO_DEFAULTS.holdSecs, 'vetoConfig falls back on a bad value')

// chained veto record references the ORIGINAL digest inside its own signed bytes.
const vrec = buildVetoRecord({ origDigest: 'ABC', tier: 'posthoc', by: 'human:main', resolved: '433634012', reason: 'r', stampedAt: 'T', flippedVerdict: hold })
ok(vrec.kind === 'veto' && vrec.origDigest === 'ABC' && vrec.unwindRequired === true, 'buildVetoRecord chains to orig digest + carries unwind')
ok(canonicalVetoRecord(vrec).includes('origDigest: ABC') && canonicalVetoRecord(vrec).includes('tier: posthoc'), 'canonical veto record seals the chain link + tier')
let threw = false; try { buildVetoRecord({ tier: 'hold', by: 'x', resolved: '1' }) } catch { threw = true }
ok(threw, 'buildVetoRecord refuses a record with no origDigest to chain to')

// ---- P3 receipt: deterministic, tamper-evident, veto INSIDE signed bytes ----
const rec = { council: 'council', mode: 'deliberate', stampedAt: '2026-07-19T00:00:00Z', question: 'ship v0.11?',
  seats: ['main', 'theo', 'codex'], votes: [{ seat: 'theo', vote: 'approve', rationale: 'lgtm' }, { seat: 'main', vote: 'approve', rationale: 'ok' }],
  verdict: { recommendation: 'approve', tally: T(2, 0, 0), confidence: 0.9, dissent: 'none', escalated: false } }
const c1 = canonicalTranscript(rec)
ok(c1 === canonicalTranscript({ ...rec, seats: ['theo', 'codex', 'main'] }), 'canonical is order-independent (stable bytes)')
ok(c1 !== canonicalTranscript({ ...rec, question: 'ship v0.12?' }), 'any field edit changes the bytes (tamper-evident)')
ok(c1.includes('veto: none'), 'no-offer receipt records veto: none inside the bytes')
const cOffer = canonicalTranscript({ ...rec, verdict: { ...rec.verdict, vetoOffer: { principal: 'human:main', resolved: '433634012', windowSecs: 900, state: 'offered-not-exercised' } } })
ok(cOffer.includes('veto: offered human:main window 900s :: offered-not-exercised') && cOffer !== c1, 'veto OFFER is INSIDE the signed bytes')
const cVeto = canonicalTranscript({ ...rec, verdict: { ...rec.verdict, vetoed: true, vetoTier: 'posthoc', vetoedBy: 'human:main', vetoReason: 'hold' } })
ok(cVeto.includes('veto: exercised posthoc human:main :: hold') && cVeto !== c1, 'exercised veto (with tier) is INSIDE the signed bytes')

// ---- A-with-seam adapter: schema-validate + no live key needed to construct ----
ok(validateAgainstSchema({ seat: 'a', vote: 'approve', rationale: 'x' }, VOTE) === null, 'valid VOTE passes schema check')
ok(validateAgainstSchema({ seat: 'a', vote: 'bogus', rationale: 'x' }, VOTE) !== null, 'bad enum caught by schema check')
ok(typeof makeAnthropicModelCall({ apiKey: 'x' }) === 'function', 'adapter constructs (seam) without a network call')

// ---- full runCouncil integration with a MOCK model (no key, deterministic) ----
function mockModel(votesById) {
  return async (prompt, schema) => {
    if (schema === TAKE) { const id = (prompt.match(/"([^"]+)" seat/) || [])[1] || 'x'; return { seat: id, position: 'take', keyRisk: 'risk' } }
    if (schema === VOTE) { const id = (prompt.match(/"([^"]+)" seat/) || [])[1] || 'x'; return { seat: id, vote: votesById[id] || 'approve', rationale: 'r' } }
    if (schema === NODE_VOTE) { const id = (prompt.match(/"([^"]+)" seat/) || [])[1] || 'x'; return { seat: id, choice: 'hetzner', rationale: 'r' } }
    // NARRATIVE / VERDICT / NODE_VERDICT
    if (schema.required && schema.required.includes('choice')) return { choice: 'hetzner', tally: T(3, 0, 0), confidence: 0.8, dissent: 'none', escalated: false, brief: '' }
    if (schema.required && schema.required.includes('recommendation')) return { recommendation: 'approve', tally: T(3, 0, 0), confidence: 0.8, dissent: 'none', escalated: false, brief: '' }
    return { confidence: 0.8, dissent: 'none', brief: '' } // NARRATIVE
  }
}
// default council, 4 approve / 1 reject -> PASS (>=3), receipt built
const r1 = await runCouncil({ role: 'convene', question: 'ship v0.11?', councilName: 'council' },
  { modelCall: mockModel({ 'eng-lead': 'approve', brand: 'approve', builder: 'approve', strategy: 'approve', contrarian: 'reject' }) })
ok(r1.verdict.recommendation === 'approve' && r1.verdict.tally.approve === 4, 'runCouncil: 4/5 approve -> PASS via deterministic tally')
ok(r1.receipt && r1.receipt.canonical.includes('council: council') && r1.receipt.seal.includes('gate-proof sign'), 'runCouncil: receipt built with seal command')
// 2 approve -> reject
const r2 = await runCouncil({ role: 'convene', question: 'ship?' },
  { modelCall: mockModel({ 'eng-lead': 'approve', brand: 'approve', builder: 'reject', strategy: 'reject', contrarian: 'reject' }) })
ok(r2.verdict.recommendation === 'reject', 'runCouncil: 2/5 approve -> reject')
// CNCL-9: a veto OFFER threads through runCouncil non-blocking — the pass stays a pass and the
// offer rides inside the sealed receipt (the flip only ever happens later via an authenticated tap).
const r3 = await runCouncil({ role: 'convene', question: 'ship?', vetoOffer: { principal: 'human:main', resolved: '433634012', windowSecs: 900 } },
  { modelCall: mockModel({ 'eng-lead': 'approve', brand: 'approve', builder: 'approve', strategy: 'approve', contrarian: 'approve' }) })
ok(r3.verdict.recommendation === 'approve' && r3.verdict.vetoed !== true, 'runCouncil: veto offer does NOT block the pass')
ok(r3.verdict.vetoOffer && r3.receipt.canonical.includes('veto: offered human:main window 900s'), 'runCouncil: offer rides inside the sealed receipt')
// hard-gate guardrail short-circuits (verifier role, tier-2) with NO model spend
let calls = 0
const r4 = await runCouncil({ role: 'verifier', task: { ident: 'DIVE-9', ask: 'x', accept: 'y', type: 'decision', tier: 2 } },
  { modelCall: async () => { calls++; return {} } })
ok(r4.verdict.escalated === true && r4.convened === false && calls === 0, 'runCouncil: tier-2 guardrail escalates with zero model calls')

// CNCL-9 AMENDMENT: veto seal-binding folds the nonce digest + executeAfter INTO the sealed bytes.
const _vbBase = canonicalTranscript(rec)
ok(augmentCanonicalVetoBinding(_vbBase, {}) === _vbBase, 'seal-binding: no digest/deadline leaves canonical byte-identical')
const _vbAug = augmentCanonicalVetoBinding(_vbBase, { nonceDigest: 'deadbeef', executeAfter: '2026-07-19T12:15:00Z' })
ok(_vbAug.split('\n').length === _vbBase.split('\n').length + 1, 'seal-binding: appends exactly one deterministic line')
ok(_vbAug.startsWith(_vbBase + '\n'), 'seal-binding: appended (never interleaved) — base bytes preserved')
const _vbP = parseCanonicalVetoBinding(_vbAug)
ok(_vbP.present && _vbP.nonceDigest === 'deadbeef' && _vbP.executeAfter === '2026-07-19T12:15:00Z', 'seal-binding: parse round-trips nonceDigest + executeAfter')
ok(_vbP.stampedAt === rec.stampedAt, 'seal-binding: stampedAt read from the (already-sealed) canonical line')
ok(parseCanonicalVetoBinding(_vbBase).present === false, 'seal-binding: fail-closed present=false when no binding line')
// The point of the amendment: an edit to the sealed nonce digest changes the canonical bytes (so
// the exercise-time re-seal will no longer match) — proving the digest is now covered by the HMAC.
const _vbTampered = _vbAug.replace('nonceDigest=deadbeef', 'nonceDigest=cafebabe')
ok(_vbTampered !== _vbAug && parseCanonicalVetoBinding(_vbTampered).nonceDigest === 'cafebabe', 'seal-binding: swapping the nonce digest changes the sealed canonical (re-seal will break)')

// CNCL-12 T2 ROT-TRIAGE: the fail-closed rule — a tier-2 gate is NEVER cleared by triage.
const t2gate = { ident: 'DIVE-77', ask: 'Ship the pricing change?', type: 'decision', tier: 2, recommend: 'ship', options: 'ship|hold' }
const trRebrief = triageVerdictToAction(t2gate, { recommendation: 'escalate', escalated: true, tally: T(0, 0, 3), confidence: 0.6, dissent: 'needs a human', brief: 'Sharper: this touches live pricing — a human must sign off.' })
ok(trRebrief.action === 'triage-rebrief' && trRebrief.cleared === false, 'triage: action=rebrief, cleared=false')
ok(!/task answer/.test(trRebrief.command), 'triage: command NEVER contains `task answer`')
ok(/task need DIVE-77 .*--tier=2/.test(trRebrief.command) && /--from=council-triage/.test(trRebrief.command), 'triage: re-files a SHARPER tier-2 ask + re-escalates')
// The load-bearing invariant: EVEN an `approve` verdict on a tier-2 gate does NOT clear it.
const trApprove = triageVerdictToAction(t2gate, { recommendation: 'approve', escalated: false, tally: T(3, 0, 0), confidence: 0.9, dissent: 'none', brief: '' })
ok(trApprove.cleared === false && !/task answer/.test(trApprove.command), 'triage: an APPROVE verdict STILL never clears a tier-2 gate (fail-closed)')
ok(trRebrief.command.includes('--options='), 'triage: preserves the original options for the human')
// CNCL-12 main-gate amendment: NEVER downgrade a human-only type to `decision` on re-file — a
// stale `secret` gate re-filed as a plain decision would invite the human to paste the secret
// onto the fleet-readable board. Both gate mappers must preserve the original type.
const secretGate = { ident: 'DIVE-1478', ask: 'R2 creds — do NOT paste here', type: 'secret', tier: 2, recommend: '', options: '' }
ok(/--type=secret /.test(triageVerdictToAction(secretGate, { recommendation: 'escalate', escalated: true, tally: T(0,0,3), confidence: 0.5, dissent: 'human', brief: 'still needs the human' }).command), 'triage: a secret gate re-files as type=secret (never downgraded to decision)')
ok(/--type=secret /.test(verdictToAction(secretGate, { recommendation: 'escalate', escalated: true, tally: T(0,0,3), confidence: 0.5, dissent: 'human', brief: 'needs human' }).command), 'gate escalate: a secret gate stays type=secret (no paste-inviting downgrade)')
for (const ht of ['approval', 'manual', 'access']) ok(new RegExp(`--type=${ht} `).test(verdictToAction({ ...secretGate, type: ht }, { recommendation: 'escalate', escalated: true, tally: T(0,0,3), confidence: 0.5, dissent: 'h', brief: 'b' }).command), `gate escalate: human-only type ${ht} preserved on re-file`)

// CNCL-16: seat PERSONA id vs dispatch REGISTRY agent. A seat's `agent` (canonical) wins; else the
// alias map resolves a known persona (theo->marketing, lilbro->creative); else the id IS the agent.
ok(resolveSeatAgent({ id: 'theo', lens: 'x' }) === 'marketing', 'resolveSeatAgent: persona theo -> registry marketing (alias)')
ok(resolveSeatAgent({ id: 'lilbro', lens: 'x' }) === 'creative', 'resolveSeatAgent: persona lilbro -> registry creative (alias)')
ok(resolveSeatAgent({ id: 'main', lens: 'x' }) === 'main', 'resolveSeatAgent: an id that IS a registry name resolves to itself')
ok(resolveSeatAgent({ id: 'theo', agent: 'someone', lens: 'x' }) === 'someone', 'resolveSeatAgent: an explicit seat.agent wins over the alias map')
ok(resolveSeatAgent('theo') === 'marketing' && resolveSeatAgent('main') === 'main', 'resolveSeatAgent: accepts a bare string id too')
ok(resolveSeatAgent(null) === '' && resolveSeatAgent(undefined) === '', 'resolveSeatAgent: null-safe')
ok(SEAT_AGENT_ALIAS.theo === 'marketing' && SEAT_AGENT_ALIAS.lilbro === 'creative', 'SEAT_AGENT_ALIAS maps the known persona seats')
// Explicit `agent` remains available for organization-supplied genesis/ad-hoc seats; built-ins
// intentionally omit it because OSS defaults are role archetypes, not one org's registry mapping.
ok(resolveSeatAgent({ id: 'brand' }) === 'brand', 'role-archetype seat resolves to its matching registry role')

// ============================================================================
// ---- CNCL-11: governance surface — classification, recusal math, threshold
//      matrix, constitutional auto-class, hash-chained lineage tamper-evidence.
// ============================================================================

// --- constitutional AUTO-CLASSIFICATION (a caller can't downgrade a rule change) ---
ok(classifyMotion({ kind: 'promote', subject: 'x' }) === 'promote', 'classify: promote')
ok(classifyMotion({ kind: 'demote', subject: 'x' }) === 'demote', 'classify: demote')
ok(classifyMotion({ kind: 'expel', subject: 'x' }) === 'expel', 'classify: expel')
ok(classifyMotion({ kind: 'ordinary', question: 'ship?' }) === 'ordinary', 'classify: plain motion is ordinary')
ok(classifyMotion({ param: 'threshold', to: '2/3' }) === 'constitutional', 'classify: touching threshold -> constitutional')
ok(classifyMotion({ param: 'quorum' }) === 'constitutional', 'classify: touching quorum -> constitutional')
ok(classifyMotion({ param: 'veto' }) === 'constitutional', 'classify: touching veto -> constitutional')
// the key guarantee: a rule change mislabelled as ordinary is STILL forced constitutional in code
ok(classifyMotion({ kind: 'ordinary', param: 'threshold', to: '1' }) === 'constitutional', 'classify: mislabelled rule change is FORCED constitutional (cannot sneak the low bar)')
ok(classifyMotion({ changes: { mode: 'quick' } }) === 'constitutional', 'classify: changing a mode -> constitutional')
ok(CONSTITUTIONAL_PARAMS.includes('threshold') && CONSTITUTIONAL_PARAMS.includes('veto'), 'classify: param set covers threshold+veto')

// --- RECUSAL: the subject of a membership motion does not vote ---
ok(JSON.stringify(recusalFor({ kind: 'demote', subject: 'codex' })) === '["codex"]', 'recusal: demote subject recuses')
ok(recusalFor({ kind: 'constitutional', param: 'threshold' }).length === 0, 'recusal: non-membership motion recuses no one')

// --- THRESHOLD MATRIX over a 5-seat roster (per THRESHOLD_POLICY, nothing hardcoded) ---
// ordinary + promote = simple majority of 5 => 3 approve
ok(tallyVotes([V('a','approve'),V('b','approve'),V('c','approve'),V('d','reject'),V('e','reject')], { decisionClass: 'ordinary', seatCount: 5 }).recommendation === 'approve', 'matrix: ordinary 3/5 approve -> pass (majority)')
ok(tallyVotes([V('a','approve'),V('b','approve'),V('c','reject'),V('d','reject'),V('e','reject')], { decisionClass: 'promote', seatCount: 5 }).recommendation === 'reject', 'matrix: promote 2/5 -> reject (majority bar)')
// demote/expel = 2/3 of 5 => ceil(3.33)=4 approve
const dem3 = tallyVotes([V('a','approve'),V('b','approve'),V('c','approve'),V('d','reject'),V('e','reject')], { decisionClass: 'demote', seatCount: 5 })
ok(dem3.threshold === 4 && dem3.recommendation === 'reject', 'matrix: demote needs 2/3 (4 of 5) — 3 approve FAILS')
ok(tallyVotes([V('a','approve'),V('b','approve'),V('c','approve'),V('d','approve'),V('e','reject')], { decisionClass: 'demote', seatCount: 5 }).recommendation === 'approve', 'matrix: demote 4/5 -> pass (2/3 met)')
// constitutional = 2/3 + FULL quorum: all 5 must vote AND 4 approve
const cAbsent = tallyVotes([V('a','approve'),V('b','approve'),V('c','approve'),V('d','approve')], { decisionClass: 'constitutional', seatCount: 5 })
ok(cAbsent.quorum === 5 && cAbsent.recommendation === 'escalate', 'matrix: constitutional inquorate (4/5 present) -> escalate (full quorum required)')
ok(tallyVotes([V('a','approve'),V('b','approve'),V('c','approve'),V('d','approve'),V('e','reject')], { decisionClass: 'constitutional', seatCount: 5 }).recommendation === 'approve', 'matrix: constitutional 4/5 approve + full quorum -> pass')

// --- RECUSAL MATH: demote a 5-seat roster; subject recuses -> vote runs over the 4 remaining ---
// 4 voting seats, 2/3 of 4 = ceil(2.67)=3 approve needed; subject's own (would-be) vote is ignored.
const rec5 = tallyVotes(
  [V('a','approve'),V('b','approve'),V('c','approve'),V('d','reject'),V('subject','approve')],
  { decisionClass: 'demote', seatCount: 5, recuse: ['subject'] })
ok(rec5.seatCount === 4 && rec5.recused[0] === 'subject', 'recusal math: subject dropped from the base (5 -> 4 seats)')
ok(rec5.threshold === 3 && rec5.tally.approve === 3 && rec5.recommendation === 'approve', 'recusal math: 3/4 approve meets 2/3 (recused vote NOT counted)')
// constitutional auto-class flows THROUGH tallyVotes via opts.motion (not a trusted class string)
const cAuto = tallyVotes([V('a','approve'),V('b','approve'),V('c','approve'),V('d','approve')], { motion: { kind: 'ordinary', param: 'threshold', to: '1' }, seatCount: 5 })
ok(cAuto.decisionClass === 'constitutional' && cAuto.recommendation === 'escalate', 'auto-class: mislabelled rule change tallies under the CONSTITUTIONAL bar (full quorum) -> escalate on 4/5')

// --- HASH-CHAINED LINEAGE: build a motion record chained onto genesis; detect tamper ---
const mrec = buildMotionRecord({
  motion: { kind: 'demote', subject: 'codex' },
  verdict: { recommendation: 'approve', tally: T(4,1,0), recused: ['codex'] },
  seats: [{ id: 'main', chair: true }, { id: 'theo' }, { id: 'olivia' }, { id: 'lilbro' }],
  threshold: { rule: 'fraction', value: 2/3 }, veto: { principal: 'human:main', resolved: '433634012' },
  prevDigest: 'GENESISDIGEST', stampedAt: '2026-07-19T12:00:00Z', seq: 1, receiptDigest: 'RCPT1',
})
ok(mrec.kind === 'motion' && mrec.motion.class === 'demote' && mrec.prevDigest === 'GENESISDIGEST', 'motion record: chained onto the prior lineage head')
const mcanon = canonicalMotion(mrec)
ok(mcanon.includes('prevDigest: GENESISDIGEST') && mcanon.includes('outcome: approve') && mcanon.includes('class: demote'), 'canonicalMotion: prevDigest + outcome + class inside the signed bytes')
ok(canonicalMotion(mrec) === mcanon, 'canonicalMotion: deterministic (byte-reproducible)')
try { buildMotionRecord({ motion: { kind: 'ordinary' }, seats: [{ id: 'a' }] }); ok(false, 'motion record: refuses a non-governance motion') }
catch { ok(true, 'motion record: refuses a non-governance motion (fail-closed)') }

// A well-formed chain: genesis (prevDigest '') -> motion1 -> motion2, each prevDigest = prior digest.
const chain = [
  chainEntryOf({ seq: 0, prevDigest: '' }, 'D0'),
  chainEntryOf({ seq: 1, prevDigest: 'D0' }, 'D1'),
  chainEntryOf({ seq: 2, prevDigest: 'D1' }, 'D2'),
]
ok(verifyLineageChain(chain).ok === true && verifyLineageChain(chain).head === 'D2', 'chain: intact lineage verifies (head = last digest)')
// EDITED record: re-sealing record 1 changes its digest D1->D1x; record 2 still points at D1 -> break.
const edited = [chain[0], chainEntryOf({ seq: 1, prevDigest: 'D0' }, 'D1x'), chain[2]]
ok(verifyLineageChain(edited).ok === false && verifyLineageChain(edited).index === 2, 'chain: an EDITED receipt breaks the next link (tamper detected)')
// DROPPED record: remove motion1 -> motion2.prevDigest 'D1' != genesis digest 'D0'.
ok(verifyLineageChain([chain[0], chain[2]]).ok === false, 'chain: a DROPPED receipt breaks the chain')
// REORDERED: swap motion1 and motion2 -> prevDigest mismatch + non-monotonic seq.
ok(verifyLineageChain([chain[0], chain[2], chain[1]]).ok === false, 'chain: a REORDERED receipt breaks the chain')
// Root must be a genesis: a lineage whose first record carries a prevDigest is rejected.
ok(verifyLineageChain([chainEntryOf({ seq: 0, prevDigest: 'X' }, 'D0')]).ok === false, 'chain: first record must be the genesis root (empty prevDigest)')
ok(verifyLineageChain([]).ok === false, 'chain: empty lineage fails closed')

// ---- CNCL-15: constitution amendments — digest sealing + drift check --------------------------
// The v0 render round-trips back to the built-in defaults (its sealed digest is a meaningful baseline).
const v0 = renderConstitutionV0()
ok(typeof v0 === 'string' && v0.startsWith('---\n'), 'CNCL-15: renderConstitutionV0 emits a frontmatter doc')
let v0norm
try { v0norm = normalizeConstitution(parseConstitutionFrontmatter(v0)) } catch (e) { v0norm = { err: String(e && e.message) } }
ok(v0norm && v0norm.council && v0norm.council.bench === 'council' && v0norm.veto.holdSecs === 900, 'CNCL-15: the v0 constitution parses+normalizes to the defaults')
ok(digestConstitution('a') === digestConstitution('a') && digestConstitution('a') !== digestConstitution('b'), 'CNCL-15: digestConstitution is deterministic + content-sensitive')
// drift check: no sealed digest = nothing to enforce; sealed+match = clean; sealed+missing/mismatch = drift (fail closed).
ok(constitutionDriftCheck({ sealedDigest: '', liveDigest: 'x' }).drifted === false, 'CNCL-15: no sealed digest → not drifted (pre-CNCL-15 lineage)')
ok(constitutionDriftCheck({ sealedDigest: 'abc', liveDigest: 'abc' }).drifted === false, 'CNCL-15: matching live+sealed digest → not drifted')
ok(constitutionDriftCheck({ sealedDigest: 'abc', liveDigest: '' }).drifted === true, 'CNCL-15: sealed digest but missing file → drift (fail-closed)')
ok(constitutionDriftCheck({ sealedDigest: 'abc', liveDigest: 'abd' }).drifted === true, 'CNCL-15: edited file (digest mismatch) → drift (fail-closed)')
// genesis seals the digest into the canonical bytes ONLY when present (back-compat: absent → old bytes).
const gWith = buildGenesisRecord({ seats: [{ id: 'a' }], veto: { principal: 'human:main', resolved: '1' }, constitutionDigest: 'DEAD' })
const gNo = buildGenesisRecord({ seats: [{ id: 'a' }], veto: { principal: 'human:main', resolved: '1' } })
ok(gWith.constitutionDigest === 'DEAD' && canonicalGenesis(gWith).includes('constitution: DEAD'), 'CNCL-15: genesis seals the constitution digest into its canonical bytes')
ok(gNo.constitutionDigest === '' && !canonicalGenesis(gNo).includes('constitution:'), 'CNCL-15: a genesis with no digest canonicalizes as before (back-compat)')
// an amend motion record must carry a digest (fail closed) + seals it into the motion bytes.
const okVerdict = { recommendation: 'approve', tally: { approve: 2, reject: 0, escalate: 0 }, escalated: false }
let amendThrew = false
try { buildMotionRecord({ motion: { kind: 'amend' }, verdict: okVerdict, seats: [{ id: 'a' }] }) } catch { amendThrew = true }
ok(amendThrew === true, 'CNCL-15: an amend motion with no constitution digest is refused (fail-closed)')
const amendRec = buildMotionRecord({ motion: { kind: 'amend' }, verdict: okVerdict, seats: [{ id: 'a' }], constitutionDigest: 'BEEF' })
ok(classifyMotion({ kind: 'amend' }) === 'constitutional', 'CNCL-15: an amend motion classifies constitutional (hardest bar)')
ok(amendRec.constitutionDigest === 'BEEF' && canonicalMotion(amendRec).includes('constitution: BEEF'), 'CNCL-15: an amend motion seals the new digest into its canonical bytes')

console.log(`\nCNCL-6/11/15 engine: ${pass} passed, ${fail} failed (bound to src/council/engine.mjs)`)
process.exit(fail ? 1 : 0)
