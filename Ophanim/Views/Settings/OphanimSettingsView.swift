//
//  SettingsView.swift
//  Ophanim
//
//  Created by Andrew Glaze on 7/16/22.
//

import SwiftUI

struct OphanimSettingsView: View {
    private enum Tabs: Hashable {
        case keyCover, install, uninstall, appearance, mcp
    }

    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
                .tag(Tabs.appearance)
            // KeyCover tab hidden - KeyCover (at-rest encryption of the emulated keychain) is
            // intentionally disabled in Ophanim, so its settings tab is not surfaced.
            // Install tab removed - Galgal is always installed by default, and the per-app
            // "Application Type" now lives on each app's Application settings tab.
            UninstallSettings.shared
                .tabItem {
                  Label("preferences.tab.uninstall", systemImage: "trash.square")
                }
                .tag(Tabs.uninstall)
            MCPSettings()
                .tabItem {
                    Label("Automation", systemImage: "terminal")
                }
                .tag(Tabs.mcp)
        }
        .ophanimTheme()
        .groupBoxStyle(TerminalGroupBoxStyle())
        .buttonStyle(TerminalButtonStyle())
    }
}

/// MCP (Model Context Protocol) automation preferences. Ophanim exposes a local MCP server so an
/// AI client can list apps, query captured events, read/change capture config, and launch apps.
/// Two transports: a loopback HTTP endpoint hosted by this app, and a headless `--mcp` stdio mode
/// an MCP client spawns directly.
struct MCPSettings: View {
    @AppStorage("ophanim.mcp.http") private var httpEnabled = true
    @AppStorage("ophanim.mcp.port") private var port = 20033
    @AppStorage("ophanim.mcp.bind") private var bindMode = "loopback"
    @AppStorage("ophanim.mcp.bindIP") private var bindIP = ""
    @State private var portText = ""

    private var binaryPath: String { Bundle.main.executablePath ?? "/Applications/Ophanim.app/Contents/MacOS/Ophanim" }
    private var stdioConfig: String {
        """
        {
          "mcpServers": {
            "ophanim": {
              "command": "\(binaryPath)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("HTTP endpoint") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Serve MCP over HTTP (loopback only)", isOn: $httpEnabled)
                        .onChange(of: httpEnabled) { on in
                            if on { MCPHTTPTransport.shared.start() } else { MCPHTTPTransport.shared.stop() }
                        }
                    HStack {
                        Text("Port")
                        TextField("20033", text: $portText)
                            .frame(width: 90)
                            .onSubmit { applyPort() }
                        Button("Apply") { applyPort() }
                        Text("(1024–65535, default 20033)").font(.caption).foregroundColor(.secondary)
                    }
                    .disabled(!httpEnabled)
                    HStack {
                        Text("Bind")
                        Picker("", selection: $bindMode) {
                            Text("Loopback (127.0.0.1)").tag("loopback")
                            Text("All interfaces (0.0.0.0)").tag("all")
                            Text("Specific IP").tag("specific")
                        }
                        .frame(width: 240)
                        .onChange(of: bindMode) { _ in restartIfRunning() }
                        Spacer()
                    }
                    .disabled(!httpEnabled)
                    if bindMode == "specific" {
                        HStack {
                            Text("IP address")
                            TextField("e.g. 192.168.1.50", text: $bindIP)
                                .frame(width: 200)
                                .onSubmit { restartIfRunning() }
                            Button("Apply") { restartIfRunning() }
                            Spacer()
                        }
                        .disabled(!httpEnabled)
                    }
                    if bindMode != "loopback" {
                        Text("⚠ This exposes the MCP server beyond this Mac. Anyone who can reach this "
                             + "address can read captured data and change capture settings. Use only on "
                             + "trusted networks.")
                            .font(.caption).foregroundColor(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("MCP clients connect at http://\(displayHost):\(String(port))/ - "
                         + "click Apply or re-toggle to rebind.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Headless (stdio)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("For clients that spawn the server themselves (e.g. Claude Desktop), add this "
                         + "to the client's MCP config - no need to keep this app open:")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(stdioConfig)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.35))
                    Button("Copy config") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(stdioConfig, forType: .string)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Capabilities") {
                Text("Tools: list_apps · query_events · get_config · set_config · launch_app. "
                     + "The client can read captured behavior and change what each app captures.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { portText = String(port) }
    }

    /// Host shown in the connect-URL hint.
    private var displayHost: String {
        switch bindMode {
        case "all": return "0.0.0.0"
        case "specific": return bindIP.isEmpty ? "127.0.0.1" : bindIP
        default: return "127.0.0.1"
        }
    }

    /// Validate the typed port, persist it, and rebind the live server if it's running.
    private func applyPort() {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)),
              (1024...65535).contains(value) else {
            portText = String(port)   // reject: revert the field
            return
        }
        port = value
        portText = String(value)
        restartIfRunning()
    }

    /// Rebind the live HTTP server to pick up a port/bind change.
    private func restartIfRunning() {
        guard httpEnabled else { return }
        MCPHTTPTransport.shared.stop()
        MCPHTTPTransport.shared.start()
    }
}

/// Appearance / theme preferences (app-wide). The fx toggle gates the digital-rain, scanlines and
/// glow used throughout the UI.
struct AppearanceSettings: View {
    @AppStorage("ophanim.fx.enabled") private var fxEnabled = true
    @AppStorage("ophanim.rain.enabled") private var rainEnabled = false
    @AppStorage("ophanim.fx.wind")   private var windEnabled = true
    @AppStorage("ophanim.fx.glitch") private var glitchEnabled = true
    @AppStorage("ophanim.fx.surge")  private var surgeEnabled = true
    @AppStorage("ophanim.fx.sweep")  private var sweepEnabled = true
    @AppStorage("ophanim.fx.eyes")   private var eyesEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Theme") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("CRT scanlines + glow", isOn: $fxEnabled)
                        .help("Faint scanline overlay and phosphor glow on accents. Turn off for a flat, faster UI.")
                    Toggle("Digital rain", isOn: $rainEnabled)
                        .help("Falling green/purple glyphs behind the UI (the library, editors, options and "
                              + "log windows). Off by default.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Effects") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Wind", isOn: $windEnabled)
                        .help("The digital rain leans and curves in a gusting wind that shifts direction over time.")
                    Toggle("Glitches", isOn: $glitchEnabled)
                        .help("Sparse white flashes on rain heads, plus an occasional horizontal tear line.")
                    Toggle("Surges", isOn: $surgeEnabled)
                        .help("Occasional bursts where a whole rain column briefly brightens.")
                    Toggle("Screen sweep", isOn: $sweepEnabled)
                        .help("A slow bright CRT refresh band that travels down the screen.")
                    Toggle("Eyes", isOn: $eyesEnabled)
                        .help("Eyeballs of varying sizes fade in at random spots in the background, open, "
                              + "blink a few times, then fade away.")
                    Text("Wind, surges and rain glitches apply when Digital rain is on; the sweep and tear "
                         + "glitch apply when CRT scanlines is on; eyes follow the CRT scanlines master toggle.")
                        .font(Theme.caption)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Preview") {
                ZStack {
                    Color.black
                    // Live preview: reflects the toggles above (rain/eyes show only when enabled; the
                    // glow follows the scanlines+glow toggle).
                    DigitalRainView()
                    EyeballsView()
                    Text("OPHANIM")
                        .font(Theme.mono(22, .bold))
                        .foregroundColor(Theme.accentBright)
                        .phosphorGlow(Theme.purple, radius: 6)
                }
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding()
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
