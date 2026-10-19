import Foundation
import os

/// Small file logger (~/Library/Logs/MaruDoc/marudoc.log) plus unified logging. Never logs file contents.
enum Log {
    private static let logger = Logger(subsystem: "app.marudoc.MaruDoc", category: "app")
    private static let queue = DispatchQueue(label: "marudoc.log")
    private static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MaruDoc", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("marudoc.log")
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO  " + message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR " + message)
    }

    private static func write(_ line: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("\(stamp) \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: fileURL) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
