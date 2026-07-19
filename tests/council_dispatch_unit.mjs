// CNCL-7 dispatch unit — convene dispatches to REAL seated agents (mocked here), with liveness
// (timeout/unparse -> abstain), quorum-validity, and a BLIND first round. Offline, no network,
// no `5dive` exec (a mock seatVote adapter stands in for the ask rail). Exit 0 == green.
import {
  parseVote, seatPrompt, normalizeSeatVote, synthesizeNarrative, buildConveneVerdict,
  tallyVotes, runCouncil, VOTE_TOKENS,
} from '../src/council/engine.mjs'

let pass = 0, fail = 0
const ok = (c, m) => { c ? pass++ : (fail++, console.error('FAIL:', m)) }

// ---- parseVote: last COUNCIL-VOTE line wins, case-insensitive, fail-safe to null ----
ok(parseVote('reasoning here\nCOUNCIL-VOTE: approve :: looks good').vote === 'approve', 'parseVote reads approve')
ok(parseVote('COUNCIL-VOTE: reject :: nope').rationale === 'nope', 'parseVote captures rationale')
ok(parseVote('council-vote: ESCALATE :: needs a human').vote === 'escalate', 'parseVote case-insensitive token+label')
ok(parseVote('COUNCIL-VOTE: approve\nactually wait\nCOUNCIL-VOTE: reject :: changed my mind').vote === 'reject', 'parseVote takes the LAST vote line')
ok(parseVote('COUNCIL-VOTE: approve').rationale.includes('no rationale'), 'parseVote tolerates a missing rationale')
ok(parseVote('I think we should ship it. approve.') === null, 'parseVote returns null when there is no COUNCIL-VOTE line (=> abstain upstream)')
ok(parseVote('') === null && parseVote(null) === null, 'parseVote null-safe on empty/nullish')
ok(parseVote('prefix COUNCIL-VOTE: bogus :: x') === null, 'parseVote rejects an out-of-enum token')

// ---- seatPrompt BLIND-ROUND ISOLATION: round 1 is a pure fn of (seat, question) ----
const seatA = { id: 'main', lens: 'CTO' }
const p1blind = seatPrompt(seatA, { question: 'ship v0.11?', round: 1 })
const p1withPrior = seatPrompt(seatA, { question: 'ship v0.11?', round: 1, priorVotes: [{ seat: 'theo', vote: 'reject', rationale: 'secret leaks' }] })
ok(p1blind === p1withPrior, 'round-1 prompt is IDENTICAL with or without priorVotes (no anchoring — blind)')
ok(!p1blind.includes('theo') && !p1blind.includes('secret leaks'), 'round-1 prompt embeds NO other seat’s vote/rationale')
ok(p1blind.includes('INDEPENDENT vote BEFORE hearing any other seat'), 'round-1 prompt instructs an independent vote')
const p2 = seatPrompt(seatA, { question: 'ship v0.11?', round: 2, priorVotes: [{ seat: 'theo', vote: 'reject', rationale: 'secret leaks' }] })
ok(p2.includes('theo') && p2.includes('REBUT'), 'round-2 (rebuttal) prompt DOES show prior votes and asks to rebut')

// ---- normalizeSeatVote: unusable result -> abstain (counted in the denominator, not the tally) ----
ok(normalizeSeatVote(seatA, { vote: 'approve', rationale: 'ok' }).vote === 'approve', 'valid seat vote passes through')
ok(normalizeSeatVote(seatA, { vote: 'garbage' }).vote === 'abstain', 'out-of-enum vote -> abstain')
ok(normalizeSeatVote(seatA, null).vote === 'abstain', 'null result -> abstain')
ok(VOTE_TOKENS.includes('abstain'), 'abstain is a recognized token')

// ---- mock dispatch adapters (stand in for `5dive agent ask`) ----
// votesById maps seat id -> a vote token OR the sentinel 'TIMEOUT' (throws, like an ask timeout)
// OR 'GARBLE' (a reply the parser can't read -> abstain). Records every ctx it was called with.
function mockSeatVote(votesById, seen) {
  return async (seat, ctx) => {
    if (seen) seen.push({ id: seat.id, round: ctx.round, sawPrior: !!(ctx.priorVotes && ctx.priorVotes.length) })
    const v = votesById[seat.id]
    if (v === 'TIMEOUT') throw new Error('E_TIMEOUT: no idle reply')          // liveness: a dead seat
    if (v === 'GARBLE') return { vote: 'abstain', rationale: 'no COUNCIL-VOTE line' }
    return { vote: v || 'approve', rationale: `${seat.id}:${v || 'approve'}` }
  }
}
const seats5 = [{ id: 'main' }, { id: 'theo' }, { id: 'codex' }, { id: 'olivia' }, { id: 'lilbro' }]
const convene = (votesById, extra = {}, seen) =>
  runCouncil({ role: 'convene', question: 'ship?', seats: seats5, councilName: 'council', ...extra },
    { seatVote: mockSeatVote(votesById, seen) })

// all approve -> PASS via deterministic tally, receipt built, votes recorded
const rAll = await convene({ main: 'approve', theo: 'approve', codex: 'approve', olivia: 'approve', lilbro: 'approve' })
ok(rAll.verdict.recommendation === 'approve' && rAll.verdict.tally.approve === 5, 'dispatch: 5/5 approve -> PASS')
ok(rAll.receipt && rAll.receipt.canonical.includes('council: council') && rAll.receipt.seal.includes('gate-proof sign'), 'dispatch: receipt built with root seal command')
ok(rAll.votes.length === 5 && rAll.receipt.canonical.includes('vote main:'), 'dispatch: every seat vote is in the signed bytes')

