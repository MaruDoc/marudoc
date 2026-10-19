import Foundation
import AppKit
import PDFKit
import EnsoShared
import EnsoDoc
import EnsoCore
import EnsoOffice

// ensocli — runs MaruDoc's engine from the command line.
//   ensocli run <action> <file>...       e.g. ensocli run to.docx report.pdf
//   ensocli selftest <output-dir>        builds fixtures and checks every action

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else {
    print("usage: ensocli run <action> <file>... | ensocli selftest <dir>")
    exit(2)
}

func runAction(_ action: String, _ files: [URL]) async throws -> EngineResult {
    let engine = Engine()
    return try await engine.run(action, files: files)
}

switch command {
case "run":
    let rest = Array(args.dropFirst())
    guard rest.count >= 2 else { print("usage: ensocli run <action> <file>..."); exit(2) }
    let files = rest.dropFirst().map { URL(fileURLWithPath: $0) }
    var done = false
    Task {
        do {
            let t0 = Date()
            let r = try await runAction(rest[0], files)
            print("\(r.message) [\(String(format: "%.2fs", Date().timeIntervalSince(t0)))] \(r.detail ?? "")")
            for o in r.outputs { print("  -> \(o.path)") }
            if let text = r.clipboardText { print(text.prefix(400)) }
        } catch {
            print("ERROR: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        done = true
    }
    // Keep the main run loop alive: some readers (HTML, RTF) hop to the main actor.
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
case "docx-roundtrip":
    // ensocli docx-roundtrip <in.docx> <out-dir>: unchanged save + one edited save, plus layout facts.
    let rest = Array(args.dropFirst())
    let input = URL(fileURLWithPath: rest[0]), outDir = URL(fileURLWithPath: rest[1])
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    do {
        let t0 = Date()
        let doc = try DocxDocument(url: input)
        let base = input.deletingPathExtension().lastPathComponent
        print("loaded \(input.lastPathComponent) in \(String(format: "%.2fs", Date().timeIntervalSince(t0))): page \(Int(doc.page.size.width))x\(Int(doc.page.size.height)) margins T\(Int(doc.page.margins.top)) L\(Int(doc.page.margins.left)) B\(Int(doc.page.margins.bottom)) R\(Int(doc.page.margins.right)) pitch \(doc.page.linePitch.map { String(Int($0)) } ?? "-") chars \(doc.attributed.length) tracked=\(doc.hasTrackedChanges)")
        let same = outDir.appendingPathComponent(base + "-same.docx")
        try doc.save(doc.attributed, to: same)
        let edited = NSMutableAttributedString(attributedString: doc.attributed)
        let ns = edited.string as NSString
        // Append to the first paragraph that has visible text.
        var loc = 0
        while loc < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let t = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, edited.attribute(.docxRaw, at: r.location, effectiveRange: nil) == nil {
                let end = NSMaxRange(r) - 1
                let attrs = edited.attributes(at: max(r.location, end - 1), effectiveRange: nil)
                edited.insert(NSAttributedString(string: "【追記テスト】", attributes: attrs), at: end)
                break
            }
            loc = NSMaxRange(r)
        }
        let ed = outDir.appendingPathComponent(base + "-edited.docx")
        try doc.save(edited, to: ed)
        print("saved \(same.lastPathComponent), \(ed.lastPathComponent)")
    } catch {
        print("ERROR: \(error)")
    }
case "selftest":
    let dir = URL(fileURLWithPath: args.dropFirst().first ?? NSTemporaryDirectory() + "marudoc-selftest")
    var done = false
    var failed = 0
    Task {
        failed = await SelfTest(root: dir).runAll()
        done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    exit(failed == 0 ? 0 : 1)
default:
    print("unknown command \(command)")
    exit(2)
}
