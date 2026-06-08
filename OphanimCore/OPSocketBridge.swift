//
//  OPSocketBridge.swift
//  OphanimCore
//
//  Bridge for the C socket/DNS interposers (connect/getaddrinfo). Connection + name-resolution
//  metadata under the .network category - complements the URLProtocol/TLS layers (which see HTTP),
//  capturing raw outbound endpoints and DNS lookups. Observe-only.
//

import Foundation

@objc(OPSocketBridge) public final class OPSocketBridge: NSObject {
    @objc public static func logConnect(host: NSString, port: Int32, family: Int32) {
        guard !OPReentry.active else { return }
        OPReentry.active = true
        defer { OPReentry.active = false }
        guard OPAgent.shared.isActive(.network) else { return }
        let ctx = OPCallContext(category: .network, layer: .socket, api: "connect",
                                fields: ["dest": "\(host):\(port)",
                                         "family": family == Int32(AF_INET6) ? "inet6" : "inet"],
                                host: host as String)
        let decision = OPAgent.shared.intercept(ctx)
        OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                    summary: "connect \(host):\(port)"))
    }

    @objc public static func logDNS(_ node: NSString) {
        guard !OPReentry.active else { return }
        OPReentry.active = true
        defer { OPReentry.active = false }
        guard OPAgent.shared.isActive(.network) else { return }
        let ctx = OPCallContext(category: .network, layer: .socket, api: "getaddrinfo",
                                fields: ["query": node as String], host: node as String)
        let decision = OPAgent.shared.intercept(ctx)
        OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                    summary: "DNS \(node)"))
    }
}
