import Foundation
import CoreGraphics
import Security
import os

/// The Finder extension and the app talk through a custom URL scheme:
///   marudoc://run?a=<action>&f=<path>&f=<path>&x=<mouseX>&y=<mouseY>
/// Opening the URL launches the app if it is not running.
public enum Bridge {
    public static let scheme = "marudoc"
    public static let appBundleID = "app.marudoc.MaruDoc"
    /// App Group shared by the app and the Finder extension. It carries the token that proves a request came from the extension.
    public static let appGroup = "FC2V887B8C.app.marudoc"
    private static let logger = Logger(subsystem: "app.marudoc.MaruDoc", category: "bridge")
    static let tokenKey = "bridgeToken"
    /// Self-test only: points the token store at a throwaway defaults domain.
    nonisolated(unsafe) public static var testGroupOverride: String?
    static var groupName: String { testGroupOverride ?? appGroup }

    static let previousTokenKey = "bridgeTokenPrevious"
    static let previousUntilKey = "bridgeTokenPreviousUntil"
    /// How long the token that was just replaced still works, so quick repeated clicks in Finder pass.
    public static let rotationGrace: TimeInterval = 5

    static func makeToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The app creates the token once (random 32 bytes, base64url) and keeps it in the shared group defaults.
    @discardableResult
    public static func prepareToken() -> String? {
        guard let defaults = UserDefaults(suiteName: groupName) else { return nil }
        if let existing = defaults.string(forKey: tokenKey), existing.utf8.count == 43 { return existing }
        guard let token = makeToken() else { return nil }
        defaults.set(token, forKey: tokenKey)
        return token
    }

    /// The extension reads this at click time, so it always sends the current token (also after a cold start).
    public static func storedToken() -> String? {
        UserDefaults(suiteName: groupName)?.string(forKey: tokenKey)
    }

    /// Replaces the token. The old one stays valid for `rotationGrace` seconds.
    @discardableResult
    static func rotateToken(now: Date = Date()) -> String? {
        guard let defaults = UserDefaults(suiteName: groupName) else {
            logger.error("rotateToken: App Group defaults unavailable")
            return nil
        }
        guard let fresh = makeToken() else {
            logger.error("rotateToken: could not generate a new token")
            return nil
        }
        if let old = defaults.string(forKey: tokenKey) {
            defaults.set(old, forKey: previousTokenKey)
            defaults.set(now.timeIntervalSince1970 + rotationGrace, forKey: previousUntilKey)
        }
        defaults.set(fresh, forKey: tokenKey)
        guard defaults.string(forKey: tokenKey) == fresh else {
            logger.error("rotateToken: new token was not stored")
            return nil
        }
        return fresh
    }

    static func constantTimeEqual(_ x: String, _ y: String) -> Bool {
        let a = Array(x.utf8), b = Array(y.utf8)
        var diff = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for i in 0..<max(a.count, b.count) {
            diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
        }
        return diff == 0
    }

    /// True when the request carries the current token, or the previous one within its grace period. Compared in constant time.
    public static func isAuthentic(_ request: Request, now: Date = Date()) -> Bool {
        guard let candidate = request.token, let defaults = UserDefaults(suiteName: groupName) else { return false }
        if let stored = defaults.string(forKey: tokenKey), !stored.isEmpty, constantTimeEqual(candidate, stored) { return true }
        if let previous = defaults.string(forKey: previousTokenKey), !previous.isEmpty,
           defaults.double(forKey: previousUntilKey) > now.timeIntervalSince1970, constantTimeEqual(candidate, previous) { return true }
        return false
    }

    /// Checks the request and, when it is accepted with the current token, rotates it. A request using the
    /// previous token (a fast second click) is accepted without rotating again.
    public static func authenticateAndRotate(_ request: Request, now: Date = Date()) -> Bool {
        guard isAuthentic(request, now: now) else { return false }
        if let candidate = request.token, let stored = storedToken(), constantTimeEqual(candidate, stored) { rotateToken(now: now) }
        return true
    }

    public struct Request: Sendable {
        public var action: String
        public var files: [URL]
        /// Global mouse location (Cocoa coordinates) when the user picked the item, used to place the HUD.
        public var mouse: CGPoint?
        /// Token from the shared App Group (`t=`); requests without a valid one need the user's confirmation.
        public var token: String?
        public init(action: String, files: [URL], mouse: CGPoint? = nil, token: String? = nil) {
            self.action = action; self.files = files; self.mouse = mouse; self.token = token
        }
    }

    public static func url(for request: Request) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "run"
        var items = [URLQueryItem(name: "a", value: request.action)]
        items += request.files.map { URLQueryItem(name: "f", value: $0.path) }
        if let m = request.mouse {
            items.append(URLQueryItem(name: "x", value: String(Int(m.x))))
            items.append(URLQueryItem(name: "y", value: String(Int(m.y))))
        }
        if let t = request.token { items.append(URLQueryItem(name: "t", value: t)) }
        c.queryItems = items
        return c.url
    }

    public static func request(from url: URL) -> Request? {
        guard url.scheme == scheme, url.host == "run",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = c.queryItems,
              let action = items.first(where: { $0.name == "a" })?.value else { return nil }
        let files = items.filter { $0.name == "f" }.compactMap(\.value).map { URL(fileURLWithPath: $0) }
        var mouse: CGPoint?
        if let x = items.first(where: { $0.name == "x" })?.value.flatMap(Double.init),
           let y = items.first(where: { $0.name == "y" })?.value.flatMap(Double.init) {
            mouse = CGPoint(x: x, y: y)
        }
        return Request(action: action, files: files, mouse: mouse, token: items.first(where: { $0.name == "t" })?.value)
    }
}
