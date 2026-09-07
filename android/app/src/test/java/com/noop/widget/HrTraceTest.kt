package com.noop.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/// #1957: pins the pure half of the heart-rate trace widget — retention, normalisation, tick
/// choice. The Bitmap draw is not JVM-testable (no Canvas), so everything decidable without one
/// lives in [HrTrace] and is covered here.
class HrTraceTest {

    private val now = 1_700_000_000_000L

    @Test fun emptySeriesProducesEmptyShape() {
        val shape = HrTrace.shape(emptyList(), now)
        assertTrue(shape.points.isEmpty())
        assertTrue(shape.ticks.isEmpty())
    }

    @Test fun singlePointIsNotATrace() {
        val shape = HrTrace.shape(listOf(now - 60_000L to 72), now)
        assertTrue(shape.points.isEmpty())
    }

    @Test fun twoPointsProduceTwoNormalisedPoints() {
        val series = listOf(now - 120_000L to 60, now - 60_000L to 80)
        val shape = HrTrace.shape(series, now)
        assertEquals(2, shape.points.size)
        // Oldest → x=0 (left), newest → x=1 (right).
        assertEquals(0f, shape.points.first().x, 0.01f)
        assertEquals(1f, shape.points.last().x, 0.01f)
        // Min bpm (60) → y=0 (bottom), max bpm (80) → y=1 (top), with 5 bpm padding.
        assertEquals(0f, shape.points.first().y, 0.01f)
        assertEquals(1f, shape.points.last().y, 0.01f)
        // Min/max are the RAW values (without the 5 bpm padding used for normalisation).
        assertEquals(60, shape.minBpm)
        assertEquals(80, shape.maxBpm)
    }

    @Test fun foldAppendsNewBucket() {
        val series = listOf(now - 120_000L to 60)
        val folded = HrTrace.fold(series, now, 72, now)
        assertEquals(2, folded.size)
        assertEquals(now to 72, folded.last())
    }

    @Test fun foldReplacesSameBucket() {
        val ts = now
        val series = listOf(ts - 120_000L to 60, ts to 70)
        // Same bucket (same ts / 60_000) → replace, not append.
        val folded = HrTrace.fold(series, ts, 75, ts)
        assertEquals(2, folded.size)
        assertEquals(ts to 75, folded.last())
    }

    @Test fun foldDropsOldPoints() {
        // Two points: one 3 hours old (outside the 2h window), one recent.
        val old = now - 3 * 60 * 60_000L
        val recent = now - 60_000L
        val series = listOf(old to 60, recent to 72)
        val folded = HrTrace.fold(series, now, 80, now)
        // The old point is dropped; the recent one + the new one survive.
        assertEquals(2, folded.size)
        assertTrue(folded.all { it.first >= now - HrTrace.WINDOW_MS })
    }

    @Test fun foldIgnoresZeroOrNegativeBpm() {
        val series = listOf(now - 60_000L to 60)
        val folded = HrTrace.fold(series, now, 0, now)
        assertEquals(series, folded)
    }

    @Test fun ticksIncludeOldestAndNewest() {
        val series = listOf(now - 120_000L to 60, now - 60_000L to 72)
        val shape = HrTrace.shape(series, now)
        assertEquals(2, shape.ticks.size)
        assertEquals(0f, shape.ticks.first().x, 0.01f)
        assertEquals(1f, shape.ticks.last().x, 0.01f)
    }

    @Test fun ticksAddMiddleForLongSeries() {
        val series = (0..5).map { i -> (now - (5 - i) * 60_000L) to (60 + i * 4) }
        val shape = HrTrace.shape(series, now)
        // 3 ticks: oldest, middle, newest.
        assertEquals(3, shape.ticks.size)
        val midX = shape.ticks[1].x
        assertTrue("middle tick should be between 0.25 and 0.75", midX > 0.25f && midX < 0.75f)
    }

    @Test fun yNormalisationIsPaddedBy5Bpm() {
        val series = listOf(now - 120_000L to 60, now - 60_000L to 80)
        val shape = HrTrace.shape(series, now)
        // The min (60) maps to y=0 because the y-axis is padded by 5 bpm below (55) and above (85),
        // so (60-55)/(85-55) = 5/30 ≈ 0.167, not 0.
        assertEquals(0.167f, shape.points.first().y, 0.01f)
        // The max (80) maps to y=1 because (80-55)/(85-55) = 25/30 ≈ 0.833, not 1.
        assertEquals(0.833f, shape.points.last().y, 0.01f)
    }

    @Test fun encodeAndDecodeRoundTrip() {
        val series = listOf(now - 120_000L to 60, now - 60_000L to 72)
        val encoded = WidgetSnapshotStore.encodeHrTrace(series)
        val decoded = WidgetSnapshotStore.decodeHrTrace(encoded)
        assertEquals(series, decoded)
    }

    @Test fun decodeNullOrEmptyReturnsEmptyList() {
        assertTrue(WidgetSnapshotStore.decodeHrTrace(null).isEmpty())
        assertTrue(WidgetSnapshotStore.decodeHrTrace("").isEmpty())
    }

    @Test fun decodeSkipsMalformedPairs() {
        val decoded = WidgetSnapshotStore.decodeHrTrace("abc:def,1700000000000:72")
        assertEquals(1, decoded.size)
        assertEquals(72, decoded[0].second)
    }
}
