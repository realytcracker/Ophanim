//
//  TestRunner.swift
//  OphanimTest - a deliberately "noisy" app that exercises every category Ophanim instruments,
//  so you can inject Ophanim, enable capture, and watch events/interceptions appear.
//

import Foundation
import UIKit
import Security
import CommonCrypto
import AdSupport
import CoreLocation
import DeviceCheck

enum TestRunner {
    static let testURL = "https://hackingfordummies.com/"

    /// Run every probe; `log` receives human-readable lines (also NSLog'd).
    static func runAll(_ log: @escaping (String) -> Void) {
        let out: (String) -> Void = { line in NSLog("[OphanimTest] %@", line); DispatchQueue.main.async { log(line) } }
        out("── run \(Date()) ──")
        network(out)
        websocket(out)
        boundary(out)
        swiftBoundary(out)
        inlineProbe(out)
        matrix(out)
        pinning(out)
        keychain(out)
        crypto(out)
        device(out)
        privacy(out)
        filesystem(out)
        process(out)
    }

    // 1b) CERT PINNING → app-level SecTrustEvaluateWithError, the exact call TrustKit / AFNetworking /
    // Alamofire / custom URLSession challenge validators make. Deterministic + network-free: we build
    // a SecTrust locally from an embedded leaf certificate (hackingfordummies.com) and evaluate it.
    // With only the leaf (no chain to a trusted anchor) the real evaluation FAILS, so with Ophanim's
    // "Bypass certificate pinning" ON the interpose force-accepts it and logs the check.
    static func pinning(_ out: @escaping (String) -> Void) {
        // Run off the main thread / app-init path - evaluating trust during very early launch on the
        // main thread is fragile (matches where real pinning libraries call it: a network callback).
        DispatchQueue.global(qos: .utility).async {
            guard let der = Data(base64Encoded: probeCertB64),
                  let cert = SecCertificateCreateWithData(nil, der as CFData) else {
                out("PINNING probe: bad embedded certificate"); return
            }
            let policy = SecPolicyCreateSSL(true, "hackingfordummies.com" as CFString)
            var trust: SecTrust?
            let status = SecTrustCreateWithCertificates(cert as CFTypeRef, policy, &trust)
            guard status == errSecSuccess, let trust else {
                out("PINNING probe: SecTrustCreateWithCertificates failed (\(status))"); return
            }
            SecTrustSetNetworkFetchAllowed(trust, false)   // purely local + deterministic
            var error: CFError?
            let trusted = SecTrustEvaluateWithError(trust, &error)   // ← Ophanim's pinning interpose target
            out("PINNING SecTrustEvaluateWithError → trusted=\(trusted) (err=\(error == nil ? "nil" : "set"))")
        }
    }

    /// hackingfordummies.com leaf certificate (DER, base64) - for the network-free pinning probe.
    private static let probeCertB64 =
        "MIIDwjCCA2mgAwIBAgIQF1DNk1G20HAOEXWCMVCf+jAKBggqhkjOPQQDAjA7MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVR29vZ2xlIFRydXN0IFNlcnZpY2VzMQwwCgYDVQQDEwNXRTEwHhcNMjYwNTA1MjI1OTI3WhcNMjYwODAzMjM1OTIzWjAgMR4wHAYDVQQDExVoYWNraW5nZm9yZHVtbWllcy5jb20wWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAR5iZOSr6Qx1JgjEgAXeQtAkkareXjDentNv1ce9+nTUUZqE/HdA73Us8TnKtXVcerheTeszb5p+B8OZmWWO/V9o4ICaDCCAmQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFAy6nY0gkB8rxqUQM8bP9sbRkplTMB8GA1UdIwQYMBaAFJB3kjVnxP+ozKnme9mAeXvMk/k4MF4GCCsGAQUFBwEBBFIwUDAnBggrBgEFBQcwAYYbaHR0cDovL28ucGtpLmdvb2cvcy93ZTEvRjFBMCUGCCsGAQUFBzAChhlodHRwOi8vaS5wa2kuZ29vZy93ZTEuY3J0MDkGA1UdEQQyMDCCFWhhY2tpbmdmb3JkdW1taWVzLmNvbYIXKi5oYWNraW5nZm9yZHVtbWllcy5jb20wEwYDVR0gBAwwCjAIBgZngQwBAgEwNgYDVR0fBC8wLTAroCmgJ4YlaHR0cDovL2MucGtpLmdvb2cvd2UxLzM3QkZ1NDliTldJLmNybDCCAQUGCisGAQQB1nkCBAIEgfYEgfMA8QB3ANdtfRDRp/V3wsfpX9cAv/mCyTNaZeHQswFzF8DIxWl3AAABnfqVFwcAAAQDAEgwRgIhAPwFGnnhtV0p3gN0EXzQkSuXuvuGqEBzYeTS3dV1O8BmAiEAtF2GpeaZlTaJ+x6ijIVN2CpmoMn4ykRxW6wtUFUqn4QAdgDIo8R/x7OtuTVrAT9qehJt4zpOQ6XGRvmXrTl1mR3PmgAAAZ36lRcsAAAEAwBHMEUCIQDkUyR5x1sewhPl05/y42+zvgeBZHzL6xkM3jQtV+XKAAIgEkzFSELiDUt2SFUzYRF5RAR6PXJ2Wy/lUfawoDWy+WAwCgYIKoZIzj0EAwIDRwAwRAIgcCL6BfA/GNAMwqmXX4ZlyaZn8A8G1jq/kwoDPFshtLgCIGaNM0AAaVX2X7vABHLKfFpBDNAmibjaem2h3JSStwmF"

