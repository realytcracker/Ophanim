//
//  ReconView.swift
//  Ophanim
//
//  Read-only recon for a hosted app's binary: surfaces what is reachable by each hook tier BEFORE
//  the analyst reaches for a disassembler. Shells out to the system `nm`/`otool` (the GUI is not
//  sandboxed and already spawns codesign/lldb) and parses their output:
//    - Imports (interpose): undefined symbols the app imports - the DYLD_INTERPOSE-reachable surface.
//    - Libraries:           linked dylibs - the tell for a bundled static stack (BoringSSL/Cronet/etc).
//    - ObjC classes (swizzle): _OBJC_CLASS_$_ symbols - the ObjC-swizzle surface.
//    - Text symbols (inline):  defined text symbols - functions hookable by name with an inline hook.
//    - Signature scan: find a wildcard byte pattern in the binary (file offsets), for locating
//      stripped/static functions to inline-hook by module+offset.
//

import SwiftUI
import AppKit

/// Opens the recon view as a standalone, resizable window (one per app bundle id), mirroring
/// LogWindowManager so macOS 12 (no SwiftUI openWindow(for:)) is supported.
final class ReconWindowManager: NSObject, NSWindowDelegate {
    static let shared = ReconWindowManager()
    private var windows: [String: NSWindow] = [:]

    func show(executable: URL, bundleID: String, appName: String) {
        if let existing = windows[bundleID] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: ReconView(executable: executable, appName: appName))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Recon - \(appName)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 640))
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
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

struct ReconView: View {
    let executable: URL
    let appName: String

    enum Tab: String, CaseIterable, Identifiable {
        case imports    = "Imports (interpose)"
        case libraries  = "Libraries"
        case objc       = "ObjC classes (swizzle)"
        case text       = "Text symbols (inline)"
        case scan       = "Signature scan"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .imports
    @State private var imports: [String] = []
    @State private var libraries: [String] = []
    @State private var objcClasses: [String] = []
    @State private var textSymbols: [String] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var filter = ""

    // Signature scan
    @State private var pattern = ""
    @State private var scanResults: [String] = []
    @State private var scanning = false
    @State private var scanNote: String?

    private var listed: [String] {
        let src: [String]
        switch tab {
        case .imports:   src = imports
        case .libraries: src = libraries
        case .objc:      src = objcClasses
        case .text:      src = textSymbols
        case .scan:      src = []
        }
        guard !filter.isEmpty else { return src }
        return src.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Recon").font(.headline)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 420)
                if tab != .scan {
                    TextField("Filter", text: $filter).frame(width: 180)
                }
                Spacer()
                if loading { ProgressView().scaleEffect(0.6) }
                Button("Reload") { load() }
            }

            Text(executable.path).font(.caption.monospaced()).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let err = loadError {
                Text(err).font(.caption).foregroundColor(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if tab == .scan {
                scanPane
            } else {
                resultsList(listed)
                Text("\(listed.count) \(tab == .libraries ? "libraries" : "symbols")"
                     + (filter.isEmpty ? "" : " (filtered)"))
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 900, maxWidth: .infinity,
               minHeight: 360, idealHeight: 640, maxHeight: .infinity)
        .ophanimTheme()
        .buttonStyle(TerminalButtonStyle())
        .textFieldStyle(TerminalTextFieldStyle())
        .onAppear(perform: load)
    }

    private func resultsList(_ items: [String]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.25))
    }

