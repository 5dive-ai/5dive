// CNCL-7 dispatch unit — convene dispatches to REAL seated agents (mocked here), with liveness
// (timeout/unparse -> abstain), quorum-validity, and a BLIND first round. Offline, no network,
// no `5dive` exec (a mock seatVote adapter stands in for the ask rail). Exit 0 == green.
import {
  parseVote, seatPrompt, normalizeSeatVote, synthesizeNarrative, buildConveneVerdict,
  tallyVotes, runCouncil, VOTE_TOKENS, canonicalTranscript, carryForwardVotes,
} from '../src/council/engine.mjs'
// CNCL-18: the non-blocking ballot ADAPTER lives in cli.mjs (guarded entrypoint so this import
// does NOT run the arg-parser). We drive its PURE collection logic with injected exec/clock seams.
import { dispatchBallotVote, ballotTap } from '../src/council/cli.mjs'
import { createHash } from 'node:crypto'

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
// CNCL-25 (Finding 4): the final `votes` are now round-2 MERGED over round-1 (not identity-equal to
// rebuttalVotes). When every seat re-casts (as here), the merge is VALUE-equal to round 2.
ok(Array.isArray(rAdv.round1Votes) && Array.isArray(rAdv.rebuttalVotes) &&
   rAdv.votes !== rAdv.rebuttalVotes &&
   JSON.stringify(rAdv.votes.map(v => [v.seat, v.vote])) === JSON.stringify(rAdv.rebuttalVotes.map(v => [v.seat, v.vote])),
   'adversarial: round 1 + rebuttal recorded separately; final votes = round-2 merged over round-1 (all re-cast -> equals round 2)')

// ---- CNCL-25 Finding-4: carryForwardVotes (pure merge) ----------------------------------------
{
  const r1 = [{ seat: 'a', vote: 'reject', rationale: 'no' }, { seat: 'b', vote: 'approve', rationale: 'y' }, { seat: 'c', vote: 'abstain', rationale: 'never voted' }]
  const r2 = [{ seat: 'a', vote: 'abstain', rationale: 'deadline/no-vote' }, { seat: 'b', vote: 'reject', rationale: 'changed my mind' }, { seat: 'c', vote: 'abstain', rationale: 'deadline/no-vote' }]
  const m = carryForwardVotes(r1, r2)
  ok(m.find(v => v.seat === 'a').vote === 'reject' && m.find(v => v.seat === 'a').carried === true, 'carryForward: a seat SILENT in round 2 carries its round-1 vote (marked carried)')
  ok(/round-1 position carried forward/.test(m.find(v => v.seat === 'a').rationale), 'carryForward: the carried vote is MARKED in the rationale (auditable in the seal)')
  ok(m.find(v => v.seat === 'b').vote === 'reject' && !m.find(v => v.seat === 'b').carried, 'carryForward: a re-cast round-2 vote WINS (a genuine revision is honored), not carried')
  ok(m.find(v => v.seat === 'c').vote === 'abstain', 'carryForward: a seat that never cast substantively stays abstain')
  ok(carryForwardVotes(null, null).length === 0 && carryForwardVotes([{ seat: 'a', vote: 'approve' }], []).length === 0, 'carryForward: null/empty-safe')
}

// ---- CNCL-25 Finding-4 INTEGRATION: an all-silent rebuttal no longer collapses the tally ------
// Pre-fix repro (2026-07-20 strategy): seats cast substantively in the blind round 1, then ALL time
// out in the tight round-2 window -> final tally taken from round 2 -> cast=0 -> inquorate, the live
// split erased. Post-fix: round-1 votes carry, so the verdict reflects real round-1 participation.
function roundAwareVote(spec) { // spec[seat] = [round1Vote, round2Vote]; 'TIMEOUT' throws (dead seat)
  return async (seat, ctx) => {
    const pair = spec[seat.id] || ['approve', 'approve']
    const v = pair[ctx.round === 2 ? 1 : 0]
    if (v === 'TIMEOUT') throw new Error('E_TIMEOUT: no idle reply')
    return { vote: v, rationale: `${seat.id}:r${ctx.round}:${v}` }
  }
}
const rCarry = await runCouncil(
  { role: 'convene', question: 'ship?', seats: seats5, councilName: 'council', mode: 'adversarial' },
  { seatVote: roundAwareVote({ main: ['reject', 'TIMEOUT'], theo: ['approve', 'TIMEOUT'], codex: ['approve', 'TIMEOUT'], olivia: ['approve', 'TIMEOUT'], lilbro: ['approve', 'TIMEOUT'] }) })
