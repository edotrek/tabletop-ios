import AVFoundation

/// Rileva la fine di una mossa dai fotogrammi dell'anteprima, come la pagina web di Tabletop
/// (`startHdFrames` in CapturePage.tsx): la scena è cambiata rispetto all'ultima foto inviata
/// ed è di nuovo ferma da un secondo.
final class MotionDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static let checkInterval = 0.5
    private static let stillThreshold = 2.5 // differenza media (0-255) sotto cui la scena è ferma
    private static let changeThreshold = 4.0 // differenza rispetto all'ultima foto per inviarne una nuova
    private static let stillRequired = 1.0
    private static let thumbWidth = 64

    let output = AVCaptureVideoDataOutput()
    /// Chiamate sul main thread.
    var onMoveEnded: (() -> Void)?
    var onInfo: ((String) -> Void)?
    /// Ogni fotogramma (sulla coda video), per lo streaming. Da impostare prima dell'avvio.
    var onFrame: ((CMSampleBuffer) -> Void)?

    private let queue = DispatchQueue(label: "camera.motion")
    // Stato usato solo sulla coda `queue`.
    private var enabled = false
    private var busy = false
    private var lastCheck = 0.0
    private var previous: [UInt8]?
    private var latest: [UInt8]?
    private var candidate: [UInt8]?
    private var lastSent: [UInt8]?
    private var stillFor = 0.0
    private var pendingGrab: ((CVPixelBuffer) -> Void)?

    override init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func setEnabled(_ value: Bool) {
        queue.async {
            guard self.enabled != value else { return }
            self.enabled = value
            self.previous = nil
            self.stillFor = 0
            log("Scatto automatico a fine mossa: \(value ? "attivo" : "spento")")
        }
    }

    /// Mentre si scatta/invia non si rilevano nuove mosse.
    func setBusy(_ value: Bool) {
        queue.async { self.busy = value }
    }

    /// Da chiamare quando inizia uno scatto per Tabletop: ricorda com'era la scena.
    func snapshotForUpload() {
        queue.async { self.candidate = self.latest }
    }

    /// Da chiamare quando la foto è arrivata a Tabletop.
    func confirmSent() {
        queue.async {
            if let candidate = self.candidate { self.lastSent = candidate }
        }
    }

    /// Consegna il prossimo fotogramma video (sulla coda video; non trattenerlo a lungo).
    func grabNextFrame(_ handler: @escaping (CVPixelBuffer) -> Void) {
        queue.async { self.pendingGrab = handler }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
        if let grab = pendingGrab, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            pendingGrab = nil
            grab(pixelBuffer)
        }
        let now = CACurrentMediaTime()
        guard now - lastCheck >= Self.checkInterval, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastCheck = now
        let current = lumaThumbnail(pixelBuffer)
        latest = current
        guard enabled else { return }

        let motion = previous.map { meanDiff($0, current) } ?? .infinity
        previous = current
        stillFor = motion < Self.stillThreshold ? stillFor + Self.checkInterval : 0
        let changed = lastSent.map { meanDiff($0, current) } ?? .infinity

        let info = "movimento \(format(motion)) · diff. dall'ultima foto \(format(changed))"
        DispatchQueue.main.async { self.onInfo?(info) }

        if !busy && changed > Self.changeThreshold && stillFor >= Self.stillRequired {
            log("Fine mossa rilevata (diff. \(format(changed)), scena ferma da \(format(stillFor)) s)")
            busy = true
            DispatchQueue.main.async { self.onMoveEnded?() }
        }
    }

    private func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f", value) : "—"
    }

    /// Miniatura in scala di grigi (64 px di larghezza) presa dal piano della luminanza.
    private func lumaThumbnail(_ pixelBuffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return [] }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let tw = Self.thumbWidth
        let th = max(1, tw * height / max(1, width))
        let samples = 4 // 4×4 campioni per cella
        var out = [UInt8](repeating: 0, count: tw * th)
        for ty in 0..<th {
            for tx in 0..<tw {
                var sum = 0
                for sy in 0..<samples {
                    let y = ((ty * samples + sy) * 2 + 1) * height / (th * samples * 2)
                    for sx in 0..<samples {
                        let x = ((tx * samples + sx) * 2 + 1) * width / (tw * samples * 2)
                        sum += Int(pixels[y * stride + x])
                    }
                }
                out[ty * tw + tx] = UInt8(sum / (samples * samples))
            }
        }
        return out
    }

    private func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }
}
