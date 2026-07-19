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

// CNCL-9 FORGE REFUSAL: convene can NEVER assert a veto from a plain string (the pre-CNCL-9 hole).
r = runCli(['convene', 'Ship it?', '--seats=a,b,c', '--veto-by=lodar', '--veto-reason=hold', '--stamped-at=T'], MOCK)
ok('forged --veto-by is refused (exit 9)', r.code === 9)
ok('forge refusal is logged/explained', /refused:.*veto-by/.test(r.err || ''))

// CNCL-9 NON-BLOCKING OFFER: a primary-council pass records the offer + STAYS a pass.
r = runCli(['convene', 'Ship it?', '--seats=a,b,c', '--veto-principal=human:main', '--veto-resolved=433634012', '--veto-window=900', '--stamped-at=T'], MOCK)
v = JSON.parse(r.out)
ok('veto offer does NOT block (pass stays pass)', v.disposition === 'pass' && v.verdict.vetoed !== true)
ok('offer recorded inside the signed bytes', /veto: offered human:main window 900s :: offered-not-exercised/.test(v.receipt.canonical))

// CNCL-9 AUTHENTICATED EXERCISE: hold-tier tap flips to blocked; wrong recipient is refused.
const vjson = JSON.stringify(v.verdict)
r = runCli(['veto', 'exercise', '--orig-digest=D1', '--by=human:main', '--resolved=433634012', '--tier=hold', '--reason=hold', `--verdict=${vjson}`, '--stamped-at=T'])
let vx = JSON.parse(r.out)
ok('hold-tier exercise -> blocked + chained record', vx.disposition === 'blocked' && vx.vetoRecord.origDigest === 'D1' && vx.vetoRecord.tier === 'hold')
r = runCli(['veto', 'exercise', '--orig-digest=D1', '--by=human:main', '--resolved=433634012', '--tier=posthoc', `--verdict=${vjson}`, '--stamped-at=T'])
vx = JSON.parse(r.out)
ok('posthoc-tier exercise -> unwind required', vx.disposition === 'blocked' && vx.vetoRecord.unwindRequired === true)
r = runCli(['veto', 'exercise', '--orig-digest=D1', '--by=human:main', '--resolved=999999', '--tier=hold', `--verdict=${vjson}`], {})
ok('exercise from wrong recipient is refused (exit 9)', r.code === 9)

// default roster when no seats given = the 5 standing seats (CNCL-8: the primary council now
// requires a genesis roster — --genesis-exists mirrors bash finding the sealed genesis file).
r = runCli(['convene', 'q?', '--genesis-exists=1', '--stamped-at=T'], MOCK)
v = JSON.parse(r.out)
ok('default roster = 5 role-archetype seats', v.seats.join(',') === 'eng-lead,brand,builder,strategy,contrarian' && v.council === 'council')

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

// --- CNCL-16 + CNCL-18: seat->agent resolution + fail-closed pre-flight (REAL dispatch path) --
// A fake `5dive` bin stands in for the fleet: `agent list` returns a fixed registry; the DEFAULT
// dispatch is now the non-blocking BALLOT (CNCL-18) so `task add` logs the --assignee it minted to
// (the reached agent) and `task show` immediately returns a CLOSED task with an approve vote (so
// the collection loop resolves at once — never blocks on the 900s deadline). The `--ask-rail`
// escape hatch still reaches the seat over `agent ask`, logged the same way. NOTE: no COUNCIL_MOCK
// here, so the real dispatch adapter + preflight run (COUNCIL_5DIVE_BIN points at the fake).
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cncl16-'))
const askLog = path.join(tmp, 'asks.log')
const fakeBin = path.join(tmp, 'fake-5dive')
fs.writeFileSync(fakeBin, [
  '#!/usr/bin/env bash',
  'if [ "$1" = "agent" ] && [ "$2" = "list" ]; then',
  '  echo \'{"ok":true,"data":[{"name":"marketing"},{"name":"creative"},{"name":"main"},{"name":"codex"},{"name":"olivia"}]}\'; exit 0',
  'fi',
  'if [ "$1" = "task" ] && [ "$2" = "add" ]; then',   // CNCL-18 ballot mint: log the assignee reached
  '  for a in "$@"; do case "$a" in --assignee=*) [ -n "$ASK_LOG" ] && echo "${a#--assignee=}" >> "$ASK_LOG" ;; esac; done',
  '  echo \'{"ok":true,"data":{"id":1,"ident":"DIVE-1"}}\'; exit 0',
  'fi',
  'if [ "$1" = "task" ] && [ "$2" = "show" ]; then',  // ballot already voted (closed w/ result)
  '  echo \'{"ok":true,"data":{"task":{"status":"done","result":"COUNCIL-VOTE: approve :: fake ok"}}}\'; exit 0',
  'fi',
  'if [ "$1" = "agent" ] && [ "$2" = "ask" ]; then',  // --ask-rail escape hatch: log the target
  '  [ -n "$ASK_LOG" ] && echo "$3" >> "$ASK_LOG"',
  '  echo \'{"ok":true,"data":{"reply":"COUNCIL-VOTE: approve :: fake ok"}}\'; exit 0',
  'fi',
  'exit 1', '',
].join('\n'))
fs.chmodSync(fakeBin, 0o755)
const REAL = { COUNCIL_5DIVE_BIN: fakeBin, ASK_LOG: askLog, COUNCIL_MOCK: '' }

