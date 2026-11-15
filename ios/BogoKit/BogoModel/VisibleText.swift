import Foundation

public enum VisibleSegment: Equatable, Sendable {
    case text(String)
    case escape(String)
}

public enum VisibleText {
    private static let bidi: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
    private static let oddSpaces: Set<UInt32> = [0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

    public static func segments(_ value: String) -> [VisibleSegment] {
        let scalars = Array(value.unicodeScalars)
        var leading = 0
        while leading < scalars.count, scalars[leading] == " " { leading += 1 }
        var trailing = scalars.count
        while trailing > leading, scalars[trailing - 1] == " " { trailing -= 1 }
        var result: [VisibleSegment] = []
        var plain = String.UnicodeScalarView()
        func flush() {
            if !plain.isEmpty { result.append(.text(String(plain))) }
            plain = String.UnicodeScalarView()
        }
        func escape(_ label: String, keeping kept: String = "") {
            flush()
            result.append(.escape(label))
            if !kept.isEmpty { result.append(.text(kept)) }
        }
        for (index, scalar) in scalars.enumerated() {
            let doubled = scalar == " " && ((index + 1 < scalars.count && scalars[index + 1] == " ") || (index > 0 && scalars[index - 1] == " "))
            switch scalar.value {
            case 0x0A: escape("↵", keeping: "\n")
            case 0x09: escape("⇥")
            case 0x0D: escape("␍")
            case 0x20 where index < leading || index >= trailing || doubled: escape("␣")
            case 0x00...0x1F, 0x7F...0x9F: escape(code(scalar))
            default:
                if bidi.contains(scalar.value) || oddSpaces.contains(scalar.value) || scalar.properties.generalCategory == .format {
                    escape(code(scalar))
                } else {
                    plain.append(scalar)
                }
            }
        }
        flush()
        return result
    }

    public static func hasEscapes(_ value: String) -> Bool {
        segments(value).contains { if case .escape = $0 { return true } else { return false } }
    }

    private static func code(_ scalar: Unicode.Scalar) -> String {
        "U+" + String(format: "%04X", scalar.value)
    }
}
