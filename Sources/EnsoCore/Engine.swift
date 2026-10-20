import Foundation
import PDFKit
import EnsoShared
import EnsoDoc

public struct EngineOptions: Sendable {
    /// Resolution for PDF -> image and PDF -> PowerPoint.
    public var imageDPI: Double = 200
    public var ocrLanguages: [String] = ["ja-JP", "en-US"]
    public var password: String?
    public var ownerPassword: String?
    public var watermarkText: String?
    /// Explicit size for `Act.imgResizeCustom`: long edge in pixels.
    public var resizeLongEdge: Int?
    /// Page ranges for "pdf.split.ranges", as typed ("1-3, 5, 8-10").
    public var splitRanges: String?
    /// Pages per file for "pdf.split.every".
    public var splitEvery: Int?
    public init() {}
}

public struct EngineResult: Sendable {
    public var outputs: [URL] = []
    public var backups: [SafeWrite.Backup] = []
    public var message: String
    public var detail: String?
    /// Text the app should put on the clipboard.
    public var clipboardText: String?
    public init(message: String) { self.message = message }
}

public enum EngineError: LocalizedError {
    case nothingToDo
    case unsupported(String)
    case failed(String)
    case cancelled
    case noGain

    public var errorDescription: String? {
        switch self {
        case .nothingToDo: return L("対象のファイルがありません")
        case .unsupported(let s): return L("この組み合わせには対応していません") + " (\(s))"
        case .failed(let s): return s
        case .cancelled: return L("キャンセルしました")
        case .noGain: return L("これ以上小さくできませんでした")
        }
    }
}

/// Runs one action on a set of files. Never modifies an input except for the in-place operations
/// (rotate / flip / metadata removal), which keep a backup for undo.
public final class Engine: @unchecked Sendable {
    public var options = EngineOptions()
    public init() {}

    public typealias Progress = @Sendable (Double) -> Void
    public typealias Cancelled = @Sendable () -> Bool

    public func run(_ action: String, files: [URL], progress: @escaping Progress = { _ in }, cancelled: @escaping Cancelled = { false }) async throws -> EngineResult {
        guard !files.isEmpty else { throw EngineError.nothingToDo }
        let files = files.map { $0.standardizedFileURL }

        // Multi-file actions
        switch action {
        case Act.combineToPDF, Act.pdfMerge:
            // The order of `files` is the page order: callers pass the order the user selected them in.
            let out = try PDFOps.merge(files, progress: progress, cancelled: cancelled)
            progress(1)
            var r = EngineResult(message: L("PDF に結合しました"))
            r.outputs = [out]; r.detail = out.lastPathComponent
            return r
        case Act.copyText:
            let text = try await TextExtraction.text(of: files, languages: options.ocrLanguages)
            var r = EngineResult(message: L("テキストをコピーしました"))
            r.clipboardText = text
            r.detail = String(format: L("%d 文字"), text.count)
            return r
        default: break
        }

        // Per-file actions
        var result = EngineResult(message: ActionCatalog.title(for: action))
        var sizeBefore: Int64 = 0, sizeAfter: Int64 = 0
        var failures: [(URL, Error)] = []
        var succeeded = 0
        for (i, file) in files.enumerated() {
            if cancelled() { throw EngineError.cancelled }
            let sub: Progress = { p in progress((Double(i) + p) / Double(files.count)) }
            do {
                // One bad file must not stop the rest of a batch.
                let one = try await runOne(action, file: file, progress: sub, cancelled: cancelled)
                result.outputs += one.outputs
                result.backups += one.backups
                sizeBefore += fileSize(file, backups: one.backups)
                sizeAfter += one.outputs.reduce(0) { $0 + fileSize($1) } + (one.backups.isEmpty ? 0 : fileSize(file))
                succeeded += 1
            } catch EngineError.cancelled {
                throw EngineError.cancelled
            } catch {
                if files.count == 1 { throw error }
                failures.append((file, error))
            }
        }
        if succeeded == 0, let first = failures.first { throw first.1 }
        result.message = doneMessage(action, count: files.count)
        if files.count > 1 {
            result.detail = String(format: L("%d 個のファイル"), succeeded)
        }
        if !failures.isEmpty {
            result.message = String(format: L("%d 件中 %d 件できました"), files.count, succeeded)
            result.detail = "\(failures[0].0.lastPathComponent): \(ErrorText.describe(failures[0].1))"
            return result
        }
        if action.contains(".compress.") || action.hasPrefix("img.resize") {
            result.detail = "\(ByteCountFormatter.string(fromByteCount: sizeBefore, countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: sizeAfter, countStyle: .file))"
        } else if result.detail == nil, let first = result.outputs.first {
            result.detail = first.lastPathComponent
        }
        progress(1)
        return result
    }

