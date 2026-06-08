//
//  LogViewerView.swift
//  Ophanim
//
//  Reads the NDJSON event logs OphanimCore writes for a hosted app (from its sandbox container
//  and/or the shared ~/Library/Logs/Ophanim dir), decodes them into OPEvent, and shows a
//  filterable table. Read-only viewer; refresh re-scans from disk.
//

import SwiftUI
import AppKit
import Combine

/// Opens the log viewer as a standalone, resizable, non-modal NSWindow (instead of a fixed-size
/// sheet). One window per host app bundle id - re-opening brings the existing one to the front.
/// macOS 12 can't use SwiftUI's openWindow/WindowGroup(for:), so we host the SwiftUI view in an
/// AppKit window directly.
final class LogWindowManager: NSObject, NSWindowDelegate {
    static let shared = LogWindowManager()
    private var windows: [String: NSWindow] = [:]

    func show(bundleID: String) {
        if let existing = windows[bundleID] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: LogViewerView(bundleID: bundleID))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Hacking Log - \(bundleID)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1200, height: 640))
        window.contentMinSize = NSSize(width: 560, height: 320)
        window.isReleasedWhenClosed = false   // lifetime owned by `windows`
        window.delegate = self
        window.center()
        windows[bundleID] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closing }
    }
}

struct LogViewerView: View {
    let bundleID: String

    struct Row: Identifiable { let id: Int; let event: OPEvent; var count: Int = 1 }

    @State private var events: [OPEvent] = []
    @State private var search = ""
    @State private var categoryFilter: OPCategory?
    @State private var loadError: String?
    @State private var selection: Int?
    @State private var autoRefresh = true
    @State private var dedupe = true
    /// The event for the selected row, captured on selection change so the detail pane and footer
    /// keep showing it even when auto-refresh replaces the table's data underneath.
    @State private var detailEvent: OPEvent?
    /// Signature (path+size+mtime of each log file) from the last scan, so the 2s auto-refresh can
    /// skip the full read+parse when nothing on disk changed.
    @State private var lastScanSig = ""

    /// Re-scan the log files on a timer while auto-refresh is on (live tail).
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var selectedEvent: OPEvent? {
        guard let id = selection else { return nil }
        return filtered.first(where: { $0.id == id })?.event
    }

    private var filtered: [Row] {
        let matched = events.filter { e in
            (categoryFilter == nil || e.category == categoryFilter)
            && (search.isEmpty
                || e.api.localizedCaseInsensitiveContains(search)
                || e.summary.localizedCaseInsensitiveContains(search)
                || e.fields.contains { $0.value.localizedCaseInsensitiveContains(search) })
        }
        guard dedupe else {
            return matched.enumerated().map { Row(id: $0.offset, event: $0.element) }
        }
        // Collapse runs of identical consecutive events into one row with a count (preserves order).
        var rows: [Row] = []
        for e in matched {
            if var last = rows.last, Self.signature(last.event) == Self.signature(e) {
                last.count += 1
                rows[rows.count - 1] = last
            } else {
                rows.append(Row(id: rows.count, event: e))
            }
        }
        return rows
    }

    private static func signature(_ e: OPEvent) -> String {
        "\(e.category.rawValue)|\(e.api)|\(e.fields["path"] ?? e.fields["host"] ?? e.fields["account"] ?? "")|\(e.disposition.rawValue)"
    }

    /// Highest ring-drop total reported in the current events (0 if none).
    private var droppedTotal: Int {
        events.compactMap { $0.api == "ophanim.ring.dropped" ? Int($0.fields["dropped"] ?? "") : nil }.max() ?? 0
    }

