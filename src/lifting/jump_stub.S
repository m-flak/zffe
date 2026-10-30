// zffe `__remill_jump`: indirect-jump dispatcher with true tail-jump
// semantics. Lifted traces tail-call here; we resolve the guest PC to JIT'd
// code and JUMP (never call/return), so the target's eventual `ret` lands on
// the jumping trace's own caller, exactly like the original `jmp`.
//
// SysV x86_64 and AArch64 only (the hosts reservation.zig supports).
// (State*, pc, mem) arrive in the standard argument registers and are
// forwarded unchanged to the resolved trace.

#if defined(__APPLE__)
#define C(sym) _##sym
#else
#define C(sym) sym
#endif

    .text

#if defined(__x86_64__)
    .globl C(__remill_jump)
    .p2align 4
C(__remill_jump):
    // rdi=State, esi=pc, rdx=mem. Save args, resolve, restore, jump.
    // The frame is fully torn down before the jump, so this is correct
    // whether or not the trace's tail call was compiled as a real jump.
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    mov %rdi, %rbx
    mov %esi, %r12d
    mov %rdx, %r13
    mov %r12d, %edi
    call C(zffe_dispatch_target)  // never returns null (aborts inside)
    mov %rax, %r11
    mov %rbx, %rdi
    mov %r12d, %esi
    mov %r13, %rdx
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    jmp *%r11

#elif defined(__aarch64__)
    .globl C(__remill_jump)
    .p2align 2
C(__remill_jump):
    // x0=State, w1=pc, x2=mem. Same shape as above.
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x0, x1, [sp, #16]
    str x2, [sp, #32]
    mov w0, w1
    bl C(zffe_dispatch_target)  // never returns null (aborts inside)
    mov x9, x0
    ldp x0, x1, [sp, #16]
    ldr x2, [sp, #32]
    ldp x29, x30, [sp], #48
    br x9

#else
#error "jump stub needs x86_64 or aarch64"
#endif

#if defined(__linux__)
    .section .note.GNU-stack,"",@progbits
#endif
