import Combine
import Foundation
import QuartzCore
import UIKit

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
    /// Ultimo errore di collegamento/invio (per il pannello del PC).
    @Published private(set) var lastError: String?

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
    private let screen: ScreenState
    // Pannello Fotocamera del PC: stato inviato solo mentre un host lo tiene aperto.
    private var reportingStatus = false
    private var statusWatchers: [NSObjectProtocol] = []
    private var statusSubscriptions = Set<AnyCancellable>()
    private var lastStatusSent: PhotoCamStatus?
    private var statusScheduled = false
    private var trust: TrustDelegate { Self.trust }
    private var session: URLSession { Self.urlSession }
    private var token: String? {
        didSet { streamer.update(server: token == nil ? nil : server, token: token) }
    }
    private var pollTask: Task<Void, Never>?
    private var pending: String?
    /// Ultima foto non arrivata per un problema di rete: si reinvia appena il server risponde.
    private var failedPhoto: PendingPhoto?

    init(camera: CameraController, streamer: LiveStreamer, screen: ScreenState) {
        self.camera = camera
        self.streamer = streamer
        self.screen = screen
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
        setReportStatus(false)
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
                    unpair(reason: "il dispositivo è stato rimosso dal pannello di Board Beam")
                    return
                }
                guard status == 200 else { throw LinkError(serverError(data) ?? "errore \(status)") }
                setOnline()
                // Letto a mano: comandi sconosciuti o campi nuovi non devono far fallire nulla.
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if let report = json["reportStatus"] as? Bool { setReportStatus(report) }
                if json.keys.contains("motionRegions") { setMotionRegions(json["motionRegions"]) }
                for command in json["commands"] as? [[String: Any]] ?? [] {
                    execute(command)
                }
                if json["capture"] as? Bool == true {
                    log("Board Beam chiede una foto")
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
        lastError = nil
        if state != .online {
            log("Collegato a Board Beam (\(server))")
            state = .online
        }
        if failedPhoto != nil { resendFailedPhoto() }
    }

    private func setOffline(_ error: Error) {
        let message = (error as? LinkError)?.message ?? error.localizedDescription
        lastError = "Server non raggiungibile: \(message)"
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
                let changes: [CGRect]? = await withCheckedContinuation { cont in
                    camera.motion.changedRegions { cont.resume(returning: $0) }
                }
                let photo = PendingPhoto(jpeg: jpeg, reason: reason, changes: changes)
                // Una foto nuova rende inutile reinviare quella vecchia.
                failedPhoto = nil
                if await upload(photo, captureTime: CACurrentMediaTime() - start) == .retry {
                    failedPhoto = photo
                    log("La foto verrà reinviata appena Board Beam torna raggiungibile")
                }
            }
            finishSending()
        }
    }

    private func finishSending() {
        isSending = false
        camera.motion.setBusy(false)
        if let next = pending {
            pending = nil
            send(reason: next)
        }
    }

    /// Reinvia l'ultima foto che non era arrivata (chiamato quando il server torna raggiungibile).
    private func resendFailedPhoto() {
        guard let photo = failedPhoto, !isSending, isPaired else { return }
        failedPhoto = nil
        isSending = true
        camera.motion.setBusy(true)
        log("Reinvio la foto che non era arrivata")
        Task {
            if await upload(photo, captureTime: nil) == .retry, failedPhoto == nil {
                failedPhoto = photo
            }
            finishSending()
        }
    }

    private enum UploadResult { case ok, retry, failed }

    private func upload(_ photo: PendingPhoto, captureTime: Double?) async -> UploadResult {
        guard let token, let url = URL(string: server + "/api/devices/frame?reason=\(photo.reason)") else { return .failed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-device-token")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        if let changes = photo.changes {
            // Zone cambiate rispetto alla foto precedente, in frazioni della foto raddrizzata.
            let boxes = changes.map { ["x": round4($0.minX), "y": round4($0.minY), "w": round4($0.width), "h": round4($0.height)] }
            if let json = try? JSONSerialization.data(withJSONObject: boxes), let text = String(data: json, encoding: .utf8) {
                request.setValue(text, forHTTPHeaderField: "x-changed-regions")
            }
        }
        request.timeoutInterval = 60
        let start = CACurrentMediaTime()
        do {
            let (data, response) = try await session.upload(for: request, from: photo.jpeg)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                unpair(reason: "il dispositivo è stato rimosso dal pannello di Board Beam")
                return .failed
            }
            guard status == 200 else {
                let message = serverError(data) ?? "errore \(status)"
                log("ERRORE invio foto: \(message)")
                // Errori del server (5xx) si riprovano; una foto rifiutata (4xx) no.
                if status >= 500 {
                    setOffline(LinkError(message))
                    return .retry
                }
                lastError = "Foto rifiutata: \(message)"
                return .failed
            }
            let uploadTime = CACurrentMediaTime() - start
            camera.motion.confirmSent()
            setOnline()
            sentCount += 1
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let why = photo.reason == "change" ? "fine mossa" : "richiesta"
            let changesText = photo.changes.map { " · \($0.count) zone cambiate" } ?? ""
            if let captureTime {
                lastUpload = "Ultima foto \(time) (\(why)): scatto \(seconds(captureTime)) + invio \(seconds(uploadTime))\(changesText)"
                log("Foto inviata (\(why)) \(megabytes(photo.jpeg.count)): scatto \(seconds(captureTime)), invio \(seconds(uploadTime))\(changesText)")
            } else {
                lastUpload = "Ultima foto \(time) (\(why), reinviata)\(changesText)"
                log("Foto reinviata (\(why)) \(megabytes(photo.jpeg.count)) in \(seconds(uploadTime))")
            }
            return .ok
        } catch {
            log("ERRORE invio foto: \(error.localizedDescription)")
            setOffline(error)
            return .retry
        }
    }

    // MARK: - Zona del tabellone

    private var motionRegionsKey: String?

    /// Poligoni (punti {x, y} in frazioni della foto raddrizzata) in cui guardare le mosse.
    /// null o [] = tutta l'inquadratura. Vale l'ultimo valore ricevuto.
    private func setMotionRegions(_ value: Any?) {
        let polygons: [[CGPoint]] = (value as? [[[String: Any]]] ?? []).map { polygon in
            polygon.compactMap { point in
                guard let x = (point["x"] as? NSNumber)?.doubleValue, let y = (point["y"] as? NSNumber)?.doubleValue else { return nil }
                return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
            }
        }
        let key = polygons.map { $0.map { String(format: "%.3f,%.3f", $0.x, $0.y) }.joined(separator: ";") }.joined(separator: "|")
        guard key != motionRegionsKey else { return }
        motionRegionsKey = key
        log(polygons.isEmpty ? "Board Beam: nessuna zona del tabellone, guardo tutta l'inquadratura"
                             : "Board Beam: zona del tabellone ricevuta (\(polygons.count) zone)")
        camera.motion.setRegions(polygons)
    }

    // MARK: - Pannello Fotocamera del PC

    /// Comando dal pannello dell'host (sempre attivo, anche a pannello chiuso).
    private func execute(_ command: [String: Any]) {
        let name = command["command"] as? String ?? "?"
        let on = command["on"] as? Bool
        switch name {
        case "focus-lock":
            log("Dal PC: metti a fuoco al centro e blocca")
            camera.focusCenterAndLock()
        case "focus-unlock":
            log("Dal PC: fuoco ed esposizione sbloccati")
            camera.setLocked(false)
        case "auto-capture":
            guard let on else { break }
            log("Dal PC: scatto automatico \(on ? "acceso" : "spento")")
            if autoCapture != on { autoCapture = on }
        case "video":
            guard let on else { break }
            log("Dal PC: video \(on ? "acceso" : "spento")")
            if streamer.enabled != on { streamer.enabled = on }
        case "fps":
            guard let fps = command["fps"] as? Int, LiveStreamer.fpsOptions.contains(fps) else { break }
            log("Dal PC: fluidità \(fps) fps")
            if streamer.fps != fps { streamer.fps = fps }
        case "send-log":
            log("Dal PC: invio il log")
            uploadLog()
        case "black-screen":
            guard let on else { break }
            log("Dal PC: schermo nero \(on ? "acceso" : "spento")")
            screen.setBlackScreen(on)
        default:
            log("Dal PC: comando sconosciuto ignorato (\(name))")
        }
    }

    /// Manda al server il log di questo avvio e di quello precedente (per scaricarlo dal PC).
    private func uploadLog() {
        guard let token, let url = URL(string: server + "/api/devices/log") else { return }
        let maxBytes = 2_000_000
        func tail(_ text: String, _ limit: Int) -> String {
            let data = Data(text.utf8)
            guard data.count > limit else { return text }
            // Tiene la parte finale, la più utile.
            return "[… inizio tagliato …]\n" + String(decoding: data.suffix(limit), as: UTF8.self)
        }
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let header = "Board Beam Cam \(app) · \(deviceModelIdentifier()) · iOS \(UIDevice.current.systemVersion)\n"
        let current = tail(LogStore.shared.text, maxBytes * 3 / 4)
        let previous = tail(LogStore.shared.previousText ?? "(nessuno)", maxBytes / 4)
        let body = header + "\n=== Log di questo avvio ===\n" + current + "\n\n=== Log dell'avvio precedente ===\n" + previous + "\n"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-device-token")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        Task {
            do {
                let (data, response) = try await session.upload(for: request, from: Data(body.utf8))
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 {
                    unpair(reason: "il dispositivo è stato rimosso dal pannello di Board Beam")
                } else if code == 200 {
                    log("Log inviato al PC (\(megabytes(body.utf8.count)))")
                } else {
                    log("Invio del log rifiutato: \(serverError(data) ?? "errore \(code)")")
                }
            } catch {
                log("Invio del log fallito: \(error.localizedDescription)")
            }
        }
    }

    /// true = un host ha il pannello aperto. Vale l'ultimo valore ricevuto.
    private func setReportStatus(_ on: Bool) {
        guard on != reportingStatus else { return }
        reportingStatus = on
        if on {
            log("Pannello Fotocamera aperto sul PC: invio lo stato quando cambia")
            startStatusWatch()
            scheduleStatus()
        } else {
            log("Pannello Fotocamera chiuso: smetto di inviare e misurare lo stato")
            stopStatusWatch()
        }
    }

    private func startStatusWatch() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification,
                     ProcessInfo.thermalStateDidChangeNotification] {
            statusWatchers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleStatus() }
            })
        }
        // I @Published avvisano prima di cambiare: scheduleStatus legge i valori al giro successivo.
        let changes: [AnyPublisher<Void, Never>] = [
            camera.$isLocked.map { _ in () }.eraseToAnyPublisher(),
            camera.$isCapturing.map { _ in () }.eraseToAnyPublisher(),
            camera.$lastError.map { _ in () }.eraseToAnyPublisher(),
            camera.$lowLight.map { _ in () }.eraseToAnyPublisher(),
            streamer.$thermalLimit.map { _ in () }.eraseToAnyPublisher(),
            $autoCapture.map { _ in () }.eraseToAnyPublisher(),
            $isSending.map { _ in () }.eraseToAnyPublisher(),
            $lastError.map { _ in () }.eraseToAnyPublisher(),
            streamer.$enabled.map { _ in () }.eraseToAnyPublisher(),
            streamer.$isLive.map { _ in () }.eraseToAnyPublisher(),
            streamer.$fps.map { _ in () }.eraseToAnyPublisher(),
            streamer.$status.map { _ in () }.eraseToAnyPublisher(),
            screen.$blackScreen.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] in self?.scheduleStatus() }
            .store(in: &statusSubscriptions)
    }

    private func stopStatusWatch() {
        statusWatchers.forEach(NotificationCenter.default.removeObserver)
        statusWatchers.removeAll()
        statusSubscriptions.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = false
        lastStatusSent = nil
    }

    /// Raggruppa i cambiamenti ravvicinati in un solo invio.
    private func scheduleStatus() {
        guard reportingStatus, !statusScheduled else { return }
        statusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusScheduled = false
            self.sendStatusIfChanged()
        }
    }

    private func currentStatus() -> PhotoCamStatus {
        let device = UIDevice.current
        let charging: Bool?
        switch device.batteryState {
        case .charging, .full: charging = true
        case .unplugged: charging = false
        default: charging = nil
        }
        let videoError = streamer.status.hasPrefix("errore") ? "Video: \(streamer.status)" : nil
        return PhotoCamStatus(
            app: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            focusLocked: camera.isLocked,
            autoCapture: autoCapture,
            video: streamer.enabled,
            videoLive: streamer.isLive,
            fps: streamer.fps,
            capturing: isSending || camera.isCapturing,
            blackScreen: screen.blackScreen,
            battery: device.batteryLevel < 0 ? nil : (Double(device.batteryLevel) * 100).rounded() / 100,
            charging: charging,
            thermal: ProcessInfo.processInfo.thermalState.protocolName,
            error: camera.lastError ?? lastError ?? videoError,
            signatureExpires: Signature.iso8601,
            thermalLimit: streamer.thermalLimit == .none ? nil : streamer.thermalLimit.rawValue,
            lowLight: camera.lowLight,
            iso: camera.iso
        )
    }

    private func sendStatusIfChanged() {
        guard reportingStatus, let token, let url = URL(string: server + "/api/devices/status") else { return }
        let status = currentStatus()
        guard status != lastStatusSent else { return }
        // Se l'invio fallisce non si ritenta: lo rimanda il prossimo cambiamento.
        lastStatusSent = status
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "x-device-token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONEncoder().encode(status)
        log("Stato inviato al PC: fuoco \(status.focusLocked ? "bloccato" : "auto"), video \(status.videoLive ? "in onda" : (status.video ? "acceso" : "spento")), batteria \(status.battery.map { "\(Int($0 * 100))%" } ?? "?"), temperatura \(status.thermal)")
        Task {
            do {
                let (data, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 {
                    unpair(reason: "il dispositivo è stato rimosso dal pannello di Board Beam")
                    return
                }
                guard code == 200 else {
                    log("Invio stato al PC rifiutato: \(serverError(data) ?? "errore \(code)")")
                    return
                }
                if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let report = json["reportStatus"] as? Bool {
                    setReportStatus(report)
                }
            } catch {
                log("Invio stato al PC fallito: \(error.localizedDescription)")
            }
        }
    }

    private func updateMotionDetection() {
        camera.motion.setEnabled(autoCapture && state == .online)
    }

    private func serverError(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }
}

private struct PendingPhoto {
    let jpeg: Data
    let reason: String
    let changes: [CGRect]?
}

private func round4(_ value: CGFloat) -> Double {
    (Double(value) * 10_000).rounded() / 10_000
}

private struct PairResponse: Decodable {
    let roomId: String
    let deviceId: String
    let deviceToken: String
    let kind: String
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
