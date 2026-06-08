//
//  OPConfig.swift
//  OphanimCore
//
//  Per-app instrumentation configuration + interception rules. Written by the GUI into the
//  app's settings plist and read by the in-process agent at constructor time. Mirror this
//  struct field-for-field on the GUI side; decoding tolerates missing keys via defaults.
//

import Foundation

/// Where records are written. Combinable.
public struct OPSinkSelection: OptionSet, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let ndjson    = OPSinkSelection(rawValue: 1 << 0)
    public static let plainText = OPSinkSelection(rawValue: 1 << 1)
    public static let osLog     = OPSinkSelection(rawValue: 1 << 2)
    public static let all: OPSinkSelection = [.ndjson, .plainText, .osLog]
}

/// Predicate used to match a call against a rule. All present fields must match (AND).
public struct OPMatcher: Codable, Sendable {
    public var categories: [OPCategory]?       // any-of
    public var apiGlob: String?                // glob on the api name, e.g. "SecItem*"
    public var hostGlob: String?               // network: host glob, e.g. "*.analytics.com"
    public var urlGlob: String?                // network: full-URL glob
    public var pathGlob: String?               // filesystem: path glob, e.g. "*/Library/jb*"
    public var argContains: String?            // substring present in any stringified arg

    public init() {}
}

/// Action a matched rule performs. `script`, when present, is evaluated via JavaScriptCore and
/// takes precedence over the static fields below it.
public struct OPAction: Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case observe, modifyArgs, replaceReturn, block, delay, fault, script
    }
    public var kind: Kind
    public var script: String?                 // JS source for `.script`
    // static payloads:
    public var replacementBodyBase64: String?  // network/file: replacement bytes
    public var replacementHeaders: [String: String]?
    public var replacementStatus: Int?         // network: HTTP status
    public var cannedReturnValue: String?      // device/keychain: stringified return
    public var delayMilliseconds: Int?
    public var faultErrorCode: Int?

    public init(kind: Kind) { self.kind = kind }
}

/// A single interception rule.
public struct OPRule: Codable, Sendable, Identifiable {
    public var id: String
    public var enabled: Bool
    public var note: String?
    public var match: OPMatcher
    public var action: OPAction

    public init(id: String, enabled: Bool = true, note: String? = nil,
                match: OPMatcher, action: OPAction) {
        self.id = id; self.enabled = enabled; self.note = note
        self.match = match; self.action = action
    }
}

/// A user-specified ObjC boundary hook: swizzle (className, selector) and log the call + its object
/// args. Lets analysts capture any @objc boundary (e.g. an SDK's response handler) without code
/// changes. Pure-Swift (non-@objc) methods aren't reachable this way - those need inline hooking.
public struct OPObjCHook: Codable, Sendable {
    public var className: String
    public var selector: String
    public var args: Int            // number of object args (0–3) to forward + log
    public var classMethod: Bool    // true = swizzle the class (+) method, false = instance (-)
    public var category: OPCategory // which capture category to log under
    public var api: String?         // display label (defaults to "className.selector")

    public init(className: String, selector: String, args: Int = 1, classMethod: Bool = false,
                category: OPCategory = .process, api: String? = nil) {
        self.className = className; self.selector = selector; self.args = args
        self.classMethod = classMethod; self.category = category; self.api = api
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        className = try c.decode(String.self, forKey: .className)
        selector = try c.decode(String.self, forKey: .selector)
        args = try c.decodeIfPresent(Int.self, forKey: .args) ?? 1
        classMethod = try c.decodeIfPresent(Bool.self, forKey: .classMethod) ?? false
        category = try c.decodeIfPresent(OPCategory.self, forKey: .category) ?? .process
        api = try c.decodeIfPresent(String.self, forKey: .api)
    }
}

/// A native-Swift vtable hook (Tier 2.5): patch an overridable Swift method's vtable slot to log the
/// call (and pass through). Reaches non-@objc Swift that ObjC swizzling can't - but only methods
/// dispatched through the vtable (polymorphic/cross-module; -O may devirtualize concrete calls).
public struct OPSwiftHook: Codable, Sendable {
    public var className: String    // ObjC-runtime class name (the _TtC… form find_symbols reports)
    public var method: String       // substring matched against the slot's (mangled) symbol
    public var category: OPCategory
    public var api: String?

    public init(className: String, method: String, category: OPCategory = .process, api: String? = nil) {
        self.className = className; self.method = method; self.category = category; self.api = api
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        className = try c.decode(String.self, forKey: .className)
        method = try c.decode(String.self, forKey: .method)
        category = try c.decodeIfPresent(OPCategory.self, forKey: .category) ?? .process
        api = try c.decodeIfPresent(String.self, forKey: .api)
    }
}