ok(rCarry.rebuttalVotes.every(v => v.vote === 'abstain'), 'carry integration: round 2 was all-silent (every seat timed out -> abstain)')
ok(rCarry.votes.filter(v => v.vote !== 'abstain').length === 5, 'CNCL-25: round-1 votes CARRY through an all-silent rebuttal (final cast != 0)')
ok(rCarry.verdict.votesCast === 5 && rCarry.verdict.quorumMet === true, 'CNCL-25: an all-silent rebuttal no longer collapses a fully-participated round 1 to inquorate')
ok(rCarry.verdict.tally.approve === 4 && rCarry.verdict.tally.reject === 1, 'CNCL-25: the live round-1 approve/reject split SURVIVES into the final tally (was erased pre-fix)')
ok(rCarry.votes.find(v => v.seat === 'main').vote === 'reject' && rCarry.votes.find(v => v.seat === 'main').carried === true, 'CNCL-25: the dissenting round-1 reject is carried + marked, not dropped')

// TAMPER-EVIDENCE of round-1 history (main's CNCL-7 gate amendment): in adversarial mode the
// signed canonical must include the round-1 votes, so a between-round seat flip cannot be
// misrepresented without failing verify. A single-round receipt must NOT carry round1 lines.
ok(/\nround1 \w+: /.test(rAdv.receipt.canonical), 'adversarial receipt SEALS the round-1 history (round1 lines in the canonical)')
ok(!/\nround1 /.test(rAll.receipt.canonical), 'single-round (non-adversarial) receipt stays round1-free (byte-identical to CNCL-6)')
// a round-1 flip changes the sealed bytes even when the FINAL votes + verdict are identical
const recBase = { council: 'c', mode: 'adversarial', stampedAt: 'T', question: 'q', seats: ['a', 'b'],
  votes: [{ seat: 'a', vote: 'approve', rationale: 'x' }, { seat: 'b', vote: 'approve', rationale: 'y' }],
  round1Votes: [{ seat: 'a', vote: 'reject', rationale: 'first no' }, { seat: 'b', vote: 'approve', rationale: 'y' }],
  verdict: { recommendation: 'approve', tally: { approve: 2, reject: 0, escalate: 0 }, confidence: 1, dissent: 'none', escalated: false } }
const recFlip = { ...recBase, round1Votes: [{ seat: 'a', vote: 'approve', rationale: 'first no' }, { seat: 'b', vote: 'approve', rationale: 'y' }] }
ok(canonicalTranscript(recBase) !== canonicalTranscript(recFlip), 'a round-1 vote flip changes the sealed bytes even with identical FINAL votes (round-1 history is tamper-evident)')
ok(canonicalTranscript({ ...recBase, seats: ['b', 'a'] }) === canonicalTranscript(recBase), 'round-1 canonical stays order-independent (stable bytes)')

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

// ---- CNCL-18: non-blocking ballot adapter (dispatchBallotVote) — PURE collection logic ----
// A stub exec answers `task add` with a fixed id and `task show` from a queue of rows; a stateful
// clock advances so the deadline loop terminates with NO real timers/sleeps. Mirrors the mockSeatVote
// injection idiom above (deterministic, offline, no `5dive` exec).
function ballotExec({ addId = 'DIVE-42', rowSeq = [], captured } = {}) {
  let i = 0
  return (args) => {
    if (captured) captured.push(args)
    if (args[0] === 'task' && args[1] === 'add') return JSON.stringify({ ok: true, data: { id: 42, ident: addId } })
    if (args[0] === 'task' && args[1] === 'show') {
      const row = rowSeq[Math.min(i, rowSeq.length - 1)]; i++
      return JSON.stringify({ ok: true, data: { task: row } })
    }
    throw new Error('ballotExec: unexpected argv ' + args.join(' '))
  }
}
const noSleep = async () => {}
const fixedNow = () => 0                              // constant clock: never trips the deadline
const advancingNow = (stepMs = 500) => { let t = 0; return () => { const v = t; t += stepMs; return v } }
const bseat = { id: 'main', lens: 'CTO' }

