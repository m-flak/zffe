// zffe guest memory runtime. See guest_mem.h.
//
// All accesses use memcpy: guest addresses may be unaligned, and direct
// dereference of a multi-byte type at an odd address is UB (and faults on
// ARM). Single-threaded guest: no atomics needed.

#include "guest_mem.h"

#include <string.h>

namespace {
uintptr_t g_base = 0;

inline uint8_t *guest_ptr(addr_t addr) {
  return reinterpret_cast<uint8_t *>(g_base + static_cast<uintptr_t>(addr));
}
}  // namespace

extern "C" {

void zffe_mem_set_base(uint64_t base) { g_base = static_cast<uintptr_t>(base); }
uint64_t zffe_mem_base(void) { return static_cast<uint64_t>(g_base); }

uint8_t __remill_read_memory_8(Memory *mem, addr_t addr) {
  (void)mem;
  return *guest_ptr(addr);
}

uint16_t __remill_read_memory_16(Memory *mem, addr_t addr) {
  (void)mem;
  uint16_t val;
  memcpy(&val, guest_ptr(addr), sizeof(val));
  return val;
}

uint32_t __remill_read_memory_32(Memory *mem, addr_t addr) {
  (void)mem;
  uint32_t val;
  memcpy(&val, guest_ptr(addr), sizeof(val));
  return val;
}

uint64_t __remill_read_memory_64(Memory *mem, addr_t addr) {
  (void)mem;
  uint64_t val;
  memcpy(&val, guest_ptr(addr), sizeof(val));
  return val;
}

Memory *__remill_write_memory_8(Memory *mem, addr_t addr, uint8_t val) {
  *guest_ptr(addr) = val;
  return mem;
}

Memory *__remill_write_memory_16(Memory *mem, addr_t addr, uint16_t val) {
  memcpy(guest_ptr(addr), &val, sizeof(val));
  return mem;
}

Memory *__remill_write_memory_32(Memory *mem, addr_t addr, uint32_t val) {
  memcpy(guest_ptr(addr), &val, sizeof(val));
  return mem;
}

Memory *__remill_write_memory_64(Memory *mem, addr_t addr, uint64_t val) {
  memcpy(guest_ptr(addr), &val, sizeof(val));
  return mem;
}

float32_t __remill_read_memory_f32(Memory *mem, addr_t addr) {
  (void)mem;
  float32_t val;
  memcpy(&val, guest_ptr(addr), sizeof(val));
  return val;
}

float64_t __remill_read_memory_f64(Memory *mem, addr_t addr) {
  (void)mem;
  float64_t val;
  memcpy(&val, guest_ptr(addr), sizeof(val));
  return val;
}

Memory *__remill_read_memory_f80(Memory *mem, addr_t addr, float80_t &out) {
  memcpy(out.data, guest_ptr(addr), sizeof(out.data));
  return mem;
}

float128_t __remill_read_memory_f128(Memory *mem, addr_t addr) {
  (void)mem;
  float128_t val;
  memcpy(&val, guest_ptr(addr), sizeof(val));
  return val;
}

Memory *__remill_write_memory_f32(Memory *mem, addr_t addr, float32_t val) {
  memcpy(guest_ptr(addr), &val, sizeof(val));
  return mem;
}

Memory *__remill_write_memory_f64(Memory *mem, addr_t addr, float64_t val) {
  memcpy(guest_ptr(addr), &val, sizeof(val));
  return mem;
}

Memory *__remill_write_memory_f80(Memory *mem, addr_t addr,
                                 const float80_t &val) {
  memcpy(guest_ptr(addr), val.data, sizeof(val.data));
  return mem;
}

Memory *__remill_write_memory_f128(Memory *mem, addr_t addr, float128_t val) {
  memcpy(guest_ptr(addr), &val, sizeof(val));
  return mem;
}

}  // extern "C"
