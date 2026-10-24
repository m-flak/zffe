/* Linker script for the FFE flat image.
 *
 * Joins ffe.o (which %includes ffedat.asm) and ffebmp.o into one 32-bit
 * image at the classic Win32 base 0x00400000. The linked ELF is the source
 * of truth: tools/elf2map reads its symbols into ffe.map, and llvm-objcopy
 * derives the flat ffe.bin from it.
 *
 * Undefined EXTERNs (C hooks like _C_DrawSprite, libc helpers) are left
 * unresolved at link time (--unresolved-symbols=ignore-all, see build.zig);
 * they resolve to 0 in the image and are recorded as `import` lines in
 * ffe.map so the lifter can route call sites to hooks.
 */
OUTPUT_FORMAT("elf32-i386")
OUTPUT_ARCH(i386)
ENTRY(ffe_entry)
ffe_entry = 0x00400000;

SECTIONS {
  . = 0x00400000;
  .text : { *(.text*) }
  . = ALIGN(16);
  .data : { *(.data*) *(.rodata*) }
  . = ALIGN(16);
  .bss : { *(.bss*) *(COMMON) }
  /DISCARD/ : { *(.note*) *(.comment*) *(.eh_frame*) }
}
