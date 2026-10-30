// zffe Remill shim. See shim.h for the ABI contract.
//
// Remill API usage mirrors bin/lift/Lift.cpp from lifting-bits/remill
// (verified against upstream HEAD 56918a8c): Arch::Get, LoadArchSemantics,
// a TraceManager reading bytes from our flat image, TraceLifter::Lift.

#include "shim.h"

#include "shim_priv.h"

#include <cctype>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

// ABI contract with src/bridge.zig (LP64). Update both sides together.
static_assert(sizeof(void *) == 8, "LP64 only");
static_assert(offsetof(zffe_func_t, addr) == 8, "abi");
static_assert(offsetof(zffe_func_t, size) == 16, "abi");
static_assert(offsetof(zffe_func_t, llvm_func) == 24, "abi");
static_assert(offsetof(zffe_func_t, kind) == 32, "abi");
static_assert(offsetof(zffe_func_t, decode_ok) == 36, "abi");
static_assert(offsetof(zffe_func_t, lifted) == 40, "abi");
static_assert(sizeof(zffe_func_t) == 48, "abi");
static_assert(offsetof(zffe_image_t, llvm_mod) == 8, "abi");
static_assert(offsetof(zffe_import_t, addr) == 8, "abi");
static_assert(sizeof(zffe_import_t) == 16, "abi");
static_assert(offsetof(zffe_image_t, funcs) == 16, "abi");
static_assert(offsetof(zffe_image_t, nfuncs) == 24, "abi");
static_assert(offsetof(zffe_image_t, imports) == 32, "abi");
static_assert(offsetof(zffe_image_t, nimports) == 40, "abi");
static_assert(offsetof(zffe_image_t, image) == 48, "abi");
static_assert(offsetof(zffe_image_t, image_size) == 56, "abi");
static_assert(offsetof(zffe_image_t, base) == 64, "abi");
static_assert(offsetof(zffe_image_t, entry) == 72, "abi");
static_assert(offsetof(zffe_image_t, code_start) == 80, "abi");
static_assert(offsetof(zffe_image_t, code_end) == 88, "abi");
static_assert(offsetof(zffe_image_t, mem_end) == 96, "abi");
static_assert(offsetof(zffe_image_t, priv) == 104, "abi");
static_assert(offsetof(zffe_image_t, error) == 112, "abi");
static_assert(sizeof(zffe_image_t) == 120, "abi");

#include <remill/Arch/Arch.h>
#include <remill/Arch/Instruction.h>
#include <remill/BC/TraceLifter.h>
#include <remill/BC/Util.h>
#include <llvm/IR/Function.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Module.h>

// Shared with jit.cpp (declared in shim_priv.h).
void zffe_set_error(zffe_image_t *img, const char *msg) {
  free(img->error);
  img->error = msg ? strdup(msg) : nullptr;
  if (msg && !img->error) {
    img->error = strdup("out of memory");
  }
}

namespace {

bool read_file(const char *path, std::vector<uint8_t> &out, std::string &err) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    err = std::string("cannot open ") + path;
    return false;
  }
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (size < 0) {
    err = std::string("cannot stat ") + path;
    fclose(f);
    return false;
  }
  out.resize((size_t)size);
  if (size > 0 && fread(out.data(), 1, (size_t)size, f) != (size_t)size) {
    err = std::string("short read on ") + path;
    fclose(f);
    return false;
  }
  fclose(f);
  return true;
}

uint64_t parse_hex(const char *s, bool &ok) {
  ok = false;
  if (!s) return 0;
  while (isspace((unsigned char)*s)) s++;
  if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
  if (!isxdigit((unsigned char)*s)) return 0;
  uint64_t v = 0;
  while (isxdigit((unsigned char)*s)) {
    char c = *s++;
    v = v * 16 + (uint64_t)(isdigit((unsigned char)c) ? c - '0'
                                                       : tolower(c) - 'a' + 10);
  }
  ok = true;
  return v;
}

