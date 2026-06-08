//
//  MenuBarView.swift
//  Ophanim
//

import AppKit
import SwiftUI
import DataCache

struct OphanimMenuView: Commands {
    @Binding var isSigningSetupShown: Bool
    var body: some Commands {
        CommandGroup(after: .systemServices) {
            Button("menubar.log.copy", systemImage: "document.on.document.fill") {
                Log.shared.logdata.copyToClipBoard()
            }
            .keyboardShortcut("L", modifiers: [.command, .option])
            Button("menubar.configSigning", systemImage: "signature") {
                isSigningSetupShown = true
            }
        }
    }
}

struct OphanimHelpMenuView: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("menubar.documentation", systemImage: "document.fill") {
                if let url = URL(string: "https://docs.ophanim.io") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button("menubar.website", systemImage: "network") {
                if let url = URL(string: "https://ophanim.io") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("menubar.github", systemImage: "arrow.up.right") {
                if let url = URL(string: "https://github.com/Ophanim/Ophanim/") {
                    NSWorkspace.shared.open(url)
                }
            }
            #if DEBUG
            Divider()
            Button("[DEBUG] Crash app", systemImage: "xmark.circle.fill") {
                fatalError("Crash was triggered")
            }
            #endif
        }
    }
}

struct OphanimViewMenuView: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(before: .sidebar) {
            Button("menubar.clearCache", systemImage: "eraser.fill") {
                DataCache.instance.cleanAll()
                Cacher.shared.removeImageCache()

                if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                   let bundleID = Bundle.main.bundleIdentifier {
                    FileManager.default.delete(at: cacheDir.appendingPathComponent(bundleID)
                        .appendingPathComponent("Image Cache"))
                }
            }
            .keyboardShortcut("R", modifiers: [.command, .shift])
            Divider()
        }
    }
}
