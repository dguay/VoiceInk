import Foundation

/// Repairs the header of a WAV file whose writer never closed it.
///
/// The recorder writes PCM samples straight through to disk, but the RIFF and
/// `data` chunk sizes are only filled in when the file is closed. After a crash
/// they still read zero, so players see an empty file. Finalizing sets both sizes
/// from the bytes actually on disk and drops a trailing partial frame.
enum InterruptedWAVFinalizer {
    struct Result: Equatable {
        let dataByteCount: Int
        let duration: TimeInterval
    }

    enum FinalizeError: Error, Equatable {
        case notWAV
        case missingFormat
        case missingData
    }

    private static let headerScanLimit = 1 << 20

    @discardableResult
    static func finalize(_ url: URL) throws -> Result {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let fileSize = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: min(fileSize, headerScanLimit)) ?? Data()
        let bytes = [UInt8](header)

        guard bytes.count >= 12,
            String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
            String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE"
        else {
            throw FinalizeError.notWAV
        }

        var blockAlign = 0
        var byteRate = 0
        var dataStart: Int?
        var offset = 12

        while offset + 8 <= bytes.count {
            let chunkID = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
            let chunkSize = Int(readUInt32(bytes, at: offset + 4))
            let bodyStart = offset + 8

            if chunkID == "fmt " {
                guard bodyStart + 16 <= bytes.count else { throw FinalizeError.missingFormat }
                byteRate = Int(readUInt32(bytes, at: bodyStart + 8))
                blockAlign = Int(readUInt16(bytes, at: bodyStart + 12))
            } else if chunkID == "data" {
                dataStart = bodyStart
                break
            }

            offset = bodyStart + chunkSize + (chunkSize & 1)
        }

        guard blockAlign > 0, byteRate > 0 else { throw FinalizeError.missingFormat }
        guard let dataStart, dataStart <= fileSize else { throw FinalizeError.missingData }

        let maximumDataBytes = Int(UInt32.max) - dataStart
        let availableBytes = min(fileSize - dataStart, maximumDataBytes)
        let dataByteCount = availableBytes - availableBytes % blockAlign
        let finalizedSize = dataStart + dataByteCount

        if finalizedSize < fileSize {
            try handle.truncate(atOffset: UInt64(finalizedSize))
        }

        try handle.seek(toOffset: 4)
        handle.write(littleEndian(UInt32(finalizedSize - 8)))
        try handle.seek(toOffset: UInt64(dataStart - 4))
        handle.write(littleEndian(UInt32(dataByteCount)))
        try handle.synchronize()

        return Result(
            dataByteCount: dataByteCount,
            duration: TimeInterval(dataByteCount) / TimeInterval(byteRate)
        )
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