    private var scanPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Wildcard byte pattern e.g.  1F 20 03 D5 ?? ??", text: $pattern)
                    .frame(maxWidth: .infinity)
                    .onSubmit { runScan() }
                Button("Scan") { runScan() }.disabled(pattern.isEmpty || scanning)
                if scanning { ProgressView().scaleEffect(0.6) }
            }
            Text("Scans the binary's bytes for the pattern (`??` = any byte) and lists file offsets. "
                 + "Map an offset to a runtime address by hooking module+offset (the binary load address "
                 + "plus the file offset's segment vmaddr); the MCP resolve helper does this math.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            resultsList(scanResults)
            if let note = scanNote {
                Text(note).font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: - Loading

    private func load() {
        loading = true
        loadError = nil
        let bin = executable.path
        Task.detached {
            let libs    = Self.parseLibraries(Self.runProcess("/usr/bin/otool", ["-L", bin]))
            let imps    = Self.parseSymbols(Self.runProcess("/usr/bin/nm", ["-arch", "arm64", "-u", bin])
                                       ?? Self.runProcess("/usr/bin/nm", ["-u", bin]))
            let all     = Self.runProcess("/usr/bin/nm", ["-arch", "arm64", bin])
                          ?? Self.runProcess("/usr/bin/nm", [bin])
            let classes = Self.parseObjCClasses(all)
            let texts   = Self.parseTextSymbols(all)
            let failed  = libs.isEmpty && imps.isEmpty && classes.isEmpty && texts.isEmpty
            await MainActor.run {
                libraries = libs
                imports = imps
                objcClasses = classes
                textSymbols = texts
                loading = false
                loadError = failed
                    ? "Could not read the binary with nm/otool. Is the path valid and is it a Mach-O?"
                    : nil
            }
        }
    }

    private func runScan() {
        let bytes = Self.parsePattern(pattern)
        guard !bytes.isEmpty else { scanNote = "Malformed pattern."; scanResults = []; return }
        scanning = true
        scanNote = nil
        let url = executable
        Task.detached {
            let (hits, note) = Self.scan(url: url, pattern: bytes)
            await MainActor.run {
                scanResults = hits
                scanNote = note
                scanning = false
            }
        }
    }

    // MARK: - Tool runner + parsers (run off the main actor)

    private nonisolated static func runProcess(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        // Discard stderr rather than pipe it: we only drain stdout, so an undrained stderr pipe could
        // deadlock the child if it ever wrote more than the pipe buffer (~64KB).
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func parseLibraries(_ text: String?) -> [String] {
        guard let text else { return [] }
        // otool -L: first line is the binary path; each following line is "\t<path> (compat ...)".
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let paren = t.range(of: " (") else { return t.isEmpty ? nil : t }
            return String(t[..<paren.lowerBound])
        }
    }

    private nonisolated static func parseSymbols(_ text: String?) -> [String] {
        guard let text else { return [] }
        // nm -u: one undefined symbol per line (may be indented). Strip a single leading underscore.
        return text.split(separator: "\n").map { line -> String in
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("_") { s.removeFirst() }
            return s
        }.filter { !$0.isEmpty }.sorted()
    }

    private nonisolated static func parseObjCClasses(_ text: String?) -> [String] {
        guard let text else { return [] }
        let marker = "_OBJC_CLASS_$_"
        var set = Set<String>()
        for line in text.split(separator: "\n") {
            if let r = line.range(of: marker) {
                set.insert(String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return set.sorted()
    }

    private nonisolated static func parseTextSymbols(_ text: String?) -> [String] {
        guard let text else { return [] }
        // nm lines: "<addr> <type> <name>". Text symbols have type t/T. Keep the address + name.
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 3 else { continue }
            let type = cols[1]
            guard type == "t" || type == "T" else { continue }
            var name = cols[2...].joined(separator: " ")
            if name.hasPrefix("_") { name.removeFirst() }
            if name.hasPrefix("_OBJC_") { continue }   // already covered by the ObjC tab
            out.append("0x\(cols[0])  \(name)")
        }
        return out.sorted()
    }

    // MARK: - Signature scan

    /// Parse "1F 20 ?? D5" into bytes; wildcard = nil. Returns [] on any malformed token.
    nonisolated static func parsePattern(_ s: String) -> [UInt8?] {
        var out: [UInt8?] = []
        for tok in s.split(whereSeparator: { $0 == " " || $0 == "," }) {
            if tok == "??" || tok == "?" { out.append(nil) }
            else if let b = UInt8(tok, radix: 16) { out.append(b) }
            else { return [] }
        }
        return out
    }

    nonisolated static func scan(url: URL, pattern: [UInt8?]) -> ([String], String?) {
        guard let data = try? Data(contentsOf: url), !pattern.isEmpty else {
            return ([], "Could not read the binary.")
        }
        let n = data.count, m = pattern.count
        guard n >= m else { return ([], "Pattern longer than the binary.") }
        var hits: [String] = []
        let cap = 500
        var truncated = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i <= n - m {
                var j = 0
                while j < m {
                    if let want = pattern[j], want != p[i + j] { break }
                    j += 1
                }
                if j == m {
                    if hits.count >= cap { truncated = true; break }
                    hits.append(String(format: "file offset 0x%llx", UInt64(i)))
                }
                i += 1
            }
        }
        let note = truncated
            ? "\(hits.count)+ matches (stopped at \(cap)); narrow the pattern."
            : "\(hits.count) match\(hits.count == 1 ? "" : "es")."
        return (hits, note)
    }
}
