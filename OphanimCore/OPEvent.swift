//
//  OPEvent.swift
//  OphanimCore
//
//  The canonical record emitted for every observed/intercepted call.
//

import Foundation

/// Broad category a hooked call belongs to. Used for routing, filtering and rule matching.
public enum OPCategory: String, Codable, CaseIterable, Sendable {
    case network
    case keychain
    case crypto
    case device
    case privacy
    case filesystem
    case process
    case jailbreak
}

/// Which instrumentation layer produced a record. Lets an analyst reason about provenance
/// (e.g. plaintext from the TLS layer vs. a structured URLSession record) and de-duplicate.
public enum OPCaptureLayer: String, Codable, Sendable {
    case tls            // boringssl SSL_read/SSL_write
    case urlProtocol    // custom NSURLProtocol
    case urlSession     // NSURLSession task/delegate swizzle
    case socket         // connect/getaddrinfo
    case objc           // generic ObjC swizzle
    case interpose      // DYLD_INTERPOSE / inline C wrapper
}

/// What the interception engine decided to do with a call.
public enum OPDisposition: String, Codable, Sendable {
    case observed       // logged, original behavior unchanged
    case argsModified   // input arguments were rewritten
    case returnReplaced // return value / response was replaced
    case blocked        // call was prevented from running
    case delayed        // call was delayed before running
    case faulted        // call was forced to fail
}

/// One structured event. Encodes cleanly to NDJSON and to a flat plain-text line.
public struct OPEvent: Codable, Sendable {
    public var timestamp: Date
    public var category: OPCategory
    public var layer: OPCaptureLayer
    public var api: String                       // e.g. "SecItemCopyMatching", "NSURLSession.dataTask"
    public var thread: String                    // human-readable thread id/name
    public var summary: String                   // short one-line description
    public var fields: [String: String]          // structured key/values (host, path, status, …)
    public var requestBody: Data?                // captured payloads (subject to body cap)
    public var responseBody: Data?
    public var disposition: OPDisposition
    public var matchedRuleID: String?            // rule that drove an interception, if any
    public var backtrace: [String]?              // optional symbolicated frames

    public init(category: OPCategory,
                layer: OPCaptureLayer,
                api: String,
                summary: String = "",
                fields: [String: String] = [:],
                requestBody: Data? = nil,
                responseBody: Data? = nil,
                disposition: OPDisposition = .observed,
                matchedRuleID: String? = nil,
                backtrace: [String]? = nil,
                timestamp: Date = Date(),
                thread: String = OPEvent.currentThreadLabel()) {
        self.timestamp = timestamp
        self.category = category
        self.layer = layer
        self.api = api
        self.thread = thread
        self.summary = summary
        self.fields = fields
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.disposition = disposition
        self.matchedRuleID = matchedRuleID
        self.backtrace = backtrace
    }

    public static func currentThreadLabel() -> String {
        if Thread.isMainThread { return "main" }
        let name = Thread.current.name ?? ""
        return name.isEmpty ? String(format: "%p", Thread.current) : name
    }

    /// Flat, grep-friendly single line for the plain-text sink.
    public func plainTextLine(iso: ISO8601DateFormatter) -> String {
        var parts = ["[\(iso.string(from: timestamp))]",
                     category.rawValue.uppercased(),
                     "(\(layer.rawValue))",
                     api]
        if disposition != .observed { parts.append("<\(disposition.rawValue)>") }
        if !summary.isEmpty { parts.append("- \(summary)") }
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) { parts.append("\(k)=\(v)") }
        return parts.joined(separator: " ")
    }

    // MARK: - Codable

    // Bodies are stored READABLY: UTF-8-decodable payloads (JSON, form data, HTML…) are written as
    // plain text so the NDJSON is human-readable; genuinely binary payloads fall back to base64,
    // flagged by `*BodyEncoding`. The default JSONEncoder would base64 every `Data`, which is why
    // text bodies used to look "encrypted" in the log.
    private enum CodingKeys: String, CodingKey {
        case timestamp, category, layer, api, thread, summary, fields
        case requestBody, requestBodyEncoding
        case responseBody, responseBodyEncoding
        case disposition, matchedRuleID, backtrace
    }

    private static func encodeBody(_ data: Data?, into c: inout KeyedEncodingContainer<CodingKeys>,
                                   body: CodingKeys, enc: CodingKeys) throws {
        guard let data = data else { return }
        if let text = String(data: data, encoding: .utf8),
           !text.unicodeScalars.contains(where: { $0.value < 0x09 || ($0.value > 0x0D && $0.value < 0x20) }) {
            try c.encode(text, forKey: body)
            try c.encode("utf8", forKey: enc)
        } else {
            try c.encode(data.base64EncodedString(), forKey: body)
            try c.encode("base64", forKey: enc)
        }
    }

    private static func decodeBody(_ c: KeyedDecodingContainer<CodingKeys>,
                                   body: CodingKeys, enc: CodingKeys) -> Data? {
        guard let s = try? c.decodeIfPresent(String.self, forKey: body) else { return nil }
        let encoding = (try? c.decodeIfPresent(String.self, forKey: enc)) ?? "utf8"
        return encoding == "base64" ? Data(base64Encoded: s) : Data(s.utf8)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(category, forKey: .category)
        try c.encode(layer, forKey: .layer)
        try c.encode(api, forKey: .api)
        try c.encode(thread, forKey: .thread)
        try c.encode(summary, forKey: .summary)
        try c.encode(fields, forKey: .fields)
        try OPEvent.encodeBody(requestBody, into: &c, body: .requestBody, enc: .requestBodyEncoding)
        try OPEvent.encodeBody(responseBody, into: &c, body: .responseBody, enc: .responseBodyEncoding)
        try c.encode(disposition, forKey: .disposition)
        try c.encodeIfPresent(matchedRuleID, forKey: .matchedRuleID)
        try c.encodeIfPresent(backtrace, forKey: .backtrace)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        category = try c.decode(OPCategory.self, forKey: .category)
        layer = try c.decode(OPCaptureLayer.self, forKey: .layer)
        api = try c.decode(String.self, forKey: .api)
        thread = try c.decode(String.self, forKey: .thread)
        summary = try c.decode(String.self, forKey: .summary)
        fields = try c.decode([String: String].self, forKey: .fields)
        requestBody = OPEvent.decodeBody(c, body: .requestBody, enc: .requestBodyEncoding)
        responseBody = OPEvent.decodeBody(c, body: .responseBody, enc: .responseBodyEncoding)
        disposition = try c.decode(OPDisposition.self, forKey: .disposition)
        matchedRuleID = try c.decodeIfPresent(String.self, forKey: .matchedRuleID)
        backtrace = try c.decodeIfPresent([String].self, forKey: .backtrace)
    }
}
