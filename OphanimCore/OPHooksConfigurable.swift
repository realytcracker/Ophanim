//
//  OPHooksConfigurable.swift
//  OphanimCore
//
//  User-specified ObjC boundary hooks (OPConfig.objcHooks). Swizzle an arbitrary (class, selector)
//  and log the call + its object arguments - capturing NSData as a body and NSString as a field.
//  This is the Tier-2 "language boundary" instrument: the high-value capture point for statically-
//  linked apps and SDKs is where their C/C++ hands decoded data to @objc code. Pure-Swift (non-@objc)
//  methods aren't reachable here - those need inline hooking.
//
//  Safety: only VOID methods are hooked (the dominant data-delivery/callback shape, e.g.
//  `-didReceiveData:`). Hooking a value-returning method with a void wrapper would corrupt the
//  return register, so those are skipped. Each (class, selector) is hooked at most once.
//

import Foundation
import ObjectiveC.runtime

enum OPConfigurableHooks {
    private static var installed = Set<String>()

    static func install() {
        let hooks = OPAgent.shared.config.objcHooks
        guard !hooks.isEmpty else { return }
        for h in hooks where OPAgent.shared.isActive(h.category) {
            let result = swizzle(h)
            // install() is re-run on every config live-reload to pick up newly added hooks; don't
            // re-log the ones already installed on a prior pass (swizzle() returns "already-installed").
            if result.hasPrefix("already") { continue }
            OPAgent.shared.observe(OPEvent(category: h.category, layer: .objc,
                api: "ophanim.objcHook.install",
                summary: "\(h.className).\(h.selector) → \(result)", fields: ["result": result]))
        }
    }

    @discardableResult
    private static func swizzle(_ h: OPObjCHook) -> String {
        let key = "\(h.classMethod ? "+" : "-")[\(h.className) \(h.selector)]"
        if installed.contains(key) { return "already-installed" }
        guard let base = NSClassFromString(h.className) else { return "class-not-found" }
        let cls: AnyClass = h.classMethod ? (object_getClass(base) ?? base) : base
        let sel = NSSelectorFromString(h.selector)
        guard let m = class_getInstanceMethod(cls, sel) else { return "method-not-found" }
        // Only hook void methods (don't corrupt a value return).
        let rt = method_copyReturnType(m)
        let isVoid = rt.pointee == 0x76 /* 'v' */
        free(rt)
        guard isVoid else { return "not-void" }
        let api = h.api ?? "\(h.className).\(h.selector)"
        let cat = h.category
        let imp = imp_implementationWithBlock(makeBlock(max(0, min(3, h.args)), m, sel, api, cat))
        method_setImplementation(m, imp)
        installed.insert(key)
        return "ok"
    }

    /// Build a void block of the requested object-arg arity that logs then forwards to the original.
    private static func makeBlock(_ argc: Int, _ m: Method, _ sel: Selector,
                                  _ api: String, _ cat: OPCategory) -> Any {
        switch argc {
        case 0:
            typealias F = @convention(c) (AnyObject, Selector) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let blk: @convention(block) (AnyObject) -> Void = { o in
                if !emit(api, cat, []) { orig(o, sel) }
            }
            return blk
        case 1:
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let blk: @convention(block) (AnyObject, AnyObject?) -> Void = { o, a in
                if !emit(api, cat, [a]) { orig(o, sel, a) }
            }
            return blk
        case 2:
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let blk: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { o, a, b in
                if !emit(api, cat, [a, b]) { orig(o, sel, a, b) }
            }
            return blk
        default:
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let blk: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { o, a, b, c in
                if !emit(api, cat, [a, b, c]) { orig(o, sel, a, b, c) }
            }
            return blk
        }
    }

    /// Log the call and apply the rule decision. Returns true if the original should be SUPPRESSED
    /// (a `.blocked` rule); a `.delayed` rule sleeps first. (Void methods → no return to replace.)
    @discardableResult
    private static func emit(_ api: String, _ cat: OPCategory, _ args: [AnyObject?]) -> Bool {
        var fields: [String: String] = [:]
        var body: Data?
        for (i, a) in args.enumerated() {
            if let d = a as? NSData { body = d as Data; fields["arg\(i)"] = "<\(d.length) bytes>" }
            else if let s = a as? NSString { fields["arg\(i)"] = String((s as String).prefix(256)) }
            else if let o = a { fields["arg\(i)"] = String(describing: type(of: o)) }
            else { fields["arg\(i)"] = "nil" }
        }
        let ctx = OPCallContext(category: cat, layer: .objc, api: api, fields: fields)
        ctx.responseBody = body
        let decision = OPAgent.shared.intercept(ctx)
        OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
        if decision.disposition == .delayed && decision.delay > 0 {
            Thread.sleep(forTimeInterval: decision.delay)
        }
        return decision.disposition == .blocked
    }
}
