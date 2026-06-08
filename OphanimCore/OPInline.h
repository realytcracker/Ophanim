//
//  OPInline.h
//  OphanimCore
//
//  Tier 3 - clean-room arm64 INLINE hooking engine (frida/Dobby-style), implemented from first
//  principles. Patches a function's machine code in memory to divert execution through a trampoline,
//  reaching code that ObjC swizzling, Swift-vtable patching, and DYLD_INTERPOSE can't (statically
//  linked / stripped / static-dispatch functions). Located by absolute address, module+offset, or
//  byte signature.
//
//  arm64 ONLY (Apple Silicon; hosted apps are arm64, not arm64e → no PAC on their own code). The
//  engine refuses arm64e targets. Patching uses copy-on-write (VM_PROT_COPY) so it is in-process and
//  ephemeral - it never modifies the on-disk binary or the dyld shared cache. Live code patching is
//  riskier than the other hook types, so it is gated behind an explicit per-app toggle upstream.
//

#ifndef OP_INLINE_H
#define OP_INLINE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/// Saved CPU state handed to the dispatcher. The byte layout MUST stay in lockstep with the offsets
/// hard-coded in OPInlineAsm.s (the shared entry thunk). Integer regs x0–x30, then sp/pc/nzcv, then
/// the FP/SIMD arg registers q0–q7 (preserved across the dispatch call; also exposes float args).
typedef struct {
    uint64_t x[31];        // x0..x30                          @ 0x000
    uint64_t sp;           // caller sp at function entry      @ 0x0F8
    uint64_t pc;           // = the hooked target address      @ 0x100
    uint64_t nzcv;         // condition flags                  @ 0x108
    uint64_t q[16];        // v0..v7 (FP/SIMD), 2 words each    @ 0x110 (plain u64 so Swift imports it)
} OPCpuContext;            // sizeof == 0x190

/// Dispatcher return codes.
#define OP_INLINE_RESUME       0   // run the original (ctx args may have been modified), transparent tail-jump
#define OP_INLINE_REPLACE      1   // skip the original; return to the caller with ctx->x[0..7]
#define OP_INLINE_RESUME_LEAVE 2   // run the original (via BL), then call the leave dispatcher with its
                                   // return in ctx->x[0..1] before returning to the caller

/// Install / resolution status.
typedef enum {
    OP_INLINE_OK = 0,
    OP_INLINE_ERR_ALREADY,        // address is already hooked
    OP_INLINE_ERR_ARM64E,         // target image is arm64e (PAC) - refused
    OP_INLINE_ERR_NOT_EXEC,       // target not in a mapped executable region / unknown image
    OP_INLINE_ERR_UNRELOCATABLE,  // prologue can't be safely relocated (fail-safe abort)
    OP_INLINE_ERR_RANGE,          // no trampoline arena reachable by the patch branch
    OP_INLINE_ERR_NOMEM,          // arena/allocation failure
    OP_INLINE_ERR_BADARG,
} op_inline_status_t;

/// Install an inline hook at absolute runtime address `target`. `hook_id` is echoed back to the
/// dispatcher so the Swift side can find the per-hook config. Idempotent per address.
op_inline_status_t op_inline_install(uintptr_t target, uint32_t hook_id);

/// Remove a previously installed hook (restores the original bytes). The trampoline page is
/// quarantined, not unmapped (other threads may still be mid-trampoline).
op_inline_status_t op_inline_uninstall(uintptr_t target);

/// The dispatcher - implemented in Swift via @_cdecl("op_inline_dispatch"). Called from the shared
/// entry thunk with the hook id and a pointer to the saved CPU context. Returns RESUME / REPLACE /
/// RESUME_LEAVE.
extern int op_inline_dispatch(uint32_t hook_id, OPCpuContext *ctx);

/// The leave dispatcher (RESUME_LEAVE path) - implemented in Swift via @_cdecl. Called after the
/// original returns, with its return value in ctx->x[0..1]; may modify them before the caller sees it.
extern void op_inline_dispatch_leave(uint32_t hook_id, OPCpuContext *ctx);

// --- target resolution helpers ---

/// dlsym(RTLD_DEFAULT, symbol) - resolve an exported symbol to a runtime address (0 if not found).
uintptr_t op_inline_resolve_symbol(const char *symbol);

/// True if `obj` looks like a valid Objective-C instance: a readable, 8-aligned pointer whose class
/// (decoded from the isa) is a registered runtime class. Does the whole check in C with raw class
/// pointers (no Swift cast machinery, which crashes on pathological classes). The Swift renderer calls
/// this before bridging a register value to an object.
bool op_inline_is_objc(uintptr_t obj);

/// True if [addr, addr+len) is a mapped, readable region. Used by the Swift arg renderers to validate
/// a register value before treating it as an ObjC object pointer / C string (never crash on garbage).
bool op_inline_ptr_readable(uintptr_t addr, size_t len);

/// Copy a NUL-terminated C string at `addr` into `buf` (<= max-1 bytes + NUL), bounded by the readable
/// extent of the containing region. Returns the length copied (0 if unreadable). Safe on garbage.
size_t op_inline_read_cstring(uintptr_t addr, char *buf, size_t max);

/// If `addr` is a one-instruction thunk (an unconditional `B`), return its branch target; else return
/// `addr` unchanged. dlsym of an exported Swift/@_cdecl symbol often yields such a thunk to the real
/// body, so following it once lands on the function we actually want to hook.
uintptr_t op_inline_follow_thunk(uintptr_t addr);

/// Resolve module (matched by a substring of its dyld path, e.g. the executable or a framework) +
/// a file/static offset (the value Ghidra reports, relative to the image's preferred base) to a
/// runtime address, accounting for ASLR slide. Returns 0 if the module isn't loaded.
uintptr_t op_inline_resolve_module_offset(const char *module_substr, uint64_t static_offset);

/// Scan a module's executable text for a byte signature (wildcard byte = 0x100 in `pattern`, which
/// is an array of `len` ints). Returns the first match's runtime address, or 0.
uintptr_t op_inline_resolve_signature(const char *module_substr, const int *pattern, size_t len);

#endif /* OP_INLINE_H */
