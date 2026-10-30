import Foundation

/// Bộ ghi protobuf tối giản (wire format) — chỉ dùng cho 2 message của Steam.
struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    private mutating func putVarint(_ v: UInt64) {
        var value = v
        repeat {
            var b = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { b |= 0x80 }
            bytes.append(b)
        } while value != 0
    }

    private mutating func tag(_ field: Int, _ wire: UInt64) {
        putVarint((UInt64(field) << 3) | wire)
    }

    mutating func int32(_ field: Int, _ value: Int32) {
        tag(field, 0)
        // int32 trong protobuf: số âm sign-extend thành 64-bit; version luôn dương nên an toàn.
        putVarint(UInt64(bitPattern: Int64(value)))
    }

    mutating func uint64(_ field: Int, _ value: UInt64) {
        tag(field, 0); putVarint(value)
    }

    mutating func fixed64(_ field: Int, _ value: UInt64) {
        tag(field, 1)
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
    }

    mutating func bytesField(_ field: Int, _ value: [UInt8]) {
        tag(field, 2); putVarint(UInt64(value.count)); bytes.append(contentsOf: value)
    }

    mutating func string(_ field: Int, _ value: String) {
        bytesField(field, Array(value.utf8))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        tag(field, 0); putVarint(value ? 1 : 0)
    }

    var data: Data { Data(bytes) }
}

/// Bộ đọc protobuf tối giản — lấy các field string theo số thứ tự.
struct ProtoReader {
    private let b: [UInt8]
    private var i = 0
    init(_ data: Data) { b = [UInt8](data) }

    private mutating func varint() -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while i < b.count {
            let byte = b[i]; i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// Trả về map: field number -> chuỗi UTF-8 (chỉ các field wire-type 2).
    mutating func readStringFields() -> [Int: String] {
        var out: [Int: String] = [:]
        while i < b.count {
            guard let key = varint() else { break }
            let field = Int(key >> 3)
            let wire = key & 7
            switch wire {
            case 0: _ = varint()                       // varint
            case 1: i += 8                             // 64-bit
            case 5: i += 4                             // 32-bit
            case 2:                                     // length-delimited
                guard let len = varint() else { return out }
                let n = Int(len)
                guard i + n <= b.count else { return out }
                if let s = String(bytes: b[i..<i+n], encoding: .utf8) { out[field] = s }
                i += n
            default: return out
            }
        }
        return out
    }
}
