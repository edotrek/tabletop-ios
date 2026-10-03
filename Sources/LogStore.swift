import Foundation

/// Log visibile nell'app (non abbiamo la console di Xcode).
/// Viene anche scritto su file, così dopo un crash si può leggere il log precedente.
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var lines: [String] = []

    let fileURL: URL
    let previousFileURL: URL
    private let fileQueue = DispatchQueue(label: "log.file")
    private let formatter: DateFormatter

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("log.txt")
        previousFileURL = docs.appendingPathComponent("log-precedente.txt")
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        try? FileManager.default.removeItem(at: previousFileURL)
        try? FileManager.default.moveItem(at: fileURL, to: previousFileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        let url = fileURL
        fileQueue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write((line + "\n").data(using: .utf8)!)
                try? handle.close()
            }
        }
        DispatchQueue.main.async { self.lines.append(line) }
    }

    var text: String { lines.joined(separator: "\n") }

    var previousText: String? { try? String(contentsOf: previousFileURL, encoding: .utf8) }

    func clear() {
        lines.removeAll()
        let url = fileURL
        fileQueue.async { try? Data().write(to: url) }
    }
}

func log(_ message: String) {
    LogStore.shared.log(message)
}
