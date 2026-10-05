import SwiftUI

@main
struct TabletopCamApp: App {
    @StateObject private var camera: CameraController
    @StateObject private var link: TabletopLink
    @StateObject private var streamer: LiveStreamer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        log("Avvio Tabletop Cam \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
        let camera = CameraController()
        _camera = StateObject(wrappedValue: camera)
        let streamer = LiveStreamer()
        let feeder = streamer.feeder
        camera.motion.onFrame = { feeder.feed($0) }
        _streamer = StateObject(wrappedValue: streamer)
        _link = StateObject(wrappedValue: TabletopLink(camera: camera, streamer: streamer))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .environmentObject(link)
                .environmentObject(streamer)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // tabletopcam://pair?server=…&code=… (es. da un QR mostrato da Tabletop)
                    log("Aperto link \(url.scheme ?? "")://\(url.host ?? "")…")
                    Task { try? await link.pair(input: url.absoluteString, server: link.server) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: log("App in background: la fotocamera si ferma finché non torni nell'app")
            case .active: log("App in primo piano")
            default: break
            }
        }
    }
}
