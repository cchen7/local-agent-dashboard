import ADCore
import Foundation
import Testing
@testable import ADInsights

@Test("FR-TK: peak chips select exact displayed lanes and the earlier tied maximum")
func peakLabelsSelectDisplayedLanes() {
    func sample(_ agent: AgentKind?, time: Int64, value: Double,
                coarse: Double = 0, cumulative: Double = 0) -> UsageDisplaySample {
        UsageDisplaySample(timestamp: time, endTimestamp: time + 60_000, agent: agent, throughput: value,
                           coarseThroughput: coarse, hasPricedUsage: false, hasUnpricedUsage: true,
                           cumulative: cumulative)
    }
    let result = UsageCurvePeak.select(from: [
        sample(.codex, time: 120_000, value: 9),
        sample(.codex, time: 60_000, value: 9),
        sample(.claudeCode, time: 60_000, value: 0, coarse: 100_000),
        sample(nil, time: 120_000, value: 12, cumulative: 1_000),
        sample(nil, time: 180_000, value: 8, cumulative: 9_000),
        sample(.copilot, time: 120_000, value: 3),
    ])
    #expect(result.map(\.id) == ["combined", "codex", AgentKind.copilot.rawValue])
    #expect(result.map(\.timestamp) == [120_000, 60_000, 120_000])
    #expect(result.map(\.value) == [12, 9, 3])
}

@Test("FR-TK: peak chip frames avoid curves, vertical markers, and each other")
func placesPeakChipsAroundObstructions() throws {
    let plot = CGRect(x: 0, y: 0, width: 320, height: 180)
    let curve = PeakChipLayout.curveObstacles([
        CGPoint(x: 0, y: 70), CGPoint(x: 149, y: 70), CGPoint(x: 201, y: 70), CGPoint(x: 320, y: 70),
    ], clearance: 3)
    #expect(curve.contains { $0.contains(CGPoint(x: 80, y: 70)) })
    let now = CGRect(x: 197, y: 0, width: 6, height: plot.height)
    let occupied = curve + [now]
    let layout = PeakChipLayout.place([
        .init(id: "combined", anchor: CGPoint(x: 149, y: 70), size: CGSize(width: 126, height: 18)),
        .init(id: "codex", anchor: CGPoint(x: 201, y: 70), size: CGSize(width: 78, height: 18)),
    ], in: plot, obstacles: occupied)
    try #require(layout.placed.map(\.id) == ["combined", "codex"])
    #expect(layout.overflow.isEmpty)
    #expect(layout.placed.allSatisfy { chip in plot.contains(chip.frame) })
    #expect(layout.placed.allSatisfy { chip in !occupied.contains { $0.intersects(chip.frame) } })
    #expect(!layout.placed[0].frame.intersects(layout.placed[1].frame))
}

@Test("FR-TK: crowded charts retain peak labels outside the plot rather than cover data")
func peakLabelsOverflowSafely() {
    let plot = CGRect(x: 0, y: 0, width: 90, height: 30)
    let layout = PeakChipLayout.place([
        .init(id: "combined", anchor: CGPoint(x: 84, y: 12), size: CGSize(width: 126, height: 18)),
        .init(id: "codex", anchor: CGPoint(x: 84, y: 12), size: CGSize(width: 78, height: 18)),
    ], in: plot, obstacles: [plot])
    #expect(layout.placed.isEmpty)
    #expect(layout.overflow == ["combined", "codex"])
}
