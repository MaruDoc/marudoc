import AppKit

extension NSAttributedString.Key {
    /// Index into DocPageLayout.sections of the text: the PDF renderer takes page size, margins, header and footer
    /// of a page from the section of its first character.
    public static let ensoSection = NSAttributedString.Key("EnsoSection")
    /// On a paragraph with tab stops that have leaders: those stops ([DocTabStop]); the PDF renderer draws the leaders.
    public static let ensoTabLeaders = NSAttributedString.Key("EnsoTabLeaders")
    /// On a paragraph that stays on the page of the next one (Word's keep with next, set on headings).
    public static let ensoKeepNext = NSAttributedString.Key("EnsoKeepNext")
    /// On a paragraph with border lines (DocBorders); the PDF renderer draws one box around neighbours with equal ones.
    public static let ensoBorders = NSAttributedString.Key("EnsoBorders")
}

/// Paragraph layout for sources with their own page layout (DocModel.pageLayout, used for PDF only): the paragraph
/// styles follow Word's spacing, line spacing, document grid, indents and tab stops instead of MaruDoc's own look.
extension AttributedConverter {

    /// The height Word gives one single-spaced line of text set in `requested` (the font name the document asks for)
    /// at `size`. Word measures the Windows font, which is often not the Mac font drawn in its place, so known families
    /// use their own ratio (the same as the Word editor's DocxDisplayFonts); any other font its own metrics.
    static func wordLineHeight(requested: String?, size: CGFloat, drawn: NSFont) -> CGFloat {
        let k = (requested ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if k.contains("游") || k.hasPrefix("yu") { return size * 1.7 }
        if k.hasPrefix("ｍｓ") || k.hasPrefix("ms") { return size * 1.0 }
        if k.contains("メイリオ") || k.hasPrefix("meiryo") { return size * 1.5 }
        if k.hasPrefix("calibri") { return size * 1.22 }
        if k.hasPrefix("century") || k.hasPrefix("timesnewroman") || k.hasPrefix("arial") { return size * 1.15 }
        return ceil(drawn.ascender - drawn.descender + drawn.leading)
    }

    /// An NSParagraphStyle for a paragraph formatted by its source.
    ///   - natural: Word's single line height for the paragraph's fonts (`wordLineHeight`, tallest run);
    ///   - pitch: the section's document grid, which auto-spaced lines snap to unless the paragraph opts out;
    ///   - before: the space above, already reduced where the previous paragraph's space after covers it.
    static func sourceParagraphStyle(_ f: DocParagraphFormat, alignment: DocAlignment, natural: CGFloat, pitch: CGFloat?,
                                     defaultTab: CGFloat, before: CGFloat, inCell: Bool = false) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        switch alignment {
        case .left: p.alignment = .natural
        case .center: p.alignment = .center
        case .right: p.alignment = .right
        case .justify: p.alignment = .justified
        }
        // Text cannot start left of the column in TextKit; negative indents start at the edge.
        let left = CGFloat(max(0, f.leftIndent))
        let first = CGFloat(max(0, f.leftIndent + f.firstLineIndent))
        p.headIndent = left
        p.firstLineHeadIndent = first
        if f.rightIndent > 0 { p.tailIndent = -CGFloat(f.rightIndent) }
        p.paragraphSpacingBefore = inCell ? 0 : before
        p.paragraphSpacing = inCell ? 0 : CGFloat(f.spaceAfter)
        switch f.lineSpacing {
        case .exactly(let h):
            p.minimumLineHeight = CGFloat(h)
            p.maximumLineHeight = CGFloat(h)
        case .atLeast(let h):
            p.minimumLineHeight = max(CGFloat(h), natural)
        case .multiple(let m):
            if let pitch, pitch > 0, f.snapToGrid, !inCell {
                // Word snaps each line to the grid: as many grid lines as the text needs.
                let lines = max(1, ceil(natural / pitch - 0.02))
                p.minimumLineHeight = lines * pitch * CGFloat(m)
            } else {
                p.minimumLineHeight = natural * CGFloat(m)
            }
        }
        var stops: [NSTextTab] = f.tabStops.map { t in
            let at = CGFloat(t.position)
            switch t.alignment {
            case .left: return NSTextTab(textAlignment: .left, location: at)
            case .center: return NSTextTab(textAlignment: .center, location: at)
            case .right: return NSTextTab(textAlignment: .right, location: at)
            case .decimal:
                // TextKit's decimal tab: right-aligned up to the decimal separator.
                return NSTextTab(textAlignment: .right, location: at,
                                 options: [.columnTerminators: NSTextTab.columnTerminators(for: Locale(identifier: "en_US_POSIX"))])
            }
        }
        // Word treats a hanging indent as a tab stop for the first line: list text and "1.<tab>text" start there.
        if first < left, !stops.contains(where: { abs($0.location - left) < 0.5 }) {
            stops.append(NSTextTab(textAlignment: .left, location: left))
        }
        p.tabStops = stops.sorted { $0.location < $1.location }
        p.defaultTabInterval = max(defaultTab, 1)
        return p
    }
}
