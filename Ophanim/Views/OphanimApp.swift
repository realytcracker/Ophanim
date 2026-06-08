//
//  OphanimApp.swift
//  Ophanim
//

import SwiftUI

/// Real entry point. When launched with `--mcp` we run a headless MCP server instead of the SwiftUI
/// app (so an MCP client can spawn this binary with no GUI / dock icon):
///   Ophanim --mcp                          → stdio transport (newline-delimited JSON-RPC)
///   Ophanim --mcp --http [--port N] [--bind loopback|all|<ip>]
///                                          → headless HTTP transport (blocking). Supplying --port
///                                            or --bind implies --http.
@main
enum OphanimMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--mcp") {
            let port = argValue(args, "--port").flatMap { UInt16($0) }
            let bind = argValue(args, "--bind")
            let httpMode = args.contains("--http") || port != nil || bind != nil
            if httpMode {
                MCPHTTPTransport.shared.start(port: port, bind: bind)
                let t = MCPHTTPTransport.shared
                guard t.isRunning else {
                    FileHandle.standardError.write(Data("ophanim: MCP HTTP failed to bind\n".utf8))
                    exit(1)
                }
                FileHandle.standardError.write(
                    Data("ophanim: MCP HTTP listening on \(t.boundHost):\(t.boundPort)\n".utf8))
                dispatchMain()   // never returns
            }
            MCPStdioTransport.run()   // never returns
        }
        OphanimApp.main()
    }

    /// Value following a `--flag` on the command line, if present.
    private static func argValue(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    @AppStorage("ShowLowPowerModeAlert") var showLowPowerModeAlert = true

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            URLHandler.shared.processURL(url: url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force the whole app - including the menu bar, context menus and Picker dropdowns, which
        // SwiftUI's .preferredColorScheme doesn't reach - into dark appearance so native menus match
        // the terminal theme. Green selection comes from the SwiftUI .tint(Theme.accent) at the roots.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        UpdateScheme.checkForUpdate()

        // Local MCP endpoint on 127.0.0.1:20033 so an AI client can drive Ophanim while it runs.
        // Toggleable in Settings; defaults on.
        if UserDefaults.standard.object(forKey: "ophanim.mcp.http") as? Bool ?? true {
            MCPHTTPTransport.shared.start()
        }

        UserDefaults.standard.register(
            defaults: ["NSApplicationCrashOnExceptions": true]
        )

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(powerStateChanged),
                                               name: Notification.Name.NSProcessInfoPowerStateDidChange,
                                               object: nil)
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            powerModal()
        }
        URLCache.iconCache.removeAllCachedResponses()
        // Code that run once on first launch
        let launchedBefore = UserDefaults.standard.bool(forKey: "launchedBefore")
        if !launchedBefore {
            UserDefaults.standard.set(true, forKey: "launchedBefore")

            // KeyCover (at-rest encryption of the emulated keychain) is intentionally left
            // DISABLED for Ophanim - an instrumentation tool wants keychain data visible, not
            // encrypted, and auto-enabling it would store a key in the macOS login keychain
            // (a launch-time prompt) for no benefit. Enable manually in Settings ▸ KeyCover if
            // ever needed.
        }

    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @objc func powerStateChanged(_ notification: Notification) {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            Task { @MainActor in
                self.powerModal()
            }
        }
    }

    func powerModal() {
        if showLowPowerModeAlert {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("alert.power.title", comment: "")
            alert.informativeText = NSLocalizedString("alert.power.subtitle", comment: "")
            alert.addButton(withTitle: NSLocalizedString("button.OK", comment: ""))
            alert.showsSuppressionButton = true
            alert.alertStyle = .critical

            if alert.runModal() == .alertFirstButtonReturn {
                showLowPowerModeAlert = alert.suppressionButton?.state == .off
            }
        }
    }
}

struct OphanimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State var isSigningSetupShown = false

    var body: some Scene {
        WindowGroup {
            MainView(isSigningSetupShown: $isSigningSetupShown)
                .environmentObject(InstallVM.shared)
                .environmentObject(AppsVM.shared)
                .environmentObject(AppIntegrity())
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                    SoundDeviceService.shared.prepareSoundDevice()
                    NotifyService.shared.allowNotify()
                }
        }
        .handlesExternalEvents(matching: ["{same path of URL?}"]) // create new window if doesn't exist
        .commands {
            SidebarCommands()
            OphanimMenuView(isSigningSetupShown: $isSigningSetupShown)
            OphanimHelpMenuView()
            OphanimViewMenuView()
        }

        Settings {
            OphanimSettingsView()
        }
    }
}