    struct OneResult {
        var outputs: [URL] = []
        var backups: [SafeWrite.Backup] = []
    }

    private func runOne(_ action: String, file: URL, progress: @escaping Progress, cancelled: @escaping Cancelled) async throws -> OneResult {
        var r = OneResult()
        let kind = FileKind.of(file)

        if action.hasPrefix("to.") {
            let target = String(action.dropFirst(3))
            r.outputs = try await Converter(options: options).convert(file, kind: kind, to: target, progress: progress, cancelled: cancelled)
            return r
        }

        switch action {
        // PDF
        case Act.pdfRotateRight, Act.pdfRotateLeft:
            r.backups = [try PDFOps.rotate(file, by: action == Act.pdfRotateRight ? 90 : -90)]
        case Act.pdfSplit:
            r.outputs = [try PDFOps.split(file)]
        case Act.pdfSplitRanges:
            r.outputs = [try PDFOps.split(file, ranges: options.splitRanges ?? "", progress: progress, cancelled: cancelled)]
        case Act.pdfSplitEvery:
            guard let n = options.splitEvery else { throw PageRanges.ParseError.badCount }
            r.outputs = [try PDFOps.split(file, every: n, progress: progress, cancelled: cancelled)]
        case Act.pdfCompressLight, Act.pdfCompressStandard, Act.pdfCompressStrong:
            let level: PDFOps.CompressionLevel = action == Act.pdfCompressLight ? .light : action == Act.pdfCompressStandard ? .standard : .strong
            r.outputs = [try PDFOps.compress(file, level: level)]
        case Act.pdfOCR:
            r.outputs = [try PDFOps.ocr(file, languages: options.ocrLanguages, progress: progress)]
        case Act.pdfEncrypt:
            guard let pw = options.password, !pw.isEmpty else { throw EngineError.failed(L("パスワードが空です")) }
            r.outputs = [try PDFOps.encrypt(file, password: pw, owner: options.ownerPassword)]
        case Act.pdfDecrypt:
            r.outputs = [try PDFOps.decrypt(file, password: options.password ?? "")]
        case Act.pdfPageNumbers:
            r.outputs = [try PDFOps.stamp(file, kind: .pageNumbers)]
        case Act.pdfWatermark:
            guard let text = options.watermarkText, !text.isEmpty else { throw EngineError.failed(L("透かしの文字が空です")) }
            r.outputs = [try PDFOps.stamp(file, kind: .watermark(text))]
        case Act.pdfExtractImages:
            r.outputs = [try ImageExtraction.extract(from: file)]
        case Act.pdfFlatten:
            r.outputs = [try PDFOps.flatten(file)]

        // Images
        case Act.imgRotateRight, Act.imgRotateLeft, Act.imgFlipH, Act.imgFlipV:
            let op: ImageOps.Orientation = action == Act.imgRotateRight ? .right : action == Act.imgRotateLeft ? .left : action == Act.imgFlipH ? .flipH : .flipV
            r.backups = [try ImageOps.reorient(file, op)]
        case Act.imgResize50, Act.imgResize25, Act.imgResize2048, Act.imgResize1080:
            let spec: ImageOps.ResizeSpec = action == Act.imgResize50 ? .scale(0.5) : action == Act.imgResize25 ? .scale(0.25) : action == Act.imgResize2048 ? .longEdge(2048) : .longEdge(1080)
            r.outputs = [try ImageOps.resize(file, spec)]
        case Act.imgResizeCustom:
            guard let edge = options.resizeLongEdge, edge > 0 else { throw EngineError.failed(L("サイズを指定してください")) }
            r.outputs = [try ImageOps.resize(file, .longEdge(edge))]
        case Act.imgCompressLight, Act.imgCompressStandard, Act.imgCompressStrong:
            let q = action == Act.imgCompressLight ? 0.85 : action == Act.imgCompressStandard ? 0.7 : 0.5
            r.outputs = [try ImageOps.compress(file, quality: q, strong: action == Act.imgCompressStrong)]
        case Act.imgRemoveBackground:
            r.outputs = [try ImageOps.removeBackground(file)]
        case Act.imgStripMetadata:
            r.backups = [try ImageOps.stripMetadata(file)]
        case Act.imgOCR:
            let text = try TextRecognizer.recognize(url: file, languages: options.ocrLanguages)
            guard !text.isEmpty else { throw EngineError.failed(L("文字が見つかりませんでした")) }
            let out = OutputNamer.file(for: file, ext: "txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            r.outputs = [out]
        default:
            throw EngineError.unsupported(action)
        }
        return r
    }

    private func fileSize(_ url: URL, backups: [SafeWrite.Backup] = []) -> Int64 {
        let u = backups.first?.saved ?? url
        if let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey]) {
            if v.isDirectory == true {
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey])
                var t: Int64 = 0
                while let f = e?.nextObject() as? URL { t += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                return t
            }
            return Int64(v.fileSize ?? 0)
        }
        return 0
    }

    private func doneMessage(_ action: String, count: Int) -> String {
        switch action {
        case let a where a.hasPrefix("to."):
            let fmt = String(action.dropFirst(3)).uppercased()
            let names = ["DOCX": "Word", "XLSX": "Excel", "PPTX": "PowerPoint", "MD": "Markdown", "TXT": L("テキスト"), "JPEG": "JPEG"]
            return String(format: L("%@ に変換しました"), names[fmt] ?? fmt)
        case Act.pdfRotateRight, Act.pdfRotateLeft, Act.imgRotateLeft, Act.imgRotateRight: return L("回転しました")
        case Act.imgFlipH, Act.imgFlipV: return L("反転しました")
        case Act.pdfSplit, Act.pdfSplitRanges, Act.pdfSplitEvery: return L("ページを分割しました")
        case Act.pdfCompressLight, Act.pdfCompressStandard, Act.pdfCompressStrong, Act.imgCompressLight, Act.imgCompressStandard, Act.imgCompressStrong: return L("圧縮しました")
        case Act.pdfOCR: return L("検索できる PDF にしました")
        case Act.pdfEncrypt: return L("パスワードを設定しました")
        case Act.pdfDecrypt: return L("パスワードを解除しました")
        case Act.pdfPageNumbers: return L("ページ番号を付けました")
        case Act.pdfWatermark: return L("透かしを入れました")
        case Act.pdfExtractImages: return L("画像を取り出しました")
        case Act.pdfFlatten: return L("注釈を統合しました")
        case Act.imgResize50, Act.imgResize25, Act.imgResize2048, Act.imgResize1080, Act.imgResizeCustom: return L("サイズを変更しました")
        case Act.imgRemoveBackground: return L("背景を削除しました")
        case Act.imgStripMetadata: return L("位置情報などを削除しました")
        case Act.imgOCR: return L("文字認識しました")
        default: return ActionCatalog.title(for: action)
        }
    }
}
