import XCTest
@testable import StrandAnalytics

/// RangeReportEngine — the data model for a shareable offline trends report over a date
/// range. The oracle for the Android RangeReportTest; keep the two in lockstep (same
/// fixtures, same assertions — cross-platform parity is the contract).
final class RangeReportTests: XCTestCase {

    // A clean +10/day recovery ramp across four days.
    private let recoveryRamp: [String: Double] = [
        "2026-06-01": 40,
        "2026-06-02": 50,
        "2026-06-03": 60,
        "2026-06-04": 70,
    ]

    // MARK: - Known series → correct mean / min / max / halves / trend

    func testKnownSeriesStats() {
        let report = RangeReportEngine.build(metrics: [.recovery: recoveryRamp],
                                             start: "2026-06-01", end: "2026-06-04")
        XCTAssertEqual(report.start, "2026-06-01")
        XCTAssertEqual(report.end, "2026-06-04")
        XCTAssertEqual(report.totalDays, 4)
        XCTAssertFalse(report.isEmpty)

        let s = report.stat(.recovery)!
        XCTAssertEqual(s.n, 4)
        XCTAssertEqual(s.mean, 55, accuracy: 1e-9)
        // Halves split by position: [40,50] vs [60,70].
        XCTAssertEqual(s.firstHalfMean, 45, accuracy: 1e-9)
        XCTAssertEqual(s.secondHalfMean, 65, accuracy: 1e-9)
        XCTAssertEqual(s.halfDelta, 20, accuracy: 1e-9)
        // A clean +10/day ramp is rising.
        XCTAssertEqual(s.trend, .rising)
        XCTAssertEqual(s.latest.day, "2026-06-04")
        XCTAssertEqual(s.latest.value, 70, accuracy: 1e-9)
    }

    // MARK: - Min / max carry the right day

    func testMinMaxCarryRightDay() {
        let series: [String: Double] = [
            "2026-06-01": 55,
            "2026-06-02": 40,   // min
            "2026-06-03": 70,   // max
            "2026-06-04": 50,
        ]
        let s = RangeReportEngine.build(metrics: [.hrv: series],
                                        start: "2026-06-01", end: "2026-06-04").stat(.hrv)!
        XCTAssertEqual(s.min.day, "2026-06-02")
        XCTAssertEqual(s.min.value, 40, accuracy: 1e-9)
        XCTAssertEqual(s.max.day, "2026-06-03")
        XCTAssertEqual(s.max.value, 70, accuracy: 1e-9)
    }

    // MARK: - Missing metric is omitted

    func testMissingMetricOmitted() {
        // Only recovery is supplied → strain/hrv/etc. are absent, not zeroed.
        let report = RangeReportEngine.build(metrics: [.recovery: recoveryRamp],
                                             start: "2026-06-01", end: "2026-06-04")
        XCTAssertNotNil(report.stat(.recovery))
        XCTAssertNil(report.stat(.strain))
        XCTAssertNil(report.stat(.hrv))
        XCTAssertNil(report.stat(.restingHr))
        XCTAssertNil(report.stat(.sleepHours))
        XCTAssertEqual(report.metrics.count, 1)
    }

    // MARK: - Out-of-range days are excluded

    func testOutOfRangeDaysExcluded() {
        let series: [String: Double] = [
            "2026-05-31": 99,   // before start — excluded
            "2026-06-01": 50,
            "2026-06-02": 60,
            "2026-06-05": 99,   // after end — excluded
        ]
        let s = RangeReportEngine.build(metrics: [.recovery: series],
                                        start: "2026-06-01", end: "2026-06-02").stat(.recovery)!
        XCTAssertEqual(s.n, 2)
        XCTAssertEqual(s.mean, 55, accuracy: 1e-9)
        XCTAssertEqual(s.min.value, 50, accuracy: 1e-9)
        XCTAssertEqual(s.max.value, 60, accuracy: 1e-9)
    }

    // MARK: - Single-day range

    func testSingleDayRange() {
        let report = RangeReportEngine.build(metrics: [.recovery: ["2026-06-01": 50]],
                                             start: "2026-06-01", end: "2026-06-01")
        XCTAssertEqual(report.totalDays, 1)
        let s = report.stat(.recovery)!
        XCTAssertEqual(s.n, 1)
        XCTAssertEqual(s.mean, 50, accuracy: 1e-9)
        XCTAssertEqual(s.min.day, "2026-06-01")
        XCTAssertEqual(s.max.day, "2026-06-01")
        XCTAssertEqual(s.latest.day, "2026-06-01")
        // One value → both halves equal it, no fabricated movement.
        XCTAssertEqual(s.firstHalfMean, 50, accuracy: 1e-9)
        XCTAssertEqual(s.secondHalfMean, 50, accuracy: 1e-9)
        XCTAssertEqual(s.trend, .flat)
    }

    // MARK: - Empty → empty report

