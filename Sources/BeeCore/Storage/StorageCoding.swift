import Foundation

/// The JSON dialect of every file Bee writes: stable across saves (sorted keys), readable and
/// diff-friendly (pretty-printed, plain slashes), with ISO 8601 dates.
enum StorageCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
