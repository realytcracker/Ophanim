//
//  MCPServer.swift
//  Ophanim
//
//  A small, dependency-free Model Context Protocol server so an AI client can drive Ophanim:
//  list hosted apps, query/search captured instrumentation events, read per-app capture config,
//  mutate that config (enable instrumentation, toggle capture categories / sinks), and launch apps.
//
//  The protocol core (MCPServer) is transport-agnostic JSON-RPC 2.0 + the MCP lifecycle. Two
//  transports feed it: MCPStdioTransport (the headless `--mcp` mode an MCP client spawns) and
//  MCPHTTPTransport (a loopback HTTP server on port 20033 the running GUI hosts). Both share the
//  same MCPData file-backed layer, so they work with or without the GUI running.
//

import Foundation
import Darwin
#if canImport(AppKit)
import AppKit
#endif

/// The default local MCP endpoint port.
let kMCPPort: UInt16 = 20033

/// The configured MCP HTTP port (UserDefaults `ophanim.mcp.port`), falling back to kMCPPort when
/// unset or out of the valid range.
var mcpConfiguredPort: UInt16 {
    let v = UserDefaults.standard.integer(forKey: "ophanim.mcp.port")
    return (1024...65535).contains(v) ? UInt16(v) : kMCPPort
}

/// The configured bind address as a string: "loopback" (default, 127.0.0.1), "all" (0.0.0.0 - all
/// interfaces), or a specific IPv4 address. UserDefaults `ophanim.mcp.bind` holds the mode; when it
/// is "specific" the address is read from `ophanim.mcp.bindIP`.
var mcpConfiguredBind: String {
    let mode = UserDefaults.standard.string(forKey: "ophanim.mcp.bind") ?? "loopback"
    if mode == "specific" {
        let ip = UserDefaults.standard.string(forKey: "ophanim.mcp.bindIP") ?? ""
        return ip.isEmpty ? "loopback" : ip
    }
    return mode
}

/// Resolve a bind mode/address string to a network-order IPv4 address. Falls back to loopback for
/// anything unrecognized so we never accidentally bind wide open.
func mcpResolveBind(_ mode: String) -> in_addr_t {
    switch mode.lowercased() {
    case "loopback", "local", "127.0.0.1": return inet_addr("127.0.0.1")
    case "all", "any", "0.0.0.0", "*":     return in_addr_t(0)   // INADDR_ANY
    default:
        let a = inet_addr(mode)
        return a == INADDR_NONE ? inet_addr("127.0.0.1") : a
    }
}

// MARK: - Protocol core

final class MCPServer {
    static let shared = MCPServer()
    private let serverName = "ophanim"
    private let serverVersion = "1.0.0"

