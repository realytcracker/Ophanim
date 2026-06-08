//
//  Galgal.swift
//  Ophanim
//

import Foundation
import injection

class Galgal {
    private static let frameworksURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Frameworks")
    private static let galgalFramework = frameworksURL
        .appendingPathComponent("Galgal")
        .appendingPathExtension("framework")
    private static let galgalPath = galgalFramework
        .appendingPathComponent("Galgal")
    private static let galgalInterfacePath = galgalFramework
        .appendingPathComponent("PlugIns")
        .appendingPathComponent("GalgalInterface")
        .appendingPathExtension("bundle")
    private static let bundledGalgalFramework = Bundle.main.bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Frameworks")
        .appendingPathComponent("Galgal")
        .appendingPathExtension("framework")

    // Sibling-injection agent dylib: installed in ~/Library/Frameworks alongside Galgal.framework,
    // bundled in the app's Contents/Frameworks. Injected as a 2nd LC_LOAD_DYLIB when a hosted app
    // is set to the .sibling injection strategy.
    private static let agentPath = frameworksURL.appendingPathComponent("OphanimAgent.dylib")
    private static let bundledAgent = Bundle.main.bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Frameworks")
        .appendingPathComponent("OphanimAgent.dylib")

    public static var ophanimContainer: URL {
        let ophanimPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("be.ophanim.Ophanim")
        if !FileManager.default.fileExists(atPath: ophanimPath.path) {
            do {
                try FileManager.default.createDirectory(at: ophanimPath,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }

        return ophanimPath
    }

    static func installOnSystem() {
        Task(priority: .background) {
            do {
                Log.shared.log("Installing Galgal")

                // Check if Frameworks folder exists, if not, create it
                if !FileManager.default.fileExists(atPath: frameworksURL.path) {
                    try FileManager.default.createDirectory(
                        atPath: frameworksURL.path,
                        withIntermediateDirectories: true,
                        attributes: [:])
                }

                // Replace any installed version with the one bundled in Ophanim.
                Log.shared.log("Copying Galgal to Frameworks")
                try FileManager.default.replaceItem(at: galgalFramework, with: bundledGalgalFramework)

                // Stage the sibling-injection agent dylib next to the framework.
                installAgentOnSystem()
            } catch {
                Log.shared.error(error)
            }
        }
    }

    static func installInIPA(_ exec: URL) async throws {
        var binary = try Data(contentsOf: exec)
        try Macho.stripBinary(&binary)

        Inject.injectMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: galgalPath.path,
                           finishHandle: { result in
            if result {
                do {
                    try installPluginInIPA(exec.deletingLastPathComponent())
                    try Shell.signApp(exec)
                } catch {
                    Log.shared.error(error)
                }
            }
        })
    }

    static func installPluginInIPA(_ payload: URL) throws {
        let allFiles = try FileManager.default.contentsOfDirectory(
            at: bundledGalgalFramework, includingPropertiesForKeys: [])
        for localizationDirectory in allFiles where localizationDirectory.pathExtension == "lproj" {
            _ = try copyAsset(target: payload,
                              directoryName: localizationDirectory.lastPathComponent,
                              component: "Galgal", pathExtension: "strings")
        }

        let bundledGalgalResources = bundledGalgalFramework
            .appendingPathComponent("Versions")
            .appendingPathComponent("A")
            .appendingPathComponent("Resources")
        if FileManager.default.fileExists(atPath: bundledGalgalResources.path) {
            let allFiles = try FileManager.default.contentsOfDirectory(
                at: bundledGalgalResources, includingPropertiesForKeys: [])
            for localizationDirectory in allFiles where localizationDirectory.pathExtension == "lproj" {
                _ = try copyAsset(source: bundledGalgalResources,
                                  target: payload,
                                  directoryName: localizationDirectory.lastPathComponent,
                                  component: "Galgal", pathExtension: "strings")
            }
        }

        let bundleTarget = try copyAsset(target: payload, directoryName: "PlugIns",
                                         component: "GalgalInterface", pathExtension: "bundle")
        try bundleTarget.fixExecutable()
        try Shell.signMacho(bundleTarget)
    }

    static func copyAsset(source: URL = bundledGalgalFramework, target: URL, directoryName: String,
                          component: String, pathExtension: String) throws -> URL {
        let directory = target.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let target = directory
                    .appendingPathComponent(component)
                    .appendingPathExtension(pathExtension)

        let source = source
                    .appendingPathComponent(directoryName)
                    .appendingPathComponent(component)
                    .appendingPathExtension(pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            try FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
        return target
    }

    static func injectInIPA(_ exec: URL, payload: URL) throws {
        var binary = try Data(contentsOf: exec)
        try Macho.stripBinary(&binary)

        Inject.injectMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: "@executable_path/Frameworks/Galgal.dylib",
                           finishHandle: { result in
            if result {
                Task(priority: .background) {
                    do {
                        if !FileManager.default.fileExists(atPath: payload.appendingPathComponent("Frameworks").path) {
                            try FileManager.default.createDirectory(
                                at: payload.appendingPathComponent("Frameworks"),
                                withIntermediateDirectories: true)
                        }

                        let libraryTarget = payload.appendingPathComponent("Frameworks")
                            .appendingPathComponent("Galgal")
                            .appendingPathExtension("dylib")

                        let tools = bundledGalgalFramework
                            .appendingPathComponent("Galgal")

                        try FileManager.default.replaceItem(at: libraryTarget, with: tools)

                        try libraryTarget.fixExecutable()
                        try installPluginInIPA(payload)
                    } catch {
                        Log.shared.error(error)
                    }
                }
            }
        })
    }

    static func removeFromApp(_ exec: URL) async {
        Inject.removeMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: galgalPath.path,
                           finishHandle: { result in
            if result {
                do {
                    let pluginUrl = exec.deletingLastPathComponent()
                        .appendingPathComponent("PlugIns")
                        .appendingPathComponent("GalgalInterface")
                        .appendingPathExtension("bundle")

                    if FileManager.default.fileExists(atPath: pluginUrl.path) {
                        try FileManager.default.removeItem(at: pluginUrl)
                    }
                    try Shell.signApp(exec)
                } catch {
                    Log.shared.error(error)
                }
            }
        })
    }

