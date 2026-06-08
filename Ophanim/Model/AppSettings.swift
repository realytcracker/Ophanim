//
//  AppSettings.swift
//  Ophanim
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct AppSettingsData: Codable {
    var bundleIdentifier: String = ""

    var keymapping = true
    var sensitivity: Float = 50

    var disableTimeout = false
    var displayRotation = 0
    var iosDeviceModel = "iPad13,8"
    var windowWidth = 1920
    var windowHeight = 1080
    var customScaler = 2.0
    var resolution = 1
    var aspectRatio = 1
    var notch: Bool = NSScreen.hasNotch()
    var bypass = false
    /// Per-detector jailbreak-bypass allowlist (ObjC class names from JBBypassCatalog). Empty = none.
    var jailbreakBypasses: [String] = []
    var discordActivity = DiscordActivity()
    var version = "3.0.0"
    var chainGuard = true
    var chainGuardDebugging = false
    var inverseScreenValues = false
    var metalHUD = false {
        didSet {
            do {
                try Shell.setMetalHUD(bundleIdentifier, enabled: metalHUD)
            } catch {
                Log.shared.error(error)
            }
        }
    }
    var windowFixMethod = 0
    var injectIntrospection = false
    var rootWorkDir = true
    var noKMOnInput = true
    var enableScrollWheel = true
    var hideTitleBar = false
    var floatingWindow = false
    var checkMicPermissionSync = false
    var limitMotionUpdateFrequency = false
    var disableBuiltinMouse = false
    var resizableAspectRatioType = 0
    var resizableAspectRatioWidth = 0
    var resizableAspectRatioHeight = 0
    var blockSleepSpamming = false

    /// Ophanim instrumentation config. Persisted under the "ophanim" key, read in-process by
    /// OphanimCore's OPConfigLoader at agent start.
    var ophanim = OPConfig()

    init() {}

    // handle old 2.x settings where ChainGuard did not exist yet
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        keymapping = try container.decodeIfPresent(Bool.self, forKey: .keymapping) ?? true
        sensitivity = try container.decodeIfPresent(Float.self, forKey: .sensitivity) ?? 50
        disableTimeout = try container.decodeIfPresent(Bool.self, forKey: .disableTimeout) ?? false
        displayRotation = try container.decodeIfPresent(Int.self, forKey: .displayRotation) ?? 0
        iosDeviceModel = try container.decodeIfPresent(String.self, forKey: .iosDeviceModel) ?? "iPad13,8"
        windowWidth = try container.decodeIfPresent(Int.self, forKey: .windowWidth) ?? 1920
        windowHeight = try container.decodeIfPresent(Int.self, forKey: .windowHeight) ?? 1080
        customScaler = try container.decodeIfPresent(Double.self, forKey: .customScaler) ?? 2.0
        resolution = try container.decodeIfPresent(Int.self, forKey: .resolution) ?? 1
        aspectRatio = try container.decodeIfPresent(Int.self, forKey: .aspectRatio) ?? 1
        notch = try container.decodeIfPresent(Bool.self, forKey: .notch) ?? NSScreen.hasNotch()
        bypass = try container.decodeIfPresent(Bool.self, forKey: .bypass) ?? false
        jailbreakBypasses = try container.decodeIfPresent([String].self, forKey: .jailbreakBypasses) ?? []
        discordActivity = try container.decodeIfPresent(DiscordActivity.self,
                                                        forKey: .discordActivity) ?? DiscordActivity()
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "3.0.0"
        chainGuard = try container.decodeIfPresent(Bool.self, forKey: .chainGuard) ?? true
        chainGuardDebugging = try container.decodeIfPresent(Bool.self, forKey: .chainGuardDebugging) ?? false
        inverseScreenValues = try container.decodeIfPresent(Bool.self, forKey: .inverseScreenValues) ?? false
        metalHUD = try container.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        windowFixMethod = try container.decodeIfPresent(Int.self, forKey: .windowFixMethod) ?? 0
        injectIntrospection = try container.decodeIfPresent(Bool.self, forKey: .injectIntrospection) ?? false
        rootWorkDir = try container.decodeIfPresent(Bool.self, forKey: .rootWorkDir) ?? true
        noKMOnInput = try container.decodeIfPresent(Bool.self, forKey: .noKMOnInput) ?? true
        enableScrollWheel = try container.decodeIfPresent(Bool.self, forKey: .enableScrollWheel) ?? true
        hideTitleBar = try container.decodeIfPresent(Bool.self, forKey: .hideTitleBar) ?? false
        floatingWindow = try container.decodeIfPresent(Bool.self, forKey: .floatingWindow) ?? false
        checkMicPermissionSync = try container.decodeIfPresent(Bool.self, forKey: .checkMicPermissionSync) ?? false
        limitMotionUpdateFrequency = try container.decodeIfPresent(Bool.self,
                                                                   forKey: .limitMotionUpdateFrequency) ?? false
        disableBuiltinMouse = try container.decodeIfPresent(Bool.self, forKey: .disableBuiltinMouse) ?? false
        resizableAspectRatioType = try container.decodeIfPresent(Int.self, forKey: .resizableAspectRatioType) ?? 0
        resizableAspectRatioWidth = try container.decodeIfPresent(Int.self, forKey: .resizableAspectRatioWidth) ?? 0
        resizableAspectRatioHeight = try container.decodeIfPresent(Int.self, forKey: .resizableAspectRatioHeight) ?? 0
        blockSleepSpamming = try container.decodeIfPresent(Bool.self, forKey: .blockSleepSpamming) ?? false
        ophanim = try container.decodeIfPresent(OPConfig.self, forKey: .ophanim) ?? OPConfig()
    }
}

