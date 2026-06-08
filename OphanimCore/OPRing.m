//
//  OPRing.m
//  OphanimCore
//
//  Implementation of the capture ring (see OPRing.h). Written in C (in a .m file so the manual
//  agent build's `*.m` glob picks it up). A bounded MPMC queue with per-cell sequence numbers
//  (Vyukov): producers fetch_add a position and publish via the cell's seq; the single consumer
//  drains and hands records to the Swift bridge.
//

#import "OPRing.h"
#import <stdatomic.h>
#import <string.h>
#import <pthread.h>
#import <unistd.h>
#import <Foundation/Foundation.h>

// Consumer-side bridge implemented in Swift (@objc OPRingBridge). Runs only on the drain thread.
@interface OPRingBridge : NSObject
+ (void)emitKind:(int)kind flags:(int)flags arg:(int)arg
             str:(const char *)str blob:(const void *)blob blobLen:(int)blobLen tid:(uint64_t)tid;
+ (void)emitDropped:(uint64_t)total;
@end

typedef struct {
    _Atomic uint64_t seq;
    uint8_t  kind;
    uint8_t  flags;
    int32_t  arg;
    uint64_t tid;
    uint16_t blob_len;
    char     str[OP_STR_CAP];
    uint8_t  blob[OP_BLOB_CAP];
} op_cell_t;

#define OP_RING_SIZE 8192               // power of two
#define OP_RING_MASK (OP_RING_SIZE - 1)

// Heap-allocated once in op_ring_start (a safe context) rather than a multi-MB static BSS array,
// which bloats __DATA vmsize. The producer only ever touches it once g_started is set (release/
// acquire), by which point g_ring is a valid, fully-initialized pointer.
static op_cell_t       *g_ring = NULL;
static _Atomic uint64_t g_enq = 0;       // next producer position
static _Atomic uint64_t g_deq = 0;       // next consumer position (single consumer)
static _Atomic uint64_t g_dropped = 0;
static _Atomic int      g_started = 0;
static _Atomic uint32_t g_cat_mask = 0;      // active OPCategory bits (set by op_ring_set_categories)
static __thread int     t_is_consumer = 0;   // set on the drain thread so it never self-enqueues

void op_ring_set_categories(uint32_t mask) {
    atomic_store_explicit(&g_cat_mask, mask, memory_order_relaxed);
}

// Bit (matching OPCategory.allCases order: network,keychain,crypto,device,privacy,filesystem,
// process,jailbreak) gating a record's kind. 0 = always allow (e.g. the agent's own boot event).
static uint32_t op_kind_cat_bit(uint8_t kind) {
    switch (kind) {
        case OP_K_FS_OPEN: case OP_K_FS_STAT: case OP_K_FS_ACCESS:
        case OP_K_FS_RENAME: case OP_K_FS_UNLINK:                 return 1u << 5;  // filesystem
        case OP_K_PROC_DLOPEN: case OP_K_PROC_FORK:
        case OP_K_PROC_SPAWN: case OP_K_PROC_EXEC:                return 1u << 6;  // process
        case OP_K_SOCK_CONNECT: case OP_K_SOCK_GETADDRINFO:
        case OP_K_TLS_READ: case OP_K_TLS_WRITE:
        case OP_K_PINNING:                                        return 1u << 0;  // network
        case OP_K_KEYCHAIN_COPY: case OP_K_KEYCHAIN_ADD:
        case OP_K_KEYCHAIN_UPDATE: case OP_K_KEYCHAIN_DELETE:     return 1u << 1;  // keychain
        case OP_K_CRYPTO:                                         return 1u << 2;  // crypto
        default:                                                  return 0;
    }
}