    // 1) NETWORK + TLS  → URLProtocol / NSURLSession swizzle / boringssl SSL_read/write
    static func network(_ out: @escaping (String) -> Void) {
        guard let url = URL(string: testURL) else { return }
        // shared session (covered by registerClass)
        URLSession.shared.dataTask(with: url) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            out("NET shared → \(testURL) status=\(code) bytes=\(data?.count ?? 0) err=\(err?.localizedDescription ?? "nil")")
        }.resume()
        // custom configured session (covered by the URLSessionConfiguration swizzle)
        var req = URLRequest(url: url)
        req.setValue("OphanimTest/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer test-secret-token", forHTTPHeaderField: "Authorization")   // redaction target
        URLSession(configuration: .default).dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            out("NET custom → \(testURL) status=\(code) bytes=\(data?.count ?? 0)")
        }.resume()
    }

    // 1c) WEBSOCKET → URLSessionWebSocketTask send/receive swizzle
    static func websocket(_ out: @escaping (String) -> Void) {
        guard let url = URL(string: "wss://echo.websocket.events") else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        task.send(.string("ophanim-ws-probe")) { err in
            out("WS send err=\(err?.localizedDescription ?? "nil")")
        }
        task.receive { result in
            switch result {
            case .success(let msg): out("WS recv \(msg)")
            case .failure(let e):   out("WS recv err \(e.localizedDescription)")
            }
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    // 1d) OBJC BOUNDARY → a stand-in for an SDK's @objc data callback, hooked via set_objc_hooks.
    static func boundary(_ out: @escaping (String) -> Void) {
        let payload = Data("ophanim-boundary-payload".utf8) as NSData
        // Invoke via objc_msgSend (perform:) - how a real SDK/runtime dispatches a callback, and the
        // only path ObjC swizzling intercepts. (A direct Swift call would be statically dispatched.)
        OPBoundaryProbe().perform(NSSelectorFromString("handleResponse:"), with: payload)
        out("BOUNDARY handleResponse(\(payload.length) bytes)")
    }

    // 1e) NATIVE-SWIFT BOUNDARY → a non-@objc, overridable Swift method dispatched through the vtable,
    // the kind ObjC swizzling can't reach. Hooked via set_swift_hooks (Tier 2.5). We call it through a
    // base-typed reference returned by an opaque @inline(never) factory so -O can't devirtualize the
    // call into a direct one (which would bypass the vtable). The line prints the runtime class name to
    // configure the hook with: set_swift_hooks className=<printed> method="processPayload".
    static func swiftBoundary(_ out: @escaping (String) -> Void) {
        let payload = Data("ophanim-swift-vtable-payload".utf8) as NSData
        // Resolve the concrete type by name at runtime so the -O optimizer can't see it and devirtualize
        // (even speculatively) - the call then goes through the genuine Swift vtable, the path Tier 2.5
        // hooks. NSStringFromClass prints the runtime name to configure set_swift_hooks's className with.
        guard let cls = NSClassFromString("OphanimTest.OPSwiftProbe") as? OPSwiftProbeBase.Type else {
            out("SWIFT-BOUNDARY probe class not found"); return
        }
        let probe = cls.init()
        probe.processPayload(payload)
        out("SWIFT-BOUNDARY \(NSStringFromClass(type(of: probe))).processPayload(\(payload.length) bytes)")
    }

    // 1f) INLINE (Tier 3) → a plain C function hooked by machine-code patch. Called through its
    // exported symbol (dlsym) so the call genuinely reaches the hooked out-of-line address (a direct
    // Swift call could inline a copy). The agent hooks the same symbol at launch; with the hook live
    // we should see an "inline" event, and call-through must still return the correct sum.
    static func inlineProbe(_ out: @escaping (String) -> Void) {
        guard let h = dlopen(nil, RTLD_NOW),
              let sym = dlsym(h, "optest_inline_target") else {
            out("INLINE probe: symbol not found"); return
        }
        typealias Fn = @convention(c) (Int32, Int32) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        let r = fn(40, 2)
        out("INLINE optest_inline_target(40,2)=\(r)")
        // second target, hooked via the config/MCP path (set_inline_hooks by symbol), not the self-test
        if let s2 = dlsym(h, "optest_inline_target2") {
            let r2 = unsafeBitCast(s2, to: (@convention(c) (Int32) -> Int32).self)(7)
            out("INLINE optest_inline_target2(7)=\(r2)")
        }
    }

    // 1g) HOOK-MATRIX → exercises every hook type against the rule actions. ObjC + Swift methods are
    // void (observe / block are the meaningful actions); inline functions return values (observe /
    // block / replace-return / fault / delay). Side-effect counters make "block" observable, and the
    // logged result/timing makes the inline actions verifiable. Rules are configured per-api via MCP.
    static func matrix(_ out: @escaping (String) -> Void) {
        let payload = Data("mtx".utf8) as NSData

        // --- ObjC (set_objc_hooks; api labels mtx.objc.observe / mtx.objc.block) ---
        let op = OPMatrixObjC()
        op.perform(NSSelectorFromString("mObserve:"), with: payload)
        OPMatrixObjC.ran = 0
        op.perform(NSSelectorFromString("mBlock"))
        out("MATRIX objc.block ran=\(OPMatrixObjC.ran) (0=blocked, 1=ran)")

        // --- Swift vtable (set_swift_hooks; mtx.swift.observe / mtx.swift.block) ---
        if let cls = NSClassFromString("OphanimTest.OPMatrixSwift") as? OPMatrixSwiftBase.Type {
            let s = cls.init()
            OPMatrixSwiftBase.seen = 0
            s.sObserve()
            OPMatrixSwiftBase.ran = 0
            s.sBlock()
            out("MATRIX swift.observe seen=\(OPMatrixSwiftBase.seen) (1=ran+logged), swift.block ran=\(OPMatrixSwiftBase.ran) (0=blocked)")
        }

        // --- Inline (set_inline_hooks + rules; mtx.inline.{observe,block,replace,fault,delay}) ---
        guard let h = dlopen(nil, RTLD_NOW) else { return }
        func call(_ sym: String, _ a: Int32) -> (Int32, Int) {
            guard let p = dlsym(h, sym) else { return (Int32.min, 0) }
            let fn = unsafeBitCast(p, to: (@convention(c) (Int32) -> Int32).self)
            let t0 = Date(); let r = fn(a); let ms = Int(Date().timeIntervalSince(t0) * 1000)
            return (r, ms)
        }
        out("MATRIX inline.observe(10)=\(call("optest_m_observe", 10).0) (no rule → expect 11)")
        out("MATRIX inline.block(10)=\(call("optest_m_block", 10).0) (normally 12 → expect 0 blocked)")
        out("MATRIX inline.replace(10)=\(call("optest_m_replace", 10).0) (normally 13 → expect 777)")
        out("MATRIX inline.fault(10)=\(call("optest_m_fault", 10).0) (normally 14 → expect -5)")
        let dly = call("optest_m_delay", 10)
        out("MATRIX inline.delay(10)=\(dly.0) elapsed=\(dly.1)ms (normally 15 → expect 15, ~300ms)")

        // --- Inline ARG RENDERING: a function whose x0=NSData, x1=NSString (the gRPC-style case) ---
        if let r = dlsym(h, "optest_render") {
            typealias RFn = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
            let body = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02]) as NSData
            let name = "FetchLoginOptions" as NSString
            let n = unsafeBitCast(r, to: RFn.self)(Unmanaged.passUnretained(body).toOpaque(),
                                                   Unmanaged.passUnretained(name).toOpaque())
            out("RENDER optest_render(data=\(body.length)B, \"\(name)\") = \(n)")
        }
    }

    // 2) KEYCHAIN  → inline SecItem* logging in the runtime
    static func keychain(_ out: @escaping (String) -> Void) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "be.ophanim.test",
                                    kSecAttrAccount as String: "ophanim-test"]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = "s3cr3t-value".data(using: .utf8)!
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        var q = base; q[kSecReturnData as String] = true
        var result: AnyObject?
        let getStatus = SecItemCopyMatching(q as CFDictionary, &result)
        out("KEYCHAIN add=\(addStatus) copyMatching=\(getStatus)")
    }

    // 3) CRYPTO  → CCCrypt / CCHmac interpose
    static func crypto(_ out: @escaping (String) -> Void) {
        let key = [UInt8](repeating: 0x2a, count: kCCKeySizeAES128)
        let iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let plain = Array("attack at dawn".utf8)
        var ct = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128); var moved = 0
        let s = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key, key.count, iv, plain, plain.count, &ct, ct.count, &moved)
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, plain, plain.count, &mac)
        out("CRYPTO CCCrypt status=\(s) ctBytes=\(moved) + CCHmac SHA256")
    }

    // 4) DEVICE  → ObjC swizzles (identifierForVendor / advertisingIdentifier)
    static func device(_ out: @escaping (String) -> Void) {
        let idfv = UIDevice.current.identifierForVendor?.uuidString ?? "nil"
        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        out("DEVICE idfv=\(idfv) idfa=\(idfa)")
    }

    // 5) PRIVACY  → pasteboard / location / App Attest
    static func privacy(_ out: @escaping (String) -> Void) {
        let pb = UIPasteboard.general.string ?? "nil"
        out("PRIVACY pasteboard.string=\(pb.prefix(24))")
        let lm = CLLocationManager()
        lm.requestWhenInUseAuthorization()
        lm.startUpdatingLocation()
        out("PRIVACY requested location")
        if DCAppAttestService.shared.isSupported {
            DCAppAttestService.shared.generateKey { keyID, err in
                out("PRIVACY appAttest generateKey id=\(keyID ?? "nil") err=\(err?.localizedDescription ?? "nil")")
            }
        } else { out("PRIVACY appAttest unsupported") }
    }

    // 6) FILESYSTEM  → inline open/stat/access logging + NSFileManager
    static func filesystem(_ out: @escaping (String) -> Void) {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let path = docs + "/ophanim-probe.txt"
        try? "ophanim filesystem probe".write(toFile: path, atomically: true, encoding: .utf8)
        _ = FileManager.default.fileExists(atPath: path)
        let fd = open(path, O_RDONLY); if fd >= 0 { close(fd) }
        var st = Darwin.stat(); _ = stat(path, &st)
        let jb = access("/bin/bash", F_OK)               // classic jailbreak probe
        out("FILESYSTEM wrote+opened probe; access(/bin/bash)=\(jb)")
    }

    // 7) PROCESS  → dlopen / posix_spawn interpose
    static func process(_ out: @escaping (String) -> Void) {
        if let h = dlopen("/usr/lib/libsqlite3.dylib", RTLD_NOW) { dlclose(h); out("PROCESS dlopen libsqlite3 ok") }
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/ls"), nil]
        let r = posix_spawn(&pid, "/bin/ls", nil, nil, argv, environ)
        out("PROCESS posix_spawn(/bin/ls)=\(r) (sandbox usually denies)")
    }
}

