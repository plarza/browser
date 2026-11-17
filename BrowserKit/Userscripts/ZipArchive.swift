import Foundation

/// Just enough of a .zip to read a backup: every file's path and its
/// contents, stored or deflated, read where they are without unpacking
/// anything onto the disk.
struct ZipArchive {
    struct File {
        let path: String
        let contents: Data

        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    }

    let files: [File]

    private static let endOfDirectory: UInt32 = 0x0605_4b50, directoryEntry: UInt32 = 0x0201_4b50, localHeader: UInt32 = 0x0403_4b50
    private static let stored = 0, deflated = 8

    /// Nil when `data` isn't a zip this can read (one that is encrypted,
    /// say, or split, or too large for the plain format).
    init?(_ data: Data) {
        let bytes = Bytes(data)
        // The directory is at the end, before a comment of at most 65,535 bytes.
        let latest = bytes.count - 22
        guard latest >= 0,
              let end = stride(from: latest, through: max(0, latest - 0xffff), by: -1).first(where: { bytes.long($0) == ZipArchive.endOfDirectory }),
              let count = bytes.short(end + 10), var entry = bytes.long(end + 16).map(Int.init)
        else { return nil }
        var files: [File] = []
        for _ in 0 ..< count {
            guard bytes.long(entry) == ZipArchive.directoryEntry,
                  let flags = bytes.short(entry + 8), flags & 1 == 0, let method = bytes.short(entry + 10),
                  let packed = bytes.long(entry + 20), let size = bytes.long(entry + 24), packed != .max, size != .max,
                  let nameLength = bytes.short(entry + 28), let extraLength = bytes.short(entry + 30), let commentLength = bytes.short(entry + 32),
                  let header = bytes.long(entry + 42).map(Int.init), header != Int(UInt32.max),
                  let name = bytes.slice(entry + 46, nameLength)
            else { return nil }
            entry += 46 + nameLength + extraLength + commentLength
            let path = String(decoding: name, as: UTF8.self)
            if path.hasSuffix("/") { continue }
            // The file's own header has a name and extras of its own to step over.
            guard bytes.long(header) == ZipArchive.localHeader,
                  let ownNameLength = bytes.short(header + 26), let ownExtraLength = bytes.short(header + 28),
                  let body = bytes.slice(header + 30 + ownNameLength + ownExtraLength, Int(packed)),
                  let contents = ZipArchive.unpack(body, method: method, size: Int(size))
            else { return nil }
            files.append(File(path: path, contents: contents))
        }
        self.files = files
    }

    private static func unpack(_ body: Data, method: Int, size: Int) -> Data? {
        switch method {
        case stored: return body
        case deflated where size == 0: return Data()
        case deflated: return try? (body as NSData).decompressed(using: .zlib) as Data
        default: return nil
        }
    }

    /// A zip's bytes, read as its little-endian numbers; nil past the end.
    private struct Bytes {
        private let data: Data
        var count: Int { data.count }

        init(_ data: Data) { self.data = data }

        func slice(_ offset: Int, _ length: Int) -> Data? {
            guard offset >= 0, length >= 0, offset + length <= data.count else { return nil }
            return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + length)
        }

        func short(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= data.count else { return nil }
            let start = data.startIndex + offset
            return Int(data[start]) | Int(data[start + 1]) << 8
        }

        func long(_ offset: Int) -> UInt32? {
            guard let low = short(offset), let high = short(offset + 2) else { return nil }
            return UInt32(low) | UInt32(high) << 16
        }
    }
}
