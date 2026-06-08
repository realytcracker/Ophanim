//
//  GalgalInformation.swift
//  Galgal
//

import Foundation

class GalgalInfo: NSObject {
    static var isLauncherInstalled: Bool {
        return GalgalInterface.shared!
            .urlForApplicationWithBundleIdentifier("be.ophanim.Ophanim") != nil
    }

    @objc static var isUnrealEngine: Bool {
        let appFolder = Bundle.main.bundleURL
        let ueFiles: [URL] = [
            appFolder.appendingPathComponent("ue4commandline.txt"),
            appFolder.appendingPathComponent("uecommandline.txt")
        ]

        for ueFile in ueFiles where FileManager.default.fileExists(atPath: ueFile.path) {
            return true
        }
        return false
    }
}

extension ProcessInfo {
    @objc open var isMacCatalystApp: Bool {
        return false
    }
    @objc open var isiOSAppOnMac: Bool {
        return true
    }
    @objc open var thermalState: ProcessInfo.ThermalState {
        return ProcessInfo.ThermalState.nominal
    }
    @objc open var isLowPowerModeEnabled: Bool {
        return false
    }
}
