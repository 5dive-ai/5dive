// The Council — standalone deliberation engine (CNCL-6, v0.11).
//
// Reimplements the four tested Workflow-harness prototypes (council/council-*.js:
// P0 convene, P1 gate-clear, P2 loop-verifier + goal-DAG node, P3 standing benches
// + tamper-evident receipt) as a standalone node module callable from any shell via
// the `5dive council` CLI. Seats call the model API DIRECTLY through the injectable
// `modelCall` adapter (A-with-seam: Anthropic Messages shape by default, {baseUrl,
// model,apiKey} behind config so a BYO/OpenRouter key drops in later with no engine
// rework). No Workflow harness, no `agent()` global.
//
// The PURE LOGIC region below (verdict->action maps + escalate-only guardrail +
// standing registry + receipt canonicalization) is ported VERBATIM from the
// prototypes and sliced by the bound contract test (no drift). The one behavioural
// invariant: a council NEVER self-clears a hard-gate class (tier>=2 or a human-only
// type) — it escalates, fail-closed on a missing tier.

import { createHash, generateKeyPairSync, sign as edSign, verify as edVerify, createPrivateKey, createPublicKey } from 'node:crypto'

// ==================== PURE LOGIC (the ported contract — auditable, offline-testable) ====================
export const HUMAN_ONLY_TYPES = ['secret', 'approval', 'manual', 'access']

// Escalate-only guardrail, shared by the gate (P1), verifier + node (P2) roles.
// tier>=2 or a human-only type is never council-decidable; a missing tier fails closed.
export function guardrail(x) {
  const tier = Number(x.tier == null ? 2 : x.tier)
  if (tier >= 2) return { forceEscalate: true, reason: `tier-${tier} hard human gate (councils escalate, never self-clear tier>=2)` }
  if (HUMAN_ONLY_TYPES.includes(x.type)) return { forceEscalate: true, reason: `type=${x.type} is human-only (money/secret/manual/access) — escalate` }
  return { forceEscalate: false, reason: '' }
}
export const gateGuardrail = guardrail   // P1 name
export const nodeGuardrail = guardrail   // P2 name