// LIVENESS: one seat times out -> abstain, still counted in the denominator (not dropped)
const r1dead = await convene({ main: 'approve', theo: 'approve', codex: 'approve', olivia: 'approve', lilbro: 'TIMEOUT' })
ok(r1dead.votes.filter(v => v.vote === 'abstain').length === 1, 'liveness: a timed-out seat is recorded as ABSTAIN (a thrown adapter is caught)')
ok(r1dead.verdict.seatCount === 5 && r1dead.verdict.votesCast === 4, 'liveness: abstainer stays in seatCount (denominator), votesCast excludes it')
ok(r1dead.verdict.recommendation === 'approve', 'liveness: 4 present, 4 approve, threshold=majority(5)=3 -> still PASS (dead seat did not shrink the roster)')
ok(r1dead.receipt.canonical.includes('lilbro: abstain'), 'liveness: the abstain rides INSIDE the signed receipt (not silently dropped)')

// QUORUM BOUNDARY: 3 seats vote / 2 abstain -> quorum majority(5)=3 -> MET (edge)
const rEdge = await convene({ main: 'approve', theo: 'approve', codex: 'approve', olivia: 'TIMEOUT', lilbro: 'GARBLE' })
ok(rEdge.verdict.votesCast === 3 && rEdge.verdict.quorum === 3 && rEdge.verdict.quorumMet === true, 'quorum boundary: exactly quorum votes cast -> quorum MET')
ok(rEdge.verdict.recommendation === 'approve', 'quorum edge: 3 approve of 3 cast, threshold 3 -> PASS')

// QUORUM BOUNDARY: only 2 seats vote / 3 abstain -> inquorate -> NO verdict, auto-ESCALATE
const rInq = await convene({ main: 'approve', theo: 'approve', codex: 'TIMEOUT', olivia: 'TIMEOUT', lilbro: 'GARBLE' })
ok(rInq.verdict.votesCast === 2 && rInq.verdict.quorumMet === false, 'quorum boundary: below quorum -> quorum NOT met')
ok(rInq.verdict.escalated === true && rInq.verdict.recommendation === 'escalate', 'inquorate convene -> auto-escalate (a rump cannot decide)')
ok(/Inquorate: only 2 of 5/.test(rInq.verdict.brief) && /abstained:/.test(rInq.verdict.brief), 'inquorate escalation carries a human brief naming the quorum shortfall + abstainers')

// BLIND FIRST ROUND at the convene level: no seat adapter sees priorVotes in round 1
const seen = []
await convene({ main: 'approve', theo: 'reject', codex: 'approve', olivia: 'approve', lilbro: 'approve' }, {}, seen)
ok(seen.length === 5 && seen.every(s => s.round === 1 && s.sawPrior === false), 'blind round 1: NO seat adapter is handed another seat’s vote before its own is recorded')

// ADVERSARIAL: a rebuttal round runs, is recorded SEPARATELY, and the FINAL tally is round 2
const seenAdv = []
const rAdv = await runCouncil(
  { role: 'convene', question: 'ship?', seats: seats5, councilName: 'council', mode: 'adversarial' },
  { seatVote: mockSeatVote({ main: 'approve', theo: 'approve', codex: 'approve', olivia: 'approve', lilbro: 'approve' }, seenAdv) })
ok(seenAdv.some(s => s.round === 1 && s.sawPrior === false), 'adversarial: round 1 still blind')
ok(seenAdv.some(s => s.round === 2 && s.sawPrior === true), 'adversarial: round 2 rebuttal DOES see the round-1 votes')
ok(Array.isArray(rAdv.round1Votes) && Array.isArray(rAdv.rebuttalVotes) && rAdv.votes === rAdv.rebuttalVotes, 'adversarial: round 1 + rebuttal recorded separately; final votes = round 2')

// ADVERSARIAL never runs a second round in a non-adversarial mode
const seenDelib = []
await convene({ main: 'approve', theo: 'approve', codex: 'approve', olivia: 'approve', lilbro: 'approve' }, { mode: 'deliberate' }, seenDelib)
ok(seenDelib.every(s => s.round === 1), 'deliberate mode: exactly one (blind) round, no rebuttal')

// ---- synthesizeNarrative: key-free, deterministic confidence/dissent/brief ----
const votesSplit = [{ seat: 'a', vote: 'approve', rationale: 'x' }, { seat: 'b', vote: 'approve', rationale: 'y' }, { seat: 'c', vote: 'reject', rationale: 'risk' }]
const counted = tallyVotes(votesSplit, { decisionClass: 'ordinary', seatCount: 3 })
const narr = synthesizeNarrative(votesSplit, counted)
ok(narr.confidence === Math.round((2 / 3) * 100) / 100, 'synthesis: confidence = winning fraction among votes cast (deterministic)')
ok(narr.dissent.includes('c (reject): risk'), 'synthesis: dissent preserves the losing side’s rationale')
ok(synthesizeNarrative([{ seat: 'a', vote: 'approve', rationale: 'x' }], tallyVotes([{ seat: 'a', vote: 'approve' }], { seatCount: 1, quorum: 'none' })).dissent === 'none', 'synthesis: unanimous -> dissent none')

// buildConveneVerdict carries the quorum bookkeeping onto the verdict
const bv = buildConveneVerdict(counted, narr)
ok(bv.quorum === counted.quorum && bv.votesCast === counted.votesCast && bv.quorumMet === counted.quorumMet, 'buildConveneVerdict surfaces quorum/votesCast/quorumMet for the receipt + disposition')

console.log(`\nCNCL-7 dispatch: ${pass} passed, ${fail} failed (bound to src/council/engine.mjs)`)
process.exit(fail ? 1 : 0)
