import AppKit

/// Lays out an attributed string on pages with TextKit 1 and writes a PDF.
/// Paragraphs tagged with `.ensoPageBreak` start a new page. Footnote marks (`.ensoFootnote`) get their notes at the
/// foot of the page the mark lands on.
public enum PDFRenderer {

    public struct PageSetup {
        public var size: CGSize
        public var margins: NSEdgeInsets
        public init(size: CGSize = DocModel.a4, margins: NSEdgeInsets = NSEdgeInsets(top: 62, left: 60, bottom: 62, right: 60)) {
            self.size = size; self.margins = margins
        }
        public var contentSize: CGSize {
            CGSize(width: size.width - margins.left - margins.right, height: size.height - margins.top - margins.bottom)
        }
    }

    public static func pdfData(from model: DocModel, setup: PageSetup? = nil, pageNumbers: Bool = false) -> Data {
        // A source with its own page layout (Word) is paginated section by section (SourcePDFRenderer.swift).
        if setup == nil, let layout = model.pageLayout, !layout.sections.isEmpty {
            return sourcePDF(model, layout: layout, pageNumbers: pageNumbers)
        }
        var s = setup ?? PageSetup()
        if setup == nil, let size = model.pageSize, size.width > 100, size.height > 100 { s.size = size }
        let style = AttributedConverter.Style(bodySize: CGFloat(model.bodyFontSize), contentWidth: s.contentSize.width,
                                              contentHeight: s.contentSize.height, paged: true)
        let attr = AttributedConverter.attributedString(from: model, style: style)
        return pdfData(from: attr, setup: s, title: model.title, pageNumbers: pageNumbers)
    }

