#!/usr/bin/env node
// The constitution kernel's CLI (DIVE-4869, DIVE-4893) — everything `5dive constitution` needs with
// no council present: parse (`constitution`), the show envelope, the v0 render, the structured
// guardrail merge, the solo genesis record (`genesis`) and the structural chain check. The show /
// render / merge / verify-chain bodies moved VERBATIM from council/cli.mjs when the council left
// core; `genesis` is council cli's `init` minus the interactive wizard (bash owns the prompts,
// the sudo gate, the principal resolution, the root seal and the lineage append).
import * as K from './constitution.mjs'
import * as S from './seal.mjs'
import fs from 'node:fs'

const argv = process.argv.slice(2)
const sub = argv[0] || ''
const rest = argv.slice(1)
const flag = (k, d) => {
  const hit = rest.find(a => a === `--${k}` || a.startsWith(`--${k}=`))
  if (hit == null) return d
  return hit.includes('=') ? hit.slice(hit.indexOf('=') + 1) : true
}
const die = (msg, code = 2) => { process.stderr.write(`constitution: ${msg}\n`); process.exit(code) }
// bash passes boolean flags as the STRINGS "0"/"1" — and JS `!"0"` is false, so never test a
// flag's truthiness for these. `--genesis-exists=0` MUST read as false (fail-closed correctness).
const flagBool = (k) => { const v = flag(k); return v === true || v === '1' || v === 'true' }
const out = (obj) => { process.stdout.write(JSON.stringify(obj) + '\n') }
const E = { ...K, ...S }

function cmdConstitution() {
  const p = flag('path')
  const path = p === true || p == null ? '' : String(p)
  out(E.loadConstitution(path))
}

// DIVE-1742: `constitution show --json` READ verb. Composes ONE envelope the dashboard (DIVE-1732)
// and any client consume instead of parsing raw constitution.yaml in-browser (DIVE-1731 no-mutation
// line + DIVE-1700 YAML bug class). The engine loadConstitution is the single shared parser. Digests
// + chain-verify come from the ROOT-sealed lineage via bash (which owns the gate-proof key); this verb
// just reads the lineage FILE for the amendment receipt list + normalizes null semantics. Fail-safe:
// a missing/garbage lineage yields amendments:[] and null digests, never a throw.
function readLineageRecords(lineagePath) {
  if (!lineagePath) return []
  let raw
  try { raw = fs.readFileSync(lineagePath, 'utf8') } catch { return [] }
  const out = []
  for (const line of raw.split(/\r?\n/)) {
    const s = line.trim(); if (!s) continue
    try { out.push(JSON.parse(s)) } catch { /* skip a corrupt line, never abort the read */ }
  }
  return out
}
function cmdConstitutionShow() {
  const strv = (k) => { const v = flag(k); return (v == null || v === true) ? '' : String(v) }
  const path = strv('path')
  const sealed = strv('sealed')
  const live = strv('live')
  const lineagePath = strv('lineage')
  const verifyFile = strv('verify-file')
  const c = E.loadConstitution(path)
  // Per-class hard_gates: raw effective ERE strings + a default-vs-custom source flag (custom ==
  // differs from the shipped default) so the dashboard can render "default" vs "customized".
  const hard_gates = { ...c.hardGates }
  const hard_gates_source = {}
  for (const k of Object.keys(hard_gates)) {
    hard_gates_source[k] = (hard_gates[k] === E.DEFAULT_HARD_GATE_CLASSES[k]) ? 'default' : 'custom'
  }
  // Amendment receipts: lineage records that carry a non-empty constitutionDigest (genesis-with-
  // constitution + every amend). Newest last (lineage is append-ordered). Fields per DIVE-1742 lock.
  const amendments = readLineageRecords(lineagePath)
    .map(w => ({ w, r: (w && w.record) || {} }))
    .filter(({ r }) => r && typeof r.constitutionDigest === 'string' && r.constitutionDigest !== '')
    .map(({ w, r }) => ({
      seq: Number.isInteger(r.seq) ? r.seq : (Number.isInteger(w.seq) ? w.seq : null),
      recordDigest: (w && typeof w.digest === 'string') ? w.digest : null,
      constitutionDigest: r.constitutionDigest,
      at: r.stampedAt || null,
      motion: (r.motion && r.motion.kind) || r.kind || null,
      outcome: r.outcome || null,
      by: r.by || (r.veto && r.veto.principal) || null,
    }))
  // verify passthrough (chain re-seal is root-only, computed by bash `council verify`); null if absent.
  let verify = null
  if (verifyFile) { try { verify = JSON.parse(fs.readFileSync(verifyFile, 'utf8')) } catch { verify = null } }
  const drift = E.constitutionDriftCheck({ sealedDigest: sealed, liveDigest: live })
  // genesisExists: is a council seated at all? This is the robust edit-vs-readonly signal (and the
  // DIVE-1743 write-path branch): a box can have a council genesis but an as-yet-UNSEALED constitution
  // (sealedDigest=null), where edits must still route through `council amend`, not a solo write. Truly
  // solo (editable) == no genesis AND no seal. bash passes --genesis-exists (it owns the genesis path).
  const genesisExists = String(flag('genesis-exists') || '') === '1'
  out({
    path: c.path, source: c.source, valid: c.valid, error: c.error,
    hard_gates, hard_gates_source, hard_gates_defaults: E.DEFAULT_HARD_GATE_CLASSES,
    hard_gate_regex: c.hardGateRegex,
    thresholds: c.thresholds, quorum: c.quorum,
    veto: c.veto, ship: c.ship, comms: c.comms, council: c.council,
    // null (NOT '') when no council has sealed. Pair with genesisExists for the edit-vs-readonly switch:
    // editable only when !genesisExists && sealedDigest==null (truly solo); else route via council amend.
    sealedDigest: sealed || null,
    liveDigest: live || null,
    genesisExists,
    drifted: !!drift.drifted, driftReason: drift.reason || null,
    verify,
    amendments,
  })
}

