#!/usr/bin/env node
// CNCL-6 — CLI + embed contract. Guards three things:
//   1. the engine/cli embedded in src/cmd_council.sh byte-match the canonical
//      src/council/*.mjs (no silent drift of the shipped copy),
//   2. gen_cmd.mjs is reproducible (re-generating yields the committed file),
//   3. the `convene` + `bench` CLI behaves per contract, offline via COUNCIL_MOCK.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'
import os from 'node:os'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const R = (p) => fs.readFileSync(path.join(root, p), 'utf-8')
let pass = 0, fail = 0
const ok = (name, cond) => { if (cond) { pass++ } else { fail++; console.error(`FAIL: ${name}`) } }
const cliPath = path.join(root, 'src', 'council', 'cli.mjs')
const runCli = (args, env = {}) => {
  try {
    const out = execFileSync('node', [cliPath, ...args], { env: { ...process.env, ...env }, encoding: 'utf-8' })
    return { code: 0, out }
  } catch (e) { return { code: e.status ?? 1, out: e.stdout || '', err: e.stderr || '' } }
}

// --- 1 + 2: embed / reproducibility -----------------------------------------
function extractHeredoc(sh, delim) {
  const lines = sh.split('\n')
  const start = lines.findIndex(l => l.includes(`<<'${delim}'`))
  const end = lines.findIndex((l, i) => i > start && l === delim)
  return lines.slice(start + 1, end).join('\n')
}
const shipped = R('src/cmd_council.sh')
ok('engine embed matches canonical', extractHeredoc(shipped, 'COUNCIL_ENGINE_MJS') === R('src/council/engine.mjs').replace(/\n$/, ''))
ok('cli embed matches canonical', extractHeredoc(shipped, 'COUNCIL_CLI_MJS') === R('src/council/cli.mjs').replace(/\n$/, ''))
execFileSync('node', [path.join(root, 'src/council/gen_cmd.mjs')], { stdio: 'ignore' })
ok('gen_cmd reproducible (clean tree)', R('src/cmd_council.sh') === shipped)

// --- 3: convene contract (offline mock) -------------------------------------
const MOCK = { COUNCIL_MOCK: '1' }
let r = runCli(['convene', 'Ship it?', '--seats=a,b,c', '--mode=deliberate', '--stamped-at=T'], MOCK)
ok('convene exits 0', r.code === 0)
let v = JSON.parse(r.out)
ok('convene passes with 3/3 approve', v.disposition === 'pass' && v.verdict.tally.approve === 3)
ok('convene receipt canonical present + veto:none inside bytes', /veto: none/.test(v.receipt.canonical))
ok('convene receipt exposes root seal command', /gate-proof sign/.test(v.receipt.seal))

// founder veto flips a pass to blocked, recorded inside the canonical bytes
r = runCli(['convene', 'Ship it?', '--seats=a,b,c', '--veto-by=lodar', '--veto-reason=hold', '--stamped-at=T'], MOCK)
v = JSON.parse(r.out)
ok('founder veto -> blocked', v.disposition === 'blocked' && v.verdict.vetoed === true)
ok('veto recorded in signed bytes', /veto: lodar/.test(v.receipt.canonical))

// default roster when no seats given = the 5 standing seats
r = runCli(['convene', 'q?', '--stamped-at=T'], MOCK)
v = JSON.parse(r.out)
ok('default roster = 5 standing seats', v.seats.length === 5 && v.seats.includes('olivia'))

// --- CNCL-7: dispatch path is the DEFAULT (real seated agents, no model key) -------------
r = runCli(['convene', 'Ship it?', '--seats=a,b,c', '--stamped-at=T'], MOCK)
v = JSON.parse(r.out)
ok('convene defaults to real-agent dispatch', v.dispatch === 'real-agents')
ok('convene surfaces per-seat votes', Array.isArray(v.votes) && v.votes.length === 3 && v.votes.every(x => x.seat && x.vote))
// --standalone selects the deferred single-key modelCall seam (still offline under COUNCIL_MOCK)
r = runCli(['convene', 'Ship it?', '--seats=a,b,c', '--standalone', '--stamped-at=T'], MOCK)
v = JSON.parse(r.out)
ok('--standalone selects the modelCall seam', v.dispatch === 'standalone-seam' && v.disposition === 'pass')

// --- 3: bench registry contract ---------------------------------------------
r = runCli(['bench', 'ls'])
ok('bench ls lists built-ins', JSON.parse(r.out).benches.some(b => b.name === 'ship' && b.builtin))
r = runCli(['bench', 'show', 'nope'])
ok('unknown bench fails closed (exit 3)', r.code === 3)

const reg = path.join(os.tmpdir(), `council-contract-${process.pid}.json`)
try { fs.unlinkSync(reg) } catch {}
r = runCli(['bench', 'add', 'rel', '--seats=main:x|codex:y', '--mode=adversarial', '--threshold=2', `--registry=${reg}`])
ok('bench add persists', r.code === 0 && JSON.parse(fs.readFileSync(reg, 'utf-8')).rel.seats.length === 2)
r = runCli(['convene', 'roll?', '--bench=rel', `--registry=${reg}`, '--stamped-at=T'], MOCK)
v = JSON.parse(r.out)
ok('convene --bench resolves persisted seats+mode', v.council === 'rel' && v.mode === 'adversarial' && v.seats.length === 2)
r = runCli(['bench', 'rm', 'ship', `--registry=${reg}`])
ok('cannot rm a built-in (exit 4)', r.code === 4)
r = runCli(['bench', 'rm', 'rel', `--registry=${reg}`])
ok('rm custom bench', r.code === 0 && !('rel' in JSON.parse(fs.readFileSync(reg, 'utf-8'))))
try { fs.unlinkSync(reg) } catch {}

console.error(`\nCNCL-6 CLI contract: ${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
