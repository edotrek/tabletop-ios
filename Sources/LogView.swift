import SwiftUI

struct LogView: View {
    @ObservedObject private var store = LogStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                    .textSelection(.enabled)
                }
                .onAppear { proxy.scrollTo(store.lines.count - 1, anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.green)
                    }
                    HStack {
                        Button {
                            UIPasteboard.general.string = store.text
                            message = "Log copiato: incollalo nella chat."
                        } label: {
                            Label("Copia log", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Menu {
                            Button("Copia log dell'avvio precedente") {
                                UIPasteboard.general.string = store.previousText ?? ""
                                message = store.previousText == nil ? "Nessun log precedente." : "Log precedente copiato."
                            }
                            Button("Cancella log", role: .destructive) { store.clear() }
                        } label: {
                            Label("Altro", systemImage: "ellipsis.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }
}
