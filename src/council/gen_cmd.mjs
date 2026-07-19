#!/usr/bin/env node
// CNCL-6 — generate src/cmd_council.sh by embedding the canonical engine.mjs + cli.mjs
// into cmd_council.template.sh (this bundle ships as one bash file, so node modules
// are embedded as heredocs). Run after editing engine.mjs / cli.mjs / the template:
//     node src/council/gen_cmd.mjs
// Drift between the embedded copy and the sources is caught by
// tests/council_cli_contract.mjs.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const read = (p) => fs.readFileSync(path.join(here, p), 'utf-8')
const engine = read('engine.mjs')
const cli = read('cli.mjs')
const tmpl = read('cmd_council.template.sh')

for (const [tok, body, delim] of [['__ENGINE_MJS__', engine, 'COUNCIL_ENGINE_MJS'], ['__CLI_MJS__', cli, 'COUNCIL_CLI_MJS']]) {
  if (body.split('\n').some(l => l === delim)) { console.error(`refuse: ${delim} appears on its own line inside the embedded module`); process.exit(1) }
  // The marker sits on its own line; drop the trailing newline of the file so the
  // heredoc closes cleanly on the next line.
  const line = new RegExp(`^${tok}$`, 'm')
  if (!line.test(tmpl)) { console.error(`marker ${tok} not found in template`); process.exit(1) }
  var out = (out ?? tmpl).replace(line, () => body.replace(/\n$/, ''))
}

const dest = path.join(here, '..', 'cmd_council.sh')
fs.writeFileSync(dest, out)
console.error(`wrote ${dest} (${out.length} bytes; engine ${engine.length} + cli ${cli.length} embedded)`)
