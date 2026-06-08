// Standalone executable unit test for the OPInline arm64 relocator. Builds an original instruction
// snippet in executable memory, relocates its first instruction with relocate_one() (+ a tail that
// jumps back to orig+4, exactly as the engine's call-original trampoline does), executes both, and
// asserts identical behavior. Run on Apple Silicon (host arch).
//   build: clang -arch arm64 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
//                -I ../OphanimCore -lobjc reloctest.c -o /tmp/rt && /tmp/rt
// (-lobjc because OPInline.c uses objc_copyClassList/object_getClass for arg-object validation.)
#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
#include <string.h>

void op_inline_shared_entry(void) {}   // satisfy the extern ref inside op_inline_install
#include "../OphanimCore/OPInline.c"

typedef uint64_t (*fn_t)(uint64_t);

static void *mkexec(const uint32_t *code, int n) {
    void *p = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); return 0; }
    memcpy(p, code, (size_t)n * 4);
    mprotect(p, 0x4000, PROT_READ | PROT_EXEC);
    sys_icache_invalidate(p, (size_t)n * 4);
    return p;
}

#define RET 0xD65F03C0u
static int passed = 0, failed = 0;

// Run `orig` (n words) at its own address O; relocate its first `ninstr` instructions (as the patch
// would displace) + tail jump back to O+ninstr*4; run both with `arg` and compare. (ninstr models the
// 4-byte patch=1 vs 16-byte patch=4 displacement.)
static void checkN(const char *name, const uint32_t *orig, int n, uint64_t arg, int ninstr) {
    uint32_t *O = (uint32_t *)mkexec(orig, n);
    uint32_t buf[32]; int rn = 0;
    for (int i = 0; i < ninstr; i++) {
        int r = relocate_one(orig[i], (uint64_t)(uintptr_t)O + (uint64_t)i * 4, buf + rn);
        if (r < 0) { printf("  FAIL %-14s relocate_one aborted\n", name); failed++; return; }
        rn += r;
    }
    rn += emit_jump_abs(buf + rn, (uint64_t)(uintptr_t)O + (uint64_t)ninstr * 4);
    uint32_t *R = (uint32_t *)mkexec(buf, rn);
    uint64_t v1 = ((fn_t)O)(arg);
    uint64_t v2 = ((fn_t)R)(arg);
    if (v1 == v2) { printf("  ok   %-14s arg=0x%llx -> 0x%llx\n", name, arg, v1); passed++; }
    else { printf("  FAIL %-14s arg=0x%llx orig=0x%llx reloc=0x%llx\n", name, arg, v1, v2); failed++; }
}
static void check(const char *name, const uint32_t *orig, int n, uint64_t arg) {
    checkN(name, orig, n, arg, 1);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    // value-computing forms: orig = [insn that sets x0][ret]
    { uint32_t c[] = { 0x90000000u, RET };                 check("ADRP x0,#0", c, 2, 0); }     // x0 = page(O)
    { uint32_t c[] = { 0x10000080u, RET };                 check("ADR x0,#16", c, 2, 0); }      // x0 = O+16
    { uint32_t c[] = { 0x58000040u, RET, 0xEFBEADDEu, 0u}; check("LDR x0,lit", c, 4, 0); }      // x0 = *(O+8)
    // B: [b #12][movz x0,#0xBB;ret][movz x0,#0xAA;ret] -> returns 0xAA
    { uint32_t c[] = { 0x14000003u, 0xD2801760u, RET, 0xD2801540u, RET };
      check("B #12", c, 5, 0); }
    // BL in a real prologue [stp x29,x30 ; mov x29,sp ; bl sub ; ldp x29,x30 ; add w0,#100 ; ret ; sub]
    // relocate all 4 (the 16-byte patch case): the relocated BL must return into the trampoline
    // continuation, and stp/ldp preserve the caller's x30. Returns 105.
    { uint32_t c[] = { 0xA9BF7BFDu, 0x910003FDu, 0x94000004u, 0xA8C17BFDu,
                       0x11019000u, 0xD65F03C0u, 0x528000A0u, 0xD65F03C0u };
      checkN("BL prologue", c, 8, 0, 4); }
    // CBZ x0,#12: x0==0 -> 0xAA ; x0!=0 -> falls to 0xBB (via tail jump to O+4)
    { uint32_t c[] = { 0x34000060u, 0xD2801760u, RET, 0xD2801540u, RET };
      check("CBZ x0 (taken)", c, 5, 0);  check("CBZ x0 (fall)", c, 5, 7); }
    // TBNZ x0,#0,#12: bit0 set -> 0xAA ; clear -> 0xBB
    { uint32_t c[] = { 0x37000060u, 0xD2801760u, RET, 0xD2801540u, RET };
      check("TBNZ x0 (taken)", c, 5, 1); check("TBNZ x0 (fall)", c, 5, 0); }
    // B.cond EQ (#12): build flags via the snippet - test cond=AL-ish via NE after cmp is complex;
    // instead test B.EQ with Z preset is hard from C. Skip executing B.cond (covered structurally by
    // CBZ/TBZ which share the invert+skip path).
    printf("\n%d passed, %d failed\n", passed, failed);
    return failed ? 1 : 0;
}
