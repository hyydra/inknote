package com.hyydra.inknote

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.widget.RemoteViews
import java.io.File

class InkNoteWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { id -> update(context, manager, id) }
    }
    companion object {
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, InkNoteWidget::class.java))
            ids.forEach { update(context, manager, it) }
        }
        private fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val views = RemoteViews(context.packageName, R.layout.inknote_widget)
            val prefs = context.getSharedPreferences("inknote_widget", Context.MODE_PRIVATE)
            views.setTextViewText(R.id.widget_title, prefs.getString("title", "InkNote"))
            val file = File(context.filesDir, "inknote_widget.png")
            if (file.exists()) {
                val opts = BitmapFactory.Options().apply { inPreferredConfig = android.graphics.Bitmap.Config.RGB_565; inSampleSize = 2 }
                BitmapFactory.decodeFile(file.absolutePath, opts)?.let { views.setImageViewBitmap(R.id.widget_image, it) }
            }
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (intent != null) {
                val pending = PendingIntent.getActivity(context, 0, intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                views.setOnClickPendingIntent(R.id.widget_root, pending)
                views.setOnClickPendingIntent(R.id.widget_image, pending)
            }
            manager.updateAppWidget(id, views)
        }
    }
}
