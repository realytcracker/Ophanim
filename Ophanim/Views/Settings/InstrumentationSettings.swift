//
//  InstrumentationSettings.swift
//  Ophanim
//
//  Per-app Ophanim instrumentation tab: master enable, injection method, capture categories,
//  and output sinks. Writes into settings.settings.ophanim (OPConfig), which the existing
//  didSet→encode() persists to the per-app plist that the in-process agent reads at launch.
//

import SwiftUI

struct InstrumentationView: View {
    @ObservedObject var settings: AppSettings
    let app: HostedApp
    // Value-type mirror of the injection strategy. AppSettings is a class, so mutating it through
    // the binding writes the same object reference back and SwiftUI's @State sees "no change" - the
    // caption never re-renders and the side-effect never fires. Driving the picker from this @State
    // (a value type) makes the view react reliably; we write through to settings + (re)inject on
    // user change only, and seed it from settings onAppear (which does NOT trigger injection).
    @State private var strategy: OPInjectionStrategy = .embedded

    private var enabled: Bool { settings.settings.ophanim.enabled }

    private var strategyBinding: Binding<OPInjectionStrategy> {
        Binding(get: { strategy },
                set: { newValue in
                    strategy = newValue
                    settings.settings.ophanim.injectionStrategy = newValue   // persist (didSet → encode)
                    guard app.hasGalgal() else { return }
                    // Switching method rewrites the hosted app's load commands + re-signs.
                    switch newValue {
                    case .sibling: Galgal.installAgentInIPA(app.executable)
                    case .embedded: Galgal.removeAgentFromApp(app.executable)
                    }
                })
    }

    private let cols = [GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox {
                    Toggle("Enable hacking", isOn: bind(\.enabled))
                        .toggleStyle(.switch)
                        .help("Turn the Ophanim hacking engine on for this app. Relaunch the app to apply.")
                    Toggle("Enable inline hooks", isOn: bind(\.enableInlineHooks))
                        .toggleStyle(.switch)
                        .disabled(!enabled)
                        .help("Master gate for inline machine-code hooks. OFF by default - configured "
                              + "inline hooks stay inert until this is on. Patches function code in memory "
                              + "(copy-on-write, in-process only); arm64.")
                    Toggle("Capture backtraces", isOn: bind(\.captureBacktraces))
                        .toggleStyle(.switch)
                        .disabled(!enabled)
                        .help("Record the calling stack for ObjC-level events (device, privacy, attestation, "
                              + "process launches) so you can see which code made each call. Adds overhead.")
                    Toggle("Open log window on launch", isOn: bind(\.autoOpenLog))
                        .toggleStyle(.switch)
                        .disabled(!enabled)
                        .help("Automatically open this app's hacking log window each time you launch it.")
                    Divider()
                    HStack {
                        Text("Injection method")
                        Spacer()
                        Picker("", selection: strategyBinding) {
                            Text("Embedded").tag(OPInjectionStrategy.embedded)
                            Text("Sibling").tag(OPInjectionStrategy.sibling)
                        }
                        .pickerStyle(.segmented).fixedSize().disabled(!enabled)
                        .help("Embedded runs the engine inside the Galgal runtime (full capture). Sibling "
                              + "injects a standalone agent dylib and re-signs the app - it covers network, "
                              + "process, device, privacy, crypto, and the ObjC/Swift hooks, with filesystem "
                              + "partial (NSFileManager only); keychain is Embedded-only.")
                    }
                    Text(strategy == .embedded
                         ? "Runs inside the Galgal runtime - relaunch the app to apply. Full capture."
                         : "Standalone agent dylib (re-signs the app). Keychain capture needs Embedded; "
                           + "filesystem is partial (NSFileManager only, not raw open/stat).")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Capture") {
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 2) {
                        ForEach(OPCategory.allCases, id: \.self) { cat in
                            Toggle(label(cat), isOn: categoryBinding(cat)).help(help(cat))
                        }
                    }
                }
                .disabled(!enabled)

                GroupBox("Output") {
                    HStack(spacing: 18) {
                        Toggle("NDJSON", isOn: sinkBinding(.ndjson))
                            .help("Write events as newline-delimited JSON - the format this log viewer reads.")
                        Toggle("Text", isOn: sinkBinding(.plainText))
                            .help("Write events as flat, human-readable text lines.")
                        Toggle("Console", isOn: sinkBinding(.osLog))
                            .help("Emit events to the unified log (Console.app / log stream), not the in-app viewer.")
                        Spacer()
                    }
                    Text("Logs are written to the app's container; open them with “View log…”.")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!enabled)

