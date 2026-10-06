import UIKit

/// Schermo nero (risparmio batteria): comandabile dall'app e dal pannello Fotocamera del PC.
@MainActor
final class ScreenState: ObservableObject {
    @Published private(set) var blackScreen = false
    private var savedBrightness: CGFloat?

    func setBlackScreen(_ on: Bool) {
        guard on != blackScreen else { return }
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
        if on {
            savedBrightness = screen?.brightness
            screen?.brightness = 0
            log("Schermo nero attivato")
        } else {
            if let savedBrightness { screen?.brightness = savedBrightness }
            log("Schermo riacceso")
        }
        blackScreen = on
    }
}
