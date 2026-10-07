import SwiftUI

struct ResultView: View {
    let result: CaptureResult
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let thumb = result.thumbnail {
                        Image(uiImage: thumb).resizable().scaledToFit()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(result.info.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout)
                        }
                    }
                    .textSelection(.enabled)

                    if let crop = result.crop {
                        Text("Ritaglio centrale al 100% (1 pixel foto = 1 pixel schermo)")
                            .font(.headline)
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: crop)
                                .resizable()
                                .frame(width: crop.size.width / displayScale, height: crop.size.height / displayScale)
                        }
                        .frame(height: 360)
                    }

                    Text("File (anche nell'app File → Sul mio iPhone → Board Beam Cam → Foto)")
                        .font(.headline)
                    ForEach(result.files, id: \.self) { url in
                        ShareLink(item: url) {
                            Label("Condividi \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Risultato")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }
}
