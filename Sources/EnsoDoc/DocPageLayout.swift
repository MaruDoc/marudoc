import Foundation
import CoreGraphics

// Page layout of a source that has one (Word): page size, margins, headers and footers per section, and the
// paragraph formatting Word lays the text out with. Only the PDF renderer (and the images made from its PDF) reads it;
// every other writer ignores it, so Markdown, HTML, text, RTF and Word output do not depend on it.

/// The document's sections and the settings that apply to all of them.
public struct DocPageLayout: Hashable, Sendable {
    public var sections: [DocSection]
    /// Word's default tab interval (settings.xml `w:defaultTabStop`), points.
    public var defaultTabStop: Double
    /// `w:evenAndOddHeaders`: even pages use the even header and footer.
    public var evenAndOddHeaders: Bool

    public init(sections: [DocSection], defaultTabStop: Double = 36, evenAndOddHeaders: Bool = false) {
        self.sections = sections; self.defaultTabStop = defaultTabStop; self.evenAndOddHeaders = evenAndOddHeaders
    }

    /// The section block `index` of DocModel.blocks belongs to.
    public func sectionIndex(forBlock index: Int) -> Int {
        var s = 0
        for (i, sec) in sections.enumerated() where sec.firstBlock <= index { s = i }
        return s
    }
}

/// Which header or footer of a section a page shows.
public enum DocHeaderKind: String, Hashable, Sendable { case `default`, first, even }

public struct DocSection: Hashable, Sendable {
    /// Index of the section's first block in DocModel.blocks.
    public var firstBlock: Int
    /// Page size in points (landscape sections are wider than tall).
    public var width: Double
    public var height: Double
    /// Page margins in points (the gutter is already added to the left margin).
    public var top: Double, left: Double, bottom: Double, right: Double
    /// Distance of the header from the top edge and of the footer from the bottom edge, points.
    public var headerDistance: Double
    public var footerDistance: Double
    /// Pitch of the document grid (`w:docGrid` of type lines): auto-spaced lines take whole multiples of it.
    public var linePitch: Double?
    /// `w:titlePg`: the section's first page shows the first-page header and footer.
    public var titlePage: Bool
    /// `w:pgNumType w:start`: page numbering restarts at this number on the section's first page.
    public var pageNumberStart: Int?
    /// `w:pgNumType w:fmt` (ST_NumberFormat: "decimal", "lowerRoman", …); nil = decimal.
    public var pageNumberFormat: String?
    /// Header and footer content by kind, already inherited from the previous section where Word inherits them.
    /// Page fields are the `DocField` placeholder characters in run text.
    public var headers: [DocHeaderKind: [DocBlock]]
    public var footers: [DocHeaderKind: [DocBlock]]

    public init(firstBlock: Int = 0, width: Double = 595.28, height: Double = 841.89, top: Double = 72, left: Double = 72,
                bottom: Double = 72, right: Double = 72, headerDistance: Double = 36, footerDistance: Double = 36,
                linePitch: Double? = nil, titlePage: Bool = false, pageNumberStart: Int? = nil, pageNumberFormat: String? = nil,
                headers: [DocHeaderKind: [DocBlock]] = [:], footers: [DocHeaderKind: [DocBlock]] = [:]) {
        self.firstBlock = firstBlock; self.width = width; self.height = height
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
        self.headerDistance = headerDistance; self.footerDistance = footerDistance; self.linePitch = linePitch
        self.titlePage = titlePage; self.pageNumberStart = pageNumberStart; self.pageNumberFormat = pageNumberFormat
        self.headers = headers; self.footers = footers
    }

    public var size: CGSize { CGSize(width: width, height: height) }
    /// Width of the text column.
    public var contentWidth: Double { max(width - left - right, 36) }
}

/// Page fields inside header and footer text. Each is one private-use character in a run; the PDF renderer replaces it
/// with the number of the page being drawn.
public enum DocField {
    /// PAGE: the page's number in the section's number format.
    public static let page: Character = "\u{E010}"
    /// NUMPAGES: pages in the document.
    public static let numPages: Character = "\u{E011}"
    /// SECTIONPAGES: pages in the page's section.
    public static let sectionPages: Character = "\u{E012}"
    public static let all: Set<Character> = [page, numPages, sectionPages]
}

