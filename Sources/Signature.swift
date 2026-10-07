import Foundation

/// Scadenza della firma dell'app (Apple ID gratuito: 7 giorni), letta dal profilo incluso nell'app.
enum Signature {
    static let expiration: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = try? PropertyListSerialization.propertyList(
            from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }()

    /// Meno di 2 giorni alla scadenza.
    static var isExpiringSoon: Bool {
        guard let expiration else { return false }
        return expiration.timeIntervalSinceNow < 2 * 86_400
    }

    static var text: String {
        guard let expiration else { return "Scadenza firma sconosciuta" }
        let left = expiration.timeIntervalSinceNow
        if left <= 0 { return "Firma SCADUTA: reinstalla l'app" }
        let date = expiration.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        if left < 86_400 { return "Firma: scade tra \(Int(left / 3600)) ore (\(date))" }
        return "Firma valida fino a \(date)"
    }

    static var iso8601: String? {
        expiration.map { ISO8601DateFormatter().string(from: $0) }
    }
}
