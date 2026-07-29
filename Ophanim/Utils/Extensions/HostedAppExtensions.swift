//
//  HostedAppExtensions.swift
//  Ophanim
//
//  Created by TheMoonThatRises on 10/2/23.
//

import Foundation

extension HostedApp {
    func createAlias() {
        do {
            try FileManager.default.createDirectory(atPath: aliasURL.path,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
            url.enumerateContents(options: [.skipsSubdirectoryDescendants]) { ctxUrl, _ in
                try FileManager.default.createSymbolicLink(
                    at: self.aliasURL.appendingPathComponent(ctxUrl.lastPathComponent),
                    withDestinationURL: ctxUrl)
            }
        } catch {
            Log.shared.log(error.localizedDescription)
        }
    }

    func removeAlias() {
        FileManager.default.delete(at: aliasURL)
    }
}