// (a) a closed task whose result carries a COUNCIL-VOTE line parses to that vote
const rParse = await dispatchBallotVote({ deadline: 100, poll: 1, _now: fixedNow, _sleep: noSleep,
  _exec: ballotExec({ rowSeq: [{ status: 'done', result: 'weighed it\nCOUNCIL-VOTE: approve :: no blocker' }] }) })(bseat, { question: 'ship?', round: 1 })
ok(rParse.vote === 'approve' && /no blocker/.test(rParse.rationale), 'ballot: closed task with a COUNCIL-VOTE result parses to that vote')

// a `reject` result likewise parses through (not just approve)
const rRej = await dispatchBallotVote({ deadline: 100, poll: 1, _now: fixedNow, _sleep: noSleep,
  _exec: ballotExec({ rowSeq: [{ status: 'done', result: 'COUNCIL-VOTE: reject :: leaks a secret' }] }) })(bseat, { question: 'ship?', round: 1 })
ok(rRej.vote === 'reject', 'ballot: a reject result is honored')

// a task still open on the FIRST poll but closed with a vote on the SECOND is collected (poll loop works)
const rPoll = await dispatchBallotVote({ deadline: 100, poll: 1, _now: fixedNow, _sleep: noSleep,
  _exec: ballotExec({ rowSeq: [{ status: 'in_progress' }, { status: 'done', result: 'COUNCIL-VOTE: escalate :: needs a human' }] }) })(bseat, { question: 'ship?', round: 1 })
ok(rPoll.vote === 'escalate', 'ballot: keeps polling an open task and collects the vote once it closes')

// (b) deadline elapses with NO result -> abstain (the missed-deadline contract)
const rDead = await dispatchBallotVote({ deadline: 1, poll: 1, _now: advancingNow(600), _sleep: noSleep,
  _exec: ballotExec({ rowSeq: [{ status: 'todo' }] }) })(bseat, { question: 'ship?', round: 1 })
ok(rDead.vote === 'abstain' && /deadline/.test(rDead.rationale), 'ballot: deadline elapses with no vote -> ABSTAIN')

// (c) a closed task with an UNPARSEABLE result -> abstain (fail-safe, never a silent approve)
const rGarble = await dispatchBallotVote({ deadline: 100, poll: 1, _now: fixedNow, _sleep: noSleep,
  _exec: ballotExec({ rowSeq: [{ status: 'done', result: 'I think we should ship it.' }] }) })(bseat, { question: 'ship?', round: 1 })
ok(rGarble.vote === 'abstain', 'ballot: a closed task with no COUNCIL-VOTE line -> ABSTAIN (fail-safe)')

// a task add that fails to mint (bad JSON / no id) -> abstain, never a throw that aborts the round
const rNoMint = await dispatchBallotVote({ deadline: 100, poll: 1, _now: fixedNow, _sleep: noSleep,
  _exec: () => 'not json' })(bseat, { question: 'ship?', round: 1 })
ok(rNoMint.vote === 'abstain', 'ballot: an unmintable task -> ABSTAIN (a broken mint never aborts the convene)')

// (d) BLIND round 1: the minted ballot body embeds NO other seat's vote/rationale
const capBlind = []
await dispatchBallotVote({ deadline: 100, poll: 1, _now: fixedNow, _sleep: noSleep, _exec: ballotExec({ captured: capBlind, rowSeq: [{ status: 'done', result: 'COUNCIL-VOTE: approve :: ok' }] }) })(
  bseat, { question: 'ship v0.11?', round: 1, priorVotes: [{ seat: 'theo', vote: 'reject', rationale: 'secret leaks' }] })
const addCall = capBlind.find(a => a[0] === 'task' && a[1] === 'add')
const bodyArg = (addCall || []).find(a => String(a).startsWith('--body='))
ok(!!bodyArg && !bodyArg.includes('theo') && !bodyArg.includes('secret leaks'), 'ballot: round-1 body embeds NO other seat’s vote (blind)')
ok(!!addCall && addCall.includes('--no-verify') && addCall.some(a => a === '--assignee=main'), 'ballot: mints a --no-verify task assigned to the resolved registry agent')
ok(!!addCall && addCall.some(a => a === '--from=council'), 'ballot: ballot task is filed --from=council')

