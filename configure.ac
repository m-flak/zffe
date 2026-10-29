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

dnl --- Remill install prefix (required) ---
AC_ARG_WITH([remill-prefix],
  [AS_HELP_STRING([--with-remill-prefix=DIR],
    [Remill install prefix, with include/ and lib/ (required)])],
  [], [with_remill_prefix=no])
AS_IF([test "x$with_remill_prefix" = xno],
  [AC_MSG_ERROR([--with-remill-prefix is required])])
AS_IF([test ! -f "$with_remill_prefix/include/remill/Arch/Arch.h"],
  [AC_MSG_ERROR([Remill headers not found under $with_remill_prefix])])
AS_IF([test ! -f "$with_remill_prefix/lib/libremill_bc.a"],
  [AC_MSG_ERROR([Remill libraries not found under $with_remill_prefix])])

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

AC_OUTPUT
