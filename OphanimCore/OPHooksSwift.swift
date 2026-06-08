//
//  OPHooksSwift.swift
//  OphanimCore
//
//  Tier 2.5 - native-Swift vtable hooking (OPConfig.swiftHooks). Reaches overridable, non-@objc
//  Swift methods that ObjC swizzling can't, by overwriting the method's slot in the class's vtable
//  (stored in the Swift class metadata). Observe-only: the trampoline logs the call and forwards to
//  the original, preserving `self` (x20, callee-saved) and up to 3 register args.
//
//  Scope / caveats:
//   - arm64 only (hosted iOS apps are arm64 - no pointer-auth on their own vtables; an arm64e app
//     would need the slot pointer PAC-signed, which is not done here).
//   - Only VTABLE-dispatched calls are intercepted. The -O optimizer devirtualizes calls on a known
//     concrete type into direct calls that bypass the vtable; those (and pure static dispatch) need
//     inline hooking (Tier 3).
//   - Fixed pool of trampolines (no runtime codegen): up to OPSwiftHooks.poolSize hooks per process.
//   - Metadata parse is bounded by the class's own classSize, so a misparse fails safe (skips) rather
//     than reading unmapped memory.
//

import Foundation

enum OPSwiftHooks {
    static let poolSize = 16

    private struct Entry { var orig: UnsafeRawPointer?; var api: String; var category: OPCategory }
    private static var table = [Entry](repeating: Entry(orig: nil, api: "", category: .process), count: poolSize)
    private static var used = 0

    // The trampoline ABI: a Swift instance method passes `self` in x20 (callee-saved → survives) and
    // up to 3 args in x0–x2; a 3-pointer-arg C function reads x0–x2 (extra/unused for lower-arity
    // methods is harmless) and forwarding them to the original preserves the call. Value returns flow
    // through because the original is the last call (its x0 result isn't clobbered after).
    typealias Tramp = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> Void

    // A fixed pool of NON-capturing trampolines (each references a literal index → convertible to a C
    // function pointer). install() assigns each hook one slot of `table`.
    private static let pool: [Tramp] = [
        { a, b, c in h(0, a, b, c) },  { a, b, c in h(1, a, b, c) },  { a, b, c in h(2, a, b, c) },
        { a, b, c in h(3, a, b, c) },  { a, b, c in h(4, a, b, c) },  { a, b, c in h(5, a, b, c) },
        { a, b, c in h(6, a, b, c) },  { a, b, c in h(7, a, b, c) },  { a, b, c in h(8, a, b, c) },
        { a, b, c in h(9, a, b, c) },  { a, b, c in h(10, a, b, c) }, { a, b, c in h(11, a, b, c) },
        { a, b, c in h(12, a, b, c) }, { a, b, c in h(13, a, b, c) }, { a, b, c in h(14, a, b, c) },
        { a, b, c in h(15, a, b, c) }
    ]

    private static func h(_ i: Int, _ a: UnsafeRawPointer?, _ b: UnsafeRawPointer?, _ c: UnsafeRawPointer?) {
        let e = table[i]
        let ctx = OPCallContext(category: e.category, layer: .objc, api: e.api,
                                fields: ["dispatch": "swift-vtable"])
        let decision = OPAgent.shared.intercept(ctx)
        OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
        if decision.disposition == .delayed && decision.delay > 0 {
            Thread.sleep(forTimeInterval: decision.delay)
        }
        if decision.disposition == .blocked { return }   // suppress the call (void method)
        if let orig = e.orig {
            unsafeBitCast(orig, to: Tramp.self)(a, b, c)   // forward; self(x20)+args preserved
        }
    }

    /// Hooks already patched, keyed by class+method. Prevents re-patching the same vtable slot when
    /// install() is re-run on config live-reload (which would chain a second trampoline and leak a
    /// pool slot every reload).
    private static var patched = Set<String>()

    static func install() {
        let hooks = OPAgent.shared.config.swiftHooks
        guard !hooks.isEmpty else { return }
        for hook in hooks where OPAgent.shared.isActive(hook.category) {
            let result = patch(hook)
            // Re-run on every live-reload to pick up newly added hooks; don't re-log existing ones.
            if result.hasPrefix("already") { continue }
            OPAgent.shared.observe(OPEvent(category: hook.category, layer: .objc,
                api: "ophanim.swiftHook.install",
                summary: "\(hook.className) \(hook.method) → \(result)", fields: ["result": result]))
        }
    }

    private static func patch(_ hook: OPSwiftHook) -> String {
        let key = "\(hook.className) \(hook.method)"
        if patched.contains(key) { return "already-installed" }
        guard used < poolSize else { return "pool-full" }
        guard let cls = NSClassFromString(hook.className) else { return "class-not-found" }
        let meta = unsafeBitCast(cls, to: UnsafeMutableRawPointer.self)

        // Confirm it's a Swift class (data field at +32 carries the swift-class bit).
        let data = meta.load(fromByteOffset: 32, as: UInt.self)
        guard (data & 0x3) != 0 else { return "not-a-swift-class" }

        // The instantiated class metadata holds the live vtable: a run of function pointers between the
        // metadata header and classSize (@ +56). We DON'T use the descriptor's VTableOffset/VTableSize:
        // those describe only the methods THIS class introduces, so a pure-override subclass (e.g. one
        // that just overrides an inherited method) has an empty descriptor vtable even though its
        // metadata carries the overridden slot in the inherited region. Instead, scan the whole vtable
        // region and dladdr-match the method symbol - this finds introduced AND overridden slots.
        // Bounded by classSize so a misparse can't read unmapped memory. Header fields (isa/superclass/
        // descriptor/etc.) are metadata or data pointers; dladdr won't resolve them to the method
        // symbol, so starting the scan low is safe given the specific substring match.
        let classSize = Int(meta.load(fromByteOffset: 56, as: UInt32.self))
        guard classSize > 80, classSize < 1 << 20 else { return "vtable-parse-failed" }

        var slot: UnsafeMutableRawPointer?
        var matched = ""
        var off = 80   // past isa/superclass/cache/data/flags/descriptor/ivarDestroyer
        while off + 8 <= classSize {
            defer { off += 8 }
            guard let fn = meta.load(fromByteOffset: off, as: UnsafeRawPointer?.self) else { continue }
            var info = Dl_info()
            guard dladdr(fn, &info) != 0, let sname = info.dli_sname else { continue }
            let sym = String(cString: sname)
            // Require both the class name and the method, so an inherited-but-not-overridden slot
            // (which points at the *base* class's impl) doesn't shadow the intended class.
            if sym.contains(hook.method) { slot = meta.advanced(by: off); matched = sym; break }
        }
        guard let slot else { return "method-not-found" }

        let idx = used
        table[idx] = Entry(orig: slot.load(as: UnsafeRawPointer.self),
                           api: hook.api ?? matched, category: hook.category)
        used += 1

        let trampPtr = unsafeBitCast(pool[idx], to: UnsafeRawPointer.self)
        let pg = sysconf(Int32(_SC_PAGESIZE))
        let pageBase = UInt(bitPattern: slot) & ~(UInt(pg) - 1)
        _ = mprotect(UnsafeMutableRawPointer(bitPattern: pageBase), Int(pg), PROT_READ | PROT_WRITE)
        slot.storeBytes(of: trampPtr, as: UnsafeRawPointer.self)
        patched.insert(key)
        return "ok (\(matched))"
    }
}
