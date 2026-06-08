//
//  OPInline.c
//  OphanimCore
//
//  Tier-3 inline hook engine core (see OPInline.h). arm64 only. Patches a function entry with a
//  branch to a per-hook trampoline that runs the shared entry thunk (OPInlineAsm.s). Copy-on-write
//  patching (VM_PROT_COPY) keeps it in-process and ephemeral - the on-disk binary and shared cache
//  are never touched.
//
//  Phase 1-2 scope: 4-byte `B` patch to a near-allocated trampoline; the relocator passes through
//  non-PC-relative prologue instructions and ABORTS (never partial-patches) on any PC-relative or
//  control-flow instruction. The full relocator + 16-byte fallback land in a later phase.
//

#if defined(__arm64__) || defined(__aarch64__)

#include "OPInline.h"
#include <mach/mach.h>           // vm_protect, vm_region_64 (mach_vm.h is unsupported under iOS SDK)
#include <sys/mman.h>
#include <dlfcn.h>
#include <string.h>
#include <pthread.h>
#include <libkern/OSCacheControl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <objc/runtime.h>
#include <stdlib.h>

#ifndef CPU_SUBTYPE_ARM64E
#define CPU_SUBTYPE_ARM64E 2
#endif

#define OP_MAX_HOOKS 128
#define OP_PAGE      0x4000u            // 16 KiB (arm64 macOS page)
#define OP_B_RANGE   0x07F00000ll       // a touch under ±128 MB for the 4-byte B patch

// Per-hook record read by the shared entry thunk via x16. Field offsets are contractual with
// OPInlineAsm.s: call_orig @ +0x00, target @ +0x08, hook_id @ +0x10. Lives in the (RX) arena page.
typedef struct {
    uint64_t call_orig;     // +0x00
    uint64_t target;        // +0x08
    uint32_t hook_id;       // +0x10
    uint32_t _pad;          // +0x14
} OPHookRecord;

typedef struct {
    bool      in_use;
    uintptr_t target;
    void     *page;         // arena page (one per hook)
    uint32_t  patch_len;    // bytes overwritten at target
    uint8_t   saved[16];    // original bytes
} OPHookSlot;

static OPHookSlot      g_hooks[OP_MAX_HOOKS];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

extern void op_inline_shared_entry(void);   // OPInlineAsm.s

// ---- arm64 instruction encoders ----------------------------------------------------------------

static inline uint32_t enc_movz(int rd, uint16_t imm, int shift16) {
    return 0xD2800000u | ((uint32_t)shift16 << 21) | ((uint32_t)imm << 5) | (uint32_t)rd;
}
static inline uint32_t enc_movk(int rd, uint16_t imm, int shift16) {
    return 0xF2800000u | ((uint32_t)shift16 << 21) | ((uint32_t)imm << 5) | (uint32_t)rd;
}
static int emit_mov_abs(uint32_t *o, int rd, uint64_t v) {
    o[0] = enc_movz(rd, (uint16_t)(v & 0xFFFF), 0);
    o[1] = enc_movk(rd, (uint16_t)((v >> 16) & 0xFFFF), 1);
    o[2] = enc_movk(rd, (uint16_t)((v >> 32) & 0xFFFF), 2);
    o[3] = enc_movk(rd, (uint16_t)((v >> 48) & 0xFFFF), 3);
    return 4;
}
static inline uint32_t enc_br(int rn)    { return 0xD61F0000u | ((uint32_t)rn << 5); }
static inline uint32_t enc_b(int64_t byte_off) {
    return 0x14000000u | ((uint32_t)((byte_off >> 2)) & 0x03FFFFFFu);
}

// ---- relocator -------------------------------------------------------------------------------

// Sign-extend the low `bits` of v.
static int64_t sext(uint64_t v, int bits) {
    uint64_t m = 1ull << (bits - 1);
    return (int64_t)((v ^ m) - m);
}

