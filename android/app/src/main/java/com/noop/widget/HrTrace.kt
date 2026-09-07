package com.noop.widget

/**
 * #1957: the pure half of the heart-rate trace widget — everything decidable WITHOUT a Canvas.
 *
 * Glance compiles to RemoteViews, which has no Canvas, so a sparkline cannot be drawn by a
 * composable. It has to be rendered to a Bitmap and handed over as an Image. That splits the work
 * in two: retention, normalisation, and tick choice belong here (pure, unit-tested), and the
 * Bitmap draw belongs in the widget renderer (not JVM-testable).
 *
 * The [WidgetSnapshotStore] already receives a live HR on the app's own cadence, throttled by
 * [PushGate] to about once a minute, which is a natural bucket size for a trace. This class folds
 * each push into a rolling window and produces the normalised points + min/max + time ticks the
 * renderer paints.
 *
 * Pure + stateless: the store holds the series; this class only shapes it.
 */
internal object HrTrace {

    /** The window the trace covers: the last 2 hours of HR. */
    const val WINDOW_MS = 2 * 60 * 60_000L

    /** The minimum gap between two consecutive trace points — matches [PushGate]'s ~60 s cadence. */
    const val BUCKET_MS = 60_000L

    /** The cap on the number of points the renderer must draw, so the Bitmap stays under the
     *  Binder transaction limit. At 1/min over 2 h that is 120, well under this cap. */
    const val MAX_POINTS = 240

    /**
     * A single point in the trace, already normalised to [0, 1] for both axes.
     *
     * `x` = 0 is the OLDEST point in the window; `x` = 1 is the NEWEST. `y` = 0 is the MIN bpm in
     * the window; `y` = 1 is the MAX. The renderer multiplies by its pixel dimensions.
     */
    data class Point(val x: Float, val y: Float, val bpm: Int, val tsMs: Long)

    /**
     * The normalised trace + the scalar min/max/ticks the renderer needs for labels.
     *
     * `points` is empty when there are fewer than 2 samples (a single point is not a trace).
     * `ticks` are the time labels the renderer paints under the x-axis, each with a normalised x
     * position and a short label string (e.g. "14:00").
     */
    data class Shape(
        val points: List<Point>,
        val minBpm: Int,
        val maxBpm: Int,
        val ticks: List<Tick>,
    )

    data class Tick(val x: Float, val label: String)

    /**
     * Fold a new HR sample into the rolling series.
     *
     * The series is a list of `(tsMs, bpm)` pairs, oldest first, deduplicated to one per
     * [BUCKET_MS] bucket. A new sample either fills the current bucket (replacing its value) or
     * starts a new one. Samples older than [WINDOW_MS] are dropped on each fold, so the series
     * never grows unbounded.
     *
     * Pure: returns a new list, does not mutate the input.
     */
    fun fold(series: List<Pair<Long, Int>>, tsMs: Long, bpm: Int, nowMs: Long): List<Pair<Long, Int>> {
        if (bpm <= 0) return series
        val bucket = tsMs / BUCKET_MS
        val updated = series.toMutableList()
        // Replace the last point if it is in the same bucket; otherwise append.
        if (updated.isNotEmpty() && updated.last().first / BUCKET_MS == bucket) {
            updated[updated.lastIndex] = tsMs to bpm
        } else {
            updated.add(tsMs to bpm)
        }
        // Drop everything older than the window.
        val cutoff = nowMs - WINDOW_MS
        while (updated.isNotEmpty() && updated.first().first < cutoff) {
            updated.removeAt(0)
        }
        // Cap the point count (defensive — at 1/min over 2 h this is never reached).
        if (updated.size > MAX_POINTS) {
            updated.subList(0, updated.size - MAX_POINTS).clear()
        }
        return updated
    }

    /**
     * Normalise the series into a [Shape] for the renderer.
     *
     * Returns an empty shape when there are fewer than 2 points (a single point is not a trace).
     * The y-axis is padded by 5 bpm on each side of the min/max so the line does not touch the
     * top/bottom of the bitmap — the same visual padding a chart gives.
     *
     * Ticks: up to 3 time labels (start, middle, end) in the user's locale short-time form, spaced
     * so they never overlap. The renderer paints them under the x-axis.
     */
    fun shape(series: List<Pair<Long, Int>>, nowMs: Long): Shape {
        if (series.size < 2) return Shape(emptyList(), 0, 0, emptyList())
        val windowStart = nowMs - WINDOW_MS
        val minBpm = series.minOf { it.second } - 5
        val maxBpm = series.maxOf { it.second } + 5
        val bpmSpan = (maxBpm - minBpm).coerceAtLeast(1)
        val tsSpan = (nowMs - windowStart).coerceAtLeast(1L)
        val points = series.map { (ts, bpm) ->
            val x = ((ts - windowStart).toFloat() / tsSpan).coerceIn(0f, 1f)
            val y = ((bpm - minBpm).toFloat() / bpmSpan).coerceIn(0f, 1f)
            Point(x, y, bpm, ts)
        }
        val ticks = ticks(series, nowMs)
        return Shape(points, minBpm + 5, maxBpm - 5, ticks)
    }

    /**
     * Choose up to 3 time ticks: the oldest point, the newest, and one in the middle if there is
     * room. Each tick's label is a short `HH:mm` in the device's locale.
     */
    private fun ticks(series: List<Pair<Long, Int>>, nowMs: Long): List<Tick> {
        val windowStart = nowMs - WINDOW_MS
        val tsSpan = (nowMs - windowStart).coerceAtLeast(1L)
        val fmt = java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault())
        val oldest = series.first()
        val newest = series.last()
        val ticks = mutableListOf<Tick>()
        ticks.add(Tick(0f, fmt.format(java.util.Date(oldest.first))))
        // Add a middle tick only if it is far enough from both ends to avoid overlap.
        if (series.size >= 4) {
            val mid = series[series.size / 2]
            val midX = ((mid.first - windowStart).toFloat() / tsSpan).coerceIn(0f, 1f)
            if (midX > 0.25f && midX < 0.75f) {
                ticks.add(Tick(midX, fmt.format(java.util.Date(mid.first))))
            }
        }
        ticks.add(Tick(1f, fmt.format(java.util.Date(newest.first))))
        return ticks
    }
}
