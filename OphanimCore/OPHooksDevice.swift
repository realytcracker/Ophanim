//
//  OPHooksDevice.swift
//  OphanimCore
//
//  Device-identity and privacy hooks via ObjC method swizzling. Classes/selectors are resolved
//  dynamically (NSClassFromString) so no extra frameworks (AdSupport/DeviceCheck/CoreLocation)
//  need linking - they resolve at runtime inside the hosted Catalyst process.
//
//  - Device identifiers (category .device): UIDevice.identifierForVendor, ASIdentifierManager
//    .advertisingIdentifier - observe + optional fake via a rule's cannedReturnValue.
//  - Privacy (category .privacy): UIPasteboard.string reads, CLLocationManager location requests,
//    DCAppAttestService key generation (attestation attempts) - observe.
//

import Foundation
import ObjectiveC.runtime

enum OPDeviceHooks {
    static func install() {
        if OPAgent.shared.isActive(.device) {
            swizzleObjectGetter("UIDevice", "identifierForVendor", category: .device,
                                api: "UIDevice.identifierForVendor")
            swizzleObjectGetter("ASIdentifierManager", "advertisingIdentifier", category: .device,
                                api: "ASIdentifierManager.advertisingIdentifier")
        }
        if OPAgent.shared.isActive(.privacy) {
            swizzleObjectGetter("UIPasteboard", "string", category: .privacy,
                                api: "UIPasteboard.string")
            swizzleVoid("CLLocationManager", "startUpdatingLocation", category: .privacy,
                        api: "CLLocationManager.startUpdatingLocation")
            swizzleVoid("CLLocationManager", "requestLocation", category: .privacy,
                        api: "CLLocationManager.requestLocation")
            // App Attest / DeviceCheck integrity APIs - observe-only (a re-signed app can't produce
            // a valid attestation; this surfaces *that the app tried*, which explains many
            // attestation-gated apps that stall after launch).
            swizzleVoidOneArg("DCAppAttestService", "generateKeyWithCompletionHandler:",
                              category: .privacy, api: "DCAppAttestService.generateKey")
            swizzleVoidThreeArg("DCAppAttestService", "attestKey:clientDataHash:completionHandler:",
                                category: .privacy, api: "DCAppAttestService.attestKey")
            swizzleVoidThreeArg("DCAppAttestService", "generateAssertion:clientDataHash:completionHandler:",
                                category: .privacy, api: "DCAppAttestService.generateAssertion")
            swizzleVoidOneArg("DCDevice", "generateTokenWithCompletionHandler:",
                              category: .privacy, api: "DCDevice.generateToken")
            // Sensitive-resource access prompts - observe when an app asks for these.
            swizzleVoidThreeArg("LAContext", "evaluatePolicy:localizedReason:reply:",
                                category: .privacy, api: "LAContext.evaluatePolicy (biometrics)")
            swizzleVoidTwoArg("CNContactStore", "requestAccessForEntityType:completionHandler:",
                              category: .privacy, api: "CNContactStore.requestAccess (contacts)")
            swizzleClassVoidTwoArg("AVCaptureDevice", "requestAccessForMediaType:completionHandler:",
                                   category: .privacy, api: "AVCaptureDevice.requestAccess (camera/mic)")
            swizzleClassVoidTwoArg("PHPhotoLibrary", "requestAuthorizationForAccessLevel:handler:",
                                   category: .privacy, api: "PHPhotoLibrary.requestAuthorization (photos)")
            swizzleClassVoidOneArg("PHPhotoLibrary", "requestAuthorization:",
                                   category: .privacy, api: "PHPhotoLibrary.requestAuthorization (photos)")
        }
    }

    // MARK: helpers

