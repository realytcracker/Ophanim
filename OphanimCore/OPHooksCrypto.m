//
//  OPHooksCrypto.m
//  OphanimCore
//
//  Symmetric-crypto / HMAC visibility via DYLD_INTERPOSE on CommonCrypto's CCCrypt and CCHmac.
//  Not interposed by Galgal → safe in both modes. The wrappers only enqueue into the allocation-
//  free capture ring (op_ring_emit) - no Swift/alloc on the hot path. flags carries the operation
//  (0=decrypt, 1=encrypt, 2=hmac); arg carries the input length. Self-gates on the .crypto category.
//

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#import "OPRing.h"

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
   _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
   { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

static CCCryptorStatus op_CCCrypt(CCOperation op, CCAlgorithm alg, CCOptions options,
                                  const void *key, size_t keyLength, const void *iv,
                                  const void *dataIn, size_t dataInLength,
                                  void *dataOut, size_t dataOutAvailable, size_t *dataOutMoved) {
    if (op_ring_started()) {   // dormant image (sibling Galgal): transparent thunk
        op_ring_emit(OP_K_CRYPTO, (op == kCCEncrypt ? 1 : 0), (int32_t)dataInLength, "CCCrypt", NULL, 0);
    }
    return CCCrypt(op, alg, options, key, keyLength, iv, dataIn, dataInLength,
                   dataOut, dataOutAvailable, dataOutMoved);
}

static void op_CCHmac(CCHmacAlgorithm algorithm, const void *key, size_t keyLength,
                      const void *data, size_t dataLength, void *macOut) {
    if (op_ring_started()) {
        op_ring_emit(OP_K_CRYPTO, 2, (int32_t)dataLength, "CCHmac", NULL, 0);
    }
    CCHmac(algorithm, key, keyLength, data, dataLength, macOut);
}

DYLD_INTERPOSE(op_CCCrypt, CCCrypt)
DYLD_INTERPOSE(op_CCHmac, CCHmac)
