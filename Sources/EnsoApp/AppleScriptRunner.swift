import Foundation

/// Runs AppleScript in a separate `osascript` process so the main thread (which also services the
/// mouse event tap) never waits on Finder or on a permission prompt.
///
/// `source` must be fixed script text. Anything that varies (file paths, numbers) goes through `arguments`,
/// which osascript hands to the script's `on run argv` handler as plain text, never as script source.
enum AppleScriptRunner {
    private static let queue = DispatchQueue(label: "marudoc.applescript")

    static func run(_ source: String, arguments: [String] = [], completion: ((Bool, String) -> Void)? = nil) {
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source, "--"] + arguments
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                DispatchQueue.main.async { completion?(false, error.localizedDescription) }
                return
            }
            p.waitUntilExit()
            let text = String(decoding: (p.terminationStatus == 0 ? out : err).fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async { completion?(ok, text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}
