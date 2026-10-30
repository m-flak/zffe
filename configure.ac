dnl zffe configure: probe the Remill/LLVM/XED environment and generate
dnl build-config.zig for build.zig to consume. build.zig does no probing.
dnl
dnl Regenerate with `aclocal && autoconf` (aclocal collects pkg.m4; no
dnl automake involvement beyond that) and commit the resulting `configure`
dnl so users never need the autotools chain.
AC_PREREQ([2.69])
AC_INIT([zffe], [0.0.0])
AC_CONFIG_SRCDIR([build.zig])
AC_CONFIG_FILES([build-config.zig])

dnl C++ compiler, for the glog header probe below.
AC_PROG_CXX

dnl --- Zig toolchain floor (build.zig and tools/ use 0.17 APIs) ---
AC_CHECK_PROG([ZIG], [zig], [zig], [no])
AS_IF([test "x$ZIG" = xno], [AC_MSG_ERROR([zig not found on PATH])])
ZIG_VERSION=$("$ZIG" version 2>/dev/null | head -n 1)
ZIG_MAJOR=$(expr "x$ZIG_VERSION" : 'x\([[0-9]]*\)\.' 2>/dev/null)
ZIG_MINOR=$(expr "x$ZIG_VERSION" : 'x[[0-9]]*\.\([[0-9]]*\)' 2>/dev/null)
AS_IF([test -z "$ZIG_MAJOR" -o -z "$ZIG_MINOR"],
  [AC_MSG_ERROR([cannot parse zig version from: $ZIG_VERSION])])
AS_IF([test "$ZIG_MAJOR" -gt 0 -o "$ZIG_MINOR" -ge 17], [],
  [AC_MSG_ERROR([zig >= 0.17.0 required (have $ZIG_VERSION)])])

dnl --- Remill install prefix (required) ---
AC_ARG_WITH([remill-prefix],
  [AS_HELP_STRING([--with-remill-prefix=DIR],
    [Remill install prefix, with include/ and lib/ (required)])],
  [], [with_remill_prefix=no])
AS_IF([test "x$with_remill_prefix" = xno],
  [AC_MSG_ERROR([--with-remill-prefix is required])])
AS_IF([test ! -f "$with_remill_prefix/include/remill/Arch/Arch.h"],
  [AC_MSG_ERROR([Remill headers not found under $with_remill_prefix])])
dnl build.zig links this set; verify each so a differently-built Remill
dnl fails here with a name instead of at link time. (Keep in sync with
dnl remill_libs in build.zig; `xed` lives in the XED prefix and is checked
dnl in its own section.)
for remill_lib in remill_bc remill_os remill_arch remill_version \
    remill_arch_x86 remill_arch_aarch64 remill_arch_sleigh \
    remill_arch_sparc32 remill_arch_sparc64 sla decomp slaSupport; do
  have_remill_lib=no
  for ext in a so dylib; do
    AS_IF([test -f "$with_remill_prefix/lib/lib${remill_lib}.$ext"],
      [have_remill_lib=yes])
  done
  AS_IF([test "x$have_remill_lib" = xno],
    [AC_MSG_ERROR([Remill library lib$remill_lib (.a/.so/.dylib) not found under $with_remill_prefix/lib; rebuild Remill with the default component set (including sleigh and all arches)])])
done

dnl --- XED install prefix (required) ---
AC_ARG_WITH([xed-prefix],
  [AS_HELP_STRING([--with-xed-prefix=DIR],
    [XED install prefix, with include/ and lib/ (required)])],
  [], [with_xed_prefix=no])
AS_IF([test "x$with_xed_prefix" = xno],
  [AC_MSG_ERROR([--with-xed-prefix is required])])
AS_IF([test ! -f "$with_xed_prefix/include/xed/xed-interface.h"],
  [AC_MSG_ERROR([XED headers not found under $with_xed_prefix])])
have_xed_lib=no
for xed_lib in libxed.a libxed.so libxed.dylib; do
  AS_IF([test -f "$with_xed_prefix/lib/$xed_lib"], [have_xed_lib=yes])
done
AS_IF([test "x$have_xed_lib" = xno],
  [AC_MSG_ERROR([no XED library under $with_xed_prefix/lib (want libxed.a, .so or .dylib)])])

dnl --- LLVM, via its own llvm-config. Shared libLLVM only (what Remill
dnl itself prefers): one -lLLVM, no component topology. `core` is a
dnl placeholder, --link-shared ignores it.
AC_ARG_WITH([llvm-config],
  [AS_HELP_STRING([--with-llvm-config=PROG],
    [llvm-config from the LLVM that Remill was built against])],
  [], [with_llvm_config=llvm-config])
