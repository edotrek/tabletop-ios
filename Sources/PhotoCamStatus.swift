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
    // Campi aggiunti nella 0.7 (il server li ignora finché non li conosce).
    /// Scadenza della firma dell'app (ISO 8601), nil se sconosciuta.
    var signatureExpires: String?
    /// Protezione dal calore: "fps" (video ridotto), "video-off" (video spento), nil = nessuna.
    var thermalLimit: String?
    /// Poca luce sul tavolo: le foto perdono dettaglio.
    var lowLight: Bool
    var iso: Int

    private enum CodingKeys: String, CodingKey {
        case app, focusLocked, autoCapture, video, videoLive, fps, capturing, blackScreen, battery, charging, thermal, error
        case signatureExpires, thermalLimit, lowLight, iso
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
        try c.encode(signatureExpires, forKey: .signatureExpires)
        try c.encode(thermalLimit, forKey: .thermalLimit)
        try c.encode(lowLight, forKey: .lowLight)
        try c.encode(iso, forKey: .iso)
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
