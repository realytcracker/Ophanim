//
//  AppSettingsVM.swift
//  Ophanim
//
//  Created by 이승윤 on 2022/08/15.
//

import Foundation

class AppSettingsVM: ObservableObject {
    let app: HostedApp
    @Published var settings: AppSettings

    init(app: HostedApp) {
        self.app = app
        settings = app.settings
    }
}
