//
//  OPHooksTLS.m
//  OphanimCore
//
//  TLS-plaintext capture via DYLD_INTERPOSE. Two stacks:
//
//  1) boringssl SSL_read/SSL_write - weak-imported; these are Apple's in-shared-cache TLS used by
//     URLSession/Network.framework. NOTE: in practice these rarely fire, because in-cache callers
//     don't go through an interposable stub (the app doesn't *import* SSL_read). Kept fail-open.
//
//  2) Secure Transport SSLRead/SSLWrite (Security.framework) - STRONG imports that apps which use
//     the classic Secure Transport API (or libraries built on it) actually link against, so
//     DYLD_INTERPOSE *does* rebind their calls. Many apps that bundle their own stack (e.g. Cronet
//     over QUIC) still use Secure Transport for some connections - this captures that plaintext, a
//     path neither the boringssl interpose nor the URLProtocol layer reaches.
//
//  Observe-only (rewriting mid-stream would corrupt the connection). Allocation-free: just
//  op_ring_emit (atomics + memcpy of up to OP_BLOB_CAP bytes). Self-gates on the .network category.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "OPRing.h"

// Secure Transport (SSLRead/SSLWrite/SSLContextRef) is deprecated but still widely linked; silence.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
   _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
   { (const void *)(unsigned long)(void *)&_replacement, (const void *)(unsigned long)(void *)&_replacee };

// --- boringssl (weak; in-cache, rarely interposable) ---
extern int SSL_read(void *ssl, void *buf, int num) __attribute__((weak_import));
extern int SSL_write(void *ssl, const void *buf, int num) __attribute__((weak_import));

static int op_SSL_read(void *ssl, void *buf, int num) {
    int r = SSL_read(ssl, buf, num);            // not rebound for this image → calls the real one
    if (op_ring_started() && r > 0 && buf) {    // dormant image (sibling Galgal): transparent thunk
        op_ring_emit(OP_K_TLS_READ, 0, r, NULL, buf, (uint16_t)(r > 0 ? r : 0));
    }
    return r;
}

static int op_SSL_write(void *ssl, const void *buf, int num) {
    if (op_ring_started() && num > 0 && buf) {
        op_ring_emit(OP_K_TLS_WRITE, 0, num, NULL, buf, (uint16_t)num);
    }
    return SSL_write(ssl, buf, num);
}

DYLD_INTERPOSE(op_SSL_read, SSL_read)
DYLD_INTERPOSE(op_SSL_write, SSL_write)

// --- Apple Secure Transport (strong import; apps that link it ARE interposable) ---
static OSStatus op_SSLRead(SSLContextRef ctx, void *data, size_t dataLength, size_t *processed) {
    OSStatus s = SSLRead(ctx, data, dataLength, processed);   // real (not rebound for this image)
    if (op_ring_started() && (s == errSSLWouldBlock || s == noErr)) {
        size_t n = processed ? *processed : 0;
        if (n > 0 && data) {
            op_ring_emit(OP_K_TLS_READ, 0, (int32_t)n, NULL, data,
                         (uint16_t)(n > OP_BLOB_CAP ? OP_BLOB_CAP : n));
        }
    }
    return s;
}

static OSStatus op_SSLWrite(SSLContextRef ctx, const void *data, size_t dataLength, size_t *processed) {
    if (op_ring_started() && dataLength > 0 && data) {
        op_ring_emit(OP_K_TLS_WRITE, 0, (int32_t)dataLength, NULL, data,
                     (uint16_t)(dataLength > OP_BLOB_CAP ? OP_BLOB_CAP : dataLength));
    }
    return SSLWrite(ctx, data, dataLength, processed);
}

DYLD_INTERPOSE(op_SSLRead, SSLRead)
DYLD_INTERPOSE(op_SSLWrite, SSLWrite)
