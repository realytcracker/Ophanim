//
//  URIHandler.swift
//  Ophanim
//
//  Created by Venti on 14/02/2023.
//

import Foundation

enum URLTypes: Int, Equatable {
    case keymap
    case app
}

enum URLAction: Int, Equatable {
    case add
    case remove
    case update
    case install
    case open
}

class URLObservable: ObservableObject {
    @Published var url: String?
    @Published var type: URLTypes?
    @Published var action: URLAction?

    public static var shared = URLObservable()
}

struct URLHandler {
    public static var shared = URLHandler()

    func processURL(url: URL) {
        guard let urlComponenents = NSURLComponents(url: url, resolvingAgainstBaseURL: false),
              let uriHost = urlComponenents.host,
              let params = urlComponenents.queryItems else {
                // Fall back to old url handler (for files)
                if url.pathExtension == "ipa" {
                    Installer.install(ipaUrl: url, export: false, returnCompletion: { _ in
                    Task { @MainActor in
                        AppsVM.shared.fetchApps()
                        NotifyService.shared.notify(
                            NSLocalizedString("notification.appInstalled", comment: ""),
                            NSLocalizedString("notification.appInstalled.message", comment: "")
                        )
                    }})
                }
                return
            }
        // URI format: ophanimapp://<object>?action=<action>&<param>=<value>
        // No custom URI objects are handled at present; non-ipa URLs are logged and ignored.
        _ = params
        NSLog("Unknown URL: \(url)")
    }
}