// ---- DIVE-1564: HUMAN-AS-SEAT ballot branch (Telegram tap closes the SAME ballot task) ----
const hseat = { id: 'lodar', kind: 'human', chat: '433634012', lens: 'founder' }

// (h1) an UNBOUND human seat -> fail-closed ABSTAIN, mints NO task and emits NO ballot (never drop silently)
const capUnbound = []
let emittedUnbound = 0
const rUnbound = await dispatchBallotVote({ deadline: 100, poll: 1, _now: fixedNow, _sleep: noSleep,
  _emitBallot: async () => { emittedUnbound++ }, _exec: ballotExec({ captured: capUnbound }) })(
  { id: 'ghost', kind: 'human' }, { question: 'ship?', round: 1 })
ok(rUnbound.vote === 'abstain' && /fail-closed/.test(rUnbound.rationale), 'human ballot: an unbound human seat -> fail-closed abstain')
ok(emittedUnbound === 0 && !capUnbound.some(a => a[0] === 'task' && a[1] === 'add'), 'human ballot: unbound seat mints NO task and emits NO ballot')

// (h2) a BOUND human seat mints the ballot task filed to the convener + emits a 3-button ballot; a tap collects
const capH = []
let emitted = null
const rTap = await dispatchBallotVote({ deadline: 100, poll: 1, from: 'council', _now: fixedNow, _sleep: noSleep,
  _emitBallot: async (p) => { emitted = p },
  _exec: ballotExec({ addId: 'DIVE-1600', captured: capH, rowSeq: [{ status: 'done', result: 'COUNCIL-VOTE: approve :: tapped approve' }] }) })(
  hseat, { question: 'ship v0.12?', round: 1, priorVotes: [{ seat: 'theo', vote: 'reject', rationale: 'secret leaks' }] })
ok(rTap.vote === 'approve' && /tapped approve/.test(rTap.rationale), 'human ballot: a tap that closes the task with a COUNCIL-VOTE is collected like any ballot')
const hAdd = capH.find(a => a[0] === 'task' && a[1] === 'add')
ok(!!hAdd && hAdd.includes('--no-verify') && hAdd.some(a => a === '--assignee=council') && hAdd.some(a => a === '--from=council'), 'human ballot: mints a --no-verify task filed to the convener (never agent-ask-run)')
const hBody = (hAdd || []).find(a => String(a).startsWith('--body='))
ok(!!hBody && !hBody.includes('theo') && !hBody.includes('secret leaks'), 'human ballot: round-1 body is BLIND (no other seat’s vote)')

// (h3) the emit payload targets the seat chat with the blind question + 3 well-formed buttons under the 64B cap
ok(!!emitted && emitted.chat === '433634012' && /ship v0.12\?/.test(emitted.text), 'human ballot: emit payload targets the seat chat with the blind question')
ok(!!emitted && Array.isArray(emitted.buttons) && emitted.buttons.length === 3, 'human ballot: emit carries 3 buttons')
const codes = (emitted.buttons || []).map(b => (b.callback_data.match(/^cvote:([^:]+):([are]):([0-9a-f]+)$/) || [])[2])
ok(codes.join(',') === 'a,r,e', 'human ballot: buttons are Approve/Reject/Abstain with a|r|e verbs')
ok((emitted.buttons || []).every(b => b.callback_data.length <= 64), 'human ballot: callback_data fits Telegram’s 64-byte cap')
const rawNonce = emitted.buttons[0].callback_data.split(':')[3]
ok(/^[0-9a-f]{32}$/.test(rawNonce), 'human ballot: callback_data carries a 16-byte one-time nonce')

// (h4) the RAW nonce is NEVER in the task body or the ballot text — only its sha256 DIGEST is stored
const digest = createHash('sha256').update(rawNonce).digest('hex')
ok(!!hBody && hBody.includes(`nonceDigest=${digest}`) && !hBody.includes(rawNonce), 'human ballot: task body records the nonce DIGEST, never the raw nonce')
ok(!emitted.text.includes(rawNonce), 'human ballot: the ballot TEXT never prints the raw nonce (buttons carry it only)')

