import Foundation
import Compression

// ZIP container (PKWARE APPNOTE) with only what OOXML / ODF need:
// stored (0) and deflate (8) entries, data descriptors, ZIP64 on the reading side.

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            table.withUnsafeBufferPointer { t in
                for b in raw { crc = t[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Raw DEFLATE (RFC 1951) via Apple's Compression framework; COMPRESSION_ZLIB is headerless deflate.
enum Deflate {
    static func compress(_ data: Data) throws -> Data {
        try process(data, operation: COMPRESSION_STREAM_ENCODE, limit: Int.max, what: "deflate")
    }

    /// Inflates at most `limit` bytes; more output than that means a broken or hostile entry.
    static func decompress(_ data: Data, limit: Int, what: String) throws -> Data {
        try process(data, operation: COMPRESSION_STREAM_DECODE, limit: limit, what: what)
    }

    private static func process(_ input: Data, operation: compression_stream_operation, limit: Int, what: String) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw OfficeError.corruptZip("cannot initialise deflate for \(what)")
        }
        defer { compression_stream_destroy(stream) }

        let chunk = 256 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var output = Data()
        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummy.deallocate() }
        let flags = Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue)

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 0 {
                stream.pointee.src_ptr = base
                stream.pointee.src_size = raw.count
            } else {
                stream.pointee.src_ptr = UnsafePointer(dummy)
                stream.pointee.src_size = 0
            }
            while true {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, flags)
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 {
                    if output.count + produced > limit {
                        throw OfficeError.corruptZip("\(what) inflates to more than its declared size")
                    }
                    output.append(dst, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    // No progress with all input consumed: truncated stream.
                    if produced == 0 && stream.pointee.src_size == 0 {
                        throw OfficeError.corruptZip("\(what) is truncated")
                    }
                default:
                    throw OfficeError.corruptZip("\(what) has invalid compressed data")
                }
            }
        }
        return output
    }
}

extension Data {
    mutating func appendLE(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendLE(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
}

// MARK: - Writer

public final class ZipWriter {
    private struct Pending {
        let name: [UInt8]
        let utf8Flag: Bool
        let method: UInt16
        let crc: UInt32
        let compressed: Data
        let uncompressedSize: Int
    }

    private var entries: [Pending] = []
    private var names = Set<String>()
    private let dosTime: UInt16
    private let dosDate: UInt16

    public init(date: Date = Date()) {
        (dosTime, dosDate) = ZipWriter.dosDateTime(date)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Adds a file. Entries are written in the order added (put `[Content_Types].xml` or `mimetype` first).
    /// `compress: false` stores the bytes verbatim, as ODF requires for `mimetype`.
    public func add(path: String, data: Data, compress: Bool = true) throws {
        let name = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { throw OfficeError.invalidArgument("empty ZIP entry name") }
        guard names.insert(name.lowercased()).inserted else { throw OfficeError.invalidArgument("duplicate ZIP entry \(name)") }
        guard data.count < 0xFFFF_FFFF else { throw OfficeError.tooLarge("\(name) is larger than 4 GB") }

        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var payload = data
        if compress && data.count > 64 {
            let deflated = try Deflate.compress(data)
            if deflated.count < data.count { method = 8; payload = deflated }
        }
        let bytes = Array(name.utf8)
        guard bytes.count <= 0xFFFF else { throw OfficeError.invalidArgument("ZIP entry name too long") }
        entries.append(Pending(name: bytes, utf8Flag: bytes.contains { $0 >= 0x80 }, method: method,
                               crc: crc, compressed: payload, uncompressedSize: data.count))
    }

    public func add(path: String, text: String, compress: Bool = true) throws {
        try add(path: path, data: Data(text.utf8), compress: compress)
    }

    public func finalize() throws -> Data {
        guard entries.count < 0xFFFF else { throw OfficeError.tooLarge("more than 65,534 ZIP entries") }
        var out = Data()
        var central = Data()
        for e in entries {
            let offset = out.count
            guard offset < 0xFFFF_FFFF else { throw OfficeError.tooLarge("archive larger than 4 GB") }
            let flags: UInt16 = e.utf8Flag ? 0x0800 : 0
            let version: UInt16 = e.method == 8 ? 20 : 10

            out.appendLE(UInt32(0x0403_4B50))
            out.appendLE(version)
            out.appendLE(flags)
            out.appendLE(e.method)
            out.appendLE(dosTime); out.appendLE(dosDate)
            out.appendLE(e.crc)
            out.appendLE(UInt32(e.compressed.count))
            out.appendLE(UInt32(e.uncompressedSize))
            out.appendLE(UInt16(e.name.count))
            out.appendLE(UInt16(0))
            out.append(contentsOf: e.name)
            out.append(e.compressed)

            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(UInt16(20))          // made by: MS-DOS, spec 2.0
            central.appendLE(version)
            central.appendLE(flags)
            central.appendLE(e.method)
            central.appendLE(dosTime); central.appendLE(dosDate)
            central.appendLE(e.crc)
            central.appendLE(UInt32(e.compressed.count))
            central.appendLE(UInt32(e.uncompressedSize))
            central.appendLE(UInt16(e.name.count))
            central.appendLE(UInt16(0))           // extra
            central.appendLE(UInt16(0))           // comment
            central.appendLE(UInt16(0))           // disk
            central.appendLE(UInt16(0))           // internal attributes
            central.appendLE(UInt32(0))           // external attributes
            central.appendLE(UInt32(offset))
            central.append(contentsOf: e.name)
        }
        let cdOffset = out.count
        guard cdOffset + central.count < 0xFFFF_FFFF else { throw OfficeError.tooLarge("archive larger than 4 GB") }
        out.append(central)
        out.appendLE(UInt32(0x0605_4B50))
        out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count)); out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(central.count))
        out.appendLE(UInt32(cdOffset))
        out.appendLE(UInt16(0))
        return out
    }

