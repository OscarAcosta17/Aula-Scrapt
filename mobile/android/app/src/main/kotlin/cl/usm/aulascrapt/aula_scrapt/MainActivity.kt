package cl.usm.aulascrapt.aula_scrapt

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "cl.usm.aulascrapt/storage"
    private val pickDirRequestCode = 9412
    private var pendingDirResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                "getExternalRoot" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
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