    /// Dispatch one JSON-RPC message. Returns the response object, or nil for notifications.
    func handle(_ msg: [String: Any]) -> [String: Any]? {
        let id = msg["id"]
        guard let method = msg["method"] as? String else { return nil }
        let params = msg["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let pv = params["protocolVersion"] as? String ?? "2025-06-18"
            return result(id, [
                "protocolVersion": pv,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": serverName, "version": serverVersion],
                "instructions": "Ophanim instruments iOS apps running on macOS. Use list_apps to "
                    + "find a bundle ID, query_events to read captured behavior, get_config/set_config "
                    + "to inspect and change what is captured, and launch_app to run one."
            ])
        case "ping":
            return result(id, [:])
        case "notifications/initialized", "notifications/cancelled":
            return nil   // notifications take no reply
        case "tools/list":
            return result(id, ["tools": Self.toolDefinitions])
        case "tools/call":
            return callTool(id, name: params["name"] as? String ?? "",
                            arguments: params["arguments"] as? [String: Any] ?? [:])
        default:
            return error(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: Tool dispatch

    private func callTool(_ id: Any?, name: String, arguments args: [String: Any]) -> [String: Any]? {
        do {
            let text = try runTool(name, args)
            return result(id, ["content": [["type": "text", "text": text]], "isError": false])
        } catch let e as ToolError {
            return result(id, ["content": [["type": "text", "text": "Error: \(e.message)"]], "isError": true])
        } catch {
            return result(id, ["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true])
        }
    }

    struct ToolError: Error { let message: String }
    private func bail(_ m: String) -> ToolError { ToolError(message: m) }

    private func runTool(_ name: String, _ args: [String: Any]) throws -> String {
        switch name {
        case "list_apps":
            let apps = MCPData.listApps().map { app -> [String: Any] in
                let cfg = MCPData.config(app.bundleID)
                return [
                    "bundleID": app.bundleID,
                    "name": app.name,
                    "version": app.version,
                    "instrumentationEnabled": cfg?.enabled ?? false,
                    "captureCategories": cfg?.categories.map { $0.rawValue } ?? []
                ]
            }
            return try json(["count": apps.count, "apps": apps])

        case "query_events":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            let category = args["category"] as? String
            let search = args["search"] as? String
            let limit = (args["limit"] as? Int) ?? 200
            let events = MCPData.events(bid, category: category, search: search, limit: limit)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(events)
            let arr = (try? JSONSerialization.jsonObject(with: data)) ?? []
            return try json(["count": events.count, "events": arr])

        case "tail_events":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            let since = (args["since"] as? Double) ?? Double((args["since"] as? Int) ?? 0)
            let limit = (args["limit"] as? Int) ?? 100
            let all = MCPData.events(bid, category: nil, search: nil, limit: 0)
            let fresh = all.filter { $0.timestamp.timeIntervalSince1970 * 1000 > since }
            let slice = fresh.count > limit ? Array(fresh.suffix(limit)) : fresh
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let arr = (try? JSONSerialization.jsonObject(with: enc.encode(slice))) ?? []
            let cursor = (all.last?.timestamp.timeIntervalSince1970 ?? 0) * 1000
            return try json(["count": slice.count, "cursor": cursor, "events": arr])

        case "analyze_app":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            return try json(MCPData.report(bid))

        case "app_imports":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            let surface = MCPData.importSurface(bid)
            let total = surface.values.reduce(0) { $0 + $1.count }
            return try json(["bundleID": bid, "interposableSymbols": total, "surface": surface])

        case "find_symbols":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            guard let kw = args["keyword"] as? String, !kw.isEmpty else { throw bail("keyword is required") }
            return try json(MCPData.findSymbols(bid, kw))

        case "set_objc_hooks":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            guard let hooksArg = args["hooks"] else { throw bail("hooks array is required") }
            let data = try JSONSerialization.data(withJSONObject: hooksArg)
            let hooks: [OPObjCHook]
            do { hooks = try JSONDecoder().decode([OPObjCHook].self, from: data) }
            catch { throw bail("invalid hooks: \(error.localizedDescription)") }
            try MCPData.updateSettings(bid) { $0.ophanim.objcHooks = hooks }
            return "Set \(hooks.count) ObjC boundary hook(s) for \(bid)."

        case "set_swift_hooks":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            guard let hooksArg = args["hooks"] else { throw bail("hooks array is required") }
            let data = try JSONSerialization.data(withJSONObject: hooksArg)
            let hooks: [OPSwiftHook]
            do { hooks = try JSONDecoder().decode([OPSwiftHook].self, from: data) }
            catch { throw bail("invalid hooks: \(error.localizedDescription)") }
            try MCPData.updateSettings(bid) { $0.ophanim.swiftHooks = hooks }
            return "Set \(hooks.count) native-Swift vtable hook(s) for \(bid)."

        case "set_inline_hooks":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            guard let hooksArg = args["hooks"] else { throw bail("hooks array is required") }
            let data = try JSONSerialization.data(withJSONObject: hooksArg)
            let hooks: [OPInlineHook]
            do { hooks = try JSONDecoder().decode([OPInlineHook].self, from: data) }
            catch { throw bail("invalid hooks: \(error.localizedDescription)") }
            try MCPData.updateSettings(bid) { $0.ophanim.inlineHooks = hooks }
            let gate = (MCPData.appSettings(bid)?.ophanim.enableInlineHooks ?? false)
            return "Set \(hooks.count) inline hook(s) for \(bid)."
                + (gate ? "" : " NOTE: inline hooks are OFF - call set_config enableInlineHooks=true to arm them.")

        case "list_presets":
            return try json(["presets": [
                ["name": "block-trackers", "description": "Block network requests to known tracker/analytics/ad hosts"],
                ["name": "fake-idfv", "description": "Return a fixed fake identifierForVendor"],
                ["name": "fake-idfa", "description": "Return a fixed fake advertising identifier"]
            ]])

        case "apply_preset":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            guard let name = args["preset"] as? String else { throw bail("preset is required") }
            let dicts = try Self.presetRules(name)
            let data = try JSONSerialization.data(withJSONObject: dicts)
            let preset = try JSONDecoder().decode([OPRule].self, from: data)
            var finalCount = 0
            try MCPData.updateSettings(bid) { s in
                let ids = Set(s.ophanim.rules.map { $0.id })
                s.ophanim.rules.append(contentsOf: preset.filter { !ids.contains($0.id) })
                finalCount = s.ophanim.rules.count
            }
            return "Applied preset '\(name)' (\(preset.count) rule(s)); \(bid) now has \(finalCount) rule(s)."

        case "set_rules":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            guard let rulesArg = args["rules"] else { throw bail("rules array is required") }
            let data = try JSONSerialization.data(withJSONObject: rulesArg)
            let rules: [OPRule]
            do { rules = try JSONDecoder().decode([OPRule].self, from: data) }
            catch { throw bail("invalid rules: \(error.localizedDescription)") }
            try MCPData.updateSettings(bid) { $0.ophanim.rules = rules }
            return "Set \(rules.count) rule(s) for \(bid)."

        case "get_config":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            guard let settings = MCPData.appSettings(bid) else { throw bail("no settings found for \(bid)") }
            let data = try JSONEncoder().encode(settings)
            return String(data: data, encoding: .utf8) ?? "{}"

        case "list_jailbreak_detectors":
            let dets = JBBypassCatalog.all.map { ["id": $0.id, "label": $0.label] }
            return try json(["count": dets.count, "detectors": dets])

        case "set_config":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            try MCPData.updateSettings(bid) { s in
                // Instrumentation (OphanimCore)
                if let on = args["enabled"] as? Bool { s.ophanim.enabled = on }
                if let on = args["autoOpenLog"] as? Bool { s.ophanim.autoOpenLog = on }
                if let on = args["captureBacktraces"] as? Bool { s.ophanim.captureBacktraces = on }
                if let on = args["bypassPinning"] as? Bool { s.ophanim.bypassPinning = on }
                if let on = args["enableInlineHooks"] as? Bool { s.ophanim.enableInlineHooks = on }
                if let cats = args["categories"] as? [String] {
                    s.ophanim.categories = OPCategory.allCases.filter { cats.contains($0.rawValue) }
                }
                if let sinks = args["sinks"] as? [String] {
                    var sel: OPSinkSelection = []
                    if sinks.contains("ndjson") { sel.insert(.ndjson) }
                    if sinks.contains("text") || sinks.contains("plainText") { sel.insert(.plainText) }
                    if sinks.contains("console") || sinks.contains("osLog") { sel.insert(.osLog) }
                    s.ophanim.sinks = sel
                }
                // Jailbreak / root-detection bypass
                if let on = args["jailbreakBypass"] as? Bool { s.bypass = on }
                if let jb = args["jailbreakBypasses"] {
                    if let str = jb as? String {
                        s.jailbreakBypasses = (str == "all") ? JBBypassCatalog.allIDs : (str == "none" ? [] : s.jailbreakBypasses)
                    } else if let arr = jb as? [String] {
                        if arr == ["all"] { s.jailbreakBypasses = JBBypassCatalog.allIDs }
                        else if arr == ["none"] || arr.isEmpty { s.jailbreakBypasses = [] }
                        else { s.jailbreakBypasses = JBBypassCatalog.allIDs.filter { arr.contains($0) } }   // validated
                    }
                }
                // Keychain emulation
                if let on = args["chainGuard"] as? Bool { s.chainGuard = on }
                if let on = args["chainGuardDebugging"] as? Bool { s.chainGuardDebugging = on }
                // Window / display (per-app)
                if let on = args["alwaysOnTop"] as? Bool { s.floatingWindow = on }
                if let on = args["disableDisplaySleep"] as? Bool { s.disableTimeout = on }
                if let on = args["hideTitleBar"] as? Bool { s.hideTitleBar = on }
                // Compatibility
                if let on = args["rootWorkDir"] as? Bool { s.rootWorkDir = on }
                if let on = args["limitMotionUpdateFrequency"] as? Bool { s.limitMotionUpdateFrequency = on }
                if let on = args["blockSleepSpamming"] as? Bool { s.blockSleepSpamming = on }
                if let on = args["checkMicPermissionSync"] as? Bool { s.checkMicPermissionSync = on }
                // Input
                if let on = args["keymapping"] as? Bool { s.keymapping = on }
                // Device
                if let model = args["iosDeviceModel"] as? String { s.iosDeviceModel = model }
            }
            let settings = MCPData.appSettings(bid)
            let data = try JSONEncoder().encode(settings)
            return "Updated. New settings:\n" + (String(data: data, encoding: .utf8) ?? "{}")

        case "launch_app":
            guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
            guard let url = MCPData.appURL(bid) else { throw bail("app not installed: \(bid)") }
            #if canImport(AppKit)
            let sema = DispatchSemaphore(value: 0)
            var launchError: Error?
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                launchError = err; sema.signal()
            }
            _ = sema.wait(timeout: .now() + 15)
            if let launchError { throw bail("launch failed: \(launchError.localizedDescription)") }
            return "Launched \(bid)."
            #else
            throw bail("launch is not supported in this build")
            #endif

        default:
            throw bail("unknown tool: \(name)")
        }
    }

    // MARK: JSON-RPC helpers

    private func result(_ id: Any?, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }
    private func error(_ id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
    private func json(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Rule dictionaries for a named preset (decoded into [OPRule] by apply_preset).
    private static func presetRules(_ name: String) throws -> [[String: Any]] {
        switch name {
        case "block-trackers":
            let domains = MCPData.trackerCatalog.keys.map { "\"\($0)\"" }.joined(separator: ",")
            let js = "var t=[\(domains)];if(ctx.host){for(var i=0;i<t.length;i++)" +
                     "{if(ctx.host.indexOf(t[i])>=0){ctx.block=true;break;}}}"
            return [["id": "op-block-trackers", "enabled": true, "note": "Block known tracker/analytics/ad hosts",
                     "match": ["categories": ["network"]],
                     "action": ["kind": "script", "script": js]]]
        case "fake-idfv":
            return [["id": "op-fake-idfv", "enabled": true, "note": "Fake identifierForVendor",
                     "match": ["apiGlob": "UIDevice.identifierForVendor"],
                     "action": ["kind": "script", "script": "ctx.returnValue='00000000-0000-0000-0000-0000DEADBEEF';"]]]
        case "fake-idfa":
            return [["id": "op-fake-idfa", "enabled": true, "note": "Fake advertising identifier",
                     "match": ["apiGlob": "ASIdentifierManager.advertisingIdentifier"],
                     "action": ["kind": "script", "script": "ctx.returnValue='00000000-0000-0000-0000-00000000AD1D';"]]]
        default:
            throw ToolError(message: "unknown preset '\(name)' - use list_presets")
        }
    }

    // MARK: Tool catalog

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_apps",
            "description": "List the iOS apps installed in Ophanim, with each app's bundle ID, name, "
                + "version, whether instrumentation is enabled, and which capture categories are active.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
        ],
        [
            "name": "query_events",
            "description": "Return captured instrumentation events for an app (filesystem, network, "
                + "keychain, crypto, process, jailbreak, etc.), newest last. Optionally filter by "
                + "category and/or a free-text search across api/summary/fields.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier (from list_apps)."],
                    "category": ["type": "string", "description": "Optional category filter, e.g. network, filesystem, keychain, crypto, process, jailbreak, device, privacy."],
                    "search": ["type": "string", "description": "Optional case-insensitive substring matched against api, summary, and field values."],
                    "limit": ["type": "integer", "description": "Max events to return (default 200, newest kept)."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "tail_events",
            "description": "Stream new captured events since a cursor. Pass the `cursor` returned by a "
                + "previous call as `since` to get only events captured since then - for live monitoring.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "since": ["type": "number", "description": "Cursor (epoch milliseconds) from a prior call; omit/0 for the latest batch."],
                    "limit": ["type": "integer", "description": "Max events to return (default 100, newest)."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "analyze_app",
            "description": "Produce a behavior/privacy report for an app from its captured events: hosts "
                + "contacted, identifiers & privacy APIs accessed, keychain items, crypto usage, jailbreak "
                + "probes/bypasses, certificate-pinning activity, and processes/libraries/URLs launched.",
            "inputSchema": [
                "type": "object",
                "properties": ["bundleID": ["type": "string", "description": "The app's bundle identifier."]],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "list_presets",
            "description": "List ready-made rule presets (block-trackers, fake-idfv, fake-idfa) you can apply with apply_preset.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
        ],
        [
            "name": "apply_preset",
            "description": "Apply a named rule preset to an app (merges into existing rules, by id). "
                + "block-trackers blocks known tracker/analytics/ad hosts; fake-idfv/fake-idfa return fixed fake identifiers.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "preset": ["type": "string", "description": "Preset name: block-trackers | fake-idfv | fake-idfa."]
                ],
                "required": ["bundleID", "preset"]
            ]
        ],
        [
            "name": "set_rules",
            "description": "Replace an app's interception rules. Each rule = {id, enabled, note?, "
                + "match:{categories?,apiGlob?,hostGlob?,urlGlob?,pathGlob?,argContains?}, "
                + "action:{kind, ...}} where kind ∈ observe|block|delay|fault|modifyArgs|replaceReturn|script. "
                + "For script rules set action.script to JS that reads/sets ctx (ctx.block=true, "
                + "ctx.returnValue, ctx.replacementBody[base64], ctx.replacementStatus). Takes effect live on a running app.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "rules": ["type": "array", "items": ["type": "object"], "description": "Full rules array (replaces existing)."]
                ],
                "required": ["bundleID", "rules"]
            ]
        ],
        [
            "name": "get_config",
            "description": "Read the full per-app settings as JSON - instrumentation (enabled, capture "
                + "categories, sinks, rules, bypassPinning, injection strategy) plus jailbreak bypasses, "
                + "ChainGuard, and window/graphics/compatibility options.",
            "inputSchema": [
                "type": "object",
                "properties": ["bundleID": ["type": "string", "description": "The app's bundle identifier."]],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "app_imports",
            "description": "Report an app's dynamically-imported TLS/crypto/keychain/process symbols - "
                + "the surface DYLD_INTERPOSE can hook. Crucial for statically-linked apps: even a "
                + "self-contained binary imports the OS's crypto/TLS primitives (e.g. Secure Transport "
                + "SSLRead/SSLWrite, SecTrustEvaluate), and those calls are interposable.",
            "inputSchema": [
                "type": "object",
                "properties": ["bundleID": ["type": "string", "description": "The app's bundle identifier."]],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "find_symbols",
            "description": "Search an app binary for symbols / ObjC class & selector names matching a "
                + "keyword - recon for finding @objc boundary hook targets (then hook with set_objc_hooks). "
                + "Returns demangled symbols, Swift class names, and selectors.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "keyword": ["type": "string", "description": "Substring to match (e.g. 'Cronet', 'Response', 'didReceive')."]
                ],
                "required": ["bundleID", "keyword"]
            ]
        ],
        [
            "name": "set_objc_hooks",
            "description": "Install ObjC boundary hooks: swizzle (className, selector) and log each call "
                + "+ its object args (NSData captured as a body). The ObjC-swizzle capture point for SDKs / the "
                + "@objc layer of statically-linked apps. Only void methods are hooked (callback shape), "
                + "and only objc_msgSend-dispatched calls are intercepted (runtime/cross-module/dynamic "
                + "invocations) - direct Swift calls and pure-Swift (non-@objc) methods aren't reachable. "
                + "Each hook = {className, selector, "
                + "args(0-3), classMethod(bool), category, api?}.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "hooks": ["type": "array", "items": ["type": "object"], "description": "Full hooks array (replaces existing)."]
                ],
                "required": ["bundleID", "hooks"]
            ]
        ],
        [
            "name": "set_swift_hooks",
            "description": "Install native-Swift vtable hooks: patch an overridable Swift "
                + "method's vtable slot to log each call and pass through. Reaches non-@objc Swift that "
                + "set_objc_hooks can't - but ONLY methods dispatched through the vtable "
                + "(polymorphic/overridable/cross-module). The -O optimizer devirtualizes concrete-type "
                + "calls into direct calls that bypass the vtable and aren't intercepted; pure static/struct "
                + "dispatch needs inline hooking. arm64 only; observe-only (void methods). Use find_symbols "
                + "to locate the runtime class name (_TtC… form) and the mangled method symbol. "
                + "Each hook = {className, method (substring matched against the slot's mangled symbol), "
                + "category, api?}.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "hooks": ["type": "array", "items": ["type": "object"], "description": "Full hooks array (replaces existing)."]
                ],
                "required": ["bundleID", "hooks"]
            ]
        ],
        [
            "name": "set_inline_hooks",
            "description": "Install inline (machine-code) hooks - patch a function's prologue to "
                + "intercept/modify/log it, reaching statically-linked / stripped / static-dispatch code "
                + "that ObjC, Swift-vtable, and interpose hooks can't. arm64 only; gated behind "
                + "set_config enableInlineHooks=true (live code patching). Locate the target (priority "
                + "order) by: address (absolute hex), symbol (dlsym; set followThunk for exported Swift), "
                + "module+offset (Ghidra static offset + ASLR slide), or module+signature (wildcard byte "
                + "pattern \"1F 20 ?? D5\"). Args x0-x3 and the return are captured; an interception rule "
                + "(set_rules, matched on the api label) can block / replace the return. Each hook = "
                + "{api, category, module?, symbol?, address?, offset?, signature?, followThunk?, "
                + "captureReturn?, renderArgs?, renderReturn?}. renderArgs maps arg registers to an ObjC "
                + "renderer, e.g. {\"x2\":\"nsstring\",\"x3\":\"nsdata\"}, so a register holding an NSData is "
                + "captured as a body (and NSString as a field) instead of a raw pointer "
                + "(nsdata|nsstring|objcDesc|cString; safe-deref, falls back to hex). renderReturn does the "
                + "same for the return value (implies captureReturn).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "hooks": ["type": "array", "items": ["type": "object"], "description": "Full hooks array (replaces existing)."]
                ],
                "required": ["bundleID", "hooks"]
            ]
        ],
        [
            "name": "list_jailbreak_detectors",
            "description": "List the jailbreak/root-detection SDKs Ophanim can bypass (id + label). Use "
                + "these ids with set_config's jailbreakBypasses, or pass \"all\" to enable every one.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
        ],
        [
            "name": "set_config",
            "description": "Modify an app's per-app settings. Any omitted field is left unchanged. "
                + "Changes persist to the per-app settings; capture categories, rules, sinks and pinning "
                + "apply live to a running app (config is watched), while newly added hooks and the "
                + "injection strategy take effect on next launch.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bundleID": ["type": "string", "description": "The app's bundle identifier."],
                    "enabled": ["type": "boolean", "description": "Turn the instrumentation engine on/off."],
                    "autoOpenLog": ["type": "boolean", "description": "Open the log window when the app launches."],
                    "captureBacktraces": ["type": "boolean", "description": "Record calling stacks for ObjC-level events (device/privacy/attestation/process)."],
                    "bypassPinning": ["type": "boolean", "description": "Force certificate-pinning checks to succeed (defeat pinning). Logged under the network category."],
                    "enableInlineHooks": ["type": "boolean", "description": "Master gate for inline (machine-code) hooks. Off by default; must be on before any set_inline_hooks target is patched (live code patching)."],
                    "categories": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Replace the active capture categories. Valid values: network, keychain, crypto, device, privacy, filesystem, process, jailbreak."
                    ],
                    "sinks": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Replace the output sinks. Valid values: ndjson, text, console."
                    ],
                    "jailbreakBypass": ["type": "boolean", "description": "Master switch for jailbreak/root-detection bypassing."],
                    "jailbreakBypasses": [
                        "description": "Which detector SDKs to bypass. Pass \"all\" or \"none\", or an array of detector ids (see list_jailbreak_detectors).",
                        "oneOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]
                    ],
                    "chainGuard": ["type": "boolean", "description": "Route keychain calls through ChainGuard (emulated keychain)."],
                    "chainGuardDebugging": ["type": "boolean", "description": "Log each ChainGuard keychain read/write."],
                    "alwaysOnTop": ["type": "boolean", "description": "Keep the app's window above other windows."],
                    "disableDisplaySleep": ["type": "boolean", "description": "Hold a no-display-sleep assertion while the app runs."],
                    "hideTitleBar": ["type": "boolean", "description": "Hide the app window's title bar."],
                    "rootWorkDir": ["type": "boolean", "description": "Start the app with its working directory at /."],
                    "limitMotionUpdateFrequency": ["type": "boolean", "description": "Throttle accelerometer/gyro callbacks."],
                    "blockSleepSpamming": ["type": "boolean", "description": "Suppress rapid-fire sleep calls."],
                    "checkMicPermissionSync": ["type": "boolean", "description": "Resolve the microphone-permission check synchronously."],
                    "keymapping": ["type": "boolean", "description": "Enable keyboard-to-touch key mapping."],
                    "iosDeviceModel": ["type": "string", "description": "iOS hardware model the app reports (e.g. iPad13,8)."]
                ],
                "required": ["bundleID"]
            ]
        ],
        [
            "name": "launch_app",
            "description": "Launch an installed app so it runs with its current instrumentation config.",
            "inputSchema": [
                "type": "object",
                "properties": ["bundleID": ["type": "string", "description": "The app's bundle identifier."]],
                "required": ["bundleID"]
            ]
        ]
    ]
}

