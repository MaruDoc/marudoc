import AppKit
import PDFKit
import EnsoShared
import EnsoCore

/// The two small questions behind 「ページ範囲を指定…」 and 「N ページごと…」: a text field in an alert, asked again
/// with the reason until the input is valid or the user cancels.
enum SplitPrompt {

    /// Page ranges such as "1-3, 5, 8-10", checked against the page count. Nil when cancelled.
    static func ranges(pageCount: Int) -> String? {
        ask(title: L("ページ範囲を指定して分割"),
            info: String(format: L("カンマで区切った 1 つずつが 1 つのファイルになります。例: 1-3, 5, 8-10 (全 %d ページ)"), pageCount),
            placeholder: "1-3, 5, 8-10", button: L("分割")) { text in
            do { _ = try PageRanges.parse(text, pageCount: pageCount); return nil } catch { return ErrorText.describe(error) }
        }
    }

    /// Pages per file. Nil when cancelled.
    static func every(pageCount: Int) -> Int? {
        let text = ask(title: L("N ページごとに分割"),
                       info: String(format: L("1 つのファイルに入れるページ数を入力してください (全 %d ページ)"), pageCount),
                       placeholder: "10", button: L("分割")) { text in
            do { _ = try PageRanges.parseCount(text); return nil } catch { return ErrorText.describe(error) }
        }
        return text.flatMap { try? PageRanges.parseCount($0) }
    }

    private static func ask(title: String, info: String, placeholder: String, button: String, validate: (String) -> String?) -> String? {
        var error: String?
        var previous = ""
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = error.map { $0 + "\n\n" + info } ?? info
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = placeholder
            field.stringValue = previous
            alert.accessoryView = field
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: L("キャンセル"))
            alert.window.initialFirstResponder = field
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            previous = field.stringValue
            if let problem = validate(previous) { error = problem; continue }
            return previous
        }
    }
}
