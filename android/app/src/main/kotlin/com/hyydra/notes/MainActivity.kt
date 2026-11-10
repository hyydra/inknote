package com.hyydra.notes

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var folderResult: MethodChannel.Result? = null
    private val folderRequestCode = 7401

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "notes/widget")
            .setMethodCallHandler { call, result ->
                if (call.method != "setNote") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val title = call.argument<String>("title") ?: "Pennino"
                    val base64 = call.argument<String>("png") ?: ""
                    File(filesDir, "notes_widget.png")
                        .writeBytes(Base64.decode(base64, Base64.DEFAULT))
                    getSharedPreferences("notes_widget", Context.MODE_PRIVATE)
                        .edit().putString("title", title).apply()
                    NotesWidget.updateAll(this)
                    result.success(null)
                } catch (error: Exception) {
                    result.error("widget", error.message, null)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "notes/sync")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "hasFolder" -> result.success(hasFolderAccess())
                        "chooseFolder" -> chooseFolder(result)
                        "readFolder" -> result.success(readFolder())
                        "writeFolder" -> {
                            val files = call.argument<Map<String, String>>("files") ?: emptyMap()
                            writeFolder(files)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("drive_sync", error.message, null)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "notes/update")
            .setMethodCallHandler { call, result ->
                if (call.method != "install") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val path = call.argument<String>("path") ?: error("Missing APK path")
                    val apk = File(path)
                    val uri = FileProvider.getUriForFile(
                        this, "$packageName.updates", apk
                    )
                    startActivity(Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    })
                    result.success(null)
                } catch (error: Exception) {
                    result.error("update_install", error.message, null)
                }
            }
    }

    private fun folderUri(): Uri? =
        getSharedPreferences("notes_sync", Context.MODE_PRIVATE)
            .getString("folder_uri", null)?.let(Uri::parse)

    private fun hasFolderAccess(): Boolean {
        val folder = folderUri() ?: return false
        return contentResolver.persistedUriPermissions.any {
            it.uri == folder && it.isReadPermission && it.isWritePermission
        }
    }

    private fun chooseFolder(result: MethodChannel.Result) {
        if (folderResult != null) {
            result.error("folder_picker", "Folder picker is already open", null)
            return
        }
        folderResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            folderUri()?.let { putExtra(DocumentsContract.EXTRA_INITIAL_URI, it) }
        }
        startActivityForResult(intent, folderRequestCode)
    }

    @Deprecated("Deprecated in Android, retained for FlutterActivity compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != folderRequestCode) return
        val result = folderResult
        folderResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result?.success(false)
            return
        }
        val flags = (data?.flags ?: 0) and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        try {
            if (flags and Intent.FLAG_GRANT_READ_URI_PERMISSION == 0 ||
                flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION == 0
            ) {
                error("The selected folder did not grant read and write access")
            }
            contentResolver.takePersistableUriPermission(uri, flags)
            getSharedPreferences("notes_sync", Context.MODE_PRIVATE)
                .edit().putString("folder_uri", uri.toString()).apply()
            result?.success(true)
        } catch (error: Exception) {
            result?.error(
                "folder_permission",
                "Could not keep access to this folder. Choose another Drive folder.",
                error.message
            )
        }
    }

    private fun folderEntries(): Map<String, Uri> {
        val tree = folderUri() ?: error("Choose a Google Drive folder first")
        if (!hasFolderAccess()) {
            error("Drive folder access expired. Choose the folder again.")
        }
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree)
        )
        val entries = mutableMapOf<String, Uri>()
        contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME
            ),
            null, null, null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0)
                val name = cursor.getString(1)
                entries[name] = DocumentsContract.buildDocumentUriUsingTree(tree, id)
            }
        }
        return entries
    }

    private fun readFolder(): Map<String, String> = folderEntries()
        .filterKeys { it.endsWith(".json", ignoreCase = true) }
        .mapValues { (_, uri) ->
            contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
                ?: error("Could not read $uri")
        }

    private fun writeFolder(files: Map<String, String>) {
        val tree = folderUri() ?: error("Choose a Google Drive folder first")
        val parent = DocumentsContract.buildDocumentUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree)
        )
        val existing = folderEntries()
        files.forEach { (name, content) ->
            val uri = existing[name] ?: DocumentsContract.createDocument(
                contentResolver, parent, "application/json", name
            ) ?: error("Could not create $name")
            writeText(uri, content, name)
        }
    }

    private fun writeText(uri: Uri, content: String, name: String) {
        var lastError: Exception? = null
        for (mode in listOf("wt", "w", "rwt")) {
            try {
                val stream = contentResolver.openOutputStream(uri, mode) ?: continue
                stream.bufferedWriter().use { writer -> writer.write(content) }
                return
            } catch (error: Exception) {
                lastError = error
            }
        }
        throw IllegalStateException("Could not write $name", lastError)
    }
}