// (h5) no tap by the deadline -> ABSTAIN (the CNCL-18 miss path, unchanged for human seats)
const rHMiss = await dispatchBallotVote({ deadline: 1, poll: 1, from: 'council', _now: advancingNow(600), _sleep: noSleep,
  _emitBallot: async () => {}, _exec: ballotExec({ rowSeq: [{ status: 'todo' }] }) })(hseat, { question: 'ship?', round: 1 })
ok(rHMiss.vote === 'abstain' && /no vote by deadline/.test(rHMiss.rationale), 'human ballot: no tap by deadline -> abstain')

// the adapter is a drop-in for the engine: runCouncil drives it exactly like the mock adapter
const rEngine = await runCouncil({ role: 'convene', question: 'ship?', seats: [{ id: 'main' }, { id: 'codex' }], councilName: 'council' },
  { seatVote: dispatchBallotVote({ deadline: 100, poll: 1, _now: fixedNow, _sleep: noSleep,
    _exec: ballotExec({ rowSeq: [{ status: 'done', result: 'COUNCIL-VOTE: approve :: fine' }] }) }) })
ok(rEngine.votes.length === 2 && rEngine.votes.every(v => v.vote === 'approve'), 'ballot: dispatchBallotVote plugs into runCouncil as the seatVote adapter')

// ==================== DIVE-1565: ballotTap tap->task-close BRIDGE (offline, stubbed exec) ====================
// A stub `5dive` reader: `task ls --json` returns the configured task rows; `task done <id> --result=…`
// records the close call. NEVER shells a real 5dive. Every audit line is captured (asserted nonce-free).
const NONCE = 'a'.repeat(32)                                    // a 16-byte hex one-time nonce
const DIGEST = createHash('sha256').update(NONCE).digest('hex') // what the ballot body stores
const humanBallot = (over = {}) => ({ id: 1600, ident: 'DIVE-1600', status: 'todo',
  body: `vote please\n[council ballot-auth] nonceDigest=${DIGEST}`, ...over })
function tapExec(cfg = {}) {
  const rows = cfg.rows || [humanBallot()]
  return (args) => {
    if (args[0] === 'task' && args[1] === 'ls') return JSON.stringify({ ok: true, data: { tasks: rows } })
    if (args[0] === 'task' && args[1] === 'done') {
      if (cfg.doneThrows) throw new Error('task done boom')
      if (cfg.doneCalls) cfg.doneCalls.push(args)
      return JSON.stringify({ ok: true, data: {} })
    }
    throw new Error('tapExec: unexpected argv ' + args.join(' '))
  }
}
const auditSink = () => { const lines = []; return { audit: (m) => lines.push(m), lines } }

// (t1) a valid tap prefix-accepts the unique OPEN human ballot, verifies the nonce, and CLOSES it with
// the mapped COUNCIL-VOTE line — the SAME ingress an agent heartbeat writes.
{
  const done = [], a = auditSink()
  const r = ballotTap({ ref: 'DIVE-1600', vote: 'a', nonce: NONCE, _exec: tapExec({ doneCalls: done }), _audit: a.audit })
  ok(r.ok === true && r.vote === 'approve' && r.taskId === 'DIVE-1600', 'ballot-tap: valid approve tap resolves + records approve')
  const doneArg = done[0] || []
  ok(doneArg[0] === 'task' && doneArg[1] === 'done' && doneArg[2] === 'DIVE-1600', 'ballot-tap: closes the resolved ballot task via `task done`')
  ok(doneArg.includes('--result=COUNCIL-VOTE: approve :: (human tap)'), 'ballot-tap: result carries `COUNCIL-VOTE: approve :: (human tap)`')
  ok(a.lines.every(l => !l.includes(NONCE)), 'ballot-tap: no audit line ever prints the raw nonce')
}

// (t2) each vote code maps to the right verb; the third button (Abstain, e) is a valid vote token.
for (const [code, verb] of [['a', 'approve'], ['r', 'reject'], ['e', 'abstain']]) {
  const done = []
  const r = ballotTap({ ref: 'DIVE-1600', vote: code, nonce: NONCE, _exec: tapExec({ doneCalls: done }), _audit: () => {} })
  ok(r.ok && r.vote === verb, `ballot-tap: code ${code} -> ${verb}`)
  ok((done[0] || []).includes(`--result=COUNCIL-VOTE: ${verb} :: (human tap)`), `ballot-tap: ${verb} written to the ballot task`)
}

