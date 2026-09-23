// The constitution SEAL (DIVE-4893). CORE-owned: the solo writer of the council lineage — a
// single-principal genesis record, its canonical preimage (the bytes the root gate-proof rail
// seals), the bench entry it seeds, and the structural chain check `constitution show` reports.
// Moved VERBATIM from the council engine (5dive-ai/5dive fcd81d73 src/council/engine.mjs) when the
// council left core, because `constitution set|edit` direct-seals with no council present. The
// council plugin keeps its own copy of these for multi-seat genesis and motions: the two writers
// append to the same lineage, so their canonical bytes must stay identical —
// tests/constitution_kernel_unit.sh pins them to golden bytes produced by the pre-move engine.

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

// The primary council's bench identity, as the council engine's DEFAULT_COUNCIL declares it — only
// the two fields genesisToBench copies, so a solo seal seeds the same bench a council init would.
const COUNCIL_BENCH_DESCRIPTION = 'The 5dive Council — self-governed standing body, one vote each. Seats mutable by quorum vote.'
const COUNCIL_BENCH_MODE = 'deliberate'

// The bench entry a genesis record seeds into the persisted registry — the primary `council`.
export function genesisToBench(rec) {
  return {
    description: COUNCIL_BENCH_DESCRIPTION,
    mode: COUNCIL_BENCH_MODE,
    seats: rec.seats.map(s => ({ id: s.id, lens: s.lens, ...(s.chair ? { chair: true } : {}), ...humanSeatFields(s) })),
    threshold: rec.threshold,
    genesis: true,           // marks this bench as motion-governed (raw add/rm refused)
    seededAt: rec.stampedAt,
  }
}