/// Stand-in for a 3rd-party SDK's @objc data-delivery callback - the kind of language boundary the
/// Tier-2 set_objc_hooks capture targets. Selector: handleResponse:.
@objc(OPBoundaryProbe) final class OPBoundaryProbe: NSObject {
    @objc func handleResponse(_ data: NSData) { _ = data.length }
}

/// Stand-in for a native-Swift (non-@objc) SDK boundary - an overridable method dispatched through the
/// Swift vtable, the kind set_swift_hooks (Tier 2.5) targets. NOT @objc, so ObjC swizzling can't see it.
/// Base + override + opaque factory force genuine vtable dispatch under -O (no devirtualization).
class OPSwiftProbeBase {
    required init() {}
    @inline(never) func processPayload(_ data: NSData) { _ = data.length }
}
final class OPSwiftProbe: OPSwiftProbeBase {
    @inline(never) override func processPayload(_ data: NSData) { _ = data.length }
}

/// Stand-in for a statically-linked C function reachable only by inline (machine-code) hooking - the
/// Tier-3 target. Exported via @_cdecl so the agent can `dlsym` and patch it; `@inline(never)` keeps
/// an out-of-line body to hook. Does a little work so it has a real (non-PC-relative) prologue.
@inline(never)
@_cdecl("optest_inline_target")
public func optest_inline_target(_ a: Int32, _ b: Int32) -> Int32 {
    var acc = a
    for _ in 0..<2 { acc = acc &+ (b / 2) }
    return acc
}