    /// Swizzle an instance getter returning an object (id). Observe, and optionally replace the
    /// returned value when a rule yields a cannedReturnValue (UUID or string fake).
    private static func swizzleObjectGetter(_ className: String, _ selName: String,
                                            category: OPCategory, api: String) {
        guard let cls = NSClassFromString(className) else { return }
        let sel = NSSelectorFromString(selName)
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject) -> AnyObject? = { obj in
            let real = orig(obj, sel)
            let ctx = OPCallContext(category: category, layer: .objc, api: api,
                                    fields: ["value": describe(real)])
            let decision = OPAgent.shared.intercept(ctx)
            if decision.disposition == .returnReplaced, let v = decision.cannedReturnValue,
               let fake = fakeLike(real, value: v) {
                OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                            summary: "faked \(api) → \(v)"))
                return fake
            }
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
            return real
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// Swizzle a no-argument void instance method - observe the call (and honor a block rule).
    private static func swizzleVoid(_ className: String, _ selName: String,
                                    category: OPCategory, api: String) {
        guard let cls = NSClassFromString(className) else { return }
        let sel = NSSelectorFromString(selName)
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject) -> Void = { obj in
            let ctx = OPCallContext(category: category, layer: .objc, api: api)
            let decision = OPAgent.shared.intercept(ctx)
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
            if decision.disposition == .blocked { return }   // suppress the call
            orig(obj, sel)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// Swizzle a void instance method taking one object argument (e.g. a completion handler) -
    /// observe the attempt and forward the argument unchanged.
    private static func swizzleVoidOneArg(_ className: String, _ selName: String,
                                          category: OPCategory, api: String) {
        guard let cls = NSClassFromString(className) else { return }
        let sel = NSSelectorFromString(selName)
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { obj, arg in
            let ctx = OPCallContext(category: category, layer: .objc, api: api)
            let decision = OPAgent.shared.intercept(ctx)
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
            orig(obj, sel, arg)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// Swizzle a void instance method taking three object args (e.g. attestKey:clientDataHash:
    /// completionHandler:) - observe the attempt, log the first arg, and forward unchanged.
    private static func swizzleVoidThreeArg(_ className: String, _ selName: String,
                                            category: OPCategory, api: String) {
        guard let cls = NSClassFromString(className) else { return }
        let sel = NSSelectorFromString(selName)
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { obj, a1, a2, a3 in
            let ctx = OPCallContext(category: category, layer: .objc, api: api,
                                    fields: ["arg": describe(a1)])
            let decision = OPAgent.shared.intercept(ctx)
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
            orig(obj, sel, a1, a2, a3)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// Swizzle a void instance method taking two object args (e.g. requestAccess:completionHandler:).
    private static func swizzleVoidTwoArg(_ className: String, _ selName: String,
                                          category: OPCategory, api: String) {
        guard let cls = NSClassFromString(className) else { return }
        let sel = NSSelectorFromString(selName)
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { obj, a1, a2 in
            observeCall(category: category, api: api, arg: a1)
            orig(obj, sel, a1, a2)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// Swizzle a void *class* method taking two object args (e.g. +requestAccessForMediaType:...).
    private static func swizzleClassVoidTwoArg(_ className: String, _ selName: String,
                                               category: OPCategory, api: String) {
        guard let cls = NSClassFromString(className), let meta = object_getClass(cls) else { return }
        let sel = NSSelectorFromString(selName)
        guard let m = class_getInstanceMethod(meta, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { obj, a1, a2 in
            observeCall(category: category, api: api, arg: a1)
            orig(obj, sel, a1, a2)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// Swizzle a void *class* method taking one object arg (e.g. +requestAuthorization:).
    private static func swizzleClassVoidOneArg(_ className: String, _ selName: String,
                                               category: OPCategory, api: String) {
        guard let cls = NSClassFromString(className), let meta = object_getClass(cls) else { return }
        let sel = NSSelectorFromString(selName)
        guard let m = class_getInstanceMethod(meta, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { obj, a1 in
            observeCall(category: category, api: api, arg: a1)
            orig(obj, sel, a1)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// Shared observe path for the simple "log this call" swizzles.
    private static func observeCall(category: OPCategory, api: String, arg: AnyObject?) {
        let ctx = OPCallContext(category: category, layer: .objc, api: api,
                                fields: arg != nil ? ["arg": describe(arg)] : [:])
        let decision = OPAgent.shared.intercept(ctx)
        OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
    }

    private static func describe(_ obj: AnyObject?) -> String {
        guard let obj = obj else { return "nil" }
        if let u = obj as? NSUUID { return u.uuidString }
        if let s = obj as? NSString { return s as String }
        return String(describing: obj)
    }

    private static func fakeLike(_ real: AnyObject?, value: String) -> AnyObject? {
        if real is NSUUID { return NSUUID(uuidString: value) }
        return value as NSString
    }
}

/// Inter-app launch hooks (category .process). Logs when the hosted app tries to open another app
/// or URL scheme - `UIApplication.openURL(...)` and `canOpenURL:`. These are the high-level paths
/// an iOS/Catalyst app uses to launch a companion app or deep link, and are common culprits when an
/// app hangs on its splash screen waiting on a handoff that never returns. Safe ObjC swizzles
/// (main-thread, high-level); a rule can block a launch or fake a `canOpenURL` result.
enum OPLaunchHooks {
    static func install() {
        guard OPAgent.shared.isActive(.process) else { return }
        swizzleOpenURLCompletion()
        swizzleOpenURLLegacy()
        swizzleCanOpenURL()
    }

    private static func urlString(_ url: AnyObject?) -> String {
        if let u = url as? NSURL { return u.absoluteString ?? "?" }
        if let s = url as? NSString { return s as String }
        return "?"
    }

    /// -[UIApplication openURL:options:completionHandler:] - the modern launch API (void).
    private static func swizzleOpenURLCompletion() {
        guard let cls = NSClassFromString("UIApplication") else { return }
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { obj, url, opts, handler in
            let u = urlString(url)
            let ctx = OPCallContext(category: .process, layer: .objc, api: "UIApplication.openURL",
                                    fields: ["url": u])
            let decision = OPAgent.shared.intercept(ctx)
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision, summary: "open \(u)"))
            if decision.disposition == .blocked { return }
            orig(obj, sel, url, opts, handler)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// -[UIApplication openURL:] - deprecated launch API (returns BOOL).
    private static func swizzleOpenURLLegacy() {
        guard let cls = NSClassFromString("UIApplication") else { return }
        let sel = NSSelectorFromString("openURL:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> ObjCBool
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> ObjCBool = { obj, url in
            let u = urlString(url)
            let ctx = OPCallContext(category: .process, layer: .objc, api: "UIApplication.openURL(legacy)",
                                    fields: ["url": u])
            let decision = OPAgent.shared.intercept(ctx)
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision, summary: "open \(u)"))
            if decision.disposition == .blocked { return ObjCBool(false) }
            return orig(obj, sel, url)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// -[UIApplication canOpenURL:] - scheme probing (returns BOOL). Apps often probe many schemes
    /// before (or instead of) launching; a rule's cannedReturnValue ("true"/"false") fakes the answer.
    private static func swizzleCanOpenURL() {
        guard let cls = NSClassFromString("UIApplication") else { return }
        let sel = NSSelectorFromString("canOpenURL:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> ObjCBool
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> ObjCBool = { obj, url in
            let u = urlString(url)
            let real = orig(obj, sel, url)
            let ctx = OPCallContext(category: .process, layer: .objc, api: "UIApplication.canOpenURL",
                                    fields: ["url": u, "result": real.boolValue ? "yes" : "no"])
            let decision = OPAgent.shared.intercept(ctx)
            if decision.disposition == .returnReplaced, let v = decision.cannedReturnValue {
                let fake = (v as NSString).boolValue
                OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                            summary: "canOpenURL \(u) → faked \(fake)"))
                return ObjCBool(fake)
            }
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
            return real
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}