    public func finalize(to url: URL) throws {
        try finalize().writeOffice(to: url)
    }

    static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(c.year ?? 1980, 1980), 2107)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

// MARK: - Reader

public struct ZipEntry: Sendable {
    public let path: String
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let method: UInt16
    public let crc32: UInt32
    public let flags: UInt16
    let localHeaderOffset: Int
    public var isDirectory: Bool { path.hasSuffix("/") }
    public var isEncrypted: Bool { flags & 1 != 0 }
}

public final class ZipReader {
    public let entries: [ZipEntry]
    private let data: Data
    private var exact: [String: Int] = [:]
    private var folded: [String: Int] = [:]
    /// Hard cap for a single inflated entry (protects against zip bombs).
    public static let maxEntrySize = 1 << 31

    public convenience init(url: URL) throws {
        try self.init(data: try Data.readOffice(url))
    }

    public init(data: Data) throws {
        self.data = data
        let b = Bytes(data: data)

        if b.count >= 8, (try? b.u32(0)) == 0xE011_CFD0, (try? b.u32(4)) == 0xE11A_B1A1 {
            throw OfficeError.encryptedOrLegacyOffice
        }
        guard b.count >= 22 else { throw OfficeError.notAZip("file too small") }

        // End of central directory: scan backwards over a possible archive comment.
        var eocd = -1
        var i = b.count - 22
        let stop = max(0, b.count - 22 - 0xFFFF)
        while i >= stop {
            if b.raw(i) == 0x50, b.raw(i + 1) == 0x4B, b.raw(i + 2) == 0x05, b.raw(i + 3) == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else {
            if (try? b.u32(0)) == 0x0403_4B50 { throw OfficeError.corruptZip("end of central directory not found (truncated file?)") }
            throw OfficeError.notAZip("no ZIP signature")
        }

        var total = Int(try b.u16(eocd + 10))
        var cdSize = Int(try b.u32(eocd + 12))
        var cdOffset = Int(try b.u32(eocd + 16))

        // ZIP64 end of central directory locator sits right before the classic record.
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF, eocd >= 20, (try? b.u32(eocd - 20)) == 0x0706_4B50 {
            let z = Int(try b.u64(eocd - 20 + 8))
            guard (try? b.u32(z)) == 0x0606_4B50 else { throw OfficeError.corruptZip("bad ZIP64 end record") }
            total = Int(try b.u64(z + 32))
            cdSize = Int(try b.u64(z + 40))
            cdOffset = Int(try b.u64(z + 48))
        }

        // Tolerate data prepended to the archive (all offsets are then off by the same amount).
        var base = 0
        if (try? b.u32(cdOffset)) != 0x0201_4B50 {
            let shifted = eocd - cdSize
            if shifted >= 0, (try? b.u32(shifted)) == 0x0201_4B50 {
                let (delta, overflow) = shifted.subtractingReportingOverflow(cdOffset)
                if overflow { throw OfficeError.corruptZip("central directory offset out of range") }
                base = delta; cdOffset = shifted
            } else {
                throw OfficeError.corruptZip("central directory not found")
            }
        }

        var list: [ZipEntry] = []
        list.reserveCapacity(min(total, 100_000))
        var p = cdOffset
        while (try? b.u32(p)) == 0x0201_4B50 {
            let flags = try b.u16(p + 8)
            let method = try b.u16(p + 10)
            let crc = try b.u32(p + 16)
            var csize = Int(try b.u32(p + 20))
            var usize = Int(try b.u32(p + 24))
            let nameLen = Int(try b.u16(p + 28))
            let extraLen = Int(try b.u16(p + 30))
            let commentLen = Int(try b.u16(p + 32))
            var offset = Int(try b.u32(p + 42))
            let nameBytes = try b.slice(p + 46, nameLen)
            let extra = try b.slice(p + 46 + nameLen, extraLen)

            // ZIP64 extended information: 8-byte values for fields saturated at 0xFFFFFFFF, in fixed order.
            if usize == 0xFFFF_FFFF || csize == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
                var q = 0
                while q + 4 <= extra.count {
                    let id = UInt16(extra[q]) | UInt16(extra[q + 1]) << 8
                    let len = Int(UInt16(extra[q + 2]) | UInt16(extra[q + 3]) << 8)
                    if id == 0x0001 {
                        var r = q + 4
                        func next() -> Int? {
                            guard r + 8 <= q + 4 + len, r + 8 <= extra.count else { return nil }
                            var v: UInt64 = 0
                            for k in 0..<8 { v |= UInt64(extra[r + k]) << UInt64(8 * k) }
                            r += 8
                            return v > UInt64(Int.max) ? nil : Int(v)
                        }
                        if usize == 0xFFFF_FFFF, let v = next() { usize = v }
                        if csize == 0xFFFF_FFFF, let v = next() { csize = v }
                        if offset == 0xFFFF_FFFF, let v = next() { offset = v }
                        break
                    }
                    q += 4 + len
                }
            }

            if csize < 0 || usize < 0 { throw OfficeError.corruptZip("negative size") }
            let name = ZipReader.decodeName(nameBytes, utf8: flags & 0x0800 != 0)
            // A hostile ZIP64 offset must not overflow; -1 makes the entry fail to open instead.
            let (shifted, overflow) = offset.addingReportingOverflow(base)
            let local = (overflow || shifted < 0 || shifted > b.count) ? -1 : shifted
            list.append(ZipEntry(path: name, compressedSize: csize, uncompressedSize: usize, method: method,
                                 crc32: crc, flags: flags, localHeaderOffset: local))
            p += 46 + nameLen + extraLen + commentLen
            if list.count > 1_000_000 { throw OfficeError.tooLarge("too many ZIP entries") }
        }
        guard !list.isEmpty || total == 0 else { throw OfficeError.corruptZip("empty central directory") }
        entries = list
        for (idx, e) in list.enumerated() {
            let key = ZipReader.normalize(e.path)
            if exact[key] == nil { exact[key] = idx }
            if folded[key.lowercased()] == nil { folded[key.lowercased()] = idx }
        }
    }

