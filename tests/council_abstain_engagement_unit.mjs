// DIVE-2891 unit — WHICH SILENCE WAS IT? Under `quorum: all` + `require_quorum: true` an abstention
// is a SILENT VETO, so a seat that could not answer and a seat that withheld consent must stop
// producing the same record. Until this change they did: both landed on `no vote by deadline` with
// no field on the sealed receipt able to separate them.
//
// Proven live 2026-08-07: codex's ballot went in_progress -> todo at ~10:40Z with 32 minutes left
// while `5dive agent info codex` reported active/enabled; the quota lock existed ONLY in a tmux pane
// that happened to be read while the round was still open. At the deadline the receipt sealed a bare
// abstain. Five seats cast and agreed; the instrument could not collect the sixth, and the durable
// record could not say so.
//
// The fix is pure instrumentation (remedy (a) on the row): the collect loop ALREADY polls `task show`
// every tick and reads a status it only tested for done/cancelled. The transitions separate the cases
// at zero cost and with no pane-scraping. Quorum, tally and capture semantics are UNTOUCHED — graded
// explicitly below, because "it made the failure legible" would not be worth a receipt-format change
// if it also moved a count.
//
// Offline: no network, no `5dive` exec (injected _exec/_now/_sleep seams). Exit 0 == green.
import { canonicalTranscript, captureAudit, normalizeSeatVote } from '../src/council/engine.mjs'
import { dispatchBallotVote } from '../src/council/cli.mjs'

let pass = 0, fail = 0
const ok = (c, m) => { c ? pass++ : (fail++, console.error('FAIL:', m)) }

// ---- seams -------------------------------------------------------------------------------
// A clock that advances a fixed step per READ, so a deadline is reached after a known number of
// poll iterations rather than by wall time.
// `task add` mints DIVE-77 (shape per the CNCL-18 mint reader); `task show` walks rowSeq and then
// repeats its last entry forever, so a sequence describes the ballot's life up to the deadline.
const ballotExec = ({ rowSeq = [], captured = null } = {}) => {
  let i = 0
  return (args) => {
    if (captured) captured.push(args)
    if (args[0] === 'task' && args[1] === 'add') return JSON.stringify({ data: { ident: 'DIVE-77' } })
    if (args[0] === 'task' && args[1] === 'show') {
      const row = rowSeq[Math.min(i, rowSeq.length - 1)] || { status: 'todo' }
      i += 1
      return JSON.stringify({ data: { task: { ident: 'DIVE-77', result: '', ...row } } })
    }
    return ''
  }
}
const seat = { id: 'codex', lens: 'engineering' }
// Deterministic clock: `_sleep` is the only thing that advances it, so the deadline is reached after
// exactly `deadline / poll` poll iterations regardless of wall time.
const drive = (rowSeq, deadline = 5) => {
  let t = 0
  return dispatchBallotVote({
    deadline, poll: 1, _now: () => t, _sleep: async (ms) => { t += ms },
    _exec: ballotExec({ rowSeq }),
  })(seat, { question: 'ratify?', round: 1 })
}

// ---- A: the four silences are now distinguishable, and named for what was OBSERVED --------------

// A1 — the fingerprint that actually happened: claimed, then handed back.
const released = await drive([{ status: 'in_progress' }, { status: 'todo' }, { status: 'todo' }])
ok(released.vote === 'abstain', 'A1 a released ballot is still an ABSTAIN (tally semantics unchanged)')
ok(released.abstainKind === 'silent:released', `A1 a claimed-then-released ballot is kind silent:released (got ${released.abstainKind})`)
ok(/CLAIMED THEN RELEASED/.test(released.rationale), 'A1 the rationale states the observed transition')

// A2 — never claimed at all: a different failure with a different remedy.
const noPickup = await drive([{ status: 'todo' }])
ok(noPickup.abstainKind === 'silent:no-pickup', `A2 a ballot never claimed is kind silent:no-pickup (got ${noPickup.abstainKind})`)

// A3 — engaged and ran out of window.
const held = await drive([{ status: 'in_progress' }])
ok(held.abstainKind === 'silent:held-open', `A3 a ballot held in_progress to the deadline is kind silent:held-open (got ${held.abstainKind})`)

