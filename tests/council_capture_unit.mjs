// DIVE-1869 capture-failure unit — a seat we never REACHED is not a seat that abstained.
//
// The bug: convene dispatches each seat ballot over a rail that needs a privileged grant. Run
// without it, every dispatch failed instantly and was folded into a plain ABSTAIN, so the run
// produced a normal-looking "Inquorate: 0 of N voted" verdict and a clean sealed receipt. A
// permissions outage was byte-indistinguishable from a legitimate unanimous abstention.
//
// The contract proved here: capture failures are TAGGED through normalization, counted apart from
// real abstentions, and a convene whose non-votes are ALL capture failures is flagged
// `deliveryFailure` (the CLI refuses to emit or seal it). Offline, no exec. Exit 0 == green.
import {
  normalizeSeatVote, captureAudit, buildConveneVerdict, synthesizeNarrative,
  tallyVotes, canonicalTranscript,
} from '../src/council/engine.mjs'

let pass = 0, fail = 0
const ok = (c, m) => { c ? pass++ : (fail++, console.error('FAIL:', m)) }

const seat = (id) => ({ id })
const SEATS = ['a', 'b', 'c'].map(seat)

// ---- normalizeSeatVote carries the tags through (they used to be dropped) ----
const capFail = normalizeSeatVote(seat('a'),
  { vote: 'abstain', abstainKind: 'capture-failed', capture: false, rationale: 'CAPTURE FAILED — sudo: a password is required' })
ok(capFail.capture === false, 'normalizeSeatVote preserves capture=false')
ok(capFail.abstainKind === 'capture-failed', 'normalizeSeatVote preserves abstainKind')

const realAbstain = normalizeSeatVote(seat('b'), { vote: 'abstain', rationale: 'no strong view' })
ok(realAbstain.capture === undefined && realAbstain.abstainKind === undefined,
  'a genuine abstention carries NO capture tag (untagged == the seat spoke)')

const unusable = normalizeSeatVote(seat('c'), null)
ok(unusable.vote === 'abstain' && unusable.capture === false && unusable.abstainKind === 'unusable',
  'an unusable adapter result is a capture failure, not an abstention')

const voted = normalizeSeatVote(seat('a'), { vote: 'approve', rationale: 'ship it' })
ok(voted.vote === 'approve' && voted.capture === undefined, 'a real vote is untouched')

// ---- captureAudit splits the two populations ----
const mixed = [
  { seat: 'a', vote: 'abstain', capture: false, abstainKind: 'capture-failed', rationale: 'no grant' },
  { seat: 'b', vote: 'abstain', rationale: 'genuinely undecided' },
  { seat: 'c', vote: 'approve', rationale: 'yes' },
]
const audit = captureAudit(mixed)
ok(audit.abstains === 2 && audit.captureFailed === 1, 'captureAudit counts abstains and capture failures apart')
ok(audit.captureFailedSeats.length === 1 && audit.captureFailedSeats[0].seat === 'a',
  'captureAudit names the seats we could not reach')
ok(captureAudit([]).captureFailed === 0 && captureAudit(undefined).abstains === 0, 'captureAudit is null-safe')

// ---- the loud case: every non-vote is a delivery failure -> deliveryFailure ----
const allFailed = SEATS.map(s => ({ seat: s.id, vote: 'abstain', capture: false, abstainKind: 'capture-failed', rationale: 'sudo: a password is required' }))
const vAllFailed = buildConveneVerdict(tallyVotes(allFailed, { seats: SEATS }), synthesizeNarrative(allFailed, tallyVotes(allFailed, { seats: SEATS })), allFailed)
ok(vAllFailed.deliveryFailure === true, 'a 0-of-N run whose every non-vote is a capture failure is flagged deliveryFailure')
ok(vAllFailed.captureFailed === 3, 'the verdict carries the capture-failure count')
ok(vAllFailed.captureFailedSeats.map(x => x.seat).join(',') === 'a,b,c', 'the verdict names every unreached seat')

// ---- the quiet case: a genuine unanimous abstention still seals (it IS a decision) ----
const allAbstained = SEATS.map(s => ({ seat: s.id, vote: 'abstain', rationale: 'no view' }))
const cAllAbstained = tallyVotes(allAbstained, { seats: SEATS })
const vAllAbstained = buildConveneVerdict(cAllAbstained, synthesizeNarrative(allAbstained, cAllAbstained), allAbstained)
ok(vAllAbstained.deliveryFailure === false,
  'a REAL unanimous abstention is NOT a delivery failure — the distinction the bug erased')

// ---- mixed: one seat genuinely abstained, so we DID hear the council; do not refuse ----
const someHeard = [
  { seat: 'a', vote: 'abstain', capture: false, abstainKind: 'capture-failed', rationale: 'no grant' },
  { seat: 'b', vote: 'abstain', rationale: 'no view' },
  { seat: 'c', vote: 'abstain', capture: false, abstainKind: 'ballot-mint-failed', rationale: 'task add failed' },
]
const cSome = tallyVotes(someHeard, { seats: SEATS })
const vSome = buildConveneVerdict(cSome, synthesizeNarrative(someHeard, cSome), someHeard)
ok(vSome.deliveryFailure === false && vSome.captureFailed === 2,
  'one genuine abstention keeps the run a real (thin) deliberation, but the failures are still counted')

// ---- quorate runs are never refused, even with an unreachable seat ----
const quorate = [
  { seat: 'a', vote: 'approve', rationale: 'yes' },
  { seat: 'b', vote: 'approve', rationale: 'yes' },
  { seat: 'c', vote: 'abstain', capture: false, abstainKind: 'capture-failed', rationale: 'unreachable' },
]
const cQ = tallyVotes(quorate, { seats: SEATS })
const vQ = buildConveneVerdict(cQ, synthesizeNarrative(quorate, cQ), quorate)
ok(vQ.quorumMet === true && vQ.deliveryFailure === false && vQ.captureFailed === 1,
  'a quorate convene still passes, with the unreached seat recorded')

// ---- the seal is unchanged: tags are ADDITIVE, never in the canonical bytes ----
const rec = { council: 'council', mode: 'quick', stampedAt: 'T', question: 'q', seats: ['a', 'b', 'c'],
  votes: allFailed, verdict: vAllFailed }
const recPlain = { ...rec, votes: allFailed.map(v => ({ seat: v.seat, vote: v.vote, rationale: v.rationale })) }
ok(canonicalTranscript(rec) === canonicalTranscript(recPlain),
  'canonicalTranscript is byte-identical with or without the tags (pre-DIVE-1869 receipts still verify)')

console.log(`council capture unit: ${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