    public var entryNames: [String] { entries.filter { !$0.isDirectory }.map(\.path) }

    /// Looks up an entry. OPC part names are case-insensitive, so this falls back to a case-folded match.
    public func entry(_ path: String) -> ZipEntry? {
        let key = ZipReader.normalize(path)
        if let i = exact[key] ?? folded[key.lowercased()] { return entries[i] }
        if let decoded = key.removingPercentEncoding, decoded != key, let i = exact[decoded] ?? folded[decoded.lowercased()] {
            return entries[i]
        }
        return nil
    }

    public func contains(_ path: String) -> Bool { entry(path) != nil }

    public func data(_ path: String) throws -> Data {
        guard let e = entry(path) else { throw OfficeError.missingPart(path) }
        return try data(for: e)
    }

    public func data(for e: ZipEntry) throws -> Data {
        let b = Bytes(data: data)
        if e.isEncrypted { throw OfficeError.encryptedOrLegacyOffice }
        guard (try? b.u32(e.localHeaderOffset)) == 0x0403_4B50 else {
            throw OfficeError.corruptZip("local header of \(e.path) not found")
        }
        let nameLen = Int(try b.u16(e.localHeaderOffset + 26))
        let extraLen = Int(try b.u16(e.localHeaderOffset + 28))
        let start = e.localHeaderOffset + 30 + nameLen + extraLen   // localHeaderOffset <= count, the rest is < 200 KB
        guard e.compressedSize >= 0, start >= 0, start <= b.count, e.compressedSize <= b.count - start else {
            throw OfficeError.corruptZip("\(e.path) extends past the end of the file")
        }
        guard e.uncompressedSize <= ZipReader.maxEntrySize else { throw OfficeError.tooLarge("\(e.path) is too large") }
        let payload = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))

        let out: Data
        switch e.method {
        case 0:
            out = payload
        case 8:
            if e.compressedSize == 0 && e.uncompressedSize == 0 { return Data() }
            out = try Deflate.decompress(payload, limit: e.uncompressedSize, what: e.path)
        default:
            throw OfficeError.unsupportedZipFeature("compression method \(e.method) in \(e.path)")
        }
        guard out.count == e.uncompressedSize else { throw OfficeError.corruptZip("\(e.path) has the wrong size") }
        guard CRC32.checksum(out) == e.crc32 else { throw OfficeError.corruptZip("checksum mismatch in \(e.path)") }
        return out
    }

    static func normalize(_ path: String) -> String {
        var s = path.replacingOccurrences(of: "\\", with: "/")
        while s.hasPrefix("/") { s.removeFirst() }
        if s.hasPrefix("./") { s.removeFirst(2) }
        return s
    }

    private static func decodeName(_ bytes: [UInt8], utf8: Bool) -> String {
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        return String(bytes: bytes, encoding: cp437) ?? String(decoding: bytes, as: UTF8.self)
    }
}

