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
const supported = new Set([
    'all',
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
])

if (!supported.has(requested)) {
    process.stderr.write(`native-toolchain-v1: unknown profile ${requested}\n`)
    process.exit(2)
}

try {
    const schemaErrors = []
    validateAgainstSchema(schema, schema, contract, 'contract.json', schemaErrors)
    if (schemaErrors.length !== 0) throw new Error(schemaErrors.join('; '))
    validateContract(contract)

    const mutations = [
        ['host compiler dependency', (copy) => copy.objective.forbidden_core_build_requirements = ['rustc']],
        ['implicit root authority', (copy) => copy.decisions.environment_authority.hidden_root = true],
        ['ambient process PATH', (copy) => copy.decisions.process_authority.path_search = true],
        ['directory symlink following', (copy) => copy.decisions.directory_authority.symlinks = 'follow'],
        ['Fixed implicit conversion', (copy) => copy.decisions.fixed_decimal.implicit_conversion = true],
        ['native host linker', (copy) => copy.decisions.decimal_backends.host_linker = true],
        ['undersized HTTP headers', (copy) => copy.decisions.http_carrier.limits.header_total_bytes = 65535],
        ['runtime instance search', (copy) => copy.decisions.generics.runtime_instance_search = true],
        ['KIF v2 reinterpretation', (copy) => copy.decisions.kif_generics.preserve_versions = ['kif-v1']],
        ['trusted proof producer', (copy) => copy.decisions.generic_proof_kernel.producer_trusted = true],
    ]

    for (const [name, mutate] of mutations) {
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

    process.stdout.write(`PASS: native toolchain decision contract (${requested})\n`)
    process.stdout.write(`PASS: ${mutations.length} authority, dependency, ABI, and trust mutations fail closed\n`)
} catch (error) {
    process.stderr.write(`native-toolchain-v1: ${error.message}\n`)
    process.exit(1)
}
