import Foundation
import CoreGraphics
import PDFKit
import EnsoDoc

/// PDF -> spreadsheet: one sheet per page, tables as clean grids, other text in column A.
public enum PDFTableExtractor {
    public static func workbook(from document: PDFDocument, ocrWhenNeeded: Bool = true,
                                languages: [String] = ["ja-JP", "en-US"], progress: ((Double) -> Void)? = nil) -> Workbook {
        let options = PDFReconstructionOptions(includeImages: false, ocrWhenNeeded: ocrWhenNeeded, removeRunningHeadersFooters: true,
                                               pageBreaks: true, languages: languages, rasterizeVectorFigures: false)
        let analyzer = DocumentAnalyzer(options: options)
        analyzer.analyze(document) { progress?($0 * 0.95) }
        let flows = analyzer.flows()
        let stats = DocStats.compute(flows: flows, styles: analyzer.styles)
        let builder = BlockBuilder(styles: analyzer.styles, stats: stats)
        let japanese = Locale.preferredLanguages.first?.hasPrefix("ja") ?? false

        var sheets: [Sheet] = []
        for (k, flow) in flows.enumerated() {
            let pageNo = analyzer.pages.indices.contains(k) ? analyzer.pages[k].index + 1 : k + 1
            let name = japanese ? "ページ\(pageNo)" : "Page \(pageNo)"
            sheets.append(Sheet(name: name, rows: rows(for: flow, builder: builder, styles: analyzer.styles)))
        }
        if sheets.isEmpty { sheets.append(Sheet(name: japanese ? "ページ1" : "Page 1", rows: [])) }
        progress?(1)
        return Workbook(sheets: sheets)
    }

    private static func rows(for flow: [FlowItem], builder: BlockBuilder, styles: StyleTable) -> [[CellValue]] {
        // Column anchors for multi-part lines outside detected tables.
        var starts: [CGFloat] = []
        for item in flow { if case .line(let l) = item, l.segments.count >= 2 { starts += l.segments.map(\.rect.minX) } }
        let anchors = cluster(starts, tol: 8)

        var rows: [[CellValue]] = []
        func separate() { if let last = rows.last, !last.allSatisfy({ $0 == .empty }) { rows.append([]) } }
        for item in flow {
            switch item {
            case .table(let t):
                separate()
                for row in t.rows {
                    var out: [CellValue] = []
                    for cell in row {
                        out.append(cell.continuation ? .empty : CellValue.guess(builder.cellText(cell)))
                        if cell.colSpan > 1 { out += Array(repeating: CellValue.empty, count: cell.colSpan - 1) }
                    }
                    rows.append(out)
                }
                rows.append([])
            case .line(let l):
                if l.segments.count >= 2 && anchors.count >= 2 {
                    var out: [CellValue] = []
                    for s in l.segments {
                        let text = builder.plainLine(TextLine(segments: [s], page: l.page, styles: styles))
                        let col = anchors.lastIndex { $0 <= s.rect.minX + 8 } ?? 0
                        while out.count < col { out.append(.empty) }
                        if out.count > col, case .text(let prev) = out[col] {
                            out[col] = .text(prev + " " + text)
                        } else if out.count > col {
                            out[col] = CellValue.guess(text)
                        } else {
                            out.append(CellValue.guess(text))
                        }
                    }
                    rows.append(out)
                } else {
                    rows.append([CellValue.guess(builder.plainLine(l))])
                }
            case .image, .pageStart:
                break
            }
        }
        // Trim trailing empties per row and trailing empty rows.
        rows = rows.map { r in
            var r = r
            while let last = r.last, last == .empty { r.removeLast() }
            return r
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows
    }

    private static func cluster(_ values: [CGFloat], tol: CGFloat) -> [CGFloat] {
        let s = values.sorted()
        var out: [CGFloat] = []
        var group: [CGFloat] = []
        for v in s {
            if let first = group.first, v - first > tol { out.append(group.reduce(0, +) / CGFloat(group.count)); group = [] }
            group.append(v)
        }
        if !group.isEmpty { out.append(group.reduce(0, +) / CGFloat(group.count)) }
        return out
    }
}

/// Lists every embedded raster image in a document.
public enum PDFImageExtractor {
    public static func images(from document: PDFDocument) -> [(pageIndex: Int, image: DocImage)] {
        var out: [(pageIndex: Int, image: DocImage)] = []
        var seenKeys = Set<Int>()
        var seenHashes = Set<UInt64>()
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i), let cg = page.pageRef else { continue }
            let geo = PageGeometry(page: page)
            let g = GraphicsScanner.scan(page: cg, geo: geo, vectors: false)
            for p in g.images where !p.isMask && p.pixelWidth >= 8 && p.pixelHeight >= 8 {
                guard seenKeys.insert(p.key).inserted, let dec = PDFImageDecoder.decode(p) else { continue }
                guard seenHashes.insert(ContentHash.hash(dec.data)).inserted else { continue }
                out.append((i, DocImage(data: dec.data, format: dec.format, pixelWidth: dec.width, pixelHeight: dec.height,
                                        displayWidth: Double(p.rect.width), displayHeight: Double(p.rect.height))))
            }
        }
        return out
    }
}
