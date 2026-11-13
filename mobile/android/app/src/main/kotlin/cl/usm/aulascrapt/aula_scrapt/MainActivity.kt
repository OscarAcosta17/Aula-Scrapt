package cl.usm.aulascrapt.aula_scrapt

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import android.view.WindowManager
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val channelName = "cl.usm.aulascrapt/storage"
    private val pickDirRequestCode = 9412
    private val notifPermRequestCode = 9413
    private var pendingDirResult: MethodChannel.Result? = null
    private var pendingNotifPermResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Edge-to-edge nativo Android 15-17 para dibujar debajo de barra de estado y gestos
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        @Suppress("DEPRECATION")
        if (Build.VERSION.SDK_INT < 35) {
            window.statusBarColor = Color.TRANSPARENT
            window.navigationBarColor = Color.TRANSPARENT
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                "getExternalRoot" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
                "getSystemSeedColor" -> result.success(readSystemAccentColor())
                "getAppInfo" -> result.success(readAppInfo())
                "canRequestPackageInstalls" -> result.success(canInstallUnknownPackages())
                "openInstallPermissionSettings" -> {
                    openUnknownSourcesSettings(result)
                }
                "installApk" -> {
                    val apkPath = call.argument<String>("path")
                    launchApkInstaller(apkPath, result)
                }
                "computeFileSha256" -> {
                    val filePath = call.argument<String>("path")
                    result.success(computeSha256(filePath))
                }
                "openLocalFile" -> {
                    val filePath = call.argument<String>("path")
                    openLocalFile(filePath, result)
                }
                "hasNotificationPermission" -> {
                    result.success(NotificationHelper.hasPermission(this))
                }
                "requestNotificationPermission" -> {
                    requestPostNotificationPermission(result)
                }
                "showNativeNotification" -> {
                    val title = call.argument<String>("title") ?: "Aula-Scrapt"
                    val body = call.argument<String>("body") ?: ""
                    val channelId = call.argument<String>("channelId") ?: NotificationHelper.CHANNEL_NEW_FILES
                    result.success(NotificationHelper.showNotification(this, title, body, channelId))
                }
                "scheduleBackgroundSync" -> {
                    val hours = call.argument<Int>("intervalHours") ?: 0
                    BackgroundSyncWorker.schedule(applicationContext, hours)
                    result.success(true)
                }
                "scanQrCode" -> {
                    startQrCodeScanner(result)
                }
                "pickDirectory" -> {
                    if (pendingDirResult != null) {
                        result.error("BUSY", "Selector ya abierto", null)
                        return@setMethodCallHandler
                    }
                    pendingDirResult = result
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                        intent.addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                        )
                        startActivityForResult(intent, pickDirRequestCode)
                    } catch (e: Exception) {
                        pendingDirResult = null
                        result.error("PICKER_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun readSystemAccentColor(): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        return try {
            resources.getColor(android.R.color.system_accent1_500, theme)
        } catch (_: Exception) {
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun readAppInfo(): Map<String, Any?> {
        val pkgInfo: PackageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            packageManager.getPackageInfo(packageName, 0)
        }
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            pkgInfo.longVersionCode
        } else {
            pkgInfo.versionCode.toLong()
        }
        return mapOf(
            "versionName" to (pkgInfo.versionName ?: "1.3.0"),
            "versionCode" to versionCode,
            "packageName" to packageName,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }

    private fun canInstallUnknownPackages(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return packageManager.canRequestPackageInstalls()
        }
        return true
    }

    private fun openUnknownSourcesSettings(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(true)
            return
        }
        try {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("SETTINGS_ERROR", e.message, null)
        }
    }

    private fun launchApkInstaller(apkPath: String?, result: MethodChannel.Result) {
        if (apkPath.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "Ruta de APK vacia", null)
            return
        }
        val apkFile = File(apkPath)
        if (!apkFile.exists() || apkFile.length() < 1024 * 100) {
            result.error("INVALID_APK", "El archivo APK no existe o esta incompleto", null)
            return
        }
        try {
            val header = ByteArray(2)
            apkFile.inputStream().use { stream ->
                if (stream.read(header) < 2 || header[0] != 0x50.toByte() || header[1] != 0x4B.toByte()) {
                    result.error("INVALID_APK", "El archivo descargado no tiene cabecera APK valida", null)
                    return
                }
            }
            if (!canInstallUnknownPackages()) {
                result.error(
                    "INSTALL_PERMISSION_REQUIRED",
                    "Habilita el permiso 'Instalar aplicaciones desconocidas' para Aula-Scrapt.",
                    null
                )
                return
            }
            val contentUri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                apkFile
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(contentUri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("INSTALL_ERROR", e.message ?: "Error al abrir el instalador", null)
        }
    }

    private fun computeSha256(filePath: String?): String? {
        if (filePath.isNullOrBlank()) return null
        val file = File(filePath)
        if (!file.exists() || !file.isFile) return null
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(65536)
                var read: Int
                while (input.read(buffer).also { read = it } != -1) {
                    digest.update(buffer, 0, read)
                }
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        } catch (_: Exception) {
            null
        }
    }

    private fun openLocalFile(filePath: String?, result: MethodChannel.Result) {
        if (filePath.isNullOrBlank()) {
            result.error("INVALID_PATH", "Ruta vacía", null)
            return
        }
        val file = File(filePath)
        if (!file.exists() || !file.isFile) {
            result.error("NOT_FOUND", "El archivo ya no existe en disco", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val ext = file.extension.lowercase()
            val detectedMime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, detectedMime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(Intent.createChooser(intent, "Abrir ${file.name}"))
            result.success(true)
        } catch (e: Exception) {
            result.error("OPEN_ERROR", e.message ?: "No hay app para abrir este archivo", null)
        }
    }

    private fun requestPostNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || NotificationHelper.hasPermission(this)) {
            result.success(true)
            return
        }
        if (pendingNotifPermResult != null) {
            result.error("BUSY", "Solicitud de permiso pendiente", null)
            return
        }
        pendingNotifPermResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notifPermRequestCode,
        )
    }

    private fun startQrCodeScanner(result: MethodChannel.Result) {
        try {
            val options = GmsBarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .enableAutoZoom()
                .build()
            val scanner = GmsBarcodeScanning.getClient(this, options)
            scanner.startScan()
                .addOnSuccessListener { barcode ->
                    val raw = barcode.rawValue
                    if (raw.isNullOrBlank()) {
                        result.error("EMPTY_QR", "El código QR no contiene texto", null)
                    } else {
                        result.success(raw)
                    }
                }
                .addOnCanceledListener {
                    result.error("CANCELLED", "Escaneo cancelado", null)
                }
                .addOnFailureListener { e ->
                    result.error("SCANNER_UNAVAILABLE", e.message ?: "Escáner QR no disponible", null)
                }
        } catch (e: Exception) {
            result.error("SCANNER_UNAVAILABLE", e.message ?: "Escáner QR no disponible", null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == notifPermRequestCode) {
            val res = pendingNotifPermResult
            pendingNotifPermResult = null
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            res?.success(granted)
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == pickDirRequestCode) {
            val res = pendingDirResult
            pendingDirResult = null
            if (res == null) return
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                res.success(null)
                return
            }
            val treeUri: Uri = data.data!!
            val resolved = resolveTreeUriToPath(treeUri)
            res.success(resolved)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun resolveTreeUriToPath(uri: Uri): String? {
        return try {
            val docId = DocumentsContract.getTreeDocumentId(uri) ?: return null
            val parts = docId.split(":", limit = 2)
            val type = parts[0]
            val relPath = if (parts.size > 1) parts[1] else ""
            if (type.equals("primary", ignoreCase = true)) {
                val base = Environment.getExternalStorageDirectory().absolutePath
                if (relPath.isEmpty()) base else "$base/$relPath"
            } else {
                // Tarjeta SD u otro volumen montado bajo /storage/<uuid>
                if (relPath.isEmpty()) "/storage/$type" else "/storage/$type/$relPath"
            }
        } catch (_: Exception) {
            null
        }
    }
}
