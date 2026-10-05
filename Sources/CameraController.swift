import AVFoundation
import CoreImage
import ImageIO
import UIKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case heic = "HEIC"
    case proRaw = "ProRAW→JPEG"

    var id: String { rawValue }
}

struct CaptureParams {
    let mode: CaptureMode
    let dim: Dim
    let jpegQuality: Double?
}

struct CaptureResult: Identifiable {
    let id = UUID()
    let title: String
    let info: [String]
    let files: [URL]
    let data: Data
    let thumbnail: UIImage?
    let crop: UIImage?
}

final class CameraController: NSObject, ObservableObject {
    // Stato mostrato nell'interfaccia (modificato solo sul main thread).
    @Published var isReady = false
    @Published var isCapturing = false
    @Published var statusText = "Avvio fotocamera…"
    @Published var liveInfo = ""
    @Published var availableDims: [Dim] = []
    @Published var selectedDim: Dim?
    @Published var proRawSupported = false
    @Published var isLocked = false
    @Published var jpegQuality: Double? = nil
    @Published var lastResult: CaptureResult?
    @Published var motionInfo = ""
    @Published var mode: CaptureMode = .jpeg {
        didSet { if mode != oldValue { modeChanged() } }
    }

    let session = AVCaptureSession()
    let motion = MotionDetector()
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let processingQueue = DispatchQueue(label: "camera.processing")
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    private var configured = false
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    override init() {
        super.init()
        motion.onInfo = { [weak self] info in self?.motionInfo = info }
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { n in
            log("ERRORE sessione: \(String(describing: n.userInfo?[AVCaptureSessionErrorKey]))")
        }
        nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { n in
            log("Sessione interrotta: \(String(describing: n.userInfo?[AVCaptureSessionInterruptionReasonKey]))")
        }
        nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in
            log("Sessione ripresa")
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            log("Temperatura cambiata: \(ProcessInfo.processInfo.thermalState.italian)")
        }
    }

    // MARK: - Avvio e configurazione

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configure() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok {
                    self.sessionQueue.async { self.configure() }
                } else {
                    log("Permesso fotocamera negato")
                    self.setStatus("Permesso fotocamera negato: abilitalo in Impostazioni")
                }
            }
        default:
            log("Permesso fotocamera negato")
            setStatus("Permesso fotocamera negato: abilitalo in Impostazioni")
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusText = text }
    }

    private func configure() {
        guard !configured else { return }
        configured = true
        log("Dispositivo \(deviceModelIdentifier()), iOS \(UIDevice.current.systemVersion)")

        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            log("ERRORE: fotocamera principale non trovata")
            setStatus("Fotocamera non trovata")
            return
        }
        device = dev
        log("Fotocamera: \(dev.localizedName) (\(dev.deviceType.rawValue))")

        session.beginConfiguration()
        session.sessionPreset = .photo
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            guard session.canAddInput(input) else { throw NSError(domain: "camera", code: 1) }
            session.addInput(input)
        } catch {
            log("ERRORE input fotocamera: \(error)")
            session.commitConfiguration()
            setStatus("Errore fotocamera")
            return
        }
        guard session.canAddOutput(photoOutput) else {
            log("ERRORE: impossibile aggiungere l'uscita foto")
            session.commitConfiguration()
            return
        }
        session.addOutput(photoOutput)
        if session.canAddOutput(motion.output) {
            session.addOutput(motion.output)
        } else {
            log("ATTENZIONE: impossibile aggiungere l'uscita video per il rilevamento delle mosse")
        }

        logFormats(dev)
        let presetMax = maxPixels(dev.activeFormat)
        log("Con preset .photo il formato attivo permette foto fino a: \(dev.activeFormat.supportedMaxPhotoDimensions.map { Dim($0).label }.joined(separator: ", "))")
        if let best = bestPhotoFormat(dev), maxPixels(best) > presetMax {
            do {
                try dev.lockForConfiguration()
                dev.activeFormat = best
                dev.unlockForConfiguration()
                log("Formato cambiato per avere la risoluzione massima: \(describe(best))")
            } catch {
                log("ERRORE cambio formato: \(error)")
            }
        }
        session.commitConfiguration()

        photoOutput.maxPhotoQualityPrioritization = .quality
        if let conn = photoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
        applyMaxDimensions()
        logOutput()

        session.startRunning()
        log("Sessione avviata: \(session.isRunning)")

        let dims = sortedDims(dev.activeFormat)
        let proRaw = photoOutput.isAppleProRAWSupported
        DispatchQueue.main.async {
            self.availableDims = dims
            self.selectedDim = dims.last
            self.proRawSupported = proRaw
            self.isReady = true
            self.statusText = "Pronta"
        }
    }

    private func sortedDims(_ format: AVCaptureDevice.Format) -> [Dim] {
        format.supportedMaxPhotoDimensions.map(Dim.init).sorted { $0.pixels < $1.pixels }
    }

    private func maxPixels(_ format: AVCaptureDevice.Format) -> Int {
        sortedDims(format).last?.pixels ?? 0
    }

    /// Il formato con la foto più grande; a parità preferisce 4:3, 420f, video più grande.
    private func bestPhotoFormat(_ dev: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let top = dev.formats.map(maxPixels).max() ?? 0
        let candidates = dev.formats.filter { maxPixels($0) == top }
        func score(_ f: AVCaptureDevice.Format) -> (Int, Int, Int) {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let is43 = Int(d.width) * 3 == Int(d.height) * 4 ? 1 : 0
            let is420f = fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription)) == "420f" ? 1 : 0
            return (is43, is420f, Int(d.width) * Int(d.height))
        }
        return candidates.max { score($0) < score($1) }
    }

    private func describe(_ f: AVCaptureDevice.Format) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let pf = fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription))
        let fps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        let photos = f.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" }.joined(separator: ",")
        return "video \(d.width)x\(d.height) \(pf) \(Int(fps))fps, foto [\(photos)]\(f.isHighestPhotoQualitySupported ? " HQ" : "")"
    }

    private func logFormats(_ dev: AVCaptureDevice) {
        log("Formati disponibili (\(dev.formats.count)):")
        for (i, f) in dev.formats.enumerated() {
            log("  [\(i)] \(describe(f))\(f == dev.activeFormat ? "  ← ATTIVO" : "")")
        }
    }

    private func applyMaxDimensions() {
        guard let dev = device, let best = sortedDims(dev.activeFormat).last else { return }
        photoOutput.maxPhotoDimensions = best.cm
        log("maxPhotoDimensions impostato a \(best.label)")
    }

    private func logOutput() {
        let o = photoOutput
        log("Uscita foto: codec \(o.availablePhotoCodecTypes.map(\.rawValue)), ProRAW supportato \(o.isAppleProRAWSupported) attivo \(o.isAppleProRAWEnabled), RAW \(o.availableRawPhotoPixelFormatTypes.map(fourCC))")
        log("Uscita foto: qualità max \(o.maxPhotoQualityPrioritization.rawValue) (3 = quality), zero shutter lag \(o.isZeroShutterLagSupported)/\(o.isZeroShutterLagEnabled), responsive \(o.isResponsiveCaptureSupported)/\(o.isResponsiveCaptureEnabled), maxPhotoDimensions \(Dim(o.maxPhotoDimensions).label)")
    }

    /// Il lettore di QR usa la fotocamera per conto suo: nel frattempo fermiamo la nostra sessione.
    func setPaused(_ paused: Bool) {
        sessionQueue.async {
            guard self.configured else { return }
            if paused && self.session.isRunning {
                self.session.stopRunning()
                log("Fotocamera in pausa (lettore QR)")
            } else if !paused && !self.session.isRunning {
                self.session.startRunning()
                log("Fotocamera ripresa")
            }
        }
    }

    // MARK: - Modalità (ProRAW va attivato sull'uscita)

    private func modeChanged() {
        let wantRaw = mode == .proRaw
        isReady = false
        statusText = "Riconfiguro…"
        sessionQueue.async {
            if wantRaw && !self.photoOutput.isAppleProRAWSupported {
                log("ProRAW non supportato in questa configurazione")
                DispatchQueue.main.async { self.mode = .jpeg }
            } else if self.photoOutput.isAppleProRAWEnabled != wantRaw {
                let t = CACurrentMediaTime()
                self.photoOutput.isAppleProRAWEnabled = wantRaw
                log("ProRAW \(wantRaw ? "attivato" : "disattivato") in \(seconds(CACurrentMediaTime() - t))")
                self.applyMaxDimensions()
                self.logOutput()
            }
            DispatchQueue.main.async {
                self.isReady = true
                self.statusText = "Pronta"
            }
        }
    }

    // MARK: - Messa a fuoco ed esposizione

    /// Tocco sull'anteprima: mette a fuoco ed espone su quel punto (una volta).
    func focus(at devicePoint: CGPoint) {
        DispatchQueue.main.async { self.isLocked = false }
        sessionQueue.async {
            guard let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                if dev.isFocusPointOfInterestSupported && dev.isFocusModeSupported(.autoFocus) {
                    dev.focusPointOfInterest = devicePoint
                    dev.focusMode = .autoFocus
                }
                if dev.isExposurePointOfInterestSupported && dev.isExposureModeSupported(.autoExpose) {
                    dev.exposurePointOfInterest = devicePoint
                    dev.exposureMode = .autoExpose
                }
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    dev.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                dev.unlockForConfiguration()
                log(String(format: "Messa a fuoco sul punto (%.2f, %.2f)", devicePoint.x, devicePoint.y))
            } catch {
                log("ERRORE messa a fuoco: \(error)")
            }
        }
    }

    /// Blocca fuoco, esposizione e bilanciamento del bianco (il tavolo è fermo).
    func setLocked(_ locked: Bool) {
        sessionQueue.async {
            guard let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                if locked {
                    if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
                    if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
                    if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
                } else {
                    dev.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    dev.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                    if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                    if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
                }
                dev.unlockForConfiguration()
                log(locked
                    ? "Bloccati fuoco/esposizione/bianco: \(self.exposureDescription(dev))"
                    : "Sbloccati fuoco/esposizione/bianco (automatici continui)")
                DispatchQueue.main.async { self.isLocked = locked }
            } catch {
                log("ERRORE blocco: \(error)")
            }
        }
    }

    private func exposureDescription(_ dev: AVCaptureDevice) -> String {
        let shutter = dev.exposureDuration.seconds
        let shutterText = shutter > 0 ? "1/\(Int((1 / shutter).rounded())) s" : "?"
        return String(format: "fuoco %.2f · ISO %.0f · ", dev.lensPosition, dev.iso) + shutterText
    }

    func refreshLive() {
        guard let dev = device else { return }
        var text = exposureDescription(dev)
        if dev.isAdjustingFocus || dev.isAdjustingExposure { text += " · regolo…" }
        text += " · \(ProcessInfo.processInfo.thermalState.italian)"
        if text != liveInfo { liveInfo = text }
    }

    // MARK: - Scatto

    func capture() {
        guard isReady, !isCapturing, let params = currentParams() else { return }
        isCapturing = true
        statusText = "Scatto…"
        let status = deviceStatus()
        sessionQueue.async {
            self.performCapture(params, light: false) { result in
                DispatchQueue.main.async {
                    self.isCapturing = false
                    self.statusText = "Pronta"
                    if let result {
                        log("   (\(status))")
                        self.lastResult = result
                    }
                }
            }
        }
    }

    /// Più scatti di fila per misurare tempi e riscaldamento. Salva solo l'ultimo.
    func captureSeries(count: Int) {
        guard isReady, !isCapturing, let params = currentParams() else { return }
        isCapturing = true
        log("Serie di \(count) scatti \(params.mode.rawValue) \(params.dim.label) — inizio, \(deviceStatus())")
        let start = CACurrentMediaTime()
        var index = 0
        func next() {
            index += 1
            let last = index == count
            DispatchQueue.main.async { self.statusText = "Serie: scatto \(index)/\(count)…" }
            sessionQueue.async {
                self.performCapture(params, light: !last) { result in
                    if !last, result != nil {
                        next()
                        return
                    }
                    DispatchQueue.main.async {
                        let total = CACurrentMediaTime() - start
                        log("Serie finita: \(index) scatti in \(seconds(total)), media \(seconds(total / Double(index))) a scatto, \(deviceStatus())")
                        self.isCapturing = false
                        self.statusText = "Pronta"
                        if let result { self.lastResult = result }
                    }
                }
            }
        }
        next()
    }

    /// Scatto per Tabletop: sempre JPEG alla massima risoluzione, qualità predefinita, senza salvare.
    /// Da chiamare sul main thread; `completion` arriva su una coda qualsiasi.
    func captureForUpload(completion: @escaping (Data?) -> Void) {
        guard isReady, let dim = availableDims.last else {
            log("Fotocamera non pronta: scatto per Tabletop annullato")
            completion(nil)
            return
        }
        let params = CaptureParams(mode: .jpeg, dim: dim, jpegQuality: nil)
        motion.snapshotForUpload()
        sessionQueue.async {
            self.performCapture(params, light: true) { completion($0?.data) }
        }
    }

    private func currentParams() -> CaptureParams? {
        guard let dim = selectedDim else { return nil }
        return CaptureParams(mode: mode, dim: dim, jpegQuality: jpegQuality)
    }

    private func makeSettings(_ p: CaptureParams) -> AVCapturePhotoSettings? {
        let settings: AVCapturePhotoSettings
        switch p.mode {
        case .jpeg, .heic:
            let codec: AVVideoCodecType = p.mode == .jpeg ? .jpeg : .hevc
            guard photoOutput.availablePhotoCodecTypes.contains(codec) else {
                log("ERRORE: codec \(codec.rawValue) non disponibile")
                return nil
            }
            var format: [String: Any] = [AVVideoCodecKey: codec]
            if let q = p.jpegQuality {
                format[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: q]
            }
            settings = AVCapturePhotoSettings(format: format)
            settings.photoQualityPrioritization = .quality
        case .proRaw:
            guard photoOutput.isAppleProRAWEnabled,
                  let raw = photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) else {
                log("ERRORE: ProRAW non disponibile")
                return nil
            }
            settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
        }
        // Non si può chiedere più di quanto impostato sull'uscita (altrimenti l'app va in crash).
        let outMax = Dim(photoOutput.maxPhotoDimensions)
        settings.maxPhotoDimensions = p.dim.pixels <= outMax.pixels ? p.dim.cm : outMax.cm
        return settings
    }

    /// Da chiamare sulla sessionQueue.
    private func performCapture(_ p: CaptureParams, light: Bool, completion: @escaping (CaptureResult?) -> Void) {
        guard let settings = makeSettings(p) else {
            completion(nil)
            return
        }
        let id = settings.uniqueID
        let processor = PhotoCaptureProcessor { [weak self] proc in
            guard let self else { return }
            self.sessionQueue.async { self.inFlight[id] = nil }
            self.processingQueue.async {
                completion(self.process(proc, params: p, light: light))
            }
        }
        inFlight[id] = processor
        processor.t0 = CACurrentMediaTime()
        photoOutput.capturePhoto(with: settings, delegate: processor)
    }

    private func process(_ proc: PhotoCaptureProcessor, params p: CaptureParams, light: Bool) -> CaptureResult? {
        if let error = proc.error {
            log("ERRORE scatto: \(error)")
            return nil
        }
        guard let captured = proc.data else {
            log("ERRORE: nessun dato dalla foto")
            return nil
        }
        var info: [String] = []
        var timing = "otturatore \(seconds(proc.tShutter - proc.t0)), foto pronta \(seconds(proc.tProcessed - proc.t0)), fine \(seconds(proc.tEnd - proc.t0))"

        var mainData = captured
        var files: [(Data, String)] = []
        let stamp = Self.fileStamp()
        switch p.mode {
        case .jpeg:
            files.append((captured, "\(stamp).jpg"))
        case .heic:
            files.append((captured, "\(stamp).heic"))
        case .proRaw:
            if let raw = imageInfo(captured) {
                info.append("DNG: \(raw.width)×\(raw.height), \(megabytes(captured.count))")
            }
            files.append((captured, "\(stamp).dng"))
            let t = CACurrentMediaTime()
            guard let jpeg = convertRawToJpeg(captured, quality: p.jpegQuality ?? 0.92) else {
                log("ERRORE conversione ProRAW → JPEG")
                return nil
            }
            timing += ", conversione JPEG \(seconds(CACurrentMediaTime() - t))"
            mainData = jpeg
            files.append((jpeg, "\(stamp).jpg"))
        }

        let mi = imageInfo(mainData)
        let dimText = mi.map { "\($0.width)×\($0.height)" } ?? "?"
        let mp = mi.map { String(format: "%.1f MP", Double($0.width * $0.height) / 1_000_000) } ?? ""
        let summary = "\(p.mode.rawValue) \(dimText) \(mp), \(megabytes(mainData.count))"
        info.insert("Foto: \(summary) (orientamento EXIF \(mi?.orientation ?? 0))", at: 0)
        info.append("Richiesto: \(p.dim.label), qualità JPEG \(p.jpegQuality.map { String($0) } ?? "predefinita")")
        if let r = proc.resolved {
            info.append("Dimensioni dichiarate da iOS: \(Dim(r.photoDimensions).label)\(r.rawPhotoDimensions.width > 0 ? ", RAW \(Dim(r.rawPhotoDimensions).label)" : "")")
        }
        info.append("Tempi: \(timing)")
        log("Scatto \(summary): \(timing)")

        if light {
            return CaptureResult(title: summary, info: info, files: [], data: mainData, thumbnail: nil, crop: nil)
        }

        var urls: [URL] = []
        for (data, name) in files {
            let url = photosDirectory().appendingPathComponent(name)
            do {
                try data.write(to: url)
                urls.append(url)
            } catch {
                log("ERRORE salvataggio \(name): \(error)")
            }
        }
        let thumb = makeThumbnail(mainData, maxPixels: 1600)
        let crop = makeCenterCrop(mainData, size: 1200, orientation: mi?.orientation ?? 1)
        return CaptureResult(title: summary, info: info, files: urls, data: mainData, thumbnail: thumb, crop: crop)
    }

    private func convertRawToJpeg(_ data: Data, quality: Double) -> Data? {
        guard let filter = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image"),
              let image = filter.outputImage,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(of: image, colorSpace: srgb, options: [key: quality])
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

/// Riceve i callback di un singolo scatto e misura i tempi.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    var t0 = 0.0
    var tShutter = 0.0
    var tProcessed = 0.0
    var tEnd = 0.0
    var data: Data?
    var error: Error?
    var resolved: AVCaptureResolvedPhotoSettings?
    private let done: (PhotoCaptureProcessor) -> Void

    init(done: @escaping (PhotoCaptureProcessor) -> Void) {
        self.done = done
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        resolved = resolvedSettings
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        tShutter = CACurrentMediaTime()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        tProcessed = CACurrentMediaTime()
        if let error {
            self.error = error
            return
        }
        data = photo.fileDataRepresentation()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        tEnd = CACurrentMediaTime()
        if let error, self.error == nil { self.error = error }
        done(self)
    }
}
