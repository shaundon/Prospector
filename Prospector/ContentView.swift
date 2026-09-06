//
//  ContentView.swift
//  Prospector
//
//  Created by Christian Selig on 2025-08-20.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var isShowingFilePicker = false

    var body: some View {
        @Bindable var appModel = appModel

        VStack(spacing: 20) {
            modelPicker

            Button(appModel.isImmersiveSpaceOpen ? "Exit Immersive View" : "Enter Immersive View") {
                Task { await toggleImmersiveSpace() }
            }
            .font(.title)
            .disabled(appModel.loadState == .loading || appModel.modelURL == nil)

            loadStatus

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Controls")
                    .font(.headline)
                Text("Passthrough, alignment and the rest are on the floating panel inside the immersive view.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ControlsGuide()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 480)
        .fileImporter(isPresented: $isShowingFilePicker, allowedContentTypes: [.usdz]) { result in
            if case .success(let url) = result {
                Task { await appModel.selectModel(url) }
            }
        }
    }

    private var modelPicker: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(appModel.modelName ?? "No model selected")
                    .lineLimit(1)
            }
            Spacer()
            Button("Choose…") {
                isShowingFilePicker = true
            }
            .disabled(appModel.isImmersiveSpaceOpen)
        }
    }

    @ViewBuilder
    private var loadStatus: some View {
        switch appModel.loadState {
        case .loading:
            ProgressView("Loading model…")
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        case .idle:
            EmptyView()
        }
    }

    private func toggleImmersiveSpace() async {
        // The immersive view owns the open flag and the load state as it appears,
        // loads and disappears; this only reports the one failure it can see.
        if appModel.isImmersiveSpaceOpen {
            await dismissImmersiveSpace()
        } else if case .error = await openImmersiveSpace(id: "ImmersiveSpace") {
            appModel.loadState = .failed("Couldn't open the immersive space.")
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
