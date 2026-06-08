//
//  OPInlineAsm.s
//  OphanimCore
//
//  Shared trampoline thunk for the Tier-3 inline hook engine (see OPInline.h / OPInline.c). One copy,
//  shared by every hook. The per-hook stub (generated in the arena) sets x16 = &OPHookRecord and
//  branches here. This saves the full CPU context, calls the Swift dispatcher, then either resumes
//  into the call-original trampoline (RESUME) or returns to the caller with handler-set x0..x7
//  (REPLACE). x16/x17 (IP0/IP1) are dead at a function entry, so the per-hook stub may clobber them.
//
//  The frame offsets here MUST match `OPCpuContext` in OPInline.h, and the record offsets (call_orig
//  @ +0x00, target @ +0x08, hook_id @ +0x10) MUST match OPHookRecord in OPInline.c.
//
//  arm64 only.

#if defined(__arm64__) || defined(__aarch64__)

.text
.p2align 2
.globl _op_inline_shared_entry
_op_inline_shared_entry:
    // x16 = &OPHookRecord on entry.
    sub  sp, sp, #0x1A0
    stp  x0,  x1,  [sp, #0x00]
    stp  x2,  x3,  [sp, #0x10]
    stp  x4,  x5,  [sp, #0x20]
    stp  x6,  x7,  [sp, #0x30]
    stp  x8,  x9,  [sp, #0x40]
    stp  x10, x11, [sp, #0x50]
    stp  x12, x13, [sp, #0x60]
    stp  x14, x15, [sp, #0x70]
    stp  x16, x17, [sp, #0x80]
    stp  x18, x19, [sp, #0x90]
    stp  x20, x21, [sp, #0xA0]
    stp  x22, x23, [sp, #0xB0]
    stp  x24, x25, [sp, #0xC0]
    stp  x26, x27, [sp, #0xD0]
    stp  x28, x29, [sp, #0xE0]
    str  x30,      [sp, #0xF0]
    add  x9, sp, #0x1A0
    str  x9,       [sp, #0xF8]        // ctx->sp = caller sp at function entry
    ldr  x9,  [x16, #0x08]
    str  x9,       [sp, #0x100]       // ctx->pc = record->target
    mrs  x9,  NZCV
    str  x9,       [sp, #0x108]       // ctx->nzcv
    stp  q0,  q1,  [sp, #0x110]
    stp  q2,  q3,  [sp, #0x130]
    stp  q4,  q5,  [sp, #0x150]
    stp  q6,  q7,  [sp, #0x170]
    str  x16,      [sp, #0x190]       // stash &record across the call (x16 is caller-clobberable)

    ldr  w0,  [x16, #0x10]            // arg0 = record->hook_id
    mov  x1,  sp                      // arg1 = &ctx
    bl   _op_inline_dispatch          // -> Swift @_cdecl; returns RESUME(0)/REPLACE(1) in w0

    ldr  x16, [sp, #0x190]            // reload &record (does not touch w0)
    cmp  w0,  #1
    b.eq Lop_inline_replace
    cmp  w0,  #2
    b.eq Lop_inline_leave             // RESUME_LEAVE: run original via BL, then leave-dispatch

    // ---- RESUME: restore (possibly arg-modified) state, jump to the call-original trampoline ----
    ldr  x9,  [sp, #0x108]
    msr  NZCV, x9
    ldp  q0,  q1,  [sp, #0x110]
    ldp  q2,  q3,  [sp, #0x130]
    ldp  q4,  q5,  [sp, #0x150]
    ldp  q6,  q7,  [sp, #0x170]
    ldp  x0,  x1,  [sp, #0x00]
    ldp  x2,  x3,  [sp, #0x10]
    ldp  x4,  x5,  [sp, #0x20]
    ldp  x6,  x7,  [sp, #0x30]
    ldp  x8,  x9,  [sp, #0x40]
    ldp  x10, x11, [sp, #0x50]
    ldp  x12, x13, [sp, #0x60]
    ldp  x14, x15, [sp, #0x70]
    ldp  x18, x19, [sp, #0x90]        // skip x16/x17 (scratch; keep x16 = &record)
    ldp  x20, x21, [sp, #0xA0]
    ldp  x22, x23, [sp, #0xB0]
    ldp  x24, x25, [sp, #0xC0]
    ldp  x26, x27, [sp, #0xD0]
    ldp  x28, x29, [sp, #0xE0]
    ldr  x30,      [sp, #0xF0]
    ldr  x17, [x16, #0x00]            // call_orig trampoline
    add  sp, sp, #0x1A0
    br   x17

Lop_inline_replace:
    // ---- REPLACE: return to the caller with handler-set x0..x7; the original never runs ----
    ldr  x9,  [sp, #0x108]
    msr  NZCV, x9
    ldp  q0,  q1,  [sp, #0x110]
    ldp  q2,  q3,  [sp, #0x130]
    ldp  q4,  q5,  [sp, #0x150]
    ldp  q6,  q7,  [sp, #0x170]
    ldp  x0,  x1,  [sp, #0x00]        // x0/x1 = handler-set return value(s)
    ldp  x2,  x3,  [sp, #0x10]
    ldp  x4,  x5,  [sp, #0x20]
    ldp  x6,  x7,  [sp, #0x30]
    ldp  x8,  x9,  [sp, #0x40]
    ldp  x10, x11, [sp, #0x50]
    ldp  x12, x13, [sp, #0x60]
    ldp  x14, x15, [sp, #0x70]
    ldp  x18, x19, [sp, #0x90]        // restore callee-saved x19..x29 (we stand in for the function)
    ldp  x20, x21, [sp, #0xA0]
    ldp  x22, x23, [sp, #0xB0]
    ldp  x24, x25, [sp, #0xC0]
    ldp  x26, x27, [sp, #0xD0]
    ldp  x28, x29, [sp, #0xE0]
    ldr  x30,      [sp, #0xF0]
    add  sp, sp, #0x1A0
    ret

Lop_inline_leave:
    // ---- RESUME_LEAVE: BL the original (it returns back here), then call leave-dispatch ----
    // Restore the (possibly arg-modified) registers for the original, but keep x16 = &record and our
    // frame (sp). x30 is NOT restored - BLR sets it so the original returns to us.
    ldr  x9,  [sp, #0x108]
    msr  NZCV, x9
    ldp  q0,  q1,  [sp, #0x110]
    ldp  q2,  q3,  [sp, #0x130]
    ldp  q4,  q5,  [sp, #0x150]
    ldp  q6,  q7,  [sp, #0x170]
    ldp  x0,  x1,  [sp, #0x00]
    ldp  x2,  x3,  [sp, #0x10]
    ldp  x4,  x5,  [sp, #0x20]
    ldp  x6,  x7,  [sp, #0x30]
    ldp  x8,  x9,  [sp, #0x40]
    ldp  x10, x11, [sp, #0x50]
    ldp  x12, x13, [sp, #0x60]
    ldp  x14, x15, [sp, #0x70]
    ldp  x18, x19, [sp, #0x90]
    ldp  x20, x21, [sp, #0xA0]
    ldp  x22, x23, [sp, #0xB0]
    ldp  x24, x25, [sp, #0xC0]
    ldp  x26, x27, [sp, #0xD0]
    ldp  x28, x29, [sp, #0xE0]
    ldr  x17, [x16, #0x00]            // call_orig trampoline (x16 = &record still valid)
    blr  x17                          // run the original; it RETs back here with x0/x1 = return value
    str  x0,  [sp, #0x00]             // ctx->x[0] = return value (blr clobbered caller-saved incl x16)
    str  x1,  [sp, #0x08]             // ctx->x[1]
    ldr  x16, [sp, #0x190]            // reload &record
    ldr  w0,  [x16, #0x10]            // hook_id
    mov  x1,  sp                      // &ctx
    bl   _op_inline_dispatch_leave    // may modify ctx->x[0..1]
    ldp  x0,  x1,  [sp, #0x00]        // (possibly modified) return value
    ldr  x30,      [sp, #0xF0]        // real caller (saved at function entry)
    add  sp, sp, #0x1A0
    ret

#endif /* arm64 */
