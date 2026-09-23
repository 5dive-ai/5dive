// The constitution kernel (DIVE-4869). CORE-owned: the one parser for constitution.yaml —
// hard-gate classes, thresholds, veto windows, standing authorities — plus the digests the
// sealed-drift check compares. It lives outside src/council/ because `task need`'s tier-2 floor
// and its lead-clear authority read it on every box, with or without the council deliberation
// engine. engine.mjs re-exports everything here, so council callers see no change and there is
// still exactly ONE parser. Moved verbatim from engine.mjs; edit it here, then re-run
// `node src/council/gen_cmd.mjs` and `node src/constitution/gen_kernel.mjs`.

import { createHash } from 'node:crypto'
import fs from 'node:fs'

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
  spend_billing: 'spend|spending|billing|invoice|invoices|invoiced|charge|charges|charged|charging|payment|payments|refund|refunds|refunded|subscription|subscriptions|price|prices|pricing|\\$[0-9]+|€[0-9]+',
  public_comms: 'publish|publishes|published|publishing|public post|announce|announces|announced|announcing|launch post|press|pressing|customer email|email customers|newsletter|blast|blasts|blasted|blasting',
  secrets: 'secret|secrets|credential|credentials|api key|api keys|token|password|passwords',
  destructive: 'delete|deletes|deleted|deleting|destroy|destroys|destroyed|destroying|teardown|wipe|wipes|wiped|wiping|purge|purges|purged|purging|drop[^.]{0,20}table|truncate|truncated|irreversible|revoke|revokes|revoked|revoking|dns|domain transfer',
}
export const DEFAULT_HARD_GATE_RX = Object.values(DEFAULT_HARD_GATE_CLASSES).join('|')

// DIVE-1702 — the constitution document schema version. `schema_version: 1` (integer) is the
// current, and only, supported version; the field is OPTIONAL and defaults to this when absent, so
// every existing comment-free constitution.yaml stays valid. A document declaring a HIGHER version
// than this CLI understands is rejected (fail-closed) — that agent must upgrade before enforcing an
// unknown schema. This is the single knob a future migration bumps.
export const CONSTITUTION_SCHEMA_VERSION = 1

// CNCL-15 — the digest embedded in a sealed genesis/amendment record is a plain content hash of
// the constitution.yaml bytes. Its integrity comes from riding INSIDE the root-sealed, hash-chained record
// (the file is forgeable, the chain is not). bash computes the on-disk digest with `sha256sum` for
// genesis/amend/verify so every realm agrees; this JS mirror is for the unit tests + cli fallback.
// This is the SOURCE digest (raw bytes) — comment/whitespace edits DO change it, which is exactly
// what the sealed-drift check wants (any hand-edit is drift). For a digest that ignores cosmetic
// churn, see policyDigest below.
export function digestConstitution(text) {
  return createHash('sha256').update(String(text == null ? '' : text), 'utf8').digest('hex')
}

// DIVE-1702 — deterministic serialization for the CANONICAL-POLICY digest: sort object keys at every
// level so key-reordering, comment-only, or whitespace edits to constitution.yaml all serialize to the
// SAME bytes. Pure (no clock/CSPRNG). Arrays keep their order (principal lists are order-significant).
export function canonicalPolicyJSON(v) {
  if (v === null || v === undefined) return 'null'
  if (Array.isArray(v)) return `[${v.map(canonicalPolicyJSON).join(',')}]`
  if (typeof v === 'object') return `{${Object.keys(v).sort().map(k => `${JSON.stringify(k)}:${canonicalPolicyJSON(v[k])}`).join(',')}}`
  return JSON.stringify(v)
}

