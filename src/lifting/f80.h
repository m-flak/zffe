// zffe f80 soft-float runtime (non-x86 hosts only; x86 hosts use native x87).
//
// x86_fp80 arithmetic has no AArch64 lowering, so on non-x86 hosts the JIT
// rewrites f80 arithmetic/conversions/comparisons (see rewriteF80 in
// jit.cpp) into calls here. Values cross the boundary as 10-byte
// little-endian extended buffers (explicit integer bit, bias 16383);
// computation happens in host double precision.
//
// Fidelity: conversions are exact or correctly rounded; arithmetic rounds
// in double precision rather than 80-bit. The differences from real x87
// are confined to the last few ulps (plus double-range saturation beyond
// 1e308). FP exception flags never latch (consistent with the runtime's
// fpu_exception_test). Game-appropriate; not bit-exact.

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Conversions.
double zffe_f80_to_f64(const uint8_t a[10]);
void zffe_f64_to_f80(double d, uint8_t out[10]);
float zffe_f80_to_f32(const uint8_t a[10]);
void zffe_f32_to_f80(float f, uint8_t out[10]);
int16_t zffe_f80_to_i16(const uint8_t a[10]);  // trunc; indefinite on invalid
int32_t zffe_f80_to_i32(const uint8_t a[10]);  // trunc; indefinite on invalid
int64_t zffe_f80_to_i64(const uint8_t a[10]);  // trunc; indefinite on invalid
uint64_t zffe_f80_to_u64(const uint8_t a[10]);  // trunc; max on invalid
void zffe_i16_to_f80(int16_t v, uint8_t out[10]);  // exact
void zffe_i32_to_f80(int32_t v, uint8_t out[10]);  // exact
void zffe_i64_to_f80(int64_t v, uint8_t out[10]);  // exact
void zffe_u32_to_f80(uint32_t v, uint8_t out[10]);  // exact

// Arithmetic in double precision.
double zffe_f80_add(const uint8_t a[10], const uint8_t b[10]);
double zffe_f80_sub(const uint8_t a[10], const uint8_t b[10]);
double zffe_f80_mul(const uint8_t a[10], const uint8_t b[10]);
double zffe_f80_div(const uint8_t a[10], const uint8_t b[10]);

// LLVM FCmpPredicate (0-15) over decoded doubles. NaN-aware.
int zffe_f80_cmp(int pred, const uint8_t a[10], const uint8_t b[10]);

// llvm.is.fpclass mask test (mask bit i = class i, LLVM FPClassTest).
int zffe_f80_classify(int mask, const uint8_t a[10]);

// Rounding to integral value (result as double, caller re-encodes).
double zffe_f80_nearbyint(const uint8_t a[10]);  // guest rounding mode
double zffe_f80_trunc(const uint8_t a[10]);  // toward zero

#ifdef __cplusplus
}
#endif
