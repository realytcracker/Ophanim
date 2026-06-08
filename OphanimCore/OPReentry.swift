//
//  OPReentry.swift
//  OphanimCore
//
//  Thread-local re-entrancy guard. Hooks must not instrument the agent's OWN work - e.g. the log
//  sinks perform file I/O (open/stat) and os_log, which would re-trigger the filesystem hooks and
//  recurse until the stack overflows. While the guard is set on a thread, all hook bridges skip
//  logging (the original function still runs). pthread-based so the guard itself never allocates.
//

import Foundation

enum OPReentry {
    private static var key: pthread_key_t = {
        var k = pthread_key_t()
        pthread_key_create(&k, nil)
        return k
    }()

    static var active: Bool {
        get { pthread_getspecific(key) != nil }
        set { pthread_setspecific(key, newValue ? UnsafeRawPointer(bitPattern: 1) : nil) }
    }

    /// Run `body` with the guard set (and restored afterward).
    static func guarded(_ body: () -> Void) {
        let was = active
        active = true
        defer { active = was }
        body()
    }
}
