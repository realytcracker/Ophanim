//
//  InstallSettings.swift
//  Ophanim
//
//  Created by TheMoonThatRises on 10/9/22.
//

import SwiftUI

/// Install-flow preferences. The dedicated Install settings tab was removed; these are driven by
/// the install dialog (and sensible defaults). The per-app "Application Type" now lives on each
/// app's Application settings tab instead of a global default.
class InstallPreferences: NSObject, ObservableObject {
    static var shared = InstallPreferences()

    @objc @AppStorage("AlwaysInstallGalgal") var alwaysInstallGalgal = true

    @AppStorage("ShowInstallPopup") var showInstallPopup = false
}
