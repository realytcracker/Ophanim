//
//  MCPData.swift
//  Ophanim
//
//  File-backed data access for the MCP server - deliberately GUI-independent so it works both in
//  the headless `--mcp` stdio process and in the running app's HTTP transport. Reads the same
//  per-app settings plists and NDJSON capture logs the rest of Ophanim uses, and can mutate the
//  instrumentation config by rewriting the settings plist (the agent reads it at app launch).
//

import Foundation

enum MCPData {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var container: URL {
        home.appendingPathComponent("Library/Containers/be.ophanim.Ophanim")
    }
    private static var appsDir: URL { container.appendingPathComponent("Applications") }
    private static var settingsDir: URL { container.appendingPathComponent("App Settings") }

    private static func settingsURL(_ bundleID: String) -> URL {
        settingsDir.appendingPathComponent(bundleID).appendingPathExtension("plist")
    }
    private static func logDir(_ bundleID: String) -> URL {
        home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Documents/Ophanim")
    }

    // MARK: - Apps

    struct AppEntry { let bundleID: String; let name: String; let version: String }

    /// The app's dynamically-imported TLS/crypto/sensitive symbols - the surface that DYLD_INTERPOSE
    /// can rebind (key for statically-linked apps: even a self-contained binary imports the OS's
    /// crypto/TLS primitives, and those calls ARE interposable). Grouped by what Ophanim can hook.
    static func importSurface(_ bundleID: String) -> [String: [String]] {
        guard let app = appURL(bundleID) else { return [:] }
        let info = (try? Data(contentsOf: app.appendingPathComponent("Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let exeName = (info["CFBundleExecutable"] as? String) ?? app.deletingPathExtension().lastPathComponent
        let exe = app.appendingPathComponent(exeName)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        p.arguments = ["-u", exe.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let syms = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        func match(_ needles: [String]) -> [String] {
            syms.filter { s in needles.contains { s.contains($0) } }.sorted()
        }
        return [
            "tls": match(["SSLRead", "SSLWrite", "SSLHandshake", "SSLCreateContext", "SSLCopyPeerTrust",
                          "SSLSetSessionOption", "SSL_read", "SSL_write", "sec_protocol"]),
            "trust_pinning": match(["SecTrustEvaluate", "SecTrustCreate", "SecPolicyCreateSSL",
                                    "SecKeyRawVerify", "SecKeyVerifySignature"]),
            "crypto": match(["CCCrypt", "CCHmac", "CC_SHA", "SecKeyCreate", "SecKeyDecrypt", "SecKeyEncrypt"]),
            "keychain": match(["SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "SecItemDelete"]),
            "process": match(["_dlopen", "posix_spawn", "_execve", "ptrace", "_fork"])
        ]
    }

    /// Path to the app's main executable, if installed.
    static func appExecutable(_ bundleID: String) -> URL? {
        guard let app = appURL(bundleID) else { return nil }
        let info = (try? Data(contentsOf: app.appendingPathComponent("Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let name = (info["CFBundleExecutable"] as? String) ?? app.deletingPathExtension().lastPathComponent
        return app.appendingPathComponent(name)
    }

    /// Search the app binary for symbols / ObjC class & selector names matching a keyword - recon for
    /// finding hook targets (e.g. an SDK's response classes/selectors). Returns demangled symbols +
    /// ObjC-name strings, capped.
    static func findSymbols(_ bundleID: String, _ keyword: String) -> [String: [String]] {
        guard let exe = appExecutable(bundleID), !keyword.isEmpty else { return [:] }
        let safe = keyword.replacingOccurrences(of: "'", with: "")
        func sh(_ cmd: String) -> [String] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return [] }
            let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return (String(data: d, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        }
        let q = "'\(safe)'"
        // Demangled symbols (incl. Swift types/methods) + ObjC class/selector strings.
        let syms = sh("nm '\(exe.path)' 2>/dev/null | xcrun swift-demangle 2>/dev/null | grep -i \(q) | sort -u | head -80")
        let classes = sh("strings -a '\(exe.path)' 2>/dev/null | grep -E '^_TtC' | xcrun swift-demangle 2>/dev/null | grep -i \(q) | sort -u | head -60")
        let selectors = sh("strings -a '\(exe.path)' 2>/dev/null | grep -iE '^[a-zA-Z][a-zA-Z0-9_]*:?$' | grep -i \(q) | sort -u | head -80")
        return ["symbols": syms, "swiftClasses": classes, "selectors": selectors]
    }

    /// Filesystem URL of an installed hosted app bundle, if present.
    static func appURL(_ bundleID: String) -> URL? {
        let url = appsDir.appendingPathComponent(bundleID).appendingPathExtension("app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func listApps() -> [AppEntry] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: appsDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [AppEntry] = []
        for app in dirs where app.pathExtension == "app" {
            let info = app.appendingPathComponent("Info.plist")
            let plist = (try? Data(contentsOf: info)).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
            } ?? [:]
            let bid = (plist["CFBundleIdentifier"] as? String)
                ?? app.deletingPathExtension().lastPathComponent
            let name = (plist["CFBundleName"] as? String)
                ?? (plist["CFBundleDisplayName"] as? String) ?? bid
            let version = (plist["CFBundleShortVersionString"] as? String) ?? "?"
            out.append(AppEntry(bundleID: bid, name: name, version: version))
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Config

    /// Decode the per-app AppSettingsData from its plist (the encoded settings model).
    static func appSettings(_ bundleID: String) -> AppSettingsData? {
        guard let data = try? Data(contentsOf: settingsURL(bundleID)) else { return nil }
        return try? PropertyListDecoder().decode(AppSettingsData.self, from: data)
    }

    static func config(_ bundleID: String) -> OPConfig? { appSettings(bundleID)?.ophanim }

    /// Mutate the full per-app settings and persist them. A running app picks the change up live via
    /// the agent's config-file poll (categories/rules/sinks/pinning); newly added hooks and the
    /// injection strategy apply on next launch.
    static func updateSettings(_ bundleID: String, _ mutate: (inout AppSettingsData) -> Void) throws {
        var settings = appSettings(bundleID) ?? AppSettingsData()
        if settings.bundleIdentifier.isEmpty { settings.bundleIdentifier = bundleID }
        mutate(&settings)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: settingsURL(bundleID))
    }

    /// Mutate just the instrumentation (OphanimCore) sub-config and persist.
    static func updateConfig(_ bundleID: String, _ mutate: (inout OPConfig) -> Void) throws {
        try updateSettings(bundleID) { mutate(&$0.ophanim) }
    }

    // MARK: - Events

    /// Load captured events for an app, newest last, optionally filtered, capped to `limit`.
    static func events(_ bundleID: String, category: String?, search: String?, limit: Int) -> [OPEvent] {
        let dir = logDir(bundleID)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var all: [OPEvent] = []
        for f in files where f.pathExtension == "ndjson" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let e = try? decoder.decode(OPEvent.self, from: d) else { continue }
                if let category, e.category.rawValue != category { continue }
                if let search, !search.isEmpty,
                   !(e.api.localizedCaseInsensitiveContains(search)
                     || e.summary.localizedCaseInsensitiveContains(search)
                     || e.fields.contains { $0.value.localizedCaseInsensitiveContains(search) }) {
                    continue
                }
                all.append(e)
            }
        }
        all.sort { $0.timestamp < $1.timestamp }
        return limit > 0 && all.count > limit ? Array(all.suffix(limit)) : all
    }

    // MARK: - Behavior / privacy report

    private static let jbMarkers = ["/bin/bash", "/bin/sh", "/usr/sbin/sshd", "/etc/apt", "/private/var/lib/apt",
        "/Applications/Cydia", "Cydia", "MobileSubstrate", "/usr/bin/ssh", "frida", "cycript",
        "/private/var/stash", "/usr/libexec/sftp-server", "jailbreak", "/var/jb"]

    /// Known tracker / analytics / ad / attribution / crash-reporting SDK host substrings.
    static let trackerCatalog: [String: String] = [
        "google-analytics.com": "Google Analytics (analytics)",
        "googletagmanager.com": "Google Tag Manager (analytics)",
        "app-measurement.com": "Firebase Analytics (analytics)",
        "firebase": "Firebase (analytics)", "crashlytics.com": "Crashlytics (crash)",
        "doubleclick.net": "Google Ads / DoubleClick (ads)", "googlesyndication.com": "Google AdSense (ads)",
        "googleadservices.com": "Google Ads (ads)", "admob": "Google AdMob (ads)",
        "graph.facebook.com": "Facebook SDK (analytics/ads)", "facebook.com/v": "Facebook Graph (analytics)",
        "appsflyer.com": "AppsFlyer (attribution)", "adjust.com": "Adjust (attribution)", "adj.st": "Adjust (attribution)",
        "branch.io": "Branch (attribution)", "singular.net": "Singular (attribution)", "kochava.com": "Kochava (attribution)",
        "amplitude.com": "Amplitude (analytics)", "mixpanel.com": "Mixpanel (analytics)",
        "segment.com": "Segment (analytics)", "segment.io": "Segment (analytics)",
        "sentry.io": "Sentry (crash)", "bugsnag.com": "Bugsnag (crash)", "nr-data.net": "New Relic (analytics)",
        "flurry.com": "Flurry (analytics)", "onesignal.com": "OneSignal (push/analytics)",
        "braze.com": "Braze (engagement)", "appboy.com": "Braze/Appboy (engagement)", "iterable.com": "Iterable (engagement)",
        "applovin.com": "AppLovin (ads)", "chartboost.com": "Chartboost (ads)", "vungle.com": "Vungle (ads)",
        "adcolony.com": "AdColony (ads)", "inmobi.com": "InMobi (ads)", "tapjoy.com": "Tapjoy (ads)",
        "mopub.com": "MoPub (ads)", "unity3d.com": "Unity Ads (ads)", "unityads": "Unity Ads (ads)",
        "scorecardresearch.com": "comScore (analytics)", "demdex.net": "Adobe Audience (analytics)",
        "omtrdc.net": "Adobe Analytics (analytics)", "moengage.com": "MoEngage (engagement)"
    ]

    /// Summarize a run into a behavior/privacy picture: who it talked to, what it accessed, etc.
    static func report(_ bundleID: String) -> [String: Any] {
        let events = self.events(bundleID, category: nil, search: nil, limit: 0)
        var byCat: [String: Int] = [:]
        var hosts: [String: Int] = [:]
        var statuses: [String: Int] = [:]
        var identifiers = Set<String>()
        var privacy = Set<String>()
        var kcAccounts = Set<String>(); var kcOps: [String: Int] = [:]
        var cryptoOps = 0
        var jbProbes = Set<String>(); var jbBypassed = Set<String>()
        var pinChecks = 0; var pinBypassed = 0
        var launches = Set<String>(); var dlopens = Set<String>(); var spawns = Set<String>()
        var tlsPlaintext = false

        for e in events {
            byCat[e.category.rawValue, default: 0] += 1
            let f = e.fields
            switch e.category {
            case .network:
                if let h = f["host"], !h.isEmpty { hosts[h, default: 0] += 1 }
                else if let ip = f["ip"], !ip.isEmpty { hosts[ip, default: 0] += 1 }
                else if let u = f["url"], let host = URL(string: u)?.host { hosts[host, default: 0] += 1 }
                if let s = f["status"], s != "0", !s.isEmpty { statuses[s, default: 0] += 1 }
                if e.api.hasPrefix("SecTrust") { pinChecks += 1; if f["bypassed"] == "yes" { pinBypassed += 1 } }
                if e.layer == .tls { tlsPlaintext = true }
            case .device:
                identifiers.insert(f["value"].map { "\(e.api) = \($0)" } ?? e.api)
            case .privacy:
                privacy.insert(e.api)
            case .keychain:
                if let a = f["account"], !a.isEmpty { kcAccounts.insert(a) }
                kcOps[e.api, default: 0] += 1
            case .crypto:
                cryptoOps += 1
            case .filesystem:
                if let p = f["path"], jbMarkers.contains(where: { p.localizedCaseInsensitiveContains($0) }) {
                    jbProbes.insert(p)
                }
            case .jailbreak:
                jbBypassed.insert(e.summary.isEmpty ? e.api : e.api)
            case .process:
                if e.api.contains("openURL") || e.api.contains("canOpenURL"), let u = f["url"] { launches.insert(u) }
                else if e.api == "dlopen", let p = f["path"] { dlopens.insert(p) }
                else if (e.api == "posix_spawn" || e.api == "execve"), let p = f["path"] { spawns.insert(p) }
            }
        }

        func topHosts() -> [[String: Any]] {
            hosts.sorted { $0.value > $1.value }.prefix(40).map { ["host": $0.key, "connections": $0.value] }
        }
        var trackers: [[String: String]] = []
        for h in hosts.keys.sorted() {
            for (sub, sdk) in trackerCatalog where h.localizedCaseInsensitiveContains(sub) {
                trackers.append(["host": h, "sdk": sdk]); break
            }
        }
        return [
            "bundleID": bundleID,
            "eventsAnalyzed": events.count,
            "summaryByCategory": byCat,
            "network": [
                "distinctHosts": hosts.count,
                "hosts": topHosts(),
                "httpStatuses": statuses,
                "tlsPlaintextCaptured": tlsPlaintext,
                "trackersDetected": trackers
            ] as [String: Any],
            "identifiersAccessed": Array(identifiers).sorted(),
            "privacyAPIs": Array(privacy).sorted(),
            "keychain": ["accountsOrServices": Array(kcAccounts).sorted(), "operations": kcOps] as [String: Any],
            "cryptoOperations": cryptoOps,
            "jailbreak": ["pathProbes": Array(jbProbes).sorted(), "detectorsBypassed": Array(jbBypassed).sorted()] as [String: Any],
            "certificatePinning": ["checks": pinChecks, "forceAccepted": pinBypassed],
            "process": [
                "appsOrURLsLaunched": Array(launches).sorted(),
                "librariesLoaded": Array(dlopens).sorted(),
                "processesSpawned": Array(spawns).sorted()
            ] as [String: Any]
        ]
    }
}
