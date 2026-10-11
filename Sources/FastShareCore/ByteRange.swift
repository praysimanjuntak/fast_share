/// Outcome of evaluating a `Range` request header against a file (RFC 9110 §14).
public enum ByteRangeSelection: Sendable, Equatable {
    /// Send the whole file with 200: no header, or one the server chooses to ignore.
    case entire
    /// Send these inclusive byte offsets with 206.
    case partial(ClosedRange<UInt64>)
    /// Reply 416: the range starts beyond the end of the file.
    case unsatisfiable
}

public enum ByteRange {
    /// Honors a single `bytes=` range. Multiple ranges and malformed headers fall back to
    /// `.entire`, which RFC 9110 permits; video players and download resumers send single ranges.
    public static func select(header: String?, fileSize size: UInt64) -> ByteRangeSelection {
        guard let header else { return .entire }
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.count > 6, value.prefix(6).lowercased() == "bytes=" else { return .entire }
        let spec = value.dropFirst(6)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .entire }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)

        if first.isEmpty {
            // Suffix form `-N`: the final N bytes.
            guard let suffixLength = number(last) else { return .entire }
            guard suffixLength > 0, size > 0 else { return .unsatisfiable }
            return .partial((size - min(suffixLength, size))...(size - 1))
        }

        guard let start = number(first) else { return .entire }
        var end = UInt64.max
        if !last.isEmpty {
            guard let value = number(last), value >= start else { return .entire }
            end = value
        }
        guard start < size else { return .unsatisfiable }
        return .partial(start...min(end, size - 1))
    }

    private static func number(_ text: String) -> UInt64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return UInt64(text)
    }
}