// PC-independent long jump to an absolute address: ldr x16,#8 ; br x16 ; .quad dst  (4 words).
static int emit_jump_abs(uint32_t *o, uint64_t dst) {
    o[0] = 0x58000050u;                       // ldr x16, #8  (load the literal two words ahead)
    o[1] = enc_br(16);                        // br  x16
    o[2] = (uint32_t)(dst & 0xFFFFFFFFu);
    o[3] = (uint32_t)(dst >> 32);
    return 4;
}

// Relocate one instruction (originally at `pc`) into `out` as PC-independent code. Returns the number
// of 32-bit words emitted, or -1 to ABORT the hook (fail-safe - never partial-patch). The conditional
// forms branch over a long-jump to the (un-taken) fall-through, which the caller places immediately
// after this block (the trampoline tail that returns to target+patch_len). Non-PC-relative and
// register-indirect instructions (incl. RET/BR/BLR) are position-independent → copied verbatim.
// Scratch register x16 (IP0) is used for materialization; it is dead at a function entry.
static int relocate_one(uint32_t w, uint64_t pc, uint32_t *out) {
    if ((w & 0xFC000000u) == 0x14000000u) {                 // B (imm26)
        uint64_t dst = pc + (uint64_t)(sext(w & 0x03FFFFFFu, 26) << 2);
        return emit_jump_abs(out, dst);
    }
    if ((w & 0xFC000000u) == 0x94000000u) {                 // BL (imm26)
        uint64_t dst = pc + (uint64_t)(sext(w & 0x03FFFFFFu, 26) << 2);
        // x30 = the continuation IN THE TRAMPOLINE (right after this 5-word block), NOT the original
        // pc+4 - which may be inside the clobbered patch window. adr reaches it (always ±1MB-near).
        out[0] = 0x100000BEu;                               // adr x30, #20  (5 words ahead)
        emit_jump_abs(out + 1, dst);                        // ldr x16,#8 ; br x16 ; .quad dst
        return 5;
    }
    if ((w & 0xFF000010u) == 0x54000000u) {                 // B.cond (imm19)
        uint64_t dst = pc + (uint64_t)(sext((w >> 5) & 0x7FFFFu, 19) << 2);
        uint32_t cond = w & 0xFu, total = 1 + 4;            // skip (words) to the fall-through tail
        out[0] = 0x54000000u | ((total & 0x7FFFFu) << 5) | (cond ^ 1u);
        emit_jump_abs(out + 1, dst);
        return (int)total;
    }
    if ((w & 0x7E000000u) == 0x34000000u) {                 // CBZ/CBNZ (imm19)
        uint64_t dst = pc + (uint64_t)(sext((w >> 5) & 0x7FFFFu, 19) << 2);
        uint32_t sf = w & 0x80000000u, Rt = w & 0x1Fu, op = (w >> 24) & 1u, total = 1 + 4;
        out[0] = 0x34000000u | sf | ((op ^ 1u) << 24) | ((total & 0x7FFFFu) << 5) | Rt;
        emit_jump_abs(out + 1, dst);
        return (int)total;
    }
    if ((w & 0x7E000000u) == 0x36000000u) {                 // TBZ/TBNZ (imm14)
        uint64_t dst = pc + (uint64_t)(sext((w >> 5) & 0x3FFFu, 14) << 2);
        uint32_t keep = w & (0x80000000u | 0x00F80000u | 0x1Fu); // b5, bit40, Rt
        uint32_t op = (w >> 24) & 1u, total = 1 + 4;
        out[0] = 0x36000000u | keep | ((op ^ 1u) << 24) | ((total & 0x3FFFu) << 5);
        emit_jump_abs(out + 1, dst);
        return (int)total;
    }
    if ((w & 0x9F000000u) == 0x10000000u) {                 // ADR
        uint64_t imm = (((w >> 5) & 0x7FFFFu) << 2) | ((w >> 29) & 3u);
        return emit_mov_abs(out, (int)(w & 0x1Fu), pc + (uint64_t)sext(imm, 21));
    }
    if ((w & 0x9F000000u) == 0x90000000u) {                 // ADRP
        uint64_t imm = (((w >> 5) & 0x7FFFFu) << 2) | ((w >> 29) & 3u);
        uint64_t dst = (pc & ~0xFFFull) + (uint64_t)(sext(imm, 21) << 12);
        return emit_mov_abs(out, (int)(w & 0x1Fu), dst);
    }
    if ((w & 0x3B000000u) == 0x18000000u) {                 // LDR (literal) 32/64
        uint64_t la = pc + (uint64_t)(sext((w >> 5) & 0x7FFFFu, 19) << 2);
        uint32_t Rt = w & 0x1Fu, opc = (w >> 30) & 3u;
        int n = emit_mov_abs(out, (int)Rt, la);
        out[n++] = (opc == 0 ? 0xB9400000u : 0xF9400000u) | (Rt << 5) | Rt;  // ldr W/X t,[Xt]
        return n;
    }
    if ((w & 0xFF000000u) == 0x98000000u) {                 // LDRSW (literal)
        uint64_t la = pc + (uint64_t)(sext((w >> 5) & 0x7FFFFu, 19) << 2);
        uint32_t Rt = w & 0x1Fu;
        int n = emit_mov_abs(out, (int)Rt, la);
        out[n++] = 0xB9800000u | (Rt << 5) | Rt;                              // ldrsw Xt,[Xt]
        return n;
    }
    if ((w & 0x3B000000u) == 0x1C000000u) {                 // LDR (literal) SIMD/FP
        uint64_t la = pc + (uint64_t)(sext((w >> 5) & 0x7FFFFu, 19) << 2);
        uint32_t Vt = w & 0x1Fu, opc = (w >> 30) & 3u;
        int n = emit_mov_abs(out, 16, la);                  // x16 = scratch address
        if (opc == 0)      out[n++] = 0xBD400000u | (16u << 5) | Vt;          // ldr St,[x16]
        else if (opc == 1) out[n++] = 0xFD400000u | (16u << 5) | Vt;          // ldr Dt,[x16]
        else if (opc == 2) out[n++] = 0x3DC00000u | (16u << 5) | Vt;          // ldr Qt,[x16]
        else return -1;
        return n;
    }
    if ((w & 0xFF000000u) == 0xD8000000u) {                 // PRFM (literal) - hint; drop to NOP
        out[0] = 0xD503201Fu;
        return 1;
    }
    out[0] = w;                                             // position-independent → verbatim
    return 1;
}

