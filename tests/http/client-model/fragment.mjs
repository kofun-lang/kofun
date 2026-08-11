// Fragmentation and seeded splitting, over one committed script.
//
//     node tests/http/client-model/fragment.mjs SCRIPT.json every
//     node tests/http/client-model/fragment.mjs SCRIPT.json seed SEED COUNT
//
// `every` splits the delivered bytes at every boundary, one cut at a time.
// `seed` splits them at pseudorandom boundaries drawn from an explicit seed,
// which it prints, so a failing plan is replayable by rerunning with the same
// number and nothing else.
//
// Both compare against the whole-message run of the same script. Everything in
// the result must match except `counters.operations`, which counts scripted
// operations and is therefore a property of the delivery plan rather than of
// the message — the one field a fragmentation test must not pin, and the one it
// would be easiest to pin by accident.

import { readFileSync } from 'node:fs'
import { readScript } from './schema.mjs'
import { runScript } from './model.mjs'

const comparable = (result) => {
    const { counters, ...rest } = result
    const { operations, ...countersRest } = counters
    return JSON.stringify({ ...rest, counters: countersRest })
}

/*
 * One explicit generator, so a seed names a plan. Node's own randomness is not
 * usable here: this corpus has to replay on another machine from the number in
 * the failure message.
 */
const splitmix32 = (seed) => {
    let state = seed >>> 0
    return () => {
        state = (state + 0x9e3779b9) >>> 0
        let value = state
        value = Math.imul(value ^ (value >>> 16), 0x21f0aaad) >>> 0
        value = Math.imul(value ^ (value >>> 15), 0x735a2d97) >>> 0
        return ((value ^ (value >>> 15)) >>> 0) / 0x100000000
    }
}

const withPlan = (script, cuts) => {
    const delivered = []
    const tail = []
    for (const operation of script.operations) {
        if (operation.op === 'deliver') delivered.push(...operation.bytes)
        else tail.push(operation)
    }
    const operations = []
    let previous = 0
    for (const cut of [...cuts, delivered.length]) {
        if (cut === previous && operations.length > 0) continue
        operations.push({ op: 'deliver', bytes: delivered.slice(previous, cut) })
        previous = cut
    }
    if (operations.length === 0) operations.push({ op: 'deliver', bytes: [] })
    return { ...script, operations: [...operations, ...tail] }
}

const deliveredLength = (script) =>
    script.operations
        .filter((operation) => operation.op === 'deliver')
        .reduce((total, operation) => total + operation.bytes.length, 0)

const main = (argv) => {
    if (argv.length < 2) {
        process.stderr.write(
            'usage: node fragment.mjs SCRIPT.json (every | seed SEED COUNT)\n',
        )
        return 2
    }
    const script = readScript(JSON.parse(readFileSync(argv[0], 'utf8')))
    const whole = comparable(runScript(script))
    const length = deliveredLength(script)

    const check = (plan, label) => {
        const split = comparable(runScript(withPlan(script, plan)))
        if (split === whole) return true
        process.stderr.write(
            `FAIL: http fragmentation: ${script.name}: ${label} disagrees with the whole message\n`,
        )
        process.stderr.write(`  whole: ${whole}\n`)
        process.stderr.write(`  split: ${split}\n`)
        return false
    }

    if (argv[1] === 'every') {
        for (let cut = 0; cut <= length; cut += 1) {
            if (!check([cut], `cut at ${cut}`)) return 1
        }
        process.stdout.write(
            `PASS: ${script.name}: ${length + 1} single cuts agree with the whole message\n`,
        )
        return 0
    }
    if (argv[1] !== 'seed' || argv.length !== 4) {
        process.stderr.write('usage: node fragment.mjs SCRIPT.json seed SEED COUNT\n')
        return 2
    }
    const seed = Number(argv[2])
    const count = Number(argv[3])
    if (!Number.isSafeInteger(seed) || !Number.isSafeInteger(count) || count < 1) {
        process.stderr.write('seed and count must be integers, count at least 1\n')
        return 2
    }
    const next = splitmix32(seed)
    for (let attempt = 0; attempt < count; attempt += 1) {
        const cuts = []
        const pieces = 1 + Math.floor(next() * 6)
        for (let index = 0; index < pieces; index += 1) {
            cuts.push(Math.floor(next() * (length + 1)))
        }
        cuts.sort((left, right) => left - right)
        if (!check(cuts, `seed ${seed} attempt ${attempt} cuts ${cuts.join(',')}`)) {
            return 1
        }
    }
    process.stdout.write(
        `PASS: ${script.name}: ${count} seeded plans from seed ${seed} agree with the whole message\n`,
    )
    return 0
}

process.exit(main(process.argv.slice(2)))