    /// Hook-install events whose result is a failure (not a success or an already-installed marker).
    /// Covers all three configurable tiers (objcHook/swiftHook/inlineHook), de-duplicated, so an
    /// aborted hook (e.g. an arm64e or unrelocatable inline target) is visible at a glance instead of
    /// being buried in the event stream. Success markers: "ok"/"ok (...)", "already-installed",
    /// "already-hooked".
    private var hookFailures: [(name: String, result: String)] {
        var out: [(String, String)] = []
        var seen = Set<String>()
        for e in events where e.api.hasSuffix("Hook.install") {
            let r = e.fields["result"] ?? ""
            if r.isEmpty || r.hasPrefix("ok") || r == "already-installed" || r == "already-hooked" { continue }
            let name = e.fields["label"] ?? e.summary
            if seen.insert("\(name)|\(r)").inserted { out.append((name, r)) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Hacking Log").font(.headline)
                Spacer()
                Picker("", selection: $categoryFilter) {
                    Text("All").tag(OPCategory?.none)
                    ForEach(OPCategory.allCases, id: \.self) { c in
                        Text(c.rawValue.capitalized).tag(OPCategory?.some(c))
                    }
                }.frame(width: 150)
                TextField("Search", text: $search).frame(width: 180)
                Toggle("Auto", isOn: $autoRefresh)
                    .toggleStyle(.switch)
                    .help("Re-scan the log every 2s to tail new events live")
                Toggle("Dedupe", isOn: $dedupe)
                    .toggleStyle(.switch)
                    .help("Collapse runs of identical consecutive events into one row with a ×N count.")
                Button("Refresh") { load() }
                Button("Show in Finder") { revealInFinder() }
                Button("Clear") { clearLogs() }
            }

            if let err = loadError {
                Text(err).font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Table(filtered, selection: $selection) {
                TableColumn("Time") { r in Text(Self.timeFmt.string(from: r.event.timestamp)) }.width(70)
                TableColumn("Category") { r in Text(r.event.category.rawValue) }.width(80)
                TableColumn("Layer") { r in Text(r.event.layer.rawValue) }.width(70)
                TableColumn("API") { r in Text(r.event.api) }.width(180)
                TableColumn("Disposition") { r in
                    Text(r.event.disposition == .observed ? "" : r.event.disposition.rawValue)
                        .foregroundColor(.orange)
                }.width(90)
                TableColumn("×") { r in
                    Text(r.count > 1 ? "×\(r.count)" : "")
                        .foregroundColor(Theme.purple)
                }.width(48)
                TableColumn("Detail") { r in Text(detail(r.event)).lineLimit(1) }
            }

            if let e = detailEvent {
                Divider()
                EventDetailView(event: e).frame(height: 200)
            }

            HStack {
                if let e = detailEvent {
                    Text("▸ \(e.category.rawValue) · \(e.api)")
                        .font(.caption).foregroundColor(Theme.accent).lineLimit(1)
                }
                Spacer()
                if !hookFailures.isEmpty {
                    Text("⚠ \(hookFailures.count) hook issue\(hookFailures.count == 1 ? "" : "s")")
                        .font(.caption).foregroundColor(Theme.danger)
                        .help("Hooks that failed to install:\n"
                              + hookFailures.map { "• \($0.name): \($0.result)" }.joined(separator: "\n"))
                }
                if droppedTotal > 0 {
                    Text("⚠ \(droppedTotal) dropped")
                        .font(.caption).foregroundColor(Theme.danger)
                        .help("Events the capture ring dropped because it filled faster than it could drain.")
                }
                Text("\(filtered.count) events")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 900, maxWidth: .infinity,
               minHeight: 320, idealHeight: 640, maxHeight: .infinity)
        .ophanimTheme()
        .buttonStyle(TerminalButtonStyle())
        .textFieldStyle(TerminalTextFieldStyle())
        .onAppear(perform: load)
        .onChange(of: selection) { _ in detailEvent = selectedEvent }
        .onReceive(refreshTimer) { _ in if autoRefresh { load() } }
    }

    private func detail(_ e: OPEvent) -> String {
        var s = e.summary
        let keys = ["host", "url", "path", "status", "value", "detail", "account", "service"]
        for k in keys where e.fields[k] != nil { s += " \(k)=\(e.fields[k]!)" }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func load() {
        // Collect the .ndjson files and a cheap change-signature (path+size+mtime) first. While the log
        // is idle the 2s auto-refresh hits this and returns without re-reading/parsing the whole log.
        var ndjsonFiles: [URL] = []
        var sig = ""
        for dir in logDirectories() {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "ndjson" {
                ndjsonFiles.append(f)
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                sig += "\(f.lastPathComponent):\(v?.fileSize ?? 0):"
                sig += "\(v?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0);"
            }
        }
        if sig == lastScanSig && !events.isEmpty { return }   // nothing changed on disk since last scan
        lastScanSig = sig

        var all: [OPEvent] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for f in ndjsonFiles {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let data = line.data(using: .utf8),
                   let e = try? decoder.decode(OPEvent.self, from: data) {
                    all.append(e)
                }
            }
        }
        all.sort { $0.timestamp < $1.timestamp }
        // Only replace the array when something actually changed. Auto-refresh runs every 2s; blindly
        // reassigning churns the Table's data and can swallow a click's selection (arrow-key selection
        // re-asserts from the keyboard, which is why it felt fine). A cheap signature is enough since
        // logs are append-only between clears.
        if all.count != events.count || all.last?.timestamp != events.last?.timestamp {
            events = all
        }
        loadError = ndjsonFiles.isEmpty
            ? "No log files found yet. Enable hacking and launch the app, then Refresh."
            : nil
    }

    /// Both the hosted app's sandbox container and the optional shared logs dir.
    private func logDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Documents/Ophanim"),
            home.appendingPathComponent("Library/Logs/Ophanim/\(bundleID)")
        ]
    }

