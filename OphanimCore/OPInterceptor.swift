//
//  OPInterceptor.swift
//  OphanimCore
//
//  The policy engine. Each hook builds an OPCallContext, asks the interceptor for a decision,
//  applies it, then emits the resulting event. Observe-by-default: with no matching rule the
//  decision is `.observe` and the original call runs untouched.
//

import Foundation
import JavaScriptCore

/// Mutable description of an in-flight call handed to the interceptor (and to JS scripts).
public final class OPCallContext {
    public let category: OPCategory
    public let layer: OPCaptureLayer
    public let api: String
    public var fields: [String: String]
    public var host: String?
    public var url: String?
    public var path: String?
    public var requestBody: Data?
    public var responseBody: Data?

    public init(category: OPCategory, layer: OPCaptureLayer, api: String,
                fields: [String: String] = [:], host: String? = nil, url: String? = nil,
                path: String? = nil, requestBody: Data? = nil, responseBody: Data? = nil) {
        self.category = category; self.layer = layer; self.api = api
        self.fields = fields; self.host = host; self.url = url; self.path = path
        self.requestBody = requestBody; self.responseBody = responseBody
    }

    /// Any-arg substring search target used by OPMatcher.argContains.
    var stringifiedArgs: String {
        ([api, host, url, path].compactMap { $0 } + fields.map { "\($0)=\($1)" }).joined(separator: " ")
    }
}

/// Outcome of consulting the rules: what to do plus any replacement payload.
public struct OPDecision {
    public var disposition: OPDisposition
    public var matchedRuleID: String?
    public var replacementBody: Data?
    public var replacementHeaders: [String: String]?
    public var replacementStatus: Int?
    public var cannedReturnValue: String?
    public var delay: TimeInterval
    public var faultErrorCode: Int?

    public static let observe = OPDecision(disposition: .observed, matchedRuleID: nil,
                                           replacementBody: nil, replacementHeaders: nil,
                                           replacementStatus: nil, cannedReturnValue: nil,
                                           delay: 0, faultErrorCode: nil)
}

public final class OPInterceptor {
    private let rules: [OPRule]
    private let jsContext: JSContext?
    private let jsLock = NSLock()   // JSContext is not thread-safe; decide() runs on many threads

    public init(rules: [OPRule]) {
        self.rules = rules.filter { $0.enabled }
        // Only stand up a JS context if some rule actually needs scripting.
        if rules.contains(where: { $0.action.kind == .script }) {
            self.jsContext = JSContext()
            self.jsContext?.exceptionHandler = { _, exc in
                NSLog("[Ophanim] JS rule error: \(exc?.toString() ?? "unknown")")
            }
        } else {
            self.jsContext = nil
        }
    }

    /// Resolve a decision for a call. First matching rule wins.
    public func decide(_ ctx: OPCallContext) -> OPDecision {
        for rule in rules where matches(rule.match, ctx) {
            return apply(rule, ctx)
        }
        return .observe
    }

    // MARK: - Matching

    private func matches(_ m: OPMatcher, _ ctx: OPCallContext) -> Bool {
        if let cats = m.categories, !cats.contains(ctx.category) { return false }
        if let g = m.apiGlob, !OPGlob.match(g, ctx.api) { return false }
        if let g = m.hostGlob, !(ctx.host.map { OPGlob.match(g, $0) } ?? false) { return false }
        if let g = m.urlGlob, !(ctx.url.map { OPGlob.match(g, $0) } ?? false) { return false }
        if let g = m.pathGlob, !(ctx.path.map { OPGlob.match(g, $0) } ?? false) { return false }
        if let sub = m.argContains, !ctx.stringifiedArgs.localizedCaseInsensitiveContains(sub) { return false }
        return true
    }

    // MARK: - Action application

    private func apply(_ rule: OPRule, _ ctx: OPCallContext) -> OPDecision {
        let a = rule.action
        switch a.kind {
        case .observe:
            return decision(.observed, rule)
        case .block:
            return decision(.blocked, rule)
        case .delay:
            var d = decision(.delayed, rule)
            d.delay = TimeInterval(a.delayMilliseconds ?? 0) / 1000.0
            return d
        case .fault:
            var d = decision(.faulted, rule)
            d.faultErrorCode = a.faultErrorCode
            return d
        case .modifyArgs:
            var d = decision(.argsModified, rule)
            d.replacementBody = a.replacementBodyBase64.flatMap { Data(base64Encoded: $0) }
            d.replacementHeaders = a.replacementHeaders
            return d
        case .replaceReturn:
            var d = decision(.returnReplaced, rule)
            d.replacementBody = a.replacementBodyBase64.flatMap { Data(base64Encoded: $0) }
            d.replacementHeaders = a.replacementHeaders
            d.replacementStatus = a.replacementStatus
            d.cannedReturnValue = a.cannedReturnValue
            return d
        case .script:
            return runScript(a.script ?? "", rule, ctx)
        }
    }

    private func decision(_ disp: OPDisposition, _ rule: OPRule) -> OPDecision {
        var d = OPDecision.observe
        d.disposition = disp
        d.matchedRuleID = rule.id
        return d
    }

    /// Evaluate a JS rule. The script sees `ctx` and may set `ctx.replacementBody` (base64),
    /// `ctx.replacementStatus`, `ctx.block = true`, or `ctx.returnValue`.
    private func runScript(_ source: String, _ rule: OPRule, _ ctx: OPCallContext) -> OPDecision {
        guard let js = jsContext else { return decision(.observed, rule) }
        jsLock.lock(); defer { jsLock.unlock() }
        let bridge: [String: Any] = [
            "category": ctx.category.rawValue,
            "api": ctx.api,
            "host": ctx.host as Any,
            "url": ctx.url as Any,
            "path": ctx.path as Any,
            "requestBodyBase64": ctx.requestBody?.base64EncodedString() as Any,
            "responseBodyBase64": ctx.responseBody?.base64EncodedString() as Any,
            "fields": ctx.fields,
            "block": false
        ]
        js.setObject(bridge, forKeyedSubscript: "ctx" as NSString)
        js.evaluateScript(source)
        guard let out = js.objectForKeyedSubscript("ctx") else { return decision(.observed, rule) }

        if out.objectForKeyedSubscript("block")?.toBool() == true {
            return decision(.blocked, rule)
        }
        var changed = false
        var d = decision(.returnReplaced, rule)
        if let b64 = out.objectForKeyedSubscript("replacementBody")?.toString(), !b64.isEmpty, b64 != "undefined",
           let data = Data(base64Encoded: b64) {
            d.replacementBody = data; changed = true
        }
        if let status = out.objectForKeyedSubscript("replacementStatus"), status.isNumber {
            d.replacementStatus = Int(status.toInt32()); changed = true
        }
        if let rv = out.objectForKeyedSubscript("returnValue")?.toString(), rv != "undefined", !rv.isEmpty {
            d.cannedReturnValue = rv; changed = true
        }
        return changed ? d : decision(.observed, rule)
    }
}

/// Minimal shell-style glob matcher supporting `*` and `?`. Anchored full-string match.
public enum OPGlob {
    public static func match(_ pattern: String, _ text: String) -> Bool {
        // Translate to NSRegularExpression for a robust full-string match.
        var rx = "^"
        for ch in pattern {
            switch ch {
            case "*": rx += ".*"
            case "?": rx += "."
            default: rx += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        rx += "$"
        guard let re = try? NSRegularExpression(pattern: rx, options: [.caseInsensitive]) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }
}
