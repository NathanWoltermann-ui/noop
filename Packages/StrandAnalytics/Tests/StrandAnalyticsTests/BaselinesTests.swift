import XCTest
@testable import StrandAnalytics

final class BaselinesTests: XCTestCase {

    func testFirstNightSeeds() {
        let s = Baselines.update(nil, value: 50, cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.baseline, 50.0, accuracy: 1e-9)
        XCTAssertEqual(s.spread, Baselines.hrvCfg.floorSpread, accuracy: 1e-9)
        XCTAssertEqual(s.nValid, 1)
        XCTAssertEqual(s.status, .calibrating)
    }

    func testColdStartStatusProgression() {
        // 3 nights → calibrating; 4 → provisional; 14 → trusted.
        var s = Baselines.foldHistory(Array(repeating: 50.0, count: 3), cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.status, .calibrating)
        XCTAssertFalse(s.usable)

        s = Baselines.foldHistory(Array(repeating: 50.0, count: 4), cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.status, .provisional)
        XCTAssertTrue(s.usable)

        s = Baselines.foldHistory(Array(repeating: 50.0, count: 14), cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.status, .trusted)
        XCTAssertTrue(s.trusted)
    }

    func testMissingNightSkipAndHold() {
        let seed = Baselines.update(nil, value: 50, cfg: Baselines.hrvCfg)
        let after = Baselines.update(seed, value: nil, cfg: Baselines.hrvCfg)
        XCTAssertEqual(after.baseline, seed.baseline, accuracy: 1e-9)
        XCTAssertEqual(after.spread, seed.spread, accuracy: 1e-9)
        XCTAssertEqual(after.nValid, seed.nValid)            // not incremented
        XCTAssertEqual(after.nightsSinceUpdate, 1)
    }

    func testConstantSeriesConvergesToValue() {
        let s = Baselines.foldHistory(Array(repeating: 50.0, count: 30), cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.baseline, 50.0, accuracy: 1e-6)     // EWMA of constant = constant
        XCTAssertEqual(s.spread, Baselines.hrvCfg.floorSpread, accuracy: 1e-9)
    }

    func testHardOutlierRejected() {
        // Establish a stable baseline, then feed a huge outlier (>5σ).
        var values = Array(repeating: 50.0, count: 10)
        let stable = Baselines.foldHistory(values, cfg: Baselines.hrvCfg)
        values.append(200.0)  // way out (within physiological max 250, but >5*spread)
        let after = Baselines.foldHistory(values, cfg: Baselines.hrvCfg)
        // Baseline should barely move (outlier was rejected, not folded).
        XCTAssertEqual(after.baseline, stable.baseline, accuracy: 1.0)
    }

    func testOutOfRangeValueSkipped() {
        let seed = Baselines.update(nil, value: 50, cfg: Baselines.hrvCfg)
        // 300 > hrv max 250 → skip-and-hold.
        let after = Baselines.update(seed, value: 300, cfg: Baselines.hrvCfg)
        XCTAssertEqual(after.nValid, seed.nValid)
        XCTAssertEqual(after.nightsSinceUpdate, 1)
    }

