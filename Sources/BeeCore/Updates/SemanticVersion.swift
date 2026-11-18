import Foundation

/// A version made of numbers separated by dots (`1.2.0`, `v1.2`), ordered number by number.
public struct SemanticVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The numbers as written.
    public let components: [Int]

    /// `nil` unless the text is one to four non-negative numbers separated by dots, with an optional leading `v`.
    public init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        components = numbers
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// The numbers without trailing zeros: `1.2` and `1.2.0` are the same version.
    private var significant: ArraySlice<Int> {
        var end = components.count
        while end > 0, components[end - 1] == 0 { end -= 1 }
        return components[..<end]
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool { lhs.significant == rhs.significant }

    public func hash(into hasher: inout Hasher) { hasher.combine(Array(significant)) }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
