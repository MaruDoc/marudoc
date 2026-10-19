import Foundation

/// Conversions and limits for numbers that come from untrusted files. Swift traps on a bad `Int(Double)`,
/// so anything read from a document goes through here.
public enum SafeInt {
    /// Images beyond this many pixels are refused (300 megapixels).
    public static let maxImagePixels = 300_000_000

    /// Rounds toward -infinity and clamps to lo...hi. NaN becomes `lo`.
    public static func floor(_ v: Double, _ lo: Int = -1_000_000_000, _ hi: Int = 1_000_000_000) -> Int {
        guard !v.isNaN else { return lo }
        return clamped(v.rounded(.down), lo, hi)
    }

    /// Rounds to nearest and clamps to lo...hi. NaN becomes `lo`.
    public static func round(_ v: Double, _ lo: Int = -1_000_000_000, _ hi: Int = 1_000_000_000) -> Int {
        guard !v.isNaN else { return lo }
        return clamped(v.rounded(), lo, hi)
    }

    private static func clamped(_ v: Double, _ lo: Int, _ hi: Int) -> Int {
        if v <= Double(lo) { return lo }
        if v >= Double(hi) { return hi }
        return Int(v)
    }

    /// True when width x height is positive and within `maxImagePixels` (no overflow possible).
    public static func isReasonablePixelSize(_ w: Int, _ h: Int, limit: Int = maxImagePixels) -> Bool {
        guard w > 0, h > 0, w <= limit, h <= limit else { return false }
        let (p, overflow) = w.multipliedReportingOverflow(by: h)
        return !overflow && p <= limit
    }
}
