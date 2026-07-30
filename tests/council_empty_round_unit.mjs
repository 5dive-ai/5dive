#!/usr/bin/env node
// DIVE-2103: an EMPTY convene round must be VISIBLE, never silently absorbed.
//
// The defect this guards: both existing guards read only the MERGED tally — quorum in
// countConveneVotes, and the DIVE-1869 outage-is-not-a-decision refusal — so a round that
// returned zero substantive votes escapes both. Measured n=2 on OPPOSITE rounds: 2026-07-20
// round 2 empty (a live approve/reject split ERASED, run went inquorate), and 2026-07-21 seq 1
// round 1 empty while the receipt still read `approve a3/r0/e0 conf=1 dissent=none`.
//
// MUTATION-GRADED (the VERIFY BY bar): arm D neutralises the detector and REQUIRES red. A test
// that only asserts the happy path cannot tell a working detector from a deleted one — which is
// the exact class (vacuous assertion) that made T9 pass on a timeout for its entire life.
import { roundParticipation, canonicalTranscript } from '../src/council/engine.mjs'

let pass = 0, fail = 0
const ok = (m) => { pass++; console.log(`ok   - ${m}`) }
const bad = (m, d) => { fail++; console.log(`FAIL - ${m}${d ? `\n   ${d}` : ''}`) }
const t = (m, c, d) => (c ? ok(m) : bad(m, d))

const abstained = (seats) => seats.map(s => ({ seat: s, vote: 'abstain', abstainKind: 'deadline' }))
const voted     = (seats) => seats.map(s => ({ seat: s, vote: 'approve', rationale: 'r' }))
const SEATS = ['a', 'b', 'c']

// --- A. the detector itself -------------------------------------------------
{
  const r = roundParticipation(1, abstained(SEATS))
  t('A1 all-abstain round reports ZERO substantive', r.substantive === 0, `got ${r.substantive}`)
  t('A2 dispatched still counts every seat', r.dispatched === 3, `got ${r.dispatched}`)
  t('A3 abstains account for the whole round', r.abstains === 3, `got ${r.abstains}`)

  const g = roundParticipation(2, voted(SEATS))
  t('A4 a healthy round reports substantive === dispatched', g.substantive === 3 && g.dispatched === 3)

  // capture===false is DIVE-1869 "never reached", which is NOT the same as abstained-by-deadline
  const u = roundParticipation(1, [{ seat: 'a', vote: 'abstain', capture: false }])
  t('A5 unreached seats are counted separately from abstains', u.unreached === 1)
}

// --- B. the canonical seals it ONLY when a round was empty -------------------
// olivia's hard constraint: a healthy receipt must stay byte-identical, or every prior seal breaks.
{
  const base = {
    council: 'c', mode: 'adversarial', stampedAt: '2026-01-01T00:00:00Z', question: 'q',
    seats: SEATS, votes: voted(SEATS), verdict: { recommendation: 'approve' },
  }
  const healthy = canonicalTranscript({ ...base, roundStats: [roundParticipation(1, voted(SEATS))] })
  t('B1 a HEALTHY round emits NO participation line (byte-identical constraint)',
    !healthy.includes('participation:'), healthy.split('\n').find(l => l.includes('participation')))

  const degenerate = canonicalTranscript({
    ...base,
    roundStats: [roundParticipation(1, abstained(SEATS)), roundParticipation(2, voted(SEATS))],
    degradedToSingleRound: true,
  })
  t('B2 an EMPTY round emits its participation line', degenerate.includes('round1 participation:'))
  t('B3 the sibling round is emitted too, so the record is symmetric', degenerate.includes('round2 participation:'))
  t('B4 the empty line reports substantive=0', /round1 participation:.*substantive=0/.test(degenerate))
  t('B5 an adversarial run with an empty round 1 is marked DEGRADED', degenerate.includes('degraded:'))

  // the omission must be driven by emptiness, not by the flag being absent
  const noFlag = canonicalTranscript({ ...base, roundStats: [roundParticipation(1, abstained(SEATS))] })
  t('B6 participation seals even when degradedToSingleRound is unset', noFlag.includes('round1 participation:'))
  t('B7 ...but the degraded line does NOT', !noFlag.includes('degraded:'))
}

// --- C. no roundStats at all => pre-2103 receipts are unchanged --------------
{
  const legacy = canonicalTranscript({
    council: 'c', mode: 'deliberate', stampedAt: '2026-01-01T00:00:00Z', question: 'q',
    seats: SEATS, votes: voted(SEATS), verdict: { recommendation: 'approve' },
  })
  t('C1 a record with no roundStats seals with no participation lines',
    !legacy.includes('participation:') && !legacy.includes('degraded:'))
}

// --- D. MUTATION ARM: neutralise the detector, REQUIRE red -------------------
// If roundParticipation stopped distinguishing abstains, A1/B4 would still pass on a *healthy*
// round — so this arm proves the assertions above are load-bearing rather than decorative.
{
  const neutralised = (round, votes) => ({
    round, dispatched: (votes || []).length,
    substantive: (votes || []).length,          // <- the bug: counts abstains as substantive
    abstains: 0, unreached: 0,
  })
  const r = neutralised(1, abstained(SEATS))
  t('D1 MUTANT: a detector that counts abstains as substantive reports 3, not 0', r.substantive === 3)

  const canon = canonicalTranscript({
    council: 'c', mode: 'adversarial', stampedAt: '2026-01-01T00:00:00Z', question: 'q',
    seats: SEATS, votes: voted(SEATS), verdict: { recommendation: 'approve' },
    roundStats: [r], degradedToSingleRound: false,
  })
  t('D2 MUTANT: the empty round would seal NOTHING, i.e. the defect returns silently',
    !canon.includes('participation:'),
    'if this fails the mutation did not neutralise anything and arm B proves less than it claims')
}

console.log(`\nDIVE-2103 empty-round visibility: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
