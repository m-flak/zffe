// zffe f80 soft-float runtime. See f80.h.

#include "f80.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern "C" {

// Guest rounding mode (x87 RC field), owned by runtime.cpp.
extern int32_t __remill_fpu_get_rounding(void);

namespace {

struct Parts {
  bool sign;
  uint16_t exp;
  uint64_t mant;
};

Parts split(const uint8_t a[10]) {
  uint64_t mant;
  uint16_t es;
  memcpy(&mant, a, 8);
  memcpy(&es, a + 8, 2);
  Parts p;
  p.sign = (es >> 15) != 0;
  p.exp = (uint16_t)(es & 0x7FFF);
  p.mant = mant;
  return p;
}

void join(uint8_t out[10], bool sign, uint16_t exp, uint64_t mant) {
  uint16_t es = (uint16_t)((sign ? 0x8000u : 0u) | (exp & 0x7FFFu));
  memcpy(out, &mant, 8);
  memcpy(out + 8, &es, 2);
}

bool isInfExp(const Parts &p) { return p.exp == 0x7FFF; }

// True infinity: int bit set, fraction clear. Anything else with maximal
// exponent is NaN (quiet/signaling/unnormal — all decode as quiet NaN).
bool isInf(const Parts &p) {
  return isInfExp(p) && p.mant == 0x8000000000000000ULL;
}

bool isNaNParts(const Parts &p) { return isInfExp(p) && !isInf(p); }

}  // namespace

double zffe_f80_to_f64(const uint8_t a[10]) {
  Parts p = split(a);
  double mag;
  if (isInf(p)) {
    mag = INFINITY;
  } else if (isNaNParts(p)) {
    mag = NAN;
  } else if (p.exp == 0) {
    if (p.mant == 0) {
      mag = 0.0;
    } else {
      // Denormal (or unnormal-with-zero-exp): mant * 2^-16445.
      mag = ldexp((double)p.mant, -16445);
    }
  } else {
    // Normal (unnormals share the formula): mant * 2^(exp-16383-63).
    // Correctly rounded: the double cast rounds once, ldexp scales exactly
    // (barring double over/underflow, which saturate correctly).
    mag = ldexp((double)p.mant, (int)p.exp - 16383 - 63);
  }
  return p.sign ? -mag : mag;
}

void zffe_f64_to_f80(double d, uint8_t out[10]) {
  bool sign = signbit(d) != 0;
  if (d == 0.0) {
    join(out, sign, 0, 0);
    return;
  }
  if (isnan(d)) {
    join(out, sign, 0x7FFF, 0xC000000000000000ULL);
    return;
  }
  if (isinf(d)) {
    join(out, sign, 0x7FFF, 0x8000000000000000ULL);
    return;
  }
  int e2 = 0;
  double frac = frexp(fabs(d), &e2);  // [0.5, 1); exact for all doubles
  // frac * 2^64 is exact (scaling preserves the <=53 significant bits) and
  // fits (frac < 1).
  uint64_t mant = (uint64_t)(frac * 18446744073709551616.0);
  int exp = e2 + 16382;
  // Defensive normalization (frexp guarantees the int bit already, but a
  // hostile libm rounding could clear it; bounded, value-preserving).
  for (int i = 0; i < 64 && (mant & 0x8000000000000000ULL) == 0; i++) {
    mant <<= 1;
    exp -= 1;
  }
  join(out, sign, (uint16_t)exp, mant);
}

float zffe_f80_to_f32(const uint8_t a[10]) {
  // Single rounding directly to float (not via double).
  Parts p = split(a);
  float mag;
  if (isInf(p)) {
    mag = INFINITY;
  } else if (isNaNParts(p)) {
    mag = NAN;
  } else if (p.exp == 0) {
    mag = (p.mant == 0) ? 0.0f : ldexpf((float)p.mant, -16445);
  } else {
    mag = ldexpf((float)p.mant, (int)p.exp - 16383 - 63);
  }
  return p.sign ? -mag : mag;
}

void zffe_f32_to_f80(float f, uint8_t out[10]) {
  // Exact: every f32 value is exactly encodable in f80.
  zffe_f64_to_f80((double)f, out);
}

int16_t zffe_f80_to_i16(const uint8_t a[10]) {
  double d = zffe_f80_to_f64(a);
  if (!(d >= -32768.0) || !(d < 32768.0)) return INT16_MIN;  // incl. NaN
  return (int16_t)d;  // LLVM fptosi truncates toward zero
}

int32_t zffe_f80_to_i32(const uint8_t a[10]) {
  double d = zffe_f80_to_f64(a);
  if (!(d >= -2147483648.0) || !(d < 2147483648.0))
    return INT32_MIN;  // incl. NaN
  return (int32_t)d;
}

int64_t zffe_f80_to_i64(const uint8_t a[10]) {
  double d = zffe_f80_to_f64(a);
  if (!(d >= -9223372036854775808.0) || !(d < 9223372036854775808.0))
    return INT64_MIN;  // incl. NaN
  return (int64_t)d;
}

