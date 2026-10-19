package com.example.pipit

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.Telephony
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.pipit/device_data"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getContacts" -> {
                    thread {
                        try {
                            val contacts = fetchContacts()
                            runOnUiThread { result.success(contacts) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("CONTACTS_ERROR", e.localizedMessage, null) }
                        }
                    }
                }
                "getCallLogs" -> {
                    result.success(emptyList<Map<String, Any?>>())
                }
                "getSms" -> {
                    thread {
                        try {
                            val messages = fetchSms()
                            runOnUiThread { result.success(messages) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SMS_ERROR", e.localizedMessage, null) }
                        }
                    }
                }
                "getInstalledApps" -> {
                    thread {
                        try {
                            val apps = fetchInstalledApps()
                            runOnUiThread { result.success(apps) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("APPS_ERROR", e.localizedMessage, null) }
                        }
                    }
                }
                "getAppIcon" -> {
                    val packageName = call.argument<String>("packageName")
                    if (!packageName.isNullOrEmpty()) {
                        thread {
                            try {
                                val iconBytes = fetchAppIconBytes(packageName)
                                runOnUiThread { result.success(iconBytes) }
                            } catch (e: Exception) {
                                runOnUiThread { result.success(null) }
                            }
                        }
                    } else {
                        result.success(null)
                    }
                }
                "openFile" -> {
                    val path = call.argument<String>("path")
                    val mimeType = call.argument<String>("mimeType")
                    if (!path.isNullOrEmpty()) {
                        openFileWithIntent(path, mimeType, result)
                    } else {
                        result.error("INVALID_PATH", "Path is empty or null", null)
                    }
                }
                "openApp" -> {
                    val packageName = call.argument<String>("packageName")
                    if (!packageName.isNullOrEmpty()) {
                        try {
                            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                            if (launchIntent != null) {
                                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(launchIntent)
                                result.success(true)
                            } else {
                                result.error("APP_NOT_FOUND", "No launch intent found for $packageName", null)
                            }
                        } catch (e: Exception) {
                            result.error("OPEN_APP_ERROR", e.localizedMessage, null)
                        }
                    } else {
                        result.error("INVALID_PACKAGE", "Package name is null", null)
                    }
                }
                "openSms" -> {
                    val address = call.argument<String>("address") ?: ""
                    val body = call.argument<String>("body")
                    try {
                        val uri = Uri.parse("smsto:$address")
                        val intent = Intent(Intent.ACTION_SENDTO, uri).apply {
                            if (!body.isNullOrEmpty()) {
                                putExtra("sms_body", body)
                            }
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                data = Uri.parse("sms:$address")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("OPEN_SMS_ERROR", e2.localizedMessage, null)
                        }
                    }
                }
                "openContact" -> {
                    val number = call.argument<String>("number") ?: ""
                    try {
                        val intent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:$number")).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_CONTACT_ERROR", e.localizedMessage, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun openFileWithIntent(path: String, customMime: String?, result: MethodChannel.Result) {
        try {
            val file = File(path)
            if (!file.exists()) {
                result.error("FILE_NOT_FOUND", "File not found: $path", null)
                return
            }

            val resolvedMime = getSpecificMimeType(path, customMime)
            val uri: Uri = try {
                FileProvider.getUriForFile(
                    this,
                    "${applicationContext.packageName}.fileprovider",
                    file
                )
            } catch (e: Exception) {
                Uri.fromFile(file)
            }

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, resolvedMime)
                addCategory(Intent.CATEGORY_DEFAULT)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("OPEN_FILE_ERROR", e.localizedMessage, null)
        }
    }

    private fun getSpecificMimeType(path: String, hintMime: String?): String {
        val ext = File(path).extension.lowercase()
        if (ext.isNotEmpty()) {
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            if (!mime.isNullOrEmpty()) return mime
        }
        return when (ext) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            "bmp" -> "image/bmp"
            "heic", "heif" -> "image/heic"
            "mp4" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "avi" -> "video/x-msvideo"
            "mov" -> "video/quicktime"
            "3gp" -> "video/3gpp"
            "webm" -> "video/webm"
            "mp3" -> "audio/mpeg"
            "wav" -> "audio/wav"
            "m4a" -> "audio/mp4"
            "aac" -> "audio/aac"
            "ogg" -> "audio/ogg"
            "flac" -> "audio/flac"
            "pdf" -> "application/pdf"
            "doc" -> "application/msword"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "xls" -> "application/vnd.ms-excel"
            "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "ppt" -> "application/vnd.ms-powerpoint"
            "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            "txt" -> "text/plain"
            "csv" -> "text/csv"
            else -> if (!hintMime.isNullOrEmpty() && !hintMime.endsWith("/*") && hintMime != "*/*") hintMime else "*/*"
        }
    }

    private fun fetchContacts(): List<Map<String, Any?>> {
        val list = mutableListOf<Map<String, Any?>>()
        val uri = ContactsContract.CommonDataKinds.Phone.CONTENT_URI
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER
        )
        val seenIds = mutableSetOf<String>()

        val cursor: Cursor? = contentResolver.query(uri, projection, null, null, "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC")
        cursor?.use {
            val idIndex = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.CONTACT_ID)
            val nameIndex = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
            val numberIndex = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)

            while (it.moveToNext()) {
                val id = if (idIndex != -1) it.getString(idIndex) ?: "" else ""
                val name = if (nameIndex != -1) it.getString(nameIndex) ?: "Unknown" else "Unknown"
                val number = if (numberIndex != -1) it.getString(numberIndex) ?: "" else ""

                val key = "$name-$number"
                if (!seenIds.contains(key)) {
                    seenIds.add(key)
                    list.add(
                        mapOf(
                            "id" to id,
                            "name" to name,
                            "number" to number
                        )
                    )
                }
            }
        }
        return list
    }

    private fun fetchCallLogs(): List<Map<String, Any?>> {
        val list = mutableListOf<Map<String, Any?>>()
        val uri = CallLog.Calls.CONTENT_URI
        val projection = arrayOf(
            CallLog.Calls._ID,
            CallLog.Calls.CACHED_NAME,
            CallLog.Calls.NUMBER,
            CallLog.Calls.TYPE,
            CallLog.Calls.DATE,
            CallLog.Calls.DURATION
        )

        val cursor: Cursor? = contentResolver.query(uri, projection, null, null, "${CallLog.Calls.DATE} DESC")
        cursor?.use {
            val idIdx = it.getColumnIndex(CallLog.Calls._ID)
            val nameIdx = it.getColumnIndex(CallLog.Calls.CACHED_NAME)
            val numberIdx = it.getColumnIndex(CallLog.Calls.NUMBER)
            val typeIdx = it.getColumnIndex(CallLog.Calls.TYPE)
            val dateIdx = it.getColumnIndex(CallLog.Calls.DATE)
            val durationIdx = it.getColumnIndex(CallLog.Calls.DURATION)

            while (it.moveToNext()) {
                val id = if (idIdx != -1) it.getString(idIdx) ?: "" else ""
                val name = if (nameIdx != -1) it.getString(nameIdx) ?: "" else ""
                val number = if (numberIdx != -1) it.getString(numberIdx) ?: "" else ""
                val type = if (typeIdx != -1) it.getInt(typeIdx) else 0
                val date = if (dateIdx != -1) it.getLong(dateIdx) else 0L
                val duration = if (durationIdx != -1) it.getLong(durationIdx) else 0L

                val typeLabel = when (type) {
                    CallLog.Calls.INCOMING_TYPE -> "Incoming"
                    CallLog.Calls.OUTGOING_TYPE -> "Outgoing"
                    CallLog.Calls.MISSED_TYPE -> "Missed"
                    CallLog.Calls.VOICEMAIL_TYPE -> "Voicemail"
                    CallLog.Calls.REJECTED_TYPE -> "Rejected"
                    CallLog.Calls.BLOCKED_TYPE -> "Blocked"
                    else -> "Unknown"
                }

                list.add(
                    mapOf(
                        "id" to id,
                        "name" to name,
                        "number" to number,
                        "type" to typeLabel,
                        "date" to date,
                        "duration" to duration
                    )
                )
            }
        }
        return list
    }

    private fun fetchSms(): List<Map<String, Any?>> {
        val list = mutableListOf<Map<String, Any?>>()
        val uri = Uri.parse("content://sms")
        val projection = arrayOf("_id", "address", "body", "date", "type")

        val cursor: Cursor? = contentResolver.query(uri, projection, null, null, "date DESC")
        cursor?.use {
            val idIdx = it.getColumnIndex("_id")
            val addressIdx = it.getColumnIndex("address")
            val bodyIdx = it.getColumnIndex("body")
            val dateIdx = it.getColumnIndex("date")
            val typeIdx = it.getColumnIndex("type")

            while (it.moveToNext()) {
                val id = if (idIdx != -1) it.getString(idIdx) ?: "" else ""
                val address = if (addressIdx != -1) it.getString(addressIdx) ?: "" else ""
                val body = if (bodyIdx != -1) it.getString(bodyIdx) ?: "" else ""
                val date = if (dateIdx != -1) it.getLong(dateIdx) else 0L
                val typeInt = if (typeIdx != -1) it.getInt(typeIdx) else 1

                val typeLabel = if (typeInt == 2) "Sent" else "Inbox"

                list.add(
                    mapOf(
                        "id" to id,
                        "address" to address,
                        "body" to body,
                        "date" to date,
                        "type" to typeLabel
                    )
                )
            }
        }
        return list
    }

    private fun fetchInstalledApps(): List<Map<String, Any?>> {
        val list = mutableListOf<Map<String, Any?>>()
        val pm = packageManager
        val packages = pm.getInstalledPackages(0)

        for (pkg in packages) {
            val appInfo = pkg.applicationInfo ?: continue
            val packageName = pkg.packageName
            val launchIntent = pm.getLaunchIntentForPackage(packageName)
            val appName = pm.getApplicationLabel(appInfo).toString()
            val versionName = pkg.versionName ?: ""

            val isRawSystem = (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            val isUpdatedSystem = (appInfo.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0

            val lowerPkg = packageName.lowercase()
            val lowerName = appName.lowercase()

            val isPopularApp = lowerPkg.contains("instagram") ||
                    lowerPkg.contains("facebook") ||
                    lowerPkg.contains("whatsapp") ||
                    lowerPkg.contains("netflix") ||
                    lowerPkg.contains("spotify") ||
                    lowerPkg.contains("twitter") ||
                    lowerPkg.contains("tiktok") ||
                    lowerPkg.contains("snapchat") ||
                    lowerPkg.contains("telegram") ||
                    lowerPkg.contains("linkedin") ||
                    lowerPkg.contains("youtube") ||
                    lowerPkg.contains("amazon") ||
                    lowerPkg.contains("flipkart") ||
                    lowerPkg.contains("chrome") ||
                    lowerPkg.contains("threads") ||
                    lowerPkg.contains("messenger") ||
                    lowerPkg.contains("reddit")

            val isSystemApp = when {
                isPopularApp -> false
                isUpdatedSystem -> false
                !isRawSystem -> false
                launchIntent != null && !packageName.startsWith("android") &&
                        !packageName.startsWith("com.android.internal") &&
                        !packageName.startsWith("com.android.server") &&
                        !packageName.startsWith("com.android.providers") &&
                        !packageName.startsWith("com.google.android.overlay") &&
                        !packageName.startsWith("com.qualcomm") -> false
                else -> true
            }

            // Include launchable applications and user apps; ignore pure background system services
            if (launchIntent != null || !isSystemApp) {
                val category = getAppCategory(appInfo)
                list.add(
                    mapOf(
                        "name" to appName,
                        "packageName" to packageName,
                        "version" to versionName,
                        "isSystemApp" to isSystemApp,
                        "category" to category
                    )
                )
            }
        }
        list.sortBy { (it["name"] as? String)?.lowercase() ?: "" }
        return list
    }

    private fun getAppCategory(appInfo: ApplicationInfo): String {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            when (appInfo.category) {
                ApplicationInfo.CATEGORY_GAME -> return "Games"
                ApplicationInfo.CATEGORY_AUDIO -> return "Music & Audio"
                ApplicationInfo.CATEGORY_VIDEO -> return "Video & Media"
                ApplicationInfo.CATEGORY_IMAGE -> return "Photography"
                ApplicationInfo.CATEGORY_SOCIAL -> return "Social"
                ApplicationInfo.CATEGORY_NEWS -> return "News"
                ApplicationInfo.CATEGORY_MAPS -> return "Maps & Navigation"
                ApplicationInfo.CATEGORY_PRODUCTIVITY -> return "Productivity"
                ApplicationInfo.CATEGORY_ACCESSIBILITY -> return "Accessibility"
            }
        }
        val lowerPkg = appInfo.packageName.lowercase()
        return when {
            lowerPkg.contains("camera") || lowerPkg.contains("gallery") || lowerPkg.contains("photos") -> "Photography"
            lowerPkg.contains("video") || lowerPkg.contains("player") || lowerPkg.contains("youtube") || lowerPkg.contains("netflix") -> "Video & Media"
            lowerPkg.contains("music") || lowerPkg.contains("audio") || lowerPkg.contains("sound") || lowerPkg.contains("spotify") -> "Music & Audio"
            lowerPkg.contains("game") || lowerPkg.contains("play.games") -> "Games"
            lowerPkg.contains("browser") || lowerPkg.contains("chrome") || lowerPkg.contains("firefox") || lowerPkg.contains("opera") -> "Browser"
            lowerPkg.contains("mail") || lowerPkg.contains("gmail") || lowerPkg.contains("outlook") -> "Email"
            lowerPkg.contains("chat") || lowerPkg.contains("message") || lowerPkg.contains("whatsapp") || lowerPkg.contains("telegram") || lowerPkg.contains("social") || lowerPkg.contains("facebook") || lowerPkg.contains("instagram") || lowerPkg.contains("twitter") -> "Social"
            lowerPkg.contains("map") || lowerPkg.contains("navigation") || lowerPkg.contains("gps") -> "Maps & Navigation"
            lowerPkg.contains("calc") || lowerPkg.contains("calendar") || lowerPkg.contains("clock") || lowerPkg.contains("deskclock") || lowerPkg.contains("notes") || lowerPkg.contains("office") || lowerPkg.contains("document") || lowerPkg.contains("pdf") -> "Productivity"
            (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0 -> "System"
            else -> "Tools"
        }
    }

    private fun fetchAppIconBytes(packageName: String): ByteArray? {
        return try {
            val pm = packageManager
            val drawable = pm.getApplicationIcon(packageName)
            val width = if (drawable.intrinsicWidth > 0) drawable.intrinsicWidth else 96
            val height = if (drawable.intrinsicHeight > 0) drawable.intrinsicHeight else 96
            val targetW = Math.min(width, 108)
            val targetH = Math.min(height, 108)
            val bmp = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            drawable.setBounds(0, 0, canvas.width, canvas.height)
            drawable.draw(canvas)
            val stream = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 90, stream)
            stream.toByteArray()
        } catch (e: Exception) {
            null
        }
    }
}
