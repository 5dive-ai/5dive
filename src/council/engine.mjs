// The Council — standalone deliberation engine (CNCL-6, v0.11). Seats call the model API
// directly via the injectable `modelCall` adapter (Anthropic Messages shape by default, a
// {baseUrl,model,apiKey} config seam for a BYO/OpenRouter key later). No Workflow harness,
// no `agent()` global. Invariant: a council NEVER self-clears a hard-gate class (tier>=2 or
// a human-only type) — it escalates, fail-closed on a missing tier.

import { createHash, generateKeyPairSync, sign as edSign, verify as edVerify, createPrivateKey, createPublicKey } from 'node:crypto'
import fs from 'node:fs'

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

// (P1) GATE-CLEAR: council verdict -> clear the gate, or bump to a human. Never self-clears.
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

// (P2a) LOOP VERIFIER: approve -> done | reject -> reject --feedback (stays in the loop) | escalate -> human.
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
  // Re-file the SAME type (never downgrade a human-only type to `decision` — see the module note above).
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

// (P3.1b) THE default Council: a self-governed standing body, one vote each. Seat count is
// UNBOUNDED and the roster is MUTABLE (addSeat/removeSeat, gated at the CLI layer by a real
// convene). These 5 are the STARTING membership, not a cap or a fixed roster.
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

// (CNCL-16) SEAT ID vs REGISTRY AGENT. A seat `id` is a PERSONA; `5dive agent ask` dispatches to
// a REGISTRY NAME, not always the same string (persona 'theo' is the 'marketing' agent). A seat
// MAY carry an explicit `agent` (canonical, wins); else this alias map; else the id IS the name.
export const SEAT_AGENT_ALIAS = { theo: 'marketing', lilbro: 'creative' }
export function resolveSeatAgent(seat) {
  if (!seat) return ''
  if (typeof seat === 'string') return SEAT_AGENT_ALIAS[seat] || seat
  if (seatIsHuman(seat)) return ''   // (DIVE-1563) a human seat is a principal, never dispatched as a registry agent
  if (seat.agent && typeof seat.agent === 'string') return seat.agent
  return SEAT_AGENT_ALIAS[seat.id] || seat.id
}

// (DIVE-1563) HUMAN-AS-SEAT SCHEMA. A council seat MAY be a human principal rather than a registry
// agent — marked `{ kind: 'human' }` (or `human: true`) with a chat/principal binding naming which
// Telegram chat the ballot goes to + whose allowFrom the tap is authenticated against (DIVE-1564
// branches on seatIsHuman to emit a ballot instead of an agent-directed ask). PURELY ADDITIVE +
// back-compat: a bare-string or existing {id, agent?, lens?} seat is NEVER human, needs zero
// migration, and serializes byte-identical (canonicalGenesis/canonicalMotion seal only id/chair/lens).
export function seatIsHuman(seat) {
  return !!seat && typeof seat === 'object' && (seat.kind === 'human' || seat.human === true)
}
// The chat/principal a human seat's ballot is delivered to + authenticated against. An explicit
// `chat` (a resolved tg chat/user id) wins; else a resolvable `principal` string (e.g. 'human:main')
// the bash/plugin layer resolves via the DIVE-1546 founder resolver. Returns '' for a non-human OR an
// unbound human seat — dispatch (DIVE-1564) must fail closed on '' and never silently drop the ballot.
export function resolveSeatChat(seat) {
  if (!seatIsHuman(seat)) return ''
  if (seat.chat != null && String(seat.chat).trim()) return String(seat.chat).trim()
  if (seat.principal && typeof seat.principal === 'string' && seat.principal.trim()) return seat.principal.trim()
  return ''
}
// The extra record fields a HUMAN seat carries beyond {id,lens,chair}. Empty {} for an agent seat, so
// spreading it into a seat projection is a no-op for all-agent rosters (seal + JSON both unchanged).
// Applied at every seat->record projection (addSeat + genesis/motion/bench serializers) so a promoted
// human seat keeps its marker across reloads instead of silently reverting to an agent.
export function humanSeatFields(seat) {
  if (!seatIsHuman(seat)) return {}
  const f = { kind: 'human' }
  const chat = resolveSeatChat(seat)
  if (chat) f.chat = chat
  return f
}
export const DEFAULT_THRESHOLD = 3   // default flat pass-threshold; overridable per bench

// (P3.1b2) TIERED THRESHOLD POLICY. Per decision-CLASS pass rule + quorum, all config. A rule is
// 'flat' (fixed N), 'majority' (floor(seats/2)+1), or 'fraction' (ceil(value*seats), e.g. 2/3).
// `quorum` = how many CURRENT seats must vote for the result to count. This map is the single knob.
export const THRESHOLD_POLICY = {
  ordinary:       { rule: 'majority',            quorum: 'majority' },
  promote:        { rule: 'majority',            quorum: 'majority' },
  demote:         { rule: 'fraction', value: 2 / 3, quorum: 'majority' },
  expel:          { rule: 'fraction', value: 2 / 3, quorum: 'majority' },
  constitutional: { rule: 'fraction', value: 2 / 3, quorum: 'all', requireQuorum: true },
}

// CNCL-14 — constitution-as-data. Missing or malformed files fall back to these
// exact pre-constitution values; a valid constitution.yaml may replace them per org.
export const DEFAULT_HARD_GATE_CLASSES = {
  spend_billing: 'spend|billing|invoice|charge|payment|refund|subscription|price|pricing|\\$[0-9]|€[0-9]',
  public_comms: 'publish|public post|announce|launch post|press|customer email|email customers|newsletter|blast',
  secrets: 'secret|credential|api key|token|password',
  destructive: 'delete|destroy|teardown|wipe|purge|drop[^.]{0,20}table|truncate|irreversible|revoke|dns|domain transfer',
}
export const DEFAULT_HARD_GATE_RX = Object.values(DEFAULT_HARD_GATE_CLASSES).join('|')

// CNCL-15 — the digest embedded in a sealed genesis/amendment record is a plain content hash of
// the constitution.yaml bytes. Its integrity comes from riding INSIDE the root-sealed, hash-chained record
// (the file is forgeable, the chain is not). bash computes the on-disk digest with `sha256sum` for
// genesis/amend/verify so every realm agrees; this JS mirror is for the unit tests + cli fallback.
export function digestConstitution(text) {
  return createHash('sha256').update(String(text == null ? '' : text), 'utf8').digest('hex')
}

// CNCL-15 — constitution-drift check (pure). `sealedDigest` = the digest sealed in the newest
// genesis/amendment record ('' if the lineage predates constitution-as-data); `liveDigest` = the
// hash of the on-disk constitution.yaml ('' if the file is missing). FAILS CLOSED: a sealed digest with a
// missing or mismatched live file is drift — a drifted constitution is NOT enforced, convene
// escalates, and verify fails. Same digest realm on both sides (bash sha256sum, or this JS mirror).
export function constitutionDriftCheck({ sealedDigest, liveDigest }) {
  const sealed = String(sealedDigest || '')
  const live = String(liveDigest || '')
  if (!sealed) return { drifted: false, reason: 'no sealed constitution digest (pre-constitution-as-data lineage)' }
  if (!live) return { drifted: true, reason: 'a constitution digest is sealed in the chain but constitution.yaml is missing (fail-closed)' }
  if (sealed !== live) return { drifted: true, reason: `constitution.yaml digest ${live.slice(0, 12)}… does not match the sealed ${sealed.slice(0, 12)}… — an unsanctioned edit (amend via a constitutional-class council motion, do not hand-edit)` }
  return { drifted: false, reason: 'the live constitution.yaml matches the sealed constitution digest' }
}

