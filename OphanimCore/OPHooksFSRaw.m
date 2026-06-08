//
//  OPHooksFSRaw.m
//  OphanimCore
//
//  Sibling-mode raw POSIX filesystem capture (open / stat / lstat / access / rename / unlink) via
//  DYLD_INTERPOSE. This closes the documented sibling-injection gap: in EMBEDDED mode Galgal owns
//  the C-level filesystem interposes (gg_open/gg_stat/... in GalgalLoader.m), but those are NOT
//  compiled into the standalone agent, so under sibling injection the only filesystem capture was the
//  ObjC-layer NSFileManager swizzle (OPHooksFilesystem) - which misses raw POSIX calls. This file
//  restores parity for the sibling agent.
//
//  SAFE in both modes by construction:
//    * It is gated with `#if defined(OPHANIM_SIBLING)` and is NOT a member of the Galgal Xcode target,
//      so the embedded runtime never compiles it - Galgal's gg_* interposes stay the sole FS capture
//      there (no double-capture). Only the agent build (build-agent.sh, with -D OPHANIM_SIBLING)
//      compiles it.
//    * In sibling mode both Galgal's gg_open and this op_fs_open interpose `open`; dyld chains the
//      call through both wrappers. Exactly one enqueues, because op_ring_emit is a no-op in the
//      dormant image (Galgal never started its ring) - the same proven chaining the process/socket/
//      crypto/TLS shared interposes rely on (see OPRing.h). The wrappers do nothing but emit into the
//      allocation-free ring and call the real function, so they are safe from any context.
//
//  Keychain is deliberately NOT mirrored here: Galgal's gg_SecItem* interposes do keychain
//  *emulation* (KeychainShim), not pure observe-and-chain, so re-interposing them risks the emulation
//  for little gain. Sibling keychain capture remains out of scope (documented in OPRing.h).
//

#if defined(OPHANIM_SIBLING)

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <stdarg.h>
#import "OPRing.h"

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
   _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
   { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

// open() is variadic: when O_CREAT (or O_TMPFILE, where defined) is set the caller passes a mode_t,
// which must be forwarded or the new file gets a garbage mode. (Stricter than Galgal's gg_open, which
// only forwards mode for an exact `oflag == O_CREAT`.)
static int op_fs_open(const char *path, int oflag, ...) {
    if (op_ring_started()) {
        op_ring_emit(OP_K_FS_OPEN, 0, oflag, path, NULL, 0);
    }
#ifdef O_TMPFILE
    int needs_mode = (oflag & O_CREAT) || (oflag & O_TMPFILE);
#else
    int needs_mode = (oflag & O_CREAT);
#endif
    if (needs_mode) {
        va_list ap; va_start(ap, oflag);
        int mode = va_arg(ap, int);
        va_end(ap);
        return open(path, oflag, mode);
    }
    return open(path, oflag);
}

static int op_fs_stat(const char *restrict path, struct stat *restrict buf) {
    if (op_ring_started()) {
        op_ring_emit(OP_K_FS_STAT, 0, 0, path, NULL, 0);
    }
    return stat(path, buf);
}

static int op_fs_lstat(const char *restrict path, struct stat *restrict buf) {
    if (op_ring_started()) {
        op_ring_emit(OP_K_FS_STAT, 0, 0, path, NULL, 0);
    }
    return lstat(path, buf);
}

static int op_fs_access(const char *path, int mode) {
    if (op_ring_started()) {
        op_ring_emit(OP_K_FS_ACCESS, 0, mode, path, NULL, 0);
    }
    return access(path, mode);
}

static int op_fs_rename(const char *old_name, const char *new_name) {
    if (op_ring_started()) {
        op_ring_emit(OP_K_FS_RENAME, 0, 0, old_name, NULL, 0);
    }
    return rename(old_name, new_name);
}

static int op_fs_unlink(const char *path) {
    if (op_ring_started()) {
        op_ring_emit(OP_K_FS_UNLINK, 0, 0, path, NULL, 0);
    }
    return unlink(path);
}

DYLD_INTERPOSE(op_fs_open, open)
DYLD_INTERPOSE(op_fs_stat, stat)
DYLD_INTERPOSE(op_fs_lstat, lstat)
DYLD_INTERPOSE(op_fs_access, access)
DYLD_INTERPOSE(op_fs_rename, rename)
DYLD_INTERPOSE(op_fs_unlink, unlink)

#endif /* OPHANIM_SIBLING */
