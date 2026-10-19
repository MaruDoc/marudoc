import Foundation

/// Stable identifiers for everything MaruDoc can do to a file.
/// The Finder extension and the radial menu only carry these strings; the app executes them.
public enum Act {
    // Conversions. The input kind is resolved at run time, so "to.pdf" works for images, Word, Markdown, ...
    public static let toPDF = "to.pdf"
    public static let toDOCX = "to.docx"
    public static let toXLSX = "to.xlsx"
    public static let toPPTX = "to.pptx"
    public static let toPNG = "to.png"
    public static let toJPEG = "to.jpeg"
    public static let toHEIC = "to.heic"
    public static let toTIFF = "to.tiff"
    public static let toMD = "to.md"
    public static let toTXT = "to.txt"
    public static let toHTML = "to.html"
    public static let toRTF = "to.rtf"
    public static let toCSV = "to.csv"

    // PDF operations
    public static let pdfMerge = "pdf.merge"
    public static let pdfSplit = "pdf.split"
    public static let pdfSplitRanges = "pdf.split.ranges"
    public static let pdfSplitEvery = "pdf.split.every"
    public static let pdfRotateRight = "pdf.rotate.right"
    public static let pdfRotateLeft = "pdf.rotate.left"
    public static let pdfCompressLight = "pdf.compress.light"
    public static let pdfCompressStandard = "pdf.compress.standard"
    public static let pdfCompressStrong = "pdf.compress.strong"
    public static let pdfOCR = "pdf.ocr"
    public static let pdfEncrypt = "pdf.encrypt"
    public static let pdfDecrypt = "pdf.decrypt"
    public static let pdfPageNumbers = "pdf.pagenumbers"
    public static let pdfWatermark = "pdf.watermark"
    public static let pdfExtractImages = "pdf.extractimages"
    public static let pdfFlatten = "pdf.flatten"

    // Image operations
    public static let imgResize50 = "img.resize.50"
    public static let imgResize25 = "img.resize.25"
    public static let imgResize2048 = "img.resize.2048"
    public static let imgResize1080 = "img.resize.1080"
    public static let imgRotateRight = "img.rotate.right"
    public static let imgRotateLeft = "img.rotate.left"
    public static let imgFlipH = "img.flip.h"
    public static let imgFlipV = "img.flip.v"
    public static let imgCompressLight = "img.compress.light"
    public static let imgCompressStandard = "img.compress.standard"
    public static let imgCompressStrong = "img.compress.strong"
    public static let imgRemoveBackground = "img.removebg"
    public static let imgStripMetadata = "img.stripmeta"
    public static let imgOCR = "img.ocr"

    // Multi-file
    /// Legacy id of the multi-file merge. The menus now offer `pdfMerge`; the engine and the app treat both alike.
    public static let combineToPDF = "multi.topdf"
    public static func isMerge(_ id: String) -> Bool { id == pdfMerge || id == combineToPDF }

    // Popup editors (handled by the app UI, not the engine)
    public static let editOpen = "edit.open"
    public static let editCrop = "edit.crop"
    public static let editPages = "edit.pages"
    public static let editResize = "edit.resize"
    public static let editPassword = "edit.password"
    public static let editWatermark = "edit.watermark"
    /// Ask for page ranges / a page count in a small dialog, then run `pdfSplitRanges` / `pdfSplitEvery`.
    public static let editSplitRanges = "edit.split.ranges"
    public static let editSplitEvery = "edit.split.every"

    // Utilities
    public static let copyText = "util.copytext"
    public static let openSettings = "app.settings"

    public static func isEditor(_ id: String) -> Bool { id.hasPrefix("edit.") }
}

/// One entry in the action tree. A node may run an action directly, open a group of children, or both:
/// on the radial ring, releasing on the segment runs `action`, moving outward reveals `children`.
public struct MenuNode: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    /// Short label for the ring (falls back to title).
    public var shortTitle: String
    public var symbol: String
    public var action: String?
    public var children: [MenuNode]

    public init(id: String, title: String, short: String? = nil, symbol: String, action: String? = nil, children: [MenuNode] = []) {
        self.id = id
        self.title = title
        self.shortTitle = short ?? title
        self.symbol = symbol
        self.action = action
        self.children = children
    }

    public static func leaf(_ action: String, _ title: String, short: String? = nil, symbol: String) -> MenuNode {
        MenuNode(id: action, title: title, short: short, symbol: symbol, action: action)
    }
}

