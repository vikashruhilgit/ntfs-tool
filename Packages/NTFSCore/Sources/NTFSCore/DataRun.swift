import Foundation

// One contiguous run of clusters on the volume. Sparse extents have no
// physical allocation, so `startLCN == nil`.
public struct Extent: Equatable, Sendable {
    /// Starting Logical Cluster Number, or nil for a sparse run.
    public let startLCN: UInt64?
    public let clusterCount: UInt64

    public init(startLCN: UInt64?, clusterCount: UInt64) {
        self.startLCN = startLCN
        self.clusterCount = clusterCount
    }

    public var isSparse: Bool { startLCN == nil }
}

// Decode an NTFS data runlist into a list of Extents.
//
// On-disk encoding (per Linux-NTFS docs):
//   - Each run begins with a header byte: low nibble = byte-width of the
//     length field (L), high nibble = byte-width of the offset field (V).
//   - Then L bytes of unsigned cluster count (little-endian).
//   - Then V bytes of *signed* cluster offset (little-endian, sign-extended).
//     The offset is a delta from the previous run's startLCN. The first
//     run's offset is absolute (delta from 0).
//   - V == 0 marks a sparse run: no physical allocation, no offset bytes.
//   - A header byte of 0x00 terminates the runlist.
public enum DataRun {

    public static func decode(_ data: Data) throws -> [Extent] {
        var extents: [Extent] = []
        var cursor = 0
        var previousLCN: Int64 = 0

        while cursor < data.count {
            let header = try data.readU8(at: cursor)
            cursor += 1
            if header == 0 { break }

            let lengthWidth = Int(header & 0x0F)
            let offsetWidth = Int((header & 0xF0) >> 4)

            guard lengthWidth > 0, lengthWidth <= 8 else {
                throw NTFSError.corruptOnDisk(
                    description: "data run header 0x\(String(format: "%02X", header)) has invalid length width \(lengthWidth)"
                )
            }
            guard offsetWidth <= 8 else {
                throw NTFSError.corruptOnDisk(
                    description: "data run header 0x\(String(format: "%02X", header)) has invalid offset width \(offsetWidth)"
                )
            }
            guard cursor + lengthWidth + offsetWidth <= data.count else {
                throw NTFSError.corruptOnDisk(
                    description: "data run truncated: header 0x\(String(format: "%02X", header)) at offset \(cursor - 1) but only \(data.count - cursor) bytes remain"
                )
            }

            let length = try readUnsignedLE(data, at: cursor, width: lengthWidth)
            cursor += lengthWidth

            if offsetWidth == 0 {
                // Sparse run.
                extents.append(Extent(startLCN: nil, clusterCount: length))
                continue
            }

            let delta = try readSignedLE(data, at: cursor, width: offsetWidth)
            cursor += offsetWidth

            let newLCN = previousLCN &+ delta
            guard newLCN >= 0 else {
                throw NTFSError.corruptOnDisk(
                    description: "data run produced negative starting LCN \(newLCN) at offset \(cursor)"
                )
            }
            extents.append(Extent(startLCN: UInt64(newLCN), clusterCount: length))
            previousLCN = newLCN
        }

        return extents
    }

    /// Total cluster count across all extents (sparse or not).
    public static func totalClusters(_ extents: [Extent]) -> UInt64 {
        extents.reduce(0) { $0 + $1.clusterCount }
    }

    // MARK: - Helpers

    private static func readUnsignedLE(_ data: Data, at offset: Int, width: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<width {
            let byte = try data.readU8(at: offset + i)
            value |= UInt64(byte) << (8 * i)
        }
        return value
    }

    /// Read a width-byte signed integer in little-endian, sign-extended to Int64.
    private static func readSignedLE(_ data: Data, at offset: Int, width: Int) throws -> Int64 {
        var unsigned: UInt64 = 0
        for i in 0..<width {
            let byte = try data.readU8(at: offset + i)
            unsigned |= UInt64(byte) << (8 * i)
        }
        // Sign-extend: if the top bit of the highest byte is set, extend with 1s.
        if width < 8 {
            let signBit = UInt64(1) << (8 * width - 1)
            if (unsigned & signBit) != 0 {
                let mask = UInt64.max << (8 * width)
                unsigned |= mask
            }
        }
        return Int64(bitPattern: unsigned)
    }
}
