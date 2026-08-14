#!/usr/bin/env node

// Run a command module on Node's Preview 1 host.
//
// Structural validity and running are different claims: a module can decode
// correctly and trap on entry. This reports the host's own view of the module's
// imports as well, because the host is the party that would have to satisfy
// them.

import { readFileSync } from 'node:fs'
import { WASI } from 'node:wasi'

const bytes = readFileSync(process.argv[2])
const module = await WebAssembly.compile(bytes)
process.stdout.write(`imports ${WebAssembly.Module.imports(module).length}\n`)

const wasi = new WASI({ version: 'preview1', args: ['command'], env: {} })
const instance = await WebAssembly.instantiate(module, wasi.getImportObject())
const code = wasi.start(instance)
process.stdout.write(`exit ${code === undefined ? 0 : code}\n`)
