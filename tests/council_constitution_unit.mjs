import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import {
  DEFAULT_CONSTITUTION, DEFAULT_HARD_GATE_RX, THRESHOLD_POLICY,
  loadConstitution, normalizeConstitution, parseConstitutionFrontmatter, resolveThreshold, tallyVotes,
} from '../src/council/engine.mjs'

let passed = 0
const ok = (condition, name) => {
  assert.ok(condition, name)
  passed++
  console.log(`ok   - ${name}`)
}

const missing = loadConstitution('/definitely/no/constitution.yaml')
ok(missing.source === 'defaults' && missing.valid, 'missing constitution uses valid built-in defaults')
ok(JSON.stringify(missing.thresholds) === JSON.stringify(THRESHOLD_POLICY), 'missing thresholds byte-match the pre-constitution policy')
ok(missing.hardGateRegex === DEFAULT_HARD_GATE_RX, 'missing hard-gate regex byte-matches pre-constitution behavior')
ok(missing.veto.holdSecs === 900 && missing.veto.posthocSecs === 172800, 'missing veto windows match pre-constitution behavior')

const doc = `council:
  bench: security
quorum: none # ordinary-class participation rule
thresholds:
  ordinary: 1
  promote: majority
  demote: 3/4
  constitutional:
    rule: fraction
    value: 0.75
    quorum: all
    require_quorum: true
veto:
  principals: [human:main, human:owner]
  hold_secs: 0
  posthoc_secs: 86400
hard_gates:
  money: 'spend|billing'
  comms: 'brand|press'
ship:
  require_ci: true
comms:
  public_requires_human: true
# Company Constitution: a comment is digest-covered but not parsed as policy.
`
const parsed = parseConstitutionFrontmatter(doc)
const loaded = normalizeConstitution(parsed)
ok(loaded.council.bench === 'security', 'roster pointer loads from council.bench')
ok(loaded.thresholds.ordinary.rule === 'flat' && loaded.thresholds.ordinary.threshold === 1, 'ordinary threshold loads as flat 1')
ok(loaded.thresholds.demote.rule === 'fraction' && loaded.thresholds.demote.value === 0.75, 'fraction threshold loads from a/b')
ok(loaded.thresholds.constitutional.quorum === 'all' && loaded.thresholds.constitutional.requireQuorum, 'constitutional full quorum loads')
ok(loaded.veto.principals.join(',') === 'human:main,human:owner' && loaded.veto.holdSecs === 0, 'veto principals + zero hold load')
ok(loaded.hardGateRegex.includes('brand') && loaded.hardGateRegex.includes('billing'), 'hard-gate classes compile to a live regex')
ok(loaded.ship.require_ci === true && loaded.comms.public_requires_human === true, 'ship/comms rules are parsed into governance params')

// DIVE-1700 — the enforced object form (rule: fraction, value: X) must accept EXACT 'a/b'
// fractions, not just floats. A truncated decimal is a governance bug: ceil(0.667*6)=5 where
// true 2/3 gives 4 on a 6-seat council, so demote/expel would need 5/6 instead of 4/6.
const twoThirds = normalizeConstitution({ thresholds: { demote: { rule: 'fraction', value: '2/3' } } })
ok(twoThirds.thresholds.demote.rule === 'fraction' && twoThirds.thresholds.demote.value === 2 / 3, "object form accepts exact '2/3' (was rejected: Number('2/3')->NaN)")
ok(resolveThreshold(6, twoThirds.thresholds.demote) === 4, "exact 2/3 resolves to 4/6, not the 5/6 a 0.667 double rounds to")
ok(resolveThreshold(6, normalizeConstitution({ thresholds: { demote: { rule: 'fraction', value: 0.667 } } }).thresholds.demote) === 5, 'the naive 0.667 float still (correctly) rounds to 5/6 — motivating exact fractions')
const scalarFrac = normalizeConstitution({ thresholds: { demote: '2/3' } })
ok(scalarFrac.thresholds.demote.value === 2 / 3, "scalar '2/3' form keeps parsing to exact 2/3")
for (const bad of ['2/0', '3/2', 'abc', '2/3/4']) {
  let threw = false
  try { normalizeConstitution({ thresholds: { demote: { rule: 'fraction', value: bad } } }) } catch { threw = true }
  ok(threw, `object fraction rejects garbage '${bad}' (guardrail: out of range / non-fraction)`)
}

const votes = [{ seat: 'a', vote: 'approve' }, { seat: 'b', vote: 'reject' }]
const customTally = tallyVotes(votes, { policy: loaded.thresholds, decisionClass: 'ordinary', seatCount: 2 })
ok(customTally.threshold === 1 && customTally.quorum === 0 && customTally.recommendation === 'approve', 'tally consumes loaded threshold + quorum policy')
const defaultTally = tallyVotes(votes, { decisionClass: 'ordinary', seatCount: 2 })
ok(defaultTally.threshold === 2 && defaultTally.quorum === 2 && defaultTally.recommendation === 'reject', 'tally without constitution retains old policy')

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'constitution-unit-'))
try {
  const file = path.join(tmp, 'constitution.yaml')
  fs.writeFileSync(file, doc)
  const fromFile = loadConstitution(file)
  ok(fromFile.source === 'file' && fromFile.valid && fromFile.council.bench === 'security', 'valid file loads from disk')
  const cli = JSON.parse(execFileSync('node', ['src/council/cli.mjs', 'convene', 'ship?', '--seats=a,b', '--stamped-at=T', `--constitution-path=${file}`], {
    cwd: path.resolve(path.dirname(new URL(import.meta.url).pathname), '..'),
    env: { ...process.env, COUNCIL_MOCK: '1' }, encoding: 'utf8',
  }))
  ok(cli.verdict.threshold === 1 && cli.verdict.quorum === 0 && cli.constitution.source === 'file', 'convene CLI loads constitution into live tally')
  fs.writeFileSync(file, 'not frontmatter\n')
  const malformed = loadConstitution(file)
  ok(!malformed.valid && malformed.source === 'defaults', 'malformed file fails closed to defaults')
  ok(malformed.hardGateRegex === DEFAULT_HARD_GATE_RX, 'malformed file never applies partial hard-gate policy')
  fs.writeFileSync(file, `---\nthresholds:\n  typo_class: 1\n---\n`)
  ok(loadConstitution(file).valid === false, 'unknown threshold class fails the whole document closed')
  fs.writeFileSync(file, `---\nhard_gates:\n  unsafe: 'brand(?= launch)'\n---\n`)
  ok(loadConstitution(file).valid === false, 'non-POSIX hard-gate pattern fails the whole document closed')
  fs.writeFileSync(file, `---\nthresholds:\n  ordinary: 1\nveto:\n  hold_secs: soon\n---\n`)
  const invalidDuration = loadConstitution(file)
  ok(!invalidDuration.valid && invalidDuration.thresholds.ordinary.rule === 'majority', 'invalid veto duration rejects the whole document instead of partially applying thresholds')
  fs.writeFileSync(file, `---\nthresholds:\n  ordinary: 1\nhard_gate:\n  public: brand\n---\n`)
  const unknownField = loadConstitution(file)
  ok(!unknownField.valid && unknownField.thresholds.ordinary.rule === 'majority', 'unknown top-level field rejects the whole document atomically')
} finally {
  fs.rmSync(tmp, { recursive: true, force: true })
}

ok(DEFAULT_CONSTITUTION.council.bench === 'council', 'default constitution points at the primary council')
console.log(`-----\ncouncil_constitution_unit: ${passed} passed, 0 failed`)
