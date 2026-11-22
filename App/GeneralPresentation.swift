import Foundation
import SwiftUI

enum DashboardClockFormat: String, CaseIterable, Identifiable, Sendable {
    case system, twelveHour, twentyFourHour
    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .system: "System Default"
        case .twelveHour: "12-hour"
        case .twentyFourHour: "24-hour"
        }
    }

    /// Change the hour cycle only. Calendar, regional formatting, usage
    /// boundaries and stored timestamps continue following the system.
    func locale(from current: Locale) -> Locale {
        guard self != .system else { return current }
        var components = Locale.Components(locale: current)
        components.hourCycle = self == .twelveHour ? .oneToTwelve : .zeroToTwentyThree
        return Locale(components: components)
    }
}

private struct DashboardClockFormatKey: EnvironmentKey {
    static let defaultValue = DashboardClockFormat.system
}

extension EnvironmentValues {
    var dashboardClockFormat: DashboardClockFormat {
        get { self[DashboardClockFormatKey.self] }
        set { self[DashboardClockFormatKey.self] = newValue }
    }
}

@propertyWrapper
struct DashboardClock: DynamicProperty {
    @Environment(\.locale) private var locale
    @Environment(\.dashboardClockFormat) private var preference

    var wrappedValue: Date.FormatStyle { .dateTime.locale(preference.locale(from: locale)) }
}