/// How an inline hook should render a selected argument/return register: deref it as an ObjC object
/// (NSData → captured as a body; NSString → a field; any object → its description) or as a C string.
/// Validated before any deref so a non-object register value falls back to raw hex (never crashes).
public enum OPArgRender: String, Codable, Sendable, CaseIterable {
    case nsdata      // [NSData] → ctx.requestBody/responseBody (+ "argN":"<N bytes>")
    case nsstring    // [NSString] → fields["argN"] = value
    case objcDesc    // any object → fields["argN"] = description (capped)
    case cString     // char* → fields["argN"] = UTF8 string (bounded)
}

/// A Tier-3 inline (machine-code) hook: patch a function's prologue so calls divert through the
/// engine (intercept / modify args+return / log). The target is located, in priority order, by:
/// `address` (absolute hex), `symbol` (dlsym; `followThunk` chases a leading B), `module`+`offset`
/// (Ghidra static offset + ASLR slide), or `module`+`signature` (wildcard byte pattern "AA BB ?? D1").
/// arm64 only; gated behind OPConfig.enableInlineHooks (live code patching).
public struct OPInlineHook: Codable, Sendable {
    public var api: String              // display label for captured events
    public var category: OPCategory
    public var module: String?          // substring of the image's dyld path (default: main executable)
    public var symbol: String?
    public var address: String?         // absolute runtime address, hex ("0x…")
    public var offset: String?          // static offset within `module` (hex or decimal)
    public var signature: String?       // byte pattern, e.g. "1F 20 03 D5 ?? ?? ?? 94"
    public var followThunk: Bool        // follow a leading unconditional B to the real body
    public var captureReturn: Bool      // also run the original and log/modify its return value
    public var renderArgs: [String: OPArgRender]?   // {"x2":"nsstring","x3":"nsdata"} - deref arg regs
    public var renderReturn: OPArgRender?            // render the return value (captureReturn/leave path)

    public init(api: String, category: OPCategory = .process, module: String? = nil,
                symbol: String? = nil, address: String? = nil, offset: String? = nil,
                signature: String? = nil, followThunk: Bool = false, captureReturn: Bool = false,
                renderArgs: [String: OPArgRender]? = nil, renderReturn: OPArgRender? = nil) {
        self.api = api; self.category = category; self.module = module; self.symbol = symbol
        self.address = address; self.offset = offset; self.signature = signature
        self.followThunk = followThunk; self.captureReturn = captureReturn
        self.renderArgs = renderArgs; self.renderReturn = renderReturn
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        api = try c.decode(String.self, forKey: .api)
        category = try c.decodeIfPresent(OPCategory.self, forKey: .category) ?? .process
        module = try c.decodeIfPresent(String.self, forKey: .module)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        offset = try c.decodeIfPresent(String.self, forKey: .offset)
        signature = try c.decodeIfPresent(String.self, forKey: .signature)
        followThunk = try c.decodeIfPresent(Bool.self, forKey: .followThunk) ?? false
        captureReturn = try c.decodeIfPresent(Bool.self, forKey: .captureReturn) ?? false
        renderArgs = try c.decodeIfPresent([String: OPArgRender].self, forKey: .renderArgs)
        renderReturn = try c.decodeIfPresent(OPArgRender.self, forKey: .renderReturn)
        // captureReturn is implied when a return renderer is requested
        if renderReturn != nil { captureReturn = true }
    }
}

/// How the engine gets into the hosted process. Embedded ships inside Galgal (always present,
/// dormant until enabled). Sibling injects a standalone agent dylib via a 2nd LC_LOAD_DYLIB.
public enum OPInjectionStrategy: String, Codable, Sendable, CaseIterable {
    case embedded
    case sibling
}

/// Top-level per-app config. Observe-by-default: with no rules, every hook only logs.
public struct OPConfig: Codable, Sendable {
    public var enabled: Bool
    public var injectionStrategy: OPInjectionStrategy   // install-time concern; default embedded
    public var categories: [OPCategory]                 // which capture modules are active
    public var sinks: OPSinkSelection
    public var logToSharedDir: Bool                     // ~/Library/Logs/Ophanim vs app container
    public var bodyCapBytes: Int                        // max captured payload size
    public var captureBacktraces: Bool
    public var redactionKeys: [String]                  // header/field keys whose values are masked ([] = nothing redacted)
    public var rules: [OPRule]
    public var autoOpenLog: Bool                         // GUI: open the log window when the app launches
    public var bypassPinning: Bool                       // force-accept SecTrust (defeat cert pinning)
    public var objcHooks: [OPObjCHook]                   // user-specified ObjC boundary hooks
    public var swiftHooks: [OPSwiftHook]                 // user-specified native-Swift vtable hooks
    public var inlineHooks: [OPInlineHook]               // Tier-3 inline (machine-code) hooks
    public var enableInlineHooks: Bool                   // explicit gate for live code patching

