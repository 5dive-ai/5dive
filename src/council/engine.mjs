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
  const t = gate.type && HUMAN_ONLY_TYPES.indexOf(gate.type) === -1 ? gate.type : 'decision'
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

// (P3.1) STANDING / NAMED COUNCILS — the built-in defaults. The CLI layer persists an
// editable copy (benches.json) seeded from these; resolveCouncil fails CLOSED on a miss.
export const STANDING_COUNCILS = {
  ship: {
    description: 'Ship-worthiness of a build/diff before it goes live.',
    mode: 'deliberate',
    seats: [
      { id: 'mark', lens: 'Review, correctness, ship-worthiness. Reversible? Tested? Any regression?' },
      { id: 'security', lens: 'Injection, blast radius, secrets, auth boundaries.' },
      { id: 'cost', lens: 'Token + infra spend, capacity/egress, provider concentration.' },
    ],
  },
  brand: {
    description: 'Customer-facing / brand + messaging call on a mature surface.',
    mode: 'deliberate',
    seats: [
      { id: 'theo', lens: 'Brand + customer read; how it lands, support load.' },
      { id: 'mark', lens: 'Operational soundness + ship-worthiness.' },
      { id: 'lilbro', lens: 'Divergent/contrarian; the take everyone is too polite to say.' },
    ],
  },
  security: {
    description: 'Security-sensitive change (auth, sudo, gate/tamper rails, MCP).',
    mode: 'adversarial',
    seats: [
      { id: 'security', lens: 'Injection, privilege, blast radius, forgeability.' },
      { id: 'redteam', lens: 'Actively try to REFUTE the leading option / find the bypass.' },
      { id: 'mark', lens: 'Correctness + reversibility of the change.' },
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

// (P3.1b) THE default Council (lodar's spec): a self-governed standing body of NAMED
// voting seats, one vote each. Seat count is UNBOUNDED and the roster is MUTABLE — the
// council promotes/demotes seats by a quorum vote (addSeat/removeSeat, gated at the CLI
// layer by a real convene). These 5 are the STARTING membership, NOT a cap or a fixed
// roster. `threshold` is a CONFIG value (see resolveThreshold) — nothing hardcodes 5 or 3.
export const DEFAULT_COUNCIL = {
  name: 'council', description: 'The 5dive Council — self-governed standing body, one vote each. Seats mutable by quorum vote.',
  mode: 'deliberate', threshold: 3, thresholdRule: 'flat',
  seats: [
    { id: 'main', lens: 'Marcus — CTO / eng lead. Correctness, ship-worthiness, reversibility.' },
    { id: 'theo', lens: 'Marketing. Brand + customer read; how it lands publicly.' },
    { id: 'codex', lens: 'Builder. Implementation soundness, edge cases, blast radius.' },
    { id: 'olivia', lens: 'CEO. Strategic fit, company priorities, risk appetite.' },
    { id: 'lilbro', lens: 'Divergent/contrarian; the objection everyone is too polite to raise.' },
  ],
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

// (P3.1d) FOUNDER VETO: lodar can veto any pass. A veto flips a pass to blocked and is
// RECORDED (goes into the signed receipt bytes via canonicalTranscript, so it's auditable
// and non-forgeable). A non-pass verdict is returned unchanged (nothing to veto). Hard-gate
// classes still surface to the founder regardless (that's the guardrail, upstream).
export function applyFounderVeto(verdict, veto) {
  if (!veto || !veto.by) return verdict
  const passed = verdict.recommendation === 'approve' && !verdict.escalated
  if (!passed) return verdict   // only a pass can be vetoed
  return {
    ...verdict,
    disposition: 'blocked',
    vetoed: true,
    vetoedBy: veto.by,
    vetoReason: veto.reason || '',
    brief: `Founder veto by ${veto.by}: pass (tally ${tallyStr(verdict.tally)}) flipped to BLOCKED.${veto.reason ? ` Reason: ${veto.reason}` : ''}`,
  }
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
  const vd = rec.verdict || {}
  const t = vd.tally || {}
  L.push(`verdict: ${norm(vd.recommendation != null ? vd.recommendation : vd.choice)} conf=${Number(vd.confidence)} tally=a${Number(t.approve) || 0}/r${Number(t.reject) || 0}/e${Number(t.escalate) || 0} escalated=${!!vd.escalated}`)
  L.push(`dissent: ${norm(vd.dissent)}`)
  // Founder veto rides INSIDE the signed bytes so a recorded veto cannot be quietly stripped.
  L.push(`veto: ${vd.vetoed ? `${norm(vd.vetoedBy)} :: ${norm(vd.vetoReason)}` : 'none'}`)
  return L.join('\n')
}

// The seal/verify run at the ROOT CLI layer (a standalone engine has no root). $RECEIPT =
// canonicalTranscript(rec) on stdin; seal stores the base64url HMAC, verify re-signs + compares.
export function sealCommands() {
  return {
    seal: `printf '%s' "$RECEIPT" | sudo 5dive gate-proof sign`,
    verify: `test "$(printf '%s' "$RECEIPT" | sudo 5dive gate-proof sign)" = "$STORED_DIGEST"`,
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

  // Verdict. Named-council (convene/standing): DETERMINISTIC tally over the current roster +
  // a narrative-only chair + founder veto. Gate/verifier/node (P1/P2) keep their ported
  // chair-synthesized verdict + action map.
  let verdict
  if (role === 'convene' || role === 'standing') {
    const counted = tallyVotes(votes, {
      decisionClass: input.decisionClass || (input.bench && input.bench.decisionClass) || 'ordinary',
      policy: input.policy,
      threshold: input.threshold != null ? input.threshold : (input.bench && input.bench.threshold),
      thresholdRule: input.thresholdRule || (input.bench && input.bench.thresholdRule),
      seatCount: seats.length,
    })
    const narr = await chairNarrative(modelCall, question, votes)
    verdict = {
      recommendation: counted.recommendation, tally: counted.tally, threshold: counted.threshold,
      seatCount: counted.seatCount, confidence: narr.confidence, dissent: narr.dissent,
      escalated: counted.escalated, brief: counted.escalated ? narr.brief : '',
    }
    verdict = applyFounderVeto(verdict, input.veto)
  } else {
    verdict = await chair(modelCall, role, input, question, votes, isNode)
  }
  return finish(role, input, { question, mode, seats, guardrail: guardTarget ? { forceEscalate: false, reason: '' } : null, convened: true, takes, votes, verdict })
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
    }
    out.receipt = { canonical: canonicalTranscript(rec), ...sealCommands() }
  }
  return out
}
