// zffe Remill shim, private C++ shared between shim.cpp and jit.cpp.
// NOT part of the C ABI (shim.h). The trace manager and lift session live
// here so the JIT's on-demand path (missed indirect targets) can lift
// traces into fresh modules with the same Arch/TraceManager.

#pragma once

#include "shim.h"

#include <remill/Arch/Arch.h>
#include <remill/BC/TraceLifter.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Module.h>

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>

// Set img->error (strdup'd; clears on nullptr). Defined in shim.cpp.
void zffe_set_error(zffe_image_t *img, const char *msg);

// Lift the trace at `addr` with `arch` (base arch for the base module,
// a spare arch bound to the miss module for on-demand lifts). The trace
// manager routes definitions by its on_demand flag. Returns the
// llvm::Function*, or NULL with img->error set. Defined in shim.cpp.
void *zffe_lift_into(zffe_image_t *img, const remill::Arch *arch,
                     uint64_t addr);

// TraceManager over our flat image. Trace naming prefers map symbol names so
// pre-declared functions get their bodies filled in by the lifter (see
// TraceLifter::Impl::get_trace_decl, which reuses module->getFunction(name)).
class ZffeTraceManager : public remill::TraceManager {
 public:
  zffe_image_t *img = nullptr;
  const remill::Arch *arch = nullptr;
  uint64_t cur_entry = 0;
  std::unordered_map<uint64_t, llvm::Function *> defined;

  // On-demand mode (miss modules): never hand out cross-module pointers.
  // `cur_defined` holds traces defined in the current miss module;
  // `base_addrs` holds every addr defined in the base module (filled by
  // SetLiftedTraceDefinition during the base lifts).
  bool on_demand = false;
  llvm::Module *cur_mod = nullptr;
  std::unordered_map<uint64_t, llvm::Function *> cur_defined;
  std::unordered_set<uint64_t> base_addrs;
  // Base-lift direct-edge targets seen but not yet lifted (imports excluded:
  // they resolve to host trampolines). Drained by zffe_lift_closure.
  std::unordered_set<uint64_t> wanted;

  // Memoized addr -> index into img->funcs / img->imports. Name lookup is
  // on hot paths (every direct edge during a lift, every base trace per
  // miss strip). CONTRACT: entries are addressed by position, so positions
  // must be stable. The arrays are written once at load and must never be
  // inserted into, removed from, or reordered -- tail appends are fine
  // (the watermarks pick them up) and realloc is fine (indices survive
  // it; cached pointers would not). Any future mid-array mutation must
  // clear these maps first. Indices (not name copies) keep one owner for
  // the strings and serve record lookup too (see findFunc).
  std::unordered_map<uint64_t, size_t> func_index;
  std::unordered_map<uint64_t, size_t> import_index;
  size_t funcs_synced = 0;
  size_t imports_synced = 0;
  const zffe_image_t *synced_img = nullptr;

  void syncNameCache() {
    if (synced_img != img) {
      func_index.clear();
      import_index.clear();
      func_index.reserve(img->nfuncs);
      import_index.reserve(img->nimports);
      funcs_synced = 0;
      imports_synced = 0;
      synced_img = img;
    }
    for (; funcs_synced < img->nfuncs; funcs_synced++)
      func_index.emplace(img->funcs[funcs_synced].addr, funcs_synced);
    for (; imports_synced < img->nimports; imports_synced++)
      import_index.emplace(img->imports[imports_synced].addr, imports_synced);
  }

  // Record for addr, or null. First match wins, matching the old scan.
  zffe_func_t *findFunc(uint64_t addr) {
    syncNameCache();
    auto it = func_index.find(addr);
    if (it == func_index.end()) return nullptr;
    return &img->funcs[it->second];
  }

  // Guest address width normalization. The lifter computes branch targets
  // in u64 without wrapping, so a 32-bit guest's direct calls into high
  // memory (e.g. import sentinels at 0xFF000000+) arrive here with all high
  // bits set. Truncate to the architecture's address width so matching,
  // naming, and map keys all see the address the guest means.
  uint64_t guestAddr(uint64_t addr) const {
    if (arch && arch->address_size < 64)
      addr &= (1ULL << arch->address_size) - 1;
    return addr;
  }

  std::string TraceName(uint64_t addr) override {
    addr = guestAddr(addr);
    syncNameCache();
    auto fi = func_index.find(addr);
    if (fi != func_index.end()) return img->funcs[fi->second].name;
    // Import sentinels lift as calls to `import_<sym>` declarations, which
    // the engine implements natively (trampolines).
    auto ii = import_index.find(addr);
    if (ii != import_index.end())
      return std::string("import_") + img->imports[ii->second].name;
    return remill::TraceManager::TraceName(addr);
  }

  void SetLiftedTraceDefinition(uint64_t addr,
                                llvm::Function *lifted_func) override {
    addr = guestAddr(addr);
    if (on_demand) {
      cur_defined[addr] = lifted_func;
    } else {
      defined[addr] = lifted_func;
      base_addrs.insert(addr);
    }
  }

  llvm::Function *GetLiftedTraceDefinition(uint64_t addr) override {
    addr = guestAddr(addr);
    if (!on_demand) {
      auto it = defined.find(addr);
      if (it != defined.end()) return it->second;
      if (addr == cur_entry) return nullptr;  // force this one to be lifted
      // Anything else: hand back (or create) a declaration so the lifter emits
      // a call instead of recursing. Mirrors remill's SimpleTraceManager.
      // Recorded for the lift closure: direct calls are direct machine calls
      // with no runtime dispatch, so every callee needs a body pre-link.
      if (!isImportAddr(addr)) wanted.insert(addr);
      auto *mod = static_cast<llvm::Module *>(img->llvm_mod);
      std::string name = TraceName(addr);
      if (auto *fn = mod->getFunction(name)) return fn;
      return arch->DeclareLiftedFunction(name, mod);
    }
    // Miss module: same-module pointers only, so the JIT can link the
    // miss module against the base module by name.
    {
      auto it = cur_defined.find(addr);
      if (it != cur_defined.end()) return it->second;
    }
    if (addr == cur_entry) return nullptr;  // force the head to be lifted
    if (base_addrs.count(addr) || isImportAddr(addr)) {
      // Defined in the base module (or a host trampoline): declare locally
      // and skip the lift; the declaration resolves cross-module at JIT
      // link time.
      std::string name = TraceName(addr);
      if (auto *fn = cur_mod->getFunction(name)) return fn;
      return arch->DeclareLiftedFunction(name, cur_mod);
    }
    return nullptr;  // genuinely new code: lift as a sibling into cur_mod
  }

  // Defined in shim.cpp (needs the flat image helpers there).
  bool TryReadExecutableByte(uint64_t addr, uint8_t *byte) override;

 private:
  bool isImportAddr(uint64_t addr) {
    syncNameCache();
    return import_index.count(addr) != 0;
  }
};

struct ZffePriv {
  std::unique_ptr<llvm::LLVMContext> ctx;
  std::unique_ptr<llvm::Module> mod;
  remill::Arch::ArchPtr arch;
  std::unique_ptr<ZffeTraceManager> tm;
  // os/arch selectors, kept so the JIT can mint spare archs for miss
  // modules (Arch init is one-shot; each miss module needs its own).
  std::string os_name;
  std::string arch_name;
};
