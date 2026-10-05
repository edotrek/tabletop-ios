import Foundation
import QuartzCore

/// Collegamento con il server di Tabletop: l'app si comporta come l'agente della reflex
/// (dispositivo `photo-camera`, vedi apps/server/agent/tabletop-reflex.cmd).
@MainActor
final class TabletopLink: ObservableObject {
    enum State: Equatable {
        case unpaired
        case connecting
        case online
        case offline(String)
    }

    static let defaultServer = "https://10.0.10.129"

    @Published private(set) var state: State = .unpaired {
        didSet { updateMotionDetection() }
    }
    @Published var autoCapture: Bool {
        didSet {
            UserDefaults.standard.set(autoCapture, forKey: Keys.autoCapture)
            updateMotionDetection()
        }
    }
    @Published private(set) var server: String
    @Published private(set) var isSending = false
    @Published private(set) var lastUpload: String?
    @Published private(set) var sentCount = 0

    var isPaired: Bool { token != nil }

    private enum Keys {
        static let server = "server"
        static let token = "deviceToken"
        static let autoCapture = "autoCapture"
    }

    /// Una sola sessione HTTP per tutta l'app, con la gestione del certificato del server.
    static let trust = TrustDelegate()
    static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }()

    let streamer: LiveStreamer
    private let camera: CameraController
    private var trust: TrustDelegate { Self.trust }
    private var session: URLSession { Self.urlSession }
    private var token: String? {
        didSet { streamer.update(server: token == nil ? nil : server, token: token) }
    }
    private var pollTask: Task<Void, Never>?
    private var pending: String?

    init(camera: CameraController, streamer: LiveStreamer) {
        self.camera = camera
        self.streamer = streamer
        let defaults = UserDefaults.standard
        server = defaults.string(forKey: Keys.server) ?? Self.defaultServer
        token = defaults.string(forKey: Keys.token)
        autoCapture = defaults.object(forKey: Keys.autoCapture) as? Bool ?? true
        trust.allowedHost = URL(string: server)?.host
        camera.motion.onMoveEnded = { [weak self] in
            Task { @MainActor in self?.send(reason: "change") }
        }
        streamer.update(server: token == nil ? nil : server, token: token)
        if token != nil {
            log("Abbinamento salvato con \(server): mi ricollego")
            start()
        }
    }

    // MARK: - Abbinamento

    /// Accetta il codice, il link "Scarica l'agente" (…/api/devices/agent?code=…)
    /// oppure un link tabletopcam://pair?server=…&code=…
    func pair(input: String, server serverInput: String) async throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var code = text
        var server = serverInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: text), let items = comps.queryItems,
           let c = items.first(where: { $0.name == "code" })?.value {
            code = c
            if let s = items.first(where: { $0.name == "server" })?.value {
                server = s
            } else if let scheme = comps.scheme, scheme.hasPrefix("http"), let host = comps.host {
                server = "\(scheme)://\(host)\(comps.port.map { ":\($0)" } ?? "")"
            }
        }
        while server.hasSuffix("/") { server.removeLast() }
        guard !code.isEmpty else { throw LinkError("Inserisci il codice o il link di abbinamento.") }
        guard let base = URL(string: server), base.host != nil else { throw LinkError("Indirizzo del server non valido.") }

        log("Abbinamento con \(server)…")
        trust.allowedHost = base.host
        var request = URLRequest(url: base.appendingPathComponent("api/devices/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["pairingCode": code])
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = serverError(data) ?? "Errore \(status)"
            log("Abbinamento fallito: \(message)")
            throw LinkError(message)
        }
        let paired = try JSONDecoder().decode(PairResponse.self, from: data)
        guard paired.kind == "photo-camera" else {
            log("Abbinamento: tipo \(paired.kind) invece di photo-camera")
            throw LinkError("Questo codice non è per una reflex: nel pannello usa \"Collega reflex\".")
        }
        log("Abbinato: stanza \(paired.roomId), dispositivo \(paired.deviceId)")
        self.server = server
        token = paired.deviceToken
        UserDefaults.standard.set(server, forKey: Keys.server)
        UserDefaults.standard.set(paired.deviceToken, forKey: Keys.token)
        start()
    }

    func unpair(reason: String) {
        log("Scollegato: \(reason)")
        pollTask?.cancel()
        pollTask = nil
        token = nil
        pending = nil
        UserDefaults.standard.removeObject(forKey: Keys.token)
        state = .unpaired
    }

    // MARK: - Comandi (long polling) e invio foto

    private func start() {
        pollTask?.cancel()
        state = .connecting
        camera.mode = .jpeg
        pollTask = Task { [weak self] in await self?.pollLoop() }
        // Prima foto appena la fotocamera è pronta: conferma anche che il server ci accetta.
        Task { [weak self] in
            for _ in 0..<50 {
                if self?.camera.isReady == true { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            self?.send(reason: "request")
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled, let token, let url = URL(string: server + "/api/devices/poll") {
            var request = URLRequest(url: url)
            request.setValue(token, forHTTPHeaderField: "x-device-token")
            request.timeoutInterval = 40
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 {
                    unpair(reason: "il dispositivo è stato rimosso dal pannello di Tabletop")
                    return
                }
                guard status == 200 else { throw LinkError(serverError(data) ?? "errore \(status)") }
                setOnline()
                let commands = try JSONDecoder().decode(Commands.self, from: data)
                if commands.capture == true {
                    log("Tabletop chiede una foto")
                    send(reason: "request")
                }
            } catch {
                if Task.isCancelled { return }
                setOffline(error)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func setOnline() {
        if state != .online {
            log("Collegato a Tabletop (\(server))")
            state = .online
        }
    }

    private func setOffline(_ error: Error) {
        let message = (error as? LinkError)?.message ?? error.localizedDescription
        if state != .offline(message) {
            log("Server non raggiungibile: \(message)")
            state = .offline(message)
        }
    }

    /// Scatta a 48 MP e invia. Se uno scatto è già in corso, ne fa un altro subito dopo.
    func send(reason: String) {
        guard isPaired else { return }
        if isSending {
            if pending == nil || reason == "request" { pending = reason }
            return
        }
        isSending = true
        camera.motion.setBusy(true)
        Task {
            let start = CACurrentMediaTime()
            let jpeg: Data? = await withCheckedContinuation { cont in
                camera.captureForUpload { cont.resume(returning: $0) }
            }
            if let jpeg {
                await upload(jpeg, reason: reason, captureTime: CACurrentMediaTime() - start)
            }
            isSending = false
            camera.motion.setBusy(false)
            if let next = pending {
                pending = nil
                send(reason: next)
            }
        }
    }

    private func upload(_ jpeg: Data, reason: String, captureTime: Double) async {
        guard let token, let url = URL(string: server + "/api/devices/frame?reason=\(reason)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-device-token")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let start = CACurrentMediaTime()
        do {
            let (data, response) = try await session.upload(for: request, from: jpeg)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                unpair(reason: "il dispositivo è stato rimosso dal pannello di Tabletop")
                return
            }
            guard status == 200 else { throw LinkError(serverError(data) ?? "errore \(status)") }
            let uploadTime = CACurrentMediaTime() - start
            camera.motion.confirmSent()
            setOnline()
            sentCount += 1
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let why = reason == "change" ? "fine mossa" : "richiesta"
            lastUpload = "Ultima foto \(time) (\(why)): scatto \(seconds(captureTime)) + invio \(seconds(uploadTime))"
            log("Foto inviata (\(why)) \(megabytes(jpeg.count)): scatto \(seconds(captureTime)), invio \(seconds(uploadTime))")
        } catch {
            log("ERRORE invio foto: \(error.localizedDescription)")
            setOffline(error)
        }
    }

    private func updateMotionDetection() {
        camera.motion.setEnabled(autoCapture && state == .online)
    }

    private func serverError(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }
}

private struct PairResponse: Decodable {
    let roomId: String
    let deviceId: String
    let deviceToken: String
    let kind: String
}

private struct Commands: Decodable {
    let capture: Bool?
}

struct LinkError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Il certificato del server è firmato dall'autorità locale di Caddy. Se iOS lo considera già
/// attendibile (certificato radice installato) va tutto da sé; altrimenti lo accettiamo
/// comunque, ma solo per l'host del server di Tabletop.
final class TrustDelegate: NSObject, URLSessionDelegate {
    var allowedHost: String?
    private var warned = false

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.performDefaultHandling, nil)
        } else if challenge.protectionSpace.host == allowedHost {
            if !warned {
                warned = true
                log("Certificato del server non attendibile per iOS (\(error.map { String(describing: $0) } ?? "?")): accettato solo per \(challenge.protectionSpace.host)")
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
