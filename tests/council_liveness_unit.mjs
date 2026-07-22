// DIVE-1739 unit — full-quorum convene reliability (gate answer A: preserve strict 6/6, fix
// reliability operationally). Covers the two new cli.mjs seams, offline, no `5dive` exec:
//   (1) preflightLiveness — a full-quorum motion refuses to dispatch when any AGENT seat is
//       asleep/deaf/health-unknown, nudges the unreachable seat(s), and exempts human seats.
//   (2) dispatchBallotVote mid-window retry-nudge — one best-effort pane nudge fires ~halfway
//       through the window if the ballot is still open, never fires when the seat votes early, and
//       never fires for a human seat (which votes by tap). Exit 0 == green.
import { preflightLiveness, dispatchBallotVote } from '../src/council/cli.mjs'
import { resolveSeatAgent } from '../src/council/engine.mjs'

let pass = 0, fail = 0
const ok = (c, m) => { c ? pass++ : (fail++, console.error('FAIL:', m)) }

// ---- (1) preflightLiveness ----
const roster = [{ id: 'olivia' }, { id: 'main' }, { id: 'sam' }, { id: 'theo' }, { id: 'dude' }, { id: 'dev' }]
const healthAll = (over = {}) => {
  const m = new Map()
  for (const s of roster) m.set(resolveSeatAgent(s), { asleep: false, deaf: false })
  for (const [k, v] of Object.entries(over)) m.set(resolveSeatAgent({ id: k }), v)
  return m
}
const spyNudge = () => { const calls = []; return [(agent, msg) => calls.push({ agent, msg }), calls] }

{
  const [nudge, calls] = spyNudge()
  const r = preflightLiveness(roster, { _health: healthAll(), _nudge: nudge })
  ok(r.ok === true && r.unreachable.length === 0, 'all seats awake -> ok, nothing unreachable')
  ok(calls.length === 0, 'all awake -> no nudge sent')
}
{
  const [nudge, calls] = spyNudge()
  const r = preflightLiveness(roster, { _health: healthAll({ dude: { asleep: true, deaf: false } }), _nudge: nudge })
  ok(r.ok === false, 'one ASLEEP seat -> full-quorum convene refuses (not ok)')
  ok(r.unreachable.length === 1 && r.unreachable[0].id === 'dude' && r.unreachable[0].why === 'asleep', 'asleep seat surfaced with reason')
  ok(calls.length === 1 && calls[0].agent === resolveSeatAgent({ id: 'dude' }), 'asleep seat gets exactly one wake nudge, to its registry agent')
}
{
  const [nudge, calls] = spyNudge()
  const r = preflightLiveness(roster, { _health: healthAll({ sam: { asleep: false, deaf: true } }), _nudge: nudge })
  ok(r.ok === false && r.unreachable[0].why === 'deaf', 'a DEAF seat is unreachable too')
  ok(calls.length === 1, 'deaf seat nudged once')
}
{
  // a seat missing from the health map entirely == health-unknown == unreachable (fail-closed).
  const m = healthAll(); m.delete(resolveSeatAgent({ id: 'theo' }))
  const [nudge, calls] = spyNudge()
  const r = preflightLiveness(roster, { _health: m, _nudge: nudge })
  ok(r.ok === false && r.unreachable[0].id === 'theo' && r.unreachable[0].why === 'health-unknown', 'unknown-health seat is unreachable (fail-closed)')
  ok(calls.length === 1, 'unknown-health seat nudged once')
}
{
  // human seats vote by Telegram tap (DIVE-1564), not by being an awake agent — exempt from the probe
  // even with NO health entry, so a human-seated council is never falsely blocked as "unreachable".
  const humanRoster = [{ id: 'olivia' }, { id: 'lodar', kind: 'human', chat: '123' }]
  const m = new Map(); m.set(resolveSeatAgent({ id: 'olivia' }), { asleep: false, deaf: false })
  const [nudge, calls] = spyNudge()
  const r = preflightLiveness(humanRoster, { _health: m, _nudge: nudge })
  ok(r.ok === true, 'human seat with no agent-health entry is EXEMPT (not unreachable)')
  ok(calls.length === 0, 'human seat is never pane-nudged')
}

