#!/usr/bin/env node
// DIVE-4869 — generate src/constitution_kernel.sh by embedding the canonical
// src/constitution/{constitution,seal,cli}.mjs into kernel.template.sh (the bundle ships as one bash
// file, so node modules ride as heredocs — the gen_cmd.mjs pattern). Run after editing any of them:
//     node src/constitution/gen_kernel.mjs
// Drift between the embedded copy and the sources is caught by tests/constitution_kernel_unit.sh.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const read = (p) => fs.readFileSync(path.join(here, p), 'utf-8')
let out = read('kernel.template.sh')
for (const [tok, body, delim] of [['__CONSTITUTION_MJS__', read('constitution.mjs'), 'CONSTITUTION_KERNEL_MJS'], ['__CONSTITUTION_SEAL_MJS__', read('seal.mjs'), 'CONSTITUTION_KERNEL_SEAL_MJS'], ['__CONSTITUTION_CLI_MJS__', read('cli.mjs'), 'CONSTITUTION_KERNEL_CLI_MJS']]) {
  if (body.split('\n').some(l => l === delim)) { console.error(`refuse: ${delim} appears on its own line inside the embedded module`); process.exit(1) }
  const line = new RegExp(`^${tok}$`, 'm')
  if (!line.test(out)) { console.error(`marker ${tok} not found in template`); process.exit(1) }
  out = out.replace(line, () => body.replace(/\n$/, ''))
}
const dest = path.join(here, '..', 'constitution_kernel.sh')
fs.writeFileSync(dest, out)
console.error(`wrote ${dest} (${out.length} bytes)`)
