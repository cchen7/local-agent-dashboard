import Foundation

enum DashboardLayoutRules {
    static let minimumPlotHeight: CGFloat = 220

    static func sessionListWidth(at windowWidth: CGFloat) -> CGFloat {
        guard windowWidth.isFinite else { return 356 }
        let width = min(1440, max(960, windowWidth))
        if width <= 1120 { return 300 + (width - 960) * 56 / 160 }
        return 356 + (width - 1120) * 64 / 320
    }

    static func compactDetail(width: CGFloat) -> Bool { width < 480 }
    static func usageCaptions(width: CGFloat) -> Bool { width >= 760 }

    static func chartBlockHeight(viewport: CGFloat, header: CGFloat, table: CGFloat,
                                 naturalChart: CGFloat, spacing: CGFloat) -> CGFloat {
        max(naturalChart, viewport - header - table - 2 * spacing)
    }
}

struct UsageBreakdownColumns {
    static let spacing: CGFloat = 10
    static let peak: CGFloat = 88
    static let peakTime: CGFloat = 76
    static let total: CGFloat = 84
    static let cache: CGFloat = 100
    static let cost: CGFloat = 95
    static let sessions: CGFloat = 56

    let showPeakTime: Bool
    let showCache: Bool
    let showCost: Bool
    let flexible: CGFloat

    init(width: CGFloat, showCost: Bool) {
        self.showCost = showCost
        let available = width.isFinite ? max(0, width) : 0
        let fixed = Self.peak + Self.total + Self.sessions + (showCost ? Self.cost : 0)
        let required = fixed + CGFloat(showCost ? 5 : 4) * Self.spacing
        let minimumFlexible: CGFloat = 192 // 96 each for the name and share.
        let cacheRequired = required + Self.cache + Self.spacing
        let peakRequired = cacheRequired + Self.peakTime + Self.spacing
        showCache = available >= cacheRequired + minimumFlexible
        showPeakTime = available >= peakRequired + minimumFlexible
        let used = showPeakTime ? peakRequired : showCache ? cacheRequired : required
        flexible = max(0, (available - used) / 2)
    }
}
