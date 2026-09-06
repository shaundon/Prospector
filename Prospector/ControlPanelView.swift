//
//  ControlPanelView.swift
//  Prospector
//

import SwiftUI

/// The floating control panel shown inside the immersive space.
///
/// It lives in the space (as a RealityView attachment) rather than in a window
/// so the model can never end up between you and it: in mixed immersion, virtual
/// geometry occludes windows behind it and swallows the pinches meant for them.
struct ControlPanelView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var isGuideShown = false

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Prospector")
                    .font(.headline)
                Spacer()
                Toggle(isOn: $appModel.panelFollowsUser) {
                    HStack(spacing: 6) {
                        if appModel.panelFollowsUser {
                            Image(systemName: "checkmark")
                        }
                        Text("Follow me")
                    }
                }
                .toggleStyle(.button)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Passthrough")
                Picker("Passthrough", selection: $appModel.passthrough) {
                    ForEach(AppModel.Passthrough.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Toggle("Show skybox", isOn: $appModel.showSkybox)

            Divider()

            Text("Align with the room")
                .font(.headline)
            HStack {
                Button("Auto-align") { appModel.pendingRequest = .alignToRoom }
                Button("Snap to floor") { appModel.pendingRequest = .resetHeight }
                Button("Reset position") { appModel.pendingRequest = .resetPosition }
            }
            if let message = appModel.alignmentMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            DisclosureGroup("Moving the room", isExpanded: $isGuideShown) {
                ControlsGuide()
                    .padding(.top, 6)
            }
            
            Divider()

            Button("Exit Immersive View") {
                Task { await dismissImmersiveSpace() }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 440)
        .padding(20)
        .glassBackgroundEffect()
    }
}

/// A reminder of the gestures and buttons, shown in the window and the panel.
struct ControlsGuide: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Left hand", "Pinch and drag to move the room around.")
            row("Right hand", "Pinch and drag to rotate the room")
            row("Thumb + middle", "Hold the pinch for 0.5s to switch full passthrough on or off.")
            row("Auto-align", "Stand where you'd be in the model, look around so the walls and floor get detected, then press. If it faces the wrong way, swing it a quarter turn with your right hand.")
            row("Controller", "Left stick moves, right stick turns, triggers go down/up. D-pad: up snaps to floor, right toggles terrain follow, left toggles speed mode.")
        }
        .font(.footnote)
    }

    private func row(_ label: String, _ text: String) -> some View {
        GridRow(alignment: .top) {
            Text(label)
                .fontWeight(.semibold)
                .gridColumnAlignment(.trailing)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ControlPanelView()
        .environment(AppModel())
}