// CNCL-15 — the v0 constitution `council init` seeds. It is the HUMAN-READABLE projection of the
// built-in DEFAULT_CONSTITUTION: round-trips back through parse+normalize to the exact defaults, so
// its sealed digest is a meaningful baseline. Single-quoted regex values survive the frontmatter
// parser byte-for-byte (no backslash processing). Amend it ONLY via `5dive council amend`.
export function renderConstitutionV0() {
  const c = DEFAULT_CONSTITUTION
  const gates = Object.entries(c.hardGates)
    .map(([k, v]) => `  ${k}: '${String(v).replace(/'/g, "''")}'`).join('\n')
  // DIVE-1701 — single-agent-first-class ordering: the GUARDRAILS a solo user edits
  // (hard_gates / ship / comms) come FIRST; the Council governance keys come LAST, clearly
  // demarcated + commented as OPTIONAL and dormant so a one-agent user never feels a company
  // is forced on them. ONE schema for both `constitution init` (unsealed seed) and `council
  // init` (sealed genesis) — key ORDER is cosmetic to the parser, so this round-trips to the
  // exact defaults either way.
  return `# 5dive company constitution (v0) — governance-as-DATA, not hardcode.
# This file is the human-readable PROJECTION of your governance policy. On its own it is
# forgeable (anyone with fs write); the AUTHORITY is the sealed digest: once sealed, enforcement
# checks this file's digest against the sealed baseline and FAILS CLOSED on drift (a drifted
# constitution is not enforced). After it is sealed, edit ONLY through:
#   · solo (no Council):  sudo 5dive constitution edit          (direct-seal, no convene)
#   · a multi-seat Council: sudo 5dive council amend --file=…    (2/3 + full quorum + founder veto)
#
# ===================================================================================
# GUARDRAILS — the machine-enforced policy. This is what a solo user edits.
# ===================================================================================
#
# hard_gates: named POSIX-ERE classes. Any content matching a class is forced through a human
# gate before it can proceed. Add/rename/rewrite classes freely; the values are DATA.
hard_gates:
${gates}
#
# ship: release guardrails (e.g. require_ci: true). Empty = no extra ship gate beyond hard_gates.
ship:
#
# comms: outbound-comms guardrails (e.g. public_requires_human: true). Empty = defaults.
comms:
#
# ===================================================================================
# COUNCIL — OPTIONAL, and DORMANT until you convene one.
# ===================================================================================
# Solo users can ignore everything below: these keys have NO effect until you run
# \`5dive council init\` to seed a multi-agent Council. They are seeded here (not hidden) so the
# upgrade path is visible without being forced. Vote thresholds, quorum, and the founder-veto
# window are DATA another org forks and rewrites for itself.
council:
  bench: ${c.council.bench}
quorum: ${c.quorum}
veto:
  hold_secs: ${c.veto.holdSecs}
  posthoc_secs: ${c.veto.posthocSecs}
# thresholds: per-class vote rules — defaults apply when omitted. Uncomment under a real Council
# to override, e.g.:
#   thresholds:
#     constitutional: { rule: fraction, value: 2/3, quorum: all, require_quorum: true }
`
}

export const DEFAULT_CONSTITUTION = {
  council: { bench: 'council' },
  quorum: 'majority',
  thresholds: THRESHOLD_POLICY,
  veto: { principals: [], principal: '', holdSecs: 900, posthocSecs: 172800 },
  hardGates: DEFAULT_HARD_GATE_CLASSES,
  hardGateRegex: DEFAULT_HARD_GATE_RX,
  ship: {},
  comms: {},
}

function yamlScalar(raw) {
  const s = String(raw).trim()
  if (!s) return {}
  if (s.startsWith('"') && s.endsWith('"')) return JSON.parse(s)
  if (s.startsWith("'") && s.endsWith("'")) return s.slice(1, -1).replace(/''/g, "'")
  if (s.startsWith('[') && s.endsWith(']')) {
    const inner = s.slice(1, -1).trim()
    return inner ? inner.split(',').map(x => yamlScalar(x.trim())) : []
  }
  if (/^(true|false)$/i.test(s)) return s.toLowerCase() === 'true'
  if (/^-?[0-9]+(?:\.[0-9]+)?$/.test(s)) return Number(s)
  if (/^(null|~)$/i.test(s)) return null
  return s
}

function stripYamlComment(line) {
  let single = false, double = false
  for (let i = 0; i < line.length; i++) {
    const c = line[i]
    if (c === "'" && !double) single = !single
    else if (c === '"' && !single && line[i - 1] !== '\\') double = !double
    else if (c === '#' && !single && !double && (i === 0 || /\s/.test(line[i - 1]))) return line.slice(0, i).trimEnd()
  }
  return line
}

// Deliberately small pure-YAML parser: mappings + scalar/inline-array
// values are the whole enforced v0 schema. Unsupported list/object syntax fails
// closed to defaults rather than being partially interpreted.
export function parseConstitutionFrontmatter(text) {
  const lines = String(text || '').replace(/\r\n/g, '\n').split('\n')
  const root = {}
  const stack = [{ indent: -1, value: root }]
  for (const original of lines) {
    if (!original.trim() || original.trimStart().startsWith('#')) continue
    if (original.includes('\t')) throw new Error('tabs are not allowed in constitution YAML')
    const indent = original.length - original.trimStart().length
    if (indent % 2) throw new Error('constitution YAML indentation must use two spaces')
    const line = stripYamlComment(original.trim())
    if (!line) continue
    if (line.startsWith('- ')) throw new Error('use inline arrays in constitution v0')
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_-]*):(?:\s+(.*))?$/)
    if (!m) throw new Error(`unsupported constitution YAML: ${line}`)
    while (stack.length > 1 && stack[stack.length - 1].indent >= indent) stack.pop()
    const parent = stack[stack.length - 1]
    if (indent > parent.indent + 2) throw new Error('constitution YAML skipped an indentation level')
    const key = m[1]
    if (['__proto__', 'prototype', 'constructor'].includes(key)) throw new Error('unsafe constitution key')
    if (Object.hasOwn(parent.value, key)) throw new Error(`duplicate constitution key: ${key}`)
    if (m[2] == null || m[2] === '') {
      parent.value[key] = {}
      stack.push({ indent, value: parent.value[key] })
    } else {
      parent.value[key] = yamlScalar(m[2])
    }
  }
  return root
}

