// zffe JIT runner. See shim.h for the ABI contract.
//
// Model: the base module (whatever liftAll lifted; possibly nothing yet)
// is compiled up front by an in-process ORC LLJIT. Direct calls between
// traces are direct machine calls. Indirect control flow (`__remill_jump`
// / `__remill_function_call`) dispatches at runtime through a trace cache:
// cache hit calls through, miss lifts the target into a small miss module
// (same LLVM context, spare Arch bound to it) and links it against the
// base module by name. Fully lazy operation works: create() on an unlifted
// image lifts traces as dispatch discovers them.
//
// Host-provided symbols (guest_mem.cpp, runtime.cpp, jump_stub.S, Zig
// trampolines) are defined as absolute symbols; libc stragglers (libm for
// x87 transcendentals, backend-emitted memcpy) resolve through a
// process-symbol fallback generator. One JIT per process (the dispatch
// stubs reach it through a global); single-threaded guest throughout.

#include "shim.h"

#include "f80.h"
#include "guest_mem.h"
#include "runtime.h"
#include "shim_priv.h"

#include <remill/Arch/Arch.h>
#include <remill/BC/TraceLifter.h>
#include <llvm/ExecutionEngine/Orc/AbsoluteSymbols.h>
#include <llvm/ExecutionEngine/Orc/ExecutionUtils.h>
#include <llvm/ExecutionEngine/Orc/LLJIT.h>
#include <llvm/ExecutionEngine/Orc/Mangling.h>
#include <llvm/ExecutionEngine/Orc/ThreadSafeModule.h>
#include <llvm/IR/DerivedTypes.h>
#include <llvm/IR/Function.h>
#include <llvm/IR/GlobalVariable.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/Instructions.h>
#include <llvm/IR/Intrinsics.h>
#include <llvm/IR/Verifier.h>
#include <llvm/Transforms/Utils/Cloning.h>
#include <llvm/Support/Error.h>
#include <llvm/Support/TargetSelect.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/TargetParser/Host.h>
#include <llvm/TargetParser/Triple.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

// Zig trampoline resolver (trampoline.zig). Strips one leading `_` itself;
// the caller strips the lifter's `import_` prefix first.
extern "C" const void *zffe_tramp_resolve(const char *name);

struct zffe_jit {
  std::unique_ptr<llvm::orc::LLJIT> lljit;
  llvm::orc::ThreadSafeContext tsctx;
  zffe_image_t *img = nullptr;  // borrowed; dies after the JIT
  std::string os;
  std::string arch;
  // Post-rewrite copy of the base module, retained for miss lifts. Remill's
  // lifter reads ISEL *bodies* (InstructionLifter reverse-maps argument
  // types from in-body uses; a bare declaration lifts every register
  // operand as `undef`), so each miss module starts as a clone of this and
  // the lifter sees exactly what the base lift saw. Never compiled; ~one
  // base module of IR per JIT.
  std::unique_ptr<llvm::Module> lift_clone;
  std::unordered_map<uint64_t, std::string> names;  // map func addr -> name
  std::unordered_map<uint64_t, void *> cache;  // guest pc -> code addr
};

