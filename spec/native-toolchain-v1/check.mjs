#!/usr/bin/env node
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { validateAgainstSchema } from '../../tests/lib/json-schema.mjs'
import { cloneContract, validateContract } from './model.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const contract = JSON.parse(readFileSync(join(HERE, 'contract.json'), 'utf8'))
const schema = JSON.parse(readFileSync(join(HERE, 'schema.json'), 'utf8'))
const requested = process.argv[2] ?? 'all'

/*
 * Eleven Taskfile entries pass eleven different profile names to this file.
 * Until #1428 the argument reached a membership test and the PASS label and
 * nothing else: every profile ran all fifteen mutations and printed the same
 * bytes, so `task kif-module-trust-profile` said its own name in a green line
 * while checking something generic.
 *
 * Slicing it is not enough on its own. A tag that is too *wide* — one profile
 * claiming a mutation that belongs to its neighbour — satisfies "every profile
 * owns one" and "every mutation is owned", prints plausible counts, and slices
 * wrongly. So the owner is not taken on trust: each mutation is applied, the
 * changed path is observed, and the declared owner must be the profile that
 * path belongs to. A mis-tagged mutation fails before any refusal is checked.
 */
const PROFILES = [
    'kif-module-trust',
    'environment-authority',
    'process-authority',
    'directory-authority',
    'fixed-decimal',
    'decimal-backends',
    'http-carrier',
    'generics',
    'kif-generics',
    'generic-proof-kernel',
]
const supported = new Set(['all', ...PROFILES])

if (!supported.has(requested)) {
    process.stderr.write(`native-toolchain-v1: unknown profile ${requested}\n`)
    process.exit(2)
}

/*
 * `objective` is the contract's shared half — targets, image formats, forbidden
 * build requirements, completion evidence. Its mutations belong to every
 * profile rather than to none: a profile that let a host-compiler dependency in
 * would be wrong regardless of which decision it owns.
 */
const SHARED = 'objective'

const mutations = [
    ['host compiler dependency', SHARED,
        (copy) => copy.objective.forbidden_core_build_requirements = ['rustc']],
    ['repository-name completion unit', SHARED,
        (copy) => copy.objective.completion_unit = 'named repository allowlist'],
    ['Linux-only native targets', SHARED, (copy) => {
        copy.objective.required_native_targets = copy.objective.required_native_targets.slice(0, 2)
    }],
    ['missing Windows operating system', SHARED, (copy) => {
        copy.objective.required_native_operating_systems = ['linux', 'macos']
    }],
    ['missing PE image writer', SHARED, (copy) => {
        copy.objective.required_native_image_formats = ['ELF64', 'Mach-O-64']
    }],
    ['system SDK dependency', SHARED, (copy) => {
        copy.objective.forbidden_core_build_requirements =
            copy.objective.forbidden_core_build_requirements
                .filter((entry) => entry !== 'system-sdk')
    }],
    ['missing native execution evidence', SHARED, (copy) => {
        copy.objective.completion_evidence = copy.objective.completion_evidence
            .filter((entry) => !entry.startsWith('native execution evidence'))
    }],
    /*
     * #1428. `kif-module-trust` owned no mutation at all before this row, which
     * is why the profile #1421 and #1422 name as the RFC-0012 regression
     * surface could run, print its own name, and check nothing of its own.
     * `model.mjs` enforced six properties of this decision and nothing broke
     * any of them.
     */
    ['raw-foreign spelled as ordinary', 'kif-module-trust',
        (copy) => copy.decisions.kif_module_trust.raw_foreign_bytes = 'ordinary'],
    ['implicit root authority', 'environment-authority',
        (copy) => copy.decisions.environment_authority.hidden_root = true],
    ['ambient process PATH', 'process-authority',
        (copy) => copy.decisions.process_authority.path_search = true],
    ['directory symlink following', 'directory-authority',
        (copy) => copy.decisions.directory_authority.symlinks = 'follow'],
    ['Fixed implicit conversion', 'fixed-decimal',
        (copy) => copy.decisions.fixed_decimal.implicit_conversion = true],
    ['native host linker', 'decimal-backends',
        (copy) => copy.decisions.decimal_backends.host_linker = true],
    ['undersized HTTP headers', 'http-carrier',
        (copy) => copy.decisions.http_carrier.limits.header_total_bytes = 65535],
    ['runtime instance search', 'generics',
        (copy) => copy.decisions.generics.runtime_instance_search = true],
    ['KIF v2 reinterpretation', 'kif-generics',
        (copy) => copy.decisions.kif_generics.preserve_versions = ['kif-v1']],
    ['trusted proof producer', 'generic-proof-kernel',
        (copy) => copy.decisions.generic_proof_kernel.producer_trusted = true],
]