// DEFAULT (ballot) path: persona seats theo/lilbro resolve to marketing/creative and the convene
// MINTS the ballot task to them for real (via --assignee).
try { fs.writeFileSync(askLog, '') } catch {}
r = runCli(['convene', 'Ship it?', '--seats=theo,lilbro,main', '--mode=deliberate', '--stamped-at=T', '--ballot-deadline=5', '--ballot-poll=1'], REAL)
ok('CNCL-18 ballot convene with persona seats exits 0 (no silent abstain)', r.code === 0)
ok('CNCL-18 default dispatch is real-agents (ballot)', /"dispatch":"real-agents"/.test(r.out || ''))
let asked = (() => { try { return fs.readFileSync(askLog, 'utf-8') } catch { return '' } })()
ok('CNCL-16 ballot REACHES marketing (persona theo resolved)', /(^|\n)marketing(\n|$)/.test(asked))
ok('CNCL-16 ballot REACHES creative (persona lilbro resolved)', /(^|\n)creative(\n|$)/.test(asked))
ok('CNCL-16 ballot never mints to the bare persona id', !/(^|\n)(theo|lilbro)(\n|$)/.test(asked))

// --ask-rail escape hatch: the OLD `agent ask` pane-scrape still reaches the resolved agent.
try { fs.writeFileSync(askLog, '') } catch {}
r = runCli(['convene', 'Ship it?', '--seats=theo,lilbro,main', '--mode=deliberate', '--stamped-at=T', '--ask-rail', '--timeout=5'], REAL)
ok('CNCL-18 --ask-rail convene exits 0', r.code === 0)
asked = (() => { try { return fs.readFileSync(askLog, 'utf-8') } catch { return '' } })()
ok('CNCL-18 --ask-rail REACHES marketing over agent ask', /(^|\n)marketing(\n|$)/.test(asked))
ok('CNCL-18 --ask-rail REACHES creative over agent ask', /(^|\n)creative(\n|$)/.test(asked))

// COUNCIL_ASK_RAIL=1 selects the escape hatch too (env parity with the flag).
try { fs.writeFileSync(askLog, '') } catch {}
r = runCli(['convene', 'Ship it?', '--seats=main', '--mode=deliberate', '--stamped-at=T', '--timeout=5'], { ...REAL, COUNCIL_ASK_RAIL: '1' })
asked = (() => { try { return fs.readFileSync(askLog, 'utf-8') } catch { return '' } })()
ok('CNCL-18 COUNCIL_ASK_RAIL=1 selects the ask rail', r.code === 0 && /(^|\n)main(\n|$)/.test(asked))

// an unresolvable seat FAILS CLOSED at pre-flight (loud, exit 6) — not a silent abstain.
r = runCli(['convene', 'Ship it?', '--seats=theo,ghostseat', '--mode=deliberate', '--stamped-at=T'], REAL)
ok('CNCL-16 unresolvable seat -> pre-flight fail closed (exit 6)', r.code === 6)
ok('CNCL-16 pre-flight names the offending seat->agent', /ghostseat/.test(r.err || '') && /pre-flight FAILED/.test(r.err || ''))

// registry unreadable (bin errors on `agent list`) also fails CLOSED, never a silent convene.
const badBin = path.join(tmp, 'bad-5dive')
fs.writeFileSync(badBin, '#!/usr/bin/env bash\nexit 1\n'); fs.chmodSync(badBin, 0o755)
r = runCli(['convene', 'Ship it?', '--seats=main', '--mode=deliberate', '--stamped-at=T'], { COUNCIL_5DIVE_BIN: badBin, COUNCIL_MOCK: '' })
ok('CNCL-16 unreadable registry -> fail closed (exit 6)', r.code === 6 && /could not read the agent registry/.test(r.err || ''))

// COUNCIL_MOCK still bypasses the pre-flight (offline tests need no live registry).
r = runCli(['convene', 'Ship it?', '--seats=theo,ghostseat', '--mode=deliberate', '--stamped-at=T'], { COUNCIL_MOCK: '1' })
ok('CNCL-16 pre-flight is skipped under COUNCIL_MOCK (offline)', r.code === 0)
try { fs.rmSync(tmp, { recursive: true, force: true }) } catch {}

console.error(`\nCNCL-6/7/8 CLI contract: ${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
