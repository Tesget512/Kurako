package com.tesget.kurako

import android.app.PictureInPictureParams
import android.content.Context
import android.content.ContentValues
import android.net.wifi.WifiManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.util.Rational
import android.webkit.MimeTypeMap
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var autoPictureInPicture = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "kurako/android/network",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    acquireMulticastLock()
                    result.success(null)
                }

                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(null)
                }

                "setAutoPictureInPicture" -> {
                    autoPictureInPicture = call.arguments as? Boolean ?: false
                    configureAutoPictureInPicture()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "kurako/android/media_store",
        ).setMethodCallHandler { call, result ->
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                result.error("UNSUPPORTED", "MediaStore.Downloads requires Android 10", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "reserve" -> {
                        val displayName = sanitizeFileName(
                            call.argument<String>("displayName") ?: error("缺少文件名"),
                        )
                        val relativePath = normalizedRelativePath(
                            call.argument<String>("relativePath")
                                ?: "${Environment.DIRECTORY_DOWNLOADS}/Kurako",
                        )
                        val mimeHint = call.argument<String>("mimeTypeHint") ?: "application/octet-stream"
                        result.success(reserveMedia(displayName, relativePath, mimeHint))
                    }
                    "stat" -> result.success(statMedia(call.argument<String>("uri")!!))
                    "publish" -> {
                        publishMedia(call.argument<String>("uri")!!)
                        result.success(null)
                    }
                    "abort" -> {
                        abortMedia(call.argument<String>("uri")!!)
                        result.success(null)
                    }
                    "deleteMedia" -> {
                        deleteMedia(
                            call.argument<String>("uri")!!,
                            call.argument<String>("videoName")!!,
                        )
                        result.success(null)
                    }
                    "listSubtitles" -> result.success(
                        listSubtitles(call.argument<String>("videoName")!!),
                    )
                    "copyToCache" -> result.success(
                        copyToCache(
                            call.argument<String>("uri")!!,
                            call.argument<String>("fileName")!!,
                        ),
                    )
                    "closeDetachedFd" -> {
                        closeDetachedFd(call.argument<Int>("fd")!!)
                        result.success(null)
                    }
                    "cleanupPending" -> {
                        cleanupPending()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("MEDIA_STORE", error.message ?: error.javaClass.simpleName, null)
            }
        }
    }

    private fun reserveMedia(
        displayName: String,
        relativePath: String,
        mimeTypeHint: String,
    ): Map<String, Any> {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
            put(MediaStore.Downloads.MIME_TYPE, inferredMimeType(displayName, mimeTypeHint))
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val uri = contentResolver.insert(collection, values)
            ?: error("无法创建 MediaStore 下载条目")
        try {
            val descriptor = contentResolver.openFileDescriptor(uri, "rw")
                ?: error("无法打开 MediaStore 可写文件")
            val actualName = queryMedia(uri).first
            return mapOf(
                "uri" to uri.toString(),
                "fd" to descriptor.detachFd(),
                "displayName" to actualName,
            )
        } catch (error: Exception) {
            contentResolver.delete(uri, null, null)
            throw error
        }
    }

    private fun queryMedia(uri: Uri): Pair<String, Long> {
        contentResolver.query(
            uri,
            arrayOf(MediaStore.Downloads.DISPLAY_NAME, MediaStore.Downloads.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) error("MediaStore 条目不存在")
            return Pair(
                cursor.getString(cursor.getColumnIndexOrThrow(MediaStore.Downloads.DISPLAY_NAME)),
                cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Downloads.SIZE)),
            )
        }
        error("无法读取 MediaStore 条目")
    }

    private fun statMedia(uriValue: String): Map<String, Any> {
        val (displayName, size) = queryMedia(Uri.parse(uriValue))
        return mapOf("displayName" to displayName, "size" to size)
    }

    private fun publishMedia(uriValue: String) {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.IS_PENDING, 0)
        }
        val updated = contentResolver.update(Uri.parse(uriValue), values, null, null)
        if (updated != 1) error("无法发布 MediaStore 下载条目")
    }

    private fun abortMedia(uriValue: String) {
        val uri = Uri.parse(uriValue)
        contentResolver.delete(uri, "${MediaStore.Downloads.IS_PENDING}=1", null)
    }

    private fun deleteMedia(uriValue: String, videoName: String) {
        val stem = videoName.substringBeforeLast('.', videoName)
        val subtitleCollection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val selection = "${MediaStore.Downloads.RELATIVE_PATH}=?"
        val args = arrayOf(normalizedRelativePath("${Environment.DIRECTORY_DOWNLOADS}/Kurako/Subtitles"))
        val subtitleUris = mutableListOf<Uri>()
        contentResolver.query(
            subtitleCollection,
            arrayOf(MediaStore.Downloads._ID, MediaStore.Downloads.DISPLAY_NAME),
            selection,
            args,
            null,
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Downloads._ID)
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Downloads.DISPLAY_NAME)
            while (cursor.moveToNext()) {
                val name = cursor.getString(nameColumn) ?: continue
                if (name.startsWith(stem)) {
                    subtitleUris.add(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI.buildUpon()
                            .appendPath(cursor.getLong(idColumn).toString())
                            .build(),
                    )
                }
            }
        }
        subtitleUris.forEach { contentResolver.delete(it, null, null) }
        val deleted = contentResolver.delete(Uri.parse(uriValue), null, null)
        if (deleted != 1) error("无法删除 MediaStore 视频")
    }

    private fun listSubtitles(videoName: String): List<Map<String, Any>> {
        val stem = videoName.substringBeforeLast('.', videoName)
        val subtitles = mutableListOf<Map<String, Any>>()
        contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            arrayOf(
                MediaStore.Downloads._ID,
                MediaStore.Downloads.DISPLAY_NAME,
                MediaStore.Downloads.SIZE,
            ),
            "${MediaStore.Downloads.RELATIVE_PATH}=?",
            arrayOf(normalizedRelativePath("${Environment.DIRECTORY_DOWNLOADS}/Kurako/Subtitles")),
            null,
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Downloads._ID)
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Downloads.DISPLAY_NAME)
            val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.Downloads.SIZE)
            while (cursor.moveToNext()) {
                val name = cursor.getString(nameColumn) ?: continue
                if (!name.startsWith(stem)) continue
                val uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI.buildUpon()
                    .appendPath(cursor.getLong(idColumn).toString())
                    .build()
                subtitles.add(
                    mapOf(
                        "uri" to uri.toString(),
                        "fileName" to name,
                        "size" to cursor.getLong(sizeColumn),
                    ),
                )
            }
        }
        return subtitles
    }

    private fun copyToCache(uriValue: String, fileName: String): String {
        val target = File(
            cacheDir,
            "media-subtitle-${System.nanoTime()}-${sanitizeFileName(fileName)}",
        )
        contentResolver.openInputStream(Uri.parse(uriValue)).use { input ->
            if (input == null) error("无法读取 MediaStore 字幕")
            target.outputStream().use { output -> input.copyTo(output) }
        }
        return target.absolutePath
    }

    private fun closeDetachedFd(fd: Int) {
        if (fd >= 0) ParcelFileDescriptor.adoptFd(fd).close()
    }

    private fun cleanupPending() {
        val selection =
            "${MediaStore.Downloads.RELATIVE_PATH} LIKE ? AND " +
                "${MediaStore.Downloads.IS_PENDING}=1"
        contentResolver.delete(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            selection,
            arrayOf("${Environment.DIRECTORY_DOWNLOADS}/Kurako%"),
        )
    }

    private fun normalizedRelativePath(value: String): String =
        value.trim().trim('/') + "/"

    private fun inferredMimeType(displayName: String, hint: String): String {
        val extension = displayName.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: hint
    }

    private fun sanitizeFileName(value: String): String {
        val cleaned = value
            .replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_")
            .trim()
            .trimEnd('.')
        require(cleaned.isNotEmpty()) { "文件名无效" }
        if (cleaned.length <= 160) return cleaned
        val dot = cleaned.lastIndexOf('.')
        return if (dot > 0) {
            "${cleaned.substring(0, dot).take(150)}.${cleaned.substring(dot + 1).take(9)}"
        } else {
            cleaned.take(160)
        }
    }

    private fun configureAutoPictureInPicture() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoPictureInPicture)
            builder.setSeamlessResizeEnabled(true)
        }
        setPictureInPictureParams(builder.build())
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (
            autoPictureInPicture &&
            Build.VERSION.SDK_INT in Build.VERSION_CODES.O until Build.VERSION_CODES.S &&
            !isInPictureInPictureMode
        ) {
            enterPictureInPictureMode(
                PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(16, 9))
                    .build(),
            )
        }
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifiManager.createMulticastLock("kurako-smb-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
        multicastLock = null
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }
}