// Parse a fraction threshold into an exact ratio. Accepts 'a/b' (e.g. '2/3' -> 0.666…) or a
// bare 0<x<=1 number. Exact fractions dodge the truncated-decimal footgun: 0.667 rounds up
// (ceil(0.667*6)=5) where true 2/3 gives 4 on a 6-seat council. Returns NaN for non-fractions.
const FRACTION_RX = /^([1-9][0-9]*)\/([1-9][0-9]*)$/
function fractionValue(raw) {
  const frac = String(raw).trim().match(FRACTION_RX)
  return frac ? Number(frac[1]) / Number(frac[2]) : Number(raw)
}

function thresholdSpec(value, base, globalQuorum) {
  const out = { ...base }
  if (typeof value === 'string' || typeof value === 'number') {
    const v = String(value).trim()
    const frac = v.match(FRACTION_RX)
    if (frac) { out.rule = 'fraction'; out.value = Number(frac[1]) / Number(frac[2]); delete out.threshold }
    else if (v === 'majority') { out.rule = 'majority'; delete out.value; delete out.threshold }
    else if (v === 'all') { out.rule = 'fraction'; out.value = 1; delete out.threshold }
    else if (/^[1-9][0-9]*$/.test(v)) { out.rule = 'flat'; out.threshold = Number(v); delete out.value }
    else throw new Error(`invalid threshold: ${v}`)
  } else if (value && typeof value === 'object' && !Array.isArray(value)) {
    const unknown = Object.keys(value).filter(k => !['rule', 'threshold', 'value', 'quorum', 'require_quorum', 'requireQuorum'].includes(k))
    if (unknown.length) throw new Error(`unknown threshold field(s): ${unknown.join(', ')}`)
    if (value.rule != null) {
      const rule = String(value.rule)
      if (!['majority', 'fraction', 'flat'].includes(rule)) throw new Error(`invalid threshold rule: ${rule}`)
      out.rule = rule
    }
    if (value.threshold != null) { out.rule = 'flat'; out.threshold = Number(value.threshold); delete out.value }
    if (value.value != null) {
      const n = fractionValue(value.value)
      if (!Number.isFinite(n) || n <= 0 || n > 1) throw new Error(`invalid threshold fraction: ${value.value}`)
      out.rule = 'fraction'; out.value = n; delete out.threshold
    }
    if (value.quorum != null) out.quorum = value.quorum
    if (value.require_quorum != null) {
      if (typeof value.require_quorum !== 'boolean') throw new Error('require_quorum must be true or false')
      out.requireQuorum = value.require_quorum
    }
    if (value.requireQuorum != null) {
      if (typeof value.requireQuorum !== 'boolean') throw new Error('requireQuorum must be true or false')
      out.requireQuorum = value.requireQuorum
    }
  } else throw new Error('threshold must be a scalar or mapping')
  if (out.quorum == null) out.quorum = globalQuorum
  if (out.rule === 'fraction' && (!Number.isFinite(Number(out.value)) || Number(out.value) <= 0 || Number(out.value) > 1)) throw new Error('fraction threshold needs value >0 and <=1')
  if (out.rule === 'flat' && (!Number.isInteger(Number(out.threshold)) || Number(out.threshold) < 1)) throw new Error('flat threshold needs a positive integer')
  return out
}

function quorumSpec(value) {
  if (typeof value === 'number' && Number.isInteger(value) && value >= 0) return value
  const s = String(value)
  if (['majority', 'all', 'none'].includes(s)) return s
  if (/^[0-9]+$/.test(s)) return Number(s)
  throw new Error(`invalid quorum: ${s}`)
}

export function normalizeConstitution(raw = {}) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('constitution frontmatter must be a mapping')
  const unknownTop = Object.keys(raw).filter(k => !['council', 'quorum', 'thresholds', 'veto', 'hard_gates', 'ship', 'comms'].includes(k))
  if (unknownTop.length) throw new Error(`unknown constitution field(s): ${unknownTop.join(', ')}`)
  if (raw.council != null && (typeof raw.council !== 'object' || Array.isArray(raw.council))) throw new Error('council must be a mapping')
  const council = raw.council || {}
  const unknownCouncil = Object.keys(council).filter(k => k !== 'bench')
  if (unknownCouncil.length) throw new Error(`unknown council field(s): ${unknownCouncil.join(', ')}`)
  if (council.bench != null && (typeof council.bench !== 'string' || !council.bench.trim())) throw new Error('council.bench must be a non-empty string')
  const globalQuorum = quorumSpec(raw.quorum == null ? DEFAULT_CONSTITUTION.quorum : raw.quorum)
  const thresholds = {}
  if (raw.thresholds != null && (typeof raw.thresholds !== 'object' || Array.isArray(raw.thresholds))) throw new Error('thresholds must be a mapping')
  const configured = raw.thresholds || {}
  const unknownClasses = Object.keys(configured).filter(k => !Object.hasOwn(THRESHOLD_POLICY, k))
  if (unknownClasses.length) throw new Error(`unknown threshold class(es): ${unknownClasses.join(', ')}`)
  for (const cls of Object.keys(THRESHOLD_POLICY)) {
    thresholds[cls] = thresholdSpec(Object.hasOwn(configured, cls) ? configured[cls] : THRESHOLD_POLICY[cls], THRESHOLD_POLICY[cls], globalQuorum)
    const classValue = configured[cls]
    const classHasQuorum = classValue && typeof classValue === 'object' && Object.hasOwn(classValue, 'quorum')
    thresholds[cls].quorum = quorumSpec(thresholds[cls].quorum)
    if (raw.quorum != null && cls !== 'constitutional' && !classHasQuorum) thresholds[cls].quorum = globalQuorum
  }
  if (raw.veto != null && (typeof raw.veto !== 'object' || Array.isArray(raw.veto))) throw new Error('veto must be a mapping')
  const veto = raw.veto || {}
  const unknownVeto = Object.keys(veto).filter(k => !['principal', 'principals', 'hold_secs', 'posthoc_secs'].includes(k))
  if (unknownVeto.length) throw new Error(`unknown veto field(s): ${unknownVeto.join(', ')}`)
  if (veto.principal != null && typeof veto.principal !== 'string') throw new Error('veto.principal must be a string')
  if (veto.principals != null && (!Array.isArray(veto.principals) || veto.principals.some(x => typeof x !== 'string'))) throw new Error('veto.principals must be an inline string array')
  if (veto.principal && veto.principals) throw new Error('use veto.principal or veto.principals, not both')
  const principals = Array.isArray(veto.principals) ? veto.principals : (veto.principal ? [veto.principal] : [])
  const seconds = (v, fallback, field) => {
    if (v == null) return fallback
    if (!Number.isInteger(v) || v < 0) throw new Error(`${field} must be a non-negative integer`)
    return v
  }
  let hardGates = DEFAULT_CONSTITUTION.hardGates
  let hardGateRegex = DEFAULT_HARD_GATE_RX
  if (Object.hasOwn(raw, 'hard_gates')) {
    if (!raw.hard_gates || typeof raw.hard_gates !== 'object' || Array.isArray(raw.hard_gates)) throw new Error('hard_gates must be a mapping')
    hardGates = Object.fromEntries(Object.entries(raw.hard_gates).map(([k, v]) => {
      if (typeof v !== 'string') throw new Error(`hard_gates.${k} must be a regex string`)
      if (/\(\?|\\[bBdDsSwW]|\\[1-9]/.test(v)) throw new Error(`hard_gates.${k} uses syntax outside POSIX ERE`)
      return [k, v]
    }))
    hardGateRegex = Object.values(hardGates).filter(Boolean).map(x => `(${x})`).join('|') || 'a^'
    new RegExp(hardGateRegex, 'i')
  }
  for (const section of ['ship', 'comms']) {
    if (raw[section] != null && (typeof raw[section] !== 'object' || Array.isArray(raw[section]))) throw new Error(`${section} must be a mapping`)
  }
  return {
    council: { bench: String(council.bench || DEFAULT_CONSTITUTION.council.bench) },
    quorum: globalQuorum,
    thresholds,
    veto: {
      principals,
      principal: principals[0] || '',
      holdSecs: seconds(veto.hold_secs, DEFAULT_CONSTITUTION.veto.holdSecs, 'veto.hold_secs'),
      posthocSecs: seconds(veto.posthoc_secs, DEFAULT_CONSTITUTION.veto.posthocSecs, 'veto.posthoc_secs'),
    },
    hardGates, hardGateRegex,
    ship: raw.ship && typeof raw.ship === 'object' ? raw.ship : {},
    comms: raw.comms && typeof raw.comms === 'object' ? raw.comms : {},
  }
}