/// Builds the action tree for a selection. Both the Finder context menu and the radial menu use this,
/// so the two always offer the same operations.
public enum ActionCatalog {

    public static func menu(for urls: [URL]) -> [MenuNode] {
        let kinds = Set(urls.map(FileKind.of))
        if urls.count > 1 { return multiMenu(kinds: kinds, count: urls.count) }
        guard let kind = kinds.first else { return [] }
        switch kind {
        case .pdf: return pdfMenu()
        case .image: return imageMenu()
        case .word, .rtf: return wordMenu(kind: kind)
        case .markdown, .text, .html: return textMenu(kind: kind)
        case .spreadsheet, .csv: return sheetMenu(kind: kind)
        case .presentation: return presentationMenu()
        case .other: return []
        }
    }

    // MARK: - Per kind

    static func pdfMenu() -> [MenuNode] {
        [
            MenuNode(id: "g.office", title: L("Office に変換"), short: "Office", symbol: "square.stack", action: Act.toDOCX, children: [
                .leaf(Act.toDOCX, L("Word (.docx)"), short: "Word", symbol: "doc.richtext"),
                .leaf(Act.toXLSX, L("Excel (.xlsx)"), short: "Excel", symbol: "tablecells"),
                .leaf(Act.toPPTX, L("PowerPoint (.pptx)"), short: "PowerPoint", symbol: "rectangle.on.rectangle"),
            ]),
            MenuNode(id: "g.image", title: L("画像に変換"), short: L("画像"), symbol: "photo", action: Act.toPNG, children: imageTargets(includePDF: false)),
            MenuNode(id: "g.text", title: L("テキストに変換"), short: L("テキスト"), symbol: "text.alignleft", action: Act.toMD, children: textTargets(excluding: nil)),
            .leaf(Act.editOpen, L("編集…"), short: L("編集"), symbol: "pencil.tip.crop.circle"),
            .leaf(Act.editCrop, L("トリミング…"), short: L("トリミング"), symbol: "crop"),
            MenuNode(id: "g.pages", title: L("ページ"), symbol: "doc.on.doc", action: Act.editPages, children: [
                .leaf(Act.editPages, L("ページを整理…"), short: L("整理"), symbol: "square.grid.2x2"),
                .leaf(Act.pdfRotateRight, L("右に回転"), short: L("右回転"), symbol: "rotate.right"),
                .leaf(Act.pdfRotateLeft, L("左に回転"), short: L("左回転"), symbol: "rotate.left"),
                splitGroup(),
            ]),
            MenuNode(id: "g.compress", title: L("圧縮"), symbol: "arrow.down.right.and.arrow.up.left", action: Act.pdfCompressStandard, children: [
                .leaf(Act.pdfCompressLight, L("軽く圧縮 (画質優先)"), short: L("軽め"), symbol: "circle.bottomhalf.filled"),
                .leaf(Act.pdfCompressStandard, L("標準の圧縮"), short: L("標準"), symbol: "circle.lefthalf.filled"),
                .leaf(Act.pdfCompressStrong, L("強く圧縮 (サイズ優先)"), short: L("強め"), symbol: "circle.fill"),
            ]),
            MenuNode(id: "g.more", title: L("その他"), symbol: "ellipsis.circle", children: [
                .leaf(Act.pdfOCR, L("文字認識して検索可能に"), short: L("文字認識"), symbol: "text.viewfinder"),
                .leaf(Act.editPassword, L("パスワード…"), short: L("パスワード"), symbol: "lock"),
                .leaf(Act.pdfPageNumbers, L("ページ番号を付ける"), short: L("ページ番号"), symbol: "number"),
                .leaf(Act.editWatermark, L("透かしを入れる…"), short: L("透かし"), symbol: "drop"),
                .leaf(Act.pdfExtractImages, L("画像を取り出す"), short: L("画像抽出"), symbol: "photo.stack"),
                .leaf(Act.copyText, L("テキストをコピー"), short: L("コピー"), symbol: "doc.on.clipboard"),
            ]),
        ]
    }

