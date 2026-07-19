// CNCL-6 engine unit + contract test — offline, mock model (no live COUNCIL_API_KEY).
// Binds directly to the shipped engine (src/council/engine.mjs), so the ported P1/P2
// verdict->action maps + escalate-only guardrail + P3 receipt keep their contract, and
// the new CNCL-6 behavior (threshold tally, unbounded self-governed roster, founder veto,
// A-with-seam adapter) is proven. Exit 0 == green.
import {
  guardrail, gateGuardrail, nodeGuardrail, verdictToAction, verifierVerdictToAction,
  nodeVerdictToDecision, resolveCouncil, STANDING_COUNCILS, DEFAULT_COUNCIL, DEFAULT_THRESHOLD,
  resolveThreshold, tallyVotes, applyFounderVeto, dispositionOf, addSeat, removeSeat,
  THRESHOLD_POLICY, quorumSize,
  canonicalTranscript, validateAgainstSchema, makeAnthropicModelCall, runCouncil, TAKE, VOTE, NODE_VOTE,
} from '../src/council/engine.mjs'

let pass = 0, fail = 0
const ok = (c, m) => { c ? pass++ : (fail++, console.error('FAIL:', m)) }
const T = (a, r, e) => ({ approve: a, reject: r, escalate: e })

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
ok(DEFAULT_COUNCIL.seats.map(s => s.id).join(',') === 'main,theo,codex,olivia,lilbro', 'starting roster = the 5 named seats')
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

// ---- CNCL-6: founder veto (pass -> blocked, recorded) ----
const passV = { recommendation: 'approve', escalated: false, tally: T(4, 1, 0), confidence: 0.9, dissent: 'none', brief: '' }
const vetoed = applyFounderVeto(passV, { by: 'lodar', reason: 'not this sprint' })
ok(vetoed.vetoed === true && vetoed.vetoedBy === 'lodar' && vetoed.disposition === 'blocked', 'founder veto flips a pass to blocked')
ok(dispositionOf(vetoed) === 'blocked', 'dispositionOf(vetoed) = blocked')
ok(dispositionOf(passV) === 'pass', 'un-vetoed pass = pass')
const rejV = { recommendation: 'reject', escalated: false, tally: T(1, 4, 0), confidence: 0.8, dissent: 'x', brief: '' }
ok(applyFounderVeto(rejV, { by: 'lodar' }).vetoed !== true, 'veto on a non-pass is a no-op (nothing to veto)')

// ---- P3 receipt: deterministic, tamper-evident, veto INSIDE signed bytes ----
const rec = { council: 'council', mode: 'deliberate', stampedAt: '2026-07-19T00:00:00Z', question: 'ship v0.11?',
  seats: ['main', 'theo', 'codex'], votes: [{ seat: 'theo', vote: 'approve', rationale: 'lgtm' }, { seat: 'main', vote: 'approve', rationale: 'ok' }],
  verdict: { recommendation: 'approve', tally: T(2, 0, 0), confidence: 0.9, dissent: 'none', escalated: false } }
const c1 = canonicalTranscript(rec)
ok(c1 === canonicalTranscript({ ...rec, seats: ['theo', 'codex', 'main'] }), 'canonical is order-independent (stable bytes)')
ok(c1 !== canonicalTranscript({ ...rec, question: 'ship v0.12?' }), 'any field edit changes the bytes (tamper-evident)')
const cVeto = canonicalTranscript({ ...rec, verdict: { ...rec.verdict, vetoed: true, vetoedBy: 'lodar', vetoReason: 'hold' } })
ok(cVeto.includes('veto: lodar :: hold') && cVeto !== c1, 'recorded veto is INSIDE the signed bytes')

// ---- A-with-seam adapter: schema-validate + no live key needed to construct ----
ok(validateAgainstSchema({ seat: 'a', vote: 'approve', rationale: 'x' }, VOTE) === null, 'valid VOTE passes schema check')
ok(validateAgainstSchema({ seat: 'a', vote: 'bogus', rationale: 'x' }, VOTE) !== null, 'bad enum caught by schema check')
ok(typeof makeAnthropicModelCall({ apiKey: 'x' }) === 'function', 'adapter constructs (seam) without a network call')

// ---- full runCouncil integration with a MOCK model (no key, deterministic) ----
function mockModel(votesById) {
  return async (prompt, schema) => {
    if (schema === TAKE) { const id = (prompt.match(/"(\w+)" seat/) || [])[1] || 'x'; return { seat: id, position: 'take', keyRisk: 'risk' } }
    if (schema === VOTE) { const id = (prompt.match(/"(\w+)" seat/) || [])[1] || 'x'; return { seat: id, vote: votesById[id] || 'approve', rationale: 'r' } }
    if (schema === NODE_VOTE) { const id = (prompt.match(/"(\w+)" seat/) || [])[1] || 'x'; return { seat: id, choice: 'hetzner', rationale: 'r' } }
    // NARRATIVE / VERDICT / NODE_VERDICT
    if (schema.required && schema.required.includes('choice')) return { choice: 'hetzner', tally: T(3, 0, 0), confidence: 0.8, dissent: 'none', escalated: false, brief: '' }
    if (schema.required && schema.required.includes('recommendation')) return { recommendation: 'approve', tally: T(3, 0, 0), confidence: 0.8, dissent: 'none', escalated: false, brief: '' }
    return { confidence: 0.8, dissent: 'none', brief: '' } // NARRATIVE
  }
}
// default council, 4 approve / 1 reject -> PASS (>=3), receipt built
const r1 = await runCouncil({ role: 'convene', question: 'ship v0.11?', councilName: 'council' },
  { modelCall: mockModel({ main: 'approve', theo: 'approve', codex: 'approve', olivia: 'approve', lilbro: 'reject' }) })
ok(r1.verdict.recommendation === 'approve' && r1.verdict.tally.approve === 4, 'runCouncil: 4/5 approve -> PASS via deterministic tally')
ok(r1.receipt && r1.receipt.canonical.includes('council: council') && r1.receipt.seal.includes('gate-proof sign'), 'runCouncil: receipt built with seal command')
// 2 approve -> reject
const r2 = await runCouncil({ role: 'convene', question: 'ship?' },
  { modelCall: mockModel({ main: 'approve', theo: 'approve', codex: 'reject', olivia: 'reject', lilbro: 'reject' }) })
ok(r2.verdict.recommendation === 'reject', 'runCouncil: 2/5 approve -> reject')
// founder veto threads through runCouncil
const r3 = await runCouncil({ role: 'convene', question: 'ship?', veto: { by: 'lodar', reason: 'hold' } },
  { modelCall: mockModel({ main: 'approve', theo: 'approve', codex: 'approve', olivia: 'approve', lilbro: 'approve' }) })
ok(r3.verdict.vetoed === true && r3.receipt.canonical.includes('veto: lodar :: hold'), 'runCouncil: founder veto flips pass to blocked + rides the receipt')
// hard-gate guardrail short-circuits (verifier role, tier-2) with NO model spend
let calls = 0
const r4 = await runCouncil({ role: 'verifier', task: { ident: 'DIVE-9', ask: 'x', accept: 'y', type: 'decision', tier: 2 } },
  { modelCall: async () => { calls++; return {} } })
ok(r4.verdict.escalated === true && r4.convened === false && calls === 0, 'runCouncil: tier-2 guardrail escalates with zero model calls')

console.log(`\nCNCL-6 engine: ${pass} passed, ${fail} failed (bound to src/council/engine.mjs)`)
process.exit(fail ? 1 : 0)