// MARK: - stdio transport (headless `--mcp`)

enum MCPStdioTransport {
    /// Blocking newline-delimited JSON-RPC loop over stdin/stdout. Never returns.
    static func run() -> Never {
        // stdio mode is meant to be spawned by an MCP client that drives requests over the stdin
        // pipe. Launched interactively (a terminal, or double-clicking the app) stdin is a TTY with
        // no client, so the read loop would hit EOF instantly and exit "for no reason". Detect that
        // and explain how to run a standalone server instead of exiting silently.
        // Require BOTH stdin and stdout to be TTYs: that's a real interactive terminal. A client
        // always reads our stdout (a pipe), so this never trips a client - even one that hands us a
        // pty for stdin.
        if isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 {
            FileHandle.standardError.write(Data(
                ("ophanim: --mcp stdio mode expects an MCP client to drive it over stdin.\n" +
                 "         To run a standalone server, use:  Ophanim --mcp --http [--port N]\n").utf8))
            exit(0)
        }
        let out = FileHandle.standardOutput
        let newline = Data([0x0a])
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard let response = MCPServer.shared.handle(msg) else { continue }
            if let rdata = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes]) {
                out.write(rdata); out.write(newline)
            }
        }
        exit(0)
    }
}

// MARK: - HTTP transport (loopback :20033, Streamable HTTP over a POSIX socket)

