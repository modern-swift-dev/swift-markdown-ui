import Foundation

extension String {
    /// Returns the string with alphanumeric characters lowercased and every other
    /// Unicode scalar replaced by a hyphen.
    ///
    /// Heading views use the result as their identity, so scroll anchors depend on
    /// this exact mapping. Consecutive separators are kept rather than collapsed.
    func kebabCased() -> String {
        var result = String.UnicodeScalarView()
        for scalar in self.unicodeScalars {
            switch scalar.value {
                case 0x30 ... 0x39,
                     0x61 ... 0x7A:
                    result.append(scalar)
                case 0x41 ... 0x5A:
                    result.append(Unicode.Scalar(UInt8(scalar.value + 0x20)))
                case 0 ..< 0x80:
                    result.append("-")
                default:
                    if kebabCaseAlphanumerics.contains(scalar) {
                        // `lowercased()` applies the same per-scalar mapping.
                        result.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
                    } else {
                        result.append("-")
                    }
            }
        }
        return String(result)
    }
}

private let kebabCaseAlphanumerics = CharacterSet.alphanumerics
