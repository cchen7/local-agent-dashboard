import Security
import SwiftUI

struct AboutSettingsPane: View {
    let isSelected: Bool
    @State private var signature: RunningAppSignature?
    @State private var finishedReading = false

    var body: some View {
        Form {
            Section {
                Text("Agent Dashboard").font(.title2.weight(.semibold))
                buildValue("Version", key: "CFBundleShortVersionString", id: "settings.about.version")
                buildValue("Build", key: "CFBundleVersion", id: "settings.about.build")
                if let signature {
                    switch signature.network {
                    case .blocked:
                        Label("Fully local. No network permission.", systemImage: "lock.shield")
                            .accessibilityIdentifier("settings.about.network.blocked")
                    case .present:
                        Label("Network permission is present in this signature.", systemImage: "exclamationmark.shield")
                            .accessibilityIdentifier("settings.about.network.present")
                    case .unconfirmed:
                        Label("Network permissions could not be confirmed.", systemImage: "questionmark.circle")
                            .accessibilityIdentifier("settings.about.network.unconfirmed")
                    }
                } else if finishedReading {
                    Label("Network permissions could not be confirmed.", systemImage: "questionmark.circle")
                        .accessibilityIdentifier("settings.about.network.unconfirmed")
                }
            }
            Section("Signed entitlements") {
                if let signature {
                    if signature.entitlements.isEmpty {
                        Text("No entitlements in this signature.").foregroundStyle(.secondary)
                    }
                    ForEach(signature.entitlements) { entitlement in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: entitlement.key).font(.caption.monospaced().weight(.medium))
                                .accessibilityIdentifier("settings.about.entitlement.key")
                            Text(verbatim: entitlement.value).font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("settings.about.entitlement.value")
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !signature.entitlements.isEmpty {
                        Text("Agent Dashboard reads source files without modifying them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if finishedReading {
                    Text("The running app’s signature could not be read.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.about.signature.unavailable")
                } else {
                    ProgressView("Reading the running app’s signature…").controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.about")
        .task(id: isSelected) {
            guard isSelected, !finishedReading else { return }
            let reading = await Task.detached(priority: .utility) { RunningAppSignature.read() }.value
            guard !Task.isCancelled else { return }
            signature = reading
            finishedReading = true
        }
    }

    private func buildValue(_ label: LocalizedStringResource, key: String, id: String) -> some View {
        LabeledContent {
            Text(verbatim: Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "—")
                .monospacedDigit()
                .accessibilityIdentifier(id)
        } label: {
            Text(label)
        }
    }
}

private struct RunningAppSignature: Sendable {
    struct Entitlement: Identifiable, Sendable {
        var id: String { key }
        let key: String
        let value: String
    }

    enum NetworkAccess: Sendable { case blocked, present, unconfirmed }

    let entitlements: [Entitlement]
    let network: NetworkAccess

    static func read() -> Self? {
        var runningCode: SecCode?
        var signedImage: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &runningCode) == errSecSuccess, let runningCode,
              SecCodeCheckValidity(runningCode, .noNetworkAccess, nil) == errSecSuccess,
              SecCodeCopyStaticCode(runningCode, [], &signedImage) == errSecSuccess, let signedImage,
              SecCodeCopySigningInformation(signedImage, [], &information) == errSecSuccess,
              let signing = information as NSDictionary?,
              signing[kSecCodeInfoIdentifier] is String else { return nil }

        let values: [String: Any]
        if let dictionary = signing[kSecCodeInfoEntitlementsDict] as? [String: Any] {
            values = dictionary
        } else if signing[kSecCodeInfoEntitlements] == nil && signing[kSecCodeInfoEntitlementsDict] == nil {
            values = [:]
        } else {
            return nil
        }
        return Self(values: values)
    }

    private init(values: [String: Any]) {
        let sandbox = "com.apple.security.app-sandbox"
        let networkKeys = ["com.apple.security.network.client", "com.apple.security.network.server"]
        // A nonstandard signature may have another exception. Only confirm the
        // absence of network permissions for the recognized sandbox profile.
        let knownKeys: Set<String> = [
            sandbox,
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.bookmarks.app-scope",
            "com.apple.security.temporary-exception.files.home-relative-path.read-only",
        ]
        if networkKeys.contains(where: { Self.boolean(values[$0]) == true }) {
            network = .present
        } else if Self.boolean(values[sandbox]) == true && Set(values.keys).isSubset(of: knownKeys) {
            network = .blocked
        } else {
            network = .unconfirmed
        }
        entitlements = values.keys.sorted().compactMap { key in
            values[key].map { .init(key: key, value: Self.display($0)) }
        }
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }

    private static func display(_ value: Any) -> String {
        if let flag = boolean(value) { return flag ? "true" : "false" }
        if let strings = value as? [String] {
            return strings.isEmpty ? "[]" : strings.joined(separator: "\n")
        }
        return String(describing: value)
    }
}
