import Foundation

/// Streams a `.jsonl` file line by line from a byte offset.
///
/// Agent transcripts grow without bound — a long-running project easily reaches
/// hundreds of megabytes — so we never load one into memory and we resume from
/// where the last scan stopped instead of re-reading the whole file.
enum JSONLReader {
    static let chunkSize = 1 << 18  // 256 KB

    /// Reads whole lines starting at `offset`, calling `handler` for each.
    /// Returns the offset just past the last *complete* line, so a partial line
    /// at the tail (the agent is still writing) is picked up on the next pass.
    @discardableResult
    static func stream(
        path: String,
        from offset: UInt64,
        handler: (Data) -> Void
    ) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return offset
        }

        var consumed = offset
        var carry = Data()
        let newline = UInt8(ascii: "\n")

        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                break
            }
            if chunk.isEmpty { break }

            carry.append(chunk)
            var lineStart = carry.startIndex

            while let idx = carry[lineStart...].firstIndex(of: newline) {
                let line = carry[lineStart..<idx]
                if !line.isEmpty { handler(Data(line)) }
                consumed += UInt64(idx - lineStart + 1)
                lineStart = carry.index(after: idx)
            }

            carry = Data(carry[lineStart...])
            // A single line larger than our buffer would otherwise grow `carry`
            // forever; such a line is not a record we can use anyway.
            if carry.count > 8 * chunkSize {
                consumed += UInt64(carry.count)
                carry.removeAll(keepingCapacity: true)
            }
        }

        return consumed
    }
}

/// ISO-8601 timestamps arrive with and without fractional seconds depending on
/// the tool and its version, so we try both and cache the formatters.
enum TimestampParser {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}
