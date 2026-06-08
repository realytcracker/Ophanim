//
//  HostedAppVM.swift
//  Ophanim
//
//  Created by Adam Chen JingFan on 4/7/24.
//

import SwiftUI

class HostedAppVM: ObservableObject {
    @Published var app: HostedApp
    @Published var showSettings = false
    @Published var showClearPreferencesAlert = false
    @Published var showClearChainGuardAlert = false
    @Published var showStartingProgress = false
    @Published var showImportSuccess = false
    @Published var showImportFail = false
    @Published var showKeymapSheet = false

    init(app: HostedApp) {
        self.app = app
    }
}
