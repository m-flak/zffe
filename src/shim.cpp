// zffe Remill shim. See shim.h for the ABI contract.
//
// Remill API usage mirrors bin/lift/Lift.cpp from lifting-bits/remill
// (verified against upstream HEAD 56918a8c): Arch::Get, LoadArchSemantics,
// a TraceManager reading bytes from our flat image, TraceLifter::Lift.

#include "shim.h"

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

#if defined(ZFFE_HAVE_REMILL) && ZFFE_HAVE_REMILL
#  include <remill/Arch/Arch.h>
#  include <remill/Arch/Instruction.h>
#  include <remill/BC/TraceLifter.h>
#  include <remill/BC/Util.h>
#  include <llvm/IR/Function.h>
#  include <llvm/IR/LLVMContext.h>
#  include <llvm/IR/Module.h>
#endif

namespace {

void set_error(zffe_image_t *img, const char *msg) {
  free(img->error);
  img->error = msg ? strdup(msg) : nullptr;
  if (msg && !img->error) {
    img->error = strdup("out of memory");
  }
}

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

#if defined(ZFFE_HAVE_REMILL) && ZFFE_HAVE_REMILL
namespace {

struct ZffePriv;

// TraceManager over our flat image. Trace naming prefers map symbol names so
// pre-declared functions get their bodies filled in by the lifter (see
// TraceLifter::Impl::get_trace_decl, which reuses module->getFunction(name)).
class ZffeTraceManager : public remill::TraceManager {
 public:
  zffe_image_t *img = nullptr;
  const remill::Arch *arch = nullptr;
  uint64_t cur_entry = 0;
  std::unordered_map<uint64_t, llvm::Function *> defined;

  std::string TraceName(uint64_t addr) override {
    for (size_t i = 0; i < img->nfuncs; i++) {
      if (img->funcs[i].addr == addr) return img->funcs[i].name;
    }
    // Import sentinels lift as calls to `import_<sym>` declarations, which
    // the engine implements natively (trampolines).
    for (size_t i = 0; i < img->nimports; i++) {
      if (img->imports[i].addr == addr)
        return std::string("import_") + img->imports[i].name;
    }
    return remill::TraceManager::TraceName(addr);
  }

  void SetLiftedTraceDefinition(uint64_t addr,
                                llvm::Function *lifted_func) override {
    defined[addr] = lifted_func;
  }

  llvm::Function *GetLiftedTraceDefinition(uint64_t addr) override {
    auto it = defined.find(addr);
    if (it != defined.end()) return it->second;
    if (addr == cur_entry) return nullptr;  // force this one to be lifted
    // Anything else: hand back (or create) a declaration so the lifter emits
    // a call instead of recursing. Mirrors remill's SimpleTraceManager.
    auto *mod = static_cast<llvm::Module *>(img->llvm_mod);
    std::string name = TraceName(addr);
    if (auto *fn = mod->getFunction(name)) return fn;
    return arch->DeclareLiftedFunction(name, mod);
  }

