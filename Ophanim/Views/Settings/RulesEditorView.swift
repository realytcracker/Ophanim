//
//  RulesEditorView.swift
//  Ophanim
//
//  Visual editor for the per-app interception rules (settings.settings.ophanim.rules). Each rule
//  is a matcher (category / host / url / path / api globs) + an action (observe / block / delay /
//  fault / modify-args / replace-return / script). Edits persist via the AppSettings didSet.
//
//  Identity: rows are selected and bound by the rule's `id` string, NOT by array index. Binding
//  into `rules[index]` by a captured index crashes (Array index out of range) the moment a rule is
//  removed - SwiftUI pushes one more update into the detail editor's bindings with a now-stale
//  index. Looking the rule up by id at get/set time degrades to a safe no-op instead.
//

import SwiftUI
import AppKit

/// Opens the rules editor as a standalone, resizable, non-modal NSWindow (instead of a fixed-size
/// sheet). One window per host app bundle id - re-opening brings the existing one to the front.
/// AppSettings is a reference type, so the editor mutates the shared instance in place (persisted
/// via its didSet→encode); we hand it to the view through a constant binding.
final class RulesWindowManager: NSObject, NSWindowDelegate {
    static let shared = RulesWindowManager()
    private var windows: [String: NSWindow] = [:]

    func show(settings: AppSettings) {
        let key = settings.info.bundleIdentifier
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: RulesEditorView(settings: settings))
        // Don't let the SwiftUI content drive the window size (its maxWidth/maxHeight .infinity makes
        // the preferred size ambiguous → opens at the wrong size). setContentSize is the source of truth.
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        let window = NSWindow(contentViewController: hosting)
        window.title = "Interception Rules - \(key)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 800, height: 540))
        window.contentMinSize = NSSize(width: 620, height: 400)
        window.isReleasedWhenClosed = false   // lifetime owned by `windows`
        window.delegate = self
        window.center()
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closing }
    }
}

struct RulesEditorView: View {
    @ObservedObject var settings: AppSettings
    @State private var selection: String?

