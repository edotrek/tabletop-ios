import AVFoundation
import LiveKit
import VideoToolbox

/// Stream video verso il server LiveKit di Tabletop, dalla stessa fotocamera che scatta a 48 MP.
/// Pubblica come la pagina web della telecamera (CapturePage.tsx): traccia "table", H.264,
/// simulcast su tre livelli; qui in 4:3 (2880×2160, 1440×1080, 720×540).
@MainActor
final class LiveStreamer: ObservableObject {
    static let fpsOptions = [30, 20, 15, 10, 5]

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            log("Video \(enabled ? "attivato" : "disattivato")")
            restart()
        }
    }
    @Published var fps: Int {
        didSet {
            UserDefaults.standard.set(fps, forKey: Keys.fps)
            log("Fluidità video: \(fps) fps")
            restart()
        }
    }
    @Published private(set) var status = "spento"
    @Published private(set) var isLive = false

    let feeder = FrameFeeder()

    private enum Keys {
        static let enabled = "videoEnabled"
        static let fps = "videoFps"
    }

    private var room: Room?
    private var task: Task<Void, Never>?
    private var target: (server: String, token: String)?
    private lazy var events = RoomEvents { [weak self] text, live in
        Task { @MainActor in self?.roomChanged(text, live: live) }
    }

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        let savedFps = defaults.integer(forKey: Keys.fps)
        fps = Self.fpsOptions.contains(savedFps) ? savedFps : 15
    }

    /// Chiamato da TabletopLink: dove trasmettere (nil = non collegati).
    func update(server: String?, token: String?) {
        let newTarget = server.flatMap { s in token.map { (server: s, token: $0) } }
        if newTarget?.server == target?.server && newTarget?.token == target?.token { return }
        target = newTarget
        restart()
    }

    private func restart() {
        task?.cancel()
        task = nil
        let old = room
        room = nil
        feeder.set(capturer: nil, fps: fps)
        isLive = false
        if let old {
            Task { await old.disconnect() }
        }
        guard enabled, let target else {
            status = enabled ? "in attesa del collegamento" : "spento"
            return
        }
        let fps = self.fps
        task = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.connect(server: target.server, deviceToken: target.token, fps: fps)
                    return
                } catch {
                    if Task.isCancelled { return }
                    attempt += 1
                    log("ERRORE video: \(error.localizedDescription) (riprovo tra 5 s)")
                    self.status = "errore: \(error.localizedDescription)"
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    private func connect(server: String, deviceToken: String, fps: Int) async throws {
        status = "collegamento…"
        guard let url = URL(string: server + "/api/media-token") else { throw LinkError("indirizzo non valido") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["participantToken": deviceToken])
        request.timeoutInterval = 15
        let (data, response) = try await TabletopLink.urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LinkError("token video rifiutato") }
        let media = try JSONDecoder().decode(MediaToken.self, from: data)
        try Task.checkCancellation()

        log("Video: collegamento a \(media.url)")
        let room = Room(delegate: events)
        do {
            try await publish(in: room, url: media.url, token: media.token, fps: fps)
            try Task.checkCancellation()
        } catch {
            // Interrotto o fallito a metà: chiude questa stanza (restart() conosce solo quella attiva).
            feeder.set(capturer: nil, fps: fps)
            await room.disconnect()
            throw error
        }
        self.room = room
        isLive = true
        status = "in diretta · \(fps) fps"
        log("Video in diretta: 2880×2160 (verticale), \(fps) fps")
    }

    private func publish(in room: Room, url: String, token: String, fps: Int) async throws {
        try await room.connect(url: url, token: token, connectOptions: ConnectOptions(autoSubscribe: false))
        try Task.checkCancellation()

        let track = await LocalVideoTrack.createBufferTrack(
            name: "table",
            source: .camera,
            options: BufferCaptureOptions(dimensions: Dimensions(width: 2880, height: 2160), fps: fps)
        )
        guard let capturer = track.capturer as? BufferCapturer else { throw LinkError("capturer video non disponibile") }
        feeder.set(capturer: capturer, fps: fps)

        // Come la pagina web: con meno fotogrammi serve meno banda a parità di nitidezza.
        let scale = max(0.5, Double(fps) / 30)
        func encoding(_ bitrate: Double) -> VideoEncoding {
            VideoEncoding(maxBitrate: Int(bitrate * scale), maxFps: fps)
        }
        let options = VideoPublishOptions(
            name: "table",
            encoding: encoding(24_000_000),
            simulcast: true,
            simulcastLayers: [
                VideoParameters(dimensions: Dimensions(width: 720, height: 540), encoding: encoding(1_200_000)),
                VideoParameters(dimensions: Dimensions(width: 1440, height: 1080), encoding: encoding(4_000_000)),
            ],
            preferredCodec: .h264,
            degradationPreference: .maintainResolution
        )
        try await room.localParticipant.publish(videoTrack: track, options: options)
    }

    private func roomChanged(_ text: String, live: Bool) {
        log("Video: \(text)")
        guard enabled, target != nil else { return }
        if live {
            if room != nil { status = "in diretta · \(fps) fps"; isLive = true }
        } else {
            status = text
            isLive = false
        }
    }
}

private struct MediaToken: Decodable {
    let url: String
    let token: String
}

/// Eventi della stanza LiveKit (arrivano su code qualsiasi).
final class RoomEvents: NSObject, RoomDelegate, @unchecked Sendable {
    private let onChange: (String, Bool) -> Void

    init(onChange: @escaping (String, Bool) -> Void) {
        self.onChange = onChange
    }

    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        switch connectionState {
        case .connected: onChange("collegato", true)
        case .reconnecting: onChange("riconnessione…", false)
        case .disconnected: onChange("scollegato", false)
        default: break
        }
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        onChange("disconnesso: \(error.map { String(describing: $0) } ?? "nessun errore")", false)
    }
}

/// Passa i fotogrammi della fotocamera a LiveKit, ridotti (4032×3024 è troppo per H.264)
/// e alla fluidità scelta. Chiamato sulla coda video della fotocamera.
final class FrameFeeder: @unchecked Sendable {
    static let outputWidth = 2880

    private let lock = NSLock()
    private var capturer: BufferCapturer?
    private var fps = 15
    // Usati solo sulla coda video.
    private var lastTime = 0.0
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)

    func set(capturer: BufferCapturer?, fps: Int) {
        lock.lock()
        self.capturer = capturer
        self.fps = fps
        lock.unlock()
    }

    func feed(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let capturer = self.capturer
        let fps = self.fps
        lock.unlock()
        guard let capturer, let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard time - lastTime >= 1.0 / Double(fps) - 0.005 else { return }
        lastTime = time
        guard let scaled = scale(source) else { return }
        // I fotogrammi arrivano "sdraiati" dal sensore: ruotati di 90° come le foto.
        capturer.capture(scaled, timeStampNs: Int64(time * 1_000_000_000), rotation: ._90)
    }

    private func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sw = CVPixelBufferGetWidth(source)
        let sh = CVPixelBufferGetHeight(source)
        guard sw > 0, sh > 0 else { return nil }
        let width = min(Self.outputWidth, sw)
        let height = (width * sh / sw) & ~1
        if transfer == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
            transfer = session
        }
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = (width, height)
        }
        guard let transfer, let pool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: output) == noErr else { return nil }
        return output
    }
}
