import Foundation
import CryptoKit
import Compression

/// Decryption of WhatsApp crypt15 backups (`msgstore.db.crypt15`).
///
/// Format (matches wa-crypt-tools, the reference):
///   [1 byte: protobuf length][optional 0x01 feature flag][protobuf BackupPrefix]
///   [AES-256-GCM ciphertext][16-byte GCM tag][16-byte MD5 checksum of everything before it]
/// - IV: BackupPrefix.c15_iv (field 3) -> IV (field 1), 16 bytes.
/// - Key: HMAC chain over the 32-byte root key (the "64 hex digits" key), message "backup encryption".
/// - Plaintext is a zlib stream containing the SQLite database.
public enum Crypt15 {
    public enum Failure: Error, CustomStringConvertible {
        case badKey, badHeader(String), checksumMismatch, authFailed, inflateFailed
        public var description: String {
            switch self {
            case .badKey: return "key must be 64 hex digits"
            case .badHeader(let m): return "bad header: \(m)"
            case .checksumMismatch: return "file checksum mismatch (corrupted or incomplete file)"
            case .authFailed: return "decryption failed: wrong key or corrupted file"
            case .inflateFailed: return "could not decompress decrypted data"
            }
        }
    }

    public static func rootKey(hex: String) throws -> Data {
        let h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard h.count == 64 else { throw Failure.badKey }
        var out = Data(); var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { throw Failure.badKey }
            out.append(b); i = j
        }
        return out
    }

    /// WhatsApp's key derivation: privateKey = HMAC(zeros32, root); out = HMAC(privateKey, message || 0x01)
    static func derive(root: Data, message: String) -> SymmetricKey {
        let priv = HMAC<SHA256>.authenticationCode(for: root, using: SymmetricKey(data: Data(repeating: 0, count: 32)))
        var h = HMAC<SHA256>(key: SymmetricKey(data: Data(priv)))
        h.update(data: Data(message.utf8))
        h.update(data: Data([1]))
        return SymmetricKey(data: Data(h.finalize()))
    }

    /// Minimal protobuf reader: returns the payload of a length-delimited field.
    static func field(_ number: Int, in data: Data) -> Data? {
        var i = data.startIndex
        func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < data.endIndex {
                let b = data[i]; i += 1
                v |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while i < data.endIndex {
            guard let tag = varint() else { return nil }
            let num = Int(tag >> 3), wire = Int(tag & 7)
            switch wire {
            case 0: _ = varint()
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let len = varint(), i + Int(len) <= data.endIndex else { return nil }
                let slice = data[i..<(i + Int(len))]; i += Int(len)
                if num == number { return Data(slice) }
            default: return nil
            }
        }
        return nil
    }

    /// Decrypt `file` and return the plain SQLite bytes.
    public static func decrypt(file: Data, rootKeyHex: String) throws -> Data {
        let root = try rootKey(hex: rootKeyHex)
        guard file.count > 64 else { throw Failure.badHeader("file too small") }
        let base = file.startIndex
        let protoLen = Int(file[base])
        var offset = 1
        if file[base + 1] == 1 { offset = 2 }
        guard offset + protoLen < file.count else { throw Failure.badHeader("length") }
        let proto = file[(base + offset)..<(base + offset + protoLen)]
        guard let c15 = field(3, in: Data(proto)), let iv = field(1, in: c15), iv.count == 16 else {
            throw Failure.badHeader("no crypt15 IV (not a crypt15 file?)")
        }
        let bodyStart = base + offset + protoLen
        let tagStart = file.endIndex - 32
        let checksumStart = file.endIndex - 16
        let ciphertext = file[bodyStart..<tagStart]
        let tag = file[tagStart..<checksumStart]

        // MD5 over header + ciphertext + tag must equal the trailing checksum (absent in multi-file backups)
        var md5 = Insecure.MD5()
        md5.update(data: file[base..<checksumStart])
        let isMultiFile = Data(md5.finalize()) != Data(file[checksumStart...])

        let key = derive(root: root, message: "backup encryption")
        let nonce = try AES.GCM.Nonce(data: iv)
        let plain: Data
        do {
            if !isMultiFile {
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
                plain = try AES.GCM.open(box, using: key)
            } else {  // multi-file: the last 16 bytes are the real tag, "tag" bytes are ciphertext
                let ct = file[bodyStart..<checksumStart]
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: file[checksumStart...])
                plain = try AES.GCM.open(box, using: key)
            }
        } catch { throw Failure.authFailed }
        return try inflate(plain)
    }

    /// zlib stream -> raw bytes (Apple's COMPRESSION_ZLIB is raw deflate, so skip the 2-byte zlib header).
    static func inflate(_ zlib: Data) throws -> Data {
        guard zlib.count > 2 else { throw Failure.inflateFailed }
        let raw = zlib.dropFirst(2)
        let dstSize = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.inflateFailed
        }
        defer { compression_stream_destroy(streamPtr) }
        var out = Data()
        try raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            streamPtr.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            streamPtr.pointee.src_size = src.count
            while true {
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = dstSize
                let st = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(dst, count: dstSize - streamPtr.pointee.dst_size)
                if st == COMPRESSION_STATUS_END { break }
                if st == COMPRESSION_STATUS_ERROR { throw Failure.inflateFailed }
            }
        }
        return out
    }
}
