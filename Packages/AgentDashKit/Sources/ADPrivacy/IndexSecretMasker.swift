import CryptoKit
import Foundation

/// Redaction for the live index. Keep ordinary text, non-sensitive JSON
/// structure, and the links between calls while removing recognized secrets.
public enum IndexSecretMasker {
    public static func text(_ text: String) -> String {
        projectText(text, scope: .text, depth: 0)
    }

    public static func eventMetadata(_ text: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        let safe = project(object, scope: .eventMetadata, depth: 0)
        guard safe.changed else { return text }
        guard let data = try? JSONSerialization.data(withJSONObject: safe.value, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Opaque decoder state either survives byte for byte or is discarded.
    /// Rewriting an identity inside it could corrupt the next incremental read.
    public static func canKeepDecoderState(_ state: Data) -> Bool {
        guard let decoded = try? JSONSerialization.jsonObject(with: state) as? [String: Any]
        else { return false }
        return !project(decoded, scope: .decoder, depth: 0).changed
    }

    private enum Scope { case text, eventMetadata, decoder }
    private static let maximumDepth = 32

    private static func projectText(_ text: String, scope: Scope, depth: Int) -> String {
        guard let first = text.utf8.first(where: { $0 != 32 && $0 != 9 && $0 != 10 && $0 != 13 }),
              first == 0x7B || first == 0x5B,
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        else { return SecretMasker.mask(text) }
        let safe = project(value, scope: scope, depth: depth)
        guard safe.changed else { return text }
        guard let encoded = try? JSONSerialization.data(withJSONObject: safe.value, options: [.sortedKeys, .fragmentsAllowed])
        else { return SecretMasker.placeholder }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func project(_ value: Any, scope: Scope, depth: Int) -> (value: Any, changed: Bool) {
        guard depth < maximumDepth else { return (SecretMasker.placeholder, true) }
        if let text = value as? String {
            let safe = projectText(text, scope: scope == .decoder ? .decoder : .text, depth: depth + 1)
            return (safe, safe != text)
        }
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            var changed = false
            for (key, field) in object {
                if SecretMasker.mask(key) != key {
                    // Dropping a credential-shaped key avoids collisions with
                    // another masked key and leaves unrelated fields intact.
                    changed = true
                    continue
                }
                if scope == .eventMetadata, depth == 0, ["call_id", "tool_use_id", "claude_message_id"].contains(key),
                   let id = field as? String, SecretMasker.mask(id) != id {
                    result[key] = "masked-call:" + SHA256.hash(data: Data(id.utf8))
                        .map { String(format: "%02x", $0) }.joined()
                    changed = true
                } else if sensitiveName(key), !(field is NSNull), !decoderIdentity(key, field: field, scope: scope) {
                    result[key] = SecretMasker.placeholder
                    changed = changed || (field as? String) != SecretMasker.placeholder
                } else {
                    let safe = project(field, scope: scope, depth: depth + 1)
                    result[key] = safe.value
                    changed = changed || safe.changed
                }
            }
            return (result, changed)
        }
        if let array = value as? [Any] {
            let elements = array.map { project($0, scope: scope, depth: depth + 1) }
            return (elements.map(\.value), elements.contains { $0.changed })
        }
        return (value, false)
    }

    private static func sensitiveName(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        }) else { return false }
        let upper = key.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASSWORD"].contains { upper.hasSuffix($0) }
    }

    private static func decoderIdentity(_ key: String, field: Any, scope: Scope) -> Bool {
        // SessionRecord.key encodes a typed agent/nativeID pair. It is not a
        // credential field, but each of its strings still gets checked.
        guard scope == .decoder, key == "key", let object = field as? [String: String] else { return false }
        return object.count == 2 && object["agent"] != nil && object["nativeID"] != nil
    }
}
