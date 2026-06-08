//
//  OPCryptoBridge.swift
//  OphanimCore
//
//  ObjC-callable bridge for the CommonCrypto interposers (CCCrypt/CCHmac). Observe-only; gates on
//  the .crypto category.
//

import Foundation

@objc(OPCryptoBridge) public final class OPCryptoBridge: NSObject {
    @objc public static func log(api: NSString, detail: NSString) {
        guard !OPReentry.active else { return }
        OPReentry.active = true
        defer { OPReentry.active = false }
        guard OPAgent.shared.isActive(.crypto) else { return }
        let ctx = OPCallContext(category: .crypto, layer: .interpose, api: api as String,
                                fields: ["detail": detail as String])
        let decision = OPAgent.shared.intercept(ctx)
        OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                    summary: "\(api) \(detail)"))
    }
}