    /// Walk a Mach-O's load commands and report whether any LC_LOAD_DYLIB points at `dylibPath`.
    private static func execLinksDylib(atURL url: URL, dylibPath: String) throws -> Bool {
        var binary = try Data(contentsOf: url)
        try Macho.stripBinary(&binary)
        var result = false
        try _ = Macho.iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let loadCommand = binary.extract(load_command.self, offset: offset,
                                             swap: shouldSwap ? swap_load_command:nil)
            if loadCommand.cmd == UInt32(LC_LOAD_DYLIB) {
                let dylibCommand = binary.extract(dylib_command.self, offset: offset,
                                                  swap: shouldSwap ? swap_dylib_command:nil)

                let dylibName = String(data: binary,
                                       offset: offset,
                                       commandSize: Int(dylibCommand.cmdsize),
                                       loadCommandString: dylibCommand.dylib.name)
                if dylibName == dylibPath {
                    result = true
                    return true
                }
            }
            return false
        }
        return result
    }

    static func installedInExec(atURL url: URL) throws -> Bool {
        try execLinksDylib(atURL: url, dylibPath: galgalPath.esc)
    }

    static func isInstalled() throws -> Bool {
        try FileManager.default.fileExists(atPath: galgalPath.path)
            && FileManager.default.fileExists(atPath: galgalInterfacePath.path)
            && Macho.isMachoValidArch(galgalPath)
    }

    // MARK: - Sibling agent injection (OphanimAgent.dylib)

    /// Copy the bundled agent dylib next to the system Galgal framework so injected apps can load it.
    static func installAgentOnSystem() {
        guard FileManager.default.fileExists(atPath: bundledAgent.path) else { return }
        do {
            try FileManager.default.replaceItem(at: agentPath, with: bundledAgent)
        } catch {
            Log.shared.error(error)
        }
    }

    /// Add a 2nd LC_LOAD_DYLIB pointing at the agent, then re-sign. Used for the .sibling strategy.
    static func installAgentInIPA(_ exec: URL) {
        installAgentOnSystem()
        Inject.injectMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: agentPath.path,
                           finishHandle: { result in
            if result {
                do { try Shell.signApp(exec) } catch { Log.shared.error(error) }
            }
        })
    }

    /// Remove the agent load command (when switching back to embedded), then re-sign.
    static func removeAgentFromApp(_ exec: URL) {
        Inject.removeMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: agentPath.path,
                           finishHandle: { result in
            if result {
                do { try Shell.signApp(exec) } catch { Log.shared.error(error) }
            }
        })
    }

    static func agentInstalledInExec(atURL url: URL) throws -> Bool {
        try execLinksDylib(atURL: url, dylibPath: agentPath.esc)
    }

	static func fetchEntitlements(_ exec: URL) throws -> String {
        do {
            return try Shell.run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", exec.path)
        } catch {
            if error.localizedDescription.contains("Document is empty") {
                // Empty entitlements
                return ""
            } else if error.localizedDescription.contains("code object is not signed at all") {
                // IPA not signed
                return ""
            } else {
                throw error
            }
        }
	}
}
