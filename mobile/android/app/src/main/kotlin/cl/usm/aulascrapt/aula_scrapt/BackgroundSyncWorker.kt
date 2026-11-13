package cl.usm.aulascrapt.aula_scrapt

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

class BackgroundSyncWorker(
    appContext: Context,
    workerParams: WorkerParameters,
) : Worker(appContext, workerParams) {

    companion object {
        private const val WORK_NAME = "aula_scrapt_bg_sync"
        private const val FLUTTER_PREFS = "FlutterSharedPreferences"
        private const val MOODLE_WS = "https://aula.usm.cl/webservice/rest/server.php"
        private const val GITHUB_LATEST = "https://api.github.com/repos/OscarAcosta17/Aula-Scrapt/releases/latest"
        private const val USER_AGENT = "Aula-Scrapt-Android-BgSync/1.3.0"

        fun schedule(context: Context, intervalHours: Int) {
            val wm = WorkManager.getInstance(context)
            if (intervalHours <= 0) {
                wm.cancelUniqueWork(WORK_NAME)
                return
            }
            val clampedHours = intervalHours.coerceIn(1, 24).toLong()
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()
            val request = PeriodicWorkRequestBuilder<BackgroundSyncWorker>(
                clampedHours,
                TimeUnit.HOURS,
            )
                .setConstraints(constraints)
                .build()

            wm.enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                request,
            )
        }
    }

    override fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        val allMap = prefs.all

        val nativeEnabled = (allMap["flutter.notify_native_enabled"] as? Boolean) ?: true
        val notifyNewFiles = (allMap["flutter.notify_on_new_files"] as? Boolean) ?: true
        val notifyDeadlines = (allMap["flutter.notify_on_deadlines"] as? Boolean) ?: true
        val autoUpdates = (allMap["flutter.auto_check_updates"] as? Boolean) ?: true

        val token = (allMap["flutter.moodle_token"] as? String)?.trim().orEmpty()
        val userId = allMap["flutter.moodle_user_id"]?.toString()?.toIntOrNull()

        val hiddenSet = parseHiddenCourses(allMap["flutter.hidden_courses_json"]?.toString())
        val knownIds = parseKnownIds(allMap["flutter.known_item_ids_json"]?.toString())
        val downloadedSet = parseDownloadedKeys(allMap["flutter.downloaded_ids_json"]?.toString())

        if (token.isNotEmpty() && userId != null && userId > 1) {
            syncCoursesWithToken(
                token = token,
                userId = userId,
                hiddenSet = hiddenSet,
                knownIds = knownIds,
                downloadedSet = downloadedSet,
                notifyNewFiles = notifyNewFiles,
                notifyDeadlines = notifyDeadlines,
                nativeEnabled = nativeEnabled,
            )
        }

        if (autoUpdates) {
            checkAppUpdate(nativeEnabled)
        }

        return Result.success()
    }

    private fun parseHiddenCourses(raw: String?): Set<Int> {
        if (raw.isNullOrBlank()) return emptySet()
        return try {
            val arr = JSONArray(raw)
            buildSet {
                for (i in 0 until arr.length()) {
                    add(arr.optInt(i))
                }
            }
        } catch (_: Exception) {
            emptySet()
        }
    }

    private fun parseKnownIds(raw: String?): Set<String> {
        if (raw.isNullOrBlank()) return emptySet()
        return try {
            val arr = JSONArray(raw)
            buildSet {
                for (i in 0 until arr.length()) {
                    val v = arr.optString(i)
                    if (v.isNotEmpty()) add(v)
                }
            }
        } catch (_: Exception) {
            emptySet()
        }
    }

    private fun parseDownloadedKeys(raw: String?): Set<String> {
        if (raw.isNullOrBlank()) return emptySet()
        return try {
            val obj = JSONObject(raw)
            val keys = obj.keys()
            buildSet {
                while (keys.hasNext()) add(keys.next())
            }
        } catch (_: Exception) {
            emptySet()
        }
    }

    private fun postMoodleWs(token: String, wsFunction: String, params: Map<String, String>): String? {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(MOODLE_WS).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                connectTimeout = 15000
                readTimeout = 20000
                setRequestProperty("User-Agent", USER_AGENT)
                setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            }
            val bodyParams = LinkedHashMap<String, String>()
            bodyParams["wstoken"] = token
            bodyParams["wsfunction"] = wsFunction
            bodyParams["moodlewsrestformat"] = "json"
            bodyParams.putAll(params)

            val encoded = bodyParams.entries.joinToString("&") { (k, v) ->
                "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
            }
            OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { it.write(encoded) }
            if (conn.responseCode != 200) return null
            BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { it.readText() }
        } catch (_: Exception) {
            null
        } finally {
            conn?.disconnect()
        }
    }

    private fun syncCoursesWithToken(
        token: String,
        userId: Int,
        hiddenSet: Set<Int>,
        knownIds: Set<String>,
        downloadedSet: Set<String>,
        notifyNewFiles: Boolean,
        notifyDeadlines: Boolean,
        nativeEnabled: Boolean,
    ) {
        val rawCourses = postMoodleWs(
            token,
            "core_enrol_get_users_courses",
            mapOf("userid" to userId.toString()),
        ) ?: return
        val coursesArr = try {
            JSONArray(rawCourses)
        } catch (_: Exception) {
            return
        }

        val activeCourseIds = mutableListOf<Int>()
        val courseNames = mutableMapOf<Int, String>()

        for (i in 0 until coursesArr.length()) {
            val c = coursesArr.optJSONObject(i) ?: continue
            val cid = c.optInt("id", 0)
            if (cid <= 1 || hiddenSet.contains(cid)) continue
            val name = c.optString("fullname", "Curso $cid")
            activeCourseIds.add(cid)
            courseNames[cid] = name

            if (notifyNewFiles && knownIds.isNotEmpty()) {
                val rawContents = postMoodleWs(
                    token,
                    "core_course_get_contents",
                    mapOf("courseid" to cid.toString()),
                ) ?: continue
                val secArr = try {
                    JSONArray(rawContents)
                } catch (_: Exception) {
                    continue
                }
                val newTitles = mutableListOf<String>()
                var firstNewId = ""
                for (s in 0 until secArr.length()) {
                    val secObj = secArr.optJSONObject(s) ?: continue
                    val mods = secObj.optJSONArray("modules") ?: continue
                    for (m in 0 until mods.length()) {
                        val mod = mods.optJSONObject(m) ?: continue
                        val modName = mod.optString("modname")
                        if (modName != "resource" && modName != "folder") continue
                        val cmid = mod.optInt("id", 0)
                        val title = mod.optString("name", "Archivo")
                        val contents = mod.optJSONArray("contents") ?: continue
                        for (f in 0 until contents.length()) {
                            val fn = contents.optJSONObject(f)?.optString("filename", title) ?: title
                            val candidates = if (modName == "folder") {
                                listOf(
                                    "folderfile_${cmid}_${fn.hashCode()}",
                                    "res_${cmid}_$f",
                                    "res_$cmid",
                                    "ws_folder_${cmid}_$f",
                                )
                            } else {
                                listOf(
                                    if (contents.length() == 1) "res_$cmid" else "res_${cmid}_$f",
                                    "ws_res_$cmid",
                                )
                            }
                            if (candidates.none { knownIds.contains(it) || downloadedSet.contains(it) }) {
                                if (firstNewId.isEmpty()) firstNewId = candidates.first()
                                newTitles.add(title)
                            }
                        }
                    }
                }
                if (newTitles.isNotEmpty()) {
                    val titleText = if (newTitles.size == 1) {
                        "Nuevo archivo en $name"
                    } else {
                        "${newTitles.size} archivos nuevos en $name"
                    }
                    val bodyText = if (newTitles.size == 1) newTitles.first() else "Incluye: ${newTitles.first()}"
                    val inserted = NotificationHelper.appendHistoryEvent(
                        context = applicationContext,
                        title = titleText,
                        body = bodyText,
                        kind = "new_file",
                        courseName = name,
                        dedupKey = "new:$cid:$firstNewId:${newTitles.size}",
                    )
                    if (inserted && nativeEnabled) {
                        NotificationHelper.showNotification(
                            applicationContext,
                            titleText,
                            bodyText,
                            NotificationHelper.CHANNEL_NEW_FILES,
                            notifId = ("new_$cid").hashCode(),
                        )
                    }
                }
            }
        }

        if (notifyDeadlines && activeCourseIds.isNotEmpty()) {
            val nowSec = System.currentTimeMillis() / 1000L
            val courseParams = LinkedHashMap<String, String>()
            activeCourseIds.forEachIndexed { idx, cid ->
                courseParams["courseids[$idx]"] = cid.toString()
            }

            // Assignments
            postMoodleWs(token, "mod_assign_get_assignments", courseParams)?.let { raw ->
                try {
                    val obj = JSONObject(raw)
                    val courses = obj.optJSONArray("courses") ?: JSONArray()
                    for (i in 0 until courses.length()) {
                        val cObj = courses.optJSONObject(i) ?: continue
                        val cid = cObj.optInt("id", 0)
                        val cName = courseNames[cid] ?: cObj.optString("fullname", "Ramo")
                        val assigns = cObj.optJSONArray("assignments") ?: continue
                        for (j in 0 until assigns.length()) {
                            val a = assigns.optJSONObject(j) ?: continue
                            val dueTs = a.optLong("duedate", 0L)
                            val diff = dueTs - nowSec
                            if (dueTs > 0 && diff in 1..(48L * 3600L)) {
                                val hrs = maxOf(1L, diff / 3600L)
                                val aTitle = a.optString("name", "Entrega")
                                val title = "Entrega próxima en ${hrs}h"
                                val body = "$cName: $aTitle"
                                val dedup = "due_assign_${a.optInt("id")}_$dueTs"
                                if (NotificationHelper.appendHistoryEvent(
                                        applicationContext,
                                        title,
                                        body,
                                        "deadline",
                                        cName,
                                        dedup,
                                    ) && nativeEnabled
                                ) {
                                    NotificationHelper.showNotification(
                                        applicationContext,
                                        title,
                                        body,
                                        NotificationHelper.CHANNEL_DEADLINES,
                                        notifId = dedup.hashCode(),
                                    )
                                }
                            }
                        }
                    }
                } catch (_: Exception) {
                }
            }

            // Quizzes
            postMoodleWs(token, "mod_quiz_get_quizzes_by_courses", courseParams)?.let { raw ->
                try {
                    val obj = JSONObject(raw)
                    val quizzes = obj.optJSONArray("quizzes") ?: return@let
                    for (i in 0 until quizzes.length()) {
                        val q = quizzes.optJSONObject(i) ?: continue
                        val cid = q.optInt("course", 0)
                        val cName = courseNames[cid] ?: "Ramo"
                        val dueTs = q.optLong("timeclose", 0L)
                        val diff = dueTs - nowSec
                        if (dueTs > 0 && diff in 1..(48L * 3600L)) {
                            val hrs = maxOf(1L, diff / 3600L)
                            val qTitle = q.optString("name", "Cuestionario")
                            val title = "Evaluación cierra en ${hrs}h"
                            val body = "$cName: $qTitle"
                            val dedup = "due_quiz_${q.optInt("id")}_$dueTs"
                            if (NotificationHelper.appendHistoryEvent(
                                    applicationContext,
                                    title,
                                    body,
                                    "deadline",
                                    cName,
                                    dedup,
                                ) && nativeEnabled
                            ) {
                                NotificationHelper.showNotification(
                                    applicationContext,
                                    title,
                                    body,
                                    NotificationHelper.CHANNEL_DEADLINES,
                                    notifId = dedup.hashCode(),
                                )
                            }
                        }
                    }
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun checkAppUpdate(nativeEnabled: Boolean) {
        var conn: HttpURLConnection? = null
        try {
            conn = (URL(GITHUB_LATEST).openConnection() as HttpURLConnection).apply {
                connectTimeout = 10000
                readTimeout = 12000
                setRequestProperty("Accept", "application/vnd.github+json")
                setRequestProperty("User-Agent", USER_AGENT)
            }
            if (conn.responseCode != 200) return
            val json = JSONObject(
                BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8)).use { it.readText() },
            )
            val tag = json.optString("tag_name", "").trim().removePrefix("v").removePrefix("V")
            if (tag.isEmpty()) return

            val currentVer = getInstalledVersionName()
            if (isNewerVersion(tag, currentVer)) {
                val title = "Nueva actualización v$tag"
                val body = "Hay una versión más reciente de Aula-Scrapt disponible en Configuración."
                if (NotificationHelper.appendHistoryEvent(
                        applicationContext,
                        title,
                        body,
                        "update",
                        dedupKey = "upd_$tag",
                    ) && nativeEnabled
                ) {
                    NotificationHelper.showNotification(
                        applicationContext,
                        title,
                        body,
                        NotificationHelper.CHANNEL_UPDATES,
                        notifId = "upd_$tag".hashCode(),
                    )
                }
            }
        } catch (_: Exception) {
        } finally {
            conn?.disconnect()
        }
    }

    @Suppress("DEPRECATION")
    private fun getInstalledVersionName(): String {
        return try {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                applicationContext.packageManager.getPackageInfo(
                    applicationContext.packageName,
                    PackageManager.PackageInfoFlags.of(0),
                )
            } else {
                applicationContext.packageManager.getPackageInfo(applicationContext.packageName, 0)
            }
            info.versionName ?: "1.3.0"
        } catch (_: Exception) {
            "1.3.0"
        }
    }

    private fun isNewerVersion(remote: String, local: String): Boolean {
        fun parse(v: String): List<Int> {
            val clean = v.split("+", "-").firstOrNull().orEmpty()
            val nums = Regex("\\d+").findAll(clean).take(3).map { it.value.toIntOrNull() ?: 0 }.toMutableList()
            while (nums.size < 3) nums.add(0)
            return nums
        }
        val r = parse(remote)
        val l = parse(local)
        for (i in 0..2) {
            if (r[i] != l[i]) return r[i] > l[i]
        }
        return false
    }
}
