// ContentView.swift — Placeholder screen for the Skooti container app
//
// The App Clip handles the unlock flow; this screen is shown only if the
// user installs/opens the full container app directly (rare in the demo).

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "scooter")
                .font(.system(size: 72, weight: .thin))
                .foregroundStyle(.primary)

            Text("Skooti")
                .font(.largeTitle.bold())

            Text("Open the App Clip from a scooter link to unlock.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(24)
    }
}

#Preview {
    ContentView()
}
