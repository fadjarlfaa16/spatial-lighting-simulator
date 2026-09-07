import Foundation
import simd

nonisolated enum AnalysisCacheKind: String, Sendable {
    case normals
    case foregroundMask
}

nonisolated enum AnalysisCacheError: LocalizedError {
    case invalidHeader
    case invalidDimensions
    case truncatedData

    var errorDescription: String? {
        switch self {
        case .invalidHeader: "Cache analysis memiliki format yang tidak dikenali."
        case .invalidDimensions: "Dimensi cache analysis tidak valid."
        case .truncatedData: "Data cache analysis tidak lengkap."
        }
    }
}

/// Compact binary sidecars referenced by project JSON. Normals are stored as
/// Float16 unit vectors; the foreground mask retains its original UInt8 alpha.
/// This avoids repeating Core ML while keeping large pixel arrays out of JSON.
nonisolated enum AnalysisCacheCodec {
    private static let normalMagic: [UInt8] = [0x4E, 0x52, 0x4D, 0x31] // NRM1
    private static let maskMagic: [UInt8] = [0x4D, 0x53, 0x4B, 0x31] // MSK1

    static func encode(_ buffer: NormalBuffer) throws -> Data {
        guard valid(width: buffer.width, height: buffer.height),
              buffer.normals.count == buffer.width * buffer.height else {
            throw AnalysisCacheError.invalidDimensions
        }
        var data = Data(normalMagic)
        append(UInt32(buffer.width), to: &data)
        append(UInt32(buffer.height), to: &data)
        data.reserveCapacity(12 + buffer.normals.count * 6)
        for value in buffer.normals {
            append(Float16(value.x).bitPattern, to: &data)
            append(Float16(value.y).bitPattern, to: &data)
            append(Float16(value.z).bitPattern, to: &data)
        }
        return data
    }

    static func decodeNormals(_ data: Data) throws -> NormalBuffer {
        var reader = Reader(data: data)
        guard try reader.bytes(count: 4) == normalMagic else {
            throw AnalysisCacheError.invalidHeader
        }
        let width = Int(try reader.uint32())
        let height = Int(try reader.uint32())
        guard valid(width: width, height: height),
              reader.remaining == width * height * 6 else {
            throw AnalysisCacheError.invalidDimensions
        }
        var normals = [SIMD3<Float>]()
        normals.reserveCapacity(width * height)
        for _ in 0..<(width * height) {
            let raw = SIMD3<Float>(
                Float(Float16(bitPattern: try reader.uint16())),
                Float(Float16(bitPattern: try reader.uint16())),
                Float(Float16(bitPattern: try reader.uint16()))
            )
            let length = simd_length(raw)
            normals.append(
                raw.x.isFinite && raw.y.isFinite && raw.z.isFinite && length > 1e-8
                ? raw / length : .zero
            )
        }
        return NormalBuffer(width: width, height: height, normals: normals)
    }

    static func encode(_ buffer: ForegroundMaskBuffer) throws -> Data {
        guard valid(width: buffer.width, height: buffer.height),
              buffer.coverage.count == buffer.width * buffer.height else {
            throw AnalysisCacheError.invalidDimensions
        }
        var data = Data(maskMagic)
        append(UInt32(buffer.width), to: &data)
        append(UInt32(buffer.height), to: &data)
        data.append(contentsOf: buffer.coverage)
        return data
    }

    static func decodeMask(_ data: Data) throws -> ForegroundMaskBuffer {
        var reader = Reader(data: data)
        guard try reader.bytes(count: 4) == maskMagic else {
            throw AnalysisCacheError.invalidHeader
        }
        let width = Int(try reader.uint32())
        let height = Int(try reader.uint32())
        guard valid(width: width, height: height), reader.remaining == width * height else {
            throw AnalysisCacheError.invalidDimensions
        }
        return ForegroundMaskBuffer(
            width: width,
            height: height,
            coverage: try reader.bytes(count: width * height)
        )
    }

    private static func valid(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= 8_192 && height <= 8_192
            && width <= Int.max / height
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private struct Reader {
        let data: Data
        var offset = 0
        var remaining: Int { data.count - offset }

        mutating func bytes(count: Int) throws -> [UInt8] {
            guard count >= 0, remaining >= count else { throw AnalysisCacheError.truncatedData }
            defer { offset += count }
            return Array(data[offset..<(offset + count)])
        }

        mutating func uint16() throws -> UInt16 {
            let value = try bytes(count: 2)
            return UInt16(value[0]) | UInt16(value[1]) << 8
        }

        mutating func uint32() throws -> UInt32 {
            let value = try bytes(count: 4)
            return UInt32(value[0]) | UInt32(value[1]) << 8
                | UInt32(value[2]) << 16 | UInt32(value[3]) << 24
        }
    }
}