// (t3) a nonce whose sha256 != the stored digest is UNAUTHENTICATED -> fail-closed, task NOT closed.
{
  const done = []
  const r = ballotTap({ ref: 'DIVE-1600', vote: 'a', nonce: 'b'.repeat(32), _exec: tapExec({ doneCalls: done }), _audit: () => {} })
  ok(r.ok === false && r.reason === 'nonce mismatch' && done.length === 0, 'ballot-tap: wrong nonce -> fail-closed, ballot never closed')
}

// (t4) a prefix that matches NO open human ballot is a MISS (also the one-time replay path: a tapped
// ballot is `done`, so it drops out of the OPEN set and a second tap resolves to a miss).
{
  const r = ballotTap({ ref: 'DIVE-9999', vote: 'a', nonce: NONCE, _exec: tapExec(), _audit: () => {} })
  ok(r.ok === false && r.reason === 'no match', 'ballot-tap: unknown/expired ref -> miss (fail-closed)')
  const doneRow = ballotTap({ ref: 'DIVE-1600', vote: 'a', nonce: NONCE, _exec: tapExec({ rows: [humanBallot({ status: 'done' })] }), _audit: () => {} })
  ok(doneRow.ok === false && doneRow.reason === 'no match', 'ballot-tap: a REPLAY on an already-closed ballot -> miss (one-time)')
}

// (t5) a prefix that matches MORE THAN ONE open human ballot is AMBIGUOUS -> fail-closed (never guess).
{
  const rows = [humanBallot({ id: 1600, ident: 'DIVE-1600' }), humanBallot({ id: 1601, ident: 'DIVE-1601' })]
  const a = auditSink()
  const r = ballotTap({ ref: 'DIVE-160', vote: 'a', nonce: NONCE, _exec: tapExec({ rows }), _audit: a.audit })
  ok(r.ok === false && r.reason === 'ambiguous', 'ballot-tap: an ambiguous prefix -> fail-closed')
  ok(a.lines.some(l => /AMBIGUOUS/.test(l)), 'ballot-tap: the ambiguity is audited')
}

// (t6) the prefix only ever resolves against HUMAN ballots — an agent ballot (no nonceDigest) with the
// same id prefix is invisible to the bridge, so it can never be closed by a tap.
{
  const agentBallot = { id: 1600, ident: 'DIVE-1600', status: 'todo', body: 'Cast your vote by CLOSING this task ...' }
  const r = ballotTap({ ref: 'DIVE-1600', vote: 'a', nonce: NONCE, _exec: tapExec({ rows: [agentBallot] }), _audit: () => {} })
  ok(r.ok === false && r.reason === 'no match', 'ballot-tap: an agent ballot (no nonceDigest) is not tap-closable')
}

// (t7) malformed taps are refused BEFORE any board read (empty ref / bad code / empty nonce).
ok(ballotTap({ ref: '', vote: 'a', nonce: NONCE, _exec: () => { throw new Error('should not exec') }, _audit: () => {} }).reason === 'missing ref', 'ballot-tap: empty ref refused pre-read')
ok(ballotTap({ ref: 'DIVE-1600', vote: 'x', nonce: NONCE, _exec: () => { throw new Error('should not exec') }, _audit: () => {} }).reason === 'bad vote code', 'ballot-tap: bad vote code refused pre-read')
ok(ballotTap({ ref: 'DIVE-1600', vote: 'a', nonce: '', _exec: () => { throw new Error('should not exec') }, _audit: () => {} }).reason === 'missing nonce', 'ballot-tap: empty nonce refused pre-read')

// (t8) nonce verified but `task done` fails -> fail-closed (surface, do not swallow as success).
{
  const r = ballotTap({ ref: 'DIVE-1600', vote: 'a', nonce: NONCE, _exec: tapExec({ doneThrows: true }), _audit: () => {} })
  ok(r.ok === false && r.reason === 'task done failed', 'ballot-tap: a failed close is reported, never a false success')
}

console.log(`\nCNCL-7 dispatch: ${pass} passed, ${fail} failed (bound to src/council/engine.mjs)`)
process.exit(fail ? 1 : 0)