    public init(enabled: Bool = false,
                injectionStrategy: OPInjectionStrategy = .embedded,
                categories: [OPCategory] = OPCategory.allCases,
                sinks: OPSinkSelection = [.ndjson],
                logToSharedDir: Bool = false,
                bodyCapBytes: Int = 64 * 1024,
                captureBacktraces: Bool = false,
                redactionKeys: [String] = [],   // nothing redacted by default - this is an analysis tool
                rules: [OPRule] = [],
                autoOpenLog: Bool = false,
                bypassPinning: Bool = false,
                objcHooks: [OPObjCHook] = [],
                swiftHooks: [OPSwiftHook] = [],
                inlineHooks: [OPInlineHook] = [],
                enableInlineHooks: Bool = false) {
        self.enabled = enabled
        self.injectionStrategy = injectionStrategy
        self.categories = categories
        self.sinks = sinks
        self.logToSharedDir = logToSharedDir
        self.bodyCapBytes = bodyCapBytes
        self.captureBacktraces = captureBacktraces
        self.redactionKeys = redactionKeys
        self.rules = rules
        self.autoOpenLog = autoOpenLog
        self.bypassPinning = bypassPinning
        self.objcHooks = objcHooks
        self.swiftHooks = swiftHooks
        self.inlineHooks = inlineHooks
        self.enableInlineHooks = enableInlineHooks
    }

    // Lenient decoding so adding fields later never invalidates an existing settings plist.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OPConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        injectionStrategy = try c.decodeIfPresent(OPInjectionStrategy.self, forKey: .injectionStrategy) ?? d.injectionStrategy
        categories = try c.decodeIfPresent([OPCategory].self, forKey: .categories) ?? d.categories
        sinks = try c.decodeIfPresent(OPSinkSelection.self, forKey: .sinks) ?? d.sinks
        logToSharedDir = try c.decodeIfPresent(Bool.self, forKey: .logToSharedDir) ?? d.logToSharedDir
        bodyCapBytes = try c.decodeIfPresent(Int.self, forKey: .bodyCapBytes) ?? d.bodyCapBytes
        captureBacktraces = try c.decodeIfPresent(Bool.self, forKey: .captureBacktraces) ?? d.captureBacktraces
        redactionKeys = try c.decodeIfPresent([String].self, forKey: .redactionKeys) ?? d.redactionKeys
        rules = try c.decodeIfPresent([OPRule].self, forKey: .rules) ?? d.rules
        autoOpenLog = try c.decodeIfPresent(Bool.self, forKey: .autoOpenLog) ?? d.autoOpenLog
        bypassPinning = try c.decodeIfPresent(Bool.self, forKey: .bypassPinning) ?? d.bypassPinning
        objcHooks = try c.decodeIfPresent([OPObjCHook].self, forKey: .objcHooks) ?? d.objcHooks
        swiftHooks = try c.decodeIfPresent([OPSwiftHook].self, forKey: .swiftHooks) ?? d.swiftHooks
        inlineHooks = try c.decodeIfPresent([OPInlineHook].self, forKey: .inlineHooks) ?? d.inlineHooks
        enableInlineHooks = try c.decodeIfPresent(Bool.self, forKey: .enableInlineHooks) ?? d.enableInlineHooks
    }

    public func isActive(_ category: OPCategory) -> Bool {
        enabled && categories.contains(category)
    }
}

/// Resolves and loads the per-app OPConfig. The agent re-derives the plist path purely from the
/// process identity, so it works in both the embedded-runtime and sibling-dylib injection modes.
public enum OPConfigLoader {
    /// Container "App Settings" plist the GUI writes, keyed by the *host* app's bundle id.
    public static func defaultURL(hostBundleID: String = Bundle.main.bundleIdentifier ?? "") -> URL {
        // homeDirectoryForCurrentUser is unavailable on iOS/Catalyst; derive the real user home
        // the same way the runtime reads its settings plist.
        return OPPaths.userHome
            .appendingPathComponent("Library/Containers/be.ophanim.Ophanim/App Settings")
            .appendingPathComponent(hostBundleID)
            .appendingPathExtension("plist")
    }

    public static func load(from url: URL = OPConfigLoader.defaultURL()) -> OPConfig {
        guard let data = try? Data(contentsOf: url) else { return OPConfig() }
        // The settings plist embeds the Ophanim config under a known key; decode leniently.
        if let cfg = try? PropertyListDecoder().decode(OPConfigEnvelope.self, from: data) {
            return cfg.ophanim ?? OPConfig()
        }
        return OPConfig()
    }
}

/// The GUI's settings model conforms to this shape (only the field we care about is decoded).
public struct OPConfigEnvelope: Codable, Sendable {
    public var ophanim: OPConfig?
}

/// Path helpers that work identically on macOS (GUI) and iOS/Mac Catalyst (in-process agent).
public enum OPPaths {
    /// The real user home. `FileManager.homeDirectoryForCurrentUser` is unavailable on iOS, and a
    /// sandboxed Catalyst app's `NSHomeDirectory()` points at its container - so derive it from the
    /// login name, matching how the runtime locates its settings plist.
    public static var userHome: URL {
        URL(fileURLWithPath: "/Users/\(NSUserName())")
    }
}
