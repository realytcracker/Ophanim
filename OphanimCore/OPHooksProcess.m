//
//  OPHooksProcess.m
//  OphanimCore
//
//  Process / dynamic-loading hooks via DYLD_INTERPOSE: dlopen, fork, posix_spawn. None of these
//  are interposed by Galgal, so this is safe in both injection modes. Useful for spotting anti-
//  debug / jailbreak-probe behavior (e.g. fork attempts the sandbox denies) and what the app
//  dynamically loads - including launches that hang on a handoff.
//
//  These fire from hostile contexts (during library loading, post-fork), so the wrappers do NOTHING
//  but enqueue into the allocation-free capture ring (op_ring_emit) and call the real function. The
//  ring's consumer thread turns records into OPEvents on a safe thread; op_ring_emit is a cheap
//  no-op until the agent starts the consumer.
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <spawn.h>
#import <unistd.h>
#import "OPRing.h"

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
   _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
   { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

static void *op_dlopen(const char *path, int mode) {
    if (op_ring_started()) {   // dormant image (sibling Galgal): transparent thunk
        op_ring_emit(OP_K_PROC_DLOPEN, 0, mode, path, NULL, 0);
    }
    return dlopen(path, mode);
}

static pid_t op_fork(void) {
    if (op_ring_started()) {
        op_ring_emit(OP_K_PROC_FORK, 0, 0, NULL, NULL, 0);
    }
    return fork();
}

static int op_posix_spawn(pid_t *pid, const char *path,
                          const posix_spawn_file_actions_t *file_actions,
                          const posix_spawnattr_t *attrp,
                          char *const argv[], char *const envp[]) {
    if (op_ring_started()) {
        op_ring_emit(OP_K_PROC_SPAWN, 0, 0, path, NULL, 0);
    }
    return posix_spawn(pid, path, file_actions, attrp, argv, envp);
}

DYLD_INTERPOSE(op_dlopen, dlopen)
DYLD_INTERPOSE(op_fork, fork)
DYLD_INTERPOSE(op_posix_spawn, posix_spawn)