    private var rules: [OPRule] { settings.settings.ophanim.rules }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Interception Rules").font(.headline)
                Spacer()
                Button { addRule() } label: { Image(systemName: "plus") }
                Button { if let s = selection { removeRule(s) } } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
            }

            HStack(alignment: .top, spacing: 12) {
                // Rule list
                List(selection: $selection) {
                    ForEach(rules) { rule in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.id).font(.body)
                            Text("\(rule.action.kind.rawValue)\(rule.enabled ? "" : " (off)")")
                                .font(.caption).foregroundColor(.secondary)
                        }.tag(rule.id)
                    }
                }
                .listStyle(.bordered).frame(width: 210)

                // Detail editor - keyed by id; vanishes cleanly if the selected rule is gone.
                if let sel = selection, rules.contains(where: { $0.id == sel }) {
                    ruleEditor(sel).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Select or add a rule").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            HStack {
                Text("\(rules.count) rule(s) - observe-by-default; rules apply on next app launch.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding()
        .frame(minWidth: 620, idealWidth: 800, maxWidth: .infinity,
               minHeight: 400, idealHeight: 540, maxHeight: .infinity)
        .ophanimTheme()
        .buttonStyle(TerminalButtonStyle())
        .textFieldStyle(TerminalTextFieldStyle())
    }

    @ViewBuilder private func ruleEditor(_ id: String) -> some View {
        Form {
            Section("Rule") {
                TextField("ID", text: idBind(id))
                Toggle("Enabled", isOn: boolBind(\.enabled, id))
                TextField("Note", text: optStrBind(\.note, id))
            }
            Section("Match (all set fields must match)") {
                Picker("Category", selection: catBind(id)) {
                    Text("Any").tag(OPCategory?.none)
                    ForEach(OPCategory.allCases, id: \.self) { Text($0.rawValue).tag(OPCategory?.some($0)) }
                }
                TextField("API glob (e.g. SecItem*)", text: matchBind(\.apiGlob, id))
                TextField("Host glob (e.g. *.analytics.com)", text: matchBind(\.hostGlob, id))
                TextField("URL glob", text: matchBind(\.urlGlob, id))
                TextField("Path glob", text: matchBind(\.pathGlob, id))
            }
            Section("Action") {
                Picker("Do", selection: actionKindBind(id)) {
                    ForEach(OPAction.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                switch rule(id)?.action.kind {
                case .replaceReturn:
                    TextField("Canned return value", text: actStrBind(\.cannedReturnValue, id))
                    TextField("HTTP status", text: actIntBind(\.replacementStatus, id))
                case .delay:
                    TextField("Delay (ms)", text: actIntBind(\.delayMilliseconds, id))
                case .fault:
                    TextField("Error code", text: actIntBind(\.faultErrorCode, id))
                case .script:
                    Text("JavaScript (mutate ctx: set ctx.block, ctx.replacementBody (base64), ctx.replacementStatus, ctx.returnValue)")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: actStrBind(\.script, id)).frame(height: 90).font(.system(.body, design: .monospaced))
                default:
                    EmptyView()
                }
            }
        }
    }

    // MARK: mutate-and-persist helpers (all keyed by rule id, never by array index)

    private func rule(_ id: String) -> OPRule? { rules.first(where: { $0.id == id }) }

    private func addRule() {
        var r = settings.settings.ophanim.rules
        // Generate an id that doesn't collide with an existing rule (ids are the identity here).
        var n = r.count + 1
        var newID = "rule-\(n)"
        while r.contains(where: { $0.id == newID }) { n += 1; newID = "rule-\(n)" }
        r.append(OPRule(id: newID, match: OPMatcher(), action: OPAction(kind: .observe)))
        settings.settings.ophanim.rules = r
        selection = newID
    }

    private func removeRule(_ id: String) {
        var r = settings.settings.ophanim.rules
        guard let i = r.firstIndex(where: { $0.id == id }) else { return }
        // Clear selection BEFORE mutating so no detail binding is left pointing at the removed rule.
        selection = nil
        r.remove(at: i)
        settings.settings.ophanim.rules = r
    }

    /// Mutate the rule with `id` in place and persist. No-ops if the rule no longer exists.
    private func mutate(_ id: String, _ body: (inout OPRule) -> Void) {
        var r = settings.settings.ophanim.rules
        guard let i = r.firstIndex(where: { $0.id == id }) else { return }
        body(&r[i])
        settings.settings.ophanim.rules = r
    }

    /// The ID field is special: editing it changes the rule's identity, so keep `selection` in sync.
    private func idBind(_ id: String) -> Binding<String> {
        Binding(get: { rule(id)?.id ?? id },
                set: { newID in
                    let trimmed = newID
                    mutate(id) { $0.id = trimmed }
                    if selection == id { selection = trimmed }
                })
    }
    private func boolBind(_ kp: WritableKeyPath<OPRule, Bool>, _ id: String) -> Binding<Bool> {
        Binding(get: { rule(id)?[keyPath: kp] ?? false },
                set: { v in mutate(id) { $0[keyPath: kp] = v } })
    }
    private func optStrBind(_ kp: WritableKeyPath<OPRule, String?>, _ id: String) -> Binding<String> {
        Binding(get: { rule(id)?[keyPath: kp] ?? "" },
                set: { v in mutate(id) { $0[keyPath: kp] = v.isEmpty ? nil : v } })
    }
    private func matchBind(_ kp: WritableKeyPath<OPMatcher, String?>, _ id: String) -> Binding<String> {
        Binding(get: { rule(id)?.match[keyPath: kp] ?? "" },
                set: { v in mutate(id) { $0.match[keyPath: kp] = v.isEmpty ? nil : v } })
    }
    private func catBind(_ id: String) -> Binding<OPCategory?> {
        Binding(get: { rule(id)?.match.categories?.first },
                set: { v in mutate(id) { $0.match.categories = v.map { [$0] } } })
    }
    private func actionKindBind(_ id: String) -> Binding<OPAction.Kind> {
        Binding(get: { rule(id)?.action.kind ?? .observe },
                set: { v in mutate(id) { $0.action.kind = v } })
    }
    private func actStrBind(_ kp: WritableKeyPath<OPAction, String?>, _ id: String) -> Binding<String> {
        Binding(get: { rule(id)?.action[keyPath: kp] ?? "" },
                set: { v in mutate(id) { $0.action[keyPath: kp] = v.isEmpty ? nil : v } })
    }
    private func actIntBind(_ kp: WritableKeyPath<OPAction, Int?>, _ id: String) -> Binding<String> {
        Binding(get: { rule(id)?.action[keyPath: kp].map(String.init) ?? "" },
                set: { v in mutate(id) { $0.action[keyPath: kp] = Int(v) } })
    }
}

// MARK: - ObjC boundary-hook editor

/// Standalone resizable window for editing the per-app ObjC boundary hooks (objcHooks). One window
/// per host bundle id.
final class ObjCHooksWindowManager: NSObject, NSWindowDelegate {
    static let shared = ObjCHooksWindowManager()
    private var windows: [String: NSWindow] = [:]

    func show(settings: AppSettings) {
        let key = settings.info.bundleIdentifier
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let hosting = NSHostingController(rootView: ObjCHooksEditorView(settings: settings))
        // Don't let the SwiftUI content drive the window size (its maxWidth/maxHeight .infinity makes
        // the preferred size ambiguous → opens at the wrong size). setContentSize is the source of truth.
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        let window = NSWindow(contentViewController: hosting)
        window.title = "ObjC Boundary Hooks - \(key)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 800, height: 540))
        window.contentMinSize = NSSize(width: 620, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closing }
    }
}

/// Visual editor for OPConfig.objcHooks. Rows are index-selected; selection is cleared before any
/// removal so no detail binding is left pointing at a stale index.
struct ObjCHooksEditorView: View {
    @ObservedObject var settings: AppSettings
    @State private var selection: Int?

    private var hooks: [OPObjCHook] { settings.settings.ophanim.objcHooks }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("ObjC Boundary Hooks").font(.headline)
                Spacer()
                Button { add() } label: { Image(systemName: "plus") }
                Button { if let s = selection { remove(s) } } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
            }
            HStack(alignment: .top, spacing: 12) {
                List(selection: $selection) {
                    ForEach(Array(hooks.enumerated()), id: \.offset) { i, h in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.className.isEmpty ? "(class)" : h.className).font(.body)
                            Text("\(h.classMethod ? "+" : "-")\(h.selector.isEmpty ? "(selector)" : h.selector) · \(h.category.rawValue)")
                                .font(.caption).foregroundColor(.secondary)
                        }.tag(i)
                    }
                }
                .listStyle(.bordered).frame(width: 240)

                if let s = selection, s < hooks.count {
                    editor(s).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Select or add a hook").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            HStack {
                Text("\(hooks.count) hook(s) - @objc methods only (objc_msgSend-dispatched); void methods; "
                     + "captured args incl. NSData. Applies on next app launch.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding()
        .frame(minWidth: 620, idealWidth: 800, maxWidth: .infinity,
               minHeight: 400, idealHeight: 540, maxHeight: .infinity)
        .ophanimTheme()
        .buttonStyle(TerminalButtonStyle())
        .textFieldStyle(TerminalTextFieldStyle())
    }

    @ViewBuilder private func editor(_ i: Int) -> some View {
        Form {
            Section("Target") {
                TextField("Class name (e.g. NSURLSession)", text: strBind(i, \.className))
                    .help("Objective-C class to swizzle, by its runtime name (as NSClassFromString sees it).")
                TextField("Selector (e.g. URLSession:dataTask:didReceiveData:)", text: strBind(i, \.selector))
                    .help("Method selector to hook. Only void methods are hooked (the data-callback shape); "
                          + "value-returning selectors are skipped.")
                Toggle("Class method (+)", isOn: boolBind(i, \.classMethod))
                    .help("On = hook the class (+) method; off = the instance (-) method.")
                Picker("Object args", selection: argsBind(i)) {
                    ForEach(0...3, id: \.self) { Text("\($0)").tag($0) }
                }
                .help("How many leading object arguments to log (NSData is captured as a body, NSString as "
                      + "a field).")
            }
            Section("Capture") {
                Picker("Category", selection: catBind(i)) {
                    ForEach(OPCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .help("Capture category to log under; must be enabled for the hook to fire.")
                TextField("Label (optional)", text: optStrBind(i, \.api))
                    .help("Event label + rule-matching name. Defaults to \"Class.selector\".")
            }
        }
    }

    // MARK: index-safe mutate/persist helpers (selection cleared before removal)

    private func add() {
        var a = settings.settings.ophanim.objcHooks
        a.append(OPObjCHook(className: "", selector: "", args: 1, classMethod: false, category: .network))
        settings.settings.ophanim.objcHooks = a
        selection = a.count - 1
    }
    private func remove(_ i: Int) {
        var a = settings.settings.ophanim.objcHooks
        guard i < a.count else { return }
        selection = nil
        a.remove(at: i)
        settings.settings.ophanim.objcHooks = a
    }
    private func mutate(_ i: Int, _ body: (inout OPObjCHook) -> Void) {
        var a = settings.settings.ophanim.objcHooks
        guard i < a.count else { return }
        body(&a[i])
        settings.settings.ophanim.objcHooks = a
    }
    private func strBind(_ i: Int, _ kp: WritableKeyPath<OPObjCHook, String>) -> Binding<String> {
        Binding(get: { i < hooks.count ? hooks[i][keyPath: kp] : "" },
                set: { v in mutate(i) { $0[keyPath: kp] = v } })
    }
    private func optStrBind(_ i: Int, _ kp: WritableKeyPath<OPObjCHook, String?>) -> Binding<String> {
        Binding(get: { (i < hooks.count ? hooks[i][keyPath: kp] : nil) ?? "" },
                set: { v in mutate(i) { $0[keyPath: kp] = v.isEmpty ? nil : v } })
    }
    private func boolBind(_ i: Int, _ kp: WritableKeyPath<OPObjCHook, Bool>) -> Binding<Bool> {
        Binding(get: { i < hooks.count ? hooks[i][keyPath: kp] : false },
                set: { v in mutate(i) { $0[keyPath: kp] = v } })
    }
    private func argsBind(_ i: Int) -> Binding<Int> {
        Binding(get: { i < hooks.count ? hooks[i].args : 1 },
                set: { v in mutate(i) { $0.args = v } })
    }
    private func catBind(_ i: Int) -> Binding<OPCategory> {
        Binding(get: { i < hooks.count ? hooks[i].category : .network },
                set: { v in mutate(i) { $0.category = v } })
    }
}

// MARK: - Native-Swift vtable-hook editor (Tier 2.5)

/// Standalone resizable window for editing the per-app native-Swift vtable hooks (swiftHooks). One
/// window per host bundle id.
final class SwiftHooksWindowManager: NSObject, NSWindowDelegate {
    static let shared = SwiftHooksWindowManager()
    private var windows: [String: NSWindow] = [:]

    func show(settings: AppSettings) {
        let key = settings.info.bundleIdentifier
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let hosting = NSHostingController(rootView: SwiftHooksEditorView(settings: settings))
        // Don't let the SwiftUI content drive the window size (its maxWidth/maxHeight .infinity makes
        // the preferred size ambiguous → opens at the wrong size). setContentSize is the source of truth.
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        let window = NSWindow(contentViewController: hosting)
        window.title = "Swift Vtable Hooks - \(key)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 800, height: 540))
        window.contentMinSize = NSSize(width: 620, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closing }
    }
}

/// Visual editor for OPConfig.swiftHooks. Rows are index-selected; selection is cleared before any
/// removal so no detail binding is left pointing at a stale index.
struct SwiftHooksEditorView: View {
    @ObservedObject var settings: AppSettings
    @State private var selection: Int?

    private var hooks: [OPSwiftHook] { settings.settings.ophanim.swiftHooks }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Swift Vtable Hooks").font(.headline)
                Spacer()
                Button { add() } label: { Image(systemName: "plus") }
                Button { if let s = selection { remove(s) } } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
            }
            HStack(alignment: .top, spacing: 12) {
                List(selection: $selection) {
                    ForEach(Array(hooks.enumerated()), id: \.offset) { i, h in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.className.isEmpty ? "(class)" : h.className).font(.body)
                            Text("\(h.method.isEmpty ? "(method)" : h.method) · \(h.category.rawValue)")
                                .font(.caption).foregroundColor(.secondary)
                        }.tag(i)
                    }
                }
                .listStyle(.bordered).frame(width: 240)

                if let s = selection, s < hooks.count {
                    editor(s).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Select or add a hook").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            HStack {
                Text("\(hooks.count) hook(s) - overridable, non-@objc Swift methods dispatched through "
                     + "the vtable; observe-only (void). -O may devirtualize concrete calls. arm64 only. "
                     + "Use find_symbols to locate the class (_TtC… form) + mangled method. Applies on next app launch.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding()
        .frame(minWidth: 620, idealWidth: 800, maxWidth: .infinity,
               minHeight: 400, idealHeight: 540, maxHeight: .infinity)
        .ophanimTheme()
        .buttonStyle(TerminalButtonStyle())
        .textFieldStyle(TerminalTextFieldStyle())
    }

    @ViewBuilder private func editor(_ i: Int) -> some View {
        Form {
            Section("Target") {
                TextField("Class name (runtime _TtC… or Module.Class)", text: strBind(i, \.className))
                    .help("Swift class whose vtable to patch, by its runtime name (the _TtC… or "
                          + "Module.Class form find_symbols reports). Must be NSClassFromString-resolvable.")
                TextField("Method (substring of the mangled symbol)", text: strBind(i, \.method))
                    .help("Substring matched against each vtable slot's mangled symbol to pick the method "
                          + "(e.g. \"processPayload\"). Only overridable, vtable-dispatched methods are reachable.")
            }
            Section("Capture") {
                Picker("Category", selection: catBind(i)) {
                    ForEach(OPCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .help("Capture category to log under; must be enabled for the hook to fire.")
                TextField("Label (optional)", text: optStrBind(i, \.api))
                    .help("Event label for captured calls. Defaults to the matched mangled symbol.")
            }
        }
    }

    // MARK: index-safe mutate/persist helpers (selection cleared before removal)

    private func add() {
        var a = settings.settings.ophanim.swiftHooks
        a.append(OPSwiftHook(className: "", method: "", category: .process))
        settings.settings.ophanim.swiftHooks = a
        selection = a.count - 1
    }
    private func remove(_ i: Int) {
        var a = settings.settings.ophanim.swiftHooks
        guard i < a.count else { return }
        selection = nil
        a.remove(at: i)
        settings.settings.ophanim.swiftHooks = a
    }
    private func mutate(_ i: Int, _ body: (inout OPSwiftHook) -> Void) {
        var a = settings.settings.ophanim.swiftHooks
        guard i < a.count else { return }
        body(&a[i])
        settings.settings.ophanim.swiftHooks = a
    }
    private func strBind(_ i: Int, _ kp: WritableKeyPath<OPSwiftHook, String>) -> Binding<String> {
        Binding(get: { i < hooks.count ? hooks[i][keyPath: kp] : "" },
                set: { v in mutate(i) { $0[keyPath: kp] = v } })
    }
    private func optStrBind(_ i: Int, _ kp: WritableKeyPath<OPSwiftHook, String?>) -> Binding<String> {
        Binding(get: { (i < hooks.count ? hooks[i][keyPath: kp] : nil) ?? "" },
                set: { v in mutate(i) { $0[keyPath: kp] = v.isEmpty ? nil : v } })
    }
    private func catBind(_ i: Int) -> Binding<OPCategory> {
        Binding(get: { i < hooks.count ? hooks[i].category : .process },
                set: { v in mutate(i) { $0.category = v } })
    }
}

// MARK: - Inline (machine-code) hook editor (Tier 3)

/// Standalone resizable window for editing the per-app inline hooks (inlineHooks). One window per host.
final class InlineHooksWindowManager: NSObject, NSWindowDelegate {
    static let shared = InlineHooksWindowManager()
    private var windows: [String: NSWindow] = [:]

    func show(settings: AppSettings) {
        let key = settings.info.bundleIdentifier
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let hosting = NSHostingController(rootView: InlineHooksEditorView(settings: settings))
        // Don't let the SwiftUI content drive the window size (its maxWidth/maxHeight .infinity makes
        // the preferred size ambiguous → opens at the wrong size). setContentSize is the source of truth.
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        let window = NSWindow(contentViewController: hosting)
        window.title = "Inline Hooks - \(key)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1100, height: 640))  // wide enough for the long field labels
        window.contentMinSize = NSSize(width: 820, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closing }
    }
}

/// Visual editor for OPConfig.inlineHooks. Index-keyed; selection cleared before removal.
struct InlineHooksEditorView: View {
    @ObservedObject var settings: AppSettings
    @State private var selection: Int?

    private var hooks: [OPInlineHook] { settings.settings.ophanim.inlineHooks }
    private var armed: Bool { settings.settings.ophanim.enableInlineHooks }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Inline Hooks").font(.headline)
                Spacer()
                Button { add() } label: { Image(systemName: "plus") }
                Button { if let s = selection { remove(s) } } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
            }
            if !armed {
                Text("⚠ Inline hooks are OFF - turn on “Enable inline hooks” in Hacking to arm these.")
                    .font(.caption).foregroundColor(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 12) {
                List(selection: $selection) {
                    ForEach(Array(hooks.enumerated()), id: \.offset) { i, h in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.api.isEmpty ? "(label)" : h.api).font(.body)
                            Text("\(targetSummary(h)) · \(h.category.rawValue)")
                                .font(.caption).foregroundColor(.secondary)
                        }.tag(i)
                    }
                }
                .listStyle(.bordered).frame(width: 250)

                if let s = selection, s < hooks.count {
                    editor(s).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Select or add a hook").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            HStack {
                Text("\(hooks.count) hook(s) - located by address / symbol / module+offset / signature "
                     + "(from Ghidra or by hand). arm64; applies on next app launch.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding()
        .frame(minWidth: 620, idealWidth: 800, maxWidth: .infinity,
               minHeight: 400, idealHeight: 540, maxHeight: .infinity)
        .ophanimTheme()
        .buttonStyle(TerminalButtonStyle())
        .textFieldStyle(TerminalTextFieldStyle())
    }

    private func targetSummary(_ h: OPInlineHook) -> String {
        if let a = h.address, !a.isEmpty { return a }
        if let s = h.symbol, !s.isEmpty { return s }
        if let o = h.offset, !o.isEmpty { return "\(h.module ?? "exe")+\(o)" }
        if let g = h.signature, !g.isEmpty { return "sig \(g.prefix(16))…" }
        return "(unresolved)"
    }

    @ViewBuilder private func editor(_ i: Int) -> some View {
        Form {
            Section("Identity") {
                TextField("Label (api)", text: strBind(i, \.api))
                    .help("Display name for captured events from this hook, and what an interception "
                          + "rule's API glob matches against (e.g. \"grpc_unary_req\").")
                Picker("Category", selection: catBind(i)) {
                    ForEach(OPCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .help("Capture category this hook logs under. The category must be enabled for the hook "
                      + "to install and fire.")
            }
            Section("Target - first non-empty field wins") {
                TextField("Absolute address (0x…)", text: optStrBind(i, \.address))
                    .help("Exact runtime address to patch (hex). Rarely used - addresses move with ASLR; "
                          + "prefer module+offset or a signature.")
                TextField("Symbol (dlsym)", text: optStrBind(i, \.symbol))
                    .help("Exported symbol name resolved via dlsym (e.g. a C function or @_cdecl export). "
                          + "Enable “Follow leading branch” if it resolves to a one-instruction thunk.")
                TextField("Module (path substring; blank = main executable)", text: optStrBind(i, \.module))
                    .help("Substring of the loaded image's path that scopes the offset/signature lookup "
                          + "(e.g. \"Snapchat\" or a framework name). Blank = the app's main executable.")
                TextField("Offset in module (0x… or decimal)", text: optStrBind(i, \.offset))
                    .help("Static offset within the module as Ghidra reports it (relative to the image's "
                          + "preferred base). The ASLR slide is added automatically at runtime.")
                TextField("Signature (e.g. 1F 20 ?? D5)", text: optStrBind(i, \.signature))
                    .help("Byte pattern scanned over the module's executable text; “??” matches any byte. "
                          + "Survives recompiles better than a fixed offset.")
                Toggle("Follow leading branch (thunk)", isOn: boolBind(i, \.followThunk))
                    .help("If the resolved address is a one-instruction unconditional branch (common for "
                          + "exported Swift), hook the real function it jumps to instead of the thunk.")
            }
            Section("Render - deref a register as an object") {
                ForEach(0..<8, id: \.self) { r in
                    Picker("x\(r)", selection: renderArgBind(i, r)) { renderOptions() }
                        .help("How to capture argument register x\(r): “(none)” logs the raw pointer; nsdata "
                              + "captures the bytes as a body; nsstring/objcDesc/cString decode it. "
                              + "Safe - a non-object value falls back to hex.")
                }
                Picker("return", selection: renderReturnBind(i)) { renderOptions() }
                    .help("Render the return value the same way. This runs the original first (enter/leave) "
                          + "to observe the real result, so it implies “capture return”.")
            }
        }
    }

    @ViewBuilder private func renderOptions() -> some View {
        Text("(none)").tag(OPArgRender?.none)
        ForEach(OPArgRender.allCases, id: \.self) { Text($0.rawValue).tag(OPArgRender?.some($0)) }
    }

    // MARK: index-safe mutate/persist helpers

    private func add() {
        var a = settings.settings.ophanim.inlineHooks
        a.append(OPInlineHook(api: "", category: .process))
        settings.settings.ophanim.inlineHooks = a
        selection = a.count - 1
    }
    private func remove(_ i: Int) {
        var a = settings.settings.ophanim.inlineHooks
        guard i < a.count else { return }
        selection = nil
        a.remove(at: i)
        settings.settings.ophanim.inlineHooks = a
    }
    private func mutate(_ i: Int, _ body: (inout OPInlineHook) -> Void) {
        var a = settings.settings.ophanim.inlineHooks
        guard i < a.count else { return }
        body(&a[i])
        settings.settings.ophanim.inlineHooks = a
    }
    private func strBind(_ i: Int, _ kp: WritableKeyPath<OPInlineHook, String>) -> Binding<String> {
        Binding(get: { i < hooks.count ? hooks[i][keyPath: kp] : "" },
                set: { v in mutate(i) { $0[keyPath: kp] = v } })
    }
    private func optStrBind(_ i: Int, _ kp: WritableKeyPath<OPInlineHook, String?>) -> Binding<String> {
        Binding(get: { (i < hooks.count ? hooks[i][keyPath: kp] : nil) ?? "" },
                set: { v in mutate(i) { $0[keyPath: kp] = v.isEmpty ? nil : v } })
    }
    private func boolBind(_ i: Int, _ kp: WritableKeyPath<OPInlineHook, Bool>) -> Binding<Bool> {
        Binding(get: { i < hooks.count ? hooks[i][keyPath: kp] : false },
                set: { v in mutate(i) { $0[keyPath: kp] = v } })
    }
    private func catBind(_ i: Int) -> Binding<OPCategory> {
        Binding(get: { i < hooks.count ? hooks[i].category : .process },
                set: { v in mutate(i) { $0.category = v } })
    }
    private func renderArgBind(_ i: Int, _ r: Int) -> Binding<OPArgRender?> {
        Binding(get: { i < hooks.count ? hooks[i].renderArgs?["x\(r)"] : nil },
                set: { v in mutate(i) { h in
                    var m = h.renderArgs ?? [:]
                    if let v = v { m["x\(r)"] = v } else { m.removeValue(forKey: "x\(r)") }
                    h.renderArgs = m.isEmpty ? nil : m
                } })
    }
    private func renderReturnBind(_ i: Int) -> Binding<OPArgRender?> {
        Binding(get: { i < hooks.count ? hooks[i].renderReturn : nil },
                set: { v in mutate(i) { $0.renderReturn = v } })
    }
}
