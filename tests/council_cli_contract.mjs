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

// default roster when no seats given = the 5 standing seats (CNCL-8: the primary council now
// requires a genesis roster — --genesis-exists mirrors bash finding the sealed genesis file).
r = runCli(['convene', 'q?', '--genesis-exists=1', '--stamped-at=T'], MOCK)
v = JSON.parse(r.out)
ok('default roster = 5 standing seats', v.seats.length === 5 && v.seats.includes('olivia') && v.council === 'council')

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

// --- CNCL-8: human-seeded genesis roster + fail-closed guards ----------------
// convene the primary council WITHOUT a genesis roster -> fail closed (exit 8).
r = runCli(['convene', 'q?', '--genesis-exists=0', '--stamped-at=T'], MOCK)
ok('convene primary council w/ genesis-exists=0 (string) fails closed (exit 8)', r.code === 8)
r = runCli(['convene', 'q?', '--bench=council', '--genesis-exists=0', '--stamped-at=T'], MOCK)
ok('convene --bench=council w/ genesis-exists=0 fails closed (exit 8)', r.code === 8)
// an ad-hoc panel (explicit --seats) is NOT the governance body -> still allowed.
r = runCli(['convene', 'q?', '--seats=a,b,c', '--stamped-at=T'], MOCK)
ok('ad-hoc --seats convene NOT gated by genesis', r.code === 0)

const greg = path.join(os.tmpdir(), `council-genesis-${process.pid}.json`)
try { fs.unlinkSync(greg) } catch {}
// init once: seeds the council bench + emits a canonical record for bash to seal.
r = runCli(['init', '--seats=main:chair,codex,olivia', '--threshold=2/3', '--veto=human:main', '--veto-resolved=433634012', '--genesis-exists=0', `--registry=${greg}`, '--stamped-at=T'])
ok('init once exits 0', r.code === 0)
let g = JSON.parse(r.out)
ok('init emits genesis record + canonical', g.genesis && g.genesis.kind === 'genesis' && typeof g.canonical === 'string')
ok('init records the chair', g.chair === 'main' && g.genesis.seats.find(s => s.id === 'main').chair === true)
ok('init records resolved veto principal', g.genesis.veto.principal === 'human:main' && g.genesis.veto.resolved === '433634012')
ok('init seeds the council bench (motion-governed)', JSON.parse(fs.readFileSync(greg, 'utf-8')).council.genesis === true)
// init TWICE (genesis already exists) -> refused, unless --force.
r = runCli(['init', '--seats=a,b', '--veto=human:main', '--veto-resolved=1', `--registry=${greg}`, '--genesis-exists=1', '--stamped-at=T'])
ok('init twice refused (exit 5)', r.code === 5)
r = runCli(['init', '--seats=a,b', '--veto=human:main', '--veto-resolved=1', `--registry=${greg}`, '--genesis-exists=1', '--force', '--stamped-at=T'])
ok('init --force re-seed allowed + flagged in record', r.code === 0 && JSON.parse(r.out).genesis.forced === true)
// init REFUSES an unresolvable veto principal (bash passes no --veto-resolved).
r = runCli(['init', '--seats=a,b', '--veto=human:ghost', `--registry=${greg}`, '--stamped-at=T'])
ok('init refuses unresolvable veto principal (exit 6)', r.code === 6)
// bad threshold / seats fail closed.
ok('init bad threshold refused', runCli(['init', '--seats=a', '--threshold=nonsense', '--veto=human:main', '--veto-resolved=1', `--registry=${greg}`]).code === 2)
ok('init duplicate seat refused', runCli(['init', '--seats=a,a', '--veto=human:main', '--veto-resolved=1', `--registry=${greg}`]).code === 2)
ok('init two chairs refused', runCli(['init', '--seats=a:chair,b:chair', '--veto=human:main', '--veto-resolved=1', `--registry=${greg}`]).code === 2)

// raw bench add/rm on the primary council is refused (governance bypass) -> exit 7.
r = runCli(['bench', 'add', 'council', '--seats=x:y', `--registry=${greg}`])
ok('raw bench add on council refused (exit 7)', r.code === 7)
r = runCli(['bench', 'rm', 'council', `--registry=${greg}`])
ok('raw bench rm on council refused (exit 7)', r.code === 7)
try { fs.unlinkSync(greg) } catch {}

console.error(`\nCNCL-6/7/8 CLI contract: ${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
