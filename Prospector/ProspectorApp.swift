//
//  ProspectorApp.swift
//  Prospector
//
//  Created by Christian Selig on 2025-08-20.
//

import SwiftUI

@main
struct ProspectorApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 460)

        // Mixed immersion (the default) keeps passthrough available everywhere,
        // so walking around the real room never triggers the system's
        // safety breakthrough that progressive/full immersion have.
        ImmersiveSpace(id: "ImmersiveSpace") {
            ImmersiveView()
                .environment(appModel)
        }
    }
}
