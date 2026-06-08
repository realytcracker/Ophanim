//
//  HostedAppView.swift
//  Ophanim
//

import SwiftUI
import DataCache

struct HostedAppView: View {
    @Binding var selectedBackgroundColor: Color
    @Binding var selectedTextColor: Color
    @Binding var selected: HostedApp?
    @Binding var isList: Bool

    @StateObject var viewModel: HostedAppVM

    var body: some View {
        HostedAppConditionalView(selectedBackgroundColor: $selectedBackgroundColor,
                               selectedTextColor: $selectedTextColor,
                               selected: $selected,
                               showStartingProgress: $viewModel.showStartingProgress,
                               app: viewModel.app,
                               isList: isList)
            .gesture(TapGesture(count: 2).onEnded {
                // Launch the app from a separate thread (allow us to Sayori it if needed)
                Task(priority: .userInitiated) {
                    if !viewModel.app.isStarting {
                        viewModel.showStartingProgress = true
                        await viewModel.app.launch()
                        viewModel.showStartingProgress = false
                    }
                }
            })
            .simultaneousGesture(TapGesture().onEnded {
                selected = viewModel.app
            })
            .contextMenu {
                Button("hostedapp.settings", systemImage: "gear", action: {
                    viewModel.showSettings.toggle()
                })
                Button("hostedapp.openCache", systemImage: "folder", action: {
                    viewModel.app.openAppCache()
                })
                Button("hostedapp.showInFinder", systemImage: "finder", action: {
                    viewModel.app.showInFinder()
                })
                Divider()
                Group {
                    Button("hostedapp.keymap", systemImage: "keyboard", action: {
                        viewModel.showKeymapSheet.toggle()
                    })
                }
                Divider()
                Group {
                    Button("hostedapp.clearCache", systemImage: "clear", action: {
                        selected = nil
                        Task { await Uninstaller.clearCachePopup(viewModel.app) }
                    })
                    Button("hostedapp.clearPreferences", systemImage: "clear", action: {
                        viewModel.showClearPreferencesAlert.toggle()
                    })
                    Button("hostedapp.clearChainGuard", systemImage: "clear", action: {
                        viewModel.showClearChainGuardAlert.toggle()
                    })
                }
                Divider()
                Button("hostedapp.delete", systemImage: "trash", action: {
                    selected = nil
                    Task { await Uninstaller.uninstallPopup(viewModel.app) }
                })
            }
            .alert("alert.app.preferences", isPresented: $viewModel.showClearPreferencesAlert) {
                Button("button.Proceed", role: .destructive) {
                    deletePreferences(app: viewModel.app.info.bundleIdentifier)
                    viewModel.showClearPreferencesAlert.toggle()
                }
                Button("button.Cancel", role: .cancel) { }
            }
            .alert("alert.app.clearChainGuard", isPresented: $viewModel.showClearChainGuardAlert) {
                Button("button.Proceed", role: .destructive) {
                    viewModel.app.clearChainGuard()
                    viewModel.showClearChainGuardAlert.toggle()
                }
                Button("button.Cancel", role: .cancel) { }
            }
            .sheet(isPresented: $viewModel.showSettings) {
                AppSettingsView(viewModel: AppSettingsVM(app: viewModel.app),
                                showKeymapSheet: $viewModel.showKeymapSheet)
            }
            .sheet(isPresented: $viewModel.showKeymapSheet) {
                KeymapView(showKeymapSheet: $viewModel.showKeymapSheet, viewModel: KeymapViewVM(app: viewModel.app))
            }
    }

    func deletePreferences(app: String) {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingEscapedPathComponent(app)
            .appendingPathComponent("Data")
            .appendingPathComponent("Library")
            .appendingPathComponent("Preferences")
            .appendingEscapedPathComponent(app)
            .appendingPathExtension("plist")

        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }

        do {
            try FileManager.default.removeItem(atPath: plistURL.path)
        } catch {
            Log.shared.log("\(error)", isError: true)
        }
    }
}

struct HostedAppConditionalView: View {
    @Binding var selectedBackgroundColor: Color
    @Binding var selectedTextColor: Color
    @Binding var selected: HostedApp?
    @Binding var showStartingProgress: Bool

    @State var app: HostedApp
    @State var appIcon: NSImage?
    @State var isList: Bool
    @State var hasGalgal: Bool?

    @State private var cache = DataCache.instance

    private var isSelected: Bool { selected?.url == app.url }

    var body: some View {
        Group {
            if isList {
                HStack(alignment: .center, spacing: 0) {
                    Group {
                        if let image = appIcon {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Rectangle()
                                 .fill(.regularMaterial)
                                 .overlay {
                                     ProgressView()
                                         .progressViewStyle(.circular)
                                         .controlSize(.small)
                                 }
                        }
                    }
                    .frame(width: 30, height: 30)
                    .cornerRadius(7.5)
                    .shadow(radius: 1)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 5)

                    Text(app.name)
                        .foregroundColor(isSelected ? Theme.accentBright : Theme.textPrimary)
                    if !(hasGalgal ?? true) {
                        Image(systemName: "exclamationmark.triangle")
                            .padding(.leading, 15)
                            .help("settings.noGalgal")
                    }
                    if showStartingProgress {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 30, height: 30)
                    }
                    Spacer()
                    Text(app.settings.info.bundleVersion)
                        .padding(.horizontal, 15)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Theme.purple.opacity(0.22) : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? Theme.accent.opacity(0.8) : Color.clear, lineWidth: 1))
                    )
            } else {
                LazyVStack {
                    Group {
                        if let image = appIcon {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Rectangle()
                                 .fill(.regularMaterial)
                                 .overlay {
                                     ProgressView()
                                         .progressViewStyle(.circular)
                                 }
                        }
                    }
                    .cornerRadius(15)
                    .shadow(radius: 1)
                    .frame(width: 60, height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
                    )
                    .phosphorGlow(isSelected ? Theme.accent : .clear, radius: isSelected ? 8 : 0)

                    let noGalgalWarning = Text(
                        (hasGalgal ?? true) ? "" : "\(Image(systemName: "exclamationmark.triangle"))  "
                    )
                    HStack {
                        Text("\(noGalgalWarning)\(app.name)")
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .foregroundColor(isSelected ? Theme.accentBright : Theme.textPrimary)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isSelected ? Theme.purple.opacity(0.22) : Color.clear)
                            )
                            .help(!(hasGalgal ?? true) ? "settings.noGalgal" : "")
                            .frame(height: 20)
                        if showStartingProgress {
                            ProgressView()
                                .padding(.leading, 10)
                                .scaleEffect(0.5)
                                .frame(width: 20, height: 20)
                        }
                    }
                }
                .frame(width: 130, height: 130)
            }
        }
        .task(priority: .userInitiated) {
            let compareStr = app.info.bundleIdentifier + app.info.bundleVersion
            if cache.readImage(forKey: app.info.bundleIdentifier) != nil
                && cache.readString(forKey: compareStr) != nil {
                appIcon = cache.readImage(forKey: app.info.bundleIdentifier)
            } else {
                appIcon = Cacher.shared.resolveLocalIcon(app)
            }
        }
        .task(priority: .background) {
            hasGalgal = app.hasGalgal()
            showStartingProgress = app.isStarting
        }
    }
}
