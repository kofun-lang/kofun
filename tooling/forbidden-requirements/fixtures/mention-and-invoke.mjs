/*
 * A fixture, not a gate. See `mention-and-invoke.sh` for what this directory is.
 *
 * A block comment naming node and running nothing:
 *   execFileSync("node", ["--version"])
 */

// A line comment doing the same: node tooling/task-help.mjs

import { execFileSync } from 'node:child_process'

/*
 * The near miss that put three `go-task` rows in the first census: in shell a
 * backtick opens a command substitution, and in JavaScript it opens a template
 * literal. `task limit exceeded` is an error message.
 */
const message = `task limit exceeded (${2} > ${1})`

/* The one invocation in this file. */
execFileSync('node', ['--version'], { stdio: 'ignore' })

export default message
