import SwiftUI

struct ContentView: View {
    @EnvironmentObject var camera: CameraController
    @State private var showLog = false
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(camera.statusText).font(.headline)
                Text(camera.liveInfo).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            CameraPreview(camera: camera)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    if camera.isCapturing {
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
                    camera.capture()
                } label: {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .background(Circle().fill(camera.isReady && !camera.isCapturing ? Color.white : Color.gray).padding(8))
                        .frame(width: 78, height: 78)
                }
                .disabled(!camera.isReady || camera.isCapturing)

                Menu {
                    Button("Mostra log") { showLog = true }
                    Section("Test") {
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
    }
}