// The bench registry the genesis seeds. Same read contract as council cli's loadRegistry for the
// cases a solo seal meets (absent / empty -> {}; garbage -> refuse), without the DIVE-3729 repair.
function loadRegistry(p) {
  if (!p) return {}
  let raw
  try { raw = fs.readFileSync(p, 'utf-8') } catch (e) {
    if (e && e.code === 'ENOENT') return {}
    die(`cannot read the bench registry ${p}: ${(e && e.code) || 'unknown error'} — this is a READ FAILURE, not an empty registry`)
  }
  if (!raw.trim()) return {}
  try { return JSON.parse(raw) } catch (e) { die(`bench registry ${p} is not valid JSON (${e.message}) — refusing to run as if it were empty`) }
}
function saveRegistry(p, reg) {
  if (!p) die('bench mutation needs --registry=<path>')
  // DIVE-3729: `mode` applies only when the file is CREATED (and is still masked by the umask), so
  // this cannot downgrade an existing registry — it stops a first write under a tight umask from
  // leaving the store root-only, which is the same lockout the shell-side rewrite caused.
  const existed = fs.existsSync(p)
  fs.writeFileSync(p, JSON.stringify(reg, null, 2) + '\n', { mode: 0o644 })
  if (!existed) { try { fs.chmodSync(p, 0o644) } catch { /* best effort; the write itself succeeded */ } }
}

