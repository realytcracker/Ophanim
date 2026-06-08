//
//  OPHooksFilesystem.swift
//  OphanimCore
//
//  ObjC-layer filesystem capture via NSFileManager swizzling - the SIBLING-mode fallback for the
//  filesystem category. In embedded mode, filesystem is captured at the C level by Galgal's own
//  gg_open/gg_stat/gg_access/… interposes (and the agent must NOT re-interpose those - the hard
//  rule), so this file is only installed under sibling injection (gated in OPBootstrap with
//  #if OPHANIM_SIBLING). It is strictly partial: it sees NSFileManager / Foundation-level access but
//  NOT raw POSIX open/stat an app makes directly. Many apps (and most jailbreak-path probes that go
//  through -[NSFileManager fileExistsAtPath:]) do route through here, so it recovers the common case.
//
//  fileExistsAtPath: additionally honors a rule's cannedReturnValue (like UIApplication.canOpenURL),
//  so a jailbreak-path existence check can be faked to NO even in sibling mode.
//

import Foundation
import ObjectiveC.runtime

enum OPFilesystemHooks {
    static func install() {
        guard OPAgent.shared.isActive(.filesystem) else { return }
        guard let cls = NSClassFromString("NSFileManager") else { return }
        swizzleExists(cls)
        swizzleExistsIsDir(cls)
        swizzleContentsAtPath(cls)
        swizzleRemoveItem(cls)
        swizzleCreateFile(cls)
    }

    private static func pathString(_ obj: AnyObject?) -> String {
        if let s = obj as? NSString { return s as String }
        return "?"
    }

    /// -[NSFileManager fileExistsAtPath:] → BOOL. Observe; a rule may fake the result (cannedReturnValue
    /// "true"/"false") - the classic jailbreak-probe defeat (return NO for /Applications/Cydia.app, …).
    private static func swizzleExists(_ cls: AnyClass) {
        let sel = NSSelectorFromString("fileExistsAtPath:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> ObjCBool
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> ObjCBool = { obj, path in
            let p = pathString(path)
            let real = orig(obj, sel, path)
            let ctx = OPCallContext(category: .filesystem, layer: .objc, api: "NSFileManager.fileExistsAtPath",
                                    fields: ["path": p, "result": real.boolValue ? "yes" : "no"])
            let decision = OPAgent.shared.intercept(ctx)
            if decision.disposition == .returnReplaced, let v = decision.cannedReturnValue {
                let fake = (v as NSString).boolValue
                OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                            summary: "fileExists \(p) → faked \(fake)"))
                return ObjCBool(fake)
            }
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
            return real
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// -[NSFileManager fileExistsAtPath:isDirectory:] → BOOL (with a BOOL* out-param, forwarded as-is).
    private static func swizzleExistsIsDir(_ cls: AnyClass) {
        let sel = NSSelectorFromString("fileExistsAtPath:isDirectory:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, UnsafeMutablePointer<ObjCBool>?) -> ObjCBool
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?, UnsafeMutablePointer<ObjCBool>?) -> ObjCBool = { obj, path, isDir in
            let p = pathString(path)
            let real = orig(obj, sel, path, isDir)
            let ctx = OPCallContext(category: .filesystem, layer: .objc,
                                    api: "NSFileManager.fileExistsAtPath:isDirectory:",
                                    fields: ["path": p, "result": real.boolValue ? "yes" : "no"])
            let decision = OPAgent.shared.intercept(ctx)
            if decision.disposition == .returnReplaced, let v = decision.cannedReturnValue {
                let fake = (v as NSString).boolValue
                OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                            summary: "fileExists \(p) → faked \(fake)"))
                return ObjCBool(fake)
            }
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
            return real
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// -[NSFileManager contentsAtPath:] → NSData?. Observe path + byte count (a file read).
    private static func swizzleContentsAtPath(_ cls: AnyClass) {
        let sel = NSSelectorFromString("contentsAtPath:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { obj, path in
            let real = orig(obj, sel, path)
            let len = (real as? NSData)?.length ?? 0
            let ctx = OPCallContext(category: .filesystem, layer: .objc, api: "NSFileManager.contentsAtPath",
                                    fields: ["path": pathString(path), "bytes": String(len)])
            let decision = OPAgent.shared.intercept(ctx)
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
            return real
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// -[NSFileManager removeItemAtPath:error:] → BOOL. Observe; a rule may block the deletion.
    private static func swizzleRemoveItem(_ cls: AnyClass) {
        let sel = NSSelectorFromString("removeItemAtPath:error:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, UnsafeMutableRawPointer?) -> ObjCBool
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?, UnsafeMutableRawPointer?) -> ObjCBool = { obj, path, err in
            let p = pathString(path)
            let ctx = OPCallContext(category: .filesystem, layer: .objc, api: "NSFileManager.removeItemAtPath",
                                    fields: ["path": p])
            let decision = OPAgent.shared.intercept(ctx)
            if decision.disposition == .blocked {
                OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                            summary: "remove \(p) → blocked"))
                return ObjCBool(true)   // report success without deleting
            }
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
            return orig(obj, sel, path, err)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// -[NSFileManager createFileAtPath:contents:attributes:] → BOOL. Observe path + byte count.
    private static func swizzleCreateFile(_ cls: AnyClass) {
        let sel = NSSelectorFromString("createFileAtPath:contents:attributes:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> ObjCBool
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> ObjCBool = { obj, path, data, attrs in
            let len = (data as? NSData)?.length ?? 0
            let ctx = OPCallContext(category: .filesystem, layer: .objc, api: "NSFileManager.createFileAtPath",
                                    fields: ["path": pathString(path), "bytes": String(len)])
            let decision = OPAgent.shared.intercept(ctx)
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
            if decision.disposition == .blocked { return ObjCBool(false) }
            return orig(obj, sel, path, data, attrs)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}