    /// 「分割」: one page each, by page ranges, or every N pages. A nested group in the Finder menu; the radial ring
    /// has two levels only, so `ringMenu(for:)` lifts these three entries one level up.
    static func splitGroup() -> MenuNode {
        MenuNode(id: "g.split", title: L("分割"), symbol: "square.split.2x1", action: Act.pdfSplit, children: [
            .leaf(Act.pdfSplit, L("1ページずつ"), short: L("1ページ"), symbol: "square.split.2x1"),
            .leaf(Act.editSplitRanges, L("ページ範囲を指定…"), short: L("範囲"), symbol: "rectangle.split.3x1"),
            .leaf(Act.editSplitEvery, L("N ページごと…"), short: L("Nページ"), symbol: "square.stack.3d.down.right"),
        ])
    }

    /// The tree for the radial ring, which shows an item and one ring of children. Groups nested inside a child group
    /// are replaced by their own children, so every action stays reachable.
    public static func ringMenu(for urls: [URL]) -> [MenuNode] {
        menu(for: urls).map { node in
            var n = node
            n.children = node.children.flatMap { $0.children.isEmpty ? [$0] : $0.children }
            return n
        }
    }

    static func imageMenu() -> [MenuNode] {
        [
            MenuNode(id: "g.convert", title: L("変換"), symbol: "arrow.triangle.2.circlepath", action: Act.toPDF, children: imageTargets(includePDF: true)),
            .leaf(Act.editCrop, L("トリミング…"), short: L("トリミング"), symbol: "crop"),
            MenuNode(id: "g.resize", title: L("サイズ変更"), short: L("サイズ"), symbol: "arrow.up.left.and.arrow.down.right", action: Act.imgResize50, children: [
                .leaf(Act.imgResize50, L("50% に縮小"), short: "50%", symbol: "square.resize.down"),
                .leaf(Act.imgResize25, L("25% に縮小"), short: "25%", symbol: "square.resize.down"),
                .leaf(Act.imgResize2048, L("長辺 2048px"), short: "2048px", symbol: "rectangle.compress.vertical"),
                .leaf(Act.imgResize1080, L("長辺 1080px"), short: "1080px", symbol: "rectangle.compress.vertical"),
                .leaf(Act.editResize, L("サイズを指定…"), short: L("指定"), symbol: "slider.horizontal.3"),
            ]),
            MenuNode(id: "g.rotate", title: L("回転"), symbol: "rotate.right", action: Act.imgRotateRight, children: [
                .leaf(Act.imgRotateRight, L("右に回転"), short: L("右回転"), symbol: "rotate.right"),
                .leaf(Act.imgRotateLeft, L("左に回転"), short: L("左回転"), symbol: "rotate.left"),
                .leaf(Act.imgFlipH, L("左右反転"), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right"),
                .leaf(Act.imgFlipV, L("上下反転"), symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down"),
            ]),
            .leaf(Act.editOpen, L("編集…"), short: L("編集"), symbol: "pencil.tip.crop.circle"),
            MenuNode(id: "g.compress", title: L("圧縮"), symbol: "arrow.down.right.and.arrow.up.left", action: Act.imgCompressStandard, children: [
                .leaf(Act.imgCompressLight, L("軽く圧縮 (画質優先)"), short: L("軽め"), symbol: "circle.bottomhalf.filled"),
                .leaf(Act.imgCompressStandard, L("標準の圧縮"), short: L("標準"), symbol: "circle.lefthalf.filled"),
                .leaf(Act.imgCompressStrong, L("強く圧縮 (サイズ優先)"), short: L("強め"), symbol: "circle.fill"),
            ]),
            .leaf(Act.imgRemoveBackground, L("背景を削除"), short: L("背景削除"), symbol: "person.crop.square"),
            MenuNode(id: "g.more", title: L("その他"), symbol: "ellipsis.circle", children: [
                .leaf(Act.imgOCR, L("文字認識してテキストに"), short: L("文字認識"), symbol: "text.viewfinder"),
                .leaf(Act.imgStripMetadata, L("位置情報などを削除"), short: L("情報削除"), symbol: "location.slash"),
                .leaf(Act.copyText, L("テキストをコピー"), short: L("コピー"), symbol: "doc.on.clipboard"),
            ]),
        ]
    }

    static func wordMenu(kind: FileKind) -> [MenuNode] {
        [
            .leaf(Act.toPDF, L("PDF に変換"), short: "PDF", symbol: "doc.text"),
            .leaf(Act.editOpen, L("編集…"), short: L("編集"), symbol: "pencil.tip.crop.circle"),
            MenuNode(id: "g.text", title: L("テキストに変換"), short: L("テキスト"), symbol: "text.alignleft", action: Act.toMD,
                     children: textTargets(excluding: kind == .rtf ? Act.toRTF : nil) + (kind == .rtf ? [.leaf(Act.toDOCX, L("Word (.docx)"), short: "Word", symbol: "doc.richtext")] : [])),
            MenuNode(id: "g.image", title: L("画像に変換"), short: L("画像"), symbol: "photo", action: Act.toPNG, children: [
                .leaf(Act.toPNG, "PNG", symbol: "photo"),
                .leaf(Act.toJPEG, "JPEG", symbol: "photo"),
            ]),
            .leaf(Act.copyText, L("テキストをコピー"), short: L("コピー"), symbol: "doc.on.clipboard"),
        ]
    }

    static func textMenu(kind: FileKind) -> [MenuNode] {
        var nodes: [MenuNode] = [
            .leaf(Act.toPDF, L("PDF に変換"), short: "PDF", symbol: "doc.text"),
            .leaf(Act.toDOCX, L("Word に変換"), short: "Word", symbol: "doc.richtext"),
            .leaf(Act.editOpen, L("編集…"), short: L("編集"), symbol: "pencil.tip.crop.circle"),
        ]
        var others: [MenuNode] = []
        if kind != .html { others.append(.leaf(Act.toHTML, "HTML", symbol: "chevron.left.forwardslash.chevron.right")) }
        if kind != .markdown { others.append(.leaf(Act.toMD, "Markdown", symbol: "number.square")) }
        if kind != .text { others.append(.leaf(Act.toTXT, L("テキスト (.txt)"), short: "TXT", symbol: "doc.plaintext")) }
        others.append(.leaf(Act.toRTF, L("リッチテキスト (.rtf)"), short: "RTF", symbol: "doc.richtext"))
        nodes.append(MenuNode(id: "g.text", title: L("ほかの形式に変換"), short: L("形式"), symbol: "arrow.triangle.2.circlepath", action: others.first?.action, children: others))
        nodes.append(MenuNode(id: "g.image", title: L("画像に変換"), short: L("画像"), symbol: "photo", action: Act.toPNG, children: [
            .leaf(Act.toPNG, "PNG", symbol: "photo"),
            .leaf(Act.toJPEG, "JPEG", symbol: "photo"),
        ]))
        nodes.append(.leaf(Act.copyText, L("テキストをコピー"), short: L("コピー"), symbol: "doc.on.clipboard"))
        return nodes
    }

    static func sheetMenu(kind: FileKind) -> [MenuNode] {
        var nodes: [MenuNode] = [.leaf(Act.toPDF, L("PDF に変換"), short: "PDF", symbol: "doc.text")]
        if kind == .spreadsheet {
            nodes.append(.leaf(Act.toCSV, L("CSV に変換"), short: "CSV", symbol: "tablecells"))
        } else {
            nodes.append(.leaf(Act.toXLSX, L("Excel に変換"), short: "Excel", symbol: "tablecells"))
        }
        nodes.append(.leaf(Act.toMD, L("Markdown の表に変換"), short: "Markdown", symbol: "number.square"))
        nodes.append(.leaf(Act.toHTML, L("HTML に変換"), short: "HTML", symbol: "chevron.left.forwardslash.chevron.right"))
        nodes.append(.leaf(Act.toDOCX, L("Word に変換"), short: "Word", symbol: "doc.richtext"))
        nodes.append(.leaf(Act.copyText, L("テキストをコピー"), short: L("コピー"), symbol: "doc.on.clipboard"))
        return nodes
    }

    static func presentationMenu() -> [MenuNode] {
        [
            .leaf(Act.toPDF, L("PDF に変換 (テキストと画像)"), short: "PDF", symbol: "doc.text"),
            .leaf(Act.toDOCX, L("Word に変換"), short: "Word", symbol: "doc.richtext"),
            .leaf(Act.toMD, L("Markdown に変換"), short: "Markdown", symbol: "number.square"),
            .leaf(Act.toTXT, L("テキストに変換"), short: L("テキスト"), symbol: "doc.plaintext"),
            .leaf(Act.pdfExtractImages, L("画像を取り出す"), short: L("画像抽出"), symbol: "photo.stack"),
            .leaf(Act.copyText, L("テキストをコピー"), short: L("コピー"), symbol: "doc.on.clipboard"),
        ]
    }

    static func multiMenu(kinds: Set<FileKind>, count: Int) -> [MenuNode] {
        var nodes: [MenuNode] = []
        if kinds.isSubset(of: [.pdf, .image]) {
            nodes.append(.leaf(Act.pdfMerge, L("PDF に結合"), short: L("結合"), symbol: "rectangle.stack"))
        }
        if kinds == [.pdf] {
            nodes.append(MenuNode(id: "g.office", title: L("まとめて Office に変換"), short: "Office", symbol: "square.stack", action: Act.toDOCX, children: [
                .leaf(Act.toDOCX, "Word", symbol: "doc.richtext"),
                .leaf(Act.toXLSX, "Excel", symbol: "tablecells"),
                .leaf(Act.toPPTX, "PowerPoint", symbol: "rectangle.on.rectangle"),
            ]))
            nodes.append(MenuNode(id: "g.image", title: L("まとめて画像に変換"), short: L("画像"), symbol: "photo", action: Act.toPNG, children: imageTargets(includePDF: false)))
            nodes.append(MenuNode(id: "g.text", title: L("まとめてテキストに変換"), short: L("テキスト"), symbol: "text.alignleft", action: Act.toMD, children: textTargets(excluding: nil)))
            nodes.append(MenuNode(id: "g.compress", title: L("まとめて圧縮"), short: L("圧縮"), symbol: "arrow.down.right.and.arrow.up.left", action: Act.pdfCompressStandard, children: [
                .leaf(Act.pdfCompressLight, L("軽め"), symbol: "circle.bottomhalf.filled"),
                .leaf(Act.pdfCompressStandard, L("標準"), symbol: "circle.lefthalf.filled"),
                .leaf(Act.pdfCompressStrong, L("強め"), symbol: "circle.fill"),
            ]))
            nodes.append(.leaf(Act.pdfOCR, L("まとめて文字認識"), short: L("文字認識"), symbol: "text.viewfinder"))
        } else if kinds == [.image] {
            nodes.append(MenuNode(id: "g.convert", title: L("まとめて変換"), short: L("変換"), symbol: "arrow.triangle.2.circlepath", action: Act.toJPEG, children: imageTargets(includePDF: false)))
            nodes.append(MenuNode(id: "g.resize", title: L("まとめてサイズ変更"), short: L("サイズ"), symbol: "arrow.up.left.and.arrow.down.right", action: Act.imgResize50, children: [
                .leaf(Act.imgResize50, "50%", symbol: "square.resize.down"),
                .leaf(Act.imgResize25, "25%", symbol: "square.resize.down"),
                .leaf(Act.imgResize2048, "2048px", symbol: "rectangle.compress.vertical"),
                .leaf(Act.imgResize1080, "1080px", symbol: "rectangle.compress.vertical"),
            ]))
            nodes.append(MenuNode(id: "g.compress", title: L("まとめて圧縮"), short: L("圧縮"), symbol: "arrow.down.right.and.arrow.up.left", action: Act.imgCompressStandard, children: [
                .leaf(Act.imgCompressLight, L("軽め"), symbol: "circle.bottomhalf.filled"),
                .leaf(Act.imgCompressStandard, L("標準"), symbol: "circle.lefthalf.filled"),
                .leaf(Act.imgCompressStrong, L("強め"), symbol: "circle.fill"),
            ]))
            nodes.append(MenuNode(id: "g.rotate", title: L("まとめて回転"), short: L("回転"), symbol: "rotate.right", action: Act.imgRotateRight, children: [
                .leaf(Act.imgRotateRight, L("右に回転"), short: L("右回転"), symbol: "rotate.right"),
                .leaf(Act.imgRotateLeft, L("左に回転"), short: L("左回転"), symbol: "rotate.left"),
            ]))
            nodes.append(.leaf(Act.imgRemoveBackground, L("まとめて背景を削除"), short: L("背景削除"), symbol: "person.crop.square"))
            nodes.append(.leaf(Act.imgStripMetadata, L("まとめて位置情報などを削除"), short: L("情報削除"), symbol: "location.slash"))
        } else if kinds.allSatisfy({ $0.isDocumentLike || $0 == .pdf }) {
            nodes.append(.leaf(Act.toPDF, L("まとめて PDF に変換"), short: "PDF", symbol: "doc.text"))
            nodes.append(.leaf(Act.toMD, L("まとめて Markdown に変換"), short: "Markdown", symbol: "number.square"))
            nodes.append(.leaf(Act.toTXT, L("まとめてテキストに変換"), short: L("テキスト"), symbol: "doc.plaintext"))
        }
        return nodes
    }

    // MARK: - Shared child lists

    static func imageTargets(includePDF: Bool) -> [MenuNode] {
        var list: [MenuNode] = []
        if includePDF { list.append(.leaf(Act.toPDF, "PDF", symbol: "doc.text")) }
        list += [
            .leaf(Act.toPNG, "PNG", symbol: "photo"),
            .leaf(Act.toJPEG, "JPEG", symbol: "photo.fill"),
            .leaf(Act.toHEIC, "HEIC", symbol: "photo.circle"),
            .leaf(Act.toTIFF, "TIFF", symbol: "photo.artframe"),
        ]
        return list
    }

    static func textTargets(excluding: String?) -> [MenuNode] {
        [
            .leaf(Act.toMD, "Markdown", symbol: "number.square"),
            .leaf(Act.toTXT, L("テキスト (.txt)"), short: "TXT", symbol: "doc.plaintext"),
            .leaf(Act.toHTML, "HTML", symbol: "chevron.left.forwardslash.chevron.right"),
            .leaf(Act.toRTF, L("リッチテキスト (.rtf)"), short: "RTF", symbol: "doc.richtext"),
        ].filter { $0.action != excluding }
    }

    /// Flattened lookup used by the app to label HUD messages.
    public static func title(for action: String) -> String {
        Labels.actionTitles[action] ?? action
    }
}

enum Labels {
    static let actionTitles: [String: String] = [
        Act.toPDF: L("PDF に変換"), Act.toDOCX: L("Word に変換"), Act.toXLSX: L("Excel に変換"),
        Act.toPPTX: L("PowerPoint に変換"), Act.toPNG: L("PNG に変換"), Act.toJPEG: L("JPEG に変換"),
        Act.toHEIC: L("HEIC に変換"), Act.toTIFF: L("TIFF に変換"), Act.toMD: L("Markdown に変換"),
        Act.toTXT: L("テキストに変換"), Act.toHTML: L("HTML に変換"), Act.toRTF: L("RTF に変換"), Act.toCSV: L("CSV に変換"),
        Act.pdfMerge: L("PDF に結合"), Act.pdfSplit: L("ページを分割"), Act.pdfSplitRanges: L("ページを分割"), Act.pdfSplitEvery: L("ページを分割"),
        Act.editSplitRanges: L("ページ範囲を指定して分割"), Act.editSplitEvery: L("N ページごとに分割"), Act.pdfRotateRight: L("右に回転"),
        Act.pdfRotateLeft: L("左に回転"), Act.pdfCompressLight: L("軽く圧縮"), Act.pdfCompressStandard: L("圧縮"),
        Act.pdfCompressStrong: L("強く圧縮"), Act.pdfOCR: L("文字認識"), Act.pdfEncrypt: L("パスワードを設定"),
        Act.pdfDecrypt: L("パスワードを解除"), Act.pdfPageNumbers: L("ページ番号を付ける"), Act.pdfWatermark: L("透かしを入れる"),
        Act.pdfExtractImages: L("画像を取り出す"), Act.pdfFlatten: L("注釈を統合"),
        Act.imgResize50: L("50% に縮小"), Act.imgResize25: L("25% に縮小"), Act.imgResize2048: L("長辺 2048px に縮小"),
        Act.imgResize1080: L("長辺 1080px に縮小"), Act.imgRotateRight: L("右に回転"), Act.imgRotateLeft: L("左に回転"),
        Act.imgFlipH: L("左右反転"), Act.imgFlipV: L("上下反転"), Act.imgCompressLight: L("軽く圧縮"),
        Act.imgCompressStandard: L("圧縮"), Act.imgCompressStrong: L("強く圧縮"), Act.imgRemoveBackground: L("背景を削除"),
        Act.imgStripMetadata: L("位置情報などを削除"), Act.imgOCR: L("文字認識"), Act.combineToPDF: L("PDF に結合"),
        Act.copyText: L("テキストをコピー"), Act.editOpen: L("編集"), Act.editCrop: L("トリミング"), Act.editPages: L("ページを整理"),
    ]
}

extension ActionCatalog {
    /// Every action id that can appear in a menu, in a stable order. The Finder extension uses the index as the
    /// NSMenuItem tag because Finder copies menu items and drops representedObject.
    public static let allActionIDs: [String] = {
        let samples: [[String]] = [
            ["a.pdf"], ["a.png"], ["a.docx"], ["a.rtf"], ["a.md"], ["a.txt"], ["a.html"], ["a.xlsx"], ["a.csv"], ["a.pptx"],
            ["a.pdf", "b.pdf"], ["a.png", "b.jpg"], ["a.pdf", "b.png"], ["a.docx", "b.md"],
        ]
        var seen = Set<String>(), out: [String] = []
        func walk(_ nodes: [MenuNode]) {
            for n in nodes {
                if let a = n.action, !seen.contains(a) { seen.insert(a); out.append(a) }
                walk(n.children)
            }
        }
        for s in samples { walk(menu(for: s.map { URL(fileURLWithPath: "/tmp/" + $0) })) }
        for extra in [Act.openSettings] where !seen.contains(extra) { out.append(extra) }
        return out
    }()

    /// Actions that rewrite the original file in place (they keep a backup for undo, but the file itself changes).
    public static let inPlaceActionIDs: Set<String> = [
        Act.pdfRotateRight, Act.pdfRotateLeft,
        Act.imgRotateRight, Act.imgRotateLeft, Act.imgFlipH, Act.imgFlipV,
        Act.imgStripMetadata,
    ]

    /// True for actions that must never run on a request that did not prove it came from the Finder extension, even
    /// when the user would click "run": they put file contents on the clipboard or change the original file.
    public static func requiresAuthentication(_ action: String) -> Bool {
        action == Act.copyText || inPlaceActionIDs.contains(action)
    }

    public enum Admission: Equatable { case run, askUser, refuse }

    /// What the app does with a `marudoc://run` request. Only ids that the Finder menu can send are ever accepted
    /// (internal ids such as `pdf.decrypt` are refused even with a valid token); a request without a valid token
    /// needs the user's confirmation and cannot use the clipboard or in-place actions.
    public static func admission(for action: String, authenticated: Bool) -> Admission {
        guard allActionIDs.contains(action) else { return .refuse }
        // Opening Settings touches no files, so it never needs a confirmation.
        if authenticated || action == Act.openSettings { return .run }
        return requiresAuthentication(action) ? .refuse : .askUser
    }

    public static func tag(for action: String) -> Int { (allActionIDs.firstIndex(of: action) ?? -1) + 1000 }
    public static func action(forTag tag: Int) -> String? {
        let i = tag - 1000
        return allActionIDs.indices.contains(i) ? allActionIDs[i] : nil
    }
}