// ---- (2) dispatchBallotVote mid-window retry-nudge ----
// Drive the ballot voter with a fake clock + a stub exec. deadline=100s, poll=10s -> each poll
// advances 10s; nudgeFrac 0.5 -> nudge target ~50s. seatVote returns after collect resolves.
const mkExec = (showRows) => {
  let showIdx = 0
  return (args) => {
    if (args[0] === 'task' && args[1] === 'add') return JSON.stringify({ data: { ident: 'BALLOT-1' } })
    if (args[0] === 'task' && args[1] === 'show') {
      const row = showRows[Math.min(showIdx, showRows.length - 1)]; showIdx++
      return JSON.stringify({ data: { task: row } })
    }
    if (args[0] === 'task' && args[1] === 'cancel') return '{}'
    return '{}'
  }
}
const fakeClock = () => { const s = { t: 1_000_000 }; return [() => s.t, async () => { s.t += 10_000 }, s] }

{
  // ballot stays OPEN the whole window -> nudge fires exactly once, then deadline -> abstain.
  const [now, sleep] = fakeClock()
  const [nudge, calls] = spyNudge()
  const voter = dispatchBallotVote({ deadline: 100, poll: 10, from: 'council', fullQuorum: true,
    _now: now, _sleep: sleep, _exec: mkExec([{ status: 'todo' }]), _nudge: nudge, _emitBallot: async () => ({}) })
  const res = await voter({ id: 'dev' }, { question: 'adopt v0 constitution?', round: 1 })
  ok(res.vote === 'abstain', 'open-till-deadline ballot -> abstain (unchanged)')
  ok(calls.length === 1, 'mid-window nudge fires exactly once on a still-open ballot')
  ok(calls[0].agent === resolveSeatAgent({ id: 'dev' }) && /BALLOT-1/.test(calls[0].msg), 'nudge targets the seat agent and names the ballot task')
}
{
  // seat votes on the FIRST poll (t=1_000_000, before nudgeAt) -> nudge never fires.
  const [now, sleep] = fakeClock()
  const [nudge, calls] = spyNudge()
  const voter = dispatchBallotVote({ deadline: 100, poll: 10, from: 'council', fullQuorum: true,
    _now: now, _sleep: sleep,
    _exec: mkExec([{ status: 'done', result: 'weighed in. COUNCIL-VOTE: approve :: v0 is a no-op adoption' }]),
    _nudge: nudge, _emitBallot: async () => ({}) })
  const res = await voter({ id: 'dev' }, { question: 'adopt v0 constitution?', round: 1 })
  ok(res.vote === 'approve', 'early vote is read normally')
  ok(calls.length === 0, 'a seat that votes before mid-window is NEVER nudged')
}
{
  // human seat: votes by tap, gets no pane nudge even if the ballot stays open past mid-window.
  const [now, sleep] = fakeClock()
  const [nudge, calls] = spyNudge()
  const voter = dispatchBallotVote({ deadline: 100, poll: 10, from: 'council', fullQuorum: true,
    _now: now, _sleep: sleep, _exec: mkExec([{ status: 'todo' }]), _nudge: nudge, _emitBallot: async () => ({}) })
  const res = await voter({ id: 'lodar', kind: 'human', chat: '123' }, { question: 'adopt v0?', round: 1 })
  ok(res.vote === 'abstain', 'un-tapped human ballot -> abstain (unchanged)')
  ok(calls.length === 0, 'human seat is never pane-nudged (it taps)')
}

console.log(`\nDIVE-1739 liveness/nudge unit: ${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