final class MCPHTTPTransport {
    static let shared = MCPHTTPTransport()
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "be.ophanim.mcp.http", attributes: .concurrent)
    private(set) var isRunning = false
    private(set) var boundPort: UInt16 = kMCPPort
    private(set) var boundHost = "loopback"

    /// Start the HTTP server on the given port + bind address (defaults to the configured values).
    /// Idempotent; silently no-ops if already running or the address is unavailable.
    func start(port: UInt16? = nil, bind bindArg: String? = nil) {
        guard listenFD < 0 else { return }
        let port = port ?? mcpConfiguredPort
        let bindMode = bindArg ?? mcpConfiguredBind
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = mcpResolveBind(bindMode)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        listenFD = fd
        boundPort = port
        boundHost = bindMode
        isRunning = true
        queue.async { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        isRunning = false
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { if listenFD < 0 { return }; continue }
            queue.async { [weak self] in self?.handleClient(client) }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        guard let (method, headers, body) = readRequest(fd) else { return }
        let (status, payload): (String, Data)
        if isCrossOriginOrRebind(headers) {
            // A web page (or a DNS-rebound hostname) is driving us. Native MCP clients send no Origin
            // and a loopback Host. Refuse, so a malicious site can't reach this localhost server to
            // read captured data / change config / launch apps. See isCrossOriginOrRebind.
            (status, payload) = ("403 Forbidden", Data(#"{"error":"forbidden"}"#.utf8))
        } else if method != "POST" {
            (status, payload) = ("405 Method Not Allowed", Data("POST only".utf8))
        } else if let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let response = MCPServer.shared.handle(msg) {
                let data = (try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes])) ?? Data()
                (status, payload) = ("200 OK", data)
            } else {
                (status, payload) = ("202 Accepted", Data())   // notification, no reply
            }
        } else {
            (status, payload) = ("400 Bad Request",
                Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#.utf8))
        }
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        // No Access-Control-Allow-Origin: this is a local JSON-RPC endpoint for native MCP clients, not
        // a web API. Advertising CORS would let a browser page read responses; we don't want that.
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(payload)
        out.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    /// True if the request looks like it came from a web page or a DNS-rebound hostname rather than a
    /// native MCP client. Two signals: (1) any `Origin` header - browsers always set it on a cross-site
    /// fetch (and on non-GET same-origin), native clients never do; (2) for the default loopback bind, a
    /// `Host` that isn't a literal loopback address (defeats rebinding, where evil.com resolves to
    /// 127.0.0.1). When the user has explicitly bound to all/■specific interfaces they accepted LAN
    /// exposure, so the Host isn't second-guessed there (the Origin check still applies).
    private func isCrossOriginOrRebind(_ headers: [String: String]) -> Bool {
        if headers["origin"] != nil { return true }
        if boundHost == "loopback", let host = headers["host"]?.lowercased() {
            let name = host.split(separator: ":").first.map(String.init) ?? host
            if !["127.0.0.1", "localhost", "::1"].contains(name) { return true }
        }
        return false
    }

    /// Read one HTTP request: headers until CRLFCRLF, then Content-Length bytes of body. Header names
    /// are returned lowercased.
    private func readRequest(_ fd: Int32) -> (method: String, headers: [String: String], body: Data)? {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 14)
        let sep = Data("\r\n\r\n".utf8)
        var headerEnd: Int? = buf.range(of: sep)?.upperBound
        // Read until we have the full header block.
        while headerEnd == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buf.append(contentsOf: chunk[0..<n])
            headerEnd = buf.range(of: sep)?.upperBound
        }
        guard let bodyStart = headerEnd,
              let headerText = String(data: buf.prefix(bodyStart), encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        let method = lines.first?.components(separatedBy: " ").first ?? "GET"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { headers[k] = v }
        }
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        // Read the remaining body bytes.
        while buf.count - bodyStart < contentLength {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
        }
        return (method, headers, buf.suffix(from: bodyStart))
    }
}
