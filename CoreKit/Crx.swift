import CryptoKit
import Foundation
import Security

/// Extensions from the Chrome Web Store: the store's CRX3 package, checked
/// and unpacked into Core's own folder.
///
/// A CRX3 file is `Cr24`, a version, a header length, a protobuf header and
/// then the zip. The header carries the extension's public key and an RSA
/// signature over the zip; an extension's id is the first 16 bytes of the
/// SHA-256 of that key, spelled with the letters a to p. So a package is
/// accepted only if its key spells the id that was asked for and its
/// signature holds over what came with it.
enum Crx {
    enum Refused: LocalizedError {
        case notAnID, http(Int), notCrx, badSignature, unzip

        var errorDescription: String? {
            switch self {
            case .notAnID: "That isn't a Chrome Web Store link or extension ID"
            case .http(let status): "The Chrome Web Store answered \(status)"
            case .notCrx: "That isn't a Chrome extension package"
            case .badSignature: "The package's signature doesn't match the extension"
            case .unzip: "The package couldn't be unpacked"
            }
        }
    }

    /// Chrome's version as told to the store; some extensions are only
    /// offered to recent versions.
    static let chromeVersion = "156.0.0.0"

    /// The id in a store link, or a bare id.
    static func id(in text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isID: (Substring) -> Bool = { $0.count == 32 && $0.allSatisfy { ("a"..."p").contains($0) } }
        if isID(Substring(text)) { return text }
        guard let url = URL(string: text), let host = url.host,
              host == "chromewebstore.google.com" || host == "chrome.google.com"
        else { return nil }
        return url.pathComponents.first { isID(Substring($0)) }
    }

    /// An id for a folder loaded from disk, from its full path, so the same
    /// folder always gets the same one.
    static func unpackedID(for folder: URL) -> String {
        spell(Array(SHA256.hash(data: Data(folder.resolvingSymlinksInPath().path.utf8)).prefix(16)))
    }

    static func spell(_ bytes: [UInt8]) -> String {
        let letters = Array("abcdefghijklmnop")
        return String(bytes.flatMap { [letters[Int($0 >> 4)], letters[Int($0 & 0xF)]] })
    }

    static func fetch(_ id: String) async throws -> Data {
        var url = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        url.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc"),
        ]
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else { throw Refused.http(status) }
        return data
    }

    /// The zip inside a CRX3 package whose key and signature match `id`.
    static func verifiedZip(_ package: Data, id: String) throws -> Data {
        let bytes = [UInt8](package)
        func uint32(at i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        guard bytes.count > 12, bytes[0 ..< 4] == [0x43, 0x72, 0x32, 0x34], uint32(at: 4) == 3 else { throw Refused.notCrx }
        let headerEnd = 12 + uint32(at: 8)
        guard headerEnd <= bytes.count else { throw Refused.notCrx }
        let header = Protobuf(Array(bytes[12 ..< headerEnd]))
        let zip = Data(bytes[headerEnd...])

        // Field 10000: the signed header data, whose field 1 is the crx id.
        guard let signedData = header.fields(10000).first,
              let crxID = Protobuf(signedData).fields(1).first, spell(crxID) == id
        else { throw Refused.badSignature }

        // What each proof signs: a fixed label, the signed data, the zip.
        var signed = Data("CRX3 SignedData\0".utf8)
        withUnsafeBytes(of: UInt32(signedData.count).littleEndian) { signed.append(contentsOf: $0) }
        signed.append(contentsOf: signedData)
        signed.append(zip)

        // Field 2: RSA proofs (1 = public key, 2 = signature). One of them
        // must be by the key the id is made from.
        let trusted = header.fields(2).map(Protobuf.init).contains { proof in
            guard let key = proof.fields(1).first, let signature = proof.fields(2).first,
                  spell(Array(SHA256.hash(data: Data(key)).prefix(16))) == id
            else { return false }
            return rsaVerifies(key: Data(key), signature: Data(signature), message: signed)
        }
        guard trusted else { throw Refused.badSignature }
        return zip
    }

    static func rsaVerifies(key: Data, signature: Data, message: Data) -> Bool {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(key as CFData, attributes as CFDictionary, nil)
                ?? SecKeyCreateWithData(subjectPublicKey(key) as CFData, attributes as CFDictionary, nil)
        else { return false }
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }

    /// The RSA key inside a DER SubjectPublicKeyInfo, which is how CRX
    /// stores it and not how Security wants it.
    static func subjectPublicKey(_ der: Data) -> Data {
        let bytes = [UInt8](der)
        // The key is the BIT STRING's contents: find 0x03, its length, then
        // skip the "unused bits" byte.
        var i = 0
        while i < bytes.count, bytes[i] != 0x03 { i += 1 }
        guard i + 2 < bytes.count else { return der }
        var length = Int(bytes[i + 1]), start = i + 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            length = bytes[(i + 2) ..< (i + 2 + count)].reduce(0) { $0 << 8 | Int($1) }
            start = i + 2 + count
        }
        guard start + length <= bytes.count, length > 1 else { return der }
        return Data(bytes[(start + 1) ..< (start + length)])
    }

    /// Unpacks `zip` into `folder`, replacing what was there.
    static func unpack(_ zip: Data, into folder: URL) throws {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("core-extension-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: work) }
        let archive = work.appendingPathComponent("package.zip")
        try zip.write(to: archive)
        let out = work.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, out.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0, files.fileExists(atPath: out.appendingPathComponent("manifest.json").path) else { throw Refused.unzip }
        try? files.removeItem(at: folder)
        try files.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: out, to: folder)
    }
}

/// Just enough protobuf to read a CRX header: length-delimited fields by
/// number, skipping the rest.
struct Protobuf {
    private var entries: [(Int, [UInt8])] = []

    init(_ bytes: [UInt8]) {
        var i = 0
        func varint() -> Int? {
            var value = 0, shift = 0
            while i < bytes.count, shift < 63 {
                let byte = bytes[i]
                i += 1
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while i < bytes.count, let tag = varint() {
            switch tag & 7 {
            case 0: _ = varint()
            case 1: i += 8
            case 2:
                guard let length = varint(), length >= 0, i + length <= bytes.count else { return }
                entries.append((tag >> 3, Array(bytes[i ..< i + length])))
                i += length
            case 5: i += 4
            default: return
            }
        }
    }

    func fields(_ number: Int) -> [[UInt8]] { entries.filter { $0.0 == number }.map(\.1) }
}