void op_ring_emit(uint8_t kind, uint8_t flags, int32_t arg,
                  const char *str, const void *blob, uint16_t blob_len) {
    if (t_is_consumer) return;                                   // drain thread must not enqueue
    if (!atomic_load_explicit(&g_started, memory_order_acquire)) return;
    uint32_t bit = op_kind_cat_bit(kind);                        // skip inactive categories cheaply
    if (bit && !(atomic_load_explicit(&g_cat_mask, memory_order_relaxed) & bit)) return;

    uint64_t pos = atomic_fetch_add_explicit(&g_enq, 1, memory_order_relaxed);
    op_cell_t *c = &g_ring[pos & OP_RING_MASK];
    uint64_t seq = atomic_load_explicit(&c->seq, memory_order_acquire);
    if (seq != pos) {                                            // cell not free → ring full
        atomic_fetch_add_explicit(&g_dropped, 1, memory_order_relaxed);
        return;
    }
    c->kind = kind;
    c->flags = flags;
    c->arg = arg;
    uint64_t tid = 0; pthread_threadid_np(NULL, &tid); c->tid = tid;
    if (str) { strlcpy(c->str, str, OP_STR_CAP); } else { c->str[0] = '\0'; }
    c->blob_len = 0;
    if (blob && blob_len) {
        uint16_t n = blob_len > OP_BLOB_CAP ? OP_BLOB_CAP : blob_len;
        memcpy(c->blob, blob, n);
        c->blob_len = n;
    }
    atomic_store_explicit(&c->seq, pos + 1, memory_order_release);   // publish
}

uint64_t op_ring_dropped(void) {
    return atomic_load_explicit(&g_dropped, memory_order_relaxed);
}

bool op_ring_started(void) {
    return atomic_load_explicit(&g_started, memory_order_acquire) != 0;
}

static void *op_ring_consumer(void *unused) {
    (void)unused;
    t_is_consumer = 1;
    pthread_setname_np("be.ophanim.ringdrain");
    uint64_t reported_drops = 0;
    for (;;) {
        uint64_t pos = atomic_load_explicit(&g_deq, memory_order_relaxed);
        op_cell_t *c = &g_ring[pos & OP_RING_MASK];
        uint64_t seq = atomic_load_explicit(&c->seq, memory_order_acquire);
        if (seq == pos + 1) {                                    // a record is ready
            uint8_t kind = c->kind, flags = c->flags;
            int32_t arg = c->arg;
            uint64_t tid = c->tid;
            uint16_t bl = c->blob_len;
            char str[OP_STR_CAP];   memcpy(str, c->str, OP_STR_CAP);
            uint8_t blob[OP_BLOB_CAP]; if (bl) memcpy(blob, c->blob, bl);
            atomic_store_explicit(&c->seq, pos + OP_RING_SIZE, memory_order_release);  // free cell
            atomic_store_explicit(&g_deq, pos + 1, memory_order_relaxed);
            @autoreleasepool {
                [OPRingBridge emitKind:kind flags:flags arg:arg
                                   str:str blob:(bl ? blob : NULL) blobLen:bl tid:tid];
            }
        } else {
            // Caught up: if records were dropped (ring was full), surface the new total once.
            uint64_t d = atomic_load_explicit(&g_dropped, memory_order_relaxed);
            if (d != reported_drops) {
                reported_drops = d;
                @autoreleasepool { [OPRingBridge emitDropped:d]; }
            }
            usleep(2000);                                         // idle 2ms
        }
    }
    return NULL;
}

static _Atomic int g_starting = 0;

void op_ring_start(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&g_starting, &expected, 1,
                                                 memory_order_acq_rel, memory_order_relaxed)) {
        return;                                                   // start already in progress/done
    }
    op_cell_t *ring = calloc(OP_RING_SIZE, sizeof(op_cell_t));
    if (!ring) { return; }
    for (uint64_t i = 0; i < OP_RING_SIZE; i++) {
        atomic_store_explicit(&ring[i].seq, i, memory_order_relaxed);
    }
    g_ring = ring;
    pthread_t th;
    if (pthread_create(&th, NULL, op_ring_consumer, NULL) != 0) {
        free(ring); g_ring = NULL;
        return;
    }
    pthread_detach(th);
    atomic_store_explicit(&g_started, 1, memory_order_release);   // publish: ring + thread ready
}
