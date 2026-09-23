#!/usr/bin/env node
// The constitution kernel's CLI (DIVE-4869) — the READ side core needs with no council engine
// present: `constitution --path=<file>` prints loadConstitution's normalized JSON (hardGateRegex,
// authority, digests, valid/error). Same output as `council/cli.mjs constitution`, same parser.
import { loadConstitution } from './constitution.mjs'

const [sub = '', ...rest] = process.argv.slice(2)
const flag = (k) => {
  const hit = rest.find(a => a === `--${k}` || a.startsWith(`--${k}=`))
  if (hit == null) return ''
  return hit.includes('=') ? hit.slice(hit.indexOf('=') + 1) : ''
}
if (sub === 'constitution') {
  process.stdout.write(JSON.stringify(loadConstitution(flag('path'))) + '\n')
} else {
  process.stderr.write(`constitution kernel: unknown subcommand: ${sub}\n`)
  process.exit(2)
}