class AppSettings: ObservableObject {
    static var appSettingsDir: URL {
        let settingsFolder =
            Galgal.ophanimContainer.appendingPathComponent("App Settings")
        if !FileManager.default.fileExists(atPath: settingsFolder.path) {
            do {
                try FileManager.default.createDirectory(at: settingsFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }
        return settingsFolder
    }

    let info: AppInfo
    let settingsUrl: URL
    var openWithLLDB: Bool = false
    var openLLDBWithTerminal: Bool = true
    // @Published so SwiftUI re-renders on any mutation. AppSettings is a class, so views must
    // observe it via @ObservedObject (not @Binding) - mutating it through a Binding<AppSettings>
    // writes the same reference back and never fires objectWillChange, leaving dependent controls
    // (captions, enable/disable) stale.
    @Published var settings: AppSettingsData {
        didSet {
            encode()
        }
    }

    init(_ info: AppInfo) {
        self.info = info
        settingsUrl = AppSettings.appSettingsDir.appendingPathComponent(info.bundleIdentifier)
                                                .appendingPathExtension("plist")
        settings = AppSettingsData()
        if !decode() {
            encode()
        }

        settings.bundleIdentifier = info.bundleIdentifier
    }

    public func sync() {
        settings.notch = NSScreen.hasNotch()
    }

    public func reset() {
        settings = AppSettingsData()
    }

    @discardableResult
    public func decode() -> Bool {
        do {
            let data = try Data(contentsOf: settingsUrl)
            settings = try PropertyListDecoder().decode(AppSettingsData.self, from: data)
            return true
        } catch {
            print(error)
            return false
        }
    }

    private static let writeQueue = DispatchQueue(label: "be.ophanim.settings.write", qos: .utility)

    @discardableResult
    public func encode() -> Bool {
        // Write off the main thread so toggling a setting doesn't block the UI (the didSet on
        // `settings` calls this on every change). Snapshot is a value copy, serialized in order.
        let snapshot = settings
        let url = settingsUrl
        AppSettings.writeQueue.async {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            do {
                let data = try encoder.encode(snapshot)
                try data.write(to: url)
            } catch {
                print(error)
            }
        }
        return true
    }
}

extension NSScreen {
    public static func hasNotch() -> Bool {
        guard #available(macOS 12, *) else { return false }
        // check if any of the connected screens contains a notch
        return NSScreen.screens.contains { $0.safeAreaInsets.top != 0 }
    }

    private static func getMacModel() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        var modelIdentifier: String?

        if let modelData = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)
            .takeRetainedValue() as? Data {
            if let modelIdentifierCString = String(data: modelData, encoding: .utf8)?.cString(using: .utf8) {
                modelIdentifier = String(cString: modelIdentifierCString)
            }
        }
        IOObjectRelease(service)
        return modelIdentifier
    }
}
