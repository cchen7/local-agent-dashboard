import ADCore
import Foundation

/// Maxima of the plotted call-precision lanes, not peaks of the raw minute
/// ledger or maxima of the separate coarse and cumulative lanes.
public struct UsageCurvePeak: Identifiable, Equatable, Sendable {
    public let agent: AgentKind?
    public let timestamp: Int64
    public let value: Double
    public var id: String { agent?.rawValue ?? "combined" }

    public static func select(from samples: [UsageDisplaySample]) -> [Self] {
        var winners: [String: Self] = [:]
        for sample in samples where sample.throughput.isFinite && sample.throughput > 0 {
            let peak = Self(agent: sample.agent, timestamp: sample.timestamp, value: sample.throughput)
            if let prior = winners[peak.id], prior.value > peak.value
                || (prior.value == peak.value && prior.timestamp <= peak.timestamp) { continue }
            winners[peak.id] = peak
        }
        return winners.values.sorted {
            if ($0.agent == nil) != ($1.agent == nil) { return $0.agent == nil }
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.id < $1.id
        }
    }
}

public struct PeakChipRequest: Equatable, Sendable {
    public let id: String
    public let anchor: CGPoint
    public let size: CGSize

    public init(id: String, anchor: CGPoint, size: CGSize) {
        self.id = id; self.anchor = anchor; self.size = size
    }
}

public struct PeakChipPlacement: Identifiable, Equatable, Sendable {
    public let id: String
    public let frame: CGRect
}

public struct PeakChipLayout: Equatable, Sendable {
    public let placed: [PeakChipPlacement]
    /// Ordered fallback labels for cases where an in-plot chip would obscure data.
    public let overflow: [String]

    public static func place(_ requests: [PeakChipRequest], in plot: CGRect, obstacles: [CGRect]) -> Self {
        let directions: [(CGFloat, CGFloat)] = [
            (0, -1), (1, -1), (-1, -1), (1, 0), (-1, 0), (0, 1), (1, 1), (-1, 1),
        ]
        let gaps: [CGFloat] = [6, 12, 20]
        var placed: [PeakChipPlacement] = []
        var overflow: [String] = []
        for chip in requests {
            var winner: CGRect?
            if chip.anchor.x.isFinite, chip.anchor.y.isFinite, chip.size.width.isFinite, chip.size.height.isFinite,
               chip.size.width > 0, chip.size.height > 0 {
                let halfWidth = chip.size.width / 2, halfHeight = chip.size.height / 2
                candidate: for gap in gaps {
                    for (dx, dy) in directions {
                        let frame = CGRect(x: chip.anchor.x + dx * (halfWidth + gap) - halfWidth,
                                           y: chip.anchor.y + dy * (halfHeight + gap) - halfHeight,
                                           width: chip.size.width, height: chip.size.height)
                        guard plot.contains(frame),
                              !placed.contains(where: { $0.frame.insetBy(dx: -3, dy: -3).intersects(frame) }),
                              !obstacles.contains(where: { $0.intersects(frame) }) else { continue }
                        winner = frame
                        break candidate
                    }
                }
            }
            if let winner { placed.append(PeakChipPlacement(id: chip.id, frame: winner)) }
            else { overflow.append(chip.id) }
        }
        return Self(placed: placed, overflow: overflow)
    }

    /// A conservative envelope for linear or monotone interpolated segments.
    public static func curveObstacles(_ points: [CGPoint], clearance: CGFloat) -> [CGRect] {
        if points.count == 1, let point = points.first {
            return [CGRect(origin: point, size: .zero).insetBy(dx: -clearance, dy: -clearance)]
        }
        return zip(points, points.dropFirst()).map { first, second in
            CGRect(x: min(first.x, second.x), y: min(first.y, second.y),
                   width: abs(first.x - second.x), height: abs(first.y - second.y))
                .insetBy(dx: -clearance, dy: -clearance)
        }
    }
}
