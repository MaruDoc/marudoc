import Foundation
import EnsoShared

/// Page ranges typed by the user ("1-3, 5, 8-10") and fixed-size chunks, 1-based. Pure text and arithmetic, so
/// the self-test can exercise it without a PDF.
public enum PageRanges {

    /// An inclusive run of pages.
    public struct Part: Equatable, Sendable {
        public let first: Int
        public let last: Int
        public init(first: Int, last: Int) { self.first = first; self.last = last }
        public var count: Int { last - first + 1 }
        /// "3" for one page, "1-3" for a run. Used in output file names.
        public var label: String { first == last ? "\(first)" : "\(first)-\(last)" }
    }

    public enum ParseError: LocalizedError, Equatable {
        case empty
        case invalid(String)
        case reversed(String)
        case outOfRange(String, pageCount: Int)
        case tooMany
        case badCount

        public var errorDescription: String? {
            switch self {
            case .empty: return L("ページ範囲を入力してください")
            case .invalid(let s): return String(format: L("「%@」は読み取れません。1-3, 5, 8-10 のように入力してください"), s)
            case .reversed(let s): return String(format: L("「%@」は前のページ番号が後ろより大きくなっています"), s)
            case .outOfRange(let s, let n): return String(format: L("「%@」はこの PDF のページ (1〜%d) の範囲外です"), s, n)
            case .tooMany: return L("範囲が多すぎます")
            case .badCount: return L("1 以上の数字を入力してください")
            }
        }
    }

    static let maxParts = 2000

    /// Full-width digits, dashes (－ ー 〜 ～ − – — ‐ ―) and commas (、 ，) become ASCII; all spaces are dropped.
    public static func normalize(_ text: String) -> String {
        var out = ""
        for u in text.unicodeScalars {
            switch u.value {
            case 0xFF10...0xFF19: out.unicodeScalars.append(Unicode.Scalar(u.value - 0xFF10 + 0x30)!)
            case 0xFF0D, 0x30FC, 0x301C, 0xFF5E, 0x2212, 0x2013, 0x2014, 0x2010, 0x2015, 0x2011, 0x207B: out += "-"
            case 0x3001, 0xFF0C, 0xFF64, 0x060C: out += ","
            default:
                if CharacterSet.whitespacesAndNewlines.contains(u) || u.value == 0x3000 { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// "1-3, 5, 8-10" -> [1...3, 5...5, 8...10]. Every part must lie inside 1...pageCount.
    public static func parse(_ text: String, pageCount: Int) throws -> [Part] {
        let parts = normalize(text).split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { throw ParseError.empty }
        guard parts.count <= maxParts else { throw ParseError.tooMany }
        var result: [Part] = []
        for raw in parts {
            let pieces = raw.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count <= 2, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else {
                throw ParseError.invalid(raw)
            }
            // A number too large for Int is simply beyond the last page.
            let numbers = pieces.map { Int($0) ?? Int.max }
            let first = numbers[0], last = numbers.count == 2 ? numbers[1] : numbers[0]
            guard first <= last else { throw ParseError.reversed(raw) }
            guard first >= 1, last <= pageCount else { throw ParseError.outOfRange(raw, pageCount: pageCount) }
            result.append(Part(first: first, last: last))
        }
        return result
    }

    /// Consecutive chunks of `n` pages; the last one may be shorter.
    public static func chunks(pageCount: Int, every n: Int) throws -> [Part] {
        guard n >= 1, pageCount >= 1 else { throw ParseError.badCount }
        var parts: [Part] = []
        var start = 1
        while start <= pageCount {
            parts.append(Part(first: start, last: min(pageCount, start + n - 1)))
            start += n
        }
        guard parts.count <= maxParts else { throw ParseError.tooMany }
        return parts
    }

    /// A positive whole number, typed in either digit width.
    public static func parseCount(_ text: String) throws -> Int {
        let s = normalize(text)
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(s), n >= 1 else { throw ParseError.badCount }
        return n
    }
}