// CNCL-8: council init (human-seeded genesis roster). Seeds the primary `council` bench ONCE from
// a human-supplied roster + veto principal. bash owns the sudo gate, veto-principal resolution,
// the ROOT seal, and the hash-chained lineage write. cli validates the roster, enforces one-time
// (fail-closed unless --force), and emits the record for bash to seal — an agent can never call
// this to bootstrap its own council because the write path (COUNCIL_DIR) is root-owned.
function cmdGenesis() {
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
  if (!resolved || resolved === true) die(`veto principal "${principal}" did not resolve — use human:<agent> (a paired agent) or tg:<user_id>`, 6)
  let rec
  try {
    rec = E.buildGenesisRecord({
      seats: parsed.seats, chair: parsed.chair, threshold,
      veto: { principal: String(principal), resolved: String(resolved) },
      prevDigest: flag('prev-digest') || '', stampedAt: flag('stamped-at') || '',
      forced, seq: Number(flag('seq')) || 0,
      // CNCL-15: bash sha256sum's the seeded v0 constitution.yaml and passes it here so the digest is
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

// CNCL-15: constitution v0 render + drift check + amend motion. `constitution-render` prints the
// v0 constitution.yaml `council init` seeds when none exists. bash writes it, then sha256sum's the on-disk
// bytes for the sealed digest — one digest realm across seed/amend/verify.
function cmdConstitutionRender() { process.stdout.write(E.renderConstitutionV0()) }

// DIVE-1751 — browser-callable STRUCTURED-FIELD write. `constitution-merge --path=<current>` reads a
// JSON patch of the SOLO-editable guardrail fields from STDIN, merges it into the CURRENT constitution,
// and re-emits a valid v0 constitution.yaml on stdout. The bash layer then flows it through the EXACT
// SAME validate + seat-count route + seal path as `set --file=`. This keeps serialize+seal colocated in
// the CLI — the browser NEVER authors governance YAML (DIVE-1700 fraction-bug class). The patch is
// STRICTLY whitelisted to hard_gates/ship/comms; the governance keys (council/quorum/veto/thresholds)
// are unreachable here BY DESIGN (they change only through a `council amend` constitutional motion). The
// emitted bytes are re-validated through the SAME normalizer before we hand them back (one parser,
// fail-closed) — a structured write can never produce a constitution that would not parse.
const MERGE_TOP = new Set(['hard_gates', 'ship', 'comms'])
const MERGE_SHIP_KEYS = new Set(['require_ci'])
const MERGE_COMMS_KEYS = new Set(['public_requires_human'])
// Serialize a raw-parsed constitution node back to v0 frontmatter. Single-quote every string so
// regex backslashes + special chars survive the frontmatter parser byte-for-byte (it does no escape
// processing); numbers/booleans/null stay bare so they re-parse as themselves. Inline arrays for lists.
function serializeConstitutionScalar(v) {
  if (v === null) return 'null'
  if (typeof v === 'boolean') return v ? 'true' : 'false'
  if (typeof v === 'number' && Number.isFinite(v)) return String(v)
  if (Array.isArray(v)) return '[' + v.map(serializeConstitutionScalar).join(', ') + ']'
  return `'${String(v).replace(/'/g, "''")}'`
}
// DIVE-3493 — a non-empty list is re-emitted as a BLOCK sequence, never inline. This verb
// re-serializes the WHOLE document (it only ever CHANGES hard_gates/ship/comms, but it
// rewrites every key it read), so an inline emitter here would silently convert a sealed
// `authority.gate_clear_leads` into the one shape the enforcing reader in src/task/need.sh
// treats as absent — revoking the allowlist as a side effect of a guardrail edit, and now
// also failing this verb's own re-validation. Empty stays `[]`: block form cannot say it.
function serializeConstitutionList(k, v, pad) {
  if (!v.length) return `${pad}${k}: []\n`
  return `${pad}${k}:\n` + v.map(x => `${pad}  - ${serializeConstitutionScalar(x)}\n`).join('')
}
function serializeConstitutionNode(obj, indent) {
  const pad = ' '.repeat(indent)
  let out = ''
  for (const [k, v] of Object.entries(obj)) {
    if (Array.isArray(v)) out += serializeConstitutionList(k, v, pad)
    else if (v && typeof v === 'object') {
      const inner = serializeConstitutionNode(v, indent + 2)
      out += inner ? `${pad}${k}:\n${inner}` : `${pad}${k}:\n`
    } else out += `${pad}${k}: ${serializeConstitutionScalar(v)}\n`
  }
  return out
}
function serializeConstitution(raw) {
  // Canonical section order; only sections present in the merged doc are emitted. Governance keys
  // (council/quorum/veto/thresholds) are re-emitted verbatim from the current doc — never touched here.
  const order = ['hard_gates', 'ship', 'comms', 'council', 'quorum', 'veto', 'thresholds']
  const keys = [...order.filter(k => Object.hasOwn(raw, k)), ...Object.keys(raw).filter(k => !order.includes(k))]
  let out = '# 5dive company constitution (v0) — machine-enforced guardrails.\n'
    + '# Written by `5dive constitution set --json` (structured guardrail write, DIVE-1751). The AUTHORITY\n'
    + '# is the sealed digest: after this file is sealed, enforcement fails CLOSED on any drift from it.\n'
  for (const k of keys) {
    const v = raw[k]
    if (Array.isArray(v)) out += serializeConstitutionList(k, v, '')
    else if (v && typeof v === 'object') {
      const inner = serializeConstitutionNode(v, 2)
      out += inner ? `${k}:\n${inner}` : `${k}:\n`
    } else out += `${k}: ${serializeConstitutionScalar(v)}\n`
  }
  return out
}
function cmdConstitutionMerge() {
  const pf = flag('path')
  const path = (pf == null || pf === true) ? '' : String(pf)
  // Base = the CURRENT constitution's RAW frontmatter (preserve the exact governance keys the user /
  // council authored — we touch ONLY the three guardrail sections). No file yet -> base on the v0
  // default projection so a first structured write still yields a complete, valid file.
  let baseText
  if (path && fs.existsSync(path)) { try { baseText = fs.readFileSync(path, 'utf8') } catch (e) { die(`constitution-merge: cannot read the current constitution ${path} (${String(e && e.message || e)})`, 4) } }
  else baseText = E.renderConstitutionV0()
  let raw
  try { raw = E.parseConstitutionFrontmatter(baseText) }
  catch (e) { die(`constitution-merge: current constitution does not parse (${String(e && e.message || e)}) — refusing to write onto it`, 4) }

  // Read + STRICTLY whitelist the STDIN patch. Anything outside hard_gates/ship/comms is refused.
  let patch
  try { patch = JSON.parse(fs.readFileSync(0, 'utf8') || '{}') }
  catch (e) { die(`constitution-merge: invalid JSON on stdin (${String(e && e.message || e)})`, 2) }
  if (!patch || typeof patch !== 'object' || Array.isArray(patch)) die('constitution-merge: stdin must be a JSON object of structured fields', 2)
  const badTop = Object.keys(patch).filter(k => !MERGE_TOP.has(k))
  if (badTop.length) die(`constitution-merge: not settable here: ${badTop.join(', ')} — only hard_gates/ship/comms (governance: council amend)`, 2)

  if (Object.hasOwn(patch, 'hard_gates')) {
    const hg = patch.hard_gates
    if (!hg || typeof hg !== 'object' || Array.isArray(hg)) die('constitution-merge: hard_gates must be an object of class -> regex string', 2)
    const cur = (raw.hard_gates && typeof raw.hard_gates === 'object' && !Array.isArray(raw.hard_gates)) ? raw.hard_gates : {}
    const allowed = new Set([...Object.keys(cur), ...Object.keys(E.DEFAULT_HARD_GATE_CLASSES)])
    for (const [k, val] of Object.entries(hg)) {
      if (!allowed.has(k)) die(`constitution-merge: unknown hard_gates class '${k}' (editable classes: ${[...allowed].sort().join(', ')})`, 2)
      if (typeof val !== 'string' || !val.trim()) die(`constitution-merge: hard_gates.${k} must be a non-empty regex string`, 2)
    }
    raw.hard_gates = { ...cur, ...hg }
  }
  for (const [sec, keys] of [['ship', MERGE_SHIP_KEYS], ['comms', MERGE_COMMS_KEYS]]) {
    if (!Object.hasOwn(patch, sec)) continue
    const p = patch[sec]
    if (!p || typeof p !== 'object' || Array.isArray(p)) die(`constitution-merge: ${sec} must be an object`, 2)
    const cur = (raw[sec] && typeof raw[sec] === 'object' && !Array.isArray(raw[sec])) ? raw[sec] : {}
    for (const [k, val] of Object.entries(p)) {
      if (!keys.has(k)) die(`constitution-merge: unknown ${sec}.${k} (settable: ${[...keys].join(', ')})`, 2)
      if (typeof val !== 'boolean') die(`constitution-merge: ${sec}.${k} must be true or false`, 2)
    }
    raw[sec] = { ...cur, ...p }
  }

  // Re-serialize + re-validate through the SAME normalizer BEFORE emitting (fail-closed): a structured
  // write can never produce a constitution that would not parse under the one shared parser.
  const text = serializeConstitution(raw)
  try { E.normalizeConstitution(E.parseConstitutionFrontmatter(text)) }
  catch (e) { die(`constitution-merge: merged constitution failed validation (${String(e && e.message || e)}) — refusing to emit`, 4) }
  process.stdout.write(text)
}

// `drift-check` — pure comparison of the sealed digest vs the live-file digest (both computed by
// bash with sha256sum). Exits non-zero when drifted so callers can fail closed on the exit code.
function cmdDriftCheck() {
  const sealed = flag('sealed') === true || flag('sealed') == null ? '' : String(flag('sealed'))
  const live = flag('live') === true || flag('live') == null ? '' : String(flag('live'))
  const res = E.constitutionDriftCheck({ sealedDigest: sealed, liveDigest: live })
  out(res)
  process.exit(res.drifted ? 7 : 0)
}

function readJsonFlag(name, { optional = false } = {}) {
  const v = flag(name)
  if (!v || v === true) { if (optional) return null; die(`needs --${name}=<json or @file>`) }
  try { return JSON.parse(String(v).startsWith('@') ? fs.readFileSync(String(v).slice(1), 'utf-8') : v) }
  catch (e) { die(`bad --${name} json: ${String(e && e.message || e)}`) }
}

// council verify — the structural chain check (bash re-seals each record's canonical separately;
// both must be green). Detects an edited/dropped/reordered receipt across the WHOLE append-only log.
function cmdVerifyChain() {
  const entries = readJsonFlag('entries')
  const res = E.verifyLineageChain(entries)
  out(res)
  process.exit(res.ok ? 0 : 5)
}

const SUBS = {
  constitution: cmdConstitution,
  'constitution-show': cmdConstitutionShow,
  'constitution-render': cmdConstitutionRender,
  'constitution-merge': cmdConstitutionMerge,
  'drift-check': cmdDriftCheck,
  genesis: cmdGenesis,
  'verify-chain': cmdVerifyChain,
}
if (Object.hasOwn(SUBS, sub)) SUBS[sub]()
else die(`unknown subcommand: ${sub} (want: ${Object.keys(SUBS).join(' | ')})`)