  bool TryReadExecutableByte(uint64_t addr, uint8_t *byte) override {
    int64_t off = image_offset(img, addr, /*want_exec=*/true);
    if (off < 0) return false;
    if (byte) *byte = img->image[off];
    return true;
  }
};

struct ZffePriv {
  std::unique_ptr<llvm::LLVMContext> ctx;
  std::unique_ptr<llvm::Module> mod;
  remill::Arch::ArchPtr arch;
  std::unique_ptr<ZffeTraceManager> tm;
};

}  // namespace
#endif  // ZFFE_HAVE_REMILL

extern "C" {

const char *zffe_version(void) {
#if defined(ZFFE_HAVE_REMILL) && ZFFE_HAVE_REMILL
  return "remill 56918a8c+";
#else
  return "stub";
#endif
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
    set_error(img, err.c_str());
    return img;
  }
  std::vector<uint8_t> map_bytes;
  if (!read_file(map_path, map_bytes, err)) {
    set_error(img, err.c_str());
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
        set_error(img, "bad base line in map");
        return img;
      }
      have_base = true;
    } else if (!strcmp(kind, "entry")) {
      bool ok = false;
      img->entry = parse_hex(strtok_r(nullptr, " \t", &tok_save), ok);
      if (!ok) {
        set_error(img, "bad entry line in map");
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
        set_error(img, "bad code line in map");
        return img;
      }
      have_code = true;
    } else if (!strcmp(kind, "mem_end")) {
      bool ok = false;
      img->mem_end = parse_hex(strtok_r(nullptr, " \t", &tok_save), ok);
      if (!ok) {
        set_error(img, "bad mem_end line in map");
        return img;
      }
      have_mem_end = true;
    } else if (!strcmp(kind, "sym")) {
      char *name = strtok_r(nullptr, " \t", &tok_save);
      char *addr_s = strtok_r(nullptr, " \t", &tok_save);
      char *size_s = strtok_r(nullptr, " \t", &tok_save);
      char *kind_s = strtok_r(nullptr, " \t", &tok_save);
      if (!name || !addr_s || !size_s || !kind_s) {
        set_error(img, "bad sym line in map");
        return img;
      }
      bool ok_a = false, ok_s = false;
      uint64_t addr = parse_hex(addr_s, ok_a);
      uint64_t size = parse_hex(size_s, ok_s);
      if (!ok_a || !ok_s) {
        set_error(img, "bad sym line in map");
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
        set_error(img, "bad import line in map (want: import <name> <addr>)");
        return img;
      }
      bool ok = false;
      uint64_t addr = parse_hex(addr_s, ok);
      if (!ok) {
        set_error(img, "bad import line in map (want: import <name> <addr>)");
        return img;
      }
      zffe_import_t im;
      memset(&im, 0, sizeof(im));
      im.addr = addr;
      import_names.emplace_back(name);
      imports.push_back(im);
    } else {
      std::string msg = std::string("unknown map line kind: ") + kind;
      set_error(img, msg.c_str());
      return img;
    }
  }

  if (!have_base || !have_entry || !have_code || !have_mem_end) {
    set_error(img, "map missing base/entry/code/mem_end");
    return img;
  }
  if (img->mem_end <= img->base) {
    set_error(img, "bad memory span in map");
    return img;
  }
  if (img->code_end <= img->code_start || img->code_start < img->base ||
      img->code_end > img->mem_end) {
    set_error(img, "bad code range in map");
    return img;
  }
  size_t span = (size_t)(img->mem_end - img->base);
  if (bin.size() > span) {
    set_error(img, "bin larger than map memory span");
    return img;
  }
  img->image = (uint8_t *)calloc(span ? span : 1, 1);
  if (!img->image) {
    set_error(img, "out of memory");
    return img;
  }
  memcpy(img->image, bin.data(), bin.size());
  img->image_size = span;

  img->nfuncs = funcs.size();
  img->funcs =
      (zffe_func_t *)calloc(img->nfuncs ? img->nfuncs : 1, sizeof(zffe_func_t));
  if (!img->funcs) {
    set_error(img, "out of memory");
    return img;
  }
  memcpy(img->funcs, funcs.data(), img->nfuncs * sizeof(zffe_func_t));
  for (size_t i = 0; i < img->nfuncs; i++) {
    img->funcs[i].name = strdup(names[i].c_str());
    if (!img->funcs[i].name) {
      set_error(img, "out of memory");
      return img;
    }
  }

  img->nimports = imports.size();
  img->imports = (zffe_import_t *)calloc(img->nimports ? img->nimports : 1,
                                         sizeof(zffe_import_t));
  if (!img->imports) {
    set_error(img, "out of memory");
    return img;
  }
  memcpy(img->imports, imports.data(),
         img->nimports * sizeof(zffe_import_t));
  for (size_t i = 0; i < img->nimports; i++) {
    img->imports[i].name = strdup(import_names[i].c_str());
    if (!img->imports[i].name) {
      set_error(img, "out of memory");
      return img;
    }
  }

#if defined(ZFFE_HAVE_REMILL) && ZFFE_HAVE_REMILL
  const char *os_s = (os && *os) ? os : "windows";
  const char *arch_s = (arch_name && *arch_name) ? arch_name : "x86";
  auto priv = std::make_unique<ZffePriv>();
  priv->ctx = std::make_unique<llvm::LLVMContext>();
  priv->arch = remill::Arch::Get(*priv->ctx, os_s, arch_s);
  if (!priv->arch) {
    set_error(img, "remill::Arch::Get failed (bad os/arch?)");
    return img;
  }
  priv->mod = remill::LoadArchSemantics(priv->arch.get());
  if (!priv->mod) {
    set_error(img, "remill::LoadArchSemantics failed");
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
#else
  (void)os;
  (void)arch_name;
  // Distinct non-NULL sentinels so the Zig side can exercise the full flow.
  for (size_t i = 0; i < img->nfuncs; i++) {
    if (img->funcs[i].kind != ZFFE_SYM_FUNC) continue;
    img->funcs[i].llvm_func =
        (void *)(uintptr_t)(img->funcs[i].addr ? img->funcs[i].addr : (i + 1));
  }
#endif

  set_error(img, nullptr);
  return img;
}

void *zffe_lift(zffe_image_t *img, uint64_t addr) {
  if (!img) return nullptr;
  set_error(img, nullptr);
  zffe_func_t *rec = nullptr;
  for (size_t i = 0; i < img->nfuncs; i++) {
    if (img->funcs[i].addr == addr) {
      rec = &img->funcs[i];
      break;
    }
  }
#if defined(ZFFE_HAVE_REMILL) && ZFFE_HAVE_REMILL
  auto *priv = static_cast<ZffePriv *>(img->priv);
  if (!priv) {
    set_error(img, "image has no remill state");
    return nullptr;
  }
  priv->tm->cur_entry = addr;
  remill::TraceLifter lifter(priv->arch.get(), priv->tm.get());
  if (!lifter.Lift(addr)) {
    set_error(img, "remill::TraceLifter::Lift failed");
    return nullptr;
  }
  void *fn = nullptr;
  auto it = priv->tm->defined.find(addr);
  if (it != priv->tm->defined.end()) fn = it->second;
  if (rec) {
    rec->llvm_func = fn;
    rec->lifted = 1;
  }
  return fn;
#else
  if (!rec) {
    set_error(img, "unknown address (not in map)");
    return nullptr;
  }
  rec->lifted = 1;
  return rec->llvm_func;
#endif
}

void zffe_free(zffe_image_t *img) {
  if (!img) return;
#if defined(ZFFE_HAVE_REMILL) && ZFFE_HAVE_REMILL
  delete static_cast<ZffePriv *>(img->priv);
#endif
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

}  // extern "C"
