import BeeCore
import Foundation

/// How the response page spells durations, sizes and times.
enum ResponseFormat {
    /// Milliseconds below one second, then seconds with two decimals.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 1 else {
            let milliseconds = max(seconds, 0) * 1000
            if milliseconds > 0, milliseconds < 10 { return String(format: "%.1f ms", milliseconds) }
            return "\(Int(milliseconds.rounded())) ms"
        }
        return String(format: "%.2f s", seconds)
    }

    /// B, KB or MB, in decimal units as the Finder counts them.
    static func size(_ bytes: Int) -> String {
        switch bytes {
        case ..<1000: "\(bytes) B"
        case ..<1_000_000: String(format: "%.1f KB", Double(bytes) / 1000)
        default: String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
    }

    /// `HH:mm:ss`.
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// `Today`, `Yesterday`, then the date.
    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter
    }()
}

extension AppModel {
    /// The variable a script changed, as the workspace holds it now. A secret is always read from
    /// here when revealed, never from the outcome of the run.
    func currentVariable(for change: VariableChange, environmentName: String?, collectionID: UUID?) -> Variable? {
        let variables: [Variable]
        switch change.scope {
        case .local:
            return nil
        case .environment:
            let active = workspace.activeEnvironment
            let environment = active?.name == environmentName
                ? active
                : workspace.environments.first { $0.name == environmentName } ?? active
            variables = environment?.variables ?? []
        case .collection:
            variables = workspace.collections.first { $0.id == collectionID }?.variables ?? []
        case .global:
            variables = workspace.globals
        }
        return variables.last { $0.isEnabled && $0.name == change.name }
    }
}

/// Re-indents JSON text without parsing it into values: key order, number spelling and string
/// escapes stay exactly as the server sent them.
enum JSONIndenter {
    static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.utf8.first(where: { !isWhitespace($0) }) else { return false }
        return first == 0x7B || first == 0x5B
    }

    static func pretty(_ source: String, indent: Int = 2) -> String {
        let bytes = Array(source.utf8)
        let count = bytes.count
        var output: [UInt8] = []
        output.reserveCapacity(count + count / 3)
        var depth = 0
        var index = 0

        func newline() {
            output.append(0x0A)
            output.append(contentsOf: repeatElement(0x20, count: depth * indent))
        }

        while index < count {
            let byte = bytes[index]
            switch byte {
            case 0x22: // A string, copied as is.
                let start = index
                index += 1
                while index < count, bytes[index] != 0x22 {
                    index += bytes[index] == 0x5C ? 2 : 1
                }
                let end = min(index, count - 1)
                output.append(contentsOf: bytes[start...end])
                index = end + 1
            case 0x7B, 0x5B: // { [
                var next = index + 1
                while next < count, isWhitespace(bytes[next]) { next += 1 }
                if next < count, bytes[next] == byte + 2 {
                    // An empty object or array stays on one line.
                    output.append(byte)
                    output.append(bytes[next])
                    index = next + 1
                } else {
                    output.append(byte)
                    depth += 1
                    newline()
                    index += 1
                }
            case 0x7D, 0x5D: // } ]
                depth = max(depth - 1, 0)
                newline()
                output.append(byte)
                index += 1
            case 0x2C: // ,
                output.append(byte)
                newline()
                index += 1
            case 0x3A: // :
                output.append(byte)
                output.append(0x20)
                index += 1
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            default:
                output.append(byte)
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
