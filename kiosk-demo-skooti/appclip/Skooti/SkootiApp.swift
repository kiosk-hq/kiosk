// SkootiApp.swift — Container app entry point
//
// The container app must exist; App Clips cannot ship standalone.
// This minimal container shows a placeholder screen directing users
// to launch the App Clip via a scooter link.
//
// The real unlock flow lives in SkootiClip (the App Clip target).

import SwiftUI

@main
struct SkootiApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
