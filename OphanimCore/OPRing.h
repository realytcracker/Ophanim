//
//  OPRing.h
//  OphanimCore
//
//  Allocation-free, lock-free capture ring for low-level interpose hooks. The producer side
//  (op_ring_emit) is callable from ANY context - inside malloc's lock, post-fork, during dyld
//  init - because it only does atomics + memcpy and never allocates, locks, or calls ObjC/Swift.
//  A single consumer thread drains records and turns them into OPEvents on a normal thread.
//
//  SIBLING-MODE NOTE: this file is compiled into BOTH the Galgal runtime (embedded) and the
//  standalone agent dylib (sibling), so each image gets its OWN ring + consumer (separate statics).
//  This is harmless: a symbol Galgal AND the agent both interpose (process/socket/crypto/TLS/pinning,
//  all of which Galgal's *engine* leaves dormant in sibling mode) chains through both wrappers, but
//  only the started image's op_ring_emit enqueues - the dormant image's is a no-op (see op_ring_started,
//  which the wrappers check to also skip their formatting work). Raw C-level filesystem (open/stat/
//  access/rename/unlink) is captured in BOTH modes: embedded via Galgal's gg_* interposes, sibling via
//  OPHooksFSRaw.m's observe-only interposes (agent-only, -D OPHANIM_SIBLING) that chain through Galgal's
//  dormant gg_* - so sibling now has filesystem parity, plus the OPHooksFilesystem NSFileManager swizzle
//  for high-level ops (dir enumeration / attributes). Keychain stays Galgal-owned (gg_SecItem* do
//  *emulation* via KeychainShim, not observe) and is NOT re-interposed by the agent (hard rule), so
//  under sibling injection keychain is uncaptured. Embedded mode captures everything.
//

#ifndef OP_RING_H
#define OP_RING_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

// Re-export the Tier-3 inline-hook engine API through the shared bridging header so both the Galgal
// framework (via Galgal.h) and the sibling agent (via -import-objc-header OPRing.h) see it in Swift.
#include "OPInline.h"

/// Event kinds emitted by the C interpose wrappers. The Swift consumer (OPRingBridge) maps each to
/// an (OPCategory, api) pair. `str` carries a path/host/symbol; `arg` a scalar (mode/len/port).
typedef enum {
    OP_K_NONE = 0,
    OP_K_FS_OPEN, OP_K_FS_STAT, OP_K_FS_ACCESS, OP_K_FS_RENAME, OP_K_FS_UNLINK,
    OP_K_PROC_DLOPEN, OP_K_PROC_FORK, OP_K_PROC_SPAWN, OP_K_PROC_EXEC,
    OP_K_SOCK_CONNECT, OP_K_SOCK_GETADDRINFO,
    OP_K_TLS_READ, OP_K_TLS_WRITE,
    OP_K_KEYCHAIN_COPY, OP_K_KEYCHAIN_ADD, OP_K_KEYCHAIN_UPDATE, OP_K_KEYCHAIN_DELETE,
    OP_K_CRYPTO,
    OP_K_PINNING,   // SecTrust evaluation (certificate pinning). `str` = function name; arg = result.
} op_kind_t;

#define OP_STR_CAP  208
#define OP_BLOB_CAP 256

/// Enqueue one record. Safe in any context; drops (counted) when the ring is full. `str` may be
/// NULL; `blob`/`blob_len` may be 0. Never blocks.
void op_ring_emit(uint8_t kind, uint8_t flags, int32_t arg,
                  const char *str, const void *blob, uint16_t blob_len);

/// Start the single consumer thread (idempotent). Call once after the runloop is up - NOT during
/// dyld initialization. Until called, op_ring_emit is a cheap no-op.
void op_ring_start(void);

/// True once op_ring_start() has run in THIS image (i.e. this image's engine owns capture). Interpose
/// wrappers check it to skip even their address/plaintext formatting when their image is dormant -
/// in sibling mode Galgal's copy of each shared wrapper stays dormant and becomes a transparent thunk.
bool op_ring_started(void);

/// Set the active-category bitmask (bit i = OPCategory.allCases[i] is capturing). op_ring_emit
/// drops records for inactive categories before touching the ring, so a hot interpose (open/stat)
/// costs ~two atomic loads when its category is off. Set by the agent whenever config changes.
void op_ring_set_categories(uint32_t mask);

/// Records dropped because the ring was full (diagnostics).
uint64_t op_ring_dropped(void);

/// Enable/disable certificate-pinning bypass. When on, the SecTrust interpose forces trust
/// evaluation to succeed (defeating app-level pinning). Pinning checks are *logged* whenever the
/// network capture category is active (OP_K_PINNING is gated on it) - independent of this flag.
void op_set_bypass_pinning(bool on);

#endif /* OP_RING_H */
