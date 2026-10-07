import AVFoundation

/// Rileva la fine di una mossa dai fotogrammi dell'anteprima, come la pagina web di Tabletop
/// (`startHdFrames` in CapturePage.tsx): la scena è cambiata rispetto all'ultima foto inviata
/// ed è di nuovo ferma da un secondo. Se Board Beam manda la zona del tabellone, guarda solo lì.
final class MotionDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static let checkInterval = 0.5
    private static let stillThreshold = 2.5 // differenza media (0-255) sotto cui la scena è ferma
    private static let changeThreshold = 4.0 // differenza rispetto all'ultima foto per inviarne una nuova
    private static let stillRequired = 1.0
    private static let thumbWidth = 96
    private static let cellChangeThreshold = 20 // differenza (0-255) di una cella per dirla "cambiata"

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
    /// Zone del tabellone in coordinate del sensore (0-1); vuoto = tutta l'inquadratura.
    private var regions: [[CGPoint]] = []
    /// Maschera calcolata per una certa dimensione della miniatura (mask nil = tutte le celle).
    private var maskCache: (width: Int, height: Int, mask: [Bool]?)?

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

    /// Zone del tabellone mandate da Board Beam, in frazioni della foto raddrizzata (verticale).
    func setRegions(_ portraitPolygons: [[CGPoint]]) {
        // La foto verticale è il sensore ruotato di 90° in senso orario:
        // (u, v) sulla foto corrisponde a (v, 1 - u) sul sensore.
        let converted = portraitPolygons
            .filter { $0.count >= 3 }
            .map { $0.map { CGPoint(x: $0.y, y: 1 - $0.x) } }
        queue.async {
            self.regions = converted
            self.maskCache = nil
            self.previous = nil
            self.stillFor = 0
        }
    }

    /// Celle della miniatura da considerare (nil = tutte).
    private func activeMask(width: Int, height: Int) -> [Bool]? {
        guard !regions.isEmpty, width > 0, height > 0 else { return nil }
        if let cache = maskCache, cache.width == width, cache.height == height { return cache.mask }
        var cells = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = CGPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))
                cells[y * width + x] = regions.contains { contains($0, p) }
            }
        }
        let active = cells.filter { $0 }.count
        let result: [Bool]? = active >= 12 ? cells : nil // zona troppo piccola: tutta l'inquadratura
        log(result == nil
            ? "Zona del tabellone troppo piccola: guardo tutta l'inquadratura"
            : String(format: "Rilevamento mosse limitato al tabellone (%.0f%% dell'inquadratura)", Double(active) / Double(cells.count) * 100))
        maskCache = (width, height, result)
        return result
    }

    private func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Zone cambiate tra l'ultima foto arrivata a Board Beam e quella appena scattata, in frazioni
    /// della foto verticale. nil = non si sa (prima foto, o è cambiato quasi tutto: luce, inquadratura).
    func changedRegions(_ completion: @escaping ([CGRect]?) -> Void) {
        queue.async { completion(self.computeChanges()) }
    }

    private func computeChanges() -> [CGRect]? {
        guard let a = lastSent, let b = candidate, a.count == b.count, !a.isEmpty else { return nil }
        let w = Self.thumbWidth, h = a.count / w
        let mask = activeMask(width: w, height: h)
        func active(_ i: Int) -> Bool { mask?[i] ?? true }
        // Toglie lo scarto medio di luminosità (piccoli cambi di esposizione).
        var shift = 0, n = 0
        for i in 0..<a.count where active(i) { shift += Int(b[i]) - Int(a[i]); n += 1 }
        let mean = n > 0 ? shift / n : 0
        var changed = [Bool](repeating: false, count: a.count)
        var count = 0
        for i in 0..<a.count where active(i) && abs(Int(b[i]) - Int(a[i]) - mean) > Self.cellChangeThreshold {
            changed[i] = true
            count += 1
        }
        if n > 0 && count * 2 > n { return nil }
        // Gruppi di celle vicine (anche in diagonale) → rettangoli, con un margine di una cella.
        var seen = [Bool](repeating: false, count: a.count)
        var boxes: [(x0: Int, y0: Int, x1: Int, y1: Int, cells: Int)] = []
        for start in 0..<a.count where changed[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var box = (x0: w, y0: h, x1: 0, y1: 0, cells: 0)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                box = (min(box.x0, x), min(box.y0, y), max(box.x1, x), max(box.y1, y), box.cells + 1)
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let j = ny * w + nx
                        if changed[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            if box.cells >= 2 { boxes.append(box) }
        }
        return boxes
            .sorted { $0.cells > $1.cells }
            .prefix(10)
            .map { box in
                let x0 = max(0, box.x0 - 1), y0 = max(0, box.y0 - 1)
                let x1 = min(w - 1, box.x1 + 1), y1 = min(h - 1, box.y1 + 1)
                // Sensore → foto verticale: u = 1 - y, v = x.
                let sx = Double(x0) / Double(w), sw = Double(x1 + 1 - x0) / Double(w)
                let sy = Double(y0) / Double(h), sh = Double(y1 + 1 - y0) / Double(h)
                return CGRect(x: 1 - sy - sh, y: sx, width: sh, height: sw)
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

        let mask = activeMask(width: Self.thumbWidth, height: current.count / Self.thumbWidth)
        let motion = previous.map { meanDiff($0, current, mask) } ?? .infinity
        previous = current
        stillFor = motion < Self.stillThreshold ? stillFor + Self.checkInterval : 0
        let changed = lastSent.map { meanDiff($0, current, mask) } ?? .infinity

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

    private func meanDiff(_ a: [UInt8], _ b: [UInt8], _ mask: [Bool]?) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum = 0, n = 0
        for i in 0..<a.count where mask?[i] ?? true {
            sum += abs(Int(a[i]) - Int(b[i]))
            n += 1
        }
        return n > 0 ? Double(sum) / Double(n) : .infinity
    }
}
