import SwiftUI

@main
struct TabletopCamApp: App {
    @StateObject private var camera = CameraController()

    init() {
        log("Avvio Tabletop Cam \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .preferredColorScheme(.dark)
        }
    }
}