// A4 — the most misleading one: the seat CLOSED the ballot without casting, so every board reads it
//      as worked.
const closedNoVote = await drive([{ status: 'done', result: 'I read it and I am not sure.' }])
ok(closedNoVote.vote === 'abstain', 'A4 a ballot closed with no COUNCIL-VOTE line is still an ABSTAIN')
ok(closedNoVote.abstainKind === 'silent:closed-no-vote', `A4 closed-without-voting is its own kind (got ${closedNoVote.abstainKind})`)

// A5 — MUTATION CONTROL for the arms above: a real vote must carry NO silence kind, or every
//      assertion here would be satisfied by stamping a kind unconditionally.
const realVote = await drive([{ status: 'done', result: 'COUNCIL-VOTE: approve :: fine' }])
ok(realVote.vote === 'approve' && realVote.abstainKind == null, 'A5 a seat that actually voted carries NO abstainKind (the kinds are not stamped blindly)')

// A6 — the four kinds are DISTINCT. Without this, "distinguishable" is asserted by four arms that
//      would all pass if the classifier collapsed to one value.
const kinds = new Set([released.abstainKind, noPickup.abstainKind, held.abstainKind, closedNoVote.abstainKind])
ok(kinds.size === 4, `A6 all four silences map to DISTINCT kinds (got ${kinds.size}: ${[...kinds].join(', ')})`)

// A7 — the record names the OBSERVATION, not a diagnosis. The entire 2026-08-07 failure thread is
//      instruments that were right about a fact and wrong about the cause; this one must not join
//      them by asserting a throttle it cannot see.
ok(!/throttl(e|ed)\b(?!.*not proof)/i.test(released.rationale.replace(/a release is what the 2026-08-07 quota lock looked like[^.]*\./, '')),
   'A7 the rationale does not DIAGNOSE a throttle')
ok(/NOT why/.test(released.rationale) && /read the seat's pane/.test(released.rationale),
   'A7 the rationale says explicitly that it records what happened, not why, and where to look')

// ---- B: the receipt SEALS it — the durable record is the point, not the run ---------------------
const recWith = { council: 'c', mode: 'deliberate', stampedAt: 't', question: 'q', seats: ['codex', 'main'],
  votes: [{ seat: 'main', vote: 'approve', rationale: 'ok' }, { seat: 'codex', vote: 'abstain', abstainKind: 'silent:released', rationale: 'no vote by deadline' }],
  verdict: { recommendation: 'approve', confidence: 1, tally: { approve: 1, reject: 0, escalate: 0 } } }
const tWith = canonicalTranscript(recWith)
ok(/^silent: codex:silent:released$/m.test(tWith), 'B1 the sealed transcript carries a `silent:` line naming the seat and its kind')

// B2 — THE COMPATIBILITY GUARANTEE, and the reason the line is conditional. Every record written
//      before this change has abstains whose kind (if any) does NOT start with `silent:`. Those must
//      seal BYTE-IDENTICALLY or `council verify` goes red on historical receipts — a governance rail
//      failing on its own past is a far worse outcome than the defect being fixed.
const recLegacy = { ...recWith, votes: [{ seat: 'main', vote: 'approve', rationale: 'ok' }, { seat: 'codex', vote: 'abstain', rationale: 'no vote by deadline' }] }
const tLegacy = canonicalTranscript(recLegacy)
ok(!/^silent:/m.test(tLegacy), 'B2 a pre-DIVE-2891 record (abstain, no kind) seals with NO `silent:` line')
ok(tLegacy === tWith.split('\n').filter(l => !l.startsWith('silent:')).join('\n'),
   'B2 …and is otherwise byte-identical to the new transcript minus that one line')

// B2b — THE ARM THAT KILLED ITERATION 1, and the one this predicate exists for. `unparsed` is a
//       PRE-EXISTING kind (src/council/cli.mjs — a seat that DID reply, off-format) and it carries
//       capture:TRUE, so it satisfied iteration 1's `capture !== false && abstainKind` filter
//       exactly. Note the fixture has NO capture field at all: normalizeSeatVote persists
//       abstainKind always and capture only when it is false, so this is the shape an unparsed
//       abstain actually takes on disk, not a hypothetical.
//
//       It has to be a fixture and not a census of the store: olivia measured that not one of the
//       30 on-disk receipts carries any abstainKind field today, so a check against real receipts
//       passes on zero and proves nothing. The break was LATENT — luck, not a guarantee — and the
//       arm has to construct the case luck was hiding.
//
//       Two failures in one, in both directions in time. BACKWARDS: a historical receipt with an
//       unparsed abstain re-seals under new bytes and `council verify` goes red on it. FORWARDS: a
//       seat that SPOKE gets written onto a line named `silent:` — this row's own failure class,
//       inside its own fix.
const recUnparsed = { ...recWith, votes: [{ seat: 'main', vote: 'approve', rationale: 'ok' },
  { seat: 'codex', vote: 'abstain', abstainKind: 'unparsed', rationale: 'codex replied but with no COUNCIL-VOTE line' }] }