export function loadConstitution(path, readFile = p => fs.readFileSync(p, 'utf8')) {
  if (!path) return { ...normalizeConstitution({}), source: 'defaults', path: '', valid: true, error: null }
  try {
    if (!fs.existsSync(path)) return { ...normalizeConstitution({}), source: 'defaults', path, valid: true, error: null }
    return { ...normalizeConstitution(parseConstitutionFrontmatter(readFile(path))), source: 'file', path, valid: true, error: null }
  } catch (e) {
    return { ...normalizeConstitution({}), source: 'defaults', path, valid: false, error: String(e && e.message || e) }
  }
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
// can't decide -> escalate), then passes iff approve-count reaches the class threshold; not a
// pass is a reject unless escalate is the plurality. The chair LLM only narrates — PASS/FAIL is
// an auditable count over the current roster. opts.threshold/thresholdRule override the class policy.
export function tallyVotes(votes, opts = {}) {
  // CNCL-11 RECUSAL: the subject of a promote/demote motion does not vote — its seat is dropped
  // from BOTH the quorum base and the threshold base, so the vote runs over the remaining seats.
  const recuse = new Set([].concat(opts.recuse || []).filter(Boolean).map(String))
  const counted = (votes || []).filter(v => !recuse.has(String(v.seat)))
  const tally = { approve: 0, reject: 0, escalate: 0 }
  for (const v of counted) { if (tally[v.vote] != null) tally[v.vote]++ }
  let seatCount = opts.seatCount || (votes || []).length
  if (recuse.size) seatCount = Math.max(1, seatCount - recuse.size)
  // CNCL-11 CONSTITUTIONAL AUTO-CLASS: a motion touching a governance param is classified in
  // CODE, so a caller can never run a rule change under the ordinary bar by mislabelling it.
  const cls = opts.decisionClass || (opts.motion ? classifyMotion(opts.motion) : 'ordinary')
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
  return { recommendation, tally, threshold, seatCount, quorum, quorumMet, votesCast, decisionClass: cls, recused: [...recuse], escalated: recommendation === 'escalate' }
}

// (P3.1e) SELF-GOVERNANCE — pure roster mutations. The CLI gates each behind a real council
// quorum vote (a convene that must pass); these just produce the new, de-duplicated roster.
export function addSeat(seats, seat) {
  const s = typeof seat === 'string' ? { id: seat } : seat
  if (!s || !s.id) throw new Error('addSeat: seat needs an id')
  if ((seats || []).some(x => x.id === s.id)) return seats.slice()   // already seated (idempotent)
  return [...(seats || []), { id: s.id, lens: s.lens || `${s.id} — council seat.`, ...humanSeatFields(s) }]
}
export function removeSeat(seats, seatId) {
  return (seats || []).filter(x => x.id !== seatId)
}

// CNCL-11 — GOVERNANCE SURFACE: motion classification, recusal, hash-chained lineage
// (promote/demote/roster/log/verify). Pure engine; the CLI+bash own the sudo gate, the root
// seal, and the persisted lineage write.

// Governance PARAMETERS — a motion that changes any of these is constitutional (the hardest
// bar: 2/3 + full quorum + founder-veto-able) and CANNOT run as an ordinary motion.
export const CONSTITUTIONAL_PARAMS = ['threshold', 'quorum', 'veto', 'mode', 'modes']

// CNCL-11: classify a motion IN CODE (never trust a caller-supplied class). Membership motions
// (promote/demote/expel) keep their own class; ANY motion touching a governance param is forced
// to `constitutional` regardless of what it claims; everything else is `ordinary`.
export function classifyMotion(motion = {}) {
  const kind = String(motion.kind || motion.type || '').toLowerCase()
  if (kind === 'promote') return 'promote'
  if (kind === 'demote') return 'demote'
  if (kind === 'expel') return 'expel'
  const raw = motion.params || motion.changes || (motion.param != null ? [motion.param] : [])
  const touched = Array.isArray(raw) ? raw : Object.keys(raw || {})
  if (touched.some(p => CONSTITUTIONAL_PARAMS.includes(String(p).toLowerCase()))) return 'constitutional'
  // CNCL-15: an `amend` motion rewrites the whole constitution — the hardest bar (constitutional).
  if (kind === 'amend' || kind === 'constitutional') return 'constitutional'
  return 'ordinary'
}

// CNCL-11: the seat that must RECUSE for a given motion — the subject of a promote/demote/expel
// (they don't get to vote on their own membership). Returns [] for non-membership motions.
export function recusalFor(motion = {}) {
  const cls = classifyMotion(motion)
  return (['promote', 'demote', 'expel'].includes(cls) && motion.subject) ? [String(motion.subject)] : []
}

// CNCL-11: a promote/demote/constitutional motion runs as a convened vote; on a PASS its outcome
// is written as a lineage record HASH-CHAINED onto the prior lineage head (genesis or the last
// motion) via prevDigest — so the roster's entire history is an append-only, tamper-evident chain
// rooted at genesis. Mirrors buildGenesisRecord's discipline; bash root-seals canonicalMotion().
export function buildMotionRecord({ motion, verdict, seats, threshold, veto, prevDigest, stampedAt, seq, receiptDigest, constitutionDigest }) {
  const cls = classifyMotion(motion)
  if (!['promote', 'demote', 'expel', 'constitutional'].includes(cls)) {
    throw new Error(`buildMotionRecord: '${cls}' is not a governance motion (promote|demote|expel|constitutional)`)
  }
  if (!Array.isArray(seats) || !seats.length) throw new Error('motion record needs the resulting seats')
  // CNCL-15: a constitutional AMEND motion must carry the digest of the constitution it ratifies —
  // that sealed digest is what `council verify` checks the live constitution.yaml against. Fail closed.
  if (cls === 'constitutional' && (motion.kind === 'amend' || motion.type === 'amend') && !constitutionDigest) {
    throw new Error('an amend motion must carry the new constitution digest to seal into the chain (fail-closed)')
  }
  return {
    kind: 'motion',
    version: 1,
    seq: Number(seq) || 0,
    council: 'council',
    motion: {
      class: cls,
      subject: motion.subject != null ? String(motion.subject) : null,
      param: motion.param != null ? String(motion.param) : null,
      to: motion.to != null ? String(motion.to) : null,
    },
    // CNCL-15: '' on a membership motion; the ratified constitution digest on an amend.
    constitutionDigest: constitutionDigest ? String(constitutionDigest) : '',
    outcome: (verdict && verdict.recommendation) || null,
    tally: (verdict && verdict.tally) || null,
    recused: (verdict && verdict.recused) || recusalFor(motion),
    seats: seats.map(s => ({ id: s.id, lens: s.lens, ...(s.chair ? { chair: true } : {}), ...humanSeatFields(s) })),
    threshold: threshold || { rule: 'majority' },
    veto: veto ? { principal: veto.principal, resolved: String(veto.resolved) } : null,
    receiptDigest: receiptDigest || '',   // links the motion to the convene receipt that decided it
    prevDigest: prevDigest || '',
    stampedAt: stampedAt || '',
  }
}

// Deterministic, whitespace-normalized preimage of a motion record — the bytes the ROOT rail
// seals + hash-chains. Same discipline as canonicalGenesis: prevDigest + outcome + the resulting
// roster INSIDE the signed bytes so none can be quietly altered without failing verify.
export function canonicalMotion(rec) {
  const norm = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim()
  const m = rec.motion || {}
  const t = rec.tally || {}
  const L = []
  L.push(`motion: ${norm(rec.council)} v${Number(rec.version) || 1} seq=${Number(rec.seq) || 0}`)
  L.push(`class: ${norm(m.class)}`)
  L.push(`subject: ${norm(m.subject)}`)
  L.push(`param: ${norm(m.param)} -> ${norm(m.to)}`)
  L.push(`outcome: ${norm(rec.outcome)}`)
  L.push(`tally: a${Number(t.approve) || 0}/r${Number(t.reject) || 0}/e${Number(t.escalate) || 0}`)
  L.push(`recused: ${(rec.recused || []).slice().sort().map(norm).join(',')}`)
  L.push(`stampedAt: ${norm(rec.stampedAt)}`)
  L.push(`prevDigest: ${norm(rec.prevDigest)}`)
  L.push(`receiptDigest: ${norm(rec.receiptDigest)}`)
  // CNCL-15: conditional (back-compat) — only an amend record carries + seals a constitution digest.
  if (rec.constitutionDigest) L.push(`constitution: ${norm(rec.constitutionDigest)}`)
  const seats = (rec.seats || []).slice().sort((a, b) => (norm(a.id) < norm(b.id) ? -1 : 1))
  for (const s of seats) L.push(`seat ${norm(s.id)}${s.chair ? ' (chair)' : ''}: ${norm(s.lens)}`)
  const th = rec.threshold || {}
  L.push(`threshold: rule=${norm(th.rule)} value=${th.value != null ? Number(th.value) : ''} flat=${th.threshold != null ? Number(th.threshold) : ''}`)
  L.push(`veto: ${norm(rec.veto && rec.veto.principal)} -> ${norm(rec.veto && rec.veto.resolved)}`)
  return L.join('\n')
}

// CNCL-11: reduce a sealed lineage record to its chain entry — the fields that make the log
// tamper-evident. `digest` is the ROOT seal of the record's canonical bytes (bash computes it).
export function chainEntryOf(rec, digest) {
  return { seq: Number(rec.seq) || 0, prevDigest: rec.prevDigest || '', digest: String(digest || '') }
}

// CNCL-11: verify the append-only lineage CHAIN. `entries` is the ordered log — each entry
// { seq, prevDigest, digest }, digest = the record's root seal. Rooted at genesis (prevDigest
// === ''). Tamper-evidence across the WHOLE log, not one record: an edited record changes its
// digest so the NEXT entry's prevDigest link breaks; a dropped or reordered record breaks the
// prevDigest link and/or seq monotonicity. Returns { ok, head, length } or { ok:false, reason, index }.
export function verifyLineageChain(entries) {
  const list = entries || []
  if (!list.length) return { ok: false, reason: 'empty lineage — no genesis root', index: -1 }
  let prev = ''
  for (let i = 0; i < list.length; i++) {
    const e = list[i]
    if (!e || !e.digest) return { ok: false, reason: `record ${i} has no sealed digest`, index: i }
    if (i === 0) {
      if (e.prevDigest) return { ok: false, reason: 'genesis root must have an empty prevDigest', index: 0 }
    } else {
      if (String(e.prevDigest) !== String(prev)) {
        return { ok: false, reason: `broken chain at record ${i} (seq ${e.seq}): prevDigest ${String(e.prevDigest).slice(0, 12)}… != prior digest ${String(prev).slice(0, 12)}… (edited/dropped/reordered record)`, index: i }
      }
      if (Number(e.seq) <= Number(list[i - 1].seq)) {
        return { ok: false, reason: `non-monotonic seq at record ${i} (${list[i - 1].seq} -> ${e.seq}) — a reordered or dropped record`, index: i }
      }
    }
    prev = e.digest
  }
  return { ok: true, head: prev, length: list.length }
}

// (CNCL-9) AUTHENTICATED FOUNDER VETO — non-blocking OFFER model. A plain `--veto-by` CLI string
// is forgeable (any agent could flip a verdict straight into a signed receipt), so: (1) convene
// never waits for a tap and never flips on a string — on a pass it records a timeboxed OFFER
// (attachVetoOffer) and seals immediately; a no-tap expiry leaves the pass standing. (2) The
// EXERCISE is a separate authenticated event — only a tap confirmed on the tier-2 rail (bash
// validates the nonce->recipient binding) calls exerciseFounderVeto, which flips the pass to
// BLOCKED in a fresh record hash-chained onto the original (never re-sealed in place). (3) Veto is
// FINAL — no council override. Hard-gate classes escalate upstream regardless.

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
// These are the seam CNCL-13/14 redirects to the `constitution.yaml` constitution — until then they read
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
  // CNCL-19: seal the cited precedents INSIDE the signed bytes so the case-law citation (which
  // prior decision was followed vs departed from) cannot be quietly rewritten after the fact. The
  // line is CONDITIONAL — emitted only when precedents were cited — so a no-precedent convene
  // (and every pre-CNCL-19 receipt) seals byte-identically. Order is stabilized by digest so
  // retrieval order never perturbs the seal.
  if (Array.isArray(vd.precedents) && vd.precedents.length) {
    const cited = vd.precedents.slice()
      .sort((a, b) => (norm(a.digest) < norm(b.digest) ? -1 : norm(a.digest) > norm(b.digest) ? 1 : 0))
      .map(p => `${norm(p.digest)}:${norm(p.relation)}`)
    L.push(`precedent: ${cited.join(',')}`)
  }
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

// (CNCL-9 main-gate amendment) FOLD THE VETO SEAL-BINDING INTO THE SIGNED BYTES. The nonce digest
// + executeAfter deadline are minted by bash AT SEAL TIME, i.e. AFTER canonicalTranscript(rec) is
// produced — left on the unsealed wrapper, an edit to either would go undetected by the exercise-
// time re-seal (which only re-signs `.canonical`), letting an attacker exercise the veto with a
// chosen nonce. FIX: append this deterministic line to canonical BEFORE sealing so both are
// covered by the same HMAC; exercise reads them back only from the VERIFIED canonical
// (parseCanonicalVetoBinding), never the raw wrapper. Appended (never interleaved), so a base-only
// receipt (no veto offer) stays byte-identical to CNCL-6/8.
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

// CNCL-8: human-seeded GENESIS roster. The primary council must not bootstrap its OWN membership —
// it is seeded ONCE by a human via `council init` (sudo-gated at the bash layer), which seals the
// genesis record on the ROOT gate-proof rail and hash-chains it into the lineage. Raw bench add/rm
// on `council` is refused (CLI layer) — membership changes only via promote/demote motions.

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
export function buildGenesisRecord({ seats, chair, threshold, veto, prevDigest, stampedAt, forced, seq, constitutionDigest }) {
  if (!Array.isArray(seats) || !seats.length) throw new Error('genesis needs seats')
  if (!veto || !veto.principal) throw new Error('genesis needs a veto principal')
  if (!veto.resolved) throw new Error(`veto principal "${veto.principal}" did not resolve to a real recipient (fail-closed)`)
  return {
    kind: 'genesis',
    version: 1,
    seq: Number(seq) || 0,
    council: 'council',
    seats: seats.map(s => ({ id: s.id, lens: s.lens, ...(s.chair ? { chair: true } : {}), ...humanSeatFields(s) })),
    chair: chair || null,
    threshold: threshold || { rule: 'majority' },
    veto: { principal: veto.principal, resolved: String(veto.resolved) },
    // CNCL-15: the v0 constitution digest, sealed into genesis so `council verify` can detect a
    // later hand-edit of constitution.yaml as drift. '' on a pre-constitution-as-data seed (back-compat).
    constitutionDigest: constitutionDigest ? String(constitutionDigest) : '',
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
  // CNCL-15: seal the constitution digest INTO the genesis bytes. Conditional so a pre-CNCL-15
  // record (no digest) canonicalizes exactly as before and its stored seal still re-verifies.
  if (rec.constitutionDigest) L.push(`constitution: ${norm(rec.constitutionDigest)}`)
  return L.join('\n')
}

// The bench entry a genesis record seeds into the persisted registry — the primary `council`.
export function genesisToBench(rec) {
  return {
    description: DEFAULT_COUNCIL.description,
    mode: DEFAULT_COUNCIL.mode,
    seats: rec.seats.map(s => ({ id: s.id, lens: s.lens, ...(s.chair ? { chair: true } : {}), ...humanSeatFields(s) })),
    threshold: rec.threshold,
    genesis: true,           // marks this bench as motion-governed (raw add/rm refused)
    seededAt: rec.stampedAt,
  }
}

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

// DISPATCH (CNCL-7): convene -> real seated agents. Fleet mode: convene DISPATCHES the question
// to the real seated agents (`5dive agent ask`); each seat votes via its OWN harness + model
// access — no shared council key. LIVENESS: a seat that times out / replies unparseably / throws
// is a recorded ABSTAIN, never silently dropped (one dead agent must not turn 3-of-5 into 3-of-4).
// BLIND FIRST ROUND: a round-1 prompt is a pure function of (seat, question), never another seat's answer.
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

// CNCL-17: seat TRACK RECORD. Score each seat's past votes against the eventual REAL outcome of
// the decided subject, surface in `council roster`, and feed promote/demote briefs (data, not
// vibes). Seat votes are DERIVED by parsing the existing sealed canonical `vote <seat>:` lines —
// no new structured array in the seal, so the tamper-evident format is untouched.

// Extract a task/subject ident (e.g. DIVE-1527, CNCL-17, OSS-32) from free text — used to link a
// HISTORICAL receipt (minted before the `subject` field) to the task whose outcome scores it.
export function subjectFromText(text) {
  const m = String(text == null ? '' : text).match(/\b([A-Z][A-Z0-9]+-\d+)\b/)
  return m ? m[1] : ''
}

// Parse the per-seat votes back OUT of a sealed canonical transcript. Votes seal as
// `vote <seat>: <choice> :: <rationale>` lines (see canonicalTranscript). A1 derives the structured
// votes from these lines instead of persisting a new array INTO the seal. round1/veto/precedent
// lines are ignored (only `vote ` lines match), so adversarial round-2 receipts score their FINAL
// votes (the sealed `vote ` lines are round 2; round1 history seals under a different prefix).
export function parseCanonicalVotes(canonical) {
  const out = []
  for (const line of String(canonical == null ? '' : canonical).split('\n')) {
    const m = line.match(/^vote\s+(\S+):\s+(approve|reject|escalate)\s+::\s+(.*)$/)
    if (m) out.push({ seat: m[1], vote: m[2], rationale: m[3] })
  }
  return out
}

// Score ONE seat vote against the eventual outcome of the decided subject. outcome ∈ {good,bad}.
//   approve + good            => correct (backed a call that landed good)
//   approve + bad             => incorrect (backed a call that went bad)
//   reject/escalate (dissent) + bad  => VINDICATED (the dissent was right)
//   reject/escalate + good    => incorrect (dissented against a good call)
export function scoreSeatVote(vote, outcome) {
  const dissent = vote === 'reject' || vote === 'escalate'
  const good = outcome === 'good'
  const correct = dissent ? !good : good
  return { correct, dissent, vindicated: dissent && !good }
}

// Per-seat calibration across receipts with a KNOWN outcome. receipts:
// [{ subject?, question?, canonical?, votes? }]; outcomes: { [subject]: 'good'|'bad' } (subjects
// with no/pending outcome are skipped — never scored on an undecided task). Votes come from
// `.votes` when present, else are PARSED from `.canonical`; subject from `.subject` else parsed
// from `.question`. Deterministic sort: calibration desc, then volume, then seat id.
export function seatTrackRecord(receipts, outcomes = {}) {
  const acc = new Map()
  let scoredReceipts = 0
  for (const r of receipts || []) {
    if (!r) continue
    const subject = r.subject || subjectFromText(r.question)
    const outcome = subject ? outcomes[subject] : null
    if (outcome !== 'good' && outcome !== 'bad') continue
    const votes = (Array.isArray(r.votes) && r.votes.length) ? r.votes : parseCanonicalVotes(r.canonical)
    if (!votes.length) continue
    scoredReceipts++
    for (const v of votes) {
      const s = acc.get(v.seat) || { seat: v.seat, scored: 0, correct: 0, incorrect: 0, dissents: 0, vindicated: 0 }
      const sc = scoreSeatVote(v.vote, outcome)
      s.scored++; sc.correct ? s.correct++ : s.incorrect++
      if (sc.dissent) s.dissents++
      if (sc.vindicated) s.vindicated++
      acc.set(v.seat, s)
    }
  }
  const seats = [...acc.values()].map(s => ({ ...s, calibration: s.scored ? s.correct / s.scored : 0 }))
    .sort((a, b) => (b.calibration - a.calibration) || (b.scored - a.scored) || (a.seat < b.seat ? -1 : a.seat > b.seat ? 1 : 0))
  return { seats, scoredReceipts }
}

// One-line per-seat summary for `council roster` + motion briefs (data, not vibes).
export function seatTrackRecordBrief(seat, tr) {
  const row = ((tr && tr.seats) || []).find(s => s.seat === seat)
  if (!row || !row.scored) return `${seat}: no scored record yet`
  return `${seat}: ${Math.round(row.calibration * 100)}% calibrated (${row.correct}/${row.scored}` +
    `${row.vindicated ? `, ${row.vindicated} vindicated dissent${row.vindicated > 1 ? 's' : ''}` : ''})`
}

// CNCL-19: council CASE LAW. At convene, the sealed receipt log is searched for prior verdicts on
// related questions; the top hits are injected into every seat ballot as PRECEDENT — history, NOT
// this round's takes, so the blind-first-round invariant is untouched. The verdict then CITES which
// precedents it followed or departed from, so consistency across decisions is auditable.
const PRECEDENT_STOPWORDS = new Set(('the a an and or but for nor of to in on at by with from as is are was ' +
  'were be been being do does did should would could can will shall may might must not no we our us it its ' +
  'this that these those i you he she they them their there here what which who whom how why when where ' +
  'if then than so such about into over under out up down off then more most some any all each').split(/\s+/))

// Tokenize a question/brief into a set of significant, lowercased terms (>=3 chars, no stopwords).
export function precedentTokens(text) {
  const out = new Set()
  for (const raw of String(text == null ? '' : text).toLowerCase().split(/[^a-z0-9]+/)) {
    if (raw.length >= 3 && !PRECEDENT_STOPWORDS.has(raw)) out.add(raw)
  }
  return out
}

// Select the top-k prior decisions relevant to `question` from a candidate pool (each entry:
// {digest, question, recommendation, brief, stampedAt}). Score = count of DISTINCT query terms
// that also appear in the candidate's (question + brief); ties break toward the more RECENT
// decision (lexicographic stampedAt desc, which is chronological for ISO-8601). Score 0 => dropped
// (never inject an unrelated precedent). Deterministic — no clock, no RNG — so it seals identically
// in tests. A self-match guard drops any candidate whose digest equals `selfDigest`.
export function selectPrecedents(question, pool, k = 3, selfDigest = '') {
  const qt = precedentTokens(question)
  if (!qt.size || !Array.isArray(pool) || !pool.length) return []
  const scored = []
  for (const p of pool) {
    if (!p || (selfDigest && p.digest === selfDigest)) continue
    const ct = precedentTokens(`${p.question || ''} ${p.brief || ''}`)
    let score = 0
    for (const t of qt) if (ct.has(t)) score++
    if (score > 0) scored.push({
      digest: String(p.digest || ''), question: String(p.question || ''),
      recommendation: String(p.recommendation || ''), brief: String(p.brief || ''),
      stampedAt: String(p.stampedAt || ''), score,
    })
  }
  scored.sort((a, b) => (b.score - a.score) || (a.stampedAt < b.stampedAt ? 1 : a.stampedAt > b.stampedAt ? -1 : 0))
  return scored.slice(0, k)
}

// Given the decided recommendation and the injected precedents, compute the citation: each
// precedent is either FOLLOWED (same recommendation reached) or DEPARTED (a different call than
// last time). Deterministic + key-free, so it works on the fleet dispatch path with no chair LLM.
export function precedentCitations(recommendation, precedents) {
  return (precedents || []).map(p => ({
    digest: p.digest, question: p.question, priorRecommendation: p.recommendation,
    relation: p.recommendation && p.recommendation === recommendation ? 'followed' : 'departed',
  }))
}

// One-line human summary of the citation for the verdict brief / receipt display.
export function precedentCitationBrief(citations) {
  if (!citations || !citations.length) return ''
  return 'Precedent: ' + citations.map(c =>
    `[${(c.digest || '').slice(0, 8) || 'unsealed'}] ${c.relation}${c.priorRecommendation ? ` (was ${c.priorRecommendation})` : ''}`).join('; ')
}

// The PRECEDENT block injected into a seat ballot (both rounds — it is HISTORY, not a current
// take). Clearly fenced + labelled so a seat weighs prior case law without it being mistaken for
// another seat's live vote.
function precedentBlock(precedents) {
  if (!precedents || !precedents.length) return ''
  const items = precedents.map(p =>
    `- [${(p.digest || '').slice(0, 8) || 'unsealed'}] Q: "${p.question}" -> ${(p.recommendation || 'n/a').toUpperCase()}${p.brief ? ` (${p.brief})` : ''}`).join('\n')
  return `\nPRECEDENT — prior COUNCIL decisions on related questions (case law; this is HISTORY, not another seat's take this round):
${items}
Weigh these. In your rationale, say briefly whether you FOLLOW or DEPART from them and why.`
}

// Build the per-seat dispatch prompt. BLIND-FIRST-ROUND invariant: round-1 output is a pure
// function of (seat, question) and NEVER embeds another seat's take/vote, so no seat anchors on
// another before its own vote is recorded. The rebuttal round (adversarial only, round 2) DOES
// show the round-1 votes and is recorded separately. Injected PRECEDENT (ctx.precedents) is
// history, not a current take, so it does NOT break the blind round.
export function seatPrompt(seat, ctx = {}) {
  const round = ctx.round || 1
  const q = ctx.question || ''
  const head = `You hold the "${seat.id}" seat on the 5dive Council. Your lens: ${seat.lens || seat.id}.`
  const ask = `Question before the council: "${q}"`
  const fmt = `Reply with brief reasoning, then END with EXACTLY this line and nothing after it:
COUNCIL-VOTE: <approve|reject|escalate> :: <one-sentence rationale>
Escalate ONLY if this genuinely needs a human (money/spend, destructive/irreversible, secrets, or a brand call on a mature product) or the council is hopelessly split.`
  const prec = precedentBlock(ctx.precedents)
  if (round >= 2 && Array.isArray(ctx.priorVotes) && ctx.priorVotes.length) {
    const prior = ctx.priorVotes.map(v => `- ${v.seat}: ${String(v.vote).toUpperCase()} — ${v.rationale}`).join('\n')
    return `${head}
${ask}${prec}
The council's first-round votes:
${prior}
REBUT: find the strongest objection to the leading position, then cast your FINAL vote.
${fmt}`
  }
  return `${head}
${ask}${prec}
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
    // CNCL-11: surface the applied decision class + who recused so the sealed receipt's verdict is
    // self-describing for audit. These are NOT in canonicalTranscript (additive, no seal change).
    decisionClass: counted.decisionClass, recused: counted.recused || [],
    confidence: narr.confidence, dissent: narr.dissent,
    escalated: counted.escalated, brief: counted.escalated ? narr.brief : '',
  }
}

// Narrative-only synthesis for the named council: the chair writes confidence/dissent/
// brief but does NOT decide the recommendation (that's the deterministic tallyVotes count).
const NARRATIVE = { type: 'object', additionalProperties: false, required: ['confidence', 'dissent', 'brief'],
  properties: { confidence: { type: 'number' }, dissent: { type: 'string' }, brief: { type: 'string' } } }

function log(on, msg) { if (on) process.stderr.write(`[council] ${msg}\n`) }

// CNCL-25 (red-team Finding 4): merge the rebuttal (round 2) over the blind round 1 for the FINAL
// tally, instead of replacing round 1 wholesale. A seat's SUBSTANTIVE round-2 vote wins (it revised
// its position after seeing the debate); but a seat that goes SILENT in round 2 (timeout / no reply
// -> abstain) keeps its substantive round-1 vote — rebuttal silence means "position unchanged", not
// "I withdraw my vote". Without this, a seat had to cast twice inside two tight consecutive windows
// for its vote to survive, so partial participation collapsed the tally to cast=0 (2026-07-20
// strategy convene: 2 real votes + a live approve/reject split ERASED by an all-abstain round 2).
// Carried votes are MARKED in the rationale so the sealed receipt shows exactly what was carried;
// round1Votes + rebuttalVotes stay recorded raw alongside the merged `votes`, so the full two-round
// record is auditable. Deterministic + pure (unit-tested). A seat that never cast a substantive vote
// in either round stays an abstain; a convene where every seat re-casts is byte-identical to before.
export function carryForwardVotes(round1Votes, rebuttalVotes) {
  const SUBSTANTIVE = new Set(['approve', 'reject', 'escalate'])
  const r1By = new Map((round1Votes || []).map(v => [String(v.seat), v]))
  return (rebuttalVotes || []).map(r2 => {
    if (r2 && SUBSTANTIVE.has(r2.vote)) return r2                    // re-cast (possibly revised) — use round 2
    const r1 = r1By.get(String(r2 && r2.seat))
    if (r1 && SUBSTANTIVE.has(r1.vote)) {                            // silent in round 2 -> carry round 1 forward
      return { seat: r2.seat, vote: r1.vote, carried: true,
        rationale: `${r1.rationale} [round-1 position carried forward; no rebuttal re-cast]` }
    }
    return r2                                                        // never cast a substantive vote -> abstain stands
  })
}

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
  const { modelCall, seatVote, verbose, role, mode, question } = h
  let { seats } = h
  // CNCL-11: a governance MOTION runs as a convened vote with the SUBJECT recused — the recused
  // seat is not dispatched (it doesn't vote on its own membership) and the class is derived from
  // the motion IN CODE (never a trusted string), so seatCount = full roster minus the recused set.
  const recuse = new Set([].concat(input.recuse || []).filter(Boolean).map(String))
  const fullCount = seats.length
  if (recuse.size) seats = seats.filter(s => !recuse.has(String(s.id)))
  const tallyOpts = {
    decisionClass: input.motion ? undefined : (input.decisionClass || (input.bench && input.bench.decisionClass) || 'ordinary'),
    motion: input.motion,
    recuse: [...recuse],
    policy: input.policy,
    threshold: input.threshold != null ? input.threshold : (input.bench && input.bench.threshold),
    thresholdRule: input.thresholdRule || (input.bench && input.bench.thresholdRule),
    seatCount: fullCount,
  }
  // CNCL-19: search the sealed receipt log for prior decisions on related questions and inject the
  // top hits into every seat ballot as PRECEDENT (history, so the blind round stays blind to
  // CURRENT takes). The verdict then cites which precedents it followed or departed from. The
  // retrieval is deterministic + key-free; the pool is passed in by the CLI (which reads the log).
  const precedents = selectPrecedents(question, input.precedentPool || [], input.precedentK != null ? input.precedentK : 3)
  let round1Votes, finalVotes, rebuttalVotes = null, verdict
  if (seatVote) {
    log(verbose, `dispatching ${seats.length} real seats (blind round 1, ${mode})${precedents.length ? `, ${precedents.length} precedent(s)` : ''}`)
    round1Votes = await dispatchRound(seats, { question, role, mode, round: 1, precedents }, seatVote)
    finalVotes = round1Votes
    if (mode === 'adversarial') {
      log(verbose, `adversarial rebuttal (round 2, recorded separately)`)
      rebuttalVotes = await dispatchRound(seats, { question, role, mode, round: 2, priorVotes: round1Votes, precedents }, seatVote)
      finalVotes = carryForwardVotes(round1Votes, rebuttalVotes)
    }
    const counted = tallyVotes(finalVotes, tallyOpts)
    verdict = buildConveneVerdict(counted, synthesizeNarrative(finalVotes, counted))
  } else {
    // Standalone seam: one modelCall answers each seat. Blind round 1 (seatPrompt embeds NO
    // other seat's take), then an adversarial rebuttal that sees the round-1 votes.
    log(verbose, `convening ${seats.length} seats via the modelCall seam (blind round 1, ${mode})`)
    const askSeam = (s, ctx) => modelCall(seatPrompt(s, ctx), VOTE).then(v => ({ seat: v.seat || s.id, vote: v.vote, rationale: v.rationale }))
    round1Votes = await Promise.all(seats.map(s => askSeam(s, { question, round: 1, precedents })))
    finalVotes = round1Votes
    if (mode === 'adversarial') {
      rebuttalVotes = await Promise.all(seats.map(s => askSeam(s, { question, round: 2, priorVotes: round1Votes, precedents })))
      finalVotes = carryForwardVotes(round1Votes, rebuttalVotes)
    }
    const counted = tallyVotes(finalVotes, tallyOpts)
    const narr = await chairNarrative(modelCall, question, finalVotes)
    verdict = buildConveneVerdict(counted, narr)
  }
  // CNCL-19: attach the deterministic precedent citation to the verdict (followed vs departed) so
  // it surfaces on the receipt/dashboard. Additive on the verdict; sealed via a CONDITIONAL
  // canonical line (present only when precedents were cited — a no-precedent convene stays
  // byte-identical to the pre-CNCL-19 seal).
  if (precedents.length) {
    verdict.precedents = precedentCitations(verdict.recommendation, precedents)
    verdict.precedentCitation = precedentCitationBrief(verdict.precedents)
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

// CNCL-10: per-seat Ed25519 CO-SIGNED VOTES. The CNCL-6 root seal proves the convener recorded
// these bytes, but nothing proves each seat cast its own vote — the convener could forge/edit any
// row before sealing. CNCL-10 closes that: every seat holds its OWN Ed25519 keypair and SIGNS its
// vote AT SOURCE, inside its own harness, before the vote leaves the agent.
//
// REPLAY PROOF: the signed bytes bind the CONVENE ID + QUESTION DIGEST, so a signed vote from an
// old convene fails verification in a new one; the verifier recomputes the expected preimage from
// the CURRENT context, never trusting a vote's self-reported convene/digest.
//
// KEY LIFECYCLE: a keypair is issued at init/promote; the private key is 0600, owner-only
// (never the shared `claude` group, which holds every agent and would leak it). A demote REVOKES
// the key (stamped in the lineage); a revoked seat's vote is rejected even if the signature
// verifies. `council verify` re-checks every seat signature + revocation + the root seal — all
// three must pass for a green receipt.

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
