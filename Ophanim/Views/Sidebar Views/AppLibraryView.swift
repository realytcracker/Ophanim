//
//  AppLibraryView.swift
//  Ophanim
//

import SwiftUI

struct AppLibraryView: View {
    @EnvironmentObject var appsVM: AppsVM
    @EnvironmentObject var installVM: InstallVM

    @Binding var selectedBackgroundColor: Color
    @Binding var selectedTextColor: Color

    @State private var gridLayout = [GridItem(.adaptive(minimum: 130, maximum: .infinity))]
    @State private var searchString = ""
    @State private var isList = UserDefaults.standard.bool(forKey: "AppLibraryView")
    @State private var selected: HostedApp?
    @State private var showSettings = false
    @State private var showLegacyConvertAlert = false
    @State private var showWrongfileTypeAlert = false
    @State var showKeymapSheet = false

    var body: some View {
        ZStack {
            // Always-on, subtle digital-rain backdrop (honors the fx toggle). The grid/empty content
            // sits on top; cells are transparent so the rain shows between them.
            DigitalRainView()
                .opacity(0.18)
                .allowsHitTesting(false)
            Group {
            if !appsVM.apps.isEmpty || appsVM.updatingApps {
                ScrollView {
                    AppDisplayView(apps: appsVM.filteredApps,
                                      selectedBackgroundColor: $selectedBackgroundColor,
                                      selectedTextColor: $selectedTextColor,
                                      selected: $selected,
                                      isList: $isList,
                                      gridLayout: gridLayout)
                }
                .onTapGesture {
                    selected = nil
                }
            } else {
                ZStack {
                    DigitalRainView()
                        .opacity(0.5)
                    VStack(spacing: 6) {
                        Text("hostedapp.noSources.title")
                            .font(Theme.mono(22, .bold))
                            .foregroundColor(Theme.accentBright)
                            .phosphorGlow(Theme.purple, radius: 6)
                            .padding(.bottom, 2)
                        Text("hostedapp.noSources.subtitle")
                            .font(Theme.body)
                            .foregroundColor(Theme.textSecondary)
                        Button("hostedapp.importIPA") {
                            if installVM.inProgress {
                                Log.shared.error(OphanimError.waitInstallation)
                            } else {
                                selectFile()
                            }
                        }
                        .buttonStyle(TerminalButtonStyle())
                        .padding(.top, 6)
                    }
                    .padding(24)
                    .background(Theme.bg.opacity(0.55).blur(radius: 8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        }
        .navigationTitle("sidebar.appLibrary")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if installVM.inProgress {
                        Log.shared.error(OphanimError.waitInstallation)
                    } else {
                        selectFile()
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .help("hostedapp.add")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Spacer()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gear")
                }
                .disabled(selected == nil)
                .help("Settings for the selected app (hacking, injection, keymapping)")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Grid View Layout", selection: $isList) {
                    Image(systemName: "square.grid.2x2")
                        .tag(false)
                    Image(systemName: "list.bullet")
                        .tag(true)
                }.pickerStyle(.segmented)
                .help("Switch between grid and list layout")
            }
        }
        .searchable(text: $searchString, placement: .toolbar)
        .onChange(of: searchString, perform: { value in
            appsVM.searchText = value
            appsVM.fetchApps()
        })
        .onAppear {
            appsVM.searchText = ""
            appsVM.fetchApps()
        }
        .onChange(of: isList, perform: { value in
            UserDefaults.standard.set(value, forKey: "AppLibraryView")
        })
        .sheet(isPresented: $showSettings) {
            if let selected = selected {
                AppSettingsView(viewModel: AppSettingsVM(app: selected), showKeymapSheet: $showKeymapSheet)
            }
        }
        .sheet(isPresented: $showKeymapSheet) {
            if let selected = selected {
                KeymapView(showKeymapSheet: $showKeymapSheet, viewModel: KeymapViewVM(app: selected))
            }
        }
        .onAppear {
            showLegacyConvertAlert = LegacySettings.doesMonolithExist
        }
        .onDrop(of: ["public.url", "public.file-url"], isTargeted: nil) { (items) -> Bool in
            if installVM.inProgress {
                Log.shared.error(OphanimError.waitInstallation)
                return false
            } else if let item = items.first {
                if let identifier = item.registeredTypeIdentifiers.first {
                    if identifier == "public.url" || identifier == "public.file-url" {
                        item.loadItem(forTypeIdentifier: identifier, options: nil) { (urlData, _) in
                            Task { @MainActor in
                                if let urlData = urlData as? Data {
                                    let url = NSURL(absoluteURLWithDataRepresentation: urlData, relativeTo: nil) as URL
                                    if url.pathExtension == "ipa" {
                                        installApp(url)
                                    } else {
                                        showWrongfileTypeAlert = true
                                    }
                                }
                            }
                        }
                    }
                }
                return true
            } else {
                return false
            }
        }
        .alert(isPresented: $showWrongfileTypeAlert) {
            Alert(title: Text("alert.wrongFileType.title"),
                  message: Text("alert.wrongFileType.subtitle"), dismissButton: .default(Text("button.OK")))
        }
        .alert("Legacy App Settings Detected!", isPresented: $showLegacyConvertAlert, actions: {
            Button("button.Convert", role: .destructive) {
                LegacySettings.convertLegacyMonolithPlist(LegacySettings.monolithURL)
                do {
                    try FileManager.default.removeItem(at: LegacySettings.monolithURL)
                } catch {
                    Log.shared.error(error)
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("button.Cancel", role: .cancel) {
                showLegacyConvertAlert.toggle()
            }
        }, message: {
            Text("alert.legacyImport.subtitle")
        })
    }

    private func installApp(_ url: URL) {
        Installer.install(ipaUrl: url, export: false, returnCompletion: { _ in
            Task { @MainActor in
                appsVM.fetchApps()
                NotifyService.shared.notify(
                    NSLocalizedString("notification.appInstalled", comment: ""),
                    NSLocalizedString("notification.appInstalled.message", comment: ""))
            }
        })
    }

    private func selectFile() {
        NSOpenPanel.selectIPA { result in
            if case .success(let url) = result {
                installApp(url)
            }
        }
    }
}

struct AppDisplayView: View {
    var apps: [HostedApp]
    @Binding var selectedBackgroundColor: Color
    @Binding var selectedTextColor: Color
    @Binding var selected: HostedApp?
    @Binding var isList: Bool

    // Implementation of ViewModels to preserve
    // UI states between list & grid view.
    @State private var viewModels: [String: HostedAppVM] = [:]

    var gridLayout: [GridItem]
    var hostedAppViews: some View {
        ForEach(apps, id: \.url) { app in
            let viewModel = viewModels[app.url.absoluteString, default: HostedAppVM(app: app)]
            HostedAppView(selectedBackgroundColor: $selectedBackgroundColor,
                        selectedTextColor: $selectedTextColor,
                        selected: $selected,
                        isList: $isList,
                        viewModel: viewModel)
                .onAppear {
                    viewModels[app.url.absoluteString] = viewModel
                }
        }
    }

    var body: some View {
        if isList {
            VStack {
                hostedAppViews
                Spacer()
            }
            .padding()
        } else {
            LazyVGrid(columns: gridLayout, alignment: .center) {
                hostedAppViews
            }
            .padding()
        }
    }
}
