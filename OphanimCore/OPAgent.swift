//
//  OPAgent.swift
//  OphanimCore
//
//  The in-process singleton both injection modes start: the embedded entrypoint (called from
//  the Galgal loader's constructor) and the sibling-dylib entrypoint (its own __attribute__
//  ((constructor))). It loads config, stands up sinks + the interceptor, and offers the single
//  facade every hook module uses: `observe(...)` for pure logging and `intercept(_:)` to get a
//  decision the hook then applies before/after calling the original implementation.
//

import Foundation

public final class OPAgent: @unchecked Sendable {
    public static let shared = OPAgent()

    public private(set) var config: OPConfig = OPConfig()
    private var sinks: OPSinkMultiplexer?
    private var interceptor: OPInterceptor?
    private var started = false
    private let lock = NSLock()
    private let configURL = OPConfigLoader.defaultURL()
    private let watchQueue = DispatchQueue(label: "be.ophanim.configwatch", qos: .utility)
    private var lastConfigMTime: TimeInterval = 0

    private init() {}

    /// Idempotent. Safe to call from a dylib constructor. Starts a self-contained config poller so
    /// edits from the GUI/MCP apply live (no app restart); returns whether instrumentation is
    /// currently enabled.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        guard !started else { lock.unlock(); return config.enabled }
        started = true
        applyConfigLocked(boot: true)
        let enabled = config.enabled
        lock.unlock()
        startConfigPolling()
        return enabled
    }

    /// (Re)load config and rebuild sinks/interceptor. Caller holds `lock`.
    private func applyConfigLocked(boot: Bool) {
        config = OPConfigLoader.load(from: configURL)
        // Push the active-category bitmask to the C ring so its interpose producers (fs/process/…)
        // skip inactive categories without touching the ring. 0 when disabled.
        var mask: UInt32 = 0
        for (i, c) in OPCategory.allCases.enumerated() where config.isActive(c) {
            mask |= (1 << UInt32(i))
        }
        op_ring_set_categories(mask)
        // Certificate-pinning bypass (force-accept). Pinning checks are *logged* via the network
        // capture category (gated in the ring), so logging needs no separate flag here.
        op_set_bypass_pinning(config.enabled && config.bypassPinning)
        guard config.enabled else { sinks = nil; interceptor = nil; return }
        let dir = OPAgent.resolveLogDirectory(config)
        sinks = OPSinkMultiplexer.make(config: config, logDirectory: dir)
        interceptor = OPInterceptor(rules: config.rules)
        observe(OPEvent(category: .process, layer: .interpose, api: "ophanim.\(boot ? "start" : "reload")",
                        summary: "agent \(boot ? "attached" : "reloaded") (\(activeSummary()))",
                        fields: ["pid": String(ProcessInfo.processInfo.processIdentifier),
                                 "logDir": dir.path]))
    }

    /// Live reload triggered by the config-file watcher. Rebuilds state and, if instrumentation was
    /// just enabled, installs the swizzle-based hooks (idempotent) so no app restart is needed.
    public func reload() {
        lock.lock()
        applyConfigLocked(boot: false)
        let enabled = config.enabled
        lock.unlock()
        guard enabled else { return }
        // Hook installation swizzles ObjC methods / patches vtables + code; do it on the main thread
        // (matching boot, where startEmbedded dispatches to main) rather than the config-poll's utility
        // queue. installHooks() runs the one-time base setup if the app launched disabled; installUserHooks()
        // then picks up any objc/swift/inline hooks added since launch (both idempotent).
        DispatchQueue.main.async {
            OPBootstrapCore.installHooks()
            OPBootstrapCore.installUserHooks()
        }
    }

    /// True when a category's hooks should install at all (cheap gate for hook registration).
    public func isActive(_ category: OPCategory) -> Bool { config.isActive(category) }

    public var bodyCap: Int { config.bodyCapBytes }

    /// Pure logging - no interception.
    public func observe(_ event: OPEvent) {
        sinks?.emit(event)
    }

    /// Consult the rules for a call. Hook modules call this, apply the returned decision (block,
    /// rewrite args/return, delay, fault), then emit the resulting event via `observe`.
    public func intercept(_ ctx: OPCallContext) -> OPDecision {
        interceptor?.decide(ctx) ?? .observe
    }

    /// Convenience: build an event from a context + the disposition that was applied.
    public func event(from ctx: OPCallContext, decision: OPDecision, summary: String = "",
                      extraFields: [String: String] = [:]) -> OPEvent {
        var fields = ctx.fields
        if let h = ctx.host { fields["host"] = h }
        if let u = ctx.url { fields["url"] = u }
        if let p = ctx.path { fields["path"] = p }
        for (k, v) in extraFields { fields[k] = v }
        // Backtraces are only meaningful for ObjC-swizzle events: those hooks run synchronously on
        // the app's calling thread, so the call stack here is the real caller. Ring-based events
        // (interpose/socket/tls) are drained on the consumer thread, where the stack would be wrong.
        var backtrace: [String]?
        if config.captureBacktraces, ctx.layer == .objc {
            backtrace = Array(Thread.callStackSymbols.dropFirst(2).prefix(32))
        }
        return OPEvent(category: ctx.category, layer: ctx.layer, api: ctx.api,
                       summary: summary, fields: fields,
                       requestBody: ctx.requestBody.map { capped($0) },
                       responseBody: ctx.responseBody.map { capped($0) },
                       disposition: decision.disposition,
                       matchedRuleID: decision.matchedRuleID,
                       backtrace: backtrace)
    }

    public func flush() { sinks?.flush() }

    // MARK: - Live config watch

    /// Interval between config-plist mtime checks. 1s gives near-immediate apply with negligible
    /// cost (one `stat()` per second on a utility thread).
    private static let configPollInterval: TimeInterval = 1.0

    /// Self-contained live reload: poll the per-app config plist's modification time on a utility
    /// queue and `reload()` when it changes. This replaces a `DispatchSource` file watch, which raced
    /// dyld image initialization and crashed the hosted process at startup (the watcher was set up
    /// from a dylib constructor). A deferred `stat()` loop on a normal thread has no such hazard:
    /// nothing runs during image init, and `stat()` touches no ObjC/dispatch state. Handles atomic
    /// writes transparently - PropertyListEncoder's write-to-temp + rename changes the path's mtime,
    /// which is all we compare.
    private func startConfigPolling() {
        // Seed the baseline from the file we just loaded so only a *later* edit triggers a reload
        // (a synchronous stat() here is safe even from a constructor - no allocation, no runtime).
        lastConfigMTime = Self.configMTime(configURL)
        scheduleConfigPoll()
    }

    private func scheduleConfigPoll() {
        watchQueue.asyncAfter(deadline: .now() + Self.configPollInterval) { [weak self] in
            guard let self = self else { return }
            let m = Self.configMTime(self.configURL)
            if m > 0, m != self.lastConfigMTime {
                self.lastConfigMTime = m
                self.reload()
            }
            self.scheduleConfigPoll()
        }
    }

    /// The config plist's mtime as epoch seconds (nanosecond precision), or 0 if it can't be stat'd.
    private static func configMTime(_ url: URL) -> TimeInterval {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return 0 }
        return TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    // MARK: - Helpers

    private func capped(_ data: Data) -> Data {
        data.count > config.bodyCapBytes ? data.prefix(config.bodyCapBytes) : data
    }

    private func activeSummary() -> String {
        config.categories.map { $0.rawValue }.joined(separator: ",")
    }

    /// Always the app's own sandbox container - the only location a sandboxed hosted app can
    /// reliably write to. (~/Library/Logs/Ophanim is blocked by the sandbox without an sbpl
    /// exception, so the shared-dir option was removed.) The GUI log viewer reads this path.
    static func resolveLogDirectory(_ config: OPConfig) -> URL {
        let docs = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("Ophanim")
    }
}
