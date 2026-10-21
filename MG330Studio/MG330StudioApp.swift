// MG330StudioApp.swift — app entry point.
import SwiftUI

@main
struct MG330StudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