/* The top-level contract keys a mutation changed, as a set of paths. */
function changedPaths(before, after, prefix = '') {
    const paths = []
    const keys = new Set([...Object.keys(before ?? {}), ...Object.keys(after ?? {})])
    for (const key of keys) {
        const path = prefix === '' ? key : `${prefix}.${key}`
        const left = before?.[key]
        const right = after?.[key]
        if (JSON.stringify(left) === JSON.stringify(right)) continue
        if (
            left !== null && right !== null &&
            typeof left === 'object' && typeof right === 'object' &&
            !Array.isArray(left) && !Array.isArray(right)
        ) {
            paths.push(...changedPaths(left, right, path))
            continue
        }
        paths.push(path)
    }
    return paths
}

/* `decisions.kif_module_trust.raw_foreign_bytes` → `kif-module-trust`. */
function ownerOfPath(path) {
    const [head, key] = path.split('.')
    if (head === SHARED) return SHARED
    if (head !== 'decisions' || key === undefined) return null
    return key.replaceAll('_', '-')
}

try {
    const schemaErrors = []
    validateAgainstSchema(schema, schema, contract, 'contract.json', schemaErrors)
    if (schemaErrors.length !== 0) throw new Error(schemaErrors.join('; '))
    validateContract(contract)

    // Every mutation's declared owner must be the profile whose subtree it
    // actually changes. This is what makes the tags measured rather than
    // asserted: moving one to a neighbour fails here.
    for (const [name, owner, mutate] of mutations) {
        const copy = cloneContract(contract)
        mutate(copy)
        const paths = changedPaths(contract, copy)
        if (paths.length === 0) throw new Error(`mutation changes nothing: ${name}`)
        const owners = new Set(paths.map(ownerOfPath))
        if (owners.size !== 1 || !owners.has(owner)) {
            throw new Error(
                `mutation \`${name}\` is declared as \`${owner}\` but changes ` +
                    `${paths.join(', ')}, owned by ${[...owners].join(', ')}`,
            )
        }
    }

    // Both directions over the vocabulary: no profile without a mutation, and
    // no mutation without a profile. The first is what caught
    // `kif-module-trust` owning nothing.
    const owned = new Set(mutations.map(([, owner]) => owner))
    const unowned = PROFILES.filter((profile) => !owned.has(profile))
    if (unowned.length !== 0) {
        throw new Error(
            `profiles with no mutation of their own: ${unowned.join(', ')}; ` +
                'a profile that runs no mutation of its own prints its name and checks nothing',
        )
    }
    for (const owner of owned) {
        if (owner !== SHARED && !PROFILES.includes(owner)) {
            throw new Error(`mutation owner \`${owner}\` is not a supported profile`)
        }
    }

    // The slice. `all` runs everything; a named profile runs the shared
    // mutations and its own.
    const selected = mutations.filter(([, owner]) =>
        requested === 'all' || owner === SHARED || owner === requested,
    )
    if (selected.length === 0) throw new Error(`profile ${requested} selects no mutation`)

    for (const [name, , mutate] of selected) {
        const copy = cloneContract(contract)
        mutate(copy)
        let rejected = false
        try {
            validateContract(copy)
        } catch {
            rejected = true
        }
        if (!rejected) throw new Error(`mutation accepted: ${name}`)
    }

    /*
     * The slice must actually narrow. Reverting the filter to `true` restores
     * exactly the original defect — every profile running everything — and
     * every assertion above still passes, because tagging is correct and the
     * counts are computed from `selected`. So the narrowing is asserted here
     * against the vocabulary rather than left implicit in the filter.
     *
     * Found by mutating the filter, not by reading it: the first version of
     * this file had all four other mutations caught and this one green.
     */
    if (requested !== 'all') {
        const foreign = selected.filter(
            ([, owner]) => owner !== SHARED && owner !== requested,
        )
        if (foreign.length !== 0) {
            throw new Error(
                `profile ${requested} selected ${foreign.length} mutation(s) belonging to ` +
                    `${[...new Set(foreign.map(([, owner]) => owner))].join(', ')}; ` +
                    'a profile that runs its neighbours\' mutations is the alias defect again',
            )
        }
        if (selected.length === mutations.length && mutations.length > 1) {
            throw new Error(
                `profile ${requested} selected every mutation, so naming it changed nothing`,
            )
        }
    }

    const own = selected.filter(([, owner]) => owner !== SHARED)
    process.stdout.write(`PASS: native toolchain decision contract (${requested})\n`)
    /*
     * The output names what ran, not just how many. Counting alone would not
     * have been enough: every profile owns exactly one mutation today, so the
     * counts are identical across all ten and the only difference would be the
     * profile's own name — which is precisely the signature the aliasing had.
     * Anyone re-running the check that found this defect (hash two profiles'
     * output with the label normalised away) must get different bytes, and
     * with the mutation names present they do.
     */
    process.stdout.write(
        `PASS: ${requested} ran ${selected.length} of ${mutations.length} mutations ` +
            `(${own.length} its own, ${selected.length - own.length} shared) and each failed closed\n`,
    )
    process.stdout.write(
        `PASS: ${requested} owns: ${own.map(([name]) => name).join('; ') || '(shared only)'}\n`,
    )
} catch (error) {
    process.stderr.write(`native-toolchain-v1: ${error.message}\n`)
    process.exit(1)
}