export function shellQuote(s) { return `'${String(s).replace(/'/g, `'\\''`)}'` }
export function tallyStr(t) { return `a${t.approve}/r${t.reject}/e${t.escalate}` }

// (P1) GATE-CLEAR: council verdict -> clear the gate (task answer) | bump to a human
// (task need --tier=2 + task escalate) WITH the one-paragraph brief. Never self-clears.
export function verdictToAction(gate, verdict) {
  if (verdict && verdict.recommendation === 'approve' && !verdict.escalated) {
    const value = gate.recommend && gate.recommend !== '-' ? gate.recommend : 'approve'
    return {
      action: 'clear',
      command: `5dive task answer ${gate.ident} --value=${shellQuote(`[council] ${value} (rec=${verdict.recommendation}, tally ${tallyStr(verdict.tally)}, conf ${verdict.confidence})`)}`,
      value,
    }
  }
  const brief = (verdict && (verdict.brief || verdict.dissent)) || 'Council could not clear; human decision required.'
  // PRESERVE the original gate type on re-file. Never coerce a human-only type (secret/approval/
  // manual/access) down to a free-text `decision` — that would re-open a `secret` gate (whose ask
  // may say "do NOT paste here") as a plain decision and invite the human to paste the secret onto
  // the fleet-readable board. A human-only escalation stays human-only (CNCL-12 main-gate amendment).
  const t = gate.type || 'decision'
  return {
    action: 'escalate',
    command: `5dive task need ${gate.ident} --type=${t} --tier=2 --ask=${shellQuote(`[council escalation] ${brief} — original ask: ${gate.ask}`)}`
      + (gate.recommend && gate.recommend !== '-' ? ` --recommend=${shellQuote(gate.recommend)}` : '')
      + (gate.options ? ` --options=${shellQuote(gate.options)}` : '')
      + ` && 5dive task escalate ${gate.ident} --from=council`,
    brief,
  }
}

// (P2a) LOOP VERIFIER: approve -> task done | reject -> task reject --feedback (stays
// in the loop, no human) | escalate -> task need --tier=2 + task escalate.
export function verifierVerdictToAction(task, verdict) {
  const conf = verdict.confidence, tly = tallyStr(verdict.tally)
  if (verdict.recommendation === 'approve' && !verdict.escalated) {
    return {
      action: 'accept',
      command: `5dive task done ${task.ident} --result=${shellQuote(`[council verifier] PASS (tally ${tly}, conf ${conf})`)}`,
    }
  }
  if (verdict.recommendation === 'reject' && !verdict.escalated) {
    const critique = verdict.dissent && verdict.dissent !== 'none' ? verdict.dissent : (verdict.brief || 'Did not meet the acceptance criteria.')
    return {
      action: 'reject',
      command: `5dive task reject ${task.ident} --feedback=${shellQuote(`[council verifier] FAIL (tally ${tly}). ${critique}`)}`,
    }
  }
  const brief = (verdict.brief || verdict.dissent) || 'Council could not grade; human decision required.'
  const t = task.type && HUMAN_ONLY_TYPES.indexOf(task.type) === -1 ? task.type : 'decision'
  return {
    action: 'escalate',
    command: `5dive task need ${task.ident} --type=${t} --tier=2 --ask=${shellQuote(`[council verifier escalation] ${brief} — original: ${task.ask}`)}`
      + ` && 5dive task escalate ${task.ident} --from=council`,
    brief,
  }
}

// (P2b) GOAL-DAG DECISION NODE: valid winning branch -> task answer --value | else escalate.
export function nodeVerdictToDecision(node, verdict) {
  const opts = (node.options || '').split('|').map(o => o.trim()).filter(Boolean)
  const choice = verdict.choice
  const validChoice = choice && opts.length > 0 && opts.indexOf(choice) !== -1
  if (!verdict.escalated && validChoice) {
    return {
      action: 'decide',
      choice,
      command: `5dive task answer ${node.ident} --value=${shellQuote(`[council] ${choice} (conf ${verdict.confidence}, tally ${tallyStr(verdict.tally)})`)}`,
    }
  }
  const brief = (verdict.brief || verdict.dissent) || 'Council could not pick a branch; human decision required.'
  return {
    action: 'escalate',
    command: `5dive task need ${node.ident} --type=decision --tier=2 --ask=${shellQuote(`[council node escalation] ${brief} — decision: ${node.question}`)}`
      + (node.options ? ` --options=${shellQuote(node.options)}` : '')
      + ` && 5dive task escalate ${node.ident} --from=council`,
    brief,
  }
}

// (CNCL-12) T2 ROT-TRIAGE: a tier-2 gate left unanswered 48h. The council re-briefs it
// sharper (or, in its brief, recommends a rescope/park to the human) and re-escalates —
// but it NEVER clears a tier-2 gate. This is the fail-closed rule: tier-2 stays human-only,
// so this mapping has NO `task answer` branch AT ALL, not even for an `approve` verdict.
// The load-bearing invariant (asserted in the unit test): `.cleared === false` and the
// command never contains `task answer`, regardless of what the verdict says.
export function triageVerdictToAction(gate, verdict) {
  const brief = (verdict && (verdict.brief || verdict.dissent))
    || 'Council reviewed the stale gate; the human decision still stands and needs an answer.'
  // Keep the gate human-only: re-file the SAME type, ALWAYS tier-2, with a sharper one-paragraph
  // brief, then re-ping the owner. Never downgrades tier, never answers, and (CNCL-12 main-gate
  // amendment) never downgrades a human-only type to `decision` — a stale `secret` gate must be
  // re-briefed as type=secret, not re-opened as a free-text decision that invites a paste.
  const t = gate.type || 'decision'
  return {
    action: 'triage-rebrief',
    cleared: false,
    command: `5dive task need ${gate.ident} --type=${t} --tier=2 --ask=${shellQuote(`[council triage] ${brief} — original ask: ${gate.ask}`)}`
      + (gate.recommend && gate.recommend !== '-' ? ` --recommend=${shellQuote(gate.recommend)}` : '')
      + (gate.options ? ` --options=${shellQuote(gate.options)}` : '')
      + ` && 5dive task escalate ${gate.ident} --from=council-triage`,
    brief,
  }
}

// (P3.1) STANDING / NAMED COUNCILS — the built-in defaults. The CLI layer persists an
// editable copy (benches.json) seeded from these; resolveCouncil fails CLOSED on a miss.
export const STANDING_COUNCILS = {
  ship: {
    description: 'Ship-worthiness of a build/diff before it goes live.',
    mode: 'deliberate',
    seats: [
      { id: 'reviewer', lens: 'Review, correctness, ship-worthiness. Reversible? Tested? Any regression?' },
      { id: 'security', lens: 'Injection, blast radius, secrets, auth boundaries.' },
      { id: 'cost', lens: 'Token + infra spend, capacity/egress, provider concentration.' },
    ],
  },
  brand: {
    description: 'Customer-facing / brand + messaging call on a mature surface.',
    mode: 'deliberate',
    seats: [
      { id: 'brand', lens: 'Brand + customer read; how it lands, support load.' },
      { id: 'operator', lens: 'Operational soundness + ship-worthiness.' },
      { id: 'contrarian', lens: 'Divergent/contrarian; the take everyone is too polite to say.' },
    ],
  },
  security: {
    description: 'Security-sensitive change (auth, sudo, gate/tamper rails, MCP).',
    mode: 'adversarial',
    seats: [
      { id: 'security', lens: 'Injection, privilege, blast radius, forgeability.' },
      { id: 'red-team', lens: 'Actively try to REFUTE the leading option / find the bypass.' },
      { id: 'reviewer', lens: 'Correctness + reversibility of the change.' },
    ],
  },
}

// Fails CLOSED: an unknown bench name is NOT silently defaulted. Pass a registry map to
// resolve against a persisted copy; defaults to the built-ins. Returns null on a miss.
export function resolveCouncil(name, registry = STANDING_COUNCILS) {
  if (!name) return null
  const c = registry[name]
  if (!c) return null
  return { name, description: c.description, mode: c.mode, seats: c.seats }
}

// (P3.1b) THE default Council: a self-governed standing body of role-archetype
// voting seats, one vote each. Seat count is UNBOUNDED and the roster is MUTABLE — the
// council promotes/demotes seats by a quorum vote (addSeat/removeSeat, gated at the CLI
// layer by a real convene). These 5 are the STARTING membership, NOT a cap or a fixed
// roster. `threshold` is a CONFIG value (see resolveThreshold) — nothing hardcodes 5 or 3.
export const DEFAULT_COUNCIL = {
  name: 'council', description: 'The 5dive Council — self-governed standing body, one vote each. Seats mutable by quorum vote.',
  mode: 'deliberate', threshold: 3, thresholdRule: 'flat',
  seats: [
    { id: 'eng-lead', lens: 'Engineering lead. Correctness, ship-worthiness, reversibility.' },
    { id: 'brand', lens: 'Brand + customer read; how it lands publicly.' },
    { id: 'builder', lens: 'Implementation soundness, edge cases, blast radius.' },
    { id: 'strategy', lens: 'Strategic fit, organizational priorities, risk appetite.' },
    { id: 'contrarian', lens: 'Divergent view; the objection everyone is too polite to raise.' },
  ],
}

// (CNCL-16) SEAT ID vs REGISTRY AGENT. A seat `id` is a PERSONA (display + receipts). The agent
// that `5dive agent ask` dispatches to is a REGISTRY NAME, which is not always the same string:
// persona 'theo' is the 'marketing' agent, 'lilbro' is 'creative'. A seat MAY carry an explicit
// `agent` (canonical, wins); otherwise this alias map resolves the known personas; otherwise the
// id IS the registry name. Genesis/ad-hoc rosters that seed a bare persona id resolve via the map.
export const SEAT_AGENT_ALIAS = { theo: 'marketing', lilbro: 'creative' }
export function resolveSeatAgent(seat) {
  if (!seat) return ''
  if (typeof seat === 'string') return SEAT_AGENT_ALIAS[seat] || seat
  if (seat.agent && typeof seat.agent === 'string') return seat.agent
  return SEAT_AGENT_ALIAS[seat.id] || seat.id
}
export const DEFAULT_THRESHOLD = 3   // default flat pass-threshold; overridable per bench

// (P3.1b2) TIERED THRESHOLD POLICY (lodar is steering toward this). Per decision-CLASS pass
// rule + quorum, ALL config so the final numbers drop in once locked. A rule is 'flat' (fixed
// N), 'majority' (floor(seats/2)+1), or 'fraction' (ceil(value*seats), e.g. 2/3). `quorum`
// = how many of the CURRENT seats must actually vote for the result to count ('majority' by
// default, a number, or 'none'). Nothing hardcodes 5 or 3 — this map is the single knob.
export const THRESHOLD_POLICY = {
  ordinary:       { rule: 'majority',            quorum: 'majority' },
  promote:        { rule: 'majority',            quorum: 'majority' },
  demote:         { rule: 'fraction', value: 2 / 3, quorum: 'majority' },
  expel:          { rule: 'fraction', value: 2 / 3, quorum: 'majority' },
  constitutional: { rule: 'fraction', value: 2 / 3, quorum: 'all', requireQuorum: true },
}

// Resolve the numeric pass-threshold for a roster from a spec. 'flat' (fixed N, clamped to
// the roster), 'majority' (floor/2+1), 'fraction' (ceil(value*seats)). Never hardcoded.
export function resolveThreshold(seatCount, spec = {}) {
  const n = Number(seatCount) || 0
  const rule = spec.rule || spec.thresholdRule || (spec.threshold != null ? 'flat' : 'majority')
  if (rule === 'fraction') return Math.max(1, Math.ceil(Number(spec.value) * n))
  if (rule === 'flat') { const t = Number(spec.threshold == null ? DEFAULT_THRESHOLD : spec.threshold); return Math.max(1, n ? Math.min(t, n) : t) }
  return Math.floor(n / 2) + 1   // majority / quorum
}

// How many of the current seats must actually vote for a result to count (the quorum GATE).
export function quorumSize(seatCount, spec = {}) {
  const n = Number(seatCount) || 0
  const q = spec.quorum
  if (typeof q === 'number') return q
  if (q === 'none') return 0
  if (q === 'all') return n   // full quorum: every current seat must vote (constitutional)
  return Math.floor(n / 2) + 1   // default: majority participation
}

// (P3.1c) DETERMINISTIC tally -> verdict. Enforces the QUORUM gate first (an inquorate vote
// can't decide -> escalate), then passes iff approve-count reaches the class threshold. Not a
// pass is a reject, unless escalate is the plurality (a genuine "needs a human" split). The
// chair LLM only narrates — the PASS/FAIL is an auditable count over the current roster.
// opts: { decisionClass, policy, seatCount, threshold, thresholdRule } — explicit
// threshold/thresholdRule override the class policy (for ad-hoc convenes/tests).
export function tallyVotes(votes, opts = {}) {
  const tally = { approve: 0, reject: 0, escalate: 0 }
  for (const v of votes || []) { if (tally[v.vote] != null) tally[v.vote]++ }
  const seatCount = opts.seatCount || (votes || []).length
  const cls = opts.decisionClass || 'ordinary'
  const policy = (opts.policy || THRESHOLD_POLICY)[cls] || THRESHOLD_POLICY.ordinary
  const spec = { ...policy }
  if (opts.threshold != null) { spec.rule = 'flat'; spec.threshold = opts.threshold }
  if (opts.thresholdRule) spec.rule = opts.thresholdRule
  const votesCast = tally.approve + tally.reject + tally.escalate
  const quorum = quorumSize(seatCount, spec)
  const quorumMet = votesCast >= quorum
  const threshold = resolveThreshold(seatCount, spec)
  let recommendation
  if (!quorumMet) recommendation = 'escalate'                       // inquorate -> can't decide, surface
  else if (tally.approve >= threshold) recommendation = 'approve'
  else if (tally.escalate > tally.approve && tally.escalate >= tally.reject) recommendation = 'escalate'
  else recommendation = 'reject'
  return { recommendation, tally, threshold, seatCount, quorum, quorumMet, votesCast, decisionClass: cls, escalated: recommendation === 'escalate' }
}

// (P3.1e) SELF-GOVERNANCE — pure roster mutations. The CLI gates each behind a real council
// quorum vote (a convene that must pass); these just produce the new, de-duplicated roster.
export function addSeat(seats, seat) {
  const s = typeof seat === 'string' ? { id: seat } : seat
  if (!s || !s.id) throw new Error('addSeat: seat needs an id')
  if ((seats || []).some(x => x.id === s.id)) return seats.slice()   // already seated (idempotent)
  return [...(seats || []), { id: s.id, lens: s.lens || `${s.id} — council seat.` }]
}
export function removeSeat(seats, seatId) {
  return (seats || []).filter(x => x.id !== seatId)
}

// (CNCL-9) AUTHENTICATED FOUNDER VETO — non-blocking OFFER model.
//
// The pre-CNCL-9 design flipped the verdict inline from a plain `--veto-by` CLI STRING, so any
// agent could forge lodar's veto straight into a signed receipt. That path is gone. Now:
//
//   1. convene NEVER waits for a tap and NEVER flips on a string. On a pass it records a
//      timeboxed OFFER (attachVetoOffer) naming the resolved genesis principal + window, seals
//      immediately, and the work proceeds. Expiry with no tap = the pass stands, and the receipt
//      already reads `veto-offered-not-exercised` (default-proceed is the do-nothing path).
//   2. The EXERCISE is a separate, authenticated event: only a tap confirmed on the tier-2 rail
//      by the resolved principal (bash validates the nonce->recipient binding) calls
//      exerciseFounderVeto, which flips the pass to BLOCKED inside a fresh record that is
//      root-sealed and hash-chained onto the convene receipt (the original bytes are never
//      re-sealed — post-hoc-after-seal re-seal stays deferred; the chain carries the flip).
//   3. Veto is FINAL — no council override. Hard-gate classes escalate upstream regardless.

// Non-blocking: attach a timeboxed veto OFFER to a pass. Disposition stays `pass` (the work is
// not blocked); the offer rides inside the sealed bytes so "an offer was made" is auditable.
// A non-pass verdict is returned unchanged (nothing to offer a veto on).
export function attachVetoOffer(verdict, offer) {
  if (!offer || !offer.principal || !offer.resolved) return verdict
  const passed = verdict.recommendation === 'approve' && !verdict.escalated
  if (!passed) return verdict
  return {
    ...verdict,
    vetoOffer: {
      principal: String(offer.principal),
      resolved: String(offer.resolved),
      windowSecs: Number(offer.windowSecs) || 0,
      state: 'offered-not-exercised',
    },
  }
}

// Authenticated EXERCISE (the confirmed tap) — TWO-TIER (lodar-locked):
//   tier='hold'    — the tap landed inside the 15m pre-execution hold; the work never ran.
//   tier='posthoc' — the tap landed after execution (up to veto_posthoc/48h); the verdict is
//                    overruled and the (reversible) work must be UNWOUND (manual unwind in v0.11).
// `veto` MUST carry the principal the bash rail authenticated (veto.by) and the resolved recipient
// the offer was made to (veto.resolved); bash has already proven the tap came from that recipient
// over the tier-2 nonce rail — the engine never trusts a bare string. The flip only applies to a
// verdict that carried the matching offer; anything else is returned unchanged (fail-closed).
// This builds the FLIPPED verdict for a NEW record; the caller hash-chains it to the original
// verdict digest and root-seals it. The original convene receipt is never re-signed or mutated.
export function exerciseFounderVeto(verdict, veto) {
  if (!veto || !veto.by || !veto.resolved) return verdict
  const offer = verdict.vetoOffer
  if (!offer || String(offer.resolved) !== String(veto.resolved)) return verdict
  const passed = verdict.recommendation === 'approve' && !verdict.escalated
  if (!passed) return verdict
  const tier = veto.tier === 'posthoc' ? 'posthoc' : 'hold'
  const briefHead = tier === 'posthoc'
    ? `Post-hoc founder veto by ${veto.by}: pass (tally ${tallyStr(verdict.tally)}) overruled — reversible work must be unwound.`
    : `Founder veto by ${veto.by}: pass (tally ${tallyStr(verdict.tally)}) held and flipped to BLOCKED before execution.`
  return {
    ...verdict,
    disposition: 'blocked',
    vetoed: true,
    vetoedBy: veto.by,
    vetoReason: veto.reason || '',
    vetoTier: tier,
    unwindRequired: tier === 'posthoc',
    vetoOffer: { ...offer, state: 'exercised' },
    brief: `${briefHead}${veto.reason ? ` Reason: ${veto.reason}` : ''}`,
  }
}

// Veto window durations. lodar-locked defaults: 15m pre-execution HOLD, 48h POST-HOC override.
// These are the seam CNCL-13/14 redirects to the `5dive.md` constitution — until then they read
// from the environment (bash sources the constitution or falls back), NEVER inline magic numbers.
export const VETO_DEFAULTS = { holdSecs: 15 * 60, posthocSecs: 48 * 60 * 60 }
export function vetoConfig(env = {}) {
  const n = (v, d) => { const x = Number(v); return Number.isFinite(x) && x > 0 ? x : d }
  return {
    holdSecs: n(env.COUNCIL_VETO_HOLD_SECS, VETO_DEFAULTS.holdSecs),
    posthocSecs: n(env.COUNCIL_VETO_POSTHOC_SECS, VETO_DEFAULTS.posthocSecs),
  }
}

// Build the chained veto RECORD emitted by an authenticated exercise. It is a distinct object from
// the convene receipt: it references the original verdict digest (origDigest) so the whole history
// links back without ever re-signing the original bytes. The caller root-seals `canonical` and
// stores {digest, prevDigest: origDigest, ...} — same hash-chain discipline as the genesis lineage.
export function buildVetoRecord({ origDigest, tier, by, resolved, reason, stampedAt, flippedVerdict }) {
  if (!origDigest) throw new Error('veto record needs the original verdict digest to chain to')
  if (!by || !resolved) throw new Error('veto record needs an authenticated principal (by) + resolved recipient')
  const t = tier === 'posthoc' ? 'posthoc' : 'hold'
  return {
    kind: 'veto',
    tier: t,
    origDigest: String(origDigest),
    by: String(by),
    resolved: String(resolved),
    reason: reason || '',
    unwindRequired: t === 'posthoc',
    stampedAt: stampedAt || '',
    disposition: 'blocked',
    tally: (flippedVerdict && flippedVerdict.tally) || null,
  }
}

// Deterministic, whitespace-normalized preimage of a veto record — the origDigest link is INSIDE
// the signed bytes so the chain cannot be re-pointed, and the tier/unwind flag cannot be stripped.
export function canonicalVetoRecord(rec) {
  const norm = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim()
  const t = rec.tally || {}
  return [
    `kind: veto`,
    `tier: ${norm(rec.tier)}`,
    `origDigest: ${norm(rec.origDigest)}`,
    `by: ${norm(rec.by)}`,
    `resolved: ${norm(rec.resolved)}`,
    `reason: ${norm(rec.reason)}`,
    `unwindRequired: ${!!rec.unwindRequired}`,
    `stampedAt: ${norm(rec.stampedAt)}`,
    `disposition: blocked`,
    `tally: a${Number(t.approve) || 0}/r${Number(t.reject) || 0}/e${Number(t.escalate) || 0}`,
  ].join('\n')
}

// The plain-English disposition of a (possibly vetoed) verdict.
export function dispositionOf(verdict) {
  if (verdict.vetoed) return 'blocked'
  if (verdict.escalated || verdict.recommendation === 'escalate') return 'escalate'
  if (verdict.recommendation === 'approve') return 'pass'
  return 'reject'
}

// (P3.2) TAMPER-EVIDENT RECEIPT — deterministic, order-independent, whitespace-normalized
// canonicalization of the whole deliberation; the dissent is INSIDE the signed bytes so it
// can't be quietly dropped. No in-engine clock: caller supplies rec.stampedAt.
export function canonicalTranscript(rec) {
  const norm = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim()
  const L = []
  L.push(`council: ${norm(rec.council)}`)
  L.push(`mode: ${norm(rec.mode)}`)
  L.push(`stampedAt: ${norm(rec.stampedAt)}`)
  L.push(`question: ${norm(rec.question)}`)
  L.push(`seats: ${(rec.seats || []).map(norm).slice().sort().join(',')}`)
  const votes = (rec.votes || []).slice().sort((a, b) => (norm(a.seat) < norm(b.seat) ? -1 : 1))
  for (const v of votes) L.push(`vote ${norm(v.seat)}: ${norm(v.vote != null ? v.vote : v.choice)} :: ${norm(v.rationale)}`)
  // CNCL-7: in adversarial mode the FINAL votes above are ROUND 2. Seal the sorted round-1
  // history too so a between-round seat flip cannot be misrepresented without failing verify
  // (the deliberative record is the product, not only the final tally). round1Votes is set on
  // the rec ONLY when a rebuttal round occurred, so a single-round receipt stays byte-identical.
  if (Array.isArray(rec.round1Votes)) {
    const r1 = rec.round1Votes.slice().sort((a, b) => (norm(a.seat) < norm(b.seat) ? -1 : 1))
    for (const v of r1) L.push(`round1 ${norm(v.seat)}: ${norm(v.vote != null ? v.vote : v.choice)} :: ${norm(v.rationale)}`)
  }
  const vd = rec.verdict || {}
  const t = vd.tally || {}
  L.push(`verdict: ${norm(vd.recommendation != null ? vd.recommendation : vd.choice)} conf=${Number(vd.confidence)} tally=a${Number(t.approve) || 0}/r${Number(t.reject) || 0}/e${Number(t.escalate) || 0} escalated=${!!vd.escalated}`)
  L.push(`dissent: ${norm(vd.dissent)}`)
  // CNCL-9: the veto OFFER and (if it happened) the EXERCISE both ride INSIDE the signed bytes,
  // so neither "an offer was made" nor "it was/wasn't exercised" can be quietly stripped. The
  // convene receipt seals with the offer's default `offered-not-exercised` state; a confirmed tap
  // seals its `exercised` flip in the CHAINED veto record (see exerciseFounderVeto), not by
  // re-signing these bytes.
  if (vd.vetoed) {
    L.push(`veto: exercised ${norm(vd.vetoTier || 'hold')} ${norm(vd.vetoedBy)} :: ${norm(vd.vetoReason)}`)
  } else if (vd.vetoOffer) {
    L.push(`veto: offered ${norm(vd.vetoOffer.principal)} window ${Number(vd.vetoOffer.windowSecs) || 0}s :: ${norm(vd.vetoOffer.state || 'offered-not-exercised')}`)
  } else {
    L.push('veto: none')
  }
  return L.join('\n')
}

// (CNCL-9 main-gate amendment) FOLD THE VETO SEAL-BINDING INTO THE SIGNED BYTES.
//
// The convene nonce digest + the executeAfter hold deadline are minted by the ROOT bash layer
// AT SEAL TIME (the engine has no clock/CSPRNG), i.e. AFTER canonicalTranscript(rec) is produced.
// Before this amendment they lived only on the UNSEALED receipt wrapper (`.vetoNonceDigest`,
// `.executeAfter`), OUTSIDE `.canonical` — so the exercise-time re-seal check (which only re-signs
// `.canonical`) did NOT cover them: an edit swapping `.vetoNonceDigest` to sha256(attacker-nonce)
// left `.canonical` untouched, the re-seal still matched, and the attacker could exercise the veto
// with a chosen nonce. FIX: bash appends this deterministic seal-binding LINE to the canonical
// BEFORE sealing, so the digest + deadline are covered by the same HMAC; exercise reads them back
// from the VERIFIED canonical (parseCanonicalVetoBinding), never from the raw wrapper. Any edit to
// the digest or deadline now changes `.canonical` and breaks the re-seal (fail-closed, refused).
//
// The line is appended (never interleaved) so a base-only receipt (no veto offer) stays byte-
// identical to CNCL-6/8. The format is a single stable line the parser round-trips exactly.
export function augmentCanonicalVetoBinding(canonical, binding) {
  const nd = String((binding && binding.nonceDigest) || '').replace(/\s+/g, '')
  const ea = String((binding && binding.executeAfter) || '').replace(/\s+/g, '')
  if (!nd && !ea) return String(canonical == null ? '' : canonical)   // nothing to bind — unchanged
  return `${String(canonical == null ? '' : canonical)}\nveto-seal: nonceDigest=${nd} executeAfter=${ea}`
}

// Parse the seal-binding back OUT of a VERIFIED canonical (the bytes that re-sealed to the stored
// digest). Returns { nonceDigest, executeAfter, stampedAt, present }. stampedAt is read from the
// canonical's own `stampedAt: ` line (already inside the sealed bytes since CNCL-6). Fail-closed:
// a canonical with no seal-binding line returns present=false + empty digest, so exercise refuses.
export function parseCanonicalVetoBinding(canonical) {
  const text = String(canonical == null ? '' : canonical)
  const m = text.match(/^veto-seal: nonceDigest=(\S*) executeAfter=(\S*)$/m)
  const sm = text.match(/^stampedAt: (.*)$/m)
  return {
    present: !!m,
    nonceDigest: m ? m[1] : '',
    executeAfter: m ? m[2] : '',
    stampedAt: sm ? sm[1].trim() : '',
  }
}

// The seal/verify run at the ROOT CLI layer (a standalone engine has no root). $RECEIPT =
// canonicalTranscript(rec) on stdin; seal stores the base64url HMAC, verify re-signs + compares.
export function sealCommands() {
  return {
    seal: `printf '%s' "$RECEIPT" | sudo 5dive gate-proof sign`,
    verify: `test "$(printf '%s' "$RECEIPT" | sudo 5dive gate-proof sign)" = "$STORED_DIGEST"`,
  }
}

// ==================== CNCL-8: human-seeded GENESIS roster ====================
// The primary council must not bootstrap its OWN membership — it is seeded ONCE by a human
// via `council init` (sudo-gated at the bash layer). These helpers build + canonicalize the
// genesis record; the bash layer seals it on the ROOT gate-proof rail and hash-chains it into
// the lineage. `council` is special in exactly one way: raw bench add/rm on it is refused (CLI
// layer) — membership changes only via promote/demote motions once the machinery lands.

// Parse a threshold SPEC string: "majority" | "all" | "3" (flat N) | "2/3" (fraction). Returns
// a spec object consumable by resolveThreshold/quorumSize. Fails CLOSED (null) on garbage.
export function parseThresholdSpec(str) {
  const s = String(str == null ? '' : str).trim().toLowerCase()
  if (!s || s === 'majority') return { rule: 'majority' }
  if (s === 'all') return { rule: 'fraction', value: 1 }
  const frac = s.match(/^(\d+)\s*\/\s*(\d+)$/)
  if (frac) { const a = Number(frac[1]), b = Number(frac[2]); if (b > 0 && a > 0 && a <= b) return { rule: 'fraction', value: a / b, label: `${a}/${b}` }; return null }
  if (/^\d+$/.test(s)) { const n = Number(s); return n > 0 ? { rule: 'flat', threshold: n } : null }
  return null
}

// Parse a genesis seat spec: "a:chair,b,c" — a comma list of ids; a token "id:chair" marks the
// chair (princeps senatus, breaks ties, votes last). Exactly one chair is allowed. Anything
// else after the colon is treated as an explicit lens. Returns { seats, chair } or throws.
export function parseGenesisSeats(spec) {
  const parts = String(spec == null ? '' : spec).split(',').map(s => s.trim()).filter(Boolean)
  const seats = []
  let chair = null
  const seen = new Set()
  for (const p of parts) {
    const i = p.indexOf(':')
    const id = (i < 0 ? p : p.slice(0, i)).trim()
    const tag = i < 0 ? '' : p.slice(i + 1).trim()
    if (!id) throw new Error(`empty seat id in "${p}"`)
    if (seen.has(id)) throw new Error(`duplicate seat: ${id}`)
    seen.add(id)
    const isChair = tag.toLowerCase() === 'chair'
    if (isChair) { if (chair) throw new Error(`more than one chair (${chair}, ${id})`); chair = id }
    const lens = (!tag || isChair) ? `${id} — council seat.` : tag
    seats.push({ id, lens, ...(isChair ? { chair: true } : {}) })
  }
  if (!seats.length) throw new Error('genesis needs at least one seat')
  return { seats, chair }
}

// Build the immutable genesis record. `veto` is { principal, resolved } — the resolvable human
// principal (e.g. human:main) plus the tg user_id the bash layer resolved it to; init REFUSES
// an unresolved principal (the record must carry a real, resolvable veto holder). prevDigest
// hash-chains this record to the prior lineage head (empty for the very first seed). No in-engine
// clock — caller supplies stampedAt (byte-reproducible canonical form).
export function buildGenesisRecord({ seats, chair, threshold, veto, prevDigest, stampedAt, forced, seq }) {
  if (!Array.isArray(seats) || !seats.length) throw new Error('genesis needs seats')
  if (!veto || !veto.principal) throw new Error('genesis needs a veto principal')
  if (!veto.resolved) throw new Error(`veto principal "${veto.principal}" did not resolve to a real recipient (fail-closed)`)
  return {
    kind: 'genesis',
    version: 1,
    seq: Number(seq) || 0,
    council: 'council',
    seats: seats.map(s => ({ id: s.id, lens: s.lens, ...(s.chair ? { chair: true } : {}) })),
    chair: chair || null,
    threshold: threshold || { rule: 'majority' },
    veto: { principal: veto.principal, resolved: String(veto.resolved) },
    forced: !!forced,
    prevDigest: prevDigest || '',
    stampedAt: stampedAt || '',
  }
}

// Deterministic, whitespace-normalized preimage of a genesis record — the bytes the ROOT rail
// seals + hash-chains. Same discipline as canonicalTranscript: order-independent seats, the veto
// + prevDigest INSIDE the signed bytes so neither can be quietly altered without failing verify.
export function canonicalGenesis(rec) {
  const norm = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim()
  const L = []
  L.push(`genesis: ${norm(rec.council)} v${Number(rec.version) || 1} seq=${Number(rec.seq) || 0}`)
  L.push(`stampedAt: ${norm(rec.stampedAt)}`)
  L.push(`forced: ${!!rec.forced}`)
  L.push(`prevDigest: ${norm(rec.prevDigest)}`)
  const seats = (rec.seats || []).slice().sort((a, b) => (norm(a.id) < norm(b.id) ? -1 : 1))
  for (const s of seats) L.push(`seat ${norm(s.id)}${s.chair ? ' (chair)' : ''}: ${norm(s.lens)}`)
  L.push(`chair: ${norm(rec.chair)}`)
  const th = rec.threshold || {}
  L.push(`threshold: rule=${norm(th.rule)} value=${th.value != null ? Number(th.value) : ''} flat=${th.threshold != null ? Number(th.threshold) : ''}`)
  L.push(`veto: ${norm(rec.veto && rec.veto.principal)} -> ${norm(rec.veto && rec.veto.resolved)}`)
  return L.join('\n')
}

// The bench entry a genesis record seeds into the persisted registry — the primary `council`.
export function genesisToBench(rec) {
  return {
    description: DEFAULT_COUNCIL.description,
    mode: DEFAULT_COUNCIL.mode,
    seats: rec.seats.map(s => ({ id: s.id, lens: s.lens })),
    threshold: rec.threshold,
    genesis: true,           // marks this bench as motion-governed (raw add/rm refused)
    seededAt: rec.stampedAt,
  }
}

// ==================== schemas (ported from P0/P2) ====================
export const TAKE = { type: 'object', additionalProperties: false, required: ['seat', 'position', 'keyRisk'],
  properties: { seat: { type: 'string' }, position: { type: 'string' }, keyRisk: { type: 'string' } } }
export const VOTE = { type: 'object', additionalProperties: false, required: ['seat', 'vote', 'rationale'],
  properties: { seat: { type: 'string' }, vote: { type: 'string', enum: ['approve', 'reject', 'escalate'] }, rationale: { type: 'string' } } }
export const NODE_VOTE = { type: 'object', additionalProperties: false, required: ['seat', 'choice', 'rationale'],
  properties: { seat: { type: 'string' }, choice: { type: 'string' }, rationale: { type: 'string' } } }
const TALLY = { type: 'object', additionalProperties: false, required: ['approve', 'reject', 'escalate'],
  properties: { approve: { type: 'integer' }, reject: { type: 'integer' }, escalate: { type: 'integer' } } }
export const VERDICT = { type: 'object', additionalProperties: false,
  required: ['recommendation', 'tally', 'confidence', 'dissent', 'escalated', 'brief'],
  properties: {
    recommendation: { type: 'string', enum: ['approve', 'reject', 'escalate'] }, tally: TALLY,
    confidence: { type: 'number' }, dissent: { type: 'string' }, escalated: { type: 'boolean' }, brief: { type: 'string' } } }
export const NODE_VERDICT = { type: 'object', additionalProperties: false,
  required: ['choice', 'tally', 'confidence', 'dissent', 'escalated', 'brief'],
  properties: {
    choice: { type: 'string' }, tally: TALLY,
    confidence: { type: 'number' }, dissent: { type: 'string' }, escalated: { type: 'boolean' }, brief: { type: 'string' } } }

// ==================== model-call adapter (A-with-seam) ====================
// Minimal structural validation of a model's forced-tool output against a schema — enough
// to catch a malformed object and trigger one retry (NOT a full JSON-schema validator).
export function validateAgainstSchema(obj, schema) {
  if (obj == null || typeof obj !== 'object') return 'not an object'
  for (const key of schema.required || []) {
    if (!(key in obj)) return `missing required field: ${key}`
  }
  for (const [k, spec] of Object.entries(schema.properties || {})) {
    if (!(k in obj)) continue
    if (spec.enum && !spec.enum.includes(obj[k])) return `field ${k}='${obj[k]}' not in enum`
    if (spec.type === 'integer' && !Number.isInteger(obj[k])) return `field ${k} not an integer`
    if (spec.type === 'string' && typeof obj[k] !== 'string') return `field ${k} not a string`
  }
  return null
}

// Build the default Anthropic-Messages modelCall. The seam: pass {baseUrl, model, apiKey}
// (and later a provider variant) without touching the engine. Returns a validated object
// matching `schema` via a forced `emit` tool, with one retry on a malformed result.
export function makeAnthropicModelCall(config = {}) {
  const baseUrl = (config.baseUrl || process.env.COUNCIL_BASE_URL || 'https://api.anthropic.com').replace(/\/+$/, '')
  const apiKey = config.apiKey || process.env.COUNCIL_API_KEY || ''
  const version = config.anthropicVersion || '2023-06-01'
  const maxTokens = config.maxTokens || 1024
  const fetchImpl = config.fetch || globalThis.fetch
  return async function modelCall(prompt, schema, opts = {}) {
    if (!apiKey) throw new Error('COUNCIL_API_KEY is not set — provision it via `5dive secret` (see CNCL-6). The engine is testable with a mock modelCall without a live key.')
    const model = opts.model || config.model || 'claude-sonnet-5'
    const body = {
      model, max_tokens: maxTokens,
      messages: [{ role: 'user', content: prompt }],
      tools: [{ name: 'emit', description: 'Return your answer as a structured object.', input_schema: schema }],
      tool_choice: { type: 'tool', name: 'emit' },
    }
    let lastErr = ''
    for (let attempt = 0; attempt < 2; attempt++) {
      const res = await fetchImpl(`${baseUrl}/v1/messages`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': version },
        body: JSON.stringify(body),
      })
      if (!res.ok) { lastErr = `HTTP ${res.status}`; continue }
      const data = await res.json()
      const tool = (data.content || []).find(b => b.type === 'tool_use' && b.name === 'emit')
      const obj = tool && tool.input
      const err = validateAgainstSchema(obj, schema)
      if (!err) return obj
      lastErr = err
    }
    throw new Error(`modelCall failed to produce a valid ${schema.required ? schema.required.join('/') : 'object'} after retry: ${lastErr}`)
  }
}

// ==================== DISPATCH (CNCL-7): convene -> real seated agents ====================
// Fleet mode: convene DISPATCHES the question to the real seated agents (the `5dive agent ask`
// rail); each seat votes via its OWN harness + model access — NO shared council key. The engine
// stays pure: the CLI injects a `seatVote(seat, ctx)` adapter that shells the ask rail; tests
// inject a deterministic mock. makeAnthropicModelCall survives only as the deferred standalone
// seam. LIVENESS: a seat that times out / replies unparseably / throws is a recorded ABSTAIN —
// never silently dropped from the roster, so the quorum gate can fail an inquorate convene
// (one dead agent must not turn 3-of-5 into 3-of-4). BLIND FIRST ROUND: a round-1 prompt is a
// pure function of (seat, question) and never embeds another seat's answer.
export const VOTE_TOKENS = ['approve', 'reject', 'escalate', 'abstain']

// Parse a seat's free-text reply (pane-scraped by `agent ask`) into a structured vote. The seat
// is instructed to END with a line `COUNCIL-VOTE: <approve|reject|escalate> :: <why>`. We take
// the LAST such line (so a seat that reasons out loud then concludes is honored), case-insensitive.
// No parseable line => null: the caller records an ABSTAIN (fail-safe — never a silent approve).
export function parseVote(reply) {
  if (!reply || typeof reply !== 'string') return null
  const re = /council-vote:\s*(approve|reject|escalate|abstain)\b\s*(?:::\s*(.*))?$/i
  let hit = null
  for (const line of reply.split(/\r?\n/)) {
    const m = line.trim().match(re)
    if (m) hit = m
  }
  if (!hit) return null
  const vote = hit[1].toLowerCase()
  const rationale = (hit[2] || '').trim() || `(${vote}, no rationale given)`
  return { vote, rationale }
}

// Build the per-seat dispatch prompt. BLIND-FIRST-ROUND invariant: round-1 output is a pure
// function of (seat, question) and NEVER embeds another seat's take/vote, so no seat anchors on
// another before its own vote is recorded. The rebuttal round (adversarial only, round 2) DOES
// show the round-1 votes and is recorded separately.
export function seatPrompt(seat, ctx = {}) {
  const round = ctx.round || 1
  const q = ctx.question || ''
  const head = `You hold the "${seat.id}" seat on the 5dive Council. Your lens: ${seat.lens || seat.id}.`
  const ask = `Question before the council: "${q}"`
  const fmt = `Reply with brief reasoning, then END with EXACTLY this line and nothing after it:
COUNCIL-VOTE: <approve|reject|escalate> :: <one-sentence rationale>
Escalate ONLY if this genuinely needs a human (money/spend, destructive/irreversible, secrets, or a brand call on a mature product) or the council is hopelessly split.`
  if (round >= 2 && Array.isArray(ctx.priorVotes) && ctx.priorVotes.length) {
    const prior = ctx.priorVotes.map(v => `- ${v.seat}: ${String(v.vote).toUpperCase()} — ${v.rationale}`).join('\n')
    return `${head}
${ask}
The council's first-round votes:
${prior}
REBUT: find the strongest objection to the leading position, then cast your FINAL vote.
${fmt}`
  }
  return `${head}
${ask}
Give your INDEPENDENT vote BEFORE hearing any other seat.
${fmt}`
}

// Normalize a seatVote adapter result into a recorded vote row. An unusable result becomes an
// ABSTAIN — counted in the roster denominator (seatCount) but not in approve/reject/escalate.
export function normalizeSeatVote(seat, res) {
  if (!res || typeof res !== 'object' || !VOTE_TOKENS.includes(res.vote)) {
    return { seat: seat.id, vote: 'abstain', rationale: (res && res.rationale) ? String(res.rationale) : 'abstained (no reply / unparseable)' }
  }
  const rationale = (res.rationale && String(res.rationale).trim()) || `(${res.vote})`
  return { seat: seat.id, vote: res.vote, rationale }
}

// Gather one round of votes from real seats via the injected dispatch adapter, in parallel. Each
// seat is isolated: it only ever sees seatPrompt(seat, ctx) this round. A seat adapter that
// rejects is caught -> abstain (liveness), so one crashed seat cannot abort the whole convene.
async function dispatchRound(seats, ctx, seatVote) {
  return Promise.all(seats.map(async (s) => {
    try { return normalizeSeatVote(s, await seatVote(s, ctx)) }
    catch (e) { return { seat: s.id, vote: 'abstain', rationale: `dispatch error: ${String(e && e.message || e)}` } }
  }))
}

// DETERMINISTIC synthesis (fleet mode, NO model key): confidence from the winning margin among
// votes cast, dissent from the losing side's rationales, a human brief assembled on escalate.
// Keeps the ENTIRE verdict path key-free + auditable for a real-agent convene (no LLM in the
// tally OR the summary — the chair narrative modelCall is only used on the standalone seam).
export function synthesizeNarrative(votes, counted) {
  const cast = (votes || []).filter(v => v.vote !== 'abstain')
  const abstained = (votes || []).filter(v => v.vote === 'abstain')
  const winner = counted.recommendation
  const withWinner = cast.filter(v => v.vote === winner)
  const against = cast.filter(v => v.vote !== winner)
  const confidence = cast.length ? Math.round((withWinner.length / cast.length) * 100) / 100 : 0
  const dissent = against.length ? against.map(v => `${v.seat} (${v.vote}): ${v.rationale}`).join('; ') : 'none'
  let brief = ''
  if (counted.escalated) {
    const why = !counted.quorumMet
      ? `Inquorate: only ${counted.votesCast} of ${counted.seatCount} seats voted (quorum ${counted.quorum})${abstained.length ? `; abstained: ${abstained.map(v => v.seat).join(', ')}` : ''}.`
      : `Council split (tally ${tallyStr(counted.tally)}); no side reached the ${counted.decisionClass} threshold and escalate carried.`
    const takes = cast.map(v => `${v.seat}: ${v.vote} — ${v.rationale}`).join(' | ')
    brief = `${why} Seat positions: ${takes || '(none)'}`
  }
  return { confidence, dissent, brief }
}

// Assemble the convene/standing verdict from the deterministic count + a narrative (synthesized
// in fleet mode, chair-written on the seam). Carries the quorum bookkeeping onto the verdict so
// the disposition + receipt reflect liveness.
export function buildConveneVerdict(counted, narr) {
  return {
    recommendation: counted.recommendation, tally: counted.tally, threshold: counted.threshold,
    seatCount: counted.seatCount, quorum: counted.quorum, quorumMet: counted.quorumMet, votesCast: counted.votesCast,
    confidence: narr.confidence, dissent: narr.dissent,
    escalated: counted.escalated, brief: counted.escalated ? narr.brief : '',
  }
}

// ==================== deliberation engine ====================
// Narrative-only synthesis for the named council: the chair writes confidence/dissent/
// brief but does NOT decide the recommendation (that's the deterministic tallyVotes count).
const NARRATIVE = { type: 'object', additionalProperties: false, required: ['confidence', 'dissent', 'brief'],
  properties: { confidence: { type: 'number' }, dissent: { type: 'string' }, brief: { type: 'string' } } }

function log(on, msg) { if (on) process.stderr.write(`[council] ${msg}\n`) }

// Run a full convene -> deliberate -> chair-synthesis over `question` with `seats`.
// `modelCall` is injected (real adapter in prod, a deterministic mock in tests).
// mode: quick (no cross-take context) | deliberate (seats see all opening takes) |
// adversarial (deliberate + one rebuttal round). role: 'convene'|'gate'|'verifier'|'node'.
export async function runCouncil(input, deps = {}) {
  const modelCall = deps.modelCall || makeAnthropicModelCall(input.config || {})
  const verbose = !!deps.verbose
  const role = input.role || 'convene'
  const mode = input.mode || 'deliberate'
  const seats = input.seats && input.seats.length ? input.seats : DEFAULT_COUNCIL.seats
  const isNode = role === 'node'
  const question = input.question || nodeQuestion(input)

  // Guardrail (gate/verifier/node) — escalate-only on a hard-gate class, no model spend.
  const guardTarget = role === 'gate' ? input.gate : role === 'verifier' ? input.task : isNode ? input.node : null
  if (guardTarget) {
    const g = guardrail(guardTarget)
    if (g.forceEscalate) {
      log(verbose, `force-escalated by guardrail: ${g.reason}`)
      const verdict = isNode
        ? { choice: '', tally: { approve: 0, reject: 0, escalate: seats.length }, confidence: 1, dissent: 'none', escalated: true, brief: `Not council-decidable: ${g.reason}.` }
        : { recommendation: 'escalate', tally: { approve: 0, reject: 0, escalate: seats.length }, confidence: 1, dissent: 'none', escalated: true, brief: `Not council-gradable/clearable: ${g.reason}.` }
      return finish(role, input, { question, mode, seats, guardrail: g, convened: false, takes: [], votes: [], verdict })
    }
  }

  // ---- CNCL-7: convene/standing DISPATCH to the REAL seated agents (fleet mode) or, when no
  // dispatch adapter is injected, the deferred standalone modelCall seam. Blind round 1,
  // adversarial rebuttal round 2 recorded separately, timeout/unparse -> abstain, deterministic
  // quorum-gated tally + key-free synthesis. Gate/verifier/node (P1/P2) keep the path below.
  if (role === 'convene' || role === 'standing') {
    return await runConvene(input, deps, { modelCall, seatVote: deps.seatVote, verbose, role, mode, seats, question })
  }

  // Convene — independent opening takes.
  log(verbose, `convening ${seats.length} seats (${mode})`)
  const takes = await Promise.all(seats.map(s =>
    modelCall(`You hold the "${s.id}" seat on the 5dive Council${roleBlurb(role)}. Your lens: ${s.lens}
${questionBlock(role, input, question)}
Give your independent opening take BEFORE hearing the other seats. Be concrete and brief.`, TAKE)))
  const takeText = takes.map(t => `- ${t.seat}: ${t.position} (key risk: ${t.keyRisk})`).join('\n')

  // Deliberate — vote (node seats choose a branch; others vote approve/reject/escalate).
  const seeTakes = mode === 'quick' ? '' : `The opening takes from all seats:\n${takeText}\n`
  const voteSchema = isNode ? NODE_VOTE : VOTE
  const votePrompt = (s) => isNode
    ? `You hold the "${s.id}" seat deciding a goal-DAG branch. Your lens: ${s.lens}
${questionBlock(role, input, question)}
${seeTakes}Name exactly ONE of the options (${input.node.options}) as your choice, with a one-to-two sentence rationale.`
    : `You hold the "${s.id}" seat on the 5dive Council${roleBlurb(role)}. Your lens: ${s.lens}
${questionBlock(role, input, question)}
${seeTakes}Cast your vote (approve | reject | escalate) with a one-to-two sentence rationale. Escalate ONLY if this genuinely needs a human (money/spend, destructive/irreversible, secrets, or a brand call on a mature product) or the council is hopelessly split.`
  let votes = await Promise.all(seats.map(s => modelCall(votePrompt(s), voteSchema)))

  // Adversarial: one rebuttal round where each seat may revise after seeing the votes.
  if (mode === 'adversarial' && !isNode) {
    const voteText = votes.map(v => `- ${v.seat}: ${v.vote} — ${v.rationale}`).join('\n')
    votes = await Promise.all(seats.map(s => modelCall(
      `You hold the "${s.id}" seat. Lens: ${s.lens}
${questionBlock(role, input, question)}
The first-round votes:\n${voteText}
REBUT: try to find the strongest objection to the leading position. Then cast your FINAL vote (approve | reject | escalate) with a one-to-two sentence rationale.`, VOTE)))
  }

  // Verdict. Gate/verifier/node (P1/P2) keep their ported chair-synthesized verdict + action
  // map (convene/standing returned early via runConvene above).
  const verdict = await chair(modelCall, role, input, question, votes, isNode)
  return finish(role, input, { question, mode, seats, guardrail: guardTarget ? { forceEscalate: false, reason: '' } : null, convened: true, takes, votes, verdict })
}

// CNCL-7 convene/standing driver — split out of runCouncil. Two paths share one deterministic
// tally + one receipt: (1) FLEET dispatch (deps.seatVote present) — each seat votes via its own
// harness, blind round 1, adversarial rebuttal round 2 recorded separately, timeout/unparse ->
// abstain, KEY-FREE synthesis; (2) the standalone modelCall SEAM (no seatVote) — one model
// answers each seat, same blind-round-1 discipline, chair-written narrative. Founder veto threads
// both. `deps` is forwarded only for symmetry; the resolved handles come in via `h`.
async function runConvene(input, deps, h) {
  const { modelCall, seatVote, verbose, role, mode, seats, question } = h
  const tallyOpts = {
    decisionClass: input.decisionClass || (input.bench && input.bench.decisionClass) || 'ordinary',
    policy: input.policy,
    threshold: input.threshold != null ? input.threshold : (input.bench && input.bench.threshold),
    thresholdRule: input.thresholdRule || (input.bench && input.bench.thresholdRule),
    seatCount: seats.length,
  }
  let round1Votes, finalVotes, rebuttalVotes = null, verdict
  if (seatVote) {
    log(verbose, `dispatching ${seats.length} real seats (blind round 1, ${mode})`)
    round1Votes = await dispatchRound(seats, { question, role, mode, round: 1 }, seatVote)
    finalVotes = round1Votes
    if (mode === 'adversarial') {
      log(verbose, `adversarial rebuttal (round 2, recorded separately)`)
      rebuttalVotes = await dispatchRound(seats, { question, role, mode, round: 2, priorVotes: round1Votes }, seatVote)
      finalVotes = rebuttalVotes
    }
    const counted = tallyVotes(finalVotes, tallyOpts)
    verdict = buildConveneVerdict(counted, synthesizeNarrative(finalVotes, counted))
  } else {
    // Standalone seam: one modelCall answers each seat. Blind round 1 (seatPrompt embeds NO
    // other seat's take), then an adversarial rebuttal that sees the round-1 votes.
    log(verbose, `convening ${seats.length} seats via the modelCall seam (blind round 1, ${mode})`)
    const askSeam = (s, ctx) => modelCall(seatPrompt(s, ctx), VOTE).then(v => ({ seat: v.seat || s.id, vote: v.vote, rationale: v.rationale }))
    round1Votes = await Promise.all(seats.map(s => askSeam(s, { question, round: 1 })))
    finalVotes = round1Votes
    if (mode === 'adversarial') {
      rebuttalVotes = await Promise.all(seats.map(s => askSeam(s, { question, round: 2, priorVotes: round1Votes })))
      finalVotes = rebuttalVotes
    }
    const counted = tallyVotes(finalVotes, tallyOpts)
    const narr = await chairNarrative(modelCall, question, finalVotes)
    verdict = buildConveneVerdict(counted, narr)
  }
  // CNCL-9: convene only ever OFFERS the veto (non-blocking); the flip happens later, and only
  // via an authenticated tap on the tier-2 rail (exerciseFounderVeto). No string ever flips here.
  verdict = attachVetoOffer(verdict, input.vetoOffer)
  return finish(role, input, {
    question, mode, seats, guardrail: null, convened: true,
    takes: [], votes: finalVotes, round1Votes, rebuttalVotes, verdict,
  })
}

function roleBlurb(role) {
  if (role === 'verifier') return ' acting as a VERIFIER (a bench of graders)'
  if (role === 'gate') return ' reviewing a risk-tiered gate'
  return ''
}
function nodeQuestion(input) {
  if (input.role === 'node' && input.node) return `Decision node: "${input.node.question}". Options: ${input.node.options}.`
  return input.question || ''
}
function questionBlock(role, input, question) {
  if (role === 'verifier' && input.task) {
    const t = input.task
    return `A maker submitted work for ${t.ident}. Original ask: "${t.ask}". Acceptance: "${t.accept}". Result: "${t.result}". Does it meet the criteria (approve), fail (reject — bounce to maker), or need a human (escalate)?`
  }
  if (role === 'gate' && input.gate) {
    const g = input.gate
    return `A tier-${g.tier} gate ${g.ident} needs a decision. Ask: "${g.ask}".${g.options ? ` Options: ${g.options}.` : ''}${g.recommend ? ` Filer recommends: ${g.recommend}.` : ''} Clear it (approve) or bump to a human (escalate)?`
  }
  if (role === 'node' && input.node) return `Question before the council: ${question}`
  return `Question before the council: "${question}"`
}

// Narrative-only chair for the named council: writes confidence/dissent/brief; does NOT
// decide the recommendation (that's the deterministic tally).
async function chairNarrative(modelCall, question, votes) {
  const voteText = votes.map(v => `- ${v.seat}: ${String(v.vote).toUpperCase()} — ${v.rationale}`).join('\n')
  return modelCall(`You are the Chair of the 5dive Council. The PASS/FAIL is decided by seat count, not by you — your job is only to summarize. Do not add your own opinion.
Question: "${question}"
Seat votes:\n${voteText}
Produce: confidence in [0,1] (how firm the panel is), dissent = the load-bearing minority view or "none" if unanimous, brief = one paragraph a human would need IF this has to go to them (else "").`, NARRATIVE)
}

async function chair(modelCall, role, input, question, votes, isNode) {
  if (isNode) {
    const voteText = votes.map(v => `- ${v.seat}: ${v.choice} — ${v.rationale}`).join('\n')
    return modelCall(`You are the Chair synthesizing a goal-DAG node verdict; aggregate only, no new opinion.
Decision: "${input.node.question}". Options: ${input.node.options}.
Seat choices:\n${voteText}
choice = the option with the most seat support (must be one of: ${input.node.options}); if evenly split or it genuinely needs a human, set escalated=true and choice="". tally: seats backing the winner as approve, others as reject, escalate-wanters as escalate. confidence [0,1]. dissent = load-bearing minority or "none". brief = one paragraph for the human iff escalated, else "".`, NODE_VERDICT)
  }
  const voteText = votes.map(v => `- ${v.seat}: ${String(v.vote).toUpperCase()} — ${v.rationale}`).join('\n')
  return modelCall(`You are the Chair of the 5dive Council. Synthesize the verdict from the seat votes; aggregate only, no new opinion.
${questionBlock(role, input, question)}
Seat votes:\n${voteText}
recommendation = the majority vote; if split evenly OR any seat escalated on a hard-gate class, set recommendation=escalate and escalated=true. tally = count each vote type. confidence [0,1]. dissent = load-bearing minority or "none". brief = one paragraph for the human iff escalated, else "".`, VERDICT)
}

// Attach the role-appropriate action map / receipt to the verdict.
function finish(role, input, base) {
  const out = { role, ...base }
  if (role === 'gate') out.gateAction = verdictToAction(input.gate, base.verdict)
  else if (role === 'verifier') out.verifierAction = verifierVerdictToAction(input.task, base.verdict)
  else if (role === 'node') out.nodeDecision = nodeVerdictToDecision(input.node, base.verdict)
  if (role === 'convene' || role === 'standing') {
    const rec = {
      council: input.councilName || 'ad-hoc', mode: base.mode, stampedAt: input.stampedAt || '',
      question: base.question, seats: base.seats.map(s => s.id), votes: base.votes, verdict: base.verdict,
      // Seal round-1 history ONLY when a rebuttal round ran (adversarial); a single-round receipt
      // omits it and stays byte-identical to CNCL-6. Makes the between-round record tamper-evident.
      ...(base.rebuttalVotes ? { round1Votes: base.round1Votes } : {}),
    }
    out.receipt = { canonical: canonicalTranscript(rec), ...sealCommands() }
  }
  return out
}

// ==================== CNCL-10: per-seat Ed25519 CO-SIGNED VOTES ====================
//
// The CNCL-6 receipt root-signs the WHOLE transcript with the ROOT gate-proof key — it proves
// the convener recorded these bytes, but NOTHING proves each seat actually cast its own vote:
// the convener assembles the vote rows and could forge or edit any of them before the seal.
// CNCL-10 closes that: every seat holds its OWN Ed25519 keypair and SIGNS its vote AT SOURCE
// (inside its own harness, before the vote leaves the agent). The convener holds no other
// seat's private key, so it can neither forge a vote nor alter one without breaking the sig.
//
// REPLAY PROOF: the signed bytes bind the CONVENE ID + the QUESTION DIGEST, so a seat's signed
// "approve" from an old convene fails verification in a new one (different convene id / digest).
// The verifier recomputes the expected preimage from the CURRENT convene context + the vote's
// own (seat, vote, rationale, stampedAt) — it never trusts a vote's self-reported convene/digest.
//
// KEY LIFECYCLE (bash layer owns the on-disk side): a keypair is issued at init/promote; the
// public key + fingerprint live in the roster; the private key is 0600, owner-only (agent-<name>,
// NOT the shared `claude` group — that group holds every agent and would leak the key). A demote
// REVOKES the key (fingerprint + revocation stamped in the lineage); compromise = revoke+reissue.
// A revoked seat's vote is rejected by verifyReceiptVotes even if the signature is cryptographically
// valid, so a demoted seat can no longer sway a convene.
//
// The receipt bundles the co-signed vote rows; the existing ROOT HMAC seal (canonicalTranscript)
// sits on top unchanged. `council verify` re-checks EVERY seat signature against the roster pubkeys
// AND revocation AND the root seal — all three must pass for a green receipt.

const _cnorm = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim()
function _b64url(buf) { return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '') }
function _b64urlDecode(str) { const s = String(str || '').replace(/-/g, '+').replace(/_/g, '/'); return Buffer.from(s, 'base64') }

// Deterministic sha256 (hex) of the normalized question — the replay-binding digest a seat signs.
export function questionDigest(question) {
  return createHash('sha256').update(_cnorm(question), 'utf8').digest('hex')
}

// Deterministic, whitespace-normalized preimage of ONE seat's vote — the exact bytes the seat
// signs at source and the verifier recomputes. Binds seat + position(vote) + reasoning(rationale)
// + ts(stampedAt) + CONVENE ID + QUESTION DIGEST. A v1 tag guards against a future format swap.
export function canonicalVoteBytes(v) {
  return [
    'council-vote v1',
    `convene: ${_cnorm(v.conveneId)}`,
    `qdigest: ${_cnorm(v.questionDigest)}`,
    `seat: ${_cnorm(v.seat)}`,
    `vote: ${_cnorm(v.vote)}`,
    `rationale: ${_cnorm(v.rationale)}`,
    `stampedAt: ${_cnorm(v.stampedAt)}`,
  ].join('\n')
}

// sha256(pubkey)[:16] — the short human-readable key fingerprint stored in the roster + lineage.
export function fingerprintOf(pub) {
  return createHash('sha256').update(String(pub || ''), 'utf8').digest('hex').slice(0, 16)
}

// Mint a fresh per-seat Ed25519 keypair. Returns the PUBLIC key (base64url SPKI-DER, roster-safe),
// its fingerprint, and the PRIVATE key as a PKCS8 PEM string — the bash layer writes the PEM 0600
// owner-only and stores only {pub, fingerprint} in the roster. No clock, no randomness seam needed
// (generateKeyPairSync is the platform CSPRNG). Never log or persist the PEM anywhere world/group
// readable.
export function generateSeatKeypair() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519')
  const pub = _b64url(publicKey.export({ type: 'spki', format: 'der' }))
  const privPem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString()
  return { pub, privPem, fingerprint: fingerprintOf(pub) }
}

// Raw Ed25519 sign/verify over a preimage string. Sign returns a base64url signature; verify is
// fail-closed (any malformed key/sig/bytes -> false, never a throw that could be read as "valid").
export function signBytes(bytes, privPem) {
  const key = createPrivateKey(privPem)
  return _b64url(edSign(null, Buffer.from(String(bytes), 'utf8'), key))
}
export function verifyBytes(bytes, sigB64, pub) {
  try {
    const key = createPublicKey({ key: _b64urlDecode(pub), format: 'der', type: 'spki' })
    return edVerify(null, Buffer.from(String(bytes), 'utf8'), key, _b64urlDecode(sigB64))
  } catch { return false }
}

// SIGN-AT-SOURCE: a seat signs its own vote with its OWN private key before the vote leaves the
// agent. `ctx` carries the convene binding {conveneId, questionDigest}; `vote` is {seat, vote,
// rationale, stampedAt}. Returns the vote row plus {sig, sigAlg, fingerprint}. This runs inside
// the seat's harness (via `5dive council sign-vote`), NEVER on the convener.
export function signSeatVote(vote, ctx, privPem, fingerprint = '') {
  const bytes = canonicalVoteBytes({
    conveneId: ctx.conveneId, questionDigest: ctx.questionDigest,
    seat: vote.seat, vote: vote.vote, rationale: vote.rationale, stampedAt: vote.stampedAt,
  })
  return { ...vote, sig: signBytes(bytes, privPem), sigAlg: 'ed25519', ...(fingerprint ? { fingerprint } : {}) }
}

// Verify ONE co-signed vote against the roster. Recomputes the preimage from the CURRENT convene
// context (ctx.conveneId + ctx.questionDigest) so a vote signed for another convene/question fails
// (replay). Fail-closed: no roster key, revoked key, missing sig, or a non-matching signature all
// return ok=false with a reason. An ABSTAIN is a recorded non-vote (a dead/silent seat that never
// signed): it is allowed unsigned but carries no weight — flagged abstain=true, ok=true.
export function verifySeatVote(signedVote, ctx, roster = {}) {
  const seat = signedVote && signedVote.seat
  if (signedVote && signedVote.vote === 'abstain' && !signedVote.sig) {
    return { seat, ok: true, abstain: true, reason: 'abstain (unsigned non-vote)' }
  }
  const entry = roster[seat]
  if (!entry || !entry.pub) return { seat, ok: false, reason: `no roster key for seat "${seat}"` }
  if (entry.revokedAt) return { seat, ok: false, reason: `seat "${seat}" key was revoked (${_cnorm(entry.revokedAt)})` }
  if (!signedVote.sig) return { seat, ok: false, reason: `vote from "${seat}" is unsigned` }
  const bytes = canonicalVoteBytes({
    conveneId: ctx.conveneId, questionDigest: ctx.questionDigest,
    seat: signedVote.seat, vote: signedVote.vote, rationale: signedVote.rationale, stampedAt: signedVote.stampedAt,
  })
  const ok = verifyBytes(bytes, signedVote.sig, entry.pub)
  return { seat, ok, reason: ok ? '' : `signature does not verify for "${seat}" (forged, edited, replayed, or wrong key)` }
}

// Re-check EVERY co-signed vote in a receipt against the roster pubkeys + revocation. Returns
// { ok, results, badSeats } — ok iff every non-abstain vote carries a valid, non-revoked signature
// bound to THIS convene. This is the per-seat half of `council verify`; the root HMAC seal is the
// other half (bash re-signs canonicalTranscript). Both must pass for a green receipt.
export function verifyReceiptVotes(votes, ctx, roster = {}) {
  const results = (votes || []).map(v => verifySeatVote(v, ctx, roster))
  const badSeats = results.filter(r => !r.ok).map(r => r.seat)
  return { ok: badSeats.length === 0, results, badSeats }
}
