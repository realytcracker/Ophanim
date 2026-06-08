//
//  FileExtensions.swift
//  Ophanim
//

import Foundation
import UniformTypeIdentifiers

extension FileManager {
    func delete(at url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(atPath: url.path)
            } catch {
                Log.shared.error(error)
            }
        }
    }

    /// Remove any existing item at `destination`, then copy `source` there. Collapses the common
    /// "exists? → remove → copy" dance used across install/inject.
    func replaceItem(at destination: URL, with source: URL) throws {
        if fileExists(atPath: destination.path) {
            try removeItem(at: destination)
        }
        try copyItem(at: source, to: destination)
    }
}

extension NSOpenPanel {
    static func selectIPA(completion: @escaping (_ result: Result<URL, Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(importedAs: "com.apple.itunes.ipa")]
        panel.canChooseFiles = true
        panel.begin { result in
            if result == .OK {
                if let url = panel.urls.first {
                    completion(.success(url))
                }
            }
        }
    }
}
