//
//  AppViewModel.swift
//  Ophanim
//

import Foundation

class AppsVM: ObservableObject {

    public static let appDirectory = Galgal.ophanimContainer.appendingPathComponent("Applications")

    static let shared = AppsVM()

    private init() {
        try? AppsVM.ensureBaseDirectoriesExist()
        // Migration: hosted apps now launch from within Ophanim, so remove the legacy
        // ~/Applications/Ophanim alias folder if a previous version created one.
        FileManager.default.delete(at: HostedApp.aliasDirectory)
        Galgal.installOnSystem()
        fetchApps()
    }

    static func ensureBaseDirectoriesExist() throws {
        try FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )
    }

    @Published var filteredApps: [HostedApp] = []
    @Published var apps: [HostedApp] = []
    @Published var searchText: String = ""
    @Published var updatingApps = true

    func fetchApps() {
        Task { @MainActor in
            updatingApps = true

            filteredApps.removeAll()
            apps.removeAll()

            do {
                let directoryContents = try FileManager.default
                    .contentsOfDirectory(at: AppsVM.appDirectory, includingPropertiesForKeys: nil, options: [])

                let subdirs = directoryContents.filter { $0.hasDirectoryPath }

                for sub in subdirs {
                    if sub.pathExtension.contains("app") &&
                        FileManager.default.fileExists(atPath: sub.appendingPathComponent("Info")
                                                                  .appendingPathExtension("plist")
                                                                  .path) {
                        let app = HostedApp(appUrl: sub)
                        print("Application installed under:", sub.path)

                        apps.append(app)
                        if searchText.isEmpty || app.searchText.contains(searchText.lowercased()) {
                            filteredApps.append(app)
                        }
                    }
                }
            } catch {
                print(error)
            }

            filteredApps.sort(by: { $0.name.lowercased() < $1.name.lowercased() })

            do {
                if !FileManager.default.fileExists(atPath: HostedApp.bundleIDCacheURL.path),
                   let firstBundleID = apps.first?.info.bundleIdentifier {
                    try "\(firstBundleID)\n"
                        .write(to: HostedApp.bundleIDCacheURL, atomically: false, encoding: .utf8)
                }

                for bundleId in apps.map({ $0.info.bundleIdentifier })
                    where !(try HostedApp.bundleIDCache).contains(bundleId) {
                    if let bundleID = "\(bundleId)\n".data(using: .utf8) {
                        let cacheFile = try FileHandle(forUpdating: HostedApp.bundleIDCacheURL)
                        try cacheFile.seekToEnd()
                        try cacheFile.write(contentsOf: bundleID)
                        try cacheFile.close()
                    }
                }
            } catch {
                Log.shared.error(error)
            }

            updatingApps = false
        }
    }
}