    public static func pdfData(from attr: NSAttributedString, setup: PageSetup = PageSetup(), title: String? = nil, pageNumbers: Bool = false) -> Data {
        // Characters whose Hiragino / Yu glyph would copy back as another character get a safe font.
        let attr = TextLayerFonts.fixed(attr)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: setup.size)
        var info: [CFString: Any] = [kCGPDFContextCreator: "MaruDoc"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { return Data() }

        let segments = split(attr)
        var pageIndex = 0
        var pages: [Page] = []
        var storages: [NSTextStorage] = []   // keep alive while drawing
        var hasFootnotes = false
        attr.enumerateAttribute(.ensoFootnote, in: NSRange(location: 0, length: attr.length)) { v, _, stop in
            if v != nil { hasFootnotes = true; stop.pointee = true }
        }
        // Footnote text that did not fit at the foot of its page continues on the next one.
        var carried = NSAttributedString()

        for segment in segments {
          // Long text is laid out in pieces (see `chunks`); a piece continues on the page where the previous one ended.
          var room: (offset: CGFloat, height: CGFloat)?
          let pieces = hasFootnotes ? [segment] : chunks(segment)
          for (pieceIndex, piece) in pieces.enumerated() {
            let storage = NSTextStorage(attributedString: piece)
            let lm = NSLayoutManager()
            lm.usesFontLeading = true
            storage.addLayoutManager(lm)
            storages.append(storage)
            var guardCount = 0
            var done = false
            if let r = room, var last = pages.popLast() {
                let tc = NSTextContainer(size: CGSize(width: setup.contentSize.width, height: r.height))
                tc.lineFragmentPadding = 0
                lm.addTextContainer(tc)
                last.more.append((lm, tc, r.offset))
                pages.append(last)
                let range = lm.glyphRange(for: tc)
                done = NSMaxRange(range) >= lm.numberOfGlyphs
            }
            while !done {
                let tc = NSTextContainer(size: setup.contentSize)
                tc.lineFragmentPadding = 0
                lm.addTextContainer(tc)
                var page = Page(lm: lm, tc: tc)
                if hasFootnotes { page.notes = placeFootnotes(lm, tc, setup.contentSize, carried: &carried) }
                let range = lm.glyphRange(for: tc)
                pages.append(page)
                guardCount += 1
                if NSMaxRange(range) >= lm.numberOfGlyphs || guardCount > 5000 { break }
                // An element taller than the page can make no progress; stop instead of looping forever.
                if range.length == 0 { break }
            }
            // Room left on the last page for the next piece.
            room = nil
            if pieceIndex + 1 < pieces.count, let last = pages.last {
                let part = last.more.last.map { ($0.lm, $0.tc, $0.dy) } ?? (last.lm, last.tc, 0)
                if let plm = part.0, let ptc = part.1, plm === lm, case let g = plm.glyphRange(for: ptc), g.length > 0 {
                    // The last line's fragment (with its paragraph spacing), not the empty line after the final newline.
                    let used = part.2 + plm.lineFragmentRect(forGlyphAt: NSMaxRange(g) - 1, effectiveRange: nil).maxY
                    if setup.contentSize.height - used > 1 { room = (used, setup.contentSize.height - used) }
                }
            }
          }
        }
        // Notes still waiting after the last page get pages of their own.
        var noteGuard = 0
        while carried.length > 0, noteGuard < 1000 {
            noteGuard += 1
            let fit = fitNotes(carried, width: setup.contentSize.width, height: setup.contentSize.height)
            pages.append(Page(notes: fit.notes))
            carried = fit.rest
            if fit.notes == nil { break }
        }

        let total = pages.count
        for page in pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            let nsctx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.current = nsctx
            ctx.saveGState()
            ctx.translateBy(x: 0, y: setup.size.height)
            ctx.scaleBy(x: 1, y: -1)
            let origin = CGPoint(x: setup.margins.left, y: setup.margins.top)
            if let lm = page.lm, let tc = page.tc {
                let range = lm.glyphRange(for: tc)
                if range.length > 0 {
                    lm.drawBackground(forGlyphRange: range, at: origin)
                    lm.drawGlyphs(forGlyphRange: range, at: origin)
                }
            }
            for part in page.more {
                let range = part.lm.glyphRange(for: part.tc)
                guard range.length > 0 else { continue }
                let o = CGPoint(x: origin.x, y: origin.y + part.dy)
                part.lm.drawBackground(forGlyphRange: range, at: o)
                part.lm.drawGlyphs(forGlyphRange: range, at: o)
            }
            if let notes = page.notes {
                // Bottom-aligned in the text area, under a short rule, like Word's footnote separator; a page holding
                // only notes carried over starts at the top.
                let top = page.lm == nil ? setup.margins.top : setup.margins.top + setup.contentSize.height - notes.height
                if page.lm != nil {
                    ctx.saveGState()
                    ctx.setStrokeColor(NSColor(white: 0.55, alpha: 1).cgColor)
                    ctx.setLineWidth(0.5)
                    ctx.move(to: CGPoint(x: setup.margins.left, y: top - 5))
                    ctx.addLine(to: CGPoint(x: setup.margins.left + min(144, setup.contentSize.width / 3), y: top - 5))
                    ctx.strokePath()
                    ctx.restoreGState()
                }
                let nOrigin = CGPoint(x: setup.margins.left, y: top)
                notes.lm.drawBackground(forGlyphRange: notes.glyphs, at: nOrigin)
                notes.lm.drawGlyphs(forGlyphRange: notes.glyphs, at: nOrigin)
            }
            pageIndex += 1
            if pageNumbers && total > 1 {
                let label = "\(pageIndex) / \(total)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 0.45, alpha: 1)]
                let size = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: (setup.size.width - size.width) / 2, y: setup.size.height - setup.margins.bottom / 2 - size.height / 2), withAttributes: attrs)
            }
            ctx.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        if pages.isEmpty { ctx.beginPDFPage(nil); ctx.endPDFPage() }
        ctx.closePDF()
        _ = storages
        return data as Data
    }

    /// A page: body text (a container of a layout manager) and/or the footnotes set at its foot.
    struct Page {
        var lm: NSLayoutManager?
        var tc: NSTextContainer?
        var notes: Notes?
        /// Further text on the same page from the next piece of a long text (`chunks`), `dy` below the top.
        var more: [(lm: NSLayoutManager, tc: NSTextContainer, dy: CGFloat)] = []
    }

    /// Footnote text laid out for one page: draw `glyphs` of `lm`; `height` is what it uses.
    struct Notes {
        let storage: NSTextStorage
        let lm: NSLayoutManager
        let glyphs: NSRange
        let height: CGFloat
    }

    /// Gap between the body text and the notes, room for the separator rule.
    static let noteGap: CGFloat = 12

    /// Shrinks the page's text container until the footnotes of the marks on it (after any carried over from the
    /// previous page) fit below the text, and returns them laid out. The container only ever shrinks, so a mark that
    /// moves to the next page takes its note along and the space reserved always holds the notes that stay. Notes
    /// take at most half the page; what does not fit is carried to the next page, as Word does.
    static func placeFootnotes(_ lm: NSLayoutManager, _ tc: NSTextContainer, _ content: CGSize,
                               carried: inout NSAttributedString) -> Notes? {
        func notes(on glyphs: NSRange) -> [NSAttributedString] {
            guard let storage = lm.textStorage, glyphs.length > 0 else { return [] }
            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            var out: [NSAttributedString] = []
            storage.enumerateAttribute(.ensoFootnote, in: chars) { v, _, _ in if let a = v as? NSAttributedString { out.append(a) } }
            return out
        }
        func joined(_ list: [NSAttributedString]) -> NSAttributedString {
            let s = NSMutableAttributedString(attributedString: carried)
            for a in list { s.append(a) }
            return s
        }
        let maxArea = content.height * 0.5
        var list = notes(on: lm.glyphRange(for: tc))
        if list.isEmpty && carried.length == 0 { return nil }
        var height = content.height
        for _ in 0..<8 {
            let needed = min(measure(joined(list), width: content.width), maxArea)
            let target = max(content.height - needed - noteGap, content.height - maxArea - noteGap)
            if target >= height - 0.5 { break }
            height = target
            tc.size = CGSize(width: content.width, height: height)
            let again = notes(on: lm.glyphRange(for: tc))
            if again.count == list.count { break }
            list = again
        }
        let fit = fitNotes(joined(list), width: content.width, height: content.height - height - noteGap)
        carried = fit.rest
        return fit.notes
    }

    /// Lays out note text in the given area: the part that fits, and the rest (empty when everything fits).
    static func fitNotes(_ text: NSAttributedString, width: CGFloat, height: CGFloat) -> (notes: Notes?, rest: NSAttributedString) {
        guard text.length > 0, height > 1 else { return (nil, text) }
        let storage = NSTextStorage(attributedString: TextLayerFonts.fixed(text))
        let lm = NSLayoutManager()
        lm.usesFontLeading = true
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: width, height: height))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        let glyphs = lm.glyphRange(for: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let used = lm.usedRect(for: tc).height
        let rest = NSMaxRange(chars) < text.length
            ? text.attributedSubstring(from: NSRange(location: NSMaxRange(chars), length: text.length - NSMaxRange(chars)))
            : NSAttributedString()
        if glyphs.length == 0 { return (nil, text) }
        return (Notes(storage: storage, lm: lm, glyphs: glyphs, height: used), rest)
    }

    static func measure(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: text)
        let lm = NSLayoutManager()
        lm.usesFontLeading = true
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return ceil(lm.usedRect(for: tc).height)
    }

    /// TextKit 1 gets slower than linear when one text storage holds a very long text: a 1.6 MB text took 9 s and a
    /// 16 MB one did not finish (WD-34). Text past `limit` characters is laid out in pieces of about `piece`
    /// characters, cut after a paragraph end; shorter text stays one piece and lays out exactly as before.
    static func chunks(_ s: NSAttributedString, limit: Int = 200_000, piece: Int = 100_000) -> [NSAttributedString] {
        guard s.length > limit else { return [s] }
        let ns = s.string as NSString
        var out: [NSAttributedString] = []
        var start = 0
        while start < ns.length {
            var end = min(ns.length, start + piece)
            if end < ns.length {
                let para = ns.paragraphRange(for: NSRange(location: end, length: 0))
                end = max(NSMaxRange(para), end)
                // Never inside a table: its cells must stay in one storage.
                while end < ns.length, (s.attribute(.paragraphStyle, at: end - 1, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty == false {
                    end = NSMaxRange(ns.paragraphRange(for: NSRange(location: end, length: 0)))
                }
            }
            out.append(s.attributedSubstring(from: NSRange(location: start, length: end - start)))
            start = end
        }
        return out
    }

    /// Splits at paragraphs carrying `.ensoPageBreak`.
    static func split(_ attr: NSAttributedString) -> [NSAttributedString] {
        var cuts: [Int] = []
        attr.enumerateAttribute(.ensoPageBreak, in: NSRange(location: 0, length: attr.length)) { v, r, _ in
            if v != nil, r.location > 0 { cuts.append(r.location) }
        }
        var out: [NSAttributedString] = []
        var start = 0
        for c in cuts where c > start {
            out.append(attr.attributedSubstring(from: NSRange(location: start, length: c - start)))
            start = c
        }
        out.append(attr.attributedSubstring(from: NSRange(location: start, length: attr.length - start)))
        return out.filter { $0.length > 0 }
    }
}
