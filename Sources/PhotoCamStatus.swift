import Foundation

/// Stato dell'app per il pannello Fotocamera dell'host (PhotoCamStatus nel protocollo di Tabletop).
/// Si codifica sempre completo, con `null` per i valori mancanti.
struct PhotoCamStatus: Encodable, Equatable {
    var app: String
    var focusLocked: Bool
    var autoCapture: Bool
    var video: Bool
    var videoLive: Bool
    var fps: Int
    var capturing: Bool
    var blackScreen: Bool
    var battery: Double?
    var charging: Bool?
    var thermal: String
    var error: String?

    private enum CodingKeys: String, CodingKey {
        case app, focusLocked, autoCapture, video, videoLive, fps, capturing, blackScreen, battery, charging, thermal, error
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(app, forKey: .app)
        try c.encode(focusLocked, forKey: .focusLocked)
        try c.encode(autoCapture, forKey: .autoCapture)
        try c.encode(video, forKey: .video)
        try c.encode(videoLive, forKey: .videoLive)
        try c.encode(fps, forKey: .fps)
        try c.encode(capturing, forKey: .capturing)
        try c.encode(blackScreen, forKey: .blackScreen)
        try c.encode(battery, forKey: .battery)
        try c.encode(charging, forKey: .charging)
        try c.encode(thermal, forKey: .thermal)
        try c.encode(error, forKey: .error)
    }
}

extension ProcessInfo.ThermalState {
    /// Valore per il protocollo di Tabletop.
    var protocolName: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }
}
