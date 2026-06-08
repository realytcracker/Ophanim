//
//  OPTLSBridge.swift
//  OphanimCore
//
//  ObjC-callable bridge the C SSL_read/SSL_write interposers call to log decrypted (plaintext)
//  TLS payloads through the agent. Observe-only: rewriting bytes mid-TLS-stream would corrupt the
//  connection, so the TLS layer captures ground-truth plaintext but defers blocking/rewrite to the
//  URLProtocol layer (which has clean request/response boundaries).
//

import Foundation

@objc(OPTLSBridge) public final class OPTLSBridge: NSObject {
    /// direction: 0 = read (inbound/response), 1 = write (outbound/request).
    @objc public static func log(direction: Int32, bytes: UnsafeRawPointer?, length: Int32) {
        guard !OPReentry.active else { return }
        OPReentry.active = true
        defer { OPReentry.active = false }
        guard length > 0, let bytes = bytes, OPAgent.shared.isActive(.network) else { return }
        let cap = min(Int(length), OPAgent.shared.bodyCap)
        let data = Data(bytes: bytes, count: cap)
        let outbound = direction == 1
        let ctx = OPCallContext(category: .network, layer: .tls,
                                api: outbound ? "SSL_write" : "SSL_read",
                                fields: ["dir": outbound ? "write" : "read",
                                         "len": String(length)])
        if outbound { ctx.requestBody = data } else { ctx.responseBody = data }
        let decision = OPAgent.shared.intercept(ctx)
        OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                    summary: "TLS \(outbound ? "write" : "read") \(length)B"))
    }
}
