import Foundation

// Little-endian fixed-width reads against a Data buffer at byte offsets.
// NTFS is little-endian on disk; Apple Silicon is also little-endian, so these
// helpers are conceptually free, but the explicit conversion enforces intent
// and guards against accidentally relying on host byte order.

extension Data {
    func readU8(at offset: Int) throws -> UInt8 {
        try ensureRange(offset: offset, length: 1)
        return self[startIndex + offset]
    }

    func readI8(at offset: Int) throws -> Int8 {
        Int8(bitPattern: try readU8(at: offset))
    }

    func readU16LE(at offset: Int) throws -> UInt16 {
        try ensureRange(offset: offset, length: 2)
        return UInt16(self[startIndex + offset]) |
               (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func readU32LE(at offset: Int) throws -> UInt32 {
        try ensureRange(offset: offset, length: 4)
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(self[startIndex + offset + i]) << (8 * i)
        }
        return value
    }

    func readU64LE(at offset: Int) throws -> UInt64 {
        try ensureRange(offset: offset, length: 8)
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(self[startIndex + offset + i]) << (8 * i)
        }
        return value
    }

    func readASCII(at offset: Int, length: Int) throws -> String {
        try ensureRange(offset: offset, length: length)
        let slice = self[(startIndex + offset)..<(startIndex + offset + length)]
        return String(decoding: slice, as: UTF8.self)
    }

    private func ensureRange(offset: Int, length: Int) throws {
        guard offset >= 0, length >= 0, offset + length <= count else {
            throw NTFSError.shortRead(expected: offset + length, got: count)
        }
    }
}