const tUnparsed = canonicalTranscript(recUnparsed)
ok(!/^silent:/m.test(tUnparsed),
   'B2b an `unparsed` abstain (pre-existing kind, capture:true, seat SPOKE) seals with NO `silent:` line')
// Compared against the SAME fixture with the kind stripped — not against recLegacy, whose rationale
// differs and which would make this pass or fail for a reason that is not the kind.
const tUnparsedNoKind = canonicalTranscript({ ...recUnparsed,
  votes: recUnparsed.votes.map(v => { const { abstainKind, ...rest } = v; return rest }) })
ok(tUnparsed === tUnparsedNoKind,
   'B2b …and seals BYTE-IDENTICALLY to the same record with the kind stripped — historical invariance by construction')
// Positive control for B2b: the identical fixture with a `silent:` kind DOES seal the line, so the
// arm above grades the prefix predicate and not a canonicalTranscript that emits nothing.
const tUnparsedControl = canonicalTranscript({ ...recUnparsed,
  votes: recUnparsed.votes.map(v => v.seat === 'codex' ? { ...v, abstainKind: 'silent:no-pickup' } : v) })
ok(/^silent: codex:silent:no-pickup$/m.test(tUnparsedControl),
   'B2b positive control: the same record with a silence kind DOES seal the line')

// B3 — a capture failure keeps going to `unreached:` ONLY. The two lines answer different questions
//      ("never asked" vs "asked, never answered") and a seat must not appear on both.
const recUnreached = { ...recWith, votes: [{ seat: 'main', vote: 'approve', rationale: 'ok' }, { seat: 'codex', vote: 'abstain', abstainKind: 'nudge-failed', capture: false, rationale: 'CAPTURE FAILED' }] }
const tUnreached = canonicalTranscript(recUnreached)
ok(/^unreached: codex:nudge-failed$/m.test(tUnreached), 'B3 a capture failure still seals on `unreached:`')
ok(!/^silent:/m.test(tUnreached), 'B3 …and does NOT also appear on `silent:` (no double-listing)')

// B4 — a healthy convene (nobody silent, nobody unreached) seals neither line.
const recClean = { ...recWith, votes: [{ seat: 'main', vote: 'approve', rationale: 'ok' }, { seat: 'codex', vote: 'reject', rationale: 'no' }] }
const tClean = canonicalTranscript(recClean)
ok(!/^silent:/m.test(tClean) && !/^unreached:/m.test(tClean), 'B4 a fully-voting convene seals neither line (byte-identical to before)')

// ---- C: QUORUM AND CAPTURE SEMANTICS ARE UNTOUCHED ---------------------------------------------
// The row is explicit that relaxing 6/6 is a constitutional call and not an engineering one, so this
// change must not move a single count. If it did, remedy (a) would have quietly become remedy (b).
const auditNew = captureAudit(recWith.votes)
const auditLegacy = captureAudit(recLegacy.votes)
ok(auditNew.seatCount === auditLegacy.seatCount && auditNew.abstains === auditLegacy.abstains,
   'C1 seatCount and abstains are identical with and without the new kind')
ok(auditNew.captureFailed === 0 && auditLegacy.captureFailed === 0,
   'C2 a silent abstain is NOT counted as a capture failure — it is a real abstention and still tallies as one')
ok(captureAudit(recUnreached.votes).captureFailed === 1,
   'C3 …while a genuine capture failure still counts as one (the distinction is preserved, not blurred)')
// C4 — normalizeSeatVote must carry the new kind through unchanged; it is the funnel every adapter
//      result passes, and a kind dropped there would be a kind that never reaches the seal.
const normalized = normalizeSeatVote(seat, { vote: 'abstain', abstainKind: 'silent:released', rationale: 'r' })
ok(normalized.abstainKind === 'silent:released' && normalized.capture !== false,
   'C4 normalizeSeatVote carries a silence kind through WITHOUT marking it a capture failure')

console.log(`council_abstain_engagement_unit: ${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
