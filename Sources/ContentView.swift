import SwiftUI

struct ContentView: View {
    @EnvironmentObject var camera: CameraController
    @EnvironmentObject var link: TabletopLink
    @EnvironmentObject var streamer: LiveStreamer
    @State private var showLog = false
    @State private var showPairing = false
    @State private var blackScreen = false
    @State private var showWakeHint = false
    @State private var savedBrightness: CGFloat?
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            linkBar

            VStack(spacing: 2) {
                Text(link.isSending ? "Scatto e invio a Tabletop…" : camera.statusText).font(.headline)
                Text(camera.liveInfo).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if link.isPaired {
                    Text("Video: \(streamer.status)").font(.caption).foregroundStyle(streamer.isLive ? .green : .secondary)
                }
                if link.state == .online {
                    if let last = link.lastUpload {
                        Text(last).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if link.autoCapture {
                        Text(camera.motionInfo).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }

            CameraPreview(camera: camera, active: !blackScreen)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    if camera.isCapturing || link.isSending {
                        ProgressView().controlSize(.large).tint(.white)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if camera.isLocked {
                        Label("AF/AE bloccati", systemImage: "lock.fill")
                            .font(.caption.bold())
                            .padding(6)
                            .background(.yellow, in: Capsule())
                            .foregroundStyle(.black)
                            .padding(8)
                    }
                }

            Picker("Modalità", selection: $camera.mode) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(camera.isCapturing)
            .padding(.horizontal)

            HStack {
                Menu {
                    Picker("Risoluzione", selection: $camera.selectedDim) {
                        ForEach(camera.availableDims, id: \.self) { dim in
                            Text(dim.label).tag(Optional(dim))
                        }
                    }
                } label: {
                    Label(camera.selectedDim?.label ?? "—", systemImage: "aspectratio")
                }
                Spacer()
                Menu {
                    Picker("Qualità JPEG", selection: $camera.jpegQuality) {
                        Text("Predefinita").tag(Double?.none)
                        ForEach([0.8, 0.9, 0.95, 1.0], id: \.self) { q in
                            Text(String(format: "%.2f", q)).tag(Double?.some(q))
                        }
                    }
                } label: {
                    Label(camera.jpegQuality.map { String(format: "Q %.2f", $0) } ?? "Q predef.", systemImage: "slider.horizontal.3")
                }
            }
            .font(.subheadline)
            .padding(.horizontal)

            HStack {
                Button {
                    camera.setLocked(!camera.isLocked)
                } label: {
                    Label(camera.isLocked ? "Sblocca" : "Blocca AF/AE",
                          systemImage: camera.isLocked ? "lock.open" : "lock")
                }
                .frame(maxWidth: .infinity)

                Button {
                    if link.isPaired {
                        link.send(reason: "request")
                    } else {
                        camera.capture()
                    }
                } label: {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .background(Circle().fill(camera.isReady && !camera.isCapturing ? Color.white : Color.gray).padding(8))
                        .frame(width: 78, height: 78)
                }
                .disabled(!camera.isReady || camera.isCapturing)

                Menu {
                    Button("Mostra log") { showLog = true }
                    Button("Schermo nero (risparmia batteria)") { setBlackScreen(true) }
                    Section("Prove (la foto resta sul telefono)") {
                        Button("Scatto di prova") { camera.capture() }
                        Button("Diagnosi allineamento foto/video") { camera.diagnoseAlignment() }
                        Button("Serie da 5 scatti") { camera.captureSeries(count: 5) }
                        Button("Serie da 20 scatti") { camera.captureSeries(count: 20) }
                    }
                } label: {
                    Label("Altro", systemImage: "ellipsis.circle")
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 8)
        }
        .overlay {
            if blackScreen {
                blackOverlay
            }
        }
        .statusBarHidden(blackScreen)
        .persistentSystemOverlays(blackScreen ? .hidden : .automatic)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            camera.start()
        }
        .onReceive(timer) { _ in camera.refreshLive() }
        .sheet(item: $camera.lastResult) { result in
            ResultView(result: result)
        }
        .sheet(isPresented: $showLog) {
            LogView()
        }
        .sheet(isPresented: $showPairing) {
            PairingView()
        }
    }

    /// Schermo nero: sull'OLED i pixel neri sono spenti. Foto, video e scatti automatici continuano.
    private var blackOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .overlay {
                if showWakeHint {
                    Text("Tocca due volte per riaccendere")
                        .font(.footnote)
                        .foregroundStyle(.gray)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { setBlackScreen(false) }
            .onTapGesture {
                showWakeHint = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showWakeHint = false }
            }
    }

    private func setBlackScreen(_ on: Bool) {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
        if on {
            savedBrightness = screen?.brightness
            screen?.brightness = 0
            log("Schermo nero attivato")
        } else {
            if let savedBrightness { screen?.brightness = savedBrightness }
            log("Schermo riacceso")
        }
        showWakeHint = on
        if on {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showWakeHint = false }
        }
        blackScreen = on
    }

    private var linkColor: Color {
        switch link.state {
        case .online: return .green
        case .connecting: return .yellow
        case .offline: return .red
        case .unpaired: return .gray
        }
    }

    private var linkText: String {
        switch link.state {
        case .unpaired: return "Non collegata a Tabletop"
        case .connecting: return "Collegamento a Tabletop…"
        case .online: return "Collegata a Tabletop · \(link.sentCount) foto inviate"
        case .offline(let message): return "Tabletop non raggiungibile: \(message)"
        }
    }

    private var linkBar: some View {
        HStack(spacing: 8) {
            Circle().fill(linkColor).frame(width: 10, height: 10)
            Text(linkText).font(.footnote).lineLimit(2)
            Spacer()
            if link.isPaired {
                Menu {
                    Toggle("Scatto automatico a fine mossa", isOn: $link.autoCapture)
                    Toggle("Trasmetti video", isOn: $streamer.enabled)
                    Picker("Fluidità video", selection: $streamer.fps) {
                        ForEach(LiveStreamer.fpsOptions, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .pickerStyle(.menu)
                    Button("Invia una foto ora") { link.send(reason: "request") }
                    Button("Scollega", role: .destructive) { link.unpair(reason: "scelto dall'utente") }
                } label: {
                    Image(systemName: "gearshape").font(.title3)
                }
            } else {
                Button("Collega") { showPairing = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }
}