/// Line spacing as Word sets it.
public enum DocLineSpacing: Hashable, Sendable {
    /// Multiples of the font's single line height (1 = single, 1.5, 2 = double).
    case multiple(Double)
    /// Every line exactly this tall, points.
    case exactly(Double)
    /// Lines at least this tall, points; taller where the text needs it.
    case atLeast(Double)
}

public struct DocTabStop: Hashable, Sendable {
    public enum Alignment: String, Hashable, Sendable { case left, center, right, decimal }
    public enum Leader: String, Hashable, Sendable { case none, dot, hyphen, underscore, middleDot }
    /// Distance from the left edge of the text column, points.
    public var position: Double
    public var alignment: Alignment
    public var leader: Leader
    public init(position: Double, alignment: Alignment = .left, leader: Leader = .none) {
        self.position = position; self.alignment = alignment; self.leader = leader
    }
}

/// Paragraph formatting resolved from the source's defaults, style chain, numbering and direct formatting. Lengths in
/// points.
public struct DocParagraphFormat: Hashable, Sendable {
    public var spaceBefore: Double = 0
    public var spaceAfter: Double = 0
    public var lineSpacing: DocLineSpacing = .multiple(1)
    public var leftIndent: Double = 0
    public var rightIndent: Double = 0
    /// First line relative to `leftIndent`; negative is a hanging indent.
    public var firstLineIndent: Double = 0
    public var tabStops: [DocTabStop] = []
    /// False when the paragraph ignores the document grid (`w:snapToGrid w:val="0"`).
    public var snapToGrid = true
    /// `w:keepNext`: the paragraph stays on the page of the one after it (headings).
    public var keepWithNext = false
    /// Set with `w:contextualSpacing`: the style id. Spacing between neighbours of the same style is dropped.
    public var contextualStyle: String?
    /// The runs with the paragraph style's character formatting applied. Set for headings only, whose `runs` the
    /// reader keeps free of the style so that other writers can give headings their own look.
    public var styledRuns: [DocRun]?
    /// Font size of the paragraph mark: the height of the paragraph when it has no text.
    public var markFontSize: Double?
    /// Empty paragraphs (blank lines) that stood right before this one. The reader drops empty paragraphs from the
    /// blocks; the PDF renderer puts them back as space.
    public var emptyBefore: [DocParagraphFormat] = []
    /// Border lines around the paragraph (Word's paragraph borders, or the outline of the text box it came from).
    public var borders: DocBorders?

    public init() {}
}

/// Lines drawn around a paragraph. Consecutive paragraphs with equal borders share one box, as in Word.
public struct DocBorders: Hashable, Sendable {
    public struct Edge: Hashable, Sendable {
        /// Line width in points.
        public var width: Double
        /// Distance between the line and the text, points.
        public var space: Double
        public var color: DocColor?
        public init(width: Double, space: Double = 0, color: DocColor? = nil) { self.width = width; self.space = space; self.color = color }
    }
    public var top: Edge?, left: Edge?, bottom: Edge?, right: Edge?
    /// Tells apart boxes that would otherwise merge (two text boxes one after the other).
    public var group: Int
    public init(top: Edge? = nil, left: Edge? = nil, bottom: Edge? = nil, right: Edge? = nil, group: Int = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right; self.group = group
    }
    public var isEmpty: Bool { top == nil && left == nil && bottom == nil && right == nil }
}

/// An inline picture's place in the source: pictures with the same `group` stood in one paragraph and share a line
/// where they fit, as Word sets them; `alignment` is that paragraph's.
public struct DocImagePlacement: Hashable, Sendable {
    public var group: Int
    public var alignment: DocAlignment
    public init(group: Int, alignment: DocAlignment) { self.group = group; self.alignment = alignment }
}