// DIVE-1702 — the CANONICAL-POLICY digest: sha256 over the NORMALIZED constitution (schema version,
// bench, thresholds, veto, hard-gate classes, ship/comms), NOT the raw file. Two documents that
// differ only in comments, key order, or whitespace produce the same policyDigest — so an audit can
// tell a cosmetic edit (source digest changed, policy digest unchanged) from a real policy change.
// The derived `hardGateRegex` is dropped (it is a pure function of hardGates — including it would
// double-count and is redundant). Accepts either a normalized object or raw frontmatter.
export function policyDigest(normalizedOrRaw) {
  const n = (normalizedOrRaw && Object.hasOwn(normalizedOrRaw, 'hardGates')) ? normalizedOrRaw : normalizeConstitution(normalizedOrRaw)
  const { hardGateRegex, ...policy } = n
  return createHash('sha256').update(canonicalPolicyJSON(policy), 'utf8').digest('hex')
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
# authority: standing authorities held by a NAMED agent (DIVE-2099). EMPTY = nobody holds one,
# which is the default — a fresh org grants nothing until it deliberately amends this in.
#   eng_approval_lead: <agent> — that ONE agent may clear tier-1 ENGINEERING approval gates on
#   its own authority instead of routing them to you. Every other guard still applies (approval
#   type only, tier 1 only, positive engineering classification, hard_gates floor, out-of-scope
#   exclusions). Deliberately NOT derived from the org chart: the chart is agent-writable, so
#   deriving authority from it would let the holder appoint itself. This value is enforced only
#   while the file matches its SEALED digest, so changing who holds it is an amendment, not an
#   edit. Example:
#     authority:
#       eng_approval_lead: main
#   gate_clear_leads: — a BLOCK list (one "  - <agent>" per line, as in the example below;
#   the inline [a, b] form is refused) of the agents allowed to CLEAR an approval/manual/access
#   gate that was ROUTED to them (DIVE-2233). The org chart still decides who a gate is routed
#   TO — that is a notification. This list decides who may clear one, so re-parenting the chart
#   moves the ping and never the authority. EMPTY = nobody may lead-clear and every routed gate
#   falls through to a human, which is the safe default and NOT an outage. Example:
#     authority:
#       gate_clear_leads:
#         - main
#         - marketing
authority:
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
  schemaVersion: CONSTITUTION_SCHEMA_VERSION,
  council: { bench: 'council' },
  quorum: 'majority',
  thresholds: THRESHOLD_POLICY,
  veto: { principals: [], principal: '', holdSecs: 900, posthocSecs: 172800 },
  hardGates: DEFAULT_HARD_GATE_CLASSES,
  hardGateRegex: DEFAULT_HARD_GATE_RX,
  ship: {},
  comms: {},
  // DIVE-2099 — standing authorities held by a named agent. Empty by default: a fresh org
  // grants nobody a standing clear until it deliberately amends this in.
  authority: { engApprovalLead: '', gateClearLeads: [] },
}