/// Bounds-checked little-endian reads over Data (which may be a slice with a non-zero startIndex).
private struct Bytes {
    let data: Data
    var count: Int { data.count }

    @inline(__always) func raw(_ off: Int) -> UInt8 {
        guard off >= 0, off < data.count else { return 0 }
        return data[data.startIndex + off]
    }

    func u16(_ off: Int) throws -> UInt16 {
        guard off >= 0, off <= data.count - 2 else { throw OfficeError.corruptZip("unexpected end of file") }
        let s = data.startIndex + off
        return UInt16(data[s]) | UInt16(data[s + 1]) << 8
    }

    func u32(_ off: Int) throws -> UInt32 {
        guard off >= 0, off <= data.count - 4 else { throw OfficeError.corruptZip("unexpected end of file") }
        let s = data.startIndex + off
        return UInt32(data[s]) | UInt32(data[s + 1]) << 8 | UInt32(data[s + 2]) << 16 | UInt32(data[s + 3]) << 24
    }

    func u64(_ off: Int) throws -> UInt64 {
        guard off >= 0, off <= data.count - 8 else { throw OfficeError.corruptZip("unexpected end of file") }
        let lo = UInt64(try u32(off)), hi = UInt64(try u32(off + 4))
        let v = lo | hi << 32
        guard v < UInt64(Int.max) else { throw OfficeError.corruptZip("offset out of range") }
        return v
    }

    func slice(_ off: Int, _ len: Int) throws -> [UInt8] {
        guard off >= 0, len >= 0, off <= data.count, len <= data.count - off else { throw OfficeError.corruptZip("unexpected end of file") }
        return [UInt8](data[(data.startIndex + off)..<(data.startIndex + off + len)])
    }
}
