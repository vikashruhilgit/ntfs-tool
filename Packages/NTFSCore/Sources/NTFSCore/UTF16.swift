import Foundation

// Decode a little-endian UTF-16 byte sequence into a Swift String. Returns nil
// on malformed input: odd byte count, or a decoder error (e.g. unpaired
// surrogate). Used by Attribute.swift, FileName.swift, and (Block D) IndexEntry.
internal func decodeUTF16LE<S: Sequence>(_ bytes: S) -> String? where S.Element == UInt8 {
    var codeUnits: [UInt16] = []
    var pair: UInt8 = 0
    var index = 0
    for byte in bytes {
        if index % 2 == 0 {
            pair = byte
        } else {
            codeUnits.append(UInt16(pair) | (UInt16(byte) << 8))
        }
        index += 1
    }
    if index % 2 != 0 {
        // Odd byte count — last byte has no high half. Reject rather than
        // silently truncating.
        return nil
    }

    var decoder = UTF16()
    var iterator = codeUnits.makeIterator()
    var scalars: [Unicode.Scalar] = []
    while true {
        switch decoder.decode(&iterator) {
        case .scalarValue(let s): scalars.append(s)
        case .emptyInput:         return String(String.UnicodeScalarView(scalars))
        case .error:              return nil
        }
    }
}
