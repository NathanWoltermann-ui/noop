package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.abs

/**
 * Parity mirror of the Swift BaselinesTests early-anchoring + recalibration cases (the HRV half of
 * the Reddit Charge report). Pins two behaviours:
 *
 *  1. Early-life anti-anchoring: artificially-high cold-start nights followed by genuine lower nights
 *     must converge toward reality in DAYS, not the ~2-3 weeks the old halfLifeB=14 EWMA took — and the
 *     genuine lower nights must NOT be rejected as hard outliers while the spread is still floor-tight.
 *     A settled baseline still rejects a wild one-off outlier (the gate is suspended only during early
 *     life, not disabled).
 *
 *  2. Manual recalibration: foldHistory(values, dayKeys, cfg, baselineEpoch) drops every night before
 *     the epoch (`noop.hrvBaselineEpoch`, epoch SECONDS) and re-seeds from the first on-or-after night.
 */
class HrvBaselineRecalibrationTest {

    private val hrvCfg = Baselines.metricCfg.getValue("hrv")

    // ── 1. Early-life anti-anchoring ────────────────────────────────────────────────────────────

    @Test
    fun earlyHighSeed_convergesQuickly() {
        // 3 high cold-start nights (~90ms) then the user's true ~54ms for a week.
        val vals: List<Double?> = listOf(90.0, 92.0, 88.0) + List(7) { 54.0 }
        val s = Baselines.foldHistory(vals, hrvCfg)
        assertTrue(
            "early-high seed should converge near the true value within ~1 week, got ${s.baseline}",
            s.baseline < 65.0,
        )
        val dev = Baselines.deviation(54.0, s)
        assertTrue(
            "a real night near the converged baseline shouldn't read as an extreme outlier, z=${dev.z}",
            abs(dev.z) < 2.0,
        )
    }

    @Test
    fun genuineLowerNights_notRejectedDuringSeed() {
        val seedHigh = Baselines.foldHistory(List(4) { 90.0 }, hrvCfg)
        val vals: List<Double?> = List(4) { 90.0 } + List(5) { 55.0 }
        val after = Baselines.foldHistory(vals, hrvCfg)
        assertTrue(
            "lower nights must be folded (baseline drops), not rejected as outliers",
            after.baseline < seedHigh.baseline - 15.0,
        )
    }

    @Test
    fun hardOutlier_stillRejectedOnceSettled() {
        // Enough varied nights to get past earlyAdaptNights AND lift spread off the floor.
        val vals = ArrayList<Double?>()
        for (i in 0 until 14) vals.add(50.0 + (i % 3).toDouble()) // 50/51/52 jitter
        val stable = Baselines.foldHistory(vals, hrvCfg)
        assertTrue(stable.nValid >= Baselines.earlyAdaptNights)
        vals.add(220.0) // wild outlier
        val after = Baselines.foldHistory(vals, hrvCfg)
        assertEquals(
            "a settled baseline should still reject a wild outlier",
            stable.baseline, after.baseline, 2.0,
        )
    }

    @Test
    fun earlyPath_noOpOnConstantSeries() {
        val s = Baselines.foldHistory(List(30) { 50.0 }, hrvCfg)
        assertEquals(50.0, s.baseline, 1e-6)
        assertEquals(hrvCfg.floorSpread, s.spread, 1e-9)
    }

    // ── 2. Manual recalibration epoch (noop.hrvBaselineEpoch) ───────────────────────────────────

    @Test
    fun recalibrateEpoch_reseedsFromEpoch() {
        val days = listOf(
            "2026-06-08", "2026-06-09", "2026-06-10", "2026-06-11", "2026-06-12", "2026-06-13",
            "2026-06-15", "2026-06-16", "2026-06-17", "2026-06-18", "2026-06-19", "2026-06-20",
        )
        val vals: List<Double?> = listOf(90.0, 91.0, 89.0, 90.0, 92.0, 88.0, 54.0, 55.0, 53.0, 54.0, 56.0, 54.0)
        val epoch = LocalDate.parse("2026-06-15").atStartOfDay(ZoneOffset.UTC).toEpochSecond().toDouble()

        val recalibrated = Baselines.foldHistory(vals, days, hrvCfg, epoch)
        assertEquals(6, recalibrated.nValid) // only the 6 post-epoch nights contribute
        assertEquals(54.0, recalibrated.baseline, 2.0)

        val notRecalibrated = Baselines.foldHistory(vals, days, hrvCfg, 0.0)
        assertTrue(notRecalibrated.baseline > recalibrated.baseline + 10.0)
    }

    @Test
    fun recalibrateEpoch_zeroIsNoOp() {
        val days = listOf("2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04")
        val vals: List<Double?> = listOf(60.0, 61.0, 59.0, 62.0)
        val withZero = Baselines.foldHistory(vals, days, hrvCfg, 0.0)
        val plain = Baselines.foldHistory(vals, hrvCfg)
        assertEquals(plain.baseline, withZero.baseline, 1e-9)
        assertEquals(plain.nValid, withZero.nValid)
    }

    @Test
    fun recalibrateEpoch_afterAllNights_resetsToColdStart() {
        val days = listOf("2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04")
        val vals: List<Double?> = listOf(60.0, 61.0, 59.0, 62.0)
        val s = Baselines.foldHistory(vals, days, hrvCfg, 4_000_000_000.0) // far-future epoch
        assertEquals(0, s.nValid)
        assertEquals(BaselineStatus.CALIBRATING, s.status)
    }
}
