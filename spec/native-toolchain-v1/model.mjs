const REQUIRED_ISSUES = Object.freeze([1212, 1231, 1234, 1241, 1249, 1255, 1256, 1265, 1266, 1267])

function fail(message) {
    throw new Error(message)
}

function equal(actual, expected, field) {
    if (actual !== expected) fail(`${field}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
}

function hasAll(actual, expected, field) {
    if (!Array.isArray(actual)) fail(`${field}: expected an array`)
    const missing = expected.filter((entry) => !actual.includes(entry))
    if (missing.length !== 0) fail(`${field}: missing ${missing.join(', ')}`)
    if (new Set(actual).size !== actual.length) fail(`${field}: duplicate entry`)
}

function positiveLimits(limits, field) {
    if (limits === null || typeof limits !== 'object' || Array.isArray(limits)) {
        fail(`${field}: expected an object`)
    }
    for (const [name, value] of Object.entries(limits)) {
        if (!Number.isSafeInteger(value) || value <= 0) fail(`${field}.${name}: expected a positive safe integer`)
    }
}

export function validateContract(contract) {
    equal(contract.schema, 'kofun.native-toolchain-decisions/v1', 'schema')
    equal(contract.profile, 'kofun-only-native/v1', 'profile')

    const objective = contract.objective ?? fail('objective: missing')
    equal(objective.required_language_for_shipped_toolchain, 'Kofun', 'objective.required_language_for_shipped_toolchain')
    equal(objective.completion_unit,
        'A repository is inside kofun-only-native/v1 if and only if one of its artifacts is required to compile, link, package, test, or rebuild the Kofun toolchain at the exact release commit and therefore appears in the fixed-point acquisition set; inputs are inside and consumers are outside.',
        'objective.completion_unit')
    hasAll(objective.replacement_class, ['Rust', 'Zig'], 'objective.replacement_class')
    const requiredTargets = [
        'native-x86_64-linux-elf64',
        'native-aarch64-linux-elf64',
        'native-x86_64-windows-pe32plus',
        'native-aarch64-windows-pe32plus',
        'native-x86_64-macos-macho64',
        'native-aarch64-macos-macho64',
    ]
    hasAll(objective.required_native_targets, requiredTargets, 'objective.required_native_targets')
    equal(objective.required_native_targets.length, requiredTargets.length,
        'objective.required_native_targets length')
    hasAll(objective.required_native_operating_systems,
        ['linux', 'windows', 'macos'],
        'objective.required_native_operating_systems')
    equal(objective.required_native_operating_systems.length, 3,
        'objective.required_native_operating_systems length')
    hasAll(objective.required_native_image_formats,
        ['ELF64', 'PE32+', 'Mach-O-64'],
        'objective.required_native_image_formats')
    equal(objective.required_native_image_formats.length, 3,
        'objective.required_native_image_formats length')
    hasAll(objective.forbidden_core_build_requirements,
        ['cc', 'c++', 'assembler', 'system-linker', 'rustc', 'cargo', 'zig', 'node', 'python',
            'shell-build-driver', 'go-task', 'system-sdk', 'import-library',
            'non-kofun-build-language'],
        'objective.forbidden_core_build_requirements')
    hasAll(objective.allowed_external_boundary,
        ['operating-system-kernel-abi', 'operating-system-loader-and-system-api',
            'firmware-or-wasm-host-abi', 'explicit-versioned-foreign-library-adapter'],
        'objective.allowed_external_boundary')
    equal(objective.allowed_external_boundary.length, 4,
        'objective.allowed_external_boundary length')
    hasAll(objective.completion_evidence,
        ['clean full-language fixed point from a released Kofun compiler',
            'byte-identical repeated native artifacts for all six required native targets',
            'native execution evidence on matching Linux, Windows, and macOS x86-64 and AArch64 hosts',
            'each supported-host Kofun compiler cross-emits all six required native targets',
            'recorded process graph contains no forbidden core build requirement',
            'source-free dependency build from KIF and package artifacts',
            'toolchain commands implemented in Kofun and exercised without forbidden core build requirements',
            'capability manifest and release artifacts read back from the exact release commit'],
        'objective.completion_evidence')
    if (!objective.claim_boundary.includes('does not claim')) fail('objective.claim_boundary: must refuse a current implementation claim')

    const decisions = contract.decisions ?? fail('decisions: missing')
    const issueNumbers = Object.values(decisions).map((decision) => decision.issue).sort((a, b) => a - b)
    equal(JSON.stringify(issueNumbers), JSON.stringify(REQUIRED_ISSUES), 'decisions.issue coverage')

    const trust = decisions.kif_module_trust
    equal(trust.tag, '0x800A', 'kif_module_trust.tag')
    equal(trust.required, true, 'kif_module_trust.required')
    equal(trust.ordinary_bytes, 'ordinary', 'kif_module_trust.ordinary_bytes')
    equal(trust.raw_foreign_bytes, 'raw-foreign', 'kif_module_trust.raw_foreign_bytes')
    equal(trust.missing, 'rebuild-required', 'kif_module_trust.missing')

    const environment = decisions.environment_authority
    equal(environment.hidden_root, false, 'environment_authority.hidden_root')
    equal(environment.pure_boundary, 'pure fn', 'environment_authority.pure_boundary')
    equal(environment.pre_runtime.build, 'refuse-before-authority-carrier-abi', 'environment_authority.pre_runtime.build')
    equal(environment.pre_runtime.run, 'refuse-before-authority-carrier-abi', 'environment_authority.pre_runtime.run')
    equal(environment.diagnostic_precedence.join(','), 'parse-type-ownership,E351-E355,E350,E356', 'environment_authority.diagnostic_precedence')

    const process = decisions.process_authority
    equal(process.shell, false, 'process_authority.shell')
    equal(process.path_search, false, 'process_authority.path_search')
    equal(process.ambient_environment, false, 'process_authority.ambient_environment')
    equal(process.ambient_cwd, false, 'process_authority.ambient_cwd')
    equal(process.toolchain_use, 'not-required-by-core-native-build', 'process_authority.toolchain_use')
    positiveLimits(process.limits, 'process_authority.limits')

    const directory = decisions.directory_authority
    equal(directory.ambient_cwd, false, 'directory_authority.ambient_cwd')
    equal(directory.symlinks, 'refuse-before-follow-by-default', 'directory_authority.symlinks')
    equal(directory.filename, 'Bytes-with-explicit-validated-Text-conversion', 'directory_authority.filename')
    equal(directory.ordering, 'unsigned-byte-lexicographic', 'directory_authority.ordering')
    positiveLimits(directory.limits, 'directory_authority.limits')

    const fixed = decisions.fixed_decimal
    equal(fixed.runtime_scale_identity, false, 'fixed_decimal.runtime_scale_identity')
    equal(fixed.construction_result, 'Result[Fixed[S], DecimalError]', 'fixed_decimal.construction_result')
    equal(fixed.implicit_conversion, false, 'fixed_decimal.implicit_conversion')
    equal(fixed.scale_min, 0, 'fixed_decimal.scale_min')
    equal(fixed.scale_max, 6144, 'fixed_decimal.scale_max')
    equal(fixed.operations.divide, 'deferred-use-Decimal.divide-with-explicit-scale-and-rounding', 'fixed_decimal.operations.divide')
    hasAll(fixed.failures, ['D001', 'D002', 'D003', 'D004'], 'fixed_decimal.failures')

    const decimal = decisions.decimal_backends
    equal(decimal.bare_wasm32, 'permanent-bounded-numeric-profile-no-Decimal-claim', 'decimal_backends.bare_wasm32')
    equal(decimal.wasm_decimal_target, 'wasm32-hostabi1', 'decimal_backends.wasm_decimal_target')
    equal(decimal.native, 'preserve-existing-direct-static-ELF-targets-and-emit-bounded-runtime-as-machine-code', 'decimal_backends.native')
    equal(decimal.host_linker, false, 'decimal_backends.host_linker')
    equal(decimal.shared_runtime_binary, false, 'decimal_backends.shared_runtime_binary')
    equal(decimal.resource_profile.significand_digits, 4096, 'decimal_backends.resource_profile.significand_digits')
    equal(decimal.resource_profile.scale_min, -6144, 'decimal_backends.resource_profile.scale_min')
    equal(decimal.resource_profile.scale_max, 6144, 'decimal_backends.resource_profile.scale_max')
    hasAll(decimal.resource_profile.diagnostics,
        ['D001', 'D002', 'D003', 'D004', 'D005', 'D006', 'D007'],
        'decimal_backends.resource_profile.diagnostics')

    const http = decisions.http_carrier
    equal(http.stream, 'generic-synchronous-finite-Stream[Bytes,HttpError]', 'http_carrier.stream')
    equal(http.live_network_claim, false, 'http_carrier.live_network_claim')
    positiveLimits(http.limits, 'http_carrier.limits')
    if (http.limits.header_total_bytes < 65536) fail('http_carrier.limits.header_total_bytes: must admit the accepted 64-KiB profile')
    if (http.limits.read_all_hard_bytes < http.limits.buffered_body_bytes) {
        fail('http_carrier.limits: read_all_hard_bytes must cover buffered_body_bytes')
    }

    const generics = decisions.generics
    equal(generics.source, 'explicit-rank1-type-application', 'generics.source')
    equal(generics.inference, false, 'generics.inference')
    equal(generics.higher_kinds, false, 'generics.higher_kinds')
    equal(generics.runtime_instance_search, false, 'generics.runtime_instance_search')
    equal(generics.separate_compilation, 'versioned-KIF-typed-template-source-free', 'generics.separate_compilation')
    positiveLimits(generics.limits, 'generics.limits')
    equal(generics.limits.type_parameters, 2, 'generics.limits.type_parameters')
    equal(generics.limits.instantiations_per_declaration, 8, 'generics.limits.instantiations_per_declaration')
    hasAll(generics.optimization_modes, ['dictionary', 'monomorphic', 'hybrid'], 'generics.optimization_modes')

    const kif = decisions.kif_generics
    equal(kif.profile, 'kofun.kif/generics-v3', 'kif_generics.profile')
    hasAll(kif.preserve_versions, ['kif-v1', 'kif-v2'], 'kif_generics.preserve_versions')
    hasAll(kif.records,
        ['TypeBinder', 'ConstructedTypeRef', 'GenericTypeDeclaration', 'GenericFunctionDeclaration',
            'TraitDeclaration', 'TraitMethod', 'Implementation', 'DictionaryAbi', 'GenericBodyTemplate',
            'PublishedInstantiation', 'GenericLawReference'],
        'kif_generics.records')
    equal(kif.coherence, 'complete-dependency-graph-before-selection', 'kif_generics.coherence')
    equal(kif.visibility, 'hidden-facts-never-satisfy-exported-bounds', 'kif_generics.visibility')
    positiveLimits(kif.limits, 'kif_generics.limits')

    const proof = decisions.generic_proof_kernel
    equal(proof.producer_trusted, false, 'generic_proof_kernel.producer_trusted')
    equal(proof.checker_trusted, true, 'generic_proof_kernel.checker_trusted')
    equal(proof.assurance, 'proven', 'generic_proof_kernel.assurance')
    equal(proof.first_theorem_ground_enumeration_sufficient, false, 'generic_proof_kernel.first_theorem_ground_enumeration_sufficient')
    equal(proof.recursion, 'unsupported-in-v1-certificates', 'generic_proof_kernel.recursion')
    hasAll(proof.rules,
        ['hypothesis', 'reflexivity', 'symmetry', 'transitivity', 'congruence',
            'typed-beta', 'typed-let', 'adt-case-reduction', 'named-proven-rewrite'],
        'generic_proof_kernel.rules')
    hasAll(proof.proof_id_inputs,
        ['proposition-digest', 'compiler-digest', 'interface-digest', 'body-digests',
            'implementation-ids', 'certificate-digest', 'kernel-profile'],
        'generic_proof_kernel.proof_id_inputs')
    positiveLimits(proof.limits, 'generic_proof_kernel.limits')

    return contract
}

export function cloneContract(contract) {
    return JSON.parse(JSON.stringify(contract))
}
