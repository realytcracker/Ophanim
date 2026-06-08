//
//  OPProcessBridge.swift
//  OphanimCore
//
//  ObjC-callable bridge for the C process/dylib interposers (dlopen/fork/posix_spawn). Observe-only
//  here; gating on the .process category happens inside (cheap when disabled).
//

import Foundation

@objc(OPProcessBridge) public final class OPProcessBridge: NSObject {
    @objc public static func log(api: NSString, detail: NSString) {
        guard !OPReentry.active else { return }
        OPReentry.active = true
        defer { OPReentry.active = false }
        guard OPAgent.shared.isActive(.process) else { return }
        let ctx = OPCallContext(category: .process, layer: .interpose, api: api as String,
                                fields: ["detail": detail as String])
        let decision = OPAgent.shared.intercept(ctx)
        OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                    summary: "\(api) \(detail)"))
    }
}
