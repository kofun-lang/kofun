#!/usr/bin/env node

import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { taskfileCommands } from './taskfile.mjs'

const root = mkdtempSync(join(tmpdir(), 'kofun-taskfile-check.'))
try {
    writeFileSync(join(root, 'Taskfile.yml'), `version: '3'

tasks:
  before:
    cmds:
      - "sh before.sh"
  carrier:
    cmds:
      - "sh carrier.sh"
  mutation:
    cmds:
      - "sh mutation.sh"
  aggregate:
    deps: [before]
    cmds:
      - "command -v cc >/dev/null 2>&1"
      - task: carrier
      - task: mutation
      - cmd: "sh after.sh"
`)

    const commands = taskfileCommands(root)
    assert.deepEqual(commands.get('aggregate'), {
        cmds: ['command -v cc >/dev/null 2>&1', 'sh after.sh'],
        deps: ['before'],
        calls: ['carrier', 'mutation'],
    })
    process.stdout.write('PASS: Taskfile command reachability follows dependencies and serialized task calls\n')
} finally {
    rmSync(root, { recursive: true, force: true })
}
