//
//  OPHooksNetwork.swift
//  OphanimCore
//
//  Network capture - Layer 2/3: a custom URLProtocol that observes every HTTP(S) request/response
//  routed through the URL Loading System, plus a URLSessionConfiguration swizzle so custom sessions
//  (not just URLSession.shared) are covered. Supports interception: a matching rule can BLOCK a
//  request or REPLACE its response with a canned body/status. TLS-plaintext (boringssl) and raw
//  socket (connect/getaddrinfo) layers are added separately.
//
//  Limitations: (1) WebSocket frames don't traverse URLProtocol - captured separately below by
//  swizzling URLSessionWebSocketTask send/receive. (2) Background URLSessions run out-of-process
//  (nsurlsessiond) and ignore custom protocolClasses, so their HTTP bodies aren't capturable here.
//

import Foundation

enum OPNetworkHooks {
    static func install() {
        guard OPAgent.shared.isActive(.network) else { return }
        URLProtocol.registerClass(OPURLProtocol.self)          // covers URLSession.shared
        swizzleSessionConfig("defaultSessionConfiguration")    // covers .default sessions
        swizzleSessionConfig("ephemeralSessionConfiguration")  // covers .ephemeral sessions
        installWebSocketHooks()                                // covers URLSessionWebSocketTask
    }

    // MARK: - WebSocket capture (URLProtocol doesn't see WS frames)

    private static func installWebSocketHooks() {
        // send/receive are implemented on the concrete __NSURLSessionWebSocketTask subclass; the
        // public NSURLSessionWebSocketTask is abstract. Prefer the concrete class.
        guard let cls = NSClassFromString("__NSURLSessionWebSocketTask")
                     ?? NSClassFromString("NSURLSessionWebSocketTask") else { return }
        swizzleWSSend(cls)
        swizzleWSReceive(cls)
    }

    private static func swizzleWSSend(_ cls: AnyClass) {
        let sel = NSSelectorFromString("sendMessage:completionHandler:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { task, msg, handler in
            emitWS(task: task, msg: msg, dir: "send")
            orig(task, sel, msg, handler)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func swizzleWSReceive(_ cls: AnyClass) {
        let sel = NSSelectorFromString("receiveMessageWithCompletionHandler:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { task, handler in
            // Wrap the completion so we log the received message, then forward to the app.
            let wrapped: @convention(block) (AnyObject?, AnyObject?) -> Void = { message, error in
                emitWS(task: task, msg: message, dir: "receive")
                if let handler = handler {
                    let call = unsafeBitCast(handler, to: (@convention(block) (AnyObject?, AnyObject?) -> Void).self)
                    call(message, error)
                }
            }
            orig(task, sel, wrapped as AnyObject)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func emitWS(task: AnyObject, msg: AnyObject?, dir: String) {
        guard OPAgent.shared.isActive(.network) else { return }
        var host: String?
        if let req = task.value(forKey: "currentRequest") as? URLRequest { host = req.url?.host }
        let str = msg?.value(forKey: "string") as? String
        let data = (msg?.value(forKey: "data") as? Data) ?? str?.data(using: .utf8)
        let ctx = OPCallContext(category: .network, layer: .objc,
                                api: "URLSessionWebSocketTask.\(dir)",
                                fields: ["transport": "websocket"], host: host)
        if dir == "send" { ctx.requestBody = data } else { ctx.responseBody = data }
        let decision = OPAgent.shared.intercept(ctx)
        OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                    summary: "WebSocket \(dir) \(data?.count ?? 0) bytes"))
    }

    /// Swizzle a URLSessionConfiguration class getter to prepend our protocol to protocolClasses.
    private static func swizzleSessionConfig(_ name: String) {
        let sel = NSSelectorFromString(name)
        guard let m = class_getClassMethod(URLSessionConfiguration.self, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> URLSessionConfiguration
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (AnyObject) -> URLSessionConfiguration = { obj in
            let cfg = orig(obj, sel)
            var protos = cfg.protocolClasses ?? []
            if !protos.contains(where: { $0 === OPURLProtocol.self }) {
                protos.insert(OPURLProtocol.self, at: 0)
                cfg.protocolClasses = protos
            }
            return cfg
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}

final class OPURLProtocol: URLProtocol, URLSessionDataDelegate {
    private static let handledKey = "be.ophanim.handled"
    private var session: URLSession?
    private var proxyTask: URLSessionDataTask?
    private var responseData = Data()
    private var httpResponse: HTTPURLResponse?
    private var ctx: OPCallContext?
    private var decision: OPDecision = .observe

    override class func canInit(with request: URLRequest) -> Bool {
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        var fields: [String: String] = ["method": req.httpMethod ?? "GET"]
        if let h = req.allHTTPHeaderFields { for (k, v) in h { fields["req.\(k)"] = v } }
        let ctx = OPCallContext(category: .network, layer: .urlProtocol, api: "URLSession.request",
                                fields: fields, host: req.url?.host, url: req.url?.absoluteString,
                                requestBody: req.httpBody)
        self.ctx = ctx
        let decision = OPAgent.shared.intercept(ctx)
        self.decision = decision

        switch decision.disposition {
        case .blocked:
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision, summary: "blocked"))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        case .returnReplaced where decision.replacementBody != nil:
            let body = decision.replacementBody ?? Data()
            let status = decision.replacementStatus ?? 200
            let headers = decision.replacementHeaders ?? ["Content-Type": "application/octet-stream"]
            ctx.responseBody = body
            if let url = req.url,
               let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                          headerFields: headers) {
                OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                                                            summary: "canned \(status)"))
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            fallthrough
        default:
            // Pass through: re-issue the request with a marker so we don't re-enter.
            guard let mutable = (req as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
            URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
            // Drop the app's explicit Accept-Encoding so URLSession manages compression itself and
            // hands us DECOMPRESSED bytes - otherwise we'd capture (and log) raw gzip/brotli, which
            // looks like encrypted garbage. URLSession still negotiates gzip transparently.
            mutable.setValue(nil, forHTTPHeaderField: "Accept-Encoding")
            session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            proxyTask = session?.dataTask(with: mutable as URLRequest)
            proxyTask?.resume()
        }
    }

    override func stopLoading() {
        proxyTask?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        httpResponse = response as? HTTPURLResponse
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let ctx = ctx {
            ctx.responseBody = responseData
            if let r = httpResponse {
                ctx.fields["status"] = String(r.statusCode)
                for (k, v) in r.allHeaderFields { ctx.fields["resp.\(k)"] = "\(v)" }
            }
            OPAgent.shared.observe(OPAgent.shared.event(from: ctx, decision: decision,
                summary: error == nil ? "ok" : "error: \(error!.localizedDescription)"))
        }
        if let error = error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
        self.session?.finishTasksAndInvalidate()
    }
}
