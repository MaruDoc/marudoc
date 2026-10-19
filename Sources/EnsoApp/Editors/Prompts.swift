import AppKit
import SwiftUI
import PDFKit
import ImageIO
import EnsoShared
import EnsoCore

/// Small one-question panels (password, watermark text, image size).
enum Prompts {

    static func host<V: View>(_ view: V, title: String, width: CGFloat = 340) -> EditorPanel {
        let panel = EditorPanel(size: NSSize(width: width, height: 200), title: title)
        panel.styleMask.remove(.resizable)
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        return panel
    }

    // MARK: Password

    static func password(url: URL, coordinator: EditorCoordinator) -> EditorPanel {
        let locked = PDFDocument(url: url)?.isEncrypted ?? false
        var panelRef: EditorPanel?
        let view = PasswordView(fileName: url.lastPathComponent, removing: locked) { pw in
            guard let p = panelRef else { return }
            var o = EngineOptions(); o.password = pw
            coordinator.perform(locked ? Act.pdfDecrypt : Act.pdfEncrypt, urls: [url], options: o, from: p)
        } cancel: { panelRef?.close() }
        let panel = host(view, title: L("パスワード"))
        panelRef = panel
        return panel
    }

    struct PasswordView: View {
        var fileName: String
        var removing: Bool
        var done: (String) -> Void
        var cancel: () -> Void
        @LocalState private var pw = ""
        @LocalState private var confirm = ""

        var valid: Bool { removing ? !pw.isEmpty : (!pw.isEmpty && pw == confirm) }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(removing ? L("パスワードを解除") : L("パスワードを設定")).font(.headline)
                Text(removing ? String(format: L("「%@」のパスワードを入力すると、パスワードなしの複製を作ります。"), fileName)
                              : String(format: L("「%@」を開くときにパスワードを求める複製を作ります。"), fileName))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField(L("パスワード"), text: $pw).textFieldStyle(.roundedBorder)
                if !removing {
                    SecureField(L("確認のためもう一度"), text: $confirm).textFieldStyle(.roundedBorder)
                    if !confirm.isEmpty && pw != confirm {
                        Text(L("一致しません")).font(.caption).foregroundStyle(.red)
                    }
                }
                HStack {
                    Spacer()
                    Button(L("キャンセル"), action: cancel).keyboardShortcut(.cancelAction)
                    Button(removing ? L("解除") : L("設定")) { done(pw) }.keyboardShortcut(.defaultAction).disabled(!valid)
                }
            }
            .padding(24)
        }
    }

    // MARK: Watermark

    static func watermark(urls: [URL], coordinator: EditorCoordinator) -> EditorPanel {
        var panelRef: EditorPanel?
        let view = TextPromptView(title: L("透かしを入れる"), message: L("各ページの中央に斜めに薄く入れます。"),
                                  placeholder: L("例: 社外秘"), initial: L("社外秘"), confirm: L("入れる")) { text in
            guard let p = panelRef else { return }
            var o = EngineOptions(); o.watermarkText = text
            coordinator.perform(Act.pdfWatermark, urls: urls, options: o, from: p)
        } cancel: { panelRef?.close() }
        let panel = host(view, title: L("透かし"))
        panelRef = panel
        return panel
    }

    struct TextPromptView: View {
        var title: String
        var message: String
        var placeholder: String
        var initial: String
        var confirm: String
        var done: (String) -> Void
        var cancel: () -> Void
        @LocalState private var text = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
                TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(L("キャンセル"), action: cancel).keyboardShortcut(.cancelAction)
                    Button(confirm) { done(text) }.keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
            .onAppear { text = initial }
        }
    }

    // MARK: Resize

    static func resize(urls: [URL], coordinator: EditorCoordinator) -> EditorPanel {
        var w = 0, h = 0
        if let first = urls.first, let src = CGImageSourceCreateWithURL(first as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            w = p[kCGImagePropertyPixelWidth] as? Int ?? 0
            h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
            if let o = p[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        }
        var panelRef: EditorPanel?
        let view = ResizeView(originalWidth: w, originalHeight: h) { longEdge in
            guard let p = panelRef else { return }
            var o = EngineOptions(); o.resizeLongEdge = longEdge
            coordinator.perform("img.resize.custom", urls: urls, options: o, from: p)
        } cancel: { panelRef?.close() }
        let panel = host(view, title: L("サイズ"))
        panelRef = panel
        return panel
    }

    struct ResizeView: View {
        var originalWidth: Int
        var originalHeight: Int
        var done: (Int) -> Void
        var cancel: () -> Void
        @LocalState private var width = ""
        @LocalState private var height = ""

        private var aspect: Double { originalHeight > 0 ? Double(originalWidth) / Double(originalHeight) : 1 }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("サイズを指定")).font(.headline)
                Text(String(format: L("元のサイズ: %d × %d px。縦横の比率は保ちます。"), originalWidth, originalHeight))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField(L("幅"), text: $width).textFieldStyle(.roundedBorder).frame(width: 90)
                        .onChange(of: width) { _, v in
                            if let n = Int(v), originalWidth > 0 { let hh = String(Int((Double(n) / aspect).rounded())); if hh != height { height = hh } }
                        }
                    Text("×").foregroundStyle(.secondary)
                    TextField(L("高さ"), text: $height).textFieldStyle(.roundedBorder).frame(width: 90)
                        .onChange(of: height) { _, v in
                            if let n = Int(v), originalHeight > 0 { let ww = String(Int((Double(n) * aspect).rounded())); if ww != width { width = ww } }
                        }
                    Text("px").foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(L("キャンセル"), action: cancel).keyboardShortcut(.cancelAction)
                    Button(L("サイズ変更")) {
                        let w = Int(width) ?? 0, h = Int(height) ?? 0
                        done(max(w, h))
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled((Int(width) ?? 0) <= 0)
                }
            }
            .padding(24)
            .onAppear {
                width = String(originalWidth / 2)
                height = String(originalHeight / 2)
            }
        }
    }
}
