import SwiftUI

@main
struct TabletopCamApp: App {
    @StateObject private var camera: CameraController
    @StateObject private var link: TabletopLink
    @Environment(\.scenePhase) private var scenePhase

    init() {
        log("Avvio Tabletop Cam \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
        let camera = CameraController()
        _camera = StateObject(wrappedValue: camera)
        _link = StateObject(wrappedValue: TabletopLink(camera: camera))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .environmentObject(link)
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
