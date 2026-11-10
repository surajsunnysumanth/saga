import Foundation
import Compression

/// Minimal gzip (RFC 1952) using Apple's raw-deflate codec, so vault segments open with any gzip tool on any OS.
public enum Gzip {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i); for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }; return c
    }
    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in for b in p { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) } }
        return c ^ 0xFFFFFFFF
    }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }

    static func run(_ input: Data, encode: Bool) -> Data? {
        let dstSize = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize); defer { dst.deallocate() }
        let sp = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1); defer { sp.deallocate() }
        guard compression_stream_init(sp, encode ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(sp) }
        var out = Data(); var ok = true
        input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            sp.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dst)
            sp.pointee.src_size = src.count
            while true {
                sp.pointee.dst_ptr = dst; sp.pointee.dst_size = dstSize
                let st = compression_stream_process(sp, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(dst, count: dstSize - sp.pointee.dst_size)
                if st == COMPRESSION_STATUS_END { break }
                if st == COMPRESSION_STATUS_ERROR { ok = false; break }
            }
        }
        return ok ? out : nil
    }

    public static func compress(_ data: Data) -> Data {
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
        out.append(run(data, encode: true) ?? Data())
        out.append(contentsOf: le32(crc32(data))); out.append(contentsOf: le32(UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    /// Inflate a mapped segment without retaining its uncompressed contents.
    /// The buffer is valid only during `visit`. Validate both gzip trailer fields.
    static func forEachChunk(in gz: Data, chunkSize: Int = 64 * 1024,
                             _ visit: (UnsafeRawBufferPointer) throws -> Void) throws {
        func invalid() -> SQLiteError { .open("invalid gzip segment") }
        guard chunkSize > 0, gz.count >= 18 else { throw invalid() }
        try gz.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let bytes = src.bindMemory(to: UInt8.self)
            guard bytes[0] == 31, bytes[1] == 139, bytes[2] == 8, bytes[3] & 0xe0 == 0 else { throw invalid() }
            let flags = bytes[3], limit = bytes.count - 8
            var offset = 10
            if flags & 4 != 0 {
                guard offset + 2 <= limit else { throw invalid() }
                let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                offset += 2 + length
            }
            for flag: UInt8 in [8, 16] where flags & flag != 0 {
                while offset < limit, bytes[offset] != 0 { offset += 1 }
                guard offset < limit else { throw invalid() }
                offset += 1
            }
            if flags & 2 != 0 { offset += 2 }
            guard offset < limit else { throw invalid() }
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { dst.deallocate() }
            var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: bytes.baseAddress!, src_size: 0, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw invalid() }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = bytes.baseAddress!.advanced(by: offset)
            stream.src_size = limit - offset
            var crc: UInt32 = 0xffffffff, size: UInt32 = 0
            while true {
                stream.dst_ptr = dst; stream.dst_size = chunkSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw invalid() }
                let count = chunkSize - stream.dst_size
                let chunk = UnsafeRawBufferPointer(start: dst, count: count)
                for b in chunk { crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
                size &+= UInt32(truncatingIfNeeded: count)
                if count > 0 { try visit(chunk) }
                if status == COMPRESSION_STATUS_END { break }
                guard count > 0 else { throw invalid() }
            }
            func trailer(_ i: Int) -> UInt32 {
                UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            }
            guard stream.src_size == 0, crc ^ 0xffffffff == trailer(limit), size == trailer(limit + 4) else { throw invalid() }
        }
    }

    public static func decompress(_ gz: Data) -> Data? {
        guard gz.count > 18, gz[gz.startIndex] == 0x1f, gz[gz.startIndex + 1] == 0x8b else { return nil }
        let flags = gz[gz.startIndex + 3]
        var i = gz.startIndex + 10
        if flags & 4 != 0 { let n = Int(gz[i]) | Int(gz[i + 1]) << 8; i += 2 + n }
        if flags & 8 != 0 { while gz[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while gz[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        let body = gz[i..<(gz.endIndex - 8)]
        guard let out = run(Data(body), encode: false) else { return nil }
        let tail = Array(gz[(gz.endIndex - 8)...])
        let crc = UInt32(tail[0]) | UInt32(tail[1]) << 8 | UInt32(tail[2]) << 16 | UInt32(tail[3]) << 24
        return crc == crc32(out) ? out : nil
    }
}
