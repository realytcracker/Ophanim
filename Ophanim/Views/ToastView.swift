//
//  ToastView.swift
//  Ophanim
//
//  Created by Isaac Marovitz on 07/08/2022.
//

import SwiftUI

struct ToastView: View {
    public static let toastGlassPadding: CGFloat = 8

    @EnvironmentObject var toastVM: ToastVM
    @EnvironmentObject var installVM: InstallVM

    var body: some View {
        if toastVM.isShown {
            VStack(spacing: -20) {
                // remove spacing for liquid glass toast to prevent the background blur that accompanies the toast when
                // scrolling down in either of the library views
                #if compiler(>=6.2)
                if #unavailable(macOS 26.0) {
                    Spacer()
                }
                #else
                Spacer()
                #endif
                ForEach(toastVM.toasts, id: \.self) { toast in
                    HStack {
                        switch toast.toastType {
                        case .notice:
                            Image(systemName: "info.circle").foregroundColor(Theme.accent)
                        case .error:
                            Image(systemName: "exclamationmark.triangle").foregroundColor(Theme.danger)
                        case .network:
                            Image(systemName: "info.circle").foregroundColor(Theme.purple)
                        }
                        Text(toast.toastDetails).foregroundColor(Theme.textPrimary)
                    }
                    .toastBackground()
                    .onAppear {
                        Task { @MainActor in
                            try await Task.sleep(nanoseconds: toast.timeRemaining * 1000000000)
                            // Next toast to be removed will always be the first in the list
                            toastVM.toasts.removeFirst()
                        }
                    }
                }
                if installVM.inProgress {
                    VStack {
                        Text(NSLocalizedString(installVM.status.rawValue, comment: ""))
                        ProgressView(value: installVM.progress)
                    }
                    .toastBackground()
                }
            }
            .animation(.easeInOut(duration: 0.25), value: toastVM.toasts.count)
            .animation(.easeInOut(duration: 0.25), value: installVM.inProgress)
        }
    }
}

struct ToastView_Preview: PreviewProvider {
    static var previews: some View {
        ToastView()
            .environmentObject(ToastVM.shared)
            .environmentObject(InstallVM.shared)
    }
}
