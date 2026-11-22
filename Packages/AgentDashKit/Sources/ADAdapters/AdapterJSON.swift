import CoreFoundation
import Foundation

enum AdapterJSON {
    typealias Object = [String: Any]

    static func object(_ data: Data) -> Object? {
        (try? JSONSerialization.jsonObject(with: data)) as? Object
    }

    static func string(_ value: Any?, bounded limit: Int? = nil) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return limit.map { prefix(value, bytes: $0) } ?? value
    }

    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int64(number.stringValue)
    }

    static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    static func timestamp(_ value: Any?) -> Int64? {
        if let millis = integer(value) { return millis }
        guard let string = value as? String, string.utf8.count <= 64 else { return nil }
        let fraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        guard let date = (try? fraction.parse(string)) ?? (try? whole.parse(string)) else { return nil }
        return Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded())
    }

    static func prefix(_ value: String, bytes: Int) -> String {
        let prefix = value.utf8.prefix(bytes)
        if let valid = String(bytes: prefix, encoding: .utf8) { return valid }
        // Only a trailing scalar may be incomplete in a prefix of Swift String.
        for count in 1...3 where count <= prefix.count {
            if let valid = String(bytes: prefix.dropLast(count), encoding: .utf8) { return valid }
        }
        return ""
    }

    static func json(_ value: Object) -> String? {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    static func shellArgument(_ value: String) -> String? {
        guard !value.utf8.contains(0), !value.isEmpty else { return nil }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
