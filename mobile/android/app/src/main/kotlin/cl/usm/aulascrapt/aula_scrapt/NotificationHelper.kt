package cl.usm.aulascrapt.aula_scrapt

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

object NotificationHelper {
    const val CHANNEL_NEW_FILES = "aula_new_files"
    const val CHANNEL_DEADLINES = "aula_deadlines"
    const val CHANNEL_DOWNLOADS = "aula_downloads"
    const val CHANNEL_UPDATES = "aula_updates"

    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val KEY_NOTIF_HISTORY = "flutter.notifications_history_json"
    private const val MAX_NOTIFICATIONS = 80
    private const val DEDUP_WINDOW_MS = 18L * 3600L * 1000L

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channels = listOf(
            NotificationChannel(
                CHANNEL_NEW_FILES,
                "Nuevos archivos de Aula",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Avisa cuando un profesor publica material nuevo"
            },
            NotificationChannel(
                CHANNEL_DEADLINES,
                "Entregas y cuestionarios",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Alertas de entregas y evaluaciones próximas (< 48h)"
            },
            NotificationChannel(
                CHANNEL_DOWNLOADS,
                "Descargas completadas",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Confirmaciones de descarga de archivos"
            },
            NotificationChannel(
                CHANNEL_UPDATES,
                "Actualizaciones",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Nuevas versiones disponibles de Aula-Scrapt"
            },
        )
        channels.forEach { manager.createNotificationChannel(it) }
    }

    fun hasPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun showNotification(
        context: Context,
        title: String,
        body: String,
        channelId: String = CHANNEL_NEW_FILES,
        notifId: Int = (System.currentTimeMillis() and 0x7FFFFFFF).toInt(),
    ): Boolean {
        ensureChannels(context)
        if (!hasPermission(context)) return false

        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val pendingIntent = PendingIntent.getActivity(context, notifId, launchIntent, pendingFlags)

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(title.ifBlank { "Aula-Scrapt USM" })
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setPriority(
                if (channelId == CHANNEL_DEADLINES) NotificationCompat.PRIORITY_HIGH
                else NotificationCompat.PRIORITY_DEFAULT,
            )

        return try {
            NotificationManagerCompat.from(context).notify(notifId, builder.build())
            true
        } catch (_: SecurityException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Appends an event into Flutter's SharedPreferences notification history so the
     * in-app Notification Center stays in sync with background WorkManager checks.
     */
    fun appendHistoryEvent(
        context: Context,
        title: String,
        body: String,
        kind: String,
        courseName: String = "",
        dedupKey: String = "",
    ): Boolean {
        val prefs = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_NOTIF_HISTORY, "[]") ?: "[]"
        val arr = try {
            JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }

        val nowMs = System.currentTimeMillis()
        if (dedupKey.isNotEmpty()) {
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                if (obj.optString("dedup_key") == dedupKey) {
                    val createdMs = obj.optLong("created_at", 0L) * 1000L
                    if (nowMs - createdMs < DEDUP_WINDOW_MS) {
                        return false
                    }
                }
            }
        }

        val entry = JSONObject().apply {
            put("id", UUID.randomUUID().toString().replace("-", "").take(12))
            put("title", title)
            put("body", body)
            put("kind", kind)
            put("course_name", courseName)
            put("dedup_key", dedupKey)
            put("created_at", nowMs / 1000L)
            put("read", false)
        }

        val updated = JSONArray()
        updated.put(entry)
        val cap = minOf(arr.length(), MAX_NOTIFICATIONS - 1)
        for (i in 0 until cap) {
            updated.put(arr.get(i))
        }
        prefs.edit().putString(KEY_NOTIF_HISTORY, updated.toString()).apply()
        return true
    }
}