    private func clearLogs() {
        for dir in logDirectories() {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "ndjson" || f.pathExtension == "log" {
                try? FileManager.default.removeItem(at: f)
            }
        }
        events = []
        lastScanSig = ""   // force the next load() to re-scan even if it races the same second
        load()
    }

    private func revealInFinder() {
        if let dir = logDirectories().first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}

/// Inspector for a single selected event: metadata, all structured fields, and the
/// request/response bodies (pretty-printed JSON when possible, otherwise raw/base64).
struct EventDetailView: View {
    let event: OPEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    badge(event.category.rawValue)
                    badge(event.layer.rawValue)
                    if event.disposition != .observed {
                        badge(event.disposition.rawValue).foregroundColor(.orange)
                    }
                    if let rule = event.matchedRuleID { Text("rule: \(rule)").font(.caption) }
                    Spacer()
                    Text(Self.fullFmt.string(from: event.timestamp))
                        .font(.caption).foregroundColor(.secondary)
                }
                Text(event.api).font(.headline).textSelection(.enabled)
                if !event.summary.isEmpty {
                    Text(event.summary).font(.callout).textSelection(.enabled)
                }

                if !event.fields.isEmpty {
                    section("Fields")
                    ForEach(event.fields.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        HStack(alignment: .top, spacing: 6) {
                            Text(k).font(.caption.monospaced()).foregroundColor(.secondary)
                                .frame(width: 170, alignment: .leading)
                            Text(v).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }

                bodyBlock("Request body", event.requestBody)
                bodyBlock("Response body", event.responseBody)

                if let bt = event.backtrace, !bt.isEmpty {
                    section("Backtrace")
                    Text(bt.joined(separator: "\n")).font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private func bodyBlock(_ title: String, _ data: Data?) -> some View {
        if let data = data, !data.isEmpty {
            section("\(title) (\(data.count) bytes)")
            ScrollView(.horizontal) {
                Text(Self.pretty(data)).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    private func section(_ t: String) -> some View {
        Text(t).font(.caption.bold()).foregroundColor(.secondary).padding(.top, 4)
    }

    private func badge(_ t: String) -> some View {
        Text(t).font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15)).cornerRadius(4)
    }

    /// Pretty-print JSON; otherwise show UTF-8 text; otherwise base64.
    static func pretty(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let out = try? JSONSerialization.data(withJSONObject: obj,
                                                 options: [.prettyPrinted, .withoutEscapingSlashes]),
           let s = String(data: out, encoding: .utf8) {
            return s
        }
        return String(data: data, encoding: .utf8) ?? data.base64EncodedString()
    }

    private static let fullFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()
}
