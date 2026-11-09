package com.example.inknote

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var folderResult: MethodChannel.Result? = null
    private val folderRequestCode = 7401

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "inknote/widget")
            .setMethodCallHandler { call, result ->
                if (call.method != "setNote") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val title = call.argument<String>("title") ?: "InkNote"
                    val base64 = call.argument<String>("png") ?: ""
                    File(filesDir, "inknote_widget.png")
                        .writeBytes(Base64.decode(base64, Base64.DEFAULT))
                    getSharedPreferences("inknote_widget", Context.MODE_PRIVATE)
                        .edit().putString("title", title).apply()
                    InkNoteWidget.updateAll(this)
                    result.success(null)
                } catch (error: Exception) {
                    result.error("widget", error.message, null)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "inknote/sync")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "hasFolder" -> result.success(folderUri() != null)
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
    }

    private fun folderUri(): Uri? =
        getSharedPreferences("inknote_sync", Context.MODE_PRIVATE)
            .getString("folder_uri", null)?.let(Uri::parse)

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
        contentResolver.takePersistableUriPermission(uri, flags)
        getSharedPreferences("inknote_sync", Context.MODE_PRIVATE)
            .edit().putString("folder_uri", uri.toString()).apply()
        result?.success(true)
    }

    private fun folderEntries(): Map<String, Uri> {
        val tree = folderUri() ?: error("Choose a Google Drive folder first")
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
        val existing = folderEntries()
        files.forEach { (name, content) ->
            val uri = existing[name] ?: DocumentsContract.createDocument(
                contentResolver, tree, "application/json", name
            ) ?: error("Could not create $name")
            contentResolver.openOutputStream(uri, "wt")?.bufferedWriter()?.use {
                it.write(content)
            } ?: error("Could not write $name")
        }
    }
}
