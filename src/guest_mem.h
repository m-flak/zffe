/* zffe guest memory runtime: translating definitions of Remill's memory
 * intrinsics. Every guest access becomes *(g_base + addr); the Memory*
 * token is threaded through unchanged for ordering.
 *
 * No Remill/LLVM headers needed: the declarations below mirror
 * remill/Arch/Runtime/Intrinsics.h exactly (verified against upstream).
 * The shim strips Remill's identity-mapping definitions from the lifted
 * module so these win at link time (see shim.cpp).
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

struct Memory;  // opaque, as in Remill
typedef uint32_t addr_t;  // x86 guest

typedef float float32_t;
typedef double float64_t;
typedef double float128_t;  // sic: matches Remill (see their TODO)
struct float80_t {
  uint8_t data[10];
};

#ifdef __cplusplus
extern "C" {
#endif

/* Set/query the host base added to every guest address. */
void zffe_mem_set_base(uint64_t base);
uint64_t zffe_mem_base(void);

uint8_t __remill_read_memory_8(Memory *mem, addr_t addr);
uint16_t __remill_read_memory_16(Memory *mem, addr_t addr);
uint32_t __remill_read_memory_32(Memory *mem, addr_t addr);
uint64_t __remill_read_memory_64(Memory *mem, addr_t addr);
Memory *__remill_write_memory_8(Memory *mem, addr_t addr, uint8_t val);
Memory *__remill_write_memory_16(Memory *mem, addr_t addr, uint16_t val);
Memory *__remill_write_memory_32(Memory *mem, addr_t addr, uint32_t val);
Memory *__remill_write_memory_64(Memory *mem, addr_t addr, uint64_t val);

float32_t __remill_read_memory_f32(Memory *mem, addr_t addr);
float64_t __remill_read_memory_f64(Memory *mem, addr_t addr);
Memory *__remill_read_memory_f80(Memory *mem, addr_t addr, float80_t &out);
float128_t __remill_read_memory_f128(Memory *mem, addr_t addr);
Memory *__remill_write_memory_f32(Memory *mem, addr_t addr, float32_t val);
Memory *__remill_write_memory_f64(Memory *mem, addr_t addr, float64_t val);
Memory *__remill_write_memory_f80(Memory *mem, addr_t addr,
                                 const float80_t &val);
Memory *__remill_write_memory_f128(Memory *mem, addr_t addr, float128_t val);

#ifdef __cplusplus
}
#endif
