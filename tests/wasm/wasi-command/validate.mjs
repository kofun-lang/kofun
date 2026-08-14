#!/usr/bin/env node

// Run an emitted module through #1098's **normative** validator.
//
// This is the assertion that matters most, and it is the one I nearly shipped
// without: the first version of the emitter produced `memory` and `_start` and
// looked correct against the profile document, and `validateModule` refused it
// with `missing-export: memory, kofun_wasi_command_version, and _start are
// required`. The contract is executable, so running it is cheaper and stricter
// than reading it — and a hand-written checklist of what the profile requires
// is exactly the artifact that drifts from the profile.

import { readFileSync } from 'node:fs'

import { makeManifest, validateModule } from '../../../spec/wasi-command-profile-v1/model.mjs'

const bytes = readFileSync(process.argv[2])
const result = validateModule(bytes, makeManifest([]))
process.stdout.write(`exports ${result.exports.join(',')}\n`)
