//
//  InstallSteps.swift
//  Ophanim
//

import Foundation

enum InstallStepsNative: String {
    case unzip = "hostedapp.install.unzip",
         wrapper = "hostedapp.install.createWrapper",
         galgal = "hostedapp.install.installGalgal",
         sign = "hostedapp.install.signing",
         library = "hostedapp.install.addToLib",
         begin = "hostedapp.install.copy",
         finish = "hostedapp.progress.finished",
         failed = "hostedapp.progress.failed"
}

class InstallVM: ProgressVM<InstallStepsNative> {

    static let shared = InstallVM()

    init() {
        super.init(start: .begin, ends: [.finish, .failed])
    }

}
