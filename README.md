# zffe

Lifts the 32-bit FFE game binary with [Remill](https://github.com/lifting-bits/remill).
`ffe-info` inspects images and test-lifts every function; the lifting
runtime (guest memory, heap, import trampolines) lives in `src/lifting/`.

Pipeline: game sources in `asm/` → `nasm`/`ld.lld` → `ffe.elf` →
`ffe.bin` + `ffe.map` → Remill lift. `zffe` is the app shell (sokol
window); it does not drive the guest yet.

Linux is the primary platform. macOS works (notes at the bottom).

## Prerequisites

| Tool | Version | Notes |
| ---- | ------- | ----- |
| Zig | exactly 0.17.0 | newer Zig routinely breaks build scripts |
| nasm, lld, llvm-objcopy, pkg-config | any | `ld.lld` comes from lld |
| CMake, Ninja, Python 3 | 3.21+, 1+, 3+ | for building Remill/XED |
| LLVM + Clang | 15+, with shared libLLVM | same install for Remill and zffe; static-only LLVM builds are not supported |
| XED | **exactly v2025.06.08** | newer XED aborts inside Remill's decoder |
| glog, gflags | dev packages | found via `pkg-config` |
| Remill | recent (developed against `56918a8c`) | |

On Debian/Ubuntu the system packages are roughly:

```sh
apt install nasm lld llvm pkg-config cmake ninja-build python3 \
    libgoogle-glog-dev libgflags-dev llvm-dev clang
```

Zig is not in distro archives — install exactly 0.17.0 from
[ziglang.org](https://ziglang.org/download/). First `zig build` also fetches
the sokol/cimgui Zig packages over the network; after that builds are offline.

## Build

### 1. XED (pinned!)

```sh
git clone https://github.com/intelxed/xed
cd xed
git checkout v2025.06.08
./mfile.py install   # kit lands in kits/; add --shared for libxed.so
```

zffe expects the kit layout `include/` + `lib/libxed.a`. Newer XED is known
bad: XED trimmed 1-byte `NOP` to zero static operands and added a hard
`api_check`, which aborts Remill's unconditional `xed_inst_operand(xedi, 0)`
in `IsDirectJump`/`IsDirectFunctionCall`/… (`v2025.06.08` predates the check).

Remill finds XED through a CMake config. If your XED install ships no
`XEDConfig.cmake`, write one (e.g. `~/.cmake/XED/XEDConfig.cmake`):

```cmake
set(XED_INCLUDE_DIRS "/path/to/xed-kit/include")
set(XED_LIBRARIES "/path/to/xed-kit/lib/libxed.a")
set(XED_FOUND TRUE)
if(NOT TARGET XED::XED)
    add_library(XED::XED STATIC IMPORTED)
    set_target_properties(XED::XED PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "${XED_INCLUDE_DIRS}"
        IMPORTED_LOCATION "${XED_LIBRARIES}"
    )
endif()
```

(If you built XED `--shared`, point `XED_LIBRARIES` at `libxed.so`
instead; zffe's `configure` accepts `.a`, `.so`, or `.dylib`.)

### 2. Remill

Set the install prefix at **configure** time so plain `cmake --install` works:

```sh
git clone https://github.com/lifting-bits/remill
cd remill
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=/path/to/llvm \
  -DXED_DIR=/path/to/dir/with/XEDConfig.cmake \
  -DCMAKE_INSTALL_PREFIX=$HOME/src/remill/dist
cmake --build build
cmake --install build
```

### 3. zffe

Configure once (validates the environment, writes `build-config.zig`),
then plain `zig build`:

```sh
./configure \
  --with-remill-prefix=$HOME/src/remill/dist \
  --with-llvm-config=/path/to/llvm-config \
  --with-xed-prefix=/path/to/xed-kit
zig build
```

`--with-llvm-config` must come from the same LLVM that Remill was built
against. glog/gflags resolve through `pkg-config` (`libglog`, `gflags`); if
they live outside the default search paths, set `PKG_CONFIG_PATH`.
Re-run `./configure` (or `./config.status --recheck`) after moving anything.

Useful overrides: `-Dffe-asm=false` (skip the asm pipeline, reuse
`zig-out/data`), `-Dnasm=… -Dffe-ld=… -Dllvm-objcopy=…` (tool paths).

## Run

```sh
# inspect + lift every function in the image
./zig-out/bin/ffe-info zig-out/data/ffe.bin zig-out/data/ffe.map --lift

# tests
zig build test

# the app shell (placeholder window; guest execution not wired up yet)
zig build run
```

## Regenerating `configure` (maintainers)

`configure` is committed so users never need the autotools chain. After
editing `configure.ac`, regenerate with `aclocal && autoconf` (needs the
`autoconf`, `automake`, and `pkg-config` packages for `pkg.m4`) and commit
the result. No automake/libtool involvement — there is no `Makefile.am`.

## macOS notes

```sh
brew install zig nasm pkg-config glog gflags llvm@22
```

Check `zig version` is 0.17.0 — if Homebrew has moved on, fetch 0.17.0
from ziglang.org instead.

Homebrew's LLVM is keg-only, so pass an explicit path:

```sh
./configure \
  --with-remill-prefix=$HOME/src/remill/dist \
  --with-llvm-config=/opt/homebrew/opt/llvm@22/bin/llvm-config \
  --with-xed-prefix=$HOME/src/xed/kits/<kit>
```

`ld.lld`/`llvm-objcopy` ship with LLVM; use `-Dffe-ld`/`-Dllvm-objcopy` if
they are not on `PATH`.
