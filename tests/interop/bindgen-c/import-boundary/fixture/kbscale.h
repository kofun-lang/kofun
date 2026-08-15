/*
 * kbscale — pinned C fixture for the bindgen-c import-boundary gate (#1217).
 *
 * Deliberately smaller than `../fixture/kbfix.h`, and the difference is the
 * point rather than an economy. That header exercises the whole stage-1
 * contract — opaque handles, a by-value `repr(C)` record, callbacks — and the
 * module-resolving build path lowers none of those: it refuses `repr(C)
 * struct` with `E2S50`. The single-file `--c-abi` path in `../check.sh` is
 * where that coverage lives.
 *
 * What this gate proves is the module boundary, so its header is exactly what
 * the boundary needs: scalar `extern "C"` functions whose signatures the
 * module path lowers, and nothing else. A header that also had a record would
 * make the fixture fail for a reason that has nothing to do with trust.
 */
#ifndef KBSCALE_H
#define KBSCALE_H

/* Doubles its argument. The facade wraps this one. */
long kbscale_double(long value);

/* Adds two values, so the facade has something with an arity above one. */
long kbscale_add(long left, long right);

#endif /* KBSCALE_H */