LLVM_CXXFLAGS=$($with_llvm_config --cxxflags 2>/dev/null | tr '\n' ' ')
AS_IF([test -z "$LLVM_CXXFLAGS"],
  [AC_MSG_ERROR([$with_llvm_config --cxxflags failed; pass --with-llvm-config=/path/to/llvm-config])])
LLVM_LDFLAGS=$($with_llvm_config --ldflags --libs core --link-shared --system-libs 2>/dev/null | tr '\n' ' ')
AS_IF([test -z "$LLVM_LDFLAGS"],
  [AC_MSG_ERROR([$with_llvm_config --libs failed])])
case " $LLVM_LDFLAGS " in
  *" -lLLVM "*|*" -lLLVM-"*) ;;
  *) AC_MSG_ERROR([no shared libLLVM in llvm-config output: install your LLVM's dev package (with libLLVM.so/dylib) or rebuild LLVM with LLVM_BUILD_LLVM_DYLIB=ON]) ;;
esac

dnl --- glog + gflags via pkg-config (both ship .pc files upstream) ---
PKG_CHECK_MODULES([LOGGING], [libglog gflags])
dnl How glog was built (shared vs static, gflags or not) decides which
dnl defines its headers need. Probe by compile+link, most-featured first,
dnl and export whatever works instead of assuming.
AC_MSG_CHECKING([for working glog header defines])
AC_LANG_PUSH([C++])
save_CXXFLAGS=$CXXFLAGS
save_LIBS=$LIBS
LOGGING_EXTRA_DEFS=""
glog_defs_ok=no
for glog_defs in "-DGLOG_USE_GLOG_EXPORT -DGLOG_USE_GFLAGS" \
    "-DGLOG_USE_GFLAGS" ""; do
  CXXFLAGS="$save_CXXFLAGS $LOGGING_CFLAGS $glog_defs"
  LIBS="$save_LIBS $LOGGING_LIBS"
  AC_LINK_IFELSE(
    [AC_LANG_PROGRAM([[#include <glog/logging.h>]],
      [[google::InitGoogleLogging("probe");]])],
    [LOGGING_EXTRA_DEFS="$glog_defs"; glog_defs_ok=yes; break], [])
done
AC_LANG_POP
CXXFLAGS=$save_CXXFLAGS
LIBS=$save_LIBS
AS_IF([test "x$glog_defs_ok" = xno],
  [AC_MSG_ERROR([cannot compile and link against glog with any known define set (tried with/without GLOG_USE_GLOG_EXPORT and GLOG_USE_GFLAGS); check your glog install])])
AC_MSG_RESULT([$LOGGING_EXTRA_DEFS])

dnl --- Game image tools (nasm + LLVM's lld/objcopy). lld/objcopy resolve
dnl from the same LLVM as --with-llvm-config (Homebrew LLVM is keg-only, so
dnl PATH alone is unreliable); nasm is independent.
AC_CHECK_PROG([NASM], [nasm], [nasm], [no])
AS_IF([test "x$NASM" = xno],
  [AC_MSG_ERROR([nasm not found; install nasm to assemble asm/])])
LLVM_BINDIR=$(dirname "$with_llvm_config")
AS_IF([test -x "$LLVM_BINDIR/ld.lld"], [FFE_LD="$LLVM_BINDIR/ld.lld"],
  [AC_CHECK_PROG([FFE_LD], [ld.lld], [ld.lld], [no])])
AS_IF([test "x$FFE_LD" = xno],
  [AC_MSG_ERROR([ld.lld not found next to $with_llvm_config nor on PATH])])
AS_IF([test -x "$LLVM_BINDIR/llvm-objcopy"],
  [LLVM_OBJCOPY="$LLVM_BINDIR/llvm-objcopy"],
  [AC_CHECK_PROG([LLVM_OBJCOPY], [llvm-objcopy], [llvm-objcopy], [no])])
AS_IF([test "x$LLVM_OBJCOPY" = xno],
  [AC_MSG_ERROR([llvm-objcopy not found next to $with_llvm_config nor on PATH])])

REMILL_INCLUDE="$with_remill_prefix/include"
REMILL_LIBDIR="$with_remill_prefix/lib"
XED_INCLUDE="$with_xed_prefix/include"
XED_LIBDIR="$with_xed_prefix/lib"
AC_SUBST([REMILL_INCLUDE])
AC_SUBST([REMILL_LIBDIR])
AC_SUBST([XED_INCLUDE])
AC_SUBST([XED_LIBDIR])
AC_SUBST([LLVM_CXXFLAGS])
AC_SUBST([LLVM_LDFLAGS])
AC_SUBST([LOGGING_EXTRA_DEFS])
AC_SUBST([NASM])
AC_SUBST([FFE_LD])
AC_SUBST([LLVM_OBJCOPY])

AC_OUTPUT
