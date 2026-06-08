//
//  OPRingBridge.swift
//  OphanimCore
//
//  Consumer side of the capture ring: the C drain thread (OPRing.m) hands each record here, on a
//  normal thread where allocation is safe. We map the record's kind to an (OPCategory, api), gate
//  on the active capture category, build an OPEvent and emit it. Nothing here runs in the hostile
//  interpose context - that's all in op_ring_emit.
//

import Foundation

@objc(OPRingBridge) public final class OPRingBridge: NSObject {
    // Mirrors op_kind_t in OPRing.h - keep in sync.
    private enum Kind: Int32 {
        case none = 0
        case fsOpen, fsStat, fsAccess, fsRename, fsUnlink
        case procDlopen, procFork, procSpawn, procExec
        case sockConnect, sockGetaddrinfo
        case tlsRead, tlsWrite
        case keychainCopy, keychainAdd, keychainUpdate, keychainDelete
        case crypto
        case pinning
    }

    /// Called only from the ring's single consumer thread.
    @objc public static func emitKind(_ kind: Int32, flags: Int32, arg: Int32,
                                      str: UnsafePointer<CChar>?, blob: UnsafeRawPointer?,
                                      blobLen: Int32, tid: UInt64) {
        guard let k = Kind(rawValue: kind) else { return }
        let detail = str.map { String(cString: $0) } ?? ""
        let (category, baseAPI, layer) = route(k)
        guard OPAgent.shared.isActive(category) else { return }   // pinning routes to .network
        // Crypto/pinning records carry the actual function name (CCCrypt / SecTrust…) in `str`.
        let api = ((k == .crypto || k == .pinning) && !detail.isEmpty) ? detail : baseAPI

        var fields: [String: String] = ["thread": String(tid)]
        var path: String?
        var host: String?
        var requestBody: Data?
        var responseBody: Data?

        switch k {
        case .fsOpen, .fsStat, .fsAccess, .fsRename, .fsUnlink:
            path = detail
            if k == .fsOpen, arg != 0 { fields["oflag"] = String(arg) }
        case .procDlopen, .procSpawn, .procExec:
            path = detail.isEmpty ? nil : detail
        case .procFork:
            break
        case .sockConnect:
            host = detail.isEmpty ? nil : detail
            if arg != 0 { fields["port"] = String(arg) }
        case .sockGetaddrinfo:
            host = detail.isEmpty ? nil : detail
        case .tlsRead, .tlsWrite:
            if arg != 0 { fields["len"] = String(arg) }
            if let blob = blob, blobLen > 0 {
                let data = Data(bytes: blob, count: Int(blobLen))
                if k == .tlsWrite { requestBody = data } else { responseBody = data }
            }
        case .keychainCopy, .keychainAdd, .keychainUpdate, .keychainDelete:
            if !detail.isEmpty { fields["account"] = detail }
            fields["status"] = String(arg)        // OSStatus from the call
        case .crypto:
            fields["op"] = flags == 1 ? "encrypt" : (flags == 2 ? "hmac" : "decrypt")
            if arg != 0 { fields["bytes"] = String(arg) }
        case .pinning:
            // flags bit0 = the real evaluation rejected the chain; bit1 = we forced it to accept.
            fields["verdict"] = (flags & 1) == 1 ? "rejected" : "trusted"
            fields["bypassed"] = (flags & 2) == 2 ? "yes" : "no"
        case .none:
            return
        }

        let ctx = OPCallContext(category: category, layer: layer, api: api,
                                fields: fields, host: host, path: path)
        ctx.requestBody = requestBody
        ctx.responseBody = responseBody
        let decision = OPAgent.shared.intercept(ctx)
        OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision))
    }

    /// Emitted by the ring consumer when records were dropped because the ring was full. Surfaces
    /// the running total as an event so truncation is visible rather than silent. observe() is a
    /// no-op when the agent isn't capturing (sinks nil).
    @objc public static func emitDropped(_ total: UInt64) {
        OPAgent.shared.observe(OPEvent(category: .process, layer: .interpose,
                                       api: "ophanim.ring.dropped",
                                       summary: "capture ring full - dropped \(total) event(s) total",
                                       fields: ["dropped": String(total)]))
    }

    private static func route(_ k: Kind) -> (OPCategory, String, OPCaptureLayer) {
        switch k {
        case .fsOpen:        return (.filesystem, "open", .interpose)
        case .fsStat:        return (.filesystem, "stat", .interpose)
        case .fsAccess:      return (.filesystem, "access", .interpose)
        case .fsRename:      return (.filesystem, "rename", .interpose)
        case .fsUnlink:      return (.filesystem, "unlink", .interpose)
        case .procDlopen:    return (.process, "dlopen", .interpose)
        case .procFork:      return (.process, "fork", .interpose)
        case .procSpawn:     return (.process, "posix_spawn", .interpose)
        case .procExec:      return (.process, "execve", .interpose)
        case .sockConnect:   return (.network, "connect", .socket)
        case .sockGetaddrinfo: return (.network, "getaddrinfo", .socket)
        case .tlsRead:       return (.network, "SSL_read", .tls)
        case .tlsWrite:      return (.network, "SSL_write", .tls)
        case .keychainCopy:  return (.keychain, "SecItemCopyMatching", .interpose)
        case .keychainAdd:   return (.keychain, "SecItemAdd", .interpose)
        case .keychainUpdate: return (.keychain, "SecItemUpdate", .interpose)
        case .keychainDelete: return (.keychain, "SecItemDelete", .interpose)
        case .crypto:        return (.crypto, "CCCrypt", .interpose)
        case .pinning:       return (.network, "SecTrustEvaluate", .tls)
        case .none:          return (.process, "?", .interpose)
        }
    }
}
