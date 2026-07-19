// CNCL-10 co-signed-votes contract test — offline, binds directly to the shipped engine
// (src/council/engine.mjs). Proves the four acceptance criteria: a forged/edited vote fails
// its signature, a cross-convene replay fails, a revoked-key vote is rejected, and the honest
// path verifies green — plus roster fingerprints + abstain handling. Exit 0 == green.
import {
  questionDigest, canonicalVoteBytes, fingerprintOf, generateSeatKeypair,
  signBytes, verifyBytes, signSeatVote, verifySeatVote, verifyReceiptVotes,
} from '../src/council/engine.mjs'

let pass = 0, fail = 0
function ok(name, cond) { if (cond) { pass++ } else { fail++; console.error('FAIL:', name) } }

// --- provision three seats, roster holds only pubkeys + fingerprints ---
const keys = {}
const roster = {}
for (const id of ['main', 'codex', 'olivia']) {
  const k = generateSeatKeypair()
  keys[id] = k
  roster[id] = { pub: k.pub, fingerprint: k.fingerprint, issuedAt: '2026-07-19T00:00:00Z' }
  ok(`${id} fingerprint matches pub`, k.fingerprint === fingerprintOf(k.pub))
  ok(`${id} fingerprint is 16 hex`, /^[0-9a-f]{16}$/.test(k.fingerprint))
}
ok('distinct keypairs', keys.main.pub !== keys.codex.pub && keys.main.privPem !== keys.codex.privPem)

const ctx = { conveneId: 'cv-2026-07-19-abc123', questionDigest: questionDigest('Ship the 0.11.8 release?') }
const stampedAt = '2026-07-19T12:00:00Z'

// --- HONEST PATH: each seat signs at source, receipt verifies green ---
const votes = [
  signSeatVote({ seat: 'main', vote: 'approve', rationale: 'tested, reversible', stampedAt }, ctx, keys.main.privPem, keys.main.fingerprint),
  signSeatVote({ seat: 'codex', vote: 'approve', rationale: 'edge cases covered', stampedAt }, ctx, keys.codex.privPem, keys.codex.fingerprint),
  signSeatVote({ seat: 'olivia', vote: 'reject', rationale: 'strategic risk', stampedAt }, ctx, keys.olivia.privPem, keys.olivia.fingerprint),
]
ok('every honest vote carries a sig + alg', votes.every(v => v.sig && v.sigAlg === 'ed25519'))
const honest = verifyReceiptVotes(votes, ctx, roster)
ok('HONEST PATH verifies green', honest.ok === true && honest.badSeats.length === 0)
ok('each honest seat individually ok', votes.every(v => verifySeatVote(v, ctx, roster).ok))

// --- FORGE: convener edits main's vote from approve -> reject after signing ---
const forgedEdit = { ...votes[0], vote: 'reject' }
ok('EDITED vote fails its signature', verifySeatVote(forgedEdit, ctx, roster).ok === false)
// --- FORGE: convener fabricates a vote it has no key to sign (sign with its own/other key) ---
const fabricated = signSeatVote({ seat: 'main', vote: 'approve', rationale: 'forged', stampedAt }, ctx, keys.codex.privPem)
ok('vote signed by the WRONG seat key fails', verifySeatVote(fabricated, ctx, roster).ok === false)
// unsigned fabricated vote
ok('UNSIGNED (fabricated) vote fails', verifySeatVote({ seat: 'main', vote: 'approve', rationale: 'x', stampedAt }, ctx, roster).ok === false)
ok('receipt with a forged vote is NOT green', verifyReceiptVotes([forgedEdit, votes[1], votes[2]], ctx, roster).ok === false)

// --- REPLAY: main's honestly-signed vote from an OLD convene is presented in a NEW one ---
const newCtx = { conveneId: 'cv-2026-07-20-def456', questionDigest: questionDigest('A different question entirely?') }
ok('cross-convene REPLAY fails (different convene id + digest)', verifySeatVote(votes[0], newCtx, roster).ok === false)
// same question digest but different convene id must still fail (replay within same topic)
const sameQNewConvene = { conveneId: 'cv-OTHER', questionDigest: ctx.questionDigest }
ok('same-question NEW-convene replay fails', verifySeatVote(votes[0], sameQNewConvene, roster).ok === false)

// --- REVOKED: olivia demoted, key revoked in roster; her cryptographically-valid vote is rejected ---
const revokedRoster = { ...roster, olivia: { ...roster.olivia, revokedAt: '2026-07-19T13:00:00Z' } }
const rv = verifySeatVote(votes[2], ctx, revokedRoster)
ok('REVOKED-key vote is rejected even though the sig is valid', rv.ok === false && /revoked/.test(rv.reason))
ok('receipt with a revoked seat is NOT green', verifyReceiptVotes(votes, ctx, revokedRoster).ok === false)

// --- ABSTAIN: a dead/silent seat is allowed unsigned, carries no weight, keeps receipt green ---
const abstain = { seat: 'codex', vote: 'abstain', rationale: 'no reply' }
const withAbstain = [votes[0], abstain, votes[2]]
const ab = verifyReceiptVotes(withAbstain, ctx, roster)
ok('ABSTAIN (unsigned non-vote) is allowed', ab.ok === true)
ok('abstain flagged, not counted as forged', verifySeatVote(abstain, ctx, roster).abstain === true)
// but a NON-abstain vote that is unsigned must still fail
ok('unsigned non-abstain still fails', verifySeatVote({ seat: 'codex', vote: 'approve', rationale: 'x' }, ctx, roster).ok === false)

// --- preimage determinism + replay binding are IN the signed bytes ---
const b1 = canonicalVoteBytes({ conveneId: 'a', questionDigest: 'q', seat: 's', vote: 'approve', rationale: 'r', stampedAt: 't' })
const b2 = canonicalVoteBytes({ conveneId: 'a', questionDigest: 'q', seat: 's', vote: 'approve', rationale: 'r', stampedAt: 't' })
ok('canonical vote bytes deterministic', b1 === b2)
ok('convene id is inside the signed bytes', b1.includes('convene: a'))
ok('question digest is inside the signed bytes', b1.includes('qdigest: q'))
ok('raw sign/verify round-trips', verifyBytes(b1, signBytes(b1, keys.main.privPem), keys.main.pub) === true)
ok('raw verify rejects a tampered byte', verifyBytes(b1 + 'x', signBytes(b1, keys.main.privPem), keys.main.pub) === false)

console.log(`\nCNCL-10 co-sign contract: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