// ---- memory / validation -----------------------------------------------------------------------

static bool cow_write(void *dst, const void *src, size_t len) {
    vm_address_t page = (vm_address_t)dst & ~((vm_address_t)OP_PAGE - 1);
    vm_size_t    span = ((vm_address_t)dst + len) - page;
    if (vm_protect(mach_task_self(), page, span, FALSE,
                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
        return false;
    memcpy(dst, src, len);
    sys_icache_invalidate(dst, len);
    vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    return true;
}

// Target must resolve inside a known image and lie in a mapped, readable+executable region.
static bool target_is_executable(uintptr_t target, size_t len) {
    Dl_info info;
    if (dladdr((const void *)target, &info) == 0 || info.dli_fbase == NULL) return false;
    vm_address_t addr = (vm_address_t)target;
    vm_size_t    size = 0;
    vm_region_basic_info_data_64_t bi;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&bi, &count, &obj) != KERN_SUCCESS) return false;
    if (addr > target || target + len > (uintptr_t)addr + size) return false;
    return (bi.protection & VM_PROT_EXECUTE) && (bi.protection & VM_PROT_READ);
}

// Refuse arm64e images (the app's code would carry PAC; our synthesized branches aren't signed).
static bool target_is_arm64e(uintptr_t target) {
    Dl_info info;
    if (dladdr((const void *)target, &info) == 0 || info.dli_fbase == NULL) return true; // unknown → refuse
    const struct mach_header_64 *mh = (const struct mach_header_64 *)info.dli_fbase;
    if (mh->magic != MH_MAGIC_64) return true;
    return (mh->cputype == CPU_TYPE_ARM64) &&
           ((mh->cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E);
}

static void free_page(void *p) {
    if (p) vm_deallocate(mach_task_self(), (vm_address_t)(uintptr_t)p, OP_PAGE);
}

// One RW page within the 4-byte B reach (±128 MB) of `target`. Walks the VM map to find an actual
// free gap in [target-range, target+range) and grabs a page there with vm_allocate(VM_FLAGS_FIXED),
// which fails (rather than clobbers) if the slot is occupied - so we never disturb an existing
// mapping. RW by default; the caller flips it RX after filling. (A hint/ANYWHERE allocation is not
// reliable here: when the band around the target is densely mapped the kernel returns a far hole.)
static void *alloc_near(uintptr_t target) {
    vm_address_t lo = (target > (uintptr_t)OP_B_RANGE) ? (vm_address_t)(target - OP_B_RANGE) : OP_PAGE;
    vm_address_t hi = (vm_address_t)(target + OP_B_RANGE);
    vm_address_t a = lo & ~((vm_address_t)OP_PAGE - 1);
    for (int guard = 0; guard < 200000 && a < hi; guard++) {
        vm_address_t r = a; vm_size_t s = 0;
        vm_region_basic_info_data_64_t bi;
        mach_msg_type_number_t c = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t o;
        kern_return_t kr = vm_region_64(mach_task_self(), &r, &s, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&bi, &c, &o);
        if (kr != KERN_SUCCESS || r > a) {              // gap [a, r) (or nothing mapped above) → free
            vm_address_t got = a;
            if (a + OP_PAGE <= hi &&
                vm_allocate(mach_task_self(), &got, OP_PAGE, VM_FLAGS_FIXED) == KERN_SUCCESS) {
                if (got == a) return (void *)(uintptr_t)got;
                vm_deallocate(mach_task_self(), got, OP_PAGE);
            }
            if (kr != KERN_SUCCESS) break;              // no more regions; nothing else to try
            a = r;                                      // skip to the next mapped region
        } else {                                        // a is inside [r, r+s) → step past it
            vm_address_t next = r + s;
            if (next <= a) break;
            a = next;
        }
    }
    return NULL;
}

// One RW page anywhere (for the 16-byte absolute patch, which has full 64-bit reach so the trampoline
// needn't be near the target). Used when alloc_near can't find a free slot within ±128 MB.
static void *alloc_any(void) {
    vm_address_t a = 0;
    if (vm_allocate(mach_task_self(), &a, OP_PAGE, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return NULL;
    return (void *)(uintptr_t)a;
}

// Heuristic: does any branch later in the function target inside (target, target+len)? Guards the
// 16-byte patch against a loop/back-edge that lands in the clobbered window. Bounded forward scan;
// stops at the first RET (a rough function-end marker). Conservative - false positives only abort.
static bool internal_branch_into(uintptr_t target, uint32_t len) {
    for (int i = 1; i < 256; i++) {
        uintptr_t pc = target + (uintptr_t)i * 4;
        if (!target_is_executable(pc, 4)) break;
        uint32_t w = *(const uint32_t *)pc;
        int64_t dst = -1;
        if ((w & 0xFC000000u) == 0x14000000u)      dst = (int64_t)pc + (sext(w & 0x03FFFFFFu, 26) << 2);
        else if ((w & 0xFF000010u) == 0x54000000u) dst = (int64_t)pc + (sext((w >> 5) & 0x7FFFFu, 19) << 2);
        else if ((w & 0x7E000000u) == 0x34000000u) dst = (int64_t)pc + (sext((w >> 5) & 0x7FFFFu, 19) << 2);
        else if ((w & 0x7E000000u) == 0x36000000u) dst = (int64_t)pc + (sext((w >> 5) & 0x3FFFu, 14) << 2);
        if (dst > (int64_t)target && dst < (int64_t)(target + len)) return true;
        if ((w & 0xFFFFFC1Fu) == 0xD65F0000u) break;   // RET - likely past the relevant code
    }
    return false;
}

// ---- install / uninstall -----------------------------------------------------------------------

op_inline_status_t op_inline_install(uintptr_t target, uint32_t hook_id) {
    if (target == 0 || (target & 3)) return OP_INLINE_ERR_BADARG;     // must be 4-byte aligned code

    pthread_mutex_lock(&g_lock);
    op_inline_status_t rc = OP_INLINE_OK;
    int slot = -1;
    for (int i = 0; i < OP_MAX_HOOKS; i++) {
        if (g_hooks[i].in_use && g_hooks[i].target == target) { rc = OP_INLINE_ERR_ALREADY; goto out; }
        if (slot < 0 && !g_hooks[i].in_use) slot = i;
    }
    if (slot < 0) { rc = OP_INLINE_ERR_NOMEM; goto out; }

    if (target_is_arm64e(target))            { rc = OP_INLINE_ERR_ARM64E;   goto out; }
    if (!target_is_executable(target, 4))    { rc = OP_INLINE_ERR_NOT_EXEC; goto out; }

    // Choose the patch form: a 4-byte B to a near trampoline (minimal clobber) when one is reachable,
    // else a 16-byte LDR x17/BR x17/.quad absolute patch (trampoline anywhere, full reach) - which
    // displaces 4 instructions, so it needs a ≥16-byte function with no internal branch into the
    // clobber window. x16/x17 (IP0/IP1) are dead at a function entry.
    void *page = alloc_near(target);
    int ninstr = 1;
    bool sixteen = false;
    if (!page) {
        if (!target_is_executable(target, 16))    { rc = OP_INLINE_ERR_NOT_EXEC; goto out; }
        if (internal_branch_into(target, 16))     { rc = OP_INLINE_ERR_UNRELOCATABLE; goto out; }
        page = alloc_any();
        if (!page)                                { rc = OP_INLINE_ERR_NOMEM; goto out; }
        ninstr = 4; sixteen = true;
    }
    uint32_t patch_len = (uint32_t)ninstr * 4;

    // Relocate the displaced instruction(s) into a temp buffer first so an unrelocatable instruction
    // aborts before anything is patched.
    uint32_t reloc[64]; int rn = 0;
    for (int i = 0; i < ninstr; i++) {
        int r = relocate_one(((const uint32_t *)target)[i], target + (uintptr_t)i * 4, reloc + rn);
        if (r < 0) { free_page(page); rc = OP_INLINE_ERR_UNRELOCATABLE; goto out; }
        rn += r;
    }

    // Layout in the page: [0x00] record, [0x40] entry stub, [0x80] call-original trampoline.
    OPHookRecord *rec   = (OPHookRecord *)page;
    uint32_t     *stub  = (uint32_t *)((uint8_t *)page + 0x40);
    uint32_t     *orig  = (uint32_t *)((uint8_t *)page + 0x80);

    // call-original trampoline: relocated prologue, then jump back past the patch.
    int m = 0;
    for (int i = 0; i < rn; i++) orig[m++] = reloc[i];
    m += emit_mov_abs(orig + m, 16, target + patch_len);
    orig[m++] = enc_br(16);

    // per-hook entry stub: x16 = &record, x17 = &shared_entry, br x17
    int n = 0;
    n += emit_mov_abs(stub + n, 16, (uint64_t)(uintptr_t)rec);
    n += emit_mov_abs(stub + n, 17, (uint64_t)(uintptr_t)&op_inline_shared_entry);
    stub[n++] = enc_br(17);

    rec->call_orig = (uint64_t)(uintptr_t)orig;
    rec->target    = (uint64_t)target;
    rec->hook_id   = hook_id;

    if (mprotect(page, OP_PAGE, PROT_READ | PROT_EXEC) != 0) {   // publish RX before any branch in
        free_page(page); rc = OP_INLINE_ERR_NOMEM; goto out;
    }
    sys_icache_invalidate(page, OP_PAGE);

    // Encode the patch.
    uint32_t patch[4];
    if (sixteen) {
        patch[0] = 0x58000051u;                                  // ldr x17, #8
        patch[1] = enc_br(17);                                   // br  x17
        patch[2] = (uint32_t)((uintptr_t)stub & 0xFFFFFFFFu);
        patch[3] = (uint32_t)((uintptr_t)stub >> 32);
    } else {
        int64_t boff = (int64_t)((uintptr_t)stub - target);
        if (boff <= -OP_B_RANGE || boff >= OP_B_RANGE) { free_page(page); rc = OP_INLINE_ERR_RANGE; goto out; }
        patch[0] = enc_b(boff);
    }

    g_hooks[slot].in_use    = true;
    g_hooks[slot].target    = target;
    g_hooks[slot].page      = page;
    g_hooks[slot].patch_len = patch_len;
    memcpy(g_hooks[slot].saved, (const void *)target, patch_len);

    if (!cow_write((void *)target, patch, patch_len)) {
        g_hooks[slot].in_use = false; free_page(page); rc = OP_INLINE_ERR_NOMEM; goto out;
    }

out:
    pthread_mutex_unlock(&g_lock);
    return rc;
}

// NOTE: there is currently no caller of op_inline_uninstall - inline hooks are installed once at
// launch from config and live for the process lifetime (config live-reload only *adds/updates* via
// idempotent install). The patched page is therefore quarantined-not-freed, and since uninstall is
// never reached, no page is ever actually leaked in practice (worst case if it were used: OP_MAX_HOOKS
// * OP_PAGE = 2 MiB, reclaimed by the OS at exit).
//
// Reclaiming the page safely is deliberately NOT done here. The page holds the per-hook stub and the
// call-original trampoline; on the RESUME path a thread tail-branches INTO this page after the Swift
// dispatcher returns and only leaves it when it branches back to the original function, so "no thread
// is mid-trampoline" cannot be proven from this thread alone. A correct reclaim requires global
// quiescence: suspend every other thread (task_threads + thread_suspend), read each PC via
// thread_get_state(ARM_THREAD_STATE64), and free a quarantined page only when (a) no thread's PC is
// in that page, (b) no thread's PC is in the shared-entry asm thunk, and (c) no thread is inside the
// dispatcher - which needs a hot-path busy counter bracketing the `bl _op_inline_dispatch[_leave]`
// calls in OPInlineAsm.s. That adds an atomic RMW to every hooked call. We do not pay that cost (nor
// risk the safety-critical thunk) to support a path that no code exercises. Wire this up together with
// a live hook-*removal* feature (uninstall on config reload), where the cost is justified.
op_inline_status_t op_inline_uninstall(uintptr_t target) {
    pthread_mutex_lock(&g_lock);
    op_inline_status_t rc = OP_INLINE_ERR_BADARG;
    for (int i = 0; i < OP_MAX_HOOKS; i++) {
        if (g_hooks[i].in_use && g_hooks[i].target == target) {
            cow_write((void *)target, g_hooks[i].saved, g_hooks[i].patch_len);
            // Quarantine the page (don't unmap: another thread may be mid-trampoline). See the note
            // above for the safe-reclaim design to add if/when this path gains a caller.
            g_hooks[i].in_use = false;
            g_hooks[i].page = NULL;
            rc = OP_INLINE_OK;
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return rc;
}

// ---- resolution helpers ------------------------------------------------------------------------

// --- ObjC object validation (all raw pointers; no Swift casts) ---------------------------------

static uintptr_t     *g_classes = NULL;
static unsigned       g_class_count = 0;
static pthread_once_t g_class_once = PTHREAD_ONCE_INIT;

static int cmp_uintptr(const void *a, const void *b) {
    uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;
    return (x < y) ? -1 : (x > y) ? 1 : 0;
}
static void build_class_set(void) {
    unsigned n = 0;
    Class *list = objc_copyClassList(&n);     // C: raw Class* array - no Swift cast machinery
    if (!list) return;
    g_classes = (uintptr_t *)malloc((size_t)n * sizeof(uintptr_t));
    if (g_classes) {
        for (unsigned i = 0; i < n; i++) g_classes[i] = (uintptr_t)list[i];
        g_class_count = n;
        qsort(g_classes, g_class_count, sizeof(uintptr_t), cmp_uintptr);
    }
    free(list);
}

bool op_inline_is_objc(uintptr_t obj) {
    if (obj == 0 || (obj & 7)) return false;
    if (!op_inline_ptr_readable(obj, 8)) return false;
    Class cls = object_getClass((id)(void *)obj);   // reads + masks the (non-pointer) isa
    if (!cls || !op_inline_ptr_readable((uintptr_t)cls, 8)) return false;
    pthread_once(&g_class_once, build_class_set);
    if (!g_classes) return false;
    uintptr_t key = (uintptr_t)cls;
    return bsearch(&key, g_classes, g_class_count, sizeof(uintptr_t), cmp_uintptr) != NULL;
}

bool op_inline_ptr_readable(uintptr_t addr, size_t len) {
    if (addr == 0 || len == 0) return false;
    vm_address_t a = (vm_address_t)addr;
    vm_size_t    s = 0;
    vm_region_basic_info_data_64_t bi;
    mach_msg_type_number_t c = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t o = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &a, &s, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&bi, &c, &o) != KERN_SUCCESS) return false;
    if (a > addr || addr + len > (uintptr_t)a + s) return false;
    return (bi.protection & VM_PROT_READ) != 0;
}

size_t op_inline_read_cstring(uintptr_t addr, char *buf, size_t max) {
    if (!buf || max == 0) return 0;
    buf[0] = '\0';
    if (addr == 0) return 0;
    vm_address_t a = (vm_address_t)addr;
    vm_size_t    s = 0;
    vm_region_basic_info_data_64_t bi;
    mach_msg_type_number_t c = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t o = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &a, &s, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&bi, &c, &o) != KERN_SUCCESS) return 0;
    if (a > addr || !(bi.protection & VM_PROT_READ)) return 0;
    size_t avail = ((uintptr_t)a + s) - addr;          // readable bytes from addr to region end
    size_t cap = max - 1; if (cap > avail) cap = avail;
    const char *p = (const char *)addr;
    size_t n = 0;
    while (n < cap && p[n] != '\0') { buf[n] = p[n]; n++; }
    buf[n] = '\0';
    return n;
}

uintptr_t op_inline_resolve_symbol(const char *symbol) {
    if (!symbol) return 0;
    return (uintptr_t)dlsym(RTLD_DEFAULT, symbol);
}

uintptr_t op_inline_follow_thunk(uintptr_t addr) {
    if (!addr || (addr & 3)) return addr;
    uint32_t w = *(const uint32_t *)addr;
    if ((w & 0xFC000000u) == 0x14000000u) {        // B imm26
        int64_t imm26 = (int64_t)(w & 0x03FFFFFFu);
        if (imm26 & 0x02000000) imm26 |= ~0x03FFFFFFll;   // sign-extend bit 25
        return addr + (uintptr_t)(imm26 << 2);
    }
    return addr;
}

uintptr_t op_inline_resolve_module_offset(const char *module_substr, uint64_t static_offset) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (module_substr && module_substr[0] && !strstr(name, module_substr)) continue;
        // runtime addr = static_offset + ASLR slide. static_offset is relative to the image's
        // preferred (link-time) base, which is what Ghidra reports.
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        return (uintptr_t)((intptr_t)static_offset + slide);
    }
    return 0;
}

uintptr_t op_inline_resolve_signature(const char *module_substr, const int *pattern, size_t len) {
    if (!pattern || len == 0) return 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (module_substr && module_substr[0] && !strstr(name, module_substr)) continue;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const uint8_t *cmd = (const uint8_t *)mh + sizeof(struct mach_header_64);
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cmd;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                if (strcmp(seg->segname, "__TEXT") == 0) {
                    const uint8_t *base = (const uint8_t *)(seg->vmaddr + slide);
                    if (seg->vmsize > len) {
                        for (uint64_t off = 0; off + len <= seg->vmsize; off++) {
                            const uint8_t *p = base + off;
                            size_t k = 0;
                            for (; k < len; k++) {
                                if (pattern[k] <= 0xFF && p[k] != (uint8_t)pattern[k]) break;
                            }
                            if (k == len) return (uintptr_t)p;
                        }
                    }
                }
            }
            cmd += lc->cmdsize;
        }
        return 0; // matched module, no hit
    }
    return 0;
}

#endif /* arm64 */
