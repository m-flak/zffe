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
static_assert(offsetof(zffe_section_t, vaddr) == 16, "abi");
static_assert(offsetof(zffe_section_t, file_off) == 24, "abi");
static_assert(offsetof(zffe_section_t, file_sz) == 32, "abi");
static_assert(offsetof(zffe_section_t, mem_sz) == 40, "abi");
static_assert(offsetof(zffe_section_t, flags) == 48, "abi");
static_assert(sizeof(zffe_section_t) == 56, "abi");
static_assert(offsetof(zffe_image_t, llvm_mod) == 8, "abi");
static_assert(offsetof(zffe_image_t, funcs) == 16, "abi");
static_assert(offsetof(zffe_image_t, nfuncs) == 24, "abi");
static_assert(offsetof(zffe_image_t, sections) == 32, "abi");
static_assert(offsetof(zffe_image_t, nsections) == 40, "abi");
static_assert(offsetof(zffe_image_t, image) == 48, "abi");
static_assert(offsetof(zffe_image_t, image_size) == 56, "abi");
static_assert(offsetof(zffe_image_t, base) == 64, "abi");
static_assert(offsetof(zffe_image_t, entry) == 72, "abi");
static_assert(offsetof(zffe_image_t, priv) == 80, "abi");
static_assert(offsetof(zffe_image_t, error) == 88, "abi");
static_assert(sizeof(zffe_image_t) == 96, "abi");

#if defined(ZFFE_HAVE_REMILL) && ZFFE_HAVE_REMILL
#  include <remill/Arch/Arch.h>
#  include <remill/Arch/Instruction.h>
#  include <remill/BC/TraceLifter.h>
#  include <remill/BC/Util.h>
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

// Byte offset of `addr` in the flat image, or -1. `want_exec` restricts to
// executable sections (for the trace manager's TryReadExecutableByte).
int64_t image_offset(const zffe_image_t *img, uint64_t addr, bool want_exec,
                     uint64_t *contig = nullptr) {
  for (size_t i = 0; i < img->nsections; i++) {
    const zffe_section_t &s = img->sections[i];
    if (want_exec && !(s.flags & ZFFE_SEC_X)) continue;
    if (addr < s.vaddr || addr >= s.vaddr + s.mem_sz) continue;
    uint64_t in_sec = addr - s.vaddr;
    if (in_sec >= s.file_sz) return -1;  // in .bss tail: no backing bytes
    if (contig) *contig = s.file_sz - in_sec;
    int64_t off = (int64_t)(s.file_off + in_sec);
    if (off < 0 || (uint64_t)off >= img->image_size) return -1;
    return off;
  }
  return -1;
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

  img->image = (uint8_t *)malloc(bin.size() ? bin.size() : 1);
  if (!img->image) {
    set_error(img, "out of memory");
    return img;
  }
  memcpy(img->image, bin.data(), bin.size());
  img->image_size = bin.size();

  std::vector<zffe_section_t> sections;
  std::vector<zffe_func_t> funcs;
  std::vector<std::string> names;  // parallel to funcs; owns name storage

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
    } else if (!strcmp(kind, "entry")) {
      bool ok = false;
      img->entry = parse_hex(strtok_r(nullptr, " \t", &tok_save), ok);
      if (!ok) {
        set_error(img, "bad entry line in map");
        return img;
      }
    } else if (!strcmp(kind, "section")) {
      zffe_section_t s;
      memset(&s, 0, sizeof(s));
      char *name = strtok_r(nullptr, " \t", &tok_save);
      if (!name) {
        set_error(img, "bad section line in map");
        return img;
      }
      snprintf(s.name, sizeof(s.name), "%s", name);
      bool have_v = false, have_o = false, have_f = false, have_m = false;
      for (char *k; (k = strtok_r(nullptr, " \t", &tok_save));) {
        char *v = strtok_r(nullptr, " \t", &tok_save);
        if (!v) break;
        if (!strcmp(k, "vaddr")) {
          s.vaddr = parse_hex(v, have_v);
        } else if (!strcmp(k, "off")) {
          s.file_off = parse_hex(v, have_o);
        } else if (!strcmp(k, "filesz")) {
          s.file_sz = parse_hex(v, have_f);
        } else if (!strcmp(k, "memsz")) {
          s.mem_sz = parse_hex(v, have_m);
        } else if (!strcmp(k, "flags")) {
          for (const char *p = v; *p; p++) {
            if (*p == 'r') s.flags |= ZFFE_SEC_R;
            if (*p == 'w') s.flags |= ZFFE_SEC_W;
            if (*p == 'x') s.flags |= ZFFE_SEC_X;
          }
        }
      }
      if (!have_v || !have_o || !have_f || !have_m) {
        set_error(img, "bad section line in map");
        return img;
      }
      // NOBITS (.bss) sections have no backing bytes; their file_off may
      // legitimately point at or past EOF.
      if (s.file_sz > 0 && s.file_off + s.file_sz > img->image_size) {
        set_error(img, "section extends past end of bin");
        return img;
      }
      sections.push_back(s);
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
      // Informational for now: the ELF relocations map call sites to these.
      continue;
    } else {
      std::string msg = std::string("unknown map line kind: ") + kind;
      set_error(img, msg.c_str());
      return img;
    }
  }

  img->nsections = sections.size();
  img->sections = (zffe_section_t *)calloc(img->nsections ? img->nsections : 1,
                                           sizeof(zffe_section_t));
  if (!img->sections) {
    set_error(img, "out of memory");
    return img;
  }
  memcpy(img->sections, sections.data(),
         img->nsections * sizeof(zffe_section_t));

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
  free(img->sections);
  free(img->image);
  free(img->error);
  free(img);
}

}  // extern "C"