// Dense image: every address in [base, mem_end) has a byte at addr - base.
// `want_exec` restricts to the code range (for TryReadExecutableByte).
int64_t image_offset(const zffe_image_t *img, uint64_t addr, bool want_exec,
                     uint64_t *contig = nullptr) {
  if (addr < img->base || addr >= img->mem_end) return -1;
  if (want_exec && (addr < img->code_start || addr >= img->code_end))
    return -1;
  if (contig) *contig = img->mem_end - addr;
  return (int64_t)(addr - img->base);
}

}  // namespace

// TryReadExecutableByte needs image_offset (above), so it lives here rather
// than in the shared header with the rest of the manager.
bool ZffeTraceManager::TryReadExecutableByte(uint64_t addr, uint8_t *byte) {
  int64_t off = image_offset(img, addr, /*want_exec=*/true);
  if (off < 0) return false;
  if (byte) *byte = img->image[off];
  return true;
}

extern "C" {

const char *zffe_version(void) {
  return "remill 56918a8c+";
}

zffe_image_t *zffe_load(const char *bin_path, const char *map_path,
                        const char *os, const char *arch_name) {
  zffe_image_t *img =
      (zffe_image_t *)calloc(1, sizeof(zffe_image_t));
  if (!img) return nullptr;
  if (!bin_path) bin_path = "";
  if (!map_path) map_path = "";

  std::vector<uint8_t> bin;
  std::string err;
  if (!read_file(bin_path, bin, err)) {
    zffe_set_error(img, err.c_str());
    return img;
  }
  std::vector<uint8_t> map_bytes;
  if (!read_file(map_path, map_bytes, err)) {
    zffe_set_error(img, err.c_str());
    return img;
  }
  map_bytes.push_back(0);

  std::vector<zffe_func_t> funcs;
  std::vector<std::string> names;  // parallel to funcs; owns name storage
  std::vector<zffe_import_t> imports;
  std::vector<std::string> import_names;  // parallel to imports
  bool have_base = false, have_entry = false;
  bool have_code = false, have_mem_end = false;

  char *save = nullptr;
  for (char *line = strtok_r((char *)map_bytes.data(), "\n", &save); line;
       line = strtok_r(nullptr, "\n", &save)) {
    while (isspace((unsigned char)*line)) line++;
    if (!*line || *line == '#') continue;
    // Strip comments and CR.
    if (char *hash = strchr(line, '#')) *hash = 0;
    size_t len = strlen(line);
    while (len && (line[len - 1] == '\r' || isspace((unsigned char)line[len - 1])))
      line[--len] = 0;
    if (!*line) continue;

    char *tok_save = nullptr;
    char *kind = strtok_r(line, " \t", &tok_save);
    if (!kind) continue;
    if (!strcmp(kind, "base")) {
      bool ok = false;
      img->base = parse_hex(strtok_r(nullptr, " \t", &tok_save), ok);
      if (!ok) {
        zffe_set_error(img, "bad base line in map");
        return img;
      }
      have_base = true;
    } else if (!strcmp(kind, "entry")) {
      bool ok = false;
      img->entry = parse_hex(strtok_r(nullptr, " \t", &tok_save), ok);
      if (!ok) {
        zffe_set_error(img, "bad entry line in map");
        return img;
      }
      have_entry = true;
    } else if (!strcmp(kind, "code")) {
      bool ok_s = false, ok_e = false;
      char *s_s = strtok_r(nullptr, " \t", &tok_save);
      char *s_e = strtok_r(nullptr, " \t", &tok_save);
      if (s_s) img->code_start = parse_hex(s_s, ok_s);
      if (s_e) img->code_end = parse_hex(s_e, ok_e);
      if (!ok_s || !ok_e) {
        zffe_set_error(img, "bad code line in map");
        return img;
      }
      have_code = true;
    } else if (!strcmp(kind, "mem_end")) {
      bool ok = false;
      img->mem_end = parse_hex(strtok_r(nullptr, " \t", &tok_save), ok);
      if (!ok) {
        zffe_set_error(img, "bad mem_end line in map");
        return img;
      }
      have_mem_end = true;
    } else if (!strcmp(kind, "sym")) {
      char *name = strtok_r(nullptr, " \t", &tok_save);
      char *addr_s = strtok_r(nullptr, " \t", &tok_save);
      char *size_s = strtok_r(nullptr, " \t", &tok_save);
      char *kind_s = strtok_r(nullptr, " \t", &tok_save);
      if (!name || !addr_s || !size_s || !kind_s) {
        zffe_set_error(img, "bad sym line in map");
        return img;
      }
      bool ok_a = false, ok_s = false;
      uint64_t addr = parse_hex(addr_s, ok_a);
      uint64_t size = parse_hex(size_s, ok_s);
      if (!ok_a || !ok_s) {
        zffe_set_error(img, "bad sym line in map");
        return img;
      }
      zffe_func_t f;
      memset(&f, 0, sizeof(f));
      f.addr = addr;
      f.size = size;
      f.decode_ok = -1;
      f.kind = !strcmp(kind_s, "func")
                   ? ZFFE_SYM_FUNC
                   : (!strcmp(kind_s, "data") ? ZFFE_SYM_DATA
                                              : ZFFE_SYM_UNKNOWN);
      names.emplace_back(name);
      funcs.push_back(f);
    } else if (!strcmp(kind, "import")) {
      char *name = strtok_r(nullptr, " \t", &tok_save);
      char *addr_s = strtok_r(nullptr, " \t", &tok_save);
      if (!name || !addr_s) {
        zffe_set_error(img, "bad import line in map (want: import <name> <addr>)");
        return img;
      }
      bool ok = false;
      uint64_t addr = parse_hex(addr_s, ok);
      if (!ok) {
        zffe_set_error(img, "bad import line in map (want: import <name> <addr>)");
        return img;
      }
      zffe_import_t im;
      memset(&im, 0, sizeof(im));
      im.addr = addr;
      import_names.emplace_back(name);
      imports.push_back(im);
    } else {
      std::string msg = std::string("unknown map line kind: ") + kind;
      zffe_set_error(img, msg.c_str());
      return img;
    }
  }

  if (!have_base || !have_entry || !have_code || !have_mem_end) {
    zffe_set_error(img, "map missing base/entry/code/mem_end");
    return img;
  }
  if (img->mem_end <= img->base) {
    zffe_set_error(img, "bad memory span in map");
    return img;
  }
  if (img->code_end <= img->code_start || img->code_start < img->base ||
      img->code_end > img->mem_end) {
    zffe_set_error(img, "bad code range in map");
    return img;
  }
  size_t span = (size_t)(img->mem_end - img->base);
  if (bin.size() > span) {
    zffe_set_error(img, "bin larger than map memory span");
    return img;
  }
  img->image = (uint8_t *)calloc(span ? span : 1, 1);
  if (!img->image) {
    zffe_set_error(img, "out of memory");
    return img;
  }
  memcpy(img->image, bin.data(), bin.size());
  img->image_size = span;

  img->nfuncs = funcs.size();
  img->funcs =
      (zffe_func_t *)calloc(img->nfuncs ? img->nfuncs : 1, sizeof(zffe_func_t));
  if (!img->funcs) {
    zffe_set_error(img, "out of memory");
    return img;
  }
  memcpy(img->funcs, funcs.data(), img->nfuncs * sizeof(zffe_func_t));
  for (size_t i = 0; i < img->nfuncs; i++) {
    img->funcs[i].name = strdup(names[i].c_str());
    if (!img->funcs[i].name) {
      zffe_set_error(img, "out of memory");
      return img;
    }
  }

  img->nimports = imports.size();
  img->imports = (zffe_import_t *)calloc(img->nimports ? img->nimports : 1,
                                         sizeof(zffe_import_t));
  if (!img->imports) {
    zffe_set_error(img, "out of memory");
    return img;
  }
  memcpy(img->imports, imports.data(),
         img->nimports * sizeof(zffe_import_t));
  for (size_t i = 0; i < img->nimports; i++) {
    img->imports[i].name = strdup(import_names[i].c_str());
    if (!img->imports[i].name) {
      zffe_set_error(img, "out of memory");
      return img;
    }
  }

  const char *os_s = (os && *os) ? os : "windows";
  const char *arch_s = (arch_name && *arch_name) ? arch_name : "x86";
  auto priv = std::make_unique<ZffePriv>();
  priv->os_name = os_s;
  priv->arch_name = arch_s;
  priv->ctx = std::make_unique<llvm::LLVMContext>();
  priv->arch = remill::Arch::Get(*priv->ctx, os_s, arch_s);
  if (!priv->arch) {
    zffe_set_error(img, "remill::Arch::Get failed (bad os/arch?)");
    return img;
  }
  priv->mod = remill::LoadArchSemantics(priv->arch.get());
  if (!priv->mod) {
    zffe_set_error(img, "remill::LoadArchSemantics failed");
    return img;
  }
  // Drop Remill's identity-mapping memory intrinsics so our translating
  // definitions (guest_mem.cpp) win at link time. If lifting ever needs
  // the originals present, move this strip to just before emit/JIT.
  {
    static const char *kMemIntrinsics[] = {
        "__remill_read_memory_8", "__remill_read_memory_16",
        "__remill_read_memory_32", "__remill_read_memory_64",
        "__remill_write_memory_8", "__remill_write_memory_16",
        "__remill_write_memory_32", "__remill_write_memory_64",
        "__remill_read_memory_f32", "__remill_read_memory_f64",
        "__remill_read_memory_f80", "__remill_read_memory_f128",
        "__remill_write_memory_f32", "__remill_write_memory_f64",
        "__remill_write_memory_f80", "__remill_write_memory_f128",
    };
    for (const char *name : kMemIntrinsics) {
      if (llvm::Function *f = priv->mod->getFunction(name)) {
        if (!f->isDeclaration()) f->deleteBody();
      }
    }
  }
  img->llvm_ctx = priv->ctx.get();
  img->llvm_mod = priv->mod.get();

  // Declare one lifted trace per known function; the lifter fills bodies in.
  for (size_t i = 0; i < img->nfuncs; i++) {
    if (img->funcs[i].kind != ZFFE_SYM_FUNC) continue;
    img->funcs[i].llvm_func =
        priv->arch->DeclareLiftedFunction(img->funcs[i].name, priv->mod.get());
  }

  // Smoke-check the mapping: decode the first instruction of each function.
  for (size_t i = 0; i < img->nfuncs; i++) {
    if (img->funcs[i].kind != ZFFE_SYM_FUNC) continue;
    uint64_t contig = 0;
    int64_t off = image_offset(img, img->funcs[i].addr, /*want_exec=*/false,
                               &contig);
    if (off < 0 || contig == 0) {
      img->funcs[i].decode_ok = 0;
      continue;
    }
    size_t n = contig > 15 ? 15 : (size_t)contig;  // x86 max insn length
    std::string_view bytes((const char *)img->image + off, n);
    remill::Instruction inst;
    img->funcs[i].decode_ok =
        priv->arch->DecodeInstruction(img->funcs[i].addr, bytes, inst,
                                      priv->arch->CreateInitialContext())
            ? 1
            : 0;
  }

  priv->tm = std::make_unique<ZffeTraceManager>();
  priv->tm->img = img;
  priv->tm->arch = priv->arch.get();
  img->priv = priv.release();

  zffe_set_error(img, nullptr);
  return img;
}

}  // extern "C"

