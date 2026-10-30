// zffe Remill runtime: host definitions for the `__remill_*` helpers that
// the semantics bitcode leaves undefined (see jit.cpp for how the JIT links
// these). Signatures mirror remill/Arch/Runtime/Intrinsics.h exactly
// (verified against upstream); the types below are local mirrors, same as
// guest_mem.h, so no Remill headers are needed.

#pragma once

#include <stddef.h>
#include <stdint.h>

#include "guest_mem.h"  // Memory, addr_t, float types (shared, not redefined)

struct State;  // opaque here; only ever passed through as State&

#ifdef __cplusplus
extern "C" {
#endif

// --- Control flow (jump lives in jump_stub.S) ---
typedef Memory *TraceFn(State *state, uint32_t pc, Memory *mem);
Memory *__remill_function_call(State &state, addr_t addr, Memory *mem);
Memory *__remill_function_return(State &state, addr_t addr, Memory *mem);
Memory *__remill_jump(State &state, addr_t addr, Memory *mem);
Memory *__remill_missing_block(State &state, addr_t addr, Memory *mem);
Memory *__remill_error(State &state, addr_t addr, Memory *mem);
// Async hypercalls (INT, IRET, far jumps...): the ISEL records the ID in
// state.hyper_call, then the trace calls here. Only IRET (guest longjmp)
// is implemented; anything else aborts loudly.
Memory *__remill_async_hyper_call(State &state, addr_t ret_addr, Memory *mem);
// Guarded trace entry: all host-to-guest calls go through here so guest
// longjmp (IRET) can abandon host frames and resume at its target.
Memory *zffe_run_guarded(State *state, TraceFn *entry, uint32_t pc,
                         Memory *mem);

// Privileged/host instructions (CPUID, RDTSC, ...). Replaces Remill's own
// definition on ALL hosts: upstream passes through to the host CPU (wrong
// CPU identity on modern machines, unbuildable elsewhere), while this one
// synthesizes a period Pentium. Index enum: SyncHyperCall::Name.
Memory *__remill_sync_hyper_call(State &state, Memory *mem, uint32_t idx);

// --- Condition/comparison markers (identity) ---
bool __remill_compare_eq(bool result);
bool __remill_compare_neq(bool result);
bool __remill_compare_sle(bool result);
bool __remill_compare_slt(bool result);
bool __remill_compare_sge(bool result);
bool __remill_compare_sgt(bool result);
bool __remill_compare_ule(bool result);
bool __remill_compare_ult(bool result);
bool __remill_compare_uge(bool result);
bool __remill_compare_ugt(bool result);

// --- Lazy flag markers (identity over the first arg) ---
bool __remill_flag_computation_zero(bool result, ...);
bool __remill_flag_computation_sign(bool result, ...);
bool __remill_flag_computation_overflow(bool result, ...);
bool __remill_flag_computation_carry(bool result, ...);

// --- Undefined values (deterministic zero) ---
uint8_t __remill_undefined_8(void);
uint16_t __remill_undefined_16(void);
uint32_t __remill_undefined_32(void);
uint64_t __remill_undefined_64(void);
float32_t __remill_undefined_f32(void);
float64_t __remill_undefined_f64(void);
float80_t __remill_undefined_f80(void);
float128_t __remill_undefined_f128(void);

// --- Single-threaded atomics (plain read-modify-write) ---
Memory *__remill_atomic_begin(Memory *mem);
Memory *__remill_atomic_end(Memory *mem);
Memory *__remill_compare_exchange_memory_8(Memory *mem, addr_t addr,
                                           uint8_t &expected, uint8_t desired);
Memory *__remill_compare_exchange_memory_16(Memory *mem, addr_t addr,
                                            uint16_t &expected,
                                            uint16_t desired);
Memory *__remill_compare_exchange_memory_32(Memory *mem, addr_t addr,
                                            uint32_t &expected,
                                            uint32_t desired);
Memory *__remill_compare_exchange_memory_64(Memory *mem, addr_t addr,
                                            uint64_t &expected,
                                            uint64_t desired);

// --- Barriers (no-ops: single-threaded guest) ---
Memory *__remill_barrier_load_load(Memory *mem);
Memory *__remill_barrier_load_store(Memory *mem);
Memory *__remill_barrier_store_load(Memory *mem);
Memory *__remill_barrier_store_store(Memory *mem);

// --- FPU environment (host-independent shadow state) ---
int32_t __remill_fpu_exception_test(int32_t read_mask);
void __remill_fpu_exception_clear(int32_t clear_mask);
void __remill_fpu_set_rounding(int32_t round_mode);
int32_t __remill_fpu_get_rounding(void);

// --- Privileged surface the userspace guest must not touch ---
uint8_t __remill_read_io_port_8(Memory *mem, addr_t port);
uint16_t __remill_read_io_port_16(Memory *mem, addr_t port);
uint32_t __remill_read_io_port_32(Memory *mem, addr_t port);
Memory *__remill_write_io_port_8(Memory *mem, addr_t port, uint8_t val);
Memory *__remill_write_io_port_16(Memory *mem, addr_t port, uint16_t val);
Memory *__remill_write_io_port_32(Memory *mem, addr_t port, uint32_t val);
Memory *__remill_x86_set_segment_ds(Memory *mem);
Memory *__remill_x86_set_segment_es(Memory *mem);
Memory *__remill_x86_set_segment_fs(Memory *mem);
Memory *__remill_x86_set_segment_gs(Memory *mem);
Memory *__remill_x86_set_segment_ss(Memory *mem);
Memory *__remill_x86_set_debug_reg(Memory *mem);
Memory *__remill_x86_set_control_reg_0(Memory *mem);
Memory *__remill_x86_set_control_reg_1(Memory *mem);
Memory *__remill_x86_set_control_reg_2(Memory *mem);
Memory *__remill_x86_set_control_reg_3(Memory *mem);
Memory *__remill_x86_set_control_reg_4(Memory *mem);

#ifdef __cplusplus
}
#endif