function yamlScalar(raw) {
  const s = String(raw).trim()
  if (!s) return {}
  if (s.startsWith('"') && s.endsWith('"')) return JSON.parse(s)
  if (s.startsWith("'") && s.endsWith("'")) return s.slice(1, -1).replace(/''/g, "'")
  if (s.startsWith('[') && s.endsWith(']')) {
    const inner = s.slice(1, -1).trim()
    const arr = inner ? inner.split(',').map(x => yamlScalar(x.trim())) : []
    // DIVE-3493 — remember that this array came from a FLOW sequence. Only
    // `authority.gate_clear_leads` cares (the node-free reader in src/task/need.sh reads a
    // block sequence and refuses a flow one on purpose), but the provenance has to be
    // recorded here because it is gone by the time the normalizer sees a plain array.
    // Non-enumerable so it never reaches JSON output, a digest, or a canonical record.
    Object.defineProperty(arr, 'yamlFlow', { value: true })
    return arr
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

// Deliberately small pure-YAML parser: mappings + scalar/flow-array values plus a BLOCK
// SEQUENCE of plain scalars are the whole enforced v0 schema. Unsupported list/object
// syntax fails closed to defaults rather than being partially interpreted.
//
// DIVE-3493 — the block sequence is here because the node-free authority reader in
// src/task/need.sh reads exactly that shape (and refuses a flow one on purpose, so it
// never grants authority from a syntax it only half-supports). Until this landed the two
// accepted DISJOINT subsets of YAML — this parser threw on `- name` while the reader threw
// away `[a, b]` — so `authority.gate_clear_leads` could not be set through any path, and
// the shipped template's own worked example failed the validator shipping beside it.
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
    if (line === '-' || line.startsWith('- ')) {
      // A sequence entry belongs to the nearest enclosing key. Pop only frames INDENTED
      // DEEPER than this entry: YAML lets a block sequence sit at its key's own indent
      // (`gate_clear_leads:` / `- main` both at 2) as well as one level in, and the
      // reader accepts both, so refusing either would re-open the same asymmetry.
      while (stack.length > 1 && stack[stack.length - 1].indent > indent) stack.pop()
      const frame = stack[stack.length - 1]
      if (!frame.owner) throw new Error('a block sequence must be the value of a key')
      if (!Array.isArray(frame.value)) {
        if (Object.keys(frame.value).length) throw new Error(`constitution key '${frame.key}' holds a mapping and a block sequence`)
        frame.value = frame.owner[frame.key] = []
      }
      const entry = line === '-' ? '' : line.slice(2).trim()
      if (!entry) throw new Error(`empty entry in the block sequence under '${frame.key}'`)
      if (/^([A-Za-z_][A-Za-z0-9_-]*):(\s|$)/.test(entry)) throw new Error(`block sequence entries must be plain scalars, not mappings (under '${frame.key}')`)
      const val = yamlScalar(entry)
      if (val !== null && typeof val === 'object') throw new Error(`block sequence entries must be plain scalars (under '${frame.key}')`)
      frame.value.push(val)
      continue
    }
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_-]*):(?:\s+(.*))?$/)
    if (!m) throw new Error(`unsupported constitution YAML: ${line}`)
    while (stack.length > 1 && stack[stack.length - 1].indent >= indent) stack.pop()
    const parent = stack[stack.length - 1]
    if (Array.isArray(parent.value)) throw new Error(`constitution key '${parent.key}' holds a block sequence and cannot also hold keys`)
    if (indent > parent.indent + 2) throw new Error('constitution YAML skipped an indentation level')
    const key = m[1]
    if (['__proto__', 'prototype', 'constructor'].includes(key)) throw new Error('unsafe constitution key')
    if (Object.hasOwn(parent.value, key)) throw new Error(`duplicate constitution key: ${key}`)
    if (m[2] == null || m[2] === '') {
      parent.value[key] = {}
      stack.push({ indent, value: parent.value[key], owner: parent.value, key })
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
  const unknownTop = Object.keys(raw).filter(k => !['schema_version', 'council', 'quorum', 'thresholds', 'veto', 'hard_gates', 'ship', 'comms', 'authority'].includes(k))
  if (unknownTop.length) throw new Error(`unknown constitution field(s): ${unknownTop.join(', ')}`)
  // DIVE-1702: OPTIONAL document version. Absent -> current (back-compat with every existing file).
  // Must be a positive integer; a version NEWER than this CLI understands is refused (fail-closed) so
  // an out-of-date agent never enforces a schema it cannot fully parse.
  let schemaVersion = CONSTITUTION_SCHEMA_VERSION
  if (Object.hasOwn(raw, 'schema_version')) {
    const sv = raw.schema_version
    if (!Number.isInteger(sv) || sv < 1) throw new Error('schema_version must be a positive integer')
    if (sv > CONSTITUTION_SCHEMA_VERSION) throw new Error(`constitution schema_version ${sv} is newer than this CLI supports (max ${CONSTITUTION_SCHEMA_VERSION}); upgrade 5dive to enforce it`)
    schemaVersion = sv
  }
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
  if (veto.principals != null && (!Array.isArray(veto.principals) || veto.principals.some(x => typeof x !== 'string'))) throw new Error('veto.principals must be a list of strings')
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
  // DIVE-2099 — `authority`: standing authorities held by a NAMED agent, granted by the
  // constitution itself rather than derived from the org chart (which is agent-writable, so
  // deriving from it lets the beneficiary self-grant). Absent/empty = nobody holds it; there is
  // no "everyone" value and no fallback. Bash reads this field node-free on the gate path and
  // trusts it ONLY when the file still matches the sealed digest, so the enforced value can only
  // change through a constitutional-class amendment.
  if (raw.authority != null && (typeof raw.authority !== 'object' || Array.isArray(raw.authority))) throw new Error('authority must be a mapping')
  const authority = raw.authority || {}
  const AUTHORITY_KEYS = ['eng_approval_lead', 'gate_clear_leads']
  const unknownAuthority = Object.keys(authority).filter(k => !AUTHORITY_KEYS.includes(k))
  if (unknownAuthority.length) throw new Error(`unknown authority field(s): ${unknownAuthority.join(', ')}`)
  if (authority.eng_approval_lead != null && typeof authority.eng_approval_lead !== 'string') throw new Error('authority.eng_approval_lead must be a string')
  const engApprovalLead = String(authority.eng_approval_lead || '').trim()
  // The same shape bash enforces (`_GATE_STANDING_LEAD_NAME_RX`): a plain agent name, so the
  // value stays a name comparison. `human:x`, `*`, `all`, paths and metacharacters are rejected
  // here rather than silently ignored at enforcement time.
  const AGENT_NAME_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/
  if (engApprovalLead && !AGENT_NAME_RE.test(engApprovalLead)) throw new Error('authority.eng_approval_lead must be a plain agent name (a-z0-9, _ or -, max 32)')
  // DIVE-2233 — `gate_clear_leads`: the agents permitted to exercise the ROUTED lead-clear
  // (DIVE-1182/1243) on an approval/manual/access gate. A LIST, not a scalar, because routing is
  // per-filer: a real org has several managers who each legitimately clear their own reports'
  // gates, and collapsing that to one name would break every branch of the chart but one.
  //
  // This does NOT decide who a gate is ROUTED to — the org chart still does that, and routing is
  // a notification concern. It decides who may CLEAR. That split is the whole fix: an agent that
  // sudo-writes itself into a builder's `reports_to` still receives the ping and still cannot
  // clear, because the name it just gave itself is not in these sealed bytes.
  if (authority.gate_clear_leads != null && !Array.isArray(authority.gate_clear_leads)) throw new Error('authority.gate_clear_leads must be a list of agent names')
  // DIVE-3493 — and it must be a BLOCK sequence, because bash is what enforces it. The
  // node-free reader refuses a flow sequence deliberately, so a document that NAMES holders
  // inline validates, seals, and then denies every name it lists — emitting an audit reason
  // (`no-gate-clear-leads-key`) indistinguishable from "never sealed". Refusing the shape
  // here is what keeps the sealed bytes and the enforced authority the same document.
  // An EMPTY `[]` is exempt on purpose: it grants nobody under either reader, it is the
  // documented safe default, and reddening it would fail a doc that is already correct.
  if (Array.isArray(authority.gate_clear_leads) && authority.gate_clear_leads.yamlFlow && authority.gate_clear_leads.length) {
    throw new Error('authority.gate_clear_leads must be written as a block sequence (one "  - name" per line), not inline [a, b] — the enforcing reader does not accept the inline form and would deny every name listed')
  }
  const gateClearLeads = (authority.gate_clear_leads || []).map(v => {
    if (typeof v !== 'string') throw new Error('authority.gate_clear_leads entries must be strings')
    return v.trim()
  }).filter(v => v !== '')
  for (const n of gateClearLeads) {
    if (!AGENT_NAME_RE.test(n)) throw new Error(`authority.gate_clear_leads entry '${n}' must be a plain agent name (a-z0-9, _ or -, max 32)`)
  }
  if (new Set(gateClearLeads).size !== gateClearLeads.length) throw new Error('authority.gate_clear_leads must not repeat a name')
  return {
    schemaVersion,
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
    authority: { engApprovalLead, gateClearLeads },
  }
}

