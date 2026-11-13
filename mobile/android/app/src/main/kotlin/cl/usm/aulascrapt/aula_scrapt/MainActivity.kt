package cl.usm.aulascrapt.aula_scrapt

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
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "cl.usm.aulascrapt/storage"
    private val pickDirRequestCode = 9412
    private var pendingDirResult: MethodChannel.Result? = null

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
            "versionName" to (pkgInfo.versionName ?: "1.2.0"),
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
