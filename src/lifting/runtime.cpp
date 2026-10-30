// zffe Remill runtime. See runtime.h.
//
// The semantics bitcode references these helpers but defines none of them;
// downstream runners are expected to provide them (the JIT links this file's
// definitions, see jit.cpp). Single-threaded throughout, like the rest of
// the guest runtime: atomics are plain read-modify-write, barriers no-ops.

#include "runtime.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <chrono>
#include <csetjmp>
#include <cstring>

#include "guest_mem.h"

extern "C" {

// Resolve-or-die lookup for indirect control flow, implemented by the JIT
// (jit.cpp). Never returns null: an unresolvable PC aborts inside.
extern void *zffe_dispatch_target(uint32_t pc);

Memory *__remill_function_call(State &state, addr_t addr, Memory *mem) {
  auto *fn = reinterpret_cast<TraceFn *>(zffe_dispatch_target(addr));
  return fn(&state, addr, mem);
}

// Direct calls lift to direct LLVM calls, so returning from a trace means
// returning from the LLVM function; the popped guest retaddr (our `addr`)
// matches the LLVM caller by construction. Guest longjmp (IRET) is the one
// unbalanced path and never reaches here: the async handler longjmps back
// to the guarded run instead. Hand-written push/ret jumps would already
// have shown up as indirect jumps.
Memory *__remill_function_return(State &state, addr_t addr, Memory *mem) {
  (void)state;
  (void)addr;
  return mem;
}

Memory *__remill_missing_block(State &state, addr_t addr, Memory *mem) {
  (void)state;
  (void)mem;
  fprintf(stderr, "zffe: reached missing block at guest 0x%x\n", addr);
  abort();
}

Memory *__remill_error(State &state, addr_t addr, Memory *mem) {
  (void)state;
  (void)mem;
  fprintf(stderr, "zffe: invalid/unsupported instruction at guest 0x%x\n",
          addr);
  abort();
}

}  // extern "C"

namespace {
// GPR dword slots, per remill X86 State.h (GPR base 2208 in State; each
// Reg 8 bytes with the dword at +0, padded exactly as the shim's verified
// comment describes). Re-verify if the pinned Remill moves.
const size_t kGprBase = 2208;
const size_t kEaxOff = kGprBase + 8;
const size_t kEbxOff = kGprBase + 24;
const size_t kEcxOff = kGprBase + 40;
const size_t kEdxOff = kGprBase + 56;

uint32_t gprGet(State &state, size_t off) {
  uint32_t v = 0;
  memcpy(&v, reinterpret_cast<uint8_t *>(&state) + off, sizeof(v));
  return v;
}

void gprSet(State &state, size_t off, uint32_t v) {
  memcpy(reinterpret_cast<uint8_t *>(&state) + off, &v, sizeof(v));
}

// ArchState sits at State+0 (State : X86State : ArchState): hyper_call ID
// and, for INT N, the vector. EIP is rip's low dword (GPR+264). Per remill
// X86 State.h / Runtime/State.h; re-verify if the pinned Remill moves.
const size_t kHyperCallOff = 0;
const size_t kHyperCallVecOff = 8;
const size_t kEipOff = kGprBase + 264;

// Guest-longjmp landing state. The IRET handler stashes the resume here
// and longjmps back to the guarded run, which dispatches and calls it
// fresh. Globals, deliberately: setjmp leaves non-volatile modified frame
// locals indeterminate after a longjmp, so the guarded frame keeps nothing
// but the jmp_buf (single-threaded guest throughout, as ever).
struct GuardRun {
  TraceFn *fn;
  State *state;
  uint32_t pc;
  Memory *mem;
};
GuardRun g_run = {};
jmp_buf g_ret_buf;
bool g_ret_armed = false;
}  // namespace

extern "C" Memory *__remill_async_hyper_call(State &state, addr_t ret_addr,
                                             Memory *mem) {
  (void)ret_addr;
  // AsyncHyperCall::Name values (remill/Arch/Runtime/HyperCall.h).
  uint32_t hc = gprGet(state, kHyperCallOff);
  if (hc == 6) {  // kX86IRet: guest longjmp. The IRET ISEL already popped
    // EIP/CS/EFLAGS into state; stash the resume and abandon host frames.
    // Never returns: the guarded run below dispatches and calls it fresh.
    if (!g_ret_armed) {
      fprintf(stderr, "zffe: longjmp with no armed return\n");
      abort();
    }
    g_run.state = &state;
    g_run.pc = gprGet(state, kEipOff);
    g_run.mem = mem;
    longjmp(g_ret_buf, 1);
    __builtin_unreachable();
  }
  uint32_t vec = gprGet(state, kHyperCallVecOff);
  uint32_t pc = gprGet(state, kEipOff);
  fprintf(stderr,
          "zffe: unhandled async hypercall %u (vector 0x%x) at guest 0x%x\n",
          hc, vec, pc);
  abort();
}