// MARK: - Hook matrix probes (observe/block on void ObjC+Swift; observe/block/replace/fault/delay inline)

/// Two @objc void methods hooked via set_objc_hooks. `ran` makes block observable.
@objc(OPMatrixObjC) final class OPMatrixObjC: NSObject {
    @objc static var ran = 0
    @objc func mObserve(_ data: NSData) { _ = data.length }
    @objc func mBlock() { OPMatrixObjC.ran += 1 }
}

/// Two overridable native-Swift (non-@objc) void methods hooked via set_swift_hooks. Base+override+
/// NSClassFromString instantiation forces genuine vtable dispatch. `ran` makes block observable.
class OPMatrixSwiftBase {
    static var ran = 0
    static var seen = 0
    required init() {}
    @inline(never) func sObserve() { OPMatrixSwiftBase.seen += 1 }
    @inline(never) func sBlock() { OPMatrixSwiftBase.ran += 1 }
}
final class OPMatrixSwift: OPMatrixSwiftBase {
    @inline(never) override func sObserve() { OPMatrixSwiftBase.seen += 1 }
    @inline(never) override func sBlock() { OPMatrixSwiftBase.ran += 1 }
}

/// Five value-returning inline (Tier-3) targets - one per rule action. DISTINCT constants (so the
/// optimizer's identical-code-folding doesn't merge them into one symbol) and @_optimize(none) (so each
/// keeps a full out-of-line ≥16-byte prologue the 16-byte absolute patch can displace). Each returns
/// a+N normally; a rule's effect shows in the result (block→0, replace→777, fault→-5) or timing (delay).
@inline(never) @_optimize(none) @_cdecl("optest_m_observe") public func optest_m_observe(_ a: Int32) -> Int32 { return a &+ 1 }
@inline(never) @_optimize(none) @_cdecl("optest_m_block")   public func optest_m_block(_ a: Int32) -> Int32   { return a &+ 2 }
@inline(never) @_optimize(none) @_cdecl("optest_m_replace") public func optest_m_replace(_ a: Int32) -> Int32 { return a &+ 3 }
@inline(never) @_optimize(none) @_cdecl("optest_m_fault")   public func optest_m_fault(_ a: Int32) -> Int32   { return a &+ 4 }
@inline(never) @_optimize(none) @_cdecl("optest_m_delay")   public func optest_m_delay(_ a: Int32) -> Int32   { return a &+ 5 }

/// Inline target whose argument registers hold ObjC object pointers (x0 = NSData, x1 = NSString) - the
/// gRPC-style shape the renderArgs feature decodes. Returns the data length so the call is verifiable.
@inline(never) @_optimize(none) @_cdecl("optest_render")
public func optest_render(_ data: UnsafeRawPointer, _ name: UnsafeRawPointer) -> Int32 {
    let d = Unmanaged<NSData>.fromOpaque(data).takeUnretainedValue()
    _ = Unmanaged<NSString>.fromOpaque(name).takeUnretainedValue()
    return Int32(d.length)
}

/// Second inline target, hooked via the config/MCP resolution path (set_inline_hooks by symbol).
@inline(never)
@_cdecl("optest_inline_target2")
public func optest_inline_target2(_ x: Int32) -> Int32 {
    return x &* 10
}