// Shared lift worker (declared in shim_priv.h, C++ linkage).
void *zffe_lift_into(zffe_image_t *img, const remill::Arch *arch,
                     uint64_t addr) {
  auto *priv = static_cast<ZffePriv *>(img->priv);
  if (!priv) {
    zffe_set_error(img, "image has no remill state");
    return nullptr;
  }
  zffe_func_t *rec = priv->tm->findFunc(addr);
  priv->tm->cur_entry = addr;
  remill::TraceLifter lifter(arch, priv->tm.get());
  if (!lifter.Lift(addr)) {
    zffe_set_error(img, "remill::TraceLifter::Lift failed");
    return nullptr;
  }
  void *fn = nullptr;
  const auto &which =
      priv->tm->on_demand ? priv->tm->cur_defined : priv->tm->defined;
  auto it = which.find(addr);
  if (it != which.end()) fn = it->second;
  if (rec) {
    rec->llvm_func = fn;
    rec->lifted = 1;
  }
  return fn;
}

extern "C" {

void *zffe_lift(zffe_image_t *img, uint64_t addr) {
  if (!img) return nullptr;
  zffe_set_error(img, nullptr);
  auto *priv = static_cast<ZffePriv *>(img->priv);
  if (!priv || !priv->mod) {
    zffe_set_error(img, "image has no lift session (already handed to JIT?)");
    return nullptr;
  }
  return zffe_lift_into(img, priv->arch.get(), addr);
}

int zffe_lift_closure(zffe_image_t *img) {
  if (!img) return -1;
  zffe_set_error(img, nullptr);
  auto *priv = static_cast<ZffePriv *>(img->priv);
  if (!priv || !priv->mod) {
    zffe_set_error(img, "image has no lift session (already handed to JIT?)");
    return -1;
  }
  int extra = 0;
  for (;;) {
    // Snapshot: lifting mutates wanted/defined.
    std::vector<uint64_t> batch;
    for (uint64_t a : priv->tm->wanted) {
      if (!priv->tm->defined.count(a)) batch.push_back(a);
    }
    if (batch.empty()) return extra;
    for (uint64_t a : batch) {
      if (priv->tm->defined.count(a)) continue;
      if (!zffe_lift_into(img, priv->arch.get(), a)) {
        char buf[160];
        snprintf(buf, sizeof buf,
                 "cannot lift code reached at guest 0x%llx: %s",
                 (unsigned long long)a,
                 img->error ? img->error : "?");
        zffe_set_error(img, buf);
        return -1;
      }
      extra++;
    }
  }
}

void zffe_free(zffe_image_t *img) {
  if (!img) return;
  delete static_cast<ZffePriv *>(img->priv);
  if (img->funcs) {
    for (size_t i = 0; i < img->nfuncs; i++) free((void *)img->funcs[i].name);
    free(img->funcs);
  }
  if (img->imports) {
    for (size_t i = 0; i < img->nimports; i++)
      free((void *)img->imports[i].name);
    free(img->imports);
  }
  free(img->image);
  free(img->error);
  free(img);
}

// X86 State blob layout, verified against lifting-bits/remill master
// `include/remill/Arch/X86/Runtime/State.h` (2026-10-25; re-verify if the
// pinned Remill moves): ArchState(16) + vec[32]x64B(2048) + aflag(16) +
// rflag/Flags(8) + seg(24) + addr(96) + GPR(272) + X87Stack(128) +
// mmx(128) + sw(24) + pad(8) + x87(512) + seg_caches(96) + k_reg(128).
// Cross-checked: GPR members sum to 272, whole struct to 3504, matching
// upstream's own static_asserts. Flip-time step: add
// `static_assert(X86_OFF_GPR_RIP == offsetof(State, gpr.rip))`-style checks
// against the real headers once Remill is available.
#define X86_STATE_SIZE 3504
#define X86_OFF_RFLAGS 2080 /* Flags.flat: full RFLAGS bits */
#define X86_OFF_GPR_RIP 2472 /* GPR base 2208 + rip@264 */
#define X86_OFF_GPR_RSP 2312 /* GPR base 2208 + rsp@104 */

void *zffe_state_new(uint32_t esp, uint32_t eip) {
  uint8_t *st = (uint8_t *)calloc(1, X86_STATE_SIZE);
  if (!st) return NULL;
  // EFLAGS = 0x202: reserved bit 1 always set, IF set, everything else
  // clear (consistent with the zeroed aflag bytes: DF=0, all CCs clear).
  // Segments stay zero: flat model, all AddressSpace bases zero.
  // Known follow-up: a Win32 guest using FS: (TEB) needs a real FS base.
  uint64_t rflags = 0x202;
  memcpy(st + X86_OFF_RFLAGS, &rflags, sizeof(rflags));
  // ESP/EIP: low halves only, tops untouched -- matches what lifted
  // 32-bit stores do (Reg is a plain union; no zero-extension in the IR).
  memcpy(st + X86_OFF_GPR_RSP, &esp, sizeof(esp));
  memcpy(st + X86_OFF_GPR_RIP, &eip, sizeof(eip));
  return st;
}

void zffe_state_free(void *state) {
  free(state);
}

}  // extern "C"
