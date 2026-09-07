package com.noop.widget

import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver

/** #1957: manifest entry point for the heart-rate trace widget — all rendering lives in
 *  [NoopHrTraceGlanceWidget]. */
class NoopHrTraceWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = NoopHrTraceGlanceWidget()
}