export function loadConstitution(path, readFile = p => fs.readFileSync(p, 'utf8')) {
  // DIVE-1702: every result carries schemaVersion (via the normalized object) plus two digests:
  //   sourceDigest — sha256 of the raw file bytes (cosmetic edits DO churn it; '' when on defaults)
  //   policyDigest — sha256 of the normalized policy (cosmetic edits do NOT churn it)
  // so a caller can tell an effective-policy change from a comment-only edit.
  const withDigests = (normalized, text, extra) => {
    const enforced = { ...normalized, ...extra }
    return { ...enforced, sourceDigest: digestConstitution(text), policyDigest: policyDigest(normalized) }
  }
  if (!path) return withDigests(normalizeConstitution({}), '', { source: 'defaults', path: '', valid: true, error: null })
  try {
    if (!fs.existsSync(path)) return withDigests(normalizeConstitution({}), '', { source: 'defaults', path, valid: true, error: null })
    const text = readFile(path)
    return withDigests(normalizeConstitution(parseConstitutionFrontmatter(text)), text, { source: 'file', path, valid: true, error: null })
  } catch (e) {
    // Fail closed to defaults; the enforced policy IS the defaults, so its digests describe defaults.
    return withDigests(normalizeConstitution({}), '', { source: 'defaults', path, valid: false, error: String(e && e.message || e) })
  }
}
