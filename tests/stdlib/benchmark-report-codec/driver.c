/* Test seam around freshly emitted Kofun, never a replacement codec. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>

static long allocation_count;
static long fail_allocation = -1;
static void *codec_test_allocate(size_t size) {
    ++allocation_count;
    if (allocation_count == fail_allocation) return NULL;
    return malloc(size);
}

#define malloc codec_test_allocate
#define main codec_source_main
#include "codec.c"
#undef main
#undef malloc

/* Generated from the independent contract's complete 49-field vocabulary. */
#include "fields.h"

static int require(int condition, const char *message) {
    if (!condition) fprintf(stderr, "FAIL: benchmark codec: %s\n", message);
    return condition;
}

static int unchanged(const KofunBytesValue *value, KofunBytesValue before,
                     const unsigned char *bytes) {
    if (!require(value->data == before.data, "destination pointer changed on refusal")) return 0;
    if (!require(value->capacity == before.capacity, "destination capacity changed on refusal")) return 0;
    if (!require(value->length == before.length, "destination length changed on refusal")) return 0;
    return require(before.length == 0 || memcmp(value->data, bytes, (size_t)before.length) == 0,
                   "destination bytes changed on refusal");
}

int main(int argc, char **argv) {
    if (!require(argc >= 3, "expected operation and fixture")) return 1;
    KofunBytesValue input = stage2_bytes_empty();
    if (!require(stage2_bytes_read_file(&input, argv[2]).tag == 0, "cannot read fixture")) return 1;
    unsigned char saved_input[65536];
    if (input.length != 0) memcpy(saved_input, input.data, (size_t)input.length);
    KofunBytesValue input_before = input;
    if (strcmp(argv[1], "decode-oom") == 0) {
        fail_allocation = strtol(argv[3], NULL, 10);
        allocation_count = 0;
    }
    KofunRecord_BenchReport report = kofun_fn_decode_report(&input);
    long decode_allocations = allocation_count;
    fail_allocation = -1;
    if (!require(!kofun_failed, "production codec raised a runtime diagnostic")) return 1;
    if (!unchanged(&input, input_before, saved_input)) return 1;
    if (strcmp(argv[1], "decode") == 0 || strcmp(argv[1], "decode-oom") == 0) {
        print_fields(report);
        if (strcmp(argv[1], "decode-oom") == 0) printf("allocations %ld\n", decode_allocations);
        kofun_bytes_release(&input);
        return 0;
    }
    if (!require(report.f_status_tag == 0, "encoder fixture must decode successfully")) return 1;
    KofunBytesValue output = stage2_bytes_empty();
    int64_t seed_length = 3;
    if (argc > 4) seed_length = strtoll(argv[4], NULL, 10);
    if (!require(stage2_bytes_assign_zeroed(&output, seed_length).tag == 0, "cannot seed destination")) return 1;
    for (uint64_t i = 0; i < output.length; ++i) output.data[i] = (unsigned char)(i % 251 + 1);
    unsigned char saved[65536];
    if (output.length != 0) memcpy(saved, output.data, (size_t)output.length);
    KofunBytesValue before = output;
    if (strcmp(argv[1], "repeat") == 0) {
        for (int iteration = 0; iteration < 128; ++iteration) {
            report = kofun_fn_decode_report(&input);
            if (!require(report.f_status_tag == 0 && !kofun_failed, "repeated decoding refused")) return 1;
            int64_t status = kofun_fn_encode_report(report, &output);
            if (!require(status == 0 && !kofun_failed, "repeated encoding refused")) return 1;
            if (!require(output.length == input.length && memcmp(output.data, input.data, (size_t)input.length) == 0,
                         "repeated encoding changed bytes")) return 1;
        }
        print_fields(report);
        if (!unchanged(&input, input_before, saved_input)) return 1;
        kofun_bytes_release(&output);
        kofun_bytes_release(&input);
        return 0;
    }
    if (strcmp(argv[1], "outcome") == 0) {
        report = kofun_fn_neutral_report(strtoll(argv[3], NULL, 10));
    }
    if (strcmp(argv[1], "invalid") == 0) {
        int mutation = (int)strtol(argv[3], NULL, 10);
        if (mutation == 0) report.f_suite = "";
        if (mutation == 1) report.f_metric = "\n";
        if (mutation == 2) report.f_host_noise = "\177";
        if (mutation == 3) report.f_direction_tag = 99;
        if (mutation == 4) report.f_summary_median += 1;
        if (mutation == 5) report.f_outlier_segment0.elements[0] = 2;
        if (mutation == 6) { report.f_allocated_bytes_available = false; report.f_allocated_bytes_value = 1; }
        if (mutation == 7) report.f_sample_segment0.elements[0] = -1;
        if (mutation == 8) report.f_harness_overhead_ns = INT64_MAX;
    }
    if (strcmp(argv[1], "physical") == 0) {
        if (!require(apply_physical_case(&report, strtol(argv[3], NULL, 10)), "unknown physical case")) return 1;
    }
    if (strcmp(argv[1], "encode-oom") == 0) fail_allocation = strtol(argv[3], NULL, 10);
    allocation_count = 0;
    int64_t status = kofun_fn_encode_report(report, &output);
    fail_allocation = -1;
    if (!require(!kofun_failed, "encoder raised a runtime diagnostic")) return 1;
    if (!unchanged(&input, input_before, saved_input)) return 1;
    if (status != 0) {
        if (!unchanged(&output, before, saved)) return 1;
    } else if (strcmp(argv[1], "physical") != 0) {
        if (!require(output.length == input.length && memcmp(output.data, input.data, (size_t)input.length) == 0,
                     "encoded bytes differ from canonical input")) return 1;
    }
    printf("status %" PRId64 "\nallocations %ld\n", status, allocation_count);
    if (status == 0 && (strcmp(argv[1], "roundtrip") == 0 || strcmp(argv[1], "physical") == 0)) {
        if (!require(fwrite(output.data, 1, (size_t)output.length, stdout) == output.length, "cannot print output")) return 1;
    }
    kofun_bytes_release(&output);
    kofun_bytes_release(&input);
    return 0;
}
