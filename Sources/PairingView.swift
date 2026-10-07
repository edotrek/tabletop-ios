import SwiftUI

struct PairingView: View {
    @EnvironmentObject var link: TabletopLink
    @EnvironmentObject var camera: CameraController
    @State private var showScanner = false
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var server = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Nel pannello di Board Beam apri **Collega reflex** e inquadra il **QR piccolo** \"per l'app Board Beam Cam\" (vale 10 minuti).")
                    Button {
                        camera.setPaused(true)
                        showScanner = true
                    } label: {
                        Label("Scansiona il QR", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                    }
                } header: {
                    Text("Come fare")
                } footer: {
                    Text("In alternativa: copia il link del pulsante \"Scarica l'agente della reflex\", fallo arrivare sull'iPhone e incollalo qui sotto.")
                }
                .font(.callout)

                Section("Codice o link") {
                    TextField("Codice o link di abbinamento", text: $code, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button {
                        code = UIPasteboard.general.string ?? ""
                    } label: {
                        Label("Incolla", systemImage: "doc.on.clipboard")
                    }
                }

                Section("Server") {
                    TextField(TabletopLink.defaultServer, text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Se incolli il link completo, il server viene preso dal link.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await pair() }
                    } label: {
                        HStack {
                            Text("Collega")
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(working || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Collega a Board Beam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
            .onAppear {
                if server.isEmpty { server = link.server }
            }
            .sheet(isPresented: $showScanner, onDismiss: { camera.setPaused(false) }) {
                QRScannerView { text in
                    code = text
                    Task { await pair() }
                }
            }
        }
    }

    private func pair() async {
        working = true
        error = nil
        do {
            try await link.pair(input: code, server: server)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }
}
