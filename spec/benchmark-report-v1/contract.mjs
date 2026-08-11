export const REPORT_SCHEMA = "kofun.bench-report/v1";
export const NEGATIVE_VECTOR_SCHEMA = "kofun.bench-report-negative-vectors/v1";
export const COMPARISON_VECTOR_SCHEMA = "kofun.bench-report-comparison-vectors/v1";

export const LIMITS = Object.freeze({
  wireBytes: 16 * 1024,
  jsonDepth: 16,
  samples: 100,
  segment0Samples: 64,
  segment1Samples: 36,
  identityBytes: 96,
  hostTextBytes: 128,
  noteBytes: 255,
  integer: Number.MAX_SAFE_INTEGER,
  warmupCapNs: 500_000_000,
  samplingCapNs: 3_000_000_000,
  thresholdBps: 1_000_000,
});

export const CLOCKS = Object.freeze(["monotonic", "process-cpu", "wall"]);
export const DIRECTIONS = Object.freeze(["lower-is-better", "higher-is-better"]);
export const WARMUP_STOPS = Object.freeze(["disabled", "steady", "time-cap"]);
export const SAMPLING_STOPS = Object.freeze(["sample-cap", "time-cap"]);
export const COUNTER_NAMES = Object.freeze([
  "allocated_bytes",
  "allocation_count",
  "gc_collections",
  "vm_peak_bytes",
  "cpu_cycles",
]);

export const ERROR_CODES = Object.freeze({
  invalidEncoding: "BR001",
  nonCanonicalBytes: "BR002",
  schemaShape: "BR003",
  limitExceeded: "BR004",
  invalidIdentity: "BR005",
  invalidInvariant: "BR006",
  arithmeticOverflow: "BR007",
  incompatibleComparison: "BR008",
  invalidThreshold: "BR009",
  measurementFailed: "BR010",
  cancelled: "BR011",
  outputFailed: "BR012",
});

export const ERROR_VOCABULARY = Object.freeze(Object.values(ERROR_CODES));

export const ROOT_FIELDS = Object.freeze([
  "schema",
  "identity",
  "clock",
  "budget",
  "measurement",
  "samples",
  "outliers",
  "summary",
  "counters",
  "digests",
  "host",
]);

export const IDENTITY_FIELDS = Object.freeze([
  "suite",
  "case",
  "parameter",
  "metric",
  "unit",
  "direction",
]);

export const BUDGET_FIELDS = Object.freeze([
  "warmup_cap_ns",
  "sampling_cap_ns",
  "sample_cap",
]);

export const MEASUREMENT_FIELDS = Object.freeze([
  "warmup_iterations",
  "warmup_stop",
  "iterations_per_sample",
  "sample_count",
  "sampling_stop",
  "harness_overhead_ns",
]);

export const SUMMARY_FIELDS = Object.freeze([
  "minimum",
  "maximum",
  "median",
  "p25",
  "p75",
  "median_absolute_deviation",
]);

export const DIGEST_FIELDS = Object.freeze([
  "toolchain_sha256",
  "source_sha256",
  "artifact_sha256",
]);

export const HOST_FIELDS = Object.freeze([
  "host_id_sha256",
  "os",
  "arch",
  "cpu",
  "affinity",
  "frequency_hz",
  "noise",
]);

export const STAGE2_STATUS_TAGS = Object.freeze({
  valid: 0,
  BR001: 1,
  BR002: 2,
  BR003: 3,
  BR004: 4,
  BR005: 5,
  BR006: 6,
  BR007: 7,
  BR008: 8,
  BR009: 9,
  BR010: 10,
  BR011: 11,
  BR012: 12,
});

export const STAGE2_VALUE_TAGS = Object.freeze({
  clock: Object.freeze({ monotonic: 0, "process-cpu": 1, wall: 2 }),
  direction: Object.freeze({ "lower-is-better": 0, "higher-is-better": 1 }),
  warmupStop: Object.freeze({ disabled: 0, steady: 1, "time-cap": 2 }),
  samplingStop: Object.freeze({ "sample-cap": 0, "time-cap": 1 }),
});

/*
 * The production Stage 2 slice maps the nested logical schema to one flat
 * nominal outcome record. Schema and unit are fixed by this profile's type
 * identity. A nonzero status tag carries no partial report: every remaining
 * field has the unique neutral value for its admitted physical type.
 */
export const STAGE2_REPORT_FIELDS = Object.freeze([
  Object.freeze({ name: "status_tag", type: "Int" }),
  Object.freeze({ name: "suite", type: "Text" }),
  Object.freeze({ name: "case", type: "Text" }),
  Object.freeze({ name: "parameter_present", type: "Bool" }),
  Object.freeze({ name: "parameter", type: "Text" }),
  Object.freeze({ name: "metric", type: "Text" }),
  Object.freeze({ name: "direction_tag", type: "Int" }),
  Object.freeze({ name: "clock_tag", type: "Int" }),
  Object.freeze({ name: "warmup_cap_ns", type: "Int" }),
  Object.freeze({ name: "sampling_cap_ns", type: "Int" }),
  Object.freeze({ name: "sample_cap", type: "Int" }),
  Object.freeze({ name: "warmup_iterations", type: "Int" }),
  Object.freeze({ name: "warmup_stop_tag", type: "Int" }),
  Object.freeze({ name: "iterations_per_sample", type: "Int" }),
  Object.freeze({ name: "sample_count", type: "Int" }),
  Object.freeze({ name: "sampling_stop_tag", type: "Int" }),
  Object.freeze({ name: "harness_overhead_ns", type: "Int" }),
  Object.freeze({ name: "sample_segment0", type: "List[Int]" }),
  Object.freeze({ name: "sample_segment1", type: "List[Int]" }),
  Object.freeze({ name: "outlier_segment0", type: "List[Int]" }),
  Object.freeze({ name: "outlier_segment1", type: "List[Int]" }),
  ...SUMMARY_FIELDS.map((name) => Object.freeze({ name: `summary_${name}`, type: "Int" })),
  ...COUNTER_NAMES.flatMap((name) => [
    Object.freeze({ name: `${name}_available`, type: "Bool" }),
    Object.freeze({ name: `${name}_value`, type: "Int" }),
  ]),
  ...DIGEST_FIELDS.map((name) => Object.freeze({ name, type: "Text" })),
  Object.freeze({ name: "host_id_sha256", type: "Text" }),
  Object.freeze({ name: "host_os", type: "Text" }),
  Object.freeze({ name: "host_arch", type: "Text" }),
  Object.freeze({ name: "host_cpu", type: "Text" }),
  Object.freeze({ name: "host_affinity_available", type: "Bool" }),
  Object.freeze({ name: "host_affinity", type: "Text" }),
  Object.freeze({ name: "host_frequency_hz_available", type: "Bool" }),
  Object.freeze({ name: "host_frequency_hz", type: "Int" }),
  Object.freeze({ name: "host_noise", type: "Text" }),
]);