    func testEmptyMetricsGivesEmptyReport() {
        let report = RangeReportEngine.build(metrics: [:],
                                             start: "2026-06-01", end: "2026-06-04")
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.metrics.count, 0)
        XCTAssertEqual(report.headlines.count, 0)
        XCTAssertEqual(report.totalDays, 4)   // the WINDOW is still 4 days wide
    }

    func testAllSeriesOutOfRangeGivesEmptyReport() {
        // Data exists but none lands in the window → empty report.
        let series: [String: Double] = ["2026-01-01": 50, "2026-12-31": 60]
        let report = RangeReportEngine.build(metrics: [.recovery: series],
                                             start: "2026-06-01", end: "2026-06-04")
        XCTAssertTrue(report.isEmpty)
    }

    // MARK: - Inverted range

    func testInvertedRangeIsEmpty() {
        // end before start → empty report, 0 days.
        let report = RangeReportEngine.build(metrics: [.recovery: recoveryRamp],
                                             start: "2026-06-04", end: "2026-06-01")
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.totalDays, 0)
    }

    // MARK: - Trend rising / falling / flat thresholds

    func testTrendRising() {
        let s = RangeReportEngine.build(metrics: [.recovery: recoveryRamp],
                                        start: "2026-06-01", end: "2026-06-04").stat(.recovery)!
        XCTAssertEqual(s.trend, .rising)
    }

    func testTrendFalling() {
        let falling: [String: Double] = [
            "2026-06-01": 70,
            "2026-06-02": 60,
            "2026-06-03": 50,
            "2026-06-04": 40,
        ]
        let s = RangeReportEngine.build(metrics: [.recovery: falling],
                                        start: "2026-06-01", end: "2026-06-04").stat(.recovery)!
        XCTAssertEqual(s.trend, .falling)
    }

    func testTrendFlatWhenLevel() {
        // A dead-level series has slope 0 < threshold → flat.
        let level: [String: Double] = [
            "2026-06-01": 60,
            "2026-06-02": 60,
            "2026-06-03": 60,
            "2026-06-04": 60,
        ]
        let s = RangeReportEngine.build(metrics: [.recovery: level],
                                        start: "2026-06-01", end: "2026-06-04").stat(.recovery)!
        XCTAssertEqual(s.trend, .flat)
    }

    func testTrendFlatWhenSlopeBelowThreshold() {
        // recovery threshold is 0.5 pts/day. A +0.1/day drift (60.0 → 60.3) is noise → flat.
        let drift: [String: Double] = [
            "2026-06-01": 60.0,
            "2026-06-02": 60.1,
            "2026-06-03": 60.2,
            "2026-06-04": 60.3,
        ]
        let s = RangeReportEngine.build(metrics: [.recovery: drift],
                                        start: "2026-06-01", end: "2026-06-04").stat(.recovery)!
        XCTAssertEqual(s.trend, .flat)
    }

    // MARK: - Trend uses the metric's OWN threshold

    func testTrendThresholdIsPerMetric() {
        // A +0.1/day climb is FLAT for recovery (thr 0.5) but RISING for sleepHours
        // (thr 0.05), proving the threshold is metric-specific.
        let drift: [String: Double] = [
            "2026-06-01": 7.0,
            "2026-06-02": 7.1,
            "2026-06-03": 7.2,
            "2026-06-04": 7.3,
        ]
        let recov = RangeReportEngine.build(metrics: [.recovery: drift],
                                            start: "2026-06-01", end: "2026-06-04").stat(.recovery)!
        let sleep = RangeReportEngine.build(metrics: [.sleepHours: drift],
                                            start: "2026-06-01", end: "2026-06-04").stat(.sleepHours)!
        XCTAssertEqual(recov.trend, .flat)
        XCTAssertEqual(sleep.trend, .rising)
    }

    // MARK: - Odd count: second half gets the extra day

    func testOddCountSplitsToSecondHalf() {
        // 3 days: mid = 1 → firstHalf [50], secondHalf [60,70].
        let series: [String: Double] = [
            "2026-06-01": 50,
            "2026-06-02": 60,
            "2026-06-03": 70,
        ]
        let s = RangeReportEngine.build(metrics: [.recovery: series],
                                        start: "2026-06-01", end: "2026-06-03").stat(.recovery)!
        XCTAssertEqual(s.firstHalfMean, 50, accuracy: 1e-9)
        XCTAssertEqual(s.secondHalfMean, 65, accuracy: 1e-9)
    }

    // MARK: - Multiple metrics + headlines

    func testMultipleMetricsAndHeadlines() {
        let recovery: [String: Double] = [
            "2026-06-01": 40, "2026-06-02": 50, "2026-06-03": 60, "2026-06-04": 70,
        ]
        let rhr: [String: Double] = [   // resting HR rising = a bad sign
            "2026-06-01": 50, "2026-06-02": 52, "2026-06-03": 54, "2026-06-04": 56,
        ]
        let report = RangeReportEngine.build(
            metrics: [.recovery: recovery, .restingHr: rhr],
            start: "2026-06-01", end: "2026-06-04")
        XCTAssertEqual(report.metrics.count, 2)
        // One headline per present metric.
        XCTAssertEqual(report.headlines.count, 2)
        // Recovery half-move (45→65, +20) dwarfs RHR's (51→55, +4) → ranked first.
        XCTAssertTrue(report.headlines[0].contains("Recovery"))
        XCTAssertTrue(report.headlines[0].contains("good sign"))
        // RHR rose, and higher RHR is worse → "worth a look".
        XCTAssertTrue(report.headlines[1].contains("Resting HR"))
        XCTAssertTrue(report.headlines[1].contains("worth a look"))
    }

    // MARK: - Determinism

    func testDeterministic() {
        let a = RangeReportEngine.build(metrics: [.recovery: recoveryRamp],
                                        start: "2026-06-01", end: "2026-06-04")
        let b = RangeReportEngine.build(metrics: [.recovery: recoveryRamp],
                                        start: "2026-06-01", end: "2026-06-04")
        XCTAssertEqual(a, b)
    }
}