namespace {

zffe_jit *g_jit = nullptr;

bool startsWith(const std::string &s, const char *prefix) {
  return s.compare(0, strlen(prefix), prefix) == 0;
}

std::string traceNameFor(zffe_jit *jit, uint64_t pc) {
  auto it = jit->names.find(pc);
  if (it != jit->names.end()) return it->second;
  char buf[32];
  snprintf(buf, sizeof(buf), "sub_%llx", (unsigned long long)pc);
  return buf;
}

[[noreturn]] void noTrace(zffe_jit *jit, uint32_t pc) {
  const char *where = "";
  if (jit && jit->img) {
    if (pc < jit->img->code_start || pc >= jit->img->code_end) {
      where = " (outside the executable range)";
    }
  }
  fprintf(stderr, "zffe: cannot resolve trace for guest 0x%x%s; aborting\n",
          pc, where);
  abort();
}

// Host definitions for Remill helpers (runtime.cpp), guest memory
// (guest_mem.cpp), and the tail-jump stub (jump_stub.S). Addresses are
// link-verified: a missing definition fails the build, not the run.
std::vector<std::pair<std::string, const void *>> hostSymbols(void) {
  using P = std::pair<std::string, const void *>;
  return {
      // Control flow.
      P("__remill_function_call", (const void *)&__remill_function_call),
      P("__remill_function_return", (const void *)&__remill_function_return),
      P("__remill_jump", (const void *)&__remill_jump),
      P("__remill_missing_block", (const void *)&__remill_missing_block),
      P("__remill_error", (const void *)&__remill_error),
      P("__remill_sync_hyper_call", (const void *)&__remill_sync_hyper_call),
      P("__remill_async_hyper_call",
        (const void *)&__remill_async_hyper_call),
      // Guest memory.
      P("__remill_read_memory_8", (const void *)&__remill_read_memory_8),
      P("__remill_read_memory_16", (const void *)&__remill_read_memory_16),
      P("__remill_read_memory_32", (const void *)&__remill_read_memory_32),
      P("__remill_read_memory_64", (const void *)&__remill_read_memory_64),
      P("__remill_write_memory_8", (const void *)&__remill_write_memory_8),
      P("__remill_write_memory_16", (const void *)&__remill_write_memory_16),
      P("__remill_write_memory_32", (const void *)&__remill_write_memory_32),
      P("__remill_write_memory_64", (const void *)&__remill_write_memory_64),
      P("__remill_read_memory_f32", (const void *)&__remill_read_memory_f32),
      P("__remill_read_memory_f64", (const void *)&__remill_read_memory_f64),
      P("__remill_read_memory_f80", (const void *)&__remill_read_memory_f80),
      P("__remill_read_memory_f128", (const void *)&__remill_read_memory_f128),
      P("__remill_write_memory_f32", (const void *)&__remill_write_memory_f32),
      P("__remill_write_memory_f64", (const void *)&__remill_write_memory_f64),
      P("__remill_write_memory_f80", (const void *)&__remill_write_memory_f80),
      P("__remill_write_memory_f128",
        (const void *)&__remill_write_memory_f128),
      // Condition markers.
      P("__remill_compare_eq", (const void *)&__remill_compare_eq),
      P("__remill_compare_neq", (const void *)&__remill_compare_neq),
      P("__remill_compare_sle", (const void *)&__remill_compare_sle),
      P("__remill_compare_slt", (const void *)&__remill_compare_slt),
      P("__remill_compare_sge", (const void *)&__remill_compare_sge),
      P("__remill_compare_sgt", (const void *)&__remill_compare_sgt),
      P("__remill_compare_ule", (const void *)&__remill_compare_ule),
      P("__remill_compare_ult", (const void *)&__remill_compare_ult),
      P("__remill_compare_uge", (const void *)&__remill_compare_uge),
      P("__remill_compare_ugt", (const void *)&__remill_compare_ugt),
      P("__remill_flag_computation_zero",
        (const void *)&__remill_flag_computation_zero),
      P("__remill_flag_computation_sign",
        (const void *)&__remill_flag_computation_sign),
      P("__remill_flag_computation_overflow",
        (const void *)&__remill_flag_computation_overflow),
      P("__remill_flag_computation_carry",
        (const void *)&__remill_flag_computation_carry),
      // Undefined values.
      P("__remill_undefined_8", (const void *)&__remill_undefined_8),
      P("__remill_undefined_16", (const void *)&__remill_undefined_16),
      P("__remill_undefined_32", (const void *)&__remill_undefined_32),
      P("__remill_undefined_64", (const void *)&__remill_undefined_64),
      P("__remill_undefined_f32", (const void *)&__remill_undefined_f32),
      P("__remill_undefined_f64", (const void *)&__remill_undefined_f64),
      P("__remill_undefined_f80", (const void *)&__remill_undefined_f80),
      P("__remill_undefined_f128", (const void *)&__remill_undefined_f128),
      // Atomics (single-threaded).
      P("__remill_atomic_begin", (const void *)&__remill_atomic_begin),
      P("__remill_atomic_end", (const void *)&__remill_atomic_end),
      P("__remill_compare_exchange_memory_8",
        (const void *)&__remill_compare_exchange_memory_8),
      P("__remill_compare_exchange_memory_16",
        (const void *)&__remill_compare_exchange_memory_16),
      P("__remill_compare_exchange_memory_32",
        (const void *)&__remill_compare_exchange_memory_32),
      P("__remill_compare_exchange_memory_64",
        (const void *)&__remill_compare_exchange_memory_64),
      // Barriers.
      P("__remill_barrier_load_load", (const void *)&__remill_barrier_load_load),
      P("__remill_barrier_load_store",
        (const void *)&__remill_barrier_load_store),
      P("__remill_barrier_store_load",
        (const void *)&__remill_barrier_store_load),
      P("__remill_barrier_store_store",
        (const void *)&__remill_barrier_store_store),
      // FPU environment.
      P("__remill_fpu_exception_test",
        (const void *)&__remill_fpu_exception_test),
      P("__remill_fpu_exception_clear",
        (const void *)&__remill_fpu_exception_clear),
      P("__remill_fpu_set_rounding", (const void *)&__remill_fpu_set_rounding),
      P("__remill_fpu_get_rounding", (const void *)&__remill_fpu_get_rounding),
      // Privileged surface.
      P("__remill_read_io_port_8", (const void *)&__remill_read_io_port_8),
      P("__remill_read_io_port_16", (const void *)&__remill_read_io_port_16),
      P("__remill_read_io_port_32", (const void *)&__remill_read_io_port_32),
      P("__remill_write_io_port_8", (const void *)&__remill_write_io_port_8),
      P("__remill_write_io_port_16", (const void *)&__remill_write_io_port_16),
      P("__remill_write_io_port_32", (const void *)&__remill_write_io_port_32),
      P("__remill_x86_set_segment_ds",
        (const void *)&__remill_x86_set_segment_ds),
      P("__remill_x86_set_segment_es",
        (const void *)&__remill_x86_set_segment_es),
      P("__remill_x86_set_segment_fs",
        (const void *)&__remill_x86_set_segment_fs),
      P("__remill_x86_set_segment_gs",
        (const void *)&__remill_x86_set_segment_gs),
      P("__remill_x86_set_segment_ss",
        (const void *)&__remill_x86_set_segment_ss),
      P("__remill_x86_set_debug_reg",
        (const void *)&__remill_x86_set_debug_reg),
      P("__remill_x86_set_control_reg_0",
        (const void *)&__remill_x86_set_control_reg_0),
      P("__remill_x86_set_control_reg_1",
        (const void *)&__remill_x86_set_control_reg_1),
      P("__remill_x86_set_control_reg_2",
        (const void *)&__remill_x86_set_control_reg_2),
      P("__remill_x86_set_control_reg_3",
        (const void *)&__remill_x86_set_control_reg_3),
      P("__remill_x86_set_control_reg_4",
        (const void *)&__remill_x86_set_control_reg_4),
      // f80 soft-float (used only where rewriteF80 ran, i.e. non-x86).
      P("zffe_f80_to_f64", (const void *)&zffe_f80_to_f64),
      P("zffe_f64_to_f80", (const void *)&zffe_f64_to_f80),
      P("zffe_f80_to_f32", (const void *)&zffe_f80_to_f32),
      P("zffe_f32_to_f80", (const void *)&zffe_f32_to_f80),
      P("zffe_f80_to_i16", (const void *)&zffe_f80_to_i16),
      P("zffe_f80_to_i32", (const void *)&zffe_f80_to_i32),
      P("zffe_f80_to_i64", (const void *)&zffe_f80_to_i64),
      P("zffe_f80_to_u64", (const void *)&zffe_f80_to_u64),
      P("zffe_i16_to_f80", (const void *)&zffe_i16_to_f80),
      P("zffe_i32_to_f80", (const void *)&zffe_i32_to_f80),
      P("zffe_i64_to_f80", (const void *)&zffe_i64_to_f80),
      P("zffe_u32_to_f80", (const void *)&zffe_u32_to_f80),
      P("zffe_f80_add", (const void *)&zffe_f80_add),
      P("zffe_f80_sub", (const void *)&zffe_f80_sub),
      P("zffe_f80_mul", (const void *)&zffe_f80_mul),
      P("zffe_f80_div", (const void *)&zffe_f80_div),
      P("zffe_f80_cmp", (const void *)&zffe_f80_cmp),
      P("zffe_f80_classify", (const void *)&zffe_f80_classify),
      P("zffe_f80_nearbyint", (const void *)&zffe_f80_nearbyint),
      P("zffe_f80_trunc", (const void *)&zffe_f80_trunc),
  };
}

// x87 transcendentals lower to libm calls inside the semantics bodies;
// those resolve through the process-symbol fallback (libm must be visible,
// probed eagerly at create()).
bool isLibmName(const std::string &name) {
  static const std::unordered_set<std::string> kLibm = {
      "sqrt", "sqrtf", "sqrtl", "sinl", "cosl", "tanl", "atanl", "fmodl",
      "log2l", "exp2l", "remainderl",
      // Double redirects the f80 rewrite emits on non-x86 hosts.
      "sin", "cos", "tan", "atan", "fmod", "log2", "exp2", "remainder",
  };
  return kLibm.count(name) != 0;
}

// Promote ISEL semantics bodies to external linkage so miss modules link
// to them by name. (They are anonymous-namespace C++, i.e. internal
// linkage, from Remill.) Must run before the base module moves into the
// JIT. Also validates the module actually carries semantics.
bool promoteISELSymbols(llvm::Module *mod, std::string &err) {
  bool any_remill = false;
  for (auto &fn : *mod) {
    if (startsWith(fn.getName().str(), "__remill_")) {
      any_remill = true;
      break;
    }
  }
  size_t nisels = 0;
  for (auto &g : mod->globals()) {
    std::string name = g.getName().str();
    if (!startsWith(name, "ISEL_")) continue;
    if (!g.isConstant() || !g.hasInitializer()) continue;
    auto *target = llvm::dyn_cast<llvm::Function>(
        g.getInitializer()->stripPointerCasts());
    if (!target) continue;  // same fallback the base lift would take
    nisels++;
    if (!target->isDeclaration()) {
      target->setLinkage(llvm::GlobalValue::ExternalLinkage);
    }
  }
  if (!mod->getGlobalVariable("__remill_state")) {
    err = "base module lacks __remill_state";
    return false;
  }
  if (!any_remill || nisels == 0) {
    err = "base module lacks semantics (no __remill_* / ISEL_* entries)";
    return false;
  }
  return true;
}

struct MissGuard {
  ZffeTraceManager *tm;
  ~MissGuard() {
    // Nothing reads cur_defined past the lift (dispatch resolves through
    // the JIT, not the manager), so drop it with the module: on lift
    // failure the module is discarded and the pointers would dangle.
    tm->cur_defined.clear();
    tm->on_demand = false;
    tm->cur_mod = nullptr;
  }
};

// x86 hosts lower x86_fp80 natively; anything else needs the soft-float
// rewrite below (f80 arithmetic has no AArch64 lowering).
bool hostNeedsF80(void) {
  auto arch = llvm::Triple(llvm::sys::getProcessTriple()).getArch();
  return arch != llvm::Triple::x86 && arch != llvm::Triple::x86_64;
}

// Remap x86_fp80 arithmetic to host-double computation (see f80.h) so the
// module compiles on hosts without x87. Storage, calls, signatures, and
// bitwise ops keep the f80 type (all ARM-legal); only value-producing
// arithmetic, conversions, comparisons, rounding, and long-double libm
// calls are rewritten. Idempotent: rerunning finds nothing to do.
// Returns false + err on any f80 construct outside the known set.
bool rewriteF80(llvm::Module *mod, std::string &err) {
  llvm::LLVMContext &ctx = mod->getContext();
  llvm::Type *f80Ty = llvm::Type::getX86_FP80Ty(ctx);
  llvm::Type *i80Ty = llvm::Type::getIntNTy(ctx, 80);
  llvm::Type *ptrTy = llvm::PointerType::get(ctx, 0);
  llvm::Type *doubleTy = llvm::Type::getDoubleTy(ctx);
  llvm::Type *floatTy = llvm::Type::getFloatTy(ctx);
  llvm::Type *i1Ty = llvm::Type::getInt1Ty(ctx);
  llvm::Type *i16Ty = llvm::Type::getInt16Ty(ctx);
  llvm::Type *i32Ty = llvm::Type::getInt32Ty(ctx);
  llvm::Type *i64Ty = llvm::Type::getInt64Ty(ctx);
  llvm::Type *voidTy = llvm::Type::getVoidTy(ctx);

  auto callee = [&](const char *name, llvm::Type *ret,
                    std::vector<llvm::Type *> args) {
    return mod->getOrInsertFunction(
        name, llvm::FunctionType::get(ret, args, false));
  };
  llvm::FunctionCallee toF64 = callee("zffe_f80_to_f64", doubleTy, {ptrTy});
  llvm::FunctionCallee toF32 = callee("zffe_f80_to_f32", floatTy, {ptrTy});
  llvm::FunctionCallee toI16 = callee("zffe_f80_to_i16", i16Ty, {ptrTy});
  llvm::FunctionCallee toI32 = callee("zffe_f80_to_i32", i32Ty, {ptrTy});
  llvm::FunctionCallee toI64 = callee("zffe_f80_to_i64", i64Ty, {ptrTy});
  llvm::FunctionCallee toU64 = callee("zffe_f80_to_u64", i64Ty, {ptrTy});
  llvm::FunctionCallee fromF64 =
      callee("zffe_f64_to_f80", voidTy, {doubleTy, ptrTy});
  llvm::FunctionCallee fromF32 =
      callee("zffe_f32_to_f80", voidTy, {floatTy, ptrTy});
  llvm::FunctionCallee fromI16 =
      callee("zffe_i16_to_f80", voidTy, {i16Ty, ptrTy});
  llvm::FunctionCallee fromI32 =
      callee("zffe_i32_to_f80", voidTy, {i32Ty, ptrTy});
  llvm::FunctionCallee fromI64 =
      callee("zffe_i64_to_f80", voidTy, {i64Ty, ptrTy});
  llvm::FunctionCallee fromU32 =
      callee("zffe_u32_to_f80", voidTy, {i32Ty, ptrTy});
  llvm::FunctionCallee fadd =
      callee("zffe_f80_add", doubleTy, {ptrTy, ptrTy});
  llvm::FunctionCallee fsub =
      callee("zffe_f80_sub", doubleTy, {ptrTy, ptrTy});
  llvm::FunctionCallee fmul =
      callee("zffe_f80_mul", doubleTy, {ptrTy, ptrTy});
  llvm::FunctionCallee fdiv =
      callee("zffe_f80_div", doubleTy, {ptrTy, ptrTy});
  llvm::FunctionCallee fcmp =
      callee("zffe_f80_cmp", i1Ty, {i32Ty, ptrTy, ptrTy});
  llvm::FunctionCallee classify =
      callee("zffe_f80_classify", i1Ty, {i32Ty, ptrTy});
  llvm::FunctionCallee nearbyint =
      callee("zffe_f80_nearbyint", doubleTy, {ptrTy});
  llvm::FunctionCallee trunc = callee("zffe_f80_trunc", doubleTy, {ptrTy});

  // long-double libm taking f80 args -> double libm (strip the trailing l).
  auto libmDouble = [&](const std::string &name) -> std::string {
    static const std::unordered_set<std::string> kF80Libm = {
        "sqrtl", "sinl", "cosl", "tanl", "atanl",
        "fmodl", "log2l", "exp2l", "remainderl",
    };
    if (!kF80Libm.count(name)) return "";
    return name.substr(0, name.size() - 1);
  };

  for (auto &fn : *mod) {
    if (fn.isDeclaration()) continue;
    // Entry allocas for spilled operands/results.
    auto spill = [&](const char *tag) {
      llvm::IRBuilder<> e(&fn.getEntryBlock().front());
      return e.CreateAlloca(f80Ty, nullptr, tag);
    };
    // Collect first (rewriting mutates the lists).
    std::vector<llvm::Instruction *> work;
    for (auto &bb : fn) {
      for (auto &in : bb) {
        bool want = false;
        if (auto *bo = llvm::dyn_cast<llvm::BinaryOperator>(&in)) {
          want = bo->getType() == f80Ty;
        } else if (auto *fc = llvm::dyn_cast<llvm::FCmpInst>(&in)) {
          want = fc->getOperand(0)->getType() == f80Ty;
        } else if (auto *ci = llvm::dyn_cast<llvm::CastInst>(&in)) {
          // Bitwise casts are legal everywhere; leave them.
          want = ci->getOpcode() != llvm::Instruction::BitCast &&
                 (ci->getSrcTy() == f80Ty || ci->getDestTy() == f80Ty);
        } else if (llvm::isa<llvm::UnaryOperator>(&in)) {
          want = in.getType() == f80Ty;
        } else if (auto *cb = llvm::dyn_cast<llvm::CallBase>(&in)) {
          const llvm::Function *f = cb->getCalledFunction();
          if (!f) continue;  // indirect: callee is ptr-typed; f80 args are
                             // legal, and libm/intrinsics are always direct
          std::string cn = f->getName().str();
          if (!libmDouble(cn).empty()) {
            want = true;
          } else if (startsWith(cn, "llvm.")) {
            want = cn.find(".f80") != std::string::npos;
          }
        }
        if (want) work.push_back(&in);
      }
    }

    for (auto *in : work) {
      llvm::IRBuilder<> b(in);
      auto spillOp = [&](llvm::Value *v, const char *tag) {
        auto *t = spill(tag);
        b.CreateStore(v, t);
        return t;
      };
      auto encodeF64 = [&](llvm::Value *d) {
        auto *t = spill("f80r");
        b.CreateCall(fromF64, {d, t});
        return b.CreateLoad(f80Ty, t);
      };
      if (auto *bo = llvm::dyn_cast<llvm::BinaryOperator>(in)) {
        llvm::FunctionCallee *op = nullptr;
        switch (bo->getOpcode()) {
          case llvm::Instruction::FAdd:
            op = &fadd;
            break;
          case llvm::Instruction::FSub:
            op = &fsub;
            break;
          case llvm::Instruction::FMul:
            op = &fmul;
            break;
          case llvm::Instruction::FDiv:
            op = &fdiv;
            break;
          default:
            err = "unrewritable f80 binary op in " + fn.getName().str();
            return false;
        }
        auto *tA = spillOp(bo->getOperand(0), "f80a");
        auto *tB = spillOp(bo->getOperand(1), "f80b");
        llvm::Value *d = b.CreateCall(*op, {tA, tB});
        in->replaceAllUsesWith(encodeF64(d));
        in->eraseFromParent();
      } else if (auto *fc = llvm::dyn_cast<llvm::FCmpInst>(in)) {
        auto *tA = spillOp(fc->getOperand(0), "f80a");
        auto *tB = spillOp(fc->getOperand(1), "f80b");
        auto *pred = llvm::ConstantInt::get(
            i32Ty, static_cast<uint64_t>(fc->getPredicate()));
        llvm::Value *r = b.CreateCall(fcmp, {pred, tA, tB});
        in->replaceAllUsesWith(r);
        in->eraseFromParent();
      } else if (auto *ci = llvm::dyn_cast<llvm::CastInst>(in)) {
        llvm::Value *r = nullptr;
        switch (ci->getOpcode()) {
          case llvm::Instruction::FPTrunc: {
            auto *t = spillOp(ci->getOperand(0), "f80a");
            if (ci->getDestTy() == doubleTy) {
              r = b.CreateCall(toF64, {t});
            } else if (ci->getDestTy() == floatTy) {
              r = b.CreateCall(toF32, {t});
            }
            break;
          }
          case llvm::Instruction::FPExt: {
            auto *t = spill("f80r");
            if (ci->getSrcTy() == doubleTy) {
              b.CreateCall(fromF64, {ci->getOperand(0), t});
            } else if (ci->getSrcTy() == floatTy) {
              b.CreateCall(fromF32, {ci->getOperand(0), t});
            } else {
              break;
            }
            r = b.CreateLoad(f80Ty, t);
            break;
          }
          case llvm::Instruction::SIToFP: {
            auto *t = spill("f80r");
            auto *w = ci->getSrcTy();
            if (w == i16Ty) {
              b.CreateCall(fromI16, {ci->getOperand(0), t});
            } else if (w == i32Ty) {
              b.CreateCall(fromI32, {ci->getOperand(0), t});
            } else if (w == i64Ty) {
              b.CreateCall(fromI64, {ci->getOperand(0), t});
            } else {
              break;
            }
            r = b.CreateLoad(f80Ty, t);
            break;
          }
          case llvm::Instruction::FPToSI: {
            auto *t = spillOp(ci->getOperand(0), "f80a");
            auto *w = ci->getDestTy();
            if (w == i16Ty) {
              r = b.CreateCall(toI16, {t});
            } else if (w == i32Ty) {
              r = b.CreateCall(toI32, {t});
            } else if (w == i64Ty) {
              r = b.CreateCall(toI64, {t});
            }
            break;
          }
          case llvm::Instruction::FPToUI: {
            auto *t = spillOp(ci->getOperand(0), "f80a");
            if (ci->getDestTy() == i64Ty) r = b.CreateCall(toU64, {t});
            break;
          }
          case llvm::Instruction::UIToFP: {
            auto *t = spill("f80r");
            if (ci->getSrcTy() == i32Ty) {
              b.CreateCall(fromU32, {ci->getOperand(0), t});
              r = b.CreateLoad(f80Ty, t);
            }
            break;
          }
          default:
            break;
        }
        if (!r) {
          err = "unrewritable f80 cast in " + fn.getName().str();
          return false;
        }
        in->replaceAllUsesWith(r);
        in->eraseFromParent();
      } else if (llvm::isa<llvm::UnaryOperator>(in)) {
        // FNeg only (the collector took all f80-typed unaries): sign flip
        // as integer xor, all ARM-legal.
        if (in->getOpcode() != llvm::Instruction::FNeg) {
          err = "unrewritable f80 unary in " + fn.getName().str();
          return false;
        }
        llvm::Value *i = b.CreateBitCast(in->getOperand(0), i80Ty);
        llvm::Value *n = b.CreateXor(
            i, llvm::ConstantInt::get(i80Ty, llvm::APInt(80, 1) << 79));
        llvm::Value *r = b.CreateBitCast(n, f80Ty);
        in->replaceAllUsesWith(r);
        in->eraseFromParent();
      } else if (auto *cb = llvm::dyn_cast<llvm::CallBase>(in)) {
        const llvm::Function *f = cb->getCalledFunction();
        std::string cn = f->getName().str();
        if (cn == "llvm.fabs.f80") {
          // Bitwise: clear the sign bit.
          llvm::Value *i = b.CreateBitCast(cb->getArgOperand(0), i80Ty);
          llvm::Value *m = b.CreateAnd(
              i, llvm::ConstantInt::get(
                     i80Ty, llvm::APInt::getLowBitsSet(80, 79)));
          llvm::Value *r = b.CreateBitCast(m, f80Ty);
          in->replaceAllUsesWith(r);
          in->eraseFromParent();
        } else if (cn == "llvm.is.fpclass.f80") {
          auto *t = spillOp(cb->getArgOperand(0), "f80a");
          llvm::Value *r =
              b.CreateCall(classify, {cb->getArgOperand(1), t});
          in->replaceAllUsesWith(r);
          in->eraseFromParent();
        } else if (cn == "llvm.fmuladd.f80") {
          // Split fused multiply-add into per-op rounded mul+add: that is
          // what x87 does (it has no fused op), so the split is the
          // faithful form, not just the convenient one.
          auto *tA = spillOp(cb->getArgOperand(0), "f80a");
          auto *tB = spillOp(cb->getArgOperand(1), "f80b");
          llvm::Value *dm = b.CreateCall(fmul, {tA, tB});
          llvm::Value *m = encodeF64(dm);
          auto *tM = spill("f80m");
          b.CreateStore(m, tM);
          auto *tC = spillOp(cb->getArgOperand(2), "f80c");
          llvm::Value *d = b.CreateCall(fadd, {tM, tC});
          in->replaceAllUsesWith(encodeF64(d));
          in->eraseFromParent();
        } else if (cn == "llvm.nearbyint.f80" || cn == "llvm.trunc.f80") {
          auto *t = spillOp(cb->getArgOperand(0), "f80a");
          llvm::Value *d = b.CreateCall(
              cn == "llvm.nearbyint.f80" ? nearbyint : trunc, {t});
          in->replaceAllUsesWith(encodeF64(d));
          in->eraseFromParent();
        } else if (!libmDouble(cn).empty()) {
          std::string dn = libmDouble(cn);
          std::vector<llvm::Type *> at;
          std::vector<llvm::Value *> av;
          for (unsigned i = 0; i < cb->arg_size(); i++) {
            llvm::Value *a = cb->getArgOperand(i);
            if (a->getType() == f80Ty) {
              auto *t = spillOp(a, "f80a");
              at.push_back(doubleTy);
              av.push_back(b.CreateCall(toF64, {t}));
            } else {
              at.push_back(a->getType());
              av.push_back(a);
            }
          }
          llvm::FunctionCallee df =
              callee(dn.c_str(), doubleTy, std::move(at));
          llvm::Value *d = b.CreateCall(df, av);
          if (cb->getType() == f80Ty) {
            in->replaceAllUsesWith(encodeF64(d));
          } else if (!cb->getType()->isVoidTy()) {
            err = "unexpected " + cn + " result type in " +
                  fn.getName().str();
            return false;
          }
          in->eraseFromParent();
        } else if (startsWith(cn, "llvm.")) {
          err = "unrewritable " + cn + " in " + fn.getName().str();
          return false;
        }
        // else: some other call the collector took (none by construction).
      }
    }
  }

  // Verification sweep: nothing targeted may remain.
  for (auto &fn : mod->functions()) {
    if (fn.isDeclaration()) continue;
    for (auto &bb : fn) {
      for (auto &in : bb) {
        bool bad = false;
        if (auto *bo = llvm::dyn_cast<llvm::BinaryOperator>(&in)) {
          bad = bo->getType() == f80Ty;
        } else if (auto *fc = llvm::dyn_cast<llvm::FCmpInst>(&in)) {
          bad = fc->getOperand(0)->getType() == f80Ty;
        } else if (auto *ci = llvm::dyn_cast<llvm::CastInst>(&in)) {
          auto op = ci->getOpcode();
          bad = (op == llvm::Instruction::FPTrunc ||
                 op == llvm::Instruction::FPExt ||
                 op == llvm::Instruction::SIToFP ||
                 op == llvm::Instruction::UIToFP ||
                 op == llvm::Instruction::FPToSI ||
                 op == llvm::Instruction::FPToUI) &&
                (ci->getSrcTy() == f80Ty || ci->getDestTy() == f80Ty);
        } else if (llvm::isa<llvm::UnaryOperator>(&in)) {
          bad = in.getType() == f80Ty;
        } else if (auto *cb = llvm::dyn_cast<llvm::CallBase>(&in)) {
          if (const llvm::Function *f = cb->getCalledFunction()) {
            std::string cn = f->getName().str();
            if (!libmDouble(cn).empty()) {
              for (unsigned i = 0; i < cb->arg_size(); i++) {
                bad = bad || cb->getArgOperand(i)->getType() == f80Ty;
              }
            } else if (startsWith(cn, "llvm.")) {
              bad = cn.find(".f80") != std::string::npos;
            }
          }
        }
        if (bad) {
          err = "f80 rewrite missed an op in " + fn.getName().str();
          return false;
        }
      }
    }
  }
  return true;
}

// The miss module starts as a full clone of the retained base copy, so
// the lifter sees real ISEL bodies (see lift_clone) and behaves exactly
// as the base lift did. Before compiling, every body except the newly
// lifted traces is dropped, leaving decls that link to the base module.
bool liftOnDemand(zffe_jit *jit, uint32_t pc) {
  auto *priv = static_cast<ZffePriv *>(jit->img->priv);
  if (!priv) return false;

  llvm::orc::ThreadSafeContext ctx = jit->tsctx;
  std::unique_ptr<llvm::Module> mod;
  ctx.withContextDo([&](llvm::LLVMContext *llvm_ctx) {
    (void)llvm_ctx;  // CloneModule keeps the source's context, as required
    char buf[32];
    snprintf(buf, sizeof(buf), "zffe-miss-%x", pc);
    mod = llvm::CloneModule(*jit->lift_clone);
    mod->setModuleIdentifier(buf);
  });
  mod->setTargetTriple(jit->lljit->getTargetTriple());
  mod->setDataLayout(jit->lljit->getDataLayout());

  // Strip the base traces' bodies (decls remain for cross-references);
  // without this they would be duplicate definitions at link time.
  for (uint64_t addr : priv->tm->base_addrs) {
    if (auto *fn = mod->getFunction(priv->tm->TraceName(addr))) {
      if (!fn->isDeclaration()) fn->deleteBody();
    }
  }
  // A spare arch per miss module: Arch init is one-shot and binds the
  // intrinsic table (hence the lifter's output module) to one module.
  auto spare = remill::Arch::Get(mod->getContext(), jit->os, jit->arch);
  if (!spare) {
    fprintf(stderr, "zffe: spare arch %s/%s unavailable\n", jit->os.c_str(),
            jit->arch.c_str());
    return false;
  }
  spare->InitFromSemanticsModule(mod.get());

  priv->tm->on_demand = true;
  priv->tm->cur_mod = mod.get();
  priv->tm->cur_defined.clear();
  MissGuard guard{priv->tm.get()};
  void *fn = zffe_lift_into(jit->img, spare.get(), pc);
  if (!fn) {
    fprintf(stderr, "zffe: miss lift failed for 0x%x: %s\n", pc,
            jit->img->error ? jit->img->error : "?");
    return false;
  }
  // Drop every body except the traces this miss lifted (head + siblings);
  // the rest link to the base definitions by name.
  std::unordered_set<llvm::Function *> keep;
  for (auto &kv : priv->tm->cur_defined) keep.insert(kv.second);
  for (auto &f : *mod) {
    if (!f.isDeclaration() && !keep.count(&f)) f.deleteBody();
  }
  // ISEL lookup globals are lift-time only; the trace calls the functions
  // directly. Other dead globals stay (harmless unreferenced data).
  {
    std::vector<llvm::GlobalVariable *> dead;
    for (auto &g : mod->globals()) {
      if (startsWith(g.getName().str(), "ISEL_") && g.use_empty())
        dead.push_back(&g);
    }
    for (auto *g : dead) g->eraseFromParent();
  }
  if (auto *st = mod->getGlobalVariable("__remill_state")) {
    if (st->use_empty()) st->eraseFromParent();
  }
  if (hostNeedsF80()) {
    std::string rerr;
    if (!rewriteF80(mod.get(), rerr)) {
      fprintf(stderr, "zffe: miss f80 rewrite failed for 0x%x: %s\n", pc,
              rerr.c_str());
      return false;
    }
  }

  std::string vmsg;
  llvm::raw_string_ostream vos(vmsg);
  if (llvm::verifyModule(*mod, &vos)) {
    fprintf(stderr, "zffe: miss module verify failed for 0x%x: %s\n", pc,
            vmsg.c_str());
    return false;
  }
  if (auto jerr = jit->lljit->addIRModule(
          llvm::orc::ThreadSafeModule(std::move(mod), std::move(ctx)))) {
    fprintf(stderr, "zffe: miss module add failed for 0x%x: %s\n", pc,
            llvm::toString(std::move(jerr)).c_str());
    return false;
  }
  return true;
}

}  // namespace

