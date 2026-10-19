import Foundation

/// The bookkeeping behind "merge in the order I selected the files": a list of paths in selection order that is
/// updated from successive snapshots of Finder's selection. The app's SelectionOrderTracker feeds it; it lives here
/// so the rules can be tested without Finder.
public struct SelectionOrder: Sendable {
    public private(set) var paths: [String] = []
    public init() {}

    /// `selection` is Finder's current selection (standardized paths, in whatever order Finder reports).
    /// Items that are no longer selected are dropped, newly selected ones are appended, and a selection of one item
    /// or none resets the list to just that item. Several items that appear at once (a shift-click range, a
    /// rubber band) are appended in the order given.
    public mutating func update(with selection: [String]) {
        if selection.count <= 1 {
            paths = selection
            return
        }
        let now = Set(selection)
        var next = paths.filter { now.contains($0) }
        let have = Set(next)
        next += selection.filter { !have.contains($0) }
        paths = next
    }

    /// `urls` in selection order if this list covers exactly that set of files; otherwise `urls` unchanged, in the
    /// order they were received. There is deliberately no fallback to sorting by name: an arbitrary but honest order
    /// beats a plausible-looking wrong one. Exact equality (not "knows all of them") also guards against a stale
    /// list after the selection changed by keyboard or in another window.
    public func order(_ urls: [URL]) -> [URL] {
        guard urls.count > 1 else { return urls }
        let wanted = urls.map { $0.standardizedFileURL.path }
        guard Set(wanted).count == urls.count, paths.count == urls.count, Set(paths) == Set(wanted) else { return urls }
        let byPath = Dictionary(uniqueKeysWithValues: zip(wanted, urls))
        return paths.compactMap { byPath[$0] }
    }
}
