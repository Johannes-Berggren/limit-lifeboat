import Foundation

/// Strict hex decoding shared by the two surfaces that parse `security`'s
/// hex output: the credential backend (which reads the secret payload) and
/// the item locator (which reads the ACL partition-list plist). Both must
/// reject malformed input identically — a lenient decode there would hand a
/// truncated credential to the rest of the app.
extension Data {
    /// Decodes an even-length ASCII hex sequence, or nil if any byte is not
    /// a hex digit. Accepts both upper- and lowercase.
    init?<Bytes: Collection>(strictASCIIHex encoded: Bytes) where Bytes.Element == UInt8 {
        guard encoded.count.isMultiple(of: 2) else {
            return nil
        }
        let encoded = Array(encoded)
        var decoded = [UInt8]()
        decoded.reserveCapacity(encoded.count / 2)
        for index in stride(from: 0, to: encoded.count, by: 2) {
            guard let high = Self.hexNibble(encoded[index]),
                  let low = Self.hexNibble(encoded[index + 1]) else {
                return nil
            }
            decoded.append((high << 4) | low)
        }
        self.init(decoded)
    }

    init?(strictASCIIHex string: String) {
        self.init(strictASCIIHex: Array(string.utf8))
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            return byte - 0x30
        case 0x41...0x46:
            return byte - 0x41 + 10
        case 0x61...0x66:
            return byte - 0x61 + 10
        default:
            return nil
        }
    }
}