extern "C" Memory *zffe_run_guarded(State *state, TraceFn *entry, uint32_t pc,
                                    Memory *mem) {
  // Save any outer guard: reentrant host-to-guest calls overwrite these.
  GuardRun outer_run = g_run;
  bool outer_armed = g_ret_armed;
  unsigned char outer_buf[sizeof(g_ret_buf)];
  memcpy(outer_buf, g_ret_buf, sizeof(g_ret_buf));
  g_run.fn = entry;
  g_run.state = state;
  g_run.pc = pc;
  g_run.mem = mem;
  g_ret_armed = true;
  for (;;) {
    if (setjmp(g_ret_buf) == 0) {
      Memory *r = g_run.fn(g_run.state, g_run.pc, g_run.mem);
      g_run = outer_run;
      g_ret_armed = outer_armed;
      memcpy(g_ret_buf, outer_buf, sizeof(g_ret_buf));
      return r;
    }
    // Longjmp landed (resume already stashed by the handler): dispatch
    // the target -- lifting it first if never compiled -- and call fresh.
    g_run.fn = reinterpret_cast<TraceFn *>(zffe_dispatch_target(g_run.pc));
  }
}

extern "C" Memory *__remill_sync_hyper_call(State &state, Memory *mem,
                                           uint32_t idx) {
  // SyncHyperCall::Name values (remill/Arch/Runtime/HyperCall.h).
  switch (idx) {
    case 0x102: {  // kX86CPUID: report a plain Pentium, GenuineIntel
      uint32_t leaf = gprGet(state, kEaxOff);
      uint32_t eax = 0, ebx = 0, ecx = 0, edx = 0;
      if (leaf == 0) {
        eax = 1;  // max basic leaf
        ebx = 0x756E6547;  // "Genu"
        edx = 0x49656E69;  // "ineI"
        ecx = 0x6C65746E;  // "ntel"
      } else if (leaf == 1) {
        eax = 0x0525;  // family 5, model 2 (P54C), stepping 5
        // EDX: FPU,VME,DE,PSE,TSC,MSR,MCE,CX8. Deliberately no MMX/CMOV/
        // APIC: pre-MMX Pentium, so the game takes its 1995 code paths.
        edx = 0x1BF;
      } else if (leaf >= 0x80000000u) {
        eax = 0x80000000u;  // max extended leaf: none
      }
      gprSet(state, kEaxOff, eax);
      gprSet(state, kEbxOff, ebx);
      gprSet(state, kEcxOff, ecx);
      gprSet(state, kEdxOff, edx);
      return mem;
    }
    case 0x103:  // kX86ReadTSC: monotonic nanoseconds, plenty for timing
    case 0x104: {  // kX86ReadTSCP: same, AUX zero
      using clock = std::chrono::steady_clock;
      static const auto t0 = clock::now();
      uint64_t ns = (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(
          clock::now() - t0)
                        .count();
      gprSet(state, kEaxOff, (uint32_t)ns);
      gprSet(state, kEdxOff, (uint32_t)(ns >> 32));
      if (idx == 0x104) gprSet(state, kEcxOff, 0);
      return mem;
    }
    case 0x105:  // kX86XGetBV: x87+SSE+AVX enabled (a 2011 insn; the game
                 // never executes it, but answer sanely if it does)
      gprSet(state, kEaxOff, 0x7);
      gprSet(state, kEdxOff, 0);
      return mem;
    case 0x10D:  // kX86SetSegmentES
      return __remill_x86_set_segment_es(mem);
    case 0x10E:  // kX86SetSegmentSS
      return __remill_x86_set_segment_ss(mem);
    case 0x10F:  // kX86SetSegmentDS
      return __remill_x86_set_segment_ds(mem);
    case 0x110:  // kX86SetSegmentFS
      return __remill_x86_set_segment_fs(mem);
    case 0x111:  // kX86SetSegmentGS
      return __remill_x86_set_segment_gs(mem);
    case 0x112:  // kX86SetDebugReg
      return __remill_x86_set_debug_reg(mem);
    case 0x114:  // kX86SetControlReg0
      return __remill_x86_set_control_reg_0(mem);
    case 0x115:  // kX86SetControlReg1
      return __remill_x86_set_control_reg_1(mem);
    case 0x116:  // kX86SetControlReg2
      return __remill_x86_set_control_reg_2(mem);
    case 0x117:  // kX86SetControlReg3
      return __remill_x86_set_control_reg_3(mem);
    case 0x118:  // kX86SetControlReg4
      return __remill_x86_set_control_reg_4(mem);
    default:
      fprintf(stderr,
              "zffe: privileged/host instruction (hypercall 0x%x) reached; "
              "aborting\n",
              idx);
      abort();
  }
}

bool __remill_compare_eq(bool r) { return r; }
bool __remill_compare_neq(bool r) { return r; }
bool __remill_compare_sle(bool r) { return r; }
bool __remill_compare_slt(bool r) { return r; }
bool __remill_compare_sge(bool r) { return r; }
bool __remill_compare_sgt(bool r) { return r; }
bool __remill_compare_ule(bool r) { return r; }
bool __remill_compare_ult(bool r) { return r; }
bool __remill_compare_uge(bool r) { return r; }
bool __remill_compare_ugt(bool r) { return r; }

bool __remill_flag_computation_zero(bool r, ...) { return r; }
bool __remill_flag_computation_sign(bool r, ...) { return r; }
bool __remill_flag_computation_overflow(bool r, ...) { return r; }
bool __remill_flag_computation_carry(bool r, ...) { return r; }

uint8_t __remill_undefined_8(void) { return 0; }
uint16_t __remill_undefined_16(void) { return 0; }
uint32_t __remill_undefined_32(void) { return 0; }
uint64_t __remill_undefined_64(void) { return 0; }
float32_t __remill_undefined_f32(void) { return 0; }
float64_t __remill_undefined_f64(void) { return 0; }
float80_t __remill_undefined_f80(void) {
  float80_t v;
  memset(&v, 0, sizeof(v));
  return v;
}
float128_t __remill_undefined_f128(void) { return 0; }

Memory *__remill_atomic_begin(Memory *mem) { return mem; }
Memory *__remill_atomic_end(Memory *mem) { return mem; }

namespace {
uintptr_t cmpxchg_base(void) {
  return static_cast<uintptr_t>(zffe_mem_base());
}
}  // namespace

Memory *__remill_compare_exchange_memory_8(Memory *mem, addr_t addr,
                                           uint8_t &expected,
                                           uint8_t desired) {
  uint8_t *p = reinterpret_cast<uint8_t *>(cmpxchg_base() + addr);
  uint8_t cur;
  memcpy(&cur, p, sizeof(cur));
  if (cur == expected) {
    memcpy(p, &desired, sizeof(desired));
  } else {
    expected = cur;
  }
  return mem;
}

Memory *__remill_compare_exchange_memory_16(Memory *mem, addr_t addr,
                                            uint16_t &expected,
                                            uint16_t desired) {
  uint8_t *p = reinterpret_cast<uint8_t *>(cmpxchg_base() + addr);
  uint16_t cur;
  memcpy(&cur, p, sizeof(cur));
  if (cur == expected) {
    memcpy(p, &desired, sizeof(desired));
  } else {
    expected = cur;
  }
  return mem;
}

Memory *__remill_compare_exchange_memory_32(Memory *mem, addr_t addr,
                                            uint32_t &expected,
                                            uint32_t desired) {
  uint8_t *p = reinterpret_cast<uint8_t *>(cmpxchg_base() + addr);
  uint32_t cur;
  memcpy(&cur, p, sizeof(cur));
  if (cur == expected) {
    memcpy(p, &desired, sizeof(desired));
  } else {
    expected = cur;
  }
  return mem;
}

Memory *__remill_compare_exchange_memory_64(Memory *mem, addr_t addr,
                                            uint64_t &expected,
                                            uint64_t desired) {
  uint8_t *p = reinterpret_cast<uint8_t *>(cmpxchg_base() + addr);
  uint64_t cur;
  memcpy(&cur, p, sizeof(cur));
  if (cur == expected) {
    memcpy(p, &desired, sizeof(desired));
  } else {
    expected = cur;
  }
  return mem;
}

Memory *__remill_barrier_load_load(Memory *mem) { return mem; }
Memory *__remill_barrier_load_store(Memory *mem) { return mem; }
Memory *__remill_barrier_store_load(Memory *mem) { return mem; }
Memory *__remill_barrier_store_store(Memory *mem) { return mem; }

namespace {
int32_t g_fpu_rounding = 0;  // x86 default: round to nearest
}  // namespace

int32_t __remill_fpu_exception_test(int32_t read_mask) {
  (void)read_mask;
  return 0;  // no pending exceptions, matching post-FNINIT hardware
}

void __remill_fpu_exception_clear(int32_t clear_mask) {
  (void)clear_mask;
}

void __remill_fpu_set_rounding(int32_t round_mode) {
  g_fpu_rounding = round_mode;
}

int32_t __remill_fpu_get_rounding(void) { return g_fpu_rounding; }

namespace {
bool g_io_warned = false;
bool g_seg_warned = false;
bool g_creg_warned = false;
}  // namespace

extern "C" {

uint8_t __remill_read_io_port_8(Memory *mem, addr_t port) {
  (void)mem;
  if (!g_io_warned) {
    g_io_warned = true;
    fprintf(stderr, "zffe: guest read I/O port 0x%x; returning open-bus 0xFF\n",
            port);
  }
  return 0xFF;
}

uint16_t __remill_read_io_port_16(Memory *mem, addr_t port) {
  (void)mem;
  if (!g_io_warned) {
    g_io_warned = true;
    fprintf(stderr, "zffe: guest read I/O port 0x%x; returning open-bus 0xFF\n",
            port);
  }
  return 0xFFFF;
}

uint32_t __remill_read_io_port_32(Memory *mem, addr_t port) {
  (void)mem;
  if (!g_io_warned) {
    g_io_warned = true;
    fprintf(stderr, "zffe: guest read I/O port 0x%x; returning open-bus 0xFF\n",
            port);
  }
  return 0xFFFFFFFF;
}

Memory *__remill_write_io_port_8(Memory *mem, addr_t port, uint8_t val) {
  (void)val;
  if (!g_io_warned) {
    g_io_warned = true;
    fprintf(stderr, "zffe: guest wrote I/O port 0x%x; ignored\n", port);
  }
  return mem;
}

Memory *__remill_write_io_port_16(Memory *mem, addr_t port, uint16_t val) {
  (void)val;
  if (!g_io_warned) {
    g_io_warned = true;
    fprintf(stderr, "zffe: guest wrote I/O port 0x%x; ignored\n", port);
  }
  return mem;
}

Memory *__remill_write_io_port_32(Memory *mem, addr_t port, uint32_t val) {
  (void)val;
  if (!g_io_warned) {
    g_io_warned = true;
    fprintf(stderr, "zffe: guest wrote I/O port 0x%x; ignored\n", port);
  }
  return mem;
}

static Memory *seg_noop(Memory *mem) {
  if (!g_seg_warned) {
    g_seg_warned = true;
    fprintf(stderr, "zffe: guest set a segment register; flat model kept\n");
  }
  return mem;
}

Memory *__remill_x86_set_segment_ds(Memory *mem) { return seg_noop(mem); }
Memory *__remill_x86_set_segment_es(Memory *mem) { return seg_noop(mem); }
Memory *__remill_x86_set_segment_fs(Memory *mem) { return seg_noop(mem); }
Memory *__remill_x86_set_segment_gs(Memory *mem) { return seg_noop(mem); }
Memory *__remill_x86_set_segment_ss(Memory *mem) { return seg_noop(mem); }
Memory *__remill_x86_set_debug_reg(Memory *mem) { return seg_noop(mem); }

static Memory *creg_noop(Memory *mem) {
  if (!g_creg_warned) {
    g_creg_warned = true;
    fprintf(stderr, "zffe: guest wrote a control register; ignored\n");
  }
  return mem;
}

Memory *__remill_x86_set_control_reg_0(Memory *mem) { return creg_noop(mem); }
Memory *__remill_x86_set_control_reg_1(Memory *mem) { return creg_noop(mem); }
Memory *__remill_x86_set_control_reg_2(Memory *mem) { return creg_noop(mem); }
Memory *__remill_x86_set_control_reg_3(Memory *mem) { return creg_noop(mem); }
Memory *__remill_x86_set_control_reg_4(Memory *mem) { return creg_noop(mem); }

}  // extern "C"