uint64_t zffe_f80_to_u64(const uint8_t a[10]) {
  double d = zffe_f80_to_f64(a);
  if (!(d >= 0.0) || !(d < 18446744073709551616.0))
    return UINT64_MAX;  // incl. NaN
  return (uint64_t)d;
}

void zffe_i64_to_f80(int64_t v, uint8_t out[10]) {
  if (v == 0) {
    join(out, false, 0, 0);
    return;
  }
  bool sign = v < 0;
  uint64_t m =
      sign ? (uint64_t)(-(v + 1)) + 1 : (uint64_t)v;  // INT64_MIN-safe abs
  int n = 63 - __builtin_clzll(m);  // index of the top set bit
  join(out, sign, (uint16_t)(16383 + n), m << (63 - n));
}

void zffe_i32_to_f80(int32_t v, uint8_t out[10]) {
  zffe_i64_to_f80((int64_t)v, out);  // exact
}

void zffe_i16_to_f80(int16_t v, uint8_t out[10]) {
  zffe_i64_to_f80((int64_t)v, out);  // exact
}

void zffe_u32_to_f80(uint32_t v, uint8_t out[10]) {
  zffe_i64_to_f80((int64_t)v, out);  // exact
}

double zffe_f80_add(const uint8_t a[10], const uint8_t b[10]) {
  return zffe_f80_to_f64(a) + zffe_f80_to_f64(b);
}

double zffe_f80_sub(const uint8_t a[10], const uint8_t b[10]) {
  return zffe_f80_to_f64(a) - zffe_f80_to_f64(b);
}

double zffe_f80_mul(const uint8_t a[10], const uint8_t b[10]) {
  return zffe_f80_to_f64(a) * zffe_f80_to_f64(b);
}

double zffe_f80_div(const uint8_t a[10], const uint8_t b[10]) {
  return zffe_f80_to_f64(a) / zffe_f80_to_f64(b);
}

// LLVM FCmpPredicate numbers (see InstrTypes.h).
int zffe_f80_cmp(int pred, const uint8_t a[10], const uint8_t b[10]) {
  double x = zffe_f80_to_f64(a);
  double y = zffe_f80_to_f64(b);
  bool un = isnan(x) || isnan(y);
  switch (pred) {
    case 0:  // false
      return 0;
    case 1:  // oeq
      return !un && x == y;
    case 2:  // ogt
      return !un && x > y;
    case 3:  // oge
      return !un && x >= y;
    case 4:  // olt
      return !un && x < y;
    case 5:  // ole
      return !un && x <= y;
    case 6:  // one
      return !un && x != y;
    case 7:  // ord
      return !un;
    case 8:  // uno
      return un;
    case 9:  // ueq
      return un || x == y;
    case 10:  // ugt
      return un || x > y;
    case 11:  // uge
      return un || x >= y;
    case 12:  // ult
      return un || x < y;
    case 13:  // ule
      return un || x <= y;
    case 14:  // une
      return un || x != y;
    case 15:  // true
      return 1;
    default:
      abort();  // not an LLVM predicate: loud, since it means a bad rewrite
  }
}

// LLVM FPClassTest bits (see FloatingPointMode.h).
int zffe_f80_classify(int mask, const uint8_t a[10]) {
  Parts p = split(a);
  unsigned cls = 0;
  if (isNaNParts(p)) {
    // x87 sNaN: int bit clear with nonzero fraction; everything else qNaN.
    bool snan = (p.mant & 0x8000000000000000ULL) == 0 &&
                (p.mant & 0x7FFFFFFFFFFFFFFFULL) != 0;
    cls = snan ? 0x0001 : 0x0002;
  } else if (isInf(p)) {
    cls = p.sign ? 0x0004 : 0x0200;
  } else if (p.exp == 0 && p.mant == 0) {
    cls = p.sign ? 0x0020 : 0x0040;
  } else if (p.exp == 0) {
    cls = p.sign ? 0x0010 : 0x0080;
  } else {
    cls = p.sign ? 0x0008 : 0x0100;
  }
  return (cls & (unsigned)mask) != 0;
}

double zffe_f80_nearbyint(const uint8_t a[10]) {
  double d = zffe_f80_to_f64(a);
  if (!isfinite(d)) return d;
  // Host rounding mode is never touched (stays nearest-even), so implement
  // the guest mode explicitly instead of trusting rint().
  switch (__remill_fpu_get_rounding() & 3) {
    case 1:  // down
      return floor(d);
    case 2:  // up
      return ceil(d);
    case 3:  // chop
      return trunc(d);
    default: {  // nearest-even, manual (no host-mode assumption)
      double fl = floor(d);
      if (fl == d) return d;  // already integral (incl. huge)
      double ce = ceil(d);
      double dl = d - fl;
      double dc = ce - d;
      if (dl < dc) return fl;
      if (dc < dl) return ce;
      return (fmod(fl, 2.0) == 0.0) ? fl : ce;  // tie: even
    }
  }
}

double zffe_f80_trunc(const uint8_t a[10]) { return trunc(zffe_f80_to_f64(a)); }

}  // extern "C"