                GroupBox("Debugger") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Open with LLDB", isOn: $settings.openWithLLDB)
                            .help("Launch this app attached to the LLDB debugger.")
                        Toggle("Open LLDB in Terminal", isOn: $settings.openLLDBWithTerminal)
                            .disabled(!settings.openWithLLDB)
                            .help("Run LLDB inside a Terminal window instead of attaching silently.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button("Recon…") {
                        ReconWindowManager.shared.show(executable: app.executable,
                                                       bundleID: settings.info.bundleIdentifier,
                                                       appName: app.name)
                    }.help("Inspect the binary's hookable surface before reaching for a disassembler: "
                           + "imported symbols (interpose), ObjC classes (swizzle), text symbols (inline), "
                           + "linked libraries, and a byte-signature scanner.")
                    Button("Edit rules…") {
                        RulesWindowManager.shared.show(settings: settings)
                    }.disabled(!enabled)
                    Button("ObjC hooks…") {
                        ObjCHooksWindowManager.shared.show(settings: settings)
                    }.disabled(!enabled)
                        .help("Swizzle arbitrary @objc (class, selector) boundaries and capture their args - "
                              + "for SDKs / the @objc layer of statically-linked apps.")
                    Button("Swift hooks…") {
                        SwiftHooksWindowManager.shared.show(settings: settings)
                    }.disabled(!enabled)
                        .help("Patch overridable, non-@objc Swift method vtable slots to capture calls "
                              + "ObjC swizzling can't reach (native-Swift vtable patch). Observe-only; arm64.")
                    Button("Inline hooks…") {
                        InlineHooksWindowManager.shared.show(settings: settings)
                    }.disabled(!enabled)
                        .help("Patch arbitrary function machine code (inline) to reach statically-linked "
                              + "/ stripped / static-dispatch code. Requires the inline-hooks gate below.")
                    Button("View log…") {
                        LogWindowManager.shared.show(bundleID: settings.info.bundleIdentifier)
                    }
                    Spacer()
                }
                Text("Capture categories, rules, sinks and pinning apply live to a running app "
                     + "(config is watched). Newly added ObjC/Swift/inline hooks take effect on next launch.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(8)
        }
        // Seed the value-type mirror from persisted settings. Direct @State assignment (not the
        // binding) so this does NOT re-run the injection side-effect on every appear.
        .onAppear { strategy = settings.settings.ophanim.injectionStrategy }
    }

    private func label(_ c: OPCategory) -> String { c.rawValue.capitalized }

    private func help(_ c: OPCategory) -> String {
        switch c {
        case .network: return "HTTP(S) traffic, decrypted TLS payloads, and certificate-pinning checks"
        case .keychain: return "Keychain item access - reads, writes, and deletes"
        case .crypto: return "Encryption, hashing, and key operations"
        case .device: return "Device identifiers (vendor ID, advertising ID)"
        case .privacy: return "Location, pasteboard, contacts, and device attestation"
        case .filesystem: return "File access, plus jailbreak-path probes"
        case .process: return "App launches, child processes, and dynamic library loads"
        case .jailbreak: return "Logs each jailbreak / root detector that gets bypassed"
        }
    }

    // MARK: - Binding helpers (mutating settings.settings.* triggers didSet → encode())

    private func bind<T>(_ kp: WritableKeyPath<OPConfig, T>) -> Binding<T> {
        Binding(get: { settings.settings.ophanim[keyPath: kp] },
                set: { settings.settings.ophanim[keyPath: kp] = $0 })
    }

    private func categoryBinding(_ c: OPCategory) -> Binding<Bool> {
        Binding(get: { settings.settings.ophanim.categories.contains(c) },
                set: { on in
                    var set = Set(settings.settings.ophanim.categories)
                    if on { set.insert(c) } else { set.remove(c) }
                    settings.settings.ophanim.categories = OPCategory.allCases.filter { set.contains($0) }
                })
    }

    private func sinkBinding(_ sink: OPSinkSelection) -> Binding<Bool> {
        Binding(get: { settings.settings.ophanim.sinks.contains(sink) },
                set: { on in
                    var s = settings.settings.ophanim.sinks
                    if on { s.insert(sink) } else { s.remove(sink) }
                    settings.settings.ophanim.sinks = s
                })
    }
}
