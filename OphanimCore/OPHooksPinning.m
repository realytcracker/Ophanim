//
//  OPHooksPinning.m
//  OphanimCore
//
//  Certificate-pinning observation + bypass via DYLD_INTERPOSE on Security.framework's trust
//  evaluation entry points (SecTrustEvaluateWithError, and the deprecated SecTrustEvaluate). Most
//  app-level pinning - TrustKit, AFNetworking, Alamofire ServerTrustManager, and hand-rolled
//  NSURLSession `didReceiveChallenge:` validators - ultimately calls one of these to decide whether
//  to accept the server's certificate chain. Those call sites live in the app binary and its
//  embedded frameworks (NOT the dyld shared cache), so DYLD_INTERPOSE rebinds them.
//
//  Behaviour is gated by the per-app `bypassPinning` flag (op_set_bypass_pinning):
//    - OFF (default): transparent passthrough - call the original, return its result, emit nothing.
//    - ON: force the evaluation to succeed (so pinning can't reject our re-signed/MITM'd chain) AND
//          emit an OP_K_PINNING event so each pinning check is visible in the log.
//
//  This does NOT reach pinning done inside the dyld shared cache or a statically-linked TLS stack
//  (e.g. Cronet/BoringSSL, as Snapchat uses) - DYLD_INTERPOSE can't rebind intra-cache calls. It is
//  the right tool for the common SecTrust-based pinning, not custom in-cache verification.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <stdatomic.h>
#import "OPRing.h"

// SecTrustEvaluate is deprecated in favor of SecTrustEvaluateWithError, but apps still call it,
// so we must interpose it too. Silence the deprecation diagnostic for this file.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
   _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
   { (const void *)(unsigned long)(void *)&_replacement, (const void *)(unsigned long)(void *)&_replacee };

static atomic_bool g_bypass_pinning = false;

void op_set_bypass_pinning(bool on) {
    atomic_store_explicit(&g_bypass_pinning, on, memory_order_relaxed);
}

// SecTrustEvaluateWithError (modern, iOS 12+/macOS 10.14+). Returns true if the chain is trusted.
// NOTE: we intentionally do NOT interpose the deprecated SecTrustEvaluate - interposing that
// (a strong shared-cache symbol with a compatibility shim) triggers a process-wide malloc-type
// recursion on macOS 15 that crashes the host app at launch. The modern API is what current
// pinning libraries use.
static Boolean op_SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef *error) {
    bool bypass = atomic_load_explicit(&g_bypass_pinning, memory_order_relaxed);
    Boolean original = SecTrustEvaluateWithError(trust, error);   // not rebound for this image → real one
    // Logged under the network capture category - op_ring_emit drops this cheaply when network
    // capture is off (OP_K_PINNING maps to the network bit). flags: bit0 rejected, bit1 bypassed.
    op_ring_emit(OP_K_PINNING, (uint8_t)((original ? 0 : 1) | (bypass ? 2 : 0)),
                 bypass ? 1 : 0, "SecTrustEvaluateWithError", NULL, 0);
    if (bypass) {
        if (error) *error = NULL;
        return true;                                      // force-accept
    }
    return original;
}

DYLD_INTERPOSE(op_SecTrustEvaluateWithError, SecTrustEvaluateWithError)
