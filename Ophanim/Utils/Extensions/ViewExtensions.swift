//
//  ViewExtensions.swift
//  Ophanim
//

import SwiftUI

extension View {
    func toastOverlay<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return self.safeAreaBar(edge: .bottom, content: content)
        }
        #endif
        return self.overlay(content: content)
    }

    func toastBackground() -> some View {
        let view = self
            .padding()
            .frame(maxWidth: .infinity)

        // provide default padding for older systems, but for those with liquid glass available, add proper padding to
        // left, right, and bottom to ensure that the distance from the edges of the app are consistent and equal
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return view.glassEffect(.regular, in: .containerRelative)
                .padding(ToastView.toastGlassPadding)
                .padding(.top)
        }
        #endif
        return view
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface.opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.45), lineWidth: 1))
            .padding()
    }
}
