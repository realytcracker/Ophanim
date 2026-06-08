//
//  AppSettingsView.swift
//  Ophanim
//
//  Created by Isaac Marovitz on 14/08/2022.
//

import SwiftUI
import DataCache

enum BlockingTask {
    case none, galgal, introspection, iosFrameworks, applicationCategoryType
}

// swiftlint:disable file_length
struct AppSettingsView: View {
    @Environment(\.dismiss) var dismiss

    @ObservedObject var viewModel: AppSettingsVM

    @Binding var showKeymapSheet: Bool

    @State var resetSettingsCompletedAlert = false
    @State var closeView = false
    @State var appIcon: NSImage?
    @State var hasGalgal: Bool?
    @State var hasAlias: Bool?

    @State private var currentTask = BlockingTask.none
    @State private var cache = DataCache.instance

    var body: some View {
        VStack {
            HStack {
                Group {
                    if let image = appIcon {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .frame(width: 60, height: 60)
                    }
                }
                .cornerRadius(10)
                .shadow(radius: 1)
                .frame(width: 33, height: 33)

                VStack {
                    HStack {
                        Text(String(
                            format:
                                NSLocalizedString("settings.title", comment: ""),
                            viewModel.app.name))
                            .font(.title2).bold()
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }

                    let noGalgalWarning = Image(systemName: "exclamationmark.triangle")
                    let warning = NSLocalizedString("settings.noGalgal", comment: "")

                    if !(hasGalgal ?? true) {
                        HStack {
                            Text("\(noGalgalWarning) \(warning)")
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                    }
                }
            }
            .task(priority: .userInitiated) {
                appIcon = cache.readImage(forKey: viewModel.app.info.bundleIdentifier)
            }

            TabView {
                GraphicsView(settings: viewModel.settings, app: viewModel.app)
                    .tabItem {
                        Text("settings.tab.graphics")
                    }
                    .disabled(!(hasGalgal ?? true))
                BypassesView(settings: viewModel.settings,
                             hasGalgal: $hasGalgal,
                             task: $currentTask,
                             app: viewModel.app)
                    .tabItem {
                        Text("settings.tab.bypasses")
                    }
                    .disabled(!(hasGalgal ?? true))
                InstrumentationView(settings: viewModel.settings, app: viewModel.app)
                    .tabItem {
                        Text("Hacking")
                    }
                KeymappingView(settings: viewModel.settings)
                    .tabItem {
                        Text("settings.tab.km")
                    }
                    .disabled(!(hasGalgal ?? true))
                InfoView(info: viewModel.app.info, hasGalgal: (hasGalgal ?? true))
                    .tabItem {
                        Text("settings.tab.info")
                    }
            }
            .frame(minWidth: 500, minHeight: 250)
            HStack {
                Button {
                    currentTask = .galgal
                    Task(priority: .userInitiated) {
                        if hasGalgal ?? true {
                            await Galgal.removeFromApp(viewModel.app.executable)
                        } else {
                            do {
                                try await Galgal.installInIPA(viewModel.app.executable)
                            } catch {
                                Log.shared.error(error)
                            }
                        }
                        Task { @MainActor in
                            AppsVM.shared.filteredApps = []
                            AppsVM.shared.fetchApps()
                        }
                        currentTask = .none
                        closeView.toggle()
                    }
                } label: {
                    Text((hasGalgal ?? true) ? "settings.removeGalgal" : "alert.install.injectGalgal")
                        .opacity(currentTask == .galgal ? 0 : 1)
                        .overlay {
                            if currentTask == .galgal { ProgressView().scaleEffect(0.5) }
                        }
                }
                Spacer()
                Button("settings.resetSettings") {
                    resetSettingsCompletedAlert.toggle()
                    viewModel.app.settings.reset()
                    closeView.toggle()
                }
                Button("hostedapp.keymap") {
                    closeView.toggle()
                    showKeymapSheet.toggle()
                }
                Button("button.OK") {
                    closeView.toggle()
                }
                .tint(.accentColor)
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(currentTask != .none)
        .onChange(of: resetSettingsCompletedAlert) { _ in
            ToastVM.shared.showToast(
                toastType: .notice,
                toastDetails: NSLocalizedString("settings.resetSettingsCompleted", comment: ""))
        }
        .onChange(of: closeView) { _ in
            dismiss()
        }
        .task(priority: .background) {
            hasGalgal = viewModel.app.hasGalgal()
            hasAlias = viewModel.app.hasAlias()
        }
        .padding()
        .frame(width: 720, height: 470)
        .ophanimTheme()
        .groupBoxStyle(TerminalGroupBoxStyle())
        .buttonStyle(TerminalButtonStyle())
    }
}

struct KeymappingView: View {
    @ObservedObject var settings: AppSettings
    @AppStorage("settings.settings.keymapping") private var keymapping = false
    @AppStorage("settings.settings.noKMOnInput") private var noKMOnInput = false
    @AppStorage("settings.settings.enableScrollWheel") private var enableScrollWheel = false
    var body: some View {
        ScrollView {
            VStack {
                HStack {
                    Toggle("settings.toggle.km", isOn: $settings.settings.keymapping)
                        .help("settings.toggle.km.help")
                    Spacer()
                    Toggle("settings.toggle.autoKM", isOn: $settings.settings.noKMOnInput)
                        .help("settings.toggle.autoKM.help")
                }
                HStack {
                    Toggle("settings.toggle.enableScrollWheel", isOn: $settings.settings.enableScrollWheel)
                        .help("settings.toggle.enableScrollWheel.help")
                    Spacer()
                }
                HStack {
                    Toggle("settings.toggle.disableBuiltinMouse", isOn: $settings.settings.disableBuiltinMouse)
                        .help("settings.toggle.disableBuiltinMouse.help")
                    Spacer()
                }
                HStack {
                    Text(String(
                        format: NSLocalizedString("settings.slider.mouseSensitivity", comment: ""),
                        settings.settings.sensitivity))
                    Spacer()
                    Slider(value: $settings.settings.sensitivity, in: 0...100, label: { EmptyView() })
                        .frame(width: 250)
                        .disabled(!settings.settings.keymapping)
                        .help("settings.slider.mouseSensitivity.help")
                }
                Spacer()
            }
            .padding()
        }
    }
}

// swiftlint:disable:next type_body_length
struct GraphicsView: View {
    @ObservedObject var settings: AppSettings
    var app: HostedApp
    @State var customWidth = 1920
    @State var customHeight = 1080
    @State var showResolutionWarning = false
    @AppStorage("settings.settings.inverseScreenValues") private var inverseScreenValues = false
    @AppStorage("settings.settings.disableTimeout") private var disableTimeout = false
    @AppStorage("settings.toggle.hideTitleBar") private var hideTitleBar = false
    @AppStorage("settings.toggle.floatingWindow") private var floatingWindow = false
    @AppStorage("settings.settings.displayRotation") private var displayRotation = 0
    static var number: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        return formatter
    }

    @State var customScaler = 2.0
    static var fractionFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 1
        formatter.decimalSeparator = "."
        return formatter
    }

    var body: some View {
        ScrollView {
            VStack {
                HStack {
                    Text("settings.picker.iosDevice")
                    Spacer()
                    Picker("", selection: $settings.settings.iosDeviceModel) {
                        Text("iPad Pro (12.9-inch) (1st gen) | A9X | 4GB").tag("iPad6,7")
                        Text("iPad Pro (12.9-inch) (3rd gen) | A12X | 4GB").tag("iPad8,6")
                        Text("iPad Pro (12.9-inch) (5th gen) | M1 | 8GB").tag("iPad13,8")
                        Text("iPad Pro (12.9-inch) (6th gen) | M2 | 8GB").tag("iPad14,5")
                        Text("iPad Pro (13-inch) (7th gen) | M4 | 8GB").tag("iPad16,6")
                        Divider()
                        Text("iPhone 13 Pro Max | A15 | 6GB").tag("iPhone14,3")
                        Text("iPhone 14 Pro Max | A16 | 6GB").tag("iPhone15,3")
                        Text("iPhone 15 Pro Max | A17 Pro | 8GB").tag("iPhone16,2")
                        Text("iPhone 16 Pro Max | A18 Pro | 8GB").tag("iPhone17,2")
                    }
                    .frame(width: 250)
                    .help("settings.picker.iosDevice.help")
                }
                HStack {
                    if showResolutionWarning {
                        Spacer()
                        let highResIcon = Image(systemName: "exclamationmark.triangle")
                        let warning = NSLocalizedString("settings.highResolution", comment: "")

                        Text("\(highResIcon) \(warning)")
                            .font(.caption)
                    } else {
                        Spacer()
                    }
                }
                HStack {
                    Text("settings.picker.adaptiveRes")
                    Spacer()
                    Picker("", selection: $settings.settings.resolution) {
                        Text("settings.picker.adaptiveRes.0").tag(0)
                        Text("settings.picker.adaptiveRes.1").tag(1)
                        Text("1080p").tag(2)
                        Text("1440p").tag(3)
                        Text("4K").tag(4)
                        Text("settings.picker.adaptiveRes.5").tag(5)
                        Text("settings.picker.adaptiveRes.6").tag(6)
                    }
                    .frame(width: 250, alignment: .leading)
                    .help("settings.picker.adaptiveRes.help")
                }
                HStack {
                    if settings.settings.resolution == 5 {
                        Text(NSLocalizedString("settings.text.customWidth", comment: "") + ":")
                        Stepper {
                            TextField(
                                "settings.text.customWidth",
                                value: $customWidth,
                                formatter: GraphicsView.number,
                                onCommit: {
                                    Task { @MainActor in
                                        NSApp.keyWindow?.makeFirstResponder(nil)
                                    }
                                })
                                .frame(width: 125)
                        }
                        onIncrement: { customWidth += 1 }
                        onDecrement: { customWidth -= 1 }
                        Spacer()
                        Text(NSLocalizedString("settings.text.customHeight", comment: "") + ":")
                        Stepper {
                            TextField(
                                "settings.text.customHeight",
                                value: $customHeight,
                                formatter: GraphicsView.number,
                                onCommit: {
                                    Task { @MainActor in
                                        NSApp.keyWindow?.makeFirstResponder(nil)
                                    }
                                })
                                .frame(width: 125)
                        } onIncrement: {
                            customHeight += 1
                        } onDecrement: {
                            customHeight -= 1
                        }
                    } else if settings.settings.resolution >= 2 && settings.settings.resolution <= 4 {
                        Text("settings.picker.aspectRatio")
                        Spacer()
                        Picker("", selection: $settings.settings.aspectRatio) {
                            Text("4:3").tag(0)
                            Text("16:9").tag(1)
                            Text("16:10").tag(2)
                        }
                        .help("settings.picker.aspectRatio.help")
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                    } else if settings.settings.resolution == 6 {
                        Text("settings.picker.aspectRatio")
                        VStack(alignment: .trailing) {
                            Picker("", selection: $settings.settings.resizableAspectRatioType) {
                                Text("settings.picker.aspectRatio.free").tag(0)
                                Text("settings.picker.aspectRatio.custom").tag(1)
                                Text("4:3").tag(2)
                                Text("16:9").tag(3)
                                Text("16:10").tag(4)
                            }
                            .pickerStyle(.radioGroup)
                            .horizontalRadioGroupLayout()
                            if settings.settings.resizableAspectRatioType == 1 {
                                HStack {
                                    TextField("", value: $settings.settings.resizableAspectRatioWidth,
                                              formatter: GraphicsView.number)
                                    .frame(width: 110)
                                    Text(":")
                                    TextField("", value: $settings.settings.resizableAspectRatioHeight,
                                              formatter: GraphicsView.number)
                                    .frame(width: 110)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    } else if settings.settings.resolution == 1 {
                        let width = Int(NSScreen.main?.frame.width ?? 1920)
                        let height = getHeightForNotch(width, Int(NSScreen.main?.frame.height ?? 1080))
                        Text("settings.text.detectedResolution")
                        Spacer()
                        Text("\(width) x \(height)")
                    } else {
                        Spacer()
                    }
                }
                HStack {
                    Text("settings.picker.scaler")
                        .help("settings.picker.scaler.help")
                    Spacer()
                    Stepper {
                        TextField(
                            "settings.text.scaler",
                            value: $customScaler,
                            formatter: GraphicsView.fractionFormatter,
                            onCommit: {
                                Task { @MainActor in NSApp.keyWindow?.makeFirstResponder(nil) }
                            })
                            .frame(width: 125)
                    } onIncrement: {
                        customScaler += 0.1
                    } onDecrement: {
                        if customScaler > 0.5 { customScaler -= 0.1 }
                    }
                }
                VStack(alignment: .leading) {
                    if #available(macOS 13.2, *) {
                        HStack {
                            Toggle("settings.picker.windowFix", isOn: $settings.settings.inverseScreenValues)
                                .help("settings.picker.windowFix.help")
                                .onChange(of: settings.settings.inverseScreenValues) { _ in
                                    settings.settings.windowFixMethod = 0
                                }
                            Spacer()
                            // Dropdown to choose fix method
                            Picker("", selection: $settings.settings.windowFixMethod) {
                                Text("settings.picker.windowFixMethod.0").tag(0)
                                Text("settings.picker.windowFixMethod.1").tag(1)
                            }
                            .frame(alignment: .leading)
                            .help("settings.picker.windowFixMethod.help")
                            .disabled(!settings.settings.inverseScreenValues)
                        }
                        Spacer()
                    }
                    HStack {
                        Text("settings.settings.displayRotation")
                        Spacer()
                        Picker("", selection: $settings.settings.displayRotation) {
                            Text("settings.settings.displayRotation.default").tag(0)
                            Text("settings.settings.displayRotation.portrait").tag(1)
                            Text("settings.settings.displayRotation.landscapeRight").tag(2)
                            Text("settings.settings.displayRotation.portraitUpsideDown").tag(3)
                            Text("settings.settings.displayRotation.flipFix").tag(4)
                        }
                        .frame(alignment: .leading)
                        .help("settings.settings.displayRotation.help")
                    }
                    Spacer()
                    Toggle("settings.toggle.floatingWindow", isOn: $settings.settings.floatingWindow)
                        .help("settings.toggle.floatingWindow.help")
                    Spacer()
                    Toggle("settings.toggle.disableDisplaySleep", isOn: $settings.settings.disableTimeout)
                        .help("settings.toggle.disableDisplaySleep.help")
                    Spacer()
                    Toggle("settings.toggle.hideTitleBar", isOn: $settings.settings.hideTitleBar)
                        .help("settings.toggle.hideTitleBar.help")
                    Spacer()
                    if #available(macOS 13.0, *) {
                        Toggle("settings.toggle.hud", isOn: $settings.settings.metalHUD)
                            .help("Show Apple's Metal performance HUD (FPS/GPU) overlay for this app.")
                        Spacer()
                    }
                }
                Spacer()
            }
            .padding()
            .onAppear {
                customWidth = settings.settings.windowWidth
                customHeight = settings.settings.windowHeight
                customScaler = settings.settings.customScaler
            }
            .onChange(of: settings.settings.resolution) { _ in
                setResolution()
            }
            .onChange(of: settings.settings.aspectRatio) { _ in
                setResolution()
            }
            .onChange(of: customWidth) { _ in
                setResolution()
            }
            .onChange(of: customHeight) { _ in
                setResolution()
            }
            .onChange(of: customScaler) { _ in
                setResolution()
            }
            .onChange(of: settings.settings.resizableAspectRatioType) { _ in
                setAspectRatioForResizableWindow()
            }
        }
    }

    func setResolution() {
        var width: Int
        var height: Int

        switch settings.settings.resolution {
        // Adaptive resolution = Auto
        case 1:
            width = Int(NSScreen.main?.frame.width ?? 1920)
            height = getHeightForNotch(width, Int(NSScreen.main?.frame.height ?? 1080))
        // Adaptive resolution = 1080p
        case 2:
            height = 1080
            width = getWidthFromAspectRatio(height)
        // Adaptive resolution = 1440p
        case 3:
            height = 1440
            width = getWidthFromAspectRatio(height)
        // Adaptive resolution = 4K
        case 4:
            height = 2160
            width = getWidthFromAspectRatio(height)
        // Adaptive resolution = Custom
        case 5:
            width = customWidth
            height = customHeight
        // Adaptive resolution = Off
        default:
            height = 1080
            width = 1920
        }

        settings.settings.windowWidth = width
        settings.settings.windowHeight = height
        settings.settings.customScaler = customScaler

        showResolutionWarning = Double(width * height) * customScaler >= 2621440 * 2.0
        // Tends to crash when the number of pixels exceeds that
    }

    func getWidthFromAspectRatio(_ height: Int) -> Int {
        var widthRatio: Int
        var heightRatio: Int

        switch settings.settings.aspectRatio {
        case 0:
            widthRatio = 4
            heightRatio = 3
        case 1:
            widthRatio = 16
            heightRatio = 9
        case 2:
            widthRatio = 16
            heightRatio = 10
        default:
            widthRatio = 16
            heightRatio = 9
        }
        return (height / heightRatio) * widthRatio
    }
    func getHeightForNotch(_ width: Int, _ height: Int) -> Int {
        let wFloat = Float(width)
        let hFloat = Float(height)
        if NSScreen.hasNotch() && (hFloat/wFloat)*16.0 > 10.3 && (hFloat/wFloat)*16.0 < 10.4 {
            return Int((wFloat / 16) * 10)
        } else {
            return Int(height)
        }
    }

    func setAspectRatioForResizableWindow() {
        var widthRatio = 0
        var heightRatio = 0

        switch settings.settings.resizableAspectRatioType {
        // Aspect ratio = Free
        case 0:
            widthRatio = 0
            heightRatio = 0
        // Aspect ratio = Custom
        case 1:
            widthRatio = settings.settings.resizableAspectRatioWidth
            heightRatio = settings.settings.resizableAspectRatioHeight
        // Aspect ratio = 4:3
        case 2:
            widthRatio = 4
            heightRatio = 3
        // Aspect ratio = 16:9
        case 3:
            widthRatio = 16
            heightRatio = 9
        // Aspect ratio = 16:10
        case 4:
            widthRatio = 16
            heightRatio = 10
        default:
            widthRatio = 16
            heightRatio = 9
        }

        settings.settings.resizableAspectRatioWidth = widthRatio
        settings.settings.resizableAspectRatioHeight = heightRatio
    }
}

struct BypassesView: View {
    @ObservedObject var settings: AppSettings
    @Binding var hasGalgal: Bool?
    @Binding var task: BlockingTask
    @AppStorage("settings.settings.chainGuard") private var chainGuard = false
    @AppStorage("settings.settings.chainGuardDebugging") private var chainGuardDebugging = false
    @AppStorage("settings.settings.bypass") private var bypass = false
    @State private var hasIntrospection: Bool
    @State private var hasIosFrameworks: Bool
    @State private var appCategory: LSApplicationCategoryType = .none
    @State private var signingCategory = false

    var app: HostedApp

    init(settings: AppSettings,
         hasGalgal: Binding<Bool?>,
         task: Binding<BlockingTask>,
         app: HostedApp) {
        self._settings = ObservedObject(wrappedValue: settings)
        self._hasGalgal = hasGalgal
        self._task = task
        self.app = app

        let lsEnvironment = app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? ""
        self.hasIntrospection = lsEnvironment.contains(HostedApp.introspection)
        self.hasIosFrameworks = lsEnvironment.contains(HostedApp.iosFrameworks)
    }

    private let jbCols = [GridItem(.flexible(), alignment: .leading),
                          GridItem(.flexible(), alignment: .leading)]

    /// Toggle binding for a single jailbreak detector (by ObjC class id) in the allowlist.
    private func jbBind(_ id: String) -> Binding<Bool> {
        Binding(get: { settings.settings.jailbreakBypasses.contains(id) },
                set: { on in
                    var set = settings.settings.jailbreakBypasses
                    if on {
                        if !set.contains(id) { set.append(id) }
                    } else {
                        set.removeAll { $0 == id }
                    }
                    settings.settings.jailbreakBypasses = set
                })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Application Type") {
                    HStack {
                        Text("settings.applicationCategoryType")
                        if signingCategory {
                            ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                        }
                        Spacer()
                        Picker("", selection: $appCategory) {
                            ForEach([.none] + LSApplicationCategoryType.allCases.filter { $0 != .none },
                                    id: \.rawValue) { value in
                                Text(value.localizedName).tag(value)
                            }
                        }
                        .frame(width: 250)
                        .help("settings.applicationCategoryType.help")
                        .onChange(of: appCategory) { _ in
                            signingCategory = true
                            app.info.applicationCategoryType = appCategory
                            Task.detached {
                                do {
                                    try await Shell.signApp(app.executable)
                                } catch {
                                    Log.shared.error(error)
                                }
                                Task { @MainActor in signingCategory = false }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Jailbreak / Root Detection") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Bypass each SDK's detector individually (\(settings.settings.jailbreakBypasses.count)/\(JBBypassCatalog.all.count))")
                                .font(Theme.caption).foregroundColor(Theme.textSecondary)
                            Spacer()
                            Button("Select All") {
                                settings.settings.jailbreakBypasses = JBBypassCatalog.allIDs
                            }
                            Button("None") {
                                settings.settings.jailbreakBypasses = []
                            }
                        }
                        LazyVGrid(columns: jbCols, alignment: .leading, spacing: 2) {
                            ForEach(JBBypassCatalog.all, id: \.id) { entry in
                                Toggle(entry.label, isOn: jbBind(entry.id))
                                    .help(entry.id)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Keychain Emulation (ChainGuard)") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("settings.chainGuard.enable", isOn: $settings.settings.chainGuard)
                            .help("settings.chainGuard.help")
                            .disabled(!(hasGalgal ?? true))
                        Toggle("settings.chainGuard.debugging", isOn: $settings.settings.chainGuardDebugging)
                            .disabled(!settings.settings.chainGuard)
                            .help("settings.chainGuard.debugging.help")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("TLS / Certificate Pinning") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Bypass certificate pinning (force-accept)",
                               isOn: $settings.settings.ophanim.bypassPinning)
                            .disabled(!(hasGalgal ?? true))
                            .help("Forces SecTrust evaluation to succeed so app-level pinning "
                                  + "(TrustKit / AFNetworking / Alamofire / custom URLSession validators) "
                                  + "can't reject the chain. Does not reach pinning inside a "
                                  + "statically-linked TLS stack (e.g. Cronet).")
                        Text("Hooks SecTrustEvaluateWithError - covers SecTrust-based pinning (most apps), "
                             + "not in-process TLS stacks like Cronet. Pinning checks are logged under the "
                             + "Network capture category.")
                            .font(Theme.caption).foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Injected Libraries") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("settings.toggle.introspection", isOn: $hasIntrospection)
                            .help("settings.toggle.introspection.help")
                            .toggleStyle(.async($task, role: .introspection))
                        Toggle("settings.toggle.iosFrameworks", isOn: $hasIosFrameworks)
                            .help("settings.toggle.iosFrameworks.help")
                            .toggleStyle(.async($task, role: .iosFrameworks))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Compatibility") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("settings.toggle.rootWorkDir", isOn: $settings.settings.rootWorkDir)
                            .disabled(!(hasGalgal ?? true))
                            .help("settings.toggle.rootWorkDir.help")
                        Toggle("settings.toggle.limitMotionUpdateFrequency",
                               isOn: $settings.settings.limitMotionUpdateFrequency)
                            .disabled(!(hasGalgal ?? true))
                            .help("settings.toggle.limitMotionUpdateFrequency.help")
                        Toggle("settings.toggle.blockSleepSpamming", isOn: $settings.settings.blockSleepSpamming)
                            .help("settings.toggle.blockSleepSpamming.help")
                        Toggle("settings.toggle.checkMicPermissionSync", isOn: $settings.settings.checkMicPermissionSync)
                            .help("settings.toggle.checkMicPermissionSync.help")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .onAppear { appCategory = app.info.applicationCategoryType }
        .onChange(of: hasIntrospection) {_ in
            task = .introspection
            Task {
                _ = await app.changeDyldLibraryPath(set: hasIntrospection, path: HostedApp.introspection)
                task = .none
            }
        }
        .onChange(of: hasIosFrameworks) {_ in
            task = .iosFrameworks
            Task {
                _ = await app.changeDyldLibraryPath(set: hasIosFrameworks, path: HostedApp.iosFrameworks)
                task = .none
            }
        }
    }
}

struct InfoView: View {
    @State var info: AppInfo
    @State var hasGalgal: Bool

    var body: some View {
        List {
            HStack {
                Text("settings.info.displayName")
                Spacer()
                Text("\(info.displayName)")
            }
            HStack {
                Text("settings.info.bundleName")
                Spacer()
                Text("\(info.bundleName)")
            }
            HStack {
                Text("settings.info.bundleIdentifier")
                Spacer()
                Text("\(info.bundleIdentifier)")
            }
            HStack {
                Text("settings.info.bundleVersion")
                Spacer()
                Text("\(info.bundleVersion)")
            }
            HStack {
                Text("settings.applicationCategoryType") + Text(":")
                Spacer()
                Text("\(info.applicationCategoryType.rawValue)")
            }
            HStack {
                Text("settings.info.executableName")
                Spacer()
                Text("\(info.executableName)")
            }
            HStack {
                Text("settings.info.minimumOSVersion")
                Spacer()
                Text("\(info.minimumOSVersion)")
            }
            HStack {
                Text("settings.info.galgal")
                Spacer()
                Text(hasGalgal ? "button.Yes" : "button.No")
            }
            HStack {
                Text("settings.info.url")
                Spacer()
                Text("\(info.url.relativePath)")
            }
            HStack {
                Text("settings.info.alias")
                Spacer()
                Text("\(HostedApp.aliasDirectory.appendingPathComponent(info.bundleIdentifier))")
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .padding()
    }
}

struct AsyncToggleStyle: ToggleStyle {
    @Binding var task: BlockingTask

    var role: BlockingTask

    func makeBody(configuration: Configuration) -> some View {
        if task == role {
            return AnyView(
                HStack(spacing: 3) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)

                    configuration.label
                }
            )
        } else {
            return AnyView(
                Toggle(isOn: configuration.$isOn) { configuration.label }
            )
        }
    }
}

extension ToggleStyle where Self == AsyncToggleStyle {
    static func async(_ task: Binding<BlockingTask>, role: BlockingTask) -> AsyncToggleStyle {
        AsyncToggleStyle(task: task, role: role)
    }
}

/// Catalog of per-SDK jailbreak/root detectors that Galgal's GalgalShadow can bypass. The `id` is
/// the ObjC class name GalgalShadow swizzles (the runtime gates each on whether its id is in the
/// per-app allowlist `settings.jailbreakBypasses`); `label` is a human hint shown in the editor.
/// Keep ids in sync with the `[GalgalShadowLoader jb:@"…"]` gates in GalgalShadow.m.
enum JBBypassCatalog {
    static let all: [(id: String, label: String)] = [
        ("UIDevice", "UIDevice (generic + device info)"),
        ("RNDeviceInfo", "React Native DeviceInfo"),
        ("JailbreakDetection", "JailbreakDetection"),
        ("JailbreakDetectionVC", "JailbreakDetectionVC"),
        ("DTTJailbreakDetection", "DTTJailbreakDetection"),
        ("jailBreak", "jailBreak"),
        ("jailBrokenJudge", "jailBrokenJudge (Cydia/path/file)"),
        ("ANSMetadata", "ANSMetadata (Akamai)"),
        ("AppsFlyerUtils", "AppsFlyer"),
        ("OneSignalJailbreakDetection", "OneSignal"),
        ("ADYSecurityChecks", "Adyen"),
        ("GemaltoConfiguration", "Gemalto / Thales"),
        ("DigiPassHandler", "OneSpan DigiPass"),
        ("v_VDMap", "Verimatrix VOS (debugger/tamper too)"),
        ("TNGDeviceTool", "TNG (Cydia/file/env)"),
        ("KSSystemInfo", "Kochava"),
        ("GBDeviceInfo", "GBDeviceInfo"),
        ("FBAdBotDetector", "Facebook Ad Bot Detector"),
        ("SDMUtils", "SDMUtils"),
        ("UtilitySystem", "UtilitySystem"),
        ("CMARAppRestrictionsDelegate", "CMARAppRestrictionsDelegate"),
        ("UBReportMetadataDevice", "Urban Airship"),
        ("CPWRDeviceInfo", "CPWRDeviceInfo"),
        ("CPWRSessionInfo", "CPWRSessionInfo"),
        ("EMDSKPPConfiguration", "Entrust EMDSKPP"),
        ("EnrollParameters", "EnrollParameters"),
        ("EMDskppConfigurationBuilder", "Entrust EMDskppConfigurationBuilder"),
        ("FCRSystemMetadata", "FCRSystemMetadata"),
        ("DTXSessionInfo", "DTXSessionInfo"),
        ("DTXDeviceInfo", "DTXDeviceInfo"),
        ("DTDeviceInfo", "DTDeviceInfo"),
        ("SecVIDeviceUtil", "SecVIDeviceUtil"),
        ("RVPBridgeExtension4Jailbroken", "RVPBridgeExtension4Jailbroken"),
        ("ZDetection", "Zimperium zDetection"),
        ("AWMyDeviceGeneralInfo", "AirWatch / Workspace ONE"),
    ]
    static var allIDs: [String] { all.map(\.id) }
}
