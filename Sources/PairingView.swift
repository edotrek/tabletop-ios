import SwiftUI

struct PairingView: View {
    @EnvironmentObject var link: TabletopLink
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var server = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("1. Nel pannello di Tabletop apri **Collega reflex**.")
                    Text("2. Copia il link del pulsante **Scarica l'agente della reflex** (tasto destro → Copia indirizzo link) e fallo arrivare sull'iPhone, per esempio mandandotelo in chat.")
                    Text("3. Incollalo qui sotto entro 10 minuti e tocca **Collega**.")
                } header: {
                    Text("Come fare")
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
            .navigationTitle("Collega a Tabletop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
            .onAppear {
                if server.isEmpty { server = link.server }
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