extern "C" {

// Resolve-or-die for indirect control flow. Called from lifted code
// (`__remill_function_call`, inlined through runtime.cpp) and from the
// tail-jump stub (jump_stub.S). Never returns null.
void *zffe_dispatch_target(uint32_t pc) {
  zffe_jit *jit = g_jit;
  if (!jit) {
    fprintf(stderr, "zffe: dispatch with no JIT\n");
    abort();
  }
  auto cached = jit->cache.find(pc);
  if (cached != jit->cache.end()) return cached->second;

  // An indirect jump/call to an import sentinel goes straight to the host
  // trampoline; sentinels are never lifted.
  for (size_t i = 0; i < jit->img->nimports; i++) {
    if (jit->img->imports[i].addr == pc) {
      const void *fn = zffe_tramp_resolve(jit->img->imports[i].name);
      if (!fn) {
        fprintf(stderr, "zffe: import %s has no trampoline\n",
                jit->img->imports[i].name);
        abort();
      }
      jit->cache[pc] = (void *)fn;
      return (void *)fn;
    }
  }

  std::string name = traceNameFor(jit, pc);
  if (auto sym = jit->lljit->lookup(name)) {
    void *addr = sym->toPtr<void *>();
    jit->cache[pc] = addr;
    return addr;
  } else {
    llvm::consumeError(sym.takeError());
  }
  if (!liftOnDemand(jit, pc)) noTrace(jit, pc);
  auto sym2 = jit->lljit->lookup(name);
  if (!sym2) {
    llvm::consumeError(sym2.takeError());
    noTrace(jit, pc);
  }
  void *addr = sym2->toPtr<void *>();
  jit->cache[pc] = addr;
  return addr;
}

zffe_jit_t *zffe_jit_create(zffe_image_t *img) {
  if (!img) return nullptr;
  zffe_set_error(img, nullptr);
  // Lifting never needs codegen, so this is the first place that does.
  static bool targets_init = false;
  if (!targets_init) {
    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmPrinter();
    targets_init = true;
  }
  if (g_jit) {
    zffe_set_error(img, "a JIT already exists (one per process)");
    return nullptr;
  }
  auto *priv = static_cast<ZffePriv *>(img->priv);
  if (!priv || !priv->mod) {
    zffe_set_error(img, "image has no lift session (already jitted?)");
    return nullptr;
  }
  llvm::Module *mod = priv->mod.get();

  // Neutralize the semantics keeper: __remill_intrinsics address-takes
  // every helper of every arch, which would force the JIT to resolve
  // sparc/aarch64/ppc helpers the x86 guest can never call. Drop the body
  // plus the llvm.used roots (pure compile-time artifacts; nothing reads
  // them at runtime). As an unreferenced declaration the keeper links to
  // nothing and costs nothing.
  // Iterate-and-match: getGlobalVariable (even AllowInternal) misses
  // these roots, but iteration finds them.
  for (auto it = mod->global_begin(); it != mod->global_end();) {
    auto *g = &*it++;
    std::string name = g->getName().str();
    if (name == "llvm.compiler.used" || name == "llvm.used") {
      g->eraseFromParent();
    }
  }
  if (auto *keeper = mod->getFunction("__remill_intrinsics")) {
    if (!keeper->isDeclaration()) {
      keeper->deleteBody();
      keeper->setLinkage(llvm::GlobalValue::ExternalLinkage);
    }
  }

  // Replace Remill's host-passthrough hypercall (x86 inline asm: CPUID,
  // RDTSC, ...) with the portable Pentium-faithful one from runtime.cpp,
  // on all hosts. As a declaration it resolves to the host definition.
  if (auto *hyper = mod->getFunction("__remill_sync_hyper_call")) {
    if (!hyper->isDeclaration()) {
      hyper->deleteBody();
      hyper->setLinkage(llvm::GlobalValue::ExternalLinkage);
    }
  }

  // Non-x86 hosts can't lower x86_fp80 arithmetic: remap it to host
  // doubles before anything else inspects or compiles the module.
  if (hostNeedsF80()) {
    std::string rerr;
    if (!rewriteF80(mod, rerr)) {
      zffe_set_error(img, rerr.c_str());
      return nullptr;
    }
  }

  // Every REFERENCED external must be explainable: host-provided, a
  // resolved import, or libm. Anything else fails here with a name, not
  // pages deep in an ORC link error.
  auto hosts = hostSymbols();
  std::unordered_set<std::string> host_names;
  for (auto &kv : hosts) host_names.insert(kv.first);
  std::vector<std::pair<std::string, const void *>> imports;
  for (auto &fn : *mod) {
    if (!fn.isDeclaration()) continue;
    std::string name = fn.getName().str();
    if (startsWith(name, "llvm.")) continue;
    // Our own neutralized keeper: its only use is the orphaned (uniqued,
    // immortal, unreachable) compiler.used initializer, which is never
    // emitted. Skip by name; use_empty() can't see through the orphan.
    if (name == "__remill_intrinsics") continue;
    if (fn.use_empty()) continue;
    if (host_names.count(name)) continue;
    if (startsWith(name, "import_")) {
      const void *tramp = zffe_tramp_resolve(name.c_str() + 7);
      if (!tramp) {
        std::string msg =
            "import " + name.substr(7) + " has no trampoline (C_* hook?)";
        zffe_set_error(img, msg.c_str());
        return nullptr;
      }
      imports.push_back({name, tramp});
      continue;
    }
    if (isLibmName(name)) continue;
    if (startsWith(name, "sub_")) {
      unsigned long long addr = 0;
      if (sscanf(name.c_str() + 4, "%llx", &addr) == 1) {
        char buf[128];
        snprintf(buf, sizeof(buf),
                 "undefined trace %s (guest 0x%llx): no map func covers an "
                 "address reached by lifted code",
                 name.c_str(), addr);
        zffe_set_error(img, buf);
      } else {
        std::string msg = "undefined trace " + name;
        zffe_set_error(img, msg.c_str());
      }
      return nullptr;
    }
    std::string msg =
        "lifted code references " + name + " with no host definition";
    zffe_set_error(img, msg.c_str());
    return nullptr;
  }
  for (auto &g : mod->globals()) {
    if (!g.isDeclaration()) continue;
    if (g.use_empty()) continue;
    std::string msg =
        "lifted code references global " + g.getName().str();
    zffe_set_error(img, msg.c_str());
    return nullptr;
  }
  // A host name that the module ALSO defines would be a duplicate
  // definition at link time; that means the model above broke.
  for (auto &kv : hosts) {
    auto *fn = mod->getFunction(kv.first);
    if (fn && !fn->isDeclaration()) {
      std::string msg = "host symbol " + kv.first +
                        " is also defined in the module (runtime model break)";
      zffe_set_error(img, msg.c_str());
      return nullptr;
    }
  }

  auto jit = std::make_unique<zffe_jit>();
  jit->img = img;
  jit->os = priv->os_name;
  jit->arch = priv->arch_name;
  // NOTE: priv->ctx/mod move into the JIT together at the very end. Every
  // failure before that leaves the image intact (still liftable); only an
  // addIRModule failure kills it (both nulled, consistently dead).
  for (size_t i = 0; i < img->nfuncs; i++) {
    if (img->funcs[i].kind == ZFFE_SYM_FUNC) {
      jit->names[img->funcs[i].addr] = img->funcs[i].name;
    }
  }
  std::string promo_err;
  if (!promoteISELSymbols(mod, promo_err)) {
    zffe_set_error(img, promo_err.c_str());
    return nullptr;
  }
  // Retained before the point of no return moves `mod` into ORC: each
  // miss module starts as a clone of this (see lift_clone).
  jit->lift_clone = llvm::CloneModule(*mod);

  auto built = llvm::orc::LLJITBuilder().create();
  if (!built) {
    zffe_set_error(img, llvm::toString(built.takeError()).c_str());
    return nullptr;
  }
  jit->lljit = std::move(*built);

  auto gen = llvm::orc::DynamicLibrarySearchGenerator::GetForCurrentProcess(
      jit->lljit->getDataLayout().getGlobalPrefix());
  if (!gen) {
    zffe_set_error(img, llvm::toString(gen.takeError()).c_str());
    return nullptr;
  }
  jit->lljit->getMainJITDylib().addGenerator(std::move(*gen));

  {
    llvm::orc::MangleAndInterner mangle(jit->lljit->getExecutionSession(),
                                       jit->lljit->getDataLayout());
    llvm::orc::SymbolMap map;
    auto add = [&](const std::string &name, const void *addr) {
      map[mangle(name)] = llvm::orc::ExecutorSymbolDef(
          llvm::orc::ExecutorAddr::fromPtr(addr),
          llvm::JITSymbolFlags::Exported);
    };
    for (auto &kv : hosts) add(kv.first, kv.second);
    for (auto &kv : imports) add(kv.first, kv.second);
    if (auto err = jit->lljit->getMainJITDylib().define(
            llvm::orc::absoluteSymbols(std::move(map)))) {
      zffe_set_error(img, llvm::toString(std::move(err)).c_str());
      return nullptr;
    }
  }

  // Probe libm eagerly: without it the first x87 transcendental would die
  // in a link error instead of here with a clear message.
  for (const char *libm :
       {"sqrt", "sqrtf", "sqrtl", "sinl", "cosl", "tanl", "atanl", "fmodl",
        "log2l", "exp2l", "remainderl", "sin", "cos", "tan", "atan", "fmod",
        "log2", "exp2", "remainder"}) {
    if (auto sym = jit->lljit->lookup(libm)) {
      (void)sym;
    } else {
      llvm::consumeError(sym.takeError());
      std::string msg =
          std::string("libm symbol ") + libm +
          " is not visible to the JIT (host must link libm)";
      zffe_set_error(img, msg.c_str());
      return nullptr;
    }
  }

  // Validate the miss pipeline now, not mid-game: a cloned module with
  // stripped traces must accept spare arch init (any gap would FATAL
  // inside Remill). Raw context: nothing is shared yet, same as the lift
  // phase.
  {
    auto probe = llvm::CloneModule(*jit->lift_clone);
    probe->setTargetTriple(jit->lljit->getTargetTriple());
    probe->setDataLayout(jit->lljit->getDataLayout());
    for (uint64_t addr : priv->tm->base_addrs) {
      if (auto *fn = probe->getFunction(priv->tm->TraceName(addr))) {
        if (!fn->isDeclaration()) fn->deleteBody();
      }
    }
    auto spare = remill::Arch::Get(probe->getContext(), jit->os, jit->arch);
    if (!spare) {
      zffe_set_error(img, "spare arch unavailable");
      return nullptr;
    }
    spare->InitFromSemanticsModule(probe.get());
  }

  mod->setTargetTriple(jit->lljit->getTargetTriple());
  mod->setDataLayout(jit->lljit->getDataLayout());
  // The point of no return: context and module move together.
  jit->tsctx = llvm::orc::ThreadSafeContext(std::move(priv->ctx));
  img->llvm_mod = nullptr;
  img->llvm_ctx = nullptr;
  if (auto err = jit->lljit->addIRModule(
          llvm::orc::ThreadSafeModule(std::move(priv->mod), jit->tsctx))) {
    zffe_set_error(img, llvm::toString(std::move(err)).c_str());
    return nullptr;  // module consumed: the image is unusable past this
  }

  g_jit = jit.get();
  return reinterpret_cast<zffe_jit_t *>(jit.release());
}

void *zffe_jit_lookup(zffe_jit_t *jit_, zffe_image_t *img, const char *name) {
  auto *jit = reinterpret_cast<zffe_jit *>(jit_);
  if (!jit || !img || !name) return nullptr;
  zffe_set_error(img, nullptr);
  if (auto sym = jit->lljit->lookup(name)) {
    return sym->toPtr<void *>();
  } else {
    std::string msg = std::string("jit lookup failed for '") + name +
                      "': " + llvm::toString(sym.takeError());
    zffe_set_error(img, msg.c_str());
    return nullptr;
  }
}

void zffe_jit_free(zffe_jit_t *jit_) {
  auto *jit = reinterpret_cast<zffe_jit *>(jit_);
  if (!jit) return;
  if (g_jit == jit) g_jit = nullptr;
  delete jit;
}

}  // extern "C"