    func testDeviationDirectionAndZero() {
        let s = Baselines.foldHistory(Array(repeating: 50.0, count: 14), cfg: Baselines.hrvCfg)
        let atBaseline = Baselines.deviation(50.0, state: s)
        XCTAssertEqual(atBaseline.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(atBaseline.delta, 0.0, accuracy: 1e-6)
        XCTAssertTrue(atBaseline.inNormalRange)

        let above = Baselines.deviation(70.0, state: s)
        XCTAssertGreaterThan(above.z, 0)
        XCTAssertEqual(above.delta, 20.0, accuracy: 1e-6)

        let below = Baselines.deviation(30.0, state: s)
        XCTAssertLessThan(below.z, 0)
    }

    func testRollingMeanSD() {
        // Trailing mean/SD over a small known set: [40, 50, 60] → mean 50, sample SD 10.
        let s = Baselines.rollingMeanSD([40, 50, 60], cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.baseline, 50.0, accuracy: 1e-9)
        // spread is stored as SD/1.253, so deviation() recovers σ = SD = 10.
        let dev = Baselines.deviation(60.0, state: s)
        XCTAssertEqual(dev.z, 1.0, accuracy: 1e-6)  // (60-50)/10
    }

    func testRollingMeanSDWindowTruncates() {
        // 35 values; window 30 keeps the last 30. Last 30 are all 50 → mean 50.
        var vals: [Double?] = Array(repeating: 100.0, count: 5)
        vals.append(contentsOf: Array(repeating: 50.0, count: 30))
        let s = Baselines.rollingMeanSD(vals, cfg: Baselines.hrvCfg, window: 30)
        XCTAssertEqual(s.baseline, 50.0, accuracy: 1e-9)
        XCTAssertEqual(s.nValid, 30)
    }

    func testRollingMeanSDDropsOutOfRangeAndNil() {
        let s = Baselines.rollingMeanSD([nil, 50, 300, 50, 50], cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.nValid, 3)  // nil + 300(>250) dropped
        XCTAssertEqual(s.baseline, 50.0, accuracy: 1e-9)
    }

    func testEmptyHistoryCalibrating() {
        let s = Baselines.rollingMeanSD([], cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.status, .calibrating)
        XCTAssertEqual(s.nValid, 0)
    }

    // MARK: - Early-life anti-anchoring (Reddit HRV report)

    /// Three artificially-high seed nights then a run of genuine lower nights must converge toward
    /// reality QUICKLY (days, not the ~2-3 weeks the old halfLifeB=14 EWMA took) — and crucially the
    /// genuine lower nights must NOT be rejected as hard outliers while the spread is still tight.
    func testEarlyHighSeedConvergesQuickly() {
        // 3 high cold-start nights (~90ms) then the user's true ~54ms.
        var vals: [Double?] = [90, 92, 88]
        vals.append(contentsOf: Array(repeating: 54.0, count: 7)) // ~1 week of real nights
        let s = Baselines.foldHistory(vals, cfg: Baselines.hrvCfg)

        // The baseline must have tracked most of the way down to 54 within a week.
        XCTAssertLessThan(s.baseline, 65.0,
                          "early-high seed should converge near the true value within ~1 week, got \(s.baseline)")
        // A true 54ms night should now read as roughly in-range, NOT a Charge-crushing extreme z.
        let dev = Baselines.deviation(54.0, state: s)
        XCTAssertLessThan(abs(dev.z), 2.0,
                          "a real night near the converged baseline shouldn't read as an extreme outlier, z=\(dev.z)")
    }

    /// The OLD behaviour (for contrast): without the early-life fix, the same sequence would reject
    /// the lower nights and stay anchored high. Here we assert the FIX — the lower nights are folded,
    /// so the baseline moves well below the seed (it would barely move if they were rejected).
    func testGenuineLowerNightsNotRejectedDuringSeed() {
        let seedHigh = Baselines.foldHistory(Array(repeating: 90.0, count: 4), cfg: Baselines.hrvCfg)
        var vals: [Double?] = Array(repeating: 90.0, count: 4)
        vals.append(contentsOf: Array(repeating: 55.0, count: 5))
        let after = Baselines.foldHistory(vals, cfg: Baselines.hrvCfg)
        XCTAssertLessThan(after.baseline, seedHigh.baseline - 15.0,
                          "lower nights must be folded (baseline drops), not rejected as outliers")
    }

    /// A genuinely settled, stable baseline must still reject a wild one-off outlier (the gate isn't
    /// disabled forever — only suspended during early life / floor-tight spread).
    func testHardOutlierStillRejectedOnceSettled() {
        // Enough varied nights to get past earlyAdaptNights AND lift spread off the floor.
        var vals: [Double?] = []
        for i in 0..<14 { vals.append(50.0 + Double(i % 3)) } // 50/51/52 jitter, ~stable
        let stable = Baselines.foldHistory(vals, cfg: Baselines.hrvCfg)
        XCTAssertGreaterThanOrEqual(stable.nValid, Baselines.earlyAdaptNights)
        vals.append(220.0) // wild outlier
        let after = Baselines.foldHistory(vals, cfg: Baselines.hrvCfg)
        XCTAssertEqual(after.baseline, stable.baseline, accuracy: 2.0,
                       "a settled baseline should still reject a wild outlier")
    }

    /// Constant input is unchanged by the early-life path (EWMA of a constant is the constant, and
    /// the faster early half-life can't move a center that's already at the value).
    func testEarlyPathNoOpOnConstantSeries() {
        let s = Baselines.foldHistory(Array(repeating: 50.0, count: 30), cfg: Baselines.hrvCfg)
        XCTAssertEqual(s.baseline, 50.0, accuracy: 1e-6)
        XCTAssertEqual(s.spread, Baselines.hrvCfg.floorSpread, accuracy: 1e-9)
    }

    // MARK: - Manual recalibration epoch (noop.hrvBaselineEpoch)

    /// Day-keyed fold with a recalibration epoch must DROP every night before the epoch and re-seed
    /// from the first on-or-after night — so a high early baseline resets to the recent reality.
    func testRecalibrateEpochReseedsFromEpoch() {
        // Pre-recalibration: 6 high nights; post: 6 lower nights. Epoch = start of 2026-06-15.
        let days = ["2026-06-08", "2026-06-09", "2026-06-10", "2026-06-11", "2026-06-12", "2026-06-13",
                    "2026-06-15", "2026-06-16", "2026-06-17", "2026-06-18", "2026-06-19", "2026-06-20"]
        let vals: [Double?] = [90, 91, 89, 90, 92, 88,  54, 55, 53, 54, 56, 54]

        // Epoch at 2026-06-15T00:00:00Z.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 15
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let epoch = cal.date(from: comps)!.timeIntervalSince1970

        let recalibrated = Baselines.foldHistory(vals, dayKeys: days, cfg: Baselines.hrvCfg, baselineEpoch: epoch)
        // Only the 6 post-epoch (~54ms) nights contribute → baseline is the lower value, not anchored high.
        XCTAssertEqual(recalibrated.nValid, 6)
        XCTAssertEqual(recalibrated.baseline, 54.0, accuracy: 2.0)

        // Sanity: with NO epoch the high pre-nights still anchor it well above the recalibrated value.
        let notRecalibrated = Baselines.foldHistory(vals, dayKeys: days, cfg: Baselines.hrvCfg, baselineEpoch: 0)
        XCTAssertGreaterThan(notRecalibrated.baseline, recalibrated.baseline + 10.0)
    }

    /// epoch <= 0 is byte-identical to the plain foldHistory (no recalibration).
    func testRecalibrateEpochZeroIsNoOp() {
        let days = ["2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04"]
        let vals: [Double?] = [60, 61, 59, 62]
        let withZero = Baselines.foldHistory(vals, dayKeys: days, cfg: Baselines.hrvCfg, baselineEpoch: 0)
        let plain = Baselines.foldHistory(vals, cfg: Baselines.hrvCfg)
        XCTAssertEqual(withZero.baseline, plain.baseline, accuracy: 1e-9)
        XCTAssertEqual(withZero.nValid, plain.nValid)
    }

    /// An epoch AFTER every night drops them all → calibrating cold-start (re-learns from scratch).
    func testRecalibrateEpochAfterAllNightsResetsToColdStart() {
        let days = ["2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04"]
        let vals: [Double?] = [60, 61, 59, 62]
        // Far-future epoch.
        let s = Baselines.foldHistory(vals, dayKeys: days, cfg: Baselines.hrvCfg, baselineEpoch: 4_000_000_000)
        XCTAssertEqual(s.nValid, 0)
        XCTAssertEqual(s.status, .calibrating)
    }
}
