package com.noop.widget

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.noop.R
import com.noop.ui.MainActivity
import com.noop.ui.uiString

/**
 * #1957: a home-screen widget showing the live heart rate with recent history as a trace.
 *
 * The current bpm, a min/max for the window, and a sparkline with a bpm scale and time labels. The
 * existing widgets carry HR as a NUMBER only; the number alone does not say whether 69 is a resting
 * evening or the tail of a climb, which is the thing a glance is for.
 *
 * Glance compiles to RemoteViews, which has no Canvas. The sparkline is rendered to a [Bitmap] and
 * handed over as an [androidx.glance.Image]. Everything decidable without a Canvas (retention,
 * normalisation, tick choice) lives in [HrTrace], unit-tested; this class only paints.
 *
 * Renders purely from the [WidgetSnapshotStore] SharedPreferences snapshot — no BLE, no DB — so it
 * costs nothing and survives process death. Tapping anywhere opens the app.
 */
class NoopHrTraceGlanceWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snap = runCatching { WidgetSnapshotStore.load(context) }.getOrDefault(WidgetSnapshot())
        val series = runCatching { WidgetSnapshotStore.loadHrTrace(context) }.getOrDefault(emptyList())
        val dark = runCatching {
            when (context.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
                .getString("theme.appearance", "system")) {
                "light" -> false
                "dark" -> true
                else -> (context.resources.configuration.uiMode and
                    android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
                    android.content.res.Configuration.UI_MODE_NIGHT_YES
            }
        }.getOrDefault(true)
        val shape = HrTrace.shape(series, System.currentTimeMillis())
        val bitmap = runCatching { renderSparkline(shape, dark) }.getOrNull()
        provideContent { WidgetContent(snap, shape, bitmap, dark) }
    }

    override fun onCompositionError(
        context: Context,
        glanceId: GlanceId,
        appWidgetId: Int,
        throwable: Throwable,
    ) {
        runCatching {
            val rv = android.widget.RemoteViews(context.packageName, R.layout.noop_widget_error)
            android.appwidget.AppWidgetManager.getInstance(context).updateAppWidget(appWidgetId, rv)
        }
    }
}

// Per-scheme colours — mirrors of the app palette (same as the standard widget).
private fun widgetSurface(dark: Boolean) = ColorProvider(if (dark) Color(0xFF0A1322) else Color(0xFFF4F1EA))
private fun widgetTextPrimary(dark: Boolean) = ColorProvider(if (dark) Color(0xFFF4F6F8) else Color(0xFF1A2230))
private fun widgetTextSecondary(dark: Boolean) = ColorProvider(if (dark) Color(0xFF8A94A4) else Color(0xFF7C8696))
private fun traceColor(dark: Boolean) = if (dark) Color(0xFFE0662F) else Color(0xFFC84E1E)

/**
 * Render the sparkline to a [Bitmap]. The bitmap is capped at 300×120 px so it stays well under
 * the Binder transaction limit (~1 MB). The path is drawn as a connected line with 2 px stroke.
 */
private fun renderSparkline(shape: HrTrace.Shape, dark: Boolean): Bitmap? {
    if (shape.points.isEmpty()) return null
    val w = 300
    val h = 120
    val pad = 8f
    val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bmp)
    val lineColor = traceColor(dark)
    val tickColor = if (dark) 0xFF8A94A4.toInt() else 0xFF7C8696.toInt()
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = lineColor
        style = Paint.Style.STROKE
        strokeWidth = 2f
    }
    val tickPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = tickColor
        textSize = 18f
    }
    // Draw the trace path.
    val path = Path()
    val drawW = w - 2 * pad
    val drawH = h - 2 * pad
    shape.points.forEachIndexed { i, pt ->
        val px = pad + pt.x * drawW
        val py = pad + (1f - pt.y) * drawH
        if (i == 0) path.moveTo(px, py) else path.lineTo(px, py)
    }
    canvas.drawPath(path, paint)
    // Draw the time ticks under the x-axis.
    shape.ticks.forEach { tick ->
        val px = pad + tick.x * drawW
        canvas.drawText(tick.label, px, h - 2f, tickPaint)
    }
    return bmp
}

@Composable
private fun WidgetContent(
    snap: WidgetSnapshot,
    shape: HrTrace.Shape,
    bitmap: Bitmap?,
    dark: Boolean,
) {
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(widgetSurface(dark))
            .cornerRadius(16.dp)
            .padding(12.dp)
            .clickable(actionStartActivity<MainActivity>()),
    ) {
        // Header: "Heart Rate" + current bpm.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = uiString(R.string.l10n_noop_glance_widget_heart_rate_410aa15c),
                style = TextStyle(color = widgetTextSecondary(dark), fontSize = 12.sp),
            )
            Spacer(modifier = GlanceModifier.defaultWeight())
            Text(
                text = snap.heartRate?.let { "$it" } ?: "—",
                style = TextStyle(
                    color = if (snap.heartRateStale) widgetTextSecondary(dark) else widgetTextPrimary(dark),
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
            Text(
                text = " bpm",
                style = TextStyle(color = widgetTextSecondary(dark), fontSize = 12.sp),
            )
        }
        Spacer(modifier = GlanceModifier.height(4.dp))
        // Min / max row.
        if (shape.points.isNotEmpty()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "${shape.minBpm}–${shape.maxBpm}",
                    style = TextStyle(color = widgetTextSecondary(dark), fontSize = 11.sp),
                )
                Spacer(modifier = GlanceModifier.defaultWeight())
            }
            Spacer(modifier = GlanceModifier.height(4.dp))
        }
        // The sparkline as a Bitmap image (Glance has no Canvas).
        if (bitmap != null) {
            Image(
                provider = ImageProvider(bitmap),
                contentDescription = uiString(R.string.l10n_noop_glance_widget_heart_rate_410aa15c),
                modifier = GlanceModifier.fillMaxWidth().height(60.dp),
            )
        }
        Spacer(modifier = GlanceModifier.defaultWeight())
        // Updated stamp.
        Text(
            text = when {
                snap.connected -> "Connected"
                snap.updatedAtMs > 0L ->
                    java.text.SimpleDateFormat(
                        com.noop.analytics.ClockFormat.hourMinutePattern(
                            com.noop.ui.ClockPrefs.uses24Hour(androidx.glance.LocalContext.current),
                        ),
                        java.util.Locale.getDefault(),
                    ).format(java.util.Date(snap.updatedAtMs))
                else -> "Open NOOP to connect"
            },
            style = TextStyle(color = widgetTextSecondary(dark), fontSize = 11.sp),
        )
    }
}
